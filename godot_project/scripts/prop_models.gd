## ENHANCED stand-ins built from primitives for the sprites the CC0 pack
## has nothing for (docs §P.11/§P.13). Marek, playtesting 2026-09-05:
## "to by sa tiež dalo nahradiť 3D modelom" — the corpses, the wrecked
## pram, the cans, bottles, rubble, papers, the hydrant, the armour.
##
##   TEXTURE.204 record 22   the twin-head floodlight mast (a real lamp)
##   TEXTURE.203             skulls (0/9/10/16/22) and skull heaps (45/46)
##   TEXTURE.202             the dead: bodies on their back (0, 1) and
##                           face down (3, 6), slumped sitting (2, 4),
##                           seated skeletons (7, 8), a bone (9), remains
##                           in blood (10–12), heads (13–15). 5 (the
##                           standing skeleton) stays a sprite.
##   TEXTURE.206             bottles (2, 3), a crushed can (4), bottles
##                           lying (5–9), concrete rubble (10–15)
##   TEXTURE.207             cans standing (0–2) and lying (3–10), a
##                           newspaper (11), a rag (12), wrecked prams
##                           (13–15)
##   TEXTURE.208             bent sign (1), hydrant (4), broken concrete
##                           ring (5), stop sign (6), broken lamp (7),
##                           pole (8), fallen sign (9)
##   TEXTURE.209             pipes: striped upright (0), lying (1–9), a
##                           T-piece (10), utility poles (11–13)
##   TEXTURE.210             rocks and rubble heaps (0–15)
##   TEXTURE.213 record 12   the burnt tree stump (the pack's tree_stump_01
##                           stretched to it "looked like a pork leg")
##
## Every prop is ONE MeshInstance3D: the primitives are merged into an
## ArrayMesh with a surface per material (`Merger`), sized to the sprite
## it replaces, base at the origin. A body's blood pool is a flat wet
## disc, a can is a cylinder with a lid — this is Doom-era clutter seen
## from three paces, not a museum.

extends RefCounted

const PickupModels := preload("res://scripts/pickup_models.gd")

const LAMP: int = 204 << 7 | 22
const SKULLS: Array = [203 << 7 | 0, 203 << 7 | 9, 203 << 7 | 10, 203 << 7 | 16, 203 << 7 | 22]
const SKULL_PILES: Array = [203 << 7 | 45, 203 << 7 | 46]

const STEEL := Color(0.22, 0.24, 0.26)
const STEEL_DARK := Color(0.13, 0.14, 0.16)
const TIN := Color(0.5, 0.51, 0.53)
const RED_PAINT := Color(0.5, 0.07, 0.05)
const RUST := Color(0.32, 0.18, 0.1)
const RUBBER := Color(0.05, 0.05, 0.05)
const GLASS_GREEN := Color(0.2, 0.42, 0.28)
const GLASS_BLUE := Color(0.22, 0.32, 0.5)
const PAPER := Color(0.8, 0.79, 0.74)
const RAG := Color(0.5, 0.46, 0.44)
const CONCRETE := Color(0.4, 0.38, 0.36)
const ROCK := Color(0.3, 0.29, 0.28)
const SKIN := Color(0.5, 0.38, 0.3)
const HAIR := Color(0.1, 0.08, 0.06)
const SUIT := Color(0.1, 0.1, 0.12)
const SHIRT := Color(0.45, 0.42, 0.38)
const DENIM := Color(0.2, 0.24, 0.32)
const BLOOD := Color(0.28, 0.02, 0.02)
const GORE := Color(0.42, 0.08, 0.06)
const TEAL := Color(0.14, 0.38, 0.4)
const WOOD := Color(0.25, 0.17, 0.1)
const SIGN_RED := Color(0.6, 0.1, 0.08)
const SIGN_WHITE := Color(0.8, 0.8, 0.78)
const LENS := Color(1.0, 0.96, 0.84)
const BONE := Color(0.58, 0.53, 0.44)
const BONE_PALE := Color(0.66, 0.62, 0.53)
const BONE_DIRTY := Color(0.46, 0.41, 0.33)
const BONE_DARK := Color(0.07, 0.06, 0.05)
const TEETH := Color(0.7, 0.67, 0.58)
const LAMP_LIGHT := Color(1.0, 0.93, 0.78)

## Which builder a sprite gets, "" for none.
static func kind_of(bank: int, rec: int) -> String:
	match bank:
		204:
			return "lamp" if rec == 22 else ""
		203:
			if rec in [0, 9, 10, 16, 22]:
				return "skull"
			return "skull_pile" if rec in [45, 46] else ""
		202:
			if rec in [0, 1]:
				return "body"
			if rec in [3, 6]:
				return "body_front"
			if rec in [2, 4]:
				return "sitting"
			if rec in [7, 8]:
				return "bones_sitting"
			if rec == 9:
				return "bone"
			if rec in [10, 11, 12]:
				return "parts"
			return "head" if rec in [13, 14, 15] else ""
		206:
			if rec in [2, 3]:
				return "bottle"
			if rec == 4:
				return "can_crushed"
			if rec >= 5 and rec <= 9:
				return "bottle_lying"
			return "rubble" if rec >= 10 and rec <= 15 else ""
		207:
			if rec <= 2:
				return "can"
			if rec <= 10:
				return "can_lying"
			if rec == 11:
				return "paper"
			if rec == 12:
				return "rag"
			return "pram" if rec <= 15 else ""
		208:
			match rec:
				1: return "sign_bent"
				4: return "hydrant"
				5: return "ring"
				6: return "sign"
				7: return "lamp_broken"
				8: return "pole"
				9: return "sign_fallen"
			return ""
		209:
			if rec == 0:
				return "pipe_up"
			if rec <= 9:
				return "pipe"
			if rec == 10:
				return "pipe_t"
			return "utility_pole" if rec <= 13 else ""
		210:
			return "rock" if rec <= 15 else ""
		213:
			return "burnt_trunk" if rec == 12 else ""
	return ""

static func has(bank: int, rec: int) -> bool:
	return kind_of(bank, rec) != ""

## The model for TEXTURE.<bank> record <rec>, `world_w` × `world_h`
## being the billboard it replaces. Base at the origin.
static func build(bank: int, rec: int, world_w: float, world_h: float, seed: int) -> Node3D:
	var kind: String = kind_of(bank, rec)
	match kind:
		"lamp": return lamp(world_w, world_h, seed)
		"skull": return skull(world_w, world_h, seed, rec)
		"skull_pile": return skull_pile(world_w, world_h, seed, rec)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var mg := Merger.new()
	var root := Node3D.new()
	root.name = kind.to_pascal_case()
	match kind:
		"body": _body(mg, world_w, world_h, rng, false, rec)
		"body_front": _body(mg, world_w, world_h, rng, true, rec)
		"sitting": _sitting(mg, world_w, world_h, rng, rec)
		"bones_sitting": _bones_sitting(mg, world_w, world_h, rng)
		"bone": _bone_into(mg, world_w * 0.3, Vector3(0.0, world_w * 0.05, 0.0), rng.randf() * TAU, BONE)
		"parts": _parts(mg, world_w, world_h, rng)
		"head": _head(mg, world_w, world_h, rng, rec)
		"bottle": _bottle(mg, world_w, world_h, rng, rec, false)
		"bottle_lying": _bottle(mg, world_w, world_h, rng, rec, true)
		"can": _can(mg, world_w, world_h, rng, rec, false, false)
		"can_lying": _can(mg, world_w, world_h, rng, rec, true, rec in [7, 8, 10])
		"can_crushed": _can(mg, world_w, world_h, rng, rec, true, true)
		"rubble": _rubble(mg, world_w, world_h, rng, rec)
		"rock": _rock(mg, world_w, world_h, rng)
		"paper": _paper(mg, world_w, world_h, rng, PAPER)
		"rag": _paper(mg, world_w, world_h, rng, RAG)
		"pram": _pram(mg, world_w, world_h, rng)
		"hydrant": _hydrant(mg, world_w, world_h)
		"ring": _ring(mg, world_w, world_h, rng)
		"sign": _sign(mg, world_w, world_h, rng, 0)
		"sign_bent": _sign(mg, world_w, world_h, rng, 1)
		"sign_fallen": _sign(mg, world_w, world_h, rng, 2)
		"lamp_broken": _lamp_broken(mg, world_w, world_h, rng)
		"pole": _pole(mg, world_w, world_h, rng, false)
		"utility_pole": _pole(mg, world_w, world_h, rng, true)
		"pipe_up": _pipe(mg, world_w, world_h, rng, 0)
		"pipe": _pipe(mg, world_w, world_h, rng, 1)
		"pipe_t": _pipe(mg, world_w, world_h, rng, 2)
		"burnt_trunk": _trunk(mg, world_w, world_h, rng)
		_:
			return null
	var mi := MeshInstance3D.new()
	mi.mesh = mg.finish()
	root.add_child(mi)
	# Free-standing clutter faces any way; the wall-hung things keep the
	# heading the map gives (none — so a hydrant is symmetric).
	if not kind in ["hydrant", "pipe_up", "pole", "utility_pole", "sign"]:
		root.rotation.y = rng.randf() * TAU
	root.add_to_group("prop")            # agent aid: --near=prop:N
	root.add_to_group("prop_" + kind)    #            --near=prop_body:N
	return root

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
	var _tools: Dictionary = {}          # "colour|style" → SurfaceTool
	var _order: Array = []
	## `style`: "" the pickup grime (painted metal), "matte" (bone, cloth,
	## paper, stone), "wet" (blood), "glass", "rubber".
	func add(mesh: Mesh, xform: Transform3D, col: Color, style: String = "") -> void:
		var key: String = "%s|%s" % [col.to_html(false), style]
		if not _tools.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			_tools[key] = st
			_order.append([key, col, style])
		(_tools[key] as SurfaceTool).append_from(mesh, 0, xform)
	func finish() -> ArrayMesh:
		var am := ArrayMesh.new()
		for e in _order:
			var st: SurfaceTool = _tools[e[0]]
			am = st.commit(am)
			am.surface_set_material(am.get_surface_count() - 1, material(e[1], e[2]))
		return am
	static func material(col: Color, style: String) -> StandardMaterial3D:
		var m: StandardMaterial3D = PickupModels._mat(col)
		match style:
			"matte":
				m.metallic = 0.0
				m.roughness = 0.9
				m.metallic_specular = 0.2
			"wet":
				m.metallic = 0.0
				m.roughness = 0.2
				m.metallic_specular = 0.7
			"glass":
				m.metallic = 0.1
				m.roughness = 0.15
				m.metallic_specular = 0.8
			"rubber":
				m.metallic = 0.0
				m.roughness = 0.75
				m.metallic_specular = 0.3
		return m

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
	mg.add(_sph(R), T * Transform3D(Basis.from_scale(Vector3(0.92, 0.86, 1.06)), Vector3(0.0, R * 0.98, -R * 0.18)), bone, "matte")
	# Brow and upper face.
	mg.add(_bx(Vector3(R * 1.2, R * 0.72, R * 0.7)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.62, R * 0.6)), bone, "matte")
	for side in [-1.0, 1.0]:
		# Cheekbone and the arch running back to the ear — wider than the
		# ball, so the skull has a face from the side too.
		mg.add(_bx(Vector3(R * 0.3, R * 0.42, R * 0.5)), T * Transform3D(Basis.IDENTITY, Vector3(side * R * 0.5, R * 0.5, R * 0.62)), bone, "matte")
		mg.add(_bx(Vector3(R * 0.2, R * 0.18, R * 0.8)), T * Transform3D(Basis.IDENTITY, Vector3(side * R * 0.6, R * 0.58, R * 0.2)), bone, "matte")
		# Sockets: dark hollows, large.
		mg.add(_sph(R * 0.34), T * Transform3D(Basis.from_scale(Vector3(1.0, 1.1, 0.8)), Vector3(side * R * 0.36, R * 0.88, R * 0.82)), BONE_DARK, "matte")
		# Mandible ramus (the hinge side of the jaw).
		mg.add(_bx(Vector3(R * 0.14, R * 0.42, R * 0.5)), T * Transform3D(Basis.IDENTITY, Vector3(side * R * 0.44, R * 0.26, R * 0.3)), bone, "matte")
	# Nasal hole.
	mg.add(_bx(Vector3(R * 0.26, R * 0.34, R * 0.22)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.5, R * 0.95)), BONE_DARK, "matte")
	# Upper teeth with dark gaps, the dark line of the bite, the chin.
	mg.add(_bx(Vector3(R * 0.9, R * 0.2, R * 0.3)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.28, R * 0.86)), TEETH, "matte")
	for k in 5:
		var x: float = (float(k) - 2.0) * R * 0.17
		mg.add(_bx(Vector3(R * 0.03, R * 0.16, R * 0.05)), T * Transform3D(Basis.IDENTITY, Vector3(x, R * 0.28, R * 1.03)), BONE_DARK, "matte")
	mg.add(_bx(Vector3(R * 0.95, R * 0.16, R * 0.5)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.1, R * 0.62)), bone, "matte")
	mg.add(_bx(Vector3(R * 0.9, R * 0.06, R * 0.1)), T * Transform3D(Basis.IDENTITY, Vector3(0.0, R * 0.19, R * 0.9)), BONE_DARK, "matte")

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

# ---------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------
static func _T(pos: Vector3, euler: Vector3 = Vector3.ZERO, scale: Vector3 = Vector3.ONE) -> Transform3D:
	return Transform3D(_scaled_local(Basis.from_euler(euler), scale), pos)

## Scale along the basis's OWN axes. Basis.scaled() in Godot 4 scales along
## the WORLD axes — measured: looking_at(+X).scaled(4,4,1) comes back with
## |z| = 4, the long axis stretched instead of kept. On a tilted part that
## squashes it the wrong way (the hair on a lolling head, the flattened
## side of a charred branch).
static func _scaled_local(b: Basis, s: Vector3) -> Basis:
	return Basis(b.x * s.x, b.y * s.y, b.z * s.z)

## A cylinder along its local Y, wrapped so it runs from `a` to `b`.
static func _rod(mg: Merger, a: Vector3, b: Vector3, r: float, col: Color, style: String = "") -> void:
	var d: Vector3 = b - a
	var len: float = d.length()
	if len < 0.01:
		return
	var up := Vector3.UP
	var dir := d / len
	var basis := Basis.IDENTITY
	if absf(dir.dot(up)) < 0.999:
		var x := up.cross(dir).normalized()
		var z := x.cross(dir).normalized()
		basis = Basis(x, dir, z)
	mg.add(_cy(r, len), Transform3D(basis, (a + b) * 0.5), col, style)

## A flat wet pool on the ground, `rx` × `rz`.
static func _pool(mg: Merger, at: Vector3, rx: float, rz: float, rng: RandomNumberGenerator) -> void:
	var m := CylinderMesh.new()
	m.top_radius = 1.0
	m.bottom_radius = 1.0
	m.height = 1.2
	m.radial_segments = 14
	mg.add(m, _T(at + Vector3(0.0, 0.6, 0.0), Vector3(0.0, rng.randf() * TAU, 0.0), Vector3(rx, 1.0, rz)), BLOOD, "wet")
	# A couple of smaller splashes off the main pool.
	for k in 2:
		var a: float = rng.randf() * TAU
		var f: float = rng.randf_range(0.9, 1.3)
		mg.add(m, _T(at + Vector3(cos(a) * rx * f, 0.5, sin(a) * rz * f), Vector3.ZERO,
			Vector3(rx * 0.3, 1.0, rz * 0.3)), BLOOD, "wet")

# ---------------------------------------------------------------------
# The dead (TEXTURE.202)
# ---------------------------------------------------------------------
## A body lying along local X, head at -X, `front` = face down. L is the
## body length (the sprite's width), the sprite's height is mostly the
## pool and a raised arm.
static func _body(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, front: bool, rec: int) -> void:
	var L: float = w * 0.9
	var t: float = maxf(h * 0.28, L * 0.11)          # body thickness on the ground
	var coat: Color = SUIT if rec in [0, 1] else (DENIM if rec == 3 else SHIRT)
	var trousers: Color = SUIT if rec in [0, 1] else DENIM
	_pool(mg, Vector3(-L * 0.1, 0.0, 0.0), L * 0.42, L * 0.26, rng)
	# Torso and pelvis.
	mg.add(_bx(Vector3(L * 0.3, t, L * 0.2)), _T(Vector3(-L * 0.12, t * 0.5, 0.0)), coat, "matte")
	mg.add(_bx(Vector3(L * 0.16, t * 0.9, L * 0.18)), _T(Vector3(L * 0.1, t * 0.45, 0.0)), trousers, "matte")
	if not front and rec in [0, 1]:
		# The shirt front of the suit.
		mg.add(_bx(Vector3(L * 0.2, t * 1.02, L * 0.07)), _T(Vector3(-L * 0.13, t * 0.5, 0.0)), SHIRT, "matte")
	# Head.
	var hr: float = L * 0.07
	mg.add(_sph(hr), _T(Vector3(-L * 0.36, hr * 0.95, rng.randf_range(-0.03, 0.03) * L), Vector3.ZERO,
		Vector3(1.0, 0.9, 1.1)), SKIN if not front else HAIR, "matte")
	if not front:
		mg.add(_sph(hr * 1.02), _T(Vector3(-L * 0.37, hr * 0.95, 0.0), Vector3.ZERO, Vector3(0.9, 0.55, 1.0)), HAIR, "matte")
	# Arms: one flung out, one along the body.
	var sh := Vector3(-L * 0.25, t * 0.6, 0.0)
	var side: float = 1.0 if rng.randf() < 0.5 else -1.0
	_rod(mg, sh + Vector3(0.0, 0.0, side * L * 0.1), sh + Vector3(-L * 0.12, -t * 0.3, side * L * 0.36), L * 0.028, coat, "matte")
	mg.add(_sph(L * 0.03), _T(sh + Vector3(-L * 0.13, -t * 0.35, side * L * 0.38)), SKIN, "matte")
	_rod(mg, sh + Vector3(0.0, 0.0, -side * L * 0.1), sh + Vector3(L * 0.22, -t * 0.3, -side * L * 0.15), L * 0.028, coat, "matte")
	mg.add(_sph(L * 0.03), _T(sh + Vector3(L * 0.24, -t * 0.35, -side * L * 0.16)), SKIN, "matte")
	# Legs, a little apart, boots at the far end.
	for k in [-1.0, 1.0]:
		var hip := Vector3(L * 0.16, t * 0.45, k * L * 0.06)
		var foot := Vector3(L * 0.46, t * 0.35, k * L * (0.1 + rng.randf() * 0.06))
		_rod(mg, hip, foot, L * 0.035, trousers, "matte")
		mg.add(_bx(Vector3(L * 0.07, t * 0.6, L * 0.045)), _T(foot + Vector3(L * 0.02, 0.0, 0.0)), HAIR, "matte")
	if rec == 1 or rec == 6:
		# A wound: a dark gore patch on the torso.
		mg.add(_bx(Vector3(L * 0.12, t * 0.2, L * 0.12)), _T(Vector3(-L * 0.08, t * 1.0, L * 0.02)), GORE, "wet")

## Slumped sitting against nothing in particular: legs out along +X.
static func _sitting(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, rec: int) -> void:
	var H: float = h * 0.95                    # seated height
	var L: float = w * 0.9
	var coat: Color = SHIRT if rec == 2 else SUIT
	_pool(mg, Vector3(L * 0.05, 0.0, 0.0), L * 0.3, L * 0.3, rng)
	# Torso leaning back a little, head dropped forward.
	mg.add(_bx(Vector3(L * 0.22, H * 0.45, L * 0.32)), _T(Vector3(-L * 0.12, H * 0.42, 0.0), Vector3(0.0, 0.0, deg_to_rad(12.0))), coat, "matte")
	mg.add(_bx(Vector3(L * 0.2, H * 0.14, L * 0.34)), _T(Vector3(-L * 0.06, H * 0.14, 0.0)), DENIM, "matte")
	var hr: float = H * 0.11
	mg.add(_sph(hr), _T(Vector3(-L * 0.02, H * 0.62, 0.0), Vector3.ZERO, Vector3(1.0, 0.95, 1.05)), SKIN, "matte")
	mg.add(_sph(hr * 1.02), _T(Vector3(-L * 0.04, H * 0.65, 0.0), Vector3.ZERO, Vector3(1.0, 0.55, 1.0)), HAIR, "matte")
	# Legs out, knees a little bent, arms in the lap / on the floor.
	for k in [-1.0, 1.0]:
		var hip := Vector3(0.0, H * 0.14, k * L * 0.09)
		var knee := Vector3(L * 0.2, H * 0.2, k * L * 0.12)
		var foot := Vector3(L * 0.42, H * 0.06, k * L * 0.14)
		_rod(mg, hip, knee, L * 0.05, DENIM, "matte")
		_rod(mg, knee, foot, L * 0.045, DENIM, "matte")
		mg.add(_bx(Vector3(L * 0.1, H * 0.1, L * 0.06)), _T(foot + Vector3(L * 0.03, 0.0, 0.0)), HAIR, "matte")
		var sh := Vector3(-L * 0.1, H * 0.6, k * L * 0.17)
		var hand := Vector3(L * 0.12, H * 0.08, k * L * (0.2 + rng.randf() * 0.06))
		_rod(mg, sh, hand, L * 0.035, coat, "matte")
		mg.add(_sph(L * 0.035), _T(hand), SKIN, "matte")
	mg.add(_bx(Vector3(L * 0.1, H * 0.16, L * 0.14)), _T(Vector3(-L * 0.02, H * 0.45, 0.0)), GORE, "wet")

## A seated skeleton: skull on a ribcage, leg bones out.
static func _bones_sitting(mg: Merger, w: float, h: float, rng: RandomNumberGenerator) -> void:
	var H: float = h * 0.95
	var L: float = w * 0.9
	var R: float = H * 0.12
	# Spine, ribs, pelvis.
	_rod(mg, Vector3(-L * 0.08, H * 0.12, 0.0), Vector3(-L * 0.14, H * 0.62, 0.0), R * 0.14, BONE, "matte")
	for i in 5:
		var y: float = H * (0.3 + 0.065 * float(i))
		var rr: float = L * (0.16 - 0.012 * float(i))
		var ring := TorusMesh.new()
		ring.inner_radius = rr - R * 0.1
		ring.outer_radius = rr + R * 0.1
		ring.rings = 10
		ring.ring_segments = 6
		mg.add(ring, _T(Vector3(-L * 0.1 - float(i) * L * 0.01, y, 0.0), Vector3(0.0, 0.0, deg_to_rad(80.0)), Vector3(1.0, 1.0, 1.3)), BONE, "matte")
	mg.add(_bx(Vector3(L * 0.14, H * 0.12, L * 0.3)), _T(Vector3(-L * 0.06, H * 0.14, 0.0)), BONE_DIRTY, "matte")
	_skull_into(mg, R, _skull_frame(R, Vector3(-L * 0.1, H * 0.72, 0.0), deg_to_rad(35.0), deg_to_rad(90.0), 0.0), BONE)
	for k in [-1.0, 1.0]:
		_rod(mg, Vector3(0.0, H * 0.12, k * L * 0.1), Vector3(L * 0.24, H * 0.14, k * L * 0.14), R * 0.16, BONE, "matte")
		_rod(mg, Vector3(L * 0.24, H * 0.14, k * L * 0.14), Vector3(L * 0.44, H * 0.04, k * L * 0.16), R * 0.14, BONE, "matte")
		_rod(mg, Vector3(-L * 0.12, H * 0.58, k * L * 0.16), Vector3(L * 0.1, H * 0.06, k * L * (0.2 + rng.randf() * 0.05)), R * 0.11, BONE, "matte")

## Remains: a pool with a limb or two and a hand.
static func _parts(mg: Merger, w: float, h: float, rng: RandomNumberGenerator) -> void:
	var L: float = w * 0.9
	_pool(mg, Vector3.ZERO, L * 0.45, L * 0.3, rng)
	var a := Vector3(-L * 0.3, L * 0.03, 0.0)
	var b := Vector3(L * 0.1, L * 0.04, L * 0.08)
	_rod(mg, a, b, L * 0.045, DENIM, "matte")
	mg.add(_bx(Vector3(L * 0.1, L * 0.08, L * 0.06)), _T(a + Vector3(-L * 0.04, L * 0.01, 0.0)), HAIR, "matte")
	mg.add(_bx(Vector3(L * 0.1, L * 0.07, L * 0.09)), _T(b + Vector3(L * 0.03, 0.0, 0.0)), GORE, "wet")
	var c := Vector3(L * 0.12, L * 0.03, -L * 0.12)
	_rod(mg, c, c + Vector3(L * 0.22, 0.0, L * 0.05), L * 0.03, SKIN, "matte")
	mg.add(_sph(L * 0.035), _T(c + Vector3(L * 0.24, L * 0.005, L * 0.055)), SKIN, "matte")

## A severed head in its pool.
static func _head(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, rec: int) -> void:
	var r: float = minf(w, h) * 0.3
	_pool(mg, Vector3.ZERO, w * 0.42, h * 0.3, rng)
	var tilt := Vector3(deg_to_rad(rng.randf_range(-25.0, 25.0)), 0.0, deg_to_rad(rng.randf_range(60.0, 100.0) * (1.0 if rng.randf() < 0.5 else -1.0)))
	var skin: Color = SKIN if rec != 14 else Color(0.62, 0.55, 0.42)
	mg.add(_sph(r), _T(Vector3(0.0, r * 0.9, 0.0), tilt, Vector3(1.0, 1.1, 0.95)), skin, "matte")
	var b := Basis.from_euler(tilt)
	mg.add(_sph(r * 1.02), Transform3D(_scaled_local(b, Vector3(1.0, 0.5, 1.0)), Vector3(0.0, r * 0.9, 0.0) + b * Vector3(0.0, r * 0.55, -r * 0.1)), HAIR, "matte")
	for side in [-1.0, 1.0]:
		mg.add(_sph(r * 0.18), Transform3D(b, Vector3(0.0, r * 0.9, 0.0) + b * Vector3(side * r * 0.36, r * 0.15, r * 0.85)), BONE_DARK, "matte")
	mg.add(_bx(Vector3(r * 0.5, r * 0.14, r * 0.2)), Transform3D(b, Vector3(0.0, r * 0.9, 0.0) + b * Vector3(0.0, -r * 0.35, r * 0.85)), GORE, "wet")
	mg.add(_sph(r * 0.7), _T(Vector3(0.0, r * 0.9, 0.0) + b * Vector3(0.0, -r * 0.9, 0.0), Vector3.ZERO, Vector3(1.0, 0.35, 1.0)), GORE, "wet")

# ---------------------------------------------------------------------
# Bottles, cans, rubbish (TEXTURE.206 / 207)
# ---------------------------------------------------------------------
static func _bottle(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, rec: int, lying: bool) -> void:
	var glass: Color = GLASS_GREEN if rec in [2, 5, 6, 7] else GLASS_BLUE
	var L: float = maxf(w, h)                    # bottle length
	var r: float = L * 0.14
	var T := Transform3D.IDENTITY
	if lying:
		T = _T(Vector3(0.0, r, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)))
	else:
		T = _T(Vector3(0.0, 0.0, 0.0))
	mg.add(_cy(r, L * 0.5), T * _T(Vector3(0.0, L * 0.25, 0.0)), glass, "glass")
	mg.add(_sph(r), T * _T(Vector3(0.0, L * 0.5, 0.0), Vector3.ZERO, Vector3(1.0, 0.7, 1.0)), glass, "glass")
	mg.add(_cy(r * 0.38, L * 0.32), T * _T(Vector3(0.0, L * 0.7, 0.0)), glass, "glass")
	mg.add(_cy(r * 0.42, L * 0.06), T * _T(Vector3(0.0, L * 0.87, 0.0)), STEEL_DARK)
	# The label.
	mg.add(_cy(r * 1.02, L * 0.18), T * _T(Vector3(0.0, L * 0.26, 0.0)), PAPER, "matte")

static func _can(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, rec: int, lying: bool, crushed: bool) -> void:
	var L: float = maxf(w, h)                    # can height
	var r: float = minf(w, h) * 0.42
	var red: bool = rec in [0, 2, 3, 6, 7, 10]
	var T := Transform3D.IDENTITY
	if lying:
		T = _T(Vector3(0.0, r * (0.7 if crushed else 1.0), 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)),
			Vector3(1.0, 1.0, 0.65) if crushed else Vector3.ONE)
	mg.add(_cy(r, L * 0.92), T * _T(Vector3(0.0, L * 0.46, 0.0)), TIN)
	if red:
		mg.add(_cy(r * 1.02, L * 0.5), T * _T(Vector3(0.0, L * 0.46, 0.0)), RED_PAINT)
	mg.add(_cy(r * 0.92, L * 0.02), T * _T(Vector3(0.0, L * 0.93, 0.0)), STEEL_DARK)
	mg.add(_cy(r * 0.9, L * 0.02), T * _T(Vector3(0.0, L * 0.005, 0.0)), STEEL_DARK)
	if crushed:
		# A dent.
		mg.add(_bx(Vector3(r * 1.2, L * 0.25, r * 0.6)), T * _T(Vector3(r * 0.5, L * 0.5, 0.0), Vector3(0.0, 0.0, deg_to_rad(20.0))), TIN)

## Concrete rubble: one to three broken blocks.
static func _rubble(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, rec: int) -> void:
	var n: int = 3 if rec == 10 else (2 if rec in [11, 12] else 1)
	for i in n:
		var sx: float = w * rng.randf_range(0.35, 0.6) / float(n) * (1.6 if n > 1 else 1.0)
		var sy: float = h * rng.randf_range(0.5, 0.85)
		var sz: float = w * rng.randf_range(0.25, 0.45)
		var x: float = (float(i) - float(n - 1) * 0.5) * w * 0.32
		var col: Color = CONCRETE.darkened(rng.randf_range(0.0, 0.25))
		mg.add(_bx(Vector3(sx, sy, sz)), _T(Vector3(x, sy * 0.45, rng.randf_range(-0.1, 0.1) * w),
			Vector3(deg_to_rad(rng.randf_range(-8.0, 8.0)), rng.randf_range(-0.4, 0.4), deg_to_rad(rng.randf_range(-10.0, 10.0)))), col, "matte")
		# Rebar stubs out of the bigger blocks.
		if sx > w * 0.25:
			_rod(mg, Vector3(x + sx * 0.4, sy * 0.5, 0.0), Vector3(x + sx * 0.4 + sx * 0.3, sy * 0.4, sz * 0.2), maxf(sx * 0.02, 1.0), RUST)

## A rock: overlapping flattened spheres in stone grey.
static func _rock(mg: Merger, w: float, h: float, rng: RandomNumberGenerator) -> void:
	var n: int = 3 if w > h * 1.5 else 2
	for i in n:
		var rx: float = w * rng.randf_range(0.28, 0.42) / (1.0 if n == 1 else 1.3)
		var ry: float = h * rng.randf_range(0.42, 0.55)
		var rz: float = rx * rng.randf_range(0.7, 1.0)
		var x: float = (float(i) - float(n - 1) * 0.5) * w * 0.28
		var col: Color = ROCK.lightened(rng.randf_range(-0.08, 0.12))
		mg.add(_sph(1.0), _T(Vector3(x, ry * 0.75, rng.randf_range(-0.08, 0.08) * w),
			Vector3(0.0, rng.randf() * TAU, deg_to_rad(rng.randf_range(-12.0, 12.0))), Vector3(rx, ry, rz)), col, "matte")
	# A sharp piece.
	mg.add(_bx(Vector3(w * 0.25, h * 0.4, w * 0.2)), _T(Vector3(w * 0.1, h * 0.2, w * 0.05),
		Vector3(deg_to_rad(20.0), rng.randf() * TAU, deg_to_rad(25.0))), ROCK, "matte")

## A newspaper or rag on the ground: two thin sheets, one lifted at a fold.
static func _paper(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, col: Color) -> void:
	var s: float = w * 0.5
	mg.add(_bx(Vector3(s, 0.8, s * 0.7)), _T(Vector3(0.0, 0.5, 0.0), Vector3(0.0, rng.randf_range(-0.3, 0.3), 0.0)), col, "matte")
	mg.add(_bx(Vector3(s * 0.7, 0.8, s * 0.6)), _T(Vector3(s * 0.25, s * 0.12, s * 0.1),
		Vector3(deg_to_rad(8.0), rng.randf_range(-0.6, 0.6), deg_to_rad(-22.0))), col, "matte")
	mg.add(_bx(Vector3(s * 0.4, 0.8, s * 0.5)), _T(Vector3(-s * 0.3, s * 0.05, -s * 0.1),
		Vector3(deg_to_rad(-12.0), rng.randf_range(-0.6, 0.6), deg_to_rad(6.0))), col.darkened(0.15), "matte")

## The wrecked pram: a body on bent legs, a hood, wheels — one off.
static func _pram(mg: Merger, w: float, h: float, rng: RandomNumberGenerator) -> void:
	var bw: float = w * 0.5                      # body length (x)
	var bd: float = w * 0.32                     # body width (z)
	var by: float = h * 0.42                     # body bottom height
	var bh: float = h * 0.24
	var tilt := Vector3(0.0, 0.0, deg_to_rad(-9.0))      # sagging to the broken wheel
	var B := _T(Vector3(0.0, by, 0.0), tilt)
	mg.add(_bx(Vector3(bw, bh, bd)), B * _T(Vector3(0.0, bh * 0.5, 0.0)), SUIT, "matte")
	mg.add(_bx(Vector3(bw * 0.9, bh * 0.15, bd * 0.85)), B * _T(Vector3(0.0, bh * 0.98, 0.0)), TEAL, "matte")
	# Hood: a half-drum over the back.
	mg.add(_cy(bd * 0.55, bw * 0.45), B * _T(Vector3(-bw * 0.28, bh * 0.9, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)), Vector3(1.0, 1.0, 0.8)), SUIT, "matte")
	# Handle: two rods up and back, a bar across.
	var hb := B * Vector3(-bw * 0.5, bh * 0.4, 0.0)
	var ht := B * Vector3(-bw * 0.8, bh * 2.6, 0.0)
	for k in [-1.0, 1.0]:
		_rod(mg, hb + Vector3(0.0, 0.0, k * bd * 0.35), ht + Vector3(0.0, 0.0, k * bd * 0.35), w * 0.012, STEEL_DARK)
	_rod(mg, ht + Vector3(0.0, 0.0, -bd * 0.35), ht + Vector3(0.0, 0.0, bd * 0.35), w * 0.015, RUBBER, "rubber")
	# Legs and wheels.
	var wr: float = h * 0.11
	var wheel := TorusMesh.new()
	wheel.inner_radius = wr * 0.8
	wheel.outer_radius = wr
	wheel.rings = 14
	wheel.ring_segments = 6
	var i := 0
	for x in [-bw * 0.35, bw * 0.35]:
		for k in [-1.0, 1.0]:
			var top := B * Vector3(x, 0.0, k * bd * 0.3)
			var missing: bool = i == 3
			var axle := Vector3(x * 1.1, wr, k * bd * 0.5)
			if missing:
				axle = Vector3(x * 1.1, wr * 0.35, k * bd * 0.55)
			_rod(mg, top, axle, w * 0.012, STEEL_DARK)
			if not missing:
				mg.add(wheel, _T(axle, Vector3(deg_to_rad(90.0 + rng.randf_range(-8.0, 8.0)), 0.0, 0.0)), RUBBER, "rubber")
				for sp in 3:
					var ang: float = float(sp) * TAU / 3.0
					_rod(mg, axle + Vector3(cos(ang) * wr * 0.8, sin(ang) * wr * 0.8, 0.0), axle - Vector3(cos(ang) * wr * 0.8, sin(ang) * wr * 0.8, 0.0), w * 0.005, TIN)
			i += 1
	# The lost wheel lies beside.
	mg.add(wheel, _T(Vector3(bw * 0.7, wr * 0.1, bd * 0.7), Vector3(0.0, rng.randf() * TAU, 0.0)), RUBBER, "rubber")

# ---------------------------------------------------------------------
# Street furniture (TEXTURE.208 / 209)
# ---------------------------------------------------------------------
static func _hydrant(mg: Merger, w: float, h: float) -> void:
	var r: float = w * 0.24
	mg.add(_cy(r * 1.3, h * 0.06), _T(Vector3(0.0, h * 0.03, 0.0)), RED_PAINT)
	mg.add(_cy(r, h * 0.62), _T(Vector3(0.0, h * 0.37, 0.0)), RED_PAINT)
	mg.add(_cy(r * 1.15, h * 0.05), _T(Vector3(0.0, h * 0.7, 0.0)), RED_PAINT)
	mg.add(_sph(r * 1.05), _T(Vector3(0.0, h * 0.74, 0.0), Vector3.ZERO, Vector3(1.0, 0.9, 1.0)), RED_PAINT)
	mg.add(_cy(r * 0.3, h * 0.08), _T(Vector3(0.0, h * 0.94, 0.0)), STEEL_DARK)
	# Side outlets with their caps and the front one.
	for k in [-1.0, 1.0]:
		mg.add(_cy(r * 0.42, r * 1.1), _T(Vector3(k * r * 1.3, h * 0.5, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0))), RED_PAINT)
		mg.add(_cy(r * 0.46, r * 0.3), _T(Vector3(k * r * 1.85, h * 0.5, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0))), STEEL_DARK)
	mg.add(_cy(r * 0.5, r * 1.0), _T(Vector3(0.0, h * 0.42, r * 1.3), Vector3(deg_to_rad(90.0), 0.0, 0.0)), RED_PAINT)
	mg.add(_cy(r * 0.55, r * 0.3), _T(Vector3(0.0, h * 0.42, r * 1.85), Vector3(deg_to_rad(90.0), 0.0, 0.0)), STEEL_DARK)

## A broken concrete ring (a culvert section) with rubble.
static func _ring(mg: Merger, w: float, h: float, rng: RandomNumberGenerator) -> void:
	var R: float = h * 0.42
	var t := TorusMesh.new()
	t.inner_radius = R * 0.72
	t.outer_radius = R
	t.rings = 16
	t.ring_segments = 8
	mg.add(t, _T(Vector3(0.0, R * 0.9, 0.0), Vector3(deg_to_rad(90.0 + rng.randf_range(-10.0, 10.0)), 0.0, deg_to_rad(rng.randf_range(-15.0, 15.0))), Vector3(1.0, 1.0, 0.9)), CONCRETE, "matte")
	_rubble(mg, w * 0.8, h * 0.35, rng, 11)

## A street sign: `state` 0 standing, 1 bent over, 2 lying flat.
static func _sign(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, state: int) -> void:
	var plate: float = w * 0.44
	var pr: float = maxf(w * 0.035, 1.5)
	var oct := CylinderMesh.new()
	oct.top_radius = plate
	oct.bottom_radius = plate
	oct.height = pr * 0.8
	oct.radial_segments = 8
	match state:
		0:
			_rod(mg, Vector3.ZERO, Vector3(0.0, h * 0.72, 0.0), pr, STEEL_DARK)
			mg.add(oct, _T(Vector3(0.0, h * 0.72 + plate * 0.9, 0.0), Vector3(deg_to_rad(90.0), 0.0, deg_to_rad(22.5))), SIGN_RED, "matte")
			mg.add(_bx(Vector3(plate * 1.3, plate * 0.36, pr)), _T(Vector3(0.0, h * 0.72 + plate * 0.9, pr * 0.5)), SIGN_WHITE, "matte")
		1:
			var knee := Vector3(0.0, h * 0.5, 0.0)
			_rod(mg, Vector3.ZERO, knee, pr, STEEL_DARK)
			var top := knee + Vector3(w * 0.3, h * 0.28, 0.0)
			_rod(mg, knee, top, pr, STEEL_DARK)
			mg.add(oct, _T(top + Vector3(plate * 0.6, plate * 0.5, 0.0), Vector3(deg_to_rad(90.0), 0.0, deg_to_rad(-35.0))), RAG, "matte")
		_:
			_rod(mg, Vector3(-w * 0.45, pr, 0.0), Vector3(w * 0.1, pr, 0.0), pr, STEEL_DARK)
			mg.add(oct, _T(Vector3(w * 0.15 + plate * 0.5, pr * 0.5, 0.0), Vector3(0.0, 0.0, deg_to_rad(22.5))), SIGN_RED, "matte")

## A lamp post with its head snapped and hanging.
static func _lamp_broken(mg: Merger, w: float, h: float, rng: RandomNumberGenerator) -> void:
	var pr: float = maxf(w * 0.05, 2.0)
	var knee := Vector3(0.0, h * 0.8, 0.0)
	_rod(mg, Vector3.ZERO, knee, pr, STEEL_DARK)
	var arm := knee + Vector3(w * 0.4, h * 0.1, 0.0)
	_rod(mg, knee, arm, pr * 0.8, STEEL_DARK)
	var head := arm + Vector3(w * 0.25, -h * 0.08, 0.0)
	_rod(mg, arm, head, pr * 0.8, STEEL_DARK)
	mg.add(_bx(Vector3(w * 0.4, h * 0.05, w * 0.2)), _T(head + Vector3(w * 0.1, -h * 0.03, 0.0), Vector3(0.0, 0.0, deg_to_rad(-30.0))), STEEL)
	mg.add(_bx(Vector3(w * 0.3, h * 0.015, w * 0.14)), _T(head + Vector3(w * 0.1, -h * 0.055, 0.0), Vector3(0.0, 0.0, deg_to_rad(-30.0))), PAPER, "matte")

## A bare pole, or a wooden utility pole with its cross-arm and pegs.
static func _pole(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, utility: bool) -> void:
	var pr: float = maxf(w * (0.22 if utility else 0.35), 2.0)
	var lean := Vector3(deg_to_rad(rng.randf_range(-3.0, 3.0)), 0.0, deg_to_rad(rng.randf_range(-3.0, 3.0)))
	var b := Basis.from_euler(lean)
	var top := b * Vector3(0.0, h * 0.98, 0.0)
	_rod(mg, Vector3.ZERO, top, pr, WOOD if utility else STEEL_DARK, "matte" if utility else "")
	if utility:
		var arm := b * Vector3(0.0, h * 0.9, 0.0)
		_rod(mg, arm + Vector3(-w * 0.45, 0.0, 0.0), arm + Vector3(w * 0.45, 0.0, 0.0), pr * 0.4, WOOD, "matte")
		for k in [-1.0, 1.0]:
			_rod(mg, arm + Vector3(k * w * 0.35, 0.0, 0.0), arm + Vector3(k * w * 0.35, pr * 2.5, 0.0), pr * 0.25, STEEL_DARK)
		for i in 3:
			var y: float = h * (0.4 + 0.18 * float(i))
			_rod(mg, b * Vector3(0.0, y, 0.0), b * Vector3(0.0, y, 0.0) + Vector3(w * 0.4, 0.0, 0.0), pr * 0.3, STEEL_DARK)

## Pipes: `state` 0 upright with red bands, 1 lying, 2 a T-piece upright.
static func _pipe(mg: Merger, w: float, h: float, rng: RandomNumberGenerator, state: int) -> void:
	match state:
		0:
			var pr: float = w * 0.3
			_rod(mg, Vector3.ZERO, Vector3(0.0, h, 0.0), pr, TIN)
			for i in 3:
				mg.add(_cy(pr * 1.03, h * 0.02), _T(Vector3(0.0, h * (0.3 + 0.25 * float(i)), 0.0)), RED_PAINT)
		1:
			var L: float = maxf(w, h) * 0.95
			var pr: float = minf(w, h) * 0.22
			var a := Vector3(-L * 0.5, pr, 0.0)
			var bend: bool = rng.randf() < 0.4
			if bend:
				var m := Vector3(0.0, pr, L * 0.15)
				_rod(mg, a, m, pr, TIN)
				_rod(mg, m, Vector3(L * 0.45, pr, -L * 0.1), pr, TIN)
			else:
				_rod(mg, a, Vector3(L * 0.5, pr, 0.0), pr, TIN)
			# Open ends are dark.
			mg.add(_cy(pr * 0.85, pr * 0.2), _T(a + Vector3(pr * 0.05, 0.0, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0))), RUBBER, "rubber")
		_:
			var pr: float = w * 0.16
			_rod(mg, Vector3.ZERO, Vector3(0.0, h * 0.8, 0.0), pr, TIN)
			mg.add(_sph(pr * 1.5), _T(Vector3(0.0, h * 0.82, 0.0)), STEEL_DARK)
			_rod(mg, Vector3(-w * 0.4, h * 0.82, 0.0), Vector3(w * 0.4, h * 0.82, 0.0), pr * 0.9, TIN)

# ---------------------------------------------------------------------
# The burnt stump (TEXTURE.213 record 12)
# ---------------------------------------------------------------------
## A charred trunk snapped off above head height: a tapered black bole,
## a jagged crown of splinters, roots flaring into the ground, and a
## few pale cracks where the bark burnt through.
static func _trunk(mg: Merger, w: float, h: float, rng: RandomNumberGenerator) -> void:
	var CHAR := Color(0.06, 0.05, 0.045)
	var CRACK := Color(0.28, 0.16, 0.08)
	var bole_h: float = h * 0.72
	var r_top: float = w * 0.19
	var r_bot: float = w * 0.27
	var bole := CylinderMesh.new()
	bole.top_radius = r_top
	bole.bottom_radius = r_bot
	bole.height = bole_h
	bole.radial_segments = 11
	mg.add(bole, _T(Vector3(0.0, bole_h * 0.5, 0.0), Vector3(deg_to_rad(rng.randf_range(-4.0, 4.0)), 0.0, deg_to_rad(rng.randf_range(-4.0, 4.0)))), CHAR, "matte")
	# The crown: splinters standing up from the rim at different heights.
	for i in 6:
		var a: float = float(i) / 6.0 * TAU + rng.randf_range(-0.2, 0.2)
		var sh: float = h * rng.randf_range(0.08, 0.26)
		var base := Vector3(cos(a) * r_top * 0.8, bole_h - sh * 0.15, sin(a) * r_top * 0.8)
		var tip := base + Vector3(cos(a) * r_top * 0.25, sh, sin(a) * r_top * 0.25)
		var sr: float = r_top * rng.randf_range(0.18, 0.3)
		var sp := CylinderMesh.new()
		sp.top_radius = sr * 0.15
		sp.bottom_radius = sr
		sp.height = (tip - base).length()
		sp.radial_segments = 5
		var d := (tip - base).normalized()
		var x := Vector3.UP.cross(d).normalized() if absf(d.dot(Vector3.UP)) < 0.999 else Vector3.RIGHT
		mg.add(sp, Transform3D(Basis(x, d, x.cross(d).normalized()), (base + tip) * 0.5), CHAR, "matte")
	# Roots: flattened cones flaring out at the foot, half in the ground.
	for i in 5:
		var a: float = float(i) / 5.0 * TAU + rng.randf_range(-0.3, 0.3)
		var len: float = w * rng.randf_range(0.28, 0.42)
		var root := CylinderMesh.new()
		root.top_radius = r_bot * 0.12
		root.bottom_radius = r_bot * 0.42
		root.height = len
		root.radial_segments = 6
		var a0 := Vector3(cos(a) * r_bot * 0.5, r_bot * 0.25, sin(a) * r_bot * 0.5)
		var a1 := Vector3(cos(a) * (r_bot * 0.5 + len), -r_bot * 0.12, sin(a) * (r_bot * 0.5 + len))
		var d := (a1 - a0).normalized()
		var x := Vector3.UP.cross(d).normalized()
		mg.add(root, Transform3D(_scaled_local(Basis(x, -d, x.cross(-d).normalized()), Vector3(1.0, 1.0, 0.6)), (a0 + a1) * 0.5), CHAR, "matte")
	# Burnt-through cracks: thin pale strips let into the bark.
	for i in 3:
		var a: float = rng.randf() * TAU
		var y0: float = bole_h * rng.randf_range(0.15, 0.5)
		var len: float = bole_h * rng.randf_range(0.2, 0.4)
		var rr: float = lerpf(r_bot, r_top, (y0 + len * 0.5) / bole_h) * 0.97
		mg.add(_bx(Vector3(r_top * 0.12, len, r_top * 0.25)), _T(Vector3(cos(a) * rr, y0 + len * 0.5, sin(a) * rr), Vector3(0.0, -a, deg_to_rad(rng.randf_range(-8.0, 8.0)))), CRACK, "matte")
	# One broken branch stub.
	var ba: float = rng.randf() * TAU
	var b0 := Vector3(cos(ba) * r_top * 0.9, bole_h * 0.78, sin(ba) * r_top * 0.9)
	_rod(mg, b0, b0 + Vector3(cos(ba) * w * 0.22, h * 0.08, sin(ba) * w * 0.22), r_top * 0.22, CHAR, "matte")
