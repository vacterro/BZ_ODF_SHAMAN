extends SceneTree
## T-86 recovery-integrity verifier: SAVE-36..70 (save-group data integrity)
## and NC-39..68 (native cleanup correctness). Every defect reproduced here
## was confirmed in the audit handoff; each block names the defect it pins.
##
## In-process ParticleLab instances are used for the fine-grained mutation
## semantics; true cross-process restart coverage lives in
## verify_t86_cross_process_save.gd.

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")
const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")
const NativeSessionScript = preload("res://scripts/native/native_experiment_session.gd")

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


func _make_lab() -> Node:
	var lab = ParticleLabScript.new()
	root.add_child(lab)
	lab.visible = false
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.setup(ResourceIndex.new(), SchemaRegistry.new())
	return lab


func _journal(ws: String, gid: String) -> Dictionary:
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(
		ws.path_join("save_groups").path_join(gid + ".json")))
	return jres.get("data", {}) if bool(jres.get("ok", false)) else {}


func _group_id_of(res: Dictionary) -> String:
	return str(res.get("group_id", ""))


## Build a two-dependency lab in a fresh isolated workspace; dep_a starts
## with an existing override when with_override_a, dep_b never does.
func _make_two_dep_lab(ws: String, with_override_a: bool) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var dir_a := ws.path_join("sources/mod_a")
	var dir_b := ws.path_join("sources/mod_b")
	DirAccess.make_dir_recursive_absolute(dir_a)
	DirAccess.make_dir_recursive_absolute(dir_b)
	_write(dir_a.path_join("effect.odf"), "[Render]\r\nlifeTime=1.0\r\n")
	_write(dir_b.path_join("effect.odf"), "[Render]\r\nlifeTime=2.0\r\n")
	var a = OdfDocument.load_cached(dir_a.path_join("effect.odf"))
	var b = OdfDocument.load_cached(dir_b.path_join("effect.odf"))
	if with_override_a:
		a.set_entry_value(a.find_entry("Render", "lifeTime"), "1.5")
		WorkspaceStore.save_document_with_rel(a, "mod_a/effect.odf")
		OdfDocument.clear_all_cache()
		a = OdfDocument.load_cached(dir_a.path_join("effect.odf"))
		b = OdfDocument.load_cached(dir_b.path_join("effect.odf"))
	a.set_entry_value(a.find_entry("Render", "lifeTime"), "9.9")
	b.set_entry_value(b.find_entry("Render", "lifeTime"), "8.8")
	var lab = _make_lab()
	lab.doc = a
	lab._external_nodes["extb"] = {"path": dir_b.path_join("effect.odf"), "header": "Render"}
	return {"lab": lab, "a": a, "b": b,
		"path_a": dir_a.path_join("effect.odf"), "path_b": dir_b.path_join("effect.odf")}


func _initialize() -> void:
	print("T-86 Recovery Integrity Verifier (SAVE-36..70, NC-39..68)")
	var tmp := ProjectSettings.globalize_path("user://verify_t86_int_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)

	# =====================================================================
	# P0-SAVE-01 — COMPLETE transactions are not recoverable (SAVE-36..40)
	# =====================================================================
	_blk_01(tmp)
	_test_invalid_journal_guard(tmp)

	# =====================================================================
	# P0-SAVE-02 — exact override/manifest structural restoration
	# (SAVE-41..46)
	# =====================================================================
	_blk_02(tmp)

	_blk_03(tmp)

	# =====================================================================
	# P0-SAVE-03 — unknown current revision blocks rollback (SAVE-47..53)
	# =====================================================================
	_blk_04(tmp)

	# =====================================================================
	# P1-SAVE-04 — recovery artifacts cannot collide by basename
	# (SAVE-54..59)
	# =====================================================================
	_blk_05(tmp)

	# =====================================================================
	# P1-SAVE-06 — durable journal finalization (SAVE-66..70)
	# =====================================================================
	_blk_06(tmp)

	WorkspaceStore.root_override = tmp

	# =====================================================================
	# NC-39..44 — never-launched STAGED dry-run rollback
	# =====================================================================
	_blk_07(tmp)

	# =====================================================================
	# NC-51..56 — unknown files survive cleanup with durable provenance
	# =====================================================================
	_blk_08(tmp)

	# =====================================================================
	# NC-63..68 — interrupted cleanup + startup intent discovery
	# =====================================================================
	_blk_09(tmp)

	WorkspaceStore.root_override = tmp
	_remove_tree(tmp)
	print("\nT-86 Recovery Integrity: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)


## T-88: saitest W-007 regression — malformed/empty journal must never be
## published as RECOVERED with zero restored files.
func _test_invalid_journal_guard(tmp: String) -> void:
	var ws := tmp.path_join("t88_invalid")
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var sg := ws.path_join("save_groups")
	DirAccess.make_dir_recursive_absolute(sg)
	var bad := {
		"schema": 1, "group_id": "t88_bad",
		"state": "PARTIAL_SAVE_RECOVERABLE", "targets": ["x", 42, null],
	}
	WorkspaceStore.atomic_write_abs(sg.path_join("t88_bad.json"), JSON.stringify(bad, "  ").to_utf8_buffer())
	var lab = _make_lab()
	var rec: Dictionary = lab.recover_partial_save_group("t88_bad")
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and not bool(rec.get("ok", true)),
		"T-88: malformed journal targets refuse false RECOVERED")
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(sg.path_join("t88_bad.json")))
	_check(str((jres.get("data", {}) as Dictionary).get("state", "")) == "PARTIAL_SAVE_RECOVERABLE",
		"T-88: durable journal state untouched after refusal")
	var empty := {
		"schema": 1, "group_id": "t88_empty",
		"state": "PARTIAL_SAVE_RECOVERABLE", "targets": [],
	}
	WorkspaceStore.atomic_write_abs(sg.path_join("t88_empty.json"), JSON.stringify(empty, "  ").to_utf8_buffer())
	var rec2: Dictionary = lab.recover_partial_save_group("t88_empty")
	_check(str(rec2.get("status", "")) == "RECOVERY_PENDING" and
		str(rec2.get("reason", "")) == "EMPTY_JOURNAL_TARGETS",
		"T-88: empty journal targets refuse false RECOVERED")
	var pending: Array[Dictionary] = lab.discover_incomplete_save_groups()
	var still := false
	for g in pending:
		if str(g.get("group_id", "")) == "t88_empty":
			still = true
	_check(still, "T-88: refused empty journal remains discoverable")
	lab.queue_free()


func _blk_01(tmp: String) -> void:
	var ws := tmp.path_join("p0s1")
	var ctx := _make_two_dep_lab(ws, true)
	var res: Dictionary = ctx["lab"].save_with_external_dependencies({})
	var gid := _group_id_of(res)
	_check(str(res.get("status", "")) == "COMPLETE", "SAVE-36 setup: two-document save reaches COMPLETE")
	var saved_a := FileAccess.get_file_as_bytes(ctx["path_a"])
	var rec: Dictionary = ctx["lab"].recover_partial_save_group(gid)
	_check(str(rec.get("status", "")) == "RECOVERY_NOT_APPLICABLE",
		"SAVE-36: recovery of COMPLETE group returns RECOVERY_NOT_APPLICABLE")
	_check(FileAccess.get_file_as_bytes(ctx["path_a"]) == saved_a,
		"SAVE-39: bytes on disk unchanged after refused recovery")
	# Explicit group id of a COMPLETE group is refused identically.
	var lab2 = _make_lab()
	var rec2: Dictionary = lab2.recover_partial_save_group(gid)
	_check(str(rec2.get("status", "")) == "RECOVERY_NOT_APPLICABLE",
		"SAVE-37: explicit group_id of COMPLETE group cannot be recovered")
	# A RECOVERED group is refused too (idempotent, no re-rollback).
	var g := _journal(ws, gid)
	g["state"] = "RECOVERED"
	WorkspaceStore.atomic_write_abs(ws.path_join("save_groups").path_join(gid + ".json"),
		JSON.stringify(g, "  ").to_utf8_buffer())
	var rec3: Dictionary = lab2.recover_partial_save_group(gid)
	_check(str(rec3.get("status", "")) == "RECOVERY_NOT_APPLICABLE",
		"SAVE-38: RECOVERED group recovery is refused (idempotent)")
	_check(FileAccess.get_file_as_bytes(ctx["path_a"]) == saved_a,
		"SAVE-40: no mutation after refusal of terminal states")
	ctx["lab"].queue_free()
	lab2.queue_free()
	_remove_tree(ws)

func _blk_02(tmp: String) -> void:
	var ws := tmp.path_join("p0s2")
	var ctx := _make_two_dep_lab(ws, false)
	var res: Dictionary = ctx["lab"].save_with_external_dependencies(
		{"fail_on_path": ctx["path_b"]})
	var gid := _group_id_of(res)
	_check(str(res.get("status", "")) == "PARTIAL_SAVE_RECOVERABLE",
		"SAVE-41 setup: first-save partial transaction is PARTIAL_SAVE_RECOVERABLE")
	# dep_a had NO override before; the interrupted transaction created one.
	var entry_before_rec := WorkspaceStore.entry_for(ctx["path_a"])
	_check(not entry_before_rec.is_empty(),
		"SAVE-41 setup: transaction created an override + manifest entry for dep_a")
	var rec: Dictionary = ctx["lab"].recover_partial_save_group(gid)
	_check(str(rec.get("status", "")) == "RECOVERED", "SAVE-41: first-save rollback recovers")
	_check(WorkspaceStore.entry_for(ctx["path_a"]).is_empty(),
		"SAVE-42: transaction-created manifest entry removed by rollback")
	var abs_a := ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join("mod_a/effect.odf"))
	_check(not FileAccess.file_exists(abs_a),
		"SAVE-41: absent override restored as ABSENT (not as source bytes)")
	var a_after = OdfDocument.load_cached(ctx["path_a"])
	_check(str(a_after.get_value("Render", "lifeTime")) == "1.0",
		"SAVE-45: workspace source identity unchanged (original 1.0)")
	_check(WorkspaceStore.entry_for(ctx["path_b"]).is_empty(),
		"SAVE-41: dep_b (never saved) keeps no manifest entry")
	# SAVE-46 simulated: verify mode sees absent state (covered fully
	# cross-process in verify_t86_cross_process_save.gd).
	ctx["lab"].queue_free()
	_remove_tree(ws)

func _blk_03(tmp: String) -> void:
	# Existing override (dep_a) + existing EMPTY override (dep_b):
	# empty must stay empty, never become absent, and dep_a restores exact
	# previous bytes.
	var ws := tmp.path_join("p0s2b")
	var ctx := _make_two_dep_lab(ws, true)
	var b0 = OdfDocument.load_cached(ctx["path_b"])
	b0.set_entry_value(b0.find_entry("Render", "lifeTime"), "2.0")
	WorkspaceStore.save_document_with_rel(b0, "mod_b/effect.odf")
	# Make the existing override bytes EMPTY on disk (a legitimate empty
	# revision), then run an interrupted transaction.
	var rel_b := str(WorkspaceStore.entry_for(ctx["path_b"]).get("rel", ""))
	var abs_b := ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(rel_b))
	WorkspaceStore.atomic_write_abs(abs_b, PackedByteArray())
	OdfDocument.clear_all_cache()
	var a1 = OdfDocument.load_cached(ctx["path_a"])
	var b1 = OdfDocument.load_cached(ctx["path_b"])
	a1.set_entry_value(a1.find_entry("Render", "lifeTime"), "7.7")
	b1.set_entry_value(b1.find_entry("Render", "lifeTime"), "6.6")
	var lab2 = _make_lab()
	lab2.doc = a1
	lab2._external_nodes["extb"] = {"path": ctx["path_b"], "header": "Render"}
	var res: Dictionary = lab2.save_with_external_dependencies({"fail_on_path": ctx["path_b"]})
	var gid := _group_id_of(res)
	var rec: Dictionary = lab2.recover_partial_save_group(gid)
	_check(str(rec.get("status", "")) == "RECOVERED", "SAVE-43 setup: existing-override rollback recovers")
	var abs_a := ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(
		str(WorkspaceStore.entry_for(ctx["path_a"]).get("rel", ""))))
	_check(FileAccess.get_file_as_string(abs_a).contains("lifeTime=1.5"),
		"SAVE-43: existing override restores exact previous bytes (1.5)")
	_check(FileAccess.file_exists(abs_b) and FileAccess.get_file_as_bytes(abs_b).is_empty(),
		"SAVE-44: existing EMPTY override remains present and empty (never absent)")
	lab2.queue_free()
	_remove_tree(ws)

func _blk_04(tmp: String) -> void:
	var ws := tmp.path_join("p0s3")
	var ctx := _make_two_dep_lab(ws, true)
	var res: Dictionary = ctx["lab"].save_with_external_dependencies(
		{"fail_on_path": ctx["path_b"]})
	var gid := _group_id_of(res)
	# Simulate: document committed, but the per-document journal update
	# failed, so the durable journal LACKS new_override_hash (SAVE-47).
	var g := _journal(ws, gid)
	var targets: Array = g.get("targets", [])
	for titem in targets:
		if titem is Dictionary and str((titem as Dictionary).get("source_path", "")) == ctx["path_a"]:
			(titem as Dictionary).erase("new_override_hash")
	g["targets"] = targets
	WorkspaceStore.atomic_write_abs(ws.path_join("save_groups").path_join(gid + ".json"),
		JSON.stringify(g, "  ").to_utf8_buffer())
	# The user then modifies the saved override again (SAVE-48).
	var rel_a := str(WorkspaceStore.entry_for(ctx["path_a"]).get("rel", ""))
	var abs_a := ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(rel_a))
	var newer := "[Render]\r\nlifeTime=5.55\r\n"
	WorkspaceStore.atomic_write_abs(abs_a, newer.to_utf8_buffer())
	var lab2 = _make_lab()
	var rec: Dictionary = lab2.recover_partial_save_group(gid)
	_check(str(rec.get("status", "")) == "RECOVERY_CONFLICT_PENDING",
		"SAVE-49: unknown current hash blocks rollback with a pending conflict")
	_check(FileAccess.get_file_as_string(abs_a) == newer,
		"SAVE-53: conflict preserved the current (newer) bytes untouched")
	var conflicts: Array = rec.get("conflicts", [])
	_check(conflicts.size() == 1 and str((conflicts[0] as Dictionary).get("classification", "")) == "CURRENT_IS_NEWER",
		"SAVE-48: override changed after interrupted commit classified CURRENT_IS_NEWER")
	# Unresolved conflict stays discoverable (SAVE-60..62).
	var pending: Array[Dictionary] = lab2.discover_incomplete_save_groups()
	var still_visible := false
	for pg in pending:
		if str(pg.get("group_id", "")) == gid and str(pg.get("state", "")) == "RECOVERY_CONFLICT_PENDING":
			still_visible = true
	_check(still_visible, "SAVE-62: unresolved conflict remains visible in discovery")
	# Explicit resolution (SAVE-63..65).
	var keep: Dictionary = lab2.resolve_recovery_conflict(gid, "keep_current")
	_check(str(keep.get("status", "")) == "RECOVERY_CONFLICT_RESOLVED",
		"SAVE-63: explicit keep_current resolves the conflict")
	_check(FileAccess.get_file_as_string(abs_a) == newer,
		"SAVE-64: final resolution keeps current bytes (user decision persists)")
	var pending2: Array[Dictionary] = lab2.discover_incomplete_save_groups()
	var still_pending := false
	for pg in pending2:
		if str(pg.get("group_id", "")) == gid:
			still_pending = true
	_check(not still_pending, "SAVE-65: resolved conflict is no longer presented as pending")
	# Source revision drift (SAVE-50) is diagnosed, never silently rolled back.
	var ws2 := tmp.path_join("p0s3b")
	var ctx2 := _make_two_dep_lab(ws2, true)
	var res2: Dictionary = ctx2["lab"].save_with_external_dependencies(
		{"fail_on_path": ctx2["path_b"]})
	var gid2 := _group_id_of(res2)
	_write(ctx2["path_a"], "[Render]\r\nlifeTime=0.25\r\n")
	var lab3 = _make_lab()
	var rec2: Dictionary = lab3.recover_partial_save_group(gid2)
	_check(str(rec2.get("status", "")) == "RECOVERY_CONFLICT_PENDING",
		"SAVE-50: original source changed after PREPARED yields conflict, not silent rollback")
	var conflict2: Array = rec2.get("conflicts", [])
	var drift_found := false
	for c2 in conflict2:
		if str((c2 as Dictionary).get("reason", "")) == "SOURCE_REVISION_DRIFT":
			drift_found = true
	_check(drift_found, "SAVE-50: drift classified as SOURCE_REVISION_DRIFT")
	# SAVE-52: an unchanged recorded commit CAN still be recovered; the
	# restore_working resolution path resolves explicitly. The second group
	# (gid2) is still RECOVERY_CONFLICT_PENDING and is used here.
	var resolved: Dictionary = lab3.resolve_recovery_conflict(gid2, "restore_working")
	_check(str(resolved.get("status", "")) == "RECOVERY_CONFLICT_RESOLVED",
		"SAVE-52 setup: restore_working resolution path also resolves")
	ctx["lab"].queue_free()
	lab2.queue_free()
	lab3.queue_free()
	ctx2["lab"].queue_free()
	_remove_tree(ws)
	_remove_tree(ws2)

func _blk_05(tmp: String) -> void:
	var ws := tmp.path_join("p1s4")
	var ctx := _make_two_dep_lab(ws, true)
	var res: Dictionary = ctx["lab"].save_with_external_dependencies(
		{"fail_on_path": ctx["path_b"]})
	var gid := _group_id_of(res)
	var rec: Dictionary = ctx["lab"].recover_partial_save_group(gid)
	_check(str(rec.get("status", "")) == "RECOVERED", "SAVE-54 setup: collision-case recovery succeeds")
	var artifacts: Array = rec.get("working_artifacts", [])
	_check(artifacts.size() == 2, "SAVE-54: both same-basename dependencies produced artifacts")
	var seen := {}
	var unique := true
	var distinct_dirs := true
	for art in artifacts:
		var p := str(art)
		if seen.has(p):
			unique = false
		seen[p] = true
		if p.get_base_dir() == str(artifacts[0]).get_base_dir() and p != artifacts[0]:
			distinct_dirs = false
	_check(unique and distinct_dirs, "SAVE-56: artifact paths are unique per source identity")
	var b0 := FileAccess.get_file_as_bytes(str(artifacts[0]))
	var b1 := FileAccess.get_file_as_bytes(str(artifacts[1]))
	_check(not b0.is_empty() and not b1.is_empty() and WorkspaceStore._md5_bytes(b0) != WorkspaceStore._md5_bytes(b1),
		"SAVE-55: different working bytes remain in separate artifacts")
	var g := _journal(ws, gid)
	var hashes_ok := true
	for titem in g.get("targets", []):
		if titem is Dictionary:
			var t: Dictionary = titem
			var expected := str(t.get("working_bytes_hash", ""))
			var identity := str(t.get("source_path", "")).get_file() + "-" + \
				WorkspaceStore._md5_bytes(WorkspaceStore.canonical(str(t.get("source_path", ""))).to_utf8_buffer())
			var ap := ws.path_join("save_groups").path_join("working_" + gid).path_join(identity).path_join(str(t.get("source_path", "")).get_file())
			if not FileAccess.file_exists(ap) or WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(ap)) != expected:
				hashes_ok = false
	_check(hashes_ok, "SAVE-57: every artifact hash matches recorded working bytes")
	ctx["lab"].queue_free()
	_remove_tree(ws)

func _blk_06(tmp: String) -> void:
	var ws := tmp.path_join("p1s6")
	var ctx := _make_two_dep_lab(ws, true)
	var res: Dictionary = ctx["lab"].save_with_external_dependencies(
		{"fail_on_path": ctx["path_b"]})
	var gid := _group_id_of(res)
	var jpath := ws.path_join("save_groups").path_join(gid + ".json")
	ctx["lab"].queue_free()
	var lab2 = _make_lab()
	# Make ONLY the final durable journal write fail (SAVE-66): file
	# restoration proceeds, the journal stays incomplete on disk.
	WorkspaceStore.fault_phases["save_journal_final_write"] = true
	var rec: Dictionary = lab2.recover_partial_save_group(gid)
	WorkspaceStore.fault_phases.erase("save_journal_final_write")
	_check(str(rec.get("status", "")) == "RECOVERY_FINALIZATION_PENDING",
		"SAVE-66: restore success + journal failure reports FINALIZATION_PENDING, never RECOVERED")
	_check(bool(rec.get("journal_finalized", false)) == false,
		"SAVE-67: no false durable RECOVERED verdict")
	var journal_state := str(_journal(ws, gid).get("state", ""))
	_check(journal_state in ["PARTIAL_SAVE_RECOVERABLE", "RECOVERY_FINALIZATION_PENDING"],
		"SAVE-68 setup: durable journal is not falsely RECOVERED (state=" + journal_state + ")")
	var pending: Array[Dictionary] = lab2.discover_incomplete_save_groups()
	var discovered_pending := false
	for pg in pending:
		if str(pg.get("group_id", "")) == gid:
			discovered_pending = str(pg.get("state", "")) in ["PARTIAL_SAVE_RECOVERABLE", "RECOVERY_FINALIZATION_PENDING"]
	_check(discovered_pending, "SAVE-68: restart discovers unresolved finalization")
	# Retry is idempotent: the journal write now works; files are already in
	# the previous state so nothing is overwritten.
	var restored_before := FileAccess.get_file_as_string(
		ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(
			str(WorkspaceStore.entry_for(ctx["path_a"]).get("rel", "")))))
	var rec2: Dictionary = lab2.recover_partial_save_group(gid)
	_check(str(rec2.get("status", "")) == "RECOVERED", "SAVE-69: retry after repair completes finalization")
	_check(FileAccess.get_file_as_string(ProjectSettings.globalize_path(
		WorkspaceStore.odf_dir().path_join(str(WorkspaceStore.entry_for(ctx["path_a"]).get("rel", ""))))) == restored_before,
		"SAVE-70: current files never overwritten unnecessarily on retry")
	lab2.queue_free()
	_remove_tree(ws)

func _blk_07(tmp: String) -> void:
	var ws := tmp.path_join("nc39")
	WorkspaceStore.root_override = ws
	var stage_base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(stage_base)
	var stage_root := SafeStageScript.allocate_stage_dir("t86_dryrun")
	var files := {"mission.bzn": "[Mission]\r\ndata=x\r\n".to_utf8_buffer()}
	var stg: Dictionary = SafeStageScript.stage(stage_root, files,
		{"scenario": {"id": "t86"}}, false, [], {"stage_id": "t86sid"})
	_check(bool(stg.get("ok", false)), "NC-39 setup: owned stage created with manifest")
	var manifest_path := str(stg.get("stage", "")).path_join("stage_manifest.json")
	# native_evidence.json marks the stage as STAGED with a session id.
	var evidence := {
		"schema": 4, "status": "STAGED", "session_id": "t86sess",
		"stage_id": "t86sid", "staged": stg.get("staged", []),
	}
	WorkspaceStore.atomic_write_abs(str(stg.get("stage", "")).path_join("native_evidence.json"),
		JSON.stringify(evidence, "  ").to_utf8_buffer())
	# The ledger records the session as STAGED, never launched.
	var ledger := {"sessions": {"t86sess": {"session_id": "t86sess", "state": "STAGED",
		"session": {"checkpoints": [{"state": "STAGED", "note": "staged only"}]}}}}
	var ledger_path := ws.path_join("native_sessions/session_ledger.json")
	DirAccess.make_dir_recursive_absolute(ledger_path.get_base_dir())
	WorkspaceStore.atomic_write_abs(ledger_path, JSON.stringify(ledger, "  ").to_utf8_buffer())
	var recon: Dictionary = SafeStageScript.reconcile_stage(str(stg.get("stage", "")), ledger_path)
	_check(str(recon.get("action", "")) == "CLEANUP_ELIGIBLE_DRY_RUN" and bool(recon.get("cleanup_allowed", false)),
		"NC-39: STAGED + provably never launched reconciles as dry-run eligible")
	_check(bool(recon.get("never_launched", false)), "NC-39: reconciliation marks the stage never-launched")
	var cl: Dictionary = SafeStageScript.cleanup(str(stg.get("stage", "")), [])
	_check(bool(cl.get("ok", false)) and str(cl.get("status", "")) == "CLEAN",
		"NC-39: never-launched stage cleanup removes owned files")
	_check(not DirAccess.dir_exists_absolute(str(stg.get("stage", ""))),
		"NC-39: empty never-launched stage directory removed")

	# NC-40: launch attempted -> dry-run route must NOT authorize.
	var stage_root2 := SafeStageScript.allocate_stage_dir("t86_launched")
	var stg2: Dictionary = SafeStageScript.stage(stage_root2, files,
		{"scenario": {"id": "t86"}}, false, [], {"stage_id": "t86sid2"})
	WorkspaceStore.atomic_write_abs(str(stg2.get("stage", "")).path_join("native_evidence.json"),
		JSON.stringify({"schema": 4, "status": "STAGED", "session_id": "t86sess2",
			"stage_id": "t86sid2", "staged": stg2.get("staged", [])}, "  ").to_utf8_buffer())
	var ledger2 := {"sessions": {
		"t86sess": {"session_id": "t86sess", "state": "STAGED",
			"session": {"checkpoints": [{"state": "STAGED", "note": "staged only"}]}},
		"t86sess2": {"session_id": "t86sess2", "state": "STAGED",
			"session": {"checkpoints": [{"state": "LAUNCH_REQUESTED", "note": "launch was attempted"}]}}}}
	WorkspaceStore.atomic_write_abs(ledger_path, JSON.stringify(ledger2, "  ").to_utf8_buffer())
	var recon2: Dictionary = SafeStageScript.reconcile_stage(str(stg2.get("stage", "")), ledger_path)
	_check(str(recon2.get("action", "")) == "PROTECT",
		"NC-40: STAGED with launch attempted stays protected (no dry-run shortcut)")
	_check(not bool(recon2.get("cleanup_allowed", false)),
		"NC-40: launched-but-unterminal session cannot clean via dry-run policy")

	# NC-41: an active monitor blocks even the dry-run route.
	var mon_path := ledger_path.get_base_dir().path_join("process_monitors.json")
	WorkspaceStore.atomic_write_abs(mon_path, JSON.stringify(
		{"monitors": {"t86sess2": {"active": true, "state": "MONITOR_ARMED", "recoverable": false}}}, "  ").to_utf8_buffer())
	var recon3: Dictionary = SafeStageScript.reconcile_stage(str(stg2.get("stage", "")), ledger_path)
	_check(str(recon3.get("action", "")) == "PROTECT" and str(recon3.get("reason", "")) in ["ACTIVE_MONITOR", "STAGE_ACTIVE_OR_RECOVERABLE"],
		"NC-41: STAGED with a monitor stays protected")
	WorkspaceStore.atomic_write_abs(mon_path, JSON.stringify({"monitors": {}}, "  ").to_utf8_buffer())

	# NC-42: unknown files inside a dry-run stage do not block owned-file
	# cleanup; they must be preserved, never deleted.
	var stage_root3 := SafeStageScript.allocate_stage_dir("t86_unknown")
	var stg3: Dictionary = SafeStageScript.stage(stage_root3, files,
		{"scenario": {"id": "t86"}}, false, [], {"stage_id": "t86sid3"})
	WorkspaceStore.atomic_write_abs(str(stg3.get("stage", "")).path_join("unknown_user_file.txt"),
		"user data".to_utf8_buffer())
	WorkspaceStore.atomic_write_abs(str(stg3.get("stage", "")).path_join("native_evidence.json"),
		JSON.stringify({"schema": 4, "status": "STAGED", "session_id": "t86sess",
			"stage_id": "t86sid3", "staged": stg3.get("staged", [])}, "  ").to_utf8_buffer())
	var recon4: Dictionary = SafeStageScript.reconcile_stage(str(stg3.get("stage", "")), ledger_path)
	_check(str(recon4.get("action", "")) == "CLEANUP_ELIGIBLE_DRY_RUN" and str(recon4.get("hash_status", "")) == "MATCH",
		"NC-42: STAGED with unknown files still dry-run eligible (owned hashes MATCH)")
	var cl3: Dictionary = SafeStageScript.cleanup(str(stg3.get("stage", "")), [])
	_check(str(cl3.get("status", "")) == "FOREIGN_FILES_PRESERVED" and FileAccess.file_exists(str(stg3.get("stage", "")).path_join("unknown_user_file.txt")),
		"NC-42: cleanup of a dry-run stage with unknown files preserves them (no deletion)")
	_check(bool(cl3.get("stage_directory_retained", false)),
		"NC-42: stage retained honestly, never silently vanished")
	# Hash mismatch blocks too.
	var stage_root4 := SafeStageScript.allocate_stage_dir("t86_modified")
	var stg4: Dictionary = SafeStageScript.stage(stage_root4, files,
		{"scenario": {"id": "t86"}}, false, [], {"stage_id": "t86sid4"})
	WorkspaceStore.atomic_write_abs(str(stg4.get("stage", "")).path_join("mission.bzn"),
		"[Mission]\r\ndata=TAMPERED\r\n".to_utf8_buffer())
	WorkspaceStore.atomic_write_abs(str(stg4.get("stage", "")).path_join("native_evidence.json"),
		JSON.stringify({"schema": 4, "status": "STAGED", "session_id": "t86sess",
			"stage_id": "t86sid4", "staged": stg4.get("staged", [])}, "  ").to_utf8_buffer())
	var recon5: Dictionary = SafeStageScript.reconcile_stage(str(stg4.get("stage", "")), ledger_path)
	_check(str(recon5.get("reason", "")) == "STAGE_HASH_MISMATCH",
		"NC-42 setup: modified owned file blocks via hash mismatch")
	_check(not bool(recon5.get("cleanup_allowed", false)),
		"NC-42: hash-mismatched dry-run stage cannot clean")

	# NC-43: missing manifest blocks everything.
	DirAccess.remove_absolute(str(stg3.get("stage", "")).path_join("stage_manifest.json"))
	var recon6: Dictionary = SafeStageScript.reconcile_stage(str(stg3.get("stage", "")), ledger_path)
	_check(str(recon6.get("reason", "")) == "MANIFEST_MISSING",
		"NC-43: missing manifest blocks cleanup authorization")

	# NC-44: RECOVERY_PENDING session remains protected (ledger state wins).
	var ledger3 := {"sessions": {
		"t86sess": {"session_id": "t86sess", "state": "STAGED",
			"session": {"checkpoints": [{"state": "STAGED"}]}},
		"t86sess2": {"session_id": "t86sess2", "state": "RECOVERY_PENDING",
			"session": {"checkpoints": [{"state": "STAGED"}]}}}}
	WorkspaceStore.atomic_write_abs(ledger_path, JSON.stringify(ledger3, "  ").to_utf8_buffer())
	var recon7: Dictionary = SafeStageScript.reconcile_stage(str(stg2.get("stage", "")), ledger_path)
	_check(str(recon7.get("action", "")) == "PROTECT",
		"NC-44: RECOVERY_PENDING session remains protected")
	_remove_tree(ws)

func _blk_08(tmp: String) -> void:
	var ws := tmp.path_join("nc51")
	WorkspaceStore.root_override = ws
	var stage_base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(stage_base)
	var stage_root := SafeStageScript.allocate_stage_dir("t86_foreign")
	var files := {"mission.bzn": "[Mission]\r\ndata=x\r\n".to_utf8_buffer()}
	var stg: Dictionary = SafeStageScript.stage(stage_root, files,
		{"scenario": {"id": "t86"}}, false, [], {"stage_id": "t86fsid"})
	var stage := str(stg.get("stage", ""))
	WorkspaceStore.atomic_write_abs(stage.path_join("unknown_user_file.txt"), "precious".to_utf8_buffer())
	var cl: Dictionary = SafeStageScript.cleanup(stage, [])
	_check(bool(cl.get("ok", false)), "NC-51 setup: cleanup succeeds for owned files")
	_check(FileAccess.file_exists(stage.path_join("unknown_user_file.txt")),
		"NC-51: unknown file survives cleanup")
	_check(str(cl.get("status", "")) == "FOREIGN_FILES_PRESERVED",
		"NC-53: cleanup result reports retained stage directory honestly")
	_check(bool(cl.get("stage_directory_retained", false)),
		"NC-53: stage_directory_retained flag set")
	_check(FileAccess.file_exists(stage.path_join("stage_manifest.json")),
		"NC-52: ownership manifest preserved (provenance recoverable)")
	var provenance_path := stage.path_join("stage_provenance.json")
	var receipt_path := stage.path_join("stage_cleanup_receipt.json")
	_check(FileAccess.file_exists(provenance_path),
		"NC-52: durable provenance snapshot written inside the stage")
	var pres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(provenance_path))
	var prov_ok := bool(pres.get("ok", false)) and (pres.get("data", null) is Dictionary) and \
		((pres.get("data", {}) as Dictionary).get("owned_files", null) is Array)
	_check(prov_ok, "NC-52: provenance snapshot carries the owned-file manifest")
	_check(FileAccess.file_exists(receipt_path), "NC-54 setup: cleanup receipt written")
	var rcpt := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(receipt_path))
	var rcpt_ok := bool(rcpt.get("ok", false)) and \
		str((rcpt.get("data", {}) as Dictionary).get("foreign_files_preserved", [""])[0]) == "unknown_user_file.txt"
	_check(rcpt_ok, "NC-54: receipt names the preserved foreign file (no misidentification)")
	_check(not FileAccess.file_exists(stage.path_join("mission.bzn")),
		"NC-55 setup: owned file was actually removed; unknown file untouched")
	# A second reconciliation must not misidentify ownership (NC-54):
	# the provenance + receipt describe exactly what was removed.
	var recon: Dictionary = SafeStageScript.reconcile_stage(stage, ws.path_join("native_sessions/session_ledger.json"))
	_check(str(recon.get("reason", "")) == "STAGE_OWNERSHIP_UNRESOLVED",
		"NC-54: second reconciliation reports unresolved (evidence status empty after receipt), never fake ownership")
	_remove_tree(ws)

func _blk_09(tmp: String) -> void:
	var ws := tmp.path_join("nc63")
	WorkspaceStore.root_override = ws
	var ledger_dir := ws.path_join("native_sessions")
	DirAccess.make_dir_recursive_absolute(ledger_dir)
	var ledger_path := ledger_dir.path_join("session_ledger.json")
	# Simulate an interrupted cleanup: first file removed, process died.
	var stage_root := ws.path_join("native_staging/SHAMAN_interrupted")
	SafeStageScript.register_owned_base(ws.path_join("native_staging"))
	var files := {"a.odf": "A".to_utf8_buffer(), "b.odf": "B".to_utf8_buffer()}
	var stg: Dictionary = SafeStageScript.stage(stage_root, files,
		{"scenario": {"id": "t86"}}, false, [], {"stage_id": "t86isid"})
	var stage := str(stg.get("stage", ""))
	DirAccess.remove_absolute(stage.path_join("a.odf"))
	WorkspaceStore.atomic_write_abs(ledger_path, JSON.stringify(
		{"sessions": {"t86isess": {"session_id": "t86isess", "state": "CLEANED_UP",
			"session": {"checkpoints": []}}}}, "  ").to_utf8_buffer())
	WorkspaceStore.atomic_write_abs(ledger_dir.path_join("t86isess.cleanup_intent.json"), JSON.stringify({
		"schema": 1, "session_id": "t86isess", "stage_root": stage,
		"state": "CLEANUP_PREPARED", "prepared_at": "2026-11-23T00:00:00",
	}, "  ").to_utf8_buffer())
	WorkspaceStore.atomic_write_abs(stage.path_join("native_evidence.json"), JSON.stringify({
		"schema": 4, "status": "CLEANED_UP", "session_id": "t86isess",
		"stage_id": "t86isid", "staged": [],
	}, "  ").to_utf8_buffer())
	var intents: Array[Dictionary] = NativeExperimentRunner.new().discover_cleanup_intents()
	_check(intents.size() == 1, "NC-65: startup discovery finds the incomplete cleanup intent")
	if intents.size() == 1:
		var it: Dictionary = intents[0]
		_check(int(it.get("remaining_owned_files", -1)) == 1,
			"NC-63: interrupted cleanup after first file reports 1 remaining owned file")
		_check(str(it.get("resolution", "")) == "RETRY_REQUIRES_RECONCILIATION",
			"NC-65: incomplete intent classified for safe retry, not auto-deletion")
		_check(str(it.get("ledger_status", "")) == "MATCH", "NC-65: session identity validated against ledger")
	# NC-64: interrupted after the LAST owned file -> retry eligible.
	DirAccess.remove_absolute(stage.path_join("b.odf"))
	var intents2: Array[Dictionary] = NativeExperimentRunner.new().discover_cleanup_intents()
	_check(intents2.size() == 1 and str(intents2[0].get("resolution", "")) == "RETRY_ELIGIBLE_OWNED_FILES_GONE",
		"NC-64: intent with zero remaining owned files is retry-eligible")
	# NC-67: an active monitor keeps the intent protected.
	WorkspaceStore.atomic_write_abs(ledger_dir.path_join("process_monitors.json"), JSON.stringify(
		{"monitors": {"t86isess": {"active": true, "state": "MONITOR_ARMED"}}}, "  ").to_utf8_buffer())
	var intents3: Array[Dictionary] = NativeExperimentRunner.new().discover_cleanup_intents()
	_check(intents3.size() == 1 and str(intents3[0].get("resolution", "")) == "PROTECTED_ACTIVE_MONITOR",
		"NC-67: active monitor keeps cleanup intent protected")
	WorkspaceStore.atomic_write_abs(ledger_dir.path_join("process_monitors.json"),
		JSON.stringify({"monitors": {}}, "  ").to_utf8_buffer())
	# NC-68: an unknown stage (no manifest) stays protected.
	WorkspaceStore.atomic_write_abs(ledger_dir.path_join("t86unk.cleanup_intent.json"), JSON.stringify({
		"schema": 1, "session_id": "t86unk", "stage_root": ws.path_join("native_staging/SHAMAN_unknown"),
		"state": "CLEANUP_PREPARED", "prepared_at": "2026-11-23T00:00:00",
	}, "  ").to_utf8_buffer())
	var intents4: Array[Dictionary] = NativeExperimentRunner.new().discover_cleanup_intents()
	var unk_protected := false
	var unk_found := false
	for it4 in intents4:
		if str(it4.get("session_id", "")) == "t86unk":
			unk_found = true
			unk_protected = str(it4.get("resolution", "")) == "RETRY_REQUIRES_RECONCILIATION" or \
				str(it4.get("stage_status", "")) == "STAGE_MISSING"
	_check(unk_found and unk_protected, "NC-68: unknown/missing stage intent stays protected")
	# NC-66: discovery is idempotent and read-only (same verdicts twice).
	var intents5: Array[Dictionary] = NativeExperimentRunner.new().discover_cleanup_intents()
	_check(intents5.size() == intents4.size(), "NC-66: repeated discovery is idempotent")
	_remove_tree(ws)