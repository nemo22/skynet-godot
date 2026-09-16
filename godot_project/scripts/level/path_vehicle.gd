## A machine that drives a path of markers — DOS AI state 11, v1.01
## handler 0x127400 (docs/trigger_graph_plan.md §4, migration step 5f).
##
## Four of them carry the campaign: the cargo truck that drives into
## MAP.210's base when the lever is thrown, MAP.260's convoy, MAP.280's
## boss chase, and the HK that lifts the player off MAP.234's roof. The
## enemy table (0x44E00) gives types 46-52 the same parameters.
##
## What the handler does in one frame: pick the path up at the first
## marker (the actor marker's own link), run at that segment's own speed,
## and at the end of the path flip whatever the last marker points at —
## the HK's CHUNK3 is mission 3's [M2]. The machine walks a straight 3D
## line from marker to marker: no terrain, no collision, no steering
## beyond the yaw it turns to face where it is going.
##
## A path RUNS while its markers carry bit 0. MAP.210's is authored off
## and a lever's chain switches it on; MAP.234's is authored on, so the HK
## is already flying when the map loads. The stop case (a marker whose bit
## is down, or a path that has run out) clears the bit down the whole
## chain, as the DOS one does, so a lever has to be thrown again.
##
## Until step 5f this class was one dictionary keyed by the actor marker's
## file offset, swept from the long loop in scripts/action_system.gd. The
## node is the vehicle now. What it holds is what one of these remembers
## between ticks — which marker it is driving at, how fast it is going and
## how fast it wants to go — and it is the only thing that moves the
## machine. What it does NOT hold is any state: the enable bits of the
## path, the links it follows and the chain it fires at the end all belong
## to the level's trigger runtime (scripts/triggers/trigger_runtime.gd)
## and are written only there.
##
## This node has no baked twin. A vehicle's record is a placement MARKER,
## and markers get no node in the bake (level_behaviour.kind_of: their
## sub-record keeps other data where a sprite keeps its act byte, so an
## enemy marker's "act" is its enemy type). So the branch builds one of
## these at registration, the way the level loader hands a mover its mesh
## — and the machine it drives is the ACTOR the loader built, held here as
## `actor`. Being registered IS being on the sweep.
##
## The numbers of the drive are not this node's either: they come from the
## rules the generated graph reads (Rules.PATH_*), so the running game and
## the graph cannot draw the line in two places.

extends Node3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")

## Stable id of this vehicle within its map — the MAP file offset of the
## actor MARKER the import read it from. The event bus and the graph name
## it by that (path@<id>); the per-map overlay carries no vehicle at all,
## because a map re-entered is re-read from disk and they start over.
var id: int = 0
## The first marker of the path: the actor marker's own link.
var head: int = 0
## The marker's enemy type (the byte a sprite keeps its act in).
var vehicle: int = -1

## The Behaviour branch this hangs under (scripts/level/behaviour.gd):
## where the trigger runtime, the MAP records and the event bus are
## reached. Null for a branch nobody plays, and then nothing here runs.
var branch: Node = null

## The machine the level loader built and placed for this marker
## (scripts/enemy.gd make_path_vehicle: no AI, no ground snap, no
## fighting — the DOS handler has no firing code at all). It hangs under
## the level's Enemies node, whose only transform is the zone origin, so
## its local position IS the zone-local one the markers are in — and it
## still reads correctly outside the tree, which is what the smoke tests
## drive it in.
var actor: Node3D = null

## The marker being driven at (0 = the path has not been picked up yet),
## and the two speeds: what the machine is doing and what this segment
## asks for. These three ARE the vehicle's memory.
var target: int = 0
var speed: float = 0.0
var target_speed: float = 0.0

# ---------------------------------------------------------------------
# The live bytes (the runtime's)
# ---------------------------------------------------------------------
func _rt() -> RefCounted:
	return branch.runtime if branch != null else null

func _enabled(off: int) -> bool:
	var rt := _rt()
	return rt != null and rt.enabled(off)

func _link(off: int) -> int:
	var rt := _rt()
	return int(rt.link(off)) if rt != null else 0

# ---------------------------------------------------------------------
# One tick
# ---------------------------------------------------------------------
## Handler 0x127400, one frame. `player_pos` is ZONE-LOCAL, like the
## actor's own position and the markers it drives to — the level's sweep
## translated it once for the whole tick.
func path_watch(delta: float, player_pos: Vector3) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	if actor.has_method("is_dead") and actor.is_dead():
		return
	if not _in_window(player_pos):
		return
	var cur = branch.record_of(target)
	if cur == null:
		# Pick the path up at its head. DOS takes the segment speed here
		# without looking at the marker's bit, so a vehicle whose path is
		# switched off creeps under a unit before the next tick brakes it.
		cur = branch.record_of(head)
		if cur == null:
			return
		target = cur.file_off
		speed = 0.0
		target_speed = Rules.PATH_SPEED_K * actor.position.distance_to(dos_pos(cur))
		# The vehicle has picked its path up — what the graph calls
		# path@<the vehicle's own marker> (M3 step 3).
		branch.say(id, "marker", "path", {"head": head, "vehicle": vehicle})
	elif not _enabled(cur.file_off):
		# The path is off (nobody has thrown the lever): brake, and clear
		# the bit down the whole chain, as the DOS stop case does.
		target_speed = 0.0
		_stop_path()
	elif actor.position.distance_to(dos_pos(cur)) <= Rules.PATH_REACH:
		var nxt = branch.record_of(_link(cur.file_off)) if _link(cur.file_off) > 0 else null
		if nxt == null:
			target_speed = 0.0
			_stop_path()
		elif (nxt.flags & 3) == 3 and nxt.marker_type >= 0 and _enabled(nxt.file_off):
			if nxt.marker_type == Rules.MARKER_PATH_LOOP:
				nxt = branch.record_of(head)
			if nxt != null:
				target_speed = Rules.PATH_SPEED_K * dos_pos(cur).distance_to(dos_pos(nxt))
				target = nxt.file_off
				cur = nxt
		else:
			# The path ends on something that is not a marker: fire it
			# once, cut the link and coast to a stop.
			print("[action] path vehicle at @%05x fires the end of its path @%05x"
				% [cur.file_off, nxt.file_off])
			branch.flip_chain(nxt.file_off)
			_rt().cut_link(cur.file_off)
			target_speed = 0.0
			return
	var to: Vector3 = dos_pos(cur) - actor.position
	if to.length() > 0.001:
		if target_speed > 0.0:
			var want: float = atan2(-to.x, -to.z)
			var turn: float = wrapf(want - actor.rotation.y, -PI, PI)
			actor.rotation.y += clampf(turn, -Rules.PATH_TURN * delta, Rules.PATH_TURN * delta)
		actor.position += to.normalized() * (speed * delta)
	var dv: float = target_speed - speed
	speed += clampf(signf(dv) * Rules.PATH_ACCEL * delta, -absf(dv), absf(dv))

## Is the machine in the 5×5 MAP-GRID cells around the player? The DOS
## engine ticks its actors by GRID CELL, not by distance (0x12980f) — see
## Rules.PATH_TICK_CELL for what the port lost by reading it as a radius.
func _in_window(player_pos: Vector3) -> bool:
	var cell: float = Rules.PATH_TICK_CELL
	var reach: int = Rules.PATH_TICK_CELLS
	return absi(floori(actor.position.x / cell) - floori(player_pos.x / cell)) <= reach \
		and absi(floori(actor.position.z / cell) - floori(player_pos.z / cell)) <= reach

## The stop case calls ObjFlipLink with "and 0xFE": the whole path goes
## off, so a lever has to switch it on again before the vehicle moves.
func _stop_path() -> void:
	var rt := _rt()
	if rt == null:
		return
	var cur = branch.record_of(head)
	var hops: int = 0
	while cur != null and hops < Rules.PATH_MAX_HOPS:
		if rt.enabled(cur.file_off):
			rt.clear_enable(cur.file_off)
		if (cur.flags & 0x40) != 0 or _link(cur.file_off) < 1:
			return
		cur = branch.record_of(_link(cur.file_off))
		hops += 1

## A MAP record's own position in the level's zone-local space (DOS Y and
## Z grow the other way).
static func dos_pos(e) -> Vector3:
	return Vector3(float(e.x), -float(e.y), -float(e.z))

# ---------------------------------------------------------------------
# The map's state overlay, and the checks
# ---------------------------------------------------------------------
## Where the machine stands and which way it faces. Not part of the save
## yet — the per-map overlay has never carried a vehicle, and a map
## re-entered puts them back at their markers, as DOS does by re-reading
## the map. What this IS for is the verifier, which checks a hundred
## nodes of one map without reloading it.
func snapshot() -> Array:
	if actor == null or not is_instance_valid(actor):
		return [Vector3.ZERO, 0.0]
	return [actor.position, actor.rotation.y]

func restore(snap: Array) -> void:
	if snap.size() < 2 or actor == null or not is_instance_valid(actor):
		return
	actor.position = snap[0]
	actor.rotation.y = float(snap[1])

## Everything this node remembers about the level's own doing, forgotten
## — the vehicle is back at the head of its path and standing still. Where
## the machine STANDS is not that: restore() puts it back.
func path_forget() -> void:
	target = 0
	speed = 0.0
	target_speed = 0.0

## One line of the console's report: what it is, where it is driving and
## how fast.
func report() -> String:
	return "@%05x type %d head %05x target %05x speed %.0f/%.0f" % [
		id, vehicle, head, target, speed, target_speed]
