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
	# Next to the game data — directly, or through the development
	# checkout's res://converted link to that same directory.
	var linked: bool = Assets.root == "res://converted" 		and ProjectSettings.globalize_path("res://converted/VERSION").replace("\\", "/") != "" 		and FileAccess.file_exists(SkynetPaths.converted_dir() + "/VERSION")
	_check((Assets.root == SkynetPaths.converted_dir() or linked) and not Assets.root.begins_with("user://"),
		"asset cache sits next to the game data (%s)" % Assets.root)
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
	var action = _main.get("_current_level").action
	for h in get_tree().get_nodes_in_group("hittable"):
		var hoff: int = int(h.call("file_off"))
		if action._destr.has(hoff) and int(action._destr[hoff]["stage"]) == 0 and not action._spent.has(hoff) and (String(h.name).begins_with("CARHIP") or String(h.name).begins_with("COPCAR")):
			car = h
			break
	_check(car != null, "a staged destructible car is in the hittable group")
	if car != null:
		var off: int = car.call("file_off")
		var stage0: int = int(action._destr[off]["stage"]) if action._destr.has(off) else -1
		var rocket := preload("res://scripts/projectile.gd").new()
		add_child(rocket)
		# Straight down onto the roof — nothing but the car in the way.
		rocket.setup(car.global_position + Vector3(0, 400, 0), Vector3(0, -1, 0), 400.0,
			{"speed": 3000.0, "life": 1.0, "splash": 512.0, "hits": "enemy"}, player)
		for f in 45:
			await get_tree().physics_frame
		var stage1: int = int(action._destr[off]["stage"]) if action._destr.has(off) else -1
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
		if (e.flags & 3) == 1 and lvl.action.is_mover_off(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e).begins_with("210DOOR"):
			door_e = e
			break
	_check(door_e != null, "MAP.210 has a 210DOOR swing-door mover")
	if door_e != null:
		var dnode: Node3D = lvl.action._nodes.get(door_e.file_off)
		var dbody: AnimatableBody3D = null
		for c in dnode.get_children():
			if c is AnimatableBody3D:
				dbody = c
		_check(dbody != null, "the door leaf carries an AnimatableBody3D")
		var closed: Transform3D = dnode.global_transform
		door_e.state_byte |= 1
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
		if (e.flags & 3) == 1 and lvl.action.is_mover_off(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e) == "BIGDOOR":
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
			e.state_byte |= 1
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
	_check(bool(_main.call("save_to_slot", 9)), "save_to_slot(9) writes a save file")
	_check(SaveGame.exists(9), "slot 9 file exists (%s)" % SaveGame.path(9))
	_check(SaveGame.info(9).begins_with("MAP.210"), "slot 9 header names MAP.210 (%s)" % SaveGame.info(9))
	# Wreck the live state, then load it back.
	player.global_position = saved_pos + Vector3(4000.0, 0.0, 0.0)
	player.set("_pools", {0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 12: 1})
	player.set("health", 100.0)
	var old_lvl = _main.get("_current_level")
	_main.call("load_from_slot", 9)
	ok = await _wait(func() -> bool:
		var cur = _main.get("_current_level")
		return cur != null and cur != old_lvl and _level_is("210") and _settled() \
			and (_main.get("_pending_player") as Dictionary).is_empty(), 180.0)
	_check(ok, "load_from_slot(9) reloads MAP.210")
	if ok:
		_check(player.global_position.distance_to(saved_pos) < 150.0,
			"player restored to the saved position (d=%.0f)" % player.global_position.distance_to(saved_pos))
		_check(player.get("_pools") == saved_pools, "ammo pools restored from the save")
		_check(is_equal_approx(float(player.get("health")), 61.0), "health restored from the save (%.0f)" % float(player.get("health")))
		_check(String(_main.get("_prev_map_name")) == saved_prev, "previous-map register restored (%s)" % saved_prev)
		_check(player.call("owned_list") == saved_owned, "weapon ownership restored from the save (%d weapons)" % saved_owned.size())
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
			if (e.flags & 3) == 1 and lvl.action.is_mover_off(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e) == "BIGDOOR":
				if float(lvl.action._movers[e.file_off]["progress"]) > 100.0:
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
		lvl.action.drop_requested.connect(func(at: Vector3, t: int) -> void: drops.append(t))
		if crate != null:
			lvl.action.on_player_hit(crate.file_off, 60.0)
			_check(lvl.action._spent.has(crate.file_off), "a 60-damage hit destroys the crate")
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
			# Variant carry-over: the gate opened in MAP.210 (step 4c) is
			# open here too — MAP.216 is the same base re-authored.
			var open_leaves: int = 0
			for e in lvl.map.entities:
				if (e.flags & 3) == 1 and lvl.action.is_mover_off(e.file_off) and LevelLoader.MapFile.entity_name(lvl.map, e) == "BIGDOOR":
					if float(lvl.action._movers[e.file_off]["progress"]) > 100.0:
						open_leaves += 1
			_check(open_leaves == 2, "MAP.216 inherits the open base gate from MAP.210 (%d leaves open)" % open_leaves)

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
			if not lvl.action.is_mover_off(c.file_off()):
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

	# --- 8. MAP.215 silo: walking up to the CORC3229 gate opens the four
	# silo cover doors (0xEF ignores bit 0); the missile button raises
	# HADES and fires objective 0x27; evac at a marker-4 zone ends the
	# mission on the use key ---
	_main.call("_on_teleport_requested", 215, 0)
	ok = await _wait(func() -> bool: return _level_is("215") and _settled(), 180.0)
	_check(ok, "MAP.215 loads for the silo check")
	if ok:
		lvl = _main.get("_current_level")
		var cover = lvl.map.entities_by_off.get(0x3077)   # 210SDOR1 leaf
		var cover_node: Node3D = lvl.action._nodes.get(0x3077)
		var cbase: Vector3 = cover_node.global_position
		var gate = lvl.map.entities_by_off.get(0x32cb)    # CORC3229, state 0x10
		var gpos := Vector3(float(gate.x), -float(gate.y), -float(gate.z))
		player.set("noclip", true)
		player.velocity = Vector3.ZERO
		player.global_position = gpos
		for f in 240:
			await get_tree().physics_frame
		_check(cover_node.global_position.distance_to(cbase) > 100.0,
			"silo cover door slides open from the bit-0-less proximity gate (%.0f u)" % cover_node.global_position.distance_to(cbase))
		var objs: Array = []
		lvl.behaviour.objective_complete.connect(func(i: int) -> void: objs.append(i))
		lvl.action.on_player_activate(0x2f8f)             # missile button
		var hades: Node3D = lvl.action._nodes.get(0x47f0)
		var hbase: Vector3 = hades.global_position
		for f in 240:
			await get_tree().physics_frame
		_check(hades.global_position.distance_to(hbase) > 200.0, "HADES missile rises (%.0f u)" % hades.global_position.distance_to(hbase))
		# Objective acts are 0x26..0x2A → index 0..4 ([M1]..[M5]); the
		# 0x1C..0x25 band is hints and moves no counter.
		_check(objs.has(0x27 - 0x26), "missile chain fires mission objective 0x27 (%s)" % str(objs))
		var btn_node: Node3D = lvl.action._nodes.get(0x2f8f)
		_check(btn_node.has_meta("switch_base"), "pressed button flips to its lit face")
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
	_finish()

## Mission 1 ends at the jeep on MAP.217, where EIGHT 0xEF gates all
## point at the same HUMMERTK. Walking up trips several of them in one
## frame; ObjFlipLink toggles, so an even number used to cancel out and
## act 0x28 never fired — mission 1 could not be finished (2026-09-04).
func _check_jeep_objective() -> void:
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
	_check(jeep != null and jeep.link_act_type == 0x28,
		"the MAP.217 jeep carries objective act 0x28")
	if jeep == null:
		return
	var objs: Array = []
	lvl.behaviour.objective_complete.connect(func(i: int) -> void: objs.append(i))
	# Stand on the jeep: every gate around it trips in the same tick.
	lvl.action.tick(0.016, Vector3(float(jeep.x), -float(jeep.y), -float(jeep.z)))
	lvl.action.tick(0.016, Vector3(float(jeep.x), -float(jeep.y), -float(jeep.z)))
	_check(objs.has(0x28 - 0x26),
		"eight gates tripping at once still fire objective 0x28 (%s)" % str(objs))

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
	lvl.action.tick(0.016, at)
	lvl.action.tick(0.016, at)
	_check(lvl.action._spent.has(wall.file_off),
		"the START BOX chain breaks the wall open")

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
	_check(y == 784.0, "MAP.250 water surface is at y=784 (%s)" % str(y))
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

## Gate geometry dump: leaf node/body transforms and a capsule sweep
## along the gate line (x - 400 .. x + 400) — '#' blocked, '.' free.
func _gate_diag(lvl, leaves: Array, centre: Vector3, probe: PhysicsShapeQueryParameters3D, space: PhysicsDirectSpaceState3D, tag: String) -> void:
	for e in leaves:
		var n: Node3D = lvl.action._nodes.get(e.file_off)
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
