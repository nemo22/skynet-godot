## Enemy actor — DOS-data-driven animation, movement, combat and sound.
##
## Every enemy type's behaviour comes from the Skynet.exe enemy table
## (VA 0x44d00 → enemy_ai_data.gd): its AI state id selects the
## behaviour family, the parameter block gives speed / turn rate / stop
## distance / turret axis + limits / fire parameters (muzzle offset,
## ammo type, rate, range) / frame-event sounds / engine loop / wreck
## parts, and the AIS script (run by enemy_ai.gd) drives the animation
## blocks and the tactical decisions exactly as the DOS interpreter.
##
## Behaviour families (state id):
##   7  walkers (T800 family, raptor, spidbot, T-rex legs): script-driven
##      animation; move while the walk loop plays; fire only during a
##      firing pose (anim flag 0x100) — DOS walker handler 0x13be00.
##   6  hover/ground chasers (globe, drone, scout, flencer, hover tank).
##   9  flyers (HK): script sets the altitude target (var 56).
##   13 tanks: script sets speed (var 48) and heading (var 44).
##   2/8 turret segments: aim one axis (0 pitch, 1 yaw) within limits at
##      the turn rate while the player is inside the engage range; fire
##      from the segment's muzzle. Child segments (guns on a rotating
##      head) are separate types on the same actor.
##   0/10/11 static bases, machines, transports: animate only.
##   1  wreck parts flung on death (ballistic).
## Combat death is instant in DOS (EnemyKill): explosion + parts.
## Actors placed with a trigger distance (marker sub+2) are dormant
## traps that detonate when the player comes close (state 12).
##
## Types without table data fall back to the older heuristic FSM
## (IDLE → CHASE → ATTACK) with the fan-port animation tables.

extends MeshInstance3D

const Explosion := preload("res://scripts/explosion.gd")
const Debris := preload("res://scripts/debris.gd")
const EnemyAnim := preload("res://scripts/enemy_anim.gd")
const Projectile := preload("res://scripts/projectile.gd")
const Tracer := preload("res://scripts/tracer.gd")
const MuzzleFlash := preload("res://scripts/muzzle_flash.gd")
const EnemyAI := preload("res://scripts/enemy_ai.gd")
const AIData := preload("res://scripts/enemy_ai_data.gd")

enum State { IDLE, CHASE, ATTACK, DEAD }

# --- tunables --------------------------------------------------------
## DOS movement speeds (u/s) are used as-is; raise if the player feels
## too fast relative to the machines.
const SPEED_SCALE: float = 1.0
## DOS projectile "speed" field → world units/s.
const BOLT_SPEED_SCALE: float = 5.0
## Shots per second = fire rate field / FIRE_RATE_DIV (pistol 250 →
## ~2/s, small turret 200 → 1.6/s, missile pod 30 → 0.23/s).
const FIRE_RATE_DIV: float = 128.0
## Aim cone before a shot is released — DOS 0x8c of 2048 (24.6°).
const AIM_CONE: float = 140.0 / 2048.0 * TAU
## DOS perception cutoff (FUN_0013bcda: 0x7d1).
const PERCEPTION_RANGE: float = 2000.0
## Hover handler 0x13c300 vertical limits: sinks toward the player at
## 250 u/s, climbs at 300 u/s, and never goes below (p6 - 100) above the
## ground under it (fighter 284, bomber 92 — floored here so a bomber
## does not skim the player's head).
const FLYER_SINK_SPEED: float = 250.0
const FLYER_CLIMB_SPEED: float = 300.0
const FLYER_MIN_ALT: float = 250.0
const FLYER_LOOKAHEAD: float = 400.0
## Wander leg length / interval when the player is not perceived.
const WANDER_RADIUS: float = 1200.0
## Max uphill slope a walker takes (radians). Only the terminator family
## (types 33-38) climbs steep canyon walls in DOS; raptors, spiders and
## hover units stay on gentle ground.
const SLOPE_TERMINATOR: float = 0.79     # ~45° over 120 u
const SLOPE_OTHER: float = 0.47          # ~27°
## Max single step (rise within 40 u): window sills and crates are not
## stairs — the tower terminator climbed onto its own roof without it.
const STEP_TERMINATOR: float = 40.0
const STEP_OTHER: float = 20.0
## Ground actors never step off a ledge: the floor 120 u ahead may be at
## most this far below the feet (terminators take catwalk ramps up to
## ~39°, the rest gentler slopes; a real platform edge is far deeper).
const MAX_DROP_TERMINATOR: float = 96.0
const MAX_DROP_OTHER: float = 60.0
const DEATH_SOUND_ID: int = 38            # dormant-trap detonation (0x26)

# Legacy exports (fallback FSM and level_loader compatibility).
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
@export var death_anim_frames: int = -1
@export var death_anim_time: float = 0.5

const DEATH_FRAME_BUDGET: int = 8

## Wreck parts resolved by level_loader: [[Mesh, Vector3 offset], …].
var death_parts: Array = []

var _frames: Array = []
var _anim_t: float = 0.0
var _anim_i: int = 0
var _player: Node3D = null
var _foot_offset: float = 0.0
var _stationary: bool = false
var _flying: bool = false
var _passive: bool = false
var _init_done: bool = false
var _state: State = State.IDLE
var _health: float = 60.0
var _fire_cd: float = 0.0
var _body_size: float = 0.0
var _body_height: float = 0.0
var _snd: AudioStreamPlayer3D = null           # alert voice (legacy)
var _engine: AudioStreamPlayer3D = null        # DOS engine loop
var _aim_node: Node3D = null                   # legacy aim mount
var _anim_table: Dictionary = {}
var _clip: String = ""

# --- DOS data-driven state ---
var _type_id: int = -1
var _t: Dictionary = {}                        # AIData.TYPES entry
var _brain: EnemyAI = null                     # AIS interpreter
var _segs: Array = []                          # turret segments (see _build_segments)
var _segs_built: bool = false
var _cds: Dictionary = {}                      # shooter node → cooldown
var _wander_target: Vector3 = Vector3.ZERO
var _wander_t: float = 0.0
var _blocked: bool = false
var _seen: bool = false
var _dormant_dist: float = 0.0                 # > 0: trap, explode when near
var _rest_yaw: float = 0.0
var _ticks: int = 0

## Bind the DOS type data. Call before setup() (level_loader does).
func configure(type_id: int) -> void:
	_type_id = type_id
	if type_id >= 0 and type_id < AIData.TYPES.size():
		_t = AIData.TYPES[type_id]
		_brain = EnemyAI.new(type_id)
		if int(_t.get("hp", 0)) > 0:
			max_health = float(_t["hp"])
		if int(_t.get("speed", 0)) > 0:
			move_speed = float(_t["speed"]) * SPEED_SCALE
		if int(_t.get("turn", 0)) > 0:
			turn_speed = float(_t["turn"]) / 2048.0 * TAU

func setup(frame_meshes: Array, aabb: AABB, stationary: bool = false,
		flying: bool = false, sound_name: String = "",
		passive: bool = false) -> void:
	_frames = frame_meshes
	# Feet = the lowest vertex across EVERY frame, not just frame 0.
	_foot_offset = aabb.position.y
	for fm in _frames:
		if fm is ArrayMesh:
			_foot_offset = minf(_foot_offset,
				(fm as ArrayMesh).get_aabb().position.y)
	_stationary = stationary
	_flying = flying
	_passive = passive
	_health = max_health
	_body_height = aabb.size.y
	_body_size = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if not _frames.is_empty():
		mesh = _frames[0]
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

	if sound_name != "" and not _t.has("engine"):
		_snd = AudioStreamPlayer3D.new()
		_snd.stream = Audio.stream(sound_name)
		_snd.unit_size = 2000.0
		_snd.max_distance = 22000.0
		_snd.volume_db = -8.0
		_snd.max_db = 0.0
		add_child(_snd)
	# DOS engine loop (tanks, HKs): the {5, sound} block in the params.
	if _t.has("engine"):
		var nm: String = Audio.sound_name(int(_t["engine"]))
		if not nm.is_empty():
			_engine = AudioStreamPlayer3D.new()
			_engine.stream = Audio.stream(nm)
			_engine.unit_size = 1500.0
			_engine.max_distance = 16000.0
			_engine.volume_db = -10.0
			_engine.max_db = -2.0
			_engine.finished.connect(func() -> void:
				if is_inside_tree() and _state != State.DEAD:
					_engine.play())
			add_child(_engine)
	# The DOS actor starts with its script's first animation.
	if _brain != null and _brain.has_script():
		_brain.tick(0.0, {})
		_show_frame(_brain.frame)

func _ready() -> void:
	# Audio players can only start once inside the tree.
	if _engine != null and _dormant_dist <= 0.0:
		_engine.play()

## Fan-port AnimRecord table — only used by the fallback FSM.
func set_anim_table(table: Dictionary) -> void:
	_anim_table = table

## Legacy aim mount — used only when the type has no turret data.
func set_aim_node(n: Node3D) -> void:
	_aim_node = n

## A dormant trap (marker sub+2 = trigger distance): no AI, not a
## mission hostile, detonates when the player comes within `dist`.
func make_dormant(dist: float) -> void:
	_dormant_dist = maxf(dist, 1.0)
	remove_from_group("enemy")
	if _engine != null:
		_engine.stop()

## True once the actor is dying/dead.
func is_dead() -> bool:
	return _state == State.DEAD

func _show_frame(f: int) -> void:
	if _frames.is_empty():
		return
	var i: int = clampi(f, 0, _frames.size() - 1)
	if i != _anim_i or mesh != _frames[i]:
		_anim_i = i
		mesh = _frames[i]

# ---------------------------------------------------------------------
# Per-tick update
# ---------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _state == State.DEAD:
		return
	_ticks += 1
	if _ticks < 2:
		return                                 # colliders settle into the space first
	if not _init_done:
		if _flying or _stationary:
			_init_done = true
		elif _snap_to_ground(true):
			_init_done = true
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	if _dormant_dist > 0.0:
		if _player != null and global_position.distance_to(_player.global_position) < _dormant_dist:
			_detonate_trap()
		return
	if _brain != null:
		_tick_data(delta)
	else:
		_tick_legacy(delta)

# ---------------------------------------------------------------------
# DOS data-driven path
# ---------------------------------------------------------------------
func _tick_data(delta: float) -> void:
	if not _segs_built:
		_build_segments()
	var st: int = _brain.state
	var sense: Dictionary = _sense()
	_brain.tick(delta, sense)
	if _brain.frame_changed:
		_show_frame(_brain.frame)
	elif _brain.anim_frames.is_empty() and _frames.size() > 1 \
			and (_flying or _passive or st == 6 or st == 9):
		_cycle_full_strip(delta)          # rotor/engine strips without a block
	for sid in _brain.sounds:
		Audio.play_id_3d(int(sid), global_position + Vector3(0.0, 40.0, 0.0), -6.0)
	if _passive or _player == null:
		return
	# Legacy alert voice on first perception.
	if _seen and not sense.get("see", false):
		pass
	if bool(sense.get("see", false)) and not _seen:
		_seen = true
		if _snd != null and _snd.stream != null and not _snd.playing:
			_snd.play()
	match st:
		7, 6, 9, 13:
			_move_data(delta, sense)
	for seg in _segs:
		_aim_segment(seg, delta)
	# Root shooter.
	var fp: Array = _brain.fire_params()
	if not fp.is_empty() and not _has_segment_node(self):
		var gate: bool = _brain.firing_pose() if (st == 7 and _brain.has_script()) else true
		if gate:
			_try_fire(self, fp, delta, _t)

## What the DOS handler perceives this tick.
func _sense() -> Dictionary:
	if _player == null:
		return {"see": false, "dist": 1.0e9, "bearing": 0, "angle": 0, "blocked": _blocked}
	var to: Vector3 = _player.global_position - global_position
	var flat := Vector3(to.x, 0.0, to.z)
	var dist: float = flat.length()
	var angle: int = _dos_angle(flat)
	var facing: int = int(round(global_rotation.y / TAU * 2048.0)) & 0x7FF
	var see: bool = dist < PERCEPTION_RANGE and _has_los()
	return {"see": see, "dist": dist, "bearing": (angle - facing) & 0x7FF,
		"angle": angle, "blocked": _blocked}

## Direction → DOS 11-bit yaw (matches the actor's rotation.y frame).
static func _dos_angle(dir: Vector3) -> int:
	if dir.length_squared() < 1.0:
		return 0
	return int(round(atan2(-dir.x, -dir.z) / TAU * 2048.0)) & 0x7FF

## Movement for walkers / hovers / flyers / tanks.
func _move_data(delta: float, sense: Dictionary) -> void:
	var st: int = _brain.state
	var see: bool = bool(sense.get("see", false))
	var target: Vector3
	if see:
		target = _player.global_position
		_wander_t = 0.0
	else:
		target = _wander(delta)
	var to: Vector3 = target - global_position
	to.y = 0.0
	var dist: float = to.length()
	var speed: float = move_speed
	var want_yaw: float = atan2(-to.x, -to.z) if dist > 1.0 else rotation.y
	if st == 13:
		# Tank script: heading (var 44, absolute DOS angle) and speed (var 48).
		if _brain.vars.has(44):
			want_yaw = float(_brain.var_or(44, 0)) / 2048.0 * TAU
		speed = float(_brain.var_or(48, int(_t.get("speed", 0)))) * SPEED_SCALE
	elif st == 9:
		# Hover (0x13c300): forward speed p9, or the script's target speed
		# (var 56 — 50..800, negative = back off); p4/p5 are turn limits.
		speed = float(_brain.var_or(56, int(_t.get("fspeed", 400)))) * SPEED_SCALE
	rotation.y = _approach_angle(rotation.y, want_yaw, turn_speed * delta)
	var moving: bool = true
	if st == 7:
		# Walkers only travel while a looping (walk) block plays.
		moving = (_brain.anim_flags & EnemyAI.ANIM_LOOP) != 0 \
			and not _brain.freeze_anim
	var near: float = float(_t.get("near", 100))
	if (st == 13 and speed < 0.0) or st == 9:
		moving = true                          # hovers never park — they overfly
	elif dist <= near:
		moving = false
	_blocked = false
	if moving and absf(speed) > 0.5:
		var fwd: Vector3 = -global_transform.basis.z
		var step: Vector3 = fwd * speed * delta
		var ground_bound: bool = st != 9 and not _flying
		if _path_blocked(step) or (ground_bound and (_too_steep(fwd) or _drop_ahead(fwd))):
			_blocked = true
			if st == 9:
				rotation.y += 1.2 * delta          # flyer: veer off the wall
			elif not see:
				_wander_t = 0.0                    # pick another leg
		else:
			global_position += step
	if st == 9:
		# DOS hover: sink toward the player's eye height, but stay at
		# least (p6 - 100) above the ground beneath — sampled under the
		# craft AND p8 ahead, so a rising hillside is climbed before it
		# is hit, and a strafing pass stays well over the player's head.
		var min_alt: float = maxf(float(_t.get("alt", 384)) - 100.0, FLYER_MIN_ALT)
		var ahead: Vector3 = -global_transform.basis.z * maxf(float(_t.get("avoid", 400)), FLYER_LOOKAHEAD)
		var floor_y: float = maxf(_surface_at(global_position), _surface_at(global_position + ahead))
		var want_y: float = maxf(_player.global_position.y + 31.0, floor_y + min_alt)
		var dy: float = want_y - global_position.y
		var vmax: float = (FLYER_CLIMB_SPEED if dy > 0.0 else FLYER_SINK_SPEED) * delta
		global_position.y += clampf(dy, -vmax, vmax)
	elif not _flying:
		_snap_to_ground()

## Highest solid surface under the actor (terrain or a roof).
func _surface_below() -> float:
	return _surface_at(global_position)

## Highest solid surface under `at` (terrain or a roof); `at.y` when
## nothing is found.
func _surface_at(at: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	if space == null:
		return at.y
	var q := PhysicsRayQueryParameters3D.create(
		at + Vector3(0.0, 6000.0, 0.0),
		at + Vector3(0.0, -20000.0, 0.0))
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	return (hit["position"] as Vector3).y if hit.has("position") else at.y

## True when the floor 120 units ahead is missing or more than MAX_DROP
## below the feet — a platform edge, not a ramp.
func _drop_ahead(fwd: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var ahead: Vector3 = global_position + fwd * 120.0
	var max_drop: float = MAX_DROP_TERMINATOR if (_type_id >= 33 and _type_id <= 38) else MAX_DROP_OTHER
	var q := PhysicsRayQueryParameters3D.create(ahead + Vector3(0.0, 60.0, 0.0),
		ahead + Vector3(0.0, -max_drop - 60.0, 0.0))
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	return not hit.has("position")

## True when the ground 120 units ahead rises more steeply than the
## family allows.
func _too_steep(fwd: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var term: bool = _type_id >= 33 and _type_id <= 38
	# A ledge right ahead (40 u) may rise at most one step.
	var near: Vector3 = global_position + fwd * 40.0
	var qn := PhysicsRayQueryParameters3D.create(near + Vector3(0.0, 400.0, 0.0),
		near + Vector3(0.0, -400.0, 0.0))
	qn.collide_with_areas = false
	var hn := space.intersect_ray(qn)
	if hn.has("position"):
		var step_up: float = (hn["position"] as Vector3).y - global_position.y
		if step_up > (STEP_TERMINATOR if term else STEP_OTHER):
			return true
	var ahead: Vector3 = global_position + fwd * 120.0
	var q := PhysicsRayQueryParameters3D.create(ahead + Vector3(0.0, 400.0, 0.0),
		ahead + Vector3(0.0, -400.0, 0.0))
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if not hit.has("position"):
		return false
	var rise: float = (hit["position"] as Vector3).y - global_position.y
	if rise <= 0.0:
		return false
	var limit: float = SLOPE_TERMINATOR if term else SLOPE_OTHER
	return atan2(rise, 120.0) > limit

## Solid geometry ahead along `step` (bodies only, not the player).
func _path_blocked(step: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var from: Vector3 = global_position + Vector3(0.0, 60.0, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, from + step.normalized() * (step.length() + 40.0))
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if not hit.has("collider"):
		return false
	return not (hit["collider"] as Object).has_method("take_damage")

## Random patrol leg when the player is not perceived.
func _wander(delta: float) -> Vector3:
	_wander_t -= delta
	if _wander_t <= 0.0 or _wander_target == Vector3.ZERO:
		_wander_t = randf_range(4.0, 9.0)
		var a: float = randf() * TAU
		_wander_target = global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(300.0, WANDER_RADIUS)
	return _wander_target

## Rotor/engine strips of types without an animation block.
func _cycle_full_strip(delta: float) -> void:
	_anim_t += delta
	var step: float = 1.0 / anim_fps
	while _anim_t >= step:
		_anim_t -= step
		_anim_i = (_anim_i + 1) % _frames.size()
	mesh = _frames[_anim_i]

# --- turret segments -------------------------------------------------
## Collect every aiming segment: the root when its own type is a
## turret (state 2/8), plus child meshes tagged with "seg_type" by
## level_loader whose type is a turret.
func _build_segments() -> void:
	_segs_built = true
	_rest_yaw = rotation.y
	var st: int = int(_t.get("st", 0))
	if st == 2 or st == 8:
		_segs.append(_make_seg(self, _t, _type_id))
	_collect_segs(self)

func _collect_segs(n: Node) -> void:
	for c in n.get_children():
		if c is Node3D and c.has_meta("seg_type"):
			var ty: int = int(c.get_meta("seg_type"))
			if ty >= 0 and ty < AIData.TYPES.size():
				var td: Dictionary = AIData.TYPES[ty]
				var sst: int = int(td.get("st", 0))
				if sst == 2 or sst == 8:
					_segs.append(_make_seg(c as Node3D, td, ty))
		_collect_segs(c)

func _make_seg(node: Node3D, td: Dictionary, ty: int) -> Dictionary:
	return {"node": node, "t": td, "type": ty,
		"axis": int(td.get("axis", 1)),
		"amin": float(td.get("amin", -2048)) / 2048.0 * TAU,
		"amax": float(td.get("amax", 2048)) / 2048.0 * TAU,
		"rate": float(td.get("turn", 512)) / 2048.0 * TAU,
		"range": float(td.get("range", 800)),
		"rest_yaw": node.rotation.y, "rest_pitch": node.rotation.x,
		"hp": float(td.get("hp", 0))}

func _has_segment_node(n: Node3D) -> bool:
	for s in _segs:
		if s["node"] == n:
			return true
	return false

## DOS turret state 2: track the player on the segment's axis within
## its limits while inside the engage range, then fire from it.
func _aim_segment(seg: Dictionary, delta: float) -> void:
	var node: Node3D = seg["node"]
	if not is_instance_valid(node) or _player == null:
		return
	var to_g: Vector3 = _player.global_position + Vector3(0.0, 60.0, 0.0) - node.global_position
	if to_g.length() > seg["range"]:
		return
	var parent: Node3D = node.get_parent() as Node3D
	var pbasis: Basis = parent.global_transform.basis if parent != null else Basis()
	var d: Vector3 = pbasis.inverse() * to_g
	var rate: float = seg["rate"] * delta
	if seg["axis"] == 1:
		var want: float = atan2(-d.x, -d.z)
		var rest: float = seg["rest_yaw"]
		var rel: float = wrapf(want - rest, -PI, PI)
		if seg["amax"] - seg["amin"] < TAU - 0.01:
			rel = clampf(rel, seg["amin"], seg["amax"])
		node.rotation.y = _approach_angle(node.rotation.y, rest + rel, rate)
	else:
		# DOS pitch is positive downward; Godot +X rotation raises the nose.
		var want: float = atan2(d.y, Vector2(d.x, d.z).length())
		var lo: float = -seg["amax"]
		var hi: float = -seg["amin"]
		want = clampf(want, minf(lo, hi), maxf(lo, hi))
		node.rotation.x = _approach_angle(node.rotation.x, want, rate)
	var fp: Array = seg["t"].get("fire", [])
	if not fp.is_empty():
		_try_fire(node, fp, delta, seg["t"])

# --- firing ----------------------------------------------------------
## Fire from `node` with the DOS fire params [mx,my,mz, ammo, speed,
## rate, range] when the player is in range, visible and inside the
## aim cone. Rate-limited per shooter.
func _try_fire(node: Node3D, fp: Array, delta: float, _td: Dictionary) -> void:
	var cd: float = float(_cds.get(node, 0.0)) - delta
	_cds[node] = cd
	if cd > 0.0 or _player == null:
		return
	var aim: Vector3 = _player.global_position + Vector3(0.0, 60.0, 0.0)
	var muzzle: Vector3 = node.global_transform * Vector3(float(fp[0]), -float(fp[1]), -float(fp[2]))
	var to: Vector3 = aim - muzzle
	var dist: float = to.length()
	if dist > float(fp[6]) or dist < 1.0:
		return
	var fwd: Vector3 = -node.global_transform.basis.z
	# Aim gate from the fire struct: cos*65536 (hovers 46340 = 45 deg,
	# endoskeleton 60415 = 23 deg) or an 11-bit bearing; default 24.6 deg.
	var cone: float = AIM_CONE
	if fp.size() > 7:
		var gate: int = int(fp[7])
		if gate > 4096:
			cone = acos(clampf(float(gate) / 65536.0, -1.0, 1.0))
		elif gate > 0:
			cone = float(gate) / 2048.0 * TAU
	if fwd.angle_to(to) > cone:
		return
	if not _has_los():
		return
	var rate: float = maxf(float(fp[5]), 1.0)
	_cds[node] = (FIRE_RATE_DIV / rate) * randf_range(0.8, 1.3)
	_shoot(muzzle, to.normalized(), int(fp[3]), absf(float(fp[4])))

## Spawn the shot for DOS ammo type `ammo` (table 0x40728).
func _shoot(muzzle: Vector3, dir: Vector3, ammo: int, dos_speed: float) -> void:
	var a: Array = AIData.AMMO[ammo] if ammo >= 0 and ammo < AIData.AMMO.size() else []
	var fam: int = int(a[0]) if not a.is_empty() else 2
	var model: String = String(a[1]) if not a.is_empty() else "LASER3.3D"
	var bank: int = int(a[2]) if not a.is_empty() else 364
	var dmg: int = int(a[3]) if not a.is_empty() else 25
	var blast: float = float(a[4]) if not a.is_empty() else 0.0
	var life: float = float(a[5]) / 35.0 if not a.is_empty() else 1.5
	var fsnd: int = int(a[6]) if not a.is_empty() else 15
	var isnd: int = int(a[7]) if not a.is_empty() else -1
	# Inaccuracy: aim somewhere in a cone — wider at range.
	var spread: float = aim_spread * 0.6
	dir = (dir + Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)) * spread).normalized()
	if fsnd >= 0:
		Audio.play_id_3d(fsnd, muzzle, -7.0)
	var scene := get_tree().current_scene
	if scene == null:
		return
	var tint: Color = _ammo_color(model)
	var mf := MuzzleFlash.new()
	scene.add_child(mf)
	mf.setup(muzzle, tint, 90.0)
	if fam == 0:
		# Hitscan bullets: tracer + instant damage (DOS type 0/1/16).
		var space := get_world_3d().direct_space_state
		var endpoint: Vector3 = muzzle + dir * 20000.0
		var q := PhysicsRayQueryParameters3D.create(muzzle, endpoint)
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.has("position"):
			endpoint = hit["position"]
		var tr: MeshInstance3D = Tracer.new()
		scene.add_child(tr)
		tr.setup(muzzle, endpoint, tint)
		if hit.has("collider"):
			var n: Node = hit["collider"] as Node
			while n != null and not n.has_method("take_damage"):
				n = n.get_parent()
			if n != null and n.is_in_group("player"):
				n.take_damage(float(absi(dmg)))
			elif bank > 0:
				var puff := Explosion.new()
				scene.add_child(puff)
				puff.setup(endpoint, 40.0, bank)
		return
	var proj := Projectile.new()
	scene.add_child(proj)
	var cfg: Dictionary = {
		"model": model if not model.is_empty() else "LASER3.3D",
		"color": tint,
		"speed": maxf(dos_speed, 200.0) * BOLT_SPEED_SCALE,
		"life": maxf(life, 0.8),
		"splash": blast if dmg < 0 else 0.0,
		"light": true, "impact_bank": bank, "hits": "player",
		"trail": model.begins_with("ROCKET"),
	}
	if isnd >= 0:
		cfg["impact_sound"] = Audio.sound_name(isnd)
	proj.setup(muzzle, dir, float(absi(dmg)), cfg, self)

static func _ammo_color(model: String) -> Color:
	match model:
		"LASER1.3D": return Color(1.0, 0.32, 0.22)
		"LASER2.3D": return Color(0.45, 0.7, 1.0)
		"ROCKET.3D": return Color(1.0, 0.75, 0.4)
	return Color(1.0, 0.45, 0.22)

# ---------------------------------------------------------------------
# Legacy heuristic FSM (types without table data)
# ---------------------------------------------------------------------
func _tick_legacy(delta: float) -> void:
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
	if _passive or _player == null:
		return
	var to := _player.global_position - global_position
	to.y = 0.0
	var dist := to.length()
	if dist < 1.0:
		return
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
	var want_yaw := atan2(-to.x, -to.z)
	if _aim_node != null:
		var local_want: float = wrapf(want_yaw - global_rotation.y, -PI, PI)
		_aim_node.rotation.y = _approach_angle(_aim_node.rotation.y,
			local_want, turn_speed * delta)
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

func _death_frame_count() -> int:
	var fc: int = _frames.size()
	if fc < 3 or _passive:
		return 0
	if death_anim_frames > 0:
		return mini(death_anim_frames, fc - 1)
	return mini(DEATH_FRAME_BUDGET, maxi(1, fc / 3))

func _walk_frame_end() -> int:
	var fc: int = _frames.size()
	if fc <= 1:
		return 0
	return maxi(0, fc - 1 - _death_frame_count())

func _set_chase() -> void:
	_state = State.CHASE
	if _snd != null and _snd.stream != null and not _snd.playing:
		_snd.play()

## Legacy bolt (fallback FSM): LASER3.3D at the player.
func _fire_at_player() -> void:
	if _clip == "attack" and _anim_table.has("attack"):
		_anim_i = clampi(int(_anim_table["attack"][0]), 0, _frames.size() - 1)
		_anim_t = 0.0
		if not _frames.is_empty():
			mesh = _frames[_anim_i]
	var origin := global_position + Vector3(0.0, 60.0, 0.0)
	var aim := _player.global_position + Vector3(0.0, 60.0, 0.0)
	var dir := (aim - origin).normalized()
	var muzzle := origin + dir * (_body_size * 0.5 + 80.0)
	_shoot(muzzle, dir, 15, 800.0)

# ---------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------
## True when an unobstructed line runs to the player.
func _has_los() -> bool:
	if _player == null:
		return false
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, 60.0, 0.0),
		_player.global_position + Vector3(0.0, 60.0, 0.0))
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if not hit.has("collider"):
		return true
	return (hit["collider"] as Object).has_method("take_damage")

## Receive damage from a player shot.
func take_damage(amount: float) -> void:
	if _state == State.DEAD:
		return
	_health -= amount
	Audio.play_sfx_3d("HIT2.RAW", global_position + Vector3(0.0, 40.0, 0.0), -4.0)
	if _dormant_dist > 0.0:
		if _health <= 0.0:
			_detonate_trap()
		return
	_seen = true                            # being shot alerts it (DOS 0x8000)
	if _health <= 0.0:
		_die()
	elif _state == State.IDLE and _brain == null:
		_set_chase()

## Dormant trap: detonate (DOS state 12 — effect + sound 0x26).
func _detonate_trap() -> void:
	if _state == State.DEAD:
		return
	_state = State.DEAD
	var centre := global_position + Vector3(0.0, _body_height * 0.5, 0.0)
	Audio.play_id_3d(DEATH_SOUND_ID, centre, -2.0)
	Audio.play_sfx_3d("EXPLO1.RAW", centre, -2.0)
	_spawn_explosion(centre, _body_size * 0.55)
	_fling_parts(centre)
	queue_free()

## Destroy the machine: DOS EnemyKill — instant explosion plus the
## type's wreck parts flung ballistically.
func _die() -> void:
	if _state == State.DEAD:
		return
	_state = State.DEAD
	if _engine != null:
		_engine.stop()
	var centre := global_position + Vector3(0.0, _body_height * 0.5, 0.0)
	Audio.play_sfx_3d("EXPLO1.RAW", centre, -2.0)
	_spawn_explosion(centre, _body_size * 0.55)
	if not _fling_parts(centre) and _body_size >= big_model_size:
		for _i in 4 + (randi() % 4):
			_spawn_debris(centre, null)
	queue_free()

## Fling the DOS wreck parts. Returns false when the type has none.
func _fling_parts(centre: Vector3) -> bool:
	if death_parts.is_empty():
		return false
	var scene := get_tree().current_scene
	if scene == null:
		return false
	for p in death_parts:
		var m: Mesh = p[0]
		var off: Vector3 = global_transform.basis * (p[1] as Vector3)
		_spawn_debris(global_position + off, m)
	return true

func _spawn_explosion(at: Vector3, radius: float) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var ex := Explosion.new()
	scene.add_child(ex)
	ex.setup(at, radius)

func _spawn_debris(at: Vector3, part: Mesh) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var d := Debris.new()
	scene.add_child(d)
	var dir := Vector3(randf_range(-1.0, 1.0), randf_range(1.5, 2.8),
		randf_range(-1.0, 1.0)).normalized()
	d.setup(at, dir * randf_range(950.0, 1750.0), part)

## Put the feet on the floor directly below. The ray starts one step
## above the FEET (not the model origin — inside the tower deck a ray
## from 120 u up started above the 130 u ceiling and "found" the roof)
## and reaches down at most one ledge; with nothing in reach the actor
## keeps its height, as DOS keeps a marker's Y. Returns true when the
## actor is settled.
func _snap_to_ground(init: bool = false) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var term: bool = _type_id >= 33 and _type_id <= 38
	var feet_y: float = global_position.y + _foot_offset
	var up: float = 60.0 if init else (STEP_TERMINATOR if term else STEP_OTHER)
	var down: float = 400.0 if init else (MAX_DROP_TERMINATOR if term else MAX_DROP_OTHER)
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(global_position.x, feet_y + up, global_position.z),
		Vector3(global_position.x, feet_y - down, global_position.z))
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.has("position"):
		global_position.y = (hit["position"] as Vector3).y - _foot_offset
		return true
	return init

## Step `cur` toward `target` (radians) by at most `max_step`.
static func _approach_angle(cur: float, target: float, max_step: float) -> float:
	var d := wrapf(target - cur, -PI, PI)
	if absf(d) <= max_step:
		return target
	return cur + signf(d) * max_step
