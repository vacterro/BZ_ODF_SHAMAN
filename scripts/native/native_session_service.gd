class_name NativeSessionService
extends Node
## Application-owned native BZCC experiment lifecycle service (P1-NATIVE-03).
## Lives at the MainWindow root so switching tabs (Weapons Lab -> Particle Lab
## -> Inspector) never interrupts automatic non-blocking monitoring or drops
## pending session recovery across restarts.

signal session_updated(session_id: String, snapshot: Dictionary)

const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")

const DEFAULT_POLL_INTERVAL_S := 0.75

var runner = null
var active_session_id: String = ""
var poll_timer: Timer = null
var _last_emitted_sig: Dictionary = {}
var _monitoring_sessions: Array[String] = []


func _ready() -> void:
	ensure_initialized()


func ensure_initialized() -> void:
	if runner == null:
		runner = NativeRunnerScript.new()
	if poll_timer == null:
		poll_timer = Timer.new()
		poll_timer.name = "NativeMonitorPollTimer"
		poll_timer.one_shot = false
		poll_timer.wait_time = DEFAULT_POLL_INTERVAL_S
		poll_timer.timeout.connect(_on_poll_timer_timeout)
		add_child(poll_timer)


func _start_poll_timer() -> void:
	if poll_timer == null:
		return
	if poll_timer.is_inside_tree():
		if poll_timer.is_stopped():
			poll_timer.start()
	else:
		poll_timer.autostart = true


func recover_pending_sessions() -> Dictionary:
	ensure_initialized()
	var rec: Dictionary = runner.recover_sessions()
	var latest: Array = runner.list_sessions()
	if not latest.is_empty():
		var top: Dictionary = latest[0]
		active_session_id = str(top.get("session_id", ""))
		for row in latest:
			var sid := str((row as Dictionary).get("session_id", ""))
			if sid == "":
				continue
			var mres: Dictionary = runner.resume_monitor(sid)
			if bool(mres.get("active", false)):
				if not _monitoring_sessions.has(sid):
					_monitoring_sessions.append(sid)
		if not _monitoring_sessions.is_empty():
			_start_poll_timer()
		if active_session_id != "":
			_emit_if_changed(active_session_id, true)
	return rec


func preflight(profile: WeaponProfile, index: ResourceIndex, options: Dictionary = {}) -> Dictionary:
	ensure_initialized()
	var res: Dictionary = runner.preflight(profile, index, options)
	var sid := str(res.get("session_id", ""))
	if sid != "":
		active_session_id = sid
		_emit_if_changed(sid, true)
	return res


func stage(session_id: String = "", extra_files: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = runner.stage(sid, extra_files, options)
	_emit_if_changed(sid, true)
	return res


func launch(session_id: String = "", options: Dictionary = {}) -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = runner.launch(sid, options)
	if bool(res.get("ok", false)) and bool(options.get("execute_process", false)):
		start_monitoring(sid)
	_emit_if_changed(sid, true)
	return res


func start_monitoring(session_id: String = "") -> bool:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return false
	active_session_id = sid
	if not _monitoring_sessions.has(sid):
		_monitoring_sessions.append(sid)
	if poll_timer != null:
		if poll_timer.is_inside_tree():
			if poll_timer.is_stopped():
				poll_timer.start()
		else:
			poll_timer.autostart = true
	_emit_if_changed(sid, true)
	return true


func is_monitoring(session_id: String = "") -> bool:
	var sid := session_id if session_id != "" else active_session_id
	if sid == "" or not _monitoring_sessions.has(sid):
		return false
	if poll_timer != null and poll_timer.is_inside_tree():
		return not poll_timer.is_stopped()
	return poll_timer != null and poll_timer.autostart


func poll_once(session_id: String = "", now_s: float = -1.0, observation_path: String = "") -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "state": "NO_ACTIVE_MONITOR", "active": false}
	var res: Dictionary = runner.poll_monitor(sid, now_s, observation_path)
	var active_now := bool(res.get("active", false))
	var st := str(res.get("state", ""))
	if not active_now or st in ["COMPARISON_COMPLETE", "NATIVE_VERIFIED", "TIMEOUT", "CANCELLED", "FAILED", "NO_ACTIVE_MONITOR", "MONITOR_PERSIST_FAILED"]:
		_monitoring_sessions.erase(sid)
		if _monitoring_sessions.is_empty() and poll_timer != null:
			poll_timer.stop()
	_emit_if_changed(sid, false)
	return res


func cancel_monitoring(session_id: String = "") -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "state": "NO_ACTIVE_MONITOR", "active": false}
	var res: Dictionary = runner.cancel_monitor(sid)
	var st := str(res.get("state", ""))
	# P1-NATIVE-01 (NC-08..NC-12): NEVER silently abandon GUI monitoring when
	# durable cancellation fails! Only stop polling once CANCELLED is committed
	# or there is no active monitor.
	if (bool(res.get("ok", false)) and st == "CANCELLED") or st == "NO_ACTIVE_MONITOR":
		_monitoring_sessions.erase(sid)
		if _monitoring_sessions.is_empty() and poll_timer != null:
			poll_timer.stop()
			poll_timer.autostart = false
	else:
		if not _monitoring_sessions.has(sid):
			_monitoring_sessions.append(sid)
		_start_poll_timer()
	_emit_if_changed(sid, true)
	return res


func arm_manual_observation(session_id: String = "", options: Dictionary = {}) -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "reason": "NO_ACTIVE_SESSION", "active": false}
	var res: Dictionary = runner.arm_manual_observation(sid, options)
	if bool(res.get("ok", false)) and bool(res.get("active", false)):
		active_session_id = sid
		if not _monitoring_sessions.has(sid):
			_monitoring_sessions.append(sid)
		_start_poll_timer()
	_emit_if_changed(sid, true)
	return res


func import_manual_observation(session_id: String = "", observation_path: String = "") -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = runner.import_manual_observation(sid, observation_path)
	if bool(res.get("ok", false)):
		_monitoring_sessions.erase(sid)
		if _monitoring_sessions.is_empty() and poll_timer != null:
			poll_timer.stop()
			poll_timer.autostart = false
	_emit_if_changed(sid, true)
	return res


func resume_monitoring(session_id: String = "") -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "state": "NO_MONITOR_TO_RESUME", "active": false}
	var res: Dictionary = runner.resume_monitor(sid)
	if bool(res.get("active", false)):
		active_session_id = sid
		if not _monitoring_sessions.has(sid):
			_monitoring_sessions.append(sid)
		_start_poll_timer()
	_emit_if_changed(sid, true)
	return res


func collect_observation(session_id: String = "", observation_path_override: String = "") -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = runner.collect_observation(sid, observation_path_override)
	if bool(res.get("ok", false)):
		_monitoring_sessions.erase(sid)
		if _monitoring_sessions.is_empty() and poll_timer != null:
			poll_timer.stop()
	_emit_if_changed(sid, true)
	return res


func cleanup_stage(session_id: String = "") -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = runner.cleanup_stage(sid)
	# P1-NATIVE-03: Never stop automatic monitoring when cleanup was rejected
	# (e.g. ACTIVE_EXPERIMENT_CANNOT_CLEANUP) or failed!
	if bool(res.get("ok", false)) and not bool(res.get("cleanup_rejected", false)):
		_monitoring_sessions.erase(sid)
		if _monitoring_sessions.is_empty() and poll_timer != null:
			poll_timer.stop()
	_emit_if_changed(sid, true)
	return res


func get_status_snapshot(session_id: String = "") -> Dictionary:
	ensure_initialized()
	var sid := session_id if session_id != "" else active_session_id
	if sid == "":
		return {
			"session_id": "",
			"state": "IDLE",
			"launch_route": "",
			"game_pid": 0,
			"mission_status": "PENDING",
			"resource_probe": "PENDING",
			"observation_status": "NONE",
			"elapsed_s": 0.0,
			"timeout_s": 0.0,
			"active": false,
			"monitoring": false,
			"reason": "",
			"native_verified": false,
		}
	var rec: Dictionary = runner.get_session_record(sid)
	var mon: Dictionary = rec.get("monitor", {}) if rec.get("monitor", {}) is Dictionary else {}
	if runner.monitors.has(sid):
		mon = (runner.monitors[sid] as RefCounted).to_dict()
	var st := str(mon.get("state", rec.get("state", "IDLE")))
	var started := float(mon.get("started_at_s", 0.0))
	var elapsed := 0.0
	if started > 0.0 and not bool(mon.get("relative_clock", false)):
		elapsed = maxf(0.0, Time.get_unix_time_from_system() - started)
	elif int(mon.get("polls", 0)) > 0:
		elapsed = float(int(mon.get("polls", 0))) * DEFAULT_POLL_INTERVAL_S
	var mission_ok := bool(mon.get("mission_observed", false))
	var probe_ok := bool(mon.get("resource_probe_confirmed", false))
	var obs_ok := bool(mon.get("observation_collected", false)) or st in ["COMPARISON_COMPLETE", "NATIVE_VERIFIED"]
	var verified := bool(mon.get("native_verified", false)) or st == "NATIVE_VERIFIED"
	return {
		"session_id": sid,
		"state": st,
		"launch_route": str(rec.get("launch_route", "")),
		"game_pid": int(mon.get("game_pid", 0)),
		"game_exe_verified": bool(mon.get("game_exe_verified", false)),
		"mission_status": "OBSERVED" if mission_ok else "WAITING",
		"resource_probe": "CONFIRMED" if probe_ok else "WAITING",
		"observation_status": "VERIFIED" if verified else ("COLLECTED" if obs_ok else "WAITING"),
		"elapsed_s": elapsed,
		"timeout_s": float(mon.get("timeout_s", 30.0)),
		"active": bool(mon.get("active", false)),
		"monitoring": _monitoring_sessions.has(sid),
		"reason": str(mon.get("reason", rec.get("reason", ""))),
		"cancel_status": str(mon.get("cancel_status", rec.get("cancel_status", ""))),
		"recoverable": bool(mon.get("recoverable", rec.get("recoverable", false))),
		"manual_armed": bool(mon.get("manual_armed", false)),
		"native_verified": verified,
		"polls": int(mon.get("polls", 0)),
	}


func _on_poll_timer_timeout() -> void:
	if _monitoring_sessions.is_empty():
		if poll_timer != null:
			poll_timer.stop()
		return
	for sid in _monitoring_sessions.duplicate():
		poll_once(sid)


func _emit_if_changed(session_id: String, force: bool) -> void:
	var snap := get_status_snapshot(session_id)
	var sig := "%s|%d|%s|%s|%s|%s|%s" % [
		str(snap.state), int(snap.game_pid), str(snap.mission_status),
		str(snap.resource_probe), str(snap.observation_status),
		str(snap.active), str(snap.reason)
	]
	if force or str(_last_emitted_sig.get(session_id, "")) != sig:
		_last_emitted_sig[session_id] = sig
		session_updated.emit(session_id, snap)
