## ENHANCED stand-ins built from primitives for the sprites the CC0 pack
## has nothing for (docs §P.11, 2026-09-05: "nemôže byť problém nájsť
## nejaký pekný 3D model lampy a keď nie, tak niečo vymodelovať podľa
## toho spritu, tak isto lebky na zemi"):
##
##   TEXTURE.204 record 22   the twin-head floodlight mast — a pole, a
##                           crossbar, two heads with lit lenses, and a
##                           real lamp under them (the DOS sprite is a
##                           picture of a light, not a light)
##   TEXTURE.203 records     the skulls in the dirt: cranium, brow,
##   0 / 9 / 10 / 16 / 22    sockets, teeth — upright, on a cheek, face
##                           up or tilted, as the record's picture lies
##   TEXTURE.203 records     the heaps of skulls and bones (212×88 and
##   45 / 46                 228×156): a mound of them plus loose bones
##
## Poly Haven's street_lamp_01 is a Victorian gas lamp and it has no
## skull, so these are modelled here, the way pickup_models.gd builds
## the medkits and ammo: boxes, cylinders and spheres in the shared
## grime material, sized to the sprite they replace, base at the origin.

extends RefCounted

const PickupModels := preload("res://scripts/pickup_models.gd")

const LAMP: int = 204 << 7 | 22
const SKULLS: Array = [203 << 7 | 0, 203 << 7 | 9, 203 << 7 | 10, 203 << 7 | 16, 203 << 7 | 22]
const SKULL_PILES: Array = [203 << 7 | 45, 203 << 7 | 46]

const STEEL := Color(0.22, 0.24, 0.26)
const STEEL_DARK := Color(0.13, 0.14, 0.16)
const LENS := Color(1.0, 0.96, 0.84)
const BONE := Color(0.58, 0.53, 0.44)
const BONE_PALE := Color(0.66, 0.62, 0.53)
const BONE_DIRTY := Color(0.46, 0.41, 0.33)
const BONE_DARK := Color(0.07, 0.06, 0.05)
const TEETH := Color(0.7, 0.67, 0.58)
const LAMP_LIGHT := Color(1.0, 0.93, 0.78)

static func has(bank: int, rec: int) -> bool:
	var si: int = bank << 7 | rec
	return si == LAMP or SKULLS.has(si) or SKULL_PILES.has(si)

## The model for TEXTURE.<bank> record <rec>, `world_w` × `world_h`
## being the billboard it replaces. Base at the origin.
static func build(bank: int, rec: int, world_w: float, world_h: float, seed: int) -> Node3D:
	var si: int = bank << 7 | rec
	if si == LAMP:
		return lamp(world_w, world_h, seed)
	if SKULL_PILES.has(si):
		return skull_pile(world_w, world_h, seed, rec)
	return skull(world_w, world_h, seed, rec)

## The floodlight mast. The sprite is 168 × 656: a slim pole with two
## heads on a short crossbar at the very top, both aimed down and out.
static func lamp(world_w: float, world_h: float, seed: int) -> Node3D:
	var root := Node3D.new()
	root.name = "LampPost"
	var r: float = maxf(world_w * 0.055, 7.0)
	var top: float = world_h * 0.93
	PickupModels._cyl(root, r, top, STEEL, Vector3(0.0, top * 0.5, 0.0))
	PickupModels._cyl(root, r * 1.6, r * 1.2, STEEL_DARK, Vector3(0.0, r * 0.6, 0.0))   # the footing
	PickupModels._cyl(root, r * 1.15, r * 1.4, STEEL_DARK, Vector3(0.0, top, 0.0))       # the cap
	var bar: float = world_w * 0.78
	PickupModels._box(root, Vector3(bar, r * 1.1, r * 1.1), STEEL_DARK, Vector3(0.0, top - r * 0.5, 0.0))
	var head_w: float = world_w * 0.34
	var head_h: float = world_h * 0.062
	var head_d: float = world_w * 0.26
	for side in [-1.0, 1.0]:
		var head := Node3D.new()
		head.position = Vector3(side * bar * 0.5, top - r * 0.5 - head_h * 0.35, 0.0)
		# Tilted down and outward, the way the sprite's heads hang.
		head.rotation.z = -side * deg_to_rad(38.0)
		root.add_child(head)
		PickupModels._box(head, Vector3(head_w, head_h, head_d), STEEL, Vector3(0.0, 0.0, 0.0))
		# The lens: the lit face on the underside.
		PickupModels._box(head, Vector3(head_w * 0.82, head_h * 0.22, head_d * 0.78), LENS,
			Vector3(0.0, -head_h * 0.5, 0.0), true)
		# A hood over the lens.
		PickupModels._box(head, Vector3(head_w * 1.04, head_h * 0.3, head_d * 1.06), STEEL_DARK,
			Vector3(0.0, head_h * 0.45, 0.0))
	# The lamp itself: one pool of light under the heads, no shadow (a
	# street can carry a dozen of these).
	var l := OmniLight3D.new()
	l.name = "Light"
	l.position = Vector3(0.0, top - head_h * 2.0, 0.0)
	l.light_color = LAMP_LIGHT
	l.light_energy = Render.energy(2.5)          # a pool on the ground a mast's height below
	l.omni_range = clampf(world_h * 1.7, 900.0, 2400.0)
	l.omni_attenuation = Render.OMNI_DECAY
	l.light_specular = 0.35
	l.shadow_enabled = false
	l.add_to_group("maplight")
	root.add_child(l)
	root.add_to_group("lamp")            # agent aid: --near=lamp:N
	root.rotation.y = float(hash(seed) % 3600) / 3600.0 * TAU
	return root

# ---------------------------------------------------------------------
# Skulls
# ---------------------------------------------------------------------
## Every skull and heap is ONE MeshInstance3D: the primitives are merged
## into an ArrayMesh with a surface per colour (a heap of sixteen skulls
## would otherwise be two hundred draw calls, and MAP.210 has seventeen
## heaps). Low-poly spheres and boxes in the pickup grime material.
class Merger:
	var _tools: Dictionary = {}          # colour → SurfaceTool
	var _order: Array = []
	func add(mesh: Mesh, xform: Transform3D, col: Color) -> void:
		if not _tools.has(col):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			_tools[col] = st
			_order.append(col)
		(_tools[col] as SurfaceTool).append_from(mesh, 0, xform)
	func finish() -> ArrayMesh:
		var am := ArrayMesh.new()
		for col in _order:
			var st: SurfaceTool = _tools[col]
			am = st.commit(am)
			var m: StandardMaterial3D = PickupModels._mat(col)
			m.metallic = 0.0                 # bone is matte — the pickup grime
			m.roughness = 0.9                # material shines like a billiard ball
			m.metallic_specular = 0.2
			am.surface_set_material(am.get_surface_count() - 1, m)
		return am

static func _sph(r: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 10
	m.rings = 5
	return m

static func _bx(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m

static func _cy(r: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	m.radial_segments = 8
	return m

## One skull of radius R into `mg`, in the frame `T` (origin under the
## jaw, +Y up, +Z the face). Cranium set BACK so the face block, sockets
## and teeth stand proud of it — the first cut had them inside the ball
## and it read as a stone from three paces.
static func _skull_into(mg: Merger, R: float, T: Transform3D, bone: Color) -> void:
	# Cranium: an ellipsoid, longer than wide, set back of the face.
	mg.add(_sph(R), T * Transform3D(Basis.from_scale(Vector3(0.92, 0.86, 1.06)), Vector3(0.0, R * 0.98, -R * 0.18)), bone)
	# Brow and upper face.
	mg.add(_bx(Vector3(R * 1.2, R * 0.72, R * 0.7)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.62, R * 0.6)), bone)
	for side in [-1.0, 1.0]:
		# Cheekbone and the arch running back to the ear — wider than the
		# ball, so the skull has a face from the side too.
		mg.add(_bx(Vector3(R * 0.3, R * 0.42, R * 0.5)), T * Transform3D(Basis.IDENTITY, Vector3(side * R * 0.5, R * 0.5, R * 0.62)), bone)
		mg.add(_bx(Vector3(R * 0.2, R * 0.18, R * 0.8)), T * Transform3D(Basis.IDENTITY, Vector3(side * R * 0.6, R * 0.58, R * 0.2)), bone)
		# Sockets: dark hollows, large.
		mg.add(_sph(R * 0.34), T * Transform3D(Basis.from_scale(Vector3(1.0, 1.1, 0.8)), Vector3(side * R * 0.36, R * 0.88, R * 0.82)), BONE_DARK)
		# Mandible ramus (the hinge side of the jaw).
		mg.add(_bx(Vector3(R * 0.14, R * 0.42, R * 0.5)), T * Transform3D(Basis.IDENTITY, Vector3(side * R * 0.44, R * 0.26, R * 0.3)), bone)
	# Nasal hole.
	mg.add(_bx(Vector3(R * 0.26, R * 0.34, R * 0.22)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.5, R * 0.95)), BONE_DARK)
	# Upper teeth with dark gaps, the dark line of the bite, the chin.
	mg.add(_bx(Vector3(R * 0.9, R * 0.2, R * 0.3)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.28, R * 0.86)), TEETH)
	for k in 5:
		var x: float = (float(k) - 2.0) * R * 0.17
		mg.add(_bx(Vector3(R * 0.03, R * 0.16, R * 0.05)), T * Transform3D(Basis.IDENTITY, Vector3(x, R * 0.28, R * 1.03)), BONE_DARK)
	mg.add(_bx(Vector3(R * 0.95, R * 0.16, R * 0.5)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.1, R * 0.62)), bone)
	mg.add(_bx(Vector3(R * 0.9, R * 0.06, R * 0.1)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.19, R * 0.9)), BONE_DARK)

## A long bone lying flat: a shaft with a knob at each end.
static func _bone_into(mg: Merger, R: float, at: Vector3, yaw: float, bone: Color) -> void:
	var b := Basis.from_euler(Vector3(PI * 0.5, yaw, 0.0))     # the shaft along the ground
	var T := Transform3D(b, at)
	mg.add(_cy(R * 0.16, R * 2.2), T, bone)
	for e in [-1.0, 1.0]:
		var knob := Transform3D(Basis.from_scale(Vector3(1.4, 0.8, 1.0)), Vector3(0.0, e * R * 1.15, 0.0))
		mg.add(_sph(R * 0.26), T * knob, bone)

## The frame that puts a skull's centre (0, 0.9 R, 0.2 R) at `centre`
## with the given pitch/yaw/roll.
static func _skull_frame(R: float, centre: Vector3, pitch: float, yaw: float, roll: float) -> Transform3D:
	var b := Basis.from_euler(Vector3(pitch, yaw, roll))
	var c := Vector3(0.0, R * 0.9, R * 0.2)
	return Transform3D(b, centre - b * c)

static func _bone_shade(rng: RandomNumberGenerator) -> Color:
	var k: float = rng.randf()
	return BONE_PALE if k < 0.3 else (BONE_DIRTY if k > 0.75 else BONE)

## A skull in the dirt, sized to the sprite (36–56 px → a hand span),
## posed the way its record's picture lies: 9/16 upright at a settled
## tilt, 0 on a cheek, 10 face up, 22 tipped over. Random heading.
static func skull(world_w: float, world_h: float, seed: int, rec: int = 9) -> Node3D:
	var root := Node3D.new()
	root.name = "Skull"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var R: float = maxf(world_w, world_h) * 0.42
	var pitch: float = deg_to_rad(rng.randf_range(-14.0, 18.0))
	var roll: float = deg_to_rad(rng.randf_range(-12.0, 12.0))
	var rest: float = R * 0.78
	var hand: float = 1.0 if rng.randf() < 0.5 else -1.0
	match rec:
		0:                                   # on a cheek, face level
			roll = deg_to_rad(hand * 90.0 + rng.randf_range(-12.0, 12.0))
			rest = R * 0.82
		10:                                  # on a cheek, face turned up
			roll = deg_to_rad(hand * 70.0 + rng.randf_range(-8.0, 8.0))
			pitch = deg_to_rad(-25.0)
			rest = R * 0.85
		22:                                  # tipped over
			pitch = deg_to_rad(-35.0 + rng.randf_range(-10.0, 10.0))
			roll = deg_to_rad(hand * 40.0)
			rest = R * 0.88
	var mg := Merger.new()
	_skull_into(mg, R, _skull_frame(R, Vector3(0.0, rest, 0.0), pitch, rng.randf() * TAU, roll), _bone_shade(rng))
	var mi := MeshInstance3D.new()
	mi.mesh = mg.finish()
	root.add_child(mi)
	root.add_to_group("skull")           # agent aid: --near=skull:N
	return root

## A heap of skulls and bones: skull centres on a dome over an elliptical
## footprint the sprite's size, packed no closer than 1.5 R, every one at
## its own heading and tilt; loose bones around the foot. Record 45 is
## the low scatter (212×88), 46 the mound (228×156).
static func skull_pile(world_w: float, world_h: float, seed: int, rec: int = 46) -> Node3D:
	var root := Node3D.new()
	root.name = "SkullPile"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var big: bool = rec == 46
	var count: int = 16 if big else 9
	var R: float = world_h * (0.14 if big else 0.2)
	var a: float = world_w * 0.45                    # half width
	var b: float = world_w * 0.24                    # half depth
	var mound: float = maxf(world_h - 2.0 * R, R)    # dome height for the centres
	var mg := Merger.new()
	var placed: Array = []
	for k in count:
		var at := Vector3.ZERO
		var ok := false
		for attempt in 24:
			var x: float = rng.randf_range(-1.0, 1.0)
			var z: float = rng.randf_range(-1.0, 1.0)
			var rr: float = x * x + z * z
			if rr > 1.0:
				continue
			var y: float = R + mound * maxf(0.0, 1.0 - rr) * rng.randf_range(0.7, 1.0)
			at = Vector3(x * a, y, z * b)
			ok = true
			for q in placed:
				if (q as Vector3).distance_to(at) < R * 1.5:
					ok = false
					break
			if ok:
				break
		if not ok:
			continue
		placed.append(at)
		var r_k: float = R * rng.randf_range(0.85, 1.1)
		var frame := _skull_frame(r_k, at, deg_to_rad(rng.randf_range(-60.0, 40.0)), rng.randf() * TAU,
			deg_to_rad(rng.randf_range(-70.0, 70.0)))
		_skull_into(mg, r_k, frame, _bone_shade(rng))
	for k in (5 if big else 3):
		var ang: float = rng.randf() * TAU
		var f: float = rng.randf_range(0.75, 1.1)
		_bone_into(mg, R, Vector3(cos(ang) * a * f, R * 0.18, sin(ang) * b * f), rng.randf() * TAU, _bone_shade(rng))
	var mi := MeshInstance3D.new()
	mi.mesh = mg.finish()
	root.add_child(mi)
	root.rotation.y = rng.randf() * TAU
	root.add_to_group("skull")           # agent aid: --near=skull:N
	return root
