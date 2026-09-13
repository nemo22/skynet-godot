## Dev probe: object meshes with a DEGENERATE extent (one axis ~0). DOS
## collides objects as cylinders/boxes, so a single-plane quad has no
## collision volume there — the port builds an exact trimesh and turns it
## into a wall (MAP.210's DOOR01, the transport's door, act 0x00).
##   godot --headless --path . --script res://tools/flat_scan.gd
extends SceneTree
func _initialize() -> void:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var Mesh3D = load("res://scripts/loaders/mesh_3d.gd")
	# The data directory the game itself uses (user://gamedata.cfg, or
	# --gamedata=DIR); this used to be one machine's absolute path.
	var Paths = load("res://scripts/skynet_paths.gd")
	var gamedata: String = Paths.locate_gamedata()
	var b = BSAReader.new()
	if not b.open(gamedata + "/MDMDOBJS.BSA", Paths.variant_for(gamedata)):
		print("[flat] cannot open MDMDOBJS.BSA")
		quit(1)
		return
	var flat: Array = []
	var total: int = 0
	for e in b.entries():
		if not String(e.name).to_upper().ends_with(".3D"):
			continue
		total += 1
		var m = Mesh3D.parse(b.read(e.name))
		if m == null or m.vertices.is_empty():
			continue
		var lo := Vector3(1e9, 1e9, 1e9)
		var hi := Vector3(-1e9, -1e9, -1e9)
		for v in m.vertices:
			lo = lo.min(v); hi = hi.max(v)
		var sz: Vector3 = hi - lo
		var mn: float = minf(sz.x, minf(sz.y, sz.z))
		if mn < 2.0:
			flat.append("%s %s" % [String(e.name).get_basename(), str(sz.round())])
	b.close()
	print("[flat] %d of %d object meshes have an axis under 2 units:" % [flat.size(), total])
	for f in flat:
		print("[flat]   %s" % f)
	quit()
