## Deathmatch bot — lives on the SERVER as a child of its DmAvatar and
## drives it like a player: walks with gravity and jumps, hunts the
## nearest visible actor, keeps a weapon-dependent distance while
## strafing, fires hitscan bursts with a skill-dependent spread, roams
## between item spots and spawn points when nobody is in sight and
## grabs pickups it walks over. Its shots are reported to the server
## exactly like a human's (`net_damage` on what the ray hits).
extends Node

## A bot runs at the DOS forward run (fly_camera.run_speed), falls under
## the DOS world gravity and hops with the DOS jump — the same numbers the
## human next to it moves by, so a bot no longer outruns the player it is
## hunting (they were 600 / 4500 / 950 while the player was, 2026-09-16).
const WALK_SPEED: float = 400.0
const GRAVITY: float = 392.0
const JUMP_SPEED: float = 177.0        # same hop as the player: 40 u of air
const SEE_RANGE: float = 7000.0
const THINK_INTERVAL: float = 0.2
const POSE_INTERVAL: float = 0.05
const GRAB_RANGE_H: float = 80.0
const GRAB_RANGE_V: float = 160.0

## Hitscan weapon slots bots pick from (fly_camera.gd table indices).
const WEAPON_CHOICES: Array = [1, 2, 3, 4, 7]
## Preferred engagement distance per slot.
const RANGE_FOR: Dictionary = {1: 700.0, 2: 1100.0, 3: 1000.0, 4: 350.0, 7: 1400.0}
## skill → [aim spread (deg), reaction (s), burst pause (s), hit chance scale]
const SKILL: Array = [
	[9.0, 0.9, 1.2, 0.6],
	[4.5, 0.45, 0.7, 0.8],
	[1.8, 0.15, 0.35, 1.0],
]

var avatar: CharacterBody3D = null
var game: Node = null                 # dm_game.gd — weapon table, world
var skill: int = 1

var _target: Node3D = null
var _target_seen_t: float = 0.0
var _think_t: float = 0.0
var _pose_t: float = 0.0
var _fire_cd: float = 0.0
var _burst_left: int = 0
var _burst_pause: float = 0.0
var _strafe_dir: float = 1.0
var _strafe_t: float = 0.0
var _goal: Vector3 = Vector3.ZERO
var _goal_t: float = 0.0
var _has_goal: bool = false
var _stuck_t: float = 0.0
var _evade_t: float = 0.0
var _evade_dir: float = 1.0
var _aim_yaw: float = 0.0
var _aim_pitch: float = 0.0
var _rng := RandomNumberGenerator.new()
var _pickup_t: float = 0.0
## One ray query for every cast (footing, sight, shots): a new query and
## a new exclude array per bot per physics frame were pure garbage.
var _ray := PhysicsRayQueryParameters3D.new()

func setup(av: CharacterBody3D, g: Node, sk: int) -> void:
	avatar = av
	game = g
	skill = clampi(sk, 0, SKILL.size() - 1)
	_ray.exclude = [avatar.get_rid()]
	_rng.randomize()
	_pick_weapon()

## Cast from `from` to `to` past this bot's own body.
func _cast(from: Vector3, to: Vector3, areas: bool) -> Dictionary:
	_ray.from = from
	_ray.to = to
	_ray.collide_with_areas = areas
	return avatar.get_world_3d().direct_space_state.intersect_ray(_ray)

func _pick_weapon() -> void:
	avatar.weapon_idx = int(WEAPON_CHOICES[_rng.randi() % WEAPON_CHOICES.size()])

## New life: fresh weapon, no target, no goal.
func on_respawn() -> void:
	_target = null
	_has_goal = false
	_burst_left = 0
	_fire_cd = 0.5
	_pick_weapon()

func _physics_process(delta: float) -> void:
	if avatar == null or not avatar.alive or not Net.match_running:
		return
	_think_t -= delta
	if _think_t <= 0.0:
		_think_t = THINK_INTERVAL
		_think()
	_move(delta)
	# Where the bot now stands, for the walk-in triggers of the arena: the
	# server's branch measures its eye as the 0xF1/0xF2 handler (0x138223)
	# measures the player's.
	if game != null and game.has_method("bot_proximity"):
		game.bot_proximity(avatar.net_id, avatar.eye())
	_aim_and_fire(delta)
	_pose_t += delta
	if _pose_t >= POSE_INTERVAL:
		_pose_t = 0.0
		var f: int = 0
		if Vector2(avatar.velocity.x, avatar.velocity.z).length() > 1.0:
			f |= Net.F_MOVING
		Net.bot_pose(avatar.net_id, avatar.global_position, avatar.yaw, avatar.pitch, f)

# --- perception ---------------------------------------------------------

func _think() -> void:
	var best: Node3D = null
	var best_d: float = SEE_RANGE
	var my_eye: Vector3 = avatar.eye()
	for c in _candidates():
		var d: float = c.global_position.distance_to(avatar.global_position)
		if d >= best_d:
			continue
		if _can_see(my_eye, c):
			best = c
			best_d = d
	if best != null:
		if best != _target:
			_target_seen_t = -SKILL[skill][1]      # reaction time before the first shot
		else:
			_target_seen_t = maxf(_target_seen_t, 0.0)
		_target = best
	elif _target != null:
		# Lost sight: chase the last known place for a bit, then give up.
		_target_seen_t -= THINK_INTERVAL
		if _target_seen_t < -3.0 or not is_instance_valid(_target):
			_target = null
	_check_pickups()

## Everyone alive but me: avatars and the host's own player body.
func _candidates() -> Array:
	var out: Array = []
	for a in get_tree().get_nodes_in_group("dm_actor"):
		if a != avatar and a is Node3D and bool(a.get("alive")):
			out.append(a)
	var pl := get_tree().get_first_node_in_group("player")
	if pl is Node3D and Net.is_alive(Net.local_id):
		out.append(pl)
	return out

func _actor_eye(n: Node3D) -> Vector3:
	if n.has_method("eye"):
		return n.eye()
	return n.global_position + Vector3(0.0, 75.0, 0.0)

func _can_see(from: Vector3, n: Node3D) -> bool:
	if avatar.get_world_3d().direct_space_state == null:
		return false
	var hit := _cast(from, _actor_eye(n), false)
	if not hit.has("collider"):
		return true
	var c: Object = hit["collider"]
	return c == n

func _check_pickups() -> void:
	_pickup_t += THINK_INTERVAL
	if _pickup_t < 0.4:
		return
	_pickup_t = 0.0
	var p: Vector3 = avatar.global_position
	for key in Net.pickups:
		var pk: Dictionary = Net.pickups[key]
		if bool(pk["taken"]):
			continue
		var d: Vector3 = (pk["pos"] as Vector3) - p
		if Vector2(d.x, d.z).length() <= GRAB_RANGE_H and absf(d.y) <= GRAB_RANGE_V + 60.0:
			Net.request_pickup(int(key), avatar.net_id)

# --- movement -------------------------------------------------------------

func _move(delta: float) -> void:
	var want: Vector3 = Vector3.ZERO           # horizontal intent, unit
	var p: Vector3 = avatar.global_position
	if _target != null and is_instance_valid(_target):
		var to: Vector3 = _target.global_position - p
		to.y = 0.0
		var dist: float = to.length()
		var fwd: Vector3 = to.normalized() if dist > 1.0 else Vector3.FORWARD
		var side: Vector3 = Vector3(-fwd.z, 0.0, fwd.x)
		var pref: float = float(RANGE_FOR.get(avatar.weapon_idx, 800.0))
		_strafe_t -= delta
		if _strafe_t <= 0.0:
			_strafe_t = _rng.randf_range(0.8, 2.2)
			_strafe_dir = -1.0 if _rng.randf() < 0.5 else 1.0
		if dist > pref + 250.0:
			want = fwd + side * _strafe_dir * 0.4
		elif dist < pref - 250.0:
			want = -fwd + side * _strafe_dir * 0.6
		else:
			want = side * _strafe_dir
	else:
		_goal_t -= delta
		if not _has_goal or _goal_t <= 0.0 or Vector2(_goal.x - p.x, _goal.z - p.z).length() < 120.0:
			_pick_goal()
		if _has_goal:
			var to: Vector3 = _goal - p
			to.y = 0.0
			if to.length() > 1.0:
				want = to.normalized()
	# Obstacles: a knee-height ray ahead; blocked → jump, then veer.
	if want.length() > 0.1:
		want = want.normalized()
		var from: Vector3 = p + Vector3(0.0, 30.0, 0.0)
		var hit := _cast(from, from + want * 110.0, false)
		var blocked: bool = hit.has("collider") and not (hit["collider"] as Object).is_in_group("dm_actor")
		if blocked and avatar.is_on_floor():
			avatar.velocity.y = JUMP_SPEED
		if _evade_t > 0.0:
			_evade_t -= delta
			var side := Vector3(-want.z, 0.0, want.x)
			want = (want * 0.3 + side * _evade_dir).normalized()
	var before := Vector2(p.x, p.z)
	var spd: float = WALK_SPEED * float(Net.CLASS_SPEED[Net.class_of(avatar.net_id)])
	avatar.velocity.x = want.x * spd
	avatar.velocity.z = want.z * spd
	if avatar.is_on_floor():
		if avatar.velocity.y < 0.0:
			avatar.velocity.y = 0.0
	else:
		avatar.velocity.y -= GRAVITY * delta
	# Facing: the target when we have one, else the way we walk.
	if _target != null and is_instance_valid(_target):
		var d: Vector3 = _actor_eye(_target) - avatar.eye()
		_aim_yaw = atan2(-d.x, -d.z)
		_aim_pitch = atan2(d.y, Vector2(d.x, d.z).length())
	elif want.length() > 0.1:
		_aim_yaw = atan2(-want.x, -want.z)
		_aim_pitch = 0.0
	avatar.yaw = lerp_angle(avatar.yaw, _aim_yaw, clampf(delta * 8.0, 0.0, 1.0))
	avatar.pitch = lerpf(avatar.pitch, _aim_pitch, clampf(delta * 8.0, 0.0, 1.0))
	# Stuck detection (the avatar's own move_and_slide ran last frame).
	if want.length() > 0.1:
		var moved: float = Vector2(p.x, p.z).distance_to(before)
		# `before` is this frame's start — compare against the previous
		# frame's position kept on the avatar instead.
		var prev: Vector3 = avatar.get_meta("bot_prev", p)
		if Vector2(prev.x, prev.z).distance_to(Vector2(p.x, p.z)) < 0.5 and moved < 0.5:
			_stuck_t += delta
		else:
			_stuck_t = 0.0
		if _stuck_t > 0.6:
			_stuck_t = 0.0
			_evade_t = 0.8
			_evade_dir = -1.0 if _rng.randf() < 0.5 else 1.0
			if _target == null:
				_pick_goal()
	avatar.set_meta("bot_prev", p)

## Roam target: a health/armor spot when hurt, otherwise any untaken
## item spot or a spawn point; nothing else on this map → a random
## point some way off.
func _pick_goal() -> void:
	_goal_t = _rng.randf_range(6.0, 12.0)
	_has_goal = false
	var p: Vector3 = avatar.global_position
	var me: Dictionary = Net.players.get(avatar.net_id, {})
	var hurt: bool = float(me.get("hp", 100.0)) < 45.0
	var options: Array = []
	for key in Net.pickups:
		var pk: Dictionary = Net.pickups[key]
		if bool(pk["taken"]):
			continue
		var si: int = int(pk["si"])
		var is_heal: bool = (si >= 27392 and si <= 27402)
		if hurt and not is_heal:
			continue
		var pos: Vector3 = pk["pos"]
		var d: float = pos.distance_to(p)
		if d > 150.0 and d < 9000.0:
			options.append([d if hurt else d * _rng.randf_range(0.5, 1.5), pos])
	if options.is_empty():
		for sp in Net.spawn_points:
			var pos: Vector3 = sp["pos"]
			var d: float = pos.distance_to(p)
			if d > 300.0:
				options.append([d * _rng.randf_range(0.5, 1.5), pos])
	if options.is_empty():
		var a: float = _rng.randf() * TAU
		_goal = p + Vector3(cos(a), 0.0, sin(a)) * 1500.0
		_has_goal = true
		return
	options.sort_custom(func(x, y) -> bool: return x[0] < y[0])
	_goal = options[mini(_rng.randi() % 3, options.size() - 1)][1]
	_has_goal = true

# --- combat ------------------------------------------------------------

func _aim_and_fire(delta: float) -> void:
	_fire_cd -= delta
	if _target == null or not is_instance_valid(_target):
		_burst_left = 0
		return
	_target_seen_t += delta
	if _target_seen_t < 0.0:
		return                                   # still reacting
	if _burst_pause > 0.0:
		_burst_pause -= delta
		return
	if _fire_cd > 0.0:
		return
	# Only shoot when actually facing the target and it is in view.
	var d: Vector3 = _actor_eye(_target) - avatar.eye()
	var want_yaw: float = atan2(-d.x, -d.z)
	if absf(wrapf(want_yaw - avatar.yaw, -PI, PI)) > deg_to_rad(12.0):
		return
	if not _can_see(avatar.eye(), _target):
		return
	var w: Dictionary = game.weapon_record(avatar.weapon_idx)
	var rate: float = float(w.get("rate", 4))
	_fire_cd = 1.0 / maxf(rate, 1.0)
	if _burst_left <= 0:
		_burst_left = 3 + int(_rng.randi() % 4)
	_burst_left -= 1
	if _burst_left <= 0:
		_burst_pause = float(SKILL[skill][2]) * _rng.randf_range(0.7, 1.4)
	# Spread grows with distance a little and shrinks with skill.
	var spread: float = deg_to_rad(float(SKILL[skill][0])) * _rng.randf_range(0.3, 1.0)
	var dir: Vector3 = d.normalized()
	var basis := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
	var a: float = _rng.randf() * TAU
	dir = (basis * Vector3(cos(a) * spread, sin(a) * spread, -1.0)).normalized()
	var from: Vector3 = avatar.eye() + dir * 40.0
	Net.bot_fire(avatar.net_id, avatar.weapon_idx, from, dir)
	# The actual hit: same ray the player uses.
	var hit := _cast(from, from + dir * 60000.0, true)
	if not hit.has("collider"):
		return
	var n: Node = hit["collider"] as Node
	while n != null and not n.has_method("net_damage") and not n.has_method("take_damage"):
		n = n.get_parent()
	if n == null or n == avatar:
		return
	var dmg: float = float(w.get("dmg", 10.0)) * float(SKILL[skill][3])
	if n.has_method("net_damage"):
		n.net_damage(dmg, avatar)
	elif n.has_method("take_damage"):
		n.take_damage(dmg)
