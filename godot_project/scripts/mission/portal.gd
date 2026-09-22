## A DOS map exit (act 0xF0) seen as a door between two zones of one
## mission scene.
##
## In DOS the exit changes the map: the target at sub+2 (0 = back to the
## map you came from) and the spawn marker set at sub+4. With every zone
## of the mission standing in the same scene there is nothing to load —
## the player is moved from this doorway to the target zone's marker set,
## which is what `target_zone` and `target_pos` spell out.
##
## The node stands at `world_pos`, so the editor shows the doorways where
## they are. The level's own MapExit nodes stay the authority at runtime
## (scripts/level/map_exit.gd); these are the baked, readable view of the
## same table (and what step 4 resolves a teleport against).
##
## `kind` repeats the census verdict: "portal" (an exit into a zone of
## this mission), "portal (no spawn)" (the target has no such marker set),
## "return" (target 0 — back through the doorway you came in by),
## "hand-over" (the exit leads into ANOTHER mission's world, e.g. the
## flight out of mission 7) or "broken" (the target map is not there).
@tool
extends Node3D

## The MAP the exit record lives in — a phase variant of a world keeps its
## own number here (MAP.216's doorways are not MAP.210's).
@export var source_map: int = 0
## The zone that hosts `source_map`, relative to THIS node.
@export var source_zone: NodePath = NodePath()
## Offset of the entity record inside that MAP file.
@export var file_off: int = 0
## Where the doorway is: in the source zone's own coordinates, and in the
## world once the zone's origin is added.
@export var local_pos: Vector3 = Vector3.ZERO
@export var world_pos: Vector3 = Vector3.ZERO
## Exit target as the DOS record gives it: the map suffix, 0 = return.
@export var target_map: int = 0
## Spawn marker set in the target map (position N, facing N+1).
@export var marker_set: int = 0
@export var kind: String = ""
## The entity records that link INTO this exit — the chain that arms it
## ("0ca97/df" = file offset / act).
@export var armed_by: PackedStringArray = PackedStringArray()
## The zone this doorway opens into, relative to THIS node. Empty for a
## return (the zone depends on where the player came from), a hand-over
## and a broken exit.
@export var target_zone: NodePath = NodePath()
## Where the player lands: the target map's marker `marker_set`, in world
## coordinates. Vector3.INF when nothing resolves it — a return, a
## hand-over, or a marker set the target map does not carry (MAP.217 has
## no set 0).
@export var target_pos: Vector3 = Vector3.INF
## DOS state byte of the record (bit 0 = already armed).
@export var state: int = 0
