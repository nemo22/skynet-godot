## A mission objective — DOS acts 0x26..0x2A (handler 0x1377d0): when a
## chain sets its bit 0 it decrements the mission's "objectives
## remaining" counter (DAT_0004e4c2), prints the [M1]..[M5] line, plays
## sound 0x51 and disables itself (act ← 0xFF, `spent` here). The
## mission ends when the counter reaches 0 — mission 1's objectives sit
## on MAP.215 and MAP.217. Act 0x2B (handler 0x13782d) fails the
## mission at once.
##
## The counter itself lives on the Mission node of the branch. Live
## since F2 (2026-09-05): the Behaviour root fires it and relays
## `fired` as objective_complete / mission_failed.

extends Node3D

signal fired(index: int)

@export var id: int = 0
@export var act: int = 0x26
## 0-based: act - 0x26 → [M<index + 1>]; -1 for the mission-failed act.
@export var index: int = 0
@export var fails_mission: bool = false
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
