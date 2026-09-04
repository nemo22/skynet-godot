extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var ps := ResourceLoader.load(args[0] if args.size() > 0 else "") as PackedScene
	if ps == null:
		print("no scene")
		quit(1)
		return
	var root := ps.instantiate()
	var sprites := root.get_node_or_null("Sprites")
	var n := 0
	var sizes: Array = []
	if sprites != null:
		for c in sprites.get_children():
			if c is Sprite3D:
				n += 1
				if sizes.size() < 6:
					var t: Texture2D = (c as Sprite3D).texture
					sizes.append("%s px=%.3f h=%.0f" % [c.name,
						(c as Sprite3D).pixel_size,
						float(t.get_height()) * (c as Sprite3D).pixel_size if t else 0.0])
	print("sprites=%d  %s" % [n, ", ".join(sizes)])
	root.free()
	quit()
