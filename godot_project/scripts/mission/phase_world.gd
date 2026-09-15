## One outdoor WORLD of a mission, and the order its variants run in.
##
## The census groups the outdoor maps a mission reaches by how much
## geometry they share: MAP.210, MAP.216 and MAP.217 are one place
## re-authored three times, so they are one world with three phases and
## exactly one zone. This node names that world and holds the phase EDGES
## (scripts/mission/phase_switch.gd) as its children, in order.
##
## A mission with a single variant still gets a world node with no edges —
## the editor then says as much, and a mission with two separate outdoor
## worlds (mission 7's city and its canyon) gets two.
@tool
extends Node3D

## The MAP the world is baked from — the zone that carries it.
@export var world_map: int = 0
## That zone, relative to THIS node.
@export var zone: NodePath = NodePath()
## Every variant in the order the mission reaches them, the base first.
@export var phase_maps: PackedInt32Array = PackedInt32Array()
