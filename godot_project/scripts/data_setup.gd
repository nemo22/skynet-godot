## First start: ask where the original games are installed.
##
## The port plays from the ORIGINAL data (the BSA archives plus the WLD.*
## and TEXTURE.* files) and keeps its converted cache beside it. When
## nothing is found — no `--gamedata=`, nothing remembered in
## user://gamedata.cfg, no `gamedata` next to the executable and none
## bundled in the pack — this screen asks the player:
##
##   * where SKYNET is installed (required), and
##   * where TERMINATOR: FUTURE SHOCK is installed (optional — it is what
##     the menu's FUTURE SHOCK entry then starts).
##
## Either folder may be given as the game's install root or as the data
## directory itself; SkynetPaths.resolve_data_dir sorts that out. Both
## are remembered in user://gamedata.cfg, so this is asked once.
extends CanvasLayer

## dir = the SkyNET data directory that was accepted ("" if the player
## quit), shock_dir = the Future Shock one ("" when skipped).
signal finished(dir: String, shock_dir: String)

const PAD: float = 28.0

var _skynet: String = ""
var _shock: String = ""
var _skynet_label: Label = null
var _shock_label: Label = null
var _continue: Button = null
var _dialog: FileDialog = null
var _picking_shock: bool = false

func _ready() -> void:
	print("[setup] asking where SKYNET (and Future Shock) are installed")
	layer = 80
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.06, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 14)
	box.offset_left = PAD
	box.offset_right = -PAD
	box.offset_top = PAD
	box.offset_bottom = -PAD
	add_child(box)
	box.add_child(_title("WHERE ARE THE ORIGINAL GAMES?"))
	box.add_child(_text("This port reads the data of the original 1996 games. "
		+ "Point it at your SKYNET folder — the install root or its GAMEDATA "
		+ "directory, either works. TERMINATOR: FUTURE SHOCK is optional; "
		+ "give it and the menu can start that game too."))
	_skynet_label = _text("SKYNET: not set")
	box.add_child(_skynet_label)
	box.add_child(_button("CHOOSE THE SKYNET FOLDER…", _on_pick_skynet))
	_shock_label = _text("FUTURE SHOCK: not set (optional)")
	box.add_child(_shock_label)
	box.add_child(_button("CHOOSE THE FUTURE SHOCK FOLDER…", _on_pick_shock))
	_continue = _button("CONTINUE", _on_continue)
	_continue.disabled = true
	box.add_child(_continue)
	box.add_child(_button("QUIT", _on_quit))
	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.use_native_dialog = true
	_dialog.dir_selected.connect(_on_dir_selected)
	add_child(_dialog)

func _title(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 26)
	return l

func _text(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 16)
	return l

func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b

func _on_pick_skynet() -> void:
	_picking_shock = false
	_dialog.title = "The SKYNET folder"
	_dialog.popup_centered_ratio(0.7)

func _on_pick_shock() -> void:
	_picking_shock = true
	_dialog.title = "The TERMINATOR: FUTURE SHOCK folder"
	_dialog.popup_centered_ratio(0.7)

func _on_dir_selected(dir: String) -> void:
	var found: String = SkynetPaths.resolve_data_dir(dir)
	var game: String = SkynetPaths.game_of(found) if not found.is_empty() else ""
	if _picking_shock:
		if game == "shock":
			_shock = found
			_shock_label.text = "FUTURE SHOCK: %s" % found
		else:
			_shock_label.text = "FUTURE SHOCK: no MDMDMAPS.BSA under %s" % dir
		return
	if game == "skynet":
		_skynet = found
		_skynet_label.text = "SKYNET: %s" % found
		_continue.disabled = false
	elif game == "shock":
		# The player pointed at Future Shock: take it as the game to play.
		_skynet = found
		_skynet_label.text = "FUTURE SHOCK (played as the main game): %s" % found
		_continue.disabled = false
	else:
		_skynet_label.text = "SKYNET: no MDMDMAP2.BSA under %s" % dir

func _on_continue() -> void:
	if _skynet.is_empty():
		return
	SkynetPaths.set_gamedata_dir(_skynet)
	if not _shock.is_empty():
		SkynetPaths.set_other_game_dir(_shock)
	finished.emit(_skynet, _shock)
	queue_free()

func _on_quit() -> void:
	finished.emit("", "")
	get_tree().quit()
