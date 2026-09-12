## Autoload `Render` — how the port draws the original data: the DOS
## software-renderer look (docs/implementation_plan.md §P, §P.45).
##
## Nearest-filtered original textures, unshaded flat-lit models, the
## SKY_SKY.3D dome and depth haze. Until 2026-09-11 a second, ENHANCED
## look sat beside it (upscaled textures, a CC0 model pack, per-pixel
## lighting, a physical sky); Marek had it removed — it caused more
## trouble than it was worth — and the port now loads only the original
## SkyNET / Future Shock data. Every material the asset builders make
## still passes through style(), so the look stays in one place.
extends Node

## Apply the DOS look to a material. `kind`: "model", "terrain",
## "sprite", "sky".
func style(mat: BaseMaterial3D, kind: String) -> void:
	if mat == null:
		return
	# DOS sampled nearest; the SMOOTH TEXTURES setting asks for linear
	# with mipmaps instead (the player's choice, not the original's).
	var smooth: bool = false
	var dynamic: bool = false
	var s: Node = get_node_or_null("/root/Settings")
	if s != null:
		smooth = bool(s.get("texture_filter"))
		dynamic = bool(s.get("dynamic_lights"))
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS \
		if smooth else BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if kind == "sky" or kind == "sprite":
		# The sky is its own light, and a billboard has no surface to
		# catch one: these stay flat whatever the setting says.
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	elif dynamic:
		# DYNAMIC LIGHTS: a muzzle flash or an explosion can only show on
		# a surface that takes light, and DOS drew the world unshaded, so
		# the switch has to turn the shading on with the lights. Rough and
		# barely specular — the DOS art has its own highlights painted in,
		# and a shiny wall was what made the removed ENHANCED look glow.
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.roughness = 0.9
		mat.metallic_specular = 0.2
	else:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
