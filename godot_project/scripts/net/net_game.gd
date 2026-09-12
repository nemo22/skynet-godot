## Autoload `Net` — deathmatch networking (docs/implementation_plan.md §O).
##
## Not the DOS wire protocol (flag 0x40000, packets via 0x11f11a): the
## port keeps only the DOS *game* — NETLEVEL.PRS arenas, the marker
## 10..29 spawn pairs, marker 100..102 item spots — and speaks its own
## protocol over Godot's ENet peer with RPCs on this node:
##
##   * the host is the SERVER and also plays; anyone may join at any time
##   * each peer simulates ITS OWN movement and sends a pose 20×/s
##     (unreliable); the server relays poses to everybody else
##   * hits are detected by the SHOOTER (client-side hit detection) and
##     reported to the server, which owns health, armor, deaths, kills,
##     respawns and pickups — the only authoritative state
##   * bots live on the server (bot_brain.gd) and are just more players
##     with NEGATIVE ids; clients see them as avatars like anyone
##
## Method prefixes: `_c_*` = client → server RPC (the sender is the actor),
## `_s_*` = server → client RPC (also invoked locally on the host so one
## code path updates every peer), `_srv_*` = server-only logic.
extends Node

signal player_joined(id: int)
signal player_left(id: int)
signal roster_changed
signal pose_received(id: int, pos: Vector3, yaw: float, pitch: float, flags: int)
signal fired(id: int, weapon: int, from: Vector3, dir: Vector3)
signal local_health_changed(hp: float, armor: float, attacker: int)
signal died(victim: int, killer: int, weapon: int)
signal respawned(id: int, pos: Vector3, yaw: float)
signal pickup_taken(key: int, by: int)
signal pickup_spawned(key: int)
signal chat_received(from_id: int, text: String)
signal match_over(reason: String)
signal match_restarted
signal time_changed(sec: int)
signal class_changed(id: int, cls: int)
signal welcome_received
signal connection_failed(reason: String)
signal disconnected(reason: String)

const PickupData := preload("res://scripts/pickup_data.gd")

const DEFAULT_PORT: int = 27015
const DISCOVERY_PORT: int = 27016
const DISCOVERY_MAGIC: String = "SKYNET_DISCOVER_1"
## Bots are negative ids (ENet peer ids are random positive 32-bit ints).
const BOT_ID_BASE: int = -1
const MAX_PEERS: int = 16
const CFG_PATH: String = "user://net.cfg"
const POSE_HZ: float = 20.0
const RESPAWN_DELAY: float = 3.0
const PICKUP_RESPAWN: float = 30.0
const MAX_HEALTH: float = 100.0
## Player classes (the DOS MP choice): HUMAN = fast, fragile; TERMINATOR =
## slow, tough, with the red machine vision that picks out everybody.
const CLASS_HUMAN: int = 0
const CLASS_TERMINATOR: int = 1
const CLASS_HP: Array = [100.0, 200.0]
const CLASS_SPEED: Array = [1.3, 0.85]
const CLASS_NAMES: Array = ["HUMAN", "TERMINATOR"]
## Pose flags.
const F_MOVING: int = 1
const F_FIRING: int = 2
const F_DEAD: int = 4

## NETLEVEL item category → sprite indices to pick from (PickupData.ITEMS).
const ITEM_SPRITES: Dictionary = {
	"bullets":      [25601, 25601, 25602],
	"energy":       [27406, 27406, 27405],
	"armor":        [27392, 27393, 27393, 27394],
	"health":       [27401, 27400, 27400, 27399],
	"slugthrowers": [25736, 25612, 25600, 25737],
	"lasers":       [25611, 25611, 25609],
	"plasmas":      [25731, 25729, 25613],
	"launchers":    [25606, 25733],
	"grenades":     [25614],
	"rockets":      [25738],
}
const WEAPON_CATEGORIES: Array = ["slugthrowers", "lasers", "plasmas", "launchers"]

## True while a network game is up (host or client).
var active: bool = false
var local_id: int = 0
var local_name: String = "PLAYER"
## The class this peer plays (applied on the next spawn).
var local_class: int = CLASS_HUMAN
## Host settings, shared with every client in the welcome:
##   name, map, max_players, time_limit (min, 0 = none), frag_limit
##   (0 = none), bots, bot_skill (0..2), items {category: count},
##   replenish (bool), port.
var settings: Dictionary = {}
## id → {name, kills, deaths, hp, armor, alive, bot, pos, weapon, cls}
var players: Dictionary = {}
## key → {si (sprite index), pos (Vector3), taken (bool)}
var pickups: Dictionary = {}
var time_left: float = 0.0
var match_running: bool = false
## Server: spawn sets [{pos, yaw}] set by the DM controller once the map
## is up; pending hellos wait for it.
var spawn_points: Array = []
var level_ready: bool = false

## A note for the main menu to flash after a forced return (kicked,
## server gone).
var pending_message: String = ""

var _peer: ENetMultiplayerPeer = null
var _pending_hellos: Array = []            # [[id, name]] before the level is up
var _respawn_at: Dictionary = {}           # id → msec
var _pickup_respawn_at: Dictionary = {}    # key → msec
var _next_pickup_key: int = 1
var _pose_accum: float = 0.0
var _time_sent: int = -1
var _discovery: PacketPeerUDP = null
var _bot_seq: int = 0
var _joining: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_cfg()

func is_server() -> bool:
	return active and _peer != null and multiplayer.is_server()

func is_bot(id: int) -> bool:
	return id < 0

func name_of(id: int) -> String:
	if players.has(id):
		return String(players[id].get("name", "?"))
	return "?"

func is_alive(id: int) -> bool:
	return players.has(id) and bool(players[id].get("alive", false))

## Net id of a damageable node: avatars carry `net_id`; the local
## player body is `local_id`; anything else is 0 (the world).
func id_of(node: Node) -> int:
	if node == null:
		return 0
	if "net_id" in node:
		return int(node.get("net_id"))
	if node.is_in_group("player"):
		return local_id
	return 0

# ---------------------------------------------------------------------
# Session setup
# ---------------------------------------------------------------------

func _load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		local_name = String(cfg.get_value("net", "name", local_name))
		local_class = clampi(int(cfg.get_value("net", "class", local_class)), 0, 1)
		local_avatar = maxi(int(cfg.get_value("net", "avatar", local_avatar)), 0)

func save_name(n: String) -> void:
	local_name = n.strip_edges().substr(0, 16)
	if local_name.is_empty():
		local_name = "PLAYER"
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("net", "name", local_name)
	cfg.set_value("net", "class", local_class)
	cfg.save(CFG_PATH)

## Start hosting with `cfg` (see `settings`). The host is peer 1.
func host(cfg: Dictionary) -> bool:
	leave()
	settings = cfg.duplicate(true)
	var port: int = int(settings.get("port", DEFAULT_PORT))
	var maxp: int = int(settings.get("max_players", 0))
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_PEERS if maxp <= 0 else clampi(maxp, 1, MAX_PEERS))
	if err != OK:
		push_error("[net] cannot host on port %d: %s" % [port, error_string(err)])
		_peer = null
		return false
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	active = true
	local_id = 1
	players.clear()
	pickups.clear()
	spawn_points.clear()
	level_ready = false
	_respawn_at.clear()
	_pickup_respawn_at.clear()
	_next_pickup_key = 1
	_bot_seq = 0
	players[1] = _new_player(local_name, false, local_class)
	for i in int(settings.get("bots", 0)):
		_srv_add_bot()
	time_left = float(settings.get("time_limit", 0)) * 60.0
	match_running = true
	_start_discovery()
	print("[net] hosting '%s' on port %d — map %s, %d bots" % [settings.get("name", ""), port,
		settings.get("map", "?"), int(settings.get("bots", 0))])
	return true

## Connect to a host. `welcome_received` fires once the roster arrived
## (then load `settings.map`); `connection_failed` on error.
func join(ip: String, port: int, name: String) -> bool:
	leave()
	save_name(name)
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(ip, port)
	if err != OK:
		push_error("[net] cannot connect to %s:%d: %s" % [ip, port, error_string(err)])
		_peer = null
		return false
	multiplayer.multiplayer_peer = _peer
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_joining = true
	players.clear()
	pickups.clear()
	print("[net] connecting to %s:%d as %s" % [ip, port, local_name])
	return true

## Tear the session down (menu, disconnect, quit).
func leave() -> void:
	_stop_discovery()
	if _peer != null:
		for sig in [["peer_connected", _on_peer_connected], ["peer_disconnected", _on_peer_disconnected],
				["connected_to_server", _on_connected], ["connection_failed", _on_connection_failed],
				["server_disconnected", _on_server_disconnected]]:
			if multiplayer.is_connected(sig[0], sig[1]):
				multiplayer.disconnect(sig[0], sig[1])
		_peer.close()
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
		_peer = null
	active = false
	_joining = false
	match_running = false
	level_ready = false
	local_id = 0
	players.clear()
	pickups.clear()
	spawn_points.clear()
	_pending_hellos.clear()
	_respawn_at.clear()
	_pickup_respawn_at.clear()

func _new_player(name: String, bot: bool, cls: int = CLASS_HUMAN) -> Dictionary:
	return {"name": name, "kills": 0, "deaths": 0, "hp": MAX_HEALTH, "armor": 0.0,
		"alive": false, "bot": bot, "pos": Vector3.ZERO, "weapon": 1, "cls": cls}

# --- peer events -------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	print("[net] peer %d connected" % id)

func _on_peer_disconnected(id: int) -> void:
	print("[net] peer %d left" % id)
	if players.has(id):
		_s_player_remove.rpc(id)
		_s_player_remove(id)

func _on_connected() -> void:
	local_id = multiplayer.get_unique_id()
	print("[net] connected, my id %d — hello" % local_id)
	_c_hello.rpc_id(1, local_name, local_class)

func _on_connection_failed() -> void:
	print("[net] connection failed")
	leave()
	connection_failed.emit("Could not reach the server.")

func _on_server_disconnected() -> void:
	print("[net] server went away")
	leave()
	disconnected.emit("The server closed the game.")

# ---------------------------------------------------------------------
# Join handshake
# ---------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _c_hello(name: String, cls: int = CLASS_HUMAN) -> void:
	if not is_server():
		return
	var id: int = multiplayer.get_remote_sender_id()
	if not level_ready:
		_pending_hellos.append([id, name, cls])
		return
	_srv_admit(id, name, cls)

func _srv_admit(id: int, name: String, cls: int = CLASS_HUMAN) -> void:
	var maxp: int = int(settings.get("max_players", 0))
	var humans: int = 0
	for p in players.values():
		if not bool(p["bot"]):
			humans += 1
	if maxp > 0 and humans >= maxp:
		_s_kick.rpc_id(id, "Server is full.")
		return
	# Unique display name.
	var base := name.strip_edges().substr(0, 16)
	if base.is_empty():
		base = "PLAYER"
	var nm := base
	var n := 2
	while _name_taken(nm):
		nm = "%s%d" % [base, n]
		n += 1
	players[id] = _new_player(nm, false, clampi(cls, 0, 1))
	_s_welcome.rpc_id(id, settings, players, _pickups_wire(), int(time_left), match_running, _vehicles_wire())
	for p in multiplayer.get_peers():
		if p != id:
			_s_player_add.rpc_id(p, id, players[id])
	player_joined.emit(id)
	roster_changed.emit()
	print("[net] %s joined as peer %d" % [nm, id])

func _name_taken(nm: String) -> bool:
	for p in players.values():
		if String(p["name"]).to_lower() == nm.to_lower():
			return true
	return false

func _pickups_wire() -> Dictionary:
	var out: Dictionary = {}
	for k in pickups:
		var p: Dictionary = pickups[k]
		out[k] = [int(p["si"]), p["pos"], bool(p["taken"])]
	return out

@rpc("authority", "call_remote", "reliable")
func _s_welcome(cfg: Dictionary, roster: Dictionary, wire: Dictionary, tl: int, running: bool, veh: Dictionary = {}) -> void:
	settings = cfg
	_apply_vehicles_wire(veh)
	players = roster
	pickups.clear()
	for k in wire:
		var a: Array = wire[k]
		pickups[int(k)] = {"si": int(a[0]), "pos": a[1], "taken": bool(a[2])}
	time_left = float(tl)
	match_running = running
	active = true
	_joining = false
	print("[net] welcome: map %s, %d players, %d pickups" % [settings.get("map", "?"), players.size(), pickups.size()])
	welcome_received.emit()
	roster_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _s_kick(reason: String) -> void:
	leave()
	connection_failed.emit(reason)

@rpc("authority", "call_remote", "reliable")
func _s_player_add(id: int, info: Dictionary) -> void:
	players[id] = info
	player_joined.emit(id)
	roster_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _s_player_remove(id: int) -> void:
	players.erase(id)
	_respawn_at.erase(id)
	player_left.emit(id)
	roster_changed.emit()

## The map is loaded on this peer: ask the server for a spawn. On the
## host this also releases queued joins.
func report_level_ready() -> void:
	if not active:
		return
	if is_server():
		level_ready = true
		for h in _pending_hellos:
			_srv_admit(int(h[0]), String(h[1]), int(h[2]) if h.size() > 2 else CLASS_HUMAN)
		_pending_hellos.clear()
		_srv_respawn(local_id)
		for id in players:
			if is_bot(id):
				_srv_respawn(id)
	else:
		_c_level_ready.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _c_level_ready() -> void:
	if not is_server():
		return
	var id: int = multiplayer.get_remote_sender_id()
	if players.has(id):
		# A late joiner needs everyone's current place before their own
		# spawn (poses only flow while people move).
		for other in players:
			if other != id and bool(players[other]["alive"]):
				var p: Dictionary = players[other]
				_s_pose.rpc_id(id, other, p["pos"], 0.0, 0.0, 0)
		_srv_respawn(id)

# ---------------------------------------------------------------------
# Poses and fire (visual replication)
# ---------------------------------------------------------------------

## Owner → server, 20×/s (the DM controller calls this every physics
## frame; the rate limit lives here).
func send_pose(pos: Vector3, yaw: float, pitch: float, flags: int, delta: float) -> void:
	if not active:
		return
	_pose_accum += delta
	if _pose_accum < 1.0 / POSE_HZ:
		return
	_pose_accum = 0.0
	if is_server():
		_srv_pose(local_id, pos, yaw, pitch, flags)
	else:
		_c_pose.rpc_id(1, pos, yaw, pitch, flags)

## Server-side bots report through here.
func bot_pose(id: int, pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	if is_server():
		_srv_pose(id, pos, yaw, pitch, flags)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _c_pose(pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	if is_server():
		_srv_pose(multiplayer.get_remote_sender_id(), pos, yaw, pitch, flags)

func _srv_pose(id: int, pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	if not players.has(id):
		return
	players[id]["pos"] = pos
	for p in multiplayer.get_peers():
		if p != id:
			_s_pose.rpc_id(p, id, pos, yaw, pitch, flags)
	if id != local_id:
		pose_received.emit(id, pos, yaw, pitch, flags)

@rpc("authority", "call_remote", "unreliable_ordered")
func _s_pose(id: int, pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	if players.has(id):
		players[id]["pos"] = pos
	pose_received.emit(id, pos, yaw, pitch, flags)

## Owner fired weapon `weapon` from `from` along `dir` — everybody else
## draws the shot (no damage on their side).
func send_fire(weapon: int, from: Vector3, dir: Vector3) -> void:
	if not active:
		return
	if is_server():
		_srv_fire(local_id, weapon, from, dir)
	else:
		_c_fire.rpc_id(1, weapon, from, dir)

func bot_fire(id: int, weapon: int, from: Vector3, dir: Vector3) -> void:
	if is_server():
		_srv_fire(id, weapon, from, dir)

@rpc("any_peer", "call_remote", "reliable")
func _c_fire(weapon: int, from: Vector3, dir: Vector3) -> void:
	if is_server():
		_srv_fire(multiplayer.get_remote_sender_id(), weapon, from, dir)

func _srv_fire(id: int, weapon: int, from: Vector3, dir: Vector3) -> void:
	if players.has(id):
		players[id]["weapon"] = weapon
	for p in multiplayer.get_peers():
		if p != id:
			_s_fire.rpc_id(p, id, weapon, from, dir)
	if id != local_id:
		fired.emit(id, weapon, from, dir)

@rpc("authority", "call_remote", "reliable")
func _s_fire(id: int, weapon: int, from: Vector3, dir: Vector3) -> void:
	if players.has(id):
		players[id]["weapon"] = weapon
	fired.emit(id, weapon, from, dir)

# ---------------------------------------------------------------------
# Damage, death, respawn (server authoritative)
# ---------------------------------------------------------------------

## Report a hit on `victim` for `dmg` by `attacker` (the local player, or a
## bot on the server). Anyone may report; the server applies it.
func hit(victim: int, dmg: float, attacker: int, weapon: int) -> void:
	if not active or dmg <= 0.0:
		return
	if is_server():
		_srv_hit(victim, dmg, attacker, weapon)
	else:
		_c_hit.rpc_id(1, victim, dmg, weapon)

@rpc("any_peer", "call_remote", "reliable")
func _c_hit(victim: int, dmg: float, weapon: int) -> void:
	if is_server():
		_srv_hit(victim, dmg, multiplayer.get_remote_sender_id(), weapon)

func _srv_hit(victim: int, dmg: float, attacker: int, weapon: int) -> void:
	if not match_running or not players.has(victim):
		return
	var v: Dictionary = players[victim]
	if not bool(v["alive"]):
		return
	# A hull takes part of the hit (jeep / HK driver).
	if vehicle_of(victim) != 0:
		dmg *= 0.6
	# Armor soaks half of each hit until it is used up (DOS 0x38cc8).
	var armor: float = float(v["armor"])
	var mx: float = max_hp_of(victim)
	if armor > 0.0:
		var soak: float = minf(dmg * 0.5, armor * mx)
		armor = maxf(armor - soak / mx, 0.0)
		dmg -= soak
	var hp: float = maxf(float(v["hp"]) - dmg, 0.0)
	v["hp"] = hp
	v["armor"] = armor
	_srv_send_health(victim, attacker)
	if hp <= 0.0:
		_srv_kill(victim, attacker, weapon)

func _srv_send_health(id: int, attacker: int) -> void:
	var v: Dictionary = players[id]
	if id == local_id:
		_s_health(float(v["hp"]), float(v["armor"]), attacker)
	elif not is_bot(id):
		_s_health.rpc_id(id, float(v["hp"]), float(v["armor"]), attacker)

@rpc("authority", "call_remote", "reliable")
func _s_health(hp: float, armor: float, attacker: int) -> void:
	if players.has(local_id):
		players[local_id]["hp"] = hp
		players[local_id]["armor"] = armor
	local_health_changed.emit(hp, armor, attacker)

func _srv_kill(victim: int, killer: int, weapon: int) -> void:
	var v: Dictionary = players[victim]
	v["alive"] = false
	v["deaths"] = int(v["deaths"]) + 1
	_srv_vehicle_driver_died(victim)
	if killer == victim or killer <= 0 or not players.has(killer):
		# Suicide / world: the DOS scoring_death penalty — one frag off.
		if players.has(victim):
			v["kills"] = int(v["kills"]) - 1
	else:
		players[killer]["kills"] = int(players[killer]["kills"]) + 1
	_respawn_at[victim] = Time.get_ticks_msec() + int(RESPAWN_DELAY * 1000.0)
	var scores := _scores_wire()
	_s_died.rpc(victim, killer, weapon, scores)
	_s_died(victim, killer, weapon, scores)
	var limit: int = int(settings.get("frag_limit", 0))
	if limit > 0 and players.has(killer) and int(players[killer]["kills"]) >= limit:
		_srv_end_match("%s REACHED %d FRAGS" % [name_of(killer), limit])

func _scores_wire() -> Dictionary:
	var out: Dictionary = {}
	for id in players:
		out[id] = [int(players[id]["kills"]), int(players[id]["deaths"])]
	return out

func _apply_scores(scores: Dictionary) -> void:
	for id in scores:
		if players.has(int(id)):
			players[int(id)]["kills"] = int(scores[id][0])
			players[int(id)]["deaths"] = int(scores[id][1])

@rpc("authority", "call_remote", "reliable")
func _s_died(victim: int, killer: int, weapon: int, scores: Dictionary) -> void:
	if players.has(victim):
		players[victim]["alive"] = false
		players[victim]["hp"] = 0.0
	_apply_scores(scores)
	died.emit(victim, killer, weapon)
	roster_changed.emit()

## Server: put `id` back into the arena at the best spawn set.
func _srv_respawn(id: int) -> void:
	if not players.has(id) or not match_running:
		return
	_respawn_at.erase(id)
	var sp: Dictionary = _srv_pick_spawn()
	var v: Dictionary = players[id]
	v["hp"] = max_hp_of(id)
	v["armor"] = 0.0
	v["alive"] = true
	v["pos"] = sp["pos"]
	_s_respawn.rpc(id, sp["pos"], sp["yaw"])
	_s_respawn(id, sp["pos"], sp["yaw"])

## The spawn set farthest from every living actor (DOS picks at random
## among the 10 pairs; distance keeps spawn-kills rare).
func _srv_pick_spawn() -> Dictionary:
	if spawn_points.is_empty():
		return {"pos": Vector3(32768, 800, -32768), "yaw": 0.0}
	var best: Dictionary = spawn_points[randi() % spawn_points.size()]
	var best_d: float = -1.0
	for sp in spawn_points:
		var d: float = 1e12
		for id in players:
			var p: Dictionary = players[id]
			if bool(p["alive"]):
				d = minf(d, (p["pos"] as Vector3).distance_to(sp["pos"]))
		d += randf() * 300.0                 # jitter so ties do not repeat
		if d > best_d:
			best_d = d
			best = sp
	return best

@rpc("authority", "call_remote", "reliable")
func _s_respawn(id: int, pos: Vector3, yaw: float) -> void:
	if players.has(id):
		var v: Dictionary = players[id]
		v["alive"] = true
		v["hp"] = max_hp_of(id)
		v["armor"] = 0.0
		v["pos"] = pos
	if id == local_id:
		local_health_changed.emit(max_hp_of(id), 0.0, 0)
	respawned.emit(id, pos, yaw)
	roster_changed.emit()

# ---------------------------------------------------------------------
# Pickups (server places them from NETLEVEL counts, owns their state)
# ---------------------------------------------------------------------

## Server, once the map is up: scatter the arena's items over the marker
## spots. `ammo_spots` = marker 100, `weapon_spots` = 101/102 (falls back
## to the ammo spots).
func server_place_pickups(ammo_spots: Array, weapon_spots: Array) -> void:
	if not is_server():
		return
	pickups.clear()
	_pickup_respawn_at.clear()
	_next_pickup_key = 1
	if weapon_spots.is_empty():
		weapon_spots = ammo_spots
	var a: Array = ammo_spots.duplicate()
	var w: Array = weapon_spots.duplicate()
	a.shuffle()
	w.shuffle()
	var ai: int = 0
	var wi: int = 0
	var items: Dictionary = settings.get("items", {})
	for cat in ITEM_SPRITES:
		var count: int = int(items.get(cat, 0))
		var choices: Array = ITEM_SPRITES[cat]
		for _i in count:
			var pos: Vector3
			if WEAPON_CATEGORIES.has(cat):
				if w.is_empty():
					break
				pos = w[wi % w.size()]
				wi += 1
			else:
				if a.is_empty():
					break
				pos = a[ai % a.size()]
				ai += 1
			var si: int = int(choices[randi() % choices.size()])
			pickups[_next_pickup_key] = {"si": si, "pos": pos, "taken": false}
			_next_pickup_key += 1
	print("[net] placed %d pickups on %d ammo / %d weapon spots" % [pickups.size(), a.size(), w.size()])

## The local actor (or a server bot, via `by`) walked over pickup `key`.
func request_pickup(key: int, by: int = -1) -> void:
	if not active or not pickups.has(key) or bool(pickups[key]["taken"]):
		return
	if is_server():
		_srv_pickup(key, local_id if by < 0 else by)
	else:
		_c_pickup.rpc_id(1, key)

@rpc("any_peer", "call_remote", "reliable")
func _c_pickup(key: int) -> void:
	if is_server():
		_srv_pickup(key, multiplayer.get_remote_sender_id())

func _srv_pickup(key: int, by: int) -> void:
	if not pickups.has(key) or bool(pickups[key]["taken"]) or not players.has(by):
		return
	if not bool(players[by]["alive"]):
		return
	var p: Dictionary = pickups[key]
	p["taken"] = true
	# Health / armor are server state; ammo and weapons are the taker's.
	var item: Array = PickupData.ITEMS.get(int(p["si"]), [])
	if item.size() >= 6:
		var v: Dictionary = players[by]
		var heal: int = int(item[2])
		var armor: int = int(item[3])
		if heal > 0:
			v["hp"] = minf(float(v["hp"]) + max_hp_of(by) * float(heal) / 100.0, max_hp_of(by))
		if armor > 0:
			v["armor"] = clampf(float(v["armor"]) + float(armor) / 65536.0, 0.0, 1.0)
		if heal > 0 or armor > 0:
			_srv_send_health(by, 0)
	if bool(settings.get("replenish", true)):
		_pickup_respawn_at[key] = Time.get_ticks_msec() + int(PICKUP_RESPAWN * 1000.0)
	_s_pickup_taken.rpc(key, by)
	_s_pickup_taken(key, by)

@rpc("authority", "call_remote", "reliable")
func _s_pickup_taken(key: int, by: int) -> void:
	if pickups.has(key):
		pickups[key]["taken"] = true
	pickup_taken.emit(key, by)

@rpc("authority", "call_remote", "reliable")
func _s_pickup_spawn(key: int) -> void:
	if pickups.has(key):
		pickups[key]["taken"] = false
	pickup_spawned.emit(key)

# ---------------------------------------------------------------------
# Bots (server)
# ---------------------------------------------------------------------

const BOT_NAMES: Array = ["T-800", "T-600", "HK-UNIT", "SKYNET", "CYBERDYNE",
	"ENDO", "T-1000", "SERIES 800", "DYSON", "REESE", "CONNOR", "MARCUS"]

func _srv_add_bot() -> int:
	var id: int = BOT_ID_BASE - _bot_seq
	_bot_seq += 1
	var nm: String = BOT_NAMES[(BOT_ID_BASE - id) % BOT_NAMES.size()]
	if _name_taken(nm):
		nm = "%s-%d" % [nm, BOT_ID_BASE - id + 1]
	players[id] = _new_player(nm, true, randi() % 2)
	return id

## Host console / menu: add or remove bots mid-game.
func set_bot_count(n: int) -> void:
	if not is_server():
		return
	n = clampi(n, 0, 12)
	var bots: Array = []
	for id in players:
		if is_bot(id):
			bots.append(id)
	while bots.size() > n:
		var id: int = bots.pop_back()
		_s_player_remove.rpc(id)
		_s_player_remove(id)
	while bots.size() < n:
		var id: int = _srv_add_bot()
		bots.append(id)
		_s_player_add.rpc(id, players[id])
		player_joined.emit(id)
		roster_changed.emit()
		if level_ready:
			_srv_respawn(id)
	settings["bots"] = n

# ---------------------------------------------------------------------
# Chat, clock, match end
# ---------------------------------------------------------------------

func send_chat(text: String) -> void:
	text = text.strip_edges().substr(0, 120)
	if text.is_empty() or not active:
		return
	if is_server():
		_srv_chat(local_id, text)
	else:
		_c_chat.rpc_id(1, text)

@rpc("any_peer", "call_remote", "reliable")
func _c_chat(text: String) -> void:
	if is_server():
		_srv_chat(multiplayer.get_remote_sender_id(), text.substr(0, 120))

func _srv_chat(from: int, text: String) -> void:
	_s_chat.rpc(from, text)
	_s_chat(from, text)

@rpc("authority", "call_remote", "reliable")
func _s_chat(from: int, text: String) -> void:
	chat_received.emit(from, text)

@rpc("authority", "call_remote", "unreliable")
func _s_time(sec: int) -> void:
	time_left = float(sec)
	time_changed.emit(sec)

func _srv_end_match(reason: String) -> void:
	if not match_running:
		return
	match_running = false
	var scores := _scores_wire()
	_s_match_over.rpc(reason, scores)
	_s_match_over(reason, scores)

@rpc("authority", "call_remote", "reliable")
func _s_match_over(reason: String, scores: Dictionary) -> void:
	match_running = false
	_apply_scores(scores)
	match_over.emit(reason)

## Host: new round on the same map — scores wiped, everyone respawned.
func restart_match() -> void:
	if not is_server():
		return
	for id in players:
		players[id]["kills"] = 0
		players[id]["deaths"] = 0
		players[id]["alive"] = false
	time_left = float(settings.get("time_limit", 0)) * 60.0
	match_running = true
	for k in pickups:
		pickups[k]["taken"] = false
	_pickup_respawn_at.clear()
	_s_restart.rpc()
	_s_restart()
	for id in players:
		_srv_respawn(id)

@rpc("authority", "call_remote", "reliable")
func _s_restart() -> void:
	match_running = true
	for id in players:
		players[id]["kills"] = 0
		players[id]["deaths"] = 0
	for k in pickups:
		pickups[k]["taken"] = false
	match_restarted.emit()
	roster_changed.emit()

# ---------------------------------------------------------------------
# Server clock: respawns, pickup respawns, time limit, LAN discovery
# ---------------------------------------------------------------------

func _process(delta: float) -> void:
	if not active:
		return
	if not is_server():
		if match_running and time_left > 0.0:
			time_left = maxf(time_left - delta, 0.0)
		return
	var now: int = Time.get_ticks_msec()
	_srv_vehicles_tick(now)
	for id in _respawn_at.keys():
		if now >= int(_respawn_at[id]):
			_srv_respawn(id)
	for k in _pickup_respawn_at.keys():
		if now >= int(_pickup_respawn_at[k]):
			_pickup_respawn_at.erase(k)
			if pickups.has(k):
				_s_pickup_spawn.rpc(k)
				_s_pickup_spawn(k)
	if match_running and int(settings.get("time_limit", 0)) > 0:
		time_left = maxf(time_left - delta, 0.0)
		var sec: int = int(ceil(time_left))
		if sec != _time_sent:
			_time_sent = sec
			_s_time.rpc(sec)
			time_changed.emit(sec)
		if time_left <= 0.0:
			_srv_end_match("TIME LIMIT REACHED")
	_poll_discovery()

## Scores sorted by kills (desc) then deaths (asc): [[id, name, k, d, bot], …].
func scoreboard() -> Array:
	var rows: Array = []
	for id in players:
		var p: Dictionary = players[id]
		rows.append([id, String(p["name"]), int(p["kills"]), int(p["deaths"]), bool(p["bot"])])
	rows.sort_custom(func(a, b) -> bool:
		if a[2] != b[2]:
			return a[2] > b[2]
		return a[3] < b[3])
	return rows

# --- LAN discovery (server side; the browser lives in net_discovery.gd) --

func _start_discovery() -> void:
	_discovery = PacketPeerUDP.new()
	if _discovery.bind(DISCOVERY_PORT) != OK:
		push_warning("[net] discovery port %d busy — the server will not show in the LAN browser" % DISCOVERY_PORT)
		_discovery = null

func _stop_discovery() -> void:
	if _discovery != null:
		_discovery.close()
		_discovery = null

func _poll_discovery() -> void:
	if _discovery == null:
		return
	while _discovery.get_available_packet_count() > 0:
		var pkt: PackedByteArray = _discovery.get_packet()
		if pkt.get_string_from_utf8() != DISCOVERY_MAGIC:
			continue
		var humans: int = 0
		var bots: int = 0
		for p in players.values():
			if bool(p["bot"]):
				bots += 1
			else:
				humans += 1
		var reply := {"name": String(settings.get("name", "SKYNET")), "map": String(settings.get("map", "")),
			"players": humans, "bots": bots, "max": int(settings.get("max_players", 0)),
			"port": int(settings.get("port", DEFAULT_PORT))}
		_discovery.set_dest_address(_discovery.get_packet_ip(), _discovery.get_packet_port())
		_discovery.put_packet(JSON.stringify(reply).to_utf8_buffer())

# ---------------------------------------------------------------------
# Player classes
# ---------------------------------------------------------------------

## Which body the player picked in the network screen's model box. The
## two CLASSES above are what the rules care about; this is the LOOK, and
## DOS keeps the two apart the same way — its avatar table (skynet.EXE
## 0x84dd4) names twelve characters that share three bodies. Menu-side
## (menu.gd CLASS_AVATARS) decides which body a given index is; here it
## is only remembered between sessions.
var local_avatar: int = 0

func set_avatar(i: int) -> void:
	local_avatar = maxi(i, 0)
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("net", "avatar", local_avatar)
	cfg.save(CFG_PATH)

func class_of(id: int) -> int:
	if players.has(id):
		return clampi(int(players[id].get("cls", CLASS_HUMAN)), 0, 1)
	return CLASS_HUMAN

func max_hp_of(id: int) -> float:
	return float(CLASS_HP[class_of(id)])

## Choose HUMAN / TERMINATOR for the local player; in a running game it
## takes effect on the next spawn (the server tracks it).
func set_class(cls: int) -> void:
	local_class = clampi(cls, 0, 1)
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("net", "name", local_name)
	cfg.set_value("net", "class", local_class)
	cfg.save(CFG_PATH)
	if not active:
		return
	if is_server():
		_srv_set_class(local_id, local_class)
	else:
		_c_set_class.rpc_id(1, local_class)

@rpc("any_peer", "call_remote", "reliable")
func _c_set_class(cls: int) -> void:
	if is_server():
		_srv_set_class(multiplayer.get_remote_sender_id(), cls)

func _srv_set_class(id: int, cls: int) -> void:
	if not players.has(id):
		return
	cls = clampi(cls, 0, 1)
	_s_class.rpc(id, cls)
	_s_class(id, cls)

@rpc("authority", "call_remote", "reliable")
func _s_class(id: int, cls: int) -> void:
	if players.has(id):
		players[id]["cls"] = cls
	class_changed.emit(id, cls)
	roster_changed.emit()

# ---------------------------------------------------------------------
# Vehicles (server places NETLEVEL `jeeps` / `hks`; one driver each)
# ---------------------------------------------------------------------

## key → {kind (1 jeep, 2 HK), pos, yaw, driver (0 = parked)}
var vehicles: Dictionary = {}
var _next_vehicle_key: int = 1
const VEHICLE_RESPAWN: float = 30.0
var _vehicle_respawn_at: Dictionary = {}   # key → msec (after a driver died)
const F_VEH_SHIFT: int = 3                 # pose flags bits 3-4 = vehicle kind

## Server, once the map is up: park the arena's vehicles on item spots.
func server_place_vehicles(spots: Array) -> void:
	if not is_server() or spots.is_empty():
		return
	vehicles.clear()
	_vehicle_respawn_at.clear()
	_next_vehicle_key = 1
	var s: Array = spots.duplicate()
	s.shuffle()
	var items: Dictionary = settings.get("items", {})
	var i: int = 0
	for spec in [["jeeps", 1], ["hks", 2]]:
		for _n in int(items.get(spec[0], 0)):
			if s.is_empty():
				break
			var pos: Vector3 = s[i % s.size()]
			i += 1
			vehicles[_next_vehicle_key] = {"kind": int(spec[1]), "pos": pos, "yaw": randf() * TAU,
				"driver": 0, "home": pos}
			_next_vehicle_key += 1
	print("[net] parked %d vehicles" % vehicles.size())

func _vehicles_wire() -> Dictionary:
	var out: Dictionary = {}
	for k in vehicles:
		var v: Dictionary = vehicles[k]
		out[k] = [int(v["kind"]), v["pos"], float(v["yaw"]), int(v["driver"])]
	return out

func _apply_vehicles_wire(wire: Dictionary) -> void:
	vehicles.clear()
	for k in wire:
		var a: Array = wire[k]
		vehicles[int(k)] = {"kind": int(a[0]), "pos": a[1], "yaw": float(a[2]), "driver": int(a[3]), "home": a[1]}

## The vehicle `id` drives, or 0.
func vehicle_of(id: int) -> int:
	for k in vehicles:
		if int(vehicles[k]["driver"]) == id:
			return int(k)
	return 0

func vehicle_kind_of(id: int) -> int:
	var k: int = vehicle_of(id)
	return int(vehicles[k]["kind"]) if k > 0 else 0

## Local player wants the seat of parked vehicle `key`.
func request_vehicle(key: int) -> void:
	if not active or not vehicles.has(key):
		return
	if is_server():
		_srv_vehicle_enter(local_id, key)
	else:
		_c_vehicle_enter.rpc_id(1, key)

## Local player climbs out at `pos` facing `yaw`.
func leave_vehicle(pos: Vector3, yaw: float) -> void:
	if not active:
		return
	if is_server():
		_srv_vehicle_exit(local_id, pos, yaw)
	else:
		_c_vehicle_exit.rpc_id(1, pos, yaw)

@rpc("any_peer", "call_remote", "reliable")
func _c_vehicle_enter(key: int) -> void:
	if is_server():
		_srv_vehicle_enter(multiplayer.get_remote_sender_id(), key)

@rpc("any_peer", "call_remote", "reliable")
func _c_vehicle_exit(pos: Vector3, yaw: float) -> void:
	if is_server():
		_srv_vehicle_exit(multiplayer.get_remote_sender_id(), pos, yaw)

func _srv_vehicle_enter(id: int, key: int) -> void:
	if not vehicles.has(key) or not is_alive(id) or vehicle_of(id) != 0:
		return
	var v: Dictionary = vehicles[key]
	if int(v["driver"]) != 0:
		return
	v["driver"] = id
	_s_vehicle.rpc(key, id, v["pos"], float(v["yaw"]))
	_s_vehicle(key, id, v["pos"], float(v["yaw"]))

func _srv_vehicle_exit(id: int, pos: Vector3, yaw: float) -> void:
	var key: int = vehicle_of(id)
	if key == 0:
		return
	var v: Dictionary = vehicles[key]
	v["driver"] = 0
	v["pos"] = pos
	v["yaw"] = yaw
	_s_vehicle.rpc(key, 0, pos, yaw)
	_s_vehicle(key, 0, pos, yaw)

## A driver died: the wreck is parked where they fell, then returns to
## its spot after VEHICLE_RESPAWN.
func _srv_vehicle_driver_died(id: int) -> void:
	var key: int = vehicle_of(id)
	if key == 0:
		return
	var v: Dictionary = vehicles[key]
	v["driver"] = 0
	v["pos"] = players[id]["pos"] if players.has(id) else v["home"]
	_s_vehicle.rpc(key, 0, v["pos"], float(v["yaw"]))
	_s_vehicle(key, 0, v["pos"], float(v["yaw"]))
	_vehicle_respawn_at[key] = Time.get_ticks_msec() + int(VEHICLE_RESPAWN * 1000.0)

func _srv_vehicles_tick(now: int) -> void:
	for k in _vehicle_respawn_at.keys():
		if now >= int(_vehicle_respawn_at[k]):
			_vehicle_respawn_at.erase(k)
			if vehicles.has(k) and int(vehicles[k]["driver"]) == 0:
				var v: Dictionary = vehicles[k]
				v["pos"] = v["home"]
				_s_vehicle.rpc(k, 0, v["pos"], float(v["yaw"]))
				_s_vehicle(k, 0, v["pos"], float(v["yaw"]))

signal vehicle_changed(key: int, driver: int, pos: Vector3, yaw: float)

@rpc("authority", "call_remote", "reliable")
func _s_vehicle(key: int, driver: int, pos: Vector3, yaw: float) -> void:
	if vehicles.has(key):
		var v: Dictionary = vehicles[key]
		v["driver"] = driver
		v["pos"] = pos
		v["yaw"] = yaw
	vehicle_changed.emit(key, driver, pos, yaw)
