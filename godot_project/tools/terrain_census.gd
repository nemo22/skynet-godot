## Dev tool: how much of each outdoor map is actually played on, and how
## coarse its heightmap is. Headless:
##   godot --headless --path . res://scenes/map_dump.tscn -- --terrain=210,220 --out=C:/tmp
## (loaded by map_dump.gd when --terrain= is given)
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")

static func run(list: String) -> void:
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	for s in list.split(","):
		var name := "MAP.%03d" % int(s)
		var bytes := bsa.read(name)
		if bytes.is_empty():
			print("%s: missing" % name)
			continue
		var m := MapFile.parse(bytes)
		var wp := SkynetPaths.gamedata_path("WLD.%03d" % int(s))
		var wld = null
		if FileAccess.file_exists(wp):
			wld = WldTerrain.parse(FileAccess.get_file_as_bytes(wp))
		var lo := Vector2(1e9, 1e9)
		var hi := Vector2(-1e9, -1e9)
		var n_mesh := 0
		var n_marker := 0
		var n_sprite := 0
		var mlo := Vector2(1e9, 1e9)
		var mhi := Vector2(-1e9, -1e9)
		for e in m.entities:
			var v: int = e.flags & 3
			var p := Vector2(float(e.x), float(e.z))
			if v == 1:
				n_mesh += 1
				lo = lo.min(p); hi = hi.max(p)
			elif v == 3 and e.marker_type >= 0:
				n_marker += 1
				mlo = mlo.min(p); mhi = mhi.max(p)
			elif v == 3:
				n_sprite += 1
				lo = lo.min(p); hi = hi.max(p)
		var ext := hi - lo
		var mext := mhi - mlo
		var frac: float = (ext.x * ext.y) / (65536.0 * 65536.0)
		print("%s: meshes %d sprites %d markers %d | meshes+sprites x %.0f..%.0f z %.0f..%.0f (%.0f x %.0f u = %d x %d cells, %.1f%% of the map) | markers x %.0f..%.0f z %.0f..%.0f (%.0f x %.0f)"
			% [name, n_mesh, n_sprite, n_marker, lo.x, hi.x, lo.y, hi.y, ext.x, ext.y,
			   int(ext.x / 256.0), int(ext.y / 256.0), frac * 100.0, mlo.x, mhi.x, mlo.y, mhi.y, mext.x, mext.y])
		if wld != null:
			# Heightmap statistics: distinct levels, flat cells, the
			# biggest single-cell step, both over the map and inside the
			# entity box.
			var levels: Dictionary = {}
			var flat := 0
			var steps: Dictionary = {}
			var maxstep := 0.0
			var inside_flat := 0
			var inside := 0
			var inside_max := 0.0
			for row in range(255):
				for col in range(255):
					var h0 := WldTerrain.corner_height(wld, col, row)
					var h1 := WldTerrain.corner_height(wld, col + 1, row)
					var h2 := WldTerrain.corner_height(wld, col, row + 1)
					var h3 := WldTerrain.corner_height(wld, col + 1, row + 1)
					levels[h0] = true
					var d: float = maxf(maxf(absf(h1 - h0), absf(h2 - h0)), absf(h3 - h0))
					var isflat: bool = d < 0.5
					if isflat: flat += 1
					maxstep = maxf(maxstep, d)
					var wx := float(col) * 256.0
					var wz := 65536.0 - float(row) * 256.0
					if wx >= lo.x and wx <= hi.x and wz >= lo.y and wz <= hi.y:
						inside += 1
						if isflat: inside_flat += 1
						inside_max = maxf(inside_max, d)
					var key: int = int(d / 40.0)
					steps[key] = int(steps.get(key, 0)) + 1
			var sk := steps.keys(); sk.sort()
			var hist := ""
			for k in sk:
				if k <= 6 or int(steps[k]) > 50:
					hist += "%d:%d " % [k * 40, steps[k]]
			print("    heights: %d distinct levels, %d/%d cells flat (%.0f%%), max step %.0f u/cell; inside the box %d cells, %.0f%% flat, max step %.0f | step histogram (u:cells) %s"
				% [levels.size(), flat, 255 * 255, 100.0 * flat / (255.0 * 255.0), maxstep, inside,
				   100.0 * inside_flat / maxf(1.0, inside), inside_max, hist])
	bsa.close()
