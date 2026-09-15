## The HUMAN class's MOTION DETECTOR (DOS weapon record 13): while the
## hand-held scanner is the weapon in hand, every other player nearby is
## marked over the 3D view.
##
## DOS FUN_00132600 (v1.00, skynet_gh.c:35565; 0x132b00 in v1.01) runs
## only in a network game and only while the scanner view is on. It walks
## the actor list, takes the 3D distance to each (FUN_0014d275) and marks
## the ones between 0x31 and 0x9c5 units — 49 to 2501, tens of metres —
## whose projected point falls inside the viewport, in palette colour
## 0xb8:
##   - a dot at the point (FUN_00011da0 → FUN_0013283e), flashing while it
##     sits in the middle of the view, under the crosshair;
##   - the player's name, STRINGS.PRS Trg_String = "#P", at (x+4, y-6);
##   - the distance, units / 0x28, then "M", at (x+4, y+2)
##     (FUN_0013276a);
##   - an actor flagged dead gets Ded_String = "#P TERMINATED" at
##     (x-0x30, y) instead.
## The offsets are 320x200 pixels; the port scales them to the view.
##
## Until 2026-09-14 the port drew a hairline cross that shrank with the
## range, so a player tens of metres away was a faint 10 px mark — in play
## the scanner looked as if it showed nobody.
##
## Drawn over the 3D view, under the HUD panel — the same place the
## TERMINATOR's machine vision sits (net/terminator_vision.gd).
extends Control

## DOS 0x31 .. 0x9c5: inside 49 units nothing is marked (that is you),
## past 2501 the scanner does not reach.
const NEAR: float = 49.0
const FAR: float = 2501.0
## World units per metre in the DOS read-out (0x28).
const UNITS_PER_M: float = 40.0
## Palette 0xb8 of SKYNET.COL, and 0xb4 (the same green, lit) for the
## flash under the crosshair.
const MARK := Color8(0x43, 0x8f, 0x43)
const MARK_LIT := Color8(0x37, 0xe7, 0x37)
const OUTLINE := Color(0.0, 0.0, 0.0, 0.85)
## The dot, in DOS pixels, and the port's font cell (net/terminator_vision
## draws its tags at the same size).
const DOT_DOS_PX: float = 3.0
const FONT_CELL: int = 20
## The middle of the view where a mark flashes — DOS x 0x8d..0xb3 of 320.
const FLASH_HALF_W: float = (0xb3 - 0x8d) / 2.0 / 320.0
const FLASH_HALF_H: float = 20.0 / 200.0

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

## What the scanner marks right now:
## [{pos: screen Vector2, dist: float, name: String, dead: bool}].
func marks() -> Array:
	var out: Array = []
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or game == null:
		return out
	var avatars: Dictionary = game.get("_avatars")
	var sz: Vector2 = get_viewport_rect().size
	for id in avatars:
		var av = avatars[id]
		if av == null or not is_instance_valid(av) or not (av as Node3D).visible:
			continue
		var dead: bool = not bool(av.get("alive")) or not Net.is_alive(int(id))
		var wpos: Vector3 = (av as Node3D).global_position + Vector3(0.0, 50.0, 0.0)
		if cam.is_position_behind(wpos):
			continue
		var dist: float = cam.global_position.distance_to(wpos)
		if dist <= NEAR or dist >= FAR:
			continue
		var sp: Vector2 = cam.unproject_position(wpos)
		if sp.x < 0.0 or sp.y < 0.0 or sp.x > sz.x or sp.y > sz.y:
			continue                       # DOS clips to the viewport rect
		out.append({"pos": sp, "dist": dist, "dead": dead,
			"name": String(av.get("display_name")).to_upper()})
	return out

func _draw() -> void:
	var f: Font = _font if _font != null else ThemeDB.fallback_font
	var sz: Vector2 = get_viewport_rect().size
	var k: float = sz.y / 200.0            # one DOS pixel
	var ascent: float = f.get_ascent(FONT_CELL)
	var lit: bool = (Engine.get_process_frames() & 7) < 4
	# The flash window sits under the crosshair, which is above the middle
	# of the window (the DOS view centre, over the panel).
	var mid := sz * 0.5
	if player != null and player.has_method("aim_screen_point"):
		mid = player.call("aim_screen_point")
	for m in marks():
		var sp: Vector2 = m["pos"]
		if bool(m["dead"]):
			_text(f, sp + Vector2(-48.0 * k, 0.0), "%s TERMINATED" % m["name"], ascent, MARK)
			continue
		var c: Color = MARK
		if lit and absf(sp.x - mid.x) <= FLASH_HALF_W * sz.x \
				and absf(sp.y - mid.y) <= FLASH_HALF_H * sz.y:
			c = MARK_LIT
		var half: float = maxf(DOT_DOS_PX * k * 0.5, 3.0)
		draw_rect(Rect2(sp - Vector2(half + 1.0, half + 1.0), Vector2(half, half) * 2.0 + Vector2(2.0, 2.0)), OUTLINE)
		draw_rect(Rect2(sp - Vector2(half, half), Vector2(half, half) * 2.0), c)
		_text(f, sp + Vector2(4.0 * k, -6.0 * k), String(m["name"]), ascent, c)
		_text(f, sp + Vector2(4.0 * k, 2.0 * k), "%dM" % int(float(m["dist"]) / UNITS_PER_M), ascent, c)

## DOS text is placed by its top-left corner; Godot's by the baseline.
func _text(f: Font, top_left: Vector2, s: String, ascent: float, c: Color) -> void:
	var at := top_left + Vector2(0.0, ascent)
	draw_string_outline(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_CELL, 4, OUTLINE)
	draw_string(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_CELL, c)
