## Dev tool: print a map's generated trigger graph for review.
##
##   godot --headless --path . res://scenes/map_dump.tscn -- --triggers=215
##   godot --headless --path . res://scenes/map_dump.tscn -- --triggers=all
##
## A list of map numbers prints every node of each: what it is, the DOS
## bytes it came from, the rule that applies, how the player can set it
## off, the chain it flips and what the first and second activation do.
## `all` walks every map of the game the data directory holds and prints
## one line each plus the warnings, with a total per warning class at the
## end — the review pass of plan §7 step 1.
##
## The graph is built here rather than read from converted/: the dump has
## to show what the CURRENT rules say, whatever is in the cache.

extends RefCounted

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")

## Warning classes, in the order the summary lists them.
const CLASSES: PackedStringArray = ["undecoded_act", "cycle", "dangling_link",
	"unreachable", "even_fan_in", "outside_border"]

static func run(spec: String) -> void:
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		print("[triggers] cannot open %s" % SkynetPaths.map_archive)
		return
	var game: String = TriggerGraph.current_game()
	var wanted: PackedStringArray = PackedStringArray()
	var detail: bool = true
	if spec.strip_edges().is_empty() or spec == "all":
		detail = false
		for e in bsa.entries():
			var nm: String = e.name.to_upper()
			if nm.begins_with("MAP.") and nm.get_extension().is_valid_int():
				wanted.append(nm)
		wanted.sort()
	else:
		for s in spec.split(","):
			wanted.append("MAP.%03d" % int(s))
	var totals: Dictionary = {}
	var t_all: int = Time.get_ticks_msec()
	var nodes_all: int = 0
	var chains_all: int = 0
	var built: int = 0
	var acts_seen: Dictionary = {}          # undecoded act → how many nodes
	var unreachable: Dictionary = {}        # kind → how many nodes
	for name in wanted:
		var bytes := bsa.read(name)
		if bytes.is_empty():
			print("%s: missing" % name)
			continue
		var t0: int = Time.get_ticks_usec()
		var g: Dictionary = TriggerGraph.build_from_bytes(name, bytes, game)
		var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
		if g.is_empty():
			print("%s: unreadable" % name)
			continue
		built += 1
		var counts: Dictionary = g.get("counts", {})
		nodes_all += int(counts.get("nodes", 0))
		chains_all += int(counts.get("chains", 0))
		for k in (counts.get("classes", {}) as Dictionary):
			totals[k] = int(totals.get(k, 0)) + int(counts["classes"][k])
		for w in (g.get("warn", []) as Array):
			var wc: String = String((w as Dictionary).get("class", ""))
			var d: String = String((w as Dictionary).get("detail", ""))
			if wc == "undecoded_act":
				acts_seen[d.get_slice(":", 0)] = int(acts_seen.get(d.get_slice(":", 0), 0)) + 1
			elif wc == "unreachable":
				# "a mover nothing links to …" → the kind is the second word.
				var kind: String = d.get_slice(" ", 1)
				unreachable[kind] = int(unreachable.get(kind, 0)) + 1
		print(_headline(name, g, ms))
		if detail:
			_detail(g)
		elif int(counts.get("warnings", 0)) > 0:
			for line in _warn_lines(g):
				print(line)
	bsa.close()
	print("")
	var rules = TriggerGraph.rules_for(game)
	print("[triggers] %d maps, %d nodes, %d chains in %.2f s (%s rules %s%s)"
		% [built, nodes_all, chains_all, float(Time.get_ticks_msec() - t_all) / 1000.0,
		   game, String(rules.rules_hash()),
		   ", INFORMATIONAL" if rules.informational() else ""])
	var any: bool = false
	for c in CLASSES:
		if totals.has(c):
			any = true
			print("[triggers]   %-16s %d" % [c, int(totals[c])])
	for c in totals:
		if not CLASSES.has(String(c)):
			any = true
			print("[triggers]   %-16s %d" % [String(c), int(totals[c])])
	if not any:
		print("[triggers]   no warnings")
	if not acts_seen.is_empty():
		var keys: Array = acts_seen.keys()
		keys.sort()
		print("[triggers] undecoded acts in use:")
		for k in keys:
			print("[triggers]   %-12s on %d nodes" % [String(k), int(acts_seen[k])])
	if not unreachable.is_empty():
		var kinds: Array = unreachable.keys()
		kinds.sort()
		print("[triggers] unreachable by kind:")
		for k in kinds:
			print("[triggers]   %-12s %d" % [String(k), int(unreachable[k])])

static func _headline(name: String, g: Dictionary, ms: float) -> String:
	var counts: Dictionary = g.get("counts", {})
	return "%s  mission %s  %s  %d entities → %d nodes, %d chains, %d warnings %s  (%.0f ms)" % [
		name, str(g.get("mission", -1)),
		"outdoor" if bool(g.get("outdoor", false)) else "indoor",
		int(counts.get("entities", 0)), int(counts.get("nodes", 0)),
		int(counts.get("chains", 0)), int(counts.get("warnings", 0)),
		str(counts.get("classes", {})), ms]

static func _warn_lines(g: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for w in (g.get("warn", []) as Array):
		var d: Dictionary = w
		out.append("    ! %-15s @%05x  %s" % [String(d.get("class", "?")),
			int(d.get("id", 0)), String(d.get("detail", ""))])
	return out

static func _detail(g: Dictionary) -> void:
	for n in (g.get("nodes", []) as Array):
		for line in node_lines(n as Dictionary):
			print(line)
	var warn: Array = g.get("warn", [])
	if not warn.is_empty():
		print("  warnings:")
		for line in _warn_lines(g):
			print(line)

## One node as three to six lines: what it is, how it is set off, the
## chain it flips and what the first two activations do.
static func node_lines(n: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var rule: Dictionary = n.get("rule", {})
	var label: String = String(n.get("name", ""))
	if label.is_empty():
		if int(n.get("marker", -1)) >= 0:
			label = "marker%d" % int(n["marker"])
		elif n.has("sprite"):
			label = "sprite%d" % int(n["sprite"])
		elif int(n.get("variant", 0)) == 2:
			label = "light"
	out.append("  @%05x %-12s v%d act %02x st %02x hp %-4d link %05x  %s [%s %s]%s" % [
		int(n.get("id", 0)), label, int(n.get("variant", 0)), int(n.get("act", 0)),
		int(n.get("state", 0)), int(n.get("hp", 0)), int(n.get("link", 0)),
		String(rule.get("kind", "?")), String(rule.get("prov", "?")),
		String(rule.get("dos", "")) if not String(rule.get("dos", "")).is_empty() else "-",
		"  " + str(n.get("fx", {})) if not (n.get("fx", {}) as Dictionary).is_empty() else ""])
	for m in (n.get("modes", []) as Array):
		# A bare "chain" mode says only what the in[] list below already
		# shows; the lines worth reading are the player-driven ones.
		if String((m as Dictionary).get("mode", "")) == "chain":
			continue
		out.append("        %s" % _mode_line(m as Dictionary))
	var chain: Dictionary = n.get("chain", {})
	var steps: Array = chain.get("walk", [])
	if not steps.is_empty():
		var parts := PackedStringArray()
		for s in steps:
			parts.append("%05x:%02x%s" % [int(s[0]), int(s[1]),
				"*" if String(s[2]).ends_with("force1") else ""])
		out.append("        chain %s  end %s%s%s" % [" > ".join(parts),
			String(chain.get("end", "?")),
			("  in[%s]" % _hex_list(chain.get("in", []))) if not (chain.get("in", []) as Array).is_empty() else "",
			("  by[%s]" % _hex_list(chain.get("by", []))) if (chain.get("by", []) as Array).size() > 1 else ""])
	var first: Array = n.get("first", [])
	var second: Array = n.get("second", [])
	if not first.is_empty() or not second.is_empty():
		out.append("        first[%s] second[%s]" % [
			" ".join(PackedStringArray(first)) if not first.is_empty() else "-",
			" ".join(PackedStringArray(second)) if not second.is_empty() else "-"])
	for w in (n.get("warn", []) as Array):
		out.append("        ! %s: %s" % [String((w as Dictionary).get("class", "?")),
			String((w as Dictionary).get("detail", ""))])
	return out

static func _mode_line(m: Dictionary) -> String:
	var bits := PackedStringArray()
	bits.append(String(m.get("mode", "?")))
	if m.has("origin") or m.has("metric"):
		bits.append("%s/%s" % [String(m.get("origin", "?")), String(m.get("metric", "?"))])
	if m.has("radius"):
		var pad: float = float(m.get("pad", 0.0))
		bits.append("r%.0f%s" % [float(m["radius"]), ("+%.0f" % pad) if pad > 0.0 else ""])
	if m.has("window"):
		bits.append("y±%.0f" % float(m["window"]))
	if m.has("at"):
		bits.append("at %d" % int(m["at"]))
	if m.has("hp"):
		bits.append("hp %d" % int(m["hp"]))
	for k in ["requires", "edge", "rearm", "latch"]:
		if m.has(k):
			bits.append("%s %s" % [k, str(m[k])])
	bits.append("(%s)" % String(m.get("prov", "?")))
	return " ".join(bits)

static func _hex_list(ids: Array) -> String:
	var out := PackedStringArray()
	for i in ids:
		out.append("%05x" % int(i))
	return " ".join(out)
