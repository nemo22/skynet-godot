## Graph against bus — the provable half of M3 step 3.
##
## Step 1 predicts, on paper, what one node's first activation comes to
## (trigger_graph._simulate → `first[]`); step 2 pins that prediction in
## the lock. Neither touches the running game. The event bus
## (trigger_bus.gd) makes the running game say what it actually did. This
## puts the two lists side by side, in ONE vocabulary — the graph's own
## effect tokens — and names what is missing and what is extra.
##
## It is deliberately a helper and not a test: the step-4 verifier drives
## the same comparison through the real input path (keys, walking, shots)
## over every map, and should be able to call `compare` and `token`
## unchanged. What varies is only how a node is set off, which is why
## `activate` is a small table of drivers rather than a script.
##
## What this cannot do, and does not pretend to: the order of the two
## lists is not the same thing. The graph runs every handler in
## ObjFlipLink walk order inside one activation; the port fires the cues
## in walk order but leaves the exits, movers, water, lights,
## destructibles, demolition and spawns to the per-tick sweeps, which
## have a fixed order of their own. So the comparison is by CONTENT — a
## multiset — and the order each side saw is reported for reading, not
## for judging.

extends RefCounted

const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")
const TriggerBus := preload("res://scripts/triggers/trigger_bus.gd")

## DOS axis 0/1/2 as the graph writes it.
const AXIS: PackedStringArray = ["X", "Y", "Z"]

# ---------------------------------------------------------------------
# One bus event in the graph's vocabulary
# ---------------------------------------------------------------------
## The graph's effect token for one announced event, or "" for an event
## the graph does not write down (every flip, every `fired`, and the
## countdown relay — the graph tokenises what a relay's CHAIN does, never
## the relay's own enable).
static func token(row: Dictionary) -> String:
	if String(row.get("ev", "")) != String(TriggerBus.EV_EFFECT):
		return ""
	var id: int = int(row.get("id", 0))
	var p: Dictionary = row.get("payload", {})
	match String(row.get("kind", "")):
		"objective":
			return "obj%d" % int(p.get("index", 0))
		"hint":
			return "hint%d" % int(p.get("index", 0))
		"fail":
			return "fail"
		"voice":
			return "voice%d" % int(p.get("voice", 0))
		"sound":
			return "snd%d" % int(p.get("sound", 0))
		"loop":
			return "loop%d" % int(p.get("loop", 0))
		"exit":
			return "exit%s/%d" % ["back" if bool(p.get("back", false))
				else str(int(p.get("map", 0))), int(p.get("set", 0))]
		"move":
			return "move@%05x:%s%s%+.0f" % [id, String(p.get("family", "")),
				AXIS[clampi(int(p.get("axis", 0)), 0, 2)], float(p.get("travel", 0.0))]
		"spin":
			return "spin@%05x" % id
		"destruct":
			return "break@%05x:%d" % [id, int(p.get("stage", 0))]
		"demolish":
			return "demolish@%05x" % id
		"spawn":
			return "spawn@%05x" % id
		"water":
			if bool(p.get("absolute", false)):
				return "waterabs"
			return "water%+d" % int(p.get("delta", 0))
		"light":
			return "light_%s@%05x" % [String(p.get("op", "")), id]
		"path":
			return "path@%05x" % id
	return ""

## Everything a recording bus heard, as graph tokens, in order.
static func tokens(history: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row in history:
		var t: String = token(row as Dictionary)
		if not t.is_empty():
			out.append(t)
	return out

# ---------------------------------------------------------------------
# Comparing
# ---------------------------------------------------------------------
## `want` (the graph) against `got` (the bus), by content. Returns
## {"ok", "want", "got", "missing", "extra"} — `missing` is what the
## graph promised and the game did not do, `extra` the other way round.
static func compare(want: Array, got: PackedStringArray) -> Dictionary:
	var left: Dictionary = _counts(want)
	var right: Dictionary = _counts(got)
	var missing := PackedStringArray()
	var extra := PackedStringArray()
	for t in left:
		for i in maxi(int(left[t]) - int(right.get(t, 0)), 0):
			missing.append(String(t))
	for t in right:
		for i in maxi(int(right[t]) - int(left.get(t, 0)), 0):
			extra.append(String(t))
	missing.sort()
	extra.sort()
	return {"ok": missing.is_empty() and extra.is_empty(),
		"want": want, "got": got, "missing": missing, "extra": extra}

static func _counts(list) -> Dictionary:
	var out: Dictionary = {}
	for t in list:
		var k: String = canon(String(t))
		out[k] = int(out.get(k, 0)) + 1
	return out

## A mover with NO TRAVEL has no direction, so the sign it is printed
## with is not a fact about it. Acts 0xBD-0xC0 are the zero slides (the
## handler table at 0x59b00 holds them with a travel word of 0), and two
## of MAP.272's gates run one: the graph's simulation flips the stored
## direction between the first activation and the second and prints
## `slideX-0` then `slideX+0`, while the mover node flips its own the
## other way round — two ways of writing the same nothing, which the
## comparison read as a missing token and an extra one.
static func canon(tok: String) -> String:
	if tok.ends_with("-0") or tok.ends_with("+0"):
		return tok.substr(0, tok.length() - 2) + "0"
	return tok

# ---------------------------------------------------------------------
# Setting a node off in the running game
# ---------------------------------------------------------------------
## How this node can be driven, from what the graph says can set it off.
## "use" covers the use key and walking in — both end in the one call the
## port makes for a single trigger; "hit" is a shot; "chain" is anything
## whose only starter is something else's chain, the countdown relay or
## the end of a vehicle path.
static func driver(node: Dictionary) -> String:
	for m in (node.get("modes", []) as Array):
		match String((m as Dictionary).get("mode", "")):
			"use_key", "prox_enter", "touch_arm":
				return "use"
			"shot_each", "shot_death":
				return "hit"
	return "chain"

## Set node `id` off once. `how` is a driver() name; `damage` is what a
## "hit" deals (enough to deplete, by default).
static func activate(level, id: int, how: String, damage: float = 1.0e6) -> bool:
	var e = level.map.entities_by_off.get(id)
	if e == null:
		return false
	var at: Vector3 = Vector3(float(e.x), -float(e.y), -float(e.z))
	at += level.origin as Vector3
	match how:
		"use":
			return level.behaviour.on_player_activate(id, at)
		"hit":
			return level.behaviour.obj_hit(id, damage)
		_:
			level.triggers.flip(id)
			return true

# ---------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------
## Fire node `id` of `level` once and compare what the bus heard with the
## graph's prediction for that node's FIRST activation.
##
## The player is kept a long way off for the ticks that follow, so the
## sweeps run (a door starts, an exit fires, the water moves) without any
## OTHER trigger being tripped by where he stands: this is one node's
## activation, not a walk through the level.
##
## Returns compare()'s dictionary plus "id", "map", "how" and "found".
static func check(level, graph: Dictionary, id: int, opts: Dictionary = {}) -> Dictionary:
	var node: Dictionary = node_of(graph, id)
	var how: String = String(opts.get("how", ""))
	if how.is_empty():
		how = driver(node)
	var out: Dictionary = {"id": id, "map": int(graph.get("map", -1)),
		"how": how, "found": not node.is_empty()}
	if node.is_empty():
		out.merge({"ok": false, "want": [], "got": PackedStringArray(),
			"missing": PackedStringArray(), "extra": PackedStringArray()})
		return out
	var bus = level.bus
	var away := Vector3(1.0e9, 0.0, 1.0e9)
	var dt: float = float(opts.get("dt", 0.05))
	# Let the level settle FIRST. A map starts some of its entities with
	# bit 0 already set — the radar dishes and sky domes that spin from
	# the first frame, the lights that flicker — and those announce
	# themselves on their first tick like anything else. They are not this
	# node's doing, and the graph's simulation leaves them out for exactly
	# that reason (trigger_graph._settle: "a rotator the map starts with
	# its bit already up is running whatever the player does"). Ticking
	# before the recording starts puts them behind us: each announces once
	# and, while its bit stays up, not again.
	for i in int(opts.get("settle", 4)):
		level.behaviour.tick(dt, away, away)
	bus.record(true)
	bus.clear()
	activate(level, id, how, float(opts.get("damage", 1.0e6)))
	for i in int(opts.get("ticks", 400)):
		level.behaviour.tick(dt, away, away)
	var heard: Array = bus.take()
	bus.record(false)
	out.merge(compare(node.get("first", []), tokens(heard)))
	return out

## The graph's node with this id ({} when the map has none).
static func node_of(graph: Dictionary, id: int) -> Dictionary:
	for n in (graph.get("nodes", []) as Array):
		if int((n as Dictionary).get("id", -1)) == id:
			return n
	return {}

## The graph of the map a level was built from.
static func graph_of(level) -> Dictionary:
	return TriggerGraph.build_from_bytes("MAP." + String(level.map_suffix),
		level.map_bytes)

## One line for a report: what matched, and what did not.
static func describe(res: Dictionary) -> String:
	var head: String = "MAP.%03d @%05x (%s)" % [int(res.get("map", -1)),
		int(res.get("id", 0)), String(res.get("how", "?"))]
	if not bool(res.get("found", false)):
		return head + " — the graph has no such node"
	if bool(res.get("ok", false)):
		var want: Array = res.get("want", [])
		return "%s — %d effects, graph and game agree%s" % [head, want.size(),
			"" if want.is_empty() else ": " + " ".join(PackedStringArray(want))]
	var parts := PackedStringArray()
	var missing: PackedStringArray = res.get("missing", PackedStringArray())
	var extra: PackedStringArray = res.get("extra", PackedStringArray())
	if not missing.is_empty():
		parts.append("the graph promised " + " ".join(missing))
	if not extra.is_empty():
		parts.append("the game also did " + " ".join(extra))
	return "%s — %s" % [head, "; ".join(parts)]
