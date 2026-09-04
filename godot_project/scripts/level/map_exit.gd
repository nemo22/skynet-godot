## A map exit — the DOS interior teleport, act 0xF0 (handler 0x137881).
##
## The entity is the doorway sprite of a truck, a bunker, a lift shaft.
## Its chain (an 0xEF gate → a door sound → this) or the player touching
## the sprite ARMS it; the use key then changes the map: the target map
## at sub+2 (0 = back to the previous map) and the spawn-marker set at
## sub+4 (position marker N, facing marker N+1). One-shot.
##
##   MapExit (this)        Area3D at the DOS position
##   +- Shape              CylinderShape3D, the touch radius
##
## F1 (2026-09-05): generated and inert — action_system.gd still runs
## the records.

extends Area3D

@export var id: int = 0
@export var act: int = 0xF0
## Map suffix to go to (MAP.<target_map>); 0 = the previous map.
@export var target_map: int = 0
## Spawn-marker set in the target map.
@export var marker_set: int = 0
## Touch radius in world units (the port's TELEPORT_TOUCH_RADIUS).
@export var radius: float = 90.0
## DOS state byte: bit 0 = armed.
@export var state: int = 0
@export var targets: Array[NodePath] = []

func returns_to_previous() -> bool:
	return target_map == 0
