## Palette loader for SKYNET.COL / BRIEF.COL etc.
##
## 256-entry 8-bit indexed palette. On-disk: 768 bytes raw RGB, or 776
## bytes (8-byte header + 768 RGB). VGA DAC values are 6-bit (0..63) in
## old files and 8-bit (0..255) in newer ones — detected by max value.
## Ported from fsh32_port/src/loaders/image_img.c:fsh_palette_parse.

extends RefCounted

const SIZE: int = 256

## Parse to a 256-element PackedColorArray of opaque RGB colors.
static func parse(bytes: PackedByteArray) -> PackedColorArray:
	if bytes == null or bytes.size() < 768:
		return PackedColorArray()
	var rgb_off: int = 0
	if bytes.size() == 768:
		rgb_off = 0
	elif bytes.size() == 776:
		rgb_off = 8
	else:
		rgb_off = bytes.size() - 768

	# Determine if values are 6-bit (max <= 63) or already 8-bit.
	var max_v: int = 0
	for i in 768:
		var v: int = bytes[rgb_off + i]
		if v > max_v: max_v = v
	var six_bit: bool = max_v <= 63

	var out := PackedColorArray()
	out.resize(SIZE)
	for i in SIZE:
		var r: int = bytes[rgb_off + i * 3 + 0]
		var g: int = bytes[rgb_off + i * 3 + 1]
		var b: int = bytes[rgb_off + i * 3 + 2]
		if six_bit:
			# Expand 6-bit DAC to 8-bit by duplicating top 2 bits into bottom.
			r = (r << 2) | (r >> 4)
			g = (g << 2) | (g >> 4)
			b = (b << 2) | (b >> 4)
		out[i] = Color8(r, g, b, 255)
	return out

## Load a palette file from disk.
static func load_file(path: String) -> PackedColorArray:
	var bytes := SkynetPaths.read_bytes(path)
	return parse(bytes)
