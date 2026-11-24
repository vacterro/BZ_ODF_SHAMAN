extends SceneTree
## T-222 / WAVE C — protected stage backup provenance.
##
## BAK-01..09: real replace_with_backup -> cleanup must report a partial,
## preserve backup bytes and keep ownership metadata.
## BAK-10..15: startup discovery must never call a backup-only stage empty.
##
## Run: Godot --headless --path . --script res://tests/verify_t222_backup_inventory.gd

const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
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
	WorkspaceStore.atomic_write_abs(path, JSON.stringify(data, "  ").to_utf8_buffer())


func _journal(path: String) -> Dictionary:
	var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	return res.get("data", {}) if bool(res.get("ok", false)) else {}


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


func _reset() -> void:
	SafeStageScript.clear_registered_bases()


## Real lifecycle: stage V1, modify an owned file, restage with the supported
## replace_with_backup conflict strategy, then clean the stage.
func _prep_backup_stage(ws: String, sid: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_BAK_")
	var stage_id := sid + "_stage"
	var first: Dictionary = SafeStageScript.stage(stage,
		{"owned.odf": "V1_OWNED".to_utf8_buffer()}, {}, false, [], {"stage_id": stage_id})
	_write(stage.path_join("owned.odf"), "HUMAN_MODIFIED_V1")
	var restage: Dictionary = SafeStageScript.stage(stage,
		{"owned.odf": "V2_OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": stage_id, "conflict_strategy": "replace_with_backup"})
	return {"stage": stage, "stage_id": stage_id, "first": first, "restage": restage}


func _discover(sid: String, stage: String) -> Dictionary:
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	_save(ledger_dir.path_join(sid + ".cleanup_intent.json"), {
		"schema": 1, "session_id": sid, "stage_root": stage, "state": "CLEANUP_COMPLETE",
	})
	for e in (NativeRunnerScript.new().discover_cleanup_intents(true) as Array[Dictionary]):
		if str(e.get("session_id", "")) == sid:
			return e
	return {}


func _test_cleanup_backups(tmp: String) -> void:
	print("\n-- BAK-01..09: replace_with_backup stays visible --")
	var c := _prep_backup_stage(tmp.path_join("bak_cleanup"), "bak_cleanup")
	var stage := str(c["stage"])
	var backups: Array = c["restage"].get("backups", [])
	_check(bool(c["first"].get("ok", false)) and bool(c["restage"].get("ok", false)) and
		backups.size() == 1 and FileAccess.file_exists(str(backups[0])) and
		FileAccess.get_file_as_string(str(backups[0])) == "HUMAN_MODIFIED_V1",
		"BAK-01/02/09: real replace_with_backup stores the prior owned bytes")
	var backup_path := str(backups[0])
	var backup_bytes := FileAccess.get_file_as_bytes(backup_path)
	var cl: Dictionary = SafeStageScript.cleanup(stage, [])
	_check(FileAccess.file_exists(backup_path) and
		FileAccess.get_file_as_bytes(backup_path) == backup_bytes,
		"BAK-03/07: cleanup preserves backup bytes exactly")
	_check(bool(cl.get("partial", false)) and (str(cl.get("status", "")) == "OWNED_FILES_REMOVED_BACKUPS_PRESERVED" or str(cl.get("status", "")) == "CLEANUP_PARTIAL_BACKUPS_PRESERVED"),
		"BAK-04: cleanup reports retained backups instead of unqualified CLEAN")
	_check(FileAccess.file_exists(stage.path_join(SafeStageScript.MANIFEST_NAME)) and
		FileAccess.file_exists(stage.path_join("stage_provenance.json")),
		"BAK-05: ownership manifest and provenance survive")
	var receipt := _journal(stage.path_join("stage_cleanup_receipt.json"))
	_check(str(receipt.get("status", "")) == "OWNED_FILES_REMOVED_BACKUPS_PRESERVED" and
		(receipt.get("protected_backups_preserved", []) as Array).size() == 1,
		"BAK-05: receipt names the retained backup and stays bound to the stage")
	_check(not FileAccess.file_exists(stage.path_join("owned.odf")),
		"BAK-02: eligible owned file was removed")
	_check(not bool(cl.get("ok", false)) or bool(cl.get("partial", false)),
		"BAK-04: partial result never claims a full cleanup")
	_reset()


func _test_discovery_backups(tmp: String) -> void:
	print("\n-- BAK-10..15: backup-only discovery is never empty --")
	var c := _prep_backup_stage(tmp.path_join("bak_disc"), "bak_disc")
	var stage := str(c["stage"])
	var backup_path := str((c["restage"].get("backups", []) as Array)[0])
	var backup_bytes := FileAccess.get_file_as_bytes(backup_path)
	DirAccess.remove_absolute(stage.path_join("owned.odf"))
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var sid := "bak_disc"
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: {
		"session_id": sid, "state": "CLEANED_UP", "stage_id": c["stage_id"],
		"stage_root": stage, "cleanup": {"ok": true, "partial": false},
		"session": {"stage_id": c["stage_id"], "stage_root": stage},
	}}})
	DirAccess.remove_absolute(stage.path_join(SafeStageScript.MANIFEST_NAME))
	var e := _discover(sid, stage)
	_check(not e.is_empty() and (e.get("backup_files", []) as Array).size() == 1,
		"BAK-10/11: discovery enumerates the retained backup")
	_check(str(e.get("stage_status", "")) != "STAGE_CLEAN_VERIFIED_EMPTY" and
		not bool(e.get("verified_complete", true)) and bool(e.get("requires_attention", true)),
		"BAK-12/13: backup-only stage is not verified empty")
	_check((e.get("unknown_files", []) as Array).is_empty() and
		str(e.get("partial_evidence", "")).find("BACKUP") >= 0 and
		str(e.get("stage_status", "")) == "BACKUPS_PRESERVED",
		"BAK-14: backups remain distinct from normal unknown files")
	_check(FileAccess.file_exists(backup_path) and
		FileAccess.get_file_as_bytes(backup_path) == backup_bytes,
		"BAK-15/07: discovery performs no destructive cleanup")
	_reset()


func _test_empty_backup_dir(tmp: String) -> void:
	print("\n-- BAK-08: empty backup directory is not a partial state --")
	var ws := tmp.path_join("bak_empty")
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_BAKEMPTY_")
	SafeStageScript.stage(stage, {}, {}, false, [], {"stage_id": "bak_empty_stage"})
	DirAccess.make_dir_recursive_absolute(stage.path_join(SafeStageScript.BACKUP_SUBDIR))
	var cl: Dictionary = SafeStageScript.cleanup(stage, [])
	_check(bool(cl.get("ok", false)) and not bool(cl.get("partial", false)),
		"BAK-08: empty backup directory does not create a false partial cleanup")
	_reset()


func _initialize() -> void:
	print("T-222 Protected backup inventory verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t222_bak_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_cleanup_backups(tmp)
	_test_discovery_backups(tmp)
	_test_empty_backup_dir(tmp)
	WorkspaceStore.root_override = old_ws
	SafeStageScript.clear_registered_bases()
	_remove_tree(tmp)
	print("\nT-222 Backup Inventory: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
