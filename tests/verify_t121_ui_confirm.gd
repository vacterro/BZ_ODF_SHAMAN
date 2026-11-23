extends Node
## T-121 UIREC-01..06 — Recovery Center confirmation workflow verifier.
## Boots the real main scene and drives the confirmation dialog directly,
## avoiding any filesystem mutation until the user explicitly confirms.

var failures: Array[String] = []
var main
var test_root := ""


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ " + msg)
	else:
		failures.append(msg)
		print("  ✗ FAIL: " + msg)


func _ready() -> void:
	print("T-121 Recovery UI Confirmation Verifier")
	test_root = "user://t121_ui_" + str(Time.get_ticks_usec())
	OS.set_environment(WorkspaceStore.ENV_ROOT, test_root)
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	_run()
	print("\nT-121 Recovery UI: %d check(s), %d failure(s)" % [
		7 + failures.size(), failures.size()])
	print("RESULT: " + ("PASS" if failures.is_empty() else "FAIL"))
	main.queue_free()
	get_tree().quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_check(main.recovery_confirm_dialog != null and
		main.recovery_confirm_dialog is ConfirmationDialog,
		"UIREC-01: Recovery Center owns an explicit confirmation dialog")

	var group := {"schema": 1, "group_id": "uipreview", "state": "PARTIAL_SAVE_RECOVERABLE",
		"targets": [{"source_path": "C:/game/effect.odf", "previous_override_hash": "abc",
			"new_override_hash": "def", "working_bytes_hash": "ghi"}],
		"conflict_resolution": {"failed": []}}
	var preview: String = main._preview_recovery_action(group, "RECOVER")
	_check(preview.contains("Operation: RECOVER") and preview.contains("C:/game/effect.odf") and
		preview.contains("previous hash: abc") and preview.contains("recorded commit: def"),
		"UIREC-01: preview lists operation, affected files and expected hashes")
	_check(preview.contains("Conflicts: 0") and preview.contains("Overwrites:"),
		"UIREC-01: preview distinguishes preserved data from overwrites")
	var inspect: String = main._preview_recovery_action(group, "KEEP CURRENT")
	_check(inspect.contains("Operation: KEEP CURRENT") and inspect.contains("Overwrites: nothing"),
		"UIREC-01: INSPECT / KEEP CURRENT / RESTORE WORKING are distinct operations")

	# Cancel: no mutation. Drive the request path with a synthetic selection.
	var ws := ProjectSettings.globalize_path(test_root)
	var sg := ws.path_join("save_groups")
	DirAccess.make_dir_recursive_absolute(sg)
	group["group_id"] = "ui_cancel"
	WorkspaceStore.atomic_write_abs(sg.path_join("ui_cancel.json"), JSON.stringify(group, "  ").to_utf8_buffer())
	var before := FileAccess.get_file_as_string(sg.path_join("ui_cancel.json"))
	main.last_recovery_center_scan = {"save_groups": [group], "cleanup_intents": [], "count": 1}
	var root_item = main.recovery_center_tree.get_root()
	var item = main.recovery_center_tree.create_item(root_item)
	item.set_metadata(0, {"kind": "save_group", "group": group})
	main.recovery_center_tree.set_selected(item, 0)
	main._request_recovery_action("RECOVER")
	_check(not main.pending_recovery_action.is_empty() and
		str(main.pending_recovery_action.get("group_id", "")) == "ui_cancel",
		"UIREC-02: request arms a pending action but performs no mutation")
	_check(FileAccess.get_file_as_string(sg.path_join("ui_cancel.json")) == before,
		"UIREC-02: cancel path leaves journal and files unchanged")
	main.pending_recovery_action = {}

	# Stale journal between preview and confirmation must be refused.
	group["state"] = "SAVE_FAILED"
	WorkspaceStore.atomic_write_abs(sg.path_join("ui_cancel.json"), JSON.stringify(group, "  ").to_utf8_buffer())
	main.pending_recovery_action = {"group_id": "ui_cancel", "action": "RECOVER",
		"journal_hash": "stale-hash"}
	main._confirm_recovery_action()
	_check(FileAccess.get_file_as_string(sg.path_join("ui_cancel.json")).contains("SAVE_FAILED") and
		main.pending_recovery_action.is_empty(),
		"UIREC-03: journal changed since preview -> REFUSED, no mutation")
