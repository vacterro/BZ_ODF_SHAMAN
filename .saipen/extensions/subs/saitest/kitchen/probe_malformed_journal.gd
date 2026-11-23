extends SceneTree
const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")
func _initialize() -> void:
	var ws := ProjectSettings.globalize_path("user://saitest_malformed_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var sg := ws.path_join("save_groups")
	DirAccess.make_dir_recursive_absolute(sg)
	var bad := {"schema": 1, "group_id": "saitest_bad", "state": "PARTIAL_SAVE_RECOVERABLE", "targets": ["not-a-dict", 42, null]}
	WorkspaceStore.atomic_write_abs(sg.path_join("saitest_bad.json"), JSON.stringify(bad, "  ").to_utf8_buffer())
	var lab = ParticleLabScript.new()
	root.add_child(lab); lab.visible=false; lab.set_process(false); lab.set_physics_process(false)
	lab.setup(ResourceIndex.new(), SchemaRegistry.new())
	var rec: Dictionary = lab.recover_partial_save_group("saitest_bad")
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(sg.path_join("saitest_bad.json")))
	var state := str((jres.get("data", {}) as Dictionary).get("state", "")) if bool(jres.get("ok", false)) else "UNREADABLE"
	print("SAITEST_RESULT status=", str(rec.get("status", "")), " ok=", bool(rec.get("ok", false)), " durable_state=", state)
	quit(0)
