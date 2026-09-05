## ENHANCED fire (docs §P.3): a procedural shader flame (shaders/
## fire.gdshader) on two billboard quads, rising embers, and a flickering
## OmniLight — the DOS fire billboards (bank 216 flames, 218 campfires,
## 208_002 burning barrel) become real light sources in the room. The
## base sits at the node origin. Campfires get a small log pile, the
## barrel a drum, both built from primitives here.
extends Node3D

const SHADER := preload("res://shaders/fire.gdshader")
const PARTICLE_SHADER := preload("res://shaders/fire_particle.gdshader")
const FxParticles := preload("res://scripts/fx_particles.gd")

## sprite index (bank << 7 | rec) → {kind, height scale}
const FIRE_SPRITES: Dictionary = {
	27653: {"kind": "flame", "h": 1.0},          # 216_005
	27659: {"kind": "flame", "h": 1.0},          # 216_011
	27660: {"kind": "flame", "h": 1.0},          # 216_012
	27661: {"kind": "flame", "h": 1.0},          # 216_013
	27904: {"kind": "camp", "h": 1.0},           # 218_000
	27905: {"kind": "camp", "h": 1.0},           # 218_001
	27906: {"kind": "camp", "h": 0.9},           # 218_002
	27907: {"kind": "camp", "h": 1.0},           # 218_003
	26626: {"kind": "barrel", "h": 1.0},         # 208_002
	26369: {"kind": "barrel", "h": 1.0},         # 206_001 (the bank-206 drum)
	26627: {"kind": "wreck", "h": 1.0},          # 208_003 burning tyres
	27662: {"kind": "flame", "h": 1.0},          # 216_014 a small flame
}

## How many fire lights may cast shadows (each one costs a cubemap).
const SHADOW_LIGHTS: int = 4
static var _shadow_count: int = 0

var _light: OmniLight3D = null
var _base_energy: float = 2.0
var _phase: float = 0.0

static func is_fire(sprite_index: int) -> bool:
	return FIRE_SPRITES.has(sprite_index)

## `world_w`/`world_h`: the DOS sprite's world size; the flame fills it.
## `kind_override`: "pool" for the burning fuel a molotov leaves — flat
## flames on a scorch mark, no logs, no rubble.
func setup(sprite_index: int, world_w: float, world_h: float, seed: int, kind_override: String = "") -> void:
	add_to_group("fire")
	var info: Dictionary = FIRE_SPRITES.get(sprite_index, {"kind": "flame", "h": 1.0})
	var kind: String = kind_override if kind_override != "" else String(info["kind"])
	add_to_group("fire_" + kind)         # agent aid: --near=fire_wreck:0
	var h: float = world_h * float(info["h"])
	var w: float = world_w
	_phase = float(hash(seed) % 1000) / 1000.0 * TAU
	var flame_base: float = 0.0
	if kind == "flame":
		# A bank-216 flame is a bare billboard: in ENHANCED it became a
		# fire standing on nothing at all ("tu hori ohen len tak z
		# nicoho", 2026-09-04). Give it something to be burning —
		# scorched ground and a few charred lumps.
		_scorch(w, true)
	elif kind == "pool":
		_scorch(w, false)
		w *= 0.9
		h *= 0.55
	elif kind == "camp":
		# The DOS campfire sprite is a bonfire the size of a room (Marek,
		# 2026-09-05: "asi by mal byť trochu menší a realistickejší, ten
		# červený kruh"): a fire of half the sprite over a small hearth.
		_campfire(w * 0.6)
		w *= 0.42
		h *= 0.55
	elif kind == "wreck":
		_tyres(w, h)
		w *= 0.8
		h *= 0.7
	elif kind == "barrel":
		_barrel(w, h)
		flame_base = h * 0.55
		w *= 0.9
		h *= 0.6
	# The body: a particle system of soft noisy blobs rising, shrinking
	# and cooling — volume from any angle; a faint wide tongue behind it.
	_flames(w, h, flame_base)
	_quad(w * 0.9, h * 0.9, flame_base, 0.35, 1.1, seed)
	_embers(w, h, flame_base)
	FxParticles.fire_smoke(self, w, h, flame_base)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.58, 0.22)
	# Intensity at Render.LIGHT_REF (3 m): a fire lights the room, it
	# does not bleach it — measured with --light-scale on the burning
	# pile in MAP.218 (2026-09-05).
	_base_energy = clampf(h / 450.0, 0.18, 0.32)
	_light.light_energy = Render.energy(_base_energy)
	_light.omni_range = clampf(h * 9.0, 500.0, 2400.0)
	_light.omni_attenuation = Render.OMNI_DECAY
	_light.position = Vector3(0.0, flame_base + h * 0.35, 0.0)
	if _shadow_count < SHADOW_LIGHTS:
		_light.shadow_enabled = true
		_shadow_count += 1
	add_child(_light)

func _quad(w: float, h: float, base: float, intensity: float, width: float, seed: int) -> void:
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	mi.mesh = qm
	var sm := ShaderMaterial.new()
	sm.shader = SHADER
	sm.set_shader_parameter("intensity", intensity)
	sm.set_shader_parameter("width", width)
	sm.set_shader_parameter("seed", float(hash(seed) % 977) / 97.0)
	mi.material_override = sm
	mi.position = Vector3(0.0, base + h * 0.5, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _flames(w: float, h: float, base: float) -> void:
	var p := GPUParticles3D.new()
	p.amount = 26
	p.lifetime = 1.1
	p.randomness = 0.5
	p.explosiveness = 0.0
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = w * 0.22
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 12.0
	pm.initial_velocity_min = h * 0.55
	pm.initial_velocity_max = h * 0.95
	pm.gravity = Vector3(0.0, h * 0.25, 0.0)
	pm.damping_min = 1.0
	pm.damping_max = 3.0
	pm.scale_min = 0.8
	pm.scale_max = 1.3
	# Age → COLOR.a for the shader (1 at birth, 0 at death).
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	var qm := QuadMesh.new()
	var s: float = w * 0.62
	qm.size = Vector2(s, s)
	var sm := ShaderMaterial.new()
	sm.shader = PARTICLE_SHADER
	qm.material = sm
	p.draw_pass_1 = qm
	p.position = Vector3(0.0, base + s * 0.35, 0.0)
	add_child(p)

func _embers(w: float, h: float, base: float) -> void:
	var p := GPUParticles3D.new()
	p.amount = 14
	p.lifetime = 1.8
	p.randomness = 0.6
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(w * 0.25, h * 0.1, w * 0.25)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 25.0
	pm.initial_velocity_min = h * 0.5
	pm.initial_velocity_max = h * 1.1
	pm.gravity = Vector3(0.0, h * 0.15, 0.0)
	pm.damping_min = 2.0
	pm.damping_max = 6.0
	pm.scale_min = 0.6
	pm.scale_max = 1.2
	pm.color = Color(1.0, 0.55, 0.15)
	p.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(maxf(w * 0.012, 1.2), maxf(w * 0.012, 1.2))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.1)
	mat.emission_energy_multiplier = 3.0
	mat.albedo_color = Color(1.0, 0.6, 0.2)
	mat.vertex_color_use_as_albedo = true
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.material = mat
	p.draw_pass_1 = qm
	p.position = Vector3(0.0, base + h * 0.3, 0.0)
	add_child(p)

## What a loose flame is burning: a scorched patch of ground and, when
## `lumps`, a handful of charred blocks around the base, so the fire has
## a source. The molotov pool skips the lumps.
func _scorch(w: float, lumps: bool = true) -> void:
	var burnt := StandardMaterial3D.new()
	burnt.albedo_color = Color(0.09, 0.07, 0.06)
	burnt.roughness = 1.0
	# The mark: soot, thin as paint — the raised brown disc read as a
	# plate under the fire (2026-09-05).
	var mark := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = w * 0.34
	disc.bottom_radius = w * 0.38
	disc.height = 0.6
	disc.radial_segments = 14
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.03, 0.028, 0.025)
	dm.roughness = 1.0
	disc.material = dm
	mark.mesh = disc
	mark.position.y = 0.3
	add_child(mark)
	if not lumps:
		return
	# Rubble: small blocks pushed into the ground, no two alike.
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_phase * 1000.0) + 7
	for i in 5:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var s: float = w * rng.randf_range(0.06, 0.13)
		bm.size = Vector3(s, s * rng.randf_range(0.5, 0.9), s * rng.randf_range(0.7, 1.3))
		bm.material = burnt
		mi.mesh = bm
		var a: float = rng.randf() * TAU
		var r: float = w * rng.randf_range(0.25, 0.8)
		mi.position = Vector3(cos(a) * r, bm.size.y * 0.3, sin(a) * r)
		mi.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU,
			rng.randf_range(-0.3, 0.3))
		add_child(mi)

## A hearth: a ring of stones around an ash bed, a teepee of thin
## charred logs, two more lying across, a faint ember glow in the
## middle. `w` is the hearth's width.
func _campfire(w: float) -> void:
	var char_mat := StandardMaterial3D.new()
	char_mat.albedo_color = Color(0.11, 0.08, 0.06)
	char_mat.roughness = 0.95
	var ash := StandardMaterial3D.new()
	ash.albedo_color = Color(0.09, 0.085, 0.08)
	ash.roughness = 1.0
	var ember := StandardMaterial3D.new()
	ember.albedo_color = Color(0.12, 0.05, 0.02)
	ember.emission_enabled = true
	ember.emission = Color(1.0, 0.32, 0.05)
	ember.emission_energy_multiplier = 0.35
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.3, 0.29, 0.27)
	stone.roughness = 0.95
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_phase * 1000.0) + 3
	# Ash bed and embers.
	_disc(w * 0.26, 1.5, ash, 0.7)
	_disc(w * 0.12, 2.5, ember, 1.4)
	# Stones.
	for i in 10:
		var a: float = float(i) / 10.0 * TAU + rng.randf_range(-0.15, 0.15)
		var rr: float = w * rng.randf_range(0.27, 0.31)
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var sr: float = w * rng.randf_range(0.04, 0.06)
		sm.radius = sr
		sm.height = sr * 2.0
		sm.radial_segments = 8
		sm.rings = 4
		sm.material = stone
		mi.mesh = sm
		mi.scale = Vector3(1.0, 0.6, 0.85)
		mi.position = Vector3(cos(a) * rr, sr * 0.45, sin(a) * rr)
		mi.rotation.y = rng.randf() * TAU
		add_child(mi)
	# Logs: a teepee of five, two lying across the bed.
	var r: float = maxf(w * 0.018, 1.5)
	var apex := Vector3(0.0, w * 0.3, 0.0)
	for i in 5:
		var a: float = float(i) / 5.0 * TAU + _phase
		var foot := Vector3(cos(a) * w * 0.19, r, sin(a) * w * 0.19)
		var top := apex + Vector3(cos(a) * w * 0.04, rng.randf_range(-0.02, 0.06) * w, sin(a) * w * 0.04)
		_log(foot, top, r, char_mat)
	for i in 2:
		var a: float = rng.randf() * TAU
		var d := Vector3(cos(a), 0.0, sin(a)) * w * 0.24
		_log(-d + Vector3(0.0, r * 1.2, 0.0), d + Vector3(0.0, r * 1.2, 0.0), r * 0.9, char_mat)

func _disc(radius: float, height: float, mat: Material, y: float) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius * 1.1
	cyl.height = height
	cyl.radial_segments = 14
	cyl.material = mat
	mi.mesh = cyl
	mi.position.y = y
	add_child(mi)

## A tapered log from `a` to `b`.
func _log(a: Vector3, b: Vector3, r: float, mat: Material) -> void:
	var d: Vector3 = b - a
	var len: float = d.length()
	if len < 0.01:
		return
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r * 0.8
	cm.bottom_radius = r
	cm.height = len
	cm.radial_segments = 7
	cm.material = mat
	mi.mesh = cm
	var dir := d / len
	var basis := Basis.IDENTITY
	if absf(dir.dot(Vector3.UP)) < 0.999:
		var x := Vector3.UP.cross(dir).normalized()
		basis = Basis(x, dir, x.cross(dir).normalized())
	mi.transform = Transform3D(basis, (a + b) * 0.5)
	add_child(mi)

## The burning wreck (208_003): a heap of tyres — two flat, one thrown on
## top — over scorched ground.
func _tyres(w: float, h: float) -> void:
	_scorch(w * 0.9, false)
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.05, 0.05, 0.05)
	rubber.roughness = 0.8
	var R: float = minf(w, h) * 0.2
	var tyre := TorusMesh.new()
	tyre.inner_radius = R * 0.55
	tyre.outer_radius = R
	tyre.rings = 18
	tyre.ring_segments = 8
	tyre.material = rubber
	var spots: Array = [
		[Vector3(-w * 0.16, R * 0.23, w * 0.02), Vector3(0.0, 0.3, 0.0)],
		[Vector3(w * 0.14, R * 0.23, -w * 0.04), Vector3(0.0, 1.1, 0.0)],
		[Vector3(-w * 0.02, R * 0.62, -w * 0.02), Vector3(deg_to_rad(28.0), 0.7, deg_to_rad(10.0))],
	]
	for sp in spots:
		var mi := MeshInstance3D.new()
		mi.mesh = tyre
		mi.position = sp[0]
		mi.rotation = sp[1]
		mi.scale = Vector3(1.0, 0.9, 1.0)
		add_child(mi)

## An oil drum with the fire coming out of the top.
func _barrel(w: float, h: float) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = w * 0.42
	cm.bottom_radius = w * 0.42
	cm.height = h * 0.55
	cm.radial_segments = 14
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.17, 0.15)
	mat.roughness = 0.7
	mat.metallic = 0.4
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.3, 0.05)
	mat.emission_energy_multiplier = 0.25
	cm.material = mat
	mi.mesh = cm
	mi.position = Vector3(0.0, h * 0.275, 0.0)
	add_child(mi)

func _process(_delta: float) -> void:
	if _light == null:
		return
	var s: float = float(Time.get_ticks_msec()) * 0.001
	var flicker: float = 0.82 + 0.12 * sin(s * 9.3 + _phase) + 0.06 * sin(s * 23.7 + _phase * 2.0)
	_light.light_energy = Render.energy(_base_energy * flicker)
