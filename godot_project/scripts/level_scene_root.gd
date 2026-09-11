## Root of a baked level scene (converted/maps/MAP.NNN.level.scn).
##
## Everything here is provenance: which MAP the scene was built from
## and by which version of the bake. The loader checks both and
## rebuilds the scene when either has moved on — editing a map (SkyNET
## Maps dock → export to mods/maps/) changes the hash, so an edited map
## never plays with stale geometry.
##
## See scripts/level_scene.gd for the node layout.

@tool
extends Node3D

@export var map_name: String = ""
@export var bake_version: int = 0
## hash() of the MAP file this was built from.
@export var source_hash: int = 0
@export var is_outdoor: bool = false
## For the log and the editor inspector.
@export var static_count: int = 0
## Nodes in the Behaviour branch (scripts/level_behaviour.gd).
@export var behaviour_count: int = 0
