## Mission solver (`--solve`): plays a mission through the way a player
## has to — with collisions, never noclip — and reports whether it can be
## finished, and if not, exactly where it stops. Written when mission 5
## (the submarine, MAP.252) came back "cannot be finished" for about the
## tenth time: every earlier check was a hand-picked walk or a teleport,
## each proved one door, and none proved the mission.
##
##   godot --path . -- --map=MAP.252 --no-briefing --solve[=SECS] [--solve-out=DIR]
##   (headless works; the exit code is 0 for PASS and 1 for FAIL)
##
## Per map, in rounds:
##   1. FLOOD the space reachable from every point reached so far, on a
##      grid (32 u indoors, 64 outdoors) with the player's own capsule. A
##      cell counts when the capsule fits there on a floor no steeper than
##      the controller's 62°, reached by sweeping the capsule up (one step,
##      80 u at most), across and down. Under water it WALKS, on the
##      floor, as the DOS soldier does (FUN_0012c15d, fly_camera
##      _water_check): there is no swimming, no float and no stroke up; the
##      body is the short one the controller wears in the water, and the
##      one climb there is — a jump from the floor, 40 u in the water and
##      33 u with the head under (177/392 and 100/150) — is inside the
##      80 u step the sweeps already allow.
##   1b. WALK ONTO the walk-on pads that space reaches (state bit 0x10,
##      FUN_00139d5e): no key, the player only has to stand on the mesh.
##   2. FIRE what a player standing in that space can fire: walk-in gates
##      and levers (the player is put on the nearest reachable cell and the
##      the level tick does the rest), use-key buttons, and, when nothing
##      else is left, every destructible in sight is shot down.
##   3. Wait for the doors and lifts, and flood again.
## Once nothing new fires it takes an exit (0xF0) the space reaches,
## preferring maps it has not seen, and carries on on the next map. The
## run PASSES when the mission counter reaches zero. When it stalls it
## prints, for every exit, gate, button and objective it never reached,
## the nearest reachable cell, what stops the capsule on the way and
## whether a thinner body would get through, and writes a top view of the
## reachable space per map (--solve-out).
##
## Movement between cells is by capsule sweeps, not by the character
## controller itself; the route it prints is what to walk with --walk when
## the controller and the sweeps disagree.
##
## Putting the player somewhere and letting the game run N frames is the
## PLAYER DRIVER's (scripts/triggers/player_driver.gd, M3 step 4) — the
## same copy the trigger verifier drives the input path with, so the two
## cannot drift apart. What the solver does with it is unchanged: the
## spawn call with reset_state = false, and a wait on drawn AND physics
## frames.
##
## MISSION SCENES (the default; `--no-mission-scene` solves the old way).
## With the whole mission standing as one scene, a doorway is no longer a
## level change: the player is MOVED to the
## zone next door, which stands off on the +X grid with its records still in
## their own DOS coordinates. Nothing here changes but where things are —
## `_zone` is the active zone's origin and `_epos` puts every record in the
## world the sweeps walk (main._solver_level_ready calls level_ready() after
## a doorway and after a world is re-authored into a phase, exactly as it is
## called after a load). The run is reported by ZONE, and a mission ends
## inside the scene the same way it ends on a map: the counter reaches zero.
extends Node

const PlayerDriver := preload("res://scripts/triggers/player_driver.gd")
const ZoneLayers := preload("res://scripts/mission/zone_layers.gd")
const Rules := preload("res://scripts/triggers/rules_skynet.gd")

## 16, not 32: a player walks round the corner of a machine; on a 32 u
## grid the flood met MAP.252's boiler corner on every line to the gate
## behind it (101 u from the last cell, radius 86, 72 u for a player).
const CELL_INDOOR: float = 16.0
const CELL_OUTDOOR: float = 64.0
const Y_QUANT: float = 16.0
const MAX_NODES: int = 400000
const STEP: float = 80.0            # fly_camera.STEP_HEIGHT
const MAX_DROP: float = 1200.0
const FLOOR_MIN_NY: float = 0.766   # cos 40° — fly_camera.FOOT_MAX_SLOPE_DEG (DOS)
const LIFT: float = PlayerDriver.LIFT   # clearance under the capsule (safe_margin)
## "In the water" is the surface this far over the feet (fly_camera
## WATER_FEET_DEPTH, FUN_0012ea6b's -5) — where the body goes short.
const WATER_FEET: float = 5.0
const EYE: float = 75.0
const SHOOT_RANGE: float = 2500.0
const ROUNDS: int = 40
## How often a flood in progress says how far it has got.
const PROGRESS_MSEC: int = 5000
## How often the run may take a door it has already been through (_exits).
const RETAKE: int = 3
const SETTLE_MAX: float = 6.0
const BUCKET: float = 256.0
## How near a WALL BUTTON the solver stands before it presses the key
## (RulesSkynet.USE_REACH) — the one record the key reaches without a
## proximity measure of its own (Trigger.is_wall_button).
const USE_REACH: float = 130.0      # RulesSkynet.USE_REACH
## The use key is also the CROSSHAIR: fly_camera._try_activate rays this
## far from the eye and operates whatever mesh it hits, so a button across
## a room is pressed by looking at it — the hand reach above is only for
## the key pressed with nothing under the crosshair (behaviour.use_nearby).
const ACTIVATE_RAY: float = 600.0
## How far from an ARMED exit the use key still takes it —
## activate_teleport's TELEPORT_TOUCH_RADIUS, the same radius that arms the
## doorway by touch (2026-09-16: it used to be that plus a gate's 60, which
## reached further than anything in the original did).
const EXIT_REACH: float = 90.0
const V_WINDOW: float = 512.0       # Rules.PROX_VERTICAL_WINDOW
const DIRS: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]

var main = null                     # scripts/main.gd (untyped: its privates are read)
## Where the player is put and how frames are waited on — shared with the
## trigger verifier (scripts/triggers/player_driver.gd).
var _drv: RefCounted = null
## Where the level being solved stands (LevelLoader.Level.origin) — what
## _epos adds to take a record into the world the solver walks.
var _zone: Vector3 = Vector3.ZERO
var _space: PhysicsDirectSpaceState3D = null
var _q: PhysicsShapeQueryParameters3D = null
var _shape_y: float = 44.0
var _radius: float = 26.0
## The standing body, and the short one the controller wears in the water
## (fly_camera SWIM_BODY_HEIGHT = 44 — a collider, not a stroke: DOS has
## no swimming, and its body ignores ceilings).
const WET_BODY: float = 44.0
var _body_shape: CapsuleShape3D = null
var _wet_shape: CapsuleShape3D = null
var _exclude: Array[RID] = []
var _cell: float = CELL_INDOOR
## Is the level being solved an outdoor one? Outdoors the ground is a
## 256x256 heightmap with buildings standing ON it — one surface per column
## — and the map is 65536 units across; indoors it is stacked decks,
## catwalks and clutter in a few thousand. The flood is the same everywhere
## but its per-column effort is not (_lands, _flood, _why_not): the indoor
## thoroughness over an outdoor city is what made MAP.210 fail to finish a
## single round in 26 minutes (2026-09-11).
var _outdoor: bool = false
var _water: float = INF
var _lo: Vector3 = Vector3.ZERO
var _hi: Vector3 = Vector3.ZERO
## The map's own fence, in world x/z (LevelLoader.border_boxes, DOS
## FUN_00122711): every commit of the player's move has to land inside one
## of the boxes or it is undone and his speed zeroed
## (fly_camera._border_clamp) — MAP.260's invisible wall is this. So the
## ground beyond them is not ground a player can walk, and the flood used
## to spend its minutes out there: MAP.210's city is a corner of a
## 65536-unit desert. Empty = no fence to keep (no boxes, or the level was
## entered from outside them, where DOS lets the move stand too).
var _fence: Array = []
# One flood.
var _key: Dictionary = {}           # Vector3i → node index
var _pos: PackedVector3Array = PackedVector3Array()
var _bucket: Dictionary = {}        # Vector2i (BUCKET u) → Array of node indices
## Grid column (Vector2i in cells) → the feet heights already standing in
## it. Outdoors the flood asks this before it rays a neighbouring column,
## and spares the ray whenever the answer is already there (about four of
## a cell's eight neighbours, measured on MAP.210). The sweeps are the
## expensive part, not the rays — this is worth a few per cent, no more.
var _col: Dictionary = {}
var _capped: bool = false
# The whole run.
var _visited: Dictionary = {}       # "MAP.252#12" → true (entered by that marker set)
## "MAP.214:03002" → how often that door has been taken (_exits, RETAKE).
var _door_uses: Dictionary = {}
var _done: Dictionary = {}          # "MAP.252:p04057" → true (fired once)
## The entries (map#set) and doors taken since the last time something
## fired. A switch pressed anywhere can change what lies behind a door
## already walked through — MAP.284's computer core is what mission 8's
## upper control room on MAP.280 waits for, and that room is entered only
## from 284 — so progress makes every door worth one more look.
var _fresh: Dictionary = {}
var _seeds: Dictionary = {}         # map name → Array[Vector3] reached earlier
var _route: PackedStringArray = PackedStringArray()
var _t0: int = 0
var _running: bool = false
var _finished: bool = false

## Called by main after every level load while --solve is on.
func level_ready() -> void:
	if _finished:
		return
	if _drv == null:
		_drv = PlayerDriver.new()
		_drv.setup(main)
	var nm: String = main._level_name()
	if _t0 == 0:
		_t0 = Time.get_ticks_msec()
		_visited["%s#start" % nm] = true
		var lim_s: String = str(main._cli.get("solve", ""))
		var lim: float = float(lim_s) if lim_s.is_valid_float() and float(lim_s) > 10.0 else 1500.0
		get_tree().create_timer(lim).timeout.connect(func() -> void:
			if not _finished:
				print("[solve] RESULT FAIL — time limit %.0f s" % lim)
				_quit(1))
		print("[solve] solving from %s (time limit %.0f s)" % [nm, lim])
	_solve_map()

func _solve_map() -> void:
	if _running:
		return
	_running = true
	var nm: String = main._level_name()
	for _i in 12:                       # colliders registered, spawn settled
		await get_tree().physics_frame
	# A FORCED EDGE: arriving on MAP.250 from MAP.253 is the torpedo ride
	# (main._torpedo_step, FUN_00132e00) — the view swims out of the tube
	# and the game itself moves on to MAP.254 set 0. Nothing on this map
	# is the player's to play; the next level_ready() is MAP.254's.
	if bool(main.torpedo_riding()):
		_route.append("%s: TORPEDO → MAP.254 set 0 (forced, FUN_00132e00)" % nm)
		print("[solve] %s: the torpedo ride — forced edge to MAP.254 set 0" % nm)
		_running = false
		return
	var lvl = main._current_level
	# The level the run is playing: its Behaviour branch is the DOS object
	# layer (the sweeps, the use key, the doorways), its trigger runtime
	# holds every byte play changes, and its MAP holds the records.
	var a = lvl
	var p = main.player
	p.set("god_mode", true)
	_setup(lvl)
	var entry: Vector3 = p.global_position
	var seeds: Array = _seeds.get(nm, [])
	seeds.append(entry)
	_seeds[nm] = seeds
	print("[solve] === %s  entry %s  water %s  cell %d  %s%s" % [nm, entry.snapped(Vector3.ONE),
		"-" if _water == INF else "%.0f" % _water, int(_cell),
		"outdoor" if lvl.is_outdoor else "indoor", _where()])
	var rounds: int = 0
	var shot: bool = false
	while rounds < ROUNDS:
		rounds += 1
		await _kill_enemies()
		# The water a chain moves (acts 0xd6-0xda: MAP.254's sewer valves)
		# stands where the last round left it, and what is under it with it.
		_water = float(main.player.water_level)
		var t: int = Time.get_ticks_msec()
		_flood(seeds)
		print("[solve] round %d: %d cells reachable%s (%d ms)" % [rounds, _pos.size(),
			" — NODE CAP HIT" if _capped else "", Time.get_ticks_msec() - t])
		if main._mission_done:
			_pass(nm)
			return
		var acts: Array = _candidates(a, nm, false)
		if acts.is_empty() and not shot:
			acts = _candidates(a, nm, true)   # shooting is the last resort
			shot = true
		elif not acts.is_empty():
			shot = false
		if acts.is_empty():
			# The toggles again: a few of them before leaving (MAP.280's
			# control room is four), many only when there is nowhere new to
			# go — a door not yet seen is the cheaper way on, and MAP.254's
			# valve maze is eight toggles and 36 floods of half a minute (it
			# is left by its exit, not solved twice).
			var ex: Array = _exits(a, nm)
			var last: bool = ex.is_empty() or int(ex[0]["score"]) <= 0
			if await _press_again(a, nm, seeds, not last):
				shot = false
				continue
			break
		for act in acts:
			await _perform(a, nm, act)
			seeds.append(act["at"])
			# A prop shot to pieces changes nothing behind a door; a wreck
			# with a chain, or any switch, may.
			if String(act["kind"]) != "shoot" or int(a.triggers.link(int(act["off"]))) > 0:
				_progress()
			# One switch at a time, as a player presses them: a chain that
			# reaches a mover while it is still travelling STOPS it where it
			# stands (Mover.mover_watch, the DOS bit taken away), so a burst
			# of presses over shared movers left MAP.280's consoles half way
			# and in no combination a player could make.
			if String(act["kind"]) != "shoot" and _moves_something(a, int(act["off"])):
				await _settle(a)
			if main._mission_done:
				await get_tree().create_timer(0.5).timeout
				_pass(nm)
				return
		await _settle(a)
	# --solve-stay: diagnose THIS map, never leave it (the report covers
	# only the map the run fails on, and a run that backs out of a flooded
	# deck never says why the deck ended).
	if main._cli.has("solve-stay"):
		print("[solve] --solve-stay: not leaving %s" % nm)
		_fail(nm, a)
		return
	# Nothing more fires here: leave by an exit this space reaches.
	for x in _exits(a, nm):
		_put(x["at"])
		await _frames(3)
		# Standing there may already have done it (a lever on the level's
		# tick), else the use key.
		if bool(a.behaviour.exit_taken()) 				or a.behaviour.activate_teleport(p.global_position, main._eye_position()):
			_visited[x["vkey"]] = true
			_fresh[x["vkey"]] = true
			_door_uses[x["dkey"]] = int(x["used"]) + 1
			_route.append("%s: EXIT → %s set %d from %s%s" % [nm, x["target"], x["set"],
				x["at"].snapped(Vector3.ONE), "  (the way back)" if int(x["score"]) < 0 else ""])
			print("[solve] exit @%05x → %s set %d (from %s)%s" % [x["off"], x["target"], x["set"],
				x["at"].snapped(Vector3.ONE), "  (the way back)" if int(x["score"]) < 0 else ""])
			_write_view(nm, a)
			_running = false
			return                      # main loads the map, level_ready() goes on
		var ex = a.map.entities_by_off.get(x["off"])
		var armed: bool = ex != null and a.triggers.enabled(ex.file_off)
		# world → zone-local: the measure is in the records' space.
		var line_ok: bool = ex != null \
			and a.behaviour.reachable(p.global_position - _zone, _epos(ex) - _zone)
		var by: String = ""
		if ex != null and not line_ok:
			# The same ray Behaviour.reachable casts: player → sprite + 40.
			var rq := PhysicsRayQueryParameters3D.create(p.global_position, _epos(ex) + Vector3(0.0, 40.0, 0.0))
			rq.collision_mask = ZoneLayers.world_mask()
			rq.exclude = [p.get_rid()]
			var h := _space.intersect_ray(rq)
			if h.has("collider"):
				by = " by %s at %s" % [_collider_name(h["collider"]), (h["position"] as Vector3).snapped(Vector3.ONE)]
		print("[solve]   exit @%05x in reach from %s but did not fire: armed=%s, line to it %s%s" % [
			x["off"], p.global_position.snapped(Vector3.ONE), armed, "clear" if line_ok else "BLOCKED", by])
	_fail(nm, a)

## Nothing new fires: press what was pressed before AGAIN, one at a time.
## A switch in this game is a toggle (the chain flips every mover on it),
## and a puzzle is a COMBINATION of them: MAP.280's upper control room
## slides its four consoles 280CMP04-07 with ten buttons that share them,
## and only some combinations open the gap to 280CMP08, mission 8's second
## objective. Pressing each once leaves whatever combination that makes;
## a player tries again. Each press that brings nothing new is pressed
## back. Once per map until something fires somewhere (`_repressed`,
## `_epoch`), so a map the run keeps coming back to does not pay for it
## every time.
var _repressed: Dictionary = {}
## How long one map's toggle search may take.
const PRESS_AGAIN_MSEC: int = 180000
## Up to this many distinct toggles are tried again before a map is left
## by a door it has seen; more only when there is no such door.
const CHEAP_TOGGLES: int = 4

func _press_again(a, nm: String, seeds: Array, cheap_only: bool = false) -> bool:
	var key: String = "%s@%d" % [nm, _epoch]
	if _repressed.has(key):
		return false
	# Only a switch whose chain moves something can open the way — a sound,
	# a light or a message pressed twice is the same room — and of switches
	# that move the SAME movers one will do: MAP.280's ten console buttons
	# are four different toggles.
	var by_set: Dictionary = {}
	for c in _candidates(a, nm, false, true):
		var ms: Array = _movers_of(a, int(c["off"]))
		if ms.is_empty():
			continue
		ms.sort()
		var sk: String = str(ms)
		if not by_set.has(sk):
			by_set[sk] = c
	var cands: Array = by_set.values().slice(0, 8)
	if cands.is_empty() or (cheap_only and cands.size() > CHEAP_TOGGLES):
		return false
	_repressed[key] = true
	print("[solve]   nothing new: trying the %d toggles used here again, one and two at a time" % cands.size())
	var base: int = _pos.size()
	var tries: Array = []
	for i in cands.size():
		tries.append([cands[i]])
	for i in cands.size():
		for j in range(i + 1, cands.size()):
			tries.append([cands[i], cands[j]])
	var t_start: int = Time.get_ticks_msec()
	for t in tries:
		if Time.get_ticks_msec() - t_start > PRESS_AGAIN_MSEC:
			print("[solve]   …gave the toggles %d s, nothing" % (PRESS_AGAIN_MSEC / 1000))
			break
		for act in t:
			await _perform(a, nm, act)
			await _settle(a)
		_water = float(main.player.water_level)
		_flood(seeds)
		# Something to fire, or real new ground — a console that moved a
		# few cells' worth either way is not a way on.
		if main._mission_done or _pos.size() > base + maxi(32, base / 20) 				or not _candidates(a, nm, false).is_empty():
			_progress()
			print("[solve]   …%s again opened something (%d → %d cells)" % [
				" + ".join(t.map(func(x): return "%s @%05x" % [x["what"], x["off"]])), base, _pos.size()])
			return true
		for act in t:
			await _perform(a, nm, act)      # back as it was
			await _settle(a)
	return false

## The movers the chain from `off` reaches (the live links).
func _movers_of(a, off: int) -> Array:
	var out: Array = []
	var cur: int = int(a.triggers.link(off))
	var seen: Dictionary = {}
	while cur > 0 and not seen.has(cur):
		seen[cur] = true
		if a.behaviour.has_mover(cur):
			out.append(cur)
		cur = int(a.triggers.link(cur))
	return out

## Does the chain from `off` reach a mover (the live links, as chain_exit
## walks them)?
func _moves_something(a, off: int) -> bool:
	return not _movers_of(a, off).is_empty()

## Everything the flood needs about this level.
func _setup(lvl) -> void:
	_zone = lvl.origin                  # zone-local ↔ world, for _epos
	_space = main.get_world_3d().direct_space_state
	var cs: CollisionShape3D = main.player.get_node_or_null("CollisionShape3D")
	var body: CapsuleShape3D = cs.shape as CapsuleShape3D if cs != null else null
	_shape_y = cs.position.y if cs != null else 44.0
	# The controller keeps safe_margin clear of every wall, so in a gap it
	# behaves as a body that much wider: sweep with radius + margin (and the
	# same over the head), on a shape of our own — _blocker thins it.
	var margin: float = float(main.player.get("safe_margin"))
	var shape := CapsuleShape3D.new()
	shape.radius = (body.radius if body != null else 16.0) + margin
	shape.height = (body.height if body != null else 88.0) + margin
	_radius = shape.radius
	_q = PhysicsShapeQueryParameters3D.new()
	_q.shape = shape
	_body_shape = shape
	_wet_shape = CapsuleShape3D.new()
	_wet_shape.radius = shape.radius
	_wet_shape.height = WET_BODY + margin
	_q.collide_with_areas = false
	_q.collision_mask = main.player.collision_mask
	_exclude_actors()
	_water = float(main.player.water_level)   # INF on a dry map — see _wet
	_cell = CELL_OUTDOOR if lvl.is_outdoor else CELL_INDOOR
	_outdoor = lvl.is_outdoor
	# The fence holds from the moment the player is inside a box — coming
	# in from outside one, DOS lets him be (_border_clamp), and so do we.
	_fence = []
	var boxes: Array = main._world_border_boxes(lvl)
	var at := Vector2(main.player.global_position.x, main.player.global_position.z)
	for b in boxes:
		if (b as Rect2).has_point(at):
			_fence = boxes
			print("[solve] fenced by %d border box(es), %s" % [boxes.size(), str(b)])
			break
	_lo = Vector3(INF, INF, INF)
	_hi = -_lo
	for e in lvl.map.entities:
		var ep := _epos(e)
		_lo = Vector3(minf(_lo.x, ep.x), minf(_lo.y, ep.y), minf(_lo.z, ep.z))
		_hi = Vector3(maxf(_hi.x, ep.x), maxf(_hi.y, ep.y), maxf(_hi.z, ep.z))
	var pad := Vector3(1500.0, 3000.0, 1500.0)
	_lo -= pad
	_hi += pad

func _exclude_actors() -> void:
	_exclude = [main.player.get_rid()]
	for en in get_tree().get_nodes_in_group("enemy"):
		if en is CollisionObject3D:
			_exclude.append((en as CollisionObject3D).get_rid())
	_q.exclude = _exclude

func _kill_enemies() -> void:
	await main.run_command("killall")
	await get_tree().physics_frame
	_exclude_actors()

# --- The flood -------------------------------------------------------------

## Cells the flood refused because they lie outside the level (indoors:
## nothing overhead), and the first such place — a hole in the geometry.
var _leaks: int = 0
var _leak_at: Vector3 = Vector3.INF
var _leak_from: Vector3 = Vector3.INF

func _flood(seeds: Array) -> void:
	_key.clear()
	_pos = PackedVector3Array()
	_bucket.clear()
	_col.clear()
	_capped = false
	_leaks = 0
	_leak_at = Vector3.INF
	var queue := PackedInt32Array()
	for s in seeds:
		var f: Vector3 = _seed_point(s)
		if f != Vector3.INF and not _key.has(_k(f)):
			queue.append(_add(f))
	var head: int = 0
	# A flood of a whole outdoor map is a minute of silence at best; it says
	# where it has got to, so a run that is merely slow is told from one
	# that is stuck (and so the cost of a change to the rules above shows).
	var t_last: int = Time.get_ticks_msec()
	while head < queue.size():
		if _pos.size() >= MAX_NODES:
			_capped = true
			break
		if Time.get_ticks_msec() - t_last >= PROGRESS_MSEC:
			t_last = Time.get_ticks_msec()
			print("[solve]   flooding: %d cells, %d still to walk" % [_pos.size(), queue.size() - head])
		var i: int = queue[head]
		head += 1
		var p: Vector3 = _pos[i]
		var ix: int = _gx(p.x)
		var iz: int = _gz(p.z)
		for d in DIRS:
			var tx: float = _wx(ix + d.x)
			var tz: float = _wz(iz + d.y)
			if tx < _lo.x or tx > _hi.x or tz < _lo.z or tz > _hi.z:
				continue
			if not _in_fence(tx, tz):
				continue                     # the move would be undone there
			if _outdoor and _known_step(Vector2i(ix + d.x, iz + d.y), p.y):
				continue                     # standing there already: the way on exists
			var moved: bool = false
			for landed in _lands(tx, tz, p.y):
				if _key.has(_k(landed)):
					moved = true             # reached already: the way on exists
				elif _passable(p, landed) and _inside(landed, p):
					queue.append(_add(landed))
					moved = true
			if not moved:
				# SQUEEZE into a gap narrower than the grid: the grid point
				# can stand where the capsule touches a side and the middle
				# of the gap does not. MAP.254's CORA4029 pipe to the valve
				# button [E] is 50-odd units wide inside for a 52 u body; the
				# controller slides to its middle and walks it, the columns
				# 6 and 10 units off-centre never fit. So try the point half
				# a cell to either side, and — once a cell stands off the
				# grid — straight on from where it stands; the cell keeps
				# that position (its key is still its grid cell's).
				for o in _squeeze_points(p, d, tx, tz):
					for landed in _lands(o.x, o.y, p.y):
						if _key.has(_k(landed)):
							moved = true
						elif _passable(p, landed) and _inside(landed, p):
							queue.append(_add(landed))
							moved = true
					if moved:
						break
			if not moved and _drops_away(tx, tz, p.y):
				# LEAP a gap: the ground in front falls away, and a player
				# takes a run and jumps it (DOS: run 400 u/s, jump 177 against
				# gravity 392 — under water 200, 100 and 150 — FUN_0012c15d,
				# FUN_0012be58). MAP.240's way onto the submarine is a jump off
				# the end of the swung crane arm onto the hull, 240 units of
				# harbour between them; the flood only ever walked and dropped.
				var dl: float = Vector2(d).length() * _cell
				var wet: bool = _wet(p.y)
				for k in range(2, 12):
					var jx: float = _wx(ix + d.x * k)
					var jz: float = _wz(iz + d.y * k)
					if not _in_fence(jx, jz) or float(k) * dl > _leap_reach(-LEAP_DROP, wet):
						break
					var got: bool = false
					for landed in _lands(jx, jz, p.y):
						var rel: float = landed.y - p.y
						if rel < -LEAP_DROP or float(k) * dl > _leap_reach(rel, wet):
							continue
						if _key.has(_k(landed)):
							got = true
						elif _leap_free(p, landed, wet) and _inside(landed, p):
							queue.append(_add(landed))
							got = true
					if got:
						break
			if not moved and _outdoor and _steep_below(tx, tz, p.y):
				# SLIDE down ground too steep to stand on. Past 40° the DOS
				# foot treats a face as a wall (0x12b192), and the controller
				# does too — downhill that wall is a slide: the body goes down
				# it to where the ground flattens. The flood had no floor in
				# that column at all and stopped at the top. MAP.250's sewer
				# mouth (set 92, mission 5's way out) is a ledge over the
				# harbour bowl, 53° down to the bottom and the one way on.
				for k in range(2, 8):
					var sx: float = _wx(ix + d.x * k)
					var sz: float = _wz(iz + d.y * k)
					if not _in_fence(sx, sz):
						break
					var got: bool = false
					for landed in _lands(sx, sz, p.y):
						if landed.y >= p.y - 8.0:
							continue             # not down the slope
						if _key.has(_k(landed)):
							got = true
						elif _passable(p, landed):
							queue.append(_add(landed))
							got = true
					if got:
						break
			if not moved and not _outdoor:
				# Step OVER something narrower than the body: no cell next
				# to MAP.252's 12 u cable duct fits a 40 u body, but the
				# controller crosses it in one stride (rise, cross, drop) —
				# under water as well, where it walks the same floor.
				#
				# Indoors only. Outdoors the grid is 64 u, so the same try
				# would leap 128 to 256 units — further than a player
				# strides — and it is the frontier's cost: every cell that
				# ends against a wall (a city is mostly walls) paid three
				# more columns of sweeps for nothing.
				for k in [2, 3, 4]:
					var fx: float = _wx(ix + d.x * k)
					var fz: float = _wz(iz + d.y * k)
					if not _in_fence(fx, fz):
						break
					var got: bool = false
					for landed in _lands(fx, fz, p.y):
						if not _key.has(_k(landed)) and _passable(p, landed) and _inside(landed, p):
							queue.append(_add(landed))
							got = true
					if got:
						break
	if _leaks > 0:
		print("[solve]   %d cells refused OUTSIDE the level (no roof overhead); the first escape is from %s to %s — a hole in the hull" % [
			_leaks, _leak_from.snapped(Vector3.ONE), _leak_at.snapped(Vector3.ONE)])

## The running jump (DOS numbers, fly_camera's): how far a take-off at run
## speed carries the body before it comes down `rel` units above (or,
## negative, below) where it left. 0 when that height is out of reach.
const RUN_SPEED: float = 400.0
const JUMP_V: float = 177.0
const GRAVITY: float = 392.0
## A landing further down than this is the ground the gap drops to — the
## flood gets there by falling — not the far side of it.
const LEAP_DROP: float = 400.0

func _leap_reach(rel: float, wet: bool) -> float:
	var v: float = 100.0 if wet else JUMP_V
	var g: float = 150.0 if wet else GRAVITY
	var run: float = RUN_SPEED * (0.5 if wet else 1.0)
	var disc: float = v * v - 2.0 * g * rel
	if disc < 0.0:
		return 0.0
	# The body's feet clear the far edge a little before the apex height
	# is lost: rel is measured at the feet, the capsule needs LIFT more.
	return run * (v + sqrt(disc)) / g

## Does the ground fall away in column (tx, tz) — no floor within a step
## under feet at `from_y`? The one place a jump is worth trying.
func _drops_away(tx: float, tz: float, from_y: float) -> bool:
	var hit := _ray(Vector3(tx, from_y + 2.0, tz), Vector3(tx, from_y - STEP - 2.0, tz))
	return hit.is_empty()

## The jump's arc, boxed: up by the jump's height at the take-off, across
## at that height, down onto the landing (resting on an edge is landing).
func _leap_free(a: Vector3, b: Vector3, wet: bool) -> bool:
	var v: float = 100.0 if wet else JUMP_V
	var g: float = 150.0 if wet else GRAVITY
	var apex: float = v * v / (2.0 * g)
	var top: float = a.y + apex
	if b.y + LIFT > top:
		return false
	if not _free(a, Vector3(0.0, apex, 0.0)):
		return false
	if not _free(Vector3(a.x, top, a.z), Vector3(b.x - a.x, 0.0, b.z - a.z)):
		return false
	var drop := Vector3(0.0, b.y - top + 0.5, 0.0)
	return _free(Vector3(b.x, top, b.z), drop) or _drop_rests(Vector3(b.x, top, b.z), drop)

## Is the first thing under column (tx, tz) ground too steep to stand on,
## and below feet at `from_y` — a slope going down, not a wall going up?
func _steep_below(tx: float, tz: float, from_y: float) -> bool:
	var hit := _ray(Vector3(tx, from_y + STEP + 2.0, tz), Vector3(tx, from_y - MAX_DROP, tz))
	if hit.is_empty():
		return false
	return absf((hit["normal"] as Vector3).y) < FLOOR_MIN_NY \
		and (hit["position"] as Vector3).y < from_y - 4.0

## Where else to try the step from `p` in direction `d` when the grid
## point (tx, tz) does not take the body: straight on from `p` itself when
## `p` stands off the grid, and, for a step along an axis, half a cell to
## either side of the grid point. Only the ones inside the fence.
func _squeeze_points(p: Vector3, d: Vector2i, tx: float, tz: float) -> Array:
	var out: Array = []
	var straight := Vector2(p.x + float(d.x) * _cell, p.z + float(d.y) * _cell)
	if absf(straight.x - tx) > 0.5 or absf(straight.y - tz) > 0.5:
		out.append(straight)
	if d.x == 0 or d.y == 0:
		var side := Vector2(float(d.y), float(d.x)) * (_cell * 0.45)   # stays in its own key
		out.append(Vector2(tx, tz) + side)
		out.append(Vector2(tx, tz) - side)
	return out.filter(func(v: Vector2) -> bool: return _in_fence(v.x, v.y))

## Indoors, a place with nothing over it is outside the level: a flood that
## slips through a seam walks round the hull in the void and "reaches"
## everything from outside (the first runs on MAP.252 did exactly that —
## 400 000 cells in a submarine of a few thousand).
func _inside(t: Vector3, from: Vector3) -> bool:
	if _outdoor:
		return true                      # outdoors the sky is open
	# Overhead AND underneath: under the hull the hull's own bottom is a
	# roof, so a roof alone let the void below the submarine in.
	var up := _ray_any(t + Vector3(0.0, EYE, 0.0), t + Vector3(0.0, 3000.0, 0.0))
	var down := _ray_any(t + Vector3(0.0, 10.0, 0.0), t - Vector3(0.0, 3000.0, 0.0))
	if not up.is_empty() and not down.is_empty():
		return true
	_leaks += 1
	if _leak_at == Vector3.INF:
		_leak_at = t
		_leak_from = from
	return false

## A ray that also hits the back of a face (a roof seen from below).
func _ray_any(from: Vector3, to: Vector3) -> Dictionary:
	var rq := PhysicsRayQueryParameters3D.create(from, to)
	rq.collision_mask = _q.collision_mask
	rq.exclude = _exclude
	rq.hit_back_faces = true
	rq.collide_with_areas = false
	return _space.intersect_ray(rq)

func _add(f: Vector3) -> int:
	var i: int = _pos.size()
	_pos.append(f)
	_key[_k(f)] = i
	var b := Vector2i(floori(f.x / BUCKET), floori(f.z / BUCKET))
	var arr: Array = _bucket.get(b, [])
	arr.append(i)
	_bucket[b] = arr
	var c := Vector2i(_gx(f.x), _gz(f.z))
	var ys: PackedFloat32Array = _col.get(c, PackedFloat32Array())
	ys.append(f.y)
	_col[c] = ys
	return i

## Is the x/z point inside the map's fence — somewhere the player's move
## would stand (fly_camera._inside_border)? True everywhere when the map
## has no fence to keep.
func _in_fence(x: float, z: float) -> bool:
	if _fence.is_empty():
		return true
	var p := Vector2(x, z)
	for b in _fence:
		if (b as Rect2).has_point(p):
			return true
	return false

## Is there already a cell in the column next door a step away from `y` —
## i.e. would _lands find its floor and the flood find it known? Outdoors
## that is the whole of it: the ground is one surface per column, so a
## known floor within a step IS the floor the ray would have returned, and
## the ray can be spared. (Indoors a column holds decks above and below one
## another and the ray has to run; this is only ever asked outdoors.)
func _known_step(col: Vector2i, y: float) -> bool:
	var ys = _col.get(col)
	if ys == null:
		return false
	for cy in (ys as PackedFloat32Array):
		if absf(cy - y) <= STEP and (_water == INF or cy >= _water - 1.0):
			return true
	return false

## The flood's grid is the ZONE's, not the world's: a cell sits on the
## same spot of the map whichever runtime stands it up. On the world grid
## a mission scene put every zone's cells wherever its origin fell —
## MAP.254 stands at x 44680, half a 16 u cell off — and the flood came to
## a different answer than on the map itself: its columns missed the foot
## of the catwalk ramp that leads out of the flooded pit by two units,
## and the run stayed at the bottom (2026-09-23).
func _gx(x: float) -> int:
	return roundi((x - _zone.x) / _cell)

func _gz(z: float) -> int:
	return roundi((z - _zone.z) / _cell)

func _wx(i: int) -> float:
	return float(i) * _cell + _zone.x

func _wz(i: int) -> float:
	return float(i) * _cell + _zone.z

## Grid key of a cell — a floor, dry or under water: nothing else is one.
func _k(f: Vector3) -> Vector3i:
	return Vector3i(_gx(f.x), roundi(f.y / Y_QUANT), _gz(f.z))

## Where a body put at `s` really is: on the floor under it — in the water
## too, where he sinks to it (MAP.250 set 10, 624 u under the harbour
## surface after the torpedo tube, is a fall to the bottom).
func _seed_point(s: Vector3) -> Vector3:
	var hit := _ray(s + Vector3(0.0, 40.0, 0.0), s - Vector3(0.0, MAX_DROP, 0.0))
	if hit.is_empty():
		return s
	return Vector3(s.x, (hit["position"] as Vector3).y, s.z)

## The feet positions a body at height `from_y` can end up at in column
## (tx, tz): up to three floors from one step above down to MAX_DROP
## below (a ray that starts inside a thick slab meets its underside
## first). A floor is any surface flat enough to stand on met from above,
## whichever way its face is turned — under the water as well as over it:
## the DOS soldier walks the bottom (fly_camera._water_check), and the
## flood used to float on the surface and swim at any depth instead.
func _lands(tx: float, tz: float, from_y: float) -> Array:
	var out: Array = []
	var top: float = from_y + STEP + 2.0
	var bottom: float = from_y - MAX_DROP
	var y: float = top
	# Three floors indoors — a ray that starts inside a thick slab meets its
	# underside first, and a deck has another under it. Outdoors ONE: the
	# terrain is a single heightmap and what stands on it is walked round,
	# not under, so the second and third rays only ever found the inside of
	# a building the flood reaches through its door anyway. A first hit too
	# steep to stand on is not the end of the column there either: the body
	# slides off it to whatever is under it.
	for _i in 3:
		if _outdoor and not out.is_empty():
			break
		var hit := _ray(Vector3(tx, y, tz), Vector3(tx, bottom, tz))
		if hit.is_empty():
			break
		var hp: Vector3 = hit["position"]
		if absf((hit["normal"] as Vector3).y) >= FLOOR_MIN_NY:
			out.append(Vector3(tx, hp.y, tz))
		y = hp.y - 2.0
		if y <= bottom:
			break
	return out

## Can the capsule get from cell `a` to cell `b`: up (one step), across,
## down — in the water the same, in the short body (_free).
func _passable(a: Vector3, b: Vector3) -> bool:
	return _why_not(a, b).is_empty()

## "" when the capsule gets from `a` to `b`, otherwise which sweep stopped it.
func _why_not(a: Vector3, b: Vector3) -> String:
	var lift: float = maxf(0.0, b.y - a.y)
	var across := Vector3(b.x - a.x, 0.0, b.z - a.z)
	# Rise, cross, drop — and when something lies BETWEEN the two floors,
	# rise higher and step over it, as the controller's step-up does (up
	# to STEP_HEIGHT). Crossing only at the far floor's height stopped the
	# flood at a 12 u ridge on the submarine's engine-room floor.
	var rise: float = lift
	var why: String = ""
	while true:
		var top: float = a.y + rise
		if rise > 0.5 and not _free(a, Vector3(0.0, rise, 0.0)):
			return why if not why.is_empty() else "rise %.0f" % rise
		if _free(Vector3(a.x, top, a.z), across):
			var drop: float = top - b.y
			# On a slope the round bottom of the capsule meets the floor
			# above the point under its axis, by r·(1/cos θ − 1): 8 u on the
			# steepest floor there is. The ray found the axis point, so the
			# sweep down stops that much short of it — MAP.214's corridor
			# ramp (27°) stopped every drop 3 u over the 4 u LIFT.
			var short: float = _radius * (1.0 / FLOOR_MIN_NY - 1.0)
			if drop <= short + 0.5 or _free(Vector3(b.x, top, b.z), Vector3(0.0, -(drop - short), 0.0)):
				return ""
			# Outdoors the column can be 64 u from the last one and its axis
			# already past the edge the body is let down onto: it comes to
			# rest on the edge, and a capsule whose axis is off an edge slides
			# off it — onto the ground the ray found. MAP.250 set 92 is the
			# sewer's mouth (SEWRENTR, the way out of mission 5): the next
			# column is 13 u lower and 7 u past the pipe's lip, the drop met
			# the lip, and the flood never left the pipe.
			if _outdoor and _drop_rests(Vector3(b.x, top, b.z), Vector3(0.0, -(drop - short), 0.0)):
				return ""
			why = "drop %.0f" % drop
		else:
			why = "across"
		if rise >= STEP - 0.5:
			return why
		# How finely the step-up is searched. Indoors 16 units — the ledges
		# and ducts a submarine is full of are that size. Outdoors 40: a
		# kerb, a step and the 80 u limit itself are all it has to find, and
		# six tries per blocked direction over a city is where the time went.
		rise = minf(rise + (40.0 if _outdoor else 16.0), STEP)
	return why

## One sweep, told in full: how far it got, and at the first contact
## which collider, where and facing which way.
func _sweep_detail(feet: Vector3, motion: Vector3) -> String:
	var start := feet + Vector3(0.0, _shape_y + LIFT, 0.0)
	_q.transform = Transform3D(Basis(), start)
	_q.motion = motion
	var r: PackedFloat32Array = _space.cast_motion(_q)
	if r.size() == 0 or r[0] >= 0.999:
		return "(free when repeated)"
	_q.transform = Transform3D(Basis(), start + motion * r[1])
	_q.motion = Vector3.ZERO
	var info: Dictionary = _space.get_rest_info(_q)
	if not info.has("collider_id"):
		return "[safe %.3f unsafe %.3f, no contact at the unsafe spot]" % [r[0], r[1]]
	return "[safe %.3f unsafe %.3f against %s at %s n=%s]" % [r[0], r[1],
		_collider_name(instance_from_id(int(info["collider_id"]))),
		(info["point"] as Vector3).snapped(Vector3(0.1, 0.1, 0.1)),
		(info["normal"] as Vector3).snapped(Vector3(0.01, 0.01, 0.01))]

## Why the flood does not go on from cell `p`: per direction, the floors
## found in the next column and what stops the capsule reaching each.
func _explain(p: Vector3) -> void:
	var ix: int = _gx(p.x)
	var iz: int = _gz(p.z)
	for d in DIRS:
		var tx: float = _wx(ix + d.x)
		var tz: float = _wz(iz + d.y)
		var parts := PackedStringArray()
		var lands: Array = _lands(tx, tz, p.y)
		if lands.is_empty():
			parts.append("no floor")
		for t in lands:
			var why: String = _why_not(p, t)
			if not why.is_empty():
				var lift: float = maxf(0.0, t.y - p.y)
				var top: float = p.y + lift
				if why.begins_with("rise"):
					why += " " + _sweep_detail(p, Vector3(0.0, lift, 0.0))
				elif why == "across":
					why += " " + _sweep_detail(Vector3(p.x, top, p.z), Vector3(t.x - p.x, 0.0, t.z - p.z))
				elif why.begins_with("drop"):
					why += " " + _sweep_detail(Vector3(t.x, top, t.z), Vector3(0.0, t.y - top, 0.0))
			if why.is_empty() and not _inside(t, p):
				why = "outside the level"
			if why.is_empty():
				why = "ok" + (" (known)" if _key.has(_k(t)) else " (NEW — not flooded?)")
			parts.append("floor y %.0f: %s" % [t.y, why])
		print("[solve]     from %s toward (%+d,%+d) → (%.0f, %.0f): %s" % [p.snapped(Vector3.ONE), d.x, d.y, tx, tz, "; ".join(parts)])

## Is `y` in the water — the surface at least WATER_FEET over the feet,
## where the controller puts the body in its short collider? A map with no
## water marker has no surface at
## all, and `_water` is then INF — under which "y < _water" is true of
## every height there is. Every water test goes through here, because the
## ones that did it by hand had the flood SWIMMING over every dry map in
## the game: a swimmer crosses a gap at any height it can rise to (there is
## no ceiling out of doors) and moves in three dimensions indoors, so the
## solver walked through the walls of MAP.210's compound and flew around
## the inside of MAP.213. What it called reachable was not.
func _wet(y: float) -> bool:
	return _water != INF and _water - y >= WATER_FEET

func _free(feet: Vector3, motion: Vector3) -> bool:
	# In the water (either end under the surface) the body is the short one.
	var wet: bool = _wet(feet.y) or _wet(feet.y + motion.y)
	_q.shape = _wet_shape if wet else _body_shape
	var cy: float = (WET_BODY * 0.5 if wet else _shape_y) + LIFT
	_q.transform = Transform3D(Basis(), feet + Vector3(0.0, cy, 0.0))
	_q.motion = motion
	var r: PackedFloat32Array = _space.cast_motion(_q)
	_q.shape = _body_shape
	return r.size() > 0 and r[0] >= 0.999

## Does a drop that `_free` refused end with the body SUPPORTED — the
## first contact under it, something it stands or slides on (a face or an
## edge below the round bottom), not a wall or a roof beside it?
func _drop_rests(feet: Vector3, motion: Vector3) -> bool:
	var wet: bool = _wet(feet.y) or _wet(feet.y + motion.y)
	_q.shape = _wet_shape if wet else _body_shape
	var start: Vector3 = feet + Vector3(0.0, (WET_BODY * 0.5 if wet else _shape_y) + LIFT, 0.0)
	_q.transform = Transform3D(Basis(), start)
	_q.motion = motion
	var r: PackedFloat32Array = _space.cast_motion(_q)
	var ok: bool = false
	if r.size() > 1 and r[0] < 0.999:
		_q.transform = Transform3D(Basis(), start + motion * r[1])
		_q.motion = Vector3.ZERO
		var info: Dictionary = _space.get_rest_info(_q)
		ok = info.has("normal") and (info["normal"] as Vector3).y >= 0.5
	_q.shape = _body_shape
	_q.motion = Vector3.ZERO
	return ok

func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var rq := PhysicsRayQueryParameters3D.create(from, to)
	rq.collision_mask = _q.collision_mask   # what the player's body meets, not the furniture
	rq.exclude = _exclude
	# The level's trimeshes collide from both sides (backface_collision),
	# and the submarine's engine-room doorway floor is a face turned
	# DOWN: the player stands on it, a front-faces-only ray fell through
	# it and the flood stopped at the hatch (2026-09-11).
	rq.hit_back_faces = true
	rq.collide_with_areas = false
	return _space.intersect_ray(rq)

## The reachable cell nearest `ep` within `reach` horizontally and the
## the doorways' vertical window; -1 when there is none.
func _nearest(ep: Vector3, reach: float, vwin: float = V_WINDOW) -> int:
	var best: int = -1
	var bd: float = INF
	if reach > 6000.0:
		for i in _pos.size():
			var d: float = _pos[i].distance_to(ep)
			if d < bd:
				bd = d
				best = i
		return best
	var r: int = int(ceil(reach / BUCKET))
	var bx: int = floori(ep.x / BUCKET)
	var bz: int = floori(ep.z / BUCKET)
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var arr = _bucket.get(Vector2i(bx + dx, bz + dz))
			if arr == null:
				continue
			for i in arr:
				var p: Vector3 = _pos[i]
				var dy: float = absf(p.y - ep.y)
				if dy > vwin:
					continue
				var h: float = Vector2(p.x - ep.x, p.z - ep.z).length()
				if h > reach:
					continue
				var d: float = h + dy * 0.25
				if d < bd:
					bd = d
					best = i
	return best

# --- What a player there can fire ------------------------------------------

## A spot the player can walk to from which a PROXIMITY record is in reach
## — 3D, from the eye, the way its own handler measures him
## (Trigger.prox_use / prox_watch). The plain _reach_point below
## measures horizontally inside a 512-unit vertical window, which is the
## doorways' rule and far too generous for these: MAP.210's tower lever
## stands 295 units over the ground at its foot, and the run pressed it
## from down there, through the crosshair, from outside anything the
## original measures.
##
## The cell's own eye, so what the solver proves is what the key does. A
## sweep toward the record (as _reach_point does for a doorway) is not
## worth it here: these sit on walls and the last few units are up, not
## along the floor.
func _reach_eye(ep: Vector3, reach: float) -> Vector3:
	var best: Vector3 = Vector3.INF
	var bd: float = reach
	var r: int = int(ceil((reach + _cell) / BUCKET))
	var bx: int = floori(ep.x / BUCKET)
	var bz: int = floori(ep.z / BUCKET)
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var arr = _bucket.get(Vector2i(bx + dx, bz + dz))
			if arr == null:
				continue
			for i in arr:
				var d: float = (_pos[i] + Vector3(0.0, EYE + LIFT, 0.0)).distance_to(ep)
				if d < bd:
					bd = d
					best = _pos[i]
	if best != Vector3.INF:
		return best
	# No cell's eye is in reach: walk up to it from the nearest ones, as
	# _reach_point does for a doorway. Outdoors the grid is 64 u and a
	# console bank is not: MAP.280's 280CMP08 (mission 8's second
	# objective, reach 86) stands behind the consoles 117 u from the
	# nearest cell's eye, and a player steps up to the bank to press it.
	var near: Array = []
	var span: float = reach + 3.0 * _cell
	var r2: int = int(ceil(span / BUCKET))
	for dx in range(-r2, r2 + 1):
		for dz in range(-r2, r2 + 1):
			var arr = _bucket.get(Vector2i(bx + dx, bz + dz))
			if arr == null:
				continue
			for i in arr:
				var e: Vector3 = _pos[i] + Vector3(0.0, EYE + LIFT, 0.0)
				if absf(e.y - ep.y) <= reach and Vector2(e.x - ep.x, e.z - ep.z).length() <= span:
					near.append([e.distance_to(ep), i])
	near.sort_custom(func(x, y): return x[0] < y[0])
	# Straight at it, and at points round it: the way in can be a gap
	# beside the thing rather than the line to it (the consoles again —
	# the gap they open is beside 280CMP03, not in front of CMP08).
	var aims: Array = [Vector2(ep.x, ep.z)]
	for rho in [reach * 0.45, reach * 0.75]:
		for k in 12:
			var ang: float = TAU * float(k) / 12.0
			aims.append(Vector2(ep.x + cos(ang) * rho, ep.z + sin(ang) * rho))
	for j in mini(near.size(), 8):
		var from: Vector3 = _pos[near[j][1]]
		for aim in aims:
			var dir := Vector3(aim.x - from.x, 0.0, aim.y - from.z)
			if dir.length() < 1.0:
				continue
			_q.transform = Transform3D(Basis(), from + Vector3(0.0, _shape_y + LIFT, 0.0))
			_q.motion = dir
			var res: PackedFloat32Array = _space.cast_motion(_q)
			_q.motion = Vector3.ZERO
			var stop: Vector3 = from + dir * (res[0] if res.size() > 0 else 0.0)
			if (stop + Vector3(0.0, EYE + LIFT, 0.0)).distance_to(ep) <= reach:
				return stop
	return Vector3.INF

## A spot the player can walk to within `reach` of `ep`: a reachable cell
## if one is close enough, otherwise the cell nearest the target and then
## as far toward it as the capsule sweeps. A player walks up to a door; he
## does not stop on a 32-unit grid (MAP.252's cabin-door gate 24SHAL3 is
## 86.1 u from the last cell, its radius 86, and 58 u from the door leaf).
func _reach_point(ep: Vector3, reach: float) -> Vector3:
	var n: int = _nearest(ep, reach)
	if n >= 0:
		return _pos[n]
	# Walk at it from the nearest cells, nearest first. From ONE cell was
	# not enough: the nearest can be the top of a bar counter, from which
	# the way is a wall (the r 14 run stayed in the cabin, r 16 got out).
	var near: Array = []
	var span: float = reach + 3.0 * _cell
	var r: int = int(ceil(span / BUCKET))
	var bx: int = floori(ep.x / BUCKET)
	var bz: int = floori(ep.z / BUCKET)
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var arr = _bucket.get(Vector2i(bx + dx, bz + dz))
			if arr == null:
				continue
			for i in arr:
				var p: Vector3 = _pos[i]
				var h: float = Vector2(p.x - ep.x, p.z - ep.z).length()
				if h <= span and absf(p.y - ep.y) <= V_WINDOW:
					near.append([h + absf(p.y - ep.y) * 0.25, i])
	near.sort_custom(func(x, y): return x[0] < y[0])
	for j in mini(near.size(), 12):
		var from: Vector3 = _pos[near[j][1]]
		var dir := Vector3(ep.x - from.x, 0.0, ep.z - from.z)
		var dist: float = dir.length()
		if dist < 1.0:
			continue
		var motion: Vector3 = dir / dist * maxf(dist - reach * 0.5, 0.0)
		_q.transform = Transform3D(Basis(), from + Vector3(0.0, _shape_y + LIFT, 0.0))
		_q.motion = motion
		var res: PackedFloat32Array = _space.cast_motion(_q)
		var stop: Vector3 = from + motion * (res[0] if res.size() > 0 else 0.0)
		if Vector2(stop.x - ep.x, stop.z - ep.z).length() <= reach and absf(stop.y - ep.y) <= V_WINDOW:
			return stop
	return Vector3.INF

func _candidates(a, nm: String, shoot: bool, again: bool = false) -> Array:
	var out: Array = []
	if shoot:
		for off in a.behaviour.damageable_offs():
			var k: String = "s%05x" % off
			if _done.has(nm + ":" + k):
				continue
			var e = a.map.entities_by_off.get(off)
			var n: int = _shooting_spot(a, off, _aim_point(a, off, e))
			if n >= 0:
				out.append({"kind": "shoot", "off": off, "key": k, "at": _pos[n], "what": _ename(a, e)})
		return out
	if not again:
		out.append_array(_pad_candidates(a, nm))
	for t in _prox_nodes(a):
		var e = a.behaviour.record_of(int(t.id))
		var k: String = "p%05x" % e.file_off
		if (_done.has(nm + ":" + k) != again) or a.triggers.spent(e.file_off):
			continue
		# The live bytes, which are the trigger runtime's (step 5a) — a
		# lever spent earlier in this run is not the lever the MAP file has.
		var act: int = a.triggers.act(e.file_off)
		var chain: bool = act == 0xF1 or act == 0xF2
		if chain and not a.triggers.enabled(e.file_off):
			continue                     # a spent lever
		var use_only: bool = t.is_wall_button()
		# A 0xEF gate is the USE KEY at a doorway, not a tripwire: its DOS
		# handler (0x1386a0) runs only in the frame ACTIVATE goes down, so
		# standing in one does nothing whatever. Walking into the eight that
		# ring MAP.217's jeep is what the solver did for [M3], and mission 1
		# could not be finished; a player presses the key there.
		var gate: bool = act == 0xEF and not use_only
		# A gate whose chain ends in a doorway is the key's way THROUGH it
		# (Behaviour.activate_teleport → use_exit_through): its press is a
		# map change, and the sweep's use edge passes it by on purpose
		# (Trigger.prox_watch). _exits offers it as a spot to take that
		# doorway from; pressing it here did nothing at all.
		if gate and a.behaviour.chain_exit(e.file_off) >= 0:
			continue
		# …and so is a LEVER whose chain ends in one: walking into it takes
		# the doorway (a chain arriving at an armed 0xF0 fires it, DOS
		# 0x138081) — mission 7's tunnel mouth @0df56 is one. Pressed here
		# the map changed under the round, and the rest of it played the
		# zone next door from the wrong place; _exits takes it as a door.
		if chain and a.behaviour.chain_exit(e.file_off) >= 0:
			continue
		# Where to stand. A gate or a lever is measured by its own handler,
		# 3D from the EYE (the trigger's own node since 2026-09-16), so the
		# spot has to satisfy that and not merely be near in plan: MAP.210's
		# tower levers stand three hundred units over the ground at their
		# foot. A WALL BUTTON is the exception the owner kept — the key
		# answers it instead of proximity — so for one of those the reach is
		# the hand's and then the crosshair's.
		var reach: float = float(t.measure())
		var at: Vector3 = _reach_point(_epos(e), USE_REACH) if use_only \
			else _reach_eye(_epos(e), reach)
		var kind: String = "use" if use_only else ("use-gate" if gate else "walk-in")
		if at == Vector3.INF and use_only:
			# Out of the hand's reach — but a BUTTON on the wall is operated
			# by LOOKING at it (ACTIVATE_RAY: the ray walks up to the mesh's
			# own node and activates it, whatever its act). MAP.214's
			# BUTTON01, the one that opens the doors to MAP.215 and so to
			# mission 1's [M1] and [M2], sits 163 units off round a wall
			# corner: no cell of the flood is within 130 of it, and plenty of
			# them can see it.
			var seen: int = _shooting_spot(a, e.file_off, _aim_point(a, e.file_off, e), ACTIVATE_RAY)
			if seen >= 0:
				at = _pos[seen]
		if at != Vector3.INF:
			out.append({"kind": kind, "off": e.file_off, "key": k,
				"at": at, "what": _ename(a, e)})
	# (A cue no chain points at used to be listed here too, as something the
	# key could read. The owner retired that port rule on 2026-09-15 and
	# nothing keeps that list any more — DOS has no use-key path to a cue,
	# so the solver has none either.)
	return out

## The WALK-ON PADS this space reaches: a mesh whose live state byte
## carries Rules.PAD_BIT is set off by standing on it — the foot mover
## hands the floor polygon's owner to FUN_00139d5e, which clears the bit
## and walks the chain once (Behaviour.walk_on, fly_camera._walk_on_floor).
## No key and no distance, so a use-key or walk-in candidate never covers
## one: MAP.215's silo cover opens as the player walks into the corridor.
## The spot is a reachable cell whose floor IS the pad's mesh.
func _pad_candidates(a, nm: String) -> Array:
	var out: Array = []
	if a.behaviour == null:
		return out
	for e in a.map.entities:
		if (e.flags & 3) != 1:
			continue
		var off: int = e.file_off
		var k: String = "w%05x" % off
		if _done.has(nm + ":" + k) or a.triggers.spent(off):
			continue
		if (int(a.triggers.state(off)) & Rules.PAD_BIT) == 0 \
				or int(a.triggers.act(off)) >= Rules.ACT_SPENT_FIRST:
			continue
		var at: Vector3 = _pad_cell(a, off)
		if at != Vector3.INF:
			out.append({"kind": "walk-on", "off": off, "key": k, "at": at, "what": _ename(a, e)})
	return out

## A reachable cell standing on the mesh of record `off` (the collider a
## short ray down from the feet meets is under the record's node), the
## nearest to the mesh's middle first; INF when the flood has none there.
func _pad_cell(a, off: int) -> Vector3:
	var target = a.behaviour.hit_node(off)
	if target == null or not is_instance_valid(target) or not (target is MeshInstance3D) \
			or (target as MeshInstance3D).mesh == null:
		return Vector3.INF
	var mi: MeshInstance3D = target
	var box: AABB = mi.global_transform * mi.mesh.get_aabb()
	var mid: Vector3 = box.get_center()
	var near: Array = []
	for bx in range(floori(box.position.x / BUCKET), floori(box.end.x / BUCKET) + 1):
		for bz in range(floori(box.position.z / BUCKET), floori(box.end.z / BUCKET) + 1):
			var arr = _bucket.get(Vector2i(bx, bz))
			if arr == null:
				continue
			for i in arr:
				var p: Vector3 = _pos[i]
				if p.x < box.position.x or p.x > box.end.x or p.z < box.position.z \
						or p.z > box.end.z or p.y < box.position.y - 2.0 or p.y > box.end.y + 2.0:
					continue
				near.append([p.distance_to(mid), i])
	near.sort_custom(func(x, y): return x[0] < y[0])
	for j in mini(near.size(), 48):
		var p: Vector3 = _pos[near[j][1]]
		var hit := _ray(p + Vector3(0.0, 20.0, 0.0), p - Vector3(0.0, 20.0, 0.0))
		var c = hit.get("collider")
		while c != null and c is Node:
			if c == target:
				return p
			c = (c as Node).get_parent()
	return Vector3.INF

func _perform(a, nm: String, act: Dictionary) -> void:
	_done[nm + ":" + String(act["key"])] = true
	var line: String = "%s: %s %s @%05x from %s" % [nm, act["kind"], act["what"], act["off"],
		(act["at"] as Vector3).snapped(Vector3.ONE)]
	_route.append(line)
	print("[solve]   " + line)
	_put(act["at"])
	await _frames(3)
	match String(act["kind"]):
		"use":
			a.behaviour.on_player_activate(int(act["off"]), main.player.global_position,
				main._eye_position())
		"use-gate":
			# The branch's own use edge, not main's — that one would take a
			# doorway the press happens to stand in as well, and the solver
			# takes its exits itself, one at a time and on purpose.
			a.behaviour.press_use()
			await _frames(2)
		"walk-on":
			# Nothing but standing there: the controller's own floor ray
			# finds the pad under the feet (fly_camera._walk_on_floor).
			await _frames(3)
			if (int(a.triggers.state(int(act["off"]))) & Rules.PAD_BIT) != 0:
				print("[solve]     (standing on @%05x left its bit 0x10 up)" % int(act["off"]))
		"shoot":
			for _try in 15:
				if not a.behaviour.is_damageable(int(act["off"])):
					break
				a.behaviour.obj_hit(int(act["off"]), 400.0)
				await get_tree().physics_frame
	await get_tree().physics_frame

## Wait `n` drawn frames AND physics frames (PlayerDriver.frames). The
## The level ticks in main._process; after a 200 ms flood the engine
## runs up to eight physics steps in one iteration, so waiting for physics
## frames alone let the solver move on before a single tick had seen the
## player at the gate — 24SHAL9 never tripped and its door stayed shut
## (2026-09-11).
func _frames(n: int) -> void:
	await _drv.frames(n)

## Put the player on a cell (PlayerDriver.place: the spawn call with
## reset_state = false, facing left alone).
func _put(at: Vector3) -> void:
	_drv.place(at)

## Doors and lifts a round set moving: wait until they stop (rotators
## never do).
func _settle(a) -> void:
	var t: float = 0.0
	while t < SETTLE_MAX:
		var moving: bool = false
		# The movers are Behaviour nodes since step 5e, and each answers for
		# itself: a rotator never stops and is not waited for.
		for n in (a.behaviour.mover_nodes() if a.behaviour != null else []):
			if bool(n.enabled()) and String(n.family_now()) != "rot":
				moving = true
				break
		if not moving:
			break
		await get_tree().create_timer(0.25).timeout
		t += 0.25
	await _frames(3)

func _aim_point(a, off: int, e) -> Vector3:
	var n = a.behaviour.hit_node(off)
	if n != null and is_instance_valid(n) and n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mi: MeshInstance3D = n
		return mi.global_transform * mi.mesh.get_aabb().get_center()
	return _epos(e) if e != null else Vector3.INF

## A reachable cell with a clear line at `aim`, nearest first — a place to
## shoot the thing from, or (with the shorter ACTIVATE_RAY) to look at it
## and press the use key.
func _shooting_spot(a, off: int, aim: Vector3, reach: float = SHOOT_RANGE) -> int:
	if aim == Vector3.INF:
		return -1
	var near: Array = []
	var r: int = int(ceil(reach / BUCKET))
	var bx: int = floori(aim.x / BUCKET)
	var bz: int = floori(aim.z / BUCKET)
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var arr = _bucket.get(Vector2i(bx + dx, bz + dz))
			if arr == null:
				continue
			for i in arr:
				var d: float = _pos[i].distance_to(aim)
				if d <= reach:
					near.append([d, i])
	near.sort_custom(func(x, y): return x[0] < y[0])
	var target = a.behaviour.hit_node(off)
	for j in mini(near.size(), 40):
		var i: int = near[j][1]
		var eye: Vector3 = _pos[i] + Vector3(0.0, EYE, 0.0)
		var hit := _ray(eye, aim)
		if hit.is_empty() or (hit["position"] as Vector3).distance_to(aim) < 48.0:
			return i
		var c = hit.get("collider")
		while c != null and c is Node:
			if c == target:
				return i
			c = (c as Node).get_parent()
	return -1

## Exits this space reaches: a map it has not seen first, then a door it
## has not been through, and last — when there is nothing new here at all —
## the way BACK. A player who has cleared a room walks out of it the way he
## came in; without that the run ended on MAP.217 with mission 1's [M1] and
## [M2] still behind the OTHER door of MAP.214, one it had already used. A
## door is taken at most RETAKE times, so the walk cannot go on for ever;
## the least-used one goes first, so it spreads out instead of swinging
## between the same two rooms.
func _exits(a, nm: String) -> Array:
	# Where the use key reaches a doorway from: the sprite itself, and any
	# 0xEF gate whose chain ends in it (activate_teleport takes either).
	# MAP.210's cargo box is the second kind and only the second kind — the
	# boarded door is opened at a gate at eye height, and the doorway sprite
	# it arms is behind the boards, out of reach. Standing at the sprite
	# alone, the run could never get into the truck (and so never into
	# MAP.216, which is the mission).
	var spots: Dictionary = {}
	for e in _exit_recs(a):
		spots[e.file_off] = [[_epos(e), EXIT_REACH]]
	for g in _prox_nodes(a):
		var ga: int = int(a.triggers.act(int(g.id)))
		if not ga in [0xEF, 0xF1, 0xF2] or a.triggers.spent(int(g.id)):
			continue
		if ga != 0xEF and not a.triggers.enabled(int(g.id)):
			continue                     # a spent lever
		var t: int = a.behaviour.chain_exit(int(g.id))
		if t >= 0 and spots.has(t):
			# A lever is measured 3D from the eye (_reach_eye), a gate's
			# key as a doorway's (_reach_point).
			(spots[t] as Array).append([_epos(a.behaviour.record_of(int(g.id))),
				float(g.measure()), ga != 0xEF])
	var out: Array = []
	for e in _exit_recs(a):
		var target: String = ("MAP.%03d" % e.exit_map) if e.exit_map > 0 else String(main._prev_map_name)
		var vkey: String = "%s#%d" % [target, e.exit_marker_id]
		var dkey: String = "%s:%05x" % [nm, e.file_off]
		var used: int = int(_door_uses.get(dkey, 0))
		var score: int = 0
		if not _seen_map(target):
			score = 2
		elif not _fresh.has(vkey):
			score = 1
		elif used < RETAKE:
			score = -1                   # nothing new that way, but a way on
		else:
			continue                     # been through that door often enough
		# Every place the key reaches it from is offered, not just the
		# first: the cargo box's doorway sprite IS in reach and simply will
		# not fire from there — it is the gate behind the boards that opens
		# it — and one try per doorway left the truck shut for good.
		for s in (spots[e.file_off] as Array):
			var at: Vector3 = _reach_eye(s[0] as Vector3, float(s[1])) if s.size() > 2 and bool(s[2]) 				else _reach_point(s[0] as Vector3, float(s[1]))
			if at == Vector3.INF:
				continue
			out.append({"off": e.file_off, "at": at, "target": target, "set": e.exit_marker_id,
				"vkey": vkey, "dkey": dkey, "used": used, "score": score})
	out.sort_custom(func(x, y): return x["used"] < y["used"] \
		if x["score"] == y["score"] else x["score"] > y["score"])
	return out

## Something fired: the doors are worth another look (_fresh), and each
## may be taken RETAKE times more.
var _epoch: int = 0

func _progress() -> void:
	_epoch += 1
	_fresh.clear()
	_door_uses.clear()

func _seen_map(target: String) -> bool:
	for k in _visited:
		if String(k).begins_with(target + "#"):
			return true
	return false

# --- Verdicts --------------------------------------------------------------

func _pass(nm: String) -> void:
	_finished = true
	print("[solve] route:")
	for r in _route:
		print("[solve]   " + r)
	print("[solve] RESULT PASS — mission complete on %s after %.0f s%s" % [nm,
		(Time.get_ticks_msec() - _t0) / 1000.0, _where()])
	_write_view(nm, main._current_level)
	_quit(0)

func _fail(nm: String, a) -> void:
	_finished = true
	print("[solve] STUCK on %s%s: nothing left to fire and no exit to a new place"
		% [nm, _where()])
	print("[solve] route so far:")
	for r in _route:
		print("[solve]   " + r)
	_report_unreached(a, nm)
	print("[solve] movers now:
" + String(a.behaviour.mover_report()))
	_write_view(nm, a)
	print("[solve] RESULT FAIL — stuck on %s after %.0f s%s"
		% [nm, (Time.get_ticks_msec() - _t0) / 1000.0, _where()])
	_quit(1)

func _quit(code: int) -> void:
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(code)

## For everything that matters and was never reached: the nearest
## reachable cell, and what stops the capsule between the two.
func _report_unreached(a, nm: String) -> void:
	var targets: Array = []
	for e in _exit_recs(a):
		var tgt: String = ("MAP.%03d" % e.exit_map) if e.exit_map > 0 else "previous map"
		if _reach_point(_epos(e), EXIT_REACH) == Vector3.INF:
			targets.append(["EXIT @%05x → %s set %d" % [e.file_off, tgt, e.exit_marker_id], _epos(e)])
	for t in _prox_nodes(a):
		var e = a.behaviour.record_of(int(t.id))
		if not _done.has("%s:p%05x" % [nm, e.file_off]):
			targets.append(["trigger %s @%05x (act %02x)" % [_ename(a, e), e.file_off, e.link_act_type], _epos(e)])
	for e in a.map.entities:
		if e.link_act_type >= 0x26 and e.link_act_type <= 0x2A:
			targets.append(["OBJECTIVE %s @%05x (act %02x)" % [_ename(a, e), e.file_off, e.link_act_type], _epos(e)])
	for t in targets:
		var n: int = _nearest(t[1], INF)
		if n < 0:
			continue
		var from: Vector3 = _pos[n]
		print("[solve]   UNREACHED %s at %s — nearest reachable cell %s, %.0f u away; %s" % [
			t[0], (t[1] as Vector3).snapped(Vector3.ONE), from.snapped(Vector3.ONE),
			from.distance_to(t[1]), _blocker(from, t[1])])
	if not targets.is_empty():
		var n0: int = _nearest(targets[0][1], INF)
		if n0 >= 0:
			print("[solve]   why the flood ends at %s:" % _pos[n0].snapped(Vector3.ONE))
			_explain(_pos[n0])

## What stops the capsule going straight from `from` toward `to`, and
## whether a thinner body would get further.
func _blocker(from: Vector3, to: Vector3) -> String:
	var dir := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if dir.length() < 1.0:
		return "straight above/below (%.0f u of height)" % (to.y - from.y)
	var motion: Vector3 = dir.limit_length(700.0)
	var shape: CapsuleShape3D = _q.shape as CapsuleShape3D
	_q.transform = Transform3D(Basis(), from + Vector3(0.0, _shape_y + LIFT, 0.0))
	_q.motion = motion
	var r: PackedFloat32Array = _space.cast_motion(_q)
	if r.size() == 0 or r[0] >= 0.999:
		return "the way is clear for %.0f u at this height (a step, a drop or a height difference is the gap)" % motion.length()
	var got: float = r[0] * motion.length()
	_q.transform = Transform3D(Basis(), from + Vector3(0.0, _shape_y + LIFT, 0.0) + motion * r[1])
	_q.motion = Vector3.ZERO
	var info: Dictionary = _space.get_rest_info(_q)
	var what: String = "?"
	if info.has("collider_id"):
		what = _collider_name(instance_from_id(int(info["collider_id"])))
		what += " at %s" % (info.get("point", Vector3.ZERO) as Vector3).snapped(Vector3.ONE)
	var thinner: String = ""
	if shape != null:
		var keep: float = shape.radius
		for rr in [20.0, 16.0, 12.0, 8.0]:
			shape.radius = rr
			_q.transform = Transform3D(Basis(), from + Vector3(0.0, _shape_y + LIFT, 0.0))
			_q.motion = motion
			var r2: PackedFloat32Array = _space.cast_motion(_q)
			var got2: float = (r2[0] if r2.size() > 0 else 0.0) * motion.length()
			if got2 > got + 48.0:
				thinner = "; a body of radius %.0f (not %.0f) gets %.0f u further" % [rr, keep, got2 - got]
				break
		shape.radius = keep
	return "capsule stops after %.0f u against %s%s" % [got, what, thinner]

func _collider_name(o) -> String:
	if o == null or not (o is Node):
		return "?"
	var n: Node = o
	var par: Node = n.get_parent()
	if par != null and par is MeshInstance3D:
		var mi: MeshInstance3D = par
		return "%s (%s, size %s)" % [String(mi.get_meta("mesh_name", mi.name)), String(mi.get_parent().name) if mi.get_parent() else "-",
			str(mi.mesh.get_aabb().size.snapped(Vector3.ONE)) if mi.mesh != null else "-"]
	return String(n.name)

# --- Output ----------------------------------------------------------------

## Top view of the reachable space (rows = z, columns = x): '.' standing,
## '~' standing in the water, 'E' exit, 'G' walk-in trigger, 'U' use button,
## 'O' objective, 'S' where the map was entered.
func _write_view(nm: String, a) -> void:
	var dir: String = String(main._cli.get("solve-out", ""))
	if dir.is_empty() or _pos.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for p in _pos:
		var c := Vector2i(roundi(p.x / _cell), roundi(p.z / _cell))
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	lo -= Vector2i(4, 4)
	hi += Vector2i(4, 4)
	var w: int = hi.x - lo.x + 1
	var h: int = hi.y - lo.y + 1
	if w * h > 4000000:
		return
	var rows: Array = []
	for _z in h:
		var row := PackedByteArray()
		row.resize(w)
		row.fill(32)
		rows.append(row)
	for p in _pos:
		var cx: int = roundi(p.x / _cell) - lo.x
		var cz: int = roundi(p.z / _cell) - lo.y
		var ch: int = 126 if _wet(p.y) else 46
		if rows[cz][cx] != 46:
			rows[cz][cx] = ch
	var mark := func(pos: Vector3, ch: String) -> void:
		var cx: int = roundi(pos.x / _cell) - lo.x
		var cz: int = roundi(pos.z / _cell) - lo.y
		if cx >= 0 and cx < w and cz >= 0 and cz < h:
			rows[cz][cx] = ch.unicode_at(0)
	for t in _prox_nodes(a):
		mark.call(_epos(a.behaviour.record_of(int(t.id))), "U" if t.is_wall_button() else "G")
	for e in a.map.entities:
		var act: int = a.triggers.act(e.file_off)
		if act >= 0x26 and act <= 0x2A:
			mark.call(_epos(e), "O")
	for e in _exit_recs(a):
		mark.call(_epos(e), "E")
	for s in _seeds.get(nm, []):
		mark.call(s, "S")
	var f := FileAccess.open("%s/solve_%s.txt" % [dir, nm], FileAccess.WRITE)
	if f == null:
		return
	f.store_line("%s  cell %d u  x %d..%d  z %d..%d  (rows = z, columns = x)" % [nm, int(_cell),
		lo.x * int(_cell), hi.x * int(_cell), lo.y * int(_cell), hi.y * int(_cell)])
	f.store_line("'.' stand  '~' in the water  E exit  G walk-in trigger  U use button  O objective  S entry")
	for z in h:
		f.store_line("%7d %s" % [(lo.y + z) * int(_cell), (rows[z] as PackedByteArray).get_string_from_ascii()])
	f.close()
	print("[solve] view written: %s/solve_%s.txt" % [dir, nm])

# --- Small helpers ---------------------------------------------------------

## An entity's WORLD position. The record is zone-local; the solver works
## in the world the physics queries and the player live in, so the zone
## origin (_setup) goes on here, once, for every caller.
func _epos(e) -> Vector3:
	return Vector3(float(e.x), -float(e.y), -float(e.z)) + _zone

## The map's proximity triggers (0xEF gates, 0xF1/0xF2 levers, wall
## buttons) — their own nodes on the level's Behaviour branch since step
## 5c, where the sweep and the measure live.
func _prox_nodes(a) -> Array:
	return a.behaviour.prox_nodes() if a.behaviour != null else []

## The MAP record behind every 0xF0 doorway of the level, in map order.
## The doorways are nodes since step 5h and the node knows where it stands
## and what it leads to; what the walk below wants of one is its record —
## the file offset it is keyed by and the marker set it spawns at.
func _exit_recs(a) -> Array:
	var out: Array = []
	if a.behaviour == null:
		return out
	for x in a.behaviour.exit_nodes():
		var e = a.behaviour.record_of(int(x.id))
		if e != null:
			out.append(e)
	return out

## Where the run stands when a mission scene is up: the console's own zone
## line (the zone, its mission, where it stands and which phase its world is
## in). "" under the per-map runtime, where the map name says it all.
func _where() -> String:
	if main == null or main._mission == null:
		return ""
	return "  [%s]" % String(main.call("_zone_report", false))

func _ename(a, e) -> String:
	if e == null:
		return "?"
	if e.name_index >= 0 and e.name_index < a.map.names.size():
		return String(a.map.names[e.name_index])
	return "sprite" if (e.flags & 3) == 3 else "entity"
