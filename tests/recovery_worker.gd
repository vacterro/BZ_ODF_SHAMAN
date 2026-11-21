extends SceneTree
## Disposable test worker for real OS process-termination recovery tests.
## Invoked by tests/test_runner.gd via OS.create_process() and killed via
## OS.kill() when the requested transaction phase is reached.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("recovery_worker: missing args")
		quit(2)
		return
	var mode := str(args[0])
	var root := str(args[1])
	WorkspaceStore.root_override = root

	if mode == "recover":
		var committed := WorkspaceStore.recover_transactions()
		print("RECOVERY_JSON:" + JSON.stringify({
			"committed": committed,
			"last_recovery": WorkspaceStore.last_recovery,
		}))
		OdfDocument.clear_all_cache()
		quit(0)
		return

	if mode == "save" and args.size() >= 5:
		var phase := str(args[2])
		var marker := str(args[3])
		var src := str(args[4])
		var target_val := str(args[5]) if args.size() > 5 else "250"
		var trigger_phase := phase
		if phase == "manifest_commit":
			trigger_phase = "manifest_write"
		elif phase == "rollback":
			WorkspaceStore.fault_phases["manifest_write"] = true
			trigger_phase = "rollback_write"
		WorkspaceStore.fault_callback = func(hit_phase: String):
			if hit_phase == trigger_phase:
				var f := FileAccess.open(marker, FileAccess.WRITE)
				if f != null:
					f.store_string(hit_phase + "\n")
					f.flush()
					f.close()
				# Wait to be forcibly terminated by the parent process.
				var deadline := Time.get_ticks_msec() + 10000
				while Time.get_ticks_msec() < deadline:
					OS.delay_msec(25)
		var doc := OdfDocument.load_file(src)
		if doc == null:
			printerr("recovery_worker: failed to load " + src)
			quit(3)
			return
		var entry = doc.find_entry("OrdnanceClass", "damageValue(H)")
		if entry != null:
			doc.set_entry_value(entry, target_val)
		else:
			doc.append_entry("OrdnanceClass", "damageValue(H)", target_val)
		doc.workspace_rel = "ord.odf"
		WorkspaceStore.save_document(doc)
		OdfDocument.clear_all_cache()
		quit(0)
		return

	printerr("recovery_worker: unknown mode " + mode)
	quit(2)
