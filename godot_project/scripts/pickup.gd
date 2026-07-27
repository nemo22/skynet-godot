## A collectible item — a billboard sprite the player walks over to grab.
##
## DOS variant-3 sprites in the "weapons flat" banks (TEXTURE.200/201) are
## weapon/ammo pickups; the "equipment" bank (TEXTURE.214) holds health
## and gear. Decorative billboards (barrels, rubble, corpses, signs …)
## stay as plain Sprite3D — only these become Pickup nodes.

extends Sprite3D

enum Kind { AMMO, HEALTH }

const GRAB_RANGE: float = 150.0

var _kind: Kind = Kind.AMMO
var _amount: int = 0
var _player: Node3D = null
var _bob_t: float = 0.0
var _base_y: float = 0.0

## Configure the pickup. `amount` is ammo rounds (AMMO) or health (HEALTH).
func setup_pickup(kind: Kind, amount: int) -> void:
	_kind = kind
	_amount = amount

func _ready() -> void:
	_base_y = position.y

func _physics_process(delta: float) -> void:
	# Gentle hover so pickups read as interactive, not scenery.
	_bob_t += delta
	position.y = _base_y + sin(_bob_t * 3.0) * 14.0

	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	if global_position.distance_to(_player.global_position) > GRAB_RANGE:
		return

	var taken := false
	match _kind:
		Kind.AMMO:
			if _player.has_method("add_ammo"):
				taken = _player.add_ammo(_amount)
		Kind.HEALTH:
			if _player.has_method("add_health"):
				taken = _player.add_health(_amount)
	if taken:
		Audio.play_sfx("CLICK.RAW", -4.0)
		queue_free()
