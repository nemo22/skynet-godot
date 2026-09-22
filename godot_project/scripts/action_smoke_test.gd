## Headless smoke test for the object/link layer (phase 1).
##
##   godot --headless --path . res://scenes/action_smoke_test.tscn
##
## Loads every campaign map (regression: none may fail to load), then
## exercises the MAP.210 wiring: proximity button → BIGDOOR
## mover, GENER0 HP-depletion chain, TRANSFRM.PRS car damage stages,
## DISH rotator, and the 0xEF gate → 0xF0 teleport pair. Exits with a
## non-zero code on failure.
##
## Nothing here boots the game scene — every level is loaded straight from
## LevelLoader and every mission scene is inspected as data — so which
## runtime Settings.mission_scenes picks never reaches this suite. The two
## that do boot Main choose for themselves: game_smoke_test puts the flag
## down to keep testing the per-map runtime, mission_smoke_test plays the
## default.

extends Node

const LevelLoader := preload("res://scripts/level_loader.gd")
const Rules := preload("res://scripts/triggers/rules_skynet.gd")
const EnemyAI := preload("res://scripts/enemy_ai.gd")
const AIData := preload("res://scripts/enemy_ai_data.gd")
const LevelScene := preload("res://scripts/level_scene.gd")
const LevelBehaviour := preload("res://scripts/level_behaviour.gd")
const MissionScene := preload("res://scripts/mission_scene.gd")
const MissionCensus := preload("res://tools/mission_census.gd")
const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")
const TriggerLock := preload("res://scripts/triggers/trigger_lock.gd")
const TriggerBus := preload("res://scripts/triggers/trigger_bus.gd")
const TriggerEquiv := preload("res://scripts/triggers/trigger_equiv.gd")
const TriggerVerifier := preload("res://scripts/triggers/trigger_verifier.gd")
const MissionVerifier := preload("res://scripts/triggers/mission_verifier.gd")
const MainScript := preload("res://scripts/main.gd")

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
			% [m, level.behaviour.mover_nodes().size(), level.behaviour.wreck_nodes().size(),
			   level.behaviour.prox_nodes().size(), level.behaviour.exit_nodes().size()])
		if m == "MAP.210":
			level210 = level
	if level210 != null:
		_run_map210_checks(level210)
		_run_behaviour_checks()
		_run_transition_checks(level210)
	_run_zone_origin_checks()
	_run_ai_checks()
	_run_cache_resource_checks()
	_run_level_scene_checks()
	_run_mission_scene_checks()
	_run_trigger_lock_checks()
	_run_trigger_bus_checks()
	print("[smoke] %s (%d failures)"
		% ["ALL PASS" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

func _run_map210_checks(level: LevelLoader.Level) -> void:
	var map = level.map
	var branch: Node = level.behaviour
	var rt: RefCounted = level.triggers

	# Index entities by mesh name for lookups.
	var by_name: Dictionary = {}
	for e in map.entities:
		if (e.flags & 3) != 1:
			continue
		var nm := LevelLoader.MapFile.entity_name(map, e).to_upper()
		if not by_name.has(nm):
			by_name[nm] = []
		by_name[nm].append(e)

	_check(level.behaviour.mover_nodes().size() >= 5,
		"MAP.210 has movers registered (doors/gates/dish)")
	var exits: Array = []
	for t in branch.exit_nodes():
		exits.append(t.target_map)
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
		var node: Node3D = branch.hit_node(target.file_off)
		_check(node != null, "chained mover has a node")
		if node != null:
			var before: Transform3D = node.transform
			var far := Vector3(1e9, 0.0, 1e9)
			rt.flip(button.file_off)             # the button's chain fires
			_check(rt.enabled(target.file_off), "chain enabled the mover")
			for i in 30:                          # ~0.5 s of motion
				branch.tick(0.016, far)
			_check(node.transform != before, "mover transform is moving")
			# BIGDOOR (act 0x41/0x42, handler 0x137a28) is a sliding
			# gate leaf: the origin moves, the basis does not.
			var slid: float = node.transform.origin.distance_to(before.origin)
			_check(slid > 1.0 and node.transform.basis.is_equal_approx(before.basis),
				"BIGDOOR gate slides without rotating (%.1f u)" % slid)

	# --- 1c. Use key beside a wall button (MAP.216 tower panel): no aim
	# needed, the nearest button within reach fires its chain ---
	var l216: LevelLoader.Level = LevelLoader.new().load_level("MAP.216")
	if l216 != null:
		var btn = null
		for e in l216.map.entities:
			if (e.flags & 3) == 1 and LevelLoader.MapFile.entity_name(l216.map, e) == "BUTTON01" and e.link_act_type == 0xEF:
				btn = e
				break
		_check(btn != null, "MAP.216 has a BUTTON01 with the 0xEF act")
		if btn != null:
			var near := Vector3(float(btn.x), -float(btn.y), -float(btn.z)) + Vector3(60.0, 0.0, 40.0)
			var gate = null
			var cur = btn
			for hop in 8:
				if cur == null or cur.link_next < 1:
					break
				cur = l216.map.entities_by_off.get(cur.link_next)
				if cur != null and Rules.is_mover(cur.link_act_type):
					gate = cur
					break
			_check(gate != null and not l216.triggers.enabled(gate.file_off),
				"the tower button's gate starts disabled")
			_check(l216.behaviour.use_nearby(near), "use beside the button operates it without aiming")
			_check(gate != null and l216.triggers.enabled(gate.file_off),
				"the button's chain enabled the gate")
			_check(not l216.behaviour.use_nearby(near + Vector3(600.0, 0.0, 0.0)), "use 600 u away does nothing")

	# --- 2. GENER0: HP-gated (state bit2, hp 200) chain on destruction ---
	var gener: LevelLoader.MapFile.Entity = null
	for e in by_name.get("GENER0", []):
		if (e.state_byte & 4) != 0 and e.hp > 0:
			gener = e
			break
	_check(gener != null, "GENER0 with bit2 + HP exists")
	if gener != null:
		var next_e = map.entities_by_off.get(gener.link_next)
		var st_before: int = rt.state(next_e.file_off) if next_e != null else -1
		branch.obj_hit(gener.file_off, 50.0)
		_check(next_e == null or rt.state(next_e.file_off) == st_before,
			"GENER0 survives a 50-damage hit (no chain fire)")
		_check(branch.obj_hit(gener.file_off, 500.0),
			"GENER0 dies to the big hit and fires its chain")
		if next_e != null:
			_check(rt.state(next_e.file_off) != st_before,
				"GENER0 chain flipped its target's state")

	# --- 3. Destructible car: TRANSFRM.PRS stage swap on damage ---
	var car: LevelLoader.MapFile.Entity = null
	for nm in by_name:
		if nm.begins_with("CARHIP") or nm.begins_with("COPCAR"):
			for e in by_name[nm]:
				# The stages are the record's own node's since step 5g.
				var w: Node = level.behaviour.wreck_node(e.file_off)
				if w != null and (w.get("meshes") as Array).size() > 1 \
						and (e.state_byte & 6) != 0:
					car = e
					break
		if car != null:
			break
	_check(car != null, "damageable TRANSFRM.PRS car exists")
	if car != null:
		var cnode: MeshInstance3D = branch.hit_node(car.file_off)
		var mesh_before: Mesh = cnode.mesh
		# One hit, one stage — the DOS handler is told nothing about how
		# hard the blow was (0x120833), so the 20 points only matter to
		# the car's hit points.
		branch.obj_hit(car.file_off, 20.0)
		_check(cnode.mesh != mesh_before,
			"car mesh swapped one damage stage on one hit")

	# --- 4. DISH (act 0x3b) rotates from load (state bit0 set) ---
	var dish: LevelLoader.MapFile.Entity = null
	for e in by_name.get("DISH", []):
		if e.link_act_type == 0x3b and (e.state_byte & 1) != 0:
			dish = e
			break
	_check(dish != null, "armed DISH rotator exists")
	if dish != null:
		var dnode: Node3D = branch.hit_node(dish.file_off)
		var db: Transform3D = dnode.transform
		branch.tick(0.1, Vector3(1e9, 0, 1e9))    # player far away
		_check(dnode.transform != db, "DISH rotates while enabled")

	# --- 5. 0xEF gate + 0xF0 teleport (chained via a sound node) ---
	branch.teleport_requested.connect(_on_teleport)
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
		branch.tick(0.016, gpos)                  # gate arms the teleport
		branch.tick(0.016, gpos)
		_check(_teleport_seen.is_empty(), "an armed exit does not fire by itself")
		branch.activate_teleport(gpos)            # the use key fires it
		_check(_teleport_seen.size() == 1
			and _teleport_seen[0][0] in [211, 212, 213, 214, 218],
			"use key fires the armed exit once → map %s" % str(_teleport_seen))

	# --- 5b. Standing ON THE FLOOR in a doorway ---------------------
	# A doorway sprite hangs above the floor the player walks on, so the
	# touch test has to allow that height difference. Measuring it in 3D
	# put MAP.210's truck out of reach entirely ("neviem sa dostať do
	# toho nákladiaku", playtest 2026-09-12) — and the check above missed it
	# because it fires the exit from the sprite's own position.
	var truck: Node = null
	for t in branch.exit_nodes():
		if t.target_map == 212:
			truck = t
			break
	_check(truck != null, "MAP.210 has the truck's exit to MAP.212")
	if truck != null:
		_teleport_seen.clear()
		branch.exit_refused()
		var tpos: Vector3 = truck.position
		var feet: Vector3 = tpos - Vector3(0.0, 60.0, 0.0)
		branch.tick(0.016, feet)
		branch.tick(0.016, feet)
		_check(branch.activate_teleport(feet)
			and _teleport_seen.size() == 1 and _teleport_seen[0][0] == 212,
			"the use key enters the truck from the floor below its doorway (%s)"
			% str(_teleport_seen))

func _on_teleport(target_map: int, marker_set: int) -> void:
	_teleport_seen.append([target_map, marker_set])

## F2 — the chain walk runs on the Behaviour nodes and the cues fire
## from there; 0x1B demolition.
func _run_behaviour_checks() -> void:
	# MAP.217: the HUMMERTK carries mission 1's last objective (act 0x28)
	# and eight 0xEF gates ring it. Tripping one fires the objective from
	# its node, once; a second gate flips a spent cue and nothing happens;
	# its act byte is retired the way DOS does it (act 0xFF) — in the
	# trigger runtime, which is where the bytes play changes live.
	var l217: LevelLoader.Level = LevelLoader.new().load_level("MAP.217")
	_check(l217 != null and l217.behaviour != null and l217.triggers != null
		and l217.behaviour.runtime == l217.triggers
		and l217.triggers.presenter == l217.behaviour,
		"MAP.217 loads with one trigger runtime and its branch, each holding the other")
	if l217 != null and l217.behaviour != null:
		var seen: Array = []
		l217.behaviour.objective_complete.connect(func(i: int) -> void: seen.append(i))
		var target = null
		for e in l217.map.entities:
			if (e.flags & 3) == 1 and e.marker_type < 0 and e.link_act_type == 0x28:
				target = e
		_check(target != null, "MAP.217 carries the [M3] objective (act 0x28) on a mesh")
		var gates: Array = []
		# The gates are their own nodes now (step 5c): the branch keeps the
		# list the handlers run for, and the record says where each one is.
		for pn in l217.behaviour.prox_nodes():
			var g = l217.behaviour.record_of(int(pn.id))
			if g.link_act_type != 0xEF:
				continue
			var cur = g
			for hop in 8:
				if cur == null or cur.link_next < 1:
					break
				cur = l217.map.entities_by_off.get(cur.link_next)
				if cur == target:
					gates.append(g)
					break
		_check(gates.size() >= 2, "%d proximity gates chain to the objective" % gates.size())
		if target != null and gates.size() >= 2:
			var g0 = gates[0]
			l217.behaviour.press_use()                  # DOS: a gate answers the use key
			l217.behaviour.tick(0.016, Vector3(float(g0.x), -float(g0.y), -float(g0.z)))
			_check(seen == [2], "tripping a gate fires objective [M3] from its node (%s)" % str(seen))
			_check(l217.triggers.act(target.file_off) == 0xFF
				and not l217.triggers.enabled(target.file_off),
				"the objective is retired (act 0xFF, bit 0 clear)")
			var g1 = gates[1]
			var p1 := Vector3(float(g1.x), -float(g1.y), -float(g1.z))
			l217.behaviour.tick(0.016, p1 + Vector3(9000.0, 0.0, 0.0))
			l217.behaviour.press_use()
			l217.behaviour.tick(0.016, p1)
			_check(seen == [2], "a second gate cannot fire the spent objective (%s)" % str(seen))

	# The same eight gates, but from where the player actually stands: they
	# ring the jeep about 90 units out, 39 to 78 units apart, and the DOS
	# gate reaches 60 + 26. Walk up to the jeep and FOUR of them are inside
	# it at once — an even number, all flipping the one [M3] record. If the
	# flips were collected and the handlers run afterwards, four toggles
	# would put the bit back where it started and mission 1 could never be
	# finished. DOS runs each handler as ObjFlipLink flips it (the graph's
	# even_fan_in warning on MAP.217 @075cb is exactly this spot), so the
	# first flip counts the objective and retires the record to 0xFF and
	# the other three flip something inert.
	var ljeep: LevelLoader.Level = LevelLoader.new().load_level("MAP.217")
	if ljeep != null and ljeep.behaviour != null:
		var jeep = ljeep.map.entities_by_off.get(0x075cb)
		_check(jeep != null and jeep.link_act_type == 0x28,
			"MAP.217's jeep carries [M3] on @075cb")
		if jeep != null:
			var eye := Vector3(float(jeep.x), -float(jeep.y), -float(jeep.z))
			var reach: float = Rules.PROX_GATE_RADIUS + Rules.PLAYER_RADIUS
			var inside: int = 0
			for pn in ljeep.behaviour.prox_nodes():
				var g = ljeep.behaviour.record_of(int(pn.id))
				if g.link_act_type == 0xEF and g.link_next == jeep.file_off \
						and eye.distance_to(Vector3(float(g.x), -float(g.y), -float(g.z))) <= reach:
					inside += 1
			_check(inside >= 2, "%d of the eight gates are within %.0f u of the jeep (%s)"
				% [inside, reach, "an even number — the cancelling case" if inside % 2 == 0 else "odd"])
			var fired: Array = []
			ljeep.behaviour.objective_complete.connect(func(i: int) -> void: fired.append(i))
			ljeep.behaviour.press_use()
			ljeep.behaviour.tick(0.016, eye - Vector3(0.0, 75.0, 0.0), eye)
			_check(fired == [2], "%d gates flipping in one tick count [M3] once (%s)"
				% [inside, str(fired)])
			_check(ljeep.triggers.act(jeep.file_off) == 0xFF
				and not ljeep.triggers.enabled(jeep.file_off),
				"…and leave it retired, not toggled back down (act %02x st %02x)"
				% [ljeep.triggers.act(jeep.file_off), ljeep.triggers.state(jeep.file_off)])

	# MAP.213: a crate with the "act on death" bit (state 04) chains to
	# the crate stacked on it, whose act 0x1B means "demolished by the
	# chain". The prop is not a proximity gate (the 0xEF handler skips
	# state & 6 == 4), and shooting it to pieces takes the top crate too.
	var l213: LevelLoader.Level = LevelLoader.new().load_level("MAP.213")
	if l213 != null:
		var base = null
		var top = null
		for e in l213.map.entities:
			if (e.flags & 3) == 1 and e.link_act_type == 0xEF and (e.state_byte & 6) == 4 and e.link_next > 0:
				var t = l213.map.entities_by_off.get(e.link_next)
				if t != null and t.link_act_type == 0x1B \
						and l213.behaviour.hit_node(t.file_off) != null:
					base = e
					top = t
					break
		_check(base != null, "MAP.213 has a crate whose death chain demolishes the crate on it")
		if base != null:
			var bnode = l213.behaviour.prox_node(base.file_off)
			_check(bnode != null and not l213.behaviour.prox_nodes().has(bnode),
				"a state-04 0xEF prop has a node and is on no proximity sweep")
			var tnode: Node3D = l213.behaviour.hit_node(top.file_off)
			l213.behaviour.obj_hit(base.file_off, 500.0)
			l213.behaviour.tick(0.016, Vector3(1e9, 0.0, 1e9))
			_check(l213.triggers.spent(top.file_off) and not tnode.visible,
				"0x1B: the stacked crate is demolished with the one shot")

	# MAP.210: the 0xF1 lever at the canyon exit opens BIGDOOR, the 0xF2
	# behind the gate runs the SAME chain and closes it (the DOS run,
	# 2026-09-11). The mover clears its bit on arrival; the chain walk
	# used to read the node's stale copy, flip 1 → 0 and never move again.
	var l210: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210 != null:
		var far := Vector3(1e9, 0.0, 1e9)
		var lever_a = l210.map.entities_by_off.get(0x77f3)
		var lever_b = l210.map.entities_by_off.get(0x7851)
		var door = _chain_find_mover(l210.map, lever_a) if lever_a != null else null
		_check(lever_a != null and lever_a.link_act_type == 0xF1
			and lever_b != null and lever_b.link_act_type == 0xF2 and door != null,
			"MAP.210 has the canyon lever (0xF1), the lever behind the gate (0xF2) and BIGDOOR")
		if door != null and lever_b != null:
			l210.triggers.flip(lever_a.file_off)
			_check(l210.triggers.enabled(door.file_off), "the canyon lever sets the gate moving")
			for i in 900:
				if not l210.triggers.enabled(door.file_off):
					break
				l210.behaviour.tick(0.016, far)
			_check(not l210.triggers.enabled(door.file_off), "the gate stops when it is fully open")
			l210.triggers.flip(lever_b.file_off)
			var m: Node = l210.behaviour.mover_node(door.file_off)
			_check(l210.triggers.enabled(door.file_off) and m != null and float(m.dir) < 0.0,
				"the lever behind the gate runs it back — it closes")

	# MAP.232: the nine consoles bring the objective counter to 1; then
	# the 0x2C relay 232MAIN fires its chain once — seven hidden robots
	# (0xF3) appear and the stuck door 232DOOR6 (0x1B) gives.
	var l232: LevelLoader.Level = LevelLoader.new().load_level("MAP.232")
	if l232 != null:
		var far2 := Vector3(1e9, 0.0, 1e9)
		var relay = l232.map.entities_by_off.get(0x598d)
		# The relay and the spawn sprites run on their own Behaviour nodes
		# since step 5d; the robots waiting at them are asked of the branch.
		var spawns: Dictionary = l232.behaviour.spawn_enemies()
		var hidden: int = 0
		for off in spawns:
			if spawns[off].is_hidden():
				hidden += 1
		_check(relay != null and relay.link_act_type == 0x2C
			and l232.triggers.enabled(relay.file_off),
			"MAP.232 has the armed 0x2C relay 232MAIN")
		_check(spawns.size() >= 7 and hidden == spawns.size(),
			"the 0xF3 spawn robots are built hidden (%d of %d)" % [hidden, spawns.size()])
		if relay != null:
			l232.behaviour.objectives_left = 2
			l232.behaviour.tick(0.016, far2)
			_check(l232.triggers.enabled(relay.file_off),
				"the relay waits while two objectives are left")
			l232.behaviour.objectives_left = 1
			l232.behaviour.tick(0.016, far2)
			l232.behaviour.tick(0.016, far2)
			var out: int = 0
			for off in spawns:
				if not spawns[off].is_hidden():
					out += 1
			_check(not l232.triggers.enabled(relay.file_off),
				"at one objective left the relay fires and switches off")
			_check(out >= 7, "the relay's chain lets the robots out (%d)" % out)
			_check(l232.triggers.spent(0x3512), "232DOOR6 gives way")

	# MAP.210: the cargo truck (type 46, AI state 11) stands still until
	# the lever @0c084 flips its path markers on; then it drives its path
	# into the base (handler 0x127400: segment speed 0.3125 × length).
	var l210b: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210b != null:
		var truck = l210b.map.entities_by_off.get(0x78d3)
		var lever = l210b.map.entities_by_off.get(0xc084)
		# The vehicles drive from their own Behaviour nodes since step 5f.
		var v: Node = l210b.behaviour.vehicle_node(0x78d3)
		_check(truck != null and truck.marker_type == 2 and truck.enemy_type == 46
			and truck.link_next > 0 and v != null,
			"MAP.210's cargo truck is a path vehicle with a path")
		if v != null and lever != null:
			var tnode: Node3D = v.actor
			var at: Vector3 = tnode.position         # DOS ticks it near the player
			var before: Vector3 = at
			for i in 30:
				l210b.behaviour.tick(0.05, at)
			# DOS takes the segment speed on the vehicle's FIRST tick without
			# looking at the bit, so it creeps under a unit before the next
			# tick brakes it — anything more means the path is running.
			_check(tnode.position.distance_to(before) < 5.0,
				"the truck waits while its path is switched off (%.1f u)"
				% tnode.position.distance_to(before))
			l210b.triggers.flip(lever.file_off)
			var head = l210b.map.entities_by_off.get(truck.link_next)
			_check(head != null and l210b.triggers.enabled(head.file_off),
				"the lever switches the truck's path on")
			for i in 60:
				l210b.behaviour.tick(0.05, tnode.position)
			_check(tnode.position.distance_to(before) > 80.0,
				"the truck drives its path (%.0f u in 3 s)"
				% tnode.position.distance_to(before))

	# MAP.234: the HK's path markers are already on, so it flies the
	# moment the map loads, and the end of its path flips CHUNK3 — act
	# 0x27, mission 3's [M2] — before it comes to a hover.
	var l234: LevelLoader.Level = LevelLoader.new().load_level("MAP.234")
	if l234 != null:
		var hk_off: int = -1
		for n in l234.behaviour.vehicle_nodes():
			hk_off = int(n.id)
			break
		_check(hk_off >= 0, "MAP.234 has the pick-up HK as a path vehicle")
		if hk_off >= 0:
			var hnode: Node3D = l234.behaviour.vehicle_node(hk_off).actor
			var hstart: Vector3 = hnode.position
			var m2: Array = []
			if l234.behaviour != null:
				l234.behaviour.objective_complete.connect(
					func(i: int) -> void: m2.append(i))
			for i in 400:                            # ~20 s of flight
				l234.behaviour.tick(0.05, hnode.position)
			_check(hnode.position.distance_to(hstart) > 200.0,
				"the HK flies without anything switching it on (%.0f u)"
				% hnode.position.distance_to(hstart))
			_check(m2 == [1], "the end of the HK's path fires [M2] (%s)" % str(m2))

	# The same HK, but watched from where the PLAYER stands: DOS ticks the
	# actors in the 5×5 grid cells around him, and a cell is 1024 units,
	# so a machine 1200 units off still runs. The port's window was one
	# cell wide, so the HK never started in the game — the check above
	# missed it because it ticks with the player right beside the HK
	# ("na strechu malo prísť HK a nepriletelo", playtest 2026-09-12).
	var l234b: LevelLoader.Level = LevelLoader.new().load_level("MAP.234")
	if l234b != null and not l234b.behaviour.vehicle_nodes().is_empty():
		var hn2: Node3D = (l234b.behaviour.vehicle_nodes()[0] as Node).get("actor")
		var from2: Vector3 = hn2.position
		var watcher: Vector3 = from2 + Vector3(1200.0, 0.0, 0.0)
		for i in 60:
			l234b.behaviour.tick(0.05, watcher)
		_check(hn2.position.distance_to(from2) > 100.0,
			"the HK starts with the player 1200 u away (%.0f u in 3 s)"
			% hn2.position.distance_to(from2))

	# MAP.233: the Cyberdyne lift. 231EL carries act 0xa6, which belongs
	# to the DOS SLIDE handler (p4=1, p6=688) — it RISES 688 units to the
	# roof. The port had 0xa5/0xa6 among the rotators, so the lift turned
	# on the spot instead of going up.
	var l233: LevelLoader.Level = LevelLoader.new().load_level("MAP.233")
	if l233 != null:
		var lift = l233.map.entities_by_off.get(0x3ce9)
		_check(lift != null and lift.link_act_type == 0xa6,
			"MAP.233's 231EL is the 0xa6 lift")
		var lnode: Node3D = l233.behaviour.hit_node(0x3ce9) if lift != null else null
		if lift != null and lnode != null:
			var before: Transform3D = lnode.transform
			l233.triggers.flip(lift.file_off)
			for i in 60:
				l233.behaviour.tick(0.05, Vector3(1e9, 0.0, 1e9))
			var moved: Vector3 = lnode.transform.origin - before.origin
			_check(moved.y > 20.0 and lnode.transform.basis.is_equal_approx(before.basis),
				"the lift rises without turning (%.0f u up, %.0f aside)"
				% [moved.y, Vector2(moved.x, moved.z).length()])

	# MAP.260: the town's invisible fence is a PAIR of type-30 markers,
	# the convoy is nine path vehicles whose type byte carries bit 7 (the
	# parser used to read it unmasked, so they never appeared at all), and
	# the car-wash door is the 60-HP thing the jeep rams through.
	var l260: LevelLoader.Level = LevelLoader.new().load_level("MAP.260")
	if l260 != null:
		_check(l260.border_boxes.size() == 1,
			"MAP.260 has one border box (%d)" % l260.border_boxes.size())
		if l260.border_boxes.size() == 1:
			var b: Rect2 = l260.border_boxes[0]
			_check(absf(b.position.x - 14208.0) < 1.0 and absf(b.end.x - 64378.0) < 1.0
				and absf(b.position.y + 27880.0) < 1.0 and absf(b.end.y + 4898.0) < 1.0,
				"the box covers the town and the inner lane (%s)" % str(b))
		var conv: int = 0
		for e in l260.map.entities:
			if (e.flags & 3) == 3 and e.marker_type == 2 and e.convoy:
				conv += 1
		_check(conv == 9, "nine convoy markers carry the 0x80 type bit (%d)" % conv)
		_check(l260.behaviour.vehicle_nodes().size() == 9,
			"the convoy is built as nine path vehicles (%d)"
			% l260.behaviour.vehicle_nodes().size())
		var door = null
		for e in l260.map.entities:
			if (e.flags & 3) == 1 and e.hp > 0 \
					and LevelLoader.MapFile.entity_name(l260.map, e) == "CWDOOR":
				door = e
				break
		_check(door != null and door.hp == 60
			and l260.behaviour.is_damageable(door.file_off),
			"the car-wash door has 60 HP and takes damage")
		# The mission end: BUTTONX @14fb6 (0xF2, radius 1024) measures from
		# the EYE, as DOS 0x1379c4 does — the port measured from the body,
		# 75 u lower, and the jeep could drive past it (playtest 2026-09-15).
		# Body 1034.5 u away, eye 1015.2 u.
		var bx = l260.map.entities_by_off.get(0x14fb6)
		_check(bx != null and bx.link_act_type == 0xF2 and l260.triggers.enabled(bx.file_off),
			"MAP.260 has the armed mission-end BUTTONX (0xF2)")
		if bx != null and l260.behaviour != null:
			var m1: Array = []
			l260.behaviour.objective_complete.connect(func(i: int) -> void: m1.append(i))
			var feet: Vector3 = Vector3(float(bx.x), -float(bx.y), -float(bx.z)) + Vector3(990.0, -300.0, 0.0)
			l260.behaviour.tick(0.016, feet)
			_check(l260.triggers.enabled(bx.file_off) and m1.is_empty(),
				"BUTTONX waits while the point measured from is 1034 u off")
			l260.behaviour.tick(0.016, feet, feet + Vector3(0.0, 75.0, 0.0))
			_check(not l260.triggers.enabled(bx.file_off) and m1 == [0],
				"from the eye, 1015 u off, it fires and its chain counts [M1] (%s)" % str(m1))

	# MAP.254 (the flooded sewers): acts 0xd6-0xda move the water level.
	# 254HOLE1 drains it by 140, CATWLK16 floods it by 170 ("Oops.") and
	# the valve maze's 0xd9/0xda pair swaps its own act each time, so it
	# raises and lowers in turn. The bits are set by hand here — what is
	# under test is the sweep, not the chains that reach it.
	var l254: LevelLoader.Level = LevelLoader.new().load_level("MAP.254")
	if l254 != null:
		var far3 := Vector3(1e9, 0.0, 1e9)
		var asked: Array = []
		# The movers are Behaviour nodes since step 5d and ask for the new
		# height on the branch's own signal.
		l254.behaviour.water_level.connect(
			func(v: float, absolute: bool) -> void: asked.append([v, absolute]))
		var hole = l254.map.entities_by_off.get(0x6eca)
		var walk = l254.map.entities_by_off.get(0x92cd)
		var valve = l254.map.entities_by_off.get(0x65af)
		_check(hole != null and hole.link_act_type == 0xd8
			and walk != null and walk.link_act_type == 0xd7,
			"MAP.254 has the sewer's water movers (0xd8 drains, 0xd7 floods)")
		if hole != null and walk != null:
			l254.triggers.arm(hole.file_off)
			l254.behaviour.tick(0.016, far3)
			l254.triggers.arm(walk.file_off)
			l254.behaviour.tick(0.016, far3)
			_check(asked == [[-140.0, false], [170.0, false]],
				"the movers ask for -140, then +170 (%s)" % str(asked))
			_check(not l254.triggers.enabled(hole.file_off)
				and not l254.triggers.enabled(walk.file_off),
				"a water mover switches itself off after it fires")
		if valve != null and (valve.link_act_type == 0xd9 or valve.link_act_type == 0xda):
			var was_act: int = valve.link_act_type
			l254.triggers.arm(valve.file_off)
			l254.behaviour.tick(0.016, far3)
			var now_act: int = l254.triggers.act(valve.file_off)
			_check(now_act != was_act and (now_act == 0xd9 or now_act == 0xda),
				"the valve's 0x%02x becomes 0x%02x — next time it goes the other way"
				% [was_act, now_act])

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
		for t in l218.behaviour.exit_nodes():
			ret.append([t.target_map, t.marker_set])
		_check(ret == [[0, 27]], "MAP.218 return exit → previous map, marker 27 (%s)" % str(ret))
	_check(level210.markers.has(27) and level210.markers.has(28),
		"MAP.210 carries the return markers 27 + 28")

	# State overlay: the GENER0 spent in the map-210 checks survives a
	# save → fresh parse → restore round trip.
	var snap: Dictionary = level210.triggers.snapshot()
	var spent_offs: Array = snap["spent"].keys()
	_check(not spent_offs.is_empty(), "the snapshot captures spent entities")
	_check(snap.has("movers") and snap.has("destr") and snap.has("spawned"),
		"…and what the nodes remember for themselves (plan §4: one TriggerState)")
	var l210b: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210b != null and not spent_offs.is_empty():
		var off: int = spent_offs[0]
		_check(not l210b.triggers.spent(off), "fresh MAP.210 parse starts unspent")
		l210b.triggers.restore(snap)
		_check(l210b.triggers.spent(off), "restore re-applies the spent flag")
		_check(l210b.triggers.state(off) == int(snap["states"][off]),
			"restore re-applies entity state bytes")
		_check(String(snap.get("graph_sha", "")) == l210b.triggers.graph_sha()
			and (snap.get("sigs", {}) as Dictionary).has(off),
			"the overlay says which map file it was taken against, and vouches for the records it changed")
		# The same overlay against ANOTHER map file (a mod, another release
		# of the data): a file offset is no longer a promise, so only the
		# records whose recorded signature still stands are laid back and
		# the rest keep what the map has (plan §4, migration step 5i).
		var l210d: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
		if l210d != null:
			var foreign: Dictionary = snap.duplicate(true)
			foreign["graph_sha"] = "another map file"
			(foreign["sigs"] as Dictionary)[off] = "a record that moved"
			var other_off: int = -1
			for o in (foreign["sigs"] as Dictionary):
				var id: int = int(o)
				var rec = l210d.triggers.record(id)
				if id != off and rec != null and (foreign["states"] as Dictionary).has(id) \
						and int(foreign["states"][id]) != int(rec.state_byte):
					other_off = id
					break
			l210d.triggers.restore(foreign)
			_check(not l210d.triggers.spent(off),
				"an overlay from another map file leaves the record whose signature moved as the file has it")
			_check(other_off < 0 or l210d.triggers.state(other_off) == int(foreign["states"][other_off]),
				"…and still lays back the records that are the same (@%05x)" % other_off)

	# Doorway touch: standing on a 0xF0 exit sprite arms it directly.
	var l210c: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210c != null:
		var seen: Array = []
		l210c.behaviour.teleport_requested.connect(
			func(m: int, s: int) -> void: seen.append([m, s]))
		var ex = l210c.behaviour.exit_nodes()[0]
		var epos: Vector3 = ex.position
		l210c.behaviour.tick(0.016, epos)
		l210c.behaviour.activate_teleport(epos)
		_check(seen.size() == 1 and seen[0][0] == ex.target_map,
			"touching a doorway sprite arms it; the use key fires it once (%s)" % str(seen))
		l210c.behaviour.tick(0.016, epos)
		l210c.behaviour.activate_teleport(epos)
		_check(seen.size() == 1, "a fired level never teleports twice")

	# Spawn-inside latch: arm_proximity at the doorway keeps the chain
	# unflipped (no door sound, no auto-arm) — but the use key still goes
	# through the gate the player stands in (the truck interiors spawn
	# beside their DOOR gate, and "press use at the door" must work).
	var l210d: LevelLoader.Level = LevelLoader.new().load_level("MAP.210")
	if l210d != null:
		var seen2: Array = []
		l210d.behaviour.teleport_requested.connect(
			func(m: int, s: int) -> void: seen2.append([m, s]))
		var ex2 = l210d.behaviour.exit_nodes()[0]
		var epos2: Vector3 = ex2.position
		l210d.behaviour.arm_proximity(epos2)
		l210d.behaviour.tick(0.016, epos2)
		_check(not l210d.triggers.enabled(int(ex2.id)),
			"spawning on a doorway does not arm it by itself")
		l210d.behaviour.activate_teleport(epos2)
		_check(seen2.size() == 1, "use at the doorway fires it even when the spawn pre-latched its gate")
		l210d.behaviour.tick(0.016, epos2 + Vector3(2000.0, 0.0, 0.0))
		l210d.behaviour.tick(0.016, epos2)
		l210d.behaviour.activate_teleport(epos2)
		_check(seen2.size() == 1, "a fired doorway never fires again in the same level")

## M2 step 1/2 — a level loaded as a ZONE, away from the world origin.
##
## A mission scene stands several DOS maps side by side, each in its own
## +X slot (docs/m2_mission_scene_plan.md). The records stay in DOS
## coordinates whatever the slot; the level's branch nodes carry the
## offset, and every world position handed to the branch has it
## taken off again. So the same script must play out identically at the
## origin and 200 000 units away — and a position given in the zone's own
## local coordinates must reach nothing at all.
const ZONE_ORIGIN := Vector3(200000.0, 0.0, 0.0)
## MAP.210's jeep, DOS (58096, -1207, 54000) → zone-local Godot.
const ZONE_PROBE_LOCAL := Vector3(58096.0, 1207.0, -54000.0)

func _run_zone_origin_checks() -> void:
	var lz: LevelLoader.Level = LevelLoader.new().load_zone("MAP.210", ZONE_ORIGIN)
	_check(lz != null and lz.origin == ZONE_ORIGIN
		and lz.behaviour != null and lz.behaviour.zone_origin == ZONE_ORIGIN,
		"MAP.210 loads as a zone standing at %s" % str(ZONE_ORIGIN))
	if lz == null:
		return
	var branches: Array = [lz.terrain, lz.entities, lz.enemies, lz.sprites, lz.behaviour]
	var off_branches: int = 0
	for b in branches:
		if b is Node3D and (b as Node3D).position.is_equal_approx(ZONE_ORIGIN):
			off_branches += 1
	_check(off_branches == branches.size(),
		"all %d branches stand at the zone origin (%d do)" % [branches.size(), off_branches])

	# A known mesh keeps its DOS transform inside the zone and lands at
	# the DOS position plus the origin in the world.
	var probe: Node3D = _child_at(lz.entities, ZONE_PROBE_LOCAL)
	_check(probe != null, "the jeep mesh keeps its DOS position %s inside the zone"
		% str(ZONE_PROBE_LOCAL))
	if probe != null:
		add_child(lz.entities)
		var want: Vector3 = ZONE_PROBE_LOCAL + ZONE_ORIGIN
		_check(probe.global_position.is_equal_approx(want),
			"…and stands at %s in the world (%s)" % [str(want), str(probe.global_position)])
		remove_child(lz.entities)

	# The doorway/use path, driven from the world: nothing answers a
	# zone-local point, and the world point behaves as at the origin
	# (the same sequence as the transition checks run on a lone map).
	if not lz.behaviour.exit_nodes().is_empty():
		var seen: Array = []
		lz.behaviour.teleport_requested.connect(
			func(m: int, s: int) -> void: seen.append([m, s]))
		var ex = lz.behaviour.exit_nodes()[0]
		var elocal: Vector3 = ex.position
		lz.behaviour.arm_proximity(elocal)
		lz.behaviour.tick(0.016, elocal)
		_check(seen.is_empty() and not lz.behaviour.activate_teleport(elocal),
			"a zone-local point is %.0f k units from the doorway and reaches nothing"
			% (ZONE_ORIGIN.length() / 1000.0))
		lz.behaviour.arm_proximity(elocal + ZONE_ORIGIN)
		lz.behaviour.tick(0.016, elocal + ZONE_ORIGIN)
		_check(not lz.triggers.enabled(int(ex.id)),
			"spawning on the doorway does not arm it by itself, in a zone either")
		lz.behaviour.activate_teleport(elocal + ZONE_ORIGIN)
		_check(seen.size() == 1,
			"use at the doorway's WORLD position fires the exit (%s)" % str(seen))

	# The proximity gate → objective chain, played out at the origin and
	# in the zone: same script, same outcome.
	var at_zero: Dictionary = _zone_gate_setup(Vector3.ZERO)
	var at_slot: Dictionary = _zone_gate_setup(ZONE_ORIGIN)
	_check(not at_zero.is_empty() and not at_slot.is_empty(),
		"MAP.217's objective gate is found both at the origin and in a zone")
	if at_zero.is_empty() or at_slot.is_empty():
		return
	var zl: LevelLoader.Level = at_slot["level"]
	zl.behaviour.press_use()
	zl.behaviour.tick(0.016, at_slot["local"])
	_check((at_slot["seen"] as Array).is_empty(),
		"the use key at the gate's zone-local point fires nothing (%s)"
		% str(at_slot["seen"]))
	for run in [at_zero, at_slot]:
		(run["level"] as LevelLoader.Level).behaviour.press_use()
		(run["level"] as LevelLoader.Level).behaviour.tick(0.016, run["at"])
	_check(at_zero["seen"] == [2] and at_slot["seen"] == [2],
		"the gate fires the objective at the origin (%s) and in the zone (%s)"
		% [str(at_zero["seen"]), str(at_slot["seen"])])
	var t0 = at_zero["target"]
	var t1 = at_slot["target"]
	var a0 = (at_zero["level"] as LevelLoader.Level).triggers
	var a1 = (at_slot["level"] as LevelLoader.Level).triggers
	_check(a0.act(t0.file_off) == 0xFF and a1.act(t1.file_off) == 0xFF
		and not a0.enabled(t0.file_off) and not a1.enabled(t1.file_off),
		"both objectives retire the same way (act %02x / %02x)"
		% [a0.act(t0.file_off), a1.act(t1.file_off)])

## The direct child of `root` whose own (zone-local) position is `at`.
func _child_at(root: Node, at: Vector3) -> Node3D:
	if root == null:
		return null
	for c in root.get_children():
		if c is Node3D and (c as Node3D).position.is_equal_approx(at):
			return c as Node3D
	return null

## MAP.217 in a zone at `origin`: the level, the 0xEF gate that chains to
## the objective mesh, that record, the list its signal fills, and the
## gate's position in both spaces. Empty when the map has no such pair.
func _zone_gate_setup(origin: Vector3) -> Dictionary:
	var lvl: LevelLoader.Level = LevelLoader.new().load_zone("MAP.217", origin)
	if lvl == null or lvl.behaviour == null:
		return {}
	var seen: Array = []
	lvl.behaviour.objective_complete.connect(func(i: int) -> void: seen.append(i))
	var target = null
	for e in lvl.map.entities:
		if (e.flags & 3) == 1 and e.marker_type < 0 and e.link_act_type == 0x28:
			target = e
	if target == null:
		return {}
	for pn in lvl.behaviour.prox_nodes():
		var g = lvl.behaviour.record_of(int(pn.id))
		if g.link_act_type != 0xEF:
			continue
		var cur = g
		for hop in 8:
			if cur == null or cur.link_next < 1:
				break
			cur = lvl.map.entities_by_off.get(cur.link_next)
			if cur == target:
				var local := Vector3(float(g.x), -float(g.y), -float(g.z))
				return {"level": lvl, "gate": g, "target": target, "seen": seen,
					"local": local, "at": local + origin}
	return {}

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

## What every baked scene stands on: the cache files it references have
## to carry their own data on disk, not just in the memory of the process
## that made them. (Kept from the editor map-scene checks, which went with
## that pipeline — the invariant is the cache's, not theirs.)
func _run_cache_resource_checks() -> void:
	var tp: String = Assets.texture(302, 17, false).resource_path
	var fresh: Texture2D = ResourceLoader.load(tp, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(fresh != null and fresh.get_width() > 0 and fresh.get_height() > 0,
		"cached texture reloads from disk with pixels (%s %s)"
			% [tp, str(fresh.get_size()) if fresh else "null"])
	var mesh_res: ArrayMesh = ResourceLoader.load(
		Assets.mesh("BIGDOOR.3D").resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var mat: BaseMaterial3D = mesh_res.surface_get_material(0) if mesh_res else null
	_check(mat != null and mat.albedo_texture != null
		and mat.albedo_texture.resource_path.begins_with(Assets.root + "/")
		and mat.albedo_texture.resource_path.contains("/tex/")
		and mat.albedo_texture.get_width() > 0,
		"cached mesh references a cache texture file (%s)"
			% (mat.albedo_texture.resource_path if mat and mat.albedo_texture else "none"))

## F1 (docs/map_format_plan.md) — the baked level scene carries the
## map's behaviour as nodes (scripts/level_behaviour.gd). MAP.216, the
## base after the truck ride with its BIGDOOR gates: it bakes, the node
## counts match the census, every gate is a Mover with its mesh and a
## "move" animation, every chain link resolves to a node, and each
## mover's animation ends (and passes its midpoint) exactly where
## the running mover drives the same record.
func _run_level_scene_checks() -> void:
	# A fresh bake every run: this is the code under test.
	var sp: String = LevelScene.scene_path("MAP.216")
	if not sp.is_empty() and ResourceLoader.exists(sp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))
	var p: String = Assets.level_scene("MAP.216")
	_check(not p.is_empty() and ResourceLoader.exists(p), "MAP.216 level scene baked (%s)" % p)
	if p.is_empty() or not ResourceLoader.exists(p):
		return
	var ps: PackedScene = ResourceLoader.load(p, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var root: Node = ps.instantiate() if ps != null else null
	_check(root != null and int(root.get("bake_version")) == LevelScene.BAKE_VERSION,
		"the scene is a v%d bake" % LevelScene.BAKE_VERSION)
	if root == null:
		return
	var beh: Node = root.get_node_or_null("Behaviour")
	_check(beh != null, "the level scene has a Behaviour branch")
	if beh == null:
		root.free()
		return

	# The records, classified the way the bake classified them.
	var loader := LevelLoader.new()
	loader.use_baked = false
	var level: LevelLoader.Level = loader.load_level("MAP.216")
	var expected: Dictionary = LevelBehaviour.census(level.map, level.transfrm)
	var total: int = 0
	var mismatch: Array = []
	for kind in LevelBehaviour.KINDS:
		var want: int = int(expected.get(kind, 0))
		total += want
		var c: Node = beh.get_node_or_null(String(LevelBehaviour.CONTAINER[kind]))
		var got: int = c.get_child_count() if c != null else 0
		if got != want:
			mismatch.append("%s %d != %d" % [kind, got, want])
	_check(mismatch.is_empty(), "node counts match the census %s%s"
		% [str(expected), "" if mismatch.is_empty() else " — " + ", ".join(mismatch)])
	_check(int(root.get("behaviour_count")) == total and total > 0,
		"root.behaviour_count = %d" % total)
	var mission: Node = beh.get_node_or_null("Mission")
	_check(mission != null and int(mission.get("key")) == 210 and int(mission.get("objectives_total")) == 3,
		"MAP.216 carries mission 210 with 3 objectives")

	# Every mover record is a Mover with its mesh and its animation; every
	# BIGDOOR gate leaf among them.
	var by_id: Dictionary = {}
	var movers: Node = beh.get_node_or_null("Movers")
	if movers != null:
		for m in movers.get_children():
			by_id[int(m.get("id"))] = m
	var mover_ents: Array = []
	for e in level.map.entities:
		if (e.flags & 3) == 1 and e.marker_type < 0 and Rules.is_mover(e.link_act_type):
			mover_ents.append(e)
	var gates: int = 0
	var gates_ok: int = 0
	var bad: Array = []
	for e in mover_ents:
		var m: Node = by_id.get(e.file_off)
		if m == null:
			bad.append("no Mover for @%05x" % e.file_off)
			continue
		var nm: String = LevelLoader.MapFile.entity_name(level.map, e)
		if nm == "BIGDOOR":
			gates += 1
			if String(m.name).begins_with("Mover_BIGDOOR"):
				gates_ok += 1
		var mesh: MeshInstance3D = m.get_node_or_null("Body/Mesh")
		var ap: AnimationPlayer = m.get_node_or_null("AnimationPlayer")
		if mesh == null or mesh.mesh == null:
			bad.append("%s has no mesh" % m.name)
		if ap == null or not ap.has_animation("move") or float(m.get("duration")) <= 0.0:
			bad.append("%s has no move animation" % m.name)
		var shape: CollisionShape3D = m.get_node_or_null("Body/Shape")
		if shape == null or shape.shape == null:
			bad.append("%s has no collider" % m.name)
	_check(bad.is_empty() and not mover_ents.is_empty(),
		"%d mover records → Movers with mesh, collider and animation%s"
		% [mover_ents.size(), "" if bad.is_empty() else " — " + ", ".join(bad)])
	_check(gates > 0 and gates_ok == gates, "every BIGDOOR gate of MAP.216 is a Mover (%d)" % gates)

	# Chains: every NodePath in `targets` (or the SoundLoop's meta) resolves.
	var links: int = 0
	var broken: int = 0
	for c in beh.get_children():
		for n in c.get_children():
			var paths: Array = []
			if "targets" in n:
				paths = n.get("targets")
			elif n.has_meta("target"):
				paths = [n.get_meta("target")]
			for path in paths:
				links += 1
				if n.get_node_or_null(path) == null:
					broken += 1
	_check(links > 0 and broken == 0, "%d chain links resolve to nodes (%d broken)" % [links, broken])
	var sounds: Node = beh.get_node_or_null("Sounds")
	if sounds != null:
		var silent: int = 0
		for s in sounds.get_children():
			if (s as AudioStreamPlayer3D).stream == null:
				silent += 1
		_check(silent == 0, "%d looping sounds carry their stream (%d without)" % [sounds.get_child_count(), silent])

	# Parity: the animation at its midpoint and its end lands where the
	# running mover puts the same entity at half and full travel. The live
	# one is the record's own Mover node (step 5e) and the mesh it moves is
	# the loader's, so what is read back is that mesh's transform.
	var branch: Node = level.behaviour
	var worst_pos: float = 0.0
	var worst_rot: float = 0.0
	var compared: int = 0
	for e in mover_ents:
		var m: Node = by_id.get(e.file_off)
		var live: Node = level.behaviour.mover_node(e.file_off)
		var node: Node3D = branch.hit_node(e.file_off)
		if m == null or live == null or node == null:
			continue
		var prm: Dictionary = LevelBehaviour.mover_params(e.link_act_type)
		var anim: Animation = (m.get_node("AnimationPlayer") as AnimationPlayer).get_animation("move")
		var body: Node3D = m.get_node("Body")
		for f in [0.5, 1.0]:
			live.progress = float(prm["span"]) * f
			live.apply_transform()
			var want: Transform3D = node.transform
			var t: float = anim.length * f
			var pos: Vector3 = (m as Node3D).position + body.position
			var basis: Basis = body.basis
			if anim.track_get_type(0) == Animation.TYPE_POSITION_3D:
				pos = (m as Node3D).position + anim.position_track_interpolate(0, t)
			else:
				basis = Basis(anim.rotation_track_interpolate(0, t))
			worst_pos = maxf(worst_pos, want.origin.distance_to(pos))
			for i in 3:
				worst_rot = maxf(worst_rot, (want.basis[i] - basis[i]).length())
			compared += 1
	_check(compared > 0 and worst_pos < 0.5 and worst_rot < 0.01,
		"%d mover animations match the running mover (pos %.3f u, basis %.4f)" % [compared, worst_pos, worst_rot])
	root.free()

## The mission scene (scripts/mission_scene.gd): mission 1 held as one
## scene — its zones on the +X grid, its doorways as portals and the
## re-authored world as phases.
func _run_mission_scene_checks() -> void:
	# Step 8 of the M2 plan: a mission scene is how the campaign is played
	# now. Asked of a FRESH Settings node — one that never entered the tree
	# and so never read settings.cfg — because what ships is the initialiser,
	# and a file on this machine can say anything.
	var fresh: Node = load("res://scripts/settings.gd").new()
	_check(bool(fresh.mission_scenes), "mission scenes are the shipped default")
	fresh.free()
	var mp: String = MissionScene.scene_path(210)
	_check(not mp.is_empty(), "the cache has a place for mission scenes")
	if mp.is_empty():
		return
	# A fresh bake every run: this is the code under test.
	if FileAccess.file_exists(mp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(mp))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LevelScene.sidecar_path(mp)))
		Assets.trust_forget(mp)
	var ps: PackedScene = Assets.mission_scene(210)
	_check(ps != null, "MISSION.210 is baked and loads (%s)" % mp.get_file())
	if ps == null:
		return
	var root: Node = ps.instantiate()
	_check(root != null and int(root.get("bake_version")) == MissionScene.MISSION_BAKE_VERSION,
		"the mission scene is a v%d bake" % MissionScene.MISSION_BAKE_VERSION)
	if root == null:
		return
	# MAP.216 and MAP.217 are MAP.210 authored again later in the mission —
	# PHASES of its world, not zones of their own.
	var zones: Array = []
	for z in root.get_node("Zones").get_children():
		zones.append(int(z.get("map_num")))
	zones.sort()
	_check(zones == [210, 211, 212, 213, 214, 215, 218],
		"mission 210 stands on zones %s" % str(zones))

	# Every 0xF0 exit the census walks is a portal node.
	var bsa = LevelLoader.BSAReader.new()
	var census: Array = []
	if bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		census = (MissionCensus._mission(210, bsa, {}) as Dictionary)["portals"]
		bsa.close()
	var portals: Node = root.get_node("Portals")
	_check(portals.get_child_count() == census.size() and not census.is_empty(),
		"%d portal nodes for the census's %d exits" % [portals.get_child_count(), census.size()])

	# The bunker doorway: it opens into MAP.218's zone, at a real place.
	var door: Node = portals.get_node_or_null("Portal_MAP_210_0cabb")
	_check(door != null, "the MAP.210 doorway @0cabb is a portal node")
	if door != null:
		var tzp: NodePath = door.get("target_zone")
		var tz: Node = door.get_node_or_null(tzp) if not tzp.is_empty() else null
		_check(tz != null and String(tz.get("map_name")) == "MAP.218",
			"…and leads into zone %s" % (String(tz.get("map_name")) if tz != null else "nothing"))
		var tp: Vector3 = door.get("target_pos")
		_check(tp.is_finite(), "…landing at %s in the world" % str(tp))
	var z218: Node3D = root.get_node_or_null("Zones/Zone_MAP_218")
	_check(z218 != null and z218.position.x > 65536.0,
		"zone MAP.218 stands clear of the outdoor world, at x=%.0f"
		% (z218.position.x if z218 != null else 0.0))
	root.free()

## M3 step 2 — the LOCK (docs plan §5 layer (a)). tests/rules/
## skynet.triggers.lock holds the reviewed trigger graph of every shipped
## map, one line per node. Rebuilding all 122 of them takes about a
## second, so the whole thing runs here rather than a sample: a rules or
## parser change that moves what any trigger DOES fails this suite
## instead of turning up in play three missions later.
func _run_trigger_lock_checks() -> void:
	var text: String = TriggerLock.lock_text()
	_check(not text.is_empty(), "the trigger lock is present")
	if text.is_empty():
		return
	# Nothing but ids, act bytes, numbers, keywords and hashes: the file is
	# committed to a public repository.
	var dirty: PackedStringArray = TriggerLock.hygiene(text)
	_check(dirty.is_empty(), "the lock holds only hex, numbers and keywords%s"
		% ("" if dirty.is_empty() else " — " + ", ".join(dirty.slice(0, 3))))
	# …and the check bites: an entity name, a quoted line of the game's
	# own text and a path must each be refused.
	var planted: int = 0
	for line in ["217 07bb4 EF use:eye/3d/r60+26/always/nolatch chain[07bb4* BUTTON01:DB] first[-] second[-] 4f2a9c31",
			"# the tower panel says \"ACCESS GRANTED\"",
			"217 07bb4 EF use:eye/3d/r60+26/always/nolatch chain[07bb4] first[res://scripts] second[-] 4f2a9c31"]:
		if not TriggerLock.hygiene(text + line + "\n").is_empty():
			planted += 1
	_check(planted == 3, "the hygiene check refuses a name, a quoted line and a path (%d of 3)" % planted)
	# …and passes a Windows checkout, where git puts a carriage return in
	# front of every newline.
	_check(TriggerLock.hygiene(text.replace("\n", "\r\n")).is_empty(),
		"the lock still reads clean with carriage returns in it")

	var lock: Dictionary = TriggerLock.parse(text)
	var head: Dictionary = lock["header"]
	_check(String(head.get("format", "")) == TriggerLock.FORMAT
		and int(head.get("lock_version", 0)) == TriggerLock.LOCK_VERSION
		and int(head.get("graph_version", 0)) == TriggerGraph.GRAPH_VERSION
		and String(head.get("game", "")) == TriggerGraph.current_game(),
		"the lock's header is this build's (%s v%s, graph %s, %s)"
		% [str(head.get("format", "?")), str(head.get("lock_version", "?")),
		   str(head.get("graph_version", "?")), str(head.get("game", "?"))])
	_check(String(head.get("rules_hash", "")) == String(
		TriggerGraph.rules_for(TriggerGraph.current_game()).rules_hash()),
		"the lock was written from these rules (%s)" % str(head.get("rules_hash", "?")))

	# Every shipped map, rebuilt from its bytes and diffed line by line.
	var res: Dictionary = TriggerLock.verify()
	if int(res["fails"]) > 0:
		for line in (res["report"] as PackedStringArray):
			print("[smoke] %s" % line)
	_check(int(res["fails"]) == 0 and int(res["checked"]) == int(head.get("maps", -1)),
		"%d maps and %d nodes match the lock in %.2f s (%d unpinned)"
		% [int(res["checked"]), int(head.get("nodes", 0)),
		   float(res["ms"]) / 1000.0, int(res["unpinned"])])
	_run_xfail_checks()

## The known-failure list the step-4 verifier gates on
## (tests/rules/skynet.xfail). It travels in the public repository beside
## the lock and keeps the same discipline: map number, id, act byte, the
## kind the rules module names and one tag out of a fixed list — no
## entity names, no paths, none of the game's own words.
func _run_xfail_checks() -> void:
	var path: String = TriggerVerifier.XFAIL_PATH
	_check(FileAccess.file_exists(path), "the verifier's known-failure list is present")
	if not FileAccess.file_exists(path):
		return
	var text: String = FileAccess.get_file_as_string(path)
	var dirty: PackedStringArray = TriggerVerifier.hygiene(text)
	_check(dirty.is_empty(), "the known-failure list holds only numbers, hex and keywords%s"
		% ("" if dirty.is_empty() else " — " + ", ".join(dirty.slice(0, 3))))
	var planted: int = 0
	for line in ["210 06db5 EF prox_gate BUTTON01",
			"210 06db5 EF nonsense loop_no_handler",
			"# the door sound is missing"]:
		if not TriggerVerifier.hygiene(text + line + "\n").is_empty():
			planted += 1
	_check(planted == 3,
		"it refuses a name, an unknown kind and a comment of its own (%d of 3)" % planted)
	_check(TriggerVerifier.hygiene(text.replace("\n", "\r\n")).is_empty(),
		"it still reads clean with carriage returns in it")
	_run_mission_spec_checks()

## The MISSION SPEC layer (b) plays (tests/rules/skynet.missions.txt,
## --verify-missions). It travels in the public repository beside the lock
## and the known-failure list and keeps the same discipline: map numbers,
## hex ids, the effect names the GRAPH itself writes, the verbs it can
## perform and one tag out of a fixed list - no entity names, no
## coordinates, no quotes, none of the game's own words. And it has to
## parse: a spec the runner cannot read is a mission nobody is checking.
func _run_mission_spec_checks() -> void:
	var path: String = MissionVerifier.SPEC_PATH
	_check(FileAccess.file_exists(path), "the mission spec is present")
	if not FileAccess.file_exists(path):
		return
	var text: String = FileAccess.get_file_as_string(path)
	var dirty: PackedStringArray = MissionVerifier.hygiene(text)
	_check(dirty.is_empty(), "the mission spec holds only numbers, hex, effects and keywords%s"
		% ("" if dirty.is_empty() else " - " + ", ".join(dirty.slice(0, 3))))
	# ...and the check bites: an entity name where an effect belongs, a
	# quoted line of the game's own text, a coordinate and a verb nobody
	# can perform must each be refused.
	var planted: int = 0
	for line in ["use 215 032cb expect BUTTON01",
			"# the console says \"ACCESS GRANTED\"",
			"use 215 032cb expect obj0 at 1420,-380,-2900",
			"jump 215 032cb expect obj0"]:
		if not MissionVerifier.hygiene(text + line + "\n").is_empty():
			planted += 1
	_check(planted == 4,
		"it refuses a name, a quoted line, a coordinate and an unknown verb (%d of 4)" % planted)
	_check(MissionVerifier.hygiene(text.replace("\n", "\r\n")).is_empty(),
		"the spec still reads clean with carriage returns in it")

	var spec: Dictionary = MissionVerifier.parse(text)
	var errors: Array = spec["errors"]
	_check(errors.is_empty(), "the spec parses%s"
		% ("" if errors.is_empty() else " - " + String(errors[0])))
	var missions: Array = spec["missions"]
	var keys := PackedStringArray()
	var counted: int = 0
	for m in missions:
		var mission: Dictionary = m
		keys.append(str(int(mission["key"])))
		var steps: Array = mission["steps"]
		if not steps.is_empty() and String((steps[steps.size() - 1] as Dictionary)["kind"]) == "counter":
			counted += 1
	# One block per campaign mission, each one played to its counter - the
	# eight maps a mission starts on (main.gd CAMPAIGN_SEQUENCE).
	var want := PackedStringArray()
	for mn in MainScript.CAMPAIGN_SEQUENCE:
		want.append(String(mn).get_extension())
	_check(missions.size() == want.size() and counted == missions.size(),
		"one block per campaign mission, each ending on its counter (%d of %d, %d counted)"
		% [missions.size(), want.size(), counted])
	_check(keys == want, "and they are the campaign's own start maps (%s)" % " ".join(keys))

## M3 step 3 — the event BUS, and what it is for.
##
## Every trigger event the runtime performs is announced
## (scripts/triggers/trigger_bus.gd). Nothing in the game subscribes, so
## the first half below is the bus on its own: it delivers by id, it
## records in order, and a level that has just been built has no
## listeners at all — the proof that nothing about play hangs off it.
##
## The second half is why it exists. For a handful of real nodes, the
## graph's PREDICTION of what the first activation comes to (its
## `first[]`, the same list the lock pins) is laid against what the
## running game ANNOUNCED when that node was actually set off
## (scripts/triggers/trigger_equiv.gd). Where the two disagree, one of
## them is wrong about the game — which is the question step 4's verifier
## then asks of every node of every map.
const EQUIV_NODES: Array = [
	# map, node, how it is driven, what it is
	["MAP.215", 0x032cb, "the silo chain: four covers slide, [M1] counts, the line plays"],
	["MAP.215", 0x02e54, "a lone mover: a door sound and one lift"],
	["MAP.215", 0x03ed8, "an exit: the door sound, then the map change"],
	["MAP.210", 0x077f3, "the canyon lever (0xF1): the gate's two leaves part"],
	["MAP.217", 0x0ba48, "one gate of the ring round the jeep: [M3]"],
	["MAP.254", 0x053d0, "a water valve: the surface rises and three walls move"],
]

func _run_trigger_bus_checks() -> void:
	# --- the bus on its own ------------------------------------------
	var bus = TriggerBus.new()
	bus.map = 210
	var heard: Array = []
	var other: Array = []
	var cb: Callable = func(ev: StringName, data: Dictionary) -> void: heard.append([ev, data])
	bus.watch(0x1234, cb)
	bus.watch(0x9999, func(ev: StringName, data: Dictionary) -> void: other.append(ev))
	bus.record(true)
	bus.announce_flip(0x1234, 0xEF, 0x01)
	bus.announce_fire(0x1234, "prox_gate")
	bus.announce_effect(0x9999, "objective", {"index": 2})
	_check(heard.size() == 2 and other.size() == 1,
		"the bus delivers by id (%d to one watcher, %d to the other)" % [heard.size(), other.size()])
	_check(String(heard[0][0]) == String(TriggerBus.EV_FLIPPED)
		and int((heard[0][1] as Dictionary)["state"]) == 1,
		"a flip carries the act and the state byte after it")
	bus.unwatch(0x1234, cb)
	bus.announce_fire(0x1234, "prox_gate")
	_check(heard.size() == 2, "unwatch stops the delivery (%d)" % heard.size())
	_check(bus.history().size() == 4 and bus.take().size() == 4 and bus.history().is_empty(),
		"the recording keeps every announcement in order, and take() empties it")
	# The graph's own vocabulary, so the two lists can be compared.
	_check(TriggerEquiv.token({"ev": TriggerBus.EV_EFFECT, "id": 0x075cb,
			"kind": "objective", "payload": {"index": 2}}) == "obj2"
		and TriggerEquiv.token({"ev": TriggerBus.EV_EFFECT, "id": 0x02f55,
			"kind": "move", "payload": {"family": "slide", "axis": 1, "travel": -378.0}})
			== "move@02f55:slideY-378"
		and TriggerEquiv.token({"ev": TriggerBus.EV_FLIPPED, "id": 1, "act": 0, "state": 0}).is_empty(),
		"a bus event reads back as the graph's own effect token")

	# --- nothing in the game listens ---------------------------------
	var l215: LevelLoader.Level = LevelLoader.new().load_level("MAP.215")
	_check(l215 != null and l215.bus != null and l215.triggers.bus == l215.bus
		and l215.behaviour != null and l215.behaviour.bus == l215.bus,
		"a level brings one bus, and the runtime and the branch both announce on it")
	if l215 != null and l215.bus != null:
		var listeners: int = 0
		for n in l215.map.entities:
			listeners += l215.bus.watchers(n.file_off)
		_check(listeners == 0 and not l215.bus.recording(),
			"a freshly built level has no subscribers and records nothing (%d)" % listeners)

	# --- the graph's prediction against the running game --------------
	var agreed: int = 0
	for row in EQUIV_NODES:
		var map_name: String = String(row[0])
		var id: int = int(row[1])
		var level: LevelLoader.Level = LevelLoader.new().load_level(map_name)
		if level == null:
			_check(false, "%s loads for the graph-vs-bus check" % map_name)
			continue
		var graph: Dictionary = TriggerEquiv.graph_of(level)
		var res: Dictionary = TriggerEquiv.check(level, graph, id)
		if bool(res.get("ok", false)):
			agreed += 1
		_check(bool(res.get("ok", false)), "%s — %s" % [TriggerEquiv.describe(res), String(row[2])])
	_check(agreed == EQUIV_NODES.size(),
		"%d of %d nodes do exactly what the graph says they do"
		% [agreed, EQUIV_NODES.size()])

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
		if Rules.is_mover(cur.link_act_type):
			return cur
	return null
