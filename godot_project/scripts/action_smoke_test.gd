## Headless smoke test for the action/link system (phase 1).
##
##   godot --headless --path . res://scenes/action_smoke_test.tscn
##
## Loads every campaign map (regression: none may fail to load), then
## exercises the MAP.210 action wiring: proximity button → BIGDOOR
## mover, GENER0 HP-depletion chain, TRANSFRM.PRS car damage stages,
## DISH rotator, and the 0xEF gate → 0xF0 teleport pair. Exits with a
## non-zero code on failure.

extends Node

const LevelLoader := preload("res://scripts/level_loader.gd")
const ActionSystem := preload("res://scripts/action_system.gd")
const EnemyAI := preload("res://scripts/enemy_ai.gd")
const AIData := preload("res://scripts/enemy_ai_data.gd")

const CAMPAIGN: Array = [
	"MAP.210", "MAP.220", "MAP.230", "MAP.240",
	"MAP.252", "MAP.260", "MAP.270", "MAP.280",
]

var _fails: int = 0
var _teleport_seen: Array = []

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[smoke] PASS  %s" % what)
	else:
		_fails += 1
		print("[smoke] FAIL  %s" % what)

func _ready() -> void:
	var level210: LevelLoader.Level = null
	for m in CAMPAIGN:
		var loader := LevelLoader.new()
		var level := loader.load_level(m)
		_check(level != null and level.map != null, "%s loads" % m)
		if level == null:
			continue
		print("[smoke] %s: movers=%d destr=%d prox=%d teleports=%d"
			% [m, level.action._movers.size(), level.action._destr.size(),
			   level.action._prox.size(), level.action._teleports.size()])
		if m == "MAP.210":
			level210 = level
	if level210 != null:
		_run_map210_checks(level210)
		_run_transition_checks(level210)
	_run_ai_checks()
	print("[smoke] %s (%d failures)"
		% ["ALL PASS" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

func _run_map210_checks(level: LevelLoader.Level) -> void:
	var map = level.map
	var action: ActionSystem = level.action

	# Index entities by mesh name for lookups.
	var by_name: Dictionary = {}
	for e in map.entities:
		if (e.flags & 3) != 1:
			continue
		var nm := LevelLoader.MapFile.entity_name(map, e).to_upper()
		if not by_name.has(nm):
			by_name[nm] = []
		by_name[nm].append(e)

	_check(action._movers.size() >= 5,
		"MAP.210 has movers registered (doors/gates/dish)")
	var exits: Array = []
	for t in action._teleports:
		exits.append(t.exit_map)
	exits.sort()
	_check(exits == [211, 212, 213, 214, 218],
		"MAP.210 teleports → %s" % str(exits))

	# --- 1. Proximity BUTTON01 (act 0xEF) opens its chained door ---
	# Chains route through intermediates (0xE0 sound nodes …); walk
	# them with ObjFlipLink's exact rules (stop at an actor flag).
	var button: LevelLoader.MapFile.Entity = null
	var target: LevelLoader.MapFile.Entity = null
	for e in by_name.get("BUTTON01", []):
		if e.link_act_type != 0xEF or (e.state_byte & 1) == 0 \
				or e.link_next < 1:
			continue
		var found = _chain_find_mover(map, e)
		if found != null:
			button = e
			target = found
			break
	_check(button != null and target != null,
		"armed BUTTON01 chains (via hops) to a mover (act 0x%02x)"
		% (target.link_act_type if target != null else 0))
	# The proximity → chain path is covered by the gate→teleport check
	# below; placing the player AT the button would also trip the
	# overlapping LEVHAN01/210BASE3 levers whose chains thread the same
	# door (an even toggle count closes it again). Fire the chain
	# directly and verify the mover runs.
	if target != null:
		var node: Node3D = action._nodes.get(target.file_off)
		_check(node != null, "chained mover has a node")
		if node != null:
			var before: Transform3D = node.transform
			var far := Vector3(1e9, 0.0, 1e9)
			action._flip_link(button)             # the button's chain fires
			_check((target.state_byte & 1) != 0, "chain enabled the mover")
			for i in 30:                          # ~0.5 s of motion
				action.tick(0.016, far)
			_check(node.transform != before, "mover transform is moving")

	# --- 2. GENER0: HP-gated (state bit2, hp 200) chain on destruction ---
	var gener: LevelLoader.MapFile.Entity = null
	for e in by_name.get("GENER0", []):
		if (e.state_byte & 4) != 0 and e.hp > 0:
			gener = e
			break
	_check(gener != null, "GENER0 with bit2 + HP exists")
	if gener != null:
		var next_e = map.entities_by_off.get(gener.link_next)
		var st_before: int = next_e.state_byte if next_e != null else -1
		_check(not action.on_player_hit(gener.file_off, 50.0),
			"GENER0 survives a 50-damage hit (no chain fire)")
		_check(action.on_player_hit(gener.file_off, 500.0),
			"GENER0 dies to the big hit and fires its chain")
		if next_e != null:
			_check(next_e.state_byte != st_before,
				"GENER0 chain flipped its target's state")

	# --- 3. Destructible car: TRANSFRM.PRS stage swap on damage ---
	var car: LevelLoader.MapFile.Entity = null
	for nm in by_name:
		if nm.begins_with("CARHIP") or nm.begins_with("COPCAR"):
			for e in by_name[nm]:
				if action._destr.has(e.file_off) \
						and action._destr[e.file_off]["meshes"].size() > 1 \
						and (e.state_byte & 6) != 0:
					car = e
					break
		if car != null:
			break
	_check(car != null, "damageable TRANSFRM.PRS car exists")
	if car != null:
		var cnode: MeshInstance3D = action._nodes.get(car.file_off)
		var mesh_before: Mesh = cnode.mesh
		action.on_player_hit(car.file_off, 20.0)
		_check(cnode.mesh != mesh_before,
			"car mesh swapped to damage stage after 20 damage")

	# --- 4. DISH (act 0x3b) rotates from load (state bit0 set) ---
	var dish: LevelLoader.MapFile.Entity = null
	for e in by_name.get("DISH", []):
		if e.link_act_type == 0x3b and (e.state_byte & 1) != 0:
			dish = e
			break
	_check(dish != null, "armed DISH rotator exists")
	if dish != null:
		var dnode: Node3D = action._nodes.get(dish.file_off)
		var db: Transform3D = dnode.transform
		action.tick(0.1, Vector3(1e9, 0, 1e9))    # player far away
		_check(dnode.transform != db, "DISH rotates while enabled")

	# --- 5. 0xEF gate + 0xF0 teleport (chained via a sound node) ---
	action.teleport_requested.connect(_on_teleport)
	var gate: LevelLoader.MapFile.Entity = null
	for e in map.entities:
		if (e.flags & 3) != 3 or e.link_act_type != 0xEF \
				or (e.state_byte & 1) == 0 or e.link_next < 1:
			continue
		var cur = e
		for hop in 8:
			if (cur.flags & 0x40) != 0 or cur.link_next < 1:
				break
			cur = map.entities_by_off.get(cur.link_next)
			if cur == null:
				break
			if cur.link_act_type == 0xF0:
				gate = e
				break
		if gate != null:
			break
	_check(gate != null, "0xEF gate chained to a 0xF0 teleport exists")
	if gate != null:
		var gpos := Vector3(float(gate.x), -float(gate.y), -float(gate.z))
		action.tick(0.016, gpos)                  # gate flips teleport on
		action.tick(0.016, gpos)                  # teleport fires
		_check(_teleport_seen.size() == 1
			and _teleport_seen[0][0] in [211, 212, 213, 214, 218],
			"teleport fired once → map %s" % str(_teleport_seen))

func _on_teleport(target_map: int, marker_set: int) -> void:
	_teleport_seen.append([target_map, marker_set])

## Phase 2 — map transitions: marker sets on both ends of an exit, the
## per-map state overlay round trip, doorway touch arming and the
## spawn-inside-the-gate latch.
func _run_transition_checks(level210: LevelLoader.Level) -> void:
	# Sound-id table sanity (0x4ff00): the door chains' one-shot nodes.
	_check(Audio.sound_name(40) == "doora.raw" and Audio.sound_name(45) == "button1.raw"
		and Audio.sound_name(125) == "torpedo.wav",
		"DOS sound-id table resolves door/button/last ids")

	# MAP.218 (bunker interior): spawn set 0, return exit → previous map
	# marker 27; MAP.210 must carry markers 27 + 28 for that return.
	var l218: LevelLoader.Level = LevelLoader.new().load_level("MAP.218")
	_check(l218 != null and l218.markers.has(0) and l218.markers.has(1),
		"MAP.218 has spawn marker 0 + facing marker 1")
	if l218 != null:
		var ret: Array = []
		for t in l218.action._teleports:
			ret.append([t.exit_map, t.exit_marker_id])
		_check(ret == [[0, 27]], "MAP.218 return exit → previous map, marker 27 (%s)" % str(ret))
	_check(level210.markers.has(27) and level210.markers.has(28),
		"MAP.210 carries the return markers 27 + 28")

	# State overlay: the GENER0 spent in the map-210 checks survives a
	# save → fresh parse → restore round trip.
	var snap: Dictionary = level210.action.save_state()
	var spent_offs: Array = snap["spent"].keys()
	_check(not spent_offs.is_empty(), "save_state captures spent entities")
	var l210b: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210b != null and not spent_offs.is_empty():
		var off: int = spent_offs[0]
		_check(not l210b.action._spent.has(off), "fresh MAP.210 parse starts unspent")
		l210b.action.restore_state(snap)
		_check(l210b.action._spent.has(off), "restore_state re-applies the spent flag")
		var e = l210b.map.entities_by_off.get(off)
		_check(e != null and e.state_byte == int(snap["states"][off]),
			"restore_state re-applies entity state bytes")

	# Doorway touch: standing on a 0xF0 exit sprite arms it directly.
	var l210c: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210c != null:
		var seen: Array = []
		l210c.action.teleport_requested.connect(
			func(m: int, s: int) -> void: seen.append([m, s]))
		var ex = l210c.action._teleports[0]
		var epos := Vector3(float(ex.x), -float(ex.y), -float(ex.z))
		l210c.action.tick(0.016, epos)
		_check(seen.size() == 1 and seen[0][0] == ex.exit_map,
			"touching a doorway sprite fires its teleport once (%s)" % str(seen))
		l210c.action.tick(0.016, epos)
		_check(seen.size() == 1, "a fired level never teleports twice")

	# Spawn-inside latch: arm_proximity at the doorway → no fire until the
	# player steps out and back in.
	var l210d: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210d != null:
		var seen2: Array = []
		l210d.action.teleport_requested.connect(
			func(m: int, s: int) -> void: seen2.append([m, s]))
		var ex2 = l210d.action._teleports[0]
		var epos2 := Vector3(float(ex2.x), -float(ex2.y), -float(ex2.z))
		l210d.action.arm_proximity(epos2)
		l210d.action.tick(0.016, epos2)
		_check(seen2.is_empty(), "spawning on a doorway does not fire it")
		l210d.action.tick(0.016, epos2 + Vector3(2000.0, 0.0, 0.0))
		l210d.action.tick(0.016, epos2)
		_check(seen2.size() == 1, "stepping out and back in fires the doorway")

## Phase 3 — DOS enemy AI data + the AIS interpreter, headless.
func _run_ai_checks() -> void:
	_check(AIData.TYPES.size() >= 100 and String(AIData.TYPES[33]["n"]) == "endoskel"
		and int(AIData.TYPES[33]["st"]) == 7 and int(AIData.TYPES[33]["hp"]) == 400,
		"enemy table: endoskel = state 7, 400 HP")
	_check(int(AIData.TYPES[7]["axis"]) == 1 and int(AIData.TYPES[58]["axis"]) == 0
		and AIData.TYPES[61]["fire"][3] == 23 and AIData.AMMO[23][1] == "ROCKET.3D",
		"turret data: smltrrt yaws, smlcanon pitches, missile pod fires rockets")
	var b := EnemyAI.new(33)
	_check(b.has_script() and b.state == 7, "endoskel carries an AIS script")
	# Not perceiving the player: the walk loop (frames 5..20) plays and
	# the hydraulic footstep (sound 60) fires on frame 8.
	var frames: Dictionary = {}
	var sounds: Dictionary = {}
	for i in 210:                               # 3 s at 70 Hz
		b.tick(EnemyAI.TICK, {"see": false, "dist": 3000.0, "bearing": 0, "angle": 0, "rand": 1000})
		frames[b.frame] = true
		for sid in b.sounds:
			sounds[sid] = true
	_check(frames.has(8) and frames.has(20), "T800 walk cycle reaches frames 8 and 20")
	_check(sounds.has(60), "footstep frame event plays sound 60 (hydra5)")
	# Player seen 300 units ahead: the script engages and reaches a
	# firing pose (anim flag 0x100) within a few seconds.
	var fired := false
	for i in 700:
		b.tick(EnemyAI.TICK, {"see": true, "dist": 300.0, "bearing": 0, "angle": 0, "rand": 1000})
		if b.firing_pose():
			fired = true
			break
	_check(fired, "T800 enters a firing pose when the player is close and seen")
	# Tank script: perceived player at 1000 u → SET speed 300 (var 48).
	var tank := EnemyAI.new(30)
	for i in 300:
		tank.tick(EnemyAI.TICK, {"see": true, "dist": 1000.0, "bearing": 0, "angle": 512})
	_check(tank.var_or(48, -1) == 300, "hvytnk script drives forward (var 48 = 300) toward a seen player")
	# HK flyer: seen player far away → altitude var 56 written.
	var hk := EnemyAI.new(4)
	for i in 300:
		hk.tick(EnemyAI.TICK, {"see": true, "dist": 3000.0, "bearing": 0, "angle": 0})
	_check(hk.vars.has(56), "hk_ftr script sets its altitude target (var 56)")

## Walk a chain with ObjFlipLink's rules (follow link_next, stop at an
## actor flag or chain end) and return the first mover entity, or null.
static func _chain_find_mover(map, start):
	var cur = start
	for hop in 8:
		if (cur.flags & 0x40) != 0 or cur.link_next < 1:
			return null
		cur = map.entities_by_off.get(cur.link_next)
		if cur == null:
			return null
		if ActionSystem.is_mover(cur.link_act_type):
			return cur
	return null
