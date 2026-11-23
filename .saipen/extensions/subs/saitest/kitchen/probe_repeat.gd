extends SceneTree
const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")
func _initialize() -> void:
	var ws := ProjectSettings.globalize_path("user://saitest_repeat_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(ws)
	WorkspaceStore.root_override = ws
	var src := ws.path_join("src.odf")
	var f := FileAccess.open(src, FileAccess.WRITE); f.store_string("[Root]\nlifeTime=1\n"); f.close()
	var doc = OdfDocument.load_cached(src)
	doc.set_entry_value(doc.find_entry("Root","lifeTime"), "5")
	var lab = ParticleLabScript.new()
	root.add_child(lab); lab.visible=false; lab.set_process(false); lab.set_physics_process(false)
	lab.setup(ResourceIndex.new(), SchemaRegistry.new())
	lab.doc = doc
	var r1: Dictionary = lab.save_with_external_dependencies({})
	var gid := str(r1.get("group_id",""))
	var r2: Dictionary = lab.recover_partial_save_group(gid)
	var r3: Dictionary = lab.recover_partial_save_group(gid)
	var r4: Dictionary = lab.resolve_recovery_conflict(gid, "keep_current")
	var r5: Dictionary = lab.resolve_recovery_conflict(gid, "keep_current")
	print("SAITEST3 first=", str(r1.get("status","")), " rec=", str(r2.get("status","")), " repeat=", str(r3.get("status","")), " resolve=", str(r4.get("status","")), " repeat_resolve=", str(r5.get("status","")))
	quit(0)
