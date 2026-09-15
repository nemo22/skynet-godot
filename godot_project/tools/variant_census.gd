## Dev tool: which MAP files are VARIANTS of one world — the same place
## at a later point of a mission, re-authored (MAP.216 and MAP.217 are
## MAP.210's base after the truck ride and after the lasers). The port
## carries the dead and the picked-up over to such a sibling on its first
## visit (main.gd _import_variant_state), so the list has to be right.
##
## Two maps are candidates when they have the same cell grid and share
## most of their variant-1 meshes by name and exact DOS position; outdoor
## maps also say whether their WLD heightmaps are the same bytes.
## Headless:
##   godot --headless --path . res://scenes/map_dump.tscn -- --variants
##   (--variants=40 lowers the threshold to 40 %)
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")

static func run(arg: String) -> void:
	var threshold: float = 0.5
	if arg.is_valid_float():
		threshold = float(arg) / 100.0
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	var maps: Dictionary = {}                     # num → {grid, outdoor, keys, wld, meshes}
	for num in range(1, 1000):
		var bytes := bsa.read("MAP.%03d" % num)
		if bytes.is_empty():
			continue
		var map := MapFile.parse(bytes)
		if map == null:
			continue
		var keys: Dictionary = {}
		var meshes: int = 0
		for e in map.entities:
			if (e.flags & 3) != 1:
				continue
			meshes += 1
			keys["%s|%d,%d,%d" % [MapFile.entity_name(map, e), e.x, e.y, e.z]] = true
		var outdoor: bool = bytes.size() > 9028 and bytes[9028] == 1
		var wld: String = ""
		if outdoor:
			var wp: String = SkynetPaths.gamedata_path("WLD.%03d" % num)
			wld = FileAccess.get_md5(wp) if FileAccess.file_exists(wp) else "-"
		maps[num] = {"grid": Vector2i(map.grid_width, map.grid_height), "outdoor": outdoor,
			"keys": keys, "wld": wld, "meshes": meshes}
	bsa.close()
	var nums: Array = maps.keys()
	nums.sort()
	print("[variants] %d maps read; pairs sharing >= %d %% of their meshes at the same place:" % [nums.size(), int(threshold * 100.0)])
	var found: int = 0
	for i in nums.size():
		for j in range(i + 1, nums.size()):
			var a: Dictionary = maps[nums[i]]
			var b: Dictionary = maps[nums[j]]
			if a["grid"] != b["grid"] or a["outdoor"] != b["outdoor"]:
				continue
			var ka: Dictionary = a["keys"]
			var kb: Dictionary = b["keys"]
			var smaller: int = mini(ka.size(), kb.size())
			if smaller == 0:
				continue
			var shared: int = 0
			for k in ka:
				if kb.has(k):
					shared += 1
			var ratio: float = float(shared) / float(smaller)
			if ratio < threshold:
				continue
			found += 1
			var terrain: String = ""
			if a["outdoor"]:
				terrain = ", same WLD" if a["wld"] == b["wld"] else ", different WLD"
			print("  MAP.%03d ~ MAP.%03d: %3d %% (%d of %d / %d meshes, %s%s)" % [nums[i], nums[j],
				int(round(ratio * 100.0)), shared, ka.size(), kb.size(),
				"outdoor" if a["outdoor"] else "indoor", terrain])
	if found == 0:
		print("  (none)")
