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
	"fire":        -1,                 # MOUSE LEFT (see mouse_code)
	"throw":       -2,                 # MOUSE RIGHT
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

## Bumped when the meaning of a stored bind changes; an older file is
## migrated on load rather than silently misbehaving.
const CFG_VERSION: int = 2

func load_binds() -> void:
	binds = DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	for a in DEFAULTS:
		binds[a] = int(cfg.get_value("binds", a, DEFAULTS[a]))
	if int(cfg.get_value("binds", "version", 1)) < CFG_VERSION:
		# Before version 2 the mouse was hard-wired: the left button
		# always fired and the right always threw, whatever FIRE and
		# THROW were bound to. Now they go through the bindings, so a
		# file from before that has to be moved onto the mouse or the
		# buttons would go dead.
		binds["fire"] = int(DEFAULTS["fire"])
		binds["throw"] = int(DEFAULTS["throw"])
		save_binds()
		print("[controls] migrated FIRE/THROW onto the mouse")

func save_binds() -> void:
	var cfg := ConfigFile.new()
	for a in binds:
		cfg.set_value("binds", a, binds[a])
	cfg.set_value("binds", "version", CFG_VERSION)
	cfg.save(CFG_PATH)

func reset_defaults() -> void:
	binds = DEFAULTS.duplicate()
	save_binds()

## --- mouse buttons ------------------------------------------------------
## A bind is normally a Godot keycode. A MOUSE BUTTON is stored as the
## NEGATIVE button index, so -1 is the left button, -2 the right, -3 the
## middle and -4/-5 the wheel. Keycodes are always positive, so the two
## never collide and the whole thing still fits in the one integer the
## config file already stores (2026-09-04: "in options I cannot map the
## mouse buttons to functions").
const MOUSE_NAMES: Dictionary = {
	1: "MOUSE LEFT", 2: "MOUSE RIGHT", 3: "MOUSE MIDDLE",
	4: "WHEEL UP", 5: "WHEEL DOWN", 6: "WHEEL LEFT", 7: "WHEEL RIGHT",
	8: "MOUSE 4", 9: "MOUSE 5",
}

static func is_mouse(code: int) -> bool:
	return code < 0

static func mouse_code(button_index: int) -> int:
	return -button_index

## Bind `action` to `keycode` (or a negative mouse code), taking it off
## whatever else held it (the DOS screen also refuses to leave a key on
## two actions).
func set_bind(action: String, keycode: int) -> void:
	for a in binds.keys():
		if a != action and int(binds[a]) == keycode:
			binds[a] = 0
	binds[action] = keycode
	save_binds()

## True while the bound key (or mouse button) for `action` is held down.
func is_pressed(action: String) -> bool:
	var kc: int = int(binds.get(action, 0))
	if kc == 0:
		return false
	if is_mouse(kc):
		return Input.is_mouse_button_pressed(-kc)
	return Input.is_key_pressed(kc)

## Does this event fire `action`? For one-shot presses (throw the
## grenade, centre the view, toggle the automap).
func matches(event: InputEvent, action: String) -> bool:
	var kc: int = int(binds.get(action, 0))
	if kc == 0:
		return false
	if event is InputEventKey:
		return not is_mouse(kc) and (event as InputEventKey).keycode == kc
	if event is InputEventMouseButton:
		return is_mouse(kc) and (event as InputEventMouseButton).button_index == -kc
	return false

## The code a rebind should store for this event, or 0 when the event is
## not something that can be bound.
static func code_for(event: InputEvent) -> int:
	if event is InputEventKey:
		return (event as InputEventKey).keycode
	if event is InputEventMouseButton:
		return mouse_code((event as InputEventMouseButton).button_index)
	return 0

## Human-readable name of whatever is currently bound to `action`.
func key_label(action: String) -> String:
	var kc: int = int(binds.get(action, 0))
	if kc == 0:
		return "---"
	if is_mouse(kc):
		return String(MOUSE_NAMES.get(-kc, "MOUSE %d" % -kc))
	var s := OS.get_keycode_string(kc)
	return s if s != "" else "---"
