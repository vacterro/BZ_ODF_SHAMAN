extends SceneTree
## T-86 disposable worker for TRUE cross-process save-group restart tests.
## Invoked by tests/verify_t86_cross_process_save.gd via OS.create_process()
## and forcibly killed via OS.kill() mid-save; fresh OS processes then
## discover and recover the durable journal. Every mode prints one
## WORKER_JSON: line so the parent can assert on structured output.

const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")
const ResourceIndexScript = preload("res://scripts/core/resource_index.gd")
const SchemaRegistryScript = preload("res://scripts/core/schema_registry.gd")


func _emit(payload: Dictionary) -> void:
	print("WORKER_JSON:" + JSON.stringify(payload))


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _make_lab() -> Node:
	var lab = ParticleLabScript.new()
	root.add_child(lab)
	lab.visible = false
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.setup(ResourceIndexScript.new(), SchemaRegistryScript.new())
	return lab


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("save_group_worker: missing args")
		quit(2)
		return
	var mode := str(args[0])
	var ws_root := str(args[1])
	WorkspaceStore.root_override = ws_root
	var parent_dir := ws_root.path_join("sources")

	if mode == "prepare":
		# Process A, phase 1: create isolated sources and the initial workspace
		# state (one dependency already has an override; the other does not).
		_write(parent_dir.path_join("mod_a/effect.odf"), "[Render]\r\nlifeTime=1.0\r\n")
		_write(parent_dir.path_join("mod_b/effect.odf"), "[Render]\r\nlifeTime=2.0\r\n")
		var first = OdfDocument.load_cached(parent_dir.path_join("mod_a/effect.odf"))
		first.set_entry_value(first.find_entry("Render", "lifeTime"), "1.5")
		var sv := WorkspaceStore.save_document_with_rel(first, "mod_a/effect.odf")
		OdfDocument.clear_all_cache()
		_emit({"mode": mode, "ok": bool(sv.get("ok", false)),
			"rel": str(WorkspaceStore.entry_for(parent_dir.path_join("mod_a/effect.odf")).get("rel", ""))})
		quit(0 if bool(sv.get("ok", false)) else 1)
		return

	if mode == "partial_save":
		# Process A, phase 2: modify both documents, start Save Dependencies
		# with an injected failure on the second document, then hang forever so
		# the parent can kill the OS process mid-flight. The journal on disk is
		# the only durable record of the interrupted transaction.
		if args.size() < 4:
			printerr("save_group_worker: partial_save needs marker + fail_on args")
			quit(2)
			return
		var marker := str(args[2])
		var fail_on := str(args[3])
		var a = OdfDocument.load_cached(parent_dir.path_join("mod_a/effect.odf"))
		var b = OdfDocument.load_cached(parent_dir.path_join("mod_b/effect.odf"))
		a.set_entry_value(a.find_entry("Render", "lifeTime"), "9.9")
		b.set_entry_value(b.find_entry("Render", "lifeTime"), "8.8")
		var lab = _make_lab()
		lab.doc = a
		lab._external_nodes["extb"] = {"path": parent_dir.path_join("mod_b/effect.odf"), "header": "Render"}
		var res: Dictionary = lab.save_with_external_dependencies({"fail_on_path": fail_on})
		_emit({"mode": mode, "status": str(res.get("status", "")), "group_id": str(res.get("group_id", ""))})
		# Signal the parent that the interrupted transaction is durable, then
		# wait to be killed. This simulates a crash after the journal write but
		# with the OS process (and all static caches) still alive.
		var f := FileAccess.open(marker, FileAccess.WRITE)
		if f != null:
			f.store_string(str(res.get("group_id", "")) + "\n")
			f.flush()
			f.close()
		var deadline := Time.get_ticks_msec() + 120000
		while Time.get_ticks_msec() < deadline:
			OS.delay_msec(25)
		quit(0)
		return

	if mode == "crash_save":
		# P1-TEST-01: begin a real multi-document save with an in-operation
		# checkpoint. The worker blocks inside save_with_external_dependencies
		# until the parent kills this OS process at the chosen phase.
		if args.size() < 5:
			printerr("save_group_worker: crash_save needs marker, phase + fail_on args")
			quit(2)
			return
		var marker := str(args[2])
		var phase := str(args[3])
		var fail_on := str(args[4])
		var a = OdfDocument.load_cached(parent_dir.path_join("mod_a/effect.odf"))
		var b = OdfDocument.load_cached(parent_dir.path_join("mod_b/effect.odf"))
		a.set_entry_value(a.find_entry("Render", "lifeTime"), "9.9")
		b.set_entry_value(b.find_entry("Render", "lifeTime"), "8.8")
		var lab = _make_lab()
		lab.doc = a
		lab._external_nodes["extb"] = {"path": parent_dir.path_join("mod_b/effect.odf"), "header": "Render"}
		var result: Dictionary = lab.save_with_external_dependencies({
			"fail_on_path": fail_on,
			"checkpoint_phase": phase,
			"checkpoint_marker": marker,
		})
		_emit({"mode": mode, "phase": phase, "status": str(result.get("status", ""))})
		quit(0)
		return

	if mode == "resolve":
		if args.size() < 4:
			printerr("save_group_worker: resolve needs group id + action")
			quit(2)
			return
		var lab5 = _make_lab()
		var resolved: Dictionary = lab5.resolve_recovery_conflict(str(args[2]), str(args[3]))
		_emit({"mode": mode, "status": str(resolved.get("status", ""))})
		quit(0)
		return

	if mode == "crash_recover":
		# Recovery-side checkpoint: block inside recover_partial_save_group.
		if args.size() < 4:
			printerr("save_group_worker: crash_recover needs marker + phase args")
			quit(2)
			return
		var marker := str(args[2])
		var phase := str(args[3])
		var lab4 = _make_lab()
		var result4: Dictionary = lab4.recover_partial_save_group("", {
			"checkpoint_phase": phase, "checkpoint_marker": marker})
		_emit({"mode": mode, "phase": phase, "status": str(result4.get("status", ""))})
		quit(0)
		return

	if mode == "discover":
		# Process B: fresh OS process, fresh static state. Discover pending
		# save groups from disk only.
		var lab2 = _make_lab()
		var pending: Array[Dictionary] = lab2.discover_incomplete_save_groups()
		var summary: Array = []
		for g in pending:
			summary.append({
				"group_id": str(g.get("group_id", "")),
				"state": str(g.get("state", "")),
				"targets": (g.get("targets", []) as Array).size(),
			})
		_emit({"mode": mode, "count": pending.size(), "groups": summary})
		quit(0)
		return

	if mode == "recover":
		# Process B: recover the discovered group in this fresh process.
		# An optional third arg targets a specific group id explicitly.
		var lab3 = _make_lab()
		var rec: Dictionary
		if args.size() >= 3 and str(args[2]) != "":
			rec = lab3.recover_partial_save_group(str(args[2]))
		else:
			rec = lab3.recover_partial_save_group()
		_emit({
			"mode": mode,
			"status": str(rec.get("status", "")),
			"group_id": str(rec.get("group_id", "")),
			"restored": rec.get("restored", []),
			"failed": rec.get("failed", []),
			"conflicts": rec.get("conflicts", []),
		})
		quit(0)
		return

	if mode == "verify":
		# Process C: validate final filesystem and manifest state only.
		var rel_a := str(WorkspaceStore.entry_for(parent_dir.path_join("mod_a/effect.odf")).get("rel", ""))
		var rel_b := str(WorkspaceStore.entry_for(parent_dir.path_join("mod_b/effect.odf")).get("rel", ""))
		var override_a := ""
		if rel_a != "":
			var pa := WorkspaceStore.odf_dir().path_join(rel_a)
			override_a = FileAccess.get_file_as_string(pa) if FileAccess.file_exists(pa) else ""
		var journals: Array = []
		var sg_dir := ws_root.path_join("save_groups")
		if DirAccess.dir_exists_absolute(sg_dir):
			var dir := DirAccess.open(sg_dir)
			if dir != null:
				dir.list_dir_begin()
				var n := dir.get_next()
				while n != "":
					if n.ends_with(".json") and not n.begins_with("working_"):
						var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(sg_dir.path_join(n)))
						if bool(jres.get("ok", false)) and (jres.get("data", null) is Dictionary):
							journals.append({"file": n, "state": str((jres.get("data", {}) as Dictionary).get("state", ""))})
					n = dir.get_next()
				dir.list_dir_end()
		var final_ok := rel_a != "" and override_a.contains("lifeTime=1.5") and \
			journals.size() >= 1 and str((journals[0] as Dictionary).get("state", "")) == "RECOVERED"
		_emit({
			"mode": mode,
			"ok": final_ok,
			"rel_a": rel_a,
			"rel_b": rel_b,
			"override_a_value": override_a,
			"journals": journals,
		})
		quit(0)
		return

	printerr("save_group_worker: unknown mode " + mode)
	quit(2)
