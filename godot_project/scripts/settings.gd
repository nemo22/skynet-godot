## Autoload `Settings`: the gameplay and render-detail options the DOS
## OPTIONS / RENDER DETAIL screens set, persisted to user://settings.cfg.
##
## The DOS original keeps these in CONTROLS.DAT (154 bytes at VA 0x60152,
## checksummed): difficulty at +0x58 (default 1 = MED), render detail at
## +0x64 (default 2 = HIGH), reverse stereo at +0x5C. Volumes live there
## too, but this port keeps those in the Audio autoload.
##
## DIFFICULTY does NOT change how many enemies a map has, nor what it
## drops — that is a common misremembering. Skynet.exe indexes a table
## at VA 0x5c210 with {1, 4, 7} for LOW/MED/HIGH and copies four 16.16
## multipliers out of it (FUN_0013b300); those four are the whole of it.

extends Node

const CFG_PATH: String = "user://settings.cfg"

enum { LOW = 0, MED = 1, HIGH = 2 }
const LEVEL_NAMES: Array = ["LOW", "MED", "HIGH"]

## Rows 1 / 4 / 7 of the DOS difficulty table (16.16 → float):
##   enemy rate of fire, damage dealt to enemies, damage dealt to the
##   player, and the player's shield (armour) regeneration per second.
const DIFF_ENEMY_FIRE: Array   = [0.25, 0.625, 1.0]
const DIFF_DMG_TO_ENEMY: Array = [1.5, 1.25, 1.0]
const DIFF_DMG_TO_PLAYER: Array = [0.75, 1.0, 1.0]
const DIFF_ARMOR_REGEN: Array  = [0.025, 0.015, 0.0125]

## RENDER DETAIL drives the draw distance and where the haze starts.
## DOS (VA 0x61800, 3 x 20 bytes): far clip 1408 / 2176 / 2432 and haze
## start 720 / 1744 / 2000 world units. Those are tiny next to what this
## port draws, so the port keeps HIGH as the tuned look and scales the
## fog distances by the DOS ratios for MED and LOW.
const DETAIL_FOG_SCALE: Array = [1408.0 / 2432.0, 2176.0 / 2432.0, 1.0]

signal difficulty_changed(level: int)
signal detail_changed(level: int)

## RESOLUTION on the DOS screen is the video mode: 320x200 or 640x480.
## This port always opens a modern window, so the setting drives the 3D
## RENDER resolution instead — the world is drawn at 320 or 640 pixels
## wide and stretched up, which is what gives the chunky software look.
## NATIVE (the port's default) renders at the window's own size.
## --- window ------------------------------------------------------------
## Separate from the RETRO render scale below: this is the size of the
## WINDOW, that is how many pixels the game is given. The project ships a
## 1280x720 base and Godot's default "keep" aspect letterboxes anything
## that is not 16:9 — which is why a wide monitor showed black bars down
## the sides. EXPAND gives the viewport the window's real aspect instead.
enum { WIN_WINDOWED = 0, WIN_BORDERLESS = 1, WIN_FULLSCREEN = 2 }
const WINDOW_MODE_NAMES: Array = ["WINDOW", "BORDERLESS", "FULLSCREEN"]
## Offered windowed sizes; anything larger than the monitor is dropped.
const WINDOW_SIZES: Array = [
	Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900),
	Vector2i(1680, 1050), Vector2i(1920, 1080), Vector2i(1920, 1200),
	Vector2i(2560, 1080), Vector2i(2560, 1440), Vector2i(3440, 1440),
	Vector2i(3840, 2160),
]

## RES_SUPER2 is the port's own addition: the world drawn at TWICE the
## window's width and scaled back down. The DOS art cannot get sharper,
## but the geometry can — "vektory predsa mozu byt renderovane vo vyssom
## ... rozliseni" (playtest 2026-09-12).
enum { RES_320 = 0, RES_640 = 1, RES_NATIVE = 2, RES_SUPER2 = 3 }
const RES_NAMES: Array = ["320 X 200", "640 X 480", "NATIVE", "NATIVE X2"]
const RES_WIDTHS: Array = [320.0, 640.0, 0.0, 0.0]
const RES_MAX: int = 3

## Anti-aliasing. The DOS renderer had none, so OFF stays the original.
## Godot's MSAA smooths POLYGON EDGES only, which is exactly the
## complaint — stair-stepped terrain against the night sky — while the
## textures stay as they were drawn.
const MSAA_NAMES: Array = ["OFF", "2X", "4X", "8X"]
const MSAA_MODES: Array = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X,
	Viewport.MSAA_4X, Viewport.MSAA_8X]
var msaa: int = 0

func set_msaa(i: int) -> void:
	msaa = clampi(i, 0, MSAA_NAMES.size() - 1)
	save()
	apply_aa()
	print("[settings] edge smoothing MSAA %s" % MSAA_NAMES[msaa])

func apply_aa() -> void:
	get_tree().root.msaa_3d = MSAA_MODES[clampi(msaa, 0, MSAA_MODES.size() - 1)]

var difficulty: int = MED
var detail: int = HIGH
var reverse_stereo: bool = false
## Flips the mouse's vertical look axis — the DOS CONTROL CONFIGURATION
## screen has no box for this (all 17 are spoken for), so it is the
## port's own addition, off by default like the rest of them.
var invert_y: bool = false
var resolution: int = RES_NATIVE
var window_mode: int = WIN_WINDOWED
var window_size: int = 0                # index into available_sizes()
## Brightness, a multiplier on the DOS gamma (main.gd). Taste differs —
## the DOS look went from "darker and flatter than the original" to "až
## moc svetlá" in a day — so it is the player's knob, not a constant.
signal brightness_changed(value: float)
const BRIGHTNESS_MIN: float = 0.5
const BRIGHTNESS_MAX: float = 1.8
var brightness_dos: float = 1.0

## Two looks the original could not offer, both OFF by default so the
## port still starts as DOS drew it:
##   hires_weapons — the 640x480 WEAPON*.CFA of MDMDHRES.BSA for the gun
##                   in your hands (asked for in playtest, 2026-09-11)
##   texture_filter — smooth (linear) texture filtering instead of the
##                   software renderer's nearest sampling
##   dynamic_lights — real lights from the gunfire, the explosions and
##                   the flying rounds, which also means the world's
##                   geometry has to TAKE light: DOS drew it flat and
##                   unshaded, so a light on it would show nothing.
var hires_weapons: bool = false
var texture_filter: bool = false
var dynamic_lights: bool = false
## The running game applies these at once (main.gd listens), not on the
## next map.
signal hires_weapons_changed(on: bool)
signal texture_filter_changed(on: bool)
signal dynamic_lights_changed(on: bool)

func set_hires_weapons(on: bool) -> void:
	hires_weapons = on
	save()
	hires_weapons_changed.emit(on)

func set_dynamic_lights(on: bool) -> void:
	dynamic_lights = on
	save()
	Render.restyle_all()               # the cached materials follow at once
	dynamic_lights_changed.emit(on)

func set_texture_filter(on: bool) -> void:
	texture_filter = on
	save()
	Render.restyle_all()
	texture_filter_changed.emit(on)

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		difficulty = clampi(int(cfg.get_value("game", "difficulty", MED)), LOW, HIGH)
		detail = clampi(int(cfg.get_value("video", "detail", HIGH)), LOW, HIGH)
		reverse_stereo = bool(cfg.get_value("audio", "reverse_stereo", false))
		invert_y = bool(cfg.get_value("game", "invert_y", false))
		resolution = clampi(int(cfg.get_value("video", "resolution", RES_NATIVE)), 0, RES_MAX)
		msaa = clampi(int(cfg.get_value("video", "msaa", 0)), 0, MSAA_NAMES.size() - 1)
		window_mode = clampi(int(cfg.get_value("video", "window_mode", WIN_WINDOWED)),
			WIN_WINDOWED, WIN_FULLSCREEN)
		window_size = int(cfg.get_value("video", "window_size", 0))
		brightness_dos = clampf(float(cfg.get_value("video", "brightness_dos", 1.0)),
			BRIGHTNESS_MIN, BRIGHTNESS_MAX)
		hires_weapons = bool(cfg.get_value("video", "hires_weapons", false))
		texture_filter = bool(cfg.get_value("video", "texture_filter", false))
		dynamic_lights = bool(cfg.get_value("video", "dynamic_lights", false))
	get_tree().root.size_changed.connect(apply_resolution)
	get_window().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	apply_window()
	apply_resolution()

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("video", "detail", detail)
	cfg.set_value("audio", "reverse_stereo", reverse_stereo)
	cfg.set_value("game", "invert_y", invert_y)
	cfg.set_value("video", "resolution", resolution)
	cfg.set_value("video", "msaa", msaa)
	cfg.set_value("video", "window_mode", window_mode)
	cfg.set_value("video", "window_size", window_size)
	cfg.set_value("video", "brightness_dos", brightness_dos)
	cfg.set_value("video", "hires_weapons", hires_weapons)
	cfg.set_value("video", "texture_filter", texture_filter)
	cfg.set_value("video", "dynamic_lights", dynamic_lights)
	cfg.save(CFG_PATH)

## The multiplier on the DOS gamma.
func brightness() -> float:
	return brightness_dos

func set_brightness(v: float) -> void:
	v = clampf(snappedf(v, 0.05), BRIGHTNESS_MIN, BRIGHTNESS_MAX)
	brightness_dos = v
	save()
	brightness_changed.emit(v)
	print("[settings] brightness %.2f" % v)

func set_difficulty(level: int) -> void:
	difficulty = clampi(level, LOW, HIGH)
	save()
	difficulty_changed.emit(difficulty)
	print("[settings] difficulty %s" % LEVEL_NAMES[difficulty])

func set_detail(level: int) -> void:
	detail = clampi(level, LOW, HIGH)
	save()
	detail_changed.emit(detail)
	print("[settings] render detail %s" % LEVEL_NAMES[detail])

func set_resolution(mode: int) -> void:
	resolution = clampi(mode, 0, RES_MAX)
	save()
	apply_resolution()
	print("[settings] render resolution %s" % RES_NAMES[resolution])

## The windowed sizes that fit on this monitor, smallest first.
func available_sizes() -> Array:
	var screen: Vector2i = DisplayServer.screen_get_size(
		DisplayServer.window_get_current_screen())
	var out: Array = []
	for s in WINDOW_SIZES:
		if s.x <= screen.x and s.y <= screen.y:
			out.append(s)
	if out.is_empty():
		out.append(Vector2i(1280, 720))
	if not out.has(screen):
		out.append(screen)              # the monitor's own resolution
	return out

func size_name(i: int) -> String:
	var list: Array = available_sizes()
	if i < 0 or i >= list.size():
		return "?"
	var s: Vector2i = list[i]
	return "%d X %d" % [s.x, s.y]

func set_window_mode(m: int) -> void:
	window_mode = clampi(m, WIN_WINDOWED, WIN_FULLSCREEN)
	save()
	apply_window()

func set_window_size(i: int) -> void:
	window_size = clampi(i, 0, available_sizes().size() - 1)
	save()
	apply_window()

## Put the window where the settings say. Fullscreen and borderless
## ignore the size — they take the screen.
func apply_window() -> void:
	var w := get_window()
	match window_mode:
		WIN_FULLSCREEN:
			w.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
		WIN_BORDERLESS:
			w.mode = Window.MODE_FULLSCREEN
		_:
			if w.mode != Window.MODE_WINDOWED:
				w.mode = Window.MODE_WINDOWED
			var list: Array = available_sizes()
			var i: int = clampi(window_size, 0, list.size() - 1)
			var want: Vector2i = list[i]
			if w.size != want:
				w.size = want
				var screen: Vector2i = DisplayServer.screen_get_size(
					DisplayServer.window_get_current_screen())
				w.position = (screen - want) / 2
	print("[settings] window %s %s" % [WINDOW_MODE_NAMES[window_mode],
		size_name(window_size) if window_mode == WIN_WINDOWED else ""])

## Drive Godot's 3D render scaling from the chosen mode.
func apply_resolution() -> void:
	var vp := get_tree().root
	if resolution == RES_SUPER2:
		# Above the window, then scaled back down: the one setting that
		# makes the GEOMETRY sharper rather than blurrier.
		vp.scaling_3d_scale = 2.0
	else:
		var want: float = float(RES_WIDTHS[resolution])
		if want <= 0.0 or vp.size.x <= 0:
			vp.scaling_3d_scale = 1.0
		else:
			vp.scaling_3d_scale = clampf(want / float(vp.size.x), 0.1, 1.0)
	apply_aa()

func set_reverse_stereo(on: bool) -> void:
	reverse_stereo = on
	save()

func set_invert_y(on: bool) -> void:
	invert_y = on
	save()
	print("[settings] invert mouse Y %s" % ("ON" if invert_y else "OFF"))

# --- what the difficulty actually does --------------------------------
## Multiplier on an enemy's rate of fire (LOW enemies shoot a quarter as
## often). The DOS roll is `rand() & 1023 < rate * factor`; the port
## divides the fire interval instead, which comes to the same thing.
func enemy_fire_scale() -> float:
	return float(DIFF_ENEMY_FIRE[difficulty])

## Multiplier on damage dealt TO enemies (LOW hits 1.5x harder).
func dmg_to_enemy() -> float:
	return float(DIFF_DMG_TO_ENEMY[difficulty])

## Multiplier on damage dealt TO the player by weapons. Radiation and
## falls are not scaled — DOS applies this in the projectile impact path
## only.
func dmg_to_player() -> float:
	return float(DIFF_DMG_TO_PLAYER[difficulty])

## Armour regeneration per second, as a fraction of a full bar.
func armor_regen() -> float:
	return float(DIFF_ARMOR_REGEN[difficulty])

## Fog / draw-distance multiplier for the current RENDER DETAIL.
func fog_scale() -> float:
	return float(DETAIL_FOG_SCALE[detail])
