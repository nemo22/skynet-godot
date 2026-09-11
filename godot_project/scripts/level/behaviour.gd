## The Behaviour branch of a level at run time (docs/map_format_plan.md
## §8, phase F2).
##
## The branch holds one node per entity with behaviour (built by
## scripts/level_behaviour.gd at import) and this script is what the
## DOS object layer becomes on top of them:
##
##   flip(id)        ObjFlipLink (FUN_001394aa): walk the chain from a
##                   node toggling bit 0 of each `state`, an 0xEF gate
##                   forcing its bit back on, stopping at an actor. A
##                   one-shot node whose bit goes UP fires at once —
##                   the DOS engine runs the handler as the chain is
##                   flipped — and clears the bit again.
##   fire()          on SoundCue, VoiceCue, MessageCue, Objective.
##   hint_message / objective_complete / mission_failed
##                   what the cues report to the game.
##
## F2 runs class by class, so while action_system.gd still drives the
## movers, triggers, exits and destructibles from the MAP records, every
## state change made here is MIRRORED into the record (bind_records) and
## restore_state pushes the records back into the nodes
## (sync_from_records). When the last class has moved, the mirror goes.

extends Node3D

const ActionSystem := preload("res://scripts/action_system.gd")

## A hint cue ([G1]..) fired: index = act - 0x1C.
signal hint_message(index: int)
## An objective cue ([M1]..) fired: index = act - 0x26.
signal objective_complete(index: int)
## The 0x2B cue fired.
signal mission_failed()

var _by_id: Dictionary = {}          # id → node
var _indexed: bool = false
var _map = null                      # MapFile.MapFile — the records mirror (F2)

func _ready() -> void:
	_ensure_index()
	# One-shots armed in the MAP data fire once at level start (a door
	# sound a map starts enabled, a radio line on entry).
	for id in _by_id:
		var n: Node = _by_id[id]
		if n.has_method("fire") and (state_of(n) & 1) != 0:
			_fire(n)

## The parsed MAP whose records still drive the classes action_system.gd
## has not handed over yet.
func bind_records(map) -> void:
	_map = map

## F2 transition: while the loader still builds the movers, the
## destructibles, the damageables and the button panels from the
## records (action targets with their own bodies), the same geometry in
## this branch must not be seen or collided with — the e2e gate sweep
## found a second, closed BIGDOOR box the moment the branch entered the
## tree. Meshes hide, shapes switch off, areas stop monitoring; the
## sound players keep playing. Narrow this as each class goes live.
static func sleep_geometry(root: Node) -> void:
	for c in root.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = false
		elif c is CollisionShape3D:
			(c as CollisionShape3D).disabled = true
		elif c is Area3D:
			(c as Area3D).monitoring = false
			(c as Area3D).monitorable = false
		sleep_geometry(c)

func _ensure_index() -> void:
	if _indexed:
		return
	_indexed = true
	for c in get_children():
		if not (c is Node3D):            # the Mission node
			continue
		for n in c.get_children():
			_by_id[id_of(n)] = n
			if n.has_signal("fired"):
				n.connect("fired", _on_cue_fired.bind(n))

## The node of entity `id` (the MAP file offset), or null.
func node(id: int) -> Node:
	_ensure_index()
	return _by_id.get(id)

## id → node for every node in the branch.
func nodes() -> Dictionary:
	_ensure_index()
	return _by_id

static func id_of(n: Node) -> int:
	if "id" in n:
		return int(n.get("id"))
	return int(n.get_meta("id", -1))

## The DOS state byte of a node — an export on the scripted kinds, a
## meta entry on the scriptless SoundLoop.
static func state_of(n: Node) -> int:
	if "state" in n:
		return int(n.get("state"))
	return int(n.get_meta("state", 0))

static func set_state(n: Node, v: int) -> void:
	if "state" in n:
		n.set("state", v)
	else:
		n.set_meta("state", v)

static func act_of(n: Node) -> int:
	if "act" in n:
		return int(n.get("act"))
	return int(n.get_meta("act", 0))

## ObjFlipLink from the node of `start_id`. Returns [[id, new_state] …]
## in walk order, so the caller can see what went up.
func flip(start_id: int) -> Array:
	_ensure_index()
	var out: Array = []
	var visited: Dictionary = {}
	var stack: Array = [start_id]
	while not stack.is_empty():
		var id: int = int(stack.pop_back())
		if visited.has(id):
			continue
		visited[id] = true
		var node: Node = _by_id.get(id)
		var rec = _map.entities_by_off.get(id) if _map != null else null
		if node == null and rec == null:
			continue
		# The record is the truth while action_system.gd still clears bits
		# there (a mover at the end of its run, a spent trigger): the node's
		# copy would flip a bit that is already down.
		var act: int = int(rec.link_act_type) if rec != null else act_of(node)
		var s: int = (int(rec.state_byte) if rec != null else state_of(node)) ^ 1
		if act == ActionSystem.ACT_PROX_GATE:
			s |= 1                                   # a gate stays live (skynet_gh.c:39837)
		if node != null:
			set_state(node, s)
		_mirror(id, s)
		out.append([id, s])
		if (s & 1) != 0 and node != null and node.has_method("fire"):
			_fire(node)
		if _is_actor(id):
			break                                    # the walk stops AT an actor
		var next: Array = _next_ids(id, node, rec)
		for i in range(next.size() - 1, -1, -1):
			stack.append(next[i])
	return out

## Where the chain goes next: down the node's `targets` where there is a
## node (that branch can fan out), down the record's own link otherwise.
## Markers get no node in the bake, and the DOS chain runs straight
## through them — MAP.210's lever switches the truck's PATH MARKERS on,
## which is what sets the truck driving.
func _next_ids(id: int, node: Node, rec) -> Array:
	var out: Array = []
	if node != null:
		for t in _targets_of(node):
			out.append(id_of(t))
		if not out.is_empty():
			return out
	if rec != null and int(rec.link_next) > 0:
		out.append(int(rec.link_next))
	return out

func _targets_of(n: Node) -> Array:
	var paths: Array = []
	if "targets" in n:
		paths = n.get("targets")
	elif n.has_meta("target"):
		paths = [n.get_meta("target")]
	var out: Array = []
	for p in paths:
		var t: Node = n.get_node_or_null(p)
		if t != null:
			out.append(t)
	return out

## Run a one-shot: the node does its thing, its enable bit clears (the
## DOS handlers clear their own bit), and a cue that DOS retires (act ←
## 0xFF) is retired in the record too.
func _fire(n: Node) -> void:
	n.call("fire")
	var s: int = state_of(n) & ~1
	set_state(n, s)
	_mirror(id_of(n), s)
	if "spent" in n and bool(n.get("spent")):
		_retire(id_of(n))

func _on_cue_fired(index: int, n: Node) -> void:
	if "fails_mission" in n:
		if bool(n.get("fails_mission")):
			mission_failed.emit()
		else:
			Audio.play_id(0x51, -4.0)                # FUN_0012f53d confirms
			objective_complete.emit(index)
	else:
		hint_message.emit(index)

func _mirror(id: int, s: int) -> void:
	if _map == null:
		return
	var e = _map.entities_by_off.get(id)
	if e != null:
		e.state_byte = s

func _retire(id: int) -> void:
	if _map == null:
		return
	var e = _map.entities_by_off.get(id)
	if e != null:
		e.link_act_type = 0xFF

func _is_actor(id: int) -> bool:
	if _map == null:
		return false
	var e = _map.entities_by_off.get(id)
	return e != null and (int(e.flags) & 0x40) != 0

## After a state overlay restore: the records are the truth, copy them
## back onto the nodes.
func sync_from_records() -> void:
	if _map == null:
		return
	_ensure_index()
	for id in _by_id:
		var e = _map.entities_by_off.get(id)
		if e != null:
			set_state(_by_id[id], int(e.state_byte))
