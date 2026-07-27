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
