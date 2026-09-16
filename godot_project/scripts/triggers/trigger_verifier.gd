## The TRIGGER VERIFIER — docs plan §5 layer (c), M3 step 4.
##
##   godot --headless --path . -- --map=MAP.200 --no-briefing \
##         --no-mission-scene --verify-triggers=all
##
## Layer (a), the lock, pins what the GRAPH says a map's triggers do.
## Layer (b), the mission spec, will pin a whole mission's route. This is
## the layer between them and the only one that touches the running game:
## for every node of every map it puts the player where the node's own
## `measure` says he has to stand, performs the activation the node
## declares — through the real input path, keys and all
## (scripts/triggers/player_driver.gd) — and lays what the event bus
## heard (scripts/triggers/trigger_bus.gd) against what the graph
## predicted for that node's first and second activation
## (scripts/triggers/trigger_equiv.gd, step 3's comparison, unchanged).
##
## Per map: load once, take a snapshot, and put that snapshot back
## between checks — a map is a few hundred checks and a level build is
## seconds. Exits are RECORDED AND REFUSED rather than taken (the map
## would go away in the middle of its own run); so are the mission
## counter and the fail act, whose handlers in main.gd end the level.
##
## Per kind, beyond the effect lists:
##   0xEF   inside + key → first; again after the movers settle → second;
##          from radius + 20 → nothing; a state-04 prop → nothing
##   F1/F2  walking in fires it once; leaving and coming back does not
##          (the port's latch) until a chain re-arms it
##   button a named variant-1 mesh with state bit 3: walking through does
##          nothing, the key fires it
##   exit   touching only ARMS it, the key takes it, a chain-armed one
##          fires on the tick it is armed
##   shot   bit 1 fires on the hit, bit 2 at HP 0, a destructible steps
##          one damage stage
##   mover  the travel the graph promised, within a unit or half a
##          degree; the bit cleared and the direction flipped afterwards
##   path   the vehicle has covered more than 80 units when it picks its
##          path up
##   relay  fires on the tick the objective counter reaches its word
## Movers, water, lights, spawns, sounds, voice lines, hints and
## objectives are not driven on their own — nothing but a chain can set
## them off — so they are verified as part of the effects of whatever
## DOES drive them, which is where the graph puts them too.
##
## Results are PASS / FAIL / UNREACHABLE (no place to stand or no line to
## shoot along, the way the solver reports a blocker) / SKIP (nothing can
## set the node off but a chain). Known failures live in
## tests/rules/skynet.xfail, facts only; the run exits non-zero only on a
## failure that is not in it.

extends Node

const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")
const TriggerEquiv := preload("res://scripts/triggers/trigger_equiv.gd")
const TriggerLock := preload("res://scripts/triggers/trigger_lock.gd")
const Rules := preload("res://scripts/triggers/rules_skynet.gd")
const PlayerDriver := preload("res://scripts/triggers/player_driver.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

const XFAIL_PATH: String = "res://tests/rules/skynet.xfail"

const PASS: String = "PASS"
const FAIL: String = "FAIL"
const UNREACHABLE: String = "UNREACHABLE"
const SKIP: String = "SKIP"

## Frames to let a handler run after the activation: the cues fire as the
## chain is walked, a mover announces at the START of its run, an exit on
## the tick it is armed — all inside the first few ticks.
const ACT_FRAMES: int = 6
## …and how long to wait afterwards for the movers to arrive, so the
## SECOND activation starts where the graph's simulation says it does
## (a 2 048-unit slide at 140 u/s is 14.6 s; a door is under 2). A
## CONTINUOUS rotator never arrives and is not waited for.
const SETTLE_FRAMES: int = 1000
## Frames the player stands still before recording, so anything else his
## standing there sets off has already gone off (trigger_equiv.check
## keeps him a long way away for the same reason; here he has to be at
## the node, so the noise is spent in advance instead).
const PRE_FRAMES: int = 3
## Shots per node: the assault rifle's 20 points are one damage stage
## (DESTRUCT_DAMAGE_PER_STAGE = 16), so one shot is the usual whole test.
const SHOT_MAX: int = 3
## Weapon slot 2 (ASSAULT RIFLE) — selected with the number key, so even
## that goes through the input path.
const SHOT_WEAPON: int = 2
## How far outside a radius the negative check stands.
const OUTSIDE_PAD: float = 20.0
## Floor search: directions round the node, and the fractions of the
## radius to try them at (nearest first — the DOS player stood at the
## thing, not at the edge of its reach).
const RING: Array = [
	Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(-1.0, 0.0),
	Vector2(0.0, 1.0), Vector2(0.0, -1.0), Vector2(0.7, 0.7),
	Vector2(0.7, -0.7), Vector2(-0.7, 0.7), Vector2(-0.7, -0.7),
]
const RING_FRACTIONS: Array = [0.0, 0.35, 0.6, 0.85]
## Shooting spots are looked for further out as well.
const SHOT_DISTANCES: Array = [90.0, 180.0, 320.0, 560.0, 900.0]
const FLOOR_MIN_NY: float = 0.766        # cos 40°, fly_camera.FOOT_MAX_SLOPE_DEG
const EYE: float = PlayerDriver.EYE

## scripts/main.gd.
var main = null
var _drv: RefCounted = null
var _space: PhysicsDirectSpaceState3D = null
var _shape: CapsuleShape3D = null
var _shape_y: float = 44.0

var _spec: String = ""
var _rows: Array = []                    # one dictionary per check
var _xfail: Dictionary = {}              # "map id" → the pinned reason
var _running: bool = false
var _t0: int = 0
var _map_t0: int = 0
var _checks: int = 0
## What an exit asked for instead of being taken, and what the counter did.
var _exit_seen: Array = []
## The pristine state of the map being checked (taken once per map).
var _snap: Dictionary = {}
## Every live proximity trigger of this map in world space, [id, pos, r] —
## what a standing point has to keep OUT of. The graph predicts what ONE
## node's activation comes to; the use key fires every gate in reach and
## a step into a doorway trips every trigger whose radius covers it, so a
## point inside two of them proves nothing about either (the ring of
## gates round MAP.210's jeep is eight of them within a few feet).
var _prox_world: Array = []
var _limit: int = 0                      # --verify-limit: nodes per map
var _only_ids: Dictionary = {}           # --verify-nodes=0bb44,075cb

# ---------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------
## Called by main once the first level is up (like --solve). The run
## drives every further level change itself, so later calls are ignored.
func begin() -> void:
	if _running:
		return
	_running = true
	_spec = String(main._cli.get("verify-triggers", "all")).strip_edges()
	_limit = int(main._cli.get("verify-limit", 0))
	for s in String(main._cli.get("verify-nodes", "")).split(",", false):
		_only_ids[s.strip_edges().hex_to_int()] = true
	_prepare()
	await _run()

## A few named nodes of the level that is ALREADY up, with no level
## changes, no report and no exit code — the seconds-long subset a suite
## can afford (game_smoke_test). Returns the rows.
func check_current(ids: Array) -> Array:
	_only_ids.clear()
	for i in ids:
		_only_ids[int(i)] = true
	_rows.clear()
	_prepare()
	await _verify_map(main._level_name())
	return _rows

func _prepare() -> void:
	if _drv != null:
		return
	_drv = PlayerDriver.new()
	_drv.setup(main)
	_space = main.get_world_3d().direct_space_state
	var cs: CollisionShape3D = main.player.get_node_or_null("CollisionShape3D")
	var body: CapsuleShape3D = cs.shape as CapsuleShape3D if cs != null else null
	_shape_y = cs.position.y if cs != null else 44.0
	_shape = CapsuleShape3D.new()
	_shape.radius = (body.radius if body != null else 16.0)
	_shape.height = (body.height if body != null else 88.0)
	_load_xfail()

func _run() -> void:
	_t0 = Time.get_ticks_msec()
	var maps: PackedStringArray = _map_list()
	print("[verify] %d map(s) to check (%s)" % [maps.size(), _spec])
	for name in maps:
		if main._level_name() != name:
			if not await main._change_level(name, false, false):
				_row(-1, 0, 0, "-", "-", FAIL, "the level would not load")
				continue
			await _drv.frames(8)
		await _verify_map(name)
	_report()

## Which maps this run covers.
##   all / (empty)   every map the archive holds
##   mission:210     the whole decade a mission's maps sit in
##   maps:215,217    exactly those
##   changed         only the maps whose graph no longer matches the lock
func _map_list() -> PackedStringArray:
	var all: PackedStringArray = PackedStringArray()
	for m in main._maps:
		all.append(String(m))
	if _spec.begins_with("maps:"):
		var out := PackedStringArray()
		for s in _spec.substr(5).split(",", false):
			var nm: String = s.strip_edges().to_upper()
			if not nm.begins_with("MAP."):
				nm = "MAP." + nm
			if all.has(nm):
				out.append(nm)
		return out
	if _spec.begins_with("mission:"):
		var key: int = int(_spec.substr(8))
		var out2 := PackedStringArray()
		for nm in all:
			var num: int = int(nm.get_extension())
			if (num / 10) * 10 == (key / 10) * 10:
				out2.append(nm)
		return out2
	if _spec == "changed":
		return _changed_maps(all)
	return all

## The maps whose freshly built graph differs from the lock — what to
## re-check after a rules change, instead of the whole game.
func _changed_maps(all: PackedStringArray) -> PackedStringArray:
	var lock: Dictionary = TriggerLock.parse(TriggerLock.lock_text())
	var maps: Dictionary = lock.get("maps", {})
	var out := PackedStringArray()
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		return all
	for nm in all:
		var num: int = int(nm.get_extension())
		var bytes: PackedByteArray = bsa.read(nm)
		if bytes.is_empty():
			out.append(nm)                       # cannot tell: check it
			continue
		var built: Dictionary = TriggerLock.map_lines(nm, bytes)
		var pinned: Dictionary = maps.get(num, {})
		if pinned.is_empty() or String(pinned.get("head", "")) != String(built.get("head", "")):
			out.append(nm)
			continue
		var want: Dictionary = pinned.get("lines", {})
		var got: PackedStringArray = built.get("lines", PackedStringArray())
		var same: bool = want.size() == got.size()
		if same:
			for line in got:
				var id: int = String(line).split(" ")[1].hex_to_int()
				if String(want.get(id, "")) != String(line):
					same = false
					break
		if not same:
			out.append(nm)
	bsa.close()
	return out

# ---------------------------------------------------------------------
# One map
# ---------------------------------------------------------------------
func _verify_map(name: String) -> void:
	_map_t0 = Time.get_ticks_msec()
	var level = main._current_level
	if level == null or level.action == null:
		_row(-1, 0, 0, "-", "-", FAIL, "no level")
		return
	var num: int = int(level.map_suffix)
	var graph: Dictionary = TriggerEquiv.graph_of(level)
	if graph.is_empty():
		_row(num, 0, 0, "-", "-", FAIL, "no graph")
		return
	# The player cannot be killed between checks; the robots are left
	# alone, because a path vehicle IS one of them (a dead actor stops
	# driving its markers, and `killall` took the truck with it).
	main.player.set("god_mode", true)
	_intercept(level)
	# Slot 2 (ASSAULT RIFLE): 20 damage points, which is one damage stage
	# — and chosen on the number key, so even that goes through the input
	# path. fly_camera reads KEY_1..KEY_9 straight off the event.
	_drv.press_key(KEY_3)
	_prox_world = []
	for pi in (level.action._prox as Array).size():
		var pe = level.action._prox[pi]
		_prox_world.append([int(pe.file_off),
			(level.action._prox_pos[pi] as Vector3) + (level.origin as Vector3),
			level.action._prox_radius(pe)])
	_snap = _pristine(level, graph, _snapshot(level))
	var snap: Dictionary = _snap
	var nodes: Array = (graph.get("nodes", []) as Array).duplicate()
	nodes.sort_custom(func(a, b): return int((a as Dictionary)["id"]) < int((b as Dictionary)["id"]))
	var done: int = 0
	for n in nodes:
		var node: Dictionary = n
		var id: int = int(node["id"])
		if not _only_ids.is_empty() and not _only_ids.has(id):
			continue
		if _limit > 0 and done >= _limit:
			break
		done += 1
		_reset(level, snap)
		await _check_node(level, graph, node)
	_reset(level, snap)
	_release(level)
	print("[verify] %s: %d node(s) in %.1f s" % [name, done,
		float(Time.get_ticks_msec() - _map_t0) / 1000.0])

## Everything that would end or leave the level while one node is being
## checked, taken over for the run: an exit is recorded and refused, the
## objective counter is kept here instead of in main (whose handler ends
## the mission and changes the level), and so is the fail act.
func _intercept(level) -> void:
	var a = level.action
	if a.teleport_requested.is_connected(main._on_teleport_requested):
		a.teleport_requested.disconnect(main._on_teleport_requested)
	if not a.teleport_requested.is_connected(_on_exit):
		a.teleport_requested.connect(_on_exit)
	var b = level.behaviour
	if b == null:
		return
	if b.objective_complete.is_connected(main._on_objective_complete):
		b.objective_complete.disconnect(main._on_objective_complete)
		b.hint_message.disconnect(main._on_hint_message)
		b.mission_failed.disconnect(main._on_mission_failed)
	if not b.objective_complete.is_connected(_on_objective):
		b.objective_complete.connect(_on_objective)

## Give the level back to main.gd — a suite running the subset goes on
## playing afterwards, and a level whose exits and objectives still
## reported here would take none of them.
func _release(level) -> void:
	var a = level.action
	if a != null and a.teleport_requested.is_connected(_on_exit):
		a.teleport_requested.disconnect(_on_exit)
		if not a.teleport_requested.is_connected(main._on_teleport_requested):
			a.teleport_requested.connect(main._on_teleport_requested)
	var b = level.behaviour
	if b == null:
		return
	if b.objective_complete.is_connected(_on_objective):
		b.objective_complete.disconnect(_on_objective)
	if not b.objective_complete.is_connected(main._on_objective_complete):
		b.objective_complete.connect(main._on_objective_complete)
		b.hint_message.connect(main._on_hint_message)
		b.mission_failed.connect(main._on_mission_failed)

## An exit asked for its map change: written down, and nothing else. The
## action system's one-map-change latch is deliberately LEFT SET — it is
## what DOS does (the frame loop tears the level down before any handler
## runs again, v1.01 0x117a2e), and releasing it here let the same exit
## fire a second time down the tick sweep and read as "the game did it
## twice". _reset clears the latch between checks.
func _on_exit(target_map: int, marker_set: int) -> void:
	_exit_seen.append([target_map, marker_set])

## The counter main.gd would keep. Only the number matters here (the
## relay reads it, and an objective is supposed to take it down by one);
## the mission-end machinery stays out of the run.
func _on_objective(_idx: int) -> void:
	var a = main._current_level.action if main._current_level != null else null
	if a != null and a.objectives_left > 0:
		a.objectives_left -= 1

# ---------------------------------------------------------------------
# Snapshot and reset
# ---------------------------------------------------------------------
func _snapshot(level) -> Dictionary:
	var a = level.action
	var paths: Dictionary = {}
	for off in a._path_vehicles:
		var v: Dictionary = a._path_vehicles[off]
		var nd: Node3D = v["node"]
		paths[off] = [nd.position if nd != null and is_instance_valid(nd) else Vector3.ZERO,
			nd.rotation.y if nd != null and is_instance_valid(nd) else 0.0]
	return {"action": a.save_state(), "objectives": a.objectives_left,
		"paths": paths, "water": float(main.player.get("water_level")),
		"spawn": main.player.global_position, "yaw": main.player.rotation.y}

## The snapshot the checks reset to is the map AS ITS FILE HAS IT, not as
## it happens to stand: the graph's `first` is simulated from the record
## bytes, so a state byte, a mover, a damage stage or a pool of hit points
## that play has already moved would be measured against a prediction made
## for a map nobody had touched. On a freshly loaded map the two are the
## same thing; for a suite running the subset at the end of a session they
## are not.
func _pristine(level, graph: Dictionary, snap: Dictionary) -> Dictionary:
	var act: Dictionary = snap["action"]
	var states: Dictionary = act["states"]
	var hp: Dictionary = act["hp"]
	for n in (graph.get("nodes", []) as Array):
		var node: Dictionary = n
		var id: int = int(node["id"])
		states[id] = int(node.get("state", 0))
		if hp.has(id):
			hp[id] = float(node.get("hp", 0))
	for off in act["movers"]:
		act["movers"][off] = [0.0, 1.0]
	for off in act["destr"]:
		act["destr"][off] = [0, 0.0]
	act["spent"] = {}
	act["acts"] = {}
	act["links"] = {}
	return snap

## Put the map back as it was. ActionSystem.restore_state does the
## records, the movers, the damage stages and the hit points; the latches
## and the one-map-change flag are the sweeps' own memory and are cleared
## here, or the next check would start with the player already "inside"
## every trigger he was standing in.
func _reset(level, snap: Dictionary) -> void:
	var a = level.action
	_restore_acts(level)
	a.restore_state(snap["action"])
	a._prox_latched.clear()
	a._touch_latched.clear()
	a._armed.clear()
	a._edge_done.clear()
	a._use_edge = false
	a._teleport_fired = false
	a._light_live.clear()
	a._light_strobe_on.clear()
	a.objectives_left = int(snap["objectives"])
	for off in a._movers:
		(a._movers[off] as Dictionary)["running"] = false
	var paths: Dictionary = snap["paths"]
	for off in paths:
		var v: Dictionary = a._path_vehicles.get(off, {})
		if v.is_empty():
			continue
		var nd: Node3D = v["node"]
		if nd != null and is_instance_valid(nd):
			nd.position = paths[off][0]
			nd.rotation.y = float(paths[off][1])
		v["tgt"] = 0
		v["spd"] = 0.0
		v["tspd"] = 0.0
	# A robot an 0xF3 chain let out stays out (putting it back is the
	# level loader's work, not a snapshot's) — but the sprite is armed
	# again, so the next check of it announces as it did the first time.
	a._spawned.clear()
	main.player.set("water_level", float(snap["water"]))
	_exit_seen.clear()
	if level.bus != null:
		level.bus.record(false)

## The act bytes and links as the MAP was parsed. A save's overlay only
## stores the ones play has CHANGED, so restore_state cannot undo a cue
## DOS retired (act ← 0xFF) or a water valve that swapped its own act —
## and the next check of a chain carrying a hint found the message gone
## for good. Every record goes back to what map_file.gd read, and the
## cue nodes with it.
func _restore_acts(level) -> void:
	var a = level.action
	var b = level.behaviour
	for off in a._parsed_act:
		var e = level.map.entities_by_off.get(off)
		if e == null:
			continue
		e.link_act_type = int(a._parsed_act[off])
		e.link_next = int(a._parsed_link.get(off, e.link_next))
		if b == null:
			continue
		var n: Node = b.node(off)
		if n != null and "spent" in n:
			n.set("spent", e.link_act_type == 0xFF)

# ---------------------------------------------------------------------
# One node
# ---------------------------------------------------------------------
## The mode this node is driven by — the first one a player can perform.
static func primary_mode(node: Dictionary) -> Dictionary:
	var order: Array = ["use_key", "prox_enter", "touch_arm", "shot_each",
		"shot_death", "counter", "path_end"]
	for want in order:
		for m in (node.get("modes", []) as Array):
			if String((m as Dictionary).get("mode", "")) == want:
				return m
	return {}

func _check_node(level, graph: Dictionary, node: Dictionary) -> void:
	var id: int = int(node["id"])
	var act: int = int(node["act"])
	var kind: String = String((node.get("rule", {}) as Dictionary).get("kind", "?"))
	var num: int = int(graph.get("map", -1))
	var mode: Dictionary = primary_mode(node)
	if mode.is_empty():
		# An 0xEF record whose state bits are not both clear or both set is
		# not a gate at all: the handler (v1.01 0x1386a0) never runs for it,
		# so the graph gives it no way in and the key must do nothing here
		# either — the one case where "no mode" is worth proving.
		if act == Rules.ACT_PROX_GATE and (int(node.get("state", 0)) & 6) != 0 \
				and (int(node.get("state", 0)) & 6) != 6:
			_checks += 1
			await _check_dead_gate(level, node, num, id, act, kind)
			return
		_row(num, id, act, kind, "chain", SKIP, "only a chain can set it off")
		return
	var how: String = String(mode["mode"])
	_checks += 1
	match how:
		"use_key":
			await _check_use(level, node, num, id, act, kind, mode)
		"prox_enter":
			await _check_prox(level, node, num, id, act, kind, mode)
		"touch_arm":
			await _check_exit(level, node, num, id, act, kind, mode)
		"shot_each", "shot_death":
			await _check_shot(level, node, num, id, act, kind, how)
		"counter":
			await _check_relay(level, node, num, id, act, kind, mode)
		"path_end":
			await _check_path(level, node, num, id, act, kind)
		_:
			_row(num, id, act, kind, how, SKIP, "no driver for this mode")

# --- the use key (0xEF gates and the wall buttons) --------------------
func _check_use(level, node: Dictionary, num: int, id: int, act: int,
		kind: String, mode: Dictionary) -> void:
	var ep: Vector3 = _epos(level, id)
	# An 0xEF gate is a sprite with no collider: DOS fires the gates in
	# reach on the KEY itself (press_use → the tick sweep), the crosshair
	# has nothing to do with it, and aiming at whatever stands behind the
	# gate would operate THAT instead (fly_camera._try_activate walks the
	# ray's collider up to an ActionTarget). So a gate is used looking at
	# the floor. A wall button is the opposite: it IS the mesh the ray has
	# to find, and the player stands at it.
	# …unless the 0xEF record is a named variant-1 mesh with state bit 3.
	# The runtime takes THOSE off the proximity sweep altogether (walking
	# past a button must not press it) and leaves them to the crosshair, so
	# a key pressed at the floor beside one does nothing at all. The graph
	# gives them the plain DOS gate mode, which is a divergence of its own
	# and is what the rows say.
	var gate: bool = kind == "prox_gate" and not _is_wall_button(level, id)
	var aim: Vector3 = ep if gate else _aim_point(level, id)
	var spot: Dictionary = _stand_in(level, ep, mode,
		0.0 if gate else Rules.USE_REACH, id)
	if not bool(spot["ok"]):
		_row(num, id, act, kind, "use", UNREACHABLE, String(spot["why"]))
		return
	var shared: String = "shared with another trigger" if bool(spot.get("shared", false)) else ""
	# A wall button answers the key, never the walk: prove the walk first.
	var walked: PackedStringArray = PackedStringArray()
	if not gate:
		walked = await _stand_and_record(level, spot["feet"], aim, gate, 0)
	var first: PackedStringArray = await _stand_and_record(level, spot["feet"], aim, gate, 1)
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), first))
	if first.is_empty() and not (node.get("first", []) as Array).is_empty():
		# Nothing at all happened: say how far the eye really was, so a
		# standing point the search believed in and the running game did not
		# is told apart from a trigger that is simply broken.
		why = _join(why, "the eye was %.0f u from it, reach %.0f"
			% [_drv.eye().distance_to(ep),
			   float(mode.get("radius", 0.0)) + float(mode.get("pad", 0.0))])
	if not walked.is_empty():
		why = _join(why, "walking past it did %s" % " ".join(walked))
	# …and the movers it started must do what the graph said they would.
	why = _join(why, _mover_truth(level, node.get("first", [])))
	if not why.is_empty():
		_row(num, id, act, kind, "use", FAIL, _join(why, shared))
		return
	# The movers arrive, clear their bit and flip their direction — and
	# only then is the next press the graph's SECOND activation.
	await _settle(level)
	why = _mover_settled(level, node.get("first", []))
	var second: PackedStringArray = await _record_around(level, func() -> void:
		_aim_at(aim, gate)
		_drv.activate())
	why = _join(why, _why(TriggerEquiv.compare(node.get("second", []), second)))
	if not why.is_empty():
		_row(num, id, act, kind, "use", FAIL, _join("second: " + why, shared))
		return
	# From outside the reach, nothing.
	var out: Dictionary = _stand_out(level, ep, mode, id)
	if bool(out["ok"]):
		_reset(level, _snap)
		var none: PackedStringArray = await _stand_and_record(level, out["feet"], aim, gate, 1)
		if none.size() > 0:
			_row(num, id, act, kind, "use", FAIL,
				"out of reach it still did %s" % " ".join(none))
			return
	_row(num, id, act, kind, "use", PASS, "")

## A state-04 prop carrying an 0xEF act: the key at it must do nothing.
func _check_dead_gate(level, node: Dictionary, num: int, id: int, act: int,
		kind: String) -> void:
	var ep: Vector3 = _epos(level, id)
	var spot: Dictionary = _stand_in(level, ep,
		{"radius": Rules.PROX_GATE_RADIUS, "pad": Rules.PLAYER_RADIUS,
		 "origin": "eye", "metric": "3d"})
	if not bool(spot["ok"]):
		_row(num, id, act, kind, "dead", UNREACHABLE, String(spot["why"]))
		return
	var got: PackedStringArray = await _stand_and_record(level, spot["feet"], ep, true, 1)
	if got.is_empty():
		_row(num, id, act, kind, "dead", PASS, "")
	else:
		_row(num, id, act, kind, "dead", FAIL,
			"a state-04 prop answered the key with %s" % " ".join(got))

# --- walking in (0xF1 / 0xF2) -----------------------------------------
func _check_prox(level, node: Dictionary, num: int, id: int, act: int,
		kind: String, mode: Dictionary) -> void:
	var ep: Vector3 = _epos(level, id)
	var inside: Dictionary = _stand_in(level, ep, mode, 0.0, id)
	if not bool(inside["ok"]):
		_row(num, id, act, kind, "prox", UNREACHABLE, String(inside["why"]))
		return
	var shared: String = "shared with another trigger" if bool(inside.get("shared", false)) else ""
	var outside: Dictionary = _stand_out(level, ep, mode, id)
	var from: Vector3 = outside["feet"] if bool(outside["ok"]) else Vector3.INF
	var first: PackedStringArray = await _walk_in(level, from, inside["feet"], ep)
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), first))
	why = _join(why, _mover_truth(level, node.get("first", [])))
	if not why.is_empty():
		_row(num, id, act, kind, "prox", FAIL, _join(why, shared))
		return
	await _settle(level)
	# Out and in again: the port's latch says nothing happens until a
	# chain re-arms it, and the graph's second activation says the same.
	var second: PackedStringArray = await _walk_in(level, from, inside["feet"], ep)
	why = _why(TriggerEquiv.compare(node.get("second", []), second))
	if not why.is_empty():
		_row(num, id, act, kind, "prox", FAIL, _join("re-entry: " + why, shared))
		return
	_row(num, id, act, kind, "prox", PASS, "")

## Stand outside, then walk in on the movement keys (or, when there is no
## floor to walk from or the way is blocked, be put there), and report
## what the bus heard on the way in.
func _walk_in(level, from: Vector3, to: Vector3, ep: Vector3) -> PackedStringArray:
	if from != Vector3.INF:
		_drv.place(from)
		_drv.face(ep)
		await _drv.frames(PRE_FRAMES)
	var bus = level.bus
	bus.record(true)
	bus.clear()
	if from != Vector3.INF:
		var got: float = await _drv.walk_toward(to, 45, 24.0)
		if got > 48.0:
			_drv.place(to)                       # the way was not walkable
	else:
		_drv.place(to)
	_drv.face(ep)
	await _drv.frames(ACT_FRAMES)
	var heard: Array = bus.take()
	bus.record(false)
	return TriggerEquiv.tokens(heard)

# --- exits (0xF0) ------------------------------------------------------
func _check_exit(level, node: Dictionary, num: int, id: int, act: int,
		kind: String, mode: Dictionary) -> void:
	var ep: Vector3 = _epos(level, id)
	# The key only reaches a doorway the player can SEE: ActionSystem
	# _reachable rays the sprite, and a shut door leaf blocks all four of
	# its lines. A doorway with no such place to stand is not a failure —
	# it is a door that has not been opened yet.
	var spot: Dictionary = _stand_in(level, ep, mode, 0.0, -1, true)
	if not bool(spot["ok"]):
		_row(num, id, act, kind, "exit", UNREACHABLE, String(spot["why"]))
		return
	# 1. Touching it must only ARM it — in DOS you walk into the truck and
	#    press the key at its rear doors; standing there does nothing.
	var touch: PackedStringArray = await _stand_and_record(level, spot["feet"], ep, true, 0)
	if _has_exit(touch):
		_row(num, id, act, kind, "exit", FAIL, "touching it took it")
		return
	# 2. The key takes it. The crosshair ray is aimed at the floor: an
	#    exit is a sprite with no collider, and a mesh behind it would
	#    answer the key instead (fly_camera._try_activate).
	var got: PackedStringArray = await _record_around(level, func() -> void:
		_drv.face(ep)
		_drv.look(main.player.rotation.y, -1.0)
		_drv.activate())
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), got))
	if not why.is_empty():
		var blocked: bool = not level.action._reachable(
			main.player.global_position - level.origin, ep - level.origin)
		# What the refused map change asked for, when there was one: an
		# exit that fired for the wrong map or the wrong marker set reads
		# as a missing token and an extra one, and this says which.
		var asked := PackedStringArray()
		for e in _exit_seen:
			asked.append("%d/%d" % [int(e[0]), int(e[1])])
		_row(num, id, act, kind, "exit", FAIL, _join(_join(why,
			"the line to it is blocked" if blocked else ""),
			("it asked for " + " ".join(asked)) if not asked.is_empty() else ""))
		return
	# 3. An exit a CHAIN switches on fires on the tick it is armed.
	_reset(level, _snap)
	var armed: PackedStringArray = await _record_around(level, func() -> void:
		level.action._armed[id] = true)
	if not _has_exit(armed):
		_row(num, id, act, kind, "exit", FAIL, "a chain-armed exit did not fire")
		return
	_row(num, id, act, kind, "exit", PASS, "")

static func _has_exit(tokens: PackedStringArray) -> bool:
	for t in tokens:
		if t.begins_with("exit"):
			return true
	return false

# --- shots (state bit 1 / bit 2) --------------------------------------
func _check_shot(level, node: Dictionary, num: int, id: int, act: int,
		kind: String, how: String) -> void:
	var a = level.action
	var aim: Vector3 = _aim_point(level, id)
	if aim == Vector3.INF:
		_row(num, id, act, kind, how, UNREACHABLE, "nothing to aim at")
		return
	var spot: Dictionary = _shooting_spot(level, id, aim)
	if not bool(spot["ok"]):
		_row(num, id, act, kind, how, UNREACHABLE, String(spot["why"]))
		return
	_drv.place(spot["feet"])
	_drv.face(aim)
	await _drv.frames(PRE_FRAMES)
	var bus = level.bus
	bus.record(true)
	bus.clear()
	var drained: bool = false
	for _i in SHOT_MAX:
		await _fire_once()
		if not a.is_damageable_off(id) or bus.history().size() > 0:
			break
	# A thousand-point generator is fifty rifle shots; the death bit is
	# what is being checked, not the barrel. The first shot above went the
	# whole way through the input path; the rest of the hit points are
	# taken off through the same ObjHit the bullet calls.
	if how == "shot_death" and a.is_damageable_off(id) and bus.history().is_empty():
		var left: float = float(a._hp.get(id, 0.0))
		if left > 0.0:
			drained = true
			a.on_player_hit(id, left)
	await _drv.frames(ACT_FRAMES)
	var got: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), got))
	why = _join(why, _mover_truth(level, node.get("first", [])))
	if not why.is_empty():
		_row(num, id, act, kind, how, FAIL, why + (" (drained)" if drained else ""))
		return
	_row(num, id, act, kind, how, PASS, "drained" if drained else "")

## One trigger pull, waited out: the weapon's own cool-down decides how
## often the key does anything (fly_camera._fire_cd).
func _fire_once() -> void:
	_drv.fire()
	await _drv.frames(2)
	var guard: int = 0
	while float(main.player.get("_fire_cd")) > 0.0 and guard < 60:
		guard += 1
		await _drv.physics(1)

# --- the countdown relay (0x2C) ---------------------------------------
func _check_relay(level, node: Dictionary, num: int, id: int, act: int,
		kind: String, mode: Dictionary) -> void:
	var a = level.action
	var e = level.map.entities_by_off.get(id)
	if e == null:
		_row(num, id, act, kind, "counter", FAIL, "no record")
		return
	var at: int = int(mode.get("at", Rules.RELAY_AT))
	var got: PackedStringArray = await _record_around(level, func() -> void:
		e.state_byte |= 1                        # what a chain does to it
		if level.behaviour != null:
			var n: Node = level.behaviour.node(id)
			if n != null:
				level.behaviour.set_state(n, e.state_byte)
		a.objectives_left = at)
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), got))
	_row(num, id, act, kind, "counter", FAIL if not why.is_empty() else PASS, why)

# --- a vehicle that drives a marker path ------------------------------
func _check_path(level, node: Dictionary, num: int, id: int, act: int,
		kind: String) -> void:
	var a = level.action
	var v: Dictionary = a._path_vehicles.get(id, {})
	if v.is_empty():
		_row(num, id, act, kind, "path", UNREACHABLE, "no vehicle was built for it")
		return
	var nd: Node3D = v["node"]
	if nd == null or not is_instance_valid(nd):
		_row(num, id, act, kind, "path", UNREACHABLE, "the vehicle is gone")
		return
	# The DOS engine only ticks actors in the five grid cells round the
	# player (0x12980f), so the path is watched from beside it.
	var was: Vector3 = nd.position
	# Beside the vehicle, on whatever it is standing over: the DOS engine
	# only ticks actors in the five grid cells round the player, so a path
	# watched from the lever that starts it never moves at all.
	var beside: Vector3 = nd.global_position + Vector3(0.0, 0.0, 256.0)
	var floor_at: Vector3 = _floor_under(beside, 600.0)
	_drv.place(floor_at if floor_at != Vector3.INF else beside)
	await _drv.frames(PRE_FRAMES)
	# Standing beside it is already enough for the DOS window, and the
	# vehicle picks its path up on the first tick it is in — before the
	# recording would have started. Put it back at the head and take the
	# measurement from there.
	v["tgt"] = 0
	v["spd"] = 0.0
	v["tspd"] = 0.0
	was = nd.position
	var bus = level.bus
	bus.record(true)
	bus.clear()
	var e = level.map.entities_by_off.get(id)
	if e != null:
		a._flip_link(e)                          # the lever that starts it
	for _i in 180:
		await _drv.physics(1)
		if nd.position.distance_to(was) > 80.0:
			break
	var got: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	var moved: float = nd.position.distance_to(was)
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), got))
	if moved <= 80.0:
		why = _join(why, "it moved %.0f units in three seconds" % moved)
	_row(num, id, act, kind, "path", FAIL if not why.is_empty() else PASS, why)

# ---------------------------------------------------------------------
# Driving and recording
# ---------------------------------------------------------------------
## Stand at `feet` looking at `aim`, let whatever else is there go off,
## then record: `keys` presses of the activate key, and ACT_FRAMES of the
## game running.
func _stand_and_record(level, feet: Vector3, aim: Vector3, floor_aim: bool,
		keys: int) -> PackedStringArray:
	_drv.place(feet)
	_aim_at(aim, floor_aim)
	await _drv.frames(PRE_FRAMES)
	return await _record_around(level, func() -> void:
		for _i in keys:
			_drv.activate())

## Turn toward `aim`; with `floor_aim` put the crosshair on the ground
## instead, so the use key reaches the entity by the DOS route (the
## proximity sweep) and not by the port's crosshair ray.
func _aim_at(aim: Vector3, floor_aim: bool) -> void:
	_drv.face(aim)
	if floor_aim:
		_drv.look(main.player.rotation.y, -1.2)

## Record the bus while `doit` runs and the game takes ACT_FRAMES more.
func _record_around(level, doit: Callable) -> PackedStringArray:
	var bus = level.bus
	bus.record(true)
	bus.clear()
	doit.call()
	await _drv.frames(ACT_FRAMES)
	var heard: Array = bus.take()
	bus.record(false)
	return TriggerEquiv.tokens(heard)

## Wait for every mover the last activation started to arrive (they clear
## their own bit on arrival), so the next activation is the graph's
## "second" and not the rest of the first. A continuous rotator (family
## rot with no angle in its slot) never arrives and is not waited for.
func _settle(level) -> void:
	var a = level.action
	for _i in SETTLE_FRAMES:
		var moving: bool = false
		for off in a._movers:
			var m: Dictionary = a._movers[off]
			if String(m["family"]) == "rot" and float(m["limit"]) == 0.0:
				continue
			if bool(m.get("running", false)):
				moving = true
				break
		if not moving:
			break
		await _drv.physics(1)
	await _drv.frames(1)

# ---------------------------------------------------------------------
# Where to stand
# ---------------------------------------------------------------------
## A place the player can stand that satisfies the node's own measure —
## the graph says where it is measured from (feet or eye), how (3D, or
## horizontally with a vertical window) and how far.
## `cap` narrows the SEARCH (never the measure): a wall button is
## operated by looking at it or by standing at it, so there is no point
## looking for a floor a thousand units away just because its 0xF2 slot
## says so.
func _stand_in(level, ep: Vector3, mode: Dictionary, cap: float = 0.0,
		alone: int = -1, sight: bool = false) -> Dictionary:
	var r: float = float(mode.get("radius", Rules.PROX_GATE_RADIUS)) \
		+ float(mode.get("pad", 0.0))
	var search: float = minf(r, cap) if cap > 0.0 else r
	var shared: Dictionary = {}
	for frac in RING_FRACTIONS:
		for d in RING:
			var at := Vector3(ep.x + d.x * search * frac, ep.y, ep.z + d.y * search * frac)
			for feet in _floors_under(at, search):
				if not _measures(feet, ep, mode, r):
					continue
				if not _fits(feet):
					continue
				if sight and not level.action._reachable(feet - (level.origin as Vector3),
						ep - (level.origin as Vector3)):
					continue                      # a shut door leaf in the way
				if alone >= 0 and not _alone_at(feet, alone):
					if shared.is_empty():
						shared = {"ok": true, "feet": feet, "why": "", "shared": true}
					continue
				return {"ok": true, "feet": feet, "why": "", "shared": false}
	if not shared.is_empty():
		return shared
	return {"ok": false, "feet": Vector3.INF, "shared": false,
		"why": ("no floor with a clear line inside the %.0f-unit measure" % r) if sight
			else ("no floor inside the %.0f-unit measure" % r)}

## Is this the ONLY proximity trigger the player would be standing in?
func _alone_at(feet: Vector3, mine: int) -> bool:
	var eye: Vector3 = feet + Vector3(0.0, EYE, 0.0)
	for row in _prox_world:
		if int(row[0]) == mine:
			continue
		if eye.distance_to(row[1] as Vector3) <= float(row[2]):
			return false
	return true

## …and one just outside it, for the checks that say nothing must happen
## there.
func _stand_out(level, ep: Vector3, mode: Dictionary, alone: int = -1) -> Dictionary:
	var r: float = float(mode.get("radius", Rules.PROX_GATE_RADIUS)) \
		+ float(mode.get("pad", 0.0))
	for extra in [OUTSIDE_PAD, OUTSIDE_PAD + 60.0, OUTSIDE_PAD + 180.0]:
		for d in RING:
			if d == Vector2.ZERO:
				continue
			var at := Vector3(ep.x + d.x * (r + extra), ep.y, ep.z + d.y * (r + extra))
			var feet: Vector3 = _floor_under(at, r + extra)
			if feet == Vector3.INF:
				continue
			if _measures(feet, ep, mode, r):
				continue                          # still inside: not the place
			if alone >= 0 and not _alone_at(feet, -1):
				continue                          # inside somebody else's reach
			if _fits(feet):
				return {"ok": true, "feet": feet, "why": ""}
	return {"ok": false, "feet": Vector3.INF, "why": "nowhere outside it to stand"}

## The node's own measure, applied to a pair of positions.
## (The eye sits LIFT higher than the floor point, because that is where
## `place` puts the body — measuring from the floor itself said a gate
## was in reach that the running game then measured out of it.)
func _measures(feet: Vector3, ep: Vector3, mode: Dictionary, r: float) -> bool:
	var from: Vector3 = feet + Vector3(0.0, EYE + PlayerDriver.LIFT, 0.0) \
		if String(mode.get("origin", "eye")) == "eye" else feet
	if String(mode.get("metric", "3d")) == "2d+window":
		if absf(from.y - ep.y) > float(mode.get("window", Rules.PROX_VERTICAL_WINDOW)):
			return false
		return Vector2(from.x - ep.x, from.z - ep.z).length() <= r
	return from.distance_to(ep) <= r

## The floors in this column near the node's own height, nearest to it
## first. SEVERAL, because one ray is not enough: a trigger stands under
## a ceiling and over a deck that has another deck under it, and a ray
## that starts high enough to clear the lintel meets the roof first — the
## roof is flat and would read as somewhere to stand. The solver's flood
## does the same thing for the same reason (mission_solver._lands).
func _floors_under(at: Vector3, reach: float) -> Array:
	var out: Array = []
	var y: float = at.y + minf(maxf(reach, 100.0), 260.0)
	var bottom: float = at.y - maxf(reach, 160.0) - 400.0
	for _i in 4:
		var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, y, at.z),
			Vector3(at.x, bottom, at.z))
		q.exclude = [main.player.get_rid()]
		q.collision_mask = main.player.collision_mask
		q.hit_back_faces = true                   # a deck face turned down
		q.collide_with_areas = false
		var hit := _space.intersect_ray(q)
		if not hit.has("position"):
			break
		var p: Vector3 = hit["position"]
		if absf((hit["normal"] as Vector3).y) >= FLOOR_MIN_NY:
			out.append(p)
		y = p.y - 2.0
		if y <= bottom:
			break
	# Nearest the node's own height first: a trigger is meant to be stood
	# at, not under.
	out.sort_custom(func(a, b): return absf((a as Vector3).y - at.y) < absf((b as Vector3).y - at.y))
	return out

## The one floor a caller that wants a single answer gets.
func _floor_under(at: Vector3, reach: float) -> Vector3:
	var all: Array = _floors_under(at, reach)
	return all[0] if not all.is_empty() else Vector3.INF

## Does the player's own capsule stand free here?
func _fits(feet: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _shape
	q.transform = Transform3D(Basis(), feet + Vector3(0.0, _shape_y + PlayerDriver.LIFT, 0.0))
	q.collision_mask = main.player.collision_mask
	q.exclude = [main.player.get_rid()]
	q.collide_with_areas = false
	return _space.intersect_shape(q, 1).is_empty()

## The middle of the node's mesh — what a shot is aimed at.
func _aim_point(level, id: int) -> Vector3:
	var n = level.action._nodes.get(id)
	if n != null and is_instance_valid(n) and n is MeshInstance3D \
			and (n as MeshInstance3D).mesh != null:
		var mi: MeshInstance3D = n
		return mi.global_transform * mi.mesh.get_aabb().get_center()
	return _epos(level, id)

## A place with a clear line at `aim` whose first collider is the node
## itself — where a player could actually shoot it from.
func _shooting_spot(level, id: int, aim: Vector3) -> Dictionary:
	var target = level.action._nodes.get(id)
	for dist in SHOT_DISTANCES:
		for d in RING:
			if d == Vector2.ZERO:
				continue
			var at := Vector3(aim.x + d.x * dist, aim.y, aim.z + d.y * dist)
			for feet in _floors_under(at, dist):
				if not _fits(feet):
					continue
				var q := PhysicsRayQueryParameters3D.create(feet + Vector3(0.0, EYE, 0.0), aim)
				q.collide_with_areas = true
				q.exclude = [main.player.get_rid()]
				var hit := _space.intersect_ray(q)
				if not hit.has("collider"):
					continue
				var c = hit["collider"]
				while c != null and c is Node:
					if c == target:
						return {"ok": true, "feet": feet, "why": ""}
					c = (c as Node).get_parent()
	return {"ok": false, "feet": Vector3.INF, "why": "no line of fire to it"}

## The port's one surviving invented rule (rules_skynet._modes): a named
## variant-1 mesh with state bit 3 answers the use key, not the walk.
func _is_wall_button(level, id: int) -> bool:
	var e = level.map.entities_by_off.get(id)
	if e == null:
		return false
	return (e.flags & 3) == 1 and (e.state_byte & 8) != 0 and e.name_index >= 0

func _epos(level, id: int) -> Vector3:
	var e = level.map.entities_by_off.get(id)
	if e == null:
		return Vector3.INF
	return Vector3(float(e.x), -float(e.y), -float(e.z)) + (level.origin as Vector3)

# ---------------------------------------------------------------------
# What the movers really did
# ---------------------------------------------------------------------
## Every move token the graph promised, checked against the mover itself:
## the travel within a unit (or half an angle unit), the enable bit down
## and the direction flipped, as the DOS handlers leave them on arrival.
## "" when they all agree.
func _mover_truth(level, want: Array) -> String:
	var a = level.action
	var bad := PackedStringArray()
	for t in want:
		var tok: String = String(t)
		if not tok.begins_with("move@"):
			continue
		var id: int = tok.substr(5, 5).hex_to_int()
		var m: Dictionary = a._movers.get(id, {})
		if m.is_empty():
			bad.append("%05x is no mover here" % id)
			continue
		var travel: float = float(tok.split("+")[-1]) if tok.find("+") > 0 \
			else -float(tok.split("-")[-1])
		var span: float = absf(float(m["limit"]))
		if String(m["family"]) == "slide5f":
			span = absf(float(int(m["limit"]) << 4))
		if absf(span - absf(travel)) > 0.5:
			bad.append("%05x travels %.0f, not %.0f" % [id, span, absf(travel)])
	return " ".join(bad)

## …and once they have arrived: the DOS handlers clear their own enable
## bit at the end of the travel and the next trigger runs them back, so
## the bit must be down and the direction flipped. Continuous rotators
## never arrive and are left out.
func _mover_settled(level, want: Array) -> String:
	var a = level.action
	var bad := PackedStringArray()
	for t in want:
		var tok: String = String(t)
		if not tok.begins_with("move@"):
			continue
		var id: int = tok.substr(5, 5).hex_to_int()
		var m: Dictionary = a._movers.get(id, {})
		var e = level.map.entities_by_off.get(id)
		if m.is_empty() or e == null:
			continue
		if String(m["family"]) == "rot" and float(m["limit"]) == 0.0:
			continue
		if (int(e.state_byte) & 1) != 0:
			bad.append("%05x still enabled after its travel" % id)
		elif float(m["dir"]) > 0.0:
			bad.append("%05x did not flip its direction" % id)
	return " ".join(bad)

# ---------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------
func _row(num: int, id: int, act: int, kind: String, mode: String,
		res: String, why: String) -> void:
	_rows.append({"map": num, "id": id, "act": act, "kind": kind,
		"mode": mode, "res": res, "why": why})
	if res == FAIL:
		print("[verify] FAIL %d @%05x act %02X %s/%s — %s"
			% [num, id, act, kind, mode, why])

static func _why(res: Dictionary) -> String:
	if bool(res.get("ok", false)):
		return ""
	var parts := PackedStringArray()
	var missing: PackedStringArray = res.get("missing", PackedStringArray())
	var extra: PackedStringArray = res.get("extra", PackedStringArray())
	if not missing.is_empty():
		parts.append("missing " + " ".join(missing))
	if not extra.is_empty():
		parts.append("extra " + " ".join(extra))
	return "; ".join(parts)

static func _join(a: String, b: String) -> String:
	if a.is_empty():
		return b
	if b.is_empty():
		return a
	return a + "; " + b

# ---------------------------------------------------------------------
# The known-failure list
# ---------------------------------------------------------------------
## tests/rules/skynet.xfail: one line per known failure,
##   <map> <id> <act> <kind> <tag>
## ids lower hex, act bytes upper hex, the tag one word. Facts only — no
## names, no paths, none of the game's own words (hygiene, below).
func _load_xfail() -> void:
	if not FileAccess.file_exists(XFAIL_PATH):
		return
	for raw in FileAccess.get_file_as_string(XFAIL_PATH).split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var tok: PackedStringArray = line.split(" ", false)
		if tok.size() < 5:
			continue
		_xfail["%d %s" % [int(tok[0]), tok[1]]] = String(tok[4])

static func xfail_key(num: int, id: int) -> String:
	return "%d %05x" % [num, id]

## The permitted vocabulary of the xfail file — the same discipline the
## lock keeps (trigger_lock.hygiene): numbers, hex ids, the kind names
## the rules module has and a tag out of the list below, nothing else.
## What a pinned failure is, in one word:
##   exit_chain_skipped    a gate whose chain ends in a doorway takes the
##                         doorway without walking the chain, because
##                         standing there had already armed it by touch —
##                         the door sound and everything else on the way
##                         is lost (ActionSystem._use_exit)
##   port_use_reach        the key still fires it from outside the DOS
##                         measure: use_nearby's 130 units, or
##                         activate_teleport's 90 + 60
##   destruct_stage_count  the graph promises one damage stage per enable;
##                         the object's TRANSFRM.PRS entry has fewer (or
##                         none at all, and DOS does nothing either)
##   second_activation     the first activation agrees and the second does
##                         not
##   chain_silent          nothing happened at all where the graph says
##                         something should
##   chain_short           the chain did less than the walk says
##   chain_extra           …or more
##   path_window           a marker-path vehicle only picks its path up
##                         inside the DOS five-cell actor window, which
##                         the graph does not model
##   demolish_once         act 0x1B kills the prop once; the graph counts
##                         a second kill
##   loop_no_handler       the graph emits an 0xEE ambient loop and the
##                         runtime's SoundLoop node has no handler
##   button_walk           a wall button answered the walk, not the key
const XFAIL_TAGS: PackedStringArray = [
	"exit_chain_skipped", "port_use_reach", "destruct_stage_count",
	"second_activation", "chain_silent", "chain_short", "chain_extra",
	"path_window", "demolish_once", "loop_no_handler", "button_walk",
]

static func hygiene(text: String) -> PackedStringArray:
	var bad := PackedStringArray()
	var kinds: PackedStringArray = Rules.KINDS
	for raw in text.split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("#"):
			if line != XFAIL_HEAD[0] and line != XFAIL_HEAD[1]:
				bad.append(line)
			continue
		var tok: PackedStringArray = line.split(" ", false)
		if tok.size() != 5:
			bad.append(line)
			continue
		if not tok[0].is_valid_int() or tok[1].to_lower() != tok[1] \
				or tok[2].to_upper() != tok[2] or not kinds.has(tok[3]) \
				or not XFAIL_TAGS.has(tok[4]):
			bad.append(line)
	return bad

const XFAIL_HEAD: PackedStringArray = [
	"# known failures - map, id, act, kind, tag; the gate gives only on a new one",
	"# ids lower hex, act bytes upper hex; keywords and numbers only",
]

# ---------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------
func _report() -> void:
	var by_res: Dictionary = {}
	var fails: Array = []
	var new_fails: Array = []
	var fixed: Dictionary = _xfail.duplicate()
	for r in _rows:
		var row: Dictionary = r
		var res: String = String(row["res"])
		by_res[res] = int(by_res.get(res, 0)) + 1
		if res != FAIL:
			continue
		fails.append(row)
		var key: String = xfail_key(int(row["map"]), int(row["id"]))
		if _xfail.has(key):
			fixed.erase(key)
		else:
			new_fails.append(row)
	var secs: float = float(Time.get_ticks_msec() - _t0) / 1000.0
	print("[verify] %d checks: %d PASS, %d FAIL (%d new), %d UNREACHABLE, %d SKIP in %.0f s"
		% [_checks, int(by_res.get(PASS, 0)), int(by_res.get(FAIL, 0)),
		   new_fails.size(), int(by_res.get(UNREACHABLE, 0)),
		   int(by_res.get(SKIP, 0)), secs])
	# What failed, grouped by the first thing that went wrong — a hundred
	# lines of the same missing token are one finding, not a hundred.
	var groups: Dictionary = {}
	for row in fails:
		var g: String = _group_of(row)
		if not groups.has(g):
			groups[g] = []
		(groups[g] as Array).append(row)
	var keys: Array = groups.keys()
	keys.sort_custom(func(x, y): return (groups[x] as Array).size() > (groups[y] as Array).size())
	for g in keys:
		var list: Array = groups[g]
		var sample := PackedStringArray()
		for i in mini(list.size(), 4):
			sample.append("%d@%05x" % [int(list[i]["map"]), int(list[i]["id"])])
		print("[verify]   %4d  %-28s  %s" % [list.size(), g, " ".join(sample)])
	for row in new_fails:
		print("[verify] NEW %d @%05x act %02X %s — %s" % [int(row["map"]),
			int(row["id"]), int(row["act"]), String(row["kind"]), String(row["why"])])
	if not fixed.is_empty():
		print("[verify] %d pinned failure(s) no longer fail: %s"
			% [fixed.size(), " ".join(PackedStringArray(fixed.keys()))])
	_write_out()
	get_tree().quit(1 if not new_fails.is_empty() else 0)

## The short name of what went wrong, for the grouping above.
static func _group_of(row: Dictionary) -> String:
	var why: String = String(row["why"])
	var kind: String = String(row["kind"])
	if why.begins_with("second: "):
		return "%s second activation" % kind
	if why.begins_with("re-entry: "):
		return "%s re-entry" % kind
	if why.find("missing loop") >= 0:
		return "ambient loop never starts"
	if why.find("missing break@") >= 0:
		return "%s damage stage" % kind
	if why.find("missing move@") >= 0:
		return "%s mover silent" % kind
	if why.find("missing spin@") >= 0:
		return "%s rotator" % kind
	if why.find("extra ") == 0:
		return "%s did more" % kind
	if why.find("missing") >= 0:
		return "%s did less" % kind
	return "%s %s" % [kind, why.split(";")[0].split(" ")[0]]

## --verify-out=PATH: every row, one per line, for the triage.
func _write_out() -> void:
	var path: String = String(main._cli.get("verify-out", ""))
	if path.is_empty():
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[verify] cannot write %s" % path)
		return
	for r in _rows:
		var row: Dictionary = r
		f.store_line("%d %05x %02X %s %s %s %s" % [int(row["map"]), int(row["id"]),
			int(row["act"]), String(row["kind"]), String(row["mode"]),
			String(row["res"]), String(row["why"])])
	f.close()
	print("[verify] rows written: %s" % path)
