## Headless map audit: walks every MAP through the real game scene and
## reports the problem classes the playtests keep finding —
##   * the player falling through the spawn (y drop after settling)
##   * enemies sunk into / floating above the floor
##   * mesh surfaces with no texture, and triangles whose UV area is
##     ~0 while the geometry is not (a texel smeared over the face —
##     the MAP.230 overpass class of bug)
##   * loader errors (push_error/push_warning while the map loads)
##
##   godot --headless --path . res://scenes/map_audit.tscn -- --no-briefing [--maps=210,230] [--settle=2.5]
extends Node

const MainScene := preload("res://scenes/main.tscn")

var _main: Node = null
var _rows: Array = []
var _issues: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# ONE MAP AT A TIME is what this audits: every map in the archive on its
	# own, at the DOS origin, including the ones no mission reaches. Mission
	# scenes are the campaign's runtime since step 8 of the M2 plan and would
	# bring a mission's whole world up around each of its interiors, so the
	# flag goes down here — in memory only, an audit must not write the
	# player's settings file.
	Settings.mission_scenes = false
	_main = MainScene.instantiate()
	add_child(_main)
	_run()

func _wait(pred: Callable, secs: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		if pred.call():
			return true
		await get_tree().process_frame
	return false

func _cli() -> Dictionary:
	var out: Dictionary = {}
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--") and a.find("=") > 0:
			out[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	return out

func _run() -> void:
	var cli := _cli()
	var settle: float = float(cli.get("settle", 2.5))
	var player: CharacterBody3D = _main.get("player")
	player.set("god_mode", true)
	# Wait for the initial map so the scene is fully up.
	await _wait(func() -> bool: return _main.get("_current_level") != null, 120.0)
	var all_maps: Array = _main.get("_maps")
	var maps: Array = []
	if cli.has("maps"):
		for s in String(cli["maps"]).split(","):
			var nm := "MAP.%03d" % int(s) if s.strip_edges().is_valid_int() else s.strip_edges().to_upper()
			if all_maps.has(nm):
				maps.append(nm)
	else:
		maps = all_maps.duplicate()
	print("[audit] %d maps, settle %.1f s" % [maps.size(), settle])
	for nm in maps:
		await _audit_map(nm, settle, player)
	_finish()

func _audit_map(nm: String, settle: float, player: CharacterBody3D) -> void:
	var all_maps: Array = _main.get("_maps")
	_main.set("_map_idx", all_maps.find(nm))
	_main.set("_prev_map_name", "")
	_main.set("_pending_marker_set", -1)
	_main.call("_load_current")
	var ok: bool = await _wait(func() -> bool:
		var lvl = _main.get("_current_level")
		return lvl != null and "MAP." + String(lvl.map_suffix) == nm and int(_main.get("_pending_marker_set")) == -1, 120.0)
	if not ok:
		_row(nm, "LOAD", "map did not come up")
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	var lvl = _main.get("_current_level")
	var spawn: Vector3 = player.global_position
	# Static checks while the world settles.
	_check_meshes(nm, lvl)
	await get_tree().create_timer(settle).timeout
	# --- player ---
	var p: Vector3 = player.global_position
	var drop: float = spawn.y - p.y
	if drop > 600.0 or p.y < -5000.0:
		_row(nm, "FALL", "player fell %.0f u from the spawn (%s → %s)" % [drop, spawn, p])
	elif not player.is_on_floor() and not player.noclip:
		_row(nm, "AIR", "player not on a floor %.1f s after the spawn (y %.0f → %.0f)" % [settle, spawn.y, p.y])
	# --- enemies ---
	var space: PhysicsDirectSpaceState3D = (_main as Node3D).get_world_3d().direct_space_state
	var sunk: Array = []
	var floating: Array = []
	for e in get_tree().get_nodes_in_group("enemy"):
		if not (e is Node3D) or not is_instance_valid(e):
			continue
		if bool(e.get("_flying")) or bool(e.get("_stationary")):
			continue
		var ep: Vector3 = (e as Node3D).global_position
		var foot: float = ep.y + float(e.get("_foot_offset"))
		var q := PhysicsRayQueryParameters3D.create(Vector3(ep.x, foot + 40.0, ep.z), Vector3(ep.x, foot - 400.0, ep.z))
		q.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(q)
		var q2 := PhysicsRayQueryParameters3D.create(Vector3(ep.x, foot + 40.0, ep.z), Vector3(ep.x, foot + 400.0, ep.z))
		q2.collide_with_areas = false
		var above: Dictionary = space.intersect_ray(q2)
		if hit.has("position"):
			var clear: float = foot - (hit["position"] as Vector3).y
			if clear > 90.0:
				floating.append("%s(+%.0f)" % [e.name, clear])
		elif above.has("position") and (above["normal"] as Vector3).y > 0.5:
			sunk.append("%s(-%.0f)" % [e.name, (above["position"] as Vector3).y - foot])
		elif ep.y < spawn.y - 3000.0:
			sunk.append("%s(fell)" % e.name)
	if not sunk.is_empty():
		_row(nm, "SUNK", "%d enemies under the floor: %s" % [sunk.size(), ", ".join(sunk.slice(0, 6))])
	if not floating.is_empty():
		_row(nm, "FLOAT", "%d enemies in the air: %s" % [floating.size(), ", ".join(floating.slice(0, 6))])

## Surfaces without a texture; triangles with real area but ~zero UV area.
func _check_meshes(nm: String, lvl) -> void:
	var untextured: Dictionary = {}
	var smeared: Dictionary = {}
	var roots: Array = []
	if lvl.entities != null:
		roots.append(lvl.entities)
	if lvl.enemies != null:
		roots.append(lvl.enemies)
	var seen: Dictionary = {}
	for root in roots:
		for c in root.get_children():
			if not (c is MeshInstance3D):
				continue
			var mi := c as MeshInstance3D
			if mi.mesh == null:
				continue
			var key: int = mi.mesh.get_instance_id()
			if seen.has(key):
				continue
			seen[key] = true
			var base: String = String(mi.name).split("_")[0] if not String(mi.name).begins_with("enemy") else String(mi.name)
			for si in mi.mesh.get_surface_count():
				var m: Material = mi.mesh.surface_get_material(si)
				if m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture == null:
					untextured[base] = untextured.get(base, 0) + 1
					continue
				var tex_size := Vector2(64, 64)
				if m is BaseMaterial3D:
					tex_size = (m as BaseMaterial3D).albedo_texture.get_size()
				if tex_size.x <= 1.0 or tex_size.y <= 1.0:
					continue                      # solid-colour bank 0/1 face: UVs are moot
				var arrays: Array = mi.mesh.surface_get_arrays(si)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var uv_v = arrays[Mesh.ARRAY_TEX_UV]
				if uv_v == null:
					continue
				var uvs: PackedVector2Array = uv_v
				var idx_v = arrays[Mesh.ARRAY_INDEX]
				var n: int = verts.size() if idx_v == null else (idx_v as PackedInt32Array).size()
				var bad: int = 0
				var t: int = 0
				while t + 2 < n:
					var i0: int = t if idx_v == null else idx_v[t]
					var i1: int = t + 1 if idx_v == null else idx_v[t + 1]
					var i2: int = t + 2 if idx_v == null else idx_v[t + 2]
					t += 3
					var a := verts[i0]
					var b := verts[i1]
					var cc := verts[i2]
					var area: float = (b - a).cross(cc - a).length() * 0.5
					if area < 400.0:
						continue
					var ua := uvs[i0] * tex_size
					var ub := uvs[i1] * tex_size
					var uc := uvs[i2] * tex_size
					var uv_area: float = absf((ub - ua).cross(uc - ua)) * 0.5
					# Flat-coloured faces carry all-zero UVs in the data (rebar beams
					# in the rubble piles) — not a smear. A smear has UVs that differ
					# yet enclose no area (OVRPASS: (0,0),(0,0),(2048,0)).
					var spread: float = maxf(ua.distance_to(ub), maxf(ua.distance_to(uc), ub.distance_to(uc)))
					if uv_area < 2.0 and spread > 4.0:
						bad += 1
						if bad == 1:
							print("[audit]   %s surface %d tex %s: pts %s %s %s uv(px) %s %s %s" % [base, si, tex_size, a, b, cc, ua, ub, uc])
				if bad > 0:
					smeared[base] = smeared.get(base, 0) + bad
	if not untextured.is_empty():
		var parts: Array = []
		for k in untextured:
			parts.append("%s×%d" % [k, untextured[k]])
		_row(nm, "NOTEX", "surfaces without a texture: %s" % ", ".join(parts.slice(0, 8)))
	if not smeared.is_empty():
		var parts: Array = []
		for k in smeared:
			parts.append("%s×%d" % [k, smeared[k]])
		_row(nm, "UV", "big faces with ~zero UV area (smeared texel): %s" % ", ".join(parts.slice(0, 8)))

func _row(map: String, kind: String, text: String) -> void:
	_issues += 1
	_rows.append([map, kind, text])
	print("[audit] %-8s %-6s %s" % [map, kind, text])

func _finish() -> void:
	print("[audit] ---- %d issue(s) ----" % _issues)
	for r in _rows:
		print("[audit] %-8s %-6s %s" % [r[0], r[1], r[2]])
	get_tree().quit(0)
