## A placed mesh that reacts to being hit: it has hit points (crates
## with their 50 HP and ammo drop, buses, the generator), or its state
## byte says a hit fires its chain (a lever, a panel that is not a
## proximity trigger). Nothing else about it moves.
##
## DOS ObjHit (v1.01 0x139019): state bit 1 = fire the action on every
## hit, and it is tested BEFORE the hit points are, so a wreck goes on
## staging after its pool is gone; bit 2 = fire it on the hit that
## depletes the pool. The pool itself drains whatever the bits say, so a
## crate with state 0 still breaks and drops its ammo. At zero the link
## record's destruction type picks the blast, the drop and the sound
## (Skynet.exe 0x423d6).
##
## Act 0x1B (v1.01 handler 0x1380bf, decoded 2026-09-05) makes one of
## these a DEMOLITION target: a chain that enables it deals it HP + 1
## through ObjHit, after an HP of 0 is raised to 1 so a prop with no hit
## points goes too — so a rack of crates goes with the one you shot
## (MAP.213), the PC and chair with their desk (MAP.461), the fence ring
## with the NODE00 gate (MAP.280), the bridge rails with the button
## (MAP.260). 243 entities across 56 maps carry it.
##
##   Damageable (this)     StaticBody3D at the DOS position and rotation
##   +- Mesh
##   +- Shape              the shared trimesh
##
## Since step 5g of docs/trigger_graph_plan.md this node is where a record
## like that is FOUND: the level loader hands it the mesh it built, and
## the branch's demolition sweep runs over these. It holds no state — the
## hit points, the spent flag and the enable bits are the level's trigger
## runtime's (scripts/triggers/trigger_runtime.gd) and are written only
## there — and, unlike a wreck's damage stages, a demolition remembers
## NOTHING between ticks: the handler is one blow and its only guard is
## that the record is not already gone, which the one writer answers. So
## the work of it stays one call on the branch (Behaviour.demolish) and
## this node carries what it always did, the record's own data.

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

## The Behaviour branch this hangs under (scripts/level/behaviour.gd).
var branch: Node = null
## The mesh the level loader built and placed for this record — what the
## blast goes off at and what leaves the world when the pool runs out.
var body: Node3D = null

## The level loader has built this record's mesh: from here on it is this
## node's.
func adopt(node: Node3D) -> void:
	body = node
