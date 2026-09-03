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
##   0xEF                 — proximity gate, 60-unit radius (0x137e2e).
##   0xF1/0xF2            — proximity-gated chain trigger (0x1379c4).
##   0xF0                 — interior teleport (0x137881): target map at
##                          sub+2, spawn-marker set at sub+4; one-shot.
##
## Runtime state (mutated state bytes, mover progress, damage stages)
## lives on/next to the parsed MapFile — reloading a map re-parses it,
## which matches DOS (maps are always reloaded from disk; the Mst
## state overlay arrives with map transitions in phase 2).

extends RefCounted

const Explosion := preload("res://scripts/explosion.gd")

signal teleport_requested(target_map: int, marker_set: int)
## A destroyed object drops an item (FUN_00124293 → FUN_00124119).
signal drop_requested(pos: Vector3, drop_type: int)
## A MISSION OBJECTIVE act (0x26..0x2A) fired; index = act - 0x26, which
## selects the [M1]..[M5] line of the mission's briefing script. The DOS
## engine (handler 0x1377d0) decrements the "objectives remaining"
## counter here, prints that line, and disables the node.
signal objective_complete(index: int)
## A hint act (0x1C..0x25) fired; index = act - 0x1C → [G1]..[G9].
## Handler 0x13779d: prints the line, changes no counter.
signal hint_message(index: int)
## Act 0x2B (handler 0x13782d): the mission is lost, at once.
signal mission_failed()

const MapFile := preload("res://scripts/loaders/map_file.gd")
const PickupData := preload("res://scripts/pickup_data.gd")

## Mover ids → [family, p4, p6] from the 0x59b00 table's per-slot
## config dword (+4 low u16, +6 high u16). Families by handler body
## (disassembled 2026-08-30 with tools/x86dis.py):
##   "slide"   0x137a28 (0x3f-0x7e): translate along DOS axis p4 (0=X,
##             1=Y, 2=Z) by p6 units at 70 u/s (140 when p6 >= 0x800);
##             the act parity flips at the limit → next trigger reverses.
##             BIGDOOR 0x41/0x42 = the two gate leaves sliding apart.
##   "swing"   0x137c6b (0x8d-92, 0xa5-ac, 0xc1-c6): rotate about axis
##             p4 by p6 11-bit units at 512/s (90°/s). 210DOOR0/1.
##   "jump"    0x137ad0 (0x30-35): instant translate by SIGNED p6.
##   "slide5f" 0x137d41: p4 speed base, p6<<4 travel (as before).
##   "rot"     continuous rotators (never stop).
## The odd 0xbd..0xc0 pair (0x137b33) is untraced — treated as swings.
const MOVER_TABLE: Dictionary = {
	0x30: ["jump", 0, 512], 0x31: ["jump", 0, 65024],
	0x32: ["jump", 1, 512], 0x33: ["jump", 1, 65024],
	0x34: ["jump", 2, 512], 0x35: ["jump", 2, 65024],
	0x36: ["rot", 0, 1024], 0x37: ["rot", 1, 1024], 0x38: ["rot", 2, 1024],
	0x39: ["rot", 0, 0], 0x3a: ["rot", 0, 0], 0x3b: ["rot", 1, 0],
	0x3c: ["rot", 1, 0], 0x3d: ["rot", 2, 0], 0x3e: ["rot", 2, 0],
	0x3f: ["slide", 0, 64], 0x40: ["slide", 0, 64], 0x41: ["slide", 0, 128],
	0x42: ["slide", 0, 128], 0x43: ["slide", 0, 256], 0x44: ["slide", 0, 256],
	0x45: ["slide", 0, 512], 0x46: ["slide", 0, 512], 0x59: ["slide", 1, 64],
	0x5a: ["slide", 1, 64], 0x5b: ["slide", 1, 128], 0x5c: ["slide", 1, 128],
	0x5d: ["slide", 1, 256], 0x5e: ["slide", 1, 256],
	0x5f: ["slide5f", 316, 128], 0x61: ["slide", 1, 512],
	0x62: ["slide", 1, 512], 0x63: ["slide", 1, 2048],
	0x64: ["slide", 1, 2048], 0x65: ["slide", 1, 2560],
	0x66: ["slide", 1, 2560], 0x67: ["slide", 1, 24], 0x68: ["slide", 1, 24],
	0x69: ["slide", 1, 768], 0x6a: ["slide", 1, 768], 0x6b: ["slide", 1, 480],
	0x6c: ["slide", 1, 480], 0x6d: ["slide", 1, 378], 0x6e: ["slide", 1, 378],
	0x6f: ["slide", 1, 1024], 0x70: ["slide", 1, 1024],
	0x71: ["slide", 1, 1520], 0x72: ["slide", 1, 1520],
	0x73: ["slide", 2, 64], 0x74: ["slide", 2, 64], 0x75: ["slide", 2, 128],
	0x76: ["slide", 2, 128], 0x77: ["slide", 2, 256], 0x78: ["slide", 2, 256],
	0x79: ["slide", 2, 512], 0x7a: ["slide", 2, 512], 0x7b: ["slide", 2, 640],
	0x7c: ["slide", 2, 640], 0x7d: ["slide", 2, 384], 0x7e: ["slide", 2, 384],
	0x8d: ["swing", 0, 256], 0x8e: ["swing", 0, 256], 0x8f: ["swing", 0, 512],
	0x90: ["swing", 0, 512], 0x91: ["swing", 0, 1024],
	0x92: ["swing", 0, 1024], 0xa5: ["swing", 1, 688],
	0xa6: ["swing", 1, 688], 0xa7: ["swing", 1, 256], 0xa8: ["swing", 1, 256],
	0xa9: ["swing", 1, 512], 0xaa: ["swing", 1, 512],
	0xab: ["swing", 1, 1024], 0xac: ["swing", 1, 1024],
	0xbd: ["swing", 1, 512], 0xbe: ["swing", 1, 512],
	0xbf: ["swing", 1, 512], 0xc0: ["swing", 1, 512],
	0xc1: ["swing", 2, 256], 0xc2: ["swing", 2, 256],
	0xc3: ["swing", 2, 512], 0xc4: ["swing", 2, 512],
	0xc5: ["swing", 2, 1024], 0xc6: ["swing", 2, 1024],
}

const ACT_DESTRUCT_A: int = 0x18
const ACT_DESTRUCT_B: int = 0x19
const ACT_PROX_GATE: int = 0xEF     # 60-unit player-proximity gate
const ACT_PROX_CHAIN_A: int = 0xF1  # radius 256 (table +4)
const ACT_PROX_CHAIN_B: int = 0xF2  # radius 1024 (table +4)
const ACT_TELEPORT: int = 0xF0
const ACT_VOICE: int = 0xED         # voice line (VOICE.PRS id at sub+2, 0x137dfd)
## Message / mission-progress acts, split exactly as the DOS handler
## table does (0x59b00). Only the OBJECTIVE band moves the counter that
## ends a mission — treating the hints as objectives (the port did until
## 2026-09-03) makes missions end at the first flavour line.
const ACT_HINT_FIRST: int = 0x1C    # [G1].. handler 0x13779d, message only
const ACT_HINT_LAST: int = 0x25
const ACT_OBJECTIVE_FIRST: int = 0x26   # [M1].. handler 0x1377d0, counter--
const ACT_OBJECTIVE_LAST: int = 0x2A
const ACT_FAIL: int = 0x2B          # handler 0x13782d: MISSION FAILED now

## One-shot play-sound-and-disable nodes (handler 0x137dbd) — chains
## route through these to give doors/gates their sounds. The table's
## per-slot +4 word is the sound id (0..125, the 0x4ff00 sound table).
## The id→.RAW filename mapping is phase 4 (sound-table extraction);
## until then these nodes just self-disable so chains don't dangle.
const SOUND_ONESHOT: Dictionary = {
	0xdb: 40, 0xdc: 41, 0xdd: 42, 0xde: 43, 0xdf: 44, 0xe0: 45,
	0xe1: 46, 0xe2: 47, 0xe3: 77, 0xe4: 93, 0xe5: 95, 0xe6: 109,
	0xe7: 110, 0xe8: 111, 0xe9: 112, 0xea: 113, 0xeb: 114,
}

## Movement tuning. The DOS handlers step 0x46/0x8c angle units per
## tick (~35 Hz) through a <<4 fixed-point accumulator — ≈153/306
## units/s (27°/54° per second). Slide analogously from its p4 base.
## TODO: calibrate against DOSBox once doors are visibly moving.
const SWING_SPEED: float = 512.0         # 11-bit units/s (0x137c6b: 0x200/s)
const SLIDE_SPEED_SLOW: float = 70.0     # units/s (0x137a28: 0x46/s)
const SLIDE_SPEED_FAST: float = 140.0    # units/s when p6 >= 0x800
const ROT_SPEED: float = 153.0           # continuous rotators
const SLIDE_SPEED_SCALE: float = 2.2     # 0x5f slide speed = p4 * this (units/s)
const PROX_GATE_RADIUS: float = 60.0     # 0xEF (Skynet.exe 0x137e2e)
## Use key reach for wall buttons / levers the crosshair is not on.
const USE_REACH: float = 130.0
## The DOS 60-unit gate test is against the player's body, so the player
## capsule radius is added — MAP data places gates 32..79 units from the
## doorway sprite they guard, which a centre-point test would walk past.
const PLAYER_RADIUS: float = 26.0
## A 0xF0 doorway sprite is also armed by the player touching it directly
## (handler 0x137881: "player touch arms state bit 0"); interior return
## exits rely on this as much as on their chained 0xEF gate.
const TELEPORT_TOUCH_RADIUS: float = 90.0
## Vertical window for every proximity test — stacked interior floors put
## gates directly above/below each other.
const PROX_VERTICAL_WINDOW: float = 512.0
const DESTRUCT_DAMAGE_PER_STAGE: float = 16.0  # handler 0x120433 stage step

var _map: MapFile.MapFile = null
var _nodes: Dictionary = {}       # file_off → Node3D (visual, optional)
var _movers: Dictionary = {}      # file_off → mover runtime state
var _prox: Array = []             # entities with a proximity act type
var _teleports: Array = []        # entities with act 0xF0
var _sound_nodes: Array = []      # entities with a SOUND_ONESHOT act
var _voice_nodes: Array = []      # entities with act 0xED
var _objective_nodes: Array = []  # entities with acts 0x1C..0x2B
## Physics access for reachability tests (set by the level controller).
var space: PhysicsDirectSpaceState3D = null
var player_body: CollisionObject3D = null
var _destr: Dictionary = {}       # file_off → destructible runtime state
var _hp: Dictionary = {}          # file_off → remaining HP
var _spent: Dictionary = {}       # file_off → true (HP-depleted, inert)
var _prox_latched: Dictionary = {} # file_off → true while player inside
var _touch_latched: Dictionary = {} # teleport file_off → player touching
var _teleport_fired: bool = false   # one map change per level instance
var _unhandled_logged: Dictionary = {}

func setup(map: MapFile.MapFile) -> void:
	_map = map
	for e in map.entities:
		var act: int = e.link_act_type
		if act == ACT_PROX_GATE or act == ACT_PROX_CHAIN_A \
				or act == ACT_PROX_CHAIN_B:
			_prox.append(e)
		elif act == ACT_TELEPORT:
			_teleports.append(e)
		elif SOUND_ONESHOT.has(act):
			_sound_nodes.append(e)
		elif act == ACT_VOICE:
			_voice_nodes.append(e)
		elif act >= ACT_HINT_FIRST and act <= ACT_FAIL:
			_objective_nodes.append(e)
		if (e.flags & 3) == 1 and e.hp > 0:
			_hp[e.file_off] = float(e.hp)

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
		}

## Register the damage-stage meshes for a destructible entity (built by
## the level loader from TRANSFRM.PRS; may be empty → vanish on kill).
## Does the entity at `off` take damage (HP pool or destruction stages)?
func is_damageable_off(off: int) -> bool:
	if _spent.has(off):
		return false
	return _hp.has(off) or _destr.has(off)

## True when the entity at `off` is a mover (door/gate/lift/rotator).
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
func on_player_activate(file_off: int, player_pos: Vector3 = Vector3.INF) -> bool:
	var e: MapFile.Entity = _map.entities_by_off.get(file_off) \
		if _map != null else null
	if e == null or _spent.has(file_off):
		return false
	# Levers, buttons and proximity gates (0xEF/0xF1/0xF2) are use-key
	# operated in DOS — the tower lever opens the base gate — even
	# though their state byte carries no "act on hit" bit.
	var usable: bool = (e.state_byte & 2) != 0 		or e.link_act_type == ACT_PROX_GATE or e.link_act_type == 0xF1 		or e.link_act_type == 0xF2
	if not usable:
		return false
	# A gate whose chain ends in an exit (the truck DOOR in MAP.211/212,
	# the bunker doorway gates) is the use-key way through: arm the exit
	# if the chain has not flipped yet and go, wherever its sprite sits.
	if e.link_act_type == ACT_PROX_GATE:
		var t: MapFile.Entity = _chain_teleport(e)
		if t != null:
			return _use_exit(e, t)
	if (e.state_byte & 2) != 0:
		_trigger(e)
	else:
		_flip_link(e)
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

## Use-key on an exit gate: flip the chain once so the exit (and the
## door sound on the way) arms, then fire it.
func _use_exit(gate: MapFile.Entity, t: MapFile.Entity) -> bool:
	if _teleport_fired:
		return false
	if (t.state_byte & 1) == 0:
		_flip_link(gate)
		_prox_latched[gate.file_off] = true
	return _fire_teleport(t)

func _fire_teleport(t: MapFile.Entity) -> bool:
	if _teleport_fired or (t.state_byte & 1) == 0:
		return false
	t.state_byte &= ~1                       # one-shot (0x137881)
	_teleport_fired = true
	print("[action] teleport → map %d, marker set %d" % [t.exit_map, t.exit_marker_id])
	teleport_requested.emit(t.exit_map, t.exit_marker_id)
	return true

## ObjFlipLink + immediate ObjDoAction, DOS order: flip the chain from
## the entity, then run the entity's own action.
func _trigger(e: MapFile.Entity) -> void:
	_flip_link(e)
	_do_action(e)

## ObjFlipLink FUN_001394aa: toggle bit0 down the chain; 0xEF nodes
## force their bit0 back on; stop at an actor or end-of-chain. Chains
## in the MAP data can be RINGS (…→door0→door1→…→back to the head);
## DOS normalises them at load in MapFixLinkEnds — we instead track
## visited members so each one toggles exactly once per trigger.
func _flip_link(start: MapFile.Entity) -> void:
	var cur: MapFile.Entity = start
	var visited: Dictionary = {}
	while cur != null and not visited.has(cur.file_off):
		visited[cur.file_off] = true
		cur.state_byte ^= 1
		if cur.link_act_type == ACT_PROX_GATE:
			cur.state_byte |= 1
		_refresh_switch_visual(cur)
		if (cur.flags & 0x40) != 0:
			break
		if cur.link_next < 1:
			break
		var nxt: MapFile.Entity = _map.entities_by_off.get(cur.link_next)
		if nxt == cur:
			break
		cur = nxt

## BUTTON01/02 are a single quad with the OFF texture (222/0, 222/2) on
## the front face and the lit ON texture (222/1, 222/3) on the back —
## showing the pressed state means showing the other side. Rotate the
## panel 180 deg about its local Y while the state bit is on.
func _refresh_switch_visual(e: MapFile.Entity) -> void:
	var node: Node3D = _nodes.get(e.file_off)
	if node == null or not is_instance_valid(node):
		return
	if not String(node.get_meta("mesh_name", node.name)).begins_with("BUTTON"):
		return
	if not node.has_meta("switch_base"):
		node.set_meta("switch_base", node.transform)
	var base: Transform3D = node.get_meta("switch_base")
	if (e.state_byte & 1) != 0:
		node.transform = Transform3D(base.basis * Basis(Vector3.UP, PI), base.origin)
	else:
		node.transform = base

## ObjDoAction: dispatch when enabled. Movers/proximity/teleports are
## per-tick handlers driven from tick(); the one-shot families run here.
func _do_action(e: MapFile.Entity) -> void:
	var act: int = e.link_act_type
	if act <= 0 or act >= 0xFE:
		return
	if is_mover(act) or act == ACT_PROX_GATE \
			or act == ACT_PROX_CHAIN_A or act == ACT_PROX_CHAIN_B \
			or act == ACT_TELEPORT or is_destructible(act) \
			or (act >= ACT_HINT_FIRST and act <= ACT_FAIL) or act == ACT_VOICE:
		return                                  # handled in tick()/hit path
	if not _unhandled_logged.has(act):
		_unhandled_logged[act] = true
		print("[action] unhandled act 0x%02x (entity @%d)" % [act, e.file_off])

## Per-tick sweep — the DOS engine re-runs enabled entities' handlers
## every tick; movers advance while enabled, proximity types watch the
## player, teleports fire once when enabled.
func tick(delta: float, player_pos: Vector3) -> void:
	if _map == null:
		return
	# Movers ------------------------------------------------------
	for off in _movers:
		var e: MapFile.Entity = _map.entities_by_off.get(off)
		if e == null or (e.state_byte & 1) == 0:
			continue
		_step_mover(off, e, delta)
	# Proximity triggers ------------------------------------------
	# DOS: the 0xEF handler (0x137e2e) never looks at bit 0 — every gate
	# watches the player all the time (MAP.215's silo cover opens from a
	# CORC3229 piece whose state is 0x10). The port keeps two kinds on
	# the use key instead: 0xF1/0xF2 levers, and variant-1 meshes with
	# state bit 3 (the wall buttons, state 0x09) — walking past a button
	# must not press it.
	for e in _prox:
		# 0xEF gates and the 0xF1 / 0xF2 chain triggers all watch the
		# player (handlers 0x137e2e and 0x1379c4); the radii differ.
		# MAP.220's mission objective hangs off an 0xF2 button 1024 units
		# from the road, which is how that jeep mission ends.
		if (e.flags & 3) == 1 and (e.state_byte & 8) != 0 and e.name_index >= 0:
			continue                         # wall button: use key only
		# (An UNNAMED variant-1 gate with the same state byte is an
		# invisible floor trigger — MAP.231's elevator call points sit
		# at the back wall of the cab, state 0x09, no mesh at all.)
		if _spent.has(e.file_off):
			continue
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		var inside: bool = _within(epos, player_pos, _prox_radius(e))
		var latched: bool = _prox_latched.get(e.file_off, false)
		if inside and not latched:
			_prox_latched[e.file_off] = true
			print("[action] gate @%05x (act %02x) tripped at %s" % [e.file_off, e.link_act_type, epos])
			_flip_link(e)
		elif not inside and latched:
			_prox_latched[e.file_off] = false
	# Sound one-shots (0xdb..0xeb, handler 0x137dbd): play the slot's
	# sound id (Audio.SOUND_IDS, the 0x4ff00 table) at the node, then
	# self-disable. Door/button chains route through these for their
	# sounds; a node armed in the MAP data plays once at level start.
	for e in _sound_nodes:
		if (e.state_byte & 1) != 0:
			e.state_byte &= ~1
			Audio.play_id_3d(int(SOUND_ONESHOT.get(e.link_act_type, -1)),
				Vector3(float(e.x), -float(e.y), -float(e.z)), -4.0)
	# Voice lines (0xED, handler 0x137dfd): play the VOICE.PRS sample
	# whose id sits at sub+2, then self-disable.
	for e in _voice_nodes:
		if (e.state_byte & 1) != 0:
			e.state_byte &= ~1
			Audio.play_voice(e.exit_map)
	# Messages and mission progress (0x1C..0x2B): fire once when a
	# chain enables them, then the act disarms itself (DOS writes 0xFF
	# into the act byte). FUN_0012f53d confirms with sound 0x51.
	for e in _objective_nodes:
		if (e.state_byte & 1) == 0:
			continue
		var act: int = e.link_act_type
		if act < ACT_HINT_FIRST or act > ACT_FAIL:
			continue
		e.state_byte &= ~1
		e.link_act_type = 0xFF               # DOS writes 0xFF: one-shot
		if act == ACT_FAIL:
			mission_failed.emit()
		elif act >= ACT_OBJECTIVE_FIRST:
			Audio.play_id(0x51, -4.0)
			objective_complete.emit(act - ACT_OBJECTIVE_FIRST)
		else:
			hint_message.emit(act - ACT_HINT_FIRST)
	# Teleports ---------------------------------------------------
	# A chain (0xEF gate → sound node → 0xF0) or touching the doorway
	# sprite ARMS the exit (state bit 0); the map change itself needs
	# the use key — in DOS you walk into the truck and press use at its
	# rear doors, nothing happens just by standing there.
	for e in _teleports:
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		var touching: bool = _within(epos, player_pos, TELEPORT_TOUCH_RADIUS)
		if touching and not _touch_latched.get(e.file_off, false):
			e.state_byte |= 1
		_touch_latched[e.file_off] = touching

## Use key: fire an armed exit the player stands in. Returns true when
## a map change was requested (one per level instance).
func activate_teleport(player_pos: Vector3) -> bool:
	if _teleport_fired:
		return false
	for e in _teleports:
		if (e.state_byte & 1) == 0:
			continue
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		if not _within(epos, player_pos, TELEPORT_TOUCH_RADIUS + PROX_GATE_RADIUS):
			continue
		if not _reachable(player_pos, epos):
			continue                         # a closed door leaf is in the way
		return _fire_teleport(e)
	# Standing in an ENABLED exit gate whose chain has not flipped (the
	# spawn pre-latched it, e.g. the truck interiors start beside their
	# DOOR): the use key goes through anyway.
	for g in _prox:
		if g.link_act_type != ACT_PROX_GATE or _spent.has(g.file_off):
			continue
		var gpos := Vector3(float(g.x), -float(g.y), -float(g.z))
		if not _within(gpos, player_pos, _prox_radius(g)):
			continue
		if not _reachable(player_pos, gpos):
			continue
		var t: MapFile.Entity = _chain_teleport(g)
		if t != null:
			return _use_exit(g, t)
	return false

## Nothing solid between the player and `target` (a doorway sprite sits
## on the floor, so aim a little above it). True when no physics space
## is available (headless unit tests).
func _reachable(from: Vector3, target: Vector3) -> bool:
	if space == null:
		return true
	var to: Vector3 = target + Vector3(0.0, 40.0, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	if player_body != null:
		q.exclude = [player_body.get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.has("position"):
		return true
	return (hit["position"] as Vector3).distance_to(to) < 48.0

## Use key with nothing activatable under the crosshair: operate the
## nearest wall button / lever the player stands at. DOS fires these by
## proximity (0xEF/0xF1/0xF2); the port keeps them on the key but does
## not demand precise aim at a small panel.
func use_nearby(player_pos: Vector3) -> bool:
	var best: MapFile.Entity = null
	var best_d: float = USE_REACH
	for e in _prox:
		if (e.flags & 3) != 1 or _spent.has(e.file_off):
			continue
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		if not _within(epos, player_pos, USE_REACH):
			continue
		var d: float = epos.distance_to(player_pos)
		if d < best_d:
			best_d = d
			best = e
	if best == null:
		return false
	return on_player_activate(best.file_off, player_pos)

## Called right after the player is placed: latch every gate and doorway
## the spawn point already lies inside, so a return exit that drops the
## player beside the gate it came through (MAP.210 marker 27 is 64 units
## from the bunker gate; MAP.211's start sits inside its DOOR gate) waits
## for the player to step out and back in instead of bouncing straight
## back.
func arm_proximity(player_pos: Vector3) -> void:
	for e in _prox:
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		if _within(epos, player_pos, _prox_radius(e)):
			_prox_latched[e.file_off] = true
	for e in _teleports:
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		if _within(epos, player_pos, TELEPORT_TOUCH_RADIUS):
			_touch_latched[e.file_off] = true

func _prox_radius(e: MapFile.Entity) -> float:
	if e.link_act_type == ACT_PROX_CHAIN_A:
		return 256.0
	if e.link_act_type == ACT_PROX_CHAIN_B:
		return 1024.0
	return PROX_GATE_RADIUS + PLAYER_RADIUS

## Horizontal distance test with a vertical window.
static func _within(epos: Vector3, player_pos: Vector3, radius: float) -> bool:
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
	if _map != null:
		for e in _map.entities:
			states[e.file_off] = e.state_byte
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
	}

## Re-apply a save_state() snapshot. Call after every node is registered
## (register_node / register_destructible) so the visuals refresh too.
func restore_state(snap: Dictionary) -> void:
	if _map == null or snap.is_empty():
		return
	var states: Dictionary = snap.get("states", {})
	for off in states:
		var e: MapFile.Entity = _map.entities_by_off.get(off)
		if e != null:
			e.state_byte = int(states[off])
	_hp = (snap.get("hp", {}) as Dictionary).duplicate()
	_spent = (snap.get("spent", {}) as Dictionary).duplicate()
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
	if fam == "rot":
		# Continuous rotator — never stops while enabled.
		m["progress"] = fmod(m["progress"] + ROT_SPEED * delta, 2048.0)
		_apply_mover_transform(node, m)
		return
	var limit: float = m["limit"]
	if fam == "slide5f":
		limit = float(int(m["limit"]) << 4)      # p6<<4 travel distance
	if limit == 0.0:
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
	m["progress"] = p
	_apply_mover_transform(node, m)
	if p == target:
		e.state_byte &= ~1                       # arrived: self-disable
		m["dir"] = -m["dir"]                     # next activation reverses

## DOS axis p4 (0=X, 1=Y-down, 2=Z) → Godot world direction.
static func _dos_axis(axis_i: int) -> Vector3:
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
			base.origin + _dos_axis(int(m["axis"])) * (m["progress"] * sign))
		return
	# Swing/rot: rotate about the DOS axis in entity-local space.
	# DOS→Godot conjugation keeps X/Y angle signs, negates Z.
	var angle: float = m["progress"] * sign * TAU / 2048.0
	var axis_i: int = m["axis"]
	var axis := Vector3.RIGHT
	if axis_i == 1:
		axis = Vector3.UP
	elif axis_i == 2:
		axis = Vector3.BACK
		angle = -angle
	node.transform = Transform3D(
		base.basis * Basis(axis, angle), base.origin)
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
			if node != null and is_instance_valid(node) \
					and node is MeshInstance3D and meshes[new_stage] != null:
				(node as MeshInstance3D).mesh = meshes[new_stage]
				_blast(node, new_stage == meshes.size() - 1)
			if new_stage == meshes.size() - 1:
				_spent[e.file_off] = true
	elif want >= 1:
		# No stage meshes — vanish (rubble piles etc.).
		_spent[e.file_off] = true
		if node != null and is_instance_valid(node):
			_blast(node, true)
			node.visible = false
			_disable_collision(node)
	return true

## DOS FUN_00124293 — HP gone. The link record's byte 0 picks the
## destruction type (Skynet.exe 0x423d6): effect sprites scattered
## within `spread`, a random drop from the type's list (crates → ammo,
## lockers → medkits) and a sound (-2 = one of 33..36); type 0 is a
## plain blast (effect 358) sized by the i16 parameter, no drop. Staged
## destructibles (0x18/0x19 wrecks) keep their final mesh; everything
## else leaves the world.
func _destroy(e: MapFile.Entity) -> void:
	var node: Node3D = _nodes.get(e.file_off)
	var origin := Vector3(float(e.x), -float(e.y), -float(e.z))
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
				var ex := Explosion.new()
				scene.add_child(ex)
				var at: Vector3 = centre
				if k > 0:
					at += Vector3(randf_range(-0.5, 0.5) * spread, 0.0, randf_range(-0.5, 0.5) * spread)
				ex.setup(at, radius * 1.6, int(s) >> 7)
				k += 1
		var pl := node.get_tree().get_first_node_in_group("player")
		if pl is Node3D and pl.has_method("take_damage"):
			var dist: float = (pl as Node3D).global_position.distance_to(centre)
			var reach: float = radius * 2.5
			if dist < reach:
				pl.take_damage(45.0 * (1.0 - dist / reach))
		if not _destr.has(e.file_off):
			node.visible = false
			_disable_collision(node)
	if drop >= 0:
		drop_requested.emit(Vector3(centre.x, origin.y, centre.z), drop)

## Explosion at a destructible's centre; the final stage also hurts
## the player nearby (DOS cars and generators blow up in your face).
func _blast(node: Node3D, final: bool) -> void:
	var aabb: AABB = (node as MeshInstance3D).get_aabb() if node is MeshInstance3D else AABB()
	var centre: Vector3 = node.global_transform * (aabb.position + aabb.size * 0.5)
	var radius: float = maxf(aabb.size.length() * 0.35, 120.0)
	Audio.play_sfx_3d("EXPLO3.RAW" if final else "EXPLO1.RAW", centre, -3.0)
	if not node.is_inside_tree():
		return
	var scene := node.get_tree().current_scene
	if scene != null:
		var ex := Explosion.new()
		scene.add_child(ex)
		ex.setup(centre, radius * (1.6 if final else 1.0))
	if final:
		var pl := node.get_tree().get_first_node_in_group("player")
		if pl is Node3D and pl.has_method("take_damage"):
			var d: float = (pl as Node3D).global_position.distance_to(centre)
			var reach: float = radius * 2.5
			if d < reach:
				pl.take_damage(45.0 * (1.0 - d / reach))

static func _disable_collision(node: Node3D) -> void:
	for c in node.get_children():
		if c is CollisionObject3D:
			for s in c.get_children():
				if s is CollisionShape3D:
					s.disabled = true
