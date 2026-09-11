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
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if kind == "sky" or kind == "sprite":
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
