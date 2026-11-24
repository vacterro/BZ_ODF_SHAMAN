extends SceneTree
## T-223 / WAVE B — reserved stage namespace protection.
##
## STAGE-RES-01..10: ordinary staging cannot write into protected backup or
## metadata paths; legitimate staging and replace_with_backup still work.
##
## Run: Godot --headless --path . --script res://tests/verify_t223_reserved_paths.gd

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


func _stage(ws: String, tag: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_RES_")
	SafeStageScript.stage(stage, {"owned.odf": "ORIGINAL".to_utf8_buffer()}, {}, false, [],
		{"stage_id": tag + "_stage"})
	_write(stage.path_join("owned.odf"), "HUMAN_MODIFIED")
	var rb: Dictionary = SafeStageScript.stage(stage,
		{"owned.odf": "REPLACED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": tag + "_stage", "conflict_strategy": "replace_with_backup"})
	return {"stage": stage, "restore": rb, "backups": rb.get("backups", [])}


func _refused(c: Dictionary, rel: String, tag: String) -> bool:
	var result: Dictionary = SafeStageScript.stage(str(c["stage"]), {rel: "INJECTED".to_utf8_buffer()},
		{}, false, [], {"stage_id": tag + "_stage"})
	return not bool(result.get("ok", true))


func _initialize() -> void:
	print("T-223 Reserved stage path verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t223_res_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	var c := _stage(tmp.path_join("res"), "res")
	var stage := str(c["stage"])
	var backups: Array = c["backups"]
	_check(backups.size() == 1 and FileAccess.file_exists(str(backups[0])),
		"STAGE-RES-08 setup: legitimate replace_with_backup created a backup")
	var backup_rel := str(backups[0]).trim_prefix(stage).trim_prefix("/")
	var backup_hash := FileAccess.get_md5(str(backups[0]))

	# STAGE-RES-01: existing protected backup cannot be overwritten.
	_check(_refused(c, backup_rel, "res"), "STAGE-RES-01: overwrite existing backup REFUSED")
	_check(FileAccess.get_md5(str(backups[0])) == backup_hash and
		FileAccess.get_file_as_string(str(backups[0])) == "HUMAN_MODIFIED",
		"STAGE-RES-09: rejected staging leaves backup bytes byte-identical")

	# STAGE-RES-02/03: new and case-varied reserved paths.
	_check(_refused(c, ".shaman_stage_backups/new.bak", "res"),
		"STAGE-RES-02: new file inside backup namespace REFUSED")
	_check(_refused(c, ".SHAMAN_STAGE_BACKUPS/case.bak", "res"),
		"STAGE-RES-03: case-varied reserved path REFUSED")

	# STAGE-RES-04..06: stage metadata paths.
	_check(_refused(c, "stage_manifest.json", "res"),
		"STAGE-RES-04: stage_manifest.json payload REFUSED")
	_check(_refused(c, "native_evidence.json", "res"),
		"STAGE-RES-05: native_evidence.json payload REFUSED")
	_check(_refused(c, "stage_cleanup_receipt.json", "res"),
		"STAGE-RES-06: stage_cleanup_receipt.json payload REFUSED")
	_check(_refused(c, "stage_provenance.json", "res"),
		"STAGE-RES-06: stage_provenance.json payload REFUSED")

	# STAGE-RES-07: normal ODF staging still works.
	var ok: Dictionary = SafeStageScript.stage(stage, {"assets/new.odf": "NORMAL".to_utf8_buffer()},
		{}, false, [], {"stage_id": "res_stage"})
	_check(bool(ok.get("ok", false)) and
		FileAccess.get_file_as_string(stage.path_join("assets/new.odf")) == "NORMAL",
		"STAGE-RES-07: normal ODF staging PASS")

	# STAGE-RES-10: invalid historical manifest enters safe recovery policy.
	_write(stage.path_join("stage_manifest.json"), "{ not json")
	var invalid: Dictionary = SafeStageScript.stage(stage, {"assets/x.odf": "X".to_utf8_buffer()},
		{}, false, [], {"stage_id": "res_stage"})
	_check(not bool(invalid.get("ok", true)) and
		str(invalid.get("reason", "")).find("MANIFEST") >= 0,
		"STAGE-RES-10: invalid historical manifest is refused safely")

	WorkspaceStore.root_override = old_ws
	SafeStageScript.clear_registered_bases()
	_remove_tree(tmp)
	print("\nT-223 Reserved Paths: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
