## ENHANCED replacement models (docs/implementation_plan.md §P.2).
##
## <converted>/enhanced_pack/replace.cfg maps DOS billboard sprites and placed .3D
## meshes to glTF models shipped in the pack (tools/enhanced_pack.py
## downloads CC0 models from Poly Haven and writes the file):
##
##   [sprites]
##   T204_001="models/Barrel_01/Barrel_01_1k.gltf|fit=h yaw=random"
##   [meshes]
##   TRUCK="models/covered_car/covered_car_1k.gltf"
##
## Options after `|`: fit=h (scale so the model is as tall as the DOS
## sprite, default) or fit=w (as wide), scale=<mul>, yaw=random|<deg>,
## tint=r,g,b (albedo multiplier so photo-scanned colours sit in the
## dusk palette). Models are loaded once per file through GLTFDocument
## (no editor import needed — the pack lives outside the project) and
## instanced by duplicating the generated scene.
extends RefCounted

const CFG_NAME: String = "replace.cfg"
const PickupModels := preload("res://scripts/pickup_models.gd")
const WeaponModels := preload("res://scripts/weapon_models.gd")
const FireEffect := preload("res://scripts/fire_effect.gd")

## ENHANCED: give a Pickup (a Sprite3D) a small 3D model instead of its
## billboard — the node keeps its logic, the texture is dropped.
## `world_w`/`world_h` = the DOS sprite's world size.
static func dress_pickup(p: Node3D, sprite_index: int, world_w: float, world_h: float) -> void:
	if not Render.enhanced():
		return
	# Guns get their own builder (weapon_models.gd); everything else is
	# the small-item one.
	var model: Node3D = null
	if WeaponModels.has(sprite_index):
		model = WeaponModels.build(sprite_index, world_w, world_h)
	elif PickupModels.has(sprite_index):
		model = PickupModels.build(sprite_index, world_w, world_h)
	if model == null:
		return
	p.set("texture", null)
	# The pickup node sits at the billboard's centre: drop the model so
	# its lowest point rests on the ground, give it a settled random yaw.
	var b: AABB = _measure(model)
	model.position.y = -world_h * 0.5 - b.position.y
	model.rotation.y = float(hash(sprite_index * 31 + int(p.position.x) + int(p.position.z)) % 628) / 100.0
	p.add_child(model)
	p.set("model", model)

static func is_fire(sprite_index: int) -> bool:
	return Render.enhanced() and FireEffect.is_fire(sprite_index)

## A shader fire standing in for a DOS fire billboard (base at origin).
static func fire_node(sprite_index: int, world_w: float, world_h: float, seed: int) -> Node3D:
	var f: Node3D = FireEffect.new()
	f.call("setup", sprite_index, world_w, world_h, seed)
	return f
## Default albedo multiplier — photo-scanned assets are brighter and
## more saturated than the 256-colour world around them.
const DEFAULT_TINT := Color(0.82, 0.78, 0.76)

static var _loaded: bool = false
static var _sprites: Dictionary = {}     # "T204_001" -> {path, opts}
static var _meshes: Dictionary = {}      # "TRUCK" -> {path, opts}
static var _scenes: Dictionary = {}      # abs path -> Node3D template (or null)
static var _bounds: Dictionary = {}      # abs path -> AABB of the template

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var dir: String = Render.override_dir()
	var cfg := ConfigFile.new()
	if cfg.load(dir + "/" + CFG_NAME) != OK:
		return
	for sec in ["sprites", "meshes"]:
		if not cfg.has_section(sec):
			continue
		for key in cfg.get_section_keys(sec):
			var v: String = String(cfg.get_value(sec, key, ""))
			if v.is_empty():
				continue
			var parts := v.split("|", true, 1)
			var rel: String = parts[0].strip_edges()
			var opts: Dictionary = {}
			if parts.size() > 1:
				for tok in parts[1].split(" ", false):
					var kv := tok.split("=", true, 1)
					if kv.size() == 2:
						opts[kv[0].strip_edges()] = kv[1].strip_edges()
			var entry := {"path": dir + "/" + rel, "opts": opts}
			if sec == "sprites":
				_sprites[key.to_upper()] = entry
			else:
				_meshes[key.to_upper()] = entry
	print("[enhanced] replacements: %d sprites, %d meshes (%s)" % [_sprites.size(), _meshes.size(), dir])

static func has_sprite(bank: int, rec: int) -> bool:
	if not Render.enhanced():
		return false
	_load()
	return _sprites.has("T%03d_%03d" % [bank, rec])

static func has_mesh(name: String) -> bool:
	if not Render.enhanced():
		return false
	_load()
	return _meshes.has(name.get_basename().to_upper())

## A model instance standing in for the billboard TEXTURE.<bank> record
## <rec>: its base is at the node origin (put it on the ground), scaled
## to the sprite's world size. `seed` picks the random yaw.
static func sprite_node(bank: int, rec: int, world_w: float, world_h: float, seed: int) -> Node3D:
	var e: Dictionary = _sprites.get("T%03d_%03d" % [bank, rec], {})
	if e.is_empty():
		return null
	return _instance(e, world_w, world_h, seed)

## A model standing in for the placed .3D mesh `name`, scaled to the DOS
## mesh's bounding box (its origin stays the entity origin).
static func mesh_node(name: String, dos_aabb: AABB, seed: int) -> Node3D:
	var e: Dictionary = _meshes.get(name.get_basename().to_upper(), {})
	if e.is_empty():
		return null
	var n := _instance(e, maxf(dos_aabb.size.x, dos_aabb.size.z), dos_aabb.size.y, seed)
	if n != null:
		n.position.y = dos_aabb.position.y
	return n

## How a replacement model would be placed, WITHOUT building it: the
## uniform scale that fits it to the billboard's world size and the yaw
## the pack asks for. The scenery bake places a thousand props a map and
## only wants those two numbers — instantiating each one, tinting it and
## throwing it away cost 60 ms a prop.
## Empty when there is no model for this record.
static func sprite_fit(bank: int, rec: int, world_w: float, world_h: float,
		seed: int) -> Dictionary:
	var e: Dictionary = _sprites.get("T%03d_%03d" % [bank, rec], {})
	if e.is_empty():
		return {}
	if _template(String(e["path"])) == null:
		return {}
	return {"scale": _fit_scale(e, world_w, world_h), "yaw": _fit_yaw(e, seed)}

static func _fit_scale(e: Dictionary, world_w: float, world_h: float) -> float:
	var opts: Dictionary = e["opts"]
	var b: AABB = _bounds[String(e["path"])]
	var s: float = 1.0
	if String(opts.get("fit", "h")) == "w" and maxf(b.size.x, b.size.z) > 0.0001:
		s = world_w / maxf(b.size.x, b.size.z)
	elif b.size.y > 0.0001:
		s = world_h / b.size.y
	return s * float(opts.get("scale", "1.0"))

static func _fit_yaw(e: Dictionary, seed: int) -> float:
	var yaw_opt: String = String((e["opts"] as Dictionary).get("yaw", "random"))
	if yaw_opt == "random":
		return float(hash(seed) % 3600) / 3600.0 * TAU
	return deg_to_rad(float(yaw_opt))

static func _instance(e: Dictionary, world_w: float, world_h: float, seed: int) -> Node3D:
	var tpl: Node3D = _template(String(e["path"]))
	if tpl == null:
		return null
	var opts: Dictionary = e["opts"]
	var b: AABB = _bounds[String(e["path"])]
	var s: float = _fit_scale(e, world_w, world_h)
	var root := Node3D.new()
	root.name = "Model"
	var inst: Node3D = tpl.duplicate()
	inst.scale = Vector3(s, s, s)
	# Base on the ground, centred on the origin.
	inst.position = Vector3(-b.get_center().x * s, -b.position.y * s, -b.get_center().z * s)
	root.add_child(inst)
	root.rotation.y = _fit_yaw(e, seed)
	# Per-instance tint (materials are shared: override on the instances).
	var tint: Color = DEFAULT_TINT
	if opts.has("tint"):
		var c := String(opts["tint"]).split(",")
		if c.size() >= 3:
			tint = Color(float(c[0]), float(c[1]), float(c[2]))
	if tint != Color(1, 1, 1):
		_tint(inst, tint)
	return root

static func _tint(n: Node, tint: Color) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			for si in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(si)
				if m is BaseMaterial3D:
					var d: BaseMaterial3D = (m as BaseMaterial3D).duplicate()
					d.albedo_color = d.albedo_color * tint
					mi.set_surface_override_material(si, d)
	for c in n.get_children():
		_tint(c, tint)

## Load (once) the glTF file as a scene template and measure it.
static func _template(path: String) -> Node3D:
	if _scenes.has(path):
		return _scenes[path]
	var node: Node3D = null
	if FileAccess.file_exists(path):
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		var err: int = doc.append_from_file(path, st)
		if err == OK:
			var gen: Node = doc.generate_scene(st)
			if gen is Node3D:
				node = gen
				_style(node)
			elif gen != null:
				gen.free()
		else:
			push_warning("[enhanced] cannot load %s (%s)" % [path, error_string(err)])
	else:
		push_warning("[enhanced] missing model %s" % path)
	_scenes[path] = node
	_bounds[path] = _measure(node) if node != null else AABB()
	if node != null:
		var b: AABB = _bounds[path]
		print("[enhanced] model %s size %.2fx%.2fx%.2f" % [path.get_file(), b.size.x, b.size.y, b.size.z])
	return node

## Give a mesh the level-of-detail chain Godot's own model importer
## would build for it, so a photo-scanned rock stops costing 60 000
## triangles once it is a hundred metres away.
##
## The pack's models are scenery scattered by the hundred: MAP.220 was
## submitting 26.5 MILLION primitives a frame with 262 of them placed,
## which is what made looking across the valley from the jeep stutter
## even though "there is nothing there" (2026-09-04). Nothing in the
## glTF files carries LODs, and a runtime-loaded mesh never goes through
## the importer, so it is done here — once per model, at load.
static func with_lods(src: ArrayMesh) -> ArrayMesh:
	if src == null or src.get_surface_count() == 0:
		return src
	var im := ImporterMesh.new()
	var made := 0
	for si in src.get_surface_count():
		if src.surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, src.surface_get_arrays(si),
			[], {}, src.surface_get_material(si), src.surface_get_name(si),
			src.surface_get_format(si))
		made += 1
	if made == 0:
		return src
	im.generate_lods(25.0, 60.0, [])
	var out: ArrayMesh = im.get_mesh()
	return out if out != null else src

static func _style(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh is ArrayMesh:
			mi.mesh = with_lods(mi.mesh as ArrayMesh)
		if mi.mesh != null:
			for si in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(si)
				if m is BaseMaterial3D:
					var bm := m as BaseMaterial3D
					bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
					bm.cull_mode = BaseMaterial3D.CULL_BACK
	for c in n.get_children():
		_style(c)

## Bounding box of every mesh under `root`, in root space.
static func _measure(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [[root, Transform3D()]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is Node3D and n != root:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var b: AABB = xf * (n as MeshInstance3D).mesh.get_aabb()
			if first:
				out = b
				first = false
			else:
				out = out.merge(b)
		for c in n.get_children():
			stack.append([c, xf])
	return out
