## Lazy cache of TEXTURE.NNN records, keyed by archive_id.
##
## Files are parsed on first request and kept in memory. Each record
## decodes to an ImageTexture only when fetched. Provides the Callable
## signature expected by Mesh3D.build_textured_array_mesh:
##   provider.call(archive_id, record_id) -> Dict {"texture", "size"}.

extends RefCounted

const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")

var palette: PackedColorArray = PackedColorArray()
var gamedata_root: String = ""
var _files: Dictionary = {}         ## archive_id -> TextureNNN.TexFile (or null on miss)
var _textures: Dictionary = {}      ## (archive_id<<7 | record_id) -> ImageTexture

func _init(p: PackedColorArray, root: String) -> void:
	palette = p
	gamedata_root = root

func _archive(archive_id: int) -> TextureNNN.TexFile:
	if _files.has(archive_id):
		return _files[archive_id]
	var path: String = "%s/TEXTURE.%03d" % [gamedata_root, archive_id]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_files[archive_id] = null
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		_files[archive_id] = null
		return null
	var t := TextureNNN.parse(bytes)
	_files[archive_id] = t
	return t

## Provider callable for Mesh3D.build_textured_array_mesh. Served from
## the converted-asset cache when it is enabled (decoded once, stored
## as a compressed texture resource); the in-memory decode is the
## fallback.
func provide(archive_id: int, record_id: int) -> Dictionary:
	if Assets.enabled:
		return Assets.provide(archive_id, record_id)
	var t := _archive(archive_id)
	if t == null or t.records.is_empty():
		return {}
	var ri: int = clamp(record_id, 0, t.records.size() - 1)
	var rec: TextureNNN.Record = t.records[ri]
	var key: int = (archive_id << 7) | ri
	var img_tex: ImageTexture = _textures.get(key, null)
	if img_tex == null:
		img_tex = TextureNNN.to_image_texture(rec, palette)
		_textures[key] = img_tex
	return {"texture": img_tex, "size": Vector2i(rec.width, rec.height), "name": t.name}
