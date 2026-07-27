## Enemy actor — animation, combat AI and event-driven sound.
##
## States: IDLE → CHASE (player spotted) → ATTACK (in range, firing)
## → DEAD. Sounds fire on events: alert when first spotting the player,
## a weapon shot on firing, an impact when hit, an explosion on death.
## A hitscan Area3D hitbox lets the player's shots register on this
## actor.
##
## Stationary actors (gun towers) never move or turn their body, but
## still fire once the player is in range.
##
## Animation — frame ranges
## ------------------------
## DOS drives enemy meshes through a per-state handler table at virtual
## `0x59900` (`PTR_LAB_00059900`, 13 entries — skynet_gh.c:30128). Each
## state handler writes the entity's current frame index (link+0x16) via
## `AIS_SetFrameNo` (skynet_gh.c:42077). The walk cycle and the death
## sequence draw from DISJOINT frame ranges baked into each .3D — DOS
## never mixes them.
##
## We don't run the AIS handlers (they're un-decompiled raw bytes in the
## EXE), but we replicate the *split*: the `.3D` frame strip is divided
## into a walk range [0 .. walk_end] cycled while moving/firing, and a
## death range [walk_end+1 .. last] played once when the actor dies. The
## split point comes from `death_anim_frames` (auto-derived from total
## frame count when -1; override per enemy in level_loader if needed).

extends MeshInstance3D

const Tracer := preload("res://scripts/tracer.gd")
const Explosion := preload("res://scripts/explosion.gd")
const Debris := preload("res://scripts/debris.gd")
const EnemyAnim := preload("res://scripts/enemy_anim.gd")

enum State { IDLE, CHASE, ATTACK, DEAD }

@export var detect_range: float = 7000.0
@export var attack_range: float = 2600.0
@export var move_speed: float = 480.0
@export var turn_speed: float = 2.6            # radians / sec
@export var anim_fps: float = 12.0
@export var max_health: float = 60.0
@export var fire_interval: float = 1.9         # seconds between shots
@export var shot_damage: float = 9.0
@export var aim_spread: float = 0.055          # miss cone, fraction of range
@export var big_model_size: float = 360.0      # AABB extent above which death flings debris
## Number of trailing `.3D` frames reserved for the death sequence. The
## walk cycle uses everything before this range. -1 = auto: a third of
## the strip (capped at DEATH_FRAME_BUDGET, min 1). Meshes with fewer
## than 3 frames are treated as single-pose — no separation, no death
## anim, just an instant explosion.
@export var death_anim_frames: int = -1
@export var death_anim_time: float = 0.5

const DEATH_FRAME_BUDGET: int = 8

var _frames: Array = []
var _anim_t: float = 0.0
var _anim_i: int = 0
var _player: Node3D = null
var _foot_offset: float = 0.0
var _stationary: bool = false
var _flying: bool = false
var _passive: bool = false                     # transports — animate, no AI
var _init_done: bool = false
var _state: State = State.IDLE
var _health: float = 60.0
var _fire_cd: float = 0.0
var _body_size: float = 0.0                    # largest mesh AABB extent
var _body_height: float = 0.0                  # mesh AABB height
var _snd: AudioStreamPlayer3D = null           # alert voice
## Child segment that yaws toward the player while the base stays still.
## Set for multi-segment stationary actors (turrets): the rotating gun
## or turret head, not the body. Null means rotate the whole mesh.
var _aim_node: Node3D = null
## Per-state frame ranges (`{state: [start, end, fps, loops]}`) sourced
## from EnemyAnim. Empty for meshes without a fan-port AnimRecord entry
## — falls back to the full-strip heuristic.
var _anim_table: Dictionary = {}
## Name of the current animation clip ("idle"/"walk"/"attack"/"death"
## /…). Drives which range _physics_process cycles. Empty when no
## table is loaded; the heuristic path runs instead.
var _clip: String = ""

func setup(frame_meshes: Array, aabb: AABB, stationary: bool = false,
		flying: bool = false, sound_name: String = "",
		passive: bool = false) -> void:
	_frames = frame_meshes
	_foot_offset = aabb.position.y
	_stationary = stationary
	_flying = flying
	_passive = passive
	_health = max_health
	_body_height = aabb.size.y
	_body_size = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if not _frames.is_empty():
		mesh = _frames[0]
	# Passive transports are not hostiles — they don't count as objectives.
	if not _passive:
		add_to_group("enemy")

	# Hitbox so the player's shots can register on this actor.
	var area := Area3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size
	shape.shape = box
	shape.position = aabb.position + aabb.size * 0.5
	area.add_child(shape)
	add_child(area)

	if sound_name != "":
		_snd = AudioStreamPlayer3D.new()
		_snd.stream = Audio.stream(sound_name)
		_snd.unit_size = 2000.0
		_snd.max_distance = 22000.0
		_snd.volume_db = -8.0
		_snd.max_db = 0.0
		add_child(_snd)

## Install a fan-port AnimRecord table (`{state: [start, end, fps,
## loops]}`). Called from level_loader at spawn time. An empty table
## means "no per-state ranges — use the heuristic walk/death split".
func set_anim_table(table: Dictionary) -> void:
	_anim_table = table

## Advance the current AnimRecord clip by `delta`. Resets the frame
## cursor whenever the AI state changes the chosen clip. Clips with
## `loops` true cycle inside [start..end]; one-shot clips hold the
## final frame so a still-firing CHASE actor doesn't snap back to its
## rest pose between shots.
func _step_clip(delta: float) -> void:
	var clip: String = _clip_for_state(_state)
	if clip.is_empty():
		return
	if clip != _clip:
		_clip = clip
		var range_first: int = int(_anim_table[clip][0])
		_anim_i = clampi(range_first, 0, _frames.size() - 1)
		_anim_t = 0.0
		mesh = _frames[_anim_i]
		return
	var rec: Array = _anim_table[clip]
	var start: int = clampi(int(rec[0]), 0, _frames.size() - 1)
	var end: int = clampi(int(rec[1]), start, _frames.size() - 1)
	var fps: float = float(rec[2])
	if fps <= 0.0:
		fps = EnemyAnim.DEFAULT_FPS
	var loops: bool = bool(rec[3])
	_anim_t += delta
	var step: float = 1.0 / fps
	while _anim_t >= step:
		_anim_t -= step
		if _anim_i < start:
			_anim_i = start
		else:
			_anim_i += 1
			if _anim_i > end:
				_anim_i = start if loops else end
	mesh = _frames[_anim_i]

## Pick the clip name that matches the current AI state. Falls back
## through related clips when a specific one isn't in the table (e.g.
## meshes with only "walk" treat ATTACK / CHASE the same).
func _clip_for_state(s: State) -> String:
	if _anim_table.is_empty():
		return ""
	match s:
		State.IDLE:
			if _anim_table.has("idle"): return "idle"
			if _anim_table.has("walk"): return "walk"
		State.CHASE:
			if _anim_table.has("walk"): return "walk"
			if _anim_table.has("run"):  return "run"
			if _anim_table.has("idle"): return "idle"
		State.ATTACK:
			if _anim_table.has("attack"): return "attack"
			if _anim_table.has("walk"):   return "walk"
		State.DEAD:
			if _anim_table.has("death"): return "death"
			if _anim_table.has("fall"):  return "fall"
	return ""

## How many trailing frames are reserved for the death sequence. -1
## explicit override means "auto" — split off a third of the strip,
## capped at DEATH_FRAME_BUDGET, with a floor of 1. A mesh with fewer
## than 3 frames returns 0 (no separation, instant explosion). Passive
## transports keep their full cycle (the strip is engines/rotors, not
## walk-then-die), so they get 0 too. Only consulted when the mesh has
## no fan-port AnimRecord entry; otherwise the table's "death" anim
## supplies its own range.
func _death_frame_count() -> int:
	var fc: int = _frames.size()
	if fc < 3 or _passive:
		return 0
	if death_anim_frames > 0:
		return mini(death_anim_frames, fc - 1)
	return mini(DEATH_FRAME_BUDGET, maxi(1, fc / 3))

## Last frame index of the walking-cycle range (inclusive). Only used
## by the heuristic path — table-driven enemies use clip ranges.
func _walk_frame_end() -> int:
	var fc: int = _frames.size()
	if fc <= 1:
		return 0
	return maxi(0, fc - 1 - _death_frame_count())

func _physics_process(delta: float) -> void:
	# A killed robot is destroyed instantly in an explosion (see _die),
	# which frees this node — this guard only catches a late physics tick
	# before the deferred free runs.
	if _state == State.DEAD:
		return

	# --- animation: state-driven ---
	# Two paths. (a) If the mesh has a fan-port AnimRecord table, pick
	# a clip for the current AI state and cycle its range at the clip's
	# fps. (b) Heuristic fallback for meshes without an entry — turrets,
	# vehicles, drones — uses the full strip with a trailing death
	# reserve (see _walk_frame_end / _death_frame_count).
	if _frames.size() > 1:
		if not _anim_table.is_empty():
			_step_clip(delta)
		else:
			var animate: bool = _flying or _passive \
				or _state == State.CHASE or _state == State.ATTACK
			if animate:
				_anim_t += delta
				var step := 1.0 / anim_fps
				var walk_end: int = _walk_frame_end()
				var walk_len: int = walk_end + 1
				while _anim_t >= step:
					_anim_t -= step
					_anim_i = (_anim_i + 1) % walk_len
				if _anim_i > walk_end:
					_anim_i = 0
				mesh = _frames[_anim_i]
			elif _anim_i != 0:
				_anim_i = 0
				_anim_t = 0.0
				mesh = _frames[0]

	if not _init_done:
		_init_done = true
		# Walking actors settle onto the floor; turrets and fliers keep
		# their authored placement Y (DOS does not ground-snap them — a
		# turret on a pillar must stay on the pillar).
		if not _flying and not _stationary:
			_snap_to_ground()

	if _passive:
		return                                 # transports: animate only

	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return

	var to := _player.global_position - global_position
	to.y = 0.0
	var dist := to.length()
	if dist < 1.0:
		return

	# --- line of sight + state transitions ---
	# An actor only enters/holds ATTACK when it can actually see the
	# player — no shooting through terrain or buildings.
	var los := false
	if _state == State.CHASE or _state == State.ATTACK:
		los = _has_los()
	match _state:
		State.IDLE:
			if dist < detect_range:
				_set_chase()
		State.CHASE:
			if dist > detect_range * 1.25:
				_state = State.IDLE
			elif dist < attack_range and los:
				_state = State.ATTACK
		State.ATTACK:
			if dist > attack_range * 1.2 or not los:
				_state = State.CHASE

	if _state == State.IDLE:
		return

	# Track the player. Walking actors turn the whole body. Turrets are
	# bolted down but rotate their gun/head — when a child aim segment is
	# wired up (multi-segment stationary actor), only that segment yaws
	# while the base stays still; otherwise the whole authored mesh yaws.
	# DOS turrets are multi-segment (fixed base + rotating head), see
	# skynet_gh.c FUN_00150284 entity render + segment table at +0x0C.
	#
	# `want_yaw` is the GLOBAL yaw pointing from this enemy at the player.
	# The aim node is a child of `self`, so its local rotation.y must be
	# `want_yaw − self.global_rotation.y` for its world facing to land on
	# the target — otherwise the authored base yaw (eyaw from the marker)
	# offsets the gun the wrong way and the turret aims off-target.
	var want_yaw := atan2(-to.x, -to.z)
	if _aim_node != null:
		var local_want: float = wrapf(want_yaw - global_rotation.y, -PI, PI)
		_aim_node.rotation.y = _approach_angle(_aim_node.rotation.y,
			local_want, turn_speed * delta)
		# Elevation tracking — DOS turret barrels pitch up/down to keep
		# the player in their sights. With YXZ Euler ordering and the
		# enemy body holding rotation.x = 0, the mount's local pitch
		# equals the global pitch to the player. Aim a bit above feet
		# (chest height) so prone players are still targetable.
		var aim_target_y: float = _player.global_position.y + 60.0
		var dy: float = aim_target_y - global_position.y
		var want_pitch: float = atan2(dy, maxf(dist, 1.0))
		_aim_node.rotation.x = _approach_angle(_aim_node.rotation.x,
			want_pitch, turn_speed * delta)
	else:
		rotation.y = _approach_angle(rotation.y, want_yaw, turn_speed * delta)

	if _state == State.CHASE and not _stationary:
		global_position += to.normalized() * move_speed * delta
		_snap_to_ground()
	elif _state == State.ATTACK:
		# A turret holds fire until its mount has swung onto the target,
		# so it visibly tracks before shooting; walking actors fire freely.
		# Compare yaws in matching frames: aim-node yaw is local to self,
		# self.rotation.y is local to the world.
		var aim_yaw: float
		var target_yaw: float
		if _aim_node != null:
			aim_yaw = _aim_node.rotation.y
			target_yaw = wrapf(want_yaw - global_rotation.y, -PI, PI)
		else:
			aim_yaw = rotation.y
			target_yaw = want_yaw
		var aimed: bool = not _stationary \
			or absf(wrapf(target_yaw - aim_yaw, -PI, PI)) < 0.35
		_fire_cd -= delta
		if _fire_cd <= 0.0 and aimed:
			_fire_cd = fire_interval * randf_range(0.8, 1.3)
			_fire_at_player()

## Designate a child node as the aim segment — only that node yaws to
## track the player, the base stays still. Called by level_loader after
## attaching segments to a multi-segment stationary actor (turrets).
func set_aim_node(n: Node3D) -> void:
	_aim_node = n

func _set_chase() -> void:
	_state = State.CHASE
	if _snd != null and _snd.stream != null and not _snd.playing:
		_snd.play()                            # alert sound

## True when an unobstructed line runs to the player — the first solid
## body hit must be the player, not terrain or a building.
func _has_los() -> bool:
	if _player == null:
		return false
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, 60.0, 0.0),
		_player.global_position + Vector3(0.0, 60.0, 0.0))
	q.collide_with_areas = false               # bodies only
	var hit := space.intersect_ray(q)
	if not hit.has("collider"):
		return true
	return (hit["collider"] as Object).has_method("take_damage")

## Hitscan a shot at the player; terrain and walls block the shot.
func _fire_at_player() -> void:
	var muzzle := global_position + Vector3(0.0, 60.0, 0.0)
	var aim := _player.global_position + Vector3(0.0, 60.0, 0.0)
	# Inaccuracy: the shot lands somewhere in a cone — wider at range.
	var spread := muzzle.distance_to(aim) * aim_spread
	var target := aim + Vector3(randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * spread
	Audio.play_sfx_3d("LASER3.RAW", muzzle, -8.0)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(muzzle, target)
	q.collide_with_areas = false               # bodies only (player, walls)
	var hit := space.intersect_ray(q)
	var endpoint := target
	if hit.has("position"):
		endpoint = hit["position"]
	var tr: MeshInstance3D = Tracer.new()
	get_tree().current_scene.add_child(tr)
	tr.setup(muzzle, endpoint, Color(1.0, 0.5, 0.25))
	if hit.has("collider"):
		var c = hit["collider"]
		if c != null and c.has_method("take_damage"):
			c.take_damage(shot_damage)

## Receive damage from a player shot.
func take_damage(amount: float) -> void:
	if _state == State.DEAD:
		return
	_health -= amount
	Audio.play_sfx_3d("HIT2.RAW", global_position + Vector3(0.0, 40.0, 0.0), -4.0)
	if _health <= 0.0:
		_die()
	elif _state == State.IDLE:
		_set_chase()                           # being shot wakes it up

## Destroy the robot: every enemy is a machine, so death is an explosion,
## not a ragdoll. Large chassis additionally fling burning debris chunks
## that detonate when they hit the ground.
##
## When the mesh has a fan-port AnimRecord table, use its "death" clip
## (frame range + fps) verbatim — these come from `fshock_ida.c`'s
## per-mesh processor (e.g. T800 family death = 46..60 @ 10 fps,
## `sub_428140`). Without a table, fall back to the trailing-frames
## heuristic. Either way, play the sequence then explode + queue_free.
func _die() -> void:
	if _state == State.DEAD:
		return
	_state = State.DEAD
	if _anim_table.has("death"):
		await _play_clip_once("death")
	else:
		var death_count: int = _death_frame_count()
		if death_count > 0:
			var start: int = _frames.size() - death_count
			var step: float = death_anim_time / float(death_count)
			for i in death_count:
				if not is_inside_tree():
					return
				_anim_i = start + i
				mesh = _frames[_anim_i]
				await get_tree().create_timer(step).timeout
	if not is_inside_tree():
		return
	var centre := global_position + Vector3(0.0, _body_height * 0.5, 0.0)
	Audio.play_sfx_3d("EXPLO1.RAW", centre, -2.0)
	_spawn_explosion(centre, _body_size * 0.55)
	if _body_size >= big_model_size:
		for _i in 4 + (randi() % 4):
			_spawn_debris(centre)
	queue_free()

## Play a named clip from `_anim_table` once, frame-by-frame, awaiting
## between frames. Returns when the end frame is shown; bails out
## early if the node leaves the tree.
func _play_clip_once(clip: String) -> void:
	if not _anim_table.has(clip):
		return
	var rec: Array = _anim_table[clip]
	var start: int = clampi(int(rec[0]), 0, _frames.size() - 1)
	var end: int = clampi(int(rec[1]), start, _frames.size() - 1)
	var fps: float = float(rec[2])
	if fps <= 0.0:
		fps = EnemyAnim.DEFAULT_FPS
	var step: float = 1.0 / fps
	for f in range(start, end + 1):
		if not is_inside_tree():
			return
		_anim_i = f
		mesh = _frames[_anim_i]
		await get_tree().create_timer(step).timeout

func _spawn_explosion(at: Vector3, radius: float) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var ex := Explosion.new()
	scene.add_child(ex)
	ex.setup(at, radius)

func _spawn_debris(at: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var d := Debris.new()
	scene.add_child(d)
	var dir := Vector3(randf_range(-1.0, 1.0), randf_range(1.5, 2.8),
		randf_range(-1.0, 1.0)).normalized()
	d.setup(at, dir * randf_range(950.0, 1750.0))

## Drop the actor onto the surface directly below it.
func _snap_to_ground() -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, 4000.0, 0.0),
		global_position + Vector3(0.0, -20000.0, 0.0))
	var hit := space.intersect_ray(q)
	if hit.has("position"):
		global_position.y = (hit["position"] as Vector3).y - _foot_offset

## Step `cur` toward `target` (radians) by at most `max_step`.
static func _approach_angle(cur: float, target: float, max_step: float) -> float:
	var d := wrapf(target - cur, -PI, PI)
	if absf(d) <= max_step:
		return target
	return cur + signf(d) * max_step
