## A whole MISSION as one Godot scene — and the bake that writes it.
##
##   converted/missions/MISSION.210.scn
##
##   MISSION_210 (this script)
##   +- EditorPreview  a sky and a key light, for opening the scene alone
##   +- Zones
##   |    Zone_MAP_210 (scripts/mission/zone.gd) at (0, 0, 0)
##   |      Level      an instance of converted/maps/MAP.210.level.scn
##   |    Zone_MAP_218 … on +X, one slot each
##   +- Portals
##   |    Portal_MAP_210_0cabb (scripts/mission/portal.gd)
##   +- Phases
##        World_MAP_210 (scripts/mission/phase_world.gd)
##          Phase_216 (scripts/mission/phase_switch.gd) — the census diff
##          Phase_217
##
## (A node name cannot hold a dot, so MAP.218's zone is Zone_MAP_218.
## EditorPreview comes first because every level scene brings a preview of
## its own and the earliest WorldEnvironment in the tree is the one the
## view takes — scripts/mission/zone.gd.)
##
## Why: a DOS mission is not one map. MAP.210 is the base, its five
## interiors are their own MAP files reached through 0xF0 doorways, and
## MAP.216/217 are MAP.210 itself re-authored later in the same mission.
## The port used to unload the world and load the next file at every
## doorway, which is where the state, the music and the objectives kept
## falling over. Held in one scene, a doorway becomes a move across the
## same world (docs/m2_mission_scene_plan.md).
##
## LAYOUT. Float precision is the budget: the mission's own outdoor world
## stands at the origin, and every other zone is placed along +X — an
## extra outdoor world takes a whole 65536-unit map, an interior takes its
## own cell grid — with a gap between them, and the whole mission is kept
## inside SPAN_LIMIT.
##
## The zones are INSTANCES of the level scenes, not copies: rebake
## MAP.213 and the mission scene picks it up. The instance is always the
## DERIVED converted/maps/MAP.NNN.level.scn, never a mod — a cache file
## may only reference cache files (asset_cache._dep_ok), and a mission
## scene pointing into mods/ would fail its own trust check and be rebaked
## on every start. A mod is put in the zone's place when the zone is
## BUILT, by the loader (level_loader.load_zone), so dropping one in or
## taking it out is picked up on the next start with nothing to rebake.
##
## The bake is a build artefact like every other cache file — a sidecar
## carries the bake version, the maps it was built from and a hash of
## their bytes, and a mission whose data moved is written again
## (Assets.mission_scene).
##
## Everything here is DATA. The runtime that walks a portal is step 4 of
## the plan and the one that applies a phase is step 5; until then the
## per-map runtime plays the game exactly as before.
@tool
extends Node3D

const LevelScene := preload("res://scripts/level_scene.gd")
const MissionCensus := preload("res://tools/mission_census.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")
const BSAReader := preload("res://scripts/loaders/bsa_reader.gd")
const ZoneScript := preload("res://scripts/mission/zone.gd")
const PortalScript := preload("res://scripts/mission/portal.gd")
const PhaseSwitchScript := preload("res://scripts/mission/phase_switch.gd")
const PhaseWorldScript := preload("res://scripts/mission/phase_world.gd")

## Bump when the bake changes shape (every saved mission scene is then
## rebuilt). 1 = the first one (2026-09-15).
const MISSION_BAKE_VERSION: int = 1

## The +X grid. An outdoor map is 64x64 cells of 1024 units, so a world
## gets a whole one; an interior gets its own grid width. GAP keeps the
## zones apart so nothing of one can ever reach into the next — a stray
## explosion radius, a 12 000-unit draw distance, the sky dome.
const OUTDOOR_SLOT: float = 65536.0
const CELL: float = 1024.0
const GAP: float = 16384.0
## Past this the single-precision transforms start to show (a 32-bit float
## has ~0.03 unit resolution at 500 000), so a mission that would need
## more is built anyway and says so.
const SPAN_LIMIT: float = 450000.0

## The campaign missions of SkyNET, by their start map.
const STARTS: PackedInt32Array = [210, 220, 230, 240, 252, 260, 270, 280]

## Where this script lives — a script cannot preload itself, and the bake
## has to put this very script on the root it builds.
const SELF_PATH := "res://scripts/mission_scene.gd"

# --- what the baked root carries --------------------------------------
@export var mission: int = 0
@export var start_map: String = ""
@export var bake_version: int = 0
## hash() over every MAP the mission uses and the heightmaps under them.
@export var source_hash: int = 0
## The zones in the order they were placed, the world first.
@export var zone_maps: PackedInt32Array = PackedInt32Array()
## Every MAP the bake read — the zones and the re-authored variants — which
## is what source_hash covers and what the sidecar lists.
@export var source_maps: PackedInt32Array = PackedInt32Array()
## For the log and the editor inspector.
@export var portal_count: int = 0
@export var phase_count: int = 0
## How far the mission reaches along +X (SPAN_LIMIT is the budget).
@export var span: float = 0.0
## Whatever the census could not make sense of (a missing map, an exit to
## a marker set the target has not got, a mission with two worlds).
@export var warnings: PackedStringArray = PackedStringArray()

# ---------------------------------------------------------------------
# Paths and provenance
# ---------------------------------------------------------------------
static func scene_path(start: int) -> String:
	if Assets.root.is_empty():
		return ""
	return "%s/missions/MISSION.%03d.scn" % [Assets.root, start]

## Plain "key=value" lines beside the scene, read without the resource
## loader — a Godot scene can run code as it loads, so its provenance is
## checked before it is touched (the level scenes do the same).
static func _read_sidecar(scene: String) -> Dictionary:
	var out: Dictionary = {}
	var sp := LevelScene.sidecar_path(scene)
	if not FileAccess.file_exists(sp):
		return out
	for line in FileAccess.get_file_as_string(sp).split("\n", false):
		var kv := line.strip_edges().split("=", true, 1)
		if kv.size() == 2:
			out[kv[0].strip_edges()] = kv[1].strip_edges()
	return out

## The maps a saved mission scene was built from, so the check below can
## hash them again without running the census.
static func _sidecar_maps(meta: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in String(meta.get("maps", "")).split(",", false):
		if s.strip_edges().is_valid_int():
			out.append(int(s))
	return out

## Every DOS map the baked mission scene of `start` holds — its zones AND
## the re-authored variants of its worlds — straight out of the sidecar,
## without loading the scene. This is the census's own answer to "which
## mission is this map played in", which no map number can give on its own:
## the interiors belong to two missions apiece (MAP.211-215 to missions 1
## and 2, MAP.242-248 to 4 and 5, MAP.281-286 to 7 and 8) and MAP.250 is
## mission 5's world although it starts no mission at all. Empty when the
## mission has never been baked (Assets.mission_maps caches it).
static func baked_maps(start: int) -> PackedInt32Array:
	var p := scene_path(start)
	if p.is_empty() or not FileAccess.file_exists(p):
		return PackedInt32Array()
	return _sidecar_maps(_read_sidecar(p))

## A fingerprint of everything the bake read: the bytes of every MAP the
## mission uses (zones AND the re-authored variants, whose records are the
## phase diffs) and the heightmaps under them.
static func source_hash_of(maps: PackedInt32Array, bsa: BSAReader) -> int:
	var sorted: Array = []
	for n in maps:
		if not sorted.has(int(n)):
			sorted.append(int(n))
	sorted.sort()
	var parts := PackedStringArray(["v%d" % MISSION_BAKE_VERSION])
	for n in sorted:
		parts.append("MAP.%03d=%d" % [n, hash(bsa.read("MAP.%03d" % n))])
		var wp: String = SkynetPaths.gamedata_path("WLD.%03d" % n)
		if FileAccess.file_exists(wp):
			parts.append("WLD.%03d=%s" % [n, FileAccess.get_md5(wp)])
	return hash(";".join(parts))

## Is the mission scene on disk this bake's, built from this data, and
## written by this installation?
static func is_current(start: int, bsa: BSAReader) -> bool:
	return stale_reason(start, bsa).is_empty()

## Why the mission scene on disk cannot be used, "" when it can. The bake
## says it in the log: a rebake that happens for no visible reason is
## nearly always the last of these — the scene, or a level scene or asset
## it stands on, that this installation's trust manifest has no record of
## (a checkout moved to another disk or machine without its user://
## cache_manifest rebuilds each mission once, the first time it is played).
static func stale_reason(start: int, bsa: BSAReader) -> String:
	var p := scene_path(start)
	if p.is_empty() or not FileAccess.file_exists(p):
		return "not baked yet"
	var meta := _read_sidecar(p)
	if int(meta.get("bake_version", "-1")) != MISSION_BAKE_VERSION:
		return "baked by bake %s, this is %d" % [meta.get("bake_version", "?"), MISSION_BAKE_VERSION]
	var maps := _sidecar_maps(meta)
	if maps.is_empty():
		return "its sidecar names no maps"
	if int(meta.get("source_hash", "0")) != source_hash_of(maps, bsa):
		return "the maps or heightmaps it was baked from changed"
	if not Assets.is_trusted(p):
		return "it or a scene it stands on was not written by this installation"
	return ""

# ---------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------
## Where every map of the mission stands. Returns
##   order:    the zone maps in placement order, the world first
##   origin:   map → Vector3 (a phase variant shares its world's origin)
##   phase_of: variant map → the world map it re-authors
##   info:     map → the census zone record
##   span:     how far the mission reaches along +X
static func _layout(start: int, report: Dictionary) -> Dictionary:
	var phase_of: Dictionary = {}
	for w in report["phases"]:
		var ps: Array = w["phases"]
		for i in range(1, ps.size()):
			phase_of[int(ps[i]["map"])] = int(w["world"])
	var zones: Array = []
	var info: Dictionary = {}
	for z in report["zones"]:
		var n: int = int(z["map"])
		info[n] = z
		if not phase_of.has(n):
			zones.append(n)
	var out: Dictionary = {"order": [], "origin": {}, "phase_of": phase_of,
		"info": info, "primary": start, "span": 0.0}
	if zones.is_empty():
		return out
	# The mission's own world goes to the origin: the start map when it is
	# outdoors, else the first outdoor world the mission walks into
	# (mission 5 starts inside the submarine — its world is MAP.250).
	var primary: int = int(zones[0])
	for n in zones:
		if bool((info[n] as Dictionary)["outdoor"]):
			primary = int(n)
			break
	var order: Array = [primary]
	for n in zones:
		if int(n) != primary:
			order.append(int(n))
	var origin: Dictionary = {}
	var cursor: float = 0.0
	for n in order:
		origin[n] = Vector3(cursor, 0.0, 0.0)
		cursor += _slot(info[n]) + GAP
	for n in phase_of:
		origin[int(n)] = origin[int(phase_of[n])]
	out["order"] = order
	out["origin"] = origin
	out["primary"] = primary
	out["span"] = maxf(cursor - GAP, 0.0)
	return out

static func _slot(z: Dictionary) -> float:
	if bool(z["outdoor"]):
		return OUTDOOR_SLOT
	return maxf(float(int((z["grid"] as Array)[0])) * CELL, CELL)

# ---------------------------------------------------------------------
# Baking
# ---------------------------------------------------------------------
## Build the mission scene and save it. `bsa` is an open reader on the map
## archive; `cache` is the census's parsed-map cache, shared between
## missions so the interiors they have in common are read once.
## Returns the path, or "".
static func save(start: int, bsa: BSAReader, cache: Dictionary) -> String:
	var p := scene_path(start)
	if p.is_empty():
		return ""
	var report: Dictionary = MissionCensus._mission(start, bsa, cache)
	var root: Node3D = _build(start, report, bsa, cache)
	if root == null:
		return ""
	var ps := PackedScene.new()
	var err: int = ps.pack(root)
	var out: String = ""
	if err == OK:
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		# The sidecar goes last and is removed first: a save that dies half
		# way leaves a scene with no provenance, which is built again.
		var side := LevelScene.sidecar_path(p)
		if FileAccess.file_exists(side):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(side))
		err = ResourceSaver.save(ps, p, ResourceSaver.FLAG_COMPRESS)
		if err == OK:
			Assets.trust_record(p)
			var w := FileAccess.open(side, FileAccess.WRITE)
			if w != null:
				var names := PackedStringArray()
				for n in (root.source_maps as PackedInt32Array):
					names.append(str(n))
				w.store_string("bake_version=%d\nsource_hash=%d\nmission=%d\nmaps=%s\n"
					% [MISSION_BAKE_VERSION, int(root.source_hash), start,
					   ",".join(names)])
				w.close()
			out = p
			print("[mission] %d: %d zones, %d portals, %d phase edges, %.0f k units wide → %s"
				% [start, (root.zone_maps as PackedInt32Array).size(),
				   int(root.portal_count), int(root.phase_count),
				   float(root.span) / 1000.0, p.get_file()])
			for wmsg in (root.warnings as PackedStringArray):
				print("[mission] %d: ! %s" % [start, wmsg])
		else:
			push_warning("[mission] cannot save %s (%s)" % [p, error_string(err)])
	else:
		push_warning("[mission] cannot pack mission %d (%s)" % [start, error_string(err)])
	root.free()
	return out

static func _build(start: int, report: Dictionary, bsa: BSAReader,
		cache: Dictionary) -> Node3D:
	var lay := _layout(start, report)
	var order: Array = lay["order"]
	if order.is_empty():
		push_warning("[mission] %d reaches no map that can be read" % start)
		return null
	var origin: Dictionary = lay["origin"]
	var phase_of: Dictionary = lay["phase_of"]
	var info: Dictionary = lay["info"]
	if float(lay["span"]) >= SPAN_LIMIT:
		push_warning("[mission] %d spans %.0f units, past the %.0f the port keeps for float precision"
			% [start, float(lay["span"]), SPAN_LIMIT])

	var root: Node3D = load(SELF_PATH).new()
	root.name = "MISSION_%03d" % start
	root.mission = start
	root.start_map = "MAP.%03d" % start
	root.bake_version = MISSION_BAKE_VERSION
	var notes := PackedStringArray(report["warnings"])
	if float(lay["span"]) >= SPAN_LIMIT:
		notes.append("the mission spans %.0f units, past the %.0f kept for float precision"
			% [float(lay["span"]), SPAN_LIMIT])
	# The mission's own sky and key light go in FIRST, on purpose: a
	# WorldEnvironment claims the view for whichever of them stands
	# earliest in the tree, and every zone brings one of its own
	# (_quiet_preview).
	root.add_child(_preview_branch())
	var zones_node := Node3D.new()
	zones_node.name = "Zones"
	root.add_child(zones_node)
	var portals_node := Node3D.new()
	portals_node.name = "Portals"
	root.add_child(portals_node)
	var phases_node := Node3D.new()
	phases_node.name = "Phases"
	root.add_child(phases_node)

	# --- zones ---------------------------------------------------------
	# Which variants each world runs through, so a zone can name its own.
	var phases_of_world: Dictionary = {}
	for w in report["phases"]:
		var names := PackedStringArray()
		var nums := PackedInt32Array()
		var ps: Array = w["phases"]
		for i in ps.size():
			nums.append(int(ps[i]["map"]))
			if i > 0:
				names.append("MAP.%03d" % int(ps[i]["map"]))
		phases_of_world[int(w["world"])] = {"names": names, "nums": nums}

	var zone_nodes: Dictionary = {}          # map → Node3D
	var placed := PackedInt32Array()
	for n in order:
		var num: int = int(n)
		var names := PackedStringArray()
		if phases_of_world.has(num):
			names = (phases_of_world[num] as Dictionary)["names"]
		var z := _zone_node(num, info[num], origin[num], names, cache)
		if z == null:
			notes.append("MAP.%03d has no baked level scene — the zone is missing" % num)
			continue
		zones_node.add_child(z)
		zone_nodes[num] = z
		placed.append(num)
	root.zone_maps = placed

	# --- portals -------------------------------------------------------
	for p in report["portals"]:
		var src: int = int(p["map"])
		var host: int = int(phase_of.get(src, src))
		var zn: Node3D = zone_nodes.get(host)
		if zn == null:
			continue
		var node: Node3D = PortalScript.new()
		node.name = "Portal_MAP_%03d_%s" % [src, String(p["off"])]
		node.source_map = src
		node.file_off = String(p["off"]).hex_to_int()
		var pos: Array = p["pos"]
		# The DOS record → Godot, as the action system reads an exit:
		# x, -y, -z, with no marker lift (that is the SPAWN's rule).
		var local := Vector3(float(pos[0]), -float(pos[1]), -float(pos[2]))
		node.local_pos = local
		node.world_pos = local + (origin[host] as Vector3)
		node.position = node.world_pos
		node.target_map = int(p["target"])
		node.marker_set = int(p["marker_set"])
		node.kind = String(p["kind"])
		node.state = int(p["state"])
		node.armed_by = PackedStringArray(p["armed_by"])
		portals_node.add_child(node)
		node.source_zone = node.get_path_to(zn)
		# Where it leads. A return has no fixed target (it depends on the
		# doorway the player came in by) and a hand-over leaves the
		# mission altogether — both keep an empty zone and Vector3.INF.
		var t: int = int(p["target"])
		if t > 0 and String(p["kind"]).begins_with("portal"):
			var thost: int = int(phase_of.get(t, t))
			var tzn: Node3D = zone_nodes.get(thost)
			if tzn != null:
				node.target_zone = node.get_path_to(tzn)
				var mp := _marker_pos(cache, t, int(p["marker_set"]))
				if mp != Vector3.INF:
					node.target_pos = mp + (origin[thost] as Vector3)
	root.portal_count = portals_node.get_child_count()

	# --- phases --------------------------------------------------------
	var diffs: Dictionary = {}               # "from>to" → the census diff
	for d in report["diffs"]:
		diffs["%d>%d" % [int(d["from"]), int(d["to"])]] = d
	var edges: int = 0
	for w in report["phases"]:
		var world: int = int(w["world"])
		var wn: Node3D = PhaseWorldScript.new()
		wn.name = "World_MAP_%03d" % world
		wn.world_map = world
		wn.phase_maps = (phases_of_world[world] as Dictionary)["nums"]
		phases_node.add_child(wn)
		if zone_nodes.has(world):
			wn.zone = wn.get_path_to(zone_nodes[world])
		var ps: Array = w["phases"]
		for i in range(1, ps.size()):
			var a: int = int(ps[i - 1]["map"])
			var b: int = int(ps[i]["map"])
			var d: Dictionary = diffs.get("%d>%d" % [a, b], {})
			if d.is_empty():
				continue
			wn.add_child(_phase_node(a, b, d, cache))
			edges += 1
	root.phase_count = edges

	# --- provenance ------------------------------------------------------
	# Every map the bake read, placed or not, so a mission whose missing
	# zone comes back is built again.
	var all_maps := PackedInt32Array()
	for n in order:
		all_maps.append(int(n))
	for n in phase_of:
		all_maps.append(int(n))
	root.source_maps = all_maps
	root.source_hash = source_hash_of(all_maps, bsa)
	root.span = float(lay["span"])
	root.warnings = notes

	for c in root.get_children():
		_own(c, root)
	# Nothing inside a Level instance is touched or marked editable: that
	# would make the packer store an entry for every one of the level's
	# ~1900 nodes. A zone puts its level's own EditorPreview out itself,
	# when it comes up (scripts/mission/zone.gd).
	return root

## One zone: the Node3D on the +X grid and the level scene under it.
static func _zone_node(num: int, z: Dictionary, at: Vector3,
		phase_names: PackedStringArray, cache: Dictionary) -> Node3D:
	var map_name := "MAP.%03d" % num
	# The level scene is the bake's input: make sure it is there and
	# current before the mission scene points at it. The DERIVED one — see
	# the header on why a mod cannot be instanced here and where it comes
	# in instead.
	var lp: String = Assets.level_scene(map_name)
	if lp.is_empty() or not FileAccess.file_exists(lp):
		push_warning("[mission] %s has no level scene to stand on" % map_name)
		return null
	var packed := ResourceLoader.load(lp, "PackedScene",
		ResourceLoader.CACHE_MODE_REUSE) as PackedScene
	if packed == null:
		push_warning("[mission] %s: the level scene will not load" % map_name)
		return null
	var node: Node3D = ZoneScript.new()
	node.name = "Zone_MAP_%03d" % num
	node.position = at
	node.map_name = map_name
	node.map_num = num
	node.outdoor = bool(z["outdoor"])
	node.grid = Vector2i(int((z["grid"] as Array)[0]), int((z["grid"] as Array)[1]))
	node.depth = int(z["depth"])
	var from: Array = z["entered_from"]
	node.entered_from_map = int(from[0])
	node.entered_from_off = int(from[1])
	node.spawn_sets = PackedInt32Array(z["marker_sets"])
	node.phases = phase_names
	if node.outdoor and FileAccess.file_exists(SkynetPaths.gamedata_path("WLD.%03d" % num)):
		node.wld_suffix = "%03d" % num
	var parsed = (cache.get(num, {}) as Dictionary).get("map")
	if parsed != null:
		node.maptype = _maptype(parsed)
		node.water_y = _water_y(parsed)
	var level: Node = packed.instantiate()
	level.name = "Level"
	node.add_child(level)
	return node

## One phase edge, with the census diff carried over as plain data and
## every entity's record offset resolved through its identity key.
static func _phase_node(from_map: int, to_map: int, d: Dictionary,
		cache: Dictionary) -> Node3D:
	var node: Node3D = PhaseSwitchScript.new()
	node.name = "Phase_%03d" % to_map
	node.from_map = from_map
	node.to_map = to_map
	if FileAccess.file_exists(SkynetPaths.gamedata_path("WLD.%03d" % to_map)):
		node.wld_suffix = "%03d" % to_map
	var keys_a: Dictionary = (cache.get(from_map, {}) as Dictionary).get("keys", {})
	var keys_b: Dictionary = (cache.get(to_map, {}) as Dictionary).get("keys", {})
	var added: Array[Dictionary] = []
	for x in d["added"]:
		added.append({"id": String(x["id"]), "off": _off_of(keys_b, x["id"]),
			"does": String(x["does"])})
	var removed: Array[Dictionary] = []
	for x in d["removed"]:
		removed.append({"id": String(x["id"]), "off": _off_of(keys_a, x["id"]),
			"does": String(x["does"])})
	var changed: Array[Dictionary] = []
	for x in d["changed"]:
		changed.append({"id": String(x["id"]), "off": _off_of(keys_b, x["id"]),
			"was": String(x["was"]), "now": String(x["now"])})
	node.added = added
	node.removed = removed
	node.changed = changed
	var terrain: Dictionary = {}
	for L in [0, 2]:
		var key: String = "terrain_layer_%d" % L
		if d.has(key):
			terrain["layer_%d" % L] = d[key]
	node.terrain = terrain
	return node

static func _off_of(keys: Dictionary, id: Variant) -> int:
	var e = keys.get(id)
	return int(e.file_off) if e != null else -1

## The spawn point of marker set `set_id` in MAP.<num>, zone-local — the
## rule main._frame_camera lands a map exit on (marker type N = the
## position, N+1 = the facing; the marker's Y is stored 0x10 short).
## Vector3.INF when the map has no such marker.
static func _marker_pos(cache: Dictionary, num: int, set_id: int) -> Vector3:
	var z: Dictionary = cache.get(num, {})
	if z.is_empty() or not bool(z.get("ok", false)):
		return Vector3.INF
	var m: MapFile.MapFile = z["map"]
	for e in m.entities:
		if (e.flags & 3) == 3 and e.marker_type == set_id:
			return Vector3(float(e.x), -float(e.y + 0x10), -float(e.z))
	return Vector3.INF

## DOS maptype (MapStart): marker type 6, value at sub+2; 0 without one.
static func _maptype(m: MapFile.MapFile) -> int:
	for e in m.entities:
		if (e.flags & 3) == 3 and e.marker_type == 6:
			return int(e.exit_map)
	return 0

## Marker 103/104 is the map's water level: the surface sits 16 units
## above the marker in Godot (DOS Y − 0x10, Y-down). INF when dry.
static func _water_y(m: MapFile.MapFile) -> float:
	for e in m.entities:
		if (e.flags & 3) == 3 and (e.marker_type == 103 or e.marker_type == 104):
			return -float(e.y) + 16.0
	return INF

## An environment and a key light for the EDITOR only, so opening a
## mission scene shows a lit world instead of a black one. The runtime
## takes the zones it wants and frees the rest.
static func _preview_branch() -> Node3D:
	var root := Node3D.new()
	root.name = "EditorPreview"
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

## Give the mission root every node the bake built. A node that already
## has an owner is the inside of an instanced level scene and keeps it —
## the instance is what gets saved, not its contents.
static func _own(n: Node, owner: Node) -> void:
	if n.owner == null:
		n.owner = owner
	for c in n.get_children():
		_own(c, owner)
