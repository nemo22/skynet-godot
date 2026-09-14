## Autoload `Render` — how the port draws the original data: the DOS
## software-renderer look (docs/implementation_plan.md §P, §P.45).
##
## Nearest-filtered original textures, unshaded flat-lit models, the
## SKY_SKY.3D dome and depth haze. Every material the asset builders make
## passes through style(), so the look stays in one place.
##
## The look also depends on two player settings (SMOOTH TEXTURES, DYNAMIC
## LIGHTS), and the materials it styles are saved into the asset cache.
## So style() tags each material with its kind, and the cache hands every
## mesh it serves to restyle_mesh(): a material converted under one
## setting is brought in line with the current one when it is used, and
## restyle_all() does the same for everything in memory when a setting
## changes — no rebuild of the cache either way.
extends Node

## Material metadata naming the kind style() was called with.
const KIND_META := &"render_kind"

## Mesh instance id → the settings signature it was last styled for.
var _styled: Dictionary = {}

## Apply the DOS look to a material. `kind`: "model", "terrain",
## "sprite", "sky".
func style(mat: BaseMaterial3D, kind: String) -> void:
	if mat == null:
		return
	# Remember the kind: a cached copy is restyled from it when loaded.
	mat.set_meta(KIND_META, kind)
	# DOS sampled nearest; the SMOOTH TEXTURES setting asks for linear
	# with mipmaps instead (the player's choice, not the original's).
	var smooth: bool = false
	var dynamic: bool = false
	var s: Node = get_node_or_null("/root/Settings")
	if s != null:
		smooth = bool(s.get("texture_filter"))
		dynamic = bool(s.get("dynamic_lights"))
	# Only what differs is written: every BaseMaterial3D setter queues a
	# shader update, and restyle_mesh() passes shared cached materials
	# through here that are usually styled right already.
	var filter: int = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS \
		if smooth else BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if mat.texture_filter != filter:
		mat.texture_filter = filter
	var shading: int = BaseMaterial3D.SHADING_MODE_UNSHADED
	if kind != "sky" and kind != "sprite" and dynamic:
		# DYNAMIC LIGHTS: a muzzle flash or an explosion can only show on
		# a surface that takes light, and DOS drew the world unshaded, so
		# the switch has to turn the shading on with the lights. Rough and
		# barely specular — the DOS art has its own highlights painted in.
		# (The sky is its own light, and a billboard has no surface to
		# catch one: those stay flat whatever the setting says.)
		shading = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		if not is_equal_approx(mat.roughness, 0.9):
			mat.roughness = 0.9
		if not is_equal_approx(mat.metallic_specular, 0.2):
			mat.metallic_specular = 0.2
	if mat.shading_mode != shading:
		mat.shading_mode = shading

## The settings style() depends on, as one number.
func signature() -> int:
	var s: Node = get_node_or_null("/root/Settings")
	if s == null:
		return 0
	return (1 if bool(s.get("texture_filter")) else 0) \
		| (2 if bool(s.get("dynamic_lights")) else 0)

## Bring every material style() made for `mesh` in line with the current
## settings. Cheap to call on every use: a mesh already styled for this
## signature is skipped. Materials style() never saw (no kind tag — the
## untextured terrain fallback, say) are left exactly as built.
func restyle_mesh(mesh: Mesh) -> void:
	if mesh == null:
		return
	var sig: int = signature()
	var id: int = mesh.get_instance_id()
	if int(_styled.get(id, -1)) == sig:
		return
	_styled[id] = sig
	for si in mesh.get_surface_count():
		var m := mesh.surface_get_material(si) as BaseMaterial3D
		if m != null and m.has_meta(KIND_META):
			style(m, String(m.get_meta(KIND_META)))

## restyle_mesh() for every MeshInstance3D under `n` (a baked level branch).
func restyle_tree(n: Node) -> void:
	if n == null:
		return
	if n is MeshInstance3D:
		restyle_mesh((n as MeshInstance3D).mesh)
	for c in n.get_children():
		restyle_tree(c)

## A setting changed: restyle every mesh styled so far that still exists.
## Materials a level duplicated for its own lighting pass (main.gd) are
## copies and follow on the next level load.
func restyle_all() -> void:
	for id in _styled.keys():
		var mesh := instance_from_id(int(id)) as Mesh
		if mesh == null:
			_styled.erase(id)
			continue
		_styled[id] = -1
		restyle_mesh(mesh)
