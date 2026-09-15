## Headless end-to-end test of the MISSION-SCENE runtime (steps 4 and 5 of
## docs/m2_mission_scene_plan.md) on the real game scene.
##
## It is a scene of its own rather than a section of game_smoke_test.gd
## because the runtime is chosen when the first level starts: the flag has
## to be up before Main boots, and the other suite must keep proving that
## the per-map runtime is untouched with the flag DOWN.
##
## What it walks: mission 1 comes up inside MISSION.210.scn, the hatch into
## MAP.218 and the return exit back out, MAP.214 ↔ MAP.215, a doorway taken
## with the use key through the action system, and then the PHASES — the
## exit into MAP.216 re-authors the world where it stands instead of
## loading it, the mission carries on into MAP.217 and the jeep counts its
## objective there — and finally mission 3's two phase edges.
##
##   godot --headless --path . res://scenes/mission_smoke_test.tscn

extends Node

const MainScene := preload("res://scenes/main.tscn")
const SaveGame := preload("res://scripts/save_game.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")

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

## The record of the first variant-1 entity named `mesh` in the level that
## is up (the jeep, a gate leaf), or null.
func _record_named(mesh: String):
	var lvl = _main.get("_current_level")
	if lvl == null or lvl.map == null:
		return null
	for e in lvl.map.entities:
		if (e.flags & 3) == 1 and MapFile.entity_name(lvl.map, e) == mesh:
			return e
	return null

## Is a robot / a pickup at `off` (an offset in the map that is up) still
## in the world?
func _enemy_alive(off: int) -> bool:
	for e in get_tree().get_nodes_in_group("enemy"):
		if e.has_meta("marker_off") and int(e.get_meta("marker_off")) == off:
			return true
	return false

func _pickup_there(off: int) -> bool:
	for s in get_tree().get_nodes_in_group("pickup"):
		if s.has_meta("pickup_off") and int(s.get_meta("pickup_off")) == off:
			return true
	return false

## What the player does to the world before it is re-authored, chosen
## among the things the NEXT variant (`next_name`) has in the same place —
## a variant repopulates most of its world (MAP.216 re-authors every robot
## and nearly every item of MAP.210), so only a shared object can be asked
## about afterwards. On the level that is up:
##   robot  one killed
##   item   one taken, by standing on it as the game takes one
##   dent   one damageable object that behaves alike on both maps, hit
##          once through the action system (its hit points must carry)
## Returns {robot, item, dent: identity key or "", hp: what the dent left}.
func _spoil_shared(next_name: String) -> Dictionary:
	var out: Dictionary = {"robot": "", "item": "", "dent": "", "hp": 0.0}
	var lvl = _main.get("_current_level")
	var other = _main.call("_parse_map", next_name)
	if lvl == null or lvl.map == null or other == null:
		return out
	var keys: Dictionary = {}
	for e in other.entities:
		keys[String(_main.call("_entity_key", other, e))] = e
	var player: CharacterBody3D = _main.get("player")
	# A robot.
	for n in get_tree().get_nodes_in_group("enemy"):
		if lvl.enemies == null or not lvl.enemies.is_ancestor_of(n) or not n.has_meta("marker_off"):
			continue
		var rec = lvl.map.entities_by_off.get(int(n.get_meta("marker_off")))
		if rec == null or rec.marker_type != 2:
			continue
		var k: String = String(_main.call("_entity_key", lvl.map, rec))
		if keys.has(k):
			n.call("take_damage", 1.0e6)
			out["robot"] = k
			break
	# An item.
	for n in get_tree().get_nodes_in_group("pickup"):
		if lvl.sprites == null or not lvl.sprites.is_ancestor_of(n) or not n.has_meta("pickup_off"):
			continue
		var rec = lvl.map.entities_by_off.get(int(n.get_meta("pickup_off")))
		if rec == null:
			continue
		var k: String = String(_main.call("_entity_key", lvl.map, rec))
		if not keys.has(k):
			continue
		player.set("noclip", true)
		player.velocity = Vector3.ZERO
		player.global_position = (n as Node3D).global_position + Vector3(0.0, 20.0, 0.0)
		for f in 12:
			await get_tree().physics_frame
		player.set("noclip", false)
		if not is_instance_valid(n):
			out["item"] = k
		else:
			print("[mission-e2e] note: the item %s would not be picked up" % k)
		break
	# A dent: plain hit points (no chain on hit, no damage stages), the
	# same act, state and chain on the next variant.
	if lvl.action != null:
		var st: Dictionary = lvl.action.save_state()
		var hp: Dictionary = st.get("hp", {})
		for off in hp:
			var e = lvl.map.entities_by_off.get(int(off))
			if e == null or (e.flags & 3) != 1 or (e.state_byte & 6) != 0 \
					or (st.get("destr", {}) as Dictionary).has(off) or float(hp[off]) <= 40.0:
				continue
			var k: String = String(_main.call("_entity_key", lvl.map, e))
			if not keys.has(k) or not bool(_main.call("_same_behaviour", lvl.map, e, other, keys[k])):
				continue
			lvl.action.on_player_hit(int(off), 10.0)
			out["dent"] = k
			out["hp"] = float(lvl.action.save_state()["hp"][off])
			break
	await get_tree().physics_frame
	print("[mission-e2e] shared with %s: robot %s, item %s, dent %s (hp %.0f)"
		% [next_name, out["robot"], out["item"], out["dent"], float(out["hp"])])
	return out

## Did what _spoil_shared did come through into the variant that is up
## now? `what` names the edge for the report. Every kind the edge shares
## must have come through; a kind the edge shares none of is reported.
func _check_carried(spoil: Dictionary, what: String) -> void:
	var lvl = _main.get("_current_level")
	var keys: Dictionary = {}
	for e in lvl.map.entities:
		keys[String(_main.call("_entity_key", lvl.map, e))] = int(e.file_off)
	if String(spoil["robot"]).is_empty():
		print("[mission-e2e] note: %s shares no robot to carry" % what)
	else:
		_check(not _enemy_alive(int(keys.get(spoil["robot"], -1))),
			"%s: the robot killed before is still dead" % what)
	if String(spoil["item"]).is_empty():
		print("[mission-e2e] note: %s shares no item to carry" % what)
	else:
		_check(not _pickup_there(int(keys.get(spoil["item"], -1))),
			"%s: the item taken before is still gone" % what)
	if String(spoil["dent"]).is_empty():
		print("[mission-e2e] note: %s shares no damageable object to carry" % what)
	else:
		var hp: Dictionary = lvl.action.save_state().get("hp", {})
		var off: int = int(keys.get(spoil["dent"], -1))
		# The variant's own record would give it full hit points: a value
		# equal to that would prove nothing.
		var rec = lvl.map.entities_by_off.get(off)
		var own: float = float(rec.hp) if rec != null else -1.0
		_check(hp.has(off) and is_equal_approx(float(hp[off]), float(spoil["hp"]))
			and not is_equal_approx(own, float(spoil["hp"])),
			"%s: the object hit before keeps its hit points (%s, carried %.0f, the map's own %.0f)"
			% [what, str(hp.get(off, "?")), float(spoil["hp"]), own])

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
	# What the player does to the world before the phase switch is asked
	# about afterwards — among what MAP.216 still has in the same place.
	var spoil_216: Dictionary = {}
	if ok:
		spoil_216 = await _spoil_shared("MAP.216")
		_check(not String(spoil_216["dent"]).is_empty(),
			"MAP.210 has a damaged object MAP.216 shares (%s)" % spoil_216["dent"])
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

	# --- 6. The exit into MAP.216: the world is RE-AUTHORED in place ---
	# MAP.216 is MAP.210 later in the mission, not a zone of its own. The
	# doorway out of the cargo box turns the world zone into it (step 5):
	# the player never leaves the scene, and what they did to the world
	# comes with them.
	if _level_is("212"):
		var t_phase: int = Time.get_ticks_msec()
		_main.call("_on_use_pressed", player.global_position)
		ok = await _wait(func() -> bool: return _level_is("216") and _settled(), 240.0)
		_check(ok, "the exit out of MAP.212 re-authors the world as MAP.216 (%d ms)"
			% (Time.get_ticks_msec() - t_phase))
		_check(_main.get("_mission") != null and _active() == "MAP.216",
			"still inside the mission scene, the world zone is MAP.216")
		_check((_main.get("_zones") as Dictionary).size() == 7
			and (_main.get("_zones") as Dictionary).has("MAP.216"),
			"the world is filed under its new map, and no zone was added or lost")
		lvl = _main.get("_current_level")
		_check(lvl != null and (lvl.origin as Vector3) == Vector3.ZERO,
			"the world stands where it stood")
		_check(_marker_gap(12) < 700.0,
			"the player lands on MAP.216's marker set 12 (d=%.0f)" % _marker_gap(12))
		_check(int(_main.get("_mission_key")) == key_before
			and int(_main.get("_objectives_left")) == left_before,
			"the mission key and the objective counter are untouched by the phase")
		# What the census says MAP.216 re-authors.
		var jeep = _record_named("HUMMERTK")
		_check(jeep != null and jeep.link_act_type == 0x1C,
			"the jeep on MAP.216 is still the hint act 1c")
		var gate = _record_named("BIGDOORC")
		_check(gate != null and gate.link_next <= 0,
			"MAP.216's gate chain ends at the door — the two links to the truck are gone")
		# …and what the player did to the world before it was re-authored.
		if not spoil_216.is_empty():
			_check_carried(spoil_216, "MAP.210 → MAP.216")

	# --- 7. Through the hangar to MAP.217 and the jeep -----------------
	# MAP.217 keeps most of MAP.216's robots, so this edge is where a dead
	# robot has to stay dead.
	var spoil_217: Dictionary = {}
	if _level_is("216"):
		spoil_217 = await _spoil_shared("MAP.217")
		_check(not String(spoil_217["robot"]).is_empty(),
			"MAP.216 has a robot MAP.217 shares, and it was killed (%s)" % spoil_217["robot"])
		ok = await _go(214, 0, "214")
		_check(ok, "MAP.216 → zone MAP.214")
		if ok:
			ok = await _go(215, 0, "215")
			_check(ok, "MAP.214 → zone MAP.215")
		if ok:
			var t_phase2: int = Time.get_ticks_msec()
			ok = await _go(217, 18, "217")
			_check(ok, "MAP.215's exit re-authors the world as MAP.217 (%d ms)"
				% (Time.get_ticks_msec() - t_phase2))
	if _level_is("217"):
		_check(_main.get("_mission") != null and _active() == "MAP.217",
			"the world zone is MAP.217, still inside the scene")
		_check(int(_main.get("_objectives_left")) == left_before,
			"the objective counter is still %d" % left_before)
		var jeep217 = _record_named("HUMMERTK")
		_check(jeep217 != null and jeep217.link_act_type == 0x28,
			"the jeep on MAP.217 carries the [M3] objective act 28")
		if not spoil_217.is_empty():
			_check_carried(spoil_217, "MAP.216 → MAP.217")
		if jeep217 != null:
			# The eight 0xEF gates stand round the jeep: walking up to it is
			# what fires the objective in DOS. The use key is pressed there
			# too — the doorway run of the playtest.
			var world = _main.get("_current_level")
			var at := Vector3(float(jeep217.x), -float(jeep217.y), -float(jeep217.z)) \
				+ (world.origin as Vector3)
			player.set("noclip", true)
			player.velocity = Vector3.ZERO
			player.global_position = at
			for f in 30:
				await get_tree().physics_frame
			_main.call("_on_use_pressed", player.global_position)
			for f in 30:
				await get_tree().physics_frame
			player.set("noclip", false)
			_check(int(_main.get("_objectives_left")) == left_before - 1,
				"the jeep counts [M3]: %d objectives left" % int(_main.get("_objectives_left")))
		# A save taken in a phase comes back as that phase.
		if not bool(_main.get("_mission_done")):
			_check(bool(_main.call("save_to_slot", SAVE_SLOT)), "the game saves in phase MAP.217")
			var slot2: Dictionary = SaveGame.read(SAVE_SLOT)
			_check(String(slot2.get("map", "")) == "MAP.217", "the save names MAP.217 as the map")
			_main.call("load_from_slot", SAVE_SLOT)
			ok = await _wait(func() -> bool: return _level_is("217") and _settled(), 240.0)
			_check(ok, "the save loads back into the mission scene in phase MAP.217")
			_check(_main.get("_mission") != null and _active() == "MAP.217",
				"the loaded world zone is MAP.217, not the map it was baked from")
	_check(_main.get("_game_over") == null, "no end screen fired by itself")

	# --- 8. Mission 3's phases: MAP.233 → MAP.235 → MAP.234 ------------
	# Mission 3 walks out of the bunker into two more variants of its own
	# world. Only that the edges apply at all is asked here.
	# (Whatever the last section left running — the fade-in of the load —
	# has to be over, or the console refuses the map change.)
	await _wait(func() -> bool: return not bool(_main.get("_level_busy")) and _settled(), 30.0)
	print("[mission-e2e] map 233 → %s" % str(_main.call("run_command", "map 233")))
	ok = await _wait(func() -> bool: return _level_is("233") and _settled(), 300.0)
	_check(ok, "mission 3 comes up inside its scene with MAP.233 active (%s)"
		% _zone_line())
	if ok and _main.get("_mission") != null:
		ok = await _go(235, 0, "235", 300.0)
		_check(ok and _active() == "MAP.235", "MAP.233's exit re-authors mission 3's world as MAP.235")
		if ok:
			ok = await _go(233, 0, "233", 300.0)
			_check(ok, "back into zone MAP.233")
		if ok:
			ok = await _go(234, 0, "234", 300.0)
			_check(ok and _active() == "MAP.234", "the second edge re-authors the world as MAP.234")
		_check(_main.get("_game_over") == null, "mission 3's phases fired no end screen")
	_finish()

func _active() -> String:
	return String(_main.get("_active_zone"))

## The console's own `zone` line, for a report.
func _zone_line() -> String:
	return String(_main.call("_zone_report", false))

func _portal(pname: String) -> Node3D:
	var m: Node = _main.get("_mission")
	if m == null:
		return null
	return m.get_node_or_null("Portals/" + pname) as Node3D

func _finish() -> void:
	SaveGame.delete(SAVE_SLOT)
	print("[mission-e2e] %s (%d failures)" % ["ALL PASS" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)
