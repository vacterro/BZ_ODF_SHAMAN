class_name NativeExperimentSession
extends RefCounted
## Immutable identity and lifecycle contract for a single native BZCC experiment.
## Created ONCE before generating Lua, BZN, mount config, staging manifest, or
## trusted execution receipts so every subsystem shares the exact same
## session_id, launch_nonce, stage_id, and observation_filename.

const SCHEMA_VERSION := 1

var session_id: String = ""
var launch_nonce: String = ""
var stage_id: String = ""
var scenario_id: String = ""
var scenario_revision: int = 1
var scenario_hash: String = ""
var stage_root: String = ""
var mission_basename: String = "shaman_shot"
var terrain_name: String = "test"
var bzn_path: String = ""
var lua_path: String = ""
var config_path: String = ""
var observation_filename: String = ""
var observation_expected_path: String = ""
var mount_marker: String = ""
var expected_odf_hashes: Dictionary = {}
var game_executable_hash: String = ""
var game_build_id: String = "UNKNOWN"
var launch_route: String = "UNSUPPORTED"
var state: String = "CREATED"
var created_at: String = ""
var updated_at: String = ""
var stage_manifest_path: String = ""
var stage_manifest_hash: String = ""
var evidence_path: String = ""
var mount_plan: Dictionary = {}
var closure_report: Dictionary = {}
var godot_prediction: Dictionary = {}
var scenario: Dictionary = {}
var launch_command: Dictionary = {}
var recovery_checkpoints: Array[Dictionary] = []

static var _seq := 0


static func create(p_stage_root: String, p_scenario: Dictionary, p_discovery: Dictionary = {},
		p_mission_base: String = "shaman_shot", p_terrain_name: String = "test",
		p_session_id: String = "", p_launch_nonce: String = "") -> RefCounted:
	_seq += 1
	var s = new()
	var canon_stage := WorkspaceStore.canonical(p_stage_root)
	var st_id := canon_stage.get_file()
	if st_id == "":
		st_id = "shaman_stage_%d_%d" % [Time.get_ticks_usec(), _seq]
	var sid := p_session_id.strip_edges()
	if sid == "":
		sid = "shaman_sess_%d_%d" % [Time.get_ticks_usec(), _seq]
	var nonce := p_launch_nonce.strip_edges()
	if nonce == "":
		nonce = ("%s|%s|%d|%d" % [sid, st_id, Time.get_ticks_usec(), randi()]).md5_text().substr(0, 16)
	var mbase := p_mission_base.strip_edges().get_basename()
	if mbase == "":
		mbase = "shaman_shot"
	var tname := p_terrain_name.strip_edges()
	if tname == "":
		tname = "test"

	var scn_copy := p_scenario.duplicate(true)
	var scn_id := str(scn_copy.get("id", scn_copy.get("scenario_id", ""))).strip_edges()
	if scn_id == "":
		scn_id = "scn_" + st_id
		scn_copy["id"] = scn_id
	var scn_rev := int(scn_copy.get("revision", 1))
	if scn_rev <= 0:
		scn_rev = 1
	scn_copy["revision"] = scn_rev
	scn_copy["session_id"] = sid
	scn_copy["launch_nonce"] = nonce
	scn_copy["stage_id"] = st_id

	var safe_sid := sid.replace("/", "_").replace("\\", "_").replace(" ", "_")
	var clean_tag := "SHAMAN_" + st_id.replace("/", "_").replace("\\", "_").replace(" ", "_").substr(0, 24)
	var docs := WorkspaceStore.canonical(OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
	var profile_dir := docs.path_join("My Games/Battlezone Combat Commander").path_join(clean_tag) if docs != "" else ""
	var logs_dir := profile_dir.path_join("Logs") if profile_dir != "" else ""
	var obs_file := "shaman_obs_%s.json" % safe_sid
	var assets_dir := canon_stage.path_join("assets")
	var cfg_path := canon_stage.path_join("shaman_native.cfg")

	s.session_id = sid
	s.launch_nonce = nonce
	s.stage_id = st_id
	s.scenario_id = scn_id
	s.scenario_revision = scn_rev
	s.scenario = scn_copy
	s.scenario_hash = JSON.stringify(scn_copy, "", true).md5_text()
	s.stage_root = canon_stage
	s.mission_basename = mbase
	s.terrain_name = tname
	s.bzn_path = assets_dir.path_join("Missions/%s.bzn" % mbase)
	s.lua_path = assets_dir.path_join("Missions/%s.lua" % mbase)
	s.config_path = cfg_path
	s.observation_filename = obs_file
	s.observation_expected_path = logs_dir.path_join(obs_file) if logs_dir != "" else ""
	s.mount_marker = "SHAMAN_MNT_" + nonce
	s.game_executable_hash = str(p_discovery.get("exe_md5", ""))
	s.game_build_id = str(p_discovery.get("build_id", "UNKNOWN"))
	s.godot_prediction = (scn_copy.get("godot_prediction", {}) as Dictionary).duplicate(true)
	s.state = "CREATED"
	var now := Time.get_datetime_string_from_system()
	s.created_at = now
	s.updated_at = now
	s.mount_plan = {
		"session_id": sid,
		"launch_nonce": nonce,
		"stage_id": st_id,
		"stage_absolute_path": canon_stage,
		"assets_mount_path": assets_dir,
		"assets_mount_win": canon_stage.path_join("assets").replace("/", "\\"),
		"bzcc_config_path": cfg_path,
		"bzcc_config_win": cfg_path.replace("/", "\\"),
		"bzcc_mydocs_tag": clean_tag,
		"bzcc_writable_profile_dir": profile_dir,
		"bzcc_logs_dir": logs_dir,
		"startup_log_path": profile_dir.path_join("battlezone.log") if profile_dir != "" else "",
		"observation_filename": obs_file,
		"observation_expected_path": s.observation_expected_path,
		"mount_marker": s.mount_marker,
		"mission_bzn": mbase + ".bzn",
		"mission_lua": mbase + ".lua",
	}
	s.add_checkpoint("CREATED", "Session initialized with immutable identifiers")
	return s


func add_checkpoint(new_state: String, detail: String = "") -> void:
	var now := Time.get_datetime_string_from_system()
	state = new_state
	updated_at = now
	recovery_checkpoints.append({
		"state": new_state,
		"at": now,
		"detail": detail,
	})


func set_expected_odf_hash(rel: String, md5: String, role: String = "", source_path: String = "", odf_name: String = "") -> void:
	expected_odf_hashes[rel] = {
		"rel": rel,
		"md5": md5.to_lower(),
		"role": role,
		"source_path": source_path,
		"odf_name": odf_name if odf_name != "" else rel.get_file(),
	}


func to_dict() -> Dictionary:
	return {
		"schema": SCHEMA_VERSION,
		"session_id": session_id,
		"launch_nonce": launch_nonce,
		"stage_id": stage_id,
		"scenario_id": scenario_id,
		"scenario_revision": scenario_revision,
		"scenario_hash": scenario_hash,
		"stage_root": stage_root,
		"mission_basename": mission_basename,
		"terrain_name": terrain_name,
		"bzn_path": bzn_path,
		"lua_path": lua_path,
		"config_path": config_path,
		"observation_filename": observation_filename,
		"observation_expected_path": observation_expected_path,
		"mount_marker": mount_marker,
		"expected_odf_hashes": expected_odf_hashes.duplicate(true),
		"game_executable_hash": game_executable_hash,
		"game_build_id": game_build_id,
		"launch_route": launch_route,
		"state": state,
		"created_at": created_at,
		"updated_at": updated_at,
		"stage_manifest_path": stage_manifest_path,
		"stage_manifest_hash": stage_manifest_hash,
		"evidence_path": evidence_path,
		"mount_plan": mount_plan.duplicate(true),
		"closure_report": closure_report.duplicate(true),
		"godot_prediction": godot_prediction.duplicate(true),
		"scenario": scenario.duplicate(true),
		"launch_command": launch_command.duplicate(true),
		"recovery_checkpoints": recovery_checkpoints.duplicate(true),
	}


static func from_dict(d: Dictionary) -> RefCounted:
	if d.is_empty():
		return null
	var s = new()
	s.session_id = str(d.get("session_id", ""))
	s.launch_nonce = str(d.get("launch_nonce", ""))
	s.stage_id = str(d.get("stage_id", ""))
	s.scenario_id = str(d.get("scenario_id", ""))
	s.scenario_revision = int(d.get("scenario_revision", 1))
	s.scenario_hash = str(d.get("scenario_hash", ""))
	s.stage_root = str(d.get("stage_root", ""))
	s.mission_basename = str(d.get("mission_basename", "shaman_shot"))
	s.terrain_name = str(d.get("terrain_name", "test"))
	s.bzn_path = str(d.get("bzn_path", ""))
	s.lua_path = str(d.get("lua_path", ""))
	s.config_path = str(d.get("config_path", ""))
	s.observation_filename = str(d.get("observation_filename", ""))
	s.observation_expected_path = str(d.get("observation_expected_path", ""))
	s.mount_marker = str(d.get("mount_marker", ""))
	s.expected_odf_hashes = (d.get("expected_odf_hashes", {}) as Dictionary).duplicate(true)
	s.game_executable_hash = str(d.get("game_executable_hash", ""))
	s.game_build_id = str(d.get("game_build_id", "UNKNOWN"))
	s.launch_route = str(d.get("launch_route", "UNSUPPORTED"))
	s.state = str(d.get("state", "CREATED"))
	s.created_at = str(d.get("created_at", ""))
	s.updated_at = str(d.get("updated_at", ""))
	s.stage_manifest_path = str(d.get("stage_manifest_path", ""))
	s.stage_manifest_hash = str(d.get("stage_manifest_hash", ""))
	s.evidence_path = str(d.get("evidence_path", ""))
	s.mount_plan = (d.get("mount_plan", {}) as Dictionary).duplicate(true)
	s.closure_report = (d.get("closure_report", {}) as Dictionary).duplicate(true)
	s.godot_prediction = (d.get("godot_prediction", {}) as Dictionary).duplicate(true)
	s.scenario = (d.get("scenario", {}) as Dictionary).duplicate(true)
	s.launch_command = (d.get("launch_command", {}) as Dictionary).duplicate(true)
	s.recovery_checkpoints.clear()
	for cp in d.get("recovery_checkpoints", []):
		if cp is Dictionary:
			s.recovery_checkpoints.append((cp as Dictionary).duplicate(true))
	return s


## Extract literal Lua local string constant (`local NAME = "VALUE"`) from generated Lua.
static func extract_lua_const(lua_text: String, const_name: String) -> String:
	var prefix := "local %s = \"" % const_name
	for raw_line in lua_text.replace("\r\n", "\n").split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with(prefix):
			var rest := line.substr(prefix.length())
			var q := rest.find("\"")
			if q >= 0:
				return rest.substr(0, q)
	return ""


## Cross-check real generated Lua text, mount plan, stage manifest, receipt,
## and evidence against this session's immutable identifiers.
func validate_consistency(files: Dictionary, p_mount_plan: Dictionary = {},
		p_stage_manifest: Dictionary = {}, p_receipt: Dictionary = {},
		p_evidence: Dictionary = {}) -> Dictionary:
	var errors: Array[String] = []
	var lua_rel := "assets/Missions/%s.lua" % mission_basename
	var lua_raw = files.get(lua_rel, "")
	var lua_text: String = (lua_raw as PackedByteArray).get_string_from_utf8() if lua_raw is PackedByteArray else str(lua_raw)
	if lua_text == "" and lua_path != "" and FileAccess.file_exists(lua_path):
		lua_text = FileAccess.get_file_as_string(lua_path)

	var lua_sid := extract_lua_const(lua_text, "SESSION_ID")
	var lua_nonce := extract_lua_const(lua_text, "LAUNCH_NONCE")
	var lua_obs := extract_lua_const(lua_text, "OBS_FILE")
	var lua_marker := extract_lua_const(lua_text, "EXPECTED_MARKER")

	if lua_sid == "" or lua_sid != session_id:
		errors.append("Lua SESSION_ID '%s' != session.session_id '%s'" % [lua_sid, session_id])
	if lua_nonce == "" or lua_nonce != launch_nonce:
		errors.append("Lua LAUNCH_NONCE '%s' != session.launch_nonce '%s'" % [lua_nonce, launch_nonce])
	if lua_obs == "" or lua_obs != observation_filename:
		errors.append("Lua OBS_FILE '%s' != session.observation_filename '%s'" % [lua_obs, observation_filename])
	if lua_marker == "" or lua_marker != mount_marker:
		errors.append("Lua EXPECTED_MARKER '%s' != session.mount_marker '%s'" % [lua_marker, mount_marker])

	var mp := p_mount_plan if not p_mount_plan.is_empty() else mount_plan
	if not mp.is_empty():
		var mp_obs := str(mp.get("observation_filename", ""))
		var mp_exp_base := str(mp.get("observation_expected_path", "")).get_file()
		if mp_obs != observation_filename:
			errors.append("MountPlan observation_filename '%s' != '%s'" % [mp_obs, observation_filename])
		if mp_exp_base != "" and mp_exp_base != lua_obs:
			errors.append("basename(MountPlan.observation_expected_path) '%s' != Lua.OBS_FILE '%s'" % [mp_exp_base, lua_obs])
		if str(mp.get("session_id", "")) != "" and str(mp.get("session_id", "")) != session_id:
			errors.append("MountPlan session_id '%s' != '%s'" % [str(mp.get("session_id", "")), session_id])

	if not p_stage_manifest.is_empty():
		var sm_id := str(p_stage_manifest.get("stage_id", ""))
		if sm_id != stage_id:
			errors.append("StageManifest stage_id '%s' != session.stage_id '%s'" % [sm_id, stage_id])

	if not p_receipt.is_empty():
		if str(p_receipt.get("session_id", "")) != session_id:
			errors.append("Receipt session_id '%s' != '%s'" % [str(p_receipt.get("session_id", "")), session_id])
		if str(p_receipt.get("launch_nonce", "")) != launch_nonce:
			errors.append("Receipt launch_nonce '%s' != '%s'" % [str(p_receipt.get("launch_nonce", "")), launch_nonce])

	if not p_evidence.is_empty():
		var ev_sid := str(p_evidence.get("session_id", ""))
		if ev_sid != session_id:
			errors.append("Evidence session_id '%s' != '%s'" % [ev_sid, session_id])
		var ev_scn = p_evidence.get("scenario", {})
		if ev_scn is Dictionary and str(ev_scn.get("session_id", "")) != session_id:
			errors.append("Scenario session_id '%s' != '%s'" % [str(ev_scn.get("session_id", "")), session_id])
		var ev_mp = p_evidence.get("mount_plan", {})
		if ev_mp is Dictionary:
			var ev_obs := str(ev_mp.get("observation_expected_path", "")).get_file()
			if ev_obs != "" and ev_obs != lua_obs:
				errors.append("Evidence mount_plan observation '%s' != Lua.OBS_FILE '%s'" % [ev_obs, lua_obs])

	return {
		"ok": errors.is_empty(),
		"reason": "" if errors.is_empty() else "SESSION_IDENTITY_MISMATCH",
		"errors": errors,
		"lua_session_id": lua_sid,
		"lua_launch_nonce": lua_nonce,
		"lua_obs_file": lua_obs,
		"lua_mount_marker": lua_marker,
	}
