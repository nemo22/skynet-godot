## A destructible object — a car that wrecks in stages, a wall a ram
## punches through, a sign (docs/map_format_plan.md §2).
##
## DOS: act 0x18/0x19 (handler 0x120833) steps the mesh through the
## damage stages TRANSFRM.PRS lists for its name — act 0x19 by exactly
## one stage per qualifying hit, whatever the hit was worth, since the
## handler is passed no damage value at all; an object with no stage
## list vanishes when its HP is gone. A chain can break one outright
## (MAP.248's girder ram). The body is the hit target: the player's
## rays parent-walk from the shape to this node.
##
##   Destructible (this)   StaticBody3D at the DOS position and rotation
##   +- Mesh               stage 0 — the intact object
##   +- Shape              the shared trimesh of the intact mesh
##
## F1 (2026-09-05): generated and inert — action_system.gd still runs
## the records. F2 moves take_damage() here.

extends StaticBody3D

@export var id: int = 0
@export var act: int = 0
@export var mesh_name: String = ""
@export var hp: int = 0
## DOS state byte: bit 1 = act on every hit, bit 2 = act when the HP
## runs out (ObjHit, skynet_gh.c:39475).
@export var state: int = 0
## The TRANSFRM.PRS damage stages, [0] = intact. Empty when the name
## has no template: the object then vanishes on destruction.
@export var stages: Array[Mesh] = []
## Link-record destruction data (Skynet.exe 0x423d6 table): the effect
## sprites, the drop and the sound of the final blast.
@export var destroy_type: int = 0
@export var destroy_param: int = 0
@export var targets: Array[NodePath] = []
