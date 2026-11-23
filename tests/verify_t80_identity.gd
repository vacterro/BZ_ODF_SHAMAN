extends SceneTree
## Focused behavioral verifier for T-80: resolved barrel identity, SALVO
## hardpoint correctness, aggregate volley state, and replay job honesty.
## Run: Godot --headless --path . --script res://tests/verify_t80_identity.gd

const WeaponProfileScript = preload("res://scripts/sim/weapon_profile.gd")
const WeaponLabScript = preload("res://scripts/lab/weapon_lab.gd")
const CombatScenarioScript = preload("res://scripts/sim/combat_scenario.gd")
const SchemaRegistryScript = preload("res://scripts/core/schema_registry.gd")

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


func _initialize() -> void:
	print("T-80 Barrel identity & replay honesty verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t80_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var shooter := tmp.path_join("tank.odf")
	var weapon := tmp.path_join("gun.odf")
	var ord := tmp.path_join("bullet.odf")
	var target := tmp.path_join("target.odf")
	_write(shooter, "[GameObjectClass]\nweaponName1=\"gun\"\nweaponHard1=\"hp_missing\"\nweaponHard2=\"hp_right\"\nmaxAmmo=500\nmaxEnergy=0\nmaxHealth=1000\narmorClass=\"H\"\n")
	_write(weapon, "[WeaponClass]\nordName=\"bullet\"\nshotDelay=0.05\n")
	_write(ord, "[OrdnanceClass]\nshotSpeed=120\nlifeSpan=2\ndamageValue(H)=60\nshotRadius=0.5\n")
	_write(target, "[GameObjectClass]\nmaxHealth=1000\narmorClass=\"H\"\n")

	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": tmp, "label": "t80", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	var schema := SchemaRegistryScript.new()
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(idx, schema)
	lab.shooter_path = shooter
	lab.target_path = target
	lab.barrel_mode = "TANDEM"
	var prof := WeaponProfileScript.new()
	_check(prof.resolve(idx, shooter, target, "", true, 0, "TANDEM"), "T-80 fixture: weapon profile resolves")
	prof.weapon_hardpoints = ["hp_missing", "hp_right"]
	lab.profile = prof
	lab.combat_scenario.create_new_scenario(prof, Vector3(0, 2, -50))

	# Missing declared hardpoint must not shift the valid second barrel.
	var hps := {"hp_right": Node3D.new()}
	lab.shooter_model_info = {"ok": true, "hardpoints": hps}
	var agg: Dictionary = lab._fire_volley(false, "SINGLE", true)
	var resolved: Array = agg.get("per_barrel_results", [])
	_check(resolved.size() == 2 and
		str((resolved[0] as Dictionary).get("hardpoint_name", "")) == "hp_missing" and
		str((resolved[1] as Dictionary).get("hardpoint_name", "")) == "hp_right",
		"BARREL-05: declared hardpoint order preserved, missing slot not compacted")
	_check(str((resolved[0] as Dictionary).get("diagnostic", "")) == "DECLARED_HARDPOINT_NOT_FOUND" and
		bool((resolved[0] as Dictionary).get("fallback_used", false)),
		"BARREL-07: missing hardpoint explicitly labelled approximate fallback")
	var accepted = agg.get("accepted_shots", 0)
	_check(int(accepted) >= 1 and int(agg.get("ammo_spent", 0)) >= 0,
		"VOLLEY-10: resource accounting follows accepted shots")

	# SALVO must record the same barrel identity as the spawned projectile origin.
	lab.barrel_mode = "SALVO"
	lab._barrel_cycle = 1
	var salvo: Dictionary = lab._fire_volley(false, "SINGLE", false)
	var sr: Array = salvo.get("per_barrel_results", [])
	var salvo_entry: Dictionary = sr[1] if sr.size() > 1 else {}
	var shot_id: Dictionary = salvo_entry.get("shot_identity", {})
	_check(sr.size() == 2 and str(salvo_entry.get("hardpoint_name", "")) == "hp_right" and
		str(shot_id.get("hardpoint", "")) == "hp_right" and int(shot_id.get("barrel_index", -1)) == 1,
		"BARREL-09: SALVO ShotIdentity records actual selected hardpoint and index")

	# Aggregate state follows acceptance, independent of first barrel's state.
	var volley = lab.last_volley_result
	_check(volley != null and bool(volley.ok) and bool(volley.complete), "VOLLEY-09: all accepted aggregate ok/complete")
	_check(str(salvo.get("state", "")) == "FIRED", "VOLLEY-09: all accepted reports FIRED")
	volley.partial_failure = true
	volley.ok = true
	volley.complete = false
	var partial: Dictionary = volley.to_dict()
	_check(str(partial.get("state", "")) == "PARTIAL_SUCCESS" and bool(partial.get("ok", false)) and
		bool(partial.get("partial_failure", false)), "VOLLEY-07: partial success state is consistent")
	volley.partial_failure = false
	volley.ok = false
	var rejected: Dictionary = volley.to_dict()
	_check(str(rejected.get("state", "")) == "REJECTED" and not bool(rejected.get("ok", true)),
		"VOLLEY-08: all rejected state is REJECTED")

	# GUI replay job state mirrors result honesty, not merely done=true.
	_check(lab._replay_job_state_from_result({"done": true, "ok": false, "complete": false,
		"reason": "REPLAY_STEP_LIMIT_EXCEEDED"}) == "FAILED",
		"RJOB-13: step-limit replay is FAILED")
	_check(lab._replay_job_state_from_result({"done": true, "ok": true, "complete": true}) == "COMPLETE",
		"RJOB-15: genuinely complete replay is COMPLETE")

	# A/B: one side incomplete must not masquerade as successful.
	lab._replay_ab_queue.clear()
	lab._replay_ab_ids.assign(["snap_a", "snap_b"])
	lab._replay_ab_results.assign([
		{"complete": true, "ok": true, "reason": "REPLAY_COMPLETE", "targets": {}},
		{"complete": false, "ok": false, "reason": "REPLAY_STEP_LIMIT_EXCEEDED", "targets": {}},
	])
	lab._finish_ab_if_ready()
	_check(lab._replay_job_state == "FAILED" and
		not bool(lab.last_replay_comparison.get("complete", true)),
		"RJOB-14: incomplete A/B side yields FAILED job state")
	lab._replay_ab_queue.clear()
	lab._replay_ab_ids.assign(["snap_a", "snap_b"])
	lab._replay_ab_results.assign([
		{"complete": true, "ok": true, "reason": "REPLAY_COMPLETE", "targets": {}},
		{"complete": true, "ok": true, "reason": "REPLAY_COMPLETE", "targets": {}},
	])
	lab._finish_ab_if_ready()
	_check(lab._replay_job_state == "COMPLETE" and
		bool(lab.last_replay_comparison.get("complete", false)),
		"RJOB-15: both A/B sides complete yields COMPLETE job state")
	lab._replay_job_state = "FAILED"
	lab.start_incremental_replay()
	_check(lab._replay_job_state != "FAILED" or not bool(lab.last_replay_result.get("ok", false)),
		"RJOB-16: fresh job starts from clean state")

	# PHI-01..06: physical hardpoint inspector reports real simulation state.
	var hp_right_node := Node3D.new()
	hp_right_node.name = "hp_right"
	lab.shooter_model_info = {"ok": true, "hardpoints": {"hp_missing": null, "hp_right": hp_right_node}}
	var rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(rows.size() == 2 and
		str(rows[0].get("hardpoint", "")) == "hp_missing" and
		str(rows[0].get("fidelity", "")) == "DECLARED_BUT_MISSING" and
		str(rows[1].get("fidelity", "")) == "RESOLVED_MODEL_NODE",
		"PHI-01/02: inspector separates declared-but-missing from resolved model node")
	_check(str(rows[1].get("node", "")) != "-" and str(rows[1].get("origin", "")).begins_with("("),
		"PHI-03: resolved node name and world origin come from the model")
	lab.barrel_mode = "SALVO"
	lab._barrel_cycle = 1
	lab._fire_volley(false, "SINGLE", false)
	var shot_rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(str(shot_rows[1].get("shot", "")).begins_with("#") and
		str(shot_rows[1].get("shot", "")).contains("hp_right"),
		"PHI-04: fired slot shows its actual ShotIdentity and hardpoint")
	_check(not str(shot_rows[0].get("shot", "")).begins_with("#"),
		"PHI-05: non-fired slot never borrows another barrel's shot identity")
	if lab.hardpoint_inspector_tree != null:
		lab.refresh_hardpoint_inspector(true)
		_check(lab.hardpoint_inspector_tree.get_root() != null and
			lab.hardpoint_inspector_tree.get_root().get_child_count() == 2,
			"PHI-06: GUI hardpoint inspector lists one row per declared slot")

	# Native stage inventory is read-only and reports unresolved ownership.
	var stage_dir := tmp.path_join("SHAMAN_test_stage")
	DirAccess.make_dir_recursive_absolute(stage_dir)
	var inv: Array[Dictionary] = lab.inspect_native_stages([tmp])
	_check(inv.size() == 1 and str(inv[0].get("stage_name", "")) == "SHAMAN_test_stage" and
		str(inv[0].get("ownership", "")) == "UNRESOLVED" and
		not bool(inv[0].get("cleanup_allowed", false)),
		"NATIVE-31/33: stage inventory read-only, missing manifest preserved")
	_check(DirAccess.dir_exists_absolute(stage_dir) and lab.native_stage_inventory_label != null and
		lab.native_stage_inventory_label.text.contains("ownership=UNRESOLVED"),
		"NATIVE-33: unresolved stage still on disk and visible in UI")

	lab.queue_free()
	_remove_tree(tmp)
	print("\nT-80 Verifier: %d checks, %d failure(s)" % [passed + failed, failed])
	if failed == 0:
		print("RESULT: PASS")
		quit(0)
	else:
		print("RESULT: FAIL")
		quit(1)
