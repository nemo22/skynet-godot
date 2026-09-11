## The HUMAN class's MOTION DETECTOR (DOS weapon record 13): while the
## hand-held scanner is the weapon in hand, every other player moving
## nearby is marked over the 3D view.
##
## DOS FUN_00132b00 (v1.01), which runs only in a network game and only
## while the scanner view is on: it walks the actor list, takes the 3D
## distance to each actor (FUN_0014d775) and marks the ones between 0x31
## and 0x9c5 units — 49 to 2501 — whose projected point falls inside the
## viewport, in palette colour 0xb8. The mark itself (0x132c6a) is a
## glyph offset a few pixels from the point, twice as far in hi-res.
## Actors carrying the "named" flag get their name drawn instead.
##
## Drawn over the 3D view, under the HUD panel — the same place the
## TERMINATOR's machine vision sits (net/terminator_vision.gd).
extends Control

## DOS 0x31 .. 0x9c5: inside 49 units nothing is marked (that is you),
## past 2501 the scanner does not reach.
const NEAR: float = 49.0
const FAR: float = 2501.0

var game: Node = null                  # dm_game.gd (avatars, font)
var player: Node3D = null              # the local player (fly_camera.gd)
var _font: Font = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_font(f: Font) -> void:
	_font = f

func _process(_delta: float) -> void:
	# The scanner only reads while it is the weapon in hand.
	var on: bool = player != null and is_instance_valid(player) \
		and player.has_method("detector_active") and bool(player.call("detector_active"))
	if on != visible:
		visible = on
	if visible:
		queue_redraw()

func _draw() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or game == null:
		return
	var f: Font = _font if _font != null else ThemeDB.fallback_font
	var avatars: Dictionary = game.get("_avatars")
	var sz: Vector2 = size
	for id in avatars:
		var av = avatars[id]
		if av == null or not is_instance_valid(av) or not bool(av.get("alive")) \
				or not Net.is_alive(int(id)):
			continue
		var wpos: Vector3 = (av as Node3D).global_position + Vector3(0.0, 50.0, 0.0)
		if cam.is_position_behind(wpos):
			continue
		var dist: float = cam.global_position.distance_to(wpos)
		if dist < NEAR or dist > FAR:
			continue
		var sp: Vector2 = cam.unproject_position(wpos)
		if sp.x < 0.0 or sp.y < 0.0 or sp.x > sz.x or sp.y > sz.y:
			continue                       # DOS clips to the viewport rect
		# The scanner's own green, brightest close up.
		var a: float = clampf(1.0 - (dist - NEAR) / (FAR - NEAR), 0.25, 1.0)
		var c := Color(0.35, 1.0, 0.45, a)
		var half: float = clampf(2200.0 / maxf(dist, 1.0), 5.0, 22.0)
		draw_line(sp + Vector2(-half, 0.0), sp + Vector2(half, 0.0), c, 2.0)
		draw_line(sp + Vector2(0.0, -half), sp + Vector2(0.0, half), c, 2.0)
		draw_arc(sp, half * 1.6, 0.0, TAU, 18, c, 1.0)
		draw_string(f, sp + Vector2(half * 1.6 + 5.0, 5.0),
			"%dM" % int(dist / 32.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, c)
