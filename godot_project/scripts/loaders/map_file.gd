## MAP file loader.
##
## Ported from fsh32_port/src/loaders/map.c. Provides the header, the
## 8-char asset name table, and an iterator over the entity grid.
##
## Layout:
##   0..3   u32 cell_count
##   4..7   u32 grid_width
##   8..11  u32 grid_height
##   12..15 u32 payload_offset = 0x253C
##   16..19 u32 sentinel = 0xFFFFFFFF
##   20..   8-byte asset names (NUL-padded), until invalid slot
##   0x253C cell grid (W*H × u32 entity-list offset)
##
## Entity block (48 bytes):
##   +0    u32 next_off (next entity in cell; -2 = end of chain)
##   +4    u32 reserved
##   +8    i32 X     (world units, 1024 per cell)
##   +12   i32 Y     (game Y-down: negative = above terrain)
##   +16   i32 Z
##   +20   u8  flags  (see below)
##   +21   u32 sub_record_ptr (always = entity_off + 25)
##   +25.. variant-specific sub-record (see below)
##
## Flag bits (skynet_gh.c Map_ToScene FUN_00136519:38186-38266):
##   & 0x03  variant: 1 = static mesh / actor, 2 = light source,
##           3 = billboard sprite
##   & 0x08  skip this entity entirely
##   & 0x40  actor — a variant-1 entity that is an ENEMY/NPC. Enemy
##           meshes live in MDMDENMS.BSA; the current animation frame
##           is held in a linked actor record at +0x16.
##
## Sub-record layout by variant:
##   variant 1: +0..11 3× i32 Euler angles (pitch/yaw/roll) in 11-bit
##              units (& 0x7FF, 0..2047 = 0°..360°); +12..13 u16 name_index
##   variant 2: +0..1  u16 light_intensity; +8..9 i16 light_enable.
##              FUN_0011b733 = AddLightSafe — variant 2 is a dynamic
##              LIGHT source, NOT an enemy spawner (verified
##              skynet_gh.c:38244-38249).
##   variant 3: +0..1  u16 sprite_index — billboard sprite, UNLESS
##              (value >> 7) == 299: then the entity is a placement
##              MARKER. marker_type = value & 0x7F (2 = enemy start);
##              enemy-type ID byte at sub+10. Enemies are placed this
##              way, NOT as variant-1 actors (FUN_0011c519 MapScanMarkers
##              / FUN_00129f39 EnemiesStartMarked, skynet_gh.c).

extends RefCounted

const PAYLOAD_OFFSET: int = 0x253C
const DICT_OFFSET: int = 20
const HEADER_SENTINEL: int = 0xFFFFFFFF
const NAME_LEN: int = 8
## Head pointer of the per-name default list (Map_SetDefault): nodes of
## {i32 next, i16 name index, u32 link record, u16 hp, u8 state}.
const DEFAULTS_HEAD: int = 0x233C
## Shortest valid entity block (variant 2: 25 + 10 bytes).
const BLOCK_MIN: int = 35

## On-disk length of an entity block for its flags byte (variant in
## bits 0-1): 48 / 35 / 36 bytes for variants 1 / 2 / 3.
static func block_length(flags: int) -> int:
	match flags & 3:
		1: return 48
		2: return 35
	return 36

class Entity:
	var cell_x: int = 0
	var cell_z: int = 0
	var x: int = 0
	var y: int = 0
	var z: int = 0
	var flags: int = 0
	## File offset of this entity's 48-byte block — index key for the
	## switch→door link chain (`MapFile.entities_by_off`).
	var file_off: int = 0
	## Variant 1 only: asset name index into MapFile.names[].
	var name_index: int = -1
	## Variant 3 only: sprite index for a billboard. Resolved against
	## MDMDIMGS.BSA in DOS (FUN_0014ea20); high bits select a sprite bank.
	var sprite_index: int = -1
	## Variant 3 only: when (sprite_index >> 7) == 299 the entity is a
	## placement MARKER, not a billboard. marker_type = sprite_index &
	## 0x7F — 2 = enemy start marker (FUN_0011c519 / FUN_00129f39).
	var marker_type: int = -1
	## Variant 3 enemy marker only: enemy-type ID byte at sub+10.
	var enemy_type: int = -1
	## Type byte bit 7 — a convoy actor (DOS actor+0xc |= 0x4000).
	var convoy: bool = false
	## Variant 2 only: light intensity passed to AddLightSafe
	## (FUN_0011b733). Variant 2 is a dynamic LIGHT source, not a spawner.
	var light_intensity: int = -1
	## Variant 2 only: enable gate (i16 at sub+8); the light is emitted
	## only when this is > 0.
	var light_enable: int = 0
	## Variant 1 only: 3× i32 Euler angles at sub+0/+4/+8, 11-bit units
	## (& 0x7FF, 2048 = 360°). Order verified against FUN_0014e100 +
	## FUN_00150284 (skynet_gh.c): the engine builds R = Rz·Rx·Ry.
	var off_x: int = 0   ## pitch — rotation about X (sub+0)
	var off_y: int = 0   ## yaw   — rotation about Y (sub+4)
	var off_z: int = 0   ## roll  — rotation about Z (sub+8)
	## ObjFlipLink chain (skynet_gh.c FUN_001394aa, line 39791).
	## `state_byte` is the per-variant flag byte the engine flips when the
	## switch is hit. Bits 1 + 2 set (`& 6 != 0`) marks the entity as
	## damageable / switchable — the trigger for the chain walk.
	##   variant 1: sub+0x12   variant 2: sub+2   variant 3: sub+5
	## `link_next` is the file offset of the next chained entity (≤ 0
	## terminates). `link_act_type` is the action dispatch type — the
	## index into the DAT_00059b00 handler table (fully dumped from
	## Skynet.exe; families in scripts/triggers/rules_skynet.gd):
	##   slide/swing/rot ids  doors, gates, lifts, rotators (movers)
	##   0x18/0x19            TRANSFRM.PRS destructible mesh-swap
	##   0xEF                 60-unit player-proximity gate
	##   0xF1/0xF2            proximity-gated chain trigger (256/1024)
	##   0xF0                 interior teleport (exit_map/exit_marker_id)
	##   variant 1: read from link record (sub+0x13 → +5 next / +9 type)
	##   variant 2: sub+4 next, sub+3 type
	##   variant 3: sub+6 next, sub+10 type
	var state_byte: int = 0
	var link_next: int = 0
	var link_act_type: int = 0
	## Variant 1 only: hit points (u16 at sub+0xe). The ObjHit path
	## (skynet_gh.c:39475) fires the entity's action when bit1 of the
	## state byte is set (every hit) or bit2 + HP depleted (destroyed).
	var hp: int = 0
	## Variant 3 only: interior-teleport data read by the 0xF0 handler
	## (Skynet.exe 0x137881): u16 at sub+2 = target map suffix (0 =
	## return to the previous map), u8 at sub+4 = spawn-marker set in
	## the target map (facing marker = id + 1).
	var exit_map: int = 0
	var exit_marker_id: int = 0
	## Variant 1: file offset of the 10-byte link record in effect (the
	## entity's own, or the per-name default from the 0x233C list) and
	## the destruction data it carries: byte 0 = destruction type into
	## the Skynet.exe 0x423d6 table (effect sprites, drop, sound), i16
	## at +1 = blast parameter for type 0 (FUN_00124293).
	var link_off: int = 0
	var destroy_type: int = 0
	var destroy_param: int = 0
	## True when hp / state_byte / link came from the map's per-name
	## default list (Map_SetDefault, skynet_gh.c:37960): on disk the
	## entity holds hp 0 / link -2, so an editor export must not write
	## the resolved values back into the sub-record.
	var uses_defaults: bool = false

class MapFile:
	## Per-name defaults from the 0x233C list: name index -> {hp, state, link}.
	var defaults: Dictionary = {}
	var grid_width: int = 0
	var grid_height: int = 0
	var names: Array[String] = []
	var entities: Array[Entity] = []
	## entity_file_offset → Entity. Built by parse() so a chain walk can
	## resolve `link_next` offsets back into Entity objects.
	var entities_by_off: Dictionary = {}

static func _u32(bytes: PackedByteArray, off: int) -> int:
	return bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16) | (bytes[off + 3] << 24)

static func _u16(bytes: PackedByteArray, off: int) -> int:
	return bytes[off] | (bytes[off + 1] << 8)

static func _s16(bytes: PackedByteArray, off: int) -> int:
	var v: int = bytes[off] | (bytes[off + 1] << 8)
	return v - 0x10000 if v >= 0x8000 else v

static func _s32(bytes: PackedByteArray, off: int) -> int:
	var v: int = _u32(bytes, off)
	if v >= 0x80000000: v -= 0x100000000
	return v

## Same name-validity heuristic as map.c:slot_looks_like_name. Accepts
## 8-byte ASCII slots where the first byte is alnum and all bytes up to
## the first NUL are alnum/_/-/.
static func _slot_looks_like_name(bytes: PackedByteArray, off: int) -> bool:
	var c0: int = bytes[off]
	# alnum check
	if not (((c0 >= 0x30 and c0 <= 0x39)
		  or (c0 >= 0x41 and c0 <= 0x5A)
		  or (c0 >= 0x61 and c0 <= 0x7A))):
		return false
	var n: int = 0
	for i in NAME_LEN:
		var c: int = bytes[off + i]
		if c == 0: break
		if c < 0x20 or c > 0x7E: return false
		# alnum + _ - .
		var ok := (c >= 0x30 and c <= 0x39) \
			   or (c >= 0x41 and c <= 0x5A) \
			   or (c >= 0x61 and c <= 0x7A) \
			   or c == 0x5F or c == 0x2D or c == 0x2E
		if not ok: return false
		n += 1
	return n >= 1

static func parse(bytes: PackedByteArray) -> MapFile:
	if bytes == null or bytes.size() < PAYLOAD_OFFSET:
		return null
	if _u32(bytes, 12) != PAYLOAD_OFFSET: return null
	if _u32(bytes, 16) != HEADER_SENTINEL: return null

	var gw: int = _u32(bytes, 4)
	var gh: int = _u32(bytes, 8)
	if gw == 0 or gh == 0 or gw > 1024 or gh > 1024: return null

	var m := MapFile.new()
	m.grid_width = gw
	m.grid_height = gh

	# Names: 8-byte slots from offset 0x14. The header carries no count
	# and the slots are not NUL-padded (leftover bytes follow short
	# names — MAP.231 slot 51 is "PC", NUL, "ZZYYX"), and the region after the
	# last name holds other data that can look like text ("XXXXXXXX"),
	# so the table cannot be walked with a shape heuristic alone: the
	# old "3+ name characters" rule stopped MAP.231 at that "PC" and
	# dropped 38 names — every mesh past it vanished (the -28 hall had
	# no east wall, the rec room floated in black). The entities are
	# the authority: read exactly max(name_index) + 1 slots, filled in
	# after the entity walk below (_read_names).

	# Per-name defaults (Map_SetDefault, skynet_gh.c:37960): every
	# variant-1 entity WITHOUT a link record of its own (sub+0x13 < 1)
	# takes hp / state byte / link record from the node for its mesh
	# name. That is where crates get their 50 HP and ammo drop, cars
	# 150-350 HP, the DISH its rotator action, buttons their 0xEF gate.
	var dnode: int = _s32(bytes, DEFAULTS_HEAD)
	var dguard: int = 0
	while dnode > 0 and dnode + 13 <= bytes.size() and dguard < 4096:
		dguard += 1
		m.defaults[_s16(bytes, dnode + 4)] = {
			"hp": _u16(bytes, dnode + 10), "state": bytes[dnode + 12],
			"link": _s32(bytes, dnode + 6)}
		dnode = _s32(bytes, dnode)

	# Entity grid at 0x253C.
	var cgrid: int = PAYLOAD_OFFSET
	if cgrid + gw * gh * 4 > bytes.size():
		# A grid running past the end of the file is a truncated or corrupt
		# MAP. It used to come back as a valid map with no entities (the
		# level loaded as an empty world); null makes callers report it.
		push_warning("[map] %dx%d cell grid runs past the end of the file (%d bytes)"
			% [gw, gh, bytes.size()])
		return null

	# Every entity block is walked at most once, and no file holds more
	# blocks than fit in it. Only a self-loop A -> A used to be caught: an
	# A -> B -> A cycle added 1 024 copies per cell, so a crafted 4 MB MAP
	# could ask for a billion Entity objects (skipped 0x08 blocks looped
	# without allocating, a billion iterations instead). No MAP of SkyNET or
	# Future Shock reaches a block twice (all 267 checked, longest cell
	# chain 147), so real maps parse exactly as before.
	var visited: Dictionary = {}
	var max_blocks: int = bytes.size() / BLOCK_MIN
	for cz in gh:
		for cx in gw:
			var ci: int = cz * gw + cx
			var e_off: int = _u32(bytes, cgrid + ci * 4)
			var safety: int = 0
			while e_off != 0 and e_off != 0xFFFFFFFF and e_off != 0xFFFFFFFE \
					and e_off + BLOCK_MIN <= bytes.size() and safety < 1024:
				if visited.has(e_off) or visited.size() >= max_blocks:
					break
				visited[e_off] = true
				safety += 1
				var nxt_for_continue: int = _u32(bytes, e_off)
				var flags_byte: int = bytes[e_off + 20]
				# Block length depends on the variant: 25-byte head + sub-
				# record of 23 (variant 1, incl. the link pointer), 10
				# (variant 2) or 11 (variant 3) bytes. The LAST block of a
				# file is often a 36-byte variant-3 record and may be the
				# HEAD of its cell chain (MAP.211 cell 2,2 / MAP.212 cell
				# 1,2 hold the truck interiors' start marker, door and exit);
				# a flat 48-byte bound silently dropped those whole cells.
				if e_off + block_length(flags_byte) > bytes.size():
					break
				# flags & 0x08 → DOS engine skips this entity entirely
				# (SKYNET.EXE.c:65936). We honour the same skip here.
				if (flags_byte & 0x08) != 0:
					if nxt_for_continue == e_off: break
					e_off = nxt_for_continue
					continue

				var e := Entity.new()
				e.cell_x = cx
				e.cell_z = cz
				e.file_off = e_off
				e.x = _s32(bytes, e_off + 8)
				e.y = _s32(bytes, e_off + 12)
				e.z = _s32(bytes, e_off + 16)
				e.flags = flags_byte
				# +21..24 is a u32 pointer to the outer sub-record; in
				# every MAP file we've inspected it equals e_off + 25,
				# i.e. the sub-record is inlined directly after the
				# +21 field. We still read the pointer to follow the
				# DOS engine convention.
				var sub_ptr: int = _u32(bytes, e_off + 21)
				if sub_ptr <= 0 or sub_ptr + 16 > bytes.size():
					sub_ptr = e_off + 25
				# Sub-record layout differs per variant (SKYNET.EXE.c
				# :65941-66012). See memory: map-indoor-outdoor.
				var variant: int = e.flags & 3
				match variant:
					1:
						# Static mesh / actor. 3× i32 Euler angles
						# (pitch/yaw/roll) + u16 name index.
						e.off_x = _s32(bytes, sub_ptr + 0)   # pitch
						e.off_y = _s32(bytes, sub_ptr + 4)   # yaw
						e.off_z = _s32(bytes, sub_ptr + 8)   # roll
						e.name_index = bytes[sub_ptr + 12] \
							| (bytes[sub_ptr + 13] << 8)
						# Switch/link chain. The variant-1 sub-record at
						# +0x12 is the flag byte; +0x13 is the file offset
						# of a 10-byte link record holding the chain's
						# action type (+9) and next-object pointer (+5).
						if sub_ptr + 0x17 <= bytes.size():
							e.hp = bytes[sub_ptr + 0x0e] \
								| (bytes[sub_ptr + 0x0f] << 8)
							e.state_byte = bytes[sub_ptr + 0x12]
							var link_off: int = _s32(bytes, sub_ptr + 0x13)
							if link_off < 1 and (e.flags & 0x40) == 0 and m.defaults.has(e.name_index):
								var d: Dictionary = m.defaults[e.name_index]
								e.hp = int(d["hp"])
								e.state_byte = int(d["state"])
								link_off = int(d["link"])
								e.uses_defaults = true
							e.link_off = link_off
							if link_off > 0 and link_off + 10 <= bytes.size():
								e.link_act_type = bytes[link_off + 9]
								e.link_next = _s32(bytes, link_off + 5)
								e.destroy_type = bytes[link_off]
								e.destroy_param = _s16(bytes, link_off + 1)
					2:
						# Dynamic light source (FUN_0011b733 = AddLightSafe).
						# u16 intensity at sub+0, i16 enable gate at sub+8.
						e.light_intensity = bytes[sub_ptr + 0] \
							| (bytes[sub_ptr + 1] << 8)
						e.light_enable = bytes[sub_ptr + 8] \
							| (bytes[sub_ptr + 9] << 8)
						# Chain fields inline at sub+2/+3/+4.
						if sub_ptr + 8 <= bytes.size():
							e.state_byte = bytes[sub_ptr + 2]
							e.link_act_type = bytes[sub_ptr + 3]
							e.link_next = _s32(bytes, sub_ptr + 4)
					3:
						# Billboard sprite OR placement marker. u16 at
						# sub+0: if (>>7) == 299 the entity is a marker
						# (marker_type 2 = enemy start), otherwise it is a
						# billboard sprite index.
						e.sprite_index = bytes[sub_ptr + 0] \
							| (bytes[sub_ptr + 1] << 8)
						if (e.sprite_index >> 7) == 299:
							e.marker_type = e.sprite_index & 0x7F
							# Bit 7 of the type byte marks a CONVOY actor:
							# EnemiesStartMarked (FUN_0012a439) strips it and
							# sets actor+0xc |= 0x4000. MAP.260's nine convoy
							# vehicles are 174/175/177/178 = 46/47/49/50 | 0x80,
							# and reading the byte unmasked put them past every
							# table, so the whole convoy silently vanished.
							e.enemy_type = bytes[sub_ptr + 10] & 0x7F
							e.convoy = (bytes[sub_ptr + 10] & 0x80) != 0
						# Teleport target data (0xF0 handler layout).
						e.exit_map = bytes[sub_ptr + 2] \
							| (bytes[sub_ptr + 3] << 8)
						e.exit_marker_id = bytes[sub_ptr + 4]
						# Chain fields inline at sub+5/+6/+10.
						if sub_ptr + 11 <= bytes.size():
							e.state_byte = bytes[sub_ptr + 5]
							e.link_next = _s32(bytes, sub_ptr + 6)
							e.link_act_type = bytes[sub_ptr + 10]
				m.entities.append(e)
				m.entities_by_off[e_off] = e
				if nxt_for_continue == e_off: break  # defensive self-loop
				e_off = nxt_for_continue
	if visited.size() >= max_blocks:
		push_warning("[map] more entity blocks than the file can hold — entity walk cut at %d" % max_blocks)
	_read_names(m, bytes)
	return m

## Fill m.names with as many 8-byte slots as the variant-1 entities
## reference. A slot that does not start with a name character (the
## data past the table) is stored empty so its entities stay unnamed.
static func _read_names(m: MapFile, bytes: PackedByteArray) -> void:
	var count: int = 0
	for e in m.entities:
		if (e.flags & 3) == 1 and e.name_index >= 0 and e.name_index < 1024:
			count = maxi(count, e.name_index + 1)
	var off: int = DICT_OFFSET
	for i in count:
		if off + NAME_LEN > PAYLOAD_OFFSET:
			break
		var nm := ""
		if _slot_looks_like_name(bytes, off):
			var name_bytes := bytes.slice(off, off + NAME_LEN)
			var nul_at := name_bytes.find(0)
			if nul_at < 0: nul_at = NAME_LEN
			nm = name_bytes.slice(0, nul_at).get_string_from_ascii()
		m.names.append(nm)
		off += NAME_LEN

## Resolve an entity's name (or empty string).
static func entity_name(m: MapFile, e: Entity) -> String:
	if m == null or e == null or e.name_index < 0 or e.name_index >= m.names.size():
		return ""
	return m.names[e.name_index]

