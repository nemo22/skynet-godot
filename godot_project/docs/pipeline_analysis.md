# SkyNET / FutureShock — DOS rendering pipeline analysis

Synthesised from parallel agent decodes of the DOS and Win32 builds.
The authoritative DOS reference is `C:\Games\SKYNET\skynet_gh.c`
(Ghidra decompile of SKYNET.EXE, 66 379 lines); Win32 cross-reference
is `FutureShock32_noblob.exe.c` / `fshock.exe.c`. `FUN_xxxxxxxx` names
and line numbers anchor into `skynet_gh.c` unless noted; older
`sub_xxxxxx` names refer to a now-superseded earlier decompile.

This document supersedes everything we previously believed about
placement, rotation, and the meaning of sub-record fields.

---

## CORRECTIONS — 2026-05-17 (verified directly in `skynet_gh.c`)

A second deep pass (DOS Ghidra decompile `skynet_gh.c`, 66 379 lines)
overturned several claims in the original draft below. Where the older
text disagrees, **this section wins**.

1. **Entity Y is used VERBATIM.** `Map_ToScene` `FUN_00136519`
   (:38194-38198) copies `entity+0x0C` straight into the render struct.
   No terrain-height sampling, no AABB-bottom offset, no per-mesh
   floor-align — for static meshes *and* actors. `godot_y = -entity.Y`.

2. **The 3×i32 sub-record values ARE rotation, and the order is
   pitch/yaw/roll** (not yaw/pitch/roll). `FUN_00150284` (:55059) calls
   `FUN_0014e100(entity[0xb], entity[0xc], …)`; `FUN_0014e100` (:53859)
   puts `sin(param_1)` isolated at `matrix[7]` → param_1 is the X-axis
   rotation. `Map_ToScene` copies sub+0→[0xb], sub+4→[0xc], sub+8→[0xd].
   So: **sub+0 = pitch (X), sub+4 = yaw (Y), sub+8 = roll (Z)**. Engine
   builds `R = Rz(roll)·Rx(pitch)·Ry(yaw)`.

3. **Variant 2 is a dynamic LIGHT source, NOT an enemy spawner.** The
   walker (:38244-38249) calls `FUN_0011b733` = AddLightSafe(x, y,
   intensity) when the `i16` at sub+8 is `> 0`. sub+0 = light intensity.

4. **Enemies are variant-1 entities with `flags & 0x40` (actor flag).**
   They are real `.3D` meshes living in **`MDMDENMS.BSA`** (AVSOLDER.3D,
   AVTRMNTR.3D, AVFEMALE.3D …), not `MDMDOBJS.BSA`. The animation frame
   index sits in a linked actor record at `+0x16`, initial value 0.

5. **`.3D` meshes carry an explicit frame table.** Header `+0x10` u32 =
   frame_count (0 = static); `+0x14` u32 = frame-table offset, 16-byte
   entries `{vertex_off, uv_off, aux_off, u16}`; `+0x30` = frame-0
   vertex block; `+0x3c` = face array. Verified via `FUN_0013425d`
   (:37066) and `FUN_0014ff0e` (:54879).

6. **Coordinate conversion is `(x, -y, -z)` for BOTH mesh vertices and
   entity positions** — `C = diag(1,-1,-1) = Rx(180°)`, det +1, a proper
   rotation. The old `(x,-y,z)` mesh convention was a reflection (det
   −1) and the source of the "needs CULL_DISABLED" workaround. Godot
   rotation = `C·R·C⁻¹ = Rz(-roll)·Rx(+pitch)·Ry(-yaw)`.

The detailed sections below are kept for their function/line anchors but
read them through the lens of these six corrections.

## Coordinate system

| Axis | DOS world | Godot target | Conversion |
|------|-----------|--------------|------------|
| X    | +X right  | +X right     | identity   |
| Y    | +Y **down** (floor is positive) | +Y up | negate |
| Z    | +Z forward (into screen) | +Z back | identity for terrain & entity placement, but mesh winding depends on handedness — currently mitigated by `CULL_DISABLED` |

DOS world is **right-handed Y-down**. Godot is **right-handed Y-up**.
Negating Y on import (both for entity position and mesh vertices) is
correct. Cell stride is **256 game units / WLD cell**, **1024 game
units / MAP cell** (one MAP cell = 4×4 WLD cells).

## Camera state (agent 1D)

```
qword_1049B4   low  = player X (i32 game units)
qword_1049B4   high = player Y (i32 game units, Y-down)
dword_1049BC         = player Z (i32 game units)
dword_1049A8         = yaw   (0..2047 maps to 0..360°)
dword_1049AC         = pitch (same 11-bit angle unit)
dword_1049B0         = roll  (same)
dword_10C700[2048]   = sine LUT,   28-bit fixed point (0x10000000 = 1.0)
dword_10CF00[2048]   = cosine LUT, same encoding
```

**Angle unit: 2048 = 360°.** Half a turn = 1024. Quarter turn = 512.
Important for understanding hex dumps — values like 1024 / 2048 / 512
that we previously read in sub-records are NOT angles (see §"3 i32 in
sub-record" below).

View matrix is computed by `sub_14E600` (line 81513-81542) as a 3×3
row-major rotation. Sub-pixel precision is `<< 8` (multiply by 256)
applied to camera-relative coordinates before perspective divide.
Screen 320×200, FOV ≈ 60° (focal length embedded in matrix scaling).

## MAP loader pipeline (agent 1A)

```
sub_12E200(map_id)         line 58871   — top-level loader
├─ sub_13E897(...)         locate MAP entry in MDMDMAP2.BSA
├─ sub_13E60B(...)         decompress into memory at dword_54C8E
├─ check MAP[+9028]        1=outdoor → dword_54C96 = 1
│                          else (2)  → dword_54C96 = 2 (indoor)
├─ sub_1369D5              init coord ranges
├─ sub_1367BE              init cell/entity buckets
├─ sub_120670              ENTITY WALKER (see below)
└─ if outdoor: load WLD via sub_13E9B9(aGamedataWld, ...)
```

### MAP header

```
+0   u32   cell_count (total entities)
+4   u32   grid_width   ← also drives Z-flip K (see Terrain §)
+8   u32   grid_height
+12  u32   payload_offset (= 0x253C)
+16  u32   sentinel (= 0xFFFFFFFF)
+20.. 8-byte ASCII name slots, NUL-padded, until invalid slot
+0x253C    cell grid: gw*gh × u32 entity-list head offsets
+9028 u32  indoor/outdoor (1=outdoor)
+9032 u32  entity count for indoor maps
```

### Entity record (48 bytes, fixed)

```
+0  u32  next_off (linked list within cell; 0/-1/-2 = end)
+4  u32  back/sentinel
+8  i32  X (DOS game units)
+12 i32  Y (DOS Y-down: negative = above ground)
+16 i32  Z
+20 u8   flags
              & 0x03 = variant (1 = static mesh, 2 = spawner, 3 = sprite)
              & 0x08 = SKIP entity
              & 0x40 = actor (has linked yaw record)
+21 u32  sub_record_ptr (always = entity_off + 25 in our files)
+25..47  variant-specific sub-record (23 bytes)
```

### Sub-record by variant  (corrected — see CORRECTIONS §2/§3)

```
variant 1 (named .3D mesh / actor):
  +0  i32 pitch  (X-axis Euler angle, 11-bit: & 0x7FF, 2048 = 360°)
  +4  i32 yaw    (Y-axis)
  +8  i32 roll   (Z-axis)
  +12 u16 name_idx into MAP names[]
  actor (flags & 0x40): enemy/NPC; mesh in MDMDENMS.BSA; current
         animation frame in a linked actor record at +0x16

variant 2 (dynamic LIGHT source — NOT a spawner):
  +0  u16 light intensity  (passed to AddLightSafe)
  +8  i16 enable gate      (light emitted only when > 0)

variant 3 (billboard sprite):
  +0  u16 sprite_index (resolved against MDMDIMGS.BSA, not MAP names[])
```

### Variant walker  —  `Map_ToScene` FUN_00136519 (skynet_gh.c:38186)

```c
for each cell (cz, cx):
  e_off = MAP[+0x253C + (cz*gw + cx)*4]
  while e_off is valid:                 // linked list via entity[+0]
    flags = entity[+0x14]
    if (flags & 0x08) continue          // skip flag
    switch (flags & 3):
      case 1: build render struct       // static mesh OR actor (0x40)
              → FUN_0011b768(frame_idx)  // frame 0 for non-actors
      case 2: if (i16 at sub+8 > 0)
                FUN_0011b733(x, y, intensity)   // = AddLightSafe
      case 3: FUN_0014ea20(...)          // billboard draw list
```

## WLD + terrain pipeline (agent 1B)

```
WLD file layout (chunk-based, verified against FutureShock32.exe
sub_4AC130 and hex dumps of WLD.200/210/230/600):
  +0x00   u32  unknown (=16)
  +0x04   u32  chunks_x (=2, so grid_w = 2*128 = 256)
  +0x08   u32  chunks_y (=2, so grid_h = 2*128 = 256)
  +0x18   u32  chunk header size (=22)
  +0x90   u32[chunks_x*chunks_y]  chunk offset table

Per chunk (at file_offset = chunk_off from table):
  +0..21   22-byte chunk header
  +22      layer 0 (heights), 128×128 = 16384 bytes
  +16406   layer 1 (decorations), 16384 bytes
  +32790   layer 2 (materials), 16384 bytes
  +49174   layer 3 (unknown), 16384 bytes
  Total per chunk: 22 + 4×16384 = 65558 bytes

Chunk order (row-major): (0,0)=NW, (1,0)=NE, (0,1)=SW, (1,1)=SE
Full grid assembled: 256×256 cells = 65536 bytes per layer

Previous flat-read from 0x4F8 was WRONG — the data at 0x4F8 is
partway into chunk 0, and layers are interleaved with chunk headers.
```

### Loader

```
sub_152AF0           line 83295   — main loader
sub_152C0A           init globals
  dword_1049C0 = dword_104DDD << 15    // K_y = grid_height << 15
  dword_1049C4 = dword_104DE1 << 15    // K_x = grid_width  << 15
```

**Critical:** `dword_104DE1` is loaded from **MAP+4** (= grid_width,
typically 256). For grid_width = 256 → K = 256 << 15 = 8,388,608. This
is the value used in Z-flip indexing — NOT some smaller value like
65536 or 64038 we had been using.

For each layer, three helper passes:
- `sub_152D8F` — set detail/LOD flags
- `sub_152E46` — copy / interpolate sub-cells
- `sub_152F65` — UV / lightmap generation

### Layer semantics

```
Layer 0 byte:
  bits 0..6  index into HEIGHT_CURVE[128] (dword_104FA8)
             max curve value 7760 game units
  bit 7      diagonal split direction (TL→BR vs BL→TR)

Layer 1 byte:
  >> 2       decoration spawn id in 0..0x21 (clamped)
             spawn called as: sub_14EFA5(x, y, z,
                ((word_104E6D << 7) | spawn_id) - 1)
             word_104E6D is per-map (UNCERTAIN where set)

Layer 2 byte:
  & 0x3F     material id (0..63)
             remapped:  v = byte_104952[id]
             if v & 0x80: single-tile material, use v & 0x7F
             else:       blend with neighbours:
                         tile = byte_104942[v*4 + neighbour_match]
  byte_104942 is HARDCODED in EXE:
    { 0x00, 0x04, 0x13, 0x1D, 0x08, 0x01, 0x09, 0x1C,
      0x17, 0x0D, 0x02, 0x0E, 0x21, 0x1C, 0x12, 0x03 }
  byte_104952 is per-map, populated at runtime. UNCERTAIN source —
  not in MAP loader, not in WLD loader code path we traced.

Layer 3: UNCERTAIN. Touched on load but no read found in render path.
```

### Terrain rasterizer

```
sub_14575D(xy, z)    line 76786   — barycentric height at (x, z)
  row_idx = (K_x - z) & 0xFF00      // Z-FLIP via K = grid_width<<15
  byte    = layer0[row_idx | (x_high_byte)]
  diag    = byte & 0x80
  h_NW    = HEIGHT_CURVE[byte & 0x7F] << 8
  h_NE    = HEIGHT_CURVE[layer0[row_idx + 0x100] & 0x7F] << 8
  h_SW    = HEIGHT_CURVE[layer0[row_idx + 1]     & 0x7F] << 8
  h_SE    = HEIGHT_CURVE[layer0[row_idx + 0x101] & 0x7F] << 8
  return -(barycentric(...) >> 8)
```

Iteration extent: full 256×256 cells (no per-frame visibility threshold
in the WLD code — view-radius culling, if any, is upstream).

### Texture per cell

`TEXTURE.NNN` where NNN matches **map number** (e.g. MAP.210 →
TEXTURE.210). Earlier hard-coded use of TEXTURE.300 was wrong.

### Sky / horizon

No skybox routine in decompile. Sky is fixed clear-to-color before
terrain. `HAZE.000` / `HAZE.005` exist in GAMEDATA but no usage found.

### Hex sample (WLD.210)

```
cell (0,0):   layer0 = 0x2E  → height curve 46  = 760 game units
cell (10,10): layer0 = 0x42  → height curve 66  = 1560
              layer1 = 0xCC  → spawn id 51
              layer2 = 0x42  → material 2 (& 0x3F)
              layer3 = 0x24  (?)
```

## Entity render pipeline

```
FUN_00150284   skynet_gh.c:55043   — per-entity render
  FUN_0014e100(entity[0xb], entity[0xc], &rot_matrix)  // build 3×3 from
                                       // pitch=sub+0, yaw=sub+4, roll=sub+8
  FUN_0014e904(&camera_matrix, &rot_matrix)            // compose model→view
  ...                                                  // transform verts

  // render-struct fields (built by Map_ToScene FUN_00136519):
  //   [8]  i32 entity_x     (= MAP entity +0x08)
  //   [9]  i32 entity_y     (= MAP entity +0x0C)   ← used VERBATIM
  //   [10] i32 entity_z     (= MAP entity +0x10)
  //   [0xb] i32 sub_rec[+0]  pitch  ← READ by FUN_0014e100
  //   [0xc] i32 sub_rec[+4]  yaw    ← READ by FUN_0014e100
  //   [0xd] i32 sub_rec[+8]  roll   ← READ by FUN_0014e100 (via EBX)
  v2 = (entity_x - camera_x) << 8
  v3 = (entity_y - camera_y) << 8
  v4 = (entity_z - camera_z) << 8
  a2[+20..28] = (v2, v3, v4)    // camera-relative position
  sub_15E618(v2, v3, v4, mesh_radius)   // frustum cull
  ...                                    // Z-sort bucket
```

### 3 i32 in sub-record — ROTATION ANGLES (pitch/yaw/roll)

The 3 i32 at MAP sub-record +0/+4/+8 are **11-bit Euler angles**, copied
into render-struct indices [0xb]/[0xc]/[0xd]. `FUN_00150284`
(skynet_gh.c:55043) calls:

```c
FUN_0014e100(unaff_EDI[0xb], unaff_EDI[0xc], &DAT_00104048);  // EBX = [0xd]
```

`FUN_0014e100` (skynet_gh.c:53859) builds a 3×3 matrix from the three
11-bit angles via sin/cos LUTs (DAT_0010c500 / DAT_0010cd00). The
transcribed matrix has `sin(param_1)` isolated at `out[7]` — the
signature of an **X-axis** rotation. Therefore:

```c
param_1 = sub+0 = PITCH (X axis)
param_2 = sub+4 = YAW   (Y axis)
EBX     = sub+8 = ROLL  (Z axis)
// engine composition order: R = Rz(roll) · Rx(pitch) · Ry(yaw)
```

The camera uses the same builder (skynet_gh.c:19059):
`FUN_0014e100(DAT_001047a8 /*pitch*/, DAT_001047ac /*yaw*/, …)`.

**Angle unit: 2048 = 360°.** `radians = (value & 0x7FF) * TAU / 2048.0`.

**Correct render formula** (with the consistent `C = (x,-y,-z)`
conversion applied to both mesh verts and entity position):

```
pitch = sub[0] & 0x7FF;  yaw = sub[4] & 0x7FF;  roll = sub[8] & 0x7FF
godot_pos      = ( entity.x, -entity.y, -entity.z )      # verbatim, no snap
godot_rotation = Rz(-roll) · Rx(+pitch) · Ry(-yaw)        # = C·R·C⁻¹
```

### Mesh axis convention

The `.3D` format carries no axis tag; DOS world is Y-down right-handed.
The correct DOS→Godot conversion is `(x, -y, -z)` — `C = diag(1,-1,-1)
= Rx(180°)`, det +1, a proper rotation that preserves handedness and
triangle winding. This is applied **identically** to mesh vertices and
to entity positions, so mesh-local and world space stay consistent.

The earlier `(x, -y, z)` mesh convention negated only Y — a reflection
(det −1) that flipped winding and forced the `CULL_DISABLED` workaround,
and left per-entity rotation mathematically ill-defined. Fixed
2026-05-17 in `mesh_3d.gd`.

### `.3D` animation frames

`.3D` header `+0x10` = frame_count (0 = static). `+0x14` = frame-table
offset; each 16-byte entry is `{vertex_off, uv_off, aux_off, u16}`.
Faces (`+0x3c`) and du/dv are shared across all frames; only vertex
positions differ. The current animation frame is per-entity (actor
record `+0x16`), initialised to **0** — there is no animation timer in
the mesh format, game/AI logic writes the frame index each render.

## Known unknowns

1. **`byte_104952` initialisation** (per-map texture remap). Touch
   point: would let us texture terrain properly per cell.
2. **`word_104E6D`** (per-map decoration set base). Touch point: would
   let us render the right decoration meshes from layer-1 spawn ids.
3. **Layer 3 byte purpose.** Touched on load, no read found in render.
4. **TEXTURE.NNN record layout.** Per-material descriptor format.
5. **Variant-3 sprite bank resolution** — `FUN_0014ea20` indexing of
   `sprite_index` into MDMDIMGS.BSA; high bits select a bank
   (`index>>7 == 299` = map markers).
6. **Actor-type table** — the enemy-mesh name table (0x6d-byte stride
   per type, actor type at entity `+0x1f`) for full enemy rendering;
   the simple fallback just reads the MAP name from MDMDENMS.BSA.
7. **Actor render-time Y adjust** — `FUN_00124293` snaps actors by the
   mesh bounding extent (`-(mesh[+0xc] >> 8)`); static meshes do not.

## Minimum correct port path

What we need for a faithful first-pass MAP.210 render, in priority order:

1. **[DONE] Fix WLD chunk parsing** — file uses 2×2 chunks (128×128)
   with offset table at header +0x90. Old flat-read from 0x4F8 was
   garbling 75% of the terrain. Fixed in wld_terrain.gd:parse().
2. **[DONE] Z-flip K = 65536** (= 256 cells × 256 units/cell). The DOS
   `grid_width << 15` is the same value in fixed-point representation.
3. **[DONE] Render full 256×256 terrain** — no threshold filtering.
4. **Use TEXTURE.NNN matching the map number** (TEXTURE.210, not 300)
   for per-cell terrain textures. Material ID from layer 2 (& 0x3F)
   indexes into the TEXTURE file's records.
5. **[DONE 2026-05-17] Entity placement = `pos = (e.x, -e.y, -e.z)`**
   verbatim — no terrain snap, no AABB offset, no sub-record offset.
6. **[DONE 2026-05-17] Mesh vertices `(x, -y, -z)`** — consistent
   handedness with entity placement.
7. **[DONE 2026-05-17] Entity rotation** — pitch/yaw/roll from sub
   +0/+4/+8, applied `Rz(-roll)·Rx(+pitch)·Ry(-yaw)`.
8. **[DONE 2026-05-17] Enemies** — variant-1 actors; mesh fallback to
   MDMDENMS.BSA in level_loader.gd.
9. **Sky = clear to a near-black color** (no procedural sky).
10. **Variant 2 = lights** — geometry skipped; optionally place an
    OmniLight3D at `(x,-y,-z)` with intensity from sub+0.
11. **Variant 3 placeholders** off by default.

## Open follow-ups (after 2026-05-17 fixes)

- **Visual test** the rotation signs and the `(x,-y,-z)` mesh flip on a
  DOS reference shot; flip signs / re-enable backface culling if needed.
- **Animation playback** — `mesh_3d.gd` now parses every frame into
  `Mesh3D.frames[]`; drive them (AnimationPlayer / morph) instead of
  freezing at frame 0.
- **Proper enemy meshes** — resolve actor type (`entity+0x1f`) through
  the 0x6d-stride name table rather than the MAP-name fallback.
- **Per-map terrain textures** — item 4 above (`byte_104952`).
