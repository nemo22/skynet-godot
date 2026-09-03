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
const SaveGame   := preload("res://scripts/save_game.gd")
const FntFont    := preload("res://scripts/loaders/fnt_font.gd")
## FONT0003.FNT (8×8) ×2 — the DOS bitmap font for the NETMENU fields.
var _net_font: FontFile = null

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
# Slider tracks and buttons, measured off the art by scanning for the
# recessed boxes and the bevel edges.
const OPT_SOUND_RECT: Rect2 = Rect2(59, 25, 112, 8)     # SOUND slider track
const OPT_MUSIC_RECT: Rect2 = Rect2(59, 42, 112, 8)     # MUSIC slider track
const OPT_STEREO_RECT: Rect2 = Rect2(11, 69, 50, 28)    # REVERSE STEREO
## DIFFICULTY LEVEL — LOW / MED / HIGH (Settings.difficulty).
const OPT_DIFF_RECTS: Array = [
	Rect2(82, 75, 32, 18), Rect2(116, 75, 33, 18), Rect2(151, 75, 33, 18),
]

# DETAIL.IMG is 198x102 — the original RENDER DETAIL screen: a
# LOW / MED / HIGH row, a RESOLUTION row and EXIT. Rects measured off
# the art by finding the buttons' bevel edges.
const DET_PANEL_SCALE: float = 3.0
const DET_LEVEL_RECTS: Array = [
	Rect2(48, 28, 32, 18), Rect2(82, 28, 33, 18), Rect2(117, 28, 33, 18),
]
const DET_RES_RECTS: Array = [Rect2(34, 63, 60, 18), Rect2(103, 63, 60, 18)]
const DET_EXIT_RECT: Rect2 = Rect2(158, 86, 38, 14)

# CONTROLS.IMG is 269x166 — the original CONTROL CONFIGURATION screen.
# All 17 captions on the art are bindable (controls.gd ACTIONS).
const CTL_PANEL_SCALE: float = 4.0
const CTL_BOXES: Dictionary = {
	# Measured off CONTROLS.IMG (269x166) by scanning for the dark bind
	# boxes, so every caption on the art has a working box — the same 17
	# the DOS CONTROLS.DAT stores (+0x00..+0x43).
	"forward":     Rect2(77, 25, 48, 8),     # FORWARD
	"back":        Rect2(77, 37, 48, 8),     # REVERSE
	"turn_left":   Rect2(77, 49, 48, 8),     # TURN LEFT
	"turn_right":  Rect2(77, 61, 48, 8),     # TURN RIGHT
	"left":        Rect2(77, 73, 48, 8),     # SLIDE LEFT
	"right":       Rect2(77, 85, 48, 8),     # SLIDE RIGHT
	"fire":        Rect2(77, 102, 48, 8),    # FIRE
	"throw":       Rect2(77, 115, 48, 8),    # THROW/USE
	"activate":    Rect2(77, 128, 48, 8),    # ACTIVATE
	"slide":       Rect2(201, 25, 48, 8),    # SLIDE (strafe modifier)
	"sprint":      Rect2(201, 37, 48, 8),    # RUN
	"up":          Rect2(201, 49, 48, 8),    # JUMP
	"down":        Rect2(201, 61, 48, 8),    # CROUCH
	"look_up":     Rect2(201, 82, 48, 8),    # LOOK UP
	"look_down":   Rect2(201, 95, 48, 8),    # LOOK DOWN
	"center_view": Rect2(201, 108, 48, 8),   # CENTER VIEW
	"automap":     Rect2(201, 128, 48, 8),   # AUTOMAP
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
const NM_START_RECT: Rect2 = Rect2(214, 144, 63, 16)
const NM_EXIT_RECT: Rect2 = Rect2(280, 145, 39, 15)

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
## QUIT.IMG — the "QUIT TO DOS?" confirmation box (see _confirm_quit).
var _quit_art: Variant = null
var _screen_debug: Control = null
var _screen_maps: Control = null
var _god_btn: Button = null            # DEBUG TOOLS god-mode toggle
var _toast: Label = null
var _load_slot_buttons: Array[Button] = []   # LOAD.IMG slot hotspots

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
	Audio.play_music(Audio.TITLE_TRACK)
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
	# `--host=MAP.605 --bots=3 --name=X`: host a deathmatch straight away;
	# `--join=ip[:port]`: connect to one (automation / second instance).
	var cli: Dictionary = {}
	for a in args:
		if a.begins_with("--") and a.find("=") > 0:
			cli[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	if cli.has("name"):
		Net.save_name(String(cli["name"]))
	if cli.has("host"):
		var lv: Dictionary = NetLevels.for_map(String(cli["host"]).strip_edges().to_upper())
		var cfg := {"name": "%s's game" % Net.local_name, "map": String(lv["map"]),
			"arena": String(lv["name"]), "max_players": 0,
			"time_limit": int(cli.get("time", 0)), "frag_limit": int(cli.get("frags", 0)),
			"items": lv.get("items", {}), "replenish": bool(lv.get("replenish", true)),
			"bots": int(cli.get("bots", 0)), "bot_skill": int(cli.get("skill", 1)),
			"port": int(cli.get("port", Net.DEFAULT_PORT))}
		if Net.host(cfg):
			SkynetPaths.selected_map = String(cfg["map"])
			get_tree().change_scene_to_file.call_deferred(GAME_SCENE)
		return
	# `--screen=netmenu|join|newgame --menu-shot=PATH`: open a menu screen
	# and capture it (layout checks from a script).
	if cli.has("screen"):
		var target: Control = {"netmenu": _screen_netmenu, "join": _screen_join,
			"newgame": _screen_newgame, "netjoin": _screen_netjoin,
			"load": _screen_load, "options": _screen_options,
			"controls": _screen_controls, "detail": _screen_display,
			"debug": _screen_debug, "maps": _screen_maps}.get(String(cli["screen"]), _screen_main)
		if target == _screen_load:
			_refresh_load_slots()
		_show_screen(target)
		if String(cli["screen"]) == "quit":
			_confirm_quit()
		if cli.has("menu-shot"):
			await get_tree().create_timer(float(cli.get("shot-delay", 1.0))).timeout
			await RenderingServer.frame_post_draw
			var img: Image = get_viewport().get_texture().get_image()
			print("[menu] screenshot %s (%s)" % [cli["menu-shot"], error_string(img.save_png(String(cli["menu-shot"])))])
			if cli.has("quit-after-shot"):
				get_tree().quit()
		return
	if cli.has("join"):
		_join_name = LineEdit.new()
		_join_name.text = Net.local_name
		_join_addr = LineEdit.new()
		_join_addr.text = String(cli["join"])
		_on_join_typed.call_deferred()
		return
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
	# Centred column: title, progress bar, current item. The import takes
	# minutes on a first start, so it needs to show real movement.
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.custom_minimum_size = Vector2(560, 0)
	box.add_theme_constant_override("separation", 14)
	layer.add_child(box)
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.text = "Converting game data for first use..."
	box.add_child(lbl)
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(560, 26)
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 0.0
	bar.show_percentage = true
	box.add_child(bar)
	var item_lbl := Label.new()
	item_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	item_lbl.add_theme_font_size_override("font_size", 16)
	item_lbl.add_theme_color_override("font_color", Color(0.75, 0.78, 0.8))
	item_lbl.text = "reading the archives..."
	box.add_child(item_lbl)
	await get_tree().process_frame
	var started := Time.get_ticks_msec()
	await Assets.import_all(func(done: int, total: int, item: String) -> void:
		bar.value = float(done) / float(maxi(total, 1))
		var secs: float = (Time.get_ticks_msec() - started) / 1000.0
		var left := ""
		if done > 20:
			left = "  ~%d s left" % int(secs * (float(total) / float(done) - 1.0))
		item_lbl.text = "%d / %d   %s%s" % [done, total, item, left])
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
	out["DETAIL"] = ImgFile.parse(imgs.read("DETAIL.IMG"), menu_pal)
	out["QUIT"] = ImgFile.parse(imgs.read("QUIT.IMG"), menu_pal)
	out["QUITMAIN"] = ImgFile.parse(imgs.read("QUITMAIN.IMG"), menu_pal)
	out["NEWGAME"] = ImgFile.parse(imgs.read("NETGAME1.IMG"), menu_pal)
	out["NETJOIN"] = ImgFile.parse(imgs.read("NETJOIN1.IMG"), menu_pal)
	out["NETMENU"] = ImgFile.parse(imgs.read("NETMENU1.IMG"), menu_pal)
	imgs.close()
	return out

# --- UI construction --------------------------------------------------

func _build() -> void:
	var art := _load_images()
	var fnt_bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path("FONT0003.FNT"))
	if not fnt_bytes.is_empty():
		_net_font = FntFont.build(fnt_bytes, 2)

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
	_screen_join = _build_join_screen()
	_screen_load = _build_load_screen(art.get("LOAD"))
	_screen_options = _build_options_screen(art.get("OPTIONS"))
	_screen_controls = _build_controls_screen(art.get("CONTROLS"))
	_screen_display = _build_display_screen(art.get("DETAIL"))
	_quit_art = art.get("QUIT")
	_screen_debug = _build_debug_screen()
	_screen_maps = _build_maps_screen()
	for s in _all_screens():
		add_child(s)

	# ESC navigation: each sub-screen steps back one level.
	_back_target = {
		_screen_newgame:  _screen_main,
		_screen_netjoin:  _screen_newgame,
		_screen_netmenu:  _screen_netjoin,
		_screen_join:     _screen_netjoin,
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
	# Back from a network game that ended on us (server gone, kicked).
	Net.leave()
	if not Net.pending_message.is_empty():
		_show_toast(Net.pending_message)
		Net.pending_message = ""

func _all_screens() -> Array:
	return [_screen_main, _screen_newgame, _screen_netjoin, _screen_netmenu,
		_screen_join, _screen_load, _screen_options, _screen_controls,
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
		func() -> void: _show_screen(_screen_join)))
	panel.add_child(_img_hotspot(NJ_EXIT_RECT, s,
		func() -> void: _show_screen(_screen_newgame)))
	return pair[0]

# --- NETMENU1.IMG field boxes (320x200 image pixels) ---------------------
const NM_NAME_RECT: Rect2 = Rect2(33, 9, 96, 9)
const NM_SKILL_RECT: Rect2 = Rect2(63, 24, 14, 7)
const NM_LIST_RECT: Rect2 = Rect2(8, 35, 121, 124)
const NM_AREA_RECT: Rect2 = Rect2(168, 9, 145, 9)
const NM_MAXP_RECT: Rect2 = Rect2(209, 24, 13, 7)
const NM_TIME_RECT: Rect2 = Rect2(249, 24, 63, 7)
const NM_GOAL_RECT: Rect2 = Rect2(166, 38, 65, 9)
const NM_KILLS_RECT: Rect2 = Rect2(247, 38, 65, 9)
const NM_SCORE_KILL_RECT: Rect2 = Rect2(212, 51, 25, 8)
const NM_SCORE_DEATH_RECT: Rect2 = Rect2(277, 51, 25, 8)
const NM_SCORE_HIT_RECT: Rect2 = Rect2(212, 63, 25, 8)
const NM_REPLENISH_RECT: Rect2 = Rect2(181, 144, 13, 8)
const NM_BOTTOM_RECT: Rect2 = Rect2(8, 165, 305, 30)
## Item count boxes: left column (jeeps … health) and right column
## (slugthrowers … rockets), one row per 10 px from y = 69.
const NM_ITEMS_LEFT: Array = ["jeeps", "hks", "bullets", "energy", "armor", "health"]
const NM_ITEMS_RIGHT: Array = ["slugthrowers", "lasers", "plasmas", "launchers", "grenades", "rockets"]
const NM_ITEM_ROW0: float = 74.0
const NM_ITEM_PITCH: float = 11.0
const NM_ITEM_LEFT_X: float = 181.0
const NM_ITEM_RIGHT_X: float = 282.0
const NM_ITEM_W: float = 13.0
const NM_ITEM_H: float = 8.0
const BOT_SKILLS: Array = ["EASY", "NORMAL", "HARD"]

var _screen_join: Control = null
var _nm_fields: Dictionary = {}          # key → LineEdit
var _nm_arena_buttons: Array = []
var _nm_arena: int = 0
var _nm_area_label: Label = null
var _nm_skill_btn: Button = null
var _nm_replenish_btn: Button = null
var _nm_bots_edit: LineEdit = null
var _nm_port_edit: LineEdit = null
var _bot_skill: int = 1
var _replenish: bool = true
var _join_list: VBoxContainer = null
var _join_name: LineEdit = null
var _join_addr: LineEdit = null
var _join_status: Label = null
var _discovery = null                     # net_discovery.gd, live on the JOIN screen
const NetDiscovery := preload("res://scripts/net/net_discovery.gd")
const NetLevels := preload("res://scripts/net/net_levels.gd")

## A transparent entry box over a baked NETMENU field.
func _nm_field(panel: Control, rect: Rect2, s: float, text: String, key: String,
		numeric: bool = false) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size = Vector2.ZERO
	e.position = rect.position * s
	e.size = rect.size * s
	_dos_font(e)
	e.add_theme_constant_override("minimum_character_width", 1)
	e.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	e.add_theme_color_override("caret_color", Color(0.6, 1.0, 0.7))
	var empty := StyleBoxEmpty.new()
	e.add_theme_stylebox_override("normal", empty)
	e.add_theme_stylebox_override("focus", empty)
	e.add_theme_stylebox_override("read_only", empty)
	e.context_menu_enabled = false
	if numeric:
		e.max_length = 3
		e.alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		e.max_length = 16
		# The DOS font is all-caps; keep what the player types that way.
		e.text_changed.connect(func(t: String) -> void:
			var up := t.to_upper()
			if up != t:
				var c := e.caret_column
				e.text = up
				e.caret_column = c)
	panel.add_child(e)
	_nm_fields[key] = e
	return e

## The FONT0003 bitmap font (16 px) on a Control, or a same-sized
## fallback when the game data lacks it.
func _dos_font(c: Control, size: int = 16) -> void:
	if _net_font != null:
		c.add_theme_font_override("font", _net_font)
		# A bitmap font only stays sharp at whole multiples of its own
		# cell (FONT0003 is 8x8, built at x2 = 16 px): round the request
		# to the nearest multiple instead of resampling it at 1.5x.
		var unit: int = maxi(_net_font.fixed_size, 1)
		c.add_theme_font_size_override("font_size", maxi(int(round(float(size) / float(unit))), 1) * unit)
	else:
		c.add_theme_font_size_override("font_size", size)

func _nm_static(panel: Control, rect: Rect2, s: float, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.position = rect.position * s
	l.size = rect.size * s
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_dos_font(l)
	l.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(l)
	return l

func _nm_toggle(panel: Control, rect: Rect2, s: float, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	_style_hotspot(b)
	b.position = rect.position * s
	b.size = rect.size * s
	_dos_font(b)
	b.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.pressed.connect(cb)
	panel.add_child(b)
	return b

## NETMENU1.IMG — the DOS network game-setup screen, live: NAME, the
## arena list (NETLEVEL.PRS), MAX # PLAYERS, TIME (minutes), the KILLS
## goal (frag limit), the item counts the host scatters over the arena,
## REPLENISH, plus bots/skill/port in the message box. START hosts.
func _build_netmenu_screen(tex: Variant) -> Control:
	var pair := _img_panel(tex, 320.0, 200.0, NM_PANEL_SCALE)
	var panel: Control = pair[1]
	var s := NM_PANEL_SCALE
	_nm_fields.clear()
	_nm_field(panel, NM_NAME_RECT, s, Net.local_name, "name")
	_nm_area_label = _nm_static(panel, NM_AREA_RECT, s, "")
	_nm_field(panel, NM_MAXP_RECT, s, "8", "max_players", true)
	_nm_field(panel, NM_TIME_RECT, s, "20", "time_limit", true)
	_nm_static(panel, NM_GOAL_RECT, s, "KILLS")
	_nm_field(panel, NM_KILLS_RECT, s, "20", "frag_limit", true)
	_nm_static(panel, NM_SCORE_KILL_RECT, s, "500")
	_nm_static(panel, NM_SCORE_DEATH_RECT, s, "400")
	_nm_static(panel, NM_SCORE_HIT_RECT, s, "100")
	for i in NM_ITEMS_LEFT.size():
		var y: float = NM_ITEM_ROW0 + float(i) * NM_ITEM_PITCH
		var key: String = NM_ITEMS_LEFT[i]
		_nm_field(panel, Rect2(NM_ITEM_LEFT_X, y, NM_ITEM_W, NM_ITEM_H), s, "0", key, true)
		_nm_field(panel, Rect2(NM_ITEM_RIGHT_X, y, NM_ITEM_W, NM_ITEM_H), s, "0", NM_ITEMS_RIGHT[i], true)
	# The SKILL LEVEL box holds two characters: bot skill 1..3.
	_nm_skill_btn = _nm_toggle(panel, NM_SKILL_RECT, s, str(_bot_skill + 1), func() -> void:
		_bot_skill = (_bot_skill + 1) % BOT_SKILLS.size()
		_nm_skill_btn.text = str(_bot_skill + 1))
	_nm_replenish_btn = _nm_toggle(panel, NM_REPLENISH_RECT, s, "YES", func() -> void:
		_replenish = not _replenish
		_nm_replenish_btn.text = "YES" if _replenish else "NO")

	# Arena list in the left box.
	var scroll := ScrollContainer.new()
	scroll.position = NM_LIST_RECT.position * s
	scroll.size = NM_LIST_RECT.size * s
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 0)
	scroll.add_child(vb)
	_nm_arena_buttons.clear()
	var levels: Array = NetLevels.levels()
	for i in levels.size():
		var lv: Dictionary = levels[i]
		if not _maps.has(String(lv["map"])):
			continue
		var b := Button.new()
		b.text = " %s  %s" % [String(lv["name"]).to_upper(), String(lv["map"]).trim_prefix("MAP.")]
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(NM_LIST_RECT.size.x * s - 12.0, 8.0 * s)
		_dos_font(b)
		b.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))
		b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
		_style_hotspot(b)
		var idx: int = i
		b.pressed.connect(func() -> void: _nm_select_arena(idx))
		vb.add_child(b)
		_nm_arena_buttons.append([b, idx])
	_nm_select_arena(0)

	# Message box: the fields the DOS screen never had.
	var row := HBoxContainer.new()
	row.position = NM_BOTTOM_RECT.position * s + Vector2(6.0, 4.0)
	row.size = NM_BOTTOM_RECT.size * s - Vector2(12.0, 8.0)
	row.add_theme_constant_override("separation", int(4.0 * s))
	panel.add_child(row)
	for spec in [["BOTS", "3", "bots"], ["PORT", str(Net.DEFAULT_PORT), "port"]]:
		var l := Label.new()
		l.text = spec[0]
		_dos_font(l)
		l.add_theme_color_override("font_color", Color(0.8, 0.85, 0.85))
		row.add_child(l)
		var e := LineEdit.new()
		e.text = spec[1]
		e.max_length = 5
		e.custom_minimum_size = Vector2((34.0 if spec[2] == "port" else 22.0) * s, 8.0 * s)
		_dos_font(e)
		e.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		row.add_child(e)
		_nm_fields[spec[2]] = e
	# HUMAN / TERMINATOR — the DOS MP class choice.
	var pl := Label.new()
	pl.text = "PLAY AS"
	_dos_font(pl)
	pl.add_theme_color_override("font_color", Color(0.8, 0.85, 0.85))
	row.add_child(pl)
	row.add_child(_class_button())
	var hint := Label.new()
	hint.text = "SKILL 1-3 = BOTS   TIME = MIN   KILLS = FRAG LIMIT"
	_dos_font(hint)
	hint.add_theme_color_override("font_color", Color(0.6, 0.66, 0.66))
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(hint)

	panel.add_child(_img_hotspot(NM_START_RECT, s, _on_host_start))
	panel.add_child(_img_hotspot(NM_EXIT_RECT, s,
		func() -> void: _show_screen(_screen_netjoin)))
	return pair[0]

## A toggle showing the local class (HUMAN = fast, fragile; TERMINATOR =
## slow, tough, machine vision). Shared by the host and join screens.
func _class_button() -> Button:
	var b := Button.new()
	b.text = Net.CLASS_NAMES[Net.local_class]
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(190, 36)
	_dos_font(b)
	_style_button(b)
	b.pressed.connect(func() -> void:
		Net.set_class((Net.local_class + 1) % 2)
		b.text = Net.CLASS_NAMES[Net.local_class]
		_show_toast("HUMAN: faster, 100 HP.  TERMINATOR: slower, 200 HP, machine vision."))
	return b

func _nm_select_arena(idx: int) -> void:
	var levels: Array = NetLevels.levels()
	if levels.is_empty():
		return
	_nm_arena = clampi(idx, 0, levels.size() - 1)
	var lv: Dictionary = levels[_nm_arena]
	if _nm_area_label != null:
		_nm_area_label.text = String(lv["name"]).to_upper()
	for pair in _nm_arena_buttons:
		var b: Button = pair[0]
		b.add_theme_color_override("font_color",
			Color(1.0, 0.9, 0.4) if int(pair[1]) == _nm_arena else Color(0.55, 0.85, 0.65))
	var items: Dictionary = lv.get("items", {})
	for key in items:
		if _nm_fields.has(key):
			(_nm_fields[key] as LineEdit).text = str(int(items[key]))
	_replenish = bool(lv.get("replenish", true))
	if _nm_replenish_btn != null:
		_nm_replenish_btn.text = "YES" if _replenish else "NO"

func _nm_int(key: String, fallback: int) -> int:
	var e: LineEdit = _nm_fields.get(key)
	if e == null or not e.text.strip_edges().is_valid_int():
		return fallback
	return int(e.text.strip_edges())

## START: host the arena with the fields as set, then load it.
func _on_host_start() -> void:
	var levels: Array = NetLevels.levels()
	if levels.is_empty():
		_show_toast("No network arenas (NETLEVEL.PRS).")
		return
	var lv: Dictionary = levels[_nm_arena]
	var nm: String = (_nm_fields["name"] as LineEdit).text.strip_edges()
	Net.save_name(nm)
	var items: Dictionary = {}
	for key in NM_ITEMS_LEFT + NM_ITEMS_RIGHT:
		if _nm_fields.has(key):
			items[key] = clampi(_nm_int(key, 0), 0, 99)
	var cfg := {
		"name": "%s's game — %s" % [Net.local_name, String(lv["name"])],
		"map": String(lv["map"]),
		"arena": String(lv["name"]),
		"max_players": clampi(_nm_int("max_players", 8), 0, Net.MAX_PEERS),
		"time_limit": clampi(_nm_int("time_limit", 0), 0, 180),
		"frag_limit": clampi(_nm_int("frag_limit", 0), 0, 999),
		"items": items,
		"replenish": _replenish,
		"bots": clampi(_nm_int("bots", 0), 0, 12),
		"bot_skill": _bot_skill,
		"port": clampi(_nm_int("port", Net.DEFAULT_PORT), 1024, 65535),
	}
	if not Net.host(cfg):
		_show_toast("Could not open port %d." % int(cfg["port"]))
		return
	SkynetPaths.selected_map = String(cfg["map"])
	_launch(GAME_SCENE)

## JOIN GAME — LAN server list (UDP discovery) plus a typed address.
func _build_join_screen() -> Control:
	var pair := _framed_panel()
	var vb: VBoxContainer = pair[1]
	vb.add_child(_heading("JOIN GAME"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	row.add_child(_section_label("NAME"))
	_join_name = LineEdit.new()
	_join_name.text = Net.local_name
	_join_name.max_length = 16
	_join_name.custom_minimum_size = Vector2(220, 40)
	_join_name.add_theme_font_size_override("font_size", 20)
	row.add_child(_join_name)
	row.add_child(_section_label("PLAY AS"))
	row.add_child(_class_button())
	vb.add_child(_section_label("Servers on the LAN"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 220)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_join_list = VBoxContainer.new()
	_join_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_join_list)
	_join_status = Label.new()
	_join_status.text = "Searching..."
	_join_status.add_theme_font_size_override("font_size", 18)
	_join_status.add_theme_color_override("font_color", Color(0.7, 0.8, 0.8))
	vb.add_child(_join_status)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 10)
	vb.add_child(row2)
	row2.add_child(_section_label("ADDRESS"))
	_join_addr = LineEdit.new()
	_join_addr.placeholder_text = "host or ip[:port]"
	_join_addr.custom_minimum_size = Vector2(300, 40)
	_join_addr.add_theme_font_size_override("font_size", 20)
	_join_addr.text_submitted.connect(func(_t: String) -> void: _on_join_typed())
	row2.add_child(_join_addr)
	var cb := _option_button("CONNECT", _on_join_typed)
	cb.custom_minimum_size = Vector2(180, 44)
	row2.add_child(cb)
	vb.add_child(_spacer(6))
	vb.add_child(_menu_button("BACK", func() -> void: _show_screen(_screen_netjoin)))
	return pair[0]

func _refresh_join_list() -> void:
	if _join_list == null or _discovery == null:
		return
	for c in _join_list.get_children():
		c.queue_free()
	var keys: Array = _discovery.servers.keys()
	keys.sort()
	for k in keys:
		var sv: Dictionary = _discovery.servers[k]
		var b := _option_button("%s   %s   %d players%s" % [String(sv["name"]), String(sv["map"]),
			int(sv["players"]), (" + %d bots" % int(sv["bots"])) if int(sv["bots"]) > 0 else ""],
			func() -> void: _connect_to(String(sv["ip"]), int(sv["port"])))
		b.custom_minimum_size = Vector2(540, 44)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_join_list.add_child(b)
	_join_status.text = "Searching..." if keys.is_empty() else "%d server(s) found" % keys.size()

func _on_join_typed() -> void:
	var a: String = _join_addr.text.strip_edges()
	if a.is_empty():
		_show_toast("Type a server address, or pick one from the list.")
		return
	var port: int = Net.DEFAULT_PORT
	var host: String = a
	var colon: int = a.rfind(":")
	if colon > 0 and a.substr(colon + 1).is_valid_int():
		port = int(a.substr(colon + 1))
		host = a.substr(0, colon)
	_connect_to(host, port)

func _connect_to(host: String, port: int) -> void:
	Audio.play_sfx("BUTTON1.RAW")
	if not Net.join(host, port, _join_name.text):
		_show_toast("Cannot connect to %s:%d." % [host, port])
		return
	_join_status.text = "Connecting to %s:%d ..." % [host, port]
	if not Net.welcome_received.is_connected(_on_net_welcome):
		Net.welcome_received.connect(_on_net_welcome)
	if not Net.connection_failed.is_connected(_on_net_failed):
		Net.connection_failed.connect(_on_net_failed)

func _on_net_welcome() -> void:
	var m: String = String(Net.settings.get("map", ""))
	if not _maps.has(m):
		Net.leave()
		_show_toast("The server plays %s, which this install does not have." % m)
		return
	SkynetPaths.selected_map = m
	_launch(GAME_SCENE)

func _on_net_failed(reason: String) -> void:
	_show_toast(reason)
	if _join_status != null:
		_join_status.text = reason

func _process(delta: float) -> void:
	var on_join: bool = _screen_join != null and _screen_join.visible
	if on_join and _discovery == null:
		_discovery = NetDiscovery.new()
		if not _discovery.start():
			_discovery = null
			_join_status.text = "LAN discovery unavailable — type an address."
	elif not on_join and _discovery != null:
		_discovery.stop()
		_discovery = null
	if _discovery != null and _discovery.tick(delta):
		_refresh_join_list()

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

## LOAD GAME — the original LOAD.IMG panel with 10 save slots
## (user://saves/slot_NN.save, see save_game.gd; slot 1 is the F6
## quicksave). A full slot shows its map and time and loads on click;
## an empty one just says so. The baked-in EXIT button returns.
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

	# 10 save slots — transparent hotspots over the LOAD.IMG bars, their
	# text refreshed from the slot files each time the screen opens.
	_load_slot_buttons.clear()
	for i in LOAD_SLOTS:
		var slot := Button.new()
		slot.flat = true
		slot.focus_mode = Control.FOCUS_NONE
		_style_hotspot(slot)
		slot.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_dos_font(slot, int(8.0 * s))
		slot.add_theme_color_override("font_color", Color(0.72, 0.95, 0.78))
		slot.add_theme_color_override("font_hover_color", Color(1, 1, 1))
		slot.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
		slot.add_theme_constant_override("h_separation", int(4.0 * s))
		slot.position = Vector2(LOAD_SLOT_X * s,
			(LOAD_SLOT_Y0 + i * LOAD_SLOT_PITCH) * s)
		slot.size = Vector2(LOAD_SLOT_W * s, LOAD_SLOT_H * s)
		var idx: int = i
		slot.pressed.connect(func() -> void: _on_load_slot(idx))
		panel.add_child(slot)
		_load_slot_buttons.append(slot)
	_refresh_load_slots()

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

## Slot captions: "  1  MAP.210 · 2026-08-30 21:14" or "  1  - empty -".
func _refresh_load_slots() -> void:
	for i in _load_slot_buttons.size():
		var b: Button = _load_slot_buttons[i]
		if not is_instance_valid(b):
			continue
		var info: String = SaveGame.info(i)
		var tag: String = "QUICK" if i == SaveGame.QUICK_SLOT else "%d" % (i + 1)
		b.text = "  %-5s  %s" % [tag, info if not info.is_empty() else "- empty -"]

func _on_load_slot(idx: int) -> void:
	if not SaveGame.exists(idx):
		_show_toast("Slot %d is empty. Save in-game with F6." % (idx + 1))
		return
	Audio.play_sfx("BUTTON1.RAW")
	SkynetPaths.pending_load_slot = idx
	_launch(GAME_SCENE)

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

	# SOUND and MUSIC volumes over the baked slider tracks.
	for row in [[OPT_SOUND_RECT, "sound"], [OPT_MUSIC_RECT, "music"]]:
		var vol: Control = preload("res://scripts/volume_slider.gd").new()
		vol.channel = String(row[1])
		vol.position = (row[0] as Rect2).position * s
		vol.size = (row[0] as Rect2).size * s
		panel.add_child(vol)

	# REVERSE STEREO — swaps the panning, like the DOS toggle.
	_stereo_mark = _option_mark(panel, OPT_STEREO_RECT, s)
	panel.add_child(_img_hotspot(OPT_STEREO_RECT, s, func() -> void:
		Settings.set_reverse_stereo(not Settings.reverse_stereo)
		_refresh_option_marks()))

	# DIFFICULTY LEVEL — LOW / MED / HIGH.
	_diff_marks.clear()
	for i in OPT_DIFF_RECTS.size():
		var r: Rect2 = OPT_DIFF_RECTS[i]
		_diff_marks.append(_option_mark(panel, r, s))
		var lvl: int = i
		panel.add_child(_img_hotspot(r, s, func() -> void:
			Settings.set_difficulty(lvl)
			_refresh_option_marks()))
	_refresh_option_marks()

	vb.add_child(_spacer(8))
	vb.add_child(_menu_button("DEBUG TOOLS",
		func() -> void: _show_screen(_screen_debug)))
	return pair[0]

## A selection highlight drawn inside one of the baked buttons: the DOS
## screens light the chosen cell up rather than moving a marker.
var _stereo_mark: ColorRect = null
var _diff_marks: Array = []
var _detail_marks: Array = []
var _res_marks: Array = []

func _option_mark(panel: Control, rect: Rect2, s: float) -> ColorRect:
	var m := ColorRect.new()
	m.color = Color(0.35, 0.95, 0.55, 0.30)
	m.position = rect.position * s
	m.size = rect.size * s
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.visible = false
	panel.add_child(m)
	return m

func _refresh_option_marks() -> void:
	if _stereo_mark != null and is_instance_valid(_stereo_mark):
		_stereo_mark.visible = Settings.reverse_stereo
	for i in _diff_marks.size():
		var m: ColorRect = _diff_marks[i]
		if is_instance_valid(m):
			m.visible = (i == Settings.difficulty)
	for i in _detail_marks.size():
		var m2: ColorRect = _detail_marks[i]
		if is_instance_valid(m2):
			m2.visible = (i == Settings.detail)

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
		_dos_font(lbl, 16)
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

## RENDER DETAIL — the original DETAIL.IMG screen (OPTIONS → DETAIL),
## with the port's own display settings underneath it.
##
## The two art rows do what they did in DOS: RENDER DETAIL pulls the
## haze in (Settings.fog_scale) and RESOLUTION picks the 3D render
## resolution, 320 or 640 pixels wide stretched up — the chunky software
## look. NATIVE and the window settings below are the port's additions.
func _build_display_screen(detail_tex: Variant) -> Control:
	var pair := _panel_screen()
	var vb: VBoxContainer = pair[1]
	var s := DET_PANEL_SCALE

	var panel := Control.new()
	panel.custom_minimum_size = Vector2(198.0 * s, 102.0 * s)
	vb.add_child(panel)
	if detail_tex != null:
		var pic := TextureRect.new()
		pic.texture = detail_tex
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(pic)
	else:
		panel.add_child(_heading("RENDER DETAIL"))

	_detail_marks.clear()
	for i in DET_LEVEL_RECTS.size():
		var r: Rect2 = DET_LEVEL_RECTS[i]
		_detail_marks.append(_option_mark(panel, r, s))
		var lvl: int = i
		panel.add_child(_img_hotspot(r, s, func() -> void:
			Settings.set_detail(lvl)
			_refresh_option_marks()
			_show_toast("Render detail: %s" % Settings.LEVEL_NAMES[lvl])))

	_res_marks.clear()
	for i in DET_RES_RECTS.size():
		var r2: Rect2 = DET_RES_RECTS[i]
		_res_marks.append(_option_mark(panel, r2, s))
		var mode: int = i
		panel.add_child(_img_hotspot(r2, s, func() -> void:
			Settings.set_resolution(mode)
			_refresh_display_marks()))
	panel.add_child(_img_hotspot(DET_EXIT_RECT, s,
		func() -> void: _show_screen(_screen_options)))

	vb.add_child(_section_label("Render resolution"))
	var native := _option_button("NATIVE (FULL WINDOW)", func() -> void:
		Settings.set_resolution(Settings.RES_NATIVE)
		_refresh_display_marks())
	native.set_meta("res_mode", Settings.RES_NATIVE)
	_res_buttons.clear()
	_res_buttons.append(native)
	vb.add_child(native)

	vb.add_child(_section_label("Weapon view"))
	var wv := HBoxContainer.new()
	wv.alignment = BoxContainer.ALIGNMENT_CENTER
	wv.add_theme_constant_override("separation", 14)
	_weapon_view_buttons.clear()
	for m in [["DOS ART", false], ["3D MODEL", true]]:
		var on: bool = m[1]
		var wb := _option_button(String(m[0]), func() -> void:
			Settings.set_weapon_3d(on)
			_refresh_display_marks())
		wb.custom_minimum_size = Vector2(210, 48)
		wb.set_meta("weapon3d", on)
		_weapon_view_buttons.append(wb)
		wv.add_child(wb)
	vb.add_child(wv)

	vb.add_child(_section_label("Window"))
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

	# DOS (faithful software look) / ENHANCED (filtered upscaled textures,
	# real lighting and sky) — Render autoload, docs §P.
	vb.add_child(_section_label("Rendering"))
	var renders := HBoxContainer.new()
	renders.alignment = BoxContainer.ALIGNMENT_CENTER
	renders.add_theme_constant_override("separation", 14)
	_render_buttons.clear()
	for m in [["DOS / RETRO", Render.DOS], ["ENHANCED", Render.ENHANCED]]:
		var rm: int = m[1]
		var rb := _option_button(m[0], func() -> void:
			Render.set_mode(rm)
			_refresh_display_marks()
			_show_toast("Rendering: %s — takes effect when a map loads." % Render.NAMES[rm]))
		rb.custom_minimum_size = Vector2(210, 48)
		rb.set_meta("render", rm)
		_render_buttons.append(rb)
		renders.add_child(rb)
	vb.add_child(renders)

	vb.add_child(_spacer(4))
	vb.add_child(_menu_button("BACK", func() -> void: _show_screen(_screen_options)))
	_refresh_display_marks()
	_refresh_option_marks()
	return pair[0]

var _render_buttons: Array[Button] = []
var _weapon_view_buttons: Array[Button] = []

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
	l.text = text.to_upper()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dos_font(l, 16)
	l.add_theme_color_override("font_color", Color(0.62, 0.65, 0.7))
	return l

## Mark the active resolution / mode button with a leading caret.
func _refresh_display_marks() -> void:
	for rb in _res_buttons:
		var mode: int = int(rb.get_meta("res_mode", -1))
		rb.text = ("> " if mode == Settings.resolution else "") + "NATIVE (FULL WINDOW)"
	for wb in _weapon_view_buttons:
		var on2: bool = bool(wb.get_meta("weapon3d"))
		wb.text = ("> " if on2 == Settings.weapon_3d else "") + ("3D MODEL" if on2 else "DOS ART")
	for i in _res_marks.size():
		var m: ColorRect = _res_marks[i]
		if is_instance_valid(m):
			m.visible = (i == Settings.resolution)
	for mb in _mode_buttons:
		var fs: bool = mb.get_meta("fs")
		var nm: String = "FULLSCREEN" if fs else "WINDOWED"
		mb.text = ("> " if fs == _disp_fullscreen else "") + nm
	for rb in _render_buttons:
		var rm: int = rb.get_meta("render")
		rb.text = ("> " if rm == Render.mode else "") + ("DOS / RETRO" if rm == Render.DOS else "ENHANCED")

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
		_dos_font(mb, 16)
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
	b.text = text.to_upper()
	b.custom_minimum_size = Vector2(340, 44)
	_dos_font(b, 16)
	b.focus_mode = Control.FOCUS_NONE
	_style_button(b)
	b.pressed.connect(cb)
	return b

func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()          # the DOS bitmap font has no lower case
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dos_font(l, 32)
	l.add_theme_color_override("font_color", Color(0.82, 0.84, 0.88))
	return l

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s

func _menu_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.custom_minimum_size = Vector2(360, 58)
	_dos_font(b, 16)
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
	_dos_font(_toast, 16)
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
		if _quit_overlay != null and is_instance_valid(_quit_overlay):
			_close_quit()                     # DOS: ESC in the box = NO
		elif _screen_main != null and _screen_main.visible:
			_confirm_quit()                   # DOS: ESC on the title = QUIT?
		else:
			for scr in _all_screens():
				if scr != null and scr.visible and _back_target.has(scr):
					_show_screen(_back_target[scr])
					break
		get_viewport().set_input_as_handled()

## QUIT confirmation — the original QUIT.IMG box (96x37, drawn at
## 115,70 of the 320x200 screen) with its baked YES / NO captions.
## DOS: FUN_00140684; ESC inside the box means NO, and ESC on the title
## menu OPENS this box rather than doing nothing.
const QUIT_PANEL_SCALE: float = 4.0
const QUIT_YES_RECT: Rect2 = Rect2(0, 20, 52, 17)
const QUIT_NO_RECT: Rect2 = Rect2(52, 20, 44, 17)
var _quit_overlay: Control = null

func _confirm_quit() -> void:
	if _quit_overlay != null and is_instance_valid(_quit_overlay):
		return
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var s := QUIT_PANEL_SCALE
	var panel := Control.new()
	panel.custom_minimum_size = Vector2(96.0 * s, 37.0 * s)
	center.add_child(panel)
	if _quit_art != null:
		var pic := TextureRect.new()
		pic.texture = _quit_art
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(pic)
	else:
		panel.add_child(_heading("QUIT TO DOS?"))
	panel.add_child(_quit_hotspot(QUIT_YES_RECT, s, func() -> void:
		get_tree().quit()))
	panel.add_child(_quit_hotspot(QUIT_NO_RECT, s, _close_quit))
	add_child(root)
	_quit_overlay = root

## Like _img_hotspot but with a visible hover highlight, standing in for
## the QUITBTN.CFA frame the DOS box drew under the pointer.
func _quit_hotspot(rect: Rect2, s: float, cb: Callable) -> Button:
	var b := _img_hotspot(rect, s, cb)
	var mark := ColorRect.new()
	mark.color = Color(0.9, 0.95, 1.0, 0.18)
	mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.visible = false
	b.add_child(mark)
	b.mouse_entered.connect(func() -> void: mark.visible = true)
	b.mouse_exited.connect(func() -> void: mark.visible = false)
	return b

func _close_quit() -> void:
	if _quit_overlay != null and is_instance_valid(_quit_overlay):
		_quit_overlay.queue_free()
	_quit_overlay = null

func _on_bar_item(label: String) -> void:
	match label:
		"NEW GAME":
			_show_screen(_screen_newgame)
		"LOAD":
			_refresh_load_slots()
			_show_screen(_screen_load)
		"SAVE":
			_show_toast("Save in-game: F6 = quicksave (slot 1), F7 = quickload.")
		"OPTIONS":
			_show_screen(_screen_options)
		"QUIT":
			_confirm_quit()

func _on_map_chosen(m: String) -> void:
	SkynetPaths.selected_map = m
	_launch(GAME_SCENE)

func _launch(scene_path: String) -> void:
	var ss := get_node_or_null("/root/SceneSwitcher")
	if ss != null and ss.has_method("set_hud_visible"):
		ss.set_hud_visible(true)
	get_tree().change_scene_to_file(scene_path)
