## A voice line — DOS act 0xED (handler 0x137dfd): plays the VOICE.PRS
## sample whose id sits at sub+2 ("no.21032 = 210g5.wav") and clears
## its own enable bit. MAP.212's truck ride is one of these at the end
## of a floor gate's chain.
##
## Live since F2 (2026-09-05): the Behaviour root fires it when a chain
## flip enables it.

extends Node3D

@export var id: int = 0
@export var act: int = 0xED
## VOICE.PRS id ("no.<voice_id> = <file>.wav").
@export var voice_id: int = 0
## DOS state byte: bit 0 = armed.
@export var state: int = 0
@export var targets: Array[NodePath] = []

func fire() -> void:
	Audio.play_voice(voice_id)
