## Main scene controller. Browses MAP.* in MDMDMAP2.BSA, loads a level
## via LevelLoader, and lets the user cycle through maps.
##
## Key bindings (in addition to the global F1..F5 scene switch):
##   PageUp / [ / P     previous map
##   PageDown / ] / N   next map
##   Home / End         first / last map
##   F6 / F7            quicksave / quickload (slot 1 of the LOAD menu)
##   ESC                in-game menu (resume / save / load / cheats / main menu)
##   ~  or Alt+\        console (DOS cheat codes work as commands)

extends Node3D

const LevelLoader := preload("res://scripts/level_loader.gd")
const BSAReader   := preload("res://scripts/loaders/bsa_reader.gd")
const ImgFile     := preload("res://scripts/loaders/img_file.gd")
const Palette     := preload("res://scripts/loaders/palette.gd")
const Briefing    := preload("res://scripts/loaders/briefing.gd")
const FntFont     := preload("res://scripts/loaders/fnt_font.gd")
const SaveGame    := preload("res://scripts/save_game.gd")
const GameConsole := preload("res://scripts/game_console.gd")
const Explosion := preload("res://scripts/explosion.gd")
const FxParticles := preload("res://scripts/fx_particles.gd")
var _ash: GPUParticles3D = null
const PauseMenu   := preload("res://scripts/pause_menu.gd")
const DmGame      := preload("res://scripts/net/dm_game.gd")
const WldTerrain  := preload("res://scripts/loaders/wld_terrain.gd")

## Map to load on startup (falls back to first map if missing).
@export var initial_map: String = "MAP.210"

## Retail campaign mission maps in order — extracted from the scripted
## level table in Skynet.exe (DAT_00034846, 0x5C-byte entries, MAP id at
## +0x04). Sub-maps reached mid-mission (the indoor base sections) are
## NOT in this table — they are linked from in-map transport entities,
## which still need their trigger/destination data decoded (see task #7).
const CAMPAIGN_SEQUENCE: Array = [
	"MAP.210", "MAP.220", "MAP.230", "MAP.240",
	"MAP.252", "MAP.260", "MAP.270", "MAP.280",
]

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D = $Player/Camera3D
@onready var sun: DirectionalLight3D = $Sun

var _maps: Array[String] = []
var _map_idx: int = 0
var _current_level: LevelLoader.Level = null
var _status_label: Label = null
var _health_label: Label = null
var _weapon_label: Label = null
var _ammo_label: Label = null
var _hud_panel: TextureRect = null     # PANEL0.IMG bottom HUD bar
var _health_fill: ColorRect = null     # HEALTH gauge fill
var _rad_fill: ColorRect = null        # RADIATION gauge fill
var _hud_layer: CanvasLayer = null     # the whole gameplay HUD
## AUTOMAP (Tab): the paused 3D map view, and the set of entity nodes the
## player has actually seen — DOS marks flag 0x80 on everything it drew
## and the automap shows only those (fog of war).
var _automap: Node3D = null
var _seen_meshes: Dictionary = {}
var _seen_poll: float = 0.0
var _armor_fill: ColorRect = null      # ARMOR gauge fill
var _hud_font: FontFile = null         # FONT0003.FNT — HUD read-outs
var _status_font: FontFile = null      # FONT0005.FNT — status messages
var _game_over: CanvasLayer = null
var _mission_hostiles: int = 0
var _mission_done: bool = false
## Command-line switches after `--` (see _parse_cli): --map=, --pos=x,y,z,
## --yaw=deg, --pitch=deg, --noclip, --no-briefing, --screenshot=PATH,
## --shot-delay=sec, --quit-after-shot — the agent/automation interface.
var _cli: Dictionary = {}
var _campaign_maps: Array[String] = []   # ordered mission "main" maps
# --- Map transitions (DOS session loop FUN_001216df, skynet_gh.c:24720) --
# `_prev_map_name` mirrors DAT_00038b18 (the map we came from — an exit
# whose target is 0 returns there); `_pending_marker_set` mirrors
# DAT_00038b1c (the marker set the next load spawns at). `_map_state`
# is the per-map "Mst" overlay: what the player changed on each map,
# re-applied when the map is entered again (maps always reload from
# disk, as in DOS).
var _prev_map_name: String = ""
var _pending_marker_set: int = -1
var _map_state: Dictionary = {}
var _fade: ColorRect = null
## Player snapshot from a save file, applied at the end of _begin_level.
var _pending_player: Dictionary = {}
## Esc menu (level stays loaded) and the `~` console.
var _pause: CanvasLayer = null
var _console: CanvasLayer = null
## Deathmatch controller (scripts/net/dm_game.gd) — only while Net.active.
var _dm: Node = null
# --- DOS mission-briefing screen (320x200) -------------------------------
# The original briefing screen (FUN_0012c300) is three stacked .IMG bands:
# the top button bar, the BRIEF<map>.IMG scene picture, and the MENU000
# bottom panel holding the scrolling text with up/down arrows.
#
# The top bar is FOUR tab buttons drawn from individual BUTTON*.IMG files
# (loaded by FUN_0012c648), each with a grey "normal" and a green
# "highlight" state, tiling the full 320-pixel width:
#   BEGIN  BUTTON04/05   x 0..55
#   BRIEFING  BUTTON06/07   x 55..135
#   TACTICAL  BUTTON08/09   x 135..217
#   STATISTICS  BUTTON10/11  x 217..320
# Rects below are in the original 320x200 pixel space.
const BRIEF_W: float = 320.0
const BRIEF_H: float = 200.0
const BR_SCENE_RECT: Rect2 = Rect2(0, 14, 320, 136)    # BRIEF<map>.IMG
const BR_PANEL_RECT: Rect2 = Rect2(0, 150, 320, 50)    # MENU000.IMG
const BR_UP_RECT: Rect2    = Rect2(299, 150, 21, 25)   # MENU000 up arrow
const BR_DOWN_RECT: Rect2  = Rect2(299, 175, 21, 25)   # MENU000 down arrow
const BR_TEXT_RECT: Rect2  = Rect2(7, 154, 288, 42)    # text area, left of arrows
# Top-bar tabs: [name, rect, grey BUTTON img, green BUTTON img].
const BR_TABS: Array = [
	["BEGIN",      Rect2(0, 0, 55, 14),   "BUTTON04", "BUTTON05"],
	["BRIEFING",   Rect2(55, 0, 80, 14),  "BUTTON06", "BUTTON07"],
	["TACTICAL",   Rect2(135, 0, 82, 14), "BUTTON08", "BUTTON09"],
	["STATISTICS", Rect2(217, 0, 103, 14),"BUTTON10", "BUTTON11"],
]

var _briefing_overlay: CanvasLayer = null
var _briefing_pages: Array = []            # [{img:Texture, text:String, title:String}]
var _briefing_page: int = 0
var _briefing_scene: TextureRect = null    # BRIEF*.IMG centre picture
## The mission screen's three tabs. BRIEFING pages through the script,
## TACTICAL spins the [TA] enemy dossiers, STATISTICS shows the four
## percentages the DOS screen drew (FUN_001346e5).
var _briefing_mode: String = "BRIEFING"
var _mission_tactical: Array = []          # [TA] dossier names
var _briefing_backdrop: Texture2D = null   # TACTBAK.IMG
var _tactical: Control = null
var _stats_box: Control = null
var _briefing_tabs: Dictionary = {}        # name -> the tab Button
var _briefing_text: Label = null           # objectives / dialogue text
var _briefing_toast_label: Label = null    # transient "tab unavailable" note
var _briefing_scroll: ScrollContainer = null
var _briefing_pending_map: String = ""     # map to load when BEGIN is pressed

func _ready() -> void:
	_cli = _parse_cli()
	print("[skynet] Godot port boot")
	print("[skynet] game root: %s" % SkynetPaths.game_root)
	# Show the dev F-key overlay again (the menu hides it).
	var ss := get_node_or_null("/root/SceneSwitcher")
	if ss != null and ss.has_method("set_hud_visible"):
		ss.set_hud_visible(true)
	# A map picked in the main menu overrides the built-in default.
	if SkynetPaths.selected_map != "":
		initial_map = SkynetPaths.selected_map
	# A network game: the host's arena, no briefing, the DM controller.
	if Net.active:
		initial_map = String(Net.settings.get("map", initial_map))
	_build_status_ui()
	_console = GameConsole.new()
	_console.handler = self
	add_child(_console)
	_pause = PauseMenu.new()
	_pause.game = self
	add_child(_pause)
	if Net.active:
		_dm = DmGame.new()
		add_child(_dm)
		_dm.setup(self, player)
	_scan_maps()
	if _maps.is_empty():
		_set_status("No maps found in MDMDMAP2.BSA")
		return
	# Campaign sequence — the mission "main" maps. In the DOS engine the
	# mission number is (map_number - 200) / 10, so a mission's entry map
	# is the one whose number ends in 0. Completing a mission advances to
	# the next such map.
	for m in CAMPAIGN_SEQUENCE:
		if _maps.has(m):
			_campaign_maps.append(m)
	print("[skynet] campaign: %d missions" % _campaign_maps.size())

	_map_idx = _maps.find(initial_map)
	if _map_idx < 0: _map_idx = 0
	# A slot picked in the LOAD menu replaces the normal start.
	var slot: int = SkynetPaths.pending_load_slot
	SkynetPaths.pending_load_slot = -1
	if slot >= 0 and SaveGame.exists(slot):
		load_from_slot(slot)
	else:
		_load_current()

## DOS meshes are drawn double-sided and their winding is arbitrary —
## the 210TOWER observation deck floor faces DOWN. Godot's concave
## shapes ignore back faces by default, so rays fell through that floor
## (the deck terminator dropped to the ground) and bodies could push
## through walls from behind. Make every trimesh solid both ways.
static func _enable_backfaces(mi: MeshInstance3D) -> void:
	for body in mi.get_children():
		if body is CollisionObject3D:
			for cs in body.get_children():
				if cs is CollisionShape3D and cs.shape is ConcavePolygonShape3D:
					(cs.shape as ConcavePolygonShape3D).backface_collision = true

## Small non-mover props: a single box is close to the DOS cylinder
## and cannot wedge the player between triangles.
static func _is_small_prop(mi: MeshInstance3D, level: LevelLoader.Level) -> bool:
	if mi.mesh == null:
		return false
	if level.action != null and mi.has_method("file_off") 			and level.action.is_mover_off(mi.file_off()):
		return false
	var s: Vector3 = mi.mesh.get_aabb().size
	# Flat pieces (floor tiles, wall panels, ramps) are level geometry,
	# not props — and a zero-thickness box would not collide at all.
	if minf(s.x, minf(s.y, s.z)) < PROP_BOX_MIN_THICKNESS:
		return false
	return maxf(s.x, maxf(s.y, s.z)) <= PROP_BOX_MAX

## A mover mesh that is a door/gate LEAF rather than a room segment
## that happens to move (MAP.214's CORB122I corridor piece rotates as a
## bulkhead; boxing it sealed the tunnel). Leaves are thin slabs, or
## carry no walkable floor plate in their lower third; corridor and
## room pieces always have one.
static func _is_door_like(mi: MeshInstance3D) -> bool:
	if mi.mesh == null:
		return false
	var aabb: AABB = mi.mesh.get_aabb()
	var s: Vector3 = aabb.size
	if minf(s.x, minf(s.y, s.z)) <= DOOR_LEAF_MAX_THICKNESS:
		return true
	var floor_top: float = aabb.position.y + s.y / 3.0
	var floor_area: float = 0.0
	for si in mi.mesh.get_surface_count():
		var arrays: Array = mi.mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx_v = arrays[Mesh.ARRAY_INDEX]          # null for fan-built surfaces
		var idx: PackedInt32Array = idx_v if idx_v != null else PackedInt32Array()
		var nrm_v = arrays[Mesh.ARRAY_NORMAL]         # stored = visible side
		var nrm: PackedVector3Array = nrm_v if nrm_v != null else PackedVector3Array()
		var n: int = idx.size() if idx.size() > 0 else verts.size()
		var t: int = 0
		while t + 2 < n:
			var i0: int = idx[t] if idx.size() > 0 else t
			var i1: int = idx[t + 1] if idx.size() > 0 else t + 1
			var i2: int = idx[t + 2] if idx.size() > 0 else t + 2
			t += 3
			var a: Vector3 = verts[i0]
			var b: Vector3 = verts[i1]
			var cc: Vector3 = verts[i2]
			var cr: Vector3 = (b - a).cross(cc - a)
			var area2: float = cr.length()
			if area2 < 1.0:
				continue
			# mesh_3d.gd emits fans as (0, k+1, k): the raw cross product
			# points at the BACK; the stored normal is the visible side.
			var up: float = nrm[i0].y if nrm.size() > i0 else -cr.y / area2
			if up > 0.8 and maxf(a.y, maxf(b.y, cc.y)) <= floor_top:
				floor_area += area2 * 0.5
	return floor_area < DOOR_LEAF_FLOOR_AREA

static func _make_box_collision(mi: MeshInstance3D) -> void:
	var aabb: AABB = mi.mesh.get_aabb()
	var sb := StaticBody3D.new()
	sb.name = mi.name + "_col"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Flat leaves (DOOR01 is a zero-thickness plane) still need a body.
	box.size = Vector3(maxf(aabb.size.x, BOX_MIN_THICKNESS),
		maxf(aabb.size.y, BOX_MIN_THICKNESS), maxf(aabb.size.z, BOX_MIN_THICKNESS))
	cs.shape = box
	cs.position = aabb.position + aabb.size * 0.5
	sb.add_child(cs)
	mi.add_child(sb)

## Swap a mesh's baked StaticBody3D for an AnimatableBody3D so the
## physics server moves the collider kinematically (pushes bodies).
## sync_to_physics stays OFF: with it on, the body only re-syncs on its
## own LOCAL transform changes and the server writes its state back into
## the node every step — a body under a moving parent then lags half-way
## behind the mesh (measured: 61 u on a 128 u gate slide). Off, the
## normal global-transform notification carries the parent's motion.
static func _make_animatable(mi: MeshInstance3D) -> void:
	for c in mi.get_children():
		if c is StaticBody3D and not (c is AnimatableBody3D):
			var ab := AnimatableBody3D.new()
			ab.name = c.name
			ab.sync_to_physics = false
			for s in c.get_children():
				c.remove_child(s)
				ab.add_child(s)
			mi.remove_child(c)
			c.free()
			mi.add_child(ab)
			return

## --floormap=x0,z0,x1,z1,step,y: ASCII plan of the collision floor at
## level `y` (agent aid for "can't get there" reports). Per cell a ray
## from y+90 down 700 u: '.' floor within 40 u of y, '#' wall/obstacle
## higher than y+40, digits = floor n×100 u below, ' ' = nothing.
func _floormap(spec: String) -> void:
	var v: PackedStringArray = spec.split(",")
	if v.size() < 6:
		print("[floormap] need x0,z0,x1,z1,step,y")
		return
	var x0 := float(v[0]); var z0 := float(v[1]); var x1 := float(v[2]); var z1 := float(v[3])
	var step := maxf(float(v[4]), 8.0); var y := float(v[5])
	var space := get_world_3d().direct_space_state
	print("[floormap] x %d..%d z %d..%d step %d at y %d (rows = z, columns = x)" % [x0, x1, z0, z1, step, y])
	var ceil_mode: bool = v.size() > 6 and v[6].begins_with("ceil")
	var fine: bool = v.size() > 6 and v[6] == "ceilfine"
	if ceil_mode:
		print("[floormap] ceiling: ray from y+30 up 600 — digit = clearance/40 above the FEET (9 = 360+), ' ' = none")
	var z := minf(z0, z1)
	while z <= maxf(z0, z1):
		var row := ""
		var x := minf(x0, x1)
		while x <= maxf(x0, x1):
			var ch := " "
			if ceil_mode:
				var cfrom := Vector3(x, y + 30.0, z)
				var cq := PhysicsRayQueryParameters3D.create(cfrom, cfrom + Vector3(0.0, 600.0, 0.0))
				cq.hit_back_faces = true
				var chit := space.intersect_ray(cq)
				if not chit.is_empty():
					var cl: float = chit["position"].y - y
					# 'a' = 0..9 u, 'b' = 10..19 … 'z' = 250+ (10-u letters
					# read finer than the 40-u digits for doorways).
					ch = str(mini(int(cl / 40.0), 9)) if not fine else char(97 + mini(int(cl / 10.0), 25))
			else:
				var from := Vector3(x, y + 90.0, z)
				var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, -700.0, 0.0))
				q.hit_back_faces = true
				var hit := space.intersect_ray(q)
				if not hit.is_empty():
					var hy: float = hit["position"].y
					if hy > y + 40.0: ch = "#"
					elif hy > y - 40.0: ch = "."
					else:
						var d: int = int((y - hy) / 100.0) + 1
						ch = str(mini(d, 9))
			row += ch
			x += step
		print("%7d %s" % [z, row])
		z += step

## --slice=x,z0,z1,y0,y1,step (or z,x0,x1,y0,y1,step,x): a vertical
## cross-section of the collision geometry through the plane x = const
## (rows = y top-down, columns = z). '#' where a short ray from the
## cell centre hits a surface, '.' for open space. Stairs, floors,
## ceilings and low lintels read directly.
func _slice(spec: String) -> void:
	var v: PackedStringArray = spec.split(",")
	if v.size() < 6:
		print("[slice] need x,z0,z1,y0,y1,step[,x]")
		return
	var along_x: bool = v.size() > 6 and v[6] == "x"
	var fixed := float(v[0])
	var a0 := minf(float(v[1]), float(v[2])); var a1 := maxf(float(v[1]), float(v[2]))
	var y0 := minf(float(v[3]), float(v[4])); var y1 := maxf(float(v[3]), float(v[4]))
	var step := maxf(float(v[5]), 4.0)
	var space := get_world_3d().direct_space_state
	print("[slice] plane %s=%d, %s %d..%d, y %d..%d, step %d" % ["z" if along_x else "x", fixed,
		"x" if along_x else "z", a0, a1, y0, y1, step])
	var dirs: Array = [Vector3.UP, Vector3.DOWN,
		Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1),
		Vector3(-1, 0, 0) if along_x else Vector3(0, 0, -1)]
	var y := y1
	while y >= y0:
		var row := ""
		var a := a0
		while a <= a1:
			var c := Vector3(a, y, fixed) if along_x else Vector3(fixed, y, a)
			var hit := false
			for d in dirs:
				var q := PhysicsRayQueryParameters3D.create(c, c + d * (step * 0.5))
				q.hit_back_faces = true
				if not space.intersect_ray(q).is_empty():
					hit = true
					break
			row += "#" if hit else "."
			a += step
		print("%6d %s" % [y, row])
		y -= step

## --pos (camera position, like the DOS markers) / --yaw / --pitch /
## --noclip: place the player for an automated run.
func _cli_place() -> void:
	if _cli.has("pos"):
		player.set_spawn(_cli_vec3(String(_cli["pos"])) - Vector3(0.0, EYE_HEIGHT, 0.0),
			player.rotation.y, false)
	if (_cli.has("noclip") or _cli.has("pos")) and not _cli.has("walk"):
		player.noclip = true
		player.velocity = Vector3.ZERO
	if _cli.has("walk") and _walk_t < 0.0:
		# --walk=x,z[,secs]: collisions on, walk toward the point and log
		# the body every half second (agent reproduction of "can't pass").
		# Route: "x,z;x,z;...[;secs]" — waypoints in order.
		_walk_route = []
		_walk_limit = 12.0
		for wp in String(_cli["walk"]).split(";"):
			var parts: PackedStringArray = wp.split(",")
			if parts.size() >= 2:
				_walk_route.append(Vector2(float(parts[0]), float(parts[1])))
			elif parts.size() == 1 and parts[0].is_valid_float():
				_walk_limit = float(parts[0])
		if _walk_route.is_empty():
			return
		_walk_target = _walk_route.pop_front()
		_walk_t = 0.0
		_walk_stuck = 0.0
		player.noclip = false
		player.velocity = Vector3.ZERO
		print("[walk] start at %s toward %s for %.1f s" % [player.global_position, _walk_target, _walk_limit])
	if _cli.has("yaw") or _cli.has("pitch"):
		var yaw := deg_to_rad(float(_cli.get("yaw", rad_to_deg(player.rotation.y))))
		var pitch := deg_to_rad(float(_cli.get("pitch", 0.0)))
		player.set_view(yaw, pitch)

## `--key=value` / `--flag` switches from both argument lists.
static func _parse_cli() -> Dictionary:
	var out: Dictionary = {}
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a in args:
		if not a.begins_with("--"):
			continue
		var eq := a.find("=")
		if eq > 0:
			out[a.substr(2, eq - 2)] = a.substr(eq + 1)
		else:
			out[a.substr(2)] = true
	return out

static func _cli_vec3(s: String) -> Vector3:
	var p := s.split(",")
	if p.size() < 3:
		return Vector3.ZERO
	return Vector3(float(p[0]), float(p[1]), float(p[2]))

## Apply the automation switches once a level is up: place the camera,
## then capture a screenshot and optionally quit.
func _cli_after_level() -> void:
	if _cli.is_empty() or not is_instance_valid(player):
		return
	if _cli.has("god"):
		player.set("god_mode", true)
	if _cli.has("console"):
		# Automation: run console commands once the level is up
		# (`--console=win;next`), each reply goes to the log.
		for c in String(_cli["console"]).split(";"):
			if not c.strip_edges().is_empty():
				print("[cli] ] %s → %s" % [c.strip_edges(), await run_command(c.strip_edges())])
	if _cli.has("quit-after"):
		# Automation: leave after N seconds (a headless client in a test).
		get_tree().create_timer(float(_cli["quit-after"])).timeout.connect(func() -> void:
			print("[skynet] --quit-after elapsed")
			Net.leave()
			get_tree().quit())
	if _cli.has("near"):
		# Agent diagnostics: stand 260 u from the first node of a group
		# ("pickup", "fire", "enemy"; "group:N" picks the N-th) facing it.
		var parts: PackedStringArray = String(_cli["near"]).split(":")
		var nodes: Array = get_tree().get_nodes_in_group(parts[0])
		var ni: int = int(parts[1]) if parts.size() > 1 else 0
		if ni < nodes.size() and nodes[ni] is Node3D:
			var tgt: Vector3 = (nodes[ni] as Node3D).global_position
			var eye: Vector3 = tgt + Vector3(-260.0, 120.0, 0.0)
			_cli["pos"] = "%f,%f,%f" % [eye.x, eye.y, eye.z]
			var d: Vector3 = tgt + Vector3(0.0, 30.0, 0.0) - eye
			_cli["yaw"] = str(rad_to_deg(atan2(-d.x, -d.z)))
			_cli["pitch"] = str(rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length())))
			print("[cli] near %s #%d at %s" % [parts[0], ni, tgt])
		else:
			print("[cli] near: no node %s #%d" % [parts[0], ni])
	_cli_place()
	if _cli.has("floormap") or _cli.has("slice"):
		await get_tree().physics_frame
		await get_tree().physics_frame
		for spec in String(_cli.get("floormap", "")).split(";"):
			if not spec.is_empty():
				_floormap(spec)
		for spec in String(_cli.get("slice", "")).split(";"):
			if not spec.is_empty():
				_slice(spec)
	if _cli.has("screenshot"):
		var delay := float(_cli.get("shot-delay", 1.5))
		await get_tree().create_timer(delay).timeout
		# Re-apply the requested view: the first captured mouse event
		# and gravity can drift the camera during the delay.
		_cli_place()
		if _cli.has("tab") and _briefing_overlay != null:
			_briefing_set_tab(String(_cli["tab"]).to_upper())
			await get_tree().process_frame
			await get_tree().process_frame
		if _cli.has("console2"):
			# Console commands run right BEFORE the capture, so short-lived
			# effects (muzzle smoke, cases) are still on screen.
			for c in String(_cli["console2"]).split(";"):
				if not c.strip_edges().is_empty():
					print("[cli] ] %s → %s" % [c.strip_edges(), await run_command(c.strip_edges())])
		if _cli.has("automap"):
			_toggle_automap()
			await get_tree().process_frame
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		var path := String(_cli["screenshot"])
		var err := img.save_png(path)
		print("[skynet] screenshot %s (%s) at pos=%s yaw=%.1f pitch=%.1f" % [path, error_string(err),
			player.global_position, rad_to_deg(player.rotation.y), rad_to_deg(player.get("_pitch"))])
		if _cli.has("quit-after-shot"):
			get_tree().quit()
	elif _cli.has("sprite-probe"):
		# Agent diagnostics: how far above the floor each billboard's
		# bottom edge sits (anchoring checks).
		await get_tree().physics_frame
		await get_tree().physics_frame
		var space := get_world_3d().direct_space_state
		var lvl := _current_level
		if lvl != null and lvl.sprites != null:
			var gaps: Array = []
			for s in lvl.sprites.get_children():
				if not (s is Sprite3D) or (s as Sprite3D).texture == null:
					continue
				var sp := s as Sprite3D
				var half: float = float(sp.texture.get_height()) * sp.pixel_size * 0.5
				var bottom: Vector3 = sp.global_position - Vector3(0.0, half, 0.0)
				var q := PhysicsRayQueryParameters3D.create(bottom + Vector3(0, 8, 0), bottom - Vector3(0, 4000, 0))
				var hit := space.intersect_ray(q)
				var gap: float = -1.0
				if hit.has("position"):
					gap = bottom.y - (hit["position"] as Vector3).y
				gaps.append(gap)
				print("[sprite-probe] %s h=%.0f bottom=%.0f gap=%.0f" % [sp.name, half * 2.0, bottom.y, gap])
			gaps.sort()
			if not gaps.is_empty():
				print("[sprite-probe] %d sprites, median gap %.0f" % [gaps.size(), gaps[gaps.size() / 2]])
	elif _cli.has("floor-probe"):
		# Agent diagnostics: what is under the spawn (fall-through reports).
		await get_tree().physics_frame
		await get_tree().physics_frame
		var space := get_world_3d().direct_space_state
		var p: Vector3 = player.global_position
		for off in [Vector3.ZERO, Vector3(150, 0, 0), Vector3(-150, 0, 0), Vector3(0, 0, 150), Vector3(0, 0, -150)]:
			var a: Vector3 = p + off
			for top in [40.0, 400.0]:
				var q := PhysicsRayQueryParameters3D.create(Vector3(a.x, a.y + top, a.z), Vector3(a.x, a.y - 3000.0, a.z))
				q.collide_with_areas = false
				var hit := space.intersect_ray(q)
				var what: String = "nothing"
				if hit.has("position"):
					var c: Node = hit["collider"] as Node
					what = "%s at y=%.0f n=%s" % [c.get_parent().name if c != null and c.get_parent() != null else "?",
						(hit["position"] as Vector3).y, hit.get("normal", Vector3.ZERO)]
				print("[probe] from %s +%.0f: %s" % [a, top, what])
		var shape := CapsuleShape3D.new()
		shape.radius = 22.0
		shape.height = 80.0
		var sq := PhysicsShapeQueryParameters3D.new()
		sq.shape = shape
		sq.transform = Transform3D(Basis(), p + Vector3(0.0, 40.0, 0.0))
		var overl := space.intersect_shape(sq, 8)
		var names: Array = []
		for o in overl:
			var c: Node = o["collider"] as Node
			names.append(c.get_parent().name if c != null and c.get_parent() != null else "?")
		print("[probe] capsule at spawn overlaps: %s" % [names])
		await get_tree().create_timer(float(_cli.get("shot-delay", 3.0))).timeout
		print("[probe] after settle: pos=%s on_floor=%s" % [player.global_position, player.is_on_floor()])
		if _cli.has("quit-after-shot"):
			get_tree().quit()
	elif _cli.has("dump-enemies"):
		# Agent diagnostics: settle, then print every enemy's placement
		# against the surface under it (sunken / floating actors).
		await get_tree().create_timer(float(_cli.get("shot-delay", 3.0))).timeout
		_dump_enemies()
		if _cli.has("quit-after-shot"):
			get_tree().quit()

func _dump_enemies() -> void:
	var space := get_world_3d().direct_space_state
	for e in get_tree().get_nodes_in_group("enemy"):
		if not (e is Node3D) or not is_instance_valid(e):
			continue
		var p: Vector3 = (e as Node3D).global_position
		var foot: float = p.y + float(e.get("_foot_offset"))
		# Floor right under the feet (from 40 u above them) and the first
		# surface above the head — sunk actors show a negative clearance.
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, foot + 40.0, p.z), Vector3(p.x, foot - 300.0, p.z))
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		var clear: String = "none"
		if hit.has("position"):
			clear = "%.0f" % (foot - (hit["position"] as Vector3).y)
		var q2 := PhysicsRayQueryParameters3D.create(Vector3(p.x, foot + 40.0, p.z), Vector3(p.x, foot + 600.0, p.z))
		q2.collide_with_areas = false
		var hit2 := space.intersect_ray(q2)
		var head: String = "none"
		if hit2.has("position"):
			head = "%.0f" % ((hit2["position"] as Vector3).y - foot)
		var brain = e.get("_brain")
		print("[enemy] %-24s type=%3d st=%2s pos=(%.0f, %.0f, %.0f) feet=%.0f floor_clearance=%s ceiling_above_feet=%s" % [
			e.name, int(e.get("_type_id")), str(brain.state) if brain != null else "-", p.x, p.y, p.z, foot, clear, head])

func _scan_maps() -> void:
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDMAP2.BSA"), SkynetPaths.variant):
		push_error("[skynet] cannot open MDMDMAP2.BSA to enumerate maps")
		return
	for e in bsa.entries():
		if e.name.to_upper().begins_with("MAP."):
			_maps.append(e.name.to_upper())
	bsa.close()
	_maps.sort_custom(func(a, b): return _suffix(a) < _suffix(b))
	print("[skynet] %d maps available: %s..%s"
		% [_maps.size(),
		   _maps[0] if _maps.size() > 0 else "(none)",
		   _maps[_maps.size() - 1] if _maps.size() > 0 else "(none)"])

static func _suffix(name: String) -> int:
	var parts := name.split(".")
	if parts.size() < 2: return -1
	return int(parts[1])

func _load_current() -> void:
	_clear_level()
	if _map_idx < 0 or _map_idx >= _maps.size():
		_set_status("No map at index %d" % _map_idx)
		return
	var name := _maps[_map_idx]
	# Mission "main" maps open with the briefing screen; the level itself
	# loads only when the player presses BEGIN. Other maps load directly.
	# Automation runs (screenshots) skip the briefing.
	if (_cli.has("screenshot") and not _cli.has("tab")) or _cli.has("no-briefing") or Net.active:
		_begin_level(name)
	elif not _maybe_show_briefing(name):
		_begin_level(name)
	elif _cli.has("screenshot"):
		# --tab=TACTICAL --screenshot=…: capture the mission screen itself.
		await get_tree().create_timer(float(_cli.get("shot-delay", 1.5))).timeout
		if _cli.has("tab"):
			_briefing_set_tab(String(_cli["tab"]).to_upper())
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var bimg: Image = get_viewport().get_texture().get_image()
		print("[skynet] screenshot %s (%s) — mission screen"
			% [_cli["screenshot"], error_string(bimg.save_png(String(_cli["screenshot"])))])
		if _cli.has("quit-after-shot"):
			get_tree().quit()

## Load and show the level geometry for `name` — called directly for
## non-mission maps, or from the briefing's BEGIN button once the player
## has read the mission briefing.
func _begin_level(name: String) -> void:
	_set_status("Loading %s ..." % name)
	_ensure_mission_script(name)
	await get_tree().process_frame

	var loader := LevelLoader.new()
	var level := loader.load_level(name)
	if level == null:
		push_error("[skynet] failed to load %s" % name)
		_set_status("[%d/%d] %s -- LOAD FAILED"
			% [_map_idx + 1, _maps.size(), name])
		return
	_current_level = level
	if level.terrain:
		add_child(level.terrain)
		level.terrain.create_trimesh_collision()   # walkable ground
		_enable_backfaces(level.terrain)
	if level.entities:
		# Bake the colliders BEFORE the subtree enters the physics space so
		# their flags (backface_collision) are registered from the first
		# step — the deck terminator's first snap otherwise only found
		# the roof.
		for c in level.entities.get_children():
			# Every entity mesh gets a trimesh StaticBody child — for
			# movers (doors/gates/lifts) it is a child of the moving
			# node, so the collision follows the action-system motion.
			if c is MeshInstance3D:
				# Doors, gates and lifts collide as their AABB box, like
				# every DOS object: the BIGDOOR leaf is a braced frame
				# whose trimesh has holes a player capsule slips through
				# (closed!) and thin edges to wedge on.
				var solid_mover: bool = (level.action != null and c.has_method("file_off")
					and level.action.is_solid_mover(c.file_off()) and _is_door_like(c))
				if solid_mover or _is_small_prop(c, level):
					_make_box_collision(c)          # DOS-style solid box
				else:
					c.create_trimesh_collision()    # walls, buildings, bridges
					_enable_backfaces(c)
				# A moving StaticBody does not push the player — a closing
				# gate would leave them wedged inside the leaf. Movers get
				# an AnimatableBody3D (sync_to_physics) instead.
				if level.action != null and c.has_method("file_off") 						and level.action.is_mover_off(c.file_off()):
					_make_animatable(c)
		add_child(level.entities)
	if level.action != null:
		level.action.teleport_requested.connect(_on_teleport_requested)
		level.action.drop_requested.connect(_on_drop_requested)
		level.action.objective_complete.connect(_on_objective_complete)
		level.action.hint_message.connect(_on_hint_message)
		level.action.mission_failed.connect(_on_mission_failed)
		level.action.space = get_world_3d().direct_space_state
		level.action.player_body = player
		if not player.pickup_message.is_connected(_set_status):
			player.pickup_message.connect(_set_status)
		if not player.use_pressed.is_connected(_on_use_pressed):
			player.use_pressed.connect(_on_use_pressed)
	if Net.active:
		# Deathmatch: no map enemies (the 31/32 markers on the arenas are
		# the DOS jeep/HK vehicle spots) and no map pickups — the server
		# scatters the arena's items (NETLEVEL.PRS) over the item markers.
		if level.enemies:
			level.enemies.queue_free()
			level.enemies = null
		if level.sprites:
			for c in level.sprites.get_children():
				if c.has_meta("pickup_off"):
					level.sprites.remove_child(c)
					c.queue_free()
	if level.enemies:  add_child(level.enemies)
	if level.sprites:  add_child(level.sprites)
	if level.sky:
		add_child(level.sky)
		level.sky.position = player.global_position
	_set_sky_fill(level, name)
	_light_level(level)
	# Re-apply this map's state overlay when we have been here before.
	_apply_map_state(level, name)

	# Let the freshly-added trimesh collision register in the physics
	# space before the spawn-clearance query runs.
	await get_tree().physics_frame
	_frame_camera(level)
	# Gates/doorways the spawn already sits in must be left before they
	# can fire again — return exits drop the player right beside the
	# gate they came through.
	if level.action != null and is_instance_valid(player):
		level.action.arm_proximity(player.global_position)
	_cli_after_level()

	# Ambient bed — wind for outdoor maps.
	if level.is_outdoor:
		Audio.play_ambient("AMB_WIND.RAW")
	else:
		Audio.stop_ambient()
	# Score: the maptype marker (type 6, sub+2) picks the HMI track.
	Audio.play_music_for_maptype(_maptype(level))
	_set_status("")
	print("[skynet] %s ready (%d/%d, %s, %d meshes, %d enemies)"
		% [name, _map_idx + 1, _maps.size(),
		   "outdoor" if level.is_outdoor else "indoor",
		   level.entity_count, level.enemy_count])

	# Hostile count for the HUD/tests — only the mission's main map
	# tracks it; the interiors reached through exits are side areas of
	# the same mission. Missions end at the evacuation zone, never here.
	_mission_done = false
	_mission_hostiles = 0
	if _is_campaign_main(name):
		_mission_hostiles = get_tree().get_nodes_in_group("enemy").size()
	if _dm == null and not Net.active:
		Stats.add_enemies(get_tree().get_nodes_in_group("enemy").size())
	# Vehicle missions (Skynet.exe mission table 0x34846, +8 = player
	# mode): mission 2 and 6 are driven in the jeep, mission 7 flown in
	# the HK, for the whole mission including its sub-maps.
	if _dm == null and is_instance_valid(player):
		player.set_vehicle(_vehicle_for_map(name))
	_apply_pending_player()
	_collect_radiation(level)
	_set_hud_mode(player.vehicle if is_instance_valid(player) else 0)
	if _dm != null:
		_dm.on_level_ready(level)

## Place the camera at the DOS player-start marker (marker_type 0), facing
## the direction marker (marker_type 1) — read by LevelLoader. Falls back
## to the entity centroid for maps with no start marker.
func _frame_camera(level: LevelLoader.Level) -> void:
	var spawn: Vector3
	var look_target: Vector3
	# Arriving through a map exit: marker set N = position marker N,
	# facing marker N+1 (PlrSetPosMarker FUN_00121f72, skynet_gh.c:
	# 25074-25087). HP/ammo carry across — only a fresh mission resets.
	var set_id: int = _pending_marker_set
	_pending_marker_set = -1
	var keep_state: bool = set_id >= 0
	if set_id >= 0 and level.markers.has(set_id):
		spawn = (level.markers[set_id] as Array)[0]
		look_target = _nearest_marker(level.markers.get(set_id + 1, []), spawn)
		look_target.y = spawn.y
	elif level.has_player_start:
		spawn = level.player_start
		look_target = level.player_dir
	elif level.entity_count > 0:
		spawn = level.centroid + Vector3(0, 80, 0)
		look_target = spawn + Vector3(0, 0, -512)
	else:
		spawn = Vector3(32768, 800, -32768)
		look_target = spawn + Vector3(0, 0, -512)

	# Guard against a degenerate look target on top of the spawn.
	if look_target.distance_to(spawn) < 1.0:
		look_target = spawn + Vector3(0, 0, -512)
	# Outdoors the DOS player is clamped to the heightfield — MAP.217's
	# start marker sits 200 u UNDER its hillside and the capsule fell
	# through the world (audit 2026-09-03). Never spawn below the terrain.
	if level.is_outdoor and level.wld != null:
		var ground: float = WldTerrain.height_at_world(level.wld, spawn.x, -spawn.z)
		if spawn.y < ground + 4.0:
			print("[skynet] spawn %.0f u under the terrain — lifted to the surface" % (ground - spawn.y))
			spawn.y = ground + 4.0
	spawn = _lift_to_floor(spawn)

	# Spawn the player feet at the marker; gravity settles them onto the
	# surface. Face the direction marker — yaw only, the body never pitches.
	var to := look_target - spawn
	var yaw := 0.0
	if Vector2(to.x, to.z).length() > 0.1:
		yaw = atan2(-to.x, -to.z)
	# Some MAP start markers sit inside a parked vehicle/prop — step the
	# spawn out to the nearest capsule-sized free spot so the player
	# starts beside it, not embedded in it.
	# Marker + 0x10 is floor level in the MAP data (MAP.218's start sits
	# exactly on its floor), so the body spawns there and the camera
	# rides EYE_HEIGHT above it.
	player.set_spawn(_find_clear_spawn(spawn), yaw, not keep_state)

	# Sun above and slightly behind the camera.
	sun.position = spawn + Vector3(0, 8000, -2000)
	print("[skynet] spawn %s, yaw %.1f deg" % [spawn, rad_to_deg(yaw)])

## DOS puts the player on the floor its cell scan finds (FUN_00138500);
## a marker under a walkway (MAP.271: 174 u below the pipe floor) or
## under a hillside is lifted onto the first upward-facing surface above
## it when nothing is within reach below. Returns the adjusted point.
func _lift_to_floor(pos: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return pos
	var down := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 40.0, 0.0), pos - Vector3(0.0, 600.0, 0.0))
	down.collide_with_areas = false
	if space.intersect_ray(down).has("position"):
		return pos
	var up := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 2.0, 0.0), pos + Vector3(0.0, 900.0, 0.0))
	up.collide_with_areas = false
	var hit := space.intersect_ray(up)
	# Seen from below the floor reports its flipped (downward) normal —
	# any near-horizontal surface counts.
	if hit.has("position") and absf((hit["normal"] as Vector3).y) > 0.5:
		var y: float = (hit["position"] as Vector3).y + 2.0
		print("[skynet] spawn has no floor below — lifted %.0f u onto the surface above" % (y - pos.y))
		return Vector3(pos.x, y, pos.z)
	return pos

## Return the spawn point, or — if a player-sized capsule there overlaps
## level geometry — the nearest free spot found by searching outward.
func _find_clear_spawn(pos: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return pos
	var shape := CapsuleShape3D.new()
	shape.radius = 22.0
	shape.height = 80.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	for ring in [0.0, 50.0, 100.0, 200.0, 320.0, 460.0, 640.0]:
		var steps: int = 1 if ring < 1.0 else 12
		for i in steps:
			var a: float = TAU * float(i) / float(steps)
			var p := pos + Vector3(cos(a) * ring, 0.0, sin(a) * ring)
			q.transform = Transform3D(Basis(), p + Vector3(0.0, 60.0, 0.0))
			if not space.intersect_shape(q, 1).is_empty():
				continue
			# A nudged spot must have a floor under it: on MAP.252/473 the
			# start marker touched a table, the first free spot 100 u away
			# was OUTSIDE the room wall, and the player fell into the void
			# (2026-09-02 report).
			if ring > 0.0:
				var r := PhysicsRayQueryParameters3D.create(p + Vector3(0.0, 60.0, 0.0), p - Vector3(0.0, 400.0, 0.0))
				r.collide_with_areas = false
				if not space.intersect_ray(r).has("position"):
					continue
				print("[skynet] spawn nudged %.0fu clear of geometry" % ring)
			return p
	print("[skynet] spawn: no clear spot with a floor nearby — using the marker")
	return pos

## DOS player: eye 75 units above the feet (DAT_00038ce5 = 0x4b,
## skynet_gh.c:25016); marker/start positions are EYE positions.
const EYE_HEIGHT: float = 75.0
## Outdoor depth haze (world units) — DOS fades distant terrain out.
const FOG_BEGIN: float = 3500.0
const FOG_END: float = 16000.0
## Props up to this AABB extent collide as boxes. 0 = off: an AABB box
## turns open props (tables, counters, arches) into solid blocks — the
## MAP.218 spawn ended up inside one, was relocated outside the room and
## fell through the world. DOS-style object cylinders would need the
## .3D bounding radius, not the AABB; trimesh + the anti-wedge routine
## is the safer default.
const PROP_BOX_MAX: float = 0.0
## Mover leaves at most this thick are boxed outright (DORB 16, DOOR01 0,
## 210DOOR 28); thicker movers are boxed only without a floor plate.
const DOOR_LEAF_MAX_THICKNESS: float = 40.0
const DOOR_LEAF_FLOOR_AREA: float = 4096.0     # 64 x 64 walkable plate
const BOX_MIN_THICKNESS: float = 16.0
const PROP_BOX_MIN_THICKNESS: float = 24.0
## Interior lighting (DOS AddLightSafe point lights over a dim ambient).
## Interior light model (variant-2 records: intensity at sub+0 14..72,
## radius-ish value at sub+8 40..540). DOS interiors read as bright
## rooms with lamps as accents; the lamps alone (radius ~1-5 m) cannot
## carry a 12x12-cell map like MAP.214, so the base level does most of
## the work and the lamps add the pools of light.
const LIGHT_RANGE_PER_UNIT: float = 10.0    # variant-2 sub+8 → world units
const LIGHT_ENERGY_DIV: float = 14.0        # variant-2 intensity → energy
const INDOOR_AMBIENT: Color = Color(0.62, 0.62, 0.68)
const OUTDOOR_AMBIENT: Color = Color(0.55, 0.55, 0.65)
## Sodium-ish tint for the street lamps (the DOS lamp sprite's heads are
## white-hot, and the pools they throw read warm against the night).
const LAMP_COLOR: Color = Color(1.0, 0.86, 0.62)
const OUTDOOR_LAMP_SCALE: float = 0.35

## One OmniLight3D per enabled variant-2 light entity, plus the interior
## treatment (dim ambient, cached unshaded materials swapped for shaded
## duplicates).
##
## Outdoor maps carry lights too — MAP.210 has 32, MAP.220 fifty — and
## they are the street lamps: the DOS renderer never lit outdoor terrain
## with them (the lamp SPRITE simply has bright pixels), so the port
## ignored them as well. In ENHANCED, where the world is really lit,
## they go in: that is what makes the lamps cast pools of light at night.
## DOS/RETRO keeps the flat original look.
func _light_level(level: LevelLoader.Level) -> void:
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	var env: Environment = we.environment
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	if level.is_outdoor:
		env.ambient_light_color = OUTDOOR_AMBIENT
		if sun != null:
			sun.visible = true
		if Render.enhanced():
			print("[level] outdoor: %d lamp lights" % _place_map_lights(level, true))
		return
	env.ambient_light_color = INDOOR_AMBIENT
	env.ambient_light_energy = 1.0
	if sun != null:
		sun.visible = false
	var cache: Dictionary = {}
	if Render.enhanced():
		# Materials are already per-pixel lit; a lower ambient lets the
		# lamps carry the room.
		env.ambient_light_color = INDOOR_AMBIENT
		env.ambient_light_energy = 0.75
	else:
		_shade_recursive(level.entities, cache)
		_shade_recursive(level.enemies, cache)
	if level.sprites != null:
		for s in level.sprites.get_children():
			if s is SpriteBase3D:
				(s as SpriteBase3D).shaded = true
	print("[level] interior: %d lights, %d shaded materials"
		% [_place_map_lights(level, false), cache.size()])

## Build the OmniLight3D for every enabled variant-2 entity. Outdoors the
## lamps are warmer and dimmer than an interior fixture, and none of them
## casts shadows — there can be fifty on a map.
func _place_map_lights(level: LevelLoader.Level, outdoor: bool) -> int:
	if level.map == null or level.entities == null:
		return 0
	var n := 0
	for e in level.map.entities:
		if (e.flags & 3) != 2 or e.light_enable <= 0:
			continue
		var l := OmniLight3D.new()
		l.position = Vector3(float(e.x), -float(e.y), -float(e.z))
		l.omni_range = clampf(float(e.light_enable) * LIGHT_RANGE_PER_UNIT, 400.0, 6000.0)
		l.omni_attenuation = 1.0
		l.light_energy = clampf(float(e.light_intensity) / LIGHT_ENERGY_DIV, 0.4, 3.5)
		if outdoor:
			# Accents, not room lighting: a night street has dozens of
			# these overlapping and the full interior energy blows the
			# whole frame out.
			l.light_color = LAMP_COLOR
			l.light_energy = clampf(l.light_energy * OUTDOOR_LAMP_SCALE, 0.15, 0.9)
			l.shadow_enabled = false
		else:
			if Render.enhanced():
				l.light_energy *= 1.6
			# The first few interior lamps cast shadows (a cubemap each).
			l.shadow_enabled = Render.enhanced() and n < 6
		l.add_to_group("maplight")      # agent aid: --near=maplight:N
		level.entities.add_child(l)
		n += 1
	return n

static func _shade_recursive(n: Node, cache: Dictionary) -> void:
	if n == null:
		return
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			for si in mi.mesh.get_surface_count():
				var m: Material = mi.mesh.surface_get_material(si)
				if m is BaseMaterial3D:
					var key: int = m.get_instance_id()
					var dup: BaseMaterial3D = cache.get(key)
					if dup == null:
						dup = (m as BaseMaterial3D).duplicate()
						dup.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
						cache[key] = dup
					mi.set_surface_override_material(si, dup)
	for c in n.get_children():
		_shade_recursive(c, cache)

## DOS fills the frame with a flat sky colour before drawing the
## SKY_SKY.3D band, so nothing black shows above the dome. Sample the
## dome texture's top rows for that colour; interiors get black.
func _set_sky_fill(level: LevelLoader.Level, map_name: String = "") -> void:
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	var env: Environment = we.environment
	var fill := Color(0.0, 0.0, 0.0)
	var night: bool = level.is_outdoor and _is_night_map(map_name)
	_clear_moon()
	if _ash != null and is_instance_valid(_ash):
		_ash.queue_free()
	_ash = null
	if level.is_outdoor and camera != null:
		_ash = FxParticles.ambient_ash(camera)
	if night:
		# No dome on night maps: the flat palette-0x11 sky and the moon.
		if level.sky != null and is_instance_valid(level.sky):
			level.sky.visible = false
		var pal: PackedColorArray = Assets.palette()
		if pal.size() > NIGHT_SKY_INDEX:
			fill = pal[NIGHT_SKY_INDEX]
			fill.a = 1.0
		_make_moon()
		print("[skynet] %s: night sky (fill %s) with the moon" % [map_name, fill])
	elif level.is_outdoor and level.sky != null and level.sky.mesh != null:
		var am: Mesh = level.sky.mesh
		var mat: Material = am.surface_get_material(0) if am.get_surface_count() > 0 else null
		if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
			var img: Image = (mat as BaseMaterial3D).albedo_texture.get_image()
			if img != null and img.get_width() > 0:
				var sum := Color(0, 0, 0)
				var n := 0
				for y in mini(4, img.get_height()):
					for x in img.get_width():
						sum += img.get_pixel(x, y)
						n += 1
				if n > 0:
					fill = sum / float(n)
					fill.a = 1.0
	env.background_mode = Environment.BG_COLOR
	env.background_color = fill
	# The dome is pinned far beyond the fog end — it must not fog out.
	if level.sky != null and level.sky.mesh != null:
		for si in level.sky.mesh.get_surface_count():
			var m: Material = level.sky.mesh.surface_get_material(si)
			if m is BaseMaterial3D:
				var sm: BaseMaterial3D = (m as BaseMaterial3D).duplicate()
				sm.disable_fog = true
				level.sky.set_surface_override_material(si, sm)
	# DOS haze: outdoors everything fades to the dark horizon with
	# distance (the painted mountains in the sky band are black too).
	env.fog_enabled = level.is_outdoor
	if level.is_outdoor:
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_light_color = fill * 0.35
		env.fog_light_energy = 1.0
		env.fog_sun_scatter = 0.0
		env.fog_density = 1.0
		# RENDER DETAIL pulls the haze in (Settings.fog_scale, from the
		# DOS far-clip table 1408 / 2176 / 2432).
		env.fog_depth_begin = FOG_BEGIN * Settings.fog_scale()
		env.fog_depth_end = FOG_END * Settings.fog_scale()
		env.fog_depth_curve = 1.0
		env.fog_aerial_perspective = 0.0
		env.fog_sky_affect = 0.0
	_apply_render_env(level, env, fill)

## --- ENHANCED rendering environment (docs §P) ------------------------------
## The DOS dome (SKY_SKY.3D, painted mountains + moon) is replaced by a
## real sky: a physical sunset / dusk sky when the dome is bright, a
## generated star field with a moon when it is dark (a night map), or a
## hand-made panorama from <converted>/enhanced_pack/sky/{sunset,night}.png. The
## sun becomes a shadow-casting light that matches the sky, plus glow,
## ACES tonemapping and volumetric light for the rays.
const NIGHT_LUMA: float = 0.14

## Time of day is per mission, not per texture: the DOS sky code
## (FUN_00133b67) draws the SKY_SKY.3D dusk dome only for the maps in the
## list at DAT_00052d51 = {250, 260, 270, 280} (missions 5-8, sub-maps
## included here); every other outdoor map — missions 1-4 and the NETLEVEL
## arenas — is NIGHT: a flat sky of palette index 0x11 and a MOON sprite
## (TEXTURE.359 record 2, FUN_00139932) at a fixed bearing, drawn only
## when the dome is not.
const DUSK_MISSIONS: Array = [250, 260, 270, 280]
const NIGHT_SKY_INDEX: int = 0x11
const MOON_BANK: int = 359
const MOON_REC: int = 2
## FUN_00139932 aims the moon along atan2(-6400, 4000) (DOS x, z) — Godot
## flips z — and a fixed elevation; 32° reads like the original screen
## position. Distance keeps it inside the far plane behind everything.
const MOON_ELEVATION_DEG: float = 32.0
const MOON_DIST: float = 100000.0
## DOS blits the 57 px sprite on a 320 px frame (~18 % of the width).
const MOON_SCREEN_FRAC: float = 0.17
## The joke (FUN_00125caf): a shot with the crosshair within 15 px of the
## moon prints "OW!"; the 25th such hit gives it a fall velocity
## (DAT_0005ba10 = 0x18800) and it drops below the horizon for the rest
## of the map (FUN_00139a10 integrates, FUN_001399e7 resets on load).
const MOON_AIM_DEG: float = 4.5
const MOON_HITS_TO_FALL: int = 24
const MOON_MESSAGE: String = "OW!"

var _moon: MeshInstance3D = null
var _moon_hits: int = 0
var _moon_fall_v: float = 0.0
var _moon_fall: float = 0.0            # radians dropped so far

static func _is_dusk_map(map_name: String) -> bool:
	var n: int = _suffix(map_name)
	return ((n / 10) * 10) in DUSK_MISSIONS

static func _is_night_map(map_name: String) -> bool:
	return not _is_dusk_map(map_name)

## Unit vector toward the moon (horizontal bearing from DOS, elevation
## minus whatever it has fallen).
func _moon_dir() -> Vector3:
	var flat := Vector3(-6400.0, 0.0, -4000.0).normalized()
	var el: float = deg_to_rad(MOON_ELEVATION_DEG) - _moon_fall
	return (flat * cos(el) + Vector3.UP * sin(el)).normalized()

## Is `fwd` (a shot direction) on the moon?
func moon_aimed(fwd: Vector3) -> bool:
	if _moon == null or not _moon.visible:
		return false
	return fwd.normalized().angle_to(_moon_dir()) < deg_to_rad(MOON_AIM_DEG)

## A shot landed on the moon.
func moon_shot() -> void:
	if _moon == null or not _moon.visible:
		return
	_set_status(MOON_MESSAGE, 1.5)
	_moon_hits += 1
	if _moon_hits > MOON_HITS_TO_FALL and _moon_fall_v == 0.0:
		_moon_fall_v = 0.02
		print("[skynet] the moon has had enough (%d hits) — falling" % _moon_hits)

func _clear_moon() -> void:
	if _moon != null and is_instance_valid(_moon):
		_moon.queue_free()
	_moon = null
	_moon_hits = 0
	_moon_fall_v = 0.0
	_moon_fall = 0.0

## The night moon: the DOS sprite pinned to the camera (both modes; in
## ENHANCED it glows a little so the bloom picks it up).
func _make_moon() -> void:
	_clear_moon()
	var tex: Texture2D = Assets.texture(MOON_BANK, MOON_REC, true)
	if tex == null:
		return
	# A camera-facing quad with its own material: unshaded, fog off
	# (it sits far past the fog end), alpha-scissored like a DOS blit.
	_moon = MeshInstance3D.new()
	_moon.name = "Moon"
	var qm := QuadMesh.new()
	var fov_w: float = 2.0 * MOON_DIST * tan(deg_to_rad(camera.fov * 0.5)) * (16.0 / 9.0)
	var w: float = fov_w * MOON_SCREEN_FRAC
	qm.size = Vector2(w, w * float(tex.get_height()) / float(tex.get_width()))
	_moon.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.disable_fog = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS if Render.enhanced() else BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if Render.enhanced():
		mat.albedo_color = Color(1.25, 1.25, 1.2)
	_moon.material_override = mat
	_moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_moon)
	_update_moon()

func _update_moon() -> void:
	if _moon == null or not is_instance_valid(_moon) or camera == null:
		return
	_moon.global_position = camera.global_position + _moon_dir() * MOON_DIST
## Seconds the MISSION COMPLETE screen stays before the next mission.
const AUTO_ADVANCE_SEC: float = 6.0

## The DOS sky dome's top band tells the time of day: a red-dominant
## fill is the sunset dome however dark, anything dim and neutral/blue
## is night.
static func _is_night_fill(fill: Color) -> bool:
	var luma: float = fill.r * 0.3 + fill.g * 0.59 + fill.b * 0.11
	if luma >= NIGHT_LUMA:
		return false
	var red_dominant: bool = fill.r > 0.12 and fill.r > (fill.g + fill.b) * 1.5
	return not red_dominant
var _star_sky_tex: Texture2D = null
const DUSK_SKY_SHADER := preload("res://shaders/dusk_sky.gdshader")
## Sun for the ENHANCED dusk: just above the horizon, south-west-ish.
const DUSK_SUN_ROT := Vector3(-7.0, 200.0, 0.0)
const NIGHT_SUN_ROT := Vector3(-38.0, 155.0, 0.0)

func _apply_render_env(level: LevelLoader.Level, env: Environment, fill: Color) -> void:
	var enhanced: bool = Render.enhanced()
	var night: bool = level.is_outdoor and _moon != null
	if level.sky != null and is_instance_valid(level.sky):
		level.sky.visible = not enhanced and not night
	if not enhanced:
		env.glow_enabled = false
		env.volumetric_fog_enabled = false
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		env.ssao_enabled = false
		if sun != null:
			sun.light_energy = 1.2
			sun.light_color = Color(1, 1, 1)
		return
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.4
	# SSAO in game units (1 u ≈ 2 cm — the default 1 u radius did
	# nothing); on everywhere, it is most of the "depth" of the look.
	env.ssao_enabled = true
	env.ssao_radius = 70.0
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	if not level.is_outdoor:
		env.volumetric_fog_enabled = false
		return
	# Sun (or moon) — low over the horizon for the dusk, dim and blue at
	# night. Shadows on: the ENHANCED materials are lit per pixel.
	if sun != null:
		sun.visible = true
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 12000.0
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		if night:
			# Moonlight from the moon's bearing.
			sun.rotation_degrees = NIGHT_SUN_ROT
			sun.look_at_from_position(Vector3.ZERO, -_moon_dir(), Vector3.UP)
			sun.light_color = Color(0.7, 0.76, 0.95)
			sun.light_energy = 0.85
		else:
			sun.rotation_degrees = DUSK_SUN_ROT
			sun.light_color = Color(1.0, 0.68, 0.42)
			sun.light_energy = 2.0
		sun.shadow_opacity = 0.85
		sun.shadow_blur = 1.5
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	var over: String = ""
	for nm in ["sky", "night" if night else "sunset"]:
		over = Render.override_path("sky/%s.png" % nm)
		if not over.is_empty():
			break
	if not over.is_empty():
		# A hand-made equirectangular panorama replaces the whole sky.
		var pm := PanoramaSkyMaterial.new()
		var img := Image.load_from_file(over)
		if img != null:
			img.generate_mipmaps()
			pm.panorama = ImageTexture.create_from_image(img)
		sky.sky_material = pm
	else:
		var sm := ShaderMaterial.new()
		sm.shader = DUSK_SKY_SHADER
		if _star_sky_tex == null:
			_star_sky_tex = _make_star_sky()
		sm.set_shader_parameter("stars", _star_sky_tex)
		if night:
			sm.set_shader_parameter("horizon_color", Color(0.05, 0.06, 0.12))
			sm.set_shader_parameter("zenith_color", Color(0.01, 0.01, 0.03))
			sm.set_shader_parameter("glow_color", Color(0.3, 0.36, 0.55))
			sm.set_shader_parameter("sun_energy", 0.0)       # the moon sprite is the disc
			sm.set_shader_parameter("glow_strength", 0.45)   # its halo
		sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# Ambient: a fixed dusk tint rather than the (mostly black) sky —
	# the shadow side of every hill and building stays readable.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Ambient low, key light high: the shadow side must read darker than
	# the lit side or everything looks flat.
	env.ambient_light_color = Color(0.2, 0.22, 0.34) if night else Color(0.5, 0.4, 0.42)
	env.ambient_light_energy = 0.55 if night else 0.8
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Haze that takes the sky colour, plus volumetric light for the rays.
	env.fog_light_color = fill.lerp(Color(0.05, 0.05, 0.1), 0.6) if night else fill.lerp(Color(1.0, 0.6, 0.35), 0.5)
	env.fog_depth_begin = FOG_BEGIN * 1.5 * Settings.fog_scale()
	env.fog_depth_end = FOG_END * 1.4 * Settings.fog_scale()
	env.fog_sky_affect = 0.0
	env.volumetric_fog_enabled = not night
	env.volumetric_fog_density = 0.00022
	env.volumetric_fog_albedo = Color(1.0, 0.85, 0.7)
	env.volumetric_fog_emission_energy = 0.0
	env.volumetric_fog_length = 12000.0
	env.volumetric_fog_anisotropy = 0.45
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_ambient_inject = 0.05

## The star layer of the ENHANCED sky (added by shaders/dusk_sky.gdshader
## above the horizon glow): a few thousand stars of varying size and
## warmth, a faint milky band, and a full moon (the DOS dome painted one
## too). Black where there is nothing.
func _make_star_sky() -> Texture2D:
	var w: int = 2048
	var h: int = 1024
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1996
	# Milky band: a soft diagonal glow.
	for y in h:
		var v: float = float(y) / float(h)
		for x in range(0, w, 2):
			var u: float = float(x) / float(w)
			var band: float = exp(-pow((v - 0.42 - 0.18 * sin(u * TAU)) * 9.0, 2.0))
			if band > 0.05:
				var c := Color(0.05, 0.06, 0.1) * band * 0.6
				img.set_pixel(x, y, img.get_pixel(x, y) + c)
				img.set_pixel(x + 1, y, img.get_pixel(x + 1, y) + c)
	for _i in 6000:
		var x: int = rng.randi() % w
		var y: int = int(pow(rng.randf(), 0.6) * float(h) * 0.55)   # denser above the horizon
		var mag: float = rng.randf()
		var warm: float = rng.randf()
		var c := Color(0.75 + 0.25 * warm, 0.8, 0.85 + 0.15 * (1.0 - warm)) * (0.35 + 0.65 * mag * mag)
		img.set_pixel(x, y, c)
		if mag > 0.85:
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var px: int = (x + d.x + w) % w
				var py: int = clampi(y + d.y, 0, h - 1)
				img.set_pixel(px, py, c * 0.45)
	# (The moon is a separate sprite — see _make_moon.)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Pin the sky mesh to the camera position each frame (DOS FUN_00133bbb
## re-centres SKY_SKY.3D on the camera). Orientation stays fixed so the
## moon/stars remain world-anchored as the player looks around.
var _walk_target := Vector2.ZERO
var _walk_route: Array = []
var _walk_stuck: float = 0.0
var _walk_last := Vector3.ZERO
var _walk_limit: float = 0.0
var _walk_t: float = -1.0
var _walk_log: float = 0.0

## --walk driver: steer the player's UI intent at the target point.
func _walk_step(delta: float) -> void:
	if _walk_t < 0.0 or not is_instance_valid(player):
		return
	_walk_t += delta
	var p: Vector3 = player.global_position
	var to := _walk_target - Vector2(p.x, p.z)
	var arrived: bool = to.length() < 24.0
	if arrived and not _walk_route.is_empty():
		print("[walk] waypoint %s reached at t=%.1f, y=%.0f" % [_walk_target, _walk_t, p.y])
		_walk_target = _walk_route.pop_front()
		arrived = false
	# Stuck diagnosis: no motion while pushing → print the contacts.
	if not arrived:
		if p.distance_to(_walk_last) < 0.5:
			_walk_stuck += delta
			if _walk_stuck > 1.0:
				_walk_stuck = -3.0
				var desc := ""
				for i in player.get_slide_collision_count():
					var kc: KinematicCollision3D = player.get_slide_collision(i)
					var col: Object = kc.get_collider()
					var cname: String = "?"
					if col is Node:
						var cn: Node = col
						var par: Node = cn.get_parent()
						cname = String(par.get_meta("mesh_name", par.name)) if par != null else cn.name
						if par is MeshInstance3D:
							var pmi: MeshInstance3D = par
							cname += " pos=%s aabb=%s under %s" % [pmi.global_position.snapped(Vector3.ONE),
								pmi.mesh.get_aabb().size.snapped(Vector3.ONE) if pmi.mesh != null else "-",
								pmi.get_parent().name if pmi.get_parent() != null else "-"]
					desc += " n=%s@%s %s" % [kc.get_normal().snapped(Vector3(0.01, 0.01, 0.01)),
						kc.get_position().snapped(Vector3.ONE), cname]
				print("[walk] STUCK at %s floor=%s wall=%s ceiling=%s%s" % [p, player.is_on_floor(),
					player.is_on_wall(), player.is_on_ceiling(), desc])
		else:
			_walk_stuck = maxf(_walk_stuck, 0.0) if _walk_stuck >= 0.0 else _walk_stuck + delta
	_walk_last = p
	if _walk_t > _walk_limit:
		player.ui_move = Vector2.ZERO
		print("[walk] end after %.1f s at %s (%s)" % [_walk_t, p,
			"on floor" if player.is_on_floor() else "airborne"])
		_walk_t = -1.0
		return
	if arrived:
		player.ui_move = Vector2.ZERO        # stand there and keep logging
	else:
		player.set_view(atan2(-to.x, -to.y), 0.0)
		player.ui_move = Vector2(0.0, 1.0)
	_walk_log += delta
	if _walk_log >= (1.0 if arrived else 0.5):
		_walk_log = 0.0
		print("[walk] t=%.1f pos=%s %s vy=%.0f%s" % [_walk_t, p,
			"floor" if player.is_on_floor() else "air", player.velocity.y,
			" (at target)" if arrived else ""])

func _process(delta: float) -> void:
	_walk_step(delta)
	if _current_level != null and _current_level.sky != null \
			and is_instance_valid(_current_level.sky):
		_current_level.sky.position = camera.global_position
	if _moon != null and is_instance_valid(_moon):
		if _moon_fall_v > 0.0 and _moon.visible:
			# FUN_00139a10: velocity feeds an accumulator that feeds the
			# offset — a quadratic drop.
			_moon_fall_v += 0.28 * delta
			_moon_fall += _moon_fall_v * delta
			if sun != null and Render.enhanced():
				sun.look_at_from_position(Vector3.ZERO, -_moon_dir(), Vector3.UP)
			if _moon_fall > deg_to_rad(MOON_ELEVATION_DEG + 12.0):
				_moon.visible = false
				if sun != null and Render.enhanced():
					sun.light_energy = 0.15
				print("[skynet] the moon is gone")
		_update_moon()
	# AUTOMAP fog of war: a few times a second, mark the entity meshes in
	# front of the player as seen (DOS sets flag 0x80 on everything it
	# drew that frame — same idea, cheaper).
	if _current_level != null and _current_level.entities != null \
			and camera != null and is_instance_valid(player) and _dm == null:
		_seen_poll -= delta
		if _seen_poll <= 0.0:
			_seen_poll = 0.25
			var here: Vector3 = player.global_position
			for c in _current_level.entities.get_children():
				if not (c is Node3D):
					continue
				var n: Node3D = c
				if _seen_meshes.has(n.get_instance_id()):
					continue
				if here.distance_to(n.global_position) < 6000.0 \
						and camera.is_position_in_frustum(n.global_position):
					_seen_meshes[n.get_instance_id()] = true
	# Entity action system — movers, proximity triggers, teleports.
	if _current_level != null and _current_level.action != null \
			and is_instance_valid(player):
		_current_level.action.tick(delta, player.global_position)
	if _health_label != null and is_instance_valid(player):
		var hp: int = int(maxf(0.0, player.health))
		var frac: float = 0.0
		if player.max_health > 0.0:
			frac = clampf(player.health / player.max_health, 0.0, 1.0)
		_health_label.text = "%d" % hp
		var low: bool = frac <= 0.3
		_health_label.add_theme_color_override("font_color",
			Color(1, 0.4, 0.32) if low else Color(0.55, 0.95, 0.62))
		if _health_fill != null:
			_health_fill.anchor_right = frac
			_health_fill.color = Color(0.9, 0.3, 0.22) if low \
				else Color(0.3, 0.85, 0.4)
		if _armor_fill != null:
			_armor_fill.anchor_right = clampf(player.armor, 0.0, 1.0)
		# Radiation: dose from the marker-4 sources, charged per second.
		if not _rad_sources.is_empty() and _game_over == null:
			_rad_dose = _radiation_dose(player.global_position + Vector3(0.0, 37.5, 0.0))
			if _rad_dose > 0.0:
				player.take_damage(_rad_dose * delta, false)
		else:
			_rad_dose = 0.0
		if _rad_fill != null:
			_rad_fill.anchor_right = clampf(_rad_dose / RAD_MAX_DOSE, 0.0, 1.0)
		_weapon_label.text = str(player.weapon_name)
		if _hud_mode != player.vehicle:
			_set_hud_mode(player.vehicle)
		if _hud_mode != 0:
			_update_vehicle_hud()
		var am: int = int(player.ammo)
		_ammo_label.text = "%d" % am
		_ammo_label.add_theme_color_override("font_color",
			Color(1, 0.4, 0.32) if am <= 0 else Color(0.55, 0.95, 0.62))
		if hp <= 0 and _game_over == null and _dm == null:
			_show_game_over()
	# No DOS mission ends by body count: they end when the objective
	# counter runs out (_on_objective_complete). `_mission_hostiles` is
	# only a counter for the HUD / tests.

## Use key with nothing under the crosshair: fire an armed exit here.
func _on_use_pressed(pos: Vector3) -> void:
	if _current_level != null and _current_level.action != null:
		var a = _current_level.action
		if not a.activate_teleport(pos):
			a.use_nearby(pos)

## --- Radiation (DOS RadInit 0x13b149 / dose 0x13b1e0) ----------------
## Marker type 4 is a RADIATION SOURCE, not an extraction zone: the u16
## at sub+2 is its strength (80..1024 in the shipped maps). Every frame
## the engine sums a dose from the sources near the player, subtracts it
## as damage (the armour soaks first) and shows it on the PANEL0
## RADIATION gauge. MAP.210 has eight sources.
##
## DOS per source, with the player at eye height:
##   skip when (dist3 * 3) >> 2 > strength     (a 1.33x strength 3D gate)
##   r = strength - dist_horizontal; skip when r <= 0
##   dose += min(r * 50, 12800)
## then dose >>= 8, so one source gives at most 50 and saturates about
## 256 units inside its edge. DOS then charged at least 1 HP per FRAME,
## which makes the damage frame-rate dependent; the port takes the same
## dose as a rate per SECOND and scales it by delta instead.
const RAD_MAX_DOSE: float = 50.0        # per source, DOS min(r*50, 12800) >> 8
var _rad_sources: Array = []            # [{pos: Vector3, strength: float}]
var _rad_dose: float = 0.0              # current dose, HP per second

func _collect_radiation(level: LevelLoader.Level) -> void:
	_rad_sources = []
	_rad_dose = 0.0
	if level == null or level.map == null:
		return
	for e in level.map.entities:
		if (e.flags & 3) != 3 or e.marker_type != 4:
			continue
		var strength: float = float(e.exit_map)   # u16 at sub+2
		if strength <= 0.0:
			continue
		_rad_sources.append({
			"pos": Vector3(float(e.x), -float(e.y), -float(e.z)),
			"strength": strength})
	if not _rad_sources.is_empty():
		print("[skynet] %d radiation sources" % _rad_sources.size())

## Dose at `at` in HP per second (0 when clear).
func _radiation_dose(at: Vector3) -> float:
	var dose: float = 0.0
	for src in _rad_sources:
		var p: Vector3 = src["pos"]
		var strength: float = src["strength"]
		var d3: float = at.distance_to(p)
		if d3 * 0.75 > strength:
			continue
		var r: float = strength - Vector2(at.x - p.x, at.z - p.z).length()
		if r <= 0.0:
			continue
		dose += minf(r * 50.0, 12800.0) / 256.0
	return dose

## --- Mission objectives (DOS FUN_0012ce73 + handler 0x1377d0) --------
## A mission is over when its objective counter reaches zero, NOT by
## reaching a place. The counter is the number of [M1]..[M5] entries in
## the mission's briefing script (<start map>.TXT in MDMDBRIF.BSA);
## MAP.210 has three, the jeep and HK missions one each. An entity whose
## act byte is 0x26+n decrements it once and prints that [M] line; acts
## 0x1C+n print a [G] hint and change nothing; act 0x2B fails the
## mission outright. The counter belongs to the MISSION, so it survives
## the trips into the interiors and back.
##
## (Until 2026-09-03 the port instead ended a mission at a marker-4
## "extraction zone". Marker 4 is a RADIATION SOURCE — see _rad_sources —
## which is why mission 1 could not be finished at all and mission 2
## finished a few seconds after the start.)
var _mission_key: int = -1            # start-map number the script came from
var _mission_objectives: Array = []   # [M1]..[M5] text, "" where absent
var _mission_hints: Array = []        # [G1]..[G9] text
var _objectives_left: int = 0

## Mission number a map belongs to (its start map): the sub-maps of
## mission 1 are 211..218, mission 5 starts on MAP.252 but scripts from
## 250.TXT.
static func _mission_of(map_name: String) -> int:
	var sfx: int = _suffix(map_name)
	return (sfx / 10) * 10 if sfx >= 200 else -1

## Load the mission script when the mission changes; keep the counter
## while moving between the maps of one mission.
func _ensure_mission_script(map_name: String) -> void:
	var key: int = _mission_of(map_name)
	# Deathmatch and the loose non-campaign maps have no script.
	if key < 0 or _dm != null or Net.active:
		return
	if key == _mission_key:
		return
	_mission_key = key
	_mission_objectives = []
	_mission_hints = []
	_objectives_left = 0
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"), SkynetPaths.variant):
		return
	var txt := bsa.read("%d.TXT" % key)
	bsa.close()
	if txt.is_empty():
		return
	var brief: Dictionary = Briefing.parse(txt)
	_mission_objectives = brief.get("missions", [])
	_mission_hints = brief.get("hints", [])
	_mission_tactical = brief.get("tactical", [])
	Stats.begin_mission()
	for t in _mission_objectives:
		if not String(t).is_empty():
			_objectives_left += 1
	print("[skynet] mission %d: %d objectives" % [key, _objectives_left])

func _on_objective_complete(idx: int) -> void:
	var text: String = ""
	if idx >= 0 and idx < _mission_objectives.size():
		text = String(_mission_objectives[idx])
	if _objectives_left > 0:
		_objectives_left -= 1
	print("[skynet] objective %d done, %d left" % [idx + 1, _objectives_left])
	_set_status(text if not text.is_empty() else "OBJECTIVE COMPLETE.", 6.0)
	if _objectives_left <= 0 and not _mission_done and _game_over == null:
		_mission_done = true
		# Let the line be read before the banner covers it (the DOS engine
		# holds the end screen back while a message is on screen).
		await get_tree().create_timer(2.5).timeout
		if _game_over == null:
			_show_mission_complete()

## [G1]..[G9] — flavour radio lines, no bearing on the mission.
func _on_hint_message(idx: int) -> void:
	if idx >= 0 and idx < _mission_hints.size():
		var t: String = String(_mission_hints[idx])
		if not t.is_empty():
			_set_status(t, 6.0)

## Act 0x2B: the mission is lost.
func _on_mission_failed() -> void:
	if _game_over == null:
		_show_game_over()


## A destroyed object's drop (crate → ammo, locker → medkit).
func _on_drop_requested(pos: Vector3, drop_type: int) -> void:
	if _current_level != null:
		LevelLoader.spawn_drop(_current_level, pos, drop_type)

## Of several markers sharing an id, the one nearest `to` (a map may hold
## two facing markers; DOS pairs the closest). `to` itself when empty.
static func _nearest_marker(list: Array, to: Vector3) -> Vector3:
	var best: Vector3 = to
	var best_d: float = -1.0
	for p in list:
		var d: float = (p as Vector3).distance_to(to)
		if best_d < 0.0 or d < best_d:
			best_d = d
			best = p
	return best

## DOS maptype (MapStart, skynet_gh.c:32525): marker type 6, value at
## sub+2; 0 when the map has none. Indexes the music table.
static func _maptype(level: LevelLoader.Level) -> int:
	if level == null or level.map == null:
		return 0
	for e in level.map.entities:
		if (e.flags & 3) == 3 and e.marker_type == 6:
			return int(e.exit_map)
	return 0

## Player mode per mission (table 0x34846 entries: {mission, map, mode}):
## 220 → 4 (jeep), 260 → 4 (jeep), 270 → 8 (HK); everything else 0.
## Sub-maps belong to their mission (map / 10).
static func _vehicle_for_map(map_name: String) -> int:
	var sfx: int = _suffix(map_name)
	if sfx < 200 or sfx >= 300:
		return 0
	match (sfx - 200) / 10:
		2, 6:
			return 1
		7:
			return 2
	return 0

## Mission "main" maps end in 0 (mission = (map - 200) / 10).
static func _is_campaign_main(map_name: String) -> bool:
	var sfx: int = _suffix(map_name)
	return sfx >= 200 and sfx % 10 == 0

## Name of the map currently loaded ("" when none).
func _level_name() -> String:
	if _current_level == null:
		return ""
	return "MAP." + _current_level.map_suffix

## Interior-teleport trigger (act 0xF0 — Skynet.exe 0x137881). The
## handler writes the target map into the pending-map register and the
## spawn-marker set into DAT_00038b1c; the session loop then reloads.
## Target 0 = the map we came from (DAT_00038b18), e.g. MAP.218's hatch
## returns to MAP.210 at marker 27.
func _on_teleport_requested(target_map: int, marker_set: int) -> void:
	var cur: String = _level_name()
	var target: String
	if target_map <= 0:
		if _prev_map_name.is_empty():
			_set_status("Exit leads back, but there is no previous map")
			return
		target = _prev_map_name
	else:
		target = "MAP.%03d" % target_map
	var t_idx: int = _maps.find(target)
	if t_idx < 0:
		_set_status("Exit target %s is not in MDMDMAP2.BSA" % target)
		return
	print("[skynet] exit %s → %s (marker set %d)" % [cur, target, marker_set])
	_prev_map_name = cur
	_pending_marker_set = marker_set
	_map_idx = t_idx
	_transition(target)

## Fade out, swap the level, fade back in. Exits bypass the briefing —
## this is an in-mission move.
func _transition(target: String) -> void:
	await _fade_to(1.0, 0.25)
	_clear_level()
	await _begin_level(target)
	await _fade_to(0.0, 0.35)

## --- Save / load (docs §N.4) -----------------------------------------------
## A save is the DOS session state: the current map, the previous-map
## register, every map's Mst overlay and the player. Maps reload from
## disk on load, as they do on every transition.

## Snapshot the running game into `slot`. False when no level is up.
func save_to_slot(slot: int) -> bool:
	if _dm != null:
		_set_status("NO SAVING IN A NETWORK GAME.")
		return false
	if _current_level == null or not is_instance_valid(player):
		_set_status("NOTHING TO SAVE.")
		return false
	_save_map_state()
	var data := {
		"version": SaveGame.VERSION,
		"time": Time.get_datetime_string_from_system(false, true),
		"map": _level_name(),
		"prev_map": _prev_map_name,
		"map_state": _map_state,
		"player": player.save_state(),
	}
	if not SaveGame.write(slot, data):
		_set_status("SAVE FAILED.")
		return false
	print("[skynet] saved slot %d: %s" % [slot, data["map"]])
	_set_status("GAME SAVED.")
	return true

## Restore `slot`: tear the current level down, install the saved state
## and reload the saved map with the player where they were.
func load_from_slot(slot: int) -> bool:
	if _dm != null:
		_set_status("NO LOADING IN A NETWORK GAME.")
		return false
	var data: Dictionary = SaveGame.read(slot)
	if data.is_empty():
		_set_status("EMPTY SLOT.")
		return false
	var map_name: String = String(data.get("map", ""))
	var idx: int = _maps.find(map_name)
	if idx < 0:
		_set_status("SAVED MAP %s IS MISSING." % map_name)
		return false
	print("[skynet] loading slot %d: %s" % [slot, map_name])
	# Whatever screen is up (briefing, end screen) goes away first.
	if _briefing_overlay != null:
		_briefing_teardown()
	get_tree().paused = false
	if _game_over != null:
		_game_over.queue_free()
		_game_over = null
	await _fade_to(1.0, 0.25)
	# _clear_level snapshots the live map into _map_state — do it BEFORE
	# the saved overlay replaces that dictionary.
	_clear_level()
	_map_state = data.get("map_state", {})
	_prev_map_name = String(data.get("prev_map", ""))
	_pending_marker_set = -1
	_pending_player = data.get("player", {})
	_map_idx = idx
	await _begin_level(map_name)
	await _fade_to(0.0, 0.35)
	_set_status("GAME LOADED.")
	return true

## End of _begin_level: put the player back where the save left them.
func _apply_pending_player() -> void:
	if _pending_player.is_empty():
		return
	var snap: Dictionary = _pending_player
	_pending_player = {}
	if is_instance_valid(player):
		player.restore_state(snap)
		if _current_level != null and _current_level.action != null:
			_current_level.action.arm_proximity(player.global_position)

func _fade_to(alpha: float, dur: float) -> void:
	if _fade == null:
		var cl := CanvasLayer.new()
		cl.layer = 70
		add_child(cl)
		_fade = ColorRect.new()
		_fade.color = Color(0, 0, 0, 0)
		_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cl.add_child(_fade)
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", alpha, dur)
	await tw.finished

## Snapshot the current map before it is torn down (DOS MstSave): which
## enemy markers are dead, which pickups were taken, and the action
## system's trigger/mover/destructible state.
func _save_map_state() -> void:
	var lvl := _current_level
	if lvl == null:
		return
	var dead: Dictionary = {}
	for off in lvl.enemy_marker_offs:
		dead[off] = true
	if lvl.enemies and is_instance_valid(lvl.enemies):
		for c in lvl.enemies.get_children():
			if c.has_meta("marker_off") \
					and not (c.has_method("is_dead") and c.is_dead()):
				dead.erase(c.get_meta("marker_off"))
	var taken: Dictionary = {}
	for off in lvl.pickup_offs:
		taken[off] = true
	if lvl.sprites and is_instance_valid(lvl.sprites):
		for c in lvl.sprites.get_children():
			if c.has_meta("pickup_off"):
				taken.erase(c.get_meta("pickup_off"))
	_map_state[_level_name()] = {
		"dead": dead, "taken": taken,
		"action": lvl.action.save_state() if lvl.action != null else {},
		# Entity signature for variant maps (MAP.216/217 are the base of
		# MAP.210 re-authored): file offset → identity key, see
		# _import_variant_state.
		"sig": _map_signature(lvl.map),
		"grid": Vector2i(lvl.map.grid_width, lvl.map.grid_height),
		"outdoor": lvl.is_outdoor,
	}

## Identity of an entity across map variants: kind + name/type + exact
## DOS position (shared objects keep their coordinates when a map is
## re-authored; only the file offsets shift).
static func _entity_key(m: LevelLoader.MapFile.MapFile, e) -> String:
	var v: int = e.flags & 3
	var id: String
	if v == 1:
		id = "1|" + LevelLoader.MapFile.entity_name(m, e)
	elif v == 2:
		id = "L"
	elif e.marker_type == 2:
		id = "E|%d" % e.enemy_type
	elif e.marker_type >= 0:
		id = "M|%d" % e.marker_type
	else:
		id = "S|%d" % e.sprite_index
	return "%s|%d,%d,%d" % [id, e.x, e.y, e.z]

static func _map_signature(m: LevelLoader.MapFile.MapFile) -> Dictionary:
	var sig: Dictionary = {}
	if m == null:
		return sig
	for e in m.entities:
		sig[e.file_off] = _entity_key(m, e)
	return sig

## First visit to a map that is a VARIANT of one already played (the
## base after the truck ride = MAP.216, after the lasers = MAP.217):
## DOS keeps its Mst overlay per map number, so the base would come
## back with every switch reset — the player asked for the state to
## carry over. Find the best-matching visited map (same grid, ≥ 60 % of
## this map's meshes present at the same coordinates) and translate its
## snapshot by entity identity: dead enemies, taken pickups, switch and
## mover states, damage. Objects the variant adds (reinforcements) are
## untouched, objects it drops are skipped.
func _import_variant_state(level: LevelLoader.Level, name: String) -> Dictionary:
	# Outdoor maps only: interiors built from the same room kit (the two
	# truck boxes MAP.211/212 share 72 % of their pieces) are different
	# places, not variants of one.
	if level.map == null or not level.is_outdoor:
		return {}
	var mine: Dictionary = {}            # key → my file offset
	var mesh_total: int = 0
	for e in level.map.entities:
		mine[_entity_key(level.map, e)] = e.file_off
		if (e.flags & 3) == 1:
			mesh_total += 1
	if mesh_total == 0:
		return {}
	var best: String = ""
	var best_ratio: float = 0.6
	var best_remap: Dictionary = {}
	for other in _map_state:
		if other == name:
			continue
		var snap: Dictionary = _map_state[other]
		if snap.get("grid", Vector2i.ZERO) != Vector2i(level.map.grid_width, level.map.grid_height):
			continue
		if bool(snap.get("outdoor", false)) != level.is_outdoor:
			continue
		var sig: Dictionary = snap.get("sig", {})
		var remap: Dictionary = {}       # other offset → my offset
		var mesh_hits: int = 0
		for off in sig:
			var key: String = sig[off]
			if mine.has(key):
				remap[off] = mine[key]
				if key.begins_with("1|"):
					mesh_hits += 1
		var ratio: float = float(mesh_hits) / float(mesh_total)
		if ratio >= best_ratio:
			best_ratio = ratio
			best = other
			best_remap = remap
	if best.is_empty():
		return {}
	var src: Dictionary = _map_state[best]
	var out: Dictionary = {"dead": {}, "taken": {}, "action": {}}
	for off in src.get("dead", {}):
		if best_remap.has(off):
			out["dead"][best_remap[off]] = true
	for off in src.get("taken", {}):
		if best_remap.has(off):
			out["taken"][best_remap[off]] = true
	var act_src: Dictionary = src.get("action", {})
	var act: Dictionary = {}
	for part in ["states", "movers", "destr", "hp", "spent"]:
		var d: Dictionary = {}
		for off in act_src.get(part, {}):
			if best_remap.has(off):
				d[best_remap[off]] = act_src[part][off]
		act[part] = d
	out["action"] = act
	print("[skynet] %s: first visit — importing state from variant %s (%d%% of meshes shared, %d dead, %d taken)"
		% [name, best, int(best_ratio * 100.0), out["dead"].size(), out["taken"].size()])
	return out

## Re-apply a saved snapshot to a freshly loaded map (DOS MstLoad).
func _apply_map_state(level: LevelLoader.Level, name: String) -> void:
	var snap: Dictionary = _map_state.get(name, {})
	if snap.is_empty():
		snap = _import_variant_state(level, name)
		if snap.is_empty():
			return
		_map_state[name] = snap
	var dead: Dictionary = snap.get("dead", {})
	if level.enemies:
		for c in level.enemies.get_children():
			if c.has_meta("marker_off") and dead.has(c.get_meta("marker_off")):
				level.enemies.remove_child(c)
				c.queue_free()
	var taken: Dictionary = snap.get("taken", {})
	if level.sprites:
		for c in level.sprites.get_children():
			if c.has_meta("pickup_off") and taken.has(c.get_meta("pickup_off")):
				level.sprites.remove_child(c)
				c.queue_free()
	if level.action != null:
		level.action.restore_state(snap.get("action", {}))
	print("[skynet] %s: restored state (%d dead, %d pickups taken)"
		% [name, dead.size(), taken.size()])

func _show_game_over() -> void:
	_show_end_screen("MISSION FAILED", Color(0.9, 0.22, 0.16), true,
		"", "FAILED.IMG")

func _show_mission_complete() -> void:
	_show_end_screen("MISSION COMPLETE", Color(0.42, 0.92, 0.48),
		false, _next_campaign_map(), "WELLDONE.IMG")

## Next campaign map after the current one, or "" at the end of the
## campaign. Works whether the current map is a mission map or a sub-map.
func _next_campaign_map() -> String:
	if _map_idx < 0 or _map_idx >= _maps.size():
		return ""
	var cur: int = _suffix(_maps[_map_idx])
	for m in _campaign_maps:
		if _suffix(m) > cur:
			return m
	return ""

## Show a paused end-of-mission screen. `respawnable` adds a RESPAWN
## button (death); a non-empty `next_map` adds a NEXT MISSION button (win).
func _show_end_screen(title: String, color: Color, respawnable: bool,
		next_map: String = "", banner_img: String = "") -> void:
	if _game_over != null:
		return
	var cl := CanvasLayer.new()
	cl.layer = 80
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(cl)
	_game_over = cl
	print("[skynet] end screen: %s" % title)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cl.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cl.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 22)
	center.add_child(vb)
	# The DOS banner art — WELLDONE.IMG "WELL DONE, SOLDIER!" (189x18) or
	# FAILED.IMG "MISSION FAILED, SOLDIER!" (228x18), index 0 transparent —
	# blown up to most of the screen width, the way the original announced
	# it. Falls back to a plain caption when the archive is missing.
	var banner: ImageTexture = _load_panel_texture(banner_img, true)
	if banner != null:
		var tr := TextureRect.new()
		tr.texture = banner
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var vw: float = get_viewport().get_visible_rect().size.x
		var bw: float = clampf(vw * 0.62, 320.0, 1400.0)
		tr.custom_minimum_size = Vector2(bw,
			bw * float(banner.get_height()) / float(banner.get_width()))
		vb.add_child(tr)
	else:
		var ttl := Label.new()
		ttl.text = title
		ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ttl.add_theme_font_size_override("font_size", 56)
		ttl.add_theme_color_override("font_color", color)
		vb.add_child(ttl)
	if respawnable:
		vb.add_child(_game_over_button("RESPAWN", _game_over_respawn))
	if next_map != "":
		vb.add_child(_game_over_button("NEXT MISSION",
			_advance_to.bind(next_map)))
	vb.add_child(_game_over_button("MAIN MENU", _game_over_menu))
	get_tree().paused = true
	# The mouse is captured while playing — free it or the buttons cannot
	# be clicked (a 2026-09-03 report: "mission complete and it just hung").
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(player) and player.has_method("_capture"):
		player.call("_capture", false)
	# A won mission moves on by itself after a few seconds, like the DOS
	# game's debrief → next briefing flow (the buttons still work sooner).
	if next_map != "":
		var my: CanvasLayer = cl
		get_tree().create_timer(AUTO_ADVANCE_SEC, true, false, true).timeout.connect(func() -> void:
			if _game_over == my and is_instance_valid(my):
				_advance_to(next_map))

## Clear the end screen and load `map_name` (the next campaign mission).
func _advance_to(map_name: String) -> void:
	get_tree().paused = false
	if _game_over != null:
		_game_over.queue_free()
		_game_over = null
	var idx: int = _maps.find(map_name)
	if idx >= 0:
		_map_idx = idx
		_load_current()

## Show the pre-mission briefing for a mission "main" map, if one exists.
## Returns true when a briefing screen is up — the caller then defers the
## level load to the briefing's BEGIN button. Returns false (load the
## level now) for sub-maps or maps without a briefing file.
func _maybe_show_briefing(map_name: String) -> bool:
	var sfx: int = _suffix(map_name)
	if sfx < 200 or sfx % 10 != 0:
		return false                        # sub-map / not a mission start
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"),
			SkynetPaths.variant):
		return false
	var txt := bsa.read("%d.TXT" % sfx)
	bsa.close()
	if txt.is_empty():
		return false
	var brief: Dictionary = Briefing.parse(txt)
	_mission_tactical = brief.get("tactical", [])
	var obj: String = brief.get("objectives", "")
	var lines: Array = brief.get("lines", [])
	if obj.is_empty() and lines.is_empty():
		return false
	_briefing_pending_map = map_name
	_show_briefing(sfx, obj, lines)
	# _show_briefing bails out if it could not build any pages — only
	# defer the load when the overlay actually came up.
	return _briefing_overlay != null

## Load the briefing screen art from MDMDIMGS.BSA. The UI chrome (the
## BUTTON*.IMG top-bar tabs, the MENU000 text panel) and the speaker
## portraits use the BRIEF.COL palette; the BRIEF<map>.IMG scene picture
## uses BRIEF2.COL.
## Returns {_ui:{PANEL, BUTTON04..BUTTON11}, _intro, _backdrop, <id>:Tex}.
func _load_brief_textures(map_num: int, lines: Array) -> Dictionary:
	var out: Dictionary = {}
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"),
			SkynetPaths.variant):
		return out
	var pal_ui := Palette.parse(bsa.read("BRIEF.COL"))
	var pal_scene := Palette.parse(bsa.read("BRIEF2.COL"))
	if pal_scene.is_empty():
		pal_scene = pal_ui
	var ui: Dictionary = {}
	if not pal_ui.is_empty():
		ui["PANEL"] = ImgFile.parse(bsa.read("MENU000.IMG"), pal_ui)
		# The eight top-bar button graphics (grey + green per tab).
		for tab in BR_TABS:
			for key in [tab[2], tab[3]]:
				ui[key] = ImgFile.parse(bsa.read(key + ".IMG"), pal_ui)
	out["_ui"] = ui
	if not pal_scene.is_empty():
		out["_backdrop"] = ImgFile.parse(bsa.read("TACTBAK.IMG"), pal_scene)
		var intro := bsa.read("BRIEF%d.IMG" % map_num)
		if not intro.is_empty():
			out["_intro"] = ImgFile.parse(intro, pal_scene)
	if not pal_ui.is_empty():
		var want: Dictionary = {}
		for ln in lines:
			want[int(ln["speaker"])] = true
		for sp in want:
			var b := bsa.read("BRIEF%03d.IMG" % int(sp))
			if not b.is_empty():
				out[sp] = ImgFile.parse(b, pal_ui)
	bsa.close()
	return out

## Paused mission-briefing screen, rebuilt from the original DOS briefing
## (FUN_0012c300): the BUTTON*.IMG tab bar (BEGIN / BRIEFING / TACTICAL /
## STATISTICS), the BRIEF<map> scene picture, and the MENU000 bottom
## panel holding the objectives / dialogue text with up/down scroll
## arrows. The 320x200 screen is stretched full-bleed, like the rest of
## the ported front-end.
func _show_briefing(map_num: int, objectives: String, lines: Array) -> void:
	if _briefing_overlay != null:
		return
	var tex: Dictionary = _load_brief_textures(map_num, lines)
	var intro: Texture2D = tex.get("_intro", null)
	var backdrop: Texture2D = tex.get("_backdrop", null)
	_briefing_backdrop = backdrop
	var scene_default: Texture2D = intro if intro != null else backdrop

	# Pages: mission objectives first, then one per dialogue turn.
	_briefing_pages = []
	if not objectives.is_empty():
		_briefing_pages.append({"img": scene_default, "text": objectives,
			"title": "MISSION %d  OBJECTIVES" % ((map_num - 200) / 10)})
	for ln in lines:
		var img: Texture2D = tex.get(int(ln["speaker"]), scene_default)
		_briefing_pages.append({"img": img if img != null else backdrop,
			"text": String(ln["text"]), "title": "INCOMING TRANSMISSION"})
	if _briefing_pages.is_empty():
		return
	_briefing_page = 0

	var ui: Dictionary = tex.get("_ui", {})
	var cl := CanvasLayer.new()
	cl.layer = 85
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(cl)
	_briefing_overlay = cl

	# Black letterbox behind the 320x200 screen.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 1)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cl.add_child(dim)

	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cl.add_child(screen)

	# Scene picture (BRIEF<map>.IMG or the active speaker portrait).
	_briefing_scene = TextureRect.new()
	_briefing_scene.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_briefing_scene.stretch_mode = TextureRect.STRETCH_SCALE
	_briefing_scene.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_briefing_scene.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_br_anchor(_briefing_scene, BR_SCENE_RECT)
	screen.add_child(_briefing_scene)

	# MENU000 bottom panel.
	var panel := _br_texrect(ui.get("PANEL"))
	_br_anchor(panel, BR_PANEL_RECT)
	screen.add_child(panel)

	# Top bar — the four BUTTON*.IMG tab buttons. BRIEFING is the active
	# tab; BEGIN launches the mission; TACTICAL / STATISTICS are drawn
	# from the real art but not yet wired to a view.
	for tab in BR_TABS:
		var tname: String = tab[0]
		var cb: Callable
		match tname:
			"BEGIN":
				cb = _briefing_begin
			_:
				cb = _briefing_set_tab.bind(tname)
		var t := _br_tab(tab[1], ui.get(tab[2]), ui.get(tab[3]),
			tname == "BRIEFING", cb)
		_briefing_tabs[tname] = t
		screen.add_child(t)

	# Scrolling objectives / dialogue text inside the MENU000 panel.
	_briefing_scroll = ScrollContainer.new()
	_briefing_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_briefing_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_br_anchor(_briefing_scroll, BR_TEXT_RECT)
	screen.add_child(_briefing_scroll)
	_briefing_text = Label.new()
	_briefing_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_briefing_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_briefing_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_briefing_text.add_theme_color_override("font_color", Color(0.83, 0.93, 0.84))
	if _hud_font != null:
		_briefing_text.add_theme_font_override("font", _hud_font)
	_briefing_scroll.add_child(_briefing_text)

	# Transparent hotspots over the MENU000 up/down arrows — they scroll
	# the panel text and page through the briefing.
	var up_b := _br_hotspot(BR_UP_RECT, _briefing_step.bind(-1))
	up_b.shortcut = _br_shortcut([KEY_UP, KEY_PAGEUP])
	screen.add_child(up_b)
	var down_b := _br_hotspot(BR_DOWN_RECT, _briefing_step.bind(1))
	down_b.shortcut = _br_shortcut([KEY_DOWN, KEY_PAGEDOWN, KEY_SPACE])
	screen.add_child(down_b)

	# Keyboard-only shortcuts — Enter begins the mission, Esc aborts to
	# the menu (the DOS bar has no EXIT button: the four tabs fill it).
	screen.add_child(_br_keybtn([KEY_ENTER, KEY_KP_ENTER], _briefing_begin))
	screen.add_child(_br_keybtn([KEY_ESCAPE], _briefing_exit))

	# TACTICAL: the rotating dossier model, over the picture slot.
	_tactical = preload("res://scripts/tactical_view.gd").new()
	_br_anchor(_tactical, BR_SCENE_RECT)
	_tactical.visible = false
	_tactical.call("setup", _mission_tactical)
	_tactical.connect("changed", func() -> void: _briefing_refresh_tab())
	screen.add_child(_tactical)

	# STATISTICS: four percentages on the same slot.
	_stats_box = VBoxContainer.new()
	_stats_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_stats_box.add_theme_constant_override("separation", 10)
	# DOS puts the labels at x=15 and right-aligns the values at x=235.
	_br_anchor(_stats_box, Rect2(15, 30, 220, 104))
	_stats_box.visible = false
	_stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(_stats_box)

	get_tree().paused = true
	if not get_viewport().size_changed.is_connected(_briefing_layout):
		get_viewport().size_changed.connect(_briefing_layout)
	_briefing_layout()
	_briefing_show_page(0)

## A TextureRect that stretches `tex` to its anchored rect; if `tex` is
## missing it falls back to a flat dark-teal fill so the band still reads.
func _br_texrect(tex: Variant) -> TextureRect:
	var tr := TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if tex != null:
		tr.texture = tex
	else:
		var fill := ColorRect.new()
		fill.color = Color(0.10, 0.16, 0.16)
		fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.add_child(fill)
	return tr

## Anchor a Control to an image-pixel rect on the 320x200 briefing screen.
func _br_anchor(node: Control, r: Rect2) -> void:
	node.anchor_left = r.position.x / BRIEF_W
	node.anchor_top = r.position.y / BRIEF_H
	node.anchor_right = (r.position.x + r.size.x) / BRIEF_W
	node.anchor_bottom = (r.position.y + r.size.y) / BRIEF_H
	node.offset_left = 0.0
	node.offset_top = 0.0
	node.offset_right = 0.0
	node.offset_bottom = 0.0

## A transparent hotspot over the MENU000 arrow art — invisible until
## hovered, so the baked arrow graphic shows through.
func _br_hotspot(rect: Rect2, cb: Callable) -> Button:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	var empty := StyleBoxEmpty.new()
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.5, 1.0, 0.6, 0.22)
	var pressed := StyleBoxFlat.new()
	pressed.bg_color = Color(0.9, 0.45, 0.2, 0.32)
	b.add_theme_stylebox_override("normal", empty)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", empty)
	_br_anchor(b, rect)
	b.pressed.connect(cb)
	return b

## Build a Shortcut resource firing on any of `keys`.
func _br_shortcut(keys: Array) -> Shortcut:
	var sc := Shortcut.new()
	var evs: Array[InputEvent] = []
	for k in keys:
		var e := InputEventKey.new()
		e.keycode = k
		evs.append(e)
	sc.events = evs
	return sc

## A top-bar tab built from its grey / green BUTTON*.IMG pair. The green
## highlight shows while the tab is hovered, or permanently if `active`.
func _br_tab(rect: Rect2, grey: Variant, green: Variant, active: bool,
		cb: Callable) -> Control:
	var holder := Control.new()
	_br_anchor(holder, rect)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var base := _br_texrect(grey)
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(base)
	var hl := _br_texrect(green)
	hl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hl.visible = active
	holder.add_child(hl)
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	var empty := StyleBoxEmpty.new()
	btn.add_theme_stylebox_override("normal", empty)
	btn.add_theme_stylebox_override("hover", empty)
	btn.add_theme_stylebox_override("pressed", empty)
	btn.add_theme_stylebox_override("focus", empty)
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.set_meta("active", active)
	btn.mouse_entered.connect(func() -> void: hl.visible = true)
	btn.mouse_exited.connect(func() -> void: hl.visible = bool(holder.get_meta("active", false)))
	holder.set_meta("highlight", hl)
	if cb.is_valid():
		btn.pressed.connect(cb)
	holder.add_child(btn)
	return holder

## Light a mission-screen tab up as the active one.
func _br_tab_active(holder: Control, on: bool) -> void:
	if holder == null or not is_instance_valid(holder):
		return
	holder.set_meta("active", on)
	var hl = holder.get_meta("highlight", null)
	if hl != null and is_instance_valid(hl):
		hl.visible = on

## An invisible, zero-size Button that only carries a keyboard Shortcut —
## the DOS briefing bar has no on-screen EXIT, so Esc is keyboard-only.
func _br_keybtn(keys: Array, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.modulate = Color(1, 1, 1, 0)
	b.custom_minimum_size = Vector2.ZERO
	b.size = Vector2.ZERO
	b.shortcut = _br_shortcut(keys)
	b.pressed.connect(cb)
	return b

## Size the briefing text font to the current window.
func _briefing_layout() -> void:
	if _briefing_text == null or not is_instance_valid(_briefing_text):
		return
	var vh: float = get_viewport().get_visible_rect().size.y
	_briefing_text.add_theme_font_size_override("font_size",
		int(clampf(vh / 26.0, 14.0, 40.0)))

## Render briefing page `i` into the screen widgets.
func _briefing_show_page(i: int) -> void:
	i = clampi(i, 0, _briefing_pages.size() - 1)
	_briefing_page = i
	var page: Dictionary = _briefing_pages[i]
	var img: Texture2D = page.get("img", null)
	if img != null:
		_briefing_scene.texture = img
	_briefing_text.text = String(page["text"])
	_briefing_scroll.scroll_vertical = 0

## Up/down arrow: scroll the panel text if it overflows, otherwise step
## to the previous / next briefing page.
func _briefing_step(dir: int) -> void:
	if _briefing_scroll == null or not is_instance_valid(_briefing_scroll):
		return
	var vbar := _briefing_scroll.get_v_scroll_bar()
	var max_scroll: int = 0
	if vbar != null:
		max_scroll = int(maxf(0.0, vbar.max_value - _briefing_scroll.size.y))
	var step: int = maxi(24, int(_briefing_scroll.size.y * 0.85))
	if dir > 0:
		if _briefing_scroll.scroll_vertical < max_scroll:
			_briefing_scroll.scroll_vertical = mini(
				_briefing_scroll.scroll_vertical + step, max_scroll)
		elif _briefing_page < _briefing_pages.size() - 1:
			_briefing_show_page(_briefing_page + 1)
	else:
		if _briefing_scroll.scroll_vertical > 0:
			_briefing_scroll.scroll_vertical = maxi(
				_briefing_scroll.scroll_vertical - step, 0)
		elif _briefing_page > 0:
			_briefing_show_page(_briefing_page - 1)
	Audio.play_sfx("BUTTON1.RAW")

## BEGIN — dismiss the briefing and load the mission level.
func _briefing_begin() -> void:
	Audio.play_sfx("BUTTON1.RAW")
	var m: String = _briefing_pending_map
	_briefing_teardown()
	if m != "":
		_begin_level(m)

## Esc — abort the mission and return to the main menu.
func _briefing_exit() -> void:
	Audio.play_sfx("BUTTON1.RAW")
	_briefing_teardown()
	_return_to_menu()

## Switch the mission screen between BRIEFING, TACTICAL and STATISTICS.
func _briefing_set_tab(tab_name: String) -> void:
	Audio.play_sfx("BUTTON1.RAW")
	_briefing_mode = tab_name
	for nm in _briefing_tabs:
		_br_tab_active(_briefing_tabs[nm], nm == tab_name)
	if _tactical != null and is_instance_valid(_tactical):
		_tactical.visible = tab_name == "TACTICAL"
	if _stats_box != null and is_instance_valid(_stats_box):
		_stats_box.visible = tab_name == "STATISTICS"
	if _briefing_scene != null and is_instance_valid(_briefing_scene):
		_briefing_scene.texture = _briefing_backdrop if tab_name != "BRIEFING" \
			else _briefing_page_img()
	_briefing_refresh_tab()

## Text under the picture for the tab on screen.
func _briefing_refresh_tab() -> void:
	if _briefing_text == null or not is_instance_valid(_briefing_text):
		return
	match _briefing_mode:
		"TACTICAL":
			var unit: String = String(_tactical.call("unit_name"))
			_briefing_text.text = "%s\n\n%s\n\n(CLICK THE PICTURE FOR THE NEXT UNIT)" \
				% [unit, String(_tactical.call("text"))]
		"STATISTICS":
			_build_stats_rows()
			_briefing_text.text = "MISSION AND CAREER PERFORMANCE."
		_:
			_briefing_show_page(_briefing_page)
	if _briefing_scroll != null and is_instance_valid(_briefing_scroll):
		_briefing_scroll.scroll_vertical = 0

## The four percentages of the DOS STATISTICS page: this mission's shot
## hit-ratio and share of enemies destroyed, then the career totals.
func _build_stats_rows() -> void:
	if _stats_box == null or not is_instance_valid(_stats_box):
		return
	for c in _stats_box.get_children():
		c.queue_free()
	var rows: Array = [
		["SHOTS HIT-RATIO:", Stats.pct(Stats.hits, Stats.shots)],
		["ENEMIES DESTROYED:", Stats.pct(Stats.kills, Stats.enemies)],
		["HIT-RATIO TOTAL:", Stats.pct(Stats.total_hits, Stats.total_shots)],
		["ENEMIES TOTAL:", Stats.pct(Stats.total_kills, Stats.total_enemies)],
	]
	for r in rows:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 24)
		var l := Label.new()
		l.text = String(r[0])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := Label.new()
		v.text = String(r[1])
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		for lab in [l, v]:
			lab.add_theme_color_override("font_color", Color(0.83, 0.93, 0.84))
			lab.add_theme_font_size_override("font_size",
				int(clampf(get_viewport().get_visible_rect().size.y / 22.0, 14.0, 44.0)))
			if _hud_font != null:
				lab.add_theme_font_override("font", _hud_font)
			line.add_child(lab)
		_stats_box.add_child(line)

func _briefing_page_img() -> Texture2D:
	if _briefing_page >= 0 and _briefing_page < _briefing_pages.size():
		return _briefing_pages[_briefing_page].get("img", null)
	return null

## Briefly flash a note across the briefing scene picture.
func _briefing_toast(msg: String) -> void:
	if _briefing_scene == null or not is_instance_valid(_briefing_scene):
		return
	if _briefing_toast_label == null or not is_instance_valid(_briefing_toast_label):
		var l := Label.new()
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_color_override("font_color", Color(1, 0.86, 0.4))
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		l.add_theme_constant_override("outline_size", 5)
		l.add_theme_font_size_override("font_size", int(clampf(
			get_viewport().get_visible_rect().size.y / 30.0, 16.0, 34.0)))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_br_anchor(l, Rect2(24, 66, 272, 32))
		_briefing_scene.get_parent().add_child(l)
		_briefing_toast_label = l
	_briefing_toast_label.text = msg
	_briefing_toast_label.visible = true
	var tm := get_tree().create_timer(2.4)
	tm.timeout.connect(func() -> void:
		if is_instance_valid(_briefing_toast_label):
			_briefing_toast_label.visible = false)

func _briefing_teardown() -> void:
	get_tree().paused = false
	if get_viewport().size_changed.is_connected(_briefing_layout):
		get_viewport().size_changed.disconnect(_briefing_layout)
	_briefing_pages = []
	_briefing_text = null
	_briefing_scroll = null
	_briefing_scene = null
	_briefing_toast_label = null
	_briefing_pending_map = ""
	if _briefing_overlay != null:
		_briefing_overlay.queue_free()
		_briefing_overlay = null

func _game_over_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 58)
	b.add_theme_font_size_override("font_size", 24)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _game_over_respawn() -> void:
	get_tree().paused = false
	if _game_over != null:
		_game_over.queue_free()
		_game_over = null
	if is_instance_valid(player):
		player.respawn()

func _game_over_menu() -> void:
	get_tree().paused = false
	_return_to_menu()

func _clear_level() -> void:
	# The hostile counter belongs to the map being torn down.
	_mission_hostiles = 0
	_seen_meshes.clear()
	if _automap != null and is_instance_valid(_automap):
		_automap.call("close_map")
	_mission_done = true
	if _current_level == null: return
	_save_map_state()
	# In-flight shots and grenades belong to the map being torn down.
	for p in get_tree().get_nodes_in_group("projectile"):
		p.queue_free()
	if _current_level.terrain and is_instance_valid(_current_level.terrain):
		_current_level.terrain.queue_free()
	if _current_level.entities and is_instance_valid(_current_level.entities):
		_current_level.entities.queue_free()
	if _current_level.enemies and is_instance_valid(_current_level.enemies):
		_current_level.enemies.queue_free()
	if _current_level.sprites and is_instance_valid(_current_level.sprites):
		_current_level.sprites.queue_free()
	if _current_level.sky and is_instance_valid(_current_level.sky):
		_current_level.sky.queue_free()
	_current_level = null

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: int = event.keycode
	# (Esc/~ inside the pause menu or console are theirs — this node is
	# paused while either is up.)
	if k == KEY_ESCAPE:
		# The in-game menu: the level keeps running underneath, only
		# its MAIN MENU item drops it.
		if _briefing_overlay == null:
			open_pause_menu()
			get_viewport().set_input_as_handled()
	elif Controls.matches(event, "automap"):
		_toggle_automap()
		get_viewport().set_input_as_handled()
	elif GameConsole.is_toggle_key(event) \
			or (k == KEY_BACKSLASH and event.alt_pressed):
		# `~` = the console; Alt+\ = the DOS cheat prompt, same thing.
		open_console()
		get_viewport().set_input_as_handled()
	elif _dm != null:
		return                              # no map hopping / saves in a match
	elif k == KEY_PAGEUP or k == KEY_BRACKETLEFT or k == KEY_P:
		_step_map(-1)
	elif k == KEY_PAGEDOWN or k == KEY_BRACKETRIGHT or k == KEY_N:
		_step_map(+1)
	elif k == KEY_HOME:
		_map_idx = 0
		_load_current()
	elif k == KEY_END:
		_map_idx = _maps.size() - 1
		_load_current()
	elif k == KEY_F6:                       # quicksave (F1-F5 dev, F8/F9 cheats)
		save_to_slot(SaveGame.QUICK_SLOT)
	elif k == KEY_F7:                       # quickload
		load_from_slot(SaveGame.QUICK_SLOT)

## AUTOMAP (the bound key, Tab by default). Pauses the game and shows the
## world from an orbiting camera; see automap.gd.
func _toggle_automap() -> void:
	if _current_level == null or not is_instance_valid(player) or _dm != null:
		return
	if _automap != null and is_instance_valid(_automap) and bool(_automap.get("open")):
		_automap.call("close_map")
		return
	if _briefing_overlay != null or _game_over != null:
		return
	if _automap == null or not is_instance_valid(_automap):
		_automap = preload("res://scripts/automap.gd").new()
		add_child(_automap)
		_automap.connect("closed", func() -> void:
			if is_instance_valid(player) and player.has_method("_capture"):
				player.call("_capture", true))
	_automap.call("show_map", self, _current_level, player, _seen_meshes)

func _step_map(d: int) -> void:
	if _maps.is_empty(): return
	_map_idx = (_map_idx + d + _maps.size()) % _maps.size()
	_load_current()

func _return_to_menu() -> void:
	get_tree().paused = false
	Net.leave()
	get_tree().change_scene_to_file("res://scenes/menu.tscn")

## --- In-game menu, console, cheats -----------------------------------------

func open_pause_menu() -> void:
	if _pause == null or _current_level == null:
		return
	if is_instance_valid(player):
		player.release_mouse()
	_pause.open()

func close_pause_menu() -> void:
	if _pause != null:
		_pause.close()

func open_console(preset: String = "") -> void:
	if _console == null:
		return
	if _pause != null and _pause.is_open:
		_pause.close()
	if is_instance_valid(player):
		player.release_mouse()
	_console.open(preset)

## State the CHEATS page mirrors on its toggle buttons.
func cheat_state() -> Dictionary:
	return {
		"willnotstop": bool(player.get("god_mode")) if is_instance_valid(player) else false,
		"noclip": bool(player.noclip) if is_instance_valid(player) else false,
	}

const HELP_TEXT := """[b]commands[/b]
  help · cheats · version · maps · map <MAP.NNN|nnn> · pos · tp x y z
  god [on|off] · noclip [on|off] · give <all|super|slot|name> · ammo
  health [n] · armor [0-100] · speed [x] · nextlevel · win · enemies
  music [0-100|off|t200|title] · save [slot] · load [slot] · menu · quit"""

const CHEATS_TEXT := """[b]DOS cheat codes[/b] (CHEAT.PRS, typed after Alt+\\ in the original)
  superuzi · arnold (all weapons) · slugs (ammo) · surgery (health+armor)
  willnotstop (immortal) · nitrous (faster) · illbeback (next level)
  showspawns (list enemies) · whoami · version · win"""

## Console / cheat-menu command line. Returns the reply (BBCode ok).
func run_command(line: String) -> String:
	var parts: PackedStringArray = line.strip_edges().split(" ", false)
	if parts.is_empty():
		return ""
	var cmd: String = parts[0].to_lower()
	var args: PackedStringArray = parts.slice(1)
	var p := player if is_instance_valid(player) else null
	match cmd:
		"help", "?":
			return HELP_TEXT
		"cheats":
			return CHEATS_TEXT
		"version", "cversion":
			return "SkyNET Godot port — Godot %s" % Engine.get_version_info().get("string", "?")
		"whoami":
			return "%s — map %s" % [OS.get_environment("USERNAME"), _level_name()]
		"maps":
			return "%d maps: %s" % [_maps.size(), " ".join(_maps)]
		"map":
			if args.is_empty():
				return "current map: %s" % _level_name()
			var want: String = args[0].to_upper()
			if want.is_valid_int():
				want = "MAP.%03d" % int(want)
			var idx: int = _maps.find(want)
			if idx < 0:
				return "no such map: %s" % want
			_map_idx = idx
			_prev_map_name = ""
			_pending_marker_set = -1
			_close_overlays()
			_transition(want)
			return "loading %s" % want
		"pos":
			if p == null:
				return "no player"
			var gp: Vector3 = p.global_position
			return "pos %.0f %.0f %.0f  yaw %.0f  (DOS x=%.0f y=%.0f z=%.0f)" % [gp.x, gp.y, gp.z,
				rad_to_deg(p.rotation.y), gp.x, -gp.y, -gp.z]
		"tp":
			if p == null or args.size() < 3:
				return "usage: tp x y z"
			p.set_spawn(Vector3(float(args[0]), float(args[1]), float(args[2])), p.rotation.y, false)
			return "teleported"
		"god", "willnotstop", "csej":
			if p == null:
				return "no player"
			var on: bool = _bool_arg(args, not bool(p.get("god_mode")))
			p.set("god_mode", on)
			return "god mode %s" % ("ON" if on else "OFF")
		"noclip", "fly":
			if p == null:
				return "no player"
			p.noclip = _bool_arg(args, not p.noclip)
			p.velocity = Vector3.ZERO
			return "noclip %s" % ("ON" if p.noclip else "OFF")
		"arnold", "cskydere":
			if p == null:
				return "no player"
			p.give_all_weapons()
			return "all weapons (%d owned)" % p.owned_list().size()
		"superuzi", "cskyder":
			if p == null:
				return "no player"
			p.give_super_uzi()
			return "SUPER UZI — 9999 rounds"
		"give":
			if p == null:
				return "no player"
			if args.is_empty():
				return "owned: %s" % ", ".join(_weapon_names(p.owned_list()))
			var a: String = args[0].to_lower()
			if a == "all":
				p.give_all_weapons()
				p.give_super_uzi()
				return "every weapon"
			if a == "super" or a == "superuzi":
				p.give_super_uzi()
				return "SUPER UZI"
			if a == "ammo":
				p.fill_ammo()
				return "ammo filled"
			var idx: int = _weapon_index(p, " ".join(args))
			if idx < 0:
				return "unknown weapon '%s' (slot 0-12 or a name)" % " ".join(args)
			p.give_weapon(idx)
			return "%s" % String(p._weapons[idx]["name"])
		"slugs", "ammo", "ckugler":
			if p == null:
				return "no player"
			p.fill_ammo()
			return "all ammo pools full"
		"surgery", "cfalck", "heal":
			if p == null:
				return "no player"
			p.full_health()
			return "health %d, armor 100 %%" % int(p.health)
		"health", "hp":
			if p == null:
				return "no player"
			if not args.is_empty():
				p.health = clampf(float(args[0]), 0.0, p.max_health)
			return "health %d / %d" % [int(p.health), int(p.max_health)]
		"armor":
			if p == null:
				return "no player"
			if not args.is_empty():
				p.armor = clampf(float(args[0]) / 100.0, 0.0, 1.0)
			return "armor %d %%" % int(round(p.armor * 100.0))
		"nitrous", "churtig":
			if p == null:
				return "no player"
			return "speed x%.1f" % p.nitrous()
		"speed":
			if p == null:
				return "no player"
			if not args.is_empty():
				p.speed_boost = clampf(float(args[0]), 0.1, 20.0)
			return "speed x%.1f" % p.speed_boost
		"illbeback", "cbane", "nextlevel":
			var nxt: String = _next_campaign_map()
			if nxt.is_empty():
				return "end of the campaign"
			_close_overlays()
			_advance_to(nxt)
			return "next mission: %s" % nxt
		"boom":
			if not is_instance_valid(player):
				return "no player"
			var ex := Explosion.new()
			add_child(ex)
			ex.setup(player.global_position + Vector3(0, 60, 0) - player.global_transform.basis.z * 420.0, 220.0)
			return "boom"
		"moon":
			if _moon == null:
				return "no moon on this map (dusk missions 5-8 have the dome instead)"
			for _i in MOON_HITS_TO_FALL + 1:
				moon_shot()
			return "moon: %d hits, %s" % [_moon_hits, "falling" if _moon_fall_v > 0.0 else "still up"]
		"shoot":
			# Agent aid: fire the held weapon N times (default 6).
			if not is_instance_valid(player):
				return "no player"
			var n: int = int(args[0]) if args.size() > 0 and args[0].is_valid_int() else 6
			for _i in n:
				player.set("_fire_cd", 0.0)
				player.call("_shoot")
				await get_tree().physics_frame
			return "fired %d" % n
		"weapon":
			if not is_instance_valid(player):
				return "no player"
			var wi: int = int(args[0]) if args.size() > 0 and args[0].is_valid_int() else 1
			player.call("give_weapon", wi)
			player.call("_select_weapon", wi)
			return "weapon %d: %s" % [wi, player.get("weapon_name")]
		"win", "cslut":
			if _current_level == null:
				return "no level"
			_close_overlays()
			_mission_done = true
			_show_mission_complete()
			return "mission complete"
		"showspawns", "cfyr", "enemies":
			var lines: Array = []
			for e in get_tree().get_nodes_in_group("enemy"):
				if e is Node3D and is_instance_valid(e):
					var gp: Vector3 = (e as Node3D).global_position
					lines.append("  %-20s type %3d  at %.0f %.0f %.0f" % [e.name, int(e.get("_type_id")), gp.x, gp.y, gp.z])
			return "%d enemies\n%s" % [lines.size(), "\n".join(lines)]
		"counters", "ctal":
			return "hostiles tracked %d, map state for %d maps, prev map %s" % [
				_mission_hostiles, _map_state.size(), _prev_map_name if not _prev_map_name.is_empty() else "-"]
		"save":
			var slot: int = int(args[0]) - 1 if not args.is_empty() and args[0].is_valid_int() else SaveGame.QUICK_SLOT
			if slot < 0 or slot >= SaveGame.SLOTS:
				return "slot 1-%d" % SaveGame.SLOTS
			return "saved to slot %d" % (slot + 1) if save_to_slot(slot) else "save failed"
		"load":
			var slot: int = int(args[0]) - 1 if not args.is_empty() and args[0].is_valid_int() else SaveGame.QUICK_SLOT
			if slot < 0 or slot >= SaveGame.SLOTS:
				return "slot 1-%d" % SaveGame.SLOTS
			if not SaveGame.exists(slot):
				return "slot %d is empty" % (slot + 1)
			_close_overlays()
			load_from_slot(slot)
			return "loading slot %d" % (slot + 1)
		"music":
			if args.is_empty():
				return "music: %s, volume %d %%" % [Audio.music_name() if not Audio.music_name().is_empty() else "off", int(round(Audio.music_volume * 100.0))]
			var a: String = args[0].to_lower()
			if a == "off" or a == "stop":
				Audio.stop_music()
				return "music stopped"
			if a.is_valid_int():
				Audio.set_music_volume(float(a) / 100.0)
				return "music volume %d %%" % int(round(Audio.music_volume * 100.0))
			if a.begins_with("t") or a == "title":
				var track: String = a.to_upper()
				if not track.ends_with(".HMI"):
					track += ".HMI"
				Audio.play_music(track)
				return "music %s" % (Audio.music_name() if not Audio.music_name().is_empty() else "failed")
			return "usage: music [0-100 | off | t200 | title]"
		"menu":
			_close_overlays()
			_return_to_menu()
			return ""
		"render":
			if args.is_empty():
				return "render: %s (dos | enhanced)" % Render.NAMES[Render.mode]
			var want: int = Render.ENHANCED if args[0].to_lower().begins_with("e") else Render.DOS
			if want == Render.mode:
				return "already %s" % Render.NAMES[want]
			Render.set_mode(want)
			var cur: String = _level_name()
			if not cur.is_empty():
				_close_overlays()
				_transition(cur)
			return "render %s — reloading" % Render.NAMES[want]
		"bots":
			if not Net.is_server():
				return "only the host can change bots"
			if not args.is_empty() and args[0].is_valid_int():
				Net.set_bot_count(int(args[0]))
			return "%d bots" % int(Net.settings.get("bots", 0))
		"class":
			if args.is_empty():
				return "class: %s (human | terminator)" % Net.CLASS_NAMES[Net.local_class]
			var want: String = args[0].to_lower()
			if want.begins_with("h"):
				Net.set_class(Net.CLASS_HUMAN)
			elif want.begins_with("t"):
				Net.set_class(Net.CLASS_TERMINATOR)
			else:
				return "usage: class human|terminator"
			return "%s from the next spawn" % Net.CLASS_NAMES[Net.local_class]
		"players", "who":
			if not Net.active:
				return "not in a network game"
			var rows: Array = []
			for r in Net.scoreboard():
				rows.append("  %-16s %3d frags %3d deaths%s" % [r[1], r[2], r[3], "  (bot)" if r[4] else ""])
			return "%d players\n%s" % [rows.size(), "\n".join(rows)]
		"quit", "exit":
			get_tree().quit()
			return ""
	return "unknown command '%s' — try help" % cmd

## Console and pause menu both go away before a level change.
func _close_overlays() -> void:
	if _console != null and _console.is_open:
		_console.close()
	if _pause != null and _pause.is_open:
		_pause.close()

static func _bool_arg(args: PackedStringArray, fallback: bool) -> bool:
	if args.is_empty():
		return fallback
	var a: String = args[0].to_lower()
	return a in ["on", "1", "true", "yes"]

func _weapon_names(idxs: Array) -> Array:
	var out: Array = []
	for i in idxs:
		if int(i) >= 0 and int(i) < player._weapons.size():
			out.append(String(player._weapons[int(i)]["name"]))
	return out

## Weapon slot from "7", "laser rifle", "shotgun" …
func _weapon_index(p: Node, what: String) -> int:
	what = what.strip_edges().to_lower()
	if what.is_valid_int():
		var i: int = int(what)
		return i if i >= 0 and i < p._weapons.size() else -1
	for i in p._weapons.size():
		if String(p._weapons[i]["name"]).to_lower() == what:
			return i
	for i in p._weapons.size():
		if String(p._weapons[i]["name"]).to_lower().begins_with(what):
			return i
	return -1

func _build_status_ui() -> void:
	# Authentic DOS bitmap fonts: FONT0003 (8×8) for the HUD read-outs,
	# FONT0005 (12×13) for status messages. Loaded once, shared by every
	# read-out Label below.
	_hud_font = _load_fnt("FONT0003.FNT", 3)
	_status_font = _load_fnt("FONT0005.FNT", 2)

	var canvas := CanvasLayer.new()
	canvas.layer = 50
	canvas.name = "HUD"
	add_child(canvas)
	_hud_layer = canvas
	_status_label = Label.new()
	_status_label.position = Vector2(8, 36)
	_status_label.add_theme_color_override("font_color", Color(1, 1, 1))
	# Bitmap fonts carry no outline glyphs — use a 1px drop shadow so the
	# message stays legible over the 3D scene.
	_status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	_status_label.add_theme_constant_override("shadow_offset_x", 2)
	_status_label.add_theme_constant_override("shadow_offset_y", 2)
	if _status_font != null:
		_status_label.add_theme_font_override("font", _status_font)
		_status_label.add_theme_font_size_override("font_size",
			_status_font.fixed_size)
	canvas.add_child(_status_label)

	# --- aiming crosshair ---
	var crosshair: Control = preload("res://scripts/crosshair.gd").new()
	canvas.add_child(crosshair)

	# --- bottom HUD bar: authentic DOS PANEL0.IMG (320×40 foot HUD) ---
	# The art spans the full window width; its height is kept at the
	# original 8:1 aspect (320:40), reproducing the DOS 20%-of-screen bar.
	var panel := TextureRect.new()
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_top = -120.0                    # set precisely by _layout_hud
	panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ptex := _load_panel_texture()
	if ptex != null:
		panel.texture = ptex
		panel.stretch_mode = TextureRect.STRETCH_SCALE
		panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	else:
		var fallback := ColorRect.new()
		fallback.color = Color(0.04, 0.05, 0.07, 0.85)
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.add_child(fallback)
	canvas.add_child(panel)
	_hud_panel = panel

	# HEALTH gauge fill — green bar in the recessed HEALTH slot.
	var hp_slot := _panel_rect(panel, 172, 25, 41, 5)
	_health_fill = ColorRect.new()
	_health_fill.anchor_bottom = 1.0
	_health_fill.anchor_right = 1.0
	_health_fill.color = Color(0.3, 0.85, 0.4)
	_health_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_slot.add_child(_health_fill)

	# Read-outs placed in the panel's recessed boxes.
	_health_label = _hud_box_label()             # numeric health (left box)
	_panel_rect(panel, 3, 20, 39, 17).add_child(_health_label)
	_weapon_label = _hud_box_label()             # active weapon name
	_panel_rect(panel, 50, 20, 83, 17).add_child(_weapon_label)
	_ammo_label = _hud_box_label()               # ammo count
	_panel_rect(panel, 96, 3, 37, 14).add_child(_ammo_label)

	# RADIATION and ARMOR gauges — the two PANEL0 slots the port left
	# empty. Rects measured off the art (320x40).
	var rad_slot := _panel_rect(panel, 50, 5, 41, 10)
	_rad_fill = ColorRect.new()
	_rad_fill.anchor_bottom = 1.0
	_rad_fill.anchor_right = 0.0
	_rad_fill.color = Color(0.95, 0.85, 0.25)
	_rad_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rad_slot.add_child(_rad_fill)
	var armor_slot := _panel_rect(panel, 172, 9, 41, 5)
	_armor_fill = ColorRect.new()
	_armor_fill.anchor_bottom = 1.0
	_armor_fill.anchor_right = 0.0
	_armor_fill.color = Color(0.45, 0.72, 1.0)
	_armor_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	armor_slot.add_child(_armor_fill)

	get_viewport().size_changed.connect(_layout_hud)
	_layout_hud()

	# On-screen MENU button (top-right) — works with mouse and touch.
	var menu_btn := Button.new()
	menu_btn.text = "MENU"
	menu_btn.focus_mode = Control.FOCUS_NONE
	menu_btn.add_theme_font_size_override("font_size", 20)
	menu_btn.anchor_left = 1.0
	menu_btn.anchor_right = 1.0
	menu_btn.offset_left = -132.0
	menu_btn.offset_right = -16.0
	menu_btn.offset_top = 8.0
	menu_btn.offset_bottom = 56.0
	menu_btn.pressed.connect(open_pause_menu)
	canvas.add_child(menu_btn)

## Keep the PANEL0 bar full-width at its native 8:1 aspect (320:40).
func _layout_hud() -> void:
	if _hud_panel == null:
		return
	var vw: float = get_viewport().get_visible_rect().size.x
	# Native 8:1 aspect up to 1280 wide; capped above so the bar never
	# eats more than ~160 px of the view on big screens.
	_hud_panel.offset_top = -clampf(vw / 8.0, 64.0, 160.0)

## Anchor a child Control inside the PANEL0 art by its source-pixel rect
## (PANEL0 is 320×40). Anchors are fractional, so the child tracks the
## stretched panel at any window size.
func _panel_rect(parent: Control, sx: float, sy: float,
		sw: float, sh: float) -> Control:
	var c := Control.new()
	c.anchor_left = sx / 320.0
	c.anchor_right = (sx + sw) / 320.0
	c.anchor_top = sy / 40.0
	c.anchor_bottom = (sy + sh) / 40.0
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c

## A read-out Label that fills its parent panel box.
func _hud_box_label() -> Label:
	var l := Label.new()
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.55, 0.95, 0.62))
	if _hud_font != null:
		l.add_theme_font_override("font", _hud_font)
		l.add_theme_font_size_override("font_size", _hud_font.fixed_size)
	else:
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		l.add_theme_constant_override("outline_size", 3)
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## Load a GAMEDATA FONT00NN.FNT and build a tintable FontFile, or null.
func _load_fnt(filename: String, scale: int) -> FontFile:
	var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path(filename))
	if bytes.is_empty():
		push_warning("HUD font missing: %s" % filename)
		return null
	return FntFont.build(bytes, scale)

## Load PANEL0.IMG (the on-foot HUD bar) as an ImageTexture, or null.
## `name` picks another panel: PANEL1.IMG (jeep cockpit) / PANEL2.IMG
## (HK cockpit) are full 320×200 frames with the windscreen as index 0.
func _load_panel_texture(name: String = "PANEL0.IMG", transparent0: bool = false) -> ImageTexture:
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"),
			SkynetPaths.variant):
		return null
	var pal_bytes := bsa.read("SKYNET.COL")
	if pal_bytes.is_empty():
		pal_bytes = bsa.read("BRIEF.COL")
	var panel_bytes := bsa.read(name)
	bsa.close()
	var palette := Palette.parse(pal_bytes)
	if palette.is_empty() or panel_bytes.is_empty():
		return null
	return ImgFile.parse(panel_bytes, palette, transparent0)

## --- Vehicle cockpit HUD (DOS mode 4 = PANEL1 jeep, 8 = PANEL2 HK) -----
## The cockpit art fills the screen (320×200 stretched); the green
## read-outs sit in its right-hand block. Rects in image pixels.
const VEH_PANELS: Array = ["", "PANEL1.IMG", "PANEL2.IMG"]
const VEH_READOUTS: Dictionary = {
	1: {"energy": Rect2(207, 151, 38, 9), "armor": Rect2(207, 160, 38, 9), "damage": Rect2(207, 169, 38, 9)},
	2: {"missiles": Rect2(207, 141, 38, 9), "energy": Rect2(207, 151, 38, 9), "armor": Rect2(207, 160, 38, 9), "damage": Rect2(207, 169, 38, 9)},
}
var _veh_layer: CanvasLayer = null
var _veh_panel: TextureRect = null
var _veh_labels: Dictionary = {}
var _hud_mode: int = 0

## Swap the HUD between the foot bar and a vehicle cockpit.
func _set_hud_mode(v: int) -> void:
	_hud_mode = v
	if _hud_panel != null:
		_hud_panel.visible = v == 0
	if _veh_layer == null:
		_veh_layer = CanvasLayer.new()
		_veh_layer.layer = 49
		add_child(_veh_layer)
		_veh_panel = TextureRect.new()
		_veh_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_veh_panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_veh_panel.stretch_mode = TextureRect.STRETCH_SCALE
		_veh_panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_veh_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_veh_layer.add_child(_veh_panel)
	for l in _veh_labels.values():
		(l as Node).queue_free()
	_veh_labels.clear()
	if v <= 0 or v >= VEH_PANELS.size():
		_veh_layer.visible = false
		return
	_veh_panel.texture = _load_panel_texture(String(VEH_PANELS[v]), true)
	_veh_layer.visible = _veh_panel.texture != null
	for key in VEH_READOUTS[v]:
		var l := _hud_box_label()
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_br_anchor(l, VEH_READOUTS[v][key])
		_veh_panel.add_child(l)
		_veh_labels[key] = l

## Cockpit read-outs: MISSILES (pool 11), ENERGY (pool 10), ARMOR %,
## DAMAGE % (100 - health).
func _update_vehicle_hud() -> void:
	if _veh_labels.is_empty() or not is_instance_valid(player):
		return
	if _veh_labels.has("missiles"):
		_veh_labels["missiles"].text = "%d" % player.pool_count(11)
	if _veh_labels.has("energy"):
		_veh_labels["energy"].text = "%d" % player.pool_count(10)
	if _veh_labels.has("armor"):
		_veh_labels["armor"].text = "%d" % int(round(player.armor * 100.0))
	if _veh_labels.has("damage"):
		var frac: float = 1.0 - clampf(player.health / maxf(player.max_health, 1.0), 0.0, 1.0)
		_veh_labels["damage"].text = "%d" % int(round(frac * 100.0))

## Transient status line (loading, saved/loaded, errors). It clears
## itself after `ttl` seconds — the HUD carries no permanent debug text.
var _status_serial: int = 0
func _set_status(text: String, ttl: float = 4.0) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_serial += 1
	if text.is_empty() or ttl <= 0.0:
		return
	var my: int = _status_serial
	get_tree().create_timer(ttl, true, false, true).timeout.connect(func() -> void:
		if _status_serial == my and _status_label != null:
			_status_label.text = "")
