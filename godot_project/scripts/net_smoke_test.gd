## Headless deathmatch smoke test: hosts MAP.605 with three bots on the
## real game scene, then checks the DM machinery — spawn sets, pickups
## placed from NETLEVEL.PRS, bot avatars that walk, shoot and score, the
## host's own hits landing on a bot, forged client input (hits, poses,
## pickups, level_ready, chat) fed to the server's handlers, a second Godot
## process joining as a client (roster/welcome/leave) and pickup respawn.
##
##   godot --headless --path . res://scenes/net_smoke_test.tscn
##   (add `-- --no-client` to skip the second process)
extends Node

const MainScene := preload("res://scenes/main.tscn")
const DmGameScript := preload("res://scripts/net/dm_game.gd")
const NetDiscovery := preload("res://scripts/net/net_discovery.gd")
const LevelLoader := preload("res://scripts/level_loader.gd")
const LevelBehaviour := preload("res://scripts/level/behaviour.gd")

## The one arena that has a DOOR: MAP.604's DRAINBOX gates (0xEF) each
## drive a WATRWEEL swing (map_dump --triggers=604). The match itself is
## played on MAP.605, which is the arena with the spawn sets, the weapon
## spots and the vehicles this suite checks, so the wire is driven on a
## pair of MAP.604 levels loaded here — one in the server's role, one in
## a client's, with the server's real delta carried between them.
const DOOR_ARENA: String = "MAP.604"

var _fails: int = 0
var _main: Node = null
var _fired: int = 0
var _bot_fired: int = 0
var _deaths: Array = []
var _joined: Array = []
var _left: Array = []
var _taken: int = 0
var _client_pid: int = -1

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[net-e2e] PASS  %s" % what)
	else:
		_fails += 1
		print("[net-e2e] FAIL  %s" % what)

func _wait(pred: Callable, secs: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		if pred.call():
			return true
		await get_tree().process_frame
	return false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Net.fired.connect(func(id: int, _w: int, _f: Vector3, _d: Vector3) -> void:
		_fired += 1
		if Net.is_bot(id):
			_bot_fired += 1)
	Net.died.connect(func(v: int, k: int, _w: int) -> void: _deaths.append([v, k]))
	Net.player_joined.connect(func(id: int) -> void: _joined.append(id))
	Net.player_left.connect(func(id: int) -> void: _left.append(id))
	Net.pickup_taken.connect(func(_k: int, _by: int) -> void: _taken += 1)
	var ok: bool = Net.host({"name": "e2e", "map": "MAP.605", "max_players": 0,
		"time_limit": 0, "frag_limit": 0, "bots": 3, "bot_skill": 2, "port": 27015,
		"items": {"jeeps": 2, "hks": 1, "bullets": 5, "energy": 5, "armor": 10, "health": 10, "slugthrowers": 5,
			"lasers": 5, "plasmas": 4, "launchers": 3, "grenades": 12, "rockets": 3},
		"replenish": true})
	_check(ok, "host() opens the server")
	_main = MainScene.instantiate()
	add_child(_main)
	_run()

func _run() -> void:
	var player: CharacterBody3D = _main.get("player")
	player.set("god_mode", true)
	var ok: bool = await _wait(func() -> bool:
		var lvl = _main.get("_current_level")
		return lvl != null and String(lvl.map_suffix) == "605" and Net.level_ready, 240.0)
	_check(ok, "MAP.605 loads in DM mode (no briefing) and the server is level-ready")
	if not ok:
		return _finish()
	_check(_main.get("_briefing_overlay") == null, "no briefing screen in a network game")
	# Mission scenes are the campaign's runtime (Settings.mission_scenes, on
	# by default since step 8) and a deathmatch is refused them: the arena is
	# one map, the same one for everyone, and no mission is being played.
	# Nothing above turns the setting off — the Net.active rule does it.
	_check(bool(Settings.mission_scenes) and _main.get("_mission") == null
		and (_main.get("_current_level").origin as Vector3) == Vector3.ZERO,
		"a deathmatch takes the per-map runtime with the flag up")
	_check(get_tree().get_nodes_in_group("enemy").is_empty(), "arena has no map enemies")
	_check(Net.spawn_points.size() >= 10, "%d DM spawn sets (markers 10..29)" % Net.spawn_points.size())
	_check(Net.pickups.size() >= 40, "%d pickups placed from NETLEVEL counts" % Net.pickups.size())
	_check(Net.vehicles.size() == 3, "%d vehicles parked (2 jeeps + 1 HK)" % Net.vehicles.size())
	_check(get_tree().get_nodes_in_group("dm_vehicle").size() == 3, "vehicle nodes in the world")
	var dm: Node = _main.get("_dm")
	_check(dm != null, "DM controller attached")
	ok = await _wait(func() -> bool: return Net.is_alive(1), 10.0)
	_check(ok, "host player spawned by the server")
	var lvl = _main.get("_current_level")
	var near_spawn := false
	for sp in Net.spawn_points:
		if (sp["pos"] as Vector3).distance_to(player.global_position) < 300.0:
			near_spawn = true
	_check(near_spawn, "host stands on a DM spawn set")
	var avatars: Array = get_tree().get_nodes_in_group("dm_actor")
	_check(avatars.size() == 3, "3 bot avatars in the world (%d)" % avatars.size())
	ok = await _wait(func() -> bool:
		for a in get_tree().get_nodes_in_group("dm_actor"):
			if not bool(a.get("alive")):
				return false
		return true, 10.0)
	_check(ok, "every bot respawned alive")
	var start: Dictionary = {}
	for a in avatars:
		start[a] = (a as Node3D).global_position
	# Let the bots roam / fight for a while.
	for _f in 60 * 12:
		await get_tree().physics_frame
	var moved: int = 0
	var grounded: int = 0
	for a in avatars:
		if not is_instance_valid(a):
			continue
		if (a as Node3D).global_position.distance_to(start[a]) > 100.0:
			moved += 1
		if (a as Node3D).global_position.y > -3000.0:
			grounded += 1
	_check(moved >= 2, "%d/3 bots walked under the bot brain" % moved)
	_check(grounded == 3, "bots stay on the map (none fell through)")
	# The bodies must ANIMATE, not slide about in one pose: "Postavicky len
	# poskakuju a premiestnuju sa. Vobec tam nie je animacia behu, statia a
	# podobne" (playtest 2026-09-12). Watch the bots' clip and frame for a
	# second — bodies that are walking show several different frames.
	var poses: Dictionary = {}
	for _f in 60:
		await get_tree().physics_frame
		for a in avatars:
			if is_instance_valid(a) and a.has_method("anim_state"):
				poses[str(a.call("anim_state"))] = true
	_check(poses.size() >= 3,
		"the bots' bodies animate (%d distinct clip frames in a second)" % poses.size())
	# Whether two bots find each other inside a fixed window is luck — on a
	# loaded machine (this suite runs four Godot processes back to back)
	# 12 s was not enough and the check failed with "0 shots", and 45 s was
	# not enough either on 2026-09-16 (the same run's bots fired four shots
	# a minute later). Waiting longer only makes the coin heavier. Give
	# them something to shoot at instead: the host counts as a candidate
	# like any other (bot_brain._candidates), so standing in front of one
	# settles it without moving a single bot and without softening what is
	# asserted — the bot still has to see him, turn and decide to fire.
	# A bot only shoots what it can SEE (bot_brain._think casts a ray), and
	# the arena is full of walls, so one fixed spot beside it is another
	# coin toss: stand in a few places round it in turn, a couple of
	# seconds each, and stop the moment a trigger is pulled.
	if _bot_fired == 0 and _deaths.is_empty():
		var around: Array = [Vector3(200.0, 0.0, 0.0), Vector3(-200.0, 0.0, 0.0),
			Vector3(0.0, 0.0, 200.0), Vector3(0.0, 0.0, -200.0),
			Vector3(500.0, 0.0, 0.0), Vector3(0.0, 0.0, 500.0)]
		for step in around.size() * 2:
			if _bot_fired > 0 or not _deaths.is_empty():
				break
			var bait: Node3D = null
			for a in avatars:
				if is_instance_valid(a) and bool(a.get("alive")) \
						and Net.is_alive(int(a.get("net_id"))):
					bait = a
					break
			if bait == null:
				break
			if not Net.is_alive(Net.local_id):
				Net._srv_respawn(Net.local_id)   # shot while baiting: get up
			player.set_spawn(bait.global_position + around[step % around.size()], 0.0, false)
			await _wait(func() -> bool: return _bot_fired > 0 or _deaths.size() > 0, 2.5)
		if _bot_fired == 0 and _deaths.is_empty():
			await _wait(func() -> bool: return _bot_fired > 0 or _deaths.size() > 0, 20.0)
	_check(_bot_fired > 0 or _deaths.size() > 0, "bots fired %d shots, %d deaths" % [_bot_fired, _deaths.size()])
	# The HUMAN class carries the MOTION DETECTOR (DOS weapon record 13):
	# it is in the loadout, it has no trigger, and its marks only draw
	# while it is the weapon in hand.
	# The class comes from the saved config, so pick it here instead of
	# inheriting whatever the last game was played as.
	var dm_node: Node = _main.get("_dm")
	var det: int = int(player.call("motion_detector_slot"))
	var was_class: int = Net.class_of(Net.local_id)   # put it back at the end
	# A class picked mid-game waits for the next spawn — what the console
	# and the NEXT LIFE message promise — and that respawn puts it on.
	Net.set_class(Net.CLASS_TERMINATOR if was_class == Net.CLASS_HUMAN else Net.CLASS_HUMAN)
	_check(Net.class_of(Net.local_id) == was_class, "a class picked mid-game waits for the next spawn")
	Net.set_class(Net.CLASS_HUMAN)
	Net._srv_respawn(Net.local_id)
	_check(Net.class_of(Net.local_id) == Net.CLASS_HUMAN, "the respawn puts the picked class on")
	if dm_node != null:
		dm_node.call("_apply_local_class")
	_check((player.call("owned_list") as Array).has(det),
		"the HUMAN player owns the motion detector (slot %d, owned %s)"
		% [det, str(player.call("owned_list"))])
	player.call("_select_weapon", det)
	_check(bool(player.call("detector_active")) and int(player.ammo) < 0,
		"the detector is in hand and shows no ammo (%d)" % int(player.ammo))
	# …and it has no trigger. This used to count Net.fired events over one
	# physics frame and expect none, which was wrong twice over: the HOST's
	# own shots never raise that signal at all (net_game._srv_fire emits
	# only for `id != local_id`), so the check could not have caught a
	# detector that DID fire; and the only thing it could see was the three
	# bots shooting at each other inside that one frame, which is a coin
	# toss — a run on 2026-09-16 failed with "1 fire events" and the next
	# passed with 0. It asks the WEAPON now, with no frame in between.
	# A real gun leaves its cooldown running and its viewmodel firing
	# (fly_camera._shoot); the detector returns before either, on
	# `kind == "detector"`. The real gun goes first, so a probe that could
	# never fail is caught here rather than passing quietly.
	var real: int = -1
	for slot in (player.call("owned_list") as Array):
		if int(slot) != det:
			real = int(slot)
			break
	player.call("_select_weapon", real)
	player.set("_fire_cd", 0.0)
	player.set("_vm_firing", false)
	player.call("_shoot")
	_check(real >= 0 and float(player.get("_fire_cd")) > 0.0,
		"a gun with a trigger leaves a cooldown behind (slot %d, %.3f s)"
		% [real, float(player.get("_fire_cd"))])
	player.call("_select_weapon", det)
	player.set("_fire_cd", 0.0)
	player.set("_vm_firing", false)
	player.call("_shoot")
	_check(float(player.get("_fire_cd")) == 0.0 and not bool(player.get("_vm_firing"))
		and bool(player.call("detector_active")),
		"the detector has no trigger (cooldown %.3f, viewmodel %s)"
		% [float(player.get("_fire_cd")), str(player.get("_vm_firing"))])
	# And it has to MARK somebody standing in front of it inside its reach
	# (2026-09-14: in play it showed nobody).
	var scanner: Control = dm_node.get("_detector") if dm_node != null else null
	var scanned: Node3D = null
	for a in get_tree().get_nodes_in_group("dm_actor"):
		if is_instance_valid(a) and bool(a.get("alive")) and Net.is_alive(int(a.get("net_id"))):
			scanned = a
			break
	if scanner != null and scanned != null:
		player.set_spawn(scanned.global_position + Vector3(600.0, 40.0, 0.0), 0.0, false)
		await get_tree().physics_frame
		var cam3: Camera3D = player.get_viewport().get_camera_3d()
		var look: Vector3 = scanned.global_position + Vector3(0.0, 50.0, 0.0) - cam3.global_position
		player.set_view(atan2(-look.x, -look.z), atan2(look.y, Vector2(look.x, look.z).length()))
		await get_tree().process_frame
		await get_tree().process_frame
		var marked: Array = scanner.call("marks")
		_check(scanner.visible and marked.size() >= 1,
			"the motion detector marks a player in front of it (%d marks at %.0f u, visible %s, in hand %s, can_process %s, same player %s, weapon %s)"
			% [marked.size(), cam3.global_position.distance_to(scanned.global_position), scanner.visible,
				player.call("detector_active"), scanner.can_process(), scanner.get("player") == player,
				player.get("weapon_name")])
	else:
		_check(false, "a live bot and the scanner overlay exist for the detector check")
	# A TERMINATOR has the same reading built into its view instead, so it
	# carries no scanner.
	Net.set_class(Net.CLASS_TERMINATOR)
	Net._srv_respawn(Net.local_id)
	if dm_node != null:
		dm_node.call("_apply_local_class")
	_check(not (player.call("owned_list") as Array).has(det),
		"the TERMINATOR carries no scanner (owned %s)" % str(player.call("owned_list")))
	Net.set_class(was_class)                  # leave the player's own choice alone
	Net._srv_respawn(Net.local_id)
	if dm_node != null:
		dm_node.call("_apply_local_class")
	# Those respawns moved the player: let it settle on the floor before the
	# eye-height checks below.
	for _f in 60:
		await get_tree().physics_frame

	# Dying used to print YOU DIED and leave the player standing ("ostane
	# stat", playtest 2026-09-12). Driving it straight rather than waiting for
	# a bot to manage the kill: the eye must go down, and come back.
	var cam: Camera3D = player.get_viewport().get_camera_3d()
	var eye0: float = cam.global_position.y if cam != null else 0.0
	player.call("begin_death_view")
	for _f in 40:                             # past DEATH_FALL (0.5 s)
		await get_tree().process_frame
	var eye1: float = cam.global_position.y if cam != null else 0.0
	_check(cam != null and eye1 < eye0 - 30.0,
		"death drops the view to the ground (eye %.0f → %.0f)" % [eye0, eye1])
	player.call("end_death_view")
	await get_tree().process_frame
	var eye2: float = cam.global_position.y if cam != null else 0.0
	_check(absf(eye2 - eye0) < 2.0, "and the respawn stands it back up (%.0f)" % eye2)
	# Teleport beside a bot and shoot it: the hit must reach the server.
	var target: Node3D = null
	for a in avatars:
		if is_instance_valid(a) and bool(a.get("alive")):
			target = a
			break
	if target != null:
		var tid: int = int(target.get("net_id"))
		var hp0: float = float(Net.players[tid]["hp"])
		player.call("_select_weapon", 1)
		# The bot keeps walking: re-aim and fire a few times, stop on the first hit.
		# Stand on a different side each try: the bot may hug a wall
		# (a BLDG20J face sat between +200 X and a T-800 once).
		# The last two stand close enough that no wall can come between
		# (a run on 2026-09-12 missed six times over from 140-200 u while
		# the bots were busy shooting each other).
		var sides: Array = [Vector3(200.0, 0.0, 0.0), Vector3(-200.0, 0.0, 0.0),
			Vector3(0.0, 0.0, 200.0), Vector3(0.0, 0.0, -200.0),
			Vector3(140.0, 0.0, 140.0), Vector3(-140.0, 0.0, -140.0),
			Vector3(70.0, 0.0, 0.0), Vector3(0.0, 0.0, 70.0)]
		for _shot in 8:
			if not is_instance_valid(target) or float(Net.players[tid]["hp"]) < hp0 or not Net.is_alive(tid):
				break
			player.set_spawn(target.global_position + sides[_shot % sides.size()], 0.0, false)
			var aim: Vector3 = (target as Node3D).global_position + Vector3(0.0, 44.0, 0.0) - (player.global_position + Vector3(0.0, 75.0, 0.0))
			player.set_view(atan2(-aim.x, -aim.z), atan2(aim.y, Vector2(aim.x, aim.z).length()))
			await get_tree().physics_frame
			player.set("_fire_cd", 0.0)
			player.call("_shoot")
			await get_tree().physics_frame
			await get_tree().physics_frame
		_check(float(Net.players[tid]["hp"]) < hp0 or not Net.is_alive(tid),
			"host's UZI shot reduced bot %s hp %.0f → %.0f" % [Net.name_of(tid), hp0, float(Net.players[tid]["hp"])])
	_check(_fired > 0, "fire events replicated (%d)" % _fired)
	# Pickup: walk onto one.
	var key: int = -1
	for k in Net.pickups:
		if not bool(Net.pickups[k]["taken"]):
			key = k
			break
	if key >= 0:
		var pos: Vector3 = Net.pickups[key]["pos"]
		player.set_spawn(pos + Vector3(0.0, 4.0, 0.0), 0.0, false)
		ok = await _wait(func() -> bool: return bool(Net.pickups[key]["taken"]), 3.0)
		_check(ok, "walking over a DM pickup takes it via the server")
	await _forged_input_checks(dm, avatars)
	_trigger_wire_checks(dm)
	# Second process joins as a client.
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.has("--no-client"):
		var exe: String = OS.get_executable_path()
		# --quit-after is the client's WHOLE life: joining, loading MAP.605
		# and spawning have to fit inside it. 12 s did not on a loaded
		# machine, and the client then quit before it ever spawned, so the
		# two checks below failed while waiting 180 s for something that
		# could no longer happen. 60 s covers a cold cache; the test does
		# not get slower in the good case, it only waits for the quit.
		var t_client := Time.get_ticks_msec()
		_client_pid = OS.create_process(exe, ["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--", "--join=127.0.0.1:27015", "--name=CLIENT", "--quit-after=60"], false)
		_check(_client_pid > 0, "client process started (pid %d)" % _client_pid)
		ok = await _wait(func() -> bool: return _joined.size() > 0 and not Net.is_bot(_joined[-1]), 90.0)
		_check(ok, "client joined the roster (%s)" % (Net.name_of(_joined[-1]) if not _joined.is_empty() else "-"))
		if ok:
			var cid: int = _joined[-1]
			ok = await _wait(func() -> bool: return Net.is_alive(cid), 120.0)
			_check(ok, "client loaded the arena and was spawned (%.1f s after launch)"
				% ((Time.get_ticks_msec() - t_client) / 1000.0))
			var av = dm.get("_avatars").get(cid)
			_check(av != null and is_instance_valid(av), "client has an avatar on the host")
			ok = await _wait(func() -> bool: return _left.has(cid), 90.0)
			_check(ok, "client left cleanly after --quit-after")
			if ok:
				# Leaving is the first thing the client's quit does, not the
				# last: its cache manifest is written as the process exits.
				# _finish used to kill it right here, so what it had baked
				# (MAP.605's level scene, meshes, textures — rebuilt over the
				# host's copies, which were not in the manifest yet either)
				# was never recorded, and every run rebuilt all of it twice.
				await _wait(func() -> bool: return not OS.is_process_running(_client_pid), 20.0)
	_finish()

## What a hostile client could send, fed straight into the server's
## handlers (`_srv_client_*`, which the `_c_*` RPCs call with the sender's
## id; the host's own id stands in for the client). None of it may change
## the game; the real rules — a bot's kill, one level_ready spawn, a seat
## given up on respawn — must hold.
func _forged_input_checks(dm: Node, avatars: Array) -> void:
	# Pure helpers first.
	var evil: String = "  [color=red]EV" + String.chr(0x202E) + "IL" + String.chr(7) + String.chr(10) + "  "
	var clean: String = Net._clean_text(evil, Net.MAX_NAME_LEN)
	_check(clean == "[color=red]EVIL", "names lose control and bidi characters ('%s')" % clean)
	_check(DmGameScript._bb("[b]X[/b]") == "[lb]b]X[lb]/b]", "scoreboard text cannot carry BBCode")
	_check(Net._is_lan_ip("192.168.1.20") and Net._is_lan_ip("10.1.2.3") and Net._is_lan_ip("172.20.0.5")
		and Net._is_lan_ip("127.0.0.1") and Net._is_lan_ip("::ffff:169.254.3.4")
		and not Net._is_lan_ip("8.8.8.8") and not Net._is_lan_ip("172.32.0.1") and not Net._is_lan_ip("fe80::1"),
		"LAN discovery answers private, loopback and link-local IPv4 only")
	var disc = NetDiscovery.new()
	disc.accept_reply("192.168.1.9", JSON.stringify({"name": 42, "map": ["x"], "players": "lots",
		"bots": null, "max": 1e300, "port": 99999}).to_utf8_buffer())
	var sv: Dictionary = disc.servers.get("192.168.1.9:65535", {})
	_check(String(sv.get("name", "")) == "?" and int(sv.get("players", -1)) == 0 and int(sv.get("max", -1)) == 999,
		"a malformed LAN reply is listed with safe values, not a script error (%s)" % str(sv))

	var bots: Array = []
	for a in avatars:
		if is_instance_valid(a) and Net.is_alive(int(a.get("net_id"))):
			bots.append(int(a.get("net_id")))
	if bots.size() < 2 or not Net.is_alive(1):
		_check(false, "two live bots and a live host for the forged-input checks (%d bots)" % bots.size())
		return
	var tid: int = bots[0]
	var v: Dictionary = Net.players[tid]
	var hp0: float = float(v["hp"])
	for bad in [NAN, INF, -50.0, 0.0]:
		Net._srv_client_hit(1, tid, bad, 1)
	Net._srv_client_hit(987654, tid, 10.0, 1)            # never admitted
	_check(float(v["hp"]) == hp0, "forged hits (NaN, inf, negative, zero, unknown sender) leave bot hp %.0f alone (%.0f)"
		% [hp0, float(v["hp"])])
	var armor0: float = float(v["armor"])
	v["hp"] = 5000.0
	v["armor"] = 0.0
	Net._srv_client_hit(1, tid, 1e9, 1)
	var took: float = 5000.0 - float(v["hp"])
	v["hp"] = hp0
	v["armor"] = armor0
	_check(is_equal_approx(took, Net.MAX_HIT_DAMAGE), "a 1e9 hit report is clamped to %.0f (took %.0f)"
		% [Net.MAX_HIT_DAMAGE, took])

	var pos0: Vector3 = Net.players[1]["pos"]
	Net._srv_client_pose(1, Vector3(NAN, 0.0, 0.0), 0.0, 0.0, 0)
	Net._srv_client_pose(1, Vector3(1e12, 0.0, 0.0), 0.0, 0.0, 0)
	Net._srv_client_pose(1, pos0 + Vector3(10.0, 0.0, 0.0), INF, 0.0, 0)
	_check(Net.players[1]["pos"] == pos0, "non-finite or absurd poses are not taken (%s)" % str(Net.players[1]["pos"]))

	var far_key: int = -1
	for k in Net.pickups:
		if not bool(Net.pickups[k]["taken"]) \
				and (Net.pickups[k]["pos"] as Vector3).distance_to(pos0) > Net.PICKUP_REACH * 2.0:
			far_key = k
			break
	if far_key >= 0:
		Net._srv_client_pickup(1, far_key)
		_check(not bool(Net.pickups[far_key]["taken"]), "a pickup request from across the map is refused")

	Net._srv_level_ready(tid)                            # the one spawn a peer gets
	v = Net.players[tid]
	v["hp"] = 42.0
	Net._srv_level_ready(tid)
	_check(float(v["hp"]) == 42.0, "a repeated level_ready does not heal (hp %.0f)" % float(v["hp"]))
	v["hp"] = Net.max_hp_of(tid)

	var lines: Array = []
	var on_chat := func(_from: int, text: String) -> void: lines.append(text)
	Net.chat_received.connect(on_chat)
	for _i in 10:
		Net._srv_client_chat(1, "X".repeat(500) + String.chr(0x202E))
	Net.chat_received.disconnect(on_chat)
	var burst: int = int(Net.RATE_LIMITS[Net.RL_CHAT][1])
	var capped: bool = true
	for l in lines:
		capped = capped and String(l).length() <= Net.MAX_CHAT_LEN
	_check(lines.size() == burst and capped, "a chat flood is cut to the %d-line burst, each capped (%d lines)"
		% [burst, lines.size()])

	if not Net.vehicles.is_empty():
		var vkey: int = int(Net.vehicles.keys()[0])
		if Net.vehicle_of(1) == 0 and int(Net.vehicles[vkey]["driver"]) == 0:
			Net._srv_vehicle_enter(1, vkey)
			var seated: bool = Net.vehicle_of(1) == vkey
			Net._srv_respawn(1)
			_check(seated and Net.vehicle_of(1) == 0 and int(Net.vehicles[vkey]["driver"]) == 0,
				"a respawn gives the seat up (seated %s, driver now %d)" % [seated, int(Net.vehicles[vkey]["driver"])])

	# Bots are NEGATIVE ids: their kills must count for them.
	var killer: int = bots[0]
	var victim: int = bots[1]
	if Net.is_alive(killer) and Net.is_alive(victim):
		var k0: int = int(Net.players[killer]["kills"])
		var vk0: int = int(Net.players[victim]["kills"])
		Net._srv_hit(victim, 100000.0, killer, 1)
		_check(not Net.is_alive(victim) and int(Net.players[killer]["kills"]) == k0 + 1
			and int(Net.players[victim]["kills"]) == vk0,
			"a bot's kill is the bot's frag (%s %d → %d) and costs the victim none (%d → %d)"
			% [Net.name_of(killer), k0, int(Net.players[killer]["kills"]), vk0, int(Net.players[victim]["kills"])])
		var center: Label = dm.get("_center")
		Net._srv_hit(1, 100000.0, killer, 1)
		_check(not Net.is_alive(1) and center != null and center.text == "KILLED BY %s" % Net.name_of(killer),
			"killed by a bot names the bot ('%s')" % (center.text if center != null else "-"))
		var back: bool = await _wait(func() -> bool: return Net.is_alive(1), Net.RESPAWN_DELAY + 5.0)
		_check(back, "and the host respawns after it")

## The arena's trigger state on the wire (M5).
##
## Two halves. The first drives a real DOOR on a pair of MAP.604 levels -
## the server's branch, which flips, and a client's, which may not — and
## carries the server's own delta from one to the other, so what is
## checked is the wire's own data and not a second copy of the rules. The
## second feeds forged intents to the live server's handler on MAP.605,
## the way the checks above feed it forged hits and pickups.
func _trigger_wire_checks(dm: Node) -> void:
	var srv = LevelLoader.new().load_level(DOOR_ARENA)
	var cli = LevelLoader.new().load_level(DOOR_ARENA)
	if srv == null or cli == null or srv.behaviour == null or cli.behaviour == null:
		_check(false, "%s loads twice for the trigger-wire checks" % DOOR_ARENA)
		return
	# The gate whose chain reaches a mover — the door of this arena.
	var gate: int = -1
	var mover: int = -1
	for t in srv.behaviour.prox_nodes():
		var nxt: int = int(srv.triggers.link(int(t.id)))
		if int(t.act_now()) == 0xEF and srv.behaviour.has_mover(nxt):
			gate = int(t.id)
			mover = nxt
			break
	if gate < 0:
		_check(false, "%s has a gate that drives a mover" % DOOR_ARENA)
		return
	srv.behaviour.net_role = LevelBehaviour.ROLE_SERVER
	srv.triggers.journal = true
	srv.triggers.net_delta()                   # start from a clean page
	var intents: Array = []
	cli.behaviour.net_role = LevelBehaviour.ROLE_CLIENT
	cli.triggers.authority = false
	cli.behaviour.net_intent = func(off: int, kind: int, amount: float) -> void:
		intents.append([off, kind, amount])

	# --- the host uses the door ---------------------------------------
	var gnode: Node3D = srv.behaviour.prox_node(gate)
	var at: Vector3 = gnode.position
	srv.behaviour.on_player_activate(gate, at, at)
	_check(srv.triggers.enabled(mover),
		"the host uses %s's gate @%05x and the mover @%05x is set going" % [DOOR_ARENA, gate, mover])
	var delta: Dictionary = srv.triggers.net_delta()
	_check((delta.get("st", {}) as Dictionary).has(mover)
		and (delta.get("movers", {}) as Dictionary).has(mover),
		"the delta carries the flip and the mover's own state (%s)" % str(delta.keys()))
	_check(not cli.triggers.enabled(mover), "the client has not moved it by itself")
	cli.triggers.apply_delta(delta)
	_check(cli.triggers.enabled(mover) and cli.triggers.state(mover) == srv.triggers.state(mover),
		"the client sees the same flip (state %02x)" % cli.triggers.state(mover))
	var sm: Node = srv.behaviour.mover_node(mover)
	var cm: Node = cli.behaviour.mover_node(mover)
	_check(sm != null and cm != null and is_equal_approx(float(sm.progress), float(cm.progress))
		and is_equal_approx(float(sm.dir), float(cm.dir)),
		"…and the same mover state (progress %.1f dir %+.0f)"
		% [float(cm.progress) if cm != null else -1.0, float(cm.dir) if cm != null else 0.0])

	# Both animate it themselves from that one flip: no position crosses
	# the wire between the start of the travel and the end of it.
	var away := Vector3(1e9, 0.0, 1e9)
	for _f in 10:
		srv.behaviour.tick(0.05, away, away)
		cli.behaviour.tick(0.05, away, away)
	_check(float(cm.progress) > 0.0 and is_equal_approx(float(sm.progress), float(cm.progress)),
		"the client animates the door from its own copy of the map (progress %.0f vs %.0f)"
		% [float(cm.progress), float(sm.progress)])
	# ...and the arrival, which is the server clearing the bit.
	for _f in 200:
		srv.behaviour.tick(0.05, away, away)
	cli.triggers.apply_delta(srv.triggers.net_delta())
	for _f in 5:
		cli.behaviour.tick(0.05, away, away)
	_check(not srv.triggers.enabled(mover) and not cli.triggers.enabled(mover)
		and is_equal_approx(float(sm.progress), float(cm.progress))
		and is_equal_approx(float(sm.dir), float(cm.dir)),
		"the door stops on both when the server's handler clears the bit (progress %.0f dir %+.0f)"
		% [float(cm.progress), float(cm.dir)])

	# --- a late joiner ------------------------------------------------
	var snap: Dictionary = srv.triggers.net_snapshot()
	_check(not snap.has("sigs")
		and (snap.get("states", {}) as Dictionary).size() < srv.map.entities.size(),
		"the welcome's overlay is sparse (%d of %d records, no signature table)"
		% [(snap.get("states", {}) as Dictionary).size(), srv.map.entities.size()])
	var late = LevelLoader.new().load_level(DOOR_ARENA)
	late.behaviour.net_role = LevelBehaviour.ROLE_CLIENT
	late.triggers.authority = false
	_check(late.triggers.net_restore(snap), "a late joiner takes the server's overlay")
	var lm: Node = late.behaviour.mover_node(mover)
	_check(late.triggers.state(mover) == srv.triggers.state(mover)
		and lm != null and is_equal_approx(float(lm.progress), float(sm.progress)),
		"…and walks into the door already open (progress %.0f)"
		% [float(lm.progress) if lm != null else -1.0])
	var foreign: Dictionary = snap.duplicate(true)
	foreign["graph_sha"] = "0000000000000000"
	var other = LevelLoader.new().load_level(DOOR_ARENA)
	other.triggers.authority = false
	var om: Node = other.behaviour.mover_node(mover)
	_check(not other.triggers.net_restore(foreign) and om != null
		and float(om.progress) == 0.0 and float(sm.progress) > 0.0,
		"an overlay of another map file is refused whole, not half applied (door at %.0f, the server's at %.0f)"
		% [float(om.progress) if om != null else -1.0, float(sm.progress)])

	# --- a client writes nothing --------------------------------------
	var st0: int = cli.triggers.state(gate)
	_check((cli.triggers.flip(gate) as Array).is_empty() and cli.triggers.state(gate) == st0,
		"a client's runtime walks no chain of its own")
	cli.triggers.arm(gate)
	cli.triggers.clear_enable(mover)
	cli.triggers.set_spent(gate)
	_check(cli.triggers.state(gate) == st0 and not cli.triggers.spent(gate),
		"…and none of its writers take")
	intents.clear()
	cli.behaviour.on_player_activate(gate, at, at)
	_check(intents.size() == 1 and int(intents[0][0]) == gate and int(intents[0][1]) == Net.TRIG_USE,
		"the use key becomes an intent for the server (%s)" % str(intents))
	var hittable: int = -1
	for off in cli.behaviour.damageable_offs():
		hittable = int(off)
		break
	if hittable >= 0:
		intents.clear()
		var hp0: float = cli.triggers.hp(hittable)
		_check(not cli.behaviour.obj_hit(hittable, 50.0)
			and is_equal_approx(cli.triggers.hp(hittable), hp0)
			and intents.size() == 1 and int(intents[0][1]) == Net.TRIG_HIT,
			"a shot on a destructible becomes an intent and costs it nothing locally")

	# --- forged intents against the live server (MAP.605) --------------
	_check(Net.trigger_world == dm, "the server offers its arena to the net code")
	var live: int = -1
	for off in dm.level.behaviour.damageable_offs():
		if dm.level.triggers.hp(int(off)) > Net.MAX_HIT_DAMAGE:
			live = int(off)
			break
	if live < 0:
		_check(false, "MAP.605 has a record with a pool to shoot at")
		return
	var lhp: float = dm.level.triggers.hp(live)
	var lpos: Vector3 = dm.trigger_pos(live)
	var far: Vector3 = lpos + Vector3(Net.MAX_HIT_RANGE * 2.0, 0.0, 0.0)
	var pos0: Vector3 = Net.players[1]["pos"]
	Net.players[1]["pos"] = far
	Net._srv_client_trigger(1, live, Net.TRIG_HIT, far, far, 100.0)
	Net._srv_client_trigger(1, live, Net.TRIG_USE, far, far, 0.0)
	_check(is_equal_approx(dm.level.triggers.hp(live), lhp),
		"a trigger intent from across the map is refused (hp %.0f)" % dm.level.triggers.hp(live))
	Net.players[1]["pos"] = lpos
	Net._srv_client_trigger(1, live, Net.TRIG_HIT, far, far, 100.0)
	Net._srv_client_trigger(987654, live, Net.TRIG_HIT, lpos, lpos, 100.0)
	Net._srv_client_trigger(1, 0x7FFFFF, Net.TRIG_HIT, lpos, lpos, 100.0)
	Net._srv_client_trigger(1, live, 99, lpos, lpos, 100.0)
	Net._srv_client_trigger(1, live, Net.TRIG_HIT, lpos, lpos, NAN)
	Net._srv_client_trigger(1, live, Net.TRIG_HIT, lpos, lpos, -100.0)
	_check(is_equal_approx(dm.level.triggers.hp(live), lhp),
		"a forged sender, place, id, kind and damage are all refused (hp %.0f)"
		% dm.level.triggers.hp(live))
	Net._srv_client_trigger(1, live, Net.TRIG_HIT, lpos, lpos, 1e9)
	_check(is_equal_approx(lhp - dm.level.triggers.hp(live), Net.MAX_HIT_DAMAGE),
		"a real one lands, clamped to %.0f (%.0f → %.0f)"
		% [Net.MAX_HIT_DAMAGE, lhp, dm.level.triggers.hp(live)])
	var wire: Dictionary = Net._trigger_wire()
	_check((wire.get("hp", {}) as Dictionary).has(live)
		and is_equal_approx(float(wire["hp"][live]), dm.level.triggers.hp(live)),
		"and the next joiner's welcome carries it")
	Net.players[1]["pos"] = pos0

func _finish() -> void:
	print("[net-e2e] %s — %d failure(s)" % ["OK" if _fails == 0 else "FAILED", _fails])
	# A client that never joined arms its --quit-after only once a level
	# is loaded, so it would otherwise run on headless forever.
	if _client_pid > 0 and OS.is_process_running(_client_pid):
		OS.kill(_client_pid)
	Net.leave()
	get_tree().quit(0 if _fails == 0 else 1)
