## Dev probe: which heightmap belongs to a map whose own WLD is missing.
## For every WLD in the game directory, sample it under each of the map's
## variant-1 entities and report the median (entity Y − terrain Y): the
## right terrain is the one the buildings stand ON.
##   godot --headless --path . res://scenes/map_dump.tscn -- --gamedata=DIR --wldmatch=40,80
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")

static func run(list: String) -> void:
	var dir: String = SkynetPaths.gamedata_dir
	var d := DirAccess.open(dir)
	if d == null:
		print("no gamedata dir")
		return
	var wlds: Array = []
	for f in d.get_files():
		if f.begins_with("WLD."):
			wlds.append(f)
	wlds.sort()
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	for s in list.split(","):
		var name := "MAP.%03d" % int(s)
		var bytes := bsa.read(name)
		if bytes.is_empty():
			print("%s missing" % name)
			continue
		var m := MapFile.parse(bytes)
		# Ground actors are the best samples of where the ground IS: a
		# building's origin may be at its base or its centre, an enemy
		# marker is always on the floor (its Y is stored as Y + 0x10).
		var pts: Array = []
		for e in m.entities:
			if (e.flags & 3) == 3 and e.marker_type == 2:
				pts.append(Vector3(float(e.x), -float(e.y + 0x10), float(e.z)))
		if pts.is_empty():
			for e in m.entities:
				if (e.flags & 3) == 1:
					pts.append(Vector3(float(e.x), -float(e.y), float(e.z)))
		print("%s: %d ground samples" % [name, pts.size()])
		for nm in wlds:
			var w = WldTerrain.parse(FileAccess.get_file_as_bytes("%s/%s" % [dir, nm]))
			var diffs := PackedFloat32Array()
			for p in pts:
				diffs.append(p.y - WldTerrain.height_at_world(w, p.x, p.z))
			var arr: Array = Array(diffs)
			arr.sort()
			var med: float = arr[arr.size() / 2]
			var lo: float = arr[arr.size() / 10]
			var hi: float = arr[arr.size() * 9 / 10]
			# How many stand within a step of the ground.
			var on: int = 0
			for v in arr:
				if absf(v) <= 60.0:
					on += 1
			print("   %-10s median %7.0f  p10 %7.0f  p90 %7.0f  on-ground %d%%"
				% [nm, med, lo, hi, on * 100 / maxi(arr.size(), 1)])
	bsa.close()
