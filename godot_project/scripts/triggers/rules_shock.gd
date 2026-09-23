## Future Shock trigger rules — SkyNET's table, unchanged.
##
## The reference for Future Shock is SkyNET v1.01 (GAME.EXE), not
## shock.exe: the DOS SkyNET engine runs Future Shock's data as it is,
## the whole campaign, when its data directory holds that game's files.
## What the port reproduces is therefore SkyNET's engine on Future
## Shock's maps, and SkyNET's rows ARE this game's rows.
##
## Checked in the v1.01 disassembly (2026-09-24):
##   - the data path is the fixed string "gamedata\" (two copies, used by
##     the file-name builders 0x1460d5 and 0x149fab); nothing probes which
##     game the directory holds. INSTALL.DAT's "fspath" key is read at
##     start-up into a global that no code reads again.
##   - the handler table at VA 0x59b00 is static data; nothing swaps it.
##   - the act handlers (0x137f00-0x138800, 0x11d970, 0x120833, 0x121160,
##     0x129642, 0x12a97a) and the chain/move helpers 0x139600-0x139f00
##     test only the network bits of [0x30a50] (0x40000 = a net game,
##     0x1000000 = the host) and the countdown HUD bit [0x30a54] & 8 —
##     no game or data-set flag. So no act behaves differently on Future
##     Shock data, and EMPTY_SLOTS is empty: an id Future Shock's maps
##     never use simply never fires.
##
## shock.exe, Future Shock's own standalone engine, is older and is NOT
## the reference. A per-act diff of its handler table against GAME.EXE's
## (kept outside the repo) found 42 slots identical, 85 different (mostly
## sound/text/network helpers, the mover's move routine and 0x1a's
## countdown display), 4 only in shock.exe (0x04-0x07, bare `ret`) and
## 23 only in SkyNET (0x18/0x19, 0x2c, 0x45/0x46, 0x6d-0x72, 0xa5/0xa6,
## 0xbd-0xc0, 0xd6-0xda, 0xf3). None of that applies to the port.

extends RefCounted

const Skynet := preload("res://scripts/triggers/rules_skynet.gd")

const GAME: String = "shock"
## False: the engine that runs this game's data is SkyNET's, whose rows
## are what the running game follows.
const INFORMATIONAL: bool = false

## Ids GAME.EXE treats differently on Future Shock data: none (header).
const EMPTY_SLOTS: PackedInt32Array = []

const KINDS: PackedStringArray = Skynet.KINDS
const UNDECODED: Dictionary = Skynet.UNDECODED
const NOT_A_LIGHT: Dictionary = Skynet.NOT_A_LIGHT
const MARKER_PATH_LOOP: int = Skynet.MARKER_PATH_LOOP
const MARKER_BORDER_FIRST: int = Skynet.MARKER_BORDER_FIRST
const MARKER_BORDER_LAST: int = Skynet.MARKER_BORDER_LAST
const ACT_PROX_GATE: int = Skynet.ACT_PROX_GATE
const ACT_TELEPORT: int = Skynet.ACT_TELEPORT
const ACT_PROX_CHAIN_A: int = Skynet.ACT_PROX_CHAIN_A
const ACT_PROX_CHAIN_B: int = Skynet.ACT_PROX_CHAIN_B
const ACT_RELAY: int = Skynet.ACT_RELAY
const ACT_SPAWN: int = Skynet.ACT_SPAWN
const ACT_HINT_FIRST: int = Skynet.ACT_HINT_FIRST
const ACT_OBJECTIVE_FIRST: int = Skynet.ACT_OBJECTIVE_FIRST
const ACT_FAIL: int = Skynet.ACT_FAIL
const PROX_GATE_RADIUS: float = Skynet.PROX_GATE_RADIUS
const PLAYER_RADIUS: float = Skynet.PLAYER_RADIUS
const TELEPORT_TOUCH_RADIUS: float = Skynet.TELEPORT_TOUCH_RADIUS
const PROX_VERTICAL_WINDOW: float = Skynet.PROX_VERTICAL_WINDOW
const DESTRUCT_DAMAGE_PER_STAGE: float = Skynet.DESTRUCT_DAMAGE_PER_STAGE

## No world of this game is known to be shipped twice. Future Shock's
## maps have never been censused for it, and the two games number their
## maps their own way, so SkyNET's list must not be read into this one.
## Empty means nothing carries between Future Shock maps — which is what
## DOS does anyway, an overlay per map number.
const VARIANTS: Dictionary = {}

static var _rules: Dictionary = {}
static var _hash: String = ""

static func all_rules() -> Dictionary:
	if _rules.is_empty():
		_rules = _build()
	return _rules

static func rule_for(act: int) -> Dictionary:
	var r: Variant = all_rules().get(act)
	return r if r is Dictionary else UNDECODED

static func has_rule(act: int) -> bool:
	return all_rules().has(act)

static func kind_of(act: int) -> String:
	return String(rule_for(act)["kind"])

## Classified by the RECORD, not the act byte alone — the light band
## only means a light on a variant-2 record (Skynet.NOT_A_LIGHT). The
## sub-record layout is the MAP format's, not either engine's table, so
## this holds for Future Shock's maps as it does for SkyNET's.
static func rule_for_record(act: int, variant: int) -> Dictionary:
	var r: Dictionary = rule_for(act)
	if variant != 2 and String(r["kind"]) == "light":
		return NOT_A_LIGHT
	return r

static func world_of(map_num: int) -> int:
	return int(VARIANTS.get(map_num, map_num))

static func same_world(a: int, b: int) -> bool:
	return a != b and world_of(a) == world_of(b)

static func informational() -> bool:
	return INFORMATIONAL

static func game_name() -> String:
	return GAME

static func marker_kind(marker_type: int) -> String:
	return Skynet.marker_kind(marker_type)

## SkyNET's engine moves Future Shock's doors with its own table.
static func mover_params(act: int) -> Dictionary:
	return Skynet.mover_params(act)

static func rules_hash() -> String:
	if _hash.is_empty():
		var acts: Array = all_rules().keys()
		acts.sort()
		var parts: PackedStringArray = PackedStringArray()
		parts.append("game=%s informational=%s" % [GAME, INFORMATIONAL])
		for a in acts:
			parts.append("%02x=%s" % [int(a), JSON.stringify(all_rules()[a])])
		parts.append("notalight=%s" % JSON.stringify(NOT_A_LIGHT))
		_hash = ";".join(parts).sha256_text().substr(0, 16)
	return _hash

static func _build() -> Dictionary:
	var out: Dictionary = {}
	for a in Skynet.all_rules():
		out[int(a)] = (Skynet.all_rules()[a] as Dictionary).duplicate(true)
	for a in EMPTY_SLOTS:
		out[int(a)] = {
			"kind": "inert", "family": "", "p4": 0, "p6": 0,
			"fire": "edge", "on_fire": "none", "dos": "", "prov": "dos",
			"note": "GAME.EXE treats this id differently on Future Shock data",
			"modes": [{"mode": "chain"}],
		}
	return out
