## A brief shot tracer — a thin glowing beam from muzzle to impact that
## fades out over a fraction of a second and frees itself.

extends MeshInstance3D

const LIFETIME: float = 0.11
const WIDTH: float = 16.0

var _life: float = LIFETIME
var _mat: StandardMaterial3D = null

## Orient the beam from `from` to `to`. Call after adding to the tree.
## `width` is the beam's thickness in world units — the player's own
## tracers are thin so they do not blot out what they are aimed at.
func setup(from: Vector3, to: Vector3, col: Color, width: float = WIDTH) -> void:
	var seg := to - from
	var length := maxf(seg.length(), 1.0)
	var bm := BoxMesh.new()
	bm.size = Vector3(width, width, length)
	mesh = bm
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.albedo_color = col
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	global_position = (from + to) * 0.5
	if length > 2.0 and absf(seg.normalized().dot(Vector3.UP)) < 0.99:
		look_at(to, Vector3.UP)

func _process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	if _mat != null:
		_mat.albedo_color.a = _life / LIFETIME
