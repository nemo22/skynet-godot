## HMI (Human Machine Interfaces "HMI-MIDISONG061595") music parser —
## the loose gamedata/T*.HMI + TITLE.HMI files the DOS engine plays
## (FUN_000129bc; song header parsed by FUN_00017880, skynet_gh.c:7979).
##
## Header (song): 0xD2 u16 ticks per beat (96 or 480 — informational),
## 0xD4 u16 TIMER RATE in Hz (120: the DOS player hands it straight to
## the timer-callback setup, skynet_gh.c:7931, so every song ticks at
## a fixed 120 Hz regardless of the division — confirmed by the .XMI
## twins in MDMDMUSC.BSA, which run at XMIDI's fixed 120 Hz and carry
## the same tick counts and note counts), 0xE4 u16 track count, 0xE8
## u32 offset of the track offset table (u32 each). Track:
## "HMI-MIDITRACK", +0x57 u32 = offset of the event stream (relative
## to the track).
##
## Events are standard MIDI with running status and standard varlen
## deltas — with two twists: a note-on carries a varlen DURATION after
## the velocity (no note-offs in the stream, like XMI), and 0xFE
## introduces HMI-private events whose lengths were worked out from
## TITLE.HMI: FE 10 = 4 bytes + (byte[4] + 5) more, FE 12 = 4, FE 13
## = 12, FE 14 = 4, FE 15 = 8.
##
## parse() returns {"division", "rate" (ticks per second), "length"
## (ticks), "events"} where events is a flat PackedInt32Array of 5-int records
## [tick, kind, channel, data1, data2], sorted by tick, with note-offs
## already materialised; kind = MIDI status nibble (0x80 off, 0x90 on,
## 0xB0 controller, 0xC0 program, 0xE0 bend as 0..16383) or 0x51 for a
## tempo meta (data1 = µs per beat).

const MAGIC := "HMI-MIDISONG061595"
const TRACK_MAGIC := "HMI-MIDITRACK"
const REC: int = 5
## More tracks than any song needs (the game's own have 6-17); a header
## count up to 65 535 is ignored past this.
const MAX_TRACKS: int = 256

static func _u16(b: PackedByteArray, o: int) -> int:
	return b[o] | (b[o + 1] << 8)

static func _u32(b: PackedByteArray, o: int) -> int:
	return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

static func parse(b: PackedByteArray) -> Dictionary:
	if b.size() < 0x100 or b.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		return {}
	var division: int = _u16(b, 0xD2)
	var rate: int = _u16(b, 0xD4)
	if division <= 0:
		division = 96
	if rate <= 0 or rate > 1000:
		rate = 120
	var ntracks: int = mini(_u16(b, 0xE4), MAX_TRACKS)
	var table: int = _u32(b, 0xE8)
	if ntracks <= 0 or table <= 0 or table + ntracks * 4 > b.size():
		return {}
	var offs: Array = []
	for i in ntracks:
		offs.append(_u32(b, table + i * 4))
	# A track ends where the next one (in file order) starts: one sorted
	# list answers that by binary search.
	var starts := PackedInt64Array(offs)
	starts.sort()
	# [key, tick, kind, ch, d1, d2] rows; key orders same-tick events:
	# controllers/programs first, then note-offs, then note-ons.
	var rows: Array = []
	var length: int = 0
	var parsed: Dictionary = {}
	for i in ntracks:
		var off: int = offs[i]
		# Each distinct track once, in table order: a crafted table naming
		# one track over and over used to parse it that many times.
		if parsed.has(off):
			continue
		parsed[off] = true
		if off <= 0 or off + 0x60 > b.size():
			continue
		if b.slice(off, off + TRACK_MAGIC.length()).get_string_from_ascii() != TRACK_MAGIC:
			continue
		var pos: int = off + _u32(b, off + 0x57)
		var end: int = b.size()
		var nxt: int = starts.bsearch(off, false)    # first start > off
		if nxt < starts.size():
			end = mini(starts[nxt], end)
		var t: int = _parse_track(b, pos, end, rows, {})
		if t > length:
			length = t
	rows.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	var ev := PackedInt32Array()
	ev.resize(rows.size() * REC)
	for i in rows.size():
		var r: Array = rows[i]
		var o: int = i * REC
		ev[o] = r[1]
		ev[o + 1] = r[2]
		ev[o + 2] = r[3]
		ev[o + 3] = r[4]
		ev[o + 4] = r[5]
	return {"division": division, "rate": rate, "length": length, "events": ev}

## Standard MIDI variable-length number, at most 4 bytes (28 bits; the
## game's songs use 3). Returns -1 for a longer one: without the cap ten
## continuation bytes overflowed into a negative length that moved the
## read position backwards, and the track loop never ended.
static func _varlen(b: PackedByteArray, st: Array) -> int:
	var v: int = 0
	var pos: int = st[0]
	var n: int = 0
	while pos < b.size():
		if n == 4:
			st[0] = pos
			return -1
		var c: int = b[pos]
		pos += 1
		n += 1
		v = (v << 7) | (c & 0x7F)
		if (c & 0x80) == 0:
			break
	st[0] = pos
	return v

static func _push(rows: Array, tick: int, kind: int, ch: int, d1: int, d2: int) -> void:
	var prio: int = 0
	if kind == 0x80:
		prio = 1
	elif kind == 0x90:
		prio = 2
	rows.append([tick * 4 + prio, tick, kind, ch, d1, d2])

## Parse one track's event stream into `rows`; returns its end tick.
static func _parse_track(b: PackedByteArray, pos: int, end: int, rows: Array, stats: Dictionary) -> int:
	var st: Array = [pos]
	var tick: int = 0
	var status: int = 0
	var size: int = b.size()
	var last: int = -1
	stats["end"] = "ran off the end"
	while st[0] < end:
		# Every event moves forward; one that does not is corrupt data, and
		# looping on it would hang the main thread.
		if st[0] <= last:
			stats["end"] = "stalled"
			break
		last = st[0]
		var delta: int = _varlen(b, st)
		if delta < 0:
			stats["end"] = "corrupt delta time"
			break
		tick += delta
		if st[0] >= end:
			break
		var c: int = b[st[0]]
		if c >= 0x80:
			status = c
			st[0] += 1
		if status == 0xFE:
			# HMI-private event: sub-type byte then a fixed payload.
			var sub: int = b[st[0]] if st[0] < end else 0
			var fe: Dictionary = stats.get("fe", {})
			fe[sub] = int(fe.get(sub, 0)) + 1
			stats["fe"] = fe
			match sub:
				0x10:
					var p: int = st[0] + 3            # past sub + 2 bytes
					st[0] = p + (int(b[p]) + 5 if p < end else 0)
				0x12:
					st[0] += 3
				0x13:
					st[0] += 11
				0x14:
					st[0] += 3
				0x15:
					st[0] += 7
				_:
					st[0] += 1
			status = 0
			continue
		if status == 0xFF:
			if st[0] >= size:
				stats["end"] = "truncated meta event"
				break
			var mt: int = b[st[0]]
			st[0] += 1
			var ln: int = _varlen(b, st)
			if mt == 0x2F:
				stats["end"] = "end of track"
				break
			if ln < 0:
				stats["end"] = "corrupt meta length"
				break
			if mt == 0x51 and ln == 3:
				if st[0] + 3 > size:
					stats["end"] = "truncated tempo"
					break
				var us: int = (b[st[0]] << 16) | (b[st[0] + 1] << 8) | b[st[0] + 2]
				_push(rows, tick, 0x51, 0, us, 0)
			st[0] += ln
			status = 0
			continue
		if status == 0xF0 or status == 0xF7:
			var ln: int = _varlen(b, st)
			if ln < 0:
				stats["end"] = "corrupt sysex length"
				break
			st[0] += ln
			status = 0
			continue
		if status < 0x80:
			stats["end"] = "lost sync (byte %02x)" % c
			stats["last"] = st[0]
			break
		var kind: int = status & 0xF0
		var ch: int = status & 0x0F
		# Data bytes the event reads below; a file cut short mid-event must
		# not index past the buffer.
		var reads: int = 2 if kind == 0x90 or kind == 0xB0 or kind == 0xE0 else \
			(1 if kind == 0x80 or kind == 0xC0 else 0)
		if st[0] + reads > size:
			stats["end"] = "truncated event"
			break
		match kind:
			0x80:
				var n: int = b[st[0]]
				st[0] += 2
				_push(rows, tick, 0x80, ch, n, 0)
			0x90:
				var n: int = b[st[0]]
				var v: int = b[st[0] + 1]
				st[0] += 2
				var dur: int = _varlen(b, st)
				if dur < 0:
					stats["end"] = "corrupt note duration"
					break
				if stats.has("durs"):
					(stats["durs"] as Array).append(dur)
				if v == 0:
					_push(rows, tick, 0x80, ch, n, 0)
				else:
					_push(rows, tick, 0x90, ch, n, v)
					_push(rows, tick + maxi(dur, 1), 0x80, ch, n, 0)
			0xA0:
				st[0] += 2
			0xB0:
				_push(rows, tick, 0xB0, ch, b[st[0]], b[st[0] + 1])
				st[0] += 2
			0xC0:
				_push(rows, tick, 0xC0, ch, b[st[0]], 0)
				st[0] += 1
			0xD0:
				st[0] += 1
			0xE0:
				var lo: int = b[st[0]]
				var hi: int = b[st[0] + 1]
				st[0] += 2
				_push(rows, tick, 0xE0, ch, lo | (hi << 7), 0)
			_:
				stats["end"] = "unknown status %02x" % status
				stats["last"] = st[0]
				break
	return tick
