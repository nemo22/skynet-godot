## One bank of airborne dust that actually drifts.
##
## The first version laid a flat volumetric haze over the whole map and
## parked six huge dense blobs in it: "strasne husta a tmava… to nemuselo
## byt vsade, skor len kde tu mracno pofukujuce" (2026-09-04). A bank is
## now thin, local and slowly on the move — it swings along one axis and
## breathes, so from any one spot there is dust passing through, not dust
## standing in the air.
##
## The motion is a sine, not a wrap: a bank is hundreds of metres across,
## and anything that teleports it would pop in the corner of the eye.

extends FogVolume

## World units the bank swings either side of where it was placed.
@export var reach: float = 1700.0
## Seconds for one full there-and-back.
@export var period: float = 74.0
## Which way the wind takes it.
@export var heading: float = 0.0
## How much the density breathes (0 = steady, 1 = fades right out).
@export var breathe: float = 0.45

var _home: Vector3 = Vector3.ZERO
var _base_density: float = 0.01
var _t: float = 0.0

func _ready() -> void:
	_home = position
	# Start each bank somewhere else in its cycle, or they all sway
	# together like a chorus line.
	_t = float(hash(_home) % 1000) / 1000.0 * TAU
	if material is FogMaterial:
		_base_density = (material as FogMaterial).density

func _process(delta: float) -> void:
	_t += delta * TAU / maxf(period, 1.0)
	var swing: float = sin(_t)
	position = _home + Vector3(cos(heading), 0.0, sin(heading)) * swing * reach \
		+ Vector3(0.0, sin(_t * 0.37) * reach * 0.05, 0.0)
	if material is FogMaterial:
		# Thickest half way through the pass, thinnest at the ends.
		(material as FogMaterial).density = _base_density \
			* (1.0 - breathe + breathe * (0.5 + 0.5 * cos(_t * 2.0)))
