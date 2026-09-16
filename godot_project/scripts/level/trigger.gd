## A proximity trigger, and the thing that watches the player for it
## (docs/trigger_graph_plan.md §4, migration step 5c).
##
##   0xEF  gate, 60 units (v1.01 handler 0x1386a0): the doorway gates
##         that arm an exit, the wall buttons, the invisible floor
##         triggers. The handler runs only in the frame ACTIVATE goes
##         down, casts no ray, never looks at its own enable bit, and
##         forces that bit back on inside ObjFlipLink.
##   0xF1  chain trigger, radius from the slot's +4 word — 256
##   0xF2  the same handler (v1.01 0x138223), radius 1024: MAP.220's
##         only objective hangs off one of these, 1024 units from the road
##
## Both handlers measure the TRUE 3D distance (0x14d775) between the
## entity and the EYE — the camera position, globals [0xd49b4/b8/bc] —
## and nothing else: no ray, no line of sight, no vertical window.
##
## Until step 5c this class was a pair of arrays swept from
## scripts/action_system.gd. The node is the sweep now. What it holds is
## where the trigger stands, how far it reaches, whether the player was
## inside it on the last tick and whether the key has already reached it
## this press. What it does NOT hold is the trigger's state: the enable
## bit, the act byte and the link belong to the level's trigger runtime
## (scripts/triggers/trigger_runtime.gd) and are written only there.
##
##   Trigger (this)        Area3D at the DOS position
##   +- Shape              CylinderShape3D, the bake's own — and asleep:
##                         the measure below is evaluated every tick, an
##                         overlap never is (plan §2, so the runtime, the
##                         verifier and the lock share one metric)
##   +- Mesh (buttons)     the panel, with its own Solid body for the
##                         use-key ray
##
## Every position that comes in or goes out here is ZONE-LOCAL — the DOS
## coordinates the records are in, which is what `position` holds. The
## caller takes the world position into that space once (ActionSystem's
## zone_origin).

extends Area3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")

@export var id: int = 0
@export var act: int = 0xEF
@export var mesh_name: String = ""
## The DOS radius in world units, as the bake read it off the slot. What
## the player is measured against is `measure()` — the same radius plus
## the port's capsule pad for an 0xEF.
@export var radius: float = 60.0
## A wall button (variant-1 mesh with state bit 3): operated with the
## use key, never by walking past — the port's rule, kept.
@export var use_key: bool = false
## DOS state byte: bit 0 = enabled. An 0xEF gate never checks it (the
## handler only looks at bits 1-2), and ObjFlipLink forces it back on.
## The byte the MAP was AUTHORED with; the live one is the runtime's.
@export var state: int = 0
@export var targets: Array[NodePath] = []

## The Behaviour branch this hangs under (scripts/level/behaviour.gd):
## where the trigger runtime and the chain walk are reached. Null for a
## branch nobody plays — the editor opening a baked scene — and then the
## baked bytes above are all there is.
var branch: Node = null

## The player was inside the measure on the last sweep. 0xF1/0xF2 fire on
## the way IN and not again until they have been left (a port rule: DOS
## re-fires as soon as a chain re-arms the trigger, plan §8 question 3).
var latched: bool = false
## The key has already flipped this gate during this press, so the sweep
## that runs later in the same tick must leave it alone or it would flip
## straight back.
var edge_done: bool = false
## A gate whose chain ends in a doorway has walked that chain — once per
## level instance, which is DOS's single walk (see behaviour.gate_to_exit).
var exit_walked: bool = false

# ---------------------------------------------------------------------
# The live bytes (the runtime's)
# ---------------------------------------------------------------------
func _rt() -> RefCounted:
	return branch.runtime if branch != null else null

func act_now() -> int:
	var rt := _rt()
	return int(rt.act(id)) if rt != null else act

func state_now() -> int:
	var rt := _rt()
	return int(rt.state(id)) if rt != null else state

func enabled() -> bool:
	var rt := _rt()
	return rt.enabled(id) if rt != null else (state & 1) != 0

# ---------------------------------------------------------------------
# The measure
# ---------------------------------------------------------------------
## How far this record reaches, by the act it carries NOW: the 0xEF slot's
## own 60 units plus the port's 26-unit capsule pad (the DOS player stands
## where the port's capsule cannot, and the maps put gates 32..79 units
## from the doorway sprite they guard), or the +4 word of an 0xF1/0xF2.
func measure() -> float:
	var a: int = act_now()
	if a == Rules.ACT_PROX_CHAIN_A:
		return Rules.PROX_CHAIN_A_RADIUS
	if a == Rules.ACT_PROX_CHAIN_B:
		return Rules.PROX_CHAIN_B_RADIUS
	return Rules.PROX_GATE_RADIUS + Rules.PLAYER_RADIUS

## DOS measures the TRUE 3D distance from the eye. The port measured it
## horizontally with a ±512 vertical window, so the ring of gates round
## the jeep on MAP.250 fired mission 5's [M1] from 143 units under the
## quay — the mission ended in the water and the flooded sewers (MAP.254)
## could be skipped entirely.
func inside(eye: Vector3) -> bool:
	return position.distance_to(eye) <= measure()

## Does this record have a proximity measure of its own as it stands? The
## 0xEF handler (0x1386a0) runs only for a state byte whose bits 1-2 are
## both clear or both set: a prop that carries the "act on death" bit
## alone is NOT a gate — the DESK0S of MAP.461 (state 04, HP 50) or a
## stacked crate on MAP.213 fires its chain from ObjHit when it breaks,
## and walking past it does nothing.
func runs() -> bool:
	var a: int = act_now()
	if a == Rules.ACT_PROX_CHAIN_A or a == Rules.ACT_PROX_CHAIN_B:
		return true
	if a != Rules.ACT_PROX_GATE:
		return false
	var bits: int = state_now() & 6
	return bits == 0 or bits == 6

## Is the entity this node was BAKED from one the handler ever runs for?
## The sweep list is fixed when the level is built, from the authored
## bytes, exactly as ActionSystem's `_prox` was.
func on_sweep() -> bool:
	if act == Rules.ACT_PROX_CHAIN_A or act == Rules.ACT_PROX_CHAIN_B:
		return true
	if act != Rules.ACT_PROX_GATE:
		return false
	var bits: int = state & 6
	return bits == 0 or bits == 6

## The one rule of the port's own the owner kept (2026-09-15): a NAMED
## variant-1 mesh whose state byte carries bit 3 is a wall button, and it
## answers the use key instead of the player walking past it. DOS knows no
## such thing — its 0xEF/0xF1/0xF2 handlers all measure the player and
## fire — but a panel you brush past and set off by accident reads as a
## bug, so these come off the proximity sweep and go on the key (the
## crosshair ray through an ActionTarget, or behaviour.use_nearby).
## "Instead of proximity" is the whole of it, so no radius limits one:
## what does is the 600-unit crosshair (RulesSkynet.USE_RAY) that found
## the mesh. MAP.210's base doors are opened by a BUTTON01 three hundred
## units up a tower wall, which no proximity radius in the original
## reaches.
## (An UNNAMED variant-1 record with the same state byte is an invisible
## floor trigger — MAP.231's elevator call points sit at the back wall of
## the cab, state 0x09, no mesh at all — and stays on the sweep.)
##
## `use_key` is the bake's answer from the authored byte; this is the
## same test on the live one. The half of it that is the record's — a
## variant-1 mesh with a name — is read off the record itself, which is
## read-only data and says name_index, not the resolved string.
func is_wall_button() -> bool:
	if (state_now() & 8) == 0:
		return false
	var e = branch.record_of(id) if branch != null else null
	if e != null:
		return (int(e.flags) & 3) == 1 and int(e.name_index) >= 0
	return use_key or not mesh_name.is_empty()

# ---------------------------------------------------------------------
# What sets it off
# ---------------------------------------------------------------------
## One tick of this trigger. `eye` is where the DOS handlers measure from
## — the camera position — in zone-local coordinates; `use_edge` is true
## in the frame the use key went down (ActionSystem.press_use).
##
## DOS: the 0xEF handler never looks at bit 0 — every gate is live
## (MAP.215's silo cover opens from a CORC3229 piece whose state is 0x10)
## — but it runs only in the frame ACTIVATE goes down. The port had them
## fire on approach, so the jeep drove into MAP.220's truck by itself.
## 0xF1/0xF2 watch the player's presence instead, and the radii differ:
## MAP.220's mission objective hangs off an 0xF2 button 1024 units from
## the road, which is how that jeep mission ends.
func prox_watch(eye: Vector3, use_edge: bool) -> void:
	var here: bool = inside(eye)
	var a: int = act_now()
	if a == Rules.ACT_PROX_GATE:
		# The key, not the approach. A gate whose chain ends in an exit is
		# the use key's way through and goes by ActionSystem.activate_teleport.
		if use_edge and here and not edge_done and _chain_exit() < 0:
			print("[action] gate @%05x used at %s" % [id, position])
			flip()
		return
	# 0xF1/0xF2 are ONE-SHOT. Their handler (v1.01 0x138223) ends by
	# calling 0x139644 with dl = 0xFE, bl = 0 — `state &= 0xFE`, i.e. the
	# trigger clears its own enable bit and stays off until a chain turns
	# it back on. The port used to re-arm it every time the player left the
	# radius, so walking back to MAP.210's gate flipped BIGDOOR again and
	# shut it in his face ("potom sa zasa zavrie a nedá sa tam dostať").
	# 0xEF gates are different: they force their own bit back on.
	var chain_trigger: bool = a == Rules.ACT_PROX_CHAIN_A or a == Rules.ACT_PROX_CHAIN_B
	if chain_trigger and not enabled():
		return
	if here and not latched:
		latched = true
		print("[action] gate @%05x (act %02x) tripped at %s" % [id, a, position])
		# DOS order: ObjFlipLink from the trigger — which toggles the
		# trigger itself as well — then `state &= 0xFE`.
		flip()
		if chain_trigger:
			_clear_enable()
	elif not here and latched:
		latched = false

## The use key reached this record — through the crosshair ray that found
## its mesh, or through the nearest-button fallback.
##
## A PROXIMITY record is measured wherever the key reaches it: its DOS
## handler runs for a player inside the radius the slot carries and for no
## one else, and that holds whichever way the port's key arrived. Without
## it the key operated a gate from anywhere the ray could see it, 600
## units away (M3 step 4: port_use_reach). `eye` is Vector3.INF when the
## caller has picked both the entity and the place and says so
## (TriggerEquiv.activate, the solver).
##
## A WALL BUTTON is the exception, and it is the whole of the kept rule:
## proximity is not its measure — what limits it is the crosshair that
## found it. Records that are not proximity types keep the port's
## aim-and-press rule as it was: the ray is all they have ever had.
func prox_use(eye: Vector3) -> bool:
	var a: int = act_now()
	var measured: bool = runs()
	if eye.is_finite() and not is_wall_button() and measured:
		if not inside(eye):
			return false
	# Levers, buttons and proximity gates (0xEF/0xF1/0xF2) are use-key
	# operated in DOS — the tower lever opens the base gate — even though
	# their state byte carries no "act on hit" bit.
	#
	# A CUE no chain points at used to be in this list as well: a hint the
	# player could read by pressing the key at it (MAP.280's doorway
	# sprite), narrowed on 2026-09-07 to keep objectives out of it after
	# MAP.252's picture finished mission 5 from the cabin wall. The owner
	# retired the whole rule on 2026-09-15 — DOS has no use-key path to a
	# cue at all, and his own DOS run of mission 5 reaches neither the
	# picture nor the hint beside it. They are unreachable there too.
	if (state_now() & 2) == 0 and not measured:
		return false
	# 0xF1/0xF2 are one-shot in DOS (they clear their own bit 0 when they
	# fire): once spent, the use key must not flip the chain back either,
	# or pressing F at MAP.210's lever after it tripped would shut the gate
	# again.
	var chain_trigger: bool = a == Rules.ACT_PROX_CHAIN_A or a == Rules.ACT_PROX_CHAIN_B
	if chain_trigger and not enabled():
		return false
	if a == Rules.ACT_PROX_GATE:
		# A gate whose chain ends in an exit (the truck DOOR in MAP.211/212,
		# the bunker doorway gates) is the use-key way through: the exit is
		# armed and taken, wherever its sprite sits.
		if _chain_exit() >= 0:
			return bool(branch.use_exit_through(self))
		# The gate the key was aimed at: flipped here, so the sweep later in
		# the tick must leave it alone or it would flip straight back.
		edge_done = true
	# DOS order is ObjFlipLink and then the entity's own ObjDoAction. For
	# these three slots that second call does nothing: they are per-tick
	# handlers, dispatched from the sweep above, and ObjDoAction returns
	# for them (action_system._do_action).
	flip()
	if chain_trigger:
		_clear_enable()                      # after the flip, as 0x138223 does
	return true

## The spawn point already lies inside this trigger: it waits for the
## player to step out and back in instead of firing where he stands.
func prox_arm(eye: Vector3) -> void:
	if inside(eye):
		latched = true

## Walk this trigger's chain — ObjFlipLink from itself.
func flip() -> void:
	if branch != null:
		branch.flip_chain(id)

## A gate whose chain ends in a doorway walks that chain ONCE per level
## instance, which is DOS's single walk and everything on it (the door
## sound above all). See behaviour.use_exit_through for why it is once.
func walk_once() -> void:
	if exit_walked:
		return
	exit_walked = true
	flip()

## Everything this node remembers about the player, forgotten — what the
## verifier clears between two checks of the same map, since a check must
## not start with the player already "inside" a trigger he was standing in.
func prox_forget() -> void:
	latched = false
	edge_done = false
	exit_walked = false

## `state &= 0xFE` — what a one-shot handler does to itself when it has
## fired. The runtime is the only thing that writes a state byte (step 5a).
func _clear_enable() -> void:
	var rt := _rt()
	if rt != null:
		rt.clear_enable(id)

## The first 0xF0 exit down this trigger's chain, or -1.
func _chain_exit() -> int:
	return branch.chain_exit(id) if branch != null else -1
