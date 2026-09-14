## Save-game slots (docs/implementation_plan.md §N.4).
##
## One file per slot under user://saves/ (SkyNET) or user://saves/shock/
## (Future Shock: the two games number their maps differently, so one
## game's LOAD screen must not offer the other's saves). The first line
## is a short header the LOAD menu can show without parsing the body:
##   SKYNET-SAVE <version>|<map>|<yyyy-mm-dd hh:mm>|<game>
## Format 2 bodies are JSON: `JSON.from_native` of the session dictionary
## built by main.save_to_slot, so int keys, Vector2i / Vector3 values and
## typed arrays come back exactly as they went in. Objects are neither
## written nor read (to_native without allow_objects), so a save file —
## something players share — cannot load a Resource or run a script.
## Format 1 bodies (var_to_str text, older builds) still load when they
## name no Object or Resource: str_to_var would instantiate or load those.
## Used via `const SaveGame := preload("res://scripts/save_game.gd")`
## (headless runs do not see class_name registrations).

const DIR := "user://saves"
const SLOTS: int = 10
## F6 / F7 use slot 0 — shown as the first LOAD.IMG bar.
const QUICK_SLOT: int = 0
const VERSION: int = 2
## The var_to_str text format builds before 2026-09-14 wrote.
const VERSION_TEXT: int = 1
const MAGIC := "SKYNET-SAVE"

## Why the last read() returned {} ("" for an empty slot or a good read),
## for a line in the menu.
static var last_error: String = ""

## The running game's save folder.
static func folder() -> String:
	return DIR + "/shock" if _game() == "shock" else DIR

## SkynetPaths.game, looked up in the tree so this script also compiles
## where the autoloads do not exist.
static func _game() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var paths: Node = tree.root.get_node_or_null("SkynetPaths") if tree != null else null
	return String(paths.get("game")) if paths != null else "skynet"

static func path(slot: int) -> String:
	return "%s/slot_%02d.save" % [folder(), slot]

## A write goes here first and replaces the slot only once complete.
static func _tmp_path(slot: int) -> String:
	return path(slot) + ".tmp"

## The slot's file, "" when empty. On Windows a rename over an existing
## file is remove + move: a crash between the two leaves only the finished
## temporary copy, which then stands in for the save.
static func _file(slot: int) -> String:
	var p: String = path(slot)
	if FileAccess.file_exists(p):
		return p
	var tmp: String = _tmp_path(slot)
	return tmp if FileAccess.file_exists(tmp) else ""

static func exists(slot: int) -> bool:
	return not _file(slot).is_empty()

## Write `data` (must carry "map") to `slot`. Returns false on failure.
static func write(slot: int, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(folder())
	var target: String = path(slot)
	var tmp: String = _tmp_path(slot)
	# full_precision: Vector components are raw JSON numbers.
	var body: String = JSON.stringify(JSON.from_native(data), "", false, true)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[save] cannot write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	var stamp: String = Time.get_datetime_string_from_system(false, true).left(16)
	var ok: bool = f.store_line("%s %d|%s|%s|%s" % [MAGIC, VERSION, String(data.get("map", "")), stamp, _game()]) \
		and f.store_string(body)
	f.close()
	if not ok:
		push_error("[save] writing %s failed (disk full?)" % tmp)
		DirAccess.remove_absolute(tmp)
		return false
	# Only a complete file replaces the slot, so a crash mid-write cannot
	# cost the player the quicksave they had.
	var err: Error = DirAccess.rename_absolute(tmp, target)
	if err != OK:
		push_error("[save] cannot replace %s (%s)" % [target, error_string(err)])
		return false
	return true

## The saved session dictionary, or {} when the slot is empty, damaged or
## refused (the reason is in `last_error`).
static func read(slot: int) -> Dictionary:
	last_error = ""
	var file: String = _file(slot)
	if file.is_empty():
		return {}
	var all: String = FileAccess.get_file_as_string(file)
	var nl: int = all.find("\n")
	var head: String = (all.substr(0, nl) if nl >= 0 else all).strip_edges()
	var body: String = all.substr(nl + 1) if nl >= 0 else ""
	if not head.begins_with(MAGIC):
		return _refuse(file, "not a save file")
	var parts: PackedStringArray = head.substr(MAGIC.length()).strip_edges().split("|")
	var version: int = int(parts[0]) if parts[0].is_valid_int() else -1
	if parts.size() > 3 and not parts[3].is_empty() and parts[3] != _game():
		return _refuse(file, "this is a %s save" % ("Future Shock" if parts[3] == "shock" else "SkyNET"))
	var v: Variant = null
	if version == VERSION:
		v = _from_json(body)
	elif version == VERSION_TEXT:
		v = _from_text(body)
	elif version > VERSION:
		return _refuse(file, "saved by a newer build (format %d, this one reads up to %d)" % [version, VERSION])
	else:
		return _refuse(file, "unknown save format '%s'" % parts[0])
	if not last_error.is_empty():
		return _refuse(file, last_error)
	if not (v is Dictionary) or not (v as Dictionary).has("map"):
		return _refuse(file, "unreadable body")
	return v

static func _refuse(file: String, why: String) -> Dictionary:
	last_error = why
	push_warning("[save] %s: %s" % [file, why])
	return {}

## Format 2. A type the file names that is not plain data (an Object, a
## script-typed container) comes back null instead of being built.
static func _from_json(body: String) -> Variant:
	var json := JSON.new()
	if json.parse(body) != OK:
		last_error = "damaged (line %d: %s)" % [json.get_error_line(), json.get_error_message()]
		return null
	return JSON.to_native(json.data, false)

## Format 1 (var_to_str). str_to_var instantiates `Object(...)` and loads
## `Resource("path")` (the ExtResource / SubResource forms too), so a body
## that names either is refused. The bare identifiers are checked: the
## parser allows blanks and comments between a name and its "(".
static func _from_text(body: String) -> Variant:
	for token in ["Object", "Resource"]:
		if body.contains(token):
			last_error = "old-format save names %s — refused, it could load code" % token
			return null
	return str_to_var(body)

## Menu label: "MAP.210 · 2026-08-30 21:14", or "" for an empty slot.
static func info(slot: int) -> String:
	var file: String = _file(slot)
	if file.is_empty():
		return ""
	var f := FileAccess.open(file, FileAccess.READ)
	if f == null:
		return ""
	var head: String = f.get_line().strip_edges()
	f.close()
	if not head.begins_with(MAGIC):
		return ""
	var parts := head.split("|")
	if parts.size() < 3:
		return "?"
	return "%s · %s" % [parts[1], parts[2]]

static func delete(slot: int) -> void:
	for p in [path(slot), _tmp_path(slot)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
