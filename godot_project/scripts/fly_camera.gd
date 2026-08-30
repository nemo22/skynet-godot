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
@export var jump_speed: float = 1800.0
@export var mouse_sensitivity: float = 0.003
@export var touch_look_speed: float = 2.2

const Tracer := preload("res://scripts/tracer.gd")
const Projectile := preload("res://scripts/projectile.gd")
const Grenade := preload("res://scripts/grenade.gd")
const MuzzleFlash := preload("res://scripts/muzzle_flash.gd")
const SmokePuff := preload("res://scripts/smoke_puff.gd")
const CFAFile := preload("res://scripts/loaders/cfa_file.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const Palette := preload("res://scripts/loaders/palette.gd")
const Explosion := preload("res://scripts/explosion.gd")

@onready var _cam: Camera3D = $Camera3D

var _yaw: float = 0.0
var _pitch: float = 0.0
var _captured: bool = false
var _mobile: bool = OS.has_feature("mobile")
## Debug: when true, gravity/collision are off (fly through everything).
var noclip: bool = false
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
	{"name": "MINI ROCKET",      "kind": "bullet",  "dmg": 50.0,  "rate": 20, "pool": 12, "cost": 1,  "snd": "SHOTS2.RAW",   "sel": 9,  "dry": 10, "cfa": "WEAPON12.CFA", "animspd": 16, "vx": 156},
]
var _weapon_idx: int = 0
# HUD mirrors of the active weapon (read by the level controller).
var weapon_name: String = "UZI"
var ammo: int = 500

## Shot delay = FIRE_RATE_SCALE / rate (see the table notes above).
const FIRE_RATE_SCALE: float = 0.5
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
#   12 mini-rkt 9999/9999 MINI ROCKET ×1 (the only unlimited one)
# DOS starts grenades and rockets at 0 — they come only from pickups,
# whose weapon/ammo types (TEXTURE.200/201 records) are not decoded
# yet — so a handful is seeded here to keep the launchers usable.
const POOL_TABLE: Dictionary = {
	0: [500, 750], 1: [50, 200], 2: [10, 99], 3: [5, 99],
	4: [500, 800], 12: [9999, 9999],
}
## Rounds a generic ammo pickup adds per pool (placeholder until the
## pickup sprite records are decoded into specific ammo types).
const PICKUP_AMMO: Dictionary = {0: 50, 1: 10, 2: 5, 3: 2, 4: 50}
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
	safe_margin = 6.0
	wall_min_slide_angle = 0.0
	_yaw = rotation.y
	if _cam != null:
		_pitch = _cam.rotation.x
	_reset_pools()
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
		_reset_pools()
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

## Switch to weapon `idx` (clamped). Plays the record's select sound
## (+0x54: uzicock3 for ballistic, ppcload for energy weapons).
func _select_weapon(idx: int) -> void:
	idx = clampi(idx, 0, _weapons.size() - 1)
	if idx == _weapon_idx:
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
					_throw_grenade()
			MOUSE_BUTTON_WHEEL_UP:
				_select_weapon((_weapon_idx - 1 + _weapons.size()) % _weapons.size())
			MOUSE_BUTTON_WHEEL_DOWN:
				_select_weapon((_weapon_idx + 1) % _weapons.size())
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_capture(false)
		elif event.keycode == int(Controls.binds.get("activate", KEY_F)):
			_try_activate()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_select_weapon(event.keycode - KEY_1)
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

	# --- weapon -------------------------------------------------------
	if _fire_cd > 0.0:
		_fire_cd -= delta
	if ui_fire:
		ui_fire = false
		_shoot()
	elif _captured and not _mobile \
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_shoot()                          # held trigger — DOS auto-fire

	# --- movement input (horizontal intent) ---------------------------
	var fwd_in: float = 0.0
	var str_in: float = 0.0
	if Controls.is_pressed("forward") or Input.is_key_pressed(KEY_UP):    fwd_in += 1.0
	if Controls.is_pressed("back")    or Input.is_key_pressed(KEY_DOWN):  fwd_in -= 1.0
	if Controls.is_pressed("right")   or Input.is_key_pressed(KEY_RIGHT): str_in += 1.0
	if Controls.is_pressed("left")    or Input.is_key_pressed(KEY_LEFT):  str_in -= 1.0
	fwd_in += ui_move.y
	str_in += ui_move.x

	if noclip:
		_fly(delta, fwd_in, str_in)
	else:
		_walk(delta, fwd_in, str_in)

## Grounded movement: walk on surfaces, gravity, jump, wall collision.
func _walk(delta: float, fwd_in: float, str_in: float) -> void:
	var basis_y := Basis(Vector3.UP, _yaw)
	var horiz := -basis_y.z * fwd_in + basis_y.x * str_in
	if horiz.length() > 1.0:
		horiz = horiz.normalized()
	var speed := walk_speed
	if Controls.is_pressed("sprint"):
		speed *= sprint_multiplier
	velocity.x = horiz.x * speed
	velocity.z = horiz.z * speed

	if is_on_floor():
		var jump := Input.is_key_pressed(KEY_SPACE) \
			or Controls.is_pressed("up") or ui_vert > 0.0
		velocity.y = jump_speed if jump else 0.0
	else:
		velocity.y -= gravity * delta
	move_and_slide()

## Debug noclip: free 6-DOF flight along the camera look direction.
func _fly(_delta: float, fwd_in: float, str_in: float) -> void:
	var look := global_transform.basis
	if _cam != null:
		look = _cam.global_transform.basis
	var vert: float = ui_vert
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) \
			or Controls.is_pressed("up"):
		vert += 1.0
	if Input.is_key_pressed(KEY_Q) or Controls.is_pressed("down"):
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
func _shoot() -> void:
	if _fire_cd > 0.0 or health <= 0.0 or _cam == null:
		return
	var w: Dictionary = _weapons[_weapon_idx]
	var kind: String = String(w.get("kind", "bullet"))
	var pool: int = int(w.get("pool", -1))
	var cost: int = int(w.get("cost", 0))
	if pool >= 0 and int(_pools.get(pool, 0)) < cost:
		_fire_cd = DRY_FIRE_DELAY
		Audio.play_id(int(w.get("dry", -1)), -6.0)
		return
	_fire_cd = maxf(FIRE_RATE_SCALE / float(w.get("rate", 4)), 0.05)
	if pool >= 0:
		_pools[pool] = int(_pools[pool]) - cost
		ammo = int(_pools[pool])
	var snd: String = String(w.get("snd", ""))
	if not snd.is_empty():
		Audio.play_sfx(snd, -5.0)
	# Kick off the viewmodel fire animation.
	_vm_firing = true
	_vm_idx = 0
	_vm_t = 0.0

	var fwd: Vector3 = -_cam.global_transform.basis.z
	var muzzle: Vector3 = _cam.global_position + fwd * 90.0 \
		- _cam.global_transform.basis.y * 26.0
	var dmg: float = float(w["dmg"])

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
	mf.setup(muzzle, tint, 130.0 if kind == "shotgun" else 100.0)

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
	var tr: MeshInstance3D = Tracer.new()
	get_tree().current_scene.add_child(tr)
	tr.setup(muzzle, endpoint, tint)
	# Shotgun: a smoke puff lingering at the muzzle after the shot.
	if kind == "shotgun":
		var sm := SmokePuff.new()
		get_tree().current_scene.add_child(sm)
		sm.setup(muzzle + fwd * 30.0, 180.0)
	if hit.has("collider"):
		var n: Node = hit["collider"] as Node
		while n != null and not n.has_method("take_damage"):
			n = n.get_parent()
		if n != null and n != self:
			n.take_damage(dmg)
		else:
			var puff := Explosion.new()
			get_tree().current_scene.add_child(puff)
			puff.setup(endpoint, 40.0, IMPACT_BANK_BULLET)

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

## Quick hand-grenade throw (right mouse button). Consumes one round
## from the grenade pool and lobs a Grenade projectile in an upward arc
## without switching weapons. No dedicated viewmodel animation yet — the
## throw is silent hands-off, like a quick-use key.
func _throw_grenade() -> void:
	if health <= 0.0 or _cam == null or _fire_cd > 0.0:
		return
	if int(_pools.get(2, 0)) <= 0:
		return
	_pools[2] = int(_pools[2]) - 1
	_sync_hud()
	_fire_cd = 0.6
	var fwd: Vector3 = -_cam.global_transform.basis.z
	var muzzle: Vector3 = _cam.global_position + fwd * 60.0
	var arc: Vector3 = (fwd + Vector3.UP * 0.35).normalized()
	var g := Grenade.new()
	get_tree().current_scene.add_child(g)
	g.setup(muzzle, arc, 200.0, 256.0, self)

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
		n.take_damage(dmg)

## Activate action (Controls "activate", default F): operate the door or
## switch the player is looking at within reach. Ray-walks parents for an
## `activate()` method. Hits Area3D so wall-mounted switches register
## (their hitbox is an Area3D, like enemies); the parent-walk filter
## ignores anything without `activate()` so enemy hitboxes are inert.
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
		return
	var n: Node = hit["collider"] as Node
	while n != null and not n.has_method("activate"):
		n = n.get_parent()
	if n != null:
		n.activate()

## Take damage from an enemy shot. On death the player just dies — the
## level controller shows a game-over screen and calls respawn().
func take_damage(amount: float) -> void:
	if health <= 0.0:
		return
	if god_mode:
		return                                   # debug invincibility
	health -= amount
	Audio.play_sfx("HIT2.RAW", -3.0)
	if health <= 0.0:
		health = 0.0
		Audio.play_sfx("EXPLO2.RAW", -2.0)
		_capture(false)                          # release the mouse

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

func _capture(on: bool) -> void:
	_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE

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
	var frames: Array = _vm_cache.get(_weapon_idx, [])
	if frames.is_empty():
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
	_viewmodel.position = Vector2(
		x_origin + vx * s, vp.y - ts.y * s)
