## The way out of a DEBUG TOOLS viewer.
##
## Each viewer (texture atlas, 3D objects, enemies, sounds) is a scene of
## its own that the menu launches with change_scene_to_file, and not one
## of them had a way back: "ked niektoru zapnem uz sa neviem dostat na
## spat do menu" (playtest 2026-09-12). Esc now returns to the menu, and
## `add_hint` says so on screen — a tool you cannot leave is worse than
## no tool.

extends RefCounted

const MENU_SCENE: String = "res://scenes/menu.tscn"

## True when `event` was the way out — the scene change is already under
## way, so the caller should return without handling it further.
static func handled(node: Node, event: InputEvent) -> bool:
	if node == null or not (event is InputEventKey):
		return false
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return false
	if k.keycode != KEY_ESCAPE and k.keycode != KEY_BACKSPACE:
		return false
	var tree: SceneTree = node.get_tree()
	if tree == null:
		return false
	tree.change_scene_to_file(MENU_SCENE)
	return true

## A corner note telling the player which key leaves. On a layer of its
## own so a viewer's own UI cannot cover it.
static func add_hint(node: Node, extra: String = "") -> void:
	if node == null:
		return
	var l := Label.new()
	l.text = "ESC — BACK TO MENU" + ("   ·   " + extra if not extra.is_empty() else "")
	l.add_theme_color_override("font_color", Color(0.86, 0.9, 0.95))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 5)
	l.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	l.offset_left = 14.0
	l.offset_top = -34.0
	l.offset_bottom = -8.0
	l.offset_right = 900.0
	var layer := CanvasLayer.new()
	layer.layer = 120
	layer.add_child(l)
	node.add_child(layer)
