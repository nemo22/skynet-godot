## Sound browser for MDMDSFXS.BSA. Lists every .RAW and .WAV; clicking
## one (or pressing Enter on it) plays the clip through a single
## AudioStreamPlayer. .RAW files are unsigned 8-bit mono PCM at 11025 Hz.

extends Control

const ViewerExit := preload("res://scripts/viewer_exit.gd")

const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")

const RAW_SAMPLE_RATE: int = 11025

@onready var list:   ItemList            = $V/Split/List
@onready var info:   Label               = $V/Split/Right/Info
@onready var status: Label               = $V/Status
@onready var player: AudioStreamPlayer   = $Player

var _bsa: BSAReader
var _names: Array[String] = []
var _selected: int = -1

func _ready() -> void:
	ViewerExit.add_hint(self)
	_bsa = BSAReader.new()
	if not _bsa.open(SkynetPaths.gamedata_path("MDMDSFXS.BSA"), SkynetPaths.variant):
		status.text = "ERROR opening MDMDSFXS.BSA"; return
	for e in _bsa.entries():
		var ext: String = e.name.get_extension().to_upper()
		if ext == "RAW" or ext == "WAV":
			_names.append(e.name)
	_names.sort()
	for n in _names:
		list.add_item(n)
	status.text = "%d sounds loaded   double-click or Enter to play   Esc back" % _names.size()
	if _names.size() > 0:
		list.select(0)
		_selected = 0
		_show_info(0)
	list.item_selected.connect(_on_selected)
	list.item_activated.connect(_on_activated)

func _exit_tree() -> void:
	if _bsa: _bsa.close()

func _on_selected(idx: int) -> void:
	_selected = idx
	_show_info(idx)

func _on_activated(idx: int) -> void:
	_selected = idx
	_show_info(idx)
	_play(idx)

func _unhandled_input(event: InputEvent) -> void:
	if ViewerExit.handled(self, event):
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ENTER, KEY_SPACE:
				if _selected >= 0: _play(_selected)

func _show_info(idx: int) -> void:
	if idx < 0 or idx >= _names.size(): return
	var fn: String = _names[idx]
	var ext := fn.get_extension().to_upper()
	var bytes := _bsa.read(fn)
	var n := bytes.size()
	var dur: float = 0.0
	if ext == "RAW":
		dur = float(n) / float(RAW_SAMPLE_RATE)
		info.text = "%s\n%d bytes   8-bit unsigned mono @ %d Hz\nduration ≈ %.2f s" % [
			fn, n, RAW_SAMPLE_RATE, dur]
	elif ext == "WAV":
		# RIFF/WAVE: sample rate at +24, bits at +34, channels at +22
		if n >= 44:
			var sr: int = bytes[24] | (bytes[25] << 8) | (bytes[26] << 16) | (bytes[27] << 24)
			var ch: int = bytes[22] | (bytes[23] << 8)
			var bits: int = bytes[34] | (bytes[35] << 8)
			var data_size: int = bytes[40] | (bytes[41] << 8) | (bytes[42] << 16) | (bytes[43] << 24)
			@warning_ignore("integer_division")
			var byte_per_sample: int = max(1, ch * bits / 8)
			dur = float(data_size) / float(sr * byte_per_sample) if sr > 0 else 0.0
			info.text = "%s\n%d bytes   %d-bit %s @ %d Hz\nduration ≈ %.2f s" % [
				fn, n, bits, "stereo" if ch == 2 else "mono", sr, dur]
		else:
			info.text = "%s\n%d bytes   (header too short)" % [fn, n]

func _play(idx: int) -> void:
	if idx < 0 or idx >= _names.size(): return
	var fn: String = _names[idx]
	var ext := fn.get_extension().to_upper()
	var bytes := _bsa.read(fn)
	var stream: AudioStreamWAV
	if ext == "RAW":
		stream = AudioStreamWAV.new()
		stream.format = AudioStreamWAV.FORMAT_8_BITS
		stream.mix_rate = RAW_SAMPLE_RATE
		stream.stereo = false
		# Convert unsigned 8-bit (centered at 0x80) to signed 8-bit for Godot.
		var signed_bytes := PackedByteArray()
		signed_bytes.resize(bytes.size())
		for i in bytes.size():
			signed_bytes[i] = (bytes[i] - 128) & 0xFF
		stream.data = signed_bytes
	elif ext == "WAV":
		# Godot has no direct in-memory WAV parser, parse minimal RIFF.
		stream = _parse_wav(bytes)
		if stream == null:
			status.text = "WAV parse failed: %s" % fn
			return
	else:
		return
	player.stream = stream
	player.play()
	status.text = "playing %s" % fn

func _parse_wav(b: PackedByteArray) -> AudioStreamWAV:
	if b.size() < 44: return null
	if b[0] != 0x52 or b[1] != 0x49 or b[2] != 0x46 or b[3] != 0x46: return null  # RIFF
	if b[8] != 0x57 or b[9] != 0x41 or b[10] != 0x56 or b[11] != 0x45: return null  # WAVE
	var fmt_code: int = b[20] | (b[21] << 8)
	if fmt_code != 1: return null  # PCM only
	var ch: int = b[22] | (b[23] << 8)
	var sr: int = b[24] | (b[25] << 8) | (b[26] << 16) | (b[27] << 24)
	var bits: int = b[34] | (b[35] << 8)
	# Find "data" chunk
	var off: int = 12
	while off + 8 <= b.size():
		var id := b.slice(off, off + 4).get_string_from_ascii()
		var sz: int = b[off + 4] | (b[off + 5] << 8) | (b[off + 6] << 16) | (b[off + 7] << 24)
		off += 8
		if id == "data":
			var data := b.slice(off, off + sz)
			var stream := AudioStreamWAV.new()
			stream.mix_rate = sr
			stream.stereo = (ch == 2)
			if bits == 8:
				stream.format = AudioStreamWAV.FORMAT_8_BITS
				# WAV 8-bit is unsigned; Godot wants signed.
				var signed := PackedByteArray()
				signed.resize(data.size())
				for i in data.size():
					signed[i] = (data[i] - 128) & 0xFF
				stream.data = signed
			elif bits == 16:
				stream.format = AudioStreamWAV.FORMAT_16_BITS
				stream.data = data
			else:
				return null
			return stream
		off += sz
	return null
