## One DOS map standing inside a mission scene.
##
## A mission is a handful of MAP files — the outdoor world and every
## interior its doorways reach — and the port now holds them all at once
## (docs/m2_mission_scene_plan.md). They cannot all sit at the DOS origin,
## so each one becomes a ZONE: a Node3D placed on a +X grid whose child
## `Level` is the baked converted/maps/MAP.NNN.level.scn. Everything the
## MAP records say stays zone-local; the node's own transform is what puts
## the zone in the world (Level.origin, Behaviour.zone_origin).
##
## The exports are what the runtime needs to switch a zone on without
## re-reading the MAP: which heightmap it stands on, the music track its
## maptype marker picks, where its water surface is, which spawn marker
## sets its doorways can land on, and which re-authored variants of it the
## mission can move to (the phases).
##
## Baked by scripts/mission_scene.gd. Data only — the runtime that acts on
## it is step 4 of the plan.
@tool
extends Node3D

## "MAP.218", and its number on its own.
@export var map_name: String = ""
@export var map_num: int = 0
## MAP+9028 == 1: the zone has a heightmap and a sky.
@export var outdoor: bool = false
## Cell grid of the MAP (64x64 outdoors, 4x4 … 36x36 indoors). The zone's
## width on the +X grid comes from this.
@export var grid: Vector2i = Vector2i.ZERO
## Which WLD the ground comes from ("210"), "" for an indoor zone.
@export var wld_suffix: String = ""
## DOS maptype (marker type 6, sub+2) — indexes the music table.
@export var maptype: int = 0
## Surface Y of the map's water (marker 103/104, DOS Y − 0x10), zone-local.
## INF when the zone is dry, which is what main._water_level answers too.
@export var water_y: float = INF
## The spawn marker sets this zone offers a doorway (marker type N = the
## position of set N, N+1 = the facing).
@export var spawn_sets: PackedInt32Array = PackedInt32Array()
## Re-authored variants of this same world, in the order the mission
## reaches them ("MAP.216", "MAP.217"). Empty for every zone that is only
## ever itself; the diffs live under Phases.
@export var phases: PackedStringArray = PackedStringArray()
## How far from the start map the census had to walk to reach this zone,
## and through which exit record.
@export var depth: int = 0
@export var entered_from_map: int = 0
@export var entered_from_off: int = -1

func _ready() -> void:
	_quiet_preview()

## A level scene carries its own EditorPreview — a night sky, a key light
## and gizmos for its enemies and markers — so that opening that one map
## shows something. A mission holds up to seventeen of them and only one
## may light the view, so each zone puts its own out as it comes up.
##
## Not done in the bake: the packer records a property set INSIDE an
## instance only for an instance the scene marks editable, and marking one
## makes the mission scene store an entry for every node of the level
## (MISSION.260, a single zone, went from a few kB to 213 kB that way).
##
## The environment is a separate matter — a WorldEnvironment is a Node,
## not a Node3D, so hiding a branch never reaches it, and it is the one
## standing EARLIEST in the tree whose environment the viewport takes.
## That is why the mission's own EditorPreview is the root's first child.
func _quiet_preview() -> void:
	var prev: Node = get_node_or_null("Level/EditorPreview")
	if prev is Node3D:
		(prev as Node3D).visible = false
