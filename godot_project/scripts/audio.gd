## Autoload: game audio — sound effects and ambient loops.
##
## Sound effects live in MDMDSFXS.BSA: mostly 8-bit unsigned mono PCM
## .RAW clips at 11025 Hz, plus a few RIFF/WAVE .WAV. Music is .XMI
## (Miles MIDI) in MDMDMUSC.BSA — not played yet (needs XMI→MIDI + synth).

extends Node

const SFX_BSA: String = "MDMDSFXS.BSA"
const RAW_RATE: int = 11025
const SFX_VOICES: int = 6
const AUDIO_CFG: String = "user://audio.cfg"

var _bsa = null                       # BSAReader, kept open for the session
var _cache: Dictionary = {}           # key -> AudioStreamWAV
var _voices: Array[AudioStreamPlayer] = []
var _voices3d: Array[AudioStreamPlayer3D] = []
var _ambient: AudioStreamPlayer = null
## Master volume, 0..1 — set from the OPTIONS menu, persisted.
var master_volume: float = 0.7

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AUDIO_CFG) == OK:
		master_volume = clampf(
			float(cfg.get_value("audio", "master", 0.7)), 0.0, 1.0)
	_apply_master()
	_bsa = preload("res://scripts/loaders/bsa_reader.gd").new()
	if not _bsa.open(SkynetPaths.gamedata_path(SFX_BSA), SkynetPaths.variant):
		push_warning("[audio] cannot open %s — sound disabled" % SFX_BSA)
		_bsa = null
	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_voices.append(p)
		# Positional voice pool — panned/attenuated by source location.
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = 2000.0
		p3.max_distance = 22000.0
		p3.max_db = 0.0
		add_child(p3)
		_voices3d.append(p3)
	_ambient = AudioStreamPlayer.new()
	add_child(_ambient)

## Decode a .RAW / .WAV clip into an AudioStreamWAV (cached in memory
## and, through the asset cache, on disk).
func _load(name: String, loop: bool) -> AudioStreamWAV:
	var key := name.to_upper() + ("#L" if loop else "")
	if _cache.has(key):
		return _cache[key]
	if _bsa == null:
		return null
	var s: AudioStreamWAV = Assets.sound(name, loop,
		func() -> Resource: return _decode(name, loop))
	if s != null:
		_cache[key] = s
	return s

func _decode(name: String, loop: bool) -> AudioStreamWAV:
	var bytes: PackedByteArray = _bsa.read(name)
	if bytes.is_empty():
		return null
	var s: AudioStreamWAV
	if name.to_upper().ends_with(".WAV"):
		s = _parse_wav(bytes)
	else:
		# DOS .RAW: unsigned 8-bit mono — Godot wants signed.
		s = AudioStreamWAV.new()
		s.format = AudioStreamWAV.FORMAT_8_BITS
		s.mix_rate = RAW_RATE
		s.stereo = false
		var signed := PackedByteArray()
		signed.resize(bytes.size())
		for i in bytes.size():
			signed[i] = (bytes[i] - 128) & 0xFF
		s.data = signed
		if loop:
			s.loop_mode = AudioStreamWAV.LOOP_FORWARD
			s.loop_begin = 0
			s.loop_end = signed.size()        # 8-bit mono: 1 byte == 1 frame
	return s

## Minimal RIFF/WAVE (PCM) parser.
func _parse_wav(b: PackedByteArray) -> AudioStreamWAV:
	if b.size() < 44:
		return null
	if b.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	if b.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null
	if (b[20] | (b[21] << 8)) != 1:
		return null                              # PCM only
	var ch: int = b[22] | (b[23] << 8)
	var sr: int = b[24] | (b[25] << 8) | (b[26] << 16) | (b[27] << 24)
	var bits: int = b[34] | (b[35] << 8)
	var off: int = 12
	while off + 8 <= b.size():
		var id := b.slice(off, off + 4).get_string_from_ascii()
		var sz: int = b[off + 4] | (b[off + 5] << 8) \
			| (b[off + 6] << 16) | (b[off + 7] << 24)
		off += 8
		if id == "data":
			var data := b.slice(off, off + mini(sz, b.size() - off))
			var s := AudioStreamWAV.new()
			s.mix_rate = sr
			s.stereo = (ch == 2)
			if bits == 8:
				s.format = AudioStreamWAV.FORMAT_8_BITS
				var sg := PackedByteArray()
				sg.resize(data.size())
				for i in data.size():
					sg[i] = (data[i] - 128) & 0xFF
				s.data = sg
			else:
				s.format = AudioStreamWAV.FORMAT_16_BITS
				s.data = data
			return s
		off += sz + (sz & 1)
	return null

## Public: a decoded one-shot stream (for positional enemy players).
func stream(name: String) -> AudioStreamWAV:
	return _load(name, false)

## Play a one-shot sound effect through a free voice (2D, non-positional).
func play_sfx(name: String, volume_db: float = 0.0) -> void:
	var s := _load(name, false)
	if s == null:
		return
	for p in _voices:
		if not p.playing:
			p.stream = s
			p.volume_db = volume_db
			p.play()
			return
	_voices[0].stream = s
	_voices[0].volume_db = volume_db
	_voices[0].play()

## Play a one-shot sound at a world position — panned and attenuated by
## its location relative to the camera/listener. Use for doors, weapons,
## explosions, impacts and any other sound that has a place in the world.
func play_sfx_3d(name: String, world_pos: Vector3, volume_db: float = -6.0) -> void:
	var s := _load(name, false)
	if s == null:
		return
	var pick: AudioStreamPlayer3D = _voices3d[0]
	for p in _voices3d:
		if not p.playing:
			pick = p
			break
	pick.stream = s
	pick.global_position = world_pos
	pick.volume_db = volume_db
	pick.play()

## Start a looping ambient bed (replaces any current one).
func play_ambient(name: String, volume_db: float = -13.0) -> void:
	var s := _load(name, true)
	if s == null:
		return
	if _ambient.stream == s and _ambient.playing:
		return
	_ambient.stream = s
	_ambient.volume_db = volume_db
	_ambient.play()

func stop_ambient() -> void:
	if _ambient != null:
		_ambient.stop()

## --- master volume -------------------------------------------------

func _apply_master() -> void:
	var db: float = linear_to_db(master_volume) if master_volume > 0.001 else -60.0
	AudioServer.set_bus_volume_db(0, db)        # bus 0 = Master

func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	_apply_master()
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.save(AUDIO_CFG)

## --- DOS sound-id table ---------------------------------------------
## Skynet.exe VA 0x4ff00: 126 × 20-byte records, field 0 = pointer
## (+0x30000) to the 8.3 filename. Every id-based sound reference in the
## engine indexes this table: weapon records (+0x48 fire / +0x54 select /
## +0x58 dry-fire), ammo types (+0x1c fire, +0x20 impact), the action
## table's one-shot sound nodes (0xdb..0xec) and AI frame events.
const SOUND_IDS: PackedStringArray = [
	"pipehit1.raw", "shots5.raw", "shots2.raw", "shots3.raw", "shtgun.raw",
	"sgcock1.raw", "sgcock2.raw", "grnlaun2.raw", "rocket2.raw", "uzicock3.raw",
	"click.raw", "laser1.raw", "laser2.raw", "laser8.raw", "laser6.raw",
	"laser3.raw", "fizzle1.raw", "ppcload.raw", "grunt1.raw", "geiger1.raw",
	"geiger2.raw", "heart1.raw", "heart2.raw", "jmpcon.raw", "jmpmet.raw",
	"jmpwod.raw", "rocket1.raw", "collide1.raw", "hit2.raw", "skid2.raw",
	"carcoll2.raw", "richo5.raw", "richo8.raw", "explo1.raw", "explo2.raw",
	"explo3.raw", "explo4.raw", "explo5.raw", "gauss1.raw", "ppc100.raw",
	"doora.raw", "doorb.raw", "doorc.raw", "doord.raw", "doorw.raw",
	"button1.raw", "button2.raw", "lever1.raw", "hk2.raw", "hk2.raw",
	"hk2.raw", "hk2.raw", "hk2.raw", "hk2.raw", "hk2.raw",
	"tank1.raw", "tank1.raw", "tank1.raw", "hvyft5.raw", "hydra2.raw",
	"hydra5.raw", "hvyft4.raw", "press1.raw", "fire.raw", "amtech1.raw",
	"amtech2.raw", "amtech3.raw", "amtech4.raw", "hk2.raw", "careng1.raw",
	"lfwgrv.raw", "rfwgrv.raw", "lfwwod.raw", "rfwwod.raw", "lfwmet.raw",
	"rfwmet.raw", "explo6.raw", "elevat1.raw", "fastgun2.raw", "fastgun2.raw",
	"hydra3.raw", "comm1.raw", "swish1.raw", "fire.raw", "lfwsew.raw",
	"rfwsew.raw", "jmpsew.raw", "wind.raw", "windmet.raw", "windwod.raw",
	"bubbles.raw", "drips.raw", "water.raw", "metdoor.raw", "miltkill.raw",
	"miltdies.raw", "motfind1.raw", "motloop2.raw", "head1.raw", "head2.raw",
	"hitbycar.raw", "grunt2.raw", "grunt3.raw", "grunt4.raw", "grunt5.raw",
	"grunt6.raw", "grunt7.raw", "grunt8.raw", "grunt9.raw", "movedoor.wav",
	"ibeam.wav", "power1.wav", "watmove.wav", "subdoor.wav", "rap.wav",
	"splash.wav", "drown.wav", "getair.wav", "bubbles2.wav", "pings.wav",
	"subalarm.wav", "carstart.wav", "getair2.wav", "leftwatr.wav", "rightwtr.wav",
	"torpedo.wav",
]

## Archive filename for a DOS sound id, or "" when the id is out of range
## (-1 = "no sound" in every DOS table).
func sound_name(id: int) -> String:
	if id < 0 or id >= SOUND_IDS.size():
		return ""
	return SOUND_IDS[id]

## Play a DOS sound id at a world position (no-op for -1 / bad ids).
func play_id_3d(id: int, world_pos: Vector3, volume_db: float = -6.0) -> void:
	var n := sound_name(id)
	if not n.is_empty():
		play_sfx_3d(n, world_pos, volume_db)

## Play a DOS sound id non-positionally (player-side sounds).
func play_id(id: int, volume_db: float = 0.0) -> void:
	var n := sound_name(id)
	if not n.is_empty():
		play_sfx(n, volume_db)
