## A parked deathmatch vehicle (NETLEVEL.PRS `jeeps` / `hks`): the DOS
## HUMMER.3D / HK_FTR.3D model on a box body. The use key on it asks the
## server for the seat; while somebody drives it the parked body is
## hidden and the driver's avatar wears the vehicle model instead.
extends StaticBody3D

const MODELS: Array = ["", "HUMMER.3D", "HK_FTR.3D"]

var key: int = -1
var kind: int = 1
var driver: int = 0
var _mesh: MeshInstance3D = null

func setup(k: int, vehicle_kind: int, pos: Vector3, yaw: float) -> void:
	key = k
	kind = clampi(vehicle_kind, 1, 2)
	name = "veh_%d" % k
	add_to_group("dm_vehicle")
	_mesh = MeshInstance3D.new()
	var am: ArrayMesh = Assets.mesh(MODELS[kind])
	var aabb: AABB
	if am != null:
		_mesh.mesh = am
		aabb = am.get_aabb()
		# Wheels / skids on the ground.
		_mesh.position = Vector3(0.0, -aabb.position.y, 0.0)
	else:
		var bm := BoxMesh.new()
		bm.size = Vector3(106, 75, 227) if kind == 1 else Vector3(357, 205, 501)
		_mesh.mesh = bm
		aabb = AABB(-bm.size * 0.5, bm.size)
		_mesh.position = Vector3(0.0, bm.size.y * 0.5, 0.0)
	add_child(_mesh)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size
	cs.shape = box
	cs.position = Vector3(0.0, aabb.size.y * 0.5, 0.0)
	add_child(cs)
	place(pos, yaw)

func place(pos: Vector3, yaw: float) -> void:
	global_position = pos
	rotation.y = yaw

## Somebody took / left the seat.
func set_driver(id: int) -> void:
	driver = id
	visible = id == 0
	for c in get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).set_deferred("disabled", id != 0)

## The player's use key (fly_camera `_try_activate` walks up to this).
func activate() -> void:
	if driver == 0:
		Net.request_vehicle(key)
