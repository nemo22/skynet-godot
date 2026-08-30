## One MAP entity record as an inspector-editable resource. Carried by
## every node of an editor map scene (map_scene.gd); the fields mirror
## MapFile.Entity — `file_off` is the entity's identity (link chains
## point at file offsets), `dos_pos` the raw DOS coordinates (Y down).

@tool
extends Resource

@export var file_off: int = 0
@export var variant: int = 0            # 1 mesh, 2 light, 3 sprite/marker
@export var flags: int = 0
@export var mesh_name: String = ""
@export var dos_pos: Vector3i = Vector3i.ZERO
@export var cell: Vector2i = Vector2i.ZERO
@export_range(0, 2047) var pitch: int = 0
@export_range(0, 2047) var yaw: int = 0
@export_range(0, 2047) var roll: int = 0
## The three raw i32 angle words (sub+0/+4/+8) — the bits above the
## 11-bit angle carry other data (an enemy marker's trap distance sits
## in the upper half of the first word), so the writer only replaces
## the low 11 bits.
@export var raw_angles: Vector3i = Vector3i.ZERO
@export var state_byte: int = 0
@export var link_next: int = 0
@export var link_act_type: int = 0
@export var hp: int = 0
## hp / state / link resolved from the map's per-name default list.
@export var uses_defaults: bool = false
@export var sprite_index: int = -1
@export var marker_type: int = -1
@export var enemy_type: int = -1
@export var exit_map: int = 0
@export var exit_marker_id: int = 0
@export var light_intensity: int = -1
@export var light_enable: int = 0
