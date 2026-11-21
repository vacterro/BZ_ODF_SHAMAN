class_name ParticleLab
extends VBoxContainer
## Render/particle graph editing plus an approximate live preview. Connections
## are persisted as real emitName/renderNameN properties on the source header;
## the preview itself remains APPROXIMATED and is never written to ODF.

signal status_changed(text: String, kind: String)
signal header_selected(header: String)
signal document_edited()
## Cross-file navigation: the render referenced by "file.header" was opened.
signal open_path_requested(path: String)

var index: ResourceIndex
var schema: SchemaRegistry
var doc: OdfDocument

const HoudiniScrubberScript = preload("res://scripts/ui/houdini_scrubber.gd")
const BzMeshReaderScript = preload("res://scripts/core/bz_mesh_reader.gd")
const RESET_SCOPE_THIS_ODF := "RESET_THIS_ODF"
const RESET_SCOPE_SELECTED_NODE := "RESET_SELECTED_NODE"
const RESET_SCOPE_SELECTED_EXTERNAL := "RESET_SELECTED_EXTERNAL_ODF"
const RESET_SCOPE_DEPENDENCY_GRAPH := "RESET_DEPENDENCY_GRAPH"

var header_label: Label
var graph: GraphEdit
var preview_viewport: SubViewport
var preview_world: Node3D
var preview_camera: Camera3D
var preview_root: Node3D
var preview_floor_body: StaticBody3D
var info: RichTextLabel
var play_button: Button
var speed_spin: HBoxContainer
var counter_label: Label
var undo_button: Button
var redo_button: Button
var duplicate_button: Button
var subgraph_button: Button
var copy_button: Button
var paste_button: Button
var preset_option: OptionButton
var texture_browser_button: Button
var search_edit: LineEdit
var delete_button: Button
var new_button: Button
var rename_button: Button
var save_deps_button: Button
var reset_scope_option: OptionButton
var reset_odf_button: Button
var reset_view_button: Button
var context_effects_bar: HFlowContainer
var context_doc: OdfDocument = null
var last_save_group: Dictionary = {}
var last_reset_result: Dictionary = {}
var last_dep_reset_impact: Dictionary = {}
var dep_reset_confirmation_pending := false
var quick_inspector_box: VBoxContainer
var _name_dialog: ConfirmationDialog
var _dep_reset_dialog: ConfirmationDialog
var _texture_dialog: ConfirmationDialog
var _texture_search: LineEdit
var _texture_cat_option: OptionButton
var _texture_list: ItemList
var _texture_info_lbl: Label
var _texture_thumb_cache: Dictionary = {}
var _texture_apply_header: String = ""
var _muted_headers: Dictionary = {}
var _solo_header: String = ""
var _header_preview_nodes: Dictionary = {}
var _name_edit: LineEdit
var _name_mode := ""
var _selected_header: String = ""
var _selected_external_path: String = ""
var _selected_headers: Array[String] = []
static var _clipboard_nodes: Array[Dictionary] = []
var _emitters: Array = []
var _live_inspection_label: Label = null
var _preview_nodes: Array = []
## GraphNode name -> {path, header} for nodes representing another ODF file.
var _external_nodes: Dictionary = {}

const EMITTER_PRESETS := {
	"fireball": {
		"label": "Fireball (draw_twirl)",
		"base_name": "Fireball",
		"props": [
			["simulateBase", "\"sim_null\""],
			["renderBase", "\"draw_twirl\""],
			["textureName", "\"flame.tga\""],
			["textureBlend", "\"one one modulate\""],
			["lifeTime", "1.2"],
			["animateTime", "1.2"],
			["startColor", "\"255 210 90 255\""],
			["finishColor", "\"200 50 10 0\""],
			["startRadius", "0.6"],
			["finishRadius", "3.2"],
			["rotationRate", "3.0"],
		],
	},
	"arc_lightning": {
		"label": "Arc Lightning (draw_bolt)",
		"base_name": "ArcLightning",
		"props": [
			["simulateBase", "\"sim_null\""],
			["renderBase", "\"draw_bolt\""],
			["textureName", "\"arctrail.tga\""],
			["textureBlend", "\"one one modulate\""],
			["lifeTime", "0.8"],
			["animateTime", "0.8"],
			["startColor", "\"255 255 255 255\""],
			["finishColor", "\"0 255 220 0\""],
			["startRadius", "0.7"],
			["finishRadius", "0.05"],
			["segmentLength", "7.0"],
			["segmentVariance", "\"2.0 2.0 0.5\""],
			["textureRate", "0.3"],
			["textureSpeed", "-8.0"],
		],
	},
	"shock_ring": {
		"label": "Shockwave Ring (draw_planar)",
		"base_name": "ShockRing",
		"props": [
			["simulateBase", "\"sim_null\""],
			["renderBase", "\"draw_planar\""],
			["textureName", "\"ring.tga\""],
			["textureBlend", "\"one one modulate\""],
			["lifeTime", "0.7"],
			["animateTime", "0.7"],
			["startColor", "\"120 240 255 255\""],
			["finishColor", "\"20 120 255 0\""],
			["startRadius", "0.5"],
			["finishRadius", "6.0"],
		],
	},
	"plasma_sphere": {
		"label": "Plasma Dome (draw_sphere)",
		"base_name": "PlasmaDome",
		"props": [
			["simulateBase", "\"sim_null\""],
			["renderBase", "\"draw_sphere\""],
			["textureName", "\"vsmoke.tga\""],
			["textureBlend", "\"one one modulate\""],
			["lifeTime", "1.1"],
			["animateTime", "1.1"],
			["startColor", "\"0 255 255 230\""],
			["finishColor", "\"20 60 255 0\""],
			["startRadius", "0.5"],
			["finishRadius", "5.0"],
			["BottomInteractsWithTerrain", "true"],
		],
	},
	"ember_sparks": {
		"label": "Bouncing Embers (sim_ember + draw_trail)",
		"base_name": "EmberSparks",
		"props": [
			["simulateBase", "\"sim_ember\""],
			["renderBase", "\"draw_trail\""],
			["textureName", "\"trail2.tga\""],
			["textureBlend", "\"one one modulate\""],
			["lifeTime", "1.2"],
			["animateTime", "1.2"],
			["startColor", "\"255 220 120 255\""],
			["finishColor", "\"255 80 10 0\""],
			["startRadius", "0.12"],
			["finishRadius", "0.02"],
			["emitVelocity", "\"0.0 10.0 0.0\""],
			["emitVariance", "\"14.0 12.0 14.0\""],
		],
	},
	"ground_dust": {
		"label": "Ground Dust (sim_dust + draw_twirl)",
		"base_name": "GroundDust",
		"props": [
			["simulateBase", "\"sim_dust\""],
			["renderBase", "\"draw_twirl\""],
			["textureName", "\"smoke2.tga\""],
			["textureBlend", "\"srcalpha invsrcalpha modulatealpha\""],
			["lifeTime", "2.0"],
			["animateTime", "2.0"],
			["startColor", "\"140 125 100 180\""],
			["finishColor", "\"90 80 70 0\""],
			["startRadius", "0.5"],
			["finishRadius", "3.0"],
			["BottomInteractsWithTerrain", "true"],
		],
	},
	"chunk_debris": {
		"label": "Bouncing Debris (sim_chunk + draw_geom)",
		"base_name": "ChunkDebris",
		"props": [
			["simulateBase", "\"sim_chunk\""],
			["renderBase", "\"draw_geom\""],
			["lifeTime", "3.0"],
			["startColor", "\"200 175 130 255\""],
			["finishColor", "\"80 70 60 0\""],
			["startRadius", "0.25"],
			["finishRadius", "0.2"],
			["emitVelocity", "\"0.0 14.0 0.0\""],
			["emitVariance", "\"12.0 10.0 12.0\""],
		],
	},
	"sparks": {
		"label": "Sparks (draw_sprite)",
		"base_name": "Sparks",
		"props": [
			["simulateBase", "\"sim_ember\""],
			["renderBase", "\"draw_sprite\""],
			["textureName", "\"crackle.tga\""],
			["textureBlend", "\"one one modulate\""],
			["lifeTime", "0.7"],
			["startColor", "\"255 245 180 255\""],
			["finishColor", "\"255 120 20 0\""],
			["startRadius", "0.25"],
			["finishRadius", "0.05"],
		],
	},
	"beam_bolt": {
		"label": "Beam Bolt (draw_bolt)",
		"base_name": "BeamBolt",
		"props": [
			["renderBase", "\"draw_bolt\""],
			["textureName", "\"arctrail.tga\""],
			["textureBlend", "\"one one modulate\""],
			["lifeTime", "0.4"],
			["startColor", "\"110 220 255 255\""],
			["finishColor", "\"30 80 255 0\""],
			["startRadius", "0.2"],
			["finishRadius", "0.08"],
		],
	},
	"smoke_trail": {
		"label": "Smoke Trail (draw_twirl_trail)",
		"base_name": "SmokeTrail",
		"props": [
			["simulateBase", "\"sim_smoke\""],
			["renderBase", "\"draw_twirl_trail\""],
			["textureName", "\"smoke.tga\""],
			["textureBlend", "\"srcalpha invsrcalpha modulatealpha\""],
			["emitDelay", "0.03"],
			["lifeTime", "1.8"],
			["startColor", "\"90 85 80 180\""],
			["finishColor", "\"40 40 40 0\""],
			["startRadius", "0.35"],
			["finishRadius", "1.6"],
		],
	},
	"flash_light": {
		"label": "Flash Light (draw_light)",
		"base_name": "FlashLight",
		"props": [
			["simulateBase", "\"sim_null\""],
			["renderBase", "\"draw_light\""],
			["lifeTime", "0.35"],
			["startColor", "\"255 220 140 255\""],
			["finishColor", "\"255 100 20 0\""],
			["startRadius", "12.0"],
			["finishRadius", "0.5"],
		],
	},
}


func setup(p_index: ResourceIndex, p_schema: SchemaRegistry) -> void:
	index = p_index
	schema = p_schema
	_build_ui()
	_build_preview_world()


func _build_ui() -> void:
	add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	add_child(top)
	header_label = Label.new()
	header_label.text = "Particle Lab: auto-resolving render/explosion ODF from active combat chain..."
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_label.clip_text = true
	top.add_child(header_label)
	var fidelity := Label.new()
	fidelity.text = "PREVIEW: APPROXIMATED"
	fidelity.add_theme_color_override("font_color", Color("#969630"))
	top.add_child(fidelity)

	context_effects_bar = HFlowContainer.new()
	context_effects_bar.add_theme_constant_override("h_separation", 4)
	context_effects_bar.add_theme_constant_override("v_separation", 2)
	add_child(context_effects_bar)

	var toolbar := HFlowContainer.new()
	toolbar.add_theme_constant_override("h_separation", 4)
	toolbar.add_theme_constant_override("v_separation", 3)
	add_child(toolbar)
	new_button = _tool_button("NEW NODE", _on_new_node, toolbar)
	rename_button = _tool_button("RENAME", _on_rename_node, toolbar)
	duplicate_button = _tool_button("DUPLICATE NODE", _on_duplicate_node, toolbar)
	subgraph_button = _tool_button("DUP SUBGRAPH", duplicate_selected_subgraph, toolbar)
	copy_button = _tool_button("COPY", copy_selected_nodes, toolbar)
	paste_button = _tool_button("PASTE", paste_nodes, toolbar)
	delete_button = _tool_button("DELETE NODE", _on_delete_node, toolbar)
	preset_option = OptionButton.new()
	preset_option.add_item("+ Preset...")
	preset_option.set_item_metadata(0, "")
	for pid in EMITTER_PRESETS:
		preset_option.add_item(str(EMITTER_PRESETS[pid].label))
		preset_option.set_item_metadata(preset_option.item_count - 1, pid)
	preset_option.item_selected.connect(_on_preset_selected)
	toolbar.add_child(preset_option)
	texture_browser_button = _tool_button("TEXTURES...", func(): open_texture_browser(_selected_header), toolbar)
	texture_browser_button.tooltip_text = "Browse all indexed BZCC particle textures (.dds/.tga/.png) with visual thumbnails and 1-click apply"
	var sep := VSeparator.new()
	toolbar.add_child(sep)
	undo_button = _tool_button("UNDO", _on_graph_undo, toolbar)
	redo_button = _tool_button("REDO", _on_graph_redo, toolbar)
	save_deps_button = _tool_button("SAVE DEPENDENCIES", _on_save_dependencies, toolbar)
	save_deps_button.tooltip_text = "Save active render ODF plus any dirty external file.header dependencies to the isolated workspace"
	reset_scope_option = OptionButton.new()
	reset_scope_option.tooltip_text = "Select explicit reset scope (default: RESET THIS ODF only)"
	for spair in [
		["RESET THIS ODF", RESET_SCOPE_THIS_ODF],
		["RESET SELECTED NODE", RESET_SCOPE_SELECTED_NODE],
		["RESET SELECTED EXTERNAL ODF", RESET_SCOPE_SELECTED_EXTERNAL],
		["RESET DEPENDENCY GRAPH", RESET_SCOPE_DEPENDENCY_GRAPH],
	]:
		reset_scope_option.add_item(str(spair[0]))
		reset_scope_option.set_item_metadata(reset_scope_option.item_count - 1, str(spair[1]))
	toolbar.add_child(reset_scope_option)
	reset_odf_button = _tool_button("RESET ODF", func(): reset_document_to_default(_active_reset_scope(), false), toolbar)
	reset_odf_button.tooltip_text = "Reset according to explicit scope (default: active Particle Lab ODF only; never silently resets external dependencies)"
	search_edit = LineEdit.new()
	search_edit.placeholder_text = "Filter render nodes…"
	search_edit.custom_minimum_size = Vector2(150, 0)
	search_edit.text_changed.connect(filter_nodes)
	toolbar.add_child(search_edit)
	var hint := Label.new()
	hint.text = "drag to link · multi-select copy/paste · Enter to edit refs · external file.header opens on OPEN"
	hint.add_theme_color_override("font_color", Color("#969630"))
	toolbar.add_child(hint)

	_name_dialog = ConfirmationDialog.new()
	_name_dialog.title = "Render node name"
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(360, 0)
	_name_edit.text_submitted.connect(func(text: String): _name_dialog.hide(); _apply_name_dialog(text))
	_name_dialog.add_child(_name_edit)
	_name_dialog.confirmed.connect(func(): _apply_name_dialog(_name_edit.text))
	add_child(_name_dialog)

	_dep_reset_dialog = ConfirmationDialog.new()
	_dep_reset_dialog.title = "Confirm Dependency Graph Reset"
	_dep_reset_dialog.ok_button_text = "Reset Dependency Graph"
	_dep_reset_dialog.confirmed.connect(func(): confirm_dependency_graph_reset())
	_dep_reset_dialog.canceled.connect(func(): cancel_dependency_graph_reset())
	add_child(_dep_reset_dialog)

	_build_texture_browser_dialog()

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
	add_child(split)

	graph = GraphEdit.new()
	graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.custom_minimum_size = Vector2(180, 0)
	graph.minimap_enabled = false
	graph.show_grid = true
	graph.snapping_enabled = true
	graph.node_selected.connect(_on_node_selected)
	graph.node_deselected.connect(_on_node_deselected)
	graph.connection_request.connect(_on_connection_request)
	graph.disconnection_request.connect(_on_disconnection_request)
	graph.end_node_move.connect(_save_layout)
	split.add_child(graph)

	var right_vsplit := VSplitContainer.new()
	right_vsplit.custom_minimum_size = Vector2(160, 0)
	right_vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vsplit.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
	split.add_child(right_vsplit)

	var pv_container := SubViewportContainer.new()
	pv_container.stretch = true
	pv_container.custom_minimum_size = Vector2(140, 120)
	pv_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vsplit.add_child(pv_container)
	preview_viewport = SubViewport.new()
	preview_viewport.own_world_3d = true
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	pv_container.add_child(preview_viewport)

	var right := VBoxContainer.new()
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.custom_minimum_size = Vector2(140, 120)
	right.clip_contents = true
	right_vsplit.add_child(right)

	var controls := HFlowContainer.new()
	controls.add_theme_constant_override("h_separation", 4)
	controls.add_theme_constant_override("v_separation", 3)
	right.add_child(controls)
	play_button = Button.new()
	play_button.text = "PAUSE"
	play_button.toggle_mode = true
	play_button.toggled.connect(_on_play_toggled)
	controls.add_child(play_button)
	var restart := Button.new()
	restart.text = "RESTART"
	restart.pressed.connect(_restart_preview)
	controls.add_child(restart)
	controls.add_child(_lbl("Speed"))
	speed_spin = HoudiniScrubberScript.new()
	speed_spin.configure(0.05, 3.0, 0.05, 1.0, "×", true, false, false)
	speed_spin.set_default_value(1.0)
	speed_spin.set_pill_width(54)
	speed_spin.custom_minimum_size = Vector2(130, 0)
	controls.add_child(speed_spin)
	reset_view_button = Button.new()
	reset_view_button.text = "RESET VIEW"
	reset_view_button.tooltip_text = "Reset preview speed to 1.00x and restart emitters"
	reset_view_button.pressed.connect(reset_preview_view)
	controls.add_child(reset_view_button)

	counter_label = Label.new()
	counter_label.text = "particles: 0    nodes: 0"
	right.add_child(counter_label)

	var qi_title := _lbl("QUICK RENDER INSPECTOR  (RMB any value to reset)")
	right.add_child(qi_title)
	var qi_scroll := ScrollContainer.new()
	qi_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	qi_scroll.custom_minimum_size = Vector2(0, 180)
	qi_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(qi_scroll)
	quick_inspector_box = VBoxContainer.new()
	quick_inspector_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quick_inspector_box.add_theme_constant_override("separation", 3)
	qi_scroll.add_child(quick_inspector_box)

	info = RichTextLabel.new()
	info.bbcode_enabled = true
	info.fit_content = false
	info.custom_minimum_size = Vector2(0, 68)
	right.add_child(info)


func _build_preview_world() -> void:
	preview_world = Node3D.new()
	preview_viewport.add_child(preview_world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#120d06")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#584426")
	e.ambient_light_energy = 1.4
	env.environment = e
	preview_world.add_child(env)
	preview_camera = Camera3D.new()
	preview_camera.look_at_from_position(Vector3(7, 4.5, 9), Vector3(0, 1.5, 0), Vector3.UP)
	preview_world.add_child(preview_camera)
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor_mesh.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("#241a0d")
	floor_mesh.material_override = fm
	preview_world.add_child(floor_mesh)
	# Real rigid floor StaticBody3D (top plane at y = 0.0)
	preview_floor_body = StaticBody3D.new()
	preview_floor_body.name = "RigidPreviewFloor"
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(40.0, 2.0, 40.0)
	fshape.shape = fbox
	fshape.position = Vector3(0.0, -1.0, 0.0)
	preview_floor_body.add_child(fshape)
	preview_world.add_child(preview_floor_body)
	preview_root = Node3D.new()
	preview_world.add_child(preview_root)


func _tool_button(text: String, handler: Callable, parent: Control) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func load_document(p_doc: OdfDocument) -> void:
	doc = p_doc
	_selected_header = ""
	_selected_headers.clear()
	_external_nodes.clear()
	_clear_graph()
	_clear_emitters()
	_rebuild_quick_inspector()
	if doc == null:
		header_label.text = "Particle Lab: no document."
		return
	var renders := doc.render_headers()
	header_label.text = "Particle Lab: %s  —  %d render header(s)" % [doc.get_display_name(), renders.size()]
	if renders.is_empty():
		info.text = "[color=#D37676]This ODF declares no renderBase/simulateBase headers.[/color]\nIt may still attach renders by reference; open the render ODF itself."
		status_changed.emit("Particle Lab: no render headers in " + doc.get_display_name(), "warning")
		return
	var positions := {}
	var i := 0
	for h in renders:
		var rb := doc.get_value(h.name, "renderBase", "?")
		var sb := doc.get_value(h.name, "simulateBase", "—")
		var occ_count := doc.header_occurrence_count(h.name)
		var node := GraphNode.new()
		node.name = _node_name_for(h.name, i)
		node.set_meta("header", h.name)
		node.set_meta("occurrences", occ_count)
		node.title = "[%s]  %s%s" % [h.name, rb, "  · merged ×%d" % occ_count if occ_count > 1 else ""]
		if occ_count > 1:
			node.tooltip_text = "%s has %d physical [%s] occurrences. Shown values are the effective (last) declaration; edits target that occurrence." % [h.name, occ_count, h.name]
		node.position_offset = Vector2(40 + (i % 3) * 300, 40 + int(i / 3) * 230)
		var rows := VBoxContainer.new()
		rows.add_theme_constant_override("separation", 1)
		node.add_child(rows)
		var sub := Label.new()
		sub.text = "simulateBase: " + sb
		sub.add_theme_color_override("font_color", Color("#C5AB6E"))
		rows.add_child(sub)
		for key in ["lifeTime", "emitDelay", "textureName", "startColor", "finishColor", "startRadius", "finishRadius", "maxCount", "damageRadius"]:
			var v := doc.get_value(h.name, key, "")
			if v != "":
				var row := Label.new()
				row.text = "%s = %s" % [key, v]
				row.add_theme_font_size_override("font_size", 11)
				rows.add_child(row)
		# Editable references: drag a connection or edit the reference text.
		for key in _child_keys(doc, h.name):
			var ref := doc.get_value(h.name, key, "")
			var ref_row := HBoxContainer.new()
			var ref_label := Label.new()
			ref_label.text = key
			ref_label.add_theme_font_size_override("font_size", 11)
			ref_label.custom_minimum_size = Vector2(88, 0)
			ref_row.add_child(ref_label)
			var ref_edit := LineEdit.new()
			ref_edit.text = ref
			ref_edit.custom_minimum_size = Vector2(140, 0)
			ref_edit.tooltip_text = "Edit %s and press Enter; target must be a render header or file.header." % key
			ref_edit.text_submitted.connect(func(text: String): _on_reference_submitted(h.name, key, text))
			ref_row.add_child(ref_edit)
			rows.add_child(ref_row)
		node.set_slot(0, true, 0, Color("#D3B57A"), true, 0, Color("#969630"))
		graph.add_child(node)
		positions[h.name.to_lower()] = node.name
		i += 1
	var built := EffectRuntime.build_document_preview(index, doc)
	_header_preview_nodes = built.get("header_nodes", {})
	for pn in built.get("nodes", []):
		preview_root.add_child(pn)
		_preview_nodes.append(pn)
	for em in built.get("emitters", []):
		_emitters.append(em)
	_apply_emitter_mute_solo()
	# Connections from emitName / renderNameN within this document.
	var ext_i := 0
	for h in renders:
		var from: String = str(positions.get(h.name.to_lower(), ""))
		if from == "":
			continue
		for key in _child_keys(doc, h.name):
			var ref := doc.get_value(h.name, key, "")
			if ref == "":
				continue
			var resolved := _resolve_reference(ref)
			var to := ""
			match str(resolved.get("kind", "")):
				"local":
					to = str(positions.get(str(resolved.header).to_lower(), ""))
				"external":
					to = _external_node(str(resolved.path), str(resolved.header), ext_i)
					ext_i += 1
			if to != "" and to != from:
				graph.connect_node(from, 0, to, 0)
	_apply_layout()
	if _selected_header == "" and not renders.is_empty():
		_selected_header = renders[0].name
		_selected_headers = [_selected_header]
		var first_gn := graph.get_node_or_null(NodePath(_selected_header.validate_node_name()))
		if first_gn is GraphNode:
			(first_gn as GraphNode).selected = true
		_rebuild_quick_inspector()
	info.text = _describe_graph(renders)
	counter_label.text = "render nodes: %d    emitters: %d" % [renders.size(), _emitters.size()]
	_update_toolbar()
	status_changed.emit("Particle Lab loaded %s (%d render headers)" % [doc.get_display_name(), renders.size()], "success")


## Automatically discover and bind particle/render ODFs from the active document
## and active combat chain so Particle Lab is never empty and adapts to ODF context.
func bind_context_document(p_ctx_doc: OdfDocument, weapon_profile = null) -> void:
	context_doc = p_ctx_doc
	if context_effects_bar != null:
		for c in context_effects_bar.get_children():
			c.queue_free()
	var targets: Array[Dictionary] = []
	var seen_paths := {}
	var add_target := func(label_prefix: String, path: String) -> void:
		if path == "" or not FileAccess.file_exists(path):
			return
		var canon := WorkspaceStore.canonical(path).to_lower()
		if seen_paths.has(canon):
			return
		var tdoc := OdfDocument.load_cached(path)
		if tdoc == null or not tdoc.is_render_odf():
			return
		seen_paths[canon] = true
		targets.append({"label": "%s: %s" % [label_prefix, path.get_file()], "path": path, "doc": tdoc})

	if p_ctx_doc != null:
		if p_ctx_doc.is_render_odf():
			add_target.call("Current Render", p_ctx_doc.source_path)
		if index != null:
			for row in OdfInheritance.merged(p_ctx_doc, index):
				var kl := str(row.get("key", "")).to_lower()
				var val := str(row.get("value", "")).strip_edges().trim_prefix("\"").trim_suffix("\"")
				var src_p := str(row.get("source", p_ctx_doc.source_path))
				if val == "":
					continue
				if kl == "renderbase" and src_p != "":
					add_target.call("Inherited Render", src_p)
				elif kl == "flashname":
					add_target.call("Muzzle Flash", index.resolve_path_from(val, src_p))
				elif kl == "rendername" or kl.begins_with("rendername"):
					add_target.call("Render", index.resolve_path_from(val, src_p))
				elif kl in ["xplvehicle", "xplground", "xplexpire", "xplbuilding", "xplcrash"]:
					add_target.call(kl, index.resolve_path_from(val, src_p))

	if weapon_profile != null and index != null:
		if weapon_profile.muzzle_render != "":
			add_target.call("Chain Flash", index.resolve_path_from(weapon_profile.muzzle_render, weapon_profile.weapon_path))
		if weapon_profile.render_name != "":
			add_target.call("Chain Trail", index.resolve_path_from(weapon_profile.render_name, weapon_profile.ordnance_path))
		if weapon_profile.xpl_vehicle != "":
			add_target.call("Chain Hit Vehicle", index.resolve_path_from(weapon_profile.xpl_vehicle, weapon_profile.ordnance_path))
		if weapon_profile.xpl_ground != "":
			add_target.call("Chain Hit Ground", index.resolve_path_from(weapon_profile.xpl_ground, weapon_profile.ordnance_path))

	if context_effects_bar != null:
		var lbl := _lbl("Context Effects:")
		context_effects_bar.add_child(lbl)
		for t in targets:
			var tp := str(t.get("path", ""))
			var btn := Button.new()
			btn.text = str(t.get("label", tp.get_file()))
			btn.focus_mode = Control.FOCUS_NONE
			btn.tooltip_text = "Load " + tp + " in Particle Lab"
			if doc != null and WorkspaceStore.canonical(doc.source_path).to_lower() == WorkspaceStore.canonical(tp).to_lower():
				btn.add_theme_color_override("font_color", Color("#F0D060"))
			btn.pressed.connect(func():
				var d := OdfDocument.load_cached(tp)
				if d != null:
					load_document(d)
					bind_context_document(context_doc, weapon_profile)
			)
			context_effects_bar.add_child(btn)
		if p_ctx_doc != null and not p_ctx_doc.is_render_odf():
			var add_local_btn := Button.new()
			add_local_btn.text = "+ Create Render Node in " + p_ctx_doc.get_display_name()
			add_local_btn.focus_mode = Control.FOCUS_NONE
			add_local_btn.tooltip_text = "Add a local [Flash] / [Render] particle section directly into " + p_ctx_doc.get_display_name()
			add_local_btn.pressed.connect(func():
				doc = p_ctx_doc
				var default_hdr := "Flash" if p_ctx_doc.has_header("WeaponClass") else ("Render" if p_ctx_doc.has_header("OrdnanceClass") else "NewRender")
				create_render_node(default_hdr)
				bind_context_document(context_doc, weapon_profile)
			)
			context_effects_bar.add_child(add_local_btn)

	var doc_in_context := doc != null and seen_paths.has(WorkspaceStore.canonical(doc.source_path).to_lower())
	if p_ctx_doc != null and p_ctx_doc.is_render_odf():
		if doc != p_ctx_doc:
			load_document(p_ctx_doc)
	elif (doc == null or doc.render_headers().is_empty() or not doc_in_context) and not targets.is_empty():
		var first_doc: OdfDocument = targets[0].get("doc", null)
		if first_doc != null:
			load_document(first_doc)


func _child_keys(doc_ref: OdfDocument, header: String) -> Array[String]:
	var keys: Array[String] = []
	if doc_ref.find_entry(header, "emitName") != null:
		keys.append("emitName")
	for i in range(1, 33):
		if doc_ref.find_entry(header, "renderName%d" % i) != null:
			keys.append("renderName%d" % i)
	return keys


func _describe_graph(renders: Array) -> String:
	var lines: Array[String] = []
	lines.append("[b]Graph[/b] — nodes are render headers; edges are emitName/renderNameN references resolved by name in this ODF or by file.header.")
	var count := {}
	var merged := 0
	for h in renders:
		var rb := doc.get_value(h.name, "renderBase", "?")
		count[rb] = int(count.get(rb, 0)) + 1
		if doc.header_occurrence_count(h.name) > 1:
			merged += 1
	for k in count:
		lines.append("• %s × %d" % [k, count[k]])
	if merged > 0:
		lines.append("[color=#D3B57A]Merged view:[/color] %d name(s) appear in more than one physical header; values shown are the effective occurrence." % merged)
	if not _external_nodes.is_empty():
		lines.append("[color=#969630]%d external file(s) linked by file.header; select one and press OPEN to inspect it.[/color]" % _external_nodes.size())
	return "\n".join(lines)


func _restart_preview() -> void:
	for e in _emitters:
		if is_instance_valid(e):
			e.restart()


func _on_play_toggled(paused: bool) -> void:
	play_button.text = "PLAY" if paused else "PAUSE"
	for e in _emitters:
		if is_instance_valid(e):
			e.emitting = not paused


func _clear_emitters() -> void:
	for n in _preview_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_preview_nodes.clear()
	for e in _emitters:
		if is_instance_valid(e):
			e.queue_free()
	_emitters.clear()


func _clear_graph() -> void:
	if graph == null:
		return
	for conn in graph.get_connection_list():
		graph.disconnect_node(conn.from_node, conn.from_port, conn.to_node, conn.to_port)
	for c in graph.get_children():
		if c is GraphNode:
			graph.remove_child(c)
			c.queue_free()


func _node_name_for(header: String, index_i: int) -> String:
	# Two different physical headers can share a name; Godot node names must not.
	var base := header.validate_node_name()
	if graph != null and graph.get_node_or_null(NodePath(base)) != null:
		base = "%s__%d" % [base, index_i]
	return base


func _header_for_node(node_name: String) -> String:
	var n := graph.get_node_or_null(NodePath(node_name))
	if n != null and n.has_meta("header"):
		return str(n.get_meta("header"))
	return ""


## Build a node for a render header in another file. Cross-file references are
## real edges: the source header literally declares "file.header".
func _external_node(path: String, header: String, index_i: int) -> String:
	var key := (path + "|" + header).md5_text().substr(0, 12)
	var node_name := "ext_" + key
	if _external_nodes.has(node_name):
		return node_name
	var node := GraphNode.new()
	node.name = node_name
	node.title = "%s ▸ %s" % [path.get_file(), header]
	node.set_meta("external_path", path)
	node.set_meta("external_header", header)
	node.tooltip_text = path
	node.position_offset = Vector2(40 + (index_i % 3) * 300, 280 + int(index_i / 3) * 230)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 2)
	node.add_child(rows)
	var src := Label.new()
	var ext_doc := OdfDocument.load_cached(path)
	var dirty_tag := " · DIRTY" if (ext_doc != null and ext_doc.dirty) else (" · OVERRIDE" if (ext_doc != null and ext_doc.workspace_override) else "")
	src.text = "external file" + dirty_tag
	src.add_theme_color_override("font_color", Color("#D37676") if (ext_doc != null and ext_doc.dirty) else Color("#969630"))
	src.add_theme_font_size_override("font_size", 11)
	rows.add_child(src)
	if ext_doc != null and ext_doc.has_header(header):
		for ekey in ["renderBase", "lifeTime", "startColor"]:
			var ev := ext_doc.get_value(header, ekey, "")
			if ev != "":
				var erow := Label.new()
				erow.text = "%s = %s" % [ekey, ev]
				erow.add_theme_font_size_override("font_size", 10)
				rows.add_child(erow)
	var open_btn := Button.new()
	open_btn.text = "OPEN " + path.get_file()
	open_btn.focus_mode = Control.FOCUS_NONE
	open_btn.pressed.connect(func(): open_path_requested.emit(path))
	rows.add_child(open_btn)
	node.set_slot(0, true, 0, Color("#969630"), false, 0, Color("#969630"))
	graph.add_child(node)
	_external_nodes[node_name] = {"path": path, "header": header}
	return node_name


## Resolve a reference value. local -> a header in this document; external ->
## "file.header" resolved through the resource index relative to this document;
## missing/missing_header are rejected by the editor instead of guessed.
func _resolve_reference(value: String) -> Dictionary:
	var v := value.strip_edges()
	if v == "":
		return {"kind": "empty"}
	if not v.contains("."):
		var local := _reference_header(v)
		if local != "":
			return {"kind": "local", "header": local, "path": doc.source_path if doc != null else ""}
		return {"kind": "missing", "value": v}
	var file_ref := v.get_basename()
	var header := v.get_extension()
	var path := ""
	if index != null and doc != null:
		path = index.resolve_path_from(file_ref, doc.source_path)
	if path == "" and doc != null and doc.source_path != "":
		var sib := doc.source_path.get_base_dir().path_join(file_ref + ".odf")
		if FileAccess.file_exists(sib):
			path = sib
	if path == "":
		return {"kind": "missing", "value": v}
	var ext_doc = OdfDocument.load_cached(path)
	if ext_doc == null:
		return {"kind": "missing", "value": v, "path": path}
	if not ext_doc.has_header(header):
		return {"kind": "missing_header", "value": v, "path": path, "header": header}
	return {"kind": "external", "path": path, "header": header, "value": v}


func _next_reference_key(header: String) -> String:
	var emit = doc.find_entry(header, "emitName")
	if emit != null and emit.core_value() == "":
		return "emitName"
	for i in range(1, 33):
		var key := "renderName%d" % i
		if doc.find_entry(header, key) == null:
			return key
	return ""


## Resolve a reference value to a header name in this document. External
## `file.header` references are not graph edges yet and return "".
func _reference_header(value: String) -> String:
	var v := value.strip_edges()
	if v == "" or v.contains("."):
		return ""
	for h in doc.render_headers():
		if h.name.to_lower() == v.to_lower():
			return h.name
	return ""


func _on_connection_request(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	var src := _header_for_node(String(from_node))
	var dst := _header_for_node(String(to_node))
	if src == "" or dst == "" or src == dst:
		status_changed.emit("Connection refused: both ends must be different render headers.", "warning")
		return
	if _would_cycle(src, dst):
		status_changed.emit("Connection refused: %s -> %s would create a cycle." % [src, dst], "warning")
		return
	var key := _next_reference_key(src)
	if key == "":
		status_changed.emit("Connection refused: all emitName/renderName1..32 slots are occupied.", "warning")
		return
	var entry = doc.find_entry(src, key)
	if entry != null:
		doc.set_entry_value(entry, dst)
	else:
		doc.append_entry(src, key, dst)
	status_changed.emit("Linked %s -> %s as %s" % [src, dst, key], "success")
	document_edited.emit()
	load_document(doc)


func _on_disconnection_request(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	var src := _header_for_node(String(from_node))
	var dst := _header_for_node(String(to_node))
	if src == "" or dst == "":
		return
	for key in _child_keys(doc, src):
		var e = doc.find_entry(src, key)
		if e != null and _reference_header(e.core_value()) == dst:
			doc.remove_entry(e)
			status_changed.emit("Removed %s -> %s (%s)" % [src, dst, key], "success")
			document_edited.emit()
			load_document(doc)
			return
	graph.disconnect_node(from_node, 0, to_node, 0)


func _on_reference_submitted(header: String, key: String, text: String) -> void:
	var value := text.strip_edges()
	if value == "":
		status_changed.emit("Empty reference ignored; disconnect the edge instead.", "warning")
		return
	var resolved := _resolve_reference(value)
	match str(resolved.get("kind", "")):
		"missing":
			status_changed.emit("Reference rejected: '%s' resolves to no header in this ODF or indexed file." % value, "warning")
			return
		"missing_header":
			status_changed.emit("Reference rejected: %s has no [%s] header." % [str(resolved.get("path", "")).get_file(), str(resolved.get("header", ""))], "warning")
			return
	var target := _reference_header(value)
	if target.to_lower() == header.to_lower():
		status_changed.emit("Reference rejected: a node cannot reference itself.", "warning")
		return
	if target != "" and _would_cycle(header, target):
		status_changed.emit("Reference rejected: %s -> %s would create a cycle." % [header, target], "warning")
		return
	var e = doc.find_entry(header, key)
	if e == null:
		return
	if e.core_value() == value:
		return
	doc.set_entry_value(e, value)
	status_changed.emit("Updated %s.%s = %s" % [header, key, value], "success")
	document_edited.emit()
	load_document(doc)


func _on_node_selected(node: Node) -> void:
	# Metadata is the identity; the visual GraphNode name may be normalised.
	if node.has_meta("external_path"):
		_selected_external_path = str(node.get_meta("external_path"))
		status_changed.emit("External node: %s ▸ %s (press OPEN to inspect)" % [_selected_external_path.get_file(), str(node.get_meta("external_header"))], "muted")
		return
	_selected_external_path = ""
	var header := str(node.get_meta("header", ""))
	if header == "":
		return
	for h in doc.render_headers():
		if h.name.to_lower() == header.to_lower():
			_selected_header = h.name
			if not _selected_headers.has(h.name):
				_selected_headers.append(h.name)
			_rebuild_quick_inspector()
			_update_toolbar()
			header_selected.emit(h.name)
			return


func _on_node_deselected(node: Node) -> void:
	if node.has_meta("external_path") and str(node.get_meta("external_path")) == _selected_external_path:
		_selected_external_path = ""
	var header := str(node.get_meta("header", ""))
	if header == "":
		return
	_selected_headers.erase(header)
	if _selected_header == header:
		_selected_header = _selected_headers[_selected_headers.size() - 1] if not _selected_headers.is_empty() else ""
	_rebuild_quick_inspector()
	_update_toolbar()


func get_selected_headers() -> Array[String]:
	var out: Array[String] = []
	if graph != null:
		for c in graph.get_children():
			if c is GraphNode and (c as GraphNode).selected and c.has_meta("header"):
				var h := str(c.get_meta("header"))
				if h != "" and not out.has(h):
					out.append(h)
	for h2 in _selected_headers:
		if not out.has(h2) and doc != null and doc.has_header(h2):
			out.append(h2)
	if out.is_empty() and _selected_header != "" and doc != null and doc.has_header(_selected_header):
		out.append(_selected_header)
	return out


func select_headers(names: Array) -> void:
	_selected_headers.clear()
	_selected_header = ""
	var wanted := {}
	for nm in names:
		wanted[str(nm).to_lower()] = true
	if graph != null:
		for c in graph.get_children():
			if c is GraphNode and c.has_meta("header"):
				var h := str(c.get_meta("header"))
				var hit := wanted.has(h.to_lower())
				(c as GraphNode).selected = hit
				if hit:
					_selected_headers.append(h)
					_selected_header = h
	_rebuild_quick_inspector()
	_update_toolbar()


## Search / filter render nodes by name or renderBase; highlights matching nodes.
func filter_nodes(query: String) -> Array[String]:
	var q := query.strip_edges().to_lower()
	var matches: Array[String] = []
	if graph == null:
		return matches
	for c in graph.get_children():
		if not (c is GraphNode):
			continue
		var gn := c as GraphNode
		var title_lc := gn.title.to_lower()
		var hdr := str(gn.get_meta("header", ""))
		var matched := q == "" or title_lc.contains(q) or hdr.to_lower().contains(q)
		gn.modulate = Color(1, 1, 1, 1) if matched else Color(0.45, 0.45, 0.45, 0.55)
		if matched and hdr != "":
			matches.append(hdr)
	return matches


func _factory_quick_value(hdr: String, key: String, fallback: String = "") -> String:
	if doc == null or doc.source_path == "" or not FileAccess.file_exists(doc.source_path):
		return fallback
	var fdoc := OdfDocument.load_file(doc.source_path)
	if fdoc == null:
		return fallback
	var fe = fdoc.find_entry(hdr, key)
	if fe != null:
		return str(fe.value_raw)
	return fallback


func _bind_quick_rmb(ctrl: Control, hdr: String, key: String, fallback: String) -> void:
	if ctrl == null:
		return
	ctrl.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				var fv := _factory_quick_value(hdr, key, fallback)
				if fv != "":
					apply_quick_property(hdr, key, fv)
				ctrl.accept_event()
	)


static func _color_to_odf_rgba(c: Color) -> String:
	return "\"%d %d %d %d\"" % [
		clampi(int(round(c.r * 255.0)), 0, 255),
		clampi(int(round(c.g * 255.0)), 0, 255),
		clampi(int(round(c.b * 255.0)), 0, 255),
		clampi(int(round(c.a * 255.0)), 0, 255),
	]


func set_emitter_muted(header: String, muted: bool) -> void:
	if muted:
		_muted_headers[header.to_lower()] = true
	else:
		_muted_headers.erase(header.to_lower())
	_apply_emitter_mute_solo()
	_rebuild_quick_inspector()


func set_emitter_solo(header: String, solo_on: bool) -> void:
	if solo_on:
		_solo_header = header.to_lower()
	elif _solo_header == header.to_lower():
		_solo_header = ""
	_apply_emitter_mute_solo()
	_rebuild_quick_inspector()


func _apply_emitter_mute_solo() -> void:
	for hname in _header_preview_nodes:
		var node = _header_preview_nodes[hname]
		if not is_instance_valid(node) or not (node is Node3D):
			continue
		var hlow := str(hname).to_lower()
		var vis := true
		if _solo_header != "":
			vis = (hlow == _solo_header)
		elif _muted_headers.has(hlow):
			vis = false
		(node as Node3D).visible = vis


## Inspect emission rate, particle count, estimated CPU/GPU cost, and lifetime
## curve metrics for a render header (Wave F particle inspection).
func inspect_emitter_metrics(header: String) -> Dictionary:
	if doc == null or header == "":
		return {}
	var rb := doc.get_value(header, "renderBase", "draw_twirl").to_lower()
	var sb := doc.get_value(header, "simulateBase", "sim_null").to_lower()
	var life := maxf(0.05, doc.get_float(header, "lifeTime", doc.get_float(header, "lifeSpan", 1.0)))
	var anim_t := doc.get_float(header, "animateTime", life)
	if anim_t <= 0.001 or anim_t > 1e6:
		anim_t = life
	var delay := doc.get_float(header, "emitDelay", 0.0)
	var max_cnt := doc.get_int(header, "maxCount", 0)
	var rate := (1.0 / maxf(0.01, delay)) if (delay > 0.001 and delay < 30.0) else (float(maxi(1, max_cnt)) / life)
	var est_active := clampi(int(ceilf(rate * life)), 1, 160)
	if max_cnt > 0:
		est_active = mini(est_active, max_cnt)
	var sr := doc.get_float(header, "startRadius", 0.5)
	var fr := doc.get_float(header, "finishRadius", sr)
	var gpu_cost := float(est_active) * maxf(0.2, (sr + fr) * 0.5) * (2.2 if rb == "draw_sphere" else (1.8 if rb == "draw_bolt" else 1.0))
	var cpu_cost := float(est_active) * (1.6 if (sb == "sim_ember" or sb == "sim_chunk" or sb == "sim_spray") else 0.6)
	var tier := "LOW" if gpu_cost < 20.0 else ("MEDIUM" if gpu_cost < 80.0 else "HIGH")
	return {
		"header": header,
		"render_base": rb,
		"simulate_base": sb,
		"life_time": life,
		"animate_time": anim_t,
		"emission_rate_hz": rate,
		"active_particles": est_active,
		"start_radius": sr,
		"finish_radius": fr,
		"cpu_cost_est": cpu_cost,
		"gpu_cost_est": gpu_cost,
		"cost_tier": tier,
		"muted": _muted_headers.has(header.to_lower()),
		"solo": _solo_header == header.to_lower(),
	}


## Live Parameter Inspection: parsed ODF values plus the actual values on the
## live CPUParticles3D nodes and the current 3D preview state. Never writes to
## the document; safe to call once per frame.
func inspect_emitter_live_state(header: String) -> Dictionary:
	var out := inspect_emitter_metrics(header)
	if out.is_empty():
		return {}
	out["live_particle_count"] = 0
	out["live_lifetime"] = 0.0
	out["live_speed"] = 0.0
	out["live_scale_curve_points"] = 0
	out["normalised_age"] = 0.0
	var holder: Node = null
	if _header_preview_nodes is Dictionary and (_header_preview_nodes as Dictionary).has(header):
		holder = _header_preview_nodes[header] as Node
	if holder == null:
		return out
	var stack: Array[Node] = [holder]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CPUParticles3D:
			var p := n as CPUParticles3D
			out["live_particle_count"] = int(out.get("live_particle_count", 0)) + p.amount
			out["live_lifetime"] = maxf(float(out.get("live_lifetime", 0.0)), p.lifetime)
			if p.direction.length() > 0.001:
				out["live_speed"] = maxf(float(out.get("live_speed", 0.0)), p.initial_velocity_min)
			if p.scale_amount_curve != null:
				out["live_scale_curve_points"] = maxi(int(out.get("live_scale_curve_points", 0)), p.scale_amount_curve.get_point_count())
		for c in n.get_children():
			stack.append(c)
	var life := maxf(0.001, float(out.get("life_time", 1.0)))
	var loop_t := fmod(float(Time.get_ticks_msec()) / 1000.0, life)
	out["normalised_age"] = clampf(loop_t / life, 0.0, 1.0)
	return out


func _build_texture_browser_dialog() -> void:
	_texture_dialog = ConfirmationDialog.new()
	_texture_dialog.title = "BZCC Particle Texture Browser"
	_texture_dialog.ok_button_text = "Apply Texture"
	_texture_dialog.min_size = Vector2i(660, 480)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_texture_dialog.add_child(vb)

	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	vb.add_child(filter_row)
	_texture_search = LineEdit.new()
	_texture_search.placeholder_text = "Search textures (flame, arc, smoke, ring, spark, crackle, trail)..."
	_texture_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_texture_search.text_changed.connect(func(_t): _populate_texture_browser())
	filter_row.add_child(_texture_search)
	_texture_cat_option = OptionButton.new()
	for pair in [["Effects / FX First", "fx"], ["All Indexed Textures", "all"], ["Fire / Plasma / Glow", "fire"], ["Smoke / Dust / Ring", "smoke"], ["Lightning / Beam / Trail", "bolt"]]:
		_texture_cat_option.add_item(str(pair[0]))
		_texture_cat_option.set_item_metadata(_texture_cat_option.item_count - 1, str(pair[1]))
	_texture_cat_option.item_selected.connect(func(_i): _populate_texture_browser())
	filter_row.add_child(_texture_cat_option)

	_texture_info_lbl = Label.new()
	_texture_info_lbl.text = "Double-click any texture to apply to textureName."
	_texture_info_lbl.add_theme_color_override("font_color", Color("#C5AB6E"))
	vb.add_child(_texture_info_lbl)

	_texture_list = ItemList.new()
	_texture_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_texture_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_texture_list.icon_mode = ItemList.ICON_MODE_TOP
	_texture_list.max_columns = 0
	_texture_list.same_column_width = true
	_texture_list.fixed_column_width = 112
	_texture_list.fixed_icon_size = Vector2i(56, 56)
	_texture_list.item_activated.connect(func(idx: int):
		_apply_selected_browser_texture(idx)
		_texture_dialog.hide()
	)
	vb.add_child(_texture_list)

	_texture_dialog.confirmed.connect(func():
		var sel := _texture_list.get_selected_items()
		if not sel.is_empty():
			_apply_selected_browser_texture(sel[0])
	)
	add_child(_texture_dialog)


## Enumerate available indexed particle textures (for UI browser & automated tests).
func list_available_textures(query: String = "", category: String = "fx", limit: int = 160) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if index == null:
		return out
	var q := query.strip_edges().to_lower()
	var cat := category.strip_edges().to_lower()
	var tex_exts := {"dds": true, "tga": true, "png": true, "bmp": true, "jpg": true, "jpeg": true}
	var seen_stem := {}
	for akey in index.assets_by_name:
		var fn := str(akey)
		var ext := fn.get_extension().to_lower()
		if not tex_exts.has(ext):
			continue
		var list: Array = index.assets_by_name[akey]
		if list.is_empty():
			continue
		var best: Dictionary = list[0]
		for item in list:
			var lp := str(item.get("path", "")).to_lower()
			if lp.contains("/effects/") or lp.contains("\\effects\\"):
				best = item
				break
			if str(item.get("kind", "")) == "game":
				best = item
		var full_p := str(best.get("path", ""))
		var plow := full_p.replace("\\", "/").to_lower()
		var is_fx := plow.contains("/effects/") or plow.contains("flame") or plow.contains("smoke") or plow.contains("spark") or plow.contains("trail") or plow.contains("bolt") or plow.contains("ring") or plow.contains("flare") or plow.contains("plasma") or plow.contains("crackle") or plow.contains("beam") or plow.contains("light") or plow.contains("blast") or plow.contains("particle")
		if cat == "fx" and not is_fx and q == "":
			continue
		elif cat == "fire" and not (fn.contains("flame") or fn.contains("fire") or fn.contains("plasma") or fn.contains("flare") or fn.contains("glow") or fn.contains("blast") or fn.contains("spark") or fn.contains("light")):
			continue
		elif cat == "smoke" and not (fn.contains("smoke") or fn.contains("dust") or fn.contains("ring") or fn.contains("cloud") or fn.contains("char") or fn.contains("puff")):
			continue
		elif cat == "bolt" and not (fn.contains("arc") or fn.contains("bolt") or fn.contains("trail") or fn.contains("beam") or fn.contains("crackle") or fn.contains("laser") or fn.contains("ray") or fn.contains("lightning")):
			continue
		if q != "" and not fn.contains(q) and not plow.contains(q):
			continue
		var stem := fn.get_basename().to_lower()
		if seen_stem.has(stem) and ext != "dds":
			continue
		seen_stem[stem] = true
		out.append({
			"name": fn,
			"odf_name": stem + ".tga",
			"path": full_p,
			"is_fx": is_fx,
			"kind": str(best.get("kind", "")),
		})
	out.sort_custom(func(a, b):
		if bool(a.is_fx) != bool(b.is_fx):
			return bool(a.is_fx)
		return str(a.name) < str(b.name)
	)
	if limit > 0 and out.size() > limit:
		return out.slice(0, limit)
	return out


func _get_texture_thumb(tex_path: String) -> ImageTexture:
	if _texture_thumb_cache.has(tex_path):
		return _texture_thumb_cache[tex_path]
	var img: Image = BzMeshReaderScript.load_image_any(tex_path)
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	if img.get_width() > 64 or img.get_height() > 64:
		img.resize(56, 56, Image.INTERPOLATE_BILINEAR)
	var itex := ImageTexture.create_from_image(img)
	_texture_thumb_cache[tex_path] = itex
	return itex


func _populate_texture_browser() -> void:
	if _texture_list == null:
		return
	_texture_list.clear()
	var q := _texture_search.text if _texture_search != null else ""
	var cat := "fx"
	if _texture_cat_option != null and _texture_cat_option.selected >= 0:
		cat = str(_texture_cat_option.get_item_metadata(_texture_cat_option.selected))
	var rows := list_available_textures(q, cat, 120)
	for r in rows:
		var thumb := _get_texture_thumb(str(r.path))
		var idx := _texture_list.add_item(str(r.name), thumb)
		_texture_list.set_item_metadata(idx, r)
		_texture_list.set_item_tooltip(idx, "%s\nODF ref: %s\n%s" % [str(r.name), str(r.odf_name), str(r.path)])
	if _texture_info_lbl != null:
		_texture_info_lbl.text = "Showing %d texture(s) — click & Apply (or double-click) to set textureName on [%s]" % [rows.size(), _texture_apply_header if _texture_apply_header != "" else "(select node)"]


func _apply_selected_browser_texture(idx: int) -> void:
	if _texture_list == null or idx < 0 or idx >= _texture_list.item_count:
		return
	var r = _texture_list.get_item_metadata(idx)
	if not (r is Dictionary):
		return
	var target_hdr := _texture_apply_header if _texture_apply_header != "" else _selected_header
	if target_hdr == "" or doc == null:
		status_changed.emit("Texture Browser: select a render node first.", "warning")
		return
	var odf_ref := str(r.get("odf_name", r.get("name", "")))
	apply_quick_property(target_hdr, "textureName", "\"" + odf_ref + "\"")


func open_texture_browser(header: String = "") -> int:
	_texture_apply_header = header if header != "" else _selected_header
	_populate_texture_browser()
	if _dep_reset_dialog != null and _dep_reset_dialog.visible:
		_dep_reset_dialog.hide()
	if _name_dialog != null and _name_dialog.visible:
		_name_dialog.hide()
	if _texture_dialog != null and is_inside_tree():
		_texture_dialog.exclusive = false
		_texture_dialog.popup_centered()
	return _texture_list.item_count if _texture_list != null else 0


func _rebuild_quick_inspector() -> void:
	if quick_inspector_box == null:
		return
	for c in quick_inspector_box.get_children():
		quick_inspector_box.remove_child(c)
		c.queue_free()
	if doc == null or _selected_header == "":
		var empty_lbl := Label.new()
		empty_lbl.text = "Select a render node to quick-edit properties."
		empty_lbl.add_theme_color_override("font_color", Color("#95804C"))
		quick_inspector_box.add_child(empty_lbl)
		return
	var hdr := _selected_header
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = "[%s]" % hdr
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color("#F0D060"))
	title_row.add_child(title)
	var mute_btn := Button.new()
	mute_btn.text = "M"
	mute_btn.toggle_mode = true
	mute_btn.button_pressed = _muted_headers.has(hdr.to_lower())
	mute_btn.tooltip_text = "Mute [%s] in live 3D preview" % hdr
	mute_btn.focus_mode = Control.FOCUS_NONE
	mute_btn.toggled.connect(func(on: bool): set_emitter_muted(hdr, on))
	title_row.add_child(mute_btn)
	var solo_btn := Button.new()
	solo_btn.text = "S"
	solo_btn.toggle_mode = true
	solo_btn.button_pressed = (_solo_header == hdr.to_lower())
	solo_btn.tooltip_text = "Solo [%s] in live 3D preview" % hdr
	solo_btn.focus_mode = Control.FOCUS_NONE
	solo_btn.toggled.connect(func(on: bool): set_emitter_solo(hdr, on))
	title_row.add_child(solo_btn)
	var reset_node_btn := Button.new()
	reset_node_btn.text = "Reset Node"
	reset_node_btn.focus_mode = Control.FOCUS_NONE
	reset_node_btn.tooltip_text = "Reset [%s] back to factory default values" % hdr
	reset_node_btn.pressed.connect(func(): reset_header_to_default(hdr))
	title_row.add_child(reset_node_btn)
	quick_inspector_box.add_child(title_row)

	# Emitter cost / rate / lifetime telemetry strip (Wave F inspection).
	var em_stat := inspect_emitter_metrics(hdr)
	var stat_lbl := Label.new()
	stat_lbl.text = "rate %.1f/s · active ~%d · radius %.2f->%.2f · cost %s (CPU %.0f / GPU %.0f)" % [
		float(em_stat.get("emission_rate_hz", 0.0)), int(em_stat.get("active_particles", 0)),
		float(em_stat.get("start_radius", 0.0)), float(em_stat.get("finish_radius", 0.0)),
		str(em_stat.get("cost_tier", "LOW")), float(em_stat.get("cpu_cost_est", 0.0)), float(em_stat.get("gpu_cost_est", 0.0)),
	]
	stat_lbl.add_theme_font_size_override("font_size", 10)
	stat_lbl.add_theme_color_override("font_color", Color("#9C9371"))
	stat_lbl.clip_text = true
	quick_inspector_box.add_child(stat_lbl)
	var live_lbl := Label.new()
	live_lbl.text = "LIVE: particles 0/0 · t=0.00"
	live_lbl.add_theme_font_size_override("font_size", 10)
	live_lbl.add_theme_color_override("font_color", Color("#B8D890"))
	live_lbl.clip_text = true
	quick_inspector_box.add_child(live_lbl)
	_live_inspection_label = live_lbl

	# 1. renderBase dropdown (RMB resets to factory)
	var rb_row := HBoxContainer.new()
	var rb_lbl := Label.new()
	rb_lbl.text = "renderBase"
	rb_lbl.custom_minimum_size = Vector2(86, 0)
	rb_row.add_child(rb_lbl)
	var rb_opt := OptionButton.new()
	rb_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cur_rb := doc.get_value(hdr, "renderBase", "draw_twirl").strip_edges().trim_prefix("\"").trim_suffix("\"")
	var rb_types := ["draw_twirl", "draw_sprite", "draw_planar", "draw_sphere", "draw_light", "draw_trail", "draw_twirl_trail", "draw_bolt", "draw_beam", "draw_tracer", "draw_wave", "draw_emit", "draw_multi", "draw_geom"]
	if cur_rb != "" and not rb_types.has(cur_rb):
		rb_types.insert(0, cur_rb)
	for rbt in rb_types:
		rb_opt.add_item(rbt)
		if rbt == cur_rb:
			rb_opt.select(rb_opt.item_count - 1)
	rb_opt.item_selected.connect(func(idx: int):
		apply_quick_property(hdr, "renderBase", "\"" + rb_opt.get_item_text(idx) + "\"")
	)
	_bind_quick_rmb(rb_opt, hdr, "renderBase", "\"draw_twirl\"")
	rb_row.add_child(rb_opt)
	quick_inspector_box.add_child(rb_row)

	# 2. simulateBase dropdown (RMB resets to factory)
	var sb_row := HBoxContainer.new()
	var sb_lbl := Label.new()
	sb_lbl.text = "simulateBase"
	sb_lbl.custom_minimum_size = Vector2(86, 0)
	sb_row.add_child(sb_lbl)
	var sb_opt := OptionButton.new()
	sb_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cur_sb := doc.get_value(hdr, "simulateBase", "sim_null").strip_edges().trim_prefix("\"").trim_suffix("\"")
	var sb_types := ["sim_null", "sim_ember", "sim_smoke", "sim_dust", "sim_chunk", "sim_spray"]
	if cur_sb != "" and not sb_types.has(cur_sb):
		sb_types.insert(0, cur_sb)
	for sbt in sb_types:
		sb_opt.add_item(sbt)
		if sbt == cur_sb:
			sb_opt.select(sb_opt.item_count - 1)
	sb_opt.item_selected.connect(func(idx: int):
		apply_quick_property(hdr, "simulateBase", "\"" + sb_opt.get_item_text(idx) + "\"")
	)
	_bind_quick_rmb(sb_opt, hdr, "simulateBase", "\"sim_null\"")
	sb_row.add_child(sb_opt)
	quick_inspector_box.add_child(sb_row)

	# 3. textureName with thumbnail preview + Pick... visual texture browser button (RMB resets)
	var tex_row := HBoxContainer.new()
	tex_row.add_theme_constant_override("separation", 4)
	var tex_lbl := Label.new()
	tex_lbl.text = "textureName"
	tex_lbl.custom_minimum_size = Vector2(86, 0)
	tex_row.add_child(tex_lbl)
	var tex_entry = doc.find_entry(hdr, "textureName")
	var tex_clean := doc.get_value(hdr, "textureName", "").strip_edges().trim_prefix("\"").trim_suffix("\"")
	var thumb_rect := TextureRect.new()
	thumb_rect.custom_minimum_size = Vector2(22, 22)
	thumb_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if tex_clean != "" and index != null:
		var tpath := index.find_asset_near(tex_clean, ["dds", "tga", "png", "jpg"], doc.source_path)
		if tpath != "":
			thumb_rect.texture = _get_texture_thumb(tpath)
	tex_row.add_child(thumb_rect)
	var tex_le := LineEdit.new()
	tex_le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tex_le.text = tex_entry.value_raw if tex_entry != null else ""
	tex_le.placeholder_text = "(unset — click Pick...)"
	tex_le.tooltip_text = "Texture filename (RMB to reset to factory default)"
	tex_le.text_submitted.connect(func(val: String): apply_quick_property(hdr, "textureName", val))
	_bind_quick_rmb(tex_le, hdr, "textureName", "\"flame.tga\"")
	tex_row.add_child(tex_le)
	var pick_tex_btn := Button.new()
	pick_tex_btn.text = "Pick..."
	pick_tex_btn.focus_mode = Control.FOCUS_NONE
	pick_tex_btn.tooltip_text = "Browse all available BZCC textures with visual previews"
	pick_tex_btn.pressed.connect(func(): open_texture_browser(hdr))
	tex_row.add_child(pick_tex_btn)
	quick_inspector_box.add_child(tex_row)

	# 4. textureBlend dropdown
	var bl_row := HBoxContainer.new()
	var bl_lbl := Label.new()
	bl_lbl.text = "textureBlend"
	bl_lbl.custom_minimum_size = Vector2(86, 0)
	bl_row.add_child(bl_lbl)
	var bl_opt := OptionButton.new()
	bl_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cur_bl := doc.get_value(hdr, "textureBlend", "one one modulate").strip_edges().trim_prefix("\"").trim_suffix("\"").to_lower()
	var blends := [
		["Additive (one one modulate)", "one one modulate"],
		["Alpha (srcalpha invsrcalpha modulatealpha)", "srcalpha invsrcalpha modulatealpha"],
		["Subtractive (invsrc invsrc modulate)", "invsrc invsrc modulate"],
		["Additive Alpha (srcalpha one modulate)", "srcalpha one modulate"],
	]
	var matched_bl := -1
	for bi in blends.size():
		bl_opt.add_item(str(blends[bi][0]))
		bl_opt.set_item_metadata(bi, str(blends[bi][1]))
		if str(blends[bi][1]) == cur_bl:
			matched_bl = bi
	if matched_bl < 0 and cur_bl != "":
		bl_opt.add_item(cur_bl)
		bl_opt.set_item_metadata(bl_opt.item_count - 1, cur_bl)
		matched_bl = bl_opt.item_count - 1
	if matched_bl >= 0:
		bl_opt.select(matched_bl)
	bl_opt.item_selected.connect(func(idx: int):
		apply_quick_property(hdr, "textureBlend", "\"" + str(bl_opt.get_item_metadata(idx)) + "\"")
	)
	_bind_quick_rmb(bl_opt, hdr, "textureBlend", "\"one one modulate\"")
	bl_row.add_child(bl_opt)
	quick_inspector_box.add_child(bl_row)

	# 5. Color pickers (startColor / finishColor) + RGBA text + RMB reset
	for ckey in ["startColor", "finishColor"]:
		var crow := HBoxContainer.new()
		crow.add_theme_constant_override("separation", 4)
		var clbl := Label.new()
		clbl.text = ckey
		clbl.custom_minimum_size = Vector2(86, 0)
		crow.add_child(clbl)
		var centry = doc.find_entry(hdr, ckey)
		var raw_c := doc.get_value(hdr, ckey, "")
		var parsed_c := EffectRuntime._color(raw_c, Color(1, 0.8, 0.3, 1) if ckey == "startColor" else Color(1, 0.2, 0.0, 0))
		var cpick := ColorPickerButton.new()
		cpick.custom_minimum_size = Vector2(36, 22)
		cpick.color = parsed_c
		cpick.edit_alpha = true
		cpick.tooltip_text = "Pick %s RGBA visually (RMB to reset to factory default)" % ckey
		cpick.color_changed.connect(func(nc: Color):
			apply_quick_property(hdr, ckey, _color_to_odf_rgba(nc))
		)
		_bind_quick_rmb(cpick, hdr, ckey, "\"255 255 255 255\"" if ckey == "startColor" else "\"255 255 255 0\"")
		crow.add_child(cpick)
		var cle := LineEdit.new()
		cle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cle.text = centry.value_raw if centry != null else ""
		cle.placeholder_text = "\"R G B A\""
		cle.tooltip_text = "R G B A (0-255) · RMB to reset to factory default"
		cle.text_submitted.connect(func(val: String): apply_quick_property(hdr, ckey, val))
		_bind_quick_rmb(cle, hdr, ckey, "\"255 255 255 255\"" if ckey == "startColor" else "\"255 255 255 0\"")
		crow.add_child(cle)
		quick_inspector_box.add_child(crow)

	# 6. Numeric HoudiniScrubbers (all with factory defaults -> RMB resets!)
	var num_keys: Array[String] = ["lifeTime", "animateTime", "emitDelay", "startRadius", "finishRadius", "rotationRate", "maxCount"]
	if cur_rb.to_lower() == "draw_bolt" or cur_rb.to_lower() == "draw_beam":
		num_keys.append("segmentLength")
	for key: String in num_keys:
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = key
		lbl.custom_minimum_size = Vector2(86, 0)
		row.add_child(lbl)
		var scrub = HoudiniScrubberScript.new()
		var cur_val: float = doc.get_float(hdr, key, 1.0 if (key == "lifeTime" or key == "animateTime") else (7.0 if key == "segmentLength" else 0.0))
		var fac_raw: String = _factory_quick_value(hdr, key, str(cur_val))
		var fac_val: float = fac_raw.strip_edges().trim_prefix("\"").trim_suffix("\"").to_float() if fac_raw != "" else cur_val
		var hi: float = 30.0 if (key == "lifeTime" or key == "animateTime") else (5.0 if key == "emitDelay" else (64.0 if key == "maxCount" else maxf(10.0, cur_val * 2.5)))
		var is_int: bool = (key == "maxCount")
		scrub.configure(0.0, hi, 1.0 if is_int else 0.05, cur_val, "", true, true, is_int)
		scrub.set_default_value(fac_val)
		scrub.set_pill_width(58)
		scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scrub.value_changed.connect(func(v: float):
			var txt_v := str(int(round(v))) if is_int else ("%.4f" % v).rstrip("0").rstrip(".")
			apply_quick_property(hdr, key, txt_v)
		)
		row.add_child(scrub)
		quick_inspector_box.add_child(row)

	# 7. BottomInteractsWithTerrain toggle (RMB resets)
	var bt_row := HBoxContainer.new()
	var bt_lbl := Label.new()
	bt_lbl.text = "Floor Clamp"
	bt_lbl.custom_minimum_size = Vector2(86, 0)
	bt_row.add_child(bt_lbl)
	var bt_chk := CheckButton.new()
	var cur_bt := doc.get_value(hdr, "BottomInteractsWithTerrain", "true").strip_edges().to_lower()
	bt_chk.button_pressed = (cur_bt != "false" and cur_bt != "0" and cur_bt != "no")
	bt_chk.text = "BottomInteractsWithTerrain"
	bt_chk.tooltip_text = "Keep sprite/sphere bottom above ground plane y=0 (RMB to reset)"
	bt_chk.toggled.connect(func(on: bool): apply_quick_property(hdr, "BottomInteractsWithTerrain", "true" if on else "false"))
	_bind_quick_rmb(bt_chk, hdr, "BottomInteractsWithTerrain", "true")
	bt_row.add_child(bt_chk)
	quick_inspector_box.add_child(bt_row)


func apply_quick_property(header: String, key: String, raw_value: String) -> bool:
	if doc == null or header == "" or key == "":
		return false
	var val := raw_value.strip_edges()
	if val == "":
		return false
	var entry = doc.find_entry(header, key)
	if entry != null:
		doc.set_entry_value(entry, val)
	else:
		doc.append_entry(header, key, val)
	status_changed.emit("Quick-edited [%s].%s = %s" % [header, key, val], "success")
	document_edited.emit()
	load_document(doc)
	select_headers([header])
	return true


## Copy selected render headers (with raw body lines and internal links) to clipboard.
func copy_selected_nodes() -> Array[Dictionary]:
	var sel := get_selected_headers()
	if doc == null or sel.is_empty():
		status_changed.emit("Copy: select one or more render nodes first.", "warning")
		return []
	var copied: Array[Dictionary] = []
	for h in sel:
		var body := doc.extract_header_body(h, -1)
		if body == "":
			continue
		copied.append({"header": h, "body": body})
	_clipboard_nodes = copied
	_update_toolbar()
	status_changed.emit("Copied %d render node(s)." % copied.size(), "success")
	return copied


## Paste copied render nodes into the active document in ONE compound undo step,
## remapping internal emitName/renderNameN links between pasted headers.
func paste_nodes() -> Array[String]:
	if doc == null or _clipboard_nodes.is_empty():
		status_changed.emit("Paste: clipboard is empty.", "warning")
		return []
	return _clone_header_records(_clipboard_nodes, "Pasted")


## Duplicate the selected subgraph (1 or more nodes + internal edges) in a
## single compound undoable edit.
func duplicate_selected_subgraph() -> Array[String]:
	var sel := get_selected_headers()
	if doc == null or sel.is_empty():
		status_changed.emit("Duplicate subgraph: select one or more render nodes first.", "warning")
		return []
	var records: Array[Dictionary] = []
	for h in sel:
		var body := doc.extract_header_body(h, -1)
		if body != "":
			records.append({"header": h, "body": body})
	if records.is_empty():
		return []
	return _clone_header_records(records, "Duplicated subgraph")


func _clone_header_records(records: Array[Dictionary], verb: String) -> Array[String]:
	var rename_map := {}
	var created: Array[String] = []
	var reserved := {}
	doc.begin_compound()
	for rec in records:
		var orig := str(rec.get("header", ""))
		var cand := _unique_header_name(orig)
		var n := 2
		while reserved.has(cand.to_lower()):
			cand = "%s_copy%d" % [orig, n]
			n += 1
		reserved[cand.to_lower()] = true
		rename_map[orig.to_lower()] = cand
		if doc.append_header_block(cand, str(rec.get("body", ""))):
			created.append(cand)
	# Remap internal edges so duplicated/pasted subgraphs stay self-contained.
	for new_hdr in created:
		for key in _child_keys(doc, new_hdr):
			var e = doc.find_entry(new_hdr, key)
			if e == null:
				continue
			var target_lc: String = str(e.core_value()).strip_edges().to_lower()
			if rename_map.has(target_lc):
				var replacement := str(rename_map[target_lc])
				if e.value_raw.strip_edges().begins_with("\""):
					doc.set_entry_value(e, "\"" + replacement + "\"")
				else:
					doc.set_entry_value(e, replacement)
	doc.end_compound()
	if created.is_empty():
		return []
	status_changed.emit("%s: %d node(s) (%s)" % [verb, created.size(), ", ".join(created)], "success")
	document_edited.emit()
	load_document(doc)
	select_headers(created)
	return created


func _on_preset_selected(idx: int) -> void:
	if preset_option == null:
		return
	var pid := str(preset_option.get_item_metadata(idx))
	preset_option.select(0)
	if pid != "":
		insert_preset(pid)


## Insert a reusable documented BZCC emitter preset as a single undoable edit.
func insert_preset(preset_id: String) -> String:
	if doc == null or not EMITTER_PRESETS.has(preset_id):
		return ""
	var spec: Dictionary = EMITTER_PRESETS[preset_id]
	var base := str(spec.get("base_name", "Preset"))
	var candidate := base
	var n := 2
	while doc.has_header(candidate):
		candidate = "%s%d" % [base, n]
		n += 1
	doc.begin_compound()
	for pair in spec.get("props", []):
		doc.append_entry(candidate, str(pair[0]), str(pair[1]))
	doc.end_compound()
	status_changed.emit("Inserted preset [%s] (%s)" % [candidate, str(spec.get("label", preset_id))], "success")
	document_edited.emit()
	load_document(doc)
	select_headers([candidate])
	return candidate


## Coordinated multi-file save for the active render ODF and every dirty
## external ODF referenced via `file.header`. Saves exclusively to isolated
## WorkspaceStore overrides; original Workshop/Game files remain untouched.
## Implements P1-05 coordinated save-group transaction snapshot and PARTIAL_SAVE_RECOVERABLE.
func save_with_external_dependencies(options: Dictionary = {}) -> Dictionary:
	var targets: Array = []
	var seen := {}
	if doc != null and doc.source_path != "":
		targets.append(doc)
		seen[doc.source_path] = true
	for ext_key in _external_nodes:
		var ep := str((_external_nodes[ext_key] as Dictionary).get("path", ""))
		if ep == "" or seen.has(ep):
			continue
		var ext_doc = OdfDocument.cached(ep)
		if ext_doc is OdfDocument and (ext_doc.dirty or ext_doc.workspace_override):
			targets.append(ext_doc)
			seen[ep] = true

	var fail_on := WorkspaceStore.canonical(str(options.get("fail_on_path", ""))).to_lower() if str(options.get("fail_on_path", "")) != "" else ""
	var group_id := "pgrp_%d" % Time.get_ticks_usec()
	var snapshots := {}
	for d in targets:
		var sp := str(d.source_path)
		var prev_ws_bytes := PackedByteArray()
		var ws_entry := WorkspaceStore.entry_for(sp)
		var had_ws := not ws_entry.is_empty()
		if had_ws:
			var ws_abs := ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(str(ws_entry.get("rel", ""))))
			if FileAccess.file_exists(ws_abs):
				prev_ws_bytes = FileAccess.get_file_as_bytes(ws_abs)
		snapshots[sp] = {
			"had_workspace_override": had_ws,
			"previous_workspace_bytes": "" if prev_ws_bytes.is_empty() else Marshalls.raw_to_base64(prev_ws_bytes),
			"working_text": d.text,
			"revision": int(d.revision),
		}

	var saved: Array[String] = []
	var failed: Array[Dictionary] = []
	for d in targets:
		var sp := str(d.source_path)
		if fail_on != "" and WorkspaceStore.canonical(sp).to_lower() == fail_on:
			failed.append({"path": sp, "error": "FORCED_SAVE_FAILURE"})
			continue
		if not d.dirty and d.workspace_override:
			saved.append(sp)
			continue
		var res := WorkspaceStore.save_document(d)
		if bool(res.get("ok", false)):
			saved.append(sp)
		else:
			failed.append({"path": sp, "error": str(res.get("error", "save failed"))})

	var status := "COMPLETE"
	if not failed.is_empty() and not saved.is_empty():
		status = "PARTIAL_SAVE_RECOVERABLE"
	elif not failed.is_empty():
		status = "SAVE_FAILED"

	last_save_group = {
		"group_id": group_id,
		"status": status,
		"saved": saved,
		"failed": failed,
		"snapshots": snapshots,
		"timestamp": Time.get_datetime_string_from_system(),
	}
	var grp_dir := ProjectSettings.globalize_path(WorkspaceStore.root().path_join("save_groups"))
	DirAccess.make_dir_recursive_absolute(grp_dir)
	WorkspaceStore.atomic_write_abs(grp_dir.path_join(group_id + ".json"), JSON.stringify(last_save_group, "  ").to_utf8_buffer())
	return {
		"ok": failed.is_empty(),
		"status": status,
		"group_id": group_id,
		"saved": saved,
		"failed": failed,
		"recoverable": status == "PARTIAL_SAVE_RECOVERABLE",
	}


func recover_partial_save_group() -> Dictionary:
	if last_save_group.is_empty():
		return {"ok": false, "reason": "NO_SAVE_GROUP"}
	var snaps: Dictionary = last_save_group.get("snapshots", {})
	var restored: Array[String] = []
	var failed: Array[Dictionary] = []
	for sp in snaps:
		var sinfo: Dictionary = snaps[sp]
		var had_ws := bool(sinfo.get("had_workspace_override", false))
		var d = OdfDocument.cached(str(sp))
		if not had_ws:
			if d != null:
				var rres := WorkspaceStore.revert_document(d)
				if not bool(rres.get("ok", false)):
					failed.append({"path": str(sp), "status": str(rres.get("status", "FAILED")), "error": str(rres.get("error", ""))})
					continue
		else:
			var prev_raw := Marshalls.base64_to_raw(str(sinfo.get("previous_workspace_bytes", "")))
			if not prev_raw.is_empty() and d != null:
				d.replace_text(prev_raw.get_string_from_utf8())
				var sres := WorkspaceStore.save_document(d)
				if not bool(sres.get("ok", false)):
					failed.append({"path": str(sp), "status": str(sres.get("status", "FAILED")), "error": str(sres.get("error", ""))})
					continue
		restored.append(str(sp))
	last_save_group["status"] = "RECOVERED" if failed.is_empty() else "PARTIAL_RECOVERY"
	if doc != null:
		load_document(doc)
	return {"ok": failed.is_empty(), "status": str(last_save_group["status"]), "restored": restored, "failed": failed}


func _active_reset_scope() -> String:
	if reset_scope_option != null and reset_scope_option.selected >= 0:
		return str(reset_scope_option.get_item_metadata(reset_scope_option.selected))
	return RESET_SCOPE_THIS_ODF


func preview_dependency_graph_reset() -> Dictionary:
	var targets: Array[Dictionary] = []
	var seen := {}
	if doc != null and doc.source_path != "":
		var c0 := WorkspaceStore.canonical(doc.source_path).to_lower()
		seen[c0] = true
		targets.append({
			"path": doc.source_path,
			"role": "active_render_odf",
			"dirty": bool(doc.dirty),
			"workspace_override": bool(doc.workspace_override) or not WorkspaceStore.entry_for(doc.source_path).is_empty(),
			"source_exists": FileAccess.file_exists(doc.source_path),
		})
	for ext_key in _external_nodes:
		var ep := str((_external_nodes[ext_key] as Dictionary).get("path", ""))
		if ep == "":
			continue
		var ce := WorkspaceStore.canonical(ep).to_lower()
		if seen.has(ce):
			continue
		seen[ce] = true
		var edoc = OdfDocument.cached(ep)
		var has_ws := not WorkspaceStore.entry_for(ep).is_empty()
		var is_dirty := edoc is OdfDocument and bool(edoc.dirty)
		if is_dirty or has_ws or (edoc is OdfDocument and bool(edoc.workspace_override)):
			targets.append({
				"path": ep,
				"role": "external_dependency",
				"dirty": is_dirty,
				"workspace_override": has_ws or (edoc is OdfDocument and bool(edoc.workspace_override)),
				"source_exists": FileAccess.file_exists(ep),
			})
	var preview := {
		"scope": RESET_SCOPE_DEPENDENCY_GRAPH,
		"total_affected_count": targets.size(),
		"targets": targets,
	}
	last_dep_reset_impact = preview
	return preview


func cancel_dependency_graph_reset() -> void:
	dep_reset_confirmation_pending = false
	if _dep_reset_dialog != null and _dep_reset_dialog.visible:
		_dep_reset_dialog.hide()
	status_changed.emit("Dependency graph reset cancelled; all files preserved.", "muted")


func confirm_dependency_graph_reset() -> Dictionary:
	dep_reset_confirmation_pending = false
	if _dep_reset_dialog != null and _dep_reset_dialog.visible:
		_dep_reset_dialog.hide()
	return reset_document_to_default(RESET_SCOPE_DEPENDENCY_GRAPH, true)


## Scoped Particle Lab reset (P0-03). Default RESET THIS ODF affects ONLY the
## currently active Particle Lab ODF and never silently resets cached external
## dependencies. RESET DEPENDENCY GRAPH requires explicit confirmation + impact
## preview + multi-file recovery point.
func reset_document_to_default(scope: String = RESET_SCOPE_THIS_ODF, confirmed: bool = false) -> Dictionary:
	if doc == null:
		status_changed.emit("Reset ODF: no render ODF loaded.", "warning")
		last_reset_result = {"ok": false, "status": "NO_DOCUMENT", "scope": scope}
		return last_reset_result

	match scope:
		RESET_SCOPE_SELECTED_NODE:
			if _selected_header == "":
				status_changed.emit("Reset node: select a render node first.", "warning")
				last_reset_result = {"ok": false, "status": "NO_NODE_SELECTED", "scope": scope}
				return last_reset_result
			var ok_n := reset_header_to_default(_selected_header)
			last_reset_result = {"ok": ok_n, "status": "SUCCESS" if ok_n else "FAILED", "scope": scope, "header": _selected_header}
			return last_reset_result

		RESET_SCOPE_SELECTED_EXTERNAL:
			if _selected_external_path == "":
				status_changed.emit("Reset external ODF: select an external node first.", "warning")
				last_reset_result = {"ok": false, "status": "NO_EXTERNAL_SELECTED", "scope": scope}
				return last_reset_result
			var ext_doc = OdfDocument.cached(_selected_external_path)
			var ext_res: Dictionary
			if ext_doc is OdfDocument:
				ext_res = WorkspaceStore.revert_document(ext_doc)
			else:
				var d_res := WorkspaceStore.discard_override_ex(_selected_external_path)
				ext_res = {
					"ok": bool(d_res.get("ok", false)) or str(d_res.get("status", "")) == "NOT_FOUND",
					"status": "NO_OVERRIDE" if str(d_res.get("status", "")) == "NOT_FOUND" else str(d_res.get("status", "")),
					"outcome": "SUCCESS" if bool(d_res.get("ok", false)) else "RESET_FAILED_RECOVERABLE",
					"error": str(d_res.get("error", "")),
				}
			if not bool(ext_res.get("ok", false)):
				status_changed.emit("Reset external ODF failed (%s): %s" % [str(ext_res.get("status", "")), str(ext_res.get("error", ""))], "danger")
				last_reset_result = {"ok": false, "status": str(ext_res.get("status", "FAILED")), "outcome": str(ext_res.get("outcome", "RESET_FAILED_RECOVERABLE")), "scope": scope, "path": _selected_external_path}
				return last_reset_result
			document_edited.emit()
			load_document(doc)
			status_changed.emit("Reset selected external ODF (%s) to factory default." % _selected_external_path.get_file(), "success")
			last_reset_result = {"ok": true, "status": str(ext_res.get("status", "SUCCESS")), "scope": scope, "path": _selected_external_path}
			return last_reset_result

		RESET_SCOPE_DEPENDENCY_GRAPH:
			var impact := preview_dependency_graph_reset()
			var targets: Array = impact.get("targets", [])
			if not confirmed:
				dep_reset_confirmation_pending = true
				if _dep_reset_dialog != null:
					var lines: Array[String] = ["Resetting the dependency graph will revert %d file(s):" % targets.size(), ""]
					for t in targets:
						lines.append("• %s (%s)" % [str(t.get("path", "")).get_file(), str(t.get("role", ""))])
					lines.append("")
					lines.append("A multi-file recovery point will be created before any reset.")
					_dep_reset_dialog.dialog_text = "\n".join(lines)
					if is_inside_tree():
						_dep_reset_dialog.popup_centered()
				status_changed.emit("Dependency graph reset requires confirmation (%d file(s))." % targets.size(), "warning")
				last_reset_result = {
					"ok": false,
					"status": "CONFIRMATION_REQUIRED",
					"confirmation_required": true,
					"scope": scope,
					"impact": impact,
					"requested": targets.size(),
					"attempted": 0,
					"succeeded": 0,
					"failed": 0,
				}
				return last_reset_result
			var target_paths: Array = []
			for t in targets:
				target_paths.append(str(t.get("path", "")))
			var rec_pt := WorkspaceStore.create_reset_recovery_point(target_paths, RESET_SCOPE_DEPENDENCY_GRAPH)
			if not bool(rec_pt.get("ok", false)):
				status_changed.emit("Dependency graph reset aborted: could not create recovery point (%s)" % str(rec_pt.get("error", "")), "danger")
				last_reset_result = {
					"ok": false,
					"status": str(rec_pt.get("status", "BACKUP_FAILED")),
					"outcome": "RESET_FAILED_RECOVERABLE",
					"scope": scope,
					"requested": targets.size(),
					"attempted": 0,
					"succeeded": 0,
					"failed": targets.size(),
				}
				return last_reset_result
			var succeeded_paths: Array[String] = []
			var failed_items: Array[Dictionary] = []
			var already_default := 0
			var recovery_pending := 0
			for tp in target_paths:
				var td = OdfDocument.cached(tp)
				var rres: Dictionary
				if td is OdfDocument:
					rres = WorkspaceStore.revert_document(td)
				else:
					var dres := WorkspaceStore.discard_override_ex(tp)
					rres = {
						"ok": bool(dres.get("ok", false)) or str(dres.get("status", "")) == "NOT_FOUND",
						"status": "NO_OVERRIDE" if str(dres.get("status", "")) == "NOT_FOUND" else str(dres.get("status", "")),
						"recovery_pending": str(dres.get("status", "")) == WorkspaceStore.TX_RECOVERY_PENDING,
						"error": str(dres.get("error", "")),
					}
				if bool(rres.get("ok", false)):
					if str(rres.get("status", "")) == "NO_OVERRIDE":
						already_default += 1
					else:
						succeeded_paths.append(tp)
				else:
					if bool(rres.get("recovery_pending", false)):
						recovery_pending += 1
					failed_items.append({"path": tp, "status": str(rres.get("status", "FAILED")), "error": str(rres.get("error", ""))})
			var fstat := "COMMITTED" if failed_items.is_empty() else ("PARTIAL_FAILURE" if not succeeded_paths.is_empty() else "RESET_FAILED_RECOVERABLE")
			WorkspaceStore.finalize_reset_recovery_point(str(rec_pt.get("path", "")), fstat, {"succeeded": succeeded_paths.size(), "failed": failed_items.size()})
			document_edited.emit()
			load_document(doc)
			if failed_items.is_empty():
				status_changed.emit("Reset dependency graph: %d file(s) restored to factory defaults." % succeeded_paths.size(), "success")
			else:
				status_changed.emit("Dependency graph reset incomplete: %d succeeded, %d failed (recovery point preserved)." % [succeeded_paths.size(), failed_items.size()], "danger")
			last_reset_result = {
				"ok": failed_items.is_empty(),
				"status": "SUCCESS" if failed_items.is_empty() else fstat,
				"outcome": "SUCCESS" if failed_items.is_empty() else "RESET_FAILED_RECOVERABLE",
				"scope": scope,
				"recovery_point": str(rec_pt.get("path", "")),
				"requested": target_paths.size(),
				"attempted": target_paths.size(),
				"succeeded": succeeded_paths.size(),
				"failed": failed_items.size(),
				"already_default": already_default,
				"recovery_pending": recovery_pending,
				"succeeded_files": succeeded_paths,
				"failed_files": failed_items,
			}
			return last_reset_result

		_:
			# Default scope: RESET_THIS_ODF — ONLY the currently active render ODF!
			# External dependencies in _external_nodes are NEVER touched silently (P0-03).
			var res := WorkspaceStore.revert_document(doc)
			if not bool(res.get("ok", false)):
				status_changed.emit("Reset ODF failed (%s): %s" % [str(res.get("status", "")), str(res.get("error", ""))], "danger")
				last_reset_result = {
					"ok": false,
					"status": str(res.get("status", "FAILED")),
					"outcome": str(res.get("outcome", "RESET_FAILED_RECOVERABLE")),
					"recovery_pending": bool(res.get("recovery_pending", false)),
					"scope": RESET_SCOPE_THIS_ODF,
					"path": doc.source_path,
					"external_untouched": true,
					"error": str(res.get("error", "")),
				}
				return last_reset_result
			document_edited.emit()
			load_document(doc)
			status_changed.emit("Reset Particle Lab ODF (%s) to factory default (external dependencies untouched)." % doc.get_display_name(), "success")
			last_reset_result = {
				"ok": true,
				"status": str(res.get("status", "SUCCESS")),
				"outcome": str(res.get("outcome", "SUCCESS")),
				"scope": RESET_SCOPE_THIS_ODF,
				"path": doc.source_path,
				"external_untouched": true,
			}
			return last_reset_result


func reset_header_to_default(header: String, occurrence_index: int = -1, mode: String = "FULL_FACTORY_HEADER") -> bool:
	if doc == null or header == "" or doc.source_path == "" or not FileAccess.file_exists(doc.source_path):
		return false
	var factory_doc := OdfDocument.load_file(doc.source_path)
	if factory_doc == null:
		return false
	if not factory_doc.has_header(header):
		var occ := occurrence_index if occurrence_index >= 0 else maxi(0, doc.header_occurrence_count(header) - 1)
		if doc.remove_header(header, occ):
			document_edited.emit()
			load_document(doc)
			status_changed.emit("Removed custom render node [%s] (reverted to factory default)." % header, "success")
			return true
		return false
	if mode == "FULL_FACTORY_HEADER":
		var replaced := doc.replace_header_occurrence_from_factory(factory_doc, header, occurrence_index)
		if not replaced:
			status_changed.emit("Render node [%s] already matches factory default." % header, "muted")
			return false
		document_edited.emit()
		load_document(doc)
		select_headers([header])
		status_changed.emit("Restored complete factory render header [%s] (removed custom properties)." % header, "success")
		return true
	# KNOWN_PROPERTIES_ONLY mode: explicitly restores only matching factory properties.
	doc.begin_compound()
	var changed_any := false
	var target_occ := occurrence_index if occurrence_index >= 0 else maxi(0, doc.header_occurrence_count(header) - 1)
	var f_occ := mini(target_occ, maxi(0, factory_doc.header_occurrence_count(header) - 1))
	for fe in factory_doc.entries:
		if fe.header.to_lower() == header.to_lower() and fe.occurrence_index == f_occ:
			var ce = doc.find_entry_occurrence(header, fe.full_key(), target_occ, fe.header_key_occurrence_index, fe.key_occurrence_index)
			if ce != null:
				if str(ce.value_raw) != str(fe.value_raw):
					doc.set_entry_value(ce, fe.value_raw)
					changed_any = true
			else:
				doc.append_entry(header, fe.full_key(), fe.value_raw, doc.header_id_for(header, target_occ))
				changed_any = true
	doc.end_compound()
	if not changed_any:
		return false
	document_edited.emit()
	load_document(doc)
	select_headers([header])
	status_changed.emit("Restored matching known factory properties on [%s] (custom properties kept)." % header, "success")
	return true


func reset_preview_view() -> void:
	if speed_spin != null:
		speed_spin.value = 1.0
	if play_button != null and play_button.button_pressed:
		play_button.button_pressed = false
	if preview_camera != null:
		preview_camera.look_at_from_position(Vector3(7, 4.5, 9), Vector3(0, 1.5, 0), Vector3.UP)
	_restart_preview()
	status_changed.emit("Reset Particle Lab 3D preview speed and view.", "muted")


func _on_save_dependencies() -> void:
	if doc == null:
		status_changed.emit("Save dependencies: no render ODF loaded.", "warning")
		return
	var res := save_with_external_dependencies()
	var saved_arr: Array = res.get("saved", [])
	var failed_arr: Array = res.get("failed", [])
	if bool(res.get("ok", false)):
		status_changed.emit("Saved %d render ODF(s) with dependencies to isolated workspace." % saved_arr.size(), "success")
		load_document(doc)
	else:
		status_changed.emit("Saved %d, failed %d dependency file(s)." % [saved_arr.size(), failed_arr.size()], "danger")


func dirty_dependency_count() -> int:
	var n := 0
	var seen := {}
	if doc != null and doc.dirty:
		n += 1
		seen[doc.source_path] = true
	for ext_key in _external_nodes:
		var ep := str((_external_nodes[ext_key] as Dictionary).get("path", ""))
		if ep == "" or seen.has(ep):
			continue
		var ext_doc = OdfDocument.cached(ep)
		if ext_doc is OdfDocument and ext_doc.dirty:
			n += 1
			seen[ep] = true
	return n


func depends_on_path(path: String) -> bool:
	if path == "" or doc == null:
		return false
	var canon := WorkspaceStore.canonical(path).to_lower()
	if WorkspaceStore.canonical(doc.source_path).to_lower() == canon:
		return true
	for ext_key in _external_nodes:
		var ep := WorkspaceStore.canonical(str((_external_nodes[ext_key] as Dictionary).get("path", ""))).to_lower()
		if ep != "" and ep == canon:
			return true
	return false


## Rebuild the live 3D particle preview from the shared OdfDocument cache
## (including any live in-memory edits to external `file.header` ODFs).
func refresh_preview_live() -> Dictionary:
	_clear_emitters()
	if doc == null or preview_root == null:
		return {"emitters": 0, "nodes": 0}
	var built := EffectRuntime.build_document_preview(index, doc)
	_header_preview_nodes = built.get("header_nodes", {})
	for pn in built.get("nodes", []):
		preview_root.add_child(pn)
		_preview_nodes.append(pn)
	for em in built.get("emitters", []):
		_emitters.append(em)
	_apply_emitter_mute_solo()
	if counter_label != null:
		counter_label.text = "render nodes: %d    emitters: %d" % [doc.render_headers().size(), _emitters.size()]
	_update_toolbar()
	return {"emitters": _emitters.size(), "nodes": _preview_nodes.size()}


## Called by MainWindow whenever ANY document is edited so cross-file external
## render edits immediately refresh ParticleLab's live preview and node summary.
func refresh_if_depends_on(edited_doc: OdfDocument) -> bool:
	if doc == null or edited_doc == null:
		return false
	if edited_doc == doc:
		load_document(doc)
		return true
	if depends_on_path(edited_doc.source_path):
		load_document(doc)
		status_changed.emit("Particle Lab live preview refreshed from external dependency %s" % edited_doc.get_display_name(), "muted")
		return true
	return false


func _layout_path() -> String:
	return WorkspaceStore.root().path_join("graph_layout.json")


func _layout_key() -> String:
	return doc.source_path if doc != null and doc.source_path != "" else "(unsaved)"


## Restore saved node positions for this source path. A layout is cosmetic UI
## state, never ODF content, and lives inside the workspace root.
func _apply_layout() -> void:
	if doc == null or graph == null:
		return
	var path := ProjectSettings.globalize_path(_layout_path())
	if not FileAccess.file_exists(path):
		return
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	var parsed = jres.get("data", null) if bool(jres.get("ok", false)) else null
	if not (parsed is Dictionary):
		return
	var doc_layout = parsed.get(_layout_key(), null)
	if not (doc_layout is Dictionary):
		return
	for c in graph.get_children():
		if c is GraphNode and c.has_meta("header"):
			var pos = doc_layout.get(str(c.get_meta("header")), null)
			if pos is Array and pos.size() == 2:
				c.position_offset = Vector2(float(pos[0]), float(pos[1]))


func _save_layout() -> void:
	if doc == null or graph == null:
		return
	var path := ProjectSettings.globalize_path(_layout_path())
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var all := {}
	if FileAccess.file_exists(path):
		var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
		var parsed = jres.get("data", null) if bool(jres.get("ok", false)) else null
		if parsed is Dictionary:
			all = parsed
	var positions := {}
	for c in graph.get_children():
		if c is GraphNode and c.has_meta("header"):
			positions[str(c.get_meta("header"))] = [c.position_offset.x, c.position_offset.y]
	all[_layout_key()] = positions
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(all, "\t"))
	f.close()


func _update_toolbar() -> void:
	if undo_button == null or doc == null:
		return
	var sel_count := get_selected_headers().size()
	undo_button.disabled = not doc.can_undo()
	redo_button.disabled = not doc.can_redo()
	new_button.disabled = doc == null
	rename_button.disabled = _selected_header == ""
	duplicate_button.disabled = _selected_header == ""
	if subgraph_button != null:
		subgraph_button.disabled = sel_count == 0
	if copy_button != null:
		copy_button.disabled = sel_count == 0
	if paste_button != null:
		paste_button.disabled = _clipboard_nodes.is_empty()
	if save_deps_button != null:
		var dcnt := dirty_dependency_count()
		save_deps_button.disabled = doc == null
		save_deps_button.text = "SAVE DEPENDENCIES (%d)" % dcnt if dcnt > 0 else "SAVE DEPENDENCIES"
	var deletable := _selected_header != "" and not _is_referenced(_selected_header)
	delete_button.disabled = not deletable or doc.render_headers().size() <= 1
	if _selected_header != "" and _is_referenced(_selected_header):
		delete_button.tooltip_text = "Still referenced by another node; disconnect those links first."
	else:
		delete_button.tooltip_text = "Remove the selected header and all its property lines."


func _is_referenced(header: String) -> bool:
	for h in doc.render_headers():
		for key in _child_keys(doc, h.name):
			if _reference_header(doc.get_value(h.name, key, "")) == header:
				return true
	return false


## Depth-first reachability over local references. A new src -> dst edge is
## invalid when dst already reaches src.
func _would_cycle(src: String, dst: String) -> bool:
	var stack: Array[String] = [dst]
	var seen := {}
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		var key := cur.to_lower()
		if seen.has(key):
			continue
		seen[key] = true
		for child_key in _child_keys(doc, cur):
			var nxt := _reference_header(doc.get_value(cur, child_key, ""))
			if nxt == "":
				continue
			if nxt.to_lower() == src.to_lower():
				return true
			stack.append(nxt)
	return false


func _unique_header_name(base: String) -> String:
	var candidate := base + "_copy"
	var n := 2
	while doc.has_header(candidate):
		candidate = "%s_copy%d" % [base, n]
		n += 1
	return candidate


func _on_duplicate_node() -> void:
	if doc == null or _selected_header == "":
		status_changed.emit("Duplicate: select a render node first.", "warning")
		return
	var new_name := _unique_header_name(_selected_header)
	# The graph shows effective values: copy the last physical occurrence.
	var occurrence := maxi(0, doc.header_occurrence_count(_selected_header) - 1)
	if not doc.duplicate_header(_selected_header, new_name, occurrence):
		status_changed.emit("Duplicate failed: the source header has no property lines.", "warning")
		return
	status_changed.emit("Duplicated %s -> %s" % [_selected_header, new_name], "success")
	document_edited.emit()
	load_document(doc)
	var node := graph.get_node_or_null(NodePath(new_name.validate_node_name()))
	if node is GraphNode:
		_selected_header = new_name
		node.selected = true
		_update_toolbar()


func _on_delete_node() -> void:
	if doc == null or _selected_header == "":
		status_changed.emit("Delete: select a render node first.", "warning")
		return
	if _is_referenced(_selected_header):
		status_changed.emit("Delete refused: %s is still referenced. Disconnect those links first." % _selected_header, "warning")
		return
	if doc.render_headers().size() <= 1:
		status_changed.emit("Delete refused: the document needs at least one render header.", "warning")
		return
	var removed := _selected_header
	# Remove the occurrence the graph actually displays (the effective last one).
	var occurrence := maxi(0, doc.header_occurrence_count(removed) - 1)
	if not doc.remove_header(removed, occurrence):
		status_changed.emit("Delete failed: header not found.", "warning")
		return
	status_changed.emit("Deleted header %s (undo available)" % removed, "success")
	document_edited.emit()
	load_document(doc)


func _on_new_node() -> void:
	if doc == null and context_doc != null:
		doc = context_doc
	if doc == null:
		status_changed.emit("New node: open an ODF first.", "warning")
		return
	var default_hint := "NewRender"
	if doc.render_headers().is_empty():
		if doc.has_header("WeaponClass"):
			default_hint = "Flash"
		elif doc.has_header("OrdnanceClass"):
			default_hint = "Render"
	create_render_node(default_hint)


func _on_rename_node() -> void:
	if doc == null or _selected_header == "":
		status_changed.emit("Rename: select a render node first.", "warning")
		return
	_name_mode = "rename"
	_name_dialog.title = "Rename [%s]" % _selected_header
	_name_edit.text = _selected_header
	_name_dialog.popup_centered()


func _apply_name_dialog(text: String) -> void:
	if _name_mode == "new":
		create_render_node(text)
	elif _name_mode == "rename":
		rename_render_node(_selected_header, text)
	_name_mode = ""


## Create a real render header with documented renderBase values and ready-to-edit defaults.
func create_render_node(name_hint: String = "NewRender") -> String:
	if doc == null and context_doc != null:
		doc = context_doc
	if doc == null:
		return ""
	var base := name_hint.strip_edges()
	if base == "":
		base = "NewRender"
	var candidate := base
	var n := 2
	while doc.has_header(candidate):
		candidate = "%s%d" % [base, n]
		n += 1
	doc.begin_compound()
	doc.append_entry(candidate, "simulateBase", "\"sim_null\"")
	doc.append_entry(candidate, "lifeTime", "1.0")
	doc.append_entry(candidate, "renderBase", "draw_sprite")
	doc.append_entry(candidate, "textureName", "\"flame.tga\"")
	doc.append_entry(candidate, "textureBlend", "\"one one modulate\"")
	doc.append_entry(candidate, "startColor", "255 200 80 255")
	doc.append_entry(candidate, "finishColor", "255 60 0 0")
	doc.append_entry(candidate, "startRadius", "0.5")
	doc.append_entry(candidate, "finishRadius", "2.0")
	doc.append_entry(candidate, "animateTime", "1.0")
	doc.end_compound()
	status_changed.emit("Created render header [%s] (draw_sprite) — edit properties in Quick Render Inspector" % candidate, "success")
	document_edited.emit()
	load_document(doc)
	select_headers([candidate])
	return candidate


## Rename a render header and rewrite every local reference that pointed at it.
func rename_render_node(old_name: String, new_name: String) -> bool:
	if doc == null or old_name == "":
		return false
	var clean := new_name.strip_edges()
	if clean == "" or clean.to_lower() == old_name.to_lower():
		return false
	if doc.has_header(clean):
		status_changed.emit("Rename rejected: [%s] already exists." % clean, "warning")
		return false
	var refs: Array = []
	for h in doc.render_headers():
		for key in _child_keys(doc, h.name):
			if _reference_header(doc.get_value(h.name, key, "")).to_lower() == old_name.to_lower():
				refs.append([h.name, key])
	doc.begin_compound()
	if not doc.rename_header(old_name, clean):
		doc.end_compound()
		status_changed.emit("Rename failed: header not found.", "warning")
		return false
	for pair in refs:
		var e = doc.find_entry(str(pair[0]), str(pair[1]))
		if e != null:
			doc.set_entry_value(e, clean)
	doc.end_compound()
	status_changed.emit("Renamed [%s] -> [%s] and updated %d reference(s)" % [old_name, clean, refs.size()], "success")
	document_edited.emit()
	load_document(doc)
	_selected_header = clean
	var node := graph.get_node_or_null(NodePath(clean.validate_node_name()))
	if node is GraphNode:
		node.selected = true
	_update_toolbar()
	return true


func _on_graph_undo() -> void:
	if doc == null or not doc.can_undo():
		return
	doc.undo()
	status_changed.emit("Graph undo: %s" % doc.get_display_name(), "muted")
	document_edited.emit()
	load_document(doc)


func _on_graph_redo() -> void:
	if doc == null or not doc.can_redo():
		return
	doc.redo()
	status_changed.emit("Graph redo: %s" % doc.get_display_name(), "muted")
	document_edited.emit()
	load_document(doc)


func _process(_delta: float) -> void:
	if counter_label == null:
		return
	var n := 0
	for e in _emitters:
		if is_instance_valid(e):
			n += int(e.amount)
	counter_label.text = "preview particles: %d    emitters: %d" % [n, _emitters.size()]
	if _live_inspection_label != null and is_instance_valid(_live_inspection_label) and _selected_header != "":
		var live := inspect_emitter_live_state(_selected_header)
		_live_inspection_label.text = "LIVE: particles %d/~%d · life %.2f/%.2f · t=%.2f · curve=%d" % [
			int(live.get("live_particle_count", 0)), int(live.get("active_particles", 0)),
			float(live.get("live_lifetime", 0.0)), float(live.get("life_time", 1.0)),
			float(live.get("normalised_age", 0.0)), int(live.get("live_scale_curve_points", 0)),
		]


func _vec(v: String) -> Vector3:
	var parts := v.split(" ", false)
	if parts.size() >= 3:
		return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
	return Vector3.ZERO


func _color(v: String, fallback: Color) -> Color:
	var parts := v.split(" ", false)
	if parts.size() >= 3:
		var r := parts[0].to_float()
		var g := parts[1].to_float()
		var b := parts[2].to_float()
		var a := parts[3].to_float() if parts.size() >= 4 else 255.0
		if r > 1.5 or g > 1.5 or b > 1.5 or a > 1.5:
			return Color(r / 255.0, g / 255.0, b / 255.0, a / 255.0)
		return Color(r, g, b, a)
	return fallback


func _lbl(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("#C5AB6E"))
	return l
