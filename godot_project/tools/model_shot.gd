## Dev tool: render named .3D models to PNGs, to LOOK at them.
##
## The object/enemy viewers are interactive; this is the headless
## counterpart — needed the moment a model has to be judged by eye (which
## pose is this body in? does it fill the frame?) rather than measured.
## Headless:
##   godot --headless --path . res://scenes/map_dump.tscn -- \
##       --modelshot=AVSOLDER,AVFEMALE --out=C:/tmp [--shotsize=320]
## (loaded by map_dump.gd when --modelshot= is given)
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D := preload("res://scripts/loaders/mesh_3d.gd")

const ARCHIVES: Array = ["MDMDOBJS.BSA", "MDMDENMS.BSA"]

## `spec`: comma-separated model names (with or without .3D).
static func run(spec: String, out_dir: String, size: int = 320) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for raw in spec.split(","):
		var name: String = raw.strip_edges().to_upper()
		if name.is_empty():
			continue
		if not name.ends_with(".3D"):
			name += ".3D"
		var bytes := PackedByteArray()
		for arc in ARCHIVES:
			var b := BSAReader.new()
			if not b.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
				continue
			bytes = b.read(name)
			b.close()
			if not bytes.is_empty():
				break
		if bytes.is_empty():
			print("[modelshot] %s: not in %s" % [name, ", ".join(ARCHIVES)])
			continue
		var parsed = Mesh3D.parse(bytes, name.get_basename())
		if parsed == null:
			print("[modelshot] %s: parse failed" % name)
			continue
		var am: ArrayMesh = Mesh3D.build_textured_array_mesh(parsed, Callable(Assets, "provide"))
		if am == null:
			print("[modelshot] %s: build failed" % name)
			continue
		var aabb: AABB = am.get_aabb()
		# A viewport of its own, the model centred, the camera pulled back
		# just far enough that the body fills the frame.
		var vp := SubViewport.new()
		vp.size = Vector2i(size, size)
		vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.16, 0.17, 0.19)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(1, 1, 1)
		env.ambient_light_energy = 1.0
		var we := WorldEnvironment.new()
		we.environment = env
		vp.add_child(we)
		var mi := MeshInstance3D.new()
		mi.mesh = am
		mi.position = -aabb.get_center()
		vp.add_child(mi)
		var cam := Camera3D.new()
		var radius: float = maxf(aabb.size.length() * 0.5, 1.0)
		# The bodies face -Z (a camera on +Z photographed their backs), so
		# stand in front of them and a little to the side.
		cam.position = Vector3(-radius * 0.5, radius * 0.25, -radius * 1.5)
		cam.look_at_from_position(cam.position, Vector3.ZERO, Vector3.UP)
		cam.far = radius * 20.0
		vp.add_child(cam)
		# Two traps, both learnt the hard way: map_dump calls this from its
		# own _ready(), where the root is still building children (so the
		# add must be deferred), and a --headless run has only the dummy
		# renderer, whose viewport texture is null — this tool needs a
		# WINDOWED run (no --headless), like the in-game screenshots.
		tree.root.add_child.call_deferred(vp)
		await tree.process_frame
		await tree.process_frame
		await tree.process_frame
		var vtex: Texture2D = vp.get_texture()
		var img: Image = vtex.get_image() if vtex != null else null
		if img == null:
			print("[modelshot] %s: the viewport gave no image — run WITHOUT --headless" % name)
			vp.queue_free()
			continue
		var path: String = "%s/MODEL_%s.png" % [out_dir, name.get_basename()]
		print("[modelshot] %s  size=%.0fx%.0fx%.0f  %d surfaces -> %s (%s)"
			% [name, aabb.size.x, aabb.size.y, aabb.size.z, am.get_surface_count(),
			   path, error_string(img.save_png(path))])
		vp.queue_free()
