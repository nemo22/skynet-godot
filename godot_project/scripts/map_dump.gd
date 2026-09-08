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
	if cli.has("wldmatch"):
		preload("res://tools/wldmatch.gd").run(String(cli["wldmatch"]))
	if cli.has("mats"):
		preload("res://tools/terrain_mats.gd").run(String(cli["mats"]))
	if cli.has("terrain"):
		preload("res://tools/terrain_census.gd").run(String(cli["terrain"]))
	if cli.has("maps"):
		var bsa := BSAReader.new()
		bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
		for s in String(cli["maps"]).split(","):
			var name := "MAP.%03d" % int(s)
			var bytes := bsa.read(name)
			if bytes.is_empty():
				print("%s: missing" % name)
				continue
			var m := MapFile.parse(bytes)
			var outdoor: bool = bytes.size() > 9028 and bytes[9028] != 0
			if bytes.size() > 9032:
				print("   header +9028 flag = %d (u32 %d)" % [bytes[9028], bytes[9028] | (bytes[9029] << 8) | (bytes[9030] << 16) | (bytes[9031] << 24)])
			if cli.has("header"):
				# --header: the u32 words from +9000 on (a vehicle-mode hunt).
				var words: Array = []
				for k in 24:
					var o: int = 9000 + k * 4
					if o + 4 <= bytes.size():
						words.append(bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16) | (bytes[o + 3] << 24))
				print("   header u32 @9000: %s" % [words])
				var head: Array = []
				for k in 16:
					head.append(bytes[k] | (bytes[k + 1] << 8) | (bytes[k + 2] << 16) | (bytes[k + 3] << 24) if false else bytes[k * 4] | (bytes[k * 4 + 1] << 8) | (bytes[k * 4 + 2] << 16) | (bytes[k * 4 + 3] << 24))
				print("   header u32 @0: %s" % [head])
			if cli.has("find"):
				find_entities(m, String(cli["find"]))
			var markers: Dictionary = {}
			var enemies: Dictionary = {}
			var banks: Dictionary = {}
			var meshes: int = 0
			var lights: int = 0
			var lights_on: int = 0
			for e in m.entities:
				var v: int = e.flags & 3
				if v == 1:
					meshes += 1
				elif v == 2:
					lights += 1
					if e.light_enable > 0:
						lights_on += 1
				elif v == 3:
					if e.marker_type >= 0:
						var key := "%d" % e.marker_type
						markers[key] = markers.get(key, 0) + 1
						if e.marker_type == 2:
							enemies[e.enemy_type] = enemies.get(e.enemy_type, 0) + 1
						if e.marker_type != 2:
							print("   marker %d at (%d,%d,%d) sub2=%d et=%d" % [e.marker_type, e.x, e.y, e.z, e.exit_map, e.enemy_type])
					elif e.sprite_index >= 0:
						var b: int = e.sprite_index >> 7
						banks[b] = banks.get(b, 0) + 1
			print("%s: grid %dx%d outdoor=%s meshes=%d lights=%d(%d on) markers=%s enemies=%s sprite_banks=%s"
				% [name, m.grid_width, m.grid_height, outdoor, meshes, lights, lights_on, markers, enemies, banks])
		bsa.close()
	if cli.has("cfa"):
		# --cfa=WEAPON01.CFA --out=DIR: every frame of a CFA as PNG.
		for nm in String(cli["cfa"]).split(","):
			var fp: Array = Assets.cfa_frames(nm.to_upper())
			if fp.is_empty():
				print("[cfa] %s: not found" % nm)
				continue
			for i in fp.size():
				var t: Texture2D = fp[i]
				if t == null:
					continue
				var img: Image = t.get_image()
				var out2: String = "%s/%s_%02d.png" % [out_dir, nm.get_basename().to_upper(), i]
				print("[cfa] %s frame %d %dx%d -> %s (%s)"
					% [nm, i, img.get_width(), img.get_height(), out2, error_string(img.save_png(out2))])
	if cli.has("radiation"):
		dump_radiation(String(cli["radiation"]))
	if cli.has("brief"):
		var bb := BSAReader.new()
		if bb.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"), SkynetPaths.variant):
			for sfx in String(cli["brief"]).split(","):
				var raw := bb.read("%d.TXT" % int(sfx))
				print("===== %s.TXT (%d bytes) =====" % [sfx, raw.size()])
				print(raw.get_string_from_ascii())
			bb.close()
	if cli.has("makepack"):
		make_pack(String(cli["makepack"]))
	if cli.has("links"):
		dump_links(String(cli["links"]))
	if cli.has("names"):
		dump_names(String(cli["names"]))
	if cli.has("inventory"):
		dump_inventory(String(cli["inventory"]), String(cli.get("maps", "")))
	if cli.has("texusage"):
		dump_texusage(String(cli["texusage"]))
	if cli.has("bankdump"):
		# --bankdump=302,437 --out=DIR: every record of the banks as PNG.
		DirAccess.make_dir_recursive_absolute(out_dir)
		for b in String(cli["bankdump"]).split(","):
			var bank: int = int(b)
			var n: int = 0
			for rec in 128:
				var sz: Vector2i = Assets.record_size(bank, rec)
				var tex: Texture2D = Assets.texture(bank, rec, false)
				if tex == null or sz.x <= 1:
					continue
				var img: Image = tex.get_image()
				if img == null:
					continue
				img.save_png("%s/T%03d_%03d.png" % [out_dir, bank, rec])
				n += 1
				if rec >= Assets.record_count(bank) - 1:
					break
			print("[bankdump] TEXTURE.%03d: %d records" % [bank, n])
	if cli.has("bsa"):
		dump_bsa(String(cli["bsa"]), String(cli.get("filter", "")))
	if cli.has("strings"):
		dump_strings(String(cli["strings"]))
	if cli.has("scan"):
		scan_colours(String(cli["scan"]))
	if cli.has("pcttest"):
		# Why an emission mask saves empty: PortableCompressedTexture2D
		# round-trip with and without mipmaps / alpha.
		for mips in [false, true]:
			for alpha in [false, true]:
				var w := 64
				var data := PackedByteArray()
				data.resize(w * w * 4)
				for i in w * w:
					data[i * 4] = 255
					data[i * 4 + 1] = 128
					data[i * 4 + 2] = 0
					data[i * 4 + 3] = 255 if alpha else 255
				var img := Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, data)
				if mips:
					img.generate_mipmaps()
				var pct := PortableCompressedTexture2D.new()
				pct.keep_compressed_buffer = true
				pct.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
				var path := "user://pcttest_%s_%s.res" % [mips, alpha]
				var err := ResourceSaver.save(pct, path, ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH)
				var back = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
				var bytes := FileAccess.get_file_as_bytes(path)
				print("  mips=%s alpha=%s: in-memory %dx%d, saved %d bytes (%s), reloaded %dx%d" % [
					mips, alpha, pct.get_width(), pct.get_height(), bytes.size(), error_string(err),
					(back as Texture2D).get_width() if back is Texture2D else -1,
					(back as Texture2D).get_height() if back is Texture2D else -1])
	if cli.has("emi"):
		# --emi=199:7,296:6 [--out=DIR]: the ENHANCED emission mask of a
		# record — what the lit pixels of that texture are.
		for spec2 in String(cli["emi"]).split(","):
			var q := spec2.split(":")
			if q.size() < 2:
				continue
			var bank2: int = int(q[0])
			var rec2: int = int(q[1])
			var em: Texture2D = Assets.emission(bank2, rec2)
			if em == null:
				print("  E%03d_%03d: no mask (not emissive)" % [bank2, rec2])
				continue
			var ei: Image = em.get_image()
			print("  E%03d_%03d: %s %dx%d, image %s" % [bank2, rec2, em.get_class(),
				em.get_width(), em.get_height(),
				("%dx%d fmt %d" % [ei.get_width(), ei.get_height(), ei.get_format()]) if ei != null else "NULL"])
			if ei != null and out_dir != "":
				ei.save_png("%s/E%03d_%03d.png" % [out_dir, bank2, rec2])
	if cli.has("faces"):
		# --faces=NAME: how many faces use which texture (archive/record),
		# so a strangely coloured surface can be traced to its art.
		var Mesh3DL = load("res://scripts/loaders/mesh_3d.gd")
		for nm in String(cli["faces"]).split(","):
			var up: String = nm.to_upper()
			var bytes: PackedByteArray = PackedByteArray()
			for arc in ["MDMDOBJS.BSA", "MDMDENMS.BSA"]:
				var b := BSAReader.new()
				if not b.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
					continue
				bytes = b.read(up + ".3D")
				b.close()
				if not bytes.is_empty():
					break
			if bytes.is_empty():
				print("%s: not found" % up)
				continue
			var m = Mesh3DL.parse(bytes, up)
			if m == null:
				print("%s: parse failed" % up)
				continue
			var hist: Dictionary = {}
			for f in m.faces:
				hist[f.type] = int(hist.get(f.type, 0)) + 1
			var keys: Array = hist.keys()
			keys.sort()
			var parts: PackedStringArray = PackedStringArray()
			for k in keys:
				parts.append("%d/%d x%d" % [int(k) >> 7, int(k) & 0x7F, int(hist[k])])
			print("%s: %d faces, %d texture ids: %s" % [up, m.faces.size(), keys.size(), ", ".join(parts)])
	if cli.has("mesh"):
		# --mesh=24SUBDOR,BIGDOOR: bounds and the collider the port builds.
		var LevelBehaviour = load("res://scripts/level_behaviour.gd")
		for nm in String(cli["mesh"]).split(","):
			var up: String = nm.to_upper()
			var am: ArrayMesh = null
			for arc in ["MDMDOBJS.BSA", "MDMDENMS.BSA"]:
				var b := BSAReader.new()
				if not b.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
					continue
				var bytes: PackedByteArray = b.read(up + ".3D")
				b.close()
				if bytes.is_empty():
					continue
				am = Assets.mesh(up + ".3D", bytes)
				break
			if am == null:
				print("%s: not found" % up)
				continue
			var aabb: AABB = am.get_aabb()
			var box: Dictionary = LevelBehaviour.box_shape(am)
			for si in am.get_surface_count():
				var smat: Material = am.surface_get_material(si)
				if smat is BaseMaterial3D:
					var bm2: BaseMaterial3D = smat
					print("  surface %d: tex %s albedo %s" % [si,
						bm2.albedo_texture.resource_path.get_file() if bm2.albedo_texture else "NONE (fallback colour)",
						bm2.albedo_color])
			print("%s: aabb pos %s size %s, %d surfaces; door_like=%s → box %s at %s"
				% [up, aabb.position, aabb.size, am.get_surface_count(),
				   LevelBehaviour.is_door_like(am), (box["shape"] as BoxShape3D).size, box["centre"]])
	if cli.has("tex"):
		dump_tex(String(cli["tex"]), String(cli.get("out", "")))
	if cli.has("faces"):
		dump_faces(String(cli["faces"]))
	if cli.has("frames"):
		dump_frames(String(cli["frames"]))
	if cli.has("img"):
		var imgs := BSAReader.new()
		imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant)
		# --pal=NAME.COL: from the archive or loose in GAMEDATA (Future Shock).
		var pal := Palette.parse(SkynetPaths.col_bytes(String(cli.get("pal", "MENU.COL"))))
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

## --inventory=DIR [--maps=210,220]: what the maps are made of, for the
## ENHANCED replacement pack — every billboard sprite as a PNG
## (DIR/sprites/T<bank>_<rec>.png) with its use count, every placed .3D
## name with count and AABB, every enemy type. Writes DIR/inventory.txt.
static func dump_inventory(dir: String, maps_arg: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir + "/sprites")
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	var names: Array = []
	if maps_arg.is_empty():
		for e in bsa.entries():
			if e.name.to_upper().begins_with("MAP."):
				names.append(e.name.to_upper())
	else:
		for s in maps_arg.split(","):
			names.append("MAP.%03d" % int(s))
	names.sort()
	var sprites: Dictionary = {}     # index -> {count, maps}
	var meshes: Dictionary = {}      # name -> {count, maps}
	var enemies: Dictionary = {}
	for name in names:
		var bytes := bsa.read(name)
		if bytes.is_empty():
			continue
		var m := MapFile.parse(bytes)
		for e in m.entities:
			var v: int = e.flags & 3
			if v == 1:
				var nm: String = MapFile.entity_name(m, e).to_upper()
				if nm.is_empty():
					continue
				var d: Dictionary = meshes.get(nm, {"count": 0, "maps": {}})
				d["count"] += 1
				d["maps"][name] = true
				meshes[nm] = d
			elif v == 3:
				if e.marker_type == 2:
					enemies[e.enemy_type] = enemies.get(e.enemy_type, 0) + 1
				elif e.marker_type == -1 and e.sprite_index >= 0:
					var d: Dictionary = sprites.get(e.sprite_index, {"count": 0, "maps": {}})
					d["count"] += 1
					d["maps"][name] = true
					sprites[e.sprite_index] = d
	bsa.close()
	var lines: PackedStringArray = []
	lines.append("# SPRITES (bank rec  count  wxh  maps)")
	var keys: Array = sprites.keys()
	keys.sort()
	for si in keys:
		var bank: int = si >> 7
		var rec: int = si & 0x7F
		var tex: Texture2D = Assets.texture(bank, rec, true)
		var size := "?"
		if tex != null:
			var img: Image = tex.get_image()
			if img != null:
				img.save_png("%s/sprites/T%03d_%03d.png" % [dir, bank, rec])
				size = "%dx%d" % [img.get_width(), img.get_height()]
		var mk: Array = sprites[si]["maps"].keys()
		mk.sort()
		lines.append("T%03d_%03d  %4d  %s  %s" % [bank, rec, sprites[si]["count"], size, ",".join(mk).replace("MAP.", "")])
	lines.append("")
	lines.append("# MESHES (name  count  aabb size  maps)")
	var mkeys: Array = meshes.keys()
	mkeys.sort()
	for nm in mkeys:
		var am: ArrayMesh = Assets.mesh(nm + ".3D")
		var sz := "?"
		if am != null:
			var b: AABB = am.get_aabb()
			sz = "%.0fx%.0fx%.0f" % [b.size.x, b.size.y, b.size.z]
		var mk: Array = meshes[nm]["maps"].keys()
		mk.sort()
		lines.append("%-10s %4d  %-16s %s" % [nm, meshes[nm]["count"], sz, ",".join(mk).replace("MAP.", "")])
	lines.append("")
	lines.append("# ENEMIES (type  count)")
	var ek: Array = enemies.keys()
	ek.sort()
	for t in ek:
		lines.append("%3d  %4d" % [t, enemies[t]])
	var f := FileAccess.open(dir + "/inventory.txt", FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	print("[inventory] %d sprites, %d meshes, %d enemy types -> %s" % [sprites.size(), meshes.size(), enemies.size(), dir])

## --texusage=DIR: which TEXTURE records the placed meshes of every map
## use, weighted by placements (DIR/inventory.txt from --inventory must
## exist). Writes DIR/texusage.txt: bank rec  weight  meshes.
static func dump_texusage(dir: String) -> void:
	var Mesh3D = load("res://scripts/loaders/mesh_3d.gd")
	var f := FileAccess.open(dir + "/inventory.txt", FileAccess.READ)
	if f == null:
		print("[texusage] no %s/inventory.txt" % dir)
		return
	var in_meshes := false
	var usage: Dictionary = {}          # type_id -> [weight, {mesh: true}]
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.begins_with("# MESHES"):
			in_meshes = true
			continue
		if line.begins_with("# ENEMIES"):
			break
		if not in_meshes or line.strip_edges().is_empty():
			continue
		var parts: PackedStringArray = line.split(" ", false)
		if parts.size() < 2:
			continue
		var nm: String = parts[0]
		var count: int = int(parts[1])
		var bytes: PackedByteArray = Assets.read_3d(nm + ".3D")
		if bytes.is_empty():
			continue
		var m = Mesh3D.parse(bytes, nm)
		if m == null:
			continue
		var seen: Dictionary = {}
		for face in m.faces:
			seen[face.type] = seen.get(face.type, 0) + 1
		for t in seen:
			var u: Array = usage.get(t, [0, {}])
			u[0] += count * int(seen[t])
			u[1][nm] = true
			usage[t] = u
	f.close()
	var keys: Array = usage.keys()
	keys.sort_custom(func(a, b): return usage[a][0] > usage[b][0])
	var lines: PackedStringArray = ["# bank rec  weight(faces x placements)  size  meshes"]
	for t in keys:
		var bank: int = t >> 7
		var rec: int = t & 0x7F
		var sz: Vector2i = Assets.record_size(bank, rec)
		var ms: Array = usage[t][1].keys()
		ms.sort()
		lines.append("T%03d_%03d  %7d  %dx%d  %s" % [bank, rec, usage[t][0], sz.x, sz.y, ",".join(ms.slice(0, 12))])
	var o := FileAccess.open(dir + "/texusage.txt", FileAccess.WRITE)
	o.store_string("
".join(lines))
	o.close()
	print("[texusage] %d records -> %s/texusage.txt" % [keys.size(), dir])

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
		if (e.flags & 3) == 2 and name_part.to_lower() == "lights":
			print("   light at godot (%d, %d, %d) intensity=%d range=%d"
				% [e.x, -e.y, -e.z, e.light_intensity, e.light_enable])
			continue
		if (e.flags & 3) == 3 and name_part.to_lower() == "sprites" and e.sprite_index >= 0 				and e.marker_type < 0:
			print("   sprite %d/%d at godot (%d, %d, %d) act=%02x" % [e.sprite_index >> 7,
				e.sprite_index & 0x7F, e.x, -e.y, -e.z, e.link_act_type])
			continue
		if (e.flags & 3) != 1:
			continue
		var nm: String = MapFile.entity_name(m, e)
		if name_part == "*" or nm.to_upper().contains(name_part.to_upper()):
			print("   %s at godot (%d, %d, %d)" % [nm, e.x, -e.y, -e.z])

## --links=231: every entity that takes part in an action chain (state
## byte, act type, HP, link target) — movers, gates, switches,
## teleports — with the chain walked from each head. Godot coords.
static func dump_links(spec: String) -> void:
	var MapFile = load("res://scripts/loaders/map_file.gd")
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	for s in spec.split(","):
		var name := "MAP.%03d" % int(s)
		var bytes := bsa.read(name)
		if bytes.is_empty():
			print("%s: missing" % name)
			continue
		var m = MapFile.parse(bytes)
		print("%s links:" % name)
		var targets: Dictionary = {}
		for e in m.entities:
			if e.link_next > 0:
				targets[e.link_next] = true
		for e in m.entities:
			var v: int = e.flags & 3
			if e.state_byte == 0 and e.link_next <= 0 and e.link_act_type == 0 					and not targets.has(e.file_off):
				continue
			var label: String
			match v:
				1: label = MapFile.entity_name(m, e)
				2: label = "LIGHT"
				3: label = ("marker %d" % e.marker_type) if e.marker_type >= 0 					else ("sprite %d/%d" % [e.sprite_index >> 7, e.sprite_index & 0x7F])
				_: label = "v%d" % v
			var extra := ""
			if e.link_act_type == 0xF0:
				extra = " -> map %d set %d" % [e.exit_map, e.exit_marker_id]
			print("  @%05x %-14s v%d (%6d,%6d,%6d) st=%02x act=%02x hp=%d next=%05x%s%s"
				% [e.file_off, label, v, e.x, -e.y, -e.z, e.state_byte, e.link_act_type,
					e.hp, maxi(e.link_next, 0), extra, "  <head" if not targets.has(e.file_off) and e.link_next > 0 else ""])
	bsa.close()

## --radiation=210,220: the marker-4 radiation sources of each map with
## their strength, the lethal core (strength-256, where the dose is at
## its 50 HP/s ceiling), and how far the player start sits from the
## nearest one — a spawn inside a source would be unplayable.
static func dump_radiation(spec: String) -> void:
	var MapFile = load("res://scripts/loaders/map_file.gd")
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	for sfx in spec.split(","):
		var name := "MAP.%03d" % int(sfx)
		var bytes := bsa.read(name)
		if bytes.is_empty():
			continue
		var m = MapFile.parse(bytes)
		var start := Vector3.ZERO
		var srcs: Array = []
		for e in m.entities:
			if (e.flags & 3) != 3:
				continue
			if e.marker_type == 0:
				start = Vector3(float(e.x), -float(e.y), -float(e.z))
			elif e.marker_type == 4 and e.exit_map > 0:
				srcs.append([Vector3(float(e.x), -float(e.y), -float(e.z)), float(e.exit_map)])
		var nearest: float = 1e9
		var lines: Array = []
		for r in srcs:
			var d: float = (r[0] as Vector3).distance_to(start)
			nearest = minf(nearest, d - float(r[1]))
			lines.append("      %s strength %d, lethal core %d u, %d u from the start"
				% [r[0], int(r[1]), int(maxf(float(r[1]) - 256.0, 0.0)), int(d)])
		print("%s: %d radiation sources; nearest edge %s from the player start"
			% [name, srcs.size(), ("%d u" % int(nearest)) if nearest < 1e8 else "n/a"])
		for l in lines:
			print(l)
	bsa.close()

## --makepack=SRC,PREFIX,OUT.pck: pack a directory into a Godot resource
## pack the game can mount at run time. Used to build the release
## `enhanced.pck` out of converted/enhanced_pack, and `converted.pck` out
## of a finished asset cache (see SkynetPaths.PACKS / build_pack):
##   --makepack=C:/games/skynet/converted/enhanced_pack,res://enhanced,C:/games/skynet/enhanced.pck
## A fourth field lists directory names to leave out (";" separated).
static func make_pack(spec: String) -> void:
	var v: PackedStringArray = spec.split(",")
	if v.size() < 3:
		print("[pack] need SRC,PREFIX,OUT.pck[,skip;skip]")
		return
	var skip := PackedStringArray()
	if v.size() > 3:
		skip = v[3].split(";", false)
	var r: Dictionary = SkynetPaths.build_pack(v[0], v[1], v[2], skip)
	if not bool(r["ok"]):
		print("[pack] FAILED: %s" % r["error"])
		return
	print("[pack] %s: %d files, %.1f MB in, %.1f MB out (%.1f s)"
		% [v[2], r["files"], float(r["bytes_in"]) / 1048576.0,
			float(r["bytes_out"]) / 1048576.0, float(r["msec"]) / 1000.0])

## --names=231: the raw 8-byte name slots of the MAP header (index, bytes)
## next to what the parser accepted, and every variant-1 entity whose
## name index the parser could not resolve.
static func dump_names(spec: String) -> void:
	var MapFile = load("res://scripts/loaders/map_file.gd")
	var bsa := BSAReader.new()
	bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant)
	for s in spec.split(","):
		var name := "MAP.%03d" % int(s)
		var bytes := bsa.read(name)
		if bytes.is_empty():
			continue
		var m = MapFile.parse(bytes)
		print("%s: parser accepted %d names; header u32 @0..0x10: %d %d %d %d %d" % [name, m.names.size(),
			bytes.decode_u32(0), bytes.decode_u32(4), bytes.decode_u32(8), bytes.decode_u32(12), bytes.decode_u32(16)])
		var off: int = 20
		var idx: int = 0
		var blank_run: int = 0
		while off + 8 <= 0x253C and blank_run < 4:
			var slot: PackedByteArray = bytes.slice(off, off + 8)
			var txt := ""
			var nonzero := false
			for b in slot:
				nonzero = nonzero or b != 0
				txt += char(b) if b >= 0x20 and b < 0x7F else ("." if b == 0 else "?")
			if nonzero:
				blank_run = 0
				print("  slot %3d @%04x: %s  %s" % [idx, off, txt, "" if idx < m.names.size() else "<< NOT accepted"])
			else:
				blank_run += 1
			off += 8
			idx += 1
		var missing: Dictionary = {}
		for e in m.entities:
			if (e.flags & 3) == 1 and MapFile.entity_name(m, e).is_empty():
				missing[e.name_index] = missing.get(e.name_index, 0) + 1
		print("  unresolved name indices (index: entities): %s" % missing)
	bsa.close()

## --tex=266:1,0:60: does TEXTURE.<bank> record <rec> resolve?
static func dump_tex(spec: String, out_dir: String = "") -> void:
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
		if t != null and out_dir != "":
			# --out=DIR: the record as PNG (index 0 transparent), to look at.
			var png: String = "%s/T%03d_%03d.png" % [out_dir, int(p[0]), int(p[1])]
			Assets.texture(int(p[0]), int(p[1]), true).get_image().save_png(png)
			print("  -> %s" % png)

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

## --scan=magenta|<r,g,b,tol>: every TEXTURE record with a big share of
## pixels near a colour — how a strangely coloured surface is traced to
## its art. Banks come from the game data directory, so nothing is out
## of range (the first cut stopped at 450 and missed TEXTURE.473).
static func scan_colours(spec: String) -> void:
	var target := Color(0.85, 0.25, 0.8)
	var tol: float = 0.35
	if spec != "magenta":
		var f := spec.split(",")
		if f.size() >= 3:
			target = Color(float(f[0]), float(f[1]), float(f[2]))
		if f.size() >= 4:
			tol = float(f[3])
	var banks: Array = []
	var d := DirAccess.open(SkynetPaths.gamedata_dir)
	if d != null:
		for f in d.get_files():
			if f.to_upper().begins_with("TEXTURE."):
				var n: int = int(f.get_extension())
				if not banks.has(n):
					banks.append(n)
	banks.sort()
	print("[scan] %d texture banks, target %s tol %.2f" % [banks.size(), target, tol])
	var found := 0
	for bank in banks:
		var tf = Assets._tex_file(bank)
		if tf == null:
			continue
		for rec in tf.records.size():
			var t: Texture2D = Assets.texture(bank, rec, true)
			if t == null:
				continue
			var img: Image = t.get_image()
			if img == null:
				continue
			var hits := 0
			var n := 0
			var step: int = maxi(1, mini(img.get_width(), img.get_height()) / 32)
			for y in range(0, img.get_height(), step):
				for x in range(0, img.get_width(), step):
					var c := img.get_pixel(x, y)
					if c.a <= 0.5:
						continue
					n += 1
					if Vector3(c.r - target.r, c.g - target.g, c.b - target.b).length() < tol:
						hits += 1
			if n > 0 and float(hits) / float(n) > 0.15:
				found += 1
				print("  T%03d_%03d %dx%d — %d%% of pixels" % [bank, rec, img.get_width(), img.get_height(), 100 * hits / n])
	print("[scan] %d records" % found)
