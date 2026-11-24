extends SceneTree
## T-223 / WAVE C — cleanup and finalization agree with retained backups.
##
## BAK-16..21: empty backup directory removed only when verified empty;
## FIN-09..13: backup-only finalization never claims unqualified COMPLETE.
##
## Run: Godot --headless --path . --script res://tests/verify_t223_cleanup_truth.gd

const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")
const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const NativeSessionScript = preload("res://scripts/native/native_experiment_session.gd")

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


func _test_empty_backup_dir(tmp: String) -> void:
	print("\n-- BAK-16..21: empty backup directory cleanup --")
	var ws := tmp.path_join("empty_backup")
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_EMPTY_")
	SafeStageScript.stage(stage, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "empty_stage"})
	var backup_dir := stage.path_join(SafeStageScript.BACKUP_SUBDIR)
	DirAccess.make_dir_recursive_absolute(backup_dir)
	_check(DirAccess.dir_exists_absolute(backup_dir), "BAK-16: empty backup directory present")
	var cl: Dictionary = SafeStageScript.cleanup(stage, [])
	_check(not DirAccess.dir_exists_absolute(backup_dir),
		"BAK-17: authorized cleanup removes verified-empty backup directory")
	_check(not DirAccess.dir_exists_absolute(stage),
		"BAK-18: stage root actually removed")
	_check(str(cl.get("status", "")) == "CLEAN" and not bool(cl.get("partial", false)),
		"BAK-18: CLEAN reflects actual filesystem state")
	SafeStageScript.clear_registered_bases()

	var ws2 := tmp.path_join("nonempty_backup")
	DirAccess.make_dir_recursive_absolute(ws2)
	WorkspaceStore.root_override = ws2
	SafeStageScript.register_owned_base(ws2.path_join("native_staging"))
	var stage2 := SafeStageScript.allocate_stage_dir("SHAMAN_NONEMPTY_")
	SafeStageScript.stage(stage2, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "nonempty_stage"})
	var backup2 := stage2.path_join(SafeStageScript.BACKUP_SUBDIR).path_join("owned.odf.1.bak")
	_write(backup2, "BACKED_UP")
	var backup_bytes_before := FileAccess.get_file_as_bytes(backup2)
	var cl2: Dictionary = SafeStageScript.cleanup(stage2, [])
	_check(bool(cl2.get("partial", false)) and
		(cl2.get("protected_backups", []) as Array).size() == 1 and
		FileAccess.file_exists(backup2) and FileAccess.get_file_as_bytes(backup2) == backup_bytes_before,
		"BAK-20: nonempty backup directory remains protected")
	SafeStageScript.clear_registered_bases()


func _test_finalization(tmp: String) -> void:
	print("\n-- FIN-09..13: backup-only finalization --")
	var ws := tmp.path_join("final_backup")
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_FIN_")
	SafeStageScript.stage(stage, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "fin_stage"})
	DirAccess.remove_absolute(stage.path_join("owned.odf"))
	var backup := stage.path_join(SafeStageScript.BACKUP_SUBDIR).path_join("owned.odf.2.bak")
	_write(backup, "PROTECTED")
	DirAccess.remove_absolute(stage.path_join(SafeStageScript.MANIFEST_NAME))
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var sid := "fin_backup"
	var sess := NativeSessionScript.new()
	sess.session_id = sid
	sess.stage_root = stage
	sess.stage_id = "fin_stage"
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: {
		"session_id": sid, "state": "CLEANED_UP", "stage_id": "fin_stage",
		"stage_root": stage, "cleanup": {"ok": true, "partial": false},
		"session": sess.to_dict(),
	}}})
	var runner = NativeRunnerScript.new()
	var ev: Dictionary = runner._finalization_evidence(sid, sess)
	_check(not bool(ev.get("ok", true)) and
		str(ev.get("reason", "")) == "PROTECTED_BACKUPS_PRESENT",
		"FIN-09: backup-only stage without receipt is NOT VERIFIED COMPLETE")
	_check(FileAccess.file_exists(backup) and FileAccess.get_file_as_string(backup) == "PROTECTED",
		"FIN-13: insufficient evidence performs zero destructive mutation")

	# FIN-10: truly empty stage with valid prior cleanup still passes.
	var stage2 := ws.path_join("native_staging").path_join("SHAMAN_FIN_CLEAN_")
	DirAccess.make_dir_recursive_absolute(stage2)
	# The ledger must describe this exact empty stage; a record bound to the
	# backup-only stage must not authorize a different stage root.
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: {
		"session_id": sid, "state": "CLEANED_UP", "stage_id": "fin_stage",
		"stage_root": stage2, "cleanup": {"ok": true, "partial": false},
		"session": {"session_id": sid, "stage_id": "fin_stage", "stage_root": stage2},
	}}})
	var sess2 := NativeSessionScript.new()
	sess2.session_id = sid
	sess2.stage_root = stage2
	sess2.stage_id = "fin_stage"
	var ev2: Dictionary = runner._finalization_evidence(sid, sess2)
	_check(bool(ev2.get("ok", false)), "FIN-10: verified empty stage with prior cleanup PASS")
	SafeStageScript.clear_registered_bases()


func _initialize() -> void:
	print("T-223 Cleanup truthfulness verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t223_truth_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_empty_backup_dir(tmp)
	_test_finalization(tmp)
	WorkspaceStore.root_override = old_ws
	SafeStageScript.clear_registered_bases()
	_remove_tree(tmp)
	print("\nT-223 Cleanup Truth: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
