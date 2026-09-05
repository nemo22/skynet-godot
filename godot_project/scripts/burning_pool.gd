## The pool of burning fuel a molotov leaves behind. Anything standing in
## it — the player included — takes damage every second until it goes
## out. ENHANCED draws it with the same shader flame the map's fires use
## (fire_effect.gd); DOS/RETRO keeps to the sprite puffs the original
## engine had, so the look matches the render mode.
##
## The molotov itself is DOS weapon record 15, ammo pool 6 — the item the
## engine selects as the secondary by default (0x44396). Its blast is
## small; the fire is what the bottle is for.

extends Node3D

const FireEffect := preload("res://scripts/fire_effect.gd")
const Explosion := preload("res://scripts/explosion.gd")
const FxParticles := preload("res://scripts/fx_particles.gd")

const BURN_TIME: float = 5.0
const TICK: float = 1.0                 # damage interval
const FIRE_SPRITE: int = 27659          # 216_011 — a flame billboard
const FLAME_SPOTS: int = 4

var _left: float = BURN_TIME
var _tick: float = 0.0
var _radius: float = 200.0
var _dps: float = 20.0
var _owner: Node = null

## `at` is the impact point, `radius` how far the fuel spread, `blast`
## the item's direct damage (a second of burning does a third of it).
func setup(at: Vector3, radius: float, blast: float, thrower: Node) -> void:
	add_to_group("projectile")           # cleared on a map change
	_radius = maxf(radius, 60.0)
	_dps = maxf(blast, 30.0) * 0.33
	_owner = thrower
	# Fuel runs down to the floor: the bottle bursts against a wall or a
	# railing and the pool used to hang there in the air, scorch discs
	# and all (Marek, 2026-09-05). No floor within reach — no pool.
	var floor_y: float = _floor_under(at)
	if is_nan(floor_y):
		_left = 0.0
		global_position = at
		return
	global_position = Vector3(at.x, floor_y + 0.5, at.z)
	if Render.enhanced():
		# A few low flames spread over the puddle rather than one tall fire.
		for i in FLAME_SPOTS:
			var a: float = TAU * float(i) / float(FLAME_SPOTS) + randf()
			var r: float = _radius * 0.5 * sqrt(randf())
			var f := FireEffect.new()
			add_child(f)
			f.position = Vector3(cos(a) * r, 0.0, sin(a) * r)
			f.setup(FIRE_SPRITE, _radius * 0.45, _radius * 0.55, i * 7 + 3, "pool")
	else:
		var ex := Explosion.new()
		add_child(ex)
		ex.setup(at, _radius * 0.9, 356)

## Y of the floor under `at` (up to 40 u above it, 320 below), NAN when
## there is none.
func _floor_under(at: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	if space == null:
		return at.y
	var q := PhysicsRayQueryParameters3D.create(at + Vector3(0.0, 40.0, 0.0), at - Vector3(0.0, 320.0, 0.0))
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.has("position"):
		return float((hit["position"] as Vector3).y)
	return NAN

func _physics_process(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		queue_free()
		return
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = TICK
	var here: Vector3 = global_position
	for e in get_tree().get_nodes_in_group("enemy"):
		if e is Node3D and e.has_method("take_damage") \
				and (e as Node3D).global_position.distance_to(here) < _radius:
			e.take_damage(_dps)
	for a in get_tree().get_nodes_in_group("dm_actor"):
		if a is Node3D and a != _owner and a.has_method("net_damage") \
				and (a as Node3D).global_position.distance_to(here) < _radius:
			a.net_damage(_dps, _owner)
	var pl := get_tree().get_first_node_in_group("player")
	if pl is Node3D and pl.has_method("take_damage") \
			and (pl as Node3D).global_position.distance_to(here) < _radius:
		pl.take_damage(_dps * 0.6)
