## LAN server browser: broadcasts a probe on Net.DISCOVERY_PORT every
## couple of seconds and collects the JSON replies hosts send back
## (net_game.gd `_poll_discovery`). Poll `tick()` from the menu.
extends RefCounted

const PROBE_INTERVAL: float = 2.0
const ENTRY_TTL: float = 6.0

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
	while _udp.get_available_packet_count() > 0:
		var pkt: PackedByteArray = _udp.get_packet()
		var ip: String = _udp.get_packet_ip()
		var data = JSON.parse_string(pkt.get_string_from_utf8())
		if not (data is Dictionary):
			continue
		var port: int = int(data.get("port", Net.DEFAULT_PORT))
		var key := "%s:%d" % [ip, port]
		var entry := {"ip": ip, "port": port, "name": String(data.get("name", "?")),
			"map": String(data.get("map", "?")), "players": int(data.get("players", 0)),
			"bots": int(data.get("bots", 0)), "max": int(data.get("max", 0)),
			"seen": Time.get_ticks_msec()}
		if not servers.has(key) or servers[key]["players"] != entry["players"] \
				or servers[key]["map"] != entry["map"]:
			changed = true
		servers[key] = entry
	var now := Time.get_ticks_msec()
	for k in servers.keys():
		if now - int(servers[k]["seen"]) > int(ENTRY_TTL * 1000.0):
			servers.erase(k)
			changed = true
	return changed
