## Short-lived muzzle-flash billboard. Spawns at the gun barrel when a
## weapon fires and fades over ~0.08 s. Uses `TEXTURE.219` ("muzzleflas",
## confirmed in the game's GAMEDATA/TEXTURE.219) —
## DOS spawns the same asset every shot from FUN_00126080
## (skynet_gh.c:28238/28379), passing the muzzle-flash effect id at
## weapon record `+0x20`. The sprite is rendered identically to variant-3
## billboards (`FUN_0014ea20`), so a Sprite3D with BILLBOARD_ENABLED is
## the right Godot analogue.
##
## The texture is converted once (Explosion.bank_frames → asset cache)
## and shared by every shot; finished flashes wait in a small pool for
## spawn() instead of being freed.

extends Node3D

const Explosion := preload("res://scripts/explosion.gd")

const LIFETIME: float = 0.08
const BANK: int = 219
## Peak energy of the light the shot throws (DYNAMIC LIGHTS only).
const FLASH_ENERGY: float = 4.0
## Finished flashes kept for reuse — one per shot fired, map-wide.
const POOL_MAX: int = 24

static var _pool: Array = []

var _light: OmniLight3D = null

## The flash texture (record 0, frame 0 of TEXTURE.219), or null.
static func texture() -> Texture2D:
	var frames: Array = Explosion.bank_frames(BANK, 0)
	return frames[0] if not frames.is_empty() else null

## A flash under `parent`, reusing a finished one when there is one.
## Same arguments as setup().
static func spawn(parent: Node, at: Vector3, tint: Color = Color.WHITE,
		size: float = 110.0) -> Node3D:
	if parent == null:
		return null
	var mf = null                              # this script's instance
	while mf == null and not _pool.is_empty():
		var c = _pool.pop_back()
		if is_instance_valid(c) and not (c as Node).is_queued_for_deletion():
			mf = c
	if mf == null:
		mf = load("res://scripts/muzzle_flash.gd").new()
	if mf.get_parent() != parent:
		if mf.get_parent() != null:
			mf.get_parent().remove_child(mf)
		parent.add_child(mf)
	mf.setup(at, tint, size)
	return mf

var _sprite: Sprite3D = null
var _t: float = LIFETIME

## Spawn a flash centred at `at`. `tint` modulates the texture (white =
## bullet/AR, red = laser, blue = plasma) so one asset covers every
## weapon family. `size` is the visual diameter in world units.
func setup(at: Vector3, tint: Color = Color.WHITE,
		size: float = 110.0) -> void:
	global_position = at
	_t = LIFETIME
	var tex: Texture2D = texture()
	if tex == null:
		_finish()
		return
	if _sprite == null:
		_sprite = Sprite3D.new()
		_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_sprite.shaded = false
		_sprite.transparent = true
		# Additive blend + no alpha-cut: the flash glows over the scene and
		# fades smoothly via modulate.a. ALPHA_CUT_DISCARD would clip the
		# fade abruptly because its threshold (0.5) cuts the modulated alpha.
		_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		_sprite.no_depth_test = true
		_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		add_child(_sprite)
	_sprite.texture = tex
	_sprite.modulate = tint
	var max_dim: float = maxf(tex.get_size().x, tex.get_size().y)
	if max_dim < 1.0:
		max_dim = 1.0
	_sprite.pixel_size = size / max_dim
	# DYNAMIC LIGHTS: the shot lights the walls around it for as long as
	# the flash lives. DOS lit nothing, so this is the player's choice —
	# and it only shows because the same setting makes the geometry take
	# light (render_mode.style). No shadows: a firefight would cast
	# dozens of shadow maps a second for an 0.08 s flash.
	if Settings.dynamic_lights:
		if _light == null:
			_light = OmniLight3D.new()
			_light.omni_attenuation = 1.5
			_light.shadow_enabled = false
			add_child(_light)
		_light.light_color = tint
		_light.light_energy = FLASH_ENERGY
		_light.omni_range = maxf(size, 60.0) * 8.0
		_light.visible = true
	elif _light != null:
		_light.visible = false
	visible = true
	set_process(true)

func _process(delta: float) -> void:
	if _sprite == null:
		return
	_t -= delta
	if _t <= 0.0:
		_finish()
		return
	var k: float = _t / LIFETIME              # 1 → 0
	_sprite.modulate.a = k
	if _light != null and _light.visible:
		_light.light_energy = FLASH_ENERGY * k

## Done: hide and wait in the pool for spawn(), or free when it is full.
func _finish() -> void:
	set_process(false)
	if is_inside_tree() and _pool.size() < POOL_MAX and not _pool.has(self):
		visible = false
		_pool.append(self)
	else:
		queue_free()
