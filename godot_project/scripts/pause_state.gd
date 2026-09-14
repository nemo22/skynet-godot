## Who has paused the game, and who needs the mouse — one owner for both.
##
## Nine places used to write `get_tree().paused` themselves (the Esc menu,
## the console, the automap, the briefing, the end screens …), so closing
## one overlay resumed the game under another, and in a network game the
## console froze the local player while the match went on. Every overlay
## now PUSHES a reason while it is up and POPS it when it goes; the tree is
## paused while any reason is held — except in a network game, which is
## never paused (the overlay only takes the input; main.gd locks the
## player's controls, see main._refresh_net_input_lock).
##
## The mouse follows the same stack. A pushed reason frees the cursor
## through the player's own release_mouse(): fly_camera.gd keeps its
## capture state in `_captured`, and a cursor freed behind its back left
## mouse look and held fire running under a menu. fly_camera does not take
## the mouse back on a click while mouse_wanted() is true. Popping the last
## reason does not recapture — the player clicks back in, as before.
##
## Static, used through `preload("res://scripts/pause_state.gd")`: an
## autoload would need project.godot.
extends RefCounted

static var _reasons: Dictionary = {}     # StringName → true
static var _mouse: Dictionary = {}       # StringName → true

## An overlay came up: pause (single player) and free the mouse.
static func push(reason: StringName) -> void:
	_reasons[reason] = true
	take_mouse(reason)
	_apply()

## That overlay went away; the game resumes once no other reason is left.
static func pop(reason: StringName) -> void:
	give_mouse(reason)
	if _reasons.erase(reason):
		_apply()

## Any overlay up (in a network game too, where the tree keeps running).
static func is_paused() -> bool:
	return not _reasons.is_empty()

static func holds(reason: StringName) -> bool:
	return _reasons.has(reason)

## Every reason and mouse owner dropped, the tree running and the cursor
## free: the game scene is being left (main menu, a dev scene switch).
static func reset() -> void:
	_reasons.clear()
	_mouse.clear()
	_apply()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## `owner` needs a visible cursor until give_mouse(owner).
static func take_mouse(owner: StringName) -> void:
	_mouse[owner] = true
	var p: Node = _player()
	if p != null and p.has_method("release_mouse"):
		p.call("release_mouse")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

static func give_mouse(owner: StringName) -> void:
	_mouse.erase(owner)

## True while something owns the cursor — a click must not capture it.
static func mouse_wanted() -> bool:
	return not _mouse.is_empty()

static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

## Net.active, looked up in the tree so this script also compiles where
## the autoloads do not exist (save_game.gd does the same).
static func _network() -> bool:
	var tree := _tree()
	var net: Node = tree.root.get_node_or_null("Net") if tree != null else null
	return net != null and bool(net.get("active"))

static func _player() -> Node:
	var tree := _tree()
	return tree.get_first_node_in_group("player") if tree != null else null

static func _apply() -> void:
	var tree := _tree()
	if tree != null:
		tree.paused = not _reasons.is_empty() and not _network()
