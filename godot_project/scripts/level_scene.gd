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
##   converted/maps/MAP.210.level.scn            DOS look
##   converted/enhanced/maps/MAP.210.level.scn   ENHANCED look
##
##   Level (level_scene_root.gd — map name, hash of the MAP it came from)
##   +- Terrain     MeshInstance3D + StaticBody3D (shared trimesh shape)
##   +- Static      every placed mesh with no behaviour, collision baked
##   +- Occluders   OccluderInstance3D — the hills and the big buildings
##   +- Detail      ENHANCED only: the scattered clutter and the dust
##
## What is NOT in it: doors, lifts, destructibles, enemies, pickups,
## lights and markers. Those are behaviour, they are driven by the MAP
## records at run time, and the loader keeps building them from the data
## (it is the cheap half — a few dozen nodes against several hundred).
##
## Three things this buys, all of them asked for (2026-09-04, "kludne
## nech konverzia spracuje tie data do formatu ktory vyhovuje godotu"):
##
##   * the editor opens a level directly — geometry, collision and all,
##     no import step, and the SkyNET Maps dock jumps straight to it;
##   * loading is an engine-side scene instantiation instead of a few
##     hundred GDScript nodes, and the collision shapes are shared
##     between every copy of a mesh AND between maps (converted/shape/)
##     instead of being rebuilt per instance;
##   * there is somewhere to PUT the enhanced dressing. The DOS maps are
##     bare because a 1996 engine could not afford scenery; the ENHANCED
##     bake fills the empty ground with debris, burnt stumps and drifting
##     dust, deterministically, once, at conversion time.
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
const Replacements := preload("res://scripts/replacements.gd")
const FxParticles  := preload("res://scripts/fx_particles.gd")

## Bump when the bake changes shape (invalidates every saved scene).
const BAKE_VERSION: int = 3

# ---------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------
## Where this map's level scene lives, for the render mode in force.
static func scene_path(map_name: String) -> String:
	if Assets.root.is_empty():
		return ""
	var sub: String = "enhanced/maps" if Render.enhanced() else "maps"
	return "%s/%s/%s.level.scn" % [Assets.root, sub, map_name.to_upper()]

## A hand-made overlay for this map, instantiated on top of the baked
## level and never touched by the conversion.
static func overlay_path(map_name: String) -> String:
	return "res://mods/maps/%s.detail.tscn" % map_name.to_upper()

# ---------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------
## The baked parts of `map_name`, or an empty dictionary when there is no
## scene for it (or it was built from a different MAP, or by an older
## bake). Keys: terrain / static / occluders / detail — all detached
## Node3Ds ready to be added to the level.
static func take(map_name: String, map_bytes: PackedByteArray) -> Dictionary:
	var p := scene_path(map_name)
	if p.is_empty() or not ResourceLoader.exists(p):
		return {}
	# Straight off disk: a rebake writes the same path, and a stale copy
	# left in the resource cache would keep being handed back.
	var packed := ResourceLoader.load(p, "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return {}
	var root: Node = packed.instantiate()
	if root == null:
		return {}
	if int(root.get("bake_version")) != BAKE_VERSION \
			or int(root.get("source_hash")) != hash(map_bytes) \
			or int(root.get("render_mode")) != Render.mode:
		print("[level] %s: the baked scene is stale — rebuilding" % map_name)
		root.free()
		if not Assets.read_only:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
		return {}
	var out: Dictionary = {}
	for key in ["Terrain", "Static", "Occluders", "Detail"]:
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
	root.render_mode = Render.mode
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
	root.detail_count = _count(level.detail)

	# What goes in, and where it came from, so it can all go back.
	var lent: Array = []                     # [node, old_parent, index]
	for g in [["Terrain", level.terrain], ["Static", statics],
			["Occluders", level.occluders], ["Detail", level.detail]]:
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

	for c in root.get_children():
		_own(c, root)
	var ps := PackedScene.new()
	var err: int = ps.pack(root)
	var out: String = ""
	if err == OK:
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		err = ResourceSaver.save(ps, p, ResourceSaver.FLAG_COMPRESS)
		if err == OK:
			out = p
			print("[level] %s: baked %d static meshes and %d detail props into %s"
				% [map_name, root.static_count, root.detail_count, p.get_file()])
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

static func _own(n: Node, owner: Node) -> void:
	n.owner = owner
	for c in n.get_children():
		_own(c, owner)

static func _count(n: Node) -> int:
	if n == null or not is_instance_valid(n):
		return 0
	var total: int = 0
	for c in n.get_children():
		total += c.get_child_count()
	return total

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

# ---------------------------------------------------------------------
# ENHANCED detail
# ---------------------------------------------------------------------
## The DOS maps are bare: a 1996 engine could not afford scenery, so the
## ground between the buildings is empty terrain. It reads as a level,
## not as a country that lost a nuclear war. This scatters the CC0 props
## the pack carries — dead branches, bark debris, boulders, stumps,
## tyres, the odd dead tree — over the open ground, on a jittered grid
## seeded from the map number, so the same map always looks the same.
##
## Rules: nothing on a slope you could not walk, nothing within
## CLUTTER_CLEAR of a placed entity or of the player's own start.
## Everything is scattered at the HIGH density and split in two: `Props`
## is the half a MED machine draws, `PropsHigh` the rest.
const CLUTTER_SPACING: float = 900.0      # the HIGH grid; MED takes half
const CLUTTER_SKIP: float = 0.45          # fraction of cells left empty
const CLUTTER_CLEAR: float = 620.0        # keep away from real entities
const CLUTTER_MAX_SLOPE: float = 260.0    # height change across a cell
const CLUTTER_MARGIN: float = 2500.0      # how far past the buildings
const CLUTTER_MAX_SIZE: float = 240.0     # longest side of any one prop
const CLUTTER_SINK: float = 12.0          # bed it into the ground
const CLUTTER_MAX: int = 5000             # hard ceiling per map
## How far a scattered prop is drawn. Without a limit every one of them
## is submitted every frame from anywhere on the map, which is what made
## looking across the valley from the jeep stutter (2026-09-04).
const CLUTTER_DRAW_RANGE: float = 7000.0
## [bank, record, weight] — every one of these has a model in the pack.
const CLUTTER_PROPS: Array = [
	[215, 6, 5.0],    # dry branches
	[242, 2, 4.0],    # dry branches, spread
	[242, 3, 4.0],    # bark debris
	[211, 3, 4.0],    # rock
	[211, 5, 3.0],    # small sand rocks
	[210, 9, 3.0],    # stones
	[210, 2, 2.0],    # moon rock
	[211, 1, 1.5],    # boulder
	[213, 12, 1.5],   # burnt stump
	[213, 9, 1.0],    # old tyre
	[208, 0, 0.8],    # dead tree
]
## Volumetric dust over the open ground: ellipsoid FogVolumes in the same
## froxel grid as the global haze, so the moon and every muzzle flash
## light them.
const DUST_VOLUMES: int = 6
const DUST_SIZE := Vector3(5200.0, 900.0, 5200.0)

## How big a patch of ground one MultiMesh covers. Small enough that the
## engine can cull and fade whole patches by distance, big enough that a
## map is a few dozen draw calls of scenery and not a few thousand.
const CHUNK: float = 6000.0

## Build the "Detail" node for an ENHANCED outdoor level, or null.
##
## Every prop of one kind inside one patch of ground becomes a single
## MultiMeshInstance3D over a SHARED, cached mesh (converted/prop/), so
## the saved level scene holds transforms and nothing else. The first
## pass put a node per prop in it, each carrying its own copy of a
## photo-scanned model: 87 MB per map, and 1600 draw calls.
static func build_detail(level) -> Node3D:
	if not Render.enhanced() or level == null or not level.is_outdoor:
		return null
	if level.wld == null or level.map == null:
		return null
	# The area worth dressing: around everything the map actually placed.
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	var solid: Array[Vector2] = []
	for e in level.map.entities:
		if (e.flags & 3) == 2:
			continue
		var q := Vector2(float(e.x), -float(e.z))
		lo = lo.min(q)
		hi = hi.max(q)
		if (e.flags & 3) == 1:
			solid.append(q)
	if solid.is_empty():
		return null
	lo -= Vector2(CLUTTER_MARGIN, CLUTTER_MARGIN)
	hi += Vector2(CLUTTER_MARGIN, CLUTTER_MARGIN)
	var total: float = 0.0
	for c in CLUTTER_PROPS:
		total += float(c[2])

	var refs: Dictionary = {}                # "P215_006" -> {mesh, s_ref, longest}
	var batches: Dictionary = {}             # model|chunk -> {ref, med, high, at}
	var rng := RandomNumberGenerator.new()
	var map_salt: int = int(level.map_suffix) if level.map_suffix.is_valid_int() else 0
	var start := Vector2(level.player_start.x, level.player_start.z)
	var made: int = 0
	var x: float = lo.x
	while x < hi.x and made < CLUTTER_MAX:
		var z: float = lo.y
		while z < hi.y and made < CLUTTER_MAX:
			# Seeded per cell: the same map always dresses the same way.
			rng.seed = hash(Vector2i(int(x / CLUTTER_SPACING),
				int(z / CLUTTER_SPACING))) ^ map_salt
			z += CLUTTER_SPACING
			if rng.randf() < CLUTTER_SKIP:
				continue
			var at := Vector2(x + rng.randf_range(-0.4, 0.4) * CLUTTER_SPACING,
				z + rng.randf_range(-0.4, 0.4) * CLUTTER_SPACING)
			if at.distance_to(start) < 900.0:
				continue
			var near: bool = false
			for q in solid:
				if absf(q.x - at.x) < CLUTTER_CLEAR and absf(q.y - at.y) < CLUTTER_CLEAR:
					near = true
					break
			if near:
				continue
			# Flat enough to stand on? Sample the cell corners.
			var h0: float = WldTerrain.height_at_world(level.wld, at.x, -at.y)
			var h1: float = WldTerrain.height_at_world(level.wld, at.x + 256.0, -at.y)
			var h2: float = WldTerrain.height_at_world(level.wld, at.x, -at.y - 256.0)
			if maxf(absf(h1 - h0), absf(h2 - h0)) > CLUTTER_MAX_SLOPE:
				continue
			var pick: Dictionary = _clutter_prop(rng, total)
			if pick.is_empty():
				continue
			var ref: Dictionary = _prop_ref(int(pick["bank"]), int(pick["rec"]), refs)
			if ref.is_empty():
				continue
			# The sprite world size is the wrong yardstick for a model:
			# fitting a felled LOG to a tall sprite height stretched it
			# into a twenty-metre tree floating over the hill
			# (2026-09-04). Cap the longest side and sit it in the dirt.
			var scale: float = float(pick["scale"]) / float(ref["s_ref"])
			var longest: float = float(ref["longest"]) * scale
			if longest > CLUTTER_MAX_SIZE:
				scale *= CLUTTER_MAX_SIZE / longest
			var ground: float = (h0 + h1 + h2) / 3.0
			var pos := Vector3(at.x, ground - CLUTTER_SINK, -at.y)
			var chunk := Vector2i(int(floor(pos.x / CHUNK)), int(floor(pos.z / CHUNK)))
			var bkey: String = "%s|%d|%d" % [ref["key"], chunk.x, chunk.y]
			if not batches.has(bkey):
				batches[bkey] = {"ref": ref, "med": [], "high": [],
					"at": Vector3((float(chunk.x) + 0.5) * CHUNK, 0.0,
						(float(chunk.y) + 0.5) * CHUNK)}
			var batch: Dictionary = batches[bkey]
			var xf := Transform3D(
				Basis(Vector3.UP, float(pick["yaw"])).scaled(Vector3.ONE * scale),
				pos - (batch["at"] as Vector3))
			# Half of them are the MED set, and it comes FIRST in the
			# instance list, so a lower detail setting is one
			# visible_instance_count away — no second node, no second
			# draw call.
			(batch["med"] if rng.randf() < 0.5 else batch["high"]).append(xf)
			made += 1
		x += CLUTTER_SPACING

	var root := Node3D.new()
	root.name = "Detail"
	var props := Node3D.new()
	props.name = "Props"
	root.add_child(props)
	for bkey in batches:
		var batch: Dictionary = batches[bkey]
		var med: Array = batch["med"]
		var xforms: Array = med + (batch["high"] as Array)
		var ref: Dictionary = batch["ref"]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = ref["mesh"]
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%s" % [ref["key"], bkey.replace("|", "_")]
		mmi.multimesh = mm
		mmi.position = batch["at"]
		# Debris does not need to be in the shadow pass: it doubles the
		# draw calls for a few pixels of shade under a stump.
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.set_meta("med", med.size())
		range_limit(mmi, CLUTTER_DRAW_RANGE)
		props.add_child(mmi)

	var dust := Node3D.new()
	dust.name = "Dust"
	root.add_child(dust)
	rng.seed = hash(level.map_suffix)
	var centre: Vector3 = level.player_start
	for i in DUST_VOLUMES:
		var a: float = rng.randf() * TAU
		var r: float = 2000.0 + rng.randf() * 11000.0
		var at3 := Vector3(centre.x + cos(a) * r, 0.0, centre.z + sin(a) * r)
		at3.y = WldTerrain.height_at_world(level.wld, at3.x, -at3.z) \
			+ rng.randf_range(150.0, 700.0)
		FxParticles.dust_volume(dust, at3,
			DUST_SIZE * rng.randf_range(0.6, 1.4), rng.randf_range(0.02, 0.05))
	print("[level] detail: %d props in %d batches, %d dust banks over %.0fx%.0f u"
		% [made, batches.size(), dust.get_child_count(), hi.x - lo.x, hi.y - lo.y])
	return root

## One weighted pick from CLUTTER_PROPS: which model, how big, which way
## round. The scale and the yaw come from the replacement pack own
## fitting rules — the node is built, measured and dropped, so a prop
## ends up exactly where the per-node version put it.
static func _clutter_prop(rng: RandomNumberGenerator, total: float) -> Dictionary:
	var r: float = rng.randf() * total
	for c in CLUTTER_PROPS:
		r -= float(c[2])
		if r > 0.0:
			continue
		var bank: int = int(c[0])
		var rec: int = int(c[1])
		if not Replacements.has_sprite(bank, rec):
			return {}
		var rs: Vector2i = Assets.record_size(bank, rec)
		var px: float = 2.0 * rng.randf_range(0.8, 1.35)
		var fit: Dictionary = Replacements.sprite_fit(bank, rec,
			float(rs.x) * px, float(rs.y) * px, rng.randi())
		if fit.is_empty():
			return {}
		return {"bank": bank, "rec": rec, "yaw": fit["yaw"], "scale": fit["scale"]}
	return {}

## The shared mesh for one clutter model, built once and cached
## (converted/prop/P<bank>_<rec>.res). `s_ref` is the scale the
## replacement pack gave the reference instance, so a prop own scale
## divided by it is the factor that goes in the MultiMesh transform.
static func _prop_ref(bank: int, rec: int, cache: Dictionary) -> Dictionary:
	var key: String = "P%03d_%03d" % [bank, rec]
	if cache.has(key):
		return cache[key]
	var out: Dictionary = {}
	var tpl: Node3D = Replacements.sprite_node(bank, rec, 1000.0, 1000.0, 0)
	var fit: Dictionary = Replacements.sprite_fit(bank, rec, 1000.0, 1000.0, 0)
	if tpl != null and not fit.is_empty():
		tpl.rotation = Vector3.ZERO
		var s_ref: float = float(fit["scale"])
		var mesh := Assets.fetch("prop", key, func() -> Resource:
			var m: ArrayMesh = Replacements.with_lods(_flatten(tpl))
			_weather(m)
			return m) as ArrayMesh
		tpl.free()
		if mesh != null and s_ref > 0.0:
			var b: AABB = mesh.get_aabb()
			out = {"key": key, "mesh": mesh, "s_ref": s_ref,
				"longest": maxf(b.size.x, maxf(b.size.y, b.size.z))}
	cache[key] = out
	return out

## Every mesh under `root`, welded into one ArrayMesh in root space (one
## surface per source surface, materials kept).
static func _flatten(root: Node3D) -> ArrayMesh:
	var out := ArrayMesh.new()
	var stack: Array = [[root, Transform3D()]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is Node3D and n != root:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			for si in mi.mesh.get_surface_count():
				if mi.mesh.surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
					continue
				var arrays: Array = mi.mesh.surface_get_arrays(si)
				_place_arrays(arrays, xf)
				out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				out.surface_set_material(out.get_surface_count() - 1,
					mi.get_active_material(si))
		for c in n.get_children():
			stack.append([c, xf])
	return out

## Move a surface vertices (and the directions that go with them) into
## another space.
static func _place_arrays(arrays: Array, xf: Transform3D) -> void:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] = xf * verts[i]
	arrays[Mesh.ARRAY_VERTEX] = verts
	var nb: Basis = xf.basis.orthonormalized()
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in nrm.size():
			nrm[i] = nb * nrm[i]
		arrays[Mesh.ARRAY_NORMAL] = nrm
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var tan: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		var i: int = 0
		while i + 3 < tan.size():
			var t: Vector3 = nb * Vector3(tan[i], tan[i + 1], tan[i + 2])
			tan[i] = t.x
			tan[i + 1] = t.y
			tan[i + 2] = t.z
			i += 4
		arrays[Mesh.ARRAY_TANGENT] = tan

## Photo-scanned props come with a specular response tuned for daylight;
## under a night sky reflection they glint like wet plastic, and they are
## brighter and more saturated than the 256-colour world around them.
## Done once, on the shared mesh.
static func _weather(mesh: ArrayMesh) -> void:
	for si in mesh.get_surface_count():
		var m: Material = mesh.surface_get_material(si)
		if not (m is BaseMaterial3D):
			continue
		var d: BaseMaterial3D = (m as BaseMaterial3D).duplicate()
		d.albedo_color = d.albedo_color * Replacements.DEFAULT_TINT
		d.roughness = clampf(d.roughness + 0.35, 0.0, 1.0)
		d.metallic = 0.0
		d.metallic_specular = 0.15
		mesh.surface_set_material(si, d)

## Stop drawing a prop past `far`, fading it out over the last fifth so
## it never pops.
static func range_limit(n: Node, far: float) -> void:
	if n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		g.visibility_range_end = far
		g.visibility_range_end_margin = far * 0.2
		g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for c in n.get_children():
		range_limit(c, far)
