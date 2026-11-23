extends SceneTree
## T-123 — one cleanup policy, one recovery confirmation contract.
##
## RED-first verifier: real NativeExperimentRunner / ParticleLab / MainWindow
## methods, isolated workspace bytes, disposable native stages. No real BZCC
## files and no writes into Workshop/game directories.
##
##   Godot --headless --path . --script res://tests/verify_t123_lifecycle_contract.gd

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")
const ResourceIndexScript = preload("res://scripts/core/resource_index.gd")
const SchemaRegistryScript = preload("res://scripts/core/schema_registry.gd")
const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const NativeSessionScript = preload("res://scripts/native/native_experiment_session.gd")
const NativeAdapterScript = preload("res://scripts/native/native_test_adapter.gd")
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
	lab.setup(ResourceIndexScript.new(), SchemaRegistryScript.new())
	return lab


func _journal(path: String) -> Dictionary:
	var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	return res.get("data", {}) if bool(res.get("ok", false)) else {}


func _save_journal(path: String, group: Dictionary) -> void:
	WorkspaceStore.atomic_write_abs(path, JSON.stringify(group, "  ").to_utf8_buffer())


func _prep_save_group(ws: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var src := ws.path_join("sources/mod_t123/effect.odf")
	_write(src, "[Render]\r\nlifeTime=1.0 ; original\r\n")
	var lab = _make_lab()
	var doc = OdfDocument.load_cached(src)
	doc.set_entry_value(doc.find_entry("Render", "lifeTime"), "1.5")
	WorkspaceStore.save_document_with_rel(doc, "mod_t123/effect.odf")
	OdfDocument.clear_all_cache()
	doc = OdfDocument.load_cached(src)
	doc.set_entry_value(doc.find_entry("Render", "lifeTime"), "9.9")
	lab.doc = doc
	var res: Dictionary = lab.save_with_external_dependencies({"fail_on_path": src})
	return {"lab": lab, "path": src, "gid": str(res.get("group_id", "")),
		"journal": ws.path_join("save_groups").path_join(str(res.get("group_id", "")) + ".json"),
		"override": ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(
			str(WorkspaceStore.entry_for(src).get("rel", ""))))}


## Build a disposable, quiescent, manifest-owned stage with a PREPARED intent.
func _prep_native(ws: String, sid: String, intent: Dictionary = {}) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_T123_")
	SafeStageScript.stage(stage, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": sid + "_stage"})
	_write(stage.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "session_id": sid, "status": "COMPLETE", "stage_id": sid + "_stage",
	}))
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var ledger := ledger_dir.path_join("session_ledger.json")
	var sessions := {sid: {"session_id": sid, "state": "COMPLETE"}}
	if intent.has("ledger_state"):
		sessions[sid]["state"] = str(intent["ledger_state"])
	SaveLedger(ledger, sessions)
	var sess := NativeSessionScript.new()
	sess.session_id = sid
	sess.stage_root = stage
	sess.stage_id = sid + "_stage"
	var runner = NativeRunnerScript.new()
	runner.sessions[sid] = {"state": "COMPLETE", "session": sess.to_dict()}
	var intent_payload := {
		"schema": 1, "session_id": sid, "stage_root": stage, "state": "CLEANUP_PREPARED",
	}
	for k in intent.keys():
		if k != "ledger_state":
			intent_payload[k] = intent[k]
	var intent_path := ledger_dir.path_join(sid + ".cleanup_intent.json")
	_save_journal(intent_path, intent_payload)
	return {"runner": runner, "stage": stage, "intent_path": intent_path,
		"ledger": ledger, "ledger_dir": ledger_dir}


func SaveLedger(path: String, sessions: Dictionary) -> void:
	_save_journal(path, {"sessions": sessions})


func _restore_after_refusal(ws: String, sid: String, stage: String, intent_path: String) -> bool:
	return FileAccess.file_exists(stage.path_join("owned.odf")) and \
		FileAccess.file_exists(intent_path) and \
		DirAccess.dir_exists_absolute(ws)


## NC-123..129: every terminal retry passes the same authorization gate.
func _test_terminal_authorization(tmp: String) -> void:
	var base := tmp.path_join("auth")
	var c := _prep_native(base, "t123_auth")
	var runner = c["runner"]
	var stage := str(c["stage"])
	# NC-123: active persisted monitor.
	_write(str(c["ledger_dir"]).path_join("process_monitors.json"), JSON.stringify({
		"monitors": {"t123_auth": {"active": true, "state": "MONITOR_ARMED"}},
	}))
	var r1: Dictionary = runner.cleanup_stage_terminal("t123_auth")
	_check(not bool(r1.get("ok", false)) and str(r1.get("reason", "")) != "",
		"NC-123: PREPARED intent + active monitor -> REFUSED")
	_check(FileAccess.file_exists(stage.path_join("owned.odf")),
		"NC-129: refusal leaves owned stage bytes untouched (active monitor)")
	DirAccess.remove_absolute(str(c["ledger_dir"]).path_join("process_monitors.json"))

	var c2 := _prep_native(tmp.path_join("auth_recovery"), "t123_rec")
	_save_journal(str(c2["ledger"]), {"sessions": {"t123_rec": {
		"session_id": "t123_rec", "state": "RECOVERY_PENDING"}}})
	var r2: Dictionary = c2["runner"].cleanup_stage_terminal("t123_rec")
	_check(not bool(r2.get("ok", false)),
		"NC-124: PREPARED intent + RECOVERY_PENDING session -> REFUSED")
	_check(FileAccess.file_exists(str(c2["stage"]).path_join("owned.odf")),
		"NC-129: refusal leaves owned stage bytes untouched (recovery pending)")

	var c3 := _prep_native(tmp.path_join("auth_mismatch"), "t123_mismatch", {
		"session_id": "t123_other"})
	var r3: Dictionary = c3["runner"].cleanup_stage_terminal("t123_mismatch")
	_check(not bool(r3.get("ok", false)),
		"NC-125: intent session_id mismatch -> REFUSED")
	_check(FileAccess.file_exists(str(c3["stage"]).path_join("owned.odf")),
		"NC-129: refusal leaves owned stage bytes untouched (session mismatch)")

	var c4 := _prep_native(tmp.path_join("auth_root"), "t123_root", {
		"stage_root": tmp.path_join("foreign_stage")})
	var r4: Dictionary = c4["runner"].cleanup_stage_terminal("t123_root")
	_check(not bool(r4.get("ok", false)),
		"NC-126: intent stage_root mismatch -> REFUSED")
	_check(FileAccess.file_exists(str(c4["stage"]).path_join("owned.odf")),
		"NC-129: refusal leaves owned stage bytes untouched (stage root mismatch)")

	var c5 := _prep_native(tmp.path_join("auth_owner"), "t123_owner")
	_write(str(c5["stage"]).path_join("owned.odf"), "TAMPERED")
	var r5: Dictionary = c5["runner"].cleanup_stage_terminal("t123_owner")
	_check(not bool(r5.get("ok", false)),
		"NC-127: changed stage file hash -> REFUSED")
	_check(FileAccess.get_file_as_string(str(c5["stage"]).path_join("owned.odf")) == "TAMPERED",
		"NC-129: refusal preserves modified owned bytes")
	SafeStageScript.clear_registered_bases()
	NativeAdapterScript.clear_trusted_sessions()


## NC-128: a genuinely quiescent prepared stage may still be finalized.
func _test_terminal_valid_retry(tmp: String) -> void:
	var c := _prep_native(tmp.path_join("valid_retry"), "t123_valid")
	var r: Dictionary = c["runner"].cleanup_stage_terminal("t123_valid")
	_check(bool(r.get("ok", false)) and str(r.get("state", "")) == "CLEANED_UP",
		"NC-128: valid quiescent terminal retry is allowed")
	var intent := _journal(str(c["intent_path"]))
	_check(str(intent.get("state", "")) == "CLEANUP_COMPLETE",
		"NC-132: ok=true/partial=false writes CLEANUP_COMPLETE")
	_check(not FileAccess.file_exists(str(c["stage"]).path_join("owned.odf")),
		"NC-132: valid cleanup removed owned files")
	SafeStageScript.clear_registered_bases()
	NativeAdapterScript.clear_trusted_sessions()


## NC-130..135: the durable intent is derived from the whole cleanup result.
func _test_cleanup_outcome_mapping() -> void:
	var runner = NativeRunnerScript.new()
	if not runner.has_method("cleanup_outcome"):
		_check(false, "NC-130..135: shared cleanup outcome classifier exists")
		return
	var fail: Dictionary = runner.cleanup_outcome({"ok": false, "partial": false,
		"status": "NO_STAGE_MANIFEST"})
	_check(str(fail.get("state", "")) == "FAILED" and
		str(fail.get("intent_state", "")) == "CLEANUP_FAILED",
		"NC-130: ok=false/partial=false never becomes CLEANUP_COMPLETE")
	var fail_partial: Dictionary = runner.cleanup_outcome({"ok": false, "partial": true,
		"status": "CLEANUP_EVIDENCE_PENDING"})
	_check(str(fail_partial.get("intent_state", "")).begins_with("CLEANUP_FAILED"),
		"NC-131: ok=false/partial=true stays an explicit failure state")
	var ok: Dictionary = runner.cleanup_outcome({"ok": true, "partial": false,
		"status": "CLEAN"})
	_check(str(ok.get("state", "")) == "CLEANED_UP" and
		str(ok.get("intent_state", "")) == "CLEANUP_COMPLETE",
		"NC-132: ok=true/partial=false -> COMPLETE")
	var partial: Dictionary = runner.cleanup_outcome({"ok": true, "partial": true,
		"status": "FOREIGN_FILES_PRESERVED"})
	_check(str(partial.get("state", "")) == "PARTIAL_CLEANUP" and
		str(partial.get("intent_state", "")) == "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED",
		"NC-133: ok=true/partial=true -> PARTIAL")


## NC-136..140: final intent persistence is a verified part of the contract.
func _test_finalization_write_failure(tmp: String) -> void:
	var c := _prep_native(tmp.path_join("finalization"), "t123_final")
	var runner = c["runner"]
	if not ("fault_fail_cleanup_intent_final_write" in runner):
		_check(false, "NC-136: runner exposes a final intent write fault hook")
		return
	runner.set("fault_fail_cleanup_intent_final_write", true)
	var r: Dictionary = runner.cleanup_stage_terminal("t123_final")
	_check(str(r.get("cleanup_intent", "")) == "CLEANUP_FINALIZATION_PENDING" and
		str(r.get("reason", "")) == "CLEANUP_INTENT_FINALIZATION_UNVERIFIED",
		"NC-138: failed final intent write reports FINALIZATION_PENDING")
	var intent := _journal(str(c["intent_path"]))
	_check(str(intent.get("state", "")) == "CLEANUP_PREPARED",
		"NC-137: old PREPARED intent remains on disk")
	runner.set("fault_fail_cleanup_intent_final_write", false)
	var retry: Dictionary = runner.cleanup_stage_terminal("t123_final")
	_check(str(retry.get("cleanup_intent", "")).begins_with("CLEANUP_COMPLETE"),
		"NC-140: retry finalizes without unsafe repeated deletion")
	SafeStageScript.clear_registered_bases()
	NativeAdapterScript.clear_trusted_sessions()


## NC-141..146: discovery must verify a terminal-looking intent.
func _test_discovery_verification(tmp: String) -> void:
	var ws := tmp.path_join("discovery")
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_T123_D_")
	SafeStageScript.stage(stage, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "d1"})
	var ledger := ledger_dir.path_join("session_ledger.json")
	_save_journal(ledger, {"sessions": {"d1": {"session_id": "d1", "state": "FAILED"}}})
	_save_journal(ledger_dir.path_join("d1.cleanup_intent.json"), {"schema": 1,
		"session_id": "d1", "stage_root": stage, "state": "CLEANUP_COMPLETE"})
	var entries: Array[Dictionary] = NativeRunnerScript.new().discover_cleanup_intents()
	var found: Dictionary = {}
	for e in entries:
		if str(e.get("session_id", "")) == "d1":
			found = e
	_check(not found.is_empty() and bool(found.get("requires_attention", false)) and
		str(found.get("resolution", "")) == "CLEANUP_STATE_DRIFT",
		"NC-141/142: COMPLETE intent with owned files or FAILED ledger -> drift warning")
	SafeStageScript.clear_registered_bases()


## REC-120..127: destructive Recovery Center actions share one revision guard.
func _test_recovery_token(tmp: String) -> void:
	var c := _prep_save_group(tmp.path_join("recover"))
	var group := _journal(str(c["journal"]))
	group["state"] = "PARTIAL_SAVE_RECOVERABLE"
	_save_journal(str(c["journal"]), group)
	var lab = _make_lab()
	var token: Dictionary = lab.build_recovery_confirmation_token(str(c["gid"]), "RECOVER")
	_check(bool(token.get("ok", false)), "REC-120: RECOVER preview captures a token")
	var before := FileAccess.get_file_as_bytes(str(c["override"]))
	var no_token: Dictionary = lab.recover_partial_save_group(str(c["gid"]), {"ui_confirmed": true})
	_check(not bool(no_token.get("ok", false)) and
		str(no_token.get("reason", "")) == "CONFIRMATION_REQUIRED",
		"REC-127: confirmed RECOVER API cannot bypass the preview token guard")
	_check(FileAccess.get_file_as_bytes(str(c["override"])) == before,
		"REC-123: refused RECOVER performs no mutation")
	var keep_token: Dictionary = lab.build_recovery_confirmation_token(str(c["gid"]), "KEEP CURRENT")
	var wrong_action: Dictionary = lab.recover_partial_save_group(str(c["gid"]), {
		"confirmation_token": keep_token})
	_check(not bool(wrong_action.get("ok", false)),
		"REC-129: token bound to its action is refused for another action")
	var settled: Dictionary = lab.recover_partial_save_group(str(c["gid"]), {
		"confirmation_token": token})
	_check(bool(settled.get("ok", false)),
		"REC-126: unchanged journal/files allow recovery with the confirmation token")
	lab.queue_free()
	OdfDocument.clear_all_cache()


## REC-128..132: the token is one coherent snapshot.
func _test_token_identity(tmp: String) -> void:
	var a := _prep_save_group(tmp.path_join("identity"))
	var lab = _make_lab()
	var peer_gid := "t123peer_1"
	var group := _journal(str(a["journal"]))
	group["group_id"] = peer_gid
	_save_journal(ProjectSettings.globalize_path(WorkspaceStore.root().path_join("save_groups")).path_join(peer_gid + ".json"), group)
	var token: Dictionary = lab.build_recovery_confirmation_token(str(a["gid"]), "RECOVER")
	var valid: Dictionary = lab.verify_recovery_confirmation(str(a["gid"]), "RECOVER", token)
	_check(bool(token.get("ok", false)) and bool(valid.get("ok", false)),
		"REC-132: valid unchanged token is accepted")
	var wrong_group: Dictionary = lab.verify_recovery_confirmation(peer_gid, "RECOVER", token)
	_check(not bool(wrong_group.get("ok", false)), "REC-128: wrong group id rejected")
	var wrong_action: Dictionary = lab.verify_recovery_confirmation(str(a["gid"]), "KEEP CURRENT", token)
	_check(not bool(wrong_action.get("ok", false)), "REC-129: wrong action rejected")
	var missing := token.duplicate(true)
	var ids: Array = missing.get("target_source_ids", [])
	if not ids.is_empty():
		ids.remove_at(0)
	missing["target_source_ids"] = ids
	var missing_check: Dictionary = lab.verify_recovery_confirmation(str(a["gid"]), "RECOVER", missing)
	_check(not bool(missing_check.get("ok", false)), "REC-130: missing target identity rejected")
	var extra := token.duplicate(true)
	var extra_ids: Array = extra.get("target_source_ids", [])
	extra_ids.append("not-a-real-target")
	extra["target_source_ids"] = extra_ids
	var extra_check: Dictionary = lab.verify_recovery_confirmation(str(a["gid"]), "RECOVER", extra)
	_check(not bool(extra_check.get("ok", false)), "REC-131: extra target identity rejected")
	lab.queue_free()
	OdfDocument.clear_all_cache()


func _initialize() -> void:
	print("T-123 Lifecycle Contract Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t123_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_terminal_authorization(tmp)
	_test_terminal_valid_retry(tmp)
	_test_cleanup_outcome_mapping()
	_test_finalization_write_failure(tmp)
	_test_discovery_verification(tmp)
	_test_recovery_token(tmp)
	_test_token_identity(tmp)
	WorkspaceStore.root_override = old_ws
	WorkspaceStore.fault_phases.clear()
	_remove_tree(tmp)
	print("\nT-123 Contract: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
