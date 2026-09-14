## Keeps out of every export what must not ship, whatever the preset's
## filters say: the converted-asset cache (derived from the copyrighted
## game data — every player builds their own on first start), local mods
## and the development scenes.
##
## v0.1.0–v0.2.1 shipped res://converted inside the PCK because the
## presets export "all resources" and the cache was linked into the
## project.
##
## Scripts are not filtered here: the engine's own GDScript export plugin
## compiles every .gd before this one sees it, so a skip() would only drop
## the source. The scripts are the public repository anyway; an entry in
## the preset's exclude_filter is the way to leave one out.

@tool
extends EditorExportPlugin

const SKIP_DIRS: PackedStringArray = [
	"res://converted/",
	"res://mods/",
]

## scenes/<name>.tscn that only the tests and the developer's command
## line start.
const DEV_SCENES: PackedStringArray = [
	"action_smoke_test",
	"game_smoke_test",
	"net_smoke_test",
	"map_dump",
	"map_audit",
	"load_bench",
]

func _get_name() -> String:
	return "SkyNET export filter"

func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if skips(path):
		skip()

static func skips(path: String) -> bool:
	for d in SKIP_DIRS:
		if path.begins_with(d):
			return true
	return path.begins_with("res://scenes/") and path.get_extension() == "tscn" \
		and path.get_file().get_basename() in DEV_SCENES
