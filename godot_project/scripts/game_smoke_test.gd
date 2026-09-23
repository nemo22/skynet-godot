## Headless end-to-end smoke test on the real game scene (main.tscn):
## boots MAP.210 through the briefing, fires every weapon slot, lets an
## enemy shoot, then walks the MAP.210 → MAP.218 → MAP.210 exit round trip
## and checks marker spawns, HP/ammo carry-over, the per-map state
## overlay, a save/load round trip and that no end screen fires by
## itself (a mission ends when its [M1]..[M5] objective counter hits 0).
##
##   godot --headless --path . res://scenes/game_smoke_test.tscn

extends Node

const MainScene := preload("res://scenes/main.tscn")
const LevelLoader := preload("res://scripts/level_loader.gd")
const SaveGame := preload("res://scripts/save_game.gd")
const Enemy := preload("res://scripts/enemy.gd")
const Projectile := preload("res://scripts/projectile.gd")
const LevelScene := preload("res://scripts/level_scene.gd")
const SettingsLib := preload("res://scripts/settings.gd")
const PathsLib := preload("res://scripts/skynet_paths.gd")

## The map _check_scene_mod stands a mod scene over: an interior, so the
## copy is small, and one this suite has already loaded once.
const MOD_MAP := "MAP.248"

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
	# THE PER-MAP RUNTIME is what this suite is written against: every exit
	# below is a level change, and the state it checks is the per-map overlay.
	# Mission scenes are the default since step 8 of the M2 plan, so the flag
	# goes DOWN here — in memory only, a test must not write the player's own
	# settings file — and mission_smoke_test.gd is the suite that plays the
	# same mission the new way. The runtime is chosen when the first level
	# starts, so this has to happen before Main is built.
	Settings.mission_scenes = false
	SkynetPaths.selected_map = "MAP.210"
	_main = MainScene.instantiate()
	add_child(_main)
	_run()

func _run() -> void:
	var player: CharacterBody3D = _main.get("player")
	# God mode from the start: a lucky enemy volley used to kill the
	# player mid-suite — the MISSION FAILED screen pauses the tree and
	# every later movement/physics check fails as collateral.
	player.set("god_mode", true)

	# --- 1. Briefing → BEGIN → MAP.210 loaded, hostiles tracked ---
	var ok: bool = await _wait(func() -> bool:
		return _main.get("_briefing_overlay") != null, 60.0)
	_check(ok, "MAP.210 briefing screen shows")
	if ok:
		_main.call("_briefing_begin")
	ok = await _wait(func() -> bool:
		return _level_is("210") and int(_main.get("_mission_hostiles")) > 0, 180.0)
	_check(ok, "MAP.210 loads, hostiles tracked (%d)" % int(_main.get("_mission_hostiles")))
	if not ok:
		return _finish()
	var lvl = _main.get("_current_level")
	_check(player.global_position.distance_to(lvl.player_start) < 1000.0,
		"player spawned at the map's start marker")
	# The fallback this whole suite rides on: with the flag down there is no
	# mission scene and the map stands at the DOS origin on its own.
	_check(_main.get("_mission") == null and (lvl.origin as Vector3) == Vector3.ZERO,
		"the flag down: MAP.210 is up on its own, at the origin")

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
	# The observation-deck terminator (endorfl, marker 66 u above the
	# 210TOWER origin) must still be up there — no walking off the deck,
	# no falling through it.
	var deck_ok := false
	var deck_y := -1.0
	for e in enemies:
		if not is_instance_valid(e) or not String(e.name).contains("endorfl"):
			continue
		var sp: Vector3 = start_pos[e]
		if sp.distance_to(Vector3(49956.0, 980.0, -56315.0)) < 300.0:
			deck_y = (e as Node3D).global_position.y
			deck_ok = deck_y > 930.0 and deck_y < 1090.0    # deck floor 978, roof 1108
	_check(deck_ok, "tower-deck terminator stays on the deck, not the roof (y=%.0f)" % deck_y)
	_check(segs >= 2, "%d enemies carry DOS turret segments (hvytrrt/guntwr)" % segs)
	_check(moved >= 1, "%d enemies moved under the DOS AI" % moved)
	# Hovers (HK) never sink onto the player or into a hillside: at least
	# 200 u of air under every one of them (0x13c300 min altitude p6-100).
	var hovers: int = 0
	var low: int = 0
	for e in enemies:
		if not is_instance_valid(e) or e.get("_brain") == null or int(e.get("_brain").state) != 9:
			continue
		hovers += 1
		var clearance: float = (e as Node3D).global_position.y - float(e.call("_surface_below"))
		if clearance < 200.0:
			low += 1
	_check(hovers > 0 and low == 0, "%d hovers all keep >= 200 u above the ground (%d low)" % [hovers, low])

	# --- 1c. Cache location, weapon ownership, cheats, pause menu, console ---
	# A release keeps the cache next to the game data; a development
	# checkout keeps it in the project, where the editor opens the map
	# scenes from — no directory link (SkynetPaths.converted_dir_for).
	_check(Assets.root == SkynetPaths.converted_dir()
		and (OS.has_feature("template") or Assets.root == "res://converted")
		and FileAccess.file_exists(Assets.root + "/VERSION"),
		"asset cache sits where converted_dir_for puts it (%s)" % Assets.root)
	_check(player.call("owned_list") == [0, 1, 2, 4, 7],
		"campaign start arsenal = PIPE, UZI, ASSAULT RIFLE, SHOTGUN, LASER RIFLE (%s)" % str(player.call("owned_list")))
	player.call("_select_weapon", 6)
	_check(int(player.get("_weapon_idx")) != 6, "an unowned weapon (ROCKET LAUNCHER) cannot be selected")
	player.call("_select_weapon", 4)
	_check(int(player.get("_weapon_idx")) == 4, "an owned weapon (SHOTGUN) can be selected")
	var reply: String = String(_main.call("run_command", "arnold"))
	_check((player.call("owned_list") as Array).size() == 12 and not bool(player.call("owns", 12)),
		"'arnold' gives the 12 on-foot weapons but not the super uzi (%s)" % reply)
	reply = String(_main.call("run_command", "superuzi"))
	_check(bool(player.call("owns", 12)) and int(player.get("_weapon_idx")) == 12
		and String(player.get("weapon_name")) == "SUPER UZI",
		"'superuzi' grants and selects slot 12 SUPER UZI (%s)" % reply)
	reply = String(_main.call("run_command", "slugs"))
	_check(int(player.call("pool_count", 0)) == 750 and int(player.call("pool_count", 4)) == 800,
		"'slugs' fills every ammo pool (%s)" % reply)
	player.set("health", 10.0)
	_main.call("run_command", "surgery")
	_check(is_equal_approx(float(player.get("health")), 100.0) and is_equal_approx(float(player.get("armor")), 1.0),
		"'surgery' restores full health and armor")
	_main.call("run_command", "god off")
	_check(not bool(player.get("god_mode")), "'god off' clears god mode")
	_main.call("run_command", "god on")
	_check(bool(player.get("god_mode")), "'god on' sets god mode")
	_check(String(_main.call("run_command", "bogus")).begins_with("unknown command"), "unknown commands are reported")
	_main.call("open_pause_menu")
	var pm = _main.get("_pause")
	_check(pm != null and bool(pm.is_open) and get_tree().paused, "Esc menu opens and pauses the tree")
	_main.call("close_pause_menu")
	_check(not get_tree().paused and _level_is("210"), "closing the Esc menu resumes with the level still loaded")
	var con = _main.get("_console")
	_main.call("open_console")
	_check(con != null and bool(con.is_open) and get_tree().paused, "console drops down and pauses")
	con.call("run", "pos")
	con.call("close")
	_check(not bool(con.is_open) and not get_tree().paused, "console closes and resumes")
	_main.call("run_command", "give ammo")

	await _check_throwables(player)
	await _check_mouse_settings(player)

	# --- 1d. Music: every HMI parses to a sane song, the map's maptype
	# picks its track and the synth is running ---
	var hmi_ok: int = 0
	var hmi_total: int = 0
	var dir := DirAccess.open(SkynetPaths.gamedata_dir)
	if dir != null:
		for fn in dir.get_files():
			if not fn.to_upper().ends_with(".HMI"):
				continue
			hmi_total += 1
			var sg: Dictionary = Audio.song(fn)
			var secs: float = 0.0
			var nev: int = 0
			if not sg.is_empty():
				@warning_ignore("integer_division")
				nev = (sg["events"] as PackedInt32Array).size() / 5
				secs = float(sg["length"]) / float(sg["rate"])
			var sane: bool = nev > 50 and secs > 5.0 and secs < 900.0
			if sane:
				hmi_ok += 1
			print("[e2e] hmi %-12s %6d events %6.1f s %s" % [fn, nev, secs, "" if sane else "<-- odd"])
	_check(hmi_total >= 20 and hmi_ok == hmi_total, "all %d HMI tracks parse to sane songs (%d ok)" % [hmi_total, hmi_ok])
	var mt: int = int(_main.call("_maptype", _main.get("_current_level")))
	var want_track: String = Audio.MAPTYPE_TRACKS[mt] if mt >= 0 and mt < Audio.MAPTYPE_TRACKS.size() else "T200.HMI"
	_check(Audio.music_name() == want_track, "MAP.210 (maptype %d) plays %s (playing: %s)" % [mt, want_track, Audio.music_name()])
	for f in 90:
		await get_tree().physics_frame
	var synth = Audio.get("_synth")
	var sounding: int = 0
	for c in synth.get_children():
		if c is AudioStreamPlayer and (c as AudioStreamPlayer).playing:
			sounding += 1
	_check(bool(synth.playing) and float(synth.get("_tick")) > 0.0, "the sequencer advances (tick %.0f, %d voices sounding)" % [float(synth.get("_tick")), sounding])
	Audio.set_music_volume(0.0)          # keep the rest of the run quiet
	_check(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")), "music volume 0 mutes the Music bus")
	Audio.set_music_volume(0.6)

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

	# --- 2b. Blast damage reaches destructible map objects (cars) ---
	var car: Node3D = null
	var rt = _main.get("_current_level").triggers
	var branch = _main.get("_current_level").behaviour
	for h in get_tree().get_nodes_in_group("hittable"):
		var hoff: int = int(h.call("file_off"))
		var w: Node = branch.wreck_node(hoff)
		if w != null and int(w.get("stage")) == 0 and not rt.spent(hoff) and (String(h.name).begins_with("CARHIP") or String(h.name).begins_with("COPCAR")):
			car = h
			break
	_check(car != null, "a staged destructible car is in the hittable group")
	if car != null:
		var off: int = car.call("file_off")
		var stage0: int = int(branch.wreck_node(off).get("stage")) if branch.wreck_node(off) != null else -1
		var rocket := preload("res://scripts/projectile.gd").new()
		add_child(rocket)
		# Straight down onto the roof — nothing but the car in the way.
		rocket.setup(car.global_position + Vector3(0, 400, 0), Vector3(0, -1, 0), 400.0,
			{"speed": 3000.0, "life": 1.0, "splash": 512.0, "hits": "enemy"}, player)
		for f in 45:
			await get_tree().physics_frame
		var stage1: int = int(branch.wreck_node(off).get("stage")) if branch.wreck_node(off) != null else -1
		_check(stage1 > stage0, "rocket blast advanced the car's damage stage (%d → %d)" % [stage0, stage1])

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
	# The old level keeps simulating during the fade-out; god mode keeps
	# a late enemy bolt from skewing the carry-over comparison.
	player.set("god_mode", true)
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
		"interior tracks no hostiles and shows no end screen")
	var st: Dictionary = _main.get("_map_state")
	_check(st.has("MAP.210") and killed_off >= 0 and (st["MAP.210"]["dead"] as Dictionary).has(killed_off),
		"MAP.210 state overlay saved with the killed enemy")
	_check(String(_main.get("_prev_map_name")) == "MAP.210", "previous-map register = MAP.210")
	# Floors must hold: 3 s of physics later the player still stands
	# near the marker (a degenerate collider once let them fall through).
	var y0: float = player.global_position.y
	for f in 180:
		await get_tree().physics_frame
	_check(absf(player.global_position.y - y0) < 200.0,
		"player stays on the interior floor (dy=%.0f)" % (player.global_position.y - y0))

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
		"hostiles tracked again on the main map (%d)" % int(_main.get("_mission_hostiles")))
	# --- 4b. Mover physics follows the mesh: open a swing door and check
	# its AnimatableBody3D really moved in the physics server ---
	var door_e = null
	for e in lvl.map.entities:
		if (e.flags & 3) == 1 and lvl.behaviour.has_mover(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e).begins_with("210DOOR"):
			door_e = e
			break
	_check(door_e != null, "MAP.210 has a 210DOOR swing-door mover")
	if door_e != null:
		var dnode: Node3D = lvl.behaviour.hit_node(door_e.file_off)
		var dbody: AnimatableBody3D = null
		for c in dnode.get_children():
			if c is AnimatableBody3D:
				dbody = c
		_check(dbody != null, "the door leaf carries an AnimatableBody3D")
		var closed: Transform3D = dnode.global_transform
		lvl.triggers.arm(door_e.file_off)
		for f in 150:
			await get_tree().physics_frame
		_check(not dnode.global_transform.basis.is_equal_approx(closed.basis), "the door leaf swung open")
		if dbody != null:
			var phys: Transform3D = PhysicsServer3D.body_get_state(dbody.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
			_check(phys.basis.is_equal_approx(dbody.global_transform.basis) and phys.origin.distance_to(dbody.global_transform.origin) < 1.0,
				"the physics body followed the swung leaf")

	# --- 4c. The base gate (two sliding BIGDOOR leaves) becomes passable:
	# a player-sized capsule in the opening is blocked while closed and
	# free once both leaves have slid apart ---
	var leaves: Array = []
	for e in lvl.map.entities:
		if (e.flags & 3) == 1 and lvl.behaviour.has_mover(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e) == "BIGDOOR":
			leaves.append(e)
	_check(leaves.size() == 2, "MAP.210 has two BIGDOOR gate leaves (%d)" % leaves.size())
	if leaves.size() == 2:
		var centre := Vector3(0, 0, 0)
		for e in leaves:
			centre += Vector3(float(e.x), -float(e.y), -float(e.z))
		centre *= 0.5
		var probe := PhysicsShapeQueryParameters3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 26.0
		cap.height = 88.0
		probe.shape = cap
		probe.exclude = [player.get_rid()]
		probe.transform = Transform3D(Basis(), centre + Vector3(0.0, 60.0, 0.0))
		var space: PhysicsDirectSpaceState3D = (_main as Node3D).get_world_3d().direct_space_state
		var blocked_before: bool = not space.intersect_shape(probe, 4).is_empty()
		_check(blocked_before, "the closed gate blocks a player capsule in the opening")
		_gate_diag(lvl, leaves, centre, probe, space, "closed")
		for e in leaves:
			lvl.triggers.arm(e.file_off)
		for f in 300:
			await get_tree().physics_frame
		var blocked_after: bool = not space.intersect_shape(probe, 4).is_empty()
		_check(not blocked_after, "the open gate lets a player capsule through the opening")
		_gate_diag(lvl, leaves, centre, probe, space, "open")

	# --- 5. Pickups: walking onto an item-table sprite collects it ---
	var pick: Node3D = null
	var pick_item: Array = []
	for n in get_tree().get_nodes_in_group("pickup"):
		var it: Array = n.call("item")
		if it.size() >= 6 and int(it[0]) >= 0 and int(it[1]) > 0:
			pick = n
			pick_item = it
			break
	_check(pick != null, "MAP.210 has an item-table pickup with an ammo pool")
	var pick_off: int = int(pick.get_meta("pickup_off")) if pick != null and pick.has_meta("pickup_off") else -1
	if pick != null:
		var pool: int = int(pick_item[0])
		var before_cnt: int = int(player.call("pool_count", pool))
		player.set("noclip", true)
		player.velocity = Vector3.ZERO
		player.global_position = pick.global_position + Vector3(0.0, 20.0, 0.0)
		for f in 10:
			await get_tree().physics_frame
		_check(not is_instance_valid(pick), "pickup is consumed when the player stands on it")
		_check(int(player.call("pool_count", pool)) > before_cnt,
			"pickup topped up pool %d (%d → %d)" % [pool, before_cnt, int(player.call("pool_count", pool))])

	# --- 5b. Save / load: slot 9 keeps the map, the player and the overlay ---
	var saved_owned: Array = player.call("owned_list")
	var saved_pos: Vector3 = player.global_position
	var saved_pools: Dictionary = (player.get("_pools") as Dictionary).duplicate()
	var saved_prev: String = String(_main.get("_prev_map_name"))
	player.set("health", 61.0)
	player.call("select_throwable", 4)                   # SATCHEL, not the default
	_check(bool(_main.call("save_to_slot", 9)), "save_to_slot(9) writes a save file")
	_check(SaveGame.exists(9), "slot 9 file exists (%s)" % SaveGame.path(9))
	_check(SaveGame.info(9).begins_with("MAP.210"), "slot 9 header names MAP.210 (%s)" % SaveGame.info(9))
	# Wreck the live state, then load it back.
	player.global_position = saved_pos + Vector3(4000.0, 0.0, 0.0)
	player.set("_pools", {0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 12: 1})
	player.set("health", 100.0)
	player.call("select_throwable", 0)
	var old_id: int = (_main.get("_current_level") as Object).get_instance_id()
	_main.call("load_from_slot", 9)
	ok = await _wait(func() -> bool:
		var cur = _main.get("_current_level")
		return cur != null and cur.get_instance_id() != old_id and _level_is("210") and _settled() \
			and (_main.get("_pending_player") as Dictionary).is_empty(), 180.0)
	_check(ok, "load_from_slot(9) reloads MAP.210")
	if ok:
		_check(player.global_position.distance_to(saved_pos) < 150.0,
			"player restored to the saved position (d=%.0f)" % player.global_position.distance_to(saved_pos))
		_check(player.get("_pools") == saved_pools, "ammo pools restored from the save")
		_check(is_equal_approx(float(player.get("health")), 61.0), "health restored from the save (%.0f)" % float(player.get("health")))
		_check(String(_main.get("_prev_map_name")) == saved_prev, "previous-map register restored (%s)" % saved_prev)
		_check(player.call("owned_list") == saved_owned, "weapon ownership restored from the save (%d weapons)" % saved_owned.size())
		_check(int(player.get("_throw_idx")) == 4 and String(player.get("secondary_name")) == "SATCHEL",
			"the THROWN weapon's selection is restored too (%s)" % str(player.get("secondary_name")))
		var pk_back: bool = false
		for s in get_tree().get_nodes_in_group("pickup"):
			if s.has_meta("pickup_off") and int(s.get_meta("pickup_off")) == pick_off:
				pk_back = true
		_check(pick_off >= 0 and not pk_back, "pickup taken before the save stays taken after the load")
		var en_back: bool = false
		for e in get_tree().get_nodes_in_group("enemy"):
			if e.has_meta("marker_off") and int(e.get_meta("marker_off")) == killed_off:
				en_back = true
		_check(killed_off >= 0 and not en_back, "enemy killed before the save stays dead after the load")
		lvl = _main.get("_current_level")
		var open_after_load: int = 0
		for e in lvl.map.entities:
			if (e.flags & 3) == 1 and lvl.behaviour.has_mover(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e) == "BIGDOOR":
				# How far a leaf has slid is the mover node's own (step 5e).
				if float(lvl.behaviour.mover_node(e.file_off).progress) > 100.0:
					open_after_load += 1
		_check(open_after_load == 2, "the opened base gate is still open after the load (%d leaves)" % open_after_load)

	# --- 6. MAP.212 (truck interior): spawn, crate breaks + drops, DOOR + use → MAP.216/12 ---
	_main.call("_on_teleport_requested", 212, 0)
	ok = await _wait(func() -> bool: return _level_is("212") and _settled(), 180.0)
	_check(ok, "truck exit loads MAP.212")
	if ok:
		lvl = _main.get("_current_level")
		_check(lvl.map.entities.size() == 19, "MAP.212 parses all 19 entities (both cells)")
		var m0b: Vector3 = (lvl.markers[0] as Array)[0] if lvl.markers.has(0) else Vector3.INF
		_check(player.global_position.distance_to(m0b) < 300.0,
			"player spawned at MAP.212 marker 0 (d=%.0f)" % player.global_position.distance_to(m0b))
		var crate = null
		for e in lvl.map.entities:
			if (e.flags & 3) == 1 and LevelLoader.MapFile.entity_name(lvl.map, e).begins_with("CRAT"):
				crate = e
				break
		_check(crate != null and crate.hp == 50 and crate.uses_defaults,
			"crates take 50 HP from the map's per-name defaults")
		var drops: Array = []
		lvl.behaviour.item_dropped.connect(func(_at: Vector3, t: int) -> void: drops.append(t))
		if crate != null:
			lvl.behaviour.obj_hit(crate.file_off, 60.0)
			_check(lvl.triggers.spent(crate.file_off), "a 60-damage hit destroys the crate")
			_check(drops == [3], "the crate's destruction rolls an ammo drop (type 3)")
		for f in 5:
			await get_tree().physics_frame
		_main.call("_on_use_pressed", player.global_position)
		ok = await _wait(func() -> bool: return _level_is("216") and _settled(), 180.0)
		_check(ok, "use at the truck DOOR leads to MAP.216")
		if ok:
			lvl = _main.get("_current_level")
			var m12: Vector3 = (lvl.markers[12] as Array)[0] if lvl.markers.has(12) else Vector3.INF
			_check(player.global_position.distance_to(m12) < 700.0,
				"player spawned at MAP.216 marker 12 (d=%.0f)" % player.global_position.distance_to(m12))
			# NO variant carry of a mechanism: the gate opened in MAP.210
			# (step 4c) comes up on MAP.216 as MAP.216's file has it — DOS
			# keeps an overlay per map number (the owner's ruling,
			# 2026-09-23). Only the dead and the taken cross.
			var open_leaves: int = 0
			for e in lvl.map.entities:
				if (e.flags & 3) == 1 and lvl.behaviour.has_mover(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e) == "BIGDOOR":
					if float(lvl.behaviour.mover_node(e.file_off).progress) > 100.0:
						open_leaves += 1
			_check(open_leaves == 0, "MAP.216's base gate is shut as its file has it, though MAP.210's was opened (%d leaves open)" % open_leaves)

	# --- 6a. Mover colliders in MAP.214: the rotating corridor segment
	# CORB122I keeps its trimesh (a box sealed the tunnel), the DORB door
	# leaves get a box ---
	_main.call("_on_teleport_requested", 214, 0)
	ok = await _wait(func() -> bool: return _level_is("214") and _settled(), 180.0)
	_check(ok, "MAP.214 loads for the collider check")
	if ok:
		lvl = _main.get("_current_level")
		var seg_box: int = -1
		var dorb_box: int = -1
		for c in lvl.entities.get_children():
			if not (c is MeshInstance3D) or not c.has_method("file_off"):
				continue
			if not lvl.behaviour.has_mover(c.file_off()):
				continue
			var has_box: bool = false
			for body in c.get_children():
				if body is CollisionObject3D:
					for sh in body.get_children():
						if sh is CollisionShape3D and sh.shape is BoxShape3D:
							has_box = true
			if String(c.name).begins_with("CORB122I"):
				seg_box = 1 if has_box else 0
			elif String(c.name).begins_with("DORB"):
				dorb_box = 1 if has_box else 0
		_check(seg_box == 0, "rotating corridor segment CORB122I keeps its trimesh collider")
		_check(dorb_box == 1, "DORB door leaf collides as a box")

	# --- 6b. Interior ↔ interior state overlay: kill a robot and take a
	# pickup in MAP.214, walk to MAP.215 and back — both must stay gone ---
	# (already in MAP.214 after 6a — go via 215 and back below)
	ok = _level_is("214")
	_check(ok, "MAP.214 loads for the state round trip")
	if ok:
		var victim = get_tree().get_first_node_in_group("enemy")
		var victim_off: int = int(victim.get_meta("marker_off")) if victim != null and victim.has_meta("marker_off") else -1
		if victim != null:
			victim.call("take_damage", 1.0e6)
		var pk: Node = get_tree().get_first_node_in_group("pickup")
		var pk_off: int = int(pk.get_meta("pickup_off")) if pk != null and pk.has_meta("pickup_off") else -1
		if pk != null:
			pk.call("collect", player)
		for f in 5:
			await get_tree().physics_frame
		_main.call("_on_teleport_requested", 215, 0)
		ok = await _wait(func() -> bool: return _level_is("215") and _settled(), 180.0)
		_check(ok, "MAP.214 → MAP.215")
		if ok:
			_main.call("_on_teleport_requested", 214, 10)
			ok = await _wait(func() -> bool: return _level_is("214") and _settled(), 180.0)
			_check(ok, "MAP.215 → MAP.214 (marker 10)")
			if ok:
				var back: bool = false
				for e in get_tree().get_nodes_in_group("enemy"):
					if e.has_meta("marker_off") and int(e.get_meta("marker_off")) == victim_off:
						back = true
				_check(victim_off >= 0 and not back, "robot killed in MAP.214 stays dead after visiting MAP.215")
				var pk_back: bool = false
				for s in get_tree().get_nodes_in_group("pickup"):
					if s.has_meta("pickup_off") and int(s.get_meta("pickup_off")) == pk_off:
						pk_back = true
				_check(pk_off >= 0 and not pk_back, "pickup taken in MAP.214 stays taken after the round trip")

	# --- 7. MAP.211 (canyon truck): all entities, return exit → previous map marker 11 ---
	var prev_sfx: String = String(_main.get("_current_level").map_suffix)
	_main.call("_on_teleport_requested", 211, 0)
	ok = await _wait(func() -> bool: return _level_is("211") and _settled(), 180.0)
	_check(ok, "MAP.211 loads")
	if ok:
		lvl = _main.get("_current_level")
		_check(lvl.map.entities.size() == 18, "MAP.211 parses all 18 entities")
		var m0c: Vector3 = (lvl.markers[0] as Array)[0] if lvl.markers.has(0) else Vector3.INF
		_check(player.global_position.distance_to(m0c) < 300.0,
			"player spawned at MAP.211 marker 0 (d=%.0f)" % player.global_position.distance_to(m0c))
		_main.call("_on_use_pressed", player.global_position)
		ok = await _wait(func() -> bool: return _level_is(prev_sfx) and _settled(), 180.0)
		_check(ok, "use at the MAP.211 DOOR returns to the previous map")
		if ok:
			lvl = _main.get("_current_level")
			var m11: Vector3 = (lvl.markers[11] as Array)[0] if lvl.markers.has(11) else Vector3.INF
			_check(player.global_position.distance_to(m11) < 700.0,
				"return spawn at marker 11 (d=%.0f)" % player.global_position.distance_to(m11))

	for f in 60:
		await get_tree().physics_frame
	_check(_main.get("_game_over") == null, "no end screen fires by itself after the round trip")

	# --- 7b. Mission 1's jeep across the base variants, through main.gd ---
	await _check_variant_objective()

	# --- 8. MAP.215 silo: use at the CORC3229 gate opens the four
	# silo cover doors (0xEF ignores bit 0); the missile button raises
	# HADES and fires objective 0x27; evac at a marker-4 zone ends the
	# mission on the use key ---
	_main.call("_on_teleport_requested", 215, 0)
	ok = await _wait(func() -> bool: return _level_is("215") and _settled(), 180.0)
	_check(ok, "MAP.215 loads for the silo check")
	if ok:
		lvl = _main.get("_current_level")
		var cover_node: Node3D = lvl.behaviour.hit_node(0x3077)   # 210SDOR1 leaf
		var cbase: Vector3 = cover_node.global_position
		var gate = lvl.map.entities_by_off.get(0x32cb)    # CORC3229, state 0x10
		var gpos := Vector3(float(gate.x), -float(gate.y), -float(gate.z))
		player.set("noclip", true)
		player.velocity = Vector3.ZERO
		player.global_position = gpos
		for f in 3:
			await get_tree().physics_frame
		lvl.behaviour.press_use()               # DOS 0x137e2e: the use key, not the approach
		for f in 240:
			await get_tree().physics_frame
		_check(cover_node.global_position.distance_to(cbase) > 100.0,
			"silo cover door slides open from the bit-0-less proximity gate (%.0f u)" % cover_node.global_position.distance_to(cbase))
		var objs: Array = []
		lvl.behaviour.objective_complete.connect(func(i: int) -> void: objs.append(i))
		lvl.behaviour.on_player_activate(0x2f8f)             # missile button
		var hades: Node3D = lvl.behaviour.hit_node(0x47f0)
		var hbase: Vector3 = hades.global_position
		for f in 240:
			await get_tree().physics_frame
		_check(hades.global_position.distance_to(hbase) > 200.0, "HADES missile rises (%.0f u)" % hades.global_position.distance_to(hbase))
		# Objective acts are 0x26..0x2A → index 0..4 ([M1]..[M5]); the
		# 0x1C..0x25 band is hints and moves no counter.
		_check(objs.has(0x27 - 0x26), "missile chain fires mission objective 0x27 (%s)" % str(objs))
		var btn_node: Node3D = lvl.behaviour.hit_node(0x2f8f)
		_check(bool(btn_node.get_meta("switch_lit", false)), "pressed button flips to its lit face")
	# Mission end: back on MAP.210 to check the objective counter and
	# that marker 4 is a RADIATION source, not an extraction zone (the
	# port read it as one until 2026-09-03: mission 1 could not be
	# finished and mission 2 ended seconds after its start).
	_main.call("_on_teleport_requested", 210, 0)
	ok = await _wait(func() -> bool: return _level_is("210") and _settled(), 180.0)
	_check(ok, "back on MAP.210 for the mission-end checks")
	if ok:
		lvl = _main.get("_current_level")
		_check(int(_main.get("_mission_key")) == 210,
			"mission script is still 210's after the interior trip")
		var rad: Array = _main.get("_rad_sources")
		_check(rad.size() == 8, "MAP.210 has 8 radiation sources (%d)" % rad.size())
		var hot = null
		for e in lvl.map.entities:
			if (e.flags & 3) == 3 and e.marker_type == 4 and e.exit_map >= 1024:
				hot = e
				break
		_check(hot != null, "a 1024-strength radiation source exists")
		if hot != null:
			var at := Vector3(float(hot.x), -float(hot.y), -float(hot.z))
			_main.call("_on_use_pressed", at + Vector3(200.0, 0.0, 0.0))
			_check(_main.get("_game_over") == null,
				"the use key inside a radiation source does NOT end the mission")
			_check(float(_main.call("_radiation_dose", at)) > 0.0,
				"standing on the source gives a dose (%.1f HP/s)" % float(_main.call("_radiation_dose", at)))
			_check(float(_main.call("_radiation_dose", at + Vector3(9000.0, 0.0, 9000.0))) == 0.0,
				"far from every source the dose is zero")
		# The counter is what ends a mission: run it down and the end
		# screen comes up by itself.
		var todo: int = int(_main.get("_objectives_left"))
		_check(todo > 0, "mission 1 still has objectives left (%d)" % todo)
		for i in todo:
			_main.call("_on_objective_complete", i)
		ok = await _wait(func() -> bool: return _main.get("_game_over") != null, 12.0)
		_check(ok, "the last objective ends the mission")
	await _check_jeep_objective()
	await _check_ram_wall()
	await _check_water()
	await _check_scene_mod()
	await _check_trigger_verifier()
	await _check_restart(player)
	_finish()

## Death and RESTART MISSION. DOS has no single-player respawn
## (FUN_00122b52 only sets the dead + failed bits): FAILED.IMG stands for
## a moment, then the RESTART.IMG box asks, and YES replays the WHOLE
## mission from its first map with the state it was entered with, every
## map's saved state deleted. The port used to offer a RESPAWN button that
## put the player back where he was killed, because the spawn point had
## been overwritten by the last marker-set arrival (playtest 2026-09-16).
func _check_restart(player: CharacterBody3D) -> void:
	if _main.get("_game_over") != null:
		_main.call("_dismiss_end_screen")
	if _main.call("_mission_key_for", _main.call("_level_name")) != 210:
		_main.call("_change_level", "MAP.210", false, false)
		if not await _wait(func() -> bool: return _level_is("210") and _settled(), 180.0):
			return _check(false, "MAP.210 loads for the restart check")
	var snap: Dictionary = _main.get("_mission_start_state")
	_check(not snap.is_empty() and int(_main.get("_mission_start_snap_key")) == 210,
		"a mission-start snapshot was taken when mission 1 began")
	var start_owned: Array = (snap.get("owned", []) as Array).duplicate()
	var start_bullets: int = int((snap.get("pools", {}) as Dictionary).get(0, -1))
	# Make the attempt worth throwing away: a spent pool, a hurt player and
	# a per-map overlay with something in it.
	(player.get("_pools") as Dictionary)[0] = 7
	player.set("health", 33.0)
	(_main.get("_map_state") as Dictionary)["MAP.218"] = {"dead": {}, "taken": {}}
	# Die.
	player.set("god_mode", false)
	player.call("take_damage", 1.0e6)
	var ok: bool = await _wait(func() -> bool: return _main.get("_game_over") != null, 12.0)
	_check(ok and bool(_main.get("_game_over_failed")) and not bool(_main.get("_game_over_restart")),
		"death puts up MISSION FAILED, with no box under it yet")
	ok = await _wait(func() -> bool: return bool(_main.get("_game_over_restart")), 12.0)
	_check(ok, "the RESTART MISSION box follows the banner by itself")
	if not ok:
		return
	# …and it is the original's own 96x37 box, not the fallback buttons.
	var art_box: bool = false
	for c in (_main.get("_game_over_box") as Node).get_children():
		for g in c.get_children():
			if g is TextureRect and (g as TextureRect).texture != null \
					and (g as TextureRect).texture.get_width() == 96:
				art_box = true
	_check(art_box, "the box is RESTART.IMG itself, with its baked YES / NO")
	# YES.
	_main.call("_end_screen_accept")
	ok = await _wait(func() -> bool: return _main.get("_briefing_overlay") != null, 60.0)
	_check(ok, "the restart goes through the mission briefing, as DOS does")
	if ok:
		_main.call("_briefing_begin")
	ok = await _wait(func() -> bool: return _level_is("210") and _settled(), 180.0)
	_check(ok, "the restart replays the mission from its FIRST map")
	if not ok:
		return
	_check((_main.get("_map_state") as Dictionary).is_empty()
		and String(_main.get("_prev_map_name")).is_empty(),
		"every map's saved state is gone (%d overlays left)" % (_main.get("_map_state") as Dictionary).size())
	_check(int(_main.get("_objectives_left")) == int(_main.get("_objectives_total"))
		and int(_main.get("_objectives_left")) > 0,
		"the objective counter is back to the full %d" % int(_main.get("_objectives_total")))
	_check(_main.get("_game_over") == null and int(_main.get("_mission_ended_key")) == -1,
		"the mission is playable again — no end screen, nothing won")
	_check(is_equal_approx(float(player.get("health")), float(snap.get("health", -1.0)))
		and int(player.call("pool_count", 0)) == start_bullets
		and player.call("owned_list") == start_owned,
		"the player is back as the mission started him (%.0f HP, %d bullets, %d weapons)"
			% [float(player.get("health")), int(player.call("pool_count", 0)), start_owned.size()])
	# A second failure must work exactly the same way.
	player.call("take_damage", 1.0e6)
	ok = await _wait(func() -> bool: return bool(_main.get("_game_over_restart")), 20.0)
	_check(ok, "a second death asks again")
	if ok:
		_main.call("_end_screen_accept")
		ok = await _wait(func() -> bool: return _main.get("_briefing_overlay") != null, 60.0)
		if ok:
			_main.call("_briefing_begin")
		var back: bool = await _wait(func() -> bool: return _level_is("210") and _settled(), 180.0)
		_check(back, "the second restart replays the mission too")
	player.set("god_mode", true)

## A handful of MAP.210's triggers driven through the REAL INPUT PATH and
## laid against the graph's prediction — the step-4 verifier
## (scripts/triggers/trigger_verifier.gd) on four nodes instead of four
## thousand, so a suite can afford it. The full run is a CLI command,
## `--verify-triggers=all`; this is the tripwire under it, and under the
## player driver the solver also uses: a key that stops reaching
## fly_camera._unhandled_input shows up here in a second.
## What each of the DOS keys must select: {key: [record, name, pool]}.
## The records come from the weapon table at 0x43714 (+0x4c = the pool);
## the key chain that hands them to WeaponSelectScn is at 0x11b0f5.
const THROW_KEYS: Dictionary = {
	KEY_F1: [15, "MOLOTOV", 6],
	KEY_F2: [14, "PIPE BOMB", 5],
	KEY_F3: [16, "GRENADE", 2],
	KEY_F4: [18, "CANISTER BOMB", 8],
	KEY_F5: [19, "SATCHEL", 9],
}

## Tap a key the way a player does — Input.parse_input_event, flushed at
## once, so it travels the real path into fly_camera._unhandled_input.
func _tap(code: int) -> void:
	for down in [true, false]:
		var k := InputEventKey.new()
		k.keycode = code as Key
		k.physical_keycode = code as Key
		k.pressed = down
		k.echo = false
		Input.parse_input_event(k)
		Input.flush_buffered_events()
	await get_tree().process_frame

## The thrown items: F1-F5 pick one each, an EMPTY one can be picked and
## throws nothing at all, and in a vehicle no weapon key does anything
## ("the different grenade types are completely missing", playtest
## 2026-09-16 — the port only had a forward-only cycle on `0`).
func _check_throwables(player: CharacterBody3D) -> void:
	var pool_record: Dictionary = preload("res://scripts/hud_panel.gd").POOL_RECORD
	var hit: int = 0
	for key in THROW_KEYS:
		var want: Array = THROW_KEYS[key]
		await _tap(int(key))
		if String(player.get("secondary_name")) == String(want[1]) \
				and int(player.get("secondary_pool")) == int(want[2]) \
				and int(pool_record.get(int(want[2]), -1)) == int(want[0]):
			hit += 1
		else:
			print("[e2e]   %s selected %s (pool %d), wanted %s (pool %d, record %d)"
				% [OS.get_keycode_string(int(key)), str(player.get("secondary_name")),
				   int(player.get("secondary_pool")), str(want[1]), int(want[2]), int(want[0])])
	_check(hit == THROW_KEYS.size(),
		"F1-F5 each select their DOS record (%d of %d)" % [hit, THROW_KEYS.size()])

	# An EMPTY item is selectable — DOS tests the owned bit and nothing
	# else — and throwing it does nothing, silently.
	var live: Dictionary = player.get("_pools")
	live[2] = 0                                # the grenades DOS starts at 0
	live[8] = 0
	await _tap(KEY_F3)
	_check(String(player.get("secondary_name")) == "GRENADE"
		and int(player.get("secondary_ammo")) == 0,
		"an empty item is still selectable (GRENADE x%d)" % int(player.get("secondary_ammo")))
	var idx_before: int = int(player.get("_throw_idx"))
	var live_before: int = get_tree().get_nodes_in_group("projectile").size()
	player.set("_throw_cd", 0.0)
	player.call("_throw_secondary")
	await get_tree().physics_frame
	_check(int(player.get("_throw_idx")) == idx_before
		and int(player.call("pool_count", 2)) == 0
		and get_tree().get_nodes_in_group("projectile").size() == live_before,
		"throwing an empty item throws nothing and does not cycle away from it")
	# The next one along is taken even though IT is empty too.
	player.call("cycle_throwable", 1)
	_check(String(player.get("secondary_name")) == "CANISTER BOMB",
		"the cycle no longer skips an empty item (%s)" % str(player.get("secondary_name")))
	# A stocked one leaves the hand.
	await _tap(KEY_F2)
	var pipes: int = int(player.call("pool_count", 5))
	player.set("_throw_cd", 0.0)
	player.call("_throw_secondary")
	await get_tree().physics_frame
	_check(pipes > 0 and int(player.call("pool_count", 5)) == pipes - 1,
		"a stocked item is thrown and costs one (%d → %d)" % [pipes, int(player.call("pool_count", 5))])

	# In a vehicle NO weapon key works: DOS skips the whole block on the
	# player-mode register (0x11b025).
	var at: Vector3 = player.global_position
	var was_weapon: int = int(player.get("_weapon_idx"))
	player.call("set_vehicle", 1)
	var veh_weapon: int = int(player.get("_weapon_idx"))
	var veh_throw: int = int(player.get("_throw_idx"))
	for key in THROW_KEYS:
		await _tap(int(key))
	await _tap(KEY_0)
	await _tap(KEY_2)
	_check(bool(player.call("_weapon_keys_blocked"))
		and int(player.get("_throw_idx")) == veh_throw
		and int(player.get("_weapon_idx")) == veh_weapon,
		"in the jeep neither F1-F5 nor `0` nor the number keys change a weapon")
	player.call("set_vehicle", 0)
	player.global_position = at
	player.call("_select_weapon", was_weapon)
	for f in 4:
		await get_tree().physics_frame

## One mouse movement, straight into the handler. The keys above already
## prove the real input path reaches it; what is measured here is the rate
## and the SIGN, which is what OPTIONS → CONTROLS → MOUSE sets.
func _look_dy(player: CharacterBody3D, dy: float) -> void:
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(0.0, dy)
	player.call("_unhandled_input", mm)

## MOUSE SENSITIVITY and REVERSE VERTICAL — the DOS mouse page's three
## settings ("chýbajú mi nastavenia myši", playtest 2026-09-16). The
## settings ("I'm missing mouse settings — movement speed and reverse Y
## axis", playtest 2026-09-16). The sensitivity is one number per axis
## over eleven steps, as CONTROLS.DAT +0x44 / +0x48 keep it, and REVERSE
## VERTICAL (+0x60) reaches the JEEP's turret as well as the soldier's
## head.
func _check_mouse_settings(player: CharacterBody3D) -> void:
	var h0: int = Settings.mouse_h
	var v0: int = Settings.mouse_v
	var inv0: bool = Settings.mouse_invert_y
	var was_captured: bool = bool(player.get("_captured"))
	player.set("_captured", true)
	_check(is_equal_approx(Settings.mouse_rate_x(), Settings.MOUSE_BASE_RATE)
		and Settings.mouse_h == Settings.MOUSE_DEFAULT,
		"the DOS default step is the rate the port has always looked at (%.4f rad/px)"
			% Settings.mouse_rate_x())
	# The screen works in lit segments: 11 lit is the fastest step, 1 the
	# slowest, and the span is the original's 11 : 1.
	Settings.set_mouse_h(Settings.MOUSE_STEPS)
	var fastest: float = Settings.mouse_rate_x()
	Settings.set_mouse_h(1)
	var slowest: float = Settings.mouse_rate_x()
	_check(Settings.mouse_h == 11 and is_equal_approx(fastest / slowest, 11.0),
		"the sensitivity spans 11 : 1, as the DOS bar does (%.4f .. %.4f rad/px)" % [slowest, fastest])
	Settings.set_mouse_h(SettingsLib.mouse_lit(h0))
	# It is written where _ready reads it: a restart of the game finds it.
	Settings.set_mouse_v(4)
	Settings.set_mouse_invert_y(true)
	var cfg := ConfigFile.new()
	var read_back: bool = cfg.load(Settings.CFG_PATH) == OK
	_check(read_back and int(cfg.get_value("controls", "mouse_v", -1)) == Settings.mouse_v
		and bool(cfg.get_value("controls", "mouse_invert_y", false)),
		"the mouse settings are written to %s, where the next start reads them" % Settings.CFG_PATH)
	# REVERSE VERTICAL, on foot and in the jeep.
	player.call("set_view", 0.0, 0.0)
	Settings.set_mouse_invert_y(false)
	_look_dy(player, 20.0)
	var normal: float = float(player.get("_pitch"))
	player.call("set_view", 0.0, 0.0)
	Settings.set_mouse_invert_y(true)
	_look_dy(player, 20.0)
	var inverted: float = float(player.get("_pitch"))
	_check(normal < -0.001 and is_equal_approx(inverted, -normal),
		"REVERSE VERTICAL flips the soldier's pitch (%.3f → %.3f rad)" % [normal, inverted])
	var at: Vector3 = player.global_position
	player.call("set_vehicle", 1)
	Settings.set_mouse_invert_y(false)
	player.set("_aim_pitch", 0.0)
	_look_dy(player, 20.0)
	var turret: float = float(player.get("_aim_pitch"))
	Settings.set_mouse_invert_y(true)
	player.set("_aim_pitch", 0.0)
	_look_dy(player, 20.0)
	var turret_inv: float = float(player.get("_aim_pitch"))
	_check(absf(turret) > 0.001 and is_equal_approx(turret_inv, -turret),
		"…and the jeep's turret with it (%.3f → %.3f rad)" % [turret, turret_inv])
	player.call("set_vehicle", 0)
	player.global_position = at
	# Put the player's own settings back exactly as they were: save()
	# rewrites the whole file, so nothing of it is left changed.
	Settings.set_mouse_h(SettingsLib.mouse_lit(h0))
	Settings.set_mouse_v(SettingsLib.mouse_lit(v0))
	Settings.set_mouse_invert_y(inv0)
	player.set("_captured", was_captured)
	player.call("set_view", 0.0, 0.0)
	for f in 4:
		await get_tree().physics_frame

const VERIFY_NODES: Array = [
	0x077f3,     # the canyon lever (0xF1): the gate's two leaves part
	0x0ba48,     # one gate of the ring round the jeep: the hint and the line
	0x076f7,     # a doorway (0xF0): touching arms it, the key takes it
	0x0c9b4,     # a destructible: one rifle round is one damage stage
]

func _check_trigger_verifier() -> void:
	if not _level_is("210"):
		# The checks above finish on whatever map they needed last; the
		# four nodes below are MAP.210's, and it is loaded fresh so the
		# graph's prediction is made for the map the file has.
		(_main.get("_map_state") as Dictionary).erase("MAP.210")
		_main.call("_change_level", "MAP.210", false, false)
		var back: bool = await _wait(func() -> bool:
			return _level_is("210") and _settled(), 180.0)
		_check(back, "MAP.210 loads for the trigger verifier")
		if not back:
			return
	var v: Node = load("res://scripts/triggers/trigger_verifier.gd").new()
	v.name = "TriggerVerifierSubset"
	v.set("main", _main)
	_main.add_child(v)
	var rows: Array = await v.call("check_current", VERIFY_NODES)
	var good: int = 0
	for r in rows:
		var row: Dictionary = r
		if String(row["res"]) == "PASS":
			good += 1
		else:
			_check(false, "verifier: %05x %s — %s" % [int(row["id"]),
				String(row["res"]), String(row["why"])])
	_check(good == VERIFY_NODES.size(),
		"%d of %d triggers do through the keys what the graph says they do"
		% [good, VERIFY_NODES.size()])
	v.queue_free()

## Mission 1's last objective through main.gd's own level changes and
## saves (playtest 2026-09-15: "let's roll" at the jeep, and the next
## mission never loaded). MAP.210 and MAP.216 carry the jeep HUMMERTK
## @075cb as hint [G1], MAP.217 carries the same entity as [M3]. Firing the
## hint on MAP.210 retired MAP.217's objective through the variant import
## (210 → 216 → 217, first visits), so it never counted. Also: a counted
## objective stays counted across a save and load, and a v0.3.0 save that
## carries the foreign retirement gets the objective back live.
## Mission 1's base gate (one BIGDOOR leaf) and the 0xEF wall button up
## the tower that runs it — the same records on MAP.210, 216 and 217.
const BASE_GATE: int = 0x078f7
const TOWER_SWITCH: int = 0x09551

## Press the tower switch on `lvl` (the chain the crosshair's key walks)
## and let the leaf slide open. True when it did.
func _open_base_gate(lvl) -> bool:
	if lvl == null or lvl.behaviour == null or lvl.behaviour.mover_node(BASE_GATE) == null:
		return false
	var leaf: Node = lvl.behaviour.mover_node(BASE_GATE)
	lvl.behaviour.flip_chain(TOWER_SWITCH)
	return await _wait(func() -> bool:
		return is_instance_valid(leaf) and absf(float(leaf.progress)) > 100.0 \
			and not bool(leaf.running), 20.0)

func _check_variant_objective() -> void:
	var jeep_off: int = 0x75cb
	# Both variants visited for the first time from here, whatever came before.
	var st: Dictionary = _main.get("_map_state")
	st.erase("MAP.216")
	st.erase("MAP.217")
	_main.call("_on_teleport_requested", 210, 0)
	var ok: bool = await _wait(func() -> bool: return _level_is("210") and _settled(), 180.0)
	_check(ok, "MAP.210 loads for the variant objective check")
	if not ok:
		return
	var lvl = _main.get("_current_level")
	var jeep = lvl.map.entities_by_off.get(jeep_off)
	_check(jeep != null and lvl.triggers.act(jeep_off) == 0x1C,
		"MAP.210's jeep is hint [G1] (act 0x1c)")
	if jeep == null:
		return
	var left0: int = int(_main.get("_objectives_left"))
	_check(left0 >= 2 and int((_main.get("_objective_cursor") as Array)[2]) == 0,
		"mission 1 has its [M3] still to do (%d left)" % left0)
	var at := Vector3(float(jeep.x), -float(jeep.y), -float(jeep.z))
	lvl.behaviour.press_use()                   # the eight gates answer the use key
	lvl.behaviour.tick(0.016, at)
	_check(lvl.triggers.act(jeep_off) == 0xFF and int(_main.get("_objectives_left")) == left0,
		"the gates fire MAP.210's jeep hint: retired, nothing counted")

	_main.call("_on_teleport_requested", 216, 12)
	ok = await _wait(func() -> bool: return _level_is("216") and _settled(), 180.0)
	_check(ok, "MAP.210 → MAP.216 (first visit, variant import)")
	if not ok:
		return
	lvl = _main.get("_current_level")
	var j216 = lvl.map.entities_by_off.get(jeep_off)
	_check(j216 != null and lvl.triggers.act(jeep_off) == 0x1C,
		"MAP.216's jeep hint is its own: no act byte crosses from MAP.210")
	# The tower switch opens the base gate on MAP.216 — which must not be
	# open when MAP.217 comes up.
	_check(await _open_base_gate(lvl), "MAP.216's tower switch @%05x opens the base gate" % TOWER_SWITCH)

	_main.call("_on_teleport_requested", 217, 14)
	ok = await _wait(func() -> bool: return _level_is("217") and _settled(), 180.0)
	_check(ok, "MAP.216 → MAP.217 (first visit, variant import)")
	if not ok:
		return
	lvl = _main.get("_current_level")
	var leaf: Node = lvl.behaviour.mover_node(BASE_GATE) if lvl.behaviour != null else null
	_check(leaf != null and absf(float(leaf.progress)) < 1.0
		and int(lvl.triggers.state(BASE_GATE)) == int(lvl.map.entities_by_off[BASE_GATE].state_byte),
		"MAP.217's base gate @%05x arrives closed though MAP.210 and MAP.216 opened theirs (at %.0f)"
		% [BASE_GATE, float(leaf.progress) if leaf != null else -1.0])
	_check(await _open_base_gate(lvl), "MAP.217's tower switch @%05x opens it" % TOWER_SWITCH)
	var j217 = lvl.map.entities_by_off.get(jeep_off)
	var cue: Node = lvl.behaviour.node(jeep_off) if lvl.behaviour != null else null
	_check(j217 != null and lvl.triggers.act(jeep_off) == 0x28
		and cue != null and not bool(cue.get("spent")),
		"MAP.217's jeep arrives as a live [M3] objective")
	var trig = lvl.map.entities_by_off.get(0x80c5)
	_check(trig != null and trig.link_act_type == 0xF2 and lvl.triggers.enabled(0x80c5),
		"MAP.217's 210BASE3 keeps its armed 0xF2 bit (scenery with state 00 on the variants)")
	if j217 == null or cue == null:
		return
	at = Vector3(float(j217.x), -float(j217.y), -float(j217.z))
	lvl.behaviour.press_use()
	lvl.behaviour.tick(0.016, at)
	var left1: int = int(_main.get("_objectives_left"))
	_check(left1 == left0 - 1 and int((_main.get("_objective_cursor") as Array)[2]) == 1,
		"the jeep counts [M3] on MAP.217 (%d → %d left)" % [left0, left1])

	# The mission-key rule: interiors and non-mission sub-maps stay mission 1's.
	_check(int(_main.call("_mission_key_for", "MAP.340")) == 210
		and int(_main.call("_mission_key_for", "MAP.292")) == 210
		and int(_main.call("_mission_key_for", "MAP.217")) == 210
		and int(_main.call("_mission_key_for", "MAP.230")) == 230,
		"interiors without a mission of their own belong to the mission being played")

	# Save / load: counted stays counted.
	_check(bool(_main.call("save_to_slot", 9)), "save on MAP.217 after [M3] counted")
	var old_id: int = (_main.get("_current_level") as Object).get_instance_id()
	_main.call("load_from_slot", 9)
	ok = await _wait(func() -> bool:
		var cur = _main.get("_current_level")
		return cur != null and cur.get_instance_id() != old_id and _level_is("217") and _settled() \
			and (_main.get("_pending_player") as Dictionary).is_empty(), 180.0)
	_check(ok, "the MAP.217 save loads")
	if not ok:
		return
	lvl = _main.get("_current_level")
	cue = lvl.behaviour.node(jeep_off)
	_check(bool(cue.get("spent")) and lvl.triggers.act(jeep_off) == 0xFF
		and int(_main.get("_objectives_left")) == left1,
		"a counted objective stays counted after the load (%d left)" % int(_main.get("_objectives_left")))
	_check(not bool(_main.get("_mission_done")), "the loaded level can end its mission (_mission_done down)")
	lvl.behaviour.press_use()
	lvl.behaviour.tick(0.016, at)
	_check(int(_main.get("_objectives_left")) == left1, "and the jeep cannot count it a second time")

	# A v0.3.0 save: the imported retirement sits in MAP.217's overlay while
	# [M3] was never shown. The load must give the objective back.
	var data: Dictionary = SaveGame.read(9)
	var acts: Dictionary = data.get("map_state", {}).get("MAP.217", {}).get("triggers", {}).get("acts", {})
	_check(int(acts.get(jeep_off, -1)) == 0xFF, "the save holds the jeep's retirement")
	# …and an overlay written BEFORE migration step 5h keeps that same
	# dictionary under "action". The two convert 1:1 — every key in either
	# is a MAP file offset — so the load reads whichever name is there.
	_check(int((_main.call("_trigger_state", {"action": {"acts": {jeep_off: 0xFF}}})
			as Dictionary).get("acts", {}).get(jeep_off, -1)) == 0xFF
		and (_main.call("_trigger_state", data.get("map_state", {}).get("MAP.217", {}))
			as Dictionary).has("acts"),
		"a pre-5h overlay's trigger state is read under its own name")
	var objs: Dictionary = data["objectives"]
	objs["left"] = left0
	(objs["cursor"] as Array)[2] = 0
	old_id = (_main.get("_current_level") as Object).get_instance_id()
	_main.call("load_from_slot", 9, data)
	ok = await _wait(func() -> bool:
		var cur = _main.get("_current_level")
		return cur != null and cur.get_instance_id() != old_id and _level_is("217") and _settled() \
			and (_main.get("_pending_player") as Dictionary).is_empty(), 180.0)
	_check(ok, "the doctored v0.3.0-style save loads")
	if not ok:
		return
	lvl = _main.get("_current_level")
	cue = lvl.behaviour.node(jeep_off)
	_check(not bool(cue.get("spent")) and lvl.triggers.act(jeep_off) == 0x28
		and int(_main.get("_objectives_left")) == left0,
		"an objective retired but never counted comes back live (%d left)" % int(_main.get("_objectives_left")))
	lvl.behaviour.press_use()
	lvl.behaviour.tick(0.016, at)
	_check(int(_main.get("_objectives_left")) == left1, "and the jeep counts it once (%d left)" % int(_main.get("_objectives_left")))
	# Give [M3] back: the silo check after this counts MAP.215's two
	# objectives and must not finish mission 1 on the way.
	_main.set("_objectives_left", left0)
	(_main.get("_objective_cursor") as Array)[2] = 0
	lvl.behaviour.objectives_left = left0
	st = _main.get("_map_state")
	st.erase("MAP.216")
	st.erase("MAP.217")

	# The shape cache key of an entity mesh: its MAP mesh, never a node name.
	var probe := MeshInstance3D.new()
	probe.name = "@MeshInstance3D@7"
	probe.mesh = Assets.mesh("BIGDOOR.3D")
	var k1: String = String(_main.call("_shape_key", probe))
	probe.mesh = BoxMesh.new()
	var k2: String = String(_main.call("_shape_key", probe))
	probe.free()
	_check(k1 == "BIGDOOR" and k2 == "", "shape cache keys come from the mesh (%s / '%s')" % [k1, k2])

## Mission 1 ends at the jeep on MAP.217, where EIGHT 0xEF gates all
## point at the same HUMMERTK. Walking up trips several of them in one
## frame; ObjFlipLink toggles, so an even number used to cancel out and
## act 0x28 never fired — mission 1 could not be finished (2026-09-04).
func _check_jeep_objective() -> void:
	# A fresh MAP.217: step 7b left its jeep counted and retired.
	(_main.get("_map_state") as Dictionary).erase("MAP.217")
	if _main.get("_game_over") != null:
		_main.call("_advance_to", "MAP.217")
	else:
		_main.call("_on_teleport_requested", 217, 0)
	var ok: bool = await _wait(func() -> bool: return _level_is("217") and _settled(), 180.0)
	_check(ok, "MAP.217 loads for the jeep check")
	if not ok:
		return
	var lvl = _main.get("_current_level")
	var jeep = lvl.map.entities_by_off.get(0x75cb)
	_check(jeep != null and lvl.triggers.act(0x75cb) == 0x28,
		"the MAP.217 jeep carries objective act 0x28")
	if jeep == null:
		return
	var objs: Array = []
	lvl.behaviour.objective_complete.connect(func(i: int) -> void: objs.append(i))
	# Stand on the jeep and press use: every gate around it trips in the
	# same tick (DOS fires all the 0xEF gates within 60 u on the key).
	lvl.behaviour.press_use()
	lvl.behaviour.tick(0.016, Vector3(float(jeep.x), -float(jeep.y), -float(jeep.z)))
	lvl.behaviour.tick(0.016, Vector3(float(jeep.x), -float(jeep.y), -float(jeep.z)))
	_check(objs.has(0x28 - 0x26),
		"eight gates tripping at once still fire objective 0x28 (%s)" % str(objs))
	await _check_jeep_ram()

## The jeep's ram (DOS v1.00 0x135a7e): one ObjHit of speed/2 per contact,
## no difficulty factor; a robot that survives throws the car back to
## where the move started with its speed negated, a destroyed one lets it
## roll on at 7/8. A raptor (200 HP) took any ram at all as its death
## until 2026-09-15. Its death blast (EnemyKill) reaches ~78 u.
func _check_jeep_ram() -> void:
	_check(Enemy.death_blast_damage(0.0) == 114 and Enemy.death_blast_damage(77.0) == 37
		and Enemy.death_blast_damage(78.0) == 0 and Enemy.death_blast_damage(500.0) == 0,
		"a robot's death blast: 114 at its centre, 37 at 77 u, nothing from 78 u (%d/%d/%d)"
		% [Enemy.death_blast_damage(0.0), Enemy.death_blast_damage(77.0), Enemy.death_blast_damage(78.0)])
	var player: CharacterBody3D = _main.get("player")
	var target: Node3D = null
	for e in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and (e as Node3D).visible and not bool(e.get("indestructible")) \
				and not bool(e.get("_hidden")) and not bool(e.call("is_dead")) and e.has_method("obj_hit"):
			if target == null or String(e.name).contains("raptor"):
				target = e
			if String(e.name).contains("raptor"):
				break
	_check(target != null, "MAP.217 has a robot to ram")
	if target == null:
		return
	# The DOS scale (0x122652): 1000 points of soldier, armour costs
	# 82/65536 of its bar per point and keeps its own fraction off him.
	var armor_keep: float = float(player.get("armor"))
	player.set("god_mode", false)
	player.set("health", 100.0)
	player.set("armor", 0.0)
	player.call("take_dos_damage", 100.0, false)
	_check(is_equal_approx(float(player.get("health")), 90.0),
		"100 DOS points take a tenth of the bar with no armour (%.2f)" % float(player.get("health")))
	player.set("armor", 1.0)
	player.call("take_dos_damage", 100.0, false)
	_check(absf(float(player.get("armor")) - 0.875) < 0.001 and absf(float(player.get("health")) - 88.75) < 0.01,
		"full armour drops to 0.875 on a 100-point hit and keeps 87.5 %% of it off (armour %.3f, health %.2f)"
		% [float(player.get("armor")), float(player.get("health"))])
	player.set("health", 100.0)
	player.set("armor", armor_keep)
	player.set("god_mode", true)
	player.call("set_vehicle", 1)
	target.set("_health", 200.0)                  # a raptor's hit points
	var fwd := Vector3(0.0, 0.0, -1.0)
	var yaw: float = 0.0                          # facing -z
	var feet: Vector3 = target.global_position + Vector3(0.0, float(target.get("_foot_offset")), 0.0)
	var pre: Vector3 = feet - fwd * 700.0
	var contact: Vector3 = feet - fwd * 100.0
	player.set("_yaw", yaw)
	player.rotation.y = yaw
	player.global_position = contact
	player.set("_veh_speed", 300.0)
	player.set("_wheel", 0.7)
	var undone: bool = bool(player.call("_ram_check", pre, yaw))
	_check(undone and is_equal_approx(float(target.get("_health")), 50.0)
		and is_equal_approx(float(player.get("_veh_speed")), -300.0)
		and player.global_position.is_equal_approx(pre) and float(player.get("_wheel")) == 0.0,
		"a ram at 300 u/s deals 150 and the car bounces back, wheel centred (hp %.0f, speed %.0f)"
		% [float(target.get("_health")), float(player.get("_veh_speed"))])
	# Straight back into it: the same robot is not dosed again at once.
	player.global_position = contact
	player.set("_veh_speed", 300.0)
	player.call("_ram_check", pre, yaw)
	_check(is_equal_approx(float(target.get("_health")), 50.0) and float(player.get("_veh_speed")) == 0.0,
		"the next touch a moment later only stops the car (hp %.0f)" % float(target.get("_health")))
	player.set("_ram_clock", float(player.get("_ram_clock")) + 1.0)
	player.global_position = contact
	player.set("_veh_speed", 400.0)
	undone = bool(player.call("_ram_check", pre, yaw))
	_check(not undone and bool(target.call("is_dead")) and is_equal_approx(float(player.get("_veh_speed")), 350.0),
		"the second ram destroys it and the car rolls on at 7/8 (speed %.0f)" % float(player.get("_veh_speed")))
	# The wreck's blast, 0.375 s on, catches the car rolling over it.
	var wreck: Vector3 = target.global_position
	player.set("_veh_speed", 0.0)
	player.set("noclip", true)
	player.global_position = wreck + Vector3(30.0, -70.0, 0.0)   # car centre 30 u off
	player.set("god_mode", false)
	player.set("health", 500.0)
	var armor0: float = float(player.get("armor"))
	player.set("armor", 0.0)
	var hits: Array = []
	var on_hurt := func(amount: float) -> void: hits.append(snappedf(amount, 0.1))
	player.connect("hurt", on_hurt)
	for f in 40:
		await get_tree().physics_frame
	player.disconnect("hurt", on_hurt)
	# d = 30: 115 - 30 in DOS steps = 84 points of the 1000-point soldier,
	# 8.4 of the port's bar — and in the jeep it is the hull that takes it.
	# (The robots around take their shots at the car meanwhile: the hull
	# takes those too, the driver none of them.)
	var hull: float = float(player.get("veh_hull"))
	_check(hits.has(8.4) and hull <= 1000.0 - 84.0 and is_equal_approx(float(player.get("health")), 500.0),
		"the wreck's blast hits the jeep that ran it over: hull 1000 → %.0f, driver untouched (hits %s)" % [hull, str(hits)])
	player.set("armor", armor0)
	player.set("health", 100.0)
	player.set("god_mode", true)
	player.set("noclip", false)
	await _check_jeep_aim(player)
	player.call("set_vehicle", 0)

## The jeep's guns fire along the TURRET — the view the crosshair is drawn
## on, which _drive builds at the end of the frame's move. The HELD
## trigger is serviced inside _physics_process, BEFORE _drive: a view
## rebuilt at the top of that step (the soldier's `_pitch`, 0 in the jeep)
## sent every auto-fire bolt along a level axis while the crosshair sat
## where the turret pointed — 12° of aim, 12° of miss (2026-09-16). The
## rockets hid it, since the THROW key fires them from the input event.
## Both are checked here: a shot has to leave the muzzle AT the point
## under the crosshair (DOS's own rule, the aim bit at weapon record
## +0x5c, 0x125dc3).
func _check_jeep_aim(player: CharacterBody3D) -> void:
	var cam: Camera3D = player.get("_cam")
	if cam == null:
		_check(false, "the jeep aim check has a camera")
		return
	player.set("_aim_yaw", deg_to_rad(9.0))
	player.set("_aim_pitch", deg_to_rad(-12.0))
	for _i in 6:
		await get_tree().physics_frame
	# The view AS DRAWN, and what the crosshair on its axis is resting on.
	var eye: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(eye, eye + fwd * 20000.0)
	q.collide_with_areas = true
	q.exclude = [player.get_rid()]
	var seen := space.intersect_ray(q)
	_check(seen.has("position"), "the jeep's crosshair rests on something to shoot at")
	if not seen.has("position"):
		return
	var cross: Vector3 = seen["position"]
	# Every shot is caught and frozen where it left the muzzle.
	var caught: Array = []
	var on_child := func(n: Node) -> void:
		if n.get_script() == Projectile:
			n.process_mode = Node.PROCESS_MODE_DISABLED
			caught.append(n)
	child_entered_tree.connect(on_child)
	for shot_case in [["plasma", 13, true], ["rockets", 14, false]]:
		(player.get("_pools") as Dictionary)[10] = 2000
		player.set("_veh_overheated", false)
		player.set("_fire_cd", 0.0)
		player.set("_weapon_idx", int(shot_case[1]))
		caught.clear()
		if bool(shot_case[2]):
			player.set("ui_fire", true)          # the held trigger: inside the physics step
			await get_tree().physics_frame
		else:
			player.call("_throw_secondary")      # the THROW key: from the input event
			await get_tree().process_frame
		if caught.is_empty():
			_check(false, "the jeep's %s leave the muzzle" % shot_case[0])
			continue
		var bolt: Node3D = caught[0]
		var err: float = rad_to_deg((cross - bolt.global_position).normalized()
			.angle_to(bolt.get("_dir") as Vector3))
		_check(err < 1.0, "the jeep's %s fly at the point under the crosshair (%.2f° off)"
			% [shot_case[0], err])
		for n in caught:
			n.queue_free()
	child_entered_tree.disconnect(on_child)
	player.set("_aim_yaw", 0.0)
	player.set("_aim_pitch", 0.0)

## MAP.248: the START BOX runs the IBEM64 girder into 248WALL. The wall
## is a 0x19 destructible with no HP of its own — the chain has to break
## it, which is the only way through (2026-09-04).
func _check_ram_wall() -> void:
	_main.call("_on_teleport_requested", 248, 0)
	var ok: bool = await _wait(func() -> bool: return _level_is("248") and _settled(), 180.0)
	_check(ok, "MAP.248 loads for the ram check")
	if not ok:
		return
	var lvl = _main.get("_current_level")
	var wall = lvl.map.entities_by_off.get(0x35a6)
	var box = lvl.map.entities_by_off.get(0x381d)
	_check(wall != null and wall.link_act_type == 0x19, "248WALL is a destructible")
	_check(box != null and box.link_act_type == 0xEF, "STARTBX is a proximity gate")
	if wall == null or box == null:
		return
	var at := Vector3(float(box.x), -float(box.y), -float(box.z))
	# The START BOX is pressed, not walked into, and the girder has to ram
	# the wall several times before it gives (the DOS run, 2026-09-11).
	var presses: int = 0
	while presses < 12 and not lvl.triggers.spent(wall.file_off):
		lvl.behaviour.press_use()
		lvl.behaviour.tick(0.016, at)
		lvl.behaviour.tick(0.016, at)
		presses += 1
	_check(lvl.triggers.spent(wall.file_off) and presses > 1,
		"the START BOX chain breaks the wall open after several rams (%d)" % presses)

## Marker 103/104 is the map's water level (DOS 0x120bf9): the harbour
## on MAP.250 stands at 784, and the player swims in it instead of
## walking on a dry sea bed (2026-09-04).
func _check_water() -> void:
	_main.call("_on_teleport_requested", 250, 0)
	var ok: bool = await _wait(func() -> bool: return _level_is("250") and _settled(), 240.0)
	_check(ok, "MAP.250 loads for the water check")
	if not ok:
		return
	var lvl = _main.get("_current_level")
	var y: float = float(_main.call("_water_level", lvl))
	# 816 = -(marker Y) + 16: the DOS surface is 16 units ABOVE the marker
	# (level = marker.Y - 0x10 with Y growing downward), which the port had
	# the wrong way round until 2026-09-12.
	_check(y == 816.0, "MAP.250 water surface is at y=816 (%s)" % str(y))
	_check(_main.get("_water") != null, "the water surface node exists")
	var pl = _main.get("player")
	_check(float(pl.get("water_level")) == y, "the player knows the water level")
	# Standing on the harbour floor means swimming, not walking.
	pl.set("global_position", Vector3(5000.0, 300.0, -13300.0))
	pl.call("_water_check")
	_check(bool(pl.get("in_water")), "down in the harbour the player is in the water")
	_check(bool(pl.get("head_under")), "and his head is under it")
	pl.set("global_position", Vector3(5000.0, 2000.0, -13300.0))
	pl.call("_water_check")
	_check(not bool(pl.get("in_water")), "above the surface he is out of it again")

## SOURCE, DERIVED, MOD. A level scene of the player's own,
## mods/maps/<MAP>.level.scn, is what the map is presented from — instead
## of the derived converted/maps/<MAP>.level.scn, with no import and no
## rebake. Copied here, played, and taken away again; the copy is byte for
## byte the derived scene, so nothing about the map can change and the
## only question this asks is WHICH FILE was instanced (level.baked_from).
##
## What a mod does not touch is what the map DOES: the records, and with
## them every trigger, still come from the DOS MAP.
func _check_scene_mod() -> void:
	var src: String = LevelScene.scene_path(MOD_MAP)
	var dir: String = PathsLib.mods_dir() + "/maps"
	var dst: String = "%s/%s.level.scn" % [dir, MOD_MAP]
	if src.is_empty() or not FileAccess.file_exists(src):
		_check(false, "%s has a baked level scene to copy" % MOD_MAP)
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var bytes := FileAccess.get_file_as_bytes(src)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null or bytes.is_empty():
		_check(false, "the mod scene can be written to %s" % dst)
		return
	f.store_buffer(bytes)
	f.close()
	_check(LevelScene.resolved_scene_path(MOD_MAP) == dst,
		"the map now resolves to the mod scene (%s)" % LevelScene.resolved_scene_path(MOD_MAP))
	# Away and back: the map has to be LOADED again for the mod to be
	# picked up, which is the promise — "on the next start", never mid-map.
	_main.call("_on_teleport_requested", int(MOD_MAP.get_extension()), 0)
	var ok: bool = await _wait(func() -> bool:
		return _level_is(MOD_MAP.get_extension()) and _settled(), 180.0)
	_check(ok, "%s loads with the mod in place" % MOD_MAP)
	var lvl = _main.get("_current_level")
	_check(ok and lvl != null and String(lvl.baked_from) == dst,
		"the mod scene is the one instanced (%s)"
			% (String(lvl.baked_from) if lvl != null else "no level"))
	_check(ok and lvl != null and lvl.map != null and not lvl.map.entities.is_empty(),
		"the map's records still come from the DOS MAP")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dst))
	_check(LevelScene.resolved_scene_path(MOD_MAP) == src,
		"with the mod gone the derived scene is back")
	# Both folders go too — but only when the test made them and nothing
	# else is in them; remove_absolute refuses a folder that is not empty.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PathsLib.mods_dir()))

## Gate geometry dump: leaf node/body transforms and a capsule sweep
## along the gate line (x - 400 .. x + 400) — '#' blocked, '.' free.
func _gate_diag(lvl, leaves: Array, centre: Vector3, probe: PhysicsShapeQueryParameters3D, space: PhysicsDirectSpaceState3D, tag: String) -> void:
	for e in leaves:
		var n: Node3D = lvl.behaviour.hit_node(e.file_off)
		var body_xf := Transform3D()
		for c in n.get_children():
			if c is AnimatableBody3D:
				body_xf = PhysicsServer3D.body_get_state(c.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		var aabb: AABB = (n as MeshInstance3D).get_aabb()
		print("[e2e] gate %s: leaf act %02x node.origin=%s aabb.x=[%.0f..%.0f] body.origin=%s" % [tag, e.link_act_type, n.global_position, (n.global_transform * aabb).position.x, (n.global_transform * aabb).end.x, body_xf.origin])
	var row := ""
	var base_xf: Transform3D = probe.transform
	for i in range(-8, 9):
		probe.transform = Transform3D(Basis(), centre + Vector3(50.0 * i, 60.0, 0.0))
		row += "#" if not space.intersect_shape(probe, 4).is_empty() else "."
	probe.transform = base_xf
	print("[e2e] gate %s sweep x=%.0f..%.0f: %s (centre y=%.0f)" % [tag, centre.x - 400.0, centre.x + 400.0, row, centre.y])

func _finish() -> void:
	SaveGame.delete(9)                                   # the test's scratch slot
	print("[e2e] %s (%d failures)" % ["ALL PASS" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)
