## .3D mesh loader (Bethesda Xngine v2.x format).
##
## Ported from fsh32_port/src/loaders/mesh_3d.c with the on-disk format
## and UV math verified against Daggerfall Unity Arch3dFile.cs (same
## engine family).
##
## Returns a Godot ArrayMesh ready for use in MeshInstance3D.
##
## Layout (struct offsets verified vs skynet_gh.c FUN_0013425d /
## FUN_0014ff0e — the .3D file is interpreted in place):
##   offset 0..3    magic "v2.X" (v2.6 animated, v2.7 static)
##   offset 4..7    u32 vertex count (per frame)
##   offset 8..11   u32 face count
##   offset 0x10    u32 frame_count (0 = static, no frame table)
##   offset 0x14    u32 frame_table offset; 16-byte entries
##                  {vertex_off, uv_off, aux_off, u16}
##   offset 0x30    u32 frame-0 vertex-block offset
##   offset 0x3c    u32 face-array offset
## Vertex: (s32 x, s32 y, s32 z), 12-byte stride. Animated meshes store
## one vertex block per frame; the frame table gives each block's offset.
## Face record: u8 vertex_count, u8 unk, u16 texture_type, u32 unk
##              then per vertex: u32 vert_byte_offset, s16 du, s16 dv
##              face stride = 8 + 8 * vert_count
##
## Texture id encoding (matches Daggerfall):
##   archive_id = type >> 7
##   record_id  = type & 0x7F
##
## UV math (verified against Daggerfall Unity Arch3dFile.cs:644 + WritePlane:857):
##   point 0     -> absolute UV (after UVunpack)
##   point 1     -> point 0 + delta
##   point 2     -> point 1 + delta
##   points 3..N -> stored values IGNORED; UVs computed by extending the
##                  (p0,p1,p2,uv0,uv1,uv2) affine map to all coplanar
##                  vertex positions via barycentric coordinates.
## UVunpack handles wrap on first 3 points.
##
## Winding / culling: XnGine culls back faces. A face is visible from the
## side on which its vertices read COUNTER-clockwise, i.e. its outward
## normal is (b-a)x(c-a). Evidence: SKY_SKY.3D (seen from inside) has all
## 50 faces wound that way, closed character models mostly so, two-sided
## catwalk plates are stored twice with reversed order (210TOWER faces
## 33/34 ...), and the Win32 port sets glFrontFace(GL_CCW)+glCullFace(GL_BACK).
## Godot's front faces are clockwise, so triangles are emitted as
## (0, k+1, k) and materials keep the default CULL_BACK. Rendering both
## sides made the reversed duplicates z-fight (moire on the tower stairs).

extends RefCounted

## DOS pipeline: (entity - camera) << 8 + mesh_vertex, so mesh vertices
## are in 1/256 world-unit space. The C port used 1/64 with 1024-unit
## cells; we use 256-unit cells (matching the DOS >> 8 cell index).
const MESH_VERT_SCALE: float = 1.0 / 256.0

class Face:
	var vert_count: int = 0
	var type: int = 0
	var idx: PackedInt32Array      # indices into vertices
	var du: PackedInt32Array       # per-face-vertex s16
	var dv: PackedInt32Array

class Mesh3D:
	var vertices: PackedVector3Array       # frame 0 (in renderer Y-up coords, scaled)
	var frames: Array[PackedVector3Array] = []  ## all animation frames (size >=1; frames[0] == vertices)
	var faces: Array[Face] = []
	var aabb: AABB
	var name: String = ""
	var frame_count: int = 1

## UV unpack — port of Daggerfall Arch3dFile.UVunpack (line 770).
## Values outside ±14336 (with -7168 reserved) are wrapped by some
## multiple of 8192; this undoes that.
static func uv_unpack(v: int) -> int:
	# SkyNET stores plain s16 deltas: a 1024 u edge carries 16384 (= 1024
	# px / 16), which the Daggerfall wrap heuristic below folded to 0 and
	# smeared one texel along the whole overpass (OVRPASS1 on MAP.230,
	# 2026-09-02 report). No SkyNET face has been found that needs the
	# wrap, so the raw value is kept.
	return v
	# v comes in as signed s16. Range check.
	if v > -14336 and v < 14336 and v != -7168:
		return v
	var next_mult: int = v - 1
	next_mult = next_mult >> 13
	next_mult += 1
	next_mult = next_mult << 13
	var prev_mult: int = next_mult - 8192
	var mult: int = prev_mult if (v - prev_mult) < (next_mult - v) else next_mult
	return v - mult

static func _u16(bytes: PackedByteArray, off: int) -> int:
	return bytes[off] | (bytes[off + 1] << 8)

static func _u32(bytes: PackedByteArray, off: int) -> int:
	return bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16) | (bytes[off + 3] << 24)

static func _s16(bytes: PackedByteArray, off: int) -> int:
	var v: int = bytes[off] | (bytes[off + 1] << 8)
	if v >= 0x8000: v -= 0x10000
	return v

static func _s32(bytes: PackedByteArray, off: int) -> int:
	var v: int = _u32(bytes, off)
	if v >= 0x80000000: v -= 0x100000000
	return v

## Quick magic check. Accepts v2.1 through v2.7. Every version shares the
## same header layout and 12-byte vertex stride — verified: ENDOSKEL v2.1
## packs 84 frames of vert_count×12 bytes exactly between its frame-0
## offset and the face array. The only format change is the face record's
## per-vertex reference field (see `face_vertex_divisor`).
static func looks_valid(bytes: PackedByteArray) -> bool:
	if bytes.size() < 48: return false
	if bytes[0] != 0x76: return false  # 'v'
	if bytes[1] != 0x32: return false  # '2'
	if bytes[2] != 0x2E: return false  # '.'
	if bytes[3] < 0x31 or bytes[3] > 0x37: return false  # '1'..'7'
	return true

## Divisor applied to a face record's per-vertex u32 to get the vertex
## index. v2.6/2.7 store a byte offset into the 12-byte-stride vertex
## array (÷12); v2.1-2.5 (ENDOSKEL, ENDORFL, T-REX*, TORTURE) store the
## index pre-multiplied by 4 (÷4). Verified against all five legacy
## meshes — every face decodes to in-range indices with this split.
static func face_vertex_divisor(bytes: PackedByteArray) -> int:
	return 12 if bytes[3] >= 0x36 else 4

## Parse a .3D mesh into the intermediate Mesh3D struct.
static func parse(bytes: PackedByteArray, mesh_name: String = "") -> Mesh3D:
	if not looks_valid(bytes):
		return null

	var m := Mesh3D.new()
	m.name = mesh_name
	var size: int = bytes.size()
	var vert_count: int = _u32(bytes, 4)
	var face_count: int = _u32(bytes, 8)
	var frame_count_field: int = _u32(bytes, 0x10)
	var frame_table_off: int   = _u32(bytes, 0x14)
	var vertex_off0: int       = _u32(bytes, 0x30)
	var faces_off: int         = _u32(bytes, 0x3c)

	if vert_count == 0 or face_count == 0: return null
	if vertex_off0 < 48 or vertex_off0 >= size: return null
	if faces_off <= vertex_off0 or faces_off > size: return null

	var frame_stride: int = vert_count * 12

	# Per-frame vertex-block offsets. A non-zero frame_count_field with a
	# valid frame table gives the explicit per-frame offsets (animation
	# frames are NOT guaranteed contiguous). Otherwise fall back to the
	# contiguous-block heuristic: frames packed from vertex_off0 to
	# faces_off back to back.
	var frame_offsets := PackedInt32Array()
	if frame_count_field > 0 and frame_count_field <= 4096 \
			and frame_table_off >= 64 \
			and frame_table_off + frame_count_field * 16 <= size:
		for fi in frame_count_field:
			frame_offsets.append(_u32(bytes, frame_table_off + fi * 16))
	else:
		var vbytes: int = faces_off - vertex_off0
		if vbytes < frame_stride or vbytes % frame_stride != 0: return null
		for fi in (vbytes / frame_stride):
			frame_offsets.append(vertex_off0 + fi * frame_stride)

	# --- vertices (all frames) ---
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	for fi in frame_offsets.size():
		var base: int = frame_offsets[fi]
		if base < 48 or base + frame_stride > size:
			if fi == 0: return null
			break          # drop trailing bad frames, keep what parsed
		var verts := PackedVector3Array()
		verts.resize(vert_count)
		for i in vert_count:
			var off := base + i * 12
			var x: float = _s32(bytes, off) * MESH_VERT_SCALE
			var y: float = _s32(bytes, off + 4) * MESH_VERT_SCALE
			var z: float = _s32(bytes, off + 8) * MESH_VERT_SCALE
			# DOS world is Y-down right-handed; Godot is Y-up right-handed.
			# Negate Y and Z (= Rx 180°, det +1). Entity placement negates
			# Y and Z identically, so mesh and world share one consistent
			# handedness — no reflection, winding is preserved.
			var v := Vector3(x, -y, -z)
			verts[i] = v
			if fi == 0:
				min_v.x = min(min_v.x, v.x); max_v.x = max(max_v.x, v.x)
				min_v.y = min(min_v.y, v.y); max_v.y = max(max_v.y, v.y)
				min_v.z = min(min_v.z, v.z); max_v.z = max(max_v.z, v.z)
		m.frames.append(verts)
	if m.frames.is_empty(): return null
	m.vertices = m.frames[0]
	m.frame_count = m.frames.size()
	m.aabb = AABB(min_v, max_v - min_v)

	# --- faces — start at the header's face-array offset ---
	# The DOS face iterator (FUN_0014ff0e) reads exactly face_count
	# records, advancing by `8 + vert_count*8` each time, with NO upper
	# bound on vert_count (it is a u8). A big floor/ceiling polygon can
	# easily have >8 vertices. The old `vc > 8` cap plus `break`-on-anomaly
	# truncated the face list — dropping a model's floor/back faces and
	# everything after them. Now: advance by the real stride every time,
	# skip only the offending face, never abandon the rest.
	var fe: int = size
	var off: int = faces_off
	var vert_div: int = face_vertex_divisor(bytes)
	for fi in face_count:
		if off + 8 > fe: break
		var vc: int = bytes[off]
		var ty: int = _u16(bytes, off + 2)
		var stride: int = 8 + vc * 8
		if off + stride > fe: break          # truncated record — stop

		if vc >= 3:
			var f := Face.new()
			f.vert_count = vc
			f.type = ty
			f.idx = PackedInt32Array()
			f.du  = PackedInt32Array()
			f.dv  = PackedInt32Array()
			f.idx.resize(vc); f.du.resize(vc); f.dv.resize(vc)

			var ok := true
			for vi in vc:
				var vb: int = _u32(bytes, off + 8 + vi * 8)
				var idx: int = int(vb / vert_div)
				if idx < 0 or idx >= vert_count:
					ok = false
					break
				f.idx[vi] = idx
				var du: int = _s16(bytes, off + 8 + vi * 8 + 4)
				var dv: int = _s16(bytes, off + 8 + vi * 8 + 6)
				if vi < 3:
					du = uv_unpack(du)
					dv = uv_unpack(dv)
				f.du[vi] = du
				f.dv[vi] = dv
			if ok:
				m.faces.append(f)

		off += stride                        # advance regardless of skip
	return m

## Build a textured ArrayMesh with one surface per unique face.type.
## `provider` is a Callable(archive_id: int, record_id: int) returning a
## Dictionary {"texture": ImageTexture, "size": Vector2i} (size = actual
## texture pixel dimensions, used for UV normalisation). Either field may
## be missing/null — face will fall back to a per-type colour material.
static func build_textured_array_mesh(m: Mesh3D, provider: Callable,
		frame: int = 0) -> ArrayMesh:
	if m == null or m.vertices.is_empty() or m.faces.is_empty():
		return null

	# Which animation frame's vertex positions to use (faces/UVs are shared).
	var verts: PackedVector3Array = m.vertices
	if frame > 0 and frame < m.frames.size():
		verts = m.frames[frame]

	var groups: Dictionary = {}
	for f in m.faces:
		if not groups.has(f.type):
			groups[f.type] = []
		groups[f.type].append(f)

	var am := ArrayMesh.new()
	for type_id in groups.keys():
		var arch: int = type_id >> 7
		var rec: int  = type_id & 0x7F
		var info: Dictionary = provider.call(arch, rec)
		var tex: Texture2D = info.get("texture", null)
		var tex_size: Vector2i = info.get("size", Vector2i(64, 64))
		if tex_size.x <= 0: tex_size.x = 64
		if tex_size.y <= 0: tex_size.y = 64
		# Daggerfall textureDivisor=16: DU/DV are in 1/16-pixel units.
		var divisor_x: float = float(tex_size.x * 16)
		var divisor_y: float = float(tex_size.y * 16)

		var positions := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()

		for f in groups[type_id]:
			# Points 0..2: stored as chained deltas. Decode them first.
			var u_abs: int = 0
			var v_abs: int = 0
			var face_uv := PackedVector2Array()
			face_uv.resize(f.vert_count)
			for k in mini(f.vert_count, 3):
				if k == 0:
					u_abs = f.du[0]
					v_abs = f.dv[0]
				else:
					u_abs += f.du[k]
					v_abs += f.dv[k]
				face_uv[k] = Vector2(u_abs / divisor_x, v_abs / divisor_y)

			var a := verts[f.idx[0]]
			var b := verts[f.idx[1]]
			var c := verts[f.idx[2]] if f.vert_count >= 3 else a
			# Outward normal = visible side (see the winding note above).
			var n := (b - a).cross(c - a).normalized()

			# Points 3..N: stored values are ignored — extend the affine UV map
			# (a, b, c -> uv[0], uv[1], uv[2]) to all coplanar vertices via
			# barycentric coordinates. Matches Daggerfall Unity FaceUVTool.
			if f.vert_count > 3:
				var v0: Vector3 = b - a
				var v1: Vector3 = c - a
				var d00: float = v0.dot(v0)
				var d01: float = v0.dot(v1)
				var d11: float = v1.dot(v1)
				var denom: float = d00 * d11 - d01 * d01
				var uv_a: Vector2 = face_uv[0]
				var uv_ab: Vector2 = face_uv[1] - uv_a
				var uv_ac: Vector2 = face_uv[2] - uv_a
				for k in range(3, f.vert_count):
					if absf(denom) < 1e-9:
						face_uv[k] = uv_a
						continue
					var v2: Vector3 = verts[f.idx[k]] - a
					var d20: float = v2.dot(v0)
					var d21: float = v2.dot(v1)
					var s: float = (d11 * d20 - d01 * d21) / denom
					var t: float = (d00 * d21 - d01 * d20) / denom
					face_uv[k] = uv_a + uv_ab * s + uv_ac * t

			# Fan (0, k+1, k): reversed so the DOS-visible (CCW) side is
			# Godot's clockwise front face; back faces are culled like DOS.
			for k in range(1, f.vert_count - 1):
				for vi in [0, k + 1, k]:
					positions.append(verts[f.idx[vi]])
					normals.append(n)
					uvs.append(face_uv[vi])

		if positions.is_empty(): continue

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs

		var mat := StandardMaterial3D.new()
		mat.cull_mode = BaseMaterial3D.CULL_BACK
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		# Unshaded: DOS models carry no lighting; interiors swap this to
		# per-vertex shading at load time (main.gd _shade_recursive).
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if tex:
			mat.albedo_texture = tex
		else:
			mat.albedo_color = Color.from_hsv(float(type_id & 0xFF) / 255.0, 0.5, 0.85)

		var surf_idx: int = am.get_surface_count()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.surface_set_material(surf_idx, mat)
	return am

## Build one textured ArrayMesh per animation frame. For a static mesh
## this returns a single-element array. Used for animated enemies — the
## caller swaps MeshInstance3D.mesh through the frames over time.
static func build_frame_meshes(m: Mesh3D, provider: Callable) -> Array:
	var out: Array = []
	if m == null or m.frames.is_empty():
		return out
	for fi in m.frames.size():
		var am := build_textured_array_mesh(m, provider, fi)
		if am != null:
			out.append(am)
	return out

## Build an ArrayMesh from parsed faces. Triangulates fans (vertex 0
## anchors every triangle of a face). Each face gets a separate surface
## so we can assign per-face textures later — but for now we collapse
## all faces into a single surface with vertex colors derived from
## face.type for diagnostic purposes.
##
## If `material` is provided, applies it as the single surface material.
static func build_array_mesh(m: Mesh3D, material: Material = null) -> ArrayMesh:
	if m == null or m.vertices.is_empty() or m.faces.is_empty():
		return null

	# Group faces by texture id so we can split surfaces by texture later.
	# For now, single surface with per-vertex colors based on face type.
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()

	for f in m.faces:
		# Accumulate cumulative UVs.
		var u_acc: int = 0
		var v_acc: int = 0
		var face_uv := PackedVector2Array()
		face_uv.resize(f.vert_count)
		for k in f.vert_count:
			u_acc += f.du[k]
			v_acc += f.dv[k]
			# Daggerfall textureDivisor=16. UV in [0,1]: u_acc / (W*16).
			# Without knowing texture W/H here, store unscaled — final
			# scaling can be done in shader or post-process. As a
			# placeholder use a generic 64-pixel divisor.
			face_uv[k] = Vector2(u_acc, v_acc) / 1024.0

		# Compute a per-face normal from the first 3 verts.
		var a := m.vertices[f.idx[0]]
		var b := m.vertices[f.idx[1]]
		var c := m.vertices[f.idx[2]]
		var n := (b - a).cross(c - a).normalized()

		# Per-face color derived from texture type so different surfaces
		# show different shades during debugging.
		var hue := float(f.type & 0xFF) / 255.0
		var col := Color.from_hsv(hue, 0.5, 0.85)

		# Triangulate as a fan: (0, k+1, k) — DOS CCW front -> Godot CW front.
		for k in range(1, f.vert_count - 1):
			for vi in [0, k + 1, k]:
				positions.append(m.vertices[f.idx[vi]])
				normals.append(n)
				uvs.append(face_uv[vi])
				colors.append(col)

	if positions.is_empty():
		return null

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR]  = colors

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material:
		am.surface_set_material(0, material)
	return am
