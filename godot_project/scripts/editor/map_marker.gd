## A placement marker (player start, facing, exits, waypoints …) or a
## variant-2 light in an editor map scene, drawn as a small box with a
## floating label so it can be selected and moved like any node.

@tool
extends MeshInstance3D

@export var rec: Resource = null

func setup_gizmo(label: String, color: Color, cache: Dictionary) -> void:
	var key := color.to_html()
	if not cache.has(key):
		var bm := BoxMesh.new()
		bm.size = Vector3(40.0, 40.0, 40.0)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = color
		bm.material = mat
		cache[key] = bm
	mesh = cache[key]
	var l := Label3D.new()
	l.name = "Label"
	l.text = label
	l.pixel_size = 1.0
	l.font_size = 48
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.position = Vector3(0.0, 50.0, 0.0)
	add_child(l)
