## The DOS HUD: PANEL0.IMG and everything the original draws on it, as
## FUN_00131fd4 draws it (Skynet.exe v1.00), in the same order and at the
## same 320x200 pixels — icons, PANEL0 over them, the ammo counters, the
## rad counter, the compass, the health and armour bars:
##
##   - the primary weapon's WEAPONnn.IMG (83x17) in the box (50,180)-(133,197)
##     and the secondary's (39x17) in (3,180)-(42,197), under a PANEL0 whose
##     index-0 holes show them (FUN_001259f9; every record's +0x40/+0x44
##     nudge is 0);
##   - the counts in FONT0004, palette 0xB7, right-aligned at x 128 and x 38
##     on row 191 (FUN_00132154): 4 digits clamped to 9999 for the primary,
##     3 for the secondary; nothing at all for a weapon without a pool
##     (the pipe, the motion detector);
##   - RADCOUNT.CFA (41x10) at (50,165): SAFE / CAUTION / DANGER by the
##     dose, < 1 / < 0x23 / the rest (FUN_00132348; its fourth frame is
##     never shown);
##   - COMPASS.IMG through the 37 px window at (96,163) (FUN_001323a2);
##   - PANELBAR.IMG (41x5, plain red) at (172,185) for health and (172,169)
##     for armour — the hull in a vehicle — cut at round(41 x v) px, at
##     least one while v > 0, the rest flat 0x7A (FUN_0013249c).
##
## No number for the health, no weapon name, nothing in the right-hand
## recess: DOS paints it 0x7A and never draws there. In a vehicle the same
## panel stays, the vehicle's records 20-25 supply the icons and pools.
## With the HI-RES ART setting every image comes from MDMDHRES.BSA (2x wide,
## 2.4x tall — DOS only moves the origin, the bigger art does the rest);
## here they are all drawn into the same 320x40 layout, so the only
## difference is sharpness.
extends Control

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const Palette := preload("res://scripts/loaders/palette.gd")
const ImgFile := preload("res://scripts/loaders/img_file.gd")
const FntFont := preload("res://scripts/loaders/fnt_font.gd")

## Port weapon slot → DOS weapon record (icon WEAPONnn.IMG). Slots 0-12
## are the records; the vehicle guns sit at records 20-25 (the jeep's
## plasma twice, 20/21, and its rockets 22/23) and the detector at 13.
const SLOT_RECORD: Dictionary = {13: 20, 14: 22, 15: 24, 16: 25, 17: 13}
## Thrown item's ammo pool → its record (14 pipe bomb .. 18 satchel).
const POOL_RECORD: Dictionary = {5: 14, 6: 15, 2: 16, 8: 17, 9: 18}
## The vehicle's secondary: its rockets (jeep 22, HK 25), pool 11.
const VEHICLE_SECOND_RECORD: Dictionary = {1: 22, 2: 25}
const VEHICLE_SECOND_POOL: int = 11

const AMMO_COLOR := Color8(71, 159, 71)          # palette 0xB7
const EMPTY_COLOR := Color8(38, 38, 44)          # palette 0x7A
const BAR_W: int = 41
const BAR_H: int = 5

var _hires: bool = false
var _panel: Texture2D = null
var _bar: Texture2D = null
var _compass_tex: Texture2D = null
var _rad_frames: Array = []
var _icons: Dictionary = {}                      # record → Texture2D or null
var _font: FontFile = null
var _font_scale: int = 0
var _font_bytes: PackedByteArray = PackedByteArray()
var _compass: Control = null
var _state: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# The compass window: its own Control, so the ribbon is clipped.
	_compass = Control.new()
	_compass.anchor_left = 96.0 / 320.0
	_compass.anchor_right = 133.0 / 320.0
	_compass.anchor_top = 3.0 / 40.0
	_compass.anchor_bottom = 17.0 / 40.0
	_compass.clip_contents = true
	_compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compass.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_compass.draw.connect(_draw_compass)
	add_child(_compass)
	resized.connect(queue_redraw)

## Load the art for one set (`hires`: MDMDHRES.BSA where it has the image).
func setup(hires: bool) -> void:
	_hires = hires
	_icons.clear()
	_panel = _img("PANEL0.IMG", true)
	_bar = _img("PANELBAR.IMG", false)
	_compass_tex = _img("COMPASS.IMG", false)
	_rad_frames = Assets.cfa_frames("RADCOUNT.CFA", hires)
	_font_bytes = SkynetPaths.read_bytes(SkynetPaths.gamedata_path("FONT0004.FNT"))
	_font = null
	_font_scale = 0
	queue_redraw()

## The 320x40 bar at its DOS proportion: an eighth of the window's width,
## never more than 160 px of the view (the caller lays it out).
static func bar_height(view_width: float) -> float:
	return clampf(view_width / 8.0, 64.0, 160.0)

## The frame's read-out. `s`: health, max_health, armor (0..1, the hull in
## a vehicle), rad (the dose, DOS units), weapon_idx, ammo (-1 = no pool),
## vehicle, second_pool, second_count, bearing (11-bit, -1 = none).
func refresh(s: Dictionary) -> void:
	if s == _state:
		return
	var old_bearing: int = int(_state.get("bearing", -2))
	_state = s.duplicate()
	if int(s.get("bearing", -1)) != old_bearing:
		_compass.queue_redraw()
	queue_redraw()

func _draw() -> void:
	var sc: float = size.x / 320.0                  # window px per DOS px
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
	# Icons first, PANEL0 over them.
	var veh: int = int(_state.get("vehicle", 0))
	var slot: int = int(_state.get("weapon_idx", -1))
	var prim: int = int(SLOT_RECORD.get(slot, slot))
	var sec: int = int(VEHICLE_SECOND_RECORD.get(veh, POOL_RECORD.get(int(_state.get("second_pool", -1)), -1)))
	_blit(_icon(prim), 50.0, 20.0, 83.0, 17.0, sc)
	_blit(_icon(sec), 3.0, 20.0, 39.0, 17.0, sc)
	if _panel != null:
		draw_texture_rect(_panel, Rect2(Vector2.ZERO, size), false)
	# The counters.
	var ammo: int = int(_state.get("ammo", -1))
	if ammo >= 0:
		_number(str(clampi(ammo, 0, 9999)), 128.0, 31.0, sc)
	var second: int = int(_state.get("second_count", -1))
	if second >= 0 and sec >= 0:
		_number(str(second), 38.0, 31.0, sc)
	# The rad counter.
	if not _rad_frames.is_empty():
		var dose: float = float(_state.get("rad", 0.0))
		var fi: int = 0 if dose < 1.0 else (1 if dose < 35.0 else 2)
		_blit(_rad_frames[mini(fi, _rad_frames.size() - 1)], 50.0, 5.0, 41.0, 10.0, sc)
	# The bars.
	var max_hp: float = maxf(float(_state.get("max_health", 100.0)), 1.0)
	_gauge(clampf(float(_state.get("health", 0.0)) / max_hp, 0.0, 1.0), 172.0, 25.0, sc)
	_gauge(clampf(float(_state.get("armor", 0.0)), 0.0, 1.0), 172.0, 9.0, sc)

## `tex` into the DOS rect (x, y, w, h) of the panel.
func _blit(tex: Texture2D, x: float, y: float, w: float, h: float, sc: float) -> void:
	if tex == null:
		return
	draw_texture_rect(tex, Rect2(x * sc, y * sc, w * sc, h * sc), false)

## PANELBAR cut at the filled width, flat 0x7A after it (FUN_0013249c).
func _gauge(v: float, x: float, y: float, sc: float) -> void:
	var filled: int = clampi(int(floor(BAR_W * v + 0.5)), 0, BAR_W)
	if v > 0.0 and filled < 1:
		filled = 1
	if filled > 0 and _bar != null:
		var kx: float = _bar.get_width() / float(BAR_W)
		draw_texture_rect_region(_bar, Rect2(x * sc, y * sc, filled * sc, BAR_H * sc),
			Rect2(0.0, 0.0, filled * kx, _bar.get_height()))
	if filled < BAR_W:
		draw_rect(Rect2((x + filled) * sc, y * sc, (BAR_W - filled) * sc, BAR_H * sc), EMPTY_COLOR)

## A FONT0004 number with its right edge at DOS x `right`, top at `top`.
func _number(text: String, right: float, top: float, sc: float) -> void:
	var f: FontFile = _digit_font(sc)
	if f == null:
		return
	var sz: int = f.fixed_size
	var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	# The bitmap's height is 5 DOS px x the font scale; the draw origin is
	# the baseline, one glyph height under the top.
	draw_string(f, Vector2(right * sc - w, top * sc + sz), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, sz, AMMO_COLOR)

## FONT0004 rasterised at the panel's scale (integer — the DOS glyphs stay
## whole pixels), rebuilt when the window changes size.
func _digit_font(sc: float) -> FontFile:
	var k: int = maxi(1, int(round(sc)))
	if _font == null or k != _font_scale:
		if _font_bytes.is_empty():
			return null
		_font = FntFont.build(_font_bytes, k)
		_font_scale = k
	return _font

## COMPASS.IMG at the DOS scroll for the bearing (FUN_001323a2).
func _draw_compass() -> void:
	var a: int = int(_state.get("bearing", -1))
	if _compass_tex == null or a < 0:
		return
	var sc: float = _compass.size.x / 37.0
	var scroll: int = (-148 * a + 1024) >> 11
	_compass.draw_texture_rect(_compass_tex,
		Rect2(float(scroll) * sc, 0.0, 185.0 * sc, _compass.size.y), false)

## The weapon icon of DOS record `rec`, loaded once per set.
func _icon(rec: int) -> Texture2D:
	if rec < 0:
		return null
	if not _icons.has(rec):
		_icons[rec] = _img("WEAPON%02d.IMG" % rec, false)
	return _icons[rec]

## An .IMG from the set in force (MDMDHRES.BSA first with HI-RES ART, the
## 320x200 art otherwise), or null.
func _img(name: String, transparent0: bool) -> ImageTexture:
	var bytes := PackedByteArray()
	for arc in (["MDMDHRES.BSA", "MDMDIMGS.BSA"] if _hires else ["MDMDIMGS.BSA"]):
		var bsa := BSAReader.new()
		if not bsa.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
			continue
		bytes = bsa.read(name)
		bsa.close()
		if not bytes.is_empty():
			break
	var palette := Palette.parse(SkynetPaths.palette_bytes())
	if palette.is_empty() or bytes.is_empty():
		return null
	return ImgFile.parse(bytes, palette, transparent0)
