extends SceneTree
## T-221 / WAVE B — native cleanup-evidence trust boundary.
##
## NDS-20..25: a vanished stage is never VERIFIED_COMPLETE without a full,
## durable cleanup result; an unverifiable intent stays discoverable.
## NID-01..05: finalization refuses a durable record bound to another stage
## root, or one missing the identities that authorize the deletion.
##
## Run: Godot --headless --path . --script res://tests/verify_t221_native_identity.gd

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


func _reset() -> void:
	SafeStageScript.clear_registered_bases()
	OdfDocument.clear_all_cache()


## Fixture: an intent pointing at a stage root that was removed from disk.
## `rec` is written verbatim as the durable ledger record for `sid`.
func _missing_stage(ws: String, sid: String, rec: Dictionary,
		intent_root_override: String = "") -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var stage := ws.path_join("native_staging").path_join("SHAMAN_" + sid)
	DirAccess.make_dir_recursive_absolute(stage)
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	if not rec.is_empty():
		_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: rec}})
	var root := intent_root_override if intent_root_override != "" else stage
	_save(ledger_dir.path_join(sid + ".cleanup_intent.json"), {
		"schema": 1, "session_id": sid, "stage_root": root,
		"state": "CLEANUP_COMPLETE",
	})
	_remove_tree(stage)  # stage vanished outside the cleanup lifecycle
	return {"ws": ws, "stage": stage, "ledger_dir": ledger_dir, "runner": NativeRunnerScript.new()}


func _discover(runner, sid: String, include_completed: bool = false) -> Dictionary:
	for e in (runner.discover_cleanup_intents(include_completed) as Array[Dictionary]):
		if str(e.get("session_id", "")) == sid:
			return e
	return {}


func _test_missing_stage_trust(tmp: String) -> void:
	print("\n-- NDS-20..25: missing stage needs verified cleanup --")
	var full := {"ok": true, "partial": false}

	# NDS-20: CLEANED_UP alone, with no cleanup result, is not proof.
	var c1 := _missing_stage(tmp.path_join("nds20"), "nds20", {
		"session_id": "nds20", "state": "CLEANED_UP",
		"stage_id": "nds20_stage", "stage_root": "",
		"session": {"stage_id": "nds20_stage"},
	})
	var e1 := _discover(c1["runner"], "nds20")
	_check(not e1.is_empty() and not bool(e1.get("verified_complete", true)) and
		bool(e1.get("requires_attention", true)),
		"NDS-20: ledger CLEANED_UP without cleanup result is NOT verified")
	_check(str(e1.get("stage_status", "")) == "STAGE_MISSING_UNVERIFIED",
		"NDS-20: unresolved missing stage carries STAGE_MISSING_UNVERIFIED")
	_reset()

	# NDS-21: cleanup.ok=false is not proof.
	var c2 := _missing_stage(tmp.path_join("nds21"), "nds21", {
		"session_id": "nds21", "state": "CLEANED_UP", "stage_id": "nds21_stage",
		"session": {"stage_id": "nds21_stage"},
		"cleanup": {"ok": false, "partial": false},
	})
	var e2 := _discover(c2["runner"], "nds21")
	_check(not bool(e2.get("verified_complete", true)) and
		bool(e2.get("requires_attention", true)),
		"NDS-21: cleanup.ok=false on a missing stage is NOT verified")
	_reset()

	# NDS-22: cleanup.partial=true never becomes VERIFIED_COMPLETE.
	var c3 := _missing_stage(tmp.path_join("nds22"), "nds22", {
		"session_id": "nds22", "state": "CLEANED_UP", "stage_id": "nds22_stage",
		"session": {"stage_id": "nds22_stage"},
		"cleanup": {"ok": true, "partial": true},
	})
	var e3 := _discover(c3["runner"], "nds22")
	_check(not bool(e3.get("verified_complete", true)) and
		bool(e3.get("requires_attention", true)),
		"NDS-22: partial cleanup on a missing stage is NOT VERIFIED_COMPLETE")
	_reset()

	# NDS-23: a valid full cleanup result backs a missing stage.
	var full_stage_root := tmp.path_join("nds23").path_join("native_staging").path_join("SHAMAN_nds23")
	var c4 := _missing_stage(tmp.path_join("nds23"), "nds23", {
		"session_id": "nds23", "state": "CLEANED_UP", "stage_id": "nds23_stage",
		"stage_root": full_stage_root, "session": {"stage_id": "nds23_stage"},
		"cleanup": full,
	})
	var e4 := _discover(c4["runner"], "nds23", true)
	_check(bool(e4.get("verified_complete", false)) and
		(e4.get("drift_reasons", []) as Array).is_empty(),
		"NDS-23: verified full cleanup + missing stage -> VERIFIED_COMPLETE")
	_reset()

	# NDS-24: an empty intent stage root is invalid identity.
	var c5 := _missing_stage(tmp.path_join("nds24"), "nds24", {
		"session_id": "nds24", "state": "CLEANED_UP", "stage_id": "nds24_stage",
		"cleanup": full,
	}, "")
	# overwrite the intent with an empty stage_root
	var ledger_dir := str(c5["ledger_dir"])
	_save(ledger_dir.path_join("nds24.cleanup_intent.json"), {
		"schema": 1, "session_id": "nds24", "stage_root": "",
		"state": "CLEANUP_COMPLETE",
	})
	var e5 := _discover(NativeRunnerScript.new(), "nds24")
	_check(not bool(e5.get("verified_complete", true)) and
		bool(e5.get("requires_attention", true)),
		"NDS-24: empty stage root is INVALID_STAGE_IDENTITY")
	_reset()

	# NDS-25: the unverified intent remains visible on a fresh discovery pass.
	WorkspaceStore.root_override = str(c1["ws"])
	var e6 := _discover(NativeRunnerScript.new(), "nds20")
	_check(not e6.is_empty() and bool(e6.get("requires_attention", true)) and
		not bool(e6.get("verified_complete", true)),
		"NDS-25: unverified intent stays discoverable after restart")
	_reset()


func _test_finalization_identity(tmp: String) -> void:
	print("\n-- NID-01..05: prior cleanup must bind the exact stage root --")
	var full := {"ok": true, "partial": false}
	var sid := "nid_final"

	# Build a real stage with the normal record shape, then mutate the root.
	var ws := tmp.path_join("nid")
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage_a := SafeStageScript.allocate_stage_dir("SHAMAN_NID_A_")
	var stage_b := SafeStageScript.allocate_stage_dir("SHAMAN_NID_B_")
	SafeStageScript.stage(stage_a, {"owned.odf": "A".to_utf8_buffer()}, {}, false, [],
		{"stage_id": sid + "_stage"})
	SafeStageScript.stage(stage_b, {"owned.odf": "B".to_utf8_buffer()}, {}, false, [],
		{"stage_id": sid + "_stage"})
	DirAccess.remove_absolute(stage_a.path_join("owned.odf"))  # stage A is already cleaned
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var sess := NativeSessionScript.new()
	sess.session_id = sid
	sess.stage_root = stage_a
	sess.stage_id = sid + "_stage"
	var rec := {"session_id": sid, "state": "CLEANED_UP", "stage_id": sid + "_stage",
		"stage_root": stage_a, "session": sess.to_dict(), "cleanup": full}
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: rec}})
	var runner = NativeRunnerScript.new()

	# NID-01: durable stage A, in-memory stage B -> refuse.
	var sess_b := NativeSessionScript.new()
	sess_b.session_id = sid
	sess_b.stage_root = stage_b
	sess_b.stage_id = sid + "_stage"
	var ev1: Dictionary = runner._finalization_evidence(sid, sess_b)
	_check(not bool(ev1.get("ok", true)) and
		str(ev1.get("reason", "")) == "PRIOR_CLEANUP_STAGE_ROOT_MISMATCH",
		"NID-01: durable stage A + in-memory stage B is REFUSED")
	_check(FileAccess.file_exists(stage_b.path_join("owned.odf")),
		"NID-05: refusal leaves stage B's own file untouched")

	# NID-02 / NID-03: missing durable stage root or session identity protects.
	var rec2 := rec.duplicate(true)
	rec2.erase("stage_root")
	var sess_rec2: Dictionary = rec2.get("session", {})
	sess_rec2.erase("stage_root")
	rec2["session"] = sess_rec2
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: rec2}})
	var ev2: Dictionary = runner._finalization_evidence(sid, sess)
	_check(not bool(ev2.get("ok", true)) and
		str(ev2.get("reason", "")) == "PRIOR_CLEANUP_IDENTITY_INCOMPLETE",
		"NID-02: durable stage root missing -> PROTECT")

	var rec3 := rec.duplicate(true)
	rec3.erase("session_id")
	var sess_rec3: Dictionary = rec3.get("session", {})
	sess_rec3.erase("session_id")
	rec3["session"] = sess_rec3
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: rec3}})
	var ev3: Dictionary = runner._finalization_evidence(sid, sess)
	_check(not bool(ev3.get("ok", true)) and
		str(ev3.get("reason", "")) == "PRIOR_CLEANUP_IDENTITY_INCOMPLETE",
		"NID-03: durable session identity missing -> PROTECT")

	# NID-04: exact full identity passes. Stage B's own file is never inspected
	# when the durable record binds the request to stage A.
	_save(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: rec}})

	# NID-04 (true match): exact identity with a clean stage A inventory.
	var ev5: Dictionary = runner._finalization_evidence(sid, sess)
	_check(bool(ev5.get("ok", false)) and str(ev5.get("reason", "")) == "",
		"NID-04: matching stage root, stage ID and session ID -> PASS")
	_check(bool(ev5.get("ownership_verified", false)),
		"NID-05: finalization evidence reports verified ownership without mutation")
	_reset()


func _initialize() -> void:
	print("T-221 Native cleanup-evidence & durable identity verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t221_native_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_missing_stage_trust(tmp)
	_test_finalization_identity(tmp)
	WorkspaceStore.root_override = old_ws
	WorkspaceStore.fault_phases.clear()
	_remove_tree(tmp)
	_reset()
	print("\nT-221 Native Identity: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
