extends SceneTree
## Focused regression verifier for T-72 (P0-SIM-01: RPL-09..RPL-16).
## Verifies chronological event-scheduled deterministic replay without blocking
## per-shot serialization.

const CombatScenarioScript = preload("res://scripts/sim/combat_scenario.gd")

var failures: Array[String] = []
var checks := 0


func _check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures.append("FAIL: " + msg)
		print("  ✗ " + msg)
	else:
		print("  ✓ " + msg)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _remove_tree(abs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	var d := DirAccess.open(abs_dir)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n != "." and n != "..":
			var p := abs_dir.path_join(n)
			if d.current_is_dir():
				_remove_tree(p)
			else:
				DirAccess.remove_absolute(p)
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(abs_dir)


func _build_fixture(tmp_dir: String, shot_delay: float = 0.1, shot_speed: float = 100.0,
		dmg_h: float = 60.0, dmg_radius: float = 0.0, shield_max: float = 100.0) -> Dictionary:
	var sh := tmp_dir.path_join("sh.odf")
	var wp := tmp_dir.path_join("wp.odf")
	var ord := tmp_dir.path_join("or.odf")
	var tg := tmp_dir.path_join("tg.odf")
	_write(sh, "[GameObjectClass]\nweaponName1=\"wp\"\nmaxAmmo=500\nmaxEnergy=500\nmaxHealth=1000\narmorClass=\"H\"\n")
	_write(wp, "[WeaponClass]\nordName=\"or\"\nshotDelay=%.3f\nenergyCost=1\n" % shot_delay)
	_write(ord, "[OrdnanceClass]\nshotSpeed=%.3f\nlifeSpan=3.0\nshotRadius=0.5\nammoCost=1\ndamageValue(H)=%.3f\ndamageRadius=%.3f\n" % [shot_speed, dmg_h, dmg_radius])
	_write(tg, "[GameObjectClass]\nmaxHealth=500\narmorClass=\"H\"\nshieldClass=\"N\"\nmaxShield=%.3f\n" % shield_max)
	var idx := ResourceIndex.new()
	idx.roots = [{"path": tmp_dir, "label": "t72", "kind": "game", "priority": 10, "enabled": true}]
	idx.scan(false)
	var prof := WeaponProfile.new()
	var ok := prof.resolve(idx, sh, tg)
	return {"ok": ok, "idx": idx, "prof": prof}


func _advance_to(scn, target_t: float) -> void:
	while scn.sim.sim_time + 0.0001 < target_t:
		scn.advance(minf(1.0 / 60.0, target_t - scn.sim.sim_time))


func _event_times(events: Array, kind: String) -> Array[float]:
	var out: Array[float] = []
	for ev in events:
		if ev is Dictionary and str(ev.get("kind", "")) == kind:
			out.append(float(ev.get("time", -1.0)))
	return out


func _initialize() -> void:
	print("T-72 Temporal Replay Concurrency Verifier (RPL-09..RPL-16)")
	var tmp_dir := ProjectSettings.globalize_path("user://t72_rpl_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp_dir)

	# --- RPL-09: Overlapping shots preserve exact launch times, concurrency & impact order ---
	var f09 := _build_fixture(tmp_dir.path_join("r09"), 0.1, 100.0, 60.0, 0.0, 100.0)
	_check(bool(f09.ok), "RPL-09 setup resolved")
	var scn09 = CombatScenarioScript.new(7209)
	var tpos09 := Vector3(0, 2, -100)
	scn09.create_new_scenario(f09.prof, tpos09)
	var a09: Dictionary = scn09.fire_shot(f09.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), tpos09, [], Vector3.ZERO, true)
	_advance_to(scn09, 0.20)
	var b09: Dictionary = scn09.fire_shot(f09.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), tpos09, [], Vector3.ZERO, true)
	_check(bool(a09.ok) and bool(b09.ok) and scn09.sim.shots.size() == 2, "RPL-09 orig: both Shot A (t=0.0) and Shot B (t=0.2) coexist in flight")
	_advance_to(scn09, 1.50)
	var orig_spawn_09 := _event_times(scn09.combat_events, "PROJECTILE_SPAWNED")
	var orig_hit_09 := _event_times(scn09.combat_events, "PROJECTILE_HIT")
	var snap09: Dictionary = scn09.save_replay_snapshot("rpl09_overlap")
	var rep09: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap09)
	var rep_spawn_09 := _event_times(rep09.get("combat_events", []), "PROJECTILE_SPAWNED")
	var rep_hit_09 := _event_times(rep09.get("combat_events", []), "PROJECTILE_HIT")
	_check(rep_spawn_09.size() == 2 and absf(rep_spawn_09[0] - 0.0) < 0.02 and absf(rep_spawn_09[1] - 0.20) < 0.02,
		"RPL-09: replay launches Shot A at t=0.00 and Shot B at t=0.20 (got %s)" % str(rep_spawn_09))
	_check(int(rep09.get("max_concurrent_shots", 0)) >= 2,
		"RPL-09: replay keeps both projectiles concurrently in flight (max_concurrent=%d)" % int(rep09.get("max_concurrent_shots", 0)))
	_check(rep_hit_09.size() == 2 and orig_hit_09.size() == 2 and absf(rep_hit_09[0] - orig_hit_09[0]) < 0.03 and absf(rep_hit_09[1] - orig_hit_09[1]) < 0.03 and rep_hit_09[1] < 1.35,
		"RPL-09: replay impact times match original overlapping schedule (orig=%s rep=%s)" % [str(orig_hit_09), str(rep_hit_09)])
	var p09: Dictionary = (rep09.get("targets", {}) as Dictionary).get("primary", {})
	_check(absf(float(p09.get("shield", -1.0)) - scn09.primary_target().shield_current) < 0.05 and absf(float(p09.get("hull", -1.0)) - scn09.primary_target().hull_current) < 0.05,
		"RPL-09: replay final shield/hull matches original")

	# --- RPL-10: Reload rejection identical on replay ---
	var f10 := _build_fixture(tmp_dir.path_join("r10"), 1.0, 100.0, 50.0, 0.0, 100.0)
	var scn10 = CombatScenarioScript.new(7210)
	var tpos10 := Vector3(0, 2, -100)
	scn10.create_new_scenario(f10.prof, tpos10)
	var fa10: Dictionary = scn10.fire_shot(f10.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), tpos10, [], Vector3.ZERO, true)
	_advance_to(scn10, 0.20)
	var fb10: Dictionary = scn10.fire_shot(f10.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), tpos10, [], Vector3.ZERO, true)
	_check(bool(fa10.ok) and not bool(fb10.ok) and str(fb10.get("state", "")) == "RELOADING", "RPL-10 orig: Shot A accepted, Shot B at t=0.20 rejected while reloading")
	_advance_to(scn10, 1.30)
	var snap10: Dictionary = scn10.save_replay_snapshot("rpl10_reload")
	var rep10: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap10)
	var rep10_acc := _event_times(rep10.get("combat_events", []), "SHOT_ACCEPTED")
	var rep10_rej := _event_times(rep10.get("combat_events", []), "SHOT_REJECTED")
	_check(rep10_acc.size() == 1 and rep10_rej.size() == 1 and absf(rep10_rej[0] - 0.20) < 0.02,
		"RPL-10: replay reproduces exact acceptance history (1 accepted, 1 rejected at t=0.20; acc=%s rej=%s)" % [str(rep10_acc), str(rep10_rej)])
	_check(int(rep10.get("shooter_ammo", -1)) == scn10.shooter.ammo_current,
		"RPL-10: replay shooter ammo matches original (%d vs %d)" % [int(rep10.get("shooter_ammo", -1)), scn10.shooter.ammo_current])

	# --- RPL-11: DoT during projectile flight combines at real impact time ---
	var f11 := _build_fixture(tmp_dir.path_join("r11"), 0.1, 100.0, 60.0, 0.0, 25.0)
	var scn11 = CombatScenarioScript.new(7211)
	var tpos11 := Vector3(0, 2, -100)
	scn11.create_new_scenario(f11.prof, tpos11)
	scn11.fire_shot(f11.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), tpos11, [], Vector3.ZERO, true)
	_advance_to(scn11, 0.25)
	scn11.apply_status_effect("primary", "PlasmaBurn", 40.0, 1.0)
	_advance_to(scn11, 1.50)
	var orig_dot_t := _event_times(scn11.combat_events, "STATUS_EFFECT_TICK")
	var orig_hit_11 := _event_times(scn11.combat_events, "PROJECTILE_HIT")
	var snap11: Dictionary = scn11.save_replay_snapshot("rpl11_dot_inflight")
	var rep11: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap11)
	var rep_dot_t := _event_times(rep11.get("combat_events", []), "STATUS_EFFECT_TICK")
	var rep_hit_11 := _event_times(rep11.get("combat_events", []), "PROJECTILE_HIT")
	var dot_before_hit := false
	for dt in rep_dot_t:
		if not rep_hit_11.is_empty() and dt < rep_hit_11[0]:
			dot_before_hit = true
			break
	var p11: Dictionary = (rep11.get("targets", {}) as Dictionary).get("primary", {})
	_check(dot_before_hit and not orig_dot_t.is_empty(),
		"RPL-11: DoT ticks advance during projectile flight BEFORE impact (hit=%s, first_dot=%s)" % [str(rep_hit_11), str(rep_dot_t[0] if not rep_dot_t.is_empty() else -1.0)])
	_check(absf(float(p11.get("shield", -1.0)) - scn11.primary_target().shield_current) < 0.2 and absf(float(p11.get("hull", -1.0)) - scn11.primary_target().hull_current) < 0.5,
		"RPL-11: replay shield/hull combines DoT + impact identically (orig=%.2f/%.2f rep=%.2f/%.2f)" % [scn11.primary_target().shield_current, scn11.primary_target().hull_current, float(p11.get("shield", -1.0)), float(p11.get("hull", -1.0))])

	# --- RPL-12: Moving target while multiple projectiles are flying ---
	var f12 := _build_fixture(tmp_dir.path_join("r12"), 0.1, 100.0, 50.0, 0.0, 0.0)
	var scn12 = CombatScenarioScript.new(7212)
	scn12.create_new_scenario(f12.prof, Vector3(0, 2, -100))
	# Shot A fired at t=0.0 straight toward (0, 2, -100)
	scn12.fire_shot(f12.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), Vector3(0, 2, -100), [], Vector3.ZERO, true)
	_advance_to(scn12, 0.20)
	# Shot B fired at t=0.20 toward (15, 2, -100) while target is still near X=0!
	var dir_b := (Vector3(15, 2, -100) - Vector3(0, 2, 0)).normalized()
	scn12.fire_shot(f12.prof, Vector3(0, 2, 0), dir_b, Vector3(0, 2, -100), [], Vector3.ZERO, true)
	# Target stays at X=0 until t=1.05 (so Shot A hits at ~0.975s), then moves to X=15 at t=1.08 (so Shot B hits at ~1.18s)!
	_advance_to(scn12, 1.05)
	scn12.record_actor_transform("primary", Vector3(15, 2, -100), Vector3(30, 0, 0), 0.0)
	_advance_to(scn12, 1.50)
	var orig_hits_12 := _event_times(scn12.combat_events, "PROJECTILE_HIT")
	var snap12: Dictionary = scn12.save_replay_snapshot("rpl12_moving_overlap")
	var rep12: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap12)
	var rep_hits_12 := _event_times(rep12.get("combat_events", []), "PROJECTILE_HIT")
	var p12: Dictionary = (rep12.get("targets", {}) as Dictionary).get("primary", {})
	_check(scn12.primary_target().hull_current < 405.0 and absf(float(p12.get("hull", -1.0)) - scn12.primary_target().hull_current) < 0.1,
		"RPL-12: moving target hit by BOTH overlapping shots identically on replay (orig hull=%.1f, rep hull=%.1f)" % [scn12.primary_target().hull_current, float(p12.get("hull", -1.0))])
	_check(rep_hits_12.size() == 2 and orig_hits_12.size() == 2 and absf(rep_hits_12[0] - orig_hits_12[0]) < 0.03 and absf(rep_hits_12[1] - orig_hits_12[1]) < 0.03,
		"RPL-12: moving-target impact order & timing match original (orig=%s rep=%s)" % [str(orig_hits_12), str(rep_hits_12)])

	# --- RPL-13: ODF revision isolation after edit ---
	var odoc13: OdfDocument = f09.prof.ordnance_doc
	var ent13 = odoc13.find_entry("OrdnanceClass", "damageValue(H)")
	odoc13.set_entry_value(ent13, "180")
	f09.prof.refresh()
	var rep13_old: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap09)
	var p13_old: Dictionary = (rep13_old.get("targets", {}) as Dictionary).get("primary", {})
	var scn13_new = CombatScenarioScript.new(7213)
	scn13_new.create_new_scenario(f09.prof, tpos09)
	scn13_new.fire_shot(f09.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), tpos09, [], Vector3.ZERO, true)
	_advance_to(scn13_new, 1.30)
	_check(absf(float(p13_old.get("hull", -1.0)) - 480.0) < 0.1 and absf(scn13_new.primary_target().hull_current - 420.0) < 0.1,
		"RPL-13: historical replay keeps frozen 60 dmg (hull=%.1f) while new sim uses edited 180 dmg (hull=%.1f)" % [float(p13_old.get("hull", -1.0)), scn13_new.primary_target().hull_current])

	# --- RPL-14: Incremental bounded replay does not block GUI on many shots ---
	var f14 := _build_fixture(tmp_dir.path_join("r14"), 0.05, 100.0, 5.0, 0.0, 0.0)
	var scn14 = CombatScenarioScript.new(7214)
	scn14.create_new_scenario(f14.prof, Vector3(0, 2, -100))
	for i in range(40):
		_advance_to(scn14, float(i) * 0.06)
		scn14.fire_shot(f14.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), Vector3(0, 2, -100), [], Vector3.ZERO, true)
	_advance_to(scn14, 4.0)
	var snap14: Dictionary = scn14.save_replay_snapshot("rpl14_many_shots")
	var cs_script: Script = scn14.get_script()
	var has_runner := false
	for m in cs_script.get_script_method_list():
		if str((m as Dictionary).get("name", "")) == "create_replay_runner":
			has_runner = true
			break
	_check(has_runner, "RPL-14: CombatScenario exposes incremental bounded ReplayRunner API")
	# RJOB-01..12: replay job ownership/state contract (source-level guards
	# plus the behavioral runner checks below).
	var wl_src := FileAccess.get_file_as_string("res://scripts/lab/weapon_lab.gd")
	_check(wl_src.contains("var _replay_job_state: String") and
		wl_src.contains("REPLAY_ALREADY_RUNNING") and
		wl_src.contains("func cancel_replay()") and
		wl_src.contains("func toggle_replay_pause()") and
		wl_src.contains("_replay_job_state = \"COMPLETE\""),
		"RJOB-01/02/05/06: single replay job state and conflict guard present")
	_check(wl_src.contains("last_replay_comparison[\"job_id\"]") and
		wl_src.contains("var _replay_job_type: String") and
		wl_src.contains("_replay_job_snapshot_ids"),
		"RJOB-03/11: A/B results bound to job and snapshot identity")
	# RPL-25..29: a safety cutoff must never be reported as success.
	if has_runner:
		var limited = scn14.call("create_replay_runner", snap14, [], {"max_steps_total": 2})
		var limited_step: Dictionary = limited.step(1, 0.0)
		var guard := 0
		while not bool(limited_step.get("done", false)) and guard < 20:
			limited_step = limited.step(1, 0.0)
			guard += 1
		var limited_res: Dictionary = limited_step.get("result", {})
		_check(bool(limited_step.get("done", false)) and not bool(limited_res.get("ok", true)) and
			str(limited_res.get("reason", "")) == "REPLAY_STEP_LIMIT_EXCEEDED" and
			not bool(limited_res.get("complete", true)) and
			int(limited_res.get("steps_executed", 0)) == 2 and
			int(limited_res.get("events_remaining", -1)) >= 0 and
			float(limited_res.get("requested_end_time", -1.0)) >= 0.0,
			"RPL-25/26: step limit returns ok=false complete=false with full diagnostics")
		var full_res: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap14)
		_check(bool(full_res.get("ok", false)) and bool(full_res.get("complete", false)) and
			str(full_res.get("reason", "")) == "REPLAY_COMPLETE",
			"RPL-29: genuine completion still reports REPLAY_COMPLETE")
	if has_runner:
		var runner = scn14.call("create_replay_runner", snap14)
		var chunks := 0
		var max_chunk_ms := 0.0
		var final_inc: Dictionary = {}
		while true:
			var t0 := Time.get_ticks_usec()
			var st: Dictionary = runner.step(12, 8.0)
			var dt_ms := float(Time.get_ticks_usec() - t0) / 1000.0
			max_chunk_ms = maxf(max_chunk_ms, dt_ms)
			chunks += 1
			if bool(st.get("done", false)):
				final_inc = st.get("result", {})
				break
			if chunks > 5000:
				break
		var sync14: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap14)
		var h_inc := float(((final_inc.get("targets", {}) as Dictionary).get("primary", {}) as Dictionary).get("hull", -1.0))
		var h_sync := float(((sync14.get("targets", {}) as Dictionary).get("primary", {}) as Dictionary).get("hull", -1.0))
		_check(chunks >= 2 and absf(h_inc - h_sync) < 0.05 and absf(h_inc - scn14.primary_target().hull_current) < 0.05,
			"RPL-14: incremental replay runs in %d bounded chunks (max %.2fms) and matches sync/orig hull (%.1f vs %.1f vs %.1f)" % [chunks, max_chunk_ms, h_inc, h_sync, scn14.primary_target().hull_current])

	# --- RPL-15: Stable same-time event ordering ---
	var f15 := _build_fixture(tmp_dir.path_join("r15"), 0.01, 100.0, 20.0, 0.0, 50.0)
	var scn15 = CombatScenarioScript.new(7215)
	scn15.create_new_scenario(f15.prof, Vector3(0, 2, -60))
	_advance_to(scn15, 0.25)
	# Multiple events at the EXACT same simulation timestamp t=0.25
	scn15.record_actor_transform("primary", Vector3(0, 2, -50), Vector3.ZERO, 0.0)
	scn15.apply_status_effect("primary", "IonBurn", 10.0, 1.0)
	scn15.fire_shot(f15.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), Vector3(0, 2, -50), [], Vector3.ZERO, false)
	scn15.fire_shot(f15.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), Vector3(0, 2, -50), [], Vector3.ZERO, false)
	_advance_to(scn15, 1.50)
	var snap15: Dictionary = scn15.save_replay_snapshot("rpl15_same_time")
	# Verify input events carry explicit monotonic seq and survive identical replay twice
	var inputs15: Array = snap15.get("timeline_inputs", [])
	var has_seq := not inputs15.is_empty() and (inputs15[0] as Dictionary).has("seq")
	var rep15a: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap15)
	var rep15b: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap15)
	_check(has_seq and JSON.stringify(rep15a.get("combat_events", [])) == JSON.stringify(rep15b.get("combat_events", [])),
		"RPL-15: same-time events carry stable seq and produce byte-identical event streams across replays")

	# --- RPL-16: Simultaneous splash impacts ---
	var f16 := _build_fixture(tmp_dir.path_join("r16"), 0.01, 100.0, 80.0, 20.0, 50.0)
	var scn16 = CombatScenarioScript.new(7216)
	scn16.create_new_scenario(f16.prof, Vector3(0, 2, -60))
	var ActorScript = preload("res://scripts/sim/combat_actor_state.gd")
	var t2 = ActorScript.create_target("secondary_1", "Target C", 500.0, "H", 30.0, "N", Vector3(6, 2, -60), 2.0)
	scn16.add_or_update_target(t2)
	scn16.capture_replay_baseline(f16.prof)
	# Two simultaneous splash shots fired at exact same t=0.0
	scn16.fire_shot(f16.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), Vector3(0, 2, -60), [], Vector3.ZERO, false)
	scn16.fire_shot(f16.prof, Vector3(0, 2, 0), Vector3(0, 0, -1), Vector3(0, 2, -60), [], Vector3.ZERO, false)
	_advance_to(scn16, 1.20)
	var snap16: Dictionary = scn16.save_replay_snapshot("rpl16_splash")
	var rep16a: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap16)
	var rep16b: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap16)
	var p16_prim: Dictionary = (rep16a.get("targets", {}) as Dictionary).get("primary", {})
	var p16_sec: Dictionary = (rep16a.get("targets", {}) as Dictionary).get("secondary_1", {})
	_check(int(rep16a.get("max_concurrent_shots", 0)) >= 2, "RPL-16: simultaneous splash shots coexist in flight")
	_check(absf(float(p16_prim.get("hull", -1.0)) - scn16.primary_target().hull_current) < 0.1 and absf(float(p16_sec.get("hull", -1.0)) - t2.hull_current) < 0.1 and JSON.stringify(rep16a.get("targets", {})) == JSON.stringify(rep16b.get("targets", {})),
		"RPL-16: simultaneous splash impacts on primary + secondary reproduce deterministically (orig %.1f/%.1f rep %.1f/%.1f)" % [scn16.primary_target().hull_current, t2.hull_current, float(p16_prim.get("hull", -1.0)), float(p16_sec.get("hull", -1.0))])

	OdfDocument.clear_all_cache()
	_remove_tree(tmp_dir)

	print("\nT-72 Verifier: %d checks, %d failure(s)" % [checks, failures.size()])
	if not failures.is_empty():
		quit(1)
		return
	print("RESULT: PASS")
	quit(0)
