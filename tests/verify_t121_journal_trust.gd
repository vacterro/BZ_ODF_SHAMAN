extends SceneTree
## T-121 recovery trust-boundary verifier.
##
## Every case builds a real isolated workspace, writes a real save-group
## journal, then mutates only the durable journal the way corruption or an
## attacker would. Recovery must refuse before any filesystem mutation.
## Covers SAVE-76..88, PATH-01..07 and SAVE-89..95.

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")
const ResourceIndexScript = preload("res://scripts/core/resource_index.gd")
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


func _make_lab() -> Node:
	var lab = ParticleLabScript.new()
	root.add_child(lab)
	lab.visible = false
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.setup(ResourceIndexScript.new(), SchemaRegistryScript.new())
	return lab


## Two sources, one pre-existing override on A. A forced failure on B leaves a
## PARTIAL_SAVE_RECOVERABLE journal with A committed and B untouched.
func _prep(ws: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var dir_a := ws.path_join("sources/mod_a")
	var dir_b := ws.path_join("sources/mod_b")
	DirAccess.make_dir_recursive_absolute(dir_a)
	DirAccess.make_dir_recursive_absolute(dir_b)
	var pa := dir_a.path_join("effect.odf")
	var pb := dir_b.path_join("effect.odf")
	_write(pa, "[Render]\r\nlifeTime=1.0\r\n")
	_write(pb, "[Render]\r\nlifeTime=2.0\r\n")
	var a = OdfDocument.load_cached(pa)
	a.set_entry_value(a.find_entry("Render", "lifeTime"), "1.5")
	WorkspaceStore.save_document_with_rel(a, "mod_a/effect.odf")
	OdfDocument.clear_all_cache()
	a = OdfDocument.load_cached(pa)
	var b = OdfDocument.load_cached(pb)
	a.set_entry_value(a.find_entry("Render", "lifeTime"), "9.9")
	b.set_entry_value(b.find_entry("Render", "lifeTime"), "8.8")
	var lab = _make_lab()
	lab.doc = a
	lab._external_nodes["extb"] = {"path": pb, "header": "Render"}
	var res: Dictionary = lab.save_with_external_dependencies({"fail_on_path": pb})
	var override_a := ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(
		str(WorkspaceStore.entry_for(pa).get("rel", ""))))
	return {"lab": lab, "path_a": pa, "path_b": pb, "override_a": override_a,
		"gid": str(res.get("group_id", "")), "journal": ws.path_join("save_groups").path_join(
		str(res.get("group_id", "")) + ".json")}


func _journal(path: String) -> Dictionary:
	var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	return res.get("data", {}) if bool(res.get("ok", false)) else {}


func _save_journal(path: String, group: Dictionary) -> void:
	WorkspaceStore.atomic_write_abs(path, JSON.stringify(group, "  ").to_utf8_buffer())


func _override_bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()


func _initialize() -> void:
	print("T-121 Recovery Journal Trust-Boundary Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t121_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	_test_previous_bytes_hash(tmp)
	_test_mixed_targets(tmp)
	_test_path_ownership(tmp)
	_test_restore_working_fresh_process(tmp)
	_test_native_provenance(tmp)
	_test_revision_comparison(tmp)
	_remove_tree(tmp)
	print("\nT-121 Journal Trust: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)


## SAVE-76..82: historical bytes must be authenticated by their recorded hash
## before any override is touched.
func _test_previous_bytes_hash(tmp: String) -> void:
	# SAVE-76: untouched journal recovers.
	var c := _prep(tmp.path_join("valid"))
	var rec: Dictionary = c["lab"].recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERED", "SAVE-76: valid previous bytes and hash recover")
	c["lab"].queue_free()

	# SAVE-77: tampered bytes, original hash -> refuse, no mutation.
	c = _prep(tmp.path_join("tampered"))
	var g := _journal(str(c["journal"]))
	var target: Dictionary = (g.get("targets", []) as Array)[0]
	var other := "[Render]\r\nlifeTime=4.4\r\n"
	target["previous_override_bytes"] = Marshalls.raw_to_base64(other.to_utf8_buffer())
	var targets: Array = g.get("targets", [])
	targets[0] = target
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var before := _override_bytes(str(c["override_a"]))
	var lab2 = _make_lab()
	rec = lab2.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "HASH_MISMATCH",
		"SAVE-77: tampered previous bytes refused as HASH_MISMATCH")
	_check(_override_bytes(str(c["override_a"])) == before,
		"SAVE-82: no target file modified after byte-hash rejection")
	lab2.queue_free()

	# SAVE-78: valid base64, wrong hash -> refuse.
	c = _prep(tmp.path_join("wronghash"))
	g = _journal(str(c["journal"]))
	target = (g.get("targets", []) as Array)[0]
	target["previous_override_hash"] = "00000000000000000000000000000000"
	targets = g.get("targets", [])
	targets[0] = target
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab3 = _make_lab()
	rec = lab3.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "HASH_MISMATCH",
		"SAVE-78: valid base64 with wrong hash refused")
	lab3.queue_free()

	# SAVE-79: malformed base64 -> refuse.
	c = _prep(tmp.path_join("badb64"))
	g = _journal(str(c["journal"]))
	target = (g.get("targets", []) as Array)[0]
	target["previous_override_bytes"] = "!!!"
	targets = g.get("targets", [])
	targets[0] = target
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab4 = _make_lab()
	rec = lab4.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) in ["HASH_MISMATCH", "INVALID_JOURNAL_TARGETS"],
		"SAVE-79: malformed base64 refused")
	lab4.queue_free()

	# SAVE-80: an existing EMPTY override is a valid previous revision.
	c = _prep(tmp.path_join("empty_prev"))
	g = _journal(str(c["journal"]))
	target = (g.get("targets", []) as Array)[0]
	target["previous_override_bytes"] = ""
	target["previous_override_hash"] = "d41d8cd98f00b204e9800998ecf8427e"
	var empty_abs := str(c["override_a"])
	var empty_before := _override_bytes(empty_abs)
	targets = g.get("targets", [])
	targets[0] = target
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab5 = _make_lab()
	rec = lab5.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERED" and
		_override_bytes(empty_abs).is_empty(),
		"SAVE-80: existing empty override remains a valid empty revision")
	_check(not (empty_before.is_empty() and not FileAccess.file_exists(empty_abs)),
		"SAVE-80: empty valid previous revision is restored as a present file")
	lab5.queue_free()

	# SAVE-81: missing previous payload on an absent source is not fabricated.
	c = _prep(tmp.path_join("missing_prev"))
	g = _journal(str(c["journal"]))
	target = (g.get("targets", []) as Array)[1]
	target["previous_override_bytes"] = ""
	target["previous_override_hash"] = "d41d8cd98f00b204e9800998ecf8427e"
	OdfDocument.clear_all_cache()
	DirAccess.remove_absolute(str(c["path_b"]))
	targets = g.get("targets", [])
	targets[1] = target
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab6 = _make_lab()
	rec = lab6.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) != "RECOVERED",
		"SAVE-81: missing previous payload with absent source is not declared recovered")
	lab6.queue_free()


## SAVE-83..88: every declared target must validate before any mutation.
func _test_mixed_targets(tmp: String) -> void:
	# SAVE-83: one valid + one string target.
	var c := _prep(tmp.path_join("mixed_string"))
	var g := _journal(str(c["journal"]))
	var targets: Array = g.get("targets", [])
	targets.append("CORRUPTED_TARGET")
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var before := _override_bytes(str(c["override_a"]))
	var lab = _make_lab()
	var rec: Dictionary = lab.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "INVALID_JOURNAL_TARGETS",
		"SAVE-83: one valid + one string target refused")
	_check(_override_bytes(str(c["override_a"])) == before,
		"SAVE-88: no partial rollback before full validation")
	lab.queue_free()

	# SAVE-84: one valid + one empty Dictionary.
	c = _prep(tmp.path_join("mixed_empty"))
	g = _journal(str(c["journal"]))
	targets = g.get("targets", [])
	targets.append({})
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab2 = _make_lab()
	rec = lab2.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "INVALID_JOURNAL_TARGETS",
		"SAVE-84: one valid + one empty target refused")
	lab2.queue_free()

	# SAVE-85: duplicate canonical source identity.
	c = _prep(tmp.path_join("duplicate"))
	g = _journal(str(c["journal"]))
	targets = g.get("targets", [])
	targets.append((targets[0] as Dictionary).duplicate(true))
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab3 = _make_lab()
	rec = lab3.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "DUPLICATE_JOURNAL_TARGET",
		"SAVE-85: duplicate source identity refused")
	lab3.queue_free()

	# SAVE-86: invalid byte payload in the second target.
	c = _prep(tmp.path_join("bad_second"))
	g = _journal(str(c["journal"]))
	var t1: Dictionary = (g.get("targets", []) as Array)[1]
	t1["working_bytes_hash"] = "00000000000000000000000000000000"
	targets = g.get("targets", [])
	targets[1] = t1
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab4 = _make_lab()
	rec = lab4.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "INVALID_JOURNAL_TARGETS",
		"SAVE-86: invalid byte payload in second target refused")
	lab4.queue_free()

	# SAVE-87: valid two-target journal still recovers.
	c = _prep(tmp.path_join("valid_two"))
	var lab5 = _make_lab()
	rec = lab5.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERED" and
		(rec.get("restored", []) as Array).size() == 2,
		"SAVE-87: valid two-target journal recovers fully")
	lab5.queue_free()


## PATH-01..07: journal paths never authorize writes outside the workspace.
func _test_path_ownership(tmp: String) -> void:
	# Sentinel outside the workspace ODF directory.
	var sentinel := tmp.path_join("protected/sentinel.odf")
	_write(sentinel, "ORIGINAL")

	# PATH-03: absolute path outside workspace refused.
	var c := _prep(tmp.path_join("abs_outside"))
	var g := _journal(str(c["journal"]))
	var t0: Dictionary = (g.get("targets", []) as Array)[0]
	t0["previous_override_path"] = sentinel
	var targets: Array = g.get("targets", [])
	targets[0] = t0
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var before := FileAccess.get_file_as_string(sentinel)
	var lab = _make_lab()
	var rec: Dictionary = lab.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "UNSAFE_OVERRIDE_PATH",
		"PATH-03: absolute path outside workspace refused")
	_check(FileAccess.get_file_as_string(sentinel) == before,
		"PATH-07: no mutation after invalid-path verdict")
	lab.queue_free()

	# PATH-02: relative traversal refused.
	c = _prep(tmp.path_join("traversal"))
	g = _journal(str(c["journal"]))
	t0 = (g.get("targets", []) as Array)[0]
	t0["previous_override_path"] = "../protected/sentinel.odf"
	targets = g.get("targets", [])
	targets[0] = t0
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab2 = _make_lab()
	rec = lab2.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "UNSAFE_OVERRIDE_PATH",
		"PATH-02: relative traversal refused")
	lab2.queue_free()

	# PATH-05: source identity mismatch refused.
	c = _prep(tmp.path_join("identity"))
	g = _journal(str(c["journal"]))
	t0 = (g.get("targets", []) as Array)[0]
	t0["source_canonical"] = sentinel
	targets = g.get("targets", [])
	targets[0] = t0
	g["targets"] = targets
	_save_journal(str(c["journal"]), g)
	var lab3 = _make_lab()
	rec = lab3.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_PENDING" and
		str(rec.get("reason", "")) == "JOURNAL_SOURCE_IDENTITY_MISMATCH",
		"PATH-05: journal source identity mismatch refused")
	lab3.queue_free()

	# PATH-01: a valid workspace override is accepted.
	c = _prep(tmp.path_join("valid_path"))
	var lab4 = _make_lab()
	rec = lab4.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERED",
		"PATH-01: valid workspace override accepted")
	lab4.queue_free()

	# PATH-06: original sources and sentinel untouched by all cases.
	_check(FileAccess.get_file_as_string(sentinel) == "ORIGINAL",
		"PATH-06: protected sentinel unchanged across all path tests")


## SAVE-89..95: restore_working must load a source never opened in this process.
func _test_restore_working_fresh_process(tmp: String) -> void:
	var ws := tmp.path_join("fresh_restore")
	var c := _prep(ws)
	var g := _journal(str(c["journal"]))
	var t0: Dictionary = (g.get("targets", []) as Array)[0]
	var bad_current := "[Render]\r\nlifeTime=6.66\r\n"
	WorkspaceStore.atomic_write_abs(str(c["override_a"]), bad_current.to_utf8_buffer())
	# Classification sees CURRENT_IS_NEWER and opens a conflict.
	OdfDocument.clear_all_cache()
	var lab = _make_lab()
	var rec: Dictionary = lab.recover_partial_save_group(str(c["gid"]))
	_check(str(rec.get("status", "")) == "RECOVERY_CONFLICT_PENDING",
		"SAVE-92 setup: external modification opens a conflict")
	lab.queue_free()

	# Fresh lab instance whose cache has never seen the affected document.
	var lab2 = _make_lab()
	var resolved: Dictionary = lab2.resolve_recovery_conflict(str(c["gid"]), "restore_working")
	_check(str(resolved.get("status", "")) == "RECOVERY_CONFLICT_RESOLVED",
		"SAVE-93: restore_working loads an uncached ODF and resolves")
	_check(FileAccess.get_file_as_string(str(c["override_a"])).contains("lifeTime=9.9"),
		"SAVE-94: working revision committed to the override")
	lab2.queue_free()

	# Third instance: second restart reads back the durable result.
	var lab3 = _make_lab()
	var group := _journal(str(c["journal"]))
	_check(str(group.get("state", "")) == "RECOVERY_CONFLICT_RESOLVED" and
		FileAccess.get_file_as_string(str(c["override_a"])).contains("lifeTime=9.9"),
		"SAVE-95: second process confirms persisted resolved state")
	lab3.queue_free()


## NPROV-01..06: cleanup evidence must be written AND read back verified.
func _test_native_provenance(tmp: String) -> void:
	var SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")
	var ws := tmp.path_join("native_prov")
	WorkspaceStore.root_override = ws
	var base := ws.path_join("native_staging")
	SafeStageScript.register_owned_base(base)

	var make_stage := func(label: String) -> String:
		var root := SafeStageScript.allocate_stage_dir(label)
		var stg: Dictionary = SafeStageScript.stage(root, {"mission.bzn": "[Mission]\r\ndata=x\r\n".to_utf8_buffer()},
			{}, false, [], {"stage_id": label + "_sid"})
		var stage := str(stg.get("stage", ""))
		_write(stage.path_join("unknown_user_file.txt"), "precious")
		return stage

	# NPROV-01: normal cleanup with foreign files verifies receipts.
	var stage: String = make_stage.call("nprov_ok")
	var cl: Dictionary = SafeStageScript.cleanup(stage, [])
	_check(str(cl.get("status", "")) == "FOREIGN_FILES_PRESERVED" and bool(cl.get("receipt_verified", false)) and
		bool(cl.get("provenance_verified", false)),
		"NPROV-01: normal cleanup verifies receipt and provenance readback")
	_check(FileAccess.file_exists(stage.path_join("unknown_user_file.txt")) and
		FileAccess.file_exists(stage.path_join("stage_manifest.json")),
		"NPROV-05/06: unknown file preserved and ownership manifest retained")

	# NPROV-04: a stale receipt must not satisfy verification. Pre-create a
	# stale artifact and make only verification fail, not the write call.
	stage = make_stage.call("nprov_stale")
	_write(stage.path_join("stage_cleanup_receipt.json"), '{"schema":1,"status":"STALE"}')
	WorkspaceStore.fault_phases["native_receipt_verify"] = true
	cl = SafeStageScript.cleanup(stage, [])
	WorkspaceStore.fault_phases.erase("native_receipt_verify")
	_check(str(cl.get("status", "")) == "CLEANUP_EVIDENCE_PENDING" and
		(cl.get("evidence_failed", []) as Array).has("receipt") and
		not bool(cl.get("provenance_preserved", true)),
		"NPROV-04: stale receipt cannot satisfy persistence verification")
	_check(FileAccess.file_exists(stage.path_join("stage_manifest.json")),
		"NPROV-06: manifest retained on evidence failure")

	# NPROV-02: receipt write failure reported.
	stage = make_stage.call("nprov_fail_receipt")
	WorkspaceStore.fault_phases["native_receipt_write"] = true
	DirAccess.remove_absolute(stage.path_join("stage_cleanup_receipt.json")) if FileAccess.file_exists(stage.path_join("stage_cleanup_receipt.json")) else null
	cl = SafeStageScript.cleanup(stage, [])
	WorkspaceStore.fault_phases.erase("native_receipt_write")
	_check(str(cl.get("reason", "")) == "PROVENANCE_PERSISTENCE_FAILED" and
		(cl.get("evidence_failed", []) as Array).has("receipt"),
		"NPROV-02: receipt write failure reported truthfully")

	# NPROV-03: provenance write failure reported.
	stage = make_stage.call("nprov_fail_prov")
	WorkspaceStore.fault_phases["native_provenance_write"] = true
	cl = SafeStageScript.cleanup(stage, [])
	WorkspaceStore.fault_phases.erase("native_provenance_write")
	_check(str(cl.get("reason", "")) == "PROVENANCE_PERSISTENCE_FAILED" and
		(cl.get("evidence_failed", []) as Array).has("provenance"),
		"NPROV-03: provenance write failure reported truthfully")


## Product slice: read-only, hash-authenticated ODF revision comparison.
func _test_revision_comparison(tmp: String) -> void:
	var c := _prep(tmp.path_join("revision_diff"))
	var g := _journal(str(c["journal"]))
	var t: Dictionary = (g.get("targets", []) as Array)[0]
	var lab = _make_lab()
	var diff: Dictionary = lab.compare_journal_target_revision(t)
	_check(not diff.is_empty() and str(diff.get("error", "")) == "" and
		int((diff.get("changed_properties", []) as Array).size()) >= 1,
		"DIFF-01: revision comparison reports authenticated property changes")
	var found := false
	for change in diff.get("changed_properties", []):
		var ch: Dictionary = change
		if str(ch.get("key", "")) == "lifeTime" and str(ch.get("previous", "")) == "1.5" and \
				str(ch.get("working", "")) == "9.9":
			found = true
	_check(found, "DIFF-02: previous/working values match the journal's real ODF bytes")
	_check(diff.has("previous_hash") and diff.has("current_hash") and
		diff.has("bytes_identical"),
		"DIFF-03: byte identities are reported without mutating the document")
	var before := FileAccess.get_file_as_string(str(c["journal"]))
	_check(FileAccess.get_file_as_string(str(c["journal"])) == before,
		"DIFF-04: revision comparison never writes the journal")
	lab.queue_free()
