## The AUTOMAP (DOS FUN_0013d400, key AUTOMAP — Tab by default).
##
## It is not a 2D map: the original re-renders the real 3D world from a
## camera orbiting above and behind the player, over a flat graticule
## backdrop, with an arrow model marking where the player stands and
## which way they face. The game is paused while it is open.
##
## What the DOS gather routine (FUN_0013db00) puts in the scene, and
## this reproduces:
##   * placed .3D meshes only — no enemies, no pickups, no sprites, no
##     lights (the gameplay gather takes variants 1/2/3, the map one
##     takes variant 1);
##   * only meshes within 5x5 map cells of the player (a cell is 1024
##     world units, so +/- 2560);
##   * only meshes already SEEN — DOS sets flag 0x80 on every entity it
##     actually drew during play, and the "Automap cleaered." cheat
##     clears them all again. main.gd marks them the same way.
##   * the terrain, on outdoor maps only.
## Fog and the draw-distance limit are switched off (FUN_0014a13c(-1)).
##
## Screen: MAPBAR1.IMG (320x17 top, seven buttons), MAPGRID.IMG (320x166
## backdrop at y=17), MAPBAR2.IMG (320x17 at y=183).

extends Node3D

const ImgFile := preload("res://scripts/loaders/img_file.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const Palette := preload("res://scripts/loaders/palette.gd")
const PauseState := preload("res://scripts/pause_state.gd")

## A map cell (FUN_001364ac shifts the world coordinate right by 10).
const CELL: float = 1024.0
## The DOS gather window is 5x5 cells around the player.
const RANGE: float = CELL * 2.5

## DOS: zoom 0x100..0x300 (256..768), tilt 0x80..0x180 (22.5..67.5 deg),
## start tilt 0xC0 = 33.75 deg. The port keeps the tilt and the 1:3 zoom
## span but opens the zoom out to something a modern screen can read.
const ZOOM_MIN: float = 1600.0
const ZOOM_MAX: float = 4800.0
const ZOOM_DEFAULT: float = 2600.0
const TILT_MIN: float = 22.5
const TILT_MAX: float = 67.5
const TILT_DEFAULT: float = 33.75
const ROT_RATE: float = 1.4          # rad/s while a rotate button is held
const TILT_RATE: float = 45.0        # deg/s
const ZOOM_RATE: float = 2200.0      # units/s
## World size of the player marker on the map.
const ARROW_SIZE: float = 320.0

## Top-bar buttons, in image pixels (the DOS hit table at 0x5EFCA).
const BAR_RECTS: Array = [
	Rect2(0, 0, 47, 17), Rect2(47, 0, 46, 17),      # rotate + / -
	Rect2(93, 0, 46, 17), Rect2(139, 0, 46, 17),    # tilt + / -
	Rect2(185, 0, 46, 17), Rect2(231, 0, 46, 17),   # zoom in / out
	Rect2(277, 0, 43, 17),                          # exit
]

var _cam: Camera3D = null
var _arrow: MeshInstance3D = null
var _layer: CanvasLayer = null
var _main: Node = null
var _player: Node3D = null
var _level = null
var _prev_cam: Camera3D = null
var _hidden: Array = []              # nodes hidden while the map is open
var _zoom: float = ZOOM_DEFAULT
var _tilt: float = TILT_DEFAULT
var _rot: float = 0.0
var _held: int = -1                  # bar button under a held mouse press
var _grid_tex: ImageTexture = null   # MAPGRID.IMG, hung behind the world
var _grid: MeshInstance3D = null
var _env_saved: Dictionary = {}
var _hidden_layers: Array = []       # HUD layers hidden while the map is up
var open: bool = false

signal closed()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

## Build the overlay and take over the view. `level` is the LevelLoader
## level, `seen` the set of discovered entity node ids.
func show_map(main: Node, level, player: Node3D, seen: Dictionary) -> void:
	if open:
		return
	_main = main
	_level = level
	_player = player
	open = true
	_build_bars()
	_build_camera()
	_build_grid()
	_build_arrow()
	_apply_visibility(seen)
	_flatten_environment()
	# The gameplay HUD (and the cockpit panel) give way to the map's own
	# bars, as they do in DOS.
	for key in ["_hud_layer", "_veh_layer"]:
		var l = _main.get(key)
		if l is CanvasLayer and (l as CanvasLayer).visible:
			(l as CanvasLayer).visible = false
			_hidden_layers.append(l)
	# ... and so does the weapon in the player's hands.
	if _player != null:
		var vm = _player.get("_vm_layer")
		if vm is CanvasLayer and (vm as CanvasLayer).visible:
			(vm as CanvasLayer).visible = false
			_hidden_layers.append(vm)
	PauseState.push(&"automap")

func close_map() -> void:
	if not open:
		return
	open = false
	for n in _hidden:
		if is_instance_valid(n):
			n.visible = true
	_hidden.clear()
	if _prev_cam != null and is_instance_valid(_prev_cam):
		_prev_cam.current = true
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	if _cam != null and is_instance_valid(_cam):
		_cam.queue_free()
	_cam = null
	if _arrow != null and is_instance_valid(_arrow):
		_arrow.queue_free()
	_arrow = null
	if _grid != null and is_instance_valid(_grid):
		_grid.queue_free()
	_grid = null
	_restore_environment()
	for l in _hidden_layers:
		if is_instance_valid(l):
			l.visible = true
	_hidden_layers.clear()
	PauseState.pop(&"automap")
	closed.emit()

# --- build -------------------------------------------------------------
func _img(nm: String, imgs: BSAReader, pal: PackedColorArray) -> ImageTexture:
	var b := imgs.read(nm)
	return ImgFile.parse(b, pal) if not b.is_empty() else null

func _build_bars() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 60
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)
	var imgs := BSAReader.new()
	var top: ImageTexture = null
	var grid: ImageTexture = null
	var bottom: ImageTexture = null
	_grid_tex = null
	if imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
		var pal := Palette.parse(SkynetPaths.palette_bytes())
		top = _img("MAPBAR1.IMG", imgs, pal)
		grid = _img("MAPGRID.IMG", imgs, pal)
		bottom = _img("MAPBAR2.IMG", imgs, pal)
		imgs.close()
	# The 320x200 screen stretched full-bleed, like the rest of the UI.
	# MAPGRID is the BACKDROP, so it cannot live on a CanvasLayer (that
	# draws over the 3D view); it hangs on the camera behind the world.
	_grid_tex = grid
	_strip(bottom, 183.0, 17.0, Color(0.1, 0.12, 0.13))
	var bar := _strip(top, 0.0, 17.0, Color(0.1, 0.12, 0.13))
	# Seven buttons across the top bar.
	for i in BAR_RECTS.size():
		var r: Rect2 = BAR_RECTS[i]
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.modulate = Color(1, 1, 1, 0)
		b.anchor_left = r.position.x / 320.0
		b.anchor_right = (r.position.x + r.size.x) / 320.0
		b.anchor_top = 0.0
		b.anchor_bottom = 1.0
		var idx: int = i
		b.button_down.connect(func() -> void: _held = idx)
		b.button_up.connect(func() -> void: _held = -1)
		b.pressed.connect(func() -> void:
			if idx == 6:
				close_map())
		bar.add_child(b)

## One full-width strip of the 320x200 layout.
func _strip(tex: ImageTexture, y: float, h: float, fallback: Color) -> Control:
	var c := Control.new()
	c.anchor_left = 0.0
	c.anchor_right = 1.0
	c.anchor_top = y / 200.0
	c.anchor_bottom = (y + h) / 200.0
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if tex != null:
		var rect := TextureRect.new()
		rect.texture = tex
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(rect)
	else:
		var cr := ColorRect.new()
		cr.color = fallback
		cr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(cr)
	_layer.add_child(c)
	return c

func _build_camera() -> void:
	_prev_cam = get_viewport().get_camera_3d()
	_cam = Camera3D.new()
	_cam.fov = 75.0
	_cam.near = 20.0
	_cam.far = 200000.0
	add_child(_cam)
	_cam.current = true
	_place_camera()

func _build_arrow() -> void:
	_arrow = MeshInstance3D.new()
	var m: ArrayMesh = Assets.mesh("ARROW.3D")
	if m != null:
		_arrow.mesh = m
	else:
		var pm := PrismMesh.new()
		pm.size = Vector3(90.0, 30.0, 140.0)
		_arrow.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 1.0, 0.5)
	mat.no_depth_test = true
	_arrow.material_override = mat
	_arrow.sorting_offset = 200.0
	# ARROW.3D is authored small; scale it so the marker reads at map zoom.
	var aabb: AABB = _arrow.mesh.get_aabb()
	var big: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if big > 1.0:
		_arrow.scale = Vector3.ONE * (ARROW_SIZE / big)
	print("[automap] arrow mesh %s -> scale %.2f" % [aabb.size, _arrow.scale.x])
	add_child(_arrow)
	_update_arrow()

## MAPGRID.IMG on a quad parented to the camera, far enough back that
## every piece of the world draws in front of it.
func _build_grid() -> void:
	if _grid_tex == null or _cam == null:
		return
	var dist: float = 60000.0
	var qm := QuadMesh.new()
	var hh: float = 2.0 * dist * tan(deg_to_rad(_cam.fov * 0.5))
	var aspect: float = 16.0 / 9.0
	var vp := get_viewport()
	if vp != null and vp.get_visible_rect().size.y > 0.0:
		aspect = vp.get_visible_rect().size.x / vp.get_visible_rect().size.y
	qm.size = Vector2(hh * aspect, hh)
	_grid = MeshInstance3D.new()
	_grid.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _grid_tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.disable_receive_shadows = true
	mat.disable_ambient_light = true
	mat.no_depth_test = false
	_grid.material_override = mat
	_grid.position = Vector3(0.0, 0.0, -dist)
	_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cam.add_child(_grid)

## The map view has no sky and no haze (DOS turns the draw-distance limit
## off with FUN_0014a13c(-1)); put the environment back on close.
func _flatten_environment() -> void:
	var we: WorldEnvironment = _main.get_node_or_null("WorldEnvironment") if _main != null else null
	if we == null or we.environment == null:
		return
	var env: Environment = we.environment
	_env_saved = {
		"bg": env.background_mode, "color": env.background_color,
		"fog": env.fog_enabled, "vfog": env.volumetric_fog_enabled,
		"energy": env.background_energy_multiplier,
	}
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.background_energy_multiplier = 1.0
	env.fog_enabled = false
	env.volumetric_fog_enabled = false

func _restore_environment() -> void:
	if _env_saved.is_empty() or _main == null:
		return
	var we: WorldEnvironment = _main.get_node_or_null("WorldEnvironment")
	if we != null and we.environment != null:
		var env: Environment = we.environment
		env.background_mode = int(_env_saved["bg"]) as Environment.BGMode
		env.background_color = _env_saved["color"]
		env.background_energy_multiplier = float(_env_saved["energy"])
		env.fog_enabled = bool(_env_saved["fog"])
		env.volumetric_fog_enabled = bool(_env_saved["vfog"])
	_env_saved = {}

# --- what the map shows ------------------------------------------------
func _hide(n: Node) -> void:
	if n is Node3D and (n as Node3D).visible:
		(n as Node3D).visible = false
		_hidden.append(n)

func _apply_visibility(seen: Dictionary) -> void:
	if _level == null or _player == null:
		return
	var here: Vector3 = _player.global_position
	if _level.sky != null and is_instance_valid(_level.sky):
		_hide(_level.sky)
	if _level.sprites != null:
		for c in _level.sprites.get_children():
			_hide(c)
	for e in get_tree().get_nodes_in_group("enemy"):
		_hide(e)
	if _level.entities != null:
		for c in _level.entities.get_children():
			if not (c is Node3D):
				continue
			var n: Node3D = c
			var far: bool = absf(n.global_position.x - here.x) > RANGE \
				or absf(n.global_position.z - here.z) > RANGE
			if far or not seen.has(n.get_instance_id()):
				_hide(n)

# --- per-frame ---------------------------------------------------------
func _place_camera() -> void:
	if _cam == null or _player == null or not is_instance_valid(_player):
		return
	var here: Vector3 = _player.global_position
	var yaw: float = _player.rotation.y
	# DOS: offset = (-fwd.x, -1, -fwd.z) * zoom rotated by the map spin,
	# so the camera sits `zoom` above and the same behind the player.
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var off := Vector3(-fwd.x, 1.0, -fwd.z) * _zoom
	off = Basis(Vector3.UP, _rot) * off
	_cam.global_position = here + off
	_cam.rotation = Vector3(-deg_to_rad(_tilt), yaw - _rot, 0.0)

func _update_arrow() -> void:
	if _arrow == null or _player == null or not is_instance_valid(_player):
		return
	_arrow.global_position = _player.global_position + Vector3(0.0, 40.0, 0.0)
	_arrow.rotation = Vector3(0.0, _player.rotation.y, 0.0)

func _unhandled_input(event: InputEvent) -> void:
	if not open or not (event is InputEventKey and event.pressed and not event.echo):
		return
	if (event as InputEventKey).keycode == KEY_ESCAPE or Controls.matches(event, "automap"):
		close_map()
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not open:
		return
	# Held bar button, or the DOS keys: arrows spin and tilt, +/- zoom.
	var rot_in: float = 0.0
	var tilt_in: float = 0.0
	var zoom_in: float = 0.0
	if _held == 0 or Input.is_key_pressed(KEY_LEFT):  rot_in += 1.0
	if _held == 1 or Input.is_key_pressed(KEY_RIGHT): rot_in -= 1.0
	if _held == 2 or Input.is_key_pressed(KEY_UP):    tilt_in += 1.0
	if _held == 3 or Input.is_key_pressed(KEY_DOWN):  tilt_in -= 1.0
	if _held == 4 or Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_KP_ADD):
		zoom_in -= 1.0
	if _held == 5 or Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_KP_SUBTRACT):
		zoom_in += 1.0
	_rot = wrapf(_rot + rot_in * ROT_RATE * delta, -PI, PI)
	_tilt = clampf(_tilt + tilt_in * TILT_RATE * delta, TILT_MIN, TILT_MAX)
	_zoom = clampf(_zoom + zoom_in * ZOOM_RATE * delta, ZOOM_MIN, ZOOM_MAX)
	_place_camera()
	_update_arrow()
