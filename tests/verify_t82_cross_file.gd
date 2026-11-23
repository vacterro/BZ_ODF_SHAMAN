extends SceneTree
## T-82/T-84 cross-file reference identity verifier: external file.header must
## stay external through Move, Swap, Replace, Reconnect and occupied-port focus.
## Each mutation is checked against exact ODF bytes and the untouched external file.

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")

var passed := 0
var failed := 0
var plab = null
var doc = null
var ext_dir := ""
var ext_bytes: PackedByteArray = PackedByteArray()


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


func _settle() -> void:
	plab.load_document(doc)


func _value(key: String) -> String:
	return doc.get_value("EmitterA", key, "")


func _check_external_intact(label: String) -> void:
	_check(FileAccess.get_file_as_bytes(ext_dir.path_join("other_effect.odf")) == ext_bytes,
		label + ": external ODF bytes unchanged")


func _initialize() -> void:
	print("T-82 Cross-File Reference Identity Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t82_xref_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	ext_dir = tmp.path_join("ext")
	DirAccess.make_dir_recursive_absolute(ext_dir)
	_write(ext_dir.path_join("other_effect.odf"), "[Render]\nrenderBase=peuler\n")
	ext_bytes = FileAccess.get_file_as_bytes(ext_dir.path_join("other_effect.odf"))

	var text := """[EmitterA]
renderBase=peuler
renderName1=other_effect.Render
renderName2=LocalRender

[EmitterB]
renderBase=peuler

[LocalRender]
renderBase=peuler

[Render]
renderBase=peuler
"""
	doc = OdfDocument.parse_text(text, tmp.path_join("graph.odf"))
	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": ext_dir, "label": "ext", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	plab = ParticleLabScript.new()
	root.add_child(plab)
	plab.visible = false
	plab.set_process(false)
	plab.set_physics_process(false)
	plab.setup(idx, SchemaRegistry.new())
	plab.load_document(doc)

	# XREF-MOVE-01: free move carries the exact file.header value.
	plab.select_edge("EmitterA", "renderName1", "Render")
	var before: PackedByteArray = doc.to_bytes()
	var ok: bool = plab.move_selected_link("renderName3", "free")
	_check(ok and _value("renderName3") == "other_effect.Render" and _value("renderName1") == "",
		"XREF-MOVE-01: free move preserves external file.header (got %s)" % _value("renderName3"))
	_check(doc.to_bytes() != before, "XREF-MOVE-01: move changed real ODF bytes")
	doc.undo()
	_settle()
	_check(_value("renderName1") == "other_effect.Render" and doc.to_bytes() == before,
		"XREF-MOVE-01: undo restores exact external bytes")
	doc.redo()
	_settle()
	_check(_value("renderName3") == "other_effect.Render", "XREF-MOVE-01: redo restores external target")

	# XREF-MOVE-02: local [Render] with the same header must not substitute.
	doc.set_entry_value(doc.find_entry("EmitterA", "renderName3"), "other_effect.Render")
	_settle()
	plab.select_edge("EmitterA", "renderName3", "Render")
	ok = plab.move_selected_link("renderName4", "free")
	_check(ok and _value("renderName4") == "other_effect.Render",
		"XREF-MOVE-02: same-name local header does not replace external (got %s)" % _value("renderName4"))

	# XREF-MOVE-03: swap two exact values, local and external.
	doc.set_entry_value(doc.find_entry("EmitterA", "renderName4"), "other_effect.Render")
	_settle()
	plab.select_edge("EmitterA", "renderName4", "Render")
	ok = plab.move_selected_link("renderName2", "swap")
	_check(ok and _value("renderName2") == "other_effect.Render" and _value("renderName4") == "LocalRender",
		"XREF-MOVE-03: swap exchanges exact values (r2=%s r4=%s)" % [_value("renderName2"), _value("renderName4")])

	# XREF-MOVE-07: swap must validate BOTH exact values. An invalid destination
	# value must never be written back into the source slot.
	doc.set_entry_value(doc.find_entry("EmitterA", "renderName4"), "other_effect.Render")
	doc.set_entry_value(doc.find_entry("EmitterA", "renderName2"), "missing_effect.Unknown")
	_settle()
	var swap_bad_before: PackedByteArray = doc.to_bytes()
	plab.select_edge("EmitterA", "renderName4", "Render")
	ok = plab.move_selected_link("renderName2", "swap")
	_check(not ok and doc.to_bytes() == swap_bad_before and
		_value("renderName4") == "other_effect.Render",
		"XREF-MOVE-07: swap refuses invalid destination and preserves byte-exact ODF")
	doc.set_entry_value(doc.find_entry("EmitterA", "renderName2"), "LocalRender")
	doc.set_entry_value(doc.find_entry("EmitterA", "renderName4"), "LocalRender")
	_settle()

	# XREF-MOVE-04: explicit replace keeps full external value.
	plab.select_edge("EmitterA", "renderName4", "LocalRender")
	ok = plab.move_selected_link("renderName1", "replace")
	_check(ok and _value("renderName1") == "LocalRender" and
		plab._reference_header(_value("renderName4")) == "",
		"XREF-MOVE-04: replace writes exact external value at destination")

	# XREF-REC-01/02: reconnect to an external not yet in graph, while local
	# [Render] exists with the same header name.
	doc.set_entry_value(doc.find_entry("EmitterA", "renderName1"), "EmitterB")
	_settle()
	plab.select_edge("EmitterA", "renderName1", "EmitterB")
	ok = plab.reconnect_selected_link("other_effect.Render")
	_check(ok and _value("renderName1") == "other_effect.Render",
		"XREF-REC-01/02: reconnect keeps external when local header collides (got %s)" % _value("renderName1"))
	_check_external_intact("XREF-REC-02")

	# XREF-REC-03: external -> local is explicit and exact.
	plab.select_edge("EmitterA", "renderName1", "Render")
	ok = plab.reconnect_selected_link("Render")
	_check(ok and _value("renderName1") == "Render",
		"XREF-REC-03: explicit local target is written as local header (got %s)" % _value("renderName1"))

	# XREF-REC-04: local -> external.
	plab.select_edge("EmitterA", "renderName1", "Render")
	ok = plab.reconnect_selected_link("other_effect.Render")
	_check(ok and _value("renderName1") == "other_effect.Render",
		"XREF-REC-04: local -> external writes exact file.header (got %s)" % _value("renderName1"))

	# XREF-REC-05: undo/redo preserve both identities.
	var after_rec: PackedByteArray = doc.to_bytes()
	doc.undo()
	_settle()
	_check(_value("renderName1") == "Render", "XREF-REC-05: undo restores local identity")
	doc.redo()
	_settle()
	_check(doc.to_bytes() == after_rec, "XREF-REC-05: redo restores external identity byte-exactly")

	# GRAPH-32/33: occupied external port focus must survive identity check.
	plab.clear_edge_selection()
	var occupied_value := _value("renderName1")
	plab._on_connection_request(StringName("EmitterA"),
		plab._port_for_key(null, "EmitterA", "renderName1"), StringName("EmitterB"), 0)
	_check(plab._focus_is_current() and str(plab._link_focus.get("key", "")) == "renderName1",
		"GRAPH-32/33: occupied external port remains selected (focus=%s)" % str(plab._link_focus))
	_check(_value("renderName1") == occupied_value,
		"GRAPH-32: occupied external port leaves source byte-exact")

	# XREF-MOVE-06: external source never touched.
	_check_external_intact("XREF-MOVE-06")

	plab.queue_free()
	_remove_tree(tmp)
	print("\nT-82 Cross-File Verifier: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
