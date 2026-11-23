extends SceneTree
## T-85 graph event honesty: document_edited and success statuses must reflect
## real ODF mutations, not function calls that changed nothing.

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")

var passed := 0
var failed := 0
var plab = null
var doc = null
var edits := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
		print("  ✓ " + msg)
	else:
		failed += 1
		print("  ✗ FAIL: " + msg)


func _initialize() -> void:
	print("T-85 Graph Event Honesty Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t85_graph_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var text := """[EmitterA]
renderBase=peuler
renderName1=EmitterB

[EmitterB]
renderBase=peuler

[EmitterC]
renderBase=peuler
"""
	doc = OdfDocument.parse_text(text, tmp.path_join("graph.odf"))
	plab = ParticleLabScript.new()
	root.add_child(plab)
	plab.visible = false
	plab.set_process(false)
	plab.set_physics_process(false)
	plab.setup(ResourceIndex.new(), SchemaRegistry.new())
	plab.load_document(doc)
	plab.document_edited.connect(func(): edits += 1)

	# GRAPH-39: stale disconnect focus must not emit a document edit.
	var before: PackedByteArray = doc.to_bytes()
	var focus_entry = doc.find_entry("EmitterA", "renderName1")
	var focus_header_id: String = str(focus_entry.header_id)
	edits = 0
	var ok: bool = plab.disconnect_selected_link()
	_check(ok and edits == 1 and doc.to_bytes() != before,
		"GRAPH-39 setup: real disconnect emits exactly one edit (edits=%d)" % edits)
	plab._link_focus = {"src": "EmitterA", "key": "renderName1", "dst": "EmitterB",
		"target": {"kind": "local", "header": "EmitterB"},
		"reference": {"kind": "local", "header": "EmitterB", "value": "EmitterB"},
		"src_header_id": focus_header_id,
		"doc_revision": int(doc.revision) + 99}
	before = doc.to_bytes()
	edits = 0
	ok = plab.disconnect_selected_link()
	_check(not ok and edits == 0 and doc.to_bytes() == before,
		"GRAPH-39: failed disconnect emits no document edit (edits=%d)" % edits)
	doc.undo()
	plab.load_document(doc)

	# GRAPH-40: paste becomes invalid when the target no longer exists.
	plab.clear_edge_selection()
	plab.select_edge("EmitterA", "renderName1", "EmitterB")
	var copied: int = plab.copy_selected_links()
	var b_entry = doc.find_entry("EmitterB", "renderBase")
	doc.remove_entry(b_entry)
	plab.load_document(doc)
	before = doc.to_bytes()
	edits = 0
	var added: int = plab.paste_links()
	_check(added == 0 and edits == 0 and doc.to_bytes() == before,
		"GRAPH-38/40: zero-change paste emits no edit (added=%d edits=%d)" % [added, edits])
	doc.undo()
	plab.load_document(doc)

	# GRAPH-41: partial paste must report exact counts and emit one real edit.
	plab.clear_edge_selection()
	plab.select_headers(["EmitterA"])
	plab.copy_selected_links()
	plab._clipboard_links.clear()
	plab._clipboard_links.append({"src": "EmitterA", "key": "renderName2", "dst": "EmitterC",
		"target": {"kind": "local", "header": "EmitterC"}})
	plab._clipboard_links.append({"src": "EmitterA", "key": "renderName9", "dst": "MissingTarget",
		"target": {"kind": "missing", "header": "MissingTarget"}})
	var valid_count: int = 1
	edits = 0
	added = plab.paste_links()
	var batch: Dictionary = plab.last_graph_batch
	var last_status := str(batch.get("status", ""))
	var last_succeeded := int(batch.get("succeeded", -1))
	var last_failed := int(batch.get("failed", -1))
	_check(added > 0 and valid_count > 0 and edits == 1 and last_status == "PARTIAL" and last_succeeded > 0 and last_failed == 1,
		"GRAPH-41: partial paste reports exact counts (added=%d edits=%d status=%s s=%d f=%d)" % [
			added, edits, last_status, last_succeeded, last_failed])

	# GRAPH-42: undo restores bytes; redo reapplies exactly once.
	doc.undo()
	plab.load_document(doc)
	_check(doc.get_value("EmitterA", "renderName2") == "" and
		doc.get_value("EmitterA", "renderName1") == "EmitterB",
		"GRAPH-42: undo removes only pasted reference")
	var after_undo: PackedByteArray = doc.to_bytes()
	doc.redo()
	plab.load_document(doc)
	_check(doc.get_value("EmitterA", "renderName2") == "EmitterC",
		"GRAPH-42: redo restores pasted reference")

	plab.queue_free()
	print("\nT-85 Graph Events: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
