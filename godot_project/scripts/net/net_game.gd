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
##   * the arena's TRIGGER STATE is the server's too (M5): doors, levers,
##     destructibles, ambient loops
##
## What is on the wire, and what is not. Until M5 the welcome carried the
## roster, the pickups and the vehicles and NOTHING of the map itself, so
## a door one peer opened was open for that peer alone. Now:
##
##   sent to the server   `_c_trigger`: "I used / I shot entity N" — an
##                        INTENT, never a result. The server runs it
##                        through the real entry point of its own level
##                        (Behaviour.on_player_activate / obj_hit), which
##                        measures the DOS radius, tests the state bits
##                        and walks the chain exactly as it does in the
##                        campaign.
##   sent to a client     `_s_trigger`: what changed since the last frame
##                        — state bytes, act bytes, links, ObjHit's pool
##                        and what it spent, the movers' travel, the
##                        wrecks' stage, the robots let out, and the cues
##                        to play. Reliable and ordered, and sent only
##                        when something changed.
##   sent on joining      `_s_welcome` carries the server's whole trigger
##                        overlay, so a late joiner walks into the doors
##                        that are already open.
##   what a crate DROPS   `_s_pickup_add`: the item a broken prop leaves
##                        behind (DOS FUN_00124293 picks it from the
##                        destruction type's list at Skynet.exe 0x423d6 and
##                        writes it into the record list, v1.01
##                        FUN_00124619). The server picks it, as it picks
##                        the arena's own, and it is a server-owned pickup
##                        from then on — one key, taken once, by whoever
##                        the server says reached it first. It does not
##                        come back (a drop is not a NETLEVEL spot) and a
##                        new round starts without it. Protocol 4.
##
## NOT on the wire, and each for a reason: a mover's POSITION (the delta
## brings the flip and where the mover stood, and every peer animates the
## rest from its own copy of the map — the travel is the same data on
## both sides); the enemies and the objectives (an arena has neither);
## the map EXITS (an arena is one map — a client asks for no map change);
## and a drop that is scenery rather than an item (a wreck's fire sprite:
## the host shows its own, and nothing about it can be taken).
##
## Method prefixes: `_c_*` = client → server RPC (the sender is the actor),
## `_s_*` = server → client RPC (also invoked locally on the host so one
## code path updates every peer), `_srv_*` = server-only logic. Every
## `_c_*` is untrusted input: it passes a `_srv_client_*` / `_gate` check
## (admitted sender, per-peer rate budget, sane values) before it counts.
## The hello and the kick are raw bytes, not RPCs (see PROTOCOL_VERSION).
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
## The local player picked a class; it is worn from the next spawn.
signal class_requested(cls: int)
## The server has changed something in the map (TriggerRuntime.net_delta);
## the DM controller lays it over its level.
signal trigger_delta(delta: Dictionary)
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

## Wire protocol version, sent in the hello. Bump it whenever an RPC on
## this node is added, removed, renamed or changes its arguments: Godot
## addresses RPCs by their index in the node's sorted method list, so two
## builds with different RPC sets cannot even deliver a call to each
## other. That is why the hello and the kick travel as raw bytes
## (send_bytes), outside that list — a mismatch still gets its reason
## across instead of hanging on "Connecting...".
## 4: `_s_pickup_add` — a broken crate's drop is a server-owned pickup,
## and the pickup wire carries whether each one is a drop.
const PROTOCOL_VERSION: int = 4
const HELLO_TAG: String = "SKYNET_HELLO"      # HELLO_TAG|version|class|name
const KICK_TAG: String = "SKYNET_KICK"        # KICK_TAG|reason
const MAX_RAW_BYTES: int = 256
## A peer that has not said hello by then is dropped (a silent connection
## would hold a slot for ever); a kicked peer gets this long to take its
## reason and go before it is cut off.
const HELLO_TIMEOUT_MS: int = 10000
const KICK_GRACE_MS: int = 2000
const MAX_NAME_LEN: int = 16
const MAX_CHAT_LEN: int = 120
const MAX_SERVER_NAME_LEN: int = 48
## LAN browser replies: at most one per source address per this long, and
## only so many probes read per frame.
const DISCOVERY_REPLY_MS: int = 500
const DISCOVERY_MAX_PER_POLL: int = 16
const DISCOVERY_SEEN_MAX: int = 256

## Sanity bounds for what clients report. The arena is a 65 536-unit
## square (256 cells of 256), so a coordinate four times that is garbage.
const WORLD_BOUND: float = 262144.0
## The biggest single hit any weapon deals: the SATCHEL's blast, 700
## (fly_camera.gd secondary table; the rockets are 400). A client's
## reported hit is clamped to it.
const MAX_HIT_DAMAGE: float = 700.0
## The hitscan ray is 60 000 units long (fly_camera.gd, bot_brain.gd);
## farther than that plus pose lag, the reporter cannot have hit anyone.
const MAX_HIT_RANGE: float = 64000.0
## Somebody killed with a rocket or grenade still in the air may still
## land it: a trade counts for both.
const DEAD_SHOT_GRACE_MS: int = 1500
## Reach checked against the server's last pose of the taker: the DOS
## grab box (80 across, 160 up) / the 600-unit use ray plus half an HK
## hull, each with room for pose lag at full speed.
const PICKUP_REACH: float = 800.0
const VEHICLE_REACH: float = 1400.0
## Per-peer budgets for client RPCs as [per second, burst]; anything past
## a budget is dropped. Poses come at POSE_HZ, the fastest gun (SUPER UZI)
## fires 20 rounds a second, one splash reports several hits at once;
## hits on yourself (drowning, radiation) arrive once per rendered frame
## and hurt nobody else, so they get their own, looser budget. The rest
## are human-speed actions. RL_DAMAGE counts hit points dealt to others,
## each hit capped at the victim's full health so overkill is free: a
## satchel in a full arena at once, then the SUPER UZI's 1000 a second.
## RL_TRIGGER is a door being used and a shot landing on a destructible:
## the same human speed as a pickup, with room for one burst of gunfire
## emptying into a car.
enum { RL_POSE, RL_FIRE, RL_HIT, RL_SELF_HIT, RL_CHAT, RL_PICKUP, RL_VEHICLE, RL_CLASS, RL_DAMAGE,
	RL_TRIGGER }
const RATE_LIMITS: Array = [[30.0, 15.0], [20.0, 20.0], [60.0, 60.0], [300.0, 300.0], [2.0, 4.0],
	[10.0, 10.0], [4.0, 4.0], [2.0, 3.0], [1500.0, 6000.0], [20.0, 30.0]]

## What a client says it did to an entity of the map. USE is every way a
## player sets a chain off — walking into a trigger, the use key, the
## crosshair on a lever — because they all end in one call on the
## server's branch (Behaviour.on_player_activate), which applies the
## record's own measure whichever way the key arrived. HIT is a shot or a
## blast on something that takes damage.
const TRIG_USE: int = 0
const TRIG_HIT: int = 1
## How far the place a client reports may be from where the server last
## saw it, and how far the ENTITY may be from there for a use — an HK
## hull plus pose lag, the vehicle reach. A shot may come from as far as
## a hitscan carries.
const TRIGGER_REACH: float = 1400.0

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
## key → {si (sprite index), pos (Vector3), taken (bool), drop (bool:
## left by a broken prop, not placed from NETLEVEL.PRS)}
var pickups: Dictionary = {}
var time_left: float = 0.0
var match_running: bool = false
## Server: spawn sets [{pos, yaw}] set by the DM controller once the map
## is up; pending hellos wait for it.
var spawn_points: Array = []
var level_ready: bool = false

## The arena as an object the net code may ask things of — the DM
## controller (scripts/net/dm_game.gd), set on the server once its level
## is up and cleared when it goes. Net knows nothing of levels, records
## or trigger runtimes; it asks this for the three things the wire needs:
##
##   trigger_snapshot()                  the overlay the welcome carries
##   trigger_pos(off) -> Vector3         where that record stands (INF:
##                                       no such record), for the reach
##   trigger_intent(off, kind, at, eye, amount)
##                                       run it through the real entry
##                                       point of the server's level
var trigger_world: Node = null
## Client: the overlay that came in the welcome, laid over the level's
## runtime as soon as the arena is up (the welcome arrives long before
## it). Cleared once it has been used.
var trigger_snapshot: Dictionary = {}

## A note for the main menu to flash after a forced return (kicked,
## server gone).
var pending_message: String = ""

var _peer: ENetMultiplayerPeer = null
var _pending_hellos: Dictionary = {}       # id → [name, cls] before the level is up
var _hello_deadline: Dictionary = {}       # id → msec: connected, no hello yet
var _kick_at: Dictionary = {}              # id → msec: kicked, cut off then
var _buckets: Dictionary = {}              # id → [Bucket per RL_*]
var _level_ready_peers: Dictionary = {}    # id → true: had its level_ready spawn
var _pending_class: Dictionary = {}        # id → class for the next spawn
var _died_at: Dictionary = {}              # id → msec of the last death
var _kick_reason: String = ""              # client: why the server sent us away
var _due: Array = []                       # scratch list for the timer sweeps
var _discovery_seen: Dictionary = {}       # ip → msec of the last reply
var _respawn_at: Dictionary = {}           # id → msec
var _pickup_respawn_at: Dictionary = {}    # key → msec
var _next_pickup_key: int = 1
var _pose_accum: float = 0.0
var _time_sent: int = -1
var _discovery: PacketPeerUDP = null
var _bot_seq: int = 0

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
	local_name = _clean_text(n, MAX_NAME_LEN)
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
	# The host relays what clients send itself, checked on the way; Godot's
	# own relay would pass client-to-client packets through unchecked.
	(multiplayer as SceneMultiplayer).server_relay = false
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	(multiplayer as SceneMultiplayer).peer_packet.connect(_on_peer_packet)
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
func join(ip: String, port: int, nm: String) -> bool:
	leave()
	save_name(nm)
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
	(multiplayer as SceneMultiplayer).peer_packet.connect(_on_peer_packet)
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
				["server_disconnected", _on_server_disconnected], ["peer_packet", _on_peer_packet]]:
			if multiplayer.is_connected(sig[0], sig[1]):
				multiplayer.disconnect(sig[0], sig[1])
		_peer.close()
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
		_peer = null
	active = false
	match_running = false
	level_ready = false
	local_id = 0
	players.clear()
	pickups.clear()
	spawn_points.clear()
	_pending_hellos.clear()
	_hello_deadline.clear()
	_kick_at.clear()
	_buckets.clear()
	_level_ready_peers.clear()
	_pending_class.clear()
	_died_at.clear()
	_kick_reason = ""
	_respawn_at.clear()
	_pickup_respawn_at.clear()
	# The arena's level is going with the session (M5).
	trigger_world = null
	trigger_snapshot.clear()

func _new_player(nm: String, bot: bool, cls: int = CLASS_HUMAN) -> Dictionary:
	return {"name": nm, "kills": 0, "deaths": 0, "hp": MAX_HEALTH, "armor": 0.0,
		"alive": false, "bot": bot, "pos": Vector3.ZERO, "weapon": 1, "cls": cls}

# --- peer events -------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	print("[net] peer %d connected" % id)
	_hello_deadline[id] = Time.get_ticks_msec() + HELLO_TIMEOUT_MS

func _on_peer_disconnected(id: int) -> void:
	print("[net] peer %d left" % id)
	# Queued while the host loaded: without this it was admitted anyway
	# once the level came up, a ghost on the roster for good.
	_pending_hellos.erase(id)
	_hello_deadline.erase(id)
	_kick_at.erase(id)
	_buckets.erase(id)
	if players.has(id):
		_srv_remove_player(id)

func _on_connected() -> void:
	local_id = multiplayer.get_unique_id()
	print("[net] connected, my id %d — hello" % local_id)
	var hello: String = "%s|%d|%d|%s" % [HELLO_TAG, PROTOCOL_VERSION, local_class,
		_clean_text(local_name, MAX_NAME_LEN)]              # the config file may hold anything
	(multiplayer as SceneMultiplayer).send_bytes(hello.to_utf8_buffer(), 1,
		MultiplayerPeer.TRANSFER_MODE_RELIABLE)

func _on_connection_failed() -> void:
	print("[net] connection failed")
	leave()
	connection_failed.emit("Could not reach the server.")

func _on_server_disconnected() -> void:
	# A kick is its reason followed by the disconnect: show the reason,
	# not "closed the game".
	var reason: String = _kick_reason
	var in_game: bool = active
	print("[net] server went away%s" % ("" if reason.is_empty() else " — " + reason))
	leave()
	if reason.is_empty():
		disconnected.emit("The server closed the game.")
	else:
		_report_kick(reason, in_game)

# ---------------------------------------------------------------------
# Join handshake
# ---------------------------------------------------------------------

## Raw packets, outside the RPC table: the hello on the server, the kick on
## a client.
func _on_peer_packet(id: int, pkt: PackedByteArray) -> void:
	if pkt.size() > MAX_RAW_BYTES:
		return
	var text: String = pkt.get_string_from_utf8()
	if is_server():
		if text.begins_with(HELLO_TAG + "|"):
			_srv_hello(id, text)
	elif id == 1 and _kick_reason.is_empty() and text.begins_with(KICK_TAG + "|"):
		_kick_reason = _clean_text(text.substr(KICK_TAG.length() + 1), MAX_RAW_BYTES)
		if _kick_reason.is_empty():
			_kick_reason = "Kicked by the server."
		# Not from inside the multiplayer poll that delivered it.
		_client_kicked.call_deferred()

func _client_kicked() -> void:
	if _kick_reason.is_empty():
		return                                 # the disconnect already reported it
	var reason: String = _kick_reason
	var in_game: bool = active
	leave()
	_report_kick(reason, in_game)

## The join screen listens for `connection_failed`; a game in progress for
## `disconnected`.
func _report_kick(reason: String, in_game: bool) -> void:
	if in_game:
		disconnected.emit(reason)
	else:
		connection_failed.emit(reason)

## Server: a hello, "SKYNET_HELLO|version|class|name". A peer already
## admitted, queued or kicked is ignored: a replayed hello used to re-admit
## with the score wiped, a new name and "ENTERED THE GAME" again.
func _srv_hello(id: int, text: String) -> void:
	if players.has(id) or _pending_hellos.has(id) or _kick_at.has(id):
		return
	var parts: PackedStringArray = text.split("|", true, 3)
	if parts.size() < 2:
		return                                 # garbage: the hello deadline drops it
	# The version is read before the rest, so a later build with another
	# hello layout is still told why.
	var version: int = parts[1].to_int() if parts[1].is_valid_int() else -1
	if version != PROTOCOL_VERSION:
		_srv_kick(id, "Version mismatch: the server speaks network protocol %d, this game %d. Both need the same build."
			% [PROTOCOL_VERSION, version])
		return
	if parts.size() < 4:
		return
	_hello_deadline.erase(id)
	var cls: int = clampi(parts[2].to_int(), 0, 1) if parts[2].is_valid_int() else CLASS_HUMAN
	var nm: String = _clean_text(parts[3], MAX_NAME_LEN)
	if not level_ready:
		_pending_hellos[id] = [nm, cls]
		return
	_srv_admit(id, nm, cls)

## Server: tell `id` why and let it go. The reason travels as raw bytes (a
## client of another build must still read it); ENet disconnects the peer
## once that is sent, and `_process` cuts it off after KICK_GRACE_MS if it
## hangs on.
func _srv_kick(id: int, reason: String) -> void:
	if _kick_at.has(id) or not multiplayer.get_peers().has(id):
		return
	print("[net] kicking peer %d: %s" % [id, reason])
	_pending_hellos.erase(id)
	_hello_deadline.erase(id)
	_kick_at[id] = Time.get_ticks_msec() + KICK_GRACE_MS
	(multiplayer as SceneMultiplayer).send_bytes(("%s|%s" % [KICK_TAG, reason]).to_utf8_buffer(), id,
		MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	var pp: ENetPacketPeer = _peer.get_peer(id)
	if pp != null:
		pp.peer_disconnect_later()

## Server: peers that never said hello, and kicked peers still hanging on,
## are cut off. They stay in `_kick_at` as -1 until peer_disconnected
## arrives, so a hello squeezed in meanwhile is not taken.
func _srv_drop_stale_peers(now: int) -> void:
	_due.clear()
	for id in _hello_deadline:
		if now >= int(_hello_deadline[id]):
			_due.append(id)
	for id in _kick_at:
		if int(_kick_at[id]) >= 0 and now >= int(_kick_at[id]):
			_due.append(id)
	for id in _due:
		_hello_deadline.erase(id)
		if multiplayer.get_peers().has(id):
			print("[net] dropping peer %d (no hello / kicked)" % id)
			_kick_at[id] = -1
			_peer.disconnect_peer(id)
		else:
			_kick_at.erase(id)

func _srv_admit(id: int, map_name: String, cls: int = CLASS_HUMAN) -> void:
	# Already in, or gone while the host was still loading.
	if players.has(id) or not multiplayer.get_peers().has(id):
		return
	var maxp: int = int(settings.get("max_players", 0))
	var humans: int = 0
	for p in players.values():
		if not bool(p["bot"]):
			humans += 1
	if maxp > 0 and humans >= maxp:
		_srv_kick(id, "Server is full.")
		return
	# Unique display name.
	var base := _clean_text(map_name, MAX_NAME_LEN)
	if base.is_empty():
		base = "PLAYER"
	var nm := base
	var n := 2
	while _name_taken(nm):
		nm = "%s%d" % [base, n]
		n += 1
	players[id] = _new_player(nm, false, clampi(cls, 0, 1))
	_s_welcome.rpc_id(id, settings, players, _pickups_wire(), int(time_left), match_running,
		_vehicles_wire(), _trigger_wire())
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

## The server's whole trigger overlay for a joiner — every door play has
## opened, every crate it has broken. Empty in the campaign and on a peer
## whose level is not up yet (nothing has happened there either).
func _trigger_wire() -> Dictionary:
	if trigger_world == null or not is_instance_valid(trigger_world):
		return {}
	return trigger_world.trigger_snapshot()

func _pickups_wire() -> Dictionary:
	var out: Dictionary = {}
	for k in pickups:
		var p: Dictionary = pickups[k]
		out[k] = [int(p["si"]), p["pos"], bool(p["taken"]), bool(p.get("drop", false))]
	return out

@rpc("authority", "call_remote", "reliable")
func _s_welcome(cfg: Dictionary, roster: Dictionary, wire: Dictionary, tl: int, running: bool,
		veh: Dictionary = {}, trig: Dictionary = {}) -> void:
	settings = cfg
	_apply_vehicles_wire(veh)
	trigger_snapshot = trig
	players = roster
	pickups.clear()
	for k in wire:
		var a: Array = wire[k]
		pickups[int(k)] = {"si": int(a[0]), "pos": a[1], "taken": bool(a[2]),
			"drop": a.size() > 3 and bool(a[3])}
	time_left = float(tl)
	match_running = running
	active = true
	print("[net] welcome: map %s, %d players, %d pickups" % [settings.get("map", "?"), players.size(), pickups.size()])
	welcome_received.emit()
	roster_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _s_player_add(id: int, info: Dictionary) -> void:
	players[id] = info
	player_joined.emit(id)
	roster_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _s_player_remove(id: int) -> void:
	players.erase(id)
	_respawn_at.erase(id)
	_buckets.erase(id)
	_level_ready_peers.erase(id)
	_pending_class.erase(id)
	_died_at.erase(id)
	player_left.emit(id)
	roster_changed.emit()

## Server: `id` leaves the game — out of any seat first (the vehicle
## stayed hidden and unenterable with a departed driver), then off every
## roster.
func _srv_remove_player(id: int) -> void:
	_srv_vehicle_driver_died(id)
	_s_player_remove.rpc(id)
	_s_player_remove(id)

## The map is loaded on this peer: ask the server for a spawn. On the
## host this also releases queued joins.
func report_level_ready() -> void:
	if not active:
		return
	if is_server():
		level_ready = true
		_level_ready_peers.clear()             # a new level: one spawn each on it
		for id in _pending_hellos.keys():
			var h: Array = _pending_hellos[id]
			_srv_admit(int(id), String(h[0]), int(h[1]))
		_pending_hellos.clear()
		_srv_respawn(local_id)
		for id in players:
			if is_bot(id):
				_srv_respawn(id)
	else:
		_c_level_ready.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _c_level_ready() -> void:
	if is_server():
		_srv_level_ready(multiplayer.get_remote_sender_id())

## Server: `id` has the arena up — its first spawn. Honoured once per peer
## per level: it respawns at full health, so a replay was a free heal.
## (restart_match respawns everybody itself and needs no second one.)
func _srv_level_ready(id: int) -> void:
	if not players.has(id) or _level_ready_peers.has(id):
		return
	_level_ready_peers[id] = true
	if not is_bot(id) and id != local_id:
		# A late joiner needs everyone's current place before their own
		# spawn (poses only flow while people move).
		for other in players:
			if other != id and bool(players[other]["alive"]):
				var p: Dictionary = players[other]
				_s_pose.rpc_id(id, other, p["pos"], 0.0, 0.0, _server_flags(other, 0))
	_srv_respawn(id)

# ---------------------------------------------------------------------
# Client input checks (server)
# ---------------------------------------------------------------------

## A token bucket: `rate` tokens a second, holding at most `burst`.
class Bucket:
	var rate: float
	var burst: float
	var tokens: float
	var last: int

	func _init(r: float, b: float) -> void:
		rate = r
		burst = b
		tokens = b
		last = Time.get_ticks_msec()

	## Spend `cost` if there is that much; false = over the budget.
	func take(cost: float = 1.0) -> bool:
		var now: int = Time.get_ticks_msec()
		tokens = minf(burst, tokens + float(now - last) * 0.001 * rate)
		last = now
		if tokens < cost:
			return false
		tokens -= cost
		return true

## Server: may RPC sender `id` do `kind` (RL_*) now? Admitted peers only —
## nothing before the hello, nothing after a kick — each kind within its
## RATE_LIMITS budget. Whatever fails is dropped.
func _gate(id: int, kind: int) -> bool:
	return players.has(id) and _bucket(id, kind).take()

func _bucket(id: int, kind: int) -> Bucket:
	if not _buckets.has(id):
		var list: Array = []
		for lim in RATE_LIMITS:
			list.append(Bucket.new(float(lim[0]), float(lim[1])))
		_buckets[id] = list
	return _buckets[id][kind]

## A reported position that can be a place in an arena.
func _sane_pos(p: Vector3) -> bool:
	return p.is_finite() and absf(p.x) <= WORLD_BOUND and absf(p.y) <= WORLD_BOUND \
		and absf(p.z) <= WORLD_BOUND

## Player-supplied text made safe to show: control characters and the
## bidi overrides that turn a line around are stripped, the ends trimmed,
## the length capped. The raw string is cut first, so a huge one costs
## nothing to scan.
func _clean_text(s: String, max_len: int) -> String:
	s = s.substr(0, max_len * 4)
	for i in s.length():
		if _is_bad_char(s.unicode_at(i)):
			var out: String = ""
			for j in s.length():
				var c: int = s.unicode_at(j)
				if not _is_bad_char(c):
					out += String.chr(c)
			s = out
			break
	return s.strip_edges().substr(0, max_len)

## C0/C1 controls and DEL; LRM/RLM, the line/paragraph separators and the
## bidi embeddings, overrides and isolates (U+202A-202E, U+2066-2069).
func _is_bad_char(c: int) -> bool:
	return c < 0x20 or (c >= 0x7F and c <= 0x9F) or c == 0x200E or c == 0x200F \
		or (c >= 0x2028 and c <= 0x202E) or (c >= 0x2066 and c <= 0x2069)

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
		_srv_client_pose(multiplayer.get_remote_sender_id(), pos, yaw, pitch, flags)

## Server: a client's pose, if it is a sane one within its budget (it is
## relayed to everybody and becomes the server's idea of where they are).
func _srv_client_pose(id: int, pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	if not _gate(id, RL_POSE) or not _sane_pos(pos) or not is_finite(yaw) or not is_finite(pitch):
		return
	_srv_pose(id, pos, yaw, pitch, flags)

func _srv_pose(id: int, pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	if not players.has(id):
		return
	players[id]["pos"] = pos
	flags = _server_flags(id, flags)
	# Straight to the admitted human peers: no get_peers() array per pose.
	for p in players:
		if p > 1 and p != id:
			_s_pose.rpc_id(p, id, pos, yaw, pitch, flags)
	if id != local_id:
		pose_received.emit(id, pos, yaw, pitch, flags)

## Pose flags as the server knows them: moving and firing are the owner's
## word, dead and the vehicle bits are server state — a client could
## otherwise show itself on foot while it drives.
func _server_flags(id: int, flags: int) -> int:
	flags &= F_MOVING | F_FIRING
	if not is_alive(id):
		flags |= F_DEAD
	var key: int = vehicle_of(id)
	if key != 0:
		flags |= (int(vehicles[key]["kind"]) & 3) << F_VEH_SHIFT
	return flags

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
		_srv_client_fire(multiplayer.get_remote_sender_id(), weapon, from, dir)

## Server: a client's shot, drawn on every other peer (flash, tracer, ray)
## — so only within its budget, from a real place in a real direction.
func _srv_client_fire(id: int, weapon: int, from: Vector3, dir: Vector3) -> void:
	if not _gate(id, RL_FIRE) or not _sane_pos(from) or not dir.is_finite() or dir.length_squared() < 0.01:
		return
	_srv_fire(id, weapon, from, dir.normalized())

func _srv_fire(id: int, weapon: int, from: Vector3, dir: Vector3) -> void:
	if players.has(id):
		players[id]["weapon"] = weapon
	for p in players:
		if p > 1 and p != id:
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
	if not active or not is_finite(dmg) or dmg <= 0.0:
		return
	if is_server():
		_srv_hit(victim, dmg, attacker, weapon)
	else:
		_c_hit.rpc_id(1, victim, dmg, weapon)

@rpc("any_peer", "call_remote", "reliable")
func _c_hit(victim: int, dmg: float, weapon: int) -> void:
	if is_server():
		_srv_client_hit(multiplayer.get_remote_sender_id(), victim, dmg, weapon)

## Server: a hit a client says it scored. The shooter's machine detects
## hits, so this is where a forged one stops: an admitted shooter that is
## alive (or was killed a moment ago with a shot in the air), a real
## positive amount no bigger than any weapon deals, a victim within ray
## range of it, and a damage budget per second. (`_c_hit(anyone, 1e9)`
## killed, NaN left hp NaN for good, a negative amount healed.)
func _srv_client_hit(id: int, victim: int, dmg: float, weapon: int) -> void:
	if not _gate(id, RL_SELF_HIT if victim == id else RL_HIT) or not players.has(victim) \
			or not is_finite(dmg) or dmg <= 0.0:
		return
	if not is_alive(id) and Time.get_ticks_msec() - int(_died_at.get(id, 0)) > DEAD_SHOT_GRACE_MS:
		return
	dmg = minf(dmg, MAX_HIT_DAMAGE)
	if victim != id:
		if (players[id]["pos"] as Vector3).distance_to(players[victim]["pos"]) > MAX_HIT_RANGE:
			return
		if not _bucket(id, RL_DAMAGE).take(minf(dmg, max_hp_of(victim))):
			return
	_srv_hit(victim, dmg, id, weapon)

func _srv_hit(victim: int, dmg: float, attacker: int, weapon: int) -> void:
	if not match_running or not players.has(victim) or not is_finite(dmg) or dmg <= 0.0:
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
	_died_at[victim] = Time.get_ticks_msec()
	_srv_vehicle_driver_died(victim)
	# Only yourself, the world (id 0: drowning, radiation, unattributed
	# splash) or somebody already gone make it a suicide. Bots are NEGATIVE
	# ids — `killer <= 0` took a frag off whoever a bot killed and never
	# gave the bot one.
	if killer == victim or killer == 0 or not players.has(killer):
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
	# No seat carries into the new life: restart_match and level_ready
	# respawn a driver who never died, and the server kept counting them
	# inside (the hull's damage cut, the jeep hidden where it was left).
	_srv_vehicle_driver_died(id)
	# A class picked during the last life is worn from now (set_class).
	if _pending_class.has(id):
		var cls: int = int(_pending_class[id])
		_pending_class.erase(id)
		if cls != class_of(id):
			_s_class.rpc(id, cls)
			_s_class(id, cls)
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
			pickups[_next_pickup_key] = {"si": si, "pos": pos, "taken": false, "drop": false}
			_next_pickup_key += 1
	print("[net] placed %d pickups on %d ammo / %d weapon spots" % [pickups.size(), a.size(), w.size()])

## The local actor (or a server bot, via `by`) walked over pickup `key`.
## `by` = 0 is the local player: bots are NEGATIVE ids, and the old
## "by < 0 means local" handed every bot's pickup to the host.
func request_pickup(key: int, by: int = 0) -> void:
	if not active or not pickups.has(key) or bool(pickups[key]["taken"]):
		return
	if is_server():
		_srv_pickup(key, local_id if by == 0 else by)
	else:
		_c_pickup.rpc_id(1, key)

@rpc("any_peer", "call_remote", "reliable")
func _c_pickup(key: int) -> void:
	if is_server():
		_srv_client_pickup(multiplayer.get_remote_sender_id(), key)

## Server: a client says it walked over `key` — granted only if the
## server's last pose of it stands near (from anywhere on the map worked).
func _srv_client_pickup(id: int, key: int) -> void:
	if not _gate(id, RL_PICKUP) or not pickups.has(key):
		return
	if (players[id]["pos"] as Vector3).distance_to(pickups[key]["pos"]) > PICKUP_REACH:
		return
	_srv_pickup(key, id)

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
	if bool(settings.get("replenish", true)) and not bool(p.get("drop", false)):
		_pickup_respawn_at[key] = Time.get_ticks_msec() + int(PICKUP_RESPAWN * 1000.0)
	_s_pickup_taken.rpc(key, by)
	_s_pickup_taken(key, by)

@rpc("authority", "call_remote", "reliable")
func _s_pickup_taken(key: int, by: int) -> void:
	if pickups.has(key):
		pickups[key]["taken"] = true
	pickup_taken.emit(key, by)

## Server: a broken prop has left item `si` at `pos` (world space, on
## the ground). It becomes one more of the server's pickups, under a key
## of its own, on every peer at once — the host's own call below is the
## same path a client's RPC takes. Returns the key, or -1 off the server
## or for a sprite that is no item.
func server_drop_pickup(si: int, pos: Vector3) -> int:
	if not is_server() or not PickupData.ITEMS.has(si) or not _sane_pos(pos):
		return -1
	var key: int = _next_pickup_key
	_next_pickup_key += 1
	_s_pickup_add.rpc(key, si, pos)
	_s_pickup_add(key, si, pos)
	return key

@rpc("authority", "call_remote", "reliable")
func _s_pickup_add(key: int, si: int, pos: Vector3) -> void:
	pickups[key] = {"si": si, "pos": pos, "taken": false, "drop": true}
	pickup_spawned.emit(key)

## A new round is the arena as NETLEVEL.PRS placed it: what the last one's
## crates left behind goes with it.
func _forget_drops() -> void:
	_due.clear()
	for k in pickups:
		if bool(pickups[k].get("drop", false)):
			_due.append(k)
	for k in _due:
		pickups.erase(k)
		_pickup_respawn_at.erase(k)

@rpc("authority", "call_remote", "reliable")
func _s_pickup_spawn(key: int) -> void:
	if pickups.has(key):
		pickups[key]["taken"] = false
	pickup_spawned.emit(key)

# ---------------------------------------------------------------------
# The map's own state (M5)
# ---------------------------------------------------------------------

## Client: "I used / I shot entity `off`". An INTENT and nothing more —
## the answer is the server's, and comes back as a delta. On the host
## this is never called: its own branch flips what it touches directly,
## which is the same code path the server runs for everyone else.
func send_trigger(off: int, kind: int, at: Vector3, eye: Vector3, amount: float = 0.0) -> void:
	if active and not is_server():
		_c_trigger.rpc_id(1, off, kind, at, eye, amount)

@rpc("any_peer", "call_remote", "reliable")
func _c_trigger(off: int, kind: int, at: Vector3, eye: Vector3, amount: float) -> void:
	if is_server():
		_srv_client_trigger(multiplayer.get_remote_sender_id(), off, kind, at, eye, amount)

## Server: run a client's intent through the real entry point of its own
## level, or drop it.
##
## What is checked here is what a client could LIE about; what the entity
## itself allows — the DOS radius, the state bits, a record already shot
## to pieces — is the branch's, and it applies to everybody. So: an
## admitted sender, within its budget, alive, reporting a place near where
## the server last saw it (the pickup rule, PICKUP_REACH's reasoning at
## vehicle range), and an entity that the server can find and that stands
## within reach of that place — a hitscan's range for a shot, arm's reach
## for a use. Damage is clamped like a reported hit on a player.
func _srv_client_trigger(id: int, off: int, kind: int, at: Vector3, eye: Vector3,
		amount: float) -> void:
	if trigger_world == null or not is_instance_valid(trigger_world):
		return
	if kind != TRIG_USE and kind != TRIG_HIT:
		return
	if not _gate(id, RL_TRIGGER) or not is_alive(id):
		return
	if not _sane_pos(at) or not _sane_pos(eye) or not is_finite(amount) or amount < 0.0:
		return
	var known: Vector3 = players[id]["pos"]
	if at.distance_to(known) > TRIGGER_REACH or eye.distance_to(known) > TRIGGER_REACH:
		return
	var where: Vector3 = trigger_world.trigger_pos(off)
	if not where.is_finite():
		return                                 # no such record on this map
	if where.distance_to(known) > (MAX_HIT_RANGE if kind == TRIG_HIT else TRIGGER_REACH):
		return
	trigger_world.trigger_intent(off, kind, at, eye, minf(amount, MAX_HIT_DAMAGE))

## Server: what its level has just changed, out to everybody. Called
## every physics frame by the DM controller with whatever the runtime's
## journal collected, which in a quiet arena is nothing at all.
func srv_send_trigger(delta: Dictionary) -> void:
	if not is_server() or delta.is_empty() or multiplayer.get_peers().is_empty():
		return
	_s_trigger.rpc(delta)

@rpc("authority", "call_remote", "reliable")
func _s_trigger(delta: Dictionary) -> void:
	trigger_delta.emit(delta)

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
		_srv_remove_player(bots.pop_back())
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
	text = _clean_text(text, MAX_CHAT_LEN)
	if text.is_empty() or not active:
		return
	if is_server():
		_srv_chat(local_id, text)
	else:
		_c_chat.rpc_id(1, text)

@rpc("any_peer", "call_remote", "reliable")
func _c_chat(text: String) -> void:
	if is_server():
		_srv_client_chat(multiplayer.get_remote_sender_id(), text)

## Server: a client's line — within its budget (every line lands in every
## peer's chat log), cleaned and capped before anything else touches it.
func _srv_client_chat(id: int, text: String) -> void:
	if not _gate(id, RL_CHAT):
		return
	text = _clean_text(text, MAX_CHAT_LEN)
	if not text.is_empty():
		_srv_chat(id, text)

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
	_forget_drops()
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
	_forget_drops()
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
	if not _hello_deadline.is_empty() or not _kick_at.is_empty():
		_srv_drop_stale_peers(now)
	# The timer sweeps collect what is due into one scratch list instead
	# of copying every key list every frame.
	if not _respawn_at.is_empty():
		_due.clear()
		for id in _respawn_at:
			if now >= int(_respawn_at[id]):
				_due.append(id)
		for id in _due:
			_srv_respawn(id)
	if not _pickup_respawn_at.is_empty():
		_due.clear()
		for k in _pickup_respawn_at:
			if now >= int(_pickup_respawn_at[k]):
				_due.append(k)
		for k in _due:
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

## Binds every interface on purpose: a socket bound to one LAN address
## does not hear broadcasts on every OS. `_poll_discovery` filters the
## senders instead.
func _start_discovery() -> void:
	_discovery_seen.clear()
	_discovery = PacketPeerUDP.new()
	if _discovery.bind(DISCOVERY_PORT) != OK:
		push_warning("[net] discovery port %d busy — the server will not show in the LAN browser" % DISCOVERY_PORT)
		_discovery = null

func _stop_discovery() -> void:
	_discovery_seen.clear()
	if _discovery != null:
		_discovery.close()
		_discovery = null

func _poll_discovery() -> void:
	if _discovery == null:
		return
	# A bounded number per frame, so a flood of probes cannot stall the host.
	for _i in DISCOVERY_MAX_PER_POLL:
		if _discovery.get_available_packet_count() <= 0:
			break
		var pkt: PackedByteArray = _discovery.get_packet()
		var ip: String = _discovery.get_packet_ip()
		var port: int = _discovery.get_packet_port()
		if pkt.size() != DISCOVERY_MAGIC.length() or pkt.get_string_from_utf8() != DISCOVERY_MAGIC:
			continue
		# The reply is bigger than the probe: answered for anywhere, a
		# spoofed probe would make the host a (small) reflector.
		if not _is_lan_ip(ip):
			continue
		var now: int = Time.get_ticks_msec()
		if _discovery_seen.has(ip) and now - int(_discovery_seen[ip]) < DISCOVERY_REPLY_MS:
			continue
		if _discovery_seen.size() >= DISCOVERY_SEEN_MAX:
			_discovery_seen.clear()
		_discovery_seen[ip] = now
		var humans: int = 0
		var bots: int = 0
		for p in players.values():
			if bool(p["bot"]):
				bots += 1
			else:
				humans += 1
		var reply := {"name": String(settings.get("name", "SKYNET")).substr(0, MAX_SERVER_NAME_LEN),
			"map": String(settings.get("map", "")).substr(0, MAX_NAME_LEN),
			"players": humans, "bots": bots, "max": int(settings.get("max_players", 0)),
			"port": int(settings.get("port", DEFAULT_PORT))}
		_discovery.set_dest_address(ip, port)
		_discovery.put_packet(JSON.stringify(reply).to_utf8_buffer())

## Private, loopback and link-local IPv4 only (10/8, 172.16/12,
## 192.168/16, 127/8, 169.254/16): the browser is a LAN feature.
func _is_lan_ip(ip: String) -> bool:
	if ip.begins_with("::ffff:"):
		ip = ip.substr(7)                      # IPv4-mapped IPv6
	var parts: PackedStringArray = ip.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		if not part.is_valid_int() or part.to_int() < 0 or part.to_int() > 255:
			return false
	var a: int = parts[0].to_int()
	var b: int = parts[1].to_int()
	return a == 10 or a == 127 or (a == 172 and b >= 16 and b <= 31) \
		or (a == 192 and b == 168) or (a == 169 and b == 254)

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
## takes effect on the next spawn (the server keeps it until then).
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
	class_requested.emit(local_class)

@rpc("any_peer", "call_remote", "reliable")
func _c_set_class(cls: int) -> void:
	if is_server() and _gate(multiplayer.get_remote_sender_id(), RL_CLASS):
		_srv_set_class(multiplayer.get_remote_sender_id(), cls)

## Server: remember `id`'s class for its next spawn (_srv_respawn puts it
## on). It used to switch bodies and health on every peer at once, in the
## middle of a fight.
func _srv_set_class(id: int, cls: int) -> void:
	if not players.has(id):
		return
	cls = clampi(cls, 0, 1)
	if cls == class_of(id):
		_pending_class.erase(id)
	else:
		_pending_class[id] = cls

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
		_srv_client_vehicle_enter(multiplayer.get_remote_sender_id(), key)

@rpc("any_peer", "call_remote", "reliable")
func _c_vehicle_exit(pos: Vector3, yaw: float) -> void:
	if is_server():
		_srv_client_vehicle_exit(multiplayer.get_remote_sender_id(), pos, yaw)

## Server: a client wants a seat — only within reach of the vehicle by the
## server's last pose of it.
func _srv_client_vehicle_enter(id: int, key: int) -> void:
	if not _gate(id, RL_VEHICLE) or not vehicles.has(key):
		return
	if (players[id]["pos"] as Vector3).distance_to(vehicles[key]["pos"]) > VEHICLE_REACH:
		return
	_srv_vehicle_enter(id, key)

## Server: a client climbs out. Where it says is where the vehicle stays
## parked for everybody, so a wild or far-off place is replaced by the
## server's last pose of the driver.
func _srv_client_vehicle_exit(id: int, pos: Vector3, yaw: float) -> void:
	if not _gate(id, RL_VEHICLE):
		return
	var known: Vector3 = players[id]["pos"]
	if not _sane_pos(pos) or pos.distance_to(known) > VEHICLE_REACH:
		pos = known
	if not is_finite(yaw):
		yaw = 0.0
	_srv_vehicle_exit(id, pos, yaw)

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
	if _vehicle_respawn_at.is_empty():
		return
	_due.clear()
	for k in _vehicle_respawn_at:
		if now >= int(_vehicle_respawn_at[k]):
			_due.append(k)
	for k in _due:
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
