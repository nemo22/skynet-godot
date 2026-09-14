## The TERMINATOR class's machine vision (the DOS MP red view): a red
## wash with scanlines, two columns of scrolling machine-code readout
## down the sides, and a targeting bracket with name and range over
## every other actor in view — even far away and through the haze, the
## way the original picked humans out at a distance. Drawn over the 3D
## view, under the HUD panel.
##
## Four layers, bottom to top, so each is drawn only as often as it
## changes: the wash and the scanlines never (a ColorRect and one tiled
## texture — the scanlines were ~360 draw_line calls a frame), the readout
## when it scrolls, the target brackets every frame.
extends Control

const SCROLL_STEP: float = 0.07
const LINES: int = 52          # small type, so more of them fit the column
## The HUD's own bitmap font cell, and how far down the readout is scaled
## from it (a bitmap font cannot be asked for a smaller size).
const FONT_CELL: int = 20
const READOUT_SCALE: float = 0.55
const MARK_RANGE: float = 30000.0
const WASH := Color(0.55, 0.02, 0.0, 0.26)
## A 1-unit black line every SCANLINE_STEP units.
const SCANLINE := Color(0.0, 0.0, 0.0, 0.16)
const SCANLINE_STEP: int = 3

var game: Node = null                  # dm_game.gd (avatars, font)
var _font: Font = null
var _left: Array = []
var _right: Array = []
## Measured width of each right-column line (-1 = not measured yet), so a
## redraw does not measure 52 strings again.
var _right_w: PackedFloat32Array = PackedFloat32Array()
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()
var _readout: Control = null
var _marks: Control = null

const MNEMONICS: Array = ["MOV", "CMP", "JNZ", "LEA", "XOR", "ADD", "SUB", "INT",
	"CALL", "RET", "PUSH", "POP", "TEST", "JMP", "SHL", "AND", "OR", "LOOP"]
const REGS: Array = ["AX", "BX", "CX", "DX", "SI", "DI", "BP", "SP", "ES:[BX]", "DS:[SI]"]

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rng.randomize()
	for _i in LINES:
		_left.append(_code_line())
		_right.append(_hex_line())
		_right_w.append(-1.0)
	var wash := ColorRect.new()
	wash.color = WASH
	_add_layer(wash)
	var img := Image.create_empty(1, SCANLINE_STEP, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	img.set_pixel(0, 0, SCANLINE)
	var scan := TextureRect.new()
	scan.texture = ImageTexture.create_from_image(img)
	scan.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scan.stretch_mode = TextureRect.STRETCH_TILE
	scan.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp lines when the canvas is scaled
	_add_layer(scan)
	_readout = Control.new()
	_readout.draw.connect(_draw_readout)
	_add_layer(_readout)
	_marks = Control.new()
	_marks.draw.connect(_draw_marks)
	_add_layer(_marks)

func _add_layer(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_font(f: Font) -> void:
	_font = f
	_right_w.fill(-1.0)
	if _readout != null:
		_readout.queue_redraw()

func _code_line() -> String:
	var op: String = MNEMONICS[_rng.randi() % MNEMONICS.size()]
	if op in ["RET", "INT", "LOOP"]:
		return "%04X  %s %02X" % [_rng.randi() % 0x10000, op, _rng.randi() % 0x100]
	if _rng.randf() < 0.5:
		return "%04X  %s %s,%s" % [_rng.randi() % 0x10000, op, REGS[_rng.randi() % REGS.size()],
			REGS[_rng.randi() % REGS.size()]]
	return "%04X  %s %s,%04X" % [_rng.randi() % 0x10000, op, REGS[_rng.randi() % REGS.size()],
		_rng.randi() % 0x10000]

func _hex_line() -> String:
	return "%04X %04X %04X" % [_rng.randi() % 0x10000, _rng.randi() % 0x10000, _rng.randi() % 0x10000]

func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	var scrolled := false
	while _t >= SCROLL_STEP:
		_t -= SCROLL_STEP
		_left.pop_front()
		_left.append(_code_line())
		_right.pop_front()
		_right.append(_hex_line())
		_right_w.remove_at(0)
		_right_w.append(-1.0)
		scrolled = true
	if scrolled:
		_readout.queue_redraw()
	_marks.queue_redraw()

func _draw_readout() -> void:
	var sz: Vector2 = _readout.size
	var f: Font = _font if _font != null else ThemeDB.fallback_font
	# The readout is atmosphere and it was swallowing the arena: "ten text
	# co ide cez obrazovku trochu moc velky a je to potom neprehladne"
	# (playtest 2026-09-12). Asking for a smaller font_size did NOT shrink it
	# — this is the DOS BITMAP font, which renders at its own cell size
	# whatever size is requested, so the first attempt changed nothing
	# (his next screenshot still showed the columns two thirds as tall as
	# the view). Scaling the canvas is the way a bitmap font gets smaller,
	# so the two columns are drawn through a transform and the coordinates
	# divided back out of it. The target tags are drawn on their own layer,
	# at the font's own size, because who and how far away is the one thing
	# this view is FOR.
	var fs: int = FONT_CELL
	var col := Color(1.0, 0.35, 0.25, 0.55)
	var k: float = READOUT_SCALE
	var lh: float = float(fs) * 1.25 * k
	# Readout columns, clear of the HUD panel at the bottom.
	var top: float = 100.0
	var bottom: float = sz.y - 190.0
	var n: int = int((bottom - top) / lh)
	_readout.draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
	for i in mini(n, LINES):
		var yy: float = (top + float(i) * lh) / k
		_readout.draw_string(f, Vector2(10.0 / k, yy), _left[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		# The right column hugs the right edge whatever the font measures.
		if _right_w[i] < 0.0:
			_right_w[i] = f.get_string_size(_right[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		_readout.draw_string(f, Vector2((sz.x - 10.0) / k - _right_w[i], yy), _right[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	_readout.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Target brackets over every other living actor in the frustum.
func _draw_marks() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or game == null:
		return
	var sz: Vector2 = _marks.size
	var f: Font = _font if _font != null else ThemeDB.fallback_font
	var fs: int = FONT_CELL
	var avatars: Dictionary = game.get("_avatars")
	for id in avatars:
		var av = avatars[id]
		if av == null or not is_instance_valid(av) or not bool(av.get("alive")) or not Net.is_alive(int(id)):
			continue
		var wpos: Vector3 = (av as Node3D).global_position + Vector3(0.0, 50.0, 0.0)
		if cam.is_position_behind(wpos):
			continue
		var dist: float = cam.global_position.distance_to(wpos)
		if dist > MARK_RANGE:
			continue
		var sp: Vector2 = cam.unproject_position(wpos)
		if sp.x < -50.0 or sp.y < -50.0 or sp.x > sz.x + 50.0 or sp.y > sz.y + 50.0:
			continue
		var half: float = clampf(9000.0 / maxf(dist, 1.0) * 6.0, 14.0, 70.0)
		var c := Color(1.0, 0.25, 0.15, 0.95)
		var arm: float = half * 0.45
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				var corner := sp + Vector2(sx * half, sy * half)
				_marks.draw_line(corner, corner - Vector2(sx * arm, 0.0), c, 2.0)
				_marks.draw_line(corner, corner - Vector2(0.0, sy * arm), c, 2.0)
		_marks.draw_line(sp + Vector2(-4.0, 0.0), sp + Vector2(4.0, 0.0), c, 1.0)
		_marks.draw_line(sp + Vector2(0.0, -4.0), sp + Vector2(0.0, 4.0), c, 1.0)
		var tag := "%s  %dM" % [String(av.get("display_name")).to_upper(), int(dist / 32.0)]
		# Who and how far has to be legible — this is the one thing the
		# machine vision is FOR — so it keeps the font's own size.
		_marks.draw_string(f, sp + Vector2(half + 6.0, 6.0), tag, HORIZONTAL_ALIGNMENT_LEFT, -1,
			fs, c)
