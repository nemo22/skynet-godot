## Inspect a baked level scene without starting the game.
##
##   godot --headless --path . --script res://tools/probe_scene.gd \
##       -- res://converted/maps/MAP.220.level.scn
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
	var scene_root := ps.instantiate()
	# Auto-named nodes ("@Class@id") are a sign of sibling name clashes at pack time.
	var auto: Array = []
	var stack0: Array = [scene_root]
	while not stack0.is_empty():
		var q: Node = stack0.pop_back()
		if String(q.name).begins_with("@"):
			auto.append("%s/%s" % [String(q.get_parent().name) if q.get_parent() else "", q.name])
		for ch in q.get_children():
			stack0.append(ch)
	print("auto-named nodes: %d %s" % [auto.size(), auto.slice(0, 6)])
	# Does every Static child enter the tree with its parent? (2026-09-06:
	# 40 of a Future Shock map's, 19 of MAP.210's did not, at runtime.)
	var st_node: Node = scene_root.get_node_or_null("Static")
	if st_node != null:
		get_root().add_child(scene_root)
		var out_of_tree: int = 0
		var dup_names: Dictionary = {}
		for ch in st_node.get_children():
			if not ch.is_inside_tree():
				out_of_tree += 1
			dup_names[ch.name] = int(dup_names.get(ch.name, 0)) + 1
		var dups: int = 0
		for k in dup_names:
			if int(dup_names[k]) > 1:
				dups += int(dup_names[k]) - 1
		print("Static: %d children, %d not inside tree after add, %d duplicate names" % [st_node.get_child_count(), out_of_tree, dups])
		# Move them to a fresh container the way the loader does.
		var ents := Node3D.new()
		get_root().add_child(ents)
		var moved := 0
		for ch in st_node.get_children().duplicate():
			st_node.remove_child(ch)
			ents.add_child(ch)
			moved += 1
		var out2 := 0
		for ch in ents.get_children():
			if not ch.is_inside_tree():
				out2 += 1
		print("after moving %d to a new parent: %d not inside tree" % [moved, out2])
		get_root().remove_child(scene_root)
	var bodies := 0
	var shapes := 0
	var empty := 0
	var stack: Array = [scene_root]
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
	print("groups %s" % str(scene_root.get_children()))
	print("bodies %d, shapes %d (%d empty)" % [bodies, shapes, empty])
	scene_root.free()
	quit()
