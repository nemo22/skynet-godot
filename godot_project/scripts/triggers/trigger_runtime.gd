## The trigger state of one level — and the only thing that writes it
## (docs plan §4, migration step 5a).
##
## Until now the same trigger state lived in two places and both were
## read: scripts/level/behaviour.gd walked the chain on the Behaviour
## nodes and MIRRORED every bit back into the parsed MAP record, while
## scripts/action_system.gd read those records for the movers, the
## proximity sweeps, the exits, the destructibles, the relays, the
## spawns, the water and the lights — and wrote them too (_clear_enable
## wrote node AND record). Two copies of one byte drift: the water valve
## that swapped its own act byte did so only in the record, and a bit
## cleared in one copy was still up in the other.
##
## So the state comes here. The MAP records stay exactly what they were
## — the DATA the map was authored with (act byte, link, position,
## radius, flags, hit points, the light's own numbers) — and nothing
## writes into them any more; this holds what PLAY has made of them.
## Everything else asks.
##
##   state / act / link      the live bytes of one entity, by MAP file
##                           offset; act0 / link0 are the record's own,
##                           which is what the save's deltas are against
##   flip                    ObjFlipLink (FUN_001394aa): walk the chain
##                           from an entity toggling bit 0, an 0xEF gate
##                           forcing its bit back on, stopping AFTER an
##                           actor, firing on the way what goes up
##   fire                    one entity's own one-shot handler: the cue
##                           runs, its bit clears the way its DOS handler
##                           clears it, and a cue DOS retires has its act
##                           byte set to 0xFF
##   snapshot / restore      the per-map Mst overlay's share of the state
##   reset / reset_acts      back to the records, as re-reading the MAP
##                           from disk used to do
##
## What a flip LOOKS like is not here: the sound a cue plays, the line it
## prints, the loop it starts are the Behaviour branch's nodes, and this
## reaches them through `presenter` (present_fire / present_silence) —
## one call out, no state coming back. Every flip and every cue is
## announced on the level's event bus exactly as before.
##
## Owned by LevelLoader.Level (`level.triggers`) and dies with it, so a
## mission scene holding several zones has one of these per zone.

extends RefCounted

const MapFile := preload("res://scripts/loaders/map_file.gd")
const Rules := preload("res://scripts/triggers/rules_skynet.gd")

## The parsed MAP. READ ONLY from here on — the records are the data,
## this object is the state.
var map: MapFile.MapFile = null
## The level's trigger event bus (scripts/triggers/trigger_bus.gd). An
## observer: null is an ordinary state and the walk takes the same path.
var bus: RefCounted = null
## The Behaviour branch (scripts/level/behaviour.gd) — presentation only.
var presenter: Node = null

## file offset → the live byte. Seeded from the records by reset().
var _state: Dictionary = {}
var _act: Dictionary = {}
var _link: Dictionary = {}
## Variant-2 lights: the enable word the DOS toggle flips the sign of,
## and the intensity the fades scale. Seeded from the record on first use
## — most maps never touch either.
var _light_enable: Dictionary = {}
var _light_intensity: Dictionary = {}

func setup(m: MapFile.MapFile) -> void:
	map = m
	reset()

## Every entity back to the byte its MAP record carries. DOS re-reads the
## map from disk on every entry and lays the Mst overlay over that, so
## this is the state a map starts in.
func reset() -> void:
	_state.clear()
	_act.clear()
	_link.clear()
	_light_enable.clear()
	_light_intensity.clear()
	if map == null:
		return
	for e in map.entities:
		_state[e.file_off] = e.state_byte
		_act[e.file_off] = e.link_act_type
		_link[e.file_off] = e.link_next

# ---------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------
func state(off: int) -> int:
	return int(_state.get(off, 0))

func act(off: int) -> int:
	return int(_act.get(off, 0))

func link(off: int) -> int:
	return int(_link.get(off, 0))

## Bit 0 — the enable bit every DOS handler tests.
func enabled(off: int) -> bool:
	return (int(_state.get(off, 0)) & 1) != 0

## …and the two the save's deltas are measured against, as the MAP file
## has them (a snapshot stores only what play has changed).
func act0(off: int) -> int:
	var e = _record(off)
	return int(e.link_act_type) if e != null else 0

func link0(off: int) -> int:
	var e = _record(off)
	return int(e.link_next) if e != null else 0

func _record(off: int):
	return map.entities_by_off.get(off) if map != null else null

# ---------------------------------------------------------------------
# Writing — the whole of it
# ---------------------------------------------------------------------
func set_state(off: int, value: int) -> void:
	_state[off] = value & 0xFF

## A chain, a touch or a spawn point arms an entity (bit 0 up).
func arm(off: int) -> void:
	_state[off] = int(_state.get(off, 0)) | 1

## What the DOS handlers do to themselves when they are done: `state &=
## 0xFE` (0x139644 with dl = 0xFE), the mover on arrival, the exit as it
## asks for the map change, the one-shot cue as it fires.
func clear_enable(off: int) -> void:
	_state[off] = int(_state.get(off, 0)) & ~1

func set_act(off: int, value: int) -> void:
	_act[off] = value & 0xFF

## A cue DOS RETIRES — the hint and the objective handlers write 0xFF
## into the act byte, and the entity does nothing at all from then on.
func retire(off: int) -> void:
	_act[off] = 0xFF

## A marker path that has run its course: the DOS stop case leaves the
## last marker pointing at nothing.
func cut_link(off: int) -> void:
	_link[off] = 0

# --- variant-2 lights -------------------------------------------------
## The light's enable word (negative = off; the DOS toggle flips the
## sign) and its intensity, which the fade acts scale.
func light_enable(off: int) -> int:
	if not _light_enable.has(off):
		var e = _record(off)
		_light_enable[off] = int(e.light_enable) if e != null else 0
	return int(_light_enable[off])

func set_light_enable(off: int, value: int) -> void:
	_light_enable[off] = value

func light_intensity(off: int) -> int:
	if not _light_intensity.has(off):
		var e = _record(off)
		_light_intensity[off] = int(e.light_intensity) if e != null else 0
	return int(_light_intensity[off])

func set_light_intensity(off: int, value: int) -> void:
	_light_intensity[off] = value

# ---------------------------------------------------------------------
# ObjFlipLink
# ---------------------------------------------------------------------
## Walk the chain from `start_off`, toggling bit 0 of every entity on it
## — the start entity included — and firing what goes up as it goes, the
## way the DOS engine runs each object's handler while the chain is
## flipped. Returns [[off, new_state] …] in walk order, so the caller can
## see what was armed (ActionSystem's per-tick sweeps read that).
##
## The DOS loop (FUN_001394aa, skynet_gh.c:39791) has no cycle guard —
## the shipped maps hold none — but `visited` keeps a broken one from
## spinning here.
func flip(start_off: int) -> Array:
	var out: Array = []
	var visited: Dictionary = {}
	var stack: Array = [start_off]
	while not stack.is_empty():
		var off: int = int(stack.pop_back())
		if visited.has(off):
			continue
		visited[off] = true
		if not _adopt(off):
			continue
		var a: int = act(off)
		var s: int = (state(off) ^ 1)
		if a == Rules.ACT_PROX_GATE:
			s |= 1                               # a gate stays live (skynet_gh.c:39837)
		set_state(off, s)
		if bus != null:
			bus.announce_flip(off, a, s)
		out.append([off, s])
		if (s & 1) != 0:
			fire(off)
		else:
			# A LEVEL kind runs for as long as its bit is up (the 0xEE
			# ambient loops), so the flip that takes the bit away is what
			# ends it — there is no handler of its own to notice.
			if presenter != null:
				presenter.present_silence(off)
		if _is_actor(off):
			break                                # the walk stops AT an actor
		var next: Array = _next_ids(off)
		for i in range(next.size() - 1, -1, -1):
			stack.append(next[i])
	return out

## Run one entity's own one-shot handler through its Behaviour node: the
## cue does its thing, its enable bit clears the way the DOS handlers
## clear theirs (the rules module's `on_fire` row — a LEVEL kind keeps
## its bit and runs on), and a cue DOS retires has its act byte set to
## 0xFF here.
func fire(off: int) -> void:
	if presenter == null:
		return
	var done: Dictionary = presenter.present_fire(off)
	if done.is_empty():
		return                                   # no node, or nothing to fire
	# The rule is read off the act the MAP was AUTHORED with, not off the
	# live one, because the live one may be the 0xFF this very handler
	# wrote a moment ago: MAP.217's jeep is flipped by four of the eight
	# gates ringing it in one tick, and from the second flip on the rule
	# for 0xFF ("spent", on_fire none) would leave the objective's bit
	# standing up. That is how the port has always read it — the Behaviour
	# node carried the authored byte and the rule came off that.
	if String(Rules.rule_for(act0(off) if _record(off) != null else act(off))
			.get("on_fire", "clear")) != "none":
		clear_enable(off)
	if bool(done.get("spent", false)):
		retire(off)

## Where the chain goes next: down the node's `targets` where there is a
## node (that branch can fan out), down the entity's own link otherwise.
## Markers get no node in the bake, and the DOS chain runs straight
## through them — MAP.210's lever switches the truck's PATH MARKERS on,
## which is what sets the truck driving.
func _next_ids(off: int) -> Array:
	var out: Array = []
	if presenter != null:
		out = presenter.targets_of(off)
		if not out.is_empty():
			return out
	var nxt: int = link(off)
	if nxt > 0:
		out.append(nxt)
	return out

## The walk stops AFTER an actor (flag 0x40) — a record thing, and one
## the records alone know.
func _is_actor(off: int) -> bool:
	var e = _record(off)
	return e != null and (int(e.flags) & 0x40) != 0

## Is this offset one we hold state for? Every entity of the MAP is, from
## reset(); a Behaviour branch built by hand (a test, the editor opening
## a baked scene) may hold nodes this has never seen, and those bring
## their own act and state in with them.
func _adopt(off: int) -> bool:
	if _state.has(off):
		return true
	if presenter == null:
		return false
	var seed: Dictionary = presenter.node_bytes(off)
	if seed.is_empty():
		return false
	_state[off] = int(seed.get("state", 0))
	_act[off] = int(seed.get("act", 0))
	return true

# ---------------------------------------------------------------------
# The per-map overlay (DOS Mst)
# ---------------------------------------------------------------------
## The state bytes of every entity, and the act bytes and links play has
## CHANGED — a cue retired to 0xFF, a water valve that swapped its own
## act, a finished path whose link was cut. Shape unchanged from when
## ActionSystem kept these (step 5h moves the save format itself).
func snapshot() -> Dictionary:
	var states: Dictionary = {}
	var acts: Dictionary = {}
	var links: Dictionary = {}
	for off in _state:
		states[off] = int(_state[off])
	for off in _act:
		if int(_act[off]) != act0(off):
			acts[off] = int(_act[off])
	for off in _link:
		if int(_link[off]) != link0(off):
			links[off] = int(_link[off])
	return {"states": states, "acts": acts, "links": links}

## Lay a snapshot back over the state. Sparse: an offset the snapshot
## does not mention keeps what it has — a variant map's carry brings only
## the entities that behave the same on both maps (main._carry_records).
func restore(snap: Dictionary) -> void:
	for off in (snap.get("states", {}) as Dictionary):
		_state[int(off)] = int(snap["states"][off]) & 0xFF
	for off in (snap.get("acts", {}) as Dictionary):
		_act[int(off)] = int(snap["acts"][off]) & 0xFF
	for off in (snap.get("links", {}) as Dictionary):
		_link[int(off)] = int(snap["links"][off])
	if presenter != null:
		presenter.sync_from_runtime()

## Act bytes and links back to what the MAP file has, the state bytes
## left alone — what the step-4 verifier needs between two checks of the
## same map, since a save's overlay holds only the CHANGED ones and could
## never undo a retirement.
func reset_acts() -> void:
	if map == null:
		return
	for e in map.entities:
		_act[e.file_off] = e.link_act_type
		_link[e.file_off] = e.link_next
	if presenter != null:
		presenter.sync_from_runtime()
