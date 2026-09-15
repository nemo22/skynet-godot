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
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")

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
## How far above the feet a floor plate may sit for a sunk actor to pop
## back out onto it (corridor ceilings are 128+ above the floor).
const SINK_RECOVER: float = 110.0
## The level's water surface (INF when the map is dry), set by main
## when the level comes up. A ground actor will not drive into it —
## "tank nemôže jazdiť po vode!!! ponoril by sa" (MAP.270's lake).
## An actor that is ALREADY in the water (the flooded decks of
## MAP.252-254) is not affected.
static var water_y: float = INF
## The level's heightmap, for the lakes that are painted into the
## terrain material instead of being marked (MAP.270).
static var terrain_wld: WldTerrain.WLD = null
const WATER_EDGE: float = 8.0
## Machine segments (state 10) hurt by contact: how far past the
## claw the swipe still lands, how hard, and how often.
const MACHINE_MARGIN: float = 60.0
## A weaponless chaser (DOS state 6 with no fire params and no armed
## segments — type 1 `globe`, whose `near` is 25) is a flying mine:
## it closes on the player and detonates. How far past `near` the
## contact counts, and the blast it (and a dormant trap) throws.
const KAMIKAZE_REACH: float = 40.0
const BLAST_RADIUS: float = 250.0
const BLAST_DAMAGE: float = 30.0
const MACHINE_HIT_DAMAGE: float = 9.0
const MACHINE_HIT_INTERVAL: float = 1.9
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
## The fallback FSM's shot is DOS ammo type 15 (table 0x40728 →
## AIData.AMMO[15]): LASER3.3D, the enemy bolt, 25 damage, fire sound 39.
## Its damage comes from that record like every other enemy shot — there
## is no per-type damage to set.
const LEGACY_AMMO: int = 15
const LEGACY_BOLT_SPEED: float = 800.0     # DOS fire-param speed field

## Ray budget. A busy map (MAP.240, 55 actors) cast 15-20 000 rays a
## second, most of them answering the same question as the tick before.
## The ground probes ahead of a mover, the snap to the floor and a
## hover's floor samples run every PROBE_TICKS physics ticks, each actor
## on its own phase, and the answer stands in between: the probes look
## 40 and 120 u ahead, farther than a ground actor travels in that time
## (under 40 u even at 800 u/s), and the body ray is lengthened by the
## ticks it skips.
const PROBE_TICKS: int = 3
## Line of sight is refreshed every LOS_TICKS ticks (15 Hz at 60): the
## AIS script only reads it at EnemyAI.SCRIPT_HZ (12 Hz).
const LOS_TICKS: int = 4
## An actor this far from the camera and outside its view runs its whole
## update every FAR_TICKS ticks on the summed delta — it walks as far,
## turns as far and animates as far, in steps nobody can see. Nothing
## fires from there: the longest DOS fire range is 1900 u.
const FAR_DIST: float = 4000.0
const FAR_TICKS: int = 4
## How far outside the view an actor still counts as seen (its own size
## is added): the camera can turn faster than FAR_TICKS.
const FAR_VIEW_MARGIN: float = 400.0
## Engine loops stop past their max_distance plus this, and start again
## inside it.
const ENGINE_GATE_MARGIN: float = 500.0

# Legacy exports (fallback FSM and level_loader compatibility).
@export var detect_range: float = 7000.0
@export var attack_range: float = 2600.0
@export var move_speed: float = 480.0
@export var turn_speed: float = 2.6            # radians / sec
@export var anim_fps: float = 12.0
@export var max_health: float = 60.0
@export var fire_interval: float = 1.9         # seconds between shots
@export var aim_spread: float = 0.055          # miss cone, fraction of range
@export var big_model_size: float = 360.0      # AABB extent above which death flings debris
@export var death_anim_frames: int = -1

const DEATH_FRAME_BUDGET: int = 8
const ENGINE_DB: float = -10.0

## Wreck parts resolved by level_loader: [[Mesh, Vector3 offset], …].
var death_parts: Array = []

var _frames: Array = []
var _anim_t: float = 0.0
var _anim_i: int = 0
var _player: Node3D = null
var _foot_offset: float = 0.0
var _hit_area: Area3D = null
var _hit_shape: CollisionShape3D = null
## How much bigger than the machine itself the hitbox is, and the least
## it may ever be. A spider walker's BODY mesh is a small box on long
## legs, and the legs are separate segments — aiming at the body was the
## only way to hit it at all ("hitpoint robotov je strasne maly, treba
## mierit presne do stredu", 2026-09-04).
const HIT_MARGIN: float = 1.18
const HIT_MIN: float = 90.0

## Grow the hitbox to cover every mesh under this actor. Called once the
## child segments are in place.
func refit_hitbox() -> void:
	if _hit_shape == null or not is_instance_valid(_hit_shape):
		return
	var box: BoxShape3D = _hit_shape.shape as BoxShape3D
	if box == null:
		return
	var b: AABB = _mesh_bounds(self, Transform3D())
	if b.size == Vector3.ZERO:
		return
	var size: Vector3 = b.size * HIT_MARGIN
	box.size = Vector3(maxf(size.x, HIT_MIN), maxf(size.y, HIT_MIN),
		maxf(size.z, HIT_MIN))
	_hit_shape.position = b.position + b.size * 0.5

## How far a blast at `at` is from this machine — measured to its
## HITBOX, not to its origin. A flying HK is 421 x 242 x 591: a grenade
## bursting on its nose is ~300 units from the origin, beyond the
## launcher's 256-unit splash, and took no damage at all ("granátometom
## sa nedá zničiť lietajúce HK, aj keď ho zasiahne x granátov").
## 0 when the point is inside the box.
func blast_distance(at: Vector3) -> float:
	if _hit_shape == null or not is_instance_valid(_hit_shape) 			or not (_hit_shape.shape is BoxShape3D):
		return global_position.distance_to(at)
	var half: Vector3 = (_hit_shape.shape as BoxShape3D).size * 0.5
	var local: Vector3 = _hit_shape.global_transform.affine_inverse() * at
	var out := Vector3(maxf(absf(local.x) - half.x, 0.0),
		maxf(absf(local.y) - half.y, 0.0), maxf(absf(local.z) - half.z, 0.0))
	return out.length()

## Union of every mesh under `n`, in this actor's space.
static func _mesh_bounds(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out = xf * (n as MeshInstance3D).mesh.get_aabb()
		first = false
	for c in n.get_children():
		if not (c is Node3D):
			continue
		var a: AABB = _mesh_bounds(c, xf * (c as Node3D).transform)
		if a.size == Vector3.ZERO:
			continue
		out = a if first else out.merge(a)
		first = false
	return out

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
## Script-only machines bolted to this actor (DOS state 10): the
## grabber arm, the welding arm, the torture rig. Each runs its own
## AIS script, which plays the animation blocks — and swipes at the
## player who walks into it.
var _machines: Array = []
var _kamikaze: int = -1                        # -1 unknown, 0 no, 1 yes
var _segs_built: bool = false
var _cds: Dictionary = {}                      # shooter node → cooldown
var _wander_target: Vector3 = Vector3.ZERO
var _wander_t: float = 0.0
var _blocked: bool = false
var _seen: bool = false
var _dormant_dist: float = 0.0                 # > 0: trap, explode when near
var _ticks: int = 0
## This actor's phase in the staggered checks (a multiple of 3 and 4).
var _stagger: int = randi() % 12
## One ray query for every cast this actor makes (bodies only).
var _ray := PhysicsRayQueryParameters3D.new()
var _los: bool = false
var _los_tick: int = -1000
var _probe_tick: int = -1000
var _probe_blocked: bool = false
var _floor_tick: int = -1000
var _floor_cache: float = 0.0
## The floor the last snap stood on — the feet ride its plane between
## snaps, so a slope does not leave them sunk or floating.
var _ground_tick: int = -1000
var _ground_ok: bool = false
var _ground_pt: Vector3 = Vector3.ZERO
var _ground_n: Vector3 = Vector3.UP
var _far_acc: float = 0.0
var _engine_far: bool = false
var _sense_d: Dictionary = {}
## The camera, sampled once per physics frame for every actor.
static var _view_frame: int = -1
static var _view_ok: bool = false
static var _view_pos: Vector3 = Vector3.ZERO
static var _view_planes: Array[Plane] = []

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
		# …but a walker's ground speed is its walk cycle's, not the
		# table's: DOS moves state-7 actors by the model's own root
		# motion (see EnemyAnim.WALK_SPEED).
		if int(_t.get("st", -1)) == 7:
			var ws: float = EnemyAnim.walk_speed(String(_t.get("n", "")))
			if ws > 0.0:
				move_speed = ws
		if int(_t.get("turn", 0)) > 0:
			turn_speed = float(_t["turn"]) / 2048.0 * TAU

func setup(frame_meshes: Array, aabb: AABB, stationary: bool = false,
		flying: bool = false, sound_name: String = "",
		passive: bool = false) -> void:
	_frames = frame_meshes
	# Feet = the lowest vertex across EVERY frame, not just frame 0.
	# Feet = the lowest vertex over the LIVING frames (the first two thirds
	# of the strip): a death/collapse pose reaches lower than any walk
	# frame (SPIDBOT f22 -158 vs -129) and pulled the spider 30 u into the
	# ground on MAP.240 (2026-09-02 report).
	_foot_offset = aabb.position.y
	var living: int = _frames.size() if _frames.size() < 6 else int(ceil(float(_frames.size()) * 2.0 / 3.0))
	for i in living:
		var fm = _frames[i]
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

	# Hitbox so the player's shots can register on this actor. The box is
	# kept on the node so refit_hitbox() can grow it once the turret,
	# legs and gun segments have been attached.
	_hit_area = Area3D.new()
	_hit_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size
	_hit_shape.shape = box
	_hit_shape.position = aabb.position + aabb.size * 0.5
	_hit_area.add_child(_hit_shape)
	# Hits come from ray and shape queries with collide_with_areas, and
	# those reach an area that neither monitors nor is monitorable: Godot
	# Physics culls the ray/shape broadphase over its static tree as well
	# (cull_segment/cull_aabb with tree mask 0xFFFFFFFF), Jolt's query
	# filter passes AREA_UNDETECTABLE like AREA_DETECTABLE. Nothing
	# listens for overlaps on a hitbox, so it pays for no pairs.
	_hit_area.monitoring = false
	_hit_area.monitorable = false
	_hit_area.collision_mask = 0
	add_child(_hit_area)

	if sound_name != "" and not _t.has("engine"):
		_snd = AudioStreamPlayer3D.new()
		_snd.stream = Audio.stream(sound_name)
		Audio.setup_3d(_snd)
		_snd.volume_db = -8.0
		_snd.max_db = 0.0
		add_child(_snd)
	# DOS engine loop (tanks, HKs): the {5, sound} block in the params.
	if _t.has("engine"):
		var nm: String = Audio.sound_name(int(_t["engine"]))
		if not nm.is_empty():
			_engine = AudioStreamPlayer3D.new()
			_engine.stream = Audio.stream(nm)
			Audio.setup_3d(_engine, 500.0, 8000.0)
			_engine.volume_db = ENGINE_DB
			_engine.max_db = -2.0
			_engine.finished.connect(func() -> void:
				if is_inside_tree() and _state != State.DEAD and not _engine_far:
					_engine.play())
			add_child(_engine)
	# The DOS actor starts with its script's first animation.
	if _brain != null and _brain.has_script():
		_brain.tick(0.0, {})
		_show_frame(_brain.frame)

func _ready() -> void:
	# Audio players can only start once inside the tree.
	if _engine != null and _dormant_dist <= 0.0 and not _hidden:
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

## A vehicle that drives a marker path (DOS AI state 11, handler
## 0x127400): the action system moves it, so no AI, no ground snap and
## no fighting — that handler has no firing code at all.
var _on_path: bool = false
## hk_ftr as a path vehicle has 0 hit points, and DOS ObjHit does nothing
## to an actor below 1 HP: the pick-up HK cannot be shot down.
var indestructible: bool = false

func make_path_vehicle() -> void:
	_on_path = true
	_init_done = true

## An 0xF3 spawn point's robot (SpawnEnemiesInit 0x129500 in v1.01):
## built at level start, then hidden — obj+0xc |= 0x2000 keeps it out
## of the active-enemy list (skynet_gh.c:29810) and the draw loop
## (38213) — until its sprite's chain fires (0x12960b clears the flag).
var _hidden: bool = false
var _hidden_layers: Dictionary = {}          # collision object → [layer, mask]

func hide_until_spawned() -> void:
	_hidden = true
	visible = false
	remove_from_group("enemy")
	process_mode = Node.PROCESS_MODE_DISABLED
	# Layer AND mask: with only the layer gone the hidden body still
	# paired with everything its mask named.
	for c in find_children("*", "CollisionObject3D", true, false):
		var co := c as CollisionObject3D
		_hidden_layers[c] = [co.collision_layer, co.collision_mask]
		co.collision_layer = 0
		co.collision_mask = 0
	if _engine != null:
		_engine.stop()

func spawn_in() -> void:
	if not _hidden:
		return
	_hidden = false
	visible = true
	process_mode = Node.PROCESS_MODE_INHERIT
	for c in _hidden_layers:
		if is_instance_valid(c):
			var saved: Array = _hidden_layers[c]
			(c as CollisionObject3D).collision_layer = int(saved[0])
			(c as CollisionObject3D).collision_mask = int(saved[1])
	_hidden_layers.clear()
	if not _passive:
		add_to_group("enemy")
		Stats.add_enemies(1)
	if _engine != null and is_inside_tree() and not _engine_far:
		_engine.play()

func is_hidden() -> bool:
	return _hidden

## The hitbox's physics RID: this actor's own shots leave it out of
## their ray instead of hitting it and flying on.
func hitbox_rid() -> RID:
	if _hit_area == null or not is_instance_valid(_hit_area):
		return RID()
	return _hit_area.get_rid()

## Radius of everything drawn under this actor, from its origin-space
## bounds (level_loader sizes the draw distance by it).
func bounds_radius() -> float:
	return _mesh_bounds(self, Transform3D()).size.length() * 0.5

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
	# Engine loops: in earshot only, muffled behind walls — checked every
	# 20 ticks, staggered across the actors.
	if _engine != null and (_ticks + get_instance_id()) % 20 == 0:
		_gate_engine()
	if _ticks < 2:
		return                                 # colliders settle into the space first
	if _on_path:
		return                                 # the action system drives it
	if not _init_done:
		if _flying:
			_init_done = true
		elif _stationary:
			_unbury()
			_init_done = true
		elif _snap_to_ground(true):
			_init_done = true
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	if _dormant_dist > 0.0:
		if _player != null and global_position.distance_to(_player.global_position) < _dormant_dist:
			_detonate_trap()
		return
	# Far away and out of view: the same update, FAR_TICKS at a time.
	_far_acc += delta
	if (_ticks + _stagger) % FAR_TICKS != 0 and _far_unseen():
		return
	var dt: float = _far_acc
	_far_acc = 0.0
	if _brain != null:
		_tick_data(dt)
	else:
		_tick_legacy(dt)

## True when this actor is beyond FAR_DIST from the camera and wholly
## outside its view (with FAR_VIEW_MARGIN to spare). False without a
## camera: then everything runs at the full rate.
func _far_unseen() -> bool:
	var frame: int = Engine.get_physics_frames()
	if frame != _view_frame:
		_view_frame = frame
		var cam: Camera3D = get_viewport().get_camera_3d()
		_view_ok = cam != null
		if _view_ok:
			_view_pos = cam.global_position
			_view_planes = cam.get_frustum()
	if not _view_ok:
		return false
	var p: Vector3 = global_position
	if p.distance_squared_to(_view_pos) < FAR_DIST * FAR_DIST:
		return false
	var r: float = _body_size + FAR_VIEW_MARGIN
	for pl in _view_planes:
		if pl.distance_to(p) > r:          # frustum normals point outward
			return true
	return false

## True on this actor's phase of an `every`-tick check (shifted by
## `offset` so two checks do not land on one tick), or when the last one
## is `every` ticks old — it just started moving, or runs at the far rate.
func _due(last: int, every: int, offset: int = 0) -> bool:
	return (_ticks + _stagger + offset) % every == 0 or _ticks - last >= every

## One ray through this actor's reusable query (bodies only, not the
## actor hitboxes). Empty when the space is gone.
func _cast(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	_ray.from = from
	_ray.to = to
	return space.intersect_ray(_ray)

## The engine loop plays while the camera is within its max_distance
## (plus ENGINE_GATE_MARGIN before it stops): a player past it is silent
## but still mixed, map-wide. In earshot it muffles behind walls.
func _gate_engine() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	var d: float = cam.global_position.distance_to(global_position) if cam != null else 0.0
	if d > _engine.max_distance + (0.0 if _engine_far else ENGINE_GATE_MARGIN):
		_engine_far = true
		if _engine.playing:
			_engine.stop()
		return
	if _engine_far:
		_engine_far = false
		if _state != State.DEAD and _dormant_dist <= 0.0 and not _hidden \
				and is_inside_tree():
			_engine.play()
	if _engine.playing:
		_engine.volume_db = ENGINE_DB + Audio.occlusion_db(global_position + Vector3(0.0, 40.0, 0.0))

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
	# A weaponless chaser is a flying mine — it does not shoot, it
	# arrives. `near` is where DOS parks it: right on top of the player.
	if st == 6 and _is_kamikaze() and bool(sense.get("see", false)) 			and global_position.distance_to(
				_player.global_position + Vector3(0.0, 40.0, 0.0)) 				<= float(_t.get("near", 40)) + KAMIKAZE_REACH:
		_detonate_trap()
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
	for m in _machines:
		_tick_machine(m, delta, sense)
	# Root shooter.
	var fp: Array = _brain.fire_params()
	if not fp.is_empty() and not _has_segment_node(self):
		var gate: bool = _brain.firing_pose() if (st == 7 and _brain.has_script()) else true
		if gate:
			_try_fire(self, fp, delta, _t)

## What the DOS handler perceives this tick. One dictionary per actor,
## refilled every tick (the brain reads it and keeps nothing).
func _sense() -> Dictionary:
	var s: Dictionary = _sense_d
	s["blocked"] = _blocked
	if _player == null:
		s["see"] = false
		s["dist"] = 1.0e9
		s["bearing"] = 0
		s["angle"] = 0
		return s
	var to: Vector3 = _player.global_position - global_position
	var flat := Vector3(to.x, 0.0, to.z)
	var dist: float = flat.length()
	var angle: int = _dos_angle(flat)
	var facing: int = int(round(global_rotation.y / TAU * 2048.0)) & 0x7FF
	s["see"] = dist < PERCEPTION_RANGE and _has_los()
	s["dist"] = dist
	s["bearing"] = (angle - facing) & 0x7FF
	s["angle"] = angle
	return s

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
		if _due(_probe_tick, PROBE_TICKS):
			_probe_tick = _ticks
			var ground_bound: bool = st != 9 and not _flying
			# The actor keeps going on this answer until the next probe, so
			# the body ray also covers the ticks in between.
			var skip: float = absf(speed) * float(PROBE_TICKS - 1) \
				/ float(Engine.physics_ticks_per_second)
			_probe_blocked = _path_blocked(step, skip) or (ground_bound and (_too_steep(fwd)
					or _drop_ahead(fwd) or _water_ahead(fwd)))
		if _probe_blocked:
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
		var reach: float = maxf(float(_t.get("avoid", 400)), FLYER_LOOKAHEAD)
		var fwd_n: Vector3 = -global_transform.basis.z
		# Sample the whole path, not just its far end: one probe ahead
		# missed a hillside rising in between and the craft flew into it
		# ("nepriateľské hkčko v polke v kopci"). Four 26 000-unit rays, so
		# every PROBE_TICKS ticks: the craft covers under 40 u of a 400 u
		# look-ahead in between.
		if _due(_floor_tick, PROBE_TICKS, 1):
			_floor_tick = _ticks
			_floor_cache = _surface_at(global_position)
			for f in [0.34, 0.67, 1.0]:
				_floor_cache = maxf(_floor_cache, _surface_at(global_position + fwd_n * (reach * f)))
		var floor_y: float = _floor_cache
		var want_y: float = maxf(_player.global_position.y + 31.0, floor_y + min_alt)
		var dy: float = want_y - global_position.y
		# Below the floor of its band it is already in the hill: climb out
		# as fast as it takes, not at the cruising rate.
		var urgent: bool = global_position.y < floor_y + min_alt * 0.5
		var vmax: float = (FLYER_CLIMB_SPEED * (3.0 if urgent else 1.0) if dy > 0.0
			else FLYER_SINK_SPEED) * delta
		global_position.y += clampf(dy, -vmax, vmax)
	elif _flying and not (st == 6 and _is_kamikaze() and see):
		# Every other flyer keeps clear of the ground. The state-6
		# chasers (the scouts) have no altitude logic of their own: they
		# chased horizontally at their marker height and slid into the
		# hillsides. Checked every fourth tick — the correction is
		# gradual and a ray per actor per frame is not worth it — each
		# actor on its own phase, climbing for the ticks since the last.
		if _due(_floor_tick, 4, 1):
			var since: int = clampi(_ticks - _floor_tick, 1, 16) if _floor_tick > 0 else 4
			_floor_tick = _ticks
			var fwd2: Vector3 = -global_transform.basis.z
			var fl: float = maxf(_surface_at(global_position),
				_surface_at(global_position + fwd2 * FLYER_LOOKAHEAD))
			var need: float = fl + FLYER_MIN_ALT - global_position.y
			if need > 0.0:
				global_position.y += minf(need, FLYER_CLIMB_SPEED * float(since)
					/ float(Engine.physics_ticks_per_second))
	elif st == 6 and _flying and _is_kamikaze() and see:
		# A flying mine homes in three dimensions: `near` parks it 25
		# units from the player, but only on the flat, so without this
		# it hovers over his head and never touches him.
		var want_y: float = _player.global_position.y + 40.0
		var dy: float = want_y - global_position.y
		global_position.y += clampf(dy, -speed * delta, speed * delta)
	elif not _flying:
		if _due(_ground_tick, PROBE_TICKS, 2):
			_ground_tick = _ticks
			_snap_to_ground()
		elif _ground_ok:
			_ride_ground_plane()

## Between two snaps, keep the feet on the plane of the floor the last
## snap found (a slope, a ramp); the next snap corrects a crest or a lift.
func _ride_ground_plane() -> void:
	var d: Vector3 = global_position - _ground_pt
	var feet: float = _ground_pt.y - (_ground_n.x * d.x + _ground_n.z * d.z) / _ground_n.y
	global_position.y = feet - _foot_offset

## Highest solid surface under the actor (terrain or a roof).
func _surface_below() -> float:
	return _surface_at(global_position)

## Highest solid surface under `at` (terrain or a roof); `at.y` when
## nothing is found.
func _surface_at(at: Vector3) -> float:
	var hit := _cast(at + Vector3(0.0, 6000.0, 0.0), at + Vector3(0.0, -20000.0, 0.0))
	return (hit["position"] as Vector3).y if hit.has("position") else at.y

## True when the ground one step ahead is under the level's water and
## the actor is not already in it: dry land stays dry land.
func _water_ahead(fwd: Vector3) -> bool:
	var ahead: Vector3 = global_position + fwd * 120.0
	if WldTerrain.is_water_at(terrain_wld, ahead.x, -ahead.z):
		return true                        # a painted lake (MAP.270)
	if water_y == INF:
		return false
	if global_position.y + _foot_offset <= water_y:
		return false                       # already wading / submerged
	return _surface_at(ahead) < water_y - WATER_EDGE

## True when the floor 120 units ahead is missing or more than MAX_DROP
## below the feet — a platform edge, not a ramp.
func _drop_ahead(fwd: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var ahead: Vector3 = global_position + fwd * 120.0
	var max_drop: float = MAX_DROP_TERMINATOR if (_type_id >= 33 and _type_id <= 38) else MAX_DROP_OTHER
	var hit := _cast(ahead + Vector3(0.0, 60.0, 0.0),
		ahead + Vector3(0.0, -max_drop - 60.0, 0.0))
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
	var hn := _cast(near + Vector3(0.0, 400.0, 0.0), near + Vector3(0.0, -400.0, 0.0))
	if hn.has("position"):
		var step_up: float = (hn["position"] as Vector3).y - global_position.y
		if step_up > (STEP_TERMINATOR if term else STEP_OTHER):
			return true
	var ahead: Vector3 = global_position + fwd * 120.0
	var hit := _cast(ahead + Vector3(0.0, 400.0, 0.0), ahead + Vector3(0.0, -400.0, 0.0))
	if not hit.has("position"):
		return false
	var rise: float = (hit["position"] as Vector3).y - global_position.y
	if rise <= 0.0:
		return false
	var limit: float = SLOPE_TERMINATOR if term else SLOPE_OTHER
	return atan2(rise, 120.0) > limit

## Solid geometry ahead along `step`, plus `extra` units (bodies only,
## not the player).
func _path_blocked(step: Vector3, extra: float = 0.0) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var from: Vector3 = global_position + Vector3(0.0, 60.0, 0.0)
	var hit := _cast(from, from + step.normalized() * (step.length() + extra + 40.0))
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
				elif sst == 10 and c.has_meta("seg_frames"):
					_machines.append(_make_machine(c as Node3D, td, ty))
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

## A script-only machine segment (state 10). It gets its own brain —
## the AIS script is what makes the arm swing and pick things up — plus
## the reach of the arm, taken from the model itself.
func _make_machine(node: Node3D, td: Dictionary, ty: int) -> Dictionary:
	var frames: Array = node.get_meta("seg_frames", [])
	# The claw, per frame: the vertex farthest from the segment's own
	# origin. An arm's AABB is mostly empty air when it leans, so the
	# box would "grab" the player from across the room; the tip is what
	# actually sweeps.
	var tips := PackedVector3Array()
	for f in frames:
		var tip := Vector3.ZERO
		if f is Mesh and (f as Mesh).get_surface_count() > 0:
			var arr: Array = (f as Mesh).surface_get_arrays(0)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var best: float = -1.0
			for v in vs:
				var l: float = v.length_squared()
				if l > best:
					best = l
					tip = v
		tips.append(tip)
	return {"node": node, "t": td, "type": ty, "frames": frames,
		"tips": tips, "brain": EnemyAI.new(ty), "cd": 0.0}

## Run one machine segment: its script drives the frames, and anything
## the arm sweeps through gets hit. DOS gives these types no fire
## params — the grabber hurts by touch ("keď hráč k nemu príde, tak ho
## zraňuje"), once per swing rather than continuously.
func _tick_machine(m: Dictionary, delta: float, sense: Dictionary) -> void:
	var node: Node3D = m["node"]
	if not is_instance_valid(node):
		return
	var brain = m["brain"]
	brain.tick(delta, sense)
	var frames: Array = m["frames"]
	if brain.frame_changed and not frames.is_empty():
		var fi: int = clampi(brain.frame, 0, frames.size() - 1)
		(node as MeshInstance3D).mesh = frames[fi]
	for sid in brain.sounds:
		Audio.play_id_3d(int(sid), node.global_position, -8.0)
	m["cd"] = maxf(float(m["cd"]) - delta, 0.0)
	if _player == null or float(m["cd"]) > 0.0:
		return
	# The claw as it is POSED this frame has to actually reach the
	# player — not a bubble around the arm's base.
	var tips: PackedVector3Array = m["tips"]
	if tips.is_empty():
		return
	var fi: int = clampi(brain.frame, 0, tips.size() - 1)
	var tip: Vector3 = node.global_transform * tips[fi]
	if tip.distance_to(_player.global_position + Vector3(0.0, 40.0, 0.0)) <= MACHINE_MARGIN:
		m["cd"] = MACHINE_HIT_INTERVAL
		_player.take_damage(MACHINE_HIT_DAMAGE, false)   # contact: no DIFFICULTY (0x12282f)
		Audio.play_sfx_3d("HIT2.RAW", tip, -4.0)

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
	# DIFFICULTY scales the rate of fire. DOS rolls `rand() & 1023 <
	# rate * factor`; dividing the interval comes to the same thing.
	# This path (every actor with DOS table data — which is nearly all
	# of them) was missing it, so MEDIUM shot 1.6x and LOW 4x too often:
	# "toto vyzerá skôr na najvyššiu obtiažnosť než na strednú".
	_cds[node] = (FIRE_RATE_DIV / rate) * randf_range(0.8, 1.3) / maxf(Settings.enemy_fire_scale(), 0.01)
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
	MuzzleFlash.spawn(scene, muzzle, tint, 44.0)
	if fam == 0:
		# Hitscan bullets: tracer + instant damage (DOS type 0/1/16).
		var endpoint: Vector3 = muzzle + dir * 20000.0
		var hit := _cast(muzzle, endpoint)
		if hit.has("position"):
			endpoint = hit["position"]
		Tracer.spawn(scene, muzzle, endpoint, tint)
		if hit.has("collider"):
			var n: Node = hit["collider"] as Node
			while n != null and not n.has_method("take_damage"):
				n = n.get_parent()
			if n != null and n.is_in_group("player"):
				# A direct hit: the ammo record's damage, in DOS points.
				if n.has_method("take_dos_damage"):
					n.take_dos_damage(float(absi(dmg)))
				else:
					n.take_damage(float(absi(dmg)))
			elif bank > 0:
				Explosion.spawn(scene, endpoint, 40.0, bank)
		return
	var proj := Projectile.new()
	scene.add_child(proj)
	var cfg: Dictionary = {
		"model": model if not model.is_empty() else "LASER3.3D",
		"color": tint,
		"speed": maxf(dos_speed, 200.0) * BOLT_SPEED_SCALE,
		"life": maxf(life, 0.8),
		"splash": blast if dmg < 0 else 0.0,
		"impact_bank": bank, "hits": "player",
		"trail": model.begins_with("ROCKET"),
	}
	if isnd >= 0:
		cfg["impact_sound"] = Audio.sound_name(isnd)
	proj.setup(muzzle, dir, float(absi(dmg)), cfg, self)

## Measured from each model's own 1x1 texture record in TEXTURE.001
## (Projectile.BOLT_COLOURS): LASER1 cyan, LASER2 green, LASER3 red.
## The port used to guess LASER1 red and LASER2 blue.
static func _ammo_color(model: String) -> Color:
	if model == "ROCKET.3D":
		return Color(1.0, 0.75, 0.4)
	return Projectile.colour_for(model, Color(1.0, 0.45, 0.22))

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
			# DIFFICULTY scales the rate of fire (LOW = a quarter as often).
			_fire_cd = fire_interval * randf_range(0.8, 1.3) / maxf(Settings.enemy_fire_scale(), 0.01)
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
	_shoot(muzzle, dir, LEGACY_AMMO, LEGACY_BOLT_SPEED)

# ---------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------
## True when an unobstructed line runs to the player. Cast every
## LOS_TICKS ticks on this actor's phase; the perception and every
## shooter on the actor share the answer in between.
func _has_los() -> bool:
	if _player == null:
		return false
	if not _due(_los_tick, LOS_TICKS, 3):
		return _los
	_los_tick = _ticks
	var space := get_world_3d().direct_space_state
	if space == null:
		_los = false
		return false
	var hit := _cast(global_position + Vector3(0.0, 60.0, 0.0),
		_player.global_position + Vector3(0.0, 60.0, 0.0))
	_los = not hit.has("collider") or (hit["collider"] as Object).has_method("take_damage")
	return _los

## Receive damage from a player shot.
## `by_player` marks a hit that came from the player's own weapon — the
## STATISTICS tab counts those against the shots fired.
func take_damage(amount: float, by_player: bool = true) -> void:
	if indestructible:
		return
	if _state == State.DEAD:
		return
	if by_player and not Net.active:
		Stats.hit()
	# DIFFICULTY scales damage dealt to entities (LOW hits 1.5x harder).
	_health -= amount * Settings.dmg_to_enemy()
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

## DOS ObjHit (0x139019) on this machine: the jeep's ram (0x135a7e, the
## car's speed >> 9) and a dying robot's blast (DEATH_BLAST_*). ObjHit
## subtracts the value as it comes — no DIFFICULTY factor, which DOS
## applies only where a projectile lands — and alerts the actor like any
## hit. True when the hit destroyed it (a ramming car drives on), false
## when it still stands or has no hit points to lose (the car bounces off).
func obj_hit(amount: float) -> bool:
	if indestructible or _hidden or _state == State.DEAD:
		return false
	_health -= maxf(amount, 0.0)
	if _dormant_dist > 0.0:
		if _health <= 0.0:
			_detonate_trap()
			return true
		return false
	_seen = true
	if _health <= 0.0:
		_die()
		return true
	if _state == State.IDLE and _brain == null:
		_set_chase()
	return false

## True for an actor that has no way to shoot: no fire params of its
## own and no armed segment bolted on. Cached — the segments are built
## once.
func _is_kamikaze() -> bool:
	if _kamikaze < 0:
		_kamikaze = 1 if (Array(_t.get("fire", [])).is_empty() and _segs.is_empty()) else 0
	return _kamikaze == 1

## Dormant trap / flying mine: detonate (DOS state 12 — effect + sound
## 0x26) and throw a blast at the player.
func _detonate_trap() -> void:
	if _state == State.DEAD:
		return
	_state = State.DEAD
	var centre := global_position + Vector3(0.0, _body_height * 0.5, 0.0)
	Audio.play_id_3d(DEATH_SOUND_ID, centre, -2.0)
	Audio.play_sfx_3d("EXPLO1.RAW", centre, -2.0)
	_spawn_explosion(centre, _body_size * 0.55)
	_blast(centre)
	_fling_parts(centre)
	queue_free()

## Explosion damage on the player: full at the centre, nothing at
## BLAST_RADIUS. Without this a mine that reaches the player just puffs.
func _blast(centre: Vector3) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var d: float = centre.distance_to(
		_player.global_position + Vector3(0.0, 40.0, 0.0))
	if d >= BLAST_RADIUS:
		return
	_player.take_damage(BLAST_DAMAGE * (1.0 - d / BLAST_RADIUS))

## Destroy the machine: DOS EnemyKill — instant explosion plus the
## type's wreck parts flung ballistically.
func _die() -> void:
	if _state == State.DEAD:
		return
	_state = State.DEAD
	if not Net.active:
		Stats.kill()
	if _engine != null:
		_engine.stop()
	var centre := global_position + Vector3(0.0, _body_height * 0.5, 0.0)
	Audio.play_sfx_3d("EXPLO1.RAW", centre, -2.0)
	_spawn_explosion(centre, _body_size * 0.55)
	if not _fling_parts(centre) and _body_size >= big_model_size:
		for _i in 4 + (randi() % 4):
			_spawn_debris(centre, null)
	if not Net.active and is_inside_tree():
		# The timer outlives this node: the blast is the script's, not ours.
		get_tree().create_timer(DEATH_BLAST_DELAY, false).timeout.connect(
			Callable(get_script(), "_death_blast").bind(get_tree(), global_position))
	queue_free()

## DOS EnemyKill (0x129a28) sets off the actor's own explosion — blast
## value 75 for every robot (0x129661) — which strikes DEATH_BLAST_DELAY
## later (timer 0x90, 0x123e71). At distance d from the actor to the
## player's DOS point (fly_camera.dos_point) it deals 115 - d, in DOS's
## fixed-point steps, when that comes to DEATH_BLAST_MIN or more and
## nothing solid stands between — unscaled by DIFFICULTY (0x12457f ..
## 0x124634) — and robots in reach take the same through ObjHit. So only
## what is within ~78 u gets hurt: the pipe's victim, and the jeep that
## rammed a robot to pieces and rolls on over the wreck at 7/8 speed. The
## port never dealt it ("zraňovalo to aj hráča", playtest 2026-09-15).
const DEATH_BLAST: int = 75
const DEATH_BLAST_PAD: int = 40
const DEATH_BLAST_MIN: int = 37
const DEATH_BLAST_DELAY: float = 0.375

## The blast's damage at distance `d` (0 or less: none).
static func death_blast_damage(d: float) -> int:
	var k: int = floori(float(DEATH_BLAST + DEATH_BLAST_PAD - d) * 256.0 / float(DEATH_BLAST))
	var dmg: int = (k * DEATH_BLAST) >> 8
	return dmg if dmg >= DEATH_BLAST_MIN else 0

static func _death_blast(tree: SceneTree, at: Vector3) -> void:
	if tree == null:
		return
	var pl := tree.get_first_node_in_group("player") as Node3D
	if pl == null or not pl.is_inside_tree():
		return
	var space: PhysicsDirectSpaceState3D = pl.get_world_3d().direct_space_state
	if space == null:
		return
	var pp: Vector3 = pl.call("dos_point") if pl.has_method("dos_point") else pl.global_position
	var dmg: int = death_blast_damage(at.distance_to(pp))
	if dmg > 0 and _blast_clear(space, at, pp, pl):
		pl.call("take_dos_damage", float(dmg), false)
	for e in tree.get_nodes_in_group("enemy"):
		if not (e is Node3D) or not is_instance_valid(e) or not e.has_method("obj_hit"):
			continue
		var ep: Vector3 = (e as Node3D).global_position
		var ed: int = death_blast_damage(at.distance_to(ep))
		if ed > 0 and _blast_clear(space, at, ep, null):
			e.call("obj_hit", float(ed))

## Nothing solid between the blast and `to` (bodies only; `ignore` is the
## body at the far end).
static func _blast_clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, ignore: Node) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	if ignore is CollisionObject3D:
		q.exclude = [(ignore as CollisionObject3D).get_rid()]
	return space.intersect_ray(q).is_empty()

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
	Explosion.spawn(scene, at, radius)

func _spawn_debris(at: Vector3, part: Mesh) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var d := Debris.new()
	scene.add_child(d)
	# DOS (FUN_00129b59) tosses the parts a few metres, not across the
	# street (a 2026-09-03 report): a steep, short lob.
	var dir := Vector3(randf_range(-1.0, 1.0), randf_range(1.4, 2.4),
		randf_range(-1.0, 1.0)).normalized()
	d.setup(at, dir * randf_range(380.0, 780.0), part)

## A stationary actor keeps its marker Y — DOS never samples the ground
## for it, and that is what keeps the turrets on the gate pillars. But a
## marker whose Y buries the base in a hill or in a roof slab leaves only
## the gun above the surface ("na tej budove by mala byť otočná veža, ale
## je prepadnutá do budovy" — MAP.280 has four guntwr3 sunk 134 u into
## the rock). Lift such an actor until its feet rest on the surface it is
## stuck in, and never past its own origin: the lift is bounded by how
## far the model hangs below the marker, so a turret hanging under a
## ceiling or already standing on a pillar cannot be moved at all.
func _unbury() -> void:
	var space := get_world_3d().direct_space_state
	if space == null or _foot_offset >= -1.0:
		return
	var feet_y: float = global_position.y + _foot_offset
	if not _floor_ray(space, global_position, feet_y + 8.0, feet_y - 24.0).is_empty():
		return                                 # already standing on something
	var hit := _floor_ray(space, global_position, global_position.y,
		feet_y + 8.0, true)
	if hit.is_empty():
		return
	var lift: float = (hit["position"] as Vector3).y - feet_y
	global_position.y += lift
	print("[enemy] %s un-buried: lifted %.0f u onto the surface it sat in"
		% [name, lift])

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
	var hit := _floor_ray(space, global_position, feet_y + up, feet_y - down)
	if hit.is_empty() and init:
		# A marker on a seam between floor pieces has nothing under it.
		# The DOS spawn query (FUN_00138500) scans the neighbouring cells
		# for the floor; step to the nearest floor plate around us.
		for r in [40.0, 80.0]:
			for i in 8:
				var a: float = TAU * float(i) / 8.0
				var off := Vector3(cos(a) * r, 0.0, sin(a) * r)
				hit = _floor_ray(space, global_position + off, feet_y + up, feet_y - down)
				if not hit.is_empty():
					global_position.x += off.x
					global_position.z += off.z
					break
			if not hit.is_empty():
				break
	if hit.is_empty():
		# Nothing to stand on below — are we UNDER a floor plate (spawned
		# at a seam, or pushed beneath a raised walkway)? A surface with
		# an upward normal within SINK_RECOVER above the feet is a floor,
		# not a ceiling (those face down): pop out onto it.
		# At placement a marker may sit well under the surface (the MAP.240
		# spiders: 130 u) — reach further up on the first snap.
		var pop := _floor_ray(space, global_position, feet_y + (240.0 if init else SINK_RECOVER), feet_y + up, true)
		_ground_ok = false
		if not pop.is_empty():
			global_position.y = (pop["position"] as Vector3).y - _foot_offset
			return true
		return init
	var gp: Vector3 = hit["position"]
	global_position.y = gp.y - _foot_offset
	# Remember the floor's plane for the ticks until the next snap. The
	# DOS meshes collide double-sided, so a normal may come back facing
	# down; the plane is the same either way.
	var gn: Vector3 = hit["normal"]
	if gn.y < 0.0:
		gn = -gn
	_ground_ok = gn.y > 0.5
	_ground_pt = gp
	_ground_n = gn
	return true

## Vertical ray at `at`'s x/z from `y_top` down to `y_bottom`; with
## `floor_only` a hit must face upward (a floor's top, not a ceiling).
func _floor_ray(space: PhysicsDirectSpaceState3D, at: Vector3, y_top: float, y_bottom: float, floor_only: bool = false) -> Dictionary:
	_ray.from = Vector3(at.x, y_top, at.z)
	_ray.to = Vector3(at.x, y_bottom, at.z)
	var hit := space.intersect_ray(_ray)
	if hit.is_empty():
		return {}
	if floor_only and (hit["normal"] as Vector3).y < 0.5:
		return {}
	return hit

## Step `cur` toward `target` (radians) by at most `max_step`.
static func _approach_angle(cur: float, target: float, max_step: float) -> float:
	var d := wrapf(target - cur, -PI, PI)
	if absf(d) <= max_step:
		return target
	return cur + signf(d) * max_step
