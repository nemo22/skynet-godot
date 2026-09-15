## The modern HUD — shown in place of the DOS PANEL0 bar while the HI-RES
## ART setting is on (a player who asks for the sharper guns gets the
## cleaner read-out with them; the DOS bar stays the default).
##
## Built like a game's status bar, not a web page: one plate in the
## bottom-left with gradient gauges (HEALTH, ARMOUR, and RAD only while
## there is a dose to show), under them the weapon and the thrown item
## side by side with their own PICKUP SPRITES as icons and the counts by
## them; a compass strip along the bottom centre with the map's north
## (marker type 7, the DOS compass offset) under a lubber line. It first
## shipped as the ENHANCED status bar (2026-09-04/05, after three rounds
## of "it looks like a child drew it with felt-tips") and went with that
## renderer on 2026-09-11; back by request on 2026-09-15.
##
## main.gd builds it, feeds refresh() every frame and asks nothing else
## of it: it covers no part of the 3D view, so the view centre stays in
## the middle of the window (hud_height() is 0).
extends Control

const PickupData := preload("res://scripts/pickup_data.gd")

const MARGIN: float = 14.0
const TINT := Color(0.62, 0.94, 0.70)
const PLATE_WIDTH: float = 300.0
const COMPASS_SPAN: float = 110.0        # degrees across the strip
const COMPASS_SIZE := Vector2(430.0, 24.0)
## Ammo pool -> the sprite of the thrown item that draws from it.
const THROW_SPRITES: Dictionary = {
	5: 25728, 6: 25605, 2: 25607, 8: 25603, 9: 25604,
}

var _health_label: Label = null
var _health_fill: TextureRect = null
var _armor_label: Label = null
var _armor_fill: TextureRect = null
var _rad_fill: TextureRect = null
var _rad_row: Control = null
var _weapon_icon: TextureRect = null
var _ammo_label: Label = null
var _weapon_label: Label = null
var _second_icon: TextureRect = null
var _second_label: Label = null
var _strip: Control = null
## Weapon slot -> the pickup sprite that grants it (built from the DOS
## item table, so the icon is always the thing you picked up).
var _weapon_sprites: Dictionary = {}
var _icon_weapon: int = -1
var _icon_pool: int = -1
var _bearing: int = -1                   # 11-bit clockwise bearing shown
var _shown: Dictionary = {}              # last values written to the labels

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for si in PickupData.ITEMS:
		var w: int = int(PickupData.ITEMS[si][4])
		if w >= 0 and not _weapon_sprites.has(w):
			_weapon_sprites[w] = si
	# --- bottom left: no box around it — the drop shadow on the type keeps
	# it legible over any scene, and a frame sized by anchors let the
	# gauges run out through its border.
	var plate := PanelContainer.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 2.0
	sb.content_margin_right = 2.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	plate.add_theme_stylebox_override("panel", sb)
	plate.anchor_top = 1.0
	plate.anchor_bottom = 1.0
	plate.offset_left = MARGIN
	plate.offset_right = MARGIN + PLATE_WIDTH
	plate.offset_top = -132.0
	plate.offset_bottom = -MARGIN
	add_child(plate)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.alignment = BoxContainer.ALIGNMENT_END
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(col)
	var hp: Array = _row(col, "HEALTH", Color(0.85, 0.16, 0.13), Color(1.0, 0.55, 0.30), 96.0, 8.0)
	_health_label = hp[0]
	_health_fill = hp[1]
	var ar: Array = _row(col, "ARMOUR", Color(0.16, 0.38, 0.85), Color(0.55, 0.85, 1.0), 96.0, 6.0)
	_armor_label = ar[0]
	_armor_fill = ar[1]
	var rad: Array = _row(col, "RAD", Color(0.72, 0.55, 0.05), Color(1.0, 0.95, 0.35), 96.0, 6.0)
	_rad_fill = rad[1]
	_rad_row = rad[2]
	_rad_row.visible = false
	# The weapon line: icon, rounds, name; then the thrown item and its
	# count — one row on one baseline, so the number sits by the gun.
	var guns := HBoxContainer.new()
	guns.add_theme_constant_override("separation", 8)
	guns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(guns)
	_weapon_icon = _icon(guns, 48.0)
	_ammo_label = _label(guns, HORIZONTAL_ALIGNMENT_RIGHT, 18, 1.0)
	_ammo_label.custom_minimum_size = Vector2(50.0, 0.0)
	_ammo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_weapon_label = _label(guns, HORIZONTAL_ALIGNMENT_LEFT, 10, 0.55)
	_weapon_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(10.0, 0.0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	guns.add_child(gap)
	_second_icon = _icon(guns, 34.0)
	_second_label = _label(guns, HORIZONTAL_ALIGNMENT_LEFT, 14, 1.0)
	_second_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# --- compass strip, bottom centre ---
	_strip = Control.new()
	_strip.custom_minimum_size = COMPASS_SIZE
	_strip.size = COMPASS_SIZE
	_strip.anchor_left = 0.5
	_strip.anchor_right = 0.5
	_strip.anchor_top = 1.0
	_strip.anchor_bottom = 1.0
	_strip.offset_left = -COMPASS_SIZE.x * 0.5
	_strip.offset_right = COMPASS_SIZE.x * 0.5
	_strip.offset_top = -COMPASS_SIZE.y - MARGIN
	_strip.offset_bottom = -MARGIN
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.draw.connect(_draw_strip)
	add_child(_strip)

## Nothing of the view is covered.
func hud_height() -> float:
	return 0.0

## The frame's read-out. `s`: health, max_health, armor (0..1), rad (0..1),
## weapon_idx, weapon_name, ammo (-1 = none), second_pool, second_name,
## second_count, bearing (11-bit clockwise, -1 = none). Only what moved is
## written — a label set every frame re-shapes its text for nothing.
func refresh(s: Dictionary) -> void:
	var hp: int = int(maxf(0.0, float(s.get("health", 0.0))))
	var max_hp: float = maxf(float(s.get("max_health", 100.0)), 1.0)
	_set_text(_health_label, "hp", str(hp))
	_health_fill.anchor_right = clampf(float(hp) / max_hp, 0.0, 1.0)
	var armor: float = clampf(float(s.get("armor", 0.0)), 0.0, 1.0)
	_set_text(_armor_label, "ar", str(int(round(armor * 100.0))))
	_armor_fill.anchor_right = armor
	var rad: float = clampf(float(s.get("rad", 0.0)), 0.0, 1.0)
	_rad_row.visible = rad > 0.0
	_rad_fill.anchor_right = rad
	var am: int = int(s.get("ammo", -1))
	_set_text(_ammo_label, "am", "" if am < 0 else str(am))
	if bool(_shown.get("am0", false)) != (am == 0):
		_shown["am0"] = am == 0
		_ammo_label.add_theme_color_override("font_color",
			Color(1, 0.4, 0.32) if am == 0 else Color(TINT.r, TINT.g, TINT.b))
	_set_text(_weapon_label, "wn", String(s.get("weapon_name", "")))
	var sc: int = int(s.get("second_count", 0))
	var sn: String = String(s.get("second_name", ""))
	_set_text(_second_label, "sn", "%s  x%d" % [sn, sc] if not sn.is_empty() else "")
	_second_label.modulate = Color(1, 1, 1) if sc > 0 else Color(0.55, 0.5, 0.5)
	_update_icons(int(s.get("weapon_idx", -1)), int(s.get("second_pool", -1)))
	var b: int = int(s.get("bearing", -1))
	if b != _bearing:
		_bearing = b
		_strip.queue_redraw()

func _set_text(l: Label, key: String, text: String) -> void:
	if String(_shown.get(key, "")) != text:
		_shown[key] = text
		l.text = text

## Keep the weapon / thrown-item icons in step with what is in hand.
func _update_icons(wi: int, pool: int) -> void:
	if wi != _icon_weapon:
		_icon_weapon = wi
		var si: int = int(_weapon_sprites.get(wi, -1))
		_weapon_icon.texture = Assets.texture(si >> 7, si & 0x7F, true) if si > 0 else null
	if pool != _icon_pool:
		_icon_pool = pool
		var ti: int = int(THROW_SPRITES.get(pool, -1))
		_second_icon.texture = Assets.texture(ti >> 7, ti & 0x7F, true) if ti > 0 else null

## A small item picture (the DOS sprite of the gun or the grenade),
## `w` wide and half as tall, centred.
func _icon(parent: Control, w: float) -> TextureRect:
	var ico := TextureRect.new()
	ico.custom_minimum_size = Vector2(w, w * 0.5)
	ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ico.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	ico.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(ico)
	return ico

## One gauge row: caption, value, and a bar that is a real gradient in a
## sunken frame rather than a flat block of colour.
func _row(parent: Control, caption: String, c0: Color, c1: Color,
		width: float, height: float) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	var cap := _label(row, HORIZONTAL_ALIGNMENT_LEFT, 10, 0.55)
	cap.text = caption
	cap.custom_minimum_size = Vector2(52.0, 0.0)
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var val := _label(row, HORIZONTAL_ALIGNMENT_RIGHT, 15, 1.0)
	val.custom_minimum_size = Vector2(34.0, 0.0)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# A plain Control, NOT a PanelContainer: a container resizes its
	# child to its own rect every layout pass, which quietly overrode the
	# fill's anchor_right — every gauge read full whatever the value was.
	var trough := Control.new()
	trough.custom_minimum_size = Vector2(width, height)
	trough.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	trough.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	trough.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(trough)
	var back := Panel.new()
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tb := StyleBoxFlat.new()
	tb.bg_color = Color(0.0, 0.0, 0.0, 0.62)
	tb.set_border_width_all(1)
	tb.border_color = Color(TINT.r, TINT.g, TINT.b, 0.22)
	back.add_theme_stylebox_override("panel", tb)
	trough.add_child(back)
	# The fill: a left-to-right gradient with a lighter top edge, so it
	# has some shape to it instead of reading as a coloured rectangle.
	var fill := TextureRect.new()
	fill.texture = _gauge_gradient(c0, c1)
	fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fill.stretch_mode = TextureRect.STRETCH_SCALE
	fill.anchor_bottom = 1.0
	fill.anchor_right = 1.0
	fill.offset_left = 1.0
	fill.offset_top = 1.0
	fill.offset_right = -1.0
	fill.offset_bottom = -1.0
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trough.add_child(fill)
	return [val, fill, row]

## Left-to-right colour ramp with a highlight along the top.
static func _gauge_gradient(c0: Color, c1: Color) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, c0)
	g.add_point(0.55, c0.lerp(c1, 0.55))
	g.set_color(g.get_point_count() - 1, c1)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 128
	t.height = 8
	t.fill_from = Vector2(0.0, 0.0)
	t.fill_to = Vector2(1.0, 0.0)
	return t

func _label(parent: Control, align: int, size: int, dim: float) -> Label:
	var l := Label.new()
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_color", Color(TINT.r, TINT.g, TINT.b) * dim)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_font_size_override("font_size", size)
	parent.add_child(l)
	return l

## The compass strip: ticks every 15 degrees, the cardinals lettered, the
## heading fixed under a lubber line in the middle. The bearing is the one
## the DOS compass shows (clockwise from the map's north).
func _draw_strip() -> void:
	if _strip == null or _bearing < 0:
		return
	var w: float = _strip.size.x
	var h: float = _strip.size.y
	var tint := Color(TINT.r, TINT.g, TINT.b)
	_strip.draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.02, 0.03, 0.04, 0.42))
	_strip.draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(tint.r, tint.g, tint.b, 0.18), false, 1.0)
	var heading: float = float(_bearing) * 360.0 / 2048.0
	var font: Font = _strip.get_theme_default_font()
	var deg: int = int(floor((heading - COMPASS_SPAN * 0.5) / 15.0)) * 15
	while float(deg) < heading + COMPASS_SPAN * 0.5:
		var d: float = wrapf(float(deg) - heading, -180.0, 180.0)
		var x: float = w * 0.5 + d / COMPASS_SPAN * w
		deg += 15
		if x < 2.0 or x > w - 2.0:
			continue
		var cardinal: bool = posmod(deg - 15, 90) == 0
		var tick: float = h * (0.42 if cardinal else 0.24)
		_strip.draw_line(Vector2(x, h - 2.0), Vector2(x, h - 2.0 - tick),
			Color(tint.r, tint.g, tint.b, 0.85 if cardinal else 0.45), 1.0)
		if cardinal and font != null:
			var letter: String = ["N", "E", "S", "W"][int(posmod(deg - 15, 360) / 90)]
			_strip.draw_string(font, Vector2(x - 5.0, h * 0.52), letter,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, tint)
	# The lubber line: where you are actually facing.
	_strip.draw_line(Vector2(w * 0.5, 1.0), Vector2(w * 0.5, h - 1.0),
		Color(1.0, 0.55, 0.35, 0.9), 1.0)
