## A burning debris chunk flung from a destroyed robot. Flies ballistically
## under gravity, tumbling, and detonates in a small explosion when it
## strikes the ground. Add to the scene, then setup().

extends Node3D

const Explosion := preload("res://scripts/explosion.gd")
const ZoneLayers := preload("res://scripts/mission/zone_layers.gd")

const GRAVITY: float = 2600.0
const MAX_LIFE: float = 2.5
## The impact blast hurts a player standing next to it (DOS: the
## ballistic parts detonate like small grenades).
const HURT_RANGE: float = 240.0
const HURT_DAMAGE: float = 14.0
const SCORCHED: Color = Color(0.32, 0.30, 0.34)     # scorched metal

## The generic chunk: one unit box and one material for all of them, each
## chunk sized by its own scale.
static var _chunk_mesh: BoxMesh = null
static var _chunk_mat: StandardMaterial3D = null

var _vel: Vector3 = Vector3.ZERO
var _life: float = MAX_LIFE
var _spin: Vector3 = Vector3.ZERO
var _mi: MeshInstance3D = null
var _ray: PhysicsRayQueryParameters3D = null

## The shared generic-chunk mesh and material.
static func chunk_mesh() -> BoxMesh:
	if _chunk_mesh == null:
		_chunk_mesh = BoxMesh.new()
		_chunk_mesh.size = Vector3.ONE
	return _chunk_mesh

static func chunk_material() -> StandardMaterial3D:
	if _chunk_mat == null:
		_chunk_mat = StandardMaterial3D.new()
		_chunk_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_chunk_mat.albedo_color = SCORCHED
	return _chunk_mat

## Launch a chunk from `at` with initial velocity `vel` (units/sec).
## `part` is the DOS wreck-part mesh (enemy table death list — engine,
## fin, gun, limb …) flung off a destroyed actor; without one a generic
## scorched-metal chunk is used.
func setup(at: Vector3, vel: Vector3, part: Mesh = null) -> void:
	global_position = at
	_vel = vel
	_spin = Vector3(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0),
		randf_range(-8.0, 8.0))
	_mi = MeshInstance3D.new()
	if part != null:
		_mi.mesh = part
	else:
		var s := randf_range(28.0, 64.0)
		_mi.mesh = chunk_mesh()
		_mi.scale = Vector3(s, s * randf_range(0.4, 1.0), s * randf_range(0.4, 1.0))
		_mi.material_override = chunk_material()
	add_child(_mi)
	_ray = PhysicsRayQueryParameters3D.new()
	_ray.collision_mask = ZoneLayers.world_mask()

func _physics_process(delta: float) -> void:
	if _mi == null:
		return
	_life -= delta
	_vel.y -= GRAVITY * delta
	_mi.rotation += _spin * delta
	var to := global_position + _vel * delta
	# Detonate on striking solid geometry along this step's path.
	var space := get_world_3d().direct_space_state
	if space != null:
		_ray.from = global_position
		_ray.to = to
		var hit := space.intersect_ray(_ray)
		if hit.has("position"):
			_detonate(hit["position"])
			return
	global_position = to
	if _life <= 0.0:
		_detonate(global_position)

func _detonate(at: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene != null:
		Explosion.spawn(scene, at, randf_range(140.0, 240.0))
	Audio.play_sfx_3d("EXPLO1.RAW", at, -9.0)
	var pl: Node = get_tree().get_first_node_in_group("player")
	if pl is Node3D and pl.has_method("take_damage"):
		var d: float = (pl as Node3D).global_position.distance_to(at)
		if d < HURT_RANGE:
			pl.call("take_damage", HURT_DAMAGE * (1.0 - d / HURT_RANGE))
	queue_free()
