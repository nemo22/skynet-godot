## What behaviour the game's maps actually contain.
##
##   godot --headless --path . res://scenes/act_census.tscn -- out.csv
##
## Before rebuilding the level format around Godot nodes it is worth
## knowing what has to be expressed. This counts, across all 123 MAPs,
## every entity's action/handler id (`link_act_type`), how long the link
## CHAINS are, and how many entities carry hit points or a state bit —
## the three things the DOS engine drives behaviour with — and then
## what the bake makes of them: the node vocabulary of
## scripts/level_behaviour.gd, counted with the same classifier the
## bake uses, so this table and a baked level cannot disagree.
##
## Placement markers are counted apart. Their sub-record keeps other
## data where a sprite keeps its act byte — an enemy marker's "act" is
## its enemy type — and the first census (2026-09-05 morning) read 243
## heavy turrets as act 0x1B and half the campaign's raptors as hint
## 0x20. Only the `entities` column is behaviour.

extends Node

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile   := preload("res://scripts/loaders/map_file.gd")
const TransfrmPRS := preload("res://scripts/loaders/transfrm_prs.gd")
const ActionSystem := preload("res://scripts/action_system.gd")
const LevelBehaviour := preload("res://scripts/level_behaviour.gd")

## What the port already knows each id to be (docs Q, memory
## action-handler-table-0x59b00).
const KNOWN: Dictionary = {
	0x18: "destructible (TRANSFRM.PRS)", 0x19: "destructible (TRANSFRM.PRS)",
	0xED: "voice line", 0xEE: "looping sound",
	0xEF: "proximity gate (60 u)", 0xF0: "teleport / map exit",
	0xF1: "proximity chain (256 u)", 0xF2: "proximity chain (1024 u)",
	0x2B: "MISSION FAILED",
}

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "act_census.csv"
	var gd: String = SkynetPaths.gamedata_dir
	var acts: Dictionary = {}          # act -> count (entities, markers apart)
	var act_markers: Dictionary = {}   # act -> count on placement markers
	var act_maps: Dictionary = {}      # act -> {map: true}
	var chain_len: Dictionary = {}     # length -> how many chains
	var kinds: Dictionary = {}         # node kind -> count
	var links: Dictionary = {}         # link_report tallies, summed
	var n_maps: int = 0
	var n_ent: int = 0
	var n_markers: int = 0
	var n_hp: int = 0
	var n_state: int = 0
	var n_linked: int = 0
	var longest: int = 0
	var longest_map: String = ""

	var transfrm: Dictionary = {}
	var brif := BSAReader.new()
	if brif.open(gd + "/MDMDBRIF.BSA", SkynetPaths.variant):
		transfrm = TransfrmPRS.parse(brif.read("TRANSFRM.PRS"))
		brif.close()

	var maps := BSAReader.new()
	if not maps.open(gd + "/MDMDMAP2.BSA", SkynetPaths.variant):
		print("no MDMDMAP2.BSA")
		get_tree().quit(1)
		return
	for e in maps.entries():
		var mn: String = e.name.to_upper()
		if not mn.begins_with("MAP."):
			continue
		var m = MapFile.parse(maps.read(mn))
		if m == null:
			continue
		n_maps += 1
		var by_off: Dictionary = {}
		var targeted: Dictionary = {}
		for ent in m.entities:
			by_off[ent.file_off] = ent
		for ent in m.entities:
			var act: int = ent.link_act_type
			if ent.marker_type >= 0:
				n_markers += 1
				if act != 0:
					act_markers[act] = int(act_markers.get(act, 0)) + 1
				continue
			n_ent += 1
			if act != 0:
				acts[act] = int(acts.get(act, 0)) + 1
				if not act_maps.has(act):
					act_maps[act] = {}
				act_maps[act][mn] = true
			if ent.hp > 0:
				n_hp += 1
			if (ent.state_byte & 6) != 0:
				n_state += 1
			if ent.link_next != 0 and not _is_end(ent.link_next):
				n_linked += 1
				targeted[ent.link_next] = true
		# Chain lengths: walk from every entity that nothing points at.
		for ent in m.entities:
			if ent.marker_type >= 0 or targeted.has(ent.file_off):
				continue
			if ent.link_next == 0 or _is_end(ent.link_next):
				continue
			var n: int = 1
			var at: int = ent.link_next
			var guard: int = 0
			while by_off.has(at) and guard < 64:
				n += 1
				guard += 1
				var nx = by_off[at]
				at = nx.link_next
				if at == 0 or _is_end(at):
					break
			chain_len[n] = int(chain_len.get(n, 0)) + 1
			if n > longest:
				longest = n
				longest_map = mn
		# The node vocabulary, with the bake's own classifier.
		var c: Dictionary = LevelBehaviour.census(m, transfrm)
		for k in c:
			kinds[k] = int(kinds.get(k, 0)) + int(c[k])
		var r: Dictionary = LevelBehaviour.link_report(m, transfrm)
		for k in r:
			links[k] = int(links.get(k, 0)) + int(r[k])
	maps.close()

	var keys: Array = acts.keys()
	keys.sort_custom(func(a, b) -> bool: return int(acts[a]) > int(acts[b]))
	print("%d maps, %d entities (+ %d placement markers), %d with HP, %d with a state bit, %d linked"
		% [n_maps, n_ent, n_markers, n_hp, n_state, n_linked])
	print("%d distinct action ids on entities" % keys.size())
	print("  act   count  maps  on markers  what the port makes of it")
	var lines: Array = ["act_hex,count,maps,on_markers,kind,known"]
	for k in keys:
		var kind: String = "static"
		if ActionSystem.is_mover(int(k)):
			var cfg: Array = ActionSystem.MOVER_TABLE[int(k)]
			kind = "mover:%s" % str(cfg[0])
		elif ActionSystem.is_destructible(int(k)):
			kind = "destructible"
		elif ActionSystem.SOUND_ONESHOT.has(int(k)):
			kind = "sound cue"
		elif int(k) >= 0x1C and int(k) <= 0x25:
			kind = "hint message"
		elif int(k) >= 0x26 and int(k) <= 0x2A:
			kind = "objective"
		elif KNOWN.has(int(k)):
			kind = "special"
		var what: String = String(KNOWN.get(int(k), ""))
		if kind.begins_with("mover"):
			what = kind
		var on_m: int = int(act_markers.get(k, 0))
		lines.append("0x%02X,%d,%d,%d,%s,%s" % [k, acts[k], (act_maps[k] as Dictionary).size(), on_m, kind, what])
		print("  0x%02X %6d %5d  %10d  %s %s" % [k, acts[k], (act_maps[k] as Dictionary).size(), on_m,
			kind, ("— " + what) if not what.is_empty() and not kind.begins_with("mover") else ""])
	var cl: Array = chain_len.keys()
	cl.sort()
	var parts: Array = []
	for n in cl:
		parts.append("%d:%d" % [n, chain_len[n]])
	print("chain lengths (nodes:count): %s" % ", ".join(parts))
	print("longest chain %d, in %s" % [longest, longest_map])

	print("node vocabulary (scripts/level_behaviour.gd), all maps:")
	var total: int = 0
	for k in LevelBehaviour.KINDS:
		var c: int = int(kinds.get(k, 0))
		total += c
		print("  %-14s %6d   %s" % [LevelBehaviour.CONTAINER[k], c, k])
		lines.append("node:%s,%d,,,%s," % [k, c, LevelBehaviour.CONTAINER[k]])
	print("  %-14s %6d" % ["total", total])
	print("  relays %d, links to markers %d, dangling links %d, meshes under cue nodes %d, "
		% [int(links.get("relays", 0)), int(links.get("to_markers", 0)),
		   int(links.get("dangling", 0)), int(links.get("cues_with_mesh", 0))]
		+ "looping sounds in chains %d, mover ids off meshes %d"
		% [int(links.get("loops_in_chains", 0)), int(links.get("mover_ids_off_mesh", 0))])
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		for l in lines:
			f.store_line(String(l))
		f.close()
		print("wrote %s" % out_path)
	get_tree().quit()

static func _is_end(v: int) -> bool:
	return v == 0xFFFFFFFF or v == 0xFFFFFFFE or v == -1 or v == -2
