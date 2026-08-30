## Enemy mesh viewer. Browse MDMDENMS.BSA and cycle animation frames.
## Controls: arrows = step model, PgUp/PgDn ±10, Space toggles animation,
## [/] = prev/next frame manually, drag = orbit, wheel = zoom.

extends Node3D

const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D       := preload("res://scripts/loaders/mesh_3d.gd")
const Palette      := preload("res://scripts/loaders/palette.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")

const ANIM_FPS: float = 12.0

@onready var pivot:  Node3D            = $Pivot
@onready var camera: Camera3D          = $Pivot/Camera3D
@onready var sun:    DirectionalLight3D = $Sun
@onready var status: Label             = $UI/Status
@onready var help:   Label             = $UI/Help

var _bsa: BSAReader
var _names: PackedStringArray
var _cache: TextureCache
var _idx: int = 0
var _instance: MeshInstance3D
var _parsed: Mesh3D.Mesh3D
var _surfaces: Array = []   ## per-surface materials & face-groups for rebuilding
var _frame_idx: int = 0
var _anim_time: float = 0.0
var _anim_playing: bool = true

# Orbit camera state.
var _yaw: float   = 0.0
var _pitch: float = -0.2
var _dist: float  = 5.0
var _dragging: bool = false

func _ready() -> void:
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
		status.text = "ERROR opening MDMDIMGS.BSA"; return
	var pal_bytes := imgs.read("SKYNET.COL")
	if pal_bytes.is_empty(): pal_bytes = imgs.read("BRIEF.COL")
	imgs.close()
	_cache = TextureCache.new(Palette.parse(pal_bytes),
		SkynetPaths.gamedata_dir)

	_bsa = BSAReader.new()
	if not _bsa.open(SkynetPaths.gamedata_path("MDMDENMS.BSA"), SkynetPaths.variant):
		status.text = "ERROR opening MDMDENMS.BSA"; return
	_names = PackedStringArray()
	for e in _bsa.entries():
		if e.name.ends_with(".3D"):
			_names.append(e.name)
	_names.sort()
	print("[enemyview] %d enemy meshes" % _names.size())
	help.text = "← → step    PgUp/PgDn ±10    Space play/pause anim    [ ] frame step"
	_show(0)

func _exit_tree() -> void:
	if _bsa: _bsa.close()

func _process(delta: float) -> void:
	if _parsed == null or _parsed.frame_count <= 1 or not _anim_playing:
		return
	_anim_time += delta * ANIM_FPS
	var next_frame: int = int(_anim_time) % _parsed.frame_count
	if next_frame != _frame_idx:
		_frame_idx = next_frame
		_update_frame()

func _show(i: int) -> void:
	if _names.is_empty(): return
	_idx = (i + _names.size()) % _names.size()
	var name: String = _names[_idx]
	var bytes := _bsa.read(name)
	if _instance:
		_instance.queue_free()
		_instance = null
	_parsed = Mesh3D.parse(bytes, name)
	if _parsed == null:
		status.text = "[%d/%d] %s — parse FAILED" % [_idx + 1, _names.size(), name]
		print("[enemyview] %s" % status.text)
		return
	_frame_idx = 0
	_anim_time = 0.0
	_rebuild()

func _rebuild() -> void:
	# Group faces by texture id (per-surface arrays), build ArrayMesh.
	var groups: Dictionary = {}
	for f in _parsed.faces:
		if not groups.has(f.type):
			groups[f.type] = []
		groups[f.type].append(f)

	var am := ArrayMesh.new()
	var verts: PackedVector3Array = _parsed.frames[_frame_idx]
	for type_id in groups.keys():
		var arch: int = type_id >> 7
		var rec: int  = type_id & 0x7F
		var info: Dictionary = _cache.provide(arch, rec)
		var tex: Texture2D = info.get("texture", null)
		var tex_size: Vector2i = info.get("size", Vector2i(64, 64))
		var dx: float = float(max(tex_size.x, 1) * 16)
		var dy: float = float(max(tex_size.y, 1) * 16)

		var positions := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()

		for f in groups[type_id]:
			# Daggerfall UV math (chained deltas for first 3, barycentric extension after).
			var face_uv := PackedVector2Array()
			face_uv.resize(f.vert_count)
			var u_abs: int = 0
			var v_abs: int = 0
			for k in mini(f.vert_count, 3):
				if k == 0:
					u_abs = f.du[0]; v_abs = f.dv[0]
				else:
					u_abs += f.du[k]; v_abs += f.dv[k]
				face_uv[k] = Vector2(u_abs / dx, v_abs / dy)
			var a := verts[f.idx[0]]
			var b := verts[f.idx[1]] if f.vert_count >= 2 else a
			var c := verts[f.idx[2]] if f.vert_count >= 3 else a
			var n := (b - a).cross(c - a).normalized()   # visible side
			if f.vert_count > 3:
				var v0 := b - a
				var v1 := c - a
				var d00 := v0.dot(v0)
				var d01 := v0.dot(v1)
				var d11 := v1.dot(v1)
				var denom := d00 * d11 - d01 * d01
				var uv_ab := face_uv[1] - face_uv[0]
				var uv_ac := face_uv[2] - face_uv[0]
				for k in range(3, f.vert_count):
					if absf(denom) < 1e-9:
						face_uv[k] = face_uv[0]; continue
					var v2 := verts[f.idx[k]] - a
					var s := (d11 * v2.dot(v0) - d01 * v2.dot(v1)) / denom
					var t := (d00 * v2.dot(v1) - d01 * v2.dot(v0)) / denom
					face_uv[k] = face_uv[0] + uv_ab * s + uv_ac * t

			for k in range(1, f.vert_count - 1):
				for vi in [0, k + 1, k]:   # DOS CCW front -> Godot CW front
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
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if tex:
			mat.albedo_texture = tex
		else:
			mat.albedo_color = Color.from_hsv(float(type_id & 0xFF) / 255.0, 0.5, 0.85)
		var idx := am.get_surface_count()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.surface_set_material(idx, mat)

	if _instance:
		_instance.mesh = am
	else:
		_instance = MeshInstance3D.new()
		_instance.mesh = am
		add_child(_instance)
	# Center on first frame's AABB.
	_instance.position = -_parsed.aabb.get_center()

	var radius := _parsed.aabb.size.length() * 0.5
	if radius <= 0.0: radius = 1.0
	if _dist <= 0.5: _dist = radius * 2.5
	_apply_camera()

	status.text = "[%d/%d] %s   verts=%d faces=%d frames=%d  frame=%d  size=%.1fx%.1fx%.1f" % [
		_idx + 1, _names.size(), _parsed.name,
		_parsed.vertices.size(), _parsed.faces.size(), _parsed.frame_count,
		_frame_idx,
		_parsed.aabb.size.x, _parsed.aabb.size.y, _parsed.aabb.size.z]
	if _frame_idx == 0:
		print("[enemyview] %s" % status.text)

func _update_frame() -> void:
	# Only rebuild — texture cache and groupings are unchanged.
	_rebuild()

func _apply_camera() -> void:
	var basis_yaw   := Basis(Vector3.UP, _yaw)
	var basis_pitch := Basis(Vector3.RIGHT, _pitch)
	pivot.global_transform.basis = basis_yaw * basis_pitch
	camera.position = Vector3(0, 0, _dist)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT:     _show(_idx - 1)
			KEY_RIGHT:    _show(_idx + 1)
			KEY_PAGEUP:   _show(_idx - 10)
			KEY_PAGEDOWN: _show(_idx + 10)
			KEY_HOME:     _show(0)
			KEY_END:      _show(_names.size() - 1)
			KEY_SPACE:    _anim_playing = not _anim_playing
			KEY_BRACKETLEFT:
				if _parsed and _parsed.frame_count > 1:
					_anim_playing = false
					_frame_idx = (_frame_idx - 1 + _parsed.frame_count) % _parsed.frame_count
					_update_frame()
			KEY_BRACKETRIGHT:
				if _parsed and _parsed.frame_count > 1:
					_anim_playing = false
					_frame_idx = (_frame_idx + 1) % _parsed.frame_count
					_update_frame()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_dist = max(_dist * 0.9, 0.5); _apply_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_dist = min(_dist * 1.1, 100000.0); _apply_camera()
	elif event is InputEventMouseMotion and _dragging:
		_yaw   -= event.relative.x * 0.01
		_pitch -= event.relative.y * 0.01
		_pitch = clamp(_pitch, -1.55, 1.55)
		_apply_camera()
