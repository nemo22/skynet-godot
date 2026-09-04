## A placed mesh that reacts to being hit: it has hit points (crates
## with their 50 HP and ammo drop, buses, the generator), or its state
## byte says a hit fires its chain (a lever, a panel that is not a
## proximity trigger). Nothing else about it moves.
##
## DOS ObjHit (skynet_gh.c:39475): the HP drains on every hit whatever
## the state bits say; bit 1 fires the chain on every hit, bit 2 once
## the HP is gone. At zero HP the link record's destruction type picks
## the blast, the drop and the sound (Skynet.exe 0x423d6).
##
##   Damageable (this)     StaticBody3D at the DOS position and rotation
##   +- Mesh
##   +- Shape              the shared trimesh
##
## F1 (2026-09-05): generated and inert — action_system.gd still runs
## the records.

extends StaticBody3D

@export var id: int = 0
## Usually 0; kept when the record carries an id no other node claims.
@export var act: int = 0
@export var mesh_name: String = ""
@export var hp: int = 0
## DOS state byte: bit 1 = act on every hit, bit 2 = act when the HP
## runs out, bit 3 = use key.
@export var state: int = 0
@export var destroy_type: int = 0
@export var destroy_param: int = 0
@export var targets: Array[NodePath] = []
