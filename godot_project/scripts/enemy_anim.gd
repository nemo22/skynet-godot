## Per-mesh enemy animation tables, extracted from the FutureShock32
## Win32 fan-port (`fshock_ida.c:75909-79912`). Each mesh family
## registers a "processor" callback that allocates `AnimRecord` structs
## (40 bytes) with explicit `(start, end, fps, loops)` values — that's
## the data we mirror here.
##
## Each enemy table maps a state name → `[start_frame, end_frame, fps,
## loops]`. State names: "idle", "walk", "run", "attack", "hit",
## "death", "fall", "gib". An anim with `fps == 0.0` uses the engine
## default (10 fps in our port). `loops` (bool): true = hold last frame
## when it cycles, false = one-shot.
##
## Meshes WITHOUT an entry here fall back to a heuristic in enemy.gd:
## walk = full frame strip, death = trailing 1/3 capped at 8 frames.
## That covers turrets, vehicles, drones — DOS has no walk cycle for
## them either; the frame strip is engines / rotors.

extends RefCounted

const DEFAULT_FPS: float = 10.0

## Endoskel + reskins (T600 / T800 family) — all share processor
## `sub_428140` (`fshock_ida.c:79204`). Frame ranges decoded from the
## per-anim writes between line 79313 (anim 0) and line 79610 (anim 12).
const T800_FAMILY: Dictionary = {
	"idle":   [1, 1, 10.0, true],
	"walk":   [6, 20, 10.0, true],
	"run":    [24, 30, 5.0, false],
	"attack": [31, 37, 5.0, false],
	"hit":    [38, 40, 5.0, false],
	"fall":   [42, 45, 10.0, false],
	"death":  [46, 60, 10.0, false],
	"gib":    [61, 63, 10.0, false],
}

## The deathmatch avatars — AVSOLDER / AVFEMALE / AVTRMNTR and their
## heads. They share one authoring (the frame-to-frame vertex deltas of
## the soldier and of the terminator agree to two decimals: one skeleton,
## several skins), so one table serves them all. No fan-port processor
## covers them, so this was MEASURED off the vertex data on 2026-09-12
## instead of decoded:
##   0      the reference pose — 17.9 u deep, arms at the sides; not a
##          pose to stand in, though it is the one the port used to show
##   1-6    standing still: small deltas, the stance unchanged
##   7-14   walking: the stride opens and closes, 72.9 -> 31.7 -> 72.8 u
##   15-24  running: the longest stride, 79 u, over the lowest shoulders
##   29-34  dying: the body's height collapses from 78 u to 31 u
## Two entries are read with less confidence: 25-28 are four sharply
## different poses (19-31 u apart), taken here as the hit stagger, and
## 35-41 a second small in-place cycle, taken as the firing pose. Both
## are one-shots, so a misreading twitches rather than breaks the body.
const AVATAR: Dictionary = {
	"idle":   [1, 6, 6.0, true],
	"walk":   [7, 14, 10.0, true],
	"run":    [15, 24, 14.0, true],
	"hit":    [25, 28, 12.0, false],
	"death":  [29, 34, 10.0, false],
	"attack": [35, 41, 12.0, false],
}

## Flencer (the small jumping robot). Just an idle pose + a single
## walk / strike cycle — the rest of the body is animated by
## per-bone blend calls instead of more AnimRecords.
const FLENCER: Dictionary = {
	"idle": [0, 7, 10.0, true],
	"walk": [8, 20, 15.0, false],
}

const GRABBER: Dictionary = {
	"idle":   [0, 5, 5.0, false],
	"walk":   [6, 12, 10.0, false],
	"run":    [13, 19, 15.0, false],
	"attack": [20, 25, 15.0, false],
	"death":  [26, 38, 15.0, false],
}

const WELDRARM: Dictionary = {
	"idle":   [0, 8, 5.0, false],
	"walk":   [9, 13, 10.0, false],
	"run":    [14, 19, 15.0, false],
	"attack": [20, 25, 15.0, false],
	"death":  [26, 37, 15.0, false],
}

const TREX_HED: Dictionary = {
	"idle":   [1, 10, 10.0, false],
	"attack": [11, 20, 10.0, false],
}

## Single combined loop — RAPTOR has no separate idle / attack state.
const RAPTOR: Dictionary = {
	"walk": [5, 19, 10.0, true],
}

const SPIDBOT: Dictionary = {
	"walk": [4, 21, 10.0, true],
}

const TREX_LEG: Dictionary = {
	"walk": [4, 20, 10.0, true],
}

## Ground speed of a walker, in units per second, measured from its own
## walk cycle by `tools/walk_probe.gd`.
##
## A DOS walker (AI state 7, handler 0x13be00) does NOT travel at the
## `speed` in the enemy type table. Every animation frame the handler
## calls 0x13c104, which takes a reference vertex of the model
## (`ref[prev] - ref[cur]`, a per-frame byte table picks which one),
## rotates it by the actor's yaw and adds it to the position — root
## motion off the planted foot. The cycles are authored in place, so the
## planted foot slides backwards through the model by exactly the
## distance the actor advances; the probe measures that.
##
## The table value is roughly twice as fast (endoskeleton 140 vs 59),
## which is what "terminátori sa nejak moc rýchlo hýbu" looks like: the
## model glides over its own footsteps.
const WALK_SPEED: Dictionary = {
	"endoskel": 60.0, "endorfl": 59.0,
	"t600pst": 59.0, "t600rfl": 59.0,
	"t800pst": 59.0, "t800rfl": 59.0,
	"raptor": 74.0,                       # table 100
	"spidbot": 57.0,                      # table 100
	"t-rexleg": 74.0,                     # table 150
}

## Measured walk speed for a mesh base name, or 0.0 when the cycle has
## not been measured (turrets, vehicles, drones — they have no gait).
static func walk_speed(mesh_base: String) -> float:
	return float(WALK_SPEED.get(mesh_base.to_lower(), 0.0))

## Look up a mesh's animation table by base name (case-insensitive).
## Returns an empty Dictionary when the mesh has no fan-port entry —
## enemy.gd then falls back to the full-strip heuristic.
static func table_for(mesh_base: String) -> Dictionary:
	var nm := mesh_base.to_lower()
	# T800 family — shared processor `sub_428140`.
	if nm in [
		"endoskel", "endorfl",
		"t600pst", "t600rfl", "t800pst", "t800rfl",
	]:
		return T800_FAMILY
	# The MP avatar bodies and their heads, which animate in step.
	if nm.begins_with("avsol") or nm.begins_with("avfem") \
			or nm.begins_with("avbtc") or nm.begins_with("avtrm") \
			or nm == "avbutch":
		return AVATAR
	match nm:
		"flencer":  return FLENCER
		"grabber":  return GRABBER
		"weldrarm": return WELDRARM
		"t-rexhed": return TREX_HED
		"raptor":   return RAPTOR
		"spidbot":  return SPIDBOT
		"t-rexleg": return TREX_LEG
	return {}
