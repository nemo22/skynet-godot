## TEXTURE.NNN atlas viewer.
## Enumerates every TEXTURE.* in GAMEDATA, parses with TextureNNN, and lays
## every record out in a scrollable flow grid. Each tile is labelled
## "NNN/R  WxH  name".

extends Control

const ViewerExit := preload("res://scripts/viewer_exit.gd")

const BSAReader  := preload("res://scripts/loaders/bsa_reader.gd")
const Palette    := preload("res://scripts/loaders/palette.gd")
const TextureNNN := preload("res://scripts/loaders/texture_nnn.gd")

const TILE_SIZE: int = 96   ## displayed size of each texture tile (square)
const FILES_PER_FRAME: int = 4

@onready var status: Label = $StatusBar
@onready var flow: HFlowContainer = $Scroll/Flow

var _palette: PackedColorArray
var _files: PackedStringArray
var _idx: int = 0
var _records_total: int = 0
var _records_failed: int = 0

func _ready() -> void:
	ViewerExit.add_hint(self)
	# Load the shared palette from MDMDIMGS.BSA.
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
		status.text = "ERROR opening MDMDIMGS.BSA"
		return
	var pal_bytes := SkynetPaths.palette_bytes()
	imgs.close()
	_palette = Palette.parse(pal_bytes)
	if _palette.is_empty():
		status.text = "ERROR loading palette"
		return

	# Enumerate TEXTURE.* on disk.
	_files = _list_texture_files(SkynetPaths.gamedata_dir)
	status.text = "loaded palette, %d TEXTURE.* files queued" % _files.size()

func _process(_delta: float) -> void:
	if _idx >= _files.size():
		return
	var batch_end: int = min(_idx + FILES_PER_FRAME, _files.size())
	while _idx < batch_end:
		_load_one(_files[_idx])
		_idx += 1
	status.text = "TEXTURE files %d / %d   records loaded: %d (failed: %d)" \
		% [_idx, _files.size(), _records_total, _records_failed]
	if _idx >= _files.size():
		print("[atlas] done: %d files, %d records loaded (%d failed)"
			% [_files.size(), _records_total, _records_failed])

func _list_texture_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir_path)
	if d == null:
		push_error("[atlas] cannot open %s" % dir_path)
		return out
	d.list_dir_begin()
	while true:
		var n := d.get_next()
		if n.is_empty(): break
		if d.current_is_dir(): continue
		if n.begins_with("TEXTURE."):
			out.append(n)
	d.list_dir_end()
	out.sort()
	return out

func _load_one(filename: String) -> void:
	# "TEXTURE.NNN" -> archive id NNN
	var suffix := filename.get_extension()
	var archive_id := suffix.to_int()
	var path := SkynetPaths.gamedata_path(filename)
	var bytes := SkynetPaths.read_bytes(path)
	if bytes.is_empty():
		_records_failed += 1
		return
	var tex: TextureNNN.TexFile = TextureNNN.parse(bytes)
	if tex == null or tex.records.is_empty():
		_records_failed += 1
		return
	for r in tex.records.size():
		var rec: TextureNNN.Record = tex.records[r]
		var img_tex: ImageTexture = TextureNNN.to_image_texture(rec, _palette)
		if img_tex == null:
			_records_failed += 1
			continue
		flow.add_child(_make_tile(archive_id, r, tex.name, rec.width, rec.height, img_tex))
		_records_total += 1

func _make_tile(arch: int, rec: int, name: String, w: int, h: int,
		t: ImageTexture) -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(TILE_SIZE + 8, TILE_SIZE + 32)
	box.add_theme_constant_override("separation", 2)

	var tr := TextureRect.new()
	tr.texture = t
	tr.custom_minimum_size = Vector2(TILE_SIZE, TILE_SIZE)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	box.add_child(tr)

	var lbl := Label.new()
	lbl.text = "%03d/%d  %s\n%dx%d" % [arch, rec, name, w, h]
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(lbl)
	return box

func _unhandled_input(event: InputEvent) -> void:
	if ViewerExit.handled(self, event):
		return
