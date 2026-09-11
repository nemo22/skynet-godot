## Software General-MIDI player for the HMI music: a sequencer feeding
## a pool of AudioStreamPlayers (Godot's mixer does the resampling —
## nothing is synthesised per sample at run time).
##
## Instruments are one-second wavetable samples built here from
## additive waveforms + envelopes per GM family (piano, organ, guitar,
## bass, strings, brass, reed, pipe, leads, pads …) and a drum kit
## (kick, snare, hats, toms, cymbals …). They are generated once and
## kept in the asset cache (converted/music/GM_nnn.res) — the "convert
## on first load" step for music. Pitch = pitch_scale on the base
## sample, so a note costs one player, no DSP.
##
## Sequencing: events come from HmiFile.parse (flat 5-int records);
## `_process` advances the tick clock (division × tempo) and dispatches
## note on/off, controllers 7/11/10/121/123, program changes, pitch
## bend and tempo. Songs loop.
extends Node

const RATE: int = 22050
const VOICES: int = 40
const REC: int = 5
const BASE_NOTE: int = 60                    # samples are pitched at C4
const REL_DB_PER_S: float = 90.0             # fastest release slope
const MIN_DB: float = -48.0

var bus: String = "Master"
var gain_db: float = -4.0
var playing: bool = false
var song_name: String = ""

var _events: PackedInt32Array = PackedInt32Array()
var _pos: int = 0
var _tick: float = 0.0
var _tps: float = 192.0                      # ticks per second
var _division: int = 96
var _length: int = 0
var _voices: Array = []                      # [player, ch, note, on(bool), age, rel_s, vel_db, base_db]
var _age: int = 0
var _chan: Array = []                        # per channel {prog, vol, expr, bend}
var _bank: Dictionary = {}                   # program → {stream, hz, rel}
var _drums: Dictionary = {}                  # note → {stream, hz, rel}
func _ready() -> void:
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = bus
		add_child(p)
		_voices.append([p, -1, -1, false, 0, 0.2, 0.0, 0.0])
	_reset_channels()

func _exit_tree() -> void:
	# Drop the sample references before the servers shut down.
	stop()
	_bank.clear()
	_drums.clear()

func _reset_channels() -> void:
	_chan = []
	for i in 16:
		_chan.append({"prog": 0, "vol": 100, "expr": 127, "bend": 1.0})

func set_bus(b: String) -> void:
	bus = b
	for v in _voices:
		(v[0] as AudioStreamPlayer).bus = b

## Start a parsed song (HmiFile.parse output).
func play(song: Dictionary, name: String = "") -> void:
	stop()
	_events = song.get("events", PackedInt32Array())
	_division = int(song.get("division", 96))
	_length = int(song.get("length", 0))
	# HMI: a fixed timer rate (120 Hz), not PPQN × tempo.
	_tps = float(song.get("rate", 120))
	_pos = 0
	_tick = 0.0
	_reset_channels()
	song_name = name
	playing = _events.size() >= REC and _length > 0

func stop() -> void:
	playing = false
	song_name = ""
	for v in _voices:
		(v[0] as AudioStreamPlayer).stop()
		v[3] = false
		v[1] = -1

func _process(delta: float) -> void:
	_release_voices(delta)
	if not playing:
		return
	_tick += delta * _tps
	var n: int = _events.size()
	while _pos < n and float(_events[_pos]) <= _tick:
		_dispatch(_pos)
		_pos += REC
	if _pos >= n:
		# Loop: the tail of the last note may still be releasing.
		_all_notes_off()
		_pos = 0
		_tick -= float(_length)
		if _tick < 0.0 or _tick > _tps:
			_tick = 0.0

func _dispatch(o: int) -> void:
	var kind: int = _events[o + 1]
	var ch: int = _events[o + 2]
	var d1: int = _events[o + 3]
	var d2: int = _events[o + 4]
	match kind:
		0x90:
			_note_on(ch, d1, d2)
		0x80:
			_note_off(ch, d1)
		0xB0:
			match d1:
				7:
					_chan[ch]["vol"] = d2
					_update_channel_volume(ch)
				11:
					_chan[ch]["expr"] = d2
					_update_channel_volume(ch)
				120, 123:
					_channel_notes_off(ch)
				121:
					_chan[ch]["vol"] = 100
					_chan[ch]["expr"] = 127
					_chan[ch]["bend"] = 1.0
		0xC0:
			_chan[ch]["prog"] = d1
		0xE0:
			# ±2 semitones over the 14-bit range.
			_chan[ch]["bend"] = pow(2.0, (float(d1 - 8192) / 8192.0) * 2.0 / 12.0)
			for v in _voices:
				if v[1] == ch and v[3]:
					_apply_pitch(v)
		0x51:
			# Tempo metas are ignored: the HMI driver runs a fixed timer.
			pass

func _channel_db(ch: int) -> float:
	var c: Dictionary = _chan[ch]
	var lin: float = (float(c["vol"]) / 127.0) * (float(c["expr"]) / 127.0)
	return linear_to_db(maxf(lin, 0.0005))

func _update_channel_volume(ch: int) -> void:
	for v in _voices:
		if v[1] == ch and v[3]:
			v[7] = _channel_db(ch)
			(v[0] as AudioStreamPlayer).volume_db = v[6] + v[7] + gain_db

static func _note_hz(note: int) -> float:
	return 440.0 * pow(2.0, float(note - 69) / 12.0)

func _apply_pitch(v: Array) -> void:
	var p: AudioStreamPlayer = v[0]
	var inst: Dictionary = v[8] if v.size() > 8 else {}
	if inst.is_empty():
		return
	var hz: float = _note_hz(v[2]) * float(_chan[v[1]]["bend"])
	if bool(inst.get("fixed", false)):
		p.pitch_scale = 1.0
	else:
		p.pitch_scale = clampf(hz / float(inst["hz"]), 0.05, 20.0)

func _note_on(ch: int, note: int, vel: int) -> void:
	var inst: Dictionary
	if ch == 9:
		inst = _drum(note)
	else:
		inst = _instrument(int(_chan[ch]["prog"]))
	if inst.is_empty() or inst.get("stream") == null:
		return
	# Retrigger the same note, else a free voice, else the oldest.
	var pick: Array = []
	for v in _voices:
		if v[1] == ch and v[2] == note and v[3]:
			pick = v
			break
	if pick.is_empty():
		for v in _voices:
			if not (v[0] as AudioStreamPlayer).playing:
				pick = v
				break
	if pick.is_empty():
		var oldest: int = -1
		for v in _voices:
			if oldest < 0 or int(v[4]) < oldest:
				oldest = int(v[4])
				pick = v
	_age += 1
	var p: AudioStreamPlayer = pick[0]
	pick[1] = ch
	pick[2] = note
	pick[3] = true
	pick[4] = _age
	pick[5] = float(inst.get("rel", 0.2))
	pick[6] = linear_to_db(maxf(float(vel) / 127.0, 0.01)) + float(inst.get("gain", 0.0))
	pick[7] = _channel_db(ch)
	if pick.size() > 8:
		pick[8] = inst
	else:
		pick.append(inst)
	p.stream = inst["stream"]
	_apply_pitch(pick)
	p.volume_db = pick[6] + pick[7] + gain_db
	p.play()

func _note_off(ch: int, note: int) -> void:
	for v in _voices:
		if v[1] == ch and v[2] == note and v[3]:
			v[3] = false                          # releasing (see _release_voices)

func _channel_notes_off(ch: int) -> void:
	for v in _voices:
		if v[1] == ch and v[3]:
			v[3] = false

func _all_notes_off() -> void:
	for v in _voices:
		if v[3]:
			v[3] = false

## Fade released voices out over their instrument's release time.
func _release_voices(delta: float) -> void:
	for v in _voices:
		var p: AudioStreamPlayer = v[0]
		if v[3] or not p.playing:
			continue
		var rel: float = maxf(float(v[5]), 0.02)
		p.volume_db -= delta * maxf(REL_DB_PER_S, 48.0 / rel)
		if p.volume_db < MIN_DB + gain_db:
			p.stop()
			v[1] = -1

# ---------------------------------------------------------------------
# Instrument bank — GM families as wavetable samples
# ---------------------------------------------------------------------

## Family specs: harmonics [[n, amp] …], attack s, decay s, sustain
## level (0 = one-shot), release s, gain dB, clip (distortion).
static func _family(prog: int) -> Dictionary:
	var f: int = prog / 8
	match f:
		0:  return {"h": [[1, 1.0], [2, 0.55], [3, 0.3], [4, 0.15], [5, 0.08], [6, 0.05]], "a": 0.004, "d": 1.4, "s": 0.0, "rel": 0.25, "gain": 0.0}
		1:  return {"h": [[1, 1.0], [3, 0.35], [4, 0.3], [6, 0.12]], "a": 0.002, "d": 1.1, "s": 0.0, "rel": 0.3, "gain": -2.0}
		2:  return {"h": [[1, 1.0], [2, 0.8], [3, 0.5], [4, 0.6], [6, 0.3], [8, 0.4]], "a": 0.01, "d": 0.2, "s": 0.9, "rel": 0.08, "gain": -3.0}
		3:
			if prog >= 29:
				return {"h": [[1, 1.0], [2, 0.7], [3, 0.6], [4, 0.5], [5, 0.4], [6, 0.3], [7, 0.25]], "a": 0.004, "d": 1.2, "s": 0.35, "rel": 0.15, "gain": -3.0, "clip": 2.5}
			return {"h": [[1, 1.0], [2, 0.6], [3, 0.4], [4, 0.3], [5, 0.2], [6, 0.12]], "a": 0.003, "d": 0.9, "s": 0.0, "rel": 0.2, "gain": -1.0}
		4:  return {"h": [[1, 1.0], [2, 0.5], [3, 0.3], [4, 0.12]], "a": 0.004, "d": 0.5, "s": 0.45, "rel": 0.12, "gain": 1.0}
		5, 6: return {"h": [[1, 1.0], [2, 0.5], [3, 0.33], [4, 0.25], [5, 0.2], [6, 0.17], [7, 0.14], [8, 0.12]], "a": 0.12, "d": 0.3, "s": 0.85, "rel": 0.4, "gain": -4.0}
		7:  return {"h": [[1, 1.0], [2, 0.6], [3, 0.5], [4, 0.4], [5, 0.35], [6, 0.3], [7, 0.25], [8, 0.2], [9, 0.15], [10, 0.12]], "a": 0.04, "d": 0.25, "s": 0.8, "rel": 0.18, "gain": -3.0}
		8:  return {"h": [[1, 1.0], [3, 0.4], [5, 0.25], [7, 0.15], [9, 0.08]], "a": 0.04, "d": 0.2, "s": 0.85, "rel": 0.15, "gain": -3.0}
		9:  return {"h": [[1, 1.0], [2, 0.15], [3, 0.06]], "a": 0.05, "d": 0.2, "s": 0.85, "rel": 0.2, "gain": -1.0}
		10:
			if prog == 80 or prog == 84 or prog == 87:
				return {"h": [[1, 1.0], [3, 0.33], [5, 0.2], [7, 0.14], [9, 0.11], [11, 0.09]], "a": 0.008, "d": 0.2, "s": 0.85, "rel": 0.1, "gain": -4.0}
			return {"h": [[1, 1.0], [2, 0.5], [3, 0.33], [4, 0.25], [5, 0.2], [6, 0.17], [7, 0.14], [8, 0.12], [9, 0.11]], "a": 0.008, "d": 0.2, "s": 0.85, "rel": 0.1, "gain": -4.0}
		11: return {"h": [[1, 1.0], [2, 0.4], [3, 0.25], [4, 0.15], [5, 0.1], [6, 0.06]], "a": 0.35, "d": 0.4, "s": 0.9, "rel": 0.7, "gain": -5.0}
		12: return {"h": [[1, 1.0], [2, 0.3], [3, 0.2]], "a": 0.2, "d": 0.4, "s": 0.8, "rel": 0.5, "gain": -5.0}
		13: return {"h": [[1, 1.0], [2, 0.5], [3, 0.4], [5, 0.2]], "a": 0.003, "d": 0.8, "s": 0.0, "rel": 0.2, "gain": -1.0}
		14: return {"h": [[1, 1.0], [2, 0.4], [3, 0.3], [4, 0.2]], "a": 0.002, "d": 0.45, "s": 0.0, "rel": 0.15, "gain": -1.0}
		_:  return {"h": [], "noise": true, "a": 0.005, "d": 0.6, "s": 0.0, "rel": 0.3, "gain": -6.0}

func _instrument(prog: int) -> Dictionary:
	prog = clampi(prog, 0, 127)
	if _bank.has(prog):
		return _bank[prog]
	var spec: Dictionary = _family(prog)
	var stream: AudioStreamWAV = Assets.fetch("music", "GM_%03d" % prog,
		func() -> Resource: return _build_tone(spec)) as AudioStreamWAV
	var inst := {"stream": stream, "hz": _loop_hz(), "rel": float(spec["rel"]), "gain": float(spec.get("gain", 0.0))}
	_bank[prog] = inst
	return inst

## The base frequency: a whole number of periods fits the loop segment.
const LOOP_LEN: int = 4410                   # 0.2 s
const LOOP_PERIODS: int = 52                 # ≈ 260 Hz, close to C4
static func _loop_hz() -> float:
	return float(RATE) * float(LOOP_PERIODS) / float(LOOP_LEN)

## Additive tone with an ADSR-shaped body; sustained sounds loop their
## last 0.2 s (steady-state), one-shots decay to silence.
static func _build_tone(spec: Dictionary) -> AudioStreamWAV:
	var sustain: float = float(spec.get("s", 0.0))
	var a: float = float(spec.get("a", 0.01))
	var d: float = float(spec.get("d", 0.5))
	var total: float = (a + d + 0.25) if sustain > 0.0 else (a + d + 0.05)
	var n: int = int(total * RATE)
	if sustain > 0.0:
		n = maxi(n, int((a + d) * RATE) + LOOP_LEN)
	var hz: float = _loop_hz()
	var buf := PackedFloat32Array()
	buf.resize(n)
	var harm: Array = spec.get("h", [])
	var noise: bool = bool(spec.get("noise", false))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var clip: float = float(spec.get("clip", 0.0))
	var norm: float = 0.0
	for h in harm:
		norm += float(h[1])
	if norm <= 0.0:
		norm = 1.0
	for i in n:
		var t: float = float(i) / float(RATE)
		var s: float = 0.0
		if noise:
			s = rng.randf_range(-1.0, 1.0)
		else:
			for h in harm:
				s += float(h[1]) * sin(TAU * hz * float(h[0]) * t)
			s /= norm
		if clip > 0.0:
			s = tanh(s * clip) / tanh(clip)
		var env: float
		if t < a:
			env = t / a
		elif sustain > 0.0:
			env = sustain + (1.0 - sustain) * exp(-(t - a) / maxf(d * 0.35, 0.001))
		else:
			env = exp(-(t - a) * 4.0 / maxf(d, 0.001))
			if t > a + d:
				env *= maxf(0.0, 1.0 - (t - a - d) / 0.05)
		buf[i] = s * env * 0.8
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = _to_pcm16(buf)
	if sustain > 0.0:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = n
		wav.loop_begin = n - LOOP_LEN
	return wav

static func _to_pcm16(buf: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(buf.size() * 2)
	for i in buf.size():
		var v: int = int(clampf(buf[i], -1.0, 1.0) * 32767.0)
		out[i * 2] = v & 0xFF
		out[i * 2 + 1] = (v >> 8) & 0xFF
	return out

# --- drums ---------------------------------------------------------------

func _drum(note: int) -> Dictionary:
	if _drums.has(note):
		return _drums[note]
	var spec: Dictionary = _drum_spec(note)
	var key: String = "DRUM_%03d" % int(spec["id"])
	var stream: AudioStreamWAV = Assets.fetch("music", key,
		func() -> Resource: return _build_drum(spec)) as AudioStreamWAV
	var inst := {"stream": stream, "hz": 1.0, "fixed": true, "rel": 0.05, "gain": float(spec.get("gain", 0.0))}
	_drums[note] = inst
	return inst

## GM percussion map → {id (sample identity), kind, params}.
static func _drum_spec(note: int) -> Dictionary:
	match note:
		35, 36: return {"id": 36, "kind": "kick", "gain": 2.0}
		37:     return {"id": 37, "kind": "hit", "len": 0.04, "gain": -6.0}
		38, 40: return {"id": 38, "kind": "snare", "gain": 0.0}
		39:     return {"id": 39, "kind": "clap", "gain": -3.0}
		41, 43: return {"id": 41, "kind": "tom", "hz": 90.0, "gain": 0.0}
		45, 47: return {"id": 45, "kind": "tom", "hz": 130.0, "gain": 0.0}
		48, 50: return {"id": 48, "kind": "tom", "hz": 180.0, "gain": 0.0}
		42, 44: return {"id": 42, "kind": "hat", "len": 0.07, "gain": -8.0}
		46:     return {"id": 46, "kind": "hat", "len": 0.35, "gain": -8.0}
		49, 52, 55, 57: return {"id": 49, "kind": "cymbal", "len": 1.2, "gain": -8.0}
		51, 59: return {"id": 51, "kind": "cymbal", "len": 0.5, "gain": -10.0}
		53:     return {"id": 53, "kind": "bell", "gain": -8.0}
		54:     return {"id": 54, "kind": "hat", "len": 0.2, "gain": -10.0}
		56:     return {"id": 56, "kind": "cowbell", "gain": -6.0}
		_:      return {"id": 60, "kind": "hit", "len": 0.15, "gain": -8.0}

static func _build_drum(spec: Dictionary) -> AudioStreamWAV:
	var kind: String = String(spec["kind"])
	var ln: float = float(spec.get("len", 0.3))
	match kind:
		"kick": ln = 0.4
		"snare": ln = 0.25
		"clap": ln = 0.3
		"tom": ln = 0.45
		"bell": ln = 0.6
		"cowbell": ln = 0.3
	var n: int = int(ln * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var prev: float = 0.0
	for i in n:
		var t: float = float(i) / float(RATE)
		var u: float = t / ln
		var s: float = 0.0
		match kind:
			"kick":
				var f: float = 45.0 + 130.0 * exp(-t * 18.0)
				s = sin(TAU * f * t * (1.0 + 0.0)) * exp(-t * 9.0)
				s = tanh(s * 1.8)
			"snare":
				var nz: float = rng.randf_range(-1.0, 1.0)
				s = nz * exp(-t * 16.0) * 0.8 + sin(TAU * 190.0 * t) * exp(-t * 30.0) * 0.5
			"clap":
				var nz: float = rng.randf_range(-1.0, 1.0)
				var burst: float = 0.0
				for k in 3:
					var tk: float = t - float(k) * 0.011
					if tk >= 0.0:
						burst = maxf(burst, exp(-tk * 60.0))
				s = nz * (burst * 0.7 + exp(-t * 12.0) * 0.5)
			"tom":
				var f: float = float(spec.get("hz", 120.0)) * (1.0 + 0.8 * exp(-t * 20.0))
				s = sin(TAU * f * t) * exp(-t * 7.0)
			"hat":
				var nz: float = rng.randf_range(-1.0, 1.0)
				var hp: float = nz - prev                # crude high-pass
				prev = nz
				s = hp * exp(-t * (6.0 / ln)) * 0.7
			"cymbal":
				var nz: float = rng.randf_range(-1.0, 1.0)
				var hp: float = nz - prev * 0.6
				prev = nz
				s = hp * exp(-t * (4.0 / ln)) * 0.6
			"bell":
				s = (sin(TAU * 1180.0 * t) + 0.5 * sin(TAU * 1760.0 * t) + 0.3 * sin(TAU * 2600.0 * t)) / 1.8 * exp(-t * 5.0)
			"cowbell":
				s = (sin(TAU * 560.0 * t) + sin(TAU * 845.0 * t)) * 0.5 * exp(-t * 12.0)
				s = tanh(s * 2.0)
			_:
				var nz: float = rng.randf_range(-1.0, 1.0)
				s = nz * exp(-t * (5.0 / ln))
		if u > 0.9:
			s *= (1.0 - u) / 0.1
		buf[i] = clampf(s * 0.85, -1.0, 1.0)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = _to_pcm16(buf)
	return wav
