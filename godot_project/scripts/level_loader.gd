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
const Palette      := preload("res://scripts/loaders/palette.gd")
const TextureNNN   := preload("res://scripts/loaders/texture_nnn.gd")
const TextureCache := preload("res://scripts/loaders/texture_cache.gd")
const WldTerrain   := preload("res://scripts/loaders/wld_terrain.gd")
const Enemy        := preload("res://scripts/enemy.gd")
const ActionSystem := preload("res://scripts/action_system.gd")
const ActionTarget := preload("res://scripts/action_target.gd")
const TransfrmPRS  := preload("res://scripts/loaders/transfrm_prs.gd")
const EnemyAnim    := preload("res://scripts/enemy_anim.gd")
const AIData       := preload("res://scripts/enemy_ai_data.gd")
const Pickup       := preload("res://scripts/pickup.gd")
const PickupData   := preload("res://scripts/pickup_data.gd")

## Variant-3 billboard sprite banks (sprite_index >> 7) → TEXTURE.NNN file.
## "weapons flat" banks are weapon/ammo pickups, "equipment" is gear; the
## rest are decorative scenery (barrels, rubble, bushes, corpses …).
const SPRITE_AMMO_BANKS   := [200, 201]   # TEXTURE.200/201 "weapons flat"
const SPRITE_HEALTH_BANKS := [214]        # TEXTURE.214 "equipment"
## World units per sprite texel — billboards are sized texture_px × this.
## DOS draws a flat at texture_dims × a perspective scale (skynet_gh.c
## FUN_0014f4xx: `tex_w * puVar1[0x11]`); the texture dimensions already
## carry each prop's relative size, so a single world-scale suffices.
const SPRITE_PIXEL_SIZE: float = 2.0

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

## Per-enemy combat stats: [max_health, shot_damage, fire_interval,
## move_speed]. Hand-tuned (the DOS table is not statically extractable);
## actors not listed use ENEMY_STATS_DEFAULT.
const ENEMY_STATS_DEFAULT: Array = [60.0, 9.0, 1.9, 480.0]
const ENEMY_STATS: Dictionary = {
	"raptor":   [45.0, 7.0, 1.6, 720.0],
	"globe":    [30.0, 6.0, 2.0, 560.0],
	"drone":    [35.0, 6.0, 1.9, 600.0],
	"scout":    [40.0, 7.0, 1.8, 700.0],
	"flencer":  [40.0, 6.0, 1.8, 600.0],
	"hk_ftr":   [120.0, 14.0, 1.4, 900.0],
	"hk_bmbr":  [150.0, 16.0, 1.6, 800.0],
	"hvytrrt":  [100.0, 12.0, 1.3, 0.0],
	"hvytrrt2": [110.0, 12.0, 1.3, 0.0],
	"hvytrrt3": [110.0, 13.0, 1.2, 0.0],
	"smltrrt":  [60.0, 8.0, 1.5, 0.0],
	"guntwr1":  [140.0, 11.0, 1.6, 0.0],
	"guntwr3":  [150.0, 12.0, 1.5, 0.0],
	"endorfl":  [70.0, 10.0, 1.5, 480.0],
	"endoskel": [70.0, 9.0, 1.6, 500.0],
	"t600pst":  [80.0, 9.0, 1.6, 440.0],
	"t600rfl":  [85.0, 11.0, 1.4, 440.0],
	"t800pst":  [110.0, 10.0, 1.5, 460.0],
	"t800rfl":  [120.0, 12.0, 1.3, 460.0],
	"mantnk":   [200.0, 18.0, 1.4, 380.0],
	"hvytnk":   [240.0, 20.0, 1.5, 320.0],
	"hvrtnk":   [160.0, 15.0, 1.5, 520.0],
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
	var map: MapFile.MapFile
	var wld: WldTerrain.WLD
	var terrain: MeshInstance3D
	var entities: Node3D                 # variant-1 .3D meshes
	var enemies: Node3D                  # variant-3 enemy-marker actors
	var sprites: Node3D                  # variant-3 billboard sprites + pickups
	var sky: MeshInstance3D              # SKY_SKY.3D — attach to camera
	var centroid: Vector3 = Vector3.ZERO
	var entity_count: int = 0
	var enemy_count: int = 0
	var is_outdoor: bool = false
	var map_suffix: String = ""           # e.g. "210"
	var map_bytes: PackedByteArray = PackedByteArray()   # the MAP file as loaded
	var terrain_tex: TextureNNN.TexFile   # TEXTURE.NNN for map-specific terrain materials
	## Player spawn read from the MAP markers (DOS-faithful):
	##   marker_type 0 = start position, marker_type 1 = facing direction.
	var player_start: Vector3 = Vector3.ZERO
	var player_dir: Vector3 = Vector3.ZERO
	var has_player_start: bool = false
	## Entity action/link system (doors, movers, destructibles,
	## proximity triggers, teleports). The level controller ticks it.
	var action: ActionSystem = null
	## Every placement marker by id → Array of world positions (a map may
	## carry several markers with one id, e.g. two facing markers). Map
	## exits spawn the player at marker N facing marker N+1
	## (PlrSetPosMarker FUN_00121f72, skynet_gh.c:25074-25087).
	var markers: Dictionary = {}
	## MAP file offsets of the enemy markers / pickups that were spawned —
	## the per-map state overlay records which of them are gone.
	var enemy_marker_offs: Array = []
	var pickup_offs: Array = []

## Load a level by its MAP basename (e.g. "MAP.210").
func load_level(map_name: String) -> Level:
	var level := Level.new()

	# Palette (shared) ---------------------------------------------
	var imgs := BSAReader.new()
	if not imgs.open(SkynetPaths.gamedata_path("MDMDIMGS.BSA"), SkynetPaths.variant):
		push_error("[level] cannot open MDMDIMGS.BSA")
		return null
	var pal_bytes := imgs.read("SKYNET.COL")
	if pal_bytes.is_empty(): pal_bytes = imgs.read("BRIEF.COL")
	imgs.close()
	var palette := Palette.parse(pal_bytes)
	if palette.is_empty():
		push_error("[level] palette load failed")
		return null

	# MAP ----------------------------------------------------------
	var maps := BSAReader.new()
	if not maps.open(SkynetPaths.gamedata_path("MDMDMAP2.BSA"), SkynetPaths.variant):
		push_error("[level] cannot open MDMDMAP2.BSA")
		return null
	var map_bytes := maps.read(map_name)
	maps.close()
	# An edited map (editor export) overrides the archive entry.
	var mod := "res://mods/maps/%s" % map_name.to_upper()
	if FileAccess.file_exists(mod):
		var mb := SkynetPaths.read_bytes(mod)
		if not mb.is_empty():
			map_bytes = mb
			print("[level] %s: using mod file %s" % [map_name, mod])
	if map_bytes.is_empty():
		push_error("[level] MAP not found: %s" % map_name)
		return null
	level.map = MapFile.parse(map_bytes)
	if level.map == null:
		push_error("[level] MAP parse failed: %s" % map_name)
		return null
	level.map_bytes = map_bytes
	level.map_suffix = map_name.split(".")[-1]
	# Indoor/outdoor flag at MAP+9028 (sub_153A8B reads `MAP[+9028] == 1`).
	if map_bytes.size() > 9028 + 4:
		var flag: int = map_bytes[9028] | (map_bytes[9029] << 8) \
			| (map_bytes[9030] << 16) | (map_bytes[9031] << 24)
		level.is_outdoor = (flag == 1)
	print("[level] %s: grid %dx%d, %d names, %d entities, %s"
		% [map_name, level.map.grid_width, level.map.grid_height,
		   level.map.names.size(), level.map.entities.size(),
		   "OUTDOOR" if level.is_outdoor else "INDOOR"])

	# Action/link system — chains, movers, destructibles, teleports.
	level.action = ActionSystem.new()
	level.action.setup(level.map)
	# TRANSFRM.PRS (destructible damage stages) lives in MDMDBRIF.BSA.
	var transfrm: Dictionary = {}
	var brif := BSAReader.new()
	if brif.open(SkynetPaths.gamedata_path("MDMDBRIF.BSA"),
			SkynetPaths.variant):
		transfrm = TransfrmPRS.parse(brif.read("TRANSFRM.PRS"))
		brif.close()

	# WLD (outdoor only) -------------------------------------------
	if level.is_outdoor:
		var wld_path := SkynetPaths.gamedata_path("WLD.%s" % level.map_suffix)
		var wld_bytes := SkynetPaths.read_bytes(wld_path)
		if not wld_bytes.is_empty():
			level.wld = WldTerrain.parse(wld_bytes)
			print("[level] WLD.%s loaded" % level.map_suffix)
		else:
			push_warning("[level] outdoor flag set but WLD.%s missing"
				% level.map_suffix)

	# Terrain tile textures — the WLD chunk header references TEXTURE.302
	# (verified: 62× 64×64 "lndscps" records). Each cell binds one tile by
	# (layer2 & 0x3F); build_terrain_mesh tiles it world-planar so roads
	# flow unbroken across cells.
	if level.is_outdoor:
		var tex302_bytes := SkynetPaths.read_bytes(
			SkynetPaths.gamedata_path("TEXTURE.302"))
		if not tex302_bytes.is_empty():
			level.terrain_tex = TextureNNN.parse(tex302_bytes)

	# Terrain mesh — built once and served from the asset cache
	# (converted/terrain/WLD.NNN.res); the tiles come from TEXTURE.302.
	if level.wld:
		var terrain_mesh := Assets.terrain(level.map_suffix, level.wld)
		if terrain_mesh:
			level.terrain = MeshInstance3D.new()
			level.terrain.name = "Terrain"
			level.terrain.mesh = terrain_mesh

	# Entities (variant 1 only) ------------------------------------
	level.entities = Node3D.new()
	level.entities.name = "Entities"

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
	for e in level.map.entities:
		if (e.flags & 3) != 1: continue
		var name: String = MapFile.entity_name(level.map, e)
		if name.is_empty(): continue
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

		# Classification by the entity's action/handler id (the 0x59b00
		# table families, recovered from Skynet.exe): doors, gates,
		# lifts and rotators are MOVER types — their DOS handlers move
		# the entity transform per tick (NOT mesh-frame swaps; every
		# door .3D in the archives is single-frame). 0x18/0x19 are
		# TRANSFRM.PRS destructibles. Anything damageable (state bits
		# 1+2, ObjHit skynet_gh.c:39512) needs a hit/activate route.
		# Everything else is plain static geometry.
		var act: int = e.link_act_type
		# Destructibles bind BY NAME to TRANSFRM.PRS (TransformInit
		# keys templates on the mesh name) — cars carry state bit1 +
		# HP but act 0x00 in the MAP data.
		var has_transfrm: bool = transfrm.has(name.to_lower())
		# Anything with HP is a hit target too (ObjHit drains it whatever
		# the state bits say — crates, buses, the dish take their HP from
		# the map's per-name defaults).
		var wants_action: bool = (ActionSystem.is_mover(act)
			or ActionSystem.is_destructible(act) or has_transfrm
			or (e.state_byte & 6) != 0 or e.hp > 0
			or act == 0xEF or act == 0xF1 or act == 0xF2)
		var mi: MeshInstance3D
		if wants_action:
			var at := ActionTarget.new()
			at.setup_action(level.action, e.file_off)
			# Sibling name collisions get renamed by the scene tree — keep
			# the mesh identity where the action system can read it.
			at.set_meta("mesh_name", name)
			mi = at
		else:
			mi = MeshInstance3D.new()
		mi.name = name
		mi.mesh = am

		# Position: entity X/Y/Z used VERBATIM from the MAP record. The DOS
		# engine never samples terrain height nor applies an AABB offset
		# for placed meshes — entity.Y (MAP +0x0C, Y-down) is already the
		# absolute world Y (verified skynet_gh.c FUN_00136519:38194-38198).
		var pos := Vector3(float(e.x), -float(e.y), -float(e.z))

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
		level.entities.add_child(mi)
		if wants_action:
			# Register after the transform is final — the mover base
			# transform is captured here.
			level.action.register_node(e, mi)
			# Staged wrecks need a TRANSFRM.PRS template for the name; a
			# 0x19 act without one (CARHIP2C via the defaults) just runs
			# the plain HP path.
			if has_transfrm:
				level.action.register_destructible(e,
					_destruct_stage_meshes(name, transfrm, objs,
						mesh_cache, provider))
		sum_x += pos.x; sum_y += pos.y; sum_z += pos.z
		n += 1

	# --- Enemies (variant-3 markers, marker_type 2) -----------------
	# Enemies are NOT variant-1 actors — they are variant-3 placement
	# markers (FUN_0011c519 MapScanMarkers / FUN_00129f39 in skynet_gh.c).
	# Each marker's enemy-type ID is at sub+10 and selects the mesh via
	# the ENEMY_MESH table; meshes live in MDMDENMS.BSA.
	level.enemies = Node3D.new()
	level.enemies.name = "Enemies"
	var en: int = 0
	var enemy_hist: Dictionary = {}
	if have_enms:
		for e in level.map.entities:
			if (e.flags & 3) != 3: continue
			if e.marker_type != 2: continue        # 2 = enemy start marker
			enemy_hist[e.enemy_type] = enemy_hist.get(e.enemy_type, 0) + 1
			var eframes := _enemy_frames_for(e.enemy_type, enms, objs,
				enemy_frame_cache, provider)
			if eframes.is_empty(): continue
			var ebase: String = ""
			if e.enemy_type >= 0 and e.enemy_type < ENEMY_MESH.size():
				ebase = ENEMY_MESH[e.enemy_type]
			# Enemy actor: animates the .3D frames and runs a simple AI.
			var emi := Enemy.new()
			emi.name = "enemy%d_%s" % [en, ebase]
			var eaabb: AABB = (eframes[0] as ArrayMesh).get_aabb()
			# Per-type combat stats (must be set before setup()).
			var st: Array = ENEMY_STATS.get(ebase, ENEMY_STATS_DEFAULT)
			emi.max_health = st[0]
			# DOS hit points win over the hand-tuned estimate when the
			# type table carries them.
			if e.enemy_type < ENEMY_HP.size() and ENEMY_HP[e.enemy_type] > 0:
				emi.max_health = float(ENEMY_HP[e.enemy_type])
			emi.set_meta("marker_off", e.file_off)
			level.enemy_marker_offs.append(e.file_off)
			emi.shot_damage = st[1]
			emi.fire_interval = st[2]
			emi.move_speed = st[3]
			# DOS type data (state id, speed, turn, fire params, script,
			# frame-event sounds …) — overrides the hand-tuned numbers.
			emi.configure(e.enemy_type)
			# Wreck parts flung on death (enemy table +0x10 death list).
			emi.death_parts = _death_parts_for(e.enemy_type, enms, objs,
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
			emi.position = Vector3(
				float(e.x), -float(e.y + 0x10), -float(e.z))
			# Face the marker's yaw (sub+4, 11-bit angle) like variant-1.
			# Godot yaw = +yaw (DOS Ry(-yaw) conjugated by diag(1,-1,-1)).
			var eyaw: float = (e.off_y & 0x7FF) * TAU / 2048.0
			emi.rotation.y = eyaw
			level.enemies.add_child(emi)
			# Attach the actor's child segments (turret gun, barrels,
			# turret head …) for multi-segment enemies. For stationary
			# turrets the first top-level segment is the rotating head —
			# wire it as the aim node so only it tracks the player and
			# the base stays still.
			var aim_seg := _attach_segments(emi, e.enemy_type, enms, objs,
				enemy_frame_cache, provider)
			if aim_seg != null and STATIONARY_ENEMIES.has(ebase):
				emi.set_aim_node(aim_seg)
			# Marker sub+2 (u16, parsed into exit_map for variant 3) =
			# trigger distance: a dormant trap that detonates when the
			# player comes close (EnemiesStartMarked FUN_00129f39 →
			# FUN_00142800, death state 0x14285e). Enemy markers carry
			# no spawn yaw — DOS actors start facing +Z.
			var trig: int = e.exit_map & 0xFFFF
			if trig > 0:
				emi.make_dormant(float(trig))
			en += 1
	level.enemy_count = en
	print("[level] placed %d enemies (variant-3 markers)" % en)
	for et in enemy_hist:
		var nm: String = "?" if et < 0 or et >= ENEMY_MESH.size() \
			else ENEMY_MESH[et]
		var fc: int = 0
		var sample: Array = enemy_frame_cache.get(nm + ".3D", [])
		if sample is Array:
			fc = sample.size()
		print("[enemy] type %d (0x%X) ×%d → %s  frames=%d"
			% [et, et, enemy_hist[et], nm, fc])

	# --- Billboard sprites + pickups (variant-3 non-marker) ---------
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

	# Rotation debug: show angle values per mesh type (pitch/yaw/roll).
	var rot_samples: Dictionary = {}
	for e in level.map.entities:
		if (e.flags & 3) != 1: continue
		var ename: String = MapFile.entity_name(level.map, e)
		if ename.is_empty(): continue
		if not rot_samples.has(ename):
			rot_samples[ename] = []
		if rot_samples[ename].size() < 3:
			rot_samples[ename].append([e.off_x, e.off_y, e.off_z])
	for ename in rot_samples:
		for vals in rot_samples[ename]:
			var pitch: int = vals[0] & 0x7FF
			var yaw: int   = vals[1] & 0x7FF
			var roll: int  = vals[2] & 0x7FF
			print("[rot] %s: raw=(%d,%d,%d) pitch/yaw/roll deg=(%.1f,%.1f,%.1f)"
				% [ename, vals[0], vals[1], vals[2],
				   pitch * 360.0 / 2048.0, yaw * 360.0 / 2048.0,
				   roll * 360.0 / 2048.0])

	return level

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

		var world_h: float = float(tex.get_height()) * SPRITE_PIXEL_SIZE
		# Ground level: outdoor sprites rest on the terrain surface;
		# indoor sprites use the placement Y.
		var base_y: float = -float(e.y)
		if level.is_outdoor and level.wld != null:
			base_y = WldTerrain.height_at_world(
				level.wld, float(e.x), float(e.z))

		# Sprites listed in the DOS item table become collectible nodes
		# (FUN_0011d600 gives them act 0xFD at map start); the rest are
		# scenery — including the weapon-bank records the table omits.
		var spr: Sprite3D
		if PickupData.ITEMS.has(e.sprite_index):
			var p := Pickup.new()
			p.setup_item(e.sprite_index)
			p.set_meta("pickup_off", e.file_off)
			level.pickup_offs.append(e.file_off)
			spr = p
			pickups += 1
		else:
			spr = Sprite3D.new()
		_style_sprite(spr, tex)
		spr.position = Vector3(
			float(e.x), base_y + world_h * 0.5, -float(e.z))
		level.sprites.add_child(spr)
		placed += 1
		# Looping ambient sound: the 0x4cc00 sprite→sound table (fires,
		# barrels — FUN_0012a400 gives them act 0xEE) or an explicit 0xEE
		# node whose sound id sits at sub+2 (exit_map holds that u16).
		var amb: int = -1
		if e.link_act_type == 0xEE:
			amb = e.exit_map
		elif e.link_act_type == 0 and PickupData.AMBIENT.has(e.sprite_index):
			amb = int(PickupData.AMBIENT[e.sprite_index])
		if amb >= 0:
			Audio.attach_loop_3d(amb, spr, -10.0)
	print("[level] placed %d billboard sprites (%d pickups)"
		% [placed, pickups])
	var keys := bank_hist.keys()
	keys.sort()
	for b in keys:
		print("[sprite] bank %d x%d" % [b, bank_hist[b]])

static func _style_sprite(spr: Sprite3D, tex: Texture2D) -> void:
	spr.texture = tex
	spr.pixel_size = SPRITE_PIXEL_SIZE
	spr.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	spr.shaded = false
	spr.double_sided = true
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

## Spawn a destruction drop (FUN_00124119): one of the drop type's
## sprites at random (0 = nothing), placed on the ground under `pos`
## (Godot coordinates); a pickup when the item table lists it.
static func spawn_drop(level: Level, pos: Vector3, drop_type: int) -> Sprite3D:
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
	var tex: Texture2D = Assets.texture(si >> 7, si & 0x7F, true)
	if tex == null:
		return null
	var spr: Sprite3D
	if PickupData.ITEMS.has(si):
		var p := Pickup.new()
		p.setup_item(si)
		spr = p
	else:
		spr = Sprite3D.new()
	_style_sprite(spr, tex)
	var ground: float = pos.y
	if level.is_outdoor and level.wld != null:
		ground = WldTerrain.height_at_world(level.wld, pos.x, -pos.z)
	var world_h: float = float(tex.get_height()) * SPRITE_PIXEL_SIZE
	spr.position = Vector3(pos.x, ground + world_h * 0.5, pos.z)
	level.sprites.add_child(spr)
	if PickupData.AMBIENT.has(si):
		Audio.attach_loop_3d(int(PickupData.AMBIENT[si]), spr, -10.0)
	return spr
