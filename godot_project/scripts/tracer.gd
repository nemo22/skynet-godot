## A brief shot tracer — a thin glowing beam from muzzle to impact that
## fades out over a fraction of a second, then waits in a small pool for
## the next shot (or frees itself when the pool is full).
##
## Every tracer draws one shared unit box, stretched by the node's scale,
## with a material shared per colour and fade level: a shot used to build
## its own BoxMesh and StandardMaterial3D.

extends MeshInstance3D

const LIFETIME: float = 0.07
const WIDTH: float = 16.0
## Alpha levels of the fade. The beam lives four frames at 60 Hz; sixteen
## levels are finer than it can show, and each is one material per colour.
## (GeometryInstance3D.transparency would need no levels, but only
## Forward+ honours it — the mobile renderer would never fade.)
const FADE_STEPS: int = 16
const POOL_MAX: int = 24

static var _box: BoxMesh = null
static var _mats: Dictionary = {}        # rgb24 << 8 | fade step → material
static var _pool: Array = []

var _life: float = LIFETIME
var _rgb: Color = Color.WHITE
var _step: int = -1

## The shared unit box every tracer draws.
static func unit_box() -> BoxMesh:
	if _box == null:
		_box = BoxMesh.new()
		_box.size = Vector3.ONE
	return _box

## The beam material for colour `col` (its alpha ignored) at fade level
## `step` of FADE_STEPS.
static func beam_material(col: Color, step: int) -> StandardMaterial3D:
	var key: int = ((col.to_rgba32() >> 8) << 8) | step
	var m: StandardMaterial3D = _mats.get(key)
	if m == null:
		m = StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.albedo_color = Color(col.r, col.g, col.b, float(step) / float(FADE_STEPS))
		_mats[key] = m
	return m

## A tracer under `parent`, reusing a finished one when there is one.
## Same arguments as setup().
static func spawn(parent: Node, from: Vector3, to: Vector3, col: Color,
		width: float = WIDTH) -> MeshInstance3D:
	if parent == null:
		return null
	var tr = null                              # this script's instance
	while tr == null and not _pool.is_empty():
		var c = _pool.pop_back()
		if is_instance_valid(c) and not (c as Node).is_queued_for_deletion():
			tr = c
	if tr == null:
		tr = load("res://scripts/tracer.gd").new()
	if tr.get_parent() != parent:
		if tr.get_parent() != null:
			tr.get_parent().remove_child(tr)
		parent.add_child(tr)
	tr.setup(from, to, col, width)
	return tr

## Orient the beam from `from` to `to`. Call after adding to the tree.
## `width` is the beam's thickness in world units — the player's own
## tracers are thin so they do not blot out what they are aimed at.
func setup(from: Vector3, to: Vector3, col: Color, width: float = WIDTH) -> void:
	var seg := to - from
	var length := maxf(seg.length(), 1.0)
	mesh = unit_box()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_life = LIFETIME
	_rgb = col
	_step = -1
	_fade(col.a)
	var b := Basis()
	if length > 2.0 and absf(seg.normalized().dot(Vector3.UP)) < 0.99:
		b = Basis.looking_at(seg, Vector3.UP)
	# The box's own size was (width, width, length); the unit box is
	# stretched along the same local axes instead.
	global_transform = Transform3D(
		Basis(b.x * width, b.y * width, b.z * length), (from + to) * 0.5)
	visible = true
	set_process(true)

func _fade(alpha: float) -> void:
	var step: int = clampi(roundi(alpha * FADE_STEPS), 0, FADE_STEPS)
	if step != _step:
		_step = step
		material_override = beam_material(_rgb, step)

func _process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		_finish()
		return
	_fade(_life / LIFETIME)

## Done: hide and wait in the pool for spawn(), or free when it is full.
func _finish() -> void:
	set_process(false)
	if is_inside_tree() and _pool.size() < POOL_MAX and not _pool.has(self):
		visible = false
		_pool.append(self)
	else:
		queue_free()
