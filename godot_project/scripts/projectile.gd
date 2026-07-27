## A visible, dodgeable projectile (rocket). Flies straight, raycasts its
## path each physics step so it can never tunnel through thin geometry,
## and on impact deals splash damage with an expanding explosion flash.

extends Node3D

const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D       := preload("res://scripts/loaders/mesh_3d.gd")
const Palette      := preload("res://scripts/loaders/palette.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")

const SPEED: float = 3000.0
const LIFETIME: float = 5.0
const FLASH_TIME: float = 0.24

## Lazily-loaded ROCKET.3D (MDMDOBJS.BSA) shared by every projectile;
## `false` marks a failed load so we don't retry each shot.
static var _rocket_cache: Variant = null

var _dir: Vector3 = Vector3.FORWARD
var _damage: float = 95.0
var _splash: float = 750.0
var _life: float = LIFETIME
var _owner: Node = null
var _mi: MeshInstance3D = null
var _mat: StandardMaterial3D = null
var _exploding: bool = false
var _flash_t: float = 0.0

static func _rocket_mesh() -> ArrayMesh:
	if _rocket_cache != null:
		return _rocket_cache if _rocket_cache is ArrayMesh else null
	_rocket_cache = false
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"),
			SkynetPaths.variant):
		return null
	var pal_bytes := imgs.read("SKYNET.COL")
	imgs.close()
	var palette := Palette.parse(pal_bytes)
	# ROCKET.3D (and the LASERn.3D bolts) live in MDMDENMS.BSA.
	var objs := BSAReader.new()
	if not objs.open(SkynetPaths.gamedata_path("MDMDENMS.BSA"),
			SkynetPaths.variant):
		return null
	var bytes := objs.read("ROCKET.3D")
	objs.close()
	if bytes.is_empty() or palette.is_empty():
		return null
	var parsed: Mesh3D.Mesh3D = Mesh3D.parse(bytes, "ROCKET")
	if parsed == null:
		return null
	var tex_cache := TextureCache.new(palette, SkynetPaths.gamedata_dir)
	var am := Mesh3D.build_textured_array_mesh(
		parsed, Callable(tex_cache, "provide"))
	_rocket_cache = am if am != null else false
	return am

## Launch from `from` heading `dir`, dealing `damage` within `splash`
## units of the impact. `shooter` is excluded from the first ray step.
func setup(from: Vector3, dir: Vector3, damage: float, splash: float,
		shooter: Node) -> void:
	global_position = from
	_dir = dir.normalized()
	_damage = damage
	_splash = splash
	_owner = shooter
	_mi = MeshInstance3D.new()
	var rm := _rocket_mesh()
	if rm != null:
		_mi.mesh = rm
		# Point the rocket along its flight path. The .3D is authored
		# nose-forward along the same axis the (x,-y,-z) conversion maps
		# to Godot -Z; flip BACK↔FORWARD here if it flies tail-first.
		var up := Vector3.UP if absf(_dir.y) < 0.99 else Vector3.RIGHT
		_mi.basis = Basis.looking_at(_dir, up)
	else:
		# Fallback: the old orange tracer blob.
		var sm := SphereMesh.new()
		sm.radius = 20.0
		sm.height = 40.0
		_mi.mesh = sm
		var fmat := StandardMaterial3D.new()
		fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fmat.albedo_color = Color(1.0, 0.72, 0.28)
		_mi.material_override = fmat
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.albedo_color = Color(1.0, 0.72, 0.28)
	add_child(_mi)

func _physics_process(delta: float) -> void:
	if _exploding:
		_flash_t -= delta
		var k := 1.0 - _flash_t / FLASH_TIME
		_mi.scale = Vector3.ONE * (1.0 + k * 9.0)
		_mat.albedo_color.a = clampf(_flash_t / FLASH_TIME, 0.0, 1.0)
		if _flash_t <= 0.0:
			queue_free()
		return

	_life -= delta
	if _life <= 0.0:
		_explode(global_position)
		return
	var to := global_position + _dir * SPEED * delta
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position, to)
	q.collide_with_areas = true                # enemy hitboxes are Area3D
	if _owner is CollisionObject3D:
		q.exclude = [(_owner as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(q)
	if hit.has("position"):
		_explode(hit["position"])
	else:
		global_position = to

## Detonate: splash-damage every actor in range, then become a flash.
func _explode(at: Vector3) -> void:
	global_position = at
	Audio.play_sfx_3d("EXPLO1.RAW", at, -1.0)
	for e in get_tree().get_nodes_in_group("enemy"):
		if e is Node3D and e.has_method("take_damage"):
			var d := (e as Node3D).global_position.distance_to(at)
			if d < _splash:
				e.take_damage(_damage * (1.0 - d / _splash))
	var pl := get_tree().get_first_node_in_group("player")
	if pl is Node3D and pl != _owner and pl.has_method("take_damage"):
		var d := (pl as Node3D).global_position.distance_to(at)
		if d < _splash:
			pl.take_damage(_damage * 0.55 * (1.0 - d / _splash))
	_exploding = true
	_flash_t = FLASH_TIME
	# Swap the rocket mesh for the expanding flash sphere.
	var sm := SphereMesh.new()
	sm.radius = 20.0
	sm.height = 40.0
	_mi.mesh = sm
	_mi.basis = Basis()
	_mi.material_override = _mat
	_mat.albedo_color = Color(1.0, 0.55, 0.2, 1.0)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
