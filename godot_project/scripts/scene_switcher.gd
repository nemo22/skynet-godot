## Global scene switcher. Autoloaded.
## F1 = Level (main.tscn), F2 = Atlas viewer, F3 = Object viewer, F4 = Enemy
## viewer (later). Always-on overlay shows the current mode.

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

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
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
	_label.text = "F1 Level   F2 Atlas   F3 Objects   F4 Enemies   F5 Sounds   ESC Quit"
	canvas.add_child(_label)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.keycode
		if SCENES.has(k):
			get_tree().change_scene_to_file(SCENES[k])
