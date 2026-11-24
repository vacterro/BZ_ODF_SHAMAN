extends SceneTree
## T-214 — receipt trust boundary and discovery drift verifier.
##
## Covers the P0/P1 findings of the 2026-11-23 night-shift handoff:
##   NFR-01..14  a partial/stale receipt can never finalize a full cleanup,
##               and a receipt never substitutes for the actual inventory.
##   NDS-01..06  discovery distinguishes full, partial and unclassified stage
##               states and never hides an unresolved stage.
##
## Real NativeExperimentRunner / SafeStageManager methods, isolated workspace
## bytes, disposable native stages. No real BZCC or Workshop path is touched.
##
##   Godot --headless --path . --script res://tests/verify_t214_receipt_trust.gd

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


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()


func _reset() -> void:
	SafeStageScript.clear_registered_bases()
	NativeAdapterScript.clear_trusted_sessions()
	OdfDocument.clear_all_cache()


## Stage, ledger record, intent and session object all owned by `sid`.
## `opts` keys: files, extra_files, remove_manifest, receipt, receipt_raw,
## ledger_state, ledger_cleanup, intent_state.
func _prep_evidence(ws: String, sid: String, opts: Dictionary = {}) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_T214_")
	var stage_id := sid + "_stage"
	var files: Dictionary = opts.get("files", {"owned.odf": ("OWNED_" + sid).to_utf8_buffer()})
	SafeStageScript.stage(stage, files, {}, false, [], {"stage_id": stage_id})
	_write(stage.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "session_id": sid, "status": "COMPLETE", "stage_id": stage_id,
	}))
	var extra: Dictionary = opts.get("extra_files", {})
	for rel in extra.keys():
		_write(stage.path_join(str(rel)), str(extra[rel]))
	var receipt_path := stage.path_join("stage_cleanup_receipt.json")
	if opts.has("receipt_raw"):
		_write(receipt_path, str(opts["receipt_raw"]))
	elif opts.has("receipt"):
		_save_journal(receipt_path, opts["receipt"])
	if bool(opts.get("remove_manifest", true)):
		DirAccess.remove_absolute(stage.path_join(SafeStageScript.MANIFEST_NAME))
	var ledger_state := str(opts.get("ledger_state", "CLEANUP_FINALIZATION_PENDING"))
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var rec := {"session_id": sid, "state": ledger_state, "stage_id": stage_id,
		"stage_root": stage, "session": {"stage_id": stage_id, "stage_root": stage}}
	if opts.has("ledger_cleanup"):
		rec["cleanup"] = opts["ledger_cleanup"]
	_save_journal(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: rec}})
	var intent_path := ledger_dir.path_join(sid + ".cleanup_intent.json")
	_save_journal(intent_path, {"schema": 1, "session_id": sid, "stage_root": stage,
		"state": str(opts.get("intent_state", "CLEANUP_FINALIZATION_PENDING"))})
	var sess := NativeSessionScript.new()
	sess.session_id = sid
	sess.stage_root = stage
	sess.stage_id = stage_id
	var runner = NativeRunnerScript.new()
	runner.sessions[sid] = {"state": ledger_state, "session_id": sid, "session": sess.to_dict()}
	return {"runner": runner, "stage": stage, "stage_id": stage_id, "sess": sess,
		"intent_path": intent_path, "ledger_dir": ledger_dir}


## The real reproduction path: SafeStageManager removes the owned file, keeps
## the foreign file, writes its own partial receipt, then the final durable
## intent write is lost and the manifest disappears.
func _prep_partial_e2e(ws: String, sid: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_T214_")
	var stage_id := sid + "_stage"
	SafeStageScript.stage(stage, {"owned.odf": ("OWNED_" + sid).to_utf8_buffer()}, {}, false, [], {"stage_id": stage_id})
	_write(stage.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "session_id": sid, "status": "COMPLETE", "stage_id": stage_id,
	}))
	_write(stage.path_join("foreign_user_file.txt"), "FOREIGN_" + sid)
	var cl: Dictionary = SafeStageScript.cleanup(stage, [])
	var ledger_dir := NativeRunnerScript.ledger_dir()
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	_save_journal(ledger_dir.path_join("session_ledger.json"), {"sessions": {sid: {
		"session_id": sid, "state": "CLEANUP_FINALIZATION_PENDING",
		"stage_id": stage_id, "stage_root": stage,
		"cleanup": cl, "session": {"stage_id": stage_id, "stage_root": stage},
	}}})
	var intent_path := ledger_dir.path_join(sid + ".cleanup_intent.json")
	_save_journal(intent_path, {"schema": 1, "session_id": sid, "stage_root": stage,
		"state": "CLEANUP_FINALIZATION_PENDING"})
	DirAccess.remove_absolute(stage.path_join(SafeStageScript.MANIFEST_NAME))
	var sess := NativeSessionScript.new()
	sess.session_id = sid
	sess.stage_root = stage
	sess.stage_id = stage_id
	var runner = NativeRunnerScript.new()
	runner.sessions[sid] = {"state": "CLEANUP_FINALIZATION_PENDING", "session_id": sid,
		"session": sess.to_dict()}
	return {"runner": runner, "stage": stage, "cleanup": cl, "intent_path": intent_path}


## A receipt as SafeStageManager writes it, bound to one session and stage.
func _bound_receipt(c: Dictionary, sid: String, status: String, extra: Dictionary = {}) -> Dictionary:
	var r := {"schema": 1, "status": status, "session_id": sid,
		"stage_id": str(c["stage_id"]), "stage_root": str(c["stage"]),
		"removed_files": [{"rel": "owned.odf", "status": "REMOVED", "md5": "x"}],
		"foreign_files_preserved": [], "stage_directory_retained": true}
	for k in extra.keys():
		r[k] = extra[k]
	return r


func _test_partial_cannot_finalize(tmp: String) -> void:
	print("\n-- NFR-01..07: partial receipt cannot authorize full finalization --")
	var c := _prep_partial_e2e(tmp.path_join("nfr"), "nfr_partial")
	var stage := str(c["stage"])
	var cl: Dictionary = c["cleanup"]
	_check(str(cl.get("status", "")) == "FOREIGN_FILES_PRESERVED" and bool(cl.get("partial", false)),
		"NFR-01 setup: real cleanup keeps the partial outcome for a foreign file")
	var receipt := _journal(stage.path_join("stage_cleanup_receipt.json"))
	_check(str(receipt.get("status", "")) == "OWNED_FILES_REMOVED_FOREIGN_FILES_PRESERVED",
		"NFR-02: receipt records FOREIGN_FILES_PRESERVED, never an unqualified removal")
	_check(not FileAccess.file_exists(stage.path_join("owned.odf")),
		"NFR-01 setup: owned file was removed by the partial cleanup")
	var foreign_before := _bytes(stage.path_join("foreign_user_file.txt"))
	var r: Dictionary = c["runner"].cleanup_stage_terminal("nfr_partial")
	_check(not bool(r.get("ok", false)), "NFR-01: partial receipt cannot finalize FULL cleanup")
	_check(r.has("durable_complete") and not bool(r.get("durable_complete", true)),
		"NFR-01: refusal reports durable_complete=false")
	var intent_after := _journal(str(c["intent_path"]))
	_check(str(intent_after.get("state", "")) != "CLEANUP_COMPLETE",
		"NFR-02: intent is never promoted to CLEANUP_COMPLETE")
	_check(DirAccess.dir_exists_absolute(stage) and FileAccess.file_exists(stage.path_join("foreign_user_file.txt")),
		"NFR-03: manifest missing + partial receipt keeps stage and foreign file")
	_check("CLEANUP_PARTIAL" in str(r.get("reason", "")) or "PARTIAL" in str(r.get("reason", "")),
		"NFR-03: refusal names the partial cleanup evidence")
	_check(_bytes(stage.path_join("foreign_user_file.txt")) == foreign_before,
		"NFR-06: foreign file bytes unchanged")
	var r2: Dictionary = c["runner"].cleanup_stage_terminal("nfr_partial")
	_check(not bool(r2.get("ok", false)) and _bytes(stage.path_join("foreign_user_file.txt")) == foreign_before,
		"NFR-07: retry is idempotent and non-destructive")
	_reset()


func _evidence(c: Dictionary, sid: String) -> Dictionary:
	return c["runner"]._finalization_evidence(sid, c["sess"])


func _test_receipt_matrix(tmp: String) -> void:
	print("\n-- NFR-04..05, NFR-08..14: receipt must agree with the filesystem --")
	var ok_ledger := {"ok": true, "partial": false}
	var partial_ledger := {"ok": true, "partial": true}

	# NFR-04 / NFR-14: valid full-cleanup evidence finalizes.
	var c1 := _prep_evidence(tmp.path_join("nfr04"), "nfr04", {
		"files": {}, "ledger_cleanup": ok_ledger,
	})
	_save_journal(str(c1["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c1, "nfr04", "OWNED_FILES_REMOVED"))
	var e1 := _evidence(c1, "nfr04")
	_check(bool(e1.get("ok", false)) and int(e1.get("remaining_owned_files", -1)) == 0,
		"NFR-04: full receipt + clean inventory + durable ok result finalizes")
	_check(str(e1.get("receipt_class", "")) == NativeRunnerScript.RECEIPT_FULL_CLEANUP,
		"NFR-14: receipt is classified as a full cleanup")
	_reset()

	# NFR-08: a receipt cannot hide an owned file that still exists.
	var c2 := _prep_evidence(tmp.path_join("nfr08"), "nfr08", {
		"ledger_cleanup": ok_ledger,
	})
	_save_journal(str(c2["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c2, "nfr08", "OWNED_FILES_REMOVED", {"removed_files": []}))
	var e2 := _evidence(c2, "nfr08")
	_check(not bool(e2.get("ok", true)) and str(e2.get("reason", "")) == "CLEANUP_FILES_REMAIN",
		"NFR-08: receipt exists but owned file remains -> REFUSED")
	_check(FileAccess.file_exists(str(c2["stage"]).path_join("owned.odf")),
		"NFR-08: refusal preserves the owned bytes")
	_reset()

	# NFR-09: a file that reappeared after the recorded removal is drift.
	var c3 := _prep_evidence(tmp.path_join("nfr09"), "nfr09", {
		"ledger_cleanup": ok_ledger,
	})
	_write(str(c3["stage"]).path_join("owned.odf"), "OWNED_AGAIN")
	_save_journal(str(c3["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c3, "nfr09", "OWNED_FILES_REMOVED"))
	var e3 := _evidence(c3, "nfr09")
	_check(not bool(e3.get("ok", true)) and str(e3.get("reason", "")) == "CLEANUP_STATE_DRIFT",
		"NFR-09: removed file reappeared -> STATE_DRIFT")
	_reset()

	# NFR-10: unknown payload in a stage with a full receipt blocks completion.
	var c4 := _prep_evidence(tmp.path_join("nfr10"), "nfr10", {
		"files": {}, "ledger_cleanup": ok_ledger,
		"extra_files": {"unknown_user_file.txt": "PRECIOUS"},
	})
	_save_journal(str(c4["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c4, "nfr10", "OWNED_FILES_REMOVED"))
	var e4 := _evidence(c4, "nfr10")
	_check(not bool(e4.get("ok", true)) and str(e4.get("reason", "")) == "CLEANUP_FILES_REMAIN",
		"NFR-10: full receipt + unknown file -> no unqualified full cleanup")
	_check(FileAccess.file_exists(str(c4["stage"]).path_join("unknown_user_file.txt")),
		"NFR-10: unknown file preserved")
	_reset()

	# NFR-11: a receipt bound to another stage proves nothing here.
	var c5 := _prep_evidence(tmp.path_join("nfr11"), "nfr11", {"ledger_cleanup": ok_ledger})
	_save_journal(str(c5["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c5, "nfr11", "OWNED_FILES_REMOVED", {"stage_id": "other_stage"}))
	var e5 := _evidence(c5, "nfr11")
	_check(not bool(e5.get("ok", true)) and str(e5.get("reason", "")) == "CLEANUP_RECEIPT_IDENTITY_MISMATCH",
		"NFR-11: receipt from a different stage -> REFUSED")
	_reset()

	# NFR-12: empty identity fields are not a wildcard.
	var c6 := _prep_evidence(tmp.path_join("nfr12"), "nfr12", {"ledger_cleanup": ok_ledger})
	_save_journal(str(c6["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c6, "nfr12", "OWNED_FILES_REMOVED", {"stage_id": "", "stage_root": ""}))
	var e6 := _evidence(c6, "nfr12")
	_check(not bool(e6.get("ok", true)) and str(e6.get("reason", "")) == "CLEANUP_RECEIPT_IDENTITY_MISMATCH",
		"NFR-12: receipt without stage identity -> REFUSED")
	_reset()

	# NFR-13: an unreadable receipt protects the stage.
	var c7 := _prep_evidence(tmp.path_join("nfr13"), "nfr13", {
		"ledger_cleanup": ok_ledger, "receipt_raw": "{ this is not json",
	})
	var e7 := _evidence(c7, "nfr13")
	_check(not bool(e7.get("ok", true)) and str(e7.get("reason", "")) == "CLEANUP_RECEIPT_CORRUPT",
		"NFR-13: corrupted receipt -> PROTECT")
	_check(FileAccess.file_exists(str(c7["stage"]).path_join("owned.odf")),
		"NFR-13: protected stage keeps its bytes")
	_reset()

	# NFR-05: no cleanup evidence at all is never proof.
	var c8 := _prep_evidence(tmp.path_join("nfr05"), "nfr05", {"remove_manifest": true})
	var e8 := _evidence(c8, "nfr05")
	_check(not bool(e8.get("ok", true)) and str(e8.get("reason", "")) == "FINALIZATION_EVIDENCE_INSUFFICIENT",
		"NFR-05: missing cleanup evidence -> PROTECT")
	_check(FileAccess.file_exists(str(c8["stage"]).path_join("owned.odf")),
		"NFR-05: no destructive promotion")
	_reset()

	# A partial receipt stays partial even when the stage looks clean now.
	var c9 := _prep_evidence(tmp.path_join("nfr02b"), "nfr02b", {
		"files": {}, "ledger_cleanup": partial_ledger,
	})
	_save_journal(str(c9["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c9, "nfr02b", "OWNED_FILES_REMOVED_FOREIGN_FILES_PRESERVED"))
	var e9 := _evidence(c9, "nfr02b")
	_check(not bool(e9.get("ok", true)) and str(e9.get("reason", "")) == "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED",
		"NFR-02: partial receipt is never promoted, even on a clean inventory")
	_reset()

	# A full receipt without a durable ok=true/non-partial result is not proof.
	var c10 := _prep_evidence(tmp.path_join("nfr04b"), "nfr04b", {
		"files": {}, "ledger_cleanup": partial_ledger,
	})
	_save_journal(str(c10["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c10, "nfr04b", "OWNED_FILES_REMOVED"))
	var e10 := _evidence(c10, "nfr04b")
	_check(not bool(e10.get("ok", true)) and str(e10.get("reason", "")) == "CLEANUP_RECEIPT_NOT_BACKED_BY_LEDGER",
		"NFR-04: receipt must be backed by a durable full-cleanup result")
	_reset()


func _discover(c: Dictionary, include_completed: bool = false) -> Dictionary:
	for e in (c["runner"].discover_cleanup_intents(include_completed) as Array[Dictionary]):
		if str(e.get("session_id", "")) == str(c["sess"].session_id):
			return e
	return {}


func _test_discovery(tmp: String) -> void:
	print("\n-- NDS-01..06: discovery distinguishes full, partial, unknown --")
	# NDS-01: COMPLETE intent contradicted by a partial receipt.
	var c1 := _prep_evidence(tmp.path_join("nds01"), "nds01", {
		"files": {}, "extra_files": {"foreign.txt": "FOREIGN"},
		"ledger_state": "CLEANED_UP", "ledger_cleanup": {"ok": true, "partial": true},
		"intent_state": "CLEANUP_COMPLETE",
	})
	_save_journal(str(c1["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c1, "nds01", "OWNED_FILES_REMOVED_FOREIGN_FILES_PRESERVED",
			{"foreign_files_preserved": ["foreign.txt"]}))
	var e1 := _discover(c1)
	_check(str(e1.get("resolution", "")) == "CLEANUP_STATE_DRIFT",
		"NDS-01: COMPLETE intent + partial receipt -> STATE_DRIFT")
	_check(bool(e1.get("requires_attention", false)) and "PARTIAL_CLEANUP_EVIDENCE" in (e1.get("drift_reasons", []) as Array),
		"NDS-01: drift names the partial evidence")
	_reset()

	# NDS-02: COMPLETE intent over unclassified stage contents.
	var c2 := _prep_evidence(tmp.path_join("nds02"), "nds02", {
		"extra_files": {"owned.odf": "REAPPEARED"},
		"ledger_state": "CLEANED_UP", "ledger_cleanup": {"ok": true, "partial": false},
		"intent_state": "CLEANUP_COMPLETE",
	})
	var e2 := _discover(c2)
	_check(bool(e2.get("requires_attention", false)) and str(e2.get("resolution", "")) == "CLEANUP_STATE_DRIFT",
		"NDS-02: COMPLETE intent + unclassified files -> attention required")
	_check(not bool(e2.get("verified_complete", true)),
		"NDS-02: unclassified stage is never verified complete")
	_reset()

	# NDS-03: a partial intent with verified foreign files is a correct partial.
	var c3 := _prep_evidence(tmp.path_join("nds03"), "nds03", {
		"files": {}, "extra_files": {"foreign.txt": "FOREIGN"},
		"ledger_state": "PARTIAL_CLEANUP", "ledger_cleanup": {"ok": true, "partial": true},
		"intent_state": "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED",
	})
	_save_journal(str(c3["stage"]).path_join("stage_cleanup_receipt.json"),
		_bound_receipt(c3, "nds03", "OWNED_FILES_REMOVED_FOREIGN_FILES_PRESERVED",
			{"foreign_files_preserved": ["foreign.txt"]}))
	var e3 := _discover(c3)
	_check(str(e3.get("resolution", "")) == "PARTIAL_FOREIGN_FILES_PRESERVED",
		"NDS-03: PARTIAL intent + verified foreign file -> partial status")
	_check(bool(e3.get("requires_attention", false)) and not bool(e3.get("verified_complete", true)),
		"NDS-03: partial is visible, never reported complete")
	_check(FileAccess.file_exists(str(c3["stage"]).path_join("foreign.txt")),
		"NDS-03: foreign file preserved")
	_reset()

	# NDS-04: verified empty stage backed by the durable ledger completes.
	var c4 := _prep_evidence(tmp.path_join("nds04"), "nds04", {
		"files": {}, "ledger_state": "CLEANED_UP",
		"ledger_cleanup": {"ok": true, "partial": false},
		"intent_state": "CLEANUP_COMPLETE",
	})
	var e4 := _discover(c4, true)
	_check(not e4.is_empty() and bool(e4.get("verified_complete", false)) and
		(e4.get("drift_reasons", []) as Array).is_empty(),
		"NDS-04: verified clean stage + durable full cleanup -> complete")
	_reset()

	# NDS-05 / NDS-06: an unresolved stage survives restart without mutation.
	var c5 := _prep_evidence(tmp.path_join("nds05"), "nds05", {
		"files": {}, "extra_files": {"precious.txt": "DO_NOT_TOUCH"},
		"ledger_state": "CLEANED_UP", "ledger_cleanup": {"ok": true, "partial": false},
		"intent_state": "CLEANUP_COMPLETE",
	})
	var before := _bytes(str(c5["stage"]).path_join("precious.txt"))
	var e5 := _discover(c5)
	var fresh = NativeRunnerScript.new()
	var e5b: Dictionary = {}
	for e in (fresh.discover_cleanup_intents() as Array[Dictionary]):
		if str(e.get("session_id", "")) == "nds05":
			e5b = e
	_check(bool(e5.get("requires_attention", false)) and bool(e5b.get("requires_attention", false)),
		"NDS-05: unresolved warning survives a restart discovery pass")
	_check(FileAccess.file_exists(str(c5["stage"]).path_join("precious.txt")) and
		_bytes(str(c5["stage"]).path_join("precious.txt")) == before,
		"NDS-06: startup discovery never deletes retained files")
	_reset()


func _initialize() -> void:
	print("T-214 Receipt Trust & Discovery Drift Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t214_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_partial_cannot_finalize(tmp)
	_test_receipt_matrix(tmp)
	_test_discovery(tmp)
	WorkspaceStore.root_override = old_ws
	WorkspaceStore.fault_phases.clear()
	_remove_tree(tmp)
	_reset()
	print("\nT-214 Receipt Trust: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
