## XnGine .IMG image loader (FutureShock / SkyNET front-end art).
##
## On-disk header (12 bytes, little-endian u16 each):
##   +0  x offset      +2  y offset
##   +4  width         +6  height
##   +8  compression   +10 record size
## then width*height palette-indexed bytes (compression 0 = raw).
##
## Only uncompressed images (compression == 0) are supported — that
## covers every menu/title screen (START.IMG, MAIN1.IMG, OPTIONS.IMG …).

extends RefCounted

## Decode an .IMG byte buffer to an ImageTexture using a 256-colour
## palette (see palette.gd). Returns null on a bad/compressed image.
## `transparent0`: palette index 0 becomes see-through (the cockpit
## panels PANEL1/PANEL2 leave the windscreen as index 0).
static func parse(bytes: PackedByteArray, palette: PackedColorArray, transparent0: bool = false) -> ImageTexture:
	if bytes == null or bytes.size() < 12 or palette.size() < 256:
		return null
	var w: int = bytes.decode_u16(4)
	var h: int = bytes.decode_u16(6)
	var comp: int = bytes.decode_u16(8)
	if w <= 0 or h <= 0 or comp != 0:
		return null
	if bytes.size() < 12 + w * h:
		return null
	# 256-entry RGBA8 lookup, then one 32-bit word per pixel (to_int32_array /
	# to_byte_array keep the bytes in memory order, so each word lays out
	# R, G, B, A) instead of a Color look-up and float maths per pixel.
	var lut := PackedByteArray()
	lut.resize(256 * 4)
	for i in 256:
		var c: Color = palette[i]
		lut[i * 4 + 0] = int(c.r * 255.0)
		lut[i * 4 + 1] = int(c.g * 255.0)
		lut[i * 4 + 2] = int(c.b * 255.0)
		lut[i * 4 + 3] = 0 if (transparent0 and i == 0) else 255
	var lut32: PackedInt32Array = lut.to_int32_array()
	var px: PackedByteArray = bytes.slice(12, 12 + w * h)
	var rgba := PackedInt32Array()
	rgba.resize(w * h)
	for i in w * h:
		rgba[i] = lut32[px[i]]
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba.to_byte_array())
	return ImageTexture.create_from_image(img)
