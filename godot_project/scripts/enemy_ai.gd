## Enemy "brain": the DOS AIS behaviour interpreter plus the per-type
## parameters, with no scene dependencies (headless-testable).
##
## DOS runs each enemy through EnemyGroupDoAI (FUN_00129871): a state
## handler (table 0x59900) advances the actor's animation block, runs
## its AIS script (FUN_0012a500) when it has one, matches frame events
## against the current animation frame (FUN_001375b1) and decides
## movement/fire. This class reproduces the data-driven parts — the
## script VM, the animation block stepping and the frame events — and
## hands the scene-side actor (enemy.gd) a small set of outputs:
## the mesh frame to show, sounds to play, whether the current pose is
## a firing pose, and the script variables (flyer altitude, tank speed
## and heading targets).
##
## Script ops (enemy_ai_data.gd OPS): an "if" jumps when `pred cmp arg`
## holds; "goto"; "wait" holds for ticks/70 s (optionally freezing the
## animation); "anim" starts a block; "set"/"add"/"setfn" write script
## variables; "sound" plays a positional sound. "if"/"goto"/"sound"
## keep executing in the same tick, the others end the tick — exactly
## the CF convention of the DOS opcode handlers (0x12a572..0x12a7d0).
##
## Predicates: see (1 while the player is NOT perceived), dist (units), bearing (player's
## direction relative to facing, 0..2047, 0 = dead ahead), bearing_abs
## (0..1024), rand (0..1023), angle_to_player (absolute 0..2047),
## animflags (current animation flags & arg), flags (actor flags & arg;
## 0x1000 = movement blocked).

extends RefCounted

const Data := preload("res://scripts/enemy_ai_data.gd")

## DOS AI tick — WAIT counts in 1/70 s.
const TICK: float = 1.0 / 70.0
## Animation block flags.
const ANIM_ONESHOT: int = 4
const ANIM_LOOP: int = 8
const ANIM_FIRE: int = 0x100
## Runtime animation flags (returned by the DOS stepper in BX).
const ANIM_DONE: int = 1
const ANIM_WRAPPED: int = 2
## Actor flag tested by the tank script: movement blocked.
const FLAG_BLOCKED: int = 0x1000
## Safety cap on ops executed per tick (scripts are small loops).
const MAX_OPS_PER_TICK: int = 64
## The script is evaluated once per rendered frame in DOS, not at 70 Hz:
## its per-evaluation RANDOM rolls (the T800's 10 % gesture check, the
## 50 % pose pick) are tuned for the ~12 fps of a 1996 machine.
const SCRIPT_HZ: float = 12.0

var type_id: int = -1
var t: Dictionary = {}                  # the TYPES entry
var state: int = 0

# --- script ---
var pc: int = 0                         # op VA, 0 = no script
var wait_left: float = 0.0              # seconds
var freeze_anim: bool = false           # WAIT(n, 1): animation paused
var vars: Dictionary = {}               # SET/ADD/SETFN offset → value
var _script_acc: float = 0.0            # time since the last script evaluation

# --- animation ---
var anim_va: int = 0
var anim_frames: PackedInt32Array = PackedInt32Array()
var anim_fps: float = 0.0
var anim_flags: int = 0                 # block flags | runtime DONE/WRAPPED
var cursor: float = 0.0                 # frame position inside the block
var frame: int = 0                      # mesh frame currently shown
var frame_changed: bool = false

# --- outputs of the last tick ---
var sounds: Array[int] = []             # frame-event / script sounds

func _init(id: int) -> void:
	type_id = id
	if id >= 0 and id < Data.TYPES.size():
		t = Data.TYPES[id]
		state = int(t.get("st", 0))
		pc = int(t.get("script", 0))

## True when the type carries an AIS script.
func has_script() -> bool:
	return pc != 0

## True while the current animation block is a firing pose.
func firing_pose() -> bool:
	return (anim_flags & ANIM_FIRE) != 0

## Fire parameters [mx, my, mz, ammo, speed, rate, range] or [].
func fire_params() -> Array:
	return t.get("fire", [])

## Start an animation block by VA. A block already playing with the
## loop flag keeps running (PLAY_ANIM's "same block & flag 8" check).
func play_anim(va: int) -> void:
	if va == anim_va and (anim_flags & ANIM_LOOP) != 0:
		return
	var rec: Array = Data.ANIMS.get(va, [])
	anim_va = va
	if rec.is_empty():
		anim_frames = PackedInt32Array()
		anim_fps = 0.0
		anim_flags = 0
		return
	anim_fps = float(rec[0])
	anim_flags = int(rec[1])
	anim_frames = PackedInt32Array(rec[2])
	cursor = 0.0
	_set_frame(anim_frames[0] if anim_frames.size() > 0 else 0)

func _set_frame(f: int) -> void:
	if f != frame:
		frame = f
		frame_changed = true
		_emit_frame_events(f)

## Frame-event sounds: {frame, sound_id, …} matched on frame change.
func _emit_frame_events(f: int) -> void:
	var ev: Array = t.get("events", [])
	var i: int = 0
	while i + 1 < ev.size():
		if int(ev[i]) == f:
			sounds.append(int(ev[i + 1]))
		i += 2

## Advance the animation block by `delta` seconds (DOS stepper 0x135c70).
func _step_anim(delta: float) -> void:
	if anim_frames.is_empty() or anim_fps <= 0.0 or freeze_anim:
		return
	var n: int = anim_frames.size()
	if n == 1:
		_set_frame(anim_frames[0])
		return
	cursor += anim_fps * delta
	anim_flags &= ~ANIM_WRAPPED
	if cursor >= float(n):
		if (anim_flags & ANIM_ONESHOT) != 0:
			cursor = float(n - 1)
			anim_flags |= ANIM_DONE
		else:
			cursor = fmod(cursor, float(n))
			anim_flags |= ANIM_WRAPPED
	_set_frame(anim_frames[clampi(int(cursor), 0, n - 1)])

## Evaluate a predicate against the senses supplied by the actor.
func _pred(name: String, arg: int, sense: Dictionary) -> int:
	match name:
		"see":
			# DOS 0x12a6b8 returns 1 while the "player perceived" flag is
			# CLEAR (the tank script idles on see != 0 and advances on
			# see == 0), so scripts test "see <= 0" for "I see the player".
			return 0 if bool(sense.get("see", false)) else 1
		"dist":
			return int(sense.get("dist", 1e9))
		"bearing":
			return int(sense.get("bearing", 0)) & 0x7FF
		"bearing_abs":
			var b: int = int(sense.get("bearing", 0)) & 0x7FF
			return mini(b, 2048 - b)
		"rand":
			# Tests may pin the roll through sense["rand"].
			return int(sense.get("rand", randi() % 1024))
		"angle_to_player":
			return int(sense.get("angle", 0)) & 0x7FF
		"animflags":
			return anim_flags & arg
		"flags":
			var fl: int = FLAG_BLOCKED if bool(sense.get("blocked", false)) else 0
			return fl & arg
	return 0

## Run script ops for this tick (FUN_0012a500).
func _run_script(delta: float, sense: Dictionary) -> void:
	if pc == 0:
		return
	if wait_left > 0.0:
		wait_left -= delta
		if wait_left > 0.0:
			return
		freeze_anim = false
	for _i in MAX_OPS_PER_TICK:
		var op: Array = Data.OPS.get(pc, [])
		if op.is_empty() or op[0] == "end":
			pc = 0                          # script over — hold the pose
			return
		match op[0]:
			"if":
				var v: int = _pred(String(op[1]), int(op[3]), sense)
				var arg: int = int(op[3])
				var jump: bool = false
				match String(op[2]):
					"le":  jump = v <= arg
					"lt":  jump = v < arg
					"gt":  jump = v > arg
					"eq0": jump = v == 0
					"ne0": jump = v != 0
				pc = int(op[4]) if jump else pc + 16
			"goto":
				pc = int(op[1])
			"sound":
				sounds.append(int(op[1]))
				pc += 16
			"wait":
				wait_left = float(op[1]) * TICK
				freeze_anim = int(op[2]) != 0
				pc += 16
				return
			"anim":
				play_anim(int(op[1]))
				pc += 16
				return
			"set":
				vars[int(op[1])] = int(op[2])
				pc += 16
				return
			"add":
				vars[int(op[1])] = int(vars.get(int(op[1]), 0)) + int(op[2])
				pc += 16
				return
			"setfn":
				vars[int(op[1])] = _pred(String(op[2]), 0, sense)
				pc += 16
				return
			_:
				pc += 16
				return

## One AI tick. `sense` keys: see (bool), dist, bearing (0..2047),
## angle (absolute 0..2047), blocked (bool). Afterwards read `frame`,
## `frame_changed`, `sounds`, `firing_pose()` and `vars`.
func tick(delta: float, sense: Dictionary) -> void:
	sounds.clear()
	frame_changed = false
	_step_anim(delta)
	_script_acc += delta
	if pc != 0 and (_script_acc >= 1.0 / SCRIPT_HZ or delta <= 0.0):
		var dt: float = _script_acc
		_script_acc = 0.0
		_run_script(dt, sense)

## Script variable with a default (flyer altitude at 56, tank speed at
## 48, tank heading at 44 — the SET offsets used by the DOS scripts).
func var_or(offset: int, default: int) -> int:
	return int(vars.get(offset, default))
