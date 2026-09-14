## LAN server browser: broadcasts a probe on Net.DISCOVERY_PORT every
## couple of seconds and collects the JSON replies hosts send back
## (net_game.gd `_poll_discovery`). Poll `tick()` from the menu.
extends RefCounted

const PROBE_INTERVAL: float = 2.0
const ENTRY_TTL: float = 6.0
## Anyone on the network can answer a broadcast, so what comes back is
## bounded and checked: this many servers listed, replies this big read,
## this many a tick, names this long.
const MAX_SERVERS: int = 64
const MAX_REPLY_BYTES: int = 512
const MAX_PER_TICK: int = 64
const MAX_NAME_LEN: int = 48

var servers: Dictionary = {}          # "ip:port" → {ip, port, name, map, players, bots, max, seen}
var _udp: PacketPeerUDP = null
var _t: float = PROBE_INTERVAL

func start() -> bool:
	_udp = PacketPeerUDP.new()
	if _udp.bind(0) != OK:
		_udp = null
		return false
	_udp.set_broadcast_enabled(true)
	return true

func stop() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
	servers.clear()

## Returns true when the list changed.
func tick(delta: float) -> bool:
	if _udp == null:
		return false
	var changed := false
	_t += delta
	if _t >= PROBE_INTERVAL:
		_t = 0.0
		var magic := Net.DISCOVERY_MAGIC.to_utf8_buffer()
		# The limited broadcast plus every interface's directed broadcast.
		var targets: Array = ["255.255.255.255"]
		for ip in IP.get_local_addresses():
			if ip.count(".") == 3 and not ip.begins_with("127."):
				var parts := ip.split(".")
				targets.append("%s.%s.%s.255" % [parts[0], parts[1], parts[2]])
		for t in targets:
			_udp.set_dest_address(t, Net.DISCOVERY_PORT)
			_udp.put_packet(magic)
	for _i in MAX_PER_TICK:
		if _udp.get_available_packet_count() <= 0:
			break
		var pkt: PackedByteArray = _udp.get_packet()
		if accept_reply(_udp.get_packet_ip(), pkt):
			changed = true
	var now := Time.get_ticks_msec()
	for k in servers.keys():
		if now - int(servers[k]["seen"]) > int(ENTRY_TTL * 1000.0):
			servers.erase(k)
			changed = true
	return changed

## One reply from `ip`: listed (or refreshed) when every field has the type
## it should. A `players` that was not a number used to stop tick() with a
## script error. Returns true when the list changed.
func accept_reply(ip: String, pkt: PackedByteArray) -> bool:
	if pkt.size() > MAX_REPLY_BYTES:
		return false
	var data = JSON.parse_string(pkt.get_string_from_utf8())
	if not (data is Dictionary):
		return false
	var port: int = clampi(_num(data, "port", Net.DEFAULT_PORT), 1, 65535)
	var key := "%s:%d" % [ip, port]
	if not servers.has(key) and servers.size() >= MAX_SERVERS:
		return false
	var entry := {"ip": ip, "port": port, "name": _text(data, "name", "?"),
		"map": _text(data, "map", "?"), "players": clampi(_num(data, "players", 0), 0, 999),
		"bots": clampi(_num(data, "bots", 0), 0, 999), "max": clampi(_num(data, "max", 0), 0, 999),
		"seen": Time.get_ticks_msec()}
	var changed: bool = not servers.has(key) or servers[key]["players"] != entry["players"] \
			or servers[key]["map"] != entry["map"]
	servers[key] = entry
	return changed

## A JSON number field as an int (JSON numbers arrive as floats), or
## `fallback` when it is missing, not a number or not finite.
func _num(d: Dictionary, key: String, fallback: int) -> int:
	var v = d.get(key, fallback)
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT and is_finite(v):
		return int(clampf(v, -1e9, 1e9))
	return fallback

## A JSON string field, cleaned (Net._clean_text) and capped.
func _text(d: Dictionary, key: String, fallback: String) -> String:
	var v = d.get(key, fallback)
	if typeof(v) != TYPE_STRING:
		return fallback
	var s: String = Net._clean_text(v, MAX_NAME_LEN)
	return s if not s.is_empty() else fallback
