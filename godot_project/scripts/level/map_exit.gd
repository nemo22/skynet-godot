## A map exit — the DOS interior teleport, act 0xF0 (handler 0x137881,
## v1.01 0x138081), and the thing that watches the player for it
## (docs/trigger_graph_plan.md §4, migration step 5h).
##
## The entity is the doorway sprite of a truck, a bunker, a lift shaft.
## Its chain (an 0xEF gate → a door sound → this) or the player touching
## the sprite ARMS it; the use key then changes the map: the target map
## at sub+2 (0 = back to the previous map) and the spawn-marker set at
## sub+4 (position marker N, facing marker N+1). One-shot.
##
## Until step 5h this class was a pair of arrays swept from the long loop
## in scripts/action_system.gd — the last one there, and the loop went
## with it. The node is the sweep now. What it holds is where the doorway
## stands, how far it reaches and whether the player was touching it on
## the last tick. What it does NOT hold is state: the enable bit, the act
## byte and the link belong to the level's trigger runtime
## (scripts/triggers/trigger_runtime.gd) and are written only there, and
## the one-map-change latch is the LEVEL's, not this record's
## (scripts/level/behaviour.gd exit_taken).
##
##   MapExit (this)        Area3D at the DOS position
##   +- Shape              CylinderShape3D, the touch radius — and asleep:
##                         the measure below is evaluated every tick, an
##                         overlap never is (plan §2, so the runtime, the
##                         verifier and the lock share one metric)
##
## Every position that comes in here is ZONE-LOCAL — the DOS coordinates
## the records are in, which is what `position` holds. The caller takes
## the player's world position into that space once (Behaviour.tick).

extends Area3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")

@export var id: int = 0
@export var act: int = 0xF0
## Map suffix to go to (MAP.<target_map>); 0 = the previous map.
@export var target_map: int = 0
## Spawn-marker set in the target map.
@export var marker_set: int = 0
## Touch radius in world units (Rules.TELEPORT_TOUCH_RADIUS, as the bake
## read it).
@export var radius: float = 90.0
## DOS state byte: bit 0 = armed. The byte the MAP was AUTHORED with; the
## live one is the runtime's.
@export var state: int = 0
@export var targets: Array[NodePath] = []

## The Behaviour branch this hangs under (scripts/level/behaviour.gd):
## where the trigger runtime, the one-map-change latch and the level's
## physics space are reached. Null for a branch nobody plays — the editor
## opening a baked scene — and then the baked bytes above are all there is.
var branch: Node = null

## The player was inside the touch radius on the last sweep. Touching a
## doorway arms it once, on the way in: a player standing in one would
## otherwise re-arm it every frame, and the fade the port's map change
## runs on leaves him standing there.
var touching: bool = false

# ---------------------------------------------------------------------
# The live bytes (the runtime's)
# ---------------------------------------------------------------------
func _rt() -> RefCounted:
	return branch.runtime if branch != null else null

func enabled() -> bool:
	var rt := _rt()
	return rt.enabled(id) if rt != null else (state & 1) != 0

# ---------------------------------------------------------------------
# The measure
# ---------------------------------------------------------------------
## The port's own test for STANDING IN a doorway. The TRUE 3D distance
## belongs to the DOS proximity handlers, whose radii come from the game
## data (Trigger.inside); a doorway sprite hangs above the floor the
## player walks on, so measuring it in 3D put the truck on MAP.210 out of
## reach — horizontal distance with a vertical window, as before.
func within(feet: Vector3) -> bool:
	if absf(feet.y - position.y) > Rules.PROX_VERTICAL_WINDOW:
		return false
	return Vector2(feet.x - position.x, feet.z - position.z).length() <= radius

# ---------------------------------------------------------------------
# What sets it off
# ---------------------------------------------------------------------
## One tick of this doorway, from the player's FEET (zone-local).
##
## A chain (0xEF gate → sound node → 0xF0) or touching the sprite ARMS
## the exit (state bit 0); the map change itself needs the use key — in
## DOS you walk into the truck and press use at its rear doors, nothing
## happens just by standing there.
##
## An exit a CHAIN switched on is the exception and fires the moment it is
## enabled (DOS 0x138081), on foot as well as in a vehicle: MAP.270's
## tunnel mouth (0xF1 button → 0xF0) and mission 5's TORPEDO TUBE, where
## the hatch's own chain shoots the player out into the harbour without
## another key press.
func exit_watch(feet: Vector3) -> void:
	var rt := _rt()
	if rt == null:
		return
	var here: bool = within(feet)
	if here and not touching:
		rt.arm(id)
	touching = here
	# What a chain armed earlier in THIS tick, which is what tells a
	# chain-fired exit from a touched one: a walk may already have taken
	# the bit down again (several triggers can share one chain), and DOS
	# runs each object's handler as the chain is flipped.
	if rt.armed(id):
		rt.arm(id)
		fire()

## The spawn point already lies inside this doorway: it waits for the
## player to step out and back in instead of arming where he stands.
func exit_arm(feet: Vector3) -> void:
	touching = within(feet)

## The use key at this doorway: taken when the player is standing in it
## and can see it. Nothing else has ever taken one — touching only arms it.
func use(feet: Vector3) -> bool:
	if not enabled() or not within(feet):
		return false
	if branch != null and not bool(branch.reachable(feet, position)):
		return false                         # a closed door leaf is in the way
	return fire()

## The handler itself (v1.01 0x138081): write the target map and the
## marker set, ask for the map change (`or [0x30a50], 0x20`) and clear
## its OWN bit 0 inline (`and byte [esi+edi+5], 0xfe`). It never retires
## its act and holds no latch of its own; what makes it once per level is
## the frame loop, which tests that request before the next entity sweep
## and tears the level down. The port's transition is asynchronous (a
## fade) and a player standing in a gate re-toggles the bit every frame,
## so that latch is kept out loud — on the level, where it belongs.
func fire() -> bool:
	if branch == null or bool(branch.exit_taken()) or not enabled():
		return false
	var rt := _rt()
	if rt != null:
		rt.clear_enable(id)                  # one-shot (0x137881)
	return bool(branch.take_exit(id, target_map, marker_set))

## Everything this node remembers about the player, forgotten — what the
## verifier clears between two checks of the same map.
func exit_forget() -> void:
	touching = false
