## TEXTURE.NNN loader for SKYNET / FutureShock.
##
## Each file is a container of N sub-records (frames or variations)
## sharing one name. Records are 8-bit palette-indexed pixel arrays.
##
## File layout:
##   0..1     u16 tag                 (== record count; 0=invalid)
##   2..17    char name[16]           (space-padded ASCII)
##   18..27   padding
##   28..     tag × 20-byte outer records, each starts with a u32
##            offset to a 28-byte sub-texture descriptor:
##              +0  u32 hash/id
##              +4  u16 width
##              +6  u16 height
##              +8  u16 mode flag
##              +14 u32 pix_data_offset (relative to descriptor)
##              +18 u16 row_gap
##              +20 u16 depth
##              +22 u16 ms_per_frame
##
## `depth` > 1 IS the "this record is animated" flag — there is no other.
## The DOS texture fetch (FUN_00149e00, 0x149e6f) compares depth to 1,
## and where the caller asks for frame -1 — which every world draw path
## does, the map billboards at 0x136f28 and the mesh faces at 0x134651 —
## it takes `frame = (ms_clock / ms_per_frame) % depth` off one
## free-running millisecond counter. So every copy of an animated record
## runs in lockstep, at its own record's rate: the fires at +22 = 114
## are 8.77 fps, the burning drum of bank 206 at 142 is 7.04 fps.
##
## Pixel data has TWO on-disk layouts, selected by `row_gap`:
##
##   row_gap != 0 (wall / terrain textures, e.g. TEXTURE.044) —
##       stride = W + row_gap. Up to four records share one interleaved
##       buffer; row N of record R starts at `pix_off + N * stride`.
##       Verified against SKYNET.EXE.c sub_1345C2.
##
##   row_gap == 0 (sprite / billboard textures, e.g. TEXTURE.200/206) —
##       pix_off points to a `depth`-entry u32 frame offset table:
##           u32 frame_off[depth]
##       Frame k starts at `pix_off + frame_off[k]`; each frame begins
##       with u16 W, u16 H, then the pixel data in ONE of two forms:
##
##         * Uncompressed — byte size == H*(W+2): each row is a 2-byte
##           X-range prefix followed by W pixel bytes.
##
##         * Compressed (transparency-run) — the common sprite form:
##           each of the H rows is a sequence of (transparent_run,
##           opaque_run) byte pairs; after every pair `opaque_run`
##           literal pixel bytes follow. Transparent pixels stay palette
##           index 0. The row ends once W columns are covered. Verified
##           against TEXTURE.200-242 — every row consumes its bytes
##           exactly. (See `_decode_sparse_rows`.)
##
## Face encoding (matches Daggerfall Xngine):
##   archive_id = face.type >> 7   -> selects TEXTURE.NNN file
##   record_id  = face.type & 0x7F -> selects sub-record within

extends RefCounted

## Cap for sanity-check on tag count. TEXTURE.000 / TEXTURE.001 (Solid
## Colors) each store 128 records, so this must be at least 128.
const MAX_RECORDS: int = 256
## Decoded-pixel budgets. A crafted bank could point all 256 records, or a
## sprite's 65 535 frame slots, at one 1024×1024 image. The real files peak
## at ~254 000 pixels per bank (TEXTURE.302) and 27 frames / ~308 000
## pixels per animation (TEXTURE.220).
const MAX_FILE_PIXELS: int = 16 * 1024 * 1024
const MAX_SPRITE_FRAMES: int = 256
const MAX_FRAMES_PIXELS: int = 16 * 1024 * 1024

class Record:
	var width: int = 0
	var height: int = 0
	var pixels: PackedByteArray   # width*height palette indices

class TexFile:
	var name: String = ""
	var records: Array[Record] = []

static func _u16(bytes: PackedByteArray, off: int) -> int:
	return bytes[off] | (bytes[off + 1] << 8)

static func _u32(bytes: PackedByteArray, off: int) -> int:
	return bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16) | (bytes[off + 3] << 24)

## Parse a TEXTURE.NNN file. Returns TexFile or null.
static func parse(bytes: PackedByteArray) -> TexFile:
	if bytes == null or bytes.size() < 28 + 20 + 28:
		return null
	var tag: int = _u16(bytes, 0)
	if tag == 0 or tag > MAX_RECORDS:
		return null

	var t := TexFile.new()
	# Name: 16 bytes starting at offset 2, space-trimmed.
	var name_bytes := bytes.slice(2, 18)
	t.name = name_bytes.get_string_from_ascii().strip_edges()

	var pixels: int = 0
	for r in tag:
		var ro: int = 28 + r * 20
		if ro + 20 > bytes.size():
			break                              # outer record table truncated
		if pixels > MAX_FILE_PIXELS:
			t.records.append(Record.new())     # over budget: placeholders
			continue
		var rec := _parse_record(bytes, ro)
		if rec != null:
			pixels += rec.pixels.size()
		# A failed record still occupies its slot — append an empty
		# placeholder so later records keep their correct index. One bad
		# record must not truncate the rest of the bank.
		t.records.append(rec if rec != null else Record.new())
	return t

## Parse one outer record at table offset `ro`. Returns a Record, or
## null when the record is malformed.
static func _parse_record(bytes: PackedByteArray, ro: int) -> Record:
	var desc_off: int = _u32(bytes, ro)
	# Solid-Colors archives (TEXTURE.000 / TEXTURE.001) store no
	# descriptor — desc_off == 0 and the outer record's byte +19 holds a
	# palette index. Synthesize a 1×1 record so the mesh path renders the
	# face as that solid colour.
	if desc_off == 0:
		var rec_sc := Record.new()
		rec_sc.width = 1
		rec_sc.height = 1
		var px := PackedByteArray()
		px.resize(1)
		px[0] = bytes[ro + 19]
		rec_sc.pixels = px
		return rec_sc
	if desc_off + 28 > bytes.size():
		return null
	var w: int = _u16(bytes, desc_off + 4)
	var h: int = _u16(bytes, desc_off + 6)
	var pix_rel: int = _u32(bytes, desc_off + 14)
	var row_gap: int = _u16(bytes, desc_off + 18)
	var depth: int = _u16(bytes, desc_off + 20)
	if w == 0 or h == 0 or w > 1024 or h > 1024:
		return null
	var pix_off: int = desc_off + pix_rel
	var rec_pixels: PackedByteArray

	# Rows live at a 256-byte stride (see the TEXTURE.NNN stride note), so
	# a 256-wide wall texture has row_gap 0 — exactly like a sprite. It is
	# a wall when the raw W×H block fits and the sprite frame table does
	# not make sense (TEXTURE.266 rec 1, the MAP.252 wardrobe: 256×128).
	if row_gap == 0 and w == 256 and pix_off + w * h <= bytes.size():
		var f0: int = _u32(bytes, pix_off)
		if depth < 1 or f0 < depth * 4 or pix_off + f0 + 4 > bytes.size() \
				or _u16(bytes, pix_off + f0) != w:
			row_gap = -1                     # force layout A at stride W

	if row_gap != 0:
		# Layout A — wall/terrain, row-interleaved at stride W+row_gap.
		var stride: int = w + maxi(row_gap, 0)
		var span: int = (h - 1) * stride + w
		if pix_off + span > bytes.size():
			stride = w
			span = w * h
			if pix_off + span > bytes.size():
				return null
		rec_pixels = PackedByteArray()
		if stride == w:
			rec_pixels = bytes.slice(pix_off, pix_off + w * h)
		else:
			for y in h:
				var so: int = pix_off + y * stride
				rec_pixels.append_array(bytes.slice(so, so + w))
	else:
		# Layout B — sprite. Parse the frame offset table, take frame 0.
		if depth < 1 or pix_off + depth * 4 + 4 > bytes.size():
			return null
		var f0_off: int = _u32(bytes, pix_off)
		var f1_off: int
		if depth >= 2:
			f1_off = _u32(bytes, pix_off + 4)
		else:
			# Single frame — span the rest of the reachable area.
			f1_off = bytes.size() - pix_off
		if f0_off < depth * 4 or f1_off <= f0_off:
			return null
		if pix_off + f1_off > bytes.size():
			return null

		var frame_start: int = pix_off + f0_off
		if frame_start + 4 > bytes.size():
			return null                      # frame header past the end
		var fw: int = _u16(bytes, frame_start)
		var fh: int = _u16(bytes, frame_start + 2)
		if fw == 0 or fh == 0 or fw > 1024 or fh > 1024:
			return null
		w = fw
		h = fh
		var data_off: int = frame_start + 4
		var data_size: int = (pix_off + f1_off) - data_off
		if data_off + data_size > bytes.size() or data_size <= 0:
			return null

		if data_size == h * (w + 2):
			# Uncompressed: each row is a 2-byte X-range prefix + W pixels.
			rec_pixels = PackedByteArray()
			for y in h:
				var so: int = data_off + y * (w + 2) + 2
				rec_pixels.append_array(bytes.slice(so, so + w))
		else:
			# Compressed sprite — per-row transparency-run encoding.
			rec_pixels = _decode_sparse_rows(bytes, data_off, data_size, w, h)
			if rec_pixels.is_empty():
				return null

	var rec := Record.new()
	rec.width = w
	rec.height = h
	rec.pixels = rec_pixels
	return rec

## Decode EVERY frame of a sprite-layout record (row_gap == 0) — the
## explosion banks TEXTURE.358 / TEXTURE.367 store the whole cel-animation
## as multiple frames inside record 0. Returns an Array of Record (each
## with its own width / height / pixels), or [] on parse failure.
##
## DOS pool: skynet_gh.c FUN_00123e3a:26654 advances frame index per tick
## and despawns at frame_count via FUN_00123e19:26642.
static func parse_record_frames(bytes: PackedByteArray,
		record_id: int) -> Array:
	if bytes == null or bytes.size() < 28 + 20 + 28:
		return []
	var tag: int = _u16(bytes, 0)
	if record_id < 0 or record_id >= tag:
		return []
	var ro: int = 28 + record_id * 20
	if ro + 20 > bytes.size():
		return []
	var desc_off: int = _u32(bytes, ro)
	if desc_off == 0 or desc_off + 28 > bytes.size():
		return []
	var pix_rel: int = _u32(bytes, desc_off + 14)
	var row_gap: int = _u16(bytes, desc_off + 18)
	var depth: int = _u16(bytes, desc_off + 20)
	var pix_off: int = desc_off + pix_rel
	if row_gap != 0:
		# Wall layout, not a multi-frame sprite — return the single record.
		var single := _parse_record(bytes, ro)
		return [single] if single != null else []
	if depth < 1 or pix_off + depth * 4 > bytes.size():
		return []

	var frames: Array = []
	# Budgets (see MAX_SPRITE_FRAMES): frame slots looked at, and pixels of
	# every frame a decode was attempted for, successful or not.
	var attempted: int = 0
	for k in mini(depth, MAX_SPRITE_FRAMES):
		var f_off: int = _u32(bytes, pix_off + k * 4)
		var f_next: int
		if k + 1 < depth:
			f_next = _u32(bytes, pix_off + (k + 1) * 4)
		else:
			f_next = bytes.size() - pix_off
		if f_off < depth * 4 or f_next <= f_off:
			continue
		if pix_off + f_next > bytes.size():
			continue
		var frame_start: int = pix_off + f_off
		if frame_start + 4 > bytes.size():
			continue
		var fw: int = _u16(bytes, frame_start)
		var fh: int = _u16(bytes, frame_start + 2)
		if fw == 0 or fh == 0 or fw > 1024 or fh > 1024:
			continue
		var data_off: int = frame_start + 4
		var data_size: int = (pix_off + f_next) - data_off
		if data_off + data_size > bytes.size() or data_size <= 0:
			continue
		attempted += fw * fh
		if attempted > MAX_FRAMES_PIXELS:
			break
		var rec_pixels: PackedByteArray
		if data_size == fh * (fw + 2):
			rec_pixels = PackedByteArray()
			for y in fh:
				var so: int = data_off + y * (fw + 2) + 2
				rec_pixels.append_array(bytes.slice(so, so + fw))
		else:
			rec_pixels = _decode_sparse_rows(bytes, data_off, data_size, fw, fh)
			if rec_pixels.is_empty():
				continue
		var rec := Record.new()
		rec.width = fw
		rec.height = fh
		rec.pixels = rec_pixels
		frames.append(rec)
	return frames

## Decode a compressed sprite frame. Each of the H rows is a sequence of
## (transparent_run, opaque_run) byte pairs; after every pair `opaque_run`
## literal pixel bytes follow. Transparent pixels are left as palette
## index 0. A row ends once W columns are covered. Returns a W×H index
## buffer, or an empty array on a source under-run.
static func _decode_sparse_rows(src: PackedByteArray, off: int,
		size: int, w: int, h: int) -> PackedByteArray:
	# Built by appending whole runs (native slices) rather than writing a
	# pixel at a time: `filled` is how much of the current row is already
	# in `dst`, and a gap before the next run is transparent zeros.
	var dst := PackedByteArray()
	var zeros := PackedByteArray()
	zeros.resize(w)                        # zero-filled
	var s: int = off
	var end: int = off + size
	for y in h:
		var x: int = 0
		var filled: int = 0
		while x < w:
			if s + 2 > end:
				return PackedByteArray()
			var trans: int = src[s]
			var opaque: int = src[s + 1]
			s += 2
			x += trans
			if s + opaque > end:
				return PackedByteArray()
			if opaque > 0 and x < w:
				var n: int = mini(opaque, w - x)   # pixels past W are dropped
				if x > filled:
					dst.append_array(zeros.slice(0, x - filled))
				dst.append_array(src.slice(s, s + n))
				filled = x + n
			s += opaque
			x += opaque
		if filled < w:
			dst.append_array(zeros.slice(0, w - filled))
	return dst

## Convert a palette-indexed record to a Godot ImageTexture (RGBA8) using
## the supplied palette (PackedColorArray length 256). Index 0 is
## rendered transparent if `transparent_index_0` is true.
static func to_image_texture(rec: Record, palette: PackedColorArray,
		transparent_index_0: bool = false) -> ImageTexture:
	var img := to_image(rec, palette, transparent_index_0)
	return ImageTexture.create_from_image(img) if img != null else null

## The decoded RGBA8 Image of a record (what the asset cache stores —
## a texture created on a headless/dummy renderer cannot give its
## pixels back, so conversion must start from the Image).
static func to_image(rec: Record, palette: PackedColorArray,
		transparent_index_0: bool = false) -> Image:
	if rec == null or rec.pixels.is_empty() or palette.size() < 256:
		return null
	var n: int = rec.width * rec.height
	# Build a 256-entry RGBA8 lookup once.
	var lut := PackedByteArray()
	lut.resize(256 * 4)
	for i in 256:
		var c: Color = palette[i]
		lut[i * 4 + 0] = int(c.r * 255.0)
		lut[i * 4 + 1] = int(c.g * 255.0)
		lut[i * 4 + 2] = int(c.b * 255.0)
		lut[i * 4 + 3] = 0 if (transparent_index_0 and i == 0) else 255
	# One pixel = one 32-bit word: to_int32_array / to_byte_array copy the
	# bytes as they are, so the words hold R, G, B, A in memory order on any
	# byte order — one read and one write per pixel instead of four each.
	var lut32: PackedInt32Array = lut.to_int32_array()
	var px: PackedByteArray = rec.pixels
	var rgba := PackedInt32Array()
	rgba.resize(n)
	for i in n:
		rgba[i] = lut32[px[i]]
	return Image.create_from_data(rec.width, rec.height, false,
		Image.FORMAT_RGBA8, rgba.to_byte_array())
