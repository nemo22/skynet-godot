## Reader for the INI-like .PRS text files in MDMDBRIF.BSA (STRINGS.PRS,
## VOICE.PRS, TRANSFRM.PRS): "key = value" lines, ';' comments, [sections]
## ignored. The first definition of a key wins — STRINGS.PRS lists every
## pickup message twice ("PICKED UP ..." then "SNAGGED A ...") and the
## DOS parser stops at the first match. Tables are cached per file.

extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

static var _cache: Dictionary = {}

static func table(name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]
	var out: Dictionary = {}
	var bsa := BSAReader.new()
	if bsa.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"), SkynetPaths.variant):
		var bytes: PackedByteArray = bsa.read(name)
		bsa.close()
		for line in bytes.get_string_from_ascii().split("\n"):
			var l: String = line.strip_edges()
			if l.is_empty() or l.begins_with(";") or l.begins_with("["):
				continue
			var eq: int = l.find("=")
			if eq <= 0:
				continue
			var k: String = l.substr(0, eq).strip_edges()
			if not out.has(k):
				out[k] = l.substr(eq + 1).strip_edges()
	_cache[name] = out
	return out

static func text(name: String, key: String, fallback: String = "") -> String:
	return String(table(name).get(key, fallback))
