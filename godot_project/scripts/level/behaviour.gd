## The Behaviour branch of a level at run time (docs/map_format_plan.md
## §8, phase F2).
##
## The branch holds one node per entity with behaviour (built by
## scripts/level_behaviour.gd at import) and this script is what the DOS
## object layer LOOKS like on top of them: the sound a chain plays, the
## line it prints, the objective it counts, the ambient loop it starts
## and stops.
##
## What it no longer is, since step 5a of docs/trigger_graph_plan.md, is
## a keeper of state. The chain walk (ObjFlipLink) and the decision that
## a cue has fired moved to scripts/triggers/trigger_runtime.gd, which
## holds the state bytes, the act bytes and the links of the whole level
## and is the only thing that writes them; the mirror into the MAP
## records is gone with it, and the records are read-only data now. This
## branch is what the runtime calls OUT to:
##
##   present_fire(id)     run that entity's node — play, print, count —
##                        and say whether it is spent afterwards. The
##                        runtime decides what the entity's bit and act
##                        byte become.
##   present_silence(id)  the chain took the bit away: a level kind (the
##                        0xEE ambient loops) stops.
##   targets_of(id)       where the chain goes next, as the bake wired it.
##   node_bytes(id)       the act and state a node was baked with — for a
##                        branch the runtime has no records for.
##
## Since step 5c it is also where the PROXIMITY class lives: the 0xEF
## gates, the 0xF1/0xF2 chain triggers and the wall buttons watch the
## player and answer the use key from their own nodes
## (scripts/level/trigger.gd), and this holds the sweep over them — the
## order the map put them in, the key's edge, and what a proximity node
## still has to ask the classes that have not moved yet (the record it
## was made from, whether it has been shot to pieces, and taking the
## doorway a gate's chain ends in). The state those nodes read and write
## is the runtime's, as everything here is.
##
## Step 5d brought the four classes that watch no player at all: the
## countdown RELAY (0x2C), the SPAWN sprites (0xF3), the WATER movers
## (0xd6-0xda) and the map LIGHTS (0x01-0x12). Each of them runs on its
## own node (scripts/level/raw_action.gd) and this holds the four sweeps
## over them, in the order and in the places the one long loop ran them,
## plus the two things that are the LEVEL's rather than any one record's:
## the lamps main.gd placed for this map and the flicker clock they share.
##
## Step 5e brought the MOVERS — the doors, the gates, the lifts and the
## rotators (scripts/level/mover.gd). Each one steps its own travel and
## remembers its own progress, and the mesh it moves is the one the level
## loader built, handed to it at registration: that is what register_mover
## is for, and being registered IS being on the sweep. A mover whose .3D
## the archives do not hold has never moved, and still does not.
##
## Step 5f brought the PATH VEHICLES — the cargo truck, the convoy, the
## boss chase and the pick-up HK (scripts/level/path_vehicle.gd). Those
## are the one class with no baked twin: a vehicle's record is a placement
## MARKER, and markers get no node at all (level_behaviour.kind_of), so
## the node is built here at registration and kept in its own container.
## It is deliberately NOT in the map's node index below — nothing flips a
## marker and nothing presents one.
##
## Step 5g brought what BREAKS: ObjHit itself, the TRANSFRM.PRS damage
## stages of acts 0x18/0x19, the 0x1B killing blow and the destruction
## that follows a spent pool of hit points. The stage a wreck is showing
## is its own node's (scripts/level/destructible.gd), which is the only
## thing that remembers one; the pool and the spent flag went where every
## other per-entity byte went in step 5a, to the one writer; and the
## sweeps, the blast and the drop are here, because a blast reaches
## everything around it and a drop belongs to the level, not to the thing
## that died.
##
## The `state` export on the nodes is the byte the MAP was AUTHORED with
## and stays that: nothing writes it at run time any more, so there is no
## second copy to disagree with the runtime. The one node-side mirror
## left is `spent` on the cue classes — their own guard against firing
## twice — and sync_from_runtime puts it back after a restore.
##
## Every cue that fires is still ANNOUNCED on the level's trigger event
## bus (`bus`, scripts/triggers/trigger_bus.gd — M3 step 3). That is an
## observer and nothing more: nothing below asks whether anything is
## listening and it behaves the same when the bus is null.
##
## F2 runs class by class, so while the level loader still builds the same
## meshes from the records, their geometry in this branch stays asleep
## (sleep_geometry) — the movers' included: a Mover node drives the
## loader's mesh and leaves its own Body hidden, or a map would show two of
## every door. When the loader's half goes, that sleep goes with it —
## except for the proximity shapes, which sleep for good: a trigger's
## measure is evaluated, never an Area3D overlap, so that the running game,
## the verifier and the lock all measure one way (plan §2).

extends Node3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")
const PathVehicle := preload("res://scripts/level/path_vehicle.gd")
const Explosion := preload("res://scripts/explosion.gd")
const Projectile := preload("res://scripts/projectile.gd")
const PickupData := preload("res://scripts/pickup_data.gd")

## The container the path vehicles are built into. Not a baked one — see
## the header — so the index below steps over it by name.
const VEHICLES: StringName = &"Vehicles"

## A hint cue ([G1]..) fired: index = act - 0x1C.
signal hint_message(index: int)
## An objective cue ([M1]..) fired: index = act - 0x26.
signal objective_complete(index: int)
## The 0x2B cue fired.
signal mission_failed()
## Acts 0xd6-0xda (handler 0x121160): the map's water level glides to a
## new target. `absolute` = go to this Y, otherwise add it to the target.
## MAP.254's sewers flood and drain as the walls and valves are opened.
signal water_level(value: float, absolute: bool)
## A destroyed object drops an item — a crate its ammo, a locker a medkit
## (DOS FUN_00124293 → FUN_00124119, the 0x423d6 table's third word). The
## position is ZONE-LOCAL: the drop becomes a child of the level's sprites
## and is put on the map's own heightmap (LevelLoader.spawn_item).
signal item_dropped(pos: Vector3, drop_type: int)

## How often the flicker and the strobe are allowed to change a lamp. The
## DOS handlers (0x137713 / 0x13773b) run on the engine tick, which is
## faster than anything worth watching; this is the port's rate and one
## clock serves every lamp of the map.
const LIGHT_FX_TICK: float = 1.0 / 20.0

var _by_id: Dictionary = {}          # id → node
var _indexed: bool = false
## The level's trigger runtime (scripts/triggers/trigger_runtime.gd): it
## owns the state and drives everything below. Null for a branch nobody
## plays — the editor opening a baked scene, the bake itself — and then
## the nodes' own baked bytes are all there is.
var runtime: RefCounted = null
## The level's trigger event bus (scripts/triggers/trigger_bus.gd, M3
## step 3): every cue that fires is announced on it. An OBSERVER — null
## is the normal case in a test that builds a branch by hand, and nothing
## below reads anything back.
var bus: RefCounted = null
## The classes that have not moved off the records yet — the exits and the
## per-tick bookkeeping of a chain walk (scripts/action_system.gd). Two
## things are reached through it: the MAP record's own read-only data, and
## the doorway a gate's chain ends in.
## Step 5h takes it away with the rest of ActionSystem; null is an
## ordinary state (a branch built by hand in a test) and the nodes fall
## back to what the bake wrote on them.
var action: RefCounted = null
## Where this zone stands in the world (LevelLoader.Level.origin). Every
## node here holds DOS coordinates, i.e. ZONE-LOCAL Godot ones, and the
## one thing below that hands a position OUT of them is the water level a
## 0xd6 sets absolutely. Zero for a lone map, where the two spaces are the
## same thing.
var zone_origin: Vector3 = Vector3.ZERO
## file_off → the OmniLight3D main.gd placed for a variant-2 record
## (_place_map_lights). Handed over whole and replaced whole: changing
## DYNAMIC LIGHTS frees every lamp and builds them again.
var map_lights: Dictionary = {}

## Every Trigger node of the map by id, and the ones the DOS handlers
## actually run for, in the order the MAP lists them — the sweep list
## ActionSystem used to build at setup. An 0xEF whose state bits 1-2 are
## not both clear or both set is not a gate and is on neither.
var _prox: Array = []
var _prox_by_id: Dictionary = {}
## The use key's first frame. DOS 0x1386a0 opens with `cmp [0x2c7f], 1`
## — ACTIVATE went down this very frame — and only then flips every live
## 0xEF gate within 60 u; walking into one does nothing (disassembled
## 2026-09-11). The port had them fire on approach, so the jeep drove
## into MAP.220's truck by itself. Set by press_use, spent by prox_tick.
var _use_edge: bool = false

## The step-5d classes, each in the order the MAP lists them — the sweep
## lists ActionSystem.setup used to build. A record is on one of the first
## three by the act byte and the variant it was authored with
## (RawAction.sweep_class); the spawn sprites come in at registration
## instead, with the robot the level loader built for them.
var _relays: Array = []
var _water: Array = []
var _lights: Array = []
var _spawns: Dictionary = {}          # file_off → its RawAction node
## The flicker clock every lamp of the map shares.
var _light_fx_clock: float = 0.0

## The movers with a mesh to move, in the order the MAP lists them — the
## order ActionSystem's own dictionary was built in, which is the order the
## level loader registers them. file_off → its Mover node; a mover whose
## mesh the archives do not hold is not here and never runs.
var _movers: Dictionary = {}

## The path vehicles, in the order the MAP lists their actor markers —
## marker file_off → its PathVehicle node. Built at registration (see the
## header); a map with no vehicle never builds the container either.
var _vehicles: Dictionary = {}

## The step-5g classes. `_hittable` is the mesh the level loader built for
## a record, by file offset — what a blast goes off at and what leaves the
## world when a pool runs out; every action target is in it, movers
## included, exactly as ActionSystem's own node index was. `_wrecks` are
## the records with TRANSFRM.PRS damage stages (registration IS membership,
## and it makes the same test the DOS lookup does — by the object's own
## mesh name), `_rams` the ones a CHAIN can break (act 0x18/0x19) and
## `_demolishers` the ones a chain KILLS (act 0x1B), both in the order the
## MAP lists them.
var _hittable: Dictionary = {}
var _wrecks: Dictionary = {}
var _rams: Array = []
var _demolishers: Array = []

func _ready() -> void:
	_ensure_index()
	# One-shots armed in the MAP data fire once at level start (a door
	# sound a map starts enabled, a radio line on entry). On a map entered
	# again, or loaded from a save, main.gd has laid the saved state over
	# the runtime BEFORE this branch enters the tree, so a cue that already
	# fired has its bit down and does not replay.
	for id in _by_id:
		if runtime != null:
			if runtime.enabled(int(id)):
				runtime.fire(int(id))
		elif (state_of(_by_id[id]) & 1) != 0:
			present_fire(int(id))

## F2 transition: while the loader still builds the movers, the
## destructibles, the damageables and the button panels from the
## records (action targets with their own bodies), the same geometry in
## this branch must not be seen or collided with — the e2e gate sweep
## found a second, closed BIGDOOR box the moment the branch entered the
## tree. Meshes hide, shapes switch off, areas stop monitoring; the
## sound players keep playing. Narrow this as each class goes live.
static func sleep_geometry(root: Node) -> void:
	for c in root.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = false
		elif c is CollisionShape3D:
			(c as CollisionShape3D).disabled = true
		elif c is Area3D:
			(c as Area3D).monitoring = false
			(c as Area3D).monitorable = false
		sleep_geometry(c)

func _ensure_index() -> void:
	if _indexed:
		return
	_indexed = true
	for c in get_children():
		if not (c is Node3D):            # the Mission node
			continue
		if c.name == VEHICLES:
			# Built here at run time, not by the bake: a path vehicle's
			# record is a placement marker, which is no part of the map's
			# entity index — nothing flips one and nothing presents one.
			continue
		for n in c.get_children():
			_by_id[id_of(n)] = n
			if n.has_signal("fired"):
				n.connect("fired", _on_cue_fired.bind(n))
			if n.has_method("prox_watch"):
				n.set("branch", self)
				_prox_by_id[id_of(n)] = n
				if bool(n.call("on_sweep")):
					_prox.append(n)
			elif n.has_method("mover_watch"):
				# A mover joins its sweep when the loader hands it the mesh
				# it moves (register_mover), not here.
				n.set("branch", self)
			elif n.has_method("sweep_class"):
				n.set("branch", self)
				match String(n.call("sweep_class")):
					"relay": _relays.append(n)
					"water": _water.append(n)
					"light": _lights.append(n)
			elif n.has_method("break_down"):      # a wreck with damage stages
				n.set("branch", self)
			elif n.has_method("adopt"):           # a plain damageable mesh
				n.set("branch", self)
			# A chain that reaches one of these breaks it or kills it, and
			# which of the two is the act byte's business, not the node
			# class's: a demolition prop whose mesh HAS damage stages is
			# baked as a wreck (level_behaviour.kind_of), so the sweeps go
			# by the byte the record was authored with, as the one long
			# loop's own lists did (ActionSystem.setup).
			match act_of(n):
				Rules.ACT_DESTRUCT_A, Rules.ACT_DESTRUCT_B: _rams.append(n)
				Rules.ACT_DEMOLISH: _demolishers.append(n)

## The node of entity `id` (the MAP file offset), or null.
func node(id: int) -> Node:
	_ensure_index()
	return _by_id.get(id)

static func id_of(n: Node) -> int:
	if "id" in n:
		return int(n.get("id"))
	return int(n.get_meta("id", -1))

## The DOS state byte a node was BAKED with — an export on the scripted
## kinds, a meta entry on the scriptless SoundLoop. Not the live one:
## that is the runtime's (TriggerRuntime.state).
static func state_of(n: Node) -> int:
	if "state" in n:
		return int(n.get("state"))
	return int(n.get_meta("state", 0))

static func act_of(n: Node) -> int:
	if "act" in n:
		return int(n.get("act"))
	return int(n.get_meta("act", 0))

# ---------------------------------------------------------------------
# What the runtime calls
# ---------------------------------------------------------------------
## Run entity `id`'s node: the cue plays, prints or counts, and says so
## on the bus. Returns {} when there is no node or the node has nothing
## to fire — the runtime then leaves the entity's bit and act byte alone
## — and {"spent": …} otherwise, which is what a cue DOS retires (act ←
## 0xFF) reports back.
func present_fire(id: int) -> Dictionary:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n == null or not n.has_method("fire"):
		return {}
	# A cue DOS has RETIRED does nothing at all when its bit goes up again
	# — and must not be announced as if it had. The bus used to say "hint"
	# on every later flip of a chain whose message had long since been
	# read, which is what the step-4 verifier saw as a second activation
	# doing more than the graph said it would.
	var was_spent: bool = "spent" in n and bool(n.get("spent"))
	n.call("fire")
	if not was_spent:
		_announce_fire(n)
	return {"spent": "spent" in n and bool(n.get("spent"))}

## The chain took the bit away from a LEVEL kind: the 0xEE ambient loop
## that has been running since it went up stops here.
func present_silence(id: int) -> void:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n != null and n.has_method("silence"):
		n.call("silence")

## Where a flip of `id` goes next — the ids the bake wired this node's
## `targets` to. Empty when the node has none, or there is no node: the
## runtime then follows the entity's own link.
func targets_of(id: int) -> Array:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n == null:
		return []
	var paths: Array = []
	if "targets" in n:
		paths = n.get("targets")
	elif n.has_meta("target"):
		paths = [n.get_meta("target")]
	var out: Array = []
	for p in paths:
		var t: Node = n.get_node_or_null(p)
		if t != null:
			out.append(id_of(t))
	return out

## The act and state byte node `id` was baked with, for a runtime that
## has no MAP record for it (a branch built by hand). {} when there is no
## such node.
func node_bytes(id: int) -> Dictionary:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n == null:
		return {}
	return {"act": act_of(n), "state": state_of(n)}

# ---------------------------------------------------------------------
# The proximity class (step 5c)
# ---------------------------------------------------------------------
## Every position below is ZONE-LOCAL — the DOS coordinates the records
## and the nodes are in. The caller takes the player's world position into
## that space once (ActionSystem.zone_origin) and everything here works in
## it, as the sweep it came from did.

## The triggers the handlers run for, in map order. A caller that wants
## one of them wants its id, where it stands and how far it reaches, all
## of which the node answers.
func prox_nodes() -> Array:
	_ensure_index()
	return _prox

## The Trigger node of entity `id`, whether or not it is on the sweep
## (a state-04 0xEF prop has one and is not a gate), or null.
func prox_node(id: int) -> Node:
	_ensure_index()
	return _prox_by_id.get(id)

## The use key went down — every live 0xEF gate in reach answers it on
## the next sweep, wherever the crosshair was pointing.
func press_use() -> void:
	_use_edge = true

## One tick of every proximity trigger, from the eye. Run from the level's
## per-tick sweep (ActionSystem.tick) in the place it has always held:
## after the movers, before the one-shot classes that read what a chain
## armed this tick.
##
## Variant-1 meshes with state bit 3 — the wall buttons — are not here:
## walking past a button must not press it, so the key and the crosshair
## are the only ways they run at all.
func prox_tick(eye: Vector3) -> void:
	_ensure_index()
	for t in _prox:
		if t.is_wall_button():
			continue
		if runtime != null and runtime.spent(int(t.id)):
			continue
		t.prox_watch(eye, _use_edge)
	_use_edge = false
	for t in _prox_by_id.values():
		t.edge_done = false

## Called right after the player is placed: latch every trigger the spawn
## point already lies inside, so a return exit that drops the player
## beside the gate it came through (MAP.210 marker 27 is 64 units from the
## bunker gate; MAP.211's start sits inside its DOOR gate) waits for him
## to step out and back in instead of bouncing straight back.
func prox_arm(eye: Vector3) -> void:
	_ensure_index()
	for t in _prox:
		t.prox_arm(eye)

## The use key reached the record at `id` — through the crosshair ray that
## found its mesh, or through use_nearby. `eye` is Vector3.INF for a
## caller that has picked both the entity and the place and says so.
## False when there is no proximity node for that id: the record is not
## one of these and the caller's own use-key path applies.
func prox_use(id: int, eye: Vector3) -> bool:
	var t: Node = prox_node(id)
	return bool(t.prox_use(eye)) if t != null else false

## Use key with nothing activatable under the crosshair: operate the
## nearest WALL BUTTON the player stands at. Those are the records the
## sweep leaves alone, so this and the crosshair ray are the only ways
## they run at all.
##
## Nothing else is reached from here any more. Until 2026-09-16 this swept
## every variant-1 proximity record and every unchained cue within 130
## units of the FEET — a hand reach the port invented, three times the
## radius of the handler it was standing in for. So the key opened a gate
## from well outside the 60 units DOS measures, which is most of what the
## step-4 verifier called port_use_reach (157 of its failures). A gate is
## the key's, but on the handler's own terms: press_use sets the edge and
## the sweep fires every gate within its radius OF THE EYE.
##
## Measured as the record's own handler measures it: 3D, from the eye, at
## the radius the slot carries (Trigger.measure).
func use_nearby(eye: Vector3) -> bool:
	_ensure_index()
	var best: Node = null
	var best_d: float = INF
	for t in _prox:
		if runtime != null and runtime.spent(int(t.id)):
			continue
		if not t.is_wall_button():
			continue
		var d: float = (t.position as Vector3).distance_to(eye)
		if d > float(t.measure()) or d >= best_d:
			continue
		best_d = d
		best = t
	if best == null:
		return false
	return bool(best.prox_use(eye))

## The first 0xEF gate in reach of the eye whose chain ends in a doorway —
## DOS's own way through a door, and what the use key takes first.
##
## Distance and nothing else, as the handler does it: the 0xEF handler
## casts no ray, and the key's own sweep casts none either. A ray here
## refused MAP.241's doorway gate from 38 units away, where the map's own
## geometry stands between the sprite and the floor the player is on.
func gate_to_exit(eye: Vector3) -> Node:
	_ensure_index()
	for t in _prox:
		if t.act_now() != Rules.ACT_PROX_GATE:
			continue
		if runtime != null and runtime.spent(int(t.id)):
			continue
		if not t.inside(eye):
			continue
		if chain_exit(int(t.id)) < 0:
			continue
		return t
	return null

## Take the doorway `gate`'s chain ends in. The exits are still the action
## system's (step 5h), so it is asked to do it — the walk of the gate's
## own chain is the gate's, and happens there.
func use_exit_through(gate: Node) -> bool:
	return bool(action.use_exit_through(gate)) if action != null else false

## The first 0xF0 exit down the chain from `id`, or -1. The live link and
## act bytes, which are the runtime's: a path whose link play has cut goes
## nowhere any more.
func chain_exit(id: int) -> int:
	if runtime == null:
		return -1
	var cur: int = id
	var seen: Dictionary = {}
	while cur > 0 and not seen.has(cur):
		seen[cur] = true
		if int(runtime.act(cur)) == Rules.ACT_TELEPORT:
			return cur
		cur = int(runtime.link(cur))
	return -1

## Walk the chain from `id` — ObjFlipLink, which is the runtime's. What
## is not is the bookkeeping around it: which entities a walk armed during
## this tick, for the one-shot sweeps that have not moved yet, and the lit
## face of a BUTTON mesh the loader built. When the last of those moves
## (step 5h) this goes straight to the runtime.
func flip_chain(id: int) -> void:
	if action != null:
		action.flip_chain(id)
	elif runtime != null:
		runtime.flip(id)

## The MAP record of `id` — the read-only data the map was authored with,
## which is where the static half of a rule lives (a wall button's name
## and variant). Null when the branch has no action system to ask.
func record_of(id: int):
	return action.record(id) if action != null else null

## Everything the proximity nodes remember about the player, forgotten —
## what the verifier clears between two checks of the same map.
func prox_forget() -> void:
	_ensure_index()
	_use_edge = false
	for t in _prox_by_id.values():
		t.prox_forget()

# ---------------------------------------------------------------------
# The movers (step 5e)
# ---------------------------------------------------------------------
## The level loader has built the mesh of mover `e`: hand it to the record's
## own node, which moves it from here on, and put that node on the sweep.
## Being registered IS being on the sweep, exactly as it was when the same
## call built a dictionary entry in ActionSystem — a mover whose .3D is
## missing from the archives never reaches this and has never moved.
func register_mover(e, node: Node3D) -> void:
	_ensure_index()
	var n: Node = _by_id.get(e.file_off)
	if n == null or not n.has_method("mover_watch"):
		push_warning("[behaviour] no Mover node for the mover @%05x" % e.file_off)
		return
	# The entity's raw 11-bit Euler triple: a swing advances one component
	# of it and the basis is rebuilt from all three.
	n.adopt(node, Vector3(float(e.off_x & 0x7FF), float(e.off_y & 0x7FF),
		float(e.off_z & 0x7FF)))
	_movers[e.file_off] = n

## One tick of every mover. Run from the level's per-tick sweep
## (ActionSystem.tick) in the place it has always held: after the lights,
## before the proximity triggers — the movers carry the collision bodies
## the player stands on, and a trigger he trips this tick must see them
## where this tick left them.
func mover_tick(delta: float) -> void:
	_ensure_index()
	for off in _movers:
		_movers[off].mover_watch(delta)

## The Mover node of entity `id` — one with a mesh to move — or null.
func mover_node(id: int) -> Node:
	_ensure_index()
	return _movers.get(id)

## Every one of them, in map order.
func mover_nodes() -> Array:
	_ensure_index()
	return _movers.values()

## Is the entity at `off` a mover (door/gate/lift/rotator) this level
## actually moves? (Not to be confused with ActionSystem.is_mover, which
## asks the same of an ACT byte and knows nothing of this map.)
func has_mover(off: int) -> bool:
	_ensure_index()
	return _movers.has(off)

## …and one that translates or swings as a solid piece, so its mesh gets
## the DOS-style box collider rather than its trimesh (main.gd).
func is_solid_mover(off: int) -> bool:
	var n: Node = mover_node(off)
	return n != null and bool(n.is_solid())

## One line per mover — the console's `movers`.
func mover_report() -> String:
	_ensure_index()
	var out: PackedStringArray = PackedStringArray()
	for off in _movers:
		out.append(String(_movers[off].report()))
	return "\n".join(out) if out.size() > 0 else "no movers"

## The map overlay's share of the movers: how far each has travelled and
## which way it goes next. The shape is unchanged (step 5h moves the save
## format itself), so an older save still reads.
func mover_snapshot() -> Dictionary:
	_ensure_index()
	var out: Dictionary = {}
	for off in _movers:
		out[off] = _movers[off].snapshot()
	return out

## …and the way back. A mover the snapshot does not know is left where it
## stands (a variant map carries only the records that match).
func mover_restore(snap: Dictionary) -> void:
	_ensure_index()
	for off in snap:
		var n: Node = _movers.get(off)
		if n != null:
			n.restore(snap[off] as Array)

## Every mover that thinks it is in the middle of a run, told it is not —
## what the verifier clears between two checks of the same map. Where a
## mover STANDS is restore_state's business, not this.
func mover_forget() -> void:
	_ensure_index()
	for off in _movers:
		_movers[off].mover_forget()

# ---------------------------------------------------------------------
# The path vehicles (step 5f)
# ---------------------------------------------------------------------
## The level loader has built the machine for the actor marker `e` (an
## enemy start whose type runs AI state 11 and whose own link is the first
## marker of a path): give the marker a node of its own and put it on the
## sweep. Being registered IS being on the sweep, exactly as it was when
## the same call built a dictionary entry in ActionSystem — an actor the
## loader builds no machine for never reaches this and has never driven.
func register_path_vehicle(e, actor: Node3D) -> void:
	var n: Node3D = PathVehicle.new()
	n.name = ("Vehicle_%d_%05x" % [e.enemy_type, e.file_off]).validate_node_name()
	n.id = e.file_off
	n.head = e.link_next
	n.vehicle = e.enemy_type
	n.position = Vector3(float(e.x), -float(e.y), -float(e.z))
	n.branch = self
	n.actor = actor
	_vehicles_root().add_child(n)
	_vehicles[e.file_off] = n

## The container, made on the first vehicle of the map (see the header —
## the bake writes none, because a marker gets no node).
func _vehicles_root() -> Node3D:
	var c := get_node_or_null(NodePath(VEHICLES)) as Node3D
	if c == null:
		c = Node3D.new()
		c.name = VEHICLES
		add_child(c)
	return c

## One tick of every path vehicle. Run from the level's per-tick sweep
## (ActionSystem.tick) in the place it has always held: after the spawn
## sprites, before the water. `player_pos` is ZONE-LOCAL, because the DOS
## window each vehicle tests is a MAP-GRID cell index and the markers are
## in that space too.
func path_tick(delta: float, player_pos: Vector3) -> void:
	for off in _vehicles:
		_vehicles[off].path_watch(delta, player_pos)

## The PathVehicle node of the actor marker at `id`, or null.
func vehicle_node(id: int) -> Node:
	return _vehicles.get(id)

## Every one of them, in map order.
func vehicle_nodes() -> Array:
	return _vehicles.values()

## Where each machine stands and which way it faces. The per-map overlay
## has never carried a vehicle (a map re-entered puts them back at their
## markers, as DOS does by re-reading the map); this is for the verifier,
## which checks a whole map's nodes without reloading it.
func path_snapshot() -> Dictionary:
	var out: Dictionary = {}
	for off in _vehicles:
		out[off] = _vehicles[off].snapshot()
	return out

func path_restore(snap: Dictionary) -> void:
	for off in snap:
		var n: Node = _vehicles.get(off)
		if n != null:
			n.restore(snap[off] as Array)

## Every vehicle put back at the head of its path and stopped — what the
## verifier clears between two checks of the same map. Where each machine
## STANDS is path_restore's business, not this.
func path_forget() -> void:
	for off in _vehicles:
		_vehicles[off].path_forget()

# ---------------------------------------------------------------------
# The destructibles, the demolition and the ram (step 5g)
# ---------------------------------------------------------------------
## ObjHit (v1.01 0x139019) and everything it leads to. The bits it tests
## and the pool it drains are the runtime's — this writes none of them —
## and the damage STAGES are the record's own node
## (scripts/level/destructible.gd), which is the only thing that
## remembers how far a wreck has come.

## The level loader has built the mesh of `e`: remember it, and hand it to
## the record's own node where there is one to take it. Every action
## target comes through here, movers included — a door with hit points
## can be shot to pieces like anything else, and what leaves the world
## then is this mesh.
func register_hittable(e, node: Node3D) -> void:
	_ensure_index()
	_hittable[e.file_off] = node
	var n: Node = _by_id.get(e.file_off)
	if n != null and n.has_method("adopt") and not n.has_method("mover_watch"):
		if n.has_method("break_down"):
			return                               # its stages arrive with it
		n.call("adopt", node)

## …and the damage stages the loader read out of TRANSFRM.PRS for it.
## Being registered IS being a wreck: a name with no template never
## reaches this, and the DOS handler returns at once for one of those
## (0x120833 → the lookup at 0x12078a sets carry, `jb` leaves).
func register_destructible(e, meshes: Array) -> void:
	_ensure_index()
	var n: Node = _by_id.get(e.file_off)
	if n == null or not n.has_method("break_down"):
		push_warning("[behaviour] no Destructible node for the wreck @%05x" % e.file_off)
		return
	n.call("adopt", _hittable.get(e.file_off), meshes)
	_wrecks[e.file_off] = n

## The Destructible node of `id` — one with damage stages — or null.
func wreck_node(id: int) -> Node:
	_ensure_index()
	return _wrecks.get(id)

## Every one of them, in the order the loader registered them.
func wreck_nodes() -> Array:
	_ensure_index()
	return _wrecks.values()

## Does the record at `id` take damage at all (a pool of hit points, or
## damage stages)? What the crosshair and a grenade ask before they burst.
func is_damageable(id: int) -> bool:
	_ensure_index()
	if runtime == null or runtime.spent(id):
		return false
	return runtime.has_hp(id) or _wrecks.has(id)

## Every record of the map that can be damaged — the pool of hit points
## the MAP gave out, plus the wrecks, which stage under fire whether they
## carry one or not.
func damageable_offs() -> Array:
	_ensure_index()
	if runtime == null:
		return []
	var offs: Dictionary = {}
	for off in runtime.hp_offs():
		offs[int(off)] = true
	for off in _wrecks:
		offs[int(off)] = true
	var out: Array = []
	for off in offs:
		if is_damageable(int(off)):
			out.append(int(off))
	return out

## ObjHit FUN_00139019. Returns true when the hit was consumed by an
## action, so a caller can skip its generic hit effects.
##
## State bit 1 = act on every hit, and it is tested BEFORE the pool is, so
## a wreck goes on staging after its hit points are gone; bit 2 = act on
## the hit that depletes the pool. The pool drains whatever the bits say,
## which is why a crate with state 0 still breaks and drops its ammo.
func obj_hit(id: int, damage: float) -> bool:
	_ensure_index()
	var e = record_of(id)
	if e == null or runtime == null:
		return false
	var was_spent: bool = runtime.spent(id)
	var has_hp: bool = runtime.has_hp(id) and (e.flags & 3) == 1 and not was_spent
	var depleted: bool = has_hp and runtime.hp(id) - damage <= 0.0
	var acted: bool = false
	var st: int = runtime.state(id)
	if (st & 6) != 0:
		var w: Node = _wrecks.get(id)
		if w != null:
			acted = bool(w.call("advance"))
		elif not was_spent and ((st & 2) != 0 or ((st & 4) != 0 and depleted)):
			# The chain walk and then the record's own handler, DOS order.
			# The bookkeeping of a walk is still the action system's (step
			# 5h moves it), so that is what is asked to do it.
			if action != null:
				action.trigger(id)
			else:
				runtime.flip(id)
			acted = true
	if has_hp:
		runtime.set_hp(id, runtime.hp(id) - damage)
		acted = true
		if depleted:
			runtime.set_spent(id)
			destroy(id)
	return acted

## Destructibles a CHAIN switched on (0x18/0x19). Normally these only
## break under fire, but a machine can break one for you: on MAP.248 a
## START BOX (0xEF) runs a sound node into the IBEM64 girder (a 0x73
## slide) and on into 248WALL — the ram that punches the hole you walk
## through. Nothing in the map data starts a destructible enabled, so bit
## 0 here always means "a chain just fired me".
##
## Run from the level's per-tick sweep (ActionSystem.tick) in the place it
## has always held: after the proximity triggers, whose walk is what arms
## one of these.
func destruct_tick() -> void:
	_ensure_index()
	for n in _rams:
		var id: int = id_of(n)
		if not fires(id):
			continue
		runtime.clear_enable(id)
		if _wrecks.has(id):
			n.call("break_down")

## Demolition (0x1B, v1.01 handler 0x1380bf): a chain that enables one of
## these deals it HP + 1 through ObjHit. The crate stack on MAP.213 comes
## down with the crate you shot, the desk takes the PC on it, the NODE00
## gate on MAP.280 drops the fence ring.
func demolish_tick() -> void:
	_ensure_index()
	for n in _demolishers:
		var id: int = id_of(n)
		if not fires(id):
			continue
		runtime.clear_enable(id)
		demolish(id)

## One demolition. `hp = max(hp, 1)` first, so a prop the map gave no hit
## points goes too, then ObjHit(hp + 1) — the object dies through the
## ordinary destruction path (blast, drop, sound, and the chain if its own
## state bits ask for it). A record already spent has nothing left to
## kill, and the simulation reads the same flag back (trigger_graph._edge).
func demolish(id: int) -> void:
	var e = record_of(id)
	if e == null or runtime.spent(id) or (e.flags & 3) != 1:
		return
	if not runtime.has_hp(id) or runtime.hp(id) <= 0.0:
		runtime.set_hp(id, 1.0)
	var left: float = runtime.hp(id)
	print("[action] demolish @%05x (act 0x1b, hp %.0f)" % [id, left])
	say(id, "demolish", "demolish", {"hp": left})
	obj_hit(id, left + 1.0)

## DOS FUN_00124293 — the hit points are gone. The link record's byte 0
## picks the destruction type (Skynet.exe 0x423d6): effect sprites
## scattered within `spread`, a random drop from the type's list (crates →
## ammo, lockers → medkits) and a sound (-2 = one of 33..36); type 0 is a
## plain blast (effect 358) sized by the i16 parameter, no drop. Staged
## wrecks keep their final mesh; everything else leaves the world.
##
## zone-local ↔ world: the record's own position is zone-local and the
## mesh's global transform is already world; both are carried as WORLD
## here, because the audio, the effects and the blast all live there.
func destroy(id: int) -> void:
	var e = record_of(id)
	if e == null:
		return
	var node: Node3D = _hittable.get(id)
	var origin := Vector3(float(e.x), -float(e.y), -float(e.z)) + zone_origin
	var centre: Vector3 = origin
	var radius: float = 120.0
	var alive: bool = node != null and is_instance_valid(node)
	if alive and node is MeshInstance3D:
		var aabb: AABB = (node as MeshInstance3D).get_aabb()
		centre = node.global_transform * (aabb.position + aabb.size * 0.5)
		radius = maxf(aabb.size.length() * 0.35, 120.0)
	var fx: Array = [0xB300]
	var spread: int = maxi(absi(e.destroy_param), 128)
	var drop: int = -1
	var snd: int = -2
	var t: int = e.destroy_type
	if t > 0 and t < PickupData.DESTRUCT.size():
		var d: Array = PickupData.DESTRUCT[t]
		fx = d[0]
		spread = int(d[1])
		drop = int(d[2])
		snd = int(d[3])
	if snd == -2:
		var pool: Array = PickupData.DESTRUCT_RANDOM_SOUNDS
		snd = int(pool[randi() % pool.size()])
	if snd >= 0 and not Audio.sound_name(snd).is_empty():
		Audio.play_id_3d(snd, centre, -3.0)
	else:
		Audio.play_sfx_3d("EXPLO3.RAW", centre, -3.0)
	if alive and node.is_inside_tree():
		var scene := node.get_tree().current_scene
		if scene != null:
			var k: int = 0
			for s in fx:
				var at: Vector3 = centre
				if k > 0:
					at += Vector3(randf_range(-0.5, 0.5) * spread, 0.0,
						randf_range(-0.5, 0.5) * spread)
				Explosion.spawn(scene, at, radius * 1.6, int(s) >> 7)
				k += 1
		radial_blast(node, centre, absi(e.destroy_param))
	# Gone from the world, whether or not it was in a tree to blow up in.
	if alive and not _wrecks.has(id):
		node.visible = false
		disable_collision(node)
	if drop >= 0:
		item_dropped.emit(Vector3(centre.x, origin.y, centre.z) - zone_origin, drop)

## Explosion at a wreck's centre; the final stage also throws the object's
## own blast (the i16 at its link record +1 — the cars of MAP.210 carry
## 200-300, the gas tanker 600, a crate nothing).
func blast(id: int, node: Node3D, final: bool) -> void:
	var e = record_of(id)
	var strength: int = absi(e.destroy_param) if e != null else 0
	var aabb: AABB = (node as MeshInstance3D).get_aabb() if node is MeshInstance3D else AABB()
	var centre: Vector3 = node.global_transform * (aabb.position + aabb.size * 0.5)
	var radius: float = maxf(aabb.size.length() * 0.35, 120.0)
	Audio.play_sfx_3d("EXPLO3.RAW" if final else "EXPLO1.RAW", centre, -3.0)
	if not node.is_inside_tree():
		return
	var scene := node.get_tree().current_scene
	if scene != null:
		Explosion.spawn(scene, centre, radius * (1.6 if final else 1.0))
	if final:
		radial_blast(node, centre, strength)

## A dying object's blast, the DOS radial one (FUN_00124386 through
## Projectile.dos_blast): `s` points at the centre + 40, nothing past half
## of it — on the player (from his DOS point, with line of sight), on the
## robots (ObjHit) and on the other destructibles in reach, which is how a
## row of cars goes up one after another. Until 2026-09-15 the port dealt
## a flat 450 points to the player from every wreck, crates included.
func radial_blast(source: Node3D, centre: Vector3, s: int) -> void:
	if s <= 0 or not source.is_inside_tree():
		return
	var tree: SceneTree = source.get_tree()
	Projectile.blast_player(centre, float(s), float(s), null, tree)
	for e in tree.get_nodes_in_group("enemy"):
		if e is Node3D and e.has_method("obj_hit"):
			var d: float = e.blast_distance(centre) if e.has_method("blast_distance") \
				else (e as Node3D).global_position.distance_to(centre)
			var bd: float = Projectile.dos_blast(float(s), d)
			if bd > 0.0:
				e.call("obj_hit", bd)
	for h in tree.get_nodes_in_group("hittable"):
		if h is Node3D and h != source and h.has_method("take_damage"):
			var bh: float = Projectile.dos_blast(float(s),
				(h as Node3D).global_position.distance_to(centre))
			if bh > 0.0:
				h.call_deferred("take_damage", bh)

static func disable_collision(node: Node3D) -> void:
	for c in node.get_children():
		if c is CollisionObject3D:
			for s in c.get_children():
				if s is CollisionShape3D:
					s.disabled = true

## The map overlay's share of the wrecks: how far each has come. The shape
## is unchanged (step 5h moves the save format itself), so an older save
## still reads.
func destruct_snapshot() -> Dictionary:
	_ensure_index()
	var out: Dictionary = {}
	for off in _wrecks:
		out[off] = _wrecks[off].call("snapshot")
	return out

## …and the way back: every wreck to the stage the overlay left it at, and
## the plain props the overlay says are spent out of the world again (a
## staged wreck keeps its last mesh instead, which restore() puts back).
func destruct_restore(snap: Dictionary) -> void:
	_ensure_index()
	for off in _hittable:
		if not runtime.spent(off) or _wrecks.has(off):
			continue
		var gone = _hittable[off]
		if gone != null and is_instance_valid(gone):
			(gone as Node3D).visible = false
			disable_collision(gone)
	for off in snap:
		var w: Node = _wrecks.get(int(off))
		if w != null:
			w.call("restore", snap[off] as Array)

# ---------------------------------------------------------------------
# The relays, the spawns, the water and the lights (step 5d)
# ---------------------------------------------------------------------
## The four sweeps below are run from the level's per-tick sweep
## (ActionSystem.tick) in the places they have always held, and each of
## them is one line per node — the work is the node's
## (scripts/level/raw_action.gd).

## Every map light, once. The flicker and the strobe run every tick their
## bit is up, so they share one clock rather than changing a lamp on every
## physics step.
func light_tick(delta: float) -> void:
	_ensure_index()
	if _lights.is_empty():
		return
	_light_fx_clock += delta
	var fx_tick: bool = _light_fx_clock >= LIGHT_FX_TICK
	if fx_tick:
		_light_fx_clock = 0.0
	for n in _lights:
		n.light_watch(fx_tick)

## The countdown relays. `objectives_left` is the mission counter main.gd
## keeps (DOS [0x1e6c2]) — the one thing a relay watches.
func relay_tick(objectives_left: int) -> void:
	_ensure_index()
	for n in _relays:
		n.relay_watch(objectives_left)

## The spawn sprites a chain has switched on.
func spawn_tick() -> void:
	_ensure_index()
	for off in _spawns:
		_spawns[off].spawn_watch()

## The water movers a chain has switched on.
func water_tick() -> void:
	_ensure_index()
	for n in _water:
		n.water_watch()

## An 0xF3 sprite's robot, built hidden by the level loader and handed to
## the sprite's own node. The registration IS the sweep list: a map may
## carry an 0xF3 no robot was built for (the DOS cap is 50 a map, and a
## type with no frames gets none), and such a sprite has never fired.
func register_spawn(off: int, robot: Node) -> void:
	_ensure_index()
	var n: Node = _by_id.get(off)
	if n == null or not n.has_method("spawn_reveal"):
		push_warning("[behaviour] no node for the 0xF3 spawn @%05x" % off)
		return
	n.set("enemy", robot)
	_spawns[off] = n

## file_off → the robot waiting at each registered spawn sprite.
func spawn_enemies() -> Dictionary:
	_ensure_index()
	var out: Dictionary = {}
	for off in _spawns:
		out[off] = _spawns[off].get("enemy")
	return out

## The robots a chain let out, for the map's state overlay …
func spawned_offs() -> Dictionary:
	_ensure_index()
	var out: Dictionary = {}
	for off in _spawns:
		if bool(_spawns[off].get("spawned")):
			out[off] = true
	return out

## … and the way back: one of them comes out again on a later visit.
func spawn_reveal(off: int) -> void:
	_ensure_index()
	var n: Node = _spawns.get(off)
	if n != null:
		n.spawn_reveal()

## The lamp main.gd placed for a variant-2 record, or null.
func lamp(id: int):
	return map_lights.get(id)

## A water mover asks for a new surface height. `absolute` = go to this Y
## (a world one), otherwise add it to the target. main.gd glides the
## surface there and everything that reads the level follows on the way.
func water_to(value: float, absolute: bool) -> void:
	water_level.emit(value, absolute)

## Say what a node just did and what it came to, on the level's event bus
## (M3 step 3). `kind` as scripts/triggers/rules_skynet.gd names it and
## `effect_kind` as scripts/triggers/trigger_bus.gd lists it; both are
## data, and nothing here is told to anyone in particular — the bus is an
## observer and null is an ordinary state.
func say(id: int, kind: String, effect_kind: String, payload: Dictionary) -> void:
	if bus == null:
		return
	bus.announce_fire(id, kind)
	if not effect_kind.is_empty():
		bus.announce_effect(id, effect_kind, payload)

## Enabled now, or enabled at any point earlier in this tick — the test
## the one-shot sweeps make. A chain walked earlier in the same tick may
## already have switched the entity off again (several triggers can share
## one chain), and DOS runs each object's handler AS the chain is flipped,
## so the arming is what counts. The bookkeeping is still the action
## system's (step 5h moves it); without one, the live bit is all there is.
func fires(id: int) -> bool:
	if action != null:
		return bool(action.fires(id))
	return runtime != null and runtime.enabled(id)

## Everything the step-5d nodes remember about the level's own doing,
## forgotten — what the verifier clears between two checks of the same
## map. A robot an 0xF3 chain let out stays out (putting it back is the
## level loader's work, not a snapshot's), but the sprite is armed again,
## so the next check of it announces as it did the first time.
func raw_forget() -> void:
	_ensure_index()
	for n in _lights:
		n.raw_forget()
	for off in _spawns:
		_spawns[off].raw_forget()

## Say what just fired, in the rules module's own vocabulary (M3 step 3).
## Nothing here changes what the cue did — it has already done it.
func _announce_fire(n: Node) -> void:
	if bus == null:
		return
	var id: int = id_of(n)
	var kind: String = Rules.kind_of(act_of(n))
	bus.announce_fire(id, kind)
	match kind:
		"sound_cue":
			bus.announce_effect(id, "sound", {"sound": int(n.get("sound_id"))})
		"sound_loop":
			# The scriptless-era node keeps its data in metadata (the bake
			# writes it there), so the id comes off the meta.
			bus.announce_effect(id, "loop", {"loop": int(n.get_meta("sound_id", -1))})
		"voice":
			bus.announce_effect(id, "voice", {"voice": int(n.get("voice_id"))})
		"hint":
			bus.announce_effect(id, "hint", {"index": int(n.get("index"))})
		"objective":
			# One node class carries both [M1].. and the 0x2B fail act.
			if "fails_mission" in n and bool(n.get("fails_mission")):
				bus.announce_effect(id, "fail", {})
			else:
				bus.announce_effect(id, "objective", {"index": int(n.get("index"))})
		"fail":
			bus.announce_effect(id, "fail", {})

func _on_cue_fired(index: int, n: Node) -> void:
	if "fails_mission" in n:
		if bool(n.get("fails_mission")):
			mission_failed.emit()
		else:
			Audio.play_id(0x51, -4.0)                # FUN_0012f53d confirms
			objective_complete.emit(index)
	else:
		hint_message.emit(index)

## After the runtime took a state overlay: a cue whose act byte came back
## as 0xFF fired before this visit and must not count again, so its
## node's own guard goes back up with it (an objective whose `spent` came
## back false counted a second time on the next chain flip).
func sync_from_runtime() -> void:
	if runtime == null:
		return
	_ensure_index()
	for id in _by_id:
		var n: Node = _by_id[id]
		if "spent" in n:
			n.set("spent", runtime.act(int(id)) == 0xFF)
