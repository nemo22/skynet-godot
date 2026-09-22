## The trigger EVENT BUS of one level — docs plan §4, M3 step 3.
##
## Step 1 wrote every map's triggers down as a graph and step 2 pinned
## it. Neither can say whether the RUNNING game does what the graph
## says, because the runtime announces nothing: a chain flips, a cue
## fires, a door starts moving, and the only trace is a print line.
##
## This is that trace as data. Every class that already performs a
## trigger event calls one of the three announce_* methods below as it
## does it — scripts/triggers/trigger_runtime.gd for the chain walk and
## scripts/level/behaviour.gd for the cues it runs,
## the long loop for the exits, movers, water, lights,
## destructibles, demolition, spawns, relays and path vehicles. Nothing
## about play changes: this is an OBSERVER. The emitting code never asks
## who is listening, holds no reference to a listener and behaves the
## same with no bus at all (every call site is guarded), and in the game
## as it ships nobody subscribes — only the tests do.
##
##   flipped(map, id, act, state)    ObjFlipLink toggled this entity's
##                                   bit 0; `state` is the byte after.
##   fired(map, id, kind)            that entity's own handler ran, named
##                                   by the rules module's kind.
##   effect(map, id, kind, payload)  and this is what the handler came to.
##
## The effect kinds, with the payload each carries:
##
##   objective  {index}            [M1].. — the mission counter
##   hint       {index}            [G1].. — a message, no counter
##   fail       {}                 act 0x2B
##   voice      {voice}            VOICE.PRS line id
##   sound      {sound}            one-shot sound id (0x4ff00 table)
##   loop       {loop}             an 0xEE ambient loop started (it runs
##                                 while its bit is up, so it is announced
##                                 on the rise and not again)
##   exit       {map, set, back}   0xF0 map change
##   move       {family, axis, travel, speed}
##                                 a mover set going, and the travel this
##                                 run will make (DOS axis 0/1/2, units or
##                                 11-bit angle)
##   spin       {family, axis, speed}
##                                 a continuous rotator switched on
##   destruct   {stage, stages}    one TRANSFRM.PRS damage stage
##   demolish   {hp}               act 0x1B killed the prop
##   spawn      {type}             an 0xF3 sprite let its robot out
##   water      {delta, absolute, target}
##                                 acts 0xd6-0xda moved the surface
##   light      {op, enable}       a light act ran (op as the graph names
##                                 it: toggle/flicker/strobe/fade_up/
##                                 fade_down)
##   path       {head, vehicle}    a marker-path vehicle picked up its path
##   relay      {at, left}         act 0x2C fired off the objective counter
##
## Who may subscribe: main.gd (the mission-facing effects), the
## presenters under scripts/level/ (each for its own id), the tests and
## the step-4 verifier. Prefer watch(id, cb) — ONE entity — over the
## broadcast signals: step 5a moved the source of truth from the MAP
## records onto the trigger runtime and the rest of step 5 replaces the
## emitting side class by class, and a subscriber that only ever named an
## id cannot tell.
##
## The bus belongs to the Level (LevelLoader.Level.bus) and dies with it,
## so a mission scene holding several zones has one bus per zone, each
## carrying its own map number.

extends RefCounted

signal flipped(map: int, id: int, act: int, state: int)
signal fired(map: int, id: int, kind: String)
signal effect(map: int, id: int, kind: String, payload: Dictionary)

const EV_FLIPPED: StringName = &"flipped"
const EV_FIRED: StringName = &"fired"
const EV_EFFECT: StringName = &"effect"

## The map these events belong to (the numeric suffix, -1 when unknown).
var map: int = -1

## id → [Callable] — the per-entity subscribers.
var _watchers: Dictionary = {}
## Everything announced since record(true), for the tests and the verifier.
var _log: Array = []
var _recording: bool = false

# ---------------------------------------------------------------------
# Announcing — the only three calls the runtime makes
# ---------------------------------------------------------------------
## ObjFlipLink toggled `id`; `state` is the state byte afterwards.
func announce_flip(id: int, act: int, state: int) -> void:
	flipped.emit(map, id, act, state)
	_deliver(id, EV_FLIPPED, {"act": act, "state": state})

## The entity's own handler ran (kinds as scripts/triggers/rules_*.gd
## name them: objective, hint, exit, mover, water, light …).
func announce_fire(id: int, kind: String) -> void:
	fired.emit(map, id, kind)
	_deliver(id, EV_FIRED, {"kind": kind})

## …and what it came to. See the kind/payload table above.
func announce_effect(id: int, kind: String, payload: Dictionary = {}) -> void:
	effect.emit(map, id, kind, payload)
	_deliver(id, EV_EFFECT, {"kind": kind, "payload": payload})

func _deliver(id: int, ev: StringName, data: Dictionary) -> void:
	if _recording:
		var row: Dictionary = data.duplicate(true)
		row["ev"] = ev
		row["id"] = id
		row["map"] = map
		_log.append(row)
	var subs: Variant = _watchers.get(id)
	if subs == null:
		return
	# A copy: a subscriber is allowed to unwatch itself from inside its
	# own callback (the presenters do, when their entity is spent).
	for cb in (subs as Array).duplicate():
		if (cb as Callable).is_valid():
			(cb as Callable).call(ev, data)

# ---------------------------------------------------------------------
# Subscribing by id
# ---------------------------------------------------------------------
## Call `cb(ev: StringName, data: Dictionary)` for every event of entity
## `id`. `data` holds what the matching announce_* was given.
func watch(id: int, cb: Callable) -> void:
	if not _watchers.has(id):
		_watchers[id] = []
	var subs: Array = _watchers[id]
	if not subs.has(cb):
		subs.append(cb)

func unwatch(id: int, cb: Callable) -> void:
	var subs: Variant = _watchers.get(id)
	if subs == null:
		return
	(subs as Array).erase(cb)
	if (subs as Array).is_empty():
		_watchers.erase(id)

func watchers(id: int) -> int:
	return (_watchers.get(id, []) as Array).size()

# ---------------------------------------------------------------------
# Recording — what the equivalence check and the verifier read
# ---------------------------------------------------------------------
## Keep every announcement in order. Off by default: a shipped build
## records nothing and allocates nothing.
func record(on: bool = true) -> void:
	_recording = on
	if not on:
		_log.clear()

func recording() -> bool:
	return _recording

## Everything announced so far, oldest first.
func history() -> Array:
	return _log

## …and forget it, so the next activation starts from an empty page.
func clear() -> void:
	_log.clear()

## The history, cleared in the same breath.
func take() -> Array:
	var out: Array = _log.duplicate()
	_log.clear()
	return out
