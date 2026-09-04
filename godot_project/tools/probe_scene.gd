## Inspect a baked level scene without starting the game.
##
##   godot --headless --path . --script res://tools/probe_scene.gd \
##       -- res://converted/enhanced/maps/MAP.220.level.scn
##
## Prints how many nodes of each type the scene stores, then instantiates
## it and counts the collision bodies and shapes — the quickest way to
## tell whether a bake actually carries its geometry AND its collision
## (a missing "Static" hand-over once left every map without floors).

extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var p: String = args[0] if args.size() > 0 else ""
	var ps := ResourceLoader.load(p) as PackedScene
	if ps == null:
		print("no scene at %s" % p)
		quit(1)
		return
	var st := ps.get_state()
	var kinds: Dictionary = {}
	for i in st.get_node_count():
		var t: String = st.get_node_type(i)
		kinds[t] = int(kinds.get(t, 0)) + 1
	print("%s: %d nodes %s" % [p.get_file(), st.get_node_count(), kinds])
	var root := ps.instantiate()
	var bodies := 0
	var shapes := 0
	var empty := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionObject3D:
			bodies += 1
		if n is CollisionShape3D:
			shapes += 1
			if (n as CollisionShape3D).shape == null:
				empty += 1
				print("  EMPTY shape at %s" % n.get_path())
		for c in n.get_children():
			stack.append(c)
	print("groups %s" % str(root.get_children()))
	print("bodies %d, shapes %d (%d empty)" % [bodies, shapes, empty])
	root.free()
	quit()
