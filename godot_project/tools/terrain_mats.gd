## Dev probe: the terrain tile palette (TEXTURE.302) and which material
## ids a map's heightmap actually uses. Finding the water tile:
##   godot --headless --path . res://scenes/map_dump.tscn -- --mats=270
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")

static func run(list: String) -> void:
	# Average colour of every tile in TEXTURE.302.
	var avg: Array = []
	for i in 64:
		var tex: Texture2D = Assets.texture(302, i, false)
		if tex == null:
			avg.append(null)
			continue
		var img: Image = tex.get_image()
		if img == null:
			avg.append(null)
			continue
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var r: float = 0.0
		var g: float = 0.0
		var b: float = 0.0
		var n: int = 0
		for y in range(0, img.get_height(), 2):
			for x in range(0, img.get_width(), 2):
				var c: Color = img.get_pixel(x, y)
				r += c.r; g += c.g; b += c.b; n += 1
		avg.append(Color(r / n, g / n, b / n) if n > 0 else null)
	for s in list.split(","):
		var suffix: int = int(s)
		var wp := SkynetPaths.gamedata_path("WLD.%03d" % suffix)
		if not FileAccess.file_exists(wp):
			print("WLD.%03d missing" % suffix)
			continue
		var w = WldTerrain.parse(FileAccess.get_file_as_bytes(wp))
		var hist: Dictionary = {}
		for row in 256:
			for col in 256:
				var id: int = WldTerrain.sample_byte(w, 2, col, row) & 0x3F
				hist[id] = hist.get(id, 0) + 1
		var ids: Array = hist.keys()
		ids.sort()
		print("WLD.%03d material ids:" % suffix)
		for id in ids:
			var c = avg[id] if id < avg.size() else null
			var blue: String = ""
			if c != null and c.b > c.r * 1.25 and c.b > c.g * 1.15:
				blue = "   <-- blue"
			print("  id %2d  cells %6d  avg %s%s" % [id, hist[id],
				("%.2f %.2f %.2f" % [c.r, c.g, c.b]) if c != null else "-", blue])
