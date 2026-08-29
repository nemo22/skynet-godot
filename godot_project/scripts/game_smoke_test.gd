## Headless end-to-end smoke test on the real game scene (main.tscn):
## boots MAP.210 through the briefing, fires every weapon slot, lets an
## enemy shoot, then walks the MAP.210 → MAP.218 → MAP.210 exit round trip
## and checks marker spawns, HP/ammo carry-over, the per-map state
## overlay and that no false MISSION COMPLETE fires.
##
##   godot --headless --path . res://scenes/game_smoke_test.tscn

extends Node

const MainScene := preload("res://scenes/main.tscn")

var _fails: int = 0
var _main: Node = null

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[e2e] PASS  %s" % what)
	else:
		_fails += 1
		print("[e2e] FAIL  %s" % what)

## Poll `pred` every frame for up to `secs` seconds of wall-clock time.
func _wait(pred: Callable, secs: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		if pred.call():
			return true
		await get_tree().process_frame
	return false

func _level_is(sfx: String) -> bool:
	var lvl = _main.get("_current_level")
	return lvl != null and String(lvl.map_suffix) == sfx

## A transition is settled once _frame_camera consumed the marker set
## and the fade-in finished.
func _settled() -> bool:
	if int(_main.get("_pending_marker_set")) != -1:
		return false
	var fade: ColorRect = _main.get("_fade")
	return fade == null or fade.color.a < 0.02

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	SkynetPaths.selected_map = "MAP.210"
	_main = MainScene.instantiate()
	add_child(_main)
	_run()

func _run() -> void:
	var player: CharacterBody3D = _main.get("player")

	# --- 1. Briefing → BEGIN → MAP.210 loaded, mission watcher armed ---
	var ok: bool = await _wait(func() -> bool:
		return _main.get("_briefing_overlay") != null, 60.0)
	_check(ok, "MAP.210 briefing screen shows")
	if ok:
		_main.call("_briefing_begin")
	ok = await _wait(func() -> bool:
		return _level_is("210") and int(_main.get("_mission_hostiles")) > 0, 180.0)
	_check(ok, "MAP.210 loads and counts hostiles (%d)" % int(_main.get("_mission_hostiles")))
	if not ok:
		return _finish()
	var lvl = _main.get("_current_level")
	_check(player.global_position.distance_to(lvl.player_start) < 1000.0,
		"player spawned at the map's start marker")

	# --- 1b. DOS enemy AI wiring: scripts animate, turrets get segments,
	# something moves within 3 s of physics ---
	var enemies: Array = get_tree().get_nodes_in_group("enemy")
	var start_pos: Dictionary = {}
	for e in enemies:
		start_pos[e] = (e as Node3D).global_position
	for f in 180:
		await get_tree().physics_frame
	var scripted: int = 0
	var segs: int = 0
	var moved: int = 0
	for e in enemies:
		if not is_instance_valid(e):
			continue
		var brain = e.get("_brain")
		if brain != null and brain.anim_va != 0:
			scripted += 1
		if (e.get("_segs") as Array).size() > 0:
			segs += 1
		if (e as Node3D).global_position.distance_to(start_pos[e]) > 20.0:
			moved += 1
	_check(scripted >= 2, "%d enemies run an AIS animation block" % scripted)
	_check(segs >= 2, "%d enemies carry DOS turret segments (hvytrrt/guntwr)" % segs)
	_check(moved >= 1, "%d enemies moved under the DOS AI" % moved)

	# --- 2. Every weapon slot fires without errors; pools drain per DOS cost ---
	player.set("_pools", {0: 123, 1: 50, 2: 10, 3: 5, 4: 500, 12: 9999})
	for i in 13:
		player.set("_weapon_idx", i)
		player.set("_fire_cd", 0.0)
		player.call("_shoot")
		for f in 3:
			await get_tree().physics_frame
	var pools: Dictionary = player.get("_pools")
	_check(int(pools[0]) == 115, "bullet pool drained by UZI+ASSAULT+MG costs (1+3+4): %d" % int(pools[0]))
	_check(int(pools[1]) == 49 and int(pools[2]) == 9 and int(pools[3]) == 4,
		"shotgun/grenade/rocket pools drained by one shot each")
	_check(int(pools[4]) == 480, "energy pool drained by 2+5+1+2+10 cells: %d" % int(pools[4]))
	var live: int = 0
	for c in get_children():
		if c != _main:
			live += 1
	_check(live > 0, "shots spawned %d effect/projectile nodes" % live)
	for f in 300:                                    # 5 s of physics: rocket life 3.4 s, grenade fuse 2.5 s
		await get_tree().physics_frame
	# Only the player's own shots count — the DOS-driven enemies keep
	# firing bolts at the player throughout the test.
	var left: int = 0
	for c in get_children():
		if c != _main and c.get_script() != null 				and String(c.get_script().resource_path).ends_with("projectile.gd") 				and c.get("_owner") == player:
			left += 1
	_check(left == 0, "all player projectiles expired or hit after 5 s of physics (%d left)" % left)

	# --- 3. Enemy bolt at the player ---
	var en = get_tree().get_first_node_in_group("enemy")
	_check(en != null, "an enemy exists on MAP.210")
	if en != null:
		en.set("_player", player)
		en.call("_fire_at_player")
		for f in 120:
			await get_tree().physics_frame
	# Kill one enemy so the state overlay has something to remember.
	var killed_off: int = -1
	if en != null and en.has_meta("marker_off"):
		killed_off = int(en.get_meta("marker_off"))
		en.call("take_damage", 1.0e6)
		await get_tree().physics_frame
		_check(not is_instance_valid(en) or bool(en.call("is_dead")),
			"enemy dies to a lethal hit")

	# --- 4. Exit MAP.210 → MAP.218 (bunker interior), marker set 0 ---
	var hp_before: float = float(player.get("health"))
	_main.call("_on_teleport_requested", 218, 0)
	ok = await _wait(func() -> bool: return _level_is("218") and _settled(), 180.0)
	_check(ok, "exit loads MAP.218")
	if not ok:
		return _finish()
	lvl = _main.get("_current_level")
	var m0: Vector3 = (lvl.markers[0] as Array)[0] if lvl.markers.has(0) else Vector3.INF
	_check(player.global_position.distance_to(m0) < 700.0,
		"player spawned at MAP.218 marker 0 (d=%.0f)" % player.global_position.distance_to(m0))
	pools = player.get("_pools")
	_check(int(pools[0]) == 115 and int(pools[4]) == 480, "ammo pools carry into the interior")
	_check(is_equal_approx(float(player.get("health")), hp_before), "health carries into the interior")
	_check(int(_main.get("_mission_hostiles")) == 0 and _main.get("_game_over") == null,
		"interior does not arm the mission watcher (no false MISSION COMPLETE)")
	var st: Dictionary = _main.get("_map_state")
	_check(st.has("MAP.210") and killed_off >= 0 and (st["MAP.210"]["dead"] as Dictionary).has(killed_off),
		"MAP.210 state overlay saved with the killed enemy")
	_check(String(_main.get("_prev_map_name")) == "MAP.210", "previous-map register = MAP.210")

	# --- 5. Return exit (map 0 → previous map, marker 27) ---
	_main.call("_on_teleport_requested", 0, 27)
	ok = await _wait(func() -> bool: return _level_is("210") and _settled(), 180.0)
	_check(ok, "return exit loads MAP.210 again")
	if not ok:
		return _finish()
	lvl = _main.get("_current_level")
	var m27: Vector3 = (lvl.markers[27] as Array)[0] if lvl.markers.has(27) else Vector3.INF
	_check(player.global_position.distance_to(m27) < 700.0,
		"player spawned at MAP.210 marker 27 (d=%.0f)" % player.global_position.distance_to(m27))
	var still_there: bool = false
	for e in get_tree().get_nodes_in_group("enemy"):
		if e.has_meta("marker_off") and int(e.get_meta("marker_off")) == killed_off:
			still_there = true
	_check(killed_off >= 0 and not still_there, "killed enemy stays dead after the round trip")
	_check(int(_main.get("_mission_hostiles")) > 0 and not bool(_main.get("_mission_done")),
		"mission watcher re-armed on the main map (%d hostiles)" % int(_main.get("_mission_hostiles")))
	for f in 60:
		await get_tree().physics_frame
	_check(_main.get("_game_over") == null, "no MISSION COMPLETE / game over after the round trip")
	_finish()

func _finish() -> void:
	print("[e2e] %s (%d failures)" % ["ALL PASS" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)
