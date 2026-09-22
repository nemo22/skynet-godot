## Headless end-to-end test of the MISSION-SCENE runtime (steps 4, 5 and 6
## of docs/m2_mission_scene_plan.md) on the real game scene.
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
## Then mission 1 is FINISHED where it is played (step 7): the two
## objectives inside MAP.215 take the counter to zero without the scene
## being left, and MISSION COMPLETE comes up with mission 2 behind it. And
## mission 5 — the one mission that does not begin on its own world — comes
## up as its own scene, with the hangar it shares with mission 4 still in it.
##
## And the SAVES (step 6): a mission save from inside an interior with its
## state, loaded back after walking out (the zones not walked into wait
## for their overlay, the return door still knows the way); one taken in
## phase MAP.217 comes back as that phase with what the phases carried; the
## same session as a v0.3 per-map save plays inside the scene, and the
## mission save plays in the per-map runtime with the flag down.
##
## Last (step 8, the flag is the DEFAULT now): everything the mission
## scenes do not cover still finds the per-map runtime on its own —
## Future Shock, a network game, `--no-mission-scene`, and a loose map no
## mission holds.
##
##   godot --headless --path . res://scenes/mission_smoke_test.tscn

extends Node

const MainScene := preload("res://scenes/main.tscn")
const SaveGame := preload("res://scripts/save_game.gd")
const MapFile := preload("res://scripts/loaders/map_file.gd")
const Rules := preload("res://scripts/triggers/rules_skynet.gd")

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

## The LIVE act byte of a record of the level that is up — the trigger
## runtime's, since the records stopped carrying play's changes (step 5a).
func _act_of(e) -> int:
	var lvl = _main.get("_current_level")
	if lvl == null or lvl.behaviour == null or e == null:
		return -1
	return lvl.triggers.act(e.file_off)

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

## The same two questions about the level that is up ONLY — the zones
## asleep beside it keep their robots and pickups in the same groups, and
## file offsets of two maps can coincide.
func _enemy_alive_here(off: int) -> bool:
	var lvl = _main.get("_current_level")
	if lvl == null or lvl.enemies == null:
		return false
	for e in get_tree().get_nodes_in_group("enemy"):
		if lvl.enemies.is_ancestor_of(e) and e.has_meta("marker_off") \
				and int(e.get_meta("marker_off")) == off \
				and not (e.has_method("is_dead") and e.call("is_dead")):
			return true
	return false

func _pickup_here(off: int) -> bool:
	var lvl = _main.get("_current_level")
	if lvl == null or lvl.sprites == null:
		return false
	for s in get_tree().get_nodes_in_group("pickup"):
		if lvl.sprites.is_ancestor_of(s) and s.has_meta("pickup_off") \
				and int(s.get_meta("pickup_off")) == off:
			return true
	return false

## Load `slot` (or `data`, a slot already read) and wait until `sfx` is up
## from THAT load: a new level object, the saved player applied and the
## fade over. A load into the map already up used to pass at once, before
## the load had even started.
func _load(slot: int, sfx: String, data: Dictionary = {}) -> bool:
	await _wait(func() -> bool: return not bool(_main.get("_level_busy")) and _settled(), 30.0)
	var before = _main.get("_current_level")
	var old_id: int = (before as Object).get_instance_id() if before != null else 0
	if data.is_empty():
		_main.call("load_from_slot", slot)
	else:
		_main.call("load_from_slot", slot, data)
	return await _wait(func() -> bool:
		var cur = _main.get("_current_level")
		return cur != null and (cur as Object).get_instance_id() != old_id and _level_is(sfx) \
			and _settled() and not bool(_main.get("_level_busy")) \
			and (_main.get("_pending_player") as Dictionary).is_empty(), 240.0)

## The format number on a slot file's header line (SKYNET-SAVE <n>|…).
func _header_version(slot: int) -> int:
	var f := FileAccess.open(SaveGame.path(slot), FileAccess.READ)
	if f == null:
		return -1
	var head: String = f.get_line()
	f.close()
	var v: String = head.trim_prefix(SaveGame.MAGIC).strip_edges().get_slice("|", 0)
	return int(v) if v.is_valid_int() else -1

## Is the zone filed under `zname` built?
func _built(zname: String) -> bool:
	var z: Dictionary = (_main.get("_zones") as Dictionary).get(zname, {})
	return not z.is_empty() and z.get("level") != null

## What the level that is up gets done to it before a save: one robot
## killed and one item taken — collected the way the pickup collects itself
## when the player reaches it, without walking him across the map's
## doorways to get there. Returns {robot: marker offset or -1, item: pickup
## offset or -1}.
func _spoil_here() -> Dictionary:
	var out: Dictionary = {"robot": -1, "item": -1}
	var lvl = _main.get("_current_level")
	var player: CharacterBody3D = _main.get("player")
	if lvl == null:
		return out
	for n in get_tree().get_nodes_in_group("enemy"):
		if lvl.enemies == null or not lvl.enemies.is_ancestor_of(n) or not n.has_meta("marker_off") \
				or bool(n.get("indestructible")):
			continue
		n.call("take_damage", 1.0e6)
		if bool(n.call("is_dead")):
			out["robot"] = int(n.get_meta("marker_off"))
			break
	for n in get_tree().get_nodes_in_group("pickup"):
		if lvl.sprites != null and lvl.sprites.is_ancestor_of(n) and n.has_meta("pickup_off"):
			out["item"] = int(n.get_meta("pickup_off"))
			n.call("collect", player)
			break
	for f in 10:
		await get_tree().physics_frame
	return out

## What the player does to the world before it is re-authored, chosen
## among the things the NEXT variant (`next_name`) has in the same place —
## a variant repopulates most of its world (MAP.216 re-authors every robot
## and nearly every item of MAP.210), so only a shared object can be asked
## about afterwards. On the level that is up:
##   robot  one killed
##   item   one taken, by standing on it as the game takes one
##   dent   one damageable object with the same SIGNATURE on both maps
##          (main._same_signature, the rule the carry itself applies since
##          step 5i), hit once through its node — its hit points must carry
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
	if lvl.behaviour != null:
		var st: Dictionary = lvl.triggers.snapshot()
		var hp: Dictionary = st.get("hp", {})
		for off in hp:
			var e = lvl.map.entities_by_off.get(int(off))
			if e == null or (e.flags & 3) != 1 or (e.state_byte & 6) != 0 \
					or (st.get("destr", {}) as Dictionary).has(off) or float(hp[off]) <= 40.0:
				continue
			var k: String = String(_main.call("_entity_key", lvl.map, e))
			if not keys.has(k) or not bool(_main.call("_same_signature", lvl.map, e, other, keys[k])):
				continue
			lvl.behaviour.obj_hit(int(off), 10.0)
			out["dent"] = k
			out["hp"] = float(lvl.triggers.snapshot()["hp"][off])
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
		var hp: Dictionary = lvl.triggers.snapshot().get("hp", {})
		var off: int = int(keys.get(spoil["dent"], -1))
		# The variant's own record would give it full hit points: a value
		# equal to that would prove nothing.
		var rec = lvl.map.entities_by_off.get(off)
		var own: float = float(rec.hp) if rec != null else -1.0
		_check(hp.has(off) and is_equal_approx(float(hp[off]), float(spoil["hp"]))
			and not is_equal_approx(own, float(spoil["hp"])),
			"%s: the object hit before keeps its hit points (%s, carried %.0f, the map's own %.0f)"
			% [what, str(hp.get(off, "?")), float(spoil["hp"]), own])

## Step 0 of the trigger-graph plan, one half: MAP.210's jeep is the hint
## [G1] where MAP.217's is the objective [M3], on the same entity in the
## same place. Fire the hint here — the eight 0xEF gates round the jeep
## answer the use key together, as they do in play — so the phase edges
## that follow have a RETIRED cue (act 0xFF) to carry, which is what used
## to land on MAP.217's objective and cost the mission its ending.
func _fire_jeep_hint() -> void:
	var lvl = _main.get("_current_level")
	var jeep = _record_named("HUMMERTK")
	if lvl == null or lvl.behaviour == null or jeep == null:
		print("[mission-e2e] note: MAP.210's jeep is not here to fire")
		return
	var left: int = int(_main.get("_objectives_left"))
	_check(lvl.triggers.act(jeep.file_off) == 0x1C,
		"MAP.210's jeep is the hint [G1] (act %02x)" % lvl.triggers.act(jeep.file_off))
	var at := Vector3(float(jeep.x), -float(jeep.y), -float(jeep.z)) + (lvl.origin as Vector3)
	lvl.behaviour.press_use()
	lvl.behaviour.tick(0.016, at, at)
	await get_tree().physics_frame
	_check(lvl.triggers.act(jeep.file_off) == 0xFF and int(_main.get("_objectives_left")) == left,
		"the gates fire it: retired on MAP.210, and the objective counter has not moved (%d)" % left)

## Step 0's other half, asked of the code rather than of the world: the
## records a phase switch carries FROM are the map's own, as the file has
## them. Play no longer writes into a level's records at all (step 5a puts
## the retired acts, the swapped water valves, the cut path links and the
## flipped bits in the trigger runtime), but the carry must still re-read
## the MAP rather than hand over whatever copy it is given — so a copy is
## spoiled here by hand and the source asked for.
func _check_phase_source_map() -> void:
	var live = _main.call("_parse_map", "MAP.210")
	if live == null:
		print("[mission-e2e] note: MAP.210 cannot be read — the carry source check is skipped")
		return
	var jeep_off: int = -1
	for e in live.entities:
		if (e.flags & 3) == 1 and MapFile.entity_name(live, e) == "HUMMERTK":
			jeep_off = e.file_off
			break
	if jeep_off < 0:
		print("[mission-e2e] note: MAP.210 has no jeep record to check")
		return
	# Spoil the copy the way play spoils a level's records…
	live.entities_by_off[jeep_off].link_act_type = 0xFF
	live.entities_by_off[jeep_off].state_byte |= 1
	# …and ask for the source a phase switch would carry from.
	var src = _main.call("_phase_source_map", "MAP.210", null)
	var rec = src.entities_by_off.get(jeep_off) if src != null else null
	_check(rec != null and int(rec.link_act_type) == 0x1C and (int(rec.state_byte) & 1) == 0,
		"a phase carries MAP.210's records as the MAP file has them, not as play left them")

## Which maps may carry into which is a COMMITTED list since step 5i
## (Rules.VARIANTS), not a search for whatever visited map looked alike:
## the two worlds the shipped data holds twice over are mission 1's base
## and mission 3's bunker plateau, and both are what the mission census
## says. The pair that keeps the list honest is MAP.240 / MAP.250 — the
## harbour of mission 4 and the harbour of mission 5 share 93 % of their
## meshes at the same coordinates and are NOT one world; the old search
## missed them only because the two sit in different decades.
func _check_variant_table() -> void:
	var t: Dictionary = Rules.VARIANTS
	_check(int(t.get(216, 0)) == 210 and int(t.get(217, 0)) == 210
		and int(t.get(234, 0)) == 230 and int(t.get(235, 0)) == 230 and t.size() == 4,
		"the committed variant list is mission 1's 216/217 and mission 3's 234/235 (%s)" % str(t))
	_check(bool(_main.call("_same_world", "MAP.210", "MAP.216"))
		and bool(_main.call("_same_world", "MAP.216", "MAP.217"))
		and bool(_main.call("_same_world", "MAP.230", "MAP.235")),
		"a phase edge is a carry: the world and its phases are one")
	_check(not bool(_main.call("_same_world", "MAP.240", "MAP.250"))
		and not bool(_main.call("_same_world", "MAP.210", "MAP.220"))
		and not bool(_main.call("_same_world", "MAP.217", "MAP.217")),
		"and two missions' harbours, two missions' bases and a map with itself are not")

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# THE DEFAULT is what this suite plays (step 8): Settings.mission_scenes
	# ships on, and nothing on the command line turns it on here. The live
	# value is only put back where the shipped default has it in case a
	# settings.cfg on this machine says otherwise — a run must not depend on
	# whoever last played, and a test must never WRITE that file. The runtime
	# is picked when the first level starts, so this happens before Main is
	# built.
	var fresh: Node = load("res://scripts/settings.gd").new()
	_check(bool(fresh.mission_scenes), "mission scenes are the shipped default")
	fresh.free()
	if not Settings.mission_scenes:
		print("[mission-e2e] note: this machine's settings.cfg chose mission scenes off — the run uses the default")
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
	_check_phase_source_map()
	_check_variant_table()

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

	# --- 2b. A save taken inside the scene is a MISSION save (the newest
	# format): the mission, the active zone (also the map, for the header and
	# the per-map runtime), the player in that zone's own coordinates, the
	# return register, and the overlay of every zone built so far.
	var pos_218: Vector3 = player.global_position
	_check(bool(_main.call("save_to_slot", SAVE_SLOT)), "the game saves from inside a zone")
	var slot: Dictionary = SaveGame.read(SAVE_SLOT)
	_check(_header_version(SAVE_SLOT) == SaveGame.VERSION and SaveGame.VERSION == 5,
		"a mission scene writes save format %d" % _header_version(SAVE_SLOT))
	_check(SaveGame.info(SAVE_SLOT).begins_with("MAP.218 · "),
		"the LOAD menu still reads the map the player is in (%s)" % SaveGame.info(SAVE_SLOT))
	_check(String(slot.get("map", "")) == "MAP.218" and String(slot.get("zone", "")) == "MAP.218"
		and int(slot.get("mission", -1)) == 210,
		"the save names mission %s, zone %s" % [str(slot.get("mission")), str(slot.get("zone"))])
	var saved_pos: Vector3 = (slot.get("player", {}) as Dictionary).get("pos", Vector3.INF)
	_check(saved_pos.is_finite() and saved_pos.x < 20000.0,
		"the player is stored in the zone's own coordinates (x=%.0f)" % saved_pos.x)
	var szones: Dictionary = slot.get("zones", {})
	_check(not slot.has("map_state") and szones.has("MAP.210") and szones.has("MAP.218")
		and szones.size() == 2,
		"the save holds the overlay of the two zones built so far (%s)" % str(szones.keys()))
	_check(((szones.get("MAP.210", {}) as Dictionary).get("dead", {}) as Dictionary).has(victim_off),
		"the zone left behind keeps its dead robot in the save")
	_check(String(slot.get("return_zone", "")) == "MAP.210", "the save keeps the return register")
	_check((slot.get("phases", {}) as Dictionary).get("MAP.210", "") == "MAP.210",
		"the save names the world's phase (%s)" % str(slot.get("phases")))

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
	ok = await _load(SAVE_SLOT, "218")
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
		_check(not _built("MAP.210") and (_main.get("_zone_state") as Dictionary).has("MAP.210")
			and not (_main.get("_map_state") as Dictionary).has("MAP.210"),
			"the world is not built yet, its overlay waits in the scene")
		ok = await _go(0, 27, "210")
		_check(ok, "the loaded return register still leads to MAP.210")
		_check(not (_main.get("_zone_state") as Dictionary).has("MAP.210"),
			"walking in built the world with its overlay")
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
			if ok:
				await _interior_save_load(victim_off, left_before)
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
		_check(not _enemy_alive_here(victim_off),
			"the world's robot is still dead: its overlay waited through the load until walked into")
	# What the player does to the world before the phase switch is asked
	# about afterwards — among what MAP.216 still has in the same place.
	var spoil_216: Dictionary = {}
	if ok:
		spoil_216 = await _spoil_shared("MAP.216")
		_check(not String(spoil_216["dent"]).is_empty(),
			"MAP.210 has a damaged object MAP.216 shares (%s)" % spoil_216["dent"])
		await _fire_jeep_hint()
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
		_check(jeep != null and _act_of(jeep) == 0x1C,
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
		_check(jeep217 != null and _act_of(jeep217) == 0x28,
			"the jeep on MAP.217 carries the [M3] objective act 28")
		# Step 0: the hint fired two phases back on MAP.210 retired THAT
		# map's copy of this entity. Nothing of it may stand here.
		var cue217: Node = _main.get("_current_level").behaviour.node(jeep217.file_off) \
			if jeep217 != null and _main.get("_current_level").behaviour != null else null
		_check(cue217 != null and not bool(cue217.get("spent")),
			"MAP.217's jeep arrives live: MAP.210's retired hint did not cross the phases")
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
			await _phase_save_load(spoil_217, left_before)
	_check(_main.get("_game_over") == null, "no end screen fired by itself")

	# --- 7e. The END of mission 1, inside the scene --------------------
	# [M3] is the jeep out in the world; [M1] and [M2] are inside MAP.215,
	# two doorways off it. Until now no run had driven those two in a scene,
	# so nothing proved a mission can be FINISHED without leaving one — the
	# counter reaching zero, MISSION COMPLETE, and the next mission behind it.
	await _finish_mission_1(left_before)

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

	# --- 9. Mission 4: a zone's water where a chain moved it ------------
	# The harbour MAP.240 has a water marker, its warehouse MAP.242 none. The
	# surface hangs under Main and belongs to the active zone, so the zone
	# being left has to keep where it had got to — across a doorway, in a
	# save taken elsewhere, and through the load of that save.
	await _wait(func() -> bool: return not bool(_main.get("_level_busy")) and _settled(), 30.0)
	print("[mission-e2e] map 240 → %s" % str(_main.call("run_command", "map 240")))
	ok = await _wait(func() -> bool: return _level_is("240") and _settled(), 300.0)
	_check(ok and _main.get("_mission") != null and _active() == "MAP.240",
		"mission 4 comes up inside its scene with MAP.240 active")
	if ok and _main.get("_mission") != null:
		var wt: float = float(_main.get("_water_target"))
		_check(wt != INF, "MAP.240 has its water surface (y=%s)" % str(wt))
		if wt != INF:
			var drained: float = wt - 160.0
			_main.call("_on_water_level", -160.0, false)     # a chain lets 160 units out
			for f in 10:
				await get_tree().physics_frame
			ok = await _go(242, 0, "242")
			_check(ok and float(_main.get("_water_target")) == INF, "MAP.242 is dry")
			if ok:
				_check(bool(_main.call("save_to_slot", SAVE_SLOT)), "the game saves in MAP.242")
				var wdata: Dictionary = SaveGame.read(SAVE_SLOT)
				var w240: Dictionary = (wdata.get("zones", {}) as Dictionary).get("MAP.240", {})
				_check(is_equal_approx(float(w240.get("water", INF)), drained),
					"the save keeps the sleeping harbour's water at %.0f (%s)" % [drained, str(w240.get("water"))])
				ok = await _go(0, 0, "240")
				_check(ok and is_equal_approx(float(_main.get("_water_target")), drained),
					"back in MAP.240 the water is where the chain moved it (%.0f)" % float(_main.get("_water_target")))
				ok = await _load(SAVE_SLOT, "242")
				_check(ok and _active() == "MAP.242", "the save loads back into MAP.242")
				if ok:
					ok = await _go(0, 0, "240")
					_check(ok and is_equal_approx(float(_main.get("_water_target")), drained),
						"after the load the harbour comes up with the saved water (%.0f)"
						% float(_main.get("_water_target")))

	# --- 10. Mission 5: the mission that does not start on its own world --
	# DOS numbers mission 5 by its maps — the 25x decade, briefing 250.TXT —
	# but it BEGINS in the sub pens of MAP.252, and the harbour MAP.250 is
	# two doorways further on. The scene is filed under the map the mission
	# starts on (Assets.mission_start_of): asking for MISSION.250.scn instead
	# baked a stray scene of a mission that begins nowhere, MAP.252 was no
	# zone of it, and every mission-5 map quietly fell back to the per-map
	# runtime.
	await _wait(func() -> bool: return not bool(_main.get("_level_busy")) and _settled(), 30.0)
	print("[mission-e2e] map 252 → %s" % str(_main.call("run_command", "map 252")))
	ok = await _wait(func() -> bool: return _level_is("252") and _settled(), 300.0)
	_check(ok and _main.get("_mission") != null and _active() == "MAP.252",
		"mission 5 comes up inside its own scene with MAP.252 active (%s)" % _zone_line())
	if ok and _main.get("_mission") != null:
		_check(int(_main.get("_mission_scene_key")) == 250,
			"the scene is mission 250's — the number its briefing and counter use (%d)"
			% int(_main.get("_mission_scene_key")))
		var m5: Dictionary = _main.get("_zones")
		_check(m5.size() == 17, "mission 5 stands on %d zones" % m5.size())
		var world: Dictionary = m5.get("MAP.250", {})
		_check(not world.is_empty() and (world["node"] as Node3D).position == Vector3.ZERO,
			"the harbour MAP.250 is the mission's world, at the origin")
		_check(int(_main.get("_mission_key")) == 250 and int(_main.get("_objectives_left")) > 0,
			"the mission key is 250 with %d objectives" % int(_main.get("_objectives_left")))
		# MAP.247 is a hangar of mission 4 as much as of mission 5: its own
		# number would hand the mission — and its objective counter — to
		# mission 4 at the door. The scene it stands in settles it.
		ok = await _go(247, 0, "247")
		_check(ok and _main.get("_mission") != null and _active() == "MAP.247"
			and int(_main.get("_mission_key")) == 250,
			"the shared hangar MAP.247 stays in mission 5 (key %d, zone %s)"
			% [int(_main.get("_mission_key")), _active()])
		if ok:
			ok = await _go(250, 0, "250", 300.0)
			_check(ok and _active() == "MAP.250",
				"and the way back leads into the harbour zone (%s)" % _zone_line())

	# --- 11. What still takes the PER-MAP runtime (step 8) --------------
	# The flag is the default now, so everything the mission scenes do not
	# cover has to find the old runtime by itself. Last in the suite: the
	# loose map below hands its mission over for good (_mission_scene_off).
	await _fallback_checks()
	_finish()

## The automatic fallbacks, with the flag UP. Each is a rule of
## main._mission_scenes_on or main._want_mission_scene; the network game
## itself is net_smoke_test's, and Future Shock's own data is not loaded
## here — the gate it fails is.
func _fallback_checks() -> void:
	_check(bool(Settings.mission_scenes), "the suite played the default (the flag is up)")
	# Future Shock: its campaign is the 01x-19x maps and MissionScene.STARTS
	# is SkyNET's, so it bakes no mission scene and is refused the runtime.
	var was_game: String = SkynetPaths.game
	SkynetPaths.game = "shock"
	var shock_none: bool = Assets.mission_starts().is_empty() \
		and Assets.mission_start_of(210) < 0
	var shock_off: bool = not bool(_main.call("_mission_scenes_on"))
	SkynetPaths.game = was_game
	_check(shock_none, "Future Shock bakes no mission scenes")
	_check(shock_off, "…and is refused the mission-scene runtime")
	_check(bool(_main.call("_mission_scenes_on")), "SkyNET has it back")
	# A network game is one arena for everyone and has no mission at all.
	Net.active = true
	var net_off: bool = not bool(_main.call("_mission_scenes_on"))
	Net.active = false
	_check(net_off, "a network game is refused it whatever the setting says")
	# `--no-mission-scene`: one run put back on the per-map runtime.
	var cli: Dictionary = _main.get("_cli")
	cli["no-mission-scene"] = true
	var cli_off: bool = not bool(_main.call("_mission_scenes_on"))
	cli.erase("no-mission-scene")
	_check(cli_off, "--no-mission-scene turns it off for a run")
	# A loose map: no mission scene is filed for the 60x arenas, and nothing
	# the census walked holds MAP.603.
	_check(Assets.mission_start_of(600) < 0,
		"no mission scene is filed for a loose map's own decade")
	_check(not Assets.mission_holds(250, "MAP.603"),
		"and the mission being played does not hold it either")
	var ok: bool = await _main.call("_change_level", "MAP.603", false, false)
	ok = ok and await _wait(func() -> bool: return _level_is("603") and _settled(), 240.0)
	_check(ok, "MAP.603 loads")
	if ok:
		var lvl = _main.get("_current_level")
		_check(_main.get("_mission") == null and (lvl.origin as Vector3) == Vector3.ZERO,
			"a loose map takes the per-map runtime, at the DOS origin")

## --- Step 7: the mission ends where it is played ------------------------

## Every [M] objective record of the level that is up: act 0x26+n, the
## entities the DOS counter comes down on (0x26 = [M1] … 0x2A = [M5]).
func _objective_records() -> Array:
	var out: Array = []
	var lvl = _main.get("_current_level")
	if lvl == null or lvl.map == null:
		return out
	for e in lvl.map.entities:
		if e.link_act_type >= 0x26 and e.link_act_type <= 0x2A:
			out.append(e)
	return out

## Does the chain `e` starts run through `off`? ObjFlipLink's own walk —
## follow link_next, stop at an actor flag or the end of the chain.
func _chain_reaches(m, e, off: int) -> bool:
	var seen: Dictionary = {}
	var cur = m.entities_by_off.get(e.link_next) if e.link_next > 0 else null
	while cur != null and not seen.has(cur.file_off):
		seen[cur.file_off] = true
		if int(cur.file_off) == off:
			return true
		if (cur.flags & 0x40) != 0 or cur.link_next <= 0:
			break
		cur = m.entities_by_off.get(cur.link_next)
	return false

## What a player touches to count the objective at `off`: an objective act
## is the END of a chain (a gate at the door of the room, a button on the
## wall), never something walked into by itself. Returns the record or null.
func _trigger_for(off: int):
	var lvl = _main.get("_current_level")
	if lvl == null or lvl.map == null:
		return null
	for e in lvl.map.entities:
		if e.link_act_type != 0xEF and e.link_act_type != 0xF1 and e.link_act_type != 0xF2:
			continue
		if _chain_reaches(lvl.map, e, off):
			return e
	return null

## Walk up to a record and press the use key there, which is how a player
## counts an objective: the 0xEF gates that ring it flip on the key, the
## 0xF1/0xF2 ones on the tick that sees the player inside their radius.
func _drive_record(e) -> void:
	var lvl = _main.get("_current_level")
	var player: CharacterBody3D = _main.get("player")
	var at := Vector3(float(e.x), -float(e.y), -float(e.z)) + (lvl.origin as Vector3)
	player.set("noclip", true)
	player.velocity = Vector3.ZERO
	player.global_position = at
	for f in 30:
		await get_tree().physics_frame
	_main.call("_on_use_pressed", player.global_position)
	for f in 30:
		await get_tree().physics_frame
	player.set("noclip", false)

## 7e. Mission 1 to its end without leaving its scene. The run stands in
## MAP.214 on the per-map runtime (7d put it there), the flag is up again
## and [M3] is counted: walking into MAP.215 brings the scene back, and its
## own two objectives take the counter to zero.
func _finish_mission_1(left_before: int) -> void:
	await _wait(func() -> bool: return not bool(_main.get("_level_busy")) and _settled(), 30.0)
	print("[mission-e2e] map 215 → %s" % str(_main.call("run_command", "map 215")))
	var ok: bool = await _wait(func() -> bool: return _level_is("215") and _settled(), 300.0)
	_check(ok and _main.get("_mission") != null and _active() == "MAP.215",
		"mission 1 is back inside its scene with MAP.215 active (%s)" % _zone_line())
	if not ok or _main.get("_mission") == null:
		return
	var left: int = int(_main.get("_objectives_left"))
	_check(left == left_before - 1, "%d objectives left, [M3] still counted" % left)
	var objs: Array = _objective_records()
	_check(objs.size() >= left, "MAP.215 carries %d objective records for the %d left"
		% [objs.size(), left])
	for e in objs:
		if int(_main.get("_objectives_left")) <= 0:
			break
		# The trigger the chain hangs off first — walking onto the objective
		# record itself does nothing, it is the end of the chain.
		var t = _trigger_for(int(e.file_off))
		if t != null:
			await _drive_record(t)
			if _main.get("_current_level") != null:
				_main.get("_current_level").behaviour.on_player_activate(
					int(t.file_off), (_main.get("player") as Node3D).global_position)
				for f in 20:
					await get_tree().physics_frame
		else:
			await _drive_record(e)
		print("[mission-e2e] objective @%05x (act %02x) driven from %s → %d left"
			% [int(e.file_off), int(e.link_act_type),
			   "trigger @%05x (act %02x)" % [int(t.file_off), int(t.link_act_type)] if t != null
				else "the record itself", int(_main.get("_objectives_left"))])
	_check(int(_main.get("_objectives_left")) == 0,
		"MAP.215's objectives take the counter to zero (%d left)" % int(_main.get("_objectives_left")))
	_check(_main.get("_mission") != null and _active() == "MAP.215",
		"the mission was finished INSIDE the scene, in zone %s" % _active())
	# _finish_mission_if_done holds the banner back 2.5 s so the last radio
	# line is read first, then MISSION COMPLETE with the next mission behind it.
	ok = await _wait(func() -> bool: return _main.get("_game_over") != null, 20.0)
	_check(ok, "MISSION COMPLETE shows for mission 1")
	_check(String(_main.get("_game_over_next")) == "MAP.220",
		"the next mission waiting behind it is %s" % str(_main.get("_game_over_next")))
	_check(int(_main.get("_mission_ended_key")) == 210,
		"mission 210 is marked won (%d)" % int(_main.get("_mission_ended_key")))
	# The banner would load MAP.220 by itself after 6 s; the run has more to
	# walk, so it is taken down here (which also stops that timer).
	_main.call("_dismiss_end_screen")
	await _wait(func() -> bool: return _main.get("_game_over") == null, 10.0)

## --- Step 6: saves ------------------------------------------------------
## What _interior_save_load did to MAP.214, for the per-map run of the
## same save at the end.
var _spoil_214: Dictionary = {}

## 4b. Inside MAP.214 (entered back from MAP.215, so the return register
## is MAP.215): a robot killed and an item taken, the game saved, the
## player walks out into the world, the save is loaded. The zone comes back
## as it was saved, the zones not walked into keep their overlays waiting,
## and the return door leads back into MAP.215.
func _interior_save_load(victim_off: int, left_before: int) -> void:
	var player: CharacterBody3D = _main.get("player")
	var spoil: Dictionary = await _spoil_here()
	_spoil_214 = spoil
	_check(int(spoil["robot"]) >= 0 and not _enemy_alive_here(int(spoil["robot"])),
		"a robot of MAP.214 was killed (@%05x)" % int(spoil["robot"]))
	_check(int(spoil["item"]) >= 0, "an item of MAP.214 was taken (@%05x)" % int(spoil["item"]))
	var pos: Vector3 = player.global_position
	var hp: float = float(player.get("health"))
	_check(bool(_main.call("save_to_slot", SAVE_SLOT)), "the game saves inside MAP.214")
	var data: Dictionary = SaveGame.read(SAVE_SLOT)
	var zones: Dictionary = data.get("zones", {})
	var mine: Dictionary = zones.get("MAP.214", {})
	_check(String(data.get("zone", "")) == "MAP.214" and String(data.get("return_zone", "")) == "MAP.215",
		"the save is zone MAP.214 with the return register MAP.215 (%s, %s)"
		% [str(data.get("zone")), str(data.get("return_zone"))])
	_check((mine.get("dead", {}) as Dictionary).has(int(spoil["robot"]))
		and (mine.get("taken", {}) as Dictionary).has(int(spoil["item"])),
		"MAP.214's overlay holds the dead robot and the taken item")
	_check(zones.has("MAP.210") and zones.has("MAP.218") and zones.has("MAP.215")
		and not zones.has("MAP.211") and not zones.has("MAP.212") and not zones.has("MAP.213"),
		"every zone built so far is in the save, the ones never walked into are not (%s)"
		% str(zones.keys()))
	# Out of the interior, and the world changes under the save: one more
	# robot of MAP.210 goes, which the load must bring back.
	var ok: bool = await _go(210, 27, "210")
	_check(ok, "walked out of MAP.214 into the world")
	var extra: int = -1
	var lvl = _main.get("_current_level")
	for e in get_tree().get_nodes_in_group("enemy"):
		if lvl.enemies != null and lvl.enemies.is_ancestor_of(e) and e.has_meta("marker_off") \
				and int(e.get_meta("marker_off")) != victim_off and not bool(e.call("is_dead")) \
				and not bool(e.get("indestructible")):
			e.call("take_damage", 1.0e6)
			if bool(e.call("is_dead")):
				extra = int(e.get_meta("marker_off"))
				break
	_check(extra >= 0 and not _enemy_alive_here(extra),
		"after the save another robot of MAP.210 dies (@%05x)" % extra)
	ok = await _load(SAVE_SLOT, "214")
	_check(ok, "the save loads back into zone MAP.214")
	if not ok:
		return
	_check(_main.get("_mission") != null and _active() == "MAP.214", "the scene is up with MAP.214 active")
	_check(player.global_position.distance_to(pos) < 300.0,
		"the player is back where the save left them (d=%.0f)" % player.global_position.distance_to(pos))
	_check(is_equal_approx(float(player.get("health")), hp), "health comes back from the save")
	_check(not _enemy_alive_here(int(spoil["robot"])) and not _pickup_here(int(spoil["item"])),
		"MAP.214 keeps its dead robot and its taken item")
	_check(String(_main.get("_prev_map_name")) == "MAP.215", "the return register is MAP.215 again")
	_check(int(_main.get("_objectives_left")) == left_before, "the objective counter comes back")
	var waiting: Dictionary = _main.get("_zone_state")
	_check(not _built("MAP.210") and not _built("MAP.215") and waiting.has("MAP.210")
		and waiting.has("MAP.215") and waiting.has("MAP.218"),
		"only MAP.214 is built; the other zones' overlays wait (%s)" % str(waiting.keys()))
	# The return door after the load: back into MAP.215, built now from its
	# waiting overlay.
	ok = await _go(0, 0, "215")
	_check(ok and _active() == "MAP.215" and _marker_gap(0) < 700.0,
		"the return door leads into MAP.215 at its marker set 0 (d=%.0f)" % _marker_gap(0))
	_check(not (_main.get("_zone_state") as Dictionary).has("MAP.215"),
		"MAP.215 took its overlay when it was built")
	ok = await _go(214, 10, "214")
	_check(ok and not _enemy_alive_here(int(spoil["robot"])) and not _pickup_here(int(spoil["item"])),
		"back in MAP.214 the robot is still dead and the item still gone")
	# The world: the robot killed after the save is back, the one before is not.
	ok = await _go(210, 27, "210")
	_check(ok and not _enemy_alive_here(victim_off) and (extra < 0 or _enemy_alive_here(extra)),
		"the world comes up as saved: the robot killed before the save dead, the one after alive (@%05x)"
		% extra)
	ok = await _go(214, 10, "214")
	_check(ok, "back into MAP.214 for the rest of the run")

## 7b. Saved in phase MAP.217 after the phases carried a robot, an item and
## a dent from MAP.210 and MAP.216 and the jeep counted [M3]: the load puts
## the world into MAP.217 before it is built and everything is still there.
## Then the same session as a v0.3 per-map save loaded with the flag up,
## and the mission save loaded with the flag DOWN.
func _phase_save_load(spoil_217: Dictionary, left_before: int) -> void:
	var player: CharacterBody3D = _main.get("player")
	var left: int = int(_main.get("_objectives_left"))
	var pos: Vector3 = player.global_position
	_check(bool(_main.call("save_to_slot", SAVE_SLOT)), "the game saves in phase MAP.217")
	var slot2: Dictionary = SaveGame.read(SAVE_SLOT)
	var zones: Dictionary = slot2.get("zones", {})
	_check(String(slot2.get("map", "")) == "MAP.217", "the save names MAP.217 as the map")
	_check((slot2.get("phases", {}) as Dictionary).get("MAP.210", "") == "MAP.217",
		"the save names the world's phase MAP.217 (%s)" % str(slot2.get("phases")))
	_check(zones.has("MAP.217") and zones.has("MAP.216") and zones.has("MAP.210"),
		"the phases the world left behind keep their overlays in the save (%s)" % str(zones.keys()))
	var ok: bool = await _load(SAVE_SLOT, "217")
	_check(ok, "the save loads back into the mission scene in phase MAP.217")
	if not ok:
		return
	_check(_main.get("_mission") != null and _active() == "MAP.217",
		"the loaded world zone is MAP.217, not the map it was baked from")
	_check(int(_main.get("_objectives_left")) == left and left == left_before - 1,
		"the counted [M3] stays counted (%d left)" % int(_main.get("_objectives_left")))
	if not spoil_217.is_empty():
		_check_carried(spoil_217, "MAP.216 → MAP.217, saved and loaded")
	_check(String(_main.get("_prev_map_name")) == "MAP.215", "the return register is MAP.215")
	var waiting: Dictionary = _main.get("_zone_state")
	_check(waiting.has("MAP.216") and waiting.has("MAP.210"),
		"the phases left behind wait under their own maps (%s)" % str(waiting.keys()))

	# --- 7c. The same session as a v0.3 per-map save, flag up ----------
	# What the per-map runtime writes: the map, the previous-map register and
	# the per-map overlay, no mission, no phases, no mission tags.
	var legacy_state: Dictionary = {}
	for mn in zones:
		var o: Dictionary = (zones[mn] as Dictionary).duplicate()
		o.erase("mission")
		legacy_state[mn] = o
	var legacy: Dictionary = {
		"version": SaveGame.VERSION_MAP,
		"time": slot2.get("time", ""),
		"map": "MAP.217",
		"prev_map": slot2.get("return_zone", ""),
		"map_state": legacy_state,
		"player": slot2["player"],
		"objectives": slot2["objectives"],
		"mission_start_map": slot2.get("mission_start_map", ""),
		"stats": slot2.get("stats", {}),
	}
	_check(SaveGame.write(SAVE_SLOT, legacy) and _header_version(SAVE_SLOT) == SaveGame.VERSION_MAP,
		"a per-map save is written as format %d" % _header_version(SAVE_SLOT))
	ok = await _load(SAVE_SLOT, "217")
	_check(ok, "the v0.3 per-map save loads with the flag up")
	if ok:
		_check(_main.get("_mission") != null and _active() == "MAP.217",
			"it plays inside the mission scene, the world zone in phase MAP.217")
		var ms: Dictionary = _main.get("_map_state")
		var leftover: Array = []
		for mn in ms:
			if (_main.get("_zones") as Dictionary).has(mn) or (_main.get("_phases") as Dictionary).has(mn):
				leftover.append(mn)
		_check(leftover.is_empty() and (_main.get("_zone_state") as Dictionary).has("MAP.216")
			and (_main.get("_zone_state") as Dictionary).has("MAP.214"),
			"its per-map overlays became the zones' state (per-map overlay left for scene maps: %s)"
			% str(leftover))
		_check(int(_main.get("_objectives_left")) == left, "the counter comes back (%d left)" % left)
		if not spoil_217.is_empty():
			_check_carried(spoil_217, "the v0.3 save in phase MAP.217")
		_check(String(_main.get("_prev_map_name")) == "MAP.215", "the previous-map register became the return zone")
		ok = await _go(214, 10, "214")
		_check(ok and not _enemy_alive_here(int(_spoil_214.get("robot", -1)))
			and not _pickup_here(int(_spoil_214.get("item", -1))),
			"an interior walked into takes its per-map overlay: MAP.214's robot dead, item gone")
		if ok:
			ok = await _go(0, 10, "217")
			_check(ok and _active() == "MAP.217", "and the return door leads back into MAP.217")

	# --- 7d. The mission save with the flag DOWN ------------------------
	# The per-map runtime plays it: the map is the zone, the zones are its
	# per-map overlay, the return zone its previous-map register.
	await _wait(func() -> bool: return not bool(_main.get("_level_busy")) and _settled(), 30.0)
	Settings.mission_scenes = false
	ok = await _load(SAVE_SLOT, "217", slot2)
	_check(ok, "the mission save loads with the flag down")
	if ok:
		var lvl = _main.get("_current_level")
		_check(_main.get("_mission") == null and (lvl.origin as Vector3) == Vector3.ZERO,
			"the per-map runtime has MAP.217 up on its own")
		var ms2: Dictionary = _main.get("_map_state")
		_check(ms2.has("MAP.217") and ms2.has("MAP.216") and ms2.has("MAP.214") and ms2.has("MAP.210"),
			"the save's zones are the per-map overlay (%s)" % str(ms2.keys()))
		_check(player.global_position.distance_to(pos) < 300.0,
			"the player stands where the save left them (d=%.0f)" % player.global_position.distance_to(pos))
		_check(int(_main.get("_objectives_left")) == left, "the counter comes back (%d left)" % left)
		if not spoil_217.is_empty():
			_check_carried(spoil_217, "the mission save in the per-map runtime")
		_check(String(_main.get("_prev_map_name")) == "MAP.215", "the return zone is the previous-map register")
		ok = await _go(214, 10, "214")
		_check(ok and _main.get("_mission") == null and not _enemy_alive_here(int(_spoil_214.get("robot", -1)))
			and not _pickup_here(int(_spoil_214.get("item", -1))),
			"MAP.214 loads per map with the save's overlay: its robot dead, its item gone")
	Settings.mission_scenes = true

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
