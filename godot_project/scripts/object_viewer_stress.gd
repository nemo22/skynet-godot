## Stress test: try to parse + build every .3D mesh, print summary.
## Boot via scene `scenes/stress.tscn` (under --headless --quit-after).

extends Node

const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D       := preload("res://scripts/loaders/mesh_3d.gd")
const Palette      := preload("res://scripts/loaders/palette.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")

func _ready() -> void:
	var imgs := BSAReader.new()
	imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant)
	var pal_bytes := SkynetPaths.palette_bytes()
	imgs.close()
	var cache := TextureCache.new(Palette.parse(pal_bytes), SkynetPaths.gamedata_dir)

	var objs := BSAReader.new()
	objs.open(SkynetPaths.gamedata_path("MDMDOBJS.BSA"), SkynetPaths.variant)
	var parse_fail := 0
	var build_fail := 0
	var ok := 0
	var total := 0
	var by_surfaces: Dictionary = {}
	for e in objs.entries():
		if not e.name.ends_with(".3D"): continue
		total += 1
		var bytes := objs.read(e.name)
		var parsed: Mesh3D.Mesh3D = Mesh3D.parse(bytes, e.name)
		if parsed == null:
			parse_fail += 1; continue
		var am := Mesh3D.build_textured_array_mesh(parsed, Callable(cache, "provide"))
		if am == null:
			build_fail += 1; continue
		ok += 1
		var sc: int = am.get_surface_count()
		by_surfaces[sc] = by_surfaces.get(sc, 0) + 1
	objs.close()
	print("[stress] total=%d ok=%d parse_fail=%d build_fail=%d" % [total, ok, parse_fail, build_fail])
	print("[stress] surfaces-per-mesh distribution: %s" % by_surfaces)
	get_tree().quit()
