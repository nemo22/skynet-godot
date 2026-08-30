## Main scene controller. Browses MAP.* in MDMDMAP2.BSA, loads a level
## via LevelLoader, and lets the user cycle through maps.
##
## Key bindings (in addition to the global F1..F5 scene switch):
##   PageUp / [ / P     previous map
##   PageDown / ] / N   next map
##   Home / End         first / last map
##   ESC                quit

extends Node3D

const LevelLoader := preload("res://scripts/level_loader.gd")
const BSAReader   := preload("res://scripts/loaders/bsa_reader.gd")
const ImgFile     := preload("res://scripts/loaders/img_file.gd")
const Palette     := preload("res://scripts/loaders/palette.gd")
const Briefing    := preload("res://scripts/loaders/briefing.gd")
const FntFont     := preload("res://scripts/loaders/fnt_font.gd")

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
	_build_status_ui()
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

static func _make_box_collision(mi: MeshInstance3D) -> void:
	var aabb: AABB = mi.mesh.get_aabb()
	var sb := StaticBody3D.new()
	sb.name = mi.name + "_col"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size
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

## --pos (camera position, like the DOS markers) / --yaw / --pitch /
## --noclip: place the player for an automated run.
func _cli_place() -> void:
	if _cli.has("pos"):
		player.set_spawn(_cli_vec3(String(_cli["pos"])) - Vector3(0.0, EYE_HEIGHT, 0.0),
			player.rotation.y, false)
	if _cli.has("noclip") or _cli.has("pos"):
		player.noclip = true
		player.velocity = Vector3.ZERO
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
	_cli_place()
	if _cli.has("screenshot"):
		var delay := float(_cli.get("shot-delay", 1.5))
		await get_tree().create_timer(delay).timeout
		# Re-apply the requested view: the first captured mouse event
		# and gravity can drift the camera during the delay.
		_cli_place()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		var path := String(_cli["screenshot"])
		var err := img.save_png(path)
		print("[skynet] screenshot %s (%s) at pos=%s yaw=%.1f pitch=%.1f" % [path, error_string(err),
			player.global_position, rad_to_deg(player.rotation.y), rad_to_deg(player.get("_pitch"))])
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
	if _cli.has("screenshot") or _cli.has("no-briefing"):
		_begin_level(name)
	elif not _maybe_show_briefing(name):
		_begin_level(name)

## Load and show the level geometry for `name` — called directly for
## non-mission maps, or from the briefing's BEGIN button once the player
## has read the mission briefing.
func _begin_level(name: String) -> void:
	_set_status("Loading %s ..." % name)
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
					and level.action.is_solid_mover(c.file_off()))
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
		level.action.space = get_world_3d().direct_space_state
		level.action.player_body = player
		if not player.pickup_message.is_connected(_set_status):
			player.pickup_message.connect(_set_status)
		if not player.use_pressed.is_connected(_on_use_pressed):
			player.use_pressed.connect(_on_use_pressed)
	if level.enemies:  add_child(level.enemies)
	if level.sprites:  add_child(level.sprites)
	if level.sky:
		add_child(level.sky)
		level.sky.position = player.global_position
	_set_sky_fill(level)
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
	_set_status("[%d/%d] %s   %s   meshes=%d   enemies=%d   PgUp/PgDn=switch  click=fly (WASD/QE, Esc=release)"
		% [_map_idx + 1, _maps.size(), name,
		   "outdoor" if level.is_outdoor else "indoor",
		   level.entity_count, level.enemy_count])

	# Mission objective: eliminate every hostile on the map. Only the
	# mission's main map ends the mission — the interiors reached
	# through exits are side areas of the same mission.
	_mission_done = false
	_mission_hostiles = 0
	if _is_campaign_main(name):
		_mission_hostiles = get_tree().get_nodes_in_group("enemy").size()

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

## Return the spawn point, or — if a player-sized capsule there overlaps
## level geometry — the nearest free spot found by searching outward.
func _find_clear_spawn(pos: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return pos
	var shape := CapsuleShape3D.new()
	shape.radius = 26.0
	shape.height = 88.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	for ring in [0.0, 100.0, 200.0, 320.0, 460.0, 640.0]:
		var steps: int = 1 if ring < 1.0 else 12
		for i in steps:
			var a: float = TAU * float(i) / float(steps)
			var p := pos + Vector3(cos(a) * ring, 0.0, sin(a) * ring)
			q.transform = Transform3D(Basis(), p + Vector3(0.0, 60.0, 0.0))
			if space.intersect_shape(q, 1).is_empty():
				if ring > 0.0:
					print("[skynet] spawn nudged %.0fu clear of geometry" % ring)
				return p
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

## Interiors: dim ambient + one OmniLight3D per enabled variant-2
## light, and the cached (unshaded) materials swapped for per-vertex
## shaded duplicates so the lights show. Outdoors stays unlit like DOS.
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
		return
	env.ambient_light_color = INDOOR_AMBIENT
	env.ambient_light_energy = 1.0
	if sun != null:
		sun.visible = false
	var cache: Dictionary = {}
	_shade_recursive(level.entities, cache)
	_shade_recursive(level.enemies, cache)
	if level.sprites != null:
		for s in level.sprites.get_children():
			if s is SpriteBase3D:
				(s as SpriteBase3D).shaded = true
	var n := 0
	for e in level.map.entities:
		if (e.flags & 3) != 2 or e.light_enable <= 0:
			continue
		var l := OmniLight3D.new()
		l.position = Vector3(float(e.x), -float(e.y), -float(e.z))
		l.omni_range = clampf(float(e.light_enable) * LIGHT_RANGE_PER_UNIT, 400.0, 6000.0)
		l.omni_attenuation = 1.0
		l.light_energy = clampf(float(e.light_intensity) / LIGHT_ENERGY_DIV, 0.4, 3.5)
		l.shadow_enabled = false
		level.entities.add_child(l)
		n += 1
	print("[level] interior: %d lights, %d shaded materials" % [n, cache.size()])

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
func _set_sky_fill(level: LevelLoader.Level) -> void:
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	var env: Environment = we.environment
	var fill := Color(0.0, 0.0, 0.0)
	if level.is_outdoor and level.sky != null and level.sky.mesh != null:
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
		env.fog_depth_begin = FOG_BEGIN
		env.fog_depth_end = FOG_END
		env.fog_depth_curve = 1.0
		env.fog_aerial_perspective = 0.0
		env.fog_sky_affect = 0.0

## Pin the sky mesh to the camera position each frame (DOS FUN_00133bbb
## re-centres SKY_SKY.3D on the camera). Orientation stays fixed so the
## moon/stars remain world-anchored as the player looks around.
func _process(delta: float) -> void:
	if _current_level != null and _current_level.sky != null \
			and is_instance_valid(_current_level.sky):
		_current_level.sky.position = camera.global_position
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
		_weapon_label.text = str(player.weapon_name)
		var am: int = int(player.ammo)
		_ammo_label.text = "%d" % am
		_ammo_label.add_theme_color_override("font_color",
			Color(1, 0.4, 0.32) if am <= 0 else Color(0.55, 0.95, 0.62))
		if hp <= 0 and _game_over == null:
			_show_game_over()
	# Mission objective — all hostiles eliminated.
	if _mission_hostiles > 0 and not _mission_done and _game_over == null \
			and get_tree().get_nodes_in_group("enemy").is_empty():
		_mission_done = true
		_show_mission_complete()

## Use key with nothing under the crosshair: fire an armed exit here.
func _on_use_pressed(pos: Vector3) -> void:
	if _current_level != null and _current_level.action != null:
		var a = _current_level.action
		if not a.activate_teleport(pos):
			a.use_nearby(pos)

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
	}

## Re-apply a saved snapshot to a freshly loaded map (DOS MstLoad).
func _apply_map_state(level: LevelLoader.Level, name: String) -> void:
	var snap: Dictionary = _map_state.get(name, {})
	if snap.is_empty():
		return
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
	_show_end_screen("MISSION FAILED", Color(0.9, 0.22, 0.16), true)

func _show_mission_complete() -> void:
	_show_end_screen("MISSION COMPLETE", Color(0.42, 0.92, 0.48),
		false, _next_campaign_map())

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
		next_map: String = "") -> void:
	if _game_over != null:
		return
	var cl := CanvasLayer.new()
	cl.layer = 80
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(cl)
	_game_over = cl
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
			"BRIEFING":
				cb = Callable()                       # active tab — no-op
			_:
				cb = _briefing_tab_unavailable.bind(tname)
		var t := _br_tab(tab[1], ui.get(tab[2]), ui.get(tab[3]),
			tname == "BRIEFING", cb)
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
	btn.mouse_entered.connect(func() -> void: hl.visible = true)
	btn.mouse_exited.connect(func() -> void: hl.visible = active)
	if cb.is_valid():
		btn.pressed.connect(cb)
	holder.add_child(btn)
	return holder

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

## TACTICAL / STATISTICS tab — drawn from the real art, but the view
## behind it is not ported yet, so clicking just flashes a note.
func _briefing_tab_unavailable(tab_name: String) -> void:
	Audio.play_sfx("BUTTON1.RAW")
	_briefing_toast("%s display is not available in this port yet." % tab_name)

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
	# Mission-complete watcher off while the level is torn down and the
	# next one streams in: _begin_level awaits between freeing the old
	# enemies and adding the new ones, and a stale hostile count with an
	# empty "enemy" group would fire a false MISSION COMPLETE — exactly
	# what walking into an interior exit used to do.
	_mission_hostiles = 0
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
	if k == KEY_ESCAPE:
		# While flying (mouse captured) ESC releases the mouse — let
		# fly_camera's _unhandled_input handle that. Otherwise return to
		# the main menu.
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_return_to_menu()
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

func _step_map(d: int) -> void:
	if _maps.is_empty(): return
	_map_idx = (_map_idx + d + _maps.size()) % _maps.size()
	_load_current()

func _return_to_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/menu.tscn")

func _build_status_ui() -> void:
	# Authentic DOS bitmap fonts: FONT0003 (8×8) for the HUD read-outs,
	# FONT0005 (12×13) for status messages. Loaded once, shared by every
	# read-out Label below.
	_hud_font = _load_fnt("FONT0003.FNT", 3)
	_status_font = _load_fnt("FONT0005.FNT", 2)

	var canvas := CanvasLayer.new()
	canvas.layer = 50
	add_child(canvas)
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
	menu_btn.pressed.connect(_return_to_menu)
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
func _load_panel_texture() -> ImageTexture:
	var bsa := BSAReader.new()
	if not bsa.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"),
			SkynetPaths.variant):
		return null
	var pal_bytes := bsa.read("SKYNET.COL")
	if pal_bytes.is_empty():
		pal_bytes = bsa.read("BRIEF.COL")
	var panel_bytes := bsa.read("PANEL0.IMG")
	bsa.close()
	var palette := Palette.parse(pal_bytes)
	if palette.is_empty() or panel_bytes.is_empty():
		return null
	return ImgFile.parse(panel_bytes, palette)

func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
