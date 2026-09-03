## Autoload: configurable key bindings.
##
## The action list is the one the DOS CONTROL CONFIGURATION screen shows
## (CONTROLS.IMG, 17 bind boxes) so the ported screen can drive all of
## them. The DOS defaults live in CONTROLS.DAT (+0x00..+0x43, 17 i32
## scancodes: A / Z / arrows / Ctrl / Alt / Shift / Tab …); this port
## keeps a modern WASD-and-mouse layout instead, which is what the
## rebind screen starts from. Everything is rebindable either way.
##
## fly_camera.gd and main.gd query is_pressed(action) for held keys and
## matches(event, action) for one-shot presses. Bindings persist to
## user://controls.cfg.

extends Node

const CFG_PATH: String = "user://controls.cfg"

## action id -> default keycode.
const DEFAULTS: Dictionary = {
	"forward":     KEY_W,
	"back":        KEY_S,
	"turn_left":   KEY_LEFT,
	"turn_right":  KEY_RIGHT,
	"left":        KEY_A,
	"right":       KEY_D,
	"fire":        KEY_CTRL,
	"throw":       KEY_G,
	"activate":    KEY_F,
	"slide":       KEY_ALT,
	"sprint":      KEY_SHIFT,
	"up":          KEY_SPACE,
	"down":        KEY_C,
	"look_up":     KEY_PAGEUP,
	"look_down":   KEY_PAGEDOWN,
	"center_view": KEY_HOME,
	"automap":     KEY_TAB,
}

## Display order and labels — the CONTROLS.IMG captions, in the order the
## boxes appear on it (left column top to bottom, then right column).
const ACTIONS: Array = [
	["forward",     "FORWARD"],
	["back",        "REVERSE"],
	["turn_left",   "TURN LEFT"],
	["turn_right",  "TURN RIGHT"],
	["left",        "SLIDE LEFT"],
	["right",       "SLIDE RIGHT"],
	["fire",        "FIRE"],
	["throw",       "THROW/USE"],
	["activate",    "ACTIVATE"],
	["slide",       "SLIDE"],
	["sprint",      "RUN"],
	["up",          "JUMP"],
	["down",        "CROUCH"],
	["look_up",     "LOOK UP"],
	["look_down",   "LOOK DOWN"],
	["center_view", "CENTER VIEW"],
	["automap",     "AUTOMAP"],
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

## Bind `action` to `keycode`, taking the key off whatever else held it
## (the DOS screen also refuses to leave a key on two actions).
func set_bind(action: String, keycode: int) -> void:
	for a in binds.keys():
		if a != action and int(binds[a]) == keycode:
			binds[a] = 0
	binds[action] = keycode
	save_binds()

## True while the bound key for `action` is held down.
func is_pressed(action: String) -> bool:
	var kc: int = int(binds.get(action, 0))
	return kc != 0 and Input.is_key_pressed(kc)

## Does this key event fire `action`? For one-shot presses (throw the
## grenade, centre the view, toggle the automap).
func matches(event: InputEvent, action: String) -> bool:
	if not (event is InputEventKey):
		return false
	var kc: int = int(binds.get(action, 0))
	return kc != 0 and (event as InputEventKey).keycode == kc

## Human-readable name of the key currently bound to `action`.
func key_label(action: String) -> String:
	var kc: int = int(binds.get(action, 0))
	if kc == 0:
		return "---"
	var s := OS.get_keycode_string(kc)
	return s if s != "" else "---"
