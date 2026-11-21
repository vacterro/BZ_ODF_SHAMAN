extends Node
## Integration smoke test: boots the real main scene, waits for indexing,
## verifies the auto-selected VSR scenario, fires a shot, and checks telemetry.

var failures: Array[String] = []
var main
var test_root := ""


func _ready() -> void:
	print("BZ_ODF_SHAMAN UI smoke test")
	# Hard isolation: this process can only write/delete inside its own root.
	test_root = "user://smoke_workspace_" + str(Time.get_ticks_usec())
	OS.set_environment(WorkspaceStore.ENV_ROOT, test_root)
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	# Wait for the background resource scan to finish (bounded).
	var waited := 0.0
	while (main.scan_thread != null or (main.index != null and main.index.total_files < 10000)) and waited < 60.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	# One more frame so the auto-selected scenario is applied.
	await get_tree().process_frame
	await get_tree().process_frame
	_check(main.index != null and main.index.count() > 10000, "resource index built: %d ODFs" % (main.index.count() if main.index else 0))
	_check(main.current_doc != null, "a document auto-opened")
	_check(main.weapon_lab != null and main.weapon_lab.profile != null, "weapon lab scenario resolved")
	if main.weapon_lab != null and main.weapon_lab.profile != null:
		var p = main.weapon_lab.profile
		_check(p.weapon_name == "gatstabvsr_c", "VSR weapon resolved: " + p.weapon_name)
		_check(bool(main.weapon_lab.shooter_model_info.get("ok", false)), "authentic BZCC shooter 3D model loaded")
		_check(bool(main.weapon_lab.target_model_info.get("ok", false)), "authentic BZCC target 3D model loaded")
		_check(main.weapon_lab.shooter_hardpoint_node != null and str(main.weapon_lab.hardpoint_mode) == "mesh:hp_cannon_1", "authentic hp_cannon_1 hardpoint bound")
		var g0: Dictionary = main.weapon_lab._shot_geometry()
		main.weapon_lab.yaw_spin.value = 25.0
		var g1: Dictionary = main.weapon_lab._shot_geometry()
		_check((g0.origin as Vector3).distance_to(g1.origin as Vector3) > 0.2, "turret yaw moves projectile spawn origin")
		_check((g0.direction as Vector3).angle_to(g1.direction as Vector3) > deg_to_rad(20.0), "turret yaw updates projectile launch direction")
		main.weapon_lab.yaw_spin.value = 0.0
		var before_children: int = main.weapon_lab.shooter_node.get_child_count()
		main.weapon_lab._reload_scenario()
		_check(main.weapon_lab.shooter_node.get_child_count() == before_children, "reload does not create duplicate shooter scene objects")
		_check(p.shot_speed > 0.0, "shotSpeed present: %.1f" % p.shot_speed)
		_check(p.expected_damage() > 0.0, "damage derived: %.1f (armor %s)" % [p.expected_damage(), p.target_armor])
		_check(main.weapon_lab.alt_button != null, "FIRE ALT control present")
		_check(p.alt != null, "alternate weapon resolved")
		if p.alt != null:
			var alt_name: String = p.alt.weapon_name
			main.weapon_lab.fire_alt()
			await get_tree().create_timer(1.5).timeout
			_check(main.weapon_lab.telemetry.text.contains("Weapon activated: " + alt_name), "alternate shot fired in UI")
			main.weapon_lab.restart_test()
		main.weapon_lab.fire_once()
		await get_tree().create_timer(1.5).timeout
		var txt: String = main.weapon_lab.telemetry.text
		_check(txt.contains("Weapon activated"), "telemetry: weapon activated")
		_check(txt.contains("Collision detected") or txt.contains("expired"), "telemetry: impact or expiry recorded")
		_check(txt.contains("Damage calculated") or txt.contains("expired"), "telemetry: damage or expiry recorded")
		_check(main.weapon_lab.fx_button != null, "FX toggle control present")
		_check(main.weapon_lab.spawned_effects > 0, "impact spawned an explosion effect")
		_check(main.weapon_lab.effect_root.get_child_count() > 0, "effect node is in the 3D scene")
		_check(txt.contains("Explosion burst"), "telemetry records the explosion ODF and emitter count")
		main.weapon_lab.restart_test()
		await get_tree().process_frame
		_check(main.weapon_lab.spawned_effects == 0 and main.weapon_lab.effect_root.get_child_count() == 0, "restart clears explosion effects")
		# Wave C live effect edit: edit explosion ODF startColor + lifeTime -> next shot reflects it, undo restores it.
		var xpl_path: String = main.index.resolve_path_from(p.xpl_vehicle if p.xpl_vehicle != "" else p.xpl_ground, p.ordnance_path)
		if xpl_path != "":
			main.open_document(xpl_path)
			await get_tree().process_frame
			var xdoc = main.current_doc
			var target_hdr := ""
			var sc_entry = null
			for h in xdoc.render_headers():
				var e_sc = xdoc.find_entry(h.name, "startColor")
				if e_sc != null:
					target_hdr = h.name
					sc_entry = e_sc
					break
			if sc_entry != null:
				var orig_sc: String = sc_entry.value_raw
				xdoc.set_entry_value(sc_entry, "\"12 240 35 255\"")
				main._propagate_document_change(false)
				main.weapon_lab.restart_test()
				main.weapon_lab.fire_once()
				await get_tree().create_timer(1.5).timeout
				var fx_res: Dictionary = main.weapon_lab.last_fx_result
				_check(bool(fx_res.get("ok", false)) and is_instance_valid(fx_res.get("root", null)), "edited explosion burst spawned")
				if is_instance_valid(fx_res.get("root", null)):
					var em: CPUParticles3D = (fx_res.root as Node).get_node_or_null("FX_" + target_hdr)
					_check(em != null and em.color_ramp.get_color(0).g > 0.85 and em.color_ramp.get_color(0).r < 0.2, "V5: live startColor edit visible in Weapons Lab shot")
				xdoc.undo()
				main._propagate_document_change(true)
				main.weapon_lab.restart_test()
				main.weapon_lab.fire_once()
				await get_tree().create_timer(1.5).timeout
				var fx_undo: Dictionary = main.weapon_lab.last_fx_result
				if is_instance_valid(fx_undo.get("root", null)):
					var em2: CPUParticles3D = (fx_undo.root as Node).get_node_or_null("FX_" + target_hdr)
					_check(em2 != null and em2.color_ramp.get_color(0) != Color(12.0/255.0, 240.0/255.0, 35.0/255.0, 1.0), "V5: undo restores previous explosion effect color")
				xdoc.set_entry_value(sc_entry, orig_sc)
				main.weapon_lab.restart_test()
	# Live edit -> fire -> observable damage change (shared document cache).
	if main.weapon_lab != null and main.weapon_lab.profile != null:
		var ord_path: String = main.weapon_lab.profile.ordnance_path
		var disk_before := FileAccess.get_file_as_bytes(ord_path)
		main.open_document(ord_path)
		await get_tree().process_frame
		var damage_entry = null
		if main.current_doc != null:
			for e in main.current_doc.entries:
				if str(e.key_raw).to_lower() == "damagevalue" and str(e.suffix).to_lower() == "(h)":
					damage_entry = e
		if damage_entry == null:
			# The VSR child inherits damage; add an explicit override, exactly like
			# a modder would in the inspector.
			damage_entry = main.current_doc.append_entry("OrdnanceClass", "damageValue(H)", "200")
		_check(damage_entry != null, "damageValue(H) located or appended in ordnance ODF")
		if damage_entry != null:
			main.current_doc.set_entry_value(damage_entry, "200")
			main.weapon_lab.restart_test()
			main.weapon_lab.fire_once()
			await get_tree().create_timer(1.5).timeout
			var tel: String = main.weapon_lab.telemetry.text
			_check(tel.contains("200.00"), "edited damage applied by simulation (200.00)")
			_check(FileAccess.get_file_as_bytes(ord_path) == disk_before, "editing never modified the original game file")
			# Undo must propagate to the profile and the next shot, not only Inspector.
			main._undo()
			await get_tree().process_frame
			main.weapon_lab.restart_test()
			main.weapon_lab.fire_once()
			await get_tree().create_timer(1.5).timeout
			_check(main.weapon_lab.telemetry.text.contains("100.00"), "undo propagated to the next simulated shot (100.00)")
			main._redo()
			await get_tree().process_frame
			main.weapon_lab.restart_test()
			main.weapon_lab.fire_once()
			await get_tree().create_timer(1.5).timeout
			_check(main.weapon_lab.telemetry.text.contains("200.00"), "redo propagated to the next simulated shot (200.00)")
			# Cross-consumer matrix: one edit must reach every active view.
			main.raw_edit.release_focus()
			await get_tree().process_frame
			main._after_edit()
			await get_tree().process_frame
			_check(main.raw_edit.text.contains("damageValue(H) = 200") or main.raw_edit.text.contains("damageValue(H)=200"), "edit propagation keeps the raw editor showing the applied value")
			_check(main.inspector_box.get_child_count() > 0, "edit propagation rebuilds the structured inspector")
			_check(main.dep_summary.text.contains("node"), "edit propagation refreshes dependencies")
			_check(absf(main.weapon_lab.profile.expected_damage() - 200.0) < 0.001, "edit propagation keeps the weapon profile on the current revision")
		# Safe staged export of the in-memory edit.
		var export_root := ProjectSettings.globalize_path(test_root.path_join("export"))
		DirAccess.make_dir_recursive_absolute(export_root)
		main._on_export_dir_selected(export_root)
		var exported := _find_exported(export_root, "atstabvsr_c.odf")
		_check(exported != "", "staged export file written")
		if exported != "":
			var txt := FileAccess.get_file_as_string(exported)
			_check(txt.contains("damageValue(H)=200") or txt.contains("damageValue(H) = 200"), "exported ODF contains the edit")
	# Save-all writes every dirty document to the workspace.
	if main.current_doc != null:
		var edited_doc = main.current_doc
		var ws_path := ProjectSettings.globalize_path(main._workspace_dir().path_join(main._relative_for(edited_doc.source_path)))
		var saved_count: int = main.save_all_edited()
		_check(saved_count >= 1, "save-all saved the edited document(s)")
		_check(FileAccess.file_exists(ws_path), "save-all wrote the workspace file")
		_check(not edited_doc.dirty, "save-all cleared the dirty flag")
		_check(edited_doc.to_bytes() == FileAccess.get_file_as_bytes(ws_path), "saved document bytes equal the current working revision")
		_check(WorkspaceStore.root() == test_root, "smoke workspace is the isolated test root")
		_check(WorkspaceStore.is_within(ProjectSettings.globalize_path(test_root), ws_path), "saved file stays inside the test root")
	# Parameter sweep: batch values applied in memory, then fully rolled back.
	if main.weapon_lab != null and main.weapon_lab.profile != null:
		var lab = main.weapon_lab
		var dmg_index := -1
		for i in lab.sweep_property.item_count:
			if str(lab.sweep_property.get_item_metadata(i)).begins_with("damageValue("):
				dmg_index = i
		_check(dmg_index >= 0, "sweep offers a damageValue property for the target armor")
		if dmg_index >= 0:
			lab.sweep_property.select(dmg_index)
			lab.sweep_from.value = 50
			lab.sweep_to.value = 250
			lab.sweep_steps.value = 5
			var sweep: Dictionary = lab.run_parameter_sweep()
			_check(sweep.rows.size() == 5, "parameter sweep produced 5 rows")
			_check(absf(float(sweep.baseline.damage) - 200.0) < 0.001, "sweep baseline uses the live 200 damage edit")
			_check(absf(float(sweep.rows[4].damage) - 250.0) < 0.001, "sweep top point applies 250 damage")
			_check(lab.sweep_output.text.contains("SWEEP"), "sweep results rendered in the UI")
			_check(absf(lab.profile.expected_damage() - 200.0) < 0.001, "sweep rolled back: edit still reads 200")
			var csv_path: String = lab.save_sweep_csv()
			_check(csv_path != "" and FileAccess.file_exists(csv_path), "sweep CSV saved to workspace")
			if csv_path != "" and FileAccess.file_exists(csv_path):
				_check(FileAccess.get_file_as_string(csv_path).contains("value,damage,damage_delta"), "sweep CSV header present")
				DirAccess.remove_absolute(csv_path)
	# Audio Lab resolves inherited weapon sounds (fireSound lives on gatstab_c).
	if main.weapon_lab != null and main.weapon_lab.profile != null:
		main.open_document(main.weapon_lab.profile.weapon_path)
		await get_tree().process_frame
		_check(main.audio_lab != null and main.audio_lab.list.item_count > 0, "Audio Lab lists inherited weapon sound references")
	# Particle lab on a real render ODF
	var xpl := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R/bz2r_res/effects/explosions/xcoreturrxpl.odf"
	if FileAccess.file_exists(xpl):
		main.open_document(xpl)
		await get_tree().process_frame
		_check(main.particle_lab != null and main.particle_lab.graph.get_child_count() > 0, "particle graph populated from real render ODF")
		var pdoc = main.current_doc
		if pdoc != null:
			var before_bytes: PackedByteArray = pdoc.to_bytes()
			var before_text: String = pdoc.text
			var src_h := ""
			var dst_h := ""
			var src_node_name := ""
			var dst_node_name := ""
			for hs in pdoc.render_headers():
				for hd in pdoc.render_headers():
					if hs.name == hd.name:
						continue
					var linked := false
					for k in main.particle_lab._child_keys(pdoc, hs.name):
						if main.particle_lab._reference_header(pdoc.get_value(hs.name, k, "")) == hd.name:
							linked = true
					if not linked and main.particle_lab._next_reference_key(hs.name) != "":
						src_h = hs.name
						dst_h = hd.name
						break
				if src_h != "":
					break
			for n in main.particle_lab.graph.get_children():
				if n is GraphNode and n.has_meta("header"):
					if str(n.get_meta("header")) == src_h:
						src_node_name = str(n.name)
					elif str(n.get_meta("header")) == dst_h:
						dst_node_name = str(n.name)
			_check(src_h != "" and dst_h != "" and src_node_name != "" and dst_node_name != "", "found an unused render link to create")
			if src_h != "" and dst_h != "" and src_node_name != "" and dst_node_name != "":
				main.particle_lab._on_connection_request(StringName(src_node_name), 0, StringName(dst_node_name), 0)
				await get_tree().process_frame
				var added_key := ""
				for k in main.particle_lab._child_keys(pdoc, src_h):
					if main.particle_lab._reference_header(pdoc.get_value(src_h, k, "")) == dst_h:
						added_key = k
				_check(added_key != "", "graph connection persisted as a real ODF reference")
				_check(main.particle_lab.doc == pdoc and main.audio_lab.doc == pdoc, "particle and audio labs share the live document revision")
				_check(pdoc.dirty and pdoc.text != before_text, "graph edit marks the document dirty")
				main.particle_lab._on_disconnection_request(StringName(src_node_name), 0, StringName(dst_node_name), 0)
				await get_tree().process_frame
				_check(pdoc.to_bytes() == before_bytes, "connect+disconnect restores byte-exact ODF")
				# Reconnect, save, clear the object cache, restore from the manifest:
				# the graph link must survive a full reopen cycle.
				main.particle_lab._on_connection_request(StringName(src_node_name), 0, StringName(dst_node_name), 0)
				await get_tree().process_frame
				_check(main.save_all_edited() >= 1, "graph edit saved to the workspace")
				OdfDocument.clear_all_cache()
				WorkspaceStore.restore_cache()
				main.open_document(xpl)
				await get_tree().process_frame
				var reopened = main.current_doc
				var persisted := false
				if reopened != null:
					for k in main.particle_lab._child_keys(reopened, src_h):
						if main.particle_lab._reference_header(reopened.get_value(src_h, k, "")) == dst_h:
							persisted = true
				_check(persisted and reopened.workspace_override, "graph link restored after save + cache clear")
				# Duplicate -> delete -> undo/redo through the real graph toolbar methods.
				var plab = main.particle_lab
				plab._selected_header = src_h
				plab._on_duplicate_node()
				await get_tree().process_frame
				var copy_name: String = plab._selected_header
				_check(copy_name.ends_with("_copy") and reopened.has_header(copy_name), "graph duplicate created a real header: " + copy_name)
				_check(reopened.header_entry_count(copy_name) > 0, "duplicate header has editable property lines")
				plab._selected_header = copy_name
				plab._on_delete_node()
				await get_tree().process_frame
				_check(not opened_doc_has(main, copy_name), "graph delete removed the duplicate header")
				plab._on_graph_undo()
				await get_tree().process_frame
				_check(opened_doc_has(main, copy_name), "graph undo restored the deleted header")
				plab._on_graph_redo()
				await get_tree().process_frame
				_check(not opened_doc_has(main, copy_name), "graph redo removed it again")
				_check(plab._would_cycle(dst_h, src_h), "cycle detection sees the existing %s -> %s edge" % [src_h, dst_h])
				# Layout persistence: cosmetic graph state in the isolated workspace.
				var moved_node = _graph_node(plab, dst_h)
				if moved_node != null:
					moved_node.position_offset = Vector2(321, 123)
				plab._save_layout()
				_check(FileAccess.file_exists(ProjectSettings.globalize_path(plab._layout_path())), "graph layout saved in the workspace")
				plab.load_document(reopened)
				await get_tree().process_frame
				var restored_node = _graph_node(plab, dst_h)
				_check(restored_node != null and restored_node.position_offset.is_equal_approx(Vector2(321, 123)), "graph layout restored after reload")
	# Cross-file graph: a real ODF whose headers reference other render files.
	var xmdm := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R/bz2r_res/baked/ISDF/Weapons/Mortar/MDM_Mortar/xmdmxpl.odf"
	if FileAccess.file_exists(xmdm):
		main.open_document(xmdm)
		await get_tree().process_frame
		var xlab = main.particle_lab
		_check(not xlab._external_nodes.is_empty(), "external file.header references become graph nodes")
		var ext_path := ""
		var ext_node = null
		for en in xlab._external_nodes:
			ext_path = str(xlab._external_nodes[en].path)
			ext_node = xlab.graph.get_node_or_null(NodePath(en))
			break
		_check(ext_path != "" and FileAccess.file_exists(ext_path), "external node resolves to a real indexed file")
		if ext_node != null:
			var open_btn = _find_button(ext_node)
			_check(open_btn != null, "external node offers an OPEN control")
			if open_btn != null:
				open_btn.pressed.emit()
				await get_tree().process_frame
				_check(main.current_doc != null and main.current_doc.source_path == ext_path, "OPEN navigates to the referenced file")
	# Duplicate physical headers are shown as one clearly marked effective node.
	var dup_path := ProjectSettings.globalize_path(test_root.path_join("dup_render.odf"))
	DirAccess.make_dir_recursive_absolute(dup_path.get_base_dir())
	var dup_f := FileAccess.open(dup_path, FileAccess.WRITE)
	dup_f.store_string("[Core]\nrenderBase = \"draw_sprite\"\nlifeTime = 1.0\n\n[Shock]\nrenderBase = \"draw_emit\"\n\n[Core]\nlifeTime = 3.0\n")
	dup_f.close()
	main.open_document(dup_path)
	await get_tree().process_frame
	var dlab = main.particle_lab
	var core_node = _graph_node(dlab, "Core")
	_check(core_node != null and core_node.title.contains("merged"), "duplicate occurrences are labelled as a merged effective view")
	var created: String = dlab.create_render_node("GraphTest")
	_check(created != "" and dlab.doc.has_header(created), "NEW NODE created a real render header")
	_check(dlab.doc.get_value(created, "renderBase") == "draw_sprite", "created node uses a documented renderBase value")
	_check(dlab.rename_render_node(created, "GraphRenamed"), "RENAME renamed the render header")
	_check(dlab.doc.has_header("GraphRenamed") and not dlab.doc.has_header(created), "renamed header replaces the old name")
	dlab.doc.undo()
	_check(dlab.doc.has_header(created), "rename is undoable")
	_check(main.raw_edit != null and main.raw_edit.text.contains("["), "raw editor populated")
	_check(main.schema != null and main.schema.property_count() > 1000, "schema registry loaded: %d properties" % (main.schema.property_count() if main.schema else 0))
	_check(main.theme != null, "Wintage theme applied")
	# Manual rescan without an app restart.
	main.rescan_index()
	var rescan_waited := 0.0
	while (main.scan_thread != null or (main.index != null and main.index.total_files < 10000)) and rescan_waited < 30.0:
		await get_tree().create_timer(0.25).timeout
		rescan_waited += 0.25
	_check(main.index != null and main.index.count() > 10000, "manual rescan rebuilt the index (%d ODFs)" % (main.index.count() if main.index else 0))
	# Simulated restart: clear all document objects, restore from the workspace
	# manifest, and confirm the saved 200 is what the editor now serves.
	if main.weapon_lab != null and main.weapon_lab.profile != null:
		var restore_path: String = main.weapon_lab.profile.ordnance_path
		OdfDocument.clear_all_cache()
		var restored_n := WorkspaceStore.restore_cache()
		_check(restored_n >= 1, "workspace overrides restored after cache clear")
		main.open_document(restore_path)
		await get_tree().process_frame
		_check(main.current_doc != null and main.current_doc.get_value("OrdnanceClass", "damageValue(H)") == "200", "saved damage 200 restored into the editor")
		_check(main._doc_state(main.current_doc).contains("OVERRIDE"), "restored document shows OVERRIDE state")
	var st_path: String = main._settings_path()
	_check(WorkspaceStore.is_within(ProjectSettings.globalize_path(test_root), st_path), "settings stay inside the test root")
	# T-12 acceptance: Edit -> Save -> Export must export the saved revision,
	# repeatedly, and survive a restart without touching the game source.
	if main.weapon_lab != null and main.weapon_lab.profile != null:
		var ord_path: String = main.weapon_lab.profile.ordnance_path
		main.open_document(ord_path)
		await get_tree().process_frame
		var sdoc = main.current_doc
		var dentry = sdoc.find_entry("OrdnanceClass", "damageValue(H)")
		_check(dentry != null, "saved-revision test found the damage entry")
		if dentry != null:
			sdoc.set_entry_value(dentry, "250")
			main._after_edit()
			await get_tree().process_frame
			_check(main.save_all_edited() >= 1, "edit saved before export")
			var e1 := ProjectSettings.globalize_path(test_root.path_join("export_saved_1"))
			DirAccess.make_dir_recursive_absolute(e1)
			main._on_export_dir_selected(e1)
			var first_stage: String = str(main.export_last_stage)
			var f1 := _find_exported(e1, "atstabvsr_c.odf")
			_check(f1 != "" and (FileAccess.get_file_as_string(f1).contains("damageValue(H)=250") or FileAccess.get_file_as_string(f1).contains("damageValue(H) = 250")), "export after save writes the saved 250 bytes")
			_check(main.export_last_report_ok, "export report write is confirmed before success is announced")
			var report: String = first_stage.path_join("export_report.txt")
			_check(FileAccess.file_exists(report) and FileAccess.get_file_as_string(report).contains(FileAccess.get_md5(f1)), "export report records the exported file hash")
			main._on_export_dir_selected(e1)
			_check(main.export_last_stage != first_stage, "two exports in the same second get distinct stage directories")
			# Export again after another save: current bytes, not the first snapshot.
			sdoc.set_entry_value(dentry, "275")
			main._after_edit()
			await get_tree().process_frame
			_check(main.save_all_edited() >= 1, "second edit saved")
			var e2 := ProjectSettings.globalize_path(test_root.path_join("export_saved_2"))
			DirAccess.make_dir_recursive_absolute(e2)
			main._on_export_dir_selected(e2)
			var f2 := _find_exported(e2, "atstabvsr_c.odf")
			_check(f2 != "" and (FileAccess.get_file_as_string(f2).contains("damageValue(H)=275") or FileAccess.get_file_as_string(f2).contains("damageValue(H) = 275")), "second export uses the newer saved revision")
			# Restart: no cache, restore from the manifest, editor must serve 275.
			OdfDocument.clear_all_cache()
			WorkspaceStore.restore_cache()
			main.open_document(ord_path)
			await get_tree().process_frame
			_check(main.current_doc != null and main.current_doc.get_value("OrdnanceClass", "damageValue(H)") == "275", "restart serves the last saved edit (275)")
			_check(not FileAccess.get_file_as_string(ord_path).contains("damageValue(H)=275") and not FileAccess.get_file_as_string(ord_path).contains("damageValue(H) = 275"), "original game ODF has no saved override content")
			_check(FileAccess.get_md5(ord_path) == str(WorkspaceStore.entry_for(ord_path).get("source_md5", "")), "original game ODF is unchanged since the save")

	# P1-07 Particle Graph + V8 cross-file render edit + V9 audio sync + 3D Lab controls.
	if main.particle_lab != null:
		var p107_path := ProjectSettings.globalize_path(test_root.path_join("p107_graph.odf"))
		var p107_ext_path := ProjectSettings.globalize_path(test_root.path_join("p107_ext.odf"))
		var fe := FileAccess.open(p107_ext_path, FileAccess.WRITE)
		fe.store_string("[Glow]\nrenderBase = \"draw_sprite\"\nlifeTime = 0.5\nstartColor = \"50 180 255 255\"\n")
		fe.close()
		var fp := FileAccess.open(p107_path, FileAccess.WRITE)
		fp.store_string("[RootEmit]\nrenderBase = \"draw_emit\"\nemitName = \"ChildFlame\"\nrenderName1 = \"p107_ext.Glow\"\n\n[ChildFlame]\nrenderBase = \"draw_twirl\"\nlifeTime = 1.0\nstartColor = \"255 200 60 255\"\n")
		fp.close()
		var pdoc := OdfDocument.load_cached(p107_path)
		main.particle_lab.load_document(pdoc)
		await get_tree().process_frame
		# Multi-select + duplicate subgraph + compound undo in one step.
		main.particle_lab.select_headers(["RootEmit", "ChildFlame"])
		_check(main.particle_lab.get_selected_headers().size() == 2, "P1-07: multi-selection tracks 2 render nodes")
		var dup_sub: Array = main.particle_lab.duplicate_selected_subgraph()
		_check(dup_sub.size() == 2, "P1-07: duplicate_selected_subgraph created 2 linked headers")
		if dup_sub.size() >= 2:
			_check(pdoc.get_value(str(dup_sub[0]), "emitName", "") == str(dup_sub[1]), "P1-07: duplicated subgraph remapped internal emitName edge")
			pdoc.undo()
			_check(not pdoc.has_header(str(dup_sub[0])) and not pdoc.has_header(str(dup_sub[1])), "P1-07: compound undo removed entire duplicated subgraph in one step")
		else:
			_check(false, "P1-07: duplicated subgraph remapped internal emitName edge")
			_check(false, "P1-07: compound undo removed entire duplicated subgraph in one step")
		# Copy / paste.
		main.particle_lab.load_document(pdoc)
		main.particle_lab.select_headers(["ChildFlame"])
		var copied: Array = main.particle_lab.copy_selected_nodes()
		_check(copied.size() == 1, "P1-07: copy_selected_nodes captured header")
		var pasted: Array = main.particle_lab.paste_nodes()
		_check(pasted.size() == 1 and pdoc.has_header(str(pasted[0])), "P1-07: paste_nodes created cloned header")
		# Search / filter.
		var filtered: Array = main.particle_lab.filter_nodes("ChildFlame")
		_check(filtered.size() >= 1, "P1-07: node search filter matched ChildFlame")
		# Reusable preset + quick inspector live edit.
		var preset_h: String = main.particle_lab.insert_preset("fireball")
		_check(preset_h != "" and pdoc.get_value(preset_h, "renderBase", "") == "draw_twirl", "P1-07: emitter preset created documented draw_twirl header")
		_check(main.particle_lab.apply_quick_property(preset_h, "lifeTime", "2.75"), "P1-07: quick inspector edited lifeTime")
		_check(pdoc.get_value(preset_h, "lifeTime", "") == "2.75", "P1-07: quick inspector edit persisted on shared OdfDocument")
		# V8: cross-file render edit + coordinated multi-file save.
		var edoc := OdfDocument.load_cached(p107_ext_path)
		edoc.set_entry_value(edoc.find_entry("Glow", "lifeTime"), "1.9")
		main.particle_lab._external_nodes["ext_test"] = {"path": p107_ext_path, "header": "Glow"}
		var msave: Dictionary = main.particle_lab.save_with_external_dependencies()
		_check(bool(msave.get("ok", false)) and (msave.get("saved", []) as Array).size() >= 2, "V8: cross-file save_with_external_dependencies saved parent and external render ODFs")
		# T-27: Particle Lab UI SAVE DEPENDENCIES button + cross-file live preview refresh.
		_check(main.particle_lab.save_deps_button != null, "T-27 UI: Particle Lab SAVE DEPENDENCIES button present")
		var ext_disk_before := FileAccess.get_file_as_bytes(p107_ext_path)
		edoc.set_entry_value(edoc.find_entry("Glow", "startColor"), "\"20 250 120 255\"")
		var refreshed: bool = main.particle_lab.refresh_if_depends_on(edoc)
		_check(refreshed, "T-27 V7: cross-file external edit refreshed Particle Lab live preview")
		var green_em := false
		for em_p in main.particle_lab._emitters:
			if is_instance_valid(em_p) and em_p.color_ramp != null and em_p.color_ramp.get_color(0).g > 0.85 and em_p.color_ramp.get_color(0).r < 0.2:
				green_em = true
				break
		_check(green_em, "T-27 V7: live Particle Lab emitter reflects edited external startColor")
		_check(main.particle_lab.dirty_dependency_count() >= 1 and main.particle_lab.save_deps_button.text.contains("SAVE DEPENDENCIES ("), "T-27 V8: SAVE DEPENDENCIES badge tracks dirty external dependency")
		main.particle_lab.save_deps_button.pressed.emit()
		await get_tree().process_frame
		_check(main.particle_lab.dirty_dependency_count() == 0, "T-27 V8: clicking SAVE DEPENDENCIES saved dirty dependencies and cleared dirty state")
		_check(FileAccess.get_file_as_bytes(p107_ext_path) == ext_disk_before, "T-27 V8: original external ODF untouched on disk")

	# 3D Lab hardpoint picker, BBOX overlay, moving target, snapshot/compare & V9 audio timeline sync.
	if main.weapon_lab != null and main.weapon_lab.profile != null:
		_check(main.weapon_lab.hardpoint_option != null and main.weapon_lab.hardpoint_option.item_count >= 1, "3D Lab: hardpoint picker populated from .msh")
		var hps: Dictionary = main.weapon_lab.shooter_model_info.get("hardpoints", {})
		if hps.size() >= 2:
			var other_hp := str(hps.keys()[0])
			_check(main.weapon_lab.select_hardpoint(other_hp), "3D Lab: hardpoint picker switches active hardpoint")
			if hps.has("hp_cannon_1"):
				main.weapon_lab.select_hardpoint("hp_cannon_1")
		_check(main.weapon_lab.bbox_overlay != null and main.weapon_lab.bbox_overlay.mesh != null, "3D Lab: bounding-box overlay mesh rendered")
		var snap: Dictionary = main.weapon_lab.snapshot_shot_baseline()
		_check(not snap.is_empty() and float(snap.get("damage", 0.0)) > 0.0, "3D Lab: baseline shot snapshot captured")
		var cmp: Dictionary = main.weapon_lab.compare_with_snapshot()
		_check(bool(cmp.get("ok", false)), "3D Lab: before/after shot comparison succeeded")
		main.weapon_lab.restart_test()
		main.weapon_lab.fire_once()
		for _f in range(180):
			main.weapon_lab.sim.advance(1.0 / 60.0)
			main.weapon_lab._sync_projectiles()
			if not main.weapon_lab._any_alive():
				break
		var has_activate := false
		var has_sfx_or_impact := false
		for ev_item in main.weapon_lab.timeline_events:
			var k := str(ev_item.get("kind", ""))
			if k == "WEAPON_ACTIVATE":
				has_activate = true
			if k == "SFX_FIRE" or k == "SFX_XPL" or k == "IMPACT":
				has_sfx_or_impact = true
		_check(has_activate and has_sfx_or_impact, "V9: synchronized audiovisual timeline recorded weapon activation + audio/impact events")
		# T-26: Split native GUI controls wired through NativeExperimentRunner with isolated cleanup.
		_check(main.weapon_lab.native_preflight_button != null and main.weapon_lab.native_stage_button != null and main.weapon_lab.native_launch_button != null and main.weapon_lab.native_collect_button != null and main.weapon_lab.native_cleanup_button != null, "T-26 UI: all 5 split native controls (PREFLIGHT/STAGE/LAUNCH/COLLECT/CLEANUP) present")
		var ui_pre: Dictionary = main.weapon_lab.run_native_preflight_only()
		_check(str(ui_pre.get("session_id", "")) != "" and main.weapon_lab.active_native_session_id == str(ui_pre.get("session_id", "")), "T-26 UI: PREFLIGHT created active durable session")
		var ui_stg: Dictionary = main.weapon_lab.run_native_stage()
		_check(bool(ui_stg.get("ok", false)) and str(ui_stg.get("state", "")) == "STAGED", "T-26 UI: STAGE materialized isolated native stage")
		var ui_lch: Dictionary = main.weapon_lab.run_native_launch(false)
		_check(bool(ui_lch.get("ok", false)) and (str(ui_lch.get("state", "")) == "AWAITING_OPERATOR" or str(ui_lch.get("state", "")) == "LAUNCH_REQUESTED"), "T-26 UI: LAUNCH / HANDOFF prepared workflow cleanly")
		var ui_col: Dictionary = main.weapon_lab.run_native_collect()
		_check(not bool(ui_col.get("ok", true)) and str(ui_col.get("reason", "")) == "OBSERVATION_ARTIFACT_MISSING", "T-26 UI: COLLECT reports OBSERVATION_ARTIFACT_MISSING before game run")
		var ui_cln: Dictionary = main.weapon_lab.run_native_cleanup()
		_check(bool(ui_cln.get("ok", false)) and (str(ui_cln.get("state", "")) == "CLEANED_UP" or str(ui_cln.get("state", "")) == "PARTIAL_CLEANUP"), "T-26 UI: CLEANUP safely cleaned staged files")
		var stg_dir_ui := str((ui_stg.get("staged", {}) as Dictionary).get("stage", ""))
		if stg_dir_ui != "" and DirAccess.dir_exists_absolute(stg_dir_ui):
			_remove_tree(stg_dir_ui)

		# T-27: 3D Weapons Lab scene authoring, interactive Timeline panel, and bounded multichannel audio pool.
		_check(main.weapon_lab.camera_preset_option != null and main.weapon_lab.camera_preset_option.item_count == 5, "T-27 UI: 5 camera presets available")
		var cam_before: Vector3 = main.weapon_lab.camera.position
		_check(main.weapon_lab.apply_camera_preset("muzzle"), "T-27 UI: muzzle camera preset applied")
		_check(main.weapon_lab.camera.position.distance_to(cam_before) > 1.0, "T-27 UI: camera preset moved 3D camera")
		_check(main.weapon_lab.apply_camera_preset("top") and main.weapon_lab.apply_camera_preset("overview"), "T-27 UI: top and overview camera presets applied")
		main.weapon_lab.set_target_transform(Vector3(12.0, 0.0, 0.0), 30.0)
		_check(absf(main.weapon_lab.target_node.position.x - 12.0) < 0.01 and absf(main.weapon_lab.target_node.rotation_degrees.y - 30.0) < 0.01, "T-27 UI: target transform offset and yaw applied")
		main.weapon_lab.set_target_transform(Vector3.ZERO, 0.0)
		# Obstacle blocks fired shot in Weapons Lab 3D scene.
		var d_cur: float = main.weapon_lab.distance_slider.value
		main.weapon_lab.restart_test()
		var obs_rec: Dictionary = main.weapon_lab.add_obstacle(Vector3(0.0, 2.0, -d_cur * 0.5), Vector3(6.0, 5.0, 2.0), "TestCover")
		_check(main.weapon_lab.obstacles.size() == 1 and main.weapon_lab.obstacles_root.get_child_count() == 1, "T-27 UI: obstacle added to 3D scene")
		main.weapon_lab.fire_once()
		for _f2 in range(180):
			main.weapon_lab.sim.advance(1.0 / 60.0)
			main.weapon_lab._sync_projectiles()
			if not main.weapon_lab._any_alive():
				break
		var saw_obs_hit := false
		for ev_o in main.weapon_lab.timeline_events:
			if str(ev_o.get("kind", "")) == "OBSTACLE_HIT":
				saw_obs_hit = true
		_check(saw_obs_hit and absf(main.weapon_lab._current_health - main.weapon_lab.profile.target_health_max) < 0.01, "T-27 UI: 3D obstacle intercepted shot and protected target hull")
		main.weapon_lab.clear_obstacles()
		_check(main.weapon_lab.obstacles.is_empty(), "T-27 UI: clear_obstacles removed obstacle")
		# Secondary target in line of fire takes independent damage.
		main.weapon_lab.restart_test()
		var aux_rec: Dictionary = main.weapon_lab.add_extra_target(Vector3(0.0, 2.0, -d_cur * 0.5), "AuxTarget", 500.0)
		main.weapon_lab.fire_once()
		for _f3 in range(180):
			main.weapon_lab.sim.advance(1.0 / 60.0)
			main.weapon_lab._sync_projectiles()
			if not main.weapon_lab._any_alive():
				break
		_check(float(aux_rec.get("health", 500.0)) < 500.0 and absf(main.weapon_lab._current_health - main.weapon_lab.profile.target_health_max) < 0.01, "T-27 UI: secondary target took independent damage while primary stayed untouched")
		main.weapon_lab.clear_extra_targets()
		# Interactive Timeline panel + bounded 8-channel audio pool.
		_check(main.weapon_lab.timeline_tree != null and main.weapon_lab.timeline_scrub_slider != null, "T-27 UI: interactive Timeline panel controls present")
		_check(main.weapon_lab.audio_pool.size() == main.weapon_lab.AUDIO_POOL_SIZE, "T-27 V9: bounded multichannel audio pool initialized to %d channels" % main.weapon_lab.AUDIO_POOL_SIZE)
		for _b in range(12):
			main.weapon_lab._play_sound_asset(main.weapon_lab.profile.fire_sound, main.weapon_lab.profile.weapon_path, "SFX_FIRE")
		_check(main.weapon_lab.audio_pool.size() == main.weapon_lab.AUDIO_POOL_SIZE, "T-27 V9: audio pool remains strictly bounded at %d after 12 rapid plays" % main.weapon_lab.AUDIO_POOL_SIZE)
		var audio_only: Array = main.weapon_lab.filter_timeline("audio")
		_check(not audio_only.is_empty(), "T-27 UI: Timeline filter('audio') returned SFX events")
		var scrubbed: Dictionary = main.weapon_lab.scrub_timeline_to(0.0)
		_check(not scrubbed.is_empty(), "T-27 UI: Timeline scrub_timeline_to(0.0) selected event")
		var sel_ev: Dictionary = main.weapon_lab.select_timeline_event(0)
		_check(not sel_ev.is_empty(), "T-27 UI: select_timeline_event emitted selection cleanly")
		main.weapon_lab.filter_timeline("all")

		# T-29: Houdini scrubbers, resizable splitters, 2D HUD mesh tags, categorized catalog, A/B picker, Font AA, UI scale, Master Volume.
		_check(main.weapon_lab.yaw_spin.has_method("begin_ladder") and main.weapon_lab.speed_spin.has_method("begin_ladder"), "T-29 UI: Weapons Lab numeric controls use HoudiniScrubber")
		_check(main.particle_lab.speed_spin.has_method("begin_ladder"), "T-29 UI: Particle Lab speed uses HoudiniScrubber")
		_check(main.main_hsplit.dragger_visibility == SplitContainer.DRAGGER_VISIBLE and main.right_hsplit.dragger_visibility == SplitContainer.DRAGGER_VISIBLE and main.weapon_lab.lab_vsplit.dragger_visibility == SplitContainer.DRAGGER_VISIBLE, "T-29 UI: all horizontal and vertical splitters have visible draggers")
		_check(main.weapon_lab._hud_tags.size() >= 2 and main.weapon_lab.hud_labels_layer != null, "T-29 UI: crisp 2D HUD mesh labels rendered above Shooter A and Target B")
		_check(main.collection_filter_option != null and main.collection_filter_option.item_count >= 5 and main.category_filter_option != null, "T-29 UI: Stock/VSR/VRV/Mods collection and category filters present")
		_check(main.weapon_lab.pick_a_button != null and main.weapon_lab.pick_b_button != null and main.weapon_lab.swap_ab_button != null, "T-29 UI: Pick A (Shooter), Pick B (Target), and Swap A/B controls present")
		_check(main.font_aa_option != null and main.theme_engine.font_aa_mode == "none", "T-29 UI: No-AA crisp font active by default with top-bar selector")
		main.apply_ui_scale(1.15)
		_check(absf(main.ui_scale - 1.15) < 0.01, "T-29 UI: UI scale control updates scale factor")
		main.apply_ui_scale(1.0)
		main.apply_master_volume(0.5, false)
		_check(absf(main.master_volume - 0.5) < 0.01 and not main.master_muted, "T-29 UI: master audio volume control updates AudioServer bus")

		# T-30: Embedded Verdana_m1 12px pixel-perfect theme, E2E combat chain bar, Inspector chain breadcrumb, property filter, 1-click override, and 5-tab workbench.
		_check(main.theme != null and main.theme.default_font != null and main.theme.default_font.get_font_name().begins_with("Verdana") and main.theme.default_font_size == 12, "T-30 UI: main window uses embedded Verdana_m1 at 12px default")
		_check(main.weapon_lab.chain_a_button != null and main.weapon_lab.chain_wpn_button != null and main.weapon_lab.chain_ord_button != null and main.weapon_lab.chain_xpl_button != null and main.weapon_lab.chain_b_button != null, "T-30 UI: Weapons Lab E2E combat chain bar (A -> Wpn -> Ord -> Xpl | B) present")
		_check(main.weapon_lab.bottom_tabs != null and main.weapon_lab.bottom_tabs.get_tab_count() == 5, "T-30 UI: Weapons Lab bottom workbench consolidated into 5 focused tabs")
		main.weapon_lab.chain_ord_button.pressed.emit()
		await get_tree().process_frame
		_check(main.current_doc != null and main.current_doc.source_path.get_file().to_lower() == "atstabvsr_c.odf", "T-30 UI: clicking E2E chain Ordnance button opens atstabvsr_c.odf in Right Inspector")
		_check(main.inspector_chain_bar != null and main.inspector_chain_bar.get_child_count() >= 5, "T-30 UI: Right Inspector displays E2E chain breadcrumb navigation strip")
		_check(main.inspector_filter_edit != null and main.has_method("_send_selection_to_lab"), "T-30 UI: Inspector property filter and Explorer Send to Lab action present")
		main.weapon_lab.chain_a_button.pressed.emit()
		await get_tree().process_frame
		if main.current_doc != null and main.current_doc.source_path.get_file().to_lower() == "ivtank_vsr.odf":
			var had_local: bool = main.current_doc.find_entry("CraftClass", "engageRange") != null
			var ov_ok: bool = main.override_inherited_property("CraftClass", "engageRange", "175")
			_check(ov_ok and main.current_doc.find_entry("CraftClass", "engageRange") != null, "T-30 UI: 1-click [+ Override] promotes inherited property into local ODF")
			if not had_local:
				main.current_doc.undo()
				main._rebuild_inspector()

		# T-31: Reset to Default buttons everywhere, in-game names (Scavenger/Sabre), UI scale 1bpp integer strike scaling, Particle Lab auto-context & P1-05 partial-save recovery, P1-06 Houdini mouse events.
		_check(main.reset_all_button != null and main.reset_ui_button != null and main.reset_doc_button != null, "T-31 UI: Reset All, Reset UI, and Reset ODF buttons present")
		_check(main.weapon_lab.reset_ab_button != null and main.weapon_lab.reset_aim_button != null and main.weapon_lab.reset_scene_button != null, "T-31 UI: Weapons Lab Reset A/B, Reset Aim, and Reset Scene buttons present")
		_check(main.particle_lab.reset_odf_button != null and main.particle_lab.reset_view_button != null, "T-31 UI: Particle Lab RESET ODF and RESET VIEW buttons present")
		_check(main.weapon_lab.native_handoff_button != null and main.weapon_lab.native_compare_button != null, "T-31 P0-01 UI: distinct LAUNCH BZCC, MANUAL STEAM HANDOFF, and COMPARE controls present")
		_check(main.loadout_option != null and main.index.active_packages.has("3532748119"), "T-31 P1-08 UI: Loadout selector active with VSR 3532748119 package")
		_check(main.weapon_lab.chain_a_button.text.contains("Tank") and main.weapon_lab.chain_b_button.text.contains("Scavenger"), "T-31 UI: Weapons Lab chain buttons display in-game names (Tank / Scavenger)")
		# UI scale integer 1bpp bitmap strike scaling without fractional content_scale_factor distortion:
		main.apply_ui_scale(1.25)
		_check(main.theme.default_font_size == 15 and absf(main.get_window().content_scale_factor - 1.0) < 0.01, "T-31 UI: 125% UI scale selects 15px 1bpp Verdana_m1 strike at 1:1 native pixels")
		main.apply_ui_scale(0.85)
		_check(main.theme.default_font_size == 10 and absf(main.get_window().content_scale_factor - 1.0) < 0.01, "T-31 UI: 85% UI scale selects 10px 1bpp Verdana_m1 strike at 1:1 native pixels")
		main.reset_ui_to_default()
		_check(main.theme.default_font_size == 12 and absf(main.ui_scale - 1.0) < 0.01, "T-31 UI: Reset UI restores 12px 100% Golden Default")
		# Per-property reset_entry_to_default & per-ODF reset_current_doc_to_default:
		if main.current_doc != null:
			var e_mass = main.current_doc.find_entry("GameObjectClass", "mass")
			if e_mass != null:
				var orig_mass := str(e_mass.value_raw)
				main.current_doc.set_entry_value(e_mass, "99999.0")
				main._after_edit()
				_check(main.reset_entry_to_default(e_mass) and str(e_mass.value_raw) == orig_mass, "T-31 UI: per-property Reset restores factory default value")
			main.override_inherited_property("GameObjectClass", "scrapCost", "99")
			var e_ov = main.current_doc.find_entry("GameObjectClass", "scrapCost")
			_check(e_ov != null and main.reset_entry_to_default(e_ov) and main.current_doc.find_entry("GameObjectClass", "scrapCost") == null, "T-31 UI: per-property Reset removes local override and reverts to inherited parent value")
		# Particle Lab auto-context & instant NEW NODE creation:
		main.particle_lab.bind_context_document(main.current_doc, main.weapon_lab.profile)
		_check(main.particle_lab.doc != null and main.particle_lab.context_effects_bar.get_child_count() >= 2, "T-31 UI: Particle Lab auto-configures context effects from active ODF/chain")
		var before_cnt: int = main.particle_lab.doc.render_headers().size()
		main.particle_lab.new_button.pressed.emit()
		await get_tree().process_frame
		_check(main.particle_lab.doc.render_headers().size() == before_cnt + 1 and main.particle_lab._selected_header != "" and main.particle_lab.quick_inspector_box.get_child_count() >= 3, "T-31 UI: clicking NEW NODE immediately creates render node and populates Quick Render Inspector")
		main.particle_lab.reset_document_to_default()
		_check(main.particle_lab.doc.render_headers().size() == before_cnt, "T-31 UI: Particle Lab RESET ODF restores factory render headers")
		# P1-05: Particle Lab partial multi-file save recovery:
		var p105_a := ProjectSettings.globalize_path(test_root.path_join("p105_a.odf"))
		var p105_b := ProjectSettings.globalize_path(test_root.path_join("p105_b.odf"))
		var fa := FileAccess.open(p105_a, FileAccess.WRITE)
		fa.store_string("[Root]\nrenderBase = \"draw_emit\"\nrenderName1 = \"p105_b.Child\"\nlifeTime = 1.0\n")
		fa.close()
		var fb := FileAccess.open(p105_b, FileAccess.WRITE)
		fb.store_string("[Child]\nrenderBase = \"draw_twirl\"\nlifeTime = 1.0\n")
		fb.close()
		var doc_a = OdfDocument.load_cached(p105_a)
		var doc_b = OdfDocument.load_cached(p105_b)
		main.particle_lab.load_document(doc_a)
		doc_a.set_entry_value(doc_a.find_entry("Root", "lifeTime"), "2.5")
		doc_b.set_entry_value(doc_b.find_entry("Child", "lifeTime"), "3.5")
		var p_fail: Dictionary = main.particle_lab.save_with_external_dependencies({"fail_on_path": p105_b})
		_check(not bool(p_fail.get("ok", true)) and str(p_fail.get("status", "")) == "PARTIAL_SAVE_RECOVERABLE", "T-31 P1-05: forced failure on 2nd file reports PARTIAL_SAVE_RECOVERABLE")
		var p_rec: Dictionary = main.particle_lab.recover_partial_save_group()
		_check(bool(p_rec.get("ok", false)) and doc_a.get_value("Root", "lifeTime", "") == "1.0", "T-31 P1-05: recover_partial_save_group restored pre-save revision cleanly")
		# P1-06: HoudiniScrubber physical mouse interaction & exact value integrity:
		var hs = main.weapon_lab.yaw_spin
		hs.set_exact_value(0.000125, "0.000125")
		_check(str(hs._format_display(hs.value)).contains("0.000125"), "T-31 P1-06: HoudiniScrubber preserves exact high-precision ODF representation")
		var mmb_down := InputEventMouseButton.new()
		mmb_down.button_index = MOUSE_BUTTON_MIDDLE
		mmb_down.pressed = true
		mmb_down.global_position = Vector2(400, 300)
		hs._on_pill_gui_input(mmb_down)
		_check(hs._ladder_active and hs._ladder_panel != null, "T-31 H-01: physical MMB press opens Houdini Value Ladder overlay")
		var mm_vert := InputEventMouseMotion.new()
		mm_vert.global_position = Vector2(400, 344)
		hs._input(mm_vert)
		var mm_horiz := InputEventMouseMotion.new()
		mm_horiz.global_position = Vector2(436, 344)
		hs._input(mm_horiz)
		_check(hs.value > 0.000125, "T-31 H-02/H-03: physical mouse motion selects sensitivity rung and scrubs value")
		var mmb_up := InputEventMouseButton.new()
		mmb_up.button_index = MOUSE_BUTTON_MIDDLE
		mmb_up.pressed = false
		mmb_up.global_position = Vector2(700, 700)
		hs._input(mmb_up)
		_check(not hs._ladder_active, "T-31 H-04: physical MMB release outside control closes Value Ladder")
		var rmb_click := InputEventMouseButton.new()
		rmb_click.button_index = MOUSE_BUTTON_RIGHT
		rmb_click.pressed = true
		hs._on_pill_gui_input(rmb_click)
		_check(absf(hs.value - 0.0) < 0.0001, "T-31 UI: RMB on HoudiniScrubber resets value to default (0.0)")

		# Wave B (T-32): RST-01..RST-14 UI & workflow regressions + Live-Swap.
		var rst_dir := ProjectSettings.globalize_path(test_root.path_join("rst_suite"))
		DirAccess.make_dir_recursive_absolute(rst_dir)
		var rst_a := rst_dir.path_join("pkg1_a.odf")
		var rst_b := rst_dir.path_join("pkg1_b.odf")
		var rst_c := rst_dir.path_join("pkg2/pkg2_c.odf")
		DirAccess.make_dir_recursive_absolute(rst_c.get_base_dir())
		var f_ra := FileAccess.open(rst_a, FileAccess.WRITE); f_ra.store_string("[OrdnanceClass]\ndamageValue(H)=100\n"); f_ra.close()
		var f_rb := FileAccess.open(rst_b, FileAccess.WRITE); f_rb.store_string("[OrdnanceClass]\ndamageValue(H)=120\n"); f_rb.close()
		var f_rc := FileAccess.open(rst_c, FileAccess.WRITE); f_rc.store_string("[OrdnanceClass]\ndamageValue(H)=140\n"); f_rc.close()
		var da := OdfDocument.load_cached(rst_a)
		da.set_entry_value(da.find_entry("OrdnanceClass", "damageValue(H)"), "201")
		WorkspaceStore.save_document_with_rel(da, "pkg1_a.odf")
		var db := OdfDocument.load_cached(rst_b)
		db.set_entry_value(db.find_entry("OrdnanceClass", "damageValue(H)"), "202")
		var dc := OdfDocument.load_cached(rst_c)
		dc.set_entry_value(dc.find_entry("OrdnanceClass", "damageValue(H)"), "203")
		WorkspaceStore.save_document_with_rel(dc, "pkg2/pkg2_c.odf")

		# RST-01 / RST-02 / RST-03: Reset All requires confirmation, enumerates A/B/C, Cancel preserves all.
		var req_all: Dictionary = main.reset_all_odfs_to_default(false)
		_check(bool(req_all.get("confirmation_required", false)) and str(req_all.get("status", "")) == "CONFIRMATION_REQUIRED", "RST-01: Reset All requires explicit confirmation before mutating")
		var imp_files: Array = (req_all.get("impact", {}) as Dictionary).get("affected_files", [])
		var has_a := false; var has_b := false; var has_c := false
		for af in imp_files:
			if WorkspaceStore._same_canon_path(str(af), rst_a): has_a = true
			if WorkspaceStore._same_canon_path(str(af), rst_b): has_b = true
			if WorkspaceStore._same_canon_path(str(af), rst_c): has_c = true
		_check(has_a and has_b and has_c, "RST-03: Reset All impact preview enumerates A (saved), B (dirty), and C (other package)")
		main.cancel_reset_all_odfs()
		_check(da.get_value("OrdnanceClass", "damageValue(H)") == "201" and db.get_value("OrdnanceClass", "damageValue(H)") == "202" and dc.get_value("OrdnanceClass", "damageValue(H)") == "203", "RST-02: Cancel Reset All preserves A, B, and C unchanged")

		# RST-06: Reset current ODF does not change other ODFs.
		main.open_document(rst_b)
		await get_tree().process_frame
		_check(main.reset_current_doc_to_default() and db.get_value("OrdnanceClass", "damageValue(H)") == "120", "RST-06: Reset current ODF restores B to factory 120")
		_check(da.get_value("OrdnanceClass", "damageValue(H)") == "201" and dc.get_value("OrdnanceClass", "damageValue(H)") == "203", "RST-06: Reset current ODF leaves A and C untouched")

		# RST-08: Reset selected counts actual successes vs failures (1 ok, 1 failed).
		var rst_ok_p := rst_dir.path_join("cnt_ok.odf")
		var rst_bad_p := rst_dir.path_join("cnt_missing.odf")
		var f_ok := FileAccess.open(rst_ok_p, FileAccess.WRITE); f_ok.store_string("[A]\nx=1\n"); f_ok.close()
		var f_bad := FileAccess.open(rst_bad_p, FileAccess.WRITE); f_bad.store_string("[A]\nx=1\n"); f_bad.close()
		var dok := OdfDocument.load_cached(rst_ok_p); dok.set_entry_value(dok.find_entry("A", "x"), "9")
		var dbad := OdfDocument.load_cached(rst_bad_p); dbad.set_entry_value(dbad.find_entry("A", "x"), "9")
		DirAccess.remove_absolute(rst_bad_p)
		var mix_rep: Dictionary = main.reset_selected_odfs_to_default([rst_ok_p, rst_bad_p, rst_ok_p], true)
		_check(int(mix_rep.get("requested", 0)) == 2 and int(mix_rep.get("succeeded", 0)) == 1 and int(mix_rep.get("failed", 0)) == 1 and not bool(mix_rep.get("ok", true)), "RST-08: deduplicated reset report accurately reports requested=2, succeeded=1, failed=1")

		# RST-01 confirm: Confirm Reset All restores A and C with recovery point.
		db.set_entry_value(db.find_entry("OrdnanceClass", "damageValue(H)"), "202")
		var conf_all: Dictionary = main.confirm_reset_all_odfs()
		_check(str(conf_all.get("recovery_point", "")) != "" and FileAccess.file_exists(str(conf_all.get("recovery_point", ""))), "RST-14 UI: confirmed Reset All creates durable recovery point")
		_check(da.get_value("OrdnanceClass", "damageValue(H)") == "100" and db.get_value("OrdnanceClass", "damageValue(H)") == "120" and dc.get_value("OrdnanceClass", "damageValue(H)") == "140", "RST-01/13 UI: confirmed Reset All restores A, B, and C to factory defaults")

		# RST-07: Particle Lab RESET THIS ODF does NOT silently reset external files B and C;
		# RESET DEPENDENCY GRAPH requires explicit confirmation.
		var pl_a := rst_dir.path_join("pl_a.odf")
		var pl_b := rst_dir.path_join("pl_b.odf")
		var pl_c := rst_dir.path_join("pl_c.odf")
		var fpa := FileAccess.open(pl_a, FileAccess.WRITE); fpa.store_string("[Root]\nrenderBase = \"draw_emit\"\nrenderName1 = \"pl_b.NodeB\"\nrenderName2 = \"pl_c.NodeC\"\nlifeTime = 1.0\n"); fpa.close()
		var fpb := FileAccess.open(pl_b, FileAccess.WRITE); fpb.store_string("[NodeB]\nrenderBase = \"draw_sprite\"\nlifeTime = 2.0\n"); fpb.close()
		var fpc := FileAccess.open(pl_c, FileAccess.WRITE); fpc.store_string("[NodeC]\nrenderBase = \"draw_twirl\"\nlifeTime = 3.0\n"); fpc.close()
		var pda := OdfDocument.load_cached(pl_a); pda.set_entry_value(pda.find_entry("Root", "lifeTime"), "9.0")
		var pdb := OdfDocument.load_cached(pl_b); pdb.set_entry_value(pdb.find_entry("NodeB", "lifeTime"), "8.0")
		var pdc := OdfDocument.load_cached(pl_c); pdc.set_entry_value(pdc.find_entry("NodeC", "lifeTime"), "7.0")
		main.particle_lab.load_document(pda)
		main.particle_lab._external_nodes["ext_b"] = {"path": pl_b, "header": "NodeB"}
		main.particle_lab._external_nodes["ext_c"] = {"path": pl_c, "header": "NodeC"}
		var pl_res: Dictionary = main.particle_lab.reset_document_to_default()
		_check(bool(pl_res.get("ok", false)) and pda.get_value("Root", "lifeTime") == "1.0" and pdb.get_value("NodeB", "lifeTime") == "8.0" and pdc.get_value("NodeC", "lifeTime") == "7.0", "RST-07: Particle Lab RESET ODF resets A only; external B and C remain unchanged")
		var dep_req: Dictionary = main.particle_lab.reset_document_to_default(main.particle_lab.RESET_SCOPE_DEPENDENCY_GRAPH, false)
		_check(bool(dep_req.get("confirmation_required", false)) and pdb.get_value("NodeB", "lifeTime") == "8.0", "RST-07: Particle Lab RESET DEPENDENCY GRAPH requires explicit confirmation")
		var dep_ok: Dictionary = main.particle_lab.confirm_dependency_graph_reset()
		_check(bool(dep_ok.get("ok", false)) and pdb.get_value("NodeB", "lifeTime") == "2.0" and pdc.get_value("NodeC", "lifeTime") == "3.0", "RST-07: confirmed RESET DEPENDENCY GRAPH restores B and C with recovery point")

		# RST-10: External source modification invalidates _factory_doc_cache between resets.
		var ext_src := rst_dir.path_join("ext_change.odf")
		var fex := FileAccess.open(ext_src, FileAccess.WRITE); fex.store_string("[Core]\nvalue=10\n"); fex.close()
		main.open_document(ext_src)
		await get_tree().process_frame
		var e_val = main.current_doc.find_entry("Core", "value")
		main.current_doc.set_entry_value(e_val, "99")
		_check(main.reset_entry_to_default(e_val) and main.current_doc.get_value("Core", "value") == "10", "RST-10: first reset uses original factory value 10")
		var fex2 := FileAccess.open(ext_src, FileAccess.WRITE); fex2.store_string("[Core]\nvalue=42\n"); fex2.close()
		e_val = main.current_doc.find_entry("Core", "value")
		main.current_doc.set_entry_value(e_val, "88")
		_check(main.reset_entry_to_default(e_val) and main.current_doc.get_value("Core", "value") == "42", "RST-10: second reset after external source change invalidates cache and uses 42")

		# RST-11 UI: Particle Lab Reset Node removes custom added properties.
		var pn_src := rst_dir.path_join("pn_custom.odf")
		var fpn := FileAccess.open(pn_src, FileAccess.WRITE); fpn.store_string("[Core]\nrenderBase=draw_sprite\nlifeTime=1\n\n[Keep]\nx=7\n"); fpn.close()
		var pnd := OdfDocument.load_cached(pn_src)
		pnd.set_entry_value(pnd.find_entry("Core", "lifeTime"), "5")
		pnd.append_entry("Core", "customValue", "99")
		main.particle_lab.load_document(pnd)
		_check(main.particle_lab.reset_header_to_default("Core") and pnd.get_value("Core", "lifeTime") == "1" and pnd.find_entry("Core", "customValue") == null and pnd.get_value("Keep", "x") == "7", "RST-11 UI: Particle Lab Reset Node restores factory header, removes customValue, keeps [Keep]")

		# RST-12: Reset UI preserves active non-VSR mod loadout.
		main.apply_active_loadout("3820486276", true)
		_check(main.index.active_packages.has("3820486276"), "RST-12 setup: switched active loadout to VRV 3820486276")
		main.apply_ui_scale(1.5)
		main.apply_master_volume(0.25, true)
		main.reset_ui_to_default()
		_check(main.theme_engine.current_slug == "goldendefault" and absf(main.ui_scale - 1.0) < 0.01 and absf(main.master_volume - 0.85) < 0.01 and not main.master_muted, "RST-12: Reset UI restores Golden Default, scale, and volume")
		_check(main.index.active_packages.has("3820486276") and main.active_loadout_id == "3820486276", "RST-12: Reset UI preserves active mod loadout 3820486276")
		main.reset_mod_loadout_to_default()
		_check(main.index.active_packages.has("3532748119"), "RST-12: explicit Reset Mod Loadout restores VSR 3532748119")

		# Live-Swap control present and functional.
		_check(main.live_swap_option != null and main.live_swap_option.item_count >= 5, "T-36 UI: Live-Swap selector includes Off/Object A/Object B/Weapon/Auto")

		# T-36 UI: Rigid floors, Titan lightning BoltBeamNode, Sandbox props/motion/aim, Texture Browser, Emitter metrics, RMB resets
		_check(main.weapon_lab.ground_body is StaticBody3D, "T-36 UI: Weapons Lab has rigid StaticBody3D floor")
		_check(main.particle_lab.preview_floor_body is StaticBody3D, "T-36 UI: Particle Lab has rigid StaticBody3D floor")
		_check(main.particle_lab.EMITTER_PRESETS.size() >= 10, "T-36 UI: Particle Lab exposes >=10 ready emitter presets")

		# Titan lightning (fvatank -> garc_c -> arcbolt & garc_a Arc Stream)
		var titan_path: String = main.index.resolve_path("fvatank.odf")
		var scav_stock: String = main.index.resolve_path("ivscav.odf")
		if titan_path != "" and scav_stock != "":
			main.weapon_lab.set_shooter(titan_path)
			main.weapon_lab.set_target(scav_stock)
			await get_tree().process_frame
			main.weapon_lab.fire_once()
			await get_tree().process_frame
			_check(main.weapon_lab.last_bolt_node != null and is_instance_valid(main.weapon_lab.last_bolt_node), "T-36 UI: Titan fire_once spawns live world-space BoltBeamNode lightning")
			main.weapon_lab.sim.advance(0.05)
			main.weapon_lab._sync_projectiles()
			_check(is_instance_valid(main.weapon_lab.last_bolt_node) and main.weapon_lab.last_bolt_node.get_parent() == main.weapon_lab.effect_root, "T-36 UI: Titan lightning persists in effect_root after hitscan shot completes")
			main.weapon_lab.last_bolt_node = null
			main.weapon_lab.fire_alt()
			await get_tree().process_frame
			_check(main.weapon_lab.last_bolt_node != null and is_instance_valid(main.weapon_lab.last_bolt_node), "T-36 UI: Titan fire_alt (garc_a Arc Stream) spawns BoltBeamNode")
			# Live-Swap weapon mode
			var garc_a_path: String = main.index.resolve_path("garc_a.odf")
			if garc_a_path != "":
				main.set_live_swap_mode("weapon")
				main._apply_live_swap_for_path(garc_a_path)
				_check(main.weapon_lab.profile != null and main.weapon_lab.profile.weapon_name.to_lower() == "garc_a", "T-36 UI: Live-Swap Weapon mode swaps active weapon on Object A to garc_a")
			main.set_live_swap_mode("off")

		# Sandbox Moving Target + Aim modes + placeable Wall/Terrain Ramp/Pillar
		main.weapon_lab.set_target_motion_mode("wiggle", true)
		_check(main.weapon_lab.target_motion_mode == "wiggle" and float(main.weapon_lab.target_speed_spin.value) > 0.0, "T-36 UI: Moving Target wiggle mode active")
		var tpos_before: Vector3 = main.weapon_lab.target_node.position
		main.weapon_lab._process(0.15)
		_check(main.weapon_lab.target_node.position.distance_to(tpos_before) > 0.05, "T-36 UI: wiggling Moving Target updates 3D position live")
		main.weapon_lab.set_shooter_aim_mode("lead")
		_check(main.weapon_lab.shooter_aim_mode == "lead", "T-36 UI: Shooter Aim mode switches to Lead Target")
		var w_rec: Dictionary = main.weapon_lab.add_wall(Vector3(0, 3, -40))
		var r_rec: Dictionary = main.weapon_lab.add_terrain_ramp(Vector3(12, 2.5, -50))
		var pil_rec: Dictionary = main.weapon_lab.add_pillar(Vector3(-12, 4, -50))
		_check(w_rec.get("node", null) is StaticBody3D and str(r_rec.get("shape", "")) == "ramp" and pil_rec.get("node", null) is StaticBody3D, "T-36 UI: Sandbox Wall, Terrain Ramp, and Pillar create rigid StaticBody3D props")
		main.weapon_lab.reset_scene_to_default()
		_check(main.weapon_lab.obstacles.is_empty() and main.weapon_lab.shooter_aim_mode == "manual", "T-36 UI: Reset Scene clears sandbox props and restores manual aim")

		# Particle Lab Texture Browser + Emitter inspection + Mute/Solo
		var fx_textures: Array = main.particle_lab.list_available_textures("", "fx", 120)
		_check(fx_textures.size() >= 20, "T-36 UI: Particle Lab Texture Browser indexes >=20 real BZCC FX textures (%d)" % fx_textures.size())
		var xpl_demo: String = main.index.resolve_path("xcoreturrxpl.odf")
		if xpl_demo != "":
			var xdoc := OdfDocument.load_cached(xpl_demo)
			main.particle_lab.load_document(xdoc)
			main.particle_lab.select_headers(["Core"])
			var em_m: Dictionary = main.particle_lab.inspect_emitter_metrics("Core")
			_check(float(em_m.get("emission_rate_hz", 0.0)) > 0.0 and str(em_m.get("cost_tier", "")) != "", "T-36 UI: Particle Lab emitter inspection computes rate and cost tier")
			main.particle_lab.set_emitter_muted("Core", true)
			_check(main.particle_lab._muted_headers.has("core"), "T-36 UI: Particle Lab Mute toggle mutes emitter")
			main.particle_lab.set_emitter_muted("Core", false)
			main.particle_lab.set_emitter_solo("Core", true)
			_check(main.particle_lab._solo_header == "core", "T-36 UI: Particle Lab Solo toggle isolates emitter")
			main.particle_lab.set_emitter_solo("Core", false)
			var cnt_tex: int = main.particle_lab.open_texture_browser("Core")
			_check(cnt_tex >= 20, "T-36 UI: open_texture_browser populates >=20 visual texture items")
			if main.particle_lab._texture_dialog != null:
				main.particle_lab._texture_dialog.hide()

		# RMB reset on HoudiniScrubber slider and WeaponLab distance_slider
		var s_rmb := HoudiniScrubber.new()
		s_rmb.configure(0.0, 200.0, 1.0, 50.0, "", true, true, false)
		s_rmb.set_default_value(50.0)
		s_rmb.value = 135.0
		var rmb_ev := InputEventMouseButton.new()
		rmb_ev.button_index = MOUSE_BUTTON_RIGHT
		rmb_ev.pressed = true
		s_rmb._on_slider_gui_input(rmb_ev)
		_check(absf(s_rmb.value - 50.0) < 0.01, "T-36 UI: RMB on HoudiniScrubber slider resets value to default (50.0)")
		s_rmb.free()
		main.weapon_lab.distance_spin.set_default_value(120.0)
		main.weapon_lab.distance_slider.value = 260.0
		main.weapon_lab.distance_slider.gui_input.emit(rmb_ev)
		_check(absf(main.weapon_lab.distance_slider.value - 120.0) < 0.1, "T-36 UI: RMB on WeaponLab distance_slider resets range to default (120 m)")

		# T-34 UI: Persistent ModLoadout save/load, Saved 3D Scene Presets, Camera Bookmarks
		var ml_save: Dictionary = main.save_loadout_profile("smoke_vsr_vrv", "Smoke VSR+VRV", ["3532748119", "3820486276"])
		_check(bool(ml_save.get("ok", false)), "T-34 UI: save_loadout_profile persisted ModLoadout JSON")
		_check(main.list_loadout_profiles().size() >= 1, "T-34 UI: list_loadout_profiles lists saved ModLoadout profile")
		main.apply_active_loadout("auto", false)
		var ml_load: Dictionary = main.load_loadout_profile("smoke_vsr_vrv", false)
		_check(bool(ml_load.get("ok", false)) and main.index.active_packages == ["3532748119", "3820486276"], "T-34 UI: load_loadout_profile restores multi-package priority [3532748119, 3820486276]")
		main.apply_active_loadout("3532748119", false)

		# Saved 3D Scene Presets & Camera Bookmarks
		main.weapon_lab.distance_slider.value = 155.0
		main.weapon_lab.set_target_motion_mode("orbit", true)
		main.weapon_lab.set_shooter_aim_mode("track")
		main.weapon_lab.add_wall(Vector3(4, 3, -65))
		main.weapon_lab.add_terrain_ramp(Vector3(-8, 2.5, -55))
		var cb_res: Dictionary = main.weapon_lab.save_camera_bookmark("titan_angle")
		_check(bool(cb_res.get("ok", false)) and main.weapon_lab.list_camera_bookmarks().has("titan_angle"), "T-34 UI: save_camera_bookmark persists camera state")
		var sp_res: Dictionary = main.weapon_lab.save_scene_preset("sandbox_test")
		_check(bool(sp_res.get("ok", false)) and main.weapon_lab.list_scene_presets().has("sandbox_test"), "T-34 UI: save_scene_preset persists sandbox actors, motion, aim, and props")
		main.weapon_lab.reset_scene_to_default()
		main.weapon_lab.apply_camera_preset("top")
		_check(main.weapon_lab.obstacles.is_empty(), "T-34 UI: scene reset cleared obstacles before reload")
		var sp_load: Dictionary = main.weapon_lab.load_scene_preset("sandbox_test")
		_check(bool(sp_load.get("ok", false)) and main.weapon_lab.obstacles.size() == 2 and main.weapon_lab.target_motion_mode == "orbit" and main.weapon_lab.shooter_aim_mode == "track", "T-34 UI: load_scene_preset restores Wall+Ramp obstacles, orbit motion, and track aim")
		_check(main.weapon_lab.apply_camera_bookmark("titan_angle") and main.weapon_lab.active_camera_preset == "bookmark:titan_angle", "T-34 UI: apply_camera_bookmark restores saved camera view")
		main.weapon_lab.reset_scene_to_default()

	_cleanup_test_root()
	print("UI smoke: %d failure(s)" % failures.size())
	if failures.is_empty():
		print("RESULT: PASS")
		get_tree().quit(0)
	else:
		for f in failures:
			printerr("FAIL: " + f)
		print("RESULT: FAIL")
		get_tree().quit(1)


func _cleanup_test_root() -> void:
	if test_root == "" or not test_root.begins_with("user://smoke_workspace_"):
		return
	var abs := ProjectSettings.globalize_path(test_root)
	if DirAccess.dir_exists_absolute(abs):
		_remove_tree(abs)


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
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


func _graph_node(lab, header: String):
	for n in lab.graph.get_children():
		if n is GraphNode and str(n.get_meta("header", "")) == header:
			return n
	return null


func opened_doc_has(main, header: String) -> bool:
	return main.current_doc != null and main.current_doc.has_header(header)


func _find_button(node: Node) -> Button:
	if node is Button:
		return node
	for c in node.get_children():
		var hit := _find_button(c)
		if hit != null:
			return hit
	return null


func _find_exported(root: String, filename: String) -> String:
	var dir := DirAccess.open(root)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if n != "." and n != "..":
			var full := root.path_join(n)
			if dir.current_is_dir():
				var hit := _find_exported(full, filename)
				if hit != "":
					dir.list_dir_end()
					return hit
			elif n.to_lower() == filename.to_lower():
				dir.list_dir_end()
				return full
		n = dir.get_next()
	dir.list_dir_end()
	return ""


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ " + msg)
	else:
		failures.append(msg)
		printerr("  ✗ " + msg)
