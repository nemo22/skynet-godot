## Measure Godot's omni light falloff in this project's units.
##
##   godot --path . -s res://tools/light_probe.gd -- [energy] [range] [decay]
##
## A white plane, one OmniLight3D 100 u above it, an orthographic camera
## looking straight down with no ambient, no tonemapping and no glow.
## Prints the rendered brightness at known distances from the lamp, so
## the numbers put into light_energy / omni_attenuation mean something
## (2026-09-05: the corridor lamps went from "light nothing" to "white
## out" between two guesses at the formula).

extends SceneTree

const SIZE: float = 4000.0
const HEIGHT: float = 100.0
const PIX: int = 800

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var energy: float = float(args[0]) if args.size() > 0 else 1.0
	var rng: float = float(args[1]) if args.size() > 1 else 1000.0
	var decay: float = float(args[2]) if args.size() > 2 else 1.0
	var w: Window = root
	w.size = Vector2i(PIX, PIX)
	var scene := Node3D.new()
	root.add_child(scene)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	scene.add_child(we)
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(SIZE, SIZE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	pm.material = mat
	plane.mesh = pm
	scene.add_child(plane)
	var l := OmniLight3D.new()
	l.position = Vector3(0.0, HEIGHT, 0.0)
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = decay
	l.light_specular = 0.0
	scene.add_child(l)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = SIZE
	cam.near = 10.0
	cam.far = 6000.0
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 3000.0, 0.0), Vector3.ZERO, Vector3.BACK)
	cam.current = true
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("C:/Users/marek/AppData/Local/Temp/claude/C--Games-skynet/e86fa335-e69b-424c-8c68-77320a26c397/scratchpad/probe.png")
	var mx: float = 0.0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			mx = maxf(mx, img.get_pixel(x, y).r)
	print("[probe] image %dx%d, brightest sample %.4f" % [img.get_width(), img.get_height(), mx])
	print("[probe] energy %.2f range %.0f decay %.2f  (lamp %.0f u above the plane)" % [energy, rng, decay, HEIGHT])
	for d in [0.0, 50.0, 100.0, 150.0, 200.0, 300.0, 400.0, 600.0, 800.0, 1200.0, 1600.0]:
		# Orthographic `size` spans the viewport HEIGHT.
		var scale: float = float(img.get_height()) / SIZE
		var px: int = int(img.get_width() * 0.5 + d * scale)
		if px >= img.get_width():
			continue
		var c: Color = img.get_pixel(px, img.get_height() / 2)
		# The plane is lit at cos(angle) × falloff; report the raw value and the
		# falloff with the geometry divided out.
		var dist: float = sqrt(d * d + HEIGHT * HEIGHT)
		var cosang: float = HEIGHT / dist
		print("[probe]  ground %5.0f u  (%5.0f u from the lamp)  pixel %.3f   falloff/energy %.4f"
			% [d, dist, c.r, c.r / maxf(cosang, 0.001) / energy])
	quit()
