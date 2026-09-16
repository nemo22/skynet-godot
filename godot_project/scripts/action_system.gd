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
##   0x18/0x19            — destructible mesh-swap per TRANSFRM.PRS
##                          damage stages (handler 0x120433).
##   0xEF                 — use-key gate, 60 units (0x137e2e: runs only
##                          in the frame ACTIVATE goes down).
##   0xF1/0xF2            — proximity-gated chain trigger (0x1379c4).
##                          Both handlers measure in 3D from the EYE — the
##                          camera position [0xd47b4] (see tick).
##   0xF0                 — interior teleport (0x137881): target map at
##                          sub+2, spawn-marker set at sub+4; one-shot.
##
## Runtime state (mutated state bytes, mover progress, damage stages)
## lives on/next to the parsed MapFile — reloading a map re-parses it,
## which matches DOS (maps are always reloaded from disk; the Mst
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
## far: the chain walk itself (ObjFlipLink runs on the nodes and mirrors
## every state bit back into the records read here) and the one-shot
## cues — sounds, voice lines, hints, objectives fire from their nodes.
## Still here: movers, proximity, exits, destructibles, demolition.

extends RefCounted

const Explosion := preload("res://scripts/explosion.gd")
const Projectile := preload("res://scripts/projectile.gd")

signal teleport_requested(target_map: int, marker_set: int)
## A destroyed object drops an item (FUN_00124293 → FUN_00124119).
signal drop_requested(pos: Vector3, drop_type: int)
## Acts 0xd6-0xda (handler 0x121160): the map's water level glides to a
## new target. `absolute` = go to this Y, otherwise add it to the target.
## MAP.254's sewers flood and drain as the walls and valves are opened.
signal water_level_requested(value: float, absolute: bool)

const MapFile := preload("res://scripts/loaders/map_file.gd")
const PickupData := preload("res://scripts/pickup_data.gd")
## What each action id MEANS now lives on its own, next to the generated
## trigger graph that reads the same rows (scripts/triggers/rules_skynet.gd,
## M3 step 1). The tables below are those rows by reference, so every
## caller of ActionSystem.MOVER_TABLE / SOUND_ONESHOT / WATER_ACTS / the
## ACT_* bands still finds them here and nothing about play changes.
## Future Shock runs SkyNET's table at run time as it always has (its own
## rules_shock.gd is used by the graph alone, and is informational).
const Rules := preload("res://scripts/triggers/rules_skynet.gd")

## Every table and band below is scripts/triggers/rules_skynet.gd's row
## set, by reference: the tables moved there with their notes (M3 step 1)
## and nothing about play changed. Bodies of the handlers, the mover
## families and the provenance of each id are documented there.
const MOVER_TABLE: Dictionary = Rules.MOVER_TABLE
const SOUND_ONESHOT: Dictionary = Rules.SOUND_ONESHOT
const WATER_ACTS: Dictionary = Rules.WATER_ACTS

const ACT_DESTRUCT_A: int = Rules.ACT_DESTRUCT_A
const ACT_DESTRUCT_B: int = Rules.ACT_DESTRUCT_B
const ACT_DEMOLISH: int = Rules.ACT_DEMOLISH
const ACT_LIGHT_TOGGLE: int = Rules.ACT_LIGHT_TOGGLE
const ACT_LIGHT_FLICKER: int = Rules.ACT_LIGHT_FLICKER
const ACT_LIGHT_STROBE: int = Rules.ACT_LIGHT_STROBE
const ACT_LIGHT_FADE_UP_FIRST: int = Rules.ACT_LIGHT_FADE_UP_FIRST
const ACT_LIGHT_FADE_DOWN_LAST: int = Rules.ACT_LIGHT_FADE_DOWN_LAST
const LIGHT_FX_TICK: float = 1.0 / 20.0
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
const RELAY_AT: int = Rules.RELAY_AT
const ACT_SPAWN: int = Rules.ACT_SPAWN
var _water_nodes: Array = []      # entities with a water act

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
var _movers: Dictionary = {}      # file_off → mover runtime state
var _prox: Array = []             # entities with a proximity act type
var _teleports: Array = []        # entities with act 0xF0
## Their world positions, index for index — tick() tests them every
## physics step, and the records never move.
var _prox_pos: PackedVector3Array = PackedVector3Array()
var _teleport_pos: PackedVector3Array = PackedVector3Array()
## Act byte and link as parsed, per file offset: save_state() keeps the
## ones play changed (a cue retired to 0xFF, the water valves swapping
## 0xd9/0xda, a path end cut off), which re-parsing the map would undo.
var _parsed_act: Dictionary = {}
var _parsed_link: Dictionary = {}
var _light_ents: Array = []       # variant-2 lights with a light act
## file_off → OmniLight3D placed by main (_place_map_lights); a light
## act flips the record and this node follows.
var map_lights: Dictionary = {}
var _light_fx_clock: float = 0.0
var _light_strobe_on: Dictionary = {}   # file_off → visible (flicker/strobe state)
var _destruct_nodes: Array = []   # entities with acts 0x18/0x19
var _demolish_nodes: Array = []   # entities with act 0x1B
## The level's Behaviour branch (scripts/level/behaviour.gd): the chain
## walk runs there and the cue nodes fire themselves (F2).
var behaviour: Node = null
## The level's trigger event bus (scripts/triggers/trigger_bus.gd, M3
## step 3): every handler run below announces itself on it. An OBSERVER
## — the sweeps do not know whether anything listens, `null` is an
## ordinary state (a test building an ActionSystem by hand), and play is
## the same either way. See _say.
var bus: RefCounted = null
## file_off → true while a light act is running, so the light effect is
## announced on the EDGE. The flicker and strobe handlers run every tick
## their bit is up (0x137713 / 0x13773b) and would otherwise announce a
## hundred times a second.
var _light_live: Dictionary = {}
## Physics access for reachability tests (set by the level controller).
var space: PhysicsDirectSpaceState3D = null
var player_body: CollisionObject3D = null
var _destr: Dictionary = {}       # file_off → destructible runtime state
var _hp: Dictionary = {}          # file_off → remaining HP
var _spent: Dictionary = {}       # file_off → true (HP-depleted, inert)
var _prox_latched: Dictionary = {} # file_off → true while player inside
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
## Gates whose chain the key has already walked on the way to a doorway —
## one walk per gate per level instance (see _use_exit).
var _exit_walked: Dictionary = {}
var _teleport_fired: bool = false   # one map change per level instance
## The use key's first frame. DOS 0x137e2e opens with `cmp [0x2c7f], 1`
## — ACTIVATE went down this very frame — and only then flips every live
## 0xEF gate within 60 u; walking into one does nothing (disassembled
## 2026-09-11). The port had them fire on approach, so the jeep drove
## into MAP.220's truck by itself. Set by press_use(), spent by tick().
var _use_edge: bool = false
var _edge_done: Dictionary = {}          # gates the key already flipped this press
## Objectives still to go — main.gd keeps the count (DOS [0x1e6c2]);
## the 0x2C relays watch it.
var objectives_left: int = 0
var _relays: Array = []
var _spawns: Dictionary = {}      # 0xF3 sprite file_off → its hidden Enemy
var _spawned: Dictionary = {}     # 0xF3 sprite file_off → true once revealed
## Path-following vehicles — DOS AI state 11, v1.01 handler 0x127400:
## the cargo truck that drives into MAP.210's base, MAP.260's convoy,
## MAP.280's boss chase and the HK that lifts the player off MAP.234's
## roof. Types 46-52 share the parameters (enemy table 0x44E00).
const PATH_SPEED_K: float = 80.0 / 256.0        # segment speed = k · its length
const PATH_ACCEL: float = 160.0                 # units/s², from a standstill
const PATH_TURN: float = 128.0 / 2048.0 * TAU   # 22.5°/s, yaw only and visual
const PATH_REACH: float = 80.0                  # 3D distance that counts as arrived
## DOS ticks the actors in the 5×5 MAP-GRID cells around the player —
## the cell index, not a radius (0x12980f: edx = 5). A grid cell is 1024
## units (64×64 cells over the 65536-unit map), so the window reaches two
## cells each way. The port used a 1024-unit radius, and the HK that
## lifts the player off MAP.234's roof waits 2413 units from where he
## arrives: it never started ("na strechu malo prísť HK a nepriletelo").
const PATH_TICK_CELL: float = 1024.0
const PATH_TICK_CELLS: int = 2
const MARKER_PATH_LOOP: int = 105               # marker type that loops to the start
var _path_vehicles: Dictionary = {}   # marker file_off → runtime state

func press_use() -> void:
	_use_edge = true
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

func setup(map: MapFile.MapFile) -> void:
	_map = map
	for e in map.entities:
		_parsed_act[e.file_off] = e.link_act_type
		_parsed_link[e.file_off] = e.link_next
		# Placement MARKERS (enemy starts, radiation sources …) keep
		# other data where a sprite keeps its act byte — an enemy
		# marker's "act" is its enemy type.
		if e.marker_type >= 0:
			continue
		var act: int = e.link_act_type
		if act == ACT_PROX_GATE:
			if gate_runs(e):
				_prox.append(e)
				_prox_pos.append(_dos_pos(e))
		elif act == ACT_PROX_CHAIN_A or act == ACT_PROX_CHAIN_B:
			_prox.append(e)
			_prox_pos.append(_dos_pos(e))
		elif act == ACT_TELEPORT:
			_teleports.append(e)
			_teleport_pos.append(_dos_pos(e))
		elif (e.flags & 3) == 2 and is_light_act(act):
			_light_ents.append(e)
		elif act == ACT_RELAY:
			_relays.append(e)
		elif WATER_ACTS.has(act):
			_water_nodes.append(e)
		elif is_destructible(act):
			_destruct_nodes.append(e)
		elif act == ACT_DEMOLISH:
			_demolish_nodes.append(e)
		if (e.flags & 3) == 1 and e.hp > 0:
			_hp[e.file_off] = float(e.hp)

## The 0xEF handler (0x137e2e) runs only for a state byte whose bits
## 1-2 are both clear or both set. A prop that carries the "act on
## death" bit alone is NOT a gate: the DESK0S of MAP.461 (state 04, HP
## 50) or a stacked crate on MAP.213 fires its chain from ObjHit when it
## breaks, and walking past it does nothing.
## 11-bit DOS Euler angles (pitch, yaw, roll — sub+0/+4/+8) → Godot basis:
## Rz(-roll)·Rx(+pitch)·Ry(+yaw), the DOS matrix (FUN_0014e100) conjugated
## by the Y/Z flip. Floats, so an animation can add a fraction.
static func euler_basis(pitch: float, yaw: float, roll: float) -> Basis:
	var b := Basis()
	b = b.rotated(Vector3.UP, yaw * TAU / 2048.0)
	b = b.rotated(Vector3.RIGHT, pitch * TAU / 2048.0)
	b = b.rotated(Vector3.BACK, -roll * TAU / 2048.0)
	return b

## A swing/rot mover after `delta` 11-bit units about DOS axis `axis_i`
## (0 pitch, 1 yaw, 2 roll). The DOS handler (0x137c6b) adds to ONE Euler
## component of the entity and the renderer rebuilds the matrix from the
## three — so the motion is neither a local nor a world rotation but the
## Euler composition with that component advanced. The old
## `base * Basis(axis, angle)` was right for yaw only: the two halves of
## MAP.281's drawbridge (0xC3/0xC4, roll ±512) swung one down, one UP
## (playtest, 2026-09-05: "ten druhý sa zle rotuje").
static func swing_basis(euler: Vector3, axis_i: int, delta: float) -> Basis:
	var e := euler
	match axis_i:
		0: e.x += delta
		1: e.y += delta
		_: e.z += delta
	return euler_basis(e.x, e.y, e.z)

## The one rule of the port's own the owner kept (2026-09-15): a NAMED
## variant-1 mesh whose state byte carries bit 3 is a wall button, and it
## answers the use key instead of the player walking past it. DOS knows no
## such thing — its 0xEF/0xF1/0xF2 handlers all measure the player and
## fire — but a panel you brush past and set off by accident reads as a
## bug, so these come off the proximity sweep (tick) and go on the key
## (use_nearby, or the crosshair ray through an ActionTarget).
## (An UNNAMED variant-1 record with the same state byte is an invisible
## floor trigger — MAP.231's elevator call points sit at the back wall of
## the cab, state 0x09, no mesh at all — and stays on the sweep.)
static func is_wall_button(e: MapFile.Entity) -> bool:
	return (e.flags & 3) == 1 and (e.state_byte & 8) != 0 and e.name_index >= 0

static func is_light_act(act: int) -> bool:
	return act == ACT_LIGHT_TOGGLE or act == ACT_LIGHT_FLICKER or act == ACT_LIGHT_STROBE \
		or (act >= ACT_LIGHT_FADE_UP_FIRST and act <= ACT_LIGHT_FADE_DOWN_LAST)

## The light record `e` as the map shows it: on when the enable word is
## positive (the DOS toggle flips its sign bit).
func _light_apply(e: MapFile.Entity) -> void:
	var l = map_lights.get(e.file_off)
	if l == null or not is_instance_valid(l):
		return
	var on: bool = e.light_enable > 0
	if _light_strobe_on.has(e.file_off):
		on = on and bool(_light_strobe_on[e.file_off])
	(l as Node3D).visible = on

## One-shot light acts, run when the light's bit 0 is set (DOS runs the
## handler each tick the bit is on; toggle and the fades clear it).
func _light_step(e: MapFile.Entity, fx_tick: bool) -> void:
	var act: int = e.link_act_type
	if act == ACT_LIGHT_TOGGLE:
		e.light_enable = -e.light_enable if e.light_enable != 0 else 1
		_clear_enable(e)
		_light_apply(e)
	elif act == ACT_LIGHT_FLICKER or act == ACT_LIGHT_STROBE:
		if not fx_tick:
			return
		var cur: bool = bool(_light_strobe_on.get(e.file_off, true))
		if act == ACT_LIGHT_STROBE or randf() < 0.5:
			cur = not cur
		_light_strobe_on[e.file_off] = cur
		_light_apply(e)
	else:
		# Fade by (act - 12)/4 of the current intensity, up or down.
		var l = map_lights.get(e.file_off)
		var f: float = float(act - 0x0C) / 4.0
		if act >= 0x10:
			f = -float(act - 0x0C) / 4.0
		if l != null and is_instance_valid(l):
			(l as OmniLight3D).light_energy = maxf((l as OmniLight3D).light_energy * (1.0 + f), 0.0)
		e.light_intensity = maxi(int(float(e.light_intensity) * (1.0 + f)), 0)
		_clear_enable(e)
		_light_apply(e)

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

static func gate_runs(e: MapFile.Entity) -> bool:
	if e.link_act_type != ACT_PROX_GATE:
		return false
	var bits: int = e.state_byte & 6
	return bits == 0 or bits == 6

## Does this act type get a visual/interactive node treatment?
static func is_mover(act: int) -> bool:
	return MOVER_TABLE.has(act)

static func is_destructible(act: int) -> bool:
	return act == ACT_DESTRUCT_A or act == ACT_DESTRUCT_B

## Attach the visual node for an entity (movers, destructibles,
## damageable meshes). Captures the mover's base transform.
func register_node(e: MapFile.Entity, node: Node3D) -> void:
	_nodes[e.file_off] = node
	if is_mover(e.link_act_type):
		var cfg: Array = MOVER_TABLE[e.link_act_type]
		var limit: int = cfg[2]
		if limit >= 0x8000: limit -= 0x10000        # signed i16
		_movers[e.file_off] = {
			"family": cfg[0],
			"axis": clampi(int(cfg[1]), 0, 2),
			"limit": float(limit),
			"p4": int(cfg[1]),
			# Slide/swing handlers step +p6 for odd act ids and -p6 for
			# even ones (`and ebx,1` in 0x137a28/0x137c6b) — the two
			# leaves of a gate carry 0x41 and 0x42 and part.
			"sign": 1.0 if (e.link_act_type & 1) != 0 else -1.0,
			"progress": 0.0,
			"dir": 1.0,
			"base": node.transform,
			"euler": Vector3(float(e.off_x & 0x7FF), float(e.off_y & 0x7FF), float(e.off_z & 0x7FF)),
		}

## Register the damage-stage meshes for a destructible entity (built by
## the level loader from TRANSFRM.PRS; may be empty → vanish on kill).
## Does the entity at `off` take damage (HP pool or destruction stages)?
func is_damageable_off(off: int) -> bool:
	if _spent.has(off):
		return false
	return _hp.has(off) or _destr.has(off)

## True when the entity at `off` is a mover (door/gate/lift/rotator).
## One line per mover: what it is, how far it has moved and which way —
## the console's `movers`.
func mover_report() -> String:
	var out: PackedStringArray = PackedStringArray()
	for off in _movers:
		var m: Dictionary = _movers[off]
		var e: MapFile.Entity = _map.entities_by_off.get(off) if _map != null else null
		var nm: String = MapFile.entity_name(_map, e) if e != null else "?"
		var span: float = absf(float(m["limit"]))
		if String(m["family"]) == "slide5f":
			span = absf(float(int(m["limit"]) << 4))
		var n = _nodes.get(off)
		var bx: String = "-"
		if n != null and is_instance_valid(n) and n is Node3D:
			var b: Basis = (n as Node3D).global_transform.basis
			bx = "X%s Y%s" % [str(b.x.round()), str(b.y.round())]
		out.append("@%05x %-8s %-7s act %02x state %02x progress %.0f/%.0f dir %+.0f sign %+.0f axis %d %s" % [
			off, nm, String(m["family"]), e.link_act_type if e else 0, e.state_byte if e else 0,
			float(m["progress"]), span, float(m["dir"]), float(m.get("sign", 1.0)), int(m["axis"]), bx])
	return "
".join(out) if out.size() > 0 else "no movers"

func is_mover_off(off: int) -> bool:
	return _movers.has(off)

## Movers that translate/swing as a solid piece (doors, gates, lifts) —
## they get a box collider; continuous rotators keep their trimesh.
func is_solid_mover(off: int) -> bool:
	if not _movers.has(off):
		return false
	return String(_movers[off]["family"]) in ["slide", "swing", "jump", "slide5f"]

func register_destructible(e: MapFile.Entity, stage_meshes: Array) -> void:
	_destr[e.file_off] = {
		"meshes": stage_meshes,   # ArrayMesh per stage, [0] = intact
		"stage": 0,
		"accum": 0.0,
	}

## ObjHit port. Returns true when the hit was consumed by an action
## (so callers can skip generic hit effects).
func on_player_hit(file_off: int, damage: float) -> bool:
	var e: MapFile.Entity = _map.entities_by_off.get(file_off) \
		if _map != null else null
	if e == null:
		return false
	# ObjHit FUN_00139019: bit1 = act on every hit (before the HP test,
	# so a wreck keeps staging after its HP is gone), bit2 = act once
	# the HP is gone; the HP itself drains independently of those bits,
	# so a crate with state 0 still breaks (and drops its ammo).
	var spent: bool = _spent.has(file_off)
	var has_hp: bool = _hp.has(file_off) and (e.flags & 3) == 1 and not spent
	var depleted: bool = has_hp and _hp[file_off] - damage <= 0.0
	var acted: bool = false
	if (e.state_byte & 6) != 0:
		# Destructible damage accumulates every qualifying hit. Membership
		# comes from registration (act 0x18/0x19 OR a TRANSFRM.PRS name
		# match — cars carry bit1 + HP but act 0x00 in the MAP data).
		if _destr.has(file_off):
			acted = _advance_destructible(e, damage)
		elif not spent and ((e.state_byte & 2) != 0 or ((e.state_byte & 4) != 0 and depleted)):
			_trigger(e)
			acted = true
	if has_hp:
		_hp[file_off] -= damage
		acted = true
		if depleted:
			_spent[file_off] = true
			_destroy(e)
	return acted

## Activate-key port. The DOS use-key path is untraced; we honour the
## same bit1 ("act on hit") gate without applying damage, which covers
## shoot-or-use switches while leaving HP-gated objects (generators,
## bit2) to real damage.
##
## zone-local ↔ world: `player_pos` (the feet) and `eye` are WORLD
## positions and are taken into the records' zone-local space for the
## measure below; `player_pos` goes on unchanged to whatever needs it.
## Vector3.INF for either means "no measure" — the caller has picked both
## the entity and the place, and says so (TriggerEquiv.activate, the
## solver).
func on_player_activate(file_off: int, player_pos: Vector3 = Vector3.INF,
		eye: Vector3 = Vector3.INF) -> bool:
	var e: MapFile.Entity = _map.entities_by_off.get(file_off) \
		if _map != null else null
	if e == null or _spent.has(file_off):
		return false
	# A PROXIMITY record is measured wherever the key reaches it. Its DOS
	# handler runs for a player inside the radius the slot carries and for
	# no one else (0x1386a0 for the 0xEF, 0x138223 for the 0xF1/0xF2), and
	# that holds whichever way the port's key arrived — the proximity sweep
	# in tick(), use_nearby, or the crosshair ray. Without it the key
	# operated a gate from anywhere the ray could see it, 600 units away
	# (M3 step 4: port_use_reach).
	#
	# A WALL BUTTON is the exception, and it is the whole of the owner's
	# kept rule: it answers the key INSTEAD of proximity, so proximity is
	# not its measure — what limits it is the crosshair that found it.
	# MAP.210's base doors are opened by a BUTTON01 three hundred units up
	# a tower wall, which no proximity radius in the original reaches.
	# Records that are not proximity types keep the port's aim-and-press
	# rule as it was: the ray is all they have ever had.
	if player_pos.is_finite() and not is_wall_button(e) and (gate_runs(e)
			or e.link_act_type == ACT_PROX_CHAIN_A
			or e.link_act_type == ACT_PROX_CHAIN_B):
		var from: Vector3 = (eye if eye.is_finite() else player_pos) - zone_origin
		if not _within(_dos_pos(e), from, _prox_radius(e)):
			return false
	# Levers, buttons and proximity gates (0xEF/0xF1/0xF2) are use-key
	# operated in DOS — the tower lever opens the base gate — even
	# though their state byte carries no "act on hit" bit.
	#
	# A CUE no chain points at used to be in this list as well: a hint the
	# player could read by pressing the key at it (MAP.280's doorway
	# sprite), narrowed on 2026-09-07 to keep objectives out of it after
	# MAP.252's picture finished mission 5 from the cabin wall. The owner
	# retired the whole rule on 2026-09-15 — DOS has no use-key path to a
	# cue at all, and his own DOS run of mission 5 reaches neither the
	# picture nor the hint beside it. They are unreachable there too.
	var usable: bool = (e.state_byte & 2) != 0 \
		or gate_runs(e) or e.link_act_type == ACT_PROX_CHAIN_A \
		or e.link_act_type == ACT_PROX_CHAIN_B
	if not usable:
		return false
	# 0xF1/0xF2 are one-shot in DOS (they clear their own bit 0 when they
	# fire — see the proximity loop): once spent, the use key must not
	# flip the chain back either, or pressing F at MAP.210's lever
	# after it tripped would shut the gate again.
	var chain_trigger: bool = e.link_act_type == ACT_PROX_CHAIN_A 		or e.link_act_type == ACT_PROX_CHAIN_B
	if chain_trigger and (e.state_byte & 1) == 0:
		return false
	# A gate whose chain ends in an exit (the truck DOOR in MAP.211/212,
	# the bunker doorway gates) is the use-key way through: arm the exit
	# if the chain has not flipped yet and go, wherever its sprite sits.
	if e.link_act_type == ACT_PROX_GATE:
		var t: MapFile.Entity = _chain_teleport(e)
		if t != null:
			return _use_exit(e, t)
		# The gate the key was aimed at: flipped here, so the key's sweep
		# in tick() must leave it alone or it would flip straight back.
		_edge_done[e.file_off] = true
	if (e.state_byte & 2) != 0:
		_trigger(e)
	else:
		_flip_link(e)
	if chain_trigger:
		_clear_enable(e)                     # after the flip, as 0x1379c4 does
	return true

## First 0xF0 node reachable down the chain from `start`, or null.
func _chain_teleport(start: MapFile.Entity) -> MapFile.Entity:
	var cur: MapFile.Entity = start
	var visited: Dictionary = {}
	while cur != null and not visited.has(cur.file_off):
		visited[cur.file_off] = true
		if cur.link_act_type == ACT_TELEPORT:
			return cur
		if cur.link_next < 1:
			return null
		cur = _map.entities_by_off.get(cur.link_next)
	return null

## Use-key on a gate whose chain ends in a doorway.
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
## its failures). The guard is this gate's own — not _prox_latched, which
## a spawn inside the gate pre-sets (arm_proximity) and which would then
## swallow the very first walk in the truck interiors.
func _use_exit(gate: MapFile.Entity, t: MapFile.Entity) -> bool:
	if _teleport_fired:
		return false
	if not _exit_walked.has(gate.file_off):
		_exit_walked[gate.file_off] = true
		_flip_link(gate)
	t.state_byte |= 1
	return _fire_teleport(t)

func _fire_teleport(t: MapFile.Entity) -> bool:
	if _teleport_fired or (t.state_byte & 1) == 0:
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

## ObjFlipLink FUN_001394aa — runs on the Behaviour branch since F2
## (scripts/level/behaviour.gd flip): toggle bit 0 down the chain, an
## 0xEF node forces its bit back on, the walk stops at an actor, and a
## one-shot cue whose bit goes up fires there and then. The nodes
## mirror every bit into the records, so the sweeps below keep reading
## the entities as before.
func _flip_link(start: MapFile.Entity) -> void:
	if behaviour == null:
		push_warning("[action] no Behaviour branch — chain from @%05x dropped" % start.file_off)
		return
	for item in behaviour.flip(start.file_off):
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
	var lit: bool = (e.state_byte & 1) != 0
	node.set_meta("switch_lit", lit)
	mi.set_surface_override_material(0, mi.mesh.surface_get_material(1) if lit else null)
	mi.set_surface_override_material(1, mi.mesh.surface_get_material(0) if lit else null)

## ObjDoAction: dispatch when enabled. Movers/proximity/teleports are
## per-tick handlers driven from tick(); the one-shot families run here.
func _do_action(e: MapFile.Entity) -> void:
	var act: int = e.link_act_type
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
	if not _light_ents.is_empty():
		_light_fx_clock += delta
		var fx_tick: bool = _light_fx_clock >= LIGHT_FX_TICK
		if fx_tick:
			_light_fx_clock = 0.0
		for e in _light_ents:
			if (e.state_byte & 1) != 0 or _armed.has(e.file_off):
				if not _light_live.has(e.file_off):
					_light_live[e.file_off] = true
					_say(e.file_off, "light", "light",
						{"op": Rules.light_op(e.link_act_type), "enable": e.light_enable})
				_light_step(e, fx_tick)
			else:
				_light_live.erase(e.file_off)
				if _light_strobe_on.has(e.file_off):
					# The chain took the bit away: the flicker ends on.
					_light_strobe_on.erase(e.file_off)
					_light_apply(e)
	# Movers ------------------------------------------------------
	for off in _movers:
		var e: MapFile.Entity = _map.entities_by_off.get(off)
		if e == null or (e.state_byte & 1) == 0:
			# A chain took the bit away in the middle of a run: the mover
			# stops where it stands and the next enable is a new run.
			var stopped: Dictionary = _movers[off]
			if bool(stopped.get("running", false)):
				stopped["running"] = false
			continue
		_step_mover(off, e, delta)
	# Proximity triggers ------------------------------------------
	# DOS: the 0xEF handler (0x137e2e) never looks at bit 0 — every gate
	# is live (MAP.215's silo cover opens from a CORC3229 piece whose
	# state is 0x10) — but it runs only in the frame ACTIVATE goes down
	# (see press_use). 0xF1/0xF2 watch the player's presence; variant-1
	# meshes with state bit 3 (the wall buttons, state 0x09) stay on the
	# use key — walking past a button must not press it.
	for pi in _prox.size():
		var e: MapFile.Entity = _prox[pi]
		# 0xEF gates and the 0xF1 / 0xF2 chain triggers all watch the
		# player (handlers 0x137e2e and 0x1379c4); the radii differ.
		# MAP.220's mission objective hangs off an 0xF2 button 1024 units
		# from the road, which is how that jeep mission ends.
		if is_wall_button(e):
			continue                         # the key or the crosshair, not the walk
		if _spent.has(e.file_off):
			continue
		var epos: Vector3 = _prox_pos[pi]
		var inside: bool = _within(epos, eye, _prox_radius(e))
		var latched: bool = _prox_latched.get(e.file_off, false)
		# 0xF1/0xF2 are ONE-SHOT. Their handler (0x1379c4) ends by calling
		# 0x139644 with dl = 0xFE, bl = 0 — `state &= 0xFE`, i.e. the
		# trigger clears its own enable bit and stays off until a chain
		# turns it back on. The port used to re-arm it every time the
		# player left the radius, so walking back to MAP.210's gate
		# flipped BIGDOOR again and shut it in his face ("potom sa zasa
		# zavrie a nedá sa tam dostať"). 0xEF gates are different: they
		# force their own bit back on (see gate_runs).
		var chain_trigger: bool = e.link_act_type == ACT_PROX_CHAIN_A 			or e.link_act_type == ACT_PROX_CHAIN_B
		# 0xEF: the key, not the approach. A gate whose chain ends in an
		# exit is the use key's way through and goes by activate_teleport.
		if e.link_act_type == ACT_PROX_GATE:
			if _use_edge and inside and _chain_teleport(e) == null and not _edge_done.has(e.file_off):
				print("[action] gate @%05x used at %s" % [e.file_off, epos])
				_flip_link(e)
			continue
		if chain_trigger and (e.state_byte & 1) == 0:
			continue
		if inside and not latched:
			_prox_latched[e.file_off] = true
			print("[action] gate @%05x (act %02x) tripped at %s" % [e.file_off, e.link_act_type, epos])
			# DOS order: ObjFlipLink from the trigger — which toggles the
			# trigger itself as well — then `state &= 0xFE`.
			_flip_link(e)
			if chain_trigger:
				_clear_enable(e)
		elif not inside and latched:
			_prox_latched[e.file_off] = false
	_use_edge = false
	_edge_done.clear()
	# (Sound one-shots, voice lines, hints and objectives fire from their
	# Behaviour nodes as the chain is flipped — F2.)
	# Destructibles a CHAIN switched on (0x18/0x19). Normally these only
	# break under fire, but a machine can break one for you: on MAP.248 a
	# START BOX (0xEF) runs a sound node into the IBEM64 girder (a 0x73
	# slide) and on into 248WALL — the ram that punches the hole you walk
	# through. Nothing in the map data starts a destructible enabled, so
	# bit 0 here always means "a chain just fired me".
	for e in _destruct_nodes:
		if not _fires(e):
			continue
		_clear_enable(e)
		_break_down(e)
	# Demolition (0x1B, handler 0x1378bf): a chain that enables one of
	# these deals it HP + 1 through ObjHit. The crate stack on MAP.213
	# comes down with the crate you shot, the desk takes the PC on it,
	# the NODE00 gate on MAP.280 drops the fence ring.
	for e in _demolish_nodes:
		if not _fires(e):
			continue
		_clear_enable(e)
		_demolish(e)
	# Countdown relays (0x2C): MAP.232's 232MAIN waits for the ninth
	# console — the counter is then 1 — and sets off the robots, the
	# stuck door and the voice line.
	for e in _relays:
		if (e.state_byte & 1) == 0:
			continue
		if objectives_left > 0 and objectives_left == RELAY_AT:
			print("[action] relay @%05x fires (%d objective left)" % [e.file_off, objectives_left])
			_say(e.file_off, "relay", "relay", {"at": RELAY_AT, "left": objectives_left})
			_flip_link(e)
			_clear_enable(e)
	# Spawn points (0xF3): the chain enables the sprite, its robot
	# appears, the sprite's bit goes down.
	for off in _spawns:
		var e: MapFile.Entity = _map.entities_by_off.get(off)
		if e == null or not _fires(e):
			continue
		_clear_enable(e)
		_spawn_in(off)
	# Vehicles on a marker path (AI state 11) ----------------------
	for off in _path_vehicles:
		_step_path_vehicle(_path_vehicles[off], delta, here)
	# Water level (0xd6-0xda) -------------------------------------
	for e in _water_nodes:
		if not _fires(e):
			continue
		_clear_enable(e)
		var cfg: Array = WATER_ACTS[e.link_act_type]
		var delta_u: int = int(cfg[0])
		var partner: int = int(cfg[1])
		if partner != 0:
			e.link_act_type = partner        # next time it goes the other way
		var target: float = -float(delta_u)
		if delta_u == 0:
			# zone-local ↔ world: an absolute surface height, and what it
			# sets is compared with world positions.
			target = -float(e.y) + zone_origin.y
			water_level_requested.emit(target, true)
		else:
			water_level_requested.emit(target, false)
		print("[action] water act @%05x (DOS delta %d)" % [e.file_off, delta_u])
		_say(e.file_off, "water", "water",
			{"delta": delta_u, "absolute": delta_u == 0, "target": target})
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
			e.state_byte |= 1
		if _armed.has(e.file_off):
			e.state_byte |= 1
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
	for gi in _prox.size():
		var g: MapFile.Entity = _prox[gi]
		if g.link_act_type != ACT_PROX_GATE or _spent.has(g.file_off):
			continue
		var gpos: Vector3 = _prox_pos[gi]
		# Distance and nothing else, as the handler does it: the 0xEF
		# handler casts no ray, and the key's own sweep in tick() casts
		# none either. A ray here refused MAP.241's doorway gate from 38
		# units away, where the map's own geometry stands between the
		# sprite and the floor the player is on.
		if not _within(gpos, from_eye, _prox_radius(g)):
			continue
		var t: MapFile.Entity = _chain_teleport(g)
		if t != null:
			return _use_exit(g, t)
	for ti in _teleports.size():
		var e: MapFile.Entity = _teleports[ti]
		if (e.state_byte & 1) == 0:
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

## Use key with nothing activatable under the crosshair: operate the
## nearest WALL BUTTON the player stands at (is_wall_button — the one
## invented rule the owner kept, 2026-09-15). Those are the records tick()
## takes off the proximity sweep, so this and the crosshair ray are the
## only ways they run at all.
##
## Nothing else is reached from here any more. Until 2026-09-16 this swept
## every variant-1 proximity record and every unchained cue within 130
## units of the FEET — a hand reach the port invented, three times the
## radius of the handler it was standing in for. So the key opened a gate
## from well outside the 60 units DOS measures, which is most of what the
## step-4 verifier called port_use_reach (157 of its failures). A gate is
## the key's, but on the handler's own terms: press_use sets the edge and
## tick() fires every gate within its radius OF THE EYE.
##
## Measured as the record's own handler measures it: 3D, from the eye, at
## the radius the slot carries (_prox_radius — 60 + the port's 26-unit
## capsule pad for an 0xEF, the +4 word for an 0xF1/0xF2).
##
## zone-local ↔ world: both arrive as WORLD positions and are taken into
## the records' zone-local space here; the world position goes on
## unchanged to on_player_activate.
func use_nearby(player_pos: Vector3, eye: Vector3 = Vector3.INF) -> bool:
	var here: Vector3 = player_pos - zone_origin
	var from_eye: Vector3 = (eye - zone_origin) if eye.is_finite() else here
	var best: MapFile.Entity = null
	var best_d: float = INF
	for pi in _prox.size():
		var e: MapFile.Entity = _prox[pi]
		if _spent.has(e.file_off) or not is_wall_button(e):
			continue
		var epos: Vector3 = _prox_pos[pi]
		var d: float = epos.distance_to(from_eye)
		if d > _prox_radius(e) or d >= best_d:
			continue
		best_d = d
		best = e
	if best == null:
		return false
	return on_player_activate(best.file_off, player_pos, eye)

## Called right after the player is placed: latch every gate and doorway
## the spawn point already lies inside, so a return exit that drops the
## player beside the gate it came through (MAP.210 marker 27 is 64 units
## from the bunker gate; MAP.211's start sits inside its DOOR gate) waits
## for the player to step out and back in instead of bouncing straight
## back. The triggers measure from `eye_pos` as tick() does (default: the
## body position), the doorways from the body.
##
## zone-local ↔ world: both arrive as WORLD positions and are taken into
## the records' zone-local space here.
func arm_proximity(player_pos: Vector3, eye_pos: Vector3 = Vector3.INF) -> void:
	var here: Vector3 = player_pos - zone_origin
	var eye: Vector3 = here if eye_pos == Vector3.INF else eye_pos - zone_origin
	for pi in _prox.size():
		var e: MapFile.Entity = _prox[pi]
		if _within(_prox_pos[pi], eye, _prox_radius(e)):
			_prox_latched[e.file_off] = true
	for ti in _teleports.size():
		var e: MapFile.Entity = _teleports[ti]
		if _within_touch(_teleport_pos[ti], here, TELEPORT_TOUCH_RADIUS):
			_touch_latched[e.file_off] = true

func _prox_radius(e: MapFile.Entity) -> float:
	if e.link_act_type == ACT_PROX_CHAIN_A:
		return 256.0
	if e.link_act_type == ACT_PROX_CHAIN_B:
		return 1024.0
	return PROX_GATE_RADIUS + PLAYER_RADIUS

## Horizontal distance test with a vertical window.
## Enabled now, or enabled at any point earlier in this tick (see
## `_armed`) — the test the one-shot sweeps use.
func _fires(e: MapFile.Entity) -> bool:
	return (e.state_byte & 1) != 0 or _armed.has(e.file_off)

## Switch an entity's enable bit off in the record AND on its Behaviour
## node: the chain walk reads the record, the cue nodes their own copy.
## (Clearing the record alone left the node at 1, so the next flip of a
## door that had run its course took it 1 → 0 and it never moved again —
## MAP.210's gate could open but never close.)
func _clear_enable(e: MapFile.Entity) -> void:
	e.state_byte &= ~1
	if behaviour != null:
		var n: Node = behaviour.node(e.file_off)
		if n != null:
			behaviour.set_state(n, e.state_byte)

## An 0xF3 spawn point's robot, built hidden by the level loader
## (SpawnEnemiesInit — at most 50 a map).
func register_spawn(off: int, node: Node) -> void:
	_spawns[off] = node

## A vehicle actor that drives its marker path: `path_head` is the first
## marker (the actor marker's own link).
func register_path_vehicle(off: int, node: Node3D, path_head: int) -> void:
	var e: MapFile.Entity = _map.entities_by_off.get(off) if _map != null else null
	_path_vehicles[off] = {
		"node": node, "head": path_head, "tgt": 0, "tspd": 0.0, "spd": 0.0,
		"off": off, "vehicle": e.enemy_type if e != null else -1,
	}

static func _dos_pos(e: MapFile.Entity) -> Vector3:
	return Vector3(float(e.x), -float(e.y), -float(e.z))

## Handler 0x127400, one frame: pick up the path, run at the segment's
## own speed, and at the end of it flip whatever the last marker points
## at (the HK's CHUNK3 carries mission 3's [M2]). The vehicle walks a
## straight 3D line from marker to marker — no terrain, no collision.
##
## zone-local ↔ world: `player_pos` is ZONE-LOCAL (tick translated it),
## like the actor's own position and the markers it drives to.
func _step_path_vehicle(v: Dictionary, delta: float, player_pos: Vector3) -> void:
	var node: Node3D = v["node"]
	if node == null or not is_instance_valid(node):
		return
	if node.has_method("is_dead") and node.is_dead():
		return
	# The actors hang under the level's Enemies node, whose only transform
	# is the zone origin, so their local position IS the zone-local one
	# the markers are in — and it still reads correctly outside the tree
	# (the smoke tests).
	if absi(floori(node.position.x / PATH_TICK_CELL) - floori(player_pos.x / PATH_TICK_CELL)) > PATH_TICK_CELLS \
			or absi(floori(node.position.z / PATH_TICK_CELL) - floori(player_pos.z / PATH_TICK_CELL)) > PATH_TICK_CELLS:
		return                                   # outside the DOS 5×5 window
	var cur: MapFile.Entity = _map.entities_by_off.get(int(v["tgt"]))
	if cur == null:
		cur = _map.entities_by_off.get(int(v["head"]))
		if cur == null:
			return
		v["tgt"] = cur.file_off
		v["spd"] = 0.0
		v["tspd"] = PATH_SPEED_K * node.position.distance_to(_dos_pos(cur))
		# The vehicle has picked its path up — what the graph calls
		# path@<the vehicle's own marker> (M3 step 3).
		_say(int(v["off"]), "marker", "path",
			{"head": int(v["head"]), "vehicle": int(v.get("vehicle", -1))})
	elif (cur.state_byte & 1) == 0:
		# The path is off (nobody has thrown the lever): brake, and clear
		# the bit down the whole chain, as the DOS stop case does.
		v["tspd"] = 0.0
		_path_disable(int(v["head"]))
	elif node.position.distance_to(_dos_pos(cur)) <= PATH_REACH:
		var nxt: MapFile.Entity = _map.entities_by_off.get(cur.link_next) \
			if cur.link_next > 0 else null
		if nxt == null:
			v["tspd"] = 0.0
			_path_disable(int(v["head"]))
		elif (nxt.flags & 3) == 3 and nxt.marker_type >= 0 and (nxt.state_byte & 1) != 0:
			if nxt.marker_type == MARKER_PATH_LOOP:
				nxt = _map.entities_by_off.get(int(v["head"]))
			if nxt != null:
				v["tspd"] = PATH_SPEED_K * _dos_pos(cur).distance_to(_dos_pos(nxt))
				v["tgt"] = nxt.file_off
				cur = nxt
		else:
			# The path ends on something that is not a marker: fire it
			# once, cut the link and coast to a stop.
			print("[action] path vehicle at @%05x fires the end of its path @%05x"
				% [cur.file_off, nxt.file_off])
			_flip_link(nxt)
			cur.link_next = 0
			v["tspd"] = 0.0
			return
	var to: Vector3 = _dos_pos(cur) - node.position
	if to.length() > 0.001:
		if float(v["tspd"]) > 0.0:
			var want: float = atan2(-to.x, -to.z)
			var turn: float = wrapf(want - node.rotation.y, -PI, PI)
			node.rotation.y += clampf(turn, -PATH_TURN * delta, PATH_TURN * delta)
		node.position += to.normalized() * (float(v["spd"]) * delta)
	var dv: float = float(v["tspd"]) - float(v["spd"])
	v["spd"] = float(v["spd"]) + clampf(signf(dv) * PATH_ACCEL * delta, -absf(dv), absf(dv))

## The stop case calls ObjFlipLink with "and 0xFE": the whole path goes
## off, so a lever has to switch it on again before the vehicle moves.
func _path_disable(head: int) -> void:
	var cur: MapFile.Entity = _map.entities_by_off.get(head)
	var hops: int = 0
	while cur != null and hops < 64:
		if (cur.state_byte & 1) != 0:
			_clear_enable(cur)
		if (cur.flags & 0x40) != 0 or cur.link_next < 1:
			return
		cur = _map.entities_by_off.get(cur.link_next)
		hops += 1

func _spawn_in(off: int) -> void:
	_spawned[off] = true
	var e: MapFile.Entity = _map.entities_by_off.get(off) if _map != null else null
	_say(off, "spawn", "spawn", {"type": (e.exit_map & 0xFFFF) if e != null else -1})
	var n = _spawns.get(off)
	if n != null and is_instance_valid(n) and n.has_method("spawn_in"):
		print("[action] spawn @%05x: %s appears" % [off, n.name])
		n.spawn_in()

## DOS measures the TRUE 3D distance (FUN_0014d775) from the eye in the
## 0xEF, 0xF1 and 0xF2 handlers (see tick). The port measured it
## horizontally with a ±512 vertical window, so the ring of gates round
## the jeep on MAP.250 fired
## mission 5's [M1] from 143 units under the quay — the mission ended in
## the water and the flooded sewers (MAP.254) could be skipped entirely.
static func _within(epos: Vector3, player_pos: Vector3, radius: float) -> bool:
	return epos.distance_to(player_pos) <= radius

## The port's own test for STANDING IN a doorway (the 0xF0 exits): the
## 3D rule above belongs to the DOS proximity handlers, whose radii come
## from the game data. A doorway sprite hangs above the floor the player
## walks on, so measuring it in 3D put the truck on MAP.210 out of reach
## — horizontal distance with a vertical window, as before.
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
	var states: Dictionary = {}
	# Act bytes and links play has changed ("acts" / "links", 2026-09-14;
	# a snapshot without them restores as before). They belong to this map
	# number only: main.gd never carries them to a variant map.
	var acts: Dictionary = {}
	var links: Dictionary = {}
	if _map != null:
		for e in _map.entities:
			states[e.file_off] = e.state_byte
			if e.link_act_type != int(_parsed_act.get(e.file_off, e.link_act_type)):
				acts[e.file_off] = e.link_act_type
			if e.link_next != int(_parsed_link.get(e.file_off, e.link_next)):
				links[e.file_off] = e.link_next
	var movers: Dictionary = {}
	for off in _movers:
		var m: Dictionary = _movers[off]
		movers[off] = [m["progress"], m["dir"]]
	var destr: Dictionary = {}
	for off in _destr:
		var d: Dictionary = _destr[off]
		destr[off] = [d["stage"], d["accum"]]
	return {
		"states": states, "movers": movers, "destr": destr,
		"hp": _hp.duplicate(), "spent": _spent.duplicate(),
		"spawned": _spawned.duplicate(),
		"acts": acts, "links": links,
	}

## Re-apply a save_state() snapshot. Call after every node is registered
## (register_node / register_destructible) so the visuals refresh too —
## and before the Behaviour branch enters the tree (main.gd), whose _ready
## fires the cues the records say are armed.
func restore_state(snap: Dictionary) -> void:
	if _map == null or snap.is_empty():
		return
	var states: Dictionary = snap.get("states", {})
	for off in states:
		var e: MapFile.Entity = _map.entities_by_off.get(off)
		if e != null:
			e.state_byte = int(states[off])
	# A cue that fired is retired (0xFF) and a water valve remembers which
	# way it goes next; sync_from_records reads the retirement onto the
	# cue nodes, or an objective would count again on the next flip.
	var acts: Dictionary = snap.get("acts", {})
	for off in acts:
		var e: MapFile.Entity = _map.entities_by_off.get(off)
		if e != null:
			e.link_act_type = int(acts[off])
	var links: Dictionary = snap.get("links", {})
	for off in links:
		var e: MapFile.Entity = _map.entities_by_off.get(off)
		if e != null:
			e.link_next = int(links[off])
	if behaviour != null:
		behaviour.sync_from_records()
	_hp = (snap.get("hp", {}) as Dictionary).duplicate()
	_spent = (snap.get("spent", {}) as Dictionary).duplicate()
	# A plain HP object that was destroyed left the world (_destroy: mesh
	# and collision gone, as DOS unlinks it). The overlay brought its
	# `spent` back but left it standing, inert. Staged wrecks keep their
	# last mesh (below).
	for off in _spent:
		if _destr.has(off):
			continue
		var gone = _nodes.get(off)
		if gone != null and is_instance_valid(gone):
			(gone as Node3D).visible = false
			_disable_collision(gone)
	# Robots an 0xF3 chain already let out come back out (the dead ones
	# the map overlay removes on its own). They were counted for the
	# STATISTICS page when they first appeared.
	Stats.hold_enemy_count = true
	for off in (snap.get("spawned", {}) as Dictionary):
		_spawn_in(int(off))
	Stats.hold_enemy_count = false
	var movers: Dictionary = snap.get("movers", {})
	for off in movers:
		if not _movers.has(off):
			continue
		var m: Dictionary = _movers[off]
		m["progress"] = float(movers[off][0])
		m["dir"] = float(movers[off][1])
		var mnode: Node3D = _nodes.get(off)
		if mnode != null and is_instance_valid(mnode):
			_apply_mover_transform(mnode, m)
	var destr: Dictionary = snap.get("destr", {})
	for off in destr:
		if not _destr.has(off):
			continue
		var d: Dictionary = _destr[off]
		d["stage"] = int(destr[off][0])
		d["accum"] = float(destr[off][1])
		var node: Node3D = _nodes.get(off)
		if node == null or not is_instance_valid(node):
			continue
		var meshes: Array = d["meshes"]
		if meshes.size() > 1:
			if node is MeshInstance3D and d["stage"] < meshes.size() \
					and meshes[d["stage"]] != null:
				(node as MeshInstance3D).mesh = meshes[d["stage"]]
		elif _spent.has(off):
			node.visible = false
			_disable_collision(node)

## Advance one mover while its enable bit is set. On reaching either
## end of its travel the DOS handler clears the enable bit and flips
## the stored direction — the next chain flip runs it back.
func _step_mover(off: int, e: MapFile.Entity, delta: float) -> void:
	var m: Dictionary = _movers[off]
	var node: Node3D = _nodes.get(off)
	if node == null or not is_instance_valid(node):
		return
	var fam: String = m["family"]
	if fam == "rot" and m["limit"] == 0.0:
		# Continuous rotator — never stops while enabled. Only the acts
		# whose handler carries NO angle spin like this: the radar DISH
		# (0x3b), the GLOBE, MAP.232's sky dome.
		if not bool(m.get("running", false)):
			m["running"] = true
			_say(off, "mover", "spin", {"family": fam,
				"axis": int(m["axis"]), "speed": ROT_SPEED})
		m["progress"] = fmod(m["progress"] + ROT_SPEED * delta, 2048.0)
		_apply_mover_transform(node, m)
		return
	var limit: float = m["limit"]
	if fam == "slide5f":
		limit = float(int(m["limit"]) << 4)      # p6<<4 travel distance
	if limit == 0.0:
		# A ZERO SLIDE (0xbd-0xc0). Its slot's limit word is 0, so the
		# handler's `cmp ax, word [ecx+6] / jl` — a signed compare of a
		# non-negative step against zero — can never take the "still
		# travelling" branch: it falls straight into the arrived path on the
		# first tick (v1.01 0x138392/0x13842d, disassembled 2026-09-16),
		# where it zeroes the step, CLEARS ITS OWN ENABLE BIT, flips the act
		# parity and calls ObjSetPos with the position unchanged. The port
		# used to return here before any of that, so the node stayed enabled
		# for ever and its chain bit never came back down.
		_say(off, "mover", "move", {"family": fam, "axis": int(m["axis"]),
			"travel": _mover_travel(m, m["progress"]), "speed": 0.0})
		_clear_enable(e)
		m["dir"] = -float(m["dir"])
		return
	var span: float = absf(limit)
	var speed: float
	match fam:
		"slide":
			speed = SLIDE_SPEED_FAST if span >= 2048.0 else SLIDE_SPEED_SLOW
		"slide5f":
			speed = float(m["p4"]) * SLIDE_SPEED_SCALE
		"jump":
			speed = 1.0e9                        # instant (0x137ad0)
		_:
			speed = SWING_SPEED
	var target: float = span if m["dir"] > 0.0 else 0.0
	var p: float = move_toward(m["progress"], target, speed * delta)
	if m["progress"] == 0.0 or m["progress"] == span:
		print("[action] mover @%05x %s %s starts (%s, span %.0f)" % [off, node.name, fam,
			"forward" if m["dir"] > 0.0 else "back", span])
	if not bool(m.get("running", false)):
		# Announced at the START of the run, with the travel the run will
		# make: the DOS handler self-disables on arrival and the graph's
		# simulation settles it the same way, so the two are talking about
		# one and the same movement — here, the moment it begins (step 3).
		m["running"] = true
		_say(off, "mover", "move", {"family": fam, "axis": int(m["axis"]),
			"travel": _mover_travel(m, target), "speed": speed})
	m["progress"] = p
	_apply_mover_transform(node, m)
	if p == target:
		_clear_enable(e)                       # arrived: self-disable
		m["dir"] = -m["dir"]                     # next activation reverses
		m["running"] = false

## How far this run carries the mover from where it stands, signed, in
## the units its family works in — the same number the graph's
## simulation writes as move@<id>:<family><axis><travel>
## (trigger_graph._settle). From either end of the travel that is the
## whole span; a mover a chain switched off half way and switched on
## again makes only the rest of it, and says so.
static func _mover_travel(m: Dictionary, target: float) -> float:
	var sign: float = float(m.get("sign", 1.0))
	var fam: String = String(m["family"])
	if fam != "rot" and fam != "slide" and float(m["limit"]) < 0.0:
		sign = -sign
	return (target - float(m["progress"])) * sign

## DOS axis p4 (0=X, 1=Y-down, 2=Z) → Godot world direction.
static func dos_axis(axis_i: int) -> Vector3:
	if axis_i == 1:
		return Vector3.DOWN
	if axis_i == 2:
		return Vector3(0.0, 0.0, -1.0)
	return Vector3.RIGHT

func _apply_mover_transform(node: Node3D, m: Dictionary) -> void:
	var base: Transform3D = m["base"]
	var fam: String = m["family"]
	var sign: float = float(m.get("sign", 1.0))
	if fam != "rot" and fam != "slide" and m["limit"] < 0.0:
		sign = -sign
	if fam == "slide5f":
		# DOS adds to entity+0xc (Y, Y-down) → Godot -Y (slides down).
		node.transform = base.translated_local(
			Vector3(0.0, -m["progress"] * sign, 0.0))
		return
	if fam == "slide" or fam == "jump":
		# Translate along the DOS world axis (handlers 0x137a28/0x137ad0
		# add to the entity position, not to a local frame).
		node.transform = Transform3D(base.basis,
			base.origin + dos_axis(int(m["axis"])) * (m["progress"] * sign))
		return
	# Swing/rot: advance one Euler component of the entity (see
	# swing_basis) — the base basis IS euler_basis(euler) at progress 0.
	var euler: Vector3 = m.get("euler", Vector3.ZERO)
	node.transform = Transform3D(
		swing_basis(euler, int(m["axis"]), m["progress"] * sign), base.origin)
	# The AnimatableBody3D child follows through the global-transform
	# notification (main.gd _make_animatable keeps sync_to_physics off).

## Destructible damage-stage advance (handler 0x120433): the damage
## counter steps one TRANSFRM.PRS stage per DESTRUCT_DAMAGE_PER_STAGE
## points; past the last stage the object is a spent wreck (or, with no
## stage meshes, vanishes).
func _advance_destructible(e: MapFile.Entity, damage: float) -> bool:
	var d: Dictionary = _destr[e.file_off]
	var meshes: Array = d["meshes"]
	if d["stage"] >= meshes.size() - 1 and (meshes.size() > 1 or _spent.has(e.file_off)):
		return false                          # final wreck / already gone
	d["accum"] += damage
	var want: int = int(d["accum"] / DESTRUCT_DAMAGE_PER_STAGE)
	var node: Node3D = _nodes.get(e.file_off)
	if meshes.size() > 1:
		var new_stage: int = mini(want, meshes.size() - 1)
		if new_stage != d["stage"]:
			d["stage"] = new_stage
			# One announcement per stage that actually happens, wherever the
			# damage came from — gunfire as well as a chain (M3 step 3; the
			# call used to sit in _break_down alone, so a prop shot to pieces
			# went past the bus in silence).
			_say(e.file_off, "destructible", "destruct",
				{"stage": new_stage, "stages": meshes.size()})
			if node != null and is_instance_valid(node) \
					and node is MeshInstance3D and meshes[new_stage] != null:
				(node as MeshInstance3D).mesh = meshes[new_stage]
				_blast(node, new_stage == meshes.size() - 1, absi(e.destroy_param))
			if new_stage == meshes.size() - 1:
				_spent[e.file_off] = true
	elif want >= 1:
		# No stage meshes — vanish (rubble piles etc.).
		_spent[e.file_off] = true
		_say(e.file_off, "destructible", "destruct", {"stage": 1, "stages": 1})
		if node != null and is_instance_valid(node):
			_blast(node, true, absi(e.destroy_param))
			node.visible = false
			_disable_collision(node)
	return true

## Handler 0x1378bf (act 0x1B): a killing blow through ObjHit — HP + 1,
## after an HP of 0 is raised to 1 so a prop with no hit points goes
## too. Everything else (blast, drop, sound, the chain if the state
## bits ask for it) is the ordinary destruction path.
func _demolish(e: MapFile.Entity) -> void:
	if _spent.has(e.file_off) or (e.flags & 3) != 1:
		return
	if not _hp.has(e.file_off) or float(_hp[e.file_off]) <= 0.0:
		_hp[e.file_off] = 1.0
	print("[action] demolish @%05x (act 0x1b, hp %.0f)" % [e.file_off, float(_hp[e.file_off])])
	_say(e.file_off, "demolish", "demolish", {"hp": float(_hp[e.file_off])})
	on_player_hit(e.file_off, float(_hp[e.file_off]) + 1.0)

## Run a destructible through every one of its TRANSFRM.PRS stages at
## once — what a machine (or a scripted demolition) does to it, as
## opposed to the slow chipping away of gunfire.
func _break_down(e: MapFile.Entity) -> void:
	if not _destr.has(e.file_off):
		return
	# One stage per blow: MAP.248's girder has to ram 248WALL several
	# times before it gives (the DOS run, 2026-09-11) — each press of
	# the START BOX swings the girder and enables the wall once. Until then
	# the port ran every stage at the first enable and the wall fell at
	# the first touch.
	print("[action] destructible @%05x struck by a chain" % e.file_off)
	var was_spent: bool = _spent.has(e.file_off)
	# (The stage itself is announced by _advance_destructible, which every
	# way of damaging the thing goes through.)
	_advance_destructible(e, DESTRUCT_DAMAGE_PER_STAGE)
	if was_spent or not _spent.has(e.file_off):
		return                                   # still standing, or long gone
	_hp[e.file_off] = 0.0
	_destroy(e)
	var node: Node3D = _nodes.get(e.file_off)
	if node != null and is_instance_valid(node):
		_disable_collision(node)

## DOS FUN_00124293 — HP gone. The link record's byte 0 picks the
## destruction type (Skynet.exe 0x423d6): effect sprites scattered
## within `spread`, a random drop from the type's list (crates → ammo,
## lockers → medkits) and a sound (-2 = one of 33..36); type 0 is a
## plain blast (effect 358) sized by the i16 parameter, no drop. Staged
## destructibles (0x18/0x19 wrecks) keep their final mesh; everything
## else leaves the world.
##
## zone-local ↔ world: the record's own position is zone-local and the
## node's global transform is already world; both are carried as WORLD
## here, because the audio, the effects and the blast all live there.
func _destroy(e: MapFile.Entity) -> void:
	var node: Node3D = _nodes.get(e.file_off)
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
					at += Vector3(randf_range(-0.5, 0.5) * spread, 0.0, randf_range(-0.5, 0.5) * spread)
				Explosion.spawn(scene, at, radius * 1.6, int(s) >> 7)
				k += 1
		_radial_blast(node, centre, absi(e.destroy_param))
	# Gone from the world, whether or not it was in a tree to blow up in.
	if alive and not _destr.has(e.file_off):
		node.visible = false
		_disable_collision(node)
	if drop >= 0:
		# zone-local ↔ world: the drop becomes a child of level.sprites and
		# is put on the map's own heightmap (LevelLoader.spawn_item), so it
		# is asked for in ZONE-LOCAL coordinates.
		drop_requested.emit(
			Vector3(centre.x, origin.y, centre.z) - zone_origin, drop)

## Explosion at a destructible's centre; the final stage also throws the
## object's own blast (`strength`, the i16 at its link record +1 — the
## cars of MAP.210 carry 200-300, the gas tanker 600, a crate nothing).
func _blast(node: Node3D, final: bool, strength: int = 0) -> void:
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
		_radial_blast(node, centre, strength)

## A dying object's blast, the DOS radial one (FUN_00124386 through
## Projectile.dos_blast): `s` points at the centre + 40, nothing past half
## of it — on the player (from his DOS point, with line of sight), on the
## robots (ObjHit) and on the other destructibles in reach, which is how a
## row of cars goes up one after another. Until 2026-09-15 the port dealt
## a flat 450 points to the player from every wreck, crates included.
func _radial_blast(source: Node3D, centre: Vector3, s: int) -> void:
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
			var bh: float = Projectile.dos_blast(float(s), (h as Node3D).global_position.distance_to(centre))
			if bh > 0.0:
				h.call_deferred("take_damage", bh)

static func _disable_collision(node: Node3D) -> void:
	for c in node.get_children():
		if c is CollisionObject3D:
			for s in c.get_children():
				if s is CollisionShape3D:
					s.disabled = true
