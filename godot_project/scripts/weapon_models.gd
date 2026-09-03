## ENHANCED weapon models: the guns lying on the ground as small
## primitive-built 3D objects instead of flat billboards.
##
## The DOS pickup sprites are side views (barrel to the right), so every
## model here is built lying along +X, centred on the origin, and sized
## to the sprite it replaces — the same contract as pickup_models.gd,
## whose materials (procedural grime + normal map, triplanar) and
## primitive helpers this reuses.
##
## The weapon HELD IN THE HANDS is a different matter: the DOS viewmodel
## is hand-drawn CFA animation with the soldier's gloves in frame, which
## no box-and-cylinder model can match. That art stays.

extends RefCounted

const PickupModels := preload("res://scripts/pickup_models.gd")

const STEEL := Color(0.30, 0.31, 0.34)
const DARK := Color(0.13, 0.14, 0.16)
const WOOD := Color(0.34, 0.19, 0.10)
const OLIVE := Color(0.25, 0.27, 0.17)
const GLOW_RED := Color(0.85, 0.15, 0.10)
const GLOW_BLUE := Color(0.25, 0.65, 0.95)

## DOS pickup sprite index → the model to build. The ids are the same
## `sprite_index` values pickup_data.gd keys its item table on.
const MODELS: Dictionary = {
	25736: "shotgun",       # 201_008 SHOTGUN
	25737: "uzi",           # 201_009 UZI
	25611: "laser",         # 200_011 LASER RIFLE
	25730: "rifle",         # 201_002 assault rifle
	25731: "rifle",         # 201_003
	25732: "plasma",        # 201_004
	25733: "launcher",      # 201_005 rocket launcher
}

## The model for each weapon slot of fly_camera._weapons, for the
## optional 3D view model (DETAIL → WEAPON VIEW).
const WEAPON_KINDS: Array = [
	"pipe",      # 0  PIPE
	"uzi",       # 1  UZI
	"rifle",     # 2  ASSAULT RIFLE
	"rifle",     # 3  MACHINE GUN
	"shotgun",   # 4  SHOTGUN
	"launcher",  # 5  GRENADE LAUNCHER
	"launcher",  # 6  ROCKET LAUNCHER
	"laser",     # 7  LASER RIFLE
	"laser",     # 8  LASER CANNON
	"plasma",    # 9  PLASMA PISTOL
	"plasma",    # 10 PLASMA RIFLE
	"plasma",    # 11 PLASMA CANNON
	"uzi",       # 12 SUPER UZI
]

static func has(sprite_index: int) -> bool:
	return MODELS.has(sprite_index)

## The model for weapon slot `idx`, or null.
static func for_weapon(idx: int, w: float, h: float) -> Node3D:
	if idx < 0 or idx >= WEAPON_KINDS.size():
		return null
	return build_kind(String(WEAPON_KINDS[idx]), w, h)

## A weapon `w` long and `h` tall (world units), centred on the origin
## and lying along +X, like the sprite it stands in for.
static func build(sprite_index: int, w: float, h: float) -> Node3D:
	return build_kind(String(MODELS.get(sprite_index, "")), w, h)

static func build_kind(kind: String, w: float, h: float) -> Node3D:
	if kind.is_empty():
		return null
	var root := Node3D.new()
	root.name = "WeaponModel"
	match kind:
		"pipe":
			_barrel(root, h * 0.16, w * 0.86, Color(0.34, 0.33, 0.30), Vector3.ZERO)
			_ring(root, h * 0.22, h * 0.14, Color(0.28, 0.27, 0.25), Vector3(w * 0.24, 0.0, 0.0))
			_ring(root, h * 0.20, h * 0.12, Color(0.28, 0.27, 0.25), Vector3(-w * 0.30, 0.0, 0.0))
		"uzi":
			# Boxy receiver, short barrel, magazine down, folded stock.
			_box(root, Vector3(w * 0.42, h * 0.42, h * 0.34), DARK, Vector3(-w * 0.05, 0.0, 0.0))
			_barrel(root, h * 0.10, w * 0.34, STEEL, Vector3(w * 0.33, h * 0.10, 0.0))
			_box(root, Vector3(h * 0.22, h * 0.62, h * 0.24), DARK, Vector3(-w * 0.02, -h * 0.48, 0.0))
			_box(root, Vector3(h * 0.20, h * 0.44, h * 0.22), DARK, Vector3(-w * 0.20, -h * 0.34, 0.0))
			_box(root, Vector3(w * 0.30, h * 0.10, h * 0.12), STEEL, Vector3(-w * 0.34, h * 0.06, 0.0))
			_sight(root, w, h, -w * 0.16)
		"rifle":
			_box(root, Vector3(w * 0.46, h * 0.34, h * 0.30), DARK, Vector3(-w * 0.02, 0.0, 0.0))
			_barrel(root, h * 0.09, w * 0.44, STEEL, Vector3(w * 0.42, h * 0.06, 0.0))
			_box(root, Vector3(h * 0.24, h * 0.56, h * 0.22), DARK, Vector3(w * 0.02, -h * 0.42, 0.0))
			_box(root, Vector3(h * 0.20, h * 0.40, h * 0.20), DARK, Vector3(-w * 0.18, -h * 0.30, 0.0))
			_box(root, Vector3(w * 0.26, h * 0.34, h * 0.22), OLIVE, Vector3(-w * 0.36, -h * 0.06, 0.0))
			_sight(root, w, h, -w * 0.10)
		"shotgun":
			# Two tubes over a wooden pump and stock.
			_barrel(root, h * 0.11, w * 0.60, STEEL, Vector3(w * 0.18, h * 0.14, 0.0))
			_barrel(root, h * 0.09, w * 0.52, DARK, Vector3(w * 0.14, -h * 0.04, 0.0))
			_box(root, Vector3(w * 0.16, h * 0.26, h * 0.26), WOOD, Vector3(w * 0.02, -h * 0.04, 0.0))
			_box(root, Vector3(w * 0.20, h * 0.34, h * 0.24), DARK, Vector3(-w * 0.22, 0.0, 0.0))
			_box(root, Vector3(w * 0.30, h * 0.40, h * 0.22), WOOD, Vector3(-w * 0.40, -h * 0.10, 0.0))
			_box(root, Vector3(h * 0.20, h * 0.42, h * 0.20), WOOD, Vector3(-w * 0.16, -h * 0.34, 0.0))
		"laser":
			# Slim body, ribbed emitter, a lit accent along the receiver.
			_box(root, Vector3(w * 0.44, h * 0.30, h * 0.26), Color(0.22, 0.24, 0.28), Vector3(-w * 0.04, 0.0, 0.0))
			_barrel(root, h * 0.10, w * 0.40, STEEL, Vector3(w * 0.36, h * 0.04, 0.0))
			for i in 3:
				_ring(root, h * 0.15, h * 0.06, STEEL, Vector3(w * 0.26 + float(i) * w * 0.09, h * 0.04, 0.0))
			_emitter(root, h * 0.11, GLOW_RED, Vector3(w * 0.56, h * 0.04, 0.0))
			_box(root, Vector3(w * 0.26, h * 0.08, h * 0.10), GLOW_RED, Vector3(-w * 0.06, h * 0.18, 0.0), true)
			_box(root, Vector3(h * 0.22, h * 0.52, h * 0.20), DARK, Vector3(-w * 0.02, -h * 0.40, 0.0))
			_box(root, Vector3(w * 0.28, h * 0.30, h * 0.20), Color(0.22, 0.24, 0.28), Vector3(-w * 0.38, -h * 0.06, 0.0))
		"plasma":
			# Fat body with a coil and a blue muzzle.
			_box(root, Vector3(w * 0.40, h * 0.44, h * 0.36), Color(0.20, 0.24, 0.30), Vector3(-w * 0.06, 0.0, 0.0))
			_barrel(root, h * 0.16, w * 0.34, STEEL, Vector3(w * 0.32, h * 0.02, 0.0))
			for i in 4:
				_ring(root, h * 0.21, h * 0.05, GLOW_BLUE, Vector3(w * 0.20 + float(i) * w * 0.08, h * 0.02, 0.0))
			_emitter(root, h * 0.15, GLOW_BLUE, Vector3(w * 0.52, h * 0.02, 0.0))
			_box(root, Vector3(h * 0.24, h * 0.54, h * 0.22), DARK, Vector3(-w * 0.04, -h * 0.46, 0.0))
			_box(root, Vector3(w * 0.24, h * 0.34, h * 0.24), Color(0.20, 0.24, 0.30), Vector3(-w * 0.34, -h * 0.06, 0.0))
		"launcher":
			# A tube with a sight block on top and a grip below.
			_barrel(root, h * 0.28, w * 0.86, Color(0.26, 0.28, 0.24), Vector3(0.0, h * 0.06, 0.0))
			_ring(root, h * 0.31, h * 0.10, DARK, Vector3(w * 0.40, h * 0.06, 0.0))
			_ring(root, h * 0.31, h * 0.10, DARK, Vector3(-w * 0.38, h * 0.06, 0.0))
			_box(root, Vector3(w * 0.26, h * 0.24, h * 0.26), DARK, Vector3(-w * 0.02, h * 0.36, 0.0))
			_box(root, Vector3(w * 0.18, h * 0.16, h * 0.20), GLOW_BLUE, Vector3(-w * 0.02, h * 0.40, h * 0.14), true)
			_box(root, Vector3(h * 0.22, h * 0.44, h * 0.20), DARK, Vector3(-w * 0.10, -h * 0.34, 0.0))
	return root

# --- primitives, all lying along +X ------------------------------------
static func _box(root: Node3D, size: Vector3, col: Color, at: Vector3, glow: bool = false) -> MeshInstance3D:
	return PickupModels._box(root, size, col, at, glow)

## A cylinder lying along +X (the helpers build them upright).
static func _barrel(root: Node3D, radius: float, length: float, col: Color, at: Vector3) -> MeshInstance3D:
	var mi: MeshInstance3D = PickupModels._cyl(root, radius, length, col, at)
	mi.rotation = Vector3(0.0, 0.0, PI * 0.5)
	return mi

static func _ring(root: Node3D, radius: float, width: float, col: Color, at: Vector3) -> MeshInstance3D:
	var mi: MeshInstance3D = PickupModels._cyl(root, radius, width, col, at)
	mi.rotation = Vector3(0.0, 0.0, PI * 0.5)
	return mi

## The lit muzzle of an energy weapon.
static func _emitter(root: Node3D, radius: float, col: Color, at: Vector3) -> void:
	var mi: MeshInstance3D = PickupModels._cyl(root, radius, radius * 0.6, col, at)
	mi.rotation = Vector3(0.0, 0.0, PI * 0.5)
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 2.2
	mi.material_override = m

static func _sight(root: Node3D, w: float, h: float, x: float) -> void:
	_box(root, Vector3(w * 0.05, h * 0.14, h * 0.06), DARK, Vector3(x, h * 0.26, 0.0))
