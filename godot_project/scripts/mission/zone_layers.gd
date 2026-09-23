## The render and physics layers that keep the zones of a mission scene
## apart.
##
## A mission scene holds every map of a mission at once (scripts/
## mission_scene.gd). The zones used to be kept apart by DISTANCE — 16 384
## units of empty space between them, and a whole 65 536-unit slot for an
## outdoor world — which made the scene a long thin line in the editor and
## left every ray, light and body free to reach the next zone had it been
## any nearer. They are kept apart by LAYERS now, and the space between
## them is only a small fixed gap (MissionScene.GAP):
##
##   render  zone k draws on layer k + 2 (2..20). The camera sees layer 1
##           (the player's own things: the weapon, the cockpit, the
##           automap grid) and the active zone's layer, and nothing else;
##           a zone's lights and decals reach its own layer only. The
##           camera's cull mask is switched at the doorway.
##   physics zone k's bodies, areas and movers are on its own bit — layer
##           1 for the first zone (so a one-zone mission, and the per-map
##           runtime, are exactly what they were), then 2, 3, 4, 6, 7 …
##           (5 is FURNITURE, main.FURNITURE_LAYER). The player's body,
##           every query the game casts and everything spawned into the
##           world at run time (shots, grenades, debris) take the active
##           zone's bit, so no ray, body or projectile can meet another
##           zone's world.
##
## The one thing that cannot have a bit per zone is the furniture: two
## bits per zone would be 34 for mission 5's seventeen zones, and a body
## has 32. It keeps the shared FURNITURE bit, which no body's mask names
## (only rays hit it), and a sleeping zone's furniture is taken off it
## until the zone is walked into again (park / unpark).
##
## Outside a mission scene nothing here changes anything: `on` is false,
## every mask comes back as it went in, and the queries keep the all-bits
## mask they always had.
extends RefCounted

## Layer 1: what belongs to the player's view and is drawn in every zone.
const SHARED_RENDER: int = 1
## Godot has 20 render layers; layer 1 is the shared one.
const RENDER_ZONES: int = 19
## Physics layer 1: what every body of the per-map runtime sits on.
const WORLD_BIT: int = 1
## main.FURNITURE_LAYER — a prop the player walks through but a shot hits.
const FURNITURE_BIT: int = 1 << 4
## Every physics bit a zone can be given (all but FURNITURE_BIT).
const ALL_SOLID: int = 0xFFFFFFFF & ~FURNITURE_BIT
## Every render layer a zone can be given (2..20).
const ALL_ZONE_RENDER: int = ((1 << 20) - 1) & ~SHARED_RENDER
## What an unmasked query hits (Godot's default mask).
const ALL_BITS: int = 0xFFFFFFFF
## The meta a zone node carries its index under.
const META := &"zone_index"
const PARKED := &"zone_parked_layer"

## A mission scene is up.
static var on: bool = false
## The zone the player is in (its index), -1 before the first one.
static var active: int = -1
## The player: his subtree is the shared view and is left on layer 1.
static var player_root: Node = null

## The physics bit of zone `k`: layers 1, 2, 3, 4, 6, 7 … 32.
static func solid_bit(k: int) -> int:
	if k < 0:
		return WORLD_BIT
	var layer: int = k + 1 if k < 4 else k + 2
	if layer > 32:
		push_warning("[zones] zone %d has no physics layer of its own (31 is the most)" % k)
		layer = 32
	return 1 << (layer - 1)

## The render layer of zone `k`: layers 2..20.
static func render_bit(k: int) -> int:
	if k < 0:
		return SHARED_RENDER
	if k >= RENDER_ZONES:
		push_warning("[zones] zone %d shares render layer %d (19 zones is the most)"
			% [k, (k % RENDER_ZONES) + 2])
	return 1 << ((k % RENDER_ZONES) + 1)

## The mask a query of the running game casts with: the active zone's
## bodies and the furniture — everything, outside a mission scene.
static func world_mask() -> int:
	if not on or active < 0:
		return ALL_BITS
	return solid_bit(active) | FURNITURE_BIT

## What the camera draws.
static func cull_mask() -> int:
	if not on or active < 0:
		return (1 << 20) - 1
	return SHARED_RENDER | render_bit(active)

## `bits` with the default world bit moved onto zone `k`'s. A body that
## is already on a zone's bit keeps it.
static func translate(bits: int, k: int) -> int:
	if bits & WORLD_BIT and k > 0:
		return (bits & ~WORLD_BIT) | solid_bit(k)
	return bits

## `bits` moved from whichever zone they were on onto zone `k`'s — for
## what follows the player from zone to zone.
static func retarget(bits: int, k: int) -> int:
	if bits & ALL_SOLID:
		return (bits & ~ALL_SOLID) | solid_bit(k)
	return bits

## The zone index `n` stands in: its nearest zone ancestor's, -1 when it
## stands in none.
static func zone_of(n: Node) -> int:
	var p: Node = n
	while p != null:
		if p.has_meta(META):
			return int(p.get_meta(META))
		p = p.get_parent()
	return -1

## Put ONE node on zone `k`'s layers (its children are theirs to be put).
static func fit_one(n: Node, k: int) -> void:
	if n is VisualInstance3D:
		(n as VisualInstance3D).layers = render_bit(k)
		if n is Light3D:
			# Its own zone and the player's view (the cockpit is lit too).
			(n as Light3D).light_cull_mask = render_bit(k) | SHARED_RENDER
		elif n is Decal:
			(n as Decal).cull_mask = render_bit(k)
	if n is CollisionObject3D:
		var co := n as CollisionObject3D
		co.collision_layer = translate(co.collision_layer, k)
		co.collision_mask = translate(co.collision_mask, k)

## Put `root` and everything under it on zone `k`'s layers.
static func fit(root: Node, k: int) -> void:
	if root == null:
		return
	fit_one(root, k)
	for c in root.get_children():
		fit(c, k)

## A node that has just entered the tree (SceneTree.node_added): it takes
## its zone's layers, or the active zone's when it stands in none — a shot
## or an explosion under Main is where the player is. The player's own
## subtree is the shared view and is left alone.
static func adopt(n: Node) -> void:
	if not on or not (n is VisualInstance3D or n is CollisionObject3D):
		return
	var k: int = zone_of(n)
	if k < 0:
		if player_root != null and is_instance_valid(player_root) \
				and (n == player_root or player_root.is_ancestor_of(n)):
			return
		k = active
	if k >= 0:
		fit_one(n, k)

## Does `n` stand in a zone that is not the active one? Radius-based
## effects (blasts) skip what sleeps in another zone.
static func asleep(n: Node) -> bool:
	if not on or n == null:
		return false
	var k: int = zone_of(n)
	return k >= 0 and k != active

## The furniture of a zone that goes to sleep comes off the shared bit…
static func park(root: Node) -> void:
	if root == null:
		return
	if root is CollisionObject3D:
		var co := root as CollisionObject3D
		if co.collision_layer & FURNITURE_BIT:
			co.set_meta(PARKED, co.collision_layer)
			co.collision_layer = co.collision_layer & ~FURNITURE_BIT
	for c in root.get_children():
		park(c)

## …and back on it when the zone wakes.
static func unpark(root: Node) -> void:
	if root == null:
		return
	if root is CollisionObject3D and root.has_meta(PARKED):
		(root as CollisionObject3D).collision_layer = int(root.get_meta(PARKED))
		root.remove_meta(PARKED)
	for c in root.get_children():
		unpark(c)

## No mission scene: back to the per-map picture.
static func reset() -> void:
	on = false
	active = -1
	player_root = null
