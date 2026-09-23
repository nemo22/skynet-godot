## The converted maps in Godot's own format.
##
## A SkyNET level is DOS data: MAP.NNN (entity records) + WLD.NNN (the
## heightmap) + .3D meshes inside BSA archives. Every level load used to
## re-derive the whole world from that — read the archives, place a node
## per record, and build a collision shape for each one out of its mesh
## faces. It is the same work every time, and only the first half of it
## was cached (converted/mesh, converted/terrain).
##
## The conversion now also writes the WORLD ITSELF as a Godot scene:
##
##   converted/maps/MAP.210.level.scn
##
##   Level (level_scene_root.gd — map name, hash of the MAP it came from)
##   +- Terrain     MeshInstance3D + StaticBody3D (shared trimesh shape)
##   +- Static      every placed mesh with no behaviour, collision baked
##   +- Occluders   OccluderInstance3D — the hills and the big buildings
##   +- Behaviour   the map's doors, gates, lifts, destructibles,
##                  triggers, exits, sounds, messages and objectives as
##                  nodes, chains as NodePaths (scripts/level_behaviour.gd)
##
## The Behaviour branch is phases F1/F2 of docs/map_format_plan.md: the
## bake generates it, the editor shows it, and the running level lifts
## it out like the rest (take() below) — its root script walks the
## chains, fires the cues and sweeps every class of the DOS object layer
## from the nodes themselves (steps 5c-5h). Enemies, pickups, lights and
## markers are still
## built from the records by the loader.
##
## Two things this buys, both of them asked for (2026-09-04, "kludne
## nech konverzia spracuje tie data do formatu ktory vyhovuje godotu"):
##
##   * the editor opens a level directly — geometry, collision and all,
##     no import step, and the SkyNET Maps dock jumps straight to it;
##   * loading is an engine-side scene instantiation instead of a few
##     hundred GDScript nodes, and the collision shapes are shared
##     between every copy of a mesh AND between maps (converted/shape/)
##     instead of being rebuilt per instance.
##
## SOURCE, DERIVED, MOD. The DOS MAP is the source and nobody edits it;
## converted/maps/MAP.210.level.scn is derived from it; and a MOD is a
## Godot scene of your own that WINS over the derived one —
## mods/maps/MAP.210.level.scn is taken in its place, with no import and
## no rebake (mod_path / take below). A modded scene changes what is
## presented and where it stands; it does not change what the map DOES.
## Every trigger still comes from the DOS records, so a node the mod adds
## has no record behind it and can never fire, and one it deletes is
## still there as far as the trigger runtime is concerned.
##
## The derived scene is a build artefact: it carries the hash of the MAP
## file it was built from, so a change in the data invalidates it and the
## next load rebuilds it. That provenance is also
## written to a plain-text sidecar (MAP.210.level.txt) which is checked
## BEFORE the scene is touched — a Godot scene can run code as it loads,
## so a stale or foreign one must never get that far — and the scene
## itself is loaded only when the asset cache's trust manifest says this
## installation wrote it (asset_cache.gd).
##
## To ADD detail without replacing the level, put it in a scene of your
## own: mods/maps/MAP.210.detail.tscn is instantiated on top of any level
## whose name it matches, after overlay_problem() has made sure it is
## plain data (see "Hand-made overlays" below). Replacing the level
## outright is the .level.scn mod above.

extends RefCounted

const LevelRoot    := preload("res://scripts/level_scene_root.gd")
const WldTerrain   := preload("res://scripts/loaders/wld_terrain.gd")
const LevelLoaderRef := preload("res://scripts/level_loader.gd")
const LevelBehaviour := preload("res://scripts/level_behaviour.gd")
const PathsLib := preload("res://scripts/skynet_paths.gd")

## Bump when the bake changes shape (invalidates every saved scene).
## 8 = the Behaviour branch (2026-09-05); 9 = its root script and the
## 0x1B demolition targets as Damageables.
## 12: the submarine alarm and its kind of loop carry across a whole
## level (level_behaviour.LOUD_LOOPS), which is a property of the baked
## SoundLoop nodes — the maps already in the cache have to be built again.
## 13 (2026-09-14): visibility ranges on the baked nodes, and the
## provenance sidecar next to every scene.
## 14 (2026-09-23): the outdoor ground is built only over the border boxes
## and what can be seen from them (LevelLoader.terrain_crop).
const BAKE_VERSION: int = 14

# ---------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------
## Where the DERIVED level scene of this map lives ("" without a cache,
## or for a map name that is not a plain file name). This is where the
## bake writes; what the game PLAYS is resolved_scene_path().
static func scene_path(map_name: String) -> String:
	if Assets.root.is_empty():
		return ""
	var m: String = _map_file_name(map_name)
	return "" if m.is_empty() else "%s/maps/%s.level.scn" % [Assets.root, m]

## A level scene of the player's own, which replaces the derived one
## everywhere this map is presented. "" when there is none. Never
## generated, never deleted and never rebuilt by us: it is the mod.
static func mod_path(map_name: String) -> String:
	var m: String = _map_file_name(map_name)
	if m.is_empty():
		return ""
	var p: String = "%s/maps/%s.level.scn" % [PathsLib.mods_dir(), m]
	return p if FileAccess.file_exists(p) else ""

## Is this map presented by a mod scene rather than by the derived one?
static func is_modded(map_name: String) -> bool:
	return not mod_path(map_name).is_empty()

## The level scene this map is actually played from: the mod when there
## is one, the derived scene otherwise. Everything that RESOLVES a level
## scene asks this; only the bake itself asks scene_path().
static func resolved_scene_path(map_name: String) -> String:
	var m: String = mod_path(map_name)
	return m if not m.is_empty() else scene_path(map_name)

## A hand-made overlay for this map, instantiated on top of the baked
## level and never touched by the conversion.
static func overlay_path(map_name: String) -> String:
	var m: String = _map_file_name(map_name)
	return "" if m.is_empty() else "%s/maps/%s.detail.tscn" % [PathsLib.mods_dir(), m]

## The provenance sidecar of a baked scene: plain "key=value" lines
## (bake_version, source_hash, map), read without the resource loader.
static func sidecar_path(scene: String) -> String:
	return scene.get_basename() + ".txt"

## `map_name` upper-cased, or "" (with an error) when it could reach
## outside the maps folder.
static func _map_file_name(map_name: String) -> String:
	var m: String = Assets.safe_key(map_name)
	if m.is_empty():
		push_error("[level] refused map name %s" % map_name)
	return m

static func _read_sidecar(scene: String) -> Dictionary:
	var out: Dictionary = {}
	var sp := sidecar_path(scene)
	if not FileAccess.file_exists(sp):
		return out
	for line in FileAccess.get_file_as_string(sp).split("\n", false):
		var kv := line.strip_edges().split("=", true, 1)
		if kv.size() == 2 and kv[1].strip_edges().is_valid_int():
			out[kv[0].strip_edges()] = kv[1].strip_edges().to_int()
	return out

## Is the baked scene at `scene` from this bake and written by this
## installation? (Whether it matches the MAP is take()'s question — it
## has the bytes.)
static func is_current(scene: String) -> bool:
	return not scene.is_empty() and FileAccess.file_exists(scene) \
		and int(_read_sidecar(scene).get("bake_version", -1)) == BAKE_VERSION \
		and Assets.is_trusted(scene)

# ---------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------
## (Loaded on the main thread. A threaded load during the fade was tried
## on 2026-09-14: its materials came up with broken RIDs — they were built
## on worker threads while the same cached meshes were in use — so the
## level scene loads here, synchronously, as before.)

## The baked parts of `map_name`, or an empty dictionary when there is no
## scene for it (or it was built from a different MAP, or by an older
## bake, or not by this installation). Keys: terrain / static / occluders
## / behaviour — all detached Node3Ds ready to be added to the level.
static func take(map_name: String, map_bytes: PackedByteArray) -> Dictionary:
	var mp := mod_path(map_name)
	if not mp.is_empty():
		return _take_mod(map_name, mp)
	var p := scene_path(map_name)
	if p.is_empty() or not FileAccess.file_exists(p):
		return {}
	# Provenance first, from the sidecar: nothing of the scene is loaded
	# until it is known to be current and ours.
	var meta := _read_sidecar(p)
	if int(meta.get("bake_version", -1)) != BAKE_VERSION \
			or not meta.has("source_hash") or int(meta["source_hash"]) != hash(map_bytes):
		print("[level] %s: the baked scene is stale — rebuilding" % map_name)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar_path(p)))
		Assets.trust_forget(p)
		return {}
	if not Assets.is_trusted(p):
		print("[level] %s: the baked scene was not written by this installation — rebuilding" % map_name)
		return {}
	var _t0: int = Time.get_ticks_usec()
	# Straight off disk: a rebake writes the same path, and a stale copy
	# left in the resource cache would keep being handed back.
	var packed := ResourceLoader.load(p, "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var _t1: int = Time.get_ticks_usec()
	if packed == null:
		return {}
	var root: Node = packed.instantiate()
	if OS.get_cmdline_user_args().has("--load-trace"):
		print("[load-trace]   %s: ResourceLoader.load %.0f ms, instantiate %.0f ms"
			% [map_name, float(_t1 - _t0) / 1000.0,
			   float(Time.get_ticks_usec() - _t1) / 1000.0])
	if root == null:
		return {}
	if int(root.get("bake_version")) != BAKE_VERSION \
			or int(root.get("source_hash")) != hash(map_bytes):
		# The sidecar disagreed with the scene it sits beside.
		print("[level] %s: the baked scene is stale — rebuilding" % map_name)
		root.free()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
		Assets.trust_forget(p)
		return {}
	var out: Dictionary = _lift_branches(root)
	_mark_source(out, p)
	root.free()
	return out

## A MOD level scene, taken as it is. None of the checks below it apply:
## the provenance sidecar and the trust manifest say "this installation
## generated this file", which is the one thing a mod is not, and a stale
## derived scene is deleted and built again — which must never happen to
## somebody's own work. It is the player's file in the player's mods
## folder, and it is used because it is there.
##
## What it cannot do is change the map: the trigger records come from the
## DOS MAP either way (level_loader.gd), so the mod decides what is shown
## and where, and nothing else. A bake version it was not made for is
## said out loud rather than silently dropped — the branches are lifted
## by name and an old scene usually still has them.
static func _take_mod(map_name: String, p: String) -> Dictionary:
	var packed := ResourceLoader.load(p, "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		push_warning("[level] %s: the mod scene %s will not load" % [map_name, p])
		return {}
	var root: Node = packed.instantiate()
	if root == null:
		return {}
	if int(root.get("bake_version")) != BAKE_VERSION:
		push_warning("[level] %s: mod scene from bake %s, this is %d — used anyway"
			% [map_name, str(root.get("bake_version")), BAKE_VERSION])
	print("[level] %s: presented by the mod scene %s" % [map_name, p])
	var out: Dictionary = _lift_branches(root)
	_mark_source(out, p)
	root.free()
	return out

## The same lift out of a level scene SOMEBODY ELSE has already
## instantiated. A mission scene holds one instance per zone
## (scripts/mission_scene.gd) and the zone runtime builds its level from
## that instance rather than loading the same file a second time; the
## caller owns `root` and frees what is left of it.
##
## An empty answer means the instance is not this bake's or not this MAP's
## — the caller then falls back to take() (which rebuilds the file) or to
## the records.
static func take_from(root: Node, map_bytes: PackedByteArray) -> Dictionary:
	if root == null or not is_instance_valid(root):
		return {}
	if int(root.get("bake_version")) != BAKE_VERSION \
			or int(root.get("source_hash")) != hash(map_bytes):
		return {}
	var out: Dictionary = _lift_branches(root)
	_mark_source(out, root.scene_file_path)
	return out

## Which file the branches came from, for the log and for the tests that
## ask which scene was instanced. Only ever added to an answer that
## carries branches: an empty dictionary means "nothing baked", and a
## lone note about where the nothing came from would read as one.
static func _mark_source(out: Dictionary, p: String) -> void:
	if not out.is_empty():
		out["source"] = p

## Detach the four baked branches from an instantiated level scene.
static func _lift_branches(root: Node) -> Dictionary:
	var out: Dictionary = {}
	for key in ["Terrain", "Static", "Occluders", "Behaviour"]:
		var n: Node = root.get_node_or_null(NodePath(key))
		if n == null:
			continue
		root.remove_child(n)
		_disown(n)
		# The look settings may have changed since the bake.
		Render.restyle_tree(n)
		out[key.to_lower()] = n
	return out

## Clear the `owner` chain of a subtree lifted out of an instantiated
## scene — the scene root it points at is about to be freed.
static func _disown(n: Node) -> void:
	n.owner = null
	for c in n.get_children():
		_disown(c)

## The hand-made overlay for `map_name`, or null. One that is not plain
## data (overlay_problem) is refused with a message and skipped.
static func overlay(map_name: String) -> Node3D:
	var p := overlay_path(map_name)
	if p.is_empty() or not FileAccess.file_exists(p):
		return null
	var problem := overlay_problem(p)
	if not problem.is_empty():
		push_warning("[level] %s: overlay %s refused — %s" % [map_name, p, problem])
		return null
	# CACHE_MODE_IGNORE: load exactly the file that was just checked.
	var packed := ResourceLoader.load(p, "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return null
	var n: Node = packed.instantiate()
	if n is Node3D:
		print("[level] %s: hand-made overlay %s" % [map_name, p])
		return n as Node3D
	if n != null:
		n.free()
	return null

# ---------------------------------------------------------------------
# Hand-made overlays — checked before they load
# ---------------------------------------------------------------------
## A mod is data, not code. An overlay may build geometry, collision,
## lights and markers out of meshes, materials, textures and shapes —
## nothing that can run code as it loads or later: no script, no
## animation (a method track calls functions), no nested scene, no
## Object()/Resource() value, no signal connection, and no file outside
## the asset cache (only .res files this installation wrote) and the mods
## folder (only .tres resources, checked the same way).
const OVERLAY_NODE_TYPES: PackedStringArray = [
	"Node3D", "Marker3D", "MeshInstance3D", "MultiMeshInstance3D",
	"StaticBody3D", "CollisionShape3D", "CollisionPolygon3D",
	"OmniLight3D", "SpotLight3D", "DirectionalLight3D", "Sprite3D", "Label3D",
	"Decal", "OccluderInstance3D", "ReflectionProbe",
	"CSGCombiner3D", "CSGBox3D", "CSGCylinder3D", "CSGSphere3D", "CSGTorus3D",
	"CSGPolygon3D", "CSGMesh3D",
]
const OVERLAY_RESOURCE_TYPES: PackedStringArray = [
	"ArrayMesh", "BoxMesh", "CapsuleMesh", "CylinderMesh", "PlaneMesh", "QuadMesh",
	"PrismMesh", "SphereMesh", "TorusMesh", "TextMesh", "PointMesh", "MultiMesh",
	"StandardMaterial3D", "ORMMaterial3D",
	"Texture2D", "ImageTexture", "PortableCompressedTexture2D", "AtlasTexture",
	"GradientTexture1D", "GradientTexture2D", "Gradient", "Image",
	"BoxShape3D", "SphereShape3D", "CapsuleShape3D", "CylinderShape3D",
	"ConvexPolygonShape3D", "ConcavePolygonShape3D", "HeightMapShape3D",
	"WorldBoundaryShape3D", "SeparationRayShape3D", "PhysicsMaterial",
	"ArrayOccluder3D", "BoxOccluder3D", "QuadOccluder3D", "SphereOccluder3D",
	"PolygonOccluder3D",
]
## Value constructors that create or load arbitrary objects.
const OVERLAY_FORBIDDEN_CTORS: PackedStringArray = ["Object", "Resource", "Callable", "Signal"]
const OVERLAY_MAX_BYTES: int = 8 * 1024 * 1024

## Why the text scene (or, nested, the .tres) at `path` may not be loaded
## as part of an overlay — "" when it may.
static func overlay_problem(path: String, depth: int = 0) -> String:
	if depth > 4:
		return "resources nested too deep"
	var ext: String = "tscn" if depth == 0 else "tres"
	if path.get_extension().to_lower() != ext:
		return "only a text .%s is accepted" % ext
	if Assets.has_redirect(path):
		return "a .import/.remap file beside it redirects the loader"
	var size: int = FileAccess.get_size(path) if FileAccess.file_exists(path) else -1
	if size <= 0 or size > OVERLAY_MAX_BYTES:
		return "missing, empty or larger than %d MB" % (OVERLAY_MAX_BYTES >> 20)
	var want: String = "gd_scene" if depth == 0 else "gd_resource"
	var first: bool = true
	for it in _scan_text_resource(FileAccess.get_file_as_string(path)):
		match String(it[0]):
			"error":
				return String(it[1])
			"prop":
				if first:
					return "not a %s file" % want
				if String(it[1]) == "script":
					return "it sets a script"
			"ctor":
				if String(it[1]) in OVERLAY_FORBIDDEN_CTORS:
					return "it constructs a value with %s()" % it[1]
			"tag":
				var tag: String = it[1]
				var f: Dictionary = it[2]
				if first:
					first = false
					if tag != want:
						return "not a %s file" % want
					if depth > 0 and not _type_in(f, OVERLAY_RESOURCE_TYPES):
						return "a resource of type %s" % str(f.get("type"))
					continue
				match tag:
					"ext_resource":
						if not _type_in(f, OVERLAY_RESOURCE_TYPES):
							return "an external resource of type %s" % str(f.get("type"))
						var why := _overlay_ext_problem(f, path, depth)
						if not why.is_empty():
							return why
					"sub_resource":
						if not _type_in(f, OVERLAY_RESOURCE_TYPES):
							return "a sub-resource of type %s" % str(f.get("type"))
					"node":
						if f.has("instance") or f.has("instance_placeholder"):
							return "it instances another scene"
						if not _type_in(f, OVERLAY_NODE_TYPES):
							return "a node of type %s" % str(f.get("type"))
					"resource":
						if depth == 0:
							return "a [resource] section in a scene"
					_:
						return "a [%s] section" % tag
	return "empty" if first else ""

static func _type_in(fields: Dictionary, allowed: PackedStringArray) -> bool:
	var t: Variant = fields.get("type")
	return t is String and String(t) in allowed

## Where an [ext_resource] can make the loader go — its path (relative to
## the file that names it) and the path its UID is registered under — and
## whether an overlay may go there.
static func _overlay_ext_problem(f: Dictionary, owner_path: String, depth: int) -> String:
	if not (f.get("path") is String):
		return "an external resource without a plain path"
	var p: String = f["path"]
	if not p.contains("://") and p.is_relative_path():
		p = owner_path.get_base_dir().path_join(p)
	var targets := PackedStringArray([p])
	if f.has("uid"):
		if not (f["uid"] is String):
			return "an external resource with an unreadable uid"
		var id: int = ResourceUID.text_to_id(String(f["uid"]))
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			targets.append(ResourceUID.get_id_path(id))
	for t in targets:
		var ext: String = t.get_extension().to_lower()
		if Assets.is_cache_path(t):
			if ext != "res" or not Assets.is_trusted(t):
				return "%s is not a cache file this installation wrote" % t
		elif _inside(t, PathsLib.mods_dir()):
			if ext != "tres":
				return "%s is not a .tres resource" % t
			var why := overlay_problem(t, depth + 1)
			if not why.is_empty():
				return "%s: %s" % [t.get_file(), why]
		else:
			return "%s is outside the asset cache and the mods folder" % t
	return ""

static func _inside(path: String, dir: String) -> bool:
	var base: String = _norm(dir)
	return not base.is_empty() and _norm(path).begins_with(base + "/")

static func _norm(p: String) -> String:
	var g := ProjectSettings.globalize_path(p).replace("\\", "/").simplify_path()
	if OS.has_feature("windows") or OS.has_feature("macos"):
		g = g.to_lower()
	return g.trim_suffix("/")

## A small reader for Godot's text resource format: just enough to see
## what a file asks the loader to create, never building anything. It
## follows the engine's own tokenizer (core/variant/variant_parser.cpp)
## where that matters — a property name gathers every non-blank character
## up to "=", so "scr ipt =" and "\"script\" =" both set `script`; ";"
## starts a comment between properties; strings span lines; a
## constructor is an identifier before "(".
## Items: ["tag", name, {field: plain string or null}], ["prop", name],
## ["ctor", identifier], and a final ["error", why] when it cannot follow.
static func _scan_text_resource(t: String) -> Array:
	var out: Array = []
	var n: int = t.length()
	var i: int = 0
	var what: String = ""
	# Before the first section and after these, the engine reads the next
	# section header straight away, skipping ANY text up to the next "["
	# (quotes and ";" included) — so only blanks may stand there.
	var gap: bool = true
	while i < n:
		var c: int = t.unicode_at(i)
		if gap:
			var open: int = t.find("[", i)
			var stop: int = n if open < 0 else open
			if not t.substr(i, stop - i).strip_edges().is_empty():
				out.append(["error", "text between sections"])
				return out
			if open < 0:
				return out
			c = 91
			i = open
		if c == 59:                                  # ; comment
			var nl: int = t.find("\n", i)
			i = n if nl < 0 else nl + 1
		elif c == 91 and what.is_empty():            # [ a section
			var tag: Array = _scan_tag(t, i + 1, out)
			if tag.is_empty():
				out.append(["error", "a malformed [section]"])
				return out
			out.append(["tag", tag[0], tag[1]])
			i = int(tag[2])
			gap = String(tag[0]) in ["gd_scene", "gd_resource", "ext_resource", "connection", "editable"]
		elif c <= 32:
			i += 1
		elif c == 34:                                # a quoted property name
			var tok: Array = _token(t, i)
			if tok[0] != "str" or String(tok[1]).contains("\\"):
				out.append(["error", "an unreadable property name"])
				return out
			what = tok[1]
			i = int(tok[2])
		elif c == 61:                                # = then one value
			out.append(["prop", what])
			what = ""
			i = _scan_value(t, _token(t, i + 1), out)
			if i < 0:
				out.append(["error", "a value this check cannot follow"])
				return out
		else:
			what += char(c)
			i += 1
	return out

## [name key=value …]: the name, the fields, the index after "]" — or []
## when malformed. A field is kept as its string when it is a plain string
## literal, null otherwise (and every value is scanned for constructors).
static func _scan_tag(t: String, i: int, out: Array) -> Array:
	var tok: Array = _token(t, i)
	if tok[0] != "id":
		return []
	var name: String = tok[1]
	i = int(tok[2])
	var fields: Dictionary = {}
	var naming: bool = true
	while true:
		tok = _token(t, i)
		if tok[0] == "punct" and tok[1] == "]":
			return [name, fields, int(tok[2])]
		if naming and tok[0] == "punct" and (tok[1] == "." or tok[1] == ":"):
			name += String(tok[1])
			tok = _token(t, int(tok[2]))
		else:
			naming = false
		if tok[0] != "id":
			return []
		if naming:
			name += String(tok[1])
			i = int(tok[2])
			continue
		var key: String = tok[1]
		var eq: Array = _token(t, int(tok[2]))
		if eq[0] != "punct" or eq[1] != "=":
			return []
		var val: Array = _token(t, int(eq[2]))
		var plain: Variant = null
		if val[0] == "str" and not String(val[1]).contains("\\"):
			plain = String(val[1])
		fields[key] = plain
		i = _scan_value(t, val, out)
		if i < 0:
			return []
	return []

## Plain packed-array contents: numbers, commas, blanks (no string, no
## nested call), skipped in one step instead of token by token.
static var _plain_re: RegEx = RegEx.create_from_string("[^\\s0-9A-Za-z_.,+\\-]")

## One value starting at token `tok`; returns the index after it, or -1.
static func _scan_value(t: String, tok: Array, out: Array) -> int:
	match String(tok[0]):
		"str", "num":
			return int(tok[2])
		"id":
			var id: String = tok[1]
			if id in ["true", "false", "null", "nan", "inf", "inf_neg"]:
				return int(tok[2])
			var nxt: Array = _token(t, int(tok[2]))
			if (id == "Array" or id == "Dictionary") and nxt[0] == "punct" and nxt[1] == "[":
				var e: int = _scan_group(t, int(nxt[2]), "]", out)
				if e < 0:
					return -1
				nxt = _token(t, e)
			if nxt[0] != "punct" or nxt[1] != "(":
				return -1
			out.append(["ctor", id])
			if id.begins_with("Packed") and id != "PackedStringArray":
				var close: int = t.find(")", int(nxt[2]))
				if close >= 0 and _plain_re.search(t, int(nxt[2]), close) == null:
					return close + 1
			return _scan_group(t, int(nxt[2]), ")", out)
		"punct":
			if tok[1] == "[":
				return _scan_group(t, int(tok[2]), "]", out)
			if tok[1] == "{":
				return _scan_group(t, int(tok[2]), "}", out)
	return -1

## Tokens up to the `close` ending this group, nested groups and the
## constructors inside included; the index after `close`, or -1.
static func _scan_group(t: String, i: int, close: String, out: Array) -> int:
	while i >= 0:
		var tok: Array = _token(t, i)
		match String(tok[0]):
			"eof", "err":
				return -1
			"punct":
				var p: String = tok[1]
				if p == close:
					return int(tok[2])
				elif p == "(":
					i = _scan_group(t, int(tok[2]), ")", out)
				elif p == "[":
					i = _scan_group(t, int(tok[2]), "]", out)
				elif p == "{":
					i = _scan_group(t, int(tok[2]), "}", out)
				elif p == ")" or p == "]" or p == "}":
					return -1
				else:
					i = int(tok[2])
			"id":
				var nxt: Array = _token(t, int(tok[2]))
				if nxt[0] == "punct" and nxt[1] == "(":
					out.append(["ctor", tok[1]])
				i = int(tok[2])
			_:
				i = int(tok[2])
	return -1

## The token at `i` (blanks skipped): [kind, text, index after it] with
## kind "punct", "str" (raw text between the quotes; &"…" and ^"…" too),
## "num" (numbers and #colours), "id", "eof" or "err".
static func _token(t: String, i: int) -> Array:
	var n: int = t.length()
	while i < n and t.unicode_at(i) <= 32:
		i += 1
	if i >= n:
		return ["eof", "", n]
	var c: int = t.unicode_at(i)
	match c:
		123, 125, 91, 93, 40, 41, 58, 44, 46, 61:    # { } [ ] ( ) : , . =
			return ["punct", char(c), i + 1]
		38, 94:                                      # & ^ before a string
			if i + 1 < n and t.unicode_at(i + 1) == 34:
				return _token(t, i + 1)
			return ["err", "", i]
		34:                                          # "
			var j: int = i + 1
			while j < n:
				var d: int = t.unicode_at(j)
				if d == 92:                          # backslash escapes the next one
					j += 2
					continue
				if d == 34:
					return ["str", t.substr(i + 1, j - i - 1), j + 1]
				j += 1
			return ["err", "", n]
	if c == 35 or c == 43 or c == 45 or (c >= 48 and c <= 57):   # # + - digit
		var j: int = i + 1
		while j < n and (_ident_char(t.unicode_at(j)) or t.unicode_at(j) == 46 \
				or ((t.unicode_at(j) == 43 or t.unicode_at(j) == 45) and t.unicode_at(j - 1) in [69, 101])):
			j += 1
		return ["num", t.substr(i, j - i), j]
	if c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
		var j: int = i + 1
		while j < n and _ident_char(t.unicode_at(j)):
			j += 1
		return ["id", t.substr(i, j - i), j]
	return ["err", "", i]

static func _ident_char(c: int) -> bool:
	return c == 95 or (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)

# ---------------------------------------------------------------------
# Baking
# ---------------------------------------------------------------------
## Pack the static half of a freshly built level and save it. The nodes
## stay where they are — they are lent to a temporary root for the pack
## and handed straight back, so the level that triggered the bake is the
## one that gets played.
static func save_from(level, map_name: String) -> String:
	if not Assets.enabled or not Assets.may_write(map_name + ".level.scn"):
		return ""
	var p := scene_path(map_name)
	if p.is_empty():
		return ""
	var root: Node3D = LevelRoot.new()
	root.name = "Level_" + map_name.replace(".", "_")
	root.map_name = map_name
	root.bake_version = BAKE_VERSION
	root.source_hash = hash(level.map_bytes)
	root.is_outdoor = level.is_outdoor
	# The static half of level.entities is lifted into a "Static" node for
	# the pack and put straight back afterwards, so the level that
	# triggered the bake keeps playing with the very same nodes.
	var statics := Node3D.new()
	statics.name = "Static"
	var moved: Array = []
	if level.entities != null and is_instance_valid(level.entities):
		for c in static_children(level.entities):
			level.entities.remove_child(c)
			statics.add_child(c)
			moved.append(c)
	root.static_count = moved.size()

	# An environment and a key light, for the EDITOR only: open the scene
	# on its own and the map has a sky and a light. The runtime never sees
	# this: take() lifts out the groups below and frees everything else
	# with the root.
	root.add_child(_preview_branch(level))

	# What goes in, and where it came from, so it can all go back.
	var lent: Array = []                     # [node, old_parent, index]
	for g in [["Terrain", level.terrain], ["Static", statics],
			["Occluders", level.occluders]]:
		var n: Node = g[1]
		if n == null or not is_instance_valid(n):
			continue
		var old: Node = n.get_parent()
		var idx: int = n.get_index() if old != null else -1
		if old != null:
			old.remove_child(n)
		n.name = String(g[0])
		root.add_child(n)
		lent.append([n, old, idx])

	# The map's behaviour as nodes, built fresh from the records (never
	# lent: the game's own ActionTargets stay where they are).
	var report: Dictionary = {}
	var behaviour: Node3D = LevelBehaviour.build(level, report)
	root.add_child(behaviour)
	root.behaviour_count = LevelBehaviour.count(behaviour)

	for c in root.get_children():
		_own(c, root)
	# The behaviour nodes are instances of scenes/level/*.tscn with their
	# inner nodes filled in (a Mover's Body, Mesh and Shape); the packer
	# only records those overrides for instances the root marks editable.
	_mark_editable(root, root)
	var ps := PackedScene.new()
	# Sibling names must be unique in the packed scene. The loader names a
	# mesh after its entity (JWALL08 ×6), the tree auto-renames the copies
	# ("@MeshInstance3D@878") and PackedScene saves those; on instantiate
	# Godot 4 regenerates such names, two siblings can collide, and a
	# child whose name collides never enters the tree — invisible, and an
	# error every frame from anything asking for its global transform (40
	# walls of Future Shock's MAP.010, 19 of MAP.210, 2026-09-06).
	_unique_sibling_names(root)
	var err: int = ps.pack(root)
	var out: String = ""
	if err == OK:
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		# The sidecar goes first and comes back last: a save that dies half
		# way leaves a scene with no provenance, which is rebuilt.
		var side := sidecar_path(p)
		if FileAccess.file_exists(side):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(side))
		err = ResourceSaver.save(ps, p, ResourceSaver.FLAG_COMPRESS)
		if err == OK:
			Assets.trust_record(p)
			var w := FileAccess.open(side, FileAccess.WRITE)
			if w != null:
				w.store_string("bake_version=%d\nsource_hash=%d\nmap=%s\n"
					% [BAKE_VERSION, hash(level.map_bytes), map_name.to_upper()])
				w.close()
			out = p
			print("[level] %s: baked %d static meshes and %d behaviour nodes into %s"
				% [map_name, root.static_count, root.behaviour_count, p.get_file()])
			print("[level] %s: behaviour %s; %d relays, %d cue meshes, %d movers without a mesh, %d links to markers, %d dangling"
				% [map_name, str(report.get("kinds", {})),
				   int(report.get("kinds", {}).get("raw", 0)), int(report.get("cues_with_mesh", 0)),
				   int(report.get("movers_without_mesh", 0)), int(report.get("to_markers", 0)),
				   int(report.get("dangling", 0))])
		else:
			push_warning("[level] cannot save %s (%s)" % [p, error_string(err)])
	else:
		push_warning("[level] cannot pack %s (%s)" % [map_name, error_string(err)])
	# Hand everything back exactly where it was.
	for item in lent:
		var n: Node = item[0]
		root.remove_child(n)
		_disown(n)
		var old: Node = item[1]
		if old != null and is_instance_valid(old):
			old.add_child(n)
			if int(item[2]) >= 0:
				old.move_child(n, int(item[2]))
	for c in moved:
		statics.remove_child(c)
		_disown(c)
		level.entities.add_child(c)
	statics.free()
	root.free()
	return out

## The children of an entity container that carry no behaviour: plain
## geometry, safe to bake. A door, a lift, a destructible car or a
## proximity trigger is an ActionTarget (it answers file_off()) and is
## built from the MAP records every time.
static func static_children(entities: Node) -> Array:
	var out: Array = []
	if entities == null or not is_instance_valid(entities):
		return out
	for c in entities.get_children():
		if c is MeshInstance3D and not c.has_method("file_off"):
			out.append(c)
	return out

## Everything the runtime builds from the MAP records, shown in the
## editor: the enemies where they stand, the placement markers, the map's
## own lights, and a night sky.
##
## Other engines put the dynamic objects straight in the level file,
## because there the level file IS the source. Here the source is the DOS
## MAP — the port converts it and exports edits back to it — so the level
## scene is a build product and its behaviour has to come from the
## records. This branch closes the gap for the EYE: open a baked level
## and the whole map is there, robots included, with the markers drawn as
## labelled gizmos. The runtime lifts out Terrain/Static/Occluders/Behaviour
## and frees this with the root, so none of it reaches the game.
static func _preview_branch(level) -> Node3D:
	var root := Node3D.new()
	root.name = "EditorPreview"
	_preview_actors(root, level)
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.015, 0.020, 0.055)
	sky_mat.sky_horizon_color = Color(0.055, 0.070, 0.125)
	sky_mat.ground_bottom_color = Color(0.03, 0.03, 0.04)
	sky_mat.ground_horizon_color = Color(0.055, 0.070, 0.125)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.name = "PreviewEnvironment"
	we.environment = env
	root.add_child(we)
	var moon := DirectionalLight3D.new()
	moon.name = "PreviewMoon"
	moon.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	moon.light_color = Color(0.72, 0.78, 0.96)
	moon.light_energy = 0.9
	moon.shadow_enabled = true
	root.add_child(moon)
	return root

## The enemies, the markers and the map lights, as the editor sees them.
static func _preview_actors(root: Node3D, level) -> void:
	if level == null or level.map == null:
		return
	var enemies := Node3D.new()
	enemies.name = "Enemies"
	root.add_child(enemies)
	var markers := Node3D.new()
	markers.name = "Markers"
	root.add_child(markers)
	var lights := Node3D.new()
	lights.name = "MapLights"
	root.add_child(lights)
	var gizmos: Dictionary = {}
	for e in level.map.entities:
		var variant: int = e.flags & 3
		if variant == 2:
			if e.light_enable <= 0:
				continue
			var l := OmniLight3D.new()
			l.name = "LIGHT_%06x" % e.file_off
			l.position = Vector3(float(e.x), -float(e.y), -float(e.z))
			l.omni_range = clampf(float(e.light_enable) * 10.0, 400.0, 6000.0)
			l.light_energy = clampf(float(e.light_intensity) / 14.0, 0.4, 3.5)
			lights.add_child(l)
			continue
		if variant != 3:
			continue
		if e.marker_type == 2:
			# An enemy: its type's mesh, first frame, where it starts.
			var nm: String = ""
			if e.enemy_type >= 0 and e.enemy_type < LevelLoaderRef.ENEMY_MESH.size():
				nm = String(LevelLoaderRef.ENEMY_MESH[e.enemy_type])
			if nm.is_empty():
				continue
			var frames: Array = Assets.mesh_frames(nm.to_upper() + ".3D")
			if frames.is_empty():
				continue
			var mi := MeshInstance3D.new()
			mi.name = "%s_%06x" % [nm.to_upper(), e.file_off]
			mi.mesh = frames[0]
			mi.position = Vector3(float(e.x), -float(e.y + 0x10), -float(e.z))
			mi.rotation.y = (e.off_y & 0x7FF) * TAU / 2048.0
			enemies.add_child(mi)
		elif e.marker_type >= 0:
			var mk := MeshInstance3D.new()
			mk.name = "MARKER%d_%06x" % [e.marker_type, e.file_off]
			mk.mesh = _gizmo_mesh(_marker_color(e.marker_type), gizmos)
			mk.position = Vector3(float(e.x), -float(e.y + 0x10), -float(e.z))
			var tag := Label3D.new()
			tag.name = "Label"
			tag.text = "M%d" % e.marker_type
			tag.pixel_size = 1.0
			tag.font_size = 48
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.no_depth_test = true
			tag.position = Vector3(0.0, 60.0, 0.0)
			mk.add_child(tag)
			markers.add_child(mk)

## A small unshaded box, one per colour.
static func _gizmo_mesh(color: Color, cache: Dictionary) -> BoxMesh:
	var key: String = color.to_html()
	if cache.has(key):
		return cache[key]
	var bm := BoxMesh.new()
	bm.size = Vector3(48.0, 48.0, 48.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	bm.material = mat
	cache[key] = bm
	return bm

## Same colours the editor's data view uses, so a marker reads the same
## in both places.
static func _marker_color(t: int) -> Color:
	match t:
		0: return Color(0.2, 1.0, 0.2)        # player start
		1: return Color(0.2, 0.6, 1.0)        # facing
		100: return Color(1.0, 0.5, 0.1)      # waypoint
	if t >= 10 and t <= 29:
		return Color(1.0, 0.2, 0.9)           # exit / MP spawn pairs
	return Color(0.85, 0.85, 0.85)

## Give the level root every node the bake built. A node that already
## has an owner is the inside of an instanced scenes/level/ scene (its
## Body, its Shape) and keeps it — the instance is what gets saved.
static func _own(n: Node, owner: Node) -> void:
	if n.owner == null:
		n.owner = owner
	for c in n.get_children():
		_own(c, owner)

## Every instanced scene under `n` becomes an editable instance of the
## root, so the properties the bake set on its inner nodes are packed.
static func _mark_editable(n: Node, root: Node) -> void:
	for c in n.get_children():
		if not c.scene_file_path.is_empty():
			root.set_editable_instance(c, true)
		_mark_editable(c, root)

# ---------------------------------------------------------------------
# Collision — one shape per MESH, shared by every copy and every map
# ---------------------------------------------------------------------
## Give `mi` the trimesh body the level needs, from the shared shape
## cache (converted/shape/<key>.res).
##
## Every entity used to call create_trimesh_collision(), which walks the
## mesh faces and builds a private ConcavePolygonShape3D — 410 of them
## on MAP.240, many of which are the same warehouse over and over. Now
## the shape is built once, cached on disk, and referenced.
static func add_collision(mi: MeshInstance3D, key: String) -> bool:
	if mi == null or mi.mesh == null:
		return false
	var shape: ConcavePolygonShape3D = Assets.shape(key, mi.mesh)
	if shape == null:
		return false
	var sb := StaticBody3D.new()
	sb.name = mi.name + "_col"
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	cs.shape = shape
	sb.add_child(cs)
	mi.add_child(sb)
	return true

# ---------------------------------------------------------------------
# Occluders
# ---------------------------------------------------------------------
## Godot can cull what is hidden behind an occluder, but only if the
## level says what the occluders ARE. Outdoors that is the terrain: from
## the jeep in the hills of MAP.220 the engine was submitting the whole
## valley behind the ridge in front of you, which is exactly the view
## that stuttered (2026-09-04). Indoors it is the walls.
##
## Terrain: a coarse grid (every OCC_STEP-th cell) whose every vertex
## takes the LOWEST ground around it and then drops another OCC_SINK —
## an occluder must never stand higher than the thing it stands for, or
## it culls what you can actually see.
const OCC_STEP: int = 4
const OCC_SINK: float = 48.0
## Static meshes big enough to hide something behind them go in with
## their real triangles (exact geometry is always safe), largest first,
## until the budget is used up.
const OCC_MESH_MIN_SIZE: float = 700.0
const OCC_MESH_MAX_TRIS: int = 1500
const OCC_BUDGET_TRIS: int = 42000

## Build the "Occluders" node for a level, or null when there is nothing
## worth occluding with.
static func build_occluders(level) -> Node3D:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	if level.wld != null:
		_terrain_occluder(level.wld, verts, idx, level.terrain_crop)
	_mesh_occluders(level, verts, idx)
	if idx.is_empty():
		return null
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var oi := OccluderInstance3D.new()
	oi.name = "Occluder"
	oi.occluder = occ
	var root := Node3D.new()
	root.name = "Occluders"
	root.add_child(oi)
	@warning_ignore("integer_division")
	print("[level] occluders: %d triangles" % (idx.size() / 3))
	return root

## Over the cells the ground is built on (`crop`, LevelLoader.terrain_crop)
## — an occluder past the edge of the drawn ground would hide the sky.
static func _terrain_occluder(w, verts: PackedVector3Array, idx: PackedInt32Array,
		crop: Rect2i = Rect2i()) -> void:
	var cells: Rect2i = WldTerrain.crop_or_all(crop)
	@warning_ignore("integer_division")
	var cols: int = maxi(cells.size.x / OCC_STEP, 1)
	@warning_ignore("integer_division")
	var rows: int = maxi(cells.size.y / OCC_STEP, 1)
	var stride: int = cols + 1
	var base: int = verts.size()
	verts.resize(base + stride * (rows + 1))
	for r in range(rows + 1):
		for c in range(stride):
			var col: int = mini(cells.position.x + c * OCC_STEP, cells.end.x)
			var row: int = mini(cells.position.y + r * OCC_STEP, cells.end.y)
			# The lowest ground anywhere in this vertex's neighbourhood.
			var h: float = 1e9
			for dr in range(-OCC_STEP, OCC_STEP + 1):
				for dc in range(-OCC_STEP, OCC_STEP + 1):
					h = minf(h, WldTerrain.corner_height(w,
						clampi(col + dc, 0, WldTerrain.GRID_W - 1),
						clampi(row + dr, 0, WldTerrain.GRID_H - 1)))
			verts[base + r * stride + c] = Vector3(
				float(col) * WldTerrain.WORLD_PER_CELL,
				h - OCC_SINK,
				-(WldTerrain.Z_FLIP_K - float(row) * WldTerrain.WORLD_PER_CELL))
	for r in rows:
		for c in cols:
			var v0: int = base + r * stride + c
			_quad(idx, v0, v0 + 1, v0 + stride + 1, v0 + stride)

## Two triangles, both windings — the occlusion rasteriser gets a solid
## surface either way round.
static func _quad(idx: PackedInt32Array, a: int, b: int, c: int, d: int) -> void:
	idx.append_array(PackedInt32Array([a, b, c, a, c, d, a, c, b, a, d, c]))

static func _mesh_occluders(level, verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	@warning_ignore("integer_division")
	var budget: int = OCC_BUDGET_TRIS - idx.size() / 3
	if budget <= 0:
		return
	# Biggest first: one warehouse hides more than twenty crates. Only
	# static geometry — a door that swings open must never occlude.
	var big: Array = []
	for c in static_children(level.entities):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var s: Vector3 = mi.mesh.get_aabb().size
		var longest: float = maxf(s.x, maxf(s.y, s.z))
		if longest >= OCC_MESH_MIN_SIZE:
			big.append([longest, mi])
	big.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))
	for item in big:
		var mi: MeshInstance3D = item[1]
		var faces: PackedVector3Array = mi.mesh.get_faces()
		@warning_ignore("integer_division")
		var tris: int = faces.size() / 3
		if tris <= 0 or tris > OCC_MESH_MAX_TRIS or tris * 2 > budget:
			continue
		budget -= tris * 2
		var xf: Transform3D = mi.transform
		var base: int = verts.size()
		for v in faces:
			verts.append(xf * v)
		for t in tris:
			var a: int = base + t * 3
			idx.append_array(PackedInt32Array([a, a + 1, a + 2, a, a + 2, a + 1]))

## Rename every node whose name is auto-generated ("@Class@id") or clashes
## with a sibling: <base>_<n>, the base being the mesh it carries or its
## class. Deterministic, so a re-bake gives the same names.
static func _unique_sibling_names(node: Node) -> void:
	var seen: Dictionary = {}
	for c in node.get_children():
		var base: String = String(c.name)
		if base.begins_with("@") or base.is_empty():
			base = c.get_class()
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				var rp: String = (c as MeshInstance3D).mesh.resource_path.get_file().get_basename()
				if not rp.is_empty():
					base = rp
		var nm: String = base
		var k: int = 1
		while seen.has(nm):
			k += 1
			nm = "%s_%d" % [base, k]
		seen[nm] = true
		if nm != String(c.name):
			c.name = nm
		_unique_sibling_names(c)
