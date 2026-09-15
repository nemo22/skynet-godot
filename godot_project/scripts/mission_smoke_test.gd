## Headless end-to-end test of the MISSION-SCENE runtime (step 4 of
## docs/m2_mission_scene_plan.md) on the real game scene.
##
## It is a scene of its own rather than a section of game_smoke_test.gd
## because the runtime is chosen when the first level starts: the flag has
## to be up before Main boots, and the other suite must keep proving that
## the per-map runtime is untouched with the flag DOWN.
##
## What it walks: mission 1 comes up inside MISSION.210.scn, the hatch into
## MAP.218 and the return exit back out, MAP.214 ↔ MAP.215, a doorway taken
## with the use key through the action system, and finally the exit into
## MAP.216 — a PHASE variant, which is not a zone, so the mission hands
## itself back to the per-map runtime (step 5 is what keeps the world).
##
##   godot --headless --path . res://scenes/mission_smoke_test.tscn

extends Node

const MainScene := preload("res://scenes/main.tscn")
const SaveGame := preload("res://scripts/save_game.gd")

## The suite's scratch slot, wiped when it ends.
const SAVE_SLOT: int = 8

var _fails: int = 0
var _main: Node = null

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[mission-e2e] PASS  %s" % what)
	else:
		_fails += 1
		print("[mission-e2e] FAIL  %s" % what)

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

## A transition is settled once the marker set is spent and the fade-in
## has finished — the same rule the per-map suite uses.
func _settled() -> bool:
	if int(_main.get("_pending_marker_set")) != -1:
		return false
	var fade: ColorRect = _main.get("_fade")
	return fade == null or fade.color.a < 0.02

## Walk to `sfx` through the exit handler (what an 0xF0 record fires) and
## wait for the world to settle.
func _go(target_map: int, marker_set: int, sfx: String, secs: float = 180.0) -> bool:
	_main.call("_on_teleport_requested", target_map, marker_set)
	return await _wait(func() -> bool: return _level_is(sfx) and _settled(), secs)

## Distance from the player to marker set `set_id` of the level that is up,
## in WORLD units — the marker is zone-local, the zone's origin puts it in
## the world.
func _marker_gap(set_id: int) -> float:
	var lvl = _main.get("_current_level")
	var player: CharacterBody3D = _main.get("player")
	if lvl == null or not lvl.markers.has(set_id):
		return INF
	var want: Vector3 = (lvl.markers[set_id] as Array)[0] + (lvl.origin as Vector3)
	return player.global_position.distance_to(want)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The runtime is picked when the level starts, so the flag goes up
	# before Main is built. Set in memory only — a test must not write the
	# player's own settings file.
	Settings.mission_scenes = true
	SkynetPaths.selected_map = "MAP.210"
	_main = MainScene.instantiate()
	add_child(_main)
	_run()

func _run() -> void:
	var player: CharacterBody3D = _main.get("player")
	player.set("god_mode", true)

	# --- 1. Mission 1 comes up inside its own scene -------------------
	var ok: bool = await _wait(func() -> bool:
		return _main.get("_briefing_overlay") != null, 60.0)
	_check(ok, "MAP.210 briefing screen shows")
	if not ok:
		return _finish()
	var t_boot: int = Time.get_ticks_msec()
	_main.call("_briefing_begin")
	ok = await _wait(func() -> bool: return _level_is("210") and _settled(), 240.0)
	var boot_ms: int = Time.get_ticks_msec() - t_boot
	_check(ok, "MAP.210 comes up (%d ms from BEGIN to a settled world)" % boot_ms)
	if not ok:
		return _finish()
	_check(_main.get("_mission") != null, "the mission scene is up")
	_check(int(_main.get("_mission_scene_key")) == 210, "the scene is mission 210's")
	var zones: Dictionary = _main.get("_zones")
	_check(zones.size() == 7, "mission 1 stands on %d zones" % zones.size())
	_check(String(_main.get("_active_zone")) == "MAP.210", "MAP.210 is the active zone")
	var lvl = _main.get("_current_level")
	_check(lvl.origin == Vector3.ZERO, "the mission's own world is at the origin")
	_check(int(_main.get("_mission_hostiles")) > 0,
		"hostiles tracked on the main map (%d)" % int(_main.get("_mission_hostiles")))
	# Only the active zone is drawn and only its robots think.
	var asleep: int = 0
	var awake: int = 0
	for zname in zones:
		var node: Node3D = (zones[zname] as Dictionary)["node"]
		if String(zname) == _active():
			awake += 1 if node.visible else 0
		elif not node.visible:
			asleep += 1
	_check(awake == 1 and asleep == zones.size() - 1,
		"the active zone is the only one drawn (%d asleep)" % asleep)
	var key_before: int = int(_main.get("_mission_key"))
	var left_before: int = int(_main.get("_objectives_left"))
	_check(key_before == 210 and left_before > 0,
		"mission key %d, %d objectives left" % [key_before, left_before])

	# The baked doorway table says where the hatch leads.
	var hatch: Node3D = _portal("Portal_MAP_210_0cabb")
	_check(hatch != null and int(hatch.get("target_map")) == 218
		and int(hatch.get("marker_set")) == 0,
		"the hatch at @0cabb is a portal into MAP.218, marker set 0")

	# A robot of the outdoor world, to be missed later.
	var victim: Node = null
	for e in get_tree().get_nodes_in_group("enemy"):
		if lvl.enemies != null and lvl.enemies.is_ancestor_of(e):
			victim = e
			break
	var victim_off: int = int(victim.get_meta("marker_off")) \
		if victim != null and victim.has_meta("marker_off") else -1
	if victim != null:
		victim.call("take_damage", 1.0e6)
	for f in 5:
		await get_tree().physics_frame
	_check(victim_off >= 0, "a robot of MAP.210 was killed (marker @%05x)" % victim_off)

	# --- 2. The hatch: MAP.210 → zone MAP.218 -------------------------
	var music_210: String = Audio.music_name()
	var hp_before: float = float(player.get("health"))
	var t0: int = Time.get_ticks_msec()
	ok = await _go(218, 0, "218")
	_check(ok, "the hatch moves the player into MAP.218 (%d ms)" % (Time.get_ticks_msec() - t0))
	if not ok:
		return _finish()
	lvl = _main.get("_current_level")
	_check(_main.get("_mission") != null and String(_main.get("_active_zone")) == "MAP.218",
		"still inside the mission scene, zone MAP.218 active")
	_check(lvl.origin == Vector3(81920.0, 0.0, 0.0),
		"zone MAP.218 stands at %s" % str(lvl.origin))
	var gap: float = _marker_gap(0)
	_check(gap < 700.0, "the player lands on MAP.218's marker set 0 (d=%.0f)" % gap)
	if hatch != null:
		var tp: Vector3 = hatch.get("target_pos")
		_check(tp.is_finite() and player.global_position.distance_to(tp) < 700.0,
			"the landing matches the baked portal target %s" % str(tp))
	_check(is_equal_approx(float(player.get("health")), hp_before),
		"health carries through the doorway")
	_check(int(_main.get("_mission_key")) == key_before
		and int(_main.get("_objectives_left")) == left_before,
		"the mission key and the objective counter are unchanged")
	_check(String(_main.get("_prev_map_name")) == "MAP.210", "the return register is MAP.210")
	# MAP.210 is maptype 0, MAP.218 maptype 3 — the score changes.
	var music_218: String = Audio.music_name()
	_check(music_218 != music_210, "the score changes with the maptype (%s → %s)"
		% [music_210, music_218])
	# The floor holds: three seconds of physics and the player is still on it.
	var y0: float = player.global_position.y
	for f in 180:
		await get_tree().physics_frame
	_check(absf(player.global_position.y - y0) < 200.0,
		"the player stays on MAP.218's floor (dy=%.0f)" % (player.global_position.y - y0))

	# --- 2b. A save taken inside the scene reads back as the DOS session
	# it stands for: the active zone is the map, the player is stored in
	# that zone's own coordinates, and every built zone keeps its overlay.
	var pos_218: Vector3 = player.global_position
	_check(bool(_main.call("save_to_slot", SAVE_SLOT)), "the game saves from inside a zone")
	var slot: Dictionary = SaveGame.read(SAVE_SLOT)
	_check(String(slot.get("map", "")) == "MAP.218", "the save names the active zone as the map")
	var saved_pos: Vector3 = (slot.get("player", {}) as Dictionary).get("pos", Vector3.INF)
	_check(saved_pos.is_finite() and saved_pos.x < 20000.0,
		"the player is stored in the zone's own coordinates (x=%.0f)" % saved_pos.x)
	_check((slot.get("map_state", {}) as Dictionary).has("MAP.210"),
		"the overlay of the zone left behind is in the save")

	# --- 3. The return exit: back out at MAP.210's marker 27 ----------
	ok = await _go(0, 27, "210")
	_check(ok, "the return exit (@02fc0, set 27) brings the player back to MAP.210")
	if not ok:
		return _finish()
	gap = _marker_gap(27)
	_check(gap < 700.0, "the player lands on MAP.210's marker set 27 (d=%.0f)" % gap)
	var back: bool = false
	for e in get_tree().get_nodes_in_group("enemy"):
		if e.has_meta("marker_off") and int(e.get_meta("marker_off")) == victim_off:
			back = true
	_check(not back, "the robot killed in MAP.210 is still dead after the round trip")
	_check(Audio.music_name() == music_210, "the score comes back with the maptype")
	_check(int(_main.get("_mission_key")) == key_before
		and int(_main.get("_objectives_left")) == left_before,
		"the mission survives the round trip unchanged")

	# --- 3b. …and loading it puts the mission back together ------------
	_main.call("load_from_slot", SAVE_SLOT)
	ok = await _wait(func() -> bool: return _level_is("218") and _settled(), 240.0)
	_check(ok, "the save loads back into zone MAP.218")
	if ok:
		_check(_main.get("_mission") != null and String(_main.get("_active_zone")) == "MAP.218",
			"the mission scene came back up with MAP.218 active")
		_check(player.global_position.distance_to(pos_218) < 300.0,
			"the player is back where the save left them (d=%.0f)"
			% player.global_position.distance_to(pos_218))
		_check(int(_main.get("_mission_key")) == key_before
			and int(_main.get("_objectives_left")) == left_before,
			"the loaded mission keeps its key and counter")
		ok = await _go(0, 27, "210")
		_check(ok, "the loaded return register still leads to MAP.210")
		var risen: bool = false
		for e in get_tree().get_nodes_in_group("enemy"):
			if e.has_meta("marker_off") and int(e.get_meta("marker_off")) == victim_off:
				risen = true
		_check(not risen, "the save carried the dead robot of the zone left behind")

	# --- 4. MAP.214 ↔ MAP.215 -----------------------------------------
	ok = await _go(214, 0, "214")
	_check(ok, "MAP.210 → zone MAP.214")
	if ok:
		var music_214: String = Audio.music_name()
		_check(_marker_gap(0) < 700.0, "the player lands on MAP.214's marker set 0")
		ok = await _go(215, 0, "215")
		_check(ok, "MAP.214 → zone MAP.215")
		if ok:
			_check(_marker_gap(0) < 700.0, "the player lands on MAP.215's marker set 0")
			_check((_main.get("_current_level").origin as Vector3) == Vector3(192512.0, 0.0, 0.0),
				"zone MAP.215 stands on its own slot")
			ok = await _go(214, 10, "214")
			_check(ok, "MAP.215 → MAP.214 at marker set 10")
			_check(_marker_gap(10) < 700.0, "the player lands on MAP.214's marker set 10")
		# MAP.212 has MAP.214's maptype (1): the score must NOT restart.
		var song_before: String = Audio.music_name()
		ok = await _go(212, 0, "212")
		_check(ok, "MAP.214 → zone MAP.212")
		_check(Audio.music_name() == song_before and song_before == music_214,
			"the score plays on across a doorway inside one maptype (%s)" % song_before)
		# Target 0 goes back the way we came in — MAP.214, marker set 10.
		ok = await _go(0, 10, "214")
		_check(ok, "the return register brings MAP.212 back to MAP.214")

	# --- 5. A doorway taken with the USE key, through the records -----
	ok = await _go(210, 27, "210")
	_check(ok, "back on MAP.210 for the use-key run")
	if ok:
		# The cargo box of the transport: the DOS gate is at eye height
		# behind the boarded door (playtest 2026-09-15). Placed exactly as
		# the console's `tp` places it, which is the run this reproduces.
		player.set_spawn(Vector3(49362.0, 730.0, -54978.0), deg_to_rad(160.0), false)
		player.set_view(deg_to_rad(160.0), 0.0)
		for f in 60:
			await get_tree().physics_frame
		_main.call("_on_use_pressed", player.global_position)
		ok = await _wait(func() -> bool: return _level_is("212") and _settled(), 180.0)
		_check(ok, "the use key at the transport takes the player into MAP.212")
		_check(_main.get("_mission") != null, "the use-key doorway stayed inside the scene")

	# --- 6. The exit into MAP.216, a PHASE variant --------------------
	# MAP.216 is MAP.210 re-authored, not a zone: the mission leaves the
	# scene here and the per-map runtime carries it (step 5 keeps the
	# world instead).
	if _level_is("212"):
		_main.call("_on_use_pressed", player.global_position)
		ok = await _wait(func() -> bool: return _level_is("216") and _settled(), 240.0)
		_check(ok, "the exit into the phase variant MAP.216 still works")
		_check(_main.get("_mission") == null,
			"the mission scene is down — MAP.216 plays on the per-map runtime")
		_check(int(_main.get("_mission_key")) == key_before,
			"the mission key survives the hand-over")
		_check(_main.get("_game_over") == null, "no end screen fired by itself")
	_finish()

func _active() -> String:
	return String(_main.get("_active_zone"))

func _portal(pname: String) -> Node3D:
	var m: Node = _main.get("_mission")
	if m == null:
		return null
	return m.get_node_or_null("Portals/" + pname) as Node3D

func _finish() -> void:
	SaveGame.delete(SAVE_SLOT)
	print("[mission-e2e] %s (%d failures)" % ["ALL PASS" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)
