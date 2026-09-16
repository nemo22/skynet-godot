## The trigger LOCK — the reviewed graph of every shipped map, pinned.
##
## Step 1 wrote a map's triggers down as a graph (trigger_graph.gd). This
## is the other half of the same idea (docs plan §5 layer (a)): the graph
## as it was REVIEWED, one line per node, in a file that is committed.
## Change a row of scripts/triggers/rules_*.gd, or the MAP parser under
## it, and anything that moves what a trigger DOES moves a line here —
## `--verify-graph` then names the map, the node and the difference,
## instead of the change being found in play three missions later.
##
## A line is
##
##   217 07bb4 EF use:eye/3d/r60+26/always/nolatch
##       chain[07bb4* 07b90:DB 07b6c:F0] first[snd40 exit213/0]
##       second[snd40 exit213/0] 4f2a9c31
##
##   map     the map's number
##   id      the node's offset in the MAP record block
##   act     its action byte (UPPER hex — ids are lower, so the two can
##           never be mistaken for each other, by a reader or by the
##           hygiene check)
##   modes   how it is set off and from where: origin, metric,
##           radius+pad, re-arm, and whether the port latches it
##   chain   the ObjFlipLink walk from it, head first; `*` marks an 0xEF
##           node forcing its own bit back on; `end:` when the walk does
##           not simply run out of links
##   first   what the first activation comes to
##   second  and the second
##   hash    sha256 of everything the graph knows about the node that the
##           line does not spell out — the rule row and its provenance,
##           the requires/edge templates, who links in, who can flip it,
##           its warnings — so nothing moves unseen behind a line that
##           still reads the same
##
## Only ids, act bytes, numbers, keywords and hashes are ever written:
## no entity names, no map names beyond the number, none of the game's
## own words, no paths and nothing about the machine that generated it.
## hygiene() holds the whole permitted vocabulary and fails on anything
## else, so the file can live in the public repository.
##
## Maps the shipped archive does not hold — an edited map under mods/,
## another game's data — cannot be pinned by a file generated from the
## shipped ones: those are reported "unpinned" and pass.

extends RefCounted

const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

const FORMAT: String = "skynet.triggers.lock"
## Bump when the LINE SHAPE changes (the lock is then rewritten wholesale).
const LOCK_VERSION: int = 1

## The header comment, fixed word for word: hygiene() accepts no other
## comment line, so no prose can ever creep into the file.
const HEAD: PackedStringArray = [
	"# generated - rewrite with --accept-lock, check with --verify-graph",
	"# ids are lower hex offsets, act bytes upper hex; keywords, numbers and hashes only",
]

## Warning classes counted per map in the header line (trigger_dump.CLASSES).
const CLASSES: PackedStringArray = ["undecoded_act", "cycle", "dangling_link",
	"unreachable", "even_fan_in", "outside_border"]

## Activation modes, shortened. The graph's names are long enough to read
## in a dump; a lock line wants one word.
const MODE_SHORT: Dictionary = {
	"use_key": "use", "prox_enter": "prox", "touch_arm": "touch",
	"shot_each": "shot", "shot_death": "death", "path_end": "path",
	"counter": "counter", "chain": "chain",
}
const METRIC_SHORT: Dictionary = {"3d": "3d", "2d+window": "2dw"}
const REARM_SHORT: Dictionary = {"always": "always", "chain": "onchain", "never": "never"}

# ---------------------------------------------------------------------
# Where it lives
# ---------------------------------------------------------------------
## The lock of a game — "" for one that has none. Future Shock runs
## SkyNET's act table informationally (rules_shock.gd), so its graph is
## reviewed but never pinned.
static func lock_path(game: String = "") -> String:
	var g: String = game if not game.is_empty() else TriggerGraph.current_game()
	return "res://tests/rules/skynet.triggers.lock" if g == "skynet" else ""

static func lock_text(game: String = "") -> String:
	var p: String = lock_path(game)
	if p.is_empty() or not FileAccess.file_exists(p):
		return ""
	return FileAccess.get_file_as_string(p)

## Is this map replaced by an edited copy outside the shipped archive?
## Such a map's graph is whatever the mod says; the lock cannot speak for it.
static func is_modded(map_name: String) -> bool:
	return FileAccess.file_exists(SkynetPaths.mods_dir() + ("/maps/%s" % map_name.to_upper()))

# ---------------------------------------------------------------------
# Generating
# ---------------------------------------------------------------------
## Every shipped map's lines, in map then id order. `only` narrows it to
## a few map names while a rule is being worked on; empty means all.
## Returns {"text", "maps", "nodes", "chains", "missing", "modded"}.
static func build(only: PackedStringArray = PackedStringArray()) -> Dictionary:
	var game: String = TriggerGraph.current_game()
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		return {"text": "", "maps": 0, "nodes": 0, "chains": 0,
			"missing": PackedStringArray(), "modded": PackedStringArray()}
	var names: PackedStringArray = _map_names(bsa, only)
	var body: PackedStringArray = PackedStringArray()
	var pinned: int = 0
	var nodes: int = 0
	var chains: int = 0
	var missing := PackedStringArray()
	var modded := PackedStringArray()
	for name in names:
		if is_modded(name):
			modded.append(name)
			continue
		var bytes: PackedByteArray = bsa.read(name)
		if bytes.is_empty():
			missing.append(name)
			continue
		var one: Dictionary = map_lines(name, bytes, game)
		if one.is_empty():
			missing.append(name)
			continue
		pinned += 1
		body.append(String(one["head"]))
		body.append_array(one["lines"] as PackedStringArray)
		nodes += int(one["nodes"])
		chains += int(one["chains"])
	bsa.close()
	var out: PackedStringArray = PackedStringArray()
	out.append_array(HEAD)
	out.append("format %s %d" % [FORMAT, LOCK_VERSION])
	out.append("graph %d" % TriggerGraph.GRAPH_VERSION)
	out.append("game %s" % game)
	out.append("rules %s" % String(TriggerGraph.rules_for(game).rules_hash()))
	out.append("maps %d" % pinned)
	out.append("nodes %d" % nodes)
	out.append("chains %d" % chains)
	out.append_array(body)
	return {"text": "\n".join(out) + "\n", "maps": pinned, "nodes": nodes,
		"chains": chains, "missing": missing, "modded": modded}

## Every MAP entry with a numeric suffix, sorted. `only` keeps just those.
static func _map_names(bsa, only: PackedStringArray) -> PackedStringArray:
	var want: Dictionary = {}
	for n in only:
		want[n.to_upper()] = true
	var names := PackedStringArray()
	for e in bsa.entries():
		var nm: String = e.name.to_upper()
		if not nm.begins_with("MAP.") or not nm.get_extension().is_valid_int():
			continue
		if want.is_empty() or want.has(nm):
			names.append(nm)
	names.sort()
	return names

## One map: its header line and one line per node, ids ascending.
static func map_lines(map_name: String, bytes: PackedByteArray,
		game: String = "") -> Dictionary:
	var g: String = game if not game.is_empty() else TriggerGraph.current_game()
	var graph: Dictionary = TriggerGraph.build_from_bytes(map_name, bytes, g)
	if graph.is_empty():
		return {}
	var num: int = int(graph.get("map", -1))
	var nodes: Array = (graph.get("nodes", []) as Array).duplicate()
	nodes.sort_custom(func(a, b): return int((a as Dictionary)["id"]) < int((b as Dictionary)["id"]))
	var lines := PackedStringArray()
	for n in nodes:
		lines.append(node_line(num, n as Dictionary))
	var counts: Dictionary = graph.get("counts", {})
	var classes: Dictionary = counts.get("classes", {})
	var warn := PackedStringArray()
	for c in CLASSES:
		if classes.has(c):
			warn.append("%s:%d" % [c, int(classes[c])])
	for c in classes:                       # a class CLASSES does not list yet
		if not CLASSES.has(String(c)):
			warn.append("%s:%d" % [String(c), int(classes[c])])
	var head: String = "map %d src %s nodes %d chains %d" % [num, _sha(bytes),
		nodes.size(), int(counts.get("chains", 0))]
	if not warn.is_empty():
		head += " warn " + ",".join(warn)
	return {"head": head, "lines": lines, "nodes": nodes.size(),
		"chains": int(counts.get("chains", 0))}

## One node as one line.
static func node_line(map_num: int, n: Dictionary) -> String:
	return "%d %05x %02X %s chain[%s] first[%s] second[%s] %s" % [
		map_num, int(n.get("id", 0)), int(n.get("act", 0)),
		_modes(n.get("modes", [])), _chain(n.get("chain", {})),
		_fx(n.get("first", [])), _fx(n.get("second", [])), _node_hash(n)]

## The activation modes, comma separated; "-" when nothing can set the
## node off at all (a gate whose state bits say the DOS handler never runs
## and that no chain reaches).
static func _modes(modes: Array) -> String:
	if modes.is_empty():
		return "-"
	var out := PackedStringArray()
	for m in modes:
		var d: Dictionary = m
		var name: String = String(MODE_SHORT.get(String(d.get("mode", "chain")), "chain"))
		var parts := PackedStringArray()
		if d.has("origin"):
			parts.append(String(d["origin"]))
		if d.has("metric"):
			parts.append(String(METRIC_SHORT.get(String(d["metric"]), "3d")))
		if d.has("radius"):
			var pad: float = float(d.get("pad", 0.0))
			parts.append("r%d%s" % [int(float(d["radius"])),
				("+%d" % int(pad)) if pad > 0.0 else ""])
		if d.has("window"):
			parts.append("w%d" % int(float(d["window"])))
		if d.has("hp"):
			parts.append("hp%d" % int(d["hp"]))
		if d.has("at"):
			parts.append("at%d" % int(d["at"]))
		if d.has("rearm"):
			parts.append(String(REARM_SHORT.get(String(d["rearm"]), "always")))
		if d.has("latch"):
			# The port's leave/re-enter latch on 0xF1/0xF2 is an open question
			# for the owner (plan §8.3) — pinned here so an answer shows up.
			parts.append("nolatch" if String(d["latch"]) == "none" else "latch")
		out.append(name if parts.is_empty() else "%s:%s" % [name, "/".join(parts)])
	return ",".join(out)

## The chain walk: the head bare, every later step with the act byte it
## flips, `*` where an 0xEF node forces its own bit back on, and the end
## of the walk when it is not a plain run-out-of-links.
static func _chain(chain: Dictionary) -> String:
	var steps: Array = chain.get("walk", [])
	if steps.is_empty():
		return "-"
	var out := PackedStringArray()
	for i in steps.size():
		var s: Array = steps[i]
		var star: String = "*" if String(s[2]).ends_with("force1") else ""
		out.append(("%05x%s" % [int(s[0]), star]) if i == 0
			else ("%05x:%02X%s" % [int(s[0]), int(s[1]), star]))
	var end: String = String(chain.get("end", "link_end"))
	if end != "link_end":
		out.append("end:" + end)
	return " ".join(out)

## The simulated effects. The graph writes an undecoded act in lower hex
## ("act1a@…"); the lock keeps act bytes upper, so it is rewritten here.
static func _fx(fx: Array) -> String:
	if fx.is_empty():
		return "-"
	var out := PackedStringArray()
	for f in fx:
		var t: String = String(f)
		if t.begins_with("act") and t.length() > 5 and t[5] == "@":
			t = "act" + t.substr(3, 2).to_upper() + t.substr(5)
		out.append(t)
	return " ".join(out)

## Everything the graph knows about the node that the readable half does
## not spell out. Prose is left out on purpose (rules_hash already moves
## on a note), so a comment edit does not rewrite 4 700 lines.
static func _node_hash(n: Dictionary) -> String:
	var modes: Array = []
	for m in (n.get("modes", []) as Array):
		var d: Dictionary = (m as Dictionary).duplicate(true)
		d.erase("note")
		modes.append(d)
	var warn: Array = []
	for w in (n.get("warn", []) as Array):
		warn.append(String((w as Dictionary).get("class", "")))
	var chain: Dictionary = n.get("chain", {})
	var payload: Dictionary = {
		"act": n.get("act", 0), "state": n.get("state", 0), "hp": n.get("hp", 0),
		"link": n.get("link", 0), "variant": n.get("variant", 0),
		"marker": n.get("marker", -1), "rule": n.get("rule", {}),
		"modes": modes, "fx": n.get("fx", {}),
		"walk": chain.get("walk", []), "end": chain.get("end", ""),
		"in": chain.get("in", []), "by": chain.get("by", []),
		"first": n.get("first", []), "second": n.get("second", []),
		"warn": warn,
	}
	return JSON.stringify(payload, "", true).sha256_text().substr(0, 8)

static func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode().substr(0, 16)

# ---------------------------------------------------------------------
# Reading it back
# ---------------------------------------------------------------------
## The lock as data: {"header", "order" (map numbers), "maps" {num →
## {"head", "src", "lines" {id → line}}}, "errors"}.
static func parse(text: String) -> Dictionary:
	var header: Dictionary = {}
	var maps: Dictionary = {}
	var order: Array = []
	var errors := PackedStringArray()
	var cur: Dictionary = {}
	for raw in text.split("\n"):
		var line: String = raw.strip_edges(false, true)
		if line.is_empty() or line.begins_with("#"):
			continue
		var tok: PackedStringArray = line.split(" ", false)
		match tok[0]:
			"format":
				header["format"] = tok[1] if tok.size() > 1 else ""
				header["lock_version"] = int(tok[2]) if tok.size() > 2 else 0
			"graph":
				header["graph_version"] = int(tok[1]) if tok.size() > 1 else 0
			"game":
				header["game"] = tok[1] if tok.size() > 1 else ""
			"rules":
				header["rules_hash"] = tok[1] if tok.size() > 1 else ""
			"maps", "nodes", "chains":
				header[tok[0]] = int(tok[1]) if tok.size() > 1 else 0
			"map":
				var num: int = int(tok[1]) if tok.size() > 1 else -1
				cur = {"head": line, "src": tok[3] if tok.size() > 3 else "",
					"lines": {}, "ids": []}
				maps[num] = cur
				order.append(num)
			_:
				if not tok[0].is_valid_int() or tok.size() < 3 or cur.is_empty():
					errors.append(line)
					continue
				var id: int = tok[1].hex_to_int()
				(cur["lines"] as Dictionary)[id] = line
				(cur["ids"] as Array).append(id)
	return {"header": header, "order": order, "maps": maps, "errors": errors}

# ---------------------------------------------------------------------
# --verify-graph
# ---------------------------------------------------------------------
## Rebuild every shipped map and diff it against the lock. `spec` is ""
## or "all" for all of them, or a list of map numbers ("210,217") to
## narrow it down while a rule is being worked on. All 122 take about a
## second, so the suites run the whole thing. Returns {"fails",
## "checked", "unpinned", "ms", "report"} — `report` is what to print,
## `fails` what to exit on.
static func verify(spec: String = "") -> Dictionary:
	var t0: int = Time.get_ticks_msec()
	var report := PackedStringArray()
	var game: String = TriggerGraph.current_game()
	var path: String = lock_path(game)
	if path.is_empty():
		report.append("[lock] %s data is unpinned — no lock is generated for it" % game)
		return _done(0, 0, 1, t0, report)
	var text: String = lock_text(game)
	if text.is_empty():
		report.append("[lock] there is no lock to check against — write one with --accept-lock")
		return _done(1, 0, 0, t0, report)
	var lock: Dictionary = parse(text)
	if not (lock["errors"] as PackedStringArray).is_empty():
		report.append("[lock] %d unreadable lines in the lock"
			% (lock["errors"] as PackedStringArray).size())
		return _done(1, 0, 0, t0, report)
	var header: Dictionary = lock["header"]
	if String(header.get("format", "")) != FORMAT \
			or int(header.get("lock_version", 0)) != LOCK_VERSION \
			or int(header.get("graph_version", 0)) != TriggerGraph.GRAPH_VERSION \
			or String(header.get("game", "")) != game:
		report.append("[lock] the lock was written by another build (format %s v%s, graph %s, game %s)"
			% [str(header.get("format", "?")), str(header.get("lock_version", "?")),
			   str(header.get("graph_version", "?")), str(header.get("game", "?"))])
		return _done(1, 0, 0, t0, report)
	var rules_now: String = String(TriggerGraph.rules_for(game).rules_hash())
	if String(header.get("rules_hash", "")) != rules_now:
		# A note edited in the rules table moves this and nothing else. It
		# is worth saying; it is not worth failing on — the LINES decide.
		report.append("[lock] note: the rules fingerprint moved (%s → %s); rewrite the header with --accept-lock"
			% [str(header.get("rules_hash", "?")), rules_now])

	var only := PackedStringArray()
	var s: String = spec.strip_edges()
	if not s.is_empty() and s != "all":
		for part in s.split(","):
			if part.strip_edges().is_valid_int():
				only.append("MAP.%03d" % int(part))
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		report.append("[lock] cannot open the map archive")
		return _done(1, 0, 0, t0, report)
	var names: PackedStringArray = _map_names(bsa, only)
	var fails: int = 0
	var checked: int = 0
	var unpinned: int = 0
	var seen: Dictionary = {}
	# The archive holds one MAP entry whose suffix is not a number, so it
	# has no map number to pin a line under. Say so rather than pass over
	# it in silence.
	if only.is_empty():
		for e in bsa.entries():
			var nm: String = e.name.to_upper()
			if nm.begins_with("MAP.") and not nm.get_extension().is_valid_int():
				unpinned += 1
				report.append("[lock] %s unpinned — its name carries no map number" % nm)
	for name in names:
		var num: int = int(name.get_extension())
		seen[num] = true
		if is_modded(name):
			unpinned += 1
			report.append("[lock] MAP.%03d unpinned — replaced outside the shipped data" % num)
			continue
		if not (lock["maps"] as Dictionary).has(num):
			unpinned += 1
			report.append("[lock] MAP.%03d unpinned — the lock does not hold this map" % num)
			continue
		var bytes: PackedByteArray = bsa.read(name)
		var built: Dictionary = map_lines(name, bytes, game) if not bytes.is_empty() else {}
		if built.is_empty():
			fails += 1
			report.append("[lock] MAP.%03d FAILED — the map cannot be read or parsed" % num)
			continue
		checked += 1
		var diff: PackedStringArray = _diff(num, lock["maps"][num], built)
		if not diff.is_empty():
			fails += 1
			report.append_array(diff)
	bsa.close()
	for num in (lock["maps"] as Dictionary):
		if not seen.has(int(num)) and (only.is_empty() or _wanted(only, int(num))):
			fails += 1
			report.append("[lock] MAP.%03d FAILED — pinned, but the data does not hold it" % int(num))
	if fails == 0:
		report.append("[lock] %d maps match the lock%s" % [checked,
			"" if unpinned == 0 else ", %d unpinned" % unpinned])
	else:
		report.append("[lock] %d of %d maps differ from the lock — review, then --accept-lock"
			% [fails, checked])
	return _done(fails, checked, unpinned, t0, report)

static func _wanted(only: PackedStringArray, num: int) -> bool:
	return ("MAP.%03d" % num) in only

static func _done(fails: int, checked: int, unpinned: int, t0: int,
		report: PackedStringArray) -> Dictionary:
	return {"fails": fails, "checked": checked, "unpinned": unpinned,
		"ms": Time.get_ticks_msec() - t0, "report": report}

## One map's differences, as lines to print. Long diffs are cut off —
## a rules change moves thousands, and the first few say what it was.
const DIFF_SHOWN: int = 12

static func _diff(num: int, pinned: Dictionary, built: Dictionary) -> PackedStringArray:
	var was: Dictionary = pinned["lines"]
	var now: Dictionary = {}
	for line in (built["lines"] as PackedStringArray):
		now[line.split(" ", false)[1].hex_to_int()] = line
	var moved: Array = []
	var gone: Array = []
	var added: Array = []
	var ids: Array = was.keys()
	ids.sort()
	for id in ids:
		if not now.has(id):
			gone.append(id)
		elif String(now[id]) != String(was[id]):
			moved.append(id)
	var nids: Array = now.keys()
	nids.sort()
	for id in nids:
		if not was.has(id):
			added.append(id)
	var head_now: String = String(built["head"])
	var head_was: String = String(pinned["head"])
	if moved.is_empty() and gone.is_empty() and added.is_empty() and head_now == head_was:
		return PackedStringArray()
	var out := PackedStringArray()
	out.append("[lock] MAP.%03d FAILED — %d nodes moved, %d gone, %d new"
		% [num, moved.size(), gone.size(), added.size()])
	if head_now != head_was:
		out.append("        was %s" % head_was)
		out.append("        now %s" % head_now)
	var shown: int = 0
	for id in moved:
		if shown >= DIFF_SHOWN:
			break
		shown += 1
		# Both halves of a line can move, or only the hash: the readable
		# half says what a trigger does, the hash covers the rule row, the
		# activation templates, who can flip it and its warnings.
		var behind: bool = String(was[id]).rsplit(" ", true, 1)[0] \
			== String(now[id]).rsplit(" ", true, 1)[0]
		out.append("        ~ %05x%s" % [int(id), "  (behind the line)" if behind else ""])
		out.append("          was %s" % String(was[id]))
		out.append("          now %s" % String(now[id]))
	for id in gone:
		if shown >= DIFF_SHOWN:
			break
		shown += 1
		out.append("        - %s" % String(was[id]))
	for id in added:
		if shown >= DIFF_SHOWN:
			break
		shown += 1
		out.append("        + %s" % String(now[id]))
	var total: int = moved.size() + gone.size() + added.size()
	if total > shown:
		out.append("        … and %d more" % (total - shown))
	return out

# ---------------------------------------------------------------------
# --accept-lock
# ---------------------------------------------------------------------
## Rewrite the lock from the current rules and the shipped maps. A
## deliberate act: everything the file pinned is replaced by what the
## code says today, so it belongs after the difference has been read.
static func accept() -> Dictionary:
	var game: String = TriggerGraph.current_game()
	var path: String = lock_path(game)
	if path.is_empty():
		return {"ok": false, "why": "%s data has no lock" % game, "path": ""}
	var t0: int = Time.get_ticks_msec()
	var made: Dictionary = build()
	var text: String = String(made["text"])
	if text.is_empty() or int(made["maps"]) == 0:
		return {"ok": false, "why": "no map could be built", "path": path}
	var bad: PackedStringArray = hygiene(text)
	if not bad.is_empty():
		return {"ok": false, "why": "the generated lock is not clean: %s" % bad[0], "path": path}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "why": "cannot write the lock", "path": path}
	f.store_string(text)
	f.close()
	return {"ok": true, "why": "", "path": path, "maps": made["maps"],
		"nodes": made["nodes"], "chains": made["chains"], "bytes": text.length(),
		"ms": Time.get_ticks_msec() - t0, "modded": made["modded"],
		"missing": made["missing"]}

# ---------------------------------------------------------------------
# Hygiene — the whole permitted vocabulary, and nothing else
# ---------------------------------------------------------------------
## What is wrong with this text, line by line ("" complaints = clean).
##
## The lock is committed to a public repository, so it must carry no
## entity name, none of the game's own words, no path, no address and no
## character outside printable ASCII. Rather than hunting for what must
## not be there, this accepts ONLY what the generator above can emit:
## every line is matched against its own grammar, and every word in it
## against a closed list. Anything new — a name leaking out of the map
## header, a note, a machine path — fails on the first line that holds it.
static func hygiene(text: String) -> PackedStringArray:
	var bad := PackedStringArray()
	var head := RegEx.new()
	head.compile("^(format %s \\d+|graph \\d+|game (skynet|shock)|rules [0-9a-f]{16}|(maps|nodes|chains) \\d+)$" % FORMAT.replace(".", "\\."))
	var mapline := RegEx.new()
	mapline.compile("^map \\d{1,4} src [0-9a-f]{16} nodes \\d+ chains \\d+( warn [a-z_]+:\\d+(,[a-z_]+:\\d+)*)?$")
	var node := RegEx.new()
	node.compile("^(\\d{1,4}) ([0-9a-f]{5}) ([0-9A-F]{2}) (\\S+) chain\\[([^\\]\\[]*)\\] first\\[([^\\]\\[]*)\\] second\\[([^\\]\\[]*)\\] ([0-9a-f]{8})$")
	var mode := RegEx.new()
	mode.compile("^(use|prox|touch|shot|death|path|counter|chain)(:[a-z0-9/+]+)?$")
	var part := RegEx.new()
	part.compile("^(eye|feet|3d|2dw|always|onchain|never|latch|nolatch|r\\d+(\\+\\d+)?|w\\d+|hp\\d+|at\\d+)$")
	var step := RegEx.new()
	step.compile("^([0-9a-f]{5}(:[0-9A-F]{2})?\\*?|end:(link_end|limit|(actor|cycle|dangling)@[0-9a-f]{5}))$")
	var eff := RegEx.new()
	eff.compile("^(hint\\d+|obj\\d+|fail|voice\\d+|snd\\d+|loop\\d+|waterabs|water[+-]\\d+"
		+ "|exit(back|\\d+)/\\d+|(spawn|demolish|path|spin)@[0-9a-f]{5}"
		+ "|break@[0-9a-f]{5}:\\d+|act[0-9A-F]{2}@[0-9a-f]{5}"
		+ "|light_(toggle|flicker|strobe|fade_up|fade_down)@[0-9a-f]{5}"
		+ "|move@[0-9a-f]{5}:(slide5f|slide|swing|jump|rot)[XYZ][+-]\\d+)$")
	var n: int = 0
	for raw in text.split("\n"):
		n += 1
		# The lock is written with plain newlines, but git hands a Windows
		# working copy back with carriage returns in front of them; that is
		# a checkout detail, not something the generator put there.
		var line: String = String(raw).trim_suffix("\r")
		for i in line.length():
			var c: int = line.unicode_at(i)
			if c < 0x20 or c > 0x7E:
				bad.append("line %d: a character outside printable ASCII" % n)
				break
		if line.strip_edges().is_empty():
			continue
		if line.begins_with("#"):
			if not (line in HEAD):
				bad.append("line %d: a comment that is not the fixed header" % n)
			continue
		if head.search(line) != null:
			continue
		if mapline.search(line) != null:
			if line.contains(" warn "):
				for w in line.get_slice(" warn ", 1).split(",", false):
					if not CLASSES.has(String(w).get_slice(":", 0)):
						bad.append("line %d: %s is not a warning class" % [n, String(w)])
			continue
		var m: RegExMatch = node.search(line)
		if m == null:
			bad.append("line %d: not a node line" % n)
			continue
		var modes: String = m.get_string(4)
		if modes != "-":
			for t in modes.split(",", false):
				var mm: RegExMatch = mode.search(String(t))
				if mm == null:
					bad.append("line %d: %s is not an activation mode" % [n, String(t)])
					continue
				if mm.get_string(2).is_empty():
					continue
				for p in mm.get_string(2).substr(1).split("/", false):
					if part.search(String(p)) == null:
						bad.append("line %d: %s is not a measure" % [n, String(p)])
		var walk: String = m.get_string(5)
		if walk != "-":
			for t in walk.split(" ", false):
				if step.search(String(t)) == null:
					bad.append("line %d: %s is not a chain step" % [n, String(t)])
		for g in [6, 7]:
			var fx: String = m.get_string(g)
			if fx == "-":
				continue
			for t in fx.split(" ", false):
				if eff.search(String(t)) == null:
					bad.append("line %d: %s is not an effect" % [n, String(t)])
	return bad
