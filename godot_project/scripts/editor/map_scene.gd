## Builds a SkyNET map as a plain, editable Godot scene for the editor.
##
## The runtime level (level_loader.gd) creates game nodes — ActionTarget,
## Enemy, Pickup — that carry behaviour. For viewing and editing a map
## in the Godot editor we want the *data* instead: one node per MAP
## entity holding its record (MapEntityRec, shown in the inspector) and
## its visual (mesh / sprite / marker gizmo) from the converted-asset
## cache, so the .scn stays small and opens instantly.
##
##   converted/maps/MAP.210.scn        ← save(map_name)
##
## Node layout:
##   MapRoot (map_root.gd: name, outdoor flag, grid, name table)
##   ├─ Terrain            MeshInstance3D (converted/terrain/WLD.NNN.res)
##   ├─ Entities/          MapMesh per variant-1 entity
##   ├─ Enemies/           MapMesh per enemy marker (type mesh, frame 0)
##   ├─ Sprites/           MapSprite per billboard
##   └─ Markers/           MapMarker per placement marker / light
##
## Coordinates follow the runtime loader exactly (DOS Y-down → Godot:
## (x, -y, -z); markers sit at y + 0x10; 11-bit Euler angles).

extends RefCounted

const LevelLoader := preload("res://scripts/level_loader.gd")
const MapFile     := preload("res://scripts/loaders/map_file.gd")
const WldTerrain  := preload("res://scripts/loaders/wld_terrain.gd")
const AIData      := preload("res://scripts/enemy_ai_data.gd")
const MapRoot     := preload("res://scripts/editor/map_root.gd")
const MapMesh     := preload("res://scripts/editor/map_mesh.gd")
const MapSprite   := preload("res://scripts/editor/map_sprite.gd")
const MapMarker   := preload("res://scripts/editor/map_marker.gd")
const MapEntityRec := preload("res://scripts/editor/map_entity_rec.gd")

## Bump when the scene's contents change; converted/maps/VERSION holds
## the number the cached scenes were built with, and Assets.map_scene()
## drops them all when it moves on.
const BUILD_VERSION: int = 2

## Where a map's scene lives in the asset cache.
static func scene_path(map_name: String) -> String:
	return "%s/maps/%s.scn" % [Assets.root, map_name.to_upper()]

## Build the editable scene tree for `map_name` (not yet packed).
## Returns null when the map cannot be loaded.
static func build(map_name: String) -> Node3D:
	# Straight from the DOS records: this view IS the data, so it must not
	# take the baked level scene's geometry (nor trigger a bake).
	var loader := LevelLoader.new()
	loader.use_baked = false
	var level: LevelLoader.Level = loader.load_level(map_name)
	if level == null or level.map == null:
		return null
	var root: Node3D = MapRoot.new()
	root.name = map_name.replace(".", "_")
	root.map_name = map_name
	root.is_outdoor = level.is_outdoor
	root.grid_size = Vector2i(level.map.grid_width, level.map.grid_height)
	root.names = PackedStringArray(level.map.names)
	root.raw = level.map_bytes
	root.build_version = BUILD_VERSION

	if level.terrain != null and level.terrain.mesh != null:
		var t := MeshInstance3D.new()
		t.name = "Terrain"
		t.mesh = level.terrain.mesh
		root.add_child(t)

	var ents := Node3D.new(); ents.name = "Entities"; root.add_child(ents)
	var enemies := Node3D.new(); enemies.name = "Enemies"; root.add_child(enemies)
	var sprites := Node3D.new(); sprites.name = "Sprites"; root.add_child(sprites)
	var markers := Node3D.new(); markers.name = "Markers"; root.add_child(markers)

	var gizmo_cache: Dictionary = {}
	for e in level.map.entities:
		var variant: int = e.flags & 3
		var rec: Resource = _rec_for(level.map, e)
		match variant:
			1:
				var nm: String = MapFile.entity_name(level.map, e)
				var node: MeshInstance3D = MapMesh.new()
				node.rec = rec
				node.name = "%s_%06x" % [nm if not nm.is_empty() else "MESH", e.file_off]
				if not nm.is_empty():
					node.mesh = Assets.mesh(nm.to_upper() + ".3D")
				node.transform = Transform3D(_basis(e), Vector3(float(e.x), -float(e.y), -float(e.z)))
				ents.add_child(node)
			2:
				var light: MeshInstance3D = MapMarker.new()
				light.rec = rec
				light.name = "LIGHT_%06x" % e.file_off
				light.setup_gizmo("L%d" % e.light_intensity, Color(1.0, 0.9, 0.3), gizmo_cache)
				light.position = Vector3(float(e.x), -float(e.y), -float(e.z))
				markers.add_child(light)
			3:
				if e.marker_type == 2:
					var en: MeshInstance3D = MapMesh.new()
					en.rec = rec
					var tname: String = _enemy_name(e.enemy_type)
					en.name = "%s_%06x" % [tname.to_upper() if not tname.is_empty() else "ENEMY", e.file_off]
					if not tname.is_empty():
						en.mesh = Assets.mesh(tname.to_upper() + ".3D")
					en.position = Vector3(float(e.x), -float(e.y + 0x10), -float(e.z))
					en.rotation.y = (e.off_y & 0x7FF) * TAU / 2048.0
					enemies.add_child(en)
				elif e.marker_type >= 0:
					var mk: MeshInstance3D = MapMarker.new()
					mk.rec = rec
					mk.name = "MARKER%d_%06x" % [e.marker_type, e.file_off]
					mk.setup_gizmo("M%d" % e.marker_type, _marker_color(e.marker_type), gizmo_cache)
					mk.position = Vector3(float(e.x), -float(e.y + 0x10), -float(e.z))
					markers.add_child(mk)
				elif e.sprite_index >= 0:
					var sp: Sprite3D = MapSprite.new()
					sp.rec = rec
					sp.name = "SPRITE%d_%06x" % [e.sprite_index, e.file_off]
					var bank: int = e.sprite_index >> 7
					var rec_id: int = e.sprite_index & 0x7F
					var tex := Assets.texture(bank, rec_id, true)
					if tex == null:
						continue
					# EXACTLY the runtime's sizing. This used to be a flat
					# 2.0 units per texel of the CACHED texture, which in
					# ENHANCED is upscaled 4x — so every billboard came
					# out four times too big and eight times for the
					# pickups, and the rest of the map looked shrunk next
					# to them (2026-09-04).
					var px: float = Assets.sprite_pixel_size(bank, rec_id, tex,
						LevelLoader.pixel_scale_for(e.sprite_index))
					var h: float = float(tex.get_height()) * px
					sp.texture = tex
					sp.pixel_size = px
					sp.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
					sp.shaded = false
					sp.double_sided = true
					sp.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
					sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS \
						if Render.enhanced() else BaseMaterial3D.TEXTURE_FILTER_NEAREST
					# Indoors the record sits 16 u above the floor, like
					# the enemy markers; outdoors it rests on the terrain.
					var base_y: float = -float(e.y) - LevelLoader.INDOOR_SPRITE_LIFT
					if level.is_outdoor and level.wld != null:
						base_y = WldTerrain.height_at_world(level.wld, float(e.x), float(e.z))
					sp.position = Vector3(float(e.x), base_y + h * 0.5, -float(e.z))
					sprites.add_child(sp)
	# The runtime nodes built by the loader are not needed here.
	for n in [level.terrain, level.entities, level.enemies, level.sprites,
			level.sky, level.occluders, level.detail, level.overlay]:
		if n != null and is_instance_valid(n):
			n.free()
	_own(root, root)
	return root

## Build, pack and save `map_name`; returns the .scn path ("" on failure).
## Built through the project link (res://converted) when it exists, so
## the editor can open the result.
static func save(map_name: String) -> String:
	return String(Assets.with_project_link(func() -> String: return _save_now(map_name)))

static func _save_now(map_name: String) -> String:
	var root := build(map_name)
	if root == null:
		return ""
	var ps := PackedScene.new()
	var err := ps.pack(root)
	root.free()
	if err != OK:
		push_error("[mapscene] pack failed for %s: %s" % [map_name, error_string(err)])
		return ""
	var p := scene_path(map_name)
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	err = ResourceSaver.save(ps, p, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_error("[mapscene] save failed for %s: %s" % [p, error_string(err)])
		return ""
	return p

static func _own(n: Node, owner: Node) -> void:
	for c in n.get_children():
		c.owner = owner
		_own(c, owner)

static func _rec_for(m: MapFile.MapFile, e: MapFile.Entity) -> Resource:
	var r: Resource = MapEntityRec.new()
	r.file_off = e.file_off
	r.variant = e.flags & 3
	r.flags = e.flags
	r.mesh_name = MapFile.entity_name(m, e)
	r.dos_pos = Vector3i(e.x, e.y, e.z)
	r.cell = Vector2i(e.cell_x, e.cell_z)
	r.pitch = e.off_x & 0x7FF
	r.yaw = e.off_y & 0x7FF
	r.roll = e.off_z & 0x7FF
	r.raw_angles = Vector3i(e.off_x, e.off_y, e.off_z)
	r.state_byte = e.state_byte
	r.link_next = e.link_next
	r.link_act_type = e.link_act_type
	r.hp = e.hp
	r.uses_defaults = e.uses_defaults
	r.sprite_index = e.sprite_index
	r.marker_type = e.marker_type
	r.enemy_type = e.enemy_type
	r.exit_map = e.exit_map
	r.exit_marker_id = e.exit_marker_id
	r.light_intensity = e.light_intensity
	r.light_enable = e.light_enable
	return r

## Same rotation convention as the runtime loader:
## C·R·C⁻¹ = Rz(-roll)·Rx(+pitch)·Ry(+yaw).
static func _basis(e: MapFile.Entity) -> Basis:
	var b := Basis()
	b = b.rotated(Vector3.UP, (e.off_y & 0x7FF) * TAU / 2048.0)
	b = b.rotated(Vector3.RIGHT, (e.off_x & 0x7FF) * TAU / 2048.0)
	b = b.rotated(Vector3.BACK, -((e.off_z & 0x7FF) * TAU / 2048.0))
	return b

static func _enemy_name(enemy_type: int) -> String:
	if enemy_type >= 0 and enemy_type < LevelLoader.ENEMY_MESH.size():
		var n: String = LevelLoader.ENEMY_MESH[enemy_type]
		if not n.is_empty():
			return n
	if enemy_type >= 0 and enemy_type < AIData.TYPES.size():
		return String(AIData.TYPES[enemy_type].get("n", ""))
	return ""

static func _marker_color(t: int) -> Color:
	match t:
		0: return Color(0.2, 1.0, 0.2)        # player start
		1: return Color(0.2, 0.6, 1.0)        # facing
		100: return Color(1.0, 0.5, 0.1)      # waypoint
	if t >= 10 and t <= 29:
		return Color(1.0, 0.2, 0.9)           # exit / MP spawn pairs
	return Color(0.85, 0.85, 0.85)
