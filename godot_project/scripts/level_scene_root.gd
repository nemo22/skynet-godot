## Root of a baked level scene (converted/maps/MAP.NNN.level.scn).
##
## Everything here is provenance: which MAP the scene was built from,
## which look it was built for, and by which version of the bake. The
## loader checks all three and rebuilds the scene when any of them has
## moved on — editing a map (SkyNET Maps dock → export to mods/maps/)
## changes the hash, so an edited map never plays with stale geometry.
##
## See scripts/level_scene.gd for the node layout.

@tool
extends Node3D

@export var map_name: String = ""
## Render.DOS / Render.ENHANCED — the two looks use different meshes and
## different textures, so they get a scene each.
@export var render_mode: int = 0
@export var bake_version: int = 0
## hash() of the MAP file this was built from.
@export var source_hash: int = 0
@export var is_outdoor: bool = false
## For the log and the editor inspector.
@export var static_count: int = 0
@export var detail_count: int = 0
