## Autoload `Assets`: the converted-asset cache.
##
## The original game data (gamedata/: BSA archives, TEXTURE.NNN, WLD.*)
## is parsed by the loaders in scripts/loaders/. Decoding it — palette
## look-ups per pixel, .3D face → ArrayMesh, 8-bit RAW → signed PCM — is
## the expensive part of every level load, and it is the same work every
## time. This cache stores the *results* as Godot binary resources
## (.res, compressed) so the second load is a plain ResourceLoader hit:
##
##   converted/tex/T302_017.res       PortableCompressedTexture2D
##   converted/mesh/BIGDOOR.res       ArrayMesh (materials → tex/ by path)
##   converted/frames/ENDOSKEL.res    FramePack of per-frame ArrayMeshes
##   converted/terrain/WLD.210.res    ArrayMesh
##   converted/sfx/DOORA.RAW.res      AudioStreamWAV
##   converted/cfa/WEAPON04.CFA.res   FramePack of textures
##   converted/fx/T358_000.res        FramePack of a sprite's cel frames
##   converted/shape/BIGDOOR.res      ConcavePolygonShape3D (shared)
##   converted/maps/MAP.210.level.scn the level itself, as a Godot scene
##
## Where the cache lives: `<game dir>/converted/` next to the gamedata
## directory in a release (SkynetPaths.converted_dir — a portable
## install), res://converted in a development checkout. A folder the game
## cannot write (an install under Program Files), or one of that name
## holding files this code did not write, is left alone and the cache
## goes to user://converted/<game>-<id> instead.
##
## converted/VERSION holds CACHE_VERSION (first line, as it always has),
## a marker and a fingerprint of the game data. A mismatch — a loader
## change, or v1.00 data swapped for v1.01 — throws the old contents away
## so stale assets are never served: the known subfolders are renamed
## aside in an instant and deleted on a worker thread, and only the file
## kinds this code writes are deleted.
##
## Only files THIS installation wrote are ever loaded — see "Trust
## manifest" below.
##
## Everything is lazy — a miss builds and saves — and `import_all()`
## runs the whole conversion up front (`--import` on the command line,
## or the first-start prompt in the menu).

extends Node

const BSAReader  := preload("res://scripts/loaders/bsa_reader.gd")
const Palette    := preload("res://scripts/loaders/palette.gd")
const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")
const Mesh3D     := preload("res://scripts/loaders/mesh_3d.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")
const CFAFile    := preload("res://scripts/loaders/cfa_file.gd")
const FramePack  := preload("res://scripts/loaders/frame_pack.gd")
const MapScene   := preload("res://scripts/editor/map_scene.gd")
const LevelScene := preload("res://scripts/level_scene.gd")
const MissionScene := preload("res://scripts/mission_scene.gd")

## Bump whenever a loader changes its output.
## 10 (2026-09-14): animation frames share their materials, materials
## carry their Render kind, and VERSION gained the data fingerprint.
const CACHE_VERSION: int = 10
## Dependencies are saved by their absolute path outside res://.
## FLAG_RELATIVE_PATHS would let a moved folder still resolve, but a moved
## folder is rebuilt anyway (the trust manifest is keyed by the absolute
## cache path), so it would buy nothing and complicate the dependency
## check.
const SAVE_FLAGS: int = ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH

## The cache's subfolders — `kind` of fetch(), plus the map and mission
## scenes. A wipe touches these and nothing else.
const KINDS: PackedStringArray = ["tex", "mesh", "frames", "terrain", "sfx",
	"cfa", "cfa_hi", "fx", "shape", "music", "maps", "missions"]
## Folders of KINDS that hold whole SCENES, saved and checked by their own
## code (level_scene.gd, mission_scene.gd) rather than served by fetch().
const SCENE_KINDS: PackedStringArray = ["maps", "missions"]
## File kinds a wipe deletes inside those folders.
const WIPE_EXTS: PackedStringArray = ["res", "scn", "txt", "tmp"]
const VERSION_FILE := "VERSION"
const VERSION_MARKER := "skynet-godot-cache"
const IMPORT_STAMP := "IMPORTED"
const LOCK_FILE := "LOCK"
const PROBE_FILE := ".write_probe"
const TRASH_PREFIX := ".trash-"
## Files of our own at the top of the cache folder.
const ROOT_FILES: PackedStringArray = [VERSION_FILE, IMPORT_STAMP, LOCK_FILE, PROBE_FILE]
## A running game rewrites its LOCK this often; one older than
## LOCK_STALE_SEC belongs to a process that is gone.
## (Short, so a game that was killed does not block a rebuild for long.)
const LOCK_REFRESH_MSEC: int = 20000
const LOCK_STALE_SEC: int = 60

const HIRES_ARCHIVE := "MDMDHRES.BSA"
## Banks whose record 0 is an effect the game plays through
## Explosion.bank_frames (converted even when it has a single frame): the
## muzzle flash, smoke, the explosion and impact pool.
const EFFECT_BANKS: Array = [219, 237, 354, 355, 356, 357, 358, 359, 360,
	361, 362, 363, 364, 365, 366, 367, 368]
## import_all yields a frame after this much work, not after every N
## jobs — most jobs take well under a frame, and a frame wait per four of
## them left ~20 s of idle time over a full import.
const IMPORT_FRAME_BUDGET_USEC: int = 12000
## A long import saves the trust manifest this often.
const IMPORT_MANIFEST_SAVE_MSEC: int = 30000

## Cache root ("" when disabled with --no-cache).
var root: String = ""
var enabled: bool = true
## Statistics for the log / progress UI.
var hits: int = 0
var misses: int = 0
## Cache files found on disk but not loaded (not written by this install).
var untrusted: int = 0

var _palette: PackedColorArray = PackedColorArray()
var _tex_files: Dictionary = {}          # bank → TexFile / false
var _tex_headers: Dictionary = {}        # bank → PackedInt32Array [w, h, frames]*
var _mem: Dictionary = {}                # path → Resource (session cache)
## Session-cache generations: level_started() advances `_gen`, every use
## stamps the entry, and entries no recent level used are let go.
var _gen: int = 0
var _used: Dictionary = {}               # _mem key → generation
var _tex_used: Dictionary = {}           # bank → generation
var _refused: Dictionary = {}            # "kind/key" → true (logged once)
var _requested_root: String = ""         # what SkynetPaths asked for
var _fp: String = ""                     # data fingerprint (memo)
var _hires_ok: int = -1                  # MDMDHRES.BSA present: -1 unknown
var _readers: Dictionary = {}            # archive → BSAReader, during import_all
## start → PackedInt32Array of the maps that mission scene holds, read
## from its sidecar once (mission_maps).
var _mission_maps: Dictionary = {}
var _importing: bool = false
var _lock_msec: int = 0
var _trash_task: int = -1
var _trash_stop: bool = false

static var _key_re: RegEx = RegEx.create_from_string("^[A-Z0-9_.\\-]+$")

func _ready() -> void:
	# The LOCK must stay fresh while the game sits in a pause menu.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if "--no-cache" in args:
		enabled = false
		print("[assets] cache disabled (--no-cache)")
		return
	# Outside the editor a PortableCompressedTexture2D drops its source
	# buffer right after decoding it — and then saves as an EMPTY texture.
	PortableCompressedTexture2D.set_keep_all_compressed_buffers(true)
	_open_root(SkynetPaths.converted_dir())
	if enabled:
		print("[assets] cache at %s" % root)

## The data directory changed (first-start prompt): move to its cache.
func relocate() -> void:
	if not enabled:
		return
	var r := SkynetPaths.converted_dir()
	if r == _requested_root:
		return
	trust_save()
	_lock_release()
	_finish_trash_task(true)
	_forget_session()
	_open_root(r)
	if enabled:
		print("[assets] cache moved to %s" % root)

func _process(_delta: float) -> void:
	if enabled and not root.is_empty() \
			and Time.get_ticks_msec() - _lock_msec >= LOCK_REFRESH_MSEC:
		_lock_touch()
	if _trash_task >= 0 and WorkerThreadPool.is_task_completed(_trash_task):
		_finish_trash_task(false)

func _exit_tree() -> void:
	trust_save()
	_lock_release()
	_finish_trash_task(true)
	_close_readers()
	# Drop the session references before the servers shut down.
	_forget_session()

## Everything held for the current cache root and game data.
func _forget_session() -> void:
	_mem.clear()
	_used.clear()
	_tex_files.clear()
	_tex_used.clear()
	_tex_headers.clear()
	_palette = PackedColorArray()
	_fp = ""
	_hires_ok = -1
	_map_scenes_checked = false
	_cfa_hires_memo.clear()
	_cfa_offset_memo.clear()
	_cfa_lo_memo.clear()
	_mods_norm = ""

## A level is about to load (main.gd). Session-cache entries that neither
## the level being left nor the one before it used are let go; whatever a
## live node still references stays in Godot's own resource cache and
## comes straight back from there. A good moment to save the manifest too.
func level_started() -> void:
	var keep_from: int = _gen - 1
	_gen += 1
	for k in _mem.keys():
		if int(_used.get(k, -1)) < keep_from:
			_mem.erase(k)
			_used.erase(k)
	for b in _tex_files.keys():
		if int(_tex_used.get(b, -1)) < keep_from:
			_tex_files.erase(b)
			_tex_used.erase(b)
	trust_save()

# ---------------------------------------------------------------------
# The cache folder: where, which version, who is using it
# ---------------------------------------------------------------------
## Take `r` as the cache root: fall back to user:// when it cannot be
## written or belongs to something else, check its version, claim it.
func _open_root(r: String) -> void:
	_requested_root = r
	r = r.replace("\\", "/").trim_suffix("/")
	var why: String = ""
	if _foreign(r):
		why = "holds files this game did not write"
	elif not _writable(r):
		why = "cannot be written"
	if not why.is_empty():
		push_warning("[assets] %s %s — the cache goes to %s" % [r, why, _fallback_root()])
		r = _fallback_root()
		if not _writable(r):
			push_warning("[assets] no writable cache folder — running without the cache")
			_disable()
			return
	root = r
	_root_norm = _norm(r)
	_manifest_file = "%s/%s.bin" % [MANIFEST_DIR, _root_norm.md5_text()]
	_trust_load()
	_check_version()
	if enabled:
		_lock_touch()
		_start_trash_cleanup(root)

func _disable() -> void:
	enabled = false
	root = ""
	_root_norm = ""
	_manifest_file = ""

## One cache per data install when the default folder is unusable.
func _fallback_root() -> String:
	return "user://converted/%s-%s" % [SkynetPaths.game,
		_norm(SkynetPaths.gamedata_dir).md5_text().substr(0, 12)]

## A folder named like the cache that this game did not make: never
## wiped and never written into. An empty folder, or one holding only
## the cache's own subfolders and files, is ours.
func _foreign(r: String) -> bool:
	if not DirAccess.dir_exists_absolute(r):
		return false
	var vpath := r + "/" + VERSION_FILE
	if FileAccess.file_exists(vpath):
		return not FileAccess.get_file_as_string(vpath).get_slice("\n", 0).strip_edges().is_valid_int()
	var d := DirAccess.open(r)
	if d == null:
		return false
	for n in d.get_directories():
		if not (n in KINDS or n.begins_with(TRASH_PREFIX)):
			return true
	for n in d.get_files():
		if not n in ROOT_FILES:
			return true
	return false

## Can this process create files in `r`? (Detected by trying: a game
## installed under Program Files otherwise failed every save, with a
## warning, and converted everything again on every run.)
func _writable(r: String) -> bool:
	DirAccess.make_dir_recursive_absolute(r)
	if not DirAccess.dir_exists_absolute(r):
		return false
	var probe := r + "/" + PROBE_FILE
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.store_8(0)
	f.close()
	DirAccess.remove_absolute(probe)
	return true

## What VERSION must say: the format version (first line, the only one
## older builds wrote and read), our marker, and the data fingerprint.
func _marker_text() -> String:
	return "%d\n%s\n%s\n" % [CACHE_VERSION, VERSION_MARKER, _fingerprint()]

## Which game data the cache was built from: the game and the sizes of
## its main archives. v1.00 and v1.01 differ there, and so does another
## game's data dropped into the same folder.
func _fingerprint() -> String:
	if _fp.is_empty():
		var parts := PackedStringArray([SkynetPaths.game])
		for arc in [SkynetPaths.map_archive, "MDMDOBJS.BSA", "MDMDENMS.BSA",
				"MDMDIMGS.BSA", "MDMDSFXS.BSA", HIRES_ARCHIVE]:
			var p: String = SkynetPaths.gamedata_path(String(arc))
			parts.append("%s=%d" % [arc, FileAccess.get_size(p) if FileAccess.file_exists(p) else -1])
		_fp = ",".join(parts)
	return _fp

## Wipe the cache when its version or data fingerprint changed.
func _check_version() -> void:
	var vpath := root + "/" + VERSION_FILE
	var want := _marker_text()
	if FileAccess.file_exists(vpath):
		var have := FileAccess.get_file_as_string(vpath)
		if have == want:
			return
		var old_v: String = have.get_slice("\n", 0).strip_edges()
		if _lock_held_by_other():
			# Another process (an older build, or the editor's job on other
			# data) is using these files right now: never wipe under it.
			push_warning("[assets] the cache at %s (version %s) is in use by another process — running without the cache"
				% [root, old_v])
			_disable()
			return
		print("[assets] cache version %s != %d, or other game data — rebuilding" % [old_v, CACHE_VERSION])
		_wipe(root)
	DirAccess.make_dir_recursive_absolute(root)
	_write_text(vpath, want)

## Throw the cache's contents away without making startup wait for it:
## every known subfolder is renamed into a hidden trash folder (instant)
## and deleted by _start_trash_cleanup on a worker thread. Only the
## cache's own folders and file kinds are touched.
func _wipe(dir: String) -> void:
	_trust_reset()
	_mem.clear()
	_used.clear()
	_map_scenes_checked = false
	var trash := "%s/%s%d-%d" % [dir, TRASH_PREFIX,
		int(Time.get_unix_time_from_system()), OS.get_process_id()]
	for k in KINDS:
		var sub := dir + "/" + k
		if not DirAccess.dir_exists_absolute(sub):
			continue
		DirAccess.make_dir_recursive_absolute(trash)
		if DirAccess.rename_absolute(sub, trash + "/" + k) != OK:
			_delete_tree(sub)                # refused (a file held open?): the slow way
	for fn in [VERSION_FILE, IMPORT_STAMP]:
		if FileAccess.file_exists(dir + "/" + fn):
			DirAccess.remove_absolute(dir + "/" + fn)

## Delete the trash folders under `dir` (this wipe's, or one an earlier
## run did not finish) on a worker thread.
func _start_trash_cleanup(dir: String) -> void:
	_finish_trash_task(false)
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	var trash := PackedStringArray()
	for n in d.get_directories():
		if n.begins_with(TRASH_PREFIX) and not d.is_link(dir + "/" + n):
			trash.append(dir + "/" + n)
	if trash.is_empty():
		return
	_trash_stop = false
	_trash_task = WorkerThreadPool.add_task(_delete_trees.bind(trash), false, "SkyNET cache cleanup")

func _finish_trash_task(stop: bool) -> void:
	if _trash_task < 0:
		return
	if stop:
		_trash_stop = true                   # a half-deleted trash folder waits for the next start
	WorkerThreadPool.wait_for_task_completion(_trash_task)
	_trash_task = -1
	_trash_stop = false

func _delete_trees(dirs: PackedStringArray) -> void:
	for d in dirs:
		_delete_tree(d)

## Delete what this cache writes under `dir`, then the folders left
## empty. A link (junction / symlink) is removed, never followed:
## emptying its target would delete whatever the link points at. Runs on
## a worker thread — file system only.
func _delete_tree(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for n in d.get_directories():
		if _trash_stop:
			return
		var sub := dir + "/" + n
		if d.is_link(sub):
			DirAccess.remove_absolute(sub)
		else:
			_delete_tree(sub)
	for n in d.get_files():
		if _trash_stop:
			return
		if n.get_extension().to_lower() in WIPE_EXTS or n == VERSION_FILE:
			DirAccess.remove_absolute(dir + "/" + n)
	DirAccess.remove_absolute(dir)           # fails, harmlessly, unless empty

## Is a live process other than this one using the cache? (Its LOCK is
## fresh and not ours.)
func _lock_held_by_other() -> bool:
	var f := FileAccess.open(root + "/" + LOCK_FILE, FileAccess.READ)
	if f == null:
		return false
	var parts := f.get_line().strip_edges().split(" ", false)
	f.close()
	if parts.size() < 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return false
	var age: int = int(Time.get_unix_time_from_system()) - int(parts[1])
	return int(parts[0]) != OS.get_process_id() and age > -60 and age < LOCK_STALE_SEC

func _lock_touch() -> void:
	_lock_msec = Time.get_ticks_msec()
	_write_text(root + "/" + LOCK_FILE, "%d %d\n"
		% [OS.get_process_id(), int(Time.get_unix_time_from_system())])

func _lock_release() -> void:
	if root.is_empty():
		return
	var p := root + "/" + LOCK_FILE
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var mine: bool = f.get_line().get_slice(" ", 0).strip_edges() == str(OS.get_process_id())
	f.close()
	if mine:
		DirAccess.remove_absolute(p)

static func _write_text(path: String, text: String) -> bool:
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		return false
	w.store_string(text)
	w.close()
	return true

## True once a full import_all() has finished for this cache version and
## this game data (the menu's first-start prompt asks this).
func import_complete() -> bool:
	if not enabled or root.is_empty():
		return false
	var p := root + "/" + IMPORT_STAMP
	return FileAccess.file_exists(p) and FileAccess.get_file_as_string(p) == _marker_text()

## The shared game palette (SKYNET.COL).
func palette() -> PackedColorArray:
	if _palette.is_empty():
		_palette = Palette.parse(SkynetPaths.palette_bytes())
	return _palette

# ---------------------------------------------------------------------
# Trust manifest
# ---------------------------------------------------------------------
## A Godot resource can carry a script, and loading it runs that script.
## The cache folder is writable by anyone who can put a file there, and a
## "converted" folder may come from anywhere — so a cache file is loaded
## only when THIS installation wrote it. Every successful save records
## the file's size and modification time in a manifest under user://
## (cache_manifest/<md5 of the absolute cache path>.bin, one per cache
## folder; var_to_bytes of {format, root, files: {relative path →
## PackedInt64Array[size, mtime]}}, read back with bytes_to_var, which
## refuses objects). A file with no entry, or one that no longer matches
## it, is a miss: it is built again and overwritten, never loaded. The
## files a resource references are checked the same way before it loads.
##
## The manifest is keyed by the absolute path, so a copied or moved
## install rebuilds its cache on the first run. It is written at the end
## of an import, at level transitions and on exit, merged with whatever
## another process (the editor's headless jobs share this user://) wrote
## meanwhile.
const MANIFEST_DIR := "user://cache_manifest"
const MANIFEST_FORMAT: int = 1
## Kinds whose files reference no other resource: the stamp is the whole
## check. Everything else also has its dependencies checked.
const LEAF_KINDS: PackedStringArray = ["tex", "sfx", "music", "shape"]

var _root_norm: String = ""
var _manifest_file: String = ""
var _manifest_mtime: int = -1
var _manifest_checked_msec: int = 0
var _trusted: Dictionary = {}            # relative path → PackedInt64Array [size, mtime]
var _trust_session: Dictionary = {}      # relative path → recorded stamp, or [] when forgotten
var _verified: Dictionary = {}           # normalised path → true (file and its dependencies)
var _mods_norm: String = ""

## Record a cache file this process has just written.
func trust_record(path: String) -> void:
	var n := _norm(path)
	if _root_norm.is_empty() or not _under(n, _root_norm):
		return
	var st := _stamp(path)
	if st.is_empty():
		return
	var rel := n.substr(_root_norm.length() + 1)
	_trusted[rel] = st
	_trust_session[rel] = st
	_verified[n] = true

## Drop a cache file from the manifest (it was deleted or went stale).
func trust_forget(path: String) -> void:
	var n := _norm(path)
	_verified.erase(n)
	if _root_norm.is_empty() or not _under(n, _root_norm):
		return
	var rel := n.substr(_root_norm.length() + 1)
	_trusted.erase(rel)
	_trust_session[rel] = PackedInt64Array()

## Is `path` inside the cache folder?
func is_cache_path(path: String) -> bool:
	return not _root_norm.is_empty() and _under(_norm(path), _root_norm)

## True when `path` is a cache file this installation wrote and nobody
## changed since — and, unless `leaf`, so is every cache file it
## references (a trusted mesh pointing at a swapped texture is not), and
## everything else it references is part of the game itself (res://,
## outside the cache and the mods folder).
func is_trusted(path: String, leaf: bool = false) -> bool:
	if _root_norm.is_empty():
		return false
	var n := _norm(path)
	if _verified.has(n):
		return true
	if not _stamp_ok(path, n):
		_trust_refresh()
		if not _stamp_ok(path, n):
			return false
	if leaf:
		return true
	if not _deps_ok(path, 0):
		return false
	_verified[n] = true
	return true

func _stamp_ok(path: String, n: String) -> bool:
	if not _under(n, _root_norm):
		return false
	var want: Variant = _trusted.get(n.substr(_root_norm.length() + 1))
	return want is PackedInt64Array and _stamp(path) == want and not has_redirect(path)

## Does a file beside `path` tell the loader to read something else
## instead? (<path>.import and <path>.remap are honoured for any path —
## a matching stamp on the file itself would mean nothing then.)
func has_redirect(path: String) -> bool:
	return FileAccess.file_exists(path + ".import") or FileAccess.file_exists(path + ".remap")

static func _stamp(path: String) -> PackedInt64Array:
	if not FileAccess.file_exists(path):
		return PackedInt64Array()
	return PackedInt64Array([FileAccess.get_size(path), FileAccess.get_modified_time(path)])

func _deps_ok(path: String, depth: int) -> bool:
	if depth > 6:
		return false
	for dep in ResourceLoader.get_dependencies(path):
		for dp in _dep_paths(String(dep), path):
			if not _dep_ok(dp, depth):
				return false
	return true

## Where one dependency entry can send the loader: the path its UID is
## registered under (the loader prefers that) and the path written beside it.
static func _dep_paths(dep: String, owner_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var uid := ""
	var p := dep
	if dep.contains("::"):
		uid = dep.get_slice("::", 0)
		p = dep.get_slice("::", 2)
	elif dep.begins_with("uid://"):
		uid = dep
		p = ""
	if uid.begins_with("uid://"):
		var id: int = ResourceUID.text_to_id(uid)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			out.append(ResourceUID.get_id_path(id))
	if not p.is_empty():
		if not p.contains("://") and p.is_relative_path():
			p = owner_path.get_base_dir().path_join(p)
		out.append(p)
	return out

func _dep_ok(dp: String, depth: int) -> bool:
	var n := _norm(dp)
	if _verified.has(n):
		return true
	if _under(n, _root_norm):
		if not _stamp_ok(dp, n) or not _deps_ok(dp, depth + 1):
			return false
		_verified[n] = true
		return true
	# The game's own files: res://, outside the cache (handled above) and
	# the mods folder. Judged by the res:// spelling, not by where res://
	# lies on disk: an exported build has no such folder (globalize_path
	# of res:// is empty there), and every cached file that references a
	# script of the game — FramePack, the baked levels — was refused and
	# rebuilt on every start.
	if not dp.begins_with("res://"):
		return false
	if _mods_norm.is_empty():
		_mods_norm = _norm(SkynetPaths.mods_dir())
	return not dp.contains("..") and not _under(n, _mods_norm)

## A path in one comparable spelling: absolute, forward slashes, no "..",
## case-folded where the file system ignores case.
static func _norm(p: String) -> String:
	var g := ProjectSettings.globalize_path(p).replace("\\", "/").simplify_path()
	if OS.has_feature("windows") or OS.has_feature("macos"):
		g = g.to_lower()
	return g.trim_suffix("/")

static func _under(n: String, base: String) -> bool:
	return not base.is_empty() and n.begins_with(base + "/")

func _trust_load() -> void:
	_trusted = _read_manifest()
	_trust_session.clear()
	_verified.clear()
	_manifest_mtime = FileAccess.get_modified_time(_manifest_file) \
		if FileAccess.file_exists(_manifest_file) else -1

## The cache was wiped: nothing in it is ours any more.
func _trust_reset() -> void:
	_trusted.clear()
	_trust_session.clear()
	_verified.clear()
	if FileAccess.file_exists(_manifest_file):
		DirAccess.remove_absolute(_manifest_file)
	_manifest_mtime = -1

## Pick up what another process recorded since the manifest was read.
## Throttled: on a cold cache every fetch is a miss.
func _trust_refresh() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _manifest_checked_msec < 1000:
		return
	_manifest_checked_msec = now
	var mt: int = FileAccess.get_modified_time(_manifest_file) \
		if FileAccess.file_exists(_manifest_file) else -1
	if mt == _manifest_mtime:
		return
	_manifest_mtime = mt
	var disk := _read_manifest()
	for rel in _trust_session:
		if (_trust_session[rel] as PackedInt64Array).is_empty():
			disk.erase(rel)
		else:
			disk[rel] = _trust_session[rel]
	_trusted = disk

func _read_manifest() -> Dictionary:
	var out: Dictionary = {}
	if _manifest_file.is_empty() or not FileAccess.file_exists(_manifest_file):
		return out
	var bytes := FileAccess.get_file_as_bytes(_manifest_file)
	if bytes.is_empty():
		return out
	var v: Variant = bytes_to_var(bytes)       # data only: objects are refused
	if not (v is Dictionary):
		return out
	var d: Dictionary = v
	if typeof(d.get("format")) != TYPE_INT or int(d["format"]) != MANIFEST_FORMAT \
			or typeof(d.get("root")) != TYPE_STRING or String(d["root"]) != _root_norm \
			or not (d.get("files") is Dictionary):
		return out
	var files: Dictionary = d["files"]
	for k in files:
		var st: Variant = files[k]
		if k is String and st is PackedInt64Array and (st as PackedInt64Array).size() == 2:
			out[k] = st
	return out

## Write this session's records into the manifest on disk, merged with
## what is there. An entry goes in only while it still matches its file.
func trust_save() -> void:
	if _trust_session.is_empty() or _manifest_file.is_empty():
		return
	var disk := _read_manifest()
	for rel in _trust_session:
		var mine: PackedInt64Array = _trust_session[rel]
		if mine.is_empty():
			disk.erase(rel)
			continue
		var now_st := _stamp(root + "/" + String(rel))
		if now_st == mine:
			disk[rel] = mine
		elif disk.has(rel) and disk[rel] != now_st:
			disk.erase(rel)
	DirAccess.make_dir_recursive_absolute(MANIFEST_DIR)
	var tmp := _manifest_file + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[assets] cannot write the cache manifest %s" % tmp)
		return
	f.store_buffer(var_to_bytes({"format": MANIFEST_FORMAT, "root": _root_norm, "files": disk}))
	f.close()
	if FileAccess.file_exists(_manifest_file):
		DirAccess.remove_absolute(_manifest_file)
	if DirAccess.rename_absolute(tmp, _manifest_file) != OK:
		push_warning("[assets] cannot replace the cache manifest %s" % _manifest_file)
		return
	_trusted = disk
	_trust_session.clear()
	_manifest_mtime = FileAccess.get_modified_time(_manifest_file)

func _note_untrusted(path: String) -> void:
	untrusted += 1
	if untrusted <= 3:
		print("[assets] %s was not written by this installation — building it again" % path)
	elif untrusted == 4:
		print("[assets] (more cache files not written here are being rebuilt)")

# ---------------------------------------------------------------------
# Generic load-or-build
# ---------------------------------------------------------------------
## `key` upper-cased when it is a safe file name — A-Z, 0-9, _ . - and
## no ".." — or "" when it is not.
func safe_key(key: String) -> String:
	var k := key.to_upper()
	if k.contains("..") or _key_re.search(k) == null:
		return ""
	return k

## The cache file for `kind/key`, or "" for a kind or key that must not
## become a path.
func _path(kind: String, key: String) -> String:
	var k := safe_key(key)
	if kind in SCENE_KINDS or not kind in KINDS or k.is_empty():
		var tag := kind + "/" + key
		if not _refused.has(tag):
			_refused[tag] = true
			push_error("[assets] refused cache key %s (A-Z 0-9 _ . - only)" % tag)
		return ""
	return "%s/%s/%s.res" % [root, kind, k]

## Would fetch(kind, key) load from disk instead of building? (A caller
## deciding whether to start a background build asks this — a file
## merely existing is not enough, it has to be one this install wrote.)
func has_cached(kind: String, key: String) -> bool:
	if not enabled:
		return false
	var k := safe_key(key)
	if kind in SCENE_KINDS or not kind in KINDS or k.is_empty():
		return false
	var p := "%s/%s/%s.res" % [root, kind, k]
	return _mem.has(p) or (FileAccess.file_exists(p) and is_trusted(p, kind in LEAF_KINDS))

## Return the cached resource for `kind/key`, building it with
## `builder` (→ Resource or null) and saving it on a miss.
func fetch(kind: String, key: String, builder: Callable) -> Resource:
	if not enabled:
		return builder.call()
	var p := _path(kind, key)
	if p.is_empty():
		# A refused key still gets its resource: built, kept for the
		# session, never saved.
		var mk := "!%s/%s" % [kind, key]
		if not _mem.has(mk):
			_mem[mk] = builder.call()
		_used[mk] = _gen
		return _mem[mk]
	if _mem.has(p):
		_used[p] = _gen
		return _mem[p]
	if FileAccess.file_exists(p):
		if is_trusted(p, kind in LEAF_KINDS):
			var r: Resource = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REUSE)
			if r != null:
				hits += 1
				_mem[p] = r
				_used[p] = _gen
				return r
		else:
			_note_untrusted(p)
	misses += 1
	var built: Resource = builder.call()
	if built != null:
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		var err := ResourceSaver.save(built, p, SAVE_FLAGS)
		if err != OK:
			push_warning("[assets] cannot save %s (%s)" % [p, error_string(err)])
		else:
			# Later saves (a mesh's material → this texture) must reference
			# the file, not embed a copy.
			built.take_over_path(p)
			trust_record(p)
	_mem[p] = built
	_used[p] = _gen
	return built

## Bytes of `name` in archive `arc` — through the reader import_all keeps
## open, or one opened for this read. Empty when either is missing.
func _read_from(arc: String, name: String) -> PackedByteArray:
	var shared: BSAReader = _readers.get(arc)
	if shared != null:
		return shared.read(name)
	var path := SkynetPaths.gamedata_path(arc)
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var b := BSAReader.new()
	if not b.open(path, SkynetPaths.variant):
		return PackedByteArray()
	var bytes := b.read(name)
	b.close()
	return bytes

func _open_readers() -> void:
	_close_readers()
	for arc in [SkynetPaths.map_archive, "MDMDOBJS.BSA", "MDMDENMS.BSA",
			"MDMDIMGS.BSA", "MDMDSFXS.BSA", HIRES_ARCHIVE]:
		var path := SkynetPaths.gamedata_path(String(arc))
		if not FileAccess.file_exists(path):
			continue
		var b := BSAReader.new()
		if b.open(path, SkynetPaths.variant):
			_readers[arc] = b

func _close_readers() -> void:
	for b in _readers.values():
		(b as BSAReader).close()
	_readers.clear()

# ---------------------------------------------------------------------
# Textures — TEXTURE.NNN records
# ---------------------------------------------------------------------
func _tex_file(bank: int) -> TextureNNN.TexFile:
	_tex_used[bank] = _gen
	if _tex_files.has(bank):
		var v = _tex_files[bank]
		return v if v is TextureNNN.TexFile else null
	var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path("TEXTURE.%03d" % bank))
	var t: TextureNNN.TexFile = TextureNNN.parse(bytes) if not bytes.is_empty() else null
	_tex_files[bank] = t if t != null else false
	return t

## Width, height and frame count of every record of TEXTURE.<bank>, as a
## flat [w, h, frames, …] array read from the record headers alone — not
## one pixel is decoded (the sizes used to cost a decode of the whole
## bank). A zero width marks a record the loader cannot read. Memoised.
func _tex_header(bank: int) -> PackedInt32Array:
	if _tex_headers.has(bank):
		return _tex_headers[bank]
	var out := PackedInt32Array()
	var path := SkynetPaths.gamedata_path("TEXTURE.%03d" % bank)
	if FileAccess.file_exists(path):
		out = _parse_tex_header(FileAccess.get_file_as_bytes(path))
	_tex_headers[bank] = out
	return out

## TextureNNN.parse's layout decisions, minus the pixels (see there for
## the format). A sprite record whose run-length data turns out to be
## broken still reports its header size here.
static func _parse_tex_header(b: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	var size: int = b.size()
	if size < 28 + 20 + 28:
		return out
	var tag: int = b.decode_u16(0)
	if tag == 0 or tag > TextureNNN.MAX_RECORDS:
		return out
	for r in tag:
		var ro: int = 28 + r * 20
		if ro + 20 > size:
			break
		var w: int = 0
		var h: int = 0
		var frames: int = 0
		var desc: int = b.decode_u32(ro)
		if desc == 0:
			w = 1                                # solid colour
			h = 1
			frames = 1
		elif desc + 28 <= size:
			var dw: int = b.decode_u16(desc + 4)
			var dh: int = b.decode_u16(desc + 6)
			var pix_off: int = desc + b.decode_u32(desc + 14)
			var row_gap: int = b.decode_u16(desc + 18)
			var depth: int = b.decode_u16(desc + 20)
			if dw > 0 and dh > 0 and dw <= 1024 and dh <= 1024:
				var wall: bool = row_gap != 0
				if not wall and dw == 256 and pix_off + dw * dh <= size:
					var f0: int = b.decode_u32(pix_off)
					wall = depth < 1 or f0 < depth * 4 or pix_off + f0 + 4 > size \
						or b.decode_u16(pix_off + f0) != dw
				if wall:
					if pix_off + (dh - 1) * (dw + row_gap) + dw <= size or pix_off + dw * dh <= size:
						w = dw
						h = dh
						frames = 1
				elif depth >= 1 and pix_off + depth * 4 + 4 <= size:
					var f0_off: int = b.decode_u32(pix_off)
					var f1_off: int = b.decode_u32(pix_off + 4) if depth >= 2 else size - pix_off
					var fs: int = pix_off + f0_off
					if f0_off >= depth * 4 and f1_off > f0_off and pix_off + f1_off <= size \
							and pix_off + f1_off > fs + 4:
						var fw: int = b.decode_u16(fs)
						var fh: int = b.decode_u16(fs + 2)
						if fw > 0 and fh > 0 and fw <= 1024 and fh <= 1024:
							w = fw
							h = fh
							frames = depth
		out.append(w)
		out.append(h)
		out.append(frames)
	return out

## Record `rec` of TEXTURE.<bank> as a saveable texture; index 0 is
## transparent when `transparent0` (billboard sprites).
func texture(bank: int, rec: int, transparent0: bool = false) -> Texture2D:
	var key := "T%03d_%03d%s" % [bank, rec, "_A" if transparent0 else ""]
	var r: Resource = fetch("tex", key, func() -> Resource:
		var img: Image = _texture_image(bank, rec, transparent0)
		if img == null:
			return null
		return _portable(img))
	return r as Texture2D

## The DOS record as an Image.
func _texture_image(bank: int, rec: int, transparent0: bool) -> Image:
	var t := _tex_file(bank)
	if t == null or t.records.is_empty():
		return null
	var ri: int = clampi(rec, 0, t.records.size() - 1)
	return TextureNNN.to_image(t.records[ri], palette(), transparent0)

## Number of frames of a record (1 for a still; 0 when unreadable).
func record_frames(bank: int, rec: int) -> int:
	var h := _tex_header(bank)
	if rec < 0 or rec * 3 + 2 >= h.size():
		return 0
	return h[rec * 3 + 2]

## World size per texel for a billboard of this record: the DOS sprite
## is SPRITE_PIXEL_SIZE units per DOS pixel whatever resolution the
## texture has.
func sprite_pixel_size(bank: int, rec: int, tex: Texture2D, dos_pixel: float) -> float:
	if tex == null or tex.get_height() <= 0:
		return dos_pixel
	return dos_pixel * float(record_size(bank, rec).y) / float(tex.get_height())

## Number of records in TEXTURE.<bank> (0 when the file is missing).
func record_count(bank: int) -> int:
	return _tex_header(bank).size() / 3

## Native DOS pixel size of a record (the UV divisor).
func record_size(bank: int, rec: int) -> Vector2i:
	var h := _tex_header(bank)
	var n: int = h.size() / 3
	if n == 0:
		return Vector2i(64, 64)
	var ri: int = clampi(rec, 0, n - 1)
	if h[ri * 3] <= 0:
		return Vector2i(64, 64)
	return Vector2i(h[ri * 3], h[ri * 3 + 1])

## A saveable texture from an Image. (Never go through ImageTexture:
## on the headless renderer get_image() comes back empty.)
static func _portable(img: Image) -> PortableCompressedTexture2D:
	var pct := PortableCompressedTexture2D.new()
	pct.keep_compressed_buffer = true
	pct.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	return pct

## Provider callable for Mesh3D.build_textured_array_mesh.
func provide(bank: int, rec: int) -> Dictionary:
	var tex := texture(bank, rec, false)
	if tex == null:
		return {}
	return {"texture": tex, "size": record_size(bank, rec)}

# ---------------------------------------------------------------------
# Meshes
# ---------------------------------------------------------------------
## Read a .3D by name from MDMDOBJS.BSA, then MDMDENMS.BSA.
func read_3d(name: String) -> PackedByteArray:
	for arc in ["MDMDOBJS.BSA", "MDMDENMS.BSA"]:
		var bytes := _read_from(arc, name)
		if not bytes.is_empty():
			return bytes
	return PackedByteArray()

## Static textured ArrayMesh for `name` ("BIGDOOR.3D"). `bytes` may be
## supplied by a caller that already has the archive open.
func mesh(name: String, bytes: PackedByteArray = PackedByteArray()) -> ArrayMesh:
	var key := name.get_basename()
	var am := fetch("mesh", key, func() -> Resource:
		var data := bytes if not bytes.is_empty() else read_3d(name)
		if data.is_empty():
			return null
		var parsed: Mesh3D.Mesh3D = Mesh3D.parse(data, key)
		if parsed == null:
			return null
		return Mesh3D.build_textured_array_mesh(parsed, Callable(self, "provide"))) as ArrayMesh
	# The settings may have changed since it was converted.
	Render.restyle_mesh(am)
	return am

## Every animation frame of `name` as an Array of ArrayMesh.
func mesh_frames(name: String, bytes: PackedByteArray = PackedByteArray()) -> Array:
	var key := name.get_basename()
	var pack: Resource = fetch("frames", key, func() -> Resource:
		var data := bytes if not bytes.is_empty() else read_3d(name)
		if data.is_empty():
			return null
		var parsed: Mesh3D.Mesh3D = Mesh3D.parse(data, key)
		if parsed == null:
			return null
		var frames := Mesh3D.build_frame_meshes(parsed, Callable(self, "provide"))
		if frames.is_empty():
			return null
		var fp := FramePack.new()
		fp.frames = frames
		return fp)
	if pack is FramePack:
		for f in (pack as FramePack).frames:
			Render.restyle_mesh(f as Mesh)
		return (pack as FramePack).frames
	return []

# ---------------------------------------------------------------------
# Terrain
# ---------------------------------------------------------------------
## Terrain mesh of WLD.<suffix>; `wld` is the parsed file (heights are
## still needed at runtime), tiles come from TEXTURE.302.
func terrain(suffix: String, wld: WldTerrain.WLD) -> ArrayMesh:
	var am := fetch("terrain", "WLD." + suffix, func() -> Resource:
		if wld == null:
			return null
		var tiles: Array = []
		var t302 := _tex_file(302)
		if t302 != null:
			for i in t302.records.size():
				var rec: TextureNNN.Record = t302.records[i]
				var ok: bool = rec != null and not rec.pixels.is_empty()
				tiles.append(texture(302, i, false) if ok else null)
		return WldTerrain.build_terrain_mesh(wld, tiles)) as ArrayMesh
	Render.restyle_mesh(am)
	return am

## The collision shape of a mesh, shared by every copy of it in every
## map (converted/shape/<key>.res). The level used to call
## MeshInstance3D.create_trimesh_collision() per entity, which walks the
## faces and builds a private ConcavePolygonShape3D — MAP.240 did that
## 410 times, for maybe 120 distinct meshes.
##
## backface_collision is on for all of them: DOS meshes are drawn
## double-sided and their winding is arbitrary (the 210TOWER deck floor
## faces down), so a one-sided shape lets rays and bodies through.
func shape(key: String, mesh: Mesh) -> ConcavePolygonShape3D:
	return fetch("shape", key, func() -> Resource:
		if mesh == null:
			return null
		var sh: ConcavePolygonShape3D = mesh.create_trimesh_shape()
		if sh == null:
			return null
		sh.backface_collision = true
		return sh) as ConcavePolygonShape3D

# ---------------------------------------------------------------------
# Sounds / CFA
# ---------------------------------------------------------------------
## Decoded clip from MDMDSFXS.BSA (`builder` does the decoding — Audio
## owns the parsers).
func sound(name: String, loop: bool, builder: Callable) -> AudioStreamWAV:
	return fetch("sfx", name + ("_L" if loop else ""), builder) as AudioStreamWAV

## Is the optional 640x480 archive there? Asked once per data directory,
## so a missing one is not tried (and logged) for every weapon.
func _hires_available() -> bool:
	if _hires_ok < 0:
		_hires_ok = 1 if FileAccess.file_exists(SkynetPaths.gamedata_path(HIRES_ARCHIVE)) else 0
		if _hires_ok == 0:
			print("[assets] no %s — the 320x200 weapon art only" % HIRES_ARCHIVE)
	return _hires_ok == 1

## Viewmodel frames of a WEAPONnn.CFA as Array[Texture2D].
## `hires`: take the frame from the 640x480 set in MDMDHRES.BSA when it
## has one (the weapon viewmodels do), falling back to the 320x200 art.
## The two sets are cached apart — same key, different kind — or the
## first one built would answer for both.
func cfa_frames(name: String, hires: bool = false) -> Array:
	var pack: Resource = fetch("cfa_hi" if hires else "cfa", name, func() -> Resource:
		var arcs: Array = [HIRES_ARCHIVE, "MDMDIMGS.BSA"] \
			if hires and _hires_available() else ["MDMDIMGS.BSA"]
		# Take the first archive whose copy actually PARSES, not merely the
		# first that holds the name: a set this loader cannot read has to
		# fall through to the other one. Until 2026-09-12 the 640x480
		# WEAPON*.CFA parsed to nothing and the player was left holding an
		# invisible gun, with no warning anywhere.
		for arc in arcs:
			var bytes: PackedByteArray = _read_from(String(arc), name)
			if bytes.is_empty():
				continue
			var frames: Array = CFAFile.parse(bytes, palette(), true)
			if frames.is_empty():
				push_warning("[cfa] %s in %s did not parse — trying the next set"
					% [name, arc])
				continue
			var fp := FramePack.new()
			for f in frames:
				if f is Image:
					fp.frames.append(_portable(f))
			return fp
		return null)
	if pack is FramePack:
		return (pack as FramePack).frames
	return []

## Is `name`'s 640x480 copy the one a hi-res request would actually draw?
## The caller needs this to SCALE the art — the two sets are authored for
## a 320- and a 480-line screen — and the frame's own width cannot say:
## WEAPON13's hi-res art is 145x194, narrower than several of the 320x200
## viewmodels. Reads the archive record's header only (48 bytes), never
## the frames, so a warm disk cache still gets a straight answer; memoised
## per session.
static var _cfa_hires_memo: Dictionary = {}
static var _cfa_offset_memo: Dictionary = {}
func cfa_is_hires(name: String) -> bool:
	if _cfa_hires_memo.has(name):
		return bool(_cfa_hires_memo[name])
	_read_hires_header(name)
	return bool(_cfa_hires_memo.get(name, false))

## The 320x200 art's frame size, which is where the hi-res art has to be
## DRAWN: that placement (weapon record x, bottom on the HUD bar) is the
## one the port has always had right, so the 640x480 frame is scaled into
## the same rectangle rather than positioned from its own header. Reads
## the 16-bit header only; memoised.
static var _cfa_lo_memo: Dictionary = {}
func cfa_lo_size(name: String) -> Vector2i:
	if _cfa_lo_memo.has(name):
		return _cfa_lo_memo[name]
	var out := Vector2i.ZERO
	var bytes: PackedByteArray = _read_from("MDMDIMGS.BSA", name)
	if bytes.size() >= 14 and not CFAFile.is_hires(bytes):
		out = Vector2i(bytes.decode_u16(0), bytes.decode_u16(2))
	_cfa_lo_memo[name] = out
	return out

## The 640x480 art's own x/y placement, (0, 0) when it has none.
func cfa_offset(name: String) -> Vector2i:
	if not _cfa_offset_memo.has(name):
		_read_hires_header(name)
	return _cfa_offset_memo.get(name, Vector2i.ZERO)

func _read_hires_header(name: String) -> void:
	var hires: bool = false
	var off := Vector2i.ZERO
	if _hires_available():
		var bytes: PackedByteArray = _read_from(HIRES_ARCHIVE, name)
		hires = CFAFile.is_hires(bytes)
		if hires:
			off = CFAFile.hires_offset(bytes)
	_cfa_hires_memo[name] = hires
	_cfa_offset_memo[name] = off

## Editor map scenes carry a build number; when map_scene.gd changes what
## it puts in them (sprite sizing, say) every cached one is dropped in
## one go rather than being checked scene by scene.
var _map_scenes_checked: bool = false

func _check_map_scenes() -> void:
	if _map_scenes_checked or root.is_empty() or not enabled:
		return
	_map_scenes_checked = true
	var stamp := root + "/maps/VERSION"
	var have: int = -1
	var f := FileAccess.open(stamp, FileAccess.READ)
	if f != null:
		have = int(f.get_line().strip_edges())
		f.close()
	if have == MapScene.BUILD_VERSION:
		return
	var d := DirAccess.open(root + "/maps")
	if d != null:
		var n := 0
		for fn in d.get_files():
			if fn.ends_with(".scn") and not fn.ends_with(".level.scn"):
				d.remove(fn)
				trust_forget(root + "/maps/" + fn)
				n += 1
		if n > 0:
			print("[assets] %d editor map scenes are from build %d, dropped" % [n, have])
	DirAccess.make_dir_recursive_absolute(root + "/maps")
	var w := FileAccess.open(stamp, FileAccess.WRITE)
	if w != null:
		w.store_line(str(MapScene.BUILD_VERSION))
		w.close()

## Editor scene of a map (built on demand, saved under converted/maps/).
## The editor only opens it from a development checkout, where the cache
## is res://converted and every mesh/texture it references is a res://
## path (SkynetPaths.converted_dir_for).
##
## The game never loads these — the editor opens them from the
## developer's own disk — so an existing one stands even when it is not
## in the trust manifest (a scene saved from the editor after an edit).
func map_scene(map_name: String) -> String:
	_check_map_scenes()
	var p := MapScene.scene_path(map_name)
	if p.is_empty():
		return ""
	if FileAccess.file_exists(p):
		hits += 1
		return p
	misses += 1
	return MapScene.save(map_name)

## Bake the level scene for `map_name` (scripts/level_scene.gd) —
## terrain, static geometry with its collision and the occluders. Loading
## the map writes it as a side effect, so this just makes the loader run.
func level_scene(map_name: String) -> String:
	var p := LevelScene.scene_path(map_name)
	if p.is_empty():
		return ""
	if LevelScene.is_current(p):
		hits += 1
		return p
	misses += 1
	var loader = load("res://scripts/level_loader.gd").new()
	var lvl = loader.load_level(map_name)
	if lvl == null:
		return ""
	for n in [lvl.terrain, lvl.entities, lvl.enemies, lvl.sprites, lvl.sky,
			lvl.occluders, lvl.overlay, lvl.behaviour]:
		if n != null and is_instance_valid(n):
			n.free()
	return p if LevelScene.is_current(p) else ""

# ---------------------------------------------------------------------
# Mission scenes — a whole mission as one scene
# ---------------------------------------------------------------------
## Where MISSION.<start>.scn lives (scripts/mission_scene.gd).
func mission_scene_path(start: int) -> String:
	return MissionScene.scene_path(start)

## Is there a mission scene for `start` on disk at all? The cheap half of
## MissionScene.stale_reason — no archive is opened and no map is hashed —
## for the one caller that has to know BEFORE it blocks: main._begin_mission_level
## puts a notice on the black screen when the first start of a mission still
## has to bake its scene (import_all does all eight, so only a cache an older
## build left behind ever gets there).
func mission_scene_baked(start: int) -> bool:
	if not enabled or start < 0:
		return false
	var p := MissionScene.scene_path(start)
	return not p.is_empty() and FileAccess.file_exists(p)

## The campaign missions a mission scene is baked for. Future Shock keeps
## the per-map runtime (docs/m2_mission_scene_plan.md).
func mission_starts() -> PackedInt32Array:
	return MissionScene.STARTS if SkynetPaths.game != "shock" \
		else PackedInt32Array()

## The mission scene the campaign mission `key` is baked as: the number of
## the map it BEGINS on, -1 when this game bakes none for it.
##
## DOS numbers a mission by the decade its maps sit in — main._mission_key_for
## answers in those numbers, and mission 5 is the 25x maps — but a mission
## does not always begin on the round number: mission 5 starts in the sub
## pens of MAP.252 and its world MAP.250 is two doorways away (Skynet.exe's
## mission table 0x34846). The scene is filed under the START, so the two
## numberings have to meet somewhere, and this is the one place they do —
## asking for MISSION.250.scn instead baked a second, stray scene of a
## mission that begins nowhere, which did not hold MAP.252.
func mission_start_of(key: int) -> int:
	if key < 0:
		return -1
	for s in mission_starts():
		if (int(s) / 10) * 10 == (key / 10) * 10:
			return int(s)
	return -1

## Every DOS map the mission scene of mission `key` holds — its zones and
## the re-authored variants of its worlds (MissionScene.baked_maps, the
## census's own list, read from the sidecar and kept). Empty when the
## mission has no baked scene.
func mission_maps(key: int) -> PackedInt32Array:
	var start: int = mission_start_of(key)
	if start < 0:
		return PackedInt32Array()
	if not _mission_maps.has(start):
		_mission_maps[start] = MissionScene.baked_maps(start)
	return _mission_maps[start]

## Is `map_name` one of the maps of mission `key`? The one answer to
## "which mission does this map belong to", which a map number cannot give
## alone — see MissionScene.baked_maps. False when nothing is baked yet,
## and the caller then falls back to the map's own number.
func mission_holds(key: int, map_name: String) -> bool:
	var sfx: String = map_name.get_extension()
	if not sfx.is_valid_int():
		return false
	var num: int = int(sfx)
	for n in mission_maps(key):
		if int(n) == num:
			return true
	return false

## Bake MISSION.<start>.scn when it is missing, stale or not this
## installation's, and answer where it is ("" when it cannot be had).
## `shared` is the census's parsed-map cache: a caller doing several
## missions hands the same one round, so the interiors they have in common
## are read once. The conversion asks for this — it wants the file, not
## the resource.
func build_mission_scene(start: int, shared: Dictionary = {}) -> String:
	if not enabled:
		return ""
	var p := MissionScene.scene_path(start)
	if p.is_empty():
		return ""
	# import_all keeps the map archive open; on its own this opens one.
	var bsa: BSAReader = _readers.get(SkynetPaths.map_archive)
	var mine: bool = bsa == null
	if mine:
		bsa = BSAReader.new()
		if not bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive),
				SkynetPaths.variant):
			push_warning("[assets] cannot open %s for mission %d"
				% [SkynetPaths.map_archive, start])
			return ""
	var stale: String = MissionScene.stale_reason(start, bsa)
	if stale.is_empty():
		hits += 1
	else:
		misses += 1
		print("[mission] %d: baking MISSION.%03d.scn — %s" % [start, start, stale])
		p = MissionScene.save(start, bsa, shared)
		_mission_maps.erase(start)        # the sidecar's map list is new
	if mine:
		bsa.close()
	if p.is_empty() or not FileAccess.file_exists(p):
		return ""
	if not is_trusted(p):
		_note_untrusted(p)
		return ""
	return p

## The mission scene itself, baked first when it has to be — what step 4
## of docs/m2_mission_scene_plan.md starts a mission from.
func mission_scene(start: int) -> PackedScene:
	var p := build_mission_scene(start)
	if p.is_empty():
		return null
	return ResourceLoader.load(p, "PackedScene",
		ResourceLoader.CACHE_MODE_REUSE) as PackedScene

## Only the mission scenes (`--import-missions`). A mission bake needs
## nothing of the conversion but the level scenes of its own zones, and it
## asks for those itself — so this is the short way round for a change to
## the mission bake alone. Returns how many are ready.
func import_missions(progress: Callable = Callable()) -> int:
	if not enabled or _importing:
		return 0
	_importing = true
	_open_readers()
	var starts := mission_starts()
	var shared: Dictionary = {}
	var t0 := Time.get_ticks_msec()
	var done: int = 0
	var ready_now: int = 0
	for s in starts:
		var t1 := Time.get_ticks_msec()
		var ok: bool = not build_mission_scene(int(s), shared).is_empty()
		done += 1
		if ok:
			ready_now += 1
		print("[assets] MISSION.%03d %s in %.1f s" % [int(s),
			"ready" if ok else "FAILED", (Time.get_ticks_msec() - t1) / 1000.0])
		if progress.is_valid():
			progress.call(done, starts.size(), "MISSION.%03d" % int(s))
		if is_inside_tree():
			await get_tree().process_frame
	_close_readers()
	_importing = false
	trust_save()
	print("[assets] %d of %d mission scenes in %.1f s"
		% [ready_now, done, (Time.get_ticks_msec() - t0) / 1000.0])
	return ready_now

# ---------------------------------------------------------------------
# Full conversion pass
# ---------------------------------------------------------------------
## Convert everything the game can use up front. `progress` receives
## (done: int, total: int, label: String); yields between items so a
## caller can draw a progress screen. Returns the number of items.
##
## The editor's data view of every map (converted/maps/MAP.NNN.scn — a
## complete level load each) is only built in an editor build, or when
## `map_scenes` / `--import-map-scenes` asks for it: a game install never
## opens one.
func import_all(progress: Callable = Callable(), map_scenes: bool = false) -> int:
	if not enabled or _importing:
		return 0
	_importing = true
	map_scenes = map_scenes or OS.has_feature("editor") \
		or "--import-map-scenes" in OS.get_cmdline_user_args()
	# One open reader per archive for the whole pass (read_3d, the CFA
	# sets and the sounds used to open an archive per item).
	_open_readers()
	var jobs: Array = []                       # [label, Callable]
	# Meshes: every .3D in both archives (frames for the enemy archive).
	for arc in ["MDMDOBJS.BSA", "MDMDENMS.BSA"]:
		var b: BSAReader = _readers.get(arc)
		if b == null:
			continue
		for e in b.entries():
			var nm: String = e.name.to_upper()
			if not nm.ends_with(".3D"):
				continue
			if arc == "MDMDENMS.BSA":
				jobs.append([nm, func() -> void: mesh_frames(nm)])
			else:
				jobs.append([nm, func() -> void: mesh(nm)])
	# Terrains, and the cel animations of every texture bank (effects and
	# animated scenery — converted during play until now).
	var d := DirAccess.open(SkynetPaths.gamedata_dir)
	if d != null:
		for fn in d.get_files():
			var up: String = fn.to_upper()
			if up.begins_with("WLD."):
				var sfx: String = fn.split(".")[1]
				jobs.append([fn, func() -> void:
					var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path(fn))
					if not bytes.is_empty():
						terrain(sfx, WldTerrain.parse(bytes))])
			elif up.begins_with("TEXTURE.") and up.get_extension().is_valid_int():
				var bank: int = int(up.get_extension())
				jobs.append([up + " (animations)", func() -> void: _import_animations(bank)])
	# Sounds.
	var sounds: BSAReader = _readers.get("MDMDSFXS.BSA")
	if sounds != null:
		for e in sounds.entries():
			var snd: String = e.name.to_upper()
			jobs.append([snd, func() -> void: Audio.stream(snd)])
	# Weapon viewmodels, and their 640x480 set when the data has one.
	var hires: bool = _hires_available()
	for i in 14:
		var cfa := "WEAPON%02d.CFA" % i
		jobs.append([cfa, func() -> void: cfa_frames(cfa)])
		if hires:
			jobs.append([cfa + " (640x480)", func() -> void: cfa_frames(cfa, true)])
	# The music's instrument samples (Audio builds them through fetch()).
	var audio: Node = get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("prewarm_music"):
		jobs.append(["music instruments", func() -> void: audio.call("prewarm_music")])
	# Map scenes: the level itself (MAP.NNN.level.scn — the world in
	# Godot's own format, which is what the game loads) and, for the
	# editor, the data view (MAP.NNN.scn — one node per MAP record, what
	# the SkyNET Maps dock edits and exports). Built here so the first run
	# pays for the whole conversion and nothing is derived during play.
	var maps: BSAReader = _readers.get(SkynetPaths.map_archive)
	if maps != null:
		for e in maps.entries():
			var mn: String = e.name.to_upper()
			if mn.begins_with("MAP."):
				if map_scenes:
					jobs.append([mn, func() -> void: map_scene(mn)])
				jobs.append([mn + " (level)", func() -> void: level_scene(mn)])
	# The missions come last: one holds INSTANCES of the level scenes above
	# (scripts/mission_scene.gd), so every zone it stands on has to be baked
	# before it. They share one census cache — the campaign's interiors are
	# reached from several missions apiece.
	var census: Dictionary = {}
	for s in mission_starts():
		var ms: int = int(s)
		jobs.append(["MISSION.%03d" % ms,
			func() -> void: build_mission_scene(ms, census)])

	var t0 := Time.get_ticks_msec()
	var last_yield := Time.get_ticks_usec()
	var last_save := t0
	var done := 0
	for j in jobs:
		(j[1] as Callable).call()
		done += 1
		if progress.is_valid():
			progress.call(done, jobs.size(), String(j[0]))
		if Time.get_ticks_msec() - last_save >= IMPORT_MANIFEST_SAVE_MSEC:
			trust_save()
			last_save = Time.get_ticks_msec()
		if is_inside_tree() and Time.get_ticks_usec() - last_yield >= IMPORT_FRAME_BUDGET_USEC:
			await get_tree().process_frame
			last_yield = Time.get_ticks_usec()
	_close_readers()
	_importing = false
	if enabled and not root.is_empty():
		# Last: the menu takes this file as "the conversion has run".
		_write_text(root + "/" + IMPORT_STAMP, _marker_text())
	trust_save()
	print("[assets] imported %d items in %.1f s (%d built, %d cached, %d not ours rebuilt)"
		% [done, (Time.get_ticks_msec() - t0) / 1000.0, misses, hits, untrusted])
	return done

## The cel animations of TEXTURE.<bank>, asked for exactly as the game
## asks (Explosion.bank_frames, same cache keys): every record with more
## than one frame the way the animated billboards want it, and record 0
## of the effect banks however many frames it has.
func _import_animations(bank: int) -> void:
	var h := _tex_header(bank)
	if h.is_empty():
		return
	var ex: Script = load("res://scripts/explosion.gd")
	if ex == null or not ex.get_script_method_list().any(
			func(m: Dictionary) -> bool: return m.get("name") == "bank_frames"):
		return
	if bank in EFFECT_BANKS and h[2] > 0:
		ex.call("bank_frames", bank, 0)
	for r in h.size() / 3:
		if h[r * 3 + 2] > 1:
			ex.call("bank_frames", bank, r, 2)
