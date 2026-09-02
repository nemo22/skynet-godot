## Dev tool: print the marker / sprite inventory of MAP files and dump
## menu art to PNG. Headless:
##   godot --headless --path . res://scenes/map_dump.tscn -- --maps=600,601 --img=NETMENU1.IMG --out=C:/tmp
extends Node

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")
const ImgFile := preload("res://scripts/loaders/img_file.gd")
const Palette := preload("res://scripts/loaders/palette.gd")

func _ready() -> void:
	var cli: Dictionary = {}
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a in args:
		if a.begins_with("--") and a.find("=") > 0:
			cli[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	var out_dir: String = String(cli.get("out", "."))
	if cli.has("maps"):
		var bsa := BSAReader.new()
		bsa.open(SkynetPaths.gamedata_path("MDMDMAP2.BSA"), SkynetPaths.variant)
		for s in String(cli["maps"]).split(","):
			var name := "MAP.%03d" % int(s)
			var bytes := bsa.read(name)
			if bytes.is_empty():
				print("%s: missing" % name)
				continue
			var m := MapFile.parse(bytes)
			var outdoor: bool = bytes.size() > 9028 and bytes[9028] != 0
			if cli.has("find"):
				find_entities(m, String(cli["find"]))
			var markers: Dictionary = {}
			var enemies: Dictionary = {}
			var banks: Dictionary = {}
			var meshes: int = 0
			for e in m.entities:
				var v: int = e.flags & 3
				if v == 1:
					meshes += 1
				elif v == 3:
					if e.marker_type >= 0:
						var key := "%d" % e.marker_type
						markers[key] = markers.get(key, 0) + 1
						if e.marker_type == 2:
							enemies[e.enemy_type] = enemies.get(e.enemy_type, 0) + 1
						if e.marker_type != 2 and e.marker_type > 6:
							print("   marker %d at (%d,%d,%d) sub2=%d et=%d" % [e.marker_type, e.x, e.y, e.z, e.exit_map, e.enemy_type])
					elif e.sprite_index >= 0:
						var b: int = e.sprite_index >> 7
						banks[b] = banks.get(b, 0) + 1
			print("%s: grid %dx%d outdoor=%s meshes=%d markers=%s enemies=%s sprite_banks=%s"
				% [name, m.grid_width, m.grid_height, outdoor, meshes, markers, enemies, banks])
		bsa.close()
	if cli.has("bsa"):
		dump_bsa(String(cli["bsa"]), String(cli.get("filter", "")))
	if cli.has("strings"):
		dump_strings(String(cli["strings"]))
	if cli.has("tex"):
		dump_tex(String(cli["tex"]))
	if cli.has("faces"):
		dump_faces(String(cli["faces"]))
	if cli.has("frames"):
		dump_frames(String(cli["frames"]))
	if cli.has("img"):
		var imgs := BSAReader.new()
		imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant)
		var pal := Palette.parse(imgs.read(String(cli.get("pal", "MENU.COL"))))
		for nm in String(cli["img"]).split(","):
			var tex: ImageTexture = ImgFile.parse(imgs.read(nm), pal)
			if tex == null:
				print("%s: parse failed" % nm)
				continue
			var p := "%s/%s.png" % [out_dir, nm.get_basename()]
			tex.get_image().save_png(p)
			print("%s -> %s (%dx%d)" % [nm, p, tex.get_width(), tex.get_height()])
		imgs.close()
	get_tree().quit()

## --frames=SPIDBOT.3D,T800RFL.3D: per-frame AABB of an animated .3D.
static func dump_frames(names: String) -> void:
	for nm in names.split(","):
		var frames: Array = Assets.mesh_frames(nm.strip_edges().to_upper())
		print("%s: %d frames" % [nm, frames.size()])
		for i in frames.size():
			var b: AABB = (frames[i] as ArrayMesh).get_aabb()
			print("  f%02d min=(%.0f,%.0f,%.0f) size=(%.0f,%.0f,%.0f)" % [i, b.position.x, b.position.y, b.position.z, b.size.x, b.size.y, b.size.z])

## --faces=OVRPASS1.3D: per-face vertex extent and raw UV deltas.
static func dump_faces(names: String) -> void:
	var Mesh3D = load("res://scripts/loaders/mesh_3d.gd")
	for nm in names.split(","):
		var key: String = nm.strip_edges().to_upper()
		var bytes: PackedByteArray = Assets.read_3d(key)
		var m = Mesh3D.parse(bytes, key.get_basename())
		if m == null:
			print("%s: parse failed" % key)
			continue
		print("%s: %d verts, %d faces, aabb %s" % [key, m.vertices.size(), m.faces.size(), m.aabb])
		for i in m.faces.size():
			var f = m.faces[i]
			var lo := Vector3(1e9, 1e9, 1e9)
			var hi := Vector3(-1e9, -1e9, -1e9)
			for vi in f.idx:
				var p: Vector3 = m.vertices[vi]
				lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
				hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
			var pts: Array = []
			for vi in f.idx:
				pts.append(m.vertices[vi])
			print("  face %2d n=%d tex=%d extent=%s du=%s dv=%s idx=%s pts=%s" % [i, f.vert_count, f.type, hi - lo, Array(f.du), Array(f.dv), Array(f.idx), pts])

## --find=OVRPASS --maps=230: entity positions (Godot coords) by name.
static func find_entities(m, name_part: String) -> void:
	var MapFile = load("res://scripts/loaders/map_file.gd")
	for e in m.entities:
		if (e.flags & 3) != 1:
			continue
		var nm: String = MapFile.entity_name(m, e)
		if nm.to_upper().contains(name_part.to_upper()):
			print("   %s at godot (%d, %d, %d)" % [nm, e.x, -e.y, -e.z])

## --tex=266:1,0:60: does TEXTURE.<bank> record <rec> resolve?
static func dump_tex(spec: String) -> void:
	for s in spec.split(","):
		var p := s.split(":")
		if p.size() < 2:
			continue
		var t: Texture2D = Assets.texture(int(p[0]), int(p[1]), false)
		var tf = Assets._tex_file(int(p[0]))
		var r = tf.records[int(p[1])] if tf != null and int(p[1]) < tf.records.size() else null
		print("  rec w=%d h=%d pixels=%d" % [r.width, r.height, r.pixels.size()] if r != null else "  rec: none")
		print("  TEXTURE.%03d rec %d: %s (file records: %d)" % [int(p[0]), int(p[1]),
			("%dx%d" % [t.get_width(), t.get_height()]) if t != null else "MISSING", tf.records.size() if tf != null else -1])

## --strings=JEEP,HK: STRINGS.PRS entries whose key or text contains a word.
static func dump_strings(spec: String) -> void:
	var PrsFile = load("res://scripts/loaders/prs_file.gd")
	var t: Dictionary = PrsFile.table("STRINGS.PRS")
	for w in spec.split(","):
		for k in t:
			if String(k).to_upper().contains(w.to_upper()) or String(t[k]).to_upper().contains(w.to_upper()):
				print("  %s = %s" % [k, t[k]])

## --bsa=MDMDIMGS.BSA --filter=HK: list archive entries.
static func dump_bsa(arc: String, filt: String) -> void:
	var b := BSAReader.new()
	if not b.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
		print("cannot open %s" % arc)
		return
	var names: Array = []
	for e in b.entries():
		if filt.is_empty() or e.name.to_upper().contains(filt.to_upper()):
			names.append(e.name)
	b.close()
	names.sort()
	print("%s: %s" % [arc, " ".join(names)])
