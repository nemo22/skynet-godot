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

## Decode a .CFA buffer into an Array of ImageTexture, one per frame.
## Returns [] on a malformed file.
static func parse(bytes: PackedByteArray, palette: PackedColorArray) -> Array:
	if bytes == null or bytes.size() < 14 or palette.size() < 256:
		return []
	var w: int = bytes.decode_u16(0)
	var h: int = bytes.decode_u16(2)
	var frame_count: int = bytes[11]
	if w <= 0 or h <= 0 or w > 2048 or h > 2048 or frame_count <= 0:
		return []
	if 12 + frame_count * 2 > bytes.size():
		return []

	# 256-entry RGBA8 LUT; index 0 → transparent.
	var lut := PackedByteArray()
	lut.resize(256 * 4)
	for i in 256:
		var c: Color = palette[i]
		lut[i * 4 + 0] = int(c.r * 255.0)
		lut[i * 4 + 1] = int(c.g * 255.0)
		lut[i * 4 + 2] = int(c.b * 255.0)
		lut[i * 4 + 3] = 0 if i == 0 else 255

	var npx: int = w * h
	var size: int = bytes.size()
	var frames: Array = []
	for f in frame_count:
		var src: int = bytes.decode_u16(12 + f * 2)
		var rgba := PackedByteArray()
		rgba.resize(npx * 4)
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
					var lo: int = bytes[src] * 4
					src += 1
					var po: int = dst * 4
					rgba[po + 0] = lut[lo + 0]
					rgba[po + 1] = lut[lo + 1]
					rgba[po + 2] = lut[lo + 2]
					rgba[po + 3] = lut[lo + 3]
					dst += 1
			else:
				# Run of (c - 0x7F) pixels of the next byte.
				if src >= size:
					break
				var lo: int = bytes[src] * 4
				src += 1
				var n: int = c - 0x7F
				for k in n:
					if dst >= npx:
						break
					var po: int = dst * 4
					rgba[po + 0] = lut[lo + 0]
					rgba[po + 1] = lut[lo + 1]
					rgba[po + 2] = lut[lo + 2]
					rgba[po + 3] = lut[lo + 3]
					dst += 1
		var img := Image.create_from_data(w, h, false,
			Image.FORMAT_RGBA8, rgba)
		frames.append(ImageTexture.create_from_image(img))
	return frames
