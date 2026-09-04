## An entity whose action id the port has not decoded (the light
## toggles and fades 0x01..0x12, the 0xF3 family, 0x2C …), or an
## act-less entity a chain merely passes through (a relay: act 0, but a
## link to the next entity). It keeps its data and its place in the
## chain so nothing is lost and nothing is invented; plan phase F6 takes
## these ids one by one against the Skynet.exe 0x59b00 table.
##
## F1 (2026-09-05): generated and inert.

extends Node3D

@export var id: int = 0
## DOS handler id; 0 = a relay.
@export var act: int = 0
## MAP entity variant: 1 = mesh, 2 = light, 3 = sprite.
@export var variant: int = 0
@export var mesh_name: String = ""
@export var sprite_index: int = -1
## The u16 at sub+2 (variant 3) or the light intensity (variant 2).
@export var param: int = 0
@export var hp: int = 0
## DOS state byte, as read.
@export var state: int = 0
@export var targets: Array[NodePath] = []

func is_relay() -> bool:
	return act == 0
