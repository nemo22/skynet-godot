## NETLEVEL.PRS — the DOS network level list (loose file next to the
## BSAs, mdm 28.may.96). One [levelN] section per deathmatch arena:
##   name, map (MAP number), maxplayers (0 = unlimited), timesetting,
##   goal (kills), scoring_kill/death/hit, then the item counts the host
##   scatters over the map's item markers (jeeps, hks, bullets, energy,
##   armor, health, slugthrowers, lasers, plasmas, launchers, grenades,
##   rockets) and replenish (yes/no = respawn taken items).
## Parsed once; a missing file yields the built-in MAP.600..609 list.
extends RefCounted

const ITEM_KEYS: Array = ["jeeps", "hks", "bullets", "energy", "armor", "health",
	"slugthrowers", "lasers", "plasmas", "launchers", "grenades", "rockets"]

static var _levels: Array = []
static var _loaded: bool = false

## [{name, map:"MAP.605", maxplayers, timesetting, items:{key:int}, replenish:bool}, …]
static func levels() -> Array:
	if _loaded:
		return _levels
	_loaded = true
	_levels = []
	var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path("NETLEVEL.PRS"))
	if bytes.is_empty():
		push_warning("[net] NETLEVEL.PRS missing — using the built-in arena list")
		for m in [605, 601, 602, 603, 604, 600, 606, 609, 607, 608]:
			_levels.append(_default("MAP.%03d" % m))
		return _levels
	var cur: Dictionary = {}
	for raw in bytes.get_string_from_ascii().split("\n"):
		var line: String = raw
		var sc: int = line.find(";")
		if sc >= 0:
			line = line.substr(0, sc)
		line = line.strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("["):
			if not cur.is_empty():
				_levels.append(cur)
			cur = _default("")
			continue
		var eq: int = line.find("=")
		if eq <= 0:
			continue
		var k: String = line.substr(0, eq).strip_edges().to_lower()
		var v: String = line.substr(eq + 1).strip_edges()
		match k:
			"name":
				cur["name"] = v
			"map":
				cur["map"] = "MAP.%03d" % int(v)
			"maxplayers":
				cur["maxplayers"] = int(v)
			"timesetting":
				cur["timesetting"] = v.to_lower()
			"replenish":
				cur["replenish"] = v.to_lower() in ["yes", "1", "true"]
			_:
				if ITEM_KEYS.has(k):
					cur["items"][k] = int(v)
	if not cur.is_empty() and not String(cur.get("map", "")).is_empty():
		_levels.append(cur)
	return _levels

static func _default(map: String) -> Dictionary:
	var items: Dictionary = {}
	for k in ITEM_KEYS:
		items[k] = 4
	return {"name": map, "map": map, "maxplayers": 0, "timesetting": "night",
		"items": items, "replenish": true}

## The entry for `map`, or a generic one when the map is not listed.
static func for_map(map: String) -> Dictionary:
	for l in levels():
		if String(l["map"]) == map:
			return l
	var d := _default(map)
	d["name"] = map
	return d
