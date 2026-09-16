## Global scene switcher. Autoloaded.
## CTRL+F1 = Level (main.tscn), CTRL+F2 = Atlas viewer, CTRL+F3 = Object
## viewer, CTRL+F4 = Enemy viewer, CTRL+F5 = Sound browser. Always-on
## overlay shows the current mode.
##
## CTRL, since 2026-09-16: F1-F5 are the game's own keys — they pick the
## thrown item, as they do in DOS (fly_camera.THROW_KEYS) — and this
## autoload sees an event before any scene does, so a bare F1 in a --dev
## run threw the player out of the level instead of selecting the molotov.

extends Node

const SCENES: Dictionary = {
	KEY_F1: "res://scenes/main.tscn",
	KEY_F2: "res://scenes/atlas_viewer.tscn",
	KEY_F3: "res://scenes/object_viewer.tscn",
	KEY_F4: "res://scenes/enemy_viewer.tscn",
	KEY_F5: "res://scenes/sound_viewer.tscn",
}

var _label: Label
var _canvas: CanvasLayer

## Hide/show the dev F-key overlay (kept off on the main menu).
func set_hud_visible(v: bool) -> void:
	if _canvas != null:
		_canvas.visible = v

## The F-key viewer switcher and its overlay are development tools:
## only `--dev` on the command line enables them.
var dev: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	dev = "--dev" in args
	if not dev:
		return
	# Lightweight overlay shown above every scene.
	var canvas := CanvasLayer.new()
	canvas.layer = 100
	_canvas = canvas
	add_child(canvas)
	_label = Label.new()
	_label.position = Vector2(8, 8)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 4)
	_label.text = "CTRL+ F1 Level  F2 Atlas  F3 Objects  F4 Enemies  F5 Sounds   ESC Quit"
	canvas.add_child(_label)

## Save the window to `path` as a PNG after `delay` seconds, then quit when
## `quit` (the menu's `--menu-shot`). Lives in this autoload rather than
## in the menu so a scene change in the meantime cannot cancel it.
func capture_after(path: String, delay: float, quit: bool) -> void:
	await get_tree().create_timer(maxf(delay, 0.0)).timeout
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(path) if img != null else ERR_CANT_CREATE
	print("[menu] screenshot %s (%s)" % [path, error_string(err)])
	if quit:
		get_tree().quit()

func _input(event: InputEvent) -> void:
	if not dev:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).ctrl_pressed:
		var k: int = event.keycode
		if SCENES.has(k):
			preload("res://scripts/pause_state.gd").reset()   # a paused game must not follow into the viewer
			get_tree().change_scene_to_file(SCENES[k])
