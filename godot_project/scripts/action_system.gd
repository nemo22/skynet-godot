## Entity action / link system — port of the DOS object-action layer:
##
##   ObjDoAction  FUN_00139698 (skynet_gh.c:39876) — dispatches an
##                entity's type/handler id through the table at
##                Skynet.exe VA 0x59b00 when its enable bit is set.
##   ObjFlipLink  FUN_001394aa (skynet_gh.c:39791) — walks the entity
##                link chain toggling the per-entity trigger bit; an
##                0xEF node force-re-enables itself (line 39837).
##   ObjHit       FUN_00139019 (skynet_gh.c:39475) — state-byte bit1 =
##                fire the action on every hit, bit2 = fire it on the
##                hit that depletes the entity's HP.
##
## The 0x59b00 handler table was dumped from Skynet.exe (raw dword at
## file offset VA+0x538A4, +0x30000 pointer correction). Families
## driven here:
##   slide / swing / rot  — doors, gates, lifts, radar dishes: the DOS
##                          handlers mutate the entity's position (0x5f,
##                          handler 0x137d41) or an 11-bit angle
##                          accumulator (0x137a28 family), committing
##                          via ObjSetPos. Not mesh-frame animation.
##   0xF0                 — interior teleport (0x137881): target map at
##                          sub+2, spawn-marker set at sub+4; one-shot.
##
## (0xEF, 0xF1 and 0xF2 — the use-key gates, the chain triggers and the
## wall buttons — left in step 5c: they watch the player from their own
## nodes now, scripts/level/trigger.gd. The countdown relay 0x2C, the
## spawn sprites 0xF3, the water movers 0xd6-0xda and the map lights
## 0x01-0x12 left in step 5d, onto scripts/level/raw_action.gd. The
## MOVERS — every slide, swing, jump and rotator of the table above —
## left in step 5e, onto scripts/level/mover.gd: each one steps its own
## travel and moves the mesh this class registered for it. The PATH
## VEHICLES left in step 5f, onto scripts/level/path_vehicle.gd. The
## DESTRUCTIBLES, the demolition and the ram — ObjHit itself, the
## TRANSFRM.PRS damage stages of 0x18/0x19 and the 0x1B killing blow —
## left in step 5g, onto scripts/level/behaviour.gd and the records' own
## scripts/level/destructible.gd.)
##
## Where the state lives: NOT here, and not in the parsed MapFile
## either. Since step 5a of docs/trigger_graph_plan.md every state byte,
## act byte and link belongs to the level's trigger runtime
## (scripts/triggers/trigger_runtime.gd, `triggers` below), which is the
## only thing that writes one; the records this sweeps are the DATA the
## map was authored with — position, radius, flags, hit points, the
## destruction table — and are read-only. What is still kept here is the
## machinery of the classes that have not moved yet: the exits and the
## latches of the sweeps.
##
## Reloading a map re-parses it and the runtime starts from the records
## again, which matches DOS (maps are always reloaded from disk; the Mst
## state overlay arrives with map transitions in phase 2).
##
## Every handler run below also ANNOUNCES itself on the level's trigger
## event bus (`bus`, scripts/triggers/trigger_bus.gd — M3 step 3): what
## fired and what it came to, as data. It is an observer — the sweeps
## never ask who is listening, nothing in the game subscribes, and with
## no bus at all the code takes the same path. What it buys is that the
## generated graph's prediction for a node and what the running game
## actually does can be laid side by side (scripts/triggers/
## trigger_equiv.gd).
##
## Phase F2 of docs/map_format_plan.md moves this, class by class, onto
## the level's Behaviour branch (scripts/level/behaviour.gd). Done so
## far: the chain walk itself (ObjFlipLink, now the trigger runtime's),
## the one-shot cues — sounds, voice lines, hints, objectives fire from
## their nodes — the PROXIMITY class, which watches the player and
## answers the use key from its own nodes since step 5c, the four
## classes that watch no player at all since step 5d (the relays, the
## spawn sprites, the water and the lights), the MOVERS since step 5e, the
## PATH VEHICLES since step 5f and the DESTRUCTIBLES, the demolition and
## the ram since step 5g. Still here: the exits.

extends RefCounted

signal teleport_requested(target_map: int, marker_set: int)
## (The water level and a destroyed object's drop are asked for on the
## Behaviour branch's own signals — the movers that move the water are its
## nodes since step 5d, and ObjHit is its work since step 5g.)

const MapFile := preload("res://scripts/loaders/map_file.gd")
## What each action id MEANS now lives on its own, next to the generated
## trigger graph that reads the same rows (scripts/triggers/rules_skynet.gd,
## M3 step 1). The tables below are those rows by reference, so every
## caller of ActionSystem.MOVER_TABLE / SOUND_ONESHOT / the ACT_* bands
## still finds them here and nothing about play changes. (The water table
## went with the water in step 5d: the nodes that run it read it straight
## off the rules module.)
## Future Shock runs SkyNET's table at run time as it always has (its own
## rules_shock.gd is used by the graph alone, and is informational).
const Rules := preload("res://scripts/triggers/rules_skynet.gd")

## Every table and band below is scripts/triggers/rules_skynet.gd's row
## set, by reference: the tables moved there with their notes (M3 step 1)
## and nothing about play changed. Bodies of the handlers, the mover
## families and the provenance of each id are documented there.
const MOVER_TABLE: Dictionary = Rules.MOVER_TABLE
const SOUND_ONESHOT: Dictionary = Rules.SOUND_ONESHOT

const ACT_DESTRUCT_A: int = Rules.ACT_DESTRUCT_A
const ACT_DESTRUCT_B: int = Rules.ACT_DESTRUCT_B
const ACT_DEMOLISH: int = Rules.ACT_DEMOLISH
const ACT_LIGHT_TOGGLE: int = Rules.ACT_LIGHT_TOGGLE
const ACT_LIGHT_FLICKER: int = Rules.ACT_LIGHT_FLICKER
const ACT_LIGHT_STROBE: int = Rules.ACT_LIGHT_STROBE
const ACT_LIGHT_FADE_UP_FIRST: int = Rules.ACT_LIGHT_FADE_UP_FIRST
const ACT_LIGHT_FADE_DOWN_LAST: int = Rules.ACT_LIGHT_FADE_DOWN_LAST
const ACT_PROX_GATE: int = Rules.ACT_PROX_GATE      # 60-unit player-proximity gate
const ACT_PROX_CHAIN_A: int = Rules.ACT_PROX_CHAIN_A  # radius 256 (table +4)
const ACT_PROX_CHAIN_B: int = Rules.ACT_PROX_CHAIN_B  # radius 1024 (table +4)
const ACT_TELEPORT: int = Rules.ACT_TELEPORT
const ACT_VOICE: int = Rules.ACT_VOICE
const ACT_HINT_FIRST: int = Rules.ACT_HINT_FIRST
const ACT_HINT_LAST: int = Rules.ACT_HINT_LAST
const ACT_OBJECTIVE_FIRST: int = Rules.ACT_OBJECTIVE_FIRST
const ACT_FAIL: int = Rules.ACT_FAIL
const ACT_RELAY: int = Rules.ACT_RELAY
const ACT_SPAWN: int = Rules.ACT_SPAWN

const SWING_SPEED: float = Rules.SWING_SPEED
const SLIDE_SPEED_SLOW: float = Rules.SLIDE_SPEED_SLOW
const SLIDE_SPEED_FAST: float = Rules.SLIDE_SPEED_FAST
const ROT_SPEED: float = Rules.ROT_SPEED
const SLIDE_SPEED_SCALE: float = Rules.SLIDE_SPEED_SCALE
const PROX_GATE_RADIUS: float = Rules.PROX_GATE_RADIUS
const USE_REACH: float = Rules.USE_REACH
const PLAYER_RADIUS: float = Rules.PLAYER_RADIUS
const TELEPORT_TOUCH_RADIUS: float = Rules.TELEPORT_TOUCH_RADIUS
const PROX_VERTICAL_WINDOW: float = Rules.PROX_VERTICAL_WINDOW
const DESTRUCT_DAMAGE_PER_STAGE: float = Rules.DESTRUCT_DAMAGE_PER_STAGE

## Where this level's zone stands in the world (LevelLoader.Level.origin).
## Every record here holds DOS coordinates, i.e. ZONE-LOCAL Godot ones —
## so a world position coming in (the player, the camera) has this taken
## off it, and a position handed out to the physics world, the audio or
## the effects has it added. Zero for a lone map, where the two spaces
## are the same thing and nothing below changes.
var zone_origin: Vector3 = Vector3.ZERO
var _map: MapFile.MapFile = null
var _nodes: Dictionary = {}       # file_off → Node3D (visual, optional)
var _teleports: Array = []        # entities with act 0xF0
## Their world positions, index for index — tick() tests them every
## physics step, and the records never move.
var _teleport_pos: PackedVector3Array = PackedVector3Array()
## The level's trigger state (scripts/triggers/trigger_runtime.gd, step
## 5a): the chain walk, the cues, and every state byte, act byte and link
## the sweeps below read. Set by the level loader.
var triggers: RefCounted = null
## The level's Behaviour branch (scripts/level/behaviour.gd). The cues
## fire from it (F2), the proximity class has run on it since step 5c —
## the key, the sweep and the wall buttons are all its nodes' work — and
## since step 5d so do the relays, the spawn sprites, the water and the
## lights, since step 5e the movers and since step 5f the path vehicles.
## This is how all of them are reached.
## Null is an ordinary state — an ActionSystem built by hand has no
## branch and none of those, and since step 5g nothing that takes damage
## either.
var behaviour: Node = null
## The level's trigger event bus (scripts/triggers/trigger_bus.gd, M3
## step 3): every handler run below announces itself on it. An OBSERVER
## — the sweeps do not know whether anything listens, `null` is an
## ordinary state (a test building an ActionSystem by hand), and play is
## the same either way. See _say.
var bus: RefCounted = null
## Physics access for reachability tests (set by the level controller).
var space: PhysicsDirectSpaceState3D = null
var player_body: CollisionObject3D = null
## One-shot nodes (message, sound, voice) whose bit 0 went UP during this
## tick, even if a later flip in the same tick took it back down.
##
## ObjFlipLink TOGGLES bit 0, and a map may point several triggers at one
## chain: eight 0xEF gates ring the jeep in MAP.217, all linked to the
## HUMMERTK that carries act 0x28 — mission 1's last objective. Walking
## up to it trips two or four of them in the SAME frame, so the toggles
## cancelled out and the objective never fired: mission 1 could not be
## finished. The DOS engine runs each object's handler as the chain is
## flipped, so an even number of flips still fires it once; the port
## sweeps by phase, so it remembers the arming instead.
var _armed: Dictionary = {}       # file_off → armed earlier this tick
var _touch_latched: Dictionary = {} # teleport file_off → player touching
var _teleport_fired: bool = false   # one map change per level instance
## Objectives still to go — main.gd keeps the count (DOS [0x1e6c2]); the
## 0x2C relays watch it from their own nodes and are handed it per tick.
var objectives_left: int = 0
## (The path-following vehicles — the cargo truck into MAP.210's base,
## MAP.260's convoy, MAP.280's boss chase and the HK that lifts the player
## off MAP.234's roof — left in step 5f, onto scripts/level/path_vehicle.gd:
## each actor marker drives its own path from its own node, and the
## parameters of the drive are the rules module's, Rules.PATH_*.)

## Every press of the use key, whatever the crosshair was on: the gates
## in reach answer it on the next sweep (behaviour.press_use).
func press_use() -> void:
	if behaviour != null:
		behaviour.press_use()
var _unhandled_logged: Dictionary = {}

## Announce one handler run and what it came to (M3 step 3). One call
## site per handler, `kind` as scripts/triggers/rules_skynet.gd names it
## and `effect_kind` as scripts/triggers/trigger_bus.gd lists it; both
## are data, and nothing here is told to anyone in particular.
func _say(off: int, kind: String, effect_kind: String, payload: Dictionary) -> void:
	if bus == null:
		return
	bus.announce_fire(off, kind)
	if not effect_kind.is_empty():
		bus.announce_effect(off, effect_kind, payload)

## --- the live bytes --------------------------------------------------
## Everything below reads an entity's state byte, act byte and link
## through these three, never off the record: the record is what the MAP
## file said, the runtime is what play has made of it (step 5a).
func state_of(off: int) -> int:
	return triggers.state(off) if triggers != null else 0

func act_of(off: int) -> int:
	return triggers.act(off) if triggers != null else 0

func link_of(off: int) -> int:
	return triggers.link(off) if triggers != null else 0

func enabled(off: int) -> bool:
	return triggers != null and triggers.enabled(off)

func setup(map: MapFile.MapFile) -> void:
	_map = map
	for e in map.entities:
		# Placement MARKERS (enemy starts, radiation sources …) keep
		# other data where a sprite keeps its act byte — an enemy
		# marker's "act" is its enemy type.
		if e.marker_type >= 0:
			continue
		var act: int = e.link_act_type
		# (The proximity types — 0xEF, 0xF1, 0xF2 — are not listed here any
		# more: since step 5c each of them watches the player from its own
		# node on the Behaviour branch, scripts/level/trigger.gd. Nor are
		# the lights, the relays and the water movers: since step 5d each of
		# them runs from its own node too, scripts/level/raw_action.gd,
		# which reads the same act byte and variant off the bake. Nor the
		# destructibles and the demolition targets: since step 5g the branch
		# sweeps those by the act byte the bake wrote on their nodes, and
		# the pool of hit points every record may carry is seeded straight
		# off the records by the trigger runtime.)
		if act == ACT_TELEPORT:
			_teleports.append(e)
			_teleport_pos.append(_dos_pos(e))

## (The DOS geometry of a mover — the 11-bit Euler basis, the swing that
## advances one of its three components, the world direction of a DOS axis
## — went with the movers in step 5e: Mover.euler_basis, swing_basis,
## dos_axis. The bake reads them from there.)

## (The wall-button rule — a NAMED variant-1 mesh with state bit 3
## answers the use key instead of the player walking past it — is the
## proximity class's own since step 5c: Trigger.is_wall_button.)

## Is this act id one of the light handlers (0x137700..)? The record has
## to be a variant-2 light as well for it to mean anything — those
## handlers write the intensity and enable words a variant-2 record keeps
## at sub+0 and sub+8, and the other variants keep other data there. The
## lights themselves run on their own nodes since step 5d
## (scripts/level/raw_action.gd); this is left for _do_action, which has
## to know that such an entity's handler is somebody else's business.
static func is_light_act(act: int) -> bool:
	return act == ACT_LIGHT_TOGGLE or act == ACT_LIGHT_FLICKER or act == ACT_LIGHT_STROBE \
		or (act >= ACT_LIGHT_FADE_UP_FIRST and act <= ACT_LIGHT_FADE_DOWN_LAST)

## Can `e` flip the chain it links to by itself — a proximity or use-key
## trigger, a countdown relay, a prop whose hit or death fires its link
## (state bits 1-2), a marker path whose end fires what it points at?
## main.gd's variant import carries such an entity's state only when
## everything down its chain is the same on both maps.
static func starts_chain(e: MapFile.Entity) -> bool:
	var act: int = e.link_act_type
	if e.marker_type >= 0:
		return e.link_next > 0
	return act == ACT_PROX_GATE or act == ACT_PROX_CHAIN_A or act == ACT_PROX_CHAIN_B \
		or act == ACT_RELAY or (e.state_byte & 6) != 0

## The MAP record of `off` — the read-only data the map was authored
## with. The proximity nodes read the static half of their rules off it
## (Trigger.is_wall_button) and it is still kept here.
func record(off: int) -> MapFile.Entity:
	return _map.entities_by_off.get(off) if _map != null else null

## Has this entity been shot to pieces? The pool and the flag are the one
## writer's since step 5g, and a spent wreck answers nothing — not the
## key, not the player walking into it.
func is_spent(off: int) -> bool:
	return triggers != null and triggers.spent(off)

## Does this act type get a visual/interactive node treatment?
static func is_mover(act: int) -> bool:
	return MOVER_TABLE.has(act)

static func is_destructible(act: int) -> bool:
	return act == ACT_DESTRUCT_A or act == ACT_DESTRUCT_B

## Attach the visual node for an entity (movers, destructibles,
## damageable meshes). A MOVER's node is handed straight on to the
## record's own Mover (step 5e, scripts/level/mover.gd): that node moves
## it from here on, and takes the transform it was placed at as the rest
## pose — so this is called with the transform already final. Every one of
## them is also the branch's HITTABLE since step 5g: what a blast goes off
## at, and what leaves the world when a pool of hit points runs out.
func register_node(e: MapFile.Entity, node: Node3D) -> void:
	_nodes[e.file_off] = node
	if behaviour == null:
		return
	if is_mover(e.link_act_type):
		behaviour.register_mover(e, node)
	behaviour.register_hittable(e, node)

## Does the entity at `off` take damage (a pool of hit points, or
## destruction stages)? The branch's since step 5g.
func is_damageable_off(off: int) -> bool:
	return behaviour != null and bool(behaviour.is_damageable(off))

## …and every one of them in the map, which is what the solver looks
## through for something to shoot.
func damageable_offs() -> Array:
	return behaviour.damageable_offs() if behaviour != null else []

## One line per mover: what it is, how far it has moved and which way —
## the console's `movers`. The movers are Behaviour nodes since step 5e
## and each writes its own line; the three below are the way the rest of
## the game still asks about one, and go straight through.
func mover_report() -> String:
	return String(behaviour.mover_report()) if behaviour != null else "no movers"

## True when the entity at `off` is a mover (door/gate/lift/rotator).
func is_mover_off(off: int) -> bool:
	return behaviour != null and bool(behaviour.has_mover(off))

## Movers that translate/swing as a solid piece (doors, gates, lifts) —
## they get a box collider; continuous rotators keep their trimesh.
func is_solid_mover(off: int) -> bool:
	return behaviour != null and bool(behaviour.is_solid_mover(off))

## The damage-stage meshes of a destructible entity, built by the level
## loader from TRANSFRM.PRS — handed to the record's own Destructible node
## (step 5g, scripts/level/destructible.gd), which stages it from here on.
func register_destructible(e: MapFile.Entity, stage_meshes: Array) -> void:
	if behaviour != null:
		behaviour.register_destructible(e, stage_meshes)

## ObjHit port — the branch's since step 5g. Returns true when the hit was
## consumed by an action (so callers can skip generic hit effects).
func on_player_hit(file_off: int, damage: float) -> bool:
	return behaviour != null and bool(behaviour.obj_hit(file_off, damage))

## Activate-key port. The DOS use-key path is untraced; we honour the
## same bit1 ("act on hit") gate without applying damage, which covers
## shoot-or-use switches while leaving HP-gated objects (generators,
## bit2) to real damage.
##
## zone-local ↔ world: `player_pos` (the feet) and `eye` are WORLD
## positions and are taken into the records' zone-local space for the
## proximity measure, which is the node's. Vector3.INF for `player_pos`
## means "no measure" — the caller has picked both the entity and the
## place, and says so (TriggerEquiv.activate, the solver).
func on_player_activate(file_off: int, player_pos: Vector3 = Vector3.INF,
		eye: Vector3 = Vector3.INF) -> bool:
	var e: MapFile.Entity = _map.entities_by_off.get(file_off) \
		if _map != null else null
	if e == null or is_spent(file_off):
		return false
	# A PROXIMITY record answers on its own node (step 5c,
	# scripts/level/trigger.gd): its DOS handler runs for a player inside
	# the radius the slot carries and for no one else (0x1386a0 for the
	# 0xEF, 0x138223 for the 0xF1/0xF2), and that holds whichever way the
	# port's key arrived — the sweep, use_nearby, or the crosshair ray that
	# got here. The node is where that measure and the one-shot rules live;
	# what is passed to it is the point they measure FROM, or Vector3.INF
	# for a caller that says it has picked the place itself.
	if behaviour != null and behaviour.prox_node(file_off) != null:
		var from: Vector3 = Vector3.INF
		if player_pos.is_finite():
			from = (eye if eye.is_finite() else player_pos) - zone_origin
		return behaviour.prox_use(file_off, from)
	# Everything else keeps the port's aim-and-press rule as it was: the
	# crosshair ray is all these have ever had, and the bit1 gate above is
	# the whole of what qualifies them.
	if (state_of(file_off) & 2) == 0:
		return false
	_trigger(e)
	return true

## Use-key on a gate whose chain ends in a doorway. The gate itself is a
## Behaviour node now (step 5c) and the walk of its chain is the node's;
## the doorway is still here, so it is asked to take it.
func use_exit_through(gate: Node) -> bool:
	if behaviour == null or _map == null:
		return false
	var t: MapFile.Entity = _map.entities_by_off.get(
		behaviour.chain_exit(int(gate.id)))
	return _use_exit(gate, t) if t != null else false

## The doorway `gate`'s chain ends in, taken.
##
## DOS has one path here and it is the ordinary one. The 0xEF handler
## calls ObjFlipLink (v1.01 0x139caa); the walk toggles bit 0 of every
## node on the way — the door sound, the leaves, the doorway itself — and
## the 0xF0 handler (v1.01 0x138081) runs on the next dispatch, writes the
## target map and marker set, asks for the map change (`or [0x30a50],
## 0x20`) and clears its OWN bit 0 inline (`and byte [esi+edi+5], 0xfe`).
## It never retires its act and holds no latch of its own; what makes it
## once per level is the frame loop, which tests that request before the
## next entity sweep and tears the level down.
##
## Two things the port has and DOS has not meet here. TOUCHING a doorway
## arms it (see tick), so the exit's bit can be up before the key is
## pressed and the walk would take it back DOWN — the exit would never
## fire. And the port's map change is a fade, so the level lives on with
## the player still standing in the gate. So: walk the chain ONCE per
## level instance, which is DOS's single walk and everything on it (the
## door sound above all), then leave the exit enabled as that walk leaves
## it and take it.
##
## Guarding the walk on the EXIT's own bit was what lost the chain:
## standing in the doorway had already armed it, so the key went straight
## through in silence (M3 step 4 read that as exit_chain_skipped, 148 of
## its failures). The guard is this gate's own (Trigger.walk_once) — not
## its proximity latch, which a spawn inside the gate pre-sets
## (arm_proximity) and which would then swallow the very first walk in the
## truck interiors.
func _use_exit(gate: Node, t: MapFile.Entity) -> bool:
	if _teleport_fired:
		return false
	gate.walk_once()
	triggers.arm(t.file_off)
	return _fire_teleport(t)

func _fire_teleport(t: MapFile.Entity) -> bool:
	if _teleport_fired or not enabled(t.file_off):
		return false
	_clear_enable(t)                         # one-shot (0x137881)
	# DOS holds no latch in the handler — it clears its own bit 0 and would
	# fire again on the next rise — but the map change it asks for
	# (`or [0x30a50], 0x20`, v1.01 0x1380b2) is tested at the top of the
	# next frame, before the entity sweep, and the level is torn down:
	# one map change per level instance, always. The port's transition is
	# asynchronous (a fade), and a player standing in a gate re-toggles
	# the exit's bit every frame, so the outcome needs saying out loud.
	_teleport_fired = true
	print("[action] teleport → map %d, marker set %d" % [t.exit_map, t.exit_marker_id])
	_say(t.file_off, "exit", "exit", {"map": t.exit_map, "set": t.exit_marker_id,
		"back": t.exit_map == 0})
	teleport_requested.emit(t.exit_map, t.exit_marker_id)
	return true

## The level controller could not take the exit (no previous map, a
## target missing from the archive): this level stays, so its other exits
## must still work — the one-map-change latch is let go again.
func teleport_refused() -> void:
	_teleport_fired = false

## ObjFlipLink + immediate ObjDoAction, DOS order: flip the chain from
## the entity, then run the entity's own action.
func _trigger(e: MapFile.Entity) -> void:
	_flip_link(e)
	_do_action(e)

## The same, from a file offset — what ObjHit calls for a record whose
## state bits say a hit runs it (the branch's since step 5g; the
## bookkeeping of a walk is still this class's, so it is asked to do it).
func trigger(off: int) -> void:
	var e: MapFile.Entity = _map.entities_by_off.get(off) if _map != null else null
	if e != null:
		_trigger(e)

## The same walk, from a file offset — what the proximity nodes call when
## they flip their own chain (step 5c, through behaviour.flip_chain).
## PUBLIC because the sweeps still here are what needs the bookkeeping
## below; when the last of them moves (step 5h) the nodes can walk
## straight on the runtime.
func flip_chain(off: int) -> void:
	var e: MapFile.Entity = _map.entities_by_off.get(off) if _map != null else null
	if e != null:
		_flip_link(e)

## ObjFlipLink FUN_001394aa — the trigger runtime's since step 5a
## (scripts/triggers/trigger_runtime.gd flip): toggle bit 0 down the
## chain, an 0xEF node forces its bit back on, the walk stops at an
## actor, and a one-shot cue whose bit goes up fires there and then. What
## comes back is the walk order and the new bytes, which is what the
## per-tick sweeps below need to know was armed.
func _flip_link(start: MapFile.Entity) -> void:
	if triggers == null:
		push_warning("[action] no trigger runtime — chain from @%05x dropped" % start.file_off)
		return
	for item in triggers.flip(start.file_off):
		var e: MapFile.Entity = _map.entities_by_off.get(int(item[0]))
		if e == null:
			continue
		if (int(item[1]) & 1) != 0:
			_armed[e.file_off] = true
		_refresh_switch_visual(e)

## BUTTON01/02 are a single quad with the OFF texture (222/0, 222/2) on
## the front face and the lit ON texture (222/1, 222/3) on the back. DOS
## shows the pressed state by the texture alone — the panel does not
## turn ("obrazovky po kliknutí sa neotáčajú, len sa flipne textúra",
## playtest, 2026-09-11); the port turned it 180°, which swung a panel whose
## origin is off its face round to the far side. The two faces swap
## materials instead, so the front shows the lit art where it stands.
## Every button a chain has flipped, drawn again from its record — after
## main.gd re-lit the level (DYNAMIC LIGHTS changed), which replaces the
## surface materials the lit face was shown with.
func refresh_switch_visuals() -> void:
	for off in _nodes:
		var n = _nodes[off]
		if n != null and is_instance_valid(n) and (n as Node).has_meta("switch_lit"):
			var e: MapFile.Entity = _map.entities_by_off.get(off) if _map != null else null
			if e != null:
				_refresh_switch_visual(e)

func _refresh_switch_visual(e: MapFile.Entity) -> void:
	var node: Node3D = _nodes.get(e.file_off)
	if node == null or not is_instance_valid(node):
		return
	if not String(node.get_meta("mesh_name", node.name)).begins_with("BUTTON"):
		return
	var mi: MeshInstance3D = node as MeshInstance3D
	if mi == null:
		var found: Array = node.find_children("*", "MeshInstance3D", true, false)
		if not found.is_empty():
			mi = found[0]
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() != 2:
		return
	var lit: bool = enabled(e.file_off)
	node.set_meta("switch_lit", lit)
	mi.set_surface_override_material(0, mi.mesh.surface_get_material(1) if lit else null)
	mi.set_surface_override_material(1, mi.mesh.surface_get_material(0) if lit else null)

## ObjDoAction: dispatch when enabled. Movers/proximity/teleports are
## per-tick handlers driven from tick(); the one-shot families run here.
func _do_action(e: MapFile.Entity) -> void:
	var act: int = act_of(e.file_off)
	if act <= 0 or act >= 0xFE:
		return
	if is_mover(act) or act == ACT_PROX_GATE \
			or act == ACT_PROX_CHAIN_A or act == ACT_PROX_CHAIN_B \
			or act == ACT_TELEPORT or is_destructible(act) or act == ACT_DEMOLISH \
			or (act >= ACT_HINT_FIRST and act <= ACT_FAIL) or act == ACT_VOICE \
			or act == ACT_RELAY or act == ACT_SPAWN \
			or SOUND_ONESHOT.has(act) or ((e.flags & 3) == 2 and is_light_act(act)):
		return                                  # tick() / the hit path / the cue nodes
	if not _unhandled_logged.has(act):
		_unhandled_logged[act] = true
		print("[action] unhandled act 0x%02x (entity @%d)" % [act, e.file_off])

## Per-tick sweep — the DOS engine re-runs enabled entities' handlers
## every tick; movers advance while enabled, proximity types watch the
## player, teleports fire once when enabled. main.gd runs it on the
## physics step: DOS ticked at a fixed rate, and the movers carry the
## collision bodies the player stands on. Motion scales by `delta`, and
## the triggers only need to see the player once a step.
##
## `player_pos` is the body (feet): doorways and the path vehicles' grid
## window go by it. `eye_pos` is where the DOS proximity handlers measure
## from — 0x1379c4 (0xF1/0xF2) and 0x137e2e (0xEF) both subtract the
## camera position [0xd47b4] from the entity and take the 3D length
## (v1.00 disassembly, 2026-09-15). The port measured from the feet, 75 u
## lower, so MAP.260's mission-end BUTTONX (0xF2, radius 1024) could be
## driven past (playtest 2026-09-15). Callers that put a test point
## right at a trigger may leave it out: it defaults to `player_pos`.
##
## zone-local ↔ world: both come in as WORLD positions and are taken into
## the records' zone-local space here, once, for the whole sweep.
func tick(delta: float, player_pos: Vector3, eye_pos: Vector3 = Vector3.INF) -> void:
	if _map == null:
		return
	var here: Vector3 = player_pos - zone_origin
	var eye: Vector3 = here if eye_pos == Vector3.INF else eye_pos - zone_origin
	# Lights ------------------------------------------------------
	# The variant-2 map lights a chain switches, flickers, strobes or fades
	# run from their own nodes since step 5d (scripts/level/raw_action.gd,
	# swept by scripts/level/behaviour.gd) — here, at the head of the tick,
	# where they have always run.
	if behaviour != null:
		behaviour.light_tick(delta)
	# Movers ------------------------------------------------------
	# The doors, the gates, the lifts and the rotators step their own
	# travel from their own nodes since step 5e (scripts/level/mover.gd) —
	# here, where they have always run: before the proximity sweep, whose
	# triggers must see the bodies where this tick left them.
	if behaviour != null:
		behaviour.mover_tick(delta)
	# Proximity triggers ------------------------------------------
	# The 0xEF gates, the 0xF1/0xF2 chain triggers and the wall buttons
	# watch the player from their own nodes since step 5c
	# (scripts/level/trigger.gd, swept by scripts/level/behaviour.gd) —
	# here, where they have always run: after the movers and before the
	# one-shot classes below, which read what a chain armed this tick.
	if behaviour != null:
		behaviour.prox_tick(eye)
	# (Sound one-shots, voice lines, hints and objectives fire from their
	# Behaviour nodes as the chain is flipped — F2.)
	# The destructibles a chain breaks (0x18/0x19 — MAP.248's girder ram)
	# and the props a chain kills outright (0x1B), both on their own nodes
	# since step 5g (scripts/level/destructible.gd,
	# scripts/level/damageable.gd) — here, where they have always run:
	# after the proximity sweep, whose walk is what arms one of them.
	if behaviour != null:
		behaviour.destruct_tick()
		behaviour.demolish_tick()
	# The countdown relays (0x2C) and the spawn sprites (0xF3), both on
	# their own nodes since step 5d. The counter a relay watches is main's
	# and is handed over as it stands this tick.
	if behaviour != null:
		behaviour.relay_tick(objectives_left)
		behaviour.spawn_tick()
	# Vehicles on a marker path (AI state 11) ----------------------
	# The truck, the convoy, the boss chase and the pick-up HK drive their
	# own markers from their own nodes since step 5f
	# (scripts/level/path_vehicle.gd) — here, where they have always run.
	# What the DOS grid window is measured against is the player's own
	# position, so it goes over with the tick.
	if behaviour != null:
		behaviour.path_tick(delta, here)
	# Water level (0xd6-0xda) -------------------------------------
	# The movers that move it are Behaviour nodes since step 5d, and they
	# ask for the new height on the branch's own signal.
	if behaviour != null:
		behaviour.water_tick()
	# Teleports ---------------------------------------------------
	# A chain (0xEF gate → sound node → 0xF0) or touching the doorway
	# sprite ARMS the exit (state bit 0); the map change itself needs
	# the use key — in DOS you walk into the truck and press use at its
	# rear doors, nothing happens just by standing there.
	for ti in _teleports.size():
		var e: MapFile.Entity = _teleports[ti]
		var epos: Vector3 = _teleport_pos[ti]
		var touching: bool = _within_touch(epos, here, TELEPORT_TOUCH_RADIUS)
		if touching and not _touch_latched.get(e.file_off, false):
			triggers.arm(e.file_off)
		if _armed.has(e.file_off):
			triggers.arm(e.file_off)
		_touch_latched[e.file_off] = touching
		# An exit a CHAIN switched on fires the moment it is enabled (DOS
		# 0x138081), on foot as well as in a vehicle: MAP.270's tunnel
		# mouth (0xF1 button → 0xF0) and mission 5's TORPEDO TUBE, where
		# the hatch's own chain shoots the player out into the harbour
		# without another key press. TOUCHING a doorway is different — it
		# only arms the exit, and the use key takes it (the truck doors).
		if _armed.has(e.file_off):
			_fire_teleport(e)
	if not _armed.is_empty():
		_armed.clear()

## Use key: take the doorway the player is standing at. Returns true when
## a map change was requested (one per level instance). `eye`: where the
## 0xEF gate below measures from — the camera, as DOS 0x1386a0 does; the
## feet when not given (tests). MAP.210's cargo box is sealed and boarded
## with the key at its rear wall: the gate inside is 91-97 u from the feet
## there, over the 86 u reach, but 23-42 u from the eye (playtest
## 2026-09-15: "the cargo truck cannot be entered").
##
## THE GATE FIRST. DOS knows one way through a door — an 0xEF gate whose
## chain ends in the 0xF0 — and it plays that chain on the way. A doorway
## the player merely TOUCHED is the port's own fallback (see tick), and
## taking it first is what silenced the gates: the exit was already armed,
## so the key went through without the door ever sounding.
##
## Both reaches are the handlers' own now. The gate is the 0xEF measure,
## 60 units from the eye plus the 26-unit pad the port's capsule needs;
## the doorway is the touch radius that armed it, not that radius plus a
## gate's on top of it (M3 step 4 read the extra 60 as port_use_reach).
##
## zone-local ↔ world: both arrive as WORLD positions and are taken into
## the records' zone-local space here.
func activate_teleport(player_pos: Vector3, eye: Vector3 = Vector3.INF) -> bool:
	var here: Vector3 = player_pos - zone_origin
	var from_eye: Vector3 = (eye - zone_origin) if eye.is_finite() else here
	if _teleport_fired:
		return false
	# The gate is its own node's business now (step 5c): which of them the
	# key reaches, and on what measure, is asked of the branch.
	var gate: Node = behaviour.gate_to_exit(from_eye) if behaviour != null else null
	if gate != null:
		return use_exit_through(gate)
	for ti in _teleports.size():
		var e: MapFile.Entity = _teleports[ti]
		if not enabled(e.file_off):
			continue
		var epos: Vector3 = _teleport_pos[ti]
		if not _within_touch(epos, here, TELEPORT_TOUCH_RADIUS):
			continue
		if not _reachable(here, epos):
			continue                         # a closed door leaf is in the way
		return _fire_teleport(e)
	return false

## Nothing solid between the player and `target` (a doorway sprite sits
## on the floor, so aim a little above it). True when no physics space
## is available (headless unit tests).
##
## zone-local ↔ world: both ends are zone-local, and the physics space is
## the world's — the rays are cast with the zone origin added back on.
func _reachable(from_local: Vector3, target_local: Vector3) -> bool:
	if space == null:
		return true
	var from: Vector3 = from_local + zone_origin
	var target: Vector3 = target_local + zone_origin
	# `from` is the player's FEET (use_pressed sends global_position). One
	# ray from the floor ran through MAP.252's torpedo-room shell 22 u from
	# the player, so the exit into it never fired (found by --solve,
	# 2026-09-11). Look from the eye and the chest to the sprite's middle
	# and its foot; a closed door leaf (108 u tall) still blocks all four.
	for fy in [75.0, 40.0]:
		for ty in [40.0, 8.0]:
			var a: Vector3 = from + Vector3(0.0, fy, 0.0)
			var b: Vector3 = target + Vector3(0.0, ty, 0.0)
			var q := PhysicsRayQueryParameters3D.create(a, b)
			q.collide_with_areas = false
			if player_body != null:
				q.exclude = [player_body.get_rid()]
			var hit := space.intersect_ray(q)
			if not hit.has("position") or (hit["position"] as Vector3).distance_to(b) < 48.0:
				return true
	return false

## Use key with nothing activatable under the crosshair: the nearest wall
## button the player stands at answers it (behaviour.use_nearby — the
## nodes' own measure, and where the rest of that story is written down).
##
## zone-local ↔ world: both arrive as WORLD positions and are taken into
## the records' zone-local space here.
func use_nearby(player_pos: Vector3, eye: Vector3 = Vector3.INF) -> bool:
	if behaviour == null:
		return false
	var here: Vector3 = player_pos - zone_origin
	return bool(behaviour.use_nearby((eye - zone_origin) if eye.is_finite() else here))

## Called right after the player is placed: latch every gate and doorway
## the spawn point already lies inside, so a return exit that drops the
## player beside the gate it came through (MAP.210 marker 27 is 64 units
## from the bunker gate; MAP.211's start sits inside its DOOR gate) waits
## for the player to step out and back in instead of bouncing straight
## back. The triggers measure from `eye_pos` as the sweep does (default:
## the body position), the doorways from the body.
##
## zone-local ↔ world: both arrive as WORLD positions and are taken into
## the records' zone-local space here.
func arm_proximity(player_pos: Vector3, eye_pos: Vector3 = Vector3.INF) -> void:
	var here: Vector3 = player_pos - zone_origin
	var eye: Vector3 = here if eye_pos == Vector3.INF else eye_pos - zone_origin
	if behaviour != null:
		behaviour.prox_arm(eye)
	for ti in _teleports.size():
		var e: MapFile.Entity = _teleports[ti]
		if _within_touch(_teleport_pos[ti], here, TELEPORT_TOUCH_RADIUS):
			_touch_latched[e.file_off] = true

## Enabled now, or enabled at any point earlier in this tick (see
## `_armed`) — the test the one-shot sweeps use. PUBLIC since step 5d:
## the classes that moved onto their nodes make the same test, and reach
## it through the branch (Behaviour.fires).
func fires(off: int) -> bool:
	return enabled(off) or _armed.has(off)

func _fires(e: MapFile.Entity) -> bool:
	return fires(e.file_off)

## Switch an entity's enable bit off — what the DOS handlers do to
## themselves when they are done. One place to write it since step 5a:
## the bit used to live in the record AND on the Behaviour node, and
## clearing the record alone left the node at 1, so the next flip of a
## door that had run its course took it 1 → 0 and it never moved again
## (MAP.210's gate could open but never close).
func _clear_enable(e: MapFile.Entity) -> void:
	triggers.clear_enable(e.file_off)

## (The whole of a path vehicle — picking the path up, the segment speed,
## the yaw it turns to, the chain it fires at the end and the stop case
## that switches the path off again — is the vehicle's own node since step
## 5f: scripts/level/path_vehicle.gd, registered by the level loader
## straight onto the branch, with every reading that was bought for it.)

static func _dos_pos(e: MapFile.Entity) -> Vector3:
	return Vector3(float(e.x), -float(e.y), -float(e.z))

## The port's own test for STANDING IN a doorway (the 0xF0 exits): the
## TRUE 3D distance belongs to the DOS proximity handlers, whose radii
## come from the game data (Trigger.inside). A doorway sprite hangs above
## the floor the player walks on, so measuring it in 3D put the truck on
## MAP.210 out of reach — horizontal distance with a vertical window, as
## before.
static func _within_touch(epos: Vector3, player_pos: Vector3, radius: float) -> bool:
	if absf(player_pos.y - epos.y) > PROX_VERTICAL_WINDOW:
		return false
	return Vector2(player_pos.x - epos.x, player_pos.z - epos.z).length() <= radius

## --- Per-map state overlay ------------------------------------------
## DOS "Mst": MstSave (FUN_0012e0f4) on leaving a map, MstLoad
## (FUN_0012e094) after MapStart. Maps are always re-parsed from disk on
## entry, so everything the player changed — toggled trigger bits, mover
## travel, damage stages, spent switches, remaining HP — is captured here
## and re-applied on return.
func save_state() -> Dictionary:
	# The state bytes, and the act bytes and links play has changed
	# ("acts" / "links", 2026-09-14; a snapshot without them restores as
	# before) — the trigger runtime's, which is where they live. They
	# belong to this map number only: main.gd never carries them to a
	# variant map. Since step 5g the pool of hit points and the records
	# that have none left come out of the same place.
	var bytes: Dictionary = triggers.snapshot() if triggers != null \
		else {"states": {}, "acts": {}, "links": {}, "hp": {}, "spent": {}}
	# How far each mover has travelled and which way it goes next — the
	# movers' own since step 5e, and asked of them here so the snapshot's
	# shape is unchanged (step 5h moves the save format itself). The same
	# goes for the wrecks, whose stage is their own node's since step 5g.
	var movers: Dictionary = behaviour.mover_snapshot() if behaviour != null else {}
	var destr: Dictionary = behaviour.destruct_snapshot() if behaviour != null else {}
	# The robots an 0xF3 chain has let out: the sprites' own since step 5d,
	# and asked of them here so the snapshot's shape is unchanged (step 5h
	# moves the save format itself).
	var spawned: Dictionary = behaviour.spawned_offs() if behaviour != null else {}
	return {
		"states": bytes["states"], "movers": movers, "destr": destr,
		"hp": bytes["hp"], "spent": bytes["spent"],
		"spawned": spawned,
		"acts": bytes["acts"], "links": bytes["links"],
	}

## Re-apply a save_state() snapshot. Call after every node is registered
## (register_node / register_destructible) so the visuals refresh too —
## and before the Behaviour branch enters the tree (main.gd), whose _ready
## fires the cues the state says are armed.
func restore_state(snap: Dictionary) -> void:
	if _map == null or snap.is_empty():
		return
	# The state bytes, and the act bytes and links play changed — a cue
	# that fired is retired (0xFF), a water valve remembers which way it
	# goes next. The runtime takes them and puts the retirement back onto
	# the cue nodes, or an objective would count again on the next flip.
	# (The pool of hit points and the spent flags come back with them since
	# step 5g — they are the one writer's like every other byte.)
	if triggers != null:
		triggers.restore(snap)
	# Robots an 0xF3 chain already let out come back out (the dead ones
	# the map overlay removes on its own). They were counted for the
	# STATISTICS page when they first appeared.
	Stats.hold_enemy_count = true
	if behaviour != null:
		for off in (snap.get("spawned", {}) as Dictionary):
			behaviour.spawn_reveal(int(off))
	Stats.hold_enemy_count = false
	# …and the movers back where the overlay left them, mesh and all, and
	# every wreck at the stage it had reached — a plain prop the overlay
	# says was destroyed leaves the world again with them. All of it the
	# nodes' own work, since steps 5e and 5g.
	if behaviour != null:
		behaviour.mover_restore(snap.get("movers", {}))
		behaviour.destruct_restore(snap.get("destr", {}))

## (The mover step, the transform it comes to and the travel it announces
## are the Mover nodes' own since step 5e — scripts/level/mover.gd
## mover_watch / apply_transform / travel_to, with every reading that was
## bought for them.)
##
## (ObjHit itself, the TRANSFRM.PRS damage stages of 0x18/0x19, the 0x1B
## killing blow and the destruction that follows a spent pool of hit
## points — the blast, the radial one it throws, the drop and the sound —
## are the Behaviour branch's since step 5g: scripts/level/behaviour.gd
## obj_hit / destruct_tick / demolish_tick / destroy, and the stage a
## wreck is showing is the record's own scripts/level/destructible.gd.)
