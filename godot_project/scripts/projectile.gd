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

const Explosion    := preload("res://scripts/explosion.gd")

## .3D name → ArrayMesh, or false when the load failed (never retried).
static var _mesh_cache: Dictionary = {}
## The soft round sprite of the halos (soft_dot), built once.
static var _dot: Texture2D = null
## Shared halo quads (by size), halo/exhaust materials (by colour) and
## the fallback spheres: a shot used to build its own of each.
static var _quads: Dictionary = {}
static var _glow_mats: Dictionary = {}
static var _spheres: Dictionary = {}
static var _sphere_mats: Dictionary = {}
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
## The flight ray, built once; its exclude list is rebuilt only when
## _ignore grows.
var _q: PhysicsRayQueryParameters3D = null

## Load a projectile model with its textures (shared by every shot). The
## models live in MDMDENMS.BSA only; the asset cache builds them once
## (converted/mesh/) with the same texture provider the old direct load
## went through.
static func model_mesh(name: String) -> ArrayMesh:
	var key := name.to_upper()
	if _mesh_cache.has(key):
		return _mesh_cache[key] if _mesh_cache[key] is ArrayMesh else null
	var am: ArrayMesh = Assets.mesh(key)
	_mesh_cache[key] = am if am != null else false
	return am

## The bolt colours are MEASURED, not chosen: each LASERn.3D is a flat
## 120-unit blade whose whole surface is one 1x1 texture record in
## TEXTURE.001 — rec 4 for LASER1, 49 for LASER2, 83 for LASER3. Those
## three pixels are (51,219,219) cyan, (99,231,99) green and
## (235,51,51) red. The port had guessed LASER1 red and LASER2 blue,
## which is why the jeep's plasma (ammo type 18 = laser2.3d, ammo table
## 0x40828) came out blue instead of green.
const BOLT_COLOURS: Dictionary = {
	"LASER1.3D": Color(0.200, 0.859, 0.859),
	"LASER2.3D": Color(0.388, 0.906, 0.388),
	"LASER3.3D": Color(0.922, 0.200, 0.200),
}

## The colour a projectile model draws in, or `fallback` for a model
## that is not one of the bolts (ROCKET.3D and the rest).
static func colour_for(model: String, fallback: Color = Color(1.0, 0.75, 0.4)) -> Color:
	return BOLT_COLOURS.get(model.to_upper(), fallback)

## Launch from `from` heading `dir`. `shooter` is never damaged by its
## own shot and its hitbox is flown through.
func setup(from: Vector3, dir: Vector3, damage: float, cfg: Dictionary,
		shooter: Node) -> void:
	global_position = from
	_dir = dir.normalized()
	_damage = damage
	_owner = shooter
	add_to_group("projectile")               # cleared on a map change
	_q = PhysicsRayQueryParameters3D.new()
	_q.collide_with_areas = true               # actor hitboxes are Area3D
	# An actor's own hitbox is an Area3D child, not the shooter itself:
	# leave it out from the start instead of hitting it and flying on.
	if shooter != null and shooter.has_method("hitbox_rid"):
		var hb: RID = shooter.call("hitbox_rid")
		if hb.is_valid():
			_ignore.append(hb)
	_rebuild_exclude()
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
		am = model_mesh(model_name)
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
		_mi.mesh = sphere_mesh(float(cfg.get("radius", 18.0)))
		_mi.material_override = sphere_material(_color)
	_mi.visible = false
	add_child(_mi)

## The fallback sphere of radius `r`, shared.
static func sphere_mesh(r: float) -> SphereMesh:
	var key: int = roundi(r * 100.0)
	var sm: SphereMesh = _spheres.get(key)
	if sm == null:
		sm = SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		_spheres[key] = sm
	return sm

## The fallback sphere's flat material in `col`, shared.
static func sphere_material(col: Color) -> StandardMaterial3D:
	var key: int = col.to_rgba32()
	var m: StandardMaterial3D = _sphere_mats.get(key)
	if m == null:
		m = StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = col
		_sphere_mats[key] = m
	return m

## A billboard quad `d` units across, shared by every halo of that size.
static func glow_quad(d: float) -> QuadMesh:
	var key: int = roundi(d * 100.0)
	var qm: QuadMesh = _quads.get(key)
	if qm == null:
		qm = QuadMesh.new()
		qm.size = Vector2(d, d)
		_quads[key] = qm
	return qm

## The additive soft-dot material of the halos and the rocket motor, in
## `col` (alpha included), shared.
static func glow_material(col: Color) -> StandardMaterial3D:
	var key: int = col.to_rgba32()
	var m: StandardMaterial3D = _glow_mats.get(key)
	if m == null:
		m = StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.albedo_texture = soft_dot()
		m.albedo_color = col
		m.disable_receive_shadows = true
		_glow_mats[key] = m
	return m

## The soft halo that makes a bolt readable in flight. It must be a
## round FALLOFF, not a flat quad: the first cut had no texture, so a
## walker's laser read as "a blue semi-transparent square" (2026-09-04).
## Energy of the light a round in flight throws (DYNAMIC LIGHTS only).
const BOLT_LIGHT_ENERGY: float = 2.0
## The rocket motor's colour.
const EXHAUST_COLOUR: Color = Color(1.0, 0.72, 0.36, 1.0)

func _add_glow(length: float) -> void:
	var d: float = maxf(length, 60.0) * GLOW_SCALE
	var g := MeshInstance3D.new()
	g.mesh = glow_quad(d)
	g.material_override = glow_material(Color(_color.r, _color.g, _color.b, 0.45))
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.visible = false
	add_child(g)
	# DYNAMIC LIGHTS: a round in flight lights what it flies past, in its
	# own measured colour (BOLT_COLOURS). Shadowless and short-ranged —
	# a firefight can have a dozen of these in the air at once.
	if Settings.dynamic_lights:
		var l := OmniLight3D.new()
		l.light_color = _color
		l.light_energy = BOLT_LIGHT_ENERGY
		l.omni_range = maxf(d, 200.0) * 2.0
		l.omni_attenuation = 1.5
		l.shadow_enabled = false
		add_child(l)

## The motor flame at a rocket's tail. ROCKET.3D is a dark 31 x 27 u
## body seen from behind at night, inside its own smoke: 25-45 px of
## black on black, so "nevidím samotnú raketu letieť" (2026-09-11) —
## the model was there, measured, just unreadable. A real rocket is
## seen by its motor; this is that, a hot additive dot at the tail.
func _add_exhaust(aabb: AABB) -> void:
	var g := MeshInstance3D.new()
	g.mesh = glow_quad(EXHAUST_SIZE)
	g.material_override = glow_material(EXHAUST_COLOUR)
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The tail is the model's end away from the nose (+Z for a rocket,
	# whose body is on -Z); the projectile node itself never rotates.
	var tail: float = -aabb.position.z if _body_forward else aabb.end.z
	g.position = -_dir * tail
	g.visible = false
	add_child(g)

## A 32x32 radial soft dot: bright in the middle, clear at the edge.
static func soft_dot() -> Texture2D:
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
## lying across the screen — the "výstrely sú ako keby z boku" playtest
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
	if _q == null:
		return                                   # setup() never ran
	_q.from = global_position
	_q.to = to
	var hit := space.intersect_ray(_q)
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
				_rebuild_exclude()
			global_position = hit["position"] + _dir * 2.0
			return
		if _splash <= 0.0:
			_deal(n, _damage)
		_finish(hit["position"], true)
		return
	_finish(hit["position"], true)               # solid geometry

## The flight ray's exclude list: every hitbox flown through so far plus
## the shooter's own body. Built whole and assigned once — the property
## hands out a copy, so appending to `_q.exclude` changed nothing and the
## shooter was only left out after its first hit on itself.
func _rebuild_exclude() -> void:
	var ex: Array[RID] = _ignore.duplicate()
	if is_instance_valid(_owner) and _owner is CollisionObject3D:
		ex.append((_owner as CollisionObject3D).get_rid())
	_q.exclude = ex

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
## The player takes a direct hit in DOS points (the ammo record's value,
## 0x1230d6 — DIFFICULTY applies there).
func _deal(n: Node, dmg: float) -> void:
	if _hits == "none":
		return
	if n.has_method("net_damage"):
		n.net_damage(dmg, _owner)
	elif n.has_method("take_dos_damage"):
		n.take_dos_damage(dmg)
	else:
		n.take_damage(dmg)

## DOS radial blast (FUN_00124386): strength `s` is the radius as well
## (clamped 5..500), the damage at distance `d` is s x (r - d + 40) / r —
## s + 40 - d for anything up to 500 — and nothing lands under half the
## strength (so a rocket, 400, reaches 240 u). No DIFFICULTY factor.
static func dos_blast(s: float, d: float) -> float:
	var r: float = clampf(s, 5.0, 500.0)
	var dmg: float = s * (r - d + 40.0) / r
	return dmg if dmg >= s * 0.5 else 0.0

## The blast (0x138a4a) also needs a clear line to the player: nothing
## solid between `from` and `to` (bodies only; `ignore` is the player).
static func blast_clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, ignore: Node) -> bool:
	if space == null:
		return true
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	if ignore is CollisionObject3D:
		q.exclude = [(ignore as CollisionObject3D).get_rid()]
	return space.intersect_ray(q).is_empty()

## The blast on the player, DOS style: from his DOS point, through the
## line-of-sight test, in DOS points. Deathmatch keeps its own reporting.
static func blast_player(at: Vector3, s: float, splash: float, owner: Node, tree: SceneTree) -> void:
	var pl := tree.get_first_node_in_group("player")
	if not (pl is Node3D) or not pl.has_method("take_damage"):
		return
	if Net.active and pl.has_method("net_damage"):
		var dn := (pl as Node3D).global_position.distance_to(at)
		if dn < splash:
			pl.net_damage(s * 0.55 * (1.0 - dn / splash), owner)
		return
	var pp: Vector3 = pl.call("dos_point") if pl.has_method("dos_point") else (pl as Node3D).global_position
	var pts: float = dos_blast(s, pp.distance_to(at))
	if pts <= 0.0:
		return
	if not blast_clear((pl as Node3D).get_world_3d().direct_space_state, at, pp, pl):
		return
	if pl.has_method("take_dos_damage"):
		pl.take_dos_damage(pts, false)
	else:
		pl.take_damage(pts, false)

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
					# One DOS radial blast (dos_blast) over everything in reach.
					var bd: float = dos_blast(_damage, d)
					if bd > 0.0:
						e.take_damage(bd)
		# Destructible map objects (cars, generators …) take blast damage
		# from anyone's explosion — DOS ObjHit runs for every object in
		# the radius.
		for h in get_tree().get_nodes_in_group("hittable"):
			if h is Node3D and h.has_method("take_damage"):
				var bh: float = dos_blast(_damage, (h as Node3D).global_position.distance_to(at))
				if bh > 0.0:
					h.take_damage(bh)
		# The player, own rocket or not — DOS makes no difference.
		blast_player(at, _damage, _splash, _owner, get_tree())
	if impact:
		if not _impact_sound.is_empty():
			Audio.play_sfx_3d(_impact_sound, at, -2.0)
		if _impact_bank > 0:
			var scene := get_tree().current_scene
			if scene != null:
				Explosion.spawn(scene, at, maxf(_splash * 0.6, 45.0), _impact_bank)
	queue_free()
