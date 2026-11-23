extends SceneTree
## T-121 P1-TEST-01 — true mid-operation OS-process interruption.
##
## Each case spawns a real Godot worker that blocks at a checkpoint emitted
## from INSIDE save_with_external_dependencies / recover_partial_save_group.
## The parent kills that process, then fresh processes discover, recover and
## validate the durable final state. Covers XPROC-20..26.

const WORKER := "res://tests/save_group_worker.gd"

var passed := 0
var failed := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
		print("  ✓ " + msg)
	else:
		failed += 1
		print("  ✗ FAIL: " + msg)


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


func _run_worker(args: Array) -> Dictionary:
	var godot := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var out: Array = []
	var code: int = OS.execute(godot, ["--headless", "--path", proj, "--script", WORKER,
		"--"] + args, out, true)
	var text := "\n".join(PackedStringArray(out))
	var payload: Dictionary = {}
	for line_item: String in text.split("\n"):
		if line_item.begins_with("WORKER_JSON:"):
			var parsed: Variant = JSON.parse_string(line_item.trim_prefix("WORKER_JSON:"))
			if parsed is Dictionary:
				payload = parsed
	return {"code": code, "payload": payload, "text": text}


## Kill the worker once its in-operation marker appears.
func _kill_at_checkpoint(ws_root: String, phase: String, mode: String) -> String:
	var marker := ws_root.path_join("checkpoint_" + phase + ".txt")
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)
	var godot := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var args: Array = ["--headless", "--path", proj, "--script", WORKER, "--", mode, ws_root, marker]
	if mode == "crash_save":
		args.append(phase)
		args.append(ws_root.path_join("sources/mod_b/effect.odf"))
	else:
		args.append(phase)
	var pid := OS.create_process(godot, args)
	var deadline := Time.get_ticks_msec() + 30000
	while not FileAccess.file_exists(marker) and Time.get_ticks_msec() < deadline:
		OS.delay_msec(20)
	if not FileAccess.file_exists(marker):
		if pid > 0:
			OS.kill(pid)
		return ""
	if pid > 0:
		OS.kill(pid)
		var exit_deadline := Time.get_ticks_msec() + 5000
		while OS.is_process_running(pid) and Time.get_ticks_msec() < exit_deadline:
			OS.delay_msec(20)
	var lines := FileAccess.get_file_as_string(marker).strip_edges().split("\n")
	return str(lines[0]) if lines.size() > 0 else ""


func _initialize() -> void:
	print("T-121 Mid-Operation Crash Verifier (XPROC-20..26)")
	var root := ProjectSettings.globalize_path("user://verify_t121_xproc_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(root)
	var phases := ["AFTER_PREPARED_JOURNAL", "AFTER_COMMITTING_JOURNAL",
		"BEFORE_FIRST_OVERRIDE_WRITE", "AFTER_FIRST_OVERRIDE_WRITE",
		"BEFORE_FIRST_TARGET_JOURNAL", "AFTER_FIRST_TARGET_JOURNAL",
		"BEFORE_FINAL_JOURNAL"]
	for phase in phases:
		var ws := root.path_join(phase)
		DirAccess.make_dir_recursive_absolute(ws)
		var prep := _run_worker(["prepare", ws])
		_check(bool(prep["payload"].get("ok", false)), "XPROC-20 setup: " + phase + " workspace prepared")
		var gid := _kill_at_checkpoint(ws, phase, "crash_save")
		_check(gid != "", "XPROC-20: " + phase + " emitted inside the save operation")
		var disc := _run_worker(["discover", ws])
		_check((disc["payload"].get("count", 0) == 1),
			"XPROC-24: " + phase + " durable phase discovered after process kill")
		var rec := _run_worker(["recover", ws, gid])
		var rstatus := str(rec["payload"].get("status", ""))
		if rstatus == "RECOVERY_CONFLICT_PENDING":
			# Override bytes exist but their commit was never journaled: the
			# durable phase is genuinely ambiguous, so a conflict is correct.
			_check((rec["payload"].get("conflicts", []) as Array).size() >= 1,
				"XPROC-24: " + phase + " surfaces unjournaled write as conflict")
			var resolved := _run_worker(["resolve", ws, gid, "restore_working"])
			_check(str(resolved["payload"].get("status", "")) == "RECOVERY_CONFLICT_RESOLVED",
				"XPROC-25: " + phase + " conflict resolved explicitly")
		else:
			_check(rstatus == "RECOVERED",
				"XPROC-21/22: " + phase + " recovers to RECOVERED")
		var ver := _run_worker(["verify", ws, gid])
		var vp: Dictionary = ver["payload"]
		var content_ok := str(vp.get("override_a_value", "")).contains("lifeTime=1.5") or 			str(vp.get("override_a_value", "")).contains("lifeTime=9.9")
		var final_state_ok := content_ok and (vp.get("journals", []) as Array).size() >= 1
		_check(final_state_ok,
			"XPROC-23/26: " + phase + " third process confirms final durable state")
	_remove_tree(root)
	print("\nT-121 Mid-Operation Crash: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
