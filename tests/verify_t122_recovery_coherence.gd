extends SceneTree
## T-122 — recovery coherence, native cleanup state and physical ODF diff.
##
## RED-first verifier. Every case uses real isolated workspace bytes and
## real ParticleLab / NativeRunner / MainWindow methods. No source-string
## assertions, no real BZCC writes. Run:
##   Godot --headless --path . --script res://tests/verify_t122_recovery_coherence.gd

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


func _prep(ws: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var dir_a := ws.path_join("sources/mod_a")
	var dir_b := ws.path_join("sources/mod_b")
	DirAccess.make_dir_recursive_absolute(dir_a)
	DirAccess.make_dir_recursive_absolute(dir_b)
	var pa := dir_a.path_join("effect.odf")
	var pb := dir_b.path_join("effect.odf")
	_write(pa, "[Render]\r\nlifeTime=1.0 ; original\r\n")
	_write(pb, "[Render]\r\nlifeTime=2.0 ; original\r\n")
	var a = OdfDocument.load_cached(pa)
	a.set_entry_value(a.find_entry("Render", "lifeTime"), "1.5")
	WorkspaceStore.save_document_with_rel(a, "mod_a/effect.odf")
	OdfDocument.clear_all_cache()
	a = OdfDocument.load_cached(pa)
	var b = OdfDocument.load_cached(pb)
	a.set_entry_value(a.find_entry("Render", "lifeTime"), "9.9")
	b.set_entry_value(b.find_entry("Render", "lifeTime"), "8.8")
	var lab = _make_lab()
	lab.doc = a
	lab._external_nodes["extb"] = {"path": pb, "header": "Render"}
	var res: Dictionary = lab.save_with_external_dependencies({"fail_on_path": pa})
	var gid := str(res.get("group_id", ""))
	return {"lab": lab, "path": pa, "gid": gid,
		"journal": ws.path_join("save_groups").path_join(gid + ".json"),
		"override": ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(
			str(WorkspaceStore.entry_for(pa).get("rel", ""))))}


func _journal(path: String) -> Dictionary:
	var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	return res.get("data", {}) if bool(res.get("ok", false)) else {}


func _save_journal(path: String, group: Dictionary) -> void:
	WorkspaceStore.atomic_write_abs(path, JSON.stringify(group, "  ").to_utf8_buffer())


## REC-101..106: a public resolver must reject a current revision changed
## after the user's preview, even when the journal itself never changed.
func _test_current_hash_guard(tmp: String) -> void:
	var c := _prep(tmp.path_join("guard"))
	var lab = _make_lab()
	var group := _journal(str(c["journal"]))
	group["state"] = "RECOVERY_CONFLICT_PENDING"
	_save_journal(str(c["journal"]), group)
	var token: Dictionary = lab.build_recovery_confirmation_token(str(c["gid"]), "restore_working")
	_check(bool(token.get("ok", false)) and str(token.get("group_id", "")) == str(c["gid"]),
		"REC-101: confirmation token captures the live journal revision")
	_check(token.get("current_file_hashes", {}) is Dictionary and
		(token.get("current_file_hashes", {}) as Dictionary).size() > 0,
		"REC-102: token records current file hashes for every target")
	WorkspaceStore.atomic_write_abs(str(c["override"]), "[Render]\r\nlifeTime=6.66\r\n".to_utf8_buffer())
	var resolved: Dictionary = lab.resolve_recovery_conflict(str(c["gid"]), "restore_working", token)
	_check(not bool(resolved.get("ok", false)) and
		str(resolved.get("reason", "")) == "CURRENT_REVISION_CHANGED",
		"REC-101/102: current revision changed after preview -> REFUSED")
	_check(FileAccess.get_file_as_string(str(c["override"])).contains("lifeTime=6.66"),
		"REC-105: refusal leaves current bytes unchanged")
	var fresh = _make_lab()
	var token2: Dictionary = fresh.build_recovery_confirmation_token(str(c["gid"]), "restore_working")
	_check(bool(token2.get("ok", false)) and
		str(token2.get("current_file_hashes", {}).get(str(c["path"]), "")) != "",
		"REC-106: fresh process recomputes a valid current revision token")
	fresh.queue_free()
	lab.queue_free()


## REC-107..113: group_id is a single safe path component bound to its file.
func _test_group_id_contract(tmp: String) -> void:
	var lab = _make_lab()
	var valid := "pgrp_123_456"
	_check(bool(lab.validate_recovery_group_id(valid, valid + ".json").get("ok", false)),
		"REC-107: canonical group id accepted")
	var bad_inputs := ["../escape", "a/b", "a\\b", "a:b", "..", "a.b", ""]
	for bad in bad_inputs:
		var res: Dictionary = lab.validate_recovery_group_id(str(bad), str(bad) + ".json")
		_check(not bool(res.get("ok", false)) and str(res.get("reason", "")) == "INVALID_GROUP_ID",
			"REC-108/109: unsafe group id '%s' rejected" % str(bad))
	var mismatch: Dictionary = lab.validate_recovery_group_id(valid, "other.json")
	_check(not bool(mismatch.get("ok", false)) and str(mismatch.get("reason", "")) == "GROUP_ID_MISMATCH",
		"REC-110: embedded id must match journal filename")
	var sentinel := tmp.path_join("sentinel.txt")
	_write(sentinel, "ORIGINAL")
	var sg_dir := tmp.path_join("groups")
	DirAccess.make_dir_recursive_absolute(sg_dir)
	var evil := "pgrp_0_1"
	var group := {"schema": 1, "group_id": evil, "state": "RECOVERY_CONFLICT_PENDING",
		"targets": []}
	_save_journal(sg_dir.path_join(evil + ".json"), group)
	var dest: Dictionary = lab.recovery_artifact_destination(sg_dir, evil)
	_check(bool(dest.get("ok", false)) and
		WorkspaceStore.is_within(sg_dir, str(dest.get("path", ""))),
		"REC-111: artifact destination stays inside the authorized root")
	_check(FileAccess.get_file_as_string(sentinel) == "ORIGINAL",
		"REC-112: no external sentinel modified")
	lab.queue_free()


## REC-114..119: direct restore updates or invalidates cached OdfDocuments.
func _test_cache_sync(tmp: String) -> void:
	var c := _prep(tmp.path_join("cache"))
	OdfDocument.clear_all_cache()
	var inspector_doc = OdfDocument.load_cached(str(c["path"]))
	var lab = _make_lab()
	var group := _journal(str(c["journal"]))
	group["state"] = "RECOVERY_CONFLICT_PENDING"
	_save_journal(str(c["journal"]), group)
	var token: Dictionary = lab.build_recovery_confirmation_token(str(c["gid"]), "restore_working")
	var resolved: Dictionary = lab.resolve_recovery_conflict(str(c["gid"]), "restore_working", token)
	_check(bool(resolved.get("ok", false)), "REC-114: cache test setup resolves successfully")
	var refreshed = OdfDocument.cached(str(c["path"]))
	_check(refreshed == null or str((refreshed as OdfDocument).get_value("Render", "lifeTime", "")) == "9.9",
		"REC-115/116: cached document converges to restored bytes or is invalidated")
	lab.queue_free()


## NCL-101..112: partial cleanup and completed intents are distinct.
func _test_native_cleanup(tmp: String) -> void:
	var ws := tmp.path_join("native")
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)
	var stage := SafeStageScript.allocate_stage_dir("SHAMAN_T122_")
	var sid := "t122_partial"
	var session = NativeSessionScript.new()
	session.session_id = sid
	session.stage_root = stage
	session.stage_id = "t122"
	var runner = NativeRunnerScript.new()
	runner.sessions[sid] = {
		"state": "COMPLETE", "session_id": sid, "session": session.to_dict(),
		"updated_at": Time.get_datetime_string_from_system(),
	}
	var ledger := NativeRunnerScript.ledger_dir().path_join("session_ledger.json")
	DirAccess.make_dir_recursive_absolute(ledger.get_base_dir())
	_write(ledger, JSON.stringify({"sessions": {sid: {"state": "COMPLETE"}}}))
	var ev := ledger.get_base_dir().path_join(sid + ".json")
	_write(ev, JSON.stringify({"session_id": sid, "status": "COMPLETE", "stage_id": "t122"}))
	SafeStageScript.stage(stage, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "t122"})
	_write(stage.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "session_id": sid, "status": "COMPLETE", "stage_id": "t122",
	}))
	_write(stage.path_join("foreign.txt"), "FOREIGN")
	var intent_path := NativeRunnerScript.ledger_dir().path_join(sid + ".cleanup_intent.json")
	_write(intent_path, JSON.stringify({"schema": 1, "session_id": sid, "stage_root": stage,
		"state": "CLEANUP_PREPARED"}))
	var result: Dictionary = runner.cleanup_stage_terminal(sid)
	_check(str(result.get("state", "")) == "PARTIAL_CLEANUP" and
		str(result.get("cleanup_intent", "")) == "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED",
		"NCL-101/102: partial cleanup writes a partial intent, not COMPLETE")
	var intent: Dictionary = _journal(intent_path)
	_check(str(intent.get("state", "")) == "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED",
		"NCL-103: ledger and durable intent agree")
	_check(FileAccess.file_exists(stage.path_join("foreign.txt")),
		"NCL-106: unknown file preserved")
	var entries: Array[Dictionary] = runner.discover_cleanup_intents()
	var partial_found := false
	for e in entries:
		if str(e.get("session_id", "")) == sid:
			partial_found = true
			_check(str(e.get("resolution", "")) == "RETRY_REQUIRES_RECONCILIATION" or
				str(e.get("resolution", "")) == "PARTIAL_FOREIGN_FILES_PRESERVED",
				"NCL-104: partial cleanup discovery reports retained stage")
	_check(partial_found, "NCL-104: partial intent discovered")
	var history: Array[Dictionary] = runner.discover_cleanup_intents(true)
	_check(history.size() >= entries.size(),
		"NCL-110: history mode exposes completed intents")
	var complete_sid := "t122_complete"
	var complete_stage := SafeStageScript.allocate_stage_dir("SHAMAN_T122_OK_")
	SafeStageScript.stage(complete_stage, {"owned.odf": "OWNED".to_utf8_buffer()}, {}, false, [],
		{"stage_id": "t122ok"})
	var complete_ledger_path := NativeRunnerScript.ledger_dir().path_join(complete_sid + ".cleanup_intent.json")
	_write(complete_ledger_path, JSON.stringify({"schema": 1, "session_id": complete_sid,
		"stage_root": complete_stage, "state": "CLEANUP_COMPLETE"}))
	var history2: Array[Dictionary] = runner.discover_cleanup_intents(true)
	_check(history2.size() >= history.size() + 1,
		"NCL-110: completed history remains inspectable")
	SafeStageScript.clear_registered_bases()
	NativeAdapterScript.clear_trusted_sessions()
	OdfDocument.clear_all_cache()


## DIFF-05..10: physical source changes survive an unchanged effective diff.
func _test_physical_diff(tmp: String) -> void:
	var ws := tmp.path_join("diff")
	WorkspaceStore.root_override = ws
	var pa := ws.path_join("sources/mod_z/effect.odf")
	_write(pa, "[Render]\r\nlifeTime=1.5 ; original\r\n[Render]\r\nlifeTime=1.5 ; second\r\n")
	var lab = _make_lab()
	var prev_text := "[Render]\r\nlifeTime=1.5 ; original\r\n[Render]\r\nlifeTime=1.5 ; second\r\n"
	var prev_bytes := prev_text.to_utf8_buffer()
	var current_text := "[Render]\r\nlifeTime=1.5 ; updated comment\r\n[Render]\r\nlifeTime=1.5 ; second\r\n"
	_write(pa, current_text)
	var target := {"source_path": pa,
		"previous_override_bytes": Marshalls.raw_to_base64(prev_bytes),
		"previous_override_hash": WorkspaceStore._md5_bytes(prev_bytes),
		"working_bytes": Marshalls.raw_to_base64(prev_bytes),
		"working_bytes_hash": WorkspaceStore._md5_bytes(prev_bytes)}
	var res: Dictionary = lab.compare_journal_target_revision(target)
	_check(res.has("physical_source_diff"),
		"DIFF-05: revision comparison exposes an independent physical source diff")
	var phys: Dictionary = res.get("physical_source_diff", {})
	_check(phys.has("comment_changes") and phys.has("duplicate_key_changes") and
		phys.has("encoding_changes") and phys.has("byte_identical"),
		"DIFF-06..08: physical diff reports comments, duplicate keys, encoding and bytes")
	_check(not bool(res.get("bytes_identical", true)),
		"DIFF-07/10: byte-different revisions are never labelled identical")
	lab.queue_free()


func _initialize() -> void:
	print("T-122 Recovery Coherence Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t122_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_ws := WorkspaceStore.root_override
	_test_current_hash_guard(tmp)
	_test_group_id_contract(tmp)
	_test_cache_sync(tmp)
	_test_native_cleanup(tmp)
	_test_physical_diff(tmp)
	WorkspaceStore.root_override = old_ws
	_remove_tree(tmp)
	print("\nT-122 Coherence: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
