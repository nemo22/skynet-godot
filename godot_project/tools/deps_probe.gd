## Dev probe: what a baked level scene actually pulls off disk, and how
## much of it. Level load is ~21 ms per MB of resources plus ~0.3 ms per
## file (measured 2026-09-09), so this is the load-time budget.
##   godot --headless --path . --script res://tools/deps_probe.gd -- res://converted/maps/MAP.210.level.scn
extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var start: String = "res://converted/maps/MAP.210.level.scn"
	for a in args:
		if a.begins_with("res://"):
			start = a
	var seen: Dictionary = {}
	var stack: Array = [start]
	var by_dir: Dictionary = {}
	var total: int = 0
	while not stack.is_empty():
		var p: String = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		var sz: int = 0
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			sz = f.get_length()
			f.close()
		total += sz
		var d: String = p.get_base_dir()
		var cur: Array = by_dir.get(d, [0, 0])
		by_dir[d] = [cur[0] + 1, cur[1] + sz]
		for dep in ResourceLoader.get_dependencies(p):
			var dp: String = dep.get_slice("::", 2) if dep.contains("::") else dep
			if dp.begins_with("res://"):
				stack.append(dp)
	print("[deps] %s: %d files, %.1f MB (~%.0f ms to load)"
		% [start.get_file(), seen.size(), float(total) / 1048576.0,
		   float(total) / 1048576.0 * 21.0 + float(seen.size()) * 0.3])
	var dirs: Array = by_dir.keys()
	dirs.sort_custom(func(a, b): return by_dir[a][1] > by_dir[b][1])
	for e in dirs:
		if by_dir[e][1] > 524288:
			print("[deps]   %-48s %4d files %7.1f MB" % [e, by_dir[e][0], float(by_dir[e][1]) / 1048576.0])
	quit()
