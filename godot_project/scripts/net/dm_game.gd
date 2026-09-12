## In-game deathmatch controller — a child of Main while `Net.active`.
## Owns everything multiplayer-specific so main.gd stays the campaign
## loop: avatars for the other players and bots, the arena's pickups
## (placed by the server from NETLEVEL.PRS), pose replication of the
## local player, the visual side of everybody else's shots, the DM HUD
## (frags / clock / kill feed / scoreboard / chat) and the end-of-round
## screen. Bots get a BotBrain on the server.
##
## Keys: TAB (hold) scoreboard · T or ENTER chat.
extends Node

const DmAvatar := preload("res://scripts/net/dm_avatar.gd")
const BotBrain := preload("res://scripts/net/bot_brain.gd")
const LevelLoader := preload("res://scripts/level_loader.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")
const Pickup := preload("res://scripts/pickup.gd")
const PickupData := preload("res://scripts/pickup_data.gd")
const Tracer := preload("res://scripts/tracer.gd")
const MuzzleFlash := preload("res://scripts/muzzle_flash.gd")
const Projectile := preload("res://scripts/projectile.gd")
const Grenade := preload("res://scripts/grenade.gd")
const SmokePuff := preload("res://scripts/smoke_puff.gd")
const Explosion := preload("res://scripts/explosion.gd")
const TerminatorVision := preload("res://scripts/net/terminator_vision.gd")
const MotionDetector := preload("res://scripts/net/motion_detector.gd")

const SPRITE_PIXEL_SIZE: float = 2.0
const FEED_LINES: int = 5
const FEED_TTL: float = 6.0

var main: Node = null
var player: CharacterBody3D = null
var level = null                        # LevelLoader.Level

var _actors: Node3D = null              # avatars live here
var _pickups_root: Node3D = null
var _avatars: Dictionary = {}           # id → DmAvatar
var _pickup_nodes: Dictionary = {}      # key → Pickup
var _brains: Dictionary = {}            # bot id → BotBrain
var _spawned: bool = false
var _dead_local: bool = false
var _last_hp: float = 100.0

# HUD
var _hud: CanvasLayer = null
var _score_line: Label = null
var _clock: Label = null
var _feed: VBoxContainer = null
var _feed_items: Array = []             # [[Label, expire_msec]]
var _center: Label = null
var _center_t: float = 0.0
var _board: PanelContainer = null
var _board_text: RichTextLabel = null
var _chat_log: VBoxContainer = null
var _chat_items: Array = []
var _chat_edit: LineEdit = null
var _chat_open: bool = false
var _over: CanvasLayer = null
var _hit_flash: ColorRect = null
var _vision: Control = null
var _detector: Control = null

func setup(m: Node, p: CharacterBody3D) -> void:
	main = m
	player = p
	name = "DM"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_actors = Node3D.new()
	_actors.name = "Actors"
	_actors.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_actors)
	_pickups_root = Node3D.new()
	_pickups_root.name = "DMPickups"
	add_child(_pickups_root)
	_build_hud()
	Net.player_joined.connect(_on_player_joined)
	Net.player_left.connect(_on_player_left)
	Net.roster_changed.connect(_refresh_scores)
	Net.pose_received.connect(_on_pose)
	Net.fired.connect(_on_fired)
	Net.local_health_changed.connect(_on_local_health)
	Net.died.connect(_on_died)
	Net.respawned.connect(_on_respawned)
	Net.pickup_taken.connect(_on_pickup_taken)
	Net.pickup_spawned.connect(_on_pickup_spawned)
	Net.chat_received.connect(_on_chat)
	Net.match_over.connect(_on_match_over)
	Net.match_restarted.connect(_on_restarted)
	Net.time_changed.connect(func(_s: int) -> void: _refresh_scores())
	Net.disconnected.connect(_on_disconnected)
	Net.class_changed.connect(_on_class_changed)
	Net.vehicle_changed.connect(_on_vehicle_changed)
	if player != null and not player.use_pressed.is_connected(_on_use_pressed):
		player.use_pressed.connect(_on_use_pressed)
	if player != null:
		player.set("input_locked", true)        # until the server spawns us

func _exit_tree() -> void:
	for sig in [["player_joined", _on_player_joined], ["player_left", _on_player_left],
			["roster_changed", _refresh_scores], ["pose_received", _on_pose], ["fired", _on_fired],
			["local_health_changed", _on_local_health], ["died", _on_died], ["respawned", _on_respawned],
			["pickup_taken", _on_pickup_taken], ["pickup_spawned", _on_pickup_spawned],
			["chat_received", _on_chat], ["match_over", _on_match_over],
			["match_restarted", _on_restarted], ["disconnected", _on_disconnected],
			["class_changed", _on_class_changed], ["vehicle_changed", _on_vehicle_changed]]:
		if Net.is_connected(sig[0], sig[1]):
			Net.disconnect(sig[0], sig[1])

## The player's weapon table (fly_camera.gd) — shared with bots/avatars.
func weapon_record(idx: int) -> Dictionary:
	if player == null:
		return {}
	var w: Array = player.get("_weapons")
	if idx < 0 or idx >= w.size():
		return {}
	return w[idx]

func weapon_name(idx: int) -> String:
	return String(weapon_record(idx).get("name", "?"))

# ---------------------------------------------------------------------
# Level hand-over from main.gd
# ---------------------------------------------------------------------

## The arena is loaded: read its spawn pairs and item spots, place the
## pickups (server) / mirror them (client), raise the avatars, then ask
## the server for a spawn.
func on_level_ready(lvl) -> void:
	level = lvl
	# DOS MP spawn sets: markers 10..29 as (position, facing) pairs, plus
	# the single-player 0/1 pair.
	var spawns: Array = []
	for set_id in [0, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28]:
		if not lvl.markers.has(set_id):
			continue
		for pos in lvl.markers[set_id]:
			var face: Vector3 = main._nearest_marker(lvl.markers.get(set_id + 1, []), pos)
			var yaw: float = 0.0
			var to: Vector3 = face - pos
			if Vector2(to.x, to.z).length() > 0.1:
				yaw = atan2(-to.x, -to.z)
			spawns.append({"pos": main._find_clear_spawn(pos), "yaw": yaw})
	print("[dm] %d spawn sets" % spawns.size())
	if Net.is_server():
		Net.spawn_points = spawns
		var ammo_spots: Array = []
		var weapon_spots: Array = []
		for pos in lvl.markers.get(100, []):
			ammo_spots.append(_ground(pos))
		for set_id in [101, 102]:
			for pos in lvl.markers.get(set_id, []):
				weapon_spots.append(_ground(pos))
		Net.server_place_pickups(ammo_spots, weapon_spots)
		Net.server_place_vehicles(weapon_spots if not weapon_spots.is_empty() else ammo_spots)
	for id in Net.players:
		_ensure_avatar(id)
	for key in Net.pickups:
		if not bool(Net.pickups[key]["taken"]):
			_spawn_pickup_node(key)
	_spawn_vehicle_nodes()
	_refresh_scores()
	Net.report_level_ready()

## Floor height under a marker (terrain outdoors; the marker Y indoors).
func _ground(pos: Vector3) -> Vector3:
	if level != null and level.is_outdoor and level.wld != null:
		return Vector3(pos.x, WldTerrain.height_at_world(level.wld, pos.x, -pos.z), pos.z)
	return pos

# ---------------------------------------------------------------------
# Avatars
# ---------------------------------------------------------------------

func _ensure_avatar(id: int) -> Node:
	if id == Net.local_id:
		return null
	if _avatars.has(id) and is_instance_valid(_avatars[id]):
		return _avatars[id]
	var info: Dictionary = Net.players.get(id, {})
	var av: CharacterBody3D = DmAvatar.new()
	var is_bot: bool = Net.is_bot(id)
	av.process_mode = Node.PROCESS_MODE_ALWAYS
	av.setup(id, String(info.get("name", "?")), is_bot and Net.is_server())
	av.visible = false                     # until the server places it
	av.alive = false
	av.set_class(Net.class_of(id))
	_actors.add_child(av)
	_avatars[id] = av
	if is_bot and Net.is_server():
		var brain: Node = BotBrain.new()
		brain.name = "Brain"
		av.add_child(brain)
		brain.setup(av, self, int(Net.settings.get("bot_skill", 1)))
		_brains[id] = brain
	# Late joiners: the roster already says where the others are.
	if bool(info.get("alive", false)) and not is_bot:
		av.spawn_at(info.get("pos", Vector3.ZERO), 0.0)
	return av

func _on_player_joined(id: int) -> void:
	_ensure_avatar(id)
	_feed_line("%s ENTERED THE GAME" % Net.name_of(id), Color(0.7, 0.9, 1.0))
	_refresh_scores()

func _on_player_left(id: int) -> void:
	_feed_line("%s LEFT THE GAME" % Net.name_of(id), Color(0.7, 0.9, 1.0))
	if _avatars.has(id):
		if is_instance_valid(_avatars[id]):
			_avatars[id].queue_free()
		_avatars.erase(id)
	_brains.erase(id)
	_refresh_scores()

func _on_pose(id: int, pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	var av = _ensure_avatar(id)
	if av == null:
		return
	if not av.visible and Net.is_alive(id):
		av.spawn_at(pos, yaw)
	av.apply_pose(pos, yaw, pitch, flags)
	av.set_vehicle((flags >> Net.F_VEH_SHIFT) & 3)

func _on_respawned(id: int, pos: Vector3, yaw: float) -> void:
	if id == Net.local_id:
		_spawned = true
		_dead_local = false
		if player.has_method("end_death_view"):
			player.call("end_death_view")
		player.set_vehicle(0)
		player.set_spawn(pos, yaw, true)
		_apply_local_class()
		player.set("input_locked", _chat_open)
		if level != null and level.action != null:
			level.action.arm_proximity(pos)
		_center_msg("", 0.0)
		return
	var av = _ensure_avatar(id)
	if av != null:
		av.spawn_at(pos, yaw)
		if _brains.has(id):
			_brains[id].on_respawn()

# ---------------------------------------------------------------------
# Local player replication
# ---------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if player == null or not Net.active or not _spawned:
		return
	var f: int = 0
	if Vector2(player.velocity.x, player.velocity.z).length() > 1.0:
		f |= Net.F_MOVING
	if bool(player.get("_vm_firing")):
		f |= Net.F_FIRING
	if _dead_local:
		f |= Net.F_DEAD
	f |= clampi(player.vehicle, 0, 2) << Net.F_VEH_SHIFT
	Net.send_pose(player.global_position, float(player.get("_yaw")), float(player.get("_pitch")), f, delta)

func _process(delta: float) -> void:
	# Kill feed ageing, centre message, hit flash.
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for it in _feed_items:
		if now > int(it[1]):
			(it[0] as Label).queue_free()
		else:
			keep.append(it)
	_feed_items = keep
	if _center_t > 0.0:
		_center_t -= delta
		if _center_t <= 0.0:
			_center.visible = false
	if _hit_flash != null and _hit_flash.color.a > 0.0:
		_hit_flash.color.a = maxf(_hit_flash.color.a - delta * 2.0, 0.0)
	if _board != null:
		_board.visible = Input.is_key_pressed(KEY_TAB) or (_over != null)

# ---------------------------------------------------------------------
# Other peers' shots — visuals only, damage is the shooter's business
# ---------------------------------------------------------------------

func _on_fired(id: int, weapon: int, from: Vector3, dir: Vector3) -> void:
	var w: Dictionary = weapon_record(weapon)
	if w.is_empty():
		return
	var av = _avatars.get(id)
	if av != null and is_instance_valid(av):
		av.apply_pose(av._target_pos if av._has_target else av.global_position, av.yaw, av.pitch, Net.F_FIRING)
	var kind: String = String(w.get("kind", "bullet"))
	var snd: String = String(w.get("snd", ""))
	if not snd.is_empty():
		Audio.play_sfx_3d(snd, from, -6.0)
	var scene := get_tree().current_scene
	if scene == null or kind == "melee":
		return
	var tint: Color = player._KIND_COLOR.get(kind, Color.WHITE)
	var mf := MuzzleFlash.new()
	scene.add_child(mf)
	mf.setup(from, tint, 48.0 if kind == "shotgun" else 36.0)
	match kind:
		"grenade":
			var g := Grenade.new()
			scene.add_child(g)
			g.setup(from, dir, 0.0, 0.0, av)
			g.visual_only = true
		"rocket", "laser", "plasma":
			var cfg: Dictionary = player._projectile_cfg(kind, w)
			cfg["hits"] = "none"
			var proj: Node3D = Projectile.new()
			scene.add_child(proj)
			proj.setup(from, dir, 0.0, cfg, av)
		_:
			var space := get_viewport().world_3d.direct_space_state
			var to: Vector3 = from + dir * 60000.0
			var q := PhysicsRayQueryParameters3D.create(from, to)
			q.collide_with_areas = true
			if av != null and is_instance_valid(av):
				q.exclude = [av.get_rid()]
			var hit := space.intersect_ray(q)
			var endpoint: Vector3 = hit["position"] if hit.has("position") else to
			var tr: MeshInstance3D = Tracer.new()
			scene.add_child(tr)
			tr.setup(from, endpoint, tint)
			if kind == "shotgun":
				var sm := SmokePuff.new()
				scene.add_child(sm)
				sm.setup(from + dir * 30.0, 180.0)
			if hit.has("collider"):
				var n: Node = hit["collider"] as Node
				if n != null and not n.is_in_group("dm_actor") and not n.is_in_group("player"):
					var puff := Explosion.new()
					scene.add_child(puff)
					puff.setup(endpoint, 40.0, player.IMPACT_BANK_BULLET)

# ---------------------------------------------------------------------
# Health, death, score
# ---------------------------------------------------------------------

func _on_local_health(hp: float, armor: float, _attacker: int) -> void:
	if player == null:
		return
	if hp < _last_hp:
		Audio.play_sfx("HIT2.RAW", -3.0)
		if _hit_flash != null:
			_hit_flash.color.a = 0.35
	_last_hp = hp
	player.health = hp
	player.armor = armor

func _on_died(victim: int, killer: int, weapon: int) -> void:
	var vn: String = Net.name_of(victim)
	if killer == victim or killer <= 0 or not Net.players.has(killer):
		_feed_line("%s DIED" % vn, Color(1.0, 0.75, 0.4))
	else:
		_feed_line("%s KILLED %s  [%s]" % [Net.name_of(killer), vn, weapon_name(weapon)],
			Color(1.0, 0.45, 0.35) if victim == Net.local_id else
			(Color(0.55, 1.0, 0.6) if killer == Net.local_id else Color(0.9, 0.9, 0.9)))
	if victim == Net.local_id:
		_dead_local = true
		player.health = 0.0
		player.velocity = Vector3.ZERO
		player.set("input_locked", true)
		if player.has_method("begin_death_view"):
			player.call("begin_death_view")
		Audio.play_sfx("EXPLO2.RAW", -2.0)
		var who: String = "YOU DIED" if killer == victim or killer <= 0 else "KILLED BY %s" % Net.name_of(killer)
		_center_msg(who, Net.RESPAWN_DELAY + 1.0)
	else:
		var av = _avatars.get(victim)
		if av != null and is_instance_valid(av):
			av.die()
	_refresh_scores()

func _on_match_over(reason: String) -> void:
	_show_over(reason)

func _on_restarted() -> void:
	if _over != null:
		_over.queue_free()
		_over = null
	for key in Net.pickups:
		if not _pickup_nodes.has(key):
			_spawn_pickup_node(key)
	_refresh_scores()
	_center_msg("NEW ROUND", 2.0)

func _on_disconnected(reason: String) -> void:
	Net.pending_message = reason
	main._return_to_menu()

# ---------------------------------------------------------------------
# Pickups
# ---------------------------------------------------------------------

func _spawn_pickup_node(key: int) -> void:
	if _pickup_nodes.has(key) and is_instance_valid(_pickup_nodes[key]):
		return
	var pk: Dictionary = Net.pickups.get(key, {})
	if pk.is_empty():
		return
	var si: int = int(pk["si"])
	var tex: Texture2D = Assets.texture(si >> 7, si & 0x7F, true)
	if tex == null:
		return
	var p: Sprite3D = Pickup.new()
	p.setup_item(si)
	p.set_meta("dm_key", key)
	var px: float = Assets.sprite_pixel_size(si >> 7, si & 0x7F, tex, SPRITE_PIXEL_SIZE)
	LevelLoader._style_sprite(p, tex, px)
	var pos: Vector3 = pk["pos"]
	var world_h: float = float(tex.get_height()) * px
	p.position = Vector3(pos.x, pos.y + world_h * 0.5, pos.z)
	_pickups_root.add_child(p)
	_pickup_nodes[key] = p

func _on_pickup_taken(key: int, by: int) -> void:
	var node = _pickup_nodes.get(key)
	if node != null and is_instance_valid(node):
		if by == Net.local_id:
			node.apply(player)
			if Audio.sound_name(Pickup.PICKUP_SOUND_ID).is_empty():
				Audio.play_sfx("CLICK.RAW", -4.0)
			else:
				Audio.play_id(Pickup.PICKUP_SOUND_ID, -4.0)
		elif node is Node3D:
			Audio.play_id_3d(Pickup.PICKUP_SOUND_ID, (node as Node3D).global_position, -10.0)
		node.queue_free()
	_pickup_nodes.erase(key)

func _on_pickup_spawned(key: int) -> void:
	_spawn_pickup_node(key)

# ---------------------------------------------------------------------
# HUD
# ---------------------------------------------------------------------

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 55
	add_child(_hud)
	var font: FontFile = main.get("_status_font")

	_hit_flash = ColorRect.new()
	_hit_flash.color = Color(0.8, 0.1, 0.05, 0.0)
	_hit_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.add_child(_hit_flash)

	_score_line = _label(font, 20)
	_score_line.position = Vector2(8, 62)
	_hud.add_child(_score_line)
	_clock = _label(font, 20)
	_clock.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_clock.offset_top = 62.0
	_clock.offset_bottom = 90.0
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_child(_clock)

	_feed = VBoxContainer.new()
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_feed.offset_left = -520.0
	_feed.offset_top = 62.0
	_feed.offset_right = -140.0
	_feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_feed)

	_center = _label(font, 34)
	_center.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_center.offset_top = 150.0
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_center.visible = false
	_hud.add_child(_center)

	_chat_log = VBoxContainer.new()
	_chat_log.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_log.offset_left = 8.0
	_chat_log.offset_top = -330.0
	_chat_log.offset_right = 700.0
	_chat_log.offset_bottom = -170.0
	_chat_log.alignment = BoxContainer.ALIGNMENT_END
	_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_chat_log)
	_chat_edit = LineEdit.new()
	_chat_edit.placeholder_text = "say..."
	_chat_edit.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_edit.offset_left = 8.0
	_chat_edit.offset_top = -168.0
	_chat_edit.offset_right = 520.0
	_chat_edit.offset_bottom = -134.0
	_chat_edit.visible = false
	_chat_edit.text_submitted.connect(_on_chat_submit)
	_chat_edit.focus_exited.connect(func() -> void: if _chat_open: _close_chat())
	_hud.add_child(_chat_edit)

	_board = PanelContainer.new()
	_board.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_board.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_board.grow_vertical = Control.GROW_DIRECTION_BOTH
	_board.custom_minimum_size = Vector2(560, 200)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.05, 0.05, 0.85)
	sb.border_color = Color(0.35, 0.6, 0.55)
	sb.set_border_width_all(2)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	_board.add_theme_stylebox_override("panel", sb)
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board.visible = false
	_board_text = RichTextLabel.new()
	_board_text.bbcode_enabled = true
	_board_text.fit_content = true
	_board_text.scroll_active = false
	_board_text.custom_minimum_size = Vector2(520, 0)
	_board_text.add_theme_font_size_override("normal_font_size", 20)
	_board_text.add_theme_font_size_override("bold_font_size", 20)
	_board_text.add_theme_font_size_override("mono_font_size", 20)
	_board.add_child(_board_text)
	_vision = TerminatorVision.new()
	_vision.game = self
	_vision.set_font(font)
	_vision.visible = false
	_hud.add_child(_vision)
	_hud.move_child(_vision, 1)                # over the hit flash, under the read-outs
	# The HUMAN's counterpart: the hand-held motion detector's marks.
	_detector = MotionDetector.new()
	_detector.game = self
	_detector.player = player
	_detector.set_font(font)
	_detector.visible = false
	_hud.add_child(_detector)
	_hud.move_child(_detector, 2)
	_hud.add_child(_board)
	_refresh_scores()

func _label(font: FontFile, size: int) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", Color(0.85, 1.0, 0.9))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _feed_line(text: String, col: Color) -> void:
	if _feed == null:
		return
	var l := _label(main.get("_status_font"), 18)
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_feed.add_child(l)
	_feed_items.append([l, Time.get_ticks_msec() + int(FEED_TTL * 1000.0)])
	while _feed_items.size() > FEED_LINES:
		var old: Array = _feed_items.pop_front()
		(old[0] as Label).queue_free()

func _center_msg(text: String, secs: float) -> void:
	if _center == null:
		return
	_center.text = text
	_center.visible = not text.is_empty()
	_center_t = secs

func _refresh_scores() -> void:
	if _score_line == null:
		return
	var me: Dictionary = Net.players.get(Net.local_id, {})
	var limit: int = int(Net.settings.get("frag_limit", 0))
	var rows: Array = Net.scoreboard()
	var rank: int = 0
	for i in rows.size():
		if int(rows[i][0]) == Net.local_id:
			rank = i + 1
	_score_line.text = "FRAGS %d%s   RANK %d/%d" % [int(me.get("kills", 0)),
		("/%d" % limit) if limit > 0 else "", rank, rows.size()]
	if int(Net.settings.get("time_limit", 0)) > 0:
		var s: int = int(ceil(Net.time_left))
		_clock.text = "%d:%02d" % [s / 60, s % 60]
	else:
		_clock.text = ""
	var txt := "[b]%s[/b]   %s\n" % [String(Net.settings.get("name", "DEATHMATCH")), String(Net.settings.get("map", ""))]
	txt += "[table=4][cell][b]PLAYER[/b][/cell][cell][b]FRAGS[/b][/cell][cell][b]DEATHS[/b][/cell][cell][/cell]"
	for r in rows:
		var mine: bool = int(r[0]) == Net.local_id
		var nm: String = String(r[1])
		if mine:
			nm = "[color=#8effa0]%s[/color]" % nm
		txt += "[cell]%s[/cell][cell]  %d[/cell][cell]  %d[/cell][cell] %s[/cell]" % [nm, int(r[2]), int(r[3]),
			"BOT" if bool(r[4]) else ""]
	txt += "[/table]"
	_board_text.text = txt

# --- chat -----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: int = event.keycode
	if _chat_open:
		if k == KEY_ESCAPE:
			_close_chat()
			get_viewport().set_input_as_handled()
		return
	if _over != null:
		return
	if k == KEY_T or k == KEY_ENTER or k == KEY_KP_ENTER:
		_open_chat()
		get_viewport().set_input_as_handled()

func _open_chat() -> void:
	_chat_open = true
	_chat_edit.visible = true
	_chat_edit.text = ""
	_chat_edit.grab_focus()
	if player != null:
		player.set("input_locked", true)
		player.release_mouse()

func _close_chat() -> void:
	_chat_open = false
	_chat_edit.visible = false
	if player != null:
		player.set("input_locked", _dead_local)
		if not _dead_local:
			player.call("_capture", true)

func _on_chat_submit(text: String) -> void:
	Net.send_chat(text)
	_close_chat()

func _on_chat(from: int, text: String) -> void:
	var l := _label(main.get("_status_font"), 18)
	l.text = "%s: %s" % [Net.name_of(from), text]
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chat_log.add_child(l)
	_chat_items.append(l)
	while _chat_items.size() > 6:
		(_chat_items.pop_front() as Label).queue_free()
	var tm := get_tree().create_timer(10.0)
	tm.timeout.connect(func() -> void:
		if is_instance_valid(l):
			_chat_items.erase(l)
			l.queue_free())

# --- end of round -----------------------------------------------------

func _show_over(reason: String) -> void:
	if _over != null:
		return
	if player != null:
		player.set("input_locked", true)
		player.release_mouse()
	var cl := CanvasLayer.new()
	cl.layer = 80
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(cl)
	_over = cl
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cl.add_child(dim)
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.offset_top = -260.0
	vb.offset_bottom = -40.0
	vb.alignment = BoxContainer.ALIGNMENT_END
	vb.add_theme_constant_override("separation", 12)
	cl.add_child(vb)
	var ttl := Label.new()
	ttl.text = reason
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_size_override("font_size", 40)
	ttl.add_theme_color_override("font_color", Color(0.42, 0.92, 0.48))
	vb.add_child(ttl)
	if Net.is_server():
		vb.add_child(_over_button("NEW ROUND", func() -> void: Net.restart_match()))
	vb.add_child(_over_button("MAIN MENU", func() -> void: main._return_to_menu()))
	_board.visible = true

func _over_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 52)
	b.add_theme_font_size_override("font_size", 24)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

# --- classes ---------------------------------------------------------------

## HUMAN: fast and fragile; TERMINATOR: slow, tough, machine vision.
func _apply_local_class() -> void:
	if player == null:
		return
	var cls: int = Net.class_of(Net.local_id)
	player.max_health = Net.max_hp_of(Net.local_id)
	player.health = player.max_health
	player.class_speed = float(Net.CLASS_SPEED[cls])
	_last_hp = player.health
	if _vision != null:
		_vision.visible = cls == Net.CLASS_TERMINATOR
	# A HUMAN carries the motion detector among the weapons; the
	# TERMINATOR has the same reading built into its view instead.
	if player.has_method("grant_weapon"):
		var det: int = int(player.call("motion_detector_slot"))
		# Through `extra_owned`, so every respawn hands it back.
		player.set("extra_owned", [det] if cls == Net.CLASS_HUMAN else [])
		if cls == Net.CLASS_HUMAN:
			player.call("grant_weapon", det)
		else:
			player.call("drop_weapon", det)
	if _detector != null:
		_detector.player = player

func _on_class_changed(id: int, cls: int) -> void:
	if id == Net.local_id:
		_center_msg("NEXT LIFE: %s" % Net.CLASS_NAMES[cls], 2.0)
		return
	var av = _avatars.get(id)
	if av != null and is_instance_valid(av):
		av.set_class(cls)

# --- vehicles (NETLEVEL jeeps / hks) ----------------------------------------

const DmVehicle := preload("res://scripts/net/dm_vehicle.gd")
var _vehicles_root: Node3D = null
var _vehicle_nodes: Dictionary = {}       # key → DmVehicle

func _spawn_vehicle_nodes() -> void:
	if _vehicles_root == null:
		_vehicles_root = Node3D.new()
		_vehicles_root.name = "DMVehicles"
		add_child(_vehicles_root)
	for key in Net.vehicles:
		if _vehicle_nodes.has(key) and is_instance_valid(_vehicle_nodes[key]):
			continue
		var v: Dictionary = Net.vehicles[key]
		var node: StaticBody3D = DmVehicle.new()
		_vehicles_root.add_child(node)
		node.setup(int(key), int(v["kind"]), v["pos"], float(v["yaw"]))
		node.set_driver(int(v["driver"]))
		_vehicle_nodes[key] = node
		var driver: int = int(v["driver"])
		if driver != 0 and driver != Net.local_id:
			var av = _ensure_avatar(driver)
			if av != null:
				av.set_vehicle(int(v["kind"]))

## Server told everybody who sits where.
func _on_vehicle_changed(key: int, driver: int, pos: Vector3, yaw: float) -> void:
	var node = _vehicle_nodes.get(key)
	if node == null or not is_instance_valid(node):
		_spawn_vehicle_nodes()
		node = _vehicle_nodes.get(key)
		if node == null:
			return
	var prev: int = int(node.driver)
	var kind: int = int(node.kind)
	node.place(pos, yaw)
	node.set_driver(driver)
	if driver == Net.local_id:
		player.set_vehicle(kind)
		player.set_spawn(pos, yaw, false)
		_center_msg("%s" % ("JUMPED INTO A JEEP" if kind == 1 else "FOUND AN HK"), 2.0)
	elif driver != 0:
		var av = _ensure_avatar(driver)
		if av != null:
			av.set_vehicle(kind)
	if driver == 0 and prev != 0:
		if prev == Net.local_id:
			if player.vehicle != 0:
				player.set_vehicle(0)
				player.set_spawn(pos + Vector3(140.0, 0.0, 0.0), yaw, false)
		else:
			var pav = _avatars.get(prev)
			if pav != null and is_instance_valid(pav):
				pav.set_vehicle(0)

## Use key with nothing to operate: climb out of the vehicle.
func _on_use_pressed(_pos: Vector3) -> void:
	if player != null and player.vehicle != 0 and Net.vehicle_of(Net.local_id) != 0:
		Net.leave_vehicle(player.global_position, float(player.get("_yaw")))
