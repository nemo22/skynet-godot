## In-game menu on Esc - the DOS one (Marek's DOSBox shot, 2026-09-11):
## MAIN2.IMG's RETURN / LOAD / SAVE / OPTIONS / QUIT bar over the
## darkened, frozen level, and the DOS art screens the title uses
## (LOAD.IMG, SAVE.IMG, OPTIONS.IMG -> CONTROLS.IMG / DETAIL.IMG,
## QUITMAIN.IMG). They are menu.gd in its in-game mode, so the two menus
## cannot drift apart; until 2026-09-11 this was a column of Godot
## buttons of its own. The level stays loaded underneath (the tree is
## paused); QUIT -> YES drops it for the title screen. The port's extras
## hang off OPTIONS: CHEATS (the DOS CHEAT.PRS codes as buttons plus a
## code line, all routed through main.run_command) and CONSOLE.
extends CanvasLayer

signal closed

const MenuScreens := preload("res://scripts/menu.gd")

var game: Node = null                  # main.gd
var is_open: bool = false

var _menu: Control = null              # menu.gd, in_game
var _cheats: Control = null
var _cheat_status: Label = null
var _cheat_line: LineEdit = null
var _cheat_toggles: Dictionary = {}    # command → Button (state shown in text)

## [label, command, is_toggle]
const CHEATS: Array = [
	["GOD MODE  (willnotstop)",      "willnotstop", true],
	["NOCLIP  (F8)",                 "noclip",      true],
	["ALL WEAPONS  (arnold)",        "arnold",      false],
	["SUPER UZI  (superuzi)",        "superuzi",    false],
	["FULL AMMO  (slugs)",           "slugs",       false],
	["FULL HEALTH + ARMOR  (surgery)", "surgery",   false],
	["NITROUS  (+50 % speed)",       "nitrous",     false],
	["NEXT LEVEL  (illbeback)",      "illbeback",   false],
	["SHOW ENEMIES  (showspawns)",   "showspawns",  false],
]

func _ready() -> void:
	layer = 80
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_menu = MenuScreens.new()
	_menu.in_game = true
	_menu.game = game
	_menu.return_requested.connect(close)
	_menu.load_requested.connect(func(slot: int) -> void:
		close()
		if game != null:
			game.call("load_from_slot", slot))
	_menu.quit_to_main_requested.connect(func() -> void:
		close()
		if game != null and game.has_method("_return_to_menu"):
			game._return_to_menu())
	_menu.cheats_requested.connect(_show.bind("cheats"))
	_menu.console_requested.connect(func() -> void:
		close()
		if game != null and game.has_method("open_console"):
			game.open_console())
	add_child(_menu)
	_cheats = _build_cheats()
	_cheats.visible = false
	add_child(_cheats)

func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	# A network match keeps running underneath (nobody else pauses).
	if Net.active:
		if game != null and is_instance_valid(game.get("player")):
			game.get("player").set("input_locked", true)
	else:
		get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show("main")

func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	if Net.active:
		var dm = game.get("_dm") if game != null else null
		if dm != null and is_instance_valid(game.get("player")) and not bool(dm.get("_dead_local")):
			game.get("player").set("input_locked", false)
	else:
		get_tree().paused = false
	closed.emit()

## Esc on the CHEATS page steps back to OPTIONS; everywhere else the DOS
## screens handle it themselves (menu.gd _unhandled_input: back one
## screen, and on the bar RETURN).
func _input(event: InputEvent) -> void:
	if not is_open or not _cheats.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		if _cheat_line != null and _cheat_line.has_focus():
			_cheat_line.release_focus()
		_show("options")
		get_viewport().set_input_as_handled()

## Open a page: "cheats" is this node's own; "main" (the bar), "load",
## "save", "options", "controls" and "detail" are menu.gd's.
func _show(page: String) -> void:
	_cheats.visible = page == "cheats"
	_menu.visible = page != "cheats"
	if page == "cheats":
		_refresh_cheats()
		Audio.play_sfx("BUTTON1.RAW")
	else:
		_menu.call("show_page", page)

# --- CHEATS --------------------------------------------------------------

func _build_cheats() -> Control:
	var page := Control.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 8)
	center.add_child(vb)
	var ttl := Label.new()
	ttl.text = "CHEATS"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_size_override("font_size", 40)
	ttl.add_theme_color_override("font_color", Color(0.42, 0.92, 0.48))
	vb.add_child(ttl)
	for c in CHEATS:
		var cmd: String = c[1]
		var b := _button(String(c[0]), _cheat.bind(cmd), 440.0, 38.0)
		vb.add_child(b)
		if bool(c[2]):
			_cheat_toggles[cmd] = b
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_cheat_line = LineEdit.new()
	_cheat_line.placeholder_text = "cheat code / console command"
	_cheat_line.custom_minimum_size = Vector2(330, 36)
	_cheat_line.text_submitted.connect(func(t: String) -> void:
		_cheat(t)
		_cheat_line.clear())
	row.add_child(_cheat_line)
	row.add_child(_button("ENTER", func() -> void:
		_cheat(_cheat_line.text)
		_cheat_line.clear(), 100.0, 36.0))
	vb.add_child(row)
	_cheat_status = Label.new()
	_cheat_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cheat_status.custom_minimum_size = Vector2(440, 30)
	_cheat_status.add_theme_color_override("font_color", Color(1, 0.86, 0.4))
	vb.add_child(_cheat_status)
	vb.add_child(_button("BACK", _show.bind("options"), 440.0, 46.0))
	return page

func _button(text: String, cb: Callable, wide: float, h: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(wide, h)
	b.add_theme_font_size_override("font_size", 18)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _cheat(cmd: String) -> void:
	cmd = cmd.strip_edges()
	if cmd.is_empty() or game == null or not game.has_method("run_command"):
		return
	var reply: String = String(game.call("run_command", cmd))
	if _cheat_status != null:
		_cheat_status.text = _strip_bb(reply)
	# A level change closes the menu (illbeback).
	if not is_open:
		return
	_refresh_cheats()

## Show the live state on the toggle buttons.
func _refresh_cheats() -> void:
	if game == null or not game.has_method("cheat_state"):
		return
	var st: Dictionary = game.call("cheat_state")
	for cmd in _cheat_toggles:
		var b: Button = _cheat_toggles[cmd]
		var on: bool = bool(st.get(cmd, false))
		var base: String = String(b.text).split("  [")[0]
		b.text = "%s  [%s]" % [base, "ON" if on else "OFF"]

static func _strip_bb(s: String) -> String:
	var r := RegEx.new()
	r.compile("\\[/?[a-z#=0-9 ]*\\]")
	return r.sub(s, "", true)
