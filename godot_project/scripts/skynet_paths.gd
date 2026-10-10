## Autoload: locates the original game data (SKYNET / Future Shock).
##
## Published builds carry no game data: the player points the game at
## their own GAMEDATA folder (4 BSA archives + WLD.* + TEXTURE.*) on first
## start (data_setup.gd), remembered in user://gamedata.cfg. A personal
## build (Android) may bundle it under res://gamedata instead.

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
	_adopt_game(gamedata_dir)
	print("[paths] gamedata: %s (%s)" % [gamedata_dir, game])

## Game, archive key and map archive name for the data in `dir`.
func _adopt_game(dir: String) -> void:
	if variant_for(dir) == BsaVariant.FUTURESHOCK_FULL:
		game = "shock"
		variant = BsaVariant.FUTURESHOCK_FULL
		map_archive = PROBE_FILE_SHOCK
	else:
		game = "skynet"
		variant = BsaVariant.SKYNET_FULL
		map_archive = PROBE_FILE

# (No converted.pck: mounting a resource pack from a folder the player can
# write to would let whoever put it there replace any res:// script.)

const BACKSLASH := "\\"

## Per directory: upper-case file name → the name on disk. Every name the
## port asks for is built upper-case, as DOS wrote it, but data copied
## onto a case-sensitive file system (Linux) often arrives lower-case.
static var _disk_names: Dictionary = {}

static func _names_in(dir: String) -> Dictionary:
	var known = _disk_names.get(dir)
	if known is Dictionary:
		return known
	var names: Dictionary = {}
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			var up: String = f.to_upper()
			# Two spellings of one name (Linux): the DOS one wins.
			if f == up or not names.has(up):
				names[up] = f
	_disk_names[dir] = names
	return names

## `dir`/`nm` spelt as the file is on disk, whatever its letter case;
## "" when there is no such file.
static func find_file(dir: String, nm: String) -> String:
	if dir.is_empty():
		return ""
	var real: String = String(_names_in(dir).get(nm.to_upper(), ""))
	if not real.is_empty():
		return "%s/%s" % [dir, real]
	# A folder that cannot be listed may still open files by name.
	var exact: String = "%s/%s" % [dir, nm]
	return exact if FileAccess.file_exists(exact) else ""

static func _has_data(dir: String) -> bool:
	return not dir.is_empty() and (not find_file(dir, PROBE_FILE).is_empty()
		or not find_file(dir, PROBE_FILE_SHOCK).is_empty())

## Where map mods live. A development run keeps them in the project
## (res://mods, which the editor writes); an exported build beside the
## game data, <parent of GAMEDATA>/mods — never inside the pack. Data
## bundled in the pack (Android) has no such folder: user://mods then.
static func mods_dir() -> String:
	if not OS.has_feature("template"):
		return "res://mods"
	var dir: String = ""
	var tree := Engine.get_main_loop() as SceneTree
	var me: Node = tree.root.get_node_or_null("SkynetPaths") if tree != null else null
	if me != null:
		dir = String(me.get("gamedata_dir"))
	if not _has_data(dir):
		dir = locate_gamedata()
	if dir.is_empty() or dir.begins_with("res://"):
		return "user://mods"
	return dir.get_base_dir() + "/mods"

## The converted-asset cache lives NEXT TO the game data (the player
## asked for a portable install: <game>/gamedata + <game>/converted),
## never in the per-user Godot directory. An exported build cannot
## write res://, so data bundled there falls back to user://.
##
## A development checkout keeps SkyNET's cache in the project itself,
## res://converted (gitignored, skipped by the export plugin), so the
## editor can open the map scenes and every saved resource references
## res:// paths — no directory link needed. Future Shock's record
## numbers collide with SkyNET's, so its cache always stays beside its
## own data.
static func converted_dir_for(gamedata: String) -> String:
	if gamedata.is_empty():
		return "user://converted"
	if not OS.has_feature("template") and game_of(gamedata) != "shock":
		return "res://converted"
	if gamedata.begins_with("res://"):
		return "user://converted"
	return gamedata.get_base_dir() + "/converted"

func converted_dir() -> String:
	return converted_dir_for(gamedata_dir if _has_data(gamedata_dir) else "")

## Which game a data directory holds, as an archive key. Static like
## locate_gamedata, because a `--script` tool gets no autoloads either -
## `SkynetPaths` is not even a known identifier there, so the dev probes
## in tools/ load this script and ask it directly.
static func variant_for(dir: String) -> int:
	if find_file(dir, PROBE_FILE).is_empty() \
			and not find_file(dir, PROBE_FILE_SHOCK).is_empty():
		return BsaVariant.FUTURESHOCK_FULL
	return BsaVariant.SKYNET_FULL

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

## Palette bytes already read, by "<data dir>|<which>": the loader, the
## HUD, sprites and every effect ask, and each read opened MDMDIMGS.BSA
## and parsed its directory again. Other data reads afresh.
var _col_memo: Dictionary = {}

## The game palette: SKYNET.COL (or BRIEF.COL) inside MDMDIMGS.BSA, for
## Future Shock too. GAME.EXE v1.01 loads "skynet.col" unconditionally
## (0x1175fe; the exe has no "shock.col" string) from the first image
## archive its search (FUN_0013e9c5) finds — SkyNET's own — so FS takes
## SkyNET's archive when its folder is known (front_archive). FS's loose
## SHOCK.COL is only the fallback without SkyNET's data: it differs from
## SKYNET.COL only at 0x11-0x1B, and 0x11 — the night sky's fill
## (FUN_0013404b) — is grey (55,51,55) there instead of black.
## Every palette reader goes through here.
func palette_bytes() -> PackedByteArray:
	var key: String = "%s|*game" % gamedata_dir
	if not _col_memo.has(key):
		_col_memo[key] = _read_palette()
	return _col_memo[key]

func _read_palette() -> PackedByteArray:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var imgs = BSAReader.new()
	var arc: Array = front_archive("MDMDIMGS.BSA")
	if imgs.open(String(arc[0]), int(arc[1])):
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
func col_bytes(nm: String) -> PackedByteArray:
	var key: String = "%s|%s" % [gamedata_dir, nm]
	if not _col_memo.has(key):
		_col_memo[key] = _read_col(nm)
	return _col_memo[key]

func _read_col(nm: String) -> PackedByteArray:
	var BSAReader = load("res://scripts/loaders/bsa_reader.gd")
	var imgs = BSAReader.new()
	if imgs.open(gamedata_path("MDMDIMGS.BSA"), variant):
		var b: PackedByteArray = imgs.read(nm)
		imgs.close()
		if not b.is_empty():
			return b
	var p: String = gamedata_path(nm)
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
	var key: String = "%s|*ui" % gamedata_dir
	if not _col_memo.has(key):
		_col_memo[key] = _read_ui_palette()
	return _col_memo[key]

func _read_ui_palette() -> PackedByteArray:
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

## SkyNET's own data folder: this one in SkyNET; in Future Shock the one
## the relaunch named (--skynet-data=) or other_game_dir(). "" when unknown.
## DOS GAME.EXE plays Future Shock from inside SkyNET: only the maps come
## from FS's folder, the menus and the briefing are SkyNET's.
var _skynet_dir_memo: Variant = null

func skynet_dir() -> String:
	if game == "skynet":
		return gamedata_dir
	if _skynet_dir_memo == null:
		var d: String = ""
		var args: PackedStringArray = OS.get_cmdline_args()
		args.append_array(OS.get_cmdline_user_args())
		for a in args:
			if a.begins_with("--skynet-data="):
				var c: String = a.substr(14).strip_edges().trim_suffix("/").trim_suffix(BACKSLASH)
				if game_of(c) == "skynet":
					d = c
		if d.is_empty():
			d = other_game_dir()
		_skynet_dir_memo = d
	return String(_skynet_dir_memo)

## [path, archive key] of a front-end archive (MDMDIMGS.BSA, MDMDBRIF.BSA):
## SkyNET's own when its folder is known, else this game's copy.
func front_archive(nm: String) -> Array:
	var sky: String = skynet_dir()
	if game == "shock" and not sky.is_empty():
		var p: String = find_file(sky, nm)
		if not p.is_empty():
			return [p, BsaVariant.SKYNET_FULL]
	return [gamedata_path(nm), variant]

## [path, archive key] of the 640x480 art, MDMDHRES.BSA — SkyNET's own in
## Future Shock too, which ships none. GAME.EXE opens every archive through
## FUN_0013e9c5, which tries its search directories in order: 0x5f400,
## 0x5f480, and only then 0x5f500 (each "<dir>\gamedata", FUN_0013e47f).
## The first ones are SkyNET's install, so in FS mode the hi-res HUD and
## weapons still come from SkyNET's folder (owner's FS log 2026-10-09:
## "BSA open failed: .../shock/gamedata/MDMDHRES.BSA").
func hires_archive() -> Array:
	return front_archive("MDMDHRES.BSA")

## A loose front-end file (FONT00NN.FNT) the same way: SkyNET's own copy
## when its folder is known — FS's fonts map K/H to other glyphs and
## have no lower case — else this game's.
func front_path(nm: String) -> String:
	var sky: String = skynet_dir()
	if game == "shock" and not sky.is_empty():
		var p: String = find_file(sky, nm)
		if not p.is_empty():
			return p
	return gamedata_path(nm)

## True when Future Shock was started from SkyNET's NEW GAME menu: the
## menu skips itself and opens mission 1's briefing (DOS FUN_0011e6f9).
## Set by switch_game (in-process) or `--fs-start` (the relaunch fallback);
## consumed by the menu.
var fs_start_pending: bool = false

func fs_start_requested() -> bool:
	if fs_start_pending:
		return true
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	return game == "shock" and args.has("--fs-start")

## SkyNET's folder while Future Shock runs in this process (switch_game);
## the menu switches back to it. "" when no switch happened.
var home_dir: String = ""

## Switch this process to the other game's data, the way DOS GAME.EXE plays
## Future Shock from inside SkyNET — no new process. The remembered data
## folder (user://gamedata.cfg) is not touched. Everything fixed by the data
## root is re-pointed or emptied:
##   - game / variant / map_archive / gamedata_dir, the palette memo, the
##     disk-name listing (here);
##   - the asset cache root and its session caches (Assets.relocate:
##     converted/ ↔ shock/converted, textures, meshes, CFA memos);
##   - Audio's archive + sound cache (re-opened on the next sound, keyed by
##     gamedata_dir) and its parsed songs;
##   - the static record-keyed caches: LevelLoader sprite frames, Explosion
##     bank frames, Projectile meshes, TriggerGraph damage stages, PRS
##     tables, NetLevels, the grenade sprite, the door-like mesh memo.
## Rules (rules_skynet / rules_shock) and the campaign tables are chosen by
## `game` each time they are asked, so they follow without a reset.
func switch_game(dir: String) -> bool:
	_disk_names.clear()
	if not _has_data(dir):
		return false
	var from: String = gamedata_dir
	var to_game: String = game_of(dir)
	if to_game == game and dir == gamedata_dir:
		return true
	gamedata_dir = dir
	game_root = dir
	_adopt_game(dir)
	_col_memo.clear()
	if to_game == "shock":
		home_dir = from
		_skynet_dir_memo = from
	else:
		home_dir = ""
		_skynet_dir_memo = null
	var assets := get_node_or_null("/root/Assets")
	if assets != null and assets.has_method("relocate"):
		assets.relocate()
	var audio := get_node_or_null("/root/Audio")
	if audio != null:
		var songs = audio.get("_songs")
		if songs is Dictionary:
			(songs as Dictionary).clear()
	for p in ["res://scripts/level_loader.gd", "res://scripts/level_behaviour.gd",
			"res://scripts/explosion.gd", "res://scripts/projectile.gd",
			"res://scripts/triggers/trigger_graph.gd", "res://scripts/loaders/prs_file.gd",
			"res://scripts/net/net_levels.gd", "res://scripts/grenade.gd"]:
		var s: Script = load(p)
		if s != null:
			s.call("reset_game")
	selected_map = ""
	print("[paths] switched to %s (%s) in-process" % [gamedata_dir, game])
	return true

## Start the game again on another data directory — the menu's FUTURE
## SHOCK entry (and, from Future Shock, the way back). The game, the
## archive keys and a dozen static caches are fixed at startup and the
## two games share record numbers, so a fresh process is the honest way
## to switch. The caller quits right after.
##
## Nothing from this run's command line is carried over (a --map,
## --host or --screenshot must not replay in the other game) except,
## for a run from the editor, the project path.
func relaunch_with_gamedata(dir: String) -> bool:
	if not _has_data(dir):
		return false
	var args := PackedStringArray()
	if not OS.has_feature("template"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--", "--gamedata=" + dir])
	if game == "skynet" and game_of(dir) == "shock":
		# Straight to FS mission 1 on SkyNET's menu art, as DOS does.
		args.append_array(["--skynet-data=" + gamedata_dir, "--fs-start"])
	if OS.has_feature("template") and OS.has_feature("pc"):
		# The engine starts the new instance once this one has shut down,
		# so the ports, the audio device and the user:// files are free.
		OS.set_restart_on_exit(true, args)
		print("[paths] restart on exit with %s" % " ".join(args))
		return true
	# set_restart_on_exit does nothing for a run started from the editor.
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	print("[paths] relaunch %s %s → pid %d" % [OS.get_executable_path().get_file(), " ".join(args), pid])
	return pid > 0

## True while the game still does not know where the originals are — the
## first-run screen (scripts/data_setup.gd) then asks for them.
func needs_setup() -> bool:
	return not _has_data(gamedata_dir)

## A folder the player picked may be the data directory itself or the
## game's install root: take <dir>, <dir>/gamedata or, for Future Shock
## installed under SkyNET, <dir>/shock/GAMEDATA. "" when none holds data.
static func resolve_data_dir(picked: String) -> String:
	var d: String = picked.strip_edges().trim_suffix("/").trim_suffix(BACKSLASH)
	if d.is_empty():
		return ""
	# The player may have copied the data in since a folder was last listed.
	_disk_names.clear()
	for cand in [d, d + "/gamedata", d + "/GAMEDATA",
			d + "/shock/GAMEDATA", d + "/shock/gamedata", d + "/SHOCK/GAMEDATA"]:
		if _has_data(cand):
			return cand
	return ""

## Which game a data directory holds: "skynet", "shock", or "" for neither.
static func game_of(dir: String) -> String:
	if not find_file(dir, PROBE_FILE).is_empty():
		return "skynet"
	if not find_file(dir, PROBE_FILE_SHOCK).is_empty():
		return "shock"
	return ""

## Remember the OTHER game's data directory under its own key, so
## other_game_dir() finds it and the menu can start it.
func set_other_game_dir(dir: String) -> bool:
	var g: String = game_of(dir)
	if g.is_empty():
		return false
	var cfg := ConfigFile.new()
	cfg.load(GAMEDATA_CFG)                 # keep whatever else is in there
	cfg.set_value("paths", g, dir)
	cfg.save(GAMEDATA_CFG)
	return true

## Remember a data directory chosen in the menu.
func set_gamedata_dir(dir: String) -> bool:
	_disk_names.clear()
	if not _has_data(dir):
		return false
	gamedata_dir = dir
	game_root = dir
	# The archive key and map archive follow the data (Future Shock picked
	# here found no maps until a restart). This process's record caches are
	# still the old game's, so data_setup.gd restarts on another game.
	_adopt_game(dir)
	_col_memo.clear()
	var cfg := ConfigFile.new()
	# Load first: a fresh ConfigFile would drop the other game's path.
	cfg.load(GAMEDATA_CFG)
	cfg.set_value("paths", "gamedata", dir)
	var g: String = game_of(dir)
	if not g.is_empty():
		cfg.set_value("paths", g, dir)
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

## `filename` in the data directory, spelt as on disk (see find_file);
## the name as given when no such file exists.
func gamedata_path(filename: String) -> String:
	var p: String = find_file(gamedata_dir, filename)
	return p if not p.is_empty() else "%s/%s" % [gamedata_dir, filename]

func read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Could not open: %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return PackedByteArray()
	var data := f.get_buffer(f.get_length())
	f.close()
	return data
