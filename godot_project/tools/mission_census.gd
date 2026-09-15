## Dev tool: the shape of a MISSION as one scene — the data the mission
## bake (one Godot scene per mission: the outdoor world, its interiors
## placed off to the side, doors as portals) needs, and the report a
## person checks before it is built.
##
## From a campaign start map it walks every 0xF0 exit to the maps the
## mission can reach (its zones), tells the world variants apart (outdoor
## zones that are the same place re-authored — MAP.216/217 are MAP.210's
## base later in the mission), orders them into PHASES by the exits that
## lead into them, and diffs consecutive phases: entities added, removed
## and re-authored (same name and place, another act, state, chain, hit
## points or type), the terrain cells whose WLD bytes differ. Every portal
## is listed with its target and spawn marker set, checked against the
## markers the target actually has.
##
## Headless:
##   godot --headless --path . res://scenes/map_dump.tscn -- --mission=all --out=DIR
##   (--mission=210,230 for some; the report goes to stdout, the data to
##   DIR/mission_NNN.json when --out is given)
extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")

const ACT_EXIT: int = 0xF0
const VARIANT_SHARE: float = 0.6          # of the smaller map's meshes, same place

static func run(arg: String, out_dir: String) -> void:
	var starts: Array = []
	if arg.strip_edges().is_empty() or arg == "all":
		starts = [210, 220, 230, 240, 252, 260, 270, 280] if SkynetPaths.game != "shock" \
			else range(10, 200, 10)
	else:
		for s in arg.split(","):
			starts.append(int(s))
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	var cache: Dictionary = {}                # num → parsed zone
	for s in starts:
		var report: Dictionary = _mission(int(s), bsa, cache)
		_print_report(report)
		if not out_dir.is_empty() and out_dir != ".":
			DirAccess.make_dir_recursive_absolute(out_dir)
			var f := FileAccess.open("%s/mission_%03d.json" % [out_dir, int(s)], FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify(report, "\t"))
				f.close()
	bsa.close()

# --- zones ---------------------------------------------------------------

## A parsed map with what the census needs of it.
static func _zone(num: int, bsa: BSAReader, cache: Dictionary) -> Dictionary:
	if cache.has(num):
		return cache[num]
	var bytes := bsa.read("MAP.%03d" % num)
	var z: Dictionary = {"num": num, "ok": false}
	if not bytes.is_empty():
		var map := MapFile.parse(bytes)
		if map != null:
			z["ok"] = true
			z["map"] = map
			z["outdoor"] = bytes.size() > 9028 and bytes[9028] == 1
			z["grid"] = Vector2i(map.grid_width, map.grid_height)
			var keys: Dictionary = {}          # identity → entity
			var meshes: int = 0
			var exits: Array = []
			var markers: Dictionary = {}       # marker type → count
			for e in map.entities:
				keys[_key(map, e)] = e
				var v: int = e.flags & 3
				if v == 1:
					meshes += 1
				elif v == 3 and e.marker_type >= 0:
					markers[e.marker_type] = int(markers.get(e.marker_type, 0)) + 1
				elif v == 3 and e.link_act_type == ACT_EXIT:
					exits.append(e)
			z["keys"] = keys
			z["meshes"] = meshes
			z["exits"] = exits
			z["markers"] = markers
			if z["outdoor"]:
				var wp: String = SkynetPaths.gamedata_path("WLD.%03d" % num)
				z["wld_md5"] = FileAccess.get_md5(wp) if FileAccess.file_exists(wp) else ""
				z["wld"] = WldTerrain.parse(SkynetPaths.read_bytes(wp)) if FileAccess.file_exists(wp) else null
	cache[num] = z
	return z

## Identity of an entity across map variants: kind + name/type + exact
## DOS position (main.gd _entity_key — the same rule).
static func _key(m: MapFile.MapFile, e) -> String:
	var v: int = e.flags & 3
	var id: String
	if v == 1:
		id = "1|" + MapFile.entity_name(m, e)
	elif v == 2:
		id = "L"
	elif e.marker_type == 2:
		id = "E|%d" % e.enemy_type
	elif e.marker_type >= 0:
		id = "M|%d" % e.marker_type
	else:
		id = "S|%d" % e.sprite_index
	return "%s|%d,%d,%d" % [id, e.x, e.y, e.z]

## What an entity DOES, for the re-authoring diff: act, state, hit points,
## the chain it starts, its exit target, its enemy type.
static func _behaviour(m: MapFile.MapFile, e) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("act %02x" % e.link_act_type)
	parts.append("state %02x" % e.state_byte)
	if (e.flags & 3) == 1:
		parts.append("hp %d" % e.hp)
		parts.append("destroy %d/%d" % [e.destroy_type, e.destroy_param])
	if (e.flags & 3) == 3 and e.link_act_type == ACT_EXIT:
		parts.append("exit %d set %d" % [e.exit_map, e.exit_marker_id])
	if e.link_next > 0:
		parts.append("chain " + _chain(m, e))
	return ", ".join(parts)

static func _chain(m: MapFile.MapFile, e) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	var cur = m.entities_by_off.get(e.link_next)
	while cur != null and not seen.has(cur.file_off) and parts.size() < 32:
		seen[cur.file_off] = true
		parts.append("%s/%02x/%02x" % [_key(m, cur), cur.link_act_type, cur.state_byte])
		if (cur.flags & 0x40) != 0 or cur.link_next <= 0:
			break
		cur = m.entities_by_off.get(cur.link_next)
	return ">".join(parts)

# --- the mission ---------------------------------------------------------

static func _mission(start: int, bsa: BSAReader, cache: Dictionary) -> Dictionary:
	var report: Dictionary = {"mission": start, "zones": [], "portals": [], "phases": [],
		"diffs": [], "warnings": []}
	# Every map the exits reach, breadth first from the start.
	var order: Array = [start]
	var depth: Dictionary = {start: 0}
	var via: Dictionary = {}                   # num → [from, exit offset]
	var qi: int = 0
	var handoffs: Dictionary = {}              # target map → the exit that leads to another mission
	while qi < order.size():
		var num: int = order[qi]
		qi += 1
		var z: Dictionary = _zone(num, bsa, cache)
		if not z["ok"]:
			report["warnings"].append("MAP.%03d is missing or unreadable" % num)
			continue
		for e in z["exits"]:
			var t: int = int(e.exit_map)
			if t <= 0:
				continue
			# Another mission's WORLD is where this one HANDS OVER (mission
			# 7's MAP.283 flies into mission 8's MAP.280), or a data quirk
			# (MAP.220's truck box returns to mission 1's MAP.216): not a
			# zone. Interiors are shared freely (the city of mission 2 walks
			# into the base's hangars 211-214, mission 5 into 242-248).
			var tz: Dictionary = _zone(t, bsa, cache)
			if tz["ok"] and tz["outdoor"] and _mission_decade(t) != _mission_decade(start) and _is_mission_map(t):
				if not handoffs.has(t):
					handoffs[t] = [num, e.file_off]
				continue
			if not depth.has(t):
				depth[t] = int(depth[num]) + 1
				via[t] = [num, e.file_off]
				order.append(t)
	for t in handoffs:
		report["warnings"].append("MAP.%03d @%05x leads into mission %d's MAP.%03d — a hand-over, not a zone" % [
			int(handoffs[t][0]), int(handoffs[t][1]), _mission_decade(int(t)), int(t)])
	# Zones.
	for num in order:
		var z: Dictionary = _zone(num, bsa, cache)
		if not z["ok"]:
			continue
		report["zones"].append({"map": num, "outdoor": z["outdoor"], "grid": [z["grid"].x, z["grid"].y],
			"meshes": z["meshes"], "entities": (z["map"] as MapFile.MapFile).entities.size(),
			"depth": depth[num], "entered_from": via.get(num, [start, -1]),
			"marker_sets": _marker_sets(z), "wld_md5": String(z.get("wld_md5", ""))})
	# Portals: every exit, with its target checked.
	for num in order:
		var z: Dictionary = _zone(num, bsa, cache)
		if not z["ok"]:
			continue
		var m: MapFile.MapFile = z["map"]
		for e in z["exits"]:
			var t: int = int(e.exit_map)
			var set_id: int = int(e.exit_marker_id)
			var p: Dictionary = {"map": num, "off": "%05x" % e.file_off,
				"pos": [e.x, e.y, e.z], "state": e.state_byte,
				"target": t, "marker_set": set_id, "armed_by": _incoming(m, e)}
			if t == 0:
				p["kind"] = "return"
			elif handoffs.has(t):
				p["kind"] = "hand-over"
			elif not depth.has(t) or not (_zone(t, bsa, cache))["ok"]:
				p["kind"] = "broken"
				report["warnings"].append("MAP.%03d exit @%05x leads to MAP.%03d, which is not there" % [num, e.file_off, t])
			else:
				p["kind"] = "portal"
				var tz: Dictionary = _zone(t, bsa, cache)
				var sets: Array = _marker_sets(tz)
				if not sets.has(set_id):
					p["kind"] = "portal (no spawn)"
					report["warnings"].append("MAP.%03d exit @%05x → MAP.%03d marker set %d: the target has no such marker" % [num, e.file_off, t, set_id])
			report["portals"].append(p)
	# World variants → phases: outdoor zones that share the world, in the
	# order the exits lead into them.
	var worlds: Array = []                      # arrays of zone nums
	for num in order:
		var z: Dictionary = _zone(num, bsa, cache)
		if not z["ok"] or not z["outdoor"]:
			continue
		var placed: bool = false
		for w in worlds:
			if _share(_zone(w[0], bsa, cache), z) >= VARIANT_SHARE:
				w.append(num)
				placed = true
				break
		if not placed:
			worlds.append([num])
	for w in worlds:
		w.sort_custom(func(a, b): return int(depth[a]) < int(depth[b]))
		var phases: Array = []
		for num in w:
			phases.append({"map": num, "depth": depth[num], "entered_from": via.get(num, [start, -1])})
		report["phases"].append({"world": w[0], "phases": phases})
		for i in range(1, w.size()):
			report["diffs"].append(_diff(_zone(w[i - 1], bsa, cache), _zone(w[i], bsa, cache)))
	if worlds.size() > 1:
		report["warnings"].append("the mission has %d separate outdoor worlds: %s" % [worlds.size(), str(worlds)])
	return report

## Campaign missions own the map decades their start maps sit in (SkyNET
## 210..289 → 210, 220, … 280; Future Shock 010..199); a map of another
## decade with a campaign start is another mission's, one without (the
## shared interiors from MAP.340 up, mission 4's MAP.292/293) is a side
## area of whoever walks in.
static func _mission_decade(num: int) -> int:
	return (num / 10) * 10

static func _is_mission_map(num: int) -> bool:
	var starts: Array = [210, 220, 230, 240, 250, 260, 270, 280] if SkynetPaths.game != "shock" \
		else range(10, 200, 10)
	return starts.has(_mission_decade(num))

## The spawn marker sets a zone offers (marker type N = position of set
## N; 0 is the start).
static func _marker_sets(z: Dictionary) -> Array:
	var out: Array = []
	for t in (z["markers"] as Dictionary):
		if int(t) < 100:
			out.append(int(t))
	out.sort()
	return out

## Which entities link INTO `e` (the chain that arms an exit).
static func _incoming(m: MapFile.MapFile, e) -> Array:
	var out: Array = []
	for o in m.entities:
		if o.link_next == e.file_off:
			out.append("%05x/%02x" % [o.file_off, o.link_act_type])
	return out

static func _share(a: Dictionary, b: Dictionary) -> float:
	if a["grid"] != b["grid"]:
		return 0.0
	var ka: Dictionary = a["keys"]
	var kb: Dictionary = b["keys"]
	var na: int = 0
	var shared: int = 0
	for k in ka:
		if not String(k).begins_with("1|"):
			continue
		na += 1
		if kb.has(k):
			shared += 1
	var nb: int = int(b["meshes"])
	var smaller: int = mini(na, nb)
	return float(shared) / float(smaller) if smaller > 0 else 0.0

## What changes from phase `a` to phase `b`.
static func _diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var ma: MapFile.MapFile = a["map"]
	var mb: MapFile.MapFile = b["map"]
	var ka: Dictionary = a["keys"]
	var kb: Dictionary = b["keys"]
	var added: Array = []
	var removed: Array = []
	var changed: Array = []
	for k in kb:
		if not ka.has(k):
			added.append({"id": k, "does": _behaviour(mb, kb[k])})
	for k in ka:
		if not kb.has(k):
			removed.append({"id": k, "does": _behaviour(ma, ka[k])})
			continue
		var ba: String = _behaviour(ma, ka[k])
		var bb: String = _behaviour(mb, kb[k])
		if ba != bb:
			changed.append({"id": k, "was": ba, "now": bb})
	var d: Dictionary = {"from": a["num"], "to": b["num"],
		"added": added, "removed": removed, "changed": changed,
		"counts": {"added": added.size(), "removed": removed.size(), "changed": changed.size()}}
	# The terrain: cells whose height/diagonal (layer 0) or material
	# (layer 2) byte differs, and where.
	var wa = a.get("wld")
	var wb = b.get("wld")
	if wa != null and wb != null:
		for L in [0, 2]:
			var la: PackedByteArray = wa.layers[L]
			var lb: PackedByteArray = wb.layers[L]
			var n: int = 0
			var rect := Rect2i()
			for i in mini(la.size(), lb.size()):
				if la[i] != lb[i]:
					var c := Vector2i(i % 256, i / 256)
					if n == 0:
						rect = Rect2i(c, Vector2i.ONE)
					else:
						rect = rect.expand(c)
					n += 1
			d["terrain_layer_%d" % L] = {"cells": n, "rect": [rect.position.x, rect.position.y, rect.end.x, rect.end.y] if n > 0 else []}
	return d

# --- report --------------------------------------------------------------

static func _print_report(r: Dictionary) -> void:
	print("=== mission %d ===" % int(r["mission"]))
	for z in r["zones"]:
		var from: Array = z["entered_from"]
		print("  zone MAP.%03d  %-7s grid %dx%d  %d meshes  %d entities  depth %d%s  spawn sets %s" % [
			int(z["map"]), "outdoor" if z["outdoor"] else "indoor", z["grid"][0], z["grid"][1],
			int(z["meshes"]), int(z["entities"]), int(z["depth"]),
			"" if int(from[1]) < 0 else "  (from MAP.%03d @%05x)" % [int(from[0]), int(from[1])],
			str(z["marker_sets"])])
	for w in r["phases"]:
		var names: Array = []
		for p in w["phases"]:
			names.append("MAP.%03d" % int(p["map"]))
		print("  world of MAP.%03d, phases in order: %s" % [int(w["world"]), " → ".join(names)])
	for d in r["diffs"]:
		print("  diff MAP.%03d → MAP.%03d: +%d added, -%d removed, %d re-authored" % [
			int(d["from"]), int(d["to"]), int(d["counts"]["added"]), int(d["counts"]["removed"]), int(d["counts"]["changed"])])
		for L in [0, 2]:
			var key: String = "terrain_layer_%d" % L
			if d.has(key):
				var t: Dictionary = d[key]
				print("      terrain layer %d: %d cells differ %s" % [L, int(t["cells"]),
					("in cells %s" % str(t["rect"])) if int(t["cells"]) > 0 else ""])
		for c in d["changed"]:
			print("      ~ %s: %s  →  %s" % [c["id"], c["was"], c["now"]])
		for x in d["added"]:
			print("      + %s: %s" % [x["id"], x["does"]])
		for x in d["removed"]:
			print("      - %s: %s" % [x["id"], x["does"]])
	for p in r["portals"]:
		print("  %-17s MAP.%03d @%s at %s → %s set %d  state %02x  armed by %s" % [
			p["kind"], int(p["map"]), p["off"], str(p["pos"]),
			"back" if int(p["target"]) == 0 else "MAP.%03d" % int(p["target"]),
			int(p["marker_set"]), int(p["state"]), str(p["armed_by"])])
	for w in r["warnings"]:
		print("  ! " + String(w))
