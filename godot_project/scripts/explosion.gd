## DOS-style explosion: a billboarded cel animation from a TEXTURE.NNN
## effects bank. Plays once at the spawn position then goes back to the
## pool (or frees itself).
##
## Reference (skynet_gh.c):
##   FUN_00123d0f  26585  ExploStart  — pool allocator, stores sprite_index
##   FUN_00123e3a  26654  per-tick advance via DAT_00043100 frame delta
##   FUN_00123e19  26642  ExploStop   — last-frame self-destroy
##   FUN_00123f10  26709  per-tick render via FUN_0014ea20 (variant-3
##                                     billboard blit — same code path)
##
## Asset banks (loose `gamedata/TEXTURE.NNN` files; not in BSAs):
##   358 "effects 3"   — enemy-death fireball (DOS sprite_idx 0xB300)
##   367 "effects 10"  — rocket/grenade detonation (DOS sprite_idx 0xB780)
##
## Each bank's record 0 holds the full multi-frame animation; the
## TextureNNN parser's `parse_record_frames` reads all frames into a list
## of `Record`s with their own per-frame width/height. `bank_frames`
## converts them once into the asset cache.

extends Node3D

const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")
const FramePack := preload("res://scripts/loaders/frame_pack.gd")
const ZoneLayers := preload("res://scripts/mission/zone_layers.gd")

## DOS advances the per-explosion frame timer by ~(DAT_00043100 * 0x180)
## >> 16 per game tick (skynet_gh.c:26670). Normalised to wall-clock that
## comes out near 24 fps on a typical CPU — good visual default.
const ANIM_FPS: float = 24.0

## Nothing is drawn closer than this to the eye, and no effect may span
## more than NEAR_SIZE_RATIO * 2 of its distance from it.
const NEAR_SKIP: float = 70.0
const NEAR_SIZE_RATIO: float = 0.4

const BANK_ENEMY_DEATH: int = 358

## Peak energy of the light a blast throws (DYNAMIC LIGHTS only).
const BLAST_ENERGY: float = 6.0

## Finished explosions waiting to be reused by spawn(). A firefight
## throws a hit puff per bullet; each one used to be a new Sprite3D (and
## a new light).
const POOL_MAX: int = 24
static var _pool: Array = []

## Frames per bank record, for the session (the disk copy is in the asset
## cache under converted/fx/).
static var _frames_by_key: Dictionary = {}

var _light: OmniLight3D = null

## Every frame of TEXTURE.<bank> record `rec` as textures, palette index 0
## transparent — decoded once and served from the asset cache after that.
## A record with fewer than `min_frames` frames comes back empty, and is
## remembered as such without decoding a pixel of it (the scenery
## billboards ask with 2: only the animated ones are wanted).
static func bank_frames(bank: int, rec: int = 0, min_frames: int = 1) -> Array:
	var key: String = "T%03d_%03d" % [bank, rec]
	if min_frames > 1:
		key += "_M%d" % min_frames
	if _frames_by_key.has(key):
		return _frames_by_key[key]
	var pack: Resource = Assets.fetch("fx", key, func() -> Resource:
		var bytes: PackedByteArray = SkynetPaths.read_bytes(
			SkynetPaths.gamedata_path("TEXTURE.%03d" % bank))
		var palette: PackedColorArray = Assets.palette()
		if bytes.is_empty() or palette.size() < 256:
			return null
		var recs: Array = []
		for r in TextureNNN.parse_record_frames(bytes, rec):
			if r != null and r.width > 0:
				recs.append(r)
		var fp := FramePack.new()
		if recs.size() < min_frames:
			return fp
		for r in recs:
			var img: Image = TextureNNN.to_image(r, palette, true)
			if img == null:
				continue
			# Lossless, like every other converted texture: the same pixels
			# the ImageTexture had, and saveable from a headless run.
			var pct := PortableCompressedTexture2D.new()
			pct.keep_compressed_buffer = true
			pct.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
			fp.frames.append(pct)
		return fp)
	var out: Array = (pack as FramePack).frames if pack is FramePack else []
	if out.size() < min_frames:
		out = []
	_frames_by_key[key] = out
	return out

## An explosion under `parent`, reusing a finished one when there is one.
## Same arguments as setup().
static func spawn(parent: Node, at: Vector3, radius: float,
		archive_id: int = BANK_ENEMY_DEATH) -> Node3D:
	if parent == null:
		return null
	var ex = null                              # this script's instance
	while ex == null and not _pool.is_empty():
		var c = _pool.pop_back()
		if is_instance_valid(c) and not (c as Node).is_queued_for_deletion():
			ex = c
	if ex == null:
		ex = load("res://scripts/explosion.gd").new()
	if ex.get_parent() != parent:
		if ex.get_parent() != null:
			ex.get_parent().remove_child(ex)
		parent.add_child(ex)
	ex.setup(at, radius, archive_id)
	return ex

var _sprite: Sprite3D = null
var _frames: Array = []
var _t: float = 0.0
var _idx: int = 0
var _radius: float = 200.0

## Spawn a billboarded explosion. `radius` sets the peak-frame visual
## diameter in world units (scaled to the largest frame's pixel extent).
## `archive_id` selects the bank — defaults to enemy-death.
func setup(at: Vector3, radius: float,
		archive_id: int = BANK_ENEMY_DEATH) -> void:
	global_position = at
	_t = 0.0
	_idx = 0
	_radius = maxf(radius, 60.0)
	# A shot that lands ON the player detonates at the camera, where any
	# billboard covers the whole screen — "when a robot hits me it blocks
	# the entire view" (2026-09-04). Cap the effect's apparent size by
	# what it is allowed to subtend, and drop it altogether when it goes
	# off inside the player's own head.
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		var dist: float = cam.global_position.distance_to(at)
		if dist < NEAR_SKIP:
			_finish()
			return
		_radius = minf(_radius, dist * NEAR_SIZE_RATIO)
	_frames = bank_frames(archive_id)
	if _frames.is_empty():
		# Bank failed to load — disappear silently rather than show
		# whatever placeholder we'd otherwise leak.
		_finish()
		return

	if _sprite == null:
		_sprite = Sprite3D.new()
		_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_sprite.shaded = false
		_sprite.transparent = true
		_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		add_child(_sprite)
	_sprite.texture = _frames[0]
	# Match the visual peak to `radius`: pixel_size = world_units_per_pixel,
	# anchored on the LARGEST frame so the explosion's blow-out fills the
	# requested radius and earlier frames are correspondingly smaller.
	var max_dim: int = 1
	for f in _frames:
		var sz: Vector2 = (f as Texture2D).get_size()
		max_dim = maxi(max_dim, int(maxf(sz.x, sz.y)))
	_sprite.pixel_size = (_radius * 2.0) / float(max_dim)
	# DYNAMIC LIGHTS: the blast lights the room, brightest at the
	# blow-out and gone with the last frame (see _process). Shadowless,
	# like the muzzle flash — it lives for a fraction of a second.
	if Settings.dynamic_lights:
		if _light == null:
			_light = OmniLight3D.new()
			_light.light_color = Color(1.0, 0.72, 0.4)
			_light.omni_attenuation = 1.5
			_light.shadow_enabled = false
			add_child(_light)
		_light.light_energy = BLAST_ENERGY
		_light.omni_range = _radius * 6.0
		_light.visible = true
	elif _light != null:
		_light.visible = false
	# A mission scene draws each zone on its own render layer, and a node
	# takes its layer when it ENTERS the tree (ZoneLayers.adopt). A pooled
	# explosion under Main is never re-added — spawn() only reparents when
	# the parent changes — so its sprite kept the layer of the zone it first
	# went off in, and after a doorway every blast out of the pool was on a
	# layer the camera no longer draws: the robot hits and deaths the owner
	# saw "only sometimes" were the fresh ones. Every setup puts the
	# visuals on the layer of where the blast goes off NOW.
	ZoneLayers.adopt(_sprite)
	if _light != null:
		ZoneLayers.adopt(_light)
	visible = true
	set_process(true)

func _process(delta: float) -> void:
	if _sprite == null or _frames.is_empty():
		return
	_t += delta
	var step: float = 1.0 / ANIM_FPS
	while _t >= step:
		_t -= step
		_idx += 1
		if _idx >= _frames.size():
			_finish()
			return
		_sprite.texture = _frames[_idx]
		if _light != null and _light.visible:
			_light.light_energy = BLAST_ENERGY \
				* (1.0 - float(_idx) / float(maxi(_frames.size(), 1)))

## Done: hide and wait in the pool for spawn(), or free when it is full.
func _finish() -> void:
	set_process(false)
	_frames = []
	if is_inside_tree() and _pool.size() < POOL_MAX and not _pool.has(self):
		visible = false
		_pool.append(self)
	else:
		queue_free()
