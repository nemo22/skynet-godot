## In-game menu on Esc. The level stays loaded underneath (the tree is
## paused); only MAIN MENU drops it. Pages: main, SAVE GAME (10
## slots), LOAD GAME, CHEATS (the DOS CHEAT.PRS codes as buttons plus a
## code line — all routed through main.run_command).
extends CanvasLayer

signal closed

const SaveGame := preload("res://scripts/save_game.gd")

var game: Node = null                  # main.gd
var is_open: bool = false

var _root: Control = null
var _pages: Dictionary = {}            # name → Control
var _page: String = "main"
var _slot_buttons: Dictionary = {}     # "save"/"load" → Array[Button]
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
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	_pages["main"] = _build_main()
	_pages["save"] = _build_slots("SAVE GAME", "save")
	_pages["load"] = _build_slots("LOAD GAME", "load")
	_pages["options"] = _build_options()
	_pages["controls"] = _build_controls()
	_pages["cheats"] = _build_cheats()
	for p in _pages.values():
		_root.add_child(p)

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

func _input(event: InputEvent) -> void:
	if _binding != "":
		var pressed: bool = (event is InputEventKey and event.pressed and not event.echo) \
			or (event is InputEventMouseButton and event.pressed)
		if not pressed:
			return
		var esc: bool = event is InputEventKey \
			and (event as InputEventKey).keycode == KEY_ESCAPE
		if not esc:
			var code: int = Controls.code_for(event)
			if code != 0:
				Controls.set_bind(_binding, code)
		_binding = ""
		_refresh_binds()
		get_viewport().set_input_as_handled()
		return
	if not is_open or not (event is InputEventKey and event.pressed and not event.echo):
		return
	if (event as InputEventKey).keycode == KEY_ESCAPE:
		if _cheat_line != null and _cheat_line.has_focus():
			_cheat_line.release_focus()
		if _page == "main":
			close()
		else:
			_show("main")
		get_viewport().set_input_as_handled()

func _show(name: String) -> void:
	_page = name
	for k in _pages:
		(_pages[k] as Control).visible = k == name
	if name == "save" or name == "load":
		_refresh_slots(name)
	elif name == "cheats":
		_refresh_cheats()
	Audio.play_sfx("BUTTON1.RAW")

# --- widgets -------------------------------------------------------------

func _page_box(title: String) -> Array:
	var page := Control.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 8)
	center.add_child(vb)
	var ttl := Label.new()
	ttl.text = title
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_size_override("font_size", 40)
	ttl.add_theme_color_override("font_color", Color(0.42, 0.92, 0.48))
	vb.add_child(ttl)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	vb.add_child(gap)
	return [page, vb]

func _button(text: String, cb: Callable, wide: float = 360.0, h: float = 46.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(wide, h)
	b.add_theme_font_size_override("font_size", 20)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _build_main() -> Control:
	var pv := _page_box("SKYNET")
	var vb: VBoxContainer = pv[1]
	vb.add_child(_button("RESUME", close))
	vb.add_child(_button("SAVE GAME", _show.bind("save")))
	vb.add_child(_button("LOAD GAME", _show.bind("load")))
	vb.add_child(_button("OPTIONS", _show.bind("options")))
	vb.add_child(_button("CONSOLE  (~)", func() -> void:
		close()
		if game != null and game.has_method("open_console"):
			game.open_console()))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	vb.add_child(gap)
	vb.add_child(_button("MAIN MENU  (drops the level)", func() -> void:
		close()
		if game != null and game.has_method("_return_to_menu"):
			game._return_to_menu()))
	vb.add_child(_button("QUIT GAME", func() -> void: get_tree().quit()))
	return pv[0]

## --- OPTIONS, in game -------------------------------------------------
## The DOS game let you into the options from the in-game menu; the port
## only had them on the title screen, so nothing could be changed once a
## level was up (2026-09-04). Every row reads and writes the same
## autoloads the title screen uses, so the two never disagree.
var _opt_rows: Array = []              # refresh callables

func _build_options() -> Control:
	var pv := _page_box("OPTIONS")
	var vb: VBoxContainer = pv[1]
	_opt_row(vb, "SOUND", func() -> String: return _pct(Audio.master_volume),
		func(d: int) -> void: Audio.set_master_volume(
			snappedf(clampf(Audio.master_volume + 0.1 * d, 0.0, 1.0), 0.1)))
	_opt_row(vb, "MUSIC", func() -> String: return _pct(Audio.music_volume),
		func(d: int) -> void: Audio.set_music_volume(
			snappedf(clampf(Audio.music_volume + 0.1 * d, 0.0, 1.0), 0.1)))
	_opt_row(vb, "DIFFICULTY",
		func() -> String: return String(Settings.LEVEL_NAMES[Settings.difficulty]),
		func(d: int) -> void: Settings.set_difficulty(
			posmod(Settings.difficulty + d, 3)))
	_opt_row(vb, "DETAIL",
		func() -> String: return String(Settings.LEVEL_NAMES[Settings.detail]),
		func(d: int) -> void: Settings.set_detail(posmod(Settings.detail + d, 3)))
	_opt_row(vb, "RENDER",
		func() -> String: return "ENHANCED" if Render.enhanced() else "DOS",
		func(_d: int) -> void: Render.set_mode(
			Render.DOS if Render.enhanced() else Render.ENHANCED))
	_opt_row(vb, "RETRO RESOLUTION",
		func() -> String: return String(Settings.RES_NAMES[Settings.resolution]),
		func(d: int) -> void: Settings.set_resolution(
			posmod(Settings.resolution + d, 3)))
	_opt_row(vb, "WINDOW",
		func() -> String: return String(Settings.WINDOW_MODE_NAMES[Settings.window_mode]),
		func(d: int) -> void: Settings.set_window_mode(
			posmod(Settings.window_mode + d, 3)))
	_opt_row(vb, "WINDOW SIZE",
		func() -> String: return Settings.size_name(Settings.window_size),
		func(d: int) -> void: Settings.set_window_size(
			posmod(Settings.window_size + d, Settings.available_sizes().size())))
	_opt_row(vb, "WEAPON VIEW",
		func() -> String: return "3D MODEL" if Settings.weapon_3d else "DOS ART",
		func(_d: int) -> void: Settings.set_weapon_3d(not Settings.weapon_3d))
	_opt_row(vb, "MUSIC SOURCE",
		func() -> String: return "WAVETABLE" if Settings.wavetable else "SYNTH",
		func(_d: int) -> void: Settings.set_wavetable(not Settings.wavetable))
	_opt_row(vb, "REVERSE STEREO",
		func() -> String: return "ON" if Settings.reverse_stereo else "OFF",
		func(_d: int) -> void: Settings.set_reverse_stereo(not Settings.reverse_stereo))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	vb.add_child(gap)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 8)
	vb.add_child(bar)
	bar.add_child(_button("CONTROLS", _show.bind("controls"), 180.0, 40.0))
	bar.add_child(_button("CHEATS", _show.bind("cheats"), 150.0, 40.0))
	bar.add_child(_button("BACK", _show.bind("main"), 150.0, 40.0))
	return pv[0]

static func _pct(v: float) -> String:
	return "%d %%" % int(round(v * 100.0))

## A caption on the left and a value you step with < and >.
func _opt_row(parent: Control, caption: String, get_text: Callable,
		step: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var cap := Label.new()
	cap.text = caption
	cap.custom_minimum_size = Vector2(250.0, 32.0)
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 18)
	row.add_child(cap)
	var val := Label.new()
	val.custom_minimum_size = Vector2(170.0, 32.0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val.add_theme_font_size_override("font_size", 18)
	val.add_theme_color_override("font_color", Color(0.62, 0.95, 0.70))
	var refresh := func() -> void: val.text = String(get_text.call())
	row.add_child(_button("<", func() -> void:
		step.call(-1)
		_refresh_options(), 46.0, 32.0))
	row.add_child(val)
	row.add_child(_button(">", func() -> void:
		step.call(1)
		_refresh_options(), 46.0, 32.0))
	_opt_rows.append(refresh)
	refresh.call()

func _refresh_options() -> void:
	for r in _opt_rows:
		(r as Callable).call()

## --- CONTROLS, in game ------------------------------------------------
var _bind_labels: Dictionary = {}      # action -> Label
var _binding: String = ""

func _build_controls() -> Control:
	var pv := _page_box("CONTROLS")
	var vb: VBoxContainer = pv[1]
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 3)
	vb.add_child(grid)
	for entry in Controls.ACTIONS:
		var action: String = String(entry[0])
		var cap := Label.new()
		cap.text = String(entry[1])
		cap.custom_minimum_size = Vector2(150.0, 30.0)
		cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cap.add_theme_font_size_override("font_size", 16)
		grid.add_child(cap)
		var b := _button(Controls.key_label(action),
			func() -> void: _begin_bind(action), 190.0, 30.0)
		b.add_theme_font_size_override("font_size", 16)
		grid.add_child(b)
		_bind_labels[action] = b
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	vb.add_child(gap)
	var hint := Label.new()
	hint.text = "Click a binding, then press a key or a mouse button.  Esc cancels."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	vb.add_child(hint)
	vb.add_child(_button("DEFAULTS", func() -> void:
		Controls.reset_defaults()
		_refresh_binds()))
	vb.add_child(_button("BACK", _show.bind("options")))
	return pv[0]

func _begin_bind(action: String) -> void:
	_binding = action
	var b: Button = _bind_labels.get(action)
	if b != null:
		b.text = "...?"

func _refresh_binds() -> void:
	for a in _bind_labels:
		(_bind_labels[a] as Button).text = Controls.key_label(a)

func _build_slots(title: String, mode: String) -> Control:
	var pv := _page_box(title)
	var vb: VBoxContainer = pv[1]
	var list: Array = []
	for i in SaveGame.SLOTS:
		var idx: int = i
		var b := _button("", _on_slot.bind(mode, idx), 520.0, 36.0)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 18)
		vb.add_child(b)
		list.append(b)
	_slot_buttons[mode] = list
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	vb.add_child(gap)
	vb.add_child(_button("BACK", _show.bind("main")))
	return pv[0]

func _refresh_slots(mode: String) -> void:
	var list: Array = _slot_buttons.get(mode, [])
	for i in list.size():
		var info: String = SaveGame.info(i)
		var tag: String = "QUICK" if i == SaveGame.QUICK_SLOT else "%d" % (i + 1)
		var b: Button = list[i]
		b.text = "  %-5s  %s" % [tag, info if not info.is_empty() else "- empty -"]
		b.disabled = mode == "load" and info.is_empty()

func _on_slot(mode: String, idx: int) -> void:
	if game == null:
		return
	if mode == "save":
		if game.call("save_to_slot", idx):
			_refresh_slots("save")
	else:
		if SaveGame.exists(idx):
			close()
			game.call("load_from_slot", idx)

func _build_cheats() -> Control:
	var pv := _page_box("CHEATS")
	var vb: VBoxContainer = pv[1]
	for c in CHEATS:
		var cmd: String = c[1]
		var b := _button(String(c[0]), _cheat.bind(cmd), 440.0, 38.0)
		b.add_theme_font_size_override("font_size", 18)
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
	vb.add_child(_button("BACK", _show.bind("main")))
	return pv[0]

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
