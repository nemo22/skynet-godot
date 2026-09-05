## A one-shot positional sound — DOS acts 0xDB..0xEB (handler 0x137dbd),
## the door and button sounds every mover chain routes through: a
## BUTTON01 gate flips a sound node flips the BIGDOOR leaves. The
## handler plays the slot's sound id (the 0x4ff00 table) and clears its
## own enable bit; a node armed in the MAP data plays once at level
## start.
##
## The node IS the player: the stream is the cached clip, so the
## editor's inspector can audition it. Live since F2 (2026-09-05): the
## Behaviour root fires it when a chain flip enables it.

extends AudioStreamPlayer3D

## The level the DOS one-shots play at (action_system.gd used -4 dB);
## the wall in between takes its share (Audio.occlusion_db).
const BASE_DB: float = -4.0

@export var id: int = 0
@export var act: int = 0
## DOS sound id (Audio.SOUND_IDS).
@export var sound_id: int = -1
## DOS state byte: bit 0 = armed — plays on the next tick, then clears.
@export var state: int = 0
@export var targets: Array[NodePath] = []

## What a chain flip does to this node.
func fire() -> void:
	if stream == null or not is_inside_tree():
		return
	volume_db = BASE_DB + Audio.occlusion_db(global_position)
	play()
