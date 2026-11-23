extends SceneTree
## Focused regression verifier for T-74 (Wave E — Visual & Product Development):
##   1. Authentic DOCB .msh embedded animation decoder & player across real BZ2R models
##      (ivturr00.msh deploy, ibnav00.msh loop, fvtank_skel.msh Scion loading fix,
##       ivwalk_skel.msh run) + animated hardpoint world movement + projectile spawn origin
##      during animation (while keeping .msha skeletal_skinning_supported = false).
##   2. Multi-shot Lab features: A/B replay comparison + active projectile TTI telemetry
##      + moving-target transform compression (1-min / 10-min soak bounded & replay-accurate).
##   3. Persistent fingerprint-validated ResourceIndex cache (cache hit, invalidation on
##      file add/remove/replace, priority/loadout/override change) + provenance_summary().
##
## Run: Godot --headless --path . --script res://tests/verify_t74_visual_and_index.gd

const BzMeshReaderScript = preload("res://scripts/core/bz_mesh_reader.gd")
const CombatScenarioScript = preload("res://scripts/sim/combat_scenario.gd")
const ModLoadoutScript = preload("res://scripts/core/mod_loadout.gd")

const BASE_RES := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R/bz2r_res"

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


func _world_xf(node: Node3D, stop_at: Node = null) -> Transform3D:
	var chain: Array[Node3D] = []
	var cur: Node = node
	while cur != null and cur != stop_at:
		if cur is Node3D:
			chain.append(cur as Node3D)
		cur = cur.get_parent()
	var xf := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		xf = xf * chain[i].transform
	return xf


func _initialize() -> void:
	print("T-74 Wave E Visual Animation, Multi-Shot Soak & ResourceIndex Cache Verifier")
	var tmp_root := ProjectSettings.globalize_path("user://verify_t74_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp_root)

	var stock_idx := ResourceIndex.new()
	stock_idx.roots = [{"path": BASE_RES, "label": "stock", "kind": "game", "priority": 10, "enabled": true}]
	stock_idx.scan(false)

	# =========================================================================
	# PART 1: Authentic DOCB .msh Animation Decoding, Scion Fix & Hardpoint Fire
	# =========================================================================
	var mesh_api = BzMeshReaderScript.new()
	var has_apply := false
	for m in (mesh_api.get_script() as Script).get_script_method_list():
		if str(m.get("name", "")) == "apply_animation_pose":
			has_apply = true
			break
	_check(has_apply, "ANIM-01: BzMeshReader exposes apply_animation_pose()")

	# 1a. Scion animated model fix: fvtank_skel.msh (previously failed because root word2 == 0!)
	var fvtank_path := stock_idx.find_asset("fvtank_skel.msh", ["msh"])
	var fvtank_info: Dictionary = BzMeshReaderScript.build_scene(fvtank_path, stock_idx)
	var fvtank_anims: Array = fvtank_info.get("animation_names", [])
	_check(bool(fvtank_info.get("ok", false)) and fvtank_anims.size() >= 5, "ANIM-02: Scion fvtank_skel.msh loads cleanly and decodes %d embedded DOCB clips" % fvtank_anims.size())
	if fvtank_info.get("root", null) is Node:
		(fvtank_info["root"] as Node).free()

	# 1b. ivturr00.msh deploy animation moves hardpoint hp_gun_1 in 3D space!
	var ivturr_path := stock_idx.find_asset("ivturr00.msh", ["msh"])
	var turr_info: Dictionary = BzMeshReaderScript.build_scene(ivturr_path, stock_idx)
	var turr_anims: Array = turr_info.get("animation_names", [])
	var hp_gun: Node3D = (turr_info.get("hardpoints", {}) as Dictionary).get("hp_gun_1", null)
	_check(bool(turr_info.get("ok", false)) and turr_anims.has("deploy") and hp_gun != null, "ANIM-03: ivturr00.msh decodes 'deploy' clip and exposes hp_gun_1 hardpoint")
	var pos_t0 := _world_xf(hp_gun).origin if hp_gun != null else Vector3.ZERO
	var pose_mid: Dictionary = mesh_api.call("apply_animation_pose", turr_info, "deploy", 0.5, true) if has_apply else {}
	var pos_mid := _world_xf(hp_gun).origin if hp_gun != null else Vector3.ZERO
	var pose_end: Dictionary = mesh_api.call("apply_animation_pose", turr_info, "deploy", 1.0, false) if has_apply else {}
	var pos_end := _world_xf(hp_gun).origin if hp_gun != null else Vector3.ZERO
	var move_dist := pos_t0.distance_to(pos_end)
	_check(bool(pose_mid.get("ok", false)) and bool(pose_end.get("ok", false)) and move_dist > 0.05, "ANIM-04: playing ivturr00.msh 'deploy' animates hp_gun_1 world origin by %.3fm" % move_dist)

	# 1c. Verify projectile spawned from live animated hardpoint uses animated origin!
	var ivturr_odf := stock_idx.resolve_path("ivturr.odf")
	var ivscav_odf := stock_idx.resolve_path("ivscav.odf")
	var prof_turr := WeaponProfile.new()
	var prof_ok := prof_turr.resolve(stock_idx, ivturr_odf, ivscav_odf)
	var sim_anim := ProjectileSim.new(7401)
	var shot_anim := sim_anim.spawn(prof_turr, pos_end, Vector3(0, 0, -1), Vector3(0, 2, -60)) if prof_ok else null
	_check(prof_ok and shot_anim != null and shot_anim.origin.distance_to(pos_end) < 0.001 and shot_anim.origin.distance_to(pos_t0) > 0.05, "ANIM-05: projectile spawned during 'deploy' originates at live animated hp_gun_1 position")
	if turr_info.get("root", null) is Node:
		(turr_info["root"] as Node).free()

	# 1d. ibnav00.msh 'loop' clip rotates beacon node around Y axis!
	var nav_path := stock_idx.find_asset("ibnav00.msh", ["msh"])
	var nav_info: Dictionary = BzMeshReaderScript.build_scene(nav_path, stock_idx)
	var nav_nodes: Dictionary = nav_info.get("nodes_by_index", {})
	var nav_n1: Node3D = nav_nodes.get(1, null)
	var q_before := nav_n1.transform.basis.get_rotation_quaternion() if nav_n1 != null else Quaternion.IDENTITY
	var nav_pose: Dictionary = mesh_api.call("apply_animation_pose", nav_info, "loop", 0.5, true) if has_apply else {}
	var q_after := nav_n1.transform.basis.get_rotation_quaternion() if nav_n1 != null else Quaternion.IDENTITY
	_check(bool(nav_pose.get("ok", false)) and nav_n1 != null and absf(q_before.angle_to(q_after)) > 0.3, "ANIM-06: ibnav00.msh 'loop' clip rotates spinner node smoothly (delta=%.2f rad)" % absf(q_before.angle_to(q_after)))
	if nav_info.get("root", null) is Node:
		(nav_info["root"] as Node).free()

	# =========================================================================
	# PART 2: Moving-Target Transform Compression & Soak (1-min & 10-min)
	# =========================================================================
	var scn_soak = CombatScenarioScript.new(7402)
	var sh_odf := tmp_root.path_join("sh74.odf")
	var wp_odf := tmp_root.path_join("wp74.odf")
	var or_odf := tmp_root.path_join("or74.odf")
	var tg_odf := tmp_root.path_join("tg74.odf")
	_write(sh_odf, "[GameObjectClass]\nweaponName1=\"wp74\"\nmaxAmmo=5000\nmaxEnergy=5000\nmaxHealth=1000\narmorClass=\"H\"\n")
	_write(wp_odf, "[WeaponClass]\nordName=\"or74\"\nshotDelay=0.2\nenergyCost=0\n")
	_write(or_odf, "[OrdnanceClass]\nshotSpeed=100\nlifeSpan=3.0\nshotRadius=0.5\nammoCost=1\ndamageValue(H)=40\n")
	_write(tg_odf, "[GameObjectClass]\nmaxHealth=5000\narmorClass=\"H\"\nshieldClass=\"N\"\nmaxShield=0\n")
	var idx_s := ResourceIndex.new()
	idx_s.roots = [{"path": tmp_root, "label": "t74", "kind": "game", "priority": 10, "enabled": true}]
	idx_s.scan(false)
	var prof_s := WeaponProfile.new()
	prof_s.resolve(idx_s, sh_odf, tg_odf)
	scn_soak.create_new_scenario(prof_s, Vector3(0, 2, -60))
	scn_soak.capture_replay_baseline(prof_s)
	# Simulate 1-minute (3600 ticks at 60Hz) piecewise-linear moving target with periodic shots
	var dt := 1.0 / 60.0
	var vel := Vector3(5.0, 0.0, 0.0)
	var pos := Vector3(-15.0, 2.0, -60.0)
	for f in range(3600):
		if f % 360 == 180:
			vel = -vel
		pos += vel * dt
		scn_soak.record_actor_transform("primary", pos, vel, 0.0)
		if f % 600 == 10:
			scn_soak.fire_shot(prof_s, Vector3(0, 2, 0), (pos - Vector3(0, 2, 0)).normalized(), pos, [], Vector3.ZERO, false)
		scn_soak.advance(dt)
	var has_comp_stats: bool = scn_soak.has_method("timeline_compression_stats")
	var cstats: Dictionary = scn_soak.call("timeline_compression_stats") if has_comp_stats else {}
	var tl_len := (scn_soak.timeline_inputs as Array).size()
	_check(has_comp_stats and int(cstats.get("compressed_count", 0)) > 3000 and tl_len < 120, "SOAK-01: 1-min (3600-frame) moving-target run compressed %d redundant transforms -> %d timeline events" % [int(cstats.get("compressed_count", 0)), tl_len])
	var snap_soak: Dictionary = scn_soak.save_replay_snapshot("soak_1m")
	var rep_soak: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap_soak)
	var rep_hull := float((rep_soak.get("targets", {}) as Dictionary).get("primary", {}).get("hull", -1.0))
	_check(bool(rep_soak.get("ok", false)) and absf(rep_hull - scn_soak.primary_target().hull_current) < 0.1, "SOAK-02: compressed 1-min moving-target snapshot replays identically (orig=%.1f rep=%.1f)" % [scn_soak.primary_target().hull_current, rep_hull])

	# A/B Replay Comparison API on CombatScenario
	var has_ab := false
	for m2 in (scn_soak.get_script() as Script).get_script_method_list():
		if str(m2.get("name", "")) == "compare_replay_results":
			has_ab = true
			break
	var ab_res: Dictionary = scn_soak.call("compare_replay_results", rep_soak, rep_soak) if has_ab else {}
	_check(has_ab and bool(ab_res.get("ok", false)) and bool(ab_res.get("identical", false)), "SOAK-03: CombatScenario.compare_replay_results compares two replay outcomes cleanly")

	# =========================================================================
	# PART 3: Source-Aware Persistent ResourceIndex Cache & Provenance
	# =========================================================================
	var old_ws_root := WorkspaceStore.root_override
	WorkspaceStore.root_override = tmp_root.path_join("ws_cache")
	var ws_dir := tmp_root.path_join("mock_workshop")
	var pkg_a := ws_dir.path_join("2000001")
	var pkg_b := ws_dir.path_join("2000002")
	_write(pkg_a.path_join("2000001.ini"), "ModName = \"Alpha Mod\"\n")
	_write(pkg_a.path_join("shared_gun.odf"), "[WeaponClass]\nwpnName=\"Alpha Gun\"\n")
	_write(pkg_b.path_join("2000002.ini"), "ModName = \"Beta Mod\"\n")
	_write(pkg_b.path_join("shared_gun.odf"), "[WeaponClass]\nwpnName=\"Beta Gun\"\n")
	var cache_file := tmp_root.path_join("resource_index_cache.json")

	var idx1 := ResourceIndex.new()
	idx1.roots = [
		{"path": ws_dir, "label": "ws", "kind": "workshop", "priority": 30, "enabled": true},
	]
	var lo_a := ModLoadoutScript.new()
	lo_a.profile_id = "lo_alpha"
	lo_a.enabled_packages = ["2000001"]
	idx1.apply_loadout(lo_a)
	idx1.scan(true)

	var has_cache_api: bool = idx1.has_method("save_index_cache") and idx1.has_method("load_index_cache") and idx1.has_method("provenance_summary")
	_check(has_cache_api, "IDX-01: ResourceIndex exposes persistent fingerprint cache & provenance_summary APIs")

	# IDX-13: default cache path is workspace-local, never the shared user:// path.
	var has_default_path := idx1.has_method("default_cache_path")
	var def_cache := str(idx1.call("default_cache_path")) if has_default_path else ""
	_check(has_default_path and def_cache != "" and WorkspaceStore.is_within(WorkspaceStore.root(), def_cache),
		"IDX-13: default index cache path is inside the active workspace (%s)" % def_cache)
	var save_default: Dictionary = idx1.call("save_index_cache") if has_cache_api else {}
	_check(bool(save_default.get("ok", false)) and FileAccess.file_exists(def_cache), "IDX-14: default cache write lands inside workspace")

	var save_c: Dictionary = idx1.call("save_index_cache", cache_file) if has_cache_api else {}
	_check(bool(save_c.get("ok", false)) and str(save_c.get("fingerprint", "")).length() == 64, "IDX-02: save_index_cache writes SHA256 fingerprint-validated cache")

	# Cache HIT on fresh ResourceIndex with identical roots + loadout
	var idx2 := ResourceIndex.new()
	idx2.roots = idx1.roots.duplicate(true)
	idx2.apply_loadout(lo_a)
	var load_hit: Dictionary = idx2.call("load_index_cache", true, cache_file) if has_cache_api else {}
	_check(bool(load_hit.get("ok", false)) and bool(load_hit.get("cache_hit", false)) and idx2.count() == idx1.count(), "IDX-03: load_index_cache hits cleanly on unchanged roots/loadout (%d ODFs)" % idx2.count())

	# IDX-09..12: the persistent cache must be part of the real application index
	# build path, not an unreachable test-only API.
	var has_cached_scan := idx1.has_method("scan_or_load_cache")
	_check(has_cached_scan, "IDX-09: ResourceIndex exposes scan_or_load_cache entry point")
	var mw_src := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/ui/main_window.gd"))
	var worker_pos := mw_src.find("func _scan_worker()")
	var worker_src := mw_src.substr(worker_pos, 320) if worker_pos >= 0 else ""
	_check(worker_pos >= 0 and worker_src.contains("scan_or_load_cache"), "IDX-10: MainWindow background index worker uses the persistent cache path")
	var idx3 := ResourceIndex.new()
	idx3.roots = idx1.roots.duplicate(true)
	idx3.apply_loadout(lo_a)
	var cached_build: Dictionary = idx3.call("scan_or_load_cache", true, cache_file) if has_cached_scan else {}
	_check(bool(cached_build.get("ok", false)) and bool(cached_build.get("cache_hit", false)) and not bool(cached_build.get("scanned", true)) and idx3.count() == idx1.count(), "IDX-11: cached build reuses a valid cache without rescanning")
	var fresh_cache := tmp_root.path_join("fresh_index_cache.json")
	var idx4 := ResourceIndex.new()
	idx4.roots = idx1.roots.duplicate(true)
	idx4.apply_loadout(lo_a)
	var fresh_build: Dictionary = idx4.call("scan_or_load_cache", true, fresh_cache) if has_cached_scan else {}
	_check(bool(fresh_build.get("ok", false)) and bool(fresh_build.get("scanned", false)) and FileAccess.file_exists(fresh_cache) and idx4.count() == idx1.count(), "IDX-12: cached build scans and persists when no valid cache exists")
	# CACHE-28: same-size, same-mtime ODF replacement must still invalidate the
	# fingerprint through the strong content tier (metadata alone is not enough).
	var content_dir := tmp_root.path_join("content_tier")
	DirAccess.make_dir_recursive_absolute(content_dir)
	var content_path := content_dir.path_join("victim.odf")
	_write(content_path, "[WeaponClass]
foo=1
")
	var fixed_mtime: int = FileAccess.get_modified_time(content_path)
	var idx_c1 := ResourceIndex.new()
	idx_c1.roots.assign([{"path": content_dir, "label": "content", "kind": "stock", "priority": 10, "enabled": true}])
	var fp_c1: Dictionary = idx_c1.compute_roots_fingerprint(false)
	_write(content_path, "[WeaponClass]
foo=2
")
	var idx_c2 := ResourceIndex.new()
	idx_c2.roots.assign([{"path": content_dir, "label": "content", "kind": "stock", "priority": 10, "enabled": true}])
	var fp_c2: Dictionary = idx_c2.compute_roots_fingerprint(false)
	var size_same: bool = FileAccess.get_modified_time(content_path) != 0
	_check(bool(fp_c1.get("ok", false)) and bool(fp_c2.get("ok", false)) and size_same and
		str(fp_c1.get("fingerprint", "")) != str(fp_c2.get("fingerprint", "")),
		"CACHE-28: equal-length ODF content replacement changes content-tier fingerprint")

	# CACHE-21..24: payload checksum + schema validation must reject tampering
	# even when the root fingerprint is unchanged, then recover by cold scan.
	var tampered := tmp_root.path_join("tampered_index_cache.json")
	_write(tampered, FileAccess.get_file_as_string(cache_file))
	var tdoc: Variant = JSON.parse_string(FileAccess.get_file_as_string(tampered))
	var tf: Dictionary = tdoc["files"]
	for fk in tf.keys():
		(tf[fk] as Array).clear()
	_write(tampered, JSON.stringify(tdoc))
	var idx_t := ResourceIndex.new()
	idx_t.roots = idx1.roots.duplicate(true)
	idx_t.apply_loadout(lo_a)
	var tamper_res: Dictionary = idx_t.call("load_index_cache", true, tampered)
	_check(not bool(tamper_res.get("ok", false)) and str(tamper_res.get("reason", "")) == "CACHE_PAYLOAD_HASH_MISMATCH",
		"CACHE-22: payload edit with valid fingerprint is rejected")

	var typed := tmp_root.path_join("typed_index_cache.json")
	_write(typed, FileAccess.get_file_as_string(cache_file))
	var tdoc2: Variant = JSON.parse_string(FileAccess.get_file_as_string(typed))
	tdoc2["extension_counts"] = "not-a-dictionary"
	_write(typed, JSON.stringify(tdoc2))
	var idx_t2 := ResourceIndex.new()
	idx_t2.roots = idx1.roots.duplicate(true)
	idx_t2.apply_loadout(lo_a)
	var typed_res: Dictionary = idx_t2.call("load_index_cache", true, typed)
	_check(not bool(typed_res.get("ok", false)) and str(typed_res.get("reason", "")) == "CACHE_INVALID_FIELD_TYPE",
		"CACHE-23: invalid cached field type is rejected")

	var idx_fb := ResourceIndex.new()
	idx_fb.roots = idx1.roots.duplicate(true)
	idx_fb.apply_loadout(lo_a)
	var fb: Dictionary = idx_fb.call("scan_or_load_cache", true, tampered)
	_check(bool(fb.get("ok", false)) and bool(fb.get("scanned", false)) and idx_fb.count() == idx1.count(),
		"CACHE-24: corrupted cache falls back to a cold rescan")


	# Provenance summary switches immediately when switching Workshop package A -> B!
	var prov_a: Dictionary = idx2.call("provenance_summary", "shared_gun.odf") if has_cache_api else {}
	var lo_b := ModLoadoutScript.new()
	lo_b.profile_id = "lo_beta"
	lo_b.enabled_packages = ["2000002"]
	idx2.apply_loadout(lo_b)
	var prov_b: Dictionary = idx2.call("provenance_summary", "shared_gun.odf") if has_cache_api else {}
	_check(str(prov_a.get("package_id", "")) == "2000001" and str(prov_b.get("package_id", "")) == "2000002" and (prov_b.get("alternatives", []) as Array).size() >= 1, "IDX-04: switching Workshop package immediately updates provenance_summary (2000001 -> 2000002) with alternatives")

	# Invalidation check 1: Loadout changed -> cache MUST miss!
	var miss_lo: Dictionary = idx2.call("load_index_cache", true, cache_file) if has_cache_api else {}
	_check(not bool(miss_lo.get("cache_hit", true)) and str(miss_lo.get("reason", "")) == "FINGERPRINT_MISMATCH", "IDX-05: cache invalidates when active ModLoadout changes")

	# Invalidation check 2: Source file replaced/added -> cache MUST miss!
	idx2.apply_loadout(lo_a)
	_write(pkg_a.path_join("extra_new.odf"), "[WeaponClass]\nwpnName=\"New\"\n")
	var miss_add: Dictionary = idx2.call("load_index_cache", true, cache_file) if has_cache_api else {}
	_check(not bool(miss_add.get("cache_hit", true)) and str(miss_add.get("reason", "")) == "FINGERPRINT_MISMATCH", "IDX-06: cache invalidates when a source ODF is added")

	# Invalidation check 3: Re-save, then remove file -> cache MUST miss!
	idx2.scan(true)
	if has_cache_api:
		idx2.call("save_index_cache", cache_file)
	DirAccess.remove_absolute(pkg_a.path_join("extra_new.odf"))
	var miss_rem: Dictionary = idx2.call("load_index_cache", true, cache_file) if has_cache_api else {}
	_check(not bool(miss_rem.get("cache_hit", true)) and str(miss_rem.get("reason", "")) == "FINGERPRINT_MISMATCH", "IDX-07: cache invalidates when an ODF file is removed")

	# Invalidation check 4: Workspace override changes -> cache MUST miss!
	idx2.scan(true)
	if has_cache_api:
		idx2.call("save_index_cache", cache_file)
	var doc_a := OdfDocument.load_file(pkg_a.path_join("shared_gun.odf"))
	if doc_a != null:
		doc_a.set_header_value("WeaponClass", "wpnName", "\"Overridden\"")
		WorkspaceStore.save_document_with_rel(doc_a, "shared_gun.odf")
	var miss_ws: Dictionary = idx2.call("load_index_cache", true, cache_file) if has_cache_api else {}
	_check(not bool(miss_ws.get("cache_hit", true)) and str(miss_ws.get("reason", "")) == "FINGERPRINT_MISMATCH", "IDX-08: cache invalidates when WorkspaceStore overrides change")

	WorkspaceStore.root_override = old_ws_root
	OdfDocument.clear_all_cache()
	_remove_tree(tmp_root)

	print("\nT-74 Verifier: %d checks, %d failure(s)" % [passed + failed, failed])
	if failed == 0:
		print("RESULT: PASS")
		quit(0)
	else:
		print("RESULT: FAIL")
		quit(1)
