## The TERMINATOR class's machine vision (the DOS MP red view): a red
## wash with scanlines, two columns of scrolling machine-code readout
## down the sides, and a targeting bracket with name and range over
## every other actor in view — even far away and through the haze, the
## way the original picked humans out at a distance. Drawn over the 3D
## view, under the HUD panel.
extends Control

const SCROLL_STEP: float = 0.07
const LINES: int = 52          # small type, so more of them fit the column
## The HUD's own bitmap font cell, and how far down the readout is scaled
## from it (a bitmap font cannot be asked for a smaller size).
const FONT_CELL: int = 20
const READOUT_SCALE: float = 0.55
const MARK_RANGE: float = 30000.0

var game: Node = null                  # dm_game.gd (avatars, font)
var _font: Font = null
var _left: Array = []
var _right: Array = []
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()

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

func set_font(f: Font) -> void:
	_font = f

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
	while _t >= SCROLL_STEP:
		_t -= SCROLL_STEP
		_left.pop_front()
		_left.append(_code_line())
		_right.pop_front()
		_right.append(_hex_line())
	queue_redraw()

func _draw() -> void:
	var sz: Vector2 = size
	# Red wash + scanlines.
	draw_rect(Rect2(Vector2.ZERO, sz), Color(0.55, 0.02, 0.0, 0.26))
	var y: float = 0.0
	while y < sz.y:
		draw_line(Vector2(0, y), Vector2(sz.x, y), Color(0.0, 0.0, 0.0, 0.16), 1.0)
		y += 3.0
	var f: Font = _font if _font != null else ThemeDB.fallback_font
	# The readout is atmosphere and it was swallowing the arena: "ten text
	# co ide cez obrazovku trochu moc velky a je to potom neprehladne"
	# (Marek 2026-09-12). Asking for a smaller font_size did NOT shrink it
	# — this is the DOS BITMAP font, which renders at its own cell size
	# whatever size is requested, so the first attempt changed nothing
	# (his next screenshot still showed the columns two thirds as tall as
	# the view). Scaling the canvas is the way a bitmap font gets smaller,
	# so the two columns are drawn through a transform and the coordinates
	# divided back out of it. The target tags are drawn afterwards, at the
	# font's own size, because who and how far away is the one thing this
	# view is FOR.
	var fs: int = FONT_CELL
	var col := Color(1.0, 0.35, 0.25, 0.55)
	var k: float = READOUT_SCALE
	var lh: float = float(fs) * 1.25 * k
	# Readout columns, clear of the HUD panel at the bottom.
	var top: float = 100.0
	var bottom: float = sz.y - 190.0
	var n: int = int((bottom - top) / lh)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
	for i in mini(n, LINES):
		var yy: float = (top + float(i) * lh) / k
		draw_string(f, Vector2(10.0 / k, yy), _left[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		# The right column hugs the right edge whatever the font measures.
		var rw: float = f.get_string_size(_right[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2((sz.x - 10.0) / k - rw, yy), _right[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Target brackets over every other living actor in the frustum.
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or game == null:
		return
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
				draw_line(corner, corner - Vector2(sx * arm, 0.0), c, 2.0)
				draw_line(corner, corner - Vector2(0.0, sy * arm), c, 2.0)
		draw_line(sp + Vector2(-4.0, 0.0), sp + Vector2(4.0, 0.0), c, 1.0)
		draw_line(sp + Vector2(0.0, -4.0), sp + Vector2(0.0, 4.0), c, 1.0)
		var tag := "%s  %dM" % [String(av.get("display_name")).to_upper(), int(dist / 32.0)]
		# Who and how far has to be legible — this is the one thing the
		# machine vision is FOR — so it keeps the font's own size.
		draw_string(f, sp + Vector2(half + 6.0, 6.0), tag, HORIZONTAL_ALIGNMENT_LEFT, -1,
			fs, c)
