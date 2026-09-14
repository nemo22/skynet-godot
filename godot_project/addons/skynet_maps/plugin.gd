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
const ExportFilter := preload("res://addons/skynet_maps/export_filter.gd")

## The converted-asset cache. A development checkout keeps it inside the
## project (SkynetPaths.converted_dir_for), so the scenes built there
## reference res:// paths and open in the editor directly.
const CACHE := "res://converted"

const KINDS := ["Mesh (name from map table)", "Sprite (bank,record)", "Enemy (type id)", "Marker (type id)", "Light (intensity)"]

var _dock: VBoxContainer
var _maps: OptionButton
var _log: RichTextLabel
var _kind: OptionButton
var _param: LineEdit
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
	_dock.add_child(_button("Open map DATA — every MAP record, editable", _open))
	_dock.add_child(_button("Open baked LEVEL — geometry + behaviour", _open_level))
	_dock.add_child(_button("Export edited scene → mods/maps/", _export))
	_dock.add_child(_button("Rebuild scene from MAP", _rebuild))
	_dock.add_child(_button("Play map", _play))
	_dock.add_child(_button("Import / convert game data", _import))
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
	var have: Dictionary = {}
	var d := DirAccess.open(CACHE + "/maps")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".scn"):
				have[f.get_basename()] = true
	for n in names:
		_maps.add_item(("%s  ✓" % n) if have.has(n) else n)
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

## Build the map's data scene, then call `then(scene_path)`.
func _build_scene(m: String, then: Callable) -> void:
	var scn := "%s/maps/%s.scn" % [CACHE, m]
	_run_game("building %s scene …" % m, ["--map-scene=%s" % m], func(code: int, output: String) -> void:
		if code != 0 or not FileAccess.file_exists(scn):
			_say("build failed (%d): %s" % [code, output.right(600)])
			return
		_fill_maps()
		then.call(scn))

func _open() -> void:
	var m := _selected()
	if m.is_empty():
		return
	var scn := "%s/maps/%s.scn" % [CACHE, m]
	if FileAccess.file_exists(scn):
		_open_scene(scn)
	else:
		_build_scene(m, _open_scene)

func _open_scene(scn: String) -> void:
	EditorInterface.open_scene_from_path(scn)
	_say("opened %s" % scn)

## The baked LEVEL scene — the world itself in Godot format (terrain,
## static geometry with its collision and the occluders). Built by the
## conversion; this bakes it on demand
## the same way _build_scene does for the data view.
##
## The data view (Open map) is what you EDIT — move an entity there and
## export it to mods/maps/. The level scene is a build artefact: it is
## rebuilt whenever the MAP it came from changes. To add scenery by hand
## and keep it, put it in mods/maps/<MAP>.detail.tscn, which the game
## instantiates on top of every level.
func _open_level() -> void:
	var m := _selected()
	if m.is_empty():
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
			node.set("mesh", _res("%s/mesh/%s.res" % [CACHE, nm]))
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
			var tex := _res("%s/tex/T%03d_%03d_A.res" % [CACHE, bank, ri])
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
			node.set("mesh", _res("%s/mesh/%s.res" % [CACHE, String(AIData.TYPES[t]["n"]).to_upper()]))
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

func _rebuild() -> void:
	var m := _selected()
	if m.is_empty() or _busy():
		return
	var scn := "%s/maps/%s.scn" % [CACHE, m]
	if FileAccess.file_exists(scn):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(scn))
	_build_scene(m, func(path: String) -> void:
		EditorInterface.reload_scene_from_path(path)
		_say("rebuilt %s" % path))

## The game itself, as its own process (not the editor's Play: that would
## need the map on the project's main run arguments).
func _play() -> void:
	var m := _selected()
	if m.is_empty() or _busy():
		return
	_play_pid = OS.create_process(OS.get_executable_path(), _godot_args(["--", "--map=%s" % m]))
	_say("playing %s (pid %d)" % [m, _play_pid])
