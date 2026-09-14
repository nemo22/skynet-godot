## Quake-style drop-down console: `~` (the key left of 1) slides a
## half-screen panel down from the top with a command line. Alt+\ —
## the DOS cheat prompt (FUN_00141e6b) — opens the same console, so
## the CHEAT.PRS codes (superuzi, arnold, slugs …) are typed here.
##
## Every line goes to `handler.run_command(line) -> String`; the
## reply is printed below it. The game is paused while the console is
## down (single player, like Quake; a network game keeps running and only
## the controls stop — scripts/pause_state.gd). Up/Down walk the history,
## Tab completes a command (twice lists the candidates), PgUp/PgDn/wheel
## scroll the log and hold the position until End or the bottom, Esc or
## `~` close it. Everything the engine prints is echoed, whether the
## console is down or not (playtest, 2026-09-05: "ako to má Quake").
##
## The log is filled once a frame and only while the console is down: a
## level load prints hundreds of lines, and a RichTextLabel shaping each
## of them as it came (hidden or not) cost a stutter after every load.
## Opening the console catches up from the Log ring.
extends CanvasLayer

const PauseState := preload("res://scripts/pause_state.gd")

signal closed

var handler: Object = null
var is_open: bool = false

const HEIGHT_FRAC: float = 0.5
const MAX_LINES: int = 1500

var _panel: PanelContainer = null
var _log: RichTextLabel = null
var _line: LineEdit = null
var _history: Array[String] = []
var _hist_pos: int = 0
var _log_seq: int = 0            # Log.total already taken into the panel
var _following: bool = true      # glued to the bottom (until scrolled up)
var _tab_matches: Array = []     # completion candidates of the last Tab
var _tab_prefix: String = ""
## Lines said but not in the label yet, and the last MAX_LINES said — what
## the label is rebuilt from when a flush would overflow it.
var _backlog: PackedStringArray = PackedStringArray()
var _kept: PackedStringArray = PackedStringArray()
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
	_log.focus_mode = Control.FOCUS_NONE      # Tab must not leave the line
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 16)
	_log.add_theme_font_size_override("mono_font_size", 16)
	_log.add_theme_color_override("default_color", Color(0.8, 0.92, 0.82))
	vb.add_child(_log)
	_log.get_v_scroll_bar().value_changed.connect(_on_scrolled)
	_line = LineEdit.new()
	_line.placeholder_text = "command  (help, Tab completes)"
	_line.add_theme_font_size_override("font_size", 17)
	_line.text_submitted.connect(_on_submit)
	_line.text_changed.connect(func(_t: String) -> void: _tab_matches = [])
	vb.add_child(_line)
	get_viewport().size_changed.connect(_layout)
	_layout()
	say("[color=#88dd99]SkyNET console[/color] — type [b]help[/b]; Tab completes; PgUp/PgDn scroll; Esc or ~ closes. Engine output is echoed here ([b]log off[/b] to hide).")

## Once a frame while down: the engine's new lines and anything said.
func _process(_delta: float) -> void:
	if is_open and (Log.total != _log_seq or not _backlog.is_empty()):
		_flush()

## Take every Log line not yet taken. Log keeps a ring of its last lines;
## what fell out of it while the console was up is reported as a count.
func _take_engine_log() -> void:
	var missing: int = Log.total - _log_seq
	if missing <= 0:
		return
	var fresh: Array = Log.since(_log_seq)
	_log_seq = Log.total
	if not echo_engine:
		return
	if missing > fresh.size():
		say("[color=#6f8a7a]… %d lines scrolled out of the engine buffer[/color]" % (missing - fresh.size()))
	for e in fresh:
		var t: String = String(e[0]).replace("[", "[lb]")
		say(("[color=#ff8a70]%s[/color]" if bool(e[1]) else "[color=#9fb4a8]%s[/color]") % t)

## Put the backlog into the label in one append. A batch that would push
## the label far past MAX_LINES rebuilds it from the kept lines instead of
## removing paragraphs one by one.
func _flush() -> void:
	_take_engine_log()
	if _backlog.is_empty():
		return
	var batch: PackedStringArray = _backlog
	_backlog = PackedStringArray()
	if _log.get_paragraph_count() + batch.size() > MAX_LINES + 64:
		_log.clear()
		batch = _kept.slice(maxi(_kept.size() - MAX_LINES, 0))
	_log.append_text("\n".join(batch) + "\n")
	var extra: int = _log.get_paragraph_count() - MAX_LINES
	for _i in maxi(extra, 0):
		_log.remove_paragraph(0)

## The log keeps its place once you scroll up; End or reaching the
## bottom glues it to the newest line again.
func _on_scrolled(value: float) -> void:
	var bar := _log.get_v_scroll_bar()
	var at_bottom: bool = value >= bar.max_value - bar.page - 2.0
	if at_bottom != _following:
		_following = at_bottom
		_log.scroll_following = at_bottom

func _scroll_by(pages: float) -> void:
	var bar := _log.get_v_scroll_bar()
	bar.value = clampf(bar.value + pages * maxf(bar.page - 24.0, 24.0), 0.0, bar.max_value - bar.page)
	_on_scrolled(bar.value)

func _scroll_to_end() -> void:
	var bar := _log.get_v_scroll_bar()
	bar.value = bar.max_value - bar.page
	_following = true
	_log.scroll_following = true

## Tab: complete the command word. One match fills it in; several fill
## the common prefix and, on the second Tab, list them.
func _complete() -> void:
	var names: Array = []
	if handler != null:
		var v = handler.get("COMMAND_NAMES")
		if v is Array:
			names = v
	names = names + ["log", "clear"]
	var text: String = _line.text
	var word: String = text.split(" ", false)[0] if not text.strip_edges().is_empty() else ""
	if text.contains(" ") and text.strip_edges().find(" ") >= 0:
		return                                  # arguments are the command's business
	var matches: Array = []
	for n in names:
		if String(n).begins_with(word.to_lower()) and not matches.has(n):
			matches.append(n)
	matches.sort()
	if matches.is_empty():
		return
	if matches.size() == 1:
		_line.text = String(matches[0]) + " "
		_line.caret_column = _line.text.length()
		_tab_matches = []
		return
	# The common prefix of every match.
	var prefix: String = String(matches[0])
	for m in matches:
		var k: int = 0
		while k < prefix.length() and k < String(m).length() and prefix[k] == String(m)[k]:
			k += 1
		prefix = prefix.substr(0, k)
	if _tab_matches == matches and _tab_prefix == prefix:
		say("[color=#ffd27a]] %s[/color]" % word.replace("[", "[lb]"))
		say("  " + "  ".join(matches))
	_tab_matches = matches
	_tab_prefix = prefix
	_line.text = prefix
	_line.caret_column = prefix.length()

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
	PauseState.push(&"console")
	_flush()
	_scroll_to_end()
	_line.text = preset
	_line.grab_focus()
	_line.caret_column = preset.length()

func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	_line.release_focus()
	PauseState.pop(&"console")
	closed.emit()

## Append a (BBCode) line to the log — on the next frame the console is
## down. Text from outside (names, map data, typed input) must come with
## its "[" already escaped as "[lb]".
func say(text: String) -> void:
	_backlog.append(text)
	_kept.append(text)
	if _kept.size() > MAX_LINES * 2:
		_kept = _kept.slice(_kept.size() - MAX_LINES)
	if _backlog.size() > MAX_LINES * 2:
		_backlog = _backlog.slice(_backlog.size() - MAX_LINES)

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
	elif k.keycode == KEY_TAB:
		_complete()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_PAGEUP:
		_scroll_by(-1.0)
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_PAGEDOWN:
		_scroll_by(1.0)
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_HOME and k.ctrl_pressed:
		_log.get_v_scroll_bar().value = 0.0
		_on_scrolled(0.0)
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_END and k.ctrl_pressed:
		_scroll_to_end()
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
	say("[color=#ffd27a]] %s[/color]" % cmd.replace("[", "[lb]"))
	_scroll_to_end()
	if cmd == "log off" or cmd == "log on":
		echo_engine = cmd == "log on"
		_log_seq = Log.total
		say("engine output %s" % ("on" if echo_engine else "off"))
		return
	if cmd == "clear":
		_backlog.clear()
		_kept.clear()
		_log_seq = Log.total
		_log.clear()
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
