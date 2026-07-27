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

## Parse a decrypted briefing .TXT. Returns
## {objectives: String, lines: Array[{speaker:int, text:String}]}.
static func parse(bytes: PackedByteArray) -> Dictionary:
	var text: String = bytes.get_string_from_ascii()
	return {
		"objectives": _objectives(text),
		"lines": _dialogue(text),
	}

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
