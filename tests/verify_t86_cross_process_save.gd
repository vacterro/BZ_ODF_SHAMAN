extends SceneTree
## T-86 TRUE cross-process Save Dependencies restart verifier (Wave C).
##
## The T-85 verifier reused ParticleLab objects inside one Godot process; this
## one spawns real OS processes with OS.create_process(), kills one mid-save
## with OS.kill(), and lets fresh processes (fresh WorkspaceStore statics,
## fresh OdfDocument cache, fresh engine state) discover and recover the
## durable save-group journal. Process C validates the final bytes, manifest
## and journal state without trusting either worker.
##
## Covers SAVE-71..74: interrupted save (A), discovery (B), safe recovery (B),
## durable final validation (C).

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
			var jres: Variant = JSON.parse_string(line_item.trim_prefix("WORKER_JSON:"))
			if jres is Dictionary:
				payload = jres
	return {"code": code, "payload": payload, "text": text}


func _initialize() -> void:
	print("T-86 True Cross-Process Save Dependencies Verifier")
	var ws_root := ProjectSettings.globalize_path("user://verify_t86_xproc_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(ws_root)
	var parent_dir := ws_root.path_join("sources")
	var src_a := parent_dir.path_join("mod_a/effect.odf")
	var src_b := parent_dir.path_join("mod_b/effect.odf")

	# ---- Process A, phase 1: isolated sources + one existing override.
	var prep := _run_worker(["prepare", ws_root])
	_check(prep["code"] == 0 and bool(prep["payload"].get("ok", false)),
		"SAVE-71 setup: process A prepared sources and one existing override")
	var override_rel_a := str(prep["payload"].get("rel", ""))
	_check(override_rel_a != "", "SAVE-71 setup: dependency A had a workspace override before the transaction")

	# ---- Process A, phase 2: multi-document save, killed mid-flight.
	var marker := ws_root.path_join("killed_mid_save.txt")
	var godot := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var pid := OS.create_process(godot, ["--headless", "--path", proj, "--script", WORKER,
		"--", "partial_save", ws_root, marker, src_b])
	_check(pid > 0, "SAVE-71: interrupted-save worker process spawned (real OS process)")
	var wait_deadline := Time.get_ticks_msec() + 20000
	while not FileAccess.file_exists(marker) and Time.get_ticks_msec() < wait_deadline:
		OS.delay_msec(20)
	_check(FileAccess.file_exists(marker), "SAVE-71: worker reached durable interrupted-save state before kill")
	var gid := (FileAccess.get_file_as_string(marker).strip_edges())
	if pid > 0:
		OS.kill(pid)
		var exit_deadline := Time.get_ticks_msec() + 5000
		while OS.is_process_running(pid) and Time.get_ticks_msec() < exit_deadline:
			OS.delay_msec(20)
	_check(not OS.is_process_running(pid), "SAVE-71: interrupted-save worker OS process terminated")
	_check(gid != "" and FileAccess.file_exists(ws_root.path_join("save_groups").path_join(gid + ".json")),
		"SAVE-71: durable journal for group " + gid + " survived the OS process kill")

	# ---- Process B: fresh process discovers the pending group.
	var disc := _run_worker(["discover", ws_root])
	_check(disc["code"] == 0, "SAVE-72: discovery process exited 0")
	var groups: Array = disc["payload"].get("groups", [])
	_check(disc["payload"].get("count", 0) == 1 and groups.size() == 1,
		"SAVE-72: fresh OS process discovered exactly one pending save group")
	if groups.size() == 1:
		_check(str(groups[0].get("state", "")) == "PARTIAL_SAVE_RECOVERABLE" and int(groups[0].get("targets", 0)) == 2,
			"SAVE-72: discovered group is PARTIAL_SAVE_RECOVERABLE with 2 targets")

	# ---- Process B: fresh process recovers safely.
	var rec := _run_worker(["recover", ws_root])
	_check(rec["code"] == 0, "SAVE-73: recovery process exited 0")
	var rp: Dictionary = rec["payload"]
	_check(str(rp.get("status", "")) == "RECOVERED", "SAVE-73: fresh-process recovery reports RECOVERED")
	_check((rp.get("failed", []) as Array).is_empty() and (rp.get("conflicts", []) as Array).is_empty(),
		"SAVE-73: recovery had no failures and no conflicts")
	_check((rp.get("restored", []) as Array).size() == 2, "SAVE-73: both dependencies restored")

	# ---- Process C: fresh process validates final durable state.
	var ver := _run_worker(["verify", ws_root])
	_check(ver["code"] == 0, "SAVE-74: verification process exited 0")
	var vp: Dictionary = ver["payload"]
	_check(str(vp.get("rel_b", "")) == "", "SAVE-74: dependency B (no override before transaction) has no manifest entry after recovery")
	_check(str(vp.get("rel_a", "")) == override_rel_a, "SAVE-74: dependency A keeps its original override path and manifest entry")
	_check(str(vp.get("override_a_value", "")).contains("lifeTime=1.5"),
		"SAVE-74: dependency A override restored to its exact previous bytes (1.5)")
	var journals: Array = vp.get("journals", [])
	var all_finalized := true
	for j in journals:
		if str((j as Dictionary).get("state", "")) != "RECOVERED":
			all_finalized = false
	_check(journals.size() >= 1 and all_finalized, "SAVE-74: no unresolved journal remains after true cross-process recovery")

	# Idempotence: another fresh recovery attempt on the completed group must
	# be refused without mutation (P0-SAVE-01 COMPLETE guard, SAVE-37/38).
	var again := _run_worker(["recover", ws_root, gid])
	_check(str(again["payload"].get("status", "")) == "RECOVERY_NOT_APPLICABLE",
		"SAVE-74: repeated explicit recovery on the completed group is refused without mutation")

	_remove_tree(ws_root)
	print("\nT-86 Cross-Process Save: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
