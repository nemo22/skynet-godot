## Main menu — recreates the original DOS front-end of
## The Terminator: Future Shock / SkyNET.
##
## The title screen (START.IMG) is the backdrop; its baked-in top bar —
## NEW GAME · LOAD · SAVE · OPTIONS · QUIT — is made clickable with
## transparent hotspots that highlight on hover.
##
## NEW GAME opens a Single Player / Network choice (network in turn
## offers Create Server / Join Client). OPTIONS holds a DEBUG TOOLS
## entry that opens the asset viewers.
##
## The chosen map is handed to the game through SkynetPaths.selected_map.

extends Control

const BSAReader  := preload("res://scripts/loaders/bsa_reader.gd")
const Palette    := preload("res://scripts/loaders/palette.gd")
const ImgFile    := preload("res://scripts/loaders/img_file.gd")
const GAME_SCENE := "res://scenes/main.tscn"

# START.IMG is 320x200; the menu bar occupies the top 17 rows. Hotspot
# x-ranges were measured from the menu-bar art (MAIN1.IMG).
const IMG_W: float = 320.0
const IMG_H: float = 200.0
const BAR_H: float = 17.0
const BAR_ITEMS: Array = [
	["NEW GAME",   0.0,  91.0],
	["LOAD",      91.0, 133.0],
	["SAVE",     133.0, 180.0],
	["OPTIONS",  180.0, 251.0],
	["QUIT",     251.0, 320.0],
]

# LOAD.IMG is 232x164 with 10 save-slot bars and a baked EXIT button.
# Slot / EXIT rects measured from the art, in image pixels.
const LOAD_SLOTS: int = 10
const LOAD_PANEL_SCALE: float = 3.0
const LOAD_SLOT_X: float = 12.0
const LOAD_SLOT_W: float = 208.0
const LOAD_SLOT_Y0: float = 17.0
const LOAD_SLOT_PITCH: float = 12.0
const LOAD_SLOT_H: float = 12.0
const LOAD_EXIT_RECT: Rect2 = Rect2(186, 147, 46, 17)

# OPTIONS.IMG is 198x123 with a baked CONTROLS / DETAIL / EXIT bottom bar.
const OPT_PANEL_SCALE: float = 3.0
const OPT_CONTROLS_RECT: Rect2 = Rect2(4, 105, 86, 16)
const OPT_DETAIL_RECT: Rect2 = Rect2(94, 105, 58, 16)
const OPT_EXIT_RECT: Rect2 = Rect2(156, 105, 42, 16)
const OPT_SOUND_RECT: Rect2 = Rect2(60, 26, 109, 6)    # SOUND slider track (inner)

# CONTROLS.IMG is 269x166 — the original CONTROL CONFIGURATION screen.
# Bind-box rects (image pixels) for the fly-camera actions the port uses;
# the remaining boxes (FIRE, JUMP-as-game, AUTOMAP …) stay unbound.
const CTL_PANEL_SCALE: float = 4.0
const CTL_BOXES: Dictionary = {
	"forward": Rect2(72, 24, 48, 11),    # FORWARD
	"back":    Rect2(72, 36, 48, 11),    # REVERSE
	"left":    Rect2(72, 72, 48, 11),    # SLIDE LEFT
	"right":   Rect2(72, 84, 48, 11),    # SLIDE RIGHT
	"sprint":  Rect2(198, 36, 48, 11),   # RUN
	"up":      Rect2(198, 48, 48, 11),   # JUMP
	"down":    Rect2(198, 60, 48, 11),   # CROUCH
}
const CTL_JOYSTICK_RECT: Rect2 = Rect2(4, 151, 76, 13)
const CTL_MOUSE_RECT: Rect2 = Rect2(89, 151, 53, 13)
const CTL_DEFAULT_RECT: Rect2 = Rect2(151, 151, 68, 13)
const CTL_EXIT_RECT: Rect2 = Rect2(224, 151, 44, 13)

# NETGAME1.IMG is 198x132 — the original NEW GAME dialog
# (MULTI-PLAYER / ONE PLAYER / TUTORIAL / FUTURE SHOCK / EXIT).
const NG_PANEL_SCALE: float = 4.0
const NG_MULTI_RECT: Rect2 = Rect2(6, 10, 186, 16)
const NG_ONE_RECT: Rect2 = Rect2(6, 35, 186, 16)
const NG_TUTORIAL_RECT: Rect2 = Rect2(6, 60, 186, 16)
const NG_FSHOCK_RECT: Rect2 = Rect2(6, 85, 186, 17)
const NG_EXIT_RECT: Rect2 = Rect2(154, 117, 44, 14)

# NETJOIN1.IMG is 198x80 — NEW GAME / JOIN GAME / EXIT.
const NJ_PANEL_SCALE: float = 4.0
const NJ_NEW_RECT: Rect2 = Rect2(8, 9, 182, 18)
const NJ_JOIN_RECT: Rect2 = Rect2(8, 34, 182, 18)
const NJ_EXIT_RECT: Rect2 = Rect2(154, 65, 44, 14)

# NETMENU1.IMG is 320x200 — the network game-setup screen (START / EXIT).
const NM_PANEL_SCALE: float = 3.2
const NM_START_RECT: Rect2 = Rect2(228, 144, 54, 18)
const NM_EXIT_RECT: Rect2 = Rect2(283, 145, 36, 16)

# DISPLAY dialog (opened from OPTIONS → DETAIL): resolution + window mode.
const DISPLAY_CFG: String = "user://display.cfg"
# Common resolutions across aspect ratios; _detect_resolutions() keeps
# only those matching the monitor's aspect and fitting on it.
const RES_CANDIDATES: Array = [
	Vector2i(1024, 768), Vector2i(1280, 720), Vector2i(1280, 800),
	Vector2i(1280, 960), Vector2i(1366, 768), Vector2i(1440, 900),
	Vector2i(1600, 900), Vector2i(1600, 1200), Vector2i(1680, 1050),
	Vector2i(1920, 1080), Vector2i(1920, 1200), Vector2i(2560, 1080),
	Vector2i(2560, 1440), Vector2i(2560, 1600), Vector2i(3440, 1440),
	Vector2i(3840, 2160),
]

var _maps: Array[String] = []
var _screen_main: Control = null
var _screen_newgame: Control = null
var _screen_netjoin: Control = null
var _screen_netmenu: Control = null
var _screen_load: Control = null
var _screen_options: Control = null
var _screen_controls: Control = null
var _screen_display: Control = null
var _screen_debug: Control = null
var _screen_maps: Control = null
var _god_btn: Button = null            # DEBUG TOOLS god-mode toggle
var _toast: Label = null

## Player script — accessed for its static `god_mode` flag so the debug
## screen can arm invincibility before a map loads.
const PlayerScript := preload("res://scripts/fly_camera.gd")
var _bar_buttons: Array[Button] = []
var _back_target: Dictionary = {}
# Key-rebinding state for the CONTROLS dialog.
var _rebinding_action: String = ""
var _rebind_labels: Dictionary = {}    # action -> Label showing the key
# DISPLAY dialog state.
var _disp_res: Vector2i = Vector2i(1280, 720)
var _disp_fullscreen: bool = false
var _res_buttons: Array[Button] = []
var _mode_buttons: Array[Button] = []
# Cached generated teal-metal panel style (built on first use).
var _panel_sb: StyleBoxTexture = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var ss := get_node_or_null("/root/SceneSwitcher")
	if ss != null and ss.has_method("set_hud_visible"):
		ss.set_hud_visible(false)
	Audio.stop_ambient()
	_scan_maps()
	if SkynetPaths.selected_map == "" and not _maps.is_empty():
		SkynetPaths.selected_map = "MAP.210" if _maps.has("MAP.210") else _maps[0]
	_apply_display_settings()
	_build()
	_maybe_import()

## First start (or `--import` on the command line): convert the game
## data into the asset cache behind a progress overlay. `--import`
## quits afterwards so the conversion can run from a script.
func _maybe_import() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	# `--map=MAP.213`: skip the menu and start the game on that map.
	for a in args:
		if a.begins_with("--map="):
			SkynetPaths.selected_map = a.substr(6).strip_edges().to_upper()
			# _ready is still adding children — switch scenes afterwards.
			get_tree().change_scene_to_file.call_deferred(GAME_SCENE)
			return
	if not Assets.enabled:
		return
	var forced: bool = "--import" in args
	# `--map-scene=MAP.210`: build one editor map scene and quit.
	for a in args:
		if a.begins_with("--map-scene="):
			var p: String = Assets.map_scene(a.substr(12).strip_edges())
			print("[menu] map scene: %s" % (p if not p.is_empty() else "FAILED"))
			get_tree().quit(0 if not p.is_empty() else 1)
			return
	if not forced and DirAccess.dir_exists_absolute(Assets.root + "/mesh"):
		return
	# No original data found (exported build without a bundled copy):
	# ask for the game's directory and remember it.
	if not SkynetPaths._has_data(SkynetPaths.gamedata_dir):
		if DisplayServer.get_name() == "headless":
			push_error("[menu] original game data not found — pass --gamedata=<dir>")
			if forced:
				get_tree().quit(1)
			return
		var dlg := FileDialog.new()
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.title = "Select the SkyNET game directory (contains MDMDMAP2.BSA)"
		dlg.size = Vector2i(720, 480)
		add_child(dlg)
		dlg.popup_centered()
		var dir: String = await dlg.dir_selected
		dlg.queue_free()
		if not SkynetPaths.set_gamedata_dir(dir):
			push_error("[menu] %s has no game data" % dir)
			return
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.88)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.text = "Converting game data for first use..."
	layer.add_child(lbl)
	await get_tree().process_frame
	await Assets.import_all(func(done: int, total: int, item: String) -> void:
		lbl.text = "Converting game data for first use...
%d / %d
%s" % [done, total, item])
	layer.queue_free()
	if forced:
		get_tree().quit()

func _scan_maps() -> void:
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDMAP2.BSA"), SkynetPaths.variant):
		push_error("[menu] cannot open MDMDMAP2.BSA")
		return
	for e in bsa.entries():
		if e.name.to_upper().begins_with("MAP."):
			_maps.append(e.name.to_upper())
	bsa.close()
	_maps.sort_custom(func(a, b): return _suffix(a) < _suffix(b))
	print("[menu] %d maps available" % _maps.size())

static func _suffix(n: String) -> int:
	var p := n.split(".")
	return int(p[1]) if p.size() > 1 else -1

# --- image loading ----------------------------------------------------

## Load the menu art (START.IMG title screen, OPTIONS.IMG panel) from
## MDMDIMGS.BSA. Returns {"START": ImageTexture, "OPTIONS": ImageTexture}.
func _load_images() -> Dictionary:
	var out: Dictionary = {}
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
		push_error("[menu] cannot open MDMDIMGS.BSA")
		return out
	# SkyNET title screen (SKYNTRMP.IMG) — unlike FutureShock's START.IMG
	# it carries no baked menu bar, so MAIN1.IMG is overlaid separately.
	var title_pal := Palette.parse(imgs.read("SKYNTRMP.COL"))
	out["TITLE"] = ImgFile.parse(imgs.read("SKYNTRMP.IMG"), title_pal)
	var menu_pal := Palette.parse(imgs.read("MENU.COL"))
	out["BAR"] = ImgFile.parse(imgs.read("MAIN1.IMG"), menu_pal)
	out["OPTIONS"] = ImgFile.parse(imgs.read("OPTIONS.IMG"), menu_pal)
	out["LOAD"] = ImgFile.parse(imgs.read("LOAD.IMG"), menu_pal)
	out["CONTROLS"] = ImgFile.parse(imgs.read("CONTROLS.IMG"), menu_pal)
	out["NEWGAME"] = ImgFile.parse(imgs.read("NETGAME1.IMG"), menu_pal)
	out["NETJOIN"] = ImgFile.parse(imgs.read("NETJOIN1.IMG"), menu_pal)
	out["NETMENU"] = ImgFile.parse(imgs.read("NETMENU1.IMG"), menu_pal)
	imgs.close()
	return out

# --- UI construction --------------------------------------------------

func _build() -> void:
	var art := _load_images()

	# Title-screen backdrop, kept behind every screen.
	var bg := TextureRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if art.get("TITLE") != null:
		bg.texture = art["TITLE"]
	else:
		var fill := ColorRect.new()
		fill.color = Color(0.05, 0.05, 0.08)
		fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(fill)
	add_child(bg)

	# Menu-bar strip (MAIN1.IMG) across the top.
	if art.get("BAR") != null:
		var bar := TextureRect.new()
		bar.texture = art["BAR"]
		bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bar.stretch_mode = TextureRect.STRETCH_SCALE
		bar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.anchor_right = 1.0
		bar.anchor_bottom = BAR_H / IMG_H
		add_child(bar)

	_screen_main = _build_main_screen()
	_screen_newgame = _build_newgame_screen(art.get("NEWGAME"))
	_screen_netjoin = _build_netjoin_screen(art.get("NETJOIN"))
	_screen_netmenu = _build_netmenu_screen(art.get("NETMENU"))
	_screen_load = _build_load_screen(art.get("LOAD"))
	_screen_options = _build_options_screen(art.get("OPTIONS"))
	_screen_controls = _build_controls_screen(art.get("CONTROLS"))
	_screen_display = _build_display_screen()
	_screen_debug = _build_debug_screen()
	_screen_maps = _build_maps_screen()
	for s in _all_screens():
		add_child(s)

	# ESC navigation: each sub-screen steps back one level.
	_back_target = {
		_screen_newgame:  _screen_main,
		_screen_netjoin:  _screen_newgame,
		_screen_netmenu:  _screen_netjoin,
		_screen_load:     _screen_main,
		_screen_options:  _screen_main,
		_screen_controls: _screen_options,
		_screen_display:  _screen_options,
		_screen_debug:    _screen_options,
		_screen_maps:     _screen_debug,
	}

	_build_toast()
	resized.connect(_layout_bar)
	_layout_bar()
	_show_screen(_screen_main)

func _all_screens() -> Array:
	return [_screen_main, _screen_newgame, _screen_netjoin, _screen_netmenu,
		_screen_load, _screen_options, _screen_controls,
		_screen_display, _screen_debug, _screen_maps]

## Main screen — transparent hotspots over the START.IMG menu bar.
func _build_main_screen() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_buttons.clear()
	for it in BAR_ITEMS:
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		_style_hotspot(b)
		var label: String = it[0]
		b.pressed.connect(func() -> void: _on_bar_item(label))
		root.add_child(b)
		_bar_buttons.append(b)
	var hint := Label.new()
	hint.text = "Future Shock / SkyNET  —  Godot Port"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -34.0
	hint.offset_bottom = -8.0
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.55, 0.6, 0.62))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hint)
	return root

func _layout_bar() -> void:
	var sx := size.x / IMG_W
	var sy := size.y / IMG_H
	for i in _bar_buttons.size():
		var it: Array = BAR_ITEMS[i]
		var b := _bar_buttons[i]
		b.position = Vector2(float(it[1]) * sx, 0.0)
		b.size = Vector2((float(it[2]) - float(it[1])) * sx, BAR_H * sy)

## NEW GAME — the original NETGAME1.IMG dialog. MULTI-PLAYER opens the
## network screen, ONE PLAYER / FUTURE SHOCK start the game, EXIT returns.
func _build_newgame_screen(newgame_tex: Variant) -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var s := NG_PANEL_SCALE
	var panel := Control.new()
	panel.custom_minimum_size = Vector2(198.0 * s, 132.0 * s)
	center.add_child(panel)

	if newgame_tex != null:
		var pic := TextureRect.new()
		pic.texture = newgame_tex
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(pic)
	else:
		panel.add_child(_heading("NEW GAME"))

	panel.add_child(_img_hotspot(NG_MULTI_RECT, s,
		func() -> void: _show_screen(_screen_netjoin)))
	# ONE PLAYER drops straight into the game; main.gd shows the proper
	# in-game mission briefing once the campaign's first map has loaded.
	panel.add_child(_img_hotspot(NG_ONE_RECT, s,
		func() -> void: _on_map_chosen(_first_campaign_map())))
	# TUTORIAL and FUTURE SHOCK are intentionally inert for now.
	panel.add_child(_img_hotspot(NG_EXIT_RECT, s,
		func() -> void: _show_screen(_screen_main)))
	return root

## A dimmed screen with a centred fixed-size panel hosting DOS .IMG art.
## Returns [root, panel]; absolute-positioned hotspots go on `panel`.
func _img_panel(tex: Variant, iw: float, ih: float, scale: float) -> Array:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var panel := Control.new()
	panel.custom_minimum_size = Vector2(iw * scale, ih * scale)
	center.add_child(panel)
	if tex != null:
		var pic := TextureRect.new()
		pic.texture = tex
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(pic)
	return [root, panel]

## MULTI-PLAYER — NETJOIN1.IMG: NEW GAME hosts, JOIN GAME browses servers.
func _build_netjoin_screen(tex: Variant) -> Control:
	var pair := _img_panel(tex, 198.0, 80.0, NJ_PANEL_SCALE)
	var panel: Control = pair[1]
	var s := NJ_PANEL_SCALE
	panel.add_child(_img_hotspot(NJ_NEW_RECT, s,
		func() -> void: _show_screen(_screen_netmenu)))
	panel.add_child(_img_hotspot(NJ_JOIN_RECT, s,
		func() -> void: _show_toast("Server browser — coming soon.")))
	panel.add_child(_img_hotspot(NJ_EXIT_RECT, s,
		func() -> void: _show_screen(_screen_newgame)))
	return pair[0]

## NETMENU1.IMG — network game-setup screen. START hosts (stub), EXIT back.
func _build_netmenu_screen(tex: Variant) -> Control:
	var pair := _img_panel(tex, 320.0, 200.0, NM_PANEL_SCALE)
	var panel: Control = pair[1]
	var s := NM_PANEL_SCALE
	panel.add_child(_img_hotspot(NM_START_RECT, s,
		func() -> void: _show_toast("Hosting a server is not implemented yet.")))
	panel.add_child(_img_hotspot(NM_EXIT_RECT, s,
		func() -> void: _show_screen(_screen_netjoin)))
	return pair[0]

## The first single-player campaign map. The campaign proper starts at
## MAP.210 — the MAP.200..202 series below it are not single-player
## missions. Falls back to the next "main" map (suffix >= 210, ending in
## 0), then to whatever map is first.
func _first_campaign_map() -> String:
	if _maps.has("MAP.210"):
		return "MAP.210"
	for m in _maps:
		var sfx := _suffix(m)
		if sfx >= 210 and sfx % 10 == 0:
			return m
	return _maps[0] if not _maps.is_empty() else "MAP.210"

## LOAD GAME — the original LOAD.IMG panel with 10 save slots.
## Every slot is empty until a save system exists; clicking one just
## reports it as empty. The baked-in EXIT button returns to the menu.
func _build_load_screen(load_tex: Variant) -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var s := LOAD_PANEL_SCALE
	var panel := Control.new()
	panel.custom_minimum_size = Vector2(232.0 * s, 164.0 * s)
	center.add_child(panel)

	if load_tex != null:
		var pic := TextureRect.new()
		pic.texture = load_tex
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(pic)
	else:
		panel.add_child(_heading("LOAD GAME"))

	# 10 empty save slots — transparent hotspots over the LOAD.IMG bars.
	for i in LOAD_SLOTS:
		var slot := Button.new()
		slot.flat = true
		slot.focus_mode = Control.FOCUS_NONE
		_style_hotspot(slot)
		slot.position = Vector2(LOAD_SLOT_X * s,
			(LOAD_SLOT_Y0 + i * LOAD_SLOT_PITCH) * s)
		slot.size = Vector2(LOAD_SLOT_W * s, LOAD_SLOT_H * s)
		var idx: int = i
		slot.pressed.connect(func() -> void:
			_show_toast("Slot %d — empty (no saved game)." % (idx + 1)))
		panel.add_child(slot)

	# Baked-in EXIT button.
	var exit_b := Button.new()
	exit_b.flat = true
	exit_b.focus_mode = Control.FOCUS_NONE
	_style_hotspot(exit_b)
	exit_b.position = LOAD_EXIT_RECT.position * s
	exit_b.size = LOAD_EXIT_RECT.size * s
	exit_b.pressed.connect(func() -> void: _show_screen(_screen_main))
	panel.add_child(exit_b)
	return root

## OPTIONS — the original OPTIONS.IMG panel. Its baked CONTROLS / DETAIL
## / EXIT bottom-bar buttons are live hotspots: CONTROLS opens the
## key-rebinding dialog, EXIT returns to the menu (so no separate BACK
## button is needed). DEBUG TOOLS sits just below the panel.
func _build_options_screen(options_tex: Variant) -> Control:
	var pair := _panel_screen()
	var vb: VBoxContainer = pair[1]
	var s := OPT_PANEL_SCALE

	var panel := Control.new()
	panel.custom_minimum_size = Vector2(198.0 * s, 123.0 * s)
	vb.add_child(panel)

	if options_tex != null:
		var pic := TextureRect.new()
		pic.texture = options_tex
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(pic)
	else:
		panel.add_child(_heading("OPTIONS"))

	panel.add_child(_img_hotspot(OPT_CONTROLS_RECT, s,
		func() -> void: _show_screen(_screen_controls)))
	panel.add_child(_img_hotspot(OPT_DETAIL_RECT, s,
		func() -> void: _show_screen(_screen_display)))
	panel.add_child(_img_hotspot(OPT_EXIT_RECT, s,
		func() -> void: _show_screen(_screen_main)))

	# Interactive SOUND volume over the baked OPTIONS.IMG slider track.
	var vol: Control = preload("res://scripts/volume_slider.gd").new()
	vol.position = OPT_SOUND_RECT.position * s
	vol.size = OPT_SOUND_RECT.size * s
	panel.add_child(vol)

	vb.add_child(_spacer(8))
	vb.add_child(_menu_button("DEBUG TOOLS",
		func() -> void: _show_screen(_screen_debug)))
	return pair[0]

## CONTROLS — the original CONTROL CONFIGURATION screen (CONTROLS.IMG).
## The bind boxes for the fly-camera actions show their key and rebind
## on click; DEFAULT resets, EXIT returns (see controls.gd autoload).
func _build_controls_screen(controls_tex: Variant) -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var s := CTL_PANEL_SCALE
	var panel := Control.new()
	panel.custom_minimum_size = Vector2(269.0 * s, 166.0 * s)
	center.add_child(panel)

	if controls_tex != null:
		var pic := TextureRect.new()
		pic.texture = controls_tex
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(pic)
	else:
		panel.add_child(_heading("CONTROL CONFIGURATION"))

	# Rebindable bind boxes — key label + transparent hotspot per action.
	for action in CTL_BOXES:
		var r: Rect2 = CTL_BOXES[action]
		var lbl := Label.new()
		lbl.text = Controls.key_label(action)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.position = r.position * s
		lbl.size = r.size * s
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", Color(0.55, 1.0, 0.65))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(lbl)
		_rebind_labels[action] = lbl
		var a: String = action
		panel.add_child(_img_hotspot(r, s, func() -> void: _begin_rebind(a)))

	# Bottom-bar buttons.
	panel.add_child(_img_hotspot(CTL_DEFAULT_RECT, s, _on_reset_controls))
	panel.add_child(_img_hotspot(CTL_EXIT_RECT, s, _on_controls_back))
	panel.add_child(_img_hotspot(CTL_JOYSTICK_RECT, s,
		func() -> void: _show_toast("Joystick configuration is not implemented.")))
	panel.add_child(_img_hotspot(CTL_MOUSE_RECT, s,
		func() -> void: _show_toast("Mouse configuration is not implemented.")))
	return root

## A transparent hotspot button placed over baked art, at `rect`
## (image pixels) scaled by `s`.
func _img_hotspot(rect: Rect2, s: float, cb: Callable) -> Button:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	_style_hotspot(b)
	b.position = rect.position * s
	b.size = rect.size * s
	b.pressed.connect(cb)
	b.pressed.connect(func() -> void: Audio.play_sfx("BUTTON1.RAW"))
	return b

## DISPLAY — resolution and window-mode settings (OPTIONS → DETAIL).
func _build_display_screen() -> Control:
	var pair := _framed_panel()
	var vb: VBoxContainer = pair[1]
	vb.add_child(_heading("DISPLAY"))

	vb.add_child(_section_label("Resolution"))
	_res_buttons.clear()
	for res in _detect_resolutions():
		var r: Vector2i = res
		var rb := _option_button("", func() -> void: _set_resolution(r))
		rb.set_meta("res", r)
		_res_buttons.append(rb)
		vb.add_child(rb)

	vb.add_child(_section_label("Window Mode"))
	var modes := HBoxContainer.new()
	modes.alignment = BoxContainer.ALIGNMENT_CENTER
	modes.add_theme_constant_override("separation", 14)
	_mode_buttons.clear()
	for m in [["FULLSCREEN", true], ["WINDOWED", false]]:
		var fs: bool = m[1]
		var mb := _option_button(m[0], func() -> void: _set_fullscreen(fs))
		mb.custom_minimum_size = Vector2(210, 48)
		mb.set_meta("fs", fs)
		_mode_buttons.append(mb)
		modes.add_child(mb)
	vb.add_child(modes)

	vb.add_child(_spacer(4))
	vb.add_child(_menu_button("BACK", func() -> void: _show_screen(_screen_options)))
	_refresh_display_marks()
	return pair[0]

## Resolutions for the DISPLAY dialog: common sizes matching the
## monitor's aspect ratio and fitting within its native resolution,
## plus the native resolution itself.
func _detect_resolutions() -> Array:
	var screen: Vector2i = DisplayServer.screen_get_size(
		DisplayServer.window_get_current_screen())
	if screen.x <= 0 or screen.y <= 0:
		screen = Vector2i(1920, 1080)
	var aspect := float(screen.x) / float(screen.y)
	var out: Array = []
	for r in RES_CANDIDATES:
		var ra := float(r.x) / float(r.y)
		if absf(ra - aspect) < 0.06 and r.x <= screen.x and r.y <= screen.y:
			out.append(r)
	if not out.has(screen):
		out.append(screen)          # always offer the native resolution
	out.sort_custom(func(a, b): return (a as Vector2i).x < (b as Vector2i).x)
	return out

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 19)
	l.add_theme_color_override("font_color", Color(0.62, 0.65, 0.7))
	return l

## Mark the active resolution / mode button with a leading caret.
func _refresh_display_marks() -> void:
	for rb in _res_buttons:
		var r: Vector2i = rb.get_meta("res")
		var on: bool = (not _disp_fullscreen) and r == _disp_res
		rb.text = "%s%d x %d" % ["> " if on else "", r.x, r.y]
	for mb in _mode_buttons:
		var fs: bool = mb.get_meta("fs")
		var nm: String = "FULLSCREEN" if fs else "WINDOWED"
		mb.text = ("> " if fs == _disp_fullscreen else "") + nm

func _set_resolution(r: Vector2i) -> void:
	_disp_res = r
	_disp_fullscreen = false
	_apply_window(false, r)
	_save_display()
	_refresh_display_marks()
	_show_toast("Resolution: %d x %d" % [r.x, r.y])

func _set_fullscreen(fs: bool) -> void:
	_disp_fullscreen = fs
	_apply_window(fs, _disp_res)
	_save_display()
	_refresh_display_marks()
	_show_toast("Fullscreen" if fs else "Windowed mode")

## Apply window mode/size. No-op on mobile (always fullscreen there).
func _apply_window(fs: bool, res: Vector2i) -> void:
	if OS.has_feature("mobile"):
		return
	var win := get_window()
	if win == null:
		return
	if fs:
		win.mode = Window.MODE_FULLSCREEN
	else:
		win.mode = Window.MODE_WINDOWED
		win.size = res
		win.move_to_center()

func _apply_display_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(DISPLAY_CFG) != OK:
		return
	_disp_res = Vector2i(
		int(cfg.get_value("display", "width", 1280)),
		int(cfg.get_value("display", "height", 720)))
	_disp_fullscreen = bool(cfg.get_value("display", "fullscreen", false))
	_apply_window(_disp_fullscreen, _disp_res)

func _save_display() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "width", _disp_res.x)
	cfg.set_value("display", "height", _disp_res.y)
	cfg.set_value("display", "fullscreen", _disp_fullscreen)
	cfg.save(DISPLAY_CFG)

## DEBUG TOOLS — launches the asset viewers.
func _build_debug_screen() -> Control:
	var pair := _framed_panel()
	var vb: VBoxContainer = pair[1]
	vb.add_child(_heading("DEBUG TOOLS"))
	vb.add_child(_spacer(6))
	vb.add_child(_menu_button("TEXTURE ATLAS",
		func() -> void: _launch("res://scenes/atlas_viewer.tscn")))
	vb.add_child(_menu_button("3D OBJECT VIEWER",
		func() -> void: _launch("res://scenes/object_viewer.tscn")))
	vb.add_child(_menu_button("ENEMY VIEWER",
		func() -> void: _launch("res://scenes/enemy_viewer.tscn")))
	vb.add_child(_menu_button("SOUND VIEWER",
		func() -> void: _launch("res://scenes/sound_viewer.tscn")))
	vb.add_child(_menu_button("MAP VIEWER",
		func() -> void: _show_screen(_screen_maps)))
	vb.add_child(_spacer(6))
	# Invincibility toggle for testing — persists into the loaded map.
	_god_btn = _menu_button(_god_label(), _toggle_god_mode)
	vb.add_child(_god_btn)
	vb.add_child(_spacer(6))
	vb.add_child(_menu_button("BACK", func() -> void: _show_screen(_screen_options)))
	return pair[0]

func _god_label() -> String:
	return "GOD MODE: %s  (F9)" % ("ON" if PlayerScript.god_mode else "OFF")

func _toggle_god_mode() -> void:
	PlayerScript.god_mode = not PlayerScript.god_mode
	if _god_btn != null:
		_god_btn.text = _god_label()

## MAP VIEWER — pick any map and load it in the game scene.
func _build_maps_screen() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 70.0
	vb.offset_right = -70.0
	vb.offset_top = 40.0
	vb.offset_bottom = -40.0
	vb.add_theme_constant_override("separation", 14)
	root.add_child(vb)

	vb.add_child(_heading("MAP VIEWER"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	var grid := GridContainer.new()
	grid.columns = 6
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(grid)
	for m in _maps:
		var mb := Button.new()
		mb.text = m.trim_prefix("MAP.")
		mb.custom_minimum_size = Vector2(0, 54)
		mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mb.add_theme_font_size_override("font_size", 20)
		mb.focus_mode = Control.FOCUS_NONE
		_style_button(mb)
		var mname: String = m
		mb.pressed.connect(func() -> void: _on_map_chosen(mname))
		grid.add_child(mb)

	var back := _menu_button("BACK", func() -> void: _show_screen(_screen_debug))
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(back)
	return root

# --- helpers ----------------------------------------------------------

## A dimmed full-screen screen with a properly CENTERED VBox.
## Returns [root_control, vbox].
func _panel_screen() -> Array:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vb)
	return [root, vb]

## A dimmed screen with a centred, bordered dialog panel — the framed
## look used by every non-DOS-art dialog. Returns [root_control, vbox].
func _framed_panel() -> Array:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var frame := PanelContainer.new()
	frame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	frame.add_theme_stylebox_override("panel", _get_panel_style())
	center.add_child(frame)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	frame.add_child(vb)
	return [root, vb]

## Generate (once) a 9-patch panel that reproduces the original DOS
## dialog art: a per-pixel mottle of four teal shades sampled from
## CONTROLS.IMG, a top edge that catches the light, and the other three
## edges in shadow with a dark outline — exactly how the XnGine panels
## are drawn.
func _get_panel_style() -> StyleBoxTexture:
	if _panel_sb != null:
		return _panel_sb
	const W := 160
	const H := 160
	const BV := 14
	# Field shades sampled from CONTROLS.IMG, weighted by frequency.
	var field: Array = [
		Color8(63, 83, 83), Color8(63, 83, 83), Color8(63, 83, 83),
		Color8(63, 83, 83), Color8(63, 83, 83),
		Color8(59, 75, 79), Color8(59, 75, 79), Color8(59, 75, 79),
		Color8(67, 95, 99), Color8(67, 95, 99),
		Color8(51, 63, 67),
	]
	var img := Image.create_empty(W, H, false, Image.FORMAT_RGB8)
	for y in H:
		for x in W:
			var dt: int = y
			var d: int = mini(mini(x, y), mini(W - 1 - x, H - 1 - y))
			var c: Color = field[randi() % field.size()]
			if dt == d and dt <= 6:
				# Top edge — lit highlight fading into the field.
				c = Color8(118, 150, 154) if dt <= 3 else Color8(84, 118, 120)
			elif d == 0:
				c = Color8(40, 48, 48)               # dark outline (L/R/B)
			elif d <= 4:
				# Left / right / bottom edges — shadow.
				c = Color8(48, 57, 60) if d <= 2 else Color8(54, 68, 71)
			img.set_pixel(x, y, c)
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	sb.set_texture_margin_all(BV)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.content_margin_left = 44.0
	sb.content_margin_right = 44.0
	sb.content_margin_top = 34.0
	sb.content_margin_bottom = 34.0
	_panel_sb = sb
	return sb

## A compact option button (resolution / mode rows in the DISPLAY dialog).
func _option_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(340, 44)
	b.add_theme_font_size_override("font_size", 22)
	b.focus_mode = Control.FOCUS_NONE
	_style_button(b)
	b.pressed.connect(cb)
	return b

func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 38)
	l.add_theme_color_override("font_color", Color(0.82, 0.84, 0.88))
	return l

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s

func _menu_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(360, 58)
	b.add_theme_font_size_override("font_size", 24)
	b.focus_mode = Control.FOCUS_NONE
	_style_button(b)
	b.pressed.connect(cb)
	return b

## Teal recessed-metal button styling, matching the generated panel.
func _style_button(b: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color8(42, 56, 56)
	normal.border_color = Color8(96, 128, 128)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(3)
	normal.content_margin_left = 12.0
	normal.content_margin_right = 12.0
	normal.content_margin_top = 9.0
	normal.content_margin_bottom = 9.0
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color8(66, 92, 92)
	hover.border_color = Color8(150, 192, 192)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color8(28, 38, 38)
	pressed.border_color = Color8(80, 108, 108)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal)
	b.add_theme_color_override("font_color", Color8(206, 222, 222))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color8(150, 175, 175))
	b.pressed.connect(func() -> void: Audio.play_sfx("BUTTON1.RAW"))

## Transparent hotspot button — invisible until hovered/pressed, so the
## START.IMG bar text shows through.
func _style_hotspot(b: Button) -> void:
	var empty := StyleBoxEmpty.new()
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(1, 1, 1, 0.22)
	var pressed := StyleBoxFlat.new()
	pressed.bg_color = Color(0.9, 0.3, 0.2, 0.35)
	b.add_theme_stylebox_override("normal", empty)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", empty)

func _build_toast() -> void:
	_toast = Label.new()
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_toast.offset_top = -96.0
	_toast.offset_bottom = -56.0
	_toast.add_theme_font_size_override("font_size", 22)
	_toast.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_toast.add_theme_constant_override("outline_size", 5)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	add_child(_toast)

func _show_toast(msg: String) -> void:
	_toast.text = msg
	_toast.visible = true
	var tm := get_tree().create_timer(2.4)
	tm.timeout.connect(func() -> void:
		if is_instance_valid(_toast):
			_toast.visible = false)

func _show_screen(s: Control) -> void:
	_cancel_rebind()
	for scr in _all_screens():
		if scr != null:
			scr.visible = scr == s

# --- key rebinding ----------------------------------------------------

func _begin_rebind(action: String) -> void:
	_cancel_rebind()
	_rebinding_action = action
	var l: Label = _rebind_labels.get(action)
	if l != null:
		l.text = "...?"

func _cancel_rebind() -> void:
	if _rebinding_action == "":
		return
	var l: Label = _rebind_labels.get(_rebinding_action)
	if l != null:
		l.text = Controls.key_label(_rebinding_action)
	_rebinding_action = ""

func _on_reset_controls() -> void:
	_cancel_rebind()
	Controls.reset_defaults()
	for action in _rebind_labels:
		_rebind_labels[action].text = Controls.key_label(action)
	_show_toast("Controls reset to defaults.")

func _on_controls_back() -> void:
	_cancel_rebind()
	_show_screen(_screen_options)

# --- input / actions --------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# While the CONTROLS dialog is waiting, the next key is the new bind.
	if _rebinding_action != "":
		if event.keycode != KEY_ESCAPE:
			Controls.set_bind(_rebinding_action, event.keycode)
		var rl: Label = _rebind_labels.get(_rebinding_action)
		if rl != null:
			rl.text = Controls.key_label(_rebinding_action)
		_rebinding_action = ""
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_ESCAPE:
		if _screen_main != null and _screen_main.visible:
			get_tree().quit()
		else:
			for scr in _all_screens():
				if scr != null and scr.visible and _back_target.has(scr):
					_show_screen(_back_target[scr])
					break
		get_viewport().set_input_as_handled()

func _on_bar_item(label: String) -> void:
	match label:
		"NEW GAME":
			_show_screen(_screen_newgame)
		"LOAD":
			_show_screen(_screen_load)
		"SAVE":
			_show_toast("Saving is available in-game.")
		"OPTIONS":
			_show_screen(_screen_options)
		"QUIT":
			get_tree().quit()

func _on_map_chosen(m: String) -> void:
	SkynetPaths.selected_map = m
	_launch(GAME_SCENE)

func _launch(scene_path: String) -> void:
	var ss := get_node_or_null("/root/SceneSwitcher")
	if ss != null and ss.has_method("set_hud_visible"):
		ss.set_hud_visible(true)
	get_tree().change_scene_to_file(scene_path)
