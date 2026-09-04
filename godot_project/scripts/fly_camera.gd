## First-person player controller.
##
## Walk mode (default): gravity pulls the player down; they stand and
## walk on the terrain and building floors, collide with walls, and jump
## with Space. Noclip mode (F8, debug): gravity off, free 6-DOF flight
## straight through all geometry.
##
## Desktop:  click to capture the mouse, WASD/arrows walk, mouse looks,
##           Space jumps, Shift sprints, ESC releases.
## Android:  driven by the on-screen TouchControls D-pads.

extends CharacterBody3D

@export var walk_speed: float = 600.0
@export var sprint_multiplier: float = 2.5
@export var fly_speed: float = 3500.0          # noclip
@export var gravity: float = 4500.0
## Jump apex = v²/2g: 950 → ~100 u (a crate, not a truck). The old 1800
## reached 360 u — four eye heights, far above the DOS hop (2026-09-03).
@export var jump_speed: float = 950.0
@export var mouse_sensitivity: float = 0.003
@export var touch_look_speed: float = 2.2

const FxParticles := preload("res://scripts/fx_particles.gd")
const Tracer := preload("res://scripts/tracer.gd")
const Projectile := preload("res://scripts/projectile.gd")
const Grenade := preload("res://scripts/grenade.gd")
const MuzzleFlash := preload("res://scripts/muzzle_flash.gd")
const SmokePuff := preload("res://scripts/smoke_puff.gd")
const CFAFile := preload("res://scripts/loaders/cfa_file.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const Palette := preload("res://scripts/loaders/palette.gd")
const Explosion := preload("res://scripts/explosion.gd")
const WeaponModels := preload("res://scripts/weapon_models.gd")
## How far ahead of the muzzle the player's own tracer starts.
const TRACER_START: float = 420.0

@onready var _cam: Camera3D = $Camera3D

var _yaw: float = 0.0
var _pitch: float = 0.0
var _captured: bool = false
var _mobile: bool = OS.has_feature("mobile")
## Debug: when true, gravity/collision are off (fly through everything).
var noclip: bool = false
## Deathmatch: no movement / fire while dead, typing in chat or waiting
## for the server's spawn (dm_game.gd drives this).
var input_locked: bool = false
## Deathmatch class: HUMAN 1.3, TERMINATOR 0.85 (Net.CLASS_SPEED).
var class_speed: float = 1.0
## Debug: when true, the player takes no damage. Static so the menu's
## DEBUG TOOLS screen can arm it before a map loads; F9 toggles it
## in-game. Persists across scene changes.
static var god_mode: bool = false

# Driven each frame by the TouchControls overlay; stays zero on desktop.
var ui_move: Vector2 = Vector2.ZERO   # x = strafe (+right), y = forward (+)
var ui_look: Vector2 = Vector2.ZERO   # x = yaw rate, y = pitch rate, -1..1
var ui_vert: float = 0.0              # >0 = jump (walk) / rise (noclip)

@export var max_health: float = 100.0
var health: float = 100.0
var ui_fire: bool = false             # set by the TouchControls FIRE button
var _fire_cd: float = 0.0
var _spawn_pos: Vector3 = Vector3.ZERO
var _spawn_yaw: float = 0.0
## Anti-wedge: seconds of movement input without progress, and the last
## position where walking was free (fallback teleport target).
var _stuck_t: float = 0.0
var _good_t: float = 0.0
var _last_good: Vector3 = Vector3.ZERO
const STUCK_TIME: float = 0.35
const STUCK_RESET_TIME: float = 1.8
## DOS stair climbing: the player is a cylinder that re-finds the floor
## within ±80 units of its feet every move (the same ±80 the enemy floor
## search uses), so door sills and stair risers up to that height are
## simply walked over. A capsule of radius 26 climbs only a few units
## by itself — MAP.231's corridor sill (72 u) and its stairs stopped the
## player dead. Classic step-up: rise, advance, drop back onto a floor.
const STEP_HEIGHT: float = 80.0
## Keyboard turning / looking (TURN LEFT-RIGHT, LOOK UP-DOWN), rad/s.
const KEY_TURN_RATE: float = 2.4
const KEY_LOOK_RATE: float = 1.5
## A hand-thrown grenade (RMB) leaves the hand far slower than the
## launcher's round (Grenade.SPEED) — a lob, not a shot.
const HAND_GRENADE_SPEED: float = 1500.0
const STEP_PROBE: float = 14.0                 # minimum forward advance

# Weapon roster — DOS records 0..12 from `DAT_0004361c` in their
# mouse-wheel cycle order (skynet_gh.c:27789-27828, cycle struct at VA
# 0x000435e0 = [0,1,…,12], 13 entries). Slot N's viewmodel is
# `WEAPON%02d.CFA`. Slot identities follow the STRINGS.PRS + CFA-art
# mapping (2=ASSAULT RIFLE … 4=SHOTGUN, the 12-frame pump … 10=PLASMA
# RIFLE), confirmed in-game 2026-07-27 — the previous table had names
# shifted one slot against their viewmodels for slots 2..10. DOS
# record-keyed fields (vx = record +0x00) stay per slot.
#
# Per-record fields, all read straight from the two DOS tables
# (weapon record at 0x4361c + stride 0x60; its ammo type at 0x40728 +
# stride 0x32, record +0x14):
#   kind   ammo-type flight family (ammo +0x00 callback): 0 = instant
#          "bullet"; 0x000f3414 = gravity "grenade"; 0x000f344d =
#          straight bolt flying a .3D model — "rocket"/"laser"/"plasma"
#          by the model named at ammo +0x04 (rocket/laser1/laser2.3d).
#          MINI ROCKET is a bullet-family type (t21) in DOS.
#   dmg    |ammo +0x0c| (negative = blast damage), splash = ammo +0x10
#   rate   weapon +0x24; DOS countdown = 0x10000 / rate, so the shot
#          delay is FIRE_RATE_SCALE / rate — the scale pins the UZI to
#          0.10 s and everything else follows the table's ratios.
#   pool   weapon +0x4c shared ammo pool, cost = +0x50 rounds per shot
#   snd    fire sound: weapon +0x48, or the ammo type's +0x1c when -1
#   sel    select sound id (+0x54), dry = empty-pool sound id (+0x58)
#   vx     viewmodel screen X (+0x00); cfa = WEAPON%02d.CFA
# Slot identities follow STRINGS.PRS + the CFA art (confirmed in-game
# 2026-07-27). JEEP PLASMA is record 13+ (vehicle/MP), not in the cycle.
var _weapons: Array = [
	{"name": "PIPE",             "kind": "melee",   "dmg": 50.0,  "rate": 2,  "pool": -1, "cost": 0,  "snd": "SWISH1.RAW",   "sel": -1, "dry": -1, "cfa": "WEAPON00.CFA", "animspd": 18, "vx": 62},
	{"name": "UZI",              "kind": "bullet",  "dmg": 10.0,  "rate": 5,  "pool": 0,  "cost": 1,  "snd": "SHOTS5.RAW",   "sel": 9,  "dry": 10, "cfa": "WEAPON01.CFA", "animspd": 16, "vx": 156},
	{"name": "ASSAULT RIFLE",    "kind": "bullet",  "dmg": 20.0,  "rate": 4,  "pool": 0,  "cost": 3,  "snd": "SHOTS2.RAW",   "sel": 9,  "dry": 10, "cfa": "WEAPON02.CFA", "animspd": 16, "vx": 154},
	{"name": "MACHINE GUN",      "kind": "bullet",  "dmg": 20.0,  "rate": 8,  "pool": 0,  "cost": 4,  "snd": "FASTGUN2.RAW", "sel": 9,  "dry": 10, "cfa": "WEAPON03.CFA", "animspd": 16, "vx": 154},
	{"name": "SHOTGUN",          "kind": "shotgun", "dmg": 50.0,  "rate": 1,  "pool": 1,  "cost": 1,  "snd": "SHTGUN.RAW",   "sel": 9,  "dry": 10, "cfa": "WEAPON04.CFA", "animspd": 12, "vx": 64},
	{"name": "GRENADE LAUNCHER", "kind": "grenade", "dmg": 200.0, "rate": 1,  "pool": 2,  "cost": 1,  "snd": "GRNLAUN2.RAW", "sel": 9,  "dry": 10, "cfa": "WEAPON05.CFA", "animspd": 8,  "vx": 156, "splash": 256.0},
	{"name": "ROCKET LAUNCHER",  "kind": "rocket",  "dmg": 400.0, "rate": 1,  "pool": 3,  "cost": 1,  "snd": "ROCKET2.RAW",  "sel": 9,  "dry": 10, "cfa": "WEAPON06.CFA", "animspd": 12, "vx": 175, "splash": 512.0},
	{"name": "LASER RIFLE",      "kind": "laser",   "dmg": 25.0,  "rate": 6,  "pool": 4,  "cost": 2,  "snd": "LASER1.RAW",   "sel": 17, "dry": 16, "cfa": "WEAPON07.CFA", "animspd": 13, "vx": 168},
	{"name": "LASER CANNON",     "kind": "laser",   "dmg": 50.0,  "rate": 6,  "pool": 4,  "cost": 5,  "snd": "LASER2.RAW",   "sel": 17, "dry": 16, "cfa": "WEAPON08.CFA", "animspd": 16, "vx": 160},
	{"name": "PLASMA PISTOL",    "kind": "plasma",  "dmg": 25.0,  "rate": 3,  "pool": 4,  "cost": 1,  "snd": "LASER8.RAW",   "sel": 17, "dry": 16, "cfa": "WEAPON09.CFA", "animspd": 16, "vx": 152},
	{"name": "PLASMA RIFLE",     "kind": "plasma",  "dmg": 50.0,  "rate": 3,  "pool": 4,  "cost": 2,  "snd": "LASER6.RAW",   "sel": 17, "dry": 16, "cfa": "WEAPON10.CFA", "animspd": 16, "vx": 160},
	{"name": "PLASMA CANNON",    "kind": "plasma",  "dmg": 100.0, "rate": 3,  "pool": 4,  "cost": 10, "snd": "LASER3.RAW",   "sel": 17, "dry": 16, "cfa": "WEAPON11.CFA", "animspd": 16, "vx": 128},
	# Record 12 is the DOS "superuzi" cheat weapon (cheat handler
	# 0x141fc8 sets record 12's owned bit and selects it): an UZI with the
	# 9999-round pool and a 20/s cadence. STRINGS.PRS calls it MINI
	# ROCKET; the player knows it as the red super uzi.
	{"name": "SUPER UZI",        "kind": "bullet",  "dmg": 50.0,  "rate": 20, "pool": 12, "cost": 1,  "snd": "SHOTS5.RAW",   "sel": 9,  "dry": 10, "cfa": "WEAPON12.CFA", "animspd": 16, "vx": 156},
	# Vehicle guns (DOS records 20/22 jeep, 24/25 HK — owned bit 2 = vehicle
	# only, no viewmodel). Ammo types 18 (laser2, -40), 5 (rocket, -400,
	# splash 512), 22 (laser1, -75). Pool 10 = vehicle energy 1000/2000
	# at 100 per bolt, pool 11 = vehicle rockets 40/50. `snd_id` = the
	# ammo type's fire sound id (+0x1c), `veh` = the vehicle that mounts it.
	{"name": "JEEP PLASMA",      "kind": "plasma",  "dmg": 40.0,  "rate": 8,  "pool": 10, "cost": 100, "snd": "", "snd_id": 14, "sel": 17, "dry": 16, "cfa": "", "vx": 160, "splash": 64.0,  "veh": 1},
	{"name": "JEEP ROCKETS",     "kind": "rocket",  "dmg": 400.0, "rate": 1,  "pool": 11, "cost": 1,   "snd": "", "snd_id": 26, "sel": 9,  "dry": 10, "cfa": "", "vx": 160, "splash": 512.0, "veh": 1},
	{"name": "HK LASER",         "kind": "laser",   "dmg": 75.0,  "rate": 8,  "pool": 10, "cost": 100, "snd": "", "snd_id": 12, "sel": 17, "dry": 16, "cfa": "", "vx": 160, "splash": 64.0,  "veh": 2},
	{"name": "HK ROCKETS",       "kind": "rocket",  "dmg": 400.0, "rate": 1,  "pool": 11, "cost": 1,   "snd": "", "snd_id": 26, "sel": 9,  "dry": 10, "cfa": "", "vx": 160, "splash": 512.0, "veh": 2},
]
## Weapon slots per vehicle (indices into `_weapons`): the gun on the
## fire key, the rocket pod on the throw key (the DOS secondary).
const VEHICLE_WEAPONS: Dictionary = {1: [13, 14], 2: [15, 16]}

## --- Secondary (thrown) weapons ---------------------------------------
## DOS keeps TWO selected-weapon registers: WeaponSelectPri (0x1254c6)
## for the gun and WeaponSelectScn (0x125585) for the thrown item, and
## the THROW key uses the second one. The campaign start list (0x43470)
## already owns weapon records 14/15/16/18/19 and the pool table
## (0x43ff4) stocks them — 25 pipe bombs, 20 molotovs, 2 canister bombs,
## 1 satchel, 0 grenades — with record 15, the MOLOTOV, selected by
## default (0x44396). In a vehicle the secondary is the rocket pod, which
## is why the jeep answers the throw key with a rocket.
##
## The DOS CONTROL CONFIGURATION screen has no bind box for changing the
## secondary — all 17 of its boxes are accounted for — so the original
## was stuck with whatever it started with. The port cycles it with the
## `0` key and the middle mouse button.
const THROWABLES: Array = [
	{"name": "PIPE BOMB",     "pool": 5, "dmg": 150.0, "splash": 220.0, "fuse": 2.2, "speed": 2600.0},
	{"name": "MOLOTOV",       "pool": 6, "dmg": 60.0,  "splash": 190.0, "fuse": 3.0, "speed": 2400.0, "burst": true, "fire": true},
	{"name": "GRENADE",       "pool": 2, "dmg": 200.0, "splash": 256.0, "fuse": 2.5, "speed": 2200.0},
	{"name": "CANISTER BOMB", "pool": 8, "dmg": 400.0, "splash": 520.0, "fuse": 2.5, "speed": 2000.0},
	{"name": "SATCHEL",       "pool": 9, "dmg": 700.0, "splash": 760.0, "fuse": 4.0, "speed": 1800.0},
]
const THROW_DEFAULT: int = 1          # MOLOTOV, as the DOS default
var _throw_idx: int = THROW_DEFAULT
## HUD-facing mirror of the selected thrown item (main.gd reads these).
var secondary_name: String = ""
var secondary_ammo: int = 0
const VEH_FOOT: int = 0
const VEH_JEEP: int = 1
const VEH_HK: int = 2
const VEH_NAMES: Array = ["", "JEEP", "HK"]
## Eye height above the body origin per vehicle (DOS foot = 75).
const VEH_EYE: Array = [75.0, 92.0, 110.0]
## Capsule (radius, height) per vehicle — the HUMMER is 106×75×227, the
## HK_FTR 357×205×501; a rounder body slides over terrain and rubble.
## On foot the DOS player is a cylinder that ignores ceilings; interior
## doorways are as small as 70 × 105 u (MAP.231 ROM4 → corridor), so
## the capsule stays well inside that with the safe margin added.
const VEH_CAPSULE: Array = [[22.0, 80.0], [55.0, 110.0], [110.0, 220.0]]
## Jeep: DOS mission 2/6 driving — throttle with inertia, mouse steers.
const JEEP_MAX_SPEED: float = 1800.0
const JEEP_REVERSE_SPEED: float = 700.0
const JEEP_ACCEL: float = 1400.0
const JEEP_BRAKE: float = 2600.0
const JEEP_DRAG: float = 900.0
const JEEP_TURN_RATE: float = 1.6              # rad/s with A/D at full speed
## HK: DOS mission 7 flight — hover, thrust in every axis, no gravity.
const HK_SPEED: float = 2600.0
const HK_STRAFE: float = 1400.0
const HK_CLIMB: float = 900.0
const HK_ACCEL: float = 2200.0
const HK_MIN_ALTITUDE: float = 150.0
## The vehicle this player is in (VEH_*). Set by the level (mission
## table: MAP.220/260 jeep, MAP.270 HK) or, in a deathmatch, by
## climbing into a parked one.
var vehicle: int = 0
var _veh_speed: float = 0.0                    # jeep forward speed (signed)
var _foot_owned: Dictionary = {}
var _foot_weapon: int = 1
var _weapon_idx: int = 0
## Weapon ownership — DOS record +0x5c bit 0. A new SkyNET campaign
## game hands out the list at 0x43470 (FUN_0012562c from the session
## start, skynet_gh.c:21838): PIPE, UZI, ASSAULT RIFLE, SHOTGUN, LASER
## RIFLE (plus the jeep/thrown-item records that have no slot here).
const START_WEAPONS: Array = [0, 1, 2, 4, 7]
## The "arnold" cheat list at 0x4350c: every on-foot weapon except the
## super uzi (its own cheat).
const ALL_WEAPONS: Array = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
const SUPER_UZI: int = 12
var _owned: Dictionary = {}          # weapon idx → true
# HUD mirrors of the active weapon (read by the level controller).
var weapon_name: String = "UZI"
var ammo: int = 500

## Shot delay = FIRE_RATE_SCALE / rate. DOS (skynet_gh.c:27936, :28224):
## the cooldown starts at 0x10000 / rec[+0x24] and every frame drops by
## DAT_00043100 = the frame delta in 16.16 seconds — i.e. a weapon fires
## exactly rec[+0x24] shots per second (UZI 5/s, MG 8/s, shotgun 1/s,
## mini rocket 20/s). The scale is therefore 1.0; 0.5 ran twice as fast.
const FIRE_RATE_SCALE: float = 1.0
const DRY_FIRE_DELAY: float = 0.25
## TEXTURE.365 — the bullet ammo types' impact effect (ammo +0x08 =
## sprite index 0xB680 → bank 365), puffed where a shot strikes geometry.
const IMPACT_BANK_BULLET: int = 365

# Shared ammo pools — Skynet.exe 0x43ff4, 13 × {0, initial, max}. A
# weapon's record +0x4c names its pool; +0x50 is the cost per shot:
#   0  bullets   500/750  UZI ×1 · ASSAULT RIFLE ×3 · MACHINE GUN ×4
#   1  shells     50/200  SHOTGUN ×1
#   2  grenades    0/99   GRENADE LAUNCHER ×1
#   3  rockets     0/99   ROCKET LAUNCHER ×1
#   4  energy    500/800  LASER RIFLE ×2 · LASER CANNON ×5 · PLASMA
#                         PISTOL ×1 · PLASMA RIFLE ×2 · PLASMA CANNON ×10
#   12 super-uzi 9999/9999 SUPER UZI ×1 (the only unlimited one)
# DOS starts grenades and rockets at 0 — they come only from pickups,
# whose weapon/ammo types (TEXTURE.200/201 records) are not decoded
# yet — so a handful is seeded here to keep the launchers usable.
#   5  pipe bombs 25/99  · 6 molotovs 20/99 · 8 canisters 2/99 ·
#   9  satchel      1/99   — the SECONDARY (thrown) items, see THROWABLES
const POOL_TABLE: Dictionary = {
	0: [500, 750], 1: [50, 200], 2: [0, 99], 3: [0, 99],
	4: [500, 800], 5: [25, 99], 6: [20, 99], 7: [0, 99], 8: [2, 99],
	9: [1, 99], 10: [1000, 2000], 11: [40, 50], 12: [9999, 9999],
}
## Rounds a generic ammo pickup adds per pool (placeholder until the
## pickup sprite records are decoded into specific ammo types).
const PICKUP_AMMO: Dictionary = {0: 50, 1: 10, 2: 5, 3: 2, 4: 50,
	5: 5, 6: 3, 8: 1, 9: 1}
var _pools: Dictionary = {}          # pool id → rounds left

# --- weapon viewmodel (the gun drawn at the bottom of the screen) -------
var _vm_layer: CanvasLayer = null
var _viewmodel: TextureRect = null
var _vm_cache: Dictionary = {}        # weapon idx → Array[ImageTexture]
var _vm_idx: int = 0
var _vm_t: float = 0.0
var _vm_firing: bool = false

func _ready() -> void:
	add_to_group("player")
	# Forgiving floor handling so steep, rocky terrain stays walkable
	# instead of catching the capsule like a wall.
	floor_max_angle = deg_to_rad(62.0)
	floor_snap_length = 150.0
	floor_block_on_wall = false
	floor_constant_speed = true
	# The world is in DOS units (thousands), so the default 0.001 collision
	# margin is microscopic — the solver cannot depenetrate and the capsule
	# wedges against walls. Scale the margin up and always slide along walls.
	safe_margin = 4.0
	wall_min_slide_angle = 0.0
	_yaw = rotation.y
	if _cam != null:
		_pitch = _cam.rotation.x
	_reset_pools()
	_reset_owned()
	_build_viewmodel()

## Place the player at a spawn point facing `yaw` (radians). Called by
## the level controller once the map is loaded. `reset_state` restores
## full health and the DOS starting ammo (a fresh mission or a respawn);
## map exits pass false so HP/ammo carry into the interior and back.
func set_spawn(pos: Vector3, yaw: float, reset_state: bool = true) -> void:
	global_position = pos
	_yaw = yaw
	_pitch = 0.0
	velocity = Vector3.ZERO
	rotation = Vector3(0.0, yaw, 0.0)
	if _cam != null:
		_cam.rotation = Vector3.ZERO
	_spawn_pos = pos
	_spawn_yaw = yaw
	if reset_state:
		health = max_health
		armor = 0.0
		_reset_pools()
		_reset_owned()
	_sync_hud()

## Point the view (radians) — automation / debug.
func set_view(yaw: float, pitch: float) -> void:
	_yaw = yaw
	_pitch = clampf(pitch, -PI * 0.49, PI * 0.49)
	rotation.y = yaw
	if _cam != null:
		_cam.rotation.x = _pitch

func _reset_pools() -> void:
	for p in POOL_TABLE:
		_pools[p] = int(POOL_TABLE[p][0])

## Back to the campaign's starting arsenal; the active slot must be
## one of them.
func _reset_owned() -> void:
	_owned.clear()
	if vehicle != VEH_FOOT:
		for w in VEHICLE_WEAPONS.get(vehicle, []):
			_owned[int(w)] = true
		if not _owned.has(_weapon_idx):
			_weapon_idx = int(VEHICLE_WEAPONS[vehicle][0])
		return
	for w in START_WEAPONS:
		_owned[int(w)] = true
	if not _owned.has(_weapon_idx):
		_weapon_idx = int(START_WEAPONS[1]) if START_WEAPONS.size() > 1 else 0
		_vm_idx = 0
		_vm_firing = false

## Climb into / out of a vehicle (VEH_*). The on-foot arsenal is parked
## with the body: a jeep mounts only its plasma guns and rockets, the
## HK its laser and rockets; the eye height and the collision capsule
## follow the vehicle. Health is the driver's — DOS keeps one bar.
func _reset_aim() -> void:
	_aim_yaw = 0.0
	_aim_pitch = 0.0

func set_vehicle(v: int) -> void:
	_reset_aim()
	if _dust != null and is_instance_valid(_dust):
		_dust.queue_free()
	_dust = null
	v = clampi(v, VEH_FOOT, VEH_HK)
	if v == vehicle:
		return
	if vehicle == VEH_FOOT:
		_foot_owned = _owned.duplicate()
		_foot_weapon = _weapon_idx
	vehicle = v
	_veh_speed = 0.0
	_wheel = 0.0
	_tilt_pitch = 0.0
	_tilt_roll = 0.0
	velocity = Vector3.ZERO
	if _cam != null:
		_cam.rotation.z = 0.0
	if v == VEH_FOOT:
		_owned = _foot_owned.duplicate() if not _foot_owned.is_empty() else _owned
		_weapon_idx = _foot_weapon
		if not _owned.has(_weapon_idx):
			_reset_owned()
	else:
		_owned.clear()
		for w in VEHICLE_WEAPONS[v]:
			_owned[int(w)] = true
		_weapon_idx = int(VEHICLE_WEAPONS[v][0])
	_vm_idx = 0
	_vm_firing = false
	_fire_cd = 0.3
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING if v == VEH_HK else CharacterBody3D.MOTION_MODE_GROUNDED
	if _cam != null:
		_cam.position.y = float(VEH_EYE[v])
	var cs: CollisionShape3D = get_node_or_null("CollisionShape3D")
	if cs != null:
		var cap := CapsuleShape3D.new()
		cap.radius = float(VEH_CAPSULE[v][0])
		cap.height = float(VEH_CAPSULE[v][1])
		cs.shape = cap
		cs.position = Vector3(0.0, cap.height * 0.5, 0.0)
	if v == VEH_HK:
		# Lift off the ground so the hover starts clear of the terrain.
		global_position.y += 60.0
	if v != VEH_FOOT:
		Audio.play_id(int(_weapons[_weapon_idx].get("sel", -1)), -8.0)
	_start_engine(v)
	_sync_hud()
	print("[player] vehicle: %s" % (VEH_NAMES[v] if v > 0 else "on foot"))

## Engine loops from the DOS sound table: careng1 (id 69) for the jeep,
## hk2 (id 48, the same loop the enemy HKs run) for the HK; the jeep
## revs with its speed (DOS action 0xd6-0xda ramps the vehicle pitch).
const ENGINE_SOUND_ID: Array = [-1, 69, 48]
const CAR_START_ID: int = 123
var _engine: AudioStreamPlayer3D = null

func _start_engine(v: int) -> void:
	if _engine != null:
		_engine.queue_free()
		_engine = null
	if v == VEH_FOOT:
		return
	if v == VEH_JEEP:
		Audio.play_id(CAR_START_ID, -6.0)
	_engine = Audio.attach_loop_3d(int(ENGINE_SOUND_ID[v]), self, -9.0)
	if _engine != null:
		_engine.position = Vector3(0.0, 40.0, 60.0)     # under the bonnet / behind the seat
		_engine.pitch_scale = 0.85

## Vehicle guns never run dry — they overheat. Pool 10 (the cockpit
## ENERGY read-out, DOS 1000/2000) drains 100 per bolt and recharges
## once the trigger rests; an emptied gun stays cold until it is back
## to VEH_COOL_LEVEL, so a long burst forces a pause.
const VEH_ENERGY_POOL: int = 10
const VEH_REGEN_PER_S: float = 450.0
const VEH_REGEN_DELAY: float = 0.35
const VEH_COOL_LEVEL: int = 400
var _veh_since_shot: float = 10.0
var _veh_overheated: bool = false

func _regen_vehicle_energy(delta: float) -> void:
	if vehicle == VEH_FOOT:
		return
	_veh_since_shot += delta
	if _veh_since_shot < VEH_REGEN_DELAY:
		return
	var mx: int = int(POOL_TABLE[VEH_ENERGY_POOL][1])
	var cur: int = int(_pools.get(VEH_ENERGY_POOL, 0))
	if cur < mx:
		_pools[VEH_ENERGY_POOL] = mini(cur + int(VEH_REGEN_PER_S * delta), mx)
		if _veh_overheated and int(_pools[VEH_ENERGY_POOL]) >= VEH_COOL_LEVEL:
			_veh_overheated = false
		if int(_weapons[_weapon_idx].get("pool", -1)) == VEH_ENERGY_POOL:
			ammo = int(_pools[VEH_ENERGY_POOL])

func _update_engine() -> void:
	if _engine == null:
		return
	if vehicle == VEH_JEEP:
		var k: float = clampf(absf(_veh_speed) / JEEP_MAX_SPEED, 0.0, 1.0)
		_engine.pitch_scale = lerpf(_engine.pitch_scale, 0.75 + 0.75 * k, 0.1)
		_engine.volume_db = -11.0 + 5.0 * k
	elif vehicle == VEH_HK:
		var k: float = clampf(velocity.length() / HK_SPEED, 0.0, 1.0)
		_engine.pitch_scale = lerpf(_engine.pitch_scale, 0.9 + 0.35 * k, 0.05)
		_engine.volume_db = -10.0 + 4.0 * k

func owns(idx: int) -> bool:
	return _owned.has(idx)

## Owned weapon indices, ascending.
func owned_list() -> Array:
	var out: Array = _owned.keys()
	out.sort()
	return out

## Next owned slot from `from` in direction `dir` (wheel / cheats).
func _next_owned(from: int, dir: int) -> int:
	var n: int = _weapons.size()
	var i: int = from
	for _k in n:
		i = (i + dir + n) % n
		if _owned.has(i):
			return i
	return from

## Rounds left for weapon `idx` — its pool's count, or 99 for the pipe.
func _ammo_for(idx: int) -> int:
	var pool: int = int(_weapons[idx].get("pool", -1))
	if pool < 0:
		return 99
	return int(_pools.get(pool, 0))

## Mirror the active weapon's name/ammo into the HUD-facing fields.
func _sync_hud() -> void:
	weapon_name = String(_weapons[_weapon_idx]["name"])
	ammo = _ammo_for(_weapon_idx)
	if vehicle != VEH_FOOT:
		var vw: int = int(VEHICLE_WEAPONS[vehicle][1])
		secondary_name = String(_weapons[vw]["name"])
		secondary_ammo = _ammo_for(vw)
	else:
		secondary_name = String(THROWABLES[_throw_idx]["name"])
		secondary_ammo = int(_pools.get(int(THROWABLES[_throw_idx]["pool"]), 0))

## Switch to weapon `idx` (clamped). Plays the record's select sound
## (+0x54: uzicock3 for ballistic, ppcload for energy weapons).
func _select_weapon(idx: int) -> void:
	idx = clampi(idx, 0, _weapons.size() - 1)
	# DOS WeaponSelect (skynet_gh.c:27846) ignores slots without the
	# owned bit — the key just does nothing.
	if idx == _weapon_idx or not _owned.has(idx):
		return
	_weapon_idx = idx
	_fire_cd = maxf(_fire_cd, 0.15)
	_vm_idx = 0
	_vm_firing = false
	_sync_hud()
	Audio.play_id(int(_weapons[idx].get("sel", -1)), -8.0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F8:
		noclip = not noclip
		velocity = Vector3.ZERO
		print("[player] noclip %s" % ("ON" if noclip else "OFF"))
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F9:
		god_mode = not god_mode
		print("[player] god mode %s" % ("ON" if god_mode else "OFF"))
		return
	if _mobile:
		return                           # touch handled by TouchControls
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if _captured:
					_shoot()
				else:
					_capture(true)
			MOUSE_BUTTON_RIGHT:
				if _captured:
					_throw_secondary()
			MOUSE_BUTTON_MIDDLE:
				if _captured:
					cycle_throwable(1)
			MOUSE_BUTTON_WHEEL_UP:
				_select_weapon(_next_owned(_weapon_idx, -1))
			MOUSE_BUTTON_WHEEL_DOWN:
				_select_weapon(_next_owned(_weapon_idx, 1))
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_capture(false)
		elif Controls.matches(event, "activate"):
			_try_activate()
		elif Controls.matches(event, "throw"):
			_throw_secondary()
		elif Controls.matches(event, "center_view"):
			set_view(_yaw, 0.0)           # CENTER VIEW: level the horizon
		elif event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_select_weapon(event.keycode - KEY_1)
		elif event.keycode == KEY_0:
			cycle_throwable(1)          # 0 cycles the thrown item
	elif event is InputEventMouseMotion and _captured and vehicle == VEH_JEEP:
		# In the jeep the mouse moves the gun crosshair; the keys drive.
		_aim_yaw = clampf(_aim_yaw - event.relative.x * mouse_sensitivity, -JEEP_AIM_YAW, JEEP_AIM_YAW)
		_aim_pitch = clampf(_aim_pitch - event.relative.y * mouse_sensitivity, JEEP_AIM_PITCH_DOWN, JEEP_AIM_PITCH_UP)
		_pitch = 0.0
	elif event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)

func _physics_process(delta: float) -> void:
	# --- look ---------------------------------------------------------
	if ui_look != Vector2.ZERO:
		_yaw -= ui_look.x * touch_look_speed * delta
		_pitch = clamp(_pitch - ui_look.y * touch_look_speed * delta, -1.5, 1.5)
	rotation.y = _yaw
	if _cam != null:
		_cam.rotation.x = _pitch

	if input_locked:
		# Dead / chatting / unspawned: gravity only, no intent.
		ui_fire = false
		if not noclip:
			velocity.x = 0.0
			velocity.z = 0.0
			if not is_on_floor():
				velocity.y -= gravity * delta
			else:
				velocity.y = 0.0
			move_and_slide()
		return

	# --- water --------------------------------------------------------
	if water_level < INF and vehicle == VEH_FOOT and not noclip:
		_water_check()
		if health > 0.0:
			_breathe(delta)
	elif in_water:
		in_water = false
		head_under = false

	# --- weapon -------------------------------------------------------
	if _fire_cd > 0.0:
		_fire_cd -= delta
	_regen_vehicle_energy(delta)
	# The DOS shield recharges by itself, faster on the easier levels
	# (difficulty table field 4, 0.025 / 0.015 / 0.0125 per second).
	if armor < 1.0 and health > 0.0:
		armor = minf(armor + Settings.armor_regen() * delta, 1.0)
	if ui_fire:
		ui_fire = false
		_shoot()
	elif _captured and not _mobile \
			and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
				or Controls.is_pressed("fire")):
		_shoot()                          # held trigger — DOS auto-fire

	# --- movement input (horizontal intent) ---------------------------
	var fwd_in: float = 0.0
	var str_in: float = 0.0
	if Controls.is_pressed("forward"): fwd_in += 1.0
	if Controls.is_pressed("back"):    fwd_in -= 1.0
	if Controls.is_pressed("right"):   str_in += 1.0
	if Controls.is_pressed("left"):    str_in -= 1.0
	# TURN LEFT / TURN RIGHT steer the view, unless SLIDE is held — the
	# DOS strafe modifier, which turns them into sidesteps instead.
	var turn: float = 0.0
	if Controls.is_pressed("turn_left"):  turn += 1.0
	if Controls.is_pressed("turn_right"): turn -= 1.0
	if turn != 0.0:
		if Controls.is_pressed("slide"):
			str_in -= turn
		else:
			_yaw = wrapf(_yaw + turn * KEY_TURN_RATE * delta, -PI, PI)
	# LOOK UP / LOOK DOWN tilt the view (the mouse does it too).
	var tilt: float = 0.0
	if Controls.is_pressed("look_up"):   tilt += 1.0
	if Controls.is_pressed("look_down"): tilt -= 1.0
	if tilt != 0.0:
		_pitch = clampf(_pitch + tilt * KEY_LOOK_RATE * delta, -PI * 0.49, PI * 0.49)
	fwd_in += ui_move.y
	str_in += ui_move.x

	if noclip:
		_fly(delta, fwd_in, str_in)
	elif vehicle == VEH_JEEP:
		_drive(delta, fwd_in, str_in)
	elif vehicle == VEH_HK:
		_hover(delta, fwd_in, str_in)
	else:
		_walk(delta, fwd_in, str_in)

## Jeep (DOS mode 4): a car, not a hovercraft — the mouse and A/D turn
## a steering WHEEL, the heading only changes while the wheels roll
## (faster at speed, self-centring), the cab pitches and rolls with the
## ground under it, bumps shake the view at speed, hard turns skid.
var _wheel: float = 0.0               # -1..1 steering wheel
var _tilt_pitch: float = 0.0
var _tilt_roll: float = 0.0
var _bump_t: float = 0.0
var _skid_cd: float = 0.0
const JEEP_WHEEL_RETURN: float = 2.5   # wheel self-centre rate (per s)
const JEEP_TILT_RATE: float = 6.0

## Jeep turret aim (DOS: the keys drive, the mouse moves an independent
## crosshair the guns follow). Relative to the car's heading.
var _aim_yaw: float = 0.0
var _aim_pitch: float = 0.0
const JEEP_AIM_YAW: float = 1.1
const JEEP_AIM_PITCH_DOWN: float = -0.45
const JEEP_AIM_PITCH_UP: float = 0.6
## Ramming (DOS: the jeep bounces off robots, both take damage).
const RAM_MIN_SPEED: float = 250.0
const RAM_RADIUS: float = 120.0
const RAM_DAMAGE_PER_SPEED: float = 0.045
const RAM_SELF_PER_SPEED: float = 0.012
var _ram_cd: Dictionary = {}       # enemy instance id -> cooldown
var _dust: GPUParticles3D = null   # ENHANCED wheel dust

## Direction the guns fire: the turret aim in the jeep, the view else.
func aim_dir() -> Vector3:
	if vehicle == VEH_JEEP:
		return -(Basis(Vector3.UP, _yaw + _aim_yaw) * Basis(Vector3.RIGHT, _aim_pitch)).z
	return -_cam.global_transform.basis.z

## Where the crosshair belongs on screen (the turret aim in the jeep).
func aim_screen_pos() -> Vector2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if vehicle != VEH_JEEP or _cam == null:
		return vp * 0.5
	var pt: Vector3 = _cam.global_position + aim_dir() * 4000.0
	if _cam.is_position_behind(pt):
		return vp * 0.5
	return _cam.unproject_position(pt)

## Drive into a robot: it takes the hit, the car bounces, the driver
## feels it too (FUN_00125caf-era DOS behaviour recalled by the player).
func _ram_check(fwd: Vector3) -> void:
	for k in _ram_cd.keys():
		_ram_cd[k] -= get_physics_process_delta_time()
		if _ram_cd[k] <= 0.0:
			_ram_cd.erase(k)
	if absf(_veh_speed) < RAM_MIN_SPEED:
		return
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var sh := SphereShape3D.new()
	sh.radius = RAM_RADIUS
	q.shape = sh
	q.transform = Transform3D(Basis(), global_position + fwd * (90.0 * signf(_veh_speed)) + Vector3(0.0, 50.0, 0.0))
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = [get_rid()]
	for hit in space.intersect_shape(q, 8):
		var n: Node = hit.get("collider") as Node
		while n != null and not (n.is_in_group("enemy") and n.has_method("take_damage")):
			n = n.get_parent()
		if n == null:
			continue
		var id: int = n.get_instance_id()
		if _ram_cd.has(id):
			continue
		_ram_cd[id] = 0.6
		var sp: float = absf(_veh_speed)
		n.call("take_damage", sp * RAM_DAMAGE_PER_SPEED)
		take_damage(sp * RAM_SELF_PER_SPEED)
		_veh_speed = -_veh_speed * 0.35
		Audio.play_id(30, -3.0)
		return

func _drive(delta: float, fwd_in: float, str_in: float) -> void:
	# Keys hold the wheel; without input it returns to centre (the mouse
	# nudges it in _unhandled_input).
	if absf(str_in) > 0.1:
		_wheel = clampf(_wheel + str_in * 3.0 * delta, -1.0, 1.0)
	else:
		_wheel = move_toward(_wheel, 0.0, JEEP_WHEEL_RETURN * delta)
	# Heading follows the wheel only while rolling.
	var roll_k: float = clampf(absf(_veh_speed) / 500.0, 0.0, 1.0)
	var dir: float = 1.0 if _veh_speed >= 0.0 else -1.0
	var yaw_rate: float = _wheel * JEEP_TURN_RATE * roll_k * dir
	_yaw -= yaw_rate * delta
	rotation.y = _yaw
	# A hard turn at speed scrubs speed off and squeals.
	if absf(yaw_rate) > 1.0 and absf(_veh_speed) > 900.0:
		_veh_speed *= 1.0 - 0.6 * delta
		_skid_cd -= delta
		if _skid_cd <= 0.0:
			_skid_cd = 0.9
			Audio.play_id(29, -8.0)
	else:
		_skid_cd = 0.0
	if fwd_in > 0.1:
		if _veh_speed < 0.0:
			_veh_speed = minf(_veh_speed + JEEP_BRAKE * delta, 0.0)
		else:
			_veh_speed = minf(_veh_speed + JEEP_ACCEL * delta, JEEP_MAX_SPEED * speed_boost)
	elif fwd_in < -0.1:
		if _veh_speed > 0.0:
			_veh_speed = maxf(_veh_speed - JEEP_BRAKE * delta, 0.0)
		else:
			_veh_speed = maxf(_veh_speed - JEEP_ACCEL * 0.6 * delta, -JEEP_REVERSE_SPEED)
	else:
		_veh_speed = move_toward(_veh_speed, 0.0, JEEP_DRAG * delta)
	var fwd := -Basis(Vector3.UP, _yaw).z
	velocity.x = fwd.x * _veh_speed
	velocity.z = fwd.z * _veh_speed
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	var before := global_position
	move_and_slide()
	_ram_check(fwd)
	if _dust == null and FxParticles.on():
		_dust = FxParticles.wheel_dust(self)
	if _dust != null:
		_dust.amount_ratio = clampf(absf(_veh_speed) / JEEP_MAX_SPEED, 0.0, 1.0) if is_on_floor() else 0.0
	# A wall stops the jeep dead (and the momentum with it) — carcoll2.
	if absf(_veh_speed) > 50.0 and global_position.distance_to(before) < absf(_veh_speed) * delta * 0.2:
		if absf(_veh_speed) > 500.0:
			Audio.play_id(30, -4.0)
		_veh_speed *= 0.3
	# Cab tilt with the ground: pitch along the heading, roll across it.
	var want_pitch: float = 0.0
	var want_roll: float = 0.0
	if is_on_floor():
		var n: Vector3 = get_floor_normal()
		var right: Vector3 = Basis(Vector3.UP, _yaw).x
		want_pitch = asin(clampf(n.dot(-fwd), -1.0, 1.0)) * 0.85
		want_roll = asin(clampf(n.dot(right), -1.0, 1.0)) * 0.7
	var tk: float = clampf(delta * JEEP_TILT_RATE, 0.0, 1.0)
	_tilt_pitch = lerpf(_tilt_pitch, want_pitch, tk)
	_tilt_roll = lerpf(_tilt_roll, want_roll, tk)
	# Bumps: the faster, the shakier.
	var sk: float = clampf(absf(_veh_speed) / JEEP_MAX_SPEED, 0.0, 1.0)
	_bump_t += delta * (6.0 + 14.0 * sk)
	if _cam != null:
		_cam.rotation.x = _pitch + _tilt_pitch + sin(_bump_t) * 0.004 * sk
		_cam.rotation.z = _tilt_roll + cos(_bump_t * 0.7) * 0.006 * sk
		_cam.position.y = float(VEH_EYE[VEH_JEEP]) + sin(_bump_t * 1.3) * 3.0 * sk
	_update_engine()

## HK (DOS mode 8): a hovering gunship — thrust along the view with W/S,
## strafe with A/D, climb / dive with E-Space / Q, no gravity, never
## below HK_MIN_ALTITUDE over whatever is under the hull.
func _hover(delta: float, fwd_in: float, str_in: float) -> void:
	var look := global_transform.basis
	if _cam != null:
		look = _cam.global_transform.basis
	var vert: float = ui_vert
	if Controls.is_pressed("up"):
		vert += 1.0
	if Controls.is_pressed("down"):
		vert -= 1.0
	var want: Vector3 = -look.z * fwd_in * HK_SPEED * speed_boost \
		+ look.x * str_in * HK_STRAFE + Vector3.UP * vert * HK_CLIMB
	if Controls.is_pressed("sprint"):
		want *= 1.4
	velocity = velocity.move_toward(want, HK_ACCEL * delta)
	# Ground clearance: push up when the surface below comes too close.
	var space := get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0.0, 20.0, 0.0),
			global_position - Vector3(0.0, HK_MIN_ALTITUDE + 40.0, 0.0))
		q.collide_with_areas = false
		q.exclude = [get_rid()]
		var hit := space.intersect_ray(q)
		if hit.has("position"):
			var clearance: float = global_position.y - (hit["position"] as Vector3).y
			if clearance < HK_MIN_ALTITUDE and velocity.y < HK_CLIMB * 0.5:
				velocity.y = maxf(velocity.y, (HK_MIN_ALTITUDE - clearance) * 4.0)
	move_and_slide()
	_update_engine()

## Grounded movement: walk on surfaces, gravity, jump, wall collision.
## --- Water (DOS 0x120c83 water level, 0x12e56b breath) ---------------
## `water_level` is the surface Y the level controller found on the map's
## marker 103/104; INF when the map is dry. Below it the player SWIMS:
## the fall turns into a slow sink, the up/down keys and the view drive
## him through the water, and while his head is under, his breath runs
## down. DOS gives about 24 s of air (0x347 ticks) and then takes 85 HP a
## second (accumulator step 0x5500 >> 8) until he surfaces or drowns.
var water_level: float = INF
const SWIM_SPEED_SCALE: float = 0.62   # slower than walking
const SWIM_VERTICAL: float = 260.0     # up/down paddle speed
const SWIM_RISE: float = 170.0         # buoyancy back toward the surface
const FLOAT_EYE: float = 10.0          # eyes ride this far above the water
const SWIM_FLOAT_BACK: float = 380.0   # push back under the surface
const SWIM_DRAG: float = 7.0
const SWIM_ENTRY_DAMP: float = 0.3     # a fall is broken by the water
const HEAD_ROOM: float = 5.0           # DOS "-5" head-under margin
const AIR_SECONDS: float = 24.0        # DOS 0x347 ticks at 35 Hz
const DROWN_DPS: float = 85.0          # DOS 0x5500 >> 8 per second
const SND_SPLASH: int = 115
const SND_DROWN: int = 116
const SND_BUBBLES: int = 118
const SND_GETAIR: int = 122
var air: float = AIR_SECONDS
var in_water: bool = false
var head_under: bool = false
var _bubble_t: float = 0.0

## The camera's world position — the eye, which is what decides whether
## the player's head is under water.
func eye_position() -> Vector3:
	return _cam.global_position if _cam != null else global_position

## Feet below the surface — the swimming test.
func _water_check() -> void:
	var was_in: bool = in_water
	var was_under: bool = head_under
	in_water = global_position.y < water_level
	head_under = eye_position().y < water_level - HEAD_ROOM
	if in_water != was_in:
		Audio.play_id(SND_SPLASH, -4.0)
		if in_water:
			velocity *= SWIM_ENTRY_DAMP     # the water breaks the fall
	if was_under and not head_under:
		Audio.play_id(SND_GETAIR, -5.0)
		air = AIR_SECONDS
	if not head_under:
		air = AIR_SECONDS

## Breath and drowning, run every frame the player is alive.
func _breathe(delta: float) -> void:
	if not head_under:
		return
	air -= delta
	_bubble_t -= delta
	if _bubble_t <= 0.0:
		_bubble_t = randf_range(1.4, 3.2)
		Audio.play_id(SND_BUBBLES, -12.0)
	if air > 0.0:
		return
	take_damage(DROWN_DPS * delta, false)
	if _bubble_t < 1.0:
		Audio.play_id(SND_DROWN, -3.0)

## Swimming: no ground contact, no jump — buoyancy plus paddling. The
## view aims the stroke, so looking down and holding forward dives.
func _swim(delta: float, fwd_in: float, str_in: float) -> void:
	var basis_y := Basis(Vector3.UP, _yaw)
	var horiz := -basis_y.z * fwd_in + basis_y.x * str_in
	if horiz.length() > 1.0:
		horiz = horiz.normalized()
	var speed: float = walk_speed * speed_boost * class_speed * SWIM_SPEED_SCALE
	var want := Vector3(horiz.x * speed, 0.0, horiz.z * speed)
	# Swimming forward while looking up or down carries you that way.
	if fwd_in > 0.0 and _cam != null:
		want.y += -_cam.global_transform.basis.z.y * speed * absf(fwd_in)
	var vert: float = 0.0
	if Controls.is_pressed("up") or ui_vert > 0.0:
		vert += 1.0
	if Controls.is_pressed("down") or ui_vert < 0.0:
		vert -= 1.0
	var eye_y: float = eye_position().y
	if vert != 0.0:
		# JUMP swims up, CROUCH dives — holding CROUCH is how you get
		# down to a hatch and stay there while your air lasts.
		want.y += vert * SWIM_VERTICAL
	else:
		# Buoyancy: let go and you rise until your eyes clear the
		# surface, then bob there. DOS plays getair2 the moment the head
		# comes out, so the swimmer is meant to float, not to sink.
		want.y += clampf((water_level + FLOAT_EYE - eye_y) * 3.0,
			-SWIM_FLOAT_BACK, SWIM_RISE)
	velocity = velocity.lerp(want, clampf(SWIM_DRAG * delta, 0.0, 1.0))
	move_and_slide()

func _walk(delta: float, fwd_in: float, str_in: float) -> void:
	if in_water:
		_swim(delta, fwd_in, str_in)
		return
	var basis_y := Basis(Vector3.UP, _yaw)
	var horiz := -basis_y.z * fwd_in + basis_y.x * str_in
	if horiz.length() > 1.0:
		horiz = horiz.normalized()
	var speed := walk_speed * speed_boost * class_speed
	if Controls.is_pressed("sprint"):
		speed *= sprint_multiplier
	velocity.x = horiz.x * speed
	velocity.z = horiz.z * speed

	if is_on_floor():
		var jump: bool = Controls.is_pressed("up") or ui_vert > 0.0
		velocity.y = jump_speed if jump else 0.0
	else:
		velocity.y -= gravity * delta
	var before := global_position
	var on_floor_before: bool = is_on_floor()
	move_and_slide()
	if on_floor_before and horiz.length() > 0.1 and is_on_wall():
		_step_up(horiz, speed * delta)
	_track_stuck(delta, horiz.length() > 0.1, global_position.distance_to(before))

## Stair step: when a wall stops grounded movement, try the same motion
## from up to STEP_HEIGHT higher and settle back down onto a walkable
## floor. Only steps UP to STEP_HEIGHT are taken; nothing happens when
## the raised probe is blocked too (a real wall) or finds no floor.
func _step_up(horiz: Vector3, advance: float) -> void:
	var fwd: Vector3 = horiz.normalized() * maxf(advance, STEP_PROBE)
	var start: Transform3D = global_transform
	# 1. Rise as far as STEP_HEIGHT allows.
	var up := Vector3(0.0, STEP_HEIGHT, 0.0)
	var kc: KinematicCollision3D = move_and_collide(up, true)
	var rise: Vector3 = up if kc == null else kc.get_travel()
	if rise.y < 4.0:
		return
	var t := start.translated(rise)
	# 2. Advance from up there; a blocked probe means a wall, not a step.
	kc = _probe(t, fwd)
	var adv: Vector3 = fwd if kc == null else kc.get_travel()
	if adv.length() < STEP_PROBE * 0.5:
		return
	t = t.translated(adv)
	# 3. Drop back onto the floor; it must be a walkable slope above the
	#    starting height (a step), not the ground we started from.
	kc = _probe(t, Vector3(0.0, -rise.y - 2.0, 0.0))
	if kc == null:
		return
	if kc.get_normal().y < cos(floor_max_angle):
		return
	var landing: Vector3 = t.origin + kc.get_travel()
	if landing.y - start.origin.y < 2.0:
		return
	global_position = landing
	velocity.y = 0.0

## test-only motion from an explicit transform (move_and_collide uses
## the body's own transform).
func _probe(from: Transform3D, motion: Vector3) -> KinematicCollision3D:
	var saved: Transform3D = global_transform
	global_transform = from
	var kc: KinematicCollision3D = move_and_collide(motion, true)
	global_transform = saved
	return kc

## Trimesh collision on detailed props can wedge the capsule (a step
## under an overhang, a gate leaf, two meshes overlapping) — DOS never
## did because it collided against object cylinders. When movement
## input produces no motion: step up over the lip, push out along the
## contact normals, and as a last resort return to the last free spot.
func _track_stuck(delta: float, wants_move: bool, moved: float) -> void:
	if wants_move and moved < 0.5:
		_stuck_t += delta
	else:
		_stuck_t = 0.0
		if moved > 2.0 and is_on_floor():
			_good_t += delta
			if _good_t > 0.5:
				_good_t = 0.0
				_last_good = global_position
	if _stuck_t < STUCK_TIME:
		return
	var up := Vector3(0.0, 48.0, 0.0)
	if not test_move(global_transform, up):
		global_position += up
		return
	var n := Vector3.ZERO
	for i in get_slide_collision_count():
		n += get_slide_collision(i).get_normal()
	if n.length() > 0.01:
		var push := n.normalized() * 30.0
		if not test_move(global_transform, push):
			global_position += push
			return
	if _stuck_t > STUCK_RESET_TIME and _last_good != Vector3.ZERO:
		print("[player] wedged — returning to the last free position")
		global_position = _last_good + Vector3(0.0, 10.0, 0.0)
		velocity = Vector3.ZERO
		_stuck_t = 0.0

## Debug noclip: free 6-DOF flight along the camera look direction.
func _fly(_delta: float, fwd_in: float, str_in: float) -> void:
	var look := global_transform.basis
	if _cam != null:
		look = _cam.global_transform.basis
	var vert: float = ui_vert
	if Controls.is_pressed("up"):
		vert += 1.0
	if Controls.is_pressed("down"):
		vert -= 1.0
	var dir := -look.z * fwd_in + look.x * str_in + Vector3.UP * vert
	var speed := fly_speed
	if Controls.is_pressed("sprint"):
		speed *= sprint_multiplier
	velocity = Vector3.ZERO
	if dir.length_squared() > 0.0:
		global_position += dir.normalized() * speed * _delta

## Tracer + muzzle-flash colour per weapon family. Picked once at fire
## time so a single dictionary in the weapons table doesn't have to
## carry duplicated Color fields. "melee" has no entry — pipe never
## spawns a flash or tracer.
const _KIND_COLOR: Dictionary = {
	"bullet":  Color(1.0, 0.92, 0.55),     # warm white-yellow
	"shotgun": Color(1.0, 0.88, 0.45),
	"laser":   Color(1.0, 0.32, 0.22),     # hot red
	"plasma":  Color(0.45, 0.7, 1.0),      # cool blue
}

const MELEE_RANGE: float = 180.0           # close-quarters pipe reach

## Fire the current weapon. Dispatches on `kind`:
##   bullet/shotgun        → hitscan ray + tracer + muzzle flash, and the
##                           bullet impact puff (TEXTURE.365) where the
##                           shot strikes geometry. Shotgun adds muzzle
##                           smoke.
##   laser/plasma/rocket   → visible Projectile flying the ammo type's
##                           .3D model (laser1 / laser2 / rocket).
##   grenade               → ballistic Grenade (TEXTURE.217 sprite).
##   melee                 → short-range swing.
##
## DOS (FUN_00125caf, skynet_gh.c:28221-28273): once the countdown hits
## zero and the pool holds a shot's cost, spawn the projectile
## (FUN_00122a64), reset the countdown to 0x10000/rate and play the fire
## sound; with too little ammo play the dry-fire sound (+0x58) instead.
## Fire weapon slot `idx` (the held gun by default). The secondary — the
## jeep's and the HK's rocket pod — goes through the same path, so it
## pays its pool, plays its sound and spawns its projectile like any
## other shot; only the viewmodel stays on the primary.
func _shoot(idx: int = -1) -> void:
	if _fire_cd > 0.0 or health <= 0.0 or _cam == null:
		return
	if idx < 0:
		idx = _weapon_idx
	var w: Dictionary = _weapons[idx]
	var kind: String = String(w.get("kind", "bullet"))
	var pool: int = int(w.get("pool", -1))
	var cost: int = int(w.get("cost", 0))
	if pool == VEH_ENERGY_POOL:
		if int(_pools.get(pool, 0)) < cost:
			_veh_overheated = true               # cold start needs VEH_COOL_LEVEL
		if _veh_overheated:
			_fire_cd = DRY_FIRE_DELAY
			Audio.play_id(int(w.get("dry", -1)), -6.0)
			return
	elif pool >= 0 and int(_pools.get(pool, 0)) < cost:
		_fire_cd = DRY_FIRE_DELAY
		Audio.play_id(int(w.get("dry", -1)), -6.0)
		return
	_fire_cd = maxf(FIRE_RATE_SCALE / float(w.get("rate", 4)), 0.05)
	if pool >= 0:
		_pools[pool] = int(_pools[pool]) - cost
		# Through _sync_hud, so the HUD keeps showing the HELD weapon's
		# ammo even when the shot came from the secondary slot.
		_sync_hud()
		if pool == VEH_ENERGY_POOL:
			_veh_since_shot = 0.0
	if not Net.active:
		Stats.shot()                        # STATISTICS: shots fired
	var snd: String = String(w.get("snd", ""))
	if not snd.is_empty():
		Audio.play_sfx(snd, -5.0)
	elif int(w.get("snd_id", -1)) >= 0:
		Audio.play_id(int(w["snd_id"]), -5.0)
	# Kick off the viewmodel fire animation (the held gun only).
	if idx == _weapon_idx:
		_vm_firing = true
		_vm_idx = 0
		_vm_t = 0.0

	var fwd: Vector3 = aim_dir()
	var muzzle: Vector3 = _cam.global_position + fwd * 90.0 \
		- _cam.global_transform.basis.y * 26.0
	if vehicle != VEH_FOOT:
		# Vehicle guns sit low on the hull, well ahead of the cockpit.
		muzzle = _cam.global_position + fwd * (160.0 if vehicle == VEH_JEEP else 260.0) \
			- _cam.global_transform.basis.y * 40.0
	var dmg: float = float(w["dmg"])
	# Deathmatch: everybody else draws this shot.
	if Net.active:
		Net.send_fire(idx, muzzle, fwd)
	# The DOS moon joke (FUN_00125caf): any weapon fired with the
	# crosshair on the moon makes it complain.
	if kind != "melee":
		var sc: Node = get_tree().current_scene
		if sc != null and sc.has_method("moon_aimed") and sc.call("moon_aimed", fwd):
			sc.call("moon_shot")

	# Melee: short-range hitscan, no tracer, no muzzle flash. The
	# viewmodel swing animation (CFA frames) is the only visible cue.
	if kind == "melee":
		_melee_hit(muzzle, fwd, dmg)
		return

	var tint: Color = _KIND_COLOR.get(kind, Color.WHITE)

	# Muzzle flash for every projectile shot (DOS spawns one via
	# FUN_00126080, skynet_gh.c:28238). The TEXTURE.219 sprite is tinted
	# to family colour so plasma flares blue, lasers red, bullets warm
	# white.
	var mf := MuzzleFlash.new()
	get_tree().current_scene.add_child(mf)
	# TEXTURE.219 is a 17x17 px sprite. DOS draws it as a small flare at
	# the gun's muzzle; from 90 u a 36 u sprite filled a third of the
	# screen, so it sits further out and smaller (a 2026-09-02 report).
	mf.setup(muzzle + fwd * 70.0, tint, 26.0 if kind == "shotgun" else 18.0)
	# ENHANCED: what a shot leaves behind — a spent case out of the port
	# for the slugthrowers, a wisp of smoke at the muzzle. The energy
	# weapons get nothing: their muzzle flash already is the effect, and
	# the coloured flare on top of it was part of what made the guns look
	# like they were belching fire (2026-09-04).
	if Render.enhanced():
		var scene: Node = get_tree().current_scene
		var right: Vector3 = global_transform.basis.x
		if _cam != null:
			right = _cam.global_transform.basis.x
		var muzzle_at: Vector3 = muzzle + fwd * 70.0
		match kind:
			"bullet":
				FxParticles.casings(scene, muzzle + right * 14.0, right, fwd, 1)
				FxParticles.muzzle_smoke(scene, muzzle_at, fwd, 16.0)
			"shotgun":
				FxParticles.casings(scene, muzzle + right * 14.0, right, fwd, 1)
				FxParticles.muzzle_smoke(scene, muzzle_at, fwd, 26.0)
			"rocket", "grenade":
				FxParticles.muzzle_smoke(scene, muzzle_at, fwd, 34.0)

	# Ballistic / straight projectiles take a separate path.
	if kind == "grenade":
		var g := Grenade.new()
		get_tree().current_scene.add_child(g)
		g.setup(muzzle, fwd, dmg, float(w.get("splash", 256.0)), self)
		return
	if kind == "rocket" or kind == "laser" or kind == "plasma":
		var proj: Node3D = Projectile.new()
		get_tree().current_scene.add_child(proj)
		proj.setup(muzzle, fwd, dmg, _projectile_cfg(kind, w), self)
		return

	# Hitscan ray for bullet / shotgun.
	var from: Vector3 = _cam.global_position
	var to: Vector3 = from + fwd * 60000.0
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = true                # enemy hitboxes are Area3D
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	var endpoint: Vector3 = to
	if hit.has("position"):
		endpoint = hit["position"]
	# A short tracer well down-range. The player's own shots used to draw
	# nothing at all: a beam starting at the muzzle filled the view with a
	# tan wedge (2026-09-02), so it was dropped — and then firing gave no
	# feedback whatsoever (2026-09-04). Starting it TRACER_START units out
	# keeps it out of the player's face and still shows where the burst
	# went.
	if kind == "bullet" or kind == "shotgun":
		var beam_from: Vector3 = muzzle + fwd * TRACER_START
		if beam_from.distance_to(endpoint) > 60.0:
			var tr: MeshInstance3D = Tracer.new()
			get_tree().current_scene.add_child(tr)
			tr.setup(beam_from, endpoint, Color(1.0, 0.85, 0.5), 6.0)
	# Shotgun: a puff of smoke lingering at the muzzle (DOS mode only —
	# ENHANCED already got its particle wisp above).
	if kind == "shotgun" and not FxParticles.on():
		var sm := SmokePuff.new()
		get_tree().current_scene.add_child(sm)
		sm.setup(muzzle + fwd * 30.0, 180.0)
	if hit.has("collider"):
		var n: Node = hit["collider"] as Node
		while n != null and not n.has_method("take_damage"):
			n = n.get_parent()
		if n != null and n != self:
			_deal(n, dmg)
		elif FxParticles.on():
			FxParticles.impact(get_tree().current_scene, endpoint, hit.get("normal", Vector3.UP))
		else:
			var puff := Explosion.new()
			get_tree().current_scene.add_child(puff)
			puff.setup(endpoint, 40.0, IMPACT_BANK_BULLET)

## Damage `n` from this player's shot — deathmatch actors take the
## attributed form (their `net_damage` reports the hit to the server).
func _deal(n: Node, dmg: float) -> void:
	if n.has_method("net_damage"):
		n.net_damage(dmg, self)
	else:
		n.take_damage(dmg)

## Look and payload of the straight-flying projectile families, from the
## DOS ammo records: the .3D model at +0x04, the impact effect bank at
## +0x08 (sprite index 0xB580 → TEXTURE.363 for rockets, 0xB600 → 364
## for laser/plasma bolts), the impact sound at +0x20 (rocket: explo3;
## lasers none) and the lifetime at +0x18 (~35 Hz ticks: 120 → 3.4 s,
## 40 → 1.1 s). Flight speed is not stored in the table.
func _projectile_cfg(kind: String, w: Dictionary) -> Dictionary:
	match kind:
		"rocket":
			return {"model": "ROCKET.3D", "color": Color(1.0, 0.75, 0.4),
				"speed": 3000.0, "life": 3.4,
				"splash": float(w.get("splash", 512.0)),
				"trail": true, "light": true, "impact_bank": 363,
				"impact_sound": "EXPLO3.RAW", "hits": "enemy"}
		"laser":
			return {"model": "LASER1.3D", "color": Color(1.0, 0.32, 0.22),
				"speed": 9000.0, "life": 1.2, "splash": 0.0, "light": true,
				"impact_bank": 364, "hits": "enemy"}
		"plasma":
			return {"model": "LASER2.3D", "color": Color(0.45, 0.7, 1.0),
				"speed": 4000.0, "life": 1.2, "splash": 0.0, "light": true,
				"impact_bank": 364, "hits": "enemy"}
	return {"speed": 4000.0, "hits": "enemy"}

## The THROW key (and the right mouse button): use the SECONDARY weapon.
## In a vehicle that is the rocket pod — it fires like any other gun. On
## foot it lobs the selected thrown item in an upward arc, out of its own
## pool, without disturbing the gun in the player's hands.
func _throw_secondary() -> void:
	if health <= 0.0 or _cam == null or _fire_cd > 0.0:
		return
	if vehicle != VEH_FOOT:
		_shoot(int(VEHICLE_WEAPONS[vehicle][1]))
		return
	var t: Dictionary = THROWABLES[_throw_idx]
	var pool: int = int(t["pool"])
	if int(_pools.get(pool, 0)) <= 0:
		# Out of this one: move to the next item that still has stock, so
		# the key always does something (DOS just played the dry click).
		if not cycle_throwable(1):
			_fire_cd = DRY_FIRE_DELAY
			Audio.play_id(10, -6.0)
			return
		t = THROWABLES[_throw_idx]
		pool = int(t["pool"])
	_pools[pool] = int(_pools[pool]) - 1
	_sync_hud()
	_fire_cd = 0.6
	var fwd: Vector3 = -_cam.global_transform.basis.z
	var muzzle: Vector3 = _cam.global_position + fwd * 60.0
	var arc: Vector3 = (fwd + Vector3.UP * 0.35).normalized()
	if Net.active:
		Net.send_fire(5, muzzle, arc)            # drawn as a launcher shot
	var g := Grenade.new()
	get_tree().current_scene.add_child(g)
	g.setup(muzzle, arc, float(t["dmg"]), float(t["splash"]), self,
		float(t.get("speed", HAND_GRENADE_SPEED)), t)

## Step to the next thrown item that still has rounds. Returns false when
## the player is carrying none at all. Bound to `0` and the middle mouse
## button; the pause menu and the console call it too.
func cycle_throwable(dir: int) -> bool:
	var n: int = THROWABLES.size()
	for k in n:
		var i: int = (_throw_idx + dir * (k + 1) + n * (k + 1)) % n
		if int(_pools.get(int(THROWABLES[i]["pool"]), 0)) > 0:
			_throw_idx = i
			_sync_hud()
			Audio.play_id(9, -8.0)
			secondary_changed.emit(secondary_name, secondary_ammo)
			return true
	return false

## Short-range melee swing (the pipe). One ray cast forward from the
## camera up to MELEE_RANGE; if it lands on a damageable node we apply
## `dmg` and play the impact sound. No tracer, no muzzle flash — the
## viewmodel swing animation is the only on-screen feedback.
func _melee_hit(from: Vector3, fwd: Vector3, dmg: float) -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var q := PhysicsRayQueryParameters3D.create(from,
		from + fwd * MELEE_RANGE)
	q.collide_with_areas = true
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.has("collider"):
		return
	var n: Node = hit["collider"] as Node
	while n != null and not n.has_method("take_damage"):
		n = n.get_parent()
	if n != null and n != self:
		Audio.play_sfx_3d("HIT2.RAW", hit["position"], -3.0)
		_deal(n, dmg)

## Activate action (Controls "activate", default F): operate the door or
## switch the player is looking at within reach. Ray-walks parents for an
## `activate()` method. Hits Area3D so wall-mounted switches register
## (their hitbox is an Area3D, like enemies); the parent-walk filter
## ignores anything without `activate()` so enemy hitboxes are inert.
## Emitted when the use key finds nothing to operate — the level
## controller then checks for an armed map exit around the player.
signal secondary_changed(name: String, count: int)
## A hit landed on the player (after armour) — the HUD flashes for it.
signal hurt(amount: float)
signal use_pressed(pos: Vector3)

func _try_activate() -> void:
	if _cam == null:
		return
	var from := _cam.global_position
	var to := from - _cam.global_transform.basis.z * 600.0
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = true
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.has("collider"):
		use_pressed.emit(global_position)
		return
	var n: Node = hit["collider"] as Node
	while n != null and not n.has_method("activate"):
		n = n.get_parent()
	if n != null:
		n.activate()
		return
	use_pressed.emit(global_position)

## Take damage from an enemy shot. On death the player just dies — the
## level controller shows a game-over screen and calls respawn().
## `scaled` applies the DIFFICULTY multiplier (Settings.dmg_to_player).
## DOS scales weapon damage in the projectile-impact path only, so
## radiation and other environmental damage pass false.
func take_damage(amount: float, scaled: bool = true) -> void:
	if health <= 0.0:
		return
	if god_mode:
		return                                   # debug invincibility
	if scaled:
		amount *= Settings.dmg_to_player()
	if Net.active:
		# Deathmatch: the server owns our health — this is our own splash
		# (rocket at the feet); other people's shots reach us as reports
		# from THEIR machines, never through here.
		Net.hit(Net.local_id, amount, Net.local_id, _weapon_idx)
		return
	if vehicle != VEH_FOOT:
		amount *= 0.6                            # the hull takes part of it
	if armor > 0.0:
		var soak: float = minf(amount * 0.5, armor * max_health)
		armor = maxf(armor - soak / max_health, 0.0)
		amount -= soak
	health -= amount
	hurt.emit(amount)
	Audio.play_sfx("HIT2.RAW", -3.0)
	if health <= 0.0:
		health = 0.0
		Audio.play_sfx("EXPLO2.RAW", -2.0)
		_capture(false)                          # release the mouse

## A deathmatch hit from `attacker` (a server-side bot shooting the
## host, or a splash from another actor's projectile on this machine).
func net_damage(amount: float, attacker: Node) -> void:
	if health <= 0.0 or god_mode:
		return
	if not Net.active:
		take_damage(amount)
		return
	var weapon: int = -1
	if attacker != null and "weapon_idx" in attacker:
		weapon = int(attacker.get("weapon_idx"))
	Net.hit(Net.local_id, amount, Net.id_of(attacker), weapon)

## Respawn at the stored level start (set_spawn resets health and ammo).
func respawn() -> void:
	set_spawn(_spawn_pos, _spawn_yaw)

## Pickup: top up the shared ammo pools (PICKUP_AMMO rounds each, capped
## at the pool maximum). Returns true when at least one pool could take
## more, so the pickup is consumed.
func add_ammo(_rounds: int) -> bool:
	var took := false
	for p in PICKUP_AMMO:
		var mx: int = int(POOL_TABLE[p][1])
		var cur: int = int(_pools.get(p, 0))
		if cur < mx:
			_pools[p] = mini(cur + int(PICKUP_AMMO[p]), mx)
			took = true
	if took:
		_sync_hud()
	return took

## Pickup: heal the player. Returns false when already at full health so
## the pickup is left for later.
func add_health(amount: int) -> bool:
	if health >= max_health:
		return false
	health = minf(health + float(amount), max_health)
	return true

## --- DOS pickup effects (handler 0x11d670, item table 0x35800) --------

## Emitted with the STRINGS.PRS "PICKED UP ..." line for the HUD.
signal pickup_message(text: String)

## Armor 0..1 (DOS 16.16 at 0x38cc8, capped at 1.0): soaks half of each
## hit until it is used up.
var armor: float = 0.0

## Top up one ammo pool by `amount`, clamped to the pool maximum. Pools
## 5-9 (thrown items) have no weapon slot yet but are tracked anyway.
func add_pool(pool: int, amount: int) -> void:
	if pool < 0 or amount <= 0:
		return
	var mx: int = int(POOL_TABLE[pool][1]) if POOL_TABLE.has(pool) else 99
	_pools[pool] = mini(int(_pools.get(pool, 0)) + amount, mx)
	_sync_hud()

## Heal by a percentage of max health (medkits: 5 / 10 / 25 / 50 %).
func heal_percent(pct: int) -> void:
	health = minf(health + max_health * float(pct) / 100.0, max_health)

func add_armor(frac: float) -> void:
	armor = clampf(armor + frac, 0.0, 1.0)

## A weapon pickup sets the owned bit and selects that weapon
## (0x11d670 → 0x1254c6).
func give_weapon(idx: int) -> void:
	if idx >= 0 and idx < _weapons.size():
		_owned[idx] = true
		_select_weapon(idx)

## --- DOS cheat effects (CHEAT.PRS codes, handlers at 0x141f08..) ------

## "arnold": the 0x4350c list — every on-foot weapon but the super uzi.
func give_all_weapons() -> void:
	for w in ALL_WEAPONS:
		_owned[int(w)] = true
	_sync_hud()

## "superuzi": record 12 owned + selected.
func give_super_uzi() -> void:
	give_weapon(SUPER_UZI)

## "slugs": every pool to its maximum.
func fill_ammo() -> void:
	for p in POOL_TABLE:
		_pools[p] = int(POOL_TABLE[p][1])
	_sync_hud()

## "surgery": full health, full armor (0x38cc8 = 0x10000, 0x38cc4 = 0).
func full_health() -> void:
	health = max_health
	armor = 1.0

## "nitrous": DOS adds 0x8000 (0.5 in 16.16) to the walk speed each time.
var speed_boost: float = 1.0
func nitrous() -> float:
	speed_boost += 0.5
	return speed_boost

## Let go of the mouse (menus, console).
func release_mouse() -> void:
	_capture(false)

## Rounds in pool `pool` (tests / HUD).
func pool_count(pool: int) -> int:
	return int(_pools.get(pool, 0))

## --- save / load (main.save_to_slot / load_from_slot) -------------------

## Everything about the player a save file keeps.
func save_state() -> Dictionary:
	return {
		"pos": global_position, "yaw": _yaw, "pitch": _pitch,
		"health": health, "armor": armor,
		"pools": _pools.duplicate(), "weapon": _weapon_idx,
		"owned": owned_list(), "speed_boost": speed_boost,
		"vehicle": vehicle, "foot_owned": _foot_owned.keys(), "foot_weapon": _foot_weapon,
	}

## Restore a save_state() snapshot — called once the level is up.
func restore_state(d: Dictionary) -> void:
	set_vehicle(int(d.get("vehicle", 0)))
	var fo = d.get("foot_owned")
	if fo is Array and not (fo as Array).is_empty():
		_foot_owned.clear()
		for w in fo:
			_foot_owned[int(w)] = true
		_foot_weapon = int(d.get("foot_weapon", 1))
	set_spawn(d.get("pos", global_position), float(d.get("yaw", _yaw)), false)
	set_view(float(d.get("yaw", _yaw)), float(d.get("pitch", 0.0)))
	health = clampf(float(d.get("health", max_health)), 0.0, max_health)
	armor = clampf(float(d.get("armor", 0.0)), 0.0, 1.0)
	var pools = d.get("pools")
	if pools is Dictionary:
		_pools = (pools as Dictionary).duplicate()
	var owned = d.get("owned")
	if owned is Array and not (owned as Array).is_empty():
		_owned.clear()
		for w in owned:
			_owned[int(w)] = true
	speed_boost = float(d.get("speed_boost", 1.0))
	_weapon_idx = clampi(int(d.get("weapon", _weapon_idx)), 0, _weapons.size() - 1)
	if not _owned.has(_weapon_idx):
		_owned[_weapon_idx] = true
	_vm_idx = 0
	_vm_firing = false
	_sync_hud()

func _capture(on: bool) -> void:
	_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE

## Build the first-person weapon viewmodel overlay and load each weapon's
## .CFA animation frames.
## The optional 3D weapon in the hands (DETAIL → WEAPON VIEW). It hangs
## off the camera at the same screen corner the DOS art occupies, kicks
## back when it fires and sways a little as the player walks. The DOS
## CFA art stays the default: it is hand-drawn WITH the soldier's
## gloves, which a primitive model cannot match.
## How far the viewmodel is allowed to sink behind the HUD bar, in DOS
## pixels — the grip and the hands read better tucked slightly under it.
const HUD_OVERLAP: float = 14.0
const VM3D_LEN: float = 34.0            # model length in world units
const VM3D_POS := Vector3(11.0, -6.5, -26.0)
const VM3D_YAW: float = 0.17
var _vm3d: Node3D = null
var _vm3d_idx: int = -1
var _vm3d_kick: float = 0.0

func _build_viewmodel() -> void:
	_vm_layer = CanvasLayer.new()
	_vm_layer.layer = 2                       # above the 3D view, below the HUD
	add_child(_vm_layer)
	_viewmodel = TextureRect.new()
	_viewmodel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_viewmodel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewmodel.visible = false
	_vm_layer.add_child(_viewmodel)
	_load_viewmodels()

## Load the .CFA viewmodel frames for every weapon that names one
## (WEAPON*.CFA in MDMDIMGS.BSA).
func _load_viewmodels() -> void:
	for i in _weapons.size():
		var cfa: String = String(_weapons[i].get("cfa", ""))
		if cfa.is_empty():
			continue
		var frames: Array = Assets.cfa_frames(cfa)
		if not frames.is_empty():
			_vm_cache[i] = frames
			print("[weapon] %s — %d viewmodel frames" % [cfa, frames.size()])

## Advance the viewmodel animation and keep it pinned bottom-centre.
func _process(delta: float) -> void:
	if _viewmodel == null:
		return
	_update_viewmodel_3d(delta)
	var frames: Array = _vm_cache.get(_weapon_idx, []) if vehicle == VEH_FOOT else []
	if frames.is_empty() or _vm3d != null:
		_viewmodel.visible = false
		return
	_viewmodel.visible = true
	if _vm_firing:
		_vm_t += delta
		# Per-weapon playback speed. Hand-tuned: DOS record +0x2c is the
		# recoil kick (skynet_gh.c:28236), not a frame rate.
		var fps: float = maxf(1.0,
			float(_weapons[_weapon_idx].get("animspd", 16)))
		var step := 1.0 / fps
		while _vm_t >= step:
			_vm_t -= step
			_vm_idx += 1
			if _vm_idx >= frames.size():
				_vm_idx = 0                   # back to the idle pose
				_vm_firing = false
				break
	_viewmodel.texture = frames[_vm_idx]
	_layout_viewmodel()

## Build / place the 3D weapon in the hands when the option is on.
func _update_viewmodel_3d(delta: float) -> void:
	var want: bool = Settings.weapon_3d and Render.enhanced() \
		and vehicle == VEH_FOOT and _cam != null and health > 0.0
	if not want:
		if _vm3d != null and is_instance_valid(_vm3d):
			_vm3d.queue_free()
		_vm3d = null
		_vm3d_idx = -1
		return
	if _vm3d_idx != _weapon_idx or _vm3d == null or not is_instance_valid(_vm3d):
		if _vm3d != null and is_instance_valid(_vm3d):
			_vm3d.queue_free()
		_vm3d = WeaponModels.for_weapon(_weapon_idx, VM3D_LEN, VM3D_LEN * 0.34)
		_vm3d_idx = _weapon_idx
		if _vm3d == null:
			return
		# Barrel forward (models are built along +X), grip toward the
		# player, and never clipped by the world.
		# Models are built along +X; a +90 deg yaw sends +X to -Z, i.e.
		# the barrel away from the camera.
		_vm3d.rotation = Vector3(0.0, PI * 0.5 + VM3D_YAW, 0.0)
		# Draw it over the world: a gun held at 22 units would otherwise
		# be sliced by any wall or slope the player stands near.
		for c in _vm3d.get_children():
			if not (c is MeshInstance3D):
				continue
			var mi: MeshInstance3D = c
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var src: Material = mi.get_active_material(0)
			if src is BaseMaterial3D:
				var dup: BaseMaterial3D = (src as BaseMaterial3D).duplicate()
				dup.no_depth_test = true
				dup.render_priority = 8
				mi.material_override = dup
		_cam.add_child(_vm3d)
	# Recoil: a kick back and up that eases out, plus a walking sway.
	if _vm_firing and _vm3d_kick < 0.2:
		_vm3d_kick = 1.0
	_vm3d_kick = maxf(_vm3d_kick - delta * 6.0, 0.0)
	var speed: float = Vector2(velocity.x, velocity.z).length() / maxf(walk_speed, 1.0)
	var t: float = float(Time.get_ticks_msec()) * 0.004
	var sway := Vector3(sin(t) * 0.6, absf(cos(t)) * 0.5, 0.0) * clampf(speed, 0.0, 1.2)
	_vm3d.position = VM3D_POS + sway + Vector3(0.0, _vm3d_kick * 1.2, _vm3d_kick * 3.0)
	_vm3d.rotation.x = _vm3d_kick * 0.22

## Pin the viewmodel sprite to the bottom-centre of the screen, scaled to
## the viewport like the DOS 320×200 screen.
func _layout_viewmodel() -> void:
	if _viewmodel.texture == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var ts := _viewmodel.texture.get_size()
	# Treat the screen as the DOS 320×200, scaled to the viewport height
	# and centred. The viewmodel's left edge sits at the weapon's DOS X
	# (record +0x00); the sprite is anchored to the screen bottom.
	var s: float = vp.y / 200.0
	var x_origin: float = (vp.x - 320.0 * s) * 0.5
	var vx: float = float(_weapons[_weapon_idx].get("vx", 80))
	_viewmodel.size = ts
	_viewmodel.scale = Vector2(s, s)
	# The gun stands ON the HUD bar, not behind it. DOS draws the world
	# in a 320x160 viewport with the 40 px panel below; the port's panel
	# is the same art scaled by WIDTH (main._layout_hud), so its top edge
	# is where the weapon's bottom belongs. Anchoring to the window
	# bottom (as this did) hid all but the muzzle behind the panel.
	var hud_h: float = clampf(vp.x / 8.0, 64.0, 160.0)
	_viewmodel.position = Vector2(
		x_origin + vx * s, vp.y - hud_h - ts.y * s + HUD_OVERLAP * s)
