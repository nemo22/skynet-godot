## Aiming crosshair drawn at the screen centre.

extends Control

var _centre: Vector2 = Vector2.ZERO
var _player: Node = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	_centre = size * 0.5

## In the jeep the crosshair is the turret's aim, moved by the mouse
## independently of the car (DOS); on foot / in the HK it is centred.
func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	var c: Vector2 = size * 0.5
	if _player != null and _player.has_method("aim_screen_pos"):
		c = _player.call("aim_screen_pos")
	if c.distance_to(_centre) > 0.5:
		_centre = c
		queue_redraw()

func _draw() -> void:
	var c := _centre if _centre != Vector2.ZERO else size * 0.5
	var col := Color(0.55, 1.0, 0.65, 0.85)
	var shadow := Color(0.0, 0.0, 0.0, 0.6)
	var gap := 7.0
	var ln := 15.0
	var dirs: Array[Vector2] = [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]
	for d in dirs:
		var a: Vector2 = c + d * gap
		var b: Vector2 = c + d * (gap + ln)
		draw_line(a + Vector2.ONE, b + Vector2.ONE, shadow, 3.0)
		draw_line(a, b, col, 2.0)
	draw_circle(c, 1.6, col)
