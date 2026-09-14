## A DOS mover — a door leaf, a gate, a lift, a rotating dish — as a
## Godot node (docs/map_format_plan.md §2).
##
## In DOS the entity's handler (the Skynet.exe 0x59b00 slot for `act`)
## moves the entity's position, or an 11-bit angle, one step per tick
## while the entity's enable bit is set, and clears the bit at the end
## of the travel; the next trigger runs it back. Here that travel is the
## "move" animation on the AnimationPlayer, generated once at import
## (scripts/level_behaviour.gd) from the same table and the same speeds
## the runtime action system uses, and the Body it moves is the collider
## the player bumps into.
##
##   Mover (this)          position = the DOS entity position, no rotation
##   +- AnimationPlayer    "move": Body from rest to the end of the travel
##   +- Body               AnimatableBody3D, basis = the DOS rotation
##      +- Mesh
##      +- Shape           a box for a door leaf, the trimesh otherwise
##
## The node itself carries no rotation, so the slide axis of the
## animation is a world axis (as in DOS, the handlers add to the entity
## position), and moving the node in the editor moves the whole travel
## with it.
##
## F1 (2026-09-05): generated and inert — the game still runs the DOS
## records through action_system.gd. F2 switches the runtime over.

extends Node3D

const ANIM := &"move"

## Stable id of this entity within its map — the MAP file offset the
## import read it from. Saves and the network key state by it (plan §3).
@export var id: int = 0
## DOS handler id (0x59b00 slot). Odd and even ids are the two
## directions of one family — the BIGDOOR leaves carry 0x41 and 0x42.
@export var act: int = 0
@export var mesh_name: String = ""
## slide / swing / jump / slide5f / rot — ActionSystem.MOVER_TABLE.
@export var family: String = "slide"
## DOS axis of the motion: 0 = X, 1 = Y (down), 2 = Z.
@export var axis: int = 0
## Full travel, signed in the direction the first trigger moves it:
## world units for slides, 11-bit angle units for swings (2048 = 360°).
@export var travel: float = 0.0
## Units of `travel` per second; 0 = instant (the DOS "jump" family).
@export var speed: float = 0.0
## Seconds for the full travel — the length of the "move" animation.
@export var duration: float = 0.0
## DOS state byte: bit 0 = enabled at start (rotators spin from load),
## bit 1 = act on every hit, bit 2 = act when the HP runs out,
## bit 3 = use key.
@export var state: int = 0
@export var hp: int = 0
## The next link of the DOS chain (ObjFlipLink) — what a flip of this
## node passes on to.
@export var targets: Array[NodePath] = []

## Run the travel forward — open the door, lower the lift.
func open() -> void:
	var ap := _player()
	if ap != null and ap.has_animation(ANIM):
		ap.play(ANIM)

## Run it back.
func close() -> void:
	var ap := _player()
	if ap != null and ap.has_animation(ANIM):
		ap.play_backwards(ANIM)

func _player() -> AnimationPlayer:
	return get_node_or_null(^"AnimationPlayer") as AnimationPlayer
