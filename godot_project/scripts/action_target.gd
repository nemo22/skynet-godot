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

func take_damage(amount: float) -> void:
	if _action != null:
		_action.on_player_hit(_file_off, amount)

func activate() -> void:
	if _action != null:
		_action.on_player_activate(_file_off)
