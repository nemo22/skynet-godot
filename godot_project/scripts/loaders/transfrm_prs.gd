## TRANSFRM.PRS loader — destructible-object damage stages.
##
## TRANSFRM.PRS (inside MDMDBRIF.BSA) is an INI-like text file listing
## the "Transform" objects: for each mesh name, the ordered list of
## replacement meshes shown as the object takes damage (e.g. carhip0a →
## carhip0b → carhip0c wreck stages). Parsed by TransformInit
## (FUN_00120000, skynet_gh.c:23719); consumed by the 0x18/0x19 action
## handler (Skynet.exe 0x120433) which swaps the displayed mesh per
## damage stage.
##
## Format:
##   [objectN]
##   name    = carhip0a
##   type    = ?
##   frames  = 3
##   frame0  = carhip0a
##   frame1  = carhip0b
##   frame2  = carhip0c

extends RefCounted

## Parse the PRS text. Returns { mesh_name_lower: PackedStringArray of
## frame mesh names (frame0 = intact) }. Empty dictionary on bad input.
static func parse(bytes: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	if bytes.is_empty():
		return out
	var text := bytes.get_string_from_ascii()
	var cur_name: String = ""
	var cur_frames: PackedStringArray = []
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with(";"):
			continue
		if line.begins_with("["):
			if not cur_name.is_empty() and cur_frames.size() > 1:
				out[cur_name] = cur_frames
			cur_name = ""
			cur_frames = PackedStringArray()
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges().to_lower()
		var val := line.substr(eq + 1).strip_edges()
		if key == "name":
			cur_name = val.to_lower()
		elif key.begins_with("frame") and key != "frames":
			cur_frames.append(val.to_lower())
	if not cur_name.is_empty() and cur_frames.size() > 1:
		out[cur_name] = cur_frames
	return out
