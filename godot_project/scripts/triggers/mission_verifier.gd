## The MISSION SPEC RUNNER — docs plan §5 layer (b), M3 step 6.
##
##   godot --headless --path . -- --map=MAP.210 --no-briefing \
##         --no-mission-scene --verify-missions=all --verify-out=rows.txt
##
## Layer (a), the lock, pins what the GRAPH says one trigger does. Layer
## (c), the verifier, proves that the running game does that — one node
## at a time, on a map put back to its pristine state between checks.
## Neither says that a MISSION can be played: that the doorway a mission
## needs opens onto the map that holds the next objective, that the cue
## behind it still counts down the counter it belongs to, and that the
## counter reaches zero at the end of the route DOS has. This does.
##
## tests/rules/skynet.missions.txt is one hand-written block per campaign
## mission — the steps in the order a player performs them:
##
##   mission 210                       the map the mission starts on
##     exit 210 07f83 expect exit214/0 take that doorway
##     walk 215 032cb expect obj0      walk onto that record's mesh
##     use 215 02f8f expect obj1       press the key at that record
##     prox 220 06f12 expect obj0      walk into that trigger
##     shoot 248 035a6 expect break@035a6:1
##     wait 234 0ea0c expect path@0ea0c   stand by it and let it run
##     must_not use 252 0342c expect obj0    doing that must NOT do this
##     counter 0                       and the mission counter reads 0
##     xfail path_window               …what is known not to work yet
##
## A step is measured the way layer (c) measures a node — the player is
## put where the record's own measure says he must stand and the key, the
## walk or the shot goes through the real input path
## (scripts/triggers/player_driver.gd), and the event bus
## (scripts/triggers/trigger_bus.gd) says what the game did. What differs
## is everything around it: nothing is reset between steps, the map is
## whatever the steps before left it, and an exit is TAKEN — the level
## changes under the run and the next step is on the next map, with the
## mission counter the one main.gd keeps for the mission.
##
## So `expect` is read as "these effects happened", not "exactly these":
## a mission is played with its robots awake, its ambient loops running
## and its movers still arriving, and what else the game says in the
## second a step takes is the business of layer (c), which measures it on
## a still map. A missing effect fails the step; an extra one is written
## into the row for reading. `must_not` is the other way round — every
## effect listed must be absent, which is how the four regressions in the
## spec file are pinned.
##
## This class IS the verifier (it extends it) rather than a second copy
## of it: where to stand, how to aim, how to press, how a shot is fired
## and how a chain's effects are compared are the same code, and the two
## layers cannot drift apart.

extends "res://scripts/triggers/trigger_verifier.gd"

const SPEC_PATH: String = "res://tests/rules/skynet.missions.txt"

const XPASS: String = "XPASS"
const XFAIL: String = "XFAIL"

## What a step may do. `use_below` is the one measure-breaking verb: the
## key pressed from a floor (or the water's surface, on the way down) UNDER the record, inside
## its horizontal radius and outside its true 3D reach — where the port's
## old 2D-with-a-vertical-window measure fired and DOS does not.
##
## `walk` walks onto a WALK-ON PAD's own mesh — no key (state bit 0x10,
## FUN_00139d5e; trigger_verifier._check_walk).
const VERBS: PackedStringArray = ["use", "use_below", "prox", "shoot",
	"exit", "wait", "walk"]

## What a step or a mission may be excused with, in one word:
##   path_window   a marker-path vehicle only drives inside the DOS
##                 five-cell actor window (0x12980f), which nothing here
##                 models: the lever that starts it is far enough from
##                 the machine that the machine never ticks
##   port_use_reach / second_activation / chain_silent / chain_short /
##   chain_extra / projectile_no_hit — as tests/rules/skynet.xfail means
##   them (scripts/triggers/trigger_verifier.gd names each one).
const SPEC_TAGS: PackedStringArray = [
	"path_window", "port_use_reach", "second_activation",
	"chain_silent", "chain_short", "chain_extra", "projectile_no_hit",
]

## The header comment of the spec file, fixed word for word (hygiene).
const SPEC_HEAD: PackedStringArray = [
	"# mission specs - run with --verify-missions (see COMMANDS.md)",
	"# map numbers decimal, ids lower hex, effects as the graph writes them",
]

## Physics frames a `wait` step lets the game run — a path vehicle picks
## its path up on the first tick it spends in the player's grid window
## and then drives it, and three seconds is what layer (c) gives one
## (trigger_verifier._check_path).
const WAIT_FRAMES: int = 180
## …and how long a `wait` on a PATH VEHICLE has. It is the machine's OWN
## drive (PathVehicle.drive_seconds): a segment is driven at 0.3125 of its
## length per second (Rules.PATH_SPEED_K), but the speed changes at
## Rules.PATH_ACCEL, so a long segment is still ramping up when it ends and
## a short one after it is driven at the long one's speed while it brakes
## — "about three seconds a segment" held only for a path of equal steps.
## Divided by how many times a frame the engine ticks it where the player
## stands (PathVehicle.ticks_from: twice for a started convoy truck in the
## window, 0x12984d), with PATH_WAIT_SLACK on top and PATH_WAIT_FRAMES as
## the ceiling. The step stops the moment the machine runs its path out
## (PathVehicle.finished).
const PATH_WAIT_FRAMES: int = 3600
const PATH_WAIT_SLACK: float = 1.5
## …and how long a taken exit has to land the next map (frames).
const EXIT_FRAMES: int = 1800
## The vertical window the port used to measure a proximity record with,
## and the reach `use_below` looks for a place inside.
const BELOW_WINDOW: float = Rules.PROX_VERTICAL_WINDOW
## Where the feet are put under the surface for a key pressed from the
## water: the eyes ten units over it. DOS has no swimming, so the player
## is sinking there (fly_camera._water_check); the key goes down on the
## frame he is put there, before he has sunk.
const FLOAT_FEET: float = 65.0

## The parsed spec, and one row per step performed.
var _missions: Array = []
var _steps: Array = []
var _only: Dictionary = {}               # --verify-missions=210,240
var _cur: String = ""                    # the map the run stands on

# ---------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------
## Called by main.gd once the first level is up. The run drives every
## further level change itself, so later calls are ignored.
func begin_missions() -> void:
	if _running:
		return
	_running = true
	var spec: String = String(main._cli.get("verify-missions", "all")).strip_edges()
	if spec == "true" or spec.is_empty():
		spec = "all"
	if spec != "all":
		for s in spec.split(",", false):
			_only[int(String(s).strip_edges().to_lower().replace("map.", ""))] = true
	_prepare()
	var text: String = FileAccess.get_file_as_string(SPEC_PATH) \
		if FileAccess.file_exists(SPEC_PATH) else ""
	var parsed: Dictionary = parse(text)
	for e in (parsed.get("errors", []) as Array):
		print("[mission] spec: %s" % String(e))
	_missions = parsed.get("missions", [])
	if _missions.is_empty():
		print("[mission] no mission spec to run (%s)" % SPEC_PATH)
		get_tree().quit(1)
		return
	await _run_missions()

# ---------------------------------------------------------------------
# The spec file
# ---------------------------------------------------------------------
## text → {"missions": [{"key", "xfail", "steps": [...]}], "errors": []}.
## Static, so the suite can read the file without a game running.
static func parse(text: String) -> Dictionary:
	var missions: Array = []
	var errors: Array = []
	var cur: Dictionary = {}
	var n: int = 0
	for raw in text.split("\n"):
		n += 1
		var line: String = raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var tok: PackedStringArray = line.split(" ", false)
		var head: String = String(tok[0])
		if head == "mission":
			if tok.size() < 2 or not String(tok[1]).is_valid_int():
				errors.append("line %d: a mission needs its start map" % n)
				continue
			cur = {"key": int(tok[1]), "xfail": "", "steps": []}
			missions.append(cur)
			continue
		if cur.is_empty():
			errors.append("line %d: a step before any mission" % n)
			continue
		if head == "counter":
			if tok.size() < 2 or not String(tok[1]).is_valid_int():
				errors.append("line %d: the counter needs a number" % n)
				continue
			(cur["steps"] as Array).append({"kind": "counter",
				"want": int(tok[1]), "xfail": "", "line": n})
			continue
		if head == "xfail":
			var tag: String = String(tok[1]) if tok.size() > 1 else ""
			if not SPEC_TAGS.has(tag):
				errors.append("line %d: %s is not a known tag" % [n, tag])
				continue
			var steps: Array = cur["steps"]
			if steps.is_empty():
				cur["xfail"] = tag              # the whole mission
			else:
				(steps[steps.size() - 1] as Dictionary)["xfail"] = tag
			continue
		var negative: bool = head == "must_not"
		var at: int = 1 if negative else 0
		if tok.size() < at + 4 or not VERBS.has(String(tok[at])):
			errors.append("line %d: %s is not a step" % [n, line])
			continue
		var want := PackedStringArray()
		var seen_expect: bool = false
		for i in range(at + 3, tok.size()):
			if String(tok[i]) == "expect":
				seen_expect = true
				continue
			want.append(String(tok[i]))
		if not seen_expect or want.is_empty():
			errors.append("line %d: a step says what it expects" % n)
			continue
		(cur["steps"] as Array).append({"kind": "must_not" if negative else "step",
			"verb": String(tok[at]), "map": int(tok[at + 1]),
			"id": String(tok[at + 2]).hex_to_int(), "want": want,
			"xfail": "", "line": n})
	return {"missions": missions, "errors": errors}

## The permitted vocabulary of the spec file — the discipline the lock
## and the known-failure list keep (trigger_lock.hygiene,
## trigger_verifier.hygiene): map numbers, hex ids, the effect tokens the
## graph itself writes, the verbs and the tags above. No entity names, no
## coordinates, no quotes, none of the game's own words.
static func hygiene(text: String) -> PackedStringArray:
	var bad := PackedStringArray()
	var effect := RegEx.new()
	effect.compile("^(obj[0-4]|hint[0-9]|fail|voice[0-9]+|snd[0-9]+|loop[0-9]+" \
		+ "|exit(back|[0-9]+)/[0-9]+|move@[0-9a-f]{5}:(slide|swing|rot|jump)[XYZ][+-][0-9]+" \
		+ "|spin@[0-9a-f]{5}|break@[0-9a-f]{5}:[0-9]+|demolish@[0-9a-f]{5}" \
		+ "|spawn@[0-9a-f]{5}|water(abs|[+-][0-9]+)|light_[a-z_]+@[0-9a-f]{5}" \
		+ "|path@[0-9a-f]{5})$")
	var id := RegEx.new()
	id.compile("^[0-9a-f]{4,5}$")
	for raw in text.split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("#"):
			if not SPEC_HEAD.has(line):
				bad.append(line)
			continue
		var tok: PackedStringArray = line.split(" ", false)
		var head: String = String(tok[0])
		if head == "mission" or head == "counter":
			if tok.size() != 2 or not String(tok[1]).is_valid_int():
				bad.append(line)
			continue
		if head == "xfail":
			if tok.size() != 2 or not SPEC_TAGS.has(String(tok[1])):
				bad.append(line)
			continue
		var at: int = 1 if head == "must_not" else 0
		if tok.size() < at + 5 or not VERBS.has(String(tok[at])) \
				or not String(tok[at + 1]).is_valid_int() \
				or id.search(String(tok[at + 2])) == null \
				or String(tok[at + 3]) != "expect":
			bad.append(line)
			continue
		for i in range(at + 4, tok.size()):
			if effect.search(String(tok[i])) == null:
				bad.append(line)
				break
	return bad

# ---------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------
func _run_missions() -> void:
	_t0 = Time.get_ticks_msec()
	var todo: Array = []
	for m in _missions:
		if _only.is_empty() or _only.has(int((m as Dictionary)["key"])):
			todo.append(m)
	print("[mission] %d mission(s) to play" % todo.size())
	for m in todo:
		await _run_mission(m as Dictionary)
	_report_missions()

func _run_mission(spec: Dictionary) -> void:
	var key: int = int(spec["key"])
	var t0: int = Time.get_ticks_msec()
	var nm: String = "MAP.%03d" % key
	# A mission begins the way RESTART MISSION begins one: the level
	# change is handed a session holding nothing but the map, which empties
	# every map's overlay, the previous-map register and the pending marker
	# set, and puts main's mission key back to -1 so the briefing script and
	# its objective counter are read again (main._install_save). The
	# briefing screen itself is skipped — this is not a player starting a
	# game, it is the mission being measured.
	if not await main._change_level(nm, false, false,
			{"map": nm, "mission_start_map": nm, "restart": true}):
		_step_row(key, 0, "mission", key, 0, FAIL, "the start map would not load", "")
		return
	await _drv.frames(8)
	_cur = main._level_name()
	var graph: Dictionary = _ready_map()
	if graph.is_empty():
		_step_row(key, 0, "mission", key, 0, FAIL, "no graph on the start map", "")
		return
	var n: int = 0
	for s in (spec["steps"] as Array):
		var step: Dictionary = s
		n += 1
		var tag: String = String(step["xfail"])
		if tag.is_empty():
			tag = String(spec["xfail"])
		await _run_step(key, n, step, tag)
	print("[mission] %d: %s in %.1f s" % [key, _tally(key),
		float(Time.get_ticks_msec() - t0) / 1000.0])
	# The MISSION COMPLETE banner pauses the game under itself; the next
	# mission needs it gone.
	main._dismiss_end_screen()

func _run_step(key: int, n: int, step: Dictionary, tag: String) -> void:
	var kind: String = String(step["kind"])
	if kind == "counter":
		var left: int = int(main._objectives_left)
		var want: int = int(step["want"])
		_step_row(key, n, "counter", key, 0,
			PASS if left == want else FAIL,
			"" if left == want else "the counter reads %d, not %d" % [left, want], tag)
		return
	var map: int = int(step["map"])
	var id: int = int(step["id"])
	var verb: String = String(step["verb"])
	var forced: String = ""
	# The step names the map it belongs to. A run that is not on it has
	# been left somewhere else — a doorway that did not open, an exit that
	# took a different one — and that is a failure of the step before; the
	# level is put where the spec says so the rest of the mission can still
	# be measured, and this step says it had to be.
	if _cur != "MAP.%03d" % map:
		forced = "the run stood on %s" % (_cur if not _cur.is_empty() else "nothing")
		if not await _go_to(map):
			_step_row(key, n, verb, map, id, FAIL,
				_join(forced, "and that map would not load"), tag)
			return
	var level = main._current_level
	if level == null or level.behaviour == null:
		_step_row(key, n, verb, map, id, FAIL, _join(forced, "no level"), tag)
		return
	var got: Dictionary = await _perform(level, verb, id)
	_drv.release_all()
	if not bool(got["ok"]):
		# A step of a mission spec names something the player HAS to
		# do, so nowhere to do it from is a failure and not the
		# neutral result it is in layer (c), where a doorway behind a
		# shut door is a door nobody has opened yet.
		_step_row(key, n, verb, map, id, FAIL,
			_join(forced, "it could not be performed: " + String(got["why"])), tag)
		return
	var tokens: PackedStringArray = got["tokens"]
	var res: Dictionary = TriggerEquiv.compare(Array(step["want"] as PackedStringArray), tokens)
	var missing: PackedStringArray = res["missing"]
	var extra: PackedStringArray = res["extra"]
	var negative: bool = kind == "must_not"
	var why: String = ""
	var ok: bool = true
	if negative:
		# Every effect listed has to be absent: what is NOT missing from
		# the wanted list is what the game did and must not have.
		var did := PackedStringArray()
		for t in (step["want"] as PackedStringArray):
			if not missing.has(t):
				did.append(String(t))
		ok = did.is_empty()
		if not ok:
			why = "it did " + " ".join(did)
	else:
		ok = missing.is_empty()
		if not ok:
			why = "missing " + " ".join(missing)
	if not extra.is_empty() and not negative:
		why = _join(why, "also " + " ".join(extra))
	# A doorway that fired is taken: the level changes under the run.
	await _take_exit(tokens)
	# …and a step the run had to be CARRIED to was not reached by
	# playing, whatever it did once it was there.
	if not forced.is_empty():
		ok = false
		why = _join(why, forced)
	_step_row(key, n, verb, map, id, PASS if ok else FAIL, why, tag)

## Perform one step's action and return {"ok", "tokens", "why"}.
func _perform(level, verb: String, id: int) -> Dictionary:
	var graph: Dictionary = TriggerEquiv.graph_of(level)
	var node: Dictionary = TriggerEquiv.node_of(graph, id)
	var kind: String = String((node.get("rule", {}) as Dictionary).get("kind", "?"))
	var mode: Dictionary = primary_mode(node)
	match verb:
		"use", "use_below":
			return await _do_use(level, id, kind, mode, verb == "use_below")
		"prox":
			return await _do_prox(level, id, mode)
		"walk":
			return await _do_walk(level, id, node.get("first", []))
		"shoot":
			return await _do_shoot(level, id)
		"exit":
			# A doorway is taken the way the map offers it: where an 0xEF
			# GATE guards it (the common case — the sprite pair by every
			# door), the key is pressed at the gate and the chain walks
			# through to the exit (Behaviour.activate_teleport); where the
			# 0xF0 sprite stands on its own, the player stands in it and
			# presses.
			if String(mode.get("mode", "")) == "use_key":
				return await _do_use(level, id, kind, mode, false)
			return await _do_exit(level, id, mode)
		"wait":
			return await _do_wait(level, id)
	return {"ok": false, "tokens": PackedStringArray(), "why": "no driver for %s" % verb}

# --- the verbs --------------------------------------------------------
## The activate key at the record. A record the graph gives no node at
## all — MAP.252's picture, a cue nothing points at — is still stood at
## and still pressed: that it does NOTHING is the whole point of the
## must_not line that names it.
func _do_use(level, id: int, kind: String, mode: Dictionary, below: bool) -> Dictionary:
	if mode.is_empty():
		mode = {"origin": "eye", "metric": "3d",
			"radius": Rules.PROX_GATE_RADIUS, "pad": Rules.PLAYER_RADIUS}
	if below:
		return await _do_use_below(level, id, mode)
	var spot: Dictionary = _use_spot(level, id, kind, mode)
	if not bool(spot["ok"]):
		var wide: Dictionary = _stand_wide(level, _epos(level, id), mode)
		if not bool(wide["ok"]):
			return {"ok": false, "tokens": PackedStringArray(),
				"why": _join(String(wide["why"]), "the eye stood %.0f u from it"
					% _drv.eye().distance_to(_epos(level, id)))}
		wide["gate"] = spot["gate"]
		wide["aim"] = spot["aim"]
		spot = wide
	return {"ok": true, "why": "", "tokens": await _stand_and_record(
		level, spot["feet"], spot["aim"], bool(spot["gate"]), 1)}

## The key from UNDER the record: inside the horizontal radius and the
## vertical window the port used to measure a proximity record with,
## and outside the true 3D reach the DOS handler measures from the eye
## (0x1386a0). The ring of gates round the jeep on MAP.250 fired mission
## 5's [M1] from 143 units under the quay, from the water - so the water
## surface is a place to stand here, as well as whatever floor lies
## below (scripts/level/trigger.gd names the same spot).
func _do_use_below(level, id: int, mode: Dictionary) -> Dictionary:
	var ep: Vector3 = _epos(level, id)
	var r: float = float(mode.get("radius", Rules.PROX_GATE_RADIUS)) + float(mode.get("pad", 0.0))
	var cands: Array = []
	var water: float = float(main.player.get("water_level"))
	if is_finite(water) and water < ep.y:
		cands.append(Vector3(ep.x, water - FLOAT_FEET, ep.z))
	for f in _floors_under(ep, r + BELOW_WINDOW):
		cands.append(f)
	for feet in cands:
		var eye: Vector3 = (feet as Vector3) + Vector3(0.0, EYE + PlayerDriver.LIFT, 0.0)
		if eye.y >= ep.y or absf(eye.y - ep.y) > BELOW_WINDOW:
			continue
		if eye.distance_to(ep) <= r:
			continue                              # DOS reaches it here: not below
		if Vector2(eye.x - ep.x, eye.z - ep.z).length() > r:
			continue                              # ...and not under it either
		return {"ok": true, "why": "", "tokens": await _stand_and_record(
			level, feet, ep, true, 1)}
	return {"ok": false, "tokens": PackedStringArray(),
		"why": "nowhere under it inside the measure the port used to have"}

## Walking into an 0xF1/0xF2 trigger, from outside it where there is
## somewhere to walk in from.
func _do_prox(level, id: int, mode: Dictionary) -> Dictionary:
	if mode.is_empty():
		return {"ok": false, "tokens": PackedStringArray(), "why": "no way in"}
	var ep: Vector3 = _epos(level, id)
	var inside: Dictionary = _stand_in(level, ep, mode, 0.0, id)
	if not bool(inside["ok"]) and int(main.player.get("vehicle")) == VEH_HK 			and String(mode.get("origin", "")) == "eye":
		# The HK is not stood anywhere: it FLIES into a gate its body has
		# no floor to fit on under (MAP.271's tunnel gate @06a6b, the
		# gates that lead into it on MAP.270).
		return await _fly_in(level, ep, mode)
	if not bool(inside["ok"]):
		return {"ok": false, "tokens": PackedStringArray(), "why": String(inside["why"])}
	var outside: Dictionary = _stand_out(level, ep, mode, id)
	var from: Vector3 = outside["feet"] if bool(outside["ok"]) else Vector3.INF
	# The recording starts BEFORE the player is put outside, which is
	# where this differs from layer (c)'s walk-in (trigger_verifier
	# ._walk_in records from the moment the walk starts). A mission asks
	# whether walking there sets the trigger off at all, and on the two
	# missions that are DRIVEN - the jeep and the HK - "walking" is a
	# machine with momentum that is already moving when it is put down:
	# it can cross the whole radius inside the frames the walk-in spends
	# settling, and the one thing it announced was then heard by nobody
	# and the trigger was spent for good.
	var bus = level.bus
	bus.record(true)
	bus.clear()
	if from != Vector3.INF:
		_drv.place(from)
		_drv.face(ep)
		await _drv.frames(PRE_FRAMES)
		if await _drv.walk_toward(inside["feet"], 45, 24.0) > 48.0:
			_drv.place(inside["feet"])            # the way was not walkable
	else:
		_drv.place(inside["feet"])
	_drv.face(ep)
	await _bring_the_eye_to(ep, float(mode.get("radius", Rules.PROX_GATE_RADIUS)))
	await _drv.frames(ACT_FRAMES)
	var tokens: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	return {"ok": true, "why": "", "tokens": tokens}

## fly_camera.VEH_HK — mission 7 is flown.
const VEH_HK: int = 2

## A gunship into an eye-measured trigger: put down in the air just
## outside the reach at the record's own height, then brought in until the
## cockpit is well inside it (_bring_the_eye_to), recording all the while.
func _fly_in(level, ep: Vector3, mode: Dictionary) -> Dictionary:
	var r: float = float(mode.get("radius", Rules.PROX_GATE_RADIUS)) + float(mode.get("pad", 0.0))
	var bus = level.bus
	bus.record(true)
	bus.clear()
	var lift: Vector3 = _drv.eye() - _drv.feet()
	_drv.place(ep + Vector3(r + OUTSIDE_PAD * 4.0, 0.0, 0.0) - lift)
	_drv.face(ep)
	await _drv.frames(PRE_FRAMES)
	await _bring_the_eye_to(ep, r)
	await _drv.frames(ACT_FRAMES)
	var tokens: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	return {"ok": true, "why": "", "tokens": tokens}

## Bring the MEASURING POINT inside the record's reach, whatever is
## carrying it. Where a standing point is looked for, the eye is taken to
## be the soldier's own — 75 units over his feet, which is what layer (c)
## has on every map it checks. Two missions are DRIVEN: the DOS engine
## measures a proximity record from the player's camera
## (main._eye_position, fly_camera.dos_point), and in the HK that camera
## rides the cockpit, a long way from the body the search put down. The
## body is walked the last stretch here, until the eye that will be
## measured is well inside the radius that measures it.
func _bring_the_eye_to(ep: Vector3, radius: float) -> void:
	for _i in 3:
		await _drv.frames(1)
		var d: Vector3 = ep - _drv.eye()
		if d.length() <= radius * 0.75:
			return
		_drv.place(main.player.global_position + d * 0.9)
		_drv.face(ep)

## Shots, with the rifle, from a place with a line to the record.
func _do_shoot(level, id: int) -> Dictionary:
	var aim: Vector3 = _aim_point(level, id)
	if aim == Vector3.INF:
		return {"ok": false, "tokens": PackedStringArray(), "why": "nothing to aim at"}
	var spot: Dictionary = _shooting_spot(level, id, aim)
	if not bool(spot["ok"]):
		return {"ok": false, "tokens": PackedStringArray(), "why": String(spot["why"])}
	_drv.place(spot["feet"])
	_drv.face(aim)
	_drv.press_key(KEY_1 + SHOT_WEAPON)
	await _drv.frames(PRE_FRAMES)
	var bus = level.bus
	bus.record(true)
	bus.clear()
	for _i in SHOT_MAX:
		await _fire_once()
		if not level.behaviour.is_damageable(id) or bus.history().size() > 0:
			break
	await _drv.frames(ACT_FRAMES)
	var tokens: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	return {"ok": true, "tokens": tokens, "why": ""}

## A doorway: stood in and answered with the key, the way a player takes
## one. The crosshair is put on the floor — an exit is a sprite with no
## collider and a mesh behind it would answer the key instead.
func _do_exit(level, id: int, mode: Dictionary) -> Dictionary:
	if mode.is_empty():
		mode = {"origin": "feet", "metric": "2d+window",
			"radius": Rules.TELEPORT_TOUCH_RADIUS, "window": Rules.PROX_VERTICAL_WINDOW}
	var ep: Vector3 = _epos(level, id)
	var spot: Dictionary = _stand_in(level, ep, mode, 0.0, id, true)
	if not bool(spot["ok"]):
		spot = _stand_in(level, ep, mode, 0.0, id)   # …or with the door shut
	if not bool(spot["ok"]):
		return {"ok": false, "tokens": PackedStringArray(), "why": String(spot["why"])}
	# Standing in it ARMS it and the key then takes it, so the player is
	# put down first and stands there for a moment: a place and a press in
	# the same frame reach the doorway before the touch that armed it has
	# happened. He is put down again inside the recording, because the
	# controller settles the body over the floor point and a doorway's
	# reach is the radius that armed it — there is no slack in it.
	_drv.place(spot["feet"])
	_drv.face(ep)
	await _drv.frames(PRE_FRAMES)
	var tokens: PackedStringArray = await _record_around(level, func() -> void:
		_drv.place(spot["feet"])
		_drv.face(ep)
		_drv.look(main.player.rotation.y, -1.0)
		_drv.activate())
	return {"ok": true, "tokens": tokens, "why": ""}

## Walk onto the record's own mesh from beside it, on the movement keys,
## and nothing else: a walk-on pad needs no key (FUN_00139d5e).
func _do_walk(level, id: int, want: Array) -> Dictionary:
	var spots: Array = _pad_spots(level, id, 1)
	if spots.is_empty():
		return {"ok": false, "tokens": PackedStringArray(),
			"why": "nowhere on its own mesh to stand"}
	var on: Vector3 = spots[0]
	var from: Vector3 = _off_pad(level, id, on)
	return {"ok": true, "why": "", "tokens": await _walk_in(level, from, on, on, want,
		level.behaviour.hit_node(id))}

## Stand by the record and let the game run: a path vehicle drives (DOS
## ticks an actor only in the five grid cells round the player, so the
## watching is the test's method and not its subject), a mover arrives, a
## chain already armed comes to what it comes to.
func _do_wait(level, id: int) -> Dictionary:
	var at: Vector3 = _epos(level, id)
	var veh: Node = level.behaviour.vehicle_node(id)
	var frames: int = WAIT_FRAMES
	# A machine that is ALREADY ticked from where the player stands is
	# watched from there. DOS ticks an actor only in the five map-grid
	# cells round the player (0x12980f), and the two path missions put the
	# player on opposite sides of that: MAP.210's lever is far enough from
	# the truck that a player who threw it never sees it move, and MAP.234's
	# HK is flying when the roof loads, ends its path four hundred units
	# from the marker the exit puts the player down on, and is inside his
	# window the whole way — so teleporting him to the machine's own spawn
	# is what makes it fly out of his window and stop, and nothing in the
	# DOS handler (0x127400, which never touches the player) puts it back.
	var stay: bool = false
	var drive: float = 0.0
	if veh != null and veh.actor != null and is_instance_valid(veh.actor):
		at = (veh.actor as Node3D).global_position
		drive = float(veh.call("drive_seconds"))
		stay = bool(veh.call("watched_from", main.player.global_position))
	if at == Vector3.INF:
		return {"ok": false, "tokens": PackedStringArray(), "why": "no record"}
	if not stay:
		var beside: Vector3 = at + Vector3(0.0, 0.0, 256.0)
		var floor_at: Vector3 = _floor_under(beside, 600.0)
		_drv.place(floor_at if floor_at != Vector3.INF else beside)
	_drv.face(at)
	await _drv.frames(PRE_FRAMES)
	if veh != null and drive > 0.0:
		var per: int = maxi(int(veh.call("ticks_from", main.player.global_position)), 1)
		frames = clampi(int(ceil(drive * PATH_WAIT_SLACK
			* float(Engine.physics_ticks_per_second) / float(per))) + WAIT_FRAMES,
			WAIT_FRAMES, PATH_WAIT_FRAMES)
	var bus = level.bus
	bus.record(true)
	bus.clear()
	for _i in frames:
		await _drv.physics(1)
		if veh != null and bool(veh.get("finished")):
			break
	await _drv.frames(1)
	var tokens: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	return {"ok": true, "tokens": tokens, "why": ""}

# --- moving between maps ----------------------------------------------
## A doorway fired: wait for main.gd to put the next map up (the fade,
## the tear-down and the build), and make the new level ready to be
## driven. Nothing here asks for the change — the game did it.
func _take_exit(tokens: PackedStringArray) -> void:
	if not _has_exit(tokens):
		return
	var was: String = _cur
	for _i in EXIT_FRAMES:
		await _drv.frames(1)
		if bool(main._level_busy):
			continue
		if main._level_name() != was and main._current_level != null:
			break
	await _drv.frames(4)
	_cur = main._level_name()
	if _cur != was:
		_ready_map()

## Put the run on `map` (a level change of the runner's own, after a step
## left it somewhere the spec does not expect).
func _go_to(map: int) -> bool:
	var nm: String = "MAP.%03d" % map
	if not await main._change_level(nm, false, false):
		return false
	await _drv.frames(8)
	_cur = main._level_name()
	if _cur != nm:
		return false
	_ready_map()
	return true

## The level that has just come up, ready to be driven — and the body
## the standing search measures with taken again. Layer (c) takes that
## body ONCE, at the start of a run that never changes it; a mission run
## crosses from a soldier into the jeep and the HK and back
## (main._level_ready_tail → fly_camera.set_vehicle, which swaps the
## capsule for VEH_CAPSULE), and a soldier's capsule measured for a
## machine — or a machine's for a soldier — reads a base corridor as
## blocked and finds nowhere to stand at all.
func _ready_map() -> Dictionary:
	var graph: Dictionary = _open_map(main._current_level, false)
	var cs: CollisionShape3D = main.player.get_node_or_null("CollisionShape3D")
	var body: CapsuleShape3D = cs.shape as CapsuleShape3D if cs != null else null
	if body != null:
		_shape_y = cs.position.y
		_shape = CapsuleShape3D.new()
		_shape.radius = body.radius
		_shape.height = body.height
	return graph

# ---------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------
func _step_row(key: int, n: int, verb: String, map: int, id: int,
		res: String, why: String, tag: String) -> void:
	var final: String = res
	if not tag.is_empty():
		final = XFAIL if res == FAIL else (XPASS if res == PASS else res)
	_steps.append({"mission": key, "n": n, "verb": verb, "map": map, "id": id,
		"res": final, "why": why, "tag": tag})
	if final == FAIL or final == XFAIL:
		print("[mission] %s %d step %d %s %d @%05x — %s%s"
			% [final, key, n, verb, map, id, why if not why.is_empty() else "-",
			   (" (" + tag + ")") if not tag.is_empty() else ""])

## One mission's counts, for its closing line.
func _tally(key: int) -> String:
	var c: Dictionary = {}
	for r in _steps:
		if int((r as Dictionary)["mission"]) != key:
			continue
		var res: String = String((r as Dictionary)["res"])
		c[res] = int(c.get(res, 0)) + 1
	var parts := PackedStringArray()
	for res in [PASS, FAIL, XFAIL, XPASS]:
		if c.has(res):
			parts.append("%d %s" % [int(c[res]), res])
	return ", ".join(parts) if not parts.is_empty() else "nothing to do"

func _report_missions() -> void:
	var c: Dictionary = {}
	var fails: Array = []
	for r in _steps:
		var row: Dictionary = r
		var res: String = String(row["res"])
		c[res] = int(c.get(res, 0)) + 1
		if res == FAIL:
			fails.append(row)
	var secs: float = float(Time.get_ticks_msec() - _t0) / 1000.0
	print("[mission] %d step(s): %d PASS, %d FAIL, %d XFAIL, %d XPASS in %.0f s"
		% [_steps.size(), int(c.get(PASS, 0)), int(c.get(FAIL, 0)),
		   int(c.get(XFAIL, 0)), int(c.get(XPASS, 0)), secs])
	for row in fails:
		print("[mission] FAIL %d step %d %s %d @%05x — %s" % [int(row["mission"]),
			int(row["n"]), String(row["verb"]), int(row["map"]), int(row["id"]),
			String(row["why"])])
	if int(c.get(XPASS, 0)) > 0:
		var fixed := PackedStringArray()
		for r in _steps:
			if String((r as Dictionary)["res"]) == XPASS:
				fixed.append("%d/%d" % [int((r as Dictionary)["mission"]),
					int((r as Dictionary)["n"])])
		print("[mission] %d excused step(s) now pass: %s" % [fixed.size(), " ".join(fixed)])
	_write_steps()
	get_tree().quit(1 if not fails.is_empty() else 0)

## --verify-out=PATH: one line per step, for the triage.
func _write_steps() -> void:
	var path: String = String(main._cli.get("verify-out", ""))
	if path.is_empty():
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[mission] cannot write %s" % path)
		return
	for r in _steps:
		var row: Dictionary = r
		f.store_line("%d %d %s %d %05x %s %s %s" % [int(row["mission"]), int(row["n"]),
			String(row["verb"]), int(row["map"]), int(row["id"]), String(row["res"]),
			String(row["tag"]) if not String(row["tag"]).is_empty() else "-",
			String(row["why"])])
	f.close()
	print("[mission] rows written: %s" % path)
