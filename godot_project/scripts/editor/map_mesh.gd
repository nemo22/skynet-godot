## A variant-1 mesh entity (or an enemy marker shown with its type mesh)
## in an editor map scene. The mesh comes from the asset cache; `rec`
## holds the MAP record.

@tool
extends MeshInstance3D

@export var rec: Resource = null
