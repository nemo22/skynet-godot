## The behaviour of a map as Godot nodes — the generator behind the
## "Behaviour" branch of a baked level scene (docs/map_format_plan.md).
##
## A SkyNET map drives everything that moves, opens, breaks, plays or
## counts with three things per entity: an action id (a slot of the
## Skynet.exe 0x59b00 handler table), a state byte, and a link to the
## next entity of a chain. A census of every map showed that surface is
## small — a few hundred movers, a couple of hundred
## destructibles, proximity gates, exits, sounds and messages, chains
## of two or three links — so each of those becomes one of the scenes
## in scenes/level/, instantiated here with its exports filled in from
## the record, and the chain link becomes a NodePath in `targets`:
##
##   Behaviour
##   +- Mission         the [M1]..[M5] counter and texts of the map's mission
##   +- Movers          Mover: door, gate, lift, dish — AnimatableBody3D + AnimationPlayer
##   +- Destructibles   Destructible: TRANSFRM.PRS damage stages
##   +- Damageables     Damageable: a mesh with hit points or a hit-fired chain
##   +- Triggers        Trigger: 0xEF gate (60 u), 0xF1 / 0xF2 (256 / 1024 u) — Area3D
##   +- Exits           MapExit: 0xF0 map change — Area3D
##   +- Sounds          looping ambient 0xEE — a plain AudioStreamPlayer3D, no script
##   +- SoundCues       one-shot 0xDB..0xEB — the door and button sounds chains route through
##   +- Voices          VoiceCue 0xED
##   +- Messages        MessageCue 0x1C..0x25 ([G1]..)
##   +- Objectives      Objective 0x26..0x2A ([M1]..), 0x2B = mission failed
##   +- Raw             RawAction: the lights a chain switches, the 0x2C
##                      relay, the water movers and the 0xF3 spawn
##                      sprites — which run from these nodes since step
##                      5d of docs/trigger_graph_plan.md — plus every
##                      other id with its data, and the act-less relays a
##                      chain passes through
##
## Node ids are the MAP file offsets the entities were read from:
## unique within a map, stable across rebakes, and what saves and the
## network will key state by (plan §3).
##
## Placement markers (enemy starts, spawn sets, water level …) are not
## entities with behaviour: their sub-record keeps other data where a
## sprite keeps its act byte — an enemy marker's "act" is its enemy
## type — so they never get a node and chains stop at them.
##
## A variant-1 mesh that the runtime builds as an action target (see
## wants_action) belongs to its node, whatever the kind: a mover or a
## destructible IS its mesh, a wall button is a Trigger with the panel
## under it. Everything else stays in the level's Static branch.
##
## F1 (2026-09-05) generated the branch; F2 (same day, first step) put
## it in the running level with scripts/level/behaviour.gd on its root:
## the one-shot cues fire from the nodes, and the chain walk that reaches
## them is the trigger runtime's (scripts/triggers/trigger_runtime.gd,
## plan step 5a), which owns the state the whole level reads. What the
## bake writes into the nodes below — act, state, hp, targets — is the
## MAP as it was AUTHORED, and stays that: nothing changes it at run time.

extends RefCounted

const MapFile      := preload("res://scripts/loaders/map_file.gd")
const Rules        := preload("res://scripts/triggers/rules_skynet.gd")
const Briefing     := preload("res://scripts/loaders/briefing.gd")
const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")

## The DOS geometry of a mover — the 11-bit Euler basis every variant-1
## record is placed with, the swing that advances one of its three
## components, the world direction of a DOS axis — belongs to the movers
## themselves since step 5e of docs/trigger_graph_plan.md.
const MoverNode    := preload("res://scripts/level/mover.gd")

const MOVER        := preload("res://scenes/level/mover.tscn")
const DESTRUCTIBLE := preload("res://scenes/level/destructible.tscn")
const DAMAGEABLE   := preload("res://scenes/level/damageable.tscn")
const TRIGGER      := preload("res://scenes/level/trigger.tscn")
const MAP_EXIT     := preload("res://scenes/level/map_exit.tscn")
const SOUND_LOOP   := preload("res://scenes/level/sound_loop.tscn")
const SOUND_CUE    := preload("res://scenes/level/sound_cue.tscn")
const VOICE_CUE    := preload("res://scenes/level/voice_cue.tscn")
const MESSAGE_CUE  := preload("res://scenes/level/message_cue.tscn")
const OBJECTIVE    := preload("res://scenes/level/objective.tscn")
const RAW_ACTION   := preload("res://scenes/level/raw_action.tscn")
const MISSION      := preload("res://scenes/level/mission.tscn")
## The script on the branch root — the run-time object layer.
const BEHAVIOUR_ROOT := preload("res://scripts/level/behaviour.gd")

const ANIM := &"move"
## Looping ambient sound (handler 0x12a47a; id at sub+2).
const ACT_SOUND_LOOP: int = 0xEE

## Every kind, in the order the containers appear under Behaviour.
const KINDS: PackedStringArray = ["mover", "destructible", "damageable", "trigger",
	"exit", "sound_loop", "sound_cue", "voice", "message", "objective", "raw"]
const CONTAINER: Dictionary = {
	"mover": "Movers", "destructible": "Destructibles", "damageable": "Damageables",
	"trigger": "Triggers", "exit": "Exits", "sound_loop": "Sounds",
	"sound_cue": "SoundCues", "voice": "Voices", "message": "Messages",
	"objective": "Objectives", "raw": "Raw",
}
const PREFIX: Dictionary = {
	"mover": "Mover", "destructible": "Destructible", "damageable": "Damageable",
	"trigger": "Trigger", "exit": "Exit", "sound_loop": "Sound",
	"sound_cue": "SoundCue", "voice": "Voice", "message": "Message",
	"objective": "Objective", "raw": "Raw",
}
## Kinds whose scene has no mesh slot of its own; a variant-1 mesh of
## theirs (a wall button, an objective on the HUMMERTK) hangs under
## the node as Mesh → Solid → Shape.
const MESHLESS_KINDS: PackedStringArray = ["trigger", "exit", "sound_loop", "sound_cue",
	"voice", "message", "objective", "raw"]

## The DOS "jump" family moves at once; the animation still needs a
## length to have two keys.
const JUMP_DURATION: float = 0.05
## A swing keys at most this many 11-bit units apart, so a 180° door
## slerps the right way round.
const SWING_KEY_STEP: float = 512.0

## Door-leaf test for the mover collider (was main.gd): a leaf is a
## thin slab, or carries no walkable floor plate in its lower third;
## corridor and room pieces that happen to move (MAP.214's CORB122I
## rotating bulkhead) always have one and keep their trimesh.
const DOOR_LEAF_MAX_THICKNESS: float = 40.0
const DOOR_LEAF_FLOOR_AREA: float = 4096.0     # 64 x 64 walkable plate
## Flat leaves (DOOR01 is a zero-thickness plane) still need a body.
const BOX_MIN_THICKNESS: float = 16.0

# ---------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------
## Does the runtime build this variant-1 mesh as an action target (a
## node with behaviour, not baked static geometry)? One rule for the
## loader and the bake, so the Static branch and the Behaviour branch
## partition the meshes the same way.
static func wants_action(e: MapFile.Entity, name: String, transfrm: Dictionary) -> bool:
	var act: int = e.link_act_type
	return Rules.is_mover(act) or Rules.is_destructible(act) \
		or act == Rules.ACT_DEMOLISH \
		or transfrm.has(name.to_lower()) \
		or (e.state_byte & 6) != 0 or e.hp > 0 \
		or act == Rules.ACT_PROX_GATE or act == Rules.ACT_PROX_CHAIN_A \
		or act == Rules.ACT_PROX_CHAIN_B

## Can `e` flip the chain it links to by itself — a proximity or use-key
## trigger, a countdown relay, a prop whose hit or death fires its link
## (state bits 1-2), a marker path whose end fires what it points at?
## main.gd's variant import carries such an entity's state only when
## everything down its chain is the same on both maps.
static func starts_chain(e: MapFile.Entity) -> bool:
	var act: int = e.link_act_type
	if e.marker_type >= 0:
		return e.link_next > 0
	return act == Rules.ACT_PROX_GATE or act == Rules.ACT_PROX_CHAIN_A \
		or act == Rules.ACT_PROX_CHAIN_B \
		or act == Rules.ACT_RELAY or (e.state_byte & 6) != 0

## Every entity another entity's chain points at (file offsets).
static func chain_targets(map: MapFile.MapFile) -> Dictionary:
	var out: Dictionary = {}
	for e in map.entities:
		if e.marker_type >= 0:
			continue
		if _link_of(map, e) != null:
			out[e.link_next] = true
	return out

## The entity `e` links to, or null (chain end, self loop, garbage).
static func _link_of(map: MapFile.MapFile, e: MapFile.Entity) -> MapFile.Entity:
	if e.link_next <= 0 or e.link_next == e.file_off:
		return null
	return map.entities_by_off.get(e.link_next)

## Which node an entity becomes ("" = none: static geometry, a plain
## sprite, a placement marker).
static func kind_of(map: MapFile.MapFile, e: MapFile.Entity, transfrm: Dictionary,
		targeted: Dictionary) -> String:
	if e.marker_type >= 0:
		return ""
	var variant: int = e.flags & 3
	var act: int = e.link_act_type
	var name: String = MapFile.entity_name(map, e) if variant == 1 else ""
	if Rules.is_mover(act):
		return "mover" if variant == 1 else "raw"
	if Rules.is_destructible(act) or (variant == 1 and transfrm.has(name.to_lower())):
		return "destructible" if variant == 1 else "raw"
	if act == Rules.ACT_PROX_GATE or act == Rules.ACT_PROX_CHAIN_A 			or act == Rules.ACT_PROX_CHAIN_B:
		return "trigger"
	if act == Rules.ACT_TELEPORT:
		return "exit"
	if act == ACT_SOUND_LOOP:
		return "sound_loop"
	if act == Rules.ACT_VOICE:
		return "voice"
	if Rules.SOUND_ONESHOT.has(act):
		return "sound_cue"
	if act >= Rules.ACT_HINT_FIRST and act <= Rules.ACT_HINT_LAST:
		return "message"
	if act >= Rules.ACT_OBJECTIVE_FIRST and act <= Rules.ACT_FAIL:
		return "objective"
	# 0x1B: a chain kills it — a Damageable whose act says so.
	if variant == 1 and (e.hp > 0 or (e.state_byte & 6) != 0 or act == Rules.ACT_DEMOLISH):
		return "damageable"
	# 0xFE / 0xFF are what DOS writes into a spent act byte, not ids.
	if act > 0 and act < 0xFE:
		return "raw"
	if _link_of(map, e) != null or targeted.has(e.file_off):
		return "raw"                            # a relay in a chain
	return ""

## kind → how many nodes the branch of this map holds. What the
## smoke test and the census compare the bake against.
static func census(map: MapFile.MapFile, transfrm: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if map == null:
		return out
	var targeted := chain_targets(map)
	for e in map.entities:
		var k := kind_of(map, e, transfrm, targeted)
		if not k.is_empty():
			out[k] = int(out.get(k, 0)) + 1
	return out

# ---------------------------------------------------------------------
# DOS record → Godot space (as level_loader.gd places meshes)
# ---------------------------------------------------------------------
static func entity_pos(e: MapFile.Entity) -> Vector3:
	return Vector3(float(e.x), -float(e.y), -float(e.z))

## 11-bit Euler angles → Godot basis: Rz(-roll)·Rx(+pitch)·Ry(+yaw), the
## DOS matrix conjugated by the Y/Z flip (level_loader.gd, verified
## against FUN_0014e100).
static func entity_basis(e: MapFile.Entity) -> Basis:
	return MoverNode.euler_basis(float(e.off_x & 0x7FF), float(e.off_y & 0x7FF), float(e.off_z & 0x7FF))

## The entity's raw 11-bit Euler triple (pitch, yaw, roll).
static func entity_euler(e: MapFile.Entity) -> Vector3:
	return Vector3(float(e.off_x & 0x7FF), float(e.off_y & 0x7FF), float(e.off_z & 0x7FF))

# ---------------------------------------------------------------------
# Movers: the 0x59b00 slot → travel, direction, speed → an animation
# ---------------------------------------------------------------------
## The bake's own copy of Rules.mover_params, and the ONLY reader of it is
## the "move" animation below — the running game asks the rules module
## directly (scripts/level/mover.gd adopt, step 5e). It is one row behind
## on purpose, not by accident: every "rot" here is still a 2048-unit
## continuous turn, where the rules module gives the three wall-monitor
## slots the instant 1024 their handler really does (2026-09-16). Bringing
## the two together changes the baked animation of those movers and so
## needs a rebake; nothing plays that animation.
static func mover_params(act: int) -> Dictionary:
	var cfg: Array = Rules.MOVER_TABLE[act]
	var fam: String = String(cfg[0])
	var p4: int = int(cfg[1])
	var limit: int = int(cfg[2])
	if limit >= 0x8000:
		limit -= 0x10000                        # signed i16
	# Slide/swing handlers step +p6 for odd act ids and -p6 for even
	# ones; the other families flip on a negative limit instead.
	var sgn: float = 1.0 if (act & 1) != 0 else -1.0
	if fam != "rot" and fam != "slide" and limit < 0:
		sgn = -sgn
	var span: float = absf(float(limit))
	match fam:
		"slide5f":
			span = absf(float(limit << 4))      # p6<<4 travel distance
		"rot":
			span = 2048.0                       # a full turn, looped
	var speed: float = Rules.SWING_SPEED
	match fam:
		"slide":
			speed = Rules.SLIDE_SPEED_FAST if span >= 2048.0 else Rules.SLIDE_SPEED_SLOW
		"slide5f":
			speed = float(p4) * Rules.SLIDE_SPEED_SCALE
		"jump":
			speed = 0.0                         # instant
		"rot":
			speed = Rules.ROT_SPEED
	return {"family": fam, "axis": clampi(p4, 0, 2), "p4": p4, "span": span,
		"sign": sgn, "speed": speed}

## The basis of a swung or spun mover at `progress` (signed 11-bit
## units) — Rules._apply_mover_transform, swing branch.
## The "move" animation of a mover: its Body from rest (t = 0) to the
## end of the travel, at the DOS speed. Position keys for the slides,
## rotation keys every SWING_KEY_STEP for the swings; a rotator loops.
## `euler` is the entity's raw Euler triple (entity_euler), `base` the
## basis it yields — the swings advance one Euler component
## (MoverNode.swing_basis), the slides move along a DOS axis.
static func mover_animation(p: Dictionary, euler: Vector3, base: Basis) -> Animation:
	var anim := Animation.new()
	var fam: String = p["family"]
	var span: float = p["span"]
	var sgn: float = p["sign"]
	var speed: float = p["speed"]
	var dur: float = JUMP_DURATION if speed <= 0.0 else span / speed
	anim.length = dur
	if fam == "slide" or fam == "jump" or fam == "slide5f":
		var t: int = anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(t, NodePath("Body"))
		anim.position_track_insert_key(t, 0.0, Vector3.ZERO)
		var end: Vector3
		if fam == "slide5f":
			# DOS adds to entity+0xc (Y-down) → the entity's local -Y.
			end = base * Vector3(0.0, -span * sgn, 0.0)
		else:
			# Along the DOS world axis: the handlers add to the position.
			end = MoverNode.dos_axis(int(p["axis"])) * (span * sgn)
		anim.position_track_insert_key(t, dur, end)
	else:
		var t: int = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(t, NodePath("Body"))
		var steps: int = maxi(1, int(ceil(span / SWING_KEY_STEP)))
		for k in steps + 1:
			var f: float = float(k) / float(steps)
			anim.rotation_track_insert_key(t, dur * f,
				MoverNode.swing_basis(euler, int(p["axis"]), span * f * sgn).get_rotation_quaternion())
		if fam == "rot":
			anim.loop_mode = Animation.LOOP_LINEAR
	return anim

# ---------------------------------------------------------------------
# Colliders
# ---------------------------------------------------------------------
## Is this mover mesh a door/gate LEAF (a box collider) rather than a
## room segment that moves (its trimesh)? Leaves are thin, or carry no
## walkable floor plate in their lower third.
##
## The floor test walks every triangle through surface_get_arrays (a copy
## of the whole mesh), and main.gd asks for every mover leaf on every map
## load — of the same few cached meshes. The answer is kept per mesh
## resource (path + instance, so a reconverted mesh is asked again).
static var _door_like_memo: Dictionary = {}

static func is_door_like(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	var key: String = ""
	if not mesh.resource_path.is_empty():
		key = "%s#%d" % [mesh.resource_path, mesh.get_instance_id()]
		if _door_like_memo.has(key):
			return bool(_door_like_memo[key])
	var door: bool = _door_like_uncached(mesh)
	if not key.is_empty():
		_door_like_memo[key] = door
	return door

static func _door_like_uncached(mesh: Mesh) -> bool:
	var aabb: AABB = mesh.get_aabb()
	var s: Vector3 = aabb.size
	if minf(s.x, minf(s.y, s.z)) <= DOOR_LEAF_MAX_THICKNESS:
		return true
	var floor_top: float = aabb.position.y + s.y / 3.0
	var floor_area: float = 0.0
	for si in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx_v = arrays[Mesh.ARRAY_INDEX]          # null for fan-built surfaces
		var idx: PackedInt32Array = idx_v if idx_v != null else PackedInt32Array()
		var nrm_v = arrays[Mesh.ARRAY_NORMAL]         # stored = visible side
		var nrm: PackedVector3Array = nrm_v if nrm_v != null else PackedVector3Array()
		var n: int = idx.size() if idx.size() > 0 else verts.size()
		var t: int = 0
		while t + 2 < n:
			var i0: int = idx[t] if idx.size() > 0 else t
			var i1: int = idx[t + 1] if idx.size() > 0 else t + 1
			var i2: int = idx[t + 2] if idx.size() > 0 else t + 2
			t += 3
			var a: Vector3 = verts[i0]
			var b: Vector3 = verts[i1]
			var cc: Vector3 = verts[i2]
			var cr: Vector3 = (b - a).cross(cc - a)
			var area2: float = cr.length()
			if area2 < 1.0:
				continue
			# mesh_3d.gd emits fans as (0, k+1, k): the raw cross product
			# points at the BACK; the stored normal is the visible side.
			var up: float = nrm[i0].y if nrm.size() > i0 else -cr.y / area2
			if up > 0.8 and maxf(a.y, maxf(b.y, cc.y)) <= floor_top:
				floor_area += area2 * 0.5
	return floor_area < DOOR_LEAF_FLOOR_AREA

## The DOS-style solid box of a mesh: {shape: BoxShape3D, centre}.
static func box_shape(mesh: Mesh) -> Dictionary:
	var aabb: AABB = mesh.get_aabb()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(aabb.size.x, BOX_MIN_THICKNESS),
		maxf(aabb.size.y, BOX_MIN_THICKNESS), maxf(aabb.size.z, BOX_MIN_THICKNESS))
	return {"shape": box, "centre": aabb.position + aabb.size * 0.5}

# ---------------------------------------------------------------------
# The branch
# ---------------------------------------------------------------------
## Build the Behaviour branch of `level` (a LevelLoader.Level with its
## parsed map and TRANSFRM.PRS table). `report` receives the tallies:
## kinds, movers_without_mesh, cues_with_mesh, dangling, to_markers.
static func build(level, report: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = "Behaviour"
	root.set_script(BEHAVIOUR_ROOT)
	for k in ["movers_without_mesh", "cues_with_mesh", "dangling", "to_markers"]:
		report[k] = 0
	report["kinds"] = {}
	var map: MapFile.MapFile = level.map if level != null else null
	if map == null:
		return root
	var transfrm: Dictionary = level.transfrm
	var targeted := chain_targets(map)
	var mission: Node = mission_node(level)
	if mission != null:
		root.add_child(mission)
	var containers: Dictionary = {}          # kind → Node3D
	var nodes: Dictionary = {}               # file_off → Node
	var shapes: Dictionary = {}              # radius → CylinderShape3D (shared)
	for e in map.entities:
		var kind := kind_of(map, e, transfrm, targeted)
		if kind.is_empty():
			continue
		var n: Node = _make(kind, level, e, transfrm, shapes, mission, report)
		if n == null:
			continue
		var c: Node3D = containers.get(kind)
		if c == null:
			c = Node3D.new()
			c.name = String(CONTAINER[kind])
			root.add_child(c)
			containers[kind] = c
		c.add_child(n)
		nodes[e.file_off] = n
		report["kinds"][kind] = int(report["kinds"].get(kind, 0)) + 1
	# The chains: ObjFlipLink's next pointer → a NodePath on the node.
	for off in nodes:
		var e: MapFile.Entity = map.entities_by_off[off]
		var t_ent: MapFile.Entity = _link_of(map, e)
		if t_ent == null:
			continue
		var n: Node = nodes[off]
		var t: Node = nodes.get(t_ent.file_off)
		if t == null:
			if t_ent.marker_type >= 0:
				report["to_markers"] += 1
			else:
				report["dangling"] += 1
			continue
		var path: NodePath = n.get_path_to(t)
		if "targets" in n:
			var arr: Array[NodePath] = []
			arr.append(path)
			n.set("targets", arr)
		else:
			n.set_meta("target", path)          # the scriptless SoundLoop
	return root

## Nodes with behaviour under a branch (the Mission does not count).
static func count(branch: Node) -> int:
	if branch == null:
		return 0
	var total: int = 0
	for c in branch.get_children():
		if c is Node3D:
			total += c.get_child_count()
	return total

## The mission a campaign map belongs to, from <key>.TXT in
## MDMDBRIF.BSA; null for the loose maps and the arenas.
static func mission_node(level) -> Node:
	if level == null or not String(level.map_suffix).is_valid_int():
		return null
	var sfx: int = int(level.map_suffix)
	if sfx < 200:
		return null
	@warning_ignore("integer_division")
	var key: int = (sfx / 10) * 10
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"), SkynetPaths.variant):
		return null
	var txt: PackedByteArray = bsa.read("%d.TXT" % key)
	bsa.close()
	if txt.is_empty():
		return null
	var brief: Dictionary = Briefing.parse(txt)
	var m = MISSION.instantiate()
	m.key = key
	m.objectives = PackedStringArray(brief.get("missions", []))
	m.hints = PackedStringArray(brief.get("hints", []))
	var total: int = 0
	for t in m.objectives:
		if not String(t).is_empty():
			total += 1
	m.objectives_total = total
	return m

static func _make(kind: String, level, e: MapFile.Entity, transfrm: Dictionary,
		shapes: Dictionary, mission: Node, report: Dictionary) -> Node:
	var map: MapFile.MapFile = level.map
	var variant: int = e.flags & 3
	var name: String = MapFile.entity_name(map, e) if variant == 1 else ""
	var n: Node = null
	match kind:
		"mover":
			n = _mover(e, name, report)
		"destructible":
			n = _destructible(e, name, transfrm)
		"damageable":
			n = _damageable(e, name)
		"trigger":
			n = _trigger(e, name, variant, shapes)
		"exit":
			n = _exit(e, shapes)
		"sound_loop":
			n = _sound_loop(e, variant)
		"sound_cue":
			n = _sound_cue(e)
		"voice":
			n = _voice(e)
		"message":
			n = _message(e, mission)
		"objective":
			n = _objective(e, mission)
		"raw":
			n = _raw(e, variant, name)
	if n == null:
		return null
	n.name = _node_name(kind, e, name)
	if n is Node3D:
		(n as Node3D).position = entity_pos(e)
	# A mesh the runtime builds as an action target goes with its node.
	if variant == 1 and kind in MESHLESS_KINDS and not name.is_empty() \
			and wants_action(e, name, transfrm):
		if _attach_mesh(n, e, name):
			report["cues_with_mesh"] += 1
	return n

static func _mover(e: MapFile.Entity, name: String, report: Dictionary) -> Node:
	var n = MOVER.instantiate()
	var p := mover_params(e.link_act_type)
	n.id = e.file_off
	n.act = e.link_act_type
	n.mesh_name = name
	n.family = p["family"]
	n.axis = p["axis"]
	n.travel = float(p["span"]) * float(p["sign"])
	n.speed = p["speed"]
	n.state = e.state_byte
	n.hp = e.hp
	var base := entity_basis(e)
	var anim := mover_animation(p, entity_euler(e), base)
	n.duration = anim.length
	var lib := AnimationLibrary.new()
	lib.add_animation(ANIM, anim)
	(n.get_node(^"AnimationPlayer") as AnimationPlayer).add_animation_library("", lib)
	var body: AnimatableBody3D = n.get_node(^"Body")
	body.transform = Transform3D(base, Vector3.ZERO)
	var mesh: ArrayMesh = _mesh_for(name)
	if mesh == null:
		report["movers_without_mesh"] += 1
		return n
	(body.get_node(^"Mesh") as MeshInstance3D).mesh = mesh
	var shape: CollisionShape3D = body.get_node(^"Shape")
	# Doors, gates and lifts collide as their box, like every DOS object
	# (BIGDOOR's trimesh is a braced frame with holes); a rotator and a
	# moving room piece keep the trimesh.
	if p["family"] != "rot" and is_door_like(mesh):
		var box := box_shape(mesh)
		shape.shape = box["shape"]
		shape.position = box["centre"]
	else:
		shape.shape = Assets.shape(name.to_upper(), mesh)
	return n

static func _destructible(e: MapFile.Entity, name: String, transfrm: Dictionary) -> Node:
	var n = DESTRUCTIBLE.instantiate()
	n.id = e.file_off
	n.act = e.link_act_type
	n.mesh_name = name
	n.hp = e.hp
	n.state = e.state_byte
	n.destroy_type = e.destroy_type
	n.destroy_param = e.destroy_param
	n.basis = entity_basis(e)
	var stages: Array[Mesh] = []
	for f in transfrm.get(name.to_lower(), PackedStringArray()):
		stages.append(_mesh_for(String(f).to_upper()))   # null keeps the stage index
	n.stages = stages
	_fill_body(n, name)
	return n

static func _damageable(e: MapFile.Entity, name: String) -> Node:
	var n = DAMAGEABLE.instantiate()
	n.id = e.file_off
	n.act = e.link_act_type
	n.mesh_name = name
	n.hp = e.hp
	n.state = e.state_byte
	n.destroy_type = e.destroy_type
	n.destroy_param = e.destroy_param
	n.basis = entity_basis(e)
	_fill_body(n, name)
	return n

## Mesh + shared trimesh into a body scene's Mesh / Shape slots.
static func _fill_body(body: Node, name: String) -> void:
	var mesh: ArrayMesh = _mesh_for(name)
	if mesh == null:
		return
	(body.get_node(^"Mesh") as MeshInstance3D).mesh = mesh
	(body.get_node(^"Shape") as CollisionShape3D).shape = Assets.shape(name.to_upper(), mesh)

static func _trigger(e: MapFile.Entity, name: String, variant: int, shapes: Dictionary) -> Node:
	var n = TRIGGER.instantiate()
	n.id = e.file_off
	n.act = e.link_act_type
	n.mesh_name = name
	var r: float = Rules.PROX_GATE_RADIUS
	if e.link_act_type == Rules.ACT_PROX_CHAIN_A:
		r = 256.0
	elif e.link_act_type == Rules.ACT_PROX_CHAIN_B:
		r = 1024.0
	n.radius = r
	# The port's rule (scripts/level/trigger.gd is_wall_button): a NAMED
	# variant-1 mesh with state bit 3 is a wall button, use key only; an
	# unnamed one is an invisible floor trigger (MAP.231's lift call
	# points).
	n.use_key = variant == 1 and (e.state_byte & 8) != 0 and not name.is_empty()
	n.state = e.state_byte
	(n.get_node(^"Shape") as CollisionShape3D).shape = _cylinder(shapes, r)
	return n

static func _exit(e: MapFile.Entity, shapes: Dictionary) -> Node:
	var n = MAP_EXIT.instantiate()
	n.id = e.file_off
	n.target_map = e.exit_map
	n.marker_set = e.exit_marker_id
	n.radius = Rules.TELEPORT_TOUCH_RADIUS
	n.state = e.state_byte
	(n.get_node(^"Shape") as CollisionShape3D).shape = _cylinder(shapes, Rules.TELEPORT_TOUCH_RADIUS)
	return n

## Loops that are meant to fill a whole level, not just their corner of
## it: the submarine's alarm (id 120, SUBALARM.WAV) sounds through the
## boat from the first second in DOS, while the scene's default 300-unit
## unit size at -10 dB left it inaudible 1600 units from the spawn.
## id → [unit_size, volume_db].
const LOUD_LOOPS: Dictionary = {120: [1500.0, -2.0]}

static func _sound_loop(e: MapFile.Entity, variant: int) -> Node:
	var n = SOUND_LOOP.instantiate()
	# The sound id sits at sub+2 (the u16 the parser reads into
	# exit_map for a variant-3 sprite).
	var sid: int = e.exit_map if variant == 3 else -1
	n.set_meta("id", e.file_off)
	n.set_meta("act", e.link_act_type)
	n.set_meta("sound_id", sid)
	n.set_meta("state", e.state_byte)
	n.stream = Audio.loop_stream_for(sid)
	if LOUD_LOOPS.has(sid):
		var lp: Array = LOUD_LOOPS[sid]
		n.unit_size = float(lp[0])
		n.volume_db = float(lp[1])
	return n

static func _sound_cue(e: MapFile.Entity) -> Node:
	var n = SOUND_CUE.instantiate()
	n.id = e.file_off
	n.act = e.link_act_type
	n.sound_id = int(Rules.SOUND_ONESHOT.get(e.link_act_type, -1))
	n.state = e.state_byte
	n.stream = Audio.oneshot_stream_for(n.sound_id)
	return n

static func _voice(e: MapFile.Entity) -> Node:
	var n = VOICE_CUE.instantiate()
	n.id = e.file_off
	n.voice_id = e.exit_map
	n.state = e.state_byte
	return n

static func _message(e: MapFile.Entity, mission: Node) -> Node:
	var n = MESSAGE_CUE.instantiate()
	n.id = e.file_off
	n.act = e.link_act_type
	n.index = e.link_act_type - Rules.ACT_HINT_FIRST
	n.state = e.state_byte
	var hints: PackedStringArray = mission.get("hints") if mission != null else PackedStringArray()
	if n.index < hints.size():
		n.text = String(hints[n.index])
	return n

static func _objective(e: MapFile.Entity, mission: Node) -> Node:
	var n = OBJECTIVE.instantiate()
	n.id = e.file_off
	n.act = e.link_act_type
	n.state = e.state_byte
	if e.link_act_type == Rules.ACT_FAIL:
		n.index = -1
		n.fails_mission = true
	else:
		n.index = e.link_act_type - Rules.ACT_OBJECTIVE_FIRST
		var lines: PackedStringArray = mission.get("objectives") if mission != null else PackedStringArray()
		if n.index < lines.size():
			n.text = String(lines[n.index])
	return n

static func _raw(e: MapFile.Entity, variant: int, name: String) -> Node:
	var n = RAW_ACTION.instantiate()
	n.id = e.file_off
	n.act = e.link_act_type
	n.variant = variant
	n.mesh_name = name
	n.hp = e.hp
	n.state = e.state_byte
	match variant:
		2:
			n.param = e.light_intensity
		3:
			n.sprite_index = e.sprite_index
			n.param = e.exit_map
	return n

## The panel of a wall button, the wreck an objective sits on: the mesh
## with its own body, so the use-key and hit rays still find something.
static func _attach_mesh(n: Node, e: MapFile.Entity, name: String) -> bool:
	var mesh: ArrayMesh = _mesh_for(name)
	if mesh == null:
		return false
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.basis = entity_basis(e)
	var sb := StaticBody3D.new()
	sb.name = "Solid"
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = Assets.shape(name.to_upper(), mesh)
	sb.add_child(cs)
	mi.add_child(sb)
	n.add_child(mi)
	return true

## The cached ArrayMesh of a MAP name ("BIGDOOR" → converted/mesh/
## BIGDOOR.res) — the same object the level's Static branch references.
static func _mesh_for(name: String) -> ArrayMesh:
	if name.is_empty():
		return null
	return Assets.mesh(name + ".3D")

## One cylinder per radius per map: the DOS radius wide, the port's
## vertical window tall (stacked interior floors keep their gates apart).
static func _cylinder(shapes: Dictionary, radius: float) -> CylinderShape3D:
	if shapes.has(radius):
		return shapes[radius]
	var c := CylinderShape3D.new()
	c.radius = radius
	c.height = 2.0 * Rules.PROX_VERTICAL_WINDOW
	shapes[radius] = c
	return c

## Kind, what it is, and the id — unique among siblings and readable in
## the scene tree: Mover_BIGDOOR_0a1b2, Trigger_EF_0a1c4, Exit_218_….
static func _node_name(kind: String, e: MapFile.Entity, name: String) -> String:
	var act: int = e.link_act_type
	var tag: String
	match kind:
		"mover", "destructible", "damageable":
			tag = name
		"trigger":
			tag = name if not name.is_empty() else "%02X" % act
		"exit":
			tag = "back" if e.exit_map == 0 else str(e.exit_map)
		"sound_loop":
			tag = str(e.exit_map) if (e.flags & 3) == 3 else "x"
		"sound_cue":
			tag = str(Rules.SOUND_ONESHOT.get(act, -1))
		"voice":
			tag = str(e.exit_map)
		"message":
			tag = "G%d" % (act - Rules.ACT_HINT_FIRST + 1)
		"objective":
			tag = "FAIL" if act == Rules.ACT_FAIL else "M%d" % (act - Rules.ACT_OBJECTIVE_FIRST + 1)
		_:
			tag = "relay" if act == 0 else "%02X" % act
			if not name.is_empty():
				tag += "_" + name
	return ("%s_%s_%05x" % [PREFIX[kind], tag, e.file_off]).validate_node_name()
