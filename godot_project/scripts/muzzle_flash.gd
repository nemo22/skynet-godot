## Short-lived muzzle-flash billboard. Spawns at the gun barrel when a
## weapon fires and fades over ~0.08 s. Uses `TEXTURE.219` ("muzzleflas",
## confirmed in C:\games\SKYNET\godot_project\gamedata\TEXTURE.219) —
## DOS spawns the same asset every shot from FUN_00126080
## (skynet_gh.c:28238/28379), passing the muzzle-flash effect id at
## weapon record `+0x20`. The sprite is rendered identically to variant-3
## billboards (`FUN_0014ea20`), so a Sprite3D with BILLBOARD_ENABLED is
## the right Godot analogue.
##
## A single static cache holds the decoded texture so every shot reuses
## one ImageTexture instance.

extends Node3D

const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")
const Palette := preload("res://scripts/loaders/palette.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

const LIFETIME: float = 0.08
const BANK: int = 219
## Peak energy of the light the shot throws (DYNAMIC LIGHTS only).
const FLASH_ENERGY: float = 4.0

var _light: OmniLight3D = null

static var _texture: Texture2D = null
static var _palette_cache: PackedColorArray = PackedColorArray()

static func _load_palette() -> PackedColorArray:
	if _palette_cache.size() >= 256:
		return _palette_cache
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"),
			SkynetPaths.variant):
		return PackedColorArray()
	var pal_bytes: PackedByteArray = SkynetPaths.palette_bytes()
	imgs.close()
	if pal_bytes.is_empty():
		return PackedColorArray()
	_palette_cache = Palette.parse(pal_bytes)
	return _palette_cache

static func _load_texture() -> Texture2D:
	if _texture != null:
		return _texture
	var path: String = SkynetPaths.gamedata_path("TEXTURE.%03d" % BANK)
	var bytes: PackedByteArray = SkynetPaths.read_bytes(path)
	if bytes.is_empty():
		return null
	var palette: PackedColorArray = _load_palette()
	if palette.size() < 256:
		return null
	var frames: Array = TextureNNN.parse_record_frames(bytes, 0)
	if frames.is_empty():
		return null
	_texture = TextureNNN.to_image_texture(frames[0], palette, true)
	return _texture

var _sprite: Sprite3D = null
var _t: float = LIFETIME

## Spawn a flash centred at `at`. `tint` modulates the texture (white =
## bullet/AR, red = laser, blue = plasma) so one asset covers every
## weapon family. `size` is the visual diameter in world units.
func setup(at: Vector3, tint: Color = Color.WHITE,
		size: float = 110.0) -> void:
	global_position = at
	var tex: Texture2D = _load_texture()
	if tex == null:
		queue_free()
		return
	_sprite = Sprite3D.new()
	_sprite.texture = tex
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.shaded = false
	_sprite.transparent = true
	# Additive blend + no alpha-cut: the flash glows over the scene and
	# fades smoothly via modulate.a. ALPHA_CUT_DISCARD would clip the
	# fade abruptly because its threshold (0.5) cuts the modulated alpha.
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	_sprite.no_depth_test = true
	_sprite.modulate = tint
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var max_dim: float = maxf(tex.get_size().x, tex.get_size().y)
	if max_dim < 1.0:
		max_dim = 1.0
	_sprite.pixel_size = size / max_dim
	add_child(_sprite)
	# DYNAMIC LIGHTS: the shot lights the walls around it for as long as
	# the flash lives. DOS lit nothing, so this is the player's choice —
	# and it only shows because the same setting makes the geometry take
	# light (render_mode.style). No shadows: a firefight would cast
	# dozens of shadow maps a second for an 0.08 s flash.
	if Settings.dynamic_lights:
		_light = OmniLight3D.new()
		_light.light_color = tint
		_light.light_energy = FLASH_ENERGY
		_light.omni_range = maxf(size, 60.0) * 8.0
		_light.omni_attenuation = 1.5
		_light.shadow_enabled = false
		add_child(_light)

func _process(delta: float) -> void:
	if _sprite == null:
		return
	_t -= delta
	if _t <= 0.0:
		queue_free()
		return
	var k: float = _t / LIFETIME              # 1 → 0
	_sprite.modulate.a = k
	if _light != null:
		_light.light_energy = FLASH_ENERGY * k
