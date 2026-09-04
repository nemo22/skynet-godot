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
func setup(sprite_index: int, world_w: float, world_h: float, seed: int) -> void:
	add_to_group("fire")
	var info: Dictionary = FIRE_SPRITES.get(sprite_index, {"kind": "flame", "h": 1.0})
	var kind: String = String(info["kind"])
	var h: float = world_h * float(info["h"])
	var w: float = world_w
	_phase = float(hash(seed) % 1000) / 1000.0 * TAU
	var flame_base: float = 0.0
	if kind == "flame":
		# A bank-216 flame is a bare billboard: in ENHANCED it became a
		# fire standing on nothing at all ("tu hori ohen len tak z
		# nicoho", 2026-09-04). Give it something to be burning —
		# scorched ground and a few charred lumps.
		_scorch(w)
	elif kind == "camp":
		_logs(w, h)
		w *= 0.75
		h *= 0.95
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
	_base_energy = clampf(h / 60.0, 1.2, 4.0)
	_light.light_energy = _base_energy
	_light.omni_range = clampf(h * 9.0, 500.0, 2400.0)
	_light.omni_attenuation = 1.4
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

## A few charred logs leaning into a pile.
## What a loose flame is burning: a scorched patch of ground and a
## handful of charred lumps around the base, so the fire has a source.
func _scorch(w: float) -> void:
	var burnt := StandardMaterial3D.new()
	burnt.albedo_color = Color(0.09, 0.07, 0.06)
	burnt.roughness = 1.0
	var mark := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = w * 0.50
	disc.bottom_radius = w * 0.54
	disc.height = maxf(w * 0.02, 1.0)
	disc.radial_segments = 14
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.06, 0.05, 0.045)
	dm.roughness = 1.0
	dm.emission_enabled = true
	dm.emission = Color(1.0, 0.34, 0.06)
	dm.emission_energy_multiplier = 0.05
	disc.material = dm
	mark.mesh = disc
	mark.position.y = disc.height * 0.4
	add_child(mark)
	# Rubble: small blocks pushed into the ground, no two alike.
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_phase * 1000.0) + 7
	for i in 6:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var s: float = w * rng.randf_range(0.10, 0.22)
		bm.size = Vector3(s, s * rng.randf_range(0.5, 0.9), s * rng.randf_range(0.7, 1.3))
		bm.material = burnt
		mi.mesh = bm
		var a: float = rng.randf() * TAU
		var r: float = w * rng.randf_range(0.25, 0.8)
		mi.position = Vector3(cos(a) * r, bm.size.y * 0.3, sin(a) * r)
		mi.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU,
			rng.randf_range(-0.3, 0.3))
		add_child(mi)

func _logs(w: float, h: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.1, 0.07)
	mat.roughness = 0.95
	var r: float = maxf(w * 0.028, 2.0)
	var n: int = 5
	for i in n:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = r
		cm.bottom_radius = r * 1.15
		cm.height = w * 0.8
		cm.radial_segments = 8
		cm.material = mat
		mi.mesh = cm
		var yaw: float = float(i) / float(n) * TAU + _phase
		mi.rotation = Vector3(0.0, yaw, deg_to_rad(62.0))
		mi.position = Vector3(cos(yaw) * w * 0.1, r + w * 0.8 * 0.5 * sin(deg_to_rad(28.0)), sin(yaw) * w * 0.1)
		add_child(mi)
	# Ash / ember bed.
	var bed := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = w * 0.3
	cyl.bottom_radius = w * 0.34
	cyl.height = r
	cyl.radial_segments = 12
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.12, 0.07, 0.05)
	bm.emission_enabled = true
	bm.emission = Color(1.0, 0.3, 0.04)
	bm.emission_energy_multiplier = 0.25
	cyl.material = bm
	bed.mesh = cyl
	bed.position = Vector3(0.0, r * 0.5, 0.0)
	add_child(bed)

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
	_light.light_energy = _base_energy * flicker
