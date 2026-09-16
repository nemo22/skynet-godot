## A variant-1 mesh wired into the action system — a door/gate leaf, a
## destructible car, a wall button, a generator … Replaces the old
## door.gd/switch.gd pair, which was built on the (disproved) theory
## that DOS doors animate by .3D frame swap; the real DOS model routes
## everything through ObjHit/ObjFlipLink/ObjDoAction (action_system.gd).
##
## Collision comes from the trimesh StaticBody main.gd bakes onto every
## entity child; as it is a child of this node it follows mover motion.
## The player's hitscan and Activate rays parent-walk to take_damage()/
## activate(), which route into the action system by entity file offset.

extends MeshInstance3D

var _action: RefCounted = null    # ActionSystem
var _file_off: int = -1

func setup_action(action: RefCounted, file_off: int) -> void:
	_action = action
	_file_off = file_off
	add_to_group("hittable")          # blast damage from projectiles/grenades

func file_off() -> int:
	return _file_off

## True for targets that lose HP or step through destruction stages —
## what a grenade should burst on. Doors, gates and buttons are wired
## into the action system too but only react to hits, they do not break.
func is_damageable() -> bool:
	if _action == null:
		return false
	return bool(_action.call("is_damageable_off", _file_off))

func take_damage(amount: float) -> void:
	if _action != null:
		_action.on_player_hit(_file_off, amount)

## The crosshair found this mesh and the key went down.
##
## Where the player stands goes with it: a proximity record (an 0xEF gate,
## an 0xF1/0xF2 lever) is measured by its own handler, and the ray that
## found this mesh walks 600 units — further than anything in the original
## reaches (action_system.on_player_activate).
##
## And the answer comes back, so a press that found only scenery under the
## crosshair is not swallowed: every mesh of the map is an action target,
## the floor plate the player is standing on included, and fly_camera
## _try_activate falls through to the gates and doorways around him.
func activate() -> bool:
	if _action == null:
		return false
	var pl := get_tree().get_first_node_in_group("player")
	var at: Vector3 = (pl as Node3D).global_position if pl is Node3D else Vector3.INF
	# fly_camera.dos_point: where the DOS engine has the player when it
	# measures a distance to him — the eye on foot.
	var eye: Vector3 = pl.call("dos_point") if pl != null and pl.has_method("dos_point") else at
	return bool(_action.on_player_activate(_file_off, at, eye))
