## Aiming crosshair at the view's centre (in the jeep the camera is the
## turret, so the aim is always there). That centre is DOS's: the middle
## of the 3D view ABOVE the HUD bar, (160, 80) of the 320x200 screen, not
## the middle of the window — the player's camera projects round it
## (fly_camera.aim_screen_point / _update_projection) and every shot is
## aimed through it (playtest 2026-09-15).
##
## On foot: a small green cross — the DOS one is a few pixels, and the
## port's first was three times that ("zameriavaci kriz je prilis velky",
## 2026-09-04). In a vehicle: the DOS reticle CROSHAIR.IMG, the dashed
## circle in the DOS jeep screenshots (2026-09-11). Skynet.exe's aim
## table (0x443ca) names mdmaim.img on foot and croshair.img for the jeep
## and the HK. Its pixels are palette colours; it is drawn as a mask in the
## DOS green, scaled from the 200-line screen to this one — or, when
## MDMDHRES.BSA has it, the 640x480 version (120x120 against 71x59: the
## 320x200 one is squashed for that mode's tall pixels) scaled from 480
## lines, which is sharp instead of a blocky blow-up (playtest, 2026-09-11).

extends Control

const VEH_RETICLE: String = "CROSHAIR.IMG"
const GREEN := Color(0.40, 0.95, 0.45, 0.9)

var _player: Node = null
var _veh: int = -1
var _reticle: Texture2D = null
var _reticle_tried: bool = false
var _reticle_unit: float = 200.0       # screen lines the reticle's art is drawn for
var _pt: Vector2 = Vector2(-1.0, -1.0) # where the reticle was last drawn

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(queue_redraw)

func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	var v: int = int(_player.get("vehicle")) if _player != null else 0
	# A scripted view (the torpedo ride) draws no reticle.
	visible = _player == null or _player.get("ride_view") != true
	if v != _veh:
		_veh = v
		queue_redraw()
	var pt: Vector2 = _aim_point()
	if pt != _pt:
		_pt = pt
		queue_redraw()

## The projection centre in this control's pixels (it fills the viewport);
## the window's middle when there is no player to ask.
func _aim_point() -> Vector2:
	if _player != null and is_instance_valid(_player) and _player.has_method("aim_screen_point"):
		return _player.call("aim_screen_point")
	return size * 0.5

## CROSHAIR.IMG as a white mask, loaded once.
func _vehicle_reticle() -> Texture2D:
	if _reticle_tried:
		return _reticle
	_reticle_tried = true
	var main = get_tree().current_scene
	if main == null or not main.has_method("_load_panel_texture"):
		return null
	var tex: Texture2D = main.call("_load_panel_texture", VEH_RETICLE, true, true)
	if tex == null:
		return null
	_reticle_unit = 480.0 if tex.get_width() >= 100 else 200.0
	var img: Image = tex.get_image()
	if img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			img.set_pixel(x, y, Color(1, 1, 1, img.get_pixel(x, y).a))
	_reticle = ImageTexture.create_from_image(img)
	return _reticle

func _draw() -> void:
	var c: Vector2 = _aim_point()
	if _veh > 0:
		var tex := _vehicle_reticle()
		if tex != null:
			var sz: Vector2 = tex.get_size() * (size.y / _reticle_unit)
			draw_texture_rect(tex, Rect2(c - sz * 0.5, sz), false, GREEN)
			return
	var col := Color(0.55, 1.0, 0.65, 0.85)
	var shadow := Color(0.0, 0.0, 0.0, 0.6)
	var gap := 4.0
	var ln := 8.0
	var dirs: Array[Vector2] = [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]
	for d in dirs:
		var a: Vector2 = c + d * gap
		var b: Vector2 = c + d * (gap + ln)
		draw_line(a + Vector2.ONE, b + Vector2.ONE, shadow, 2.0)
		draw_line(a, b, col, 1.0)
	draw_circle(c, 1.0, col)
