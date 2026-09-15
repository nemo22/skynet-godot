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
## Extra horizontal speed carried through a jump taken at full
## sprint. Scales with how fast the player actually left the
## ground, so a standing jump is unchanged.
const JUMP_RUN_BOOST: float = 0.35
var _air_boost: float = 0.0
@export var mouse_sensitivity: float = 0.003
@export var touch_look_speed: float = 2.2

const Tracer := preload("res://scripts/tracer.gd")
const Projectile := preload("res://scripts/projectile.gd")
const Grenade := preload("res://scripts/grenade.gd")
const MuzzleFlash := preload("res://scripts/muzzle_flash.gd")
const SmokePuff := preload("res://scripts/smoke_puff.gd")
const Explosion := preload("res://scripts/explosion.gd")
const PauseState := preload("res://scripts/pause_state.gd")
## How far ahead of the muzzle the player's own tracer starts, and how
## far it is allowed to reach.
const TRACER_START: float = 420.0
const TRACER_MAX: float = 2600.0

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
## in-game (not in a network game). Persists across map changes; the
## title menu clears it, and so does starting a network game from it.
static var god_mode: bool = false

# Driven each frame by the TouchControls overlay; stays zero on desktop.
var ui_move: Vector2 = Vector2.ZERO   # x = strafe (+right), y = forward (+)
var ui_look: Vector2 = Vector2.ZERO   # x = yaw rate, y = pitch rate, -1..1
var ui_vert: float = 0.0              # >0 = jump (walk) / rise (noclip)
var ui_sprint: bool = false           # touch/automation RUN, same as Shift

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
## The steepest ground a man on foot walks up. DOS (0x12b192) lets a rise
## onto a face only when its normal's Y is at least 196/256 — cos 40° —
## and treats anything steeper as a wall to slide along, so the hills
## round the canyons cannot be walked over or round ("pôvodne hráč
## nemohol chodiť po kopcoch", playtest, 2026-09-11). The jeep's wheels have
## no such test and it climbs.
const FOOT_MAX_SLOPE_DEG: float = 40.0
const VEH_MAX_SLOPE_DEG: float = 75.0
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
	# DOS record 13: no ammo type, no pool, no fire or dry sound, view X
	# 168 — not a gun but the MP MOTION DETECTOR, the hand-held scanner a
	# HUMAN player carries (the DOS deathmatch, 2026-09-12). Its draw
	# code (0x132b00) marks the other players; see net/motion_detector.gd.
	{"name": "MOTION DETECTOR",  "kind": "detector", "dmg": 0.0,  "rate": 2,  "pool": -1, "cost": 0,   "snd": "", "sel": -1, "dry": -1, "cfa": "WEAPON13.CFA", "animspd": 8, "vx": 168},
]
## Where each slot's shot leaves and where it flies (read from Skynet.exe
## 0x4361c): [record +0x30 x right, +0x34 y DOWN, +0x38 z ahead — all from
## the eye, in the view's frame; DOS adds 20 to z (FUN_00125caf, 0x125d45)
## — and +0x5c bit 1, set when the shot flies AT the point under the
## crosshair (0x125dc3; without it, straight along the view)]. The guns
## that fire from the eye itself carry (0,0,0). Vehicle slots are
## records 20/22 (their pairs 21/23 hold the other barrel, the same x
## negated), 24, 25; the detector is record 13.
const MUZZLE: Array = [
	[Vector3(-10.0, 10.0, 30.0), false],   # 0  PIPE (the swing reaches from the eye)
	[Vector3.ZERO, true],                  # 1  UZI
	[Vector3.ZERO, true],                  # 2  ASSAULT RIFLE
	[Vector3.ZERO, true],                  # 3  MACHINE GUN
	[Vector3.ZERO, true],                  # 4  SHOTGUN
	[Vector3(3.0, 5.0, 0.0), false],       # 5  GRENADE LAUNCHER
	[Vector3(18.0, 1.0, 18.0), true],      # 6  ROCKET LAUNCHER
	[Vector3(16.0, 14.0, 20.0), true],     # 7  LASER RIFLE
	[Vector3(16.0, 14.0, 20.0), true],     # 8  LASER CANNON
	[Vector3(8.0, 10.0, 40.0), true],      # 9  PLASMA PISTOL
	[Vector3(14.0, 13.0, 20.0), true],     # 10 PLASMA RIFLE
	[Vector3(16.0, 11.0, 20.0), true],     # 11 PLASMA CANNON
	[Vector3.ZERO, true],                  # 12 SUPER UZI
	[Vector3(-20.0, 60.0, 80.0), true],    # 13 JEEP PLASMA (records 20/21)
	[Vector3(-10.0, 55.0, 80.0), true],    # 14 JEEP ROCKETS (22/23)
	[Vector3(-15.0, -30.0, 115.0), true],  # 15 HK LASER (24)
	[Vector3(0.0, -30.0, 115.0), true],    # 16 HK ROCKETS (25)
	[Vector3(-10.0, 10.0, 30.0), false],   # 17 MOTION DETECTOR (13)
]
## The thrown items, records 14-19: all leave the left hand, none aimed.
const THROW_MUZZLE: Vector3 = Vector3(-20.0, 25.0, 0.0)
## DOS's own addition to every muzzle's z.
const MUZZLE_AHEAD: float = 20.0
## Index of the detector in `_weapons` above.
const MOTION_DETECTOR: int = 17
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
var secondary_pool: int = -1           # the ammo pool it draws from
const VEH_FOOT: int = 0
const VEH_JEEP: int = 1
const VEH_HK: int = 2
const VEH_NAMES: Array = ["", "JEEP", "HK"]
## Eye height above the body origin per vehicle (DOS foot = 75).
const VEH_EYE: Array = [75.0, 92.0, 110.0]
## Capsule (radius, height) per vehicle — the HUMMER is 106×75×227, the
## HK_FTR 357×205×501; a rounder body slides over terrain and rubble.
## On foot the DOS player is a cylinder that ignores ceilings; interior
## doorways are as small as 70 × 105 u (MAP.231 ROM4 → corridor). The foot
## body was 26 (the scene) or 22 (after a vehicle), plus the 4 u safe
## margin — 52-60 u across, and the submarine of mission 5 is narrower
## than that: --solve found the cabin, the mess hall and the torpedo-room
## corridor impassable at an effective radius of 26 and passable at 20
## (2026-09-11). 16 + 4 is that 20: a 40 u body, the proportions of a man
## whose eyes are at 75, and still well inside the smallest doorway.
## Height 76, not 88: DOS ignores ceilings for the player, and the port's
## 88 u body (92 with the margin) could not pass the 88 u lintel in front
## of the submarine's engine-room bulkhead (floormap ceil, 2026-09-11).
## The top, 80 with the margin, still sits above the eyes at 75.
## Same as the Player capsule in main.tscn, so leaving a vehicle does not
## change the body.
const VEH_CAPSULE: Array = [[16.0, 76.0], [55.0, 110.0], [110.0, 220.0]]
## Jeep: DOS mission 2/6 driving. The DOS handler (0x134eec, data from
## ds:0x23700, disassembled 2026-09-11) in u/s and u/s²: the throttle
## pulls 1148 divided by the gear, max(1, v / 21.45), up to 683.6 — the
## port's 1800 was 2.6 times too fast ("jeep jazdí extrémne rýchlo");
## the brake and reverse take 459, down to -140; rolling drag is 153;
## the slope adds 1148·sin of itself.
const JEEP_MAX_SPEED: float = 683.6
const JEEP_REVERSE_SPEED: float = 140.0
const JEEP_ACCEL: float = 1148.0
const JEEP_GEAR: float = 21.45
const JEEP_BRAKE: float = 459.0
const JEEP_DRAG: float = 153.0
## Turning (0x135271): none below JEEP_GEAR u/s, else wheel·721.6/v rad/s,
## at most 1.074 (350 of 2048 a second), the other way round in reverse.
const JEEP_TURN_K: float = 721.6
const JEEP_TURN_MAX: float = 1.074
## The wheel goes lock to lock in 0.305 s and back to centre as fast.
const JEEP_WHEEL_RATE: float = 3.28
## The brake squeals (sound 29) above this speed.
const JEEP_SKID_SPEED: float = 171.0
## HK: DOS mission 7 flight — hover, thrust in every axis, no gravity.
const HK_SPEED: float = 2600.0
const HK_STRAFE: float = 1400.0
const HK_CLIMB: float = 900.0
const HK_ACCEL: float = 2200.0
const HK_MIN_ALTITUDE: float = 150.0
## …and a ceiling over it. DOS caps how high the gunship may climb
## ("v DOS hre bolo limitované, ako vysoko môže hráč vyletieť
## s hkčkom"); without it mission 7 is won by climbing over the
## canyon and crossing the map, instead of shooting through it.
## The band is the enemy fighter's own: hk_ftr flies at `alt` 384
## (284 over the ground), the player gets roughly twice that.
const HK_MAX_ALTITUDE: float = 700.0
const HK_CEILING_PROBE: float = 20000.0
const HK_ROOF_PROBE: float = 4000.0
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
## Weapons the player keeps besides the campaign's starting arsenal —
## the deathmatch class's own kit (a HUMAN's motion detector). Re-applied
## by _reset_owned, so a respawn does not take it away.
var extra_owned: Array = []
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
var _pools: Dictionary = {}          # pool id → rounds left

# --- weapon viewmodel (the gun drawn at the bottom of the screen) -------
var _vm_layer: CanvasLayer = null
var _viewmodel: TextureRect = null
var _vm_cache: Dictionary = {}        # weapon idx → Array[ImageTexture]
## weapon idx → true when its frames came from the 640x480 set, which
## draws at half the scale (Assets.cfa_is_hires decides which set).
## this, so the width tells the two sets apart.
var _vm_hires: Dictionary = {}
## weapon idx → the hi-res art's own x/y, (0,0) when it carries none.
var _vm_off: Dictionary = {}
## weapon idx → the 320x200 frame size, the rectangle the hi-res art is
## drawn into.
var _vm_lo: Dictionary = {}
var _vm_idx: int = 0
var _vm_t: float = 0.0
var _vm_firing: bool = false

func _ready() -> void:
	add_to_group("player")
	# DOS's 40° on foot (set_vehicle changes it for the vehicles).
	floor_max_angle = deg_to_rad(FOOT_MAX_SLOPE_DEG)
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
		_net_env_dmg = 0.0                 # owed by the life that just ended
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
	for w in extra_owned:                # the deathmatch class's own kit
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
	v = clampi(v, VEH_FOOT, VEH_HK)
	if v == vehicle:
		return
	if vehicle == VEH_FOOT:
		_foot_owned = _owned.duplicate()
		_foot_weapon = _weapon_idx
	vehicle = v
	veh_hull = VEH_HULL_POINTS               # a fresh ride, a whole hull
	_veh_speed = 0.0
	_wheel = 0.0
	_tilt_pitch = 0.0
	_tilt_roll = 0.0
	velocity = Vector3.ZERO
	floor_max_angle = deg_to_rad(FOOT_MAX_SLOPE_DEG if v == VEH_FOOT else VEH_MAX_SLOPE_DEG)
	if _cam != null:
		_cam.rotation.z = 0.0
		_cam.rotation.y = 0.0            # the turret faces the bonnet again
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
		_swim_body = false              # a fresh capsule, standing height
	if v == VEH_HK:
		# Lift off the ground so the hover starts clear of the terrain.
		global_position.y += 60.0
	if v != VEH_FOOT:
		Audio.play_id(int(_weapons[_weapon_idx].get("sel", -1)), -8.0)
	_start_engine(v)
	_attach_cockpit(v)
	_sync_hud()
	print("[player] vehicle: %s" % (VEH_NAMES[v] if v > 0 else "on foot"))

## The vehicle as the DOS player sees it from inside: its own model drawn
## round the eye. Skynet.exe's HUD table (0x44700) names hummer.3d for
## the jeep and hkcockpt.3d for the HK. Back faces are culled, so from
## inside only the windscreen frame, the roll bar and the bonnet show - the
## view in the DOS screenshots (2026-09-11). The port had drawn
## PANEL1/PANEL2.IMG instead, full-screen dashboards the executable never
## loads (panel0.img is its only panel name).
## The jeep's model rides the CAR (a pivot at the eye that tilts with the
## cab), so the turret camera swings across it; the HK's rides the
## camera, which points where the craft does.
const VEH_COCKPIT: Array = ["", "HUMMER.3D", "HKCOCKPT.3D"]
## Where the model sits relative to the eye. A HUD-table entry is
## {handle, x, y, z, name}: FUN_00126415 loads the model once and
## FUN_00133d26 adds (x, y, z) << 8 to every vertex (the y rides in EBX,
## which Ghidra shows as unaff_EBX); FUN_0012645c then draws it at the
## camera position. DOS y is down and z ahead, so the jeep's 26,22,8 is
## (26, -22, -8) here: the eye sits in the LEFT seat, 22 over the model's
## origin, and the windscreen's centre post stands 30 to the right - the
## post at the lower right of the DOS shot, not a post in mid-view
## (read as 0,26,22 it was; no placement round the car's middle matched).
## The HK's 0,4,16 is (0, -4, -16).
const VEH_COCKPIT_OFFSET: Array = [Vector3.ZERO, Vector3(26.0, -22.0, -8.0), Vector3(0.0, -4.0, -16.0)]
var _cockpit_pivot: Node3D = null

func _attach_cockpit(v: int) -> void:
	if _cockpit_pivot != null and is_instance_valid(_cockpit_pivot):
		# Its duplicated flat materials are let go first and the node is
		# taken out of the world at once, then freed at the end of the
		# frame. Left as it was, the materials went before the instance, and
		# a respawn straight out of a vehicle (the player moves that same
		# frame) had the renderer update an instance whose materials were
		# gone — 16 "material is null" errors, 2026-09-14.
		for c in _cockpit_pivot.get_children():
			if c is MeshInstance3D:
				for si in (c as MeshInstance3D).get_surface_override_material_count():
					(c as MeshInstance3D).set_surface_override_material(si, null)
		var holder: Node = _cockpit_pivot.get_parent()
		if holder != null:
			holder.remove_child(_cockpit_pivot)
		_cockpit_pivot.queue_free()
	_cockpit_pivot = null
	if v == VEH_FOOT or _cam == null:
		return
	var am: ArrayMesh = Assets.mesh(String(VEH_COCKPIT[v]))
	if am == null:
		return
	_cockpit_pivot = Node3D.new()
	_cockpit_pivot.name = "Cockpit"
	var mi := MeshInstance3D.new()
	mi.mesh = am
	# Flat, as DOS draws it: seen from inside, every face looks back at the
	# driver, away from whatever light the level has.
	for si in am.get_surface_count():
		var sm: Material = am.surface_get_material(si)
		if sm is BaseMaterial3D:
			var flat := (sm as BaseMaterial3D).duplicate() as BaseMaterial3D
			flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mi.set_surface_override_material(si, flat)
	mi.position = VEH_COCKPIT_OFFSET[v]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cockpit_pivot.add_child(mi)
	if v == VEH_HK:
		_cam.add_child(_cockpit_pivot)
	else:
		_cockpit_pivot.position = Vector3(0.0, float(VEH_EYE[v]), 0.0)
		add_child(_cockpit_pivot)

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

## Put one more weapon in the player's hands (the deathmatch loadout:
## a HUMAN carries the motion detector besides the guns).
func grant_weapon(idx: int) -> void:
	if idx >= 0 and idx < _weapons.size():
		_owned[idx] = true

func drop_weapon(idx: int) -> void:
	if _owned.has(idx):
		_owned.erase(idx)
		if _weapon_idx == idx:
			_select_weapon(_next_owned(idx, 1))

## The detector's slot in `_weapons` — a method, so callers need not
## reach for a script constant through an instance.
func motion_detector_slot() -> int:
	return MOTION_DETECTOR

## Is the motion detector the weapon in hand right now?
func detector_active() -> bool:
	return _weapon_idx == MOTION_DETECTOR and vehicle == VEH_FOOT and health > 0.0

## Rounds left for weapon `idx` — its pool's count, or 99 for the pipe.
func _ammo_for(idx: int) -> int:
	if String(_weapons[idx].get("kind", "")) == "detector":
		return -1                          # a scanner has no rounds to show
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
		secondary_pool = int(THROWABLES[_throw_idx]["pool"])
		secondary_ammo = int(_pools.get(secondary_pool, 0))

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
	# The debug toggles stay out of a network game: hits are checked on the
	# victim's machine, so F9 made a player invulnerable online, and F8
	# flew through the arena walls.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F8 and not Net.active:
		noclip = not noclip
		velocity = Vector3.ZERO
		print("[player] noclip %s" % ("ON" if noclip else "OFF"))
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F9 and not Net.active:
		god_mode = not god_mode
		print("[player] god mode %s" % ("ON" if god_mode else "OFF"))
		return
	if _mobile:
		return                           # touch handled by TouchControls
	if event is InputEventMouseButton and event.pressed:
		if not _captured and event.button_index == MOUSE_BUTTON_LEFT:
			# An overlay (Esc menu, console — they keep the game running in a
			# network match) owns the cursor: a click is its, not the view's.
			if not PauseState.mouse_wanted():
				_capture(true)
			return
		if _captured and _act_on(event):
			return
		match event.button_index:
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
		elif _act_on(event):
			pass
		elif Controls.matches(event, "activate"):
			_try_activate()
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
	_flush_env_damage(delta)

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
	elif _captured and not _mobile and Controls.is_pressed("fire"):
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

	var was: Vector3 = global_position
	if noclip:
		_fly(delta, fwd_in, str_in)
	elif vehicle == VEH_JEEP:
		_drive(delta, fwd_in, str_in)
	elif vehicle == VEH_HK:
		_hover(delta, fwd_in, str_in)
	else:
		_walk(delta, fwd_in, str_in)
	_border_clamp(was)

## The map's own fence (DOS FUN_00122789, boxes from FUN_00122711 — see
## LevelLoader.border_boxes): every commit of the player's move has to
## land inside one of the boxes, or the move is UNDONE and the speed
## zeroed. That is the invisible wall on MAP.260, which keeps the jeep in
## the town and on the inner highway lane. Within 64 units of an edge the
## engine prints hint slot 8 = [G9] ("The highway is the other way.")
## once, re-armed when the player leaves the band.
const BORDER_HINT_MARGIN: float = 64.0
var border_boxes: Array = []          # Rect2 in world x/z; empty = no fence
var _border_hinted: bool = false
signal border_hint()

func _border_clamp(prev: Vector3) -> void:
	if border_boxes.is_empty() or noclip:
		return
	var p := Vector2(global_position.x, global_position.z)
	var box: Rect2 = Rect2()
	var found: bool = false
	for b in border_boxes:
		if (b as Rect2).has_point(p):
			box = b
			found = true
			break
	if not found:
		# Only a way back INTO the fence is a refuge. When the position
		# before the move is outside every box too — a spawn, a loaded
		# save or a stuck reset put the player there — restoring it would
		# undo every move from then on and freeze him for good; the move
		# stands, and the fence holds from the moment he is inside a box.
		if not _inside_border(Vector2(prev.x, prev.z)):
			return
		global_position = prev
		velocity = Vector3.ZERO
		_veh_speed = 0.0
		return
	var edge: float = minf(
		minf(p.x - box.position.x, box.end.x - p.x),
		minf(p.y - box.position.y, box.end.y - p.y))
	if edge > BORDER_HINT_MARGIN:
		_border_hinted = false
	elif not _border_hinted:
		_border_hinted = true
		border_hint.emit()

## Is the x/z point `p` inside one of the fence boxes?
func _inside_border(p: Vector2) -> bool:
	for b in border_boxes:
		if (b as Rect2).has_point(p):
			return true
	return false

## Jeep (DOS mode 4): a car, not a hovercraft — the mouse and A/D turn
## a steering WHEEL, the heading only changes while the wheels roll
## (faster at speed, self-centring), the cab pitches and rolls with the
## ground under it, bumps shake the view at speed, the brake squeals.
var _wheel: float = 0.0               # -1..1 steering wheel
var _tilt_pitch: float = 0.0
var _tilt_roll: float = 0.0
var _bump_t: float = 0.0
var _skid_cd: float = 0.0
const JEEP_TILT_RATE: float = 6.0

## Jeep turret aim (DOS: the keys drive, the mouse turns the view - the
## camera is the turret). Relative to the car's heading.
var _aim_yaw: float = 0.0
var _aim_pitch: float = 0.0
const JEEP_AIM_YAW: float = 1.1
const JEEP_AIM_PITCH_DOWN: float = -0.45
const JEEP_AIM_PITCH_UP: float = 0.6
## Ramming (DOS v1.00 0x135a7e, run once per move from 0x135588). The
## car's state is saved before the move; after it, the first object the
## hull touches gets ObjHit (0x139019) with speed_field >> 9 — the field
## is u/s x 256, so v/2 at v u/s, and a reversing car deals nothing
## (ObjHit clamps a negative hit to 0). No DIFFICULTY factor: that lives
## in the projectile impact path, not in ObjHit. ObjHit's carry decides:
##   destroyed (clc)            -> the car drives on at 7/8 speed, sound 30
##   survived or no HP (stc)    -> the saved state comes back (position
##                                 and heading) and the speed is NEGATED,
##                                 sound 30 — the car bounces off.
## So a raptor (200 HP) takes two rams at 300 u/s, a T-800 (500) four,
## and every one that fails throws the car back under fire. The port
## used to dose v/2 every 1/25 s while the probe overlapped and always
## rolled on — any robot, however big, burst at the first touch
## (playtest 2026-09-15). The ram itself does the driver no harm in v1.00;
## what hurts him is the robot's death blast (Enemy.DEATH_BLAST_*) as the
## car rolls on over the wreck.
const RAM_MIN_SPEED: float = 2.0
## The hull the ram test uses: HUMMER.3D is 106 x 75 x 227, plus a few
## units, lifted off the ground so flat floors never count as a touch.
const RAM_HALF: Vector3 = Vector3(57.0, 30.0, 118.0)
const RAM_LIFT: float = 50.0
const RAM_MAX_RESULTS: int = 16
## A second hit on the same thing waits this long. DOS has no such wait,
## but its restore-and-negate means a real second ram needs a run-up;
## without one, holding the throttle against a robot re-hits it every
## few frames at one frame's worth of speed.
const RAM_REARM: float = 0.3
var _ram_next: Dictionary = {}     # target instance id -> _ram_clock when it may be hit again
var _ram_clock: float = 0.0        # seconds driven, the clock _ram_next counts in
## The ram probe, built on first use and kept: a fresh query and shape
## every physics tick while driving created and freed a physics shape 60
## times a second.
var _ram_query: PhysicsShapeQueryParameters3D = null
const RAM_CD_PRUNE: int = 16       # expired waits are swept past this many

## Direction the guns fire: where the camera looks. In the jeep the
## camera IS the turret - the mouse turns it, the keys drive the car -
## so the car's frame swings across the view as you aim and the
## crosshair stays on the aim point (the DOS screenshots, 2026-09-11;
## the port had moved a crosshair over a view fixed to the car).
## The camera's axis projects exactly onto the crosshair: the projection
## centre IS the crosshair point (see _update_projection), so this is the
## ray through it. (Camera3D.project_ray_normal is not used for it: it
## builds the ray from symmetric viewport half-extents, which a shifted
## frustum does not have.)
func aim_dir() -> Vector3:
	return -_cam.global_transform.basis.z

## Drive into something (see RAM_*). `pre_pos` / `pre_yaw` are the car's
## state before this move — what DOS copies to 0x237b4 and puts back on a
## bounce. True when the ram undid the move, so the caller's own wall
## bounce must not negate the speed a second time.
func _ram_check(pre_pos: Vector3, pre_yaw: float) -> bool:
	# A wait ends once the clock reaches its stamp; stale stamps are only
	# swept when they pile up.
	_ram_clock += get_physics_process_delta_time()
	if _ram_next.size() > RAM_CD_PRUNE:
		for k in _ram_next.keys():
			if _ram_clock >= float(_ram_next[k]):
				_ram_next.erase(k)
	if absf(_veh_speed) < RAM_MIN_SPEED:
		return false
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var now: Dictionary = _ram_targets(space, global_position, _yaw)
	if now.is_empty():
		return false
	# Only a touch THIS move made is a ram. Something already inside the
	# hull before it (a robot that walked into a standing car) is left
	# alone: restoring a position that touches it too would pin the car
	# there for good.
	var before: Dictionary = _ram_targets(space, pre_pos, pre_yaw)
	for id in now:
		if before.has(id):
			continue
		var n: Node = now[id]
		if _ram_clock < float(_ram_next.get(id, -1.0)):
			# Hit a moment ago: the car is stopped, not dosed again.
			_ram_undo(pre_pos, pre_yaw, false)
			return true
		_ram_next[id] = _ram_clock + RAM_REARM
		var dmg: float = maxf(floorf(_veh_speed * 0.5), 0.0)
		var destroyed: bool = false
		if n.is_in_group("enemy"):
			destroyed = n.has_method("obj_hit") and bool(n.call("obj_hit", dmg))
		elif n.has_method("is_damageable") and bool(n.call("is_damageable")):
			# A breakable map entity through the action system's ObjHit —
			# the car-wash door on MAP.260 (CWDOOR, 60 HP) falls to one ram
			# above 120 u/s, and that is how the jeep leaves the town.
			n.call("take_damage", dmg)
			destroyed = not bool(n.call("is_damageable"))
		Audio.play_id(30, -3.0)
		print("[ram] %s: %d at %.0f u/s -> %s" % [String(n.get_meta("mesh_name", n.name)),
			int(dmg), _veh_speed, "destroyed, drive on" if destroyed else "bounced"])
		if destroyed:
			_veh_speed *= 0.875
			return false
		_ram_undo(pre_pos, pre_yaw, true)
		return true
	return false

## Ram targets the car's hull box overlaps with the car at `at` facing
## `yaw`: instance id -> the robot (group "enemy") or map entity (group
## "hittable") that owns the collider.
func _ram_targets(space: PhysicsDirectSpaceState3D, at: Vector3, yaw: float) -> Dictionary:
	if _ram_query == null:
		var sh := BoxShape3D.new()
		sh.size = RAM_HALF * 2.0
		_ram_query = PhysicsShapeQueryParameters3D.new()
		_ram_query.shape = sh
		_ram_query.collide_with_areas = true      # robot hitboxes are areas
		_ram_query.collide_with_bodies = true
		_ram_query.exclude = [get_rid()]
	_ram_query.transform = Transform3D(Basis(Vector3.UP, yaw), at + Vector3(0.0, RAM_LIFT, 0.0))
	var out: Dictionary = {}
	for hit in space.intersect_shape(_ram_query, RAM_MAX_RESULTS):
		var n: Node = hit.get("collider") as Node
		while n != null and not (n.has_method("take_damage")
				and (n.is_in_group("enemy") or n.is_in_group("hittable"))):
			n = n.get_parent()
		if n == null or out.has(n.get_instance_id()):
			continue
		if n.has_method("is_dead") and bool(n.call("is_dead")):
			continue                                # a wreck on its way out
		out[n.get_instance_id()] = n
	return out

## Put the car back where the move started. `bounce` negates the speed
## (DOS 0x1355c5: neg of both speed fields) and centres the wheel
## (0x1355d1); without it the car just stops.
func _ram_undo(pre_pos: Vector3, pre_yaw: float, bounce: bool) -> void:
	global_position = pre_pos
	_yaw = pre_yaw
	rotation.y = pre_yaw
	_veh_speed = -_veh_speed if bounce else 0.0
	if bounce:
		_wheel = 0.0
	velocity.x = 0.0
	velocity.z = 0.0

func _drive(delta: float, fwd_in: float, str_in: float) -> void:
	# The state a ram bounce restores — taken before the wheel turns the
	# heading, as DOS saves it before 0x135201 steers.
	var pre_pos: Vector3 = global_position
	var pre_yaw: float = _yaw
	var grounded: bool = is_on_floor()
	# Keys hold the wheel; without input it returns to centre (the mouse
	# nudges it in _unhandled_input). Lock to lock in 0.305 s, as DOS.
	if absf(str_in) > 0.1:
		_wheel = clampf(_wheel + str_in * JEEP_WHEEL_RATE * delta, -1.0, 1.0)
	else:
		_wheel = move_toward(_wheel, 0.0, JEEP_WHEEL_RATE * delta)
	# Heading: DOS turns only with the wheels on the ground and above
	# JEEP_GEAR u/s, at wheel·721.6/v rad/s up to 1.074 — about the same
	# rate at any speed — and the other way round when backing up.
	var spd: float = absf(_veh_speed)
	if grounded and spd > JEEP_GEAR:
		var yaw_rate: float = clampf(_wheel * JEEP_TURN_K / spd, -JEEP_TURN_MAX, JEEP_TURN_MAX)
		if _veh_speed < 0.0:
			yaw_rate = -yaw_rate
		_yaw -= yaw_rate * delta
	rotation.y = _yaw
	var fwd := -Basis(Vector3.UP, _yaw).z
	# Throttle and brake work through wheels on the ground only.
	if grounded:
		if fwd_in > 0.1:
			if _veh_speed < 0.0:
				_veh_speed = minf(_veh_speed + JEEP_BRAKE * delta, 0.0)
			else:
				var gear: float = maxf(1.0, floorf(_veh_speed / JEEP_GEAR))
				_veh_speed = minf(_veh_speed + JEEP_ACCEL / gear * delta, JEEP_MAX_SPEED * speed_boost)
			_skid_cd = 0.0
		elif fwd_in < -0.1:
			if _veh_speed > JEEP_SKID_SPEED:
				_skid_cd -= delta
				if _skid_cd <= 0.0:
					_skid_cd = 0.9
					Audio.play_id(29, -8.0)     # the tyres squeal under the brake
			_veh_speed = maxf(_veh_speed - JEEP_BRAKE * delta, -JEEP_REVERSE_SPEED)
		else:
			_veh_speed = move_toward(_veh_speed, 0.0, JEEP_DRAG * delta)
			_skid_cd = 0.0
		# Downhill pulls and uphill holds back: 1148·sin of the slope
		# along the heading.
		_veh_speed += JEEP_ACCEL * get_floor_normal().dot(fwd) * delta
	velocity.x = fwd.x * _veh_speed
	velocity.z = fwd.z * _veh_speed
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	var before := global_position
	move_and_slide()
	var rammed: bool = _ram_check(pre_pos, pre_yaw)
	# A wall throws the car back at the speed it came in with and the
	# wheel snaps straight — carcoll2 (DOS 0x135a7e negates the speed).
	if not rammed and absf(_veh_speed) > 50.0 and is_on_wall() \
			and global_position.distance_to(before) < absf(_veh_speed) * delta * 0.2:
		Audio.play_id(30, -4.0)
		_veh_speed = -_veh_speed
		_wheel = 0.0
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
		# The camera is the turret: the aim turns it, the cab tilts and
		# shakes it.
		_cam.rotation.y = _aim_yaw
		_cam.rotation.x = _aim_pitch + _tilt_pitch + sin(_bump_t) * 0.004 * sk
		_cam.rotation.z = _tilt_roll + cos(_bump_t * 0.7) * 0.006 * sk
		_cam.position.y = float(VEH_EYE[VEH_JEEP]) + sin(_bump_t * 1.3) * 3.0 * sk
	if _cockpit_pivot != null and is_instance_valid(_cockpit_pivot):
		# The car's own frame tilts with the cab, not with the aim.
		_cockpit_pivot.rotation = Vector3(_tilt_pitch, 0.0, _tilt_roll)
		if _cam != null:
			_cockpit_pivot.position.y = _cam.position.y
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
	if _sprinting():
		want *= 1.4
	velocity = velocity.move_toward(want, HK_ACCEL * delta)
	# Ground clearance: push up when the surface below comes too close.
	var space := get_world_3d().direct_space_state
	if space != null:
		# Long enough to find the ground from the top of the band, not
		# just from just above the floor — the ceiling needs the same
		# measurement the floor push does.
		var q := _hk_ray_query(global_position + Vector3(0.0, 20.0, 0.0),
			global_position - Vector3(0.0, HK_CEILING_PROBE, 0.0))
		var hit := space.intersect_ray(q)
		if hit.has("position"):
			var clearance: float = global_position.y - (hit["position"] as Vector3).y
			if clearance < HK_MIN_ALTITUDE and velocity.y < HK_CLIMB * 0.5:
				velocity.y = maxf(velocity.y, (HK_MIN_ALTITUDE - clearance) * 4.0)
			elif clearance > HK_MAX_ALTITUDE and not _roofed(space):
				# Firm, but not a wall: the higher the gunship gets, the
				# harder it sinks back into its band.
				velocity.y = minf(velocity.y, -minf(
					(clearance - HK_MAX_ALTITUDE) * 2.0, HK_CLIMB))
	move_and_slide()
	_update_engine()

## True when something is directly overhead: the gunship is inside a
## tunnel, a shaft or a hangar, and the altitude cap does not apply
## there. MAP.271's tunnel is flown at y ~4950 and its exit teleport
## sits at 7676 — 2 700 units up a shaft — so a cap measured against the
## floor below would seal the mission in ("exit z tunelov je vyssie ako
## ten limit"). Out under open sky the cap holds.
func _roofed(space: PhysicsDirectSpaceState3D) -> bool:
	var q := _hk_ray_query(
		global_position + Vector3(0.0, 40.0, 0.0),
		global_position + Vector3(0.0, HK_ROOF_PROBE, 0.0))
	return not space.intersect_ray(q).is_empty()

## The HK's ground and roof probes share one ray query, built on first use:
## a new query (and exclude array) every physics tick while flying was
## garbage for nothing. Bodies only, never the player's own.
var _hk_ray: PhysicsRayQueryParameters3D = null

func _hk_ray_query(from: Vector3, to: Vector3) -> PhysicsRayQueryParameters3D:
	if _hk_ray == null:
		_hk_ray = PhysicsRayQueryParameters3D.new()
		_hk_ray.collide_with_areas = false
		_hk_ray.exclude = [get_rid()]
	_hk_ray.from = from
	_hk_ray.to = to
	return _hk_ray

## RUN: the Shift key, or the on-screen / automation button.
func _sprinting() -> bool:
	return ui_sprint or Controls.is_pressed("sprint")

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

## Swimming, the body is short: a swimmer lies in the water. MAP.253's
## flooded passage runs under a sloping deck only 83-75 u over its floor;
## the standing body (76 + the 4 u margin) cannot pass it, while the DOS
## player, whose body ignores ceilings, swims straight through (found by
## --solve, 2026-09-11). Out of the water the body stands up again as
## soon as a standing body fits over its head — never inside a ceiling.
const SWIM_BODY_HEIGHT: float = 44.0
var _swim_body: bool = false

func _set_swim_body(on: bool) -> void:
	if on == _swim_body or vehicle != VEH_FOOT:
		return
	var cs: CollisionShape3D = get_node_or_null("CollisionShape3D")
	if cs == null or not (cs.shape is CapsuleShape3D):
		return
	var cap: CapsuleShape3D = cs.shape
	var h: float = SWIM_BODY_HEIGHT if on else float(VEH_CAPSULE[VEH_FOOT][1])
	if not on:
		var tall := CapsuleShape3D.new()
		tall.radius = cap.radius
		tall.height = h
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = tall
		q.transform = Transform3D(Basis(), global_position + Vector3(0.0, h * 0.5 + safe_margin, 0.0))
		q.collision_mask = collision_mask
		q.exclude = [get_rid()]
		if not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty():
			return                         # no room to stand yet: stay low
	cap.height = h
	cs.position = Vector3(0.0, h * 0.5, 0.0)
	_swim_body = on

## Feet below the surface — the swimming test.
func _water_check() -> void:
	var was_in: bool = in_water
	var was_under: bool = head_under
	in_water = global_position.y < water_level
	head_under = eye_position().y < water_level - HEAD_ROOM
	_set_swim_body(in_water)
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
	take_dos_damage(DROWN_DPS * delta, false)
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
	var base: float = walk_speed * speed_boost * class_speed
	var speed: float = base * (sprint_multiplier if _sprinting() else 1.0)
	if is_on_floor():
		var jump: bool = Controls.is_pressed("up") or ui_vert > 0.0
		if jump:
			# A run-up has to buy distance — "jump so Shiftom (behom) by
			# mal hráč skočiť ďalej", and the gaps between the roofs need
			# it. The take-off speed decides the whole arc, so the boost
			# is fixed here rather than read again in mid-air; the
			# vertical impulse is untouched (it matches the DOS jump —
			# 0x3c0000 = 60 units in a frame at 0x11bdfd — and raising it
			# would put the player on ledges the level never offers).
			_air_boost = JUMP_RUN_BOOST * clampf(
				(speed - base) / maxf(base * (sprint_multiplier - 1.0), 1.0), 0.0, 1.0)
		else:
			_air_boost = 0.0
		velocity.y = jump_speed if jump else 0.0
	else:
		speed *= 1.0 + _air_boost
		velocity.y -= gravity * delta
	velocity.x = horiz.x * speed
	velocity.z = horiz.z * speed
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
	if _sprinting():
		speed *= sprint_multiplier
	velocity = Vector3.ZERO
	if dir.length_squared() > 0.0:
		global_position += dir.normalized() * speed * _delta

## Where a shot leaves, as DOS computes it (FUN_00125caf, 0x125d45-0x125da0):
## the record's offset `off` (x right, y DOWN, z ahead — MUZZLE) with
## MUZZLE_AHEAD added to z, plus the distance the player covers this frame
## (0x38c08 x dt: the walking / flying speed; the jeep keeps its speed
## elsewhere), turned by the view matrix and added to the eye. `side`
## flips x — a vehicle's barrels take turns.
func _muzzle_point(off: Vector3, side: float = 1.0) -> Vector3:
	var b: Basis = _cam.global_transform.basis
	var lead: float = 0.0
	if vehicle != VEH_JEEP:
		lead = maxf(velocity.dot(-b.z), 0.0) * get_physics_process_delta_time()
	# DOS y is down and z ahead; the camera's own y is up and z behind.
	return _cam.global_position + b.x * (off.x * side) - b.y * off.y \
		- b.z * (MUZZLE_AHEAD + off.z + lead)

## MUZZLE entry for weapon slot `idx`: the offset, and the aim bit.
func _muzzle_offset(idx: int) -> Vector3:
	return MUZZLE[idx][0] if idx >= 0 and idx < MUZZLE.size() else Vector3.ZERO

func _muzzle_aimed(idx: int) -> bool:
	return bool(MUZZLE[idx][1]) if idx >= 0 and idx < MUZZLE.size() else true

## Which barrel a vehicle gun fires next: weapon slot -> +1 / -1. DOS
## negates the record's +0x30 after every shot in a vehicle (0x125e5e).
var _barrel_side: Dictionary = {}

## How far down the aim ray to look for the thing the crosshair is on.
const AIM_REACH: float = 20000.0
## A picked point less than this far ahead of the muzzle (or behind it —
## the crosshair on a wall the muzzle already reaches past) is not aimed at.
const AIM_MIN_AHEAD: float = 1.0

## The direction a shot from `muzzle` flies. DOS picks the pixel under the
## crosshair every frame and keeps its 3D point (0x14413); a weapon with
## the aim bit flies from its muzzle AT that point, so an offset barrel
## still lands on the crosshair. With nothing under the crosshair (sky),
## or without the aim bit, the shot flies along the view (0x1448d).
func _shot_dir(muzzle: Vector3, fwd: Vector3, aimed: bool) -> Vector3:
	if not aimed:
		return fwd
	var space := get_world_3d().direct_space_state
	if space == null:
		return fwd
	var from: Vector3 = _cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from + fwd * AIM_REACH)
	q.collide_with_areas = true
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.has("position"):
		return fwd
	var to: Vector3 = (hit["position"] as Vector3) - muzzle
	if to.dot(fwd) < AIM_MIN_AHEAD:
		return fwd
	return to.normalized()

## Where the flare and the shotgun smoke go for a gun whose DOS shot
## leaves from the eye: by the gun art in the lower right (MUZZLE's
## convention — right, down, ahead less MUZZLE_AHEAD).
const FLASH_AT_GUN: Vector3 = Vector3(15.0, 12.0, 40.0)

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
	if kind == "detector":
		return                               # a scanner has no trigger
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
	# Where the shot comes FROM and which way it flies — DOS's own numbers
	# (MUZZLE, FUN_00125caf). The port used one guessed muzzle for every
	# gun, 60 ahead / 15 right / 12 down, and aimed it at a crosshair drawn
	# in the middle of the window, below the view's real centre: the gun
	# art pointed above the crosshair and the bolts and tracers ran below
	# it (playtest 2026-09-15). Now the crosshair is on the projection
	# centre, the bullet guns fire from the eye (their DOS offset is 0,0,0)
	# and the offset guns fly at the point under the crosshair. `fwd` stays
	# the aim direction: the hitscan ray is cast from the eye along it.
	var off: Vector3 = _muzzle_offset(idx)
	var side: float = float(_barrel_side.get(idx, 1.0))
	var muzzle: Vector3 = _muzzle_point(off, side)
	# From the eye's own axis the picked point lies straight along the view.
	var shot: Vector3 = fwd if off == Vector3.ZERO else _shot_dir(muzzle, fwd, _muzzle_aimed(idx))
	if vehicle != VEH_FOOT:
		_barrel_side[idx] = -side               # the other barrel next time
	var dmg: float = float(w["dmg"])
	# Deathmatch: everybody else draws this shot.
	if Net.active:
		Net.send_fire(idx, muzzle, shot)
	# The DOS moon joke (FUN_00125caf): any weapon fired with the
	# crosshair on the moon makes it complain.
	if kind != "melee":
		var sc: Node = get_tree().current_scene
		if sc != null and sc.has_method("moon_aimed") and sc.call("moon_aimed", fwd):
			sc.call("moon_shot")

	# Melee: short-range hitscan, no tracer, no muzzle flash. The
	# viewmodel swing animation (CFA frames) is the only visible cue.
	if kind == "melee":
		# Melee reaches from the eye, not from the gun corner.
		_melee_hit(_cam.global_position + fwd * 40.0, fwd, dmg)
		return

	var tint: Color = _KIND_COLOR.get(kind, Color.WHITE)

	# Muzzle flash for every projectile shot: the TEXTURE.219 sprite tinted
	# to the family colour so plasma flares blue, lasers red, bullets warm
	# white. (FUN_00126080, which the fire routine calls, only turns the
	# record's +0x20 into a vector at 0x38f5b — the flare is the port's.)
	# TEXTURE.219 is a 17x17 px sprite; from 90 u a 36 u sprite filled a
	# third of the screen, so it sits further out and smaller (a 2026-09-02
	# report). A gun that fires from the eye would put it right on the
	# crosshair, so for those it stays at the gun in the corner.
	# Pooled, like the tracer and the impact puff below: a node per shot
	# was a new sprite (and light) at the weapon's fire rate.
	var fx_parent: Node = get_tree().current_scene
	var at_gun: Vector3 = muzzle if off != Vector3.ZERO else _muzzle_point(FLASH_AT_GUN)
	MuzzleFlash.spawn(fx_parent, at_gun + shot * 70.0, tint, 26.0 if kind == "shotgun" else 18.0)

	# Ballistic / straight projectiles take a separate path.
	if kind == "grenade":
		var g := Grenade.new()
		fx_parent.add_child(g)
		g.setup(muzzle, shot, dmg, float(w.get("splash", 256.0)), self)
		return
	if kind == "rocket" or kind == "laser" or kind == "plasma":
		var proj: Node3D = Projectile.new()
		fx_parent.add_child(proj)
		proj.setup(muzzle, shot, dmg, _projectile_cfg(kind, w), self)
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
		var beam_from: Vector3 = muzzle + shot * TRACER_START
		# Stop it well before the horizon. A ray that hits nothing ends
		# 60,000 units out, and a 6-unit box that long, drawn additive,
		# is a huge glowing wedge across the view — "the shots render as
		# if they were flying in from the side" (2026-09-04).
		var beam_to: Vector3 = beam_from
		var reach: float = minf(beam_from.distance_to(endpoint), TRACER_MAX)
		beam_to = beam_from + (endpoint - beam_from).normalized() * reach
		if reach > 120.0:
			Tracer.spawn(fx_parent, beam_from, beam_to, Color(1.0, 0.86, 0.55, 0.5), 2.0)
	# Shotgun: a puff of smoke lingering at the gun.
	if kind == "shotgun":
		var sm := SmokePuff.new()
		fx_parent.add_child(sm)
		sm.setup(at_gun + fwd * 30.0, 180.0)
	if hit.has("collider"):
		var n: Node = hit["collider"] as Node
		while n != null and not n.has_method("take_damage"):
			n = n.get_parent()
		if n != null and n != self:
			_deal(n, dmg)
		else:
			Explosion.spawn(fx_parent, endpoint, 40.0, IMPACT_BANK_BULLET)

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
				"trail": true, "impact_bank": 363,
				"impact_sound": "EXPLO3.RAW", "hits": "enemy"}
		# The bolt colours come from the models' own 1x1 textures, not from
		# a guess (Projectile.BOLT_COLOURS): LASER1 cyan, LASER2 green.
		# The jeep's plasma is ammo type 18 = laser2.3d, so it is GREEN —
		# the port drew it blue ("s tým laserom v jeepe", 2026-09-11).
		"laser":
			return {"model": "LASER1.3D", "color": Projectile.colour_for("LASER1.3D"),
				"speed": 9000.0, "life": 1.2, "splash": 0.0,
				"impact_bank": 364, "hits": "enemy"}
		"plasma":
			return {"model": "LASER2.3D", "color": Projectile.colour_for("LASER2.3D"),
				"speed": 4000.0, "life": 1.2, "splash": 0.0,
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
	var fwd: Vector3 = aim_dir()
	var muzzle: Vector3 = _muzzle_point(THROW_MUZZLE)   # the left hand
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
## Every press of the use key, whatever is under the crosshair — DOS
## fires the 0xEF gates in reach on the key itself (ActionSystem.press_use).
signal activate_key(pos: Vector3)

func _try_activate() -> void:
	activate_key.emit(global_position)
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

## Where the DOS engine has the player when it measures a distance to him
## (a robot's death blast, 0x12457f): the eye on foot and in the HK, the
## middle of the car in the jeep, 70 u over the wheels (0x1359e1).
const JEEP_CENTRE_HEIGHT: float = 70.0

func dos_point() -> Vector3:
	if vehicle == VEH_JEEP or _cam == null:
		return global_position + Vector3(0.0, JEEP_CENTRE_HEIGHT if vehicle == VEH_JEEP else 75.0, 0.0)
	return _cam.global_position

## The DOS soldier has 1000 damage points (0x121e48: max 0x3e800 in 8.8),
## and every damage value in the DOS tables — an ammo record's 10..100, a
## blast's strength, the 85 a second of drowning — is subtracted from
## THAT (0x122652: loss = D x 256 with no armour). The port's bar is
## max_health; a DOS value is worth max_health / 1000 of it. Until
## 2026-09-15 the raw table values came off the 100-point bar: every
## enemy shot hurt ten times as much as in the original (a 10-damage
## bullet took 10 % instead of 1 %).
const DOS_HEALTH_POINTS: float = 1000.0
## Armour (0x12268a): a hit of D points costs 82/65536 of the armour bar
## per point — full armour is used up by 800 points — and the armour that
## is left after the hit keeps that fraction of it off the soldier.
const ARMOR_COST_PER_POINT: float = 82.0 / 65536.0
## In a vehicle (0x130c4a) the soldier is not hurt at all: the hull takes
## every hit, 1:1, from its own pool (0x130caa; 1000 for the jeep, and the
## flag that picks 1500 is not decoded — both take 1000 here), and the
## ARMOR bar shows the hull (0x13231d). At zero the ride is over.
const VEH_HULL_POINTS: float = 1000.0
var veh_hull: float = VEH_HULL_POINTS

## Damage in DOS points (see DOS_HEALTH_POINTS): what the DOS tables and
## formulas say, straight. `scaled` = a direct weapon hit (DIFFICULTY
## applies, 0x1230d6); blasts, contact, falls, drowning pass false.
func take_dos_damage(points: float, scaled: bool = true) -> void:
	take_damage(points * max_health / DOS_HEALTH_POINTS, scaled)

## Take `amount` of the port's own bar (max_health). On death the player
## just dies — the level controller shows a game-over screen and calls
## respawn(). `scaled` applies the DIFFICULTY multiplier
## (Settings.dmg_to_player); DOS scales weapon damage in the
## projectile-impact path only, so radiation and other environmental
## damage pass false.
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
		if not scaled:
			# Radiation and drowning arrive as a sliver every frame, and a
			# reliable report each was a flood to the host: they are summed
			# and sent by _flush_env_damage, the same total in far fewer hits.
			_net_env_dmg += amount
			return
		Net.hit(Net.local_id, amount, Net.local_id, _weapon_idx)
		return
	var points: float = amount * DOS_HEALTH_POINTS / max_health
	if vehicle != VEH_FOOT:
		veh_hull = maxf(veh_hull - points, 0.0)
		hurt.emit(amount)
		Audio.play_sfx("HIT2.RAW", -3.0)
		if veh_hull <= 0.0:
			health = 0.0
			Audio.play_sfx("EXPLO2.RAW", -2.0)
			_capture(false)
		return
	if armor > 0.0:
		armor = maxf(armor - ARMOR_COST_PER_POINT * points, 0.0)
		amount *= 1.0 - armor
	# DOS takes at least 1/256 of a point; the port's bar is float.
	health -= amount
	hurt.emit(amount)
	Audio.play_sfx("HIT2.RAW", -3.0)
	if health <= 0.0:
		health = 0.0
		Audio.play_sfx("EXPLO2.RAW", -2.0)
		_capture(false)                          # release the mouse

## What the HUD's ARMOR bar shows: the armour on foot, the hull in a
## vehicle (DOS 0x13231d), both 0..1.
func armor_gauge() -> float:
	if vehicle != VEH_FOOT:
		return clampf(veh_hull / VEH_HULL_POINTS, 0.0, 1.0)
	return clampf(armor, 0.0, 1.0)

## Network game: environmental damage (take_damage with `scaled` false)
## waiting to be reported, and how long it has waited. At most one report
## per NET_ENV_SEND_INTERVAL; whatever is left goes out once it is due.
const NET_ENV_SEND_INTERVAL: float = 0.1
var _net_env_dmg: float = 0.0
var _net_env_t: float = 0.0

func _flush_env_damage(delta: float) -> void:
	if _net_env_dmg <= 0.0:
		return
	if not Net.active:
		_net_env_dmg = 0.0                       # the game it was owed to is gone
		_net_env_t = 0.0
		return
	_net_env_t += delta
	if _net_env_t < NET_ENV_SEND_INTERVAL:
		return
	var amount: float = _net_env_dmg
	_net_env_dmg = 0.0
	_net_env_t = 0.0
	Net.hit(Net.local_id, amount, Net.local_id, _weapon_idx)

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

## How far the viewmodel is allowed to sink behind the HUD bar, in DOS
## pixels — the grip and the hands read better tucked slightly under it.
const HUD_OVERLAP: float = 14.0

## Build the first-person weapon viewmodel overlay and load each weapon's
## .CFA animation frames.
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
	var hires: bool = bool(Settings.hires_weapons)
	_vm_hires.clear()
	for i in _weapons.size():
		var cfa: String = String(_weapons[i].get("cfa", ""))
		if cfa.is_empty():
			continue
		var frames: Array = Assets.cfa_frames(cfa, hires)
		if frames.is_empty():
			continue
		_vm_cache[i] = frames
		# The 640x480 art is twice the DOS pixels, so it draws at half
		# the scale (see _layout_viewmodel) — otherwise the gun doubles
		# in size. A weapon the hi-res set lacks falls back on its own.
		# WHICH SET the frames came from decides the scale, and only the
		# file's own layout says that — not its width: the 640x480
		# WEAPON13 is 145x194, narrower than several 320x200 viewmodels.
		_vm_hires[i] = hires and Assets.cfa_is_hires(cfa)
		_vm_off[i] = Assets.cfa_offset(cfa) if bool(_vm_hires[i]) else Vector2i.ZERO
		_vm_lo[i] = Assets.cfa_lo_size(cfa) if bool(_vm_hires[i]) else Vector2i.ZERO
		print("[weapon] %s — %d viewmodel frames%s"
			% [cfa, frames.size(), " (hi-res)" if _vm_hires.get(i, false) else ""])

## The one-shot actions that can sit on a key OR a mouse button. True
## when the event was one of them.
func _act_on(event: InputEvent) -> bool:
	if Controls.matches(event, "fire"):
		_shoot()
		return true
	if Controls.matches(event, "throw"):
		_throw_secondary()
		return true
	if Controls.matches(event, "activate"):
		_try_activate()
		return true
	return false

## No viewmodel frames — one shared empty list, not a new one each frame.
const NO_FRAMES: Array = []

## Advance the viewmodel animation and keep it pinned bottom-centre.
func _process(delta: float) -> void:
	_update_projection()
	_step_death_view(delta)
	if _viewmodel == null:
		return
	var frames: Array = _vm_cache.get(_weapon_idx, NO_FRAMES) if vehicle == VEH_FOOT else NO_FRAMES
	# A corpse holds no gun.
	_viewmodel.visible = not frames.is_empty() and _death_t < 0.0
	if frames.is_empty():
		_vm_firing = false
		return
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

## --- the death view ---------------------------------------------------
## In a deathmatch the message said YOU DIED and the body went on
## standing: "asi by som ho zviezol k zemy a aj pohlad nech ide na chvilu
## k zemi kym sa respawne" (playtest 2026-09-12). The DOS original is no
## guide — it wipes the screen — so this is the plain reading of it: the
## eye sinks from 75 to the floor and the head tips over, then holds
## there until the server respawns you. dm_game drives it.
const DEATH_EYE: float = 14.0
const DEATH_FALL: float = 0.5             # seconds to go down
const DEATH_ROLL: float = 0.35            # radians the head tips
const DEATH_PITCH: float = -0.22          # and looks along the ground
var _death_t: float = -1.0                # -1 = alive

func begin_death_view() -> void:
	if _death_t < 0.0:
		_death_t = 0.0

func end_death_view() -> void:
	if _death_t < 0.0:
		return
	_death_t = -1.0
	if _cam != null:
		_cam.position.y = float(VEH_EYE[VEH_FOOT])
		_cam.rotation = Vector3(_pitch, 0.0, 0.0)

func _step_death_view(delta: float) -> void:
	if _death_t < 0.0 or _cam == null:
		return
	_death_t = minf(_death_t + delta, DEATH_FALL)
	var k: float = ease(_death_t / DEATH_FALL, 0.45)   # drops fast, settles
	_cam.position.y = lerpf(float(VEH_EYE[VEH_FOOT]), DEATH_EYE, k)
	_cam.rotation.x = lerpf(_pitch, DEATH_PITCH, k)
	_cam.rotation.z = DEATH_ROLL * k

## How much of the window bottom the HUD bar takes — the scene knows the
## panel's scaled height.
func _hud_height(vp: Vector2) -> float:
	var sc: Node = get_tree().current_scene
	if sc != null and sc.has_method("hud_height"):
		return float(sc.call("hud_height"))
	return clampf(vp.x / 8.0, 64.0, 160.0)

## --- the view's centre ------------------------------------------------
## DOS renders the world into a 320x160 view above the 40-line panel and
## projects it round the middle of THAT view, (160, 80) — 40 % down the
## screen (FUN_0014f6d0) — and the reticle is drawn exactly there. The
## port's camera fills the whole window with the HUD bar laid over its
## bottom, so its centre sat at 50 %, under the art: the viewmodels,
## drawn for a centre at 40 %, pointed above the crosshair (playtest
## 2026-09-15). The camera's frustum is shifted instead — same vertical
## field (the `fov` of the scene), same aspect, same window — so its axis
## lands in the middle of the part of the window the HUD leaves free.
## Checked every frame (a resize, or the HUD bar shown or hidden, moves
## it); the camera is only touched when something changed.
var _proj_key: Array = []

func _update_projection() -> void:
	if _cam == null or not is_inside_tree():
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if vp.y < 1.0:
		return
	var hud_h: float = clampf(_hud_height(vp), 0.0, vp.y * 0.5)
	var key: Array = [vp, hud_h, _cam.fov, _cam.near]
	if key == _proj_key and _cam.projection == Camera3D.PROJECTION_FRUSTUM:
		return
	_proj_key = key
	# A frustum camera's `size` is the height of its near plane, and the
	# offset moves that plane in the same units: half the HUD in pixels,
	# as a fraction of the window height, times the plane's height. The
	# plane moves DOWN, so the axis sits above the window's middle.
	var plane_h: float = 2.0 * _cam.near * tan(deg_to_rad(_cam.fov) * 0.5)
	_cam.projection = Camera3D.PROJECTION_FRUSTUM
	_cam.size = plane_h
	_cam.frustum_offset = Vector2(0.0, -(hud_h * 0.5) / vp.y * plane_h)

## Where the crosshair goes, in viewport pixels: the projection centre —
## the middle of the window above the HUD bar (crosshair.gd draws there).
func aim_screen_point() -> Vector2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	return Vector2(vp.x * 0.5, (vp.y - clampf(_hud_height(vp), 0.0, vp.y * 0.5)) * 0.5)

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
	# The 640x480 art is NOT a doubled copy of the 320x200 one: DOS's
	# 320x200 mode has TALL pixels and the hi-res art is drawn square, so
	# the same gun is twice as wide but 2.4x as tall (measured on
	# WEAPON00: 151x60 against 302x144). Two attempts at deriving the
	# placement from the hi-res art itself both came out wrong — half
	# scale left the gun a fifth too tall, and its header's own x/y is a
	# screen position for WEAPON00 but not for WEAPON04 — so this stops
	# deriving anything: the hi-res frame is scaled into EXACTLY the
	# rectangle the 320x200 frame would occupy, which is the placement the
	# port has always had right. Same picture, four times the pixels.
	var hires: bool = bool(_vm_hires.get(_weapon_idx, false))
	var lo: Vector2i = _vm_lo.get(_weapon_idx, Vector2i.ZERO)
	var draw := Vector2(ts.x * s, ts.y * s)          # what the 320 art draws
	if hires and lo.x > 0 and lo.y > 0:
		draw = Vector2(float(lo.x) * s, float(lo.y) * s)
	var x: float = x_origin + vx * s
	_viewmodel.scale = Vector2(draw.x / maxf(ts.x, 1.0), draw.y / maxf(ts.y, 1.0))
	# The gun stands ON the HUD bar, not behind it. DOS draws the world
	# in a 320x160 viewport with the 40 px panel below; the port's panel
	# is the same art scaled by WIDTH (main._layout_hud), so its top edge
	# is where the weapon's bottom belongs. Anchoring to the window
	# bottom (as this did) hid all but the muzzle behind the panel.
	# The gun's own content is flush with the bottom of its frame in both
	# sets (measured), so standing the FRAME on the bar stands the gun on
	# it either way.
	var hud_h: float = _hud_height(vp)
	_viewmodel.position = Vector2(x, vp.y - hud_h - draw.y + HUD_OVERLAP * s)
