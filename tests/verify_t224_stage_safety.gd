extends SceneTree
## T-224 / WAVE B-C-D: physical stage path identity and immutable ownership.
##
## Run: Godot --headless --path . --script res://tests/verify_t224_stage_safety.gd

const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")

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


func _save(path: String, data: Dictionary) -> void:
	_write(path, JSON.stringify(data, "  "))


func _read_manifest(stage: String) -> Dictionary:
	var result: Dictionary = SafeStageScript._parse_json_safe(
		FileAccess.get_file_as_string(stage.path_join(SafeStageScript.MANIFEST_NAME)))
	return result.get("data", {}) if bool(result.get("ok", false)) else {}


func _remove_tree(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
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


func _prepare(ws: String, tag: String) -> String:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_T224_%s_%d_" % [tag, OS.get_process_id()])
	var first: Dictionary = SafeStageScript.stage(stage, {"owned.odf": "V1".to_utf8_buffer()},
		{}, false, [], {"stage_id": tag + "-A"})
	_check(bool(first.get("ok", false)), "setup: stage %s created" % tag)
	return stage


func _test_nested_backup(tmp: String) -> void:
	print("\n-- STAGE-224-01..08: nested protected namespaces --")
	var stage := _prepare(tmp.path_join("nested"), "nested")
	var rel := "assets/.shaman_stage_backups/user.odf"
	var target := stage.path_join(rel)
	_write(target, "USER_BYTES")
	var before := FileAccess.get_file_as_bytes(target)
	var refused: Dictionary = SafeStageScript.stage(stage, {rel: "NEW".to_utf8_buffer()},
		{}, false, [], {"stage_id": "nested-A"})
	_check(str(refused.get("reason", "")) == "RESERVED_STAGE_PATH",
		"STAGE-224-02: nested backup path REFUSED")
	_check(FileAccess.get_file_as_bytes(target) == before,
		"STAGE-224-03: nested protected bytes unchanged")
	_check(not bool(SafeStageScript.stage("__unused__", {"assets/effects.odf": "X".to_utf8_buffer()}, {}, true, [], {"stage_id": "probe"}).get("ok", true)),
		"STAGE-224-06: normal nested assets path allowed")
	var exact: Dictionary = SafeStageScript.stage(stage,
		{".shaman_stage_backups": "X".to_utf8_buffer()}, {}, false, [], {"stage_id": "nested-A"})
	_check(str(exact.get("reason", "")) == "RESERVED_STAGE_PATH",
		"STAGE-224-05: exact backup component REFUSED")
	var case_refused: Dictionary = SafeStageScript.stage(stage,
		{"other/.SHAMAN_STAGE_BACKUPS/case.odf": "X".to_utf8_buffer()},
		{}, false, [], {"stage_id": "nested-A"})
	_check(str(case_refused.get("reason", "")) == "RESERVED_STAGE_PATH",
		"STAGE-224-04: case-varied nested backup REFUSED")
	var inspection: Dictionary = SafeStageScript.inspect_stage(stage)
	_check((inspection.get("protected_backups", []) as Array).has(rel),
		"STAGE-224-07: nested protected data remains discoverable")
	var manifest := _read_manifest(stage)
	var has_rel := false
	for entry in (manifest.get("files", []) as Array):
		if str((entry as Dictionary).get("rel", "")) == rel:
			has_rel = true
	_check(not has_rel, "STAGE-224-08: refusal creates no manifest ownership")


func _test_case_identity(tmp: String) -> void:
	print("\n-- STAGE-224-09..15: Windows physical file identity --")
	var stage := _prepare(tmp.path_join("case"), "case")
	var unknown := stage.path_join("Assets/Weapon.odf")
	_write(unknown, "UNKNOWN_ORIGINAL")
	var unknown_alias: Dictionary = SafeStageScript.stage(stage,
		{"assets/weapon.odf": "OVERWRITE".to_utf8_buffer()}, {}, false, [], {"stage_id": "case-A"})
	_check(str(unknown_alias.get("reason", "")) == "UNOWNED_FILE_COLLISION",
		"STAGE-224-09: unknown case alias REFUSED")
	_check(FileAccess.get_file_as_string(unknown) == "UNKNOWN_ORIGINAL",
		"STAGE-224-14: rejected unknown alias preserves original bytes")

	var restage: Dictionary = SafeStageScript.stage(stage,
		{"new_owned.odf": "OWNED_V1".to_utf8_buffer()}, {}, false, [], {"stage_id": "case-A"})
	_check(bool(restage.get("ok", false)), "setup: owned file staged beside unknown file")
	var owned_stage := _prepare(tmp.path_join("case_owned"), "case_owned")
	var owned := owned_stage.path_join("effects/Flash.odf")
	var owned_stage_result: Dictionary = SafeStageScript.stage(owned_stage,
		{"effects/Flash.odf": "OWNED_V1".to_utf8_buffer()}, {}, false, [], {"stage_id": "case_owned-A"})
	_check(bool(owned_stage_result.get("ok", false)), "setup: isolated owned mixed-case path staged")
	_write(owned, "HUMAN_MODIFIED")
	var modified_alias: Dictionary = SafeStageScript.stage(owned_stage,
		{"effects/flash.odf": "REPLACEMENT".to_utf8_buffer()},
		{}, false, [], {"stage_id": "case_owned-A"})
	_check(str(modified_alias.get("reason", "")) == "MODIFIED_OWNED_FILE_CONFLICT" and
		FileAccess.get_file_as_string(owned) == "HUMAN_MODIFIED",
		"STAGE-224-10: owned case alias still enforces hash guard")

	var duplicate: Dictionary = SafeStageScript.stage(owned_stage, {
		"effects/Flash.odf": "A".to_utf8_buffer(),
		"effects/flash.odf": "B".to_utf8_buffer(),
	}, {}, false, [], {"stage_id": "case_owned-A"})
	_check(str(duplicate.get("reason", "")) == "DUPLICATE_TARGET",
		"STAGE-224-11: duplicate incoming physical target REFUSED")

	var stage_b := _prepare(tmp.path_join("manifest"), "manifest")
	var valid: Dictionary = SafeStageScript.stage(stage_b,
		{"assets/normal.odf": "NORMAL".to_utf8_buffer()}, {}, false, [], {"stage_id": "manifest-A"})
	_check(bool(valid.get("ok", false)) and
		FileAccess.get_file_as_string(stage_b.path_join("assets/normal.odf")) == "NORMAL",
		"STAGE-224-13: one valid mixed-case path stages normally")
	var manifest := _read_manifest(stage_b)
	var duplicate_row: Dictionary = manifest.duplicate(true)
	var rows: Array = duplicate_row.get("files", [])
	rows.append((rows[0] as Dictionary).duplicate(true))
	(rows[1] as Dictionary)["rel"] = "assets/NORMAL.odf"
	duplicate_row["files"] = rows
	_save(stage_b.path_join(SafeStageScript.MANIFEST_NAME), duplicate_row)
	var invalid: Dictionary = SafeStageScript.stage(stage_b, {}, {}, false, [],
		{"stage_id": "manifest-A"})
	_check(str(invalid.get("reason", "")) == "INVALID_STAGE_MANIFEST",
		"STAGE-224-12: case-duplicate manifest REFUSED")

	var rollback_stage := _prepare(tmp.path_join("rollback"), "rollback")
	SafeStageScript.stage(rollback_stage, {"new_owned.odf": "OWNED_V1".to_utf8_buffer()},
		{}, false, [], {"stage_id": "rollback-A"})
	var rollback_target := rollback_stage.path_join("effects/Mixed.odf")
	var rollback_setup: Dictionary = SafeStageScript.stage(rollback_stage, {
		"new_owned.odf": "OWNED_V1".to_utf8_buffer(),
		"effects/Mixed.odf": "ROLLBACK_V1".to_utf8_buffer(),
	}, {}, false, [], {"stage_id": "rollback-A"})
	SafeStageScript.fault_fail_rel = "new.fail"
	var rollback: Dictionary = SafeStageScript.stage(rollback_stage, {
		"effects/Mixed.odf": "ROLLBACK_V2".to_utf8_buffer(),
		"new.fail": "NEW".to_utf8_buffer(),
	}, {}, false, [], {"stage_id": "rollback-A"})
	SafeStageScript.fault_fail_rel = ""
	_check(str(rollback.get("status", "")) == "ROLLED_BACK" and
		FileAccess.get_file_as_string(rollback_target) == "ROLLBACK_V1" and
		not FileAccess.file_exists(rollback_stage.path_join("new.fail")),
		"STAGE-224-15: mixed-case rollback restores prior bytes")


func _test_stage_identity(tmp: String) -> void:
	print("\n-- SID-01..07: immutable stage ID during restaging --")
	var stage := _prepare(tmp.path_join("identity"), "identity")
	var original := FileAccess.get_file_as_bytes(stage.path_join("owned.odf"))
	var mismatch: Dictionary = SafeStageScript.stage(stage,
		{"owned.odf": "V2".to_utf8_buffer()}, {}, false, [], {"stage_id": "identity-B"})
	_check(str(mismatch.get("reason", "")) == "STAGE_IDENTITY_MISMATCH",
		"SID-02: restage with a different stage ID REFUSED")
	_check(str(_read_manifest(stage).get("stage_id", "")) == "identity-A",
		"SID-03: manifest stage ID remains A")
	_check(FileAccess.get_file_as_bytes(stage.path_join("owned.odf")) == original,
		"SID-04: refused identity change preserves stage bytes")
	var same: Dictionary = SafeStageScript.stage(stage,
		{"owned.odf": "V2".to_utf8_buffer()}, {}, false, [], {"stage_id": "identity-A"})
	_check(bool(same.get("ok", false)) and str(same.get("stage_id", "")) == "identity-A",
		"SID-05: restage with the same stage ID succeeds")
	var implicit: Dictionary = SafeStageScript.stage(stage,
		{"owned.odf": "V3".to_utf8_buffer()}, {}, false, [], {})
	_check(bool(implicit.get("ok", false)) and str(implicit.get("stage_id", "")) == "identity-A",
		"SID-06: restage without explicit ID preserves A")
	var inspection: Dictionary = SafeStageScript.inspect_stage(stage)
	_check(str(inspection.get("stage_id", "")) == "identity-A",
		"SID-07: cleanup identity remains A after restart")


func _initialize() -> void:
	print("T-224 Physical stage safety verifier (platform=%s)" % OS.get_name())
	var tmp := ProjectSettings.globalize_path("user://verify_t224_stage_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_nested_backup(tmp)
	_test_case_identity(tmp)
	_test_stage_identity(tmp)
	WorkspaceStore.root_override = old_ws
	SafeStageScript.clear_registered_bases()
	_remove_tree(tmp)
	print("\nT-224 Stage Safety: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
