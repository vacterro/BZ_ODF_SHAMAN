class_name NativeProcessMonitor
extends RefCounted
## Bounded asynchronous monitor for one native BZCC session.
##
## State machine:
##   STEAM_PROCESS_STARTED -> GAME_PROCESS_DETECTED -> MISSION_OBSERVED
##   -> RESOURCE_PROBE_CONFIRMED -> COMPARISON_COMPLETE / NATIVE_VERIFIED
## Terminal states: TIMEOUT, CANCELLED, FAILED.
##
## The monitor never advances on a timer alone: a new battlezone2.exe process
## must be observed with a PID that was absent at launch and with a matching
## executable path and MD5. Mission and resource probes come from session-bound
## evidence only. Both timeout_s and max_polls bound every active monitor.

const STATE_STEAM := "STEAM_PROCESS_STARTED"
const STATE_GAME := "GAME_PROCESS_DETECTED"
const STATE_MISSION := "MISSION_OBSERVED"
const STATE_PROBE := "RESOURCE_PROBE_CONFIRMED"
const STATE_COMPARISON := "COMPARISON_COMPLETE"
const STATE_VERIFIED := "NATIVE_VERIFIED"
const STATE_TIMEOUT := "TIMEOUT"
const STATE_CANCELLED := "CANCELLED"
const STATE_FAILED := "FAILED"

const TERMINAL_STATES := [STATE_COMPARISON, STATE_VERIFIED, STATE_TIMEOUT, STATE_CANCELLED, STATE_FAILED]

var session_id: String = ""
var state: String = STATE_STEAM
var reason: String = ""
var active: bool = true
var started_at_s: float = 0.0
var relative_clock: bool = false
var timeout_s: float = 30.0
var max_polls: int = 240
var polls: int = 0
var game_pid: int = 0
var game_exe_verified: bool = false
var preexisting_game_pids: Array = []
var expected_exe: String = ""
var expected_md5: String = ""
var mission_observed: bool = false
var mission_loaded_at: String = ""
var resource_probe_confirmed: bool = false
var observation_collected: bool = false
var comparison_complete: bool = false
var native_verified: bool = false
var last_result_state: String = ""
var last_error: String = ""


static func create(sid: String, discovery: Dictionary, options: Dictionary, preexisting: Array) -> NativeProcessMonitor:
	var monitor := new()
	monitor.session_id = sid
	monitor.expected_exe = str(discovery.get("exe", ""))
	monitor.expected_md5 = str(discovery.get("exe_md5", "")).strip_edges().to_lower()
	monitor.preexisting_game_pids = preexisting.duplicate(true)
	monitor.started_at_s = float(options.get("monitor_started_at_s", 0.0))
	monitor.timeout_s = maxf(0.1, float(options.get("monitor_timeout_s", 30.0)))
	monitor.max_polls = maxi(1, int(options.get("monitor_max_polls", 240)))
	return monitor


func is_terminal() -> bool:
	return state in TERMINAL_STATES


## Accept only a genuinely new battlezone2.exe process with matching exe path
## and MD5. Preexisting PIDs and foreign executables are never promoted.
func detect_game(inspector: Callable, legacy_detector: Callable) -> Dictionary:
	if inspector.is_valid():
		var procs = inspector.call()
		if procs is Array:
			var expected_path := expected_exe.replace("\\", "/").strip_edges().to_lower()
			for item in procs:
				if not (item is Dictionary):
					continue
				var proc: Dictionary = item
				var pid := int(proc.get("pid", 0))
				if pid <= 0 or preexisting_game_pids.has(pid):
					continue
				var proc_name := str(proc.get("name", "")).strip_edges().to_lower()
				var proc_path := str(proc.get("exe_path", "")).replace("\\", "/").strip_edges().to_lower()
				if proc_name != "battlezone2.exe" and not proc_path.ends_with("/battlezone2.exe"):
					continue
				if expected_path != "" and proc_path != expected_path:
					continue
				if expected_md5 != "" and str(proc.get("exe_md5", "")).strip_edges().to_lower() != expected_md5:
					continue
				game_pid = pid
				game_exe_verified = true
				state = STATE_GAME
				return {"detected": true, "game_pid": pid, "game_exe_verified": true, "source": "process_inspector"}
		return {"detected": false, "game_pid": 0, "game_exe_verified": false, "source": "process_inspector"}
	if legacy_detector.is_valid():
		var res = legacy_detector.call()
		if res is Dictionary and bool(res.get("detected", false)):
			var pid := int(res.get("game_pid", 0))
			if pid > 0 and not preexisting_game_pids.has(pid):
				game_pid = pid
				game_exe_verified = false
				state = STATE_GAME
				return {"detected": true, "game_pid": pid, "game_exe_verified": false, "source": "legacy_detector"}
	return {"detected": false, "game_pid": 0, "game_exe_verified": false, "source": "none"}


func apply_mission_probe(info: Dictionary) -> void:
	mission_observed = bool(info.get("mission_observed", false))
	mission_loaded_at = str(info.get("mission_loaded_at", ""))
	resource_probe_confirmed = bool(info.get("resource_probe_confirmed", false))
	if mission_observed and state == STATE_GAME:
		state = STATE_MISSION
	if resource_probe_confirmed and state == STATE_MISSION:
		state = STATE_PROBE


func finish_collection(result: Dictionary) -> void:
	last_result_state = str(result.get("state", ""))
	observation_collected = bool(result.get("observation_collected", result.get("ok", false)))
	comparison_complete = bool(result.get("comparison_complete", false))
	native_verified = bool(result.get("verified", false)) and comparison_complete
	if bool(result.get("persist_failed", false)):
		state = STATE_FAILED
		reason = "STATE_PERSIST_FAILED"
		last_error = str(result.get("error", "checked state persistence failed"))
		active = false
		return
	if native_verified:
		state = STATE_VERIFIED
	elif comparison_complete:
		state = STATE_COMPARISON
	elif bool(result.get("ok", false)) == false and last_result_state != "":
		state = last_result_state
	if is_terminal():
		active = false


func cancel() -> void:
	state = STATE_CANCELLED
	reason = "MONITOR_CANCELLED"
	active = false


func timeout() -> void:
	state = STATE_TIMEOUT
	reason = "MONITOR_TIMEOUT"
	active = false


func to_dict() -> Dictionary:
	return {
		"session_id": session_id,
		"state": state,
		"reason": reason,
		"active": active,
		"started_at_s": started_at_s,
		"relative_clock": relative_clock,
		"timeout_s": timeout_s,
		"max_polls": max_polls,
		"polls": polls,
		"game_pid": game_pid,
		"game_exe_verified": game_exe_verified,
		"preexisting_game_pids": preexisting_game_pids.duplicate(true),
		"expected_exe": expected_exe,
		"expected_md5": expected_md5,
		"mission_observed": mission_observed,
		"mission_loaded_at": mission_loaded_at,
		"resource_probe_confirmed": resource_probe_confirmed,
		"observation_collected": observation_collected,
		"comparison_complete": comparison_complete,
		"native_verified": native_verified,
		"last_result_state": last_result_state,
		"last_error": last_error,
	}


static func from_dict(d: Dictionary) -> NativeProcessMonitor:
	if d.is_empty():
		return null
	var monitor := new()
	monitor.session_id = str(d.get("session_id", ""))
	monitor.state = str(d.get("state", STATE_STEAM))
	monitor.reason = str(d.get("reason", ""))
	monitor.active = bool(d.get("active", true))
	monitor.started_at_s = float(d.get("started_at_s", 0.0))
	monitor.relative_clock = bool(d.get("relative_clock", false))
	monitor.timeout_s = float(d.get("timeout_s", 30.0))
	monitor.max_polls = int(d.get("max_polls", 240))
	monitor.polls = int(d.get("polls", 0))
	monitor.game_pid = int(d.get("game_pid", 0))
	monitor.game_exe_verified = bool(d.get("game_exe_verified", false))
	var pids = d.get("preexisting_game_pids", [])
	monitor.preexisting_game_pids = (pids as Array).duplicate(true) if pids is Array else []
	monitor.expected_exe = str(d.get("expected_exe", ""))
	monitor.expected_md5 = str(d.get("expected_md5", ""))
	monitor.mission_observed = bool(d.get("mission_observed", false))
	monitor.mission_loaded_at = str(d.get("mission_loaded_at", ""))
	monitor.resource_probe_confirmed = bool(d.get("resource_probe_confirmed", false))
	monitor.observation_collected = bool(d.get("observation_collected", false))
	monitor.comparison_complete = bool(d.get("comparison_complete", false))
	monitor.native_verified = bool(d.get("native_verified", false))
	monitor.last_result_state = str(d.get("last_result_state", ""))
	monitor.last_error = str(d.get("last_error", ""))
	return monitor


func result() -> Dictionary:
	var out := to_dict()
	out.erase("expected_exe")
	out.erase("expected_md5")
	out.erase("started_at_s")
	out.erase("timeout_s")
	out.erase("max_polls")
	out["ok"] = true
	return out
