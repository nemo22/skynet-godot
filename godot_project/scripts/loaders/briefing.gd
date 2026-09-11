## Mission briefing parser — MDMDBRIF.BSA "NNN.TXT" files.
##
## A briefing file is section-based. Each section opens with a "[XX]"
## header line and ends at a "%%%%" line; entries are split by "####".
## Bracketed lines are tags, not display text:
##   [vNNNNN]          a voice-line id (precedes a dialogue entry)
##   [NNN]             the speaker number for the entry that follows
##   [000.102.…]       an objective flag
##
## Sections used here:
##   [EN] — the mission objectives paragraph
##   [BR] — the pre-mission briefing dialogue (HQ radio conversation),
##          one entry per speaker turn
##
## The DOS briefing screen shows BRIEF<speaker>.IMG for each turn while
## the voice line plays (FUN_0012c300 / FUN_0012bfb0, skynet_gh.c).
##
## BSAReader.read() returns the file already decrypted.

extends RefCounted

const NEWLINE := "\n"

## Parse a decrypted briefing .TXT. Returns
## {objectives: String, lines: Array[{speaker:int, text:String}],
##  missions: Array[String], hints: Array[String], tactical: Array[String]}.
static func parse(bytes: PackedByteArray) -> Dictionary:
	var text: String = bytes.get_string_from_ascii()
	return {
		"objectives": _objectives(text),
		"lines": _dialogue(text),
		"missions": _numbered(text, "M", 5),
		"mission_texts": _sections(text, "M", 5),
		"hints": _numbered(text, "G", 9),
		"tactical": _words(text, "[TA]"),
	}

## The [M1]..[M5] / [G1]..[G9] sections, in order, "" where absent.
##
## [M<n>] are the MISSION OBJECTIVES: the DOS engine counts these entries
## at briefing-parse time (FUN_0012ce73, skynet_gh.c:31618) into the
## "objectives remaining" counter, and act 0x26+n on a map entity
## decrements it and prints the matching line. [G<n>] are act 0x1C+n
## flavour messages that change no counter. Mission 1 (210.TXT) has
## M1..M3 and G1..G5 + G9.
static func _numbered(text: String, prefix: String, count: int) -> Array:
	var out: Array = []
	for i in count:
		var got: Array = _entries(text, "[%s%d]" % [prefix, i + 1])
		out.append(String(got[0]) if not got.is_empty() else "")
	return out

## Every entry of [M1]..[M5]. The DOS engine counts them ALL into the
## objective counter (FUN_0012ce73) and each act 0x26+n prints the NEXT
## one of its section — v1.01 handler 0x137fd0 steps a text pointer past
## the one it showed. MAP.232's nine consoles are nine entries of [M1];
## counting sections ended mission 4 at the second display.
static func _sections(text: String, prefix: String, count: int) -> Array:
	var out: Array = []
	for i in count:
		out.append(_entries(text, "[%s%d]" % [prefix, i + 1]))
	return out

## The [TA] section lists one asset name per line (tachkftr, tacscout …)
## — the enemy dossiers the TACTICAL tab shows.
static func _words(text: String, header: String) -> Array:
	var out: Array = []
	for entry in _entries(text, header):
		for w in String(entry).split(" ", false):
			var n: String = w.strip_edges()
			if not n.is_empty():
				out.append(n)
	return out

## Entries of one section: text between the header and "%%%%", split on
## "####", bracketed tag lines dropped.
static func _entries(text: String, header: String) -> Array:
	var out: Array = []
	var inside: bool = false
	var buf: Array[String] = []
	for raw in text.split(NEWLINE):
		var line: String = raw.strip_edges()
		if not inside:
			if line == header:
				inside = true
			continue
		if line.begins_with("%%%%"):
			break
		if line == "####":
			if not buf.is_empty():
				out.append(" ".join(buf))
				buf.clear()
			continue
		if line.is_empty() or (line.begins_with("[") and line.ends_with("]")):
			continue
		buf.append(line)
	if not buf.is_empty():
		out.append(" ".join(buf))
	return out

## The [EN] mission-objectives paragraph.
static func _objectives(text: String) -> String:
	var out: Array[String] = []
	var inside: bool = false
	for raw in text.split("\n"):
		var line: String = raw.strip_edges()
		if not inside:
			if line == "[EN]":
				inside = true
			continue
		if line.begins_with("%%%%"):
			break
		if line == "####" or line.is_empty():
			continue
		if line.begins_with("[") and line.ends_with("]"):
			continue
		out.append(line)
	return " ".join(out).strip_edges()

## The [BR] dialogue as an ordered list of {speaker, text} turns.
static func _dialogue(text: String) -> Array:
	var lines: Array = []
	var inside: bool = false
	var speaker: int = 3
	var buf: Array[String] = []
	for raw in text.split("\n"):
		var line: String = raw.strip_edges()
		if not inside:
			if line == "[BR]":
				inside = true
			continue
		if line.begins_with("%%%%"):
			break
		if line == "####":
			if not buf.is_empty():
				lines.append({"speaker": speaker, "text": " ".join(buf)})
				buf.clear()
			continue
		if line.is_empty():
			continue
		if line.begins_with("[") and line.ends_with("]"):
			var tag: String = line.substr(1, line.length() - 2)
			if tag.is_empty():
				continue
			if tag[0] == "v" or tag[0] == "V":
				continue                       # voice-line id
			if tag.contains("."):
				break                           # objective flag — end of dialogue
			if tag.is_valid_int():
				speaker = tag.to_int()
			continue
		buf.append(line)
	return lines
