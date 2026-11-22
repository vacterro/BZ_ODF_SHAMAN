extends SceneTree
## Reproducible real-BZCC native experiment probe (P0-NATIVE-02, P1-EVIDENCE-01).
## Uses a real ResourceIndex + WeaponProfile + strict complete resource closure
## against a stock-only scenario by default (ivtank / ivscav / gminigun_c), or
## an explicit VSR integration fixture when `--vsr` is supplied.
## All writes stay under an isolated WorkspaceStore root; BZ2R is strictly read-only.

const RunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const AdapterScript = preload("res://scripts/native/native_test_adapter.gd")
const WorkspaceScript = preload("res://scripts/core/workspace_store.gd")

const MAX_WAIT_S := 90.0
const POLL_INTERVAL_MS := 500


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var use_vsr := args.has("--vsr")
	var allow_launch := args.has("--launch")
	var use_stock_addon := not args.has("--custom-config")
	var launch_started_unix := int(Time.get_unix_time_from_system())

	var root := "user://native_probe_" + str(Time.get_ticks_usec())
	OS.set_environment(WorkspaceScript.ENV_ROOT, root)
	var evidence_dir := ProjectSettings.globalize_path("res://.saipen/evidence/native")
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	var evidence_path := evidence_dir.path_join("native-probe-" + str(Time.get_ticks_usec()) + ".json")

	var out := {
		"schema": 2,
		"fixture": "vsr" if use_vsr else "stock_only",
		"workspace_root": root,
		"started_at": Time.get_datetime_string_from_system(),
		"discovery": {},
		"preflight": {},
		"stage": {},
		"launch": {},
		"monitor": {},
		"observation": {},
		"diagnostics": {},
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

	# P0-NATIVE-02: Build a real ResourceIndex + strict ModLoadout + WeaponProfile
	# so preflight verifies complete resource closure (shooter, target, weapon, ordnance).
	var index := ResourceIndex.new()
	var res_root := str(disc.get("res_root", str(disc.get("game_root", AdapterScript.DEFAULT_GAME_ROOT)).path_join("bz2r_res")))
	var ws_root := str(disc.get("workshop_root", ""))
	index.roots = [{"path": res_root, "label": "base", "kind": "game", "priority": 10, "enabled": true}]
	if ws_root != "":
		index.roots.append({"path": ws_root, "label": "workshop", "kind": "workshop", "priority": 30, "enabled": true})
	index.scan(use_vsr)
	var active_pkgs: Array[String] = []
	var shooter_name := "ivtank"
	var target_name := "ivscav"
	var weapon_override := ""
	if use_vsr:
		active_pkgs = ["3532748119"]
		shooter_name = "ivtank_vsr"
		target_name = "ivscav_vsr"
		weapon_override = "gatstabvsr_c"
	index.set_active_packages(active_pkgs, true)
	var shooter_path := index.resolve_path(shooter_name)
	var target_path := index.resolve_path(target_name)
	var profile := WeaponProfile.new()
	var prof_ok := shooter_path != "" and target_path != "" and profile.resolve(index, shooter_path, target_path, weapon_override)
	if not prof_ok:
		out.reason = "RESOURCE_CLOSURE_INCOMPLETE"
		out.preflight = {
			"ok": false,
			"reason": "RESOURCE_CLOSURE_INCOMPLETE",
			"shooter_path": shooter_path,
			"target_path": target_path,
			"errors": profile.errors,
		}
		_write(evidence_path, out)
		quit(1)
		return

	var pre: Dictionary = runner.preflight(profile, index, {
		"discovery": disc,
		"stage_prefix": "shaman_vsr" if use_vsr else "shaman_stock",
		"launch_mode": "STOCK_ADDON" if use_stock_addon else "CUSTOM_CONFIG",
		"check_closure": true,
		"require_complete_closure": true,
		"active_packages": active_pkgs,
		"mounted_workshop_packages": active_pkgs,
	})
	var pre_detail: Dictionary = pre.get("preflight", {})
	out.preflight = {
		"ok": bool(pre.get("ok", false)),
		"state": str(pre.get("state", "")),
		"reason": str(pre.get("reason", "")),
		"session_id": str(pre.get("session_id", "")),
		"launch_mode": str(pre.get("launch_mode", "")),
		"launch_route": str(pre_detail.get("launch_route", "")),
		"stage_eligible": bool(pre.get("stage_eligible", false)),
		"config_compatible": bool(pre.get("config_compatible", false)),
		"execution_environment_ready": bool(pre.get("execution_environment_ready", false)),
		"launch_ready": bool(pre.get("launch_ready", false)),
		"launch_eligible": bool(pre.get("launch_eligible", false)),
		"closure_status": str((pre_detail.get("resource_closure", {}) as Dictionary).get("status", "")),
		"config_diagnostics": (pre_detail.get("launch_command", {}) as Dictionary).get("config_diagnostics", {}),
	}
	if not bool(pre.get("ok", false)):
		out.reason = str(pre.get("reason", "RESOURCE_CLOSURE_INCOMPLETE"))
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

	if not allow_launch:
		out.verdict = "STAGED_DRY_RUN"
		out.reason = "Complete resource closure staged; pass --launch to execute authorized BZCC launch"
		var cl0: Dictionary = runner.cleanup_stage(sid)
		out.cleanup = {"ok": bool(cl0.get("ok", false)), "state": str(cl0.get("state", ""))}
		out.finished_at = Time.get_datetime_string_from_system()
		_write(evidence_path, out)
		quit(0)
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
		if state in ["COMPARISON_COMPLETE", "NATIVE_VERIFIED", "TIMEOUT", "CANCELLED", "FAILED", "RECOVERY_PENDING"]:
			break
	out.monitor = {
		"waited_s": waited,
		"state": str(last_poll.get("state", "")),
		"game_pid": int(last_poll.get("game_pid", 0)),
		"game_exe_verified": bool(last_poll.get("game_exe_verified", false)),
		"mission_observed": bool(last_poll.get("mission_observed", false)),
		"resource_probe_confirmed": bool(last_poll.get("resource_probe_confirmed", false)),
		"observation_collected": bool(last_poll.get("observation_collected", false)),
		"polls": int(last_poll.get("polls", 0)),
		"reason": str(last_poll.get("reason", "")),
	}

	var rec_sess: Dictionary = (runner.get_session_record(sid).get("session", {}) as Dictionary)
	var obs_path := str(rec_sess.get("observation_expected_path", ""))
	if bool(last_poll.get("observation_collected", false)):
		out.observation = {
			"path": obs_path,
			"ok": true,
			"state": str(last_poll.get("state", "")),
			"verified": bool(last_poll.get("verified", false)),
		}
		out.verdict = "NATIVE_VERIFIED" if bool(last_poll.get("verified", false)) else "COMPARISON_COMPLETE"
		out.reason = "LuaMission observation artifact collected automatically by monitor"
	elif obs_path != "" and FileAccess.file_exists(obs_path):
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
		out.reason = "No session-bound LuaMission observation artifact appeared within %d s" % int(MAX_WAIT_S)

	out.diagnostics = _collect_launch_diagnostics(rec_sess, launch_started_unix)
	if str(out.diagnostics.get("blocker_summary", "")) != "":
		out.reason = str(out.diagnostics.get("blocker_summary", out.reason))
	var cl: Dictionary = runner.cleanup_stage(sid)
	out.cleanup = {"ok": bool(cl.get("ok", false)), "state": str(cl.get("state", ""))}
	out.finished_at = Time.get_datetime_string_from_system()
	_write(evidence_path, out)
	quit(0)


func _collect_launch_diagnostics(sess_dict: Dictionary, launch_started_unix: int) -> Dictionary:
	var stage_root := str(sess_dict.get("stage_root", ""))
	var session_id := str(sess_dict.get("session_id", ""))
	var docs := WorkspaceStore.canonical(OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)).path_join("My Games/Battlezone Combat Commander")
	var corr: Dictionary = AdapterScript.correlate_crash_logs(docs, {
		"stage_root": stage_root,
		"stage_id": str(sess_dict.get("stage_id", "")),
		"session_id": session_id,
		"config_path": str(sess_dict.get("config_path", "")),
		"mission_bzn": str(sess_dict.get("mission_basename", AdapterScript.DEFAULT_MISSION_BASE)) + ".bzn",
	}, launch_started_unix)
	var cls: Dictionary = AdapterScript.classify_startup_failure(str(corr.get("selected_tail", "")))
	return {
		"log_correlation": corr,
		"startup_classification": cls,
		"blocker_summary": "%s (confidence=%s, session=%s)" % [
			str(cls.get("code", "UNKNOWN_STARTUP_STATE")),
			str(corr.get("confidence", "UNRELATED")),
			session_id
		],
	}


func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("cannot write native probe evidence: " + path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("NATIVE_PROBE_EVIDENCE=" + path)
	print("NATIVE_PROBE_VERDICT=" + str(data.get("verdict", "")) + " " + str(data.get("reason", "")))
