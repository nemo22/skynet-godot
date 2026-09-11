## The converted maps in Godot's own format.
##
## A SkyNET level is DOS data: MAP.NNN (entity records) + WLD.NNN (the
## heightmap) + .3D meshes inside BSA archives. Every level load used to
## re-derive the whole world from that — read the archives, place a node
## per record, and build a collision shape for each one out of its mesh
## faces. It is the same work every time, and only the first half of it
## was cached (converted/mesh, converted/terrain).
##
## The conversion now also writes the WORLD ITSELF as a Godot scene:
##
##   converted/maps/MAP.210.level.scn
##
##   Level (level_scene_root.gd — map name, hash of the MAP it came from)
##   +- Terrain     MeshInstance3D + StaticBody3D (shared trimesh shape)
##   +- Static      every placed mesh with no behaviour, collision baked
##   +- Occluders   OccluderInstance3D — the hills and the big buildings
##   +- Behaviour   the map's doors, gates, lifts, destructibles,
##                  triggers, exits, sounds, messages and objectives as
##                  nodes, chains as NodePaths (scripts/level_behaviour.gd)
##
## The Behaviour branch is phases F1/F2 of docs/map_format_plan.md: the
## bake generates it, the editor shows it, and the running level lifts
## it out like the rest (take() below) — its root script walks the
## chains and fires the cues, while action_system.gd still drives the
## movers, triggers, exits and destructibles from the MAP records until
## their turn comes. Enemies, pickups, lights and markers are still
## built from the records by the loader.
##
## Two things this buys, both of them asked for (2026-09-04, "kludne
## nech konverzia spracuje tie data do formatu ktory vyhovuje godotu"):
##
##   * the editor opens a level directly — geometry, collision and all,
##     no import step, and the SkyNET Maps dock jumps straight to it;
##   * loading is an engine-side scene instantiation instead of a few
##     hundred GDScript nodes, and the collision shapes are shared
##     between every copy of a mesh AND between maps (converted/shape/)
##     instead of being rebuilt per instance.
##
## The scene is a build artefact: it carries the hash of the MAP file it
## was built from, so editing a map (the dock's export to mods/maps/)
## invalidates it and the next load rebuilds it. To add detail BY HAND
## that survives a rebuild, put it in a scene of your own:
## mods/maps/MAP.210.detail.tscn is instantiated on top of any level
## whose name it matches.

extends RefCounted

const LevelRoot    := preload("res://scripts/level_scene_root.gd")
const WldTerrain   := preload("res://scripts/loaders/wld_terrain.gd")
const LevelLoaderRef := preload("res://scripts/level_loader.gd")
const LevelBehaviour := preload("res://scripts/level_behaviour.gd")

## Bump when the bake changes shape (invalidates every saved scene).
## 8 = the Behaviour branch (2026-09-05); 9 = its root script and the
## 0x1B demolition targets as Damageables.
## 12: the submarine alarm and its kind of loop carry across a whole
## level (level_behaviour.LOUD_LOOPS), which is a property of the baked
## SoundLoop nodes — the maps already in the cache have to be built again.
const BAKE_VERSION: int = 12

# ---------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------
## Where this map's level scene lives.
static func scene_path(map_name: String) -> String:
	if Assets.root.is_empty():
		return ""
	return "%s/maps/%s.level.scn" % [Assets.root, map_name.to_upper()]

## A hand-made overlay for this map, instantiated on top of the baked
## level and never touched by the conversion.
static func overlay_path(map_name: String) -> String:
	return "res://mods/maps/%s.detail.tscn" % map_name.to_upper()

# ---------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------
## The baked parts of `map_name`, or an empty dictionary when there is no
## scene for it (or it was built from a different MAP, or by an older
## bake). Keys: terrain / static / occluders / behaviour — all detached
## Node3Ds ready to be added to the level.
static func take(map_name: String, map_bytes: PackedByteArray) -> Dictionary:
	var p := scene_path(map_name)
	if p.is_empty() or not ResourceLoader.exists(p):
		return {}
	# Straight off disk: a rebake writes the same path, and a stale copy
	# left in the resource cache would keep being handed back.
	var _t0: int = Time.get_ticks_usec()
	var packed := ResourceLoader.load(p, "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var _t1: int = Time.get_ticks_usec()
	if packed == null:
		return {}
	var root: Node = packed.instantiate()
	if OS.get_cmdline_user_args().has("--load-trace"):
		print("[load-trace]   %s: ResourceLoader.load %.0f ms, instantiate %.0f ms"
			% [map_name, float(_t1 - _t0) / 1000.0,
			   float(Time.get_ticks_usec() - _t1) / 1000.0])
	if root == null:
		return {}
	if int(root.get("bake_version")) != BAKE_VERSION \
			or int(root.get("source_hash")) != hash(map_bytes):
		print("[level] %s: the baked scene is stale — rebuilding" % map_name)
		root.free()
		if not Assets.read_only:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
		return {}
	var out: Dictionary = {}
	for key in ["Terrain", "Static", "Occluders", "Behaviour"]:
		var n: Node = root.get_node_or_null(NodePath(key))
		if n == null:
			continue
		root.remove_child(n)
		_disown(n)
		out[key.to_lower()] = n
	root.free()
	return out

## Clear the `owner` chain of a subtree lifted out of an instantiated
## scene — the scene root it points at is about to be freed.
static func _disown(n: Node) -> void:
	n.owner = null
	for c in n.get_children():
		_disown(c)

## The hand-made overlay for `map_name`, or null.
static func overlay(map_name: String) -> Node3D:
	var p := overlay_path(map_name)
	if not ResourceLoader.exists(p):
		return null
	var packed := ResourceLoader.load(p) as PackedScene
	if packed == null:
		return null
	var n: Node = packed.instantiate()
	if n is Node3D:
		print("[level] %s: hand-made overlay %s" % [map_name, p])
		return n as Node3D
	if n != null:
		n.free()
	return null

# ---------------------------------------------------------------------
# Baking
# ---------------------------------------------------------------------
## Pack the static half of a freshly built level and save it. The nodes
## stay where they are — they are lent to a temporary root for the pack
## and handed straight back, so the level that triggered the bake is the
## one that gets played.
static func save_from(level, map_name: String) -> String:
	if not Assets.enabled or Assets.read_only:
		return ""
	return String(Assets.with_project_link(
		func() -> String: return _save_now(level, map_name)))

static func _save_now(level, map_name: String) -> String:
	var p := scene_path(map_name)
	if p.is_empty():
		return ""
	var root: Node3D = LevelRoot.new()
	root.name = "Level_" + map_name.replace(".", "_")
	root.map_name = map_name
	root.bake_version = BAKE_VERSION
	root.source_hash = hash(level.map_bytes)
	root.is_outdoor = level.is_outdoor
	# The static half of level.entities is lifted into a "Static" node for
	# the pack and put straight back afterwards, so the level that
	# triggered the bake keeps playing with the very same nodes.
	var statics := Node3D.new()
	statics.name = "Static"
	var moved: Array = []
	if level.entities != null and is_instance_valid(level.entities):
		for c in static_children(level.entities):
			level.entities.remove_child(c)
			statics.add_child(c)
			moved.append(c)
	root.static_count = moved.size()

	# An environment and a key light, for the EDITOR only: open the scene
	# on its own and the map has a sky and a light. The runtime never sees
	# this: take() lifts out the groups below and frees everything else
	# with the root.
	root.add_child(_preview_branch(level))

	# What goes in, and where it came from, so it can all go back.
	var lent: Array = []                     # [node, old_parent, index]
	for g in [["Terrain", level.terrain], ["Static", statics],
			["Occluders", level.occluders]]:
		var n: Node = g[1]
		if n == null or not is_instance_valid(n):
			continue
		var old: Node = n.get_parent()
		var idx: int = n.get_index() if old != null else -1
		if old != null:
			old.remove_child(n)
		n.name = String(g[0])
		root.add_child(n)
		lent.append([n, old, idx])

	# The map's behaviour as nodes, built fresh from the records (never
	# lent: the game's own ActionTargets stay where they are).
	var report: Dictionary = {}
	var behaviour: Node3D = LevelBehaviour.build(level, report)
	root.add_child(behaviour)
	root.behaviour_count = LevelBehaviour.count(behaviour)

	for c in root.get_children():
		_own(c, root)
	# The behaviour nodes are instances of scenes/level/*.tscn with their
	# inner nodes filled in (a Mover's Body, Mesh and Shape); the packer
	# only records those overrides for instances the root marks editable.
	_mark_editable(root, root)
	var ps := PackedScene.new()
	# Sibling names must be unique in the packed scene. The loader names a
	# mesh after its entity (JWALL08 ×6), the tree auto-renames the copies
	# ("@MeshInstance3D@878") and PackedScene saves those; on instantiate
	# Godot 4 regenerates such names, two siblings can collide, and a
	# child whose name collides never enters the tree — invisible, and an
	# error every frame from anything asking for its global transform (40
	# walls of Future Shock's MAP.010, 19 of MAP.210, 2026-09-06).
	_unique_sibling_names(root)
	var err: int = ps.pack(root)
	var out: String = ""
	if err == OK:
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		err = ResourceSaver.save(ps, p, ResourceSaver.FLAG_COMPRESS)
		if err == OK:
			out = p
			print("[level] %s: baked %d static meshes and %d behaviour nodes into %s"
				% [map_name, root.static_count, root.behaviour_count, p.get_file()])
			print("[level] %s: behaviour %s; %d relays, %d cue meshes, %d movers without a mesh, %d links to markers, %d dangling"
				% [map_name, str(report.get("kinds", {})),
				   int(report.get("kinds", {}).get("raw", 0)), int(report.get("cues_with_mesh", 0)),
				   int(report.get("movers_without_mesh", 0)), int(report.get("to_markers", 0)),
				   int(report.get("dangling", 0))])
		else:
			push_warning("[level] cannot save %s (%s)" % [p, error_string(err)])
	else:
		push_warning("[level] cannot pack %s (%s)" % [map_name, error_string(err)])
	# Hand everything back exactly where it was.
	for item in lent:
		var n: Node = item[0]
		root.remove_child(n)
		_disown(n)
		var old: Node = item[1]
		if old != null and is_instance_valid(old):
			old.add_child(n)
			if int(item[2]) >= 0:
				old.move_child(n, int(item[2]))
	for c in moved:
		statics.remove_child(c)
		_disown(c)
		level.entities.add_child(c)
	statics.free()
	root.free()
	return out

## The children of an entity container that carry no behaviour: plain
## geometry, safe to bake. A door, a lift, a destructible car or a
## proximity trigger is an ActionTarget (it answers file_off()) and is
## built from the MAP records every time.
static func static_children(entities: Node) -> Array:
	var out: Array = []
	if entities == null or not is_instance_valid(entities):
		return out
	for c in entities.get_children():
		if c is MeshInstance3D and not c.has_method("file_off"):
			out.append(c)
	return out

## Everything the runtime builds from the MAP records, shown in the
## editor: the enemies where they stand, the placement markers, the map's
## own lights, and a night sky.
##
## Other engines put the dynamic objects straight in the level file,
## because there the level file IS the source. Here the source is the DOS
## MAP — the port converts it and exports edits back to it — so the level
## scene is a build product and its behaviour has to come from the
## records. This branch closes the gap for the EYE: open a baked level
## and the whole map is there, robots included, with the markers drawn as
## labelled gizmos. The runtime lifts out Terrain/Static/Occluders/Behaviour
## and frees this with the root, so none of it reaches the game.
static func _preview_branch(level) -> Node3D:
	var root := Node3D.new()
	root.name = "EditorPreview"
	_preview_actors(root, level)
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.015, 0.020, 0.055)
	sky_mat.sky_horizon_color = Color(0.055, 0.070, 0.125)
	sky_mat.ground_bottom_color = Color(0.03, 0.03, 0.04)
	sky_mat.ground_horizon_color = Color(0.055, 0.070, 0.125)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.name = "PreviewEnvironment"
	we.environment = env
	root.add_child(we)
	var moon := DirectionalLight3D.new()
	moon.name = "PreviewMoon"
	moon.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	moon.light_color = Color(0.72, 0.78, 0.96)
	moon.light_energy = 0.9
	moon.shadow_enabled = true
	root.add_child(moon)
	return root

## The enemies, the markers and the map lights, as the editor sees them.
static func _preview_actors(root: Node3D, level) -> void:
	if level == null or level.map == null:
		return
	var enemies := Node3D.new()
	enemies.name = "Enemies"
	root.add_child(enemies)
	var markers := Node3D.new()
	markers.name = "Markers"
	root.add_child(markers)
	var lights := Node3D.new()
	lights.name = "MapLights"
	root.add_child(lights)
	var gizmos: Dictionary = {}
	for e in level.map.entities:
		var variant: int = e.flags & 3
		if variant == 2:
			if e.light_enable <= 0:
				continue
			var l := OmniLight3D.new()
			l.name = "LIGHT_%06x" % e.file_off
			l.position = Vector3(float(e.x), -float(e.y), -float(e.z))
			l.omni_range = clampf(float(e.light_enable) * 10.0, 400.0, 6000.0)
			l.light_energy = clampf(float(e.light_intensity) / 14.0, 0.4, 3.5)
			lights.add_child(l)
			continue
		if variant != 3:
			continue
		if e.marker_type == 2:
			# An enemy: its type's mesh, first frame, where it starts.
			var nm: String = ""
			if e.enemy_type >= 0 and e.enemy_type < LevelLoaderRef.ENEMY_MESH.size():
				nm = String(LevelLoaderRef.ENEMY_MESH[e.enemy_type])
			if nm.is_empty():
				continue
			var frames: Array = Assets.mesh_frames(nm.to_upper() + ".3D")
			if frames.is_empty():
				continue
			var mi := MeshInstance3D.new()
			mi.name = "%s_%06x" % [nm.to_upper(), e.file_off]
			mi.mesh = frames[0]
			mi.position = Vector3(float(e.x), -float(e.y + 0x10), -float(e.z))
			mi.rotation.y = (e.off_y & 0x7FF) * TAU / 2048.0
			enemies.add_child(mi)
		elif e.marker_type >= 0:
			var mk := MeshInstance3D.new()
			mk.name = "MARKER%d_%06x" % [e.marker_type, e.file_off]
			mk.mesh = _gizmo_mesh(_marker_color(e.marker_type), gizmos)
			mk.position = Vector3(float(e.x), -float(e.y + 0x10), -float(e.z))
			var tag := Label3D.new()
			tag.name = "Label"
			tag.text = "M%d" % e.marker_type
			tag.pixel_size = 1.0
			tag.font_size = 48
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.no_depth_test = true
			tag.position = Vector3(0.0, 60.0, 0.0)
			mk.add_child(tag)
			markers.add_child(mk)

## A small unshaded box, one per colour.
static func _gizmo_mesh(color: Color, cache: Dictionary) -> BoxMesh:
	var key: String = color.to_html()
	if cache.has(key):
		return cache[key]
	var bm := BoxMesh.new()
	bm.size = Vector3(48.0, 48.0, 48.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	bm.material = mat
	cache[key] = bm
	return bm

## Same colours the editor's data view uses, so a marker reads the same
## in both places.
static func _marker_color(t: int) -> Color:
	match t:
		0: return Color(0.2, 1.0, 0.2)        # player start
		1: return Color(0.2, 0.6, 1.0)        # facing
		100: return Color(1.0, 0.5, 0.1)      # waypoint
	if t >= 10 and t <= 29:
		return Color(1.0, 0.2, 0.9)           # exit / MP spawn pairs
	return Color(0.85, 0.85, 0.85)

## Give the level root every node the bake built. A node that already
## has an owner is the inside of an instanced scenes/level/ scene (its
## Body, its Shape) and keeps it — the instance is what gets saved.
static func _own(n: Node, owner: Node) -> void:
	if n.owner == null:
		n.owner = owner
	for c in n.get_children():
		_own(c, owner)

## Every instanced scene under `n` becomes an editable instance of the
## root, so the properties the bake set on its inner nodes are packed.
static func _mark_editable(n: Node, root: Node) -> void:
	for c in n.get_children():
		if not c.scene_file_path.is_empty():
			root.set_editable_instance(c, true)
		_mark_editable(c, root)

# ---------------------------------------------------------------------
# Collision — one shape per MESH, shared by every copy and every map
# ---------------------------------------------------------------------
## Give `mi` the trimesh body the level needs, from the shared shape
## cache (converted/shape/<key>.res).
##
## Every entity used to call create_trimesh_collision(), which walks the
## mesh faces and builds a private ConcavePolygonShape3D — 410 of them
## on MAP.240, many of which are the same warehouse over and over. Now
## the shape is built once, cached on disk, and referenced.
static func add_collision(mi: MeshInstance3D, key: String) -> bool:
	if mi == null or mi.mesh == null:
		return false
	var shape: ConcavePolygonShape3D = Assets.shape(key, mi.mesh)
	if shape == null:
		return false
	var sb := StaticBody3D.new()
	sb.name = mi.name + "_col"
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	cs.shape = shape
	sb.add_child(cs)
	mi.add_child(sb)
	return true

# ---------------------------------------------------------------------
# Occluders
# ---------------------------------------------------------------------
## Godot can cull what is hidden behind an occluder, but only if the
## level says what the occluders ARE. Outdoors that is the terrain: from
## the jeep in the hills of MAP.220 the engine was submitting the whole
## valley behind the ridge in front of you, which is exactly the view
## that stuttered (2026-09-04). Indoors it is the walls.
##
## Terrain: a coarse grid (every OCC_STEP-th cell) whose every vertex
## takes the LOWEST ground around it and then drops another OCC_SINK —
## an occluder must never stand higher than the thing it stands for, or
## it culls what you can actually see.
const OCC_STEP: int = 4
const OCC_SINK: float = 48.0
## Static meshes big enough to hide something behind them go in with
## their real triangles (exact geometry is always safe), largest first,
## until the budget is used up.
const OCC_MESH_MIN_SIZE: float = 700.0
const OCC_MESH_MAX_TRIS: int = 1500
const OCC_BUDGET_TRIS: int = 42000

## Build the "Occluders" node for a level, or null when there is nothing
## worth occluding with.
static func build_occluders(level) -> Node3D:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	if level.wld != null:
		_terrain_occluder(level.wld, verts, idx)
	_mesh_occluders(level, verts, idx)
	if idx.is_empty():
		return null
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var oi := OccluderInstance3D.new()
	oi.name = "Occluder"
	oi.occluder = occ
	var root := Node3D.new()
	root.name = "Occluders"
	root.add_child(oi)
	print("[level] occluders: %d triangles" % (idx.size() / 3))
	return root

static func _terrain_occluder(w, verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	var cols: int = (WldTerrain.GRID_W - 1) / OCC_STEP
	var rows: int = (WldTerrain.GRID_H - 1) / OCC_STEP
	var stride: int = cols + 1
	var base: int = verts.size()
	verts.resize(base + stride * (rows + 1))
	for r in range(rows + 1):
		for c in range(stride):
			var col: int = mini(c * OCC_STEP, WldTerrain.GRID_W - 1)
			var row: int = mini(r * OCC_STEP, WldTerrain.GRID_H - 1)
			# The lowest ground anywhere in this vertex's neighbourhood.
			var h: float = 1e9
			for dr in range(-OCC_STEP, OCC_STEP + 1):
				for dc in range(-OCC_STEP, OCC_STEP + 1):
					h = minf(h, WldTerrain.corner_height(w,
						clampi(col + dc, 0, WldTerrain.GRID_W - 1),
						clampi(row + dr, 0, WldTerrain.GRID_H - 1)))
			verts[base + r * stride + c] = Vector3(
				float(col) * WldTerrain.WORLD_PER_CELL,
				h - OCC_SINK,
				-(WldTerrain.Z_FLIP_K - float(row) * WldTerrain.WORLD_PER_CELL))
	for r in rows:
		for c in cols:
			var v0: int = base + r * stride + c
			_quad(idx, v0, v0 + 1, v0 + stride + 1, v0 + stride)

## Two triangles, both windings — the occlusion rasteriser gets a solid
## surface either way round.
static func _quad(idx: PackedInt32Array, a: int, b: int, c: int, d: int) -> void:
	idx.append_array(PackedInt32Array([a, b, c, a, c, d, a, c, b, a, d, c]))

static func _mesh_occluders(level, verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	var budget: int = OCC_BUDGET_TRIS - idx.size() / 3
	if budget <= 0:
		return
	# Biggest first: one warehouse hides more than twenty crates. Only
	# static geometry — a door that swings open must never occlude.
	var big: Array = []
	for c in static_children(level.entities):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var s: Vector3 = mi.mesh.get_aabb().size
		var longest: float = maxf(s.x, maxf(s.y, s.z))
		if longest >= OCC_MESH_MIN_SIZE:
			big.append([longest, mi])
	big.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))
	for item in big:
		var mi: MeshInstance3D = item[1]
		var faces: PackedVector3Array = mi.mesh.get_faces()
		var tris: int = faces.size() / 3
		if tris <= 0 or tris > OCC_MESH_MAX_TRIS or tris * 2 > budget:
			continue
		budget -= tris * 2
		var xf: Transform3D = mi.transform
		var base: int = verts.size()
		for v in faces:
			verts.append(xf * v)
		for t in tris:
			var a: int = base + t * 3
			idx.append_array(PackedInt32Array([a, a + 1, a + 2, a, a + 2, a + 1]))

## Rename every node whose name is auto-generated ("@Class@id") or clashes
## with a sibling: <base>_<n>, the base being the mesh it carries or its
## class. Deterministic, so a re-bake gives the same names.
static func _unique_sibling_names(node: Node) -> void:
	var seen: Dictionary = {}
	for c in node.get_children():
		var base: String = String(c.name)
		if base.begins_with("@") or base.is_empty():
			base = c.get_class()
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				var rp: String = (c as MeshInstance3D).mesh.resource_path.get_file().get_basename()
				if not rp.is_empty():
					base = rp
		var nm: String = base
		var k: int = 1
		while seen.has(nm):
			k += 1
			nm = "%s_%d" % [base, k]
		seen[nm] = true
		if nm != String(c.name):
			c.name = nm
		_unique_sibling_names(c)
