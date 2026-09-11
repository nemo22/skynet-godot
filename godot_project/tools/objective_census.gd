## Dev tool: can every campaign mission still reach zero objectives?
## The DOS counter (FUN_0012ce73) holds EVERY entry of [M1]..[M5]; each
## map entity with act 0x26+n takes one off and retires. A section with
## more entries than entities across the mission's maps cannot finish.
## Headless:
##   godot --headless --path . res://scenes/map_dump.tscn -- --objectives=210,220,230,240,250,260,270,280
## (loaded by map_dump.gd when --objectives= is given)
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")
const Briefing := preload("res://scripts/loaders/briefing.gd")

static func run(list: String) -> void:
	var brif := BSAReader.new()
	brif.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"), SkynetPaths.variant)
	var maps := BSAReader.new()
	maps.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	for s in list.split(","):
		var key: int = int(s)
		var txt := brif.read("%03d.TXT" % key)
		if txt.is_empty():
			print("mission %d: no briefing" % key)
			continue
		var texts: Array = Briefing.parse(txt).get("mission_texts", [])
		var entries: Array = []
		var total: int = 0
		for sec in texts:
			entries.append((sec as Array).size())
			total += (sec as Array).size()
		var acts: Array = [0, 0, 0, 0, 0]
		var relays: Array = []
		var spawns: int = 0
		var where: Array = []
		for m in range(key, key + 10):
			var bytes := maps.read("MAP.%03d" % m)
			if bytes.is_empty():
				continue
			var map := MapFile.parse(bytes)
			for e in map.entities:
				if e.marker_type >= 0:
					continue
				var a: int = e.link_act_type
				if a >= 0x26 and a <= 0x2A:
					acts[a - 0x26] += 1
					where.append("%d@%05x:M%d" % [m, e.file_off, a - 0x25])
				elif a == 0x2C:
					relays.append("%d@%05x(st %02x)" % [m, e.file_off, e.state_byte])
				elif a == 0xF3:
					spawns += 1
		var short: Array = []
		for i in 5:
			if int(entries[i]) > int(acts[i]):
				short.append("M%d %d>%d" % [i + 1, entries[i], acts[i]])
		print("mission %d: entries %s = %d, acts %s, relays %s, spawns %d  %s"
			% [key, entries, total, acts, relays, spawns,
			   "OK" if short.is_empty() else "UNFINISHABLE " + ", ".join(short)])
		print("    objective acts: %s" % " ".join(where))
	brif.close()
	maps.close()
