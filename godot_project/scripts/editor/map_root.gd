## Root of an editor map scene (converted/maps/MAP.NNN.scn).

@tool
extends Node3D

@export var map_name: String = ""
@export var is_outdoor: bool = false
@export var grid_size: Vector2i = Vector2i.ZERO
## The MAP name table (variant-1 entities index into it).
@export var names: PackedStringArray = PackedStringArray()
## The original MAP file — the writer patches this copy in place so
## every byte we do not understand survives a round trip.
@export var raw: PackedByteArray = PackedByteArray()
