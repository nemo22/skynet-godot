## .CFA cel-animation loader — DOS weapon viewmodels (WEAPON*.CFA) and
## RADCOUNT.CFA.
##
## Header (little-endian):
##   +0  u16  frame width
##   +2  u16  frame height
##   +11 u8   frame count
##   +12 u16[frame_count]  absolute byte offset of each frame's data
##
## Each frame is one RLE byte stream (compression mode 2) expanding to
## exactly width*height 8-bit palette indices, row-major:
##   c  < 0x80 → literal block of (c + 1) pixels (each its own byte)
##   c >= 0x80 → run of (c - 0x7F) pixels of the next byte
## Palette index 0 is transparent.
##
## Verified against WEAPON04.CFA (174x158, 12 frames) and WEAPON00.CFA
## (302x128, 7 frames). See loader FUN at fshock.exe.c:193540.

extends RefCounted

## SkyNET's 640x480 art (MDMDHRES.BSA) uses a SECOND layout, decoded
## 2026-09-12. The parser above read its height as zero and threw the
## file away, so HI-RES WEAPONS quietly drew no gun at all:
##   +0  u32 x            +4  u32 y
##   +8  u32 width        +12 u32 height
##   +16 24 bytes of zero
##   +40 u32 frame count
##   +44 u32[count] frame offsets
## The first frame offset is ALWAYS 44 + 4*count, and that is what tells
## the two layouts apart — the same archive's RADCOUNT.CFA and TNET*.CFA
## are still the 16-bit kind, so a version byte would not do.
##
## A frame body is row-based rather than one byte stream: per row, pairs
## of (skip u8, count u8) followed by `count` palette bytes, until the
## row covers `width`; a blank row is simply (width, 0). Verified across
## all 14 WEAPON*.CFA — 73 of 73 frames decode to exactly width*height.
const HIRES_HEADER: int = 44

## Decoded-size guards: a 522-byte file could declare 255 frames of
## 2048x2048 (4.3 GB of RGBA). Neither layout's encoding expands a byte to
## more than ~128 pixels, and every real CFA of both games stays under 24
## pixels per file byte and 2 million pixels in all (JOYBTN, WEAPON00).
const MAX_PIXELS_PER_BYTE: int = 128
const MAX_TOTAL_PIXELS: int = 16 * 1024 * 1024

## True when w×h×frames cannot be a genuine file of `size` bytes, or is
## more than a viewmodel strip could ever need.
static func _too_big(w: int, h: int, frames: int, size: int) -> bool:
	var total: int = w * h * frames
	return total > MAX_TOTAL_PIXELS or total > size * MAX_PIXELS_PER_BYTE

## The 256-entry RGBA8 look-up as one 32-bit word per palette index
## (to_int32_array keeps the bytes in memory order, so a word written back
## with to_byte_array lays out R, G, B, A); index 0 is transparent.
static func _lut32(palette: PackedColorArray) -> PackedInt32Array:
	var lut := PackedByteArray()
	lut.resize(256 * 4)
	for i in 256:
		var c: Color = palette[i]
		lut[i * 4 + 0] = int(c.r * 255.0)
		lut[i * 4 + 1] = int(c.g * 255.0)
		lut[i * 4 + 2] = int(c.b * 255.0)
		lut[i * 4 + 3] = 0 if i == 0 else 255
	return lut.to_int32_array()

## Frame count if `bytes` is the 640x480 layout, else 0.
static func hires_frame_count(bytes: PackedByteArray) -> int:
	if bytes == null or bytes.size() < HIRES_HEADER + 8:
		return 0
	var w: int = bytes.decode_u32(8)
	var h: int = bytes.decode_u32(12)
	var n: int = bytes.decode_u32(40)
	if w <= 0 or h <= 0 or w > 4096 or h > 4096 or n <= 0 or n > 64:
		return 0
	if HIRES_HEADER + n * 4 > bytes.size():
		return 0
	if bytes.decode_u32(HIRES_HEADER) != HIRES_HEADER + n * 4:
		return 0
	return n

static func is_hires(bytes: PackedByteArray) -> bool:
	return hires_frame_count(bytes) > 0

## The 640x480 layout's own x/y, which the 320x200 one does not carry.
## WEAPON00 reads 37/142 against a 603x338 frame — 37+603 = 640 and
## 142+338 = 480, so for that one it is plainly where the art sits on a
## 640x480 screen. Others (WEAPON04 at 63/4) do not land on an edge, so
## the field is trusted only when it is non-zero and the caller has a
## fallback. Returns (0, 0) for the 16-bit layout.
static func hires_offset(bytes: PackedByteArray) -> Vector2i:
	if hires_frame_count(bytes) <= 0:
		return Vector2i.ZERO
	return Vector2i(bytes.decode_u32(0), bytes.decode_u32(4))


## Decode a .CFA buffer into an Array of ImageTexture, one per frame
## (or of Image when `as_images` — the asset cache stores those).
## Returns [] on a malformed file.
static func parse(bytes: PackedByteArray, palette: PackedColorArray,
		as_images: bool = false) -> Array:
	if bytes == null or palette.size() < 256:
		return []
	if is_hires(bytes):
		return _parse_hires(bytes, palette, as_images)
	if bytes.size() < 14:
		return []
	var w: int = bytes.decode_u16(0)
	var h: int = bytes.decode_u16(2)
	var frame_count: int = bytes[11]
	if w <= 0 or h <= 0 or w > 2048 or h > 2048 or frame_count <= 0:
		return []
	if 12 + frame_count * 2 > bytes.size():
		return []
	if _too_big(w, h, frame_count, bytes.size()):
		return []

	var lut := _lut32(palette)
	var npx: int = w * h
	var size: int = bytes.size()
	var frames: Array = []
	for f in frame_count:
		var src: int = bytes.decode_u16(12 + f * 2)
		var rgba := PackedInt32Array()
		rgba.resize(npx)                 # zero-filled: undecoded pixels stay clear
		var dst: int = 0
		while dst < npx and src < size:
			var c: int = bytes[src]
			src += 1
			if c < 0x80:
				# Literal block of c+1 pixels.
				var n: int = c + 1
				for k in n:
					if dst >= npx or src >= size:
						break
					rgba[dst] = lut[bytes[src]]
					src += 1
					dst += 1
			else:
				# Run of (c - 0x7F) pixels of the next byte.
				if src >= size:
					break
				var word: int = lut[bytes[src]]
				src += 1
				var n: int = mini(c - 0x7F, npx - dst)
				for k in n:
					rgba[dst] = word
					dst += 1
		var img := Image.create_from_data(w, h, false,
			Image.FORMAT_RGBA8, rgba.to_byte_array())
		if as_images:
			frames.append(img)
		else:
			frames.append(ImageTexture.create_from_image(img))
	return frames

## Decode the 640x480 layout (see the note above HIRES_HEADER).
static func _parse_hires(bytes: PackedByteArray, palette: PackedColorArray,
		as_images: bool) -> Array:
	var w: int = bytes.decode_u32(8)
	var h: int = bytes.decode_u32(12)
	var count: int = bytes.decode_u32(40)
	var size: int = bytes.size()
	if _too_big(w, h, count, size):
		return []
	# 256-entry RGBA8 LUT; index 0 is the transparent one, as everywhere.
	var lut := _lut32(palette)
	var frames: Array = []
	for f in count:
		var src: int = bytes.decode_u32(HIRES_HEADER + f * 4)
		var stop: int = size
		if f + 1 < count:
			stop = mini(bytes.decode_u32(HIRES_HEADER + (f + 1) * 4), size)
		var rgba := PackedInt32Array()
		rgba.resize(w * h)              # zero-filled: skipped pixels stay clear
		for row in h:
			var x: int = 0
			var base: int = row * w
			while x < w and src + 1 < stop:
				var skip: int = bytes[src]
				var n: int = bytes[src + 1]
				src += 2
				x += skip
				for k in n:
					if x >= w or src >= stop:
						break
					rgba[base + x] = lut[bytes[src]]
					src += 1
					x += 1
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba.to_byte_array())
		if as_images:
			frames.append(img)
		else:
			frames.append(ImageTexture.create_from_image(img))
	return frames
