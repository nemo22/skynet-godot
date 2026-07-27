## Raw vertex bytes from ENDOSKEL (v2.1, 4-byte stride).

extends Node

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

func _ready() -> void:
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path("MDMDENMS.BSA"), SkynetPaths.variant)
	var d := bsa.read("ENDOSKEL.3D")
	var voff: int = 200992
	# Dump 122 verts × 4 bytes = 488 bytes (one frame).
	print("ENDOSKEL frame 0 vertices (4 B each, 122 verts):")
	# Print as: idx (s8 s8 s8 s8 | x_u8 y_u8 z_u8 flag)
	for i in 30:
		var off: int = voff + i * 4
		var b0: int = d[off];     var s0: int = b0 - 256 if b0 >= 128 else b0
		var b1: int = d[off + 1]; var s1: int = b1 - 256 if b1 >= 128 else b1
		var b2: int = d[off + 2]; var s2: int = b2 - 256 if b2 >= 128 else b2
		var b3: int = d[off + 3]; var s3: int = b3 - 256 if b3 >= 128 else b3
		print("  v%-3d: bytes %02x %02x %02x %02x  s8=(%d, %d, %d, %d)" % [i, b0, b1, b2, b3, s0, s1, s2, s3])
	# Now also as 4-byte packed s11/s11/s10:
	print("\nAlso interpreted as packed s11|s11|s10|0:")
	for i in 10:
		var off: int = voff + i * 4
		var u: int = d[off] | (d[off+1] << 8) | (d[off+2] << 16) | (d[off+3] << 24)
		var x: int = u & 0x7FF; if x >= 0x400: x -= 0x800
		var y: int = (u >> 11) & 0x7FF; if y >= 0x400: y -= 0x800
		var z: int = (u >> 22) & 0x3FF; if z >= 0x200: z -= 0x400
		print("  v%-3d: u32=%08x  (x=%d, y=%d, z=%d)" % [i, u, x, y, z])
	bsa.close()
	get_tree().quit()
