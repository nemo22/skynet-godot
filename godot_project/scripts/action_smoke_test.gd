## Headless smoke test for the action/link system (phase 1).
##
##   godot --headless --path . res://scenes/action_smoke_test.tscn
##
## Loads every campaign map (regression: none may fail to load), then
## exercises the MAP.210 action wiring: proximity button → BIGDOOR
## mover, GENER0 HP-depletion chain, TRANSFRM.PRS car damage stages,
## DISH rotator, and the 0xEF gate → 0xF0 teleport pair. Exits with a
## non-zero code on failure.

extends Node

const LevelLoader := preload("res://scripts/level_loader.gd")
const ActionSystem := preload("res://scripts/action_system.gd")
const EnemyAI := preload("res://scripts/enemy_ai.gd")
const AIData := preload("res://scripts/enemy_ai_data.gd")
const MapScene := preload("res://scripts/editor/map_scene.gd")
const MapWriter := preload("res://scripts/editor/map_writer.gd")
const MapFileC := preload("res://scripts/loaders/map_file.gd")
const MapMeshN := preload("res://scripts/editor/map_mesh.gd")
const MapEntityRecR := preload("res://scripts/editor/map_entity_rec.gd")

const CAMPAIGN: Array = [
	"MAP.210", "MAP.220", "MAP.230", "MAP.240",
	"MAP.252", "MAP.260", "MAP.270", "MAP.280",
]

var _fails: int = 0
var _teleport_seen: Array = []

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[smoke] PASS  %s" % what)
	else:
		_fails += 1
		print("[smoke] FAIL  %s" % what)

func _ready() -> void:
	var level210: LevelLoader.Level = null
	for m in CAMPAIGN:
		var loader := LevelLoader.new()
		var level := loader.load_level(m)
		_check(level != null and level.map != null, "%s loads" % m)
		if level == null:
			continue
		print("[smoke] %s: movers=%d destr=%d prox=%d teleports=%d"
			% [m, level.action._movers.size(), level.action._destr.size(),
			   level.action._prox.size(), level.action._teleports.size()])
		if m == "MAP.210":
			level210 = level
	if level210 != null:
		_run_map210_checks(level210)
		_run_transition_checks(level210)
	_run_ai_checks()
	_run_map_scene_checks()
	_run_map_writer_checks()
	print("[smoke] %s (%d failures)"
		% ["ALL PASS" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

func _run_map210_checks(level: LevelLoader.Level) -> void:
	var map = level.map
	var action: ActionSystem = level.action

	# Index entities by mesh name for lookups.
	var by_name: Dictionary = {}
	for e in map.entities:
		if (e.flags & 3) != 1:
			continue
		var nm := LevelLoader.MapFile.entity_name(map, e).to_upper()
		if not by_name.has(nm):
			by_name[nm] = []
		by_name[nm].append(e)

	_check(action._movers.size() >= 5,
		"MAP.210 has movers registered (doors/gates/dish)")
	var exits: Array = []
	for t in action._teleports:
		exits.append(t.exit_map)
	exits.sort()
	_check(exits == [211, 212, 213, 214, 218],
		"MAP.210 teleports → %s" % str(exits))

	# --- 1. Proximity BUTTON01 (act 0xEF) opens its chained door ---
	# Chains route through intermediates (0xE0 sound nodes …); walk
	# them with ObjFlipLink's exact rules (stop at an actor flag).
	var button: LevelLoader.MapFile.Entity = null
	var target: LevelLoader.MapFile.Entity = null
	for e in by_name.get("BUTTON01", []):
		if e.link_act_type != 0xEF or (e.state_byte & 1) == 0 \
				or e.link_next < 1:
			continue
		var found = _chain_find_mover(map, e)
		if found != null:
			button = e
			target = found
			break
	_check(button != null and target != null,
		"armed BUTTON01 chains (via hops) to a mover (act 0x%02x)"
		% (target.link_act_type if target != null else 0))
	# The proximity → chain path is covered by the gate→teleport check
	# below; placing the player AT the button would also trip the
	# overlapping LEVHAN01/210BASE3 levers whose chains thread the same
	# door (an even toggle count closes it again). Fire the chain
	# directly and verify the mover runs.
	if target != null:
		var node: Node3D = action._nodes.get(target.file_off)
		_check(node != null, "chained mover has a node")
		if node != null:
			var before: Transform3D = node.transform
			var far := Vector3(1e9, 0.0, 1e9)
			action._flip_link(button)             # the button's chain fires
			_check((target.state_byte & 1) != 0, "chain enabled the mover")
			for i in 30:                          # ~0.5 s of motion
				action.tick(0.016, far)
			_check(node.transform != before, "mover transform is moving")
			# BIGDOOR (act 0x41/0x42, handler 0x137a28) is a sliding
			# gate leaf: the origin moves, the basis does not.
			var slid: float = node.transform.origin.distance_to(before.origin)
			_check(slid > 1.0 and node.transform.basis.is_equal_approx(before.basis),
				"BIGDOOR gate slides without rotating (%.1f u)" % slid)

	# --- 2. GENER0: HP-gated (state bit2, hp 200) chain on destruction ---
	var gener: LevelLoader.MapFile.Entity = null
	for e in by_name.get("GENER0", []):
		if (e.state_byte & 4) != 0 and e.hp > 0:
			gener = e
			break
	_check(gener != null, "GENER0 with bit2 + HP exists")
	if gener != null:
		var next_e = map.entities_by_off.get(gener.link_next)
		var st_before: int = next_e.state_byte if next_e != null else -1
		action.on_player_hit(gener.file_off, 50.0)
		_check(next_e == null or next_e.state_byte == st_before,
			"GENER0 survives a 50-damage hit (no chain fire)")
		_check(action.on_player_hit(gener.file_off, 500.0),
			"GENER0 dies to the big hit and fires its chain")
		if next_e != null:
			_check(next_e.state_byte != st_before,
				"GENER0 chain flipped its target's state")

	# --- 3. Destructible car: TRANSFRM.PRS stage swap on damage ---
	var car: LevelLoader.MapFile.Entity = null
	for nm in by_name:
		if nm.begins_with("CARHIP") or nm.begins_with("COPCAR"):
			for e in by_name[nm]:
				if action._destr.has(e.file_off) \
						and action._destr[e.file_off]["meshes"].size() > 1 \
						and (e.state_byte & 6) != 0:
					car = e
					break
		if car != null:
			break
	_check(car != null, "damageable TRANSFRM.PRS car exists")
	if car != null:
		var cnode: MeshInstance3D = action._nodes.get(car.file_off)
		var mesh_before: Mesh = cnode.mesh
		action.on_player_hit(car.file_off, 20.0)
		_check(cnode.mesh != mesh_before,
			"car mesh swapped to damage stage after 20 damage")

	# --- 4. DISH (act 0x3b) rotates from load (state bit0 set) ---
	var dish: LevelLoader.MapFile.Entity = null
	for e in by_name.get("DISH", []):
		if e.link_act_type == 0x3b and (e.state_byte & 1) != 0:
			dish = e
			break
	_check(dish != null, "armed DISH rotator exists")
	if dish != null:
		var dnode: Node3D = action._nodes.get(dish.file_off)
		var db: Transform3D = dnode.transform
		action.tick(0.1, Vector3(1e9, 0, 1e9))    # player far away
		_check(dnode.transform != db, "DISH rotates while enabled")

	# --- 5. 0xEF gate + 0xF0 teleport (chained via a sound node) ---
	action.teleport_requested.connect(_on_teleport)
	var gate: LevelLoader.MapFile.Entity = null
	for e in map.entities:
		if (e.flags & 3) != 3 or e.link_act_type != 0xEF \
				or (e.state_byte & 1) == 0 or e.link_next < 1:
			continue
		var cur = e
		for hop in 8:
			if (cur.flags & 0x40) != 0 or cur.link_next < 1:
				break
			cur = map.entities_by_off.get(cur.link_next)
			if cur == null:
				break
			if cur.link_act_type == 0xF0:
				gate = e
				break
		if gate != null:
			break
	_check(gate != null, "0xEF gate chained to a 0xF0 teleport exists")
	if gate != null:
		var gpos := Vector3(float(gate.x), -float(gate.y), -float(gate.z))
		action.tick(0.016, gpos)                  # gate arms the teleport
		action.tick(0.016, gpos)
		_check(_teleport_seen.is_empty(), "an armed exit does not fire by itself")
		action.activate_teleport(gpos)            # the use key fires it
		_check(_teleport_seen.size() == 1
			and _teleport_seen[0][0] in [211, 212, 213, 214, 218],
			"use key fires the armed exit once → map %s" % str(_teleport_seen))

func _on_teleport(target_map: int, marker_set: int) -> void:
	_teleport_seen.append([target_map, marker_set])

## Phase 2 — map transitions: marker sets on both ends of an exit, the
## per-map state overlay round trip, doorway touch arming and the
## spawn-inside-the-gate latch.
func _run_transition_checks(level210: LevelLoader.Level) -> void:
	# Sound-id table sanity (0x4ff00): the door chains' one-shot nodes.
	_check(Audio.sound_name(40) == "doora.raw" and Audio.sound_name(45) == "button1.raw"
		and Audio.sound_name(125) == "torpedo.wav",
		"DOS sound-id table resolves door/button/last ids")

	# MAP.218 (bunker interior): spawn set 0, return exit → previous map
	# marker 27; MAP.210 must carry markers 27 + 28 for that return.
	var l218: LevelLoader.Level = LevelLoader.new().load_level("MAP.218")
	_check(l218 != null and l218.markers.has(0) and l218.markers.has(1),
		"MAP.218 has spawn marker 0 + facing marker 1")
	if l218 != null:
		var ret: Array = []
		for t in l218.action._teleports:
			ret.append([t.exit_map, t.exit_marker_id])
		_check(ret == [[0, 27]], "MAP.218 return exit → previous map, marker 27 (%s)" % str(ret))
	_check(level210.markers.has(27) and level210.markers.has(28),
		"MAP.210 carries the return markers 27 + 28")

	# State overlay: the GENER0 spent in the map-210 checks survives a
	# save → fresh parse → restore round trip.
	var snap: Dictionary = level210.action.save_state()
	var spent_offs: Array = snap["spent"].keys()
	_check(not spent_offs.is_empty(), "save_state captures spent entities")
	var l210b: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210b != null and not spent_offs.is_empty():
		var off: int = spent_offs[0]
		_check(not l210b.action._spent.has(off), "fresh MAP.210 parse starts unspent")
		l210b.action.restore_state(snap)
		_check(l210b.action._spent.has(off), "restore_state re-applies the spent flag")
		var e = l210b.map.entities_by_off.get(off)
		_check(e != null and e.state_byte == int(snap["states"][off]),
			"restore_state re-applies entity state bytes")

	# Doorway touch: standing on a 0xF0 exit sprite arms it directly.
	var l210c: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210c != null:
		var seen: Array = []
		l210c.action.teleport_requested.connect(
			func(m: int, s: int) -> void: seen.append([m, s]))
		var ex = l210c.action._teleports[0]
		var epos := Vector3(float(ex.x), -float(ex.y), -float(ex.z))
		l210c.action.tick(0.016, epos)
		l210c.action.activate_teleport(epos)
		_check(seen.size() == 1 and seen[0][0] == ex.exit_map,
			"touching a doorway sprite arms it; the use key fires it once (%s)" % str(seen))
		l210c.action.tick(0.016, epos)
		l210c.action.activate_teleport(epos)
		_check(seen.size() == 1, "a fired level never teleports twice")

	# Spawn-inside latch: arm_proximity at the doorway keeps the chain
	# unflipped (no door sound, no auto-arm) — but the use key still goes
	# through the gate the player stands in (the truck interiors spawn
	# beside their DOOR gate, and "press use at the door" must work).
	var l210d: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210d != null:
		var seen2: Array = []
		l210d.action.teleport_requested.connect(
			func(m: int, s: int) -> void: seen2.append([m, s]))
		var ex2 = l210d.action._teleports[0]
		var epos2 := Vector3(float(ex2.x), -float(ex2.y), -float(ex2.z))
		l210d.action.arm_proximity(epos2)
		l210d.action.tick(0.016, epos2)
		_check((ex2.state_byte & 1) == 0, "spawning on a doorway does not arm it by itself")
		l210d.action.activate_teleport(epos2)
		_check(seen2.size() == 1, "use at the doorway fires it even when the spawn pre-latched its gate")
		l210d.action.tick(0.016, epos2 + Vector3(2000.0, 0.0, 0.0))
		l210d.action.tick(0.016, epos2)
		l210d.action.activate_teleport(epos2)
		_check(seen2.size() == 1, "a fired doorway never fires again in the same level")

## Phase 3 — DOS enemy AI data + the AIS interpreter, headless.
func _run_ai_checks() -> void:
	_check(AIData.TYPES.size() >= 100 and String(AIData.TYPES[33]["n"]) == "endoskel"
		and int(AIData.TYPES[33]["st"]) == 7 and int(AIData.TYPES[33]["hp"]) == 400,
		"enemy table: endoskel = state 7, 400 HP")
	_check(int(AIData.TYPES[7]["axis"]) == 1 and int(AIData.TYPES[58]["axis"]) == 0
		and AIData.TYPES[61]["fire"][3] == 23 and AIData.AMMO[23][1] == "ROCKET.3D",
		"turret data: smltrrt yaws, smlcanon pitches, missile pod fires rockets")
	var b := EnemyAI.new(33)
	_check(b.has_script() and b.state == 7, "endoskel carries an AIS script")
	# Not perceiving the player: the walk loop (frames 5..20) plays and
	# the hydraulic footstep (sound 60) fires on frame 8.
	var frames: Dictionary = {}
	var sounds: Dictionary = {}
	for i in 210:                               # 3 s at 70 Hz
		b.tick(EnemyAI.TICK, {"see": false, "dist": 3000.0, "bearing": 0, "angle": 0, "rand": 1000})
		frames[b.frame] = true
		for sid in b.sounds:
			sounds[sid] = true
	_check(frames.has(8) and frames.has(20), "T800 walk cycle reaches frames 8 and 20")
	_check(sounds.has(60), "footstep frame event plays sound 60 (hydra5)")
	# Player seen 300 units ahead: the script engages and reaches a
	# firing pose (anim flag 0x100) within a few seconds.
	var fired := false
	for i in 700:
		b.tick(EnemyAI.TICK, {"see": true, "dist": 300.0, "bearing": 0, "angle": 0, "rand": 1000})
		if b.firing_pose():
			fired = true
			break
	_check(fired, "T800 enters a firing pose when the player is close and seen")
	# Tank script: perceived player at 1000 u → SET speed 300 (var 48).
	var tank := EnemyAI.new(30)
	for i in 300:
		tank.tick(EnemyAI.TICK, {"see": true, "dist": 1000.0, "bearing": 0, "angle": 512})
	_check(tank.var_or(48, -1) == 300, "hvytnk script drives forward (var 48 = 300) toward a seen player")
	# HK flyer: seen player far away → altitude var 56 written.
	var hk := EnemyAI.new(4)
	for i in 300:
		hk.tick(EnemyAI.TICK, {"see": true, "dist": 3000.0, "bearing": 0, "angle": 0})
	_check(hk.vars.has(56), "hk_ftr script sets its altitude target (var 56)")

## Editor map scenes: MAP.210 builds, packs, saves and reloads with
## every entity family present.
func _run_map_scene_checks() -> void:
	var p: String = MapScene.save("MAP.210")
	_check(not p.is_empty() and ResourceLoader.exists(p), "MAP.210 editor scene saved (%s)" % p)
	if p.is_empty():
		return
	var ps: PackedScene = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(ps != null, "MAP.210 scene loads back as a PackedScene")
	if ps == null:
		return
	var root: Node = ps.instantiate()
	var ents: int = root.get_node("Entities").get_child_count()
	var enemies: int = root.get_node("Enemies").get_child_count()
	var sprites: int = root.get_node("Sprites").get_child_count()
	var markers: int = root.get_node("Markers").get_child_count()
	_check(ents == 176 and enemies == 19 and sprites == 235 and markers > 20,
		"scene holds 176 meshes, 19 enemies, 235 sprites, %d markers (got %d/%d/%d)" % [markers, ents, enemies, sprites])
	var first: Node = root.get_node("Entities").get_child(0)
	_check(first is MeshInstance3D and (first as MeshInstance3D).mesh != null
		and first.get("rec") != null and int(first.get("rec").get("file_off")) > 0,
		"entity nodes carry a mesh from the cache and their MAP record")
	_check(root.get_node("Terrain") != null and (root.get_node("Terrain") as MeshInstance3D).mesh != null,
		"scene carries the cached terrain mesh")
	var f := FileAccess.open(p, FileAccess.READ)
	var sz: int = f.get_length() if f != null else 0
	if f != null:
		f.close()
	_check(sz > 0 and sz < 2_000_000, "scene file references cache resources instead of embedding them (%d bytes)" % sz)
	root.free()
	# Cached textures must carry their pixels on disk (a fresh load, not
	# the in-memory object) and meshes must reference them by path.
	var tp: String = Assets.texture(302, 17, false).resource_path
	var fresh: Texture2D = ResourceLoader.load(tp, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(fresh != null and fresh.get_width() > 0 and fresh.get_height() > 0,
		"cached texture reloads from disk with pixels (%s %s)" % [tp, str(fresh.get_size()) if fresh else "null"])
	var mesh_res: ArrayMesh = ResourceLoader.load(Assets.mesh("BIGDOOR.3D").resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var mat: BaseMaterial3D = mesh_res.surface_get_material(0) if mesh_res else null
	_check(mat != null and mat.albedo_texture != null
		and mat.albedo_texture.resource_path.begins_with(Assets.root + "/tex/")
		and mat.albedo_texture.get_width() > 0,
		"cached mesh references a cache texture file (%s)" % (mat.albedo_texture.resource_path if mat and mat.albedo_texture else "none"))

## MAP writer: byte-exact round trip, then move / rotate / delete /
## duplicate entities and re-parse the result.
func _run_map_writer_checks() -> void:
	var root: Node3D = MapScene.build("MAP.210")
	if root == null:
		_check(false, "MAP.210 scene builds for the writer")
		return
	var raw: PackedByteArray = root.get("raw")
	var out: PackedByteArray = MapWriter.write(root)
	_check(out.size() == raw.size() and out == raw,
		"unedited scene round-trips byte for byte (%d bytes)" % out.size())
	# Angle decomposition reproduces every entity's rotation (an
	# equivalent Euler triple is fine — 180/180/180 is the identity).
	var bad_ang := 0
	for c in root.get_node("Entities").get_children():
		var r = c.get("rec")
		var b0: Basis = MapWriter.basis_from_angles(r.pitch, r.yaw, r.roll)
		var back: Vector3i = MapWriter.angles_from_basis(b0)
		var b1: Basis = MapWriter.basis_from_angles(back.x, back.y, back.z)
		if not b1.is_equal_approx(b0):
			bad_ang += 1
	_check(bad_ang == 0, "angle decomposition reproduces every mesh rotation (%d bad)" % bad_ang)
	# Edit: move the first mesh 3 cells along +X, rotate it 90°, delete
	# the second, duplicate the third.
	var ents: Node = root.get_node("Entities")
	var n0: Node3D = ents.get_child(0)
	var n1: Node3D = ents.get_child(1)
	var n2: Node3D = ents.get_child(2)
	var off0: int = int(n0.get("rec").get("file_off"))
	var off1: int = int(n1.get("rec").get("file_off"))
	var off2: int = int(n2.get("rec").get("file_off"))
	var old_pos: Vector3 = n0.position
	n0.position.x += 3.0 * 1024.0
	n0.rotation.y += PI * 0.5
	ents.remove_child(n1)
	n1.free()
	var dup: Node3D = n2.duplicate()
	dup.position.z -= 500.0
	ents.add_child(dup)
	var log: Array = []
	var edited: PackedByteArray = MapWriter.write(root, log)
	var m = MapFileC.parse(edited)
	_check(m != null, "edited MAP parses")
	if m != null:
		var e0 = m.entities_by_off.get(off0)
		_check(e0 != null and e0.x == int(round(old_pos.x)) + 3072
			and e0.cell_x == e0.x / 1024 and e0.cell_z == e0.z / 1024,
			"moved entity re-parses in its new cell (x=%d cell=%d)" % [e0.x if e0 else -1, e0.cell_x if e0 else -1])
		var yaw0: int = int(n0.get("rec").get("yaw"))
		_check(e0 != null and ((e0.off_y & 0x7FF) - yaw0 - 512) % 2048 == 0,
			"rotated entity carries yaw+512 (%d → %d)" % [yaw0, (e0.off_y & 0x7FF) if e0 else -1])
		_check(not m.entities_by_off.has(off1), "deleted entity is gone after re-parse")
		var e2 = m.entities_by_off.get(off2)
		var copies: int = 0
		for e in m.entities:
			if e.name_index == e2.name_index and e.x == e2.x and e.z == e2.z + 500:
				copies += 1
		_check(copies == 1 and m.entities.size() == 490,
			"duplicated entity appended and linked (%d entities, %d copies)" % [m.entities.size(), copies])
	# New entities from templates: a mesh (name from the table) and an
	# enemy marker, placed by node position only.
	var nm: MeshInstance3D = MapMeshN.new()
	var r1: Resource = MapEntityRecR.new()
	r1.variant = 1
	r1.flags = 1
	r1.mesh_name = String((root.get("names") as PackedStringArray)[0])
	r1.file_off = -1
	nm.rec = r1
	nm.position = Vector3(30000.0, -50.0, -30000.0)
	nm.rotation.y = PI * 0.5
	ents.add_child(nm)
	var en: MeshInstance3D = MapMeshN.new()
	var r2: Resource = MapEntityRecR.new()
	r2.variant = 3
	r2.flags = 3
	r2.marker_type = 2
	r2.enemy_type = 33
	r2.sprite_index = (299 << 7) | 2
	r2.file_off = -1
	en.rec = r2
	en.position = Vector3(31000.0, 100.0, -30500.0)
	root.get_node("Enemies").add_child(en)
	var edited2: PackedByteArray = MapWriter.write(root)
	var m2 = MapFileC.parse(edited2)
	var new_mesh = null
	var new_enemy = null
	if m2 != null:
		for e in m2.entities:
			if (e.flags & 3) == 1 and e.x == 30000 and e.z == 30000:
				new_mesh = e
			if e.marker_type == 2 and e.enemy_type == 33 and e.x == 31000:
				new_enemy = e
	_check(m2 != null and m2.entities.size() == 492, "two created entities re-parse (%d entities)" % (m2.entities.size() if m2 else -1))
	_check(new_mesh != null and new_mesh.name_index == 0 and new_mesh.y == 50
		and (new_mesh.off_y & 0x7FF) == 512 and new_mesh.cell_x == 29 and new_mesh.cell_z == 29,
		"created mesh has name 0, DOS y=50, yaw 512, cell 29/29")
	_check(new_enemy != null and new_enemy.y == -100 - 0x10 and new_enemy.cell_x == 30,
		"created enemy marker sits at y-0x10 in cell 30")
	root.free()

## Walk a chain with ObjFlipLink's rules (follow link_next, stop at an
## actor flag or chain end) and return the first mover entity, or null.
static func _chain_find_mover(map, start):
	var cur = start
	for hop in 8:
		if (cur.flags & 0x40) != 0 or cur.link_next < 1:
			return null
		cur = map.entities_by_off.get(cur.link_next)
		if cur == null:
			return null
		if ActionSystem.is_mover(cur.link_act_type):
			return cur
	return null
