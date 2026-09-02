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
	var rgba := PackedByteArray()
	rgba.resize(w * h * 4)
	for i in w * h:
		var c: Color = palette[bytes[12 + i]]
		var o: int = i * 4
		rgba[o + 0] = int(c.r * 255.0)
		rgba[o + 1] = int(c.g * 255.0)
		rgba[o + 2] = int(c.b * 255.0)
		rgba[o + 3] = 0 if (transparent0 and bytes[12 + i] == 0) else 255
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba)
	return ImageTexture.create_from_image(img)
