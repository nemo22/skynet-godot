## A DOS mover — a door leaf, a gate, a lift, a rotating dish — and the
## thing that moves it (docs/trigger_graph_plan.md §4, migration step 5e).
##
## In DOS the entity's handler (the Skynet.exe 0x59b00 slot for `act`)
## moves the entity's position, or an 11-bit angle, one step per tick
## while the entity's enable bit is set, and clears that bit at the end of
## the travel; the next trigger runs it back. That table (v1.01 0x59e00)
## gives every act EIGHT bytes — the handler pointer, then the two config
## words p4 and p6 — which is how one family is told from its neighbours:
##
##   slide    0x137a28  translate along DOS axis p4 by p6 units at 70 u/s
##                      (140 when p6 >= 0x800). BIGDOOR's 0x41/0x42 are
##                      the two leaves of the base gate parting.
##   swing    0x137c6b  rotate about axis p4 by p6 11-bit units at 512/s.
##   jump     0x137ad0  instant translate by the SIGNED p6.
##   slide5f  0x137d41  p4 is the speed base, the travel is p6<<4.
##   rot                two different handlers behind one family name: with
##                      an angle (0x36-0x38, p6 = 1024) the wall monitors,
##                      whose half turn is INSTANT and self-inverse; with
##                      no angle (0x39-0x3e) a genuine continuous rotator —
##                      the radar dish, the globe, MAP.232's sky dome —
##                      that never stops while its bit is up.
##   zero     0x137b33  0xbd-0xc0, whose table limit word is 0: the handler
##                      falls straight into the arrived path and they never
##                      move at all.
##
## Until step 5e this class was one dictionary keyed by file offset, swept
## from the long loop in scripts/action_system.gd. The node is the mover
## now. What it holds is what one of these records remembers between ticks
## — how far along its travel it is, which way it is going, whether it is
## in the middle of a run — and it is the only thing that moves the mesh.
## What it does NOT hold is the record's state: the enable bit, the act
## byte and the link belong to the level's trigger runtime
## (scripts/triggers/trigger_runtime.gd) and are written only there.
##
##   Mover (this)          position = the DOS entity position, no rotation
##   +- AnimationPlayer    "move": the same travel as an animation, made at
##                         import — the SLEEPING geometry's, for looking at
##                         a door in the editor. The running game steps
##                         `progress` below instead, because a DOS mover is
##                         driven by its enable bit and can be stopped and
##                         reversed half way.
##   +- Body               AnimatableBody3D, basis = the DOS rotation
##      +- Mesh / Shape    asleep while the level loader still builds the
##                         same mesh from the record (sleep_geometry)
##
## The mesh this MOVES is therefore the loader's — handed over at
## registration as `presenter`, with the transform it was placed at as the
## rest pose. Its AnimatableBody3D child follows through the
## global-transform notification (main.gd _make_animatable keeps
## sync_to_physics off), and that body is what the player stands on.
##
## The numbers of the travel are NOT read off the exports below: they come
## from the rules the generated graph reads (Rules.mover_params), so the
## running game and the graph cannot draw the line in two places. The
## exports are what the BAKE made of the same act — see `family` — and one
## of them is knowingly behind: level_behaviour.mover_params still gives
## every "rot" a 2048-unit continuous turn, which the wall monitors (an
## instant 1024) stopped being on 2026-09-16. Only the animation above is
## built from it, and nothing plays that.

extends Node3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")

const ANIM := &"move"

## What the port steps a family whose DOS handler has no rate at all: the
## jumps (0x137ad0) and the wall monitors (0x138577) put the whole travel
## on in a single tick. Large enough that one move_toward covers any span.
const INSTANT_SPEED: float = 1.0e9

## Stable id of this entity within its map — the MAP file offset the
## import read it from. Saves and the network key state by it (plan §3).
@export var id: int = 0
## DOS handler id (0x59b00 slot). Odd and even ids are the two
## directions of one family — the BIGDOOR leaves carry 0x41 and 0x42.
@export var act: int = 0
@export var mesh_name: String = ""
## slide / swing / jump / slide5f / rot — Rules.MOVER_TABLE. The bake's
## answer, kept as the map's own data; the live one is `family_now()`.
@export var family: String = "slide"
## DOS axis of the motion: 0 = X, 1 = Y (down), 2 = Z.
@export var axis: int = 0
## Full travel, signed in the direction the first trigger moves it:
## world units for slides, 11-bit angle units for swings (2048 = 360°).
@export var travel: float = 0.0
## Units of `travel` per second; 0 = instant (the DOS "jump" family).
@export var speed: float = 0.0
## Seconds for the full travel — the length of the "move" animation.
@export var duration: float = 0.0
## DOS state byte: bit 0 = enabled at start (rotators spin from load),
## bit 1 = act on every hit, bit 2 = act when the HP runs out,
## bit 3 = use key. The byte the MAP was AUTHORED with; the live one is
## the runtime's.
@export var state: int = 0
@export var hp: int = 0
## The next link of the DOS chain (ObjFlipLink) — what a flip of this
## node passes on to.
@export var targets: Array[NodePath] = []

## The Behaviour branch this hangs under (scripts/level/behaviour.gd):
## where the trigger runtime and the event bus are reached. Null for a
## branch nobody plays — the editor opening a baked scene — and then the
## baked bytes above are all there is.
var branch: Node = null

## The mesh the level loader built for this record, and the rest pose it
## was placed at. Null until registration (and for a record whose .3D is
## missing from the archives, which has never moved).
var presenter: Node3D = null
var base: Transform3D = Transform3D.IDENTITY
## The entity's raw 11-bit Euler triple (pitch, yaw, roll) — a swing
## advances ONE of the three and the basis is rebuilt from all of them.
var euler: Vector3 = Vector3.ZERO

## How far along the travel, in the units the family works in, and which
## way the next run goes. These two ARE the mover's save state.
var progress: float = 0.0
var dir: float = 1.0
## A run is under way — announced once at its start, and ended by arrival
## or by a chain taking the bit away.
var running: bool = false

## The travel as the rules module reads this act (filled at registration).
var _fam: String = "slide"
var _axis: int = 0
var _sign: float = 1.0
var _span: float = 0.0
var _speed: float = 0.0
## A continuous rotator: the slot carries NO angle, so the handler turns
## for as long as the bit is up and never arrives.
var _spins: bool = false

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

## `state &= 0xFE` — what the DOS handler does to itself at the end of the
## travel. The runtime is the only thing that writes a state byte (5a).
func _clear_enable() -> void:
	var rt := _rt()
	if rt != null:
		rt.clear_enable(id)

# ---------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------
## The level loader has built this record's mesh: it is what this node
## moves from here on, and where it stands now is the rest pose every
## travel is measured from. `euler_in` is the record's own 11-bit Euler
## triple, which the swing families advance one component of.
##
## The numbers come from the rules module rather than from the exports
## above, so the graph and the game read one table (see the header).
func adopt(node: Node3D, euler_in: Vector3) -> void:
	presenter = node
	base = node.transform
	euler = euler_in
	var p: Dictionary = Rules.mover_params(act)
	_fam = String(p["family"])
	_axis = int(p["axis"])
	_sign = float(p["sign"])
	_span = float(p["span"])
	_speed = float(p["speed"])
	# Only a "rot" slot with no angle of its own is given a rate by
	# mover_params, and that is the one that never arrives.
	_spins = _fam == "rot" and _speed > 0.0

## The whole travel of this mover, in its family's units — what the
## graph's move@ token promises (trigger_graph._settle).
func span() -> float:
	return _span

## Does this one turn for ever while its bit is up (the radar dish, the
## globe, the sky dome), rather than arriving and switching itself off?
func spins() -> bool:
	return _spins

func family_now() -> String:
	return _fam

## Movers that translate or swing as a solid piece (doors, gates, lifts)
## get a box collider; continuous rotators keep their trimesh.
func is_solid() -> bool:
	return _fam in ["slide", "swing", "jump", "slide5f"]

# ---------------------------------------------------------------------
# One tick
# ---------------------------------------------------------------------
## Advance this mover while its enable bit is set. On reaching either end
## of its travel the DOS handler clears the bit and flips the stored
## direction — the next chain flip runs it back.
func mover_watch(delta: float) -> void:
	if presenter == null or not is_instance_valid(presenter):
		return
	if not enabled():
		# A chain took the bit away in the middle of a run: the mover stops
		# where it stands and the next enable is a new run.
		running = false
		return
	if _spins:
		# Never stops while enabled. Only the acts whose handler carries NO
		# angle spin like this: the radar DISH (0x3b), the GLOBE, MAP.232's
		# sky dome.
		if not running:
			running = true
			_say("spin", {"family": _fam, "axis": _axis, "speed": _speed})
		progress = fmod(progress + _speed * delta, 2048.0)
		apply_transform()
		return
	if _span == 0.0:
		# A ZERO SLIDE (0xbd-0xc0). Its slot's limit word is 0, so the
		# handler's `cmp ax, word [ecx+6] / jl` — a signed compare of a
		# non-negative step against zero — can never take the "still
		# travelling" branch: it falls straight into the arrived path on the
		# first tick (v1.01 0x138392/0x13842d, disassembled 2026-09-16),
		# where it zeroes the step, CLEARS ITS OWN ENABLE BIT, flips the act
		# parity and calls ObjSetPos with the position unchanged. The port
		# used to return here before any of that, so the node stayed enabled
		# for ever and its chain bit never came back down.
		_say("move", {"family": _fam, "axis": _axis,
			"travel": travel_to(progress), "speed": 0.0})
		_clear_enable()
		dir = -dir
		return
	# A family whose handler has no rate — the jumps, and the wall monitor's
	# half turn (v1.01 0x138577: nine instructions, `add eax, edx / and eax,
	# 0x7ff` puts the whole 1024 on in a single tick and `and byte
	# [esi+0x12], 0xfe` clears the bit on the way out; the mask is what makes
	# it self-inverse, so the next trigger turns the panel back). The panels
	# are flat and two-sided with a different picture on each face, so that
	# instant turn IS the screen changing — turned at the swing rate instead
	# it showed the player a polygon revolving for two seconds (playtest
	# 2026-09-16: "flipuje sa, ako keby sa rotovala").
	var step: float = _speed if _speed > 0.0 else INSTANT_SPEED
	var target: float = _span if dir > 0.0 else 0.0
	var p: float = move_toward(progress, target, step * delta)
	if progress == 0.0 or progress == _span:
		print("[action] mover @%05x %s %s starts (%s, span %.0f)" % [id, presenter.name,
			_fam, "forward" if dir > 0.0 else "back", _span])
	if not running:
		# Announced at the START of the run, with the travel the run will
		# make: the DOS handler self-disables on arrival and the graph's
		# simulation settles it the same way, so the two are talking about
		# one and the same movement — here, the moment it begins (step 3).
		running = true
		_say("move", {"family": _fam, "axis": _axis,
			"travel": travel_to(target), "speed": step})
	progress = p
	apply_transform()
	if p == target:
		_clear_enable()                          # arrived: self-disable
		dir = -dir                               # next activation reverses
		running = false

## How far this run carries the mover from where it stands, signed, in the
## units its family works in — the same number the graph's simulation
## writes as move@<id>:<family><axis><travel> (trigger_graph._settle).
## From either end of the travel that is the whole span; a mover a chain
## switched off half way and switched on again makes only the rest of it,
## and says so.
func travel_to(target: float) -> float:
	return (target - progress) * _sign

## The mesh where `progress` puts it.
func apply_transform() -> void:
	if presenter == null or not is_instance_valid(presenter):
		return
	if _fam == "slide5f":
		# DOS adds to entity+0xc (Y, Y-down) → Godot -Y (slides down).
		presenter.transform = base.translated_local(
			Vector3(0.0, -progress * _sign, 0.0))
		return
	if _fam == "slide" or _fam == "jump":
		# Translate along the DOS world axis (handlers 0x137a28/0x137ad0
		# add to the entity position, not to a local frame).
		presenter.transform = Transform3D(base.basis,
			base.origin + dos_axis(_axis) * (progress * _sign))
		return
	# Swing/rot: advance one Euler component of the entity (see
	# swing_basis) — the base basis IS euler_basis(euler) at progress 0.
	presenter.transform = Transform3D(
		swing_basis(euler, _axis, progress * _sign), base.origin)
	# The AnimatableBody3D child follows through the global-transform
	# notification (main.gd _make_animatable keeps sync_to_physics off).

## Say what this mover just did, on the level's event bus (M3 step 3).
func _say(effect_kind: String, payload: Dictionary) -> void:
	if branch != null:
		branch.say(id, "mover", effect_kind, payload)

# ---------------------------------------------------------------------
# The map's state overlay, and the console
# ---------------------------------------------------------------------
## What the per-map overlay (DOS Mst) keeps of a mover, and the way back.
## The shape is the one ActionSystem's snapshot has always had — step 5h
## moves the save format itself.
func snapshot() -> Array:
	return [progress, dir]

func restore(snap: Array) -> void:
	if snap.size() < 2:
		return
	progress = float(snap[0])
	dir = float(snap[1])
	apply_transform()

## Everything this node remembers about the level's own doing, forgotten —
## what the verifier clears between two checks of the same map. Where the
## mover STANDS is not that: restore_state puts it back.
func mover_forget() -> void:
	running = false

## One line of the console's `movers`: what it is, how far it has moved
## and which way.
func report() -> String:
	var bx: String = "-"
	if presenter != null and is_instance_valid(presenter):
		var b: Basis = presenter.global_transform.basis
		bx = "X%s Y%s" % [str(b.x.round()), str(b.y.round())]
	return "@%05x %-8s %-7s act %02x state %02x progress %.0f/%.0f dir %+.0f sign %+.0f axis %d %s" % [
		id, mesh_name if not mesh_name.is_empty() else "?", _fam,
		act_now(), state_now(), progress, _span, dir, _sign, _axis, bx]

# ---------------------------------------------------------------------
# The DOS geometry of a mover
# ---------------------------------------------------------------------
## 11-bit DOS Euler angles (pitch, yaw, roll — sub+0/+4/+8) → Godot basis:
## Rz(-roll)·Rx(+pitch)·Ry(+yaw), the DOS matrix (FUN_0014e100) conjugated
## by the Y/Z flip. Floats, so an animation can add a fraction.
static func euler_basis(pitch: float, yaw: float, roll: float) -> Basis:
	var b := Basis()
	b = b.rotated(Vector3.UP, yaw * TAU / 2048.0)
	b = b.rotated(Vector3.RIGHT, pitch * TAU / 2048.0)
	b = b.rotated(Vector3.BACK, -roll * TAU / 2048.0)
	return b

## A swing/rot mover after `delta` 11-bit units about DOS axis `axis_i`
## (0 pitch, 1 yaw, 2 roll). The DOS handler (0x137c6b) adds to ONE Euler
## component of the entity and the renderer rebuilds the matrix from the
## three — so the motion is neither a local nor a world rotation but the
## Euler composition with that component advanced. The old
## `base * Basis(axis, angle)` was right for yaw only: the two halves of
## MAP.281's drawbridge (0xC3/0xC4, roll ±512) swung one down, one UP
## (playtest, 2026-09-05: "ten druhý sa zle rotuje").
static func swing_basis(euler_in: Vector3, axis_i: int, delta: float) -> Basis:
	var e := euler_in
	match axis_i:
		0: e.x += delta
		1: e.y += delta
		_: e.z += delta
	return euler_basis(e.x, e.y, e.z)

## DOS axis p4 (0=X, 1=Y-down, 2=Z) → Godot world direction.
static func dos_axis(axis_i: int) -> Vector3:
	if axis_i == 1:
		return Vector3.DOWN
	if axis_i == 2:
		return Vector3(0.0, 0.0, -1.0)
	return Vector3.RIGHT

# ---------------------------------------------------------------------
# The sleeping geometry
# ---------------------------------------------------------------------
## Run the baked "move" animation forward — the travel as the import saw
## it, on the Body under this node. Nothing in the running game calls
## these: the level loader's mesh is what moves (see the header), and it
## is stepped by mover_watch. They are how a door is looked at in the
## editor.
func open() -> void:
	var ap := _player()
	if ap != null and ap.has_animation(ANIM):
		ap.play(ANIM)

## Run it back.
func close() -> void:
	var ap := _player()
	if ap != null and ap.has_animation(ANIM):
		ap.play_backwards(ANIM)

func _player() -> AnimationPlayer:
	return get_node_or_null(^"AnimationPlayer") as AnimationPlayer
