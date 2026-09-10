## Dev probe: one entity's link record, including whatever the MAP
## defaults table (0x233C) filled in by name.
##   godot --headless --path . --script res://tools/ent_probe.gd -- 210 DOOR01 TRCKBOX TRUCK
extends SceneTree
var _bytes: PackedByteArray
func _initialize() -> void:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var MapFile = load("res://scripts/loaders/map_file.gd")
	var args := OS.get_cmdline_user_args()
	var suffix: int = int(args[0]) if args.size() > 0 else 210
	var want: Array = []
	for i in range(1, args.size()):
		want.append(args[i].to_upper())
	var b = BSAReader.new()
	b.open("C:/Games/skynet/gamedata/MDMDMAP2.BSA", 2)
	_bytes = b.read("MAP.%03d" % suffix)
	var m = MapFile.parse(_bytes)
	b.close()
	print("[ent] defaults table: %d entries" % m.defaults.size())
	for k in m.defaults:
		var d = m.defaults[k]
		var nm2: String = MapFile.name_of_index(m, k) if MapFile.has_method("name_of_index") else str(k)
		print("[def] name_index %3d (%s): %s" % [k, nm2, str(d)])
	for e in m.entities:
		if (e.flags & 3) != 1:
			continue
		var nm: String = MapFile.entity_name(m, e).to_upper()
		if not want.is_empty() and not want.has(nm):
			continue
		var raw: String = ""
		if e.link_off > 0 and e.link_off + 10 <= _bytes.size():
			for k in 10:
				raw += "%02x " % _bytes[e.link_off + k]
		print("[ent] %-9s @%05x act=%02x state=%02x hp=%d link_off=%d raw[%s] def=%s"
			% [nm, e.file_off, e.link_act_type, e.state_byte, e.hp, e.link_off,
			   raw.strip_edges(), str(e.uses_defaults) if "uses_defaults" in e else "?"])
	quit()
