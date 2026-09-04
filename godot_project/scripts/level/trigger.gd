## A proximity trigger — the DOS gates and chain triggers
## (docs/map_format_plan.md §2).
##
##   0xEF  gate, 60 units (handler 0x137e2e): the doorway gates that arm
##         an exit, the wall buttons, the invisible floor triggers
##   0xF1  chain trigger, 256 units (handler 0x1379c4)
##   0xF2  chain trigger, 1024 units — MAP.220's only objective hangs
##         off one of these, 1024 units from the road
##
## The DOS test is the player's body against the radius; here the
## Shape is a cylinder of that radius (the player capsule overlapping
## it adds its own radius, as the port's PLAYER_RADIUS did) and of the
## port's vertical window in height, so stacked interior floors keep
## their gates apart. When the player enters, the node flips its chain
## (ObjFlipLink) down `targets`.
##
##   Trigger (this)        Area3D at the DOS position
##   +- Shape              CylinderShape3D
##   +- Mesh (buttons)     the panel, with its own Solid body for the
##                         use-key ray
##
## F1 (2026-09-05): generated and inert — action_system.gd still runs
## the records. F2 connects body_entered.

extends Area3D

@export var id: int = 0
@export var act: int = 0xEF
@export var mesh_name: String = ""
## The DOS radius in world units.
@export var radius: float = 60.0
## A wall button (variant-1 mesh with state bit 3): operated with the
## use key, never by walking past — the port's rule, kept.
@export var use_key: bool = false
## DOS state byte: bit 0 = enabled. An 0xEF gate never checks it (the
## handler only looks at bits 1-2), and ObjFlipLink forces it back on.
@export var state: int = 0
@export var targets: Array[NodePath] = []

func is_gate() -> bool:
	return act == 0xEF
