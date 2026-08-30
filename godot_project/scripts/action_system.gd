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

const MapFile := preload("res://scripts/loaders/map_file.gd")

## Mover ids → [family, p4, p6] from the 0x59b00 table's per-slot
## config dword (+4 low u16, +6 high u16). For swing/rot p4 selects the
## rotation axis (0=X, 1=Y, 2=Z; DOS axes) and p6 is the SIGNED angle
## limit in 11-bit units (2048 = 360°; 0 = continuous). For the 0x5f
## slide p4 is the speed base and p6<<4 the travel distance. The odd
## 0xbd..0xc0 pair carries a non-axis p4 — treated as Y-axis swings.
const MOVER_TABLE: Dictionary = {
	0x30: ["swing", 0, 512], 0x31: ["swing", 0, 65024],
	0x32: ["swing", 1, 512], 0x33: ["swing", 1, 65024],
	0x34: ["swing", 2, 512], 0x35: ["swing", 2, 65024],
	0x36: ["rot", 0, 1024], 0x37: ["rot", 1, 1024], 0x38: ["rot", 2, 1024],
	0x39: ["rot", 0, 0], 0x3a: ["rot", 0, 0], 0x3b: ["rot", 1, 0],
	0x3c: ["rot", 1, 0], 0x3d: ["rot", 2, 0], 0x3e: ["rot", 2, 0],
	0x3f: ["swing", 0, 64], 0x40: ["swing", 0, 64], 0x41: ["swing", 0, 128],
	0x42: ["swing", 0, 128], 0x43: ["swing", 0, 256], 0x44: ["swing", 0, 256],
	0x45: ["swing", 0, 512], 0x46: ["swing", 0, 512], 0x59: ["swing", 1, 64],
	0x5a: ["swing", 1, 64], 0x5b: ["swing", 1, 128], 0x5c: ["swing", 1, 128],
	0x5d: ["swing", 1, 256], 0x5e: ["swing", 1, 256],
	0x5f: ["slide", 316, 128], 0x61: ["swing", 1, 512],
	0x62: ["swing", 1, 512], 0x63: ["swing", 1, 2048],
	0x64: ["swing", 1, 2048], 0x65: ["swing", 1, 2560],
	0x66: ["swing", 1, 2560], 0x67: ["swing", 1, 24], 0x68: ["swing", 1, 24],
	0x69: ["swing", 1, 768], 0x6a: ["swing", 1, 768], 0x6b: ["swing", 1, 480],
	0x6c: ["swing", 1, 480], 0x6d: ["swing", 1, 378], 0x6e: ["swing", 1, 378],
	0x6f: ["swing", 1, 1024], 0x70: ["swing", 1, 1024],
	0x71: ["swing", 1, 1520], 0x72: ["swing", 1, 1520],
	0x73: ["swing", 2, 64], 0x74: ["swing", 2, 64], 0x75: ["swing", 2, 128],
	0x76: ["swing", 2, 128], 0x77: ["swing", 2, 256], 0x78: ["swing", 2, 256],
	0x79: ["swing", 2, 512], 0x7a: ["swing", 2, 512], 0x7b: ["swing", 2, 640],
	0x7c: ["swing", 2, 640], 0x7d: ["swing", 2, 384], 0x7e: ["swing", 2, 384],
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
const SWING_SPEED_SLOW: float = 153.0    # 11-bit units/s, |limit| < 0x800
const SWING_SPEED_FAST: float = 306.0    # 11-bit units/s, |limit| >= 0x800
const ROT_SPEED: float = 153.0           # continuous rotators
const SLIDE_SPEED_SCALE: float = 2.2     # slide speed = p4 * this (units/s)
const PROX_GATE_RADIUS: float = 60.0     # 0xEF (Skynet.exe 0x137e2e)
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
			"progress": 0.0,
			"dir": 1.0,
			"base": node.transform,
		}

## Register the damage-stage meshes for a destructible entity (built by
## the level loader from TRANSFRM.PRS; may be empty → vanish on kill).
## True when the entity at `off` is a mover (door/gate/lift/rotator).
func is_mover_off(off: int) -> bool:
	return _movers.has(off)

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
	if e == null or _spent.has(file_off):
		return false
	if (e.state_byte & 6) == 0:
		return false
	var depleted: bool = false
	if _hp.has(file_off):
		_hp[file_off] -= damage
		if _hp[file_off] <= 0.0:
			depleted = true
	# Destructible damage accumulates every qualifying hit. Membership
	# comes from registration (act 0x18/0x19 OR a TRANSFRM.PRS name
	# match — cars carry bit1 + HP but act 0x00 in the MAP data).
	if _destr.has(file_off):
		_advance_destructible(e, damage)
		return true
	if (e.state_byte & 2) != 0 or ((e.state_byte & 4) != 0 and depleted):
		if depleted:
			_spent[file_off] = true
		_trigger(e)
		return true
	return false

## Activate-key port. The DOS use-key path is untraced; we honour the
## same bit1 ("act on hit") gate without applying damage, which covers
## shoot-or-use switches while leaving HP-gated objects (generators,
## bit2) to real damage.
func on_player_activate(file_off: int) -> bool:
	var e: MapFile.Entity = _map.entities_by_off.get(file_off) \
		if _map != null else null
	if e == null or _spent.has(file_off):
		return false
	if (e.state_byte & 2) == 0:
		return false
	_trigger(e)
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
		if (cur.flags & 0x40) != 0:
			break
		if cur.link_next < 1:
			break
		var nxt: MapFile.Entity = _map.entities_by_off.get(cur.link_next)
		if nxt == cur:
			break
		cur = nxt

## ObjDoAction: dispatch when enabled. Movers/proximity/teleports are
## per-tick handlers driven from tick(); the one-shot families run here.
func _do_action(e: MapFile.Entity) -> void:
	var act: int = e.link_act_type
	if act <= 0 or act >= 0xFE:
		return
	if is_mover(act) or act == ACT_PROX_GATE \
			or act == ACT_PROX_CHAIN_A or act == ACT_PROX_CHAIN_B \
			or act == ACT_TELEPORT or is_destructible(act):
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
	for e in _prox:
		if (e.state_byte & 1) == 0 or _spent.has(e.file_off):
			continue
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		var inside: bool = _within(epos, player_pos, _prox_radius(e))
		var latched: bool = _prox_latched.get(e.file_off, false)
		if inside and not latched:
			_prox_latched[e.file_off] = true
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
	# Teleports ---------------------------------------------------
	# Armed by a chain (0xEF gate → sound node → 0xF0) or by the player
	# touching the doorway sprite itself. One map change per level
	# instance — the level is torn down once the signal fires.
	if _teleport_fired:
		return
	for e in _teleports:
		var epos := Vector3(float(e.x), -float(e.y), -float(e.z))
		var touching: bool = _within(epos, player_pos, TELEPORT_TOUCH_RADIUS)
		var armed: bool = (e.state_byte & 1) != 0
		if touching and not _touch_latched.get(e.file_off, false):
			armed = true
		_touch_latched[e.file_off] = touching
		if not armed:
			continue
		e.state_byte &= ~1                       # one-shot (0x137881)
		_teleport_fired = true
		print("[action] teleport → map %d, marker set %d"
			% [e.exit_map, e.exit_marker_id])
		teleport_requested.emit(e.exit_map, e.exit_marker_id)
		return

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
	if fam == "slide":
		limit = float(int(m["limit"]) << 4)      # p6<<4 travel distance
	if limit == 0.0:
		return
	var span: float = absf(limit)
	var speed: float
	if fam == "slide":
		speed = float(m["p4"]) * SLIDE_SPEED_SCALE
	else:
		speed = SWING_SPEED_FAST if span >= 2048.0 else SWING_SPEED_SLOW
	var target: float = span if m["dir"] > 0.0 else 0.0
	var p: float = move_toward(m["progress"], target, speed * delta)
	m["progress"] = p
	_apply_mover_transform(node, m)
	if p == target:
		e.state_byte &= ~1                       # arrived: self-disable
		m["dir"] = -m["dir"]                     # next activation reverses

func _apply_mover_transform(node: Node3D, m: Dictionary) -> void:
	var base: Transform3D = m["base"]
	var fam: String = m["family"]
	var sign: float = 1.0
	if fam != "rot" and m["limit"] < 0.0:
		sign = -1.0
	if fam == "slide":
		# DOS adds to entity+0xc (Y, Y-down) → Godot -Y (slides down).
		node.transform = base.translated_local(
			Vector3(0.0, -m["progress"] * sign, 0.0))
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

## Destructible damage-stage advance (handler 0x120433): the damage
## counter steps one TRANSFRM.PRS stage per DESTRUCT_DAMAGE_PER_STAGE
## points; past the last stage the object is a spent wreck (or, with no
## stage meshes, vanishes).
func _advance_destructible(e: MapFile.Entity, damage: float) -> void:
	var d: Dictionary = _destr[e.file_off]
	d["accum"] += damage
	var meshes: Array = d["meshes"]
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
