## A hint message — DOS acts 0x1C..0x25 (handler 0x13779d): prints the
## [G1]..[G10] line of the mission's briefing script and changes no
## counter. Fires once when a chain sets its bit 0, then DOS writes 0xFF
## into the act byte.
##
## The text is copied in at import from <mission>.TXT (MDMDBRIF.BSA)
## when the map belongs to a campaign mission, so the editor shows what
## the trigger will say.
##
## F1 (2026-09-05): generated and inert — action_system.gd still runs
## the records.

extends Node3D

@export var id: int = 0
@export var act: int = 0x1C
## 0-based: act - 0x1C → [G<index + 1>].
@export var index: int = 0
@export_multiline var text: String = ""
## DOS state byte: bit 0 = armed.
@export var state: int = 0
@export var targets: Array[NodePath] = []
