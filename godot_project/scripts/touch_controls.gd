## On-screen touch controls for Android.
##
## Left D-pad  = move  (forward / back / strafe left-right)
## Right D-pad = look  (turn up / down / left / right)
## Centre pair = rise / sink (fly camera vertical)
##
## Multi-touch is handled by manual finger tracking against button
## rectangles, so several buttons work at the same time (e.g. walk
## forward while turning) regardless of GUI touch routing. The overlay
## writes ui_move / ui_look / ui_vert onto the fly camera each frame.

extends Control

@export var button_size: float = 120.0
@export var margin: float = 40.0

var _cam: Node = null               # the player body (group "player")
var _rects: Dictionary = {}        # button id -> Rect2
var _fingers: Dictionary = {}      # finger index -> button id
var _mobile: bool = OS.has_feature("mobile")

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cam = get_tree().get_first_node_in_group("player")
	visible = OS.has_feature("mobile") or DisplayServer.is_touchscreen_available()
	resized.connect(_layout)
	_layout()

func _layout() -> void:
	_rects.clear()
	var s := button_size
	var w := size.x
	var h := size.y
	# Left move pad (cross, anchored bottom-left).
	var lx := margin + s * 1.5
	var ly := h - margin - s * 1.5
	_rects["mf"] = Rect2(lx - s * 0.5, ly - s * 1.5, s, s)
	_rects["mb"] = Rect2(lx - s * 0.5, ly + s * 0.5, s, s)
	_rects["ml"] = Rect2(lx - s * 1.5, ly - s * 0.5, s, s)
	_rects["mr"] = Rect2(lx + s * 0.5, ly - s * 0.5, s, s)
	# Right look pad (cross, anchored bottom-right).
	var rx := w - margin - s * 1.5
	var ry := h - margin - s * 1.5
	_rects["lu"] = Rect2(rx - s * 0.5, ry - s * 1.5, s, s)
	_rects["ld"] = Rect2(rx - s * 0.5, ry + s * 0.5, s, s)
	_rects["ll"] = Rect2(rx - s * 1.5, ry - s * 0.5, s, s)
	_rects["lr"] = Rect2(rx + s * 0.5, ry - s * 0.5, s, s)
	# Rise / sink (centre bottom, stacked).
	var cx := w * 0.5 - s * 0.5
	_rects["rise"] = Rect2(cx, h - margin - s * 2.0 - 16.0, s, s)
	_rects["sink"] = Rect2(cx, h - margin - s, s, s)
	# Fire button (above the look pad).
	_rects["fire"] = Rect2(rx - s * 0.5, ry - s * 3.0, s, s)
	queue_redraw()

func _hit(pos: Vector2) -> String:
	for id in _rects:
		if (_rects[id] as Rect2).has_point(pos):
			return id
	return ""

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			var id := _hit(event.position)
			if id != "":
				_fingers[event.index] = id
		else:
			_fingers.erase(event.index)
		queue_redraw()
	elif event is InputEventScreenDrag:
		if _fingers.has(event.index):
			var id := _hit(event.position)
			if id == "":
				_fingers.erase(event.index)
			else:
				_fingers[event.index] = id
			queue_redraw()
	# Mouse fallback so the overlay can be tested on the desktop. Skipped
	# on mobile, where touch may also synthesize mouse events.
	elif _mobile:
		return
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var id := _hit(event.position)
			if id != "":
				_fingers[-1] = id
		else:
			_fingers.erase(-1)
		queue_redraw()
	elif event is InputEventMouseMotion and _fingers.has(-1):
		var id := _hit(event.position)
		if id == "":
			_fingers.erase(-1)
		else:
			_fingers[-1] = id
		queue_redraw()

## The buttons held right now. One dictionary, refilled: _process asks
## every frame, and a new one each time was garbage for nothing.
var _held_buf: Dictionary = {}

func _held() -> Dictionary:
	_held_buf.clear()
	for f in _fingers:
		_held_buf[_fingers[f]] = true
	return _held_buf

func _process(_delta: float) -> void:
	if not visible:
		return
	if _cam == null:
		_cam = get_tree().get_first_node_in_group("player")
		if _cam == null:
			return
	var h := _held()
	var mv := Vector2.ZERO
	if h.has("mf"): mv.y += 1.0
	if h.has("mb"): mv.y -= 1.0
	if h.has("mr"): mv.x += 1.0
	if h.has("ml"): mv.x -= 1.0
	var lk := Vector2.ZERO
	if h.has("lu"): lk.y -= 1.0
	if h.has("ld"): lk.y += 1.0
	if h.has("ll"): lk.x -= 1.0
	if h.has("lr"): lk.x += 1.0
	var v := 0.0
	if h.has("rise"): v += 1.0
	if h.has("sink"): v -= 1.0
	_cam.set("ui_move", mv)
	_cam.set("ui_look", lk)
	_cam.set("ui_vert", v)
	# Hold FIRE to auto-shoot (the player's fire cooldown rate-limits it).
	if h.has("fire"):
		_cam.set("ui_fire", true)

func _draw() -> void:
	var h := _held()
	for id in _rects:
		var r: Rect2 = _rects[id]
		var on: bool = h.has(id)
		if id == "fire":
			# Distinct red fire button with a filled dot.
			draw_rect(r, Color(0.28, 0.06, 0.06, 0.9 if on else 0.6), true)
			draw_rect(r, Color(1.0, 0.4, 0.35, 0.7), false, 2.0)
			draw_circle(r.position + r.size * 0.5, r.size.x * 0.22,
				Color(1.0, 0.5, 0.4, 1.0 if on else 0.82))
			continue
		draw_rect(r, Color(0.08, 0.09, 0.12, 0.85 if on else 0.5), true)
		draw_rect(r, Color(0.85, 0.9, 1.0, 0.55), false, 2.0)
		_draw_arrow(id, r, Color(1, 1, 1, 1.0 if on else 0.78))

func _draw_arrow(id: String, r: Rect2, col: Color) -> void:
	var c := r.position + r.size * 0.5
	var k := r.size.x * 0.24
	var pts := PackedVector2Array()
	match id:
		"mf", "lu", "rise":
			pts = PackedVector2Array([c + Vector2(0, -k), c + Vector2(-k, k), c + Vector2(k, k)])
		"mb", "ld", "sink":
			pts = PackedVector2Array([c + Vector2(0, k), c + Vector2(-k, -k), c + Vector2(k, -k)])
		"ml", "ll":
			pts = PackedVector2Array([c + Vector2(-k, 0), c + Vector2(k, -k), c + Vector2(k, k)])
		"mr", "lr":
			pts = PackedVector2Array([c + Vector2(k, 0), c + Vector2(-k, -k), c + Vector2(-k, k)])
	if pts.size() == 3:
		draw_colored_polygon(pts, col)
