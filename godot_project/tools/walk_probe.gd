## Dev probe: how far a DOS walk cycle carries the model. The cycles are
## authored in place, so the engine's forward step comes from the PLANTED
## FOOT sliding backwards in model space (walker handler 0x13be00 →
## 0x13c104: delta = ref_vertex[prev] - ref_vertex[cur], rotated by the
## actor's yaw). This estimates that by taking, per frame, the most
## backward-moving vertex among the lowest ones.
##   godot --headless --path . --script res://tools/walk_probe.gd -- ENDOSKEL.3D:6:20:10
extends SceneTree

func _initialize() -> void:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var Mesh3D = load("res://scripts/loaders/mesh_3d.gd")
	# The data directory the game itself uses (user://gamedata.cfg, or
	# --gamedata=DIR); this used to be one machine's absolute path.
	var Paths = load("res://scripts/skynet_paths.gd")
	var gamedata: String = Paths.locate_gamedata()
	var b = BSAReader.new()
	if not b.open(gamedata + "/MDMDENMS.BSA", Paths.variant_for(gamedata)):
		print("no MDMDENMS.BSA")
		quit(1)
		return
	for spec in OS.get_cmdline_user_args():
		if spec.begins_with("--"):
			continue
		var parts: PackedStringArray = spec.split(":")
		var nm: String = parts[0].to_upper()
		var f0: int = int(parts[1]) if parts.size() > 1 else 0
		var f1: int = int(parts[2]) if parts.size() > 2 else 0
		var fps: float = float(parts[3]) if parts.size() > 3 else 10.0
		var bytes: PackedByteArray = b.read(nm)
		if bytes.is_empty():
			print("%s: missing" % nm)
			continue
		var m = Mesh3D.parse(bytes)
		if m == null:
			print("%s: parse failed" % nm)
			continue
		if f1 <= 0 or f1 >= m.frames.size():
			f1 = m.frames.size() - 1
		# Model height, to pick out the feet.
		var lo: float = 1.0e9
		var hi: float = -1.0e9
		for v in m.frames[f0]:
			lo = minf(lo, v.y); hi = maxf(hi, v.y)
		var foot_y: float = lo + (hi - lo) * 0.15
		var back: float = 0.0                  # most backward foot (planted)
		var fwd: float = 0.0                   # most forward foot (swinging)
		for fi in range(f0 + 1, f1 + 1):
			var a: PackedVector3Array = m.frames[fi - 1]
			var c: PackedVector3Array = m.frames[fi]
			var dmin: float = 0.0
			var dmax: float = 0.0
			for vi in mini(a.size(), c.size()):
				if a[vi].y > foot_y and c[vi].y > foot_y:
					continue                     # not a foot
				var dz: float = c[vi].z - a[vi].z
				dmin = minf(dmin, dz)
				dmax = maxf(dmax, dz)
			back += -dmin
			fwd += dmax
		var secs: float = float(f1 - f0) / maxf(fps, 0.01)
		print("%-12s frames %d..%d @ %.0f fps (%.2f s): planted %.0f u → %.0f u/s | swing %.0f u → %.0f u/s  (height %.0f)"
			% [nm, f0, f1, fps, secs, back, back / maxf(secs, 0.01),
			   fwd, fwd / maxf(secs, 0.01), hi - lo])
	b.close()
	quit()
