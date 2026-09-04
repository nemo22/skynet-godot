## ENHANCED pickup models (docs §P.3): the simple DOS items — medkits,
## energy cells and batteries, ammo boxes, grenades, bottles, rockets —
## as small primitive-built 3D models with emissive accents, sized to
## the sprite they replace and centred on the origin (the Pickup node
## bobs and spins them). Guns and armour vests stay billboards.
extends RefCounted

const RED := Color(0.7, 0.08, 0.07)
const WHITE := Color(0.78, 0.77, 0.72)
const OLIVE := Color(0.27, 0.3, 0.17)
const GREY := Color(0.36, 0.37, 0.39)
const DARK := Color(0.14, 0.15, 0.17)

## Procedural surface shared by every pickup material: value-noise
## grime with scratches as an albedo multiplier plus a normal map from
## it, mapped triplanar so boxes and cylinders need no UV care.
static var _grunge: Texture2D = null
static var _grunge_n: Texture2D = null

static func _surface() -> void:
	if _grunge != null:
		return
	var n: int = 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# Low-frequency blotches from a few random cosines, high-frequency grain.
	var ph: Array = []
	for _i in 6:
		ph.append([rng.randf() * TAU, rng.randf_range(2.0, 6.0), rng.randf_range(2.0, 6.0)])
	for y in n:
		for x in n:
			var u: float = float(x) / float(n)
			var v: float = float(y) / float(n)
			var g: float = 0.0
			for q in ph:
				g += sin(u * TAU * q[1] + q[0]) * cos(v * TAU * q[2] - q[0])
			g = 0.82 + g / 6.0 * 0.14 + rng.randf_range(-0.06, 0.06)
			img.set_pixel(x, y, Color(g, g, g))
	# Scratches: a few thin dark lines.
	for _s in 14:
		var x0: float = rng.randf() * n
		var y0: float = rng.randf() * n
		var ang: float = rng.randf() * TAU
		var ln: int = int(rng.randf_range(12.0, 40.0))
		for i in ln:
			var px: int = posmod(int(x0 + cos(ang) * i), n)   # % goes negative
			var py: int = posmod(int(y0 + sin(ang) * i), n)
			var c: Color = img.get_pixel(px, py)
			img.set_pixel(px, py, c * 0.72)
	img.generate_mipmaps()
	_grunge = ImageTexture.create_from_image(img)
	var nimg := img.duplicate()
	nimg.clear_mipmaps()
	nimg.bump_map_to_normal_map(3.0)
	nimg.generate_mipmaps()
	_grunge_n = ImageTexture.create_from_image(nimg)

## The shared grime texture and its normal map, for the other procedural
## model builders (weapon_models.gd) so every item wears the same wear.
static func grunge() -> Texture2D:
	_surface()
	return _grunge

static func grunge_normal() -> Texture2D:
	_surface()
	return _grunge_n

## sprite index → [builder, colour]
const MODELS: Dictionary = {
	27399: ["can", WHITE],                       # 214_007 health 50 %
	27400: ["medkit", Color(0.2, 0.3, 0.18)],    # 214_008 health 25 %
	27401: ["medkit", Color(0.24, 0.42, 0.22)],  # 214_009 health 10 %
	27402: ["medkit", Color(0.5, 0.52, 0.55)],   # 214_010 health 5 %
	27405: ["cell", DARK],                       # 214_013 energy 10
	27406: ["battery", Color(0.18, 0.22, 0.3)],  # 214_014 energy 25
	25601: ["crate", OLIVE],                     # 200_001 bullets 100
	25602: ["clip", DARK],                       # 200_002 bullets 25
	25603: ["canister", GREY],                   # 200_003 canister
	25604: ["crate", Color(0.36, 0.28, 0.18)],   # 200_004 satchel
	25605: ["bottle", Color(0.3, 0.5, 0.25)],    # 200_005 molotov
	25607: ["grenade", OLIVE],                   # 200_007 grenade
	25608: ["grenade", OLIVE],                   # 200_008 grenade
	25614: ["grenades", OLIVE],                  # 200_014 grenades
	25615: ["grenades", OLIVE],                  # 200_015 grenades
	25728: ["pipe", Color(0.35, 0.33, 0.3)],     # 201_000 pipe
	25735: ["crate", Color(0.55, 0.15, 0.12)],   # 201_007 shells
	25734: ["rocket", GREY],                     # 201_006 rocket
	25738: ["rockets", GREY],                    # 201_010 rockets
}

static func has(sprite_index: int) -> bool:
	return MODELS.has(sprite_index)

## A model `w` wide and `h` tall (world units), centred on the origin.
static func build(sprite_index: int, w: float, h: float) -> Node3D:
	var spec: Array = MODELS.get(sprite_index, [])
	if spec.is_empty():
		return null
	var root := Node3D.new()
	root.name = "PickupModel"
	var col: Color = spec[1]
	match String(spec[0]):
		"medkit":
			_box(root, Vector3(w, h * 0.7, w * 0.62), col, Vector3.ZERO)
			_cross(root, w * 0.45, Vector3(0.0, h * 0.35 + 1.0, 0.0), true)
			_cross(root, w * 0.3, Vector3(0.0, 0.0, w * 0.31 + 1.0), false)
			_box(root, Vector3(w * 0.36, h * 0.12, w * 0.16), DARK, Vector3(0.0, h * 0.35 + h * 0.06, 0.0))
		"can":
			_cyl(root, w * 0.5, h, col, Vector3.ZERO)
			_cross(root, w * 0.55, Vector3(0.0, 0.0, w * 0.5 + 1.0), false)
			_cyl(root, w * 0.52, h * 0.08, GREY, Vector3(0.0, h * 0.46, 0.0))
			_cyl(root, w * 0.52, h * 0.08, GREY, Vector3(0.0, -h * 0.46, 0.0))
		"cell":
			_cyl(root, w * 0.5, h * 0.9, col, Vector3.ZERO)
			_ring(root, w * 0.52, h * 0.07, Color(1.0, 0.15, 0.1), Vector3(0.0, h * 0.25, 0.0))
			_ring(root, w * 0.52, h * 0.07, Color(0.2, 1.0, 0.3), Vector3(0.0, -h * 0.1, 0.0))
			_cyl(root, w * 0.2, h * 0.14, GREY, Vector3(0.0, h * 0.5, 0.0))
		"battery":
			_box(root, Vector3(w, h * 0.55, w * 0.7), col, Vector3(0.0, -h * 0.2, 0.0))
			for i in 3:
				_cyl(root, w * 0.11, h * 0.45, Color(0.7, 0.45, 0.2), Vector3((float(i) - 1.0) * w * 0.3, h * 0.25, 0.0))
			_box(root, Vector3(w * 0.9, h * 0.06, w * 0.08), Color(0.3, 0.7, 1.0), Vector3(0.0, -h * 0.05, w * 0.36), true)
		"crate":
			_box(root, Vector3(w, h * 0.8, w * 0.6), col, Vector3(0.0, -h * 0.1, 0.0))
			_box(root, Vector3(w * 1.04, h * 0.2, w * 0.64), col.darkened(0.25), Vector3(0.0, h * 0.4, 0.0))
			_box(root, Vector3(w * 0.06, h * 0.82, w * 0.62), DARK, Vector3(-w * 0.3, -h * 0.1, 0.0))
			_box(root, Vector3(w * 0.06, h * 0.82, w * 0.62), DARK, Vector3(w * 0.3, -h * 0.1, 0.0))
		"clip":
			_box(root, Vector3(w, h, w * 0.5), col, Vector3.ZERO)
			_box(root, Vector3(w * 0.9, h * 0.25, w * 0.52), Color(0.75, 0.6, 0.3), Vector3(0.0, h * 0.4, 0.0))
		"canister":
			_cyl(root, w * 0.5, h * 0.85, col, Vector3(0.0, -h * 0.05, 0.0))
			_cyl(root, w * 0.25, h * 0.15, DARK, Vector3(0.0, h * 0.45, 0.0))
		"bottle":
			_cyl(root, w * 0.28, h * 0.6, col, Vector3(0.0, -h * 0.2, 0.0))
			_cyl(root, w * 0.12, h * 0.4, col, Vector3(0.0, h * 0.3, 0.0))
			_box(root, Vector3(w * 0.2, h * 0.16, w * 0.2), Color(0.9, 0.85, 0.6), Vector3(0.0, h * 0.5, 0.0))
		"grenade":
			_sphere(root, w * 0.5, col, Vector3(0.0, -h * 0.1, 0.0))
			_cyl(root, w * 0.18, h * 0.3, GREY, Vector3(0.0, h * 0.35, 0.0))
		"grenades":
			for i in 4:
				var a: float = float(i) * TAU / 4.0
				_sphere(root, w * 0.22, col, Vector3(cos(a) * w * 0.25, -h * 0.15, sin(a) * w * 0.25))
				_cyl(root, w * 0.08, h * 0.2, GREY, Vector3(cos(a) * w * 0.25, h * 0.12, sin(a) * w * 0.25))
		"pipe":
			var mi := _cyl(root, w * 0.5, h, col, Vector3.ZERO)
			mi.rotation.z = deg_to_rad(12.0)
		"rocket":
			var r := _cyl(root, h * 0.5, w, col, Vector3.ZERO)
			r.rotation.z = deg_to_rad(90.0)
			var tip := _cyl(root, h * 0.5, w * 0.25, RED, Vector3(w * 0.6, 0.0, 0.0))
			tip.rotation.z = deg_to_rad(90.0)
		"rockets":
			for i in 3:
				var z: float = (float(i) - 1.0) * h * 1.1
				var r := _cyl(root, h * 0.45, w * 0.85, col, Vector3(0.0, 0.0, z))
				r.rotation.z = deg_to_rad(90.0)
				var tip := _cyl(root, h * 0.45, w * 0.2, RED, Vector3(w * 0.5, 0.0, z))
				tip.rotation.z = deg_to_rad(90.0)
	return root

static func _mat(col: Color, glow: bool = false) -> StandardMaterial3D:
	_surface()
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.albedo_texture = _grunge
	m.normal_enabled = true
	m.normal_texture = _grunge_n
	m.normal_scale = 0.8
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.03, 0.03, 0.03)
	m.roughness = 0.72
	m.metallic = 0.25
	m.metallic_specular = 0.45
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if glow:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 2.0
	return m

static func _box(root: Node3D, size: Vector3, col: Color, at: Vector3, glow: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat(col, glow)
	mi.mesh = bm
	mi.position = at
	root.add_child(mi)
	return mi

static func _cyl(root: Node3D, radius: float, height: float, col: Color, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 12
	cm.material = _mat(col)
	mi.mesh = cm
	mi.position = at
	root.add_child(mi)
	return mi

static func _ring(root: Node3D, radius: float, height: float, col: Color, at: Vector3) -> MeshInstance3D:
	var mi := _cyl(root, radius, height, col, at)
	(mi.mesh as CylinderMesh).material = _mat(col, true)
	return mi

static func _sphere(root: Node3D, radius: float, col: Color, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	sm.material = _mat(col)
	mi.mesh = sm
	mi.position = at
	root.add_child(mi)
	return mi

## A red cross: two bars, flat on top (`flat`) or upright on a side.
static func _cross(root: Node3D, size: float, at: Vector3, flat: bool) -> void:
	var t: float = 1.5
	var arm: float = size * 0.3
	if flat:
		_box(root, Vector3(size, t, arm), RED, at, true)
		_box(root, Vector3(arm, t, size), RED, at, true)
	else:
		_box(root, Vector3(size, arm, t), RED, at, true)
		_box(root, Vector3(arm, size, t), RED, at, true)
