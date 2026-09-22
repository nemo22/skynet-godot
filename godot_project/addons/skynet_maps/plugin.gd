## Editor dock for the SkyNET map tools: open the baked LEVEL scene of a
## map, convert the game data, and play a map in the game.
##
## SOURCE, DERIVED, MOD. The DOS MAP file is the source and nobody edits
## it — there is no way back from Godot into it and the port does not ask
## for one. converted/maps/MAP.NNN.level.scn is DERIVED from it and is
## rewritten by every import. To change a map, save your own copy of that
## scene as mods/maps/MAP.NNN.level.scn: the game takes it instead of the
## derived one (scripts/level_scene.gd). It changes what is presented and
## where — the triggers still come from the DOS records, so a node you
## add has no record behind it and can never fire.

@tool
extends EditorPlugin

const Paths := preload("res://scripts/skynet_paths.gd")
const ExportFilter := preload("res://addons/skynet_maps/export_filter.gd")

## The converted-asset cache. A development checkout keeps it inside the
## project (SkynetPaths.converted_dir_for), so the scenes built there
## reference res:// paths and open in the editor directly.
const CACHE := "res://converted"

## Where a map's own scene goes when it is modded — the same folder the
## GAME reads (SkynetPaths.mods_dir, res://mods in a checkout).
static func _mod_dir() -> String:
	return Paths.mods_dir() + "/maps"

var _dock: VBoxContainer
var _maps: OptionButton
var _log: RichTextLabel
var _export_filter: EditorExportPlugin

func _enter_tree() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "SkyNET Maps"
	var row := HBoxContainer.new()
	_maps = OptionButton.new()
	_maps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_maps)
	var refresh := Button.new()
	refresh.text = "↻"
	refresh.pressed.connect(_fill_maps)
	row.add_child(refresh)
	_dock.add_child(row)
	_dock.add_child(_button("Open LEVEL — the map as a Godot scene", _open_level))
	_dock.add_child(_button("Rebake LEVEL from the MAP", _rebuild))
	_dock.add_child(_button("Play map", _play))
	_dock.add_child(_button("Import / convert game data", _import))
	_log = RichTextLabel.new()
	_log.custom_minimum_size = Vector2(0, 160)
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_dock.add_child(_log)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_export_filter = ExportFilter.new()
	add_export_plugin(_export_filter)
	_fill_maps()

func _exit_tree() -> void:
	if _job != null:
		_job.wait_to_finish()
		_job = null
	remove_export_plugin(_export_filter)
	remove_control_from_docks(_dock)
	_dock.queue_free()

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b

func _say(msg: String) -> void:
	_log.add_text(msg + "\n")
	print("[skynet-maps] " + msg)

## Every MAP in MDMDMAP2.BSA (the ones with a built scene are marked).
func _fill_maps() -> void:
	_maps.clear()
	var names: Array = []
	var gd: String = Paths.locate_gamedata()
	if gd.is_empty():
		_say("original game data not found (SKYNET.EXE dir) — set it in the game's first-start dialog or --gamedata=")
		return
	var bsa = load("res://scripts/loaders/bsa_reader.gd").new()
	if bsa.open(gd + "/MDMDMAP2.BSA", 0):
		for e in bsa.entries():
			var nm: String = e.name.to_upper()
			if nm.begins_with("MAP."):
				names.append(nm)
		bsa.close()
	names.sort()
	# ✓ = a level scene is baked, MOD = the player's own scene wins over it.
	var have: Dictionary = {}
	var d := DirAccess.open(CACHE + "/maps")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".level.scn"):
				have[f.trim_suffix(".level.scn")] = true
	var modded: Dictionary = {}
	var md := DirAccess.open(_mod_dir())
	if md != null:
		for f in md.get_files():
			if f.ends_with(".level.scn"):
				modded[f.trim_suffix(".level.scn")] = true
	for n in names:
		var mark: String = "  MOD" if modded.has(n) else ("  ✓" if have.has(n) else "")
		_maps.add_item(n + mark)
	if names.is_empty():
		_say("no maps in %s/MDMDMAP2.BSA" % gd)

func _selected() -> String:
	if _maps.selected < 0:
		return ""
	return _maps.get_item_text(_maps.selected).split(" ")[0]

# --- headless game runs ------------------------------------------------
## Building a scene or converting the data runs the GAME, headless, in its
## own process: the loaders need the game's autoloads (SkynetPaths, Assets,
## Audio …), which do not exist in the editor, and a crash in a loader
## then cannot take the editor down. The process runs on a thread so the
## editor stays responsive; `done(code, output)` is called on the main
## thread afterwards. One run at a time, and not while a game started with
## Play map is still running — two processes writing the cache at once
## corrupt it.
var _job: Thread
var _play_pid: int = -1

func _busy() -> bool:
	if _job != null:
		_say("busy — wait for the running build to finish")
		return true
	if _play_pid > 0 and OS.is_process_running(_play_pid):
		_say("close the game started with Play map first (it writes the same cache)")
		return true
	return false

func _run_game(label: String, game_args: Array, done: Callable) -> void:
	if _busy():
		return
	_say(label)
	var args := _godot_args(["--headless", "--"] + game_args)
	_job = Thread.new()
	_job.start(func() -> void:
		var out: Array = []
		var code: int = OS.execute(OS.get_executable_path(), args, out, true)
		_run_done.call_deferred(code, "".join(out), done))

func _run_done(code: int, output: String, done: Callable) -> void:
	_job.wait_to_finish()
	_job = null
	EditorInterface.get_resource_filesystem().scan()
	done.call(code, output)

func _godot_args(extra: Array) -> PackedStringArray:
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(PackedStringArray(extra))
	return args

func _open_scene(scn: String) -> void:
	EditorInterface.open_scene_from_path(scn)
	_say("opened %s" % scn)

## The LEVEL scene — the world itself in Godot format (terrain, static
## geometry with its collision, the occluders and the behaviour branch).
##
## The MOD is opened when there is one: mods/maps/<MAP>.level.scn is the
## file the game plays, and it is the file to edit. Without one this
## opens the DERIVED scene, which every import rewrites — save it into
## mods/maps/ under the same name to make an edit of it stick. (To ADD to
## a level instead of replacing it, mods/maps/<MAP>.detail.tscn is
## instantiated on top of whichever level is playing.)
func _open_level() -> void:
	var m := _selected()
	if m.is_empty():
		return
	var mod: String = "%s/%s.level.scn" % [_mod_dir(), m]
	if FileAccess.file_exists(mod):
		_open_scene(mod)
		_say("this map is modded — the game plays this file, not the converted one")
		return
	var scn: String = "%s/maps/%s.level.scn" % [CACHE, m]
	if FileAccess.file_exists(scn):
		_open_scene(scn)
		return
	_run_game("baking %s level scene …" % m, ["--level-scene=%s" % m], func(code: int, output: String) -> void:
		if code != 0 or not FileAccess.file_exists(scn):
			_say("bake failed (%d): %s" % [code, output.right(600)])
			return
		_open_scene(scn))

func _import() -> void:
	_run_game("converting game data (a few minutes) …", ["--import"], func(code: int, _output: String) -> void:
		_say("import finished (%d)" % code)
		_fill_maps())

## Throw the derived level scene away and build it from the MAP again —
## after a change to the bake, which the cached scene knows nothing about.
## A mod is not touched: it is not ours to rebuild.
func _rebuild() -> void:
	var m := _selected()
	if m.is_empty() or _busy():
		return
	var scn := "%s/maps/%s.level.scn" % [CACHE, m]
	if FileAccess.file_exists(scn):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(scn))
	_run_game("baking %s level scene …" % m, ["--level-scene=%s" % m], func(code: int, output: String) -> void:
		if code != 0 or not FileAccess.file_exists(scn):
			_say("bake failed (%d): %s" % [code, output.right(600)])
			return
		_fill_maps()
		EditorInterface.reload_scene_from_path(scn)
		_say("rebuilt %s" % scn))

## The game itself, as its own process (not the editor's Play: that would
## need the map on the project's main run arguments).
func _play() -> void:
	var m := _selected()
	if m.is_empty() or _busy():
		return
	_play_pid = OS.create_process(OS.get_executable_path(), _godot_args(["--", "--map=%s" % m]))
	_say("playing %s (pid %d)" % [m, _play_pid])
