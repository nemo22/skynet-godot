## ENHANCED stand-ins built from primitives for the sprites the CC0 pack
## has nothing for (docs §P.11, 2026-09-05: "nemôže byť problém nájsť
## nejaký pekný 3D model lampy a keď nie, tak niečo vymodelovať podľa
## toho spritu, tak isto lebky na zemi"):
##
##   TEXTURE.204 record 22   the twin-head floodlight mast — a pole, a
##                           crossbar, two heads with lit lenses, and a
##                           real lamp under them (the DOS sprite is a
##                           picture of a light, not a light)
##   TEXTURE.203 records 9   the skulls in the dirt: cranium, brow,
##   and 16                  sockets, teeth, lying at a settled tilt
##
## Poly Haven's street_lamp_01 is a Victorian gas lamp and it has no
## skull, so these are modelled here, the way pickup_models.gd builds
## the medkits and ammo: boxes, cylinders and spheres in the shared
## grime material, sized to the sprite they replace, base at the origin.

extends RefCounted

const PickupModels := preload("res://scripts/pickup_models.gd")

const LAMP: int = 204 << 7 | 22
const SKULLS: Array = [203 << 7 | 9, 203 << 7 | 16]

const STEEL := Color(0.22, 0.24, 0.26)
const STEEL_DARK := Color(0.13, 0.14, 0.16)
const LENS := Color(1.0, 0.96, 0.84)
const BONE := Color(0.70, 0.66, 0.56)
const BONE_DARK := Color(0.09, 0.08, 0.07)
const LAMP_LIGHT := Color(1.0, 0.93, 0.78)

static func has(bank: int, rec: int) -> bool:
	var si: int = bank << 7 | rec
	return si == LAMP or SKULLS.has(si)

## The model for TEXTURE.<bank> record <rec>, `world_w` × `world_h`
## being the billboard it replaces. Base at the origin.
static func build(bank: int, rec: int, world_w: float, world_h: float, seed: int) -> Node3D:
	var si: int = bank << 7 | rec
	if si == LAMP:
		return lamp(world_w, world_h, seed)
	return skull(world_w, world_h, seed)

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

## A skull in the dirt. Sized to the sprite (36 × 44 → a hand span),
## lying on its jaw at a settled tilt with a random yaw.
static func skull(world_w: float, world_h: float, seed: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Skull"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var R: float = maxf(world_w, world_h) * 0.42
	var body := Node3D.new()
	root.add_child(body)
	# Cranium: a sphere set BACK, so its front (0.8 R) sits behind the
	# face — the first cut had the face inside the ball.
	var cr := PickupModels._sphere(body, R, BONE, Vector3(0.0, R * 0.98, -R * 0.2))
	cr.scale = Vector3(1.0, 0.9, 1.0)
	# Brow and face: a block in front of the cranium, front at 0.95 R.
	PickupModels._box(body, Vector3(R * 1.2, R * 0.72, R * 0.7), BONE, Vector3(0.0, R * 0.62, R * 0.6))
	# Cheekbones.
	for side in [-1.0, 1.0]:
		PickupModels._box(body, Vector3(R * 0.3, R * 0.42, R * 0.5), BONE, Vector3(side * R * 0.5, R * 0.5, R * 0.62))
	# Eye sockets and the nasal hole: dark domes and a dark wedge that
	# stand just proud of the face — big, or the thing reads as a ball
	# from three paces.
	for side in [-1.0, 1.0]:
		PickupModels._sphere(body, R * 0.3, BONE_DARK, Vector3(side * R * 0.36, R * 0.9, R * 0.8))
	PickupModels._box(body, Vector3(R * 0.26, R * 0.34, R * 0.22), BONE_DARK, Vector3(0.0, R * 0.5, R * 0.95))
	# Upper teeth: a light bar with dark gaps, and the jaw under it.
	PickupModels._box(body, Vector3(R * 0.9, R * 0.2, R * 0.3), Color(0.8, 0.78, 0.7), Vector3(0.0, R * 0.28, R * 0.86))
	for k in 5:
		var x: float = (float(k) - 2.0) * R * 0.17
		PickupModels._box(body, Vector3(R * 0.03, R * 0.16, R * 0.05), BONE_DARK, Vector3(x, R * 0.28, R * 1.03))
	PickupModels._box(body, Vector3(R * 0.95, R * 0.16, R * 0.5), BONE, Vector3(0.0, R * 0.1, R * 0.62))
	PickupModels._box(body, Vector3(R * 0.9, R * 0.06, R * 0.1), BONE_DARK, Vector3(0.0, R * 0.19, R * 0.9))
	# Settled in the dirt: a tilt, a roll and a random heading.
	body.rotation = Vector3(deg_to_rad(rng.randf_range(-14.0, 18.0)), 0.0, deg_to_rad(rng.randf_range(-12.0, 12.0)))
	body.position.y = -R * 0.12
	root.rotation.y = rng.randf() * TAU
	root.add_to_group("skull")           # agent aid: --near=skull:N
	return root
