## The Behaviour branch of a level at run time (docs/map_format_plan.md
## §8, phase F2).
##
## The branch holds one node per entity with behaviour (built by
## scripts/level_behaviour.gd at import) and this script is what the DOS
## object layer LOOKS like on top of them: the sound a chain plays, the
## line it prints, the objective it counts, the ambient loop it starts
## and stops.
##
## What it no longer is, since step 5a of docs/trigger_graph_plan.md, is
## a keeper of state. The chain walk (ObjFlipLink) and the decision that
## a cue has fired moved to scripts/triggers/trigger_runtime.gd, which
## holds the state bytes, the act bytes and the links of the whole level
## and is the only thing that writes them; the mirror into the MAP
## records is gone with it, and the records are read-only data now. This
## branch is what the runtime calls OUT to:
##
##   present_fire(id)     run that entity's node — play, print, count —
##                        and say whether it is spent afterwards. The
##                        runtime decides what the entity's bit and act
##                        byte become.
##   present_silence(id)  the chain took the bit away: a level kind (the
##                        0xEE ambient loops) stops.
##   targets_of(id)       where the chain goes next, as the bake wired it.
##   node_bytes(id)       the act and state a node was baked with — for a
##                        branch the runtime has no records for.
##
## The `state` export on the nodes is the byte the MAP was AUTHORED with
## and stays that: nothing writes it at run time any more, so there is no
## second copy to disagree with the runtime. The one node-side mirror
## left is `spent` on the cue classes — their own guard against firing
## twice — and sync_from_runtime puts it back after a restore.
##
## Every cue that fires is still ANNOUNCED on the level's trigger event
## bus (`bus`, scripts/triggers/trigger_bus.gd — M3 step 3). That is an
## observer and nothing more: nothing below asks whether anything is
## listening and it behaves the same when the bus is null.
##
## F2 runs class by class, so while action_system.gd still drives the
## movers, triggers, exits and destructibles, their geometry in this
## branch stays asleep (sleep_geometry). When the last class has moved,
## that goes too.

extends Node3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")

## A hint cue ([G1]..) fired: index = act - 0x1C.
signal hint_message(index: int)
## An objective cue ([M1]..) fired: index = act - 0x26.
signal objective_complete(index: int)
## The 0x2B cue fired.
signal mission_failed()

var _by_id: Dictionary = {}          # id → node
var _indexed: bool = false
## The level's trigger runtime (scripts/triggers/trigger_runtime.gd): it
## owns the state and drives everything below. Null for a branch nobody
## plays — the editor opening a baked scene, the bake itself — and then
## the nodes' own baked bytes are all there is.
var runtime: RefCounted = null
## The level's trigger event bus (scripts/triggers/trigger_bus.gd, M3
## step 3): every cue that fires is announced on it. An OBSERVER — null
## is the normal case in a test that builds a branch by hand, and nothing
## below reads anything back.
var bus: RefCounted = null

func _ready() -> void:
	_ensure_index()
	# One-shots armed in the MAP data fire once at level start (a door
	# sound a map starts enabled, a radio line on entry). On a map entered
	# again, or loaded from a save, main.gd has laid the saved state over
	# the runtime BEFORE this branch enters the tree, so a cue that already
	# fired has its bit down and does not replay.
	for id in _by_id:
		if runtime != null:
			if runtime.enabled(int(id)):
				runtime.fire(int(id))
		elif (state_of(_by_id[id]) & 1) != 0:
			present_fire(int(id))

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

static func id_of(n: Node) -> int:
	if "id" in n:
		return int(n.get("id"))
	return int(n.get_meta("id", -1))

## The DOS state byte a node was BAKED with — an export on the scripted
## kinds, a meta entry on the scriptless SoundLoop. Not the live one:
## that is the runtime's (TriggerRuntime.state).
static func state_of(n: Node) -> int:
	if "state" in n:
		return int(n.get("state"))
	return int(n.get_meta("state", 0))

static func act_of(n: Node) -> int:
	if "act" in n:
		return int(n.get("act"))
	return int(n.get_meta("act", 0))

# ---------------------------------------------------------------------
# What the runtime calls
# ---------------------------------------------------------------------
## Run entity `id`'s node: the cue plays, prints or counts, and says so
## on the bus. Returns {} when there is no node or the node has nothing
## to fire — the runtime then leaves the entity's bit and act byte alone
## — and {"spent": …} otherwise, which is what a cue DOS retires (act ←
## 0xFF) reports back.
func present_fire(id: int) -> Dictionary:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n == null or not n.has_method("fire"):
		return {}
	# A cue DOS has RETIRED does nothing at all when its bit goes up again
	# — and must not be announced as if it had. The bus used to say "hint"
	# on every later flip of a chain whose message had long since been
	# read, which is what the step-4 verifier saw as a second activation
	# doing more than the graph said it would.
	var was_spent: bool = "spent" in n and bool(n.get("spent"))
	n.call("fire")
	if not was_spent:
		_announce_fire(n)
	return {"spent": "spent" in n and bool(n.get("spent"))}

## The chain took the bit away from a LEVEL kind: the 0xEE ambient loop
## that has been running since it went up stops here.
func present_silence(id: int) -> void:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n != null and n.has_method("silence"):
		n.call("silence")

## Where a flip of `id` goes next — the ids the bake wired this node's
## `targets` to. Empty when the node has none, or there is no node: the
## runtime then follows the entity's own link.
func targets_of(id: int) -> Array:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n == null:
		return []
	var paths: Array = []
	if "targets" in n:
		paths = n.get("targets")
	elif n.has_meta("target"):
		paths = [n.get_meta("target")]
	var out: Array = []
	for p in paths:
		var t: Node = n.get_node_or_null(p)
		if t != null:
			out.append(id_of(t))
	return out

## The act and state byte node `id` was baked with, for a runtime that
## has no MAP record for it (a branch built by hand). {} when there is no
## such node.
func node_bytes(id: int) -> Dictionary:
	_ensure_index()
	var n: Node = _by_id.get(id)
	if n == null:
		return {}
	return {"act": act_of(n), "state": state_of(n)}

## Say what just fired, in the rules module's own vocabulary (M3 step 3).
## Nothing here changes what the cue did — it has already done it.
func _announce_fire(n: Node) -> void:
	if bus == null:
		return
	var id: int = id_of(n)
	var kind: String = Rules.kind_of(act_of(n))
	bus.announce_fire(id, kind)
	match kind:
		"sound_cue":
			bus.announce_effect(id, "sound", {"sound": int(n.get("sound_id"))})
		"sound_loop":
			# The scriptless-era node keeps its data in metadata (the bake
			# writes it there), so the id comes off the meta.
			bus.announce_effect(id, "loop", {"loop": int(n.get_meta("sound_id", -1))})
		"voice":
			bus.announce_effect(id, "voice", {"voice": int(n.get("voice_id"))})
		"hint":
			bus.announce_effect(id, "hint", {"index": int(n.get("index"))})
		"objective":
			# One node class carries both [M1].. and the 0x2B fail act.
			if "fails_mission" in n and bool(n.get("fails_mission")):
				bus.announce_effect(id, "fail", {})
			else:
				bus.announce_effect(id, "objective", {"index": int(n.get("index"))})
		"fail":
			bus.announce_effect(id, "fail", {})

func _on_cue_fired(index: int, n: Node) -> void:
	if "fails_mission" in n:
		if bool(n.get("fails_mission")):
			mission_failed.emit()
		else:
			Audio.play_id(0x51, -4.0)                # FUN_0012f53d confirms
			objective_complete.emit(index)
	else:
		hint_message.emit(index)

## After the runtime took a state overlay: a cue whose act byte came back
## as 0xFF fired before this visit and must not count again, so its
## node's own guard goes back up with it (an objective whose `spent` came
## back false counted a second time on the next chain flip).
func sync_from_runtime() -> void:
	if runtime == null:
		return
	_ensure_index()
	for id in _by_id:
		var n: Node = _by_id[id]
		if "spent" in n:
			n.set("spent", runtime.act(int(id)) == 0xFF)
