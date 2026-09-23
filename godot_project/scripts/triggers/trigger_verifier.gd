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
const ZoneLayers := preload("res://scripts/mission/zone_layers.gd")

const XFAIL_PATH: String = "res://tests/rules/skynet.xfail"

const PASS: String = "PASS"
const FAIL: String = "FAIL"
const UNREACHABLE: String = "UNREACHABLE"
const SKIP: String = "SKIP"

## Frames to let a handler run after the activation: the cues fire as the
## chain is walked, a mover announces at the START of its run, an exit on
## the tick it is armed — all inside the first few ticks.
const ACT_FRAMES: int = 6
## …and how much longer an activation is HEARD OUT for when the graph
## promised something the bus has not said yet. The chain itself is
## walked inside one tick, but what it sets off is not: a demolition
## deals its victim's own blast through the deferred call queue and that
## wreck deals the next one's (Behaviour.radial_blast → call_deferred),
## so MAP.260's twelve-deep demolition chain needs a frame per link
## before every `demolish` is on the bus. The budget is derived from what
## the graph promised — a node that promised nothing waits for nothing —
## and the wait ends the moment the promise is kept, so this can only
## turn a missing token into a heard one, never a quiet check into a
## noisy one.
const HEAR_FRAMES_PER_EFFECT: int = 3
const HEAR_FRAMES_MAX: int = 180
## The ceiling on waiting for the movers to arrive, so the SECOND
## activation starts where the graph's simulation says it does. The wait
## itself ends when they have all stopped; what it is allowed to cost is
## worked out from THEIR OWN travel (_settle_budget), and this is only
## the guard on a mover that never arrives at all. A CONTINUOUS rotator
## is one of those and is not waited for. Forty seconds, because MAP.231's
## cab is a 1 520-unit lift and a flat 1 000 frames stopped waiting for it
## with a few units to go — the bit still up, and the next press reading
## as a gate that answers once (three of the pinned second_activation
## rows). What a check really spends is the derived budget, which for a
## door is two seconds.
const SETTLE_FRAMES: int = 2400
## …and the floor under that budget: a door is under two seconds.
const SETTLE_MIN_FRAMES: int = 120
## Frames of grace on top of a mover's own travel time, for the tick it
## is started on and the tick it clears its bit in.
const SETTLE_PAD_FRAMES: int = 30
## The seed every check starts from. Nothing in the trigger layer is
## random, but a great deal AROUND it is: a robot picks a wander angle
## (enemy.gd), a wreck picks one of four destruction sounds and scatters
## its effect sprites (Behaviour.destroy), a flicker lamp tosses a coin
## (raw_action.gd), a crate picks what it drops. Godot randomises the
## global generator at startup, so two runs of this file put the robots
## and the debris of MAP.210/240/250/260 in different places and the
## `shot_each` rows that depend on what the blast reached came out
## differently. The global seed is put back to this number before every
## level change and before every check, which makes a run a function of
## the tree alone. Every generator the level code reaches is that global
## one; the two RandomNumberGenerator instances the port owns
## (scripts/net/) belong to the deathmatch and are never built here.
const CHECK_SEED: int = 0x5147
## How many times a standing point is corrected toward its record when
## the placed body measures out of reach (_nudge).
const NUDGE_TRIES: int = 4
## Frames the player stands still before recording, so anything else his
## standing there sets off has already gone off (trigger_equiv.check
## keeps him a long way away for the same reason; here he has to be at
## the node, so the noise is spent in advance instead).
const PRE_FRAMES: int = 3
## …and how long he stands there for a PATH check, which is a special case
## of the same thing: the DOS engine only ticks an actor in the five grid
## cells round the player (0x12980f), so the machine has to have been in
## the window — and moving under its own speed ramp — before the travel
## is measured. (Until M4 it also had to have ANNOUNCED before the
## recording started, because the port said `path` where a machine picked
## its path up; that announcement is at the flip now, where DOS commits,
## so a neighbour coming into reach can no longer be read as this
## vehicle's doing.)
const PATH_SETTLE_FRAMES: int = 120
## Shots per node: the assault rifle's 20 points are one damage stage
## (DESTRUCT_DAMAGE_PER_STAGE = 16), so one shot is the usual whole test.
const SHOT_MAX: int = 3
## A death check with real rounds: the deepest pool it empties one round
## at a time (twelve rifle rounds; the one pool deeper than that in the
## shipped maps, MAP.280's 10500-point generator, goes by ObjHit instead),
## the rounds it may fire over the count, and how many standing points it
## tries for a clear one.
const SHOT_DEATH_MAX: int = 12
const SHOT_DEATH_SPARE: int = 2
const SHOT_DEATH_SPOTS: int = 12
## Weapon slot 2 (ASSAULT RIFLE) — selected with the number key, so even
## that goes through the input path.
const SHOT_WEAPON: int = 2
## How far outside a radius the negative check stands.
const OUTSIDE_PAD: float = 20.0
## Where a player puts himself to press a WALL BUTTON: in front of it, at
## the same measure a gate is answered from. The button's own mode reaches
## as far as the crosshair does (600 units) and that is right for what the
## key can do, but it is no guide to where to stand — searching straight
## out to it found the ground under a panel three hundred units up a tower
## wall, from where the only view of the panel is the tower.
const BUTTON_STAND: Dictionary = {"origin": "eye", "metric": "3d",
	"radius": Rules.PROX_GATE_RADIUS, "pad": Rules.PLAYER_RADIUS}
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
## Where across a walk-on pad's box the columns that look for its own
## floor are cast (_pad_spots).
const PAD_FRACTIONS: Array = [0.5, 0.35, 0.65, 0.2, 0.8, 0.08, 0.92]
## How far above or below the pad's floor the walk onto it may start
## before a higher or lower one is tried (_off_pad).
const PAD_LEVEL_STEP: float = 16.0
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
## …and where this map's doorways are, for the same reason: a place where
## NOTHING may happen has to be outside their touch measure too.
var _exit_world: Array = []
## What the mission table had the player in before the checks put him on
## foot, given back with the level (_open_map / _release).
var _was_vehicle: int = 0
var _limit: int = 0                      # --verify-limit: nodes per map
## [map name, rows it wrote] per map of the run, in the run's order — the
## `.maps` file a shard writes beside its rows (_write_out).
var _blocks: Array = []
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
	_steady()
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

## The two things that make a run repeatable to the row.
##
## The seed is the obvious half (CHECK_SEED above). The other half is the
## CLOCK: PlayerDriver.frames waits for a drawn frame and then a physics
## frame, and a headless run draws as fast as the machine lets it, so a
## main-loop iteration that fell behind — a level build, a map's first
## shader compile — runs the physics step it owes SEVERAL times over and
## the six frames a check gives a handler become nine. That is what made
## 201@04ee1 and 359@04ee1 (a 512-unit swing door), 230@0f224 (a damage
## stage) and 260@14fb6 (a demolition chain) come out differently on two
## runs of the same tree. One physics step per iteration, and no jitter
## smoothing on top of it, makes `frames(n)` mean n steps of 1/60 s
## whatever the machine is doing. The step itself is unchanged, so the
## game runs exactly as it does in play — only slower under load, which
## a headless run does not care about.
##
## What the run then waits for is physics frames, never seconds — so with
## Godot's own `--fixed-fps 60` (an engine switch, before `--`) nothing
## waits for the wall clock at all: every main-loop iteration is exactly
## one physics step, run as fast as the machine allows, and the rows are
## the same (tools/verify_gate.py always passes it).
func _steady() -> void:
	Engine.max_physics_steps_per_frame = 1
	Engine.physics_jitter_fix = 0.0
	seed(CHECK_SEED)

## The body the standing search measures with, taken again. set_vehicle
## swaps the capsule (fly_camera.VEH_CAPSULE), so the shape _prepare took
## on the START map is a machine's wherever the run began on a vehicle
## map — and a machine's capsule measured for a soldier reads every base
## corridor as blocked. The mission runner takes it per map for the same
## reason (mission_verifier._ready_map).
func _take_capsule() -> void:
	var cs: CollisionShape3D = main.player.get_node_or_null("CollisionShape3D")
	var body: CapsuleShape3D = cs.shape as CapsuleShape3D if cs != null else null
	if body == null:
		return
	_shape_y = cs.position.y
	_shape = CapsuleShape3D.new()
	_shape.radius = body.radius
	_shape.height = body.height

func _run() -> void:
	_t0 = Time.get_ticks_msec()
	var maps: PackedStringArray = _map_list()
	var shard: Array = shard_spec(String(main._cli.get("verify-shard", "")))
	if not shard.is_empty():
		maps = shard_maps(maps, int(shard[0]), int(shard[1]))
	print("[verify] %d map(s) to check (%s%s)" % [maps.size(), _spec,
		(", shard %d/%d" % [int(shard[0]), int(shard[1])]) if not shard.is_empty() else ""])
	for nm in maps:
		var first_row: int = _rows.size()
		if main._level_name() != nm:
			# A level BUILD draws on the same global generator (the pickup
			# a crate is given, level_loader 1391), so the seed goes back
			# before the build as well as before each check.
			seed(CHECK_SEED)
			if not await main._change_level(nm, false, false):
				_row(-1, 0, 0, "-", "-", FAIL, "the level would not load")
				_blocks.append([nm, _rows.size() - first_row])
				continue
			await _drv.frames(8)
		await _verify_map(nm)
		_blocks.append([nm, _rows.size() - first_row])
	_report()

## --verify-shard=I/N → [I, N], or [] when there is none (or it is not
## one: 0 <= I < N).
static func shard_spec(s: String) -> Array:
	var p: PackedStringArray = s.strip_edges().split("/")
	if p.size() != 2 or not p[0].is_valid_int() or not p[1].is_valid_int():
		return []
	var i: int = int(p[0])
	var n: int = int(p[1])
	if n < 1 or i < 0 or i >= n:
		return []
	return [i, n]

## The maps shard `i` of `n` checks, out of `maps` (the run's own list, in
## its own order). A function of the list alone, so N processes given the
## same spec split it the same way and between them check every map once.
##
## A map is not checked on its own: it is checked in the run that reached
## it, and what the maps before it left behind can reach it — a variant
## (MAP.216 and 217 are MAP.210 later in the mission) takes over the
## records its world had destroyed or had taken (main._carry_records).
## So the maps of one mission decade stay together, in their order, and it
## is whole decades that are shared out: the heaviest first, each to the
## shard with the least work so far (the lock's node count for the maps,
## plus a level load each). Inside a shard the decades run in the run's
## order again. The player comes back with the start kit on every map
## (main.place_at_marker → set_spawn with reset_state), and the seed is put
## back before every build and every check (CHECK_SEED), so nothing else
## carries from one decade to the next.
static func shard_maps(maps: PackedStringArray, i: int, n: int) -> PackedStringArray:
	if n <= 1:
		return maps
	var lock: Dictionary = TriggerLock.parse(TriggerLock.lock_text()).get("maps", {})
	var groups: Array = []                   # [first index, weight, [names]]
	var last_decade: int = -9999
	for k in maps.size():
		var nm: String = maps[k]
		var num: int = int(nm.get_extension())
		@warning_ignore("integer_division")
		var decade: int = num / 10
		if groups.is_empty() or decade != last_decade:
			groups.append([k, 0, []])
			last_decade = decade
		var g: Array = groups[groups.size() - 1]
		g[1] = int(g[1]) + SHARD_MAP_WEIGHT \
			+ ((lock.get(num, {}) as Dictionary).get("lines", {}) as Dictionary).size()
		(g[2] as Array).append(nm)
	var order: Array = groups.duplicate()
	order.sort_custom(func(a, b) -> bool:
		if int(a[1]) != int(b[1]):
			return int(a[1]) > int(b[1])
		return int(a[0]) < int(b[0]))
	var work: Array = []
	work.resize(n)
	work.fill(0)
	var mine: Dictionary = {}                # first index → true, for shard i
	for g in order:
		var best: int = 0
		for s in n:
			if int(work[s]) < int(work[best]):
				best = s
		work[best] = int(work[best]) + int(g[1])
		if best == i:
			mine[int(g[0])] = true
	var out := PackedStringArray()
	for g in groups:
		if mine.has(int(g[0])):
			for nm in (g[2] as Array):
				out.append(String(nm))
	return out

## What a level load is worth against one checked node, for the split
## above (a load is two or three seconds, a node a fraction of one).
const SHARD_MAP_WEIGHT: int = 12

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
			@warning_ignore("integer_division")
			if (num / 10) * 10 == (key / 10) * 10:
				out2.append(nm)
		return out2
	if _spec == "changed":
		return _changed_maps(all)
	return all

## What to re-check after a change, instead of the whole game — the maps
##   · whose freshly built graph differs from the lock (a rule changed and
##     the lock has not been accepted yet);
##   · whose lock lines differ from `--verify-base-lock=PATH`, the lock as
##     it was before the change (the one accepted since — tools/verify_gate.py
##     hands in the committed one, `git show HEAD:…`);
##   · with a line in the known-failure list that differs from
##     `--verify-base-xfail=PATH` (a failure unpinned has to be seen passing).
## The game never asks git itself; a change to the CODE means every map, and
## deciding that is the driver's business (verify_gate.py NOT_IN_A_RUN).
func _changed_maps(all: PackedStringArray) -> PackedStringArray:
	var lock: Dictionary = TriggerLock.parse(TriggerLock.lock_text())
	var maps: Dictionary = lock.get("maps", {})
	var base_maps: Dictionary = {}
	var base_path: String = String(main._cli.get("verify-base-lock", ""))
	if not base_path.is_empty():
		if not FileAccess.file_exists(base_path):
			push_warning("[verify] no base lock at %s - checking every map" % base_path)
			return all
		base_maps = TriggerLock.parse(FileAccess.get_file_as_string(base_path)).get("maps", {})
	var xfail_moved: Dictionary = _xfail_moved(String(main._cli.get("verify-base-xfail", "")))
	var out := PackedStringArray()
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		return all
	for nm in all:
		var num: int = int(nm.get_extension())
		if xfail_moved.has(num) or (not base_path.is_empty()
				and not _same_pin(maps.get(num, {}), base_maps.get(num, {}))):
			out.append(nm)
			continue
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

## Two parsed lock entries of one map pin the same thing: the head line
## and every node line alike.
static func _same_pin(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() != b.is_empty():
		return false
	if String(a.get("head", "")) != String(b.get("head", "")):
		return false
	var la: Dictionary = a.get("lines", {})
	var lb: Dictionary = b.get("lines", {})
	if la.size() != lb.size():
		return false
	for id in la:
		if String(la[id]) != String(lb.get(id, "")):
			return false
	return true

## The maps with a known-failure line that is in one of the two lists and
## not in the other ({} with no base list).
func _xfail_moved(base_path: String) -> Dictionary:
	var out: Dictionary = {}
	if base_path.is_empty() or not FileAccess.file_exists(base_path):
		return out
	var now: Dictionary = {}
	var was: Dictionary = {}
	for pair in [[XFAIL_PATH, now], [base_path, was]]:
		if not FileAccess.file_exists(String(pair[0])):
			continue
		for raw in FileAccess.get_file_as_string(String(pair[0])).split("\n"):
			var line: String = raw.strip_edges()
			if not line.is_empty() and not line.begins_with("#"):
				(pair[1] as Dictionary)[line] = true
	for line in now.keys() + was.keys():
		if now.has(line) != was.has(line):
			out[int(String(line).split(" ")[0])] = true
	return out

# ---------------------------------------------------------------------
# One map
# ---------------------------------------------------------------------
func _verify_map(nm: String) -> void:
	_map_t0 = Time.get_ticks_msec()
	var level = main._current_level
	var graph: Dictionary = _open_map(level, true)
	if graph.is_empty():
		return
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
	print("[verify] %s: %d node(s) in %.1f s" % [nm, done,
		float(Time.get_ticks_msec() - _map_t0) / 1000.0])

## The level that has just come up, made ready to be driven: its graph,
## the player unkillable, the rifle in his hands, and the two lists a
## standing point is measured against (every live proximity radius and
## every doorway). `intercept` keeps the exits and the objective counter
## here instead of in main.gd — which is right for a map being checked
## node by node and wrong for the MISSION RUNNER (layer (b),
## scripts/triggers/mission_verifier.gd), which has to TAKE the exits and
## let the counter be the mission's own. Returns {} when there is nothing
## to check, having said so.
func _open_map(level, intercept: bool) -> Dictionary:
	if level == null or level.behaviour == null:
		_row(-1, 0, 0, "-", "-", FAIL, "no level")
		return {}
	var num: int = int(level.map_suffix)
	var graph: Dictionary = TriggerEquiv.graph_of(level)
	if graph.is_empty():
		_row(num, 0, 0, "-", "-", FAIL, "no graph")
		return {}
	# The player cannot be killed between checks; the robots are left
	# alone, because a path vehicle IS one of them (a dead actor stops
	# driving its markers, and `killall` took the truck with it).
	main.player.set("god_mode", true)
	# `intercept` — this map is being checked record by record, not played
	# — also puts the player ON FOOT, whatever the mission table says the
	# map is played in (main._vehicle_for_map: missions 2 and 6 drive,
	# mission 7 flies). A gunship holds its own ground clearance — _hover
	# pushes it off whatever is under it — so a check that puts it down on
	# the floor a gate stands on finds the eye two hundred units above
	# that gate a moment later, outside every measure there is, and
	# twenty-four of MAP.272's gates read as triggers that answer nothing. The vehicle is
	# the MISSION runner's business (layer (b), which plays mission 7 in
	# the HK from end to end); this layer proves one record at a time and
	# needs the player where the record's own handler measures him. It is
	# also what puts a real gun in his hands: a vehicle weapon fires a
	# PROJECTILE, and projectile._is_target stops a bolt only on the
	# `enemy` group, so a car on a vehicle map was never hit at all.
	if intercept:
		_was_vehicle = int(main.player.vehicle)
		main.player.set_vehicle(0)
		_take_capsule()
		_intercept(level)
	# Slot 2 (ASSAULT RIFLE): 20 damage points, which is one damage stage
	# — and chosen on the number key, so even that goes through the input
	# path. fly_camera reads KEY_1..KEY_9 straight off the event. Every
	# shot check picks it again (_check_shot): the checks put the player
	# down all over the map and a weapon he is set down on ARMS ITSELF.
	_hold_rifle()
	_prox_world = []
	for pn in (level.behaviour.prox_nodes() as Array):
		_prox_world.append([int(pn.id),
			(pn.position as Vector3) + (level.origin as Vector3),
			float(pn.measure())])
	_exit_world = []
	for x in (level.behaviour.exit_nodes() as Array):
		_exit_world.append([int(x.id), (x.position as Vector3) + (level.origin as Vector3)])
	_snap = _pristine(level, graph, _snapshot(level))
	return graph

## Everything that would end or leave the level while one node is being
## checked, taken over for the run: an exit is recorded and refused, the
## objective counter is kept here instead of in main (whose handler ends
## the mission and changes the level), and so is the fail act.
func _intercept(level) -> void:
	var b = level.behaviour
	if b == null:
		return
	if b.teleport_requested.is_connected(main._on_teleport_requested):
		b.teleport_requested.disconnect(main._on_teleport_requested)
	if not b.teleport_requested.is_connected(_on_exit):
		b.teleport_requested.connect(_on_exit)
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
	if _was_vehicle > 0 and is_instance_valid(main.player):
		main.player.set_vehicle(_was_vehicle)    # the suite goes on playing
		_was_vehicle = 0
	var b = level.behaviour
	if b == null:
		return
	if b.teleport_requested.is_connected(_on_exit):
		b.teleport_requested.disconnect(_on_exit)
		if not b.teleport_requested.is_connected(main._on_teleport_requested):
			b.teleport_requested.connect(main._on_teleport_requested)
	if b.objective_complete.is_connected(_on_objective):
		b.objective_complete.disconnect(_on_objective)
	if not b.objective_complete.is_connected(main._on_objective_complete):
		b.objective_complete.connect(main._on_objective_complete)
		b.hint_message.connect(main._on_hint_message)
		b.mission_failed.connect(main._on_mission_failed)

## An exit asked for its map change: written down, and nothing else. The
## level's one-map-change latch is deliberately LEFT SET — it is what DOS
## does (the frame loop tears the level down before any handler runs
## again, v1.01 0x117a2e), and releasing it here let the same exit fire a
## second time down the tick sweep and read as "the game did it twice".
## _reset clears the latch between checks.
func _on_exit(target_map: int, marker_set: int) -> void:
	_exit_seen.append([target_map, marker_set])

## The counter main.gd would keep. Only the number matters here (the
## relay reads it, and an objective is supposed to take it down by one);
## the mission-end machinery stays out of the run.
func _on_objective(_idx: int) -> void:
	var b = main._current_level.behaviour if main._current_level != null else null
	if b != null and b.objectives_left > 0:
		b.objectives_left -= 1

# ---------------------------------------------------------------------
# Snapshot and reset
# ---------------------------------------------------------------------
func _snapshot(level) -> Dictionary:
	# Where every path vehicle stands and which way it faces — the
	# vehicles' own since step 5f, and asked of them here: a path is the
	# one thing a snapshot does not keep.
	var paths: Dictionary = level.behaviour.path_snapshot() if level.behaviour != null else {}
	return {"triggers": level.triggers.snapshot(),
		"objectives": level.behaviour.objectives_left,
		"paths": paths, "water": float(main.player.get("water_level")),
		"spawn": main.player.global_position, "yaw": main.player.rotation.y}

## The snapshot the checks reset to is the map AS ITS FILE HAS IT, not as
## it happens to stand: the graph's `first` is simulated from the record
## bytes, so a state byte, a mover, a damage stage or a pool of hit points
## that play has already moved would be measured against a prediction made
## for a map nobody had touched. On a freshly loaded map the two are the
## same thing; for a suite running the subset at the end of a session they
## are not.
func _pristine(_level, graph: Dictionary, snap: Dictionary) -> Dictionary:
	var act: Dictionary = snap["triggers"]
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

## Put the map back as it was. TriggerRuntime.restore does the bytes, the
## movers, the damage stages and the hit points; the latches and the
## one-map-change flag are the nodes' own memory and are cleared here, or
## the next check would start with the player already "inside" every
## trigger he was standing in.
func _reset(level, snap: Dictionary) -> void:
	# Every check starts from the same throw of the dice (CHECK_SEED):
	# where the robots wander to and what a wreck scatters is then the
	# same on every run of the same tree.
	seed(CHECK_SEED)
	_restore_acts(level)
	level.triggers.restore(snap["triggers"])
	level.behaviour.prox_forget()
	# …and what the step-5d classes remember: the flicker each lamp is
	# half way through, and the sprites whose robot is out. A robot an
	# 0xF3 chain let out stays out (putting it back is the level loader's
	# work, not a snapshot's) — but the sprite is armed again, so the next
	# check of it announces as it did the first time.
	level.behaviour.raw_forget()
	# …and that no mover is in the middle of a run (step 5e). Where each
	# one STANDS came back with restore_state above.
	level.behaviour.mover_forget()
	# …and every path vehicle back at the head of its path and standing
	# still, where the map put it (step 5f).
	level.behaviour.path_forget()
	level.behaviour.path_restore(snap["paths"])
	# …and the doorways: which of them the player was standing in, and the
	# one map change this level instance is allowed (step 5h).
	level.behaviour.exit_forget()
	level.triggers.clear_armed()
	_replay_load(level)
	level.behaviour.objectives_left = int(snap["objectives"])
	main.player.set("water_level", float(snap["water"]))
	_exit_seen.clear()
	if level.bus != null:
		level.bus.record(false)

## The map as its FIRST entity sweep leaves it, which is what the graph
## simulates from (trigger_graph._first_sweep): ObjDoAction (FUN_00139698)
## runs the handler of every record whose bit 0 is up from the first tick
## of the level, so a cue laid down enabled has played and cleared its bit
## (0x137dbd for the one-shot sounds, 0x13779d/0x1377d0 retire the
## messages and objectives) before a player can press anything. The
## running game does it once, as its branch enters the tree
## (Behaviour._ready); a reset puts the authored bytes back and so has to
## do it again. The lamps, movers, wrecks, demolitions, water and spawn
## sprites need nothing here — they are the tick's, and the tick that
## follows a reset runs them. The count the objectives take off is put
## back by the caller.
func _replay_load(level) -> void:
	var rt = level.triggers
	if rt == null or level.map == null:
		return
	for e in level.map.entities:
		var off: int = int(e.file_off)
		if e.marker_type >= 0 or not rt.enabled(off):
			continue
		var kind: String = String(Rules.rule_for_record(rt.act(off), e.flags & 3)["kind"])
		if kind in LOAD_CUES:
			rt.fire(off)

## The one-shot cues _replay_load fires.
const LOAD_CUES: PackedStringArray = ["hint", "objective", "fail", "sound_cue", "voice"]

## The act bytes and links as the MAP was parsed. A save's overlay only
## stores the ones play has CHANGED, so restore_state cannot undo a cue
## DOS retired (act ← 0xFF) or a water valve that swapped its own act —
## and the next check of a chain carrying a hint found the message gone
## for good. The runtime puts every one of them back to what map_file.gd
## read, and the cue nodes with it.
func _restore_acts(level) -> void:
	if level.triggers != null:
		level.triggers.reset_acts()

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

## The node's mode of that name, or {}.
static func mode_of(node: Dictionary, want: String) -> Dictionary:
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
	# A WALK-ON PAD is proved by its own mode first: standing on the mesh
	# fires it once, and the use key it still answers afterwards is the
	# graph's SECOND activation (_check_walk). A pad with no room on it for
	# a body is checked on the key alone, as the gate it also is: MAP.286's
	# three CATWLK12 plates lie 36 units under a fan housing that covers
	# them whole, and nobody stands there (_pad_spots finds the floor, the
	# capsule does not fit on it).
	var pad: Dictionary = mode_of(node, "walk_on")
	if not pad.is_empty() and not _pad_spots(level, id, 1).is_empty():
		_checks += 1
		await _check_walk(level, graph, node, num, id, act, kind)
		return
	var how: String = String(mode["mode"])
	_checks += 1
	match how:
		"use_key":
			await _check_use(level, graph, node, num, id, act, kind, mode)
		"prox_enter":
			await _check_prox(level, graph, node, num, id, act, kind, mode)
		"touch_arm":
			await _check_exit(level, graph, node, num, id, act, kind, mode)
		"shot_each", "shot_death":
			await _check_shot(level, node, num, id, act, kind, how)
		"counter":
			await _check_relay(level, node, num, id, act, kind, mode)
		"path_end":
			await _check_path(level, node, num, id, act, kind)
		_:
			_row(num, id, act, kind, how, SKIP, "no driver for this mode")

# --- the use key (0xEF gates and the wall buttons) --------------------
## Where the player stands to press this record's key, and what he looks
## at while he does it: {ok, feet, aim, gate, shared, why}.
##
## An 0xEF gate is a sprite with no collider: DOS fires the gates in reach
## on the KEY itself (press_use → the tick sweep), the crosshair has
## nothing to do with it, and aiming at whatever stands behind the gate
## would operate THAT instead (fly_camera._try_activate walks the ray's
## collider up to an ActionTarget). So a gate is used looking at the
## floor. A wall button is the opposite: it IS the mesh the ray has to
## find, and the player stands at it.
## …unless the 0xEF record is a named variant-1 mesh with state bit 3.
## The runtime takes THOSE off the proximity sweep altogether (walking
## past a button must not press it) and leaves them to the crosshair, so
## a key pressed at the floor beside one does nothing at all. The graph
## says the same of them since 2026-09-16 (trigger_graph._button_mode).
func _use_spot(level, id: int, kind: String, mode: Dictionary) -> Dictionary:
	var ep: Vector3 = _epos(level, id)
	var gate: bool = kind == "prox_gate" and not _is_wall_button(level, id)
	# A button is pressed from in FRONT of it, so the search starts at the
	# DOS gate measure and only widens to the hand's reach when there is
	# nowhere that near to stand. The mode's own 600 units are how far the
	# crosshair carries, not where a player would put himself — searching
	# straight out to it found the ground under a panel three hundred units
	# up a tower, from where the view of it is the tower.
	var spot: Dictionary = _stand_in(level, ep, mode if gate else BUTTON_STAND, 0.0, id)
	if not gate:
		# A button is reached by being LOOKED at (fly_camera._try_activate
		# → the 600-unit crosshair) or by being stood at (use_nearby, and
		# that one measures the DOS gate radius, 86 units — not the 600
		# the mode carries). A floor inside 86 units answers either way;
		# further out, only the crosshair does, and only where the line
		# to the panel is the panel. So where the near search found a
		# place the crosshair does NOT answer from, a place it does is
		# preferred. Where there is none, the near answer stands, so this
		# can put nothing out of reach that was in it.
		var seen: Dictionary = _button_spot(level, ep, id, mode, spot)
		if bool(seen["ok"]):
			spot = seen
	if not gate and not bool(spot["ok"]):
		# Nowhere in front of it: widen to the hand's reach, and ask for a
		# clear line while doing it — the key gets to a button by being
		# LOOKED at. (Asking for the crosshair's own answer instead — a
		# floor whose first collider along the line is this very mesh, the
		# search a shot uses — put a hundred and thirty of these out of
		# reach that the running game presses perfectly well.)
		spot = _stand_in(level, ep, mode, Rules.USE_REACH, id, true)
	if not bool(spot["ok"]):
		# Last resort: the mission runner's wider ring (_stand_wide) —
		# sixteen directions at nine distances, and, where the capsule
		# fits nowhere, the tightest place it does not, because a SPAWN
		# never asks whether it fits and the game puts the player there.
		spot = _stand_wide(level, ep, mode if gate else BUTTON_STAND)
	spot["gate"] = gate
	spot["aim"] = ep if gate else _aim_point(level, id)
	spot["ep"] = ep
	return spot

func _check_use(level, graph: Dictionary, node: Dictionary, num: int, id: int,
		act: int, kind: String, mode: Dictionary) -> void:
	var spot: Dictionary = _use_spot(level, id, kind, mode)
	var ep: Vector3 = spot["ep"]
	var gate: bool = bool(spot["gate"])
	var aim: Vector3 = spot["aim"]
	if not bool(spot["ok"]):
		_row(num, id, act, kind, "use", UNREACHABLE, String(spot["why"]))
		return
	if gate:
		# Where the body really comes to rest, not where the floor ray
		# found ground (_nudge) — and then the map put back, because
		# standing there may have tripped something else on the way.
		spot["feet"] = await _nudge(level, spot["feet"], ep, mode)
		_reset(level, _snap)
	# …and whether that point is inside somebody else's reach is asked of
	# the point the check will really use, not of the one the search
	# started from: a correction of a few units carries the eye into the
	# next gate of a ring (MAP.230's four).
	var feet_in: Vector3 = spot["feet"]
	spot["shared"] = not _alone_at(feet_in, id) or not _doorways_at(feet_in).is_empty()
	var shared: String = "shared with another trigger" if bool(spot.get("shared", false)) else ""
	# A wall button answers the key, never the walk: prove the walk first.
	var walked: PackedStringArray = PackedStringArray()
	if not gate:
		walked = await _stand_and_record(level, spot["feet"], aim, gate, 0)
	var first: PackedStringArray = await _stand_and_record(level, spot["feet"], aim,
		gate, 1, node.get("first", []))
	var why: String = _why(_share(level, graph, id, true, spot,
		TriggerEquiv.compare(node.get("first", []), first)))
	if first.is_empty() and not (node.get("first", []) as Array).is_empty():
		# Nothing at all happened: say how far the eye really was, so a
		# standing point the search believed in and the running game did not
		# is told apart from a trigger that is simply broken.
		why = _join(why, "the eye was %.0f u from it, reach %.0f"
			% [_drv.eye().distance_to(ep),
			   float(mode.get("radius", 0.0)) + float(mode.get("pad", 0.0))])
	if not walked.is_empty():
		why = _join(why, "walking past it did %s" % " ".join(walked))
	# …and the movers it started must do what the graph said they would —
	# unless the point is shared, where a leaf may have been half way
	# through a neighbour's run before the key went down.
	if not bool(spot["shared"]):
		why = _join(why, _mover_truth(level, node.get("first", [])))
	if not why.is_empty():
		_row(num, id, act, kind, "use", FAIL, _join(why, shared))
		return
	# The movers arrive, clear their bit and flip their direction — and
	# only then is the next press the graph's SECOND activation.
	await _settle(level, node.get("first", []))
	why = "" if bool(spot["shared"]) else _mover_settled(level, node.get("first", []))
	# Put him back where the node says he has to stand before pressing
	# again. The first press may have MOVED HIM: a lift is a mover with
	# the player on it (MAP.231's cab, MAP.283's platform, MAP.272's
	# hoists), and the port's controller rides it — so the second press
	# went in from wherever the ride ended, which for a 378-unit lift is
	# well outside the 86 units the 0xEF handler measures, and the check
	# read a gate that works as one that answers once. Nothing about the
	# MAP changed under him, only where he is standing, which is the one
	# thing this layer places by hand anyway.
	var second: PackedStringArray = await _record_around(level, func() -> void:
		_drv.place(spot["feet"])
		_aim_at(aim, gate)
		_drv.activate(), node.get("second", []))
	why = _join(why, _why(_share(level, graph, id, true, spot,
		TriggerEquiv.compare(node.get("second", []), second))))
	if not why.is_empty():
		_row(num, id, act, kind, "use", FAIL, _join("second: " + why, shared))
		return
	# From outside the reach, nothing.
	var out: Dictionary = _stand_out(level, ep, mode, id)
	if bool(out["ok"]):
		_reset(level, _snap)
		var none: PackedStringArray = await _stand_and_record(level, out["feet"], aim, gate, 1)
		# …and it only says anything if the player really WAS out of reach
		# when the key went down. The search measures a floor point; the
		# body is settled over it, and a point chosen twenty units outside
		# an 86-unit measure comes back inside it when the controller
		# pushes the capsule off the wall behind him. That is the test
		# standing in the wrong place, not the handler reaching too far —
		# which is what the one pinned port_use_reach row was.
		var out_r: float = float(mode.get("radius", 0.0)) + float(mode.get("pad", 0.0))
		if none.size() > 0 and _reach_now(ep, mode) > out_r:
			_row(num, id, act, kind, "use", FAIL,
				"out of reach it still did %s" % " ".join(none))
			return
	_row(num, id, act, kind, "use", PASS, "")

## A state-04 prop carrying an 0xEF act: the key at it must do nothing.
func _check_dead_gate(level, _node: Dictionary, num: int, id: int, act: int,
		kind: String) -> void:
	var ep: Vector3 = _epos(level, id)
	var spot: Dictionary = _stand_in(level, ep,
		{"radius": Rules.PROX_GATE_RADIUS, "pad": Rules.PLAYER_RADIUS,
		 "origin": "eye", "metric": "3d"})
	if not bool(spot["ok"]):
		spot = _stand_wide(level, ep, BUTTON_STAND)
	if not bool(spot["ok"]):
		_row(num, id, act, kind, "dead", UNREACHABLE, String(spot["why"]))
		return
	var got: PackedStringArray = await _stand_and_record(level, spot["feet"], ep, true, 1)
	if got.is_empty():
		_row(num, id, act, kind, "dead", PASS, "")
	else:
		_row(num, id, act, kind, "dead", FAIL,
			"a state-04 prop answered the key with %s" % " ".join(got))

# --- walk-on pads (state bit 0x10, FUN_00139d5e) ----------------------
## Walk onto the pad's own mesh from beside it: the chain goes as the
## graph's `first`, the bit comes down, and walking onto it again does
## nothing (once). Then the use key, where the record is a gate that still
## answers it, is the graph's `second`.
func _check_walk(level, graph: Dictionary, node: Dictionary, num: int, id: int,
		act: int, kind: String) -> void:
	var spots: Array = _pad_spots(level, id, 1)
	if spots.is_empty():
		_row(num, id, act, kind, "walk", UNREACHABLE, "nowhere on its own mesh to stand")
		return
	var on: Vector3 = spots[0]
	var from: Vector3 = _off_pad(level, id, on)
	var spot: Dictionary = {"feet": on, "shared": not _alone_at(on, id)}
	var shared: String = "shared with another trigger" if bool(spot["shared"]) else ""
	var mesh = level.behaviour.hit_node(id)
	var first: PackedStringArray = await _walk_in(level, from, on, on,
		node.get("first", []), mesh)
	var why: String = _why(_share(level, graph, id, false, spot,
		TriggerEquiv.compare(node.get("first", []), first)))
	if (int(level.triggers.state(id)) & Rules.PAD_BIT) != 0:
		why = _join(why, "standing on it left bit 0x10 up")
	if not bool(spot["shared"]):
		why = _join(why, _mover_truth(level, node.get("first", [])))
	if not why.is_empty():
		_leave_pad(from)
		_row(num, id, act, kind, "walk", FAIL, _join(why, shared))
		return
	await _settle(level, node.get("first", []))
	# Off and on again: the bit is gone, so nothing.
	var again: PackedStringArray = await _walk_in(level, from, on, on, [], mesh)
	why = _why(_share(level, graph, id, false, spot, TriggerEquiv.compare([], again)))
	if not why.is_empty():
		_leave_pad(from)
		_row(num, id, act, kind, "walk", FAIL, _join("walked on again: " + why, shared))
		return
	# …and what is left is the record's ordinary self: a gate answers the
	# key, and this press is the chain's second walk.
	var use: Dictionary = mode_of(node, "use_key")
	if not use.is_empty():
		var us: Dictionary = _use_spot(level, id, kind, use)
		if bool(us["ok"]):
			us["shared"] = not _alone_at(us["feet"], id) \
				or not _doorways_at(us["feet"]).is_empty()
			var second: PackedStringArray = await _stand_and_record(level, us["feet"],
				us["aim"], bool(us["gate"]), 1, node.get("second", []))
			why = _why(_share(level, graph, id, true, us,
				TriggerEquiv.compare(node.get("second", []), second)))
			if not why.is_empty():
				_leave_pad(from)
				_row(num, id, act, kind, "walk", FAIL, _join("the key after the walk: " + why,
					"shared with another trigger" if bool(us["shared"]) else ""))
				return
	_leave_pad(from)
	_row(num, id, act, kind, "walk", PASS, "")

## Off the pad before the map is put back: a reset raises its bit again,
## and a player still standing there would set it off in the next check.
func _leave_pad(from: Vector3) -> void:
	_drv.place(from if from != Vector3.INF else (_snap.get("spawn", main.player.global_position) as Vector3))

## Places on the record's OWN mesh where the capsule stands: columns cast
## down through its box, a floor kept only where the collider under the
## feet is this record's mesh — which is what the foot mover hands DOS's
## FUN_00139d5e. A pad is walked ON, not climbed onto: a corridor piece
## has a roof over its floor that is the same mesh, so the floors at or
## under the record's own origin come first, the nearest of them first.
func _pad_spots(level, id: int, limit: int) -> Array:
	var target = level.behaviour.hit_node(id) if level.behaviour != null else null
	if target == null or not is_instance_valid(target) or not (target is MeshInstance3D) \
			or (target as MeshInstance3D).mesh == null:
		return []
	var mi: MeshInstance3D = target
	var box: AABB = mi.global_transform * mi.mesh.get_aabb()
	var origin: Vector3 = mi.global_position
	var found: Array = []
	for fx in PAD_FRACTIONS:
		for fz in PAD_FRACTIONS:
			var c := Vector3(lerpf(box.position.x, box.end.x, fx), box.end.y + 20.0,
				lerpf(box.position.z, box.end.z, fz))
			for hit in _column(c, box.position.y - 20.0):
				if not _is_under(hit["collider"], target):
					continue
				var feet: Vector3 = hit["position"]
				if _fits(feet):
					found.append(feet)
	found.sort_custom(func(a, b) -> bool:
		var ua: bool = (a as Vector3).y <= origin.y + 1.0
		var ub: bool = (b as Vector3).y <= origin.y + 1.0
		if ua != ub:
			return ua
		return (a as Vector3).distance_to(origin) < (b as Vector3).distance_to(origin))
	return found.slice(0, limit)

## A floor beside the pad, about level with the spot on it, that is NOT
## the pad — where the walk onto it starts. INF when there is none (the
## player is then put down on the pad, which is stepping onto it too).
## A floor within a stair riser of the pad's is taken before one further
## up or down: walked off a ledge 34 units over MAP.212's pad the body hung
## on the ledge's steep lip over it and never came down on the pad.
func _off_pad(level, id: int, on: Vector3) -> Vector3:
	var target = level.behaviour.hit_node(id)
	for tol in [PAD_LEVEL_STEP, 40.0]:
		for dist in [70.0, 110.0, 160.0, 220.0]:
			for d in RING:
				if d == Vector2.ZERO:
					continue
				var at := Vector3(on.x + d.x * dist, on.y + 60.0, on.z + d.y * dist)
				for hit in _column(at, on.y - 60.0):
					var p: Vector3 = hit["position"]
					if absf(p.y - on.y) > tol or _is_under(hit["collider"], target):
						continue
					if _fits(p) and not _touches_pad(p, target):
						return p
	return Vector3.INF

## True when the body standing at `feet` would already be on the pad: any
## face of its mesh under the capsule's footprint, the coplanar ones
## included. MAP.252's sloping corridor is laid in pieces that overlap at
## the seams, one face on another, and a column that found the other
## piece first put the walk's start on the pad it was to walk onto.
func _touches_pad(feet: Vector3, target) -> bool:
	for d in RING:
		var r: float = Rules.PLAYER_RADIUS + 6.0
		var at: Vector3 = feet + Vector3((d as Vector2).x * r, 0.0, (d as Vector2).y * r)
		var ex: Array = [main.player.get_rid()]
		for _i in 4:
			var q := PhysicsRayQueryParameters3D.create(at + Vector3(0.0, 24.0, 0.0),
				at - Vector3(0.0, 24.0, 0.0))
			q.exclude = ex
			q.collision_mask = main.player.collision_mask
			q.hit_back_faces = true
			q.collide_with_areas = false
			var hit := _space.intersect_ray(q)
			if not hit.has("collider"):
				break
			if _is_under(hit["collider"], target):
				return true
			ex.append(hit["rid"])
	return false

## True when the floor under the feet — the point the game asks about
## (fly_camera._walk_on_floor) — is the pad's mesh.
func _feet_on(target) -> bool:
	var f: Vector3 = main.player.global_position
	for hit in _column(f + Vector3(0.0, 8.0, 0.0), f.y - 24.0):
		return _is_under(hit["collider"], target)
	return false

## Every walkable face under one point, top first, with what it belongs to.
func _column(top: Vector3, bottom_y: float) -> Array:
	var out: Array = []
	var y: float = top.y
	for _i in 6:
		var q := PhysicsRayQueryParameters3D.create(Vector3(top.x, y, top.z),
			Vector3(top.x, bottom_y, top.z))
		q.exclude = [main.player.get_rid()]
		q.collision_mask = main.player.collision_mask
		q.hit_back_faces = true
		q.collide_with_areas = false
		var hit := _space.intersect_ray(q)
		if not hit.has("position"):
			break
		var p: Vector3 = hit["position"]
		if (hit["normal"] as Vector3).y >= FLOOR_MIN_NY:
			out.append({"position": p, "collider": hit.get("collider")})
		y = p.y - 2.0
		if y <= bottom_y:
			break
	return out

static func _is_under(n, target) -> bool:
	var c = n
	while c != null and c is Node:
		if c == target:
			return true
		c = (c as Node).get_parent()
	return false

# --- walking in (0xF1 / 0xF2) -----------------------------------------
func _check_prox(level, graph: Dictionary, node: Dictionary, num: int, id: int,
		act: int, kind: String, mode: Dictionary) -> void:
	var ep: Vector3 = _epos(level, id)
	var inside: Dictionary = _stand_in(level, ep, mode, 0.0, id)
	if not bool(inside["ok"]):
		inside = _stand_wide(level, ep, mode)
	if not bool(inside["ok"]):
		_row(num, id, act, kind, "prox", UNREACHABLE, String(inside["why"]))
		return
	inside["feet"] = await _nudge(level, inside["feet"], ep, mode)
	_reset(level, _snap)
	inside["shared"] = not _alone_at(inside["feet"], id)
	var shared: String = "shared with another trigger" if bool(inside.get("shared", false)) else ""
	var outside: Dictionary = _stand_out(level, ep, mode, id)
	var from: Vector3 = outside["feet"] if bool(outside["ok"]) else Vector3.INF
	var first: PackedStringArray = await _walk_in(level, from, inside["feet"], ep,
		node.get("first", []))
	var why: String = _why(_share(level, graph, id, false, inside,
		TriggerEquiv.compare(node.get("first", []), first)))
	why = _join(why, _mover_truth(level, node.get("first", [])))
	if not why.is_empty():
		_row(num, id, act, kind, "prox", FAIL, _join(why, shared))
		return
	await _settle(level, node.get("first", []))
	# Out and in again: the port's latch says nothing happens until a
	# chain re-arms it, and the graph's second activation says the same.
	var second: PackedStringArray = await _walk_in(level, from, inside["feet"], ep,
		node.get("second", []))
	why = _why(_share(level, graph, id, false, inside,
		TriggerEquiv.compare(node.get("second", []), second)))
	if not why.is_empty():
		_row(num, id, act, kind, "prox", FAIL, _join("re-entry: " + why, shared))
		return
	_row(num, id, act, kind, "prox", PASS, "")

## Stand outside, then walk in on the movement keys (or, when there is no
## floor to walk from or the way is blocked, be put there), and report
## what the bus heard on the way in.
##
## `pad` is a walk-on pad's mesh when the walk is onto one. Walked in, the
## body can end up hung on a lip beside it (a ledge's steep edge, a
## generator's rim) rather than on it; it is then put down on the spot,
## which is stepping onto it too. With nowhere to walk from, the level
## still gets its settling frames before the recording, with the body
## held still where it is so no floor it stands on is walked on.
func _walk_in(level, from: Vector3, to: Vector3, ep: Vector3,
		want: Array = [], pad = null) -> PackedStringArray:
	if from != Vector3.INF:
		_drv.place(from)
		_drv.face(ep)
		await _drv.frames(PRE_FRAMES)
	elif pad != null:
		main.player.set_physics_process(false)
		await _drv.frames(PRE_FRAMES)
		main.player.set_physics_process(true)
	var bus = level.bus
	bus.record(true)
	bus.clear()
	if from != Vector3.INF:
		var got: float = await _drv.walk_toward(to, 45, 24.0)
		if got > 48.0 or (pad != null and not _feet_on(pad)):
			_drv.place(to)                       # the way was not walkable
	else:
		_drv.place(to)
	_drv.face(ep)
	await _drv.frames(ACT_FRAMES)
	for _i in mini(HEAR_FRAMES_PER_EFFECT * want.size(), HEAR_FRAMES_MAX):
		if _heard_all(want, bus.history()):
			break
		await _drv.frames(1)
	var heard: Array = bus.take()
	bus.record(false)
	return TriggerEquiv.tokens(heard)

# --- exits (0xF0) ------------------------------------------------------
func _check_exit(level, graph: Dictionary, node: Dictionary, num: int, id: int,
		act: int, kind: String, mode: Dictionary) -> void:
	var ep: Vector3 = _epos(level, id)
	# The key only reaches a doorway the player can SEE: Behaviour
	# .reachable rays the sprite, and a shut door leaf blocks all four of
	# its lines. A doorway with no such place to stand is not a failure —
	# it is a door that has not been opened yet.
	#
	# …and, where the map leaves room for it, a place no GATE reaches
	# either (the `alone` argument — the exit's own id is in no proximity
	# row, so every one of them counts). The key is one key: standing in an
	# 0xEF gate whose chain ends in this very doorway, it walks that chain
	# first (Behaviour.activate_teleport) and the door sounds on the
	# way, which is right for the gate and more than this node promises.
	# Where there is nowhere else to stand the spot is taken anyway and
	# marked shared, as the gates' own checks do.
	var spot: Dictionary = _stand_in(level, ep, mode, 0.0, id, true)
	if not bool(spot["ok"]):
		spot = _stand_wide(level, ep, mode, true)
	if not bool(spot["ok"]):
		_row(num, id, act, kind, "exit", UNREACHABLE, String(spot["why"]))
		return
	spot["shared"] = not _alone_at(spot["feet"], -1)
	# 1. Touching it must only ARM it — in DOS you walk into the truck and
	#    press the key at its rear doors; standing there does nothing.
	var touch: PackedStringArray = await _stand_and_record(level, spot["feet"], ep, true, 0)
	if _has_exit(touch):
		_row(num, id, act, kind, "exit", FAIL, "touching it took it")
		return
	# 2. The key takes it. The crosshair ray is aimed at the floor: an
	#    exit is a sprite with no collider, and a mesh behind it would
	#    answer the key instead (fly_camera._try_activate).
	# Put him back on the spot first. A doorway's reach IS the radius that
	# armed it (90 units), so there is no slack in it, and the body does
	# not stay where it is put: the controller settles it over the floor
	# point, and three frames of that carried him 33 units off a doorway
	# the search had him 77 from. That is the test moving, not the game.
	var got: PackedStringArray = await _record_around(level, func() -> void:
		_drv.place(spot["feet"])
		_drv.face(ep)
		_drv.look(main.player.rotation.y, -1.0)
		_drv.activate(), node.get("first", []))
	var why: String = _why(_share(level, graph, id, true, spot,
		TriggerEquiv.compare(node.get("first", []), got)))
	# There is one key. Where the only floor inside this doorway's measure
	# is also inside an 0xEF GATE whose chain ends in this very doorway,
	# that gate is what the key operates — DOS's own way through a door,
	# and the port takes it first (Behaviour.activate_teleport). What
	# the game then did is the GATE's row of the graph, sound and all, so
	# that is what it is measured against.
	if not why.is_empty() and bool(spot.get("shared", false)):
		var by_gate: Array = _gate_chaining_to(level, graph, id)
		if not by_gate.is_empty():
			var alt: String = _why(TriggerEquiv.compare(by_gate, got))
			why = "" if alt.is_empty() else _join(alt, "a gate covers this doorway")
	if not why.is_empty():
		var blocked: bool = not level.behaviour.reachable(
			main.player.global_position - level.origin, ep - level.origin)
		# What the refused map change asked for, when there was one: an
		# exit that fired for the wrong map or the wrong marker set reads
		# as a missing token and an extra one, and this says which.
		var asked := PackedStringArray()
		for e in _exit_seen:
			asked.append("%d/%d" % [int(e[0]), int(e[1])])
		# …and how far the FEET really were when the key went down, the way
		# the doorway measures them (2D with a vertical window): a spot the
		# search believed in and the running game then measured out of it —
		# the controller settles the body over the floor point before the
		# press — is told apart from a doorway that is simply shut.
		var feet: Vector3 = main.player.global_position
		var flat: float = Vector2(feet.x - ep.x, feet.z - ep.z).length()
		var put: Vector3 = spot["feet"]
		_row(num, id, act, kind, "exit", FAIL, _join(_join(_join(why,
			"the feet were %.0f u from it (put at %.0f), reach %.0f"
				% [flat, Vector2(put.x - ep.x, put.z - ep.z).length(),
				   Rules.TELEPORT_TOUCH_RADIUS]),
			"the line to it is blocked" if blocked else ""),
			("it asked for " + " ".join(asked)) if not asked.is_empty() else ""))
		return
	# 3. An exit a CHAIN switches on fires on the tick it is armed.
	_reset(level, _snap)
	var armed: PackedStringArray = await _record_around(level, func() -> void:
		level.triggers.arm_in_tick(id))
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
	var b = level.behaviour
	var aim: Vector3 = _aim_point(level, id)
	if aim == Vector3.INF:
		_row(num, id, act, kind, how, UNREACHABLE, "nothing to aim at")
		return
	if level.behaviour.hit_node(id) == null:
		# Nothing was built for it: the record carries the hit bit and the
		# level has no mesh of it to put a bullet into, so neither this
		# check nor a player can reach it. Said in its own words, because
		# "no line of fire" reads as a wall in the way.
		_row(num, id, act, kind, how, UNREACHABLE, "no mesh was built for it to be shot")
		return
	var spot: Dictionary = _shooting_spot(level, id, aim)
	if not bool(spot["ok"]):
		_row(num, id, act, kind, how, UNREACHABLE, String(spot["why"]))
		return
	if how == "shot_death":
		# Real rounds first: a spot from where the round the rifle really
		# fires reaches THIS record before anything else that breaks, and a
		# pool the rifle can empty from there.
		var clear: Dictionary = await _death_spot(level, id, aim)
		if bool(clear["ok"]):
			await _check_shot_death(level, node, num, id, act, kind, how, aim)
			return
		spot["why"] = String(clear["why"])
	_drv.place(spot["feet"])
	_drv.face(aim)
	# The rifle again, and not once per map: a check that walked or was
	# put down on a weapon PICKUP is holding that one from then on, and
	# the bolt of a laser or a plasma gun flies straight through a prop
	# (projectile._is_target stops only on the `enemy` group), so the
	# cars further down a map's list were being shot with something that
	# cannot break them. Twelve of the pinned "no damage stage" failures
	# were only that.
	_hold_rifle()
	await _drv.frames(PRE_FRAMES)
	var bus = level.bus
	bus.record(true)
	bus.clear()
	# Set when the death edge was taken through ObjHit rather than left to
	# the barrel — which, since the reset below, is every death there are
	# hit points left to take off.
	var by_hit: bool = false
	var fallback: String = String(spot.get("why", ""))
	for _i in SHOT_MAX:
		await _fire_once()
		if not b.is_damageable(id) or bus.history().size() > 0:
			break
	# A thousand-point generator is fifty rifle shots; the death bit is
	# what is being checked, not the barrel — and not what the barrel HIT
	# on the way either. Three rifle shots into a rack of crates take the
	# crate in FRONT with them, and the chain of the record behind it then
	# has nothing left to demolish: the 0x1B handler deals HP + 1 through
	# ObjHit, and ObjHit does nothing to a record whose pool has already
	# run out (Behaviour.demolish). So the shots above prove the input
	# path, and then the map goes back as its file has it — the reset
	# every check starts from — and the death edge is taken on THAT,
	# through the same ObjHit the bullet calls, which is the map the
	# graph simulated its `first` on.
	if how == "shot_death":
		_reset(level, _snap)
		# The reset puts the map's own bytes back, and the sweeps answer
		# that the way they answer any change (a lamp whose bit moved says
		# so): heard out first, as every other check hears its reset out,
		# before the recording starts.
		await _drv.frames(PRE_FRAMES)
		bus.record(true)
		bus.clear()
		var left: float = float(level.triggers.hp(id))
		if left > 0.0:
			by_hit = true
			b.obj_hit(id, left)
	await _drv.frames(ACT_FRAMES)
	# …and heard out, as an activation is: a wreck's own blast reaches the
	# next prop through the deferred call queue (Behaviour.radial_blast),
	# so a row of cars answers one shot over several frames.
	for _i in mini(HEAR_FRAMES_PER_EFFECT * (node.get("first", []) as Array).size(),
			HEAR_FRAMES_MAX):
		if _heard_all(node.get("first", []), bus.history()):
			break
		await _drv.frames(1)
	var got: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), got))
	why = _join(why, _mover_truth(level, node.get("first", [])))
	var via: String = ""
	if by_hit:
		via = "by ObjHit" if fallback.is_empty() else "by ObjHit: " + fallback
	if not why.is_empty():
		_row(num, id, act, kind, how, FAIL, why + (" (%s)" % via if by_hit else ""))
		return
	_row(num, id, act, kind, how, PASS, via)

## A record set off by being SHOT TO DEATH (state bit 2, ObjHit
## FUN_00139019 -> the depletion edge), proven with the rifle's own rounds:
## fired from `_death_spot`, as many as its pool takes, and whatever the
## chain did laid against the graph's `first`. The map is the one the
## check was reset to, so what the graph simulated is what is shot at.
func _check_shot_death(level, node: Dictionary, num: int, id: int, act: int,
		kind: String, how: String, aim: Vector3) -> void:
	var b = level.behaviour
	var bus = level.bus
	# The records the chain is to demolish, and whether each is still
	# standing before the first round (see _blasted below).
	var standing: Dictionary = {}
	for t in (node.get("first", []) as Array):
		var tok: String = String(t)
		if tok.begins_with("demolish@") and tok.substr(9).is_valid_hex_number():
			var off: int = tok.substr(9).hex_to_int()
			standing[off] = not level.triggers.spent(off)
	bus.record(true)
	bus.clear()
	var shots: int = 0
	for _i in _shots_to_kill(level, id) + SHOT_DEATH_SPARE:
		if not b.is_damageable(id):
			break
		_drv.face(aim)
		await _fire_once()
		shots += 1
	var dead: bool = not b.is_damageable(id)
	await _drv.frames(ACT_FRAMES)
	for _i in mini(HEAR_FRAMES_PER_EFFECT * (node.get("first", []) as Array).size(),
			HEAR_FRAMES_MAX):
		if _heard_all(node.get("first", []), bus.history()):
			break
		await _drv.frames(1)
	var got: PackedStringArray = TriggerEquiv.tokens(bus.take())
	bus.record(false)
	var why: String = "" if dead else "%d rifle rounds did not empty its pool" % shots
	var res: Dictionary = TriggerEquiv.compare(node.get("first", []), got)
	var blasted: PackedStringArray = _blasted(level, res, standing)
	why = _join(why, _why(res))
	why = _join(why, _mover_truth(level, node.get("first", [])))
	if not why.is_empty():
		_row(num, id, act, kind, how, FAIL, why + " (%d rounds)" % shots)
		return
	_row(num, id, act, kind, how, PASS,
		"" if blasted.is_empty() else "the blast took %s first" % " ".join(blasted))

## A demolition the graph promises and the game did not announce, because
## the record went some other way first: the record that died throws its
## own blast (FUN_00124293, the i16 at its link record +1 — Behaviour.
## radial_blast), and a prop standing next to it can die in that blast
## before the chain's 0x1B handler (0x1380bf) is dispatched on the next
## sweep. That handler then finds a spent pool and does nothing — which is
## the runtime's rule and DOS's (Behaviour.demolish). What it was there to
## do has been done: the record is gone. The graph walks the links and
## cannot see a blast, so a missing `demolish@X` is forgiven exactly where
## X was standing before the first round and is spent now, and nowhere
## else. (The death edge taken through ObjHit on a reset map could never
## show this: the reset puts the bytes back, not the props the last check
## blew away, so the blast found nothing there to kill.)
func _blasted(level, res: Dictionary, standing: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var keep := PackedStringArray()
	for t in (res.get("missing", PackedStringArray()) as PackedStringArray):
		var tok: String = String(t)
		var off: int = tok.substr(9).hex_to_int() if tok.begins_with("demolish@") else -1
		if off >= 0 and bool(standing.get(off, false)) and level.triggers.spent(off):
			out.append("%05x" % off)
		else:
			keep.append(tok)
	res["missing"] = keep
	res["ok"] = keep.is_empty() and (res.get("extra", PackedStringArray()) as PackedStringArray).is_empty()
	return out

## Rounds of the check's rifle a record's pool takes (its hit points over
## the weapon record's damage, rounded up; one for a pool of nothing -
## ObjHit's `hp <= 0` edge comes on the first hit).
func _shots_to_kill(level, id: int) -> int:
	var hp: float = float(level.triggers.hp(id)) if level.triggers.has_hp(id) else 0.0
	var dmg: float = _rifle_damage()
	if dmg <= 0.0:
		return SHOT_DEATH_MAX + 1
	return maxi(ceili(hp / dmg), 1)

## The check's rifle in the player's hands, chosen on its number key.
## The key does nothing for a slot he does not own (DOS WeaponSelect,
## fly_camera._select_weapon), and Future Shock sends him out with the
## pipe alone (its start list 0x43538): every FS "shot" was a pipe swing,
## which broke only the crates he happened to be put down beside. SkyNET's
## start list already holds the rifle, so there this is only the key. A
## driver's arsenal is the vehicle's own and is left alone.
func _hold_rifle() -> void:
	if int(main.player.vehicle) == 0 and main.player.has_method("grant_weapon"):
		main.player.call("grant_weapon", SHOT_WEAPON)
	_drv.press_key(KEY_1 + SHOT_WEAPON)

func _rifle_damage() -> float:
	var ws = main.player.get("_weapons")
	if ws is Array and SHOT_WEAPON < (ws as Array).size():
		return float((ws as Array)[SHOT_WEAPON].get("dmg", 0.0))
	return 0.0

## Where the rifle can shoot record `id` to death with nothing else in
## the way: stood on, settled, faced, and the round the gun really fires
## - from the camera along the view (fly_camera._shoot, the hitscan of a
## gun whose DOS muzzle offset is 0,0,0) - cast to see what it meets
## first. The spot search measures from a standing point, and the body
## the controller has settled is not at it: from where it came to rest
## the round met the crate IN FRONT of the one aimed at, emptied that
## pool first, and the chain behind then had nothing left to demolish
## (the 0x1B handler 0x1380bf deals HP + 1 through ObjHit, which does
## nothing to a record already spent). Every spot the search finds is
## tried; the body is left standing at the first one that is clear.
## {ok: false, why} when none is, or when the pool is deeper than the
## check will empty round by round.
func _death_spot(level, id: int, aim: Vector3) -> Dictionary:
	if not level.triggers.has_hp(id) or float(level.triggers.hp(id)) <= 0.0:
		return {"ok": false, "why": ""}      # no pool: nothing for a round to empty
	var need: int = _shots_to_kill(level, id)
	if need > SHOT_DEATH_MAX:
		return {"ok": false, "why": "its pool takes %d rounds" % need}
	var target = level.behaviour.hit_node(id)
	var tried: int = 0
	for feet in _shooting_spots(level, id, aim, SHOT_DEATH_SPOTS):
		tried += 1
		_drv.place(feet)
		_drv.face(aim)
		_hold_rifle()
		await _drv.frames(PRE_FRAMES)
		_drv.face(aim)
		await _drv.physics(1)
		if _round_meets(target):
			return {"ok": true, "why": ""}
	return {"ok": false, "why": "no clear round from %d spot(s)" % tried}

## Does the rifle's round, fired now, meet `target` before anything else?
## The walk up the collider's parents is the one fly_camera._shoot makes
## to find what takes the damage.
func _round_meets(target: Node) -> bool:
	var cam = main.player.get("_cam")
	if cam == null or not main.player.has_method("aim_dir"):
		return false
	var from: Vector3 = (cam as Node3D).global_position
	var q := PhysicsRayQueryParameters3D.create(from,
		from + (main.player.call("aim_dir") as Vector3) * 60000.0)
	q.collision_mask = ZoneLayers.world_mask()
	q.collide_with_areas = true
	q.exclude = [main.player.get_rid()]
	var hit := _space.intersect_ray(q)
	if not hit.has("collider"):
		return false
	var c = hit["collider"]
	while c != null and c is Node:
		if c == target:
			return true
		c = (c as Node).get_parent()
	return false

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
	var b = level.behaviour
	var e = level.map.entities_by_off.get(id)
	if e == null:
		_row(num, id, act, kind, "counter", FAIL, "no record")
		return
	var at: int = int(mode.get("at", Rules.RELAY_AT))
	var got: PackedStringArray = await _record_around(level, func() -> void:
		level.triggers.arm(id)                   # what a chain does to it
		b.objectives_left = at, node.get("first", []))
	var why: String = _why(TriggerEquiv.compare(node.get("first", []), got))
	_row(num, id, act, kind, "counter", FAIL if not why.is_empty() else PASS, why)

# --- a vehicle that drives a marker path ------------------------------
func _check_path(level, node: Dictionary, num: int, id: int, act: int,
		kind: String) -> void:
	var veh: Node = level.behaviour.vehicle_node(id) if level.behaviour != null else null
	if veh == null:
		_row(num, id, act, kind, "path", UNREACHABLE, "no vehicle was built for it")
		return
	var nd: Node3D = veh.actor
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
	await _drv.physics(PATH_SETTLE_FRAMES)
	# Standing beside it is already enough for the DOS window. Put it back
	# at the head and take the measurement from there, so the travel below
	# is the whole of this path's and not the part of it the machine drove
	# while the player was being settled.
	veh.path_forget()
	was = nd.position
	var bus = level.bus
	bus.record(true)
	bus.clear()
	var e = level.map.entities_by_off.get(id)
	if e != null:
		level.triggers.flip(e.file_off)           # the end of the path, taken directly
	_arm_path(level, int(veh.head))
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

## Switch the markers of a path on, whatever the walk above left them at.
##
## The flip stands in for the END of the path — it is how the chain's
## effects are reached without driving the whole route first — but
## ObjFlipLink is a TOGGLE, and a map may author its path either way.
## MAP.210's truck waits for a lever, so its markers are off and the flip
## switches them on; MAP.234's HK is already flying when the map loads, so
## its markers are on (st 01) and that same flip switched them OFF — the
## machine then sat still for the whole three seconds and the check read
## it as a vehicle that will not drive. Thirteen of the fourteen pinned
## path_window rows said exactly that, and it was the check's own doing,
## not the game's: the running game drives every one of them.
##
## What the path itself is the vehicle's node knows (path_watch): the
## chain of variant-3 MARKERS from the head, stopping at an actor or at
## the first link that is not one.
func _arm_path(level, head: int) -> void:
	var cur = level.map.entities_by_off.get(head)
	var hops: int = 0
	while cur != null and hops < Rules.PATH_MAX_HOPS:
		if (cur.flags & 3) != 3 or cur.marker_type < 0:
			return
		level.triggers.arm(cur.file_off)
		if (cur.flags & 0x40) != 0 or int(level.triggers.link(cur.file_off)) < 1:
			return
		cur = level.map.entities_by_off.get(int(level.triggers.link(cur.file_off)))
		hops += 1

# ---------------------------------------------------------------------
# Driving and recording
# ---------------------------------------------------------------------
## Stand at `feet` looking at `aim`, let whatever else is there go off,
## then record: `keys` presses of the activate key, and ACT_FRAMES of the
## game running.
func _stand_and_record(level, feet: Vector3, aim: Vector3, floor_aim: bool,
		keys: int, want: Array = []) -> PackedStringArray:
	_drv.place(feet)
	_aim_at(aim, floor_aim)
	await _drv.frames(PRE_FRAMES)
	# Put him back on the point before the key goes down. The body does
	# not stay where it is put — the controller settles it over the floor
	# and slides it out of whatever it is touching — and the measure a
	# gate applies has no slack in it (86 units for an 0xEF), so the three
	# frames that let the neighbourhood go quiet also carried him off the
	# spot the search had measured. _check_exit has done this since step
	# 5b for the same reason.
	return await _record_around(level, func() -> void:
		_drv.place(feet)
		_aim_at(aim, floor_aim)
		for _i in keys:
			_drv.activate(), want)

## Turn toward `aim`; with `floor_aim` put the crosshair on the ground
## instead, so the use key reaches the entity by the DOS route (the
## proximity sweep) and not by the port's crosshair ray.
func _aim_at(aim: Vector3, floor_aim: bool) -> void:
	_drv.face(aim)
	if floor_aim:
		_drv.look(main.player.rotation.y, -1.2)

## Record the bus while `doit` runs and the game takes ACT_FRAMES more —
## and then, while the graph is still owed a token, up to the budget
## `want` earns (HEAR_FRAMES_PER_EFFECT above).
func _record_around(level, doit: Callable, want: Array = []) -> PackedStringArray:
	var bus = level.bus
	bus.record(true)
	bus.clear()
	doit.call()
	await _drv.frames(ACT_FRAMES)
	var budget: int = mini(HEAR_FRAMES_PER_EFFECT * want.size(), HEAR_FRAMES_MAX)
	for _i in budget:
		if _heard_all(want, bus.history()):
			break
		await _drv.frames(1)
	var heard: Array = bus.take()
	bus.record(false)
	return TriggerEquiv.tokens(heard)

## Has everything the graph promised been said? (Nothing is judged here —
## an EXTRA token is the comparison's business, and waiting longer could
## only collect more of them; this is only the question "is there still
## something to wait for".)
func _heard_all(want: Array, history: Array) -> bool:
	if want.is_empty():
		return true
	return PackedStringArray(TriggerEquiv.compare(want,
		TriggerEquiv.tokens(history)).get("missing", PackedStringArray())).is_empty()

## Wait for every mover the last activation started to arrive (they clear
## their own bit on arrival), so the next activation is the graph's
## "second" and not the rest of the first. A continuous rotator (family
## rot with no angle in its slot) never arrives and is not waited for.
##
## How long that is allowed to take is the MOVERS' OWN: their travel
## divided by their speed, the slowest of them deciding (_settle_budget).
## A fixed count was either far more than a door needs or — on MAP.283's
## 378-unit lift and MAP.201's 512-unit swing — near enough the truth
## that a frame lost to a slow tick left the mover still running when the
## second press went in, which is what made those rows come out
## differently on two runs.
func _settle(level, want: Array = []) -> void:
	for _i in _settle_budget(level, want):
		var moving: bool = false
		for n in level.behaviour.mover_nodes():
			if bool(n.spins()):
				continue
			if bool(n.running):
				moving = true
				break
		if not moving:
			break
		await _drv.physics(1)
	await _drv.frames(1)

## How many frames the movers of this activation are worth: the longest
## travel divided by its own speed, plus the tick it starts on and the
## tick it clears its bit in. `want` is the graph's own promise, so the
## movers are named before they have moved; a promise with no mover in it
## still gets the floor, because a chain can start one the graph does not
## write down as a move (a continuous rotator) and the loop above leaves
## the moment nothing is running anyway.
func _settle_budget(level, want: Array) -> int:
	var frames: int = SETTLE_MIN_FRAMES
	for t in want:
		var tok: String = String(t)
		if not tok.begins_with("move@"):
			continue
		var n: Node = level.behaviour.mover_node(tok.substr(5, 5).hex_to_int())
		if n == null or bool(n.spins()):
			continue
		var speed: float = float(n.speed)
		if speed <= 0.0:
			continue                              # the DOS "jump" family: instant
		frames = maxi(frames, int(ceil(float(n.span()) / speed
			* float(Engine.physics_ticks_per_second))) + SETTLE_PAD_FRAMES)
	return mini(frames, SETTLE_FRAMES)

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
				if sight and not level.behaviour.reachable(feet - (level.origin as Vector3),
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

## Where the CROSSHAIR answers this wall button from. The rings of the
## near search first (a player presses a panel from in front of it), then
## the wider ones out to the reach the slot really carries — and the test
## is the crosshair's own: the first collider along the line from the eye
## that has an `activate` method has to be this record's node, because
## that is the one fly_camera hands the key to (_try_activate, and a
## target that takes the key never lets it through to use_nearby).
##
## `near` is what the near search already found; it is returned unchanged
## when nothing here can better it, so this only ever moves a button
## check to a place that works.
func _button_spot(level, ep: Vector3, id: int, mode: Dictionary,
		near: Dictionary) -> Dictionary:
	var target: Node = level.behaviour.hit_node(id)
	if target == null:
		target = level.behaviour.prox_node(id)
	if target == null:
		return near
	var aim: Vector3 = _aim_point(level, id)
	var reach: float = float(mode.get("radius", Rules.USE_REACH)) + float(mode.get("pad", 0.0))
	var near_r: float = Rules.PROX_GATE_RADIUS + Rules.PLAYER_RADIUS
	for search in [near_r, Rules.USE_REACH, reach]:
		for frac in RING_FRACTIONS:
			for d in RING:
				var at := Vector3(ep.x + d.x * search * frac, ep.y, ep.z + d.y * search * frac)
				for feet in _floors_under(at, search):
					if not _measures(feet, ep, mode, reach):
						continue
					if not _fits(feet):
						continue
					if not _ray_reaches(feet, aim, target):
						continue
					return {"ok": true, "feet": feet, "why": "", "shared": false}
	return near

## Does the crosshair, from `feet`, resolve to `target`? The walk up the
## collider's parents is fly_camera._try_activate's own.
func _ray_reaches(feet: Vector3, aim: Vector3, target: Node) -> bool:
	var eye: Vector3 = feet + Vector3(0.0, _eye_h() + PlayerDriver.LIFT, 0.0)
	var q := PhysicsRayQueryParameters3D.create(eye, aim)
	q.collision_mask = ZoneLayers.world_mask()
	q.collide_with_areas = true
	q.exclude = [main.player.get_rid()]
	var hit := _space.intersect_ray(q)
	if not hit.has("collider"):
		return false
	var n: Node = hit["collider"] as Node
	while n != null and not n.has_method("activate"):
		n = n.get_parent()
	if n == null:
		return false
	return n == target or target.is_ancestor_of(n) or n.is_ancestor_of(target)

## Stand there, let the controller settle the body, and see where the
## node's own handler would really measure the eye. A floor point is not
## a standing point: `place` sets the capsule down and the controller
## pushes it out of whatever it is touching and down onto what is under
## it, and the eye ends somewhere else — 91 units from a gate the search
## had at 84, which is outside the 86 the 0xEF handler measures, and the
## key then did nothing at all. That is the test standing in the wrong
## place, not the gate refusing a player.
##
## So the placement is MEASURED, and where it came out short the point is
## stepped toward the record by the overshoot and measured again. The
## best of the tries is what the check then uses, and a node with nowhere
## better keeps the point the search gave it.
func _nudge(_level, feet: Vector3, ep: Vector3, mode: Dictionary) -> Vector3:
	var r: float = float(mode.get("radius", Rules.PROX_GATE_RADIUS))
	r += float(mode.get("pad", 0.0))
	var best: Vector3 = feet
	var best_d: float = INF
	for _i in NUDGE_TRIES:
		_drv.place(feet)
		_drv.face(ep)
		await _drv.frames(1)
		var d: float = _reach_now(ep, mode)
		if d < best_d:
			best_d = d
			best = feet
		if d <= r:
			return feet
		var toward := Vector3(ep.x - feet.x, 0.0, ep.z - feet.z)
		if toward.length() < 1.0:
			break
		var step: float = minf(d - r + 4.0, toward.length() * 0.6)
		var at: Vector3 = feet + toward.normalized() * step
		var f2: Vector3 = _floor_under(at, r)
		if f2 == Vector3.INF or f2.distance_to(feet) < 0.5 or not _fits(f2):
			break
		feet = f2
	return best

## How far the node's handler measures the player as standing, NOW, from
## where the body really is (main._eye_position, which is what the DOS
## handlers read).
func _reach_now(ep: Vector3, mode: Dictionary) -> float:
	var from: Vector3 = main.player.global_position
	if String(mode.get("origin", "eye")) == "eye":
		from = _drv.eye()
	if String(mode.get("metric", "3d")) == "2d+window":
		if absf(from.y - ep.y) > float(mode.get("window", Rules.PROX_VERTICAL_WINDOW)):
			return INF
		return Vector2(from.x - ep.x, from.z - ep.z).length()
	return from.distance_to(ep)

## What a comparison comes to at a SHARED standing point.
##
## The key is one key and a step is one step. The 0xEF handler (v1.01
## 0x1386a0) runs for every gate within its 60 units of the eye, the
## sweep walking them in map order, and the 0xF1/0xF2 handler (0x138223)
## for every chain trigger the player has just walked into — DOS fires
## them all, and so does the port. Where the map leaves only one floor
## inside this record's measure and that floor is inside another live
## one's too (`shared`, which the search only falls back to), what the
## game did is this node's row AND the neighbours': their effects are
## there as well, and a chain the two of them SHARE is walked twice and
## left where it started, so this node's own tokens can be missing.
##
## Neither is the node behaving differently from the graph, so what the
## neighbours in reach promise is forgiven — and only that. Anything
## outside their promise still fails, and at a spot that is not shared
## nothing is forgiven at all.
func _share(level, graph: Dictionary, mine: int, use_key: bool,
		spot: Dictionary, res: Dictionary) -> Dictionary:
	if bool(res.get("ok", false)) or not bool(spot.get("shared", false)):
		return res
	var pool: Dictionary = {}
	# The eye AT THE STANDING POINT, which is where the key went down —
	# not where the body has got to since, which for a gate that runs a
	# lift is somewhere else entirely. The same measure _alone_at made
	# when it called this point shared.
	var eye: Vector3 = (spot["feet"] as Vector3) + Vector3(0.0, _eye_h(), 0.0)
	if use_key:
		for x in _doorways_at(spot["feet"] as Vector3):
			if int(x) == mine:
				continue
			var xn: Dictionary = TriggerEquiv.node_of(graph, int(x))
			for t in ((xn.get("first", []) as Array) + (xn.get("second", []) as Array)):
				pool[String(t)] = true
	for g in (level.behaviour.prox_nodes() as Array):
		if int(g.id) == mine or not bool(g.runs()):
			continue
		# A step into the place trips every 0xF1/0xF2 whose radius covers
		# it, whatever is being checked; the 0xEF gates need the key, so
		# they only belong here when one is pressed. A wall button belongs
		# to neither — it is off the sweep and answers the crosshair alone.
		if g.is_wall_button():
			continue
		if g.act_now() == Rules.ACT_PROX_GATE and not use_key:
			continue
		var gp: Vector3 = (g.position as Vector3) + (level.origin as Vector3)
		if eye.distance_to(gp) > float(g.measure()):
			continue
		var gn: Dictionary = TriggerEquiv.node_of(graph, int(g.id))
		# BOTH of the neighbour's activations: the key is pressed twice
		# here, so the neighbour is walked twice too, and what it comes to
		# the second time is as much its doing as the first.
		for t in ((gn.get("first", []) as Array) + (gn.get("second", []) as Array)):
			pool[String(t)] = true
			# A door the neighbour also runs is forgiven WHATEVER travel it
			# makes, not only the full one: a leaf the neighbour started
			# and this walk reversed half way is 115 units of a 128-unit
			# slide, and no list of promised tokens can hold that number.
			if String(t).begins_with("move@"):
				pool["move@" + String(t).substr(5, 5)] = true
	if pool.is_empty():
		return res
	var missing := PackedStringArray()
	var extra := PackedStringArray()
	for t in (res.get("missing", PackedStringArray()) as PackedStringArray):
		if not _in_pool(pool, String(t)):
			missing.append(String(t))
	for t in (res.get("extra", PackedStringArray()) as PackedStringArray):
		if not _in_pool(pool, String(t)):
			extra.append(String(t))
	return {"ok": missing.is_empty() and extra.is_empty(), "want": res.get("want", []),
		"got": res.get("got", PackedStringArray()), "missing": missing, "extra": extra}

static func _in_pool(pool: Dictionary, token: String) -> bool:
	if pool.has(token):
		return true
	return token.begins_with("move@") and pool.has("move@" + token.substr(5, 5))

## The DOORWAYS this point is inside, by their own touch measure
## (MapExit.within: 2D with a vertical window). They matter to the use
## key and to nothing else: main._on_use_pressed offers the press to
## activate_teleport BEFORE anything else, so a key pressed at a gate
## while the feet are in a doorway takes the doorway as well — which is
## the game's own rule and more than the gate promised.
func _doorways_at(feet: Vector3) -> Array:
	var out: Array = []
	for row in _exit_world:
		var at: Vector3 = row[1]
		if absf(feet.y - at.y) > Rules.PROX_VERTICAL_WINDOW:
			continue
		if Vector2(feet.x - at.x, feet.z - at.z).length() <= Rules.TELEPORT_TOUCH_RADIUS:
			out.append(int(row[0]))
	return out

## Is this the ONLY proximity trigger the player would be standing in?
func _alone_at(feet: Vector3, mine: int) -> bool:
	var eye: Vector3 = feet + Vector3(0.0, _eye_h(), 0.0)
	for row in _prox_world:
		if int(row[0]) == mine:
			continue
		if eye.distance_to(row[1] as Vector3) <= float(row[2]):
			return false
	return true

## Is this place outside every DOORWAY's touch measure (the port's 2D
## radius with a vertical window, MapExit.within)? A spot
## that says "nothing may happen here" cannot be one where the player is
## standing in a door: the key takes THAT, and rightly — it is the
## doorway's own rule, not the trigger being checked.
func _clear_of_doorways(feet: Vector3) -> bool:
	for row in _exit_world:
		var at: Vector3 = row[1]
		if absf(feet.y - at.y) > Rules.PROX_VERTICAL_WINDOW:
			continue
		if Vector2(feet.x - at.x, feet.z - at.z).length() <= Rules.TELEPORT_TOUCH_RADIUS:
			return false
	return true

## …and one just outside it, for the checks that say nothing must happen
## there.
func _stand_out(_level, ep: Vector3, mode: Dictionary, alone: int = -1) -> Dictionary:
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
			if alone >= 0 and not _clear_of_doorways(feet):
				continue                          # standing IN a doorway
			if _fits(feet):
				return {"ok": true, "feet": feet, "why": ""}
	return {"ok": false, "feet": Vector3.INF, "why": "nowhere outside it to stand"}

## Every place a record can be answered from, in a ring of sixteen
## directions at nine distances out to the edge of its own measure —
## the search of last resort, when the one layer (c) uses has found
## nowhere to stand. Layer (c) falls back to it as well (M4, 2026-09-22):
## a node this cannot reach either is a node with no floor under it, and
## the 204 rows layer (c) called UNREACHABLE were mostly the near search
## missing a place the game itself puts the player in.
##
## That search is right for what it does: eight directions at nothing,
## 35, 60 and 85 per cent of the reach, nearest first, because the DOS
## player stood AT a thing rather than at the edge of it, and a point far
## out is as likely to lie inside the next trigger along. A mission has to
## REACH the record, and the two it could not reach are the objectives of
## missions 4 and 8 — layer (c) calls both UNREACHABLE and the game plays
## them perfectly well:
##   MAP.292's objective sprite is answered from 83 units away, past the
##   furthest ring the near search tries (73), and the solver's own flood
##   stands in the same place (--solve, 2026-09-22);
##   MAP.280's objective console is answered from 16 units away — nearer
##   than the near search's FIRST ring but not straight under it, where
##   the four downward rays are spent inside the console's own faces
##   before they reach the floor it stands on.
func _stand_wide(level, ep: Vector3, mode: Dictionary, sight: bool = false) -> Dictionary:
	var r: float = float(mode.get("radius", Rules.PROX_GATE_RADIUS)) + float(mode.get("pad", 0.0))
	var tried: int = 0
	var blocked: int = 0
	var near: float = INF
	var tight: Vector3 = Vector3.INF
	var tight_d: float = INF
	for frac in [0.15, 0.2, 0.25, 0.3, 0.5, 0.7, 0.9, 0.95, 1.0]:
		for i in 16:
			var a: float = TAU * float(i) / 16.0
			var at := Vector3(ep.x + cos(a) * r * frac, ep.y, ep.z + sin(a) * r * frac)
			for feet in _floors_under(at, r):
				tried += 1
				var eye: Vector3 = (feet as Vector3) + Vector3(0.0, _eye_h() + PlayerDriver.LIFT, 0.0)
				near = minf(near, eye.distance_to(ep))
				if not _measures(feet, ep, mode, r):
					continue
				if sight and not level.behaviour.reachable(feet - (level.origin as Vector3),
						ep - (level.origin as Vector3)):
					continue                      # a shut door leaf in the way
				if not _fits(feet):
					blocked += 1
					if eye.distance_to(ep) < tight_d:
						tight_d = eye.distance_to(ep)
						tight = feet
					continue
				return {"ok": true, "feet": feet, "why": "", "shared": false}
	# Nowhere the capsule stands free — but the game puts the player in
	# tighter places than this test allows, because a SPAWN never asks
	# whether the capsule fits: it sets the body down and the controller's
	# own margin pushes it out of whatever it is in (main._apply_pending
	# _player, and every marker-set arrival). MAP.280's objective console
	# is such a place — the key answers it from the floor beside it, which
	# every one of these rings found and the capsule test refused — so the
	# nearest of the refused points is where the player is put, and what
	# then happens is the step's own answer.
	if tight != Vector3.INF:
		return {"ok": true, "feet": tight, "why": "", "shared": false, "tight": true}
	# What the search saw, so a record nothing can reach is told apart
	# from one the floor under it is simply missing for.
	return {"ok": false, "feet": Vector3.INF, "shared": false,
		"why": "nowhere in the %.0f-unit measure to stand (%d floor(s) tried, %d of them blocked, the nearest eye %.0f u off)"
			% [r, tried, blocked, near]}


## How high over his feet the running game has the player's eye right now
## — what main._eye_position reports, and so what the DOS proximity
## handlers measure from. A constant was right while every check was made
## on foot and 35 units out in a seat (fly_camera.VEH_EYE).
func _eye_h() -> float:
	if main.player == null or not is_instance_valid(main.player):
		return EYE
	return main._eye_position().y - main.player.global_position.y

## The node's own measure, applied to a pair of positions.
## (The eye sits LIFT higher than the floor point, because that is where
## `place` puts the body — measuring from the floor itself said a gate
## was in reach that the running game then measured out of it.)
func _measures(feet: Vector3, ep: Vector3, mode: Dictionary, r: float) -> bool:
	var from: Vector3 = feet + Vector3(0.0, _eye_h() + PlayerDriver.LIFT, 0.0) \
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
	var n = level.behaviour.hit_node(id)
	if n != null and is_instance_valid(n) and n is MeshInstance3D \
			and (n as MeshInstance3D).mesh != null:
		var mi: MeshInstance3D = n
		return mi.global_transform * mi.mesh.get_aabb().get_center()
	return _epos(level, id)

## A place with a clear line at `aim` whose first collider is the node
## itself — where a player could actually shoot it from.
func _shooting_spot(level, id: int, aim: Vector3) -> Dictionary:
	var all: Array = _shooting_spots(level, id, aim, 1)
	if all.is_empty():
		return {"ok": false, "feet": Vector3.INF, "why": "no line of fire to it"}
	return {"ok": true, "feet": all[0], "why": ""}

## Up to `limit` such places, nearest ring first.
func _shooting_spots(level, id: int, aim: Vector3, limit: int) -> Array:
	var out: Array = []
	var target = level.behaviour.hit_node(id)
	for dist in SHOT_DISTANCES:
		for d in RING:
			if d == Vector2.ZERO:
				continue
			var at := Vector3(aim.x + d.x * dist, aim.y, aim.z + d.y * dist)
			for feet in _floors_under(at, dist):
				if not _fits(feet):
					continue
				var q := PhysicsRayQueryParameters3D.create(feet + Vector3(0.0, EYE, 0.0), aim)
				q.collision_mask = ZoneLayers.world_mask()
				q.collide_with_areas = true
				q.exclude = [main.player.get_rid()]
				var hit := _space.intersect_ray(q)
				if not hit.has("collider"):
					continue
				var c = hit["collider"]
				while c != null and c is Node:
					if c == target:
						out.append(feet)
						if out.size() >= limit:
							return out
						break
					c = (c as Node).get_parent()
	return out

## The graph's `first` for an 0xEF gate the player is standing in whose
## chain ends in doorway `id` — what the key really does here. Empty when
## no such gate is in reach of where he stands now.
func _gate_chaining_to(level, graph: Dictionary, id: int) -> Array:
	var eye: Vector3 = _drv.eye()
	for g in (level.behaviour.prox_nodes() as Array):
		if g.act_now() != Rules.ACT_PROX_GATE:
			continue
		if eye.distance_to((g.position as Vector3) + (level.origin as Vector3)) \
				> float(g.measure()):
			continue
		if level.behaviour.chain_exit(int(g.id)) != id:
			continue
		return (TriggerEquiv.node_of(graph, int(g.id)) as Dictionary).get("first", [])
	return []

## The port's one surviving invented rule (rules_skynet._modes): a named
## variant-1 mesh with state bit 3 answers the use key, not the walk.
func _is_wall_button(level, id: int) -> bool:
	var e = level.map.entities_by_off.get(id)
	if e == null:
		return false
	return (e.flags & 3) == 1 and (level.triggers.state(id) & 8) != 0 and e.name_index >= 0

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
	var bad := PackedStringArray()
	for t in want:
		var tok: String = String(t)
		if not tok.begins_with("move@"):
			continue
		var id: int = tok.substr(5, 5).hex_to_int()
		var n: Node = level.behaviour.mover_node(id)
		if n == null:
			bad.append("%05x is no mover here" % id)
			continue
		var travel: float = float(tok.split("+")[-1]) if tok.find("+") > 0 \
			else -float(tok.split("-")[-1])
		var span: float = float(n.span())
		if absf(span - absf(travel)) > 0.5:
			bad.append("%05x travels %.0f, not %.0f" % [id, span, absf(travel)])
	return " ".join(bad)

## …and once they have arrived: the DOS handlers clear their own enable
## bit at the end of the travel and the next trigger runs them back, so
## the bit must be down and the direction flipped. Continuous rotators
## never arrive and are left out.
func _mover_settled(level, want: Array) -> String:
	var bad := PackedStringArray()
	for t in want:
		var tok: String = String(t)
		if not tok.begins_with("move@"):
			continue
		var id: int = tok.substr(5, 5).hex_to_int()
		var n: Node = level.behaviour.mover_node(id)
		var e = level.map.entities_by_off.get(id)
		if n == null or e == null:
			continue
		if bool(n.spins()):
			continue
		if level.triggers.enabled(id):
			bad.append("%05x still enabled after its travel" % id)
		elif float(n.dir) > 0.0:
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
##   projectile_no_hit     a damage stage the player cannot reach because
##                         he is DRIVING: on the jeep and HK maps the only
##                         gun is the vehicle's, whose bolt is a
##                         projectile, and projectile._is_target stops a
##                         bolt only on the `enemy` group — so it flies
##                         straight through every prop and the car is
##                         never hit at all. The same holds on foot for
##                         the laser and plasma guns; a rocket only
##                         reaches one through its splash. Nothing to do
##                         with the destructibles, and left for a decision
##                         about the weapon code (step 5g, 2026-09-22)
##   port_use_reach        the key still fires it from outside the DOS
##                         measure. The one row left is a WALL BUTTON,
##                         where that is the port's kept rule rather than
##                         a fault: what limits a button is the 600-unit
##                         crosshair and the crosshair finds the MESH, so
##                         a point twenty units outside the record's own
##                         reach still has the panel under the sights
##                         (fly_camera._try_activate). The negative check
##                         measures to the record, which a button is not
##                         answered from
##   second_activation     the first activation agrees and the second does
##                         not
##   chain_silent          nothing happened at all where the graph says
##                         something should — the row carries how far the
##                         eye really was
##   chain_short           the chain did less than the walk says
##   chain_extra           …or more
##   path_window           a marker-path vehicle only picks its path up
##                         inside the DOS five-cell actor window, which
##                         the graph does not model
##   mover_absent          the graph names a mover the level built no node
##                         for, so the travel it promises has nothing to
##                         make it
##   loaded_state          the simulation starts from the byte the MAP was
##                         AUTHORED with, and some records have spent it
##                         before a player can reach them: MAP.231's
##                         eighteen lights are laid down with bit 0 up,
##                         the light handler runs on the first tick of the
##                         level and clears it (the DOS sweep does the
##                         same), so the first press a player makes is the
##                         graph's SECOND walk of them. Settled
##                         2026-09-22: the graph runs that first sweep
##                         before it simulates (trigger_graph._first_sweep)
##                         and the reset replays the cues the branch fires
##                         on entering the tree (_replay_load); eight lock
##                         lines moved, and the one row this tag pinned
##                         passes. Kept for a record the sweep still misses
##   exit_forced           a doorway laid down with bit 0 already up, and a
##                         gate whose chain ends in it. The walk turns the
##                         bit OFF, so the graph's first activation takes
##                         no map change and its second does. The port
##                         walks the chain once and then arms and fires
##                         the doorway anyway (Behaviour.use_exit_through,
##                         the owner's rule of 2026-09-16: guarding the
##                         walk on the exit's own bit is what lost the
##                         door sound, and DOS performs one map change per
##                         level instance either way). Runtime and graph
##                         disagree by design until that rule is revisited
## Gone with M4 (2026-09-22): demolish_spent, 4 rows — one the GRAPH and
## three this file. ObjFlipLink (v1.01 0x139caa) only walks the links and
## twiddles state bytes, so a demolition waits for the next entity sweep
## and finds nothing where ObjHit has already destroyed the record: the
## runtime was right to refuse it, and the simulation now carries the
## death (trigger_graph._dies_when_fired). The other three were the
## barrel — three rifle shots into a rack of crates take the crate in
## FRONT with them — and the death edge is measured after a reset now.
## Gone with M4 (2026-09-22), all of them the HARNESS rather than the game
## — the standing point, the clock or the body the checks put down:
##   chain_silent, chain_short, chain_extra, second_activation,
##   port_use_reach: 64 rows. Three causes. The player was left in the
##   VEHICLE the mission table gives a map, and a gunship holds its own
##   ground clearance, so twenty-four of MAP.272's gates were pressed
##   from two hundred units over them; the body does not stay where it is
##   put, so the key went down from a point the search had measured and
##   the controller had since left; and where a map leaves only one floor
##   inside a record's measure, that floor is inside the next record's
##   too, so the one key fired both and the two chains that share a
##   suffix cancelled it (_share forgives what the neighbours explain,
##   and nothing else).
##   path_window: 2 rows, the RUNTIME. The port announced the path where
##   the machine picked it up; DOS commits at the flip, and that is what
##   the graph writes down. Moved to Behaviour.present_fire.
##   projectile_no_hit: 3 rows, the same on-foot rule — a soldier's rifle
##   is a hitscan and reaches what a vehicle bolt flew through.
## Gone with M3 step 5b (2026-09-16): exit_chain_skipped (a gate whose
## chain ends in a doorway walks that chain now), demolish_once (the
## simulation reads its own spent flag), loop_no_handler (the SoundLoop
## node has a handler), button_walk (never seen).
## Gone with step 5g (2026-09-22): destruct_stage_count, all 74 of them.
## Twelve were this file picking the rifle once a map while the checks
## walked the player over weapon pickups that arm themselves; forty-three
## were the GRAPH promising a damage stage to a car that is already some
## other car's last stage and has no TRANSFRM.PRS template of its own, on
## which the DOS handler returns at once (0x120833 → the lookup at
## 0x12078a sets carry, `jb` leaves); the nineteen that are left are the
## vehicle maps and are pinned as projectile_no_hit.
const XFAIL_TAGS: PackedStringArray = [
	"port_use_reach", "projectile_no_hit", "second_activation",
	"chain_silent", "chain_short", "chain_extra", "path_window",
	"mover_absent", "loaded_state", "exit_forced",
]

static func hygiene(text: String) -> PackedStringArray:
	var bad := PackedStringArray()
	var kinds: PackedStringArray = Rules.KINDS
	for raw in text.split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("#"):
			# The head is fixed text — the two lines that say what a row
			# is, and the glossary that says what each tag claims (M4). A
			# comment of anyone's own is still refused, so nothing of the
			# game's words can reach the file this way.
			if not XFAIL_HEAD.has(line):
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

## The head of the file: the only comment lines it may carry, and the
## glossary of the tags, so a reader of the list alone knows what each
## pinned row is claiming (M4, 2026-09-22). Kept to the same vocabulary
## as the rows — keywords and numbers, no names, no paths, none of the
## game's own words.
const XFAIL_HEAD: PackedStringArray = [
	"# known failures - map, id, act, kind, tag; the gate gives only on a new one",
	"# ids lower hex, act bytes upper hex; keywords and numbers only",
	"# what each tag means:",
	"#   chain_silent       nothing happened where the graph says something should",
	"#   chain_short        the chain did less than the walk says",
	"#   chain_extra        ... or more",
	"#   second_activation  the first activation agrees and the second does not",
	"#   port_use_reach     the key still fires it from outside the DOS measure;",
	"#                      a wall button is reached by the crosshair, not by that",
	"#   projectile_no_hit  the only gun that reaches it fires a projectile, and a",
	"#                      projectile is stopped by no prop",
	"#   path_window        a marker path is only driven inside the DOS actor window",
	"#   mover_absent       the graph names a mover the level built no node for",
	"#   loaded_state       the graph simulates from the authored state byte, which",
	"#                      the map has already spent by the time a player is there",
	"#   exit_forced        the port takes a doorway a chain reaches whatever the",
	"#                      walk did to its bit; the walk alone would shut it",
]

# ---------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------
func _report() -> void:
	var by_res: Dictionary = {}
	var fails: Array = []
	var new_fails: Array = []
	# Only the pinned failures of the maps this run checked can have been
	# fixed by it: a subset or a shard says nothing about the others.
	var fixed: Dictionary = {}
	var ran: Dictionary = {}
	for r in _rows:
		ran[int((r as Dictionary)["map"])] = true
	for key in _xfail:
		if ran.has(int(String(key).split(" ")[0])):
			fixed[key] = _xfail[key]
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
	# A shard also says which maps its rows are, by their place in the run's
	# own map list, so tools/verify_gate.py can put N shards' rows back in
	# the order one process writes them.
	if shard_spec(String(main._cli.get("verify-shard", ""))).is_empty():
		return
	var m := FileAccess.open(path + ".maps", FileAccess.WRITE)
	if m == null:
		push_warning("[verify] cannot write %s.maps" % path)
		return
	for b in _blocks:
		m.store_line("%d %s %d" % [(main._maps as Array).find(String(b[0])), String(b[0]), int(b[1])])
	m.close()
