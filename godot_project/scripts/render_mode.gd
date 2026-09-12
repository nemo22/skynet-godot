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
	var s: Node = get_node_or_null("/root/Settings")
	if s != null:
		smooth = bool(s.get("texture_filter"))
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS \
		if smooth else BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if kind == "sky" or kind == "sprite":
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
