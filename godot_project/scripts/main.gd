## Main scene controller. Browses MAP.* in MDMDMAP2.BSA and loads a level
## via LevelLoader.
##
## Key bindings (in addition to the global F1..F5 scene switch):
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
const EnemyRef := preload("res://scripts/enemy.gd")
const PauseMenu   := preload("res://scripts/pause_menu.gd")
const DmGame      := preload("res://scripts/net/dm_game.gd")
const WldTerrain  := preload("res://scripts/loaders/wld_terrain.gd")
const LevelScene  := preload("res://scripts/level_scene.gd")
const LevelBehaviour := preload("res://scripts/level_behaviour.gd")
const Rules       := preload("res://scripts/triggers/rules_skynet.gd")
const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")
const CamPath     := preload("res://scripts/cam_path.gd")
const PauseState  := preload("res://scripts/pause_state.gd")
const HudPanel    := preload("res://scripts/hud_panel.gd")
const HudModern   := preload("res://scripts/hud_modern.gd")
const EffectWarmup := preload("res://scripts/effect_warmup.gd")
const StatsLib := preload("res://scripts/stats.gd")
const ZoneLayers := preload("res://scripts/mission/zone_layers.gd")

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
## Terminator: Future Shock — mission n starts on MAP.0n0 (briefings
## 010.TXT…190.TXT in its MDMDBRIF.BSA); shock.exe keeps no map table
## like Skynet.exe's 0x34846 (searched 2026-09-06).
const CAMPAIGN_SEQUENCE_SHOCK: Array = [
	"MAP.010", "MAP.020", "MAP.030", "MAP.040", "MAP.050", "MAP.060", "MAP.070",
	"MAP.080", "MAP.090", "MAP.100", "MAP.110", "MAP.120", "MAP.130", "MAP.140",
	"MAP.150", "MAP.160", "MAP.170", "MAP.180", "MAP.190",
]

static func _campaign_sequence() -> Array:
	return CAMPAIGN_SEQUENCE_SHOCK if SkynetPaths.game == "shock" else CAMPAIGN_SEQUENCE

## The first mission's map number in this game's numbering.
static func _mission_base() -> int:
	return 10 if SkynetPaths.game == "shock" else 200

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D = $Player/Camera3D
@onready var sun: DirectionalLight3D = $Sun

var _maps: Array[String] = []
var _map_idx: int = 0
var _current_level: LevelLoader.Level = null
var _status_label: Label = null
## The HUD bar: the DOS panel (scripts/hud_panel.gd, PANEL0 and all DOS
## draws on it) or, with HI-RES ART on, the modern status bar
## (scripts/hud_modern.gd). Both take the same refresh() every frame.
var _hud: Control = null
var _hud_is_dos: bool = true
## The compass bearing (both HUDs): the 11-bit clockwise bearing from the
## map's north, view yaw + the marker-7 offset (DOS FUN_001323a2,
## (degrees << 11) / 360 at 0x12df3f).
var _compass_north: int = 0            # marker 7, in 11-bit units
var _compass_level: WeakRef = null
var _hud_layer: CanvasLayer = null     # the whole gameplay HUD
## AUTOMAP (Tab): the paused 3D map view, and the set of entity nodes the
## player has actually seen — DOS marks flag 0x80 on everything it drew
## and the automap shows only those (fog of war).
var _automap: Node3D = null
var _seen_meshes: Dictionary = {}
var _seen_poll: float = 0.0
var _hud_font: FontFile = null         # FONT0003.FNT — HUD read-outs
## The message line's font: FONT0004 at the panel's scale under the DOS
## HUD (FUN_0012f453: (4,3), palette 0xB3 over a 0x7F shadow), FONT0005
## with the modern one. `_msg_scale` is the scale it was built at (0 =
## FONT0005).
var _status_font: FontFile = null
var _msg_scale: int = -1
var _game_over: CanvasLayer = null
var _mission_hostiles: int = 0
var _mission_done: bool = false
## Command-line switches after `--` (see _parse_cli): --map=, --pos=x,y,z,
## --yaw=deg, --pitch=deg, --noclip, --no-briefing, --screenshot=PATH,
## --shot-delay=sec, --quit-after-shot — the agent/automation interface.
## --no-mission-scene / --mission-scene override Settings.mission_scenes for
## one run (_mission_scenes_on).
var _cli: Dictionary = {}
var _campaign_maps: Array[String] = []   # ordered mission "main" maps
var _mission_start_map: String = ""      # the campaign map the mission began on
## The player exactly as the mission began — DOS's mission-start snapshot
## (FUN_0011d346 takes it, FUN_0011d3b0 puts it back: damage, armour, the
## thirteen ammo pools, the twenty-six per-weapon counts and BOTH weapon
## selections). RESTART MISSION replays from this, never from what the
## attempt that failed left behind. `_mission_start_snap_key` is the
## mission it was taken for, so walking back into the mission's own first
## map — mission 1 returns to MAP.210 from every one of its interiors —
## does not overwrite it with a half-spent kit.
var _mission_start_state: Dictionary = {}
var _mission_start_snap_key: int = -1
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
## Every level change runs through _change_level, one at a time: two at
## once (an exit fired during another's fade, F7 during an exit) tore the
## level down twice, and a save taken mid-change stored the exit as used.
## `_level_gen` counts the changes; a coroutine that waited (the
## mission-complete delay) checks it before acting on a level that is gone.
var _level_busy: bool = false
var _level_gen: int = 0
## Player snapshot from a save file, applied at the end of _begin_level.
var _pending_player: Dictionary = {}
## A loaded save's mission counters (Stats), laid over the mission script.
var _pending_stats: Dictionary = {}
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
	_watch_settings()
	_console = GameConsole.new()
	_console.handler = self
	add_child(_console)
	_console.closed.connect(_refresh_net_input_lock)
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
	for m in _campaign_sequence():
		if _maps.has(m):
			_campaign_maps.append(m)
	print("[skynet] campaign: %d missions" % _campaign_maps.size())

	_map_idx = _maps.find(initial_map)
	if _map_idx < 0: _map_idx = 0
	# A slot picked in the LOAD menu replaces the normal start — when it
	# reads and its map exists. A damaged or foreign save used to leave an
	# empty black scene; it now starts the game normally and says why.
	var slot: int = SkynetPaths.pending_load_slot
	SkynetPaths.pending_load_slot = -1
	var saved: Dictionary = SaveGame.read(slot) if slot >= 0 else {}
	if not saved.is_empty() and _maps.has(String(saved.get("map", ""))):
		load_from_slot(slot, saved)
	else:
		if slot >= 0:
			var why: String = SaveGame.last_error
			if why.is_empty():
				why = "empty slot" if saved.is_empty() else "saved map %s is missing" % String(saved.get("map", "?"))
			push_warning("[skynet] slot %d did not load (%s) — normal start" % [slot + 1, why])
		_load_current()

func _exit_tree() -> void:
	_unwatch_settings()
	# Leaving the game scene (main menu, a dev scene switch): nothing may
	# stay paused or hold the mouse — and no mission scene's layers may
	# outlive it into the next game (a deathmatch plays on bit 1).
	PauseState.reset()
	ZoneLayers.reset()

## Does this mesh already carry a collision body? Static geometry comes
## out of the baked level scene with one (and the loader gives the rest
## of it one too), so the per-entity trimesh build here is only for the
## movers and destructibles it built by hand.
static func _has_collision(mi: Node) -> bool:
	for c in mi.get_children():
		if c is CollisionObject3D:
			return true
	return false

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
	if level.behaviour != null and mi.has_method("file_off") \
			and level.behaviour.has_mover(mi.file_off()):
		return false
	var s: Vector3 = mi.mesh.get_aabb().size
	# Flat pieces (floor tiles, wall panels, ramps) are level geometry,
	# not props — and a zero-thickness box would not collide at all.
	if minf(s.x, minf(s.y, s.z)) < PROP_BOX_MIN_THICKNESS:
		return false
	return maxf(s.x, maxf(s.y, s.z)) <= PROP_BOX_MAX

## The DOS-style solid box of a mover leaf or a prop — the same box the
## bake gives a Mover (scripts/level_behaviour.gd).
static func _make_box_collision(mi: MeshInstance3D) -> void:
	var box: Dictionary = LevelBehaviour.box_shape(mi.mesh)
	var sb := StaticBody3D.new()
	sb.name = mi.name + "_col"
	var cs := CollisionShape3D.new()
	cs.shape = box["shape"]
	cs.position = box["centre"]
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

## wallmap x0,z0,x1,z1,step,y: where a player capsule fits at height y —
## the question a ray cannot answer (a wall is invisible to a downward
## ray whose start is below its top). '.' free, '#' blocked, '?' no
## physics world.
func _wallmap(spec: String) -> void:
	var v: PackedStringArray = spec.split(",")
	if v.size() < 6:
		print("[wallmap] need x0,z0,x1,z1,step,y")
		return
	var x0 := int(v[0]); var z0 := int(v[1]); var x1 := int(v[2])
	var z1 := int(v[3]); var step := maxi(int(v[4]), 1); var y := float(v[5])
	var space := get_world_3d().direct_space_state
	if space == null:
		print("[wallmap] no physics world")
		return
	var shape := CapsuleShape3D.new()
	shape.radius = float(v[6]) if v.size() > 6 else 22.0
	shape.height = 80.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.collision_mask = ZoneLayers.world_mask()
	q.shape = shape
	if is_instance_valid(player) and player is CollisionObject3D:
		q.exclude = [(player as CollisionObject3D).get_rid()]
	print("[wallmap] x %d..%d z %d..%d step %d at y %.0f (rows = z, columns = x); '.' fits, '#' blocked"
		% [x0, x1, z0, z1, step, y])
	var z := z0
	while z <= z1:
		var line := ""
		var x := x0
		while x <= x1:
			q.transform = Transform3D(Basis(), Vector3(float(x), y + 40.0, float(z)))
			line += "#" if not space.intersect_shape(q, 1).is_empty() else "."
			x += step
		print("  %6d %s" % [z, line])
		z += step

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
				cq.collision_mask = ZoneLayers.world_mask()
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
				q.collision_mask = ZoneLayers.world_mask()
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
				q.collision_mask = ZoneLayers.world_mask()
				q.hit_back_faces = true
				if not space.intersect_ray(q).is_empty():
					hit = true
					break
			row += "#" if hit else "."
			a += step
		print("%6d %s" % [y, row])
		y -= step

## Drive the scripted camera one frame. With --write-movie the delta is
## exactly 1/fps, so the same path renders to the same frames every time.
## The run quits when the path ends, which closes the movie file.
func _campath_step(delta: float) -> void:
	if _campath == null or _campath_t < 0.0 or not is_instance_valid(player):
		return
	var t0: float = _campath_t
	_campath_t += delta
	var p: Dictionary = _campath.call("pose", _campath_t)
	if p.is_empty():
		return
	player.global_position = (p["pos"] as Vector3) - Vector3(0.0, EYE_HEIGHT, 0.0)
	player.velocity = Vector3.ZERO
	player.set_view(float(p["yaw"]), float(p["pitch"]))
	for _i in (_campath.call("events", t0, _campath_t) as Array):
		player.call("_shoot")
	if _campath_t > float(_campath.call("duration")) + 0.25:
		print("[campath] done at %.2f s" % _campath_t)
		_campath = null
		get_tree().quit()

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
		# The soldier walks at the DOS 250 u/s (fly_camera.walk_speed), so a
		# route takes about 2.4x as long as it did at the port's old 600 —
		# the default window was raised to match (2026-09-16).
		_walk_limit = 30.0
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
		_walk_best = 1e9
		print("[walk] start at %s toward %s for %.1f s" % [player.global_position, _walk_target, _walk_limit])
	if _cli.has("yaw") or _cli.has("pitch"):
		var yaw := deg_to_rad(float(_cli.get("yaw", rad_to_deg(player.rotation.y))))
		var pitch := deg_to_rad(float(_cli.get("pitch", 0.0)))
		player.set_view(yaw, pitch)
	# --campath=FILE|auto:...: fly the camera along a scripted path, for a
	# RECORDED promo clip (see scripts/cam_path.gd). Godot's own Movie Maker
	# turns real-time sync off, so nobody can play along while it records
	# — the camera has to be driven, and driving it also means the shot
	# comes out the same after every change to the game.
	if _cli.has("campath") and _campath == null:
		var cp: RefCounted = CamPath.new()
		if cp.call("load_spec", String(_cli["campath"])):
			_campath = cp
			_campath_t = 0.0
			player.noclip = true
			player.velocity = Vector3.ZERO
			player.set("input_locked", true)
			cp.call("resolve_auto", player.global_position + Vector3(0.0, EYE_HEIGHT, 0.0),
				player.rotation.y, 0.0)
			print("[campath] %.1f s, %d keys" % [cp.call("duration"), (cp.get("keys") as Array).size()])

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
	if _cli.has("player-radius"):
		# Agent aid: a thinner or wider player body, to measure what the
		# levels were built for (--solve reads this same shape).
		var pcs: CollisionShape3D = player.get_node_or_null("CollisionShape3D")
		if pcs != null and pcs.shape is CapsuleShape3D:
			(pcs.shape as CapsuleShape3D).radius = float(_cli["player-radius"])
			print("[cli] player capsule radius %.0f" % (pcs.shape as CapsuleShape3D).radius)
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
		# "group:N:dist" stands that far off instead.
		var dist: float = float(parts[2]) if parts.size() > 2 else 260.0
		if ni < nodes.size() and nodes[ni] is Node3D:
			var tgt: Vector3 = (nodes[ni] as Node3D).global_position
			var eye: Vector3 = tgt + Vector3(-dist, dist * 0.46, 0.0)
			_cli["pos"] = "%f,%f,%f" % [eye.x, eye.y, eye.z]
			var d: Vector3 = tgt + Vector3(0.0, 30.0, 0.0) - eye
			_cli["yaw"] = str(rad_to_deg(atan2(-d.x, -d.z)))
			_cli["pitch"] = str(rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length())))
			print("[cli] near %s #%d at %s" % [parts[0], ni, tgt])
		else:
			print("[cli] near: no node %s #%d" % [parts[0], ni])
	_cli_place()
	# The console runs AFTER --pos/--near have placed the player: a
	# `tp`/`shoot`/`use` script fired from the map's start point
	# otherwise (2026-09-08).
	if _cli.has("console"):
		# Automation: run console commands once the FIRST level is up
		# (`--console=win;next`), each reply goes to the log. Commands for
		# a later map go in --console-<suffix>= (e.g. --console-013=tp …;use),
		# run when that map comes up.
		var cmds: String = String(_cli["console"])
		_cli.erase("console")
		for c in cmds.split(";"):
			if not c.strip_edges().is_empty():
				print("[cli] ] %s → %s" % [c.strip_edges(), await run_command(c.strip_edges())])
	var per_map: String = "console-" + (_current_level.map_suffix if _current_level != null else "")
	if _cli.has(per_map):
		var cmds2: String = String(_cli[per_map])
		_cli.erase(per_map)
		for c in cmds2.split(";"):
			if not c.strip_edges().is_empty():
				print("[cli] ] %s → %s" % [c.strip_edges(), await run_command(c.strip_edges())])
	_solver_level_ready()
	_verifier_level_ready()
	_mission_runner_level_ready()
	if _cli.has("console-open"):
		# Automation: drop the console itself (a screenshot of its UI).
		open_console(String(_cli["console-open"]))
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
	elif _cli.has("perf"):
		# --perf[=secs]: stand still and measure the FRAME TIMES, because
		# "it stutters" is about the worst frames, not the average.
		await _perf_probe(float(_cli.get("perf", 8.0)))
		if _cli.has("quit-after-shot"):
			get_tree().quit()

## --solve: the mission solver is told that a world is up and playable
## (scripts/mission_solver.gd, which then floods it, fires what it can and
## takes an exit). It is told once per PLACE, whichever runtime brought it
## up: after a level change, and — inside a mission scene, where a doorway
## is no longer a level change — after a move into another zone and after a
## world has been re-authored into a phase.
func _solver_level_ready() -> void:
	if not _cli.has("solve"):
		return
	var solver: Node = get_node_or_null("MissionSolver")
	if solver == null:
		solver = load("res://scripts/mission_solver.gd").new()
		solver.name = "MissionSolver"
		solver.set("main", self)
		add_child(solver)
	solver.call("level_ready")

## --verify-triggers=all|mission:210|maps:215,217|changed: the trigger
## verifier is told that a world is up (scripts/triggers/trigger_verifier.gd,
## M3 step 4). Unlike the solver it drives every further level change
## itself, so this only ever starts it — the first world it is given is
## the one it begins on, and `begin` ignores every later call.
func _verifier_level_ready() -> void:
	if not _cli.has("verify-triggers"):
		return
	var v: Node = get_node_or_null("TriggerVerifier")
	if v != null:
		return
	v = load("res://scripts/triggers/trigger_verifier.gd").new()
	v.name = "TriggerVerifier"
	v.set("main", self)
	add_child(v)
	v.call("begin")

## --verify-missions=all|210,240: the mission spec runner
## (scripts/triggers/mission_verifier.gd, M3 step 6) — layer (b), which
## plays tests/rules/skynet.missions.txt across the maps of each mission.
## Like the verifier it drives its own level changes, so this only starts
## it; the first world it is given is the one it begins on.
func _mission_runner_level_ready() -> void:
	if not _cli.has("verify-missions"):
		return
	if get_node_or_null("MissionVerifier") != null:
		return
	var m: Node = load("res://scripts/triggers/mission_verifier.gd").new()
	m.name = "MissionVerifier"
	m.set("main", self)
	add_child(m)
	m.call("begin_missions")

## Frame-time probe. Prints the distribution, not just the average: a
## mean of 8 ms with a 90 ms worst frame is exactly what "docela dost to
## sekalo" feels like, and an average hides it.
func _perf_probe(secs: float) -> void:
	# Uncapped, or every number is just the vsync interval.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().create_timer(1.0, true, false, true).timeout   # let the level settle
	var ms: PackedFloat32Array = PackedFloat32Array()
	var spikes: Array = []
	var t0: int = Time.get_ticks_msec()
	var t_end: int = t0 + int(secs * 1000.0)
	var last: int = Time.get_ticks_usec()
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		var now: int = Time.get_ticks_usec()
		var dt: float = float(now - last) / 1000.0
		ms.append(dt)
		if dt > 20.0 and spikes.size() < 24:
			spikes.append("%.2fs:%.0fms" % [float(Time.get_ticks_msec() - t0) / 1000.0, dt])
		last = now
	if ms.size() < 8:
		print("[perf] too few frames")
		return
	var arr: Array = Array(ms)
	arr.sort()
	var sum: float = 0.0
	for v in arr:
		sum += v
	var over_33: int = 0
	for v in arr:
		if v > 33.3:
			over_33 += 1
	@warning_ignore("integer_division")
	print("[perf] %s: %d frames | mean %.1f ms (%.0f fps) | median %.1f | 95th %.1f | 99th %.1f | worst %.1f | %d frames over 33 ms (%.1f%%)"
		% [_level_name(), arr.size(),
		   sum / float(arr.size()), 1000.0 / (sum / float(arr.size())),
		   float(arr[arr.size() / 2]), float(arr[int(arr.size() * 0.95)]),
		   float(arr[int(arr.size() * 0.99)]), float(arr[arr.size() - 1]),
		   over_33, 100.0 * float(over_33) / float(arr.size())])
	if not spikes.is_empty():
		print("[perf]   spikes over 20 ms at %s" % " ".join(spikes))
	print("[perf]   process %.2f ms, physics %.2f ms (of the frame) | %s" % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		ProjectSettings.get_setting("physics/3d/physics_engine", "?")])
	print("[perf]   draw calls %d, primitives %d, video mem %.0f MB, objects %d" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)])

func _scan_maps() -> void:
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		push_error("[skynet] cannot open %s to enumerate maps" % SkynetPaths.map_archive)
		return
	for e in bsa.entries():
		var nm: String = e.name.to_upper()
		# Future Shock's archive also holds MAP.JTE and MAP.TXT — text,
		# not levels. A map's suffix is a number.
		if nm.begins_with("MAP.") and nm.split(".")[-1].is_valid_int():
			_maps.append(nm)
	bsa.close()
	_maps.sort_custom(func(a, b): return _suffix(a) < _suffix(b))
	print("[skynet] %d maps available: %s..%s"
		% [_maps.size(),
		   _maps[0] if _maps.size() > 0 else "(none)",
		   _maps[_maps.size() - 1] if _maps.size() > 0 else "(none)"])

static func _suffix(nm: String) -> int:
	var parts := nm.split(".")
	if parts.size() < 2: return -1
	return int(parts[1])

func _load_current() -> void:
	if _map_idx < 0 or _map_idx >= _maps.size():
		_clear_level()
		_mission_done = false               # (raised for a change that is not coming)
		_set_status("No map at index %d" % _map_idx)
		return
	var nm := _maps[_map_idx]
	# Mission "main" maps open with the briefing screen; the level itself
	# loads only when the player presses BEGIN. Other maps load directly.
	# Automation runs (screenshots) skip the briefing.
	# A scripted camera run has nobody to press a key on the briefing, and
	# with --write-movie it would record that screen until the disk filled
	# (it recorded 912 MB of it before I noticed), so --campath skips it
	# like --screenshot does.
	var no_briefing: bool = (_cli.has("screenshot") and not _cli.has("tab")) \
		or _cli.has("no-briefing") or _cli.has("campath") or _cli.has("walk") or Net.active
	if not await _change_level(nm, false, not no_briefing):
		return
	if _briefing_overlay != null and _cli.has("screenshot"):
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
## Loose furniture the player walks past, not into. A chair is 30 × 51
## × 24 units; MAP.252's cabin has three, and with the exact trimesh of
## every mesh they seal the room mission 5 starts in at EVERY body width
## the --solve sweep tried (radius 26 down to 14) — the only way out was
## to shoot the chairs ("nedá sa ani vyjsť z kajuty"). Such pieces keep
## their collider — bullets, grenades and the crosshair still hit them,
## so a chair can still be shot to bits — but on FURNITURE_LAYER, which
## the player's body (collision_mask 1) does not collide with. Movers
## (doors, lifts) never qualify.
const FURNITURE_LAYER: int = 1 << 4
const FURNITURE_MAX_SIDE: float = 48.0
const FURNITURE_MAX_HEIGHT: float = 80.0

func _unblock_furniture(level: LevelLoader.Level) -> void:
	if level.entities == null:
		return
	var n: int = 0
	for c in level.entities.get_children():
		if not (c is MeshInstance3D) or (c as MeshInstance3D).mesh == null:
			continue
		if level.behaviour != null and c.has_method("file_off") \
				and level.behaviour.has_mover(c.file_off()):
			continue
		var sz: Vector3 = (c as MeshInstance3D).mesh.get_aabb().size
		if maxf(sz.x, sz.z) > FURNITURE_MAX_SIDE or sz.y > FURNITURE_MAX_HEIGHT:
			continue
		for b in c.get_children():
			if b is StaticBody3D:
				(b as StaticBody3D).collision_layer = FURNITURE_LAYER
				n += 1
	if n > 0:
		print("[level] %d small props made walk-through" % n)

## The shared collision-shape cache key of an entity mesh: the MAP mesh
## name — the ActionTarget's "mesh_name" meta, or the name of the cached
## mesh resource it shows (converted/mesh/<NAME>.res). "" when neither is
## known: a plain mesh that shares its name with a sibling (the sealed
## truck doors) is renamed "@MeshInstance3D@N" by the tree, a key the
## cache refuses with an error per door — and a node name like that says
## nothing about the mesh, so such a mesh builds its own shape.
static func _shape_key(mi: MeshInstance3D) -> String:
	var key: String = String(mi.get_meta("mesh_name", ""))
	if key.is_empty() and mi.mesh != null:
		var rp: String = mi.mesh.resource_path
		if rp.get_extension() == "res" and rp.get_base_dir().get_file() == "mesh":
			key = rp.get_file().get_basename()
	return Assets.safe_key(key) if not key.is_empty() else ""

## Only _change_level calls this (one level change at a time).
func _begin_level(nm: String) -> void:
	var gen: int = _level_gen
	# The session cache lets go of what neither this map nor the last used.
	Assets.level_started()
	print("[skynet] loading %s" % nm)
	_ensure_mission_script(nm)
	await get_tree().process_frame
	if gen != _level_gen:
		return
	# MISSION SCENES (Settings.mission_scenes, on by default): the whole
	# mission comes up as one scene and this map is one zone of it. Falls
	# back to the per-map path below when the mission has no baked scene or
	# this map is not one of its zones (a phase variant, a hand-over), and
	# `--no-mission-scene` sends the whole run down it.
	if _want_mission_scene(nm):
		var in_scene: bool = await _begin_mission_level(nm, gen)
		if in_scene:
			return
	# The phases a loaded save named are a mission scene's business; the
	# per-map runtime reads the variant from the map it loads.
	_pending_zone_phases = {}

	var loader := LevelLoader.new()
	var level := loader.load_level(nm)
	if level == null:
		push_error("[skynet] failed to load %s" % nm)
		push_error("[skynet] [%d/%d] %s -- LOAD FAILED"
			% [_map_idx + 1, _maps.size(), nm])
		return
	_current_level = level
	if level.terrain:
		add_child(level.terrain)
		if not _has_collision(level.terrain):
			level.terrain.create_trimesh_collision()   # walkable ground
			_enable_backfaces(level.terrain)
	if level.entities:
		_bake_entity_collision(level)
		add_child(level.entities)
		_unblock_furniture(level)
		if _cli.has("spawn-probe"):
			var outside: int = 0
			for c in level.entities.get_children():
				if c is Node3D and not (c as Node3D).is_inside_tree():
					outside += 1
			print("[spawn-probe] entities: %d children, %d outside the tree" % [level.entities.get_child_count(), outside])
	# Re-apply this map's state overlay when we have been here before —
	# BEFORE the Behaviour branch enters the tree: a cue armed in the MAP
	# data fires in its _ready, and one that fired on an earlier visit (or
	# before the save) must find its bit down and its act retired, or the
	# radio line plays and the objective counts again.
	_apply_map_state(level, nm)
	# The Behaviour branch (scripts/level/behaviour.gd): the chains and
	# the cues. Signals first — a cue armed in the MAP data fires in its
	# _ready, the moment it enters the tree.
	if level.behaviour != null:
		_connect_behaviour(level)
		add_child(level.behaviour)
	_connect_level(level)
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
	_set_sky_fill(level, nm)
	_light_level(level)

	# Let the freshly-added trimesh collision register in the physics
	# space before the spawn-clearance query runs.
	await get_tree().physics_frame
	if gen != _level_gen:
		return
	_settle_sprites(level)
	_frame_camera(level)
	# Gates/doorways the spawn already sits in must be left before they
	# can fire again — return exits drop the player right beside the
	# gate they came through.
	if level.behaviour != null and is_instance_valid(player):
		level.behaviour.arm_proximity(player.global_position, _eye_position())
	# (The automation switches — _cli_after_level — run once _change_level
	# has finished: a scripted `use` that takes an exit is a level change
	# of its own.)

	# Ambient bed — wind for outdoor maps.
	if level.is_outdoor:
		Audio.play_ambient("AMB_WIND.RAW")
	else:
		Audio.stop_ambient()
	# Score: the maptype marker (type 6, sub+2) picks the HMI track.
	Audio.play_music_for_maptype(_maptype(level))
	_set_status("")
	print("[skynet] %s ready (%d/%d, %s, %d meshes, %d enemies)"
		% [nm, _map_idx + 1, _maps.size(),
		   "outdoor" if level.is_outdoor else "indoor",
		   level.entity_count, level.enemy_count])
	_level_ready_tail(level, nm)

## Every entity mesh gets its collision before the subtree enters the
## physics space, so the flags (backface_collision) are registered from
## the first step — the deck terminator's first snap otherwise only found
## the roof.
func _bake_entity_collision(level: LevelLoader.Level) -> void:
	if level.entities == null:
		return
	for c in level.entities.get_children():
		# Every entity mesh gets a trimesh StaticBody child — for movers
		# (doors/gates/lifts) it is a child of the moving node, so the
		# collision follows the action-system motion.
		if not (c is MeshInstance3D):
			continue
		# Static geometry arrives with its collision already on it — one
		# shared shape per mesh, out of the converted cache
		# (scripts/level_scene.gd).
		if _has_collision(c):
			continue
		# A door that can never open (a flat DOOR leaf with no action,
		# LevelLoader._sealed_door) stays without a collider here too:
		# the loader leaves it out so the route behind stays open, and
		# this pass gave it one back — MAP.210's DOOR01 across the
		# cargo box kept the truck shut (playtest 2026-09-15).
		if not c.has_method("file_off"):
			var mesh_name: String = String(c.get_meta("mesh_name", ""))
			if mesh_name.is_empty() and c.mesh != null:
				mesh_name = c.mesh.resource_path.get_file().get_basename()
			if LevelLoader._sealed_door(mesh_name, c.mesh):
				continue
		# Doors, gates and lifts collide as their AABB box, like every DOS
		# object: the BIGDOOR leaf is a braced frame whose trimesh has
		# holes a player capsule slips through (closed!) and thin edges to
		# wedge on.
		var solid_mover: bool = (level.behaviour != null and c.has_method("file_off")
			and level.behaviour.is_solid_mover(c.file_off()) and LevelBehaviour.is_door_like(c.mesh))
		if solid_mover or _is_small_prop(c, level):
			_make_box_collision(c)          # DOS-style solid box
		else:
			# (The shared, cached shape — backface_collision already on —
			# is the normal case; a mesh with no cache name gets its own.)
			var shape_key: String = _shape_key(c)
			if shape_key.is_empty() or not LevelScene.add_collision(c, shape_key):
				c.create_trimesh_collision()    # walls, buildings, bridges
				_enable_backfaces(c)
		# A moving StaticBody does not push the player — a closing gate
		# would leave them wedged inside the leaf. Movers get an
		# AnimatableBody3D (sync_to_physics) instead.
		if level.behaviour != null and c.has_method("file_off") \
				and level.behaviour.has_mover(c.file_off()):
			_make_animatable(c)

## The mission-script signals of a level's Behaviour branch. Each level
## brings a branch of its own, so this connects once per level — and once
## per ZONE with a mission scene up, where several branches are alive at
## the same time and all of them report to the one mission.
func _connect_behaviour(level: LevelLoader.Level) -> void:
	if level.behaviour == null:
		return
	if not level.behaviour.objective_complete.is_connected(_on_objective_complete):
		level.behaviour.objective_complete.connect(_on_objective_complete)
		level.behaviour.hint_message.connect(_on_hint_message)
		level.behaviour.mission_failed.connect(_on_mission_failed)
		# …and the water the branch's 0xd6-0xda movers ask for (step 5d),
		# and what a destroyed object drops (step 5g — ObjHit and the
		# destruction that follows it are the branch's).
		level.behaviour.water_level.connect(_on_water_level)
		level.behaviour.item_dropped.connect(_on_drop_requested)

## The map change a level asks for, the references its branch needs, and
## the player's own signals (connected once, whatever the level).
func _connect_level(level: LevelLoader.Level) -> void:
	if level.behaviour == null:
		return
	if not level.behaviour.teleport_requested.is_connected(_on_teleport_requested):
		level.behaviour.teleport_requested.connect(_on_teleport_requested)
	level.behaviour.space = get_world_3d().direct_space_state
	level.behaviour.player_body = player
	level.behaviour.objectives_left = _objectives_left
	if not player.pickup_message.is_connected(_set_status):
		player.pickup_message.connect(_set_status)
	if not player.use_pressed.is_connected(_on_use_pressed):
		player.use_pressed.connect(_on_use_pressed)
	if not player.activate_key.is_connected(_on_activate_key):
		player.activate_key.connect(_on_activate_key)
	if not player.secondary_changed.is_connected(_on_secondary_changed):
		player.secondary_changed.connect(_on_secondary_changed)
	if not player.hurt.is_connected(_on_hurt):
		player.hurt.connect(_on_hurt)

## What a level that has just come up needs told, whichever runtime
## brought it up: the hostile count, the mission it belongs to, the
## player's vehicle and border boxes, the radiation sources, the water and
## the scenery. A mission scene runs this for every zone walked into.
func _level_ready_tail(level: LevelLoader.Level, nm: String) -> void:
	# Hostile count for the HUD/tests — only the mission's main map
	# tracks it; the interiors reached through exits are side areas of
	# the same mission. Missions end at the evacuation zone, never here.
	_mission_done = false
	_mission_hostiles = 0
	if _campaign_maps.has(nm):
		_mission_start_map = nm
	elif _mission_of(_mission_start_map) != _mission_key_for(nm):
		# Entered a mission somewhere other than its start map (--map, the
		# console, an old save): the start map is the mission's own.
		_mission_start_map = _mission_start_for(nm)
	if _is_campaign_main(nm):
		_mission_hostiles = _level_enemies(level).size()
	if _dm == null and not Net.active:
		_count_mission_enemies(level, nm)
	# Vehicle missions (Skynet.exe mission table 0x34846, +8 = player
	# mode): mission 2 and 6 are driven in the jeep, mission 7 flown in
	# the HK, for the whole mission including its sub-maps.
	if _dm == null and is_instance_valid(player):
		player.set_vehicle(_vehicle_for_map(nm))
	# The map's border boxes and the hint at their edge (MAP.260).
	if is_instance_valid(player):
		player.border_boxes = _world_border_boxes(level)
		if not player.border_hint.is_connected(_on_border_hint):
			player.border_hint.connect(_on_border_hint)
	_apply_pending_player()
	_take_mission_start_state(nm)
	_collect_radiation(level)
	_setup_water(level)
	_setup_scenery(level)
	_set_hud_mode(player.vehicle if is_instance_valid(player) else 0)
	if _dm != null:
		_dm.on_level_ready(level)

## The mission has just begun on its first map: keep the player as he
## stands, for RESTART MISSION. Taken here, after _apply_pending_player,
## so a save loaded on the start map restarts to the state the save has —
## and only once per mission, so coming back to the first map later does
## not overwrite it. A deathmatch and a loose map have no mission to
## restart and take none.
func _take_mission_start_state(nm: String) -> void:
	if _dm != null or Net.active or not is_instance_valid(player):
		return
	if not _campaign_maps.has(nm) or _mission_start_snap_key == _mission_key:
		return
	_mission_start_snap_key = _mission_key
	_mission_start_state = _player_snapshot()

## The actors of ONE level. With a mission scene up every zone's robots
## are in the tree at once and the "enemy" group holds them all, so what
## belongs to this level is what stands under its own branch.
func _level_enemies(level: LevelLoader.Level) -> Array:
	var out: Array = []
	var branch: Node3D = level.enemies if level != null else null
	var scoped: bool = _mission != null and branch != null and is_instance_valid(branch)
	for e in get_tree().get_nodes_in_group("enemy"):
		if scoped and not branch.is_ancestor_of(e):
			continue
		out.append(e)
	return out

## zone-local → world: the level's border boxes are built from the marker
## records, so they are in the zone's own x/z; the player tests them
## against his global position. Translating them here (rather than in the
## loader) keeps `Level.border_boxes` in DOS coordinates, where the census
## tools and the smoke tests read them.
static func _world_border_boxes(level: LevelLoader.Level) -> Array:
	if level == null or level.origin == Vector3.ZERO:
		return level.border_boxes if level != null else []
	var shift := Vector2(level.origin.x, level.origin.z)
	var out: Array = []
	for b in level.border_boxes:
		out.append(Rect2((b as Rect2).position + shift, (b as Rect2).size))
	return out

## STATISTICS "ENEMIES DESTROYED": the mission's enemies, each counted
## once. This used to add the whole "enemy" group on every map entry and
## every load — robots already dead or already counted included. An enemy
## is known by its start marker's identity (_entity_key); on an outdoor map
## that identity is shared with the map's variants (MAP.216 is MAP.210's
## base with the same robots), indoors it is the map's own. Robots an 0xF3
## spawn point lets out are counted by enemy.gd when they appear.
func _count_mission_enemies(level: LevelLoader.Level, nm: String) -> void:
	var n: int = 0
	for e in _level_enemies(level):
		var id: String = "%s|%s" % [nm, e.name]
		if e.has_meta("marker_off") and level.map != null:
			var rec = level.map.entities_by_off.get(int(e.get_meta("marker_off")))
			if rec != null:
				if rec.marker_type < 0:
					continue                    # an 0xF3 spawn sprite's robot
				id = ("" if level.is_outdoor else nm + "|") + _entity_key(level.map, rec)
		if Stats.count_enemy(id):
			n += 1
	if n > 0:
		print("[stats] %s: %d enemies counted for the mission (%d in all)" % [nm, n, Stats.enemies])

## Place the camera at the DOS player-start marker (marker_type 0), facing
## the direction marker (marker_type 1) — read by LevelLoader. Falls back
## to the entity centroid for maps with no start marker.
##
## zone-local ↔ world: the markers and the centroid are zone-local and the
## heightmap is sampled in map coordinates, so the whole choice is made in
## that space and the zone origin goes on once, before the physics
## queries and the player.
func _frame_camera(level: LevelLoader.Level) -> void:
	# Arriving through a map exit: marker set N = position marker N,
	# facing marker N+1 (PlrSetPosMarker FUN_00121f72, skynet_gh.c:
	# 25074-25087). The register is spent whatever the level turns out to
	# carry — a map without that marker still starts at its own start.
	var set_id: int = _pending_marker_set
	_pending_marker_set = -1
	place_at_marker(level, set_id)

## Put the player into `level` at marker set `set_id` (-1 = the map's own
## start marker). Shared with the mission-scene runtime, where a doorway
## moves the player between two zones that are both already standing and
## there is no level load to hang the placement on.
func place_at_marker(level: LevelLoader.Level, set_id: int) -> void:
	var spawn: Vector3
	var look_target: Vector3
	# HP/ammo carry across a marker-set arrival — only a fresh mission resets.
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
	# zone-local → world: everything below queries the physics world.
	spawn += level.origin
	look_target += level.origin
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
const SLAB_REACH: float = 320.0
func _lift_to_floor(pos: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return pos
	if _cli.has("spawn-probe"):
		# Agent aid: what is above and below the spawn point.
		var qd := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 400.0, 0.0), pos - Vector3(0.0, 600.0, 0.0))
		qd.collision_mask = ZoneLayers.world_mask()
		var hd := space.intersect_ray(qd)
		var qu := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 2.0, 0.0), pos + Vector3(0.0, 900.0, 0.0))
		qu.collision_mask = ZoneLayers.world_mask()
		var hu := space.intersect_ray(qu)
		print("[spawn-probe] marker feet y=%.1f; from +400 down hits y=%s n=%s; up from +2 hits y=%s n=%s" % [pos.y,
			str((hd["position"] as Vector3).y) if hd.has("position") else "-", str(hd.get("normal", "-")),
			str((hu["position"] as Vector3).y) if hu.has("position") else "-", str(hu.get("normal", "-"))])
		var qn := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 40.0, 0.0), pos - Vector3(0.0, 60.0, 0.0))
		qn.collision_mask = ZoneLayers.world_mask()
		var hn := space.intersect_ray(qn)
		print("[spawn-probe] near ray +40..-60 hits y=%s n=%s collider=%s" % [
			str((hn["position"] as Vector3).y) if hn.has("position") else "-", str(hn.get("normal", "-")),
			str((hn["collider"] as Node).get_parent().name) if hn.has("collider") and (hn["collider"] as Node).get_parent() else "-"])
	# A marker UNDER its floor slab (Future Shock's interiors put the start
	# 90–240 u below the deck: MAP.013 feet 35 / floor 128, MAP.017 27 /
	# 264): the ray up hits the slab's underside close above, and the
	# floor the marker "has" below is some lower deck. DOS's cell scan
	# (FUN_00138500) lands the player on the slab; so do we — its top is
	# found from above.
	var near_floor := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 40.0, 0.0), pos - Vector3(0.0, 60.0, 0.0))
	near_floor.collision_mask = ZoneLayers.world_mask()
	near_floor.collide_with_areas = false
	var near := space.intersect_ray(near_floor)
	var standing: bool = near.has("position")
	if standing:
		# Feet onto that floor: a marker hovering 35 u above the deck under
		# a low slab (MAP.013) put the capsule into the slab and the clear-
		# spot search walked it out of the room.
		var fy: float = (near["position"] as Vector3).y + 1.0
		if absf(fy - pos.y) > 2.0:
			print("[skynet] spawn %.0f u off its floor — set down on it" % (pos.y - fy))
			return Vector3(pos.x, fy, pos.z)
		return pos
	if not standing:
		var up0 := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 2.0, 0.0), pos + Vector3(0.0, SLAB_REACH, 0.0))
		up0.collision_mask = ZoneLayers.world_mask()
		up0.collide_with_areas = false
		var under := space.intersect_ray(up0)
		if under.has("position") and (under["normal"] as Vector3).y < -0.5:
			var uy: float = (under["position"] as Vector3).y
			# (Past the underside by a hair: a DOS floor is one double-sided
			# polygon, its top IS its underside.)
			var top_q := PhysicsRayQueryParameters3D.create(Vector3(pos.x, uy + SLAB_REACH, pos.z), Vector3(pos.x, uy - 1.0, pos.z))
			top_q.collision_mask = ZoneLayers.world_mask()
			top_q.collide_with_areas = false
			var top := space.intersect_ray(top_q)
			if top.has("position") and (top["normal"] as Vector3).y > 0.5:
				var y: float = (top["position"] as Vector3).y + 1.0
				print("[skynet] spawn %.0f u under its floor — lifted onto it" % (y - pos.y))
				return Vector3(pos.x, y, pos.z)
	var down := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 40.0, 0.0), pos - Vector3(0.0, 600.0, 0.0))
	down.collision_mask = ZoneLayers.world_mask()
	down.collide_with_areas = false
	if space.intersect_ray(down).has("position"):
		return pos
	var up := PhysicsRayQueryParameters3D.create(pos + Vector3(0.0, 2.0, 0.0), pos + Vector3(0.0, 900.0, 0.0))
	up.collision_mask = ZoneLayers.world_mask()
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
	q.collision_mask = ZoneLayers.world_mask()
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
				r.collision_mask = ZoneLayers.world_mask()
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
## Outdoor depth haze (world units) — DOS fades distant terrain out. It
## starts at FOG_BEGIN pushed out by the stretch, and is solid at
## LevelLoader.FOG_FAR (_apply_fog_distances).
const FOG_BEGIN: float = 3500.0
const FOG_BEGIN_STRETCH: float = 1.9
## Props up to this AABB extent collide as boxes. 0 = off: an AABB box
## turns open props (tables, counters, arches) into solid blocks — the
## MAP.218 spawn ended up inside one, was relocated outside the room and
## fell through the world. DOS-style object cylinders would need the
## .3D bounding radius, not the AABB; trimesh + the anti-wedge routine
## is the safer default.
const PROP_BOX_MAX: float = 0.0
## Mover leaves are boxed by LevelBehaviour.is_door_like (thin, or no
## floor plate) — the bake and the loader share the rule.
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
## With DYNAMIC LIGHTS on the world is shaded per pixel, and the ambient is
## what keeps it looking like the DOS art: an unlit surface outdoors takes
## a neutral white ambient of 1.0 (the texture as drawn), indoors the same
## ambient as with the setting off. The lights only ADD — muzzle flashes,
## explosions, rounds, lamps. There is no sun then: a directional light
## over maps whose light is painted into the textures lit every face turned
## towards it, hangar interiors and walls behind buildings included, since
## its shadows reach only ~100 u (playtest 2026-09-15: "nasvetľujú sa plochy
## v tieni").
const DYN_AMBIENT_OUTDOOR_COLOR: Color = Color(1.0, 1.0, 1.0)

## One OmniLight3D per enabled variant-2 light entity of an interior,
## plus the interior treatment (cached unshaded materials swapped for
## per-vertex shaded duplicates). Outdoor maps carry lights too - MAP.210
## has 32, MAP.220 fifty, the street lamps - but the DOS renderer never
## lit the terrain with them (the lamp SPRITE simply has bright pixels),
## so outdoors only the flat ambient is set.
func _light_level(level: LevelLoader.Level) -> void:
	if not _light_env(level):
		return
	var cache: Dictionary = {}
	_shade_recursive(level.entities, cache, Settings.dynamic_lights)
	_shade_recursive(level.enemies, cache, Settings.dynamic_lights)
	if Settings.dynamic_lights and level.terrain != null:
		# The ground takes light too, or every lamp would hang over a
		# black street.
		_shade_recursive(level.terrain, cache, true)
	# Indoor sprites are shaded as before; outdoors DOS draws them at full
	# light and the dim ambient would only blacken the pickups.
	if level.sprites != null and not level.is_outdoor:
		for s in level.sprites.get_children():
			# ... except the fires, which DOS draws at full light.
			if s is SpriteBase3D and not s.has_meta("fullbright"):
				(s as SpriteBase3D).shaded = true
	print("[level] %s: %d map lights, %d shaded materials"
		% ["outdoor (dynamic lights)" if level.is_outdoor else "interior",
			_place_map_lights(level), cache.size()])

## The AMBIENT half on its own: the environment and the key light for this
## level, with nothing built. False when there is no more to do — no world
## environment at all, or an outdoor map without DYNAMIC LIGHTS, which DOS
## draws flat.
##
## Split out for the mission-scene runtime: activating a zone that has been
## entered before must set the environment again but must NOT shade its
## materials or place its lamps a second time (_place_map_lights builds a
## node per record every time it runs).
func _light_env(level: LevelLoader.Level) -> bool:
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return false
	var env: Environment = we.environment
	# DYNAMIC LIGHTS is the player's setting, not the original's. With it the
	# surfaces are shaded per pixel over an ambient that leaves them as the
	# DOS art has them (see DYN_AMBIENT_OUTDOOR_COLOR), the lights add on
	# top, and OUTDOOR maps get their lamps built: MAP.210 carries 32 and
	# MAP.220 fifty street lamps that the DOS renderer never lit the ground
	# with.
	var dyn: bool = Settings.dynamic_lights
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_sky_contribution = 0.0 if dyn else 1.0
	if level.is_outdoor:
		env.ambient_light_color = DYN_AMBIENT_OUTDOOR_COLOR if dyn else OUTDOOR_AMBIENT
		env.ambient_light_energy = 1.0 if dyn else 1.25
		if sun != null:
			sun.visible = not dyn
		if not dyn:
			return false
	else:
		env.ambient_light_sky_contribution = 1.0
		env.ambient_light_color = INDOOR_AMBIENT
		env.ambient_light_energy = 1.0
		if sun != null:
			sun.visible = false
	return true

## Indoor sprites rest on the floor the physics world actually has under
## them. The DOS record's Y sits a little above the floor and the port lifted the billboard's foot by a constant; the
## items still sank ("sprity zabiehajú do podlahy", 2026-09-05). Each
## sprite carries `bottom_off` (its foot relative to its origin); a ray
## from knee height finds the floor and the foot goes onto it, within a
## hand's span either way.
const SETTLE_REACH: float = 60.0
func _settle_sprites(level: LevelLoader.Level) -> void:
	if level == null or level.sprites == null or level.is_outdoor:
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var moved: int = 0
	for s in level.sprites.get_children():
		if not (s is Node3D) or not s.has_meta("bottom_off"):
			continue
		var n: Node3D = s
		var foot: float = n.global_position.y + float(n.get_meta("bottom_off"))
		var from := Vector3(n.global_position.x, foot + SETTLE_REACH, n.global_position.z)
		var q := PhysicsRayQueryParameters3D.create(from, from - Vector3(0.0, SETTLE_REACH * 2.0, 0.0))
		q.collision_mask = ZoneLayers.world_mask()
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if not hit.has("position"):
			continue
		var dy: float = float((hit["position"] as Vector3).y) + 0.5 - foot
		if absf(dy) > 0.5 and absf(dy) <= SETTLE_REACH:
			n.global_position.y += dy
			moved += 1
	if moved > 0:
		print("[level] settled %d sprites onto the floor" % moved)

## Build the OmniLight3D for every enabled variant-2 entity of an interior.
func _place_map_lights(level: LevelLoader.Level) -> int:
	if level.map == null or level.entities == null:
		return 0
	var n := 0
	for e in level.map.entities:
		if (e.flags & 3) != 2:
			continue
		# A light that starts off (enable word ≤ 0) still gets its node —
		# a chain may switch it on (act 0x01) or flicker it (0x02).
		var starts_on: bool = e.light_enable > 0
		var l := OmniLight3D.new()
		l.position = Vector3(float(e.x), -float(e.y), -float(e.z))
		l.omni_range = clampf(float(absi(e.light_enable)) * LIGHT_RANGE_PER_UNIT, 400.0, 6000.0)
		l.omni_attenuation = 1.0
		l.light_energy = clampf(float(e.light_intensity) / LIGHT_ENERGY_DIV, 0.4, 3.5)
		l.add_to_group("maplight")      # agent aid: --near=maplight:N
		l.visible = starts_on
		l.set_meta("file_off", e.file_off)
		level.map_lights[e.file_off] = l
		level.entities.add_child(l)
		if starts_on:
			n += 1
	# The lamps are the light records' own since step 5d: each variant-2
	# node reaches its own through the branch (Behaviour.lamp). Handed over
	# whole, because changing DYNAMIC LIGHTS frees every one of them and
	# builds them again.
	if level.behaviour != null:
		level.behaviour.map_lights = level.map_lights
	return n

## `per_pixel`: with DYNAMIC LIGHTS on the surfaces take their light per
## pixel — a muzzle flash on a per-vertex wall lights the wall's corners
## rather than the patch the flash is actually against.
static func _shade_recursive(n: Node, cache: Dictionary, per_pixel: bool = false) -> void:
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
						dup.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL \
							if per_pixel else BaseMaterial3D.SHADING_MODE_PER_VERTEX
						if per_pixel:
							# The DOS art paints its own highlights: no
							# specular at all, only the light's diffuse.
							dup.roughness = 1.0
							dup.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
						dup.set_meta(LIT_COPY_META, true)
						cache[key] = dup
					mi.set_surface_override_material(si, dup)
	for c in n.get_children():
		_shade_recursive(c, cache, per_pixel)

## Marks a material _shade_recursive made, so a re-light can take it off.
const LIT_COPY_META := &"lit_copy"

## Undo _shade_recursive under `n`: its lit copies come off the surfaces
## (other overrides — a lit button face — stay).
static func _unshade_recursive(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		for si in mi.get_surface_override_material_count():
			var m: Material = mi.get_surface_override_material(si)
			if m != null and m.has_meta(LIT_COPY_META):
				mi.set_surface_override_material(si, null)
	for c in n.get_children():
		_unshade_recursive(c)

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
		# (The distances: _apply_fog_distances, from _apply_render_env.)
		env.fog_depth_curve = 1.0
		env.fog_aerial_perspective = 0.0
		env.fog_sky_affect = 0.0
	_apply_render_env(level, env, fill)

## --- Rendering environment and sky ------------------------------------
## The DOS grading — the palette-ramp look, not raw linear output.
## 1.30 matched the Win32 port's gamma (2026-09-04) and came back as
## "až moc svetlá" (2026-09-05); the player's own BRIGHTNESS setting
## multiplies this (Settings.brightness).
const DOS_BRIGHTNESS: float = 1.15
const DOS_CONTRAST: float = 1.06
const DOS_SATURATION: float = 1.10

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
	@warning_ignore("integer_division")
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

## The night moon: the DOS sprite pinned to the camera.
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
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
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
## Seconds FAILED.IMG stands alone before the RESTART MISSION box comes up
## over it (DOS FUN_00121fe3 holds it about that long).
const FAILED_HOLD_SEC: float = 2.4

## The player's settings apply the moment they change, not on the next
## map: BRIGHTNESS (the DOS gamma), RENDER DETAIL (the haze, occlusion
## culling), the hi-res art, DYNAMIC LIGHTS and SMOOTH TEXTURES. Settings
## is an autoload and outlives this scene, so _exit_tree lets go again.
func _settings_links() -> Array:
	return [
		[Settings.brightness_changed, _refresh_brightness],
		[Settings.detail_changed, _on_detail_changed],
		[Settings.hires_weapons_changed, _on_hires_changed],
		[Settings.dynamic_lights_changed, _on_lighting_setting_changed],
		[Settings.texture_filter_changed, _on_lighting_setting_changed],
	]

func _watch_settings() -> void:
	for link in _settings_links():
		var sig: Signal = link[0]
		if not sig.is_connected(link[1]):
			sig.connect(link[1])

func _unwatch_settings() -> void:
	for link in _settings_links():
		var sig: Signal = link[0]
		if sig.is_connected(link[1]):
			sig.disconnect(link[1])

## RENDER DETAIL: the haze distances and occlusion culling of the level up.
func _on_detail_changed(_level: int = 0) -> void:
	get_viewport().use_occlusion_culling = Settings.detail > Settings.LOW
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if _current_level != null and _current_level.is_outdoor and we != null and we.environment != null:
		_apply_fog_distances(we.environment)

## HI-RES ART: the gun in your hands swaps sets, and the HUD swaps with it
## — the DOS panel off, the modern bar on (see _build_hud).
func _on_hires_changed(_on: bool = false) -> void:
	if _hud_layer != null:
		_build_hud()
	if is_instance_valid(player) and player.has_method("_load_viewmodels"):
		player.call("_load_viewmodels")

## DYNAMIC LIGHTS / SMOOTH TEXTURES: Render.restyle_all() has brought the
## cached materials along; the level's own lit copies (_shade_recursive)
## and its lamps are built again.
func _on_lighting_setting_changed(_on: bool = false) -> void:
	var level := _current_level
	if level == null:
		return
	for l in level.map_lights.values():
		if l != null and is_instance_valid(l):
			(l as Node).queue_free()
	level.map_lights.clear()
	for branch in [level.entities, level.enemies, level.terrain]:
		_unshade_recursive(branch)
	_light_level(level)
	if level.behaviour != null:
		level.behaviour.refresh_switch_visuals()

func _refresh_brightness(_v: float = 1.0) -> void:
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	we.environment.adjustment_brightness = DOS_BRIGHTNESS * Settings.brightness()

func _apply_render_env(level: LevelLoader.Level, env: Environment, fill: Color) -> void:
	var night: bool = level.is_outdoor and _moon != null
	if level.sky != null and is_instance_valid(level.sky):
		level.sky.visible = not night
	env.glow_enabled = false
	env.volumetric_fog_enabled = false
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ssao_enabled = false
	# The DOS renderer draws through a palette ramp and its own
	# gamma; the port's straight linear output came out darker and
	# flatter than the original ever looked. The Win32 port solves
	# it with fGamma / fContrast uniforms — same idea here
	# (2026-09-04: "the shading and the brightness in that port are
	# how I would want our DOS look").
	env.adjustment_enabled = true
	env.adjustment_brightness = DOS_BRIGHTNESS * Settings.brightness()
	env.adjustment_contrast = DOS_CONTRAST
	env.adjustment_saturation = DOS_SATURATION
	if sun != null:
		sun.light_energy = 1.35
		sun.light_color = Color(1.0, 0.97, 0.92)
	if level.is_outdoor:
		# Haze that reaches the horizon instead of swallowing the
		# next hill: the sky colour, not a third of it, and pushed
		# out with the far clip.
		env.fog_light_color = fill.lerp(Color(0.16, 0.14, 0.16), 0.35)
		_apply_fog_distances(env)

## Where the outdoor haze starts and where it is solid. The solid end IS
## LevelLoader.FOG_FAR — the distance past which the loader stops drawing
## geometry (visibility ranges) — so the two cannot drift apart: a haze
## ending beyond it would show things popping out. RENDER DETAIL pulls both
## fog distances in, never out (Settings.fog_scale, from the DOS far-clip
## table 1408 / 2176 / 2432), so FOG_FAR stays a safe culling distance.
func _apply_fog_distances(env: Environment) -> void:
	env.fog_depth_begin = FOG_BEGIN * FOG_BEGIN_STRETCH * Settings.fog_scale()
	env.fog_depth_end = LevelLoader.FOG_FAR * Settings.fog_scale()

## Pin the sky mesh to the camera position each frame (DOS FUN_00133bbb
## re-centres SKY_SKY.3D on the camera). Orientation stays fixed so the
## moon/stars remain world-anchored as the player looks around.
## --campath: the scripted camera, and how far along it we are.
var _campath: RefCounted = null
var _campath_t: float = -1.0
var _walk_target := Vector2.ZERO
var _walk_route: Array = []
var _walk_stuck: float = 0.0
var _walk_limit: float = 0.0
var _walk_best: float = 1e9        # closest approach to the target so far
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
		# Not "did I move" but "did I get closer": a capsule pressed against
		# a wall slides and jitters a couple of units every frame, and that
		# used to hide every stuck report.
		var gained: float = _walk_best - to.length()
		if gained > 4.0:
			_walk_best = to.length()
			_walk_stuck = minf(_walk_stuck, 0.0)
		if gained <= 4.0:
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
						cname = String(par.get_meta("mesh_name", par.name)) if par != null else String(cn.name)
						if par is MeshInstance3D:
							var pmi: MeshInstance3D = par
							cname += " pos=%s aabb=%s under %s" % [pmi.global_position.snapped(Vector3.ONE),
								str(pmi.mesh.get_aabb().size.snapped(Vector3.ONE)) if pmi.mesh != null else "-",
								String(pmi.get_parent().name) if pmi.get_parent() != null else "-"]
					desc += " n=%s@%s %s" % [kc.get_normal().snapped(Vector3(0.01, 0.01, 0.01)),
						kc.get_position().snapped(Vector3.ONE), cname]
				print("[walk] STUCK at %s floor=%s wall=%s ceiling=%s%s" % [p, player.is_on_floor(),
					player.is_on_wall(), player.is_on_ceiling(), desc])
		else:
			_walk_stuck = maxf(_walk_stuck, 0.0) if _walk_stuck >= 0.0 else _walk_stuck + delta
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

## The AIR second last put on the message line (-1 = none).
var _hud_air: int = -1

## The DOS object layer — movers, proximity triggers, doorways — on the
## physics step (see Behaviour.tick).
func _physics_process(delta: float) -> void:
	if _current_level != null and _current_level.behaviour != null \
			and is_instance_valid(player):
		_current_level.behaviour.tick(delta, player.global_position, _eye_position())

## Where the DOS proximity handlers measure from: the camera (0x1379c4 and
## 0x137e2e subtract [0xd47b4], the view position) — 75 u over the feet on
## foot, the seat or the cockpit in a vehicle.
func _eye_position() -> Vector3:
	if camera != null and is_instance_valid(camera) and camera.is_inside_tree():
		return camera.global_position
	return player.global_position + Vector3(0.0, EYE_HEIGHT, 0.0)

func _process(delta: float) -> void:
	_walk_step(delta)
	_campath_step(delta)
	if _current_level != null and _current_level.sky != null \
			and is_instance_valid(_current_level.sky):
		_current_level.sky.position = camera.global_position
	if _moon != null and is_instance_valid(_moon):
		if _moon_fall_v > 0.0 and _moon.visible:
			# FUN_00139a10: velocity feeds an accumulator that feeds the
			# offset — a quadratic drop.
			_moon_fall_v += 0.28 * delta
			_moon_fall += _moon_fall_v * delta
			if _moon_fall > deg_to_rad(MOON_ELEVATION_DEG + 12.0):
				_moon.visible = false
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
				if not n.is_inside_tree():
					continue
				if here.distance_to(n.global_position) < 6000.0 \
						and camera.is_position_in_frustum(n.global_position):
					_seen_meshes[n.get_instance_id()] = true
	if _hud != null and is_instance_valid(player):
		var hp: int = int(maxf(0.0, player.health))
		# Radiation: dose from the marker-4 sources, charged per second.
		if not _rad_sources.is_empty() and _game_over == null:
			_rad_dose = _radiation_dose(player.global_position + Vector3(0.0, 37.5, 0.0))
			if _rad_dose > 0.0:
				player.take_dos_damage(_rad_dose * delta, false)   # DOS points x dt (0x13b2c7)
		else:
			_rad_dose = 0.0
		_update_radiation_feedback(delta)
		_fade_hurt(delta)
		var air: int = -1
		if _water != null:
			_step_water(delta)
			_update_water_tint()
			if player.head_under and player.air < 10.0:
				air = maxi(int(ceil(player.air)), 0)
		if air != _hud_air or (air >= 0 and _status_label.text.is_empty()):
			# When the second changes (or the line was cleared), not a timer
			# and a status write every frame.
			_hud_air = air
			if air >= 0:
				_set_status("AIR %d" % air, 1.2)
		if _hud_mode != player.vehicle:
			_set_hud_mode(player.vehicle)
		if _hud_mode != 0:
			_update_vehicle_hud()
		# The bar reads the soldier off this — it writes only what moved.
		_hud.call("refresh", {
			"health": player.health, "max_health": player.max_health,
			"armor": float(player.armor_gauge()),
			"rad": _rad_dose, "rad_frac": clampf(_rad_dose / RAD_MAX_DOSE, 0.0, 1.0),
			"weapon_idx": int(player.get("_weapon_idx")), "weapon_name": str(player.weapon_name),
			"ammo": int(player.ammo), "vehicle": int(player.vehicle),
			"second_pool": int(player.secondary_pool), "second_name": str(player.secondary_name),
			"second_count": int(player.secondary_ammo), "bearing": _hud_bearing(),
		})
		# A restart carries the corpse through the fade — the player is put
		# back on his feet only once the first map is up — so a level change
		# under way must not raise the banner a second time.
		if hp <= 0 and _game_over == null and _dm == null and not _level_busy:
			_show_game_over()
	# No DOS mission ends by body count: they end when the objective
	# counter runs out (_on_objective_complete). `_mission_hostiles` is
	# only a counter for the HUD / tests.

## Taking a hit: a red wash over the view that fades in a fraction of a
## second. It replaces the feedback that was lost when the impact effect
## stopped being drawn full-screen at the camera (explosion.gd NEAR_SKIP)
## — you still know you were hit and roughly how hard.
const HURT_FLASH_MAX: float = 0.42
var _hurt_flash: ColorRect = null
var _hurt_level: float = 0.0

func _on_hurt(amount: float) -> void:
	_hurt_level = minf(_hurt_level + clampf(amount / 45.0, 0.10, 0.5), HURT_FLASH_MAX)
	if _hurt_flash == null or not is_instance_valid(_hurt_flash):
		var cl := CanvasLayer.new()
		cl.layer = 4                      # over the world, under the HUD
		add_child(cl)
		_hurt_flash = ColorRect.new()
		_hurt_flash.color = Color(0.75, 0.05, 0.04, 0.0)
		_hurt_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cl.add_child(_hurt_flash)
	_hurt_flash.color.a = _hurt_level

func _fade_hurt(delta: float) -> void:
	if _hurt_level <= 0.0:
		return
	_hurt_level = maxf(_hurt_level - delta * 1.6, 0.0)
	if _hurt_flash != null and is_instance_valid(_hurt_flash):
		_hurt_flash.color.a = _hurt_level

## The thrown item changed (the `0` key / middle mouse button). The DOS
## panel has no slot for the secondary, so it is announced on the status
## line the way the engine announced pickups.
func _on_secondary_changed(nm: String, count: int) -> void:
	_set_status("%s  x%d" % [nm, count], 2.5)

## Every press of the use key, whatever the crosshair is on: the 0xEF
## gates within reach answer it (Behaviour.press_use).
func _on_activate_key(_pos: Vector3) -> void:
	if _current_level != null and _current_level.behaviour != null:
		_current_level.behaviour.press_use()

## Use key with nothing under the crosshair: fire an armed exit here.
func _on_use_pressed(pos: Vector3) -> void:
	if _current_level != null and _current_level.behaviour != null:
		var b = _current_level.behaviour
		b.press_use()                       # (also for scripted presses)
		if not b.activate_teleport(pos, _eye_position()):
			b.use_nearby(pos, _eye_position())

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
## Being irradiated has to be felt, not just measured: DOS clicks a
## Geiger counter and washes the screen red, and without either the
## player just dies for no visible reason (playtest, 2026-09-06: "mám
## pocit, že tie radiačné zóny nefungujú" — they did, they killed him
## in four seconds, silently).
const RAD_CLICK_SLOW: float = 0.7      # seconds between clicks at a trace
const RAD_CLICK_FAST: float = 0.05     # …and in a lethal core
const RAD_TINT_MAX: float = 0.3
var _rad_click_left: float = 0.0
var _rad_tint: ColorRect = null
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
		# zone-local → world: the dose is measured against the player's
		# global position every frame (_radiation_dose).
		_rad_sources.append({
			"pos": Vector3(float(e.x), -float(e.y), -float(e.z)) + level.origin,
			"strength": strength})
	if not _rad_sources.is_empty():
		print("[skynet] %d radiation sources" % _rad_sources.size())

## Dose at `at` in HP per second (0 when clear).
## The Geiger counter and the red wash, both scaled by the dose. Silent
## and invisible above zero would be a bug of its own: the DOS player
## hears the counter run away before the health bar moves.
func _update_radiation_feedback(delta: float) -> void:
	var f: float = clampf(_rad_dose / RAD_MAX_DOSE, 0.0, 1.0)
	if _rad_tint == null or not is_instance_valid(_rad_tint):
		if f <= 0.0:
			return
		_rad_tint = ColorRect.new()
		_rad_tint.color = Color(0.75, 0.05, 0.03, 0.0)
		_rad_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_rad_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var cl := CanvasLayer.new()
		cl.layer = 4                      # over the world, under the HUD panel
		cl.add_child(_rad_tint)
		add_child(cl)
	# A slow pulse so it reads as a warning, not as damage taken.
	var pulse: float = 0.75 + 0.25 * sin(float(Time.get_ticks_msec()) * 0.006)
	_rad_tint.color.a = minf(f * RAD_TINT_MAX * pulse, RAD_TINT_MAX)
	if f <= 0.0:
		_rad_click_left = 0.0
		return
	_rad_click_left -= delta
	if _rad_click_left <= 0.0:
		_rad_click_left = lerpf(RAD_CLICK_SLOW, RAD_CLICK_FAST, f)
		Audio.play_sfx("GEIGER1.RAW" if f < 0.5 else "GEIGER2.RAW")

func _radiation_dose(at: Vector3) -> float:
	var dose: float = 0.0
	for src in _rad_sources:
		var p: Vector3 = src["pos"]
		var strength: float = src["strength"]
		# DOS FUN_0013b1e0: the 3-D distance to the source, 50 per unit
		# inside the strength, at most 12800 >> 8 = 50 a second per source.
		var r: float = strength - at.distance_to(p)
		if r <= 0.0:
			continue
		dose += minf(r * 50.0, 12800.0) / 256.0
	return dose

## --- The level's own scenery ---------------------------------------
## What the baked level scene (scripts/level_scene.gd) carries beside the
## map itself: the occluders that stop the engine submitting the valley
## behind a ridge. `mods/maps/<MAP>.detail.tscn` is a scene of your own,
## instantiated on top and never touched by the conversion
## (level.overlay); `mods/maps/<MAP>.level.scn` replaces the baked level
## altogether (scripts/level_scene.gd).
var _overlay: Node3D = null
var _occluders: Node3D = null

func _setup_scenery(level: LevelLoader.Level) -> void:
	for old in [_overlay, _occluders]:
		if old != null and is_instance_valid(old):
			old.queue_free()
	_overlay = null
	_occluders = null
	if level == null:
		return
	if level.occluders != null and is_instance_valid(level.occluders):
		_occluders = level.occluders
		add_child(_occluders)
		level.occluders = null
	if level.overlay != null and is_instance_valid(level.overlay):
		_overlay = level.overlay
		add_child(_overlay)
		level.overlay = null
	# Occlusion culling costs a CPU pass of its own; LOW turns it off.
	get_viewport().use_occlusion_culling = Settings.detail > Settings.LOW

## --- Water (DOS 0x120bf9 / 0x120c83 / 0x12e56b) ----------------------
## Marker type 103 (or 104) carries the map's WATER LEVEL: the engine
## takes that marker's Y, subtracts 16 and holds the surface there
## (0x120c83 can also slide it toward a target — that is how a deck
## floods). Under it the palette swaps to SKYNTWTR.COL, entering and
## leaving play splash / getair2, and after about 24 seconds of held
## breath drowning takes 85 HP a second (fly_camera._breathe).
##
## Five maps have one: the harbour on MAP.240 and MAP.250 (surface 786
## and 784 — the docks stand on stilts out of it and the submarine and
## the freighter float in it) and the flooded submarine decks on
## MAP.252/253/254. Without it those maps read as a dry rock basin with
## the boats sitting on the ground, which is exactly how the port drew
## them until 2026-09-04.
const WATER_MARKERS: Array = [103, 104]
const WATER_DROP: float = 16.0        # DOS: level = marker Y - 0x10
const WATER_SPAN: float = 65536.0     # a whole 64×64 map grid
const WATER_CELL: float = 1024.0      # one MAP grid cell, in world units
var _water: MeshInstance3D = null
var _water_tint: ColorRect = null
## Where the surface is gliding to, and how fast: DOS moves it at 0x1000
## units a second for a marker-103 map, 0x800 for marker 104
## (FUN_00120f85 / FUN_00121083).
var _water_target: float = INF
var _water_speed: float = 16.0

## The surface Y, or INF when the map is dry. zone-local → world: the
## level is compared with global positions (the player's head, the
## actors'), so it carries the zone's own Y.
static func _water_level(level: LevelLoader.Level) -> float:
	if level == null or level.map == null:
		return INF
	for e in level.map.entities:
		if (e.flags & 3) == 3 and WATER_MARKERS.has(e.marker_type):
			# DOS: level = marker.Y − 0x10, and DOS Y grows DOWNWARD, so in
			# Godot the surface sits 16 units ABOVE the marker. The port had
			# it 32 u too low on every map, which is why the submarine looked
			# drier than the original (FUN_00120f85, checked 2026-09-12).
			return -float(e.y) + WATER_DROP + level.origin.y
	return INF

func _setup_water(level: LevelLoader.Level) -> void:
	_water = null
	var y: float = _water_level(level)
	if is_instance_valid(player):
		player.water_level = y
	EnemyRef.water_y = y                  # ground actors stay out of it
	EnemyRef.terrain_wld = level.wld      # …and out of the painted lakes
	# zone-local ↔ world: the actors probe the heightmap with their global
	# position, which has to come back into map coordinates first.
	EnemyRef.terrain_origin = level.origin
	_water_target = y
	_water_speed = 16.0
	if level != null and level.map != null:
		for e in level.map.entities:
			if (e.flags & 3) == 3 and WATER_MARKERS.has(e.marker_type):
				_water_speed = 16.0 if e.marker_type == 103 else 8.0
				break
	if _water_tint != null and is_instance_valid(_water_tint):
		_water_tint.visible = false
	if y == INF:
		return
	# Back on a map whose water a chain moved: the surface where it had got
	# to, still gliding toward where it was going (_save_map_state). In a
	# mission scene the zone keeps it on its own entry (_keep_zone_water,
	# or the overlay it was built with).
	var snap: Dictionary = _map_state.get(_level_name(), {}) if _mission == null \
		else _zones.get(_active_zone, {})
	if snap.has("water"):
		_water_target = float(snap["water"])
		y = float(snap.get("water_y", _water_target))
		if is_instance_valid(player):
			player.water_level = y
		EnemyRef.water_y = y
	# One flat surface over THIS map's grid (its cell count × 1024), not
	# over a fixed 65536: a mission scene stands its maps side by side, and
	# a surface wider than the map it belongs to would lie over its
	# neighbours. It is drawn transparent and two-sided, so the world above
	# still occludes it and it is there when you look up from below.
	var span_x: float = WATER_SPAN
	var span_z: float = WATER_SPAN
	if level.map != null and level.map.grid_width > 0 and level.map.grid_height > 0:
		span_x = float(level.map.grid_width) * WATER_CELL
		span_z = float(level.map.grid_height) * WATER_CELL
	var centre := Vector2(span_x * 0.5, -span_z * 0.5)
	# Outdoors the ground is built only over its crop (LevelLoader.
	# terrain_crop), and a surface reaching past its edge would lie out in
	# the open, where no ground hides it.
	if level.is_outdoor and level.terrain_crop.size.x > 0:
		var cw: Rect2 = WldTerrain.cells_to_world(level.terrain_crop)
		span_x = cw.size.x
		span_z = cw.size.y
		centre = cw.get_center()
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	var pm := PlaneMesh.new()
	pm.size = Vector2(span_x, span_z)
	mi.mesh = pm
	# zone-local → world: the grid starts at the zone's own corner.
	mi.position = Vector3(centre.x, y, centre.y) \
		+ Vector3(level.origin.x, 0.0, level.origin.z)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(0.06, 0.22, 0.28, 0.82)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	add_child(mi)
	_water = mi
	print("[level] water surface at y=%d" % int(y))

## Acts 0xd6-0xda: a chain moved the water. The surface then glides to
## its new height at the map's own rate, and everything that reads the
## level — the player's swimming, the actors keeping out of it — follows
## it on the way (DOS FUN_00121083).
func _on_water_level(value: float, absolute: bool) -> void:
	if _water_target == INF:
		return                            # a dry map has no surface to move
	_water_target = value if absolute else _water_target + value
	print("[skynet] water level → %d" % int(_water_target))

func _step_water(delta: float) -> void:
	if _water == null or not is_instance_valid(_water) or _water_target == INF:
		return
	var y: float = _water.position.y
	if is_equal_approx(y, _water_target):
		return
	y = move_toward(y, _water_target, _water_speed * delta)
	_water.position.y = y
	if is_instance_valid(player):
		player.water_level = y
	EnemyRef.water_y = y

## The SKYNTWTR.COL palette swap, as a tint over the 3D view.
func _update_water_tint() -> void:
	if not is_instance_valid(player):
		return
	var under: bool = bool(player.head_under)
	if _water_tint == null or not is_instance_valid(_water_tint):
		if not under:
			return
		var cl := CanvasLayer.new()
		cl.layer = 3                      # under the HUD panel and menus
		add_child(cl)
		_water_tint = ColorRect.new()
		_water_tint.color = Color(0.10, 0.38, 0.48, 0.42)
		_water_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_water_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cl.add_child(_water_tint)
	_water_tint.visible = under

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
var _mission_texts: Array = []        # [M1]..[M5] every entry — DOS counts them all
var _objective_cursor: Array = []     # per section: entries shown so far
var _pending_objectives: Dictionary = {}  # a loaded save's counter (_ensure_mission_script)
var _objectives_total: int = 0        # every [M] entry of the script
## The mission whose MISSION COMPLETE banner has been shown (-1 none): a
## sub-map of a won mission entered afterwards must not win it again.
var _mission_ended_key: int = -1

## Mission number a map belongs to (its start map): the sub-maps of
## mission 1 are 211..218, mission 5 starts on MAP.252 but scripts from
## 250.TXT.
static func _mission_of(map_name: String) -> int:
	var sfx: int = _suffix(map_name)
	@warning_ignore("integer_division")
	return (sfx / 10) * 10 if sfx >= _mission_base() else -1

## The mission `map_name` is played in. DOS resets the mission register
## when a mission STARTS and never again, so a map's own number decides
## only when it is a campaign start map; every other map is a side area of
## the mission being played.
##
## Which mission a side area belongs to is not in its number:
##   - the shared interiors belong to two missions apiece — MAP.211-215 are
##     the truck hangars of missions 1 AND 2, MAP.242-248 the harbour sheds
##     of 4 and 5, MAP.281-286 the base of 7 and 8;
##   - MAP.250 is mission 5's own WORLD, two doorways past its start map
##     MAP.252, and starts no mission at all;
##   - the MAP.340+ rooms and mission 4's MAP.292/293 belong to whoever
##     walks in.
## The mission SCENE's map list answers it (Assets.mission_holds — the
## bake's census). Taking the number instead put mission 5 into mission 4's
## briefing at the first hangar door, and each of those maps used to start a
## "mission" of its own: the counter went to 0 on the way in and back to
## full on the way out, with the objectives already done retired for good,
## so the mission could not end. A save being loaded names its mission; a
## loose map with nothing running, or one no mission scene claims, keeps its
## own number.
func _mission_key_for(map_name: String) -> int:
	var own: int = _mission_of(map_name)
	if own < 0 or _campaign_maps.has(map_name):
		return own                          # a start map, and only it, sets the mission
	var loading: int = int(_pending_objectives.get("key", -1))
	if loading >= 0 and not _mission_start_for_key(loading).is_empty():
		return loading
	if _mission_key >= 0 and Assets.mission_holds(_mission_key, map_name):
		return _mission_key
	if not _mission_start_for_key(own).is_empty():
		return own
	return _mission_key if _mission_key >= 0 else own

## Load the mission script when the mission changes; keep the counter
## while moving between the maps of one mission.
func _ensure_mission_script(map_name: String) -> void:
	var key: int = _mission_key_for(map_name)
	# Deathmatch and the loose non-campaign maps have no script.
	if key < 0 or _dm != null or Net.active:
		return
	if key == _mission_key:
		return
	_mission_key = key
	# A new mission may try its own baked scene again, whatever made the
	# last one hand itself back to the per-map runtime.
	_mission_scene_off = -1
	_mission_objectives = []
	_mission_hints = []
	_objectives_left = 0
	_objectives_total = 0
	_mission_texts = []
	_objective_cursor = []
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"), SkynetPaths.variant):
		return
	var txt := bsa.read("%03d.TXT" % key)
	bsa.close()
	if txt.is_empty():
		return
	var brief: Dictionary = Briefing.parse(txt)
	_mission_objectives = brief.get("missions", [])
	_mission_hints = brief.get("hints", [])
	_mission_tactical = brief.get("tactical", [])
	# STATISTICS: a new mission starts its counters — but a save loaded
	# goes back to its own, and a save of the mission being played that
	# carries none (before 2026-09-14) keeps the running ones; it used to
	# zero them on every load.
	var loading: bool = int(_pending_objectives.get("key", -1)) == key
	if loading and int(_pending_stats.get("key", -1)) == key:
		Stats.restore_mission(_pending_stats)
	elif not (loading and Stats.mission_key == key):
		Stats.begin_mission(key)
	_pending_stats = {}
	_mission_texts = brief.get("mission_texts", [])
	for sec in _mission_texts:
		_objective_cursor.append(0)
		_objectives_left += (sec as Array).size()
	_objectives_total = _objectives_left
	if loading:
		_objectives_left = int(_pending_objectives.get("left", _objectives_left))
		var cur: Array = _pending_objectives.get("cursor", [])
		for i in mini(cur.size(), _objective_cursor.size()):
			_objective_cursor[i] = int(cur[i])
	_pending_objectives = {}
	print("[skynet] mission %d: %d objectives" % [key, _objectives_left])

## Act 0x26+idx (v1.01 handler 0x137fd0): once the counter is spent it
## does nothing at all; otherwise the counter drops and the NEXT entry of
## section [M<idx+1>] is shown.
func _on_objective_complete(idx: int) -> void:
	if _objectives_left <= 0:
		return
	_objectives_left -= 1
	var text: String = ""
	if idx >= 0 and idx < _mission_texts.size():
		var sec: Array = _mission_texts[idx]
		var at: int = int(_objective_cursor[idx])
		if at < sec.size():
			text = String(sec[at])
			_objective_cursor[idx] = at + 1
	if _current_level != null and _current_level.behaviour != null:
		_current_level.behaviour.objectives_left = _objectives_left
	print("[skynet] objective %d done, %d left" % [idx + 1, _objectives_left])
	_set_status(text if not text.is_empty() else "OBJECTIVE COMPLETE.", 6.0)
	_finish_mission_if_done(2.5)

## The mission's counter has run out: MISSION COMPLETE, once per mission,
## after `delay` seconds — the last line gets read before the banner covers
## it (the DOS engine holds the end screen back while a message is up).
## The wait runs on the game clock, so it stops under the Esc menu or the
## automap instead of putting the banner over them; and if the level
## changes meanwhile (an exit, a load) it gives up — _change_level asks
## again once the new level is up, which is also how a save made with no
## objectives left finishes its mission.
func _finish_mission_if_done(delay: float) -> void:
	if _dm != null or Net.active or _mission_key < 0 or _objectives_total <= 0 \
			or _objectives_left > 0 or _mission_ended_key == _mission_key:
		return
	if _mission_done or _game_over != null or _current_level == null:
		return                          # already on its way, or nothing to win on
	_mission_done = true
	var gen: int = _level_gen
	var key: int = _mission_key
	if delay > 0.0:
		await get_tree().create_timer(delay, false).timeout
	if gen != _level_gen or key != _mission_key:
		return
	if _game_over != null:
		# Killed in the wait (or act 0x2B): the mission was lost after all,
		# and the restart that replays it asks again.
		_mission_done = false
		return
	_mission_ended_key = key
	_show_mission_complete()

## The engine's own hint when the player reaches a border box's edge:
## hint slot 8 = [G9], which on MAP.260 reads "The highway is the other
## way." (DOS FUN_00122789 prints it from the same table as act 0x24).
func _on_border_hint() -> void:
	_on_hint_message(8)

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
	if _dm != null:
		# A deathmatch: the drop is the server's pickup (dm_game.drop_item).
		_dm.drop_item(pos, drop_type)
		return
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
	if SkynetPaths.game == "shock":
		# Future Shock keeps no mission table; its briefings say which
		# missions are driven or flown (020 "find HQ … pull the car in",
		# 040/100 "drive the carload…", 170 "drive to the TDTS complex";
		# 060 "take H/K through the drainage tunnel", 110 "fly through
		# river canyon", 120 tank convoy, 160 the TDTS fence) — the
		# walkthrough's jeep missions 2/8/15 and HK missions 5/9/10/14
		# in its own numbering.
		if sfx < 10 or sfx >= 200:
			return 0
		@warning_ignore("integer_division")
		match (sfx / 10) * 10:
			20, 40, 100, 170:
				return 1
			60, 110, 120, 160:
				return 2
		return 0
	if sfx < 200 or sfx >= 300:
		return 0
	@warning_ignore("integer_division")
	match (sfx - 200) / 10:
		2, 6:
			return 1
		7:
			return 2
	return 0

## Mission "main" maps end in 0 (mission = (map - 200) / 10).
static func _is_campaign_main(map_name: String) -> bool:
	var sfx: int = _suffix(map_name)
	return sfx >= _mission_base() and sfx % 10 == 0

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
	if _level_busy:
		_refuse_teleport()                    # the level is on its way out anyway
		return
	if target_map <= 0:
		if _prev_map_name.is_empty():
			_set_status("Exit leads back, but there is no previous map")
			_refuse_teleport()
			return
		target = _prev_map_name
	else:
		target = "MAP.%03d" % target_map
	var t_idx: int = _maps.find(target)
	if t_idx < 0:
		_set_status("Exit target %s is not in MDMDMAP2.BSA" % target)
		_refuse_teleport()
		return
	print("[skynet] exit %s → %s (marker set %d)" % [cur, target, marker_set])
	_prev_map_name = cur
	# Inside a mission scene the target is usually already standing: the
	# doorway moves the player instead of loading the map (the return
	# register above picked the zone for an exit whose target is 0).
	if _mission != null:
		if _zones.has(target):
			_enter_zone(target, marker_set)
			return
		if _phases.has(target):
			# A re-authored variant of one of the mission's worlds: the
			# world moves on to it where it stands, and nothing is left.
			_switch_phase(target, marker_set)
			return
		# A hand-over into another mission (mission 7 flies out of its own
		# world): step out of the scene and let the per-map runtime carry
		# the mission from here.
		print("[mission] %s is no zone of mission %d — leaving the mission scene"
			% [target, _mission_scene_key])
		_mission_scene_off = _mission_scene_key
	_pending_marker_set = marker_set
	_transition(target)

## The exit was not taken: the level's one-map-change latch is released,
## or every other exit of this map would stay dead.
func _refuse_teleport() -> void:
	if _current_level != null and _current_level.behaviour != null:
		_current_level.behaviour.exit_refused()

## Fade out, swap the level, fade back in. Exits bypass the briefing —
## this is an in-mission move.
func _transition(target: String) -> void:
	_change_level(target, true, false)

## THE way a level changes — exits, the console's `map`, loading a save,
## the next mission, the briefing's BEGIN — one at a time (`_level_busy`;
## false when one is already running or the map does not exist).
##   fade_out  fade to black first (exits, loads); otherwise cut to black
##   briefing  a mission start map shows its briefing instead of loading
##             (BEGIN comes back here)
##   saved     a save's session dictionary, installed after the tear-down
## The old level keeps running during the fade-out, but the player's
## controls do not, and saving and loading wait (save_to_slot) — an exit
## saved mid-fade was stored as already used.
func _change_level(map_name: String, fade_out: bool, briefing: bool, saved: Dictionary = {}) -> bool:
	var idx: int = _maps.find(map_name)
	if _level_busy or idx < 0:
		if _level_busy:
			print("[skynet] %s: a level change is already running — ignored" % map_name)
		return false
	_level_busy = true
	_level_gen += 1
	if not Net.active and is_instance_valid(player):
		player.set("input_locked", true)
	if fade_out:
		await _fade_to(1.0, 0.25)
	else:
		_fade_to(1.0, 0.0)
	# _clear_level snapshots the live map into _map_state — BEFORE a save's
	# overlay replaces that dictionary.
	_clear_level()
	_map_idx = idx
	if not saved.is_empty():
		_install_save(saved)
	if briefing and _maybe_show_briefing(map_name):
		_end_level_change()
		return true
	await _begin_level(map_name)
	_end_level_change()
	if _current_level != null:
		# Behind the black: every combat effect drawn once, so the first
		# shot does not stall on loading and compiling them.
		EffectWarmup.warm(_current_level.entities if _current_level.entities != null else self)
		_cli_after_level()
	_fade_to(0.0, 0.35)
	if not saved.is_empty() and not saved.has("restart"):
		_set_status("GAME LOADED.")
	# A mission whose last objective fell while the level changed (or a
	# save from the moment it fell) ends now.
	_finish_mission_if_done(2.5)
	return true

## Every way out of _change_level passes here. _clear_level raised
## _mission_done for the change (no mission may end on a level half torn
## down or half built); _begin_level lowers it once the level is up — but
## a level that failed to load, or a briefing shown instead, never got
## there, and the flag stayed up: saves said CANNOT SAVE NOW and no
## mission could end again. Nothing between _begin_level's end and here
## can legitimately raise it.
func _end_level_change() -> void:
	_mission_done = false
	_level_busy = false
	if not Net.active and is_instance_valid(player):
		player.set("input_locked", _campath != null)


## --- Mission scenes (step 4, docs/m2_mission_scene_plan.md) -----------
## A campaign mission is one baked scene (converted/missions/MISSION.NNN.scn,
## scripts/mission_scene.gd): the outdoor world at the origin and every
## interior it reaches standing beside it on a +X grid. A DOS map exit stops
## being a level change — the player is MOVED to the target zone, which is
## already built and still holds whatever was done in it.
##
## This is the campaign's runtime (step 8, 2026-09-16). The per-map runtime
## above is still the one every other map uses — Future Shock, a network
## game, a loose map, a mission with no baked scene — and `--no-mission-scene`
## gives a run of the campaign back to it.

## The mission scene under Main, and its zones by THE MAP THEY ARE IN:
##   "MAP.218" → {node: Zone_MAP_218, level: LevelLoader.Level or null,
##                map: "MAP.218", maps: every phase it can be in}
## A zone's Level is built the first time the player walks into it —
## mission 4 reaches sixteen interiors and building them all at the door
## would be a minute of nothing.
##
## The key is the map IN FORCE, not the one the zone was baked from: a
## world zone re-authored into a phase variant (MAP.210 → MAP.216) is
## re-keyed with it, so everything that reads a zone by map name — the
## doorways, the per-map overlay, a save — keeps reading the DOS map the
## player is actually standing in.
var _mission: Node3D = null
var _zones: Dictionary = {}
var _active_zone: String = ""
var _mission_scene_key: int = -1
## Every variant a world zone of this mission can be re-authored into:
##   "MAP.216" → the zone entry above (the same dictionary _zones holds).
## Filled from the baked Phases branch; the base map is in it too, so a
## world can be switched back.
var _phases: Dictionary = {}
## Which phase each world zone must come up in when a save is loaded:
## home map name → the map in force when it was saved.
var _pending_zone_phases: Dictionary = {}
## The mission scene's overlays that are NOT standing in the world, by the
## DOS map each one stands for (step 6):
##   "MAP.214" → {dead, taken, action, sig, grid, outdoor, mission[, water]}
## What a loaded save holds for the zones the player has not walked into
## yet — a zone's overlay waits here until it is built — and what a world
## was like before it was re-authored into a phase (MAP.210's state while
## the zone is MAP.216, for the day an exit leads back into MAP.210).
##
## Behind the flag this, and every built zone's own level, IS the state of
## the mission; the per-map `_map_state` holds only what lies outside the
## scene. The two meet at the scene's edges: coming up it takes its own
## maps out of `_map_state` (_take_scene_overlays), coming down it hands
## all of them back (_teardown_mission) — which is how a v0.3 save plays in
## a mission scene and how a hand-over carries the mission to the per-map
## runtime.
var _zone_state: Dictionary = {}
## The mission whose scene we have stepped out of for good this session:
## a phase variant (MAP.216) is not a zone, so taking that exit hands the
## mission back to the per-map runtime and it keeps it to the end.
var _mission_scene_off: int = -1

## Is the mission-scene runtime allowed at all right now? It is how the
## campaign is played (Settings.mission_scenes, on by default since
## 2026-09-16), but a deathmatch, Future Shock and the map browser keep the
## per-map path whatever the setting says — a network game is the same map
## for everyone and has no mission, Future Shock bakes no mission scenes
## (Assets.mission_starts), and a loose map is nobody's zone.
##
## `--no-mission-scene` puts a single run back on the per-map runtime, which
## is what the older suites (game_smoke_test, action_smoke_test) and a
## side-by-side comparison use; `--mission-scene` forces it on when the
## player's settings file says off.
func _mission_scenes_on() -> bool:
	if _cli.has("no-mission-scene"):
		return false
	return (Settings.mission_scenes or _cli.has("mission-scene")) \
		and not Net.active and _dm == null and SkynetPaths.game != "shock"

## Should `nm` come up inside its mission's scene? Only a map of a
## campaign mission this game bakes a scene for (Assets.mission_start_of).
func _want_mission_scene(nm: String) -> bool:
	if not _mission_scenes_on():
		return false
	var key: int = _mission_key_for(nm)
	if key < 0 or key == _mission_scene_off:
		return false
	return Assets.mission_start_of(key) >= 0 \
		and not _mission_start_for_key(key).is_empty()

## Bring the mission scene up with `name` as the active zone. False when
## it cannot be had — no baked scene, or `name` is not one of its zones —
## and _begin_level then loads the map on its own as before.
func _begin_mission_level(map_name: String, gen: int) -> bool:
	var key: int = _mission_key_for(map_name)
	var t0: int = Time.get_ticks_msec()
	# The scene is filed under the map the mission BEGINS on, which is not
	# always the mission's own number: mission 5 is the 25x maps and starts
	# on MAP.252 (Assets.mission_start_of).
	var start: int = Assets.mission_start_of(key)
	# A scene that has never been baked is built here, and that is tens of
	# seconds with nothing on the screen but the fade's black. The notice
	# goes up first and takes a frame to draw — the bake itself does not
	# yield (see _show_baking).
	var baking: bool = start >= 0 and not Assets.mission_scene_baked(start)
	if baking:
		await _show_baking(key)
		if gen != _level_gen:
			_hide_baking()
			return false
	var t_scene: int = Time.get_ticks_msec()
	var packed: PackedScene = Assets.mission_scene(start) if start >= 0 else null
	if baking:
		_hide_baking()
		var bake_ms: int = Time.get_ticks_msec() - t_scene
		t0 += bake_ms                   # the bake is reported on its own
		print("[mission] %d: %s (%.1f s)" % [key,
			"its scene was baked on the way in" if packed != null
				else "its scene would not bake", bake_ms / 1000.0])
	if packed == null:
		print("[mission] %d has no baked scene — the per-map runtime keeps it" % key)
		_mission_scene_off = key
		return false
	var root: Node3D = packed.instantiate() as Node3D
	var t_inst: int = Time.get_ticks_msec()
	if root == null:
		_mission_scene_off = key
		return false
	var zones: Dictionary = {}
	var zones_node: Node = root.get_node_or_null("Zones")
	if zones_node != null:
		for c in zones_node.get_children():
			if c is Node3D and not String(c.get("map_name")).is_empty():
				var mn: String = String(c.get("map_name"))
				zones[mn] = {"node": c, "level": null, "map": mn,
					"maps": PackedStringArray([mn])}
	# The phase table: which re-authored variants each world zone can be
	# turned into (scripts/mission/phase_world.gd). MAP.216 is not a zone
	# of its own — it is what the MAP.210 zone becomes.
	var phases: Dictionary = {}
	var phases_node: Node = root.get_node_or_null("Phases")
	if phases_node != null:
		for w in phases_node.get_children():
			var home: String = "MAP.%03d" % int(w.get("world_map"))
			var entry: Dictionary = zones.get(home, {})
			var nums: PackedInt32Array = w.get("phase_maps")
			if entry.is_empty() or nums.size() < 2:
				continue
			var names := PackedStringArray()
			for n in nums:
				names.append("MAP.%03d" % int(n))
			entry["maps"] = names
			for nm in names:
				phases[nm] = entry
	if not zones.has(map_name) and not phases.has(map_name):
		# A map the census never reached, or a hand-over into another
		# mission: the mission carries on the old way.
		print("[mission] %d: %s is no zone of the scene — the per-map runtime takes the mission"
			% [key, map_name])
		root.free()
		_mission_scene_off = key
		return false
	add_child(root)
	# The bake's own sky and key light are for opening the scene in the
	# editor; the game lights the active zone itself (_light_level).
	var prev: Node = root.get_node_or_null("EditorPreview")
	if prev != null:
		root.remove_child(prev)
		prev.queue_free()
	# Every zone comes out of the bake visible, and a mission holds up to
	# seventeen of them: they go dark until the player is in one. The dark
	# is not what keeps them apart, though, and neither is the distance
	# (MissionScene.GAP is 2048 units): each zone is put on its own render
	# layer and its own physics bit here, the camera draws only the active
	# zone's layer and every query casts on its bit only
	# (scripts/mission/zone_layers.gd). A zone's baked statics stay in the
	# physics world on that bit, where nothing of another zone meets them;
	# its furniture, which has to share one bit, comes off it while the
	# zone sleeps.
	ZoneLayers.on = true
	ZoneLayers.active = -1
	ZoneLayers.player_root = player
	for zname in zones:
		var zentry: Dictionary = zones[zname]
		var zn: Node3D = zentry["node"]
		var zi: int = int(zn.get("zone_index")) if zn.get("zone_index") != null else zn.get_index()
		zentry["index"] = zi
		zn.set_meta(ZoneLayers.META, zi)
		ZoneLayers.fit(zn, zi)
		ZoneLayers.park(zn)
		zn.visible = false
	if not get_tree().node_added.is_connected(_on_zone_node_added):
		get_tree().node_added.connect(_on_zone_node_added)
	_mission = root
	_zones = zones
	_phases = phases
	_mission_scene_key = key
	_active_zone = ""
	# Whatever the per-map overlay holds for the maps of this scene becomes
	# the zones' state — a loaded save's (either format), or what the
	# per-map runtime did in this mission before the scene came up.
	_take_scene_overlays(key)
	# A save taken after the world had been re-authored names its phase:
	# the zone comes up as THAT map, not as the one it was baked from
	# (save_to_slot's "zone_phases"). The active map says so too, and is
	# the one that must hold whatever the save is silent about.
	for home in _pending_zone_phases:
		var want: String = String(_pending_zone_phases[home])
		var pz: Dictionary = phases.get(want, {})
		if not pz.is_empty() and String(pz.get("map", "")) == String(home):
			_set_zone_phase(pz, want)
	_pending_zone_phases = {}
	if not _zones.has(map_name):
		_set_zone_phase(_phases[map_name], map_name)
	var ok: bool = await _activate_zone(map_name, "", gen)
	if not ok:
		push_warning("[mission] %d: zone %s would not build — falling back" % [key, map_name])
		_teardown_mission()
		_mission_scene_off = key
		return false
	print("[mission] %d up in %d ms (%d ms instancing the scene, %d zones, active %s)"
		% [key, Time.get_ticks_msec() - t0, t_inst - t0, zones.size(), map_name])
	return true

## The one thing a level change has to SAY rather than do behind the black.
##
## Every mission scene is baked by the conversion (Assets.import_all bakes
## all eight after the level scenes they stand on), so a normal install
## never sees this. A cache an older build left behind, or one whose maps
## moved under it, bakes the mission the first time it is played instead —
## a minute of a black screen that would read as a hang. The notice says
## what is happening, and that it happens once.
##
## It hangs on the fade's own CanvasLayer, above the black, and the frames
## awaited here are the only chance it gets to draw: the bake that follows
## is one long synchronous call.
var _baking_note: Label = null
func _show_baking(key: int) -> void:
	if _fade == null:
		_fade_to(1.0, 0.0)              # make the layer (already black)
	if _baking_note == null:
		_baking_note = Label.new()
		_baking_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_baking_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_baking_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_baking_note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_baking_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_baking_note.add_theme_color_override("font_color", Color(0.78, 0.82, 0.84))
		var f: FontFile = _status_font if _status_font != null \
			else _load_fnt("FONT0003.FNT", 2)
		if f != null:
			_baking_note.add_theme_font_override("font", f)
			_baking_note.add_theme_font_size_override("font_size", f.fixed_size)
		_fade.get_parent().add_child(_baking_note)
	@warning_ignore("integer_division")
	_baking_note.text = "PREPARING MISSION %d\n\nThis happens once." \
		% maxi((key - 200) / 10, 1)
	_baking_note.visible = true
	print("[mission] %d: preparing its scene for the first time" % key)
	# Two frames: one to lay the label out, one to put it on the screen.
	await get_tree().process_frame
	await get_tree().process_frame

func _hide_baking() -> void:
	if _baking_note != null and is_instance_valid(_baking_note):
		_baking_note.visible = false

## The per-map overlay's entries for the maps of this mission scene — its
## zones and every phase of its worlds — move into `_zone_state`, where
## each waits for its zone to be built. DOS never carries a map's state
## from one mission into the next (MAP.211-215 are the truck interiors of
## missions 1 AND 2): an overlay snapshotted while another mission was
## being played is dropped. One without a mission of its own comes from a
## save older than the tag and is taken, as the per-map runtime takes it.
func _take_scene_overlays(key: int) -> void:
	_zone_state = {}
	var taken := PackedStringArray()
	var dropped := PackedStringArray()
	for mn in _map_state.keys():
		var nm: String = String(mn)
		if not _zones.has(nm) and not _phases.has(nm):
			continue
		var snap: Dictionary = _map_state[mn]
		_map_state.erase(mn)
		if int(snap.get("mission", key)) != key:
			dropped.append(nm)
			continue
		_zone_state[nm] = snap
		taken.append(nm)
	if not taken.is_empty() or not dropped.is_empty():
		print("[mission] %d: state waiting for %d zones (%s)%s" % [key, taken.size(),
			", ".join(taken), "" if dropped.is_empty()
				else "; another mission's left behind: " + ", ".join(dropped)])

## The scene and every zone in it go; whatever the player changed in the
## zones — built or still waiting — is handed to the per-map overlay, so a
## mission that hands itself to the old runtime (an exit into another
## mission, a zone that would not build) carries its state over.
func _teardown_mission() -> void:
	if _mission == null:
		return
	# Back to the per-map picture: one layer, one physics bit.
	if get_tree().node_added.is_connected(_on_zone_node_added):
		get_tree().node_added.disconnect(_on_zone_node_added)
	ZoneLayers.reset()
	_zone_view(-1)
	var overlays: Dictionary = _scene_overlays()
	for mn in overlays:
		_map_state[mn] = overlays[mn]
	_zone_state = {}
	# A zone's sky dome is the one thing of it that hangs under Main (it
	# follows the camera), so it does not go with the scene.
	for zname in _zones:
		var lvl = (_zones[zname] as Dictionary).get("level")
		if lvl != null and lvl.sky != null and is_instance_valid(lvl.sky):
			lvl.sky.queue_free()
	if is_instance_valid(_mission):
		_mission.queue_free()
	_mission = null
	_zones = {}
	_phases = {}
	_active_zone = ""
	_mission_scene_key = -1

## The overlay of the zone filed under `zname` as it stands, {} when it has
## not been built. The active zone's water is the surface in the world; a
## sleeping zone's is what _keep_zone_water put on its entry.
func _zone_snapshot(zname: String) -> Dictionary:
	var z: Dictionary = _zones.get(zname, {})
	var lvl = z.get("level")
	if lvl == null:
		return {}
	var active: bool = zname == _active_zone
	var snap: Dictionary = _level_snapshot(lvl, active)
	if not active and z.has("water"):
		snap["water"] = z["water"]
		snap["water_y"] = z.get("water_y", z["water"])
	return snap

## Every overlay of the running mission scene by the DOS map it stands for:
## each built zone as it stands, and every overlay still waiting.
func _scene_overlays() -> Dictionary:
	var out: Dictionary = _zone_state.duplicate()
	for zname in _zones:
		var snap: Dictionary = _zone_snapshot(String(zname))
		if not snap.is_empty():
			out[String(zname)] = snap
	return out

## The water surface belongs to the active zone and hangs under Main, so a
## zone being left keeps where a chain had moved it (acts 0xd6-0xda) on its
## own entry — MAP.252's drained deck stays drained when the player comes
## back from MAP.253. Nothing is kept for a dry zone.
func _keep_zone_water() -> void:
	var z: Dictionary = _zones.get(_active_zone, {})
	if z.is_empty():
		return
	if _water != null and is_instance_valid(_water) and _water_target != INF:
		z["water"] = _water_target
		z["water_y"] = _water.position.y

## Build the runtime level of a zone out of the level scene the mission
## scene already stands under it. Everything goes under the ZONE node,
## which carries the zone's origin — the sky is the exception, it is
## pinned to the camera.
##
## `carry` is the world the zone is being re-authored FROM when this is a
## phase switch ({name, map, snap} — see _switch_phase): what the player
## did to the objects both variants share comes over with it.
func _build_zone(zname: String, z: Dictionary, carry: Dictionary = {}) -> LevelLoader.Level:
	var node: Node3D = z["node"]
	var t0: int = Time.get_ticks_msec()
	# A zone that has never been built still has the level scene the
	# mission bake stood under it; one being re-authored into a phase
	# variant has not, and the loader reads that map's own baked scene.
	var baked_root: Node = node.get_node_or_null("Level")
	var loader := LevelLoader.new()
	var level: LevelLoader.Level = loader.load_zone_from(zname, node.position, baked_root)
	if level == null:
		push_error("[mission] zone %s failed to build" % zname)
		return null
	# Nothing is left in the level-scene instance but its editor preview.
	if baked_root != null and is_instance_valid(baked_root):
		node.remove_child(baked_root)
		baked_root.queue_free()
	if level.terrain != null:
		node.add_child(level.terrain)
		if not _has_collision(level.terrain):
			level.terrain.create_trimesh_collision()   # walkable ground
			_enable_backfaces(level.terrain)
	if level.entities != null:
		_bake_entity_collision(level)
		node.add_child(level.entities)
		_unblock_furniture(level)
	# The zone's overlay, before the Behaviour branch enters the tree and
	# its armed cues fire. Walking between the zones of one mission scene
	# restores nothing — the zone never went away. What does get applied:
	# the overlay a loaded save left waiting for this zone (_zone_state),
	# and on a PHASE switch, which rebuilds the world as another MAP, the
	# robots the player killed and the items he took, by entity identity,
	# exactly as the per-map runtime carries them (_import_variant_state) —
	# the mechanisms come up as the variant's file has them. A phase the
	# world has been in before comes back as it was left, not carried.
	var snap: Dictionary = _zone_state.get(zname, {})
	if not snap.is_empty():
		# The save repair of v0.3.0 holds for a zone's overlay as it does
		# for a map's.
		_unretire_uncounted_objectives(level, zname, snap)
		_zone_state.erase(zname)          # the level holds it from here on
		if snap.has("water"):
			z["water"] = snap["water"]
			z["water_y"] = snap.get("water_y", snap["water"])
	elif not carry.is_empty():
		snap = _carry_variant_state(level, zname, carry)
	if not snap.is_empty():
		_apply_snapshot(level, zname, snap)
	if level.behaviour != null:
		_connect_behaviour(level)
		node.add_child(level.behaviour)
	_connect_level(level)
	if level.enemies != null:
		node.add_child(level.enemies)
	if level.sprites != null:
		node.add_child(level.sprites)
	# The zone's own scenery rides with it, so it is hidden with the zone.
	if level.occluders != null and is_instance_valid(level.occluders):
		node.add_child(level.occluders)
		level.occluders = null
	if level.overlay != null and is_instance_valid(level.overlay):
		node.add_child(level.overlay)
		level.overlay = null
	if level.sky != null:
		add_child(level.sky)                # follows the camera, not the zone
		level.sky.position = player.global_position
	z["level"] = level
	# Everything the build hung under the zone took its layers as it went
	# in (ZoneLayers.adopt); what was set up off the tree and then had its
	# bits written again (a hidden robot, a prop made walk-through) gets
	# them once more here.
	ZoneLayers.fit(node, int(z.get("index", 0)))
	print("[mission] zone %s built in %d ms (%s, %d meshes, %d enemies) at %s"
		% [zname, Time.get_ticks_msec() - t0,
		   "outdoor" if level.is_outdoor else "indoor",
		   level.entity_count, level.enemy_count, str(node.position)])
	return level

## Make `zname` the zone the game is played in: the one the player came
## from goes quiet, this one wakes up, and every per-level setup runs
## against it. `_pending_marker_set` says where in it the player lands.
## `carry` is _build_zone's (a phase switch hands the world it came from).
func _activate_zone(zname: String, from: String, gen: int, carry: Dictionary = {}) -> bool:
	var z: Dictionary = _zones.get(zname, {})
	if z.is_empty():
		return false
	# Where the surface of the zone being left had got to stays with it.
	_keep_zone_water()
	if not from.is_empty() and from != zname:
		_deactivate_zone(from)
	# The camera, the player's body and every query move onto this zone's
	# layers BEFORE anything of it is built: what the build hangs under
	# Main (the sky dome) takes the active zone's (ZoneLayers.adopt).
	var znode: Node3D = z["node"]
	ZoneLayers.unpark(znode)
	_hush_zone(znode, false)
	_zone_view(int(z.get("index", 0)))
	# The water surface of the zone being left — or of this one, when a
	# doorway leads back into the map it is in. It hangs under Main rather
	# than under the zone (the zone going dark would not take it), and
	# _setup_water builds the next one at the end of this.
	if _water != null and is_instance_valid(_water):
		_water.queue_free()
	_water = null
	_water_target = INF
	if is_instance_valid(player):
		player.water_level = INF
	var fresh: bool = z.get("level") == null
	if fresh and _build_zone(zname, z, carry) == null:
		return false
	var level: LevelLoader.Level = z["level"]
	var node: Node3D = z["node"]
	_current_level = level
	_active_zone = zname
	var idx: int = _maps.find(zname)
	if idx >= 0:
		_map_idx = idx
	node.visible = true
	if level.enemies != null and is_instance_valid(level.enemies):
		level.enemies.process_mode = Node.PROCESS_MODE_INHERIT
	if level.sky != null and is_instance_valid(level.sky):
		level.sky.visible = true
	_set_sky_fill(level, zname)
	# A zone that has been lit already keeps its lamps and its shaded
	# materials — only the ambient is set again (_place_map_lights would
	# build a second lamp for every record).
	if fresh:
		_light_level(level)
	else:
		_light_env(level)
	# Let the colliders of a zone that has just been built register before
	# the spawn-clearance query runs.
	await get_tree().physics_frame
	if gen != _level_gen:
		return false
	if fresh:
		_settle_sprites(level)
	place_at_marker(level, _pending_marker_set)
	_pending_marker_set = -1
	# Gates/doorways the arrival already stands in must be left before
	# they can fire again — a return exit drops the player right beside
	# the doorway they came through.
	if level.behaviour != null and is_instance_valid(player):
		level.behaviour.arm_proximity(player.global_position, _eye_position())
	if level.is_outdoor:
		Audio.play_ambient("AMB_WIND.RAW")
	else:
		Audio.stop_ambient()
	# The maptype marker picks the track; Audio.play_music keeps playing
	# when the track does not change, so crossing a doorway inside one
	# maptype does not restart the score.
	Audio.play_music_for_maptype(_maptype(level))
	_set_status("")
	_level_ready_tail(level, zname)
	return true

## The zone the player is leaving: its robots stop thinking, its action
## system stops being ticked (main._physics_process only ticks the active
## level), its geometry and its occluders go out of the view, and the
## shots in flight over it are gone.
##
## Its exits are re-armed: the DOS one-map-change latch is released by the
## map load that follows an exit, and here there is no load.
##
## Its sounds are paused where they are (_hush_zone) — the zones stand only
## MissionScene.GAP apart, well inside the 5000-9000 units a loop or an
## engine carries — and its furniture comes off the shared FURNITURE bit
## (ZoneLayers.park). Its render layer and its physics bit need nothing:
## the camera and every query have moved to the next zone's.
func _deactivate_zone(zname: String) -> void:
	var z: Dictionary = _zones.get(zname, {})
	if z.is_empty():
		return
	var znode: Node3D = z["node"]
	if znode != null and is_instance_valid(znode):
		ZoneLayers.park(znode)
		_hush_zone(znode, true)
	var level = z.get("level")
	if level != null:
		if level.behaviour != null:
			level.behaviour.exit_refused()
		if level.enemies != null and is_instance_valid(level.enemies):
			level.enemies.process_mode = Node.PROCESS_MODE_DISABLED
		if level.sky != null and is_instance_valid(level.sky):
			level.sky.visible = false
	var node: Node3D = z["node"]
	if node != null and is_instance_valid(node):
		node.visible = false
	# In-flight shots and grenades belong to the zone they were fired in.
	for p in get_tree().get_nodes_in_group("projectile"):
		p.queue_free()

## Point the player's view and body at zone `idx` (zone_layers.gd): the
## camera draws that zone's layer and the shared one, the player collides
## on its bit. -1, or no mission scene: every layer and bit 1, the per-map
## picture.
func _zone_view(idx: int) -> void:
	if ZoneLayers.on:
		ZoneLayers.active = idx
	var k: int = idx if ZoneLayers.on and idx >= 0 else 0
	if is_instance_valid(player):
		var bodies: Array = [player]
		bodies.append_array(player.find_children("*", "CollisionObject3D", true, false))
		for b in bodies:
			if b is CollisionObject3D:
				var co := b as CollisionObject3D
				co.collision_layer = ZoneLayers.retarget(co.collision_layer, k)
				co.collision_mask = ZoneLayers.retarget(co.collision_mask, k)
	if camera != null:
		camera.cull_mask = ZoneLayers.cull_mask()
	# The scene's own key light belongs to no zone: it lights the one the
	# player is in (and the shared layer), never a sleeping neighbour.
	if sun != null:
		sun.light_cull_mask = ZoneLayers.cull_mask()

## Every node that enters the tree while a mission scene is up takes its
## zone's layers — or the active zone's, a shot or an explosion under Main.
func _on_zone_node_added(n: Node) -> void:
	ZoneLayers.adopt(n)

## A zone going to sleep pauses its sounds where they are, and they carry
## on when it wakes.
func _hush_zone(node: Node, hush: bool) -> void:
	for p in node.find_children("*", "AudioStreamPlayer3D", true, false):
		var a := p as AudioStreamPlayer3D
		if hush:
			if a.playing and not a.stream_paused:
				a.stream_paused = true
				a.set_meta(&"zone_hushed", true)
		elif a.has_meta(&"zone_hushed"):
			a.remove_meta(&"zone_hushed")
			a.stream_paused = false

## A doorway inside the mission scene: fade, move, fade back. The shape of
## _change_level without a level change — one at a time (`_level_busy`),
## and a mission whose last objective fell during it ends afterwards.
func _enter_zone(target: String, marker_set: int) -> void:
	if _mission == null or _level_busy:
		return
	_level_busy = true
	_level_gen += 1
	var gen: int = _level_gen
	if not Net.active and is_instance_valid(player):
		player.set("input_locked", true)
	await _fade_to(1.0, 0.25)
	var from: String = _active_zone
	_pending_marker_set = marker_set
	var ok: bool = await _activate_zone(target, from, gen)
	if gen != _level_gen:
		return                              # another change took over
	_end_level_change()
	if not ok:
		push_warning("[mission] cannot enter zone %s" % target)
	_fade_to(0.0, 0.35)
	_finish_mission_if_done(2.5)
	_solver_level_ready()               # --solve: a doorway is its level change

## --- Phases (step 5, docs/m2_mission_scene_plan.md) -------------------
## Half a mission's outdoor map is shipped several times over: MAP.216 is
## MAP.210 later in the mission (the gate open, the truck gone, another
## crop of robots) and MAP.217 is later still, and DOS walks into them
## through ordinary 0xF0 exits that happen to lead back outdoors. The
## scene holds the world ONCE and moves it FORWARD: the zone is rebuilt
## from the variant's own MAP file where it stands, and the player lands
## on that map's marker set in the same zone.
##
## Rebuilt, not patched. DOS loads the whole variant, and so does this —
## the records, the chains, the robots, the pickups, the heightmap and the
## baked geometry all come from the target map, which is the only way the
## re-authored chains (MAP.216's gate chain is four links where MAP.210's
## is six) can be right. What comes across is the dead and the taken, by
## entity identity; every mechanism starts as the variant's file has it,
## as DOS has it with an overlay per map number (_carry_variant_state).

## The map the zone `entry` is in becomes `target`: the key it is filed
## under, the node's own exports and whatever is still standing under it.
## The level itself is NOT built here — _activate_zone does that.
func _set_zone_phase(entry: Dictionary, target: String) -> void:
	var old: String = String(entry.get("map", ""))
	if old == target or target.is_empty():
		return
	var node: Node3D = entry["node"]
	# A zone that has never been walked into still carries the level scene
	# of the map it was baked from; the loader reads the target's own.
	var baked: Node = node.get_node_or_null("Level")
	if baked != null and is_instance_valid(baked):
		node.remove_child(baked)
		baked.queue_free()
	_zones.erase(old)
	entry["map"] = target
	_zones[target] = entry
	# The variant has a water marker of its own; a surface kept for the old
	# map says nothing about it.
	entry.erase("water")
	entry.erase("water_y")
	var num: int = _suffix(target)
	node.set("map_name", target)
	node.set("map_num", num)
	if bool(node.get("outdoor")) \
			and FileAccess.file_exists(SkynetPaths.gamedata_path("WLD.%03d" % num)):
		node.set("wld_suffix", "%03d" % num)
	print("[mission] zone %s is now %s" % [old, target])

## Everything a built zone put in the world goes, and its overlay is kept
## first — the zone is about to be built again as another map.
func _free_zone_level(entry: Dictionary) -> void:
	var lvl = entry.get("level")
	entry["level"] = null
	if lvl == null:
		return
	if lvl.behaviour != null:
		lvl.behaviour.exit_refused()
	# The sky dome hangs under Main (it follows the camera); everything
	# else of the zone stands under the zone node, so that is swept whole
	# — the branches, their map lights, the occluders and any overlay.
	if lvl.sky != null and is_instance_valid(lvl.sky):
		lvl.sky.queue_free()
	var node: Node3D = entry["node"]
	if node != null and is_instance_valid(node):
		for c in node.get_children():
			node.remove_child(c)
			c.queue_free()
	if _current_level == lvl:
		_current_level = null           # nothing may be ticked in between
	# In-flight shots and grenades belong to the world that is going.
	for p in get_tree().get_nodes_in_group("projectile"):
		p.queue_free()
	_seen_meshes.clear()                # the automap's fog is per map

## A DOS exit into a re-authored variant of one of this mission's worlds.
## The world zone is rebuilt as that variant in place and the player lands
## on its marker set; every other zone is left exactly as it is.
func _switch_phase(target: String, marker_set: int) -> void:
	var entry: Dictionary = _phases.get(target, {})
	if _mission == null or entry.is_empty() or _level_busy:
		_refuse_teleport()
		return
	_level_busy = true
	_level_gen += 1
	var gen: int = _level_gen
	if not Net.active and is_instance_valid(player):
		player.set("input_locked", true)
	await _fade_to(1.0, 0.25)
	var t0: int = Time.get_ticks_msec()
	var from: String = String(entry["map"])
	# The zone being re-authored is usually NOT the one the player stands
	# in (MAP.212's doorway leads out into MAP.216), so the zone they are
	# leaving still has to be put to sleep — _activate_zone does that when
	# it is told where the player came from.
	var leaving: String = _active_zone if _active_zone != from else ""
	var carry: Dictionary = {}
	var lvl = entry.get("level")
	if lvl != null:
		# DOS keeps an overlay per map number: what the world was like is
		# kept under its own name, and what carries into the variant is
		# worked out from it when the new records are there.
		var snap: Dictionary = _zone_snapshot(from)
		_zone_state[from] = snap
		carry = {"name": from, "map": _phase_source_map(from, lvl), "snap": snap}
		_free_zone_level(entry)
	elif _zone_state.has(from):
		# A world not walked back into since a save was loaded: what the
		# player did to it is still the waiting overlay, and it carries
		# from there — against the records as the file has them, the way
		# the per-map runtime reads a variant it carries from.
		var src: LevelLoader.MapFile.MapFile = _parse_map(from)
		if src != null:
			carry = {"name": from, "map": src, "snap": _zone_state[from]}
	_set_zone_phase(entry, target)
	_pending_marker_set = marker_set
	var ok: bool = await _activate_zone(target, leaving, gen, carry)
	if gen != _level_gen:
		return                              # another change took over
	_end_level_change()
	if not ok:
		push_warning("[mission] cannot re-author the world as %s" % target)
	_fade_to(0.0, 0.35)
	print("[mission] phase %s → %s in %d ms" % [from, target, Time.get_ticks_msec() - t0])
	_finish_mission_if_done(2.5)
	_solver_level_ready()               # --solve: the world it walks is a new one

## What the console's `zone` / `zones` print.
func _zone_report(all: bool) -> String:
	if _mission == null:
		return "no mission scene up (the per-map runtime is playing %s)" % _level_name()
	if not all:
		var z: Dictionary = _zones.get(_active_zone, {})
		var at: Vector3 = (z["node"] as Node3D).position if not z.is_empty() else Vector3.ZERO
		return "zone %s of mission %d at %s (%d zones)%s" \
			% [_active_zone, _mission_scene_key, at, _zones.size(),
			   _phase_note(z)]
	var lines: Array = ["mission %d, %d zones:" % [_mission_scene_key, _zones.size()]]
	for zname in _zones:
		var z: Dictionary = _zones[zname]
		var lvl = z.get("level")
		lines.append("  %s %s at %s%s%s" % [
			"*" if String(zname) == _active_zone else " ", zname,
			str((z["node"] as Node3D).position),
			"" if lvl != null else ("  (not built yet, saved state waiting)"
				if _zone_state.has(zname) else "  (not built yet)"),
			_phase_note(z)])
	# The phases a world has left behind keep their overlay under their own
	# map name.
	var kept := PackedStringArray()
	for mn in _zone_state:
		if not _zones.has(mn):
			kept.append(String(mn))
	if not kept.is_empty():
		lines.append("  state kept for phases left behind: %s" % ", ".join(kept))
	return "\n".join(lines)

## " — phase 2 of 3: MAP.210 > [MAP.216] > MAP.217" for a zone that is one
## of a world's variants, "" for a zone that is only ever itself.
func _phase_note(z: Dictionary) -> String:
	var maps: PackedStringArray = z.get("maps", PackedStringArray())
	if maps.size() < 2:
		return ""
	var here: String = String(z.get("map", ""))
	var parts := PackedStringArray()
	var at: int = 0
	for i in maps.size():
		if maps[i] == here:
			at = i + 1
			parts.append("[%s]" % maps[i])
		else:
			parts.append(maps[i])
	return "  — phase %d of %d: %s" % [at, maps.size(), " > ".join(parts)]
## --- Save / load (docs §N.4) -----------------------------------------------
## A save is the DOS session state: the current map, the previous-map
## register, every map's Mst overlay and the player. Maps reload from
## disk on load, as they do on every transition.
##
## Two sessions, one file (scripts/save_game.gd):
##   per-map (VERSION_MAP)  {map, prev_map, map_state, player, objectives,
##                        mission_start_map, stats} — what the per-map
##                        runtime writes: Future Shock, loose maps, the
##                        mission-scene flag off
##   mission (VERSION, "v0.4", step 6 of docs/m2_mission_scene_plan.md)
##                       {map, mission, zone, phases, zones, return_zone,
##                        player, objectives, mission_start_map, stats} —
##                        written whenever a mission scene is up
## Both load under either runtime. The zones of a mission save are keyed by
## the DOS map each one stands for, so they ARE per-map overlays: installing
## one lays them out as `_map_state` (_install_save), the per-map runtime
## plays that as it is, and a mission scene coming up takes its own maps
## back out of it (_take_scene_overlays) — the same door a per-map save
## walks through into a mission scene.

## Snapshot the running game into `slot`. False when no level is up, or
## while the game is between states: a level change running, the mission
## already won (a save then stored 0 objectives left — a mission that
## could never end again), an end screen up.
func save_to_slot(slot: int) -> bool:
	if _dm != null or Net.active:
		_set_status("NO SAVING IN A NETWORK GAME.")
		return false
	if _current_level == null or not is_instance_valid(player):
		_set_status("NOTHING TO SAVE.")
		return false
	if _level_busy or _mission_done or _game_over != null:
		_set_status("CANNOT SAVE NOW.")
		return false
	var psnap: Dictionary = _player_snapshot()
	var data: Dictionary
	if _mission != null:
		data = _scene_save_data(psnap)
	else:
		_save_map_state()
		data = {
			"version": SaveGame.VERSION_MAP,
			"time": Time.get_datetime_string_from_system(false, true),
			"map": _level_name(),
			"prev_map": _prev_map_name,
			"map_state": _map_state,
			"player": psnap,
			"objectives": _objectives_save(),
			# 2026-09-14 — both optional on load (see _install_save).
			"mission_start_map": _mission_start_map,
			"stats": Stats.mission_state(),
			# 2026-09-16, also optional: what RESTART MISSION replays from.
			"mission_start_player": _mission_start_state,
		}
	if not SaveGame.write(slot, data):
		_set_status("SAVE FAILED.")
		return false
	print("[skynet] saved slot %d: %s%s" % [slot, data["map"],
		" (mission %d, %d zone overlays)" % [int(data["mission"]), (data["zones"] as Dictionary).size()]
			if data.has("zones") else ""])
	_set_status("GAME SAVED.")
	return true

## The player as a save file (and the mission-start snapshot) keeps him.
## He goes back into the level's own (DOS) coordinates: a zone of a
## mission scene stands off the origin, and a snapshot must read the same
## whichever runtime restores it — nor may the zone origins of a rebaked
## mission strand him in mid-air.
func _player_snapshot() -> Dictionary:
	var snap: Dictionary = player.save_state()
	if _current_level != null and _current_level.origin != Vector3.ZERO and snap.has("pos"):
		snap["pos"] = (snap["pos"] as Vector3) - _current_level.origin
	return snap

## The mission counter as a save keeps it.
func _objectives_save() -> Dictionary:
	return {"key": _mission_key, "left": _objectives_left,
		"cursor": _objective_cursor.duplicate()}

## A mission scene saved as the mission it is (SaveGame.VERSION, "v0.4"):
##   map          the DOS map the player stands in — the active zone, under
##                the map in force (MAP.217, not the MAP.210 it was baked
##                from); the slot header and the per-map runtime read this
##   mission      the scene's mission key (210)
##   zone         the active zone — the same name as `map`
##   phases       every world's phase: the map it was baked from → the map
##                in force ({"MAP.210": "MAP.217"}); applied before any zone
##                is built
##   zones        map → overlay ({dead, taken, triggers, sig, grid, outdoor,
##                mission[, water, water_y]}) for every zone the mission has
##                built and every overlay still waiting (a zone not walked
##                into since a load, a phase a world has left behind); a
##                zone never built is absent — it comes up as its MAP says
##   return_zone  the previous-map register: where an exit whose target is 0
##                leads (DAT_00038b18)
##   player       the player, in the zone's own coordinates
##   objectives, mission_start_map, stats, mission_start_player — as the
##                per-map session has them
## The score is not kept: the zone's maptype marker picks it again.
func _scene_save_data(psnap: Dictionary) -> Dictionary:
	return {
		"version": SaveGame.VERSION,
		"time": Time.get_datetime_string_from_system(false, true),
		"map": _active_zone,
		"mission": _mission_scene_key,
		"zone": _active_zone,
		"phases": _zone_phases(),
		"zones": _scene_overlays(),
		"return_zone": _prev_map_name,
		"player": psnap,
		"objectives": _objectives_save(),
		"mission_start_map": _mission_start_map,
		"stats": Stats.mission_state(),
		"mission_start_player": _mission_start_state,
	}

## Is `data` a mission-scene session (the `zones` shape)?
static func _is_scene_save(data: Dictionary) -> bool:
	return data.get("zones") is Dictionary

## The phase every world of the running mission scene stands in, by the
## map it was baked from: {"MAP.210": "MAP.216"}. Every world that has
## phases is in it, one still in its base map too; empty without a mission
## scene up.
func _zone_phases() -> Dictionary:
	var out: Dictionary = {}
	for zname in _zones:
		var z: Dictionary = _zones[zname]
		var maps: PackedStringArray = z.get("maps", PackedStringArray())
		if maps.size() > 1:
			out[maps[0]] = String(zname)
	return out

## Restore `slot`: tear the current level down, install the saved state
## and reload the saved map with the player where they were. `data` is
## the slot already read (the LOAD menu's start in _ready).
func load_from_slot(slot: int, data: Dictionary = {}) -> bool:
	if _dm != null or Net.active:
		_set_status("NO LOADING IN A NETWORK GAME.")
		return false
	if _level_busy:
		_set_status("CANNOT LOAD NOW.")
		return false
	if data.is_empty():
		data = SaveGame.read(slot)
	if data.is_empty():
		_set_status("EMPTY SLOT." if SaveGame.last_error.is_empty()
			else "CANNOT LOAD: " + SaveGame.last_error.to_upper())
		return false
	var map_name: String = String(data.get("map", ""))
	if not _maps.has(map_name):
		_set_status("SAVED MAP %s IS MISSING." % map_name)
		return false
	print("[skynet] loading slot %d: %s" % [slot, map_name])
	# Whatever screen is up (console, Esc menu, briefing, end screen) goes
	# away first, each through its own close so nothing stays paused.
	_close_overlays()
	if _briefing_overlay != null:
		_briefing_teardown()
	_dismiss_end_screen()
	return await _change_level(map_name, true, false, data)

## A save's session state, laid in between the tear-down and the load.
## Either session lands as the per-map overlay (see the section head): a
## mission save's zones are keyed by DOS map already, and its return zone
## is the previous-map register.
func _install_save(data: Dictionary) -> void:
	if _is_scene_save(data):
		_map_state = (data["zones"] as Dictionary).duplicate()
		_prev_map_name = String(data.get("return_zone", ""))
		# Which variant each world of the mission stands in
		# (_begin_mission_level puts the zones into them before the first
		# one is built; the per-map runtime needs none of it).
		_pending_zone_phases = data.get("phases", {})
		print("[skynet] mission save: mission %d, zone %s, %d zone overlays, return zone %s"
			% [int(data.get("mission", -1)), String(data.get("zone", data.get("map", ""))),
			   _map_state.size(), _prev_map_name if not _prev_map_name.is_empty() else "-"])
	else:
		var ms = data.get("map_state", {})
		_map_state = (ms as Dictionary).duplicate() if ms is Dictionary else {}
		_prev_map_name = String(data.get("prev_map", ""))
		# A per-map save written inside a mission scene by the step-5 build
		# named the phases as "zone_phases"; one from before carries none.
		_pending_zone_phases = data.get("zone_phases", {})
	_pending_marker_set = -1
	_pending_player = data.get("player", {})
	# The mission script is read again and the saved counter laid over it.
	_pending_objectives = data.get("objectives", {})
	_pending_stats = data.get("stats", {})
	_mission_key = -1
	_mission_ended_key = -1
	# The start map picks the next mission. A save without it (before
	# 2026-09-14) takes the saved map's mission's own — keeping the one of
	# the mission being played sent a mission-1 save on to mission 3.
	var map_name: String = String(data.get("map", ""))
	var start: String = String(data.get("mission_start_map", ""))
	if not _campaign_maps.has(start) or _mission_of(start) != _mission_key_for(map_name):
		start = _mission_start_for(map_name)
	_mission_start_map = start
	# What RESTART MISSION replays from. A save from before 2026-09-16, or
	# one taken outside a campaign mission, carries none: the restart then
	# starts the mission with the DOS starting kit instead.
	var msp: Variant = data.get("mission_start_player", {})
	_mission_start_state = (msp as Dictionary).duplicate() if msp is Dictionary else {}
	_mission_start_snap_key = _mission_of(start) if not _mission_start_state.is_empty() else -1

## The campaign map the mission `map_name` is played in starts on ("" outside
## the campaign).
func _mission_start_for(map_name: String) -> String:
	return _mission_start_for_key(_mission_key_for(map_name))

## The campaign map mission `key` starts on, "" when no campaign mission has
## that key.
func _mission_start_for_key(key: int) -> String:
	if key < 0:
		return ""
	for m in _campaign_maps:
		if _mission_of(m) == key:
			return m
	return ""

## End of _begin_level: put the player back where the save left them.
func _apply_pending_player() -> void:
	if _pending_player.is_empty():
		return
	var snap: Dictionary = _pending_player
	_pending_player = {}
	# zone-local → world: a save keeps the player in the map's own
	# coordinates (save_to_slot), so a zone standing off the origin puts
	# them back where the DOS position means.
	if _current_level != null and _current_level.origin != Vector3.ZERO and snap.has("pos"):
		snap = snap.duplicate()
		snap["pos"] = (snap["pos"] as Vector3) + _current_level.origin
	if is_instance_valid(player):
		player.restore_state(snap)
		if _current_level != null and _current_level.behaviour != null:
			_current_level.behaviour.arm_proximity(player.global_position, _eye_position())

## Fade the screen to `alpha` over `dur` seconds (0 = at once). A newer
## fade replaces one still running — the fade-in after a load is not
## awaited, and the next exit may already be fading out.
var _fade_tween: Tween = null
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
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null
	if dur <= 0.0:
		_fade.color.a = alpha
		return
	var tw := create_tween()
	_fade_tween = tw
	tw.tween_property(_fade, "color:a", alpha, dur)
	# Not tw.finished: a killed tween never emits it.
	await get_tree().create_timer(dur, false).timeout
	if _fade_tween == tw:
		_fade.color.a = alpha
		_fade_tween = null

## Snapshot the current map before it is torn down (DOS MstSave): which
## enemy markers are dead, which pickups were taken, and the whole
## trigger state of the map (TriggerRuntime.snapshot).
func _save_map_state() -> void:
	var lvl := _current_level
	if lvl == null:
		return
	_map_state[_level_name()] = _level_snapshot(lvl, true)

## The overlay of one level, whether or not it is the one being played. A
## mission scene keeps several of them alive at once and snapshots them all
## for a save or when it comes down (_zone_snapshot); `with_water` belongs
## to the ACTIVE one, which is the only level whose surface is in the world.
##
## It carries no table of its entities any more (an identity key per
## record, the map's grid, its outdoor flag): those were there for a
## search through the visited maps for something that looked like a
## variant, and since step 5i the variants are a committed list and the
## map an overlay carries into is read again from its file. What an
## overlay says about the records it was taken against is now the trigger
## state's own graph_sha (TriggerRuntime.snapshot).
func _level_snapshot(lvl: LevelLoader.Level, with_water: bool = false) -> Dictionary:
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
	var snap: Dictionary = {
		"dead": dead, "taken": taken,
		# The trigger state of the map: every byte play has changed, the
		# movers, the wrecks and the robots let out (TriggerRuntime.snapshot,
		# plan §4). Written under "triggers" since step 5h — a save from
		# before keeps the same dictionary under "action" (_trigger_state).
		"triggers": lvl.triggers.snapshot() if lvl.triggers != null else {},
		# The mission it was played in (step 6): a mission scene takes no
		# overlay of another mission's (_take_scene_overlays). Absent in
		# saves from before; the per-map runtime does not read it.
		"mission": _mission_key,
	}
	# Where a chain has moved the water (acts 0xd6-0xda), and where the
	# surface has got to on its way — the marker alone put MAP.254's
	# drained sewer back under water (2026-09-14; absent = the marker).
	if with_water and _water != null and is_instance_valid(_water) and _water_target != INF:
		snap["water"] = _water_target
		snap["water_y"] = _water.position.y
	return snap

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

## Which record of `dst_map` each record of `src_map` IS, where both maps
## have it: source file offset → this map's. Identity only — the same
## kind of thing, of the same name or type, at the same DOS coordinates —
## what a dead robot and a taken pickup are carried by (_carry_records).
static func _variant_remap(src_map: LevelLoader.MapFile.MapFile,
		dst_map: LevelLoader.MapFile.MapFile) -> Dictionary:
	var out: Dictionary = {}
	if src_map == null or dst_map == null:
		return out
	var mine: Dictionary = {}                # identity key → my file offset
	for e in dst_map.entities:
		mine[_entity_key(dst_map, e)] = e.file_off
	for e in src_map.entities:
		var key: String = _entity_key(src_map, e)
		if mine.has(key):
			out[e.file_off] = mine[key]
	return out

## The records a PHASE SWITCH carries from: `from` as the MAP file has
## them. Only their identity is read (_variant_remap: kind, name or type,
## DOS position), which play never changes; `lvl` is the fallback for a
## map that cannot be re-read, which is better than carrying nothing.
func _phase_source_map(from: String, lvl) -> LevelLoader.MapFile.MapFile:
	var parsed: LevelLoader.MapFile.MapFile = _parse_map(from)
	if parsed != null:
		return parsed
	push_warning("[mission] %s cannot be read again — the phase carries its live records" % from)
	return lvl.map if lvl != null else null

## `map_name` parsed fresh, the way LevelLoader reads it — the archive
## entry, which is the only source of a map's records. Or null.
static func _parse_map(map_name: String) -> LevelLoader.MapFile.MapFile:
	var bytes := PackedByteArray()
	var bsa := BSAReader.new()
	if bsa.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		bytes = bsa.read(map_name)
		bsa.close()
	return LevelLoader.MapFile.parse(bytes) if not bytes.is_empty() else null

## The rule module of the game being PLAYED. The port runs SkyNET's act
## tables on Future Shock's maps (the shock table is not decoded), but
## which maps are variants of one world is a fact about the data, and
## the two games number their maps differently — so that one question is
## asked of the right module.
static func _rules() -> Script:
	return TriggerGraph.rules_for(TriggerGraph.current_game())

## Are these two maps the same world shipped twice — a world and one of
## its later phases, or two phases of it (Rules.VARIANTS)?
static func _same_world(a: String, b: String) -> bool:
	return bool(_rules().same_world(_suffix(a), _suffix(b)))

## First visit to a map that is a VARIANT of one already played (the
## base after the truck ride = MAP.216, after the lasers = MAP.217).
##
## WHICH maps those are is the committed list in the rules module
## (Rules.VARIANTS, migration step 5i), not a search: until then this
## looked through every visited map of the same mission for one sharing
## 60 % of this map's meshes at the same coordinates, which is a guess
## about the data made afresh on every first visit.
##
## What crosses is the DEAD ROBOTS and the TAKEN PICKUPS, by entity
## identity, and nothing else. DOS keeps one Mst overlay per map NUMBER
## and re-reads every map from its file, so a variant comes up with its
## mechanisms exactly as authored: every trigger's state, act and link
## byte, every mover where the file puts it, every wreck whole, every
## pool of hit points full. The port carried the switches, movers, damage
## and destruction of the records both maps share until the owner's
## ruling of 2026-09-23 ("tak ako DOS"): MAP.217's base gate @078f7 came
## up open because it had been opened on MAP.210, where DOS has it shut
## until the tower switch @09551 opens it again. The dead and the taken
## stay the port's — the player asked for those — and a variant's
## reinforcements, which are records of its own, come up as authored.
##
## Never an act byte or a link either, and for the same reason: a retired
## cue (act 0xFF) belongs to the map it fired on. 2026-09-14 imported
## them, the jeep's [G1] hint fired on MAP.210 retired MAP.217's [M3]
## objective on the same entity, and mission 1 could not end.
func _import_variant_state(level: LevelLoader.Level, nm: String) -> Dictionary:
	if level.map == null:
		return {}
	# The overlay to carry from: a visited map of this world. Two of them
	# can be waiting — MAP.217 is walked into with both MAP.210 and
	# MAP.216 behind it — and the one holding most of this map's records
	# is its nearest phase, which is the one the world was last played in
	# (MAP.217 shares 420 records with MAP.216 against MAP.210's 383).
	var best: String = ""
	var best_map: LevelLoader.MapFile.MapFile = null
	var best_remap: Dictionary = {}
	for other in _map_state:
		if not _same_world(String(other), nm):
			continue
		var m: LevelLoader.MapFile.MapFile = _parse_map(String(other))
		if m == null:
			push_warning("[skynet] %s: cannot read %s — its switches and damage stay behind"
				% [nm, String(other)])
			continue
		var remap_tbl: Dictionary = _variant_remap(m, level.map)
		if not remap_tbl.is_empty() and remap_tbl.size() >= best_remap.size():
			best = String(other)
			best_map = m
			best_remap = remap_tbl
	if best.is_empty():
		return {}
	var out: Dictionary = _carry_records(_map_state[best], best_remap)
	print("[skynet] %s: first visit — the dead and the taken of %s, the same world re-authored (%d of its entities are here too, %d dead, %d taken; its mechanisms stay as this map has them)"
		% [nm, best, best_remap.size(), out["dead"].size(), out["taken"].size()])
	return out

## The same carry for a PHASE SWITCH (step 5): the world the player was
## just in is `carry` = {name, map (as it was parsed then), snap}, and
## `level` is the same zone built again from the variant's records. There
## is nothing to search for and nothing to parse — the source map is the
## one that has just come down — and the rule is the one above, to the
## letter: identity by kind + name + DOS position, the dead and the taken
## and nothing of the mechanisms.
func _carry_variant_state(level: LevelLoader.Level, nm: String,
		carry: Dictionary) -> Dictionary:
	var src_map: LevelLoader.MapFile.MapFile = carry.get("map")
	var from: String = String(carry.get("name", ""))
	if level.map == null or src_map == null:
		return {}
	# A phase edge comes out of the mission scene's own census, the list
	# out of the rules module: where the two disagree, nothing carries
	# rather than something wrong.
	if not _same_world(from, nm):
		push_warning("[mission] %s and %s are not one world — the phase carries nothing" % [from, nm])
		return {}
	var remap_tbl: Dictionary = _variant_remap(src_map, level.map)
	var out: Dictionary = _carry_records(carry.get("snap", {}), remap_tbl)
	print("[mission] %s ← %s: %d of its entities are here too (%d dead, %d taken; its mechanisms stay as this map has them)"
		% [nm, from, remap_tbl.size(), out["dead"].size(), out["taken"].size()])
	return out

## Translate one map's overlay onto another's records through `remap`
## (source file offset → this level's, by entity identity): the dead
## robots and the taken pickups, and an EMPTY trigger overlay. Nothing of
## a mechanism crosses a variant — no state, act or link byte, no mover,
## no wreck, no hit points, no spent record — because DOS has an overlay
## per map number and nothing else (see _import_variant_state). An empty
## overlay is nothing to lay (TriggerRuntime.restore), so the variant's
## own records stand exactly as its file authors them.
func _carry_records(src: Dictionary, remap_tbl: Dictionary) -> Dictionary:
	var out: Dictionary = {"dead": {}, "taken": {}, "triggers": {}}
	for off in src.get("dead", {}):
		if remap_tbl.has(off):
			out["dead"][remap_tbl[off]] = true
	for off in src.get("taken", {}):
		if remap_tbl.has(off):
			out["taken"][remap_tbl[off]] = true
	return out

## Save repair for v0.3.0 (the 2026-09-14 variant import). Such a snapshot
## can hold an objective retired on ANOTHER map: MAP.210's jeep hint fired,
## the import wrote its 0xFF onto MAP.217's [M3] jeep, and a save made
## after that keeps it on every load. The rule: a restored 0xFF on an
## entity whose act in the MAP data is an objective (0x26 + n) is dropped
## when section [M<n+1>] of the running mission's script has entries and
## none of them has been shown (cursor 0). An objective that really fired
## while the counter ran moved that cursor (_on_objective_complete), so a
## section still at 0 has never counted anything and the retirement is
## foreign. Exact for mission 1, where each of [M1] [M2] [M3] has one entry
## and one entity (MAP.215's two, MAP.217's jeep): [M3] at 0 = the jeep
## never counted. A section with no entries never moves its cursor, so it
## is left alone; so is a mission already won. Dropped retirements leave
## the snapshot, so the next save is clean.
func _unretire_uncounted_objectives(level: LevelLoader.Level, nm: String, snap: Dictionary) -> void:
	var acts: Dictionary = _trigger_state(snap).get("acts", {})
	if acts.is_empty() or level.map == null or _mission_key < 0 \
			or _mission_key != _mission_key_for(nm) or _mission_ended_key == _mission_key:
		return
	var foreign: Array = []
	for off in acts:
		if int(acts[off]) != 0xFF:
			continue
		var e = level.map.entities_by_off.get(int(off))   # as parsed: nothing restored yet
		if e == null or e.marker_type >= 0:
			continue
		var idx: int = e.link_act_type - Rules.ACT_OBJECTIVE_FIRST
		if idx < 0 or e.link_act_type >= Rules.ACT_FAIL:
			continue
		if idx >= _mission_texts.size() or (_mission_texts[idx] as Array).is_empty():
			continue
		if int(_objective_cursor[idx]) > 0:
			continue
		foreign.append(off)
	for off in foreign:
		acts.erase(off)
		print("[skynet] %s: objective @%05x [M%d] was retired but never counted — live again (v0.3.0 save repair)"
			% [nm, int(off), level.map.entities_by_off[int(off)].link_act_type - 0x25])

## Re-apply a saved snapshot to a freshly loaded map (DOS MstLoad). The
## per-map runtime's: a mission scene applies its zones' overlays itself
## (_build_zone), from _zone_state and never through the variant search.
func _apply_map_state(level: LevelLoader.Level, nm: String) -> void:
	var snap: Dictionary = _map_state.get(nm, {})
	if snap.is_empty():
		snap = _import_variant_state(level, nm)
		if snap.is_empty():
			return
		_map_state[nm] = snap
	else:
		_unretire_uncounted_objectives(level, nm, snap)
	_apply_snapshot(level, nm, snap)

## The TRIGGER STATE of one map's overlay — every byte play has changed,
## the movers, the wrecks and the robots let out.
##
## Migration step 5h moved it under "triggers" (plan §4:
## map_state[map].triggers IS the runtime's snapshot). A save written
## before that keeps the same dictionary under "action", and the two are
## the same thing 1:1: every key in either is a MAP FILE OFFSET and every
## section — states, acts, links, hp, spent, movers, destr, spawned — was
## already written by the runtime or asked of the same nodes. So an old
## overlay converts by being read under its own name, and nothing else.
## (A save from a build older still simply has fewer sections, which
## restore takes as "no change there", as it always did.)
static func _trigger_state(snap: Dictionary) -> Dictionary:
	if snap.has("triggers"):
		return snap["triggers"]
	return snap.get("action", {})

## An overlay onto a level whose records have just been read: the dead
## robots and the taken pickups leave, and the trigger runtime takes the
## switch, mover, damage and act state.
func _apply_snapshot(level: LevelLoader.Level, nm: String, snap: Dictionary) -> void:
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
	if level.triggers != null:
		level.triggers.restore(_trigger_state(snap))
	print("[skynet] %s: restored state (%d dead, %d pickups taken)"
		% [nm, dead.size(), taken.size()])

## Death, and act 0x2B. DOS (FUN_00122b52) sets the dead + mission-failed
## bits, plays SFX 108 and runs no animation and no fade; FUN_00121fe3
## then holds FAILED.IMG up for about 2.4 seconds and hands over to the
## RESTART MISSION dialog. There is NO single-player respawn — the port
## offered one, and it put the player back exactly where he was killed,
## because every marker-set arrival had overwritten the spawn point ("it
## respawned me on the very spot where I died", playtest 2026-09-16).
func _show_game_over() -> void:
	_show_end_screen("MISSION FAILED", Color(0.9, 0.22, 0.16), true,
		"", "FAILED.IMG")

func _show_mission_complete() -> void:
	_show_end_screen("MISSION COMPLETE", Color(0.42, 0.92, 0.48),
		false, _next_campaign_map(), "WELLDONE.IMG")

## Next campaign map after the current one, or "" at the end of the
## campaign. Works whether the current map is a mission map or a sub-map.
func _next_campaign_map() -> String:
	# From the map the mission began on: a mission often ends on a sub-map
	# or an interior whose number lies past every mission map (MAP.230's
	# ends aboard the submarine), and that used to end the campaign —
	# "hodilo ma to do hlavného menu" (playtest, 2026-09-11).
	var at: int = _campaign_maps.find(_mission_start_map)
	if at >= 0:
		return _campaign_maps[at + 1] if at + 1 < _campaign_maps.size() else ""
	if _map_idx < 0 or _map_idx >= _maps.size():
		return ""
	var cur: int = _suffix(_maps[_map_idx])
	for m in _campaign_maps:
		if _suffix(m) > cur:
			return m
	return ""

## Show a paused end-of-mission screen. `failed` is death: the banner
## stands alone for FAILED_HOLD_SEC and the RESTART MISSION box follows it.
## A non-empty `next_map` is the mission that won and what comes after it.
func _show_end_screen(title: String, color: Color, failed: bool,
		next_map: String = "", banner_img: String = "") -> void:
	if _game_over != null:
		return
	var cl := CanvasLayer.new()
	cl.layer = 80
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(cl)
	_game_over = cl
	_game_over_next = next_map
	_game_over_failed = failed
	_game_over_restart = false
	print("[skynet] end screen: %s (next %s)" % [title, next_map if next_map != "" else "-"])
	var dim := ColorRect.new()
	# A won mission leaves the frozen view showing under the banner.
	dim.color = Color(0.02, 0.03, 0.05, 0.85 if failed else 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cl.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cl.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 22)
	center.add_child(vb)
	_game_over_box = vb
	# The DOS banner art — WELLDONE.IMG "WELL DONE, SOLDIER!" (189x18) or
	# FAILED.IMG "MISSION FAILED, SOLDIER!" (228x18), index 0 transparent —
	# blown up to most of the screen width, the way the original announced
	# it. Falls back to a plain caption when the archive is missing.
	var banner: ImageTexture = _load_panel_texture(banner_img, true, true)
	if banner != null:
		var rect := TextureRect.new()
		rect.texture = banner
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var vw: float = get_viewport().get_visible_rect().size.x
		var bw: float = clampf(vw * 0.62, 320.0, 1400.0)
		rect.custom_minimum_size = Vector2(bw,
			bw * float(banner.get_height()) / float(banner.get_width()))
		vb.add_child(rect)
	else:
		var ttl := Label.new()
		ttl.text = title
		ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ttl.add_theme_font_size_override("font_size", 56)
		ttl.add_theme_color_override("font_color", color)
		vb.add_child(ttl)
	# Paused, and the mouse freed for whatever comes next — the buttons
	# here, or the next briefing's tabs and the main menu after a won
	# mission, which inherited a captured mouse (2026-09-03: "mission
	# complete and it just hung").
	PauseState.push(&"end_screen")
	# Main is paused under this screen, so its _input never sees Enter or
	# Space: the keys ride on a button of the (always processing) layer.
	cl.add_child(_br_keybtn([KEY_ENTER, KEY_KP_ENTER, KEY_SPACE], _end_screen_accept))
	if failed:
		# DOS shows the banner alone, then the dialog. ESC in the dialog is
		# NO — and only there, so ESC under the banner still does nothing.
		cl.add_child(_br_keybtn([KEY_ESCAPE], _end_screen_cancel))
		# The timers below know their screen by its instance id, never by
		# the node: a lambda that captures a node the player has dismissed
		# before the timer ran out is called with null and Godot reports
		# "Lambda capture at index 0 was freed" (the mission suite took the
		# end screen down and walked on, 6 s before this fired).
		var failed_id: int = cl.get_instance_id()
		get_tree().create_timer(FAILED_HOLD_SEC, true, false, true).timeout.connect(
			func() -> void:
				if _end_screen_is(failed_id):
					_show_restart_box(_game_over_box))
		return
	# A won mission is DOS's banner and nothing else — WELLDONE.IMG for a
	# few seconds, then the next mission's briefing (a DOSBox run,
	# 2026-09-11; the port had NEXT MISSION / MAIN MENU buttons under it).
	# Enter / Space skip the wait; after the last mission, the main menu.
	var my_id: int = cl.get_instance_id()
	get_tree().create_timer(AUTO_ADVANCE_SEC, true, false, true).timeout.connect(func() -> void:
		if _end_screen_is(my_id):
			if next_map != "":
				_advance_to(next_map)
			else:
				_game_over_menu())

## Is the end screen that is up the one with instance id `id`?
func _end_screen_is(id: int) -> bool:
	return _game_over != null and is_instance_valid(_game_over) \
		and _game_over.get_instance_id() == id

## RESTART.IMG, the DOS "RESTART MISSION? YES / NO" box, under the banner
## that is already up (FUN_0011d09e). It is the same 96x37 panel as
## QUIT.IMG, drawn at 75,27 of the 320x200 screen, so YES and NO sit in
## the same two rectangles the menu's quit box uses.
const RESTART_BOX_SCALE: float = 4.0
const RESTART_YES_RECT: Rect2 = Rect2(0, 20, 52, 17)
const RESTART_NO_RECT: Rect2 = Rect2(52, 20, 44, 17)

func _show_restart_box(vb: VBoxContainer) -> void:
	if _game_over_restart or not is_instance_valid(vb):
		return
	_game_over_restart = true
	# No index-0 pixel anywhere in the box, so nothing to make see-through.
	var art: ImageTexture = _load_panel_texture("RESTART.IMG")
	if art == null:
		# No archive art: the plain buttons the other screens use. The
		# wording is the box's own.
		vb.add_child(_game_over_button("RESTART MISSION", _restart_mission))
		vb.add_child(_game_over_button("MAIN MENU", _game_over_menu))
		return
	var s := RESTART_BOX_SCALE
	var box := Control.new()
	box.custom_minimum_size = Vector2(96.0 * s, 37.0 * s)
	var pic := TextureRect.new()
	pic.texture = art
	pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(pic)
	box.add_child(_restart_hotspot(RESTART_YES_RECT, s, _restart_mission))
	box.add_child(_restart_hotspot(RESTART_NO_RECT, s, _game_over_menu))
	vb.add_child(box)

## A transparent button over the box's baked YES / NO caption, lit while
## the pointer is on it (the DOS box draws a RESTBTN.CFA frame there).
func _restart_hotspot(rect: Rect2, s: float, cb: Callable) -> Button:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.position = rect.position * s
	b.size = rect.size * s
	var empty := StyleBoxEmpty.new()
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.9, 0.95, 1.0, 0.18)
	b.add_theme_stylebox_override("normal", empty)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", empty)
	b.pressed.connect(cb)
	return b

## RESTART MISSION — the box's YES (FUN_0011d09e, which calls
## FUN_0011d3b0). DOS replays the WHOLE mission from its FIRST map and
## through the briefing, with the marker set back to 0, the objective
## counter re-read from the script and every map's saved state deleted
## (the tfs_swap.* files go, one INT 21h unlink each); the player comes
## back as the mission-start snapshot has him. Nothing of the attempt that
## failed survives — which is the whole point, and why there is no
## respawn.
##
## The wipe is the save machinery's: _install_save with a session that
## holds nothing but the map and that snapshot empties `_map_state`, the
## previous-map register, the zone phases, the pending marker set and the
## stats, and puts `_mission_key` back to -1 so _ensure_mission_script
## reads the script and the counter again. _clear_level, which runs first,
## takes down the mission scene with its zones, `_zone_state` and
## `_phases`, and clears `_seen_meshes`, `_mission_hostiles` and
## `_prev_map_name`.
func _restart_mission() -> void:
	if _level_busy:
		return
	var start: String = _mission_start_map
	if not _maps.has(start):
		start = _level_name()          # a loose map: replay the map itself
	if not _maps.has(start):
		_game_over_menu()
		return
	print("[skynet] RESTART MISSION: %s%s" % [start, "" if _mission_start_state.is_empty()
		else " with the state the mission was entered with"])
	_dismiss_end_screen()
	await _change_level(start, true, true, {
		"map": start,
		"player": _mission_start_state,
		"mission_start_player": _mission_start_state,
		"mission_start_map": start,
		# Read by _change_level alone: a restart is not a loaded game and
		# must not say GAME LOADED. It is never written to a file.
		"restart": true,
	})

## Clear the end screen and load `map_name` (the next campaign mission).
func _advance_to(map_name: String) -> void:
	if _level_busy:
		return
	_dismiss_end_screen()
	var idx: int = _maps.find(map_name)
	if idx >= 0:
		_map_idx = idx
		_load_current()

## The end screen goes, and its hold on the pause with it.
func _dismiss_end_screen() -> void:
	if _game_over != null:
		if is_instance_valid(_game_over):
			_game_over.queue_free()
		_game_over = null
	_game_over_box = null
	_game_over_failed = false
	_game_over_restart = false
	PauseState.pop(&"end_screen")

## Show the pre-mission briefing for a mission "main" map, if one exists.
## Returns true when a briefing screen is up — the caller then defers the
## level load to the briefing's BEGIN button. Returns false (load the
## level now) for sub-maps or maps without a briefing file.
func _maybe_show_briefing(map_name: String) -> bool:
	# A mission starts on its CAMPAIGN_SEQUENCE map — MAP.252 for mission
	# 5, not a map ending in 0 (that rule skipped its briefing).
	if not _campaign_maps.has(map_name):
		return false                        # sub-map / not a mission start
	var sfx: int = _mission_of(map_name)
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"),
			SkynetPaths.variant):
		return false
	var txt := bsa.read("%03d.TXT" % sfx)
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
	var pal_ui := Palette.parse(SkynetPaths.ui_palette_bytes())
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
		var intro := bsa.read("BRIEF%03d.IMG" % map_num)
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
		@warning_ignore("integer_division")
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

	# Paused, with a cursor for the tabs — the screen after a won mission
	# used to come up with the mouse still captured.
	PauseState.push(&"briefing")
	if not get_viewport().size_changed.is_connected(_briefing_layout):
		get_viewport().size_changed.connect(_briefing_layout)
	_briefing_layout()
	_briefing_show_page(0)

## A TextureRect that stretches `tex` to its anchored rect; if `tex` is
## missing it falls back to a flat dark-teal fill so the band still reads.
func _br_texrect(tex: Variant) -> TextureRect:
	var rect := TextureRect.new()
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if tex != null:
		rect.texture = tex
	else:
		var fill := ColorRect.new()
		fill.color = Color(0.10, 0.16, 0.16)
		fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.add_child(fill)
	return rect

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
		_change_level(m, false, false)

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
		["SHOTS HIT-RATIO:", StatsLib.pct(Stats.hits, Stats.shots)],
		["ENEMIES DESTROYED:", StatsLib.pct(Stats.kills, Stats.enemies)],
		["HIT-RATIO TOTAL:", StatsLib.pct(Stats.total_hits, Stats.total_shots)],
		["ENEMIES TOTAL:", StatsLib.pct(Stats.total_kills, Stats.total_enemies)],
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

func _briefing_teardown() -> void:
	PauseState.pop(&"briefing")
	if get_viewport().size_changed.is_connected(_briefing_layout):
		get_viewport().size_changed.disconnect(_briefing_layout)
	_briefing_pages = []
	_briefing_text = null
	_briefing_scroll = null
	_briefing_scene = null
	_briefing_pending_map = ""
	if _briefing_overlay != null:
		_briefing_overlay.queue_free()
		_briefing_overlay = null

## What the end screen offers, for the keyboard: Enter/Space take the
## first choice — YES in the RESTART MISSION box, or the next mission.
## Esc is NO, and only once the box is up; under the banner it does
## nothing, as it did before (2026-09-05, "namiesto ďalšej misie menu").
var _game_over_next: String = ""
## This end screen is a death (FAILED.IMG), and the RESTART box under it
## is up.
var _game_over_failed: bool = false
var _game_over_restart: bool = false
## The banner's own column — where the RESTART box is put when its wait
## is up, or when Enter skips it.
var _game_over_box: VBoxContainer = null

func _game_over_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 58)
	b.add_theme_font_size_override("font_size", 24)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _game_over_menu() -> void:
	_return_to_menu()

## Enter / Space on the end screen: its first choice. Under the banner
## that is the box itself — the wait is skippable, as the won mission's
## is.
func _end_screen_accept() -> void:
	if _game_over == null:
		return
	if _game_over_restart:
		_restart_mission()
	elif _game_over_failed:
		_show_restart_box(_game_over_box)
	elif _game_over_next != "":
		_advance_to(_game_over_next)
	else:
		_game_over_menu()

## Esc: NO in the RESTART MISSION box — the main menu (FUN_0011d09e treats
## it as the NO button). Before the box is up it does nothing.
func _end_screen_cancel() -> void:
	if _game_over != null and _game_over_restart:
		_game_over_menu()

func _clear_level() -> void:
	# The hostile counter belongs to the map being torn down.
	_mission_hostiles = 0
	_seen_meshes.clear()
	if _automap != null and is_instance_valid(_automap):
		_automap.call("close_map")
	_mission_done = true
	if _current_level == null:
		_teardown_mission()
		return
	# A mission scene snapshots its zones itself, the active one with its
	# water, and it holds every zone's branches under itself, so its own
	# tear-down takes them all; the frees below then find nothing left.
	if _mission == null:
		_save_map_state()
	_teardown_mission()
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
	if _current_level.behaviour and is_instance_valid(_current_level.behaviour):
		_current_level.behaviour.queue_free()
	if _water != null and is_instance_valid(_water):
		_water.queue_free()
	_water = null
	for scenery in [_overlay, _occluders]:
		if scenery != null and is_instance_valid(scenery):
			scenery.queue_free()
	_overlay = null
	_occluders = null
	_water_target = INF
	if is_instance_valid(player):
		player.water_level = INF
		player.border_boxes = []
	_current_level = null

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: int = event.keycode
	if _game_over != null and is_instance_valid(_game_over):
		# The end screen has the keyboard (its Enter/Space button does the
		# work — this node is paused under it).
		get_viewport().set_input_as_handled()
		return
	# Esc, ~ and the rest belong to an overlay that is up: its own screens
	# (menu.gd, the console, the automap) and the deathmatch chat box take
	# them in _input / _unhandled_input. In single player this node is
	# paused under them anyway; a network game is never paused, and this
	# handler used to eat the Esc that should have closed the chat box or
	# stepped back through the Esc menu. Nothing opens mid level change.
	if _level_busy or PauseState.is_paused() \
			or (_dm != null and bool(_dm.get("_chat_open"))):
		return
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
		return                              # no saves in a match
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
			# Back to the view — unless something else still has the cursor.
			if is_instance_valid(player) and player.has_method("_capture") \
					and not PauseState.mouse_wanted():
				player.call("_capture", true))
	_automap.call("show_map", self, _current_level, player, _seen_meshes)

func _return_to_menu() -> void:
	PauseState.reset()
	Net.leave()
	get_tree().change_scene_to_file("res://scenes/menu.tscn")

## --- In-game menu, console, cheats -----------------------------------------

## (The overlays free the mouse through PauseState.push, which lets the
## player's own capture go.)
func open_pause_menu() -> void:
	if _pause == null or _current_level == null:
		return
	_pause.open()

func close_pause_menu() -> void:
	if _pause != null:
		_pause.close()

func open_console(preset: String = "") -> void:
	if _console == null:
		return
	if _pause != null and _pause.is_open:
		_pause.close()
	_console.open(preset)
	_refresh_net_input_lock()

## Network game: the tree never pauses, so the player's controls stop
## instead while dead, not yet spawned, chatting or while an overlay (Esc
## menu, console) has the keyboard — and come back when the last of those
## goes. pause_menu.gd and the console's `closed` call this too.
func _refresh_net_input_lock() -> void:
	if not Net.active or _dm == null or not is_instance_valid(player):
		return
	var dead: bool = bool(_dm.get("_dead_local")) or not bool(_dm.get("_spawned"))
	player.set("input_locked", dead or bool(_dm.get("_chat_open")) or PauseState.is_paused())

## State the CHEATS page mirrors on its toggle buttons.
func cheat_state() -> Dictionary:
	return {
		"willnotstop": bool(player.get("god_mode")) if is_instance_valid(player) else false,
		"noclip": bool(player.noclip) if is_instance_valid(player) else false,
	}

## Every word run_command answers to — the console's Tab completion.
const COMMAND_NAMES: Array = [
	"ammo", "armor", "arnold", "bake", "cbane", "boom", "bots", "brightness", "killall", "wait", "floormap", "wallmap", "walkto", "movers", "what",
	"cheats", "class", "counters", "drop", "dump", "enemies", "exit", "fly",
	"gamma", "give", "god", "heal", "health", "help", "hp", "illbeback", "load",
	"map", "maps", "menu", "moon", "music", "nextlevel", "nitrous", "noclip",
	"objectives", "occlusion", "options", "pause", "players", "pos", "quit",
	"rebake", "save", "secondary", "shoot", "showspawns",
	"slugs", "speed", "superuzi", "surgery", "throw", "tp", "tpveh", "use", "version",
	"weapon", "where", "who", "whoami", "win", "look", "bodyat", "collfaces", "aim",
	"zone", "zones",
]

const HELP_TEXT := """[b]commands[/b]
  help · cheats · version · maps · map <MAP.NNN|nnn> · pos · tp x y z
  god [on|off] · noclip [on|off] · give <all|super|slot|name> · ammo
  health [n] · armor [0-100] · speed [x] · nextlevel · win · enemies
  use (action key) · objectives (what the mission still wants)
  music [0-100|off|t200|title] · save [slot] · load [slot] · menu · quit
  where (position, view and what the level costs) · bake [all]
  zone · zones [show|all|hide] (the mission scene's zones, when one is up)"""

const CHEATS_TEXT := """[b]DOS cheat codes[/b] (CHEAT.PRS, typed after Alt+\\ in the original)
  superuzi · arnold (all weapons) · slugs (ammo) · surgery (health+armor)
  willnotstop (immortal) · nitrous (faster) · illbeback (next level)
  showspawns (list enemies) · whoami · version · win"""

## What the console refuses in a network game: the cheats and everything
## that changes the world or the player beyond what playing does — it
## replicates to the match (and `map` / `load` would tear the arena down).
## Information, the view and the local settings stay. A few only refuse
## with arguments: `health` alone reads the health, `health 500` sets it.
const NET_REFUSED: Array = [
	"map", "tp", "tpveh", "aim", "god", "willnotstop", "csej", "noclip", "fly",
	"arnold", "cskydere", "superuzi", "cskyder", "give", "slugs", "ammo", "ckugler",
	"surgery", "cfalck", "heal", "nitrous", "churtig", "illbeback", "cbane", "nextlevel",
	"drop", "bake", "rebake", "walkto", "killall", "boom", "moon", "shoot", "weapon",
	"win", "cslut", "save", "load",
]
const NET_REFUSED_WITH_ARGS: Array = ["health", "hp", "armor", "speed"]

## Text from outside the game's own strings (player names, typed words,
## the OS user name) for a BBCode reply: "[" is shown, never obeyed.
static func _bb(s: String) -> String:
	return s.replace("[", "[lb]")

## Console / cheat-menu command line. Returns the reply (BBCode ok).
func run_command(line: String) -> String:
	var parts: PackedStringArray = line.strip_edges().split(" ", false)
	if parts.is_empty():
		return ""
	var cmd: String = parts[0].to_lower()
	var args: PackedStringArray = parts.slice(1)
	var p := player if is_instance_valid(player) else null
	if Net.active and (NET_REFUSED.has(cmd) or (NET_REFUSED_WITH_ARGS.has(cmd) and not args.is_empty())
			or ((cmd == "throw" or cmd == "secondary") and not args.is_empty() and args[0].to_lower() == "now")):
		return "'%s' is not allowed in a network game" % _bb(cmd)
	match cmd:
		"help", "?":
			return HELP_TEXT
		"cheats":
			return CHEATS_TEXT
		"version", "cversion":
			return "SkyNET Godot port — Godot %s" % Engine.get_version_info().get("string", "?")
		"whoami":
			return "%s — map %s" % [_bb(OS.get_environment("USERNAME")), _level_name()]
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
				return "no such map: %s" % _bb(want)
			if _level_busy:
				return "a level change is already running"
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
		"tpveh":
			# Agent aid: stand off a parked deathmatch vehicle and look at
			# it. Their spots are shuffled every round, so a screenshot run
			# cannot be told the coordinates in advance.
			# `tpveh [n] [distance]`.
			if p == null:
				return "no player"
			var vl: Array = get_tree().get_nodes_in_group("dm_vehicle")
			if vl.is_empty():
				return "no parked vehicles (is this a deathmatch?)"
			var vn: int = clampi(int(args[0]) if args.size() > 0 and args[0].is_valid_int() else 0,
				0, vl.size() - 1)
			var away: float = float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 420.0
			var vp3: Vector3 = (vl[vn] as Node3D).global_position
			var stand := vp3 + Vector3(away * 0.7, 150.0, away * 0.7)
			p.set_spawn(stand - Vector3(0.0, EYE_HEIGHT, 0.0), p.rotation.y, false)
			p.noclip = true
			var to: Vector3 = vp3 - stand
			p.set_view(atan2(-to.x, -to.z), asin(clampf(to.normalized().y, -1.0, 1.0)))
			return "vehicle %d of %d at %s" % [vn, vl.size(), vp3]
		"aim":
			# Agent aid: turn the jeep's turret (degrees, relative to the car)
			# - the view swings across the car's own frame.
			if p == null or args.is_empty() or not args[0].is_valid_float():
				return "usage: aim yaw [pitch]"
			p.set("_aim_yaw", deg_to_rad(float(args[0])))
			if args.size() > 1 and args[1].is_valid_float():
				p.set("_aim_pitch", deg_to_rad(float(args[1])))
			return "turret yaw %s" % args[0]
		"collfaces":
			# Agent aid: the COLLISION triangles of every mesh named NAME whose
			# centre lies in the box x0,z0,x1,z1 — world vertices and the normal
			# of the winding. A one-sided DOS face the renderer culls still
			# collides from behind (backface_collision); this finds it.
			if _current_level == null or _current_level.entities == null or args.size() < 2:
				return "usage: collfaces NAME x0,z0,x1,z1"
			var want: String = args[0].to_upper()
			var bxs: PackedStringArray = args[1].split(",")
			if bxs.size() < 4:
				return "usage: collfaces NAME x0,z0,x1,z1"
			var x0: float = minf(float(bxs[0]), float(bxs[2]))
			var x1: float = maxf(float(bxs[0]), float(bxs[2]))
			var z0: float = minf(float(bxs[1]), float(bxs[3]))
			var z1: float = maxf(float(bxs[1]), float(bxs[3]))
			var shown: int = 0
			for mi in _current_level.entities.get_children():
				if not (mi is MeshInstance3D) or String(mi.get_meta("mesh_name", mi.name)).to_upper() != want:
					continue
				for bd in mi.get_children():
					for cs in bd.get_children():
						if not (cs is CollisionShape3D) or not ((cs as CollisionShape3D).shape is ConcavePolygonShape3D):
							continue
						var cxf: Transform3D = (cs as CollisionShape3D).global_transform
						var tri: PackedVector3Array = ((cs as CollisionShape3D).shape as ConcavePolygonShape3D).get_faces()
						for ti in range(0, tri.size() - 2, 3):
							var va: Vector3 = cxf * tri[ti]
							var vb: Vector3 = cxf * tri[ti + 1]
							var vc: Vector3 = cxf * tri[ti + 2]
							var cen: Vector3 = (va + vb + vc) / 3.0
							if cen.x < x0 or cen.x > x1 or cen.z < z0 or cen.z > z1:
								continue
							var nrm: Vector3 = (vb - va).cross(vc - va).normalized()
							@warning_ignore("integer_division")
							print("[collfaces] %s @%s tri %d: %s %s %s  n=%s" % [want, (mi as Node3D).global_position.snapped(Vector3.ONE),
								ti / 3, va.snapped(Vector3.ONE), vb.snapped(Vector3.ONE), vc.snapped(Vector3.ONE), nrm.snapped(Vector3(0.01, 0.01, 0.01))])
							shown += 1
							if shown >= 60:
								return "60 shown (cut)"
			return "%d collision triangles" % shown
		"bodyat":
			# Agent aid: every collider a player-sized body (radius + safe
			# margin) standing with its feet at x y z overlaps — "what exactly
			# am I stuck on", with the shape type and where a box really is.
			if p == null or args.size() < 3:
				return "usage: bodyat x y z [radius]"
			var feet := Vector3(float(args[0]), float(args[1]), float(args[2]))
			var pcs: CollisionShape3D = p.get_node_or_null("CollisionShape3D")
			var body: CapsuleShape3D = pcs.shape as CapsuleShape3D
			var cap := CapsuleShape3D.new()
			cap.radius = float(args[3]) if args.size() > 3 else body.radius + float(p.get("safe_margin"))
			cap.height = body.height + float(p.get("safe_margin"))
			var bq := PhysicsShapeQueryParameters3D.new()
			bq.shape = cap
			bq.transform = Transform3D(Basis(), feet + Vector3(0.0, pcs.position.y + 4.0, 0.0))
			bq.collision_mask = p.collision_mask
			bq.exclude = [p.get_rid()]
			var hits: Array = get_world_3d().direct_space_state.intersect_shape(bq, 16)
			if hits.is_empty():
				return "free (radius %.0f)" % cap.radius
			var found := PackedStringArray()
			for h in hits:
				var hc = h.get("collider")
				if not (hc is Node):
					continue
				var hpar: Node = (hc as Node).get_parent()
				var hname: String = String(hpar.get_meta("mesh_name", hpar.name)) if hpar != null else String((hc as Node).name)
				var kinds := PackedStringArray()
				for sc in (hc as Node).get_children():
					if sc is CollisionShape3D and (sc as CollisionShape3D).shape != null:
						var sh: Shape3D = (sc as CollisionShape3D).shape
						var k: String = sh.get_class().replace("Shape3D", "")
						if sh is BoxShape3D:
							k += " %s at %s" % [(sh as BoxShape3D).size.snapped(Vector3.ONE), (sc as CollisionShape3D).global_position.snapped(Vector3.ONE)]
						kinds.append(k)
				found.append("%s [%s] layer %d" % [hname, ", ".join(kinds), (hc as CollisionObject3D).collision_layer if hc is CollisionObject3D else 0])
			return "overlaps (radius %.0f): %s" % [cap.radius, "; ".join(found)]
		"look":
			# Agent aid: turn the view, in degrees. After `throw now`, a `tp`
			# and a `look` put the camera beside the rocket already in flight
			# — from behind, its smoke is seen end-on and says nothing.
			if p == null or args.is_empty() or not args[0].is_valid_float():
				return "usage: look yaw [pitch]"
			# fly_camera re-applies `_yaw` every frame; rotation.y alone
			# lasted exactly one frame.
			p.set("_yaw", deg_to_rad(float(args[0])))
			p.rotation.y = deg_to_rad(float(args[0]))
			if args.size() > 1 and args[1].is_valid_float():
				p.set("_pitch", deg_to_rad(float(args[1])))
			return "looking yaw %.1f pitch %.1f" % [rad_to_deg(p.rotation.y), rad_to_deg(float(p.get("_pitch")))]
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
				return "unknown weapon '%s' (slot 0-12 or a name)" % _bb(" ".join(args))
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
			if _level_busy:
				return "a level change is already running"
			_close_overlays()
			_advance_to(nxt)
			return "next mission: %s" % nxt
		"throw", "secondary":
			if p == null:
				return "no player"
			if not args.is_empty() and args[0].to_lower() == "next":
				p.cycle_throwable(1)
			elif not args.is_empty() and args[0].is_valid_int():
				# `throw 1`..`throw 5` — the F-keys by number, for a run with
				# no keyboard of its own (--console=).
				var n: int = clampi(int(args[0]), 1, 5) - 1
				p.select_throwable(int(p.THROW_KEYS.get(KEY_F1 + n, -1)))
			elif not args.is_empty() and args[0].to_lower() == "now":
				# Like `shoot`: a leftover cooldown (entering the jeep sets
				# one) must not swallow the agent's shot silently.
				p.set("_fire_cd", 0.0)
				p.set("_throw_cd", 0.0)
				p.call("_throw_secondary")
			return "secondary: %s x%d" % [p.secondary_name, p.secondary_ammo]
		"drop":
			# Agent aid: spawn a crate drop at the player's feet.
			if p == null or _current_level == null:
				return "no level"
			var dt: int = int(args[0]) if args.size() > 0 and args[0].is_valid_int() else 3
			var side: float = float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 0.0
			var b := Basis(Vector3.UP, p.rotation.y)
			var at: Vector3 = p.global_position - b.z * 200.0 + b.x * side
			# Over 1000 it is a sprite index, not a drop-table type.
			var made: Node = LevelLoader.spawn_item(_current_level, at, dt) if dt > 1000 				else LevelLoader.spawn_drop(_current_level, at, dt)
			if made == null:
				return "drop %d produced nothing" % dt
			return "dropped %s at %s" % [made.name, made.position]
		"where", "dump":
			# Everything needed to reproduce a report: where the player
			# stands, what he is looking at, and what the level is made
			# of right now. Goes to the log as well as the console.
			var lines: Array = []
			if p != null:
				var gp: Vector3 = p.global_position
				lines.append("map %s  pos %.0f %.0f %.0f  yaw %.1f  pitch %.1f" % [
					_level_name(), gp.x, gp.y, gp.z,
					rad_to_deg(p.rotation.y),
					rad_to_deg(p.get_node("Camera3D").rotation.x) if p.has_node("Camera3D") else 0.0])
				lines.append("health %.0f  armour %.0f%%  weapon %s  vehicle %d" % [
					float(p.health), float(p.armor) * 100.0,
					str(p.get("weapon_name")), int(p.vehicle)])
				lines.append("relaunch:  --map=%s --pos=%.0f,%.0f,%.0f --yaw=%.0f --noclip --god"
					% [_level_name(), gp.x, gp.y + 75.0, gp.z, rad_to_deg(p.rotation.y)])
			lines.append("fps %d  draw calls %d  primitives %d  video mem %.1f MB" % [
				Engine.get_frames_per_second(),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
			lines.append("detail %s  baked %s  enemies %d" % [
				Settings.LEVEL_NAMES[Settings.detail],
				"yes" if _current_level != null and _current_level.baked else "no",
				get_tree().get_nodes_in_group("enemy").size()])
			lines.append("occlusion culling %s  objects %d  shadow draws %d" % [
				"on" if get_viewport().use_occlusion_culling else "off",
				Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
			for l in lines:
				print("[where] %s" % l)
			return "
".join(lines)
		"occlusion", "occ":
			# Debug aid: the baked occluders are what stops the engine
			# submitting the valley behind the ridge. Toggling them makes
			# the difference measurable with `where`.
			var vp := get_viewport()
			if not args.is_empty():
				vp.use_occlusion_culling = args[0].to_lower() in ["on", "1", "true"]
			return "occlusion culling %s" % ("on" if vp.use_occlusion_culling else "off")
		"bake", "rebake":
			# Rebuild the baked level scene (scripts/level_scene.gd) for
			# the map that is up, or for every map with `bake all`. The
			# conversion does this on the first run; this is for after a
			# change to the bake or to a MAP.
			var which: Array = _maps.duplicate() if (not args.is_empty() 				and args[0].to_lower() == "all") else [_level_name()]
			var t0: int = Time.get_ticks_msec()
			var made: int = 0
			for mn in which:
				var sp: String = LevelScene.scene_path(String(mn))
				if not sp.is_empty() and ResourceLoader.exists(sp):
					DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))
				if not Assets.level_scene(String(mn)).is_empty():
					made += 1
				await get_tree().process_frame
			var msg: String = "baked %d/%d level scenes in %.1f s" % [made,
				which.size(), (Time.get_ticks_msec() - t0) / 1000.0]
			print("[bake] %s" % msg)
			if which.size() == 1:
				_load_current()
			return msg
		"pause", "options":
			# Agent aid / quick access: open the in-game menu, on the
			# OPTIONS page when asked for.
			open_pause_menu()
			if cmd == "options" and _pause != null:
				_pause.call("_show", "options")
			return "menu open"
		"zone":
			# Which zone of a mission scene the game is in. `tp` stays a
			# WORLD teleport — a zone's own coordinates are the DOS ones,
			# and the zone origin is what stands between them.
			return _zone_report(false)
		"zones":
			# Agent aid: `zones show` stands every zone up at once — only
			# their layers keep them apart then (zone_layers.gd) — `zones
			# all` lets the camera draw every layer as well, which is what
			# the editor shows, and `zones hide` puts it back.
			if args.size() > 0 and _mission != null:
				var want: String = String(args[0])
				if want in ["show", "all", "hide"]:
					for zn in _zones:
						var zon: Node3D = (_zones[zn] as Dictionary)["node"]
						zon.visible = want != "hide" or String(zn) == _active_zone
					if camera != null:
						camera.cull_mask = (1 << 20) - 1 if want == "all" else ZoneLayers.cull_mask()
					return "zones %s: every zone %s, camera cull mask %x" % [want,
						"drawn" if want != "hide" else "but the active one dark", camera.cull_mask]
			return _zone_report(true)
		"use":
			# The action key, from a script: --console="tp …;use".
			if p == null:
				return "no player"
			_on_use_pressed(p.global_position)
			return "use at %s" % p.global_position
		"objectives", "obj":
			var todo: Array = []
			for i in _mission_texts.size():
				var sec: Array = _mission_texts[i]
				for j in range(int(_objective_cursor[i]), sec.size()):
					todo.append("[M%d] %s" % [i + 1, sec[j]])
			return "mission %d, %d left:\n%s" % [_mission_key,
				_objectives_left, "\n".join(todo)]
		"wait":
			# Agent aid: let the world run before the next console command
			# (a gate needs a tick, a door a second to swing).
			var secs: float = float(args[0]) if args.size() > 0 and args[0].is_valid_float() else 1.0
			await get_tree().create_timer(clampf(secs, 0.0, 30.0), true, false, true).timeout
			return "waited %.1f s" % secs
		"what":
			# Agent aid: what is under the crosshair — node, mesh, material,
			# albedo texture. "that surface is the wrong colour" reports used
			# to need a texture hunt.
			if camera == null:
				return "no camera"
			var space := get_world_3d().direct_space_state
			if space == null:
				return "no physics world"
			var from: Vector3 = camera.global_position
			if args.size() > 0 and args[0] == "grid":
				# `what grid`: 7x7 rays over the view — every material on
				# screen at once, with its albedo texture.
				var vp: Vector2 = get_viewport().get_visible_rect().size
				var seen: Dictionary = {}
				for gy in 7:
					for gx in 7:
						var sp := Vector2(vp.x * (float(gx) + 0.5) / 7.0, vp.y * (float(gy) + 0.5) / 7.0)
						var o: Vector3 = camera.project_ray_origin(sp)
						var d: Vector3 = camera.project_ray_normal(sp)
						var gq := PhysicsRayQueryParameters3D.create(o, o + d * 6000.0)
						gq.collision_mask = ZoneLayers.world_mask()
						gq.collide_with_areas = true
						if is_instance_valid(player) and player is CollisionObject3D:
							gq.exclude = [(player as CollisionObject3D).get_rid()]
						var gh := space.intersect_ray(gq)
						if not gh.has("collider"):
							continue
						var gn: Node = gh["collider"] as Node
						var gm: MeshInstance3D = null
						var gw: Node = gn
						while gw != null and gm == null:
							if gw is MeshInstance3D:
								gm = gw
							gw = gw.get_parent()
						if gm == null or gm.mesh == null:
							continue
						for si in gm.mesh.get_surface_count():
							var sm: Material = gm.get_active_material(si)
							if sm is BaseMaterial3D and (sm as BaseMaterial3D).albedo_texture != null:
								var tp: String = (sm as BaseMaterial3D).albedo_texture.resource_path.get_file()
								seen["%s|%s" % [gm.name, tp]] = true
				var names: Array = seen.keys()
				names.sort()
				return "%d mesh/texture pairs in view:\n  %s" % [names.size(), "\n  ".join(names)]
			var dir: Vector3 = -camera.global_transform.basis.z
			var rq := PhysicsRayQueryParameters3D.create(from, from + dir * 6000.0)
			rq.collision_mask = ZoneLayers.world_mask()
			rq.collide_with_areas = true          # enemy hitboxes are Area3D
			if is_instance_valid(player) and player is CollisionObject3D:
				rq.exclude = [(player as CollisionObject3D).get_rid()]
			var hit := space.intersect_ray(rq)
			if not hit.has("collider"):
				return "nothing within 6000 u"
			var node: Node = hit["collider"] as Node
			var mi: MeshInstance3D = null
			var walk: Node = node
			while walk != null and mi == null:
				if walk is MeshInstance3D:
					mi = walk
				walk = walk.get_parent()
			var out: String = "hit %s at %s (%.0f u)" % [node.name, str(hit["position"]).left(40),
				from.distance_to(hit["position"])]
			if mi == null:
				return out + " — no mesh"
			out += "\n  mesh %s (%s), %d surfaces" % [mi.name,
				mi.mesh.resource_path.get_file() if mi.mesh else "-",
				mi.mesh.get_surface_count() if mi.mesh else 0]
			for si in (mi.mesh.get_surface_count() if mi.mesh else 0):
				var mat: Material = mi.get_active_material(si)
				var tex_path: String = "-"
				var col: String = "-"
				if mat is BaseMaterial3D:
					var bm: BaseMaterial3D = mat
					tex_path = bm.albedo_texture.resource_path if bm.albedo_texture else "(no texture)"
					col = str(bm.albedo_color)
				out += "\n  surface %d: %s albedo %s tex %s" % [si,
					mat.get_class() if mat else "no material", col, tex_path]
			return out
		"movers":
			# Agent aid: what every mover is doing right now.
			if _current_level == null or _current_level.behaviour == null:
				return "no level"
			return _current_level.behaviour.mover_report()
		"walkto":
			# Agent aid: drive the player at a point (the --walk driver),
			# after a door has opened or a lift has come down.
			if args.size() < 2:
				return "usage: walkto x z [secs]"
			_walk_route.clear()
			_walk_target = Vector2(float(args[0]), float(args[1]))
			# 15 s, not 6: at the DOS 250 u/s that is the same ~3800 units
			# the old default bought at the port's 600 (2026-09-16).
			_walk_limit = float(args[2]) if args.size() > 2 else 15.0
			_walk_t = 0.0
			_walk_stuck = 0.0
			_walk_best = 1e9
			if is_instance_valid(player):
				player.set("noclip", false)
			return "walking to %s" % _walk_target
		"wallmap":
			# Agent aid: where a player-sized capsule FITS, at one height.
			# The floormap casts a ray down and cannot see a vertical wall
			# whose top is above the ray; this asks the physics world the
			# question the player asks. '.' = free, '#' = blocked.
			if args.is_empty():
				return "usage: wallmap x0,z0,x1,z1,step,y"
			_wallmap(" ".join(args))
			return ""
		"floormap":
			# Agent aid: the --floormap plan, at any moment.
			if args.is_empty():
				return "usage: floormap x0,z0,x1,z1,step,y"
			_floormap(" ".join(args))
			return ""
		"killall":
			# Agent aid: every enemy dies where it stands (state tests).
			var k: int = 0
			for e in get_tree().get_nodes_in_group("enemy"):
				if e.has_method("take_damage"):
					e.take_damage(100000.0)
					k += 1
			return "killed %d" % k
		"boom":
			if not is_instance_valid(player):
				return "no player"
			Explosion.spawn(self, player.global_position + Vector3(0, 60, 0) - player.global_transform.basis.z * 420.0, 220.0)
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
			if _level_busy:
				return "a level change is already running"
			_close_overlays()
			_mission_done = true
			_mission_ended_key = _mission_key
			_show_mission_complete()
			return "mission complete"
		"showspawns", "cfyr", "enemies":
			var lines: Array = []
			for e in get_tree().get_nodes_in_group("enemy"):
				if e is Node3D and is_instance_valid(e):
					var gp: Vector3 = (e as Node3D).global_position
					# The hitbox too: "I had to aim at the exact centre" reports
					# are answered by comparing it with the meshes it covers.
					var hb: String = "-"
					for a in (e as Node3D).get_children():
						if a is Area3D:
							for cs in (a as Area3D).get_children():
								if cs is CollisionShape3D and (cs as CollisionShape3D).shape is BoxShape3D:
									var bs: Vector3 = ((cs as CollisionShape3D).shape as BoxShape3D).size
									hb = "%.0fx%.0fx%.0f at %s" % [bs.x, bs.y, bs.z, str((cs as CollisionShape3D).position.round())]
					lines.append("  %-20s type %3d  at %.0f %.0f %.0f  hitbox %s  hp %.0f" % [
						e.name, int(e.get("_type_id")), gp.x, gp.y, gp.z, hb,
						float(e.get("_health")) if e.get("_health") != null else -1.0])
			return "%d enemies\n%s" % [lines.size(), "\n".join(lines)]
		"counters", "ctal":
			return "hostiles tracked %d, map state for %d maps%s, prev map %s" % [
				_mission_hostiles, _map_state.size(),
				"" if _mission == null else " (outside the mission scene; %d zone overlays waiting)" % _zone_state.size(),
				_prev_map_name if not _prev_map_name.is_empty() else "-"]
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
			var sdata: Dictionary = SaveGame.read(slot)
			if sdata.is_empty():
				return "slot %d: %s" % [slot + 1, _bb(SaveGame.last_error)]
			if _level_busy:
				return "a level change is already running"
			_close_overlays()
			load_from_slot(slot, sdata)
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
				return "music %s" % (_bb(Audio.music_name()) if not Audio.music_name().is_empty() else "failed")
			return "usage: music [0-100 | off | t200 | title]"
		"menu":
			_close_overlays()
			_return_to_menu()
			return ""
		"brightness", "gamma":
			# The DOS gamma, 0.5..1.8.
			if not args.is_empty() and args[0].is_valid_float():
				Settings.set_brightness(float(args[0]))
			return "brightness %.2f" % Settings.brightness()
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
				# Names are the players' own text: escaped, or "[b]" in one
				# restyles the console (the padding is done before escaping).
				rows.append("  %s %3d frags %3d deaths%s" % [_bb("%-16s" % String(r[1])),
					int(r[2]), int(r[3]), "  (bot)" if r[4] else ""])
			return "%d players\n%s" % [rows.size(), "\n".join(rows)]
		"quit", "exit":
			get_tree().quit()
			return ""
	return "unknown command '%s' — try help" % _bb(cmd)

## Console, pause menu and automap all go away before a level change.
func _close_overlays() -> void:
	if _console != null and _console.is_open:
		_console.close()
	if _pause != null and _pause.is_open:
		_pause.close()
	if _automap != null and is_instance_valid(_automap) and bool(_automap.get("open")):
		_automap.call("close_map")

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

	# --- the HUD bar (see _build_hud) ---
	get_viewport().size_changed.connect(_layout_hud)
	_build_hud()
	# (There used to be an on-screen MENU button pinned top-right. Esc
	# opens the same menu and the button sat over the view.)

## The HUD bar for the setting in force: the DOS panel — PANEL0 and every
## DOS draw on it, the 320x200 art, at the bottom of the window at its
## DOS proportion — or, with HI-RES ART on, the modern status bar in the
## corner with the view uncovered. Built at start and again when the
## setting flips.
func _build_hud() -> void:
	if _hud != null:
		_hud.queue_free()
		_hud = null
	_hud_is_dos = not Settings.hires_weapons
	if _hud_is_dos:
		var p: Control = HudPanel.new()
		p.anchor_top = 1.0
		p.anchor_right = 1.0
		p.anchor_bottom = 1.0
		p.call("setup", false)
		_hud = p
	else:
		_hud = HudModern.new()
	_hud_layer.add_child(_hud)
	# A vehicle's own panel (none today) would hide the bar.
	_hud.visible = _hud_mode == 0 or String(VEH_PANELS[clampi(_hud_mode, 0, VEH_PANELS.size() - 1)]).is_empty()
	_layout_hud()

## The clockwise bearing the compass shows, 0..2047: the view's yaw (DOS
## [0x38c94]/[0x38c9c] — the camera, so the jeep's turret) plus the map's
## marker-7 offset; -1 with no camera.
func _hud_bearing() -> int:
	if camera == null or not is_instance_valid(camera):
		return -1
	var lvl_ref = _compass_level.get_ref() if _compass_level != null else null
	if lvl_ref != _current_level:
		_compass_level = weakref(_current_level) if _current_level != null else null
		_compass_north = _compass_offset(_current_level)
	var fwd: Vector3 = -camera.global_transform.basis.z
	# North is -z (DOS +z); turning right (clockwise from above) adds.
	var bearing: float = fposmod(atan2(fwd.x, -fwd.z), TAU)
	return (int(bearing * 2048.0 / TAU) + _compass_north) & 0x7FF

## Marker type 7: the compass offset in degrees at sub+2 (0x12df04),
## clamped 0..359 and turned into 11-bit units.
static func _compass_offset(level: LevelLoader.Level) -> int:
	if level == null or level.map == null:
		return 0
	for e in level.map.entities:
		if (e.flags & 3) == 3 and e.marker_type == 7:
			@warning_ignore("integer_division")
			return (clampi(int(e.exit_map), 0, 359) << 11) / 360
	return 0

## How much of the window bottom the HUD covers — the DOS bar's height,
## 0 while it is hidden or the modern bar (which covers no view) is up.
## The view's projection centre sits in the middle of what is left
## (fly_camera._update_projection).
func hud_height() -> float:
	if _hud == null or not _hud.visible or not _hud_is_dos:
		return 0.0
	return HudPanel.bar_height(get_viewport().get_visible_rect().size.x)

## Keep the DOS bar full-width at its native 8:1 aspect (320:40), and the
## message line in the font and place its HUD wants.
func _layout_hud() -> void:
	var vw: float = get_viewport().get_visible_rect().size.x
	if _hud != null and _hud_is_dos:
		_hud.offset_top = -HudPanel.bar_height(vw)
	_style_status_label(vw)

## The message line (FUN_0012f453): under the DOS HUD it is FONT0004 at
## the panel's pixel scale, palette 0xB3 over a 0x7F shadow one pixel
## down and right, at (4,3) of the 320x200 screen; the modern bar keeps
## the port's FONT0005 line. Rebuilt only when the scale changes.
func _style_status_label(vw: float) -> void:
	if _status_label == null:
		return
	var k: int = maxi(1, int(round(vw / 320.0))) if _hud_is_dos else 0
	if k != _msg_scale:
		_msg_scale = k
		_status_font = _load_fnt("FONT0004.FNT", k) if k > 0 else _load_fnt("FONT0005.FNT", 2)
		if _status_font != null:
			_status_label.add_theme_font_override("font", _status_font)
			_status_label.add_theme_font_size_override("font_size", _status_font.fixed_size)
	if k > 0:
		_status_label.position = Vector2(4.0 * k, 3.0 * k)
		_status_label.add_theme_color_override("font_color", Color8(55, 235, 55))
		_status_label.add_theme_color_override("font_shadow_color", Color8(18, 18, 21))
		_status_label.add_theme_constant_override("shadow_offset_x", k)
		_status_label.add_theme_constant_override("shadow_offset_y", k)
	else:
		_status_label.position = Vector2(8, 36)
		_status_label.add_theme_color_override("font_color", Color(1, 1, 1))
		_status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
		_status_label.add_theme_constant_override("shadow_offset_x", 2)
		_status_label.add_theme_constant_override("shadow_offset_y", 2)

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
func _load_fnt(filename: String, factor: int) -> FontFile:
	var bytes := SkynetPaths.read_bytes(SkynetPaths.gamedata_path(filename))
	if bytes.is_empty():
		push_warning("HUD font missing: %s" % filename)
		return null
	return FntFont.build(bytes, factor)

## Load PANEL0.IMG (the on-foot HUD bar) as an ImageTexture, or null.
## `nm` picks another panel: PANEL1.IMG (jeep cockpit) / PANEL2.IMG
## (HK cockpit) are full 320×200 frames with the windscreen as index 0.
## `hires`: the 640x480 set of MDMDHRES.BSA — twice the 320x200 art's
## resolution (CROSHAIR 120x120, WELLDONE 378x42, PANEL0 640x96 …) —
## when that archive has the image; the 320x200 one otherwise.
func _load_panel_texture(nm: String = "PANEL0.IMG", transparent0: bool = false,
		hires: bool = false) -> ImageTexture:
	var panel_bytes := PackedByteArray()
	for arc in (["MDMDHRES.BSA", "MDMDIMGS.BSA"] if hires else ["MDMDIMGS.BSA"]):
		var bsa := BSAReader.new()
		if not bsa.open(SkynetPaths.gamedata_path(arc), SkynetPaths.variant):
			continue
		panel_bytes = bsa.read(nm)
		bsa.close()
		if not panel_bytes.is_empty():
			break
	var pal_bytes := SkynetPaths.palette_bytes()
	var palette := Palette.parse(pal_bytes)
	if palette.is_empty() or panel_bytes.is_empty():
		return null
	return ImgFile.parse(panel_bytes, palette, transparent0)

## --- Vehicle HUD -------------------------------------------------------
## In a vehicle DOS keeps the foot bar (PANEL0) and draws the vehicle's
## own model round the eye (FlyCamera._attach_cockpit). PANEL1/PANEL2.IMG
## are in the archive, but the executable never loads them - panel0.img
## is its only panel name - and the full-screen dashboards the port showed
## since 2026-09-03 were a guess the DOS screenshots disproved. The
## overlay machinery stays for a panel name, should one ever turn up.
const VEH_PANELS: Array = ["", "", ""]
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
	if _hud != null:
		_hud.visible = v == 0 or String(VEH_PANELS[clampi(v, 0, VEH_PANELS.size() - 1)]).is_empty()
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
	if v <= 0 or v >= VEH_PANELS.size() or String(VEH_PANELS[v]).is_empty():
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
		_veh_labels["armor"].text = "%d" % int(round(float(player.armor_gauge()) * 100.0))
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
