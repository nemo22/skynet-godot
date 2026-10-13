## Autoload: game audio — sound effects and ambient loops.
##
## Sound effects live in MDMDSFXS.BSA: mostly 8-bit unsigned mono PCM
## .RAW clips at 11025 Hz, plus a few RIFF/WAVE .WAV. Music is the
## loose gamedata/T*.HMI + TITLE.HMI (the files the DOS engine plays —
## MDMDMUSC.BSA only holds Miles .XMI twins), decoded by HmiFile and
## played by MidiSynth on the "Music" bus.

extends Node

const SFX_BSA: String = "MDMDSFXS.BSA"
const RAW_RATE: int = 11025
const SFX_VOICES: int = 6
const AUDIO_CFG: String = "user://audio.cfg"

const PrsFile := preload("res://scripts/loaders/prs_file.gd")
const HmiFile := preload("res://scripts/loaders/hmi_file.gd")
const MidiSynth := preload("res://scripts/midi_synth.gd")
const ZoneLayers := preload("res://scripts/mission/zone_layers.gd")

var _bsa = null                       # BSAReader, kept open for the session
var _cache: Dictionary = {}           # key -> AudioStreamWAV
var _voices: Array[AudioStreamPlayer] = []
var _voices3d: Array[AudioStreamPlayer3D] = []
var _ambient: AudioStreamPlayer = null
## The menus' voices: they play on while the game is paused (play_ui).
var _ui_voices: Array[AudioStreamPlayer] = []
## Master volume, 0..1 — set from the OPTIONS menu, persisted.
var master_volume: float = 0.7
## Music volume, 0..1 (console `music <0-100>`), persisted.
var music_volume: float = 0.6
var _synth: Node = null
var _songs: Dictionary = {}           # name → parsed song

## DOS maptype (marker type 6, sub+2) → track, Skynet.exe table at
## VA 0x4f9f9 (0x24-byte entries: u32, "gamedata\tNNN.hmi", flag).
## The menu plays TITLE.HMI (skynet_gh.c:21787).
const MAPTYPE_TRACKS: PackedStringArray = [
	"T200.HMI", "T205.HMI", "T204.HMI", "T206.HMI", "T201.HMI", "T202.HMI",
	"T205.HMI", "T300NEW.HMI", "T301.HMI", "T303.HMI", "T302.HMI", "T305.HMI",
]
const TITLE_TRACK := "TITLE.HMI"

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AUDIO_CFG) == OK:
		master_volume = clampf(
			float(cfg.get_value("audio", "master", 0.7)), 0.0, 1.0)
		music_volume = clampf(
			float(cfg.get_value("audio", "music", 0.6)), 0.0, 1.0)
	_apply_master()
	# A "Music" bus so the score has its own level under Master.
	if AudioServer.get_bus_index("Music") < 0:
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, "Music")
		AudioServer.set_bus_send(idx, "Master")
	_apply_music_volume()
	_synth = MidiSynth.new()
	_synth.name = "MidiSynth"
	_synth.bus = "Music"
	add_child(_synth)
	_archive()
	# The music and the menus' sounds play on in a paused game (the Esc
	# menu, the console, the automap); every game sound holds where it is
	# and goes on when the game does (the C# port's paused effects bus).
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		p.process_mode = Node.PROCESS_MODE_PAUSABLE
		add_child(p)
		_voices.append(p)
		var u := AudioStreamPlayer.new()
		add_child(u)
		_ui_voices.append(u)
		# Positional voice pool — panned/attenuated by source location.
		# Inverse-square from 400 u: a robot two streets away is a murmur,
		# not a neighbour (a 2026-09-02 report: "every robot audible from
		# anywhere"). Walls add occlusion_db() on top.
		var p3 := AudioStreamPlayer3D.new()
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
		p3.unit_size = SFX_UNIT_SIZE
		p3.max_distance = SFX_MAX_DISTANCE
		p3.max_db = 0.0
		p3.process_mode = Node.PROCESS_MODE_PAUSABLE
		add_child(p3)
		_voices3d.append(p3)
	_ambient = AudioStreamPlayer.new()
	_ambient.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_ambient)

## The data directory the open sound archive came from.
var _bsa_dir: String = ""

## The sound archive, opened from the data directory in force NOW — or
## null when it has none. Until 2026-09-15 it was opened once, in _ready:
## on a first start with no data found yet, that ran before the DATA
## SETUP screen had asked for the folder, failed on an empty path, and the
## whole session went without a single sound effect while the music
## (loaded on demand) played — "nemá zvuky" from a player's first run.
func _archive():
	var dir: String = SkynetPaths.gamedata_dir
	if _bsa != null and dir == _bsa_dir:
		return _bsa
	if _bsa != null:
		_bsa.close()
	_bsa = null
	_cache.clear()
	_bsa_dir = dir
	if dir.is_empty():
		return null                              # the setup screen is on its way
	var b = preload("res://scripts/loaders/bsa_reader.gd").new()
	if not b.open(SkynetPaths.gamedata_path(SFX_BSA), SkynetPaths.variant):
		push_warning("[audio] cannot open %s in %s — no sound effects" % [SFX_BSA, dir])
		return null
	_bsa = b
	return _bsa

## Decode a .RAW / .WAV clip into an AudioStreamWAV (cached in memory
## and, through the asset cache, on disk).
func _load(nm: String, loop: bool) -> AudioStreamWAV:
	var key := nm.to_upper() + ("#L" if loop else "")
	if _cache.has(key):
		return _cache[key]
	if _archive() == null:
		return null
	var s: AudioStreamWAV = Assets.sound(nm, loop,
		func() -> Resource: return _decode(nm, loop))
	if s != null:
		_cache[key] = s
	return s

## Decode options for AudioStreamWAV.load_from_buffer: straight PCM, no
## trimming, normalising, resampling or bit-depth change, so the samples
## come out exactly as they went in. Its 8-bit path reads unsigned bytes
## as (b - 128) / 128 and writes them back * 128 as signed — the same
## (b - 128) the hand-written loop stored, done in C++.
const WAV_DECODE: Dictionary = {
	"compress/mode": 0, "edit/trim": false, "edit/normalize": false,
	"force/8_bit": false, "force/mono": false, "force/max_rate": false,
	"edit/loop_mode": 1,                   # disabled (no smpl-chunk loops)
}

func _decode(nm: String, loop: bool) -> AudioStreamWAV:
	if _bsa == null:
		return null
	var bytes: PackedByteArray = _bsa.read(nm)
	if bytes.is_empty():
		return null
	var s: AudioStreamWAV
	if nm.to_upper().ends_with(".WAV"):
		# A .WAV never loops here (the loop flag only ever applied to .RAW).
		s = AudioStreamWAV.load_from_buffer(bytes, WAV_DECODE)
		if s == null:
			s = _parse_wav(bytes)                # a header the engine refuses
	else:
		# DOS .RAW: unsigned 8-bit mono at 11025 Hz, given the RIFF header
		# it lacks. A loop runs over the whole clip (8-bit mono: one byte
		# is one frame).
		var opts: Dictionary = WAV_DECODE.duplicate()
		if loop:
			opts["edit/loop_mode"] = 2             # forward
			opts["edit/loop_begin"] = 0
			opts["edit/loop_end"] = bytes.size()
		s = AudioStreamWAV.load_from_buffer(_riff_pcm8(bytes, RAW_RATE), opts)
	return s

## `pcm` (unsigned 8-bit mono) wrapped in a minimal RIFF/WAVE header.
static func _riff_pcm8(pcm: PackedByteArray, rate: int) -> PackedByteArray:
	var pad: int = pcm.size() & 1                  # chunks are word-aligned
	var out := PackedByteArray()
	out.resize(44)
	out.encode_u32(0, 0x46464952)                  # "RIFF"
	out.encode_u32(4, 36 + pcm.size() + pad)
	out.encode_u32(8, 0x45564157)                  # "WAVE"
	out.encode_u32(12, 0x20746D66)                 # "fmt "
	out.encode_u32(16, 16)
	out.encode_u16(20, 1)                          # PCM
	out.encode_u16(22, 1)                          # mono
	out.encode_u32(24, rate)
	out.encode_u32(28, rate)                       # bytes per second
	out.encode_u16(32, 1)                          # block align
	out.encode_u16(34, 8)                          # bits per sample
	out.encode_u32(36, 0x61746164)                 # "data"
	out.encode_u32(40, pcm.size())
	out.append_array(pcm)
	if pad == 1:
		out.append(0)
	return out

## Minimal RIFF/WAVE (PCM) parser — the fallback for a file that
## AudioStreamWAV.load_from_buffer will not take.
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
func stream(nm: String) -> AudioStreamWAV:
	return _load(nm, false)

## Play a one-shot sound effect through a free voice (2D, non-positional).
func play_sfx(nm: String, volume_db: float = 0.0) -> void:
	var s := _load(nm, false)
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

## A menu's sound (a button): on the interface voices, which a paused game
## does not hold.
func play_ui(nm: String, volume_db: float = 0.0) -> void:
	var s := _load(nm, false)
	if s == null:
		return
	var pick: AudioStreamPlayer = _ui_voices[0]
	for p in _ui_voices:
		if not p.playing:
			pick = p
			break
	pick.stream = s
	pick.volume_db = volume_db
	pick.play()

## How a DOS 2D sound treats a copy of itself already playing (the play
## flags of FUN_0012ef06): start another, skip (2: not over itself) or
## restart that one (6: the footsteps).
enum Overlap { STACK, SKIP, RESTART }

## A DOS sound id on the player's 2D voices at the id's own volume and
## pitch (v1.01 table 0x50100 +4/+8): the soldier's steps, landings and
## grunts.
func play_id_dos(id: int, overlap: int = Overlap.STACK) -> void:
	var n := sound_name(id)
	if n.is_empty():
		return
	var s := _load(n, false)
	if s == null:
		return
	var pick: AudioStreamPlayer = null
	for p in _voices:
		if p.playing and p.stream == s:
			if overlap == Overlap.SKIP:
				return
			if overlap == Overlap.RESTART:
				pick = p
				break
	if pick == null:
		for p in _voices:
			if not p.playing:
				pick = p
				break
	if pick == null:
		pick = _voices[0]
	pick.stream = s
	pick.volume_db = linear_to_db(maxf(float(DOS_VOLUME[id]) / 128.0, 0.001))
	pick.pitch_scale = float(DOS_PITCH.get(id, 128)) / 128.0
	pick.play()

## Each DOS sound id's volume of 128 (v1.01 0x50100 +4).
const DOS_VOLUME: PackedByteArray = [
	100, 100, 100, 128, 128, 100, 100, 128, 100, 100, 100, 105, 100, 100, 100,
	100, 100, 100, 80, 80, 80, 60, 60, 100, 100, 100, 100, 100, 100, 100,
	100, 100, 100, 128, 128, 128, 128, 128, 128, 60, 100, 100, 100, 100, 100,
	100, 100, 100, 128, 128, 80, 60, 60, 40, 50, 128, 100, 70, 100, 50,
	50, 100, 100, 60, 50, 50, 100, 100, 30, 90, 40, 40, 40, 40, 40,
	40, 128, 100, 128, 128, 40, 100, 100, 40, 100, 100, 128, 100, 100, 100,
	100, 100, 100, 100, 100, 100, 70, 70, 128, 100, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128,
]
## The ids whose pitch (0x50100 +8) is not 128: the clip plays at
## 11025 x pitch / 128 Hz (the HK's hk2.raw variants, the left gravel step).
const DOS_PITCH: Dictionary = {49: 77, 50: 134, 51: 115, 52: 173, 53: 154,
	54: 102, 55: 102, 57: 154, 70: 80}

## DOS mixes at most six placed one-shots at once (and six loops, see
## _limit_loops); a new one takes the farthest one's voice only when it is
## nearer, so the robots and machinery of a big building cannot drown out
## what stands next to the player. The level's one-shot cue nodes
## (scripts/level/sound_cue.gd) share the count.
var _cues: Array = []

func register_cue(p: AudioStreamPlayer3D) -> void:
	if not _cues.has(p):
		_cues.append(p)

## Room for a placed one-shot `dist` from the listener: true when fewer
## than six play, or when the farthest of them is farther (it is stopped).
func claim_oneshot(dist: float) -> bool:
	var cam: Camera3D = _listener()
	var from: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var count: int = 0
	var far_p: AudioStreamPlayer3D = null
	var far_d: float = -1.0
	for i in range(_cues.size() - 1, -1, -1):
		if not is_instance_valid(_cues[i]):
			_cues.remove_at(i)
	for p in _voices3d + _cues:
		var a := p as AudioStreamPlayer3D
		if not a.playing or a.stream_paused or not a.is_inside_tree():
			continue
		count += 1
		var d: float = from.distance_to(a.global_position)
		if d > far_d:
			far_d = d
			far_p = a
	if count < SFX_VOICES:
		return true
	if far_p == null or far_d <= dist:
		return false
	far_p.stop()
	return true

## Play a one-shot sound at a world position — panned and attenuated by
## its location relative to the camera/listener. Use for doors, weapons,
## explosions, impacts and any other sound that has a place in the world.
##
## A sound past SFX_MAX_DISTANCE would be silent: it gets no voice and no
## occlusion ray (a walker's footsteps on the far side of the map used to
## take both). With all six voices busy the new sound takes the voice
## that is quietest where the listener stands — or is dropped when it
## would be quieter still — so a footstep cannot cut off the player's
## own explosion.
func play_sfx_3d(nm: String, world_pos: Vector3, volume_db: float = -6.0) -> void:
	var cam: Camera3D = _listener()
	var dist: float = cam.global_position.distance_to(world_pos) if cam != null else 0.0
	if dist > SFX_MAX_DISTANCE:
		return
	var s := _load(nm, false)
	if s == null:
		return
	if not claim_oneshot(dist):
		return
	var pick: AudioStreamPlayer3D = null
	var far_d: float = -1.0
	for p in _voices3d:
		if not p.playing:
			pick = p
			break
		# Every pool voice busy (the room was made on a cue node): the
		# farthest pool voice gives way.
		var d: float = cam.global_position.distance_to(p.global_position) if cam != null else 0.0
		if d > far_d:
			far_d = d
			pick = p
	var db: float = volume_db + occlusion_db(world_pos)
	pick.stream = s
	pick.global_position = world_pos
	pick.volume_db = db
	pick.play()

## The camera the 3D voices are heard from, or null.
func _listener() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

## Positional attenuation shared by every 3D voice (one-shots, enemy
## engines and alerts, ambient loops): inverse-square from unit_size,
## silent past max_distance.
const SFX_UNIT_SIZE: float = 400.0
const SFX_MAX_DISTANCE: float = 9000.0
const OCCLUDED_DB: float = -14.0

## Apply the shared attenuation model to a looping/actor voice.
func setup_3d(p: AudioStreamPlayer3D, unit: float = SFX_UNIT_SIZE, max_dist: float = SFX_MAX_DISTANCE) -> void:
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
	p.unit_size = unit
	p.max_distance = max_dist

## Godot has no sound occlusion: a ray from the listener (the camera)
## to the source that hits level geometry first means a wall is in the
## way — muffle by OCCLUDED_DB. Actor hitboxes (areas) do not count.
func occlusion_db(world_pos: Vector3) -> float:
	var vp := get_viewport()
	if vp == null:
		return 0.0
	var cam: Camera3D = vp.get_camera_3d()
	if cam == null:
		return 0.0
	var world := cam.get_world_3d()
	if world == null:
		return 0.0
	var space := world.direct_space_state
	if space == null:
		return 0.0
	var from: Vector3 = cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, world_pos)
	q.collision_mask = ZoneLayers.world_mask()
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if not hit.has("position"):
		return 0.0
	# A hit on the source's own body (an enemy's capsule) is not a wall.
	if (hit["position"] as Vector3).distance_to(world_pos) < 120.0:
		return 0.0
	return OCCLUDED_DB

## Start a looping ambient bed (replaces any current one).
func play_ambient(nm: String, volume_db: float = -13.0) -> void:
	var s := _load(nm, true)
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
	_save_cfg()

func _save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.save(AUDIO_CFG)

## --- music -------------------------------------------------------------

func _apply_music_volume() -> void:
	var idx := AudioServer.get_bus_index("Music")
	if idx < 0:
		return
	var db: float = linear_to_db(music_volume) if music_volume > 0.001 else -60.0
	AudioServer.set_bus_volume_db(idx, db)
	AudioServer.set_bus_mute(idx, music_volume <= 0.001)

func set_music_volume(v: float) -> void:
	music_volume = clampf(v, 0.0, 1.0)
	_apply_music_volume()
	_save_cfg()

## Parsed HMI song (memory-cached; a 30 KB file parses in milliseconds).
func song(nm: String) -> Dictionary:
	nm = nm.to_upper()
	if _songs.has(nm):
		return _songs[nm]
	var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path(nm))
	var s: Dictionary = HmiFile.parse(bytes) if not bytes.is_empty() else {}
	if s.is_empty():
		push_warning("[audio] cannot play %s" % nm)
	_songs[nm] = s
	return s

## Start a track ("T200.HMI"); a no-op when it is already playing.
func play_music(nm: String) -> void:
	nm = nm.to_upper()
	if _synth == null:
		return
	if _synth.playing and _synth.song_name == nm:
		return
	var s := song(nm)
	if s.is_empty():
		_synth.stop()
		return
	_synth.play(s, nm)
	print("[audio] music %s (%d events, %.0f s)" % [nm, s["events"].size() / HmiFile.REC,
		float(s["length"]) / float(s["rate"])])

func stop_music() -> void:
	if _synth != null:
		_synth.stop()

## Build every instrument sample the game's tracks use (Assets.import_all),
## so no song synthesises one when it first plays.
func prewarm_music() -> void:
	if _synth == null:
		return
	var tracks: Array = Array(MAPTYPE_TRACKS)
	tracks.append(TITLE_TRACK)
	for t in tracks:
		for item in MidiSynth._song_items(song(String(t)).get("events", PackedInt32Array())):
			_synth._install(item)

func music_name() -> String:
	return String(_synth.song_name) if _synth != null and _synth.playing else ""

## The level's track from its maptype marker (DOS MapStart: no marker → 0).
func play_music_for_maptype(maptype: int) -> void:
	if maptype < 0 or maptype >= MAPTYPE_TRACKS.size():
		maptype = 0
	play_music(MAPTYPE_TRACKS[maptype])

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

## Looping positional sound parented to `parent` (ambient fires and
## barrels from the 0x4cc00 table, 0xEE nodes, vehicle engines). Returns
## the player.
##
## It plays only while the listener is inside its max_distance: a loop
## past that is silent but still mixed, and a map carries dozens of
## fires. _process starts and stops them a few times a second; a loop
## somebody else stops stays stopped.
func attach_loop_3d(id: int, parent: Node, volume_db: float = -10.0) -> AudioStreamPlayer3D:
	var n := sound_name(id)
	if n.is_empty() or parent == null:
		return null
	var s := _load(n, true)
	if s == null:
		return null
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	setup_3d(p, 300.0, 5000.0)
	p.max_db = 0.0
	p.volume_db = volume_db
	parent.add_child(p)
	_loops.append(p)
	_gated[p.get_instance_id()] = true           # not started yet
	if p.is_inside_tree():
		var cam: Camera3D = _listener()
		_gate_loop(p, cam.global_position if cam != null else p.global_position)
	return p

## Distance-gated loops (attach_loop_3d) and which of them the gate has
## stopped (or not started yet): instance id → true.
var _loops: Array = []
var _gated: Dictionary = {}
var _loop_t: float = 0.0
const LOOP_GATE_INTERVAL: float = 0.3
const LOOP_GATE_MARGIN: float = 500.0

func _process(delta: float) -> void:
	# A paused game holds its loops where they are (the Audio node itself
	# runs always, for the menus).
	if get_tree().paused:
		return
	_loop_t -= delta
	if _loop_t > 0.0 or (_loops.is_empty() and _scene_loops.is_empty()):
		return
	_loop_t = LOOP_GATE_INTERVAL
	var cam: Camera3D = _listener()
	_limit_loops(cam)
	var i: int = _loops.size() - 1
	while i >= 0:
		var p = _loops[i]
		if not is_instance_valid(p):
			_loops.remove_at(i)
		elif (p as Node).is_inside_tree():
			_gate_loop(p, cam.global_position if cam != null else (p as Node3D).global_position)
		i -= 1
	# Forget the ids of players that are gone.
	if _gated.size() > _loops.size():
		var live: Dictionary = {}
		for p in _loops:
			live[(p as Object).get_instance_id()] = true
		for k in _gated.keys():
			if not live.has(k):
				_gated.erase(k)

## The level's ambient loop nodes (scripts/level/sound_loop.gd): counted
## by _limit_loops with the attach_loop_3d ones, never started by the gate.
var _scene_loops: Array = []

func register_loop(p: AudioStreamPlayer3D) -> void:
	if not _scene_loops.has(p):
		_scene_loops.append(p)

## Only the six nearest loops in earshot are heard (DOS's six loop
## voices); the rest hold paused until they are among the nearest again.
func _limit_loops(cam: Camera3D) -> void:
	for i in range(_scene_loops.size() - 1, -1, -1):
		if not is_instance_valid(_scene_loops[i]):
			_scene_loops.remove_at(i)
	var from: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var heard: Array = []
	for p in _loops + _scene_loops:
		if not is_instance_valid(p):
			continue
		var a := p as AudioStreamPlayer3D
		if not a.is_inside_tree() or not a.playing:
			if a.has_meta(&"voice_limited"):
				a.remove_meta(&"voice_limited")
				a.stream_paused = false
			continue
		if a.has_meta(&"zone_hushed") or ZoneLayers.asleep(a):
			continue
		var d: float = from.distance_to(a.global_position)
		if a.max_distance <= 0.0 or d <= a.max_distance:
			heard.append([d, a])
		elif a.has_meta(&"voice_limited"):
			a.remove_meta(&"voice_limited")
			a.stream_paused = false
	heard.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	for i in heard.size():
		var a: AudioStreamPlayer3D = heard[i][1]
		if i < SFX_VOICES:
			if a.has_meta(&"voice_limited"):
				a.remove_meta(&"voice_limited")
				a.stream_paused = false
		elif not a.stream_paused:
			a.stream_paused = true
			a.set_meta(&"voice_limited", true)

## Start `p` inside its max_distance of `listener`, stop it past it (plus
## LOOP_GATE_MARGIN), and only ever restart what the gate itself stopped.
func _gate_loop(p: AudioStreamPlayer3D, listener: Vector3) -> void:
	var id: int = p.get_instance_id()
	# A loop of a zone the player is not in (a mission scene holds them
	# all, only MissionScene.GAP apart) is off, however near it stands.
	if ZoneLayers.asleep(p):
		if p.playing and not p.stream_paused:
			p.stop()
			_gated[id] = true
		return
	var d: float = listener.distance_to(p.global_position)
	if p.playing:
		if d > p.max_distance + LOOP_GATE_MARGIN:
			p.stop()
			_gated[id] = true
	elif _gated.has(id) and d <= p.max_distance:
		_gated.erase(id)
		p.play()

## The cached looping / one-shot stream of a DOS sound id, for the level
## bake (scripts/level_behaviour.gd): straight from the asset cache
## rather than the session dictionary above, so the saved scene
## references the cache file under whichever root is in force at bake
## time. null for -1 / bad ids.
func loop_stream_for(id: int) -> AudioStreamWAV:
	return _bake_stream(id, true)

func oneshot_stream_for(id: int) -> AudioStreamWAV:
	return _bake_stream(id, false)

func _bake_stream(id: int, loop: bool) -> AudioStreamWAV:
	var n := sound_name(id)
	if n.is_empty() or _archive() == null:
		return null
	return Assets.sound(n, loop, func() -> Resource: return _decode(n, loop))

## Voice line by VOICE.PRS id (0xED nodes: "no.21032 = 210g5.wav").
func play_voice(id: int, volume_db: float = 0.0) -> void:
	var f := PrsFile.text("VOICE.PRS", "no.%d" % id)
	if not f.is_empty():
		play_sfx(f.to_upper(), volume_db)
