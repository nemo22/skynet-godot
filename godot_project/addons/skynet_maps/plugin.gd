## Editor dock for the SkyNET map tools: open a converted map scene,
## export the edited scene back to a MAP file (mods/maps/), rebuild a
## scene from its MAP, and play a map in the game.

@tool
extends EditorPlugin

const MapWriter := preload("res://scripts/editor/map_writer.gd")

var _dock: VBoxContainer
var _maps: OptionButton
var _log: RichTextLabel

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
	_dock.add_child(_button("Open scene", _open))
	_dock.add_child(_button("Export edited scene → mods/maps/", _export))
	_dock.add_child(_button("Rebuild scene from MAP (headless)", _rebuild))
	_dock.add_child(_button("Play map", _play))
	_log = RichTextLabel.new()
	_log.custom_minimum_size = Vector2(0, 160)
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_dock.add_child(_log)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_fill_maps()

func _exit_tree() -> void:
	remove_control_from_docks(_dock)
	_dock.queue_free()

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b

func _say(msg: String) -> void:
	_log.append_text(msg + "\n")
	print("[skynet-maps] " + msg)

func _fill_maps() -> void:
	_maps.clear()
	var d := DirAccess.open("res://converted/maps")
	if d == null:
		_say("no converted/maps — run the game once with -- --import")
		return
	var names: Array = []
	for f in d.get_files():
		if f.ends_with(".scn"):
			names.append(f.get_basename())
	names.sort()
	for n in names:
		_maps.add_item(n)

func _selected() -> String:
	return _maps.get_item_text(_maps.selected) if _maps.selected >= 0 else ""

func _open() -> void:
	var m := _selected()
	if m.is_empty():
		return
	EditorInterface.open_scene_from_path("res://converted/maps/%s.scn" % m)
	_say("opened %s" % m)

func _export() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.get("raw") == null:
		_say("the edited scene is not a SkyNET map scene")
		return
	var log: Array = []
	var ok := MapWriter.export_map(root, "", log)
	for l in log:
		_say(String(l))
	if ok:
		EditorInterface.mark_scene_as_unsaved()
		_say("save the scene (Ctrl+S) to keep the updated raw data")

func _godot_args(extra: Array) -> PackedStringArray:
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(PackedStringArray(extra))
	return args

func _rebuild() -> void:
	var m := _selected()
	if m.is_empty():
		return
	var scn := "res://converted/maps/%s.scn" % m
	DirAccess.remove_absolute(scn)
	var pid := OS.create_process(OS.get_executable_path(),
		_godot_args(["--headless", "--", "--map-scene=%s" % m]))
	_say("rebuilding %s (pid %d) — reopen the scene when it finishes" % [m, pid])

func _play() -> void:
	var m := _selected()
	if m.is_empty():
		return
	var pid := OS.create_process(OS.get_executable_path(), _godot_args(["--", "--map=%s" % m]))
	_say("playing %s (pid %d)" % [m, pid])
