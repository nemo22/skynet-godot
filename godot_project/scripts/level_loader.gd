## High-level level loader. DOS-faithful baseline:
##
##   pos_world = (e.x, terrain_y, -e.z)
##   mesh_vertices: (x, -y, -z) in mesh_3d.gd
##   rotation: sub-record 3×i32 = Euler angles (11-bit, 2048=360°)
##
## Ghidra decode of SKYNET.EXE FUN_0014e100 (skynet_gh.c:53859)
## confirms the sub-record values are rotation angles indexing
## sin/cos LUTs, in the same format as the camera yaw/pitch/roll.
##
## Variant 2 (spawners) and variant 3 (sprite billboards) are NOT
## rendered until we decode their archives.

extends RefCounted

const BSAReader    := preload("res://scripts/loaders/bsa_reader.gd")
const Mesh3D       := preload("res://scripts/loaders/mesh_3d.gd")
const MapFile      := preload("res://scripts/loaders/map_file.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")
const WldTerrain   := preload("res://scripts/loaders/wld_terrain.gd")
const Enemy        := preload("res://scripts/enemy.gd")
const ActionTarget := preload("res://scripts/action_target.gd")
const TransfrmPRS  := preload("res://scripts/loaders/transfrm_prs.gd")
const EnemyAnim    := preload("res://scripts/enemy_anim.gd")
const AIData       := preload("res://scripts/enemy_ai_data.gd")
const Pickup       := preload("res://scripts/pickup.gd")
const PickupData   := preload("res://scripts/pickup_data.gd")
const LevelScene   := preload("res://scripts/level_scene.gd")
const LevelBehaviour := preload("res://scripts/level_behaviour.gd")
const TriggerBus   := preload("res://scripts/triggers/trigger_bus.gd")
const TriggerRuntime := preload("res://scripts/triggers/trigger_runtime.gd")
const Explosion    := preload("res://scripts/explosion.gd")

## World units per sprite texel — billboards are sized texture_px × this.
## DOS draws a flat at texture_dims × a perspective scale (skynet_gh.c
## FUN_0014f4xx: `tex_w * puVar1[0x11]`); the texture dimensions already
## carry each prop's relative size, so a single world-scale suffices.
const SPRITE_PIXEL_SIZE: float = 2.0
## Collectibles are drawn at the DOS renderer's own 1:1 scale.
##
## FUN_0014f208 hands the blitter `record.width * scale`, where `scale`
## is the entity's 8.8 factor and the distances it works in are the same
## fixed-point world units — so at scale 1.0 a sprite is exactly as many
## world units wide as it has pixels. The port's 2.0 was picked to make
## the SCENERY (trees, rubble, barrels) read at a believable size, and it
## turned the items into furniture: a 141x24 px ammo belt came out 282 u
## long, wider than the console desk it lay on ("the items out of the
## crates are terribly big", 2026-09-04). Items go back to 1:1; scenery
## keeps the tuned scale until its own factor is recovered.
const PICKUP_PIXEL_SIZE: float = 1.0

## The scale a variant-3 sprite is drawn at.
static func pixel_scale_for(sprite_index: int) -> float:
	return PICKUP_PIXEL_SIZE if PickupData.ITEMS.has(sprite_index) 		else SPRITE_PIXEL_SIZE
const INDOOR_SPRITE_LIFT: float = 16.0

## Enemy-type ID → mesh base name (no extension). Extracted from the
## static enemy table at Skynet.exe virtual 0x44d00 (record stride 0x1C,
## field +0 → resource record → inline filename). Indices 0x00..0x53;
## all names verified present in MDMDENMS.BSA. 0x36..0x39 unresolved.
## Multi-segment enemies (tanks/walkers/flyers) also spawn child parts
## in DOS — first pass renders only the main body mesh.
## Fixed weapon emplacements (gun towers, turrets, cannon/missile pods).
## These never walk and never rotate their whole body — only the turret
## segment should aim, which needs the multi-segment actor system (TODO).
const STATIONARY_ENEMIES: Array = [
	"smltrrt", "guntwr1", "guntwr3", "hvytrrt", "hvytrrt2", "hvytrrt3",
	"smlcanon", "smlplsm", "tribrrl", "msslpodr", "msslpodl",
	"hvyplsm", "hvybrrl", "hmslpodl", "hmslpodr",
	"bosstrrt", "bossgun", "grabbase",
]

## Passive actors — animate only, no AI/combat (scripted transports).
const PASSIVE_ENEMIES: Array = [
	"boxtrck",   # transport box on a lift — TODO: scripted-move behaviour
]

## Per-enemy stats for the fallback FSM: [max_health, fire_interval,
## move_speed]. Hand-tuned; the DOS type table (enemy_ai_data.gd, read in
## Enemy.configure) overrides them for every type that carries data.
## There is no damage column: a shot's damage is its DOS ammo record's
## (+0x0c of table 0x40728, AIData.AMMO) — the old one was never read.
## Actors not listed use ENEMY_STATS_DEFAULT.
const ENEMY_STATS_DEFAULT: Array = [60.0, 1.9, 480.0]
const ENEMY_STATS: Dictionary = {
	"raptor":   [45.0, 1.6, 720.0],
	"globe":    [30.0, 2.0, 560.0],
	"drone":    [35.0, 1.9, 600.0],
	"scout":    [40.0, 1.8, 700.0],
	"flencer":  [40.0, 1.8, 600.0],
	"hk_ftr":   [120.0, 1.4, 900.0],
	"hk_bmbr":  [150.0, 1.6, 800.0],
	"hvytrrt":  [100.0, 1.3, 0.0],
	"hvytrrt2": [110.0, 1.3, 0.0],
	"hvytrrt3": [110.0, 1.2, 0.0],
	"smltrrt":  [60.0, 1.5, 0.0],
	"guntwr1":  [140.0, 1.6, 0.0],
	"guntwr3":  [150.0, 1.5, 0.0],
	"endorfl":  [70.0, 1.5, 480.0],
	"endoskel": [70.0, 1.6, 500.0],
	"t600pst":  [80.0, 1.6, 440.0],
	"t600rfl":  [85.0, 1.4, 440.0],
	"t800pst":  [110.0, 1.5, 460.0],
	"t800rfl":  [120.0, 1.3, 460.0],
	"mantnk":   [200.0, 1.4, 380.0],
	"hvytnk":   [240.0, 1.5, 320.0],
	"hvrtnk":   [160.0, 1.5, 520.0],
}

## Per-type hit points from the Skynet.exe enemy table at VA 0x44d00:
## record +0x14 (+0x30000) points at the type's parameter block, whose
## first dword is copied into the actor's HP field (instance +0x0e,
## clamped to 0x7fff — FUN_0012959d, skynet_gh.c:29961-29968). Indexed
## by enemy type like ENEMY_MESH. 0 = no HP in the table (scripted /
## transport actors) — those fall back to ENEMY_STATS.
const ENEMY_HP: PackedInt32Array = [
	125, 50, 50, 150, 300, 300, 150, 50, 50, 50,
	50, 50, 50, 400, 400, 400, 400, 400, 400, 400,
	400, 200, 200, 200, 200, 200, 200, 200, 50, 50,
	700, 200, 200, 400, 400, 450, 450, 500, 500, 150,
	400, 450, 10000, 150, 150, 100, 800, 800, 400, 700,
	0, 0, 10000, 0, 50, 50, 50, 50, 35, 35,
	35, 35, 35, 35, 35, 35, 35, 35, 35, 125,
	125, 125, 200, 200, 200, 125, 125, 300, 100, 100,
	10000, 10000, 6000, 6000, 100, 75, 0, 0, 10, 10,
	10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
]

## Airborne actors — keep their authored altitude (no ground snap).
const FLYING_ENEMIES: Array = [
	"globe", "drone", "scout", "hk_ftr", "hk_bmbr",
]

## Per-enemy positional sound (played periodically while the actor is
## active). Names resolve in MDMDSFXS.BSA; absent → silent.
const ENEMY_SOUND: Dictionary = {
	"raptor": "RAP.WAV",
	"hk_ftr": "HK2.RAW", "hk_bmbr": "BHK.RAW",
	"globe": "MOTLOOP2.RAW", "drone": "MOTLOOP2.RAW",
	"scout": "MOTFIND1.RAW", "flencer": "MOTLOOP2.RAW",
	"hvytrrt": "TURRET.RAW", "hvytrrt2": "TURRET.RAW",
	"hvytrrt3": "TURRET.RAW", "smltrrt": "TURRET.RAW",
	"guntwr1": "TURRET.RAW", "guntwr3": "TURRET.RAW",
	"endorfl": "N_ACTR.RAW", "endoskel": "N_ACTR.RAW",
	"t600pst": "N_ACTR.RAW", "t600rfl": "N_ACTR.RAW",
	"t800pst": "N_ACTR.RAW", "t800rfl": "N_ACTR.RAW",
	"mantnk": "TANK1.RAW", "hvytnk": "TANK1.RAW", "hvrtnk": "TANK1.RAW",
}

## Enemy-type ID → mesh base name. The full 100-entry table extracted
## from Skynet.exe (enemy table at virtual 0x44d00; each 0x1C record's
## +0 points to an inline ".3D" filename string).
const ENEMY_MESH: PackedStringArray = [
	"flencer", "globe", "drone", "scout", "hk_ftr", "hk_bmbr", "hvrtnk", "smltrrt",
	"smltrrt", "smltrrt", "smltrrt", "smltrrt", "smltrrt", "guntwr1", "guntwr1", "guntwr1",
	"guntwr1", "guntwr3", "guntwr3", "guntwr3", "guntwr3", "hvytrrt2", "hvytrrt", "hvytrrt",
	"hvytrrt", "hvytrrt", "hvytrrt", "hvytrrt", "smltrrt", "smltrrt", "hvytnk", "hvytrrt2",
	"raptor", "endoskel", "endorfl", "t600pst", "t600rfl", "t800pst", "t800rfl", "mantnk",
	"t-rexleg", "spidbot", "bosschss", "grabbase", "grabbase", "torture", "boxtrck", "tnktrck",
	"sgtcar00", "hvytnk", "tranenem", "hk_ftr", "bosschss", "avsolidb", "smltrrt", "smltrrt",
	"smltrrt", "smltrrt", "smlcanon", "smlplsm", "tribrrl", "msslpodr", "smlcanon", "smlplsm",
	"tribrrl", "msslpodr", "tribrrl", "msslpodl", "msslpodr", "hvyplsm", "hvybrrl", "hvybrrl",
	"hvytrrt3", "hvytrrt3", "hvytrrt3", "hmslpodl", "hmslpodr", "t-rexhed", "t-gunr", "t-gunl",
	"bosschst", "bosshead", "bosstrrt", "bossgun", "grabber", "weldrarm", "hadeenem", "avsolidh",
	"scengine", "scgun", "scfin", "scwing", "hfengine", "hfprobe", "hffin", "smltrrt",
	"smlcanon", "smlplsm", "tribrrl", "msslpodr",
]

## Multi-segment actors. Extracted from the Skynet.exe enemy table:
## record +0x0C points to a child list of 32-byte entries
## {continue_flag, child_type, ox, oy, oz, pitch, yaw, roll}. Each value:
##   [child_enemy_type, off_x, off_y, off_z, pitch, yaw, roll]
## Offsets are in mesh-origin units (DOS Y-down); rotation is 11-bit
## (2048 = 360°). A turret = a fixed base + these child segments (a
## rotating gun, a barrel pair, a turret head …); children may nest.
const ENEMY_SEGMENTS: Dictionary = {
	4: [[55, 0,-20,-120, 0,0,1024]],
	6: [[66, 0,-22,19, 0,0,0], [67, -13,0,0, 0,0,0], [68, 13,0,0, 0,0,0]],
	7: [[62, 7,-6,0, 0,0,0]],
	8: [[62, 7,-6,0, 0,0,0]],
	9: [[63, 7,-8,0, 0,0,0]],
	10: [[63, 7,-8,0, 0,0,0]],
	11: [[64, 12,2,0, 0,0,1024]],
	12: [[64, 12,2,0, 0,0,1024]],
	13: [[31, 0,-101,0, 0,0,0]],
	14: [[72, 0,-109,0, 0,0,0]],
	15: [[73, 0,-109,0, 0,0,0]],
	16: [[74, 0,-109,0, 0,0,0]],
	17: [[31, 0,-189,0, 0,0,0]],
	18: [[72, 0,-197,0, 0,0,0]],
	19: [[73, 0,-197,0, 0,0,0]],
	20: [[74, 0,-197,0, 0,0,0]],
	21: [[76, 0,-12,7, 0,0,0]],
	22: [[69, -51,0,0, 0,0,0], [69, 51,0,0, 0,0,0]],
	23: [[70, -53,1,0, 0,0,0], [70, 53,1,0, 0,0,0]],
	24: [[71, -53,1,0, 0,0,0], [71, 53,1,0, 0,0,0]],
	25: [[69, -51,0,0, 0,0,0], [69, 51,0,0, 0,0,0]],
	26: [[70, -53,1,0, 0,0,0], [70, 53,1,0, 0,0,0]],
	27: [[71, -53,1,0, 0,0,0], [71, 53,1,0, 0,0,0]],
	28: [[65, 4,-8,0, 0,0,0]],
	29: [[65, 4,-8,0, 0,0,0]],
	30: [[26, 0,-55,30, 0,0,0]],
	31: [[76, 0,-12,7, 0,0,0]],
	39: [[66, 0,-22,19, 0,0,0], [67, -13,0,0, 0,0,0], [68, 13,0,0, 0,0,0]],
	40: [[77, 0,-72,43, 0,0,0]],
	42: [[80, 0,-133,75, 0,0,0]],
	43: [[84, 0,0,0, 0,0,0]],
	44: [[85, 0,-4,0, 0,0,0]],
	49: [[26, 0,-55,30, 0,0,0]],
	50: [[86, 0,-70,0, 0,0,256]],
	52: [[80, 0,-133,75, 0,0,0]],
	53: [[87, 0,0,0, 0,0,0]],
	54: [[58, 7,-6,0, 0,0,0]],
	55: [[59, 7,-8,0, 0,0,0]],
	56: [[60, 11,-8,0, 0,0,0]],
	57: [[61, 4,-8,0, 0,0,0]],
	72: [[69, -51,0,0, 0,0,0], [69, 51,0,0, 0,0,0]],
	73: [[70, -53,1,0, 0,0,0], [70, 53,1,0, 0,0,0]],
	74: [[71, -53,1,0, 0,0,0], [71, 53,1,0, 0,0,0]],
	77: [[78, -32,-29,-24, 0,0,0], [79, 32,-29,-24, 0,0,0]],
	80: [[81, 0,-58,0, 0,0,0], [82, 170,-10,18, 0,0,0], [82, -170,-10,18, 0,0,0]],
	82: [[83, 0,13,0, 0,0,0]],
}

class Level:
	## Where this zone stands in the world. A mission scene holds several
	## DOS maps side by side (docs/m2_mission_scene_plan.md), so everything
	## the records give is ZONE-LOCAL and the branch nodes below carry this
	## offset: world = zone-local + origin. Zero for a lone map, and then
	## the two spaces are the same thing.
	var origin: Vector3 = Vector3.ZERO
	var map: MapFile.MapFile
	var wld: WldTerrain.WLD
	var terrain: MeshInstance3D
	## file_off → OmniLight3D for every variant-2 light (main places them,
	## a chain switches them).
	var map_lights: Dictionary = {}
	var entities: Node3D                 # variant-1 .3D meshes
	var enemies: Node3D                  # variant-3 enemy-marker actors
	var sprites: Node3D                  # variant-3 billboard sprites + pickups
	var sky: MeshInstance3D              # SKY_SKY.3D — attach to camera
	var centroid: Vector3 = Vector3.ZERO
	var entity_count: int = 0
	var enemy_count: int = 0
	var is_outdoor: bool = false
	var map_suffix: String = ""           # e.g. "210"
	## Which heightmap the ground came from — the map's own, or a
	## borrowed one when the game ships none (Future Shock 040/080).
	var wld_suffix: String = ""
	var map_bytes: PackedByteArray = PackedByteArray()   # the MAP file as loaded
	## Player spawn read from the MAP markers (DOS-faithful):
	##   marker_type 0 = start position, marker_type 1 = facing direction.
	var player_start: Vector3 = Vector3.ZERO
	var player_dir: Vector3 = Vector3.ZERO
	var has_player_start: bool = false
	## Every trigger event this level performs, announced
	## (scripts/triggers/trigger_bus.gd, M3 step 3). An OBSERVER: the
	## trigger runtime and the Behaviour branch announce on it, nothing in
	## the game subscribes, and it dies with the level. One per ZONE, so a
	## mission scene's maps each announce under their own map number.
	var bus: RefCounted = null
	## The trigger state of this zone and the only thing that writes it
	## (scripts/triggers/trigger_runtime.gd, plan step 5a): the chain
	## walk, the cues, and the state bytes, act bytes and links the whole
	## level reads. The parsed MAP above is the DATA it started from and
	## is never written to.
	var triggers: RefCounted = null
	## TRANSFRM.PRS: mesh name → its damage-stage mesh names. Kept for
	## the bake, which classifies the destructibles by it too.
	var transfrm: Dictionary = {}
	## Every placement marker by id → Array of world positions (a map may
	## carry several markers with one id, e.g. two facing markers). Map
	## exits spawn the player at marker N facing marker N+1
	## (PlrSetPosMarker FUN_00121f72, skynet_gh.c:25074-25087).
	var markers: Dictionary = {}
	## Where the player is allowed to be: Rect2 in world x/z built from
	## PAIRS of markers of types 30-39 (DOS FUN_00122711, table 0x390e3).
	## Empty on a map that carries none — then nothing is fenced off.
	var border_boxes: Array = []
	## MAP file offsets of the enemy markers / pickups that were spawned —
	## the per-map state overlay records which of them are gone.
	var enemy_marker_offs: Array = []
	var pickup_offs: Array = []
	## --- the baked level scene (scripts/level_scene.gd) ----------------
	## Terrain, static geometry and their collision come out of a Godot
	## scene the conversion wrote; `baked` says the entity loop below can
	## skip everything that has no behaviour.
	var baked: bool = false
	var occluders: Node3D = null          # OccluderInstance3D for the map
	var overlay: Node3D = null            # mods/maps/<MAP>.detail.tscn
	## The level scene the baked branches came from: the derived
	## converted/maps/<MAP>.level.scn, or a mod that replaced it. "" when
	## nothing was baked and the records did the work.
	var baked_from: String = ""
	## The map's behaviour as nodes (scripts/level_behaviour.gd), out of
	## the baked scene or built here; scripts/level/behaviour.gd on its
	## root runs the chains and the cues (F2).
	var behaviour: Node3D = null

## Build every node from the DOS data, ignoring (and then rewriting) the
## baked level scene. The bake itself runs with this off.
var use_baked: bool = true

## Load a level by its MAP basename (e.g. "MAP.210").
## Phase timing for the load. `--load-trace` prints where the seconds
## of a level load actually go, instead of guessing.
static var _trace: Array = []
static var _trace_t0: int = 0
static var _trace_on: bool = OS.get_cmdline_user_args().has("--load-trace")

static func _phase(what: String) -> void:
	if not _trace_on:
		return
	var now: int = Time.get_ticks_usec()
	_trace.append([what, now - _trace_t0])
	_trace_t0 = now

## Load a level at the world origin — the lone-map runtime.
func load_level(map_name: String) -> Level:
	return load_zone(map_name, Vector3.ZERO)

## Build the level of a zone whose BAKED half is already in the tree.
##
## A mission scene instantiates the level scene of every zone itself and
## stands it at the zone's origin (scripts/mission_scene.gd), so the
## terrain and the static geometry are there before the loader runs:
## `baked_root` is that instance, and its branches are lifted out of it
## instead of a second copy being loaded. The caller parents everything
## under the node that already stands at `origin`, which is why the
## branches are NOT moved here (see _stand_at_origin).
##
## `baked_root` may be null and the promise still holds: a PHASE switch
## re-authors a zone into another MAP (main._switch_phase) and there is no
## instance standing under it then — the baked scene of that map is loaded
## here as usual, and the branches still stay zone-local.
func load_zone_from(map_name: String, origin: Vector3, baked_root: Node) -> Level:
	return load_zone(map_name, origin, baked_root, true)

## Load a level as a ZONE standing at `origin`. Everything built from the
## MAP records keeps its DOS (zone-local) coordinates; the branch nodes
## get `origin` as their transform, so their children's global positions
## are world ones. At Vector3.ZERO this is load_level to the bit.
##
## `parented` (load_zone_from) says the caller parents the branches under
## a node that carries `origin` already.
func load_zone(map_name: String, origin: Vector3, baked_root: Node = null,
		parented: bool = false) -> Level:
	var level := Level.new()
	level.origin = origin
	_trace = []
	_trace_t0 = Time.get_ticks_usec()

	# Palette (shared, parsed once per session by the asset cache) ------
	var palette: PackedColorArray = Assets.palette()
	if palette.is_empty():
		push_error("[level] palette load failed")
		return null

	# MAP ----------------------------------------------------------
	# The DOS MAP is the SOURCE and it is never overridden: what a map
	# DOES is the game's, and a mod replaces its level SCENE (the
	# presentation) instead — scripts/level_scene.gd.
	var maps := BSAReader.new()
	if not maps.open(SkynetPaths.gamedata_path(SkynetPaths.map_archive), SkynetPaths.variant):
		push_error("[level] cannot open %s" % SkynetPaths.map_archive)
		return null
	var map_bytes := maps.read(map_name)
	maps.close()
	if map_bytes.is_empty():
		push_error("[level] MAP not found: %s" % map_name)
		return null
	level.map = MapFile.parse(map_bytes)
	if level.map == null:
		push_error("[level] MAP parse failed: %s" % map_name)
		return null
	level.map_bytes = map_bytes
	level.map_suffix = map_name.split(".")[-1]
	level.wld_suffix = level.map_suffix
	# Indoor/outdoor flag at MAP+9028 (sub_153A8B reads `MAP[+9028] == 1`).
	if map_bytes.size() > 9028 + 4:
		var flag: int = map_bytes[9028] | (map_bytes[9029] << 8) \
			| (map_bytes[9030] << 16) | (map_bytes[9031] << 24)
		level.is_outdoor = (flag == 1)
	print("[level] %s: grid %dx%d, %d names, %d entities, %s"
		% [map_name, level.map.grid_width, level.map.grid_height,
		   level.map.names.size(), level.map.entities.size(),
		   "OUTDOOR" if level.is_outdoor else "INDOOR"])

	# The event bus (M3 step 3) is built BEFORE the trigger state so that
	# every trigger event of this level, from the first one, has somewhere
	# to be announced. Nothing subscribes: it is an observer.
	level.bus = TriggerBus.new()
	level.bus.map = int(level.map_suffix) if level.map_suffix.is_valid_int() else -1
	# The trigger state (step 5a). Everything below asks it for a state
	# byte, an act byte or a link, and it is the only thing that writes
	# one — the records are read-only from here on.
	level.triggers = TriggerRuntime.new()
	level.triggers.bus = level.bus
	level.triggers.setup(level.map)
	# TRANSFRM.PRS (destructible damage stages) lives in MDMDBRIF.BSA.
	var transfrm: Dictionary = {}
	var brif := BSAReader.new()
	if brif.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"),
			SkynetPaths.variant):
		transfrm = TransfrmPRS.parse(brif.read("TRANSFRM.PRS"))
		brif.close()
	level.transfrm = transfrm

	_phase("read+parse map")
	# WLD (outdoor only) -------------------------------------------
	if level.is_outdoor:
		var wld_path := SkynetPaths.gamedata_path("WLD.%s" % level.map_suffix)
		var wld_bytes := PackedByteArray()
		if FileAccess.file_exists(wld_path):
			wld_bytes = SkynetPaths.read_bytes(wld_path)
		if wld_bytes.is_empty():
			# Future Shock ships no WLD.040 and no WLD.080, yet both are
			# outdoor city maps — without a heightmap the whole level
			# floats over nothing and the player falls 14 000 units out
			# of the world. DOS opens `gamedata\wld.NNN` and, when the
			# file is not there, simply keeps whatever heightmap is
			# already in memory; we cannot know which one that was, so we
			# ask the level itself (see _best_fit_wld).
			var borrowed: String = _best_fit_wld(level.map)
			if not borrowed.is_empty():
				level.wld_suffix = borrowed
				wld_bytes = SkynetPaths.read_bytes(
					SkynetPaths.gamedata_path("WLD.%s" % borrowed))
		if not wld_bytes.is_empty():
			level.wld = WldTerrain.parse(wld_bytes)
			if level.wld_suffix == level.map_suffix:
				print("[level] WLD.%s loaded" % level.map_suffix)
			else:
				print("[level] WLD.%s missing — standing the level on WLD.%s"
					% [level.map_suffix, level.wld_suffix])
		else:
			push_warning("[level] outdoor flag set but WLD.%s missing"
				% level.map_suffix)

	_phase("wld")
	# The baked level scene: terrain, static geometry and their collision
	# and the occluders, all in Godot's own format
	# (scripts/level_scene.gd). It carries a hash of this MAP, so data
	# that moved falls straight back to building from the records.
	var baked: Dictionary = {}
	if use_baked:
		# A zone's copy is already instantiated by the mission scene; when
		# it turns out to be stale the ordinary path still gets a chance to
		# rebuild the file before the records have to do the work.
		#
		# A MOD beats that instance. The mission bake stands on the
		# DERIVED scene on purpose (a cache file may only reference cache
		# files — asset_cache._dep_ok), so the mission scene never points
		# into mods/; the substitution happens here instead, once per zone
		# build, which is also why dropping a mod in is picked up on the
		# next start with no rebake at all.
		if baked_root != null and not LevelScene.is_modded(map_name):
			baked = LevelScene.take_from(baked_root, map_bytes)
		if baked.is_empty():
			baked = LevelScene.take(map_name, map_bytes)
	var baked_static: Node = null
	if not baked.is_empty():
		level.baked = true
		level.baked_from = String(baked.get("source", ""))
		level.terrain = baked.get("terrain")
		level.occluders = baked.get("occluders")
		baked_static = baked.get("static")
		level.behaviour = baked.get("behaviour")
	level.overlay = LevelScene.overlay(map_name)
	# The behaviour nodes: from the bake, or built from the records now
	# (a bake-less run, the editor's data view). The chains are walked on
	# them from here on.
	if level.behaviour == null:
		level.behaviour = LevelBehaviour.build(level)
	# Its bodies and meshes sleep while the entity loop below still
	# builds the same objects from the records (F2, class by class).
	level.behaviour.sleep_geometry(level.behaviour)
	# The branch is the runtime's presentation — the cues it plays and
	# prints, and the chain wiring the bake laid down — and the runtime is
	# where its state lives.
	level.behaviour.runtime = level.triggers
	level.behaviour.bus = level.bus
	level.triggers.presenter = level.behaviour
	# Every class of the DOS object layer runs on the branch's own nodes
	# now (steps 5c-5h) and the branch is the level's per-tick sweep. The
	# water and the drops hand positions back out into world space, so the
	# branch is told where its zone stands; and the MOVERS meet the entity
	# loop below, which builds the mesh and hands it to the record's own
	# Mover through register_node — so this has to be in place before that
	# loop runs.
	level.behaviour.zone_origin = origin

	_phase("baked scene")
	# Terrain mesh — built once and served from the asset cache
	# (converted/terrain/WLD.NNN.res); the tiles come from TEXTURE.302.
	if level.wld and level.terrain == null:
		var terrain_mesh := Assets.terrain(level.wld_suffix, level.wld)
		if terrain_mesh:
			level.terrain = MeshInstance3D.new()
			level.terrain.name = "Terrain"
			level.terrain.mesh = terrain_mesh
			# The ground's collision shape is cached like everything else
			# (converted/shape/WLD_NNN.res): 130 000 triangles is a slow
			# thing to re-derive on every level start.
			LevelScene.add_collision(level.terrain, "WLD_" + level.wld_suffix)

	# Entities (variant 1 only) ------------------------------------
	level.entities = Node3D.new()
	level.entities.name = "Entities"
	# The baked half moves in first; the loop below adds the entities
	# that carry behaviour, so everything still lives in one container
	# and the automap, the lighting pass and the collision pass do not
	# have to know where a mesh came from.
	if baked_static != null and is_instance_valid(baked_static):
		for c in baked_static.get_children().duplicate():
			baked_static.remove_child(c)
			level.entities.add_child(c)
		baked_static.free()

	var objs := BSAReader.new()
	if not objs.open(SkynetPaths.gamedata_path("MDMDOBJS.BSA"), SkynetPaths.variant):
		push_error("[level] cannot open MDMDOBJS.BSA")
		return level

	# Enemy/actor meshes (AVSOLDER.3D etc.) live in MDMDENMS.BSA, not
	# MDMDOBJS.BSA. Actors are variant-1 entities with the 0x40 flag; we
	# resolve their mesh name through this archive as a fallback.
	var enms := BSAReader.new()
	var have_enms: bool = enms.open(
		SkynetPaths.gamedata_path("MDMDENMS.BSA"), SkynetPaths.variant)
	if not have_enms:
		push_warning("[level] MDMDENMS.BSA unavailable — enemies will be missing")

	var mesh_cache: Dictionary = {}
	var enemy_frame_cache: Dictionary = {}
	var tex_cache := TextureCache.new(palette,
		SkynetPaths.gamedata_dir)
	var provider := Callable(tex_cache, "provide")

	var sum_x: float = 0; var sum_y: float = 0; var sum_z: float = 0
	var n: int = 0
	var failed_reads: Dictionary = {}
	var failed_parses: Dictionary = {}
	_phase("terrain mesh")
	for e in level.map.entities:
		if (e.flags & 3) != 1: continue
		var name: String = MapFile.entity_name(level.map, e)
		if name.is_empty(): continue

		# Classification by the entity's action/handler id (the 0x59b00
		# table families, recovered from Skynet.exe): doors, gates,
		# lifts and rotators are MOVER types — their DOS handlers move
		# the entity transform per tick (NOT mesh-frame swaps; every
		# door .3D in the archives is single-frame). 0x18/0x19 are
		# TRANSFRM.PRS destructibles. Anything damageable (state bits
		# 1+2, ObjHit skynet_gh.c:39512) needs a hit/activate route.
		# Everything else is plain static geometry — and static geometry
		# is what the baked level scene already holds.
		# Destructibles bind BY NAME to TRANSFRM.PRS (TransformInit
		# keys templates on the mesh name) — cars carry state bit1 +
		# HP but act 0x00 in the MAP data.
		var has_transfrm: bool = transfrm.has(name.to_lower())
		# Anything with HP is a hit target too (ObjHit drains it whatever
		# the state bits say — crates, buses, the dish take their HP from
		# the map's per-name defaults). The rule is shared with the bake
		# so the Static and Behaviour branches partition the meshes the
		# same way.
		var wants_action: bool = LevelBehaviour.wants_action(e, name, transfrm)

		# Position: entity X/Y/Z used VERBATIM from the MAP record. The DOS
		# engine never samples terrain height nor applies an AABB offset
		# for placed meshes — entity.Y (MAP +0x0C, Y-down) is already the
		# absolute world Y (verified skynet_gh.c FUN_00136519:38194-38198).
		var pos := Vector3(float(e.x), -float(e.y), -float(e.z))
		if level.baked and not wants_action:
			# Already in the scene, with its collision. Only the tally
			# the camera framing uses is still wanted.
			sum_x += pos.x; sum_y += pos.y; sum_z += pos.z
			n += 1
			continue

		var lookup: String = name + ".3D"
		var cached = mesh_cache.get(lookup, null)
		var am: ArrayMesh = null
		if cached == null:
			var bytes: PackedByteArray = objs.read(lookup)
			if bytes.is_empty() and have_enms:
				bytes = enms.read(lookup)   # enemy/actor mesh fallback
			if bytes.is_empty():
				mesh_cache[lookup] = false
				failed_reads[lookup] = true
				continue
			# Parsed + textured once, then served from converted/mesh/.
			am = Assets.mesh(lookup, bytes)
			if am == null:
				mesh_cache[lookup] = false
				var ver_str := ""
				if bytes.size() >= 4:
					ver_str = "%c%c%c%c" % [bytes[0], bytes[1], bytes[2], bytes[3]]
				failed_parses[lookup] = ver_str
				continue
			mesh_cache[lookup] = am
		elif typeof(cached) == TYPE_BOOL:
			continue
		else:
			am = cached
		if am == null: continue

		var mi: MeshInstance3D
		if wants_action:
			var at := ActionTarget.new()
			at.setup_action(level.behaviour, e.file_off)
			# Sibling name collisions get renamed by the scene tree — keep
			# the mesh identity where the branch can read it.
			at.set_meta("mesh_name", name)
			mi = at
		else:
			mi = MeshInstance3D.new()
		mi.name = name
		mi.mesh = am

		# Rotation: sub-record Euler angles, 11-bit units (2048 = 360°).
		# Order verified vs FUN_0014e100 + FUN_00150284 (skynet_gh.c):
		#   off_x = pitch (X), off_y = yaw (Y), off_z = roll (Z).
		# FUN_0014e100 (skynet_gh.c:53859) builds R = Rz(roll)·Rx(pitch)·
		# Ry(-yaw) — the Y term uses NEGATED yaw (all 9 matrix entries
		# transcribed and solved). With the DOS→Godot conversion
		# C = diag(1,-1,-1) (= Rx 180°, applied identically to mesh
		# vertices and entity position), the Godot rotation is
		# C·R·C⁻¹ = Rz(-roll)·Rx(+pitch)·Ry(+yaw).
		var pitch_rad: float = (e.off_x & 0x7FF) * TAU / 2048.0
		var yaw_rad:   float = (e.off_y & 0x7FF) * TAU / 2048.0
		var roll_rad:  float = (e.off_z & 0x7FF) * TAU / 2048.0
		var b := Basis()
		b = b.rotated(Vector3.UP,     yaw_rad)
		b = b.rotated(Vector3.RIGHT,  pitch_rad)
		b = b.rotated(Vector3.BACK,  -roll_rad)
		mi.transform = Transform3D(b, pos)
		if not wants_action and not _sealed_door(name, mi.mesh):
			# Shared with every other copy of this mesh, in this map and
			# in all the others (converted/shape/). Movers and
			# destructibles keep main.gd's treatment: a door leaf
			# collides as a box, and a mover needs its own body.
			LevelScene.add_collision(mi, name.to_upper())
		level.entities.add_child(mi)
		if wants_action:
			# Register after the transform is final — a mover's node takes
			# where it stands now as the rest pose of its travel (step 5e,
			# Behaviour.register_mover → Mover.adopt).
			level.behaviour.register_node(e, mi)
			# Staged wrecks need a TRANSFRM.PRS template for the name; a
			# 0x19 act without one (CARHIP2C, which IS another car's last
			# stage) just runs the plain HP path, exactly as the DOS
			# handler does when its lookup comes back empty (0x120833 →
			# 0x12078a sets carry, `jb` leaves). The record's own
			# Destructible node stages it from here on (step 5g).
			if has_transfrm and level.behaviour != null:
				level.behaviour.register_destructible(e,
					_destruct_stage_meshes(name, transfrm, objs,
						mesh_cache, provider))
		sum_x += pos.x; sum_y += pos.y; sum_z += pos.z
		n += 1

	# --- Enemies (variant-3 markers, marker_type 2) -----------------
	# Enemies are NOT variant-1 actors — they are variant-3 placement
	# markers (FUN_0011c519 MapScanMarkers / FUN_00129f39 in skynet_gh.c).
	# Each marker's enemy-type ID is at sub+10 and selects the mesh via
	# the ENEMY_MESH table; meshes live in MDMDENMS.BSA.
	_phase("entity meshes")
	level.enemies = Node3D.new()
	level.enemies.name = "Enemies"
	var en: int = 0
	var enemy_hist: Dictionary = {}
	if have_enms:
		# Enemy start markers, then the 0xF3 spawn sprites: SpawnEnemiesInit
		# (0x129500 in v1.01) builds a robot of type u16 sub+2 at every
		# variant-3 entity with act 0xF3 — at most 50 — and hides it until
		# the sprite's chain fires (MAP.232: seven robots once the last
		# console is done).
		var starts: Array = []
		var n_spawn: int = 0
		for e in level.map.entities:
			if (e.flags & 3) != 3: continue
			if e.marker_type == 2:                 # 2 = enemy start marker
				starts.append([e, e.enemy_type, false])
			elif e.marker_type < 0 and e.link_act_type == 0xF3 and n_spawn < 50:
				starts.append([e, e.exit_map & 0xFFFF, true])
				n_spawn += 1
		for start in starts:
			var e = start[0]
			var et: int = start[1]
			var spawn: bool = start[2]
			enemy_hist[et] = enemy_hist.get(et, 0) + 1
			var eframes := _enemy_frames_for(et, enms, objs,
				enemy_frame_cache, provider)
			if eframes.is_empty(): continue
			var ebase: String = ""
			if et >= 0 and et < ENEMY_MESH.size():
				ebase = ENEMY_MESH[et]
			# Enemy actor: animates the .3D frames and runs a simple AI.
			var emi := Enemy.new()
			emi.name = "enemy%d_%s" % [en, ebase]
			var eaabb: AABB = (eframes[0] as ArrayMesh).get_aabb()
			# Per-type combat stats (must be set before setup()).
			var st: Array = ENEMY_STATS.get(ebase, ENEMY_STATS_DEFAULT)
			emi.max_health = st[0]
			# DOS hit points win over the hand-tuned estimate when the
			# type table carries them.
			if et < ENEMY_HP.size() and ENEMY_HP[et] > 0:
				emi.max_health = float(ENEMY_HP[et])
			emi.set_meta("marker_off", e.file_off)
			level.enemy_marker_offs.append(e.file_off)
			emi.fire_interval = st[1]
			emi.move_speed = st[2]
			# DOS type data (state id, speed, turn, fire params, script,
			# frame-event sounds …) — overrides the hand-tuned numbers.
			emi.configure(et)
			# Wreck parts flung on death (enemy table +0x10 death list).
			emi.death_parts = _death_parts_for(et, enms, objs,
				enemy_frame_cache, provider)
			emi.setup(eframes, eaabb,
				STATIONARY_ENEMIES.has(ebase), FLYING_ENEMIES.has(ebase),
				ENEMY_SOUND.get(ebase, ""), PASSIVE_ENEMIES.has(ebase))
			# Per-mesh AnimRecord frame ranges from the FutureShock32
			# fan-port (`fshock_ida.c:75909-79912`). Meshes not in the
			# table (turrets, vehicles, drones) keep the heuristic
			# walk/death split.
			emi.set_anim_table(EnemyAnim.table_for(ebase))
			# DOS places enemy actors at the marker's X / (Y + 0x10) / Z
			# VERBATIM — EnemiesStartMarked FUN_00129f39 → ObjInsertNew
			# FUN_00138ea6 (skynet_gh.c:30476/39374). No terrain-height
			# sample and no AABB-bottom lift: the level author set the
			# marker Y, so turrets on the gate pillars stay on the pillars
			# instead of being dragged down to the street.
			# (A spawn sprite's robot goes to the sprite's own X/Y/Z, facing
			# +Z: 0x12a4f0 takes no angle.)
			emi.position = Vector3(
				float(e.x), -float(e.y if spawn else e.y + 0x10), -float(e.z))
			# Face the marker's yaw (sub+4, 11-bit angle) like variant-1.
			# Godot yaw = +yaw (DOS Ry(-yaw) conjugated by diag(1,-1,-1)).
			var eyaw: float = 0.0 if spawn else (e.off_y & 0x7FF) * TAU / 2048.0
			emi.rotation.y = eyaw
			level.enemies.add_child(emi)
			# Attach the actor's child segments (turret gun, barrels,
			# turret head …) for multi-segment enemies. For stationary
			# turrets the first top-level segment is the rotating head —
			# wire it as the aim node so only it tracks the player and
			# the base stays still.
			var aim_seg := _attach_segments(emi, et, enms, objs,
				enemy_frame_cache, provider)
			if aim_seg != null and STATIONARY_ENEMIES.has(ebase):
				emi.set_aim_node(aim_seg)
			# The hitbox starts as the body mesh alone; now that the legs,
			# turret and guns are on, make it cover the whole machine.
			emi.refit_hitbox()
			# Marker sub+2 (u16, parsed into exit_map for variant 3) =
			# trigger distance: a dormant trap that detonates when the
			# player comes close (EnemiesStartMarked FUN_00129f39 →
			# FUN_00142800, death state 0x14285e). Enemy markers carry
			# no spawn yaw — DOS actors start facing +Z.
			# Vehicles that drive a marker path (AI state 11): the truck
			# into MAP.210's base, MAP.260's convoy, MAP.234's pick-up HK.
			# The marker's own node drives them (step 5f,
			# scripts/level/path_vehicle.gd, handler 0x127400); the path is
			# the marker's own link, and registering here is what puts the
			# vehicle on the path sweep at all.
			if not spawn and et >= 0 and et < AIData.TYPES.size() \
					and int(AIData.TYPES[et].get("st", -1)) == 11 and e.link_next > 0:
				emi.make_path_vehicle()
				emi.indestructible = int(AIData.TYPES[et].get("hp", 0)) == 0
				if level.behaviour != null:
					level.behaviour.register_path_vehicle(e, emi)
			var trig: int = 0 if spawn else e.exit_map & 0xFFFF
			if trig > 0:
				emi.make_dormant(float(trig))
			if spawn:
				emi.hide_until_spawned()
				# The sprite's own node lets it out (step 5d,
				# scripts/level/raw_action.gd), and registering here is what
				# puts that sprite on the spawn sweep at all.
				if level.behaviour != null:
					level.behaviour.register_spawn(e.file_off, emi)
			en += 1
	level.enemy_count = en
	print("[level] placed %d enemies (variant-3 markers)" % en)
	# The per-type histogram is a load diagnostic: --load-trace only.
	if _trace_on:
		for et in enemy_hist:
			var nm: String = "?" if et < 0 or et >= ENEMY_MESH.size() \
				else ENEMY_MESH[et]
			var fc: int = 0
			var sample = enemy_frame_cache.get(nm.to_upper() + ".3D", [])
			if sample is Array:
				fc = (sample as Array).size()
			print("[enemy] type %d (0x%X) ×%d → %s  frames=%d"
				% [et, et, enemy_hist[et], nm, fc])

	# --- Billboard sprites + pickups (variant-3 non-marker) ---------
	_phase("enemies")
	_build_sprites(level, palette)

	# --- Player spawn (variant-3 markers: type 0 = start, 1 = direction) ---
	# DOS FUN_00121f72 (PlrSetPosMarker): the player spawns at the marker
	# whose marker_type is 0; the marker_type 1 marker gives the facing.
	# The marker's Y is stored as entity.Y + 0x10 (FUN_0011c519). Coords
	# convert DOS Y-down → Godot exactly like every other entity.
	var ps_found: bool = false
	var dir_candidates: Array[Vector3] = []
	for e in level.map.entities:
		if (e.flags & 3) != 3: continue
		if e.marker_type >= 0:
			if not level.markers.has(e.marker_type):
				level.markers[e.marker_type] = []
			level.markers[e.marker_type].append(Vector3(
				float(e.x), -float(e.y + 0x10), -float(e.z)))
		if e.marker_type == 0:
			# DOS player position: marker X / (Y + 0x10) / Z used verbatim
			# (FUN_00121f72 / FUN_0011c519). The DOS camera sits at this Y
			# — no eye-height is added, so we must not add one either, or
			# the camera rises into nearby vehicles/props ("inside jeep").
			level.player_start = Vector3(
				float(e.x), -float(e.y + 0x10), -float(e.z))
			ps_found = true
		elif e.marker_type == 1:
			dir_candidates.append(Vector3(
				float(e.x), -float(e.y + 0x10), -float(e.z)))
	# DOS border boxes (FUN_00122711): PAIRS of markers of the same type
	# 30-39 build up to 10 boxes, and every commit of the player's move
	# (FUN_00122789) has to land inside one of them or the move is undone
	# and the speed zeroed. That is MAP.260's "invisible barrier", which
	# holds the jeep inside the town and on the inner highway lane.
	for mt in range(30, 40):
		var pts: Array = level.markers.get(mt, [])
		for i in range(0, pts.size() - 1, 2):
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[i + 1]
			level.border_boxes.append(Rect2(
				Vector2(minf(a.x, b.x), minf(a.z, b.z)),
				Vector2(absf(a.x - b.x), absf(a.z - b.z))))
	if not level.border_boxes.is_empty():
		print("[level] %d border box(es) from marker pairs (types 30-39)"
			% level.border_boxes.size())
	level.has_player_start = ps_found
	if ps_found:
		# Facing = the marker_type 1 marker nearest the start. A map may
		# hold several type-1 markers; DOS pairs the closest one.
		var best: float = -1.0
		for dc in dir_candidates:
			var d: float = dc.distance_to(level.player_start)
			if best < 0.0 or d < best:
				best = d
				level.player_dir = dc
		if dir_candidates.is_empty():
			level.player_dir = level.player_start + Vector3(0, 0, -512)
		level.player_dir.y = level.player_start.y    # keep the look level
		print("[level] player start %s, dir %s"
			% [level.player_start, level.player_dir])
	else:
		print("[level] no player-start marker (marker_type 0)")

	_phase("sprites+spawn")
	# --- Sky (SKY_SKY.3D — global engine sky for outdoor maps) -------
	# DOS draws SKY_SKY.3D pinned to the camera every frame for outdoor
	# maps (FUN_00133bbb). The moon/stars are textured faces of this
	# mesh. main.gd attaches it to the camera.
	if level.is_outdoor:
		var sky_bytes := objs.read("SKY_SKY.3D")
		if not sky_bytes.is_empty():
			var sky_parsed: Mesh3D.Mesh3D = Mesh3D.parse(sky_bytes, "SKY_SKY")
			if sky_parsed:
				var sky_am := Mesh3D.build_textured_array_mesh(
					sky_parsed, provider)
				if sky_am:
					# SKY_SKY.3D is authored tiny (~1000-unit radius) — DOS
					# draws it in a dedicated pre-pass. Godot has no such
					# pass, so instead scale the dome FAR larger than the
					# whole 65k map (but inside the camera far plane) and
					# render it as ordinary opaque geometry. Every piece of
					# terrain is then closer than the dome shell and
					# depth-tests in front of it normally — no occlusion,
					# no clipping. (no_depth_test made the dome paint over
					# everything, trapping the view inside the sky.)
					for si in sky_am.get_surface_count():
						var sm = sky_am.surface_get_material(si)
						if sm is StandardMaterial3D:
							sm.shading_mode = \
								BaseMaterial3D.SHADING_MODE_UNSHADED
							# Dome faces are wound to be seen from inside
							# (DOS CCW rule) - default CULL_BACK is right.
					level.sky = MeshInstance3D.new()
					level.sky.name = "Sky"
					level.sky.mesh = sky_am
					var sky_aabb := sky_am.get_aabb()
					var sky_r: float = maxf(sky_aabb.size.x,
						sky_aabb.size.z) * 0.5
					if sky_r > 1.0:
						level.sky.scale = Vector3.ONE * (130000.0 / sky_r)
					print("[level] sky SKY_SKY.3D loaded (radius %.0f → scale %.1f)"
						% [sky_r, level.sky.scale.x])

	objs.close()
	if have_enms: enms.close()

	if not failed_reads.is_empty():
		print("[level] %d meshes not in BSA: %s"
			% [failed_reads.size(), ", ".join(failed_reads.keys())])
	if not failed_parses.is_empty():
		for fname in failed_parses:
			print("[level] mesh parse failed: %s (magic=%s)" % [fname, failed_parses[fname]])

	level.entity_count = n
	if n > 0:
		level.centroid = Vector3(sum_x / n, sum_y / n, sum_z / n)
	print("[level] placed %d variant-1 meshes, centroid %s"
		% [n, level.centroid])

	# Nothing was baked for this map (or the MAP has changed): build the
	# occluders now, and write the whole static half out as a Godot scene
	# so the next start just instantiates it.
	if not level.baked and use_baked:
		var t0 := Time.get_ticks_msec()
		level.occluders = LevelScene.build_occluders(level)
		LevelScene.save_from(level, map_name)
		print("[level] %s: bake took %d ms" % [map_name, Time.get_ticks_msec() - t0])

	# Outdoors, what stands wholly past the haze is not drawn at all. After
	# the bake on purpose: the saved scene stays exactly as it was.
	if level.is_outdoor:
		limit_draw_distance(level.entities)
		limit_draw_distance(level.sprites)
		if level.enemies != null:
			for a in level.enemies.get_children():
				if a is Node3D:
					var r: float = float(a.call("bounds_radius")) if a.has_method("bounds_radius") else 0.0
					# Animation frames reach past frame 0's bounds (a stride,
					# a swung arm): half as much again, and some.
					limit_draw_distance(a, r * 1.5 + 200.0, true)

	# zone-local ↔ world: last of all, so the bake above and every record
	# position in it stay in DOS space. A mission scene's zone is parented
	# to a node that stands at the origin already — moving the branches too
	# would put it there twice (load_zone_from).
	if not parented:
		_stand_at_origin(level)

	_phase("sky+rest")
	if _trace_on:
		var parts: Array = []
		for t in _trace:
			parts.append("%s %.0f ms" % [t[0], float(t[1]) / 1000.0])
		print("[load-trace] %s: %s" % [map_name, " | ".join(parts)])
	return level

## Move the level's top branches to `level.origin`. Their children keep
## the zone-local positions the records gave them and follow the parent,
## which is what makes a second map loadable beside the first. The sky is
## left alone: it is pinned to the camera every frame (main.gd).
static func _stand_at_origin(level: Level) -> void:
	if level == null or level.origin == Vector3.ZERO:
		return
	for branch in [level.terrain, level.entities, level.enemies,
			level.sprites, level.behaviour, level.occluders, level.overlay]:
		if branch != null and is_instance_valid(branch) and branch is Node3D:
			(branch as Node3D).position += level.origin
	print("[level] zone stands at %s" % str(level.origin))

## Resolve an enemy marker's animation frames by enemy-type ID (marker
## sub+10), via the ENEMY_MESH table. Meshes come from MDMDENMS.BSA
## (MDMDOBJS.BSA fallback). Returns an Array of ArrayMesh — one per .3D
## vertex frame (animated actors) or a single element (static). Cached
## per .3D filename so repeated enemy types share the frame meshes.
## Resolve the wreck-part meshes of a type's death list into
## [[Mesh, Vector3 local offset], …] (DOS Y-down → Godot).
static func _death_parts_for(enemy_type: int, enms: BSAReader,
		objs: BSAReader, frame_cache: Dictionary, provider: Callable) -> Array:
	var out: Array = []
	if enemy_type < 0 or enemy_type >= AIData.TYPES.size():
		return out
	for p in AIData.TYPES[enemy_type].get("death", []):
		var frames := _enemy_frames_for(int(p[0]), enms, objs, frame_cache, provider)
		if frames.is_empty():
			continue
		out.append([frames[0], Vector3(float(p[1]), -float(p[2]), -float(p[3]))])
	return out

## Which heightmap does this map actually stand on? Score every WLD in
## the game directory by how many of the map's ENEMY markers land within
## a step of its ground — an enemy marker is always on the floor, while a
## building's origin may be at its base or its centre. For Future Shock's
## MAP.040 the answer is unambiguous: WLD.030 puts 88 % of the 196
## markers on the ground, the next best manages 21 %.
##
## Returns "" when nothing fits well enough to be called this map's
## ground.
const WLD_FIT_STEP: float = 60.0
const WLD_FIT_MIN: float = 0.33

## A door leaf that nothing can ever open must not be allowed to seal a
## route. MAP.210's transport carries `DOOR01` across the only way into
## its cargo box, and the DOS link record for it is
## `00 00 00 00 00 fe ff ff ff 00` — act **0x00**, no chain, no HP. It
## never moves. In DOS you walk through it because collision there comes
## from an object cylinder/box and the leaf is a single plane 0.004 units
## thick; the port builds an exact trimesh out of it and gets a wall.
##
## Narrow on purpose: the mesh must be a single plane AND the entity must
## have no action AND the name must say door. Plenty of other flat quads
## are load-bearing — `039FLOOR` is 256×256×0 and is a floor.
const DOOR_PLANE: float = 2.0

static func _sealed_door(mesh_name: String, mesh: Mesh) -> bool:
	if mesh == null or not mesh_name.to_upper().contains("DOOR"):
		return false
	var sz: Vector3 = mesh.get_aabb().size
	return minf(sz.x, minf(sz.y, sz.z)) < DOOR_PLANE

static func _best_fit_wld(map: MapFile.MapFile) -> String:
	if map == null:
		return ""
	var dir: String = SkynetPaths.gamedata_dir
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var pts: Array = []
	for e in map.entities:
		if (e.flags & 3) == 3 and e.marker_type >= 0:
			pts.append(Vector3(float(e.x), -float(e.y + 0x10), float(e.z)))
	if pts.size() < 8:
		# A map with almost no markers (Future Shock's demo levels
		# MAP.001/002 carry only a start and a facing) has to be scored
		# on its buildings instead — looser, but better than a level
		# left hanging over nothing.
		for e in map.entities:
			if (e.flags & 3) == 1:
				pts.append(Vector3(float(e.x), -float(e.y), float(e.z)))
	if pts.size() < 8:
		return ""
	var best: String = ""
	var best_on: int = 0
	for f in d.get_files():
		if not f.to_upper().begins_with("WLD."):
			continue
		var w = WldTerrain.parse(SkynetPaths.read_bytes("%s/%s" % [dir, f]))
		if w == null:
			continue
		var on: int = 0
		for p in pts:
			if absf(p.y - WldTerrain.height_at_world(w, p.x, p.z)) <= WLD_FIT_STEP:
				on += 1
		if on > best_on:
			best_on = on
			best = f.substr(4)
	if float(best_on) < float(pts.size()) * WLD_FIT_MIN:
		return ""
	print("[level] heightmap fit: WLD.%s carries %d of %d ground markers"
		% [best, best_on, pts.size()])
	return best

static func _enemy_frames_for(enemy_type: int, enms: BSAReader,
		objs: BSAReader, frame_cache: Dictionary,
		provider: Callable) -> Array:
	if enemy_type < 0:
		return []
	var base: String = ""
	if enemy_type < ENEMY_MESH.size():
		base = ENEMY_MESH[enemy_type]
	# Wreck parts (types 100+) exist only in the DOS table.
	if base.is_empty() and enemy_type < AIData.TYPES.size():
		base = String(AIData.TYPES[enemy_type].get("n", ""))
	if base.is_empty():
		return []
	if base.is_empty():
		return []
	var lookup := base.to_upper() + ".3D"
	var cached = frame_cache.get(lookup, null)
	if cached != null:
		return [] if typeof(cached) == TYPE_BOOL else cached
	var bytes: PackedByteArray = enms.read(lookup)
	if bytes.is_empty():
		bytes = objs.read(lookup)
	if bytes.is_empty():
		frame_cache[lookup] = false
		return []
	# Every frame built once, then served from converted/frames/.
	var frames: Array = Assets.mesh_frames(lookup, bytes)
	if frames.is_empty():
		frame_cache[lookup] = false
		return []
	if frames.size() > 1:
		print("[enemy] %s — %d animation frames" % [lookup, frames.size()])
	frame_cache[lookup] = frames
	return frames

## Build the ArrayMesh list for a destructible's TRANSFRM.PRS damage
## stages (frame0 = intact). Returns [] when the mesh has no transform
## template — the destructible then vanishes when destroyed.
static func _destruct_stage_meshes(mesh_name: String, transfrm: Dictionary,
		objs: BSAReader, mesh_cache: Dictionary,
		provider: Callable) -> Array:
	var frames: PackedStringArray = transfrm.get(
		mesh_name.to_lower(), PackedStringArray())
	var out: Array = []
	for f in frames:
		var lookup := String(f).to_upper() + ".3D"
		var cached = mesh_cache.get(lookup, null)
		if cached is ArrayMesh:
			out.append(cached)
			continue
		var bytes: PackedByteArray = objs.read(lookup)
		if bytes.is_empty():
			out.append(null)
			continue
		var am: ArrayMesh = Assets.mesh(lookup, bytes)
		if am == null:
			out.append(null)
			continue
		mesh_cache[lookup] = am
		out.append(am)
	if out.size() > 1:
		print("[destruct] %s — %d damage stages" % [mesh_name, out.size()])
	return out

## Recursively attach the child segment meshes of a multi-segment actor
## (turret gun, barrel pair, turret head, tank turret …). Each segment is
## a static MeshInstance3D placed at its DOS mesh-origin offset/rotation;
## a segment that is itself multi-segment recurses.
##
## At depth 0 every segment is parented to a single "AimMount" Node3D so a
## turret with several siblings (e.g. dual barrels at -53/+53 X) rotates as
## one unit when wired as an aim node. Returns the AimMount, or null when
## no segments are attached.
static func _attach_segments(parent: Node3D, enemy_type: int,
		enms: BSAReader, objs: BSAReader, frame_cache: Dictionary,
		provider: Callable, depth: int = 0) -> Node3D:
	if depth > 4 or not ENEMY_SEGMENTS.has(enemy_type):
		return null
	var aim_mount: Node3D = null
	for seg in ENEMY_SEGMENTS[enemy_type]:
		var child_type: int = seg[0]
		var frames := _enemy_frames_for(child_type, enms, objs,
			frame_cache, provider)
		if frames.is_empty():
			continue
		var smi := MeshInstance3D.new()
		smi.mesh = frames[0]
		# The segment's own DOS type — enemy.gd builds its turret AI
		# (aim axis / limits / fire params) from it.
		smi.set_meta("seg_type", child_type)
		# A script-only machine (state 10: the grabber arm, the welding
		# arm, the torture rig) animates itself — hand it the whole frame
		# strip so enemy.gd can run its AIS script over it. "V pôvodnej
		# verzii hry toto rameno je animované, točí sa a ako keby
		# prekladalo veci" — GRABBER.3D has 33 frames we never played.
		if frames.size() > 1 and child_type < AIData.TYPES.size() 				and int(AIData.TYPES[child_type].get("st", -1)) == 10:
			smi.set_meta("seg_frames", frames)
		# DOS Y-down → Godot Y-up: negate Y and Z, as for meshes/entities.
		smi.position = Vector3(
			float(seg[1]), -float(seg[2]), -float(seg[3]))
		# Same rotation convention as variant-1 meshes:
		# Rz(-roll)·Rx(+pitch)·Ry(+yaw).
		var sb := Basis()
		sb = sb.rotated(Vector3.UP,     float(seg[5]) * TAU / 2048.0)
		sb = sb.rotated(Vector3.RIGHT,  float(seg[4]) * TAU / 2048.0)
		sb = sb.rotated(Vector3.BACK,  -float(seg[6]) * TAU / 2048.0)
		smi.basis = sb
		var target: Node3D = parent
		if depth == 0:
			if aim_mount == null:
				aim_mount = Node3D.new()
				aim_mount.name = "AimMount"
				parent.add_child(aim_mount)
			target = aim_mount
		target.add_child(smi)
		_attach_segments(smi, child_type, enms, objs,
			frame_cache, provider, depth + 1)
	return aim_mount

## Build the variant-3 billboard sprites and pickups. Each non-marker
## variant-3 entity carries a sprite_index: bank = index >> 7 selects the
## TEXTURE.NNN file, record = index & 0x7F the sub-record within it. The
## "weapons flat" / "equipment" banks become collectible Pickup nodes;
## every other bank is a static decorative billboard (barrels, rubble,
## bushes, corpses, signs …).
static func _build_sprites(level: Level, palette: PackedColorArray) -> void:
	level.sprites = Node3D.new()
	level.sprites.name = "Sprites"
	if level.map == null:
		return
	var img_cache: Dictionary = {}        # sprite_index → Texture2D
	var bank_hist: Dictionary = {}
	var placed: int = 0
	var pickups: int = 0
	for e in level.map.entities:
		if (e.flags & 3) != 3: continue
		if e.marker_type != -1: continue          # markers handled elsewhere
		if e.sprite_index < 0: continue
		var bank: int = e.sprite_index >> 7
		var rec_id: int = e.sprite_index & 0x7F
		bank_hist[bank] = bank_hist.get(bank, 0) + 1

		# Resolve (and cache) the sprite image — index 0 transparent.
		if not img_cache.has(e.sprite_index):
			img_cache[e.sprite_index] = Assets.texture(bank, rec_id, true)
		var tex: Texture2D = img_cache[e.sprite_index]
		if tex == null:
			continue

		var px: float = Assets.sprite_pixel_size(bank, rec_id, tex,
			pixel_scale_for(e.sprite_index))
		var world_h: float = float(tex.get_height()) * px
		# Ground level: outdoor sprites rest on the terrain surface;
		# indoor sprites use the placement Y.
		# Indoors the record's Y sits 16 u above the floor (the same +0x10
		# the enemy markers carry; a 2026-09-03 probe measured 13–26 u), so
		# the billboard's foot goes down to the floor.
		var base_y: float = -float(e.y) - INDOOR_SPRITE_LIFT
		if level.is_outdoor and level.wld != null:
			base_y = WldTerrain.height_at_world(
				level.wld, float(e.x), float(e.z))

		# Sprites listed in the DOS item table become collectible nodes
		# (FUN_0011d600 gives them act 0xFD at map start); the rest are
		# scenery — including the weapon-bank records the table omits.
		var spr: Node3D
		if PickupData.ITEMS.has(e.sprite_index):
			var p := Pickup.new()
			p.setup_item(e.sprite_index)
			p.set_meta("pickup_off", e.file_off)
			level.pickup_offs.append(e.file_off)
			_style_sprite(p, tex, px)
			p.position = Vector3(float(e.x), base_y + world_h * 0.5, -float(e.z))
			p.set_meta("bottom_off", -world_h * 0.5)
			spr = p
			pickups += 1
		else:
			# A record with several frames is a DOS animated billboard —
			# the fires (216 flames, 218 campfires, 208/206 burning drums)
			# store four, played in a loop from a per-entity start frame.
			# The start frame is the port's: DOS runs every animated record
			# off ONE free-running millisecond clock (FUN_00149e00 reads it
			# at 0x149e7a), so its fires all flicker in step. Kept because a
			# yard of identical flames in lockstep reads worse than DOS
			# looks — the rate below IS the record's own.
			var anim: SpriteFrames = sprite_anim(e.sprite_index)
			if anim != null:
				var a := AnimatedSprite3D.new()
				a.sprite_frames = anim
				_style_sprite(a, tex, px)
				a.frame = e.file_off % anim.get_frame_count("default")
				a.play("default")
				spr = a
			else:
				var s3 := Sprite3D.new()
				_style_sprite(s3, tex, px)
				spr = s3
			if dos_fullbright(e.sprite_index):
				spr.set_meta("fullbright", true)
			spr.position = Vector3(float(e.x), base_y + world_h * 0.5, -float(e.z))
			spr.set_meta("bottom_off", -world_h * 0.5)
		level.sprites.add_child(spr)
		placed += 1
		# Looping ambient sound from the 0x4cc00 sprite→sound table
		# (fires, barrels — FUN_0012a400 gives them act 0xEE at map
		# start). An explicit 0xEE record is a Sound node of the
		# Behaviour branch and plays from there (F2).
		if e.link_act_type == 0 and PickupData.AMBIENT.has(e.sprite_index):
			Audio.attach_loop_3d(int(PickupData.AMBIENT[e.sprite_index]), spr, -10.0)
	print("[level] placed %d billboard sprites (%d pickups)" % [placed, pickups])
	if _trace_on:                                # a load diagnostic
		var keys := bank_hist.keys()
		keys.sort()
		for b in keys:
			print("[sprite] bank %d x%d" % [b, bank_hist[b]])

## Where the outdoor haze is solid at RENDER DETAIL HIGH (16 000 x 1.8).
## main.gd takes its fog end from here (_apply_fog_distances); MED and
## LOW pull it in, never out.
const FOG_FAR: float = 16000.0 * 1.8
const DRAW_MARGIN: float = 200.0

## Stop drawing each piece of geometry under `root` once it is wholly past
## FOG_FAR, where depth fog has painted every pixel of it the flat haze
## colour (Godot measures the visibility range to the instance's AABB
## centre, so the piece's own radius goes on top). `radius` > 0 is one
## bound for every piece (an actor, whose frames move); 0 sizes each from
## its own bounds. `include_root` covers `root` itself.
static func limit_draw_distance(root: Node, radius: float = 0.0, include_root: bool = false) -> void:
	if root == null:
		return
	if include_root and root is Node3D:
		_limit_one(root, (root as Node3D).transform, radius)
	_limit_below(root, Transform3D(), radius)

static func _limit_below(n: Node, xf: Transform3D, radius: float) -> void:
	for c in n.get_children():
		if not (c is Node3D):
			continue
		var cxf: Transform3D = xf * (c as Node3D).transform
		_limit_one(c, cxf, radius)
		_limit_below(c, cxf, radius)

static func _limit_one(n: Node, xf: Transform3D, radius: float) -> void:
	if not (n is GeometryInstance3D):
		return
	var gi := n as GeometryInstance3D
	var r: float = radius
	if r <= 0.0 and gi is SpriteBase3D:
		# A sprite's bounds exist only once it has drawn; its rectangle
		# exists as soon as it has a texture.
		var sb := gi as SpriteBase3D
		var s: Vector3 = xf.basis.get_scale().abs()
		r = sb.get_item_rect().size.length() * sb.pixel_size * 0.5 * maxf(s.x, maxf(s.y, s.z))
	elif r <= 0.0:
		r = (xf * gi.get_aabb()).size.length() * 0.5
	# The margin is hysteresis around the end (Forward+); the end is set so
	# that even its low side stays past FOG_FAR + r.
	gi.visibility_range_end = FOG_FAR + r + DRAW_MARGIN * 2.0
	gi.visibility_range_end_margin = DRAW_MARGIN

## Fallback rate for an animated billboard whose record does not say how
## fast it runs. Every record in the shipped data does say — DOS keeps
## the period in milliseconds at descriptor +22 and divides its own
## millisecond clock by it (FUN_00149e00, 0x149e7f) — so this only
## catches a record with a zero there.
const SPRITE_ANIM_FPS: float = 12.0
static var _anim_cache: Dictionary = {}      # sprite index → SpriteFrames or null

## The frames of a multi-frame sprite record as SpriteFrames ("default",
## looping), or null for a single-frame one. The frames are converted once
## into the asset cache (Explosion.bank_frames — a single-frame record is
## remembered there as such, never decoded); the SpriteFrames are kept for
## the session.
##
## The speed is the record's own: 114 ms a frame for the fires of banks
## 208/216/218 (8.77 fps), 142 for bank 206's burning drum (7.04). The
## port used to run every one of them at a guessed 12.
static func sprite_anim(sprite_index: int) -> SpriteFrames:
	if _anim_cache.has(sprite_index):
		return _anim_cache[sprite_index]
	var bank: int = sprite_index >> 7
	var rec: int = sprite_index & 0x7F
	var frames: Array = Explosion.bank_frames(bank, rec, 2)
	var sf: SpriteFrames = null
	if frames.size() >= 2:
		var ms: int = Assets.record_frame_ms(bank, rec)
		sf = SpriteFrames.new()
		sf.set_animation_speed("default",
			1000.0 / float(ms) if ms > 0 else SPRITE_ANIM_FPS)
		sf.set_animation_loop("default", true)
		for t in frames:
			sf.add_frame("default", t)
	_anim_cache[sprite_index] = sf
	return sf

## The sprites DOS draws at full light whatever the room's shading
## (FUN_00124216 returns light 0x3f for exactly these — the fires):
## 192_000, 192_002, 206_001, 208_002-003, 216_005, 216_011-012, 218_000-003.
static func dos_fullbright(sprite_index: int) -> bool:
	if sprite_index == 0x6701 or sprite_index == 0x6002 or sprite_index == 0x6000:
		return true
	var bank: int = sprite_index >> 7
	var rec: int = sprite_index & 0x7F
	match bank:
		0xd0: return rec >= 2 and rec <= 3
		0xd8: return rec == 5 or rec == 0xb or rec == 0xc
		0xda: return rec <= 3
	return false

static func _style_sprite(spr: SpriteBase3D, tex: Texture2D, pixel_size: float = SPRITE_PIXEL_SIZE) -> void:
	if spr is Sprite3D:
		(spr as Sprite3D).texture = tex
	spr.pixel_size = pixel_size
	spr.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	spr.shaded = false
	spr.double_sided = true
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

## Spawn a destruction drop (v1.01 FUN_00124619, v1.00 FUN_00124119):
## one of the drop type's sprites at random (0 = nothing), placed on the
## ground under `pos` (Godot coordinates); a pickup when the item table
## lists it.
static func spawn_drop(level: Level, pos: Vector3, drop_type: int) -> Node3D:
	if level == null or level.sprites == null:
		return null
	if drop_type < 0 or drop_type >= PickupData.DROPS.size():
		return null
	var choices: Array = PickupData.DROPS[drop_type]
	if choices.is_empty():
		return null
	var si: int = int(choices[randi() % choices.size()])
	if si <= 0:
		return null
	return spawn_item(level, pos, si)

## One pickup sprite `si` placed on the ground at `pos` — the tail of
## spawn_drop, also reachable from the console (`drop <sprite index>`).
##
## zone-local ↔ world: `pos` is ZONE-LOCAL. The sprite becomes a child of
## level.sprites, which carries the zone origin, and the heightmap below
## is sampled in map coordinates — both want the DOS space, not the
## world one. Behaviour.item_dropped emits zone-local for this.
##
## A drop is an ordinary map billboard once it is down: DOS writes it into
## the record list (v1.01 FUN_00124619) and from then on draws it through
## the same path as the sprites the map was built with, asking for frame
## -1 (0x136f28) — so a multi-frame record left behind ANIMATES. What the
## wrecked cars of MAP.210 leave is exactly that: destruction type 0x68,
## drop list 2, TEXTURE.218 records 0-3, four frames each at 114 ms. The
## port made a plain Sprite3D here and took frame 0, so the wreck burned
## with the fire loop playing over a still picture (playtest 2026-09-16).
## The placed-sprite path (_build_sprites) has had the animation since
## 2026-09-11; this one was left behind.
static func spawn_item(level: Level, pos: Vector3, si: int) -> Node3D:
	if level == null or level.sprites == null:
		return null
	var tex: Texture2D = Assets.texture(si >> 7, si & 0x7F, true)
	if tex == null:
		return null
	var spr: SpriteBase3D
	if PickupData.ITEMS.has(si):
		var p := Pickup.new()
		p.setup_item(si)
		spr = p
	else:
		var anim: SpriteFrames = sprite_anim(si)
		if anim != null:
			var a := AnimatedSprite3D.new()
			a.sprite_frames = anim
			a.play("default")
			spr = a
		else:
			spr = Sprite3D.new()
		# No `fullbright` mark is needed here: _style_sprite leaves the
		# sprite unshaded, and the pass that shades indoor billboards
		# (main._light_level) has already run by the time anything drops.
	var px: float = Assets.sprite_pixel_size(si >> 7, si & 0x7F, tex,
		pixel_scale_for(si))
	_style_sprite(spr, tex, px)
	var ground: float = pos.y
	if level.is_outdoor and level.wld != null:
		ground = WldTerrain.height_at_world(level.wld, pos.x, -pos.z)
	var world_h: float = float(tex.get_height()) * px
	spr.position = Vector3(pos.x, ground + world_h * 0.5, pos.z)
	level.sprites.add_child(spr)
	if level.is_outdoor:
		_limit_one(spr, spr.transform, 0.0)
	if PickupData.AMBIENT.has(si):
		Audio.attach_loop_3d(int(PickupData.AMBIENT[si]), spr, -10.0)
	return spr
