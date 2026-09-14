## Dev tool: fly the camera along a scripted path, so a promo clip can be
## RENDERED instead of screen-grabbed.
##
## Godot does the recording itself — `--write-movie out.avi` forces
## `--fixed-fps`, so every frame advances by exactly 1/fps whatever the
## machine manages and not one frame is dropped, audio included. That
## same property is why this tool has to exist: with real-time sync off
## the clock is no longer wall-clock, so nobody can play along while it
## records. The camera has to be driven.
##
##   godot --path godot_project --write-movie shot.avi --fixed-fps 60 \
##       --resolution 1280x720 -- --map=MAP.210 --campath=PATH
##
## PATH is either a JSON file of keys:
##
##   {"keys": [
##      {"t": 0.0, "pos": [61000, 900, -48000], "yaw": 90, "pitch": -4},
##      {"t": 5.0, "pos": [61600, 920, -48500], "yaw": 130, "fire": true}
##   ]}
##
## — `t` in seconds, `pos` in world units, angles in degrees; position is
## interpolated with a Catmull-Rom spline so the camera does not jerk at
## the keys, yaw the short way round, pitch straight; `fire` pulls the
## trigger as the camera passes that key —
##
## or `auto:secs=6,speed=180,turn=10,rise=0,fire=2.5` for a plain dolly
## forward from wherever the player spawned, which needs no coordinates
## and is the quickest way to see whether a shot is worth authoring.

extends RefCounted

var keys: Array = []                  # [{t, pos: Vector3, yaw, pitch, fire}]
## auto mode: filled instead of `keys`, resolved against the spawn pose.
var auto: Dictionary = {}

func load_spec(spec: String) -> bool:
	if spec.begins_with("auto:") or spec == "auto":
		auto = {"secs": 6.0, "speed": 180.0, "turn": 0.0, "rise": 0.0, "fire": -1.0}
		for pair in spec.trim_prefix("auto:").split(","):
			var kv: PackedStringArray = pair.split("=")
			if kv.size() == 2 and auto.has(kv[0]):
				auto[kv[0]] = float(kv[1])
		return true
	if not FileAccess.file_exists(spec):
		push_error("[campath] no such path file: %s" % spec)
		return false
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(spec))
	if not (data is Dictionary) or not (data as Dictionary).has("keys"):
		push_error("[campath] %s carries no \"keys\" array" % spec)
		return false
	for k in (data as Dictionary)["keys"]:
		var d: Dictionary = k
		var p: Array = d.get("pos", [0.0, 0.0, 0.0])
		if p.size() < 3:
			continue
		keys.append({
			"t": float(d.get("t", 0.0)),
			"pos": Vector3(float(p[0]), float(p[1]), float(p[2])),
			"yaw": deg_to_rad(float(d.get("yaw", 0.0))),
			"pitch": deg_to_rad(float(d.get("pitch", 0.0))),
			"fire": bool(d.get("fire", false)),
		})
	keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["t"]) < float(b["t"]))
	if keys.size() < 2:
		push_error("[campath] %s needs at least two keys" % spec)
		return false
	return true

## Turn an `auto:` spec into two keys once the spawn pose is known.
func resolve_auto(pos: Vector3, yaw: float, pitch: float) -> void:
	if auto.is_empty():
		return
	var secs: float = maxf(float(auto["secs"]), 0.5)
	var yaw_end: float = yaw + deg_to_rad(float(auto["turn"]))
	# Forward is -Z rotated by the yaw, as everywhere else in the port.
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var end := pos + fwd * (float(auto["speed"]) * secs) \
		+ Vector3(0.0, float(auto["rise"]) * secs, 0.0)
	keys = [
		{"t": 0.0, "pos": pos, "yaw": yaw, "pitch": pitch, "fire": false},
		{"t": secs, "pos": end, "yaw": yaw_end, "pitch": pitch, "fire": false},
	]
	var ft: float = float(auto["fire"])
	if ft > 0.0 and ft < secs:
		var u: float = ft / secs
		keys.insert(1, {"t": ft, "pos": pos.lerp(end, u),
			"yaw": lerp_angle(yaw, yaw_end, u), "pitch": pitch, "fire": true})
	auto.clear()

func duration() -> float:
	return float(keys[-1]["t"]) if not keys.is_empty() else 0.0

## Camera pose at `t`: {pos, yaw, pitch}.
func pose(t: float) -> Dictionary:
	if keys.is_empty():
		return {}
	if keys.size() == 1 or t <= float(keys[0]["t"]):
		return {"pos": keys[0]["pos"], "yaw": keys[0]["yaw"], "pitch": keys[0]["pitch"]}
	var last: int = keys.size() - 1
	if t >= float(keys[last]["t"]):
		return {"pos": keys[last]["pos"], "yaw": keys[last]["yaw"], "pitch": keys[last]["pitch"]}
	var i: int = 0
	while i < last and t > float(keys[i + 1]["t"]):
		i += 1
	var t0: float = float(keys[i]["t"])
	var t1: float = float(keys[i + 1]["t"])
	var u: float = clampf((t - t0) / maxf(t1 - t0, 0.0001), 0.0, 1.0)
	# Ease within the segment so a cut between keys does not read as a jolt.
	var e: float = smoothstep(0.0, 1.0, u)
	var p0: Vector3 = keys[maxi(i - 1, 0)]["pos"]
	var p1: Vector3 = keys[i]["pos"]
	var p2: Vector3 = keys[i + 1]["pos"]
	var p3: Vector3 = keys[mini(i + 2, last)]["pos"]
	return {
		"pos": p1.cubic_interpolate(p2, p0, p3, e),
		"yaw": lerp_angle(float(keys[i]["yaw"]), float(keys[i + 1]["yaw"]), e),
		"pitch": lerpf(float(keys[i]["pitch"]), float(keys[i + 1]["pitch"]), e),
	}

## Indices of the keys whose `fire` falls in (t0, t1].
func events(t0: float, t1: float) -> Array:
	var out: Array = []
	for i in keys.size():
		var kt: float = float(keys[i]["t"])
		if bool(keys[i]["fire"]) and kt > t0 and kt <= t1:
			out.append(i)
	return out
