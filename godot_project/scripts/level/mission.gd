## The mission a map belongs to: the [M1]..[M5] objective counter and
## the message texts, from <key>.TXT in MDMDBRIF.BSA. One per level
## branch, only for campaign maps (MAP.2xx: mission = (suffix / 10) *
## 10, so MAP.217 belongs to mission 210 and its objectives count
## toward that mission's total — DOS keeps the counter across the
## interior trips).
##
## F1 (2026-09-05): generated and inert — main.gd still reads the
## briefing itself.

extends Node

## Mission key = the start map's suffix (210, 220 … 280).
@export var key: int = 0
## How many [M] lines the script has — the count that has to reach 0.
@export var objectives_total: int = 0
@export var objectives: PackedStringArray = PackedStringArray()
@export var hints: PackedStringArray = PackedStringArray()
