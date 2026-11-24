extends SceneTree
## Bounded Windows filename-equivalence investigation for ODF write paths.

const WorkspaceStoreScript = preload("res://scripts/core/workspace_store.gd")
const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")

var passed := 0
var failed := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
		print("  PASS " + msg)
	else:
		failed += 1
		print("  FAIL " + msg)


func _remove_tree(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _initialize() -> void:
	print("Windows path identity verifier (platform=%s)" % OS.get_name())
	var tmp := ProjectSettings.globalize_path("user://verify_winpath_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var previous_root := WorkspaceStoreScript.root_override
	WorkspaceStoreScript.root_override = tmp
	var base := tmp.path_join("stage")
	var base_registration: Dictionary = SafeStageScript.register_owned_base(base)
	_check(bool(base_registration.get("ok", false)), "WINPATH setup: owned temporary stage root registered")
	DirAccess.make_dir_recursive_absolute(base)

	var alias_stage := base.path_join("alias")
	var valid_stage := base.path_join("valid")
	SafeStageScript.register_owned_base(alias_stage)
	SafeStageScript.register_owned_base(valid_stage)
	var alias_target := alias_stage.path_join("effects/weapon.odf")
	DirAccess.make_dir_recursive_absolute(alias_target.get_base_dir())
	var alias_file := FileAccess.open(alias_target, FileAccess.WRITE)
	if alias_file != null:
		alias_file.store_string("ORIGINAL")
		alias_file.close()
	_check(FileAccess.file_exists(alias_target) and FileAccess.get_file_as_string(alias_target) == "ORIGINAL",
		"WINPATH-01 setup: canonical effects/weapon.odf exists")
	var alias_identity := SafeStageScript.path_identity("effects/weapon.odf")
	_check(alias_identity == SafeStageScript.path_identity("effects/weapon.odf.") and
		alias_identity == SafeStageScript.path_identity("effects/weapon.odf "),
		"WINPATH-01/02 Windows trailing-dot and trailing-space identities agree")
	var alias_refused: Dictionary = SafeStageScript.stage(alias_stage, {
		"effects/weapon.odf": "A".to_utf8_buffer(),
		"effects/weapon.odf.": "B".to_utf8_buffer(),
	}, {}, false, [], {"stage_id": "winpath-alias"})
	_check(not bool(alias_refused.get("ok", true)) and
		str(alias_refused.get("reason", "")) in ["UNOWNED_FILE_COLLISION", "WINDOWS_PATH_ALIAS_REJECTED", "DUPLICATE_TARGET"],
		"WINPATH-01/02 Windows aliases are rejected before mutation")
	_check(FileAccess.get_file_as_string(alias_target) == "ORIGINAL",
		"WINPATH-05 rejected aliases preserve the original file")

	var reserved_attempt: Dictionary = SafeStageScript.stage(valid_stage,
		{"effects/CON": "CON_BYTES".to_utf8_buffer()}, {}, false, [], {"stage_id": "winpath-con"})
	_check(not bool(reserved_attempt.get("ok", false)) and not FileAccess.file_exists(valid_stage.path_join("effects/CON")),
		"WINPATH-03 reserved Windows device path is refused without creating a file")
	var case_identity := SafeStageScript.path_identity("Effects/Weapon.ODF")
	_check(case_identity == alias_identity,
		"WINPATH-06 manifest identity follows Windows case-insensitive filesystem identity")
	var valid: Dictionary = SafeStageScript.stage(valid_stage, {"effects/weapon.odf": "VALID".to_utf8_buffer()},
		{}, false, [], {"stage_id": "winpath-valid"})
	_check(bool(valid.get("ok", false)) and FileAccess.get_file_as_string(valid_stage.path_join("effects/weapon.odf")) == "VALID",
		"WINPATH-04 valid filenames remain accepted")

	WorkspaceStoreScript.root_override = previous_root
	SafeStageScript.clear_registered_bases()
	_remove_tree(tmp)
	print("\nWindows Path Identity: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
