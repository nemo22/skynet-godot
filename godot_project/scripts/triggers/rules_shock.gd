## Future Shock trigger rules — SkyNET's table with the slots that game
## leaves empty turned inert, and every row marked informational.
##
## Future Shock ships its own engine (shock.exe) and its own handler
## table; nothing in it has been disassembled yet. The port runs SkyNET's
## act tables on Future Shock's maps, which is right for the families the
## two games share and wrong wherever the tables differ — so the graph of
## a Future Shock map is built, read and reviewed, but it is NOT a source
## of truth: `INFORMATIONAL` is true, every row's provenance is
## "unverified", and an act the table cannot decode is a warning rather
## than an error.
##
## The empty slots below come from the census of Future Shock's own maps
## (docs plan §3): 0x13, 0x2f and 0x47-0x58 are never used there, and the
## game has no destructible mesh-swap (0x18/0x19), no countdown relay
## (0x2C), no water movers (0xd6-0xda) and no spawn points (0xf3) —
## SkyNET features whose ids must not be read into a Future Shock map.

extends RefCounted

const Skynet := preload("res://scripts/triggers/rules_skynet.gd")

const GAME: String = "shock"
## True: nothing here is verified against shock.exe.
const INFORMATIONAL: bool = true

## Slots this game leaves empty, or SkyNET ids it does not have.
const EMPTY_SLOTS: PackedInt32Array = [
	0x13, 0x2F,
	0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50,
	0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
	Skynet.ACT_DESTRUCT_A, Skynet.ACT_DESTRUCT_B, Skynet.ACT_RELAY,
	0xD6, 0xD7, 0xD8, 0xD9, 0xDA, Skynet.ACT_SPAWN,
]

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

static func informational() -> bool:
	return INFORMATIONAL

static func game_name() -> String:
	return GAME

static func marker_kind(marker_type: int) -> String:
	return Skynet.marker_kind(marker_type)

## The mover families are the one thing the two games plainly share (the
## same .3D doors on the same slot ids); the numbers come from SkyNET's
## table until shock.exe's own is read.
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
		var row: Dictionary = (Skynet.all_rules()[a] as Dictionary).duplicate(true)
		# Nothing in shock.exe has been read: no row here may claim more.
		row["prov"] = "unverified"
		row["note"] = ("SkyNET's row, run on this game's maps unchecked — "
			+ String(row.get("note", ""))).strip_edges()
		out[int(a)] = row
	for a in EMPTY_SLOTS:
		out[int(a)] = {
			"kind": "inert", "family": "", "p4": 0, "p6": 0,
			"fire": "edge", "on_fire": "none", "dos": "", "prov": "unverified",
			"note": "this game leaves the slot empty (map census)",
			"modes": [{"mode": "chain"}],
		}
	return out
