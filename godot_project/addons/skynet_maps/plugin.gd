## Editor dock for the SkyNET map tools: open a converted map scene,
## export the edited scene back to a MAP file (mods/maps/), rebuild a
## scene from its MAP, and play a map in the game.

@tool
extends EditorPlugin

const MapWriter := preload("res://scripts/editor/map_writer.gd")
const MapMesh := preload("res://scripts/editor/map_mesh.gd")
const MapSprite := preload("res://scripts/editor/map_sprite.gd")
const MapMarker := preload("res://scripts/editor/map_marker.gd")
const MapEntityRec := preload("res://scripts/editor/map_entity_rec.gd")
const AIData := preload("res://scripts/enemy_ai_data.gd")
const Paths := preload("res://scripts/skynet_paths.gd")

## The converted-asset cache (next to the game data — see SkynetPaths).
static func _cache() -> String:
	return Paths.converted_dir_for(Paths.locate_gamedata())

const KINDS := ["Mesh (name from map table)", "Sprite (bank,record)", "Enemy (type id)", "Marker (type id)", "Light (intensity)"]

var _dock: VBoxContainer
var _maps: OptionButton
var _log: RichTextLabel
var _kind: OptionButton
var _param: LineEdit

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
	_dock.add_child(HSeparator.new())
	_kind = OptionButton.new()
	for k in KINDS:
		_kind.add_item(k)
	_dock.add_child(_kind)
	_param = LineEdit.new()
	_param.placeholder_text = "BIGDOOR | 200,3 | 33 | 100 | 500"
	_dock.add_child(_param)
	_dock.add_child(_button("Add at editor camera", _add))
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
	var d := DirAccess.open(_cache() + "/maps")
	if d == null:
		_say("no %s/maps — run the game once with -- --import" % _cache())
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
	EditorInterface.open_scene_from_path("%s/maps/%s.scn" % [_cache(), m])
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

## Create a new entity node in the edited map scene. The writer turns
## nodes with file_off = -1 into fresh blocks on export.
func _add() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.get("raw") == null:
		_say("open a SkyNET map scene first")
		return
	var cam: Camera3D = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	var pos: Vector3 = cam.global_position - cam.global_transform.basis.z * 400.0
	var p: String = _param.text.strip_edges()
	var rec: Resource = MapEntityRec.new()
	rec.file_off = -1
	var node: Node3D = null
	var group := ""
	match _kind.selected:
		0:
			var nm := p.to_upper()
			if not (root.get("names") as PackedStringArray).has(nm):
				_say("'%s' is not in this map's name table" % nm)
				return
			node = MapMesh.new()
			rec.variant = 1
			rec.flags = 1
			rec.mesh_name = nm
			node.set("mesh", _res("%s/mesh/%s.res" % [_cache(), nm]))
			group = "Entities"
		1:
			var parts := p.split(",")
			if parts.size() != 2:
				_say("sprite needs bank,record")
				return
			var bank := int(parts[0])
			var ri := int(parts[1])
			node = MapSprite.new()
			rec.variant = 3
			rec.flags = 3
			rec.sprite_index = (bank << 7) | (ri & 0x7F)
			var tex := _res("%s/tex/T%03d_%03d_A.res" % [_cache(), bank, ri])
			if tex != null:
				node.set("texture", tex)
			node.set("pixel_size", 2.0)
			node.set("billboard", BaseMaterial3D.BILLBOARD_FIXED_Y)
			node.set("shaded", false)
			group = "Sprites"
		2:
			var t := int(p)
			if t < 0 or t >= AIData.TYPES.size():
				_say("enemy type 0..%d" % (AIData.TYPES.size() - 1))
				return
			node = MapMesh.new()
			rec.variant = 3
			rec.flags = 3
			rec.marker_type = 2
			rec.enemy_type = t
			rec.sprite_index = (299 << 7) | 2
			node.set("mesh", _res("%s/mesh/%s.res" % [_cache(), String(AIData.TYPES[t]["n"]).to_upper()]))
			group = "Enemies"
		3:
			var t := int(p)
			node = MapMarker.new()
			rec.variant = 3
			rec.flags = 3
			rec.marker_type = t
			rec.sprite_index = (299 << 7) | (t & 0x7F)
			node.call("setup_gizmo", "M%d" % t, Color(1.0, 0.2, 0.9), {})
			group = "Markers"
		4:
			node = MapMarker.new()
			rec.variant = 2
			rec.flags = 2
			rec.light_intensity = maxi(int(p), 1)
			rec.light_enable = 1
			node.call("setup_gizmo", "L%d" % rec.light_intensity, Color(1.0, 0.9, 0.3), {})
			group = "Markers"
	var parent := root.get_node_or_null(group)
	if parent == null:
		_say("scene has no %s group" % group)
		return
	node.set("rec", rec)
	node.name = "NEW_%s_%d" % [group.to_upper(), Time.get_ticks_msec() % 100000]
	parent.add_child(node)
	node.position = pos
	_own(node, root)
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	EditorInterface.mark_scene_as_unsaved()
	_say("added %s at %s — export writes it as a new block" % [node.name, pos])

static func _own(n: Node, owner: Node) -> void:
	n.owner = owner
	for c in n.get_children():
		_own(c, owner)

static func _res(path: String) -> Resource:
	return ResourceLoader.load(path) if ResourceLoader.exists(path) else null

func _godot_args(extra: Array) -> PackedStringArray:
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(PackedStringArray(extra))
	return args

func _rebuild() -> void:
	var m := _selected()
	if m.is_empty():
		return
	var scn := "%s/maps/%s.scn" % [_cache(), m]
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
