## Autoload: configurable keyboard bindings for the fly camera.
##
## The CONTROLS dialog in the menu rebinds these; bindings persist to
## user://controls.cfg. fly_camera.gd queries is_pressed(action).

extends Node

const CFG_PATH: String = "user://controls.cfg"

## action id -> default keycode.
const DEFAULTS: Dictionary = {
	"forward": KEY_W,
	"back":    KEY_S,
	"left":    KEY_A,
	"right":   KEY_D,
	"up":      KEY_E,
	"down":    KEY_Q,
	"sprint":  KEY_SHIFT,
	"activate": KEY_F,
}

## Display order and human-readable labels for the rebind UI.
const ACTIONS: Array = [
	["forward", "Move Forward"],
	["back",    "Move Backward"],
	["left",    "Strafe Left"],
	["right",   "Strafe Right"],
	["up",      "Move Up"],
	["down",    "Move Down"],
	["sprint",  "Sprint"],
	["activate", "Activate"],
]

var binds: Dictionary = {}

func _ready() -> void:
	load_binds()

func load_binds() -> void:
	binds = DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		for a in DEFAULTS:
			binds[a] = int(cfg.get_value("binds", a, DEFAULTS[a]))

func save_binds() -> void:
	var cfg := ConfigFile.new()
	for a in binds:
		cfg.set_value("binds", a, binds[a])
	cfg.save(CFG_PATH)

func reset_defaults() -> void:
	binds = DEFAULTS.duplicate()
	save_binds()

func set_bind(action: String, keycode: int) -> void:
	binds[action] = keycode
	save_binds()

## True while the bound key for `action` is held down.
func is_pressed(action: String) -> bool:
	return Input.is_key_pressed(int(binds.get(action, 0)))

## Human-readable name of the key currently bound to `action`.
func key_label(action: String) -> String:
	var kc: int = int(binds.get(action, 0))
	var s := OS.get_keycode_string(kc)
	return s if s != "" else "(none)"
