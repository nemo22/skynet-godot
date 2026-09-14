## A collectible item — a billboard the player walks over to grab.
##
## DOS: at map start FUN_0011d600 gives every variant-3 sprite listed in
## the item table (Skynet.exe 0x35800 → PickupData.ITEMS) action 0xFD;
## handler 0x11d670 collects it once the player is close (80 units
## across, 160 up/down): tops up the item's ammo pool (clamped to the
## pool maximum), heals a percentage, adds armor, grants and selects a
## weapon, prints the STRINGS.PRS "PICKED UP ..." line and removes the
## sprite — the pickup is consumed even when nothing could be added.
## Sprites in the weapon/equipment banks that the table omits stay as
## plain scenery, exactly as in DOS.

extends Sprite3D

const PickupData := preload("res://scripts/pickup_data.gd")
const PrsFile := preload("res://scripts/loaders/prs_file.gd")

const GRAB_RANGE_H: float = 80.0      # horizontal reach (0x11d670: 0x50)
const GRAB_RANGE_V: float = 160.0     # vertical window (0xa0)
const PICKUP_SOUND_ID: int = 179      # 0x11d670 → 0x12f3f7(0xb3)

## A pickup farther than WAKE_RANGE from the player does not process at
## all (MAP.240 carries 131, each bobbing and testing the grab every
## tick). One of them — the first in the tree, the warden — always runs
## and wakes or rests the others every WAKE_INTERVAL, and at once when
## the player jumps (a teleport, a loaded save, a respawn). The grab
## reaches 80 u, so a resting pickup cannot be walked onto before it is
## awake: that would take 3000 u in a quarter second.
const WAKE_RANGE: float = 3000.0
const WAKE_INTERVAL: float = 0.25
## A move this long between two ticks is a jump, not a walk.
const JUMP_DIST: float = 400.0

## Every pickup inside the tree, the warden first.
static var _all: Array = []
static var _wake_t: float = 0.0
static var _last_player: Vector3 = Vector3.INF

var _item: Array = []
var _player: Node3D = null
var _bob_t: float = 0.0
var _base_y: float = 0.0

## Configure from the DOS item table entry for `sprite_index`
## ([pool, amount, heal %, armor/65536, weapon, message key]).
func setup_item(sprite_index: int) -> void:
	_item = PickupData.ITEMS.get(sprite_index, [])

func item() -> Array:
	return _item

func _ready() -> void:
	_base_y = position.y
	add_to_group("pickup")

func _enter_tree() -> void:
	_all.append(self)
	set_physics_process(true)
	_wake_t = 0.0                          # take a fresh look next tick

func _exit_tree() -> void:
	_all.erase(self)
	# The warden may be the one leaving: whoever leads now must run.
	if not _all.is_empty() and is_instance_valid(_all[0]):
		(_all[0] as Node).set_physics_process(true)

func _physics_process(delta: float) -> void:
	if not _all.is_empty() and _all[0] == self:
		_ward(delta)
	# Gentle hover so pickups read as interactive, not scenery.
	_bob_t += delta
	position.y = _base_y + sin(_bob_t * 3.0) * 14.0

	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	var d: Vector3 = _player.global_position - global_position
	if Vector2(d.x, d.z).length() > GRAB_RANGE_H or absf(d.y) > GRAB_RANGE_V:
		return
	if has_meta("dm_key"):
		# Deathmatch: the server hands the item out (dm_game.gd applies
		# it when the taken notice names us).
		if _player.get("input_locked") == true:
			return
		_dm_req_t -= delta
		if _dm_req_t <= 0.0:
			_dm_req_t = 0.5
			Net.request_pickup(int(get_meta("dm_key")))
		return
	collect(_player)

var _dm_req_t: float = 0.0

## The warden's round: wake the pickups within WAKE_RANGE of the player,
## rest the rest (never itself).
func _ward(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	var here: Vector3 = _player.global_position
	var jumped: bool = here.distance_squared_to(_last_player) > JUMP_DIST * JUMP_DIST
	_last_player = here
	_wake_t -= delta
	if _wake_t > 0.0 and not jumped:
		return
	_wake_t = WAKE_INTERVAL
	var r2: float = WAKE_RANGE * WAKE_RANGE
	for p in _all:
		if p == self or not is_instance_valid(p):
			continue
		(p as Node).set_physics_process(
			(p as Node3D).global_position.distance_squared_to(here) < r2)

## Apply the item to `player` and consume the pickup.
func collect(player: Node) -> void:
	apply(player)
	if Audio.sound_name(PICKUP_SOUND_ID).is_empty():
		Audio.play_sfx("CLICK.RAW", -4.0)
	else:
		Audio.play_id(PICKUP_SOUND_ID, -4.0)
	queue_free()

## The item's effect on `player` (no sound, the node stays).
func apply(player: Node) -> void:
	if _item.size() >= 6:
		var pool: int = int(_item[0])
		var amount: int = int(_item[1])
		var heal: int = int(_item[2])
		var armor: int = int(_item[3])
		var weapon: int = int(_item[4])
		var msg: String = String(_item[5])
		if pool >= 0 and amount > 0 and player.has_method("add_pool"):
			player.add_pool(pool, amount)
		if heal > 0 and player.has_method("heal_percent"):
			player.heal_percent(heal)
		if armor > 0 and player.has_method("add_armor"):
			player.add_armor(float(armor) / 65536.0)
		if weapon >= 0 and player.has_method("give_weapon"):
			player.give_weapon(weapon)
		if not msg.is_empty() and player.has_signal("pickup_message"):
			player.emit_signal("pickup_message", PrsFile.text("STRINGS.PRS", msg, msg))
