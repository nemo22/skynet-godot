## Which of the game's textures are actually WORTH replacing.
##
##   godot --headless --path . res://scenes/tex_usage.tscn -- out.csv
##
## The game ships 328 TEXTURE.NNN banks, but a bank is not a unit of
## work: what matters is how much of the screen a record covers when you
## play. This walks every MAP in MDMDMAP2.BSA, counts how often each mesh
## is placed, parses each mesh once and adds up the WORLD AREA of the
## faces that use each (bank, record) — placements included. The result
## is a ranked list: replace the top of it and you have replaced most of
## what the player sees.
##
## Terrain tiles (bank 302) are counted separately: every outdoor map is
## one big sheet of them, so they never appear on a mesh.

extends Node

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D    := preload("res://scripts/loaders/mesh_3d.gd")
const MapFile   := preload("res://scripts/loaders/map_file.gd")
const Paths     := preload("res://scripts/skynet_paths.gd")

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "tex_usage.csv"
	var gd: String = SkynetPaths.gamedata_dir
	var variant: int = SkynetPaths.variant
	print("gamedata %s variant %d" % [gd, variant])
	if gd.is_empty():
		print("no game data")
		get_tree().quit(1)
		return

	# --- how often each mesh is placed, over every map ----------------
	var placed: Dictionary = {}            # "NAME" -> count
	var maps := BSAReader.new()
	var n_maps: int = 0
	if maps.open(gd + "/MDMDMAP2.BSA", variant):
		for e in maps.entries():
			var mn: String = e.name.to_upper()
			if not mn.begins_with("MAP."):
				continue
			var m = MapFile.parse(maps.read(mn))
			if m == null:
				continue
			n_maps += 1
			for ent in m.entities:
				if (ent.flags & 3) != 1:
					continue
				var nm: String = MapFile.entity_name(m, ent)
				if nm.is_empty():
					continue
				placed[nm.to_upper()] = int(placed.get(nm.to_upper(), 0)) + 1
		maps.close()

	# --- area per (bank, record) --------------------------------------
	var area: Dictionary = {}              # bank<<7|rec -> world area
	var on_meshes: Dictionary = {}         # bank<<7|rec -> how many meshes
	var objs := BSAReader.new()
	var parsed: int = 0
	if objs.open(gd + "/MDMDOBJS.BSA", variant):
		for nm in placed:
			var bytes: PackedByteArray = objs.read(nm + ".3D")
			if bytes.is_empty():
				continue
			var mesh = Mesh3D.parse(bytes)
			if mesh == null:
				continue
			parsed += 1
			var copies: float = float(placed[nm])
			var seen: Dictionary = {}
			for f in mesh.faces:
				if f.idx.size() < 3:
					continue
				var a: float = 0.0
				for i in range(1, f.idx.size() - 1):
					var p0: Vector3 = mesh.vertices[f.idx[0]]
					var p1: Vector3 = mesh.vertices[f.idx[i]]
					var p2: Vector3 = mesh.vertices[f.idx[i + 1]]
					a += (p1 - p0).cross(p2 - p0).length() * 0.5
				var key: int = f.type & 0xFFFF
				area[key] = float(area.get(key, 0.0)) + a * copies
				if not seen.has(key):
					seen[key] = true
					on_meshes[key] = int(on_meshes.get(key, 0)) + 1
		objs.close()

	# --- what the pack already replaces -------------------------------
	var have: Dictionary = {}
	var cfg := ConfigFile.new()
	var pack: String = Render.override_dir()
	if not FileAccess.file_exists(pack + "/replace.cfg"):
		pack = "res://converted/enhanced_pack"
	if cfg.load(pack + "/replace.cfg") == OK and cfg.has_section("sprites"):
		for k in cfg.get_section_keys("sprites"):
			have[String(k).to_upper()] = true
	var tex_dir := DirAccess.open(pack + "/textures")
	if tex_dir != null:
		for f in tex_dir.get_files():
			have[f.get_basename().to_upper().trim_suffix("_N").trim_suffix("_DETAIL")] = true

	var keys: Array = area.keys()
	keys.sort_custom(func(a, b) -> bool: return float(area[a]) > float(area[b]))
	var total: float = 0.0
	for k in keys:
		total += float(area[k])

	var lines: Array = ["bank,record,area_share_pct,meshes,replaced"]
	var shown: int = 0
	var covered: float = 0.0
	print("%d maps, %d distinct meshes placed, %d parsed, %d textures used"
		% [n_maps, placed.size(), parsed, keys.size()])
	print("rank  bank/rec   share  cum    meshes  replaced")
	for k in keys:
		var bank: int = k >> 7
		var rec: int = k & 0x7F
		var share: float = float(area[k]) / maxf(total, 1.0) * 100.0
		covered += share
		var name: String = "T%03d_%03d" % [bank, rec]
		var done: String = "yes" if have.has(name) else "-"
		lines.append("%d,%d,%.3f,%d,%s" % [bank, rec, share, int(on_meshes.get(k, 0)), done])
		if shown < 40:
			print("%4d  %s  %5.2f%% %5.1f%%  %5d   %s"
				% [shown + 1, name, share, covered, int(on_meshes.get(k, 0)), done])
		shown += 1
	# How many records carry 50 / 80 / 90 % of the visible surface.
	var run: float = 0.0
	var marks: Array = [50.0, 80.0, 90.0]
	var mi: int = 0
	for i in keys.size():
		run += float(area[keys[i]]) / maxf(total, 1.0) * 100.0
		while mi < marks.size() and run >= float(marks[mi]):
			print("  %d records cover %.0f%% of the placed surface" % [i + 1, marks[mi]])
			mi += 1
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		for l in lines:
			f.store_line(String(l))
		f.close()
		print("wrote %s (%d rows)" % [out_path, lines.size() - 1])
	get_tree().quit()
