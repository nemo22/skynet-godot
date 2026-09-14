## Writes an edited editor map scene (map_scene.gd) back into the MAP
## file format.
##
## The MAP layout is only partly understood, so the writer never
## re-serialises: it patches the original bytes kept in MapRoot.raw.
## Every entity node's record (MapEntityRec) and transform are compared
## with what the file holds and only differences are written:
##
##   position / angles   node transform wins when it was moved in the
##                       editor, otherwise the record's DOS fields
##                       (editable in the inspector) — 11-bit angles
##                       replace only the low bits of the raw words
##   state / link / hp / sprite / marker / exit / light fields
##                       from the record (variant-specific offsets)
##   cell chains         an entity whose cell (x/1024, z/1024) changed
##                       is unlinked from its old cell list and linked
##                       at the head of the new one — DOS walks these
##                       lists per cell for everything
##   deleted nodes       unlinked and flagged 0x08 (engine skip)
##   duplicated nodes    a node whose file_off another node already
##                       used gets a copy of the source block appended
##                       at the end of the file and linked into its cell
##
## An unedited scene therefore round-trips byte for byte.

extends RefCounted

const MapEntityRec := preload("res://scripts/editor/map_entity_rec.gd")
## Static paths only: the editor plugin runs this without the autoloads.
const Paths := preload("res://scripts/skynet_paths.gd")

const PAYLOAD_OFFSET: int = 0x253C
## Shortest entity block (variant 2) — chain walks stop before it would overrun.
const BLOCK_MIN: int = 35
const CELL_UNITS: int = 1024
const END_A: int = 0xFFFFFFFF
const END_B: int = 0xFFFFFFFE
const SKIP_FLAG: int = 0x08
const MARKER_Y_LIFT: int = 0x10

## Edited maps are written here (the mods folder: res://mods in a
## checkout, beside the game data in a release); the level loader prefers
## them over the MDMDMAP2.BSA entry. "" for a map name that is not a plain
## file name.
static func mod_path(map_name: String) -> String:
	var m: String = map_name.to_upper()
	if m.is_empty() or m.contains("..") \
			or RegEx.create_from_string("^[A-Z0-9_.\\-]+$").search(m) == null:
		push_error("[mapwriter] refused map name %s" % map_name)
		return ""
	return "%s/maps/%s" % [Paths.mods_dir(), m]

# ---------------------------------------------------------------------
# byte helpers
# ---------------------------------------------------------------------
static func _u32(b: PackedByteArray, o: int) -> int:
	return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

static func _s32(b: PackedByteArray, o: int) -> int:
	var v := _u32(b, o)
	return v - 0x100000000 if v >= 0x80000000 else v

static func _put32(b: PackedByteArray, o: int, v: int) -> void:
	v = v & 0xFFFFFFFF
	b[o] = v & 0xFF
	b[o + 1] = (v >> 8) & 0xFF
	b[o + 2] = (v >> 16) & 0xFF
	b[o + 3] = (v >> 24) & 0xFF

static func _put16(b: PackedByteArray, o: int, v: int) -> void:
	b[o] = v & 0xFF
	b[o + 1] = (v >> 8) & 0xFF

static func _is_end(v: int) -> bool:
	return v == 0 or v == END_A or v == END_B

# ---------------------------------------------------------------------
# cell chains
# ---------------------------------------------------------------------
## Every entity offset reachable from the cell grid → cell index.
static func _chain_map(b: PackedByteArray, gw: int, gh: int) -> Dictionary:
	var out: Dictionary = {}
	for ci in gw * gh:
		var e := _u32(b, PAYLOAD_OFFSET + ci * 4)
		var guard := 0
		while not _is_end(e) and e + BLOCK_MIN <= b.size() and guard < 4096:
			guard += 1
			if out.has(e):
				break
			out[e] = ci
			e = _u32(b, e)
	return out

## Remove `off` from cell `ci`'s list (head or predecessor patched).
static func _unlink(b: PackedByteArray, ci: int, off: int) -> bool:
	var head_at := PAYLOAD_OFFSET + ci * 4
	var e := _u32(b, head_at)
	if e == off:
		_put32(b, head_at, _u32(b, off))
		return true
	var guard := 0
	while not _is_end(e) and e + BLOCK_MIN <= b.size() and guard < 4096:
		guard += 1
		var nxt := _u32(b, e)
		if nxt == off:
			_put32(b, e, _u32(b, off))
			return true
		e = nxt
	return false

## Put `off` at the head of cell `ci`'s list.
static func _link_head(b: PackedByteArray, ci: int, off: int) -> void:
	var head_at := PAYLOAD_OFFSET + ci * 4
	var head := _u32(b, head_at)
	_put32(b, off, head if not _is_end(head) or head == END_B else END_A)
	_put32(b, head_at, off)

static func _cell_of(x: int, z: int, gw: int, gh: int) -> int:
	var cx: int = clampi(int(floor(float(x) / CELL_UNITS)), 0, gw - 1)
	var cz: int = clampi(int(floor(float(z) / CELL_UNITS)), 0, gh - 1)
	return cz * gw + cx

# ---------------------------------------------------------------------
# angles
# ---------------------------------------------------------------------
## The loader builds B = Rz(-roll)·Rx(pitch)·Ry(yaw) (global-axis
## rotations applied yaw, pitch, roll). Recover the three 11-bit angles.
static func basis_from_angles(pitch: int, yaw: int, roll: int) -> Basis:
	var b := Basis()
	b = b.rotated(Vector3.UP, (yaw & 0x7FF) * TAU / 2048.0)
	b = b.rotated(Vector3.RIGHT, (pitch & 0x7FF) * TAU / 2048.0)
	b = b.rotated(Vector3.BACK, -((roll & 0x7FF) * TAU / 2048.0))
	return b

static func angles_from_basis(b: Basis) -> Vector3i:
	# Godot's ZXY Euler order composes Rz·Rx·Ry — exactly the loader's
	# product with (x, y, z) = (pitch, yaw, -roll).
	var e: Vector3 = b.orthonormalized().get_euler(EULER_ORDER_ZXY)
	return Vector3i(_to11(e.x), _to11(e.y), _to11(-e.z))

static func _to11(rad: float) -> int:
	return int(round(wrapf(rad, 0.0, TAU) / TAU * 2048.0)) & 0x7FF

# ---------------------------------------------------------------------
# writer
# ---------------------------------------------------------------------
## Node kinds by the group node they live under.
enum Kind { MESH, ENEMY, MARKER, SPRITE, LIGHT }

static func _kind(node: Node, rec: Resource) -> int:
	var v: int = int(rec.get("variant"))
	if v == 1:
		return Kind.MESH
	if v == 2:
		return Kind.LIGHT
	if int(rec.get("marker_type")) == 2:
		return Kind.ENEMY
	if int(rec.get("marker_type")) >= 0:
		return Kind.MARKER
	return Kind.SPRITE

## Godot position the scene builder gave this record.
static func _expected_pos(kind: int, dos: Vector3i, node: Node3D) -> Vector3:
	match kind:
		Kind.ENEMY, Kind.MARKER:
			return Vector3(float(dos.x), -float(dos.y + MARKER_Y_LIFT), -float(dos.z))
		Kind.SPRITE:
			# Y depends on the terrain; compare X/Z only.
			return Vector3(float(dos.x), node.position.y, -float(dos.z))
	return Vector3(float(dos.x), -float(dos.y), -float(dos.z))

## DOS coordinates for a node that was moved in the editor.
static func _dos_from_pos(kind: int, p: Vector3, old: Vector3i) -> Vector3i:
	match kind:
		Kind.ENEMY, Kind.MARKER:
			return Vector3i(int(round(p.x)), int(round(-p.y)) - MARKER_Y_LIFT, int(round(-p.z)))
		Kind.SPRITE:
			return Vector3i(int(round(p.x)), old.y, int(round(-p.z)))
	return Vector3i(int(round(p.x)), int(round(-p.y)), int(round(-p.z)))

## Collect [node, rec] pairs under the map root.
static func _entity_nodes(root: Node) -> Array:
	var out: Array = []
	for grp in ["Entities", "Enemies", "Sprites", "Markers"]:
		var g := root.get_node_or_null(grp)
		if g == null:
			continue
		for c in g.get_children():
			if c is Node3D and c.get("rec") is MapEntityRec:
				out.append([c, c.get("rec")])
	return out

## Size of the block at `off` = distance to the next entity block in
## file order (the aux records between them belong to it).
static func _block_size(off: int, sorted_offs: Array, file_size: int) -> int:
	var i := sorted_offs.bsearch(off)
	if i + 1 < sorted_offs.size():
		return int(sorted_offs[i + 1]) - off
	return mini(file_size - off, 48)

## A fresh entity block: 48 bytes for a mesh (variant 1), 35 for a
## light (2), 36 for a sprite/marker (3) — the layouts seen in every
## MAP. Position, angles and the variant fields are filled by the
## main loop; a mesh must use a name already in the map's name table
## (the header region after the table is not free space).
static func _new_block(rec: Resource, root: Node) -> PackedByteArray:
	var v: int = int(rec.get("variant"))
	var size: int = 48 if v == 1 else (35 if v == 2 else 36)
	var blk := PackedByteArray()
	blk.resize(size)
	blk.fill(0)
	_put32(blk, 0, END_A)
	blk[20] = v
	if v == 1:
		var names: PackedStringArray = root.get("names")
		var idx: int = -1
		var want: String = String(rec.get("mesh_name")).to_upper()
		for i in names.size():
			if names[i].to_upper() == want:
				idx = i
				break
		if idx < 0:
			return PackedByteArray()
		_put16(blk, 25 + 12, idx)
	return blk

## Older readers walked only blocks with 48 bytes in bounds; pad an
## appended 35/36-byte block so any such tool still sees it.
static func _pad_block(b: PackedByteArray, off: int) -> void:
	while b.size() < off + 48:
		b.append(0)

## Produce the MAP bytes for the scene under `root`. Returns an empty
## array when the root carries no original data. `log` receives
## human-readable lines about what changed.
static func write(root: Node, log: Array = []) -> PackedByteArray:
	var raw: PackedByteArray = root.get("raw")
	if raw == null or raw.size() < PAYLOAD_OFFSET + 4:
		push_error("[mapwriter] scene root carries no MAP data")
		return PackedByteArray()
	var b: PackedByteArray = raw.duplicate()
	var gw := _u32(b, 4)
	var gh := _u32(b, 8)
	var chains := _chain_map(b, gw, gh)
	var sorted_offs: Array = chains.keys()
	sorted_offs.sort()
	var seen: Dictionary = {}                # file_off → true (first node wins)
	var changed := 0
	var moved := 0
	var added := 0

	for pair in _entity_nodes(root):
		var node: Node3D = pair[0]
		var rec: Resource = pair[1]
		var off: int = int(rec.get("file_off"))
		var kind := _kind(node, rec)
		# --- new entity (file_off < 0): a block from the variant template -
		if off < 0:
			var blk := _new_block(rec, root)
			if blk.is_empty():
				push_warning("[mapwriter] %s: cannot create (mesh name not in this map's table?)" % node.name)
				continue
			var new_off := b.size()
			b.append_array(blk)
			_pad_block(b, new_off)
			_put32(b, new_off + 21, new_off + 25)
			off = new_off
			added += 1
			log.append("%s: created → offset %d" % [node.name, new_off])
		# --- duplicate: append a copy of the source block --------------
		elif seen.has(off) or not chains.has(off):
			if not chains.has(off):
				push_warning("[mapwriter] %s: unknown file offset %d — skipped" % [node.name, off])
				continue
			var size := _block_size(off, sorted_offs, raw.size())
			var new_off := b.size()
			b.append_array(raw.slice(off, off + size))
			_pad_block(b, new_off)
			_put32(b, new_off + 21, new_off + 25)          # inline sub-record
			off = new_off
			added += 1
			log.append("%s: duplicated → offset %d" % [node.name, new_off])
		seen[off] = true
		var sub := off + 25
		var dos: Vector3i = rec.get("dos_pos")
		# --- position --------------------------------------------------
		var exp := _expected_pos(kind, dos, node)
		if not node.position.is_equal_approx(exp) and node.position.distance_to(exp) > 0.5:
			dos = _dos_from_pos(kind, node.position, dos)
		var old := Vector3i(_s32(b, off + 8), _s32(b, off + 12), _s32(b, off + 16))
		if dos != old:
			_put32(b, off + 8, dos.x)
			_put32(b, off + 12, dos.y)
			_put32(b, off + 16, dos.z)
			moved += 1
			log.append("%s: moved %s → %s" % [node.name, old, dos])
		# --- cell membership --------------------------------------------
		var want_cell := _cell_of(dos.x, dos.z, gw, gh)
		var cur_cell: int = int(chains.get(int(rec.get("file_off")), -1)) if off == int(rec.get("file_off")) else -1
		if cur_cell != want_cell:
			if cur_cell >= 0:
				_unlink(b, cur_cell, off)
			_link_head(b, want_cell, off)
			log.append("%s: cell %d → %d" % [node.name, cur_cell, want_cell])
		# --- angles: the three variant-1 words (only their low 11 bits) --
		var v: int = int(rec.get("variant"))
		if v == 1:
			var rawang: Vector3i = rec.get("raw_angles")
			var ang := Vector3i(int(rec.get("pitch")), int(rec.get("yaw")), int(rec.get("roll")))
			var exp_b := basis_from_angles(ang.x, ang.y, ang.z)
			if not node.transform.basis.is_equal_approx(exp_b):
				ang = angles_from_basis(node.transform.basis)
			var words := Vector3i(
				(rawang.x & ~0x7FF) | (ang.x & 0x7FF),
				(rawang.y & ~0x7FF) | (ang.y & 0x7FF),
				(rawang.z & ~0x7FF) | (ang.z & 0x7FF))
			if words != Vector3i(_s32(b, sub), _s32(b, sub + 4), _s32(b, sub + 8)):
				_put32(b, sub, words.x)
				_put32(b, sub + 4, words.y)
				_put32(b, sub + 8, words.z)
				changed += 1
				log.append("%s: angles → %s" % [node.name, ang])
		# --- variant-specific fields -------------------------------------
		var before := b.slice(sub, mini(sub + 24, b.size()))
		match v:
			1:
				# hp / state resolved from the per-name default list are not
				# the entity's own bytes (MapFile.uses_defaults) — leave them.
				if not bool(rec.get("uses_defaults")):
					_put16(b, sub + 0x0e, int(rec.get("hp")))
					b[sub + 0x12] = int(rec.get("state_byte")) & 0xFF
				var link_off := _s32(b, sub + 0x13)
				if link_off > 0 and link_off + 10 <= b.size():
					b[link_off + 9] = int(rec.get("link_act_type")) & 0xFF
					_put32(b, link_off + 5, int(rec.get("link_next")))
			2:
				_put16(b, sub + 0, int(rec.get("light_intensity")))
				b[sub + 2] = int(rec.get("state_byte")) & 0xFF
				b[sub + 3] = int(rec.get("link_act_type")) & 0xFF
				_put32(b, sub + 4, int(rec.get("link_next")))
				_put16(b, sub + 8, int(rec.get("light_enable")))
			3:
				var si: int = int(rec.get("sprite_index"))
				var mt: int = int(rec.get("marker_type"))
				if mt >= 0:
					si = (299 << 7) | (mt & 0x7F)
				_put16(b, sub + 0, si)
				_put16(b, sub + 2, int(rec.get("exit_map")))
				b[sub + 4] = int(rec.get("exit_marker_id")) & 0xFF
				b[sub + 5] = int(rec.get("state_byte")) & 0xFF
				_put32(b, sub + 6, int(rec.get("link_next")))
				b[sub + 10] = int(rec.get("link_act_type")) & 0xFF
				if mt == 2:
					b[sub + 10] = int(rec.get("enemy_type")) & 0xFF
		if b.slice(sub, mini(sub + 24, b.size())) != before:
			changed += 1
			log.append("%s: fields updated" % node.name)

	# --- deleted entities: unlink + skip flag ---------------------------
	var removed := 0
	for off in chains.keys():
		if seen.has(off):
			continue
		_unlink(b, int(chains[off]), off)
		b[off + 20] = b[off + 20] | SKIP_FLAG
		removed += 1
		log.append("entity @%d: removed" % off)
	log.append("summary: %d moved, %d field changes, %d added, %d removed"
		% [moved, changed, added, removed])
	return b

## Write the scene's MAP to `path` (default: the mod override path).
static func export_map(root: Node, path: String = "", log: Array = []) -> bool:
	var bytes := write(root, log)
	if bytes.is_empty():
		return false
	if path.is_empty():
		path = mod_path(String(root.get("map_name")))
		if path.is_empty():
			return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[mapwriter] cannot write %s" % path)
		return false
	f.store_buffer(bytes)
	f.close()
	# The scene now describes this file.
	root.set("raw", bytes)
	log.append("written %s (%d bytes)" % [path, bytes.size()])
	return true
