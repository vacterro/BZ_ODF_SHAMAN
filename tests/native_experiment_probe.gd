extends SceneTree
## Reproducible real-BZCC native experiment probe (T-20 / P2-01).
## Uses the real adapter and runner with no DI hooks. All writes stay under an
## isolated WorkspaceStore root; the game root is only read, never modified.
## Emits a durable JSON evidence artifact containing preflight, stage, launch,
## bounded monitor polls, observation collection and the exact blocker/verdict.

const RunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const AdapterScript = preload("res://scripts/native/native_test_adapter.gd")
const WorkspaceScript = preload("res://scripts/core/workspace_store.gd")

const MAX_WAIT_S := 90.0
const POLL_INTERVAL_MS := 500


func _initialize() -> void:
	var root := "user://t20_native_probe_" + str(Time.get_ticks_usec())
	OS.set_environment(WorkspaceScript.ENV_ROOT, root)
	var evidence_dir := ProjectSettings.globalize_path("res://.saipen/evidence/native")
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	var evidence_path := evidence_dir.path_join("T-20-native-probe-" + str(Time.get_ticks_usec()) + ".json")

	var out := {
		"schema": 1,
		"ticket": "T-20",
		"workspace_root": root,
		"started_at": Time.get_datetime_string_from_system(),
		"discovery": {},
		"preflight": {},
		"stage": {},
		"launch": {},
		"monitor": {},
		"observation": {},
		"cleanup": {},
		"verdict": "BLOCKED",
		"reason": "",
	}
	var runner = RunnerScript.new()
	AdapterScript.clear_trusted_sessions()
	var disc: Dictionary = AdapterScript.discover()
	out.discovery = disc
	if not bool(disc.get("ok", false)):
		out.reason = "NATIVE_EXE_NOT_FOUND"
		_write(evidence_path, out)
		quit(1)
		return

	var odf_bytes := "[OrdnanceClass]\ndamageValue(H)=100\nshotSpeed=120\nshotRadius=0.5\nlifeSpan=0.834\n".to_utf8_buffer()
	var pre: Dictionary = runner.preflight(null, null, {
		"discovery": disc,
		"stage_prefix": "t20_real",
		"staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes},
	})
	out.preflight = {
		"ok": bool(pre.get("ok", false)),
		"state": str(pre.get("state", "")),
		"reason": str(pre.get("reason", "")),
		"session_id": str(pre.get("session_id", "")),
		"launch_route": str(pre.get("launch_route", "")),
		"launch_ready": bool(pre.get("launch_ready", false)),
	}
	if not bool(pre.get("ok", false)):
		out.reason = "PREFLIGHT_FAILED"
		_write(evidence_path, out)
		quit(1)
		return

	var sid := str(pre.get("session_id", ""))
	var stg: Dictionary = runner.stage(sid)
	var staged_session = stg.get("session", null)
	out.stage = {
		"ok": bool(stg.get("ok", false)),
		"state": str(stg.get("state", "")),
		"stage_root": str(staged_session.stage_root) if staged_session != null else "",
	}
	if not bool(stg.get("ok", false)):
		out.reason = "STAGE_FAILED"
		_write(evidence_path, out)
		quit(1)
		return

	var launch: Dictionary = runner.launch(sid, {
		"execute_process": true,
		"monitor_timeout_s": MAX_WAIT_S,
		"monitor_max_polls": int(MAX_WAIT_S / (POLL_INTERVAL_MS / 1000.0)),
	})
	out.launch = {
		"ok": bool(launch.get("ok", false)),
		"state": str(launch.get("state", "")),
		"route": str(launch.get("route", "")),
		"process_id": int(launch.get("process_id", 0)),
		"game_pid": int(launch.get("game_pid", 0)),
		"reason": str(launch.get("reason", "")),
	}

	var waited := 0.0
	var last_poll: Dictionary = {}
	while waited < MAX_WAIT_S:
		OS.delay_msec(POLL_INTERVAL_MS)
		waited += POLL_INTERVAL_MS / 1000.0
		last_poll = runner.poll_monitor(sid)
		var state := str(last_poll.get("state", ""))
		if state in ["COMPARISON_COMPLETE", "NATIVE_VERIFIED", "TIMEOUT", "CANCELLED", "FAILED"]:
			break
		var obs_path := str((runner.get_session_record(sid).get("session", {}) as Dictionary).get("observation_expected_path", ""))
		if obs_path != "" and FileAccess.file_exists(obs_path):
			break
	out.monitor = {
		"waited_s": waited,
		"state": str(last_poll.get("state", "")),
		"game_pid": int(last_poll.get("game_pid", 0)),
		"game_exe_verified": bool(last_poll.get("game_exe_verified", false)),
		"mission_observed": bool(last_poll.get("mission_observed", false)),
		"resource_probe_confirmed": bool(last_poll.get("resource_probe_confirmed", false)),
		"polls": int(last_poll.get("polls", 0)),
		"reason": str(last_poll.get("reason", "")),
	}

	var obs_path := str((runner.get_session_record(sid).get("session", {}) as Dictionary).get("observation_expected_path", ""))
	if obs_path != "" and FileAccess.file_exists(obs_path):
		var col: Dictionary = runner.collect_observation(sid, obs_path)
		out.observation = {
			"path": obs_path,
			"ok": bool(col.get("ok", false)),
			"state": str(col.get("state", "")),
			"verified": bool(col.get("verified", false)),
			"reason": str(col.get("reason", "")),
		}
		out.verdict = "NATIVE_VERIFIED" if bool(col.get("verified", false)) else "COMPARISON_COMPLETE"
		out.reason = "LuaMission observation artifact collected from disk"
	else:
		out.observation = {
			"expected_path": obs_path,
			"exists": false,
			"reason": "OBSERVATION_ARTIFACT_MISSING",
		}
		out.reason = "BZCC launched/detected but no session-bound LuaMission observation artifact appeared within %d s; not attested" % int(MAX_WAIT_S)

	out.diagnostics = _collect_launch_diagnostics(str(out.get("stage", {}).get("stage_root", "")), str(pre.get("session_id", "")))
	out.reason = out.diagnostics.get("blocker_summary", out.reason)
	var cl: Dictionary = runner.cleanup_stage(sid)
	out.cleanup = {"ok": bool(cl.get("ok", false)), "state": str(cl.get("state", ""))}
	out.finished_at = Time.get_datetime_string_from_system()
	_write(evidence_path, out)
	quit(0)


func _collect_launch_diagnostics(stage_root: String, session_id: String) -> Dictionary:
	var out := {
		"steam_launch_lines": [],
		"bzcc_startup_log": "",
		"bzcc_startup_tail": "",
		"staged_observation_files": [],
		"blocker_summary": "",
	}
	var steam_log := "C:/Program Files (x86)/Steam/logs/console_log.txt"
	if not FileAccess.file_exists(steam_log):
		steam_log = "V:/__STORE_V/_SOFT/Steam/logs/console_log.txt"
	if FileAccess.file_exists(steam_log):
		var lines := FileAccess.get_file_as_string(steam_log).split("\n")
		for i in range(maxi(0, lines.size() - 400), lines.size()):
			var line := str(lines[i]).strip_edges()
			if line.contains(stage_root.replace("\\", "/")) or line.contains(stage_root.replace("/", "\\")):
				out.steam_launch_lines.append(line)
	var docs := WorkspaceStore.canonical(OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)).path_join("My Games/Battlezone Combat Commander")
	var dir := DirAccess.open(docs)
	if dir != null:
		var newest := ""
		var newest_mtime := 0
		for name in dir.get_files():
			if not str(name).begins_with("Battlezone-Crashed") or not str(name).ends_with(".log"):
				continue
			var p := docs.path_join(str(name))
			var mt := FileAccess.get_modified_time(p)
			if mt > newest_mtime:
				newest_mtime = mt
				newest = p
		if newest != "":
			out.bzcc_startup_log = newest
			var txt := FileAccess.get_file_as_string(newest)
			var tlines := txt.split("\n")
			var tail: Array[String] = []
			for i in range(maxi(0, tlines.size() - 14), tlines.size()):
				tail.append(str(tlines[i]).strip_edges())
			out.bzcc_startup_tail = "\n".join(tail)
		if stage_root != "":
			var tag := stage_root.get_file().substr(0, 24)
			var profile := docs.path_join("SHAMAN_" + tag)
			var pd := DirAccess.open(profile)
			if pd != null:
				_scan_obs_files(pd, profile, out.staged_observation_files)
	if out.steam_launch_lines.is_empty():
		out.blocker_summary = "Steam -applaunch did not record staged config/mission in client log; launch not proven"
	elif out.bzcc_startup_tail.contains("Command line /config used") and not out.bzcc_startup_tail.contains("Config: 'AddDirRecurse'"):
		out.blocker_summary = "BZCC accepted staged /config and mission command line but terminated before filesystem/mission initialization; no session-bound LuaMission observation artifact (session=%s)" % session_id
	else:
		out.blocker_summary = "No session-bound LuaMission observation artifact; inspect steam_launch_lines and bzcc_startup_tail"
	return out


func _scan_obs_files(dir: DirAccess, path: String, result: Array) -> void:
	for name in dir.get_files():
		if str(name).begins_with("shaman_obs_") and str(name).ends_with(".json"):
			result.append(path.path_join(str(name)))
	for sub in dir.get_directories():
		var subdir := DirAccess.open(path.path_join(str(sub)))
		if subdir != null:
			_scan_obs_files(subdir, path.path_join(str(sub)), result)


func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("cannot write native probe evidence: " + path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("T20_EVIDENCE=" + path)
	print("T20_VERDICT=" + str(data.get("verdict", "")) + " " + str(data.get("reason", "")))
