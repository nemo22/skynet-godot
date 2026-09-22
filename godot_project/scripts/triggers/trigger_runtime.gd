## The trigger state of one level — and the only thing that writes it
## (docs plan §4, migration step 5a).
##
## Before step 5a the same trigger state lived in two places and both
## were read: scripts/level/behaviour.gd walked the chain on the
## Behaviour nodes and MIRRORED every bit back into the parsed MAP
## record, while one long loop (scripts/action_system.gd, gone since step
## 5h) read those records for the movers, the proximity sweeps, the
## exits, the destructibles, the relays, the spawns, the water and the
## lights — and wrote them too (its _clear_enable wrote node AND
## record). Two copies of one byte drift: the water valve that swapped
## its own act byte did so only in the record, and a bit cleared in one
## copy was still up in the other.
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
##   hp / spent              what ObjHit (FUN_00139019) leaves behind: the
##                           hit points still in the pool and the record
##                           that has none left. Play state like the rest
##                           — plan §1 lists both in TriggerState — and
##                           they came here in step 5g with the
##                           destructibles
##   flip                    ObjFlipLink (FUN_001394aa): walk the chain
##                           from an entity toggling bit 0, an 0xEF gate
##                           forcing its bit back on, stopping AFTER an
##                           actor, firing on the way what goes up
##   fire                    one entity's own one-shot handler: the cue
##                           runs, its bit clears the way its DOS handler
##                           clears it, and a cue DOS retires has its act
##                           byte set to 0xFF
##   armed / fires           what a chain armed during THIS tick, which a
##                           one-shot sweep has to count as fired even if
##                           a later flip took the bit down again
##   snapshot / restore      the per-map Mst overlay, which since step 5h
##                           is the WHOLE of a map's play state: a save
##                           keeps it under map_state[map].triggers
##   reset / reset_acts      back to the records, as re-reading the MAP
##                           from disk used to do
##
## What a flip LOOKS like is not here: the sound a cue plays, the line it
## prints, the loop it starts, the lit face a button shows are the
## Behaviour branch's nodes, and this reaches them through `presenter`
## (present_fire / present_silence / present_flip, and present_snapshot /
## present_restore for the three things a node remembers for itself) —
## one call out, no state coming back. Every flip and every cue is
## announced on the level's event bus exactly as before.
##
## Owned by LevelLoader.Level (`level.triggers`) and dies with it, so a
## mission scene holding several zones has one of these per zone.

extends RefCounted

const MapFile := preload("res://scripts/loaders/map_file.gd")
const Rules := preload("res://scripts/triggers/rules_skynet.gd")
const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")

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
## ObjHit's own two: the hit points a record has LEFT (seeded by reset
## from every variant-1 record the map gives any) and the records whose
## pool has run out and which answer nothing any more.
var _hp: Dictionary = {}
var _spent: Dictionary = {}
## The records' own signatures and their fingerprint, worked out on first
## use and kept: the records are read-only, so neither can change while
## this level lives (see snapshot / restore).
var _sigs: Dictionary = {}
var _graph_sha: String = ""
## Every entity whose bit 0 went UP during THIS tick, even if a later
## flip in the same tick took it back down again.
##
## ObjFlipLink TOGGLES bit 0, and a map may point several triggers at one
## chain: eight 0xEF gates ring the jeep in MAP.217, all linked to the
## HUMMERTK that carries act 0x28 — mission 1's last objective. Walking
## up to it trips two or four of them in the SAME frame, so the toggles
## cancelled out and the objective never fired: mission 1 could not be
## finished. The DOS engine runs each object's handler as the chain is
## flipped, so an even number of flips still fires it once; the port
## sweeps by phase, so it remembers the arming instead. Cleared at the
## end of the level's tick (Behaviour.tick), and play state that lives
## for one tick, which is why it is here and in no snapshot.
var _armed: Dictionary = {}

func setup(m: MapFile.MapFile) -> void:
	map = m
	_sigs.clear()                            # another map, other records
	_graph_sha = ""
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
	_hp.clear()
	_spent.clear()
	_armed.clear()
	if map == null:
		return
	for e in map.entities:
		_state[e.file_off] = e.state_byte
		_act[e.file_off] = e.link_act_type
		_link[e.file_off] = e.link_next
		# A pool only exists where the map gave the record one, and only on
		# a variant-1 mesh: ObjHit drains it whatever the state bits say, so
		# a crate with state 0 still breaks and drops its ammo.
		if (e.flags & 3) == 1 and e.hp > 0:
			_hp[e.file_off] = float(e.hp)

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

## Did a chain arm this entity earlier in this tick (see `_armed`)?
func armed(off: int) -> bool:
	return _armed.has(off)

## Enabled now, or enabled at any point earlier in this tick — the test
## the one-shot sweeps make.
func fires(off: int) -> bool:
	return enabled(off) or _armed.has(off)

## Stand in for a chain that armed `off` this tick. The walk below does
## this for every entity whose bit it sends up; the verifier uses it to
## put an exit in the state a chain would have left it in without
## walking one (trigger_verifier._check_exit).
func arm_in_tick(off: int) -> void:
	_armed[off] = true

## The end of the level's tick: what a chain armed is no longer news.
func clear_armed() -> void:
	_armed.clear()

## …and the two the save's deltas are measured against, as the MAP file
## has them (a snapshot stores only what play has changed).
func act0(off: int) -> int:
	var e = _record(off)
	return int(e.link_act_type) if e != null else 0

func link0(off: int) -> int:
	var e = _record(off)
	return int(e.link_next) if e != null else 0

## The MAP record of `off` — the read-only DATA the map was authored
## with (position, radius, flags, name index, the destruction table),
## which is the half of a rule that never changes. Null for an offset
## this map has no record for.
func record(off: int):
	return _record(off)

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

# --- ObjHit's pool ----------------------------------------------------
## Has this record a pool of hit points at all? (The MAP's per-name
## defaults give one to crates, cars, generators and doors alike; a
## record with none is simply never worn down.)
func has_hp(off: int) -> bool:
	return _hp.has(off)

func hp(off: int) -> float:
	return float(_hp.get(off, 0.0))

## Every record that has one, in map order — what the solver goes through
## looking for something to shoot.
func hp_offs() -> Array:
	return _hp.keys()

func set_hp(off: int, value: float) -> void:
	_hp[off] = value

## Shot to pieces: the pool ran out. A spent record answers nothing any
## more — not the key, not the player walking into it — and the sweeps
## that watch it step over it.
func spent(off: int) -> bool:
	return _spent.has(off)

func set_spent(off: int) -> void:
	_spent[off] = true

# ---------------------------------------------------------------------
# ObjFlipLink
# ---------------------------------------------------------------------
## Walk the chain from `start_off`, toggling bit 0 of every entity on it
## — the start entity included — and firing what goes up as it goes, the
## way the DOS engine runs each object's handler while the chain is
## flipped. Returns [[off, new_state] …] in walk order, for a caller that
## wants the walk itself (the graph's equivalence check); what a walk
## ARMED is remembered here instead, in `_armed`.
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
		# What a walk LOOKS like on the node it passes: a BUTTON panel
		# shows its lit face. Presentation, like present_fire below, and
		# the branch alone knows about it.
		if presenter != null:
			presenter.present_flip(off)
		if (s & 1) != 0:
			_armed[off] = true               # …for the rest of this tick
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
## The whole play state of this map, as a save keeps it (plan §4's
## TriggerState, under `map_state[map].triggers` since step 5h): the
## state bytes of every entity, the act bytes and links play has CHANGED
## — a cue retired to 0xFF, a water valve that swapped its own act, a
## finished path whose link was cut — the pool of hit points and the
## records spent from it, and, asked of the branch, the three things a
## node remembers for itself: how far each mover has travelled and which
## way it goes next, the stage each wreck is showing, and the 0xF3
## sprites whose robot is already out.
##
## Every key in it is a MAP FILE OFFSET, which is what makes an overlay
## carryable to a variant map (main._carry_records) and an older save
## readable as it stands.
##
## It also records WHICH MAP it is an overlay of, in the only terms that
## survive a file changing under it: `graph_sha`, the fingerprint of every
## record's signature, and `sigs`, the signature of each offset it
## actually changes (plan §1). A save is a file players keep for months,
## and the offsets in it mean nothing against a MAP that has been edited
## since — a mod, another release of the data. With these, restore() can
## still lay back the entities that ARE the same and leave the rest as
## the file has them, instead of writing a bit into whatever record now
## happens to sit at that offset.
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
	var out: Dictionary = {"states": states, "acts": acts, "links": links,
		"hp": _hp.duplicate(), "spent": _spent.duplicate(),
		"movers": {}, "destr": {}, "spawned": {}}
	if presenter != null:
		var theirs: Dictionary = presenter.present_snapshot()
		for part in ["movers", "destr", "spawned"]:
			out[part] = theirs.get(part, {})
	out["graph_sha"] = graph_sha()
	out["sigs"] = _sigs_of(out)
	return out

## The signature of every offset this overlay CHANGES — the acts, the
## links, the pools, the movers, the wrecks, the robots let out and the
## state bytes that are no longer the record's own. The rest of `states`
## says only "as authored", which needs no guarding: an offset left out
## keeps whatever the map being loaded has there.
func _sigs_of(snap: Dictionary) -> Dictionary:
	var want: Dictionary = {}
	for part in ["acts", "links", "spent", "movers", "destr", "spawned"]:
		for off in (snap.get(part, {}) as Dictionary):
			want[int(off)] = true
	for off in (snap.get("states", {}) as Dictionary):
		var e = _record(int(off))
		if e == null or int(snap["states"][off]) != int(e.state_byte):
			want[int(off)] = true
	for off in (snap.get("hp", {}) as Dictionary):
		var e = _record(int(off))
		if e == null or not is_equal_approx(float(snap["hp"][off]), float(e.hp)):
			want[int(off)] = true
	var all: Dictionary = sigs()
	var out: Dictionary = {}
	for off in want:
		out[off] = String(all.get(off, ""))
	return out

## Every record's signature, by file offset (TriggerGraph.signatures) —
## built once per level and kept, since the records never change.
func sigs() -> Dictionary:
	if _sigs.is_empty() and map != null:
		_sigs = TriggerGraph.signatures(map)
	return _sigs

## The fingerprint of the whole table above: the map an overlay belongs
## to, told by what its records ARE rather than by its name.
func graph_sha() -> String:
	if _graph_sha.is_empty() and map != null:
		_graph_sha = TriggerGraph.sha_of(sigs())
	return _graph_sha

## Lay a snapshot back over the state. Sparse: an offset the snapshot
## does not mention keeps what it has — a variant map's carry brings only
## the entities that behave the same on both maps (main._carry_records).
##
## An EMPTY snapshot is nothing to lay: a level with no overlay of its own
## keeps the bytes its records were read with, and the pool below is not
## emptied out from under it.
##
## An overlay that names a graph_sha which is NOT this map's was made
## against another MAP file — the same map edited, another release of the
## data, a mod. Then an offset is no longer a promise, and only the
## entities whose recorded signature still matches the record now at that
## offset are laid back; the others keep what the file has (plan §4: on a
## graph_sha mismatch apply only ids with matching sig). An overlay with
## no graph_sha at all is a save from before this was written down and
## converts 1:1 by file offset, as it always did.
func restore(snap: Dictionary) -> void:
	if snap.is_empty():
		return
	var sha: String = String(snap.get("graph_sha", ""))
	var all: bool = sha.is_empty() or sha == graph_sha()
	var ok: Dictionary = {} if all else _restorable(snap, sha)
	for off in (snap.get("states", {}) as Dictionary):
		if all or ok.has(int(off)):
			_state[int(off)] = int(snap["states"][off]) & 0xFF
	for off in (snap.get("acts", {}) as Dictionary):
		if all or ok.has(int(off)):
			_act[int(off)] = int(snap["acts"][off]) & 0xFF
	for off in (snap.get("links", {}) as Dictionary):
		if all or ok.has(int(off)):
			_link[int(off)] = int(snap["links"][off])
	# The pool and the wrecks are laid back WHOLE, not sparsely: the
	# overlay carries every pool the map has, and a snapshot that names
	# neither (an old save, a hand-built one) puts both back empty — which
	# is what the long loop did with them before step 5g. Against another
	# file it is the other way round: this map's own pools stand, and only
	# the records the overlay can still vouch for are taken from it.
	if all:
		_hp = (snap.get("hp", {}) as Dictionary).duplicate()
		_spent = (snap.get("spent", {}) as Dictionary).duplicate()
	else:
		for off in (snap.get("hp", {}) as Dictionary):
			if ok.has(int(off)):
				_hp[int(off)] = float(snap["hp"][off])
		for off in (snap.get("spent", {}) as Dictionary):
			if ok.has(int(off)):
				_spent[int(off)] = true
	if presenter != null:
		presenter.sync_from_runtime()
		# …and what the nodes themselves remember: the movers back where
		# the overlay left them, mesh and all, every wreck at the stage it
		# had reached, and the robots an 0xF3 chain had already let out.
		presenter.present_restore(snap if all else _only(snap, ok))

## Which offsets of an overlay made against ANOTHER map file may still be
## laid back: those whose recorded signature is the signature of the
## record standing there now.
func _restorable(snap: Dictionary, sha: String) -> Dictionary:
	var theirs: Dictionary = snap.get("sigs", {})
	var mine: Dictionary = sigs()
	var out: Dictionary = {}
	for off in theirs:
		var id: int = int(off)
		if String(theirs[off]) == String(mine.get(id, "")):
			out[id] = true
	print("[triggers] the overlay was made against another map file: %d of its %d changed records are still the same (%s ≠ %s)"
		% [out.size(), theirs.size(), sha, graph_sha()])
	return out

## `snap` with the movers, wrecks and spawns of the offsets in `ok` only
## — what a presenter is given for an overlay from another file.
func _only(snap: Dictionary, ok: Dictionary) -> Dictionary:
	var out: Dictionary = snap.duplicate()
	for part in ["movers", "destr", "spawned"]:
		var kept: Dictionary = {}
		for off in (snap.get(part, {}) as Dictionary):
			if ok.has(int(off)):
				kept[off] = snap[part][off]
		out[part] = kept
	return out

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
