## List a BSA archive without the game running:
##   godot --headless --path . --script res://tools/probe_bsa.gd -- <archive> <variant> [filter]
## variant: 0 FS demo, 1 FS full, 2 SKYNET. Prints name, size, flags.
extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: probe_bsa.gd -- <archive> <variant> [filter]")
		quit(1)
		return
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var b = BSAReader.new()
	if not b.open(args[0], int(args[1])):
		print("cannot open %s" % args[0])
		quit(1)
		return
	var filt: String = args[2].to_upper() if args.size() > 2 else ""
	var n := 0
	var families: Dictionary = {}
	for e in b.entries():
		var nm: String = String(e.name)
		var fam: String = nm.get_extension() if nm.contains(".") else nm
		families[fam] = int(families.get(fam, 0)) + 1
		if filt.is_empty() or nm.to_upper().contains(filt):
			if filt.is_empty() and n >= 40:
				n += 1
				continue
			print("  %-13s %8d  flags %d" % [nm, e.size, e.flags])
			n += 1
	print("%s: %d entries, families %s" % [args[0].get_file(), b.entries().size(), families])
	b.close()
	quit()
