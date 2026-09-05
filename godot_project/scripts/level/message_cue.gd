## A hint message — DOS acts 0x1C..0x25 (handler 0x13779d): prints the
## [G1]..[G10] line of the mission's briefing script and changes no
## counter. Fires once when a chain sets its bit 0, then DOS writes 0xFF
## into the act byte — `spent` here.
##
## The text is copied in at import from <mission>.TXT (MDMDBRIF.BSA)
## when the map belongs to a campaign mission, so the editor shows what
## the trigger will say. Live since F2 (2026-09-05): the Behaviour root
## fires it and relays `fired` as hint_message.

extends Node3D

signal fired(index: int)

@export var id: int = 0
@export var act: int = 0x1C
## 0-based: act - 0x1C → [G<index + 1>].
@export var index: int = 0
@export_multiline var text: String = ""
## DOS state byte: bit 0 = armed.
@export var state: int = 0
@export var targets: Array[NodePath] = []

var spent: bool = false

func fire() -> void:
	if spent:
		return
	spent = true
	fired.emit(index)
