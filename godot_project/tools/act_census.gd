## What behaviour the game's maps actually contain.
##
##   godot --headless --path . res://scenes/act_census.tscn -- out.csv
##
## Before rebuilding the level format around Godot nodes it is worth
## knowing what has to be expressed. This counts, across all 123 MAPs,
## every entity's action/handler id (`link_act_type`), how long the link
## CHAINS are, and how many entities carry hit points or a state bit —
## the three things the DOS engine drives behaviour with.

extends Node

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile   := preload("res://scripts/loaders/map_file.gd")
const ActionSystem := preload("res://scripts/action_system.gd")

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
	var acts: Dictionary = {}          # act -> count
	var act_maps: Dictionary = {}      # act -> {map: true}
	var chain_len: Dictionary = {}     # length -> how many chains
	var n_maps: int = 0
	var n_ent: int = 0
	var n_hp: int = 0
	var n_state: int = 0
	var n_linked: int = 0
	var longest: int = 0
	var longest_map: String = ""

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
			n_ent += 1
			var act: int = ent.link_act_type
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
			if targeted.has(ent.file_off):
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
	maps.close()

	var keys: Array = acts.keys()
	keys.sort_custom(func(a, b) -> bool: return int(acts[a]) > int(acts[b]))
	print("%d maps, %d entities, %d with HP, %d with a state bit, %d linked"
		% [n_maps, n_ent, n_hp, n_state, n_linked])
	print("%d distinct action ids" % keys.size())
	print("  act   count  maps  what the port makes of it")
	var lines: Array = ["act_hex,count,maps,kind,known"]
	for k in keys:
		var kind: String = "static"
		if ActionSystem.is_mover(int(k)):
			var cfg: Array = ActionSystem.MOVER_TABLE[int(k)]
			kind = "mover:%s" % str(cfg[0])
		elif ActionSystem.is_destructible(int(k)):
			kind = "destructible"
		elif int(k) >= 0x1C and int(k) <= 0x25:
			kind = "hint message"
		elif int(k) >= 0x26 and int(k) <= 0x2A:
			kind = "objective"
		elif KNOWN.has(int(k)):
			kind = "special"
		var what: String = String(KNOWN.get(int(k), ""))
		if kind.begins_with("mover"):
			what = kind
		lines.append("0x%02X,%d,%d,%s,%s" % [k, acts[k], (act_maps[k] as Dictionary).size(), kind, what])
		print("  0x%02X %6d %5d  %s %s" % [k, acts[k], (act_maps[k] as Dictionary).size(),
			kind, ("— " + what) if not what.is_empty() and not kind.begins_with("mover") else ""])
	var cl: Array = chain_len.keys()
	cl.sort()
	var parts: Array = []
	for n in cl:
		parts.append("%d:%d" % [n, chain_len[n]])
	print("chain lengths (nodes:count): %s" % ", ".join(parts))
	print("longest chain %d, in %s" % [longest, longest_map])
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		for l in lines:
			f.store_line(String(l))
		f.close()
		print("wrote %s" % out_path)
	get_tree().quit()

static func _is_end(v: int) -> bool:
	return v == 0xFFFFFFFF or v == 0xFFFFFFFE or v == -1 or v == -2
