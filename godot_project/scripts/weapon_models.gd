## ENHANCED weapon models: the guns lying on the ground as small
## primitive-built 3D objects instead of flat billboards, and the
## optional 3D view model (DETAIL → WEAPON VIEW).
##
## The DOS pickup sprites are side views (barrel to the right), so every
## model here is built lying along +X, centred on the origin, and sized
## to the sprite it replaces — `w` is the whole length, `h` the whole
## height INCLUDING the magazine and the grip, because that is what the
## sprite's bounding box covers.
##
## Second pass 2026-09-04 ("try harder on the 3D models"): the first cut
## was a handful of same-material boxes. Now every gun is built from
## named MATERIALS — gunmetal, steel, polymer, wood, rubber, brass and a
## lit accent — carries a real trigger inside a torus guard, proper
## sights, a tapered magazine and a butt pad, and the round parts are
## smooth cylinders and tori rather than blocks. Everything shares
## pickup_models' grime texture so the guns wear the same dirt as the
## crates around them.

extends RefCounted

const PickupModels := preload("res://scripts/pickup_models.gd")

# --- materials ---------------------------------------------------------
## kind → [albedo, metallic, roughness, emission energy]
const MATERIALS: Dictionary = {
	"gunmetal": [Color(0.15, 0.155, 0.175), 0.85, 0.38, 0.0],
	"steel":    [Color(0.42, 0.43, 0.46), 0.95, 0.24, 0.0],
	"blued":    [Color(0.10, 0.11, 0.14), 0.90, 0.30, 0.0],
	"polymer":  [Color(0.09, 0.09, 0.10), 0.00, 0.72, 0.0],
	"rubber":   [Color(0.055, 0.055, 0.06), 0.00, 0.95, 0.0],
	"wood":     [Color(0.30, 0.16, 0.075), 0.00, 0.55, 0.0],
	"brass":    [Color(0.62, 0.46, 0.16), 0.90, 0.30, 0.0],
	"olive":    [Color(0.20, 0.22, 0.13), 0.10, 0.70, 0.0],
	"glass":    [Color(0.06, 0.09, 0.12), 0.55, 0.10, 0.0],
	"glow":     [Color(1.0, 1.0, 1.0), 0.0, 0.4, 2.6],
}

const GLOW_RED := Color(0.95, 0.16, 0.10)
const GLOW_BLUE := Color(0.30, 0.70, 1.0)
const GLOW_GREEN := Color(0.35, 1.0, 0.45)

## Which sprite gets which gun is not a table here — the DOS item table
## already says it. pickup_data.ITEMS[sprite][4] is the weapon slot the
## pickup grants, so the model follows from WEAPON_KINDS and can never
## drift out of step with what the player actually picks up. (The first
## cut hand-listed sprite ids and got three of seven wrong: 25730/25732
## are not pickups at all, and 25731 is the PLASMA PISTOL, not a rifle.)
const PickupData := preload("res://scripts/pickup_data.gd")

## Guns are longer than they are tall; the DOS art for some of them is
## only 10-13 px high, which squeezes the grip and the stock into
## nothing. Never build one flatter than this fraction of its length.
const MIN_ASPECT: float = 0.22

## The weapon slot a pickup sprite grants, or -1.
static func weapon_of(sprite_index: int) -> int:
	var item: Array = PickupData.ITEMS.get(sprite_index, [])
	return int(item[4]) if item.size() > 4 else -1

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
	var slot: int = weapon_of(sprite_index)
	return slot >= 0 and slot < WEAPON_KINDS.size()

## The model for weapon slot `idx`, or null.
static func for_weapon(idx: int, w: float, h: float) -> Node3D:
	if idx < 0 or idx >= WEAPON_KINDS.size():
		return null
	return build_kind(String(WEAPON_KINDS[idx]), w, h)

## A weapon `w` long and `h` tall (world units), centred on the origin
## and lying along +X, like the sprite it stands in for.
static func build(sprite_index: int, w: float, h: float) -> Node3D:
	return for_weapon(weapon_of(sprite_index), w, h)

static func build_kind(kind: String, w: float, h_in: float) -> Node3D:
	if kind.is_empty():
		return null
	var h: float = maxf(h_in, w * MIN_ASPECT)
	var root := Node3D.new()
	root.name = "WeaponModel"
	match kind:
		"pipe":     _pipe(root, w, h)
		"uzi":      _uzi(root, w, h)
		"rifle":    _rifle(root, w, h)
		"shotgun":  _shotgun(root, w, h)
		"laser":    _laser(root, w, h)
		"plasma":   _plasma(root, w, h)
		"launcher": _launcher(root, w, h)
		_: return null
	return root

# --- the guns ----------------------------------------------------------

## A length of scaffolding pipe with a taped grip and threaded collars.
static func _pipe(r: Node3D, w: float, h: float) -> void:
	var rad: float = h * 0.30
	_tube(r, rad, rad, w * 0.94, "steel", Vector3.ZERO)
	_tube(r, rad * 1.22, rad * 1.22, w * 0.05, "steel", Vector3(w * 0.44, 0.0, 0.0))
	_tube(r, rad * 1.22, rad * 1.22, w * 0.05, "steel", Vector3(-w * 0.44, 0.0, 0.0))
	# Grip tape: a slightly fatter rubber sleeve at the swinging end.
	_tube(r, rad * 1.12, rad * 1.12, w * 0.24, "rubber", Vector3(-w * 0.28, 0.0, 0.0))
	_ring(r, rad * 1.18, rad * 0.10, "blued", Vector3(-w * 0.15, 0.0, 0.0))

## Compact SMG: stamped receiver, the magazine through the grip, a
## folding wire stock.
static func _uzi(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.18                     # bore line
	_box(r, Vector3(w * 0.40, h * 0.40, h * 0.34), "blued", Vector3(-w * 0.04, top, 0.0))
	# Ribbed top cover + cocking knob.
	_box(r, Vector3(w * 0.34, h * 0.06, h * 0.20), "gunmetal", Vector3(-w * 0.04, top + h * 0.21, 0.0))
	_box(r, Vector3(h * 0.10, h * 0.10, h * 0.10), "steel", Vector3(-w * 0.02, top + h * 0.24, 0.0))
	# Barrel, nut and shroud.
	_tube(r, h * 0.075, h * 0.075, w * 0.34, "steel", Vector3(w * 0.32, top + h * 0.02, 0.0))
	_ring(r, h * 0.13, h * 0.035, "gunmetal", Vector3(w * 0.17, top + h * 0.02, 0.0))
	_ring(r, h * 0.11, h * 0.030, "gunmetal", Vector3(w * 0.47, top + h * 0.02, 0.0))
	# Magazine through the pistol grip, tapering to the floor plate.
	_taper(r, Vector3(h * 0.22, h * 0.56, h * 0.26), Vector3(h * 0.19, h * 0.56, h * 0.24),
		"blued", Vector3(-w * 0.03, -h * 0.20, 0.0))
	_box(r, Vector3(h * 0.26, h * 0.05, h * 0.28), "polymer", Vector3(-w * 0.03, -h * 0.48, 0.0))
	_box(r, Vector3(h * 0.20, h * 0.34, h * 0.22), "rubber", Vector3(-w * 0.03, -h * 0.04, 0.0))
	# Trigger inside its guard.
	_guard(r, w, h, -w * 0.12, top - h * 0.20)
	# Folding wire stock, two struts and a shoulder bar.
	for sz in [-1.0, 1.0]:
		_box(r, Vector3(w * 0.30, h * 0.05, h * 0.05), "steel",
			Vector3(-w * 0.34, top - h * 0.02, sz * h * 0.13))
	_box(r, Vector3(h * 0.06, h * 0.06, h * 0.30), "steel", Vector3(-w * 0.48, top - h * 0.02, 0.0))
	_sights(r, w, h, top, w * 0.14, -w * 0.16)

## Assault rifle / machine gun: two-piece receiver, vented handguard, a
## curved magazine and a flash hider.
static func _rifle(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.16
	_box(r, Vector3(w * 0.34, h * 0.34, h * 0.28), "blued", Vector3(-w * 0.06, top, 0.0))
	_box(r, Vector3(w * 0.30, h * 0.20, h * 0.24), "gunmetal", Vector3(-w * 0.05, top + h * 0.24, 0.0))
	# Ejection port and charging handle.
	_box(r, Vector3(w * 0.09, h * 0.12, h * 0.02), "polymer",
		Vector3(w * 0.04, top + h * 0.08, h * 0.145))
	_box(r, Vector3(h * 0.08, h * 0.08, h * 0.08), "steel", Vector3(-w * 0.17, top + h * 0.28, 0.0))
	# Handguard: a ribbed tube with vent slots, then the barrel.
	_tube(r, h * 0.16, h * 0.16, w * 0.26, "polymer", Vector3(w * 0.22, top + h * 0.04, 0.0), 14)
	for i in 3:
		_box(r, Vector3(w * 0.05, h * 0.05, h * 0.34), "gunmetal",
			Vector3(w * 0.14 + float(i) * w * 0.08, top + h * 0.04, 0.0))
	_tube(r, h * 0.062, h * 0.062, w * 0.30, "steel", Vector3(w * 0.44, top + h * 0.04, 0.0))
	# Flash hider: a slightly wider slotted muzzle.
	_tube(r, h * 0.10, h * 0.085, w * 0.08, "blued", Vector3(w * 0.55, top + h * 0.04, 0.0))
	# Curved magazine — three boxes leaning progressively back.
	for i in 3:
		var t: float = float(i)
		_box(r, Vector3(h * 0.17, h * 0.22, h * 0.30), "polymer",
			Vector3(-w * 0.05 - t * h * 0.045, -h * 0.06 - t * h * 0.19, 0.0),
			Vector3(0.0, 0.0, deg_to_rad(6.0 + t * 5.0)))
	# Pistol grip, trigger, guard.
	_box(r, Vector3(h * 0.20, h * 0.42, h * 0.22), "polymer",
		Vector3(-w * 0.18, -h * 0.14, 0.0), Vector3(0.0, 0.0, deg_to_rad(14.0)))
	_guard(r, w, h, -w * 0.12, top - h * 0.18)
	# Stock: a tapered tube into a rubber butt pad.
	_taper(r, Vector3(w * 0.24, h * 0.30, h * 0.22), Vector3(w * 0.24, h * 0.36, h * 0.24),
		"polymer", Vector3(-w * 0.36, top - h * 0.02, 0.0))
	_box(r, Vector3(h * 0.05, h * 0.38, h * 0.26), "rubber", Vector3(-w * 0.485, top - h * 0.02, 0.0))
	_sights(r, w, h, top + h * 0.30, w * 0.30, -w * 0.16)
	# Sling loop.
	_ring(r, h * 0.09, h * 0.020, "steel", Vector3(-w * 0.30, top - h * 0.18, 0.0))

## Pump shotgun: barrel over magazine tube, wooden forend and stock.
static func _shotgun(r: Node3D, w: float, h: float) -> void:
	var bore: float = h * 0.20
	_tube(r, h * 0.13, h * 0.13, w * 0.62, "blued", Vector3(w * 0.20, bore, 0.0))
	_tube(r, h * 0.095, h * 0.095, w * 0.50, "blued", Vector3(w * 0.16, bore - h * 0.24, 0.0))
	# Barrel ring and the bead front sight.
	_ring(r, h * 0.17, h * 0.03, "gunmetal", Vector3(w * 0.34, bore - h * 0.12, 0.0))
	_sphere(r, h * 0.05, "brass", Vector3(w * 0.50, bore + h * 0.15, 0.0))
	# Grooved wooden forend riding the magazine tube.
	_box(r, Vector3(w * 0.20, h * 0.28, h * 0.26), "wood", Vector3(w * 0.06, bore - h * 0.22, 0.0))
	for i in 4:
		_box(r, Vector3(w * 0.012, h * 0.30, h * 0.28), "blued",
			Vector3(w * 0.00 + float(i) * w * 0.045, bore - h * 0.22, 0.0))
	# Receiver with its loading port and ejection port.
	_box(r, Vector3(w * 0.22, h * 0.34, h * 0.28), "blued", Vector3(-w * 0.13, bore - h * 0.10, 0.0))
	_box(r, Vector3(w * 0.10, h * 0.10, h * 0.02), "polymer",
		Vector3(-w * 0.11, bore - h * 0.06, h * 0.145))
	_guard(r, w, h, -w * 0.19, bore - h * 0.32)
	# Wooden stock with a rubber pad; the wrist drops behind the receiver.
	_taper(r, Vector3(w * 0.30, h * 0.34, h * 0.24), Vector3(w * 0.30, h * 0.46, h * 0.26),
		"wood", Vector3(-w * 0.36, bore - h * 0.20, 0.0), Vector3(0.0, 0.0, deg_to_rad(-5.0)))
	_box(r, Vector3(h * 0.05, h * 0.48, h * 0.28), "rubber", Vector3(-w * 0.50, bore - h * 0.24, 0.0))

## Laser rifle: slim shell, ribbed emitter, a scope and a lit power cell.
static func _laser(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.14
	_box(r, Vector3(w * 0.42, h * 0.32, h * 0.26), "gunmetal", Vector3(-w * 0.06, top, 0.0))
	_taper(r, Vector3(w * 0.16, h * 0.32, h * 0.26), Vector3(w * 0.16, h * 0.22, h * 0.18),
		"gunmetal", Vector3(w * 0.23, top, 0.0))
	# Emitter tube with cooling ribs and a lit lens.
	_tube(r, h * 0.085, h * 0.085, w * 0.34, "steel", Vector3(w * 0.42, top, 0.0))
	for i in 4:
		_ring(r, h * 0.14, h * 0.028, "steel", Vector3(w * 0.30 + float(i) * w * 0.075, top, 0.0))
	_lens(r, h * 0.095, GLOW_RED, Vector3(w * 0.58, top, 0.0))
	# Power cell: a lit window let into the receiver's flank.
	for sz in [-1.0, 1.0]:
		_box(r, Vector3(w * 0.16, h * 0.10, h * 0.02), "glow",
			Vector3(-w * 0.10, top + h * 0.05, sz * h * 0.135), Vector3.ZERO, GLOW_RED)
	_box(r, Vector3(w * 0.12, h * 0.14, h * 0.20), "polymer", Vector3(-w * 0.16, top + h * 0.05, 0.0))
	# Scope on a pair of rings, glass at the rear.
	_tube(r, h * 0.10, h * 0.10, w * 0.26, "blued", Vector3(-w * 0.02, top + h * 0.30, 0.0))
	_ring(r, h * 0.13, h * 0.03, "steel", Vector3(-w * 0.10, top + h * 0.30, 0.0))
	_ring(r, h * 0.13, h * 0.03, "steel", Vector3(w * 0.06, top + h * 0.30, 0.0))
	_lens(r, h * 0.085, GLOW_BLUE, Vector3(-w * 0.155, top + h * 0.30, 0.0), 1.1)
	# Grip, trigger, stock.
	_box(r, Vector3(h * 0.20, h * 0.40, h * 0.22), "polymer",
		Vector3(-w * 0.16, -h * 0.16, 0.0), Vector3(0.0, 0.0, deg_to_rad(12.0)))
	_guard(r, w, h, -w * 0.10, top - h * 0.17)
	_taper(r, Vector3(w * 0.22, h * 0.28, h * 0.20), Vector3(w * 0.22, h * 0.34, h * 0.22),
		"gunmetal", Vector3(-w * 0.36, top - h * 0.02, 0.0))
	_box(r, Vector3(h * 0.05, h * 0.36, h * 0.24), "rubber", Vector3(-w * 0.47, top - h * 0.02, 0.0))

## Plasma weapon: a caged glowing chamber, coil rings, a flared muzzle.
static func _plasma(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.14
	_box(r, Vector3(w * 0.34, h * 0.44, h * 0.34), "gunmetal", Vector3(-w * 0.12, top, 0.0))
	# The chamber: a lit sphere inside three thin retaining rings.
	_sphere(r, h * 0.19, "glow", Vector3(w * 0.06, top, 0.0), GLOW_BLUE)
	for i in 3:
		_ring(r, h * 0.22, h * 0.022, "steel",
			Vector3(w * 0.06 + (float(i) - 1.0) * h * 0.14, top, 0.0))
	# Accelerator: coil rings stepping down the barrel to a flared muzzle.
	_tube(r, h * 0.11, h * 0.11, w * 0.34, "gunmetal", Vector3(w * 0.34, top, 0.0))
	for i in 4:
		_ring(r, h * 0.17 - float(i) * h * 0.012, h * 0.030, "brass",
			Vector3(w * 0.24 + float(i) * w * 0.075, top, 0.0))
	_taper(r, Vector3(w * 0.10, h * 0.24, h * 0.24), Vector3(w * 0.10, h * 0.34, h * 0.34),
		"steel", Vector3(w * 0.53, top, 0.0))
	_lens(r, h * 0.13, GLOW_BLUE, Vector3(w * 0.575, top, 0.0))
	# Cooling fins over the receiver.
	for i in 3:
		_box(r, Vector3(w * 0.03, h * 0.14, h * 0.30), "steel",
			Vector3(-w * 0.20 + float(i) * w * 0.07, top + h * 0.28, 0.0))
	# Grip, trigger, shoulder brace.
	_box(r, Vector3(h * 0.22, h * 0.42, h * 0.24), "polymer",
		Vector3(-w * 0.20, -h * 0.16, 0.0), Vector3(0.0, 0.0, deg_to_rad(12.0)))
	_guard(r, w, h, -w * 0.14, top - h * 0.23)
	_taper(r, Vector3(w * 0.20, h * 0.30, h * 0.22), Vector3(w * 0.20, h * 0.40, h * 0.26),
		"gunmetal", Vector3(-w * 0.38, top - h * 0.02, 0.0))
	_box(r, Vector3(h * 0.05, h * 0.42, h * 0.28), "rubber", Vector3(-w * 0.485, top - h * 0.02, 0.0))

## Shoulder-fired tube: rocket / grenade launcher.
static func _launcher(r: Node3D, w: float, h: float) -> void:
	var axis: float = h * 0.12
	_tube(r, h * 0.24, h * 0.24, w * 0.80, "olive", Vector3(0.0, axis, 0.0), 18)
	# Muzzle flare and rear venturi.
	_taper(r, Vector3(w * 0.10, h * 0.52, h * 0.52), Vector3(w * 0.10, h * 0.64, h * 0.64),
		"olive", Vector3(w * 0.44, axis, 0.0))
	_taper(r, Vector3(w * 0.10, h * 0.56, h * 0.56), Vector3(w * 0.10, h * 0.44, h * 0.44),
		"blued", Vector3(-w * 0.44, axis, 0.0))
	# Reinforcing bands along the tube.
	for i in 3:
		_ring(r, h * 0.27, h * 0.035, "blued",
			Vector3(-w * 0.24 + float(i) * w * 0.24, axis, 0.0))
	# Optic block with a lit reticle, on a raised rail.
	_box(r, Vector3(w * 0.22, h * 0.10, h * 0.22), "blued", Vector3(-w * 0.04, axis + h * 0.28, 0.0))
	_box(r, Vector3(w * 0.16, h * 0.20, h * 0.20), "gunmetal", Vector3(-w * 0.04, axis + h * 0.42, 0.0))
	_lens(r, h * 0.07, GLOW_GREEN, Vector3(-w * 0.125, axis + h * 0.42, 0.0), 1.1)
	# Pistol grip with the trigger, and a forward grip to steady it.
	_box(r, Vector3(h * 0.22, h * 0.44, h * 0.24), "polymer",
		Vector3(-w * 0.16, -h * 0.28, 0.0), Vector3(0.0, 0.0, deg_to_rad(12.0)))
	_guard(r, w, h, -w * 0.10, -h * 0.06)
	_box(r, Vector3(h * 0.18, h * 0.34, h * 0.20), "polymer",
		Vector3(w * 0.20, -h * 0.24, 0.0), Vector3(0.0, 0.0, deg_to_rad(-10.0)))
	# Shoulder pad under the rear of the tube.
	_box(r, Vector3(w * 0.16, h * 0.10, h * 0.34), "rubber", Vector3(-w * 0.30, axis - h * 0.28, 0.0))

# --- shared sub-assemblies --------------------------------------------

## A trigger blade inside a torus guard, centred at (x, y).
static func _guard(r: Node3D, _w: float, h: float, x: float, y: float) -> void:
	var mi: MeshInstance3D = _ring(r, h * 0.15, h * 0.028, "gunmetal", Vector3(x, y, 0.0))
	mi.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)     # guard lies in XY
	_box(r, Vector3(h * 0.035, h * 0.16, h * 0.06), "steel", Vector3(x + h * 0.03, y + h * 0.07, 0.0),
		Vector3(0.0, 0.0, deg_to_rad(-10.0)))

## A front post and a rear notch on the top line.
static func _sights(r: Node3D, _w: float, h: float, y: float, front_x: float, rear_x: float) -> void:
	_box(r, Vector3(h * 0.04, h * 0.16, h * 0.05), "blued", Vector3(front_x, y + h * 0.24, 0.0))
	_box(r, Vector3(h * 0.06, h * 0.05, h * 0.16), "blued", Vector3(front_x, y + h * 0.30, 0.0))
	_box(r, Vector3(h * 0.06, h * 0.12, h * 0.16), "blued", Vector3(rear_x, y + h * 0.22, 0.0))

## A lit lens facing +X (a muzzle, an optic).
static func _lens(r: Node3D, radius: float, col: Color, at: Vector3, aspect: float = 0.4) -> void:
	_tube(r, radius, radius, radius * aspect, "glow", at, 14, col)

# --- primitives, all built lying along +X -------------------------------

static func _mat(kind: String, tint: Color = Color(0, 0, 0, 0)) -> StandardMaterial3D:
	var spec: Array = MATERIALS.get(kind, MATERIALS["gunmetal"])
	var m := StandardMaterial3D.new()
	m.albedo_color = tint if tint.a > 0.0 else Color(spec[0])
	m.metallic = float(spec[1])
	m.roughness = float(spec[2])
	m.metallic_specular = 0.5
	# The same wear the crates and medkits carry, mapped triplanar so the
	# boxes and cylinders need no UVs of their own.
	m.albedo_texture = PickupModels.grunge()
	m.normal_enabled = true
	m.normal_texture = PickupModels.grunge_normal()
	m.normal_scale = 0.55
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.05, 0.05, 0.05)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if float(spec[3]) > 0.0:
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = float(spec[3])
		m.albedo_texture = null
		m.normal_enabled = false
	return m

static func _add(r: Node3D, mesh: Mesh, at: Vector3, rot: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.rotation = rot
	r.add_child(mi)
	return mi

static func _box(r: Node3D, size: Vector3, kind: String, at: Vector3,
		rot: Vector3 = Vector3.ZERO, tint: Color = Color(0, 0, 0, 0)) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat(kind, tint)
	return _add(r, bm, at, rot)

## A box whose far (+X) face is a different size — stocks, muzzle
## flares, venturis. Built from a four-sided cylinder rolled 45 degrees
## about its own axis so the four flat faces come out axis-aligned; a
## square section's circumradius is side/sqrt(2), hence SQUARE_R.
const SQUARE_R: float = 0.70710678
static func _taper(r: Node3D, near: Vector3, far: Vector3, kind: String, at: Vector3,
		rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var pivot := Node3D.new()
	pivot.position = at
	pivot.rotation = rot
	r.add_child(pivot)
	var cm := CylinderMesh.new()
	cm.bottom_radius = (near.y + near.z) * 0.5 * SQUARE_R
	cm.top_radius = (far.y + far.z) * 0.5 * SQUARE_R
	cm.height = near.x
	cm.radial_segments = 4
	cm.rings = 1
	cm.material = _mat(kind)
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.rotation = Vector3(0.0, 0.0, deg_to_rad(-90.0))   # axis along +X
	pivot.add_child(mi)
	mi.rotate_object_local(Vector3.UP, deg_to_rad(45.0)) # faces axis-aligned
	return mi

## A cylinder lying along +X.
static func _tube(r: Node3D, r0: float, r1: float, length: float, kind: String,
		at: Vector3, segments: int = 16, tint: Color = Color(0, 0, 0, 0)) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r0
	cm.top_radius = r1
	cm.height = length
	cm.radial_segments = segments
	cm.rings = 1
	cm.material = _mat(kind, tint)
	return _add(r, cm, at, Vector3(0.0, 0.0, deg_to_rad(-90.0)))

## A ring around the barrel (a band, a coil, a scope mount).
static func _ring(r: Node3D, radius: float, thickness: float, kind: String,
		at: Vector3) -> MeshInstance3D:
	var tm := TorusMesh.new()
	tm.inner_radius = maxf(radius - thickness, 0.001)
	tm.outer_radius = radius + thickness
	tm.rings = 18
	tm.ring_segments = 8
	tm.material = _mat(kind)
	return _add(r, tm, at, Vector3(0.0, 0.0, deg_to_rad(90.0)))

static func _sphere(r: Node3D, radius: float, kind: String, at: Vector3,
		tint: Color = Color(0, 0, 0, 0)) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 16
	sm.rings = 8
	sm.material = _mat(kind, tint)
	return _add(r, sm, at, Vector3.ZERO)
