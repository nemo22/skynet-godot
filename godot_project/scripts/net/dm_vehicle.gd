## A parked deathmatch vehicle (NETLEVEL.PRS `jeeps` / `hks`). The use
## key on it asks the server for the seat; while somebody drives it the
## parked body is hidden and the driver's avatar wears the vehicle model
## instead.
##
## The models are the DOS MULTIPLAYER ones, which are not the campaign's.
## This drew HUMMER.3D, and HUMMER.3D is the jeep's INTERIOR — the shell
## the port draws around the driver's eye — so a parked jeep in an arena
## was a white floor pan with a dashboard standing in the open ("net jeep
## v mp arene sa zobrazuje zle", Marek 2026-09-13, with the screenshot
## that showed it). Measured: HUMMER is 106x75x227 against HUMMERTK's
## 114x124x234, and DOS's own MP table (skynet.EXE 0x84dd4, records 13
## and 14) names NETHUMER.3D with a separate turret and barrel, and
## NET_HK.3D — the same craft as HK_FTR but with five more surfaces.
extends StaticBody3D

const MODELS: Array = ["", "NETHUMER.3D", "NET_HK.3D"]
## The jeep's roof gun, which NETHUMER does not carry itself.
const JEEP_TURRET: String = "NETHMTRT.3D"
const JEEP_BARREL: String = "NETHMBRL.3D"

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
	# The jeep's gun is two models of its own (DOS lists body, barrel and
	# turret together), and neither carries a mount point, so the turret
	# is seated on the roof from the bounds themselves: its underside goes
	# where the body's top is. Body top +52.0, turret bottom -15.2.
	if kind == 1 and am != null:
		var body_top: float = aabb.position.y + aabb.size.y      # +52 in model space
		var turret: ArrayMesh = Assets.mesh(JEEP_TURRET)
		var turret_h: float = turret.get_aabb().size.y if turret != null else 0.0
		for part in [[JEEP_TURRET, 0.0], [JEEP_BARREL, turret_h * 0.5]]:
			var pm: ArrayMesh = Assets.mesh(String(part[0]))
			if pm == null:
				continue
			var pb: AABB = pm.get_aabb()
			var mi := MeshInstance3D.new()
			mi.mesh = pm
			# The turret's underside goes on the roof; the barrel rides at
			# the turret's own half height, which is where a pintle sits.
			mi.position = Vector3(0.0,
				body_top + float(part[1]) - (pb.position.y if float(part[1]) == 0.0
					else pb.position.y + pb.size.y * 0.5), 0.0)
			_mesh.add_child(mi)
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
