extends SceneTree
## T-128 — RED-first verifier for the unified native cleanup contract.
##
## Real NativeExperimentRunner / SafeStageManager / ParticleLab methods,
## isolated workspace bytes, disposable native stages. No real BZCC or
## Workshop paths are touched.
##
##   Godot --headless --path . --script res://tests/verify_t128_cleanup_contract.gd

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


func _journal(path: String) -> Dictionary:
	var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	return res.get("data", {}) if bool(res.get("ok", false)) else {}


func _save_journal(path: String, data: Dictionary) -> void:
	WorkspaceStore.atomic_write_abs(path, JSON.stringify(data, "  ").to_utf8_buffer())


func _reset() -> void:
	SafeStageScript.clear_registered_bases()
	NativeAdapterScript.clear_trusted_sessions()
	OdfDocument.clear_all_cache()


## A stage, ledger record and PREPARED intent all belonging to `sid`.
func _prep(ws: String, sid: String, intent: Dictionary = {}) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_T128_")
	SafeStageScript.stage(stage, {"owned.odf": ("OWNED_" + sid).to_utf8_buffer()}, {}, false, [],
		{"stage_id": sid + "_stage"})
	_write(stage.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "session_id": sid, "status": "COMPLETE", "stage_id": sid + "_stage",
	}))
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var ledger := ledger_dir.path_join("session_ledger.json")
	var rec := {"session_id": sid, "state": "COMPLETE"}
	if intent.has("ledger_state"):
		rec["state"] = str(intent["ledger_state"])
	if intent.has("ledger_cleanup"):
		rec["cleanup"] = intent["ledger_cleanup"]
	_save_journal(ledger, {"sessions": {sid: rec}})
	var sess := NativeSessionScript.new()
	sess.session_id = sid
	sess.stage_root = stage
	sess.stage_id = sid + "_stage"
	var runner = NativeRunnerScript.new()
	runner.sessions[sid] = {"state": "COMPLETE", "session_id": sid, "session": sess.to_dict()}
	var payload := {"schema": 1, "session_id": sid, "stage_root": stage,
		"state": "CLEANUP_PREPARED"}
	for k in intent.keys():
		if not (k in ["ledger_state", "ledger_cleanup"]):
			payload[k] = intent[k]
	var intent_path := ledger_dir.path_join(sid + ".cleanup_intent.json")
	_save_journal(intent_path, payload)
	return {"runner": runner, "stage": stage, "intent_path": intent_path,
		"ledger": ledger, "ledger_dir": ledger_dir, "session": sess}


## Two independent stages; session A's record is made to point at stage B.
func _prep_cross(ws: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage_a := SafeStageScript.allocate_stage_dir("SHAMAN_OWN_A_")
	var stage_b := SafeStageScript.allocate_stage_dir("SHAMAN_OWN_B_")
	SafeStageScript.stage(stage_a, {"owned.odf": "A_OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "A_stage"})
	SafeStageScript.stage(stage_b, {"owned.odf": "B_OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "B_stage"})
	_write(stage_a.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "session_id": "A", "status": "COMPLETE", "stage_id": "A_stage"}))
	_write(stage_b.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "session_id": "B", "status": "COMPLETE", "stage_id": "B_stage"}))
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	_save_journal(ledger_dir.path_join("session_ledger.json"), {"sessions": {
		"A": {"session_id": "A", "state": "COMPLETE"},
		"B": {"session_id": "B", "state": "COMPLETE"},
	}})
	var sess_a := NativeSessionScript.new()
	sess_a.session_id = "A"
	sess_a.stage_root = stage_b
	sess_a.stage_id = "A_stage"
	var sess_b := NativeSessionScript.new()
	sess_b.session_id = "B"
	sess_b.stage_root = stage_b
	sess_b.stage_id = "B_stage"
	var runner = NativeRunnerScript.new()
	runner.sessions["A"] = {"state": "COMPLETE", "session_id": "A", "session": sess_a.to_dict()}
	runner.sessions["B"] = {"state": "COMPLETE", "session_id": "B", "session": sess_b.to_dict()}
	var intent_path := ledger_dir.path_join("A.cleanup_intent.json")
	_save_journal(intent_path, {"schema": 1, "session_id": "A", "stage_root": stage_b,
		"state": "CLEANUP_PREPARED"})
	return {"runner": runner, "stage_a": stage_a, "stage_b": stage_b,
		"intent_path": intent_path, "ledger_dir": ledger_dir}


## OWN-01..07: a session never cleans another session's stage.
func _test_cross_session_ownership(tmp: String) -> void:
	var c := _prep_cross(tmp.path_join("cross"))
	var runner = c["runner"]
	var stage_a := str(c["stage_a"])
	var stage_b := str(c["stage_b"])
	var r: Dictionary = runner.cleanup_stage("A")
	_check(not bool(r.get("ok", false)),
		"OWN-01: session A pointing at stage B is REFUSED")
	_check(str(r.get("reason", "")).find("OWNER") >= 0 or
		str(r.get("reason", "")).find("IDENTITY") >= 0 or
		str(r.get("reason", "")).find("STAGE") >= 0 or
		str(r.get("reason", "")).find("SESSION") >= 0,
		"OWN-02: refusal names stage ownership/identity")
	_check(FileAccess.file_exists(stage_a.path_join("owned.odf")) and
		FileAccess.file_exists(stage_b.path_join("owned.odf")),
		"OWN-06: refusal preserves both stages")
	var term: Dictionary = runner.cleanup_stage_terminal("A")
	_check(not bool(term.get("ok", false)),
		"OWN-07: terminal retry agrees with normal cleanup gate")
	_check(FileAccess.file_exists(stage_b.path_join("owned.odf")),
		"OWN-06: terminal refusal also preserves stage B")

	var c2 := _prep(tmp.path_join("own_obj"), "own_obj")
	var rec2: Dictionary = c2["runner"].sessions["own_obj"]
	var sess2: Dictionary = rec2["session"]
	sess2["session_id"] = "someone_else"
	rec2["session"] = sess2
	c2["runner"].sessions["own_obj"] = rec2
	var r2: Dictionary = c2["runner"].cleanup_stage("own_obj")
	_check(not bool(r2.get("ok", false)),
		"OWN-03: session object ID differing from requested ID is REFUSED")
	_check(FileAccess.file_exists(str(c2["stage"]).path_join("owned.odf")),
		"OWN-06: identity refusal preserves owned bytes")
	_reset()

	var c3 := _prep(tmp.path_join("own_stage_id"), "own_sid")
	var rec3: Dictionary = c3["runner"].sessions["own_sid"]
	var sess3: Dictionary = rec3["session"]
	sess3["stage_id"] = "wrong_stage_id"
	rec3["session"] = sess3
	c3["runner"].sessions["own_sid"] = rec3
	var r3: Dictionary = c3["runner"].cleanup_stage("own_sid")
	_check(not bool(r3.get("ok", false)),
		"OWN-04: manifest stage ID differing from session stage ID is REFUSED")
	_reset()

	var c4 := _prep_cross(tmp.path_join("cross_valid"))
	var good: Dictionary = c4["runner"].cleanup_stage("B")
	_check(bool(good.get("ok", false)),
		"OWN-05: matching identities remain cleanup eligible")
	_check(not FileAccess.file_exists(str(c4["stage_b"]).path_join("owned.odf")),
		"OWN-05: eligible stage still cleans normally")
	_reset()


## FIN-01..08: missing manifest is never proof of a completed deletion.
func _test_finalization_evidence(tmp: String) -> void:
	var c := _prep(tmp.path_join("fin_remaining"), "fin_remaining", {
		"ledger_state": "CLEANUP_FINALIZATION_PENDING",
		"state": "CLEANUP_FINALIZATION_PENDING",
	})
	DirAccess.remove_absolute(str(c["stage"]).path_join(SafeStageScript.MANIFEST_NAME))
	var r: Dictionary = c["runner"].cleanup_stage_terminal("fin_remaining")
	_check(not bool(r.get("ok", false)),
		"FIN-01: missing manifest with owned file remaining is REFUSED")
	_check(FileAccess.file_exists(str(c["stage"]).path_join("owned.odf")),
		"FIN-01: refused finalization leaves owned bytes")
	_reset()

	var c2 := _prep(tmp.path_join("fin_no_receipt"), "fin_no_receipt", {
		"ledger_state": "CLEANUP_FINALIZATION_PENDING",
		"state": "CLEANUP_FINALIZATION_PENDING",
	})
	DirAccess.remove_absolute(str(c2["stage"]).path_join(SafeStageScript.MANIFEST_NAME))
	DirAccess.remove_absolute(str(c2["stage"]).path_join("owned.odf"))
	var r2: Dictionary = c2["runner"].cleanup_stage_terminal("fin_no_receipt")
	_check(not bool(r2.get("ok", false)),
		"FIN-02: empty stage without cleanup receipt is REFUSED")
	_reset()

	var c3 := _prep(tmp.path_join("fin_failed"), "fin_failed", {
		"ledger_state": "CLEANUP_FINALIZATION_PENDING",
		"state": "CLEANUP_FINALIZATION_PENDING",
		"ledger_cleanup": {"ok": false, "partial": false},
	})
	DirAccess.remove_absolute(str(c3["stage"]).path_join(SafeStageScript.MANIFEST_NAME))
	DirAccess.remove_absolute(str(c3["stage"]).path_join("owned.odf"))
	var r3: Dictionary = c3["runner"].cleanup_stage_terminal("fin_failed")
	_check(not bool(r3.get("ok", false)),
		"FIN-03: prior cleanup ok=false cannot finalize COMPLETE")
	_reset()

	var c4 := _prep(tmp.path_join("fin_partial"), "fin_partial", {
		"ledger_state": "CLEANUP_FINALIZATION_PENDING",
		"state": "CLEANUP_FINALIZATION_PENDING",
		"ledger_cleanup": {"ok": true, "partial": true},
	})
	DirAccess.remove_absolute(str(c4["stage"]).path_join(SafeStageScript.MANIFEST_NAME))
	var r4: Dictionary = c4["runner"].cleanup_stage_terminal("fin_partial")
	_check(not bool(r4.get("ok", false)),
		"FIN-04: prior partial cleanup is not promoted to COMPLETE")
	_check(FileAccess.file_exists(str(c4["stage"]).path_join("owned.odf")),
		"FIN-04: partial outcome preserved")
	_reset()

	var c5 := _prep(tmp.path_join("fin_ok"), "fin_ok", {
		"ledger_state": "CLEANUP_FINALIZATION_PENDING",
		"state": "CLEANUP_FINALIZATION_PENDING",
		"ledger_cleanup": {"ok": true, "partial": false},
	})
	var stage5 := str(c5["stage"])
	DirAccess.remove_absolute(stage5.path_join(SafeStageScript.MANIFEST_NAME))
	DirAccess.remove_absolute(stage5.path_join("owned.odf"))
	var r5: Dictionary = c5["runner"].cleanup_stage_terminal("fin_ok")
	_check(bool(r5.get("ok", false)),
		"FIN-05: verified fully cleaned stage finalizes")
	_check(str(_journal(str(c5["intent_path"])).get("state", "")) == "CLEANUP_COMPLETE",
		"FIN-05: final intent reaches CLEANUP_COMPLETE")
	_reset()

	var c6 := _prep(tmp.path_join("fin_restart"), "fin_restart", {
		"ledger_state": "CLEANUP_FINALIZATION_PENDING",
		"state": "CLEANUP_FINALIZATION_PENDING",
	})
	DirAccess.remove_absolute(str(c6["stage"]).path_join(SafeStageScript.MANIFEST_NAME))
	DirAccess.remove_absolute(str(c6["stage"]).path_join("owned.odf"))
	var fresh = NativeRunnerScript.new()
	var entries: Array[Dictionary] = fresh.discover_cleanup_intents()
	var found: Dictionary = {}
	for e in entries:
		if str(e.get("session_id", "")) == "fin_restart":
			found = e
	_check(not found.is_empty() and bool(found.get("requires_attention", false)),
		"FIN-07: unresolved state survives restart and needs attention")
	_reset()


## DISC-01..12: discovery checks the specific cleanup claim, not terminality.
func _prep_discovery(tmp: String, sid: String, intent_state: String,
		ledger_state: String, mode: String) -> Dictionary:
	var ws := tmp.path_join("disc_" + sid)
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	_save_journal(ledger_dir.path_join("session_ledger.json"), {"sessions": {
		sid: {"session_id": sid, "state": ledger_state},
	}})
	var stage := ws.path_join("native_staging").path_join("SHAMAN_" + sid)
	DirAccess.make_dir_recursive_absolute(stage)
	if mode == "owned":
		SafeStageScript.register_owned_base(stage.get_base_dir())
		SafeStageScript.stage(stage, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
			{"stage_id": sid + "_stage"})
	elif mode == "receipt":
		_write(stage.path_join("foreign.txt"), "FOREIGN")
		_save_journal(stage.path_join("stage_cleanup_receipt.json"), {
			"schema": 1, "session_id": sid, "stage_id": sid + "_stage",
			"stage_root": stage, "status": "OWNED_FILES_REMOVED_FOREIGN_FILES_PRESERVED",
			"foreign_files_preserved": ["foreign.txt"],
		})
	elif mode == "receipt_wrong_sid":
		_write(stage.path_join("foreign.txt"), "FOREIGN")
		_save_journal(stage.path_join("stage_cleanup_receipt.json"), {
			"schema": 1, "session_id": "other", "stage_id": sid + "_stage",
			"stage_root": stage, "status": "OWNED_FILES_REMOVED_FOREIGN_FILES_PRESERVED",
			"foreign_files_preserved": ["foreign.txt"],
		})
	elif mode == "clean":
		_remove_tree(stage)
	elif mode == "missing_manifest_file":
		pass
	_save_journal(ledger_dir.path_join(sid + ".cleanup_intent.json"), {
		"schema": 1, "session_id": sid, "stage_root": stage, "state": intent_state,
	})
	return {"runner": NativeRunnerScript.new(), "sid": sid, "stage": stage}


func _discover_entry(c: Dictionary) -> Dictionary:
	for e in (c["runner"].discover_cleanup_intents() as Array[Dictionary]):
		if str(e.get("session_id", "")) == str(c["sid"]):
			return e
	return {}


func _test_discovery_mapping(tmp: String) -> void:
	var c1 := _prep_discovery(tmp, "d1", "CLEANUP_COMPLETE", "PARTIAL_CLEANUP", "owned")
	var e1 := _discover_entry(c1)
	_check(not e1.is_empty() and str(e1.get("resolution", "")) == "CLEANUP_STATE_DRIFT",
		"DISC-01: COMPLETE intent + PARTIAL_CLEANUP ledger -> DRIFT")
	_reset()

	var c2 := _prep_discovery(tmp, "d2", "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED", "CLEANED_UP", "receipt")
	var e2 := _discover_entry(c2)
	_check(not e2.is_empty() and str(e2.get("resolution", "")) == "CLEANUP_STATE_DRIFT",
		"DISC-02: PARTIAL intent + CLEANED_UP ledger -> DRIFT")
	_reset()

	var c3 := _prep_discovery(tmp, "d3", "CLEANUP_COMPLETE", "COMPLETE", "clean")
	var e3 := _discover_entry(c3)
	_check(not e3.is_empty() and str(e3.get("resolution", "")) == "CLEANUP_STATE_DRIFT",
		"DISC-03: native COMPLETE ledger is not cleanup proof -> DRIFT")
	_reset()

	var c4 := _prep_discovery(tmp, "d4", "CLEANUP_COMPLETE", "CLEANED_UP", "clean")
	var e4: Dictionary = {}
	for e in (c4["runner"].discover_cleanup_intents(true) as Array[Dictionary]):
		if str(e.get("session_id", "")) == "d4":
			e4 = e
	_check(not e4.is_empty() and bool(e4.get("verified_complete", false)) and
		(e4.get("drift_reasons", []) as Array).is_empty(),
		"DISC-04: COMPLETE intent + CLEANED_UP + clean stage -> verified")
	_reset()

	var c5 := _prep_discovery(tmp, "d5", "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED", "PARTIAL_CLEANUP", "receipt")
	var e5 := _discover_entry(c5)
	_check(not e5.is_empty() and
		str(e5.get("resolution", "")) == "PARTIAL_FOREIGN_FILES_PRESERVED",
		"DISC-05: PARTIAL intent + PARTIAL_CLEANUP + receipt -> partial")
	_check(FileAccess.file_exists(str(c5["stage"]).path_join("foreign.txt")),
		"DISC-12: foreign file preserved")
	_reset()

	var c6 := _prep_discovery(tmp, "d6", "CLEANUP_COMPLETE", "COMPLETED_WHATEVER", "clean")
	var e6 := _discover_entry(c6)
	_check(not e6.is_empty() and bool(e6.get("requires_attention", false)),
		"DISC-06: unknown ledger state -> attention")
	_reset()

	var c8 := _prep_discovery(tmp, "d8", "CLEANUP_COMPLETE", "CLEANED_UP", "missing_manifest_file")
	_write(str(c8["stage"]).path_join("owned.odf"), "OWNED")
	var e8 := _discover_entry(c8)
	_check(not e8.is_empty() and bool(e8.get("requires_attention", false)),
		"DISC-08: missing manifest with a file requires attention")
	_reset()

	var c10 := _prep_discovery(tmp, "d10", "CLEANUP_COMPLETE", "CLEANED_UP", "receipt_wrong_sid")
	var e10 := _discover_entry(c10)
	_check(not e10.is_empty() and bool(e10.get("requires_attention", false)),
		"DISC-10: receipt with wrong session ID requires attention")
	_reset()


## API-01..06: ok means durable completion, not merely removed files.
func _test_api_durability(tmp: String) -> void:
	var c := _prep(tmp.path_join("api"), "api_final")
	var runner = c["runner"]
	runner.set("fault_fail_cleanup_intent_final_write", true)
	var r: Dictionary = runner.cleanup_stage_terminal("api_final")
	_check(not bool(r.get("ok", true)), "API-01: failed final intent write -> ok=false")
	_check(bool(r.get("files_cleanup_ok", false)), "API-02: file cleanup result still reported")
	_check(bool(r.get("recovery_required", false)), "API-03: durable finalization unfinished -> recovery")
	runner.set("fault_fail_cleanup_intent_final_write", false)
	var retry: Dictionary = runner.cleanup_stage_terminal("api_final")
	_check(bool(retry.get("ok", false)), "API-05: retry reaches verified complete")
	_reset()


## INT-01..06: destructive retry demands a complete, matched intent identity.
func _test_intent_identity(tmp: String) -> void:
	var cases := [
		{"session_id": ""}, {"stage_root": ""}, {"schema": 99},
	]
	var i := 1
	for override in cases:
		var sid := "int_%d" % i
		var c := _prep(tmp.path_join(sid), sid, override)
		var r: Dictionary = c["runner"].cleanup_stage_terminal(sid)
		_check(not bool(r.get("ok", false)), "INT-0%d: incomplete intent identity is REFUSED" % i)
		_check(FileAccess.file_exists(str(c["stage"]).path_join("owned.odf")),
			"INT-0%d: refusal preserves owned bytes" % i)
		_reset()
		i += 1
	var c4 := _prep(tmp.path_join("int_valid"), "int_valid")
	var good: Dictionary = c4["runner"].cleanup_stage_terminal("int_valid")
	_check(bool(good.get("ok", false)), "INT-06: fully matched intent is accepted")
	_reset()


## REC-133..137: a supplied token is never rewritten to make it valid.
func _make_lab() -> Node:
	var lab = ParticleLabScript.new()
	root.add_child(lab)
	lab.visible = false
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.setup(ResourceIndexScript.new(), SchemaRegistryScript.new())
	return lab


func _prep_save_group(ws: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var src := ws.path_join("sources/mod_t128/effect.odf")
	_write(src, "[Render]\r\nlifeTime=1.0 ; original\r\n")
	var lab = _make_lab()
	var doc = OdfDocument.load_cached(src)
	doc.set_entry_value(doc.find_entry("Render", "lifeTime"), "1.5")
	WorkspaceStore.save_document_with_rel(doc, "mod_t128/effect.odf")
	OdfDocument.clear_all_cache()
	doc = OdfDocument.load_cached(src)
	doc.set_entry_value(doc.find_entry("Render", "lifeTime"), "9.9")
	lab.doc = doc
	var res: Dictionary = lab.save_with_external_dependencies({"fail_on_path": src})
	return {"lab": lab, "path": src, "gid": str(res.get("group_id", "")),
		"journal": ws.path_join("save_groups").path_join(str(res.get("group_id", "")) + ".json"),
		"override": ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(
			str(WorkspaceStore.entry_for(src).get("rel", ""))))}


func _test_recovery_token(tmp: String) -> void:
	var c := _prep_save_group(tmp.path_join("recover"))
	var group := _journal(str(c["journal"]))
	group["state"] = "PARTIAL_SAVE_RECOVERABLE"
	_save_journal(str(c["journal"]), group)
	var lab = c["lab"]
	var token: Dictionary = lab.build_recovery_confirmation_token(str(c["gid"]), "RECOVER")
	_check(bool(token.get("ok", false)), "REC-135: valid token captured")
	var before := FileAccess.get_file_as_bytes(str(c["override"]))
	var missing := token.duplicate(true)
	missing.erase("group_id")
	var r1: Dictionary = lab.recover_partial_save_group(str(c["gid"]), {"confirmation_token": missing})
	_check(not bool(r1.get("ok", false)), "REC-133: provided token lacking group_id is REFUSED")
	var empty := token.duplicate(true)
	empty["group_id"] = ""
	var r2: Dictionary = lab.recover_partial_save_group(str(c["gid"]), {"confirmation_token": empty})
	_check(not bool(r2.get("ok", false)), "REC-134: empty token group_id is REFUSED")
	_check(FileAccess.get_file_as_bytes(str(c["override"])) == before,
		"REC-137: invalid token performs no mutation")
	var fresh_token: Dictionary = lab.build_recovery_confirmation_token(str(c["gid"]), "RECOVER")
	var good: Dictionary = lab.recover_partial_save_group(str(c["gid"]), {"confirmation_token": fresh_token})
	_check(bool(good.get("ok", false)), "REC-135: valid group ID still accepted")
	lab.queue_free()
	_reset()


func _initialize() -> void:
	print("T-128 Cleanup Contract Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t128_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_cross_session_ownership(tmp)
	_test_finalization_evidence(tmp)
	_test_discovery_mapping(tmp)
	_test_api_durability(tmp)
	_test_intent_identity(tmp)
	_test_recovery_token(tmp)
	WorkspaceStore.root_override = old_ws
	WorkspaceStore.fault_phases.clear()
	_remove_tree(tmp)
	_reset()
	print("\nT-128 Contract: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
