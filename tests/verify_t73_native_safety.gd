extends SceneTree
## Focused regression verifier for T-73 (Wave C — P1-NATIVE-01..04):
##   NC-08..NC-12: Checked cancellation ordering, GUI monitor retention on failure, restart reconciliation
##   SA-01..SA-09: Unique STOCK_ADDON mission basenames, active collision rejection, bzone.cfg stream parsing,
##                 read-only foreign addon & old SHAMAN conflict scan, ModLoadout provenance check
##   NM-11..NM-16: ARM MANUAL OBSERVATION lifecycle, restart persistence, late verified process correlation,
##                 manual import unattested boundary, fake PID never creates NATIVE_VERIFIED.
##
## Run: Godot --headless --path . --script res://tests/verify_t73_native_safety.gd

const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const NativeAdapterScript = preload("res://scripts/native/native_test_adapter.gd")
const NativeServiceScript = preload("res://scripts/native/native_session_service.gd")
const ModLoadoutScript = preload("res://scripts/core/mod_loadout.gd")

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


func _make_obs_json(sess: RefCounted, dmg: float = 75.0, mounted: bool = true) -> String:
	return JSON.stringify({
		"contract_version": 2,
		"measurement_method": "GetCurHealth_delta",
		"session_id": str(sess.session_id),
		"launch_nonce": str(sess.launch_nonce),
		"scenario_id": str(sess.scenario_id),
		"mission_basename": str(sess.mission_basename),
		"state": "MEASUREMENT_COMPLETE",
		"shooter": "ivtank_vsr",
		"target": "ivscav_vsr",
		"weapon": "gatstabvsr_c",
		"ordnance": "atstabvsr_c.odf",
		"hp_before": 1000.0,
		"hp_after": 1000.0 - dmg,
		"hp_max": 1000.0,
		"damage": dmg,
		"elapsed_mission_s": 1.25,
		"tps": 20,
		"mount_marker": str(sess.mount_marker),
		"resources_mounted": mounted,
	})


func _initialize() -> void:
	print("T-73 Wave C Native Safety Verifier (NC-08..12, SA-01..09, NM-11..16)")
	var old_ws_root := WorkspaceStore.root_override
	var tmp_root := ProjectSettings.globalize_path("user://verify_t73_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp_root)
	WorkspaceStore.root_override = tmp_root

	var disc := NativeAdapterScript.discover()
	var game_root := str(disc.get("game_root", NativeAdapterScript.DEFAULT_GAME_ROOT))
	var steam_ok := {"steam_present": true, "steam_running": true, "steam_logged_in": true, "steam_exe": str(disc.get("steam_exe", "")), "detail": "mock logged in"}
	var steam_off := {"steam_present": true, "steam_running": true, "steam_logged_in": false, "steam_exe": str(disc.get("steam_exe", "")), "detail": "ActiveUser=0x0"}
	var odf_bytes := "[OrdnanceClass]\r\ndamageValue(H)=100\r\nshotSpeed=200\r\nlifeSpan=2.0\r\n".to_utf8_buffer()

	# =========================================================================
	# PART 1: NC-08..NC-12 — Checked Cancellation & GUI Monitor Retention
	# =========================================================================
	var svc = NativeServiceScript.new()
	svc.ensure_initialized()
	var runner = svc.runner
	runner.process_launcher = func(_e: String, _a: Array) -> Dictionary: return {"ok": true, "pid": 8101, "exit_code": 0}
	runner.process_inspector = func() -> Array: return []
	var pre_nc: Dictionary = runner.preflight(null, null, {
		"discovery": disc,
		"stage_prefix": "nc08_cancel",
		"staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes},
		"config_path_override": game_root.path_join("shaman_nc08.cfg"),
		"steam_override": steam_ok,
	})
	var sid_nc := str(pre_nc.get("session_id", ""))
	var stg_nc: Dictionary = svc.stage(sid_nc)
	var lch_nc: Dictionary = svc.launch(sid_nc, {"execute_process": true, "monitor_started_at_s": 0.0, "monitor_timeout_s": 60.0})
	_check(bool(lch_nc.get("ok", false)) and svc.is_monitoring(sid_nc), "NC setup: launch started active monitoring in NativeSessionService")

	# NC-08 & NC-10: Inject session-ledger write failure during Cancel!
	runner.fault_fail_ledger_write = true
	var c_led: Dictionary = svc.cancel_monitoring(sid_nc)
	runner.fault_fail_ledger_write = false
	var snap_led: Dictionary = svc.get_status_snapshot(sid_nc)
	_check(not bool(c_led.get("ok", true)) and str(c_led.get("cancel_status", "")) == "CANCELLATION_PERSIST_FAILED", "NC-08: ledger write failure returns ok=false and cancel_status=CANCELLATION_PERSIST_FAILED")
	_check(bool(c_led.get("active", false)) and bool(c_led.get("recoverable", false)), "NC-08: live monitor stays active & recoverable when ledger persist fails")
	_check(svc.is_monitoring(sid_nc), "NC-10: NativeSessionService does NOT silently abandon monitoring on ledger cancel failure")
	_check(str(snap_led.get("cancel_status", "")) == "CANCELLATION_PERSIST_FAILED" or str(snap_led.get("reason", "")) == "CANCELLATION_PERSIST_FAILED", "NC-08: GUI status snapshot exposes CANCELLATION_PERSIST_FAILED")

	# NC-09 & NC-10: Inject process_monitors.json write failure during Cancel!
	runner.fault_fail_monitor_persist = true
	var c_mon: Dictionary = svc.cancel_monitoring(sid_nc)
	runner.fault_fail_monitor_persist = false
	var snap_mon: Dictionary = svc.get_status_snapshot(sid_nc)
	_check(not bool(c_mon.get("ok", true)) and str(c_mon.get("cancel_status", "")) == "CANCELLATION_PERSIST_FAILED", "NC-09: process_monitors.json failure returns ok=false and cancel_status=CANCELLATION_PERSIST_FAILED")
	_check(svc.is_monitoring(sid_nc), "NC-09/NC-10: NativeSessionService keeps monitoring active on monitor-persist failure")
	_check(str(snap_mon.get("cancel_status", "")) == "CANCELLATION_PERSIST_FAILED" and bool(snap_mon.get("recoverable", false)), "NC-09: failure & recoverable state visible in GUI snapshot")

	# NC-11: Restart after failed cancellation -> deterministic RECOVERY_PENDING, NO false CANCELLED!
	var svc_restart = NativeServiceScript.new()
	svc_restart.ensure_initialized()
	var rec_nc: Dictionary = svc_restart.recover_pending_sessions()
	var rec_after: Dictionary = svc_restart.runner.get_session_record(sid_nc)
	_check(bool(rec_nc.get("ok", false)) and str(rec_after.get("state", "")) == "RECOVERY_PENDING", "NC-11: restart after failed cancellation reconciles deterministically to RECOVERY_PENDING (no false CANCELLED)")
	_check(str(rec_after.get("state", "")) != "CANCELLED" and str(rec_after.get("state", "")) != "NATIVE_VERIFIED", "NC-11: no false terminal success after failed cancel restart")

	# NC-12: Resume recoverable monitor & cancel cleanly -> monitoring stops, state=CANCELLED, cleanup allowed!
	svc_restart.resume_monitoring(sid_nc)
	var c_ok: Dictionary = svc_restart.cancel_monitoring(sid_nc)
	_check(bool(c_ok.get("ok", false)) and str(c_ok.get("state", "")) == "CANCELLED" and not svc_restart.is_monitoring(sid_nc), "NC-12: successful cancellation stops monitoring and commits durable CANCELLED")
	var rec_nc_done: Dictionary = svc_restart.runner.get_session_record(sid_nc)
	var SessionScript = preload("res://scripts/native/native_experiment_session.gd")
	var sess_nc_done = SessionScript.from_dict(rec_nc_done.get("session", {}))
	if sess_nc_done != null:
		_write(str(sess_nc_done.evidence_path), JSON.stringify({
			"session_id": sid_nc, "stage_id": str(sess_nc_done.stage_id), "status": "CANCELLED"
		}))
	var cl_nc: Dictionary = svc_restart.cleanup_stage(sid_nc)
	_check(bool(cl_nc.get("ok", false)) and str(cl_nc.get("state", "")) == "CLEANED_UP", "NC-12: cleanup succeeds safely after confirmed CANCELLED")
	svc.free()
	svc_restart.free()

	# =========================================================================
	# PART 2: SA-01..SA-09 — STOCK_ADDON Isolation, Mission Identity, Conflicts
	# =========================================================================
	var fake_docs := tmp_root.path_join("mock_docs_sa")
	var fake_addon := fake_docs.path_join("My Games/Battlezone Combat Commander/addon")
	DirAccess.make_dir_recursive_absolute(fake_addon)
	var untouched_user_file := fake_addon.path_join("user_custom_keep.odf")
	var untouched_body := "[GameObjectClass]\nunitName=\"KeepMeUntouched\"\n"
	_write(untouched_user_file, untouched_body)

	var disc_sa := disc.duplicate(true)
	disc_sa["addon_root"] = fake_addon
	var r_sa = NativeRunnerScript.new()
	var pre_sa1: Dictionary = r_sa.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "sa_a",
		"staged_odfs": {"assets/ODF/atstab_a.odf": odf_bytes},
		"steam_override": steam_ok,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	var pre_sa2: Dictionary = r_sa.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "sa_b",
		"staged_odfs": {"assets/ODF/atstab_b.odf": odf_bytes},
		"steam_override": steam_ok,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	var sess_sa1 = pre_sa1.get("session")
	var sess_sa2 = pre_sa2.get("session")
	var mb1 := str(sess_sa1.mission_basename) if sess_sa1 != null else ""
	var mb2 := str(sess_sa2.mission_basename) if sess_sa2 != null else ""
	_check(mb1 != "" and mb2 != "" and mb1 != mb2 and mb1 != "shaman_shot" and mb2 != "shaman_shot", "SA-01: two STOCK_ADDON sessions derive distinct unique mission basenames (%s vs %s)" % [mb1, mb2])
	_check(str(sess_sa1.observation_filename) != str(sess_sa2.observation_filename), "SA-01: two sessions have distinct observation filenames")

	# SA-02: Stage both simultaneously -> clean, no session mission collision, launch args target own mission
	var stg_sa1: Dictionary = r_sa.stage(str(pre_sa1.get("session_id", "")))
	var stg_sa2: Dictionary = r_sa.stage(str(pre_sa2.get("session_id", "")))
	var cmd_sa2: Dictionary = (pre_sa2.get("preflight", {}) as Dictionary).get("launch_command", {})
	var gargs_sa2: Array = cmd_sa2.get("game_args", [])
	_check(bool(stg_sa1.get("ok", false)) and bool(stg_sa2.get("ok", false)) and gargs_sa2.has(mb2 + ".bzn"), "SA-02: two simultaneous STOCK_ADDON stages succeed and target their own mission BZN")

	# SA-03: Attempting to reuse an active session's mission basename is rejected with MISSION_NAME_COLLISION!
	var pre_dup: Dictionary = r_sa.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "sa_dup",
		"mission_base": mb1,
		"staged_odfs": {"assets/ODF/atstab_c_unique.odf": odf_bytes},
		"steam_override": steam_ok,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	_check(not bool(pre_dup.get("launch_eligible", true)) and str(pre_dup.get("reason", "")) == "MISSION_NAME_COLLISION", "SA-03: reusing active mission basename rejected with MISSION_NAME_COLLISION (got %s)" % str(pre_dup.get("reason", "")))

	# SA-04: Session-specific mount marker filename & Lua consistency check
	var f_sa1: Dictionary = pre_sa1.get("files", {})
	var f_sa2: Dictionary = pre_sa2.get("files", {})
	var mk1 := str(sess_sa1.mount_plan.get("marker_odf_filename", ""))
	var mk2 := str(sess_sa2.mount_plan.get("marker_odf_filename", ""))
	_check(mk1 != "" and mk2 != "" and mk1 != mk2 and f_sa1.has("assets/ODF/" + mk1) and f_sa2.has("assets/ODF/" + mk2), "SA-04: STOCK_ADDON sessions isolate mount marker ODF filenames (%s vs %s)" % [mk1, mk2])

	# SA-05: Foreign addon ODF collision detected (read-only) -> blocks launch_eligible & native verification!
	var foreign_coll := fake_addon.path_join("SomeForeignMod/atstab_conflict.odf")
	_write(foreign_coll, "[OrdnanceClass]\ndamageValue(H)=999\n")
	var pre_fcoll: Dictionary = r_sa.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "sa_fcoll",
		"staged_odfs": {"assets/ODF/atstab_conflict.odf": odf_bytes},
		"steam_override": steam_ok,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	var f_rep: Dictionary = (pre_fcoll.get("preflight", {}) as Dictionary).get("addon_conflict_report", {})
	_check(not bool(pre_fcoll.get("launch_eligible", true)) and not bool(f_rep.get("ok", true)) and str(pre_fcoll.get("reason", "")) == "ADDON_FOREIGN_ODF_COLLISION", "SA-05: foreign addon ODF collision detected and blocks launch_eligible (got %s)" % str(pre_fcoll.get("reason", "")))

	# SA-06: Old SHAMAN stage collision detected with safe resolution options!
	var old_shaman := fake_addon.path_join("SHAMAN_legacy_old_stage/assets/ODF/atstab_old_dup.odf")
	_write(old_shaman, "[OrdnanceClass]\ndamageValue(H)=50\n")
	var pre_ocoll: Dictionary = r_sa.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "sa_ocoll",
		"staged_odfs": {"assets/ODF/atstab_old_dup.odf": odf_bytes},
		"steam_override": steam_ok,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	var o_rep: Dictionary = (pre_ocoll.get("preflight", {}) as Dictionary).get("addon_conflict_report", {})
	var o_res_opts: Array = (o_rep.get("provenance", {}) as Dictionary).get("resolution_options", [])
	_check(not bool(pre_ocoll.get("launch_eligible", true)) and str(pre_ocoll.get("reason", "")) == "OLD_SHAMAN_STAGE_COLLISION" and not o_res_opts.is_empty(), "SA-06: old SHAMAN stage ODF collision detected with safe resolution options")

	# SA-07: Cleanup owned stages and verify ZERO foreign addon files modified/removed!
	r_sa.cleanup_stage(str(pre_sa1.get("session_id", "")))
	r_sa.cleanup_stage(str(pre_sa2.get("session_id", "")))
	_check(FileAccess.file_exists(untouched_user_file) and FileAccess.get_file_as_string(untouched_user_file) == untouched_body and FileAccess.file_exists(foreign_coll), "SA-07: unknown/foreign addon files completely untouched after scan and cleanup")

	# SA-08: bzone.cfg parser handles comments, ConfigureStream("base"), SetActiveStream, AppendToMyDocs!
	var cfg_test_root := tmp_root.path_join("mock_cfg_game")
	var cfg_complex := "// leading comment\nConfigureFileSystem()\n{\n\t/* commented out:\n\tAddDirRecurse(\"@mydocsdir\\addon\");\n\t*/\n\tAppendToMyDocs(\"custom_profile\");\n\tConfigureStream(\"unused\")\n\t{\n\t\tAddDirRecurse(\"@mydocsdir\\addon\");\n\t}\n\tConfigureStream(\"live_base\")\n\t{\n\t\tAddDirRecurse(\"@rootdir\\bz2r_res\");\n\t\tAddDirRecurse(\"@mydocsdir\\addon\");\n\t}\n\tSetActiveStream(\"live_base\");\n}\n"
	_write(cfg_test_root.path_join("bzone.cfg"), cfg_complex)
	var parsed_cfg := NativeAdapterScript.inspect_stock_bzone_cfg(cfg_test_root)
	_check(not bool(parsed_cfg.get("ok", true)) and str(parsed_cfg.get("active_stream", "")) == "live_base" and str(parsed_cfg.get("append_to_mydocs", "")) == "custom_profile", "SA-08: inspect_stock_bzone_cfg parses active stream & comments accurately (rejects addon-not-first in active stream)")
	var stock_real := NativeAdapterScript.inspect_stock_bzone_cfg(game_root)
	_check(bool(stock_real.get("ok", false)) and str(stock_real.get("active_stream", "")) == "base" and bool(stock_real.get("mounts_addon_first", false)), "SA-08: real stock BZ2R bzone.cfg resolves active_stream=base with @mydocsdir\\addon first")

	# SA-09: Resource identity matches active ModLoadout (foreign addon overriding loadout ODF is caught)
	var ws_mod := tmp_root.path_join("ws_mod_sa09")
	var pkg_a := ws_mod.path_join("1111111")
	_write(pkg_a.path_join("ivtank_sa09.odf"), "[GameObjectClass]\nweaponName1=\"gwpn_sa09\"\nmaxHealth=1000\narmorClass=\"H\"\n")
	_write(pkg_a.path_join("gwpn_sa09.odf"), "[WeaponClass]\nordName=\"ord_sa09\"\n")
	_write(pkg_a.path_join("ord_sa09.odf"), "[OrdnanceClass]\ndamageValue(H)=120\nshotSpeed=200\nlifeSpan=2.0\n")
	var idx_sa09 := ResourceIndex.new()
	idx_sa09.roots = [
		{"path": game_root.path_join("bz2r_res"), "label": "stock", "kind": "game", "priority": 10, "enabled": true},
		{"path": ws_mod, "label": "ws", "kind": "workshop", "priority": 30, "enabled": true},
	]
	idx_sa09.scan(true)
	var lo := ModLoadoutScript.new()
	lo.profile_id = "sa09_loadout"
	lo.enabled_packages = ["1111111"]
	idx_sa09.apply_loadout(lo)
	var prof_sa09 := WeaponProfile.new()
	prof_sa09.resolve(idx_sa09, pkg_a.path_join("ivtank_sa09.odf"), pkg_a.path_join("ivtank_sa09.odf"))
	var pre_sa09: Dictionary = r_sa.preflight(prof_sa09, idx_sa09, {
		"discovery": disc_sa,
		"stage_prefix": "sa09_lo",
		"steam_override": steam_ok,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
		"active_packages": ["1111111"],
	})
	var c_rep09: Dictionary = (pre_sa09.get("preflight", {}) as Dictionary).get("addon_conflict_report", {})
	_check(str(c_rep09.get("active_loadout_profile_id", "")) == "sa09_loadout" and bool(c_rep09.get("ok", false)), "SA-09: STOCK_ADDON preflight records active ModLoadout provenance cleanly")

	# =========================================================================
	# PART 3: NM-11..NM-16 — ARM MANUAL OBSERVATION & Anti-Spoof Guarantees
	# =========================================================================
	var svc_nm = NativeServiceScript.new()
	svc_nm.ensure_initialized()
	var r_nm = svc_nm.runner
	var preexisting_procs := [{"pid": 1111, "name": "battlezone2.exe", "exe_path": str(disc.get("exe", "")), "exe_md5": str(disc.get("exe_md5", ""))}]
	var live_procs := preexisting_procs.duplicate(true)
	r_nm.process_inspector = func() -> Array: return live_procs
	var pre_nm: Dictionary = r_nm.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "nm11_manual",
		"staged_odfs": {"assets/ODF/atstab_nm11.odf": odf_bytes},
		"steam_override": steam_off,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	var sid_nm := str(pre_nm.get("session_id", ""))
	var stg_nm: Dictionary = svc_nm.stage(sid_nm)
	var sess_nm = stg_nm.get("session")

	# NM-11: Arm manual observation before manual Steam launch -> MONITOR_ARMED, NOT launched/verified!
	var has_arm: bool = svc_nm.has_method("arm_manual_observation")
	var arm_res: Dictionary = svc_nm.call("arm_manual_observation", sid_nm, {"monitor_started_at_s": 0.0, "monitor_timeout_s": 120.0}) if has_arm else {}
	_check(has_arm and bool(arm_res.get("ok", false)) and str(arm_res.get("state", "")) == "MONITOR_ARMED" and svc_nm.is_monitoring(sid_nm), "NM-11: ARM MANUAL OBSERVATION transitions staged session to MONITOR_ARMED with active polling")
	_check(not bool(arm_res.get("game_launched", false)) and not bool(arm_res.get("verified", false)), "NM-11: arming does NOT falsely claim game launched or NATIVE_VERIFIED")

	# NM-12: Persists across editor restart -> fresh NativeSessionService resumes MONITOR_ARMED!
	var svc_nm2 = NativeServiceScript.new()
	svc_nm2.ensure_initialized()
	var r_nm2 = svc_nm2.runner
	r_nm2.process_inspector = func() -> Array: return live_procs
	svc_nm2.recover_pending_sessions()
	var snap_nm2: Dictionary = svc_nm2.get_status_snapshot(sid_nm)
	_check(svc_nm2.is_monitoring(sid_nm) and str(snap_nm2.get("state", "")) == "MONITOR_ARMED", "NM-12: MONITOR_ARMED persists and resumes automatically across restart")

	# NM-13: Late verified game process detected (ignores preexisting PID 1111, detects new verified PID 2222)
	var p_before: Dictionary = svc_nm2.poll_once(sid_nm, 1.0)
	_check(str(p_before.get("state", "")) == "MONITOR_ARMED" and int(p_before.get("game_pid", 0)) == 0, "NM-13: preexisting PID 1111 ignored while MONITOR_ARMED")
	live_procs.append({"pid": 2222, "name": "battlezone2.exe", "exe_path": str(disc.get("exe", "")), "exe_md5": str(disc.get("exe_md5", ""))})
	var p_det: Dictionary = svc_nm2.poll_once(sid_nm, 2.0)
	_check(str(p_det.get("state", "")) == "GAME_PROCESS_VERIFIED" and int(p_det.get("game_pid", 0)) == 2222 and bool(p_det.get("game_exe_verified", false)), "NM-13: late verified battlezone2.exe process transitions MONITOR_ARMED -> GAME_PROCESS_VERIFIED")

	# NM-14: Session-specific Lua observation written to expected path -> collected & compared automatically!
	var obs_path_nm := str(sess_nm.observation_expected_path)
	_write(obs_path_nm, _make_obs_json(sess_nm, 88.0, true))
	var p_obs: Dictionary = svc_nm2.poll_once(sid_nm, 3.0)
	_check(bool(p_obs.get("observation_collected", false)) and str(p_obs.get("state", "")) in ["COMPARISON_COMPLETE", "NATIVE_VERIFIED"], "NM-14: session-specific Lua observation collected automatically after verified process + marker")
	svc_nm2.cleanup_stage(sid_nm)
	svc_nm.free()
	svc_nm2.free()

	# NM-15: Manual import without live verified process -> OBSERVATION_IMPORTED -> COMPARISON_COMPLETE (unattested, NEVER NATIVE_VERIFIED)
	var r_imp = NativeRunnerScript.new()
	var pre_imp: Dictionary = r_imp.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "nm15_import",
		"staged_odfs": {"assets/ODF/atstab_nm15.odf": odf_bytes},
		"steam_override": steam_off,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	var sid_imp := str(pre_imp.get("session_id", ""))
	var stg_imp: Dictionary = r_imp.stage(sid_imp)
	var sess_imp = stg_imp.get("session")
	var imp_file := tmp_root.path_join("manual_imported_obs.json")
	_write(imp_file, _make_obs_json(sess_imp, 60.0, true))
	var has_imp: bool = r_imp.has_method("import_manual_observation")
	var imp_res: Dictionary = r_imp.call("import_manual_observation", sid_imp, imp_file) if has_imp else {}
	_check(has_imp and bool(imp_res.get("ok", false)) and str(imp_res.get("state", "")) == "COMPARISON_COMPLETE" and bool(imp_res.get("unattested", false)) and not bool(imp_res.get("verified", true)), "NM-15: manual import reaches COMPARISON_COMPLETE with unattested=true and verified=false")
	r_imp.cleanup_stage(sid_imp)

	# NM-16: Fake / unverified PID (legacy detector without exe+MD5) + observation NEVER creates NATIVE_VERIFIED!
	var r_fake = NativeRunnerScript.new()
	r_fake.game_process_detector = func() -> Dictionary: return {"detected": true, "game_pid": 7777}
	var pre_fk: Dictionary = r_fake.preflight(null, null, {
		"discovery": disc_sa,
		"stage_prefix": "nm16_fake",
		"staged_odfs": {"assets/ODF/atstab_nm16.odf": odf_bytes},
		"steam_override": steam_off,
		"launch_mode": "STOCK_ADDON",
		"docs_dir_override": fake_docs,
	})
	var sid_fk := str(pre_fk.get("session_id", ""))
	var stg_fk: Dictionary = r_fake.stage(sid_fk)
	var sess_fk = stg_fk.get("session")
	var fk_arm: Dictionary = r_fake.call("arm_manual_observation", sid_fk, {"monitor_started_at_s": 0.0, "monitor_timeout_s": 60.0}) if r_fake.has_method("arm_manual_observation") else {}
	var fk_p1: Dictionary = r_fake.poll_monitor(sid_fk, 1.0)
	_write(str(sess_fk.observation_expected_path), _make_obs_json(sess_fk, 75.0, true))
	var fk_p2: Dictionary = r_fake.poll_monitor(sid_fk, 2.0)
	_check(bool(fk_arm.get("ok", false)) and str(fk_p1.get("state", "")) == "GAME_PROCESS_CANDIDATE", "NM-16: unverified PID enters GAME_PROCESS_CANDIDATE, not GAME_PROCESS_VERIFIED")
	_check(not bool(fk_p2.get("verified", true)) and str(fk_p2.get("state", "")) != "NATIVE_VERIFIED", "NM-16: fake/unverified PID + observation NEVER produces NATIVE_VERIFIED (got %s)" % str(fk_p2.get("state", "")))
	r_fake.cancel_monitor(sid_fk)
	r_fake.cleanup_stage(sid_fk)

	# NATIVE-23..27: read-only stage inventory proves ownership and refuses
	# cleanup while the session is STAGED (non-terminal).
	var sm = load("res://scripts/native/safe_stage_manager.gd")
	var stage_dir := tmp_root.path_join("inventory_stage")
	DirAccess.make_dir_recursive_absolute(stage_dir)
	var payload_path := stage_dir.path_join("mission.bzn")
	_write(payload_path, "payload")
	var payload_md5 := WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(payload_path))
	var stage_manifest := {
		"schema": 1,
		"stage_id": "inventory_stage",
		"stage_root": stage_dir,
		"files": [{"rel": "mission.bzn", "bytes": 7, "md5": payload_md5}],
	}
	_write(stage_dir.path_join("stage_manifest.json"), JSON.stringify(stage_manifest))
	_write(stage_dir.path_join("native_evidence.json"), JSON.stringify({
		"session_id": "inventory_session", "stage_id": "inventory_stage", "status": "STAGED"
	}))
	var inv: Dictionary = sm.inspect_stage(stage_dir)
	_check(bool(inv.get("ok", false)) and str(inv.get("hash_status", "")) == "MATCH" and
		str(inv.get("session_status", "")) == "STAGED" and not bool(inv.get("cleanup_allowed", true)),
		"NATIVE-23/26: staged owned stage reports MATCH but cleanup refused")
	_write(stage_dir.path_join("native_evidence.json"), JSON.stringify({
		"session_id": "inventory_session", "stage_id": "inventory_stage", "status": "COMPLETE"
	}))
	var terminal_inv: Dictionary = sm.inspect_stage(stage_dir)
	_check(bool(terminal_inv.get("cleanup_allowed", false)),
		"NATIVE-27: terminal owned stage with matching hashes is cleanup-eligible")
	_write(payload_path, "tampered!")
	var tampered_inv: Dictionary = sm.inspect_stage(stage_dir)
	_check(not bool(tampered_inv.get("cleanup_allowed", true)) and
		(tampered_inv.get("modified_files", []) as Array).size() > 0,
		"NATIVE-25: hash mismatch prevents cleanup even for terminal stage")

	# NSTAGE: read-only reconciliation across restart, ledger status, and safety.
	var ledger := tmp_root.path_join("native_sessions").path_join("session_ledger.json")
	DirAccess.make_dir_recursive_absolute(ledger.get_base_dir())
	var monitors_file := ledger.get_base_dir().path_join("process_monitors.json")
	if FileAccess.file_exists(monitors_file):
		DirAccess.remove_absolute(monitors_file)
	var evidence_path := stage_dir.path_join("native_evidence.json")
	_write(ledger, JSON.stringify({"sessions": {"inventory_session": {"state": "STAGED"}}}))
	var active_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(not bool(active_rec.get("cleanup_allowed", true)) and
		str(active_rec.get("reason", "")) == "STAGE_HASH_MISMATCH" and
		bool(active_rec.get("evidence_preserved", false)),
		"NSTAGE-04/15: hash mismatch protects stage and preserves evidence")
	_write(payload_path, "payload")
	var active_match: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(active_match.get("action", "")) == "PROTECT" and
		str(active_match.get("reason", "")) == "STAGE_ACTIVE_OR_RECOVERABLE" and
		str(active_match.get("ledger_status", "")) == "MATCH",
		"NSTAGE-02/09: ledger active state protects owned matching stage")
	_write(ledger, JSON.stringify({"sessions": {"inventory_session": {"state": "COMPLETE"}}}))
	var terminal_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(terminal_rec.get("action", "")) == "CLEANUP_ELIGIBLE" and
		bool(terminal_rec.get("cleanup_allowed", false)) and
		str(terminal_rec.get("ledger_status", "")) == "MATCH",
		"NSTAGE-01/13: valid terminal ledger authorizes cleanup eligibility")
	_check(FileAccess.file_exists(payload_path) and FileAccess.file_exists(evidence_path) and
		FileAccess.file_exists(stage_dir.path_join("stage_manifest.json")),
		"NSTAGE-16: reconciliation is read-only; all stage files remain")

	var missing_manifest := tmp_root.path_join("unknown_stage")
	DirAccess.make_dir_recursive_absolute(missing_manifest)
	var unknown_rec: Dictionary = sm.reconcile_stage(missing_manifest, ledger)
	_check(str(unknown_rec.get("action", "")) == "PROTECT" and
		str(unknown_rec.get("reason", "")) == "MANIFEST_MISSING",
		"NSTAGE-03: missing manifest stage stays protected (specific MANIFEST_MISSING reason)")

	DirAccess.remove_absolute(ledger)
	var missing_ledger_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(missing_ledger_rec.get("action", "")) == "PROTECT" and
		str(missing_ledger_rec.get("ledger_status", "")) == "LEDGER_NOT_FOUND" and
		bool(missing_ledger_rec.get("recovery_pending", false)),
		"NSTAGE-10: missing ledger yields PROTECT/RECOVERY_PENDING")
	_write(ledger, JSON.stringify({"sessions": {"other_session": {"state": "COMPLETE"}}}))
	var absent_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(absent_rec.get("action", "")) == "PROTECT" and
		str(absent_rec.get("ledger_status", "")) == "SESSION_NOT_IN_LEDGER",
		"NSTAGE-11: session absent from ledger stays protected")
	_write(ledger, JSON.stringify({"sessions": {"inventory_session": {"state": "COMPLETE"}}}))
	_write(evidence_path, JSON.stringify({
		"session_id": "inventory_session", "stage_id": "inventory_stage", "status": "STAGED"
	}))
	var disagree_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(disagree_rec.get("action", "")) == "PROTECT" and
		str(disagree_rec.get("reason", "")) == "LEDGER_EVIDENCE_DISAGREE",
		"NSTAGE-12: ledger/evidence disagreement stays protected")
	_write(evidence_path, JSON.stringify({
		"session_id": "inventory_session", "stage_id": "inventory_stage", "status": "COMPLETE"
	}))

	_write(monitors_file, JSON.stringify({"monitors": {"inventory_session": {
		"state": "MONITOR_ARMED", "active": true, "recoverable": false
	}}}))
	var monitor_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(monitor_rec.get("action", "")) == "PROTECT" and
		str(monitor_rec.get("reason", "")) == "ACTIVE_MONITOR",
		"NSTAGE-14: active monitor keeps terminal session ineligible")
	DirAccess.remove_absolute(monitors_file)

	_write(payload_path, "tampered!")
	var modified_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(modified_rec.get("action", "")) == "PROTECT" and
		str(modified_rec.get("reason", "")) == "STAGE_HASH_MISMATCH",
		"NSTAGE-15: modified stage files stay protected")
	_write(payload_path, "payload")

	_write(ledger, "not json")
	var corrupt_rec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
	_check(str(corrupt_rec.get("ledger_status", "")) == "LEDGER_CORRUPT" and
		str(corrupt_rec.get("action", "")) == "PROTECT" and
		bool(corrupt_rec.get("recovery_pending", false)) and
		not bool(corrupt_rec.get("cleanup_allowed", true)),
		"NSTAGE-09: corrupt ledger yields PROTECT/RECOVERY_PENDING, never CLEANUP_ELIGIBLE")

	# NSTAGE-23..27: monitor state must be validated independently of `active`.
	_write(ledger, JSON.stringify({"sessions": {"inventory_session": {"state": "COMPLETE"}}}))
	_write(evidence_path, JSON.stringify({
		"session_id": "inventory_session", "stage_id": "inventory_stage", "status": "COMPLETE"
	}))
	var monitor_cases := [
		{"state": "MONITOR_ARMED", "active": false, "recoverable": false, "code": "NSTAGE-23"},
		{"state": "GAME_PROCESS_DETECTED", "active": false, "recoverable": false, "code": "NSTAGE-24"},
		{"state": "MYSTERY_STATE", "active": false, "recoverable": false, "code": "NSTAGE-25"},
		{"state": "NATIVE_VERIFIED", "active": false, "recoverable": false, "code": "NSTAGE-26"},
		{"state": "CANCELLED", "active": false, "recoverable": true, "code": "NSTAGE-27"},
	]
	for case in monitor_cases:
		var c: Dictionary = case
		_write(monitors_file, JSON.stringify({"monitors": {"inventory_session": {
			"state": c.get("state", ""), "active": bool(c.get("active", false)),
			"recoverable": bool(c.get("recoverable", false))
		}}}))
		var mrec: Dictionary = sm.reconcile_stage(stage_dir, ledger)
		var expect_eligible := str(c.get("code", "")) == "NSTAGE-26"
		_check((str(mrec.get("action", "")) == "CLEANUP_ELIGIBLE") == expect_eligible and
			(bool(mrec.get("cleanup_allowed", false)) == expect_eligible),
			str(c.get("code", "")) + ": monitor " + str(c.get("state", "")) +
			" active=false recoverable=" + str(c.get("recoverable", false)) +
			" -> " + str(mrec.get("action", "")) + "/" + str(mrec.get("reason", "")))
	if FileAccess.file_exists(monitors_file):
		DirAccess.remove_absolute(monitors_file)

	# NSTAGE-17..22: GUI inventory verdict must equal authoritative reconciliation.
	var WeaponLabScript = load("res://scripts/lab/weapon_lab.gd")
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	var inv_root := tmp_root.path_join("inventory_parent")
	DirAccess.make_dir_recursive_absolute(inv_root.path_join("SHAMAN_gui"))
	var payload_source := inv_root.path_join("SHAMAN_gui/mission.bzn")
	_write(payload_source, "payload")
	var manifest: Dictionary = {
		"schema": 1, "stage_id": "gui_stage", "stage_root": inv_root.path_join("SHAMAN_gui"),
		"files": [{"rel": "mission.bzn", "bytes": 7, "md5": WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(payload_source))}],
	}
	_write(inv_root.path_join("SHAMAN_gui/stage_manifest.json"), JSON.stringify(manifest))
	_write(inv_root.path_join("SHAMAN_gui/native_evidence.json"), JSON.stringify({
		"session_id": "inventory_session", "stage_id": "gui_stage", "status": "COMPLETE"
	}))
	var inv_roots: Array[String] = [inv_root]

	# Corrupt ledger -> GUI must refuse.
	_write(ledger, "not json")
	var inv_corrupt: Array[Dictionary] = lab.inspect_native_stages(inv_roots)
	_check(inv_corrupt.size() == 1 and not bool(inv_corrupt[0].get("cleanup_allowed", true)) and
		bool(inv_corrupt[0].get("recovery_pending", false)),
		"NSTAGE-17: GUI shows corrupt ledger as refused/recovery-required")

	# Missing ledger -> GUI must refuse.
	DirAccess.remove_absolute(ledger)
	var inv_missing: Array[Dictionary] = lab.inspect_native_stages(inv_roots)
	_check(inv_missing.size() == 1 and not bool(inv_missing[0].get("cleanup_allowed", true)) and
		str(inv_missing[0].get("ledger_status", "")) == "LEDGER_NOT_FOUND",
		"NSTAGE-18: GUI refuses missing ledger")

	# Active monitor -> GUI must refuse.
	_write(ledger, JSON.stringify({"sessions": {"inventory_session": {"state": "COMPLETE"}}}))
	_write(monitors_file, JSON.stringify({"monitors": {"inventory_session": {
		"state": "MONITOR_ARMED", "active": true, "recoverable": false
	}}}))
	var inv_monitor: Array[Dictionary] = lab.inspect_native_stages(inv_roots)
	_check(inv_monitor.size() == 1 and not bool(inv_monitor[0].get("cleanup_allowed", true)) and
		str(inv_monitor[0].get("action", "")) == "PROTECT",
		"NSTAGE-19: GUI refuses active monitor")
	DirAccess.remove_absolute(monitors_file)

	# Valid terminal, no monitor -> GUI eligible and equal to reconciliation.
	var inv_ok: Array[Dictionary] = lab.inspect_native_stages(inv_roots)
	var authoritative: Dictionary = sm.reconcile_stage(inv_root.path_join("SHAMAN_gui"), ledger)
	_check(inv_ok.size() == 1 and bool(inv_ok[0].get("cleanup_allowed", false)) and
		str(inv_ok[0].get("action", "")) == "CLEANUP_ELIGIBLE",
		"NSTAGE-20: valid terminal stage eligible in GUI")
	_check(str(inv_ok[0].get("action", "")) == str(authoritative.get("action", "")) and
		str(inv_ok[0].get("reason", "")) == str(authoritative.get("reason", "")),
		"NSTAGE-21: GUI inventory equals reconciliation verdict")
	_check(FileAccess.file_exists(payload_source) and
		FileAccess.file_exists(inv_root.path_join("SHAMAN_gui/native_evidence.json")),
		"NSTAGE-22: inventory never deletes stage files")
	lab.queue_free()

	# T-85 NC-28..NC-32: actual runtime cleanup must obey reconciliation.
	var rr = NativeRunnerScript.new()
	rr.process_launcher = func(_e: String, _a: Array) -> Dictionary: return {"ok": true, "pid": 0, "exit_code": 0}
	var pre_cl: Dictionary = rr.preflight(null, null, {
		"discovery": disc, "stage_prefix": "t85clean",
		"staged_odfs": {"assets/ODF/t85clean.odf": odf_bytes},
		"config_path_override": game_root.path_join("t85clean.cfg"),
		"steam_override": steam_ok,
	})
	var sid_cl := str(pre_cl.get("session_id", ""))
	var st_cl: Dictionary = rr.stage(sid_cl)
	var sess_cl = st_cl.get("session")
	var stage_cl := str(sess_cl.stage_root)
	var cl_payload := stage_cl.path_join("mission.bzn")
	if not FileAccess.file_exists(cl_payload):
		_write(cl_payload, "t85")
	var cl_ledger := ledger.get_base_dir().path_join("session_ledger.json")
	DirAccess.make_dir_recursive_absolute(cl_ledger.get_base_dir())

	# Refuse RECOVERY_PENDING even if a monitor says terminal.
	rr.sessions[sid_cl]["state"] = "RECOVERY_PENDING"
	_write(cl_ledger, JSON.stringify({"sessions": {sid_cl: {"state": "RECOVERY_PENDING"}}}))
	var cl_files_before := FileAccess.get_file_as_bytes(stage_cl.path_join("stage_manifest.json"))
	var reject_28: Dictionary = rr.cleanup_stage(sid_cl)
	_check(not bool(reject_28.get("ok", true)) and bool(reject_28.get("cleanup_rejected", false)) and
		FileAccess.file_exists(stage_cl.path_join("stage_manifest.json")) and
		FileAccess.get_file_as_bytes(stage_cl.path_join("stage_manifest.json")) == cl_files_before,
		"NC-28: RECOVERY_PENDING runtime cleanup refused and files preserved")

	# Refuse FAILED with active monitor.
	rr.sessions[sid_cl]["state"] = "FAILED"
	rr.sessions[sid_cl]["monitor"] = {"state": "MONITOR_ARMED", "active": true, "recoverable": false}
	_write(cl_ledger, JSON.stringify({"sessions": {sid_cl: {"state": "FAILED"}}}))
	var reject_29: Dictionary = rr.cleanup_stage(sid_cl)
	_check(not bool(reject_29.get("ok", true)) and bool(reject_29.get("cleanup_rejected", false)),
		"NC-29: FAILED with active monitor refuses cleanup")

	# Refuse CANCELLED with recoverable monitor.
	rr.sessions[sid_cl]["state"] = "CANCELLED"
	rr.sessions[sid_cl]["monitor"] = {"state": "CANCELLED", "active": false, "recoverable": true}
	_write(cl_ledger, JSON.stringify({"sessions": {sid_cl: {"state": "CANCELLED"}}}))
	var reject_30: Dictionary = rr.cleanup_stage(sid_cl)
	_check(not bool(reject_30.get("ok", true)) and bool(reject_30.get("cleanup_rejected", false)),
		"NC-30: CANCELLED with recoverable monitor refuses cleanup")

	# NC-32: valid terminal session with a matching owned stage cleans up.
	var reg32: Dictionary = sm.register_owned_base(tmp_root)
	var sid32 := "nc32_synthetic"
	var sess32 = sess_cl
	sess32.stage_root = stage_dir
	sess32.session_id = sid32
	sess32.stage_id = "inventory_stage"
	rr.sessions[sid32] = {
		"state": "COMPLETE", "session_id": sid32, "session": sess32.to_dict(),
		"updated_at": Time.get_datetime_string_from_system(),
	}
	_write(evidence_path, JSON.stringify({
		"session_id": sid32, "stage_id": "inventory_stage", "status": "COMPLETE"
	}))
	_write(cl_ledger, JSON.stringify({"sessions": {sid32: {"state": "COMPLETE"}}}))
	var allow_32: Dictionary = rr.cleanup_stage(sid32)
	_check(bool(allow_32.get("ok", false)) and str(allow_32.get("state", "")) == "CLEANED_UP" and
		FileAccess.file_exists(NativeRunnerScript.ledger_dir().path_join(sid32 + ".cleanup_intent.json")),
		"NC-32: valid quiescent terminal cleanup commits with durable intent")
	var intent = WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(NativeRunnerScript.ledger_dir().path_join(sid32 + ".cleanup_intent.json")))
	_check(bool(intent.get("ok", false)) and str((intent.get("data", {}) as Dictionary).get("state", "")) == "CLEANUP_COMPLETE",
		"NC-38: no false CLEANED_UP without completed cleanup intent")

	NativeAdapterScript.clear_trusted_sessions()
	OdfDocument.clear_all_cache()
	WorkspaceStore.root_override = old_ws_root
	_remove_tree(tmp_root)

	print("\nT-73 Verifier: %d checks, %d failure(s)" % [passed + failed, failed])
	if failed == 0:
		print("RESULT: PASS")
		quit(0)
	else:
		print("RESULT: FAIL")
		quit(1)
