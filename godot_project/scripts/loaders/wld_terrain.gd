## WLD terrain loader → ArrayMesh.
##
## See docs/pipeline_analysis.md for the full DOS pipeline.
##
## File layout (chunk-based, verified against FutureShock32.exe.c
## sub_4AC130 and hex dump of WLD.210):
##   +0x00          File header
##     +0x04  u32   chunks_x (typically 2)
##     +0x08  u32   chunks_y (typically 2)
##     +0x90  u32[] chunk offset table [chunks_y * chunks_x entries]
##   +chunk_off     Per-chunk data (22-byte header + 4 layers):
##     +0..21       chunk header
##     +22          layer 0 (heights), chunk_w × chunk_h bytes
##     +22+N        layer 1 (decorations), N bytes
##     +22+2N       layer 2 (materials), N bytes
##     +22+3N       layer 3 (unknown), N bytes
##   where N = 128×128 = 16384 per-chunk layer.
##   Total grid: chunks_x*128 × chunks_y*128 = 256×256 cells.
##
## Cell stride and coordinate frame (verified vs SKYNET.EXE.c
## sub_14575D, line 76786):
##   - heightmap is 256×256 grid, each cell 256 game units
##   - column index in layer 0 = (world_x >> 8) & 0xFF
##   - row    index in layer 0 = ((K - world_z) >> 8) & 0xFF
##     where K = grid_height * 256 = 65536. Row 0 = north (max Z),
##     row 255 = south (min Z).
##
## Layer semantics (sub_14575D + curve at SKYNET.EXE.c:19291):
##   layer 0 bits 0..6 = HEIGHT_CURVE[128] index
##   layer 0 bit 7     = "cell is non-planar" marker (set at load by
##                       FUN_001534db when the 4 corner heights differ).
##                       NOT a split-direction selector — the DOS
##                       terrain always splits a cell on the NW-SE
##                       diagonal (FUN_0014525d:49391).
##   layer 1 byte >> 2 = decoration spawn id (0..0x21)
##   layer 2 byte & 0x3F = material id, remapped through per-map
##                         byte_104952 + hardcoded byte_104942 blend
##   layer 3           = UNCERTAIN

extends RefCounted

const Mesh3DLoader := preload("res://scripts/loaders/mesh_3d.gd")
const CHUNK_TABLE_OFFSET: int = 0x90
const CHUNK_HEADER_SIZE: int = 22
const CHUNK_CELLS: int = 128
const GRID_W: int = 256
const GRID_H: int = 256
const LAYER_BYTES: int = GRID_W * GRID_H
const WORLD_PER_CELL: float = 256.0
## Tile orientation sense of the layer-2 bits 6/7 (see build_terrain_mesh).
const TILE_ROT_CCW: bool = false

## World Z at row 0. row N → world Z = K - N*256. With K = 65536 and
## GRID_H = 256, the heightmap fills exactly Z = 256..65536 — the same
## range as the MAP entity grid.
const Z_FLIP_K: float = float(GRID_H) * WORLD_PER_CELL    ## 65536

## 128-entry non-linear height curve from dword_104FA8
## (SKYNET.EXE.c:19291). Indexed by (layer0_byte & 0x7F).
const HEIGHT_CURVE: Array = [
	   0,   40,   40,   40,   80,   80,   80,  120,  120,  120,
	 160,  160,  160,  200,  200,  200,  240,  240,  240,  280,
	 280,  320,  320,  320,  360,  360,  400,  400,  400,  440,
	 440,  480,  480,  480,  520,  520,  560,  560,  600,  600,
	 600,  640,  640,  680,  680,  720,  720,  760,  760,  800,
	 800,  840,  840,  880,  880,  920,  920,  960, 1000, 1000,
	1040, 1040, 1080, 1120, 1120, 1160, 1160, 1200, 1240, 1240,
	1280, 1320, 1320, 1360, 1400, 1440, 1440, 1480, 1520, 1560,
	1600, 1600, 1640, 1680, 1720, 1760, 1800, 1840, 1880, 1920,
	1960, 2000, 2040, 2080, 2120, 2200, 2240, 2280, 2320, 2400,
	2440, 2520, 2560, 2640, 2680, 2760, 2840, 2920, 3000, 3080,
	3160, 3240, 3360, 3440, 3560, 3680, 3800, 3960, 4080, 4280,
	4440, 4680, 4920, 5200, 5560, 6040, 6680, 7760,
]

## byte_104942 (DAT_00104742) — 16-byte 4x4 material transition matrix.
## Extracted from Skynet.exe at file offset 0x157FE6 (VA 0x104742).
## Indexed as MATERIAL_BLEND[neighbour_id * 4 + center_id]:
## when all 4 orthogonal neighbours of a cell hold the same material
## id `w` and the centre holds `c`, the centre is rewritten to
## MATERIAL_BLEND[w*4 + c]. Diagonal entries (w == c) yield the input
## material itself (no change); off-diagonal entries yield transition
## tiles 4..0x21. Algorithm: skynet_gh.c FUN_00153144 (lines 57287-57355).
const MATERIAL_BLEND: Array = [
	0x00, 0x04, 0x13, 0x1D, 0x08, 0x01, 0x09, 0x1C,
	0x17, 0x0D, 0x02, 0x0E, 0x21, 0x1C, 0x12, 0x03,
]

## byte_104952 (DAT_00104752) — 64-byte material remap LUT.
## Extracted from Skynet.exe at file offset 0x157FF6 (VA 0x104752).
## v = MATERIAL_REMAP[layer2 & 0x3F]:
##   v == 0xFF (-1)  → skip cell, leave unchanged
##   v in 0..3       → cell is a base material, eligible for blending
##   v in 4..0x21    → cell is an intermediate transition tile from a
##                     prior pass, also eligible for blending (idempotent)
## Pass-through values along the diagonal of MATERIAL_BLEND (0,1,2,3)
## map back to themselves; off-diagonal transition tile ids map back
## to their base group, which makes the smoothing pass idempotent.
const MATERIAL_REMAP: Array = [
	0x00, 0x01, 0x02, 0x03, 0x00, 0xFF, 0xFF, 0xFF,
	0x01, 0x01, 0xFF, 0xFF, 0xFF, 0x02, 0x02, 0xFF,
	0xFF, 0xFF, 0x03, 0x00, 0xFF, 0xFF, 0xFF, 0x02,
	0x01, 0xFF, 0xFF, 0xFF, 0x03, 0x00, 0xFF, 0xFF,
	0xFF, 0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
]

## DAT_00116200 — 256-byte LUT for the 2x2 corner coalesce pass.
## Index is packed as (TL<<4) | (BL<<2) | (TR<<0) | (BR<<6), where each
## corner contributes 2 bits (its MATERIAL_REMAP value). Output 0xFE
## means "no-op", 0xFF means "propagate-right and retry", other values
## are the new layer-2 material id for the top-left corner of the block.
## Algorithm: skynet_gh.c FUN_0015340a (lines 57432-57486).
const COALESCE_TILE: Array = [
	0xFF, 0xC5, 0xD4, 0xDE, 0x45, 0x70, 0xFE, 0xFE, 0x54, 0xFE, 0x16, 0xFE, 0x5E, 0xFE, 0xFE, 0x72,
	0x05, 0xC6, 0x22, 0x24, 0x06, 0x07, 0x0B, 0x26, 0x62, 0x0B, 0xFE, 0xFE, 0x24, 0x1A, 0xFE, 0xFE,
	0x14, 0x28, 0xD5, 0x29, 0x22, 0xFE, 0x28, 0xFE, 0x55, 0x0B, 0x16, 0x10, 0x29, 0xFE, 0x10, 0xFE,
	0x1E, 0xE4, 0xE3, 0xDF, 0x24, 0xFE, 0xFE, 0x1B, 0x23, 0xFE, 0xFE, 0xEC, 0x1F, 0x1A, 0x10, 0x20,
	0x85, 0x86, 0xD5, 0xA4, 0x46, 0x87, 0x22, 0x66, 0x15, 0x22, 0xFE, 0xFE, 0x64, 0xA6, 0xFE, 0xFE,
	0x30, 0xC7, 0xFE, 0xFE, 0x47, 0xFF, 0xCA, 0xD9, 0xFE, 0x4A, 0x73, 0xFE, 0xFE, 0x59, 0xFE, 0x74,
	0xFE, 0x25, 0x15, 0xFE, 0x22, 0x0A, 0xCB, 0x67, 0x15, 0x0B, 0x0C, 0x2A, 0xFE, 0xA7, 0x6A, 0xFE,
	0xFE, 0x26, 0xFE, 0xEB, 0x24, 0x19, 0x67, 0xDA, 0xFE, 0x27, 0xFE, 0x6D, 0x2B, 0x1A, 0x2D, 0x1B,
	0x94, 0xE2, 0xD5, 0xE3, 0x22, 0xFE, 0x55, 0xFE, 0x95, 0x28, 0x96, 0x23, 0x1F, 0xFE, 0x23, 0xFE,
	0xFE, 0xE5, 0x25, 0xFE, 0x46, 0x8A, 0x8B, 0x27, 0x22, 0x4B, 0x8C, 0x6A, 0xFE, 0x67, 0xAA, 0xFE,
	0x31, 0xFE, 0xD6, 0xFE, 0xFE, 0x33, 0xCC, 0xFE, 0x56, 0x4C, 0xFF, 0xCF, 0xFE, 0xFE, 0x4F, 0x75,
	0xFE, 0xFE, 0x29, 0xEC, 0xFE, 0xFE, 0x2A, 0xED, 0x69, 0x6A, 0x0F, 0xD0, 0x2C, 0x2D, 0x10, 0x11,
	0x9E, 0x24, 0x23, 0x9F, 0x64, 0xFE, 0xFE, 0xAB, 0x63, 0xFE, 0xFE, 0xAC, 0x5F, 0x6B, 0x6C, 0xA0,
	0xFE, 0xE6, 0xFE, 0x2B, 0x26, 0x99, 0x27, 0x9A, 0xFE, 0xE7, 0xFE, 0xAD, 0x6B, 0x5A, 0x6D, 0x9B,
	0xFE, 0xFE, 0xE9, 0x2C, 0xFE, 0xFE, 0xEA, 0x2D, 0x29, 0x2A, 0x8F, 0x90, 0x6C, 0x6D, 0x50, 0x91,
	0x32, 0xFE, 0xFE, 0xE0, 0xFE, 0x34, 0xFE, 0xDB, 0xFE, 0xFE, 0x35, 0xD1, 0x60, 0x5B, 0x51, 0xFF,
]

class WLD:
	## layers[L] is a PackedByteArray of 65536 bytes, row-major
	## (index = row * 256 + col).
	var layers: Array[PackedByteArray] = []
	## ENHANCED: the part of the map that is played on (DOS world X/Z,
	## the entity box grown by FINE_MARGIN). Inside it the ground is the
	## smooth surface of `height_smooth`, subdivided FINE_DIV times per
	## cell; a FINE_TAPER-wide ring blends back to the DOS planes, and
	## the rest of the 65536 u square stays at one plane per triangle.
	## Empty = classic terrain everywhere (DOS look, or no map box).
	var fine_rect: Rect2 = Rect2()
	## Corner heights as one flat PackedFloat32Array, (GRID_W+1) per row,
	## filled lazily by `_corners`.
	var _corner_cache: PackedFloat32Array = PackedFloat32Array()

## The smooth ground (ENHANCED, docs §P.12). The DOS heightmap has 256 u
## cells and a 40 u height step, so a hill is a stack of terraces: one
## sloped cell, a flat one, another slope. Measured over the outdoor
## maps: 88–97 % of the cells are flat, the rest step 40–320 u in one
## cell, and the box the entities stand in is 1–7 % of the map (26–37 %
## on the vehicle maps). So only the box gets the fine surface, and only
## its sloped cells get subdivided — a flat cell stays two triangles.
const FINE_DIV: int = 4                  # sub-cells per cell (64 u)
const FINE_MARGIN: float = 2048.0        # around the entity box
const FINE_TAPER: float = 1024.0         # smooth → planar blend ring
const FINE_EPS: float = 4.0              # normal finite-difference step

## Read a little-endian u32 from a byte array.
static func _u32(bytes: PackedByteArray, off: int) -> int:
	return bytes[off] | (bytes[off+1] << 8) | (bytes[off+2] << 16) | (bytes[off+3] << 24)

## Parse WLD bytes into 4 reassembled layer buffers.
## Reads the chunk offset table from the header and assembles
## 2×2 chunks (each 128×128 cells) into flat 256×256 layers.
## Matches FutureShock32.exe sub_4AC130 (level.c:wld_load).
static func parse(bytes: PackedByteArray) -> WLD:
	if bytes == null or bytes.size() < CHUNK_TABLE_OFFSET + 16:
		return null

	var chunks_x: int = _u32(bytes, 4)
	var chunks_y: int = _u32(bytes, 8)
	if chunks_x <= 0 or chunks_y <= 0 or chunks_x > 4 or chunks_y > 4:
		return null
	var grid_w: int = chunks_x * CHUNK_CELLS
	var grid_h: int = chunks_y * CHUNK_CELLS
	if grid_w != GRID_W or grid_h != GRID_H:
		push_warning("[wld] unexpected grid %dx%d (expected 256x256)" % [grid_w, grid_h])

	var w := WLD.new()
	w.layers.resize(4)
	for L in 4:
		w.layers[L] = PackedByteArray()
		w.layers[L].resize(LAYER_BYTES)
		w.layers[L].fill(0)

	var chunk_layer_size: int = CHUNK_CELLS * CHUNK_CELLS  # 16384

	for cy in chunks_y:
		for cx in chunks_x:
			var table_idx: int = cy * chunks_x + cx
			var table_off: int = CHUNK_TABLE_OFFSET + table_idx * 4
			if table_off + 4 > bytes.size():
				push_error("[wld] chunk table out of bounds")
				return null
			var chunk_off: int = _u32(bytes, table_off)
			var data_off: int = chunk_off + CHUNK_HEADER_SIZE

			for L in 4:
				var layer_start: int = data_off + L * chunk_layer_size
				if layer_start + chunk_layer_size > bytes.size():
					push_error("[wld] chunk data out of bounds (chunk %d,%d layer %d)" % [cx, cy, L])
					break
				var row_base: int = cy * CHUNK_CELLS
				var col_base: int = cx * CHUNK_CELLS
				var layer_ref: PackedByteArray = w.layers[L]
				for row in CHUNK_CELLS:
					var src_off: int = layer_start + row * CHUNK_CELLS
					var dst_off: int = (row_base + row) * GRID_W + col_base
					# Copy 128 bytes (one chunk row) into the flat output
					for col in CHUNK_CELLS:
						layer_ref[dst_off + col] = bytes[src_off + col]
				w.layers[L] = layer_ref

	# DOS post-load passes on the layer-2 material buffer so the
	# in-memory buffer matches what the rasterizer reads.
	_smooth_materials(w)
	return w

## DOS terrain post-load passes on the layer-2 material buffer.
## Replicates skynet_gh.c FUN_00153144 (single-neighbour smoothing) +
## FUN_0015340a (2x2 corner coalesce). The result is a layer-2 buffer
## where uniform regions snap to a base material and boundaries carry
## transition tile ids (4..0x21).
##
## NB: the DOS algorithm assumes layer-2 has been pre-quantised by
## FUN_0015308f (height → tier 0..3). The thresholds for that pass
## live in BSS and are populated at runtime, so we don't have them —
## instead we run the smoothing directly on the WLD's layer-2 bytes.
## Cells with MATERIAL_REMAP[id] == 0xFF are left untouched (sentinel),
## which corresponds to the DOS "skip" branch.
static func _smooth_materials(w: WLD) -> void:
	if w == null:
		return
	var L2: PackedByteArray = w.layers[2]

	# Pass 1: single-neighbour smoothing (FUN_00153144).
	# If the centre's remap is in 0..0x21 (not 0xFF) and all 4 orthogonal
	# neighbours hold the same raw byte `nb`, rewrite centre to
	# MATERIAL_BLEND[(nb & 0x3)*4 + (centre & 0x3)].
	for row in range(1, GRID_H - 1):
		var rb1: int = row * GRID_W
		for col in range(1, GRID_W - 1):
			var idx: int = rb1 + col
			var centre: int = L2[idx]
			var rv: int = MATERIAL_REMAP[centre & 0x3F]
			if rv == 0xFF:
				continue
			var nW: int = L2[idx - 1]
			var nE: int = L2[idx + 1]
			var nN: int = L2[idx - GRID_W]
			var nS: int = L2[idx + GRID_W]
			if nW == nE and nW == nN and nW == nS:
				var bi: int = ((nW & 0x3) << 2) | (centre & 0x3)
				L2[idx] = MATERIAL_BLEND[bi]

	# Pass 2: 2x2 corner coalesce (FUN_0015340a). Pack the four remapped
	# corner values into an 8-bit pattern and consult COALESCE_TILE:
	#   pattern = (TL<<4) | (BL<<2) | (TR<<0) | (BR<<6)
	# Output 0xFE (signed -2) = "propagate-right and retry" — copy TR onto
	# BR and re-evaluate the same cell. Output 0xFF (signed -1) = no-op.
	# All other values become the new id for the top-left cell.
	for row in range(0, GRID_H - 1):
		var rb2: int = row * GRID_W
		var col: int = 0
		while col < GRID_W - 1:
			var idx: int = rb2 + col
			var TL: int = L2[idx]
			var TR: int = L2[idx + 1]
			var BL: int = L2[idx + GRID_W]
			var BR: int = L2[idx + GRID_W + 1]
			var rTL: int = MATERIAL_REMAP[TL & 0x3F]
			var rTR: int = MATERIAL_REMAP[TR & 0x3F]
			var rBL: int = MATERIAL_REMAP[BL & 0x3F]
			var rBR: int = MATERIAL_REMAP[BR & 0x3F]
			if rTL != 0xFF and rTR != 0xFF and rBL != 0xFF and rBR != 0xFF:
				var pat: int = ((rTL & 0x3) << 4) | ((rBL & 0x3) << 2) \
					| (rTR & 0x3) | ((rBR & 0x3) << 6)
				var out: int = COALESCE_TILE[pat]
				if out == 0xFE:
					# Sentinel: copy TR onto BR and retry this cell.
					L2[idx + GRID_W + 1] = TR
					continue
				if out != 0xFF:
					L2[idx] = out
			col += 1

	w.layers[2] = L2

static func sample_byte(w: WLD, layer: int, col: int, row: int) -> int:
	if w == null or layer < 0 or layer > 3:
		return 0
	if col < 0 or col >= GRID_W or row < 0 or row >= GRID_H:
		return 0
	return w.layers[layer][row * GRID_W + col]

## Corner height at heightmap (col, row) in game Y units.
static func corner_height(w: WLD, col: int, row: int) -> float:
	var b: int = sample_byte(w, 0, col, row)
	return float(HEIGHT_CURVE[b & 0x7F])

## Heightmap (col, row) under a world (X, Z).
## DOS uses (K - z) >> 8 & 0xFF — the mask wraps row into [0,255].
static func cell_for_world(wx: float, wz: float) -> Vector2i:
	var col: int = int(wx / WORLD_PER_CELL) & 0xFF
	var row: int = int((Z_FLIP_K - wz) / WORLD_PER_CELL) & 0xFF
	return Vector2i(col, row)

## Terrain Y at world (wx, wz) — the height of the ground the mesh
## actually shows: the DOS planes (each cell split NW–SE) or, in ENHANCED
## inside `w.fine_rect`, the smooth surface. Used for everything that
## stands on the ground (sprites, props, spawns); it used to return the
## cell's NW corner, which put a sprite on a slope up to a height step
## in the air.
static func height_at_world(w: WLD, wx: float, wz: float) -> float:
	if w == null:
		return 0.0
	var planar: float = height_planar(w, wx, wz)
	if not Render.enhanced() or not w.fine_rect.has_area():
		return planar
	var k: float = fine_weight(w, wx, wz)
	if k <= 0.0:
		return planar
	return lerpf(planar, height_smooth(w, wx, wz), k)

## Cell-local (u, v) in [0, 1) at world (wx, wz): u east across the
## cell, v south (row direction).
static func _cell_uv(wx: float, wz: float) -> Vector2:
	var fx: float = wx / WORLD_PER_CELL
	var fz: float = (Z_FLIP_K - wz) / WORLD_PER_CELL
	return Vector2(fx - floorf(fx), fz - floorf(fz))

## The DOS ground: two planes per cell, split on the NW–SE diagonal
## (the same triangles build_terrain_mesh draws).
static func height_planar(w: WLD, wx: float, wz: float) -> float:
	var c := cell_for_world(wx, wz)
	var uv := _cell_uv(wx, wz)
	var h_nw: float = corner_height(w, c.x, c.y)
	var h_ne: float = corner_height(w, mini(c.x + 1, GRID_W - 1), c.y)
	var h_sw: float = corner_height(w, c.x, mini(c.y + 1, GRID_H - 1))
	var h_se: float = corner_height(w, mini(c.x + 1, GRID_W - 1), mini(c.y + 1, GRID_H - 1))
	if uv.x >= uv.y:
		return h_nw + uv.x * (h_ne - h_nw) + uv.y * (h_se - h_ne)
	return h_nw + uv.y * (h_sw - h_nw) + uv.x * (h_se - h_sw)

## 1 inside the fine box, 0 outside the FINE_TAPER ring around it.
static func fine_weight(w: WLD, wx: float, wz: float) -> float:
	var r := w.fine_rect
	var dx: float = maxf(maxf(r.position.x - wx, wx - r.end.x), 0.0)
	var dz: float = maxf(maxf(r.position.y - wz, wz - r.end.y), 0.0)
	return clampf(1.0 - maxf(dx, dz) / FINE_TAPER, 0.0, 1.0)

## Corner heights, cached: index = row * (GRID_W + 1) + col, edges
## clamped so the interpolant has neighbours everywhere.
static func _corners(w: WLD) -> PackedFloat32Array:
	if w._corner_cache.is_empty():
		var cw: int = GRID_W + 1
		var out := PackedFloat32Array()
		out.resize(cw * (GRID_H + 1))
		for r in GRID_H + 1:
			for c in cw:
				out[r * cw + c] = corner_height(w, mini(c, GRID_W - 1), mini(r, GRID_H - 1))
		w._corner_cache = out
	return w._corner_cache

## Fritsch–Butland tangent from the two neighbouring slopes: zero at a
## crest, a trough or next to a flat run (so a plateau stays exactly
## flat and the whole S-curve lives in the sloped cell), the harmonic
## mean otherwise (a straight slope stays straight).
static func _mono_tangent(d0: float, d1: float) -> float:
	if d0 * d1 <= 0.0:
		return 0.0
	return 2.0 * d0 * d1 / (d0 + d1)

## Monotone cubic through q1 → q2 at t, with q0/q3 the outer neighbours.
## Never overshoots: the result lies between q1 and q2.
static func _mono1d(q0: float, q1: float, q2: float, q3: float, t: float) -> float:
	var m1: float = _mono_tangent(q1 - q0, q2 - q1)
	var m2: float = _mono_tangent(q2 - q1, q3 - q2)
	var t2: float = t * t
	var t3: float = t2 * t
	return (2.0 * t3 - 3.0 * t2 + 1.0) * q1 + (t3 - 2.0 * t2 + t) * m1 \
		+ (-2.0 * t3 + 3.0 * t2) * q2 + (t3 - t2) * m2

## The smooth ground: a separable monotone cubic over the corner grid
## (rows along X first, then the 4 row values along Z). It passes
## through every corner, never leaves the range of the cell's own four
## corners (so the terrain occluders and anything placed at a corner
## stay valid), keeps flat cells flat and straight slopes straight, and
## turns each terrace step into an S-curve inside its cell.
static func height_smooth(w: WLD, wx: float, wz: float) -> float:
	var hs := _corners(w)
	var cw: int = GRID_W + 1
	var c := cell_for_world(wx, wz)
	var uv := _cell_uv(wx, wz)
	var r0: float = 0.0
	var r1: float = 0.0
	var r2: float = 0.0
	var r3: float = 0.0
	var ca: int = clampi(c.x - 1, 0, GRID_W)
	var cb: int = clampi(c.x, 0, GRID_W)
	var cc: int = clampi(c.x + 1, 0, GRID_W)
	var cd: int = clampi(c.x + 2, 0, GRID_W)
	for j in 4:
		var base: int = clampi(c.y - 1 + j, 0, GRID_H) * cw
		var v: float = _mono1d(hs[base + ca], hs[base + cb], hs[base + cc], hs[base + cd], uv.x)
		match j:
			0: r0 = v
			1: r1 = v
			2: r2 = v
			_: r3 = v
	return _mono1d(r0, r1, r2, r3, uv.y)

## The ground the ENHANCED fine mesh is built from: planar outside the
## box, smooth inside, blended across the taper ring.
static func height_fine(w: WLD, wx: float, wz: float) -> float:
	var k: float = fine_weight(w, wx, wz)
	var planar: float = height_planar(w, wx, wz)
	if k <= 0.0:
		return planar
	return lerpf(planar, height_smooth(w, wx, wz), k)

## Per-cell vertex colour from WLD layer 2 (material id, &0x3F).
## Hand-tuned palette covering the dominant material ids on MAP.210.
## Unknown materials fall back to neutral sand so the terrain reads
## as a coherent ground instead of a Mondrian of HSV stripes.
## Brightness modulated by layer-0 height shade so slopes still read.
static func material_color(b2: int, b0: int) -> Color:
	var key: int = b2 & 0x3F
	var base: Color
	match key:
		2:  base = Color(0.55, 0.55, 0.55)  # concrete / road
		17: base = Color(0.45, 0.35, 0.30)  # secondary rock
		18: base = Color(0.50, 0.42, 0.32)  # gravel
		31: base = Color(0.40, 0.40, 0.45)  # darker concrete
		36: base = Color(0.60, 0.50, 0.35)  # dirt
		39: base = Color(0.30, 0.45, 0.20)  # grass
		46: base = Color(0.55, 0.40, 0.28)  # canyon rock (brown)
		60: base = Color(0.78, 0.70, 0.50)  # sand
		_:  base = Color(0.65, 0.58, 0.42)  # neutral sand fallback
	var h_shade: float = 0.7 + 0.3 * (float(b0 & 0x7F) / 127.0)
	return Color(base.r * h_shade, base.g * h_shade, base.b * h_shade)

## Blended vertex colour at a grid CORNER (col, row) — averages the
## material colours of up to 4 cells that share this corner.
## Produces smooth colour transitions at material boundaries instead
## of hard per-cell edges.  Used by build_terrain_mesh() for each of
## the 4 corners of every cell quad.
##
## When `avg_colors` is non-empty (Array[Color] indexed by mat_id),
## the colour is taken from that palette instead of the hardcoded one.
## This lets level_loader derive colours from the actual TEXTURE tiles.
static func corner_blended_color(w: WLD, col: int, row: int,
		avg_colors: Array = []) -> Color:
	var total := Color(0.0, 0.0, 0.0)
	var count: int = 0
	# The 4 cells sharing corner (col, row): (col-1,row-1), (col,row-1),
	# (col-1,row), (col,row).  Each cell occupies [c..c+1] × [r..r+1].
	for dr in [-1, 0]:
		for dc in [-1, 0]:
			var cr: int = row + dr
			var cc: int = col + dc
			if cr >= 0 and cr < GRID_H and cc >= 0 and cc < GRID_W:
				var b2: int = sample_byte(w, 2, cc, cr)
				var b0: int = sample_byte(w, 0, cc, cr)
				var mat: int = b2 & 0x3F
				if not avg_colors.is_empty() and mat < avg_colors.size() \
						and avg_colors[mat] != null:
					var h_shade: float = 0.7 + 0.3 * (float(b0 & 0x7F) / 127.0)
					var ac: Color = avg_colors[mat]
					total += Color(ac.r * h_shade, ac.g * h_shade, ac.b * h_shade)
				else:
					total += material_color(b2, b0)
				count += 1
	if count == 0:
		return Color(0.5, 0.5, 0.5)
	return Color(total.r / count, total.g / count, total.b / count)

## Build the terrain ArrayMesh covering the full 256×256 heightmap.
##
## DOS textures terrain with a continuous world-planar projection: each
## cell binds one TEXTURE.302 tile chosen by (layer2 & 0x3F), and the UV
## flows with world position so a road runs unbroken across cells. This
## is reproduced with one ArrayMesh surface per material id, world-planar
## UVs (one tile per cell) and the tile texture left at REPEAT wrap.
##
## `tile_textures` is an Array of Texture2D indexed by material id (built
## from TEXTURE.302). When empty, a vertex-colour fallback is used.
static func build_terrain_mesh(w: WLD, tile_textures: Array = [],
		tile_normals: Array = [], avg_colors: Array = []) -> ArrayMesh:
	if w == null:
		return null
	if Render.enhanced() and w.fine_rect.has_area():
		return _build_fine(w, tile_textures, tile_normals, avg_colors)
	var has_tex: bool = not tile_textures.is_empty()

	# Pre-compute the per-corner blended colours for every grid vertex.
	# Stored in a flat array: index = row * (GRID_W+1) + col.
	# Each vertex is shared by up to 4 cells; averaging their material
	# colours produces smooth transitions at material boundaries.
	var cw: int = GRID_W + 1
	var corner_colors: Array = []
	corner_colors.resize(cw * (GRID_H + 1))
	for r in range(GRID_H + 1):
		for c in range(GRID_W + 1):
			corner_colors[r * cw + c] = corner_blended_color(w, c, r, avg_colors)

	# One vertex bucket per material id → one ArrayMesh surface each, so
	# every material binds its own tile. bucket = [pos, norm, uv, col],
	# plain Arrays (fast append; converted to Packed arrays at the end).
	var buckets: Dictionary = {}

	for row in range(GRID_H - 1):
		for col in range(GRID_W - 1):
			var h_NW := corner_height(w, col,     row    )
			var h_NE := corner_height(w, col + 1, row    )
			var h_SW := corner_height(w, col,     row + 1)
			var h_SE := corner_height(w, col + 1, row + 1)

			var x0 := col       * WORLD_PER_CELL
			var x1 := (col + 1) * WORLD_PER_CELL
			# Negate Z: DOS +Z = forward, Godot +Z = backward.
			var z_n := -(Z_FLIP_K - row       * WORLD_PER_CELL)
			var z_s := -(Z_FLIP_K - (row + 1) * WORLD_PER_CELL)

			var p_NW := Vector3(x0, h_NW, z_n)
			var p_NE := Vector3(x1, h_NE, z_n)
			var p_SE := Vector3(x1, h_SE, z_s)
			var p_SW := Vector3(x0, h_SW, z_s)

			# World-planar UV: one tile per 256-unit cell, continuous
			# across cells — with REPEAT wrap a road tiles seamlessly.
			# Layer-2 bits 6/7 orient the tile (XnGine, as in Daggerfall):
			# bit 6 rotates 90°, bit 7 flips (180°). Road edge and corner
			# tiles only join up when honoured.
			var b2: int = sample_byte(w, 2, col, row)
			var orient: int = ((b2 & 0x40) >> 6) | ((b2 & 0x80) >> 6)
			if TILE_ROT_CCW:
				orient = (4 - orient) & 3
			var uv_NW := Vector2(float(col),     float(row))
			var uv_NE := Vector2(float(col + 1), float(row))
			var uv_SE := Vector2(float(col + 1), float(row + 1))
			var uv_SW := Vector2(float(col),     float(row + 1))

			var mat_id: int = b2 & 0x3F

			# Per-corner blended colours (smooth transitions at boundaries).
			var c_NW: Color = corner_colors[row       * cw + col      ]
			var c_NE: Color = corner_colors[row       * cw + (col + 1)]
			var c_SW: Color = corner_colors[(row + 1) * cw + col      ]
			var c_SE: Color = corner_colors[(row + 1) * cw + (col + 1)]

			var bk = buckets.get(mat_id)
			if bk == null:
				bk = [[], [], [], []]
				buckets[mat_id] = bk
			var bp: Array = bk[0]
			var bn: Array = bk[1]
			var bu: Array = bk[2]
			var bc: Array = bk[3]

			# Split each cell on the NW-SE diagonal.
			var n1 := (p_SE - p_NW).cross(p_NE - p_NW).normalized()
			var n2 := (p_SW - p_NW).cross(p_SE - p_NW).normalized()
			bp.append(p_NW); bp.append(p_NE); bp.append(p_SE)
			bp.append(p_NW); bp.append(p_SE); bp.append(p_SW)
			bn.append(n1); bn.append(n1); bn.append(n1)
			bn.append(n2); bn.append(n2); bn.append(n2)
			if orient != 0:
				var base_c := Vector2(float(col), float(row))
				var q := [uv_NW - base_c, uv_NE - base_c, uv_SE - base_c, uv_SW - base_c]
				for r_i in orient:
					for i in 4:
						q[i] = Vector2(1.0 - q[i].y, q[i].x)   # rotate 90° about the tile centre
				uv_NW = q[0] + base_c
				uv_NE = q[1] + base_c
				uv_SE = q[2] + base_c
				uv_SW = q[3] + base_c
			bu.append(uv_NW); bu.append(uv_NE); bu.append(uv_SE)
			bu.append(uv_NW); bu.append(uv_SE); bu.append(uv_SW)
			# Per-corner colours — each triangle vertex gets the blended
			# colour of its grid corner, not a flat per-cell colour.
			bc.append(c_NW); bc.append(c_NE); bc.append(c_SE)
			bc.append(c_NW); bc.append(c_SE); bc.append(c_SW)

	if buckets.is_empty():
		return null

	var am := ArrayMesh.new()
	var mat_ids := buckets.keys()
	mat_ids.sort()
	for mat_id in mat_ids:
		var bk: Array = buckets[mat_id]
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(bk[0])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(bk[1])
		if Render.enhanced():
			# Rolling hills instead of faceted cells: normals averaged over
			# the shared grid corners (within the bucket).
			arrays[Mesh.ARRAY_NORMAL] = Mesh3DLoader.smooth_normals(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL], 80.0)
			arrays[Mesh.ARRAY_TANGENT] = Mesh3DLoader._tangents_for(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL], PackedVector2Array(bk[2]))
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(bk[2])
		if Render.enhanced():
			# UV2 from the world position: the ENHANCED detail layer
			# (photo grain + normals) tiles evenly whatever the tile's
			# own orientation.
			var uv2 := PackedVector2Array()
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			uv2.resize(verts.size())
			for vi in verts.size():
				uv2[vi] = Vector2(verts[vi].x, verts[vi].z) / Render.DETAIL_WORLD_SIZE
			arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_COLOR]  = PackedColorArray(bk[3])
		var si: int = am.get_surface_count()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var smat := StandardMaterial3D.new()
		smat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var tex: Texture2D = null
		if has_tex and mat_id >= 0 and mat_id < tile_textures.size():
			tex = tile_textures[mat_id]
		if tex != null:
			smat.albedo_texture = tex
			smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			# DOS draws the raw tile texture — no lighting and no vertex
			# tint (the blended corner colours only serve the untextured
			# fallback below). Depth comes from the fog instead.
			smat.vertex_color_use_as_albedo = false
			smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			var nrm: Texture2D = tile_normals[mat_id] if mat_id < tile_normals.size() else null
			Render.style(smat, "terrain", nrm)
		else:
			# No tile — vertex colour IS the albedo.
			smat.vertex_color_use_as_albedo = true
			smat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
		am.surface_set_material(si, smat)
	return am

# ---------------------------------------------------------------------
# ENHANCED fine terrain
# ---------------------------------------------------------------------
## Same surfaces per material and the same world-planar tile UVs as the
## classic mesh, but indexed, with the ground from `height_fine` and
## normals from its finite differences. A cell is subdivided FINE_DIV ×
## FINE_DIV when it lies in the fine box (or its taper ring) AND its four
## corners differ; every other cell is the two DOS triangles, which the
## interpolant reproduces exactly, so the two kinds meet without cracks.
static func _build_fine(w: WLD, tile_textures: Array, tile_normals: Array,
		avg_colors: Array) -> ArrayMesh:
	var has_tex: bool = not tile_textures.is_empty()
	var t0: int = Time.get_ticks_msec()
	# The outer rect (box + taper) in cell coordinates: cells outside it
	# are planar however sloped they are.
	var outer: Rect2 = w.fine_rect.grow(FINE_TAPER)
	var col0: int = clampi(int(floorf(outer.position.x / WORLD_PER_CELL)), 0, GRID_W - 1)
	var col1: int = clampi(int(ceilf(outer.end.x / WORLD_PER_CELL)), 0, GRID_W - 1)
	var row0: int = clampi(int(floorf((Z_FLIP_K - outer.end.y) / WORLD_PER_CELL)), 0, GRID_H - 1)
	var row1: int = clampi(int(ceilf((Z_FLIP_K - outer.position.y) / WORLD_PER_CELL)), 0, GRID_H - 1)

	var cw: int = GRID_W + 1
	var corner_colors: Array = []
	if not has_tex:
		corner_colors.resize(cw * (GRID_H + 1))
		for r in range(GRID_H + 1):
			for c in range(GRID_W + 1):
				corner_colors[r * cw + c] = corner_blended_color(w, c, r, avg_colors)

	# bucket = [pos, norm, tan, uv, uv2, col, idx]
	var buckets: Dictionary = {}
	var fine_cells: int = 0
	var n: int = FINE_DIV
	for row in range(GRID_H - 1):
		for col in range(GRID_W - 1):
			var h_nw := corner_height(w, col, row)
			var h_ne := corner_height(w, col + 1, row)
			var h_sw := corner_height(w, col, row + 1)
			var h_se := corner_height(w, col + 1, row + 1)
			var sloped: bool = h_nw != h_ne or h_nw != h_sw or h_nw != h_se
			var in_box: bool = col >= col0 and col <= col1 and row >= row0 and row <= row1
			var div: int = n if (sloped and in_box) else 1
			if div > 1:
				fine_cells += 1

			var b2: int = sample_byte(w, 2, col, row)
			var orient: int = ((b2 & 0x40) >> 6) | ((b2 & 0x80) >> 6)
			if TILE_ROT_CCW:
				orient = (4 - orient) & 3
			var mat_id: int = b2 & 0x3F
			var bk = buckets.get(mat_id)
			if bk == null:
				bk = [PackedVector3Array(), PackedVector3Array(), PackedFloat32Array(),
					PackedVector2Array(), PackedVector2Array(), PackedColorArray(), PackedInt32Array()]
				buckets[mat_id] = bk
			var bp: PackedVector3Array = bk[0]
			var bn: PackedVector3Array = bk[1]
			var bt: PackedFloat32Array = bk[2]
			var bu: PackedVector2Array = bk[3]
			var bu2: PackedVector2Array = bk[4]
			var bc: PackedColorArray = bk[5]
			var bi: PackedInt32Array = bk[6]
			var first: int = bp.size()

			# The tile's UV Jacobian is constant, so the tangent (the world
			# direction along which U grows) and the bitangent (V) are one
			# pair per tile: U/V per cell of world X and of world Z(Godot),
			# the latter growing with the row.
			var base_c := Vector2(float(col), float(row))
			var uv_c: Vector2 = _tile_uv(base_c, orient, 0.5, 0.5)
			var d_du: Vector2 = (_tile_uv(base_c, orient, 0.51, 0.5) - uv_c) / 0.01   # dUV per +X cell
			var d_dv: Vector2 = (_tile_uv(base_c, orient, 0.5, 0.51) - uv_c) / 0.01   # dUV per +Z(Godot) cell
			var tan_w := Vector3(d_du.x, 0.0, d_dv.x).normalized()   # gradient of U
			var bit_w := Vector3(d_du.y, 0.0, d_dv.y).normalized()   # gradient of V

			for j in div + 1:
				for i in div + 1:
					var wx: float = (float(col) + float(i) / float(div)) * WORLD_PER_CELL
					var wz_dos: float = Z_FLIP_K - (float(row) + float(j) / float(div)) * WORLD_PER_CELL
					var h: float
					var nrm: Vector3
					if div > 1:
						h = height_fine(w, wx, wz_dos)
						var hx: float = height_fine(w, wx + FINE_EPS, wz_dos)
						var hz: float = height_fine(w, wx, wz_dos - FINE_EPS)   # south = -Z(DOS) = +Z(Godot)
						nrm = Vector3(-(hx - h) / FINE_EPS, 1.0, -(hz - h) / FINE_EPS).normalized()
					else:
						# Corner of a planar cell: the corner height and the
						# average slope around it (smooth shading).
						h = corner_height(w, mini(col + i, GRID_W - 1), mini(row + j, GRID_H - 1))
						var hx1: float = height_fine(w, wx + FINE_EPS, wz_dos)
						var hx0: float = height_fine(w, wx - FINE_EPS, wz_dos)
						var hz1: float = height_fine(w, wx, wz_dos - FINE_EPS)
						var hz0: float = height_fine(w, wx, wz_dos + FINE_EPS)
						nrm = Vector3(-(hx1 - hx0) / (2.0 * FINE_EPS), 1.0, -(hz1 - hz0) / (2.0 * FINE_EPS)).normalized()
					bp.append(Vector3(wx, h, -wz_dos))
					bn.append(nrm)
					# Gram-Schmidt the tile tangent against the normal.
					var t: Vector3 = (tan_w - nrm * nrm.dot(tan_w)).normalized()
					var hand: float = 1.0 if nrm.cross(t).dot(bit_w) >= 0.0 else -1.0
					bt.append(t.x); bt.append(t.y); bt.append(t.z); bt.append(hand)
					bu.append(_tile_uv(base_c, orient, float(i) / float(div), float(j) / float(div)))
					bu2.append(Vector2(wx, -wz_dos) / Render.DETAIL_WORLD_SIZE)
					if not has_tex:
						# Nearest corner's blended colour (fallback look only).
						var cc: int = mini(col + int(round(float(i) / float(div))), GRID_W)
						var cr: int = mini(row + int(round(float(j) / float(div))), GRID_H)
						bc.append(corner_colors[cr * cw + cc])
			# Two triangles per sub-cell, split NW–SE like the DOS cell.
			var stride: int = div + 1
			for j in div:
				for i in div:
					var v_nw: int = first + j * stride + i
					var v_ne: int = v_nw + 1
					var v_sw: int = v_nw + stride
					var v_se: int = v_sw + 1
					bi.append(v_nw); bi.append(v_ne); bi.append(v_se)
					bi.append(v_nw); bi.append(v_se); bi.append(v_sw)

	if buckets.is_empty():
		return null
	var am := ArrayMesh.new()
	var mat_ids := buckets.keys()
	mat_ids.sort()
	var verts_total: int = 0
	var tris_total: int = 0
	for mat_id in mat_ids:
		var bk: Array = buckets[mat_id]
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = bk[0]
		arrays[Mesh.ARRAY_NORMAL] = bk[1]
		arrays[Mesh.ARRAY_TANGENT] = bk[2]
		arrays[Mesh.ARRAY_TEX_UV] = bk[3]
		arrays[Mesh.ARRAY_TEX_UV2] = bk[4]
		if not has_tex:
			arrays[Mesh.ARRAY_COLOR] = bk[5]
		arrays[Mesh.ARRAY_INDEX] = bk[6]
		verts_total += (bk[0] as PackedVector3Array).size()
		tris_total += (bk[6] as PackedInt32Array).size() / 3
		var si: int = am.get_surface_count()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var smat := StandardMaterial3D.new()
		smat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var tex: Texture2D = null
		if has_tex and mat_id >= 0 and mat_id < tile_textures.size():
			tex = tile_textures[mat_id]
		if tex != null:
			smat.albedo_texture = tex
			smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			smat.vertex_color_use_as_albedo = false
			smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			var nrm_tex: Texture2D = tile_normals[mat_id] if mat_id < tile_normals.size() else null
			Render.style(smat, "terrain", nrm_tex)
		else:
			smat.vertex_color_use_as_albedo = true
			smat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
		am.surface_set_material(si, smat)
	print("[terrain] fine mesh: box cells %d..%d x %d..%d, %d sloped cells subdivided %dx, %d vertices, %d triangles in %d surfaces (%d ms)"
		% [col0, col1, row0, row1, fine_cells, FINE_DIV, verts_total, tris_total, am.get_surface_count(),
		   Time.get_ticks_msec() - t0])
	return am

## World-planar tile UV at cell-local (u, v) with the layer-2 orientation
## applied about the tile centre (the classic builder's rotation).
static func _tile_uv(base_c: Vector2, orient: int, u: float, v: float) -> Vector2:
	var q := Vector2(u, v)
	for r_i in orient:
		q = Vector2(1.0 - q.y, q.x)
	return q + base_c
