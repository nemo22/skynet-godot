## Autoload `Assets`: the converted-asset cache.
##
## The original game data (gamedata/: BSA archives, TEXTURE.NNN, WLD.*)
## is parsed by the loaders in scripts/loaders/. Decoding it — palette
## look-ups per pixel, .3D face → ArrayMesh, 8-bit RAW → signed PCM — is
## the expensive part of every level load, and it is the same work every
## time. This cache stores the *results* as Godot binary resources
## (.res, compressed) so the second load is a plain ResourceLoader hit:
##
##   converted/tex/T302_017.res       PortableCompressedTexture2D
##   converted/mesh/BIGDOOR.res       ArrayMesh (materials → tex/ by path)
##   converted/frames/ENDOSKEL.res    FramePack of per-frame ArrayMeshes
##   converted/terrain/WLD.210.res    ArrayMesh
##   converted/sfx/DOORA.RAW.res      AudioStreamWAV
##   converted/cfa/WEAPON04.CFA.res   FramePack of textures
##   converted/shape/BIGDOOR.res      ConcavePolygonShape3D (shared)
##   converted/maps/MAP.210.level.scn the level itself, as a Godot scene
##
## Where the cache lives: `<game dir>/converted/` next to the gamedata
## directory (SkynetPaths.converted_dir — a portable install, nothing
## in the per-user Godot folder); only data bundled inside the project
## keeps it at res://converted (dev) or user://converted (export, where
## res:// is read-only). `CACHE_VERSION` is written to
## converted/VERSION; a mismatch wipes the directory so a loader change
## never serves stale data.
##
## Everything is lazy — a miss builds and saves — and `import_all()`
## runs the whole conversion up front (`--import` on the command line,
## or the first-start prompt in the menu). A release can ship the whole
## thing as `converted.pck`; SkynetPaths mounts it at res://converted and
## the cache then runs `read_only` (see there for the release layout).

extends Node

const BSAReader  := preload("res://scripts/loaders/bsa_reader.gd")
const Palette    := preload("res://scripts/loaders/palette.gd")
const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")
const Mesh3D     := preload("res://scripts/loaders/mesh_3d.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")
const CFAFile    := preload("res://scripts/loaders/cfa_file.gd")
const FramePack  := preload("res://scripts/loaders/frame_pack.gd")
const MapScene   := preload("res://scripts/editor/map_scene.gd")
const LevelScene := preload("res://scripts/level_scene.gd")

## Bump whenever a loader changes its output.
const CACHE_VERSION: int = 9   # 2026-09-08: emission masks were saved empty
const SAVE_FLAGS: int = ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH

## Cache root ("" when disabled with --no-cache).
var root: String = ""
var enabled: bool = true
## The cache came from a mounted converted.pck: everything is there and
## nothing can be written back. Misses still build in memory, they just
## are not saved (and the version check only reports a mismatch).
var read_only: bool = false
## Statistics for the log / progress UI.
var hits: int = 0
var misses: int = 0

var _palette: PackedColorArray = PackedColorArray()
var _tex_files: Dictionary = {}          # bank → TexFile / false
var _mem: Dictionary = {}                # path → Resource (session cache)

func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if "--no-cache" in args:
		enabled = false
		print("[assets] cache disabled (--no-cache)")
		return
	root = SkynetPaths.converted_dir()
	# A development checkout keeps the cache in the project (a directory,
	# or a link to the one beside the data) so the editor can open map
	# scenes; address it as res://converted then, so every saved resource
	# references res:// paths.
	# (Only for SkyNET: Future Shock's textures share record numbers with
	# SkyNET's and must never land in the same cache.)
	if SkynetPaths.game == "skynet" and not root.begins_with("res://") \
			and DirAccess.dir_exists_absolute("res://converted") \
			and FileAccess.file_exists("res://converted/VERSION"):
		root = "res://converted"
	# A release mounts the whole cache as converted.pck (SkynetPaths
	# .PACKS) — same res://converted path, but read-only.
	if SkynetPaths.pack_mounted("converted"):
		root = "res://converted"
		read_only = true
	# Outside the editor a PortableCompressedTexture2D drops its source
	# buffer right after decoding it — and then saves as an EMPTY texture.
	PortableCompressedTexture2D.set_keep_all_compressed_buffers(true)
	_check_version()
	print("[assets] cache at %s%s" % [root, " (read-only pack)" if read_only else ""])

## The data directory changed (first-start prompt): move to its cache.
func relocate() -> void:
	if not enabled or read_only:
		return
	var r := SkynetPaths.converted_dir()
	if r == root:
		return
	root = r
	_mem.clear()
	_tex_files.clear()
	_check_version()
	print("[assets] cache moved to %s" % root)

func _exit_tree() -> void:
	# Drop the session references before the servers shut down.
	_mem.clear()
	_tex_files.clear()

## Wipe the cache when its format version changed.
func _check_version() -> void:
	var vpath := root + "/VERSION"
	var f := FileAccess.open(vpath, FileAccess.READ)
	if f != null:
		var v: int = int(f.get_line().strip_edges())
		f.close()
		if v == CACHE_VERSION:
			return
		if read_only:
			# A packed cache from an older build: report it and run on,
			# the entries that still load are still valid to load.
			push_warning("[assets] packed cache is version %d, this build wants %d — rebuild it" % [v, CACHE_VERSION])
			return
		print("[assets] cache version %d != %d — rebuilding" % [v, CACHE_VERSION])
		_wipe(root)
	elif read_only:
		return
	DirAccess.make_dir_recursive_absolute(root)
	var w := FileAccess.open(vpath, FileAccess.WRITE)
	if w != null:
		w.store_line(str(CACHE_VERSION))
		w.close()

func _wipe(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			_wipe(dir + "/" + n)
			DirAccess.remove_absolute(dir + "/" + n)
		else:
			DirAccess.remove_absolute(dir + "/" + n)
		n = d.get_next()
	d.list_dir_end()

## Remove the whole cache (OPTIONS → rebuild data).
func clear() -> void:
	if root.is_empty() or read_only:
		return
	_wipe(root)
	_mem.clear()
	_check_version()

## The shared game palette (SKYNET.COL).
func palette() -> PackedColorArray:
	if _palette.is_empty():
		_palette = Palette.parse(SkynetPaths.palette_bytes())
	return _palette

# ---------------------------------------------------------------------
# Generic load-or-build
# ---------------------------------------------------------------------
func _path(kind: String, key: String) -> String:
	return "%s/%s/%s.res" % [root, kind, key.to_upper().replace("/", "_")]

## Return the cached resource for `kind/key`, building it with
## `builder` (→ Resource or null) and saving it on a miss.
func fetch(kind: String, key: String, builder: Callable) -> Resource:
	if not enabled:
		return builder.call()
	var p := _path(kind, key)
	if _mem.has(p):
		return _mem[p]
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REUSE)
		if r != null:
			hits += 1
			_mem[p] = r
			return r
	misses += 1
	var built: Resource = builder.call()
	if built != null and not read_only:
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		var err := ResourceSaver.save(built, p, SAVE_FLAGS)
		if err != OK:
			push_warning("[assets] cannot save %s (%s)" % [p, error_string(err)])
		else:
			# Later saves (a mesh's material → this texture) must reference
			# the file, not embed a copy.
			built.take_over_path(p)
	_mem[p] = built
	return built

# ---------------------------------------------------------------------
# Textures — TEXTURE.NNN records
# ---------------------------------------------------------------------
func _tex_file(bank: int) -> TextureNNN.TexFile:
	if _tex_files.has(bank):
		var v = _tex_files[bank]
		return v if v is TextureNNN.TexFile else null
	var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path("TEXTURE.%03d" % bank))
	var t: TextureNNN.TexFile = TextureNNN.parse(bytes) if not bytes.is_empty() else null
	_tex_files[bank] = t if t != null else false
	return t

## Record `rec` of TEXTURE.<bank> as a saveable texture; index 0 is
## transparent when `transparent0` (billboard sprites).
func texture(bank: int, rec: int, transparent0: bool = false) -> Texture2D:
	var key := "T%03d_%03d%s" % [bank, rec, "_A" if transparent0 else ""]
	var r: Resource = fetch("tex", key, func() -> Resource:
		var img: Image = _texture_image(bank, rec, transparent0)
		if img == null:
			return null
		return _portable(img))
	return r as Texture2D

## The DOS record as an Image.
func _texture_image(bank: int, rec: int, transparent0: bool) -> Image:
	var t := _tex_file(bank)
	if t == null or t.records.is_empty():
		return null
	var ri: int = clampi(rec, 0, t.records.size() - 1)
	return TextureNNN.to_image(t.records[ri], palette(), transparent0)

## World size per texel for a billboard of this record: the DOS sprite
## is SPRITE_PIXEL_SIZE units per DOS pixel whatever resolution the
## texture has.
func sprite_pixel_size(bank: int, rec: int, tex: Texture2D, dos_pixel: float) -> float:
	if tex == null or tex.get_height() <= 0:
		return dos_pixel
	return dos_pixel * float(record_size(bank, rec).y) / float(tex.get_height())

## Number of records in TEXTURE.<bank> (0 when the file is missing).
func record_count(bank: int) -> int:
	var t := _tex_file(bank)
	return t.records.size() if t != null else 0

## Native DOS pixel size of a record (the UV divisor).
func record_size(bank: int, rec: int) -> Vector2i:
	var t := _tex_file(bank)
	if t == null or t.records.is_empty():
		return Vector2i(64, 64)
	var ri: int = clampi(rec, 0, t.records.size() - 1)
	var rr: TextureNNN.Record = t.records[ri]
	if rr == null or rr.width <= 0:
		return Vector2i(64, 64)
	return Vector2i(rr.width, rr.height)

## A saveable texture from an Image. (Never go through ImageTexture:
## on the headless renderer get_image() comes back empty.)
static func _portable(img: Image) -> PortableCompressedTexture2D:
	var pct := PortableCompressedTexture2D.new()
	pct.keep_compressed_buffer = true
	pct.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	return pct

## Provider callable for Mesh3D.build_textured_array_mesh.
func provide(bank: int, rec: int) -> Dictionary:
	var tex := texture(bank, rec, false)
	if tex == null:
		return {}
	return {"texture": tex, "size": record_size(bank, rec)}

# ---------------------------------------------------------------------
# Meshes
# ---------------------------------------------------------------------
## Read a .3D by name from MDMDOBJS.BSA, then MDMDENMS.BSA.
func read_3d(name: String) -> PackedByteArray:
	for arc in ["MDMDOBJS.BSA", "MDMDENMS.BSA"]:
		var b := BSAReader.new()
		if b.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
			var bytes := b.read(name)
			b.close()
			if not bytes.is_empty():
				return bytes
	return PackedByteArray()

## Static textured ArrayMesh for `name` ("BIGDOOR.3D"). `bytes` may be
## supplied by a caller that already has the archive open.
func mesh(name: String, bytes: PackedByteArray = PackedByteArray()) -> ArrayMesh:
	var key := name.get_basename()
	return fetch("mesh", key, func() -> Resource:
		var data := bytes if not bytes.is_empty() else read_3d(name)
		if data.is_empty():
			return null
		var parsed: Mesh3D.Mesh3D = Mesh3D.parse(data, key)
		if parsed == null:
			return null
		return Mesh3D.build_textured_array_mesh(parsed, Callable(self, "provide"))) as ArrayMesh

## Every animation frame of `name` as an Array of ArrayMesh.
func mesh_frames(name: String, bytes: PackedByteArray = PackedByteArray()) -> Array:
	var key := name.get_basename()
	var pack: Resource = fetch("frames", key, func() -> Resource:
		var data := bytes if not bytes.is_empty() else read_3d(name)
		if data.is_empty():
			return null
		var parsed: Mesh3D.Mesh3D = Mesh3D.parse(data, key)
		if parsed == null:
			return null
		var frames := Mesh3D.build_frame_meshes(parsed, Callable(self, "provide"))
		if frames.is_empty():
			return null
		var fp := FramePack.new()
		fp.frames = frames
		return fp)
	if pack is FramePack:
		return (pack as FramePack).frames
	return []

# ---------------------------------------------------------------------
# Terrain
# ---------------------------------------------------------------------
## Terrain mesh of WLD.<suffix>; `wld` is the parsed file (heights are
## still needed at runtime), tiles come from TEXTURE.302.
func terrain(suffix: String, wld: WldTerrain.WLD) -> ArrayMesh:
	return fetch("terrain", "WLD." + suffix, func() -> Resource:
		if wld == null:
			return null
		var tiles: Array = []
		var t302 := _tex_file(302)
		if t302 != null:
			for i in t302.records.size():
				var rec: TextureNNN.Record = t302.records[i]
				var ok: bool = rec != null and not rec.pixels.is_empty()
				tiles.append(texture(302, i, false) if ok else null)
		return WldTerrain.build_terrain_mesh(wld, tiles)) as ArrayMesh

## The collision shape of a mesh, shared by every copy of it in every
## map (converted/shape/<key>.res). The level used to call
## MeshInstance3D.create_trimesh_collision() per entity, which walks the
## faces and builds a private ConcavePolygonShape3D — MAP.240 did that
## 410 times, for maybe 120 distinct meshes.
##
## backface_collision is on for all of them: DOS meshes are drawn
## double-sided and their winding is arbitrary (the 210TOWER deck floor
## faces down), so a one-sided shape lets rays and bodies through.
func shape(key: String, mesh: Mesh) -> ConcavePolygonShape3D:
	return fetch("shape", key, func() -> Resource:
		if mesh == null:
			return null
		var sh: ConcavePolygonShape3D = mesh.create_trimesh_shape()
		if sh == null:
			return null
		sh.backface_collision = true
		return sh) as ConcavePolygonShape3D

# ---------------------------------------------------------------------
# Sounds / CFA
# ---------------------------------------------------------------------
## Decoded clip from MDMDSFXS.BSA (`builder` does the decoding — Audio
## owns the parsers).
func sound(name: String, loop: bool, builder: Callable) -> AudioStreamWAV:
	return fetch("sfx", name + ("_L" if loop else ""), builder) as AudioStreamWAV

## Viewmodel frames of a WEAPONnn.CFA as Array[Texture2D].
## `hires`: take the frame from the 640x480 set in MDMDHRES.BSA when it
## has one (the weapon viewmodels do), falling back to the 320x200 art.
## The two sets are cached apart — same key, different kind — or the
## first one built would answer for both.
func cfa_frames(name: String, hires: bool = false) -> Array:
	var pack: Resource = fetch("cfa_hi" if hires else "cfa", name, func() -> Resource:
		var imgs := BSAReader.new()
		var arcs: Array = ["MDMDHRES.BSA", "MDMDIMGS.BSA"] if hires else ["MDMDIMGS.BSA"]
		# Take the first archive whose copy actually PARSES, not merely the
		# first that holds the name: a set this loader cannot read has to
		# fall through to the other one. Until 2026-09-12 the 640x480
		# WEAPON*.CFA parsed to nothing and the player was left holding an
		# invisible gun, with no warning anywhere.
		for arc in arcs:
			if not imgs.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
				continue
			var bytes: PackedByteArray = imgs.read(name)
			imgs.close()
			if bytes.is_empty():
				continue
			var frames: Array = CFAFile.parse(bytes, palette(), true)
			if frames.is_empty():
				push_warning("[cfa] %s in %s did not parse — trying the next set"
					% [name, arc])
				continue
			var fp := FramePack.new()
			for f in frames:
				if f is Image:
					fp.frames.append(_portable(f))
			return fp
		return null)
	if pack is FramePack:
		return (pack as FramePack).frames
	return []

## Is `name`'s 640x480 copy the one a hi-res request would actually draw?
## The caller needs this to SCALE the art — the two sets are authored for
## a 320- and a 480-line screen — and the frame's own width cannot say:
## WEAPON13's hi-res art is 145x194, narrower than several of the 320x200
## viewmodels. Reads the archive record's header only (48 bytes), never
## the frames, so a warm disk cache still gets a straight answer; memoised
## per session.
static var _cfa_hires_memo: Dictionary = {}
static var _cfa_offset_memo: Dictionary = {}
func cfa_is_hires(name: String) -> bool:
	if _cfa_hires_memo.has(name):
		return bool(_cfa_hires_memo[name])
	_read_hires_header(name)
	return bool(_cfa_hires_memo.get(name, false))

## The 640x480 art's own x/y placement, (0, 0) when it has none.
func cfa_offset(name: String) -> Vector2i:
	if not _cfa_offset_memo.has(name):
		_read_hires_header(name)
	return _cfa_offset_memo.get(name, Vector2i.ZERO)

func _read_hires_header(name: String) -> void:
	var hires: bool = false
	var off := Vector2i.ZERO
	var b := BSAReader.new()
	if b.open(SkynetPaths.gamedata_path("MDMDHRES.BSA"), SkynetPaths.variant):
		var bytes: PackedByteArray = b.read(name)
		b.close()
		hires = CFAFile.is_hires(bytes)
		if hires:
			off = CFAFile.hires_offset(bytes)
	_cfa_hires_memo[name] = hires
	_cfa_offset_memo[name] = off

## Editor scene of a map (built on demand, saved under converted/maps/).
## The editor cannot use resources outside res://, so the project keeps
## a link `res://converted` → the cache directory (a directory junction
## the SkyNET Maps dock creates). Map scenes are built through that
## link: every mesh/texture they reference is then a res:// path.
func use_project_link() -> bool:
	if root.begins_with("res://"):
		return true
	# The link points at the SkyNET cache; a Future Shock bake must stay
	# in its own directory (its record numbers collide with SkyNET's).
	if SkynetPaths.game != "skynet":
		return false
	if not DirAccess.dir_exists_absolute("res://converted"):
		return false
	var probe := "res://converted/VERSION"
	if not FileAccess.file_exists(probe):
		return false
	root = "res://converted"
	_mem.clear()
	print("[assets] cache via project link %s" % ProjectSettings.globalize_path(root))
	return true

## Editor map scenes carry a build number; when map_scene.gd changes what
## it puts in them (sprite sizing, say) every cached one is dropped in
## one go rather than being checked scene by scene.
var _map_scenes_checked: bool = false

func _check_map_scenes() -> void:
	if _map_scenes_checked or root.is_empty() or read_only or not enabled:
		return
	_map_scenes_checked = true
	var stamp := root + "/maps/VERSION"
	var have: int = -1
	var f := FileAccess.open(stamp, FileAccess.READ)
	if f != null:
		have = int(f.get_line().strip_edges())
		f.close()
	if have == MapScene.BUILD_VERSION:
		return
	var d := DirAccess.open(root + "/maps")
	if d != null:
		var n := 0
		for fn in d.get_files():
			if fn.ends_with(".scn") and not fn.ends_with(".level.scn"):
				d.remove(fn)
				n += 1
		if n > 0:
			print("[assets] %d editor map scenes are from build %d, dropped" % [n, have])
	DirAccess.make_dir_recursive_absolute(root + "/maps")
	var w := FileAccess.open(stamp, FileAccess.WRITE)
	if w != null:
		w.store_line(str(MapScene.BUILD_VERSION))
		w.close()

func map_scene(map_name: String) -> String:
	_check_map_scenes()
	var old_root: String = root
	var linked: bool = use_project_link()
	var p := MapScene.scene_path(map_name)
	if linked and root != old_root:
		root = old_root
		_mem.clear()
	if ResourceLoader.exists(p):
		hits += 1
		return p
	misses += 1
	return MapScene.save(map_name)

## Bake the level scene for `map_name` (scripts/level_scene.gd) —
## terrain, static geometry with its collision and the occluders. Loading
## the map writes it as a side effect, so this just makes the loader run.
func level_scene(map_name: String) -> String:
	var p := LevelScene.scene_path(map_name)
	if p.is_empty():
		return ""
	if ResourceLoader.exists(p):
		hits += 1
		return p
	misses += 1
	var loader = load("res://scripts/level_loader.gd").new()
	var lvl = loader.load_level(map_name)
	if lvl == null:
		return ""
	for n in [lvl.terrain, lvl.entities, lvl.enemies, lvl.sprites, lvl.sky,
			lvl.occluders, lvl.overlay, lvl.behaviour]:
		if n != null and is_instance_valid(n):
			n.free()
	return p if ResourceLoader.exists(p) else ""

## Run `what` with the cache addressed through the project link (when
## there is one) so every resource it touches gets a res:// path, then
## return to the direct path for the rest of this process.
func with_project_link(what: Callable) -> Variant:
	var old_root: String = root
	var linked: bool = use_project_link()
	var out: Variant = what.call()
	if linked and root != old_root:
		root = old_root
		_mem.clear()
	return out

# ---------------------------------------------------------------------
# Full conversion pass
# ---------------------------------------------------------------------
## Convert everything the game can use up front. `progress` receives
## (done: int, total: int, label: String); yields between items so a
## caller can draw a progress screen. Returns the number of items.
func import_all(progress: Callable = Callable()) -> int:
	if not enabled:
		return 0
	var jobs: Array = []                       # [label, Callable]
	# Meshes: every .3D in both archives (frames for the enemy archive).
	for arc in ["MDMDOBJS.BSA", "MDMDENMS.BSA"]:
		var b := BSAReader.new()
		if b.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
			for e in b.entries():
				var nm: String = e.name.to_upper()
				if not nm.ends_with(".3D"):
					continue
				if arc == "MDMDENMS.BSA":
					jobs.append([nm, func() -> void: mesh_frames(nm)])
				else:
					jobs.append([nm, func() -> void: mesh(nm)])
			b.close()
	# Terrains.
	var d := DirAccess.open(SkynetPaths.gamedata_dir)
	if d != null:
		for fn in d.get_files():
			if fn.to_upper().begins_with("WLD."):
				var sfx: String = fn.split(".")[1]
				jobs.append([fn, func() -> void:
					var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path(fn))
					if not bytes.is_empty():
						terrain(sfx, WldTerrain.parse(bytes))])
	# Sounds.
	var sfx := BSAReader.new()
	if sfx.open(SkynetPaths.gamedata_path("MDMDSFXS.BSA"), SkynetPaths.variant):
		for e in sfx.entries():
			var snd: String = e.name.to_upper()
			jobs.append([snd, func() -> void: Audio.stream(snd)])
		sfx.close()
	# Weapon viewmodels.
	for i in 14:
		var cfa := "WEAPON%02d.CFA" % i
		jobs.append([cfa, func() -> void: cfa_frames(cfa)])
	# Map scenes, two per MAP: the editor's data view
	# (converted/maps/MAP.NNN.scn — one node per MAP record, what the
	# SkyNET Maps dock edits and exports) and the level itself
	# (MAP.NNN.level.scn — the world in Godot's own format, which is
	# what the game loads). Both are built here so the first run pays
	# for the whole conversion and nothing is derived during play.
	var maps := BSAReader.new()
	if maps.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		for e in maps.entries():
			var mn: String = e.name.to_upper()
			if mn.begins_with("MAP."):
				jobs.append([mn, func() -> void: map_scene(mn)])
				jobs.append([mn + " (level)", func() -> void: level_scene(mn)])
		maps.close()

	var t0 := Time.get_ticks_msec()
	var done := 0
	for j in jobs:
		(j[1] as Callable).call()
		done += 1
		if progress.is_valid():
			progress.call(done, jobs.size(), String(j[0]))
		if is_inside_tree() and (done % 4) == 0:
			await get_tree().process_frame
	print("[assets] imported %d items in %.1f s (%d built, %d cached)"
		% [done, (Time.get_ticks_msec() - t0) / 1000.0, misses, hits])
	return done
