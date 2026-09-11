## Dev tool: the DOS border boxes (marker pairs of types 30-39, engine
## FUN_00122711) per map — and whether everything the player must reach
## lies inside them. Outside a box the engine undoes the player's move,
## so a box that misses a spawn, an exit or an objective would make the
## map unplayable.
## Headless:
##   godot --headless --path . res://scenes/map_dump.tscn -- --borders=210,220,230
## (loaded by map_dump.gd when --borders= is given; no list = every map)
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")

static func run(list: String) -> void:
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	var names: Array = []
	if list.strip_edges().is_empty() or list == "all":
		for m in range(200, 300):
			names.append(m)
	else:
		for s in list.split(","):
			names.append(int(s))
	for num in names:
		var bytes := bsa.read("MAP.%03d" % num)
		if bytes.is_empty():
			continue
		var map := MapFile.parse(bytes)
		# Markers by type, exactly as the level loader collects them.
		var by_type: Dictionary = {}
		for e in map.entities:
			if (e.flags & 3) == 3 and e.marker_type >= 0:
				if not by_type.has(e.marker_type):
					by_type[e.marker_type] = []
				by_type[e.marker_type].append(Vector2(
					float(e.x), -float(e.z)))
		var boxes: Array = []
		for mt in range(30, 40):
			var pts: Array = by_type.get(mt, [])
			for i in range(0, pts.size() - 1, 2):
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[i + 1]
				boxes.append(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)),
					Vector2(absf(a.x - b.x), absf(a.y - b.y))))
			if pts.size() % 2 == 1:
				print("MAP.%03d: marker type %d is UNPAIRED (%d)" % [num, mt, pts.size()])
		if boxes.is_empty():
			continue
		var out: Array = []
		for b in boxes:
			out.append("[%.0f..%.0f × %.0f..%.0f]"
				% [(b as Rect2).position.x, (b as Rect2).end.x,
				   (b as Rect2).position.y, (b as Rect2).end.y])
		print("MAP.%03d: %d box(es) %s" % [num, boxes.size(), " ".join(out)])
		# Everything the player has to reach must sit inside some box.
		var trouble: Array = []
		for e in map.entities:
			var p := Vector2(float(e.x), -float(e.z))
			var inside: bool = false
			for b in boxes:
				if (b as Rect2).has_point(p):
					inside = true
					break
			if inside:
				continue
			var what: String = ""
			if (e.flags & 3) == 3 and e.marker_type == 0:
				what = "player start"
			elif (e.flags & 3) == 3 and e.marker_type >= 10 and e.marker_type <= 29:
				what = "DM spawn %d" % e.marker_type
			elif e.link_act_type >= 0x26 and e.link_act_type <= 0x2A:
				what = "objective M%d" % (e.link_act_type - 0x25)
			elif e.link_act_type == 0xF0:
				what = "exit → %d" % e.exit_map
			if not what.is_empty():
				trouble.append("%s @%05x (%d,%d)" % [what, e.file_off, e.x, e.z])
		if trouble.is_empty():
			print("    everything reachable is inside")
		else:
			print("    OUTSIDE THE BOXES: %s" % ", ".join(trouble))
	bsa.close()
