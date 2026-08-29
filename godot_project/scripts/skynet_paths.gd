## Autoload: locates the bundled original game data (SKYNET / FutureShock).
##
## The needed GAMEDATA (4 BSA archives + WLD.* + TEXTURE.*) is bundled
## under res://gamedata/ so it ships inside the exported PCK — this lets
## the same build run on desktop AND Android. FileAccess with a res://
## path reads from the project folder in the editor and from the PCK in
## an exported build.

extends Node

## Where the bundled game data lives. res:// works on every platform.
const GAMEDATA_DIR := "res://gamedata"

## CTPAX-X variant keys used to decrypt BSA archives — same numbers as
## fsh32_port/src/loaders/archive_bsa.c and unfsnbsa.exe.
enum BsaVariant {
	FUTURESHOCK_DEMO = 0,
	FUTURESHOCK_FULL = 1,
	SKYNET_FULL      = 2,
	INSTALLER        = 3,
}

var gamedata_dir: String = GAMEDATA_DIR
var variant: int = BsaVariant.SKYNET_FULL
## Back-compat alias (some viewers / log lines still reference it).
var game_root: String = GAMEDATA_DIR

## Where the original data may live, in priority order. The game reads
## the originals only to fill the converted-asset cache (Assets), so
## they can sit outside the project: `--gamedata=<dir>` on the command
## line, the path remembered in user://gamedata.cfg, res://gamedata
## (bundled), or a `gamedata` folder next to / above the project or exe.
const GAMEDATA_CFG := "user://gamedata.cfg"
const PROBE_FILE := "MDMDMAP2.BSA"

func _ready() -> void:
	var found := _locate_gamedata()
	if found.is_empty():
		push_warning("[paths] original game data not found — looked for %s" % PROBE_FILE)
	else:
		gamedata_dir = found
		game_root = found
	print("[paths] gamedata: %s" % gamedata_dir)

static func _has_data(dir: String) -> bool:
	return not dir.is_empty() and FileAccess.file_exists("%s/%s" % [dir, PROBE_FILE])

func _locate_gamedata() -> String:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a in args:
		if a.begins_with("--gamedata="):
			var d := a.substr(11).strip_edges().trim_suffix("/").trim_suffix("\\")
			if _has_data(d):
				return d
			push_warning("[paths] --gamedata=%s has no %s" % [d, PROBE_FILE])
	var cfg := ConfigFile.new()
	if cfg.load(GAMEDATA_CFG) == OK:
		var d: String = String(cfg.get_value("paths", "gamedata", ""))
		if _has_data(d):
			return d
	if _has_data(GAMEDATA_DIR):
		return GAMEDATA_DIR
	var bases: Array[String] = []
	if OS.has_feature("template"):
		bases.append(OS.get_executable_path().get_base_dir())
	else:
		bases.append(ProjectSettings.globalize_path("res://").trim_suffix("/"))
	for b in bases:
		for cand in [b + "/gamedata", b.get_base_dir() + "/gamedata", b + "/GAMEDATA", b.get_base_dir() + "/GAMEDATA"]:
			if _has_data(cand):
				return cand
	return ""

## Remember a data directory chosen in the menu.
func set_gamedata_dir(dir: String) -> bool:
	if not _has_data(dir):
		return false
	gamedata_dir = dir
	game_root = dir
	var cfg := ConfigFile.new()
	cfg.set_value("paths", "gamedata", dir)
	cfg.save(GAMEDATA_CFG)
	return true

## Map chosen in the main menu; the game scene reads this on load.
## Empty → the game falls back to its own default (MAP.210).
var selected_map: String = ""

func gamedata_path(filename: String) -> String:
	return "%s/%s" % [gamedata_dir, filename]

func read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Could not open: %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return PackedByteArray()
	var data := f.get_buffer(f.get_length())
	f.close()
	return data
