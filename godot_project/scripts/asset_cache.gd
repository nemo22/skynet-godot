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
## or the first-start prompt in the menu).

extends Node

const BSAReader  := preload("res://scripts/loaders/bsa_reader.gd")
const Palette    := preload("res://scripts/loaders/palette.gd")
const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")
const Mesh3D     := preload("res://scripts/loaders/mesh_3d.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")
const CFAFile    := preload("res://scripts/loaders/cfa_file.gd")
const FramePack  := preload("res://scripts/loaders/frame_pack.gd")
const MapScene   := preload("res://scripts/editor/map_scene.gd")

## Bump whenever a loader changes its output.
const CACHE_VERSION: int = 8
const SAVE_FLAGS: int = ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH

## Cache root ("" when disabled with --no-cache).
var root: String = ""
var enabled: bool = true
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
	# Outside the editor a PortableCompressedTexture2D drops its source
	# buffer right after decoding it — and then saves as an EMPTY texture.
	PortableCompressedTexture2D.set_keep_all_compressed_buffers(true)
	_check_version()
	print("[assets] cache at %s" % root)

## The data directory changed (first-start prompt): move to its cache.
func relocate() -> void:
	if not enabled:
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
		print("[assets] cache version %d != %d — rebuilding" % [v, CACHE_VERSION])
		_wipe(root)
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
	if root.is_empty():
		return
	_wipe(root)
	_mem.clear()
	_check_version()

## The shared game palette (SKYNET.COL).
func palette() -> PackedColorArray:
	if _palette.is_empty():
		var imgs := BSAReader.new()
		if imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
			var b := imgs.read("SKYNET.COL")
			if b.is_empty():
				b = imgs.read("BRIEF.COL")
			imgs.close()
			_palette = Palette.parse(b)
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
	if built != null:
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
		var t := _tex_file(bank)
		if t == null or t.records.is_empty():
			return null
		var ri: int = clampi(rec, 0, t.records.size() - 1)
		var img: Image = TextureNNN.to_image(t.records[ri], palette(), transparent0)
		if img == null:
			return null
		return _portable(img))
	return r as Texture2D

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
	return {"texture": tex, "size": Vector2i(tex.get_width(), tex.get_height())}

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
				tiles.append(texture(302, i, false) if rec != null and not rec.pixels.is_empty() else null)
		return WldTerrain.build_terrain_mesh(wld, tiles)) as ArrayMesh

# ---------------------------------------------------------------------
# Sounds / CFA
# ---------------------------------------------------------------------
## Decoded clip from MDMDSFXS.BSA (`builder` does the decoding — Audio
## owns the parsers).
func sound(name: String, loop: bool, builder: Callable) -> AudioStreamWAV:
	return fetch("sfx", name + ("_L" if loop else ""), builder) as AudioStreamWAV

## Viewmodel frames of a WEAPONnn.CFA as Array[Texture2D].
func cfa_frames(name: String) -> Array:
	var pack: Resource = fetch("cfa", name, func() -> Resource:
		var imgs := BSAReader.new()
		if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
			return null
		var bytes := imgs.read(name)
		imgs.close()
		if bytes.is_empty():
			return null
		var frames: Array = CFAFile.parse(bytes, palette(), true)
		if frames.is_empty():
			return null
		var fp := FramePack.new()
		for f in frames:
			if f is Image:
				fp.frames.append(_portable(f))
		return fp)
	if pack is FramePack:
		return (pack as FramePack).frames
	return []

## Editor scene of a map (built on demand, saved under converted/maps/).
func map_scene(map_name: String) -> String:
	var p := MapScene.scene_path(map_name)
	if ResourceLoader.exists(p):
		hits += 1
		return p
	misses += 1
	return MapScene.save(map_name)

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
	# Editor map scenes (converted/maps/MAP.NNN.scn) — every MAP.
	var maps := BSAReader.new()
	if maps.open(SkynetPaths.gamedata_path("MDMDMAP2.BSA"), SkynetPaths.variant):
		for e in maps.entries():
			var mn: String = e.name.to_upper()
			if mn.begins_with("MAP."):
				jobs.append([mn, func() -> void: map_scene(mn)])
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
