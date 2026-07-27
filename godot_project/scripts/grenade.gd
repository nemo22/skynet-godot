## A grenade fired from the GRENADE LAUNCHER. Travels under gravity in
## a parabolic arc, bounces off solid surfaces, and detonates on
## contact with an enemy or after `FUSE_TIME` seconds.
##
## DOS models this as a generic projectile (`FUN_00122a64`,
## skynet_gh.c:25675) whose ammo-type entry installs a custom per-frame
## callback at `DAT_00040728+0x00` that adds gravity to the velocity
## each tick. We just bake the gravity in.

extends Node3D

const Explosion := preload("res://scripts/explosion.gd")

const GRAVITY: float = 2600.0
const FUSE_TIME: float = 2.6
const RESTITUTION: float = 0.4               # bounce energy retained
const SPEED: float = 1600.0                  # initial muzzle velocity

var _vel: Vector3 = Vector3.ZERO
var _life: float = FUSE_TIME
var _damage: float = 80.0
var _splash: float = 700.0
var _owner: Node = null
var _spin: Vector3 = Vector3.ZERO
var _mi: MeshInstance3D = null
var _exploded: bool = false

## Launch from `from` heading `dir` (unit vector). Initial speed is
## constant; `damage` and `splash` set the detonation payload.
func setup(from: Vector3, dir: Vector3, damage: float, splash: float,
		shooter: Node) -> void:
	global_position = from
	_vel = dir.normalized() * SPEED + Vector3.UP * 320.0  # slight loft
	_damage = damage
	_splash = splash
	_owner = shooter
	_spin = Vector3(randf_range(-6.0, 6.0), randf_range(-6.0, 6.0),
		randf_range(-6.0, 6.0))
	_mi = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 14.0
	sm.height = 28.0
	_mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.32, 0.45, 0.22)   # olive-drab grenade body
	_mi.material_override = mat
	add_child(_mi)

func _physics_process(delta: float) -> void:
	if _exploded:
		return
	_life -= delta
	_vel.y -= GRAVITY * delta
	if _mi != null:
		_mi.rotation += _spin * delta
	var to: Vector3 = global_position + _vel * delta
	var space := get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(global_position, to)
		q.collide_with_areas = true             # enemy hitboxes are areas
		if _owner is CollisionObject3D:
			q.exclude = [(_owner as CollisionObject3D).get_rid()]
		var hit := space.intersect_ray(q)
		if hit.has("position"):
			# Detonate on enemies; bounce off level geometry.
			var c: Node = hit.get("collider") as Node
			var n: Node = c
			while n != null and not n.has_method("take_damage"):
				n = n.get_parent()
			if n != null and n != _owner and n is Node3D \
					and n.is_in_group("enemy"):
				_detonate(hit["position"])
				return
			# Bounce: reflect velocity around the hit normal, lose energy.
			var nrm: Vector3 = hit.get("normal", Vector3.UP)
			global_position = hit["position"] + nrm * 2.0
			_vel = _vel.bounce(nrm) * RESTITUTION
			return
	global_position = to
	if _life <= 0.0:
		_detonate(global_position)

func _detonate(at: Vector3) -> void:
	_exploded = true
	Audio.play_sfx_3d("EXPLO1.RAW", at, -1.0)
	for e in get_tree().get_nodes_in_group("enemy"):
		if e is Node3D and e.has_method("take_damage"):
			var d := (e as Node3D).global_position.distance_to(at)
			if d < _splash:
				e.take_damage(_damage * (1.0 - d / _splash))
	var pl := get_tree().get_first_node_in_group("player")
	if pl is Node3D and pl != _owner and pl.has_method("take_damage"):
		var d := (pl as Node3D).global_position.distance_to(at)
		if d < _splash:
			pl.take_damage(_damage * 0.55 * (1.0 - d / _splash))
	var scene := get_tree().current_scene
	if scene != null:
		var ex := Explosion.new()
		scene.add_child(ex)
		ex.setup(at, 280.0)
	queue_free()
