## One PHASE EDGE of a mission: what changes when the world is re-authored.
##
## The outdoor half of a mission is shipped several times over. MAP.216 is
## MAP.210 later in the mission — the same hills, the same buildings, with
## the gate open, the truck gone and a fresh crop of enemies — and DOS
## reaches it by an ordinary 0xF0 exit that happens to lead back outdoors.
## A mission scene holds the world ONCE and moves it forward instead, so
## this node carries the difference between two consecutive variants as
## plain data: which entities appear, which go, which are re-authored, and
## whether the heightmap moved.
##
## Entities are identified the way the census and main.gd identify them
## across variants: kind + name/type + the exact DOS position (`id`). The
## file offset is stored beside it because rebuilding an entity needs the
## record's own fields, and the record is in the MAP the offset belongs to
## — the TARGET map for `added` and `changed`, the SOURCE map for
## `removed`.
##
## Data only: the runtime that applies a phase is step 5 of
## docs/m2_mission_scene_plan.md.
@tool
extends Node3D

## The variant this edge leads from, and the one it leads to.
@export var from_map: int = 0
@export var to_map: int = 0
## The heightmap the target variant stands on ("216").
@export var wld_suffix: String = ""
## Entities the target variant has and the source has not:
## {id: String, off: int (in the TARGET map), does: String}.
@export var added: Array[Dictionary] = []
## Entities the source has and the target has not:
## {id: String, off: int (in the SOURCE map), does: String}.
@export var removed: Array[Dictionary] = []
## Entities both variants have, authored differently — another act, state,
## chain, hit points or destruction type:
## {id: String, off: int (in the TARGET map), was: String, now: String}.
@export var changed: Array[Dictionary] = []
## WLD cells whose bytes differ, per layer (0 = height + diagonal,
## 2 = material): {"layer_0": {"cells": int, "rect": Array}, …}.
@export var terrain: Dictionary = {}
