## ENHANCED weapon models: the guns lying on the ground as small 3D
## objects instead of flat billboards, and the 3D weapon in the player's
## hands (DETAIL → WEAPON VIEW).
##
## The DOS pickup sprites are side views (barrel to the right), so every
## model here is built lying along +X, centred on the origin, and sized
## to the sprite it replaces — `w` is the whole length, `h` the whole
## height INCLUDING the magazine and the grip, because that is what the
## sprite's bounding box covers.
##
## Third pass 2026-09-04 ("more detailed and prettier"): the plain boxes
## are gone. Every rectangular part is a CHAMFERED box built here as an
## ArrayMesh — the cut edges catch a highlight, which is most of what
## separates a model from a crate. On top of that the guns carry the
## small parts that make a gun read as one: a rail with fins, receiver
## pins, a selector, a knurled charging handle, sling swivels, witness
## holes down the magazine, a slotted flash hider, a scope with glass at
## both ends. Polymer and rubber take a stippled normal map, so grips
## look moulded rather than painted.

extends RefCounted

const PickupModels := preload("res://scripts/pickup_models.gd")
const PickupData := preload("res://scripts/pickup_data.gd")

# --- materials ---------------------------------------------------------
## kind → [albedo, metallic, roughness, emission energy, clearcoat]
const MATERIALS: Dictionary = {
	"gunmetal": [Color(0.115, 0.120, 0.135), 0.62, 0.58, 0.0, 0.0],
	"steel":    [Color(0.28, 0.29, 0.32), 0.70, 0.44, 0.0, 0.04],
	"blued":    [Color(0.062, 0.068, 0.082), 0.66, 0.50, 0.0, 0.06],
	"polymer":  [Color(0.085, 0.085, 0.095), 0.00, 0.74, 0.0, 0.0],
	"rubber":   [Color(0.045, 0.045, 0.050), 0.00, 0.95, 0.0, 0.0],
	"wood":     [Color(0.26, 0.135, 0.062), 0.00, 0.55, 0.0, 0.0],
	"brass":    [Color(0.48, 0.35, 0.13), 0.80, 0.34, 0.0, 0.08],
	"olive":    [Color(0.165, 0.180, 0.105), 0.12, 0.70, 0.0, 0.05],
	"glass":    [Color(0.04, 0.06, 0.09), 0.55, 0.08, 0.0, 0.40],
	"glow":     [Color(1.0, 1.0, 1.0), 0.0, 0.4, 2.8, 0.0],
}
## Kinds that are moulded, not machined — they get the stipple normal.
const GRIPPY: Array = ["polymer", "rubber"]

const GLOW_RED := Color(0.95, 0.16, 0.10)
const GLOW_BLUE := Color(0.30, 0.70, 1.0)
const GLOW_GREEN := Color(0.35, 1.0, 0.45)

## Guns are longer than they are tall; the DOS art for some of them is
## only 10-13 px high, which squeezes the grip and the stock into
## nothing. Never build one flatter than this fraction of its length.
const MIN_ASPECT: float = 0.24
## Chamfer as a fraction of a part's smallest side. Keep it SMALL: a
## wide chamfer turns into a band that catches the key and rim light at
## a grazing angle, and a near-black polymer part then reads as a pale
## grey slab with a dark panel in the middle (2026-09-04).
const BEVEL: float = 0.07

## The model for each weapon slot of fly_camera._weapons.
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

## Which sprite gets which gun is not a table here — the DOS item table
## already says it. pickup_data.ITEMS[sprite][4] is the weapon slot the
## pickup grants, so the model follows from WEAPON_KINDS and can never
## drift out of step with what the player actually picks up.
static func weapon_of(sprite_index: int) -> int:
	var item: Array = PickupData.ITEMS.get(sprite_index, [])
	return int(item[4]) if item.size() > 4 else -1

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

## A length of scaffolding pipe: threaded collars, a wound grip, a nut.
static func _pipe(r: Node3D, w: float, h: float) -> void:
	var rad: float = h * 0.26
	_tube(r, rad, rad, w * 0.94, "steel", Vector3.ZERO, 20)
	for sx in [-1.0, 1.0]:
		_tube(r, rad * 1.24, rad * 1.24, w * 0.045, "steel", Vector3(sx * w * 0.44, 0.0, 0.0), 20)
		_ring(r, rad * 1.26, rad * 0.09, "blued", Vector3(sx * w * 0.40, 0.0, 0.0))
	# Grip tape, wound in overlapping turns.
	_tube(r, rad * 1.10, rad * 1.10, w * 0.24, "rubber", Vector3(-w * 0.28, 0.0, 0.0), 18)
	for i in 5:
		_ring(r, rad * 1.13, rad * 0.05, "rubber",
			Vector3(-w * 0.375 + float(i) * w * 0.048, 0.0, 0.0))
	# A hex nut welded on.
	_tube(r, rad * 1.35, rad * 1.35, w * 0.035, "brass", Vector3(w * 0.10, 0.0, 0.0), 6)

## Compact SMG: stamped receiver, the magazine through the grip, a
## folding wire stock, ejection port and selector.
static func _uzi(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.18                     # bore line
	_part(r, Vector3(w * 0.40, h * 0.40, h * 0.34), "blued", Vector3(-w * 0.04, top, 0.0))
	# Ribbed top cover with a knurled cocking knob riding in its slot.
	_part(r, Vector3(w * 0.34, h * 0.07, h * 0.20), "gunmetal",
		Vector3(-w * 0.04, top + h * 0.21, 0.0))
	for i in 6:
		_part(r, Vector3(w * 0.012, h * 0.035, h * 0.21), "blued",
			Vector3(-w * 0.16 + float(i) * w * 0.045, top + h * 0.245, 0.0))
	_knurl(r, h * 0.07, h * 0.12, "steel", Vector3(-w * 0.02, top + h * 0.26, 0.0))
	# Barrel, nut and a muzzle collar.
	_tube(r, h * 0.070, h * 0.070, w * 0.34, "steel", Vector3(w * 0.32, top + h * 0.02, 0.0))
	_ring(r, h * 0.125, h * 0.032, "gunmetal", Vector3(w * 0.17, top + h * 0.02, 0.0))
	_tube(r, h * 0.10, h * 0.085, w * 0.05, "blued", Vector3(w * 0.47, top + h * 0.02, 0.0), 14)
	# Ejection port and selector switch on the flank.
	_part(r, Vector3(w * 0.10, h * 0.13, h * 0.02), "polymer",
		Vector3(w * 0.02, top + h * 0.10, h * 0.175))
	_pin(r, h * 0.05, h * 0.04, "steel", Vector3(-w * 0.14, top - h * 0.05, h * 0.18))
	_part(r, Vector3(h * 0.11, h * 0.035, h * 0.03), "steel",
		Vector3(-w * 0.115, top - h * 0.05, h * 0.20))
	# Magazine through the pistol grip, tapering to a floor plate, with
	# witness holes down its side.
	_taper(r, Vector3(h * 0.22, h * 0.56, h * 0.26), Vector3(h * 0.19, h * 0.56, h * 0.24),
		"blued", Vector3(-w * 0.03, -h * 0.20, 0.0))
	_part(r, Vector3(h * 0.27, h * 0.055, h * 0.29), "polymer", Vector3(-w * 0.03, -h * 0.48, 0.0))
	for i in 3:
		_part(r, Vector3(h * 0.05, h * 0.05, h * 0.02), "polymer",
			Vector3(-w * 0.03, -h * 0.10 - float(i) * h * 0.12, h * 0.13))
	_grip(r, h * 0.20, h * 0.34, h * 0.22, Vector3(-w * 0.03, -h * 0.04, 0.0), 0.0)
	_guard(r, h, -w * 0.12, top - h * 0.20)
	# Folding wire stock: two struts and a shoulder bar.
	for sz in [-1.0, 1.0]:
		_tube(r, h * 0.028, h * 0.028, w * 0.30, "steel",
			Vector3(-w * 0.34, top - h * 0.02, sz * h * 0.13), 8)
	_tube(r, h * 0.030, h * 0.030, h * 0.30, "steel",
		Vector3(-w * 0.48, top - h * 0.02, 0.0), 8, Color(0, 0, 0, 0), Vector3(PI * 0.5, 0.0, 0.0))
	_sights(r, h, top + h * 0.24, w * 0.14, -w * 0.16)
	_swivel(r, h, Vector3(-w * 0.30, top - h * 0.19, 0.0))

## Assault rifle / machine gun: two-piece receiver on a rail, vented
## handguard, curved magazine, slotted flash hider.
static func _rifle(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.16
	_part(r, Vector3(w * 0.34, h * 0.34, h * 0.28), "blued", Vector3(-w * 0.06, top, 0.0))
	_part(r, Vector3(w * 0.30, h * 0.20, h * 0.24), "gunmetal",
		Vector3(-w * 0.05, top + h * 0.24, 0.0))
	_rail(r, h, w * 0.28, Vector3(-w * 0.05, top + h * 0.35, 0.0), 7)
	# Ejection port, charging handle, magazine release, receiver pins.
	_part(r, Vector3(w * 0.10, h * 0.13, h * 0.02), "polymer",
		Vector3(w * 0.04, top + h * 0.08, h * 0.145))
	_knurl(r, h * 0.055, h * 0.10, "steel", Vector3(-w * 0.17, top + h * 0.28, 0.0))
	_pin(r, h * 0.045, h * 0.03, "steel", Vector3(-w * 0.02, top - h * 0.06, h * 0.15))
	for x in [-w * 0.17, w * 0.06]:
		_tube(r, h * 0.035, h * 0.035, h * 0.30, "steel",
			Vector3(x, top - h * 0.10, 0.0), 10, Color(0, 0, 0, 0), Vector3(PI * 0.5, 0.0, 0.0))
	# Handguard: a ribbed tube with cooling slots let into it.
	_tube(r, h * 0.155, h * 0.155, w * 0.26, "polymer", Vector3(w * 0.22, top + h * 0.04, 0.0), 16)
	for i in 4:
		_ring(r, h * 0.165, h * 0.018, "polymer",
			Vector3(w * 0.12 + float(i) * w * 0.066, top + h * 0.04, 0.0))
	for sz in [-1.0, 1.0]:
		for i in 3:
			_part(r, Vector3(w * 0.045, h * 0.05, h * 0.02), "blued",
				Vector3(w * 0.15 + float(i) * w * 0.07, top + h * 0.04, sz * h * 0.15))
	# Barrel and a slotted flash hider.
	_tube(r, h * 0.058, h * 0.058, w * 0.30, "steel", Vector3(w * 0.44, top + h * 0.04, 0.0))
	_tube(r, h * 0.095, h * 0.082, w * 0.09, "blued", Vector3(w * 0.55, top + h * 0.04, 0.0), 14)
	for i in 3:
		var a: float = float(i) * TAU / 3.0
		_part(r, Vector3(w * 0.055, h * 0.035, h * 0.10), "gunmetal",
			Vector3(w * 0.555, top + h * 0.04 + sin(a) * h * 0.075, cos(a) * h * 0.075),
			Vector3(a, 0.0, 0.0))
	# Curved magazine — boxes leaning progressively back, then a floor plate.
	for i in 3:
		var t: float = float(i)
		_part(r, Vector3(h * 0.17, h * 0.23, h * 0.30), "polymer",
			Vector3(-w * 0.05 - t * h * 0.045, -h * 0.06 - t * h * 0.19, 0.0),
			Vector3(0.0, 0.0, deg_to_rad(6.0 + t * 5.0)))
	_part(r, Vector3(h * 0.20, h * 0.05, h * 0.33), "polymer",
		Vector3(-w * 0.05 - h * 0.135, -h * 0.62, 0.0), Vector3(0.0, 0.0, deg_to_rad(16.0)))
	# Grip, trigger, stock with a cheek riser and a rubber butt pad.
	_grip(r, h * 0.20, h * 0.42, h * 0.22, Vector3(-w * 0.18, -h * 0.14, 0.0), 14.0)
	_guard(r, h, -w * 0.12, top - h * 0.18)
	# Skeleton stock: a comb over an open frame, not a solid block.
	_taper(r, Vector3(w * 0.24, h * 0.15, h * 0.20), Vector3(w * 0.24, h * 0.17, h * 0.22),
		"polymer", Vector3(-w * 0.36, top + h * 0.11, 0.0))
	_taper(r, Vector3(w * 0.20, h * 0.11, h * 0.18), Vector3(w * 0.20, h * 0.13, h * 0.20),
		"polymer", Vector3(-w * 0.38, top - h * 0.17, 0.0), Vector3(0.0, 0.0, deg_to_rad(-7.0)))
	_part(r, Vector3(w * 0.05, h * 0.30, h * 0.16), "polymer",
		Vector3(-w * 0.27, top - h * 0.04, 0.0), Vector3(0.0, 0.0, deg_to_rad(12.0)))
	_part(r, Vector3(h * 0.06, h * 0.40, h * 0.27), "rubber",
		Vector3(-w * 0.485, top - h * 0.02, 0.0))
	_sights(r, h, top + h * 0.34, w * 0.30, -w * 0.16)
	_swivel(r, h, Vector3(-w * 0.30, top - h * 0.19, 0.0))
	_swivel(r, h, Vector3(w * 0.34, top - h * 0.10, 0.0))

## Pump shotgun: barrel over magazine tube, wooden forend and stock.
static func _shotgun(r: Node3D, w: float, h: float) -> void:
	var bore: float = h * 0.22
	_tube(r, h * 0.125, h * 0.125, w * 0.62, "blued", Vector3(w * 0.20, bore, 0.0), 18)
	_tube(r, h * 0.090, h * 0.090, w * 0.50, "blued", Vector3(w * 0.16, bore - h * 0.23, 0.0), 16)
	# Barrel ring, magazine cap and a brass bead front sight.
	_ring(r, h * 0.17, h * 0.028, "gunmetal", Vector3(w * 0.34, bore - h * 0.11, 0.0))
	_tube(r, h * 0.105, h * 0.095, w * 0.03, "gunmetal", Vector3(w * 0.42, bore - h * 0.23, 0.0), 14)
	_sphere(r, h * 0.045, "brass", Vector3(w * 0.49, bore + h * 0.14, 0.0))
	# Grooved wooden forend riding the magazine tube.
	_part(r, Vector3(w * 0.20, h * 0.27, h * 0.25), "wood", Vector3(w * 0.06, bore - h * 0.21, 0.0))
	for i in 5:
		_part(r, Vector3(w * 0.013, h * 0.29, h * 0.27), "blued",
			Vector3(float(i) * w * 0.040, bore - h * 0.21, 0.0))
	# Receiver with a loading port, ejection port and a safety button.
	_part(r, Vector3(w * 0.22, h * 0.34, h * 0.27), "blued", Vector3(-w * 0.13, bore - h * 0.09, 0.0))
	_part(r, Vector3(w * 0.11, h * 0.11, h * 0.02), "polymer",
		Vector3(-w * 0.11, bore - h * 0.05, h * 0.14))
	_tube(r, h * 0.038, h * 0.038, h * 0.30, "brass",
		Vector3(-w * 0.20, bore - h * 0.22, 0.0), 10, Color(0, 0, 0, 0), Vector3(PI * 0.5, 0.0, 0.0))
	_guard(r, h, -w * 0.19, bore - h * 0.30)
	# Wooden stock with a rubber pad and sling swivels.
	_taper(r, Vector3(w * 0.30, h * 0.32, h * 0.23), Vector3(w * 0.30, h * 0.46, h * 0.25),
		"wood", Vector3(-w * 0.36, bore - h * 0.19, 0.0), Vector3(0.0, 0.0, deg_to_rad(-5.0)))
	_part(r, Vector3(h * 0.06, h * 0.48, h * 0.28), "rubber", Vector3(-w * 0.50, bore - h * 0.23, 0.0))
	_swivel(r, h, Vector3(-w * 0.44, bore - h * 0.40, 0.0))
	_swivel(r, h, Vector3(w * 0.24, bore - h * 0.34, 0.0))

## Laser rifle: slim shell, ribbed emitter, a scope and a lit cell.
static func _laser(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.14
	_part(r, Vector3(w * 0.42, h * 0.32, h * 0.26), "gunmetal", Vector3(-w * 0.06, top, 0.0))
	_taper(r, Vector3(w * 0.16, h * 0.32, h * 0.26), Vector3(w * 0.16, h * 0.22, h * 0.18),
		"gunmetal", Vector3(w * 0.23, top, 0.0))
	# Emitter tube with cooling ribs stepping down to a lit lens.
	_tube(r, h * 0.080, h * 0.080, w * 0.34, "steel", Vector3(w * 0.42, top, 0.0), 18)
	for i in 5:
		_ring(r, h * 0.135 - float(i) * h * 0.006, h * 0.024, "steel",
			Vector3(w * 0.30 + float(i) * w * 0.060, top, 0.0))
	_lens(r, h * 0.090, GLOW_RED, Vector3(w * 0.585, top, 0.0))
	# Power cell: a lit window let into each flank, behind a cage.
	for sz in [-1.0, 1.0]:
		_part(r, Vector3(w * 0.16, h * 0.10, h * 0.015), "glow",
			Vector3(-w * 0.10, top + h * 0.05, sz * h * 0.134), Vector3.ZERO, GLOW_RED)
		for i in 3:
			_part(r, Vector3(w * 0.012, h * 0.11, h * 0.02), "gunmetal",
				Vector3(-w * 0.145 + float(i) * w * 0.045, top + h * 0.05, sz * h * 0.140))
	_part(r, Vector3(w * 0.12, h * 0.15, h * 0.20), "polymer", Vector3(-w * 0.17, top + h * 0.06, 0.0))
	# Scope on two rings, glass at both ends, mounted on a rail.
	_rail(r, h, w * 0.20, Vector3(-w * 0.02, top + h * 0.19, 0.0), 5)
	_tube(r, h * 0.095, h * 0.095, w * 0.26, "blued", Vector3(-w * 0.02, top + h * 0.31, 0.0), 18)
	for x in [-w * 0.10, w * 0.06]:
		_ring(r, h * 0.125, h * 0.028, "steel", Vector3(x, top + h * 0.31, 0.0))
	_tube(r, h * 0.115, h * 0.100, w * 0.04, "blued", Vector3(w * 0.12, top + h * 0.31, 0.0), 16)
	_lens(r, h * 0.085, GLOW_BLUE, Vector3(-w * 0.157, top + h * 0.31, 0.0), 1.1)
	_lens(r, h * 0.090, GLOW_BLUE, Vector3(w * 0.142, top + h * 0.31, 0.0), 0.6)
	# Grip, trigger, stock.
	_grip(r, h * 0.20, h * 0.40, h * 0.22, Vector3(-w * 0.16, -h * 0.16, 0.0), 12.0)
	_guard(r, h, -w * 0.10, top - h * 0.17)
	_taper(r, Vector3(w * 0.22, h * 0.28, h * 0.20), Vector3(w * 0.22, h * 0.34, h * 0.22),
		"gunmetal", Vector3(-w * 0.36, top - h * 0.02, 0.0))
	_part(r, Vector3(h * 0.06, h * 0.38, h * 0.25), "rubber", Vector3(-w * 0.47, top - h * 0.02, 0.0))
	_swivel(r, h, Vector3(-w * 0.28, top - h * 0.18, 0.0))

## Plasma weapon: a caged glowing chamber, coil rings, a flared muzzle.
static func _plasma(r: Node3D, w: float, h: float) -> void:
	var top: float = h * 0.14
	_part(r, Vector3(w * 0.34, h * 0.44, h * 0.34), "gunmetal", Vector3(-w * 0.12, top, 0.0))
	# The chamber: a lit sphere inside retaining rings and four struts.
	_sphere(r, h * 0.185, "glow", Vector3(w * 0.06, top, 0.0), GLOW_BLUE)
	for i in 3:
		_ring(r, h * 0.215, h * 0.020, "steel",
			Vector3(w * 0.06 + (float(i) - 1.0) * h * 0.14, top, 0.0))
	for i in 4:
		var a: float = float(i) * TAU / 4.0 + PI * 0.25
		_part(r, Vector3(h * 0.30, h * 0.03, h * 0.05), "steel",
			Vector3(w * 0.06, top + sin(a) * h * 0.215, cos(a) * h * 0.215),
			Vector3(a, 0.0, 0.0))
	# Accelerator: coil rings stepping down the barrel to a flared muzzle.
	_tube(r, h * 0.105, h * 0.105, w * 0.34, "gunmetal", Vector3(w * 0.34, top, 0.0), 18)
	for i in 5:
		_ring(r, h * 0.165 - float(i) * h * 0.009, h * 0.026, "brass",
			Vector3(w * 0.235 + float(i) * w * 0.062, top, 0.0))
	_taper(r, Vector3(w * 0.10, h * 0.24, h * 0.24), Vector3(w * 0.10, h * 0.36, h * 0.36),
		"steel", Vector3(w * 0.53, top, 0.0))
	_lens(r, h * 0.13, GLOW_BLUE, Vector3(w * 0.578, top, 0.0))
	# Cooling fins and a coolant line over the receiver.
	for i in 4:
		_part(r, Vector3(w * 0.025, h * 0.15, h * 0.30), "steel",
			Vector3(-w * 0.21 + float(i) * w * 0.06, top + h * 0.29, 0.0))
	_tube(r, h * 0.035, h * 0.035, w * 0.30, "rubber",
		Vector3(-w * 0.02, top + h * 0.26, h * 0.14), 10)
	# Grip, trigger, shoulder brace.
	_grip(r, h * 0.22, h * 0.42, h * 0.24, Vector3(-w * 0.20, -h * 0.16, 0.0), 12.0)
	_guard(r, h, -w * 0.14, top - h * 0.23)
	_taper(r, Vector3(w * 0.20, h * 0.30, h * 0.22), Vector3(w * 0.20, h * 0.40, h * 0.26),
		"gunmetal", Vector3(-w * 0.38, top - h * 0.02, 0.0))
	_part(r, Vector3(h * 0.06, h * 0.44, h * 0.29), "rubber",
		Vector3(-w * 0.485, top - h * 0.02, 0.0))

## Shoulder-fired tube: rocket / grenade launcher.
static func _launcher(r: Node3D, w: float, h: float) -> void:
	var axis: float = h * 0.12
	_tube(r, h * 0.235, h * 0.235, w * 0.80, "olive", Vector3(0.0, axis, 0.0), 22)
	# Muzzle flare, rear venturi and the dark bore.
	_taper(r, Vector3(w * 0.10, h * 0.50, h * 0.50), Vector3(w * 0.10, h * 0.64, h * 0.64),
		"olive", Vector3(w * 0.44, axis, 0.0))
	_taper(r, Vector3(w * 0.10, h * 0.54, h * 0.54), Vector3(w * 0.10, h * 0.42, h * 0.42),
		"blued", Vector3(-w * 0.44, axis, 0.0))
	_lens(r, h * 0.20, Color(0.04, 0.04, 0.05), Vector3(w * 0.481, axis, 0.0), 0.2)
	# Reinforcing bands and a firing cable along the tube.
	for i in 3:
		_ring(r, h * 0.265, h * 0.030, "blued",
			Vector3(-w * 0.24 + float(i) * w * 0.24, axis, 0.0))
	_tube(r, h * 0.030, h * 0.030, w * 0.44, "rubber",
		Vector3(-w * 0.10, axis - h * 0.20, h * 0.16), 10)
	# Optic block with a lit reticle, on a raised rail.
	_rail(r, h, w * 0.24, Vector3(-w * 0.04, axis + h * 0.27, 0.0), 6)
	_part(r, Vector3(w * 0.16, h * 0.22, h * 0.20), "gunmetal", Vector3(-w * 0.04, axis + h * 0.43, 0.0))
	_lens(r, h * 0.07, GLOW_GREEN, Vector3(-w * 0.125, axis + h * 0.43, 0.0), 1.1)
	_lens(r, h * 0.07, Color(0.06, 0.09, 0.12), Vector3(w * 0.045, axis + h * 0.43, 0.0), 1.1)
	# Pistol grip with the trigger, and a forward grip to steady it.
	_grip(r, h * 0.22, h * 0.44, h * 0.24, Vector3(-w * 0.16, -h * 0.28, 0.0), 12.0)
	_guard(r, h, -w * 0.10, -h * 0.06)
	_grip(r, h * 0.18, h * 0.34, h * 0.20, Vector3(w * 0.20, -h * 0.24, 0.0), -10.0)
	# Shoulder pad under the rear of the tube.
	_part(r, Vector3(w * 0.16, h * 0.10, h * 0.34), "rubber", Vector3(-w * 0.30, axis - h * 0.28, 0.0))
	_swivel(r, h, Vector3(-w * 0.34, axis - h * 0.26, 0.0))
	_swivel(r, h, Vector3(w * 0.30, axis - h * 0.26, 0.0))

# --- shared sub-assemblies --------------------------------------------

## A trigger blade inside a torus guard, centred at (x, y).
static func _guard(r: Node3D, h: float, x: float, y: float) -> void:
	var mi: MeshInstance3D = _ring(r, h * 0.145, h * 0.026, "gunmetal", Vector3(x, y, 0.0))
	mi.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)     # guard lies in XY
	_part(r, Vector3(h * 0.035, h * 0.155, h * 0.055), "steel",
		Vector3(x + h * 0.03, y + h * 0.07, 0.0), Vector3(0.0, 0.0, deg_to_rad(-10.0)))

## A moulded grip: the body, finger grooves and a butt cap.
static func _grip(r: Node3D, gw: float, gh: float, gd: float, at: Vector3, tilt: float) -> void:
	var rot := Vector3(0.0, 0.0, deg_to_rad(tilt))
	_part(r, Vector3(gw, gh, gd), "polymer", at, rot)
	for i in 3:
		var t: float = float(i) - 1.0
		_part(r, Vector3(gw * 0.30, gh * 0.13, gd * 1.05), "rubber",
			at + Vector3(gw * 0.42 + sin(deg_to_rad(tilt)) * t * gh * 0.24,
				-t * gh * 0.24, 0.0), rot)
	_part(r, Vector3(gw * 1.06, gh * 0.10, gd * 0.92), "polymer",
		at + Vector3(0.0, -gh * 0.52, 0.0), rot)

## A picatinny-style rail: a base with `n` cross fins.
static func _rail(r: Node3D, h: float, length: float, at: Vector3, n: int) -> void:
	_part(r, Vector3(length, h * 0.035, h * 0.14), "gunmetal", at)
	for i in n:
		var t: float = (float(i) / maxf(float(n - 1), 1.0)) - 0.5
		_part(r, Vector3(length * 0.055, h * 0.055, h * 0.13), "gunmetal",
			at + Vector3(t * length * 0.92, h * 0.035, 0.0))

## A front post in its hood and a rear notch on the top line.
static func _sights(r: Node3D, h: float, y: float, front_x: float, rear_x: float) -> void:
	_part(r, Vector3(h * 0.035, h * 0.14, h * 0.04), "blued", Vector3(front_x, y + h * 0.06, 0.0))
	for sz in [-1.0, 1.0]:
		_part(r, Vector3(h * 0.05, h * 0.16, h * 0.025), "blued",
			Vector3(front_x, y + h * 0.07, sz * h * 0.075))
	_part(r, Vector3(h * 0.06, h * 0.025, h * 0.17), "blued", Vector3(front_x, y + h * 0.15, 0.0))
	_part(r, Vector3(h * 0.06, h * 0.10, h * 0.17), "blued", Vector3(rear_x, y + h * 0.04, 0.0))
	_part(r, Vector3(h * 0.07, h * 0.06, h * 0.04), "polymer", Vector3(rear_x, y + h * 0.07, 0.0))

## A sling swivel: a loop on a stud.
static func _swivel(r: Node3D, h: float, at: Vector3) -> void:
	var mi: MeshInstance3D = _ring(r, h * 0.055, h * 0.014, "steel", at + Vector3(0.0, -h * 0.05, 0.0))
	mi.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
	_part(r, Vector3(h * 0.03, h * 0.05, h * 0.03), "steel", at)

## A knurled knob (charging handle, bolt).
static func _knurl(r: Node3D, radius: float, length: float, kind: String, at: Vector3) -> void:
	_tube(r, radius, radius, length, kind, at, 12)
	for i in 8:
		var a: float = float(i) * TAU / 8.0
		_part(r, Vector3(length * 0.9, radius * 0.16, radius * 0.16), kind,
			at + Vector3(0.0, sin(a) * radius, cos(a) * radius), Vector3(a, 0.0, 0.0))

## A pin / screw head standing proud of a flank (axis along Z).
static func _pin(r: Node3D, radius: float, length: float, kind: String, at: Vector3) -> void:
	_tube(r, radius, radius, length, kind, at, 10, Color(0, 0, 0, 0), Vector3(PI * 0.5, 0.0, 0.0))

## A lit lens facing +X (a muzzle, an optic).
static func _lens(r: Node3D, radius: float, col: Color, at: Vector3, aspect: float = 0.4) -> void:
	_tube(r, radius, radius, radius * aspect, "glow", at, 16, col)

# --- primitives, all built lying along +X -------------------------------

## A stippled normal map for moulded parts — grips and pads.
static var _stipple: Texture2D = null
static func _stipple_normal() -> Texture2D:
	if _stipple != null:
		return _stipple
	var n: int = 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			# Diamond checkering: a pyramid inside every 8 px cell.
			var u: float = fposmod(float(x) + float(y), 8.0) / 8.0
			var v: float = fposmod(float(x) - float(y), 8.0) / 8.0
			var g: float = (1.0 - absf(u - 0.5) * 2.0) * (1.0 - absf(v - 0.5) * 2.0)
			img.set_pixel(x, y, Color(g, g, g))
	img.bump_map_to_normal_map(2.4)
	img.generate_mipmaps()
	_stipple = ImageTexture.create_from_image(img)
	return _stipple

static func _mat(kind: String, tint: Color = Color(0, 0, 0, 0)) -> StandardMaterial3D:
	var spec: Array = MATERIALS.get(kind, MATERIALS["gunmetal"])
	var m := StandardMaterial3D.new()
	m.albedo_color = tint if tint.a > 0.0 else Color(spec[0])
	m.metallic = float(spec[1])
	m.roughness = float(spec[2])
	m.metallic_specular = 0.30
	if float(spec[4]) > 0.0:
		m.clearcoat_enabled = true
		m.clearcoat = float(spec[4])
		m.clearcoat_roughness = 0.15
	m.normal_enabled = true
	m.uv1_triplanar = true
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if GRIPPY.has(kind):
		# Moulded: a fine stipple over the same grime the metal wears.
		# Without the grime a big flat polymer face lit head-on comes out
		# a featureless grey slab — a linear 0.09 albedo displays as
		# about 0.33 sRGB, which is nothing like black plastic looks
		# next to an unlit receiver (2026-09-04).
		m.albedo_texture = PickupModels.grunge()
		m.normal_texture = _stipple_normal()
		m.normal_scale = 0.5
		m.uv1_scale = Vector3(0.9, 0.9, 0.9)
	else:
		m.albedo_texture = PickupModels.grunge()
		m.normal_texture = PickupModels.grunge_normal()
		m.normal_scale = 0.45
		m.uv1_scale = Vector3(0.05, 0.05, 0.05)
	if float(spec[3]) > 0.0:
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = float(spec[3])
		m.albedo_texture = null
		m.normal_enabled = false
	return m

## Chamfered box, cached by size and bevel. The cut edges are what make
## these read as machined parts instead of cubes: six inset faces, twelve
## edge strips and eight corner triangles.
static var _bevel_cache: Dictionary = {}
static func _chamfer_mesh(size: Vector3, bevel: float) -> ArrayMesh:
	var key := "%.3f_%.3f_%.3f_%.3f" % [size.x, size.y, size.z, bevel]
	if _bevel_cache.has(key):
		return _bevel_cache[key]
	var a: float = size.x * 0.5
	var b: float = size.y * 0.5
	var c: float = size.z * 0.5
	var t: float = minf(bevel, minf(a, minf(b, c)) * 0.45)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The six inset faces: [normal, u axis, v axis, offset, half-u, half-v]
	var faces: Array = [
		[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0), a, c - t, b - t],
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0), a, c - t, b - t],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1), b, a - t, c - t],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1), b, a - t, c - t],
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0), c, a - t, b - t],
		[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0), c, a - t, b - t],
	]
	for f in faces:
		var nrm: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var o: Vector3 = nrm * float(f[3])
		var hu: float = float(f[4])
		var hv: float = float(f[5])
		_quad(st, nrm, o - u * hu - v * hv, o + u * hu - v * hv,
			o + u * hu + v * hv, o - u * hu + v * hv)
	# Edge strips.
	for axis in 3:
		for i in 4:
			var s1: float = -1.0 if (i & 1) == 0 else 1.0
			var s2: float = -1.0 if (i & 2) == 0 else 1.0
			var p0: Vector3
			var p1: Vector3
			var q0: Vector3
			var q1: Vector3
			var nn: Vector3
			match axis:
				0:   # along X, between the ±Y and ±Z faces
					p0 = Vector3(-(a - t), s1 * b, s2 * (c - t))
					p1 = Vector3(a - t, s1 * b, s2 * (c - t))
					q0 = Vector3(-(a - t), s1 * (b - t), s2 * c)
					q1 = Vector3(a - t, s1 * (b - t), s2 * c)
					nn = Vector3(0.0, s1, s2).normalized()
				1:   # along Y, between the ±X and ±Z faces
					p0 = Vector3(s1 * a, -(b - t), s2 * (c - t))
					p1 = Vector3(s1 * a, b - t, s2 * (c - t))
					q0 = Vector3(s1 * (a - t), -(b - t), s2 * c)
					q1 = Vector3(s1 * (a - t), b - t, s2 * c)
					nn = Vector3(s1, 0.0, s2).normalized()
				_:   # along Z, between the ±X and ±Y faces
					p0 = Vector3(s1 * a, s2 * (b - t), -(c - t))
					p1 = Vector3(s1 * a, s2 * (b - t), c - t)
					q0 = Vector3(s1 * (a - t), s2 * b, -(c - t))
					q1 = Vector3(s1 * (a - t), s2 * b, c - t)
					nn = Vector3(s1, s2, 0.0).normalized()
			var wind: float = s1 * s2
			if axis == 1:
				wind = -wind
			if wind > 0.0:
				_quad(st, nn, p0, q0, q1, p1)
			else:
				_quad(st, nn, p0, p1, q1, q0)
	# Corner triangles: the three face vertices that replaced each corner.
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var px := Vector3(sx * a, sy * (b - t), sz * (c - t))
				var py := Vector3(sx * (a - t), sy * b, sz * (c - t))
				var pz := Vector3(sx * (a - t), sy * (b - t), sz * c)
				var n3 := Vector3(sx, sy, sz).normalized()
				if (sx * sy * sz) > 0.0:
					_tri(st, n3, px, py, pz)
				else:
					_tri(st, n3, px, pz, py)
	st.generate_tangents()
	var am: ArrayMesh = st.commit()
	_bevel_cache[key] = am
	return am

## One flat triangle. The UV is a planar projection along the face's
## DOMINANT axis — using (x, y) for every face made the +/-X faces
## degenerate (constant u), and generate_tangents() then produced NaN
## tangents there, which the normal map turned into a blown-out white
## panel: "the uzi has bad normals, you can see into the weapon"
## (2026-09-04).
static func _tri(st: SurfaceTool, n: Vector3, p0: Vector3, p1: Vector3, p2: Vector3) -> void:
	var ax: float = absf(n.x)
	var ay: float = absf(n.y)
	var az: float = absf(n.z)
	for p in [p0, p1, p2]:
		st.set_normal(n)
		if ax >= ay and ax >= az:
			st.set_uv(Vector2(p.z, p.y))
		elif ay >= az:
			st.set_uv(Vector2(p.x, p.z))
		else:
			st.set_uv(Vector2(p.x, p.y))
		st.add_vertex(p)

static func _quad(st: SurfaceTool, n: Vector3, p0: Vector3, p1: Vector3,
		p2: Vector3, p3: Vector3) -> void:
	_tri(st, n, p0, p1, p2)
	_tri(st, n, p0, p2, p3)

static func _add(r: Node3D, mesh: Mesh, mat: Material, at: Vector3, rot: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.add_child(mi)
	return mi

## A chamfered rectangular part.
static func _part(r: Node3D, size: Vector3, kind: String, at: Vector3,
		rot: Vector3 = Vector3.ZERO, tint: Color = Color(0, 0, 0, 0)) -> MeshInstance3D:
	var bevel: float = minf(size.x, minf(size.y, size.z)) * BEVEL
	return _add(r, _chamfer_mesh(size, bevel), _mat(kind, tint), at, rot)

## A box whose far (+X) face is a different size — stocks, muzzle
## flares, venturis. FLAT-shaded: the first cut built these from a
## four-sided cylinder, whose normals are radial, so the four flat faces
## shaded like a barrel and every stock came out as a pale grey slab
## with a dark panel down the middle (2026-09-04).
static var _frustum_cache: Dictionary = {}
static func _frustum_mesh(length: float, n_y: float, n_z: float,
		f_y: float, f_z: float) -> ArrayMesh:
	var key := "%.3f_%.3f_%.3f_%.3f_%.3f" % [length, n_y, n_z, f_y, f_z]
	if _frustum_cache.has(key):
		return _frustum_cache[key]
	var x0: float = -length * 0.5
	var x1: float = length * 0.5
	var a: float = n_y * 0.5
	var b: float = n_z * 0.5
	var c: float = f_y * 0.5
	var d: float = f_z * 0.5
	# Near face (-X) corners, then far face (+X) corners, both counted
	# anticlockwise seen from +X.
	var n0 := Vector3(x0, -a, -b)
	var n1 := Vector3(x0, -a, b)
	var n2 := Vector3(x0, a, b)
	var n3 := Vector3(x0, a, -b)
	var f0 := Vector3(x1, -c, -d)
	var f1 := Vector3(x1, -c, d)
	var f2 := Vector3(x1, c, d)
	var f3 := Vector3(x1, c, -d)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_flat_quad(st, n0, n1, n2, n3)          # near cap, facing -X
	_flat_quad(st, f3, f2, f1, f0)          # far cap, facing +X
	_flat_quad(st, n1, f1, f2, n2)          # +Z
	_flat_quad(st, n3, f3, f0, n0)          # -Z
	_flat_quad(st, n2, f2, f3, n3)          # +Y
	_flat_quad(st, n0, f0, f1, n1)          # -Y
	st.generate_tangents()
	var am: ArrayMesh = st.commit()
	_frustum_cache[key] = am
	return am

## A quad with one flat normal taken from its own winding.
static func _flat_quad(st: SurfaceTool, p0: Vector3, p1: Vector3,
		p2: Vector3, p3: Vector3) -> void:
	var n: Vector3 = (p1 - p0).cross(p2 - p0).normalized()
	_quad(st, n, p0, p1, p2, p3)

static func _taper(r: Node3D, near: Vector3, far: Vector3, kind: String, at: Vector3,
		rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	return _add(r, _frustum_mesh(near.x, near.y, near.z, far.y, far.z),
		_mat(kind), at, rot)

## A cylinder lying along +X (`extra_rot` re-aims it: (PI/2,0,0) = along Z).
static func _tube(r: Node3D, r0: float, r1: float, length: float, kind: String,
		at: Vector3, segments: int = 16, tint: Color = Color(0, 0, 0, 0),
		extra_rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r0
	cm.top_radius = r1
	cm.height = length
	cm.radial_segments = segments
	cm.rings = 1
	return _add(r, cm, _mat(kind, tint), at,
		Vector3(0.0, 0.0, deg_to_rad(-90.0)) + extra_rot)

## A ring around the barrel (a band, a coil, a scope mount).
static func _ring(r: Node3D, radius: float, thickness: float, kind: String,
		at: Vector3) -> MeshInstance3D:
	var tm := TorusMesh.new()
	tm.inner_radius = maxf(radius - thickness, 0.001)
	tm.outer_radius = radius + thickness
	tm.rings = 20
	tm.ring_segments = 10
	return _add(r, tm, _mat(kind), at, Vector3(0.0, 0.0, deg_to_rad(90.0)))

static func _sphere(r: Node3D, radius: float, kind: String, at: Vector3,
		tint: Color = Color(0, 0, 0, 0)) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 20
	sm.rings = 10
	return _add(r, sm, _mat(kind, tint), at, Vector3.ZERO)
