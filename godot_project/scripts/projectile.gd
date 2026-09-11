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
##   color         tint for the sphere and the halo
##   speed         world units per second
##   life          seconds before it fizzles (DOS ammo +0x18 ticks)
##   splash        blast radius (0 = direct hit only)
##   hits          "enemy" (player shot) or "player" (enemy shot)
##   trail         a motor glow at the tail (rockets). DOS leaves no smoke
##                 while a rocket flies (skynet_gh.c:25860-25970); its one
##                 effect is at the impact.
##   impact_bank   TEXTURE.NNN effect bank for the impact (0 = none)
##   impact_sound  .RAW played at the impact ("" = none)
##   radius        sphere radius when there is no model

extends Node3D

const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D       := preload("res://scripts/loaders/mesh_3d.gd")
const Palette      := preload("res://scripts/loaders/palette.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")
const Explosion    := preload("res://scripts/explosion.gd")

## .3D name → ArrayMesh, or false when the load failed (never retried).
static var _mesh_cache: Dictionary = {}
## The soft round sprite of the halos (_soft_dot), built once.
static var _dot: Texture2D = null
## How much wider a laser bolt is drawn than its 3x7 u model (see setup).
const BOLT_FATTEN: float = 2.0
## Halo diameter as a fraction of the bolt's length.
const GLOW_SCALE: float = 0.24
## A 120-unit bolt passing a metre from the lens fills a quarter of the
## screen with a solid wedge — which is what the jeep's plasma looked
## like (2026-09-04). Nothing is drawn until it is this far from the
## camera; by then it is small enough to read as a bolt.
const NEAR_CLIP: float = 320.0
## The rocket motor's glow, world units across.
const EXHAUST_SIZE: float = 90.0

var _dir: Vector3 = Vector3.FORWARD
## True when the model's body sits on +Z (the laser bolts) rather
## than on -Z (the rockets).
var _body_forward: bool = false
var _is_bolt: bool = false
var _speed: float = 3000.0
var _life: float = 5.0
var _damage: float = 0.0
var _splash: float = 0.0
var _hits: String = "enemy"
var _impact_bank: int = 0
var _impact_sound: String = ""
var _color: Color = Color(1.0, 0.75, 0.4)
var _owner: Node = null
var _mi: MeshInstance3D = null
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
	var pal_bytes := SkynetPaths.palette_bytes()
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
		# The .3D projectiles do NOT agree on which way they point.
		# ROCKET.3D carries its body at negative Z (nose forward, which is
		# what looking_at aims); LASER1/2/3.3D carry theirs at POSITIVE Z
		# (bounds z -8.7 .. +111.6). Aimed by the same rule both ways, the
		# bolt's 120 u blade trails backwards out of the muzzle, over the
		# cockpit — "výstrely sú renderované ako keby z boku". So ask the
		# model where its body is instead of assuming.
		_body_forward = am.get_aabb().get_center().z > 0.0
		_is_bolt = _model_is_bolt(model_name)
		_mi.basis = _bolt_basis(BOLT_FATTEN if _is_bolt else 1.0)
		# LASER1/2/3.3D are 120 u long but only 3x7 u thick. On a 320x200
		# DOS screen that was a bright hairline you could not miss; at a
		# modern resolution the same bolt is a sub-pixel thread, which is
		# why incoming fire read as "nothing visible at all" (2026-09-04).
		# Fatten the bolt and give it a halo instead of speeding it up.
		_add_glow(am.get_aabb().size.z)
		if not _is_bolt and bool(cfg.get("trail", false)):
			_add_exhaust(am.get_aabb())
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
	_mi.visible = false
	add_child(_mi)

## The soft halo that makes a bolt readable in flight. It must be a
## round FALLOFF, not a flat quad: the first cut had no texture, so a
## walker's laser read as "a blue semi-transparent square" (2026-09-04).
func _add_glow(length: float) -> void:
	var qm := QuadMesh.new()
	var d: float = maxf(length, 60.0) * GLOW_SCALE
	qm.size = Vector2(d, d)
	var g := MeshInstance3D.new()
	g.mesh = qm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = _soft_dot()
	m.albedo_color = Color(_color.r, _color.g, _color.b, 0.45)
	m.disable_receive_shadows = true
	g.material_override = m
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.visible = false
	add_child(g)

## The motor flame at a rocket's tail. ROCKET.3D is a dark 31 x 27 u
## body seen from behind at night, inside its own smoke: 25-45 px of
## black on black, so "nevidím samotnú raketu letieť" (2026-09-11) —
## the model was there, measured, just unreadable. A real rocket is
## seen by its motor; this is that, a hot additive dot at the tail.
func _add_exhaust(aabb: AABB) -> void:
	var qm := QuadMesh.new()
	qm.size = Vector2(EXHAUST_SIZE, EXHAUST_SIZE)
	var g := MeshInstance3D.new()
	g.mesh = qm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = _soft_dot()
	m.albedo_color = Color(1.0, 0.72, 0.36, 1.0)
	m.disable_receive_shadows = true
	g.material_override = m
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The tail is the model's end away from the nose (+Z for a rocket,
	# whose body is on -Z); the projectile node itself never rotates.
	var tail: float = -aabb.position.z if _body_forward else aabb.end.z
	g.position = -_dir * tail
	g.visible = false
	add_child(g)

## A 32x32 radial soft dot: bright in the middle, clear at the edge.
static func _soft_dot() -> Texture2D:
	if _dot != null:
		return _dot
	var n: int = 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d: float = Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	img.generate_mipmaps()
	_dot = ImageTexture.create_from_image(img)
	return _dot

## Where the bolt points, and which way its flat face is turned. A DOS
## bolt is a blade 3.4 u wide and 6.7 u tall: edge-on it is a hairline,
## so it is rolled about the flight axis to keep the wide face toward the
## camera, the way any engine draws a beam.
## `fatten` thickens the two thin axes of the bolt itself. NOT via
## Basis.scaled(): in Godot 4 that scales along the WORLD axes, so a
## bolt flying along world X was stretched sideways into a flat slab
## lying across the screen — the "výstrely sú ako keby z boku" Marek
## sent a picture of, reported four times, and not fixed by aiming it.
func _bolt_basis(fatten: float = 1.0) -> Basis:
	var body: Vector3 = _dir if _body_forward else -_dir
	var wide := Vector3.UP
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		var to_cam: Vector3 = global_position - cam.global_position
		var w: Vector3 = body.cross(to_cam)
		if w.length_squared() > 1.0e-6:
			wide = w.normalized()
	if absf(wide.dot(body)) > 0.99:
		wide = Vector3.RIGHT if absf(body.y) > 0.9 else Vector3.UP
	var z: Vector3 = body.normalized()
	var y: Vector3 = (wide - z * wide.dot(z)).normalized()
	return Basis(y.cross(z) * fatten, y * fatten, z)

static func _model_is_bolt(name: String) -> bool:
	return name.to_upper().begins_with("LASER")

func _physics_process(delta: float) -> void:
	if _done:
		return
	# The shooter may die (and be freed) while its bolt is still flying.
	# NOT `_owner != null and …`: in Godot 4 a freed instance compares
	# EQUAL to null, so that guard never fired, `_owner is …` below then
	# raised "Left operand of 'is' is a previously freed instance" on
	# every physics frame until the bolt landed — a stack trace per frame,
	# which is what made the game stutter after every kill.
	if not is_instance_valid(_owner):
		_owner = null
	_life -= delta
	if _life <= 0.0:
		_finish(global_position, false)
		return
	if _mi != null and not _mi.visible:
		var cam := get_viewport().get_camera_3d()
		if cam == null or cam.global_position.distance_to(global_position) > NEAR_CLIP:
			_mi.visible = true
			for c in get_children():
				if c is MeshInstance3D:
					(c as MeshInstance3D).visible = true

	if _is_bolt and _mi != null:
		# Re-roll every frame: the bolt has to keep its face to a camera
		# that is itself moving.
		_mi.basis = _bolt_basis(BOLT_FATTEN)
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
			_deal(n, _damage)
		_finish(hit["position"], true)
		return
	_finish(hit["position"], true)               # solid geometry

## Enemy shots hurt the player, player shots hurt enemies; in a
## deathmatch every other actor is fair game. "none" = a replicated
## visual of somebody else's shot — it stops on actors but hurts nobody.
func _is_target(n: Node) -> bool:
	if _hits == "none":
		return not n.is_in_group("dm_actor") and not n.is_in_group("player")
	if n.is_in_group("dm_actor"):
		return true
	if _hits == "player":
		return n.is_in_group("player")
	return n.is_in_group("enemy")

## Attributed damage for deathmatch actors, plain for everything else.
func _deal(n: Node, dmg: float) -> void:
	if _hits == "none":
		return
	if n.has_method("net_damage"):
		n.net_damage(dmg, _owner)
	else:
		n.take_damage(dmg)

## Impact: splash damage (when the type has a blast radius), the impact
## effect and sound, then free. A fizzled shot (lifetime over) just
## disappears.
func _finish(at: Vector3, impact: bool) -> void:
	_done = true
	global_position = at
	if impact and _splash > 0.0 and _hits != "none":
		for a in get_tree().get_nodes_in_group("dm_actor"):
			if a is Node3D and a != _owner and a.has_method("net_damage"):
				var da := (a as Node3D).global_position.distance_to(at)
				if da < _splash:
					a.net_damage(_damage * (1.0 - da / _splash), _owner)
		if _hits == "enemy":
			for e in get_tree().get_nodes_in_group("enemy"):
				if e is Node3D and e.has_method("take_damage") and e != _owner:
					var d: float = e.blast_distance(at) if e.has_method("blast_distance") 						else (e as Node3D).global_position.distance_to(at)
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
		if pl is Node3D and pl.has_method("take_damage"):
			var d := (pl as Node3D).global_position.distance_to(at)
			if d < _splash:
				if pl == _owner:
					pl.take_damage(_damage * 0.55 * (1.0 - d / _splash))   # own rocket
				elif _hits != "enemy" or pl.has_method("net_damage") and Net.active:
					pl.net_damage(_damage * 0.55 * (1.0 - d / _splash), _owner) if pl.has_method("net_damage") \
						else pl.take_damage(_damage * 0.55 * (1.0 - d / _splash))
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
