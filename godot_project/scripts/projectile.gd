## A visible, dodgeable straight-flying projectile — the DOS ammo-type
## family whose per-tick callback is 0x000f344d (Skynet.exe ammo table at
## VA 0x40728, stride 0x32): rockets, laser bolts and plasma bolts. Each
## record names its .3D model at +0x04 (+0x30000 → "rocket.3d",
## "laser1.3d", "laser2.3d", "laser3.3d" at VA 0x40c0a..), its fire
## sound at +0x1c, damage at +0x0c, blast radius at +0x10 and its impact
## effect sprite bank at +0x08. The model is loaded from MDMDENMS.BSA
## with its real textures; a glowing sphere stands in when it is missing.
##
## Raycasts its path every physics step so it never tunnels through thin
## geometry. On impact it deals direct (no splash) or radial (splash)
## damage, spawns the impact effect and frees itself.
##
## setup() `cfg` keys:
##   model         ".3D" name in MDMDENMS.BSA ("" → sphere)
##   color         tint for the sphere, light and trail
##   speed         world units per second
##   life          seconds before it fizzles (DOS ammo +0x18 ticks)
##   splash        blast radius (0 = direct hit only)
##   hits          "enemy" (player shot) or "player" (enemy shot)
##   trail         smoke puffs along the flight (rockets)
##   light         OmniLight3D while flying
##   impact_bank   TEXTURE.NNN effect bank for the impact (0 = none)
##   impact_sound  .RAW played at the impact ("" = none)
##   radius        sphere radius when there is no model

extends Node3D

const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D       := preload("res://scripts/loaders/mesh_3d.gd")
const Palette      := preload("res://scripts/loaders/palette.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")
const SmokePuff    := preload("res://scripts/smoke_puff.gd")
const Explosion    := preload("res://scripts/explosion.gd")

## .3D name → ArrayMesh, or false when the load failed (never retried).
static var _mesh_cache: Dictionary = {}

var _dir: Vector3 = Vector3.FORWARD
var _speed: float = 3000.0
var _life: float = 5.0
var _damage: float = 0.0
var _splash: float = 0.0
var _hits: String = "enemy"
var _trail: bool = false
var _trail_t: float = 0.0
var _impact_bank: int = 0
var _impact_sound: String = ""
var _color: Color = Color(1.0, 0.75, 0.4)
var _owner: Node = null
var _mi: MeshInstance3D = null
var _light: OmniLight3D = null
var _done: bool = false
## Hitboxes of actors this bolt passes through (the shooter, allies).
var _ignore: Array[RID] = []

## Load a projectile model with its textures (shared by every shot).
static func _model_mesh(name: String) -> ArrayMesh:
	var key := name.to_upper()
	if _mesh_cache.has(key):
		return _mesh_cache[key] if _mesh_cache[key] is ArrayMesh else null
	_mesh_cache[key] = false
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"),
			SkynetPaths.variant):
		return null
	var pal_bytes := imgs.read("SKYNET.COL")
	imgs.close()
	var palette := Palette.parse(pal_bytes)
	var enms := BSAReader.new()
	if not enms.open(SkynetPaths.gamedata_path("MDMDENMS.BSA"),
			SkynetPaths.variant):
		return null
	var bytes := enms.read(key)
	enms.close()
	if bytes.is_empty() or palette.is_empty():
		return null
	var parsed: Mesh3D.Mesh3D = Mesh3D.parse(bytes, key)
	if parsed == null:
		return null
	var tex_cache := TextureCache.new(palette, SkynetPaths.gamedata_dir)
	var am := Mesh3D.build_textured_array_mesh(
		parsed, Callable(tex_cache, "provide"))
	if am != null:
		_mesh_cache[key] = am
	return am

## Launch from `from` heading `dir`. `shooter` is never damaged by its
## own shot and its hitbox is flown through.
func setup(from: Vector3, dir: Vector3, damage: float, cfg: Dictionary,
		shooter: Node) -> void:
	global_position = from
	_dir = dir.normalized()
	_damage = damage
	_owner = shooter
	add_to_group("projectile")               # cleared on a map change
	_speed = float(cfg.get("speed", 3000.0))
	_life = float(cfg.get("life", 5.0))
	_splash = float(cfg.get("splash", 0.0))
	_hits = String(cfg.get("hits", "enemy"))
	_trail = bool(cfg.get("trail", false))
	_impact_bank = int(cfg.get("impact_bank", 0))
	_impact_sound = String(cfg.get("impact_sound", ""))
	_color = cfg.get("color", _color)

	_mi = MeshInstance3D.new()
	var model_name: String = String(cfg.get("model", ""))
	var am: ArrayMesh = null
	if not model_name.is_empty():
		am = _model_mesh(model_name)
	if am != null:
		_mi.mesh = am
		# The .3D missiles are authored nose-forward along the axis the
		# (x,-y,-z) conversion maps to Godot -Z, which looking_at aims.
		var up := Vector3.UP if absf(_dir.y) < 0.99 else Vector3.RIGHT
		_mi.basis = Basis.looking_at(_dir, up)
	else:
		var sm := SphereMesh.new()
		var r: float = float(cfg.get("radius", 18.0))
		sm.radius = r
		sm.height = r * 2.0
		_mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = _color
		_mi.material_override = mat
	add_child(_mi)

	if bool(cfg.get("light", false)):
		_light = OmniLight3D.new()
		_light.light_color = _color
		_light.light_energy = 2.0
		_light.omni_range = maxf(_splash, 300.0)
		add_child(_light)

func _physics_process(delta: float) -> void:
	if _done:
		return
	# The shooter may die (and be freed) while its bolt is still flying.
	if _owner != null and not is_instance_valid(_owner):
		_owner = null
	_life -= delta
	if _life <= 0.0:
		_finish(global_position, false)
		return
	if _trail:
		_trail_t -= delta
		if _trail_t <= 0.0:
			_trail_t = 0.03
			var sm := SmokePuff.new()
			get_tree().current_scene.add_child(sm)
			sm.setup(global_position, 70.0)

	var to := global_position + _dir * _speed * delta
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position, to)
	q.collide_with_areas = true                # actor hitboxes are Area3D
	q.exclude = _ignore.duplicate()
	if _owner is CollisionObject3D:
		q.exclude.append((_owner as CollisionObject3D).get_rid())
	var hit := space.intersect_ray(q)
	if not hit.has("position"):
		global_position = to
		return

	# Resolve the damageable actor behind the collider, if any.
	var collider: Object = hit.get("collider") as Object
	var n: Node = collider as Node
	while n != null and not n.has_method("take_damage"):
		n = n.get_parent()
	if n != null:
		if n == _owner or not _is_target(n):
			# The shooter or an ally — fly straight through.
			if collider is CollisionObject3D:
				_ignore.append((collider as CollisionObject3D).get_rid())
			global_position = hit["position"] + _dir * 2.0
			return
		if _splash <= 0.0:
			n.take_damage(_damage)
		_finish(hit["position"], true)
		return
	_finish(hit["position"], true)               # solid geometry

## Enemy shots hurt the player, player shots hurt enemies.
func _is_target(n: Node) -> bool:
	if _hits == "player":
		return n.is_in_group("player")
	return n.is_in_group("enemy")

## Impact: splash damage (when the type has a blast radius), the impact
## effect and sound, then free. A fizzled shot (lifetime over) just
## disappears.
func _finish(at: Vector3, impact: bool) -> void:
	_done = true
	global_position = at
	if impact and _splash > 0.0:
		if _hits == "enemy":
			for e in get_tree().get_nodes_in_group("enemy"):
				if e is Node3D and e.has_method("take_damage") and e != _owner:
					var d := (e as Node3D).global_position.distance_to(at)
					if d < _splash:
						e.take_damage(_damage * (1.0 - d / _splash))
		# Destructible map objects (cars, generators …) take blast damage
		# from anyone's explosion — DOS ObjHit runs for every object in
		# the radius.
		for h in get_tree().get_nodes_in_group("hittable"):
			if h is Node3D and h.has_method("take_damage"):
				var dh := (h as Node3D).global_position.distance_to(at)
				if dh < _splash:
					h.take_damage(_damage * (1.0 - dh / _splash))
		var pl := get_tree().get_first_node_in_group("player")
		if pl is Node3D and pl != _owner and pl.has_method("take_damage"):
			var d := (pl as Node3D).global_position.distance_to(at)
			if d < _splash:
				pl.take_damage(_damage * 0.55 * (1.0 - d / _splash))
	if impact:
		if not _impact_sound.is_empty():
			Audio.play_sfx_3d(_impact_sound, at, -2.0)
		if _impact_bank > 0:
			var scene := get_tree().current_scene
			if scene != null:
				var ex := Explosion.new()
				scene.add_child(ex)
				ex.setup(at, maxf(_splash * 0.6, 45.0), _impact_bank)
	queue_free()
