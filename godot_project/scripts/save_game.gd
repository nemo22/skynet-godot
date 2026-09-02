## Save-game slots (docs/implementation_plan.md §N.4).
##
## One file per slot under user://saves/. The first line is a short
## header the LOAD menu can show without parsing the body:
##   SKYNET-SAVE <version>|<map>|<yyyy-mm-dd hh:mm>
## The rest is `var_to_str` of the session dictionary built by
## main.save_to_slot — Dictionaries with int keys and Vector2i values
## survive the round trip (JSON would not).
## Used via `const SaveGame := preload("res://scripts/save_game.gd")`
## (headless runs do not see class_name registrations).

const DIR := "user://saves"
const SLOTS: int = 10
## F6 / F7 use slot 0 — shown as the first LOAD.IMG bar.
const QUICK_SLOT: int = 0
const VERSION: int = 1
const MAGIC := "SKYNET-SAVE"

static func path(slot: int) -> String:
	return "%s/slot_%02d.save" % [DIR, slot]

static func exists(slot: int) -> bool:
	return FileAccess.file_exists(path(slot))

## Write `data` (must carry "map") to `slot`. Returns false on failure.
static func write(slot: int, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(path(slot), FileAccess.WRITE)
	if f == null:
		push_error("[save] cannot write %s (%s)" % [path(slot), error_string(FileAccess.get_open_error())])
		return false
	var stamp: String = Time.get_datetime_string_from_system(false, true).left(16)
	f.store_line("%s %d|%s|%s" % [MAGIC, VERSION, String(data.get("map", "")), stamp])
	f.store_string(var_to_str(data))
	f.close()
	return true

## The saved session dictionary, or {} when the slot is empty/corrupt.
static func read(slot: int) -> Dictionary:
	var f := FileAccess.open(path(slot), FileAccess.READ)
	if f == null:
		return {}
	# get_as_text() always reads from offset 0 — split the header off.
	var all: String = f.get_as_text()
	f.close()
	var nl: int = all.find("\n")
	var head: String = all.substr(0, nl) if nl >= 0 else all
	var body: String = all.substr(nl + 1) if nl >= 0 else ""
	if not head.begins_with(MAGIC):
		push_warning("[save] %s is not a save file" % path(slot))
		return {}
	var v = str_to_var(body)
	if not (v is Dictionary) or not (v as Dictionary).has("map"):
		push_warning("[save] %s: unreadable body" % path(slot))
		return {}
	return v

## Menu label: "MAP.210 · 2026-08-30 21:14", or "" for an empty slot.
static func info(slot: int) -> String:
	var f := FileAccess.open(path(slot), FileAccess.READ)
	if f == null:
		return ""
	var head: String = f.get_line()
	f.close()
	if not head.begins_with(MAGIC):
		return ""
	var parts := head.split("|")
	if parts.size() < 3:
		return "?"
	return "%s · %s" % [parts[1], parts[2]]

static func delete(slot: int) -> void:
	if exists(slot):
		DirAccess.remove_absolute(path(slot))
