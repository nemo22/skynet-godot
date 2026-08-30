## A grenade fired from the GRENADE LAUNCHER. Travels under gravity in a
## parabolic arc, bounces off solid surfaces, and detonates on contact
## with an enemy or when its fuse runs out.
##
## DOS models this as a generic projectile (FUN_00122a64, skynet_gh.c:
## 25675) whose ammo type (t3 at 0x40728 + 3*0x32) installs the gravity
## callback 0x000f3414, draws the grenade as the billboard sprite named
## at +0x04 (sprite index 27778 = TEXTURE.217 record 2), and on impact
## spawns the effect bank at +0x08 (0xB200 = TEXTURE.356) with the sound
## at +0x20 (33 = explo1.raw). Launch is straight along the aim — the arc
## comes from gravity alone, so aiming up is what gives range.

extends Node3D

const Explosion  := preload("res://scripts/explosion.gd")
const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")
const Palette    := preload("res://scripts/loaders/palette.gd")
const BSAReader  := preload("res://scripts/loaders/bsa_reader.gd")

const GRAVITY: float = 2400.0
const FUSE_TIME: float = 2.5
const RESTITUTION: float = 0.35              # bounce energy retained
const SPEED: float = 2400.0                  # initial muzzle velocity
const SPRITE_BANK: int = 217
const SPRITE_RECORD: int = 2
const IMPACT_BANK: int = 356
const SPRITE_PIXEL_SIZE: float = 2.0

static var _sprite_tex: Texture2D = null
static var _sprite_tried: bool = false

var _vel: Vector3 = Vector3.ZERO
var _life: float = FUSE_TIME
var _damage: float = 200.0
var _splash: float = 256.0
var _owner: Node = null
var _exploded: bool = false

## TEXTURE.217 record 2 as a texture (loaded once per session).
static func _load_sprite() -> Texture2D:
	if _sprite_tried:
		return _sprite_tex
	_sprite_tried = true
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"),
			SkynetPaths.variant):
		return null
	var pal_bytes: PackedByteArray = imgs.read("SKYNET.COL")
	imgs.close()
	var palette := Palette.parse(pal_bytes)
	var bytes := SkynetPaths.read_bytes(
		SkynetPaths.gamedata_path("TEXTURE.%03d" % SPRITE_BANK))
	if palette.size() < 256 or bytes.is_empty():
		return null
	var tf := TextureNNN.parse(bytes)
	if tf == null or SPRITE_RECORD >= tf.records.size():
		return null
	_sprite_tex = TextureNNN.to_image_texture(
		tf.records[SPRITE_RECORD], palette, true)
	return _sprite_tex

## Launch from `from` heading `dir` (unit vector). Initial speed is
## constant; `damage` and `splash` set the detonation payload.
func setup(from: Vector3, dir: Vector3, damage: float, splash: float,
		shooter: Node) -> void:
	add_to_group("projectile")               # cleared on a map change
	global_position = from
	_vel = dir.normalized() * SPEED
	_damage = damage
	_splash = splash
	_owner = shooter
	var tex := _load_sprite()
	if tex != null:
		var spr := Sprite3D.new()
		spr.texture = tex
		spr.pixel_size = SPRITE_PIXEL_SIZE
		spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		spr.shaded = false
		spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		add_child(spr)
	else:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 14.0
		sm.height = 28.0
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.32, 0.45, 0.22)   # olive-drab body
		mi.material_override = mat
		add_child(mi)

func _physics_process(delta: float) -> void:
	if _exploded:
		return
	_life -= delta
	_vel.y -= GRAVITY * delta
	var to: Vector3 = global_position + _vel * delta
	var space := get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(global_position, to)
		q.collide_with_areas = true             # enemy hitboxes are areas
		if _owner is CollisionObject3D:
			q.exclude = [(_owner as CollisionObject3D).get_rid()]
		var hit := space.intersect_ray(q)
		if hit.has("position"):
			# Detonate on enemies; bounce off level geometry.
			var c: Node = hit.get("collider") as Node
			var n: Node = c
			while n != null and not n.has_method("take_damage"):
				n = n.get_parent()
			if n != null and n != _owner and n is Node3D \
					and n.is_in_group("enemy"):
				_detonate(hit["position"])
				return
			# Bounce: reflect velocity around the hit normal, lose energy.
			var nrm: Vector3 = hit.get("normal", Vector3.UP)
			global_position = hit["position"] + nrm * 2.0
			_vel = _vel.bounce(nrm) * RESTITUTION
			return
	global_position = to
	if _life <= 0.0:
		_detonate(global_position)

func _detonate(at: Vector3) -> void:
	_exploded = true
	Audio.play_sfx_3d("EXPLO1.RAW", at, -1.0)
	for h in get_tree().get_nodes_in_group("hittable"):
		if h is Node3D and h.has_method("take_damage"):
			var dh := (h as Node3D).global_position.distance_to(at)
			if dh < _splash:
				h.take_damage(_damage * (1.0 - dh / _splash))
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
	var scene := get_tree().current_scene
	if scene != null:
		var ex := Explosion.new()
		scene.add_child(ex)
		ex.setup(at, 280.0, IMPACT_BANK)
	queue_free()
