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
## Which game the data directory holds: "skynet" (SkyNET, MDMDMAP2.BSA)
## or "shock" (Terminator: Future Shock, MDMDMAPS.BSA). The archives use
## different keys and the map archive has a different name; everything
## else asks `map_archive` instead of naming the file.
var game: String = "skynet"
var map_archive: String = "MDMDMAP2.BSA"
## Back-compat alias (some viewers / log lines still reference it).
var game_root: String = GAMEDATA_DIR

## Where the original data may live, in priority order. The game reads
## the originals only to fill the converted-asset cache (Assets), so
## they can sit outside the project: `--gamedata=<dir>` on the command
## line, the path remembered in user://gamedata.cfg, res://gamedata
## (bundled), or a `gamedata` folder next to / above the project or exe.
const GAMEDATA_CFG := "user://gamedata.cfg"
const PROBE_FILE := "MDMDMAP2.BSA"           # SkyNET
const PROBE_FILE_SHOCK := "MDMDMAPS.BSA"     # Future Shock

func _ready() -> void:
	var found := locate_gamedata()
	if found.is_empty():
		push_warning("[paths] original game data not found — looked for %s" % PROBE_FILE)
	else:
		gamedata_dir = found
		game_root = found
	if not FileAccess.file_exists("%s/%s" % [gamedata_dir, PROBE_FILE]) \
			and FileAccess.file_exists("%s/%s" % [gamedata_dir, PROBE_FILE_SHOCK]):
		game = "shock"
		variant = BsaVariant.FUTURESHOCK_FULL
		map_archive = PROBE_FILE_SHOCK
	print("[paths] gamedata: %s (%s)" % [gamedata_dir, game])
	_mount_packs()

# --- resource packs (release layout) ---------------------------------
## A release ships the free ENHANCED asset pack as `enhanced.pck` and may
## keep the converted-asset cache in `converted.pck`; both are ordinary
## Godot resource packs (PCKPacker, built with map_dump --makepack) that
## `load_resource_pack` maps into res://. Verified on 4.7.2: ConfigFile,
## `Image.load_from_file` on a raw WebP, DirAccess listings and
## GLTFDocument (model + its .bin + textures) all read out of a mounted
## pack, and PCKPacker itself runs in an exported build.
##
## Mounted here — before Assets and Render read their directories — so
## `Render.override_dir()` can return res://enhanced and Assets can take
## res://converted as a ready-made (read-only) cache. Directories on
## disk always win when no pack is there, which is the dev setup.
const PACKS: Dictionary = {
	"enhanced": ["res://enhanced", "res://enhanced/replace.cfg"],
	"converted": ["res://converted", "res://converted/VERSION"],
}
## Names from PACKS that are mounted in this run.
var mounted_packs: PackedStringArray = PackedStringArray()

func pack_mounted(name: String) -> bool:
	return name in mounted_packs

## Where a <name>.pck may sit: next to the executable (release), next to
## the project (dev), in user:// (a cache built at first start) and next
## to the game data (portable install). `--pack=PATH` forces one,
## `--no-packs` skips them.
func _pack_bases() -> Array:
	var bases: Array = []
	if OS.has_feature("template"):
		bases.append(OS.get_executable_path().get_base_dir())
	bases.append(ProjectSettings.globalize_path("res://").trim_suffix("/"))
	bases.append(ProjectSettings.globalize_path("user://").trim_suffix("/"))
	if _has_data(gamedata_dir) and not gamedata_dir.begins_with("res://"):
		bases.append(gamedata_dir.get_base_dir())
	return bases

func _mount_packs() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if "--no-packs" in args:
		print("[paths] resource packs skipped (--no-packs)")
		return
	var forced: Array = []
	for a in args:
		if a.begins_with("--pack="):
			forced.append(a.substr(7).strip_edges())
	for pack_name in PACKS:
		var probe: String = PACKS[pack_name][1]
		var path := ""
		for f in forced:
			if f.get_file().get_basename() == pack_name:
				path = f            # --pack= wins even over a dev directory
		if path.is_empty() and FileAccess.file_exists(probe):
			continue                       # already there (dev directory / link)
		if path.is_empty():
			for b in _pack_bases():
				var cand: String = "%s/%s.pck" % [b, pack_name]
				if FileAccess.file_exists(cand):
					path = cand
					break
		if path.is_empty():
			continue
		if not ProjectSettings.load_resource_pack(path):
			push_warning("[paths] %s could not be mounted" % path)
			continue
		if not FileAccess.file_exists(probe):
			push_warning("[paths] %s mounted but has no %s" % [path, probe])
			continue
		mounted_packs.append(pack_name)
		print("[paths] mounted %s → %s" % [path, PACKS[pack_name][0]])

## Pack `src_dir` into the resource pack `out_path`, its contents mapped
## under `prefix` (a res:// path). The counterpart of _mount_packs: this
## is how enhanced.pck is built for a release, and how converted.pck can
## be built from a finished cache — PCKPacker works in an exported build
## too, so the game itself can do it after the first-start import.
## `skip` drops directories by name anywhere in the tree.
## Returns {ok, error, files, bytes_in, bytes_out, msec}.
static func build_pack(src_dir: String, prefix: String, out_path: String,
		skip: PackedStringArray = PackedStringArray()) -> Dictionary:
	var out: Dictionary = {"ok": false, "error": "", "files": 0,
		"bytes_in": 0, "bytes_out": 0, "msec": 0}
	var src: String = src_dir.trim_suffix("/").trim_suffix(BACKSLASH)
	if not DirAccess.dir_exists_absolute(src):
		out["error"] = "no such directory: " + src
		return out
	var t0 := Time.get_ticks_msec()
	var p := PCKPacker.new()
	var err := p.pck_start(out_path)
	if err != OK:
		out["error"] = "cannot create %s: %s" % [out_path, error_string(err)]
		return out
	var n: Array = [0, 0]
	_pack_dir(p, src, prefix.trim_suffix("/"), n, skip)
	err = p.flush(false)
	if err != OK:
		out["error"] = "flush: " + error_string(err)
		return out
	out["ok"] = true
	out["files"] = n[0]
	out["bytes_in"] = n[1]
	out["bytes_out"] = FileAccess.get_file_as_bytes(out_path).size()
	out["msec"] = Time.get_ticks_msec() - t0
	return out

const BACKSLASH := "\\"

static func _pack_dir(p: PCKPacker, abs_dir: String, prefix: String, n: Array,
		skip: PackedStringArray) -> void:
	var d := DirAccess.open(abs_dir)
	if d == null:
		return
	for f in d.get_files():
		var abs: String = abs_dir + "/" + f
		if p.add_file(prefix + "/" + f, abs) == OK:
			n[0] += 1
			n[1] += FileAccess.get_file_as_bytes(abs).size()
	for sub in d.get_directories():
		if sub in skip:
			continue
		_pack_dir(p, abs_dir + "/" + sub, prefix + "/" + sub, n, skip)

static func _has_data(dir: String) -> bool:
	return not dir.is_empty() and (FileAccess.file_exists("%s/%s" % [dir, PROBE_FILE])
		or FileAccess.file_exists("%s/%s" % [dir, PROBE_FILE_SHOCK]))

## The converted-asset cache lives NEXT TO the game data (the player
## asked for a portable install: <game>/gamedata + <game>/converted),
## never in the per-user Godot directory. Data bundled inside the
## project (res://gamedata) keeps the cache in the project while
## developing; an exported build cannot write res://, so that case
## falls back to user://.
static func converted_dir_for(gamedata: String) -> String:
	if gamedata.is_empty():
		return "user://converted"
	if gamedata.begins_with("res://"):
		return "user://converted" if OS.has_feature("template") else "res://converted"
	return gamedata.get_base_dir() + "/converted"

func converted_dir() -> String:
	return converted_dir_for(gamedata_dir if _has_data(gamedata_dir) else "")

## Static so the editor plugin (no autoloads there) can find it too.
static func locate_gamedata() -> String:
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

## The game palette: SkyNET keeps SKYNET.COL (or BRIEF.COL) inside
## MDMDIMGS.BSA; Future Shock ships SHOCK.COL / BRIEF.COL loose in
## GAMEDATA. Every palette reader goes through here.
func palette_bytes() -> PackedByteArray:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var imgs = BSAReader.new()
	if imgs.open(gamedata_path("MDMDIMGS.BSA"), variant):
		for nm in ["SKYNET.COL", "BRIEF.COL"]:
			var b: PackedByteArray = imgs.read(nm)
			if not b.is_empty():
				imgs.close()
				return b
		imgs.close()
	for nm in ["SHOCK.COL", "BRIEF.COL", "SKYNET.COL"]:
		var p: String = gamedata_path(nm)
		if FileAccess.file_exists(p):
			var b: PackedByteArray = FileAccess.get_file_as_bytes(p)
			if not b.is_empty():
				return b
	return PackedByteArray()

## Any .COL palette by name: the image archive first (SkyNET keeps them
## there), then loose in GAMEDATA (Future Shock). Empty when absent.
func col_bytes(name: String) -> PackedByteArray:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var imgs = BSAReader.new()
	if imgs.open(gamedata_path("MDMDIMGS.BSA"), variant):
		var b: PackedByteArray = imgs.read(name)
		imgs.close()
		if not b.is_empty():
			return b
	var p: String = gamedata_path(name)
	if FileAccess.file_exists(p):
		return FileAccess.get_file_as_bytes(p)
	return PackedByteArray()

## The first of several palettes that exists (see col_bytes).
func first_col_bytes(names: Array) -> PackedByteArray:
	for n in names:
		var b: PackedByteArray = col_bytes(String(n))
		if not b.is_empty():
			return b
	return PackedByteArray()

## The briefing/menu UI palette: BRIEF.COL in the archive (SkyNET) or
## loose (Future Shock); the game palette when neither exists.
func ui_palette_bytes() -> PackedByteArray:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var imgs = BSAReader.new()
	if imgs.open(gamedata_path("MDMDIMGS.BSA"), variant):
		var b: PackedByteArray = imgs.read("BRIEF.COL")
		imgs.close()
		if not b.is_empty():
			return b
	var p: String = gamedata_path("BRIEF.COL")
	if FileAccess.file_exists(p):
		var b: PackedByteArray = FileAccess.get_file_as_bytes(p)
		if not b.is_empty():
			return b
	return palette_bytes()

## The OTHER game's data directory, when it sits where the installer
## put it: SkyNET at <root>/gamedata (or GAMEDATA), Future Shock at
## <root>/shock/GAMEDATA — or wherever user://gamedata.cfg says
## ([paths] skynet= / shock=). "" when there is none.
func other_game_dir() -> String:
	var want: String = "shock" if game == "skynet" else "skynet"
	var cfg := ConfigFile.new()
	if cfg.load(GAMEDATA_CFG) == OK:
		var d: String = String(cfg.get_value("paths", want, ""))
		if _has_data(d):
			return d
	var cands: Array[String] = []
	var root: String = gamedata_dir.get_base_dir()
	if game == "skynet":
		for sub in ["shock/GAMEDATA", "shock/gamedata", "SHOCK/GAMEDATA", "futureshock/GAMEDATA"]:
			cands.append(root + "/" + sub)
			cands.append(gamedata_dir + "/" + sub)
	else:
		var up: String = root.get_base_dir()
		for sub in ["gamedata", "GAMEDATA", "skynet/gamedata", "skynet/GAMEDATA"]:
			cands.append(up + "/" + sub)
			cands.append(root + "/" + sub)
	for c in cands:
		if _has_data(c) and c.trim_suffix("/") != gamedata_dir.trim_suffix("/"):
			return c
	return ""

## Start the game again on another data directory — the menu's FUTURE
## SHOCK entry (and, from Future Shock, the way back). Every autoload
## opened its archives on this directory, so a fresh process is the
## honest way to switch. The engine arguments are kept (an editor run
## keeps its --path), --gamedata is replaced.
func relaunch_with_gamedata(dir: String) -> bool:
	if not _has_data(dir):
		return false
	var args: PackedStringArray = PackedStringArray()
	for a in OS.get_cmdline_args():
		if not a.begins_with("--gamedata="):
			args.append(a)
	var user: PackedStringArray = PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--gamedata=") and not a.begins_with("--map="):
			user.append(a)
	user.append("--gamedata=" + dir)
	args.append("--")
	args.append_array(user)
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	print("[paths] relaunch %s %s → pid %d" % [OS.get_executable_path().get_file(), " ".join(args), pid])
	return pid > 0

## Remember a data directory chosen in the menu.
func set_gamedata_dir(dir: String) -> bool:
	if not _has_data(dir):
		return false
	gamedata_dir = dir
	game_root = dir
	var cfg := ConfigFile.new()
	cfg.set_value("paths", "gamedata", dir)
	cfg.save(GAMEDATA_CFG)
	# The cache follows the data directory.
	var assets := get_node_or_null("/root/Assets")
	if assets != null and assets.has_method("relocate"):
		assets.relocate()
	return true

## Map chosen in the main menu; the game scene reads this on load.
## Empty → the game falls back to its own default (MAP.210).
var selected_map: String = ""

## Save slot picked in the LOAD menu; main._ready loads it instead of
## the selected map and resets this to -1.
var pending_load_slot: int = -1

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
