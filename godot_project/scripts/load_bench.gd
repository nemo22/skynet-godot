## Headless level-load benchmark:
##   godot --headless --path . res://scenes/load_bench.tscn
## Times LevelLoader.load_level for a few maps (cold = cache being
## built, warm = cache hits) and prints the asset-cache statistics.

extends Node

const LevelLoader := preload("res://scripts/level_loader.gd")
const MAPS: Array = ["MAP.210", "MAP.218", "MAP.240"]

func _ready() -> void:
	for m in MAPS:
		var t0 := Time.get_ticks_msec()
		var lvl := LevelLoader.new().load_level(m)
		var t1 := Time.get_ticks_msec()
		var n := 0
		if lvl != null and lvl.entities:
			n = lvl.entities.get_child_count()
		print("[bench] %s: %d ms (%d entity meshes)" % [m, t1 - t0, n])
	print("[bench] assets: %d hits, %d misses, root %s" % [Assets.hits, Assets.misses, Assets.root])
	get_tree().quit(0)
