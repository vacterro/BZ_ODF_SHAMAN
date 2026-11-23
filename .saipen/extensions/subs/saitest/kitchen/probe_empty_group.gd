extends SceneTree
const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")
func _initialize() -> void:
	var ws := ProjectSettings.globalize_path("user://saitest_empty_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var sg := ws.path_join("save_groups")
	DirAccess.make_dir_recursive_absolute(sg)
	var g := {"schema": 1, "group_id": "saitest_empty", "state": "PARTIAL_SAVE_RECOVERABLE", "targets": []}
	WorkspaceStore.atomic_write_abs(sg.path_join("saitest_empty.json"), JSON.stringify(g, "  ").to_utf8_buffer())
	var lab = ParticleLabScript.new()
	root.add_child(lab); lab.visible=false; lab.set_process(false); lab.set_physics_process(false)
	lab.setup(ResourceIndex.new(), SchemaRegistry.new())
	var rec: Dictionary = lab.recover_partial_save_group("saitest_empty")
	var pending: Array[Dictionary] = lab.discover_incomplete_save_groups()
	print("SAITEST2 status=", str(rec.get("status", "")), " restored=", (rec.get("restored", []) as Array).size(), " still_discoverable=", pending.size())
	quit(0)
