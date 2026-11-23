extends SceneTree
## T-82 focused verifier: GraphEdit output-port indices, not slot indices, must
## carry exact physical ODF reference identity. Uses get_output_port_slot() and
## direct-child metadata as the oracle. Headless Godot does not materialise ports
## until first draw, so it falls back to the stable output-port convention.
##
## Run: Godot --headless --path . --script res://tests/verify_t81_graph_ports.gd

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")

var passed := 0
var failed := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
		print("  ✓ " + msg)
	else:
		failed += 1
		print("  ✗ FAIL: " + msg)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _remove_tree(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir != null:
		dir.list_dir_begin()
		var n := dir.get_next()
		while n != "":
			if n != "." and n != "..":
				var full := path.path_join(n)
				if dir.current_is_dir():
					_remove_tree(full)
				else:
					DirAccess.remove_absolute(full)
			n = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _node_for(plab, header: String) -> GraphNode:
	for c in plab.graph.get_children():
		if c is GraphNode and c.has_meta("header") and str(c.get_meta("header")) == header:
			return c as GraphNode
	return null


func _port_for(plab, node: GraphNode, key: String) -> int:
	return plab._port_for_key(node, String(node.name), key)


func _edge_from(plab, node_name: String, port: int) -> Array:
	var out: Array = []
	for conn in plab.graph.get_connection_list():
		if str(conn.get("from_node", "")) == node_name and int(conn.get("from_port", -1)) == port:
			out.append(conn)
	return out


func _initialize() -> void:
	print("T-82 GraphEdit Output-Port Identity Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t82_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var ext_dir := tmp.path_join("ext")
	DirAccess.make_dir_recursive_absolute(ext_dir)
	_write(ext_dir.path_join("other_effect.odf"), "[Render]\nrenderBase=peuler\n")

	var text := """[EmitterA]
renderBase=peuler
emitName=EmitterB
renderName1=EmitterB
renderName2=EmitterB
renderName3=other_effect.Render

[EmitterB]
renderBase=peuler

[EmitterC]
renderBase=peuler

[EmitterD]
renderBase=peuler
"""
	var doc := OdfDocument.parse_text(text, tmp.path_join("graph.odf"))
	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": ext_dir, "label": "ext", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	var plab = ParticleLabScript.new()
	root.add_child(plab)
	plab.visible = false
	plab.set_process(false)
	plab.set_physics_process(false)
	plab.setup(idx, SchemaRegistry.new())
	plab.load_document(doc)

	var a := _node_for(plab, "EmitterA")
	_check(a != null, "PORT-00: EmitterA GraphNode exists")
	if a == null:
		return
	var b := _node_for(plab, "EmitterB")
	var keys: Array[String] = plab._slot_port_keys.get(String(a.name), [])
	_check(a.get_child_count() == keys.size(),
		"PORT-04: one direct child Control per slot (%d=%d)" % [a.get_child_count(), keys.size()])
	var direct_ok := true
	for p in range(a.get_child_count()):
		if not (a.get_child(p) is Control):
			direct_ok = false
	_check(direct_ok, "PORT-06: every slot backed by a direct child Control")

	# PORT-11/12: real port -> slot -> child metadata -> ODF key.
	var expected := {
		0: "emitName", 1: "renderName1", 2: "renderName2",
		3: "renderName3", 4: "@add:renderName4",
	}
	var port_count: int = (plab._output_port_keys.get(String(a.name), []) as Array).size()
	_check(port_count == 5, "PORT-11: five real output ports (got %d)" % port_count)
	for p in range(port_count):
		var key := plab._key_for_port(a, String(a.name), p)
		_check(key == str(expected.get(p, "")), "PORT-12: output port %d -> %s (got %s)" % [p, str(expected.get(p, "")), key])
	if port_count == 5 and a.get_output_port_count() > 0:
		for p in range(port_count):
			var slot := a.get_output_port_slot(p)
			var child := a.get_child(slot)
			var key := str(child.get_meta("ref_key", ""))
			var mapped := plab._key_for_port(a, String(a.name), p)
			if key.begins_with("@add:"):
				key = "@add:" + key.substr(5)
			_check(key == mapped, "PORT-16: port %d slot %d child metadata %s (map %s)" % [p, slot, key, mapped])

	# PORT-13: first physical reference is reachable through real output port 0.
	var p_emit := _port_for(plab, a, "emitName")
	var p1 := _port_for(plab, a, "renderName1")
	var p2 := _port_for(plab, a, "renderName2")
	var p3 := _port_for(plab, a, "renderName3")
	_check(p_emit == 0, "PORT-13: emitName uses real output port 0 (got %d)" % p_emit)
	_check(p1 > 0 and p2 > p1 and p3 > p2, "PORT-15: parallel references own distinct ordered ports")

	# PORT-17/18: every connection originates from a valid port and the port's
	# ODF key resolves to the exact physical reference entry.
	var edge_count := 0
	for conn in plab.graph.get_connection_list():
		if str(conn.get("from_node", "")) != String(a.name):
			continue
		var p := int(conn.get("from_port", -1))
		var key := plab._key_for_port(a, String(a.name), p)
		var valid := p >= 0 and p < port_count and key != "" and not key.begins_with("@add:")
		_check(valid, "PORT-17: edge from valid physical port %d (%s)" % [p, key])
		if valid:
			var rec := plab._edge_record(String(a.name), p, str(conn.get("to_node", "")))
			_check(not rec.is_empty() and str(rec.get("key", "")) == key,
				"PORT-18: edge identity resolves to %s" % key)
		edge_count += 1
	_check(edge_count == 4, "PORT-10: four GraphEdit connections from EmitterA (got %d)" % edge_count)

	# HILITE: selecting the second parallel edge highlights only its real port.
	plab.select_edge("EmitterA", "renderName2", "EmitterB")
	var active := []
	for key in plab._connection_activity.keys():
		if float(plab._connection_activity[key]) > 0.5:
			active.append(int(str(key).split(":")[1]))
	_check(active.size() == 1 and active[0] == p2,
		"HILITE-01: only renderName2 port %d highlighted (active=%s)" % [p2, str(active)])

	# DRAG: occupied real port refuses and leaves ODF bytes untouched.
	var before_drag: PackedByteArray = doc.to_bytes()
	plab.clear_edge_selection()
	plab._on_connection_request(StringName(a.name), p1, StringName(b.name), 0)
	_check(doc.to_bytes() == before_drag, "DRAG-01: occupied port drag leaves ODF byte-exact")
	_check(plab._link_focus.get("key", "") == "renderName1", "DRAG-02: occupied port selects its own physical key")

	# DRAG: +ADD is the last real output port and creates the next free key.
	var add_port := _port_for(plab, a, "@add:renderName4")
	_check(add_port == port_count - 1, "DRAG-03: +ADD uses real last output port %d (got %d)" % [port_count - 1, add_port])
	plab._on_connection_request(StringName(a.name), add_port, StringName(b.name), 0)
	_check(doc.get_value("EmitterA", "renderName4") == "EmitterB",
		"DRAG-04: add port created renderName4 intentionally")
	plab.load_document(doc)
	a = _node_for(plab, "EmitterA")
	_check(a != null and a.get_child_count() == (plab._slot_port_keys.get(String(a.name), []) as Array).size(),
		"DRAG-05: rebuilt node slots match its port map")

	# DISC: exact real port disconnects only that physical reference; undo restores.
	var before_disc: PackedByteArray = doc.to_bytes()
	var p4 := _port_for(plab, a, "renderName4")
	plab._on_disconnection_request(StringName(a.name), p4, StringName(b.name), 0)
	_check(doc.find_entry("EmitterA", "renderName4") == null and
		doc.get_value("EmitterA", "renderName1") == "EmitterB",
		"DISC-01: exact port %d disconnect removes only renderName4" % p4)
	_check(doc.can_undo(), "DISC-02: disconnect is undoable")
	doc.undo()
	_check(doc.to_bytes() == before_disc, "DISC-03: undo restores exact ODF bytes")

	# XREF: external file.header edge has exact target identity and can be
	# selected/disconnected by mouse identity, leaving the external file intact.
	var ext_bytes: PackedByteArray = FileAccess.get_file_as_bytes(ext_dir.path_join("other_effect.odf"))
	var ext_conn := _edge_from(plab, String(a.name), p3)
	_check(ext_conn.size() == 1, "XREF-06: external edge originates from renderName3 port %d" % p3)
	var ext_rec := plab._edge_record(String(a.name), p3, str(ext_conn[0].get("to_node", "")))
	_check(not ext_rec.is_empty() and str((ext_rec.get("target", {}) as Dictionary).get("kind", "")) == "external",
		"XREF-11: external edge carries typed external target identity")
	plab._link_focus = ext_rec
	_check(plab._focus_is_current(), "XREF-06: external edge selection survives identity check")
	var before_ext_disc: PackedByteArray = doc.to_bytes()
	plab._on_disconnection_request(StringName(a.name), p3, str(ext_conn[0].get("to_node", "")), 0)
	_check(doc.find_entry("EmitterA", "renderName3") == null and
		doc.get_value("EmitterA", "renderName1") == "EmitterB",
		"XREF-07: external edge disconnect removes only its physical reference")
	doc.undo()
	_check(doc.to_bytes() == before_ext_disc, "XREF-08: external disconnect undo restores byte-exact ODF")
	_check(FileAccess.get_file_as_bytes(ext_dir.path_join("other_effect.odf")) == ext_bytes,
		"XREF-12: external ODF bytes unchanged")

	plab.queue_free()
	_remove_tree(tmp)
	print("\nT-82 Verifier: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
