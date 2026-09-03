## Quake-style drop-down console: `~` (the key left of 1) slides a
## half-screen panel down from the top with a command line. Alt+\ —
## the DOS cheat prompt (FUN_00141e6b) — opens the same console, so
## the CHEAT.PRS codes (superuzi, arnold, slugs …) are typed here.
##
## Every line goes to `handler.run_command(line) -> String`; the
## reply is printed below it. The game is paused while the console is
## down (single player, like Quake). Up/Down walk the history, Esc or
## `~` close it.
extends CanvasLayer

signal closed

var handler: Object = null
var is_open: bool = false

const HEIGHT_FRAC: float = 0.5
const MAX_LINES: int = 400

var _panel: PanelContainer = null
var _log: RichTextLabel = null
var _line: LineEdit = null
var _history: Array[String] = []
var _hist_pos: int = 0
var _log_shown: int = 0          # engine log lines already in the panel
## Engine output (Log autoload) is echoed while the console is down;
## `log off` in the console silences it.
var echo_engine: bool = true

func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.05, 0.06, 0.93)
	sb.border_color = Color(0.35, 0.75, 0.45)
	sb.border_width_bottom = 2
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_panel.add_child(vb)
	_log = RichTextLabel.new()
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 16)
	_log.add_theme_font_size_override("mono_font_size", 16)
	_log.add_theme_color_override("default_color", Color(0.8, 0.92, 0.82))
	vb.add_child(_log)
	_line = LineEdit.new()
	_line.placeholder_text = "command  (help)"
	_line.add_theme_font_size_override("font_size", 17)
	_line.text_submitted.connect(_on_submit)
	vb.add_child(_line)
	get_viewport().size_changed.connect(_layout)
	_layout()
	say("[color=#88dd99]SkyNET console[/color] — type [b]help[/b]; Esc or ~ closes. Engine output is echoed here ([b]log off[/b] to hide).")
	Log.line.connect(_on_engine_line)

## Engine log lines: buffered ones are flushed when the console opens,
## live ones appended while it is down.
func _on_engine_line(text: String, error: bool) -> void:
	if not is_open or not echo_engine:
		return
	_flush_engine_log()

func _flush_engine_log() -> void:
	var all: Array = Log.lines
	if _log_shown > all.size():
		_log_shown = 0
	while _log_shown < all.size():
		var e: Array = all[_log_shown]
		_log_shown += 1
		if not echo_engine:
			continue
		var t: String = String(e[0]).replace("[", "[lb]")
		if bool(e[1]):
			say("[color=#ff8a70]%s[/color]" % t)
		else:
			say("[color=#9fb4a8]%s[/color]" % t)

func _layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_panel.position = Vector2.ZERO
	_panel.size = Vector2(vp.x, vp.y * HEIGHT_FRAC)

## Drop the console; `preset` pre-fills the command line.
func open(preset: String = "") -> void:
	if is_open:
		return
	is_open = true
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_flush_engine_log()
	_line.text = preset
	_line.grab_focus()
	_line.caret_column = preset.length()

func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	_line.release_focus()
	get_tree().paused = false
	closed.emit()

func toggle() -> void:
	if is_open:
		close()
	else:
		open()

## Append a (BBCode) line to the log.
func say(text: String) -> void:
	_log.append_text(text + "\n")
	if _log.get_line_count() > MAX_LINES:
		_log.remove_paragraph(0)

static func is_toggle_key(event: InputEvent) -> bool:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return false
	var k: InputEventKey = event
	return k.keycode == KEY_QUOTELEFT or k.keycode == KEY_ASCIITILDE \
		or k.physical_keycode == KEY_QUOTELEFT or k.keycode == KEY_SECTION

func _input(event: InputEvent) -> void:
	if not is_open or not (event is InputEventKey and event.pressed):
		return
	var k: InputEventKey = event
	if k.keycode == KEY_ESCAPE or is_toggle_key(event):
		close()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_UP and not _history.is_empty():
		_hist_pos = maxi(_hist_pos - 1, 0)
		_line.text = _history[_hist_pos]
		_line.caret_column = _line.text.length()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_DOWN and not _history.is_empty():
		_hist_pos = mini(_hist_pos + 1, _history.size())
		_line.text = _history[_hist_pos] if _hist_pos < _history.size() else ""
		_line.caret_column = _line.text.length()
		get_viewport().set_input_as_handled()

func _on_submit(text: String) -> void:
	var cmd := text.strip_edges()
	_line.clear()
	if cmd.is_empty():
		return
	if _history.is_empty() or _history[_history.size() - 1] != cmd:
		_history.append(cmd)
	_hist_pos = _history.size()
	say("[color=#ffd27a]] %s[/color]" % cmd)
	if cmd == "log off" or cmd == "log on":
		echo_engine = cmd == "log on"
		_log_shown = Log.lines.size()
		say("engine output %s" % ("on" if echo_engine else "off"))
		return
	run(cmd)

## Execute a line through the handler and print the reply.
func run(cmd: String) -> void:
	if handler == null or not handler.has_method("run_command"):
		say("no command handler")
		return
	# run_command may be a coroutine (the "shoot" command steps frames);
	# awaiting a plain value is a no-op in GDScript 2, so this is safe.
	var reply: String = String(await handler.call("run_command", cmd))
	if not reply.is_empty():
		say(reply)
