## The TACTICAL tab of the mission screen (DOS FUN_0012c300, mode flag
## DAT_0004f633): an enemy-recognition database, not a map.
##
## The mission's briefing script lists the dossiers in its [TA] section
## (MAP.210: tachkftr, tacscout, taccmbrf, tacraptr, tacglobe, tacturls,
## tactruck). For each the DOS engine loads <name>.3D from MDMDOBJS.BSA
## and <name>.TXT from MDMDBRIF.BSA, spins the model on the spot over the
## TACTBAK.IMG backdrop and prints the text underneath; clicking the
## picture steps to the next unit.
##
## Here the model lives in a SubViewport so it can be dropped straight
## into the briefing overlay's picture slot.

extends SubViewportContainer

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

## DOS spins by (dt * 0xC0) >> 16 of 2048 units per second ≈ 34 deg/s.
const SPIN_DEG: float = 34.0

var names: Array = []
var index: int = 0

var _vp: SubViewport = null
var _pivot: Node3D = null
var _model: MeshInstance3D = null
var _cam: Camera3D = null
var _texts: Dictionary = {}          # name -> dossier text

signal changed()

func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	add_child(_vp)
	var world := Node3D.new()
	_vp.add_child(world)
	# The spin has to be about the model's own centre, so the pivot turns
	# and the mesh hangs off it by -centre (rotating the mesh node itself
	# would swing it around a corner of its bounding box).
	_pivot = Node3D.new()
	world.add_child(_pivot)
	_model = MeshInstance3D.new()
	_pivot.add_child(_model)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35.0, 140.0, 0.0)
	key.light_energy = 1.6
	world.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10.0, -40.0, 0.0)
	fill.light_energy = 0.5
	world.add_child(fill)
	_cam = Camera3D.new()
	_cam.fov = 45.0
	_cam.near = 1.0
	_cam.far = 100000.0
	world.add_child(_cam)
	_cam.current = true
	_load_current()

## `list` is the [TA] section of the mission's briefing script.
func setup(list: Array) -> void:
	names = list.duplicate()
	index = 0
	if _model != null:
		_load_current()

func step(dir: int) -> void:
	if names.is_empty():
		return
	index = posmod(index + dir, names.size())
	_load_current()
	changed.emit()

## Name of the unit on screen, e.g. "TACSCOUT" → "SCOUT".
func unit_name() -> String:
	if names.is_empty():
		return ""
	var n: String = String(names[index]).to_upper()
	return n.trim_prefix("TAC")

## The dossier text for the unit on screen.
func text() -> String:
	if names.is_empty():
		return "NO TACTICAL DATA FOR THIS MISSION."
	var key: String = String(names[index]).to_upper()
	if _texts.has(key):
		return String(_texts[key])
	var t := ""
	var bsa := BSAReader.new()
	if bsa.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"), SkynetPaths.variant):
		var raw := bsa.read(key + ".TXT")
		bsa.close()
		if not raw.is_empty():
			t = raw.get_string_from_ascii().strip_edges()
	if t.is_empty():
		t = "NO DOSSIER ON FILE."
	_texts[key] = t
	return t

func _load_current() -> void:
	if _model == null:
		return
	_model.mesh = null
	if names.is_empty():
		return
	var m: ArrayMesh = Assets.mesh(String(names[index]).to_upper() + ".3D")
	if m == null:
		return
	_model.mesh = m
	# Frame the model: DOS puts the camera at bound_radius * focal / 2^14;
	# the same idea, from the mesh's own extent.
	var aabb: AABB = m.get_aabb()
	var radius: float = maxf(aabb.size.length() * 0.5, 1.0)
	_model.position = -aabb.get_center()
	var dist: float = radius / tan(deg_to_rad(_cam.fov * 0.5)) * 0.95
	_cam.position = Vector3(0.0, radius * 0.30, dist)
	_cam.look_at(Vector3.ZERO, Vector3.UP)

func _process(delta: float) -> void:
	if _pivot != null and _model != null and _model.mesh != null:
		_pivot.rotation.y = wrapf(_pivot.rotation.y + deg_to_rad(SPIN_DEG) * delta, -PI, PI)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			step(1)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			step(-1)
			accept_event()
