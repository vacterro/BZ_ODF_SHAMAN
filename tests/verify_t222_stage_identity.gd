extends SceneTree
## T-222 / WAVE B — immutable stage identity at cleanup finalization.
##
## NID-06: durable stage_id differs from in-memory stage_id -> REFUSED.
## NID-07: top-level and nested durable stage identities conflict -> REFUSED.
## NID-08: durable stage_id missing -> PROTECT.
## NID-09: in-memory stage_id missing -> PROTECT.
## NID-10: full identity match -> PASS.
## NID-11: refusal performs no filesystem mutation.
## NID-12: normal and terminal cleanup gates agree.
##
## Run: Godot --headless --path . --script res://tests/verify_t222_stage_identity.gd

const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const NativeSessionScript = preload("res://scripts/native/native_experiment_session.gd")
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


func _make_session(sid: String, stage_root: String, stage_id: String):
	var sess := NativeSessionScript.new()
	sess.session_id = sid
	sess.stage_root = stage_root
	sess.stage_id = stage_id
	return sess


func _record(sid: String, root: String, stage_id: String, nested_id: String = "") -> Dictionary:
	var sess = _make_session(sid, root, stage_id)
	var rec := {"session_id": sid, "state": "CLEANED_UP", "stage_id": stage_id,
		"stage_root": root, "session": sess.to_dict(),
		"cleanup": {"ok": true, "partial": false}}
	if nested_id != "":
		var nested: Dictionary = rec["session"]
		nested["stage_id"] = nested_id
		rec["session"] = nested
	return rec


func _evidence(rec: Dictionary, sid: String, sess) -> Dictionary:
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: rec}})
	var runner = NativeRunnerScript.new()
	runner.sessions[sid] = {"state": "CLEANED_UP", "session_id": sid, "session": sess.to_dict()}
	return runner._finalization_evidence(sid, sess)


func _initialize() -> void:
	print("T-222 Durable stage identity verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t222_id_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	var ws := tmp.path_join("id")
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var sid := "S-100"
	var root := ws.path_join("native_staging").path_join("SHAMAN_stage_A")
	DirAccess.make_dir_recursive_absolute(root)
	_write(root.path_join("owned.odf"), "OWNED")

	# NID-06: same session/root, different immutable stage ID.
	var rec_a := _record(sid, root, "STAGE-A")
	var sess_b = _make_session(sid, root, "STAGE-B")
	var ev6: Dictionary = _evidence(rec_a, sid, sess_b)
	_check(not bool(ev6.get("ok", true)) and
		str(ev6.get("reason", "")) == "PRIOR_CLEANUP_STAGE_ID_MISMATCH",
		"NID-06: durable STAGE-A + in-memory STAGE-B is REFUSED")
	_check(FileAccess.file_exists(root.path_join("owned.odf")),
		"NID-11: refusal leaves the owned file untouched")

	# NID-07: top-level and nested stage IDs conflict.
	var rec_conflict := _record(sid, root, "STAGE-A", "STAGE-C")
	var sess_a = _make_session(sid, root, "STAGE-A")
	var ev7: Dictionary = _evidence(rec_conflict, sid, sess_a)
	_check(not bool(ev7.get("ok", true)) and
		str(ev7.get("reason", "")) == "PRIOR_CLEANUP_STAGE_ID_MISMATCH",
		"NID-07: top-level/nested stage ID conflict is REFUSED")

	# NID-08: durable stage_id missing (both places) -> PROTECT.
	var rec_missing: Dictionary = _record(sid, root, "STAGE-A")
	rec_missing.erase("stage_id")
	var nested: Dictionary = rec_missing["session"]
	nested.erase("stage_id")
	rec_missing["session"] = nested
	var ev8: Dictionary = _evidence(rec_missing, sid, sess_a)
	_check(not bool(ev8.get("ok", true)) and
		str(ev8.get("reason", "")) == "PRIOR_CLEANUP_IDENTITY_INCOMPLETE",
		"NID-08: missing durable stage ID -> PROTECT")

	# NID-09: in-memory stage_id missing -> PROTECT.
	var ev9: Dictionary = _evidence(rec_a, sid, _make_session(sid, root, ""))
	_check(not bool(ev9.get("ok", true)) and
		str(ev9.get("reason", "")) == "PRIOR_CLEANUP_IDENTITY_INCOMPLETE",
		"NID-09: missing in-memory stage ID -> PROTECT")

	# NID-10: exact full identity with clean stage -> PASS.
	DirAccess.remove_absolute(root.path_join("owned.odf"))
	var ev10: Dictionary = _evidence(rec_a, sid, sess_a)
	_check(bool(ev10.get("ok", false)) and str(ev10.get("reason", "")) == "",
		"NID-10: matching session, stage ID and stage root -> PASS")

	# NID-12: the shared authority is what both cleanup entrypoints consult.
	var source := FileAccess.get_file_as_string("res://scripts/native/native_experiment_runner.gd")
	_check(source.contains("func _durable_cleanup_identity(") and
		source.contains("_durable_cleanup_identity(rec, session_id, str(sess.stage_root), str(sess.stage_id))"),
		"NID-12: finalization uses the shared durable-identity authority")
	_check(source.contains("_durable_cleanup_identity(_durable_session_record(sid), sid, stage_root"),
		"NID-12: discovery uses the same durable-identity authority")

	WorkspaceStore.root_override = old_ws
	SafeStageScript.clear_registered_bases()
	_remove_tree(tmp)
	print("\nT-222 Stage Identity: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
