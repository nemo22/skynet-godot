## A burning debris chunk flung from a destroyed robot. Flies ballistically
## under gravity, tumbling, and detonates in a small explosion when it
## strikes the ground. Add to the scene, then setup().

extends Node3D

const Explosion := preload("res://scripts/explosion.gd")

const GRAVITY: float = 2600.0
const MAX_LIFE: float = 3.5

var _vel: Vector3 = Vector3.ZERO
var _life: float = MAX_LIFE
var _spin: Vector3 = Vector3.ZERO
var _mi: MeshInstance3D = null

## Launch a chunk from `at` with initial velocity `vel` (units/sec).
func setup(at: Vector3, vel: Vector3) -> void:
	global_position = at
	_vel = vel
	_spin = Vector3(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0),
		randf_range(-8.0, 8.0))
	_mi = MeshInstance3D.new()
	var bm := BoxMesh.new()
	var s := randf_range(28.0, 64.0)
	bm.size = Vector3(s, s * randf_range(0.4, 1.0), s * randf_range(0.4, 1.0))
	_mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.32, 0.30, 0.34)      # scorched metal
	_mi.material_override = mat
	add_child(_mi)

func _physics_process(delta: float) -> void:
	_life -= delta
	_vel.y -= GRAVITY * delta
	_mi.rotation += _spin * delta
	var to := global_position + _vel * delta
	# Detonate on striking solid geometry along this step's path.
	var space := get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(global_position, to)
		var hit := space.intersect_ray(q)
		if hit.has("position"):
			_detonate(hit["position"])
			return
	global_position = to
	if _life <= 0.0:
		_detonate(global_position)

func _detonate(at: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene != null:
		var ex := Explosion.new()
		scene.add_child(ex)
		ex.setup(at, randf_range(140.0, 240.0))
	Audio.play_sfx_3d("EXPLO1.RAW", at, -9.0)
	queue_free()
