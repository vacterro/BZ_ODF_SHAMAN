class_name NativeExperimentRunner
extends RefCounted
## Orchestrator for native BZCC validation experiments with a durable session
## ledger that survives application restart.
##
## Lifecycle:
##   preflight() -> stage() -> launch() (STEAM_MANAGED or OPERATOR_MANUAL)
##   -> collect_observation() -> cleanup_stage()
##
## All ledger data lives inside WorkspaceStore.root()/native_sessions so smoke
## and unit tests remain isolated via BZ_SHAMAN_WORKSPACE_ROOT and never write
## into BZ2R, Steam Workshop, or production user data.

const LEDGER_SCHEMA := 1
const LUA_CONTRACT_VERSION := 1
const REASON_STATE_PERSIST_FAILED := "STATE_PERSIST_FAILED"
const STATE_RECOVERY_PENDING := "RECOVERY_PENDING"
const STATUS_MONITOR_STATE_SAVED := "MONITOR_STATE_SAVED"
const STATUS_MONITOR_PERSIST_FAILED := "MONITOR_PERSIST_FAILED"
const STATUS_CANCEL_REQUESTED := "CANCEL_REQUESTED"
const STATUS_CANCELLATION_COMMITTED := "CANCELLATION_COMMITTED"
const STATUS_CANCELLATION_PERSIST_FAILED := "CANCELLATION_PERSIST_FAILED"
const REASON_RESOURCE_CLOSURE_INCOMPLETE := "RESOURCE_CLOSURE_INCOMPLETE"
const NativeAdapterScript = preload("res://scripts/native/native_test_adapter.gd")
const NativeSessionScript = preload("res://scripts/native/native_experiment_session.gd")
const ResourceClosureScript = preload("res://scripts/native/native_resource_closure.gd")
const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")
const ProcessMonitorScript = preload("res://scripts/native/native_process_monitor.gd")

const REQUIRED_LUA_CONTRACT_FIELDS := [
	"session_id",
	"launch_nonce",
	"scenario_id",
	"state",
	"shooter",
	"target",
	"weapon",
	"ordnance",
	"hp_before",
	"hp_after",
	"hp_max",
	"damage",
	"elapsed_mission_s",
	"tps",
	"mount_marker",
	"resources_mounted",
]

## In-memory index of active/recovered sessions: session_id -> Dictionary record.
var sessions: Dictionary = {}
## Quarantined malformed ledger records preserved during recovery (P1-02 / S-04).
var quarantined_sessions: Dictionary = {}
## Staged file maps cached in memory for the current run: session_id -> Dictionary.
var _pending_files: Dictionary = {}
## Optional test-only launcher override: func(exe: String, args: Array) -> Dictionary{ok, pid, exit_code}
var process_launcher: Callable = Callable()
## Optional test-only detector override for actual battlezone2.exe process: func() -> Dictionary{detected: bool, game_pid: int}
var game_process_detector: Callable = Callable()
## Optional test-only mission/resource probe observer: func(sess) -> Dictionary{mission_observed, mission_loaded_at, resource_probe_confirmed, startup_log_path}
var mission_observer: Callable = Callable()
## Optional test-only process inspector: func() -> Array of {pid, name, exe_path, exe_md5}.
var process_inspector: Callable = Callable()
## Active bounded monitors: session_id -> NativeProcessMonitor.
var monitors: Dictionary = {}
## Test-only persistence failure injection hooks (P1-NATIVE-01, P1-02).
var fault_fail_preflight_package_write := false
var fault_fail_session_write := false
var fault_fail_ledger_write := false
var fault_fail_operator_instructions_write := false
var fault_fail_evidence_write := false
var fault_fail_monitor_persist := false
## Test-only fault hook for the durable cleanup-intent finalization step.
var fault_fail_cleanup_intent_final_write := false


static func ledger_dir() -> String:
	return WorkspaceStore.canonical(WorkspaceStore.root().path_join("native_sessions"))


static func ledger_path() -> String:
	return ledger_dir().path_join("session_ledger.json")


static func _session_file(session_id: String) -> String:
	var safe := session_id.strip_edges().replace("/", "_").replace("\\", "_").replace("..", "_")
	return ledger_dir().path_join(safe + ".json")


static func _preflight_pkg_file(session_id: String) -> String:
	var safe := session_id.strip_edges().replace("/", "_").replace("\\", "_").replace("..", "_")
	return ledger_dir().path_join(safe + ".preflight_pkg.json")


static func _quarantine_file(session_id: String) -> String:
	var safe := session_id.strip_edges().replace("/", "_").replace("\\", "_").replace("..", "_")
	return ledger_dir().path_join("quarantine_" + safe + ".json")


static func _cached_doc_for(spath: String, fallback_doc = null):
	var canon_t := WorkspaceStore.canonical(spath).to_lower()
	var cdoc = OdfDocument.cached(spath)
	if cdoc == null:
		for k in OdfDocument._cache:
			if WorkspaceStore.canonical(str(k)).to_lower() == canon_t:
				cdoc = OdfDocument._cache[k]
				break
	if cdoc == null and fallback_doc != null:
		cdoc = fallback_doc
	return cdoc


## P1-NATIVE-03: Byte-exact raw file hash on disk (safe for UTF-8, UTF-8 BOM, UTF-16LE/BE).
static func hash_source_raw(spath: String) -> Dictionary:
	if spath == "" or not FileAccess.file_exists(spath):
		return {"exists": false, "hash": "", "bytes": 0}
	var raw := FileAccess.get_file_as_bytes(spath)
	return {"exists": true, "hash": WorkspaceStore._md5_bytes(raw), "bytes": raw.size()}


## P1-NATIVE-03: Byte-exact working OdfDocument hash (distinguished from raw source bytes).
static func hash_working_document(spath: String, fallback_doc = null) -> Dictionary:
	var cdoc = _cached_doc_for(spath, fallback_doc)
	if cdoc != null:
		var wbytes: PackedByteArray = cdoc.to_bytes()
		return {
			"cached": true,
			"hash": WorkspaceStore._md5_bytes(wbytes),
			"bytes": wbytes.size(),
			"revision": int(cdoc.revision),
			"encoding": str(cdoc.encoding),
			"dirty": bool(cdoc.dirty),
		}
	var raw_info := hash_source_raw(spath)
	return {
		"cached": false,
		"hash": str(raw_info.get("hash", "")),
		"bytes": int(raw_info.get("bytes", 0)),
		"revision": 0,
		"encoding": "",
		"dirty": false,
	}


static func source_revision_snapshot(spath: String, fallback_doc = null) -> Dictionary:
	var raw_info := hash_source_raw(spath)
	var work_info := hash_working_document(spath, fallback_doc)
	var raw_h := str(raw_info.get("hash", ""))
	var work_h := str(work_info.get("hash", ""))
	return {
		"SOURCE_RAW_HASH": raw_h,
		"WORKING_DOCUMENT_HASH": work_h,
		"source_byte_length": int(raw_info.get("bytes", 0)),
		"working_byte_length": int(work_info.get("bytes", 0)),
		"encoding": str(work_info.get("encoding", "")),
		"revision": int(work_info.get("revision", 0)),
		"md5": work_h if work_h != "" else raw_h,
	}


static func _current_source_md5(spath: String, fallback_doc = null) -> String:
	var snap := source_revision_snapshot(spath, fallback_doc)
	return str(snap.get("WORKING_DOCUMENT_HASH", snap.get("SOURCE_RAW_HASH", "")))


static func _is_valid_base64(s: String) -> bool:
	if s.is_empty():
		return true
	if (s.length() % 4) != 0:
		return false
	var pad_started := false
	var pad_count := 0
	for i in s.length():
		var c := s.unicode_at(i)
		var is_alnum := (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 43 or c == 47
		if c == 61: # '='
			pad_started = true
			pad_count += 1
			if pad_count > 2:
				return false
		elif is_alnum:
			if pad_started:
				return false
		else:
			return false
	return true


static func _compute_package_md5(sid: String, file_meta: Dictionary) -> String:
	var keys := file_meta.keys()
	keys.sort()
	var lines: Array[String] = ["session=" + sid]
	for k in keys:
		var m: Dictionary = file_meta[k]
		lines.append("%s|%d|%s" % [str(k), int(m.get("byte_length", -1)), str(m.get("md5", "")).to_lower()])
	return WorkspaceStore._md5_bytes("\n".join(lines).to_utf8_buffer())


## Reload durable session ledger from disk and reconcile stage/evidence/observation
## presence across restart. Never promotes unattested sessions to NATIVE_VERIFIED.
func recover_sessions() -> Dictionary:
	sessions.clear()
	var lpath := ledger_path()
	var recovered := 0
	var corrupted := 0
	var missing_stage := 0
	var observation_ready := 0
	var errors: Array[String] = []

	if not FileAccess.file_exists(lpath):
		return {
			"ok": true,
			"recovered": 0,
			"corrupted": 0,
			"missing_stage": 0,
			"observation_ready": 0,
			"errors": [],
			"sessions": [],
		}

	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(lpath))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {
			"ok": false,
			"reason": "CORRUPT_SESSION_LEDGER",
			"error": str(jres.get("error", "invalid ledger JSON")),
			"recovered": 0,
			"corrupted": 1,
			"missing_stage": 0,
			"observation_ready": 0,
			"errors": [str(jres.get("error", "invalid ledger JSON"))],
			"sessions": [],
		}

	var root_doc: Dictionary = jres.get("data", {})
	var items = root_doc.get("sessions", {})
	if not (items is Dictionary):
		return {
			"ok": false,
			"reason": "CORRUPT_SESSION_LEDGER",
			"error": "ledger sessions field is not a Dictionary",
			"recovered": 0,
			"corrupted": 1,
			"missing_stage": 0,
			"observation_ready": 0,
			"errors": ["ledger sessions field is not a Dictionary"],
			"sessions": [],
		}

	quarantined_sessions.clear()
	if root_doc.get("quarantined", null) is Dictionary:
		quarantined_sessions = (root_doc.get("quarantined", {}) as Dictionary).duplicate(true)
	var raw_ledger_text := FileAccess.get_file_as_string(lpath)

	for raw_sid in items:
		var sid := str(raw_sid)
		var rec = items[raw_sid]
		if not (rec is Dictionary):
			corrupted += 1
			errors.append("corrupt ledger entry: " + sid)
			quarantined_sessions[sid] = {"raw": rec, "reason": "NON_DICT_RECORD", "quarantined_at": Time.get_datetime_string_from_system()}
			WorkspaceStore.atomic_write_abs(_quarantine_file(sid), JSON.stringify(quarantined_sessions[sid], "  ").to_utf8_buffer())
			continue
		var entry: Dictionary = (rec as Dictionary).duplicate(true)
		var sdict: Dictionary = entry.get("session", {}) if entry.get("session", {}) is Dictionary else {}
		var sess_obj = NativeSessionScript.from_dict(sdict)
		if sess_obj == null or str(sess_obj.session_id) == "":
			corrupted += 1
			errors.append("unparseable session snapshot: " + sid)
			quarantined_sessions[sid] = {"raw": entry, "reason": "INVALID_SESSION_SNAPSHOT", "quarantined_at": Time.get_datetime_string_from_system()}
			WorkspaceStore.atomic_write_abs(_quarantine_file(sid), JSON.stringify(quarantined_sessions[sid], "  ").to_utf8_buffer())
			continue

		var stage_root := str(sess_obj.stage_root)
		var sm_path := str(sess_obj.stage_manifest_path)
		var stage_exists := stage_root != "" and DirAccess.dir_exists_absolute(stage_root)
		var manifest_exists := sm_path != "" and FileAccess.file_exists(sm_path)
		var obs_path := str(sess_obj.observation_expected_path)
		var obs_exists := obs_path != "" and FileAccess.file_exists(obs_path)
		var prev_state := str(entry.get("state", sess_obj.state))

		entry["recovered_at"] = Time.get_datetime_string_from_system()
		entry["stage_present_on_disk"] = stage_exists and manifest_exists
		entry["observation_present_on_disk"] = obs_exists
		entry["can_collect_observation"] = obs_exists and stage_exists and prev_state != "CLEANED_UP" and prev_state != STATE_RECOVERY_PENDING
		entry["can_cleanup"] = stage_exists and manifest_exists
		monitors.erase(sid)

		if str(entry.get("reason", "")) in [REASON_STATE_PERSIST_FAILED, STATUS_CANCELLATION_PERSIST_FAILED] or str(entry.get("cancel_status", "")) == STATUS_CANCELLATION_PERSIST_FAILED or prev_state == STATE_RECOVERY_PENDING:
			entry["state"] = STATE_RECOVERY_PENDING
			if str(entry.get("cancel_status", "")) == STATUS_CANCELLATION_PERSIST_FAILED or str(entry.get("reason", "")) == STATUS_CANCELLATION_PERSIST_FAILED:
				entry["reason"] = STATUS_CANCELLATION_PERSIST_FAILED
				entry["cancel_status"] = STATUS_CANCELLATION_PERSIST_FAILED
				entry["recoverable"] = true
				entry["recovery_status"] = STATUS_CANCELLATION_PERSIST_FAILED
			else:
				entry["reason"] = REASON_STATE_PERSIST_FAILED
				entry["recovery_status"] = "STATE_PERSIST_FAILED"
			entry["recovery_pending"] = true
			sess_obj.add_checkpoint(STATE_RECOVERY_PENDING, "Recovered checked transition that failed persistence (%s)" % str(entry.get("reason", "")))
		elif prev_state in ["STAGED", "LAUNCH_REQUESTED", "AWAITING_OPERATOR", "MONITOR_ARMED", "GAME_PROCESS_CANDIDATE", "GAME_PROCESS_DETECTED", "GAME_PROCESS_VERIFIED", "MISSION_OBSERVED", "RESOURCE_PROBE_CONFIRMED", "OBSERVATION_IMPORTED", "STEAM_PROCESS_STARTED", "GAME_STARTED", "MISSION_LOADED"]:
			if not (stage_exists and manifest_exists):
				missing_stage += 1
				entry["recovery_status"] = "STAGE_MISSING"
				sess_obj.add_checkpoint("STAGE_MISSING", "Recovered after restart; stage manifest missing on disk")
			elif obs_exists:
				observation_ready += 1
				entry["recovery_status"] = "OBSERVATION_READY"
				sess_obj.add_checkpoint("RESTART_RECOVERED", "Recovered after restart; observation artifact found on disk")
			else:
				entry["recovery_status"] = "RECOVERED_PENDING"
				sess_obj.add_checkpoint("RESTART_RECOVERED", "Recovered pending session after restart (state=%s)" % prev_state)
		else:
			entry["recovery_status"] = "RECOVERED_" + prev_state

		# Restarted sessions cannot silently retain NATIVE_VERIFIED across a fresh
		# process without re-evaluating evidence on disk.
		if prev_state == "NATIVE_VERIFIED":
			var ev_path := str(sess_obj.evidence_path)
			if ev_path == "" or not FileAccess.file_exists(ev_path):
				entry["state"] = "COMPARISON_COMPLETE"
				entry["recovery_status"] = "EVIDENCE_MISSING"

		entry["session"] = sess_obj.to_dict()
		# Restore durable preflight package into memory if present and verified (P1-NATIVE-02).
		var pkg_loaded := _load_preflight_package(sid)
		entry["preflight_snapshot_status"] = str(pkg_loaded.get("status", "PREFLIGHT_SNAPSHOT_MISSING"))
		if bool(pkg_loaded.get("ok", false)):
			_pending_files[sid] = pkg_loaded.get("files", {})
			entry["preflight_package_present"] = true
		else:
			_pending_files.erase(sid)
			entry["preflight_package_present"] = false
		sessions[sid] = entry
		recovered += 1

	if corrupted > 0 and raw_ledger_text != "":
		WorkspaceStore.atomic_write_abs(ledger_dir().path_join("session_ledger.corrupt_backup.json"), raw_ledger_text.to_utf8_buffer())
	var save_res := _save_ledger()
	if not bool(save_res.get("ok", false)):
		return {
			"ok": false,
			"reason": "LEDGER_PERSIST_FAILED",
			"recovered": recovered,
			"corrupted": corrupted,
			"quarantined": quarantined_sessions.duplicate(true),
			"missing_stage": missing_stage,
			"observation_ready": observation_ready,
			"errors": errors,
			"sessions": list_sessions(),
		}
	return {
		"ok": true,
		"recovered": recovered,
		"corrupted": corrupted,
		"quarantined": quarantined_sessions.duplicate(true),
		"missing_stage": missing_stage,
		"observation_ready": observation_ready,
		"errors": errors,
		"sessions": list_sessions(),
	}


## P1-02: A checked transition commits the session record and ledger before any
## externally visible success is returned. A failed persist leaves the durable
## record in RECOVERY_PENDING with reason=STATE_PERSIST_FAILED, so a restart
## cannot observe a state the process never proved it reached.
func _commit_transition(session_id: String, record: Dictionary, next_state: String, checkpoint_detail: String = "") -> Dictionary:
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess != null and checkpoint_detail != "":
		sess.add_checkpoint(next_state, checkpoint_detail)
	record["state"] = next_state
	record["updated_at"] = Time.get_datetime_string_from_system()
	record["session"] = sess.to_dict() if sess != null else record.get("session", {})
	var per := _persist_session(session_id, record)
	if bool(per.get("ok", false)):
		return {"ok": true, "state": next_state, "reason": "", "record": record.duplicate(true)}
	record["state"] = STATE_RECOVERY_PENDING
	record["evidence_state"] = STATE_RECOVERY_PENDING
	record["reason"] = REASON_STATE_PERSIST_FAILED
	record["persist_error"] = str(per.get("error", str(per.get("reason", "checked state persist failed"))))
	record["recovery_pending"] = true
	record["updated_at"] = Time.get_datetime_string_from_system()
	if sess != null:
		sess.add_checkpoint(STATE_RECOVERY_PENDING, "Checked transition to %s failed: %s" % [next_state, record["persist_error"]])
		record["session"] = sess.to_dict()
	# Leave the in-memory projection in the failed state too; never report a
	# transition the durable ledger did not accept. Persist the failed state to
	# the single-session record so a restart sees the same RECOVERY_PENDING fact.
	sessions[session_id] = record.duplicate(true)
	WorkspaceStore.atomic_write_abs(
		_session_file(session_id), JSON.stringify(record, "  ").to_utf8_buffer()
	)
	return {
		"ok": false,
		"state": STATE_RECOVERY_PENDING,
		"reason": REASON_STATE_PERSIST_FAILED,
		"recovery_pending": true,
		"attempted_state": next_state,
		"error": str(record["persist_error"]),
		"persist": per.duplicate(true),
	}


## Checked failure when the artifact a transition depends on could not be
## written: never publish the intended state; persist RECOVERY_PENDING instead.
func _fail_transition(session_id: String, record: Dictionary, attempted_state: String, error: String) -> Dictionary:
	record["state"] = STATE_RECOVERY_PENDING
	record["evidence_state"] = STATE_RECOVERY_PENDING
	record["reason"] = REASON_STATE_PERSIST_FAILED
	record["persist_error"] = error
	record["recovery_pending"] = true
	record["attempted_state"] = attempted_state
	record["updated_at"] = Time.get_datetime_string_from_system()
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess != null:
		sess.add_checkpoint(STATE_RECOVERY_PENDING, "Checked transition to %s failed: %s" % [attempted_state, error])
		record["session"] = sess.to_dict()
	sessions[session_id] = record.duplicate(true)
	WorkspaceStore.atomic_write_abs(_session_file(session_id), JSON.stringify(record, "  ").to_utf8_buffer())
	return {
		"ok": false,
		"state": STATE_RECOVERY_PENDING,
		"reason": REASON_STATE_PERSIST_FAILED,
		"recovery_pending": true,
		"attempted_state": attempted_state,
		"error": error,
	}


func _save_ledger() -> Dictionary:
	if fault_fail_ledger_write:
		return {"ok": false, "reason": "LEDGER_WRITE_FAILED", "error": "injected session_ledger.json write failure"}
	var dir := ledger_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var doc := {
		"schema": LEDGER_SCHEMA,
		"updated": Time.get_datetime_string_from_system(),
		"sessions": sessions,
		"quarantined": quarantined_sessions,
	}
	var payload := JSON.stringify(doc, "  ").to_utf8_buffer()
	var lpath := ledger_path()
	var wres := WorkspaceStore.atomic_write_abs(lpath, payload)
	if not bool(wres.get("ok", false)):
		return wres
	if not FileAccess.file_exists(lpath) or WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(lpath)) != WorkspaceStore._md5_bytes(payload):
		return {"ok": false, "reason": "LEDGER_VERIFY_FAILED", "error": "session_ledger.json read-back verification failed"}
	return {"ok": true, "path": lpath, "md5": WorkspaceStore._md5_bytes(payload)}


## P1-NATIVE-01 & P1-NATIVE-02: Byte-exact base64 + byte_length + HashingContext MD5
## + package-level MD5 + read-back verification.
func _save_preflight_package(sid: String, files: Dictionary, source_revisions: Dictionary) -> Dictionary:
	if fault_fail_preflight_package_write:
		return {"ok": false, "reason": "PREFLIGHT_PERSIST_FAILED", "error": "injected preflight package write failure"}
	var dir := ledger_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var serialized_files := {}
	var file_hashes := {}
	for k in files:
		var rel := str(k)
		var v = files[k]
		var raw_bytes: PackedByteArray = v if v is PackedByteArray else str(v).to_utf8_buffer()
		var byte_md5 := WorkspaceStore._md5_bytes(raw_bytes)
		serialized_files[rel] = {
			"encoding": "base64",
			"raw_type": "bytes" if v is PackedByteArray else "utf8",
			"byte_length": raw_bytes.size(),
			"md5": byte_md5,
			"data": Marshalls.raw_to_base64(raw_bytes),
		}
		file_hashes[rel] = {"byte_length": raw_bytes.size(), "md5": byte_md5}
	var pkg_md5 := _compute_package_md5(sid, serialized_files)
	var pkg := {
		"schema": 2,
		"session_id": sid,
		"saved_at": Time.get_datetime_string_from_system(),
		"package_md5": pkg_md5,
		"source_revisions": source_revisions,
		"files": serialized_files,
	}
	var ppath := _preflight_pkg_file(sid)
	var payload := JSON.stringify(pkg, "  ").to_utf8_buffer()
	var wres := WorkspaceStore.atomic_write_abs(ppath, payload)
	if not bool(wres.get("ok", false)):
		return {"ok": false, "reason": "PREFLIGHT_PERSIST_FAILED", "error": str(wres.get("error", "preflight package write failed"))}
	if not FileAccess.file_exists(ppath) or WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(ppath)) != WorkspaceStore._md5_bytes(payload):
		return {"ok": false, "reason": "PREFLIGHT_PERSIST_FAILED", "error": "preflight package read-back verification failed"}
	return {
		"ok": true,
		"path": ppath,
		"package_md5": pkg_md5,
		"file_hashes": file_hashes,
		"bytes": payload.size(),
	}


## P1-NATIVE-02: Strict restore with base64 syntax validation, byte-length check,
## HashingContext per-file MD5 check, package MD5 check, and session identity check.
## Status values: PREFLIGHT_SNAPSHOT_VALID, PREFLIGHT_SNAPSHOT_CORRUPT,
## PREFLIGHT_SNAPSHOT_MISSING, PREFLIGHT_SNAPSHOT_SESSION_MISMATCH,
## PREFLIGHT_SNAPSHOT_HASH_MISMATCH.
func _load_preflight_package(sid: String) -> Dictionary:
	var p := _preflight_pkg_file(sid)
	if not FileAccess.file_exists(p):
		return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_MISSING", "reason": "PREFLIGHT_SNAPSHOT_MISSING", "error": "preflight snapshot file not found: " + p}
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(p))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": str(jres.get("error", "invalid snapshot JSON"))}
	var data: Dictionary = jres.get("data", {})
	var pkg_sid := str(data.get("session_id", ""))
	if pkg_sid == "" or pkg_sid != sid:
		return {
			"ok": false,
			"status": "PREFLIGHT_SNAPSHOT_SESSION_MISMATCH",
			"reason": "PREFLIGHT_SNAPSHOT_SESSION_MISMATCH",
			"error": "snapshot session_id '%s' does not match requested '%s'" % [pkg_sid, sid],
		}
	var raw_files = data.get("files", {})
	if not (raw_files is Dictionary) or (raw_files as Dictionary).is_empty():
		return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": "snapshot files map missing or empty"}
	var out_files := {}
	var verified_meta := {}
	for k in raw_files:
		var rel := str(k)
		var item = raw_files[k]
		if not (item is Dictionary):
			return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": "non-dictionary file record: " + rel}
		var item_d: Dictionary = item
		var enc := str(item_d.get("encoding", ""))
		var d := str(item_d.get("data", ""))
		var exp_md5 := str(item_d.get("md5", "")).strip_edges().to_lower()
		var has_len: bool = item_d.has("byte_length")
		var exp_len := int(item_d.get("byte_length", -1))
		var decoded := PackedByteArray()
		if enc == "base64":
			if not _is_valid_base64(d):
				return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": "malformed base64 for " + rel}
			decoded = Marshalls.base64_to_raw(d)
			if d != "" and decoded.is_empty():
				return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": "base64 decode returned empty bytes for " + rel}
			# Verify strict base64 roundtrip so truncated/padded garbage cannot slip through.
			if Marshalls.raw_to_base64(decoded) != d:
				return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": "non-canonical or corrupted base64 for " + rel}
		elif enc == "utf8":
			decoded = d.to_utf8_buffer()
		else:
			return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": "unsupported encoding '%s' for %s" % [enc, rel]}
		var actual_md5 := WorkspaceStore._md5_bytes(decoded)
		if exp_md5 == "":
			return {"ok": false, "status": "PREFLIGHT_SNAPSHOT_CORRUPT", "reason": "PREFLIGHT_SNAPSHOT_CORRUPT", "error": "missing file hash for " + rel}
		if actual_md5 != exp_md5:
			return {
				"ok": false,
				"status": "PREFLIGHT_SNAPSHOT_HASH_MISMATCH",
				"reason": "PREFLIGHT_SNAPSHOT_HASH_MISMATCH",
				"error": "byte MD5 mismatch for %s (expected %s, got %s)" % [rel, exp_md5, actual_md5],
			}
		if has_len and decoded.size() != exp_len:
			return {
				"ok": false,
				"status": "PREFLIGHT_SNAPSHOT_CORRUPT",
				"reason": "PREFLIGHT_SNAPSHOT_CORRUPT",
				"error": "byte length mismatch for %s (expected %d, got %d)" % [rel, exp_len, decoded.size()],
			}
		verified_meta[rel] = {"byte_length": decoded.size(), "md5": actual_md5}
		if str(item.get("raw_type", "bytes")) == "utf8" and enc != "base64":
			out_files[rel] = d
		else:
			out_files[rel] = decoded
	var exp_pkg_md5 := str(data.get("package_md5", "")).strip_edges().to_lower()
	if exp_pkg_md5 != "":
		var actual_pkg_md5 := _compute_package_md5(sid, verified_meta)
		if actual_pkg_md5 != exp_pkg_md5:
			return {
				"ok": false,
				"status": "PREFLIGHT_SNAPSHOT_HASH_MISMATCH",
				"reason": "PREFLIGHT_SNAPSHOT_HASH_MISMATCH",
				"error": "package_md5 mismatch (expected %s, got %s)" % [exp_pkg_md5, actual_pkg_md5],
			}
	return {
		"ok": true,
		"status": "PREFLIGHT_SNAPSHOT_VALID",
		"reason": "",
		"session_id": sid,
		"package_md5": exp_pkg_md5,
		"files": out_files,
		"file_hashes": verified_meta,
		"source_revisions": data.get("source_revisions", {}) if data.get("source_revisions", {}) is Dictionary else {},
	}


func _persist_session(sid: String, entry: Dictionary) -> Dictionary:
	var prev_had := sessions.has(sid)
	var prev_entry: Dictionary = (sessions[sid] as Dictionary).duplicate(true) if prev_had else {}
	sessions[sid] = entry
	var spath := _session_file(sid)
	var per_res: Dictionary
	if fault_fail_session_write:
		per_res = {"ok": false, "reason": "SESSION_WRITE_FAILED", "error": "injected session JSON write failure"}
	else:
		var spayload := JSON.stringify(entry, "  ").to_utf8_buffer()
		per_res = WorkspaceStore.atomic_write_abs(spath, spayload)
		if bool(per_res.get("ok", false)):
			if not FileAccess.file_exists(spath) or WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(spath)) != WorkspaceStore._md5_bytes(spayload):
				per_res = {"ok": false, "reason": "SESSION_VERIFY_FAILED", "error": "session JSON read-back verification failed"}
	if not bool(per_res.get("ok", false)):
		if prev_had:
			sessions[sid] = prev_entry
		else:
			sessions.erase(sid)
		return {"ok": false, "session_written": false, "ledger_written": false, "reason": "PREFLIGHT_PERSIST_FAILED", "error": str(per_res.get("error", "session write failed")), "ledger": ledger_path()}
	var led_res := _save_ledger()
	if not bool(led_res.get("ok", false)):
		if prev_had:
			sessions[sid] = prev_entry
		else:
			sessions.erase(sid)
		return {"ok": false, "session_written": true, "ledger_written": false, "reason": "PREFLIGHT_PERSIST_FAILED", "error": str(led_res.get("error", "ledger write failed")), "ledger": ledger_path()}
	return {"ok": true, "session_written": true, "ledger_written": true, "reason": "", "error": "", "ledger": ledger_path()}


func list_sessions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for sid in sessions:
		out.append((sessions[sid] as Dictionary).duplicate(true))
	out.sort_custom(func(a, b): return str(a.get("updated_at", "")) > str(b.get("updated_at", "")))
	return out


func get_session_record(session_id: String) -> Dictionary:
	if sessions.has(session_id):
		return (sessions[session_id] as Dictionary).duplicate(true)
	return {}


## Step 1: Read-only preflight. Creates one immutable NativeExperimentSession,
## analyzes resource closure, builds in-memory package files, validates BZN/Lua/
## mount/session/Steam route, and persists the session to the durable ledger.
func preflight(profile: WeaponProfile, index: ResourceIndex = null, options: Dictionary = {}) -> Dictionary:
	var disc: Dictionary = options.get("discovery", {}) if options.get("discovery", {}) is Dictionary else {}
	if disc.is_empty():
		disc = NativeAdapterScript.discover(str(options.get("game_root", NativeAdapterScript.DEFAULT_GAME_ROOT)))
	var launch_mode := str(options.get("launch_mode", "CUSTOM_CONFIG")).strip_edges().to_upper()
	if launch_mode != "STOCK_ADDON":
		launch_mode = "CUSTOM_CONFIG"
	var stage_root := str(options.get("stage_root", "")).strip_edges()
	var stock_addon_plan: Dictionary = {}
	if launch_mode == "STOCK_ADDON":
		var addon_prefix := str(options.get("stage_prefix", "shaman_addon"))
		var addon_stage_id := "%s_%d_%d" % [addon_prefix, Time.get_ticks_usec(), randi()]
		var docs_override := str(options.get("docs_dir_override", "")).strip_edges()
		stock_addon_plan = NativeAdapterScript.build_stock_addon_stage_plan(addon_stage_id, "", str(options.get("mission_base", NativeAdapterScript.DEFAULT_MISSION_BASE)), docs_override)
		if stage_root == "":
			stage_root = str(stock_addon_plan.get("stage_absolute_path", ""))
			var addon_base := str(stock_addon_plan.get("addon_base", ""))
			if addon_base != "":
				var extra_prot := NativeAdapterScript._extra_protected_from_discovery(disc, true)
				SafeStageScript.register_owned_base(addon_base, extra_prot)
		else:
			stage_root = WorkspaceStore.canonical(stage_root)
	elif stage_root == "":
		stage_root = SafeStageScript.allocate_stage_dir(str(options.get("stage_prefix", "shaman_run")))
	else:
		stage_root = WorkspaceStore.canonical(stage_root)

	var weapon_name := profile.weapon_name if profile != null and profile.weapon_name != "" else str(options.get("weapon_odf", "gatstabvsr_c"))
	var ord_name := profile.ordnance_name if profile != null and profile.ordnance_name != "" else str(options.get("ordnance_odf", "atstabvsr_c"))
	var shooter_name := profile.shooter_path.get_file().get_basename() if profile != null and profile.shooter_path != "" else str(options.get("shooter_odf", "ivtank_vsr"))
	var target_name := profile.target_path.get_file().get_basename() if profile != null and profile.target_path != "" else str(options.get("target_odf", "ivscav_vsr"))
	var pred_dmg := profile.expected_damage() if profile != null else float(options.get("expected_damage", 100.0))
	var armor := profile.target_armor if profile != null and profile.target_armor != "" else str(options.get("armor", "H"))

	var scenario: Dictionary = (options.get("scenario", {}) as Dictionary).duplicate(true) if options.get("scenario", {}) is Dictionary else {}
	if str(scenario.get("id", "")) == "":
		scenario["id"] = "scn_" + weapon_name
	scenario["shooter"] = shooter_name
	scenario["target"] = target_name
	scenario["weapon"] = weapon_name
	scenario["ordnance"] = ord_name
	scenario["launch_mode"] = launch_mode
	if not scenario.has("godot_prediction"):
		scenario["godot_prediction"] = {
			"damage": pred_dmg,
			"armor": armor,
			"shot_speed": profile.shot_speed if profile != null else 0.0,
			"life_span": profile.life_span if profile != null else 0.0,
		}

	var explicit_mission_base := str(options.get("mission_base", "")).strip_edges()
	var mission_base := explicit_mission_base if explicit_mission_base != "" else NativeAdapterScript.DEFAULT_MISSION_BASE
	var terrain_name := str(options.get("terrain_name", NativeAdapterScript.DEFAULT_TERRAIN_NAME))
	var sess = NativeAdapterScript.create_session(stage_root, scenario, disc, mission_base, terrain_name)
	# P1-NATIVE-02 (SA-01..SA-04): In STOCK_ADDON mode, derive a unique BZCC-safe
	# mission basename and session-scoped mount marker ODF unless caller explicitly
	# supplied a mission_base (which is still validated and collision-checked).
	if launch_mode == "STOCK_ADDON":
		if explicit_mission_base == "":
			mission_base = NativeAdapterScript.derive_session_mission_basename(str(sess.session_id), str(sess.launch_nonce))
			sess.mission_basename = mission_base
			var assets_dir_sa := WorkspaceStore.canonical(stage_root).path_join("assets")
			sess.bzn_path = assets_dir_sa.path_join("Missions/%s.bzn" % mission_base)
			sess.lua_path = assets_dir_sa.path_join("Missions/%s.lua" % mission_base)
			sess.mount_plan["mission_basename"] = mission_base
			sess.mount_plan["mission_bzn"] = mission_base + ".bzn"
			sess.mount_plan["mission_lua"] = mission_base + ".lua"
		sess.marker_odf_filename = NativeAdapterScript.derive_session_marker_odf(str(sess.session_id), str(sess.launch_nonce), "STOCK_ADDON")
		sess.mount_plan["marker_odf_filename"] = sess.marker_odf_filename
	var mbase_check: Dictionary = NativeAdapterScript.validate_mission_basename(mission_base)
	var cfg_override := str(options.get("config_path_override", "")).strip_edges()
	if cfg_override != "":
		sess.config_path = WorkspaceStore.canonical(cfg_override)
		sess.mount_plan["bzcc_config_path"] = sess.config_path
		sess.mount_plan["bzcc_config_win"] = sess.config_path.replace("/", "\\")
	var addon_plan: Dictionary = {}
	if launch_mode == "STOCK_ADDON":
		addon_plan = NativeAdapterScript.build_stock_addon_stage_plan(sess.stage_id, sess.session_id, mission_base, str(options.get("docs_dir_override", "")))
		sess.config_path = ""
		sess.observation_filename = str(addon_plan.get("observation_filename", sess.observation_filename))
		sess.observation_expected_path = str(addon_plan.get("observation_expected_path", sess.observation_expected_path))
		sess.mount_plan["launch_mode"] = "STOCK_ADDON"
		sess.mount_plan["addon_base"] = str(addon_plan.get("addon_base", ""))
		sess.mount_plan["bzcc_writable_profile_dir"] = str(addon_plan.get("bzcc_writable_profile_dir", ""))
		sess.mount_plan["bzcc_logs_dir"] = str(addon_plan.get("bzcc_logs_dir", ""))
		sess.mount_plan["startup_log_path"] = str(addon_plan.get("startup_log_path", ""))
		sess.mount_plan["observation_filename"] = sess.observation_filename
		sess.mount_plan["observation_expected_path"] = sess.observation_expected_path
		sess.mount_plan["mission_basename"] = mission_base
		sess.mount_plan["mission_bzn"] = mission_base + ".bzn"
		sess.mount_plan["mission_lua"] = mission_base + ".lua"
		sess.mount_plan["marker_odf_filename"] = sess.marker_odf_filename

	var extra_odfs: Dictionary = {}
	if options.has("staged_odfs") and options.staged_odfs is Dictionary:
		extra_odfs = (options.staged_odfs as Dictionary).duplicate(true)
	elif profile != null and index != null:
		extra_odfs = ResourceClosureScript.build_minimal_staged_odfs(profile, index, disc, true)
	elif profile != null and profile.ordnance_doc != null:
		extra_odfs["assets/ODF/" + profile.ordnance_path.get_file()] = profile.ordnance_doc.to_bytes()

	var files: Dictionary = NativeAdapterScript.build_experiment_files_for_session(sess, profile, extra_odfs)
	if launch_mode == "STOCK_ADDON":
		# Never pollute global @mydocsdir\addon with bzshell_init.cfg or external shaman_native.cfg.
		files.erase("shaman_native.cfg")
		files.erase("assets/Config/bzshell_init.cfg")
	var require_closure := bool(options.get("require_complete_closure", false))
	var closure_spec: Dictionary = {}
	if index != null or bool(options.get("check_closure", false)) or require_closure:
		closure_spec = {
			"shooter_odf": shooter_name,
			"target_odf": target_name,
			"weapon_odf": weapon_name,
			"ordnance_odf": ord_name,
			"shooter_path": profile.shooter_path if profile != null else "",
			"target_path": profile.target_path if profile != null else "",
			"weapon_path": profile.weapon_path if profile != null else "",
			"ordnance_path": profile.ordnance_path if profile != null else "",
			"staged_files": files,
			"mounted_workshop_packages": options.get("mounted_workshop_packages", []),
			"active_packages": options.get("active_packages", []),
		}

	var steam_override: Dictionary = options.get("steam_override", {}) if options.get("steam_override", {}) is Dictionary else {}
	var pre_launch_opts := {
		"launch_mode": launch_mode,
		"config_path_override": cfg_override,
		"include_logconsole": bool(options.get("include_logconsole", false)),
	}
	var pre: Dictionary = NativeAdapterScript.preflight_experiment(
		stage_root, files, sess.scenario, disc, steam_override, sess, index if not closure_spec.is_empty() else null, closure_spec, pre_launch_opts
	)
	if require_closure and index == null:
		pre["ok"] = false
		pre["structurally_valid"] = false
		pre["resource_closure_valid"] = false
		pre["stage_eligible"] = false
		pre["launch_ready"] = false
		pre["launch_eligible"] = false
		pre["status"] = "FAILED"
		pre["reason"] = REASON_RESOURCE_CLOSURE_INCOMPLETE
		if pre.get("gates", null) is Dictionary:
			(pre["gates"] as Dictionary)["STRUCTURALLY_VALID"] = false
			(pre["gates"] as Dictionary)["RESOURCE_CLOSURE_VALID"] = false
			(pre["gates"] as Dictionary)["STAGE_ELIGIBLE"] = false
			(pre["gates"] as Dictionary)["LAUNCH_ELIGIBLE"] = false
		var pre_issues: Array = pre.get("issues", [])
		pre_issues.append("Complete resource closure required but no ResourceIndex was supplied (synthetic probe cannot claim full native closure)")
		pre["issues"] = pre_issues
	elif not closure_spec.is_empty() and not bool((pre.get("resource_closure", {}) as Dictionary).get("ok", true)):
		pre["closure_incomplete"] = true
		pre["closure_code"] = REASON_RESOURCE_CLOSURE_INCOMPLETE
		pre["resource_closure_valid"] = false
		pre["stage_eligible"] = false
		pre["launch_ready"] = false
		pre["launch_eligible"] = false

	# P1-NATIVE-02 & P1-NATIVE-03 (SA-01..SA-09): Validate mission basename safety,
	# active-session mission name uniqueness, and shared @mydocsdir\addon collisions.
	if not bool(mbase_check.get("ok", true)):
		pre["ok"] = false
		pre["structurally_valid"] = false
		pre["stage_eligible"] = false
		pre["launch_ready"] = false
		pre["launch_eligible"] = false
		pre["status"] = "FAILED"
		pre["reason"] = str(mbase_check.get("reason", "INVALID_MISSION_BASENAME"))
		var mi_issues: Array = pre.get("issues", [])
		mi_issues.append(str(mbase_check.get("error", "invalid mission basename")))
		pre["issues"] = mi_issues

	var active_mission_conflict_sid := ""
	var mbase_lc := mission_base.to_lower()
	for existing_sid in sessions:
		if str(existing_sid) == str(sess.session_id):
			continue
		var erec: Dictionary = sessions[existing_sid]
		var est := str(erec.get("state", ""))
		if est in ["CLEANED_UP", "CANCELLED", "FAILED", "TIMEOUT", "COMPARISON_COMPLETE", "NATIVE_VERIFIED"]:
			continue
		var esess: Dictionary = erec.get("session", {}) if erec.get("session", {}) is Dictionary else {}
		if str(esess.get("mission_basename", "")).to_lower() == mbase_lc:
			active_mission_conflict_sid = str(existing_sid)
			break

	var addon_conflict_report: Dictionary = {}
	if launch_mode == "STOCK_ADDON":
		var addon_dir_scan := str(addon_plan.get("addon_base", str(disc.get("addon_root", ""))))
		var loadout_info := {
			"active_loadout_profile_id": str(index.active_loadout_profile_id) if index != null else "",
			"active_packages": index.active_packages.duplicate() if index != null else options.get("active_packages", []),
		}
		addon_conflict_report = NativeAdapterScript.scan_addon_mount_conflicts(
			addon_dir_scan, stage_root, files,
			pre.get("resource_closure", {}) if pre.get("resource_closure", {}) is Dictionary else {},
			loadout_info
		)
		if active_mission_conflict_sid != "":
			var mc_list: Array = addon_conflict_report.get("conflicts", [])
			mc_list.append({
				"code": "MISSION_NAME_COLLISION",
				"resource": mission_base + ".bzn",
				"target_kind": "mission",
				"own_path": "assets/Missions/%s.bzn" % mission_base,
				"conflicting_path": "session:" + active_mission_conflict_sid,
				"source_kind": "active_shaman_session",
				"stage_dir": active_mission_conflict_sid,
				"safe_resolutions": ["Use auto-derived unique session mission basename or clean up session " + active_mission_conflict_sid],
			})
			addon_conflict_report["conflicts"] = mc_list
			addon_conflict_report["ok"] = false
			addon_conflict_report["verification_allowed"] = false
			addon_conflict_report["reason"] = "MISSION_NAME_COLLISION"
		pre["addon_conflict_report"] = addon_conflict_report
		if not bool(addon_conflict_report.get("ok", true)):
			var creason := str(addon_conflict_report.get("reason", "ADDON_FOREIGN_ODF_COLLISION"))
			pre["launch_ready"] = false
			pre["launch_eligible"] = false
			pre["addon_isolated"] = false
			if creason == "MISSION_NAME_COLLISION":
				pre["stage_eligible"] = false
				pre["status"] = "FAILED"
			else:
				if str(pre.get("status", "")) == "STRUCTURALLY_VALID":
					pre["status"] = "BLOCKED"
			pre["reason"] = creason
			var pre_blks: Array = pre.get("blockers", [])
			pre_blks.append("STOCK_ADDON mount conflict (%s): %d conflicting file(s) in %s" % [creason, (addon_conflict_report.get("conflicts", []) as Array).size(), addon_dir_scan])
			pre["blockers"] = pre_blks
			if pre.get("gates", null) is Dictionary:
				(pre["gates"] as Dictionary)["LAUNCH_ELIGIBLE"] = false
				(pre["gates"] as Dictionary)["ADDON_ISOLATED"] = false
				if creason == "MISSION_NAME_COLLISION":
					(pre["gates"] as Dictionary)["STAGE_ELIGIBLE"] = false
		else:
			pre["addon_isolated"] = true
			if pre.get("gates", null) is Dictionary:
				(pre["gates"] as Dictionary)["ADDON_ISOLATED"] = true
	elif active_mission_conflict_sid != "":
		pre["launch_ready"] = false
		pre["launch_eligible"] = false
		pre["reason"] = "MISSION_NAME_COLLISION"
		var pre_blks2: Array = pre.get("blockers", [])
		pre_blks2.append("Active session %s already uses mission basename '%s'" % [active_mission_conflict_sid, mission_base])
		pre["blockers"] = pre_blks2

	var structurally_valid := bool(pre.get("structurally_valid", false))
	var resource_closure_valid := bool(pre.get("resource_closure_valid", true))
	var preflight_passed := structurally_valid and resource_closure_valid
	var stage_eligible_pre := bool(pre.get("stage_eligible", preflight_passed))
	var config_compatible := bool(pre.get("config_compatible", false))
	var exec_env_ready := bool(pre.get("execution_environment_ready", false))
	var launch_ready_pre := bool(pre.get("launch_ready", false))
	var state := "PREFLIGHT_OK" if launch_ready_pre else ("BLOCKED" if stage_eligible_pre else "FAILED")
	sess.add_checkpoint(state, "Preflight finished: route=%s mode=%s reason=%s" % [str(pre.get("launch_route", "")), launch_mode, str(pre.get("reason", ""))])

	var source_revisions := {}
	if profile != null:
		for d in [profile.shooter_doc, profile.target_doc, profile.weapon_doc, profile.ordnance_doc]:
			if d != null and d.source_path != "":
				var cp0 := WorkspaceStore.canonical(d.source_path)
				var snap0 := source_revision_snapshot(cp0, d)
				if str(snap0.get("SOURCE_RAW_HASH", "")) != "" or str(snap0.get("WORKING_DOCUMENT_HASH", "")) != "":
					source_revisions[cp0] = snap0
	if options.has("source_odf_paths") and options.source_odf_paths is Array:
		for sp in options.source_odf_paths:
			var cp := WorkspaceStore.canonical(str(sp))
			var cdoc = OdfDocument.cached(cp)
			if cdoc == null and FileAccess.file_exists(cp):
				cdoc = OdfDocument.load_cached(cp)
			var snap1 := source_revision_snapshot(cp, cdoc)
			if str(snap1.get("SOURCE_RAW_HASH", "")) != "" or str(snap1.get("WORKING_DOCUMENT_HASH", "")) != "":
				source_revisions[cp] = snap1

	var sid := str(sess.session_id)
	# P1-NATIVE-01: Enforce all 6 durability checks before reporting preflight success.
	var pkg_res := _save_preflight_package(sid, files, source_revisions)
	var pkg_verify: Dictionary = _load_preflight_package(sid) if bool(pkg_res.get("ok", false)) else {"ok": false, "status": "PREFLIGHT_SNAPSHOT_MISSING"}
	var pkg_ok := bool(pkg_res.get("ok", false)) and bool(pkg_verify.get("ok", false)) and str(pkg_verify.get("status", "")) == "PREFLIGHT_SNAPSHOT_VALID" and str(pkg_verify.get("session_id", "")) == sid

	var now := Time.get_datetime_string_from_system()
	var stage_eligible := stage_eligible_pre and pkg_ok
	var launch_eligible := stage_eligible and launch_ready_pre and config_compatible and exec_env_ready
	var record := {
		"schema": LEDGER_SCHEMA,
		"session_id": sid,
		"stage_id": str(sess.stage_id),
		"stage_root": stage_root,
		"state": state,
		"evidence_state": "STRUCTURALLY_VALID" if preflight_passed else "FAILED",
		"preflight_passed": preflight_passed and pkg_ok,
		"structurally_valid": structurally_valid,
		"resource_closure_valid": resource_closure_valid,
		"stage_eligible": stage_eligible,
		"config_compatible": config_compatible,
		"execution_environment_ready": exec_env_ready,
		"launch_ready": launch_ready_pre and pkg_ok,
		"launch_eligible": launch_eligible,
		"launch_mode": launch_mode,
		"restart_resumable": false,
		"preflight_package_md5": str(pkg_res.get("package_md5", "")),
		"preflight_file_hashes": (pkg_res.get("file_hashes", {}) as Dictionary).duplicate(true),
		"source_revisions": source_revisions,
		"launch_route": str(pre.get("launch_route", "UNSUPPORTED")),
		"reason": str(pre.get("reason", "")),
		"created_at": now,
		"updated_at": now,
		"discovery": disc,
		"preflight": pre,
		"session": sess.to_dict(),
		"staged": {},
		"launch": {},
		"evidence": {},
		"cleanup": {},
	}
	if not pkg_ok:
		_pending_files.erase(sid)
		record["state"] = "FAILED"
		record["evidence_state"] = "FAILED"
		record["preflight_passed"] = false
		record["stage_eligible"] = false
		record["launch_ready"] = false
		record["launch_eligible"] = false
		record["restart_resumable"] = false
		record["reason"] = "PREFLIGHT_PERSIST_FAILED"
		return {
			"ok": false,
			"preflight_passed": false,
			"structurally_valid": structurally_valid,
			"resource_closure_valid": resource_closure_valid,
			"stage_eligible": false,
			"config_compatible": config_compatible,
			"execution_environment_ready": exec_env_ready,
			"launch_eligible": false,
			"launch_ready": false,
			"restart_resumable": false,
			"session_id": sid,
			"session": sess,
			"state": "FAILED",
			"reason": "PREFLIGHT_PERSIST_FAILED",
			"error": str(pkg_res.get("error", pkg_verify.get("error", "preflight package persistence failed"))),
			"preflight": pre,
			"files": {},
			"record": record.duplicate(true),
		}

	record["restart_resumable"] = true
	var per_res := _persist_session(sid, record)
	if not bool(per_res.get("ok", false)):
		_pending_files.erase(sid)
		record["state"] = "FAILED"
		record["evidence_state"] = "FAILED"
		record["preflight_passed"] = false
		record["stage_eligible"] = false
		record["launch_ready"] = false
		record["launch_eligible"] = false
		record["restart_resumable"] = false
		record["reason"] = "PREFLIGHT_PERSIST_FAILED"
		return {
			"ok": false,
			"preflight_passed": false,
			"structurally_valid": structurally_valid,
			"resource_closure_valid": resource_closure_valid,
			"stage_eligible": false,
			"config_compatible": config_compatible,
			"execution_environment_ready": exec_env_ready,
			"launch_eligible": false,
			"launch_ready": false,
			"restart_resumable": false,
			"session_id": sid,
			"session": sess,
			"state": "FAILED",
			"reason": "PREFLIGHT_PERSIST_FAILED",
			"error": str(per_res.get("error", "session/ledger persistence failed")),
			"preflight": pre,
			"files": {},
			"record": record.duplicate(true),
		}

	_pending_files[sid] = pkg_verify.get("files", files)
	return {
		"ok": preflight_passed,
		"preflight_passed": preflight_passed,
		"structurally_valid": structurally_valid,
		"resource_closure_valid": resource_closure_valid,
		"stage_eligible": stage_eligible,
		"config_compatible": config_compatible,
		"execution_environment_ready": exec_env_ready,
		"launch_eligible": launch_eligible,
		"launch_ready": launch_ready_pre,
		"launch_mode": launch_mode,
		"restart_resumable": true,
		"preflight_package_md5": str(pkg_res.get("package_md5", "")),
		"session_id": sid,
		"session": sess,
		"state": state,
		"evidence_state": str(record["evidence_state"]),
		"reason": str(pre.get("reason", "")),
		"preflight": pre,
		"files": _pending_files[sid],
		"record": record.duplicate(true),
	}


## Diagnostic-only staging helper (P1-NATIVE-04). Explicitly separated from
## launchable staging: NEVER marks a session launch_eligible and NEVER allows
## files_override to bypass preflight for native launch.
func stage_diagnostic(session_id: String, files_override: Dictionary = {}, stage_options: Dictionary = {}) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "state": "REJECTED", "launch_eligible": false, "reason": "UNKNOWN_SESSION", "error": "session not found in ledger: " + session_id}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "state": "REJECTED", "launch_eligible": false, "reason": "INVALID_SESSION", "error": "cannot deserialize session: " + session_id}
	var files: Dictionary = files_override
	if files.is_empty():
		var pkg_res := _load_preflight_package(session_id)
		if bool(pkg_res.get("ok", false)):
			files = pkg_res.get("files", {})
		else:
			return {
				"ok": false,
				"state": "FAILED",
				"launch_eligible": false,
				"reason": str(pkg_res.get("status", "PREFLIGHT_SNAPSHOT_MISSING")),
				"error": str(pkg_res.get("error", "no valid preflight snapshot for diagnostic staging")),
			}
	var disc: Dictionary = record.get("discovery", {})
	var stg: Dictionary = NativeAdapterScript.stage_scenario(
		str(sess.stage_root), files, sess.scenario, disc, false, sess, stage_options
	)
	if not bool(stg.get("ok", false)):
		return stg
	record["state"] = "STAGED_DIAGNOSTIC"
	record["launch_eligible"] = false
	record["reason"] = "DIAGNOSTIC_ONLY"
	record["updated_at"] = Time.get_datetime_string_from_system()
	record["session"] = sess.to_dict()
	record["staged"] = {
		"stage": str(stg.get("stage", "")),
		"stage_id": str(stg.get("stage_id", "")),
		"manifest": str(stg.get("manifest", "")),
		"stage_manifest": str(stg.get("stage_manifest", "")),
		"file_count": (stg.get("staged", []) as Array).size(),
		"launch_eligible": false,
		"diagnostic_only": true,
	}
	_persist_session(session_id, record)
	return {
		"ok": true,
		"session_id": session_id,
		"state": "STAGED_DIAGNOSTIC",
		"launch_eligible": false,
		"staged": stg,
		"session": sess,
		"record": record.duplicate(true),
	}


## Step 2: Materialize the preflighted package under the allowlisted stage dir
## via SafeStageManager, preserving the exact NativeExperimentSession identity.
## P1-NATIVE-04: Fail-closed defaults (`preflight_passed=false`, `launch_eligible=false`);
## `files_override` can NEVER bypass preflight for launchable staging.
func stage(session_id: String, files_override: Dictionary = {}, stage_options: Dictionary = {}) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "state": "REJECTED", "launch_eligible": false, "reason": "UNKNOWN_SESSION", "error": "session not found in ledger: " + session_id}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "state": "REJECTED", "launch_eligible": false, "reason": "INVALID_SESSION", "error": "cannot deserialize session: " + session_id}

	if bool(stage_options.get("diagnostic_only", false)):
		return stage_diagnostic(session_id, files_override, stage_options)

	# P1-NATIVE-04: files_override must NEVER substitute for a preflight-verified launchable package.
	if not files_override.is_empty():
		return {
			"ok": false,
			"state": "REJECTED",
			"launch_eligible": false,
			"reason": "FILES_OVERRIDE_REQUIRES_PREFLIGHT",
			"error": "files_override cannot bypass preflight for launchable staging; run a new preflight or stage_diagnostic()",
		}

	# P1-NATIVE-04: Fail-closed if preflight fields are absent from a persisted session.
	if not record.has("preflight_passed") or not record.has("launch_eligible"):
		return {
			"ok": false,
			"state": "REJECTED",
			"launch_eligible": false,
			"reason": "PREFLIGHT_STATE_MISSING",
			"error": "Persisted session is missing preflight_passed/launch_eligible state (fail-closed)",
		}

	var pre_passed := bool(record.get("preflight_passed", false))
	var rec_stage_eligible := bool(record.get("stage_eligible", pre_passed))
	var rec_launch_eligible := bool(record.get("launch_eligible", false))
	var is_diag := str(record.get("reason", "")) == "DIAGNOSTIC_ONLY" or str(record.get("state", "")) == "STAGED_DIAGNOSTIC"
	if not pre_passed or not rec_stage_eligible or is_diag:
		var fail_reason := str(record.get("reason", "PREFLIGHT_FAILED"))
		if fail_reason == "":
			fail_reason = "PREFLIGHT_FAILED"
		return {
			"ok": false,
			"state": "REJECTED",
			"stage_eligible": false,
			"launch_eligible": false,
			"reason": fail_reason,
			"error": "Preflight failed (%s); staging rejected" % fail_reason,
		}

	# P1-NATIVE-02: Always validate durable preflight package hashes before staging so
	# tampered/corrupt/session-mismatched snapshots cannot silently enter native staging.
	var pkg_res := _load_preflight_package(session_id)
	if not bool(pkg_res.get("ok", false)):
		_pending_files.erase(session_id)
		record["launch_eligible"] = false
		record["preflight_snapshot_status"] = str(pkg_res.get("status", "PREFLIGHT_SNAPSHOT_CORRUPT"))
		return {
			"ok": false,
			"state": "FAILED",
			"launch_eligible": false,
			"snapshot_status": str(pkg_res.get("status", "PREFLIGHT_SNAPSHOT_CORRUPT")),
			"reason": str(pkg_res.get("reason", "PREFLIGHT_SNAPSHOT_CORRUPT")),
			"error": str(pkg_res.get("error", "no verified preflight snapshot available for " + session_id)),
		}
	var files: Dictionary = pkg_res.get("files", {})
	var verified_pkg_hashes: Dictionary = pkg_res.get("file_hashes", {})
	_pending_files[session_id] = files
	if not record.has("source_revisions") or (record.get("source_revisions", {}) as Dictionary).is_empty():
		record["source_revisions"] = pkg_res.get("source_revisions", {})

	# P1-NATIVE-03: Byte-exact source drift detection distinguishing SOURCE_RAW_HASH and WORKING_DOCUMENT_HASH.
	var src_revs: Dictionary = record.get("source_revisions", {}) if record.get("source_revisions", {}) is Dictionary else {}
	if not src_revs.is_empty() and not bool(stage_options.get("allow_source_drift", false)):
		for spath in src_revs:
			var exp_info: Dictionary = src_revs[spath] if src_revs[spath] is Dictionary else {}
			var exp_raw := str(exp_info.get("SOURCE_RAW_HASH", ""))
			var exp_work := str(exp_info.get("WORKING_DOCUMENT_HASH", exp_info.get("md5", "")))
			var cur_snap := source_revision_snapshot(str(spath), null)
			var cur_raw := str(cur_snap.get("SOURCE_RAW_HASH", ""))
			var cur_work := str(cur_snap.get("WORKING_DOCUMENT_HASH", ""))
			if exp_raw != "" and cur_raw != "" and cur_raw != exp_raw:
				return {
					"ok": false,
					"state": "FAILED",
					"launch_eligible": false,
					"reason": "SOURCE_DRIFT_DETECTED",
					"drift_kind": "SOURCE_RAW_HASH",
					"drifted_path": str(spath),
					"expected_hash": exp_raw,
					"actual_hash": cur_raw,
					"error": "Source file raw bytes for '%s' changed since preflight snapshot" % str(spath).get_file(),
				}
			if exp_work != "" and cur_work != "" and cur_work != exp_work:
				return {
					"ok": false,
					"state": "FAILED",
					"launch_eligible": false,
					"reason": "SOURCE_DRIFT_DETECTED",
					"drift_kind": "WORKING_DOCUMENT_HASH",
					"drifted_path": str(spath),
					"expected_hash": exp_work,
					"actual_hash": cur_work,
					"error": "Working ODF document '%s' changed since preflight snapshot" % str(spath).get_file(),
				}

	var disc: Dictionary = record.get("discovery", {})
	var stg: Dictionary = NativeAdapterScript.stage_scenario(
		str(sess.stage_root), files, sess.scenario, disc, false, sess, stage_options
	)
	if not bool(stg.get("ok", false)):
		sess.add_checkpoint("FAILED", "Staging failed: " + str(stg.get("error", "")))
		record["state"] = str(stg.get("status", "FAILED"))
		record["reason"] = str(stg.get("reason", "STAGE_FAILED"))
		record["updated_at"] = Time.get_datetime_string_from_system()
		record["session"] = sess.to_dict()
		_persist_session(session_id, record)
		return stg

	# Record byte-exact STAGED_FILE_HASH map and verify staged bytes match preflight snapshot (N-D07).
	var staged_hashes := {}
	for rel in verified_pkg_hashes:
		var abs_p := str(sess.stage_root).path_join(str(rel))
		if not FileAccess.file_exists(abs_p):
			return {"ok": false, "state": "FAILED", "launch_eligible": false, "reason": "STAGED_FILE_MISSING", "error": "staged file missing after stage: " + str(rel)}
		var st_md5 := WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(abs_p))
		var exp_m := str((verified_pkg_hashes[rel] as Dictionary).get("md5", ""))
		if exp_m != "" and st_md5 != exp_m:
			return {"ok": false, "state": "FAILED", "launch_eligible": false, "reason": "STAGED_HASH_MISMATCH", "error": "staged bytes differ from preflight package for " + str(rel)}
		staged_hashes[str(rel)] = st_md5

	record["state"] = "STAGED"
	record["evidence_state"] = "STAGED"
	record["stage_eligible"] = true
	# P0-NATIVE-01: Preserve preflight launch eligibility — staging a valid
	# scenario with external /config or logged-off Steam MUST NOT promote
	# launch_eligible to true!
	record["launch_eligible"] = rec_launch_eligible
	if rec_launch_eligible:
		record["reason"] = ""
	record["updated_at"] = Time.get_datetime_string_from_system()
	record["session"] = sess.to_dict()
	record["staged"] = {
		"stage": str(stg.get("stage", "")),
		"stage_id": str(stg.get("stage_id", "")),
		"manifest": str(stg.get("manifest", "")),
		"stage_manifest": str(stg.get("stage_manifest", "")),
		"file_count": (stg.get("staged", []) as Array).size(),
		"staged_file_hashes": staged_hashes,
		"stage_eligible": true,
		"launch_eligible": rec_launch_eligible,
	}
	record["evidence"] = (stg.get("evidence", {}) as Dictionary).duplicate(true)
	var staged_commit := _commit_transition(session_id, record, "STAGED", "Staged via SafeStageManager")
	if not bool(staged_commit.get("ok", false)):
		staged_commit["session_id"] = session_id
		staged_commit["evidence_state"] = STATE_RECOVERY_PENDING
		staged_commit["stage_eligible"] = false
		staged_commit["launch_eligible"] = false
		return staged_commit
	return {
		"ok": true,
		"session_id": session_id,
		"state": "STAGED",
		"evidence_state": "STAGED",
		"stage_eligible": true,
		"launch_eligible": rec_launch_eligible,
		"reason": str(record.get("reason", "")),
		"staged_file_hashes": staged_hashes,
		"staged": stg,
		"session": sess,
		"record": record.duplicate(true),
	}


func _verify_staged_integrity_before_launch(sess: RefCounted) -> Dictionary:
	if sess == null or str(sess.stage_root) == "" or str(sess.stage_manifest_path) == "":
		return {"ok": false, "reason": "NOT_STAGED"}
	if not FileAccess.file_exists(str(sess.stage_manifest_path)):
		return {"ok": false, "reason": "NOT_STAGED"}
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(str(sess.stage_manifest_path)))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {"ok": false, "reason": "STAGE_MODIFIED_AFTER_PREFLIGHT"}
	var sm: Dictionary = jres.get("data", {})
	var files = sm.get("files", [])
	if not (files is Array) or (files as Array).is_empty():
		return {"ok": false, "reason": "STAGE_MODIFIED_AFTER_PREFLIGHT"}
	for entry in files:
		if not (entry is Dictionary):
			continue
		var rel := str(entry.get("rel", ""))
		var exp_md5 := str(entry.get("md5", "")).to_lower()
		var abs_p := str(sess.stage_root).path_join(rel)
		if not FileAccess.file_exists(abs_p):
			return {"ok": false, "reason": "STAGE_MODIFIED_AFTER_PREFLIGHT", "detail": "missing staged file: " + rel}
		if exp_md5 != "" and WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(abs_p)).to_lower() != exp_md5:
			return {"ok": false, "reason": "STAGE_MODIFIED_AFTER_PREFLIGHT", "detail": "modified staged file: " + rel}
	return {"ok": true}


## P1-NATIVE-05: Production game process detection NEVER accepts caller-provided
## option fields (game_process_detected / game_pid / mission_loaded_at / resources_mounted).
## Only an explicit test DI callback (`game_process_detector`) or real OS process
## inspection (`tasklist` for battlezone2.exe) can confirm a running game process.
func _detect_bzcc_game_process(preexisting_pids: Array = []) -> Dictionary:
	# A bound process inspector is authoritative: never fall through to the
	# real OS process table, which can race an injected deterministic fixture.
	if process_inspector.is_valid():
		var procs = process_inspector.call()
		if procs is Array:
			for item in procs:
				if not (item is Dictionary):
					continue
				var pid := int(item.get("pid", 0))
				if pid > 0 and not preexisting_pids.has(pid):
					return {"detected": true, "game_pid": pid, "source": "test_inspector_di"}
		return {"detected": false, "game_pid": 0, "source": "test_inspector_di"}
	if game_process_detector.is_valid():
		var dres = game_process_detector.call()
		if dres is Dictionary:
			return {
				"detected": bool(dres.get("detected", false)),
				"game_pid": int(dres.get("game_pid", 0)),
				"source": "test_detector_di",
			}
		return {"detected": bool(dres), "game_pid": 0, "source": "test_detector_di"}
	if OS.get_name() == "Windows":
		var pout: Array = []
		var prc := OS.execute("tasklist", ["/FI", "IMAGENAME eq battlezone2.exe", "/FO", "CSV", "/NH"], pout, true)
		if prc == 0 and not pout.is_empty():
			for raw_line in str(pout[0]).split("\n"):
				var line := raw_line.strip_edges()
				if line.to_lower().begins_with("\"battlezone2.exe\""):
					var cols := line.split("\",\"")
					var gpid := int(cols[1].replace("\"", "").strip_edges()) if cols.size() >= 2 else 0
					if gpid > 0:
						return {"detected": true, "game_pid": gpid, "source": "os_tasklist"}
	return {"detected": false, "game_pid": 0, "source": "os_tasklist"}


## Inspect genuine mission load & resource probe evidence from disk (startup log /
## session-bound Lua observation) or an explicit test DI `mission_observer`.
## NEVER trusts untrusted caller option dictionaries.
func _observe_mission_and_probe(sess: RefCounted) -> Dictionary:
	if mission_observer.is_valid():
		var mres = mission_observer.call(sess)
		if mres is Dictionary:
			return {
				"mission_observed": bool(mres.get("mission_observed", str(mres.get("mission_loaded_at", "")) != "")),
				"mission_loaded_at": str(mres.get("mission_loaded_at", "")),
				"resource_probe_confirmed": bool(mres.get("resource_probe_confirmed", false)),
				"startup_log_path": str(mres.get("startup_log_path", str(sess.mount_plan.get("startup_log_path", "")))),
				"source": "test_observer_di",
			}
	var log_path := str(sess.mount_plan.get("startup_log_path", ""))
	var mission_observed := false
	var mission_loaded_at := ""
	if log_path != "" and FileAccess.file_exists(log_path):
		var log_txt := FileAccess.get_file_as_string(log_path)
		if log_txt.contains("SHAMAN_STATE:") and log_txt.contains(str(sess.session_id)):
			mission_observed = true
			mission_loaded_at = Time.get_datetime_string_from_system()
	var obs_path := str(sess.observation_expected_path)
	var resource_probe_confirmed := false
	if obs_path != "" and FileAccess.file_exists(obs_path):
		var oj := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(obs_path))
		if bool(oj.get("ok", false)) and oj.get("data", null) is Dictionary:
			var od: Dictionary = oj.get("data", {})
			if str(od.get("session_id", "")) == str(sess.session_id) and str(od.get("launch_nonce", "")) == str(sess.launch_nonce):
				if not mission_observed:
					mission_observed = true
					mission_loaded_at = Time.get_datetime_string_from_system()
				if bool(od.get("resources_mounted", false)) and (str(sess.mount_marker) == "" or str(od.get("mount_marker", "")) == str(sess.mount_marker)):
					resource_probe_confirmed = true
	return {
		"mission_observed": mission_observed,
		"mission_loaded_at": mission_loaded_at,
		"resource_probe_confirmed": resource_probe_confirmed,
		"startup_log_path": log_path,
		"source": "disk_inspection",
	}


## Step 3: Launch via STEAM_MANAGED or prepare durable OPERATOR_MANUAL handoff.
## Never modifies BZ2R and never auto-spawns BZCC unless `execute_process = true`
## is explicitly requested (or a test `process_launcher` is bound).
func launch(session_id: String, options: Dictionary = {}) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "state": "REJECTED", "reason": "UNKNOWN_SESSION", "error": "session not found in ledger: " + session_id}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "state": "REJECTED", "reason": "INVALID_SESSION", "error": "cannot deserialize session"}

	# P1-NATIVE-04: Fail-closed when preflight_passed or launch_eligible is missing.
	if not record.has("preflight_passed") or not record.has("launch_eligible"):
		return {
			"ok": false,
			"state": "REJECTED",
			"reason": "PREFLIGHT_STATE_MISSING",
			"launch_rejected": true,
			"error": "LAUNCH_REJECTED: persisted session missing preflight state (fail-closed)",
		}
	var is_diag := str(record.get("reason", "")) == "DIAGNOSTIC_ONLY" or str(record.get("state", "")) == "STAGED_DIAGNOSTIC"
	var stage_eligible := bool(record.get("stage_eligible", record.get("preflight_passed", false)))
	if not bool(record.get("preflight_passed", false)) or not stage_eligible or is_diag:
		var rej_reason := str(record.get("reason", "LAUNCH_REJECTED"))
		if rej_reason == "" or rej_reason == "DIAGNOSTIC_ONLY":
			rej_reason = "LAUNCH_REJECTED"
		return {
			"ok": false,
			"state": "REJECTED",
			"reason": rej_reason,
			"launch_rejected": true,
			"error": "LAUNCH_REJECTED: preflight not passed or diagnostic-only session (" + rej_reason + ")",
		}

	if str(sess.stage_manifest_path) == "" or not FileAccess.file_exists(str(sess.stage_manifest_path)):
		return {"ok": false, "state": "REJECTED", "reason": "NOT_STAGED", "launch_rejected": true, "error": "stage the experiment before launching"}

	# P0-02 / N-05 / N-D10 / NL-04: Re-verify staged files immediately before launch.
	var stg_check := _verify_staged_integrity_before_launch(sess)
	if not bool(stg_check.get("ok", false)):
		var mod_reason := str(stg_check.get("reason", "STAGE_MODIFIED_AFTER_PREFLIGHT"))
		sess.add_checkpoint("FAILED", "Stage integrity check failed before launch: " + str(stg_check.get("detail", mod_reason)))
		record["state"] = "FAILED"
		record["launch_eligible"] = false
		record["reason"] = mod_reason
		if monitors.has(session_id):
			var mon_f = monitors[session_id]
			mon_f.state = ProcessMonitorScript.STATE_FAILED
			mon_f.reason = mod_reason
			mon_f.active = false
			record["monitor"] = mon_f.to_dict()
			_save_monitors()
		record["session"] = sess.to_dict()
		record["updated_at"] = Time.get_datetime_string_from_system()
		_persist_session(session_id, record)
		return {"ok": false, "state": "REJECTED", "reason": mod_reason, "launch_rejected": true, "detail": str(stg_check.get("detail", ""))}

	var disc: Dictionary = record.get("discovery", {})
	var pre: Dictionary = record.get("preflight", {})
	var launch_mode := str(record.get("launch_mode", pre.get("launch_mode", "CUSTOM_CONFIG")))
	var route := str(options.get("route_override", pre.get("launch_route", sess.launch_route)))
	if bool(options.get("manual_handoff", false)):
		route = "OPERATOR_MANUAL"
	if route == "" or route == "UNSUPPORTED":
		sess.add_checkpoint("BLOCKED", "Launch refused: route is UNSUPPORTED")
		record["state"] = "BLOCKED"
		record["reason"] = str(pre.get("reason", "UNSUPPORTED_LAUNCH_ROUTE"))
		record["session"] = sess.to_dict()
		record["updated_at"] = Time.get_datetime_string_from_system()
		_persist_session(session_id, record)
		return {"ok": false, "state": "BLOCKED", "route": "UNSUPPORTED", "reason": str(record.reason)}

	var mission_bzn := str(sess.mission_basename) + ".bzn"
	var include_logconsole := bool(options.get("include_logconsole", false))
	var cmd: Dictionary = NativeAdapterScript.build_launch_command(route, disc, str(sess.config_path), mission_bzn, include_logconsole, launch_mode)
	var now := Time.get_datetime_string_from_system()

	if route == "OPERATOR_MANUAL" or route == "STEAM_LAUNCH_OPTIONS":
		var cfg_diag: Dictionary = cmd.get("config_diagnostics", {}) if cmd.get("config_diagnostics", {}) is Dictionary else {}
		var cfg_arg := str(cfg_diag.get("config_arg", str(sess.config_path).replace("/", "\\")))
		var rootdir_handoff: Dictionary = pre.get("rootdir_handoff", {}) if pre.get("rootdir_handoff", {}) is Dictionary else {}
		if rootdir_handoff.is_empty() and launch_mode != "STOCK_ADDON" and not bool(cfg_diag.get("ok", false)):
			rootdir_handoff = NativeAdapterScript.prepare_rootdir_config_handoff(str(sess.config_path), str(disc.get("game_root", NativeAdapterScript.DEFAULT_GAME_ROOT)))
		var flags_prefix := "/nointro /win /logconsole" if include_logconsole else "/nointro /win"
		var launch_opts_line := str(cmd.get("launch_options_text", "%s /config \"%s\" \"%s\"" % [flags_prefix, cfg_arg, mission_bzn]))
		var instr_lines := PackedStringArray([
			"BZ_ODF_SHAMAN Native Experiment Operator Handoff",
			"session_id=" + str(sess.session_id),
			"launch_nonce=" + str(sess.launch_nonce),
			"stage_root=" + str(sess.stage_root),
			"launch_mode=" + launch_mode,
			"route=" + route,
			"steam_app_id=" + NativeAdapterScript.STEAM_APP_ID,
			"config_path=" + str(sess.config_path).replace("/", "\\"),
			"config_arg=" + cfg_arg,
			"config_compatibility=" + str(cfg_diag.get("code", "")),
			"rootdir_destination=" + str(rootdir_handoff.get("destination_path", "")),
			"rootdir_config_sha256=" + str(rootdir_handoff.get("sha256", "")),
			"rootdir_collision=" + str(bool(rootdir_handoff.get("collision_detected", false))),
			"mission_bzn=" + mission_bzn,
			"launch_options=" + launch_opts_line,
			"observation_expected_path=" + str(sess.observation_expected_path),
			"instructions=" + str(cmd.get("instructions", launch_opts_line)),
		])
		var instr_path := str(sess.stage_root).path_join("operator_instructions.txt")
		var instr_res: Dictionary = {"ok": false, "error": "injected operator_instructions.txt write failure"} if fault_fail_operator_instructions_write else WorkspaceStore.atomic_write_abs(instr_path, "\n".join(instr_lines).to_utf8_buffer())
		if not bool(instr_res.get("ok", false)):
			return _fail_transition(session_id, record, "AWAITING_OPERATOR", "operator_instructions.txt write failed")
		# The instructions file is SHAMAN's own launch artifact: register it in
		# the stage manifest so hash-verified cleanup owns it instead of
		# classifying it as a foreign survivor (T-26 route).
		var instr_manifest_path := str(sess.stage_root).path_join("stage_manifest.json")
		if FileAccess.file_exists(instr_manifest_path):
			var im_res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(instr_manifest_path))
			if bool(im_res.get("ok", false)) and (im_res.get("data", null) is Dictionary):
				var im: Dictionary = im_res.get("data", {})
				var im_files: Array = im.get("files", []) if im.get("files", []) is Array else []
				var already := false
				for it in im_files:
					if it is Dictionary and str((it as Dictionary).get("rel", "")) == "operator_instructions.txt":
						already = true
				if not already:
					im_files.append({
						"rel": "operator_instructions.txt",
						"md5": WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(instr_path)),
						"bytes": FileAccess.get_file_as_bytes(instr_path).size(),
					})
					im["files"] = im_files
					WorkspaceStore.atomic_write_abs(instr_manifest_path, JSON.stringify(im, "  ").to_utf8_buffer())
		sess.add_checkpoint("AWAITING_OPERATOR", "Operator manual handoff written to " + instr_path)
		record["state"] = "AWAITING_OPERATOR"
		record["evidence_state"] = "LAUNCH_REQUESTED"
		record["launch_route"] = route
		record["reason"] = str(pre.get("reason", "OPERATOR_MANUAL_HANDOFF"))
		record["updated_at"] = now
		record["launch"] = {
			"mode": route,
			"launch_mode": launch_mode,
			"executed": false,
			"requested_at": now,
			"command": cmd,
			"rootdir_handoff": rootdir_handoff,
			"instructions_path": instr_path,
			"observation_expected_path": str(sess.observation_expected_path),
		}
		record["session"] = sess.to_dict()
		var manual_commit := _commit_transition(session_id, record, "AWAITING_OPERATOR", "Operator handoff written")
		if not bool(manual_commit.get("ok", false)):
			manual_commit["session_id"] = session_id
			manual_commit["route"] = route
			return manual_commit
		return {
			"ok": true,
			"state": "AWAITING_OPERATOR",
			"evidence_state": "LAUNCH_REQUESTED",
			"route": route,
			"launch_mode": launch_mode,
			"reason": str(record.reason),
			"command": cmd,
			"rootdir_handoff": rootdir_handoff,
			"instructions_path": instr_path,
			"observation_expected_path": str(sess.observation_expected_path),
			"session_id": session_id,
		}

	# P0-NATIVE-01: Actual game launch MUST NOT proceed when launch_eligible or
	# config_compatible is false (e.g. unresolved CONFIG_REQUIRES_ROOTDIR_PLACEMENT).
	var live_cfg_diag: Dictionary = cmd.get("config_diagnostics", {}) if cmd.get("config_diagnostics", {}) is Dictionary else {}
	var cfg_compat := bool(record.get("config_compatible", bool(live_cfg_diag.get("ok", false)))) and bool(live_cfg_diag.get("ok", false))
	if not bool(record.get("launch_eligible", false)) or not cfg_compat:
		var blk_reason := str(live_cfg_diag.get("code", "")) if not cfg_compat else str(record.get("reason", "LAUNCH_REJECTED"))
		if blk_reason == "" or blk_reason == "CONFIG_IN_ROOTDIR":
			blk_reason = str(record.get("reason", "LAUNCH_REJECTED"))
		if blk_reason == "":
			blk_reason = "LAUNCH_REJECTED"
		return {
			"ok": false,
			"state": "REJECTED",
			"route": route,
			"launch_mode": launch_mode,
			"reason": blk_reason,
			"launch_rejected": true,
			"executed": false,
			"command": cmd,
			"error": "LAUNCH_REJECTED: session is not launch-eligible (%s); use manual_handoff or a compatible config/STOCK_ADDON route" % blk_reason,
		}

	if route == "STEAM_MANAGED":
		var stg_arg := {
			"stage": str(sess.stage_root),
			"stage_id": str(sess.stage_id),
			"stage_manifest": str(sess.stage_manifest_path),
			"staged": (record.get("evidence", {}) as Dictionary).get("staged", []),
			"evidence": record.get("evidence", {}),
		}
		var receipt: Dictionary = NativeAdapterScript.begin_trusted_session(stg_arg, disc, sess.scenario, "STEAM_MANAGED", sess)
		sess.add_checkpoint("LAUNCH_REQUESTED", "Prepared STEAM_MANAGED launch for AppID 624970")
		record["state"] = "LAUNCH_REQUESTED"
		record["evidence_state"] = "LAUNCH_REQUESTED"
		record["launch_route"] = "STEAM_MANAGED"
		record["updated_at"] = now
		record["launch"] = {
			"mode": "STEAM_MANAGED",
			"executed": false,
			"requested_at": now,
			"command": cmd,
			"receipt": receipt,
			"process_id": 0,
		}
		record["session"] = sess.to_dict()
		var launch_req_commit := _commit_transition(session_id, record, "LAUNCH_REQUESTED", "Prepared STEAM_MANAGED launch")
		if not bool(launch_req_commit.get("ok", false)):
			launch_req_commit["session_id"] = session_id
			launch_req_commit["route"] = "STEAM_MANAGED"
			launch_req_commit["launch_rejected"] = true
			return launch_req_commit

		# P1-03: snapshot game PIDs BEFORE spawning Steam so a game process
		# started by this launch is never mistaken for a preexisting one.
		var launch_options := options.duplicate(true)
		if not launch_options.has("preexisting_game_pids"):
			launch_options["preexisting_game_pids"] = _capture_preexisting_game_pids()
		var execute_proc := bool(options.get("execute_process", false))
		var pid := 0
		var exit_code := -1
		var game_detected := false
		var game_pid := 0
		var mission_observed := false
		var resource_probe_confirmed := false
		if execute_proc:
			var exe := str(cmd.get("executable", ""))
			var args: Array = cmd.get("args", [])
			if process_launcher.is_valid():
				var lres = process_launcher.call(exe, args)
				if lres is Dictionary:
					pid = int(lres.get("pid", 0))
					exit_code = int(lres.get("exit_code", 0))
			elif exe != "" and FileAccess.file_exists(exe):
				pid = OS.create_process(exe, PackedStringArray(args))
				exit_code = 0 if pid > 0 else -1
			if pid > 0:
				# P1-NATIVE-05: Steam PID alone only proves STEAM_PROCESS_STARTED, never GAME_PROCESS_DETECTED.
				var det_info := _detect_bzcc_game_process(launch_options.get("preexisting_game_pids", []))
				game_detected = bool(det_info.get("detected", false))
				game_pid = int(det_info.get("game_pid", 0)) if game_detected else 0
				if game_detected:
					var obs_info := _observe_mission_and_probe(sess)
					mission_observed = bool(obs_info.get("mission_observed", false))
					var mload_at := str(obs_info.get("mission_loaded_at", ""))
					resource_probe_confirmed = bool(obs_info.get("resource_probe_confirmed", false))
					var slog_path := str(obs_info.get("startup_log_path", ""))
					NativeAdapterScript.confirm_trusted_execution(
						session_id, game_pid if game_pid > 0 else pid, now, "STEAM_MANAGED", args, exit_code, mload_at,
						slog_path, resource_probe_confirmed
					)
					var new_state := "GAME_PROCESS_DETECTED"
					if mission_observed and resource_probe_confirmed:
						new_state = "RESOURCE_PROBE_CONFIRMED"
					elif mission_observed:
						new_state = "MISSION_OBSERVED"
					sess.add_checkpoint(new_state, "STEAM_MANAGED game process detected pid=%d (mission=%s probe=%s)" % [game_pid, str(mission_observed), str(resource_probe_confirmed)])
					record["state"] = new_state
					record["evidence_state"] = new_state
				else:
					sess.add_checkpoint("STEAM_PROCESS_STARTED", "Steam launcher started (pid=%d); battlezone2.exe not detected" % pid)
					record["state"] = "STEAM_PROCESS_STARTED"
					record["evidence_state"] = "STEAM_PROCESS_STARTED"
				(record["launch"] as Dictionary)["executed"] = true
				(record["launch"] as Dictionary)["process_id"] = pid
				(record["launch"] as Dictionary)["game_process_detected"] = game_detected
				(record["launch"] as Dictionary)["game_pid"] = game_pid
				(record["launch"] as Dictionary)["mission_observed"] = mission_observed
				(record["launch"] as Dictionary)["resource_probe_confirmed"] = resource_probe_confirmed
				(record["launch"] as Dictionary)["exit_code"] = exit_code
				record["session"] = sess.to_dict()
				record["updated_at"] = Time.get_datetime_string_from_system()
				var post_launch_commit := _commit_transition(session_id, record, str(record["state"]), "Launch process outcome persisted")
				if not bool(post_launch_commit.get("ok", false)):
					post_launch_commit["session_id"] = session_id
					post_launch_commit["route"] = "STEAM_MANAGED"
					return post_launch_commit
				var mstart := _start_monitor(session_id, sess, disc, launch_options, true)
				if not bool(mstart.get("ok", false)):
					return mstart
					if not bool(mstart.get("ok", false)):
						return mstart
			else:
				sess.add_checkpoint("FAILED", "STEAM_MANAGED launch failed to spawn process")
				record["state"] = "FAILED"
				record["evidence_state"] = "FAILED"
				record["reason"] = "GAME_PROCESS_NOT_STARTED"
				record["session"] = sess.to_dict()
				record["updated_at"] = Time.get_datetime_string_from_system()
				_persist_session(session_id, record)
				return {"ok": false, "state": "FAILED", "route": "STEAM_MANAGED", "reason": "GAME_PROCESS_NOT_STARTED", "session_id": session_id}

		return {
			"ok": true,
			"state": str(record.state),
			"evidence_state": str(record.get("evidence_state", record.state)),
			"route": "STEAM_MANAGED",
			"command": cmd,
			"receipt": receipt,
			"process_id": pid,
			"game_process_detected": game_detected,
			"game_pid": game_pid,
			"mission_observed": mission_observed,
			"resource_probe_confirmed": resource_probe_confirmed,
			"executed": pid > 0,
			"session_id": session_id,
		}

	return {"ok": false, "state": "FAILED", "route": route, "reason": "UNSUPPORTED_LAUNCH_ROUTE"}


## Validate a parsed Lua observation dictionary against the controlled Lua
## measurement contract for `session`.
static func validate_lua_measurement_contract(obs: Dictionary, session: RefCounted) -> Dictionary:
	var errors: Array[String] = []
	if obs.is_empty():
		return {"ok": false, "reason": "EMPTY_OBSERVATION", "errors": ["observation is empty"], "lua_state": ""}
	for f in REQUIRED_LUA_CONTRACT_FIELDS:
		if not obs.has(f):
			errors.append("missing required Lua contract field: " + f)
	var lua_state := str(obs.get("state", ""))
	if not NativeAdapterScript.LUA_EXPERIMENT_STATES.has(lua_state):
		errors.append("unknown Lua state: " + lua_state)
	if session != null:
		if str(obs.get("session_id", "")) != str(session.session_id):
			errors.append("Lua session_id '%s' != expected '%s'" % [str(obs.get("session_id", "")), str(session.session_id)])
		if str(obs.get("launch_nonce", "")) != str(session.launch_nonce):
			errors.append("Lua launch_nonce '%s' != expected '%s'" % [str(obs.get("launch_nonce", "")), str(session.launch_nonce)])
		if str(session.mount_marker) != "" and str(obs.get("mount_marker", "")) != str(session.mount_marker):
			errors.append("Lua mount_marker '%s' != expected '%s'" % [str(obs.get("mount_marker", "")), str(session.mount_marker)])
	if not bool(obs.get("resources_mounted", false)):
		errors.append("Lua reported resources_mounted=false")
	var hp_before := float(obs.get("hp_before", 0.0))
	var hp_after := float(obs.get("hp_after", 0.0))
	var hp_max := float(obs.get("hp_max", 0.0))
	var dmg := float(obs.get("damage", 0.0))
	var tps := int(obs.get("tps", 0))
	if lua_state == "MEASUREMENT_COMPLETE":
		if hp_max <= 0.0:
			errors.append("invalid hp_max <= 0")
		if tps <= 0:
			errors.append("invalid tps <= 0")
		if absf((hp_before - hp_after) - dmg) > 0.05:
			errors.append("damage %.3f does not match hp_before - hp_after (%.3f)" % [dmg, hp_before - hp_after])
	var reason := ""
	if lua_state == "TIMEOUT":
		reason = "LUA_MEASUREMENT_TIMEOUT"
	elif lua_state == "FAILED":
		reason = "LUA_MEASUREMENT_FAILED"
	elif not errors.is_empty():
		reason = "LUA_CONTRACT_VIOLATION"
	return {
		"ok": errors.is_empty() and lua_state == "MEASUREMENT_COMPLETE",
		"contract_valid": errors.is_empty(),
		"lua_state": lua_state,
		"reason": reason,
		"errors": errors,
	}


## Step 4: Collect an on-disk observation artifact for `session_id` (works even
## after an application restart via the durable ledger), validate the controlled
## Lua measurement contract, compare against Godot prediction, and persist evidence.
func collect_observation(session_id: String, observation_path_override: String = "") -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "reason": "UNKNOWN_SESSION", "error": "session not found in ledger: " + session_id}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "reason": "INVALID_SESSION", "error": "cannot deserialize session"}

	var obs_path := observation_path_override.strip_edges()
	if obs_path == "":
		obs_path = str(sess.observation_expected_path)
	if obs_path == "" or not FileAccess.file_exists(obs_path):
		return {
			"ok": false,
			"state": str(record.get("state", "AWAITING_OPERATOR")),
			"reason": "OBSERVATION_ARTIFACT_MISSING",
			"error": "observation file not found yet: " + obs_path,
			"expected_path": obs_path,
		}

	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(obs_path))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		sess.add_checkpoint("FAILED", "Corrupt observation JSON: " + str(jres.get("error", "")))
		record["state"] = "FAILED"
		record["reason"] = "OBSERVATION_JSON_INVALID"
		record["session"] = sess.to_dict()
		record["updated_at"] = Time.get_datetime_string_from_system()
		_persist_session(session_id, record)
		return {"ok": false, "state": "FAILED", "reason": "OBSERVATION_JSON_INVALID", "error": str(jres.get("error", ""))}

	var obs_dict: Dictionary = jres.get("data", {})
	var contract := validate_lua_measurement_contract(obs_dict, sess)
	if str(contract.get("lua_state", "")) == "TIMEOUT" or str(contract.get("lua_state", "")) == "FAILED":
		var fail_state := str(contract.get("lua_state", "FAILED"))
		sess.add_checkpoint(fail_state, "Lua reported terminal state " + fail_state)
		record["state"] = fail_state
		record["reason"] = str(contract.get("reason", fail_state))
		record["session"] = sess.to_dict()
		record["updated_at"] = Time.get_datetime_string_from_system()
		_persist_session(session_id, record)
		return {
			"ok": false,
			"state": fail_state,
			"reason": str(contract.get("reason", fail_state)),
			"contract": contract,
			"verified": false,
		}
	if not bool(contract.get("ok", false)):
		sess.add_checkpoint("FAILED", "Lua measurement contract violation: " + "; ".join(contract.get("errors", [])))
		record["state"] = "FAILED"
		record["reason"] = "LUA_CONTRACT_VIOLATION"
		record["session"] = sess.to_dict()
		record["updated_at"] = Time.get_datetime_string_from_system()
		_persist_session(session_id, record)
		return {
			"ok": false,
			"state": "FAILED",
			"reason": "LUA_CONTRACT_VIOLATION",
			"contract": contract,
			"verified": false,
		}

	var ev: Dictionary = (record.get("evidence", {}) as Dictionary).duplicate(true)
	if ev.is_empty() and str(sess.evidence_path) != "" and FileAccess.file_exists(str(sess.evidence_path)):
		var ej := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(str(sess.evidence_path)))
		if bool(ej.get("ok", false)) and ej.get("data", null) is Dictionary:
			ev = ej.get("data", {})

	var pred: Dictionary = sess.godot_prediction if not (sess.godot_prediction as Dictionary).is_empty() else (ev.get("godot_prediction", {}) as Dictionary)
	var trusted := NativeAdapterScript.get_trusted_session(session_id)
	var updated_ev: Dictionary
	var is_unattested := false
	if bool(obs_dict.get("synthetic", false)):
		updated_ev = ev.duplicate(true)
		updated_ev["status"] = "FAILED"
		updated_ev["capture_error"] = "SYNTHETIC_OBSERVATION_REJECTED"
	elif not trusted.is_empty() and bool(trusted.get("execution_confirmed", false)) and bool(trusted.get("resources_mounted", false)):
		updated_ev = NativeAdapterScript.capture_trusted_observation(ev, session_id, obs_path, pred, "bzcc_luamission_writetofile")
	else:
		# Recovered across restart, OPERATOR_MANUAL, or missing mission/resource probe confirmation:
		# honest COMPARISON_COMPLETE (unattested by live in-process PID + mission/probe confirmation).
		is_unattested = true
		var obs_copy := obs_dict.duplicate(true)
		obs_copy["provenance"] = "operator_manual_collection"
		obs_copy["unattested"] = true
		obs_copy["measurement_method"] = str(obs_copy.get("measurement_method", "GetCurHealth_delta"))
		updated_ev = NativeAdapterScript.record_observation_and_compare(ev, obs_copy, pred, [obs_path])
		updated_ev["status"] = "COMPARISON_COMPLETE"
		updated_ev["unattested"] = true

	var verdict: Dictionary = NativeAdapterScript.validate_native_evidence(updated_ev)
	var final_state := "NATIVE_VERIFIED" if bool(verdict.get("verified", false)) else str(updated_ev.get("status", "COMPARISON_COMPLETE"))
	var cap_err := str(updated_ev.get("capture_error", ""))
	if cap_err != "":
		final_state = "FAILED"

	if str(sess.evidence_path) != "":
		var ev_res: Dictionary = {"ok": false, "error": "injected native_evidence.json write failure"} if fault_fail_evidence_write else WorkspaceStore.atomic_write_abs(str(sess.evidence_path), JSON.stringify(updated_ev, "  ").to_utf8_buffer())
		if not bool(ev_res.get("ok", false)):
			var fev: Dictionary = _fail_transition(session_id, record, final_state, "native_evidence.json write failed: " + str(ev_res.get("error", "")))
			fev["verified"] = false
			return fev

	sess.add_checkpoint(final_state, "Collected observation %s (verified=%s)" % [obs_path.get_file(), str(verdict.get("verified", false))])
	record["state"] = final_state
	record["evidence_state"] = final_state
	record["reason"] = cap_err
	record["evidence"] = updated_ev
	record["verdict"] = verdict
	record["session"] = sess.to_dict()
	record["updated_at"] = Time.get_datetime_string_from_system()
	var obs_commit := _commit_transition(session_id, record, final_state, "Observation collected and compared")
	if not bool(obs_commit.get("ok", false)):
		obs_commit["session_id"] = session_id
		obs_commit["verified"] = false
		return obs_commit

	return {
		"ok": final_state == "NATIVE_VERIFIED" or final_state == "COMPARISON_COMPLETE",
		"state": final_state,
		"evidence_state": final_state,
		"reason": cap_err,
		"verified": bool(verdict.get("verified", false)),
		"unattested": is_unattested or not bool(verdict.get("verified", false)),
		"synthetic": bool(verdict.get("synthetic", true)),
		"contract": contract,
		"evidence": updated_ev,
		"verdict": verdict,
		"session_id": session_id,
	}


## P1-03: Capture PIDs of battlezone2.exe processes already running before our
## Steam launcher spawns a new one. These are never attributed to this session.
func _capture_preexisting_game_pids() -> Array:
	var out: Array = []
	if process_inspector.is_valid():
		var procs = process_inspector.call()
		if procs is Array:
			for item in procs:
				if item is Dictionary and str(item.get("name", "")).to_lower() == "battlezone2.exe":
					var pid := int(item.get("pid", 0))
					if pid > 0:
						out.append(pid)
		return out
	if OS.get_name() == "Windows":
		var pout: Array = []
		var prc := OS.execute("tasklist", ["/FI", "IMAGENAME eq battlezone2.exe", "/FO", "CSV", "/NH"], pout, true)
		if prc == 0:
			for raw_line in pout:
				var line := str(raw_line).strip_edges()
				if line.to_lower().begins_with("\"battlezone2.exe\""):
					var cols := line.split("\",\"")
					var pid := int(cols[1].replace("\"", "").strip_edges()) if cols.size() >= 2 else 0
					if pid > 0:
						out.append(pid)
	return out


func _save_monitors() -> Dictionary:
	if sessions.is_empty():
		return {"ok": true, "status": STATUS_MONITOR_STATE_SAVED, "recovery_pending": false, "error": ""}
	var doc := {"schema": LEDGER_SCHEMA, "updated": Time.get_datetime_string_from_system(), "monitors": {}}
	for sid in monitors:
		doc["monitors"][sid] = (monitors[sid] as RefCounted).to_dict()
	var wres: Dictionary = {"ok": false, "error": "injected process_monitors.json write failure"} if fault_fail_monitor_persist else WorkspaceStore.atomic_write_abs(
		ledger_dir().path_join("process_monitors.json"), JSON.stringify(doc, "  ").to_utf8_buffer()
	)
	if not bool(wres.get("ok", false)):
		return {
			"ok": false,
			"status": STATUS_MONITOR_PERSIST_FAILED,
			"reason": STATUS_MONITOR_PERSIST_FAILED,
			"recovery_pending": true,
			"state": STATE_RECOVERY_PENDING,
			"persist_failed": true,
			"error": str(wres.get("error", "process_monitors.json write failed")),
		}
	return {"ok": true, "status": STATUS_MONITOR_STATE_SAVED, "recovery_pending": false, "error": ""}


func _fail_monitor_persist(session_id: String, monitor, save_res: Dictionary) -> Dictionary:
	var err := str(save_res.get("error", "process_monitors.json write failed"))
	if monitor != null:
		monitor.last_error = err
		monitor.reason = STATUS_MONITOR_PERSIST_FAILED
	var record: Dictionary = sessions.get(session_id, {})
	if not record.is_empty():
		record["recovery_pending"] = true
		record["monitor_persist_status"] = STATUS_MONITOR_PERSIST_FAILED
		record["last_error"] = err
		sessions[session_id] = record
	var out: Dictionary = monitor.result() if monitor != null else {}
	out["ok"] = false
	out["session_id"] = session_id
	out["status"] = STATUS_MONITOR_PERSIST_FAILED
	out["state"] = STATE_RECOVERY_PENDING
	out["reason"] = STATUS_MONITOR_PERSIST_FAILED
	out["recovery_pending"] = true
	out["persist_failed"] = true
	out["verified"] = false
	out["native_verified"] = false
	out["error"] = err
	return out


func _start_monitor(session_id: String, sess: RefCounted, disc: Dictionary, options: Dictionary, pre_captured: bool) -> Dictionary:
	var preexisting: Array = options.get("preexisting_game_pids", []) if options.get("preexisting_game_pids", []) is Array else []
	if not pre_captured:
		preexisting = _capture_preexisting_game_pids()
	var monitor = ProcessMonitorScript.create(session_id, disc, options, preexisting)
	var record: Dictionary = sessions.get(session_id, {})
	# Wall clock for production; an explicitly injected origin selects the
	# relative test clock so no real waits are needed.
	monitor.started_at_s = float(options.get("monitor_started_at_s", Time.get_unix_time_from_system()))
	monitor.relative_clock = options.has("monitor_started_at_s") or (monitor.started_at_s == 0.0)
	record["monitor"] = monitor.to_dict()
	sessions[session_id] = record
	monitors[session_id] = monitor
	var ms := _save_monitors()
	if not bool(ms.get("ok", false)):
		return _fail_monitor_persist(session_id, monitor, ms)
	return {"ok": true, "session_id": session_id, "state": monitor.state, "active": monitor.active, "monitor_persist_status": STATUS_MONITOR_STATE_SAVED}


func _persist_monitor_state(session_id: String, monitor, record: Dictionary, state: String) -> bool:
	monitor.state = state
	record["monitor"] = monitor.to_dict()
	record["state"] = state
	record["evidence_state"] = state
	var commit := _commit_transition(session_id, record, state, "NativeProcessMonitor state=" + state)
	return bool(commit.get("ok", false))


## Advance an active monitor by one bounded poll. `now_s` is an injectable clock
## so tests never depend on real waits; when `observation_path` is omitted, the
## session-bound `observation_expected_path` is resolved automatically (P1-NATIVE-04).
## Monitor checkpoints persist on state changes and verify write results (P1-NATIVE-05).
func poll_monitor(session_id: String, now_s: float = -1.0, observation_path: String = "") -> Dictionary:
	if not monitors.has(session_id):
		return {"ok": false, "state": "NO_ACTIVE_MONITOR", "reason": "NO_ACTIVE_MONITOR", "active": false}
	var monitor = monitors[session_id]
	if not bool(monitor.active) or monitor.is_terminal():
		var d: Dictionary = monitor.result()
		d["ok"] = false
		d["reason"] = "MONITOR_NOT_ACTIVE"
		return d
	var prev_state := str(monitor.state)
	# Explicit now_s is a relative test clock; production poll uses wall time.
	var explicit_clock := now_s >= 0.0
	var t: float = now_s if explicit_clock else Time.get_unix_time_from_system()
	var origin: float = 0.0 if explicit_clock else monitor.started_at_s
	monitor.polls += 1
	if monitor.polls > monitor.max_polls or (t - origin) > monitor.timeout_s:
		var record: Dictionary = sessions.get(session_id, {})
		var commit := _commit_transition(session_id, record, "TIMEOUT", "Monitor bounded poll/timeout")
		if not bool(commit.get("ok", false)):
			commit["session_id"] = session_id
			return commit
		monitor.timeout()
		var ms_to := _save_monitors()
		if not bool(ms_to.get("ok", false)):
			return _fail_monitor_persist(session_id, monitor, ms_to)
		var r_to: Dictionary = monitor.result()
		r_to["monitor_persist_status"] = STATUS_MONITOR_STATE_SAVED
		return r_to

	if monitor.state in ["STEAM_PROCESS_STARTED", "MONITOR_ARMED"]:
		var det: Dictionary = monitor.detect_game(process_inspector, game_process_detector)
		if bool(det.get("detected", false)):
			var record0: Dictionary = sessions.get(session_id, {})
			var next_proc_state := str(monitor.state)
			if not _persist_monitor_state(session_id, monitor, record0, next_proc_state):
				var failed := _fail_transition(session_id, record0, next_proc_state, "checked transition persist failed")
				failed["session_id"] = session_id
				return failed
			var ms_g := _save_monitors()
			if not bool(ms_g.get("ok", false)):
				return _fail_monitor_persist(session_id, monitor, ms_g)
			var r_g: Dictionary = monitor.result()
			r_g["monitor_persist_status"] = STATUS_MONITOR_STATE_SAVED
			return r_g

	elif monitor.state in ["GAME_PROCESS_DETECTED", "GAME_PROCESS_VERIFIED", "GAME_PROCESS_CANDIDATE", "MISSION_OBSERVED", "RESOURCE_PROBE_CONFIRMED"]:
		var sess = NativeSessionScript.from_dict((sessions.get(session_id, {}) as Dictionary).get("session", {}))
		if sess == null:
			return {"ok": false, "state": "INVALID_SESSION", "reason": "INVALID_SESSION", "active": false}
		var probe := _observe_mission_and_probe(sess)
		monitor.apply_mission_probe(probe)
		var state_changed := str(monitor.state) != prev_state
		if state_changed:
			var record1: Dictionary = sessions.get(session_id, {})
			if not _persist_monitor_state(session_id, monitor, record1, monitor.state):
				var failed1 := _fail_transition(session_id, record1, monitor.state, "checked probe transition persist failed")
				failed1["session_id"] = session_id
				return failed1

		# P1-NATIVE-04 (NM-13..NM-16): For armed manual sessions, ONLY a verified
		# battlezone2.exe process (exe path + MD5 match) + session-bound mission &
		# marker probe may attest trusted execution. An unverified candidate PID
		# (GAME_PROCESS_CANDIDATE) NEVER earns trusted execution or NATIVE_VERIFIED!
		if bool(monitor.manual_armed) and bool(monitor.game_exe_verified) and bool(monitor.mission_observed) and bool(monitor.resource_probe_confirmed):
			var tr := NativeAdapterScript.get_trusted_session(session_id)
			if not tr.is_empty() and not bool(tr.get("execution_confirmed", false)):
				var rec_m: Dictionary = sessions.get(session_id, {})
				var lcmd_m: Dictionary = (rec_m.get("launch", {}) as Dictionary).get("command", {})
				var args_m: Array = lcmd_m.get("game_args", [str(sess.mission_basename) + ".bzn"])
				NativeAdapterScript.confirm_trusted_execution(
					session_id, int(monitor.game_pid), Time.get_datetime_string_from_system(),
					"OPERATOR_MANUAL", args_m, 0, str(monitor.mission_loaded_at),
					str(probe.get("startup_log_path", "")), true
				)

		# P1-NATIVE-04: Automatically resolve session-bound expected observation
		# path when caller did not supply an explicit override.
		var resolved_obs_path := observation_path.strip_edges()
		if resolved_obs_path == "":
			resolved_obs_path = str(sess.observation_expected_path).strip_edges()
		var obs_ready := resolved_obs_path != "" and FileAccess.file_exists(resolved_obs_path)
		if monitor.state == "RESOURCE_PROBE_CONFIRMED" and obs_ready:
			var obs_res := collect_observation(session_id, resolved_obs_path)
			var out: Dictionary = monitor.result()
			out["observation_path"] = resolved_obs_path
			out["observation_collected"] = bool(obs_res.get("ok", false))
			out["comparison_complete"] = bool(obs_res.get("comparison_complete", obs_res.get("ok", false)))
			var allow_verified := bool(obs_res.get("verified", false)) and (not bool(monitor.manual_armed) or bool(monitor.game_exe_verified))
			out["verified"] = allow_verified
			out["state"] = str(obs_res.get("state", monitor.state))
			if not allow_verified and out["state"] == "NATIVE_VERIFIED":
				out["state"] = "COMPARISON_COMPLETE"
			out["reason"] = str(obs_res.get("reason", out.get("reason", "")))
			out["native_verified"] = allow_verified
			if bool(obs_res.get("persist_failed", false)):
				out["persist_failed"] = true
				out["recovery_pending"] = true
			if not bool(obs_res.get("ok", false)) and str(obs_res.get("reason", "")) != "":
				# Foreign-session or corrupt observation rejected: keep monitor active
				# or record rejection without false completion.
				out["ok"] = false
				out["rejected_observation"] = true
				var ms_rej := _save_monitors()
				if not bool(ms_rej.get("ok", false)):
					return _fail_monitor_persist(session_id, monitor, ms_rej)
				out["monitor_persist_status"] = STATUS_MONITOR_STATE_SAVED
				return out
			monitor.finish_collection(out)
			var ms_col := _save_monitors()
			if not bool(ms_col.get("ok", false)):
				return _fail_monitor_persist(session_id, monitor, ms_col)
			out["monitor_persist_status"] = STATUS_MONITOR_STATE_SAVED
			return out

		if state_changed:
			var ms_st := _save_monitors()
			if not bool(ms_st.get("ok", false)):
				return _fail_monitor_persist(session_id, monitor, ms_st)
			var r_st: Dictionary = monitor.result()
			r_st["monitor_persist_status"] = STATUS_MONITOR_STATE_SAVED
			return r_st

	monitor.polls = int(monitor.polls)
	var r_idle: Dictionary = monitor.result()
	r_idle["monitor_persist_status"] = STATUS_MONITOR_STATE_SAVED
	return r_idle


## P1-NATIVE-04 (NM-11..NM-14): Arm non-blocking manual observation before an
## operator launches BZCC via Steam. Captures preexisting game PIDs, writes
## operator instructions, persists MONITOR_ARMED across restarts, and NEVER
## falsely claims the game launched or NATIVE_VERIFIED on arming alone.
func arm_manual_observation(session_id: String, options: Dictionary = {}) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "state": "REJECTED", "reason": "UNKNOWN_SESSION", "active": false}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "state": "REJECTED", "reason": "INVALID_SESSION", "active": false}
	if str(sess.stage_manifest_path) == "" or not FileAccess.file_exists(str(sess.stage_manifest_path)):
		return {"ok": false, "state": "REJECTED", "reason": "NOT_STAGED", "active": false, "error": "stage the experiment before arming manual observation"}
	var stg_check := _verify_staged_integrity_before_launch(sess)
	if not bool(stg_check.get("ok", false)):
		return {"ok": false, "state": "REJECTED", "reason": str(stg_check.get("reason", "STAGE_MODIFIED_AFTER_PREFLIGHT")), "active": false}

	# Ensure durable operator handoff instructions exist (AWAITING_OPERATOR).
	var handoff_res: Dictionary = {}
	if str(record.get("state", "")) != "AWAITING_OPERATOR" and str((record.get("launch", {}) as Dictionary).get("instructions_path", "")) == "":
		var h_opts := options.duplicate(true)
		h_opts["manual_handoff"] = true
		h_opts["execute_process"] = false
		handoff_res = launch(session_id, h_opts)
		if not bool(handoff_res.get("ok", false)):
			return handoff_res
		record = sessions[session_id]
		sess = NativeSessionScript.from_dict(record.get("session", {}))

	var disc: Dictionary = record.get("discovery", {})
	var preexisting: Array = (options.get("preexisting_game_pids", []) as Array).duplicate(true) if (options.has("preexisting_game_pids") and options.get("preexisting_game_pids", []) is Array) else _capture_preexisting_game_pids()
	var stg_arg := {
		"stage": str(sess.stage_root),
		"stage_id": str(sess.stage_id),
		"stage_manifest": str(sess.stage_manifest_path),
		"staged": (record.get("evidence", {}) as Dictionary).get("staged", []),
		"evidence": record.get("evidence", {}),
	}
	var receipt: Dictionary = NativeAdapterScript.begin_trusted_session(stg_arg, disc, sess.scenario, "OPERATOR_MANUAL", sess)
	var mon_opts := options.duplicate(true)
	mon_opts["preexisting_game_pids"] = preexisting
	var monitor = ProcessMonitorScript.create(session_id, disc, mon_opts, preexisting)
	monitor.state = ProcessMonitorScript.STATE_MONITOR_ARMED
	monitor.manual_armed = true
	monitor.arm_source = "OPERATOR_MANUAL"
	monitor.active = true
	monitor.started_at_s = float(mon_opts.get("monitor_started_at_s", Time.get_unix_time_from_system()))
	monitor.relative_clock = mon_opts.has("monitor_started_at_s") or (monitor.started_at_s == 0.0)
	record["monitor"] = monitor.to_dict()
	record["state"] = "MONITOR_ARMED"
	record["evidence_state"] = "MONITOR_ARMED"
	record["launch_route"] = "OPERATOR_MANUAL"
	record["manual_armed"] = true
	record["updated_at"] = Time.get_datetime_string_from_system()
	if record.get("launch", null) is Dictionary:
		(record["launch"] as Dictionary)["receipt"] = receipt
		(record["launch"] as Dictionary)["manual_armed"] = true
	var commit := _commit_transition(session_id, record, "MONITOR_ARMED", "Manual observation armed before operator Steam launch")
	if not bool(commit.get("ok", false)):
		commit["session_id"] = session_id
		commit["active"] = false
		return commit
	monitors[session_id] = monitor
	var ms := _save_monitors()
	if not bool(ms.get("ok", false)):
		return _fail_monitor_persist(session_id, monitor, ms)
	return {
		"ok": true,
		"session_id": session_id,
		"state": "MONITOR_ARMED",
		"active": true,
		"manual_armed": true,
		"game_launched": false,
		"verified": false,
		"preexisting_game_pids": preexisting.duplicate(true),
		"instructions_path": str((record.get("launch", {}) as Dictionary).get("instructions_path", "")),
		"command": (record.get("launch", {}) as Dictionary).get("command", {}),
		"observation_expected_path": str(sess.observation_expected_path),
		"monitor_persist_status": STATUS_MONITOR_STATE_SAVED,
	}


## P1-NATIVE-04 (NM-15): Explicitly import an operator-supplied observation JSON
## without live verified process attestation. Records OBSERVATION_IMPORTED ->
## COMPARISON_COMPLETE with unattested=true, verified=false (NEVER NATIVE_VERIFIED).
func import_manual_observation(session_id: String, observation_path: String) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "reason": "UNKNOWN_SESSION", "verified": false, "unattested": true}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "reason": "INVALID_SESSION", "verified": false, "unattested": true}
	# Ensure manual import NEVER claims in-process execution attestation.
	var prev_trusted := NativeAdapterScript.get_trusted_session(session_id)
	if not prev_trusted.is_empty():
		NativeAdapterScript._trusted_sessions.erase(session_id)
	sess.add_checkpoint("OBSERVATION_IMPORTED", "Manual observation imported from " + observation_path.get_file())
	record["session"] = sess.to_dict()
	sessions[session_id] = record
	var res := collect_observation(session_id, observation_path)
	res["imported"] = bool(res.get("ok", false))
	res["unattested"] = true
	res["verified"] = false
	if str(res.get("state", "")) == "NATIVE_VERIFIED":
		res["state"] = "COMPARISON_COMPLETE"
	if monitors.has(session_id):
		var mon = monitors[session_id]
		mon.observation_imported = true
		mon.observation_collected = bool(res.get("ok", false))
		mon.comparison_complete = bool(res.get("ok", false))
		mon.native_verified = false
		if bool(res.get("ok", false)):
			mon.state = ProcessMonitorScript.STATE_COMPARISON
			mon.active = false
			_save_monitors()
	return res


func resume_monitor(session_id: String) -> Dictionary:
	var path := ledger_dir().path_join("process_monitors.json")
	if FileAccess.file_exists(path):
		var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
		if bool(jres.get("ok", false)) and jres.get("data", null) is Dictionary:
			var md = (jres.get("data", {}) as Dictionary).get("monitors", {})
			if md is Dictionary and (md as Dictionary).has(session_id):
				var monitor = ProcessMonitorScript.from_dict(md[session_id])
				if monitor != null:
					var normalized: Array = []
					for p in monitor.preexisting_game_pids:
						normalized.append(int(p))
					monitor.preexisting_game_pids = normalized
					monitors[session_id] = monitor
					if not sessions.has(session_id):
						recover_sessions()
					return monitor.result()
	# Fallback to monitor snapshot persisted inside the session record (e.g. after
	# process_monitors.json failed to write during cancellation — NC-11 / NC-12).
	if sessions.has(session_id):
		var rec_m = (sessions[session_id] as Dictionary).get("monitor", {})
		if rec_m is Dictionary and not (rec_m as Dictionary).is_empty():
			var monitor2 = ProcessMonitorScript.from_dict(rec_m)
			if monitor2 != null:
				var normalized2: Array = []
				for p2 in monitor2.preexisting_game_pids:
					normalized2.append(int(p2))
				monitor2.preexisting_game_pids = normalized2
				monitors[session_id] = monitor2
				return monitor2.result()
	if monitors.has(session_id):
		return (monitors[session_id] as RefCounted).result()
	return {"ok": false, "state": "NO_MONITOR_TO_RESUME", "reason": "NO_MONITOR_TO_RESUME", "active": false}


func _save_monitors_snapshot(override_sid: String = "", override_dict: Dictionary = {}) -> Dictionary:
	if sessions.is_empty():
		return {"ok": true, "status": STATUS_MONITOR_STATE_SAVED, "recovery_pending": false, "error": ""}
	var doc := {"schema": LEDGER_SCHEMA, "updated": Time.get_datetime_string_from_system(), "monitors": {}}
	for sid in monitors:
		if override_sid != "" and str(sid) == override_sid and not override_dict.is_empty():
			doc["monitors"][sid] = override_dict.duplicate(true)
		else:
			doc["monitors"][sid] = (monitors[sid] as RefCounted).to_dict()
	var wres: Dictionary = {"ok": false, "error": "injected process_monitors.json write failure"} if fault_fail_monitor_persist else WorkspaceStore.atomic_write_abs(
		ledger_dir().path_join("process_monitors.json"), JSON.stringify(doc, "  ").to_utf8_buffer()
	)
	if not bool(wres.get("ok", false)):
		return {
			"ok": false,
			"status": STATUS_MONITOR_PERSIST_FAILED,
			"reason": STATUS_MONITOR_PERSIST_FAILED,
			"recovery_pending": true,
			"state": STATE_RECOVERY_PENDING,
			"persist_failed": true,
			"error": str(wres.get("error", "process_monitors.json write failed")),
		}
	return {"ok": true, "status": STATUS_MONITOR_STATE_SAVED, "recovery_pending": false, "error": ""}


## P1-NATIVE-01 (NC-08..NC-12): Checked cancellation.
## NEVER mutates the live monitor to CANCELLED before BOTH session-ledger
## persistence AND process_monitors.json persistence succeed!
## On any persistence failure, keeps the live monitor active and recoverable
## with cancel_status=CANCELLATION_PERSIST_FAILED and persists a RECOVERY_PENDING
## recovery record so restart reconciles deterministically.
func cancel_monitor(session_id: String) -> Dictionary:
	if not monitors.has(session_id):
		return {"ok": false, "state": "NO_ACTIVE_MONITOR", "reason": "NO_ACTIVE_MONITOR", "active": false}
	var monitor = monitors[session_id]
	var prev_mon_dict: Dictionary = monitor.to_dict()
	var cand_mon_dict: Dictionary = prev_mon_dict.duplicate(true)
	cand_mon_dict["state"] = ProcessMonitorScript.STATE_CANCELLED
	cand_mon_dict["reason"] = "MONITOR_CANCELLED"
	cand_mon_dict["cancel_status"] = STATUS_CANCELLATION_COMMITTED
	cand_mon_dict["recoverable"] = false
	cand_mon_dict["active"] = false

	var record: Dictionary = (sessions.get(session_id, {}) as Dictionary).duplicate(true)
	if not record.is_empty():
		record["cancel_status"] = STATUS_CANCEL_REQUESTED
		record["monitor"] = cand_mon_dict.duplicate(true)
	var commit := _commit_transition(session_id, record, "CANCELLED", "Monitor cancelled by operator")
	if not bool(commit.get("ok", false)):
		var cerr := str(commit.get("error", "checked cancel ledger persist failed"))
		monitor.active = true
		monitor.recoverable = true
		monitor.cancel_status = STATUS_CANCELLATION_PERSIST_FAILED
		monitor.reason = STATUS_CANCELLATION_PERSIST_FAILED
		monitor.last_error = cerr
		var rec_fail: Dictionary = (sessions.get(session_id, record) as Dictionary).duplicate(true)
		rec_fail["state"] = STATE_RECOVERY_PENDING
		rec_fail["reason"] = STATUS_CANCELLATION_PERSIST_FAILED
		rec_fail["cancel_status"] = STATUS_CANCELLATION_PERSIST_FAILED
		rec_fail["recoverable"] = true
		rec_fail["recovery_pending"] = true
		rec_fail["monitor"] = monitor.to_dict()
		sessions[session_id] = rec_fail
		WorkspaceStore.atomic_write_abs(_session_file(session_id), JSON.stringify(rec_fail, "  ").to_utf8_buffer())
		return {
			"ok": false,
			"session_id": session_id,
			"state": STATE_RECOVERY_PENDING,
			"monitor_state": str(monitor.state),
			"cancel_status": STATUS_CANCELLATION_PERSIST_FAILED,
			"reason": STATUS_CANCELLATION_PERSIST_FAILED,
			"recoverable": true,
			"recovery_pending": true,
			"active": true,
			"persist_failed": true,
			"error": cerr,
		}

	var ms := _save_monitors_snapshot(session_id, cand_mon_dict)
	if not bool(ms.get("ok", false)):
		var merr := str(ms.get("error", "process_monitors.json write failed during cancellation"))
		monitor.active = true
		monitor.recoverable = true
		monitor.cancel_status = STATUS_CANCELLATION_PERSIST_FAILED
		monitor.reason = STATUS_CANCELLATION_PERSIST_FAILED
		monitor.last_error = merr
		var rec_mfail: Dictionary = (sessions.get(session_id, record) as Dictionary).duplicate(true)
		rec_mfail["state"] = STATE_RECOVERY_PENDING
		rec_mfail["evidence_state"] = STATE_RECOVERY_PENDING
		rec_mfail["reason"] = STATUS_CANCELLATION_PERSIST_FAILED
		rec_mfail["cancel_status"] = STATUS_CANCELLATION_PERSIST_FAILED
		rec_mfail["recoverable"] = true
		rec_mfail["recovery_pending"] = true
		rec_mfail["monitor_persist_status"] = STATUS_MONITOR_PERSIST_FAILED
		rec_mfail["monitor"] = monitor.to_dict()
		rec_mfail["last_error"] = merr
		var sess_mf = NativeSessionScript.from_dict(rec_mfail.get("session", {}))
		if sess_mf != null:
			sess_mf.add_checkpoint(STATE_RECOVERY_PENDING, "Cancellation monitor persist failed: " + merr)
			rec_mfail["session"] = sess_mf.to_dict()
		sessions[session_id] = rec_mfail
		_persist_session(session_id, rec_mfail)
		return {
			"ok": false,
			"session_id": session_id,
			"state": STATE_RECOVERY_PENDING,
			"monitor_state": str(monitor.state),
			"status": STATUS_MONITOR_PERSIST_FAILED,
			"cancel_status": STATUS_CANCELLATION_PERSIST_FAILED,
			"reason": STATUS_CANCELLATION_PERSIST_FAILED,
			"recoverable": true,
			"recovery_pending": true,
			"active": true,
			"persist_failed": true,
			"error": merr,
		}

	# Both session ledger and process_monitors.json persisted cleanly: commit live monitor state!
	monitor.cancel()
	if sessions.has(session_id):
		var rec_ok: Dictionary = sessions[session_id]
		rec_ok["cancel_status"] = STATUS_CANCELLATION_COMMITTED
		rec_ok["recoverable"] = false
		rec_ok["recovery_pending"] = false
		rec_ok["monitor"] = monitor.to_dict()
		sessions[session_id] = rec_ok
	var out: Dictionary = monitor.result()
	out["cancel_status"] = STATUS_CANCELLATION_COMMITTED
	out["recoverable"] = false
	out["monitor_persist_status"] = STATUS_MONITOR_STATE_SAVED
	return out


## One lifecycle contract for both cleanup entrypoints. The durable cleanup
## result is classified from the cleanup outcome, never from `partial` alone.
func cleanup_outcome(cl: Dictionary) -> Dictionary:
	var is_partial := bool(cl.get("partial", false))
	var ok := bool(cl.get("ok", false))
	if not ok:
		return {"state": "FAILED" if not is_partial else "PARTIAL_CLEANUP",
			"intent_state": "CLEANUP_FAILED" if not is_partial else "CLEANUP_FAILED_PARTIAL_RECOVERY",
			"status": str(cl.get("status", "CLEANUP_FAILED"))}
	if is_partial:
		return {"state": "PARTIAL_CLEANUP",
			"intent_state": "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED",
			"status": str(cl.get("status", "PARTIAL_CLEANUP"))}
	return {"state": "CLEANED_UP", "intent_state": "CLEANUP_COMPLETE",
		"status": str(cl.get("status", "CLEAN"))}


func _durable_session_state(session_id: String) -> String:
	var rec := _durable_session_record(session_id)
	return str(rec.get("state", "")) if not rec.is_empty() else ""


## The ledger record is the durable authority for cleanup identity and result.
func _durable_session_record(session_id: String) -> Dictionary:
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(ledger_path()))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {}
	var root: Dictionary = jres.get("data", {})
	var items = root.get("sessions", null)
	if not (items is Dictionary):
		items = root.get("ledger", null)
	if not (items is Dictionary) or not (items as Dictionary).has(session_id):
		return {}
	var rec = (items as Dictionary).get(session_id, null)
	return rec if rec is Dictionary else {}


## True only when a prior verified cleanup has removed every manifest-owned
## file. Missing manifest + empty stage is NOT proof: the durable ledger must
## also carry an ok=true, non-partial cleanup result with a matching identity.
func _verified_prior_cleanup(session_id: String, sess) -> bool:
	var rec := _durable_session_record(session_id)
	if rec.is_empty():
		return false
	var sid := str(rec.get("session_id", ""))
	if sid != "" and sid != session_id:
		return false
	var stage_id := str((rec.get("session", {}) as Dictionary).get("stage_id", ""))
	if stage_id != "" and sess != null and str(sess.stage_id) != "" and stage_id != str(sess.stage_id):
		return false
	var cl = rec.get("cleanup", null)
	if not (cl is Dictionary):
		return false
	var cleanup: Dictionary = cl
	if not bool(cleanup.get("ok", false)) or bool(cleanup.get("partial", false)):
		return false
	return true


## Positive finalization evidence. A receipt counts only if it names this
## session/stage and reports owned files removed; a clean stage satisfies the
## inventory only when prior cleanup was verified in the durable ledger.
func _finalization_evidence(session_id: String, sess) -> Dictionary:
	var stage_root := str(sess.stage_root)
	var result := {"ok": false, "reason": "FINALIZATION_EVIDENCE_INSUFFICIENT",
		"ownership_verified": false, "receipt_verified": false,
		"stage_contents_unclassified": false, "remaining_owned_files": -1}
	var receipt_path := stage_root.path_join("stage_cleanup_receipt.json")
	var prior := _verified_prior_cleanup(session_id, sess)
	if FileAccess.file_exists(receipt_path):
		var rres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(receipt_path))
		if bool(rres.get("ok", false)) and (rres.get("data", null) is Dictionary):
			var receipt: Dictionary = rres.get("data", {})
			var r_sid := str(receipt.get("session_id", ""))
			var r_stage := str(receipt.get("stage_root", ""))
			var r_stage_id := str(receipt.get("stage_id", ""))
			var identity_ok := (r_sid == session_id and
				(r_stage == "" or WorkspaceStore.canonical(r_stage) == WorkspaceStore.canonical(stage_root)) and
				(r_stage_id == "" or str(sess.stage_id) == "" or r_stage_id == str(sess.stage_id)))
			if identity_ok and str(receipt.get("status", "")).begins_with("OWNED_FILES_REMOVED"):
				result["receipt_verified"] = true
				result["ownership_verified"] = true
	if bool(result["receipt_verified"]):
		result["ok"] = true
		result["reason"] = ""
		result["remaining_owned_files"] = 0
		return result
	if not DirAccess.dir_exists_absolute(stage_root):
		if prior:
			result["ok"] = true
			result["reason"] = ""
			result["ownership_verified"] = true
			result["remaining_owned_files"] = 0
		return result
	var existing: Array[String] = []
	SafeStageScript._list_existing_rel_files(stage_root, stage_root, existing)
	var metadata := [SafeStageScript.MANIFEST_NAME, "native_evidence.json",
		"stage_provenance.json", "stage_cleanup_receipt.json"]
	var substantive: Array[String] = []
	for rel in existing:
		if not metadata.has(rel) and not rel.begins_with(SafeStageScript.BACKUP_SUBDIR + "/"):
			substantive.append(rel)
	result["remaining_owned_files"] = substantive.size()
	result["stage_contents_unclassified"] = true
	if substantive.is_empty() and prior:
		result["ok"] = true
		result["reason"] = ""
		result["ownership_verified"] = true
		result["stage_contents_unclassified"] = false
	return result


## Shared authorization gate. A PREPARED intent is not permission to delete:
## every retry must re-prove session identity, stage identity, ledger, monitor
## quiescence and authoritative stage ownership/hashes.
func _authorize_cleanup(session_id: String, record: Dictionary, sess,
		intent: Dictionary = {}, finalization_retry: bool = false) -> Dictionary:
	# P0-NATIVE-01: the requested ID, the session record, the session object and
	# the stage evidence must all describe one owner. Empty fields never waive
	# the check, and the same gate covers normal and terminal cleanup.
	var record_sid := str(record.get("session_id", ""))
	var object_sid := str(sess.session_id) if sess != null else ""
	if session_id == "" or record_sid != "" and record_sid != session_id or \
			object_sid != session_id:
		return {"ok": false, "reason": "CLEANUP_SESSION_IDENTITY_MISMATCH"}
	var stage_root := str(sess.stage_root)
	if stage_root == "":
		return {"ok": false, "reason": "CLEANUP_STAGE_ROOT_MISSING"}
	if str(sess.stage_id) == "":
		return {"ok": false, "reason": "CLEANUP_STAGE_ID_MISSING"}
	if not intent.is_empty():
		# INT-01..06: a terminal retry requires a complete, matched identity.
		# Missing fields never waive the check.
		var intent_sid := str(intent.get("session_id", ""))
		var intent_root := str(intent.get("stage_root", ""))
		if intent_sid == "" or intent_sid != session_id:
			return {"ok": false, "reason": "CLEANUP_INTENT_SESSION_IDENTITY_REQUIRED"}
		if intent_root == "" or WorkspaceStore.canonical(intent_root) != WorkspaceStore.canonical(stage_root):
			return {"ok": false, "reason": "CLEANUP_INTENT_STAGE_ROOT_REQUIRED"}
		if int(intent.get("schema", 0)) != 1:
			return {"ok": false, "reason": "CLEANUP_INTENT_SCHEMA_UNSUPPORTED"}
	if not intent.is_empty() and \
			str(intent.get("state", "")) not in ["CLEANUP_PREPARED", "CLEANUP_FINALIZATION_PENDING"]:
		return {"ok": false, "reason": "CLEANUP_INTENT_NOT_RESUMABLE"}
	if _is_session_active_for_cleanup(session_id, record):
		return {"ok": false, "reason": "ACTIVE_EXPERIMENT_CANNOT_CLEANUP",
			"state": str(record.get("state", "ACTIVE"))}
	# A finalization retry has already passed the destructive step. The stage
	# manifest is gone by design; allow only a durable, quiescent finalization
	# state to complete the intent without repeating any deletion.
	if finalization_retry and not FileAccess.file_exists(str(sess.stage_root).path_join(SafeStageScript.MANIFEST_NAME)):
		var durable_state := _durable_session_state(session_id)
		if durable_state != "CLEANUP_FINALIZATION_PENDING":
			return {"ok": false, "reason": "FINALIZATION_RETRY_NOT_DURABLE"}
		var mon := SafeStageScript._active_monitor_for_session(ledger_path(), session_id)
		if bool(mon.get("active", false)):
			return {"ok": false, "reason": "ACTIVE_MONITOR"}
		# P0-NATIVE-02: absent manifest alone proves nothing. Require a verified
		# receipt or a durable ok=true/non-partial result plus a clean inventory.
		var evidence := _finalization_evidence(session_id, sess)
		if not bool(evidence.get("ok", false)):
			return {"ok": false, "reason": str(evidence.get("reason", "FINALIZATION_EVIDENCE_INSUFFICIENT")),
				"finalization_only": false, "evidence": evidence}
		return {"ok": true, "finalization_only": true, "evidence": evidence,
			"reconciliation": {"never_launched_dry_run": false}}
	var reconciliation: Dictionary = SafeStageScript.reconcile_stage(str(sess.stage_root), ledger_path())
	var recon_action := str(reconciliation.get("action", ""))
	# P0-NATIVE-01: reconciliation derives owner from stage evidence. That owner
	# must equal the requested session, and the manifest stage ID must equal the
	# session object's immutable stage ID.
	var recon_sid := str(reconciliation.get("session_id", ""))
	var recon_stage_id := str(reconciliation.get("stage_id", ""))
	if recon_sid == "" or recon_sid != session_id or \
			(recon_stage_id != "" and recon_stage_id != str(sess.stage_id)):
		return {"ok": false, "reason": "CLEANUP_STAGE_OWNER_MISMATCH",
			"requested_session_id": session_id,
			"stage_owner_session_id": recon_sid,
			"stage_id": recon_stage_id}
	if not (recon_action == "CLEANUP_ELIGIBLE" or recon_action == "CLEANUP_ELIGIBLE_DRY_RUN") \
			or not bool(reconciliation.get("cleanup_allowed", false)):
		return {"ok": false,
			"reason": str(reconciliation.get("reason", "STAGE_CLEANUP_NOT_AUTHORIZED")),
			"recovery_pending": bool(reconciliation.get("recovery_pending", false)),
			"ledger_status": str(reconciliation.get("ledger_status", "")),
			"monitor_status": str(reconciliation.get("monitor_status", ""))}
	reconciliation["never_launched_dry_run"] = recon_action == "CLEANUP_ELIGIBLE_DRY_RUN" and \
		bool(reconciliation.get("never_launched", false))
	return {"ok": true, "reconciliation": reconciliation}


## Persist, read back and verify the final durable intent. A failed final write
## is never reported as confirmed durable completion.
func _finalize_cleanup_intent(intent_path: String, session_id: String,
		stage_root: String, outcome: Dictionary, cl: Dictionary,
		never_launched_dry_run: bool) -> bool:
	if fault_fail_cleanup_intent_final_write:
		return false
	var payload := JSON.stringify({
		"schema": 1, "session_id": session_id, "stage_root": stage_root,
		"state": str(outcome.get("intent_state", "CLEANUP_FAILED")),
		"cleanup": cl, "cleanup_status": str(outcome.get("status", "")),
		"never_launched_dry_run": never_launched_dry_run,
		"completed_at": Time.get_datetime_string_from_system(),
	}, "  ").to_utf8_buffer()
	var write := WorkspaceStore.atomic_write_abs(intent_path, payload)
	if not bool(write.get("ok", false)) or not FileAccess.file_exists(intent_path):
		return false
	if WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(intent_path)) != WorkspaceStore._md5_bytes(payload):
		return false
	var parsed := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(intent_path))
	if not bool(parsed.get("ok", false)) or not (parsed.get("data", null) is Dictionary):
		return false
	var disk: Dictionary = parsed.get("data", {})
	return str(disk.get("state", "")) == str(outcome.get("intent_state", "")) and \
		str(disk.get("session_id", "")) == session_id and \
		WorkspaceStore.canonical(str(disk.get("stage_root", ""))) == WorkspaceStore.canonical(stage_root)


func _is_session_active_for_cleanup(session_id: String, record: Dictionary) -> bool:
	var rec_state := str(record.get("state", ""))
	# Recovery-pending, failed and partial-cleanup states are not proof that the
	# game process is quiesced. Never infer cleanup eligibility from them alone.
	if rec_state in ["RECOVERY_PENDING", "FAILED", "PARTIAL_CLEANUP"]:
		return true
	if monitors.has(session_id):
		var mon = monitors[session_id]
		if mon != null and bool(mon.active) and not mon.is_terminal():
			return true
	var mon_dict: Dictionary = record.get("monitor", {}) if record.get("monitor", {}) is Dictionary else {}
	if not mon_dict.is_empty():
		var m_active := bool(mon_dict.get("active", false))
		var m_recoverable := bool(mon_dict.get("recoverable", false))
		var m_state := str(mon_dict.get("state", "")).to_upper()
		var m_terminal := m_state in ProcessMonitorScript.TERMINAL_STATES
		if m_active or m_recoverable or not m_terminal:
			return true
		if str(mon_dict.get("cancel_status", "")) == STATUS_CANCEL_REQUESTED:
			return true
	if rec_state in ["STEAM_PROCESS_STARTED", "MONITOR_ARMED", "GAME_PROCESS_CANDIDATE", "GAME_PROCESS_DETECTED", "GAME_PROCESS_VERIFIED", "MISSION_OBSERVED", "RESOURCE_PROBE_CONFIRMED"]:
		return true
	return false


## Step 5: Safe MD5-verified cleanup of the staged directory via SafeStageManager.
## P1-NATIVE-03: Rejects cleanup while an experiment monitor is active
## (`ACTIVE_EXPERIMENT_CANNOT_CLEANUP`) and retains evidence artifacts in a
## durable directory separate from disposable stage files.
func cleanup_stage(session_id: String) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "reason": "UNKNOWN_SESSION", "error": "session not found in ledger: " + session_id}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "reason": "INVALID_SESSION", "error": "cannot deserialize session"}
	var auth: Dictionary = _authorize_cleanup(session_id, record, sess)
	if not bool(auth.get("ok", false)):
		var auth_reason := str(auth.get("reason", "STAGE_CLEANUP_NOT_AUTHORIZED"))
		var active_rejection := auth_reason == "ACTIVE_EXPERIMENT_CANNOT_CLEANUP"
		return {
			"ok": false,
			"state": str(auth.get("state", record.get("state", "ACTIVE"))),
			"reason": auth_reason,
			"cleanup_rejected": true,
			"active_monitor": active_rejection,
			"recovery_pending": bool(auth.get("recovery_pending", false)),
			"ledger_status": str(auth.get("ledger_status", "")),
			"monitor_status": str(auth.get("monitor_status", "")),
			"session_id": session_id,
			"error": auth_reason + ": authoritative cleanup gate refused cleanup",
		}
	var reconciliation: Dictionary = auth.get("reconciliation", {})
	var never_launched_dry_run := bool(reconciliation.get("never_launched_dry_run", false))
	# Durable cleanup intent is written and read back BEFORE any file removal.
	var intent_path := ledger_dir().path_join(session_id.replace("/", "_").replace("\\", "_") + ".cleanup_intent.json")
	var intent_payload := JSON.stringify({
		"schema": 1, "session_id": session_id, "stage_root": str(sess.stage_root),
		"state": "CLEANUP_PREPARED", "reconciliation": reconciliation,
		"prepared_at": Time.get_datetime_string_from_system(),
	}, "  ").to_utf8_buffer()
	var intent_write := WorkspaceStore.atomic_write_abs(intent_path, intent_payload)
	if not bool(intent_write.get("ok", false)) or not FileAccess.file_exists(intent_path) or \
			WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(intent_path)) != WorkspaceStore._md5_bytes(intent_payload):
		return {"ok": false, "state": "RECOVERY_PENDING", "reason": "CLEANUP_INTENT_PERSIST_FAILED",
			"cleanup_rejected": true, "recovery_pending": true, "session_id": session_id,
			"error": "durable cleanup intent could not be verified; no files were removed"}
	# NC-07: Retain durable evidence artifact outside disposable stage root before cleanup.
	var retained_evidence_path := ""
	var ev_src := str(sess.evidence_path)
	if ev_src != "" and FileAccess.file_exists(ev_src):
		var ev_dir := ledger_dir().path_join("evidence")
		DirAccess.make_dir_recursive_absolute(ev_dir)
		var ev_dst := ev_dir.path_join(session_id.replace("/", "_").replace("\\", "_") + "_native_evidence.json")
		var ev_bytes := FileAccess.get_file_as_bytes(ev_src)
		if not ev_bytes.is_empty():
			var ew := WorkspaceStore.atomic_write_abs(ev_dst, ev_bytes)
			if bool(ew.get("ok", false)):
				retained_evidence_path = ev_dst
				record["retained_evidence_path"] = ev_dst
	elif not (record.get("evidence", {}) as Dictionary).is_empty():
		var ev_dir2 := ledger_dir().path_join("evidence")
		DirAccess.make_dir_recursive_absolute(ev_dir2)
		var ev_dst2 := ev_dir2.path_join(session_id.replace("/", "_").replace("\\", "_") + "_native_evidence.json")
		var ew2 := WorkspaceStore.atomic_write_abs(ev_dst2, JSON.stringify(record.get("evidence", {}), "  ").to_utf8_buffer())
		if bool(ew2.get("ok", false)):
			retained_evidence_path = ev_dst2
			record["retained_evidence_path"] = ev_dst2

	var disc: Dictionary = record.get("discovery", {})
	var is_stock_addon := str(record.get("launch_mode", "")) == "STOCK_ADDON"
	var stage_leaf := WorkspaceStore.canonical(str(sess.stage_root)).get_file()
	var extra_prot: Array[String] = NativeAdapterScript._extra_protected_from_discovery(disc, is_stock_addon and stage_leaf.begins_with("SHAMAN_"))
	if is_stock_addon and str(sess.stage_root) != "":
		var addon_parent := WorkspaceStore.canonical(str(sess.stage_root)).get_base_dir()
		if addon_parent != "" and addon_parent.to_lower().ends_with("/addon"):
			SafeStageScript.register_owned_base(addon_parent, extra_prot)
	var cl: Dictionary = SafeStageScript.cleanup(str(sess.stage_root), extra_prot)
	var outcome := cleanup_outcome(cl)
	var new_state := str(outcome.get("state", "FAILED"))
	var terminal_intent_state := str(outcome.get("intent_state", "CLEANUP_FAILED"))
	sess.add_checkpoint(new_state, "Stage cleanup: status=%s removed=%d" % [str(cl.get("status", "")), int(cl.get("removed", 0))])
	record["state"] = new_state
	record["cleanup"] = cl
	record["session"] = sess.to_dict()
	record["updated_at"] = Time.get_datetime_string_from_system()
	_pending_files.erase(session_id)
	var cleanup_commit := _commit_transition(session_id, record, new_state, "Stage cleanup completed")
	if not bool(cleanup_commit.get("ok", false)):
		WorkspaceStore.atomic_write_abs(intent_path, JSON.stringify({
			"schema": 1, "session_id": session_id, "stage_root": str(sess.stage_root),
			"state": "CLEANUP_RECOVERY_PENDING", "cleanup": cl,
			"completed_at": Time.get_datetime_string_from_system(),
		}, "  ").to_utf8_buffer())
		cleanup_commit["session_id"] = session_id
		cleanup_commit["cleanup"] = cl
		cleanup_commit["cleanup_intent"] = "CLEANUP_RECOVERY_PENDING"
		return cleanup_commit
	var intent_finalized := _finalize_cleanup_intent(intent_path, session_id,
		str(sess.stage_root), outcome, cl, never_launched_dry_run)
	# P1-NATIVE-03: the final durable intent write must be read back and
	# verified. Files removed + ledger committed + unverifiable intent is NOT
	# a complete durable cleanup; report the honest intermediate state.
	if not intent_finalized:
		var pending_record := record.duplicate(true)
		pending_record["state"] = "CLEANUP_FINALIZATION_PENDING"
		var fin_transition := _commit_transition(session_id, pending_record,
			"CLEANUP_FINALIZATION_PENDING", "Cleanup done; final intent write could not be verified")
		return {
			"ok": false,
			"state": "CLEANUP_FINALIZATION_PENDING" if bool(fin_transition.get("ok", false)) else new_state,
			"cleanup": cl,
			"files_cleanup_ok": bool(cl.get("ok", false)),
			"ledger_commit_ok": true,
			"intent_finalized": false,
			"durable_complete": false,
			"recovery_required": true,
			"retained_evidence_path": retained_evidence_path,
			"session_id": session_id,
			"cleanup_intent": "CLEANUP_FINALIZATION_PENDING",
			"reason": "CLEANUP_INTENT_FINALIZATION_UNVERIFIED",
			"error": "stage files removed and ledger committed, but the durable cleanup intent could not be verified after write",
		}
	var durable := bool(cl.get("ok", false)) and intent_finalized
	return {
		"ok": durable,
		"state": new_state,
		"cleanup": cl,
		"files_cleanup_ok": bool(cl.get("ok", false)),
		"ledger_commit_ok": true,
		"intent_finalized": intent_finalized,
		"durable_complete": durable,
		"recovery_required": not durable,
		"retained_evidence_path": retained_evidence_path,
		"session_id": session_id,
		"cleanup_intent": terminal_intent_state + ("_VERIFIED" if intent_finalized else ""),
		"never_launched_dry_run": never_launched_dry_run,
	}


## T-122: finalize a cleanup whose durable intent is already prepared.
## Distinct from cleanup_stage() so an interrupted/restarted cleanup can be
## completed without re-arming a fresh intent or bypassing reconciliation.
func cleanup_stage_terminal(session_id: String) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "reason": "UNKNOWN_SESSION", "session_id": session_id}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "reason": "INVALID_SESSION", "session_id": session_id}
	var intent_path := ledger_dir().path_join(session_id.replace("/", "_").replace("\\", "_") + ".cleanup_intent.json")
	if not FileAccess.file_exists(intent_path):
		return {"ok": false, "reason": "CLEANUP_INTENT_MISSING", "session_id": session_id}
	var intent_res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(intent_path))
	if not bool(intent_res.get("ok", false)) or not (intent_res.get("data", null) is Dictionary):
		return {"ok": false, "reason": "CLEANUP_INTENT_NOT_PREPARED", "session_id": session_id}
	var intent: Dictionary = intent_res.get("data", {})
	var finalization_retry := str(intent.get("state", "")) == "CLEANUP_FINALIZATION_PENDING" or \
		_durable_session_state(session_id) == "CLEANUP_FINALIZATION_PENDING"
	if finalization_retry:
		intent["state"] = "CLEANUP_PREPARED"
	var auth: Dictionary = _authorize_cleanup(session_id, record, sess, intent, finalization_retry)
	if not bool(auth.get("ok", false)):
		return {"ok": false, "reason": str(auth.get("reason", "STAGE_CLEANUP_NOT_AUTHORIZED")),
			"cleanup_rejected": true, "session_id": session_id,
			"recovery_pending": bool(auth.get("recovery_pending", false))}
	var is_stock_addon := str(record.get("launch_mode", "")) == "STOCK_ADDON"
	var stage_leaf := WorkspaceStore.canonical(str(sess.stage_root)).get_file()
	var extra_prot: Array[String] = NativeAdapterScript._extra_protected_from_discovery(
		record.get("discovery", {}), is_stock_addon and stage_leaf.begins_with("SHAMAN_"))
	var cl: Dictionary
	var outcome: Dictionary
	var new_state := ""
	var terminal_intent_state := ""
	if bool(auth.get("finalization_only", false)):
		outcome = {"state": "CLEANED_UP", "intent_state": "CLEANUP_COMPLETE",
			"status": "ALREADY_CLEANED"}
		new_state = "CLEANED_UP"
		terminal_intent_state = "CLEANUP_COMPLETE"
		cl = {"ok": true, "partial": false, "status": "ALREADY_CLEANED",
			"removed": 0, "reused_prior_cleanup": true}
	else:
		cl = SafeStageScript.cleanup(str(sess.stage_root), extra_prot)
		outcome = cleanup_outcome(cl)
		new_state = str(outcome.get("state", "FAILED"))
		terminal_intent_state = str(outcome.get("intent_state", "CLEANUP_FAILED"))
	record["state"] = new_state
	record["cleanup"] = cl
	record["session"] = sess.to_dict()
	record["updated_at"] = Time.get_datetime_string_from_system()
	_pending_files.erase(session_id)
	var commit := _commit_transition(session_id, record, new_state, "Terminal cleanup finalized")
	if not bool(commit.get("ok", false)):
		return {"ok": false, "reason": "STATE_PERSIST_FAILED", "session_id": session_id,
			"cleanup_intent": "CLEANUP_RECOVERY_PENDING", "cleanup": cl}
	var reconciliation: Dictionary = auth.get("reconciliation", {})
	var intent_finalized := _finalize_cleanup_intent(intent_path, session_id,
		str(sess.stage_root), outcome, cl, bool(reconciliation.get("never_launched_dry_run", false)))
	if not intent_finalized:
		var pending_record := record.duplicate(true)
		pending_record["state"] = "CLEANUP_FINALIZATION_PENDING"
		var fin_transition := _commit_transition(session_id, pending_record,
			"CLEANUP_FINALIZATION_PENDING", "Terminal cleanup done; final intent write could not be verified")
		return {"ok": false,
			"state": "CLEANUP_FINALIZATION_PENDING" if bool(fin_transition.get("ok", false)) else new_state,
			"cleanup_intent": "CLEANUP_FINALIZATION_PENDING", "cleanup": cl,
			"files_cleanup_ok": bool(cl.get("ok", false)), "ledger_commit_ok": true,
			"intent_finalized": false, "durable_complete": false, "recovery_required": true,
			"reason": "CLEANUP_INTENT_FINALIZATION_UNVERIFIED", "session_id": session_id}
	var durable := bool(cl.get("ok", false)) and intent_finalized
	return {"ok": durable, "state": new_state,
		"cleanup_intent": terminal_intent_state, "cleanup": cl,
		"files_cleanup_ok": bool(cl.get("ok", false)), "ledger_commit_ok": true,
		"intent_finalized": intent_finalized, "durable_complete": durable,
		"recovery_required": not durable, "session_id": session_id}


## P1-NATIVE-04: read-only startup discovery of incomplete cleanup intents.
## Scans every persisted *.cleanup_intent.json beside the session ledger and
## classifies it against the durable ledger, monitor state, stage manifest and
## remaining files. This method NEVER deletes or writes anything: it reports
## incomplete cleanup state so the UI can surface it and a human can permit a
## safe retry. Destructive startup cleanup is forbidden by design.
func discover_cleanup_intents(include_completed: bool = false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(ledger_dir())
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if n.ends_with(".cleanup_intent.json"):
			var intent_path := ledger_dir().path_join(n)
			var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(intent_path))
			var entry: Dictionary = {
				"intent_path": intent_path,
				"intent_file": n,
				"schema_ok": false,
				"intent_state": "UNREADABLE",
				"session_id": "",
				"stage_root": "",
				"ledger_status": "NOT_CHECKED",
				"monitor_status": "NOT_CHECKED",
				"stage_status": "NOT_CHECKED",
				"remaining_owned_files": 0,
				"ownership_verified": false,
				"receipt_verified": false,
				"manifest_present": false,
				"stage_contents_unclassified": false,
				"unknown_files": [],
				"resolution": "UNKNOWN",
				"requires_attention": true,
				"terminal": false,
				"verified_complete": false,
				"drift_reasons": [],
			}
			if bool(jres.get("ok", false)) and (jres.get("data", null) is Dictionary):
				var intent: Dictionary = jres.get("data", {})
				entry["schema_ok"] = int(intent.get("schema", 0)) == 1
				entry["intent_state"] = str(intent.get("state", "UNKNOWN"))
				entry["session_id"] = str(intent.get("session_id", ""))
				entry["stage_root"] = str(intent.get("stage_root", ""))
			if not entry["schema_ok"]:
				entry["resolution"] = "INTENT_INVALID_SCHEMA"
				out.append(entry)
				n = dir.get_next()
				continue
			var sid := str(entry["session_id"])
			# 1-2: validate session identity against the durable ledger.
			var ledger_file := ledger_path()
			var ledger_state := ""
			if not FileAccess.file_exists(ledger_file):
				entry["ledger_status"] = "LEDGER_NOT_FOUND"
			else:
				var lres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(ledger_file))
				if not bool(lres.get("ok", false)) or not (lres.get("data", null) is Dictionary):
					entry["ledger_status"] = "LEDGER_CORRUPT"
				else:
					var items = (lres.get("data", {}) as Dictionary).get("sessions", null)
					var ledger_items = (lres.get("data", {}) as Dictionary).get("ledger", null)
					if not (items is Dictionary) and ledger_items is Dictionary:
						items = ledger_items
					if not (items is Dictionary):
						entry["ledger_status"] = "LEDGER_CORRUPT"
					elif not (items as Dictionary).has(sid):
						entry["ledger_status"] = "SESSION_NOT_IN_LEDGER"
					else:
						var rec = (items as Dictionary).get(sid, {})
						if rec is Dictionary and str((rec as Dictionary).get("state", "")) != "":
							ledger_state = str((rec as Dictionary).get("state", "")).to_upper()
							entry["ledger_status"] = "MATCH"
						else:
							entry["ledger_status"] = "RECORD_NO_STATE"
			# 5: reconcile monitor state read-only.
			var monitor := SafeStageScript._active_monitor_for_session(ledger_file, sid)
			entry["monitor_status"] = str(monitor.get("status", "NOT_FOUND"))
			# 6: inventory remaining files under the recorded stage root.
			var stage_root := str(entry["stage_root"])
			var remaining_owned := 0
			var unknown: Array[String] = []
			if stage_root == "" or not DirAccess.dir_exists_absolute(stage_root):
				entry["stage_status"] = "STAGE_MISSING"
				# A vanished stage is only benign when the durable ledger proves
				# a prior complete cleanup; otherwise keep it unresolved.
				var missing_rec := _durable_session_record(sid)
				var missing_cl = missing_rec.get("cleanup", null)
				var ledger_confirms := str(missing_rec.get("state", "")).to_upper() == "CLEANED_UP" and \
					missing_cl is Dictionary and bool((missing_cl as Dictionary).get("ok", false)) and \
					not bool((missing_cl as Dictionary).get("partial", false))
				if str(entry["intent_state"]) == "CLEANUP_COMPLETE" and \
						str(entry.get("ledger_status", "")) == "MATCH" and \
						ledger_state == "CLEANED_UP":
					ledger_confirms = true
				if ledger_confirms:
					entry["ownership_verified"] = true
					entry["stage_contents_unclassified"] = false
			else:
				var inspection := SafeStageScript.inspect_stage(stage_root)
				entry["stage_status"] = str(inspection.get("reason", "STAGE_PRESENT"))
				var manifest_path := stage_root.path_join(SafeStageScript.MANIFEST_NAME)
				entry["manifest_present"] = FileAccess.file_exists(manifest_path)
				if entry["manifest_present"]:
					var mres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(manifest_path))
					if bool(mres.get("ok", false)) and (mres.get("data", null) is Dictionary):
						var manifest: Dictionary = mres.get("data", {})
						entry["ownership_verified"] = str(manifest.get("stage_id", "")) != "" and \
							str(inspection.get("session_id", "")) == sid
						var declared := {}
						for f in manifest.get("files", []):
							if f is Dictionary:
								var rel := str((f as Dictionary).get("rel", ""))
								declared[rel] = true
								if FileAccess.file_exists(stage_root.path_join(rel)):
									remaining_owned += 1
						var existing: Array[String] = []
						SafeStageScript._list_existing_rel_files(stage_root, stage_root, existing)
						for rel in existing:
							if not declared.has(rel) and rel != SafeStageScript.MANIFEST_NAME \
									and rel != "native_evidence.json" and rel != "stage_provenance.json" \
									and rel != "stage_cleanup_receipt.json" \
									and not rel.begins_with(SafeStageScript.BACKUP_SUBDIR + "/"):
								unknown.append(rel)
				else:
					# Missing manifest: ownership must come from a verified receipt
					# bound to this session and stage, never from an empty inventory.
					var receipt_path := stage_root.path_join("stage_cleanup_receipt.json")
					entry["stage_contents_unclassified"] = true
					if FileAccess.file_exists(receipt_path):
						entry["stage_status"] = "RECEIPT_PRESENT"
						var rres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(receipt_path))
						if bool(rres.get("ok", false)) and (rres.get("data", null) is Dictionary):
							var rcp: Dictionary = rres.get("data", {})
							var r_sid := str(rcp.get("session_id", ""))
							var r_stage := str(rcp.get("stage_root", ""))
							var identity_ok := r_sid == sid and \
								(r_stage == "" or WorkspaceStore.canonical(r_stage) == WorkspaceStore.canonical(stage_root))
							if identity_ok and str(rcp.get("status", "")).begins_with("OWNED_FILES_REMOVED"):
								entry["receipt_verified"] = true
								entry["ownership_verified"] = true
								entry["stage_contents_unclassified"] = false
							var foreign = rcp.get("foreign_files_preserved", [])
							if foreign is Array:
								for f in foreign:
									unknown.append(str(f))
			entry["remaining_owned_files"] = remaining_owned
			entry["unknown_files"] = unknown
			# 7-8: classify without mutating anything. A terminal-looking string
			# is a claim, not proof; verify it against the durable state first.
			var intent_state := str(entry["intent_state"])
			var terminal := intent_state in ["CLEANUP_COMPLETE", "CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED"]
			var drift: Array[String] = []
			if terminal:
				# Strict intent-to-ledger correspondence. Native experiment
				# terminal states are not cleanup proof.
				var required_ledger := ""
				match intent_state:
					"CLEANUP_COMPLETE":
						required_ledger = "CLEANED_UP"
					"CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED":
						required_ledger = "PARTIAL_CLEANUP"
				if ledger_state == "":
					drift.append("LEDGER_UNRESOLVED")
				elif ledger_state != required_ledger:
					drift.append("LEDGER_DISAGREES")
				if remaining_owned > 0:
					drift.append("OWNED_FILES_REMAIN")
				if not bool(entry["ownership_verified"]):
					drift.append("OWNERSHIP_UNVERIFIED" if not bool(entry["stage_contents_unclassified"]) \
						else "STAGE_CONTENTS_UNCLASSIFIED")
				if intent_state == "CLEANUP_COMPLETE" and not entry["manifest_present"] and \
						not bool(entry["receipt_verified"]) and \
						str(entry.get("stage_status", "")) != "STAGE_MISSING":
					drift.append("CLEANUP_RECEIPT_MISSING")
				if bool(monitor.get("active", false)):
					drift.append("ACTIVE_MONITOR")
				entry["drift_reasons"] = drift
			entry["terminal"] = terminal
			entry["verified_complete"] = terminal and drift.is_empty()
			entry["requires_attention"] = (not terminal) or not drift.is_empty()
			if terminal:
				if not drift.is_empty():
					entry["resolution"] = "CLEANUP_STATE_DRIFT"
					out.append(entry)
					n = dir.get_next()
					continue
				entry["resolution"] = "ALREADY_COMPLETE" if intent_state == "CLEANUP_COMPLETE" else "PARTIAL_FOREIGN_FILES_PRESERVED"
				entry["requires_attention"] = intent_state != "CLEANUP_COMPLETE"
				if intent_state == "CLEANUP_COMPLETE" and not include_completed:
					n = dir.get_next()
					continue
			elif str(entry["intent_state"]) == "CLEANUP_FINALIZATION_PENDING":
				entry["resolution"] = "FINALIZATION_RETRY_ELIGIBLE" if remaining_owned == 0 else "FILES_STILL_PRESENT"
			elif str(entry["intent_state"]) == "CLEANUP_PREPARED" or str(entry["intent_state"]) == "CLEANUP_RECOVERY_PENDING":
				if bool(monitor.get("active", false)):
					entry["resolution"] = "PROTECTED_ACTIVE_MONITOR"
				elif ledger_state == "":
					entry["resolution"] = "PROTECTED_LEDGER_UNRESOLVED"
				elif remaining_owned == 0:
					entry["resolution"] = "RETRY_ELIGIBLE_OWNED_FILES_GONE"
				else:
					entry["resolution"] = "RETRY_REQUIRES_RECONCILIATION"
			else:
				entry["resolution"] = "UNKNOWN_INTENT_STATE"
			out.append(entry)
		n = dir.get_next()
	dir.list_dir_end()
	return out
