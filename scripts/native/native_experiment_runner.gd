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

		if str(entry.get("reason", "")) == REASON_STATE_PERSIST_FAILED or prev_state == STATE_RECOVERY_PENDING:
			entry["state"] = STATE_RECOVERY_PENDING
			entry["reason"] = REASON_STATE_PERSIST_FAILED
			entry["recovery_pending"] = true
			entry["recovery_status"] = "STATE_PERSIST_FAILED"
			sess_obj.add_checkpoint(STATE_RECOVERY_PENDING, "Recovered checked transition that failed persistence")
		elif prev_state in ["STAGED", "LAUNCH_REQUESTED", "AWAITING_OPERATOR", "GAME_PROCESS_DETECTED", "MISSION_OBSERVED", "RESOURCE_PROBE_CONFIRMED", "STEAM_PROCESS_STARTED", "GAME_STARTED", "MISSION_LOADED"]:
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
	var stage_root := str(options.get("stage_root", "")).strip_edges()
	if stage_root == "":
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
	if not scenario.has("godot_prediction"):
		scenario["godot_prediction"] = {
			"damage": pred_dmg,
			"armor": armor,
			"shot_speed": profile.shot_speed if profile != null else 0.0,
			"life_span": profile.life_span if profile != null else 0.0,
		}

	var mission_base := str(options.get("mission_base", NativeAdapterScript.DEFAULT_MISSION_BASE))
	var terrain_name := str(options.get("terrain_name", NativeAdapterScript.DEFAULT_TERRAIN_NAME))
	var sess = NativeAdapterScript.create_session(stage_root, scenario, disc, mission_base, terrain_name)

	var extra_odfs: Dictionary = {}
	if options.has("staged_odfs") and options.staged_odfs is Dictionary:
		extra_odfs = (options.staged_odfs as Dictionary).duplicate(true)
	elif profile != null and index != null:
		extra_odfs = ResourceClosureScript.build_minimal_staged_odfs(profile, index, disc, true)
	elif profile != null and profile.ordnance_doc != null:
		extra_odfs["assets/ODF/" + profile.ordnance_path.get_file()] = profile.ordnance_doc.to_bytes()

	var files: Dictionary = NativeAdapterScript.build_experiment_files_for_session(sess, profile, extra_odfs)
	var closure_spec: Dictionary = {}
	if index != null or bool(options.get("check_closure", false)):
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
	var pre: Dictionary = NativeAdapterScript.preflight_experiment(
		stage_root, files, sess.scenario, disc, steam_override, sess, index if not closure_spec.is_empty() else null, closure_spec
	)
	var preflight_passed := bool(pre.get("structurally_valid", false))
	var state := "PREFLIGHT_OK" if bool(pre.get("launch_ready", false)) else ("BLOCKED" if preflight_passed else "FAILED")
	sess.add_checkpoint(state, "Preflight finished: route=%s reason=%s" % [str(pre.get("launch_route", "")), str(pre.get("reason", ""))])

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
	var record := {
		"schema": LEDGER_SCHEMA,
		"session_id": sid,
		"stage_id": str(sess.stage_id),
		"stage_root": stage_root,
		"state": state,
		"evidence_state": "STRUCTURALLY_VALID" if preflight_passed else "FAILED",
		"preflight_passed": preflight_passed and pkg_ok,
		"launch_eligible": preflight_passed and pkg_ok,
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
		record["launch_eligible"] = false
		record["restart_resumable"] = false
		record["reason"] = "PREFLIGHT_PERSIST_FAILED"
		return {
			"ok": false,
			"preflight_passed": false,
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
		record["launch_eligible"] = false
		record["restart_resumable"] = false
		record["reason"] = "PREFLIGHT_PERSIST_FAILED"
		return {
			"ok": false,
			"preflight_passed": false,
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
		"launch_eligible": preflight_passed,
		"launch_ready": bool(pre.get("launch_ready", false)),
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
	var rec_eligible := bool(record.get("launch_eligible", false))
	if not pre_passed or not rec_eligible:
		var fail_reason := str(record.get("reason", "PREFLIGHT_FAILED"))
		if fail_reason == "":
			fail_reason = "PREFLIGHT_FAILED"
		return {
			"ok": false,
			"state": "REJECTED",
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
	record["launch_eligible"] = true
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
		"launch_eligible": true,
	}
	record["evidence"] = (stg.get("evidence", {}) as Dictionary).duplicate(true)
	var staged_commit := _commit_transition(session_id, record, "STAGED", "Staged via SafeStageManager")
	if not bool(staged_commit.get("ok", false)):
		staged_commit["session_id"] = session_id
		staged_commit["evidence_state"] = STATE_RECOVERY_PENDING
		staged_commit["launch_eligible"] = false
		return staged_commit
	return {
		"ok": true,
		"session_id": session_id,
		"state": "STAGED",
		"evidence_state": "STAGED",
		"launch_eligible": true,
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

	# P1-NATIVE-04: Fail-closed when preflight_passed or launch_eligible is missing or false.
	if not record.has("preflight_passed") or not record.has("launch_eligible"):
		return {
			"ok": false,
			"state": "REJECTED",
			"reason": "PREFLIGHT_STATE_MISSING",
			"launch_rejected": true,
			"error": "LAUNCH_REJECTED: persisted session missing preflight state (fail-closed)",
		}
	if not bool(record.get("preflight_passed", false)) or not bool(record.get("launch_eligible", false)):
		var rej_reason := str(record.get("reason", "LAUNCH_REJECTED"))
		if rej_reason == "" or rej_reason == "DIAGNOSTIC_ONLY":
			rej_reason = "LAUNCH_REJECTED"
		return {
			"ok": false,
			"state": "REJECTED",
			"reason": rej_reason,
			"launch_rejected": true,
			"error": "LAUNCH_REJECTED: preflight not passed or session not launch-eligible (" + rej_reason + ")",
		}

	if str(sess.stage_manifest_path) == "" or not FileAccess.file_exists(str(sess.stage_manifest_path)):
		return {"ok": false, "state": "REJECTED", "reason": "NOT_STAGED", "launch_rejected": true, "error": "stage the experiment before launching"}

	# P0-02 / N-05 / N-D10: Re-verify staged files immediately before launch.
	var stg_check := _verify_staged_integrity_before_launch(sess)
	if not bool(stg_check.get("ok", false)):
		var mod_reason := str(stg_check.get("reason", "STAGE_MODIFIED_AFTER_PREFLIGHT"))
		sess.add_checkpoint("FAILED", "Stage integrity check failed before launch: " + str(stg_check.get("detail", mod_reason)))
		record["state"] = "FAILED"
		record["launch_eligible"] = false
		record["reason"] = mod_reason
		record["session"] = sess.to_dict()
		record["updated_at"] = Time.get_datetime_string_from_system()
		_persist_session(session_id, record)
		return {"ok": false, "state": "REJECTED", "reason": mod_reason, "launch_rejected": true, "detail": str(stg_check.get("detail", ""))}

	var disc: Dictionary = record.get("discovery", {})
	var pre: Dictionary = record.get("preflight", {})
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
	var cmd: Dictionary = NativeAdapterScript.build_launch_command(route, disc, str(sess.config_path), mission_bzn)
	var now := Time.get_datetime_string_from_system()

	if route == "OPERATOR_MANUAL" or route == "STEAM_LAUNCH_OPTIONS":
		var instr_lines := PackedStringArray([
			"BZ_ODF_SHAMAN Native Experiment Operator Handoff",
			"session_id=" + str(sess.session_id),
			"launch_nonce=" + str(sess.launch_nonce),
			"stage_root=" + str(sess.stage_root),
			"route=" + route,
			"steam_app_id=" + NativeAdapterScript.STEAM_APP_ID,
			"config_path=" + str(sess.config_path).replace("/", "\\"),
			"mission_bzn=" + mission_bzn,
			"launch_options=/nointro /win /logconsole /config \"%s\" \"%s\"" % [str(sess.config_path).replace("/", "\\"), mission_bzn],
			"observation_expected_path=" + str(sess.observation_expected_path),
			"instructions=" + str(cmd.get("instructions", cmd.get("launch_options_text", ""))),
		])
		var instr_path := str(sess.stage_root).path_join("operator_instructions.txt")
		var instr_res: Dictionary = {"ok": false, "error": "injected operator_instructions.txt write failure"} if fault_fail_operator_instructions_write else WorkspaceStore.atomic_write_abs(instr_path, "\n".join(instr_lines).to_utf8_buffer())
		if not bool(instr_res.get("ok", false)):
			return _fail_transition(session_id, record, "AWAITING_OPERATOR", "operator_instructions.txt write failed")
		sess.add_checkpoint("AWAITING_OPERATOR", "Operator manual handoff written to " + instr_path)
		record["state"] = "AWAITING_OPERATOR"
		record["evidence_state"] = "LAUNCH_REQUESTED"
		record["launch_route"] = route
		record["reason"] = str(pre.get("reason", "OPERATOR_MANUAL_HANDOFF"))
		record["updated_at"] = now
		record["launch"] = {
			"mode": route,
			"executed": false,
			"requested_at": now,
			"command": cmd,
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
			"reason": str(record.reason),
			"command": cmd,
			"instructions_path": instr_path,
			"observation_expected_path": str(sess.observation_expected_path),
			"session_id": session_id,
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


func _save_monitors() -> void:
	if not sessions.is_empty():
		var doc := {"schema": LEDGER_SCHEMA, "updated": Time.get_datetime_string_from_system(), "monitors": {}}
		for sid in monitors:
			doc["monitors"][sid] = (monitors[sid] as RefCounted).to_dict()
		WorkspaceStore.atomic_write_abs(
			ledger_dir().path_join("process_monitors.json"), JSON.stringify(doc, "  ").to_utf8_buffer()
		)


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
	_save_monitors()
	return {"ok": true, "session_id": session_id, "state": monitor.state, "active": monitor.active}


func _persist_monitor_state(session_id: String, monitor, record: Dictionary, state: String) -> bool:
	monitor.state = state
	record["monitor"] = monitor.to_dict()
	record["state"] = state
	record["evidence_state"] = state
	var commit := _commit_transition(session_id, record, state, "NativeProcessMonitor state=" + state)
	return bool(commit.get("ok", false))


## Advance an active monitor by one bounded poll. `now_s` is an injectable clock
## so tests never depend on real waits; `observation_path` may supply an on-disk
## artifact when the monitor has already confirmed mission + resource probe.
func poll_monitor(session_id: String, now_s: float = -1.0, observation_path: String = "") -> Dictionary:
	if not monitors.has(session_id):
		return {"ok": false, "state": "NO_ACTIVE_MONITOR", "reason": "NO_ACTIVE_MONITOR", "active": false}
	var monitor = monitors[session_id]
	if not bool(monitor.active) or monitor.is_terminal():
		var d: Dictionary = monitor.result()
		d["ok"] = false
		d["reason"] = "MONITOR_NOT_ACTIVE"
		return d
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
		_save_monitors()
		return monitor.result()

	if monitor.state == "STEAM_PROCESS_STARTED":
		var det: Dictionary = monitor.detect_game(process_inspector, game_process_detector)
		if bool(det.get("detected", false)):
			var record0: Dictionary = sessions.get(session_id, {})
			if not _persist_monitor_state(session_id, monitor, record0, "GAME_PROCESS_DETECTED"):
				var failed := _fail_transition(session_id, record0, "GAME_PROCESS_DETECTED", "checked transition persist failed")
				failed["session_id"] = session_id
				return failed
			_save_monitors()
			return monitor.result()

	elif monitor.state in ["GAME_PROCESS_DETECTED", "MISSION_OBSERVED", "RESOURCE_PROBE_CONFIRMED"]:
		var sess = NativeSessionScript.from_dict((sessions.get(session_id, {}) as Dictionary).get("session", {}))
		if sess == null:
			return {"ok": false, "state": "INVALID_SESSION", "reason": "INVALID_SESSION", "active": false}
		var probe := _observe_mission_and_probe(sess)
		monitor.apply_mission_probe(probe)
		var record1: Dictionary = sessions.get(session_id, {})
		if not _persist_monitor_state(session_id, monitor, record1, monitor.state):
			var failed1 := _fail_transition(session_id, record1, monitor.state, "checked probe transition persist failed")
			failed1["session_id"] = session_id
			return failed1

		if monitor.state == "RESOURCE_PROBE_CONFIRMED" and observation_path != "":
			var obs_res := collect_observation(session_id, observation_path)
			var out: Dictionary = monitor.result()
			out["observation_collected"] = bool(obs_res.get("ok", false))
			out["comparison_complete"] = bool(obs_res.get("comparison_complete", obs_res.get("ok", false)))
			out["verified"] = bool(obs_res.get("verified", false))
			out["state"] = str(obs_res.get("state", monitor.state))
			out["native_verified"] = bool(obs_res.get("verified", false))
			monitor.finish_collection(out)
			_save_monitors()
			return out

	monitor.polls = int(monitor.polls)
	_save_monitors()
	return monitor.result()


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
	if monitors.has(session_id):
		return (monitors[session_id] as RefCounted).result()
	return {"ok": false, "state": "NO_MONITOR_TO_RESUME", "reason": "NO_MONITOR_TO_RESUME", "active": false}


func cancel_monitor(session_id: String) -> Dictionary:
	if not monitors.has(session_id):
		return {"ok": false, "state": "NO_ACTIVE_MONITOR", "reason": "NO_ACTIVE_MONITOR", "active": false}
	var monitor = monitors[session_id]
	monitor.cancel()
	var record: Dictionary = sessions.get(session_id, {})
	_commit_transition(session_id, record, "CANCELLED", "Monitor cancelled by operator")
	_save_monitors()
	return monitor.result()


## Step 5: Safe MD5-verified cleanup of the staged directory via SafeStageManager.
func cleanup_stage(session_id: String) -> Dictionary:
	if not sessions.has(session_id):
		return {"ok": false, "reason": "UNKNOWN_SESSION", "error": "session not found in ledger: " + session_id}
	var record: Dictionary = sessions[session_id]
	var sess = NativeSessionScript.from_dict(record.get("session", {}))
	if sess == null:
		return {"ok": false, "reason": "INVALID_SESSION", "error": "cannot deserialize session"}
	var disc: Dictionary = record.get("discovery", {})
	var extra_prot: Array[String] = []
	for k in ["game_root", "data_root", "res_root", "missions_dll_root", "workshop_root", "addon_root"]:
		var p := str(disc.get(k, ""))
		if p != "":
			extra_prot.append(p)
	var cl: Dictionary = SafeStageScript.cleanup(str(sess.stage_root), extra_prot)
	var new_state := "CLEANED_UP" if (bool(cl.get("ok", false)) and not bool(cl.get("partial", false))) else ("PARTIAL_CLEANUP" if bool(cl.get("partial", false)) else "FAILED")
	sess.add_checkpoint(new_state, "Stage cleanup: status=%s removed=%d" % [str(cl.get("status", "")), int(cl.get("removed", 0))])
	record["state"] = new_state
	record["cleanup"] = cl
	record["session"] = sess.to_dict()
	record["updated_at"] = Time.get_datetime_string_from_system()
	_pending_files.erase(session_id)
	var cleanup_commit := _commit_transition(session_id, record, new_state, "Stage cleanup completed")
	if not bool(cleanup_commit.get("ok", false)):
		cleanup_commit["session_id"] = session_id
		cleanup_commit["cleanup"] = cl
		return cleanup_commit
	return {
		"ok": bool(cl.get("ok", false)),
		"state": new_state,
		"cleanup": cl,
		"session_id": session_id,
	}
