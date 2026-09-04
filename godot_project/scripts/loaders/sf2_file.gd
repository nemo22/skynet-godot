## SoundFont 2 reader — enough of it to use a GM bank as a wavetable.
##
## The port's music is a MIDI sequencer (hmi_file.gd) driving synthesised
## tones (midi_synth._build_tone). Those tones are additive sine stacks:
## they play the right notes at the right time, but a trumpet does not
## sound like a trumpet. A General MIDI SoundFont has a RECORDED sample
## for every program, which is what a real wavetable card had, so this
## reads one out per instrument and hands it to the synth as an
## AudioStreamWAV. Marek supplied "gm dls remastered version 2.1.sf2"
## (2026-09-04).
##
## Only what is needed is parsed and only what is asked for is read: the
## file is 70 MB, so the small hunks (phdr/pbag/pgen/inst/ibag/igen/shdr)
## are held in memory and the audio itself is seeked into on demand.
##
## Layout (SF2 spec 2.04, RIFF "sfbk"):
##   LIST INFO  — names and version
##   LIST sdta  — "smpl" chunk: all samples, 16-bit signed mono, back to back
##   LIST pdta  — the record arrays below
## A preset points at zones (pbag), each zone is a run of generators
## (pgen); generator 41 names an instrument, which has its own zones
## (ibag/igen) and generator 53 names the sample (shdr).

extends RefCounted

const GEN_START_ADDRS: int = 0
const GEN_END_ADDRS: int = 1
const GEN_STARTLOOP_ADDRS: int = 2
const GEN_ENDLOOP_ADDRS: int = 3
const GEN_START_COARSE: int = 4
const GEN_END_COARSE: int = 12
const GEN_STARTLOOP_COARSE: int = 45
const GEN_ENDLOOP_COARSE: int = 50
const GEN_INSTRUMENT: int = 41
const GEN_KEY_RANGE: int = 43
const GEN_SAMPLE_MODES: int = 54
const GEN_SAMPLE_ID: int = 53
const GEN_ROOT_KEY: int = 58
const GEN_COARSE_TUNE: int = 51
const GEN_FINE_TUNE: int = 52

class SF2:
	var path: String = ""
	var ok: bool = false
	var smpl_off: int = 0                 # byte offset of the sample data
	var smpl_len: int = 0                 # in bytes
	var phdr := PackedByteArray()
	var pbag := PackedByteArray()
	var pgen := PackedByteArray()
	var inst := PackedByteArray()
	var ibag := PackedByteArray()
	var igen := PackedByteArray()
	var shdr := PackedByteArray()

## Read the directory of a .sf2. Returns null when it is not one.
static func open_file(path: String) -> SF2:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var sf := SF2.new()
	sf.path = path
	if f.get_buffer(4).get_string_from_ascii() != "RIFF":
		return null
	var riff_len: int = f.get_32()
	if f.get_buffer(4).get_string_from_ascii() != "sfbk":
		return null
	var end: int = mini(8 + riff_len, int(f.get_length()))
	while f.get_position() + 8 <= end:
		var id: String = f.get_buffer(4).get_string_from_ascii()
		var size: int = f.get_32()
		var next: int = f.get_position() + size + (size & 1)
		if id == "LIST":
			var kind: String = f.get_buffer(4).get_string_from_ascii()
			if kind == "sdta" or kind == "pdta":
				# Walk the sub-chunks of this list in place.
				while f.get_position() + 8 <= next:
					var sid: String = f.get_buffer(4).get_string_from_ascii()
					var ssize: int = f.get_32()
					var snext: int = f.get_position() + ssize + (ssize & 1)
					match sid:
						"smpl":
							sf.smpl_off = f.get_position()
							sf.smpl_len = ssize
						"phdr": sf.phdr = f.get_buffer(ssize)
						"pbag": sf.pbag = f.get_buffer(ssize)
						"pgen": sf.pgen = f.get_buffer(ssize)
						"inst": sf.inst = f.get_buffer(ssize)
						"ibag": sf.ibag = f.get_buffer(ssize)
						"igen": sf.igen = f.get_buffer(ssize)
						"shdr": sf.shdr = f.get_buffer(ssize)
					f.seek(snext)
		f.seek(next)
	f.close()
	sf.ok = not sf.phdr.is_empty() and not sf.shdr.is_empty() and sf.smpl_len > 0
	return sf

# --- record accessors --------------------------------------------------
static func _u16(b: PackedByteArray, o: int) -> int:
	return b[o] | (b[o + 1] << 8)

static func _s16(b: PackedByteArray, o: int) -> int:
	var v: int = _u16(b, o)
	return v - 65536 if v >= 32768 else v

static func _u32(b: PackedByteArray, o: int) -> int:
	return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

## Generators of zone `zi` in a bag/gen pair, as {oper: amount}.
static func _zone_gens(bag: PackedByteArray, gen: PackedByteArray, zi: int) -> Dictionary:
	var out: Dictionary = {}
	if (zi + 1) * 4 + 2 > bag.size():
		return out
	var g0: int = _u16(bag, zi * 4)
	var g1: int = _u16(bag, (zi + 1) * 4)
	for g in range(g0, g1):
		var o: int = g * 4
		if o + 4 > gen.size():
			break
		out[_u16(gen, o)] = _u16(gen, o + 2)
	return out

## The zone whose key range covers `key`, else the last zone without one
## (the instrument's global zone is skipped by the sampleID test).
static func _pick_zone(bag: PackedByteArray, gen: PackedByteArray,
		first: int, last: int, key: int, need: int) -> Dictionary:
	var fallback: Dictionary = {}
	for zi in range(first, last):
		var g: Dictionary = _zone_gens(bag, gen, zi)
		if not g.has(need):
			continue
		if fallback.is_empty():
			fallback = g
		if not g.has(GEN_KEY_RANGE):
			return g
		var kr: int = int(g[GEN_KEY_RANGE])
		if key >= (kr & 0xFF) and key <= ((kr >> 8) & 0xFF):
			return g
	return fallback

## The sample a GM `program` in `bank` plays around `key`, as
## {stream: AudioStreamWAV, root: int (MIDI note), cents: float}.
## Empty when the SoundFont has nothing for it.
static func instrument(sf: SF2, bank: int, program: int, key: int = 60) -> Dictionary:
	if sf == null or not sf.ok:
		return {}
	var n_presets: int = sf.phdr.size() / 38 - 1        # last is the EOP terminal
	var pi: int = -1
	for i in n_presets:
		var o: int = i * 38
		if _u16(sf.phdr, o + 20) == program and _u16(sf.phdr, o + 22) == bank:
			pi = i
			break
	if pi < 0:
		return {}
	var pz0: int = _u16(sf.phdr, pi * 38 + 24)
	var pz1: int = _u16(sf.phdr, (pi + 1) * 38 + 24)
	var pg: Dictionary = _pick_zone(sf.pbag, sf.pgen, pz0, pz1, key, GEN_INSTRUMENT)
	if not pg.has(GEN_INSTRUMENT):
		return {}
	var ii: int = int(pg[GEN_INSTRUMENT])
	if (ii + 1) * 22 + 22 > sf.inst.size():
		return {}
	var iz0: int = _u16(sf.inst, ii * 22 + 20)
	var iz1: int = _u16(sf.inst, (ii + 1) * 22 + 20)
	var ig: Dictionary = _pick_zone(sf.ibag, sf.igen, iz0, iz1, key, GEN_SAMPLE_ID)
	if not ig.has(GEN_SAMPLE_ID):
		return {}
	var si: int = int(ig[GEN_SAMPLE_ID])
	var so: int = si * 46
	if so + 46 > sf.shdr.size():
		return {}
	var start: int = _u32(sf.shdr, so + 20)
	var send: int = _u32(sf.shdr, so + 24)
	var loop0: int = _u32(sf.shdr, so + 28)
	var loop1: int = _u32(sf.shdr, so + 32)
	var rate: int = _u32(sf.shdr, so + 36)
	var root: int = sf.shdr[so + 40]
	var correction: int = sf.shdr[so + 41]
	if correction >= 128:
		correction -= 256
	# Zone offsets nudge the sample's window (rarely used, cheap to honour).
	start += _signed_gen(ig, GEN_START_ADDRS) + _signed_gen(ig, GEN_START_COARSE) * 32768
	send += _signed_gen(ig, GEN_END_ADDRS) + _signed_gen(ig, GEN_END_COARSE) * 32768
	loop0 += _signed_gen(ig, GEN_STARTLOOP_ADDRS) + _signed_gen(ig, GEN_STARTLOOP_COARSE) * 32768
	loop1 += _signed_gen(ig, GEN_ENDLOOP_ADDRS) + _signed_gen(ig, GEN_ENDLOOP_COARSE) * 32768
	if ig.has(GEN_ROOT_KEY) and int(ig[GEN_ROOT_KEY]) < 128:
		root = int(ig[GEN_ROOT_KEY])
	var cents: float = float(correction) \
		+ float(_signed_gen(ig, GEN_FINE_TUNE)) \
		+ float(_signed_gen(ig, GEN_COARSE_TUNE)) * 100.0
	var loops: bool = (int(ig.get(GEN_SAMPLE_MODES, 0)) & 1) != 0
	if send <= start or rate <= 0:
		return {}
	var frames: int = send - start
	if frames > MAX_FRAMES:
		frames = MAX_FRAMES
		loops = loops and loop1 - start < MAX_FRAMES
	var f := FileAccess.open(sf.path, FileAccess.READ)
	if f == null:
		return {}
	f.seek(sf.smpl_off + start * 2)
	var pcm: PackedByteArray = f.get_buffer(frames * 2)
	f.close()
	if pcm.size() < 4:
		return {}
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.stereo = false
	st.mix_rate = rate
	st.data = pcm
	if loops and loop1 > loop0 and loop1 - start <= frames:
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_begin = maxi(loop0 - start, 0)
		st.loop_end = mini(loop1 - start, frames - 1)
	else:
		st.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return {"stream": st, "root": root, "cents": cents, "rate": rate,
		"looped": st.loop_mode == AudioStreamWAV.LOOP_FORWARD}

## A hard ceiling on how much of one sample is kept: 8 seconds at 44 kHz
## is far more than any GM instrument needs and keeps a 70 MB bank from
## turning into 70 MB of RAM.
const MAX_FRAMES: int = 44100 * 8

static func _signed_gen(g: Dictionary, oper: int) -> int:
	if not g.has(oper):
		return 0
	var v: int = int(g[oper])
	return v - 65536 if v >= 32768 else v
