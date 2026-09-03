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
signal weapon_view_changed(model: bool)

## RESOLUTION on the DOS screen is the video mode: 320x200 or 640x480.
## This port always opens a modern window, so the setting drives the 3D
## RENDER resolution instead — the world is drawn at 320 or 640 pixels
## wide and stretched up, which is what gives the chunky software look.
## NATIVE (the port's default) renders at the window's own size.
enum { RES_320 = 0, RES_640 = 1, RES_NATIVE = 2 }
const RES_NAMES: Array = ["320 X 200", "640 X 480", "NATIVE"]
const RES_WIDTHS: Array = [320.0, 640.0, 0.0]

var difficulty: int = MED
var detail: int = HIGH
var reverse_stereo: bool = false
var resolution: int = RES_NATIVE
## The weapon in the player's hands: false = the DOS hand-drawn CFA
## animation (with the soldier's gloves), true = the ENHANCED 3D model.
## The art is the better-looking of the two, so it stays the default.
var weapon_3d: bool = false

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		difficulty = clampi(int(cfg.get_value("game", "difficulty", MED)), LOW, HIGH)
		detail = clampi(int(cfg.get_value("video", "detail", HIGH)), LOW, HIGH)
		reverse_stereo = bool(cfg.get_value("audio", "reverse_stereo", false))
		resolution = clampi(int(cfg.get_value("video", "resolution", RES_NATIVE)), 0, 2)
		weapon_3d = bool(cfg.get_value("video", "weapon_3d", false))
	get_tree().root.size_changed.connect(apply_resolution)
	apply_resolution()

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("video", "detail", detail)
	cfg.set_value("audio", "reverse_stereo", reverse_stereo)
	cfg.set_value("video", "resolution", resolution)
	cfg.set_value("video", "weapon_3d", weapon_3d)
	cfg.save(CFG_PATH)

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
	resolution = clampi(mode, 0, 2)
	save()
	apply_resolution()
	print("[settings] render resolution %s" % RES_NAMES[resolution])

## Drive Godot's 3D render scaling from the chosen mode.
func apply_resolution() -> void:
	var vp := get_tree().root
	var want: float = float(RES_WIDTHS[resolution])
	if want <= 0.0 or vp.size.x <= 0:
		vp.scaling_3d_scale = 1.0
	else:
		vp.scaling_3d_scale = clampf(want / float(vp.size.x), 0.1, 1.0)

func set_weapon_3d(on: bool) -> void:
	weapon_3d = on
	save()
	weapon_view_changed.emit(on)

func set_reverse_stereo(on: bool) -> void:
	reverse_stereo = on
	save()

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
