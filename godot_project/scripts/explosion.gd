## DOS-style explosion: a billboarded cel animation from a TEXTURE.NNN
## effects bank. Plays once at the spawn position then self-destroys.
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
## of `Record`s with their own per-frame width/height.

extends Node3D

const FxParticles := preload("res://scripts/fx_particles.gd")
const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")
const Palette := preload("res://scripts/loaders/palette.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

## DOS advances the per-explosion frame timer by ~(DAT_00043100 * 0x180)
## >> 16 per game tick (skynet_gh.c:26670). Normalised to wall-clock that
## comes out near 24 fps on a typical CPU — good visual default.
const ANIM_FPS: float = 24.0

## Nothing is drawn closer than this to the eye, and no effect may span
## more than NEAR_SIZE_RATIO * 2 of its distance from it.
const NEAR_SKIP: float = 70.0
const NEAR_SIZE_RATIO: float = 0.4

const BANK_ENEMY_DEATH: int = 358
const BANK_ROCKET: int = 367

# Static frame cache keyed by bank id; loaded once per game session.
static var _frames_by_bank: Dictionary = {}
static var _palette_cache: PackedColorArray = PackedColorArray()

## Lazy-load the palette used by the in-game HUD / variant-3 sprites.
## Matches level_loader.gd's SKYNET.COL pick so the explosion blends in
## with everything else rendered from the same palette.
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

## Lazy-load and decode every frame of `archive_id` record 0 (the
## animation strip) into an Array of ImageTexture. Cached for the
## session — every subsequent explosion of the same kind reuses these.
static func _load_frames(archive_id: int) -> Array:
	if _frames_by_bank.has(archive_id):
		return _frames_by_bank[archive_id]
	var path: String = SkynetPaths.gamedata_path(
		"TEXTURE.%03d" % archive_id)
	var bytes: PackedByteArray = SkynetPaths.read_bytes(path)
	if bytes.is_empty():
		_frames_by_bank[archive_id] = []
		return []
	var palette: PackedColorArray = _load_palette()
	if palette.size() < 256:
		_frames_by_bank[archive_id] = []
		return []
	var records: Array = TextureNNN.parse_record_frames(bytes, 0)
	var textures: Array = []
	for rec in records:
		if rec == null or rec.width <= 0:
			continue
		var tex := TextureNNN.to_image_texture(rec, palette, true)
		if tex != null:
			textures.append(tex)
	_frames_by_bank[archive_id] = textures
	return textures

const PUFF_SHADER := preload("res://shaders/explosion_puff.gdshader")
## ENHANCED: how many noisy billboard puffs make up the fireball.
const PUFFS: int = 6
## ENHANCED: the puff cloud lives this long (the cel strips are ~0.5 s).
const ENH_LIFE: float = 1.1
var _elapsed: float = 0.0

var _sprite: Sprite3D = null
var _puffs: Array = []          # [MeshInstance3D, ShaderMaterial, dir: Vector3, size: float]
var _frames: Array = []
var _t: float = 0.0
var _idx: int = 0
var _radius: float = 200.0
var _light: OmniLight3D = null

## Spawn a billboarded explosion. `radius` sets the peak-frame visual
## diameter in world units (scaled to the largest frame's pixel extent).
## `archive_id` selects the bank — defaults to enemy-death; pass
## BANK_ROCKET for projectile detonations.
func setup(at: Vector3, radius: float,
		archive_id: int = BANK_ENEMY_DEATH) -> void:
	global_position = at
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
			queue_free()
			return
		_radius = minf(_radius, dist * NEAR_SIZE_RATIO)
	_frames = _load_frames(archive_id)
	if _frames.is_empty():
		# Bank failed to load — disappear silently rather than show
		# whatever placeholder we'd otherwise leak.
		queue_free()
		return

	_sprite = Sprite3D.new()
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.shaded = false
	_sprite.transparent = true
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_sprite.texture = _frames[0]
	# Match the visual peak to `radius`: pixel_size = world_units_per_pixel,
	# anchored on the LARGEST frame so the explosion's blow-out fills the
	# requested radius and earlier frames are correspondingly smaller.
	var max_dim: int = 1
	for f in _frames:
		var sz: Vector2 = (f as Texture2D).get_size()
		max_dim = maxi(max_dim, int(maxf(sz.x, sz.y)))
	_sprite.pixel_size = (_radius * 2.0) / float(max_dim)
	add_child(_sprite)
	if Render.enhanced():
		# A cloud of noisy, transparent billboard puffs (shaders/
		# explosion_puff.gdshader) instead of the cel frames: a bright core
		# and PUFFS blobs drifting outward, all cooling into smoke. The
		# frame clock still paces its life.
		_sprite.visible = false
		for i in PUFFS + 1:
			var mi := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(1.0, 1.0)
			mi.mesh = qm
			var sm := ShaderMaterial.new()
			sm.shader = PUFF_SHADER
			sm.set_shader_parameter("seed", randf() * 10.0)
			sm.set_shader_parameter("t", 0.0)
			sm.set_shader_parameter("intensity", 1.6 if i == 0 else 1.0)
			mi.material_override = sm
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var dir := Vector3.ZERO
			var size: float = _radius * 1.6
			if i > 0:
				dir = Vector3(randf_range(-1.0, 1.0), randf_range(-0.5, 1.0), randf_range(-1.0, 1.0)).normalized()
				size = _radius * randf_range(0.9, 1.4)
			mi.scale = Vector3(size, size, size) * 0.5
			add_child(mi)
			_puffs.append([mi, sm, dir, size])
		var scene: Node = get_parent()
		FxParticles.sparks(scene, at, Vector3.UP, int(clampf(_radius / 8.0, 12.0, 40.0)), _radius * 5.0)
		if _radius >= 100.0:
			FxParticles.smoke_column(scene, at, _radius)
		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.7, 0.4)
		_light.light_energy = Render.energy(3.0)
		_light.omni_range = maxf(_radius * 5.0, 600.0)
		_light.omni_attenuation = Render.OMNI_DECAY
		add_child(_light)

func _process(delta: float) -> void:
	if _sprite == null or _frames.is_empty():
		return
	_t += delta
	_elapsed += delta
	if not _puffs.is_empty():
		var tt: float = clampf(_elapsed / ENH_LIFE, 0.0, 1.0)
		if _elapsed >= ENH_LIFE:
			queue_free()
			return
		var grow: float = 0.45 + 0.75 * sqrt(tt)
		for pf in _puffs:
			var mi: MeshInstance3D = pf[0]
			(pf[1] as ShaderMaterial).set_shader_parameter("t", tt)
			mi.position = (pf[2] as Vector3) * _radius * 0.7 * sqrt(tt)
			var sz: float = float(pf[3]) * grow
			mi.scale = Vector3(sz, sz, sz)
		if _light != null:
			_light.light_energy = Render.energy(3.0 * (1.0 - tt) * (1.0 - tt))
		return
	var step: float = 1.0 / ANIM_FPS
	while _t >= step:
		_t -= step
		_idx += 1
		if _idx >= _frames.size():
			queue_free()
			return
		_sprite.texture = _frames[_idx]
		if _light != null:
			_light.light_energy = Render.energy(3.0 * (1.0 - float(_idx) / float(_frames.size())))
