## The trigger graph of a map — generated once at import, read-only.
##
## A SkyNET map drives everything that opens, breaks, plays, counts or
## ends the mission with three bytes per entity: an action id, a state
## byte and a link to the next entity of a chain (docs plan §1). Those
## bytes have been read straight by the runtime until now, each class of
## behaviour with its own idea of what they mean — which is why fixing
## one trigger broke another. This builds the whole of a map's trigger
## surface ONCE, from the records and scripts/triggers/rules_*.gd, into
## a plain data structure that can be printed, reviewed, pinned and
## (from step 3 on) played:
##
##   header    format, graph_version, rules_hash, game, map, source_hash,
##             outdoor, mission
##   nodes[]   identity, the DOS bytes, the rule that applies, how it can
##             be activated, its lifecycle, its chain, the effects it
##             resolves to, a simulation of its first two activations and
##             whatever looks wrong about it
##   chains[]  one per head, in walk order
##   ticks     what the runtime has to look at every frame, with places
##   warn[]    undecoded act, cycle, dangling link, unreachable,
##             even fan-in, outside the border box
##
## Nothing here runs the game: the graph is built and written, and the
## existing ActionSystem keeps playing (plan §7 step 1). It is saved as
## converted/maps/MAP.NNN.triggers.json beside the level scene, with the
## same trust and source-hash discipline as every other cache file, and
## versioned by graph_version + rules_hash so a rules change rebuilds
## every graph in seconds without touching geometry.
##
## The chain walk is ObjFlipLink (skynet_gh.c FUN_001394aa:39791) to the
## letter: toggle bit 0 of the START entity too, force it back on for an
## 0xEF node (line 39837), pass straight through placement markers, stop
## AFTER flipping an actor (flags & 0x40), stop on a link < 1 — plus a
## cycle guard DOS does not have, because a graph must terminate.

extends RefCounted

const MapFile := preload("res://scripts/loaders/map_file.gd")
const RulesSkynet := preload("res://scripts/triggers/rules_skynet.gd")
const RulesShock := preload("res://scripts/triggers/rules_shock.gd")
const AIData := preload("res://scripts/enemy_ai_data.gd")

const FORMAT: String = "skynet.triggers"
## Bump when the SHAPE of the graph changes (every saved graph is then
## rebuilt). A change to the rules alone moves rules_hash instead.
const GRAPH_VERSION: int = 1
## No real chain is anywhere near this long; a crafted one stops here.
const WALK_LIMIT: int = 256
## AI state 11 = a vehicle that drives a marker path (v1.01 0x127400).
const AI_STATE_PATH: int = 11

# ---------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------
## The rule table of a game. Future Shock's is SkyNET's marked
## informational (rules_shock.gd) — its graph is built and reviewed but
## never treated as truth.
static func rules_for(game: String) -> Script:
	return RulesShock if game == "shock" else RulesSkynet

## The game the running installation is playing.
static func current_game() -> String:
	return "shock" if SkynetPaths.game == "shock" else "skynet"

# ---------------------------------------------------------------------
# Paths, staleness, saving and loading
# ---------------------------------------------------------------------
## Where this map's graph lives ("" without a cache).
static func json_path(map_name: String) -> String:
	if Assets.root.is_empty():
		return ""
	var m: String = Assets.safe_key(map_name)
	if m.is_empty():
		push_error("[triggers] refused map name %s" % map_name)
		return ""
	return "%s/maps/%s.triggers.json" % [Assets.root, m]

## Why the graph on disk cannot be used — "" when it can. The header is
## inside the file (it is text), so there is no sidecar: version, rules
## fingerprint, game and the hash of the MAP bytes all travel with it.
static func stale_reason(map_name: String, map_bytes: PackedByteArray,
		game: String = "") -> String:
	var p := json_path(map_name)
	if p.is_empty():
		return "no cache folder"
	if not FileAccess.file_exists(p):
		return "not built yet"
	if not Assets.is_trusted(p, true):
		return "not written by this installation"
	var head: Dictionary = _read_header(p)
	if head.is_empty():
		return "unreadable"
	var g: String = game if not game.is_empty() else current_game()
	if String(head.get("format", "")) != FORMAT:
		return "another format (%s)" % str(head.get("format", "?"))
	if int(head.get("graph_version", -1)) != GRAPH_VERSION:
		return "built by graph %s, this is %d" % [str(head.get("graph_version", "?")), GRAPH_VERSION]
	if String(head.get("game", "")) != g:
		return "built for %s, this is %s" % [str(head.get("game", "?")), g]
	var rr = rules_for(g)
	if String(head.get("rules_hash", "")) != String(rr.rules_hash()):
		return "the rules changed (%s → %s)" % [str(head.get("rules_hash", "?")),
			String(rr.rules_hash())]
	if int(head.get("source_hash", 0)) != hash(map_bytes):
		return "the MAP it was built from changed"
	return ""

## The graph of `map_name`, built and written when the file is missing,
## stale or not this installation's. `{}` when it cannot be had.
static func load_or_build(map_name: String, map_bytes: PackedByteArray,
		game: String = "") -> Dictionary:
	var g: String = game if not game.is_empty() else current_game()
	var p := json_path(map_name)
	var why: String = stale_reason(map_name, map_bytes, g)
	if why.is_empty():
		var got: Dictionary = _read_json(p)
		if not got.is_empty():
			return got
		why = "unreadable"
	var graph: Dictionary = build_from_bytes(map_name, map_bytes, g)
	if graph.is_empty():
		return {}
	_write(p, graph, map_name, why)
	return graph

## Build and write, whatever is on disk. Returns the file path ("" on
## failure) — what the import job calls.
static func save(map_name: String, map_bytes: PackedByteArray,
		game: String = "") -> String:
	var g: String = game if not game.is_empty() else current_game()
	var p := json_path(map_name)
	if p.is_empty():
		return ""
	var graph: Dictionary = build_from_bytes(map_name, map_bytes, g)
	if graph.is_empty():
		return ""
	return p if _write(p, graph, map_name, "rebuild") else ""

static func _write(path: String, graph: Dictionary, map_name: String, why: String) -> bool:
	if path.is_empty():
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[triggers] cannot write %s" % path)
		return false
	f.store_string(JSON.stringify(graph, "", true))
	f.close()
	Assets.trust_record(path)
	var counts: Dictionary = graph.get("counts", {})
	print("[triggers] %s: %d nodes, %d chains, %d warnings (%s)"
		% [map_name, int(counts.get("nodes", 0)), int(counts.get("chains", 0)),
		   int(counts.get("warnings", 0)), why])
	return true

static func _read_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var got: Variant = JSON.parse_string(txt)
	return got if got is Dictionary else {}

## The header alone — the file is read whole (they are small), but only
## the header is looked at, so a body that changed shape cannot mislead.
static func _read_header(path: String) -> Dictionary:
	var got: Dictionary = _read_json(path)
	if got.is_empty():
		return {}
	var out: Dictionary = {}
	for k in ["format", "graph_version", "rules_hash", "game", "map",
			"source_hash", "outdoor", "mission"]:
		if got.has(k):
			out[k] = got[k]
	return out

# ---------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------
## The graph of a MAP file's bytes. `map_name` is "MAP.215" or similar —
## its numeric suffix names the map and its mission.
static func build_from_bytes(map_name: String, map_bytes: PackedByteArray,
		game: String = "") -> Dictionary:
	var m = MapFile.parse(map_bytes)
	if m == null:
		return {}
	var sfx: String = map_name.get_extension()
	var num: int = int(sfx) if sfx.is_valid_int() else -1
	# The outdoor flag is the MAP header's +9028 byte (memory: indoor /
	# outdoor maps); a truncated file has none.
	var outdoor: bool = map_bytes.size() > 9028 and map_bytes[9028] != 0
	return build(m, num, hash(map_bytes), game if not game.is_empty() else current_game(), outdoor)

## The graph of an already parsed map.
static func build(map, map_num: int, source_hash: int, game: String,
		outdoor: bool) -> Dictionary:
	if map == null:
		return {}
	var rules = rules_for(game)
	var ctx: Dictionary = _context(map, rules, game)
	var nodes: Array = []
	var warn: Array = []
	for id in ctx["order"]:
		nodes.append(_node(ctx, int(id), warn))
	var chains: Array = []
	for id in ctx["order"]:
		if not _is_head(ctx, int(id)):
			continue
		var c: Dictionary = ctx["chain"][int(id)]
		chains.append({"head": int(id), "steps": c["steps"], "end": c["end"]})
	_graph_warnings(ctx, warn)
	var classes: Dictionary = {}
	for w in warn:
		var k: String = String((w as Dictionary)["class"])
		classes[k] = int(classes.get(k, 0)) + 1
	return {
		"format": FORMAT,
		"graph_version": GRAPH_VERSION,
		"rules_hash": String(rules.rules_hash()),
		"game": game,
		"informational": bool(rules.informational()),
		"map": map_num,
		"source_hash": source_hash,
		"outdoor": outdoor,
		# DOS numbers a campaign mission by the decade its maps sit in.
		# SkyNET's campaign starts at 200 — anything below is a loose map or
		# an arena and belongs to no mission; Future Shock numbers its own
		# from 010 up.
		"mission": (map_num / 10) * 10 if map_num >= 200 or (game == "shock" and map_num >= 0) else -1,
		"counts": {"entities": map.entities.size(), "nodes": nodes.size(),
			"chains": chains.size(), "warnings": warn.size(), "classes": classes},
		"border": ctx["boxes"],
		"nodes": nodes,
		"chains": chains,
		"ticks": _ticks(ctx),
		"warn": warn,
	}

## Everything the per-node work shares: the records, who links to whom,
## which entities become nodes, the rule of each, the chain each starts
## and the map's border boxes.
static func _context(map, rules, game: String) -> Dictionary:
	var ents: Dictionary = map.entities_by_off
	var incoming: Dictionary = {}          # id → [ids that link here]
	for e in map.entities:
		if e.link_next > 0 and e.link_next != e.file_off:
			if not incoming.has(e.link_next):
				incoming[e.link_next] = []
			(incoming[e.link_next] as Array).append(e.file_off)
	var markers: Dictionary = {}
	var paths: Dictionary = {}             # vehicle marker → its path head
	for e in map.entities:
		if e.marker_type < 0:
			continue
		markers[e.file_off] = true
		# A vehicle that drives a marker path: an enemy start whose type
		# runs AI state 11 and whose own link is the first path marker
		# (level_loader.gd register_path_vehicle).
		if e.marker_type == 2 and e.link_next > 0 and e.enemy_type >= 0 \
				and e.enemy_type < AIData.TYPES.size() \
				and int(AIData.TYPES[e.enemy_type].get("st", -1)) == AI_STATE_PATH:
			paths[e.file_off] = e.link_next
	var order: Array = []
	for e in map.entities:
		if _wants_node(e, incoming):
			order.append(e.file_off)
	var ctx: Dictionary = {
		"map": map, "ents": ents, "rules": rules,
		"incoming": incoming, "markers": markers, "paths": paths,
		"order": order,
		"rule": {}, "chain": {}, "sig": {}, "boxes": _border_boxes(map),
	}
	for id in order:
		ctx["rule"][id] = _rule_of(ctx, int(id))
	for id in order:
		ctx["chain"][id] = _walk(ctx, int(id))
	ctx["modes"] = {}
	for id in order:
		ctx["modes"][id] = _modes(ctx, int(id))
	# Which TRIGGERS can flip each node: the heads whose walk reaches it.
	# Two triggers aimed at one chain toggle it twice in the same tick, so
	# this — not the raw link count — is the even-fan-in question.
	var by: Dictionary = {}
	for id in order:
		if not _self_starting(ctx, int(id)):
			continue
		for step in (ctx["chain"][id]["steps"] as Array):
			var sid: int = int(step[0])
			if sid == int(id):
				continue          # a trigger toggling its own bit is not fan-in
			if not by.has(sid):
				by[sid] = []
			if not (by[sid] as Array).has(int(id)):
				(by[sid] as Array).append(int(id))
	ctx["by"] = by
	return ctx

## Can this node start its chain on its own (a trigger, a shot-fired
## prop, the counter relay, the end of a vehicle path)?
static func _self_starting(ctx: Dictionary, id: int) -> bool:
	for m in (ctx["modes"][id] as Array):
		if String((m as Dictionary)["mode"]) != "chain":
			return true
	return false

## Is this entity part of the trigger surface? Everything with an act, a
## link, an incoming link, hit points or the hit/death state bits — and a
## placement marker only when a chain runs through it (a marker's
## sub-record keeps other data where a sprite keeps its act byte, so its
## "act" means nothing).
static func _wants_node(e, incoming: Dictionary) -> bool:
	if e.marker_type >= 0:
		return e.link_next > 0 or incoming.has(e.file_off)
	return e.link_act_type > 0 or e.link_next > 0 or incoming.has(e.file_off) \
		or e.hp > 0 or (e.state_byte & 6) != 0

## The rule row that applies to one entity — by MARKER TYPE for a
## placement marker, by act id AND RECORD VARIANT for everything else
## (rules_*.rule_for_record: the light band only means a light on a
## variant-2 record, for the same reason a marker's act byte means
## nothing — the sub-record keeps other data in those bytes).
static func _rule_of(ctx: Dictionary, id: int) -> Dictionary:
	var e = ctx["ents"][id]
	var rules = ctx["rules"]
	if e.marker_type >= 0:
		return {
			"kind": "marker", "family": String(rules.marker_kind(e.marker_type)),
			"p4": e.marker_type, "p6": 0, "fire": "level", "on_fire": "none",
			"dos": "0x11c519", "prov": "dos",
			"note": "a placement marker: classified by its type, never by its act byte",
			"modes": [{"mode": "chain"}],
		}
	return rules.rule_for_record(e.link_act_type, e.flags & 3)

# ---------------------------------------------------------------------
# The chain walk — ObjFlipLink FUN_001394aa
# ---------------------------------------------------------------------
## The walk from `start`: [[id, act, op] …] in order, and how it ends
## ("link_end", "actor@id", "cycle@id", "dangling@off", "limit").
## `op` is "toggle", or "toggle+force1" for an 0xEF node, which forces
## its own bit back on (skynet_gh.c:39837) — a chain cannot switch a
## proximity gate off.
static func _walk(ctx: Dictionary, start: int) -> Dictionary:
	var ents: Dictionary = ctx["ents"]
	var steps: Array = []
	var seen: Dictionary = {}
	var cur: int = start
	var end: String = "link_end"
	while true:
		if seen.has(cur):
			end = "cycle@%05x" % cur
			break
		if steps.size() >= WALK_LIMIT:
			end = "limit"
			break
		seen[cur] = true
		var e = ents.get(cur)
		if e == null:
			end = "dangling@%05x" % cur
			break
		# A marker's act byte is not an act: the walk passes straight
		# through it (MAP.210's lever switches the truck's path markers on).
		var act: int = 0 if e.marker_type >= 0 else e.link_act_type
		steps.append([cur, act, "toggle+force1" if act == RulesSkynet.ACT_PROX_GATE else "toggle"])
		if (e.flags & 0x40) != 0:
			end = "actor@%05x" % cur          # the walk stops AFTER an actor
			break
		if e.link_next < 1:
			end = "link_end"
			break
		var nxt: int = e.link_next
		if not ents.has(nxt):
			end = "dangling@%05x" % nxt
			break
		cur = nxt
	return {"steps": steps, "end": end}

## Is `id` the head of a chain — nothing links to it, or it can start one
## by itself (a trigger, a shot-fired prop, the counter relay)?
static func _is_head(ctx: Dictionary, id: int) -> bool:
	if (ctx["chain"][id]["steps"] as Array).is_empty():
		return false
	return not ctx["incoming"].has(id) or _self_starting(ctx, id)

# ---------------------------------------------------------------------
# Activation
# ---------------------------------------------------------------------
## How this node can be set off. The rule supplies the template; the
## record decides which of them actually apply (a gate whose state bits
## say the handler never runs has none, a shot-fired prop gains one).
##
## The port's own inventions are NOT here — the owner's ruling of
## 2026-09-15 sends the 130-unit use_nearby, the use key on an unchained
## message and "use at a gate walks through to its exit" back to pure
## DOS. The one port rule that stays is the WALL BUTTON: a named
## variant-1 mesh with state bit 3 answers the use key instead of the
## player walking past it.
static func _modes(ctx: Dictionary, id: int) -> Array:
	var e = ctx["ents"][id]
	var rule: Dictionary = ctx["rule"][id]
	var kind: String = String(rule["kind"])
	var out: Array = []
	var wall_button: bool = (e.flags & 3) == 1 and (e.state_byte & 8) != 0 \
		and e.name_index >= 0
	match kind:
		"prox_gate":
			# The handler (v1.01 0x1386a0) runs only for a state byte whose
			# bits 1-2 are both clear or both set: a prop that carries the
			# "act on death" bit alone is not a gate.
			var bits: int = e.state_byte & 6
			if bits == 0 or bits == 6:
				out.append_array(_templates(rule))
		"prox_chain":
			if wall_button:
				out.append({
					"mode": "use_key", "origin": "eye", "metric": "3d",
					"radius": float(rule["p4"]), "pad": 0.0,
					"requires": "bit0", "edge": "key-down", "rearm": "chain",
					"latch": "none", "prov": "port",
					"note": "a named wall button with state bit 3: the key, not walking past it (the owner's choice)",
				})
			else:
				out.append_array(_templates(rule))
		"exit":
			out.append_array(_templates(rule))
		"relay":
			out.append_array(_templates(rule))
		_:
			pass
	# ObjHit FUN_00139019: bit 1 = fire the action on every hit, bit 2 =
	# fire it on the hit that takes the hit points to zero.
	if (e.state_byte & 2) != 0:
		out.append({"mode": "shot_each", "requires": "state&2", "edge": "hit",
			"rearm": "always", "prov": "dos", "note": "ObjHit 0x139019"})
	if (e.state_byte & 4) != 0:
		out.append({"mode": "shot_death", "requires": "state&4", "edge": "hp0",
			"rearm": "never", "hp": e.hp, "prov": "dos", "note": "ObjHit 0x139019"})
	if ctx["paths"].has(id):
		out.append({"mode": "path_end", "prov": "dos",
			"note": "the vehicle flips whatever the last marker of its path points at (0x127400)"})
	if ctx["incoming"].has(id):
		out.append({"mode": "chain", "prov": "dos"})
	return out

## The rule's own templates, with "chain" left to the caller.
static func _templates(rule: Dictionary) -> Array:
	var out: Array = []
	for t in rule.get("modes", []):
		var d: Dictionary = t
		if String(d.get("mode", "chain")) == "chain":
			continue
		out.append(d.duplicate(true))
	return out

# ---------------------------------------------------------------------
# One node
# ---------------------------------------------------------------------
static func _node(ctx: Dictionary, id: int, warn: Array) -> Dictionary:
	var map = ctx["map"]
	var e = ctx["ents"][id]
	var rule: Dictionary = ctx["rule"][id]
	var variant: int = e.flags & 3
	var chain: Dictionary = ctx["chain"][id]
	var modes: Array = ctx["modes"][id]
	var node: Dictionary = {
		"id": id,
		"variant": variant,
		"flags": e.flags,
		"marker": e.marker_type,
		"pos": [e.x, e.y, e.z],
		"act": e.link_act_type,
		"state": e.state_byte,
		"hp": e.hp,
		"link": maxi(e.link_next, 0),
		"sig": _sig(ctx, id),
		"rule": {"kind": rule["kind"], "family": rule["family"],
			"p4": rule["p4"], "p6": rule["p6"], "dos": rule["dos"],
			"prov": rule["prov"], "fire": rule["fire"], "on_fire": rule["on_fire"]},
		"modes": modes,
		"chain": {"walk": chain["steps"], "end": chain["end"],
			"in": ctx["incoming"].get(id, []), "by": ctx["by"].get(id, [])},
		"fx": _effects(ctx, id),
	}
	if variant == 1:
		node["name"] = MapFile.entity_name(map, e)
		node["euler"] = [e.off_x & 0x7FF, e.off_y & 0x7FF, e.off_z & 0x7FF]
		node["destroy"] = [e.destroy_type, e.destroy_param]
	elif variant == 2:
		node["light"] = [e.light_intensity, e.light_enable]
	else:
		node["sprite"] = e.sprite_index
		node["sub2"] = e.exit_map
		node["sub4"] = e.exit_marker_id
		if e.marker_type >= 0:
			node["enemy"] = e.enemy_type
	var sim: Dictionary = _simulate(ctx, id, modes)
	node["first"] = sim["first"]
	node["second"] = sim["second"]
	var mine: Array = _node_warnings(ctx, id, modes)
	if not mine.is_empty():
		node["warn"] = mine
		for w in mine:
			warn.append({"class": String((w as Dictionary)["class"]), "id": id,
				"detail": String((w as Dictionary)["detail"])})
	return node

## hash(kind, act, state, hit points, name/sprite, position, and the
## signature of the next entity down the chain). Two maps that re-author
## the same object give it the same signature, which is what the variant
## carry and the lock compare (plan §1).
static func _sig(ctx: Dictionary, id: int) -> String:
	var memo: Dictionary = ctx["sig"]
	if memo.has(id):
		return String(memo[id])
	return _sig_walk(ctx, id, {})

static func _sig_walk(ctx: Dictionary, id: int, stack: Dictionary) -> String:
	var memo: Dictionary = ctx["sig"]
	if memo.has(id):
		return String(memo[id])
	if stack.has(id):
		return "cycle"
	var e = ctx["ents"].get(id)
	if e == null:
		return "none"
	stack[id] = true
	var nxt: String = "end"
	if e.link_next > 0:
		nxt = _sig_walk(ctx, e.link_next, stack) if ctx["ents"].has(e.link_next) else "dangling"
	stack.erase(id)
	var what: String = ""
	if (e.flags & 3) == 1:
		what = "1|" + MapFile.entity_name(ctx["map"], e)
	elif (e.flags & 3) == 2:
		what = "L"
	elif e.marker_type >= 0:
		what = "M|%d|%d" % [e.marker_type, e.enemy_type]
	else:
		what = "S|%d" % e.sprite_index
	var s: String = "%s/%02x/%02x/%d/%d,%d,%d>%s" % [what, e.link_act_type,
		e.state_byte, e.hp, e.x, e.y, e.z, nxt]
	var h: String = s.sha256_text().substr(0, 12)
	memo[id] = h
	return h

# ---------------------------------------------------------------------
# Resolved effects
# ---------------------------------------------------------------------
## What this node DOES when its bit goes up — the numbers pulled out of
## the record so nothing downstream has to read the MAP again.
static func _effects(ctx: Dictionary, id: int) -> Dictionary:
	var e = ctx["ents"][id]
	var rule: Dictionary = ctx["rule"][id]
	var rules = ctx["rules"]
	match String(rule["kind"]):
		"hint":
			return {"hint": e.link_act_type - RulesSkynet.ACT_HINT_FIRST}
		"objective":
			return {"objective": e.link_act_type - RulesSkynet.ACT_OBJECTIVE_FIRST}
		"fail":
			return {"fail": true}
		"voice":
			return {"voice": e.exit_map}
		"sound_cue":
			return {"sound": int(rule["p4"])}
		"sound_loop":
			return {"loop": e.exit_map}
		"exit":
			return {"map": e.exit_map, "set": e.exit_marker_id, "back": e.exit_map == 0}
		"mover":
			return mover_effect(rules, e.link_act_type)
		"water":
			return {"water": int(rule["p4"]), "absolute": int(rule["p4"]) == 0,
				"swap": int(rule["p6"])}
		"destructible":
			return {"stage": 1, "per_stage": RulesSkynet.DESTRUCT_DAMAGE_PER_STAGE}
		"demolish":
			return {"demolish": true, "hp": e.hp}
		"spawn":
			return {"spawn": e.exit_map & 0xFFFF}
		"light":
			return {"light": _light_op(e.link_act_type), "intensity": e.light_intensity,
				"enable": e.light_enable}
		"relay":
			return {"relay": int(rule["p4"])}
		"prox_gate":
			return {"radius": RulesSkynet.PROX_GATE_RADIUS,
				"pad": RulesSkynet.PLAYER_RADIUS}
		"prox_chain":
			return {"radius": float(rule["p4"])}
		"marker":
			var out: Dictionary = {"marker": e.marker_type, "kind": rule["family"]}
			if ctx["paths"].has(id):
				out["path_start"] = int(ctx["paths"][id])
				out["vehicle"] = e.enemy_type
			return out
	return {}

## The light bands are SkyNET's in both games (rules_shock.gd runs the
## same rows), so the one naming lives in the rules module — the runtime
## announces the same word on the event bus.
static func _light_op(act: int) -> String:
	return RulesSkynet.light_op(act)

## Travel, direction, speed and running time of a mover act — the same
## numbers ActionSystem.register_node and _step_mover derive from the
## same table (level_behaviour.mover_params).
static func mover_effect(rules, act: int) -> Dictionary:
	var p: Dictionary = rules.mover_params(act)
	var dur: float = 0.0
	if float(p["speed"]) > 0.0:
		dur = snappedf(float(p["span"]) / float(p["speed"]), 0.001)
	return {"family": p["family"], "axis": p["axis"],
		"travel": float(p["span"]) * float(p["sign"]), "speed": p["speed"],
		"duration": dur, "dir0": 1}

# ---------------------------------------------------------------------
# Simulation — the first and the second activation, from the map data
# ---------------------------------------------------------------------
## What happens the first time this node is set off, and what happens the
## second time (plan §3 step 4). Both run on a copy of the map's own
## state, so nothing here touches the records.
static func _simulate(ctx: Dictionary, id: int, modes: Array) -> Dictionary:
	var starts: bool = false
	for m in modes:
		if String((m as Dictionary)["mode"]) != "chain":
			starts = true
	if not starts or (ctx["chain"][id]["steps"] as Array).is_empty():
		return {"first": [], "second": []}
	var st: Dictionary = _fresh_state(ctx)
	var first: Array = _fire(ctx, id, st)
	# An exit ENDS the level instance, so there is no second activation to
	# simulate. The 0xF0 handler itself holds no latch — decoded from the
	# v1.01 bytes at 0x138081 (2026-09-16): it clears its own bit 0 inline
	# and would fire again on the next rise. But the same handler sets the
	# map-change request (`or [0x30a50], 0x20`), and the frame loop tests
	# that at 0x117a2e BEFORE the next entity sweep and tears the level
	# down: DOS performs exactly one map change per level instance. The
	# graph said the exit fires twice, which read as "walk back through and
	# it works again"; the runtime's one-map-change latch
	# (action_system._teleport_fired) was the one that matched DOS.
	var second: Array = [] if _ends_instance(first) else _fire(ctx, id, st)
	return {"first": first, "second": second}

## Does this activation take the level away — i.e. is a map change part
## of what it comes to?
static func _ends_instance(fx: Array) -> bool:
	for f in fx:
		if String(f).begins_with("exit"):
			return true
	return false

static func _fresh_state(ctx: Dictionary) -> Dictionary:
	var st: Dictionary = {"bit": {}, "act": {}, "stage": {}, "dir": {}, "spent": {}}
	for e in (ctx["map"].entities as Array):
		st["bit"][e.file_off] = e.state_byte
		st["act"][e.file_off] = e.link_act_type
	return st

## One activation: the chain walk, then the edge handlers in walk order
## for every node whose bit 0 went UP, then the movers settle.
static func _fire(ctx: Dictionary, id: int, st: Dictionary) -> Array:
	var fx: Array = []
	var kind: String = String(ctx["rule"][id]["kind"])
	# 0xF1/0xF2 only run while their own bit is set; a chain has to re-arm
	# them (the handler clears it as it fires).
	if kind == "prox_chain" and (int(st["bit"].get(id, 0)) & 1) == 0:
		return fx
	var rose: Array = []
	for step in (ctx["chain"][id]["steps"] as Array):
		var sid: int = int(step[0])
		var was: int = int(st["bit"].get(sid, 0))
		var now: int = was ^ 1
		if int(step[1]) == RulesSkynet.ACT_PROX_GATE:
			now |= 1
		st["bit"][sid] = now
		if (was & 1) == 0 and (now & 1) != 0:
			rose.append(sid)
	for sid in rose:
		_edge(ctx, int(sid), st, fx)
	if kind == "prox_chain":
		st["bit"][id] = int(st["bit"].get(id, 0)) & ~1   # 0x139644 with -2
	_settle(ctx, st, fx, rose)
	return fx

## The handler of a node whose bit 0 has just gone up, and what it does
## to its own record afterwards.
static func _edge(ctx: Dictionary, id: int, st: Dictionary, fx: Array) -> void:
	var e = ctx["ents"].get(id)
	if e == null:
		return
	if ctx["markers"].has(id):
		if ctx["paths"].has(id):
			fx.append("path@%05x" % id)
		return
	var act: int = int(st["act"].get(id, e.link_act_type))
	var rules = ctx["rules"]
	# The act the record carries NOW (a water valve swaps its own), read
	# against the record it sits on — see _rule_of.
	var rule: Dictionary = rules.rule_for_record(act, e.flags & 3)
	var kind: String = String(rule["kind"])
	var clear: bool = true
	match kind:
		"hint":
			fx.append("hint%d" % (act - RulesSkynet.ACT_HINT_FIRST))
			st["act"][id] = 0xFF
		"objective":
			fx.append("obj%d" % (act - RulesSkynet.ACT_OBJECTIVE_FIRST))
			st["act"][id] = 0xFF
		"fail":
			fx.append("fail")
			st["act"][id] = 0xFF
		"voice":
			fx.append("voice%d" % e.exit_map)
		"sound_cue":
			fx.append("snd%d" % int(rule["p4"]))
		"exit":
			fx.append("exit%s/%d" % ["back" if e.exit_map == 0 else str(e.exit_map),
				e.exit_marker_id])
		"spawn":
			fx.append("spawn@%05x" % id)
		"demolish":
			fx.append("demolish@%05x" % id)
			st["spent"][id] = true
		"destructible":
			var n: int = int(st["stage"].get(id, 0)) + 1
			st["stage"][id] = n
			fx.append("break@%05x:%d" % [id, n])
		"water":
			var delta: int = int(rule["p4"])
			fx.append("waterabs" if delta == 0 else "water%+d" % delta)
			if int(rule["p6"]) != 0:
				st["act"][id] = int(rule["p6"])          # 0xd9 ↔ 0xda
		"light":
			var op: String = _light_op(act)
			fx.append("light_%s@%05x" % [op, id])
			clear = op != "flicker" and op != "strobe"   # those run while the bit is up
		"sound_loop":
			fx.append("loop%d" % e.exit_map)
			clear = false
		"relay", "mover", "prox_gate", "prox_chain", "pickup", "inert", "marker", "none":
			clear = false                                # level kinds, armed, or nothing at all
		_:
			clear = false
			fx.append("act%02x@%05x" % [act, id])        # undecoded: say so
	if clear:
		st["bit"][id] = int(st["bit"].get(id, 0)) & ~1

## Movers whose bit is up run to the end of their travel, clear the bit
## and reverse — the DOS handlers self-disable on arrival, which is why
## the next chain flip runs them back.
## Only the movers THIS activation switched on: a rotator the map starts
## with its bit already up is running whatever the player does, and
## listing it under every trigger's effects would drown the real ones.
static func _settle(ctx: Dictionary, st: Dictionary, fx: Array, rose: Array) -> void:
	var rules = ctx["rules"]
	for id in rose:
		var iid: int = int(id)
		if not ctx["rule"].has(iid) or String(ctx["rule"][iid]["kind"]) != "mover":
			continue
		if (int(st["bit"].get(iid, 0)) & 1) == 0:
			continue
		# A mover never changes its act byte, so the record's is the one.
		var p: Dictionary = rules.mover_params(int(ctx["ents"][iid].link_act_type))
		var dir: float = float(st["dir"].get(iid, 1.0))
		var travel: float = float(p["span"]) * float(p["sign"]) * dir
		if String(p["family"]) == "rot" and float(p["speed"]) > 0.0 and float(p["span"]) >= 2048.0:
			# A continuous rotator never arrives: it spins while the bit is up.
			fx.append("spin@%05x" % iid)
			continue
		fx.append("move@%05x:%s%s%+.0f" % [iid, p["family"],
			["X", "Y", "Z"][clampi(int(p["axis"]), 0, 2)], travel])
		st["bit"][iid] = int(st["bit"].get(iid, 0)) & ~1
		st["dir"][iid] = -dir

# ---------------------------------------------------------------------
# What the runtime has to watch every frame
# ---------------------------------------------------------------------
static func _ticks(ctx: Dictionary) -> Dictionary:
	var out: Dictionary = {"use": [], "prox": [], "exits": [], "relays": [],
		"spawns": [], "paths": [], "water": [], "lights": []}
	for id in ctx["order"]:
		var iid: int = int(id)
		var e = ctx["ents"][iid]
		var kind: String = String(ctx["rule"][iid]["kind"])
		var at: Array = [e.x, e.y, e.z]
		match kind:
			"prox_gate":
				var bits: int = e.state_byte & 6
				if bits == 0 or bits == 6:
					out["use"].append({"id": iid, "pos": at,
						"r": RulesSkynet.PROX_GATE_RADIUS + RulesSkynet.PLAYER_RADIUS})
			"prox_chain":
				var use_key: bool = (e.flags & 3) == 1 and (e.state_byte & 8) != 0 \
					and e.name_index >= 0
				var entry: Dictionary = {"id": iid, "pos": at,
					"r": float(ctx["rule"][iid]["p4"])}
				if use_key:
					entry["use_key"] = true
					out["use"].append(entry)
				else:
					out["prox"].append(entry)
			"exit":
				out["exits"].append({"id": iid, "pos": at,
					"r": RulesSkynet.TELEPORT_TOUCH_RADIUS, "map": e.exit_map,
					"set": e.exit_marker_id})
			"relay":
				out["relays"].append({"id": iid, "at": int(ctx["rule"][iid]["p4"])})
			"spawn":
				out["spawns"].append({"id": iid, "pos": at, "type": e.exit_map & 0xFFFF})
			"water":
				out["water"].append({"id": iid, "pos": at,
					"delta": int(ctx["rule"][iid]["p4"])})
			"light":
				out["lights"].append({"id": iid, "pos": at,
					"op": _light_op(e.link_act_type)})
		if ctx["paths"].has(iid):
			out["paths"].append({"id": iid, "pos": at,
				"head": int(ctx["paths"][iid]), "vehicle": e.enemy_type})
	return out

# ---------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------
## The DOS border boxes: markers of types 30-39, read in PAIRS
## (FUN_00122711). Outside them the engine undoes the player's move.
static func _border_boxes(map) -> Array:
	var by_type: Dictionary = {}
	for e in map.entities:
		if e.marker_type >= RulesSkynet.MARKER_BORDER_FIRST \
				and e.marker_type <= RulesSkynet.MARKER_BORDER_LAST:
			if not by_type.has(e.marker_type):
				by_type[e.marker_type] = []
			(by_type[e.marker_type] as Array).append(e)
	var out: Array = []
	var types: Array = by_type.keys()
	types.sort()
	for mt in types:
		var pts: Array = by_type[mt]
		var i: int = 0
		while i + 1 < pts.size():
			var a = pts[i]
			var b = pts[i + 1]
			out.append([mini(a.x, b.x), mini(a.z, b.z), maxi(a.x, b.x), maxi(a.z, b.z)])
			i += 2
	return out

static func _inside_border(boxes: Array, e) -> bool:
	if boxes.is_empty():
		return true
	for b in boxes:
		if e.x >= int(b[0]) and e.x <= int(b[2]) and e.z >= int(b[1]) and e.z <= int(b[3]):
			return true
	return false

## What looks wrong about one node.
static func _node_warnings(ctx: Dictionary, id: int, modes: Array) -> Array:
	var e = ctx["ents"][id]
	var rule: Dictionary = ctx["rule"][id]
	var kind: String = String(rule["kind"])
	var out: Array = []
	if kind == "undecoded":
		out.append({"class": "undecoded_act",
			"detail": "act %02x: %s" % [e.link_act_type, String(rule["note"])]})
	var chain: Dictionary = ctx["chain"][id]
	var end: String = String(chain["end"])
	# (A link that points nowhere is reported once, on the entity that
	# holds it — _graph_warnings — not on every head whose walk reaches it.)
	if end.begins_with("cycle@"):
		out.append({"class": "cycle", "detail": "the chain comes back to %s" % end.substr(6)})
	elif end == "limit":
		out.append({"class": "cycle", "detail": "the chain is longer than %d links" % WALK_LIMIT})
	# Something that only a chain can set off, that no chain does and that
	# the map does not start enabled (a rotator or an ambient loop with
	# bit 0 already set is running from the first frame — the Behaviour
	# branch fires those one-shots at level start).
	if not ctx["incoming"].has(id) and _needs_chain(kind, e) and modes.is_empty() \
			and (e.state_byte & 1) == 0:
		out.append({"class": "unreachable",
			"detail": "a %s nothing links to and nothing can set off" % kind})
	# An even number of TRIGGERS aimed at one node cancel out unless the
	# engine fires each handler as the chain is flipped — the eight gates
	# round MAP.217's jeep trip two or four in the same frame, and the
	# toggles took the objective straight back down.
	var by: Array = ctx["by"].get(id, [])
	if by.size() >= 2 and by.size() % 2 == 0:
		out.append({"class": "even_fan_in",
			"detail": "%d triggers flip this node: their toggles cancel unless each fires as it flips" % by.size()})
	if not _inside_border(ctx["boxes"], e) and _player_reached(kind, modes):
		out.append({"class": "outside_border",
			"detail": "at (%d,%d) — outside every border box, where the player cannot go" % [e.x, e.z]})
	return out

## Kinds that do nothing at all until a chain enables them. A
## DESTRUCTIBLE is not one: gunfire takes it through its damage stages
## with no chain in sight (ObjHit → 0x120433), so one nothing links to is
## ordinary scenery, not a dead end.
##
## Nor is a DEMOLITION prop that carries hit points, for the same reason
## and by the same routine. Act 0x1B (handler 0x1378bf) is only a chain's
## way of KILLING an object: hp = max(hp, 1), then ObjHit(hp + 1) — and
## ObjHit (0x139019) is the routine every bullet calls. A crate with 40
## points and act 0x1B breaks under fire whether or not anything ever
## links to it; what the act adds is a second way to break it. Reading
## those as dead ends made 141 of the 243 "unreachable" warnings, which
## buried the hundred that are worth looking at. A demolition prop with
## NO hit points is still flagged: nothing at all can set that one off.
static func _needs_chain(kind: String, e) -> bool:
	if kind == "demolish":
		return e.hp <= 0
	return kind in ["mover", "hint", "objective",
		"fail", "sound_cue", "voice", "water", "spawn", "light", "exit", "relay"]

## Must the player be able to stand at this node for it to work?
static func _player_reached(kind: String, modes: Array) -> bool:
	if kind in ["objective", "exit"]:
		return true
	for m in modes:
		if String((m as Dictionary)["mode"]) in ["use_key", "prox_enter", "touch_arm"]:
			return true
	return false

## Warnings about the map as a whole.
static func _graph_warnings(ctx: Dictionary, warn: Array) -> void:
	for id in ctx["incoming"]:
		if ctx["ents"].has(id):
			continue
		for src in (ctx["incoming"][id] as Array):
			warn.append({"class": "dangling_link", "id": int(src),
				"detail": "links to %05x, where no entity starts" % int(id)})
