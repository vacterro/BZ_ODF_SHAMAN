extends SceneTree
## T-85 multi-file save durability: write-ahead journal, restart discovery,
## byte-identical working artifact and previous-override rollback.

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")

var passed := 0
var failed := 0
var ws_root := ""


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


func _make_lab() -> Node:
	var lab = ParticleLabScript.new()
	root.add_child(lab)
	lab.visible = false
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.setup(ResourceIndex.new(), SchemaRegistry.new())
	return lab


func _initialize() -> void:
	print("T-85 Multi-File Save Recovery Verifier")
	ws_root = ProjectSettings.globalize_path("user://verify_t85_save_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(ws_root)
	WorkspaceStore.root_override = ws_root
	var ext_dir := ws_root.path_join("sources")
	DirAccess.make_dir_recursive_absolute(ext_dir)
	_write(ext_dir.path_join("parent.odf"), "[Root]\r\nlifeTime=1.0\r\n; keep comment\r\n")
	_write(ext_dir.path_join("effect.odf"), "[Render]\r\nlifeTime=1.0\r\n")
	var parent = OdfDocument.load_cached(ext_dir.path_join("parent.odf"))
	var effect = OdfDocument.load_cached(ext_dir.path_join("effect.odf"))
	parent.set_entry_value(parent.find_entry("Root", "lifeTime"), "2.5")
	effect.set_entry_value(effect.find_entry("Render", "lifeTime"), "2.5")
	var parent_working: PackedByteArray = parent.to_bytes()
	var effect_working: PackedByteArray = effect.to_bytes()

	var lab = _make_lab()
	lab.doc = parent
	lab._external_nodes["effect"] = {"path": ext_dir.path_join("effect.odf"), "header": "Render"}
	var res: Dictionary = lab.save_with_external_dependencies({"fail_on_path": ext_dir.path_join("effect.odf")})
	_check(str(res.get("status", "")) == "PARTIAL_SAVE_RECOVERABLE" and (res.get("failed", []) as Array).size() == 1,
		"SAVE-01: partial save reports PARTIAL_SAVE_RECOVERABLE with exact failure")
	var gid := str(res.get("group_id", ""))
	var journal_path := ws_root.path_join("save_groups").path_join(gid + ".json")
	_check(FileAccess.file_exists(journal_path), "SAVE-01: durable PREPARE journal exists before recovery")
	var journal = WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(journal_path))
	_check(bool(journal.get("ok", false)) and str((journal.get("data", {}) as Dictionary).get("state", "")) == "PARTIAL_SAVE_RECOVERABLE",
		"SAVE-03: final journal state is honest, not COMPLETE")
	lab.queue_free()

	# Simulate a fresh process: new ParticleLab has empty last_save_group.
	var lab2 = _make_lab()
	_check(lab2.last_save_group.is_empty(), "SAVE-01 setup: fresh lab has no in-memory save group")
	var pending: Array[Dictionary] = lab2.discover_incomplete_save_groups()
	_check(pending.size() == 1, "SAVE-01/04: restart discovers incomplete save group from disk")
	var rec: Dictionary = lab2.recover_partial_save_group()
	_check(str(rec.get("status", "")) == "RECOVERED", "SAVE-01: restart recovery succeeds")
	var artifacts: Array = rec.get("working_artifacts", [])
	_check(artifacts.size() == 2, "SAVE-06: both pre-save working edits preserved as artifacts")
	var artifact_bytes := FileAccess.get_file_as_bytes(str(artifacts[0]))
	_check(artifact_bytes == parent_working, "SAVE-06/07/08/09: working artifact is byte-exact including BOM/comments/encoding")
	var restored = OdfDocument.load_cached(ext_dir.path_join("parent.odf"))
	_check(restored != null and str(restored.get_value("Root", "lifeTime")) == "1.0",
		"SAVE-01: saved override rolled back to previous value")
	var rj = WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(journal_path))
	_check(str((rj.get("data", {}) as Dictionary).get("state", "")) == "RECOVERED",
		"SAVE-13: recovered journal state persisted")
	lab2.queue_free()

	# SAVE-02: journal write failure must block all document writes.
	WorkspaceStore.fault_phases["after_temp"] = true
	var lab3 = _make_lab()
	lab3.doc = parent
	lab3._external_nodes["effect"] = {"path": ext_dir.path_join("effect.odf"), "header": "Render"}
	var blocked: Dictionary = lab3.save_with_external_dependencies({})
	WorkspaceStore.fault_phases.erase("after_temp")
	_check(str(blocked.get("status", "")) == "RECOVERY_PENDING" and
		str(blocked.get("reason", "")) == "JOURNAL_WRITE_FAILED" and
		(blocked.get("saved", []) as Array).is_empty(),
		"SAVE-02: failed journal write starts no document mutation")
	lab3.queue_free()

	OdfDocument.clear_all_cache()
	_remove_tree(ws_root)
	print("\nT-85 Save Recovery: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
