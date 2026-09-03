## Autoload `Render` — the DOS / ENHANCED rendering switch
## (docs/implementation_plan.md §P).
##
##   DOS       what the port always drew: nearest-filtered original
##             textures, unshaded flat-lit models, the SKY_SKY.3D dome,
##             depth haze — a faithful software-renderer look.
##   ENHANCED  the same data through a modern pipeline: 4× pixel-art
##             upscaled textures with mipmaps and anisotropic filtering
##             (or hand-made replacements from <converted>/enhanced/pack/), normal
##             maps derived from the textures, smooth-shaded models,
##             per-pixel lighting with sun shadows and dynamic lights,
##             a physical sky (sunset / night with stars and moon), glow
##             and volumetric light.
##
## The mode is chosen in OPTIONS → DISPLAY (user://display.cfg
## `render`), `--render=enhanced|dos` on the command line, or the console
## (`render enhanced`). Every asset builder asks `Render.enhanced()`; the
## converted-asset cache keeps one tree per mode.
extends Node

signal mode_changed(mode: int)

const DOS: int = 0
const ENHANCED: int = 1
const NAMES: Array = ["DOS", "ENHANCED"]
const CFG_PATH: String = "user://display.cfg"

## DOS textures in ENHANCED mode: one scale2x pass (GDScript, ~50 ms per
## texture) then a native Lanczos ×2 — ×4 in all. Replacement PNGs may
## be any size.
const UPSCALE_PASSES: int = 1
## Smoothing-group angle for model normals in ENHANCED mode.
const SMOOTH_ANGLE_DEG: float = 55.0
## World units one repeat of the terrain detail layer covers (UV2).
const DETAIL_WORLD_SIZE: float = 900.0

var _detail_cache: Dictionary = {}       # name -> [albedo, normal] or []

## The pack's detail layer `<name>_detail.png` (+ `_n.png`) — grain and
## relief laid over the DOS colours at UV2. Empty array when absent.
func detail_layer(name: String) -> Array:
	if _detail_cache.has(name):
		return _detail_cache[name]
	var out: Array = []
	var p: String = override_path("textures/%s_detail.png" % name)
	if not p.is_empty():
		var img := Image.load_from_file(p)
		if img != null:
			img.generate_mipmaps()
			var nrm: Texture2D = null
			var np: String = override_path("textures/%s_detail_n.png" % name)
			if not np.is_empty():
				var nimg := Image.load_from_file(np)
				if nimg != null:
					nimg.generate_mipmaps()
					nrm = ImageTexture.create_from_image(nimg)
			out = [ImageTexture.create_from_image(img), nrm]
			print("[render] detail layer %s (%s)" % [name, p.get_file()])
	_detail_cache[name] = out
	return out

var mode: int = DOS

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		mode = clampi(int(cfg.get_value("display", "render", DOS)), DOS, ENHANCED)
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a in args:
		if a.begins_with("--render="):
			var v := a.substr(9).to_lower()
			mode = ENHANCED if v.begins_with("e") else DOS
	print("[render] mode %s" % NAMES[mode])

func enhanced() -> bool:
	return mode == ENHANCED

func set_mode(m: int) -> void:
	m = clampi(m, DOS, ENHANCED)
	if m == mode:
		return
	mode = m
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("display", "render", mode)
	cfg.save(CFG_PATH)
	print("[render] mode %s" % NAMES[mode])
	mode_changed.emit(mode)

## <converted>/enhanced/pack — hand-made replacements: textures/T<bank>_<rec>.png,
## sky/night.png, sky/sunset.png (equirectangular panoramas).
## The enhanced asset PACK (replace.cfg, models/, textures/, LICENSE) lives
## INSIDE the converted tree — <game>/converted/enhanced/pack — next to
## the ENHANCED cache it feeds (<game>/converted/enhanced/tex, mesh …), so
## everything the ENHANCED mode needs is one directory (Marek, 2026-09-03;
## the release will ship it as one package). Mind that the pack is NOT
## regenerable: a cache wipe must spare `enhanced/pack`.
func override_dir() -> String:
	return SkynetPaths.converted_dir() + "/enhanced/pack"

## `.png` in the name also matches `.webp` / `.jpg` on disk (the pack
## ships WebP to stay small).
func override_path(rel: String) -> String:
	var p := override_dir() + "/" + rel
	if FileAccess.file_exists(p):
		return p
	if rel.ends_with(".png"):
		for ext in [".webp", ".jpg"]:
			var q: String = p.get_basename() + ext
			if FileAccess.file_exists(q):
				return q
	return ""

## Apply the mode's look to a material. `kind`: "model", "terrain",
## "sprite", "sky". `normal` is the derived normal map (ENHANCED).
func style(mat: BaseMaterial3D, kind: String, normal: Texture2D = null) -> void:
	if mat == null:
		return
	if mode == DOS:
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		if kind == "sky" or kind == "sprite":
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		return
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	match kind:
		"model", "terrain":
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 0.85 if kind == "terrain" else 0.65
			mat.metallic = 0.0
			mat.metallic_specular = 0.4
			if normal != null:
				mat.normal_enabled = true
				mat.normal_texture = normal
				mat.normal_scale = 1.3 if kind == "terrain" else 1.0
			if kind == "terrain":
				var det: Array = detail_layer("terrain")
				if not det.is_empty():
					# Albedo × 2·detail (detail is a high-pass around 0.5,
					# so the DOS colour is kept on average) + its relief.
					mat.detail_enabled = true
					mat.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
					mat.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
					mat.detail_albedo = det[0]
					if det[1] != null:
						mat.detail_normal = det[1]
					mat.albedo_color = Color(2.0, 2.0, 2.0)
		"sprite":
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		"sky":
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

## Scale2x (EPX) — the classic pixel-art doubler: an edge-aware 2× that
## keeps hard lines hard instead of blurring them. Applied UPSCALE_PASSES
## times. Works on RGBA8 images; alpha rides along.
static func scale2x(src: Image) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var dst := Image.create(w * 2, h * 2, false, Image.FORMAT_RGBA8)
	for y in h:
		var ym: int = maxi(y - 1, 0)
		var yp: int = mini(y + 1, h - 1)
		for x in w:
			var xm: int = maxi(x - 1, 0)
			var xp: int = mini(x + 1, w - 1)
			var p: Color = src.get_pixel(x, y)
			var a: Color = src.get_pixel(x, ym)
			var b: Color = src.get_pixel(xp, y)
			var c: Color = src.get_pixel(xm, y)
			var d: Color = src.get_pixel(x, yp)
			var e0: Color = p
			var e1: Color = p
			var e2: Color = p
			var e3: Color = p
			if c == a and c != d and a != b:
				e0 = a
			if a == b and a != c and b != d:
				e1 = b
			if d == c and d != b and c != a:
				e2 = c
			if b == d and b != a and d != c:
				e3 = d
			dst.set_pixel(x * 2, y * 2, e0)
			dst.set_pixel(x * 2 + 1, y * 2, e1)
			dst.set_pixel(x * 2, y * 2 + 1, e2)
			dst.set_pixel(x * 2 + 1, y * 2 + 1, e3)
	return dst

## The ENHANCED version of a DOS texture image: scale2x passes, then a
## light bilinear soften so the blocks read as surface, plus mipmaps.
static func enhance_image(img: Image, crisp: bool = false) -> Image:
	var out: Image = img
	if out.get_format() != Image.FORMAT_RGBA8:
		out = out.duplicate()
		out.convert(Image.FORMAT_RGBA8)
	for _i in UPSCALE_PASSES:
		out = scale2x(out)
	if crisp:
		# Sprites: a second EPX pass instead of the resample — edges stay
		# hard, the silhouette stays pixel-art. Total ×4.
		out = scale2x(out)
	else:
		# Surfaces: a native Lanczos ×2 (fast) — the EPX pass keeps the
		# edges, the resample takes the stair-steps off them. Total ×4.
		out.resize(out.get_width() * 2, out.get_height() * 2, Image.INTERPOLATE_LANCZOS)
	out.generate_mipmaps()
	return out

## A tangent-space normal map from a colour image (height = luminance).
static func normal_from(img: Image, strength: float = 4.0) -> Image:
	var n: Image = img.duplicate()
	n.convert(Image.FORMAT_RGBA8)
	if n.has_mipmaps():
		n.clear_mipmaps()
	n.bump_map_to_normal_map(strength)
	n.generate_mipmaps()
	return n
