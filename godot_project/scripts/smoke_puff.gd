## A small, slow-fading smoke cloud. Spawned by the shotgun (and any
## projectile impact that flags smoke) at the muzzle or hit point.
##
## DOS spawns smoke via the ammo-type record's impact-spawn pointer
## (`DAT_00040728+0x2a`, skynet_gh.c:25954) — same call path as the
## explosion fireball but a different effect bank. The smoke source is
## `TEXTURE.237` (`fire smoke`, confirmed present in
## the game's GAMEDATA/TEXTURE.237), one of the
## "effects" family rendered with the same variant-3 billboard math.

extends Node3D

const Explosion := preload("res://scripts/explosion.gd")

const ANIM_FPS: float = 14.0
const BANK: int = 237

## Every frame of the smoke bank, converted once (Explosion.bank_frames).
static func frames() -> Array:
	return Explosion.bank_frames(BANK, 0)

var _sprite: Sprite3D = null
var _frames_local: Array = []
var _t: float = 0.0
var _idx: int = 0

func setup(at: Vector3, size: float = 160.0) -> void:
	global_position = at
	_frames_local = frames()
	if _frames_local.is_empty():
		queue_free()
		return
	_sprite = Sprite3D.new()
	_sprite.texture = _frames_local[0]
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.shaded = false
	_sprite.transparent = true
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var max_dim: int = 1
	for f in _frames_local:
		var sz: Vector2 = (f as Texture2D).get_size()
		max_dim = maxi(max_dim, int(maxf(sz.x, sz.y)))
	_sprite.pixel_size = size / float(max_dim)
	add_child(_sprite)

func _process(delta: float) -> void:
	if _sprite == null or _frames_local.is_empty():
		return
	_t += delta
	var step: float = 1.0 / ANIM_FPS
	while _t >= step:
		_t -= step
		_idx += 1
		if _idx >= _frames_local.size():
			queue_free()
			return
		_sprite.texture = _frames_local[_idx]
