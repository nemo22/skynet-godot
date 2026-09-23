## DOS XnGine bitmap-font loader — GAMEDATA/FONT00NN.FNT.
##
## Format (little-endian; every FONT file is exactly 8644 bytes):
##   +0x00  u16 em_width, u16 line_height
##   +0x04  240 entries × {u16 data_offset, u16 glyph_width}
##          covering codepoints 0x21..0x110 (entry 0 = '!'; space has
##          no glyph and is synthesised from em_width)
##   data   each glyph = line_height rows × u16, 32-byte stride;
##          a pixel is set when bit (15 - column) of the row word is 1.
##
## build() returns a Godot FontFile with white glyphs on a transparent
## atlas — assign it as a Label/Control theme font and tint via
## "font_color". `scale` integer-upscales every glyph nearest-neighbour
## so the pixel font stays crisp at HUD sizes.

extends RefCounted

const GLYPH_COUNT := 240
const FIRST_CODEPOINT := 0x21       # entry 0 is '!'; space (0x20) has no glyph
const ATLAS_COLS := 16

## Build a FontFile from raw FONT00NN.FNT bytes, or null on failure.
static func build(bytes: PackedByteArray, scale: int = 1) -> FontFile:
	if bytes.size() < 4 + GLYPH_COUNT * 4:
		return null
	scale = maxi(scale, 1)
	var line_h := bytes.decode_u16(2)
	if line_h <= 0 or line_h > 16:
		return null

	# --- glyph entry table ---
	var offsets := PackedInt32Array()
	var widths := PackedInt32Array()
	var max_w := 1
	for i in GLYPH_COUNT:
		var e := 4 + i * 4
		offsets.append(bytes.decode_u16(e))
		var gw := bytes.decode_u16(e + 2)
		# A row is one u16, so no glyph is wider than 16 (FONT0011's are
		# exactly that). A wider one is corrupt — it sized the atlas by it
		# (up to 65 535 × 16 columns) and shifted the row word by a
		# negative count.
		if gw > 16:
			return null
		widths.append(gw)
		max_w = maxi(max_w, gw)

	# --- atlas: 16-column grid of (max_w × line_h) cells, ×scale ---
	var rows := int(ceil(float(GLYPH_COUNT) / ATLAS_COLS))
	var cell_w := max_w * scale + scale          # +scale-px gutter
	var cell_h := line_h * scale + scale
	var atlas := Image.create(ATLAS_COLS * cell_w, rows * cell_h,
		false, Image.FORMAT_RGBA8)
	atlas.fill(Color(1, 1, 1, 0))

	var sz := line_h * scale
	var size2 := Vector2i(sz, 0)
	var font := FontFile.new()
	font.fixed_size = sz
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	font.set_texture_image(0, size2, 0, atlas)

	for i in GLYPH_COUNT:
		var gw: int = widths[i]
		var src: int = offsets[i]
		var cx := (i % ATLAS_COLS) * cell_w
		@warning_ignore("integer_division")
		var cy := (i / ATLAS_COLS) * cell_h
		for ry in line_h:
			var word_off := src + ry * 2
			if word_off + 1 >= bytes.size():
				break
			var word := bytes.decode_u16(word_off)
			for rx in gw:
				if (word >> (15 - rx)) & 1:
					for sy in scale:
						for sx in scale:
							atlas.set_pixel(cx + rx * scale + sx,
								cy + ry * scale + sy, Color.WHITE)
		var cp := FIRST_CODEPOINT + i
		font.set_glyph_texture_idx(0, size2, cp, 0)
		font.set_glyph_uv_rect(0, size2, cp,
			Rect2(cx, cy, gw * scale, line_h * scale))
		font.set_glyph_size(0, size2, cp, Vector2(gw * scale, line_h * scale))
		font.set_glyph_offset(0, size2, cp, Vector2(0, -sz))
		font.set_glyph_advance(0, sz, cp, Vector2((gw + 1) * scale, 0))

	# The DOS fonts stop at 0x60: there are no lowercase glyphs, because
	# the game only ever printed capitals. Mixed-case text — the mission
	# lines out of the briefing, for one — therefore came out as stray
	# letters and dots (2026-09-04). Point every lowercase codepoint at
	# its capital so any string renders.
	for i in GLYPH_COUNT:
		var up: int = FIRST_CODEPOINT + i
		if up < 0x41 or up > 0x5A:
			continue
		var low: int = up + 0x20
		font.set_glyph_texture_idx(0, size2, low, 0)
		font.set_glyph_uv_rect(0, size2, low, font.get_glyph_uv_rect(0, size2, up))
		font.set_glyph_size(0, size2, low, font.get_glyph_size(0, size2, up))
		font.set_glyph_offset(0, size2, low, font.get_glyph_offset(0, size2, up))
		font.set_glyph_advance(0, sz, low, font.get_glyph_advance(0, sz, up))

	# Space (0x20) has no entry in the table — synthesise a blank glyph
	# advanced by the header em_width.
	var space_w := maxi(bytes.decode_u16(0), 2) * scale
	font.set_glyph_advance(0, sz, 0x20, Vector2(space_w, 0))

	# Re-upload the atlas now every glyph has been rasterised into it.
	font.set_texture_image(0, size2, 0, atlas)
	font.set_cache_ascent(0, sz, sz)
	font.set_cache_descent(0, sz, 0)
	return font
