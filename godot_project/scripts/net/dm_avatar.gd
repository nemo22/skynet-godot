## A deathmatch actor as seen by OTHER peers: every remote player and
## every bot is one of these — a T800RFL endoskeleton (the DOS MP body)
## on a player-sized capsule, walking / firing / dying through the
## fan-port frame ranges (enemy_anim.gd T800_FAMILY).
##
## Two drive modes:
##   * replicated (default): main peers feed `apply_pose()` and the body
##     glides toward it — no physics of its own
##   * local (bots on the server): a BotBrain child moves it with
##     move_and_slide like the player, and this node reports poses
##
## Shots register on the capsule body itself: hitscan and projectiles
## walk up to `net_damage()`, which reports the hit to the server.
extends CharacterBody3D

const EnemyAnim := preload("res://scripts/enemy_anim.gd")
const Explosion := preload("res://scripts/explosion.gd")
const Debris := preload("res://scripts/debris.gd")

const MODEL: String = "T800RFL.3D"
const CAPSULE_RADIUS: float = 26.0
const CAPSULE_HEIGHT: float = 88.0
const EYE_HEIGHT: float = 75.0
const LERP_RATE: float = 14.0
const HIDE_AFTER_DEATH: float = 2.5

var net_id: int = -1
var display_name: String = ""
var local_drive: bool = false
var alive: bool = true
## Yaw/pitch the owner reported (bots write these directly).
var yaw: float = 0.0
var pitch: float = 0.0
var flags: int = 0

var _mesh: MeshInstance3D = null
var _frames: Array = []
var _anim: Dictionary = {}
var _clip: String = ""
var _clip_t: float = 0.0
var _clip_i: int = 0
var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _target_pitch: float = 0.0
var _has_target: bool = false
var _death_t: float = 0.0
var _shape: CollisionShape3D = null
var _foot: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _moving_t: float = 0.0

func setup(id: int, name_text: String, local: bool) -> void:
	net_id = id
	display_name = name_text
	local_drive = local
	name = "dm_%d" % id
	add_to_group("dm_actor")
	collision_layer = 1
	collision_mask = 1
	floor_max_angle = deg_to_rad(62.0)
	floor_snap_length = 150.0
	safe_margin = 6.0
	wall_min_slide_angle = 0.0
	_shape = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = CAPSULE_RADIUS
	cap.height = CAPSULE_HEIGHT
	_shape.shape = cap
	_shape.position = Vector3(0.0, CAPSULE_HEIGHT * 0.5, 0.0)
	add_child(_shape)

	_frames = Assets.mesh_frames(MODEL)
	_mesh = MeshInstance3D.new()
	if not _frames.is_empty():
		_foot = (_frames[0] as ArrayMesh).get_aabb().position.y
		for f in _frames:
			if f is ArrayMesh:
				_foot = minf(_foot, (f as ArrayMesh).get_aabb().position.y)
		_mesh.mesh = _frames[1] if _frames.size() > 1 else _frames[0]
	else:
		var cm := CapsuleMesh.new()
		cm.radius = CAPSULE_RADIUS
		cm.height = CAPSULE_HEIGHT
		_mesh.mesh = cm
		_foot = -CAPSULE_HEIGHT * 0.5
	_mesh.position = Vector3(0.0, -_foot, 0.0)
	add_child(_mesh)
	_anim = EnemyAnim.table_for("t800rfl")

	# No name tag over the head: it would give the body away across the
	# map. Terminators read names through their machine vision instead.
	_play("idle")

func set_display_name(n: String) -> void:
	display_name = n

## HUMAN players wear an olive tint over the endoskeleton (the data has
## no human body model); TERMINATORs are the bare chrome machine.
var cls: int = 0
func set_class(c: int) -> void:
	cls = c
	if _mesh == null:
		return
	if c == Net.CLASS_HUMAN:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.45, 0.42, 0.22, 0.55)
		_mesh.material_overlay = m
	else:
		_mesh.material_overlay = null

## In a vehicle the avatar IS the vehicle: the HUMMER / HK_FTR model
## replaces the endoskeleton and the capsule grows to the hull.
var vehicle: int = 0
var _veh_mesh: MeshInstance3D = null
var _engine: AudioStreamPlayer3D = null
const VEH_MODELS: Array = ["", "HUMMER.3D", "HK_FTR.3D"]
func set_vehicle(v: int) -> void:
	v = clampi(v, 0, 2)
	if v == vehicle:
		return
	vehicle = v
	if _veh_mesh != null:
		_veh_mesh.queue_free()
		_veh_mesh = null
	if _mesh != null:
		_mesh.visible = v == 0
	# Engine loop others hear: careng1 (jeep) / hk2 (HK).
	if _engine != null:
		_engine.queue_free()
		_engine = null
	if v != 0:
		_engine = Audio.attach_loop_3d(69 if v == 1 else 48, self, -8.0)
	var cap: CapsuleShape3D = (_shape.shape as CapsuleShape3D) if _shape != null else null
	if v == 0:
		if cap != null:
			cap.radius = CAPSULE_RADIUS
			cap.height = CAPSULE_HEIGHT
			_shape.position = Vector3(0.0, CAPSULE_HEIGHT * 0.5, 0.0)
		return
	var am: ArrayMesh = Assets.mesh(VEH_MODELS[v])
	_veh_mesh = MeshInstance3D.new()
	if am != null:
		_veh_mesh.mesh = am
		_veh_mesh.position = Vector3(0.0, -am.get_aabb().position.y, 0.0)
	else:
		var bm := BoxMesh.new()
		bm.size = Vector3(106, 75, 227) if v == 1 else Vector3(357, 205, 501)
		_veh_mesh.mesh = bm
		_veh_mesh.position = Vector3(0.0, bm.size.y * 0.5, 0.0)
	add_child(_veh_mesh)
	if cap != null:
		cap.radius = 55.0 if v == 1 else 110.0
		cap.height = 110.0 if v == 1 else 220.0
		_shape.position = Vector3(0.0, cap.height * 0.5, 0.0)

## Eye position (bots aim and see from here).
func eye() -> Vector3:
	return global_position + Vector3(0.0, EYE_HEIGHT, 0.0)

## A replicated pose from the owner.
func apply_pose(pos: Vector3, y: float, p: float, f: int) -> void:
	_target_pos = pos
	_target_yaw = y
	_target_pitch = p
	flags = f
	if not _has_target:
		_has_target = true
		global_position = pos
		rotation.y = y
		yaw = y
	if (f & 2) != 0 and alive:
		_play("attack", true)

## Server put this actor back in the arena.
func spawn_at(pos: Vector3, y: float) -> void:
	alive = true
	visible = true
	_death_t = 0.0
	global_position = pos
	_target_pos = pos
	_has_target = true
	yaw = y
	_target_yaw = y
	rotation.y = y
	velocity = Vector3.ZERO
	flags = 0
	if _shape != null:
		_shape.disabled = false
	_play("idle")

## Death: the fall animation, then the body fades out of the arena.
func die() -> void:
	if not alive:
		return
	alive = false
	_death_t = 0.0
	velocity = Vector3.ZERO
	if _shape != null:
		_shape.set_deferred("disabled", true)
	_play("death", true)
	Audio.play_sfx_3d("EXPLO2.RAW", global_position + Vector3(0.0, 40.0, 0.0), -4.0)
	var scene := get_tree().current_scene
	if scene != null:
		var ex := Explosion.new()
		scene.add_child(ex)
		ex.setup(global_position + Vector3(0.0, 50.0, 0.0), 90.0)
		for _i in 3:
			var d := Debris.new()
			scene.add_child(d)
			var dir := Vector3(randf_range(-1.0, 1.0), randf_range(1.5, 2.5), randf_range(-1.0, 1.0)).normalized()
			d.setup(global_position + Vector3(0.0, 50.0, 0.0), dir * randf_range(600.0, 1100.0))

## Hitscan / projectile hit from `attacker` (a Node: the local player or
## a bot avatar). Reported to the server, which owns the health.
func net_damage(amount: float, attacker: Node) -> void:
	if not alive:
		return
	var weapon: int = -1
	if attacker != null and is_instance_valid(attacker):
		if "_weapon_idx" in attacker:
			weapon = int(attacker.get("_weapon_idx"))
		elif "weapon_idx" in attacker:
			weapon = int(attacker.get("weapon_idx"))
	Net.hit(net_id, amount, Net.id_of(attacker), weapon)
	Audio.play_sfx_3d("HIT2.RAW", global_position + Vector3(0.0, 40.0, 0.0), -4.0)

## Damage with no attributed shooter (world / unknown).
func take_damage(amount: float) -> void:
	net_damage(amount, null)

# --- bots: the brain writes yaw/pitch and velocity ----------------------

var weapon_idx: int = 1

func _physics_process(delta: float) -> void:
	if not alive:
		_death_t += delta
		if _death_t > HIDE_AFTER_DEATH:
			visible = false
		_step_anim(delta)
		return
	if local_drive:
		rotation.y = yaw
		var before := global_position
		move_and_slide()
		_moving_t = 0.15 if global_position.distance_to(before) > 1.0 else maxf(_moving_t - delta, 0.0)
	elif _has_target:
		var k: float = clampf(delta * LERP_RATE, 0.0, 1.0)
		var before := global_position
		global_position = global_position.lerp(_target_pos, k)
		# Snap when far off (teleport / respawn / long lag).
		if global_position.distance_to(_target_pos) > 1500.0:
			global_position = _target_pos
		yaw = lerp_angle(yaw, _target_yaw, k)
		pitch = lerpf(pitch, _target_pitch, k)
		rotation.y = yaw
		if (flags & 1) != 0 or global_position.distance_to(before) > 0.5:
			_moving_t = 0.15
		else:
			_moving_t = maxf(_moving_t - delta, 0.0)
	if _clip != "attack" and _clip != "death":
		_play("walk" if _moving_t > 0.0 else "idle")
	_step_anim(delta)

# --- animation --------------------------------------------------------

func _play(clip: String, restart: bool = false) -> void:
	if _clip == clip and not restart:
		return
	_clip = clip
	_clip_t = 0.0
	_clip_i = 0
	_show_clip_frame()

func _step_anim(delta: float) -> void:
	if _frames.is_empty() or not _anim.has(_clip):
		return
	var a: Array = _anim[_clip]
	var fps: float = float(a[2]) if float(a[2]) > 0.0 else EnemyAnim.DEFAULT_FPS
	var n: int = int(a[1]) - int(a[0]) + 1
	if n <= 1:
		return
	_clip_t += delta
	var step: float = 1.0 / fps
	while _clip_t >= step:
		_clip_t -= step
		_clip_i += 1
		if _clip_i >= n:
			if _clip == "attack":
				_play("idle")
				return
			if _clip == "death":
				_clip_i = n - 1              # hold the last frame
			else:
				_clip_i = 0
	_show_clip_frame()

func _show_clip_frame() -> void:
	if _frames.is_empty() or _mesh == null:
		return
	var a: Array = _anim.get(_clip, [1, 1, 10.0, true])
	var f: int = clampi(int(a[0]) + _clip_i, 0, _frames.size() - 1)
	if _mesh.mesh != _frames[f]:
		_mesh.mesh = _frames[f]
