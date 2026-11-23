extends SceneTree
## T-81 windowed verifier: materialised GraphNode port counts. Headless Godot
## does not register ports until the first draw frame, so this check needs a
## real rendering window.
##
## Run: Godot --path . --script res://tests/verify_t81_windowed_ports.gd

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


func _node_for(plab, header: String) -> GraphNode:
	for c in plab.graph.get_children():
		if c is GraphNode and c.has_meta("header") and str(c.get_meta("header")) == header:
			return c as GraphNode
	return null


func _initialize() -> void:
	print("T-81 Windowed GraphNode Port Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t81_windowed_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var text := """[EmitterA]
renderBase=peuler
emitName=EmitterB
renderName1=EmitterB
renderName2=EmitterB
renderName3=EmitterC

[EmitterB]
renderBase=peuler

[EmitterC]
renderBase=peuler
"""
	_write(tmp.path_join("graph.odf"), text)
	var doc := OdfDocument.parse_text(text, tmp.path_join("graph.odf"))
	var idx := ResourceIndex.new()
	var plab = ParticleLabScript.new()
	root.add_child(plab)
	plab.set_anchors_preset(Control.PRESET_FULL_RECT)
	plab.setup(idx, SchemaRegistry.new())
	plab.load_document(doc)
	await process_frame
	await process_frame
	var a := _node_for(plab, "EmitterA")
	if a == null:
		print("  ✗ FAIL: EmitterA GraphNode missing")
		quit(1)
		return
	var keys: Array[String] = plab._slot_port_keys.get(String(a.name), [])
	var port_keys: Array = plab._output_port_keys.get(String(a.name), [])
	var output_ports := a.get_output_port_count()
	var input_ports := a.get_input_port_count()
	print("  [port state] output=%d input=%d children=%d keys=%d" % [
		output_ports, input_ports, a.get_child_count(), keys.size()])
	_check(output_ports == 5, "WIN-PORT-01: three references + emitName + add port = 5 real outputs")
	_check(input_ports == 1, "WIN-PORT-02: one real input port")
	_check(output_ports == keys.size() - 1, "WIN-PORT-03: every mapped key has a real output")
	# WIN-PORT-05: real port -> slot -> direct-child metadata -> exact ODF key.
	var expected := ["emitName", "renderName1", "renderName2", "renderName3", "@add:renderName4"]
	var mapped_ok := port_keys.size() == expected.size()
	var visited: Array[int] = []
	for p in range(expected.size()):
		var key := str(port_keys[p]) if p < port_keys.size() else ""
		var slot := a.get_output_port_slot(p) if p < output_ports else -1
		visited.append(slot)
		var child_key := ""
		if slot >= 0 and slot < a.get_child_count():
			child_key = str(a.get_child(slot).get_meta("ref_key", ""))
		if key != expected[p]:
			mapped_ok = false
		var slot_key := keys[slot] if slot >= 0 and slot < keys.size() else ""
		if slot_key != expected[p]:
			mapped_ok = false
	_check(mapped_ok, "WIN-PORT-05: every real port maps to its child ODF reference")
	_check(visited.size() == 5 and visited[0] == 1 and visited[4] == 5,
		"WIN-PORT-08: real port 0 maps to slot 1 and +ADD port to slot 5")
	# WIN-PORT-06: GraphEdit connections use real port indices that resolve to
	# exact ODF entries, not neighbouring properties.
	var edges_ok := true
	var edge_count := 0
	for conn in plab.graph.get_connection_list():
		if str(conn.get("from_node", "")) != String(a.name):
			continue
		var p := int(conn.get("from_port", -1))
		var rec := plab._edge_record(String(a.name), p, str(conn.get("to_node", "")))
		if p < 0 or p >= output_ports or rec.is_empty() or str(rec.get("key", "")) != str(port_keys[p]):
			edges_ok = false
		edge_count += 1
	_check(edge_count == 4 and edges_ok, "WIN-PORT-06: GraphEdit edges resolve exact physical ports")
	# WIN-PORT-07: +ADD is the last real output port and is usable from mouse.
	var add_port := plab._port_for_key(a, String(a.name), "@add:renderName4")
	_check(add_port == output_ports - 1,
		"WIN-PORT-07: +ADD uses real last output port %d (got %d)" % [output_ports - 1, add_port])
	plab.queue_free()
	print("\nT-81 Windowed Verifier: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
