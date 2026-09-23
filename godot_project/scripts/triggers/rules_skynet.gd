## SkyNET trigger rules — one read-only row per action id.
##
## Every entity of a MAP carries three bytes that decide what it does:
## an action id (a slot of the DOS handler table at Skynet.exe VA
## 0x59b00), a state byte and a link to the next entity of a chain.
## Until now the knowledge of what each id means lived in
## the long loop next to the code that ran it. This module is that
## knowledge on its own — data, no runtime — so three readers can share
## it: the running game (every class holds the constants by
## reference, so nothing about play changes), the generated trigger
## graph (scripts/triggers/trigger_graph.gd) and whatever checks the
## graph later.
##
## A row says:
##   kind      what the node IS (mover, exit, objective, prox_gate …)
##   family    the mover family behind the id, "" for the rest
##   p4 / p6   the handler slot's two config words (+4 low u16, +6 high
##             u16) — axis and travel for a mover, the sound id for a
##             one-shot, the radius for 0xF1/0xF2
##   fire      "edge"  the handler runs in the frame bit 0 goes UP
##             "level" the handler runs every tick bit 0 is set
##   on_fire   what the handler does to its own record afterwards:
##             "clear" bit 0 off, "retire" act ← 0xFF, "swap" act ← the
##             partner id, "force1" bit 0 forced back on, "none"
##   modes     how the node can be activated (chain / use key / walking
##             in / a shot / the objective counter / the end of a path),
##             with the measuring rule of each
##   dos       the handler address the row was read from
##   prov      "dos"        disassembled from the binary
##             "port"       the port's own rule, chosen deliberately
##             "unverified" a guess — nothing in the binary says so yet
##   note      what part of the row is tuning rather than DOS truth
##
## Provenance of the measuring point (owner's ruling, 2026-09-15): the
## 0xEF handler (v1.01 0x1386a0, fixed radius 0x3c) and the 0xF1/0xF2
## handler (0x138223, radius from its slot's +4 word) subtract the SAME
## globals [0xd49b4/b8/bc] and call the same 3-D distance routine
## 0x14d775 — the player's EYE. One constant for both, recorded here.
##
## Future Shock has its own table in shock.exe; rules_shock.gd is this
## one with the slots that game leaves empty turned inert and every row
## marked informational.

extends RefCounted

## Which game's table this is.
const GAME: String = "skynet"
## False: the rows below are what the running game follows.
const INFORMATIONAL: bool = false

# ---------------------------------------------------------------------
# Tables (moved here from the old long loop, unchanged)
# ---------------------------------------------------------------------
## Mover ids → [family, p4, p6] from the 0x59b00 table's per-slot
## config dword (+4 low u16, +6 high u16). Families by handler body
## (disassembled 2026-08-30 with tools/x86dis.py):
##   "slide"   0x137a28 (0x3f-0x7e): translate along DOS axis p4 (0=X,
##             1=Y, 2=Z) by p6 units at 70 u/s (140 when p6 >= 0x800);
##             the act parity flips at the limit → next trigger reverses.
##             BIGDOOR 0x41/0x42 = the two gate leaves sliding apart.
##   "swing"   0x137c6b (0x8d-92, 0xa5-ac, 0xc1-c6): rotate about axis
##             p4 by p6 11-bit units at 512/s (90°/s). 210DOOR0/1.
##   "jump"    0x137ad0 (0x30-35): instant translate by SIGNED p6.
##   "slide5f" 0x137d41: p4 speed base, p6<<4 travel.
##   "rot"     turn about one axis: with an angle (0x36-0x38, 1024 =
##             180 deg) a half turn that stops and reverses — the wall
##             monitors are flat two-sided panels and the turn IS the
##             picture change; with no angle (0x39-0x3e) a continuous
##             rotator (radar dish, globe, sky dome).
##   0xbd-0xc0 (0x137b33/0x137bce, disassembled 2026-09-06): diagonal
##             slides (x and z by the same step, the second pair x
##             negated) — but their table limit word is 0, so the step
##             is cancelled on the first tick: they flip their parity,
##             clear their bit and never move. A zero slide here.
const MOVER_TABLE: Dictionary = {
	0x30: ["jump", 0, 512], 0x31: ["jump", 0, 65024],
	0x32: ["jump", 1, 512], 0x33: ["jump", 1, 65024],
	0x34: ["jump", 2, 512], 0x35: ["jump", 2, 65024],
	0x36: ["rot", 0, 1024], 0x37: ["rot", 1, 1024], 0x38: ["rot", 2, 1024],
	0x39: ["rot", 0, 0], 0x3a: ["rot", 0, 0], 0x3b: ["rot", 1, 0],
	0x3c: ["rot", 1, 0], 0x3d: ["rot", 2, 0], 0x3e: ["rot", 2, 0],
	0x3f: ["slide", 0, 64], 0x40: ["slide", 0, 64], 0x41: ["slide", 0, 128],
	0x42: ["slide", 0, 128], 0x43: ["slide", 0, 256], 0x44: ["slide", 0, 256],
	0x45: ["slide", 0, 512], 0x46: ["slide", 0, 512], 0x59: ["slide", 1, 64],
	0x5a: ["slide", 1, 64], 0x5b: ["slide", 1, 128], 0x5c: ["slide", 1, 128],
	0x5d: ["slide", 1, 256], 0x5e: ["slide", 1, 256],
	0x5f: ["slide5f", 316, 128], 0x61: ["slide", 1, 512],
	0x62: ["slide", 1, 512], 0x63: ["slide", 1, 2048],
	0x64: ["slide", 1, 2048], 0x65: ["slide", 1, 2560],
	0x66: ["slide", 1, 2560], 0x67: ["slide", 1, 24], 0x68: ["slide", 1, 24],
	0x69: ["slide", 1, 768], 0x6a: ["slide", 1, 768], 0x6b: ["slide", 1, 480],
	0x6c: ["slide", 1, 480], 0x6d: ["slide", 1, 378], 0x6e: ["slide", 1, 378],
	0x6f: ["slide", 1, 1024], 0x70: ["slide", 1, 1024],
	0x71: ["slide", 1, 1520], 0x72: ["slide", 1, 1520],
	0x73: ["slide", 2, 64], 0x74: ["slide", 2, 64], 0x75: ["slide", 2, 128],
	0x76: ["slide", 2, 128], 0x77: ["slide", 2, 256], 0x78: ["slide", 2, 256],
	0x79: ["slide", 2, 512], 0x7a: ["slide", 2, 512], 0x7b: ["slide", 2, 640],
	0x7c: ["slide", 2, 640], 0x7d: ["slide", 2, 384], 0x7e: ["slide", 2, 384],
	0x8d: ["swing", 0, 256], 0x8e: ["swing", 0, 256], 0x8f: ["swing", 0, 512],
	0x90: ["swing", 0, 512], 0x91: ["swing", 0, 1024],
	0x92: ["swing", 0, 1024],
	# 0xa5/0xa6 belong to the SLIDE handler (0x138287 in v1.01, p4=1
	# p6=688), not to the rotator: they are the LIFT — MAP.233's 231EL
	# rises 688 units to the Cyberdyne roof. The port had them swinging,
	# so the elevator only turned on the spot (playtest 2026-09-12).
	0xa5: ["slide", 1, 688], 0xa6: ["slide", 1, 688],
	0xa7: ["swing", 1, 256], 0xa8: ["swing", 1, 256],
	0xa9: ["swing", 1, 512], 0xaa: ["swing", 1, 512],
	0xab: ["swing", 1, 1024], 0xac: ["swing", 1, 1024],
	0xbd: ["slide", 0, 0], 0xbe: ["slide", 0, 0],
	0xbf: ["slide", 0, 0], 0xc0: ["slide", 0, 0],
	0xc1: ["swing", 2, 256], 0xc2: ["swing", 2, 256],
	0xc3: ["swing", 2, 512], 0xc4: ["swing", 2, 512],
	0xc5: ["swing", 2, 1024], 0xc6: ["swing", 2, 1024],
}

## One-shot play-sound-and-disable nodes (handler 0x137dbd) — chains
## route through these to give doors/gates their sounds. The table's
## per-slot +4 word is the sound id (0..125, the 0x4ff00 sound table).
const SOUND_ONESHOT: Dictionary = {
	0xdb: 40, 0xdc: 41, 0xdd: 42, 0xde: 43, 0xdf: 44, 0xe0: 45,
	0xe1: 46, 0xe2: 47, 0xe3: 77, 0xe4: 93, 0xe5: 95, 0xe6: 109,
	0xe7: 110, 0xe8: 111, 0xe9: 112, 0xea: 113, 0xeb: 114,
}

## Water movers (0xd6-0xda, handler 0x121160): [DOS delta in units, the
## act this one turns into]. Delta 0 = the level goes to the entity's own
## Y. DOS Y grows downward, so a NEGATIVE delta raises the surface — the
## port flips the sign when it emits the target. 0xd9/0xda swap their own
## act byte, so they raise and lower in turn (MAP.254's valve maze).
const WATER_ACTS: Dictionary = {
	0xd6: [0, 0], 0xd7: [-170, 0], 0xd8: [140, 0],
	0xd9: [-112, 0xda], 0xda: [112, 0xd9],
}

# ---------------------------------------------------------------------
# Bands and single ids
# ---------------------------------------------------------------------
## Light handlers (0x137700.., disassembled 2026-09-06) — chains drive
## the variant-2 map lights: 0x01 toggles the light (XOR of the enable
## word's sign bit, one-shot), 0x02 flickers it while its bit is set
## (a random toggle about every other tick), 0x03 strobes (toggle every
## tick), 0x0d-0x0f fade UP by (act-12)/4 of the intensity per trigger,
## 0x10-0x12 fade DOWN by the same. 0x0a/0x0c are `ret` (nothing).
const ACT_LIGHT_TOGGLE: int = 0x01
const ACT_LIGHT_FLICKER: int = 0x02
const ACT_LIGHT_STROBE: int = 0x03
const ACT_LIGHT_FADE_UP_FIRST: int = 0x0D
const ACT_LIGHT_FADE_DOWN_LAST: int = 0x12

## Destructible mesh-swap per TRANSFRM.PRS damage stages (0x120433).
const ACT_DESTRUCT_A: int = 0x18
const ACT_DESTRUCT_B: int = 0x19
## Demolition (handler 0x1380bf, decoded 2026-09-05): when a chain
## enables the entity, the handler sets its HP to 1 if it has none and
## calls ObjHit with HP + 1 — the object dies through the normal
## destruction path (blast, drop, sound).
const ACT_DEMOLISH: int = 0x1B
## Message / mission-progress acts, split exactly as the DOS handler
## table does. Only the OBJECTIVE band moves the counter that ends a
## mission — treating the hints as objectives makes missions end at the
## first flavour line.
const ACT_HINT_FIRST: int = 0x1C        # [G1].. handler 0x13779d, message only
const ACT_HINT_LAST: int = 0x25
const ACT_OBJECTIVE_FIRST: int = 0x26   # [M1].. handler 0x1377d0, counter--
const ACT_OBJECTIVE_LAST: int = 0x2A
const ACT_FAIL: int = 0x2B              # handler 0x13782d: MISSION FAILED now
## Countdown relay (v1.01 handler 0x138038, disassembled 2026-09-11):
## while enabled, once the objective counter is above zero and equal to
## the table word (1 for 0x2C), flip the chain from itself, then off.
const ACT_RELAY: int = 0x2C
const RELAY_AT: int = 1
const ACT_VOICE: int = 0xED             # voice line (VOICE.PRS id at sub+2, 0x137dfd)
const ACT_SOUND_LOOP: int = 0xEE        # looping ambient (id at sub+2, 0x12a47a)
const ACT_PROX_GATE: int = 0xEF         # use-key gate, 60 units
const ACT_TELEPORT: int = 0xF0          # interior teleport
const ACT_PROX_CHAIN_A: int = 0xF1      # radius 256 (table +4)
const ACT_PROX_CHAIN_B: int = 0xF2      # radius 1024 (table +4)
## Spawn point (v1.01 0x129642 → 0x12960b): reveal the robot
## SpawnEnemiesInit (0x129500) built hidden at this sprite.
const ACT_SPAWN: int = 0xF3
const ACT_PICKUP: int = 0xFD            # collectable (0x11d670)
## 0x1A: variant-3 only, 0x137902 → 0x146600 with sub+2. Untraced.
const ACT_UNKNOWN_1A: int = 0x1A
## Ids DOS writes into a spent act byte — never dispatched.
const ACT_SPENT_FIRST: int = 0xFE

# ---------------------------------------------------------------------
# Movement tuning. The DOS handlers step 0x46/0x8c angle units per tick
# (~35 Hz) through a <<4 fixed-point accumulator — ≈153/306 units/s
# (27°/54° per second). Slide analogously from its p4 base. The FAMILY
# and the TRAVEL are DOS; the units per second are the port's reading of
# the tick rate.
# ---------------------------------------------------------------------
const SWING_SPEED: float = 512.0         # 11-bit units/s (0x137c6b: 0x200/s)
const SLIDE_SPEED_SLOW: float = 70.0     # units/s (0x137a28: 0x46/s)
const SLIDE_SPEED_FAST: float = 140.0    # units/s when p6 >= 0x800
const ROT_SPEED: float = 153.0           # continuous rotators
const SLIDE_SPEED_SCALE: float = 2.2     # 0x5f slide speed = p4 * this (units/s)

# ---------------------------------------------------------------------
# Path vehicles — DOS AI state 11, v1.01 handler 0x127400. An actor that
# drives a chain of placement MARKERS: the cargo truck into MAP.210's
# base, MAP.260's convoy, MAP.280's boss chase, and the HK that lifts the
# player off MAP.234's roof. Types 46-52 share the parameters (enemy
# table 0x44E00). The vehicles run on their own nodes since step 5f of
# docs/trigger_graph_plan.md (scripts/level/path_vehicle.gd), and read
# these from here rather than keeping a second copy beside them.
# ---------------------------------------------------------------------
const PATH_SPEED_K: float = 80.0 / 256.0        # segment speed = k · its length
const PATH_ACCEL: float = 160.0                 # units/s², from a standstill
const PATH_TURN: float = 128.0 / 2048.0 * TAU   # 22.5°/s, yaw only and visual
const PATH_REACH: float = 80.0                  # 3D distance that counts as arrived
## DOS ticks the actors in the 5×5 MAP-GRID cells around the player — the
## cell index, not a radius (0x12980f: edx = 5). A grid cell is 1024 units
## (64×64 cells over the 65536-unit map), so the window reaches two cells
## each way. The port used a 1024-unit radius, and the HK that lifts the
## player off MAP.234's roof waits 2413 units from where he arrives: it
## never started ("na strechu malo prísť HK a nepriletelo").
const PATH_TICK_CELL: float = 1024.0
const PATH_TICK_CELLS: int = 2
## The stop case walks at most this many links before giving up — the DOS
## loop has no guard and the shipped maps need none.
const PATH_MAX_HOPS: int = 64

# ---------------------------------------------------------------------
# Measuring constants (the runtime's, kept in one place)
# ---------------------------------------------------------------------
const PROX_GATE_RADIUS: float = 60.0        # 0xEF (v1.01 0x1386a0, cmp 0x3c)
const PROX_CHAIN_A_RADIUS: float = 256.0    # 0xF1 slot +4
const PROX_CHAIN_B_RADIUS: float = 1024.0   # 0xF2 slot +4
## Added to the DOS 60-unit gate radius: the DOS player stands where the
## port's capsule cannot (a gate mesh's origin is inside its collider), and
## MAP data places gates 32..79 units from the doorway sprite they guard.
const PLAYER_RADIUS: float = 26.0
## A 0xF0 doorway sprite is also armed by the player touching it directly
## (handler 0x137881: "player touch arms state bit 0").
const TELEPORT_TOUCH_RADIUS: float = 90.0
## Vertical window for the port's own 2D tests — stacked interior floors
## put doorways directly above/below each other.
const PROX_VERTICAL_WINDOW: float = 512.0
## Use key reach for a wall button the crosshair is not on
## (Behaviour.use_nearby's fallback, and where the checks stand).
const USE_REACH: float = 130.0
## …and how far the CROSSHAIR itself reaches (fly_camera._try_activate's
## ray). That is a wall button's real measure, and the owner's kept rule
## says so: it answers the key instead of proximity, so a proximity radius
## is not what limits it — MAP.210's base doors are opened by a button
## three hundred units up a tower wall, which no radius in the original
## would reach.
const USE_RAY: float = 600.0
## The step the destructible handler (v1.01 0x120833, v1.00 0x120433)
## adds to an object's damage counter, one call at a time; the stage it
## shows is counter >> 4. The handler is passed no damage value, so this
## is a whole stage per qualifying hit and never a fraction of one.
const DESTRUCT_DAMAGE_PER_STAGE: float = 16.0

# ---------------------------------------------------------------------
# Kinds
# ---------------------------------------------------------------------
const KINDS: PackedStringArray = [
	"none", "light", "destructible", "demolish", "hint", "objective", "fail",
	"relay", "mover", "water", "sound_cue", "sound_loop", "voice",
	"prox_gate", "exit", "prox_chain", "spawn", "pickup", "inert",
	"marker", "undecoded",
]

## What a node with no row at all is: a handler slot nothing here has
## decoded. The graph turns one of these into a warning, never an error.
const UNDECODED: Dictionary = {
	"kind": "undecoded", "family": "", "p4": 0, "p6": 0,
	"fire": "edge", "on_fire": "none", "dos": "", "prov": "unverified",
	"note": "no row in this table — the handler slot is not decoded",
	"modes": [{"mode": "chain"}],
}

## Acts 0x01-0x12 are the LIGHT handlers, and a light is a VARIANT-2
## record. Those handlers work on that record's own sub-fields — the
## intensity u16 at sub+0 and the enable i16 at sub+8 (map_file.gd §
## "Sub-record layout by variant") — and a variant-1 mesh keeps its
## pitch and roll Euler angles in the same bytes, a variant-3 sprite its
## sprite index. So the act byte alone no more makes a light than a
## marker's act byte makes an objective: the record decides, exactly as
## MARKER_KIND decides for a placement marker.
##
## Six variant-1 meshes of the shipped maps carry act 0x01, and the
## running game has never lit one: a record joins the light sweep only
## when `(flags & 3) == 2` (RawAction.sweep_class), and nothing else
## dispatches the act at all. The graph read them as lamps, which put six
## fade/toggle effects in the lock that nothing in the game performs.
const NOT_A_LIGHT: Dictionary = {
	"kind": "inert", "family": "", "p4": 0, "p6": 0,
	"fire": "edge", "on_fire": "none", "dos": "", "prov": "port",
	"note": "a light act on a record that is not a light: the 0x137700 handlers write the variant-2 intensity/enable words, which this variant keeps other data in",
	"modes": [{"mode": "chain"}],
}

# ---------------------------------------------------------------------
# Marker rules — a marker is classified by its TYPE, never by its act
# byte. A placement marker's sub-record keeps other data where a sprite
# keeps its act (an enemy marker's "act" is its enemy type), so reading
# the byte puts half the campaign's robots in the objective band.
# Types from MapScanMarkers FUN_0011c519 and its consumers.
# ---------------------------------------------------------------------
const MARKER_KIND: Dictionary = {
	0: "spawn_set", 1: "spawn_set", 2: "enemy_start", 3: "ceiling",
	4: "radiation", 5: "unused", 6: "maptype", 7: "compass",
	8: "background_rad", 9: "unused",
	30: "border", 31: "border", 32: "border", 33: "border", 34: "border",
	35: "border", 36: "border", 37: "border", 38: "border", 39: "border",
	100: "mp_spawn", 101: "mp_jeep", 102: "mp_hk",
	103: "water_plane", 104: "water_plane",
	105: "path_loop",
}
## Types 10..29 are the deathmatch spawn ring (scripts/net/).
const MARKER_MP_FIRST: int = 10
const MARKER_MP_LAST: int = 29
## The marker a vehicle path loops back to its head at.
const MARKER_PATH_LOOP: int = 105
## Border boxes are read in PAIRS (engine FUN_00122711).
const MARKER_BORDER_FIRST: int = 30
const MARKER_BORDER_LAST: int = 39

# ---------------------------------------------------------------------
# Variant maps — one world, shipped several times over
# ---------------------------------------------------------------------
## Which map numbers are RE-AUTHORED VERSIONS of one world, and of which
## world: MAP.216 is MAP.210 after the truck ride and MAP.217 is MAP.210
## after the lasers — the same ground, the same buildings, another crop of
## robots and other chains. DOS keeps an Mst overlay per map NUMBER, so
## it carries nothing between them and the player meets his own dead
## again; the port carries what he did across (main._carry_records), and
## this table is the committed list of where that may happen at all
## (docs/trigger_graph_plan.md §4). It replaces a search that took any
## visited map of the same mission sharing 60 % of its meshes — which
## could only ever guess.
##
## The two worlds are the census of the shipped data (map_dump
## --mission=all, 2026-09-16: "MAP.210 → MAP.216 → MAP.217" and
## "MAP.230 → MAP.235 → MAP.234"), and the mesh census (--variants=)
## agrees: the members of each share 89-98 % of their placed meshes at
## the same coordinates. Not the ground under them — mission 1's phases
## bring a heightmap of their own, and only mission 3's keep MAP.230's —
## which is why a phase is loaded whole rather than patched.
##
## What is deliberately NOT here, though the mesh census pairs them:
##   240 ~ 250 (93 %)  mission 4's harbour and mission 5's are two
##                     missions, each with an overlay of its own
##   210 ~ 220 (82 %)  the same about mission 1's base and mission 2's
##   270 ~ 272 (82 %)  no mission reaches MAP.272 — nothing can carry
##   200 ~ 202 (98 %)  loose maps outside the campaign
const VARIANTS: Dictionary = {216: 210, 217: 210, 234: 230, 235: 230}

## The world a map number belongs to — itself, unless it is a variant.
static func world_of(map_num: int) -> int:
	return int(VARIANTS.get(map_num, map_num))

## May state carry from map `a` into map `b`? Only between two DIFFERENT
## members of one world.
static func same_world(a: int, b: int) -> bool:
	return a != b and world_of(a) == world_of(b)

## Is this table informational only (Future Shock's is)? A static call
## rather than a plain constant, so a caller holding either module in a
## variable can ask the same question of both.
static func informational() -> bool:
	return INFORMATIONAL

static func game_name() -> String:
	return GAME

## What a light act DOES, in one word — the name the graph writes into
## its effects, the lock pins and the event bus announces, so the three
## cannot drift apart. (Only meaningful on a variant-2 record; see
## NOT_A_LIGHT.)
static func light_op(act: int) -> String:
	match act:
		ACT_LIGHT_TOGGLE: return "toggle"
		ACT_LIGHT_FLICKER: return "flicker"
		ACT_LIGHT_STROBE: return "strobe"
	if act >= ACT_LIGHT_FADE_UP_FIRST and act < 0x10:
		return "fade_up"
	return "fade_down"

static func marker_kind(marker_type: int) -> String:
	if MARKER_KIND.has(marker_type):
		return String(MARKER_KIND[marker_type])
	if marker_type >= MARKER_MP_FIRST and marker_type <= MARKER_MP_LAST:
		return "mp_spawn"
	if marker_type >= 0 and marker_type < 100:
		return "spawn_set"
	return "unused"

# ---------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------
static var _rules: Dictionary = {}
static var _hash: String = ""

## act id → rule. Built once.
static func all_rules() -> Dictionary:
	if _rules.is_empty():
		_rules = _build()
	return _rules

## The rule of one act id — UNDECODED when the table has no row.
static func rule_for(act: int) -> Dictionary:
	var r: Variant = all_rules().get(act)
	return r if r is Dictionary else UNDECODED

static func has_rule(act: int) -> bool:
	return all_rules().has(act)

static func kind_of(act: int) -> String:
	return String(rule_for(act)["kind"])

## Does this act id drive one of the 0x59b00 MOVER handlers — a door, a
## gate, a lift, a rotator? The table above is the whole answer, and the
## bake asks it to decide which records become Mover nodes.
static func is_mover(act: int) -> bool:
	return MOVER_TABLE.has(act)

## …and is it one of the two TRANSFRM.PRS destructible slots (0x18/0x19,
## the same handler with a different first parameter)?
static func is_destructible(act: int) -> bool:
	return act == ACT_DESTRUCT_A or act == ACT_DESTRUCT_B

## The rule of an act byte AS CARRIED BY A PARTICULAR RECORD. The table
## above is keyed by the act alone, but two of the bands only mean what
## they say on the right kind of record — see NOT_A_LIGHT. `variant` is
## the record's `flags & 3` (1 mesh/actor, 2 light, 3 sprite/marker).
static func rule_for_record(act: int, variant: int) -> Dictionary:
	var r: Dictionary = rule_for(act)
	if variant != 2 and String(r["kind"]) == "light":
		return NOT_A_LIGHT
	return r

## A short, stable fingerprint of the whole table: the generated graphs
## carry it and rebuild themselves when a row changes. JSON.stringify
## sorts keys, so the same table always hashes the same.
static func rules_hash() -> String:
	if _hash.is_empty():
		var acts: Array = all_rules().keys()
		acts.sort()
		var parts: PackedStringArray = PackedStringArray()
		parts.append("game=%s informational=%s" % [GAME, INFORMATIONAL])
		for a in acts:
			parts.append("%02x=%s" % [int(a), JSON.stringify(all_rules()[a])])
		var mts: Array = MARKER_KIND.keys()
		mts.sort()
		for mt in mts:
			parts.append("m%d=%s" % [int(mt), String(MARKER_KIND[mt])])
		# The per-RECORD rules (rule_for_record) are rules too: a change to
		# one has to rebuild every stored graph, like a change to a row.
		parts.append("notalight=%s" % JSON.stringify(NOT_A_LIGHT))
		parts.append("r=%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f"
			% [PROX_GATE_RADIUS, PROX_CHAIN_A_RADIUS, PROX_CHAIN_B_RADIUS,
			   PLAYER_RADIUS, TELEPORT_TOUCH_RADIUS, PROX_VERTICAL_WINDOW,
			   USE_RAY])
		_hash = ";".join(parts).sha256_text().substr(0, 16)
	return _hash

## What a mover act comes to: family, DOS axis, the span of the travel,
## the direction sign and the speed, all from MOVER_TABLE and the
## constants above. The one answer for the running game (each mover node
## reads it at registration — scripts/level/mover.gd adopt) and for the
## generated graph. level_behaviour.mover_params is the bake's own copy,
## and builds nothing but the animation the editor plays.
static func mover_params(act: int) -> Dictionary:
	var cfg: Array = MOVER_TABLE[act]
	var fam: String = String(cfg[0])
	var p4: int = int(cfg[1])
	var limit: int = int(cfg[2])
	if limit >= 0x8000:
		limit -= 0x10000                        # signed i16
	# Slide/swing handlers step +p6 for odd act ids and -p6 for even
	# ones; the other families flip on a negative limit instead.
	var sgn: float = 1.0 if (act & 1) != 0 else -1.0
	if fam != "rot" and fam != "slide" and limit < 0:
		sgn = -sgn
	var span: float = absf(float(limit))
	match fam:
		"slide5f":
			span = absf(float(limit << 4))      # p6<<4 travel distance
		"rot":
			# Only a slot with NO angle is a full turn, looped. The three
			# that carry one (0x36-0x38, p6 = 1024) are the wall monitors,
			# and their handler (v1.01 0x138577, disassembled 2026-09-16) is
			# not a travel at all: `add eax, edx / and eax, 0x7ff` puts the
			# whole 1024 — half of the 2048-unit circle — on the angle in a
			# single tick and then `and byte [esi+0x12], 0xfe` clears the
			# enable bit. The mask makes it self-inverse, so the next
			# trigger turns the panel back. Until 2026-09-16 this line gave
			# them 2048 as well, and the graph read every monitor as a
			# continuous rotator (spin@) while the runtime ran it as the
			# 1024-unit half turn the table says. Since step 5e the
			# runtime reads its travel from HERE, so there is one answer;
			# level_behaviour.mover_params, which builds the bake's own
			# animation of the same travel, still says 2048 — and nothing
			# plays that animation.
			if limit == 0:
				span = 2048.0
	var speed: float = SWING_SPEED
	match fam:
		"slide":
			speed = SLIDE_SPEED_FAST if span >= 2048.0 else SLIDE_SPEED_SLOW
		"slide5f":
			speed = float(p4) * SLIDE_SPEED_SCALE
		"jump":
			speed = 0.0                         # instant
		"rot":
			# …and a monitor's half turn is instant, like a jump: its
			# handler has no rate in it at all (see above — the whole 1024
			# goes on in one tick and the bit comes down on the way out).
			# Only the slots with NO angle turn at a rate, and that is the
			# continuous one.
			speed = ROT_SPEED if limit == 0 else 0.0
	return {"family": fam, "axis": clampi(p4, 0, 2), "p4": p4, "span": span,
		"sign": sgn, "speed": speed}

## One row with the defaults filled in.
static func _row(kind: String, extra: Dictionary) -> Dictionary:
	var r: Dictionary = {
		"kind": kind, "family": "", "p4": 0, "p6": 0,
		"fire": "edge", "on_fire": "clear", "dos": "", "prov": "unverified",
		"note": "", "modes": [{"mode": "chain"}],
	}
	for k in extra:
		r[k] = extra[k]
	return r

static func _build() -> Dictionary:
	var r: Dictionary = {}
	# --- No handler at all ---------------------------------------------
	# ObjDoAction (FUN_00139698) returns at once for an act of 0: such an
	# entity is a plain prop, a damageable one when its state bits say so,
	# or a RELAY a chain merely passes through on its way to the next link
	# (MAP.280's fence ring, the rails of MAP.260).
	r[0x00] = _row("none", {"prov": "dos", "on_fire": "none",
		"note": "act 0: no handler — a prop, or a relay a chain passes through"})
	# --- Lights (variant-2 entities; 0x0a/0x0c are `ret`) -------------
	r[ACT_LIGHT_TOGGLE] = _row("light", {"dos": "0x137700", "prov": "dos",
		"p6": 1, "note": "op toggle: XOR the enable word's sign bit, then clear bit 0"})
	r[ACT_LIGHT_FLICKER] = _row("light", {"dos": "0x137713", "prov": "dos",
		"fire": "level", "on_fire": "none", "p6": 2,
		"note": "op flicker: a random toggle per tick while bit 0 is set"})
	r[ACT_LIGHT_STROBE] = _row("light", {"dos": "0x13773b", "prov": "dos",
		"fire": "level", "on_fire": "none", "p6": 3,
		"note": "op strobe: toggle every tick while bit 0 is set"})
	for a in range(ACT_LIGHT_FADE_UP_FIRST, 0x10):
		r[a] = _row("light", {"dos": "0x137772", "prov": "dos", "p6": a,
			"note": "op fade up by (id-12)/4 of the intensity, then clear bit 0"})
	for a in range(0x10, ACT_LIGHT_FADE_DOWN_LAST + 1):
		r[a] = _row("light", {"dos": "0x137747", "prov": "dos", "p6": a,
			"note": "op fade down by (id-12)/4 of the intensity, then clear bit 0"})
	for a in [0x0A, 0x0C]:
		r[a] = _row("inert", {"dos": "", "prov": "dos", "on_fire": "none",
			"note": "the handler is a bare `ret`"})
	# --- Empty slots (no handler at all, 2026-09-06 audit) ------------
	for a in [0x14, 0x17, 0x2D, 0xFE, 0xFF]:
		r[a] = _row("inert", {"prov": "dos", "on_fire": "none",
			"note": "empty handler slot; 0xfe/0xff are what DOS writes into a spent act byte"})
	# --- Destruction ---------------------------------------------------
	# 0x18 and 0x19 are ONE handler (both slots of the 0x59e00 table hold
	# 0x000f0833, i.e. v1.01 0x120833) told apart by the slot's p4 word.
	# With p4 = 0 — that is 0x19 — the handler clears its own enable bit at
	# entry (0x120845 tests the word, 0x120858 calls the state routine with
	# 0xfe) and then adds a flat 16 to the damage counter: one stage per
	# enable, which is what both rows say here. With p4 = 4 — 0x18 — it
	# clears nothing and adds p4 << 4 scaled by the frame time (0x120893),
	# four stages a second for as long as its bit is up: a machine chewing
	# through a wall rather than a single blow.
	# That ramp is NOT modelled, and it cannot be reached to be tested:
	# the shipped data holds 15 act-0x18 records, every one of them with no
	# way in at all (mode `-` in the lock — no state bits, no use key) and
	# no chain in any map walks into one, so nothing can ever set their bit
	# (checked over the whole lock, 2026-09-22). Modelling it would be
	# writing code no player can run.
	#
	# What DOES decide whether either of them does anything is the object's
	# own mesh: the handler's first move is to look it up in the transform
	# table (0x120879 `call 0x12078a`, carry set when the name is not in
	# it) and the next instruction is `jb` to the exit. Half the cars the
	# maps place have no template because they ARE another car's last stage
	# (CARHIP0C is the third frame of CARHIP0A's), and shooting one of
	# those does nothing at all. The generated graph reads TRANSFRM.PRS for
	# exactly that since step 5g (trigger_graph.stage_templates).
	for a in [ACT_DESTRUCT_A, ACT_DESTRUCT_B]:
		r[a] = _row("destructible", {"dos": "0x120433", "prov": "dos",
			"note": "one TRANSFRM.PRS damage stage per enable, and nothing at all when the mesh has no template; the %.0f points a stage is the port's step%s"
				% [DESTRUCT_DAMAGE_PER_STAGE,
				   " (0x18 carries p4 = 4 and ramps four stages a second while enabled instead, and clears no bit of its own — not modelled, and unreachable in the shipped data)"
					if a == ACT_DESTRUCT_A else ""]})
	r[ACT_DEMOLISH] = _row("demolish", {"dos": "0x1380bf", "prov": "dos",
		"note": "variant 1 only: hp = max(hp, 1) then ObjHit(hp + 1)"})
	# --- Messages, objectives, the counter -----------------------------
	for a in range(ACT_HINT_FIRST, ACT_HINT_LAST + 1):
		r[a] = _row("hint", {"dos": "0x13779d", "prov": "dos",
			"on_fire": "retire", "p6": a - ACT_HINT_FIRST,
			"note": "[G%d]: a message, no counter" % (a - ACT_HINT_FIRST + 1)})
	for a in range(ACT_OBJECTIVE_FIRST, ACT_OBJECTIVE_LAST + 1):
		r[a] = _row("objective", {"dos": "0x1377d0", "prov": "dos",
			"on_fire": "retire", "p6": a - ACT_OBJECTIVE_FIRST,
			"note": "[M%d]: the mission counter goes down by one" % (a - ACT_OBJECTIVE_FIRST + 1)})
	r[ACT_FAIL] = _row("fail", {"dos": "0x13782d", "prov": "dos",
		"on_fire": "retire", "note": "the mission is lost the moment this fires"})
	r[ACT_RELAY] = _row("relay", {"dos": "0x138038", "prov": "dos",
		"fire": "level", "p4": RELAY_AT,
		"modes": [{"mode": "chain"}, {"mode": "counter", "at": RELAY_AT}],
		"note": "fires when the objective counter is above zero and equals the slot word"})
	# --- Movers ---------------------------------------------------------
	var mover_dos: Dictionary = {
		"jump": "0x137ad0", "rot": "0x137a28", "slide": "0x137a28",
		"slide5f": "0x137d41", "swing": "0x137c6b",
	}
	for a in MOVER_TABLE:
		var cfg: Array = MOVER_TABLE[a]
		var fam: String = String(cfg[0])
		var zero: bool = int(cfg[2]) == 0 and fam == "slide"
		r[a] = _row("mover", {
			"family": fam, "p4": int(cfg[1]), "p6": int(cfg[2]),
			"fire": "level", "on_fire": "clear",
			"dos": "0x137b33" if zero else String(mover_dos.get(fam, "")),
			"prov": "dos",
			"note": ("a zero slide: the slot's limit word is 0, so it flips its parity, clears its bit and never moves"
				if zero else
				"the DOS handler steps a fixed-point accumulator per tick; the units/s the port runs it at are calibration"),
		})
	# --- Water ----------------------------------------------------------
	for a in WATER_ACTS:
		var w: Array = WATER_ACTS[a]
		r[a] = _row("water", {"dos": "0x121160", "prov": "dos",
			"p4": int(w[0]), "p6": int(w[1]),
			"on_fire": "swap" if int(w[1]) != 0 else "clear",
			"note": "DOS Y grows downward: a negative delta raises the surface; delta 0 = go to the entity's own Y"})
	# --- Sounds and voice ------------------------------------------------
	for a in SOUND_ONESHOT:
		r[a] = _row("sound_cue", {"dos": "0x137dbd", "prov": "dos",
			"p4": int(SOUND_ONESHOT[a]),
			"note": "plays the slot's sound id once and clears its own bit"})
	r[0xEC] = _row("undecoded", {"dos": "0x137dbd", "prov": "unverified",
		"on_fire": "none",
		"note": "the 2026-08-30 note puts 0xdb-0xec in the one-shot sound family, but no id was read for this slot"})
	r[ACT_VOICE] = _row("voice", {"dos": "0x137dfd", "prov": "dos",
		"note": "VOICE.PRS line id at sub+2"})
	r[ACT_SOUND_LOOP] = _row("sound_loop", {"dos": "0x12a47a", "prov": "dos",
		"fire": "level", "on_fire": "none",
		"note": "ambient loop, id at sub+2, handle at sub+4"})
	# --- The player-driven ones -------------------------------------------
	r[ACT_PROX_GATE] = _row("prox_gate", {"dos": "0x1386a0", "prov": "dos",
		"fire": "edge", "on_fire": "force1", "p6": int(PROX_GATE_RADIUS),
		"modes": [{
			"mode": "use_key", "origin": "eye", "metric": "3d",
			"radius": PROX_GATE_RADIUS, "pad": PLAYER_RADIUS,
			"requires": "state&6 in {0,6}", "edge": "key-down",
			"rearm": "always", "latch": "none",
			"prov": "port",
			"note": "DOS runs the handler in the frame ACTIVATE goes down (cmp [0x2c7f],1); the %.0f-unit pad is the port's, for a capsule that cannot stand where the DOS player did"
				% PLAYER_RADIUS,
		}],
		"note": "the handler never looks at bit 0 — a gate is always live — and forces its own bit back on inside ObjFlipLink"})
	# The 0xF0 handler, decoded from the v1.01 bytes at 0x138081 (the
	# v1.00 0x137881 + the 0x13xxxx band's 0x800), 2026-09-16:
	#   the target map goes into the pending-map register, the marker set
	#   into its own, `or [0x30a50], 0x20` asks for the map change, and
	#   `and byte [esi+edi+5], 0xfe` clears the node's OWN bit 0 inline —
	#   it does NOT retire its act byte the way an objective does
	#   (0x139e09, which it never calls). ObjDoAction dispatches it on
	#   every frame the bit is up, so the self-clear is the only thing
	#   making it once-per-rise, and a chain re-arming it would fire it
	#   again. It cannot be SEEN to: the frame loop tests that 0x20 at
	#   0x117a2e, before the next entity sweep, and tears the level down —
	#   one map change per level instance, always. The port's own latch
	#   (Behaviour.exit_taken) is that outcome; the graph's simulation
	#   stops at the first exit for the same reason (trigger_graph._simulate).
	r[ACT_TELEPORT] = _row("exit", {"dos": "0x137881", "prov": "dos",
		"modes": [
			{"mode": "chain", "edge": "bit0-rise", "note": "an exit a chain enables fires at once"},
			{"mode": "touch_arm", "origin": "feet", "metric": "2d+window",
			 "radius": TELEPORT_TOUCH_RADIUS, "window": PROX_VERTICAL_WINDOW,
			 "edge": "enter", "prov": "port",
			 "note": "touching the doorway ARMS bit 0; the use key takes it — the port's 2D test, a doorway sprite hangs above the floor"},
		],
		"note": "target map at sub+2 (0 = back the way we came), spawn-marker set at sub+4; the handler holds no latch, but the map change it asks for ends the level instance before any handler runs again"})
	for a in [ACT_PROX_CHAIN_A, ACT_PROX_CHAIN_B]:
		var rad: float = PROX_CHAIN_A_RADIUS if a == ACT_PROX_CHAIN_A else PROX_CHAIN_B_RADIUS
		r[a] = _row("prox_chain", {"dos": "0x138223", "prov": "dos",
			"fire": "edge", "on_fire": "clear", "p4": int(rad),
			"modes": [{
				"mode": "prox_enter", "origin": "eye", "metric": "3d",
				"radius": rad, "pad": 0.0, "requires": "bit0",
				"edge": "enter", "rearm": "chain", "latch": "port",
				"prov": "dos",
				"note": "DOS re-arms at once — it fires again the moment a chain turns its bit back on, even with the player still inside (owner's ruling 2026-09-15); the port's leave/re-enter latch is the `latch` field"},
			],
			"note": "radius from the slot's +4 word; the handler ends by clearing its own bit (0x139644 with -2), so it is one-shot until a chain re-arms it"})
	r[ACT_SPAWN] = _row("spawn", {"dos": "0x129142", "prov": "unverified",
		"note": "reveals the robot SpawnEnemiesInit built hidden at this sprite; 0x1290eb's lookup is untraced"})
	r[ACT_PICKUP] = _row("pickup", {"dos": "0x11d670", "prov": "dos",
		"fire": "level", "on_fire": "none",
		"note": "a collectable, assigned at map start from the 0x35800 item table; no chain behaviour"})
	r[ACT_UNKNOWN_1A] = _row("undecoded", {"dos": "0x137902", "prov": "unverified",
		"on_fire": "none",
		"note": "variant 3 only: calls 0x146600 with sub+2 — untraced"})
	return r
