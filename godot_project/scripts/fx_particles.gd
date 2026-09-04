## ENHANCED particle effects (docs §P.6). The DOS game has no particle
## system at all — its effects are cel-animated billboards. In ENHANCED
## mode these GPUParticles3D helpers add what a modern renderer can:
## sparks and dust at bullet impacts, sparks and a smoke column in
## explosions, a smoke trail behind rockets and burning debris, spent
## cases and muzzle smoke at the gun, dust behind the jeep's wheels,
## smoke over fires, and ash drifting through the night air on the
## outdoor maps. Every helper returns null in DOS mode so callers can
## stay unconditional.
extends RefCounted

static var _dot: Texture2D = null          # soft round sprite

static func on() -> bool:
	return Render.enhanced()

## A 32×32 radial soft dot, the one sprite every particle uses.
static func dot() -> Texture2D:
	if _dot != null:
		return _dot
	var n: int = 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d: float = Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_dot = ImageTexture.create_from_image(img)
	return _dot

static func _mat(color: Color, additive: bool, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.albedo_texture = dot()
	m.albedo_color = color
	m.vertex_color_use_as_albedo = true
	m.disable_receive_shadows = true
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	return m

static func _quad(size: float, mat: Material) -> QuadMesh:
	var qm := QuadMesh.new()
	qm.size = Vector2(size, size)
	qm.material = mat
	return qm

## A colour ramp (alpha fades out, optional colour shift).
static func _ramp(c0: Color, c1: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, c0)
	g.set_color(1, c1)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t

static func _free_after(p: Node, secs: float) -> void:
	p.get_tree().create_timer(secs).timeout.connect(func() -> void:
		if is_instance_valid(p):
			p.queue_free())

## Sparks flying from `at`, biased along `dir`; gravity pulls them down.
static func sparks(scene: Node, at: Vector3, dir: Vector3, count: int = 18,
		speed: float = 700.0, color: Color = Color(1.0, 0.75, 0.35)) -> GPUParticles3D:
	if not on() or scene == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = count
	p.lifetime = 0.55
	p.one_shot = true
	p.explosiveness = 1.0
	p.randomness = 0.6
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir.normalized() if dir.length() > 0.01 else Vector3.UP
	pm.spread = 70.0
	pm.initial_velocity_min = speed * 0.4
	pm.initial_velocity_max = speed
	pm.gravity = Vector3(0.0, -2600.0, 0.0)
	pm.damping_min = 100.0
	pm.damping_max = 400.0
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	pm.color_ramp = _ramp(color, Color(color.r, color.g * 0.5, 0.0, 0.0))
	p.process_material = pm
	p.draw_pass_1 = _quad(6.0, _mat(color, true, 3.0))
	p.position = at
	scene.add_child(p)
	_free_after(p, 1.2)
	return p

## A soft dust / smoke puff rising slowly from `at`.
static func puff(scene: Node, at: Vector3, size: float = 80.0,
		color: Color = Color(0.45, 0.4, 0.36, 0.55), life: float = 1.4, count: int = 8) -> GPUParticles3D:
	if not on() or scene == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = count
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.9
	p.randomness = 0.5
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = size * 0.2
	pm.direction = Vector3.UP
	pm.spread = 60.0
	pm.initial_velocity_min = size * 0.4
	pm.initial_velocity_max = size * 0.9
	pm.gravity = Vector3(0.0, size * 0.15, 0.0)
	pm.damping_min = size * 0.3
	pm.damping_max = size * 0.6
	pm.scale_min = 0.6
	pm.scale_max = 1.3
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.color_ramp = _ramp(color, Color(color.r, color.g, color.b, 0.0))
	p.process_material = pm
	p.draw_pass_1 = _quad(size, _mat(Color(1, 1, 1), false))
	p.position = at
	scene.add_child(p)
	_free_after(p, life + 0.3)
	return p

## A smoke column after an explosion of `radius`.
static func smoke_column(scene: Node, at: Vector3, radius: float) -> GPUParticles3D:
	return puff(scene, at + Vector3(0.0, radius * 0.3, 0.0), radius * 1.4,
		Color(0.1, 0.09, 0.09, 0.5), 2.6, 12)

## A bullet impact: sparks along the surface normal and a dust puff.
static func impact(scene: Node, at: Vector3, normal: Vector3) -> void:
	if not on():
		return
	sparks(scene, at + normal * 4.0, normal, 14, 600.0)
	puff(scene, at + normal * 6.0, 50.0, Color(0.5, 0.45, 0.4, 0.45), 0.9, 5)

## A continuous emitter that follows `node` and leaves its particles in
## the world (a rocket's smoke, a burning chunk's trail).
static func trail(node: Node3D, size: float = 40.0,
		color: Color = Color(0.35, 0.33, 0.32, 0.5), burning: bool = false) -> GPUParticles3D:
	if not on() or node == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = 40 if burning else 32
	p.lifetime = 0.7 if burning else 1.3
	p.local_coords = false
	p.randomness = 0.4
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = size * 0.1
	pm.direction = Vector3.UP
	pm.spread = 40.0
	pm.initial_velocity_min = size * 0.3
	pm.initial_velocity_max = size * 0.7
	pm.gravity = Vector3(0.0, size * 0.4, 0.0)
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	if burning:
		pm.color_ramp = _ramp(Color(1.0, 0.6, 0.2, 0.9), Color(0.3, 0.1, 0.05, 0.0))
	else:
		pm.color_ramp = _ramp(color, Color(color.r, color.g, color.b, 0.0))
	p.process_material = pm
	p.draw_pass_1 = _quad(size, _mat(Color(1, 1, 1), burning, 2.0 if burning else 0.0))
	node.add_child(p)
	return p

## Spent cases flicking out of the ejection port, tumbling, bouncing off
## nothing and gone in a second and a half. `right` is the gun's right
## hand side; they leave with a bit of up and back, like a real ejection.
static func casings(scene: Node, at: Vector3, right: Vector3, fwd: Vector3,
		count: int = 1) -> GPUParticles3D:
	if not on() or scene == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = maxi(count, 1)
	p.lifetime = 1.5
	p.one_shot = true
	p.explosiveness = 1.0
	p.randomness = 0.55
	var pm := ParticleProcessMaterial.new()
	pm.direction = (right * 1.6 + Vector3.UP * 0.9 - fwd * 0.25).normalized()
	pm.spread = 18.0
	pm.initial_velocity_min = 190.0
	pm.initial_velocity_max = 330.0
	pm.gravity = Vector3(0.0, -2600.0, 0.0)
	pm.damping_min = 20.0
	pm.damping_max = 60.0
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -900.0
	pm.angular_velocity_max = 900.0
	pm.scale_min = 0.8
	pm.scale_max = 1.15
	pm.color_ramp = _ramp(Color(0.85, 0.66, 0.28, 1.0), Color(0.7, 0.55, 0.24, 0.0))
	p.process_material = pm
	# A stubby brass case. It ejects a hand's width from the camera, so it
	# has to be SMALL: the first cut used a 4x9 quad and filled a corner
	# of the screen with a cream-coloured blob every shot (2026-09-04).
	var qm := QuadMesh.new()
	qm.size = Vector2(1.6, 3.6)
	var m := _mat(Color(1, 1, 1), false, 0.6)
	m.albedo_texture = null                   # a solid case, not a soft dot
	qm.material = m
	p.draw_pass_1 = qm
	p.position = at
	scene.add_child(p)
	_free_after(p, 1.9)
	return p

## The wisp left hanging at the muzzle after a shot. `hot` (energy
## weapons) makes it a bright coloured flare instead of grey smoke.
static func muzzle_smoke(scene: Node, at: Vector3, fwd: Vector3,
		size: float = 34.0, tint: Color = Color(0.55, 0.53, 0.5, 0.22),
		hot: bool = false) -> GPUParticles3D:
	if not on() or scene == null:
		return null
	var p := GPUParticles3D.new()
	# Kept deliberately thin: the first cut billowed after every shot and
	# read as "far too much fire and smoke" (2026-09-04). Two wisps that
	# are gone in half a second are enough to sell the gun.
	p.amount = 2
	p.lifetime = 0.35 if hot else 0.55
	p.one_shot = true
	p.explosiveness = 1.0
	p.randomness = 0.5
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = size * 0.12
	pm.direction = fwd
	pm.spread = 28.0
	pm.initial_velocity_min = size * 0.8
	pm.initial_velocity_max = size * 2.0
	pm.gravity = Vector3(0.0, size * (0.0 if hot else 0.5), 0.0)
	pm.damping_min = size * 1.2
	pm.damping_max = size * 2.4
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.color_ramp = _ramp(tint, Color(tint.r, tint.g, tint.b, 0.0))
	p.process_material = pm
	p.draw_pass_1 = _quad(size, _mat(Color(1, 1, 1), hot, 2.0 if hot else 0.0))
	p.position = at
	scene.add_child(p)
	_free_after(p, 1.4)
	return p

## A 3D noise field the fog volumes below take their density from —
## built once and shared, so a bank of dust actually has structure
## instead of being one flat value.
static var _fog_noise: Texture3D = null
static func fog_noise() -> Texture3D:
	if _fog_noise != null:
		return _fog_noise
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.03
	n.fractal_octaves = 3
	var t := NoiseTexture3D.new()
	t.noise = n
	t.width = 48
	t.height = 48
	t.depth = 48
	t.seamless = true
	_fog_noise = t
	return t

## A REAL volumetric dust bank: a FogVolume the light scatters through,
## not a transparent quad. The first pass drew big billboards, which read
## as exactly what they were — "one square polygon with some opacity"
## (2026-09-04). Godot's volumetric fog does this properly, so the dust
## and the glow around a fire now live in the same froxel grid as the
## global haze.
static func dust_volume(parent: Node3D, at: Vector3, size: Vector3,
		density: float = 0.035, tint: Color = Color(0.44, 0.40, 0.35)) -> FogVolume:
	if parent == null:
		return null
	var fv := FogVolume.new()
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fv.size = size
	fv.position = at
	var m := FogMaterial.new()
	m.density = density
	m.albedo = tint
	m.edge_fade = 0.6
	m.height_falloff = 0.25
	m.density_texture = fog_noise()
	fv.material = m
	parent.add_child(fv)
	return fv

## The glow a fire throws into the air around it.
static func fire_volume(parent: Node3D, radius: float) -> FogVolume:
	if parent == null:
		return null
	var fv := FogVolume.new()
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fv.size = Vector3(radius * 3.0, radius * 4.0, radius * 3.0)
	fv.position = Vector3(0.0, radius * 1.2, 0.0)
	var m := FogMaterial.new()
	m.density = 0.05
	m.albedo = Color(0.9, 0.55, 0.25)
	m.emission = Color(1.0, 0.55, 0.18)
	m.edge_fade = 0.75
	fv.material = m
	parent.add_child(fv)
	return fv

## Dust banks drifting through the outdoor maps: big, very faint sheets
## low over the ground that the moonlight catches, on top of the ash.
## This is a nuclear winter — the air itself should look dirty.
static func dust_clouds(node: Node3D, tint: Color = Color(0.42, 0.38, 0.33)) -> GPUParticles3D:
	if not on() or node == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = 26
	p.lifetime = 26.0
	p.local_coords = false
	p.randomness = 0.9
	p.preprocess = 20.0
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(3600.0, 260.0, 3600.0)
	pm.direction = Vector3(1.0, 0.03, 0.35)
	pm.spread = 25.0
	pm.initial_velocity_min = 45.0
	pm.initial_velocity_max = 130.0
	pm.gravity = Vector3.ZERO
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 18.0
	pm.turbulence_noise_scale = 1.2
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -3.0
	pm.angular_velocity_max = 3.0
	pm.scale_min = 0.7
	pm.scale_max = 2.0
	# In and out over the life — a bank must never pop.
	var g := Gradient.new()
	g.set_color(0, Color(tint.r, tint.g, tint.b, 0.0))
	g.add_point(0.25, Color(tint.r, tint.g, tint.b, 0.10))
	g.add_point(0.75, Color(tint.r, tint.g, tint.b, 0.10))
	g.set_color(g.get_point_count() - 1, Color(tint.r, tint.g, tint.b, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	p.draw_pass_1 = _quad(1500.0, _mat(Color(1, 1, 1), false))
	node.add_child(p)
	return p

## Dust kicked up behind the jeep; drive `amount_ratio` by speed.
static func wheel_dust(node: Node3D) -> GPUParticles3D:
	if not on() or node == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = 48
	p.lifetime = 1.6
	p.local_coords = false
	p.randomness = 0.5
	p.amount_ratio = 0.0
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(70.0, 5.0, 40.0)
	pm.direction = Vector3(0.0, 0.6, 1.0)
	pm.spread = 35.0
	pm.initial_velocity_min = 120.0
	pm.initial_velocity_max = 260.0
	pm.gravity = Vector3(0.0, 25.0, 0.0)
	pm.damping_min = 60.0
	pm.damping_max = 140.0
	pm.scale_min = 0.8
	pm.scale_max = 1.6
	pm.color_ramp = _ramp(Color(0.5, 0.42, 0.36, 0.5), Color(0.5, 0.42, 0.36, 0.0))
	p.process_material = pm
	p.draw_pass_1 = _quad(90.0, _mat(Color(1, 1, 1), false))
	p.position = Vector3(0.0, -60.0, 110.0)      # behind the cab, at the wheels
	node.add_child(p)
	return p

## Thin smoke rising over a fire of `w` × `h`.
static func fire_smoke(node: Node3D, w: float, h: float, base: float) -> GPUParticles3D:
	if not on() or node == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = 10
	p.lifetime = 2.8
	p.randomness = 0.5
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = w * 0.15
	pm.direction = Vector3.UP
	pm.spread = 15.0
	pm.initial_velocity_min = h * 0.5
	pm.initial_velocity_max = h * 0.8
	pm.gravity = Vector3(0.0, h * 0.12, 0.0)
	pm.scale_min = 0.8
	pm.scale_max = 1.8
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.color_ramp = _ramp(Color(0.25, 0.22, 0.2, 0.35), Color(0.25, 0.22, 0.2, 0.0))
	p.process_material = pm
	p.draw_pass_1 = _quad(w * 0.5, _mat(Color(1, 1, 1), false))
	p.position = Vector3(0.0, base + h * 0.9, 0.0)
	node.add_child(p)
	return p

## Ash drifting through the night air around the camera (outdoor maps).
static func ambient_ash(node: Node3D) -> GPUParticles3D:
	if not on() or node == null:
		return null
	var p := GPUParticles3D.new()
	p.amount = 220
	p.lifetime = 9.0
	p.local_coords = false
	p.randomness = 0.8
	p.preprocess = 6.0
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(2200.0, 700.0, 2200.0)
	pm.direction = Vector3(0.3, -0.2, 0.1)
	pm.spread = 90.0
	pm.initial_velocity_min = 20.0
	pm.initial_velocity_max = 70.0
	pm.gravity = Vector3(0.0, -12.0, 0.0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 40.0
	pm.turbulence_noise_scale = 3.0
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	pm.color_ramp = _ramp(Color(0.6, 0.58, 0.55, 0.0), Color(0.6, 0.58, 0.55, 0.0))
	# Fade in and out over the life (alpha 0 → 0.7 → 0).
	var g := Gradient.new()
	g.set_color(0, Color(0.6, 0.58, 0.55, 0.0))
	g.add_point(0.2, Color(0.6, 0.58, 0.55, 0.7))
	g.add_point(0.8, Color(0.6, 0.58, 0.55, 0.7))
	g.set_color(g.get_point_count() - 1, Color(0.6, 0.58, 0.55, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	p.draw_pass_1 = _quad(5.0, _mat(Color(1, 1, 1), false))
	node.add_child(p)
	return p
