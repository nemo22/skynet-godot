## .3D object viewer.
## Browse every .3D mesh in MDMDOBJS.BSA. Left/Right = step,
## PageUp/Down = jump 10, mouse-drag = orbit, wheel = zoom.

extends Node3D

const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D       := preload("res://scripts/loaders/mesh_3d.gd")
const Palette      := preload("res://scripts/loaders/palette.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")

@onready var pivot: Node3D    = $Pivot
@onready var camera: Camera3D = $Pivot/Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var status: Label    = $UI/Status
@onready var help:   Label    = $UI/Help

var _objs: BSAReader
var _names: PackedStringArray
var _cache: TextureCache
var _idx: int = 0
var _instance: MeshInstance3D

# Orbit camera state.
var _yaw: float   = 0.0
var _pitch: float = -0.2
var _dist: float  = 5.0
var _dragging: bool = false

func _ready() -> void:
	# Palette
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
		status.text = "ERROR opening MDMDIMGS.BSA"; return
	var pal_bytes := SkynetPaths.palette_bytes()
	imgs.close()
	var pal := Palette.parse(pal_bytes)
	if pal.is_empty():
		status.text = "ERROR loading palette"; return
	_cache = TextureCache.new(pal, SkynetPaths.gamedata_dir)

	# MDMDOBJS.BSA — list every .3D
	_objs = BSAReader.new()
	if not _objs.open(SkynetPaths.gamedata_path("MDMDOBJS.BSA"), SkynetPaths.variant):
		status.text = "ERROR opening MDMDOBJS.BSA"; return
	_names = PackedStringArray()
	for e in _objs.entries():
		if e.name.ends_with(".3D"):
			_names.append(e.name)
	_names.sort()
	print("[objview] %d .3D meshes available" % _names.size())
	help.text = "← → step    PgUp/PgDn ±10    drag = orbit    wheel = zoom"

	_show(0)

func _exit_tree() -> void:
	if _objs:
		_objs.close()

func _show(i: int) -> void:
	if _names.is_empty(): return
	_idx = (i + _names.size()) % _names.size()
	var name: String = _names[_idx]
	var bytes := _objs.read(name)
	var parsed: Mesh3D.Mesh3D = Mesh3D.parse(bytes, name)
	if _instance:
		_instance.queue_free()
		_instance = null
	if parsed == null:
		status.text = "[%d/%d] %s — parse FAILED" % [_idx + 1, _names.size(), name]
		return
	var am := Mesh3D.build_textured_array_mesh(parsed, Callable(_cache, "provide"))
	if am == null:
		status.text = "[%d/%d] %s — build FAILED" % [_idx + 1, _names.size(), name]
		return
	_instance = MeshInstance3D.new()
	_instance.mesh = am
	# Centre the mesh on the pivot.
	_instance.position = -parsed.aabb.get_center()
	add_child(_instance)

	# Frame camera around AABB.
	var radius: float = parsed.aabb.size.length() * 0.5
	if radius <= 0.0: radius = 1.0
	_dist = radius * 2.5
	_apply_camera()
	status.text = "[%d/%d] %s   verts=%d faces=%d surfaces=%d   size=%.1fx%.1fx%.1f" % [
		_idx + 1, _names.size(), name,
		parsed.vertices.size(), parsed.faces.size(), am.get_surface_count(),
		parsed.aabb.size.x, parsed.aabb.size.y, parsed.aabb.size.z]
	print("[objview] %s" % status.text)

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
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_dist = max(_dist * 0.9, 0.5)
			_apply_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_dist = min(_dist * 1.1, 100000.0)
			_apply_camera()
	elif event is InputEventMouseMotion and _dragging:
		_yaw   -= event.relative.x * 0.01
		_pitch -= event.relative.y * 0.01
		_pitch = clamp(_pitch, -1.55, 1.55)
		_apply_camera()
