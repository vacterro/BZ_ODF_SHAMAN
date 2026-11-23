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
var save_deps_confirm_dialog: ConfirmationDialog
var save_deps_preview_tree: Tree
var save_deps_preview_info: Label
var _pending_save_preview: Dictionary = {}
var reset_scope_option: OptionButton
var reset_odf_button: Button
var reset_view_button: Button
var context_effects_bar: HFlowContainer
var context_doc: OdfDocument = null
var last_save_group: Dictionary = {}
var last_save_recovery: Dictionary = {}
var last_graph_batch: Dictionary = {}
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
## T-76: clipboard for link cut/copy/paste and the last link chosen for
## reconnect/move operations. Each record is {src, key, dst}.
static var _clipboard_links: Array[Dictionary] = []
var _link_focus: Dictionary = {}
## Slot -> physical reference key for each rendered graph node. Slot 0 is the
## input row; slots 1..N are direct child Controls backed by ODF properties.
var _slot_port_keys: Dictionary = {}
## GraphNode name -> Array keyed by real GraphEdit output port index. Built from
## get_output_port_slot() after the node is inside the GraphEdit tree, so a
## connection's from_port resolves the exact ODF property. Empty while headless
## (Godot materialises ports on first draw); fall back to slot identity there.
var _output_port_keys: Dictionary = {}
## Mirrors GraphEdit connection activity for exact-port assertions. The visual
## state lives in GraphEdit; this mirror is only an inspectable record.
var _connection_activity: Dictionary = {}
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
	graph.gui_input.connect(_on_graph_gui_input)
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
	_slot_port_keys.clear()
	_output_port_keys.clear()
	_clear_graph()
	_clear_emitters()
	_rebuild_quick_inspector()
	if doc == null:
		if header_label != null:
			header_label.text = "Particle Lab: no document."
		return
	var renders := doc.render_headers()
	if header_label != null:
		header_label.text = "Particle Lab: %s  —  %d render header(s)" % [doc.get_display_name(), renders.size()]
	if renders.is_empty():
		if info != null:
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
		# GraphNode only registers slots while inside the GraphEdit tree.
		if graph != null:
			graph.add_child(node)
		# Slot 0 is the node's input and is backed by this direct child Control;
		# one further direct child Control backs each output port. Godot derives
		# GraphNode slots from direct children, not nested container rows.
		var rows := VBoxContainer.new()
		rows.name = "InputSlot"
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
		var slot_keys := _child_keys(doc, h.name)
		node.set_slot(0, true, 0, Color("#969630"), false, 0, Color("#969630"))
		# Each physical reference key owns one real GraphNode output port. The
		# port's direct child Control carries the exact ODF identity in metadata.
		var port_keys: Array[String] = [""]
		for key in slot_keys:
			var ref := doc.get_value(h.name, key, "")
			var port_index := node.get_child_count()
			var ref_row := HBoxContainer.new()
			ref_row.name = "ReferenceSlot_%s" % key
			ref_row.set_meta("ref_key", key)
			ref_row.set_meta("ref_header", h.name)
			ref_row.add_theme_constant_override("separation", 2)
			var ref_label := Label.new()
			ref_label.text = "OUT %d · %s" % [port_index, key]
			ref_label.add_theme_font_size_override("font_size", 10)
			ref_label.add_theme_color_override("font_color", Color("#D3B57A"))
			ref_label.custom_minimum_size = Vector2(112, 0)
			ref_row.add_child(ref_label)
			var ref_edit := LineEdit.new()
			ref_edit.text = ref
			ref_edit.custom_minimum_size = Vector2(140, 0)
			ref_edit.tooltip_text = "Edit %s (output %d) and press Enter; target must be a render header or file.header." % [key, port_index]
			ref_edit.text_submitted.connect(func(text: String): _on_reference_submitted(h.name, key, text))
			ref_row.add_child(ref_edit)
			node.add_child(ref_row)
			node.set_slot(port_index, false, 0, Color("#969630"), true, 0, Color("#D3B57A"))
			port_keys.append(key)
		# A distinct output port for the next available reference key. It exists
		# only when a key is available and never reuses an occupied slot.
		var new_key := _next_reference_key(h.name)
		if new_key != "":
			var port_index := node.get_child_count()
			var add_row := Label.new()
			add_row.name = "AddReferencePort"
			add_row.text = "+ ADD %s" % new_key
			add_row.set_meta("ref_key", new_key)
			add_row.set_meta("ref_header", h.name)
			add_row.set_meta("is_add_port", true)
			add_row.add_theme_font_size_override("font_size", 10)
			add_row.add_theme_color_override("font_color", Color("#9C9371"))
			add_row.tooltip_text = "Drag from this port to create %s." % new_key
			node.add_child(add_row)
			node.set_slot(port_index, false, 0, Color("#969630"), true, 0, Color("#B8D890"))
			port_keys.append("@add:" + new_key)
		_slot_port_keys[node.name] = port_keys.duplicate()
		# Godot numbers output ports only among enabled right-hand slots. Build
		# the port->key map from the real API when ports are materialised.
		_output_port_keys[node.name] = _build_port_keys(node, port_keys)
		positions[h.name.to_lower()] = node.name
		i += 1
	var built := EffectRuntime.build_document_preview(index, doc)
	_header_preview_nodes = built.get("header_nodes", {})
	for pn in built.get("nodes", []):
		if preview_root != null:
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
			var src_node := graph.get_node_or_null(NodePath(from)) as GraphNode if graph != null else null
			var port := _port_for_key(src_node, from, key)
			if port < 0:
				# Physical slot no longer exposed by this merged node; never
				# attach the edge to the input port as a false substitute.
				continue
			if to != "" and to != from and graph != null and not graph.is_node_connected(from, port, to, 0):
				graph.connect_node(from, port, to, 0)
	_apply_layout()
	_refresh_edge_highlight()
	if _selected_header == "" and not renders.is_empty():
		_selected_header = renders[0].name
		_selected_headers = [_selected_header]
		var first_gn := graph.get_node_or_null(NodePath(_node_name_for(_selected_header, 0))) if graph != null else null
		if first_gn is GraphNode:
			(first_gn as GraphNode).selected = true
		_rebuild_quick_inspector()
	if info != null:
		info.text = _describe_graph(renders)
	if counter_label != null:
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
	var n := graph.get_node_or_null(NodePath(node_name)) if graph != null else null
	if n != null and n.has_meta("header"):
		return str(n.get_meta("header"))
	return ""


## Exact target identity for a GraphEdit edge. Local targets carry a document
## header; external targets carry canonical path + package + external header.
func _target_identity_for_node(node_name: String) -> Dictionary:
	var n := graph.get_node_or_null(NodePath(node_name)) if graph != null else null
	if n == null:
		return {"kind": "missing", "name": node_name}
	if n.has_meta("external_path"):
		var path := str(n.get_meta("external_path"))
		return {
			"kind": "external", "name": node_name,
			"path": WorkspaceStore.canonical(path),
			"package": index.package_of(path) if index != null else "",
			"header": str(n.get_meta("external_header", "")),
		}
	if n.has_meta("header"):
		return {"kind": "local", "name": node_name, "header": str(n.get_meta("header"))}
	return {"kind": "missing", "name": node_name}


func _same_target_identity(a: Dictionary, b: Dictionary) -> bool:
	if int(a.get("kind", 0)) == 0 or a.get("kind") != b.get("kind"):
		return false
	if str(a.get("kind")) == "local":
		return str(a.get("header", "")).to_lower() == str(b.get("header", "")).to_lower()
	if str(a.get("kind")) == "external":
		return str(a.get("path", "")).to_lower() == str(b.get("path", "")).to_lower() \
			and str(a.get("header", "")).to_lower() == str(b.get("header", "")).to_lower()
	return false


## Resolve a resolved reference to the exact identity of its graph target node.
func _target_identity_for_reference(resolved: Dictionary) -> Dictionary:
	var h := str(resolved.get("header", ""))
	if str(resolved.get("kind", "")) == "external":
		var path := WorkspaceStore.canonical(str(resolved.get("path", "")))
		return {
			"kind": "external", "name": path.path_join(h).get_file(),
			"path": path, "package": index.package_of(path) if index != null else "",
			"header": h,
		}
	for node_name in _external_nodes:
		var ext: Dictionary = _external_nodes.get(node_name, {})
		if str(ext.get("header", "")).to_lower() == h.to_lower() \
				and WorkspaceStore.canonical(str(ext.get("path", ""))).to_lower() == WorkspaceStore.canonical(str(resolved.get("path", ""))).to_lower():
			return _target_identity_for_node(node_name)
	for n in graph.get_children() if graph != null else []:
		if n is GraphNode and n.has_meta("header") and str(n.get_meta("header")).to_lower() == h.to_lower() \
				and not (n as GraphNode).has_meta("external_path"):
			return _target_identity_for_node(String(n.name))
	return {"kind": "missing", "header": h, "path": str(resolved.get("path", ""))}


## Physical ODF identity of a reference value: local header or exact
## file.header. Never collapses an external reference into a local header name.
func _reference_identity(value: String) -> Dictionary:
	var resolved := _resolve_reference(value)
	match str(resolved.get("kind", "")):
		"local":
			return {
				"kind": "local", "header": str(resolved.get("header", "")),
				"path": str(resolved.get("path", "")),
				"value": value.strip_edges(),
			}
		"external":
			return {
				"kind": "external", "header": str(resolved.get("header", "")),
				"path": WorkspaceStore.canonical(str(resolved.get("path", ""))),
				"package": index.package_of(str(resolved.get("path", ""))) if index != null else "",
				"value": value.strip_edges(),
			}
		_:
			return {"kind": "missing", "value": value.strip_edges()}


func _reference_identity_matches(identity: Dictionary, target: Dictionary) -> bool:
	if identity.get("kind") != target.get("kind"):
		return false
	if str(identity.get("header", "")).to_lower() != str(target.get("header", "")).to_lower():
		return false
	if str(identity.get("kind")) == "external":
		return str(identity.get("path", "")).to_lower() == str(target.get("path", "")).to_lower()
	return true


## Validate an existing GraphEdit edge against the exact ODF entry that created
## it. Used by mouse selection, disconnect and highlight; no header-only guessing.
func _edge_record_from_connection(conn: Dictionary) -> Dictionary:
	return _edge_record(str(conn.get("from_node", "")), int(conn.get("from_port", -1)),
		str(conn.get("to_node", "")))


func _edge_record(from_node: String, from_port: int, to_node: String) -> Dictionary:
	var slots: Array[String] = _slot_port_keys.get(from_node, [])
	var key := ""
	var node := graph.get_node_or_null(NodePath(from_node)) as GraphNode if graph != null else null
	var ports: Array = _output_port_keys.get(from_node, [])
	if from_port >= 0 and from_port < ports.size() and str(ports[from_port]) != "":
		key = str(ports[from_port])
	elif node != null and from_port >= 0 and from_port < node.get_output_port_count():
		var slot := node.get_output_port_slot(from_port)
		if slot >= 0 and slot < slots.size():
			key = slots[slot]
	if key == "" or key.begins_with("@add:"):
		return {}
	var header := _header_for_node(from_node)
	if header.is_empty():
		return {}
	var entry = doc.find_entry_occurrence(header, key) if doc != null else null
	if entry == null and key.contains("("):
		entry = doc.find_entry_occurrence(header, key.substr(0, key.find("(")))
	if entry == null:
		return {}
	var identity := _reference_identity(str(entry.core_value()))
	var target := _target_identity_for_node(to_node)
	if not _reference_identity_matches(identity, target):
		return {}
	return {
		"src": header, "key": str(entry.full_key()),
		"dst": str(identity.get("header", "")),
		"target": target, "reference": identity,
		"src_header_id": str(entry.header_id),
		"src_occurrence": int(entry.occurrence_index),
		"key_occurrence": int(entry.key_occurrence_index),
		"doc_key_occurrence": int(entry.key_occurrence_index),
		"entry_line": int(entry.line),
		"doc_revision": int(doc.revision),
		"from_node": from_node, "from_port": from_port, "to_node": to_node,
		"selection_source": "graph_port",
	}


## Map a physical reference key to a real GraphEdit output-port index.
## Windowed Godot exposes get_output_port_slot(); headless returns 0 so the
## stable slot-based mapping remains usable for headless logic verifiers.
## Build port->key using the real Godot API. Falls back to headless slot order.
func _build_port_keys(node: GraphNode, slot_keys: Array[String]) -> Array[String]:
	var out: Array[String] = []
	if node != null and node.get_output_port_count() > 0:
		for p in range(node.get_output_port_count()):
			var slot := node.get_output_port_slot(p)
			if slot >= 0 and slot < slot_keys.size():
				out.append(slot_keys[slot])
			else:
				out.append("")
		return out
	for i in range(1, slot_keys.size()):
		out.append(slot_keys[i])
	return out


func _port_for_key(node: GraphNode, node_name: String, key: String) -> int:
	if node != null and node.get_output_port_count() > 0:
		var ports: Array = _output_port_keys.get(node_name, [])
		for p in range(ports.size()):
			if str(ports[p]) == key:
				return p
		for p in range(node.get_output_port_count()):
			var slot := node.get_output_port_slot(p)
			var slots: Array[String] = _slot_port_keys.get(node_name, [])
			if slot >= 0 and slot < slots.size() and slots[slot] == key:
				return p
		return -1
	var slots: Array[String] = _slot_port_keys.get(node_name, [])
	var slot_index := slots.find(key)
	return slot_index - 1 if slot_index > 0 else -1


## Map a GraphEdit output-port index back to its slot index using Godot's API,
## falling back to the headless slot convention (port = slot - 1).
func _slot_for_port(node: GraphNode, node_name: String, port: int) -> int:
	if node != null and node.get_output_port_count() > 0 and port >= 0 and port < node.get_output_port_count():
		return node.get_output_port_slot(port)
	return port + 1


## Physical key behind a real GraphEdit output port. External callers must never
## index the slot-key array with a port number.
func _key_for_port(node: GraphNode, node_name: String, port: int) -> String:
	var ports: Array = _output_port_keys.get(node_name, [])
	if port >= 0 and port < ports.size() and str(ports[port]) != "":
		return str(ports[port])
	if node != null and node.get_output_port_count() > 0 and port >= 0 and port < node.get_output_port_count():
		var slot := node.get_output_port_slot(port)
		var slots: Array[String] = _slot_port_keys.get(node_name, [])
		if slot >= 0 and slot < slots.size():
			return slots[slot]
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
	if graph != null:
		graph.add_child(node)
	node.set_slot(0, true, 0, Color("#969630"), false, 0, Color("#969630"))
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


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	if doc == null:
		return
	var src := _header_for_node(String(from_node))
	var target := _target_identity_for_node(String(to_node))
	var dst := ""
	if str(target.get("kind", "")) == "local":
		dst = str(target.get("header", ""))
	elif str(target.get("kind", "")) == "external":
		dst = "%s.%s" % [str(target.get("path", "")).get_basename(), str(target.get("header", ""))]
	var node := graph.get_node_or_null(NodePath(String(from_node))) as GraphNode if graph != null else null
	var key := _key_for_port(node, String(from_node), from_port)
	if src.is_empty() or dst.is_empty() or key.is_empty():
		status_changed.emit("Link refused: source port has no physical ODF reference.", "warning")
		return
	if key.begins_with("@add:"):
		# The dedicated "+" port creates the next reference key intentionally.
		key = key.substr(5)
		if key.is_empty():
			status_changed.emit("Link refused: no free renderNameN reference slot.", "warning")
			return
	else:
		var pe = doc.find_entry(src, key)
		if pe != null and pe.core_value() != "":
			# Occupied physical port: never silently pick a different property.
			select_edge(src, key, _reference_header(pe.core_value()), "graph_port")
			status_changed.emit("PORT_OCCUPIED: %s.%s already linked; use RECONNECT to retarget it." % [src, key], "warning")
			return
	var check := _validate_link(src, dst, key, "", false, target)
	if not bool(check.get("ok", false)):
		_report_link_failure(str(check.get("code", "INVALID")))
		return
	key = str(check.get("key", ""))
	var value := str(check.get("value", dst))
	var entry = doc.find_entry(src, key)
	if entry != null:
		doc.set_entry_value(entry, value)
	else:
		doc.append_entry(src, key, value)
	status_changed.emit("Linked %s -> %s as %s" % [src, value, key], "success")
	document_edited.emit()
	load_document(doc)


## All local reference entries whose value resolves to `dst`, in document order.
func _matching_reference_entries(src: String, dst: String) -> Array:
	var out: Array = []
	if doc == null:
		return out
	for e in doc.entries:
		if str(e.header).to_lower() != src.to_lower() or e.is_shadowed():
			continue
		if _reference_header(e.core_value()).to_lower() == dst.to_lower():
			out.append(e)
	return out


func _entry_record(e) -> Dictionary:
	return {
		"src": str(e.header), "key": str(e.full_key()), "dst": _reference_header(e.core_value()),
		"src_header_id": str(e.header_id), "src_occurrence": int(e.occurrence_index),
		"key_occurrence": int(e.header_key_occurrence_index),
		"doc_key_occurrence": int(e.key_occurrence_index),
		"entry_line": int(e.line), "doc_revision": int(doc.revision),
		"selection_source": "graph_port",
	}


## One identity-aware removal path for mouse, keyboard and inspector commands.
## A failed or ambiguous disconnect leaves every ODF byte unchanged.
func disconnect_exact_edge(rec: Dictionary) -> bool:
	if doc == null:
		return false
	var e = _entry_for_link(rec)
	if e == null:
		status_changed.emit("Disconnect refused: selected physical reference is stale.", "warning")
		return false
	var expected: Dictionary = rec.get("target", {})
	if expected.is_empty():
		expected = {"kind": "local", "header": str(rec.get("dst", ""))}
	if not _reference_identity_matches(_reference_identity(str(e.core_value())), expected):
		status_changed.emit("Disconnect refused: selected physical reference is stale.", "warning")
		return false
	var snap := doc.capture_snapshot()
	doc.begin_compound()
	var removed := doc.remove_entry(e)
	doc.end_compound()
	if not removed:
		doc.restore_snapshot(snap)
		status_changed.emit("Disconnect failed; original reference preserved.", "warning")
		return false
	clear_edge_selection()
	document_edited.emit()
	load_document(doc)
	status_changed.emit("Removed %s.%s -> %s" % [str(rec.get("src", "")), str(rec.get("key", "")), str(rec.get("dst", ""))], "success")
	return true


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	if doc == null:
		return
	# Exact port identity wins. It carries local and external target identity
	# from the ODF entry that produced this GraphEdit connection.
	var rec := _edge_record(String(from_node), from_port, String(to_node))
	if rec.is_empty():
		status_changed.emit("DISCONNECT_IDENTITY_UNRESOLVED: visual edge preserved; selecting the physical slot is required.", "warning")
		load_document(doc)
		return
	disconnect_exact_edge(rec)


# ---------------------------------------------------------------------------
# T-76: node-link manipulation hotkeys. Links are emitName/renderNameN entries
# on a source render header whose value names a target header. Every operation
# is one compound, undoable ODF edit followed by a graph rebuild.
# ---------------------------------------------------------------------------

const GRAPH_LINK_ERRORS := {
	"INVALID": "Link refused: invalid source or destination.",
	"SELF": "Link refused: a node cannot reference itself.",
	"CYCLE": "Link refused: the connection would create a cycle.",
	"SLOT_MISSING": "Link refused: the reference slot does not exist.",
	"SLOT_OCCUPIED": "Link refused: the destination slot is occupied.",
}

## Build the verbatim ODF reference value for a GraphEdit target identity.
## Local targets use the header name; external targets use file.header and
## resolve through the active resource index so Reconnect/paste never write a
## bare header that silently changes an external reference into a local one.
func _reference_value_for_target(target: Dictionary) -> String:
	if not str(target.get("value", "")).strip_edges().is_empty():
		return str(target.get("value")).strip_edges()
	if str(target.get("kind", "")) == "external":
		var ext_header := str(target.get("header", ""))
		var ext_path := str(target.get("path", ""))
		if ext_header == "" or ext_path == "":
			return ""
		var by_path := index.resolve_path_from(ext_path.get_file(), doc.source_path if doc != null else "") if index != null else ""
		if by_path != "" and WorkspaceStore.canonical(by_path).to_lower() != WorkspaceStore.canonical(ext_path).to_lower():
			return ""
		var file_ref := ext_path.get_file().get_basename()
		return "%s.%s" % [file_ref, ext_header]
	return str(target.get("header", target.get("name", "")))


## One validator for every graph reference entry point (mouse, reconnect,
## paste, move, direct edit). `ignore_key` drops an existing edge from the
## cycle walk so reconnect/move can validate the candidate before mutating.
## External file.header references are resource references, not local graph
## edges: they must resolve to an indexed file and never enter cycle analysis.
func _validate_link(src: String, dst: String, key: String = "",
		ignore_key: String = "", allow_replace: bool = false, target: Dictionary = {}) -> Dictionary:
	if doc == null or src.is_empty() or dst.is_empty() or not doc.has_header(src):
		return {"ok": false, "code": "INVALID"}
	var resolved := _resolve_reference(dst)
	var ref_kind := str(resolved.get("kind", ""))
	var value := dst
	if not target.is_empty():
		value = _reference_value_for_target(target)
		if value.is_empty():
			return {"ok": false, "code": "INVALID"}
		resolved = _resolve_reference(value)
		ref_kind = str(resolved.get("kind", ""))
	if ref_kind == "external":
		if str(resolved.get("path", "")).strip_edges() == "" or str(resolved.get("header", "")).strip_edges() == "":
			return {"ok": false, "code": "INVALID"}
	elif ref_kind == "local":
		if not doc.has_header(dst):
			return {"ok": false, "code": "INVALID"}
		if str(resolved.get("header", "")).to_lower() == src.to_lower():
			return {"ok": false, "code": "SELF"}
		if _would_cycle(src, str(resolved.get("header", "")), ignore_key):
			return {"ok": false, "code": "CYCLE"}
	else:
		return {"ok": false, "code": "INVALID"}
	var use_key := key if key != "" else _next_reference_key(src)
	if use_key.is_empty():
		return {"ok": false, "code": "SLOT_MISSING"}
	var existing = doc.find_entry(src, use_key)
	if existing != null and not allow_replace and use_key != ignore_key:
		return {"ok": false, "code": "SLOT_OCCUPIED", "entry": existing}
	return {"ok": true, "code": "OK", "key": use_key, "value": value,
		"kind": ref_kind, "entry": existing}


func _report_link_failure(code: String) -> void:
	status_changed.emit(GRAPH_LINK_ERRORS.get(code, str(GRAPH_LINK_ERRORS["INVALID"])), "warning")


func _entry_for_link(rec: Dictionary):
	if doc == null:
		return null
	var src := str(rec.get("src", ""))
	var key := str(rec.get("key", ""))
	var header_occ := int(rec.get("src_occurrence", -1))
	var key_occ := int(rec.get("key_occurrence", -1))
	if header_occ >= 0 or key_occ >= 0:
		return doc.find_entry_occurrence(src, key, header_occ, -1, key_occ)
	return doc.find_entry(src, key)


func _refresh_edge_highlight() -> void:
	if graph == null:
		return
	_connection_activity.clear()
	for connection in graph.get_connection_list():
		var key := "%s:%d:%s:%d" % [str(connection.get("from_node", "")), int(connection.get("from_port", 0)),
			str(connection.get("to_node", "")), int(connection.get("to_port", 0))]
		_connection_activity[key] = 0.0
		graph.set_connection_activity(str(connection.get("from_node", "")), int(connection.get("from_port", 0)),
			str(connection.get("to_node", "")), int(connection.get("to_port", 0)), 0.0)
	if not _focus_is_current():
		return
	var src := str(_link_focus.get("src", ""))
	var dst := str(_link_focus.get("dst", ""))
	var focus_key := str(_link_focus.get("key", ""))
	for connection in graph.get_connection_list():
		var from_node := str(connection.get("from_node", ""))
		var to_node := str(connection.get("to_node", ""))
		if _header_for_node(from_node) != src:
			continue
		var focus_target := _target_identity_for_node(to_node)
		if not _reference_identity_matches(
				{"kind": "local", "header": dst, "path": str(_link_focus.get("target_path", ""))}, focus_target) \
				and str(_link_focus.get("dst", "")) != dst:
			continue
		var from_port := int(connection.get("from_port", 0))
		var focus_node := graph.get_node_or_null(NodePath(from_node)) as GraphNode if graph != null else null
		if _key_for_port(focus_node, from_node, from_port) != focus_key:
			continue
		_connection_activity["%s:%d:%s:%d" % [from_node, from_port, to_node, int(connection.get("to_port", 0))]] = 1.0
		graph.set_connection_activity(from_node, from_port,
			to_node, int(connection.get("to_port", 0)), 1.0)


func _clear_edge_highlight() -> void:
	if graph == null:
		return
	for connection in graph.get_connection_list():
		graph.set_connection_activity(str(connection.get("from_node", "")), int(connection.get("from_port", 0)),
			str(connection.get("to_node", "")), int(connection.get("to_port", 0)), 0.0)


## A selection only applies to the exact document revision it was captured
## on; later edits or undo/redo invalidate it instead of retargeting a
## different physical property occurrence.
func _focus_is_current() -> bool:
	if _link_focus.is_empty() or doc == null:
		return false
	if int(_link_focus.get("doc_revision", -1)) != doc.revision:
		_link_focus.clear()
		return false
	var e = _entry_for_link(_link_focus)
	if e == null:
		_link_focus.clear()
		return false
	var expected: Dictionary = _link_focus.get("target", {})
	if expected.is_empty():
		expected = {"kind": "local", "header": str(_link_focus.get("dst", ""))}
	if not _reference_identity_matches(_reference_identity(str(e.core_value())), expected):
		_link_focus.clear()
		return false
	return true


func select_edge(src: String, key: String, dst: String, source: String = "graph") -> void:
	if doc == null:
		return
	var e = doc.find_entry(src, key)
	if e == null:
		_link_focus.clear()
		_clear_edge_highlight()
		return
	var identity := _reference_identity(str(e.core_value()))
	var expected_target := {
		"kind": identity.get("kind", "local"),
		"header": str(identity.get("header", dst)),
		"path": str(identity.get("path", "")),
	}
	_link_focus = {
		"src": src, "key": key, "dst": dst,
		"target": expected_target, "reference": identity,
		"src_header_id": str(e.header_id),
		"src_occurrence": int(e.occurrence_index),
		"key_occurrence": int(e.key_occurrence_index),
		"doc_key_occurrence": int(e.key_occurrence_index),
		"entry_line": int(e.line),
		"doc_revision": int(doc.revision),
		"selection_source": source,
	}
	_refresh_edge_highlight()
	status_changed.emit("Selected edge %s.%s -> %s" % [src, key, dst], "muted")


func clear_edge_selection() -> void:
	_link_focus.clear()
	_clear_edge_highlight()


func _on_graph_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	if (event as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return
	var conn = graph.get_closest_connection_at_point(
		graph.get_local_mouse_position() + graph.get_scroll_offset(), 10.0)
	if conn == null or not (conn is Dictionary):
		clear_edge_selection()
		return
	var rec := _edge_record_from_connection(conn as Dictionary)
	if rec.is_empty():
		clear_edge_selection()
		return
	_link_focus = rec
	_refresh_edge_highlight()
	var target: Dictionary = rec.get("target", {})
	var target_label := str(target.get("header", ""))
	if str(target.get("kind", "")) == "external":
		target_label = str(target.get("path", "")).get_file() + " ▸ " + target_label
	status_changed.emit("Selected edge %s.%s -> %s" % [
		str(rec.get("src", "")), str(rec.get("key", "")), target_label], "muted")


## Collect link records touching the selected headers (or the focused link).
func _collect_target_links() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if doc == null:
		return out
	if _focus_is_current():
		out.append(_link_focus.duplicate(true))
		return out
	var selected := get_selected_headers()
	for src in selected:
		for key in _child_keys(doc, src):
			var e = doc.find_entry(src, key)
			if e == null:
				continue
			var identity := _reference_identity(str(e.core_value()))
			if identity.get("kind") == "external":
				out.append({
					"src": src, "key": key, "dst": str(identity.get("header", "")),
					"target": {"kind": "external", "header": str(identity.get("header", "")),
						"path": str(identity.get("path", ""))},
					"reference": identity, "selection_source": "selected_header",
				})
			elif str(identity.get("header", "")) != "" and doc.has_header(str(identity.get("header", ""))):
				out.append({"src": src, "key": key, "dst": str(identity.get("header", "")),
					"target": identity, "selection_source": "selected_header"})
	return out


func _remove_link(rec: Dictionary) -> bool:
	var e = _entry_for_link(rec)
	if e == null or not _record_matches_entry(rec, e):
		return false
	doc.remove_entry(e)
	return true


func _record_matches_entry(rec: Dictionary, e) -> bool:
	if e == null:
		return false
	var expected: Dictionary = rec.get("target", {})
	if expected.is_empty():
		expected = {"kind": "local", "header": str(rec.get("dst", ""))}
	return _reference_identity_matches(_reference_identity(str(e.core_value())), expected)


func _add_link(src: String, dst: String, key: String = "", allow_replace: bool = false,
		target: Dictionary = {}) -> bool:
	var check := _validate_link(src, dst, key, "", allow_replace, target)
	if not bool(check.get("ok", false)):
		_report_link_failure(str(check.get("code", "INVALID")))
		return false
	var use_key := str(check.get("key", ""))
	var value := str(check.get("value", dst))
	var existing = check.get("entry", null)
	if existing != null:
		doc.set_entry_value(existing, value)
	else:
		doc.append_entry(src, use_key, value)
	return true


## Mutate one existing entry in place. Preferred for reconnect: preserves the
## physical header, property occurrence, surrounding comments and formatting.
func _retarget_link(rec: Dictionary, dst: String) -> bool:
	var e = _entry_for_link(rec)
	if e == null or not _record_matches_entry(rec, e):
		return false
	doc.set_entry_value(e, dst)
	return true


func copy_selected_links() -> int:
	var links := _collect_target_links()
	_clipboard_links = links.duplicate(true)
	status_changed.emit("Copied %d graph link(s)." % links.size(), "muted")
	return links.size()


func cut_selected_links() -> int:
	var links := _collect_target_links()
	if links.is_empty():
		last_graph_batch = {"status": "NO_CHANGE", "requested": 0, "succeeded": 0, "failed": 0, "failure_reasons": []}
		return 0
	var before_bytes: PackedByteArray = doc.to_bytes()
	doc.begin_compound()
	var removed := 0
	for rec in links:
		if _remove_link(rec):
			removed += 1
	doc.end_compound()
	if removed == 0 or doc.to_bytes() == before_bytes:
		last_graph_batch = {"status": "NO_CHANGE", "requested": links.size(),
			"succeeded": 0, "failed": links.size(), "failure_reasons": [{"reason": "STALE_EDGES"}]}
		clear_edge_selection()
		status_changed.emit("Cut made no change; no document edit was emitted.", "warning")
		return 0
	_clipboard_links = links.duplicate(true)
	last_graph_batch = {"status": "COMPLETE", "requested": links.size(),
		"succeeded": removed, "failed": links.size() - removed, "failure_reasons": []}
	clear_edge_selection()
	document_edited.emit()
	load_document(doc)
	status_changed.emit("Cut %d graph link(s) (undo available)." % removed, "success")
	return removed


func paste_links() -> int:
	if doc == null or _clipboard_links.is_empty():
		last_graph_batch = {"status": "NO_CHANGE", "requested": 0, "succeeded": 0, "failed": 0, "failure_reasons": []}
		return 0
	var selected := get_selected_headers()
	var target_src := selected[0] if not selected.is_empty() else ""
	var requested := _clipboard_links.size()
	var added := 0
	var failures: Array[Dictionary] = []
	var before_bytes: PackedByteArray = doc.to_bytes()
	doc.begin_compound()
	for rec in _clipboard_links:
		var src := target_src if target_src != "" else str(rec.get("src", ""))
		var dst := str(rec.get("dst", ""))
		var use_key := "" if target_src != "" else str(rec.get("key", ""))
		var target: Dictionary = rec.get("target", {})
		var check := _validate_link(src, dst, use_key, "", false, target)
		if not bool(check.get("ok", false)):
			var code := str(check.get("code", "INVALID"))
			failures.append({"path": src, "key": use_key, "reason": code})
			_report_link_failure(code)
			continue
		if _add_link(src, dst, use_key, false, target):
			added += 1
		else:
			failures.append({"path": src, "key": use_key, "reason": "ADD_FAILED"})
	doc.end_compound()
	if added == 0:
		last_graph_batch = {"status": "NO_CHANGE", "requested": requested,
			"succeeded": 0, "failed": failures.size(), "failure_reasons": failures}
		status_changed.emit("Paste made no change; no document edit was emitted.", "warning")
		return 0
	var status := "COMPLETE" if failures.is_empty() else "PARTIAL"
	last_graph_batch = {"status": status, "requested": requested,
		"succeeded": added, "failed": failures.size(), "failure_reasons": failures}
	document_edited.emit()
	load_document(doc)
	status_changed.emit("Pasted %d graph link(s) (%s, %d failed; undo available)." % [
		added, status, failures.size()], "success" if failures.is_empty() else "warning")
	return added


func disconnect_selected_link() -> bool:
	var links := _collect_target_links()
	if links.is_empty():
		last_graph_batch = {"status": "NO_CHANGE", "requested": 0, "succeeded": 0, "failed": 0, "failure_reasons": []}
		return false
	var before_bytes: PackedByteArray = doc.to_bytes()
	doc.begin_compound()
	var ok := _remove_link(links[0])
	doc.end_compound()
	if not ok or doc.to_bytes() == before_bytes:
		clear_edge_selection()
		last_graph_batch = {"status": "NO_CHANGE", "requested": 1, "succeeded": 0,
			"failed": 1, "failure_reasons": [{"reason": "STALE_EDGE"}]}
		status_changed.emit("Disconnect made no change; no document edit was emitted.", "warning")
		return false
	last_graph_batch = {"status": "COMPLETE", "requested": 1, "succeeded": 1, "failed": 0, "failure_reasons": []}
	clear_edge_selection()
	document_edited.emit()
	load_document(doc)
	status_changed.emit("Disconnected %s -> %s (undo available)." % [
		str(links[0].get("src", "")), str(links[0].get("dst", ""))
	], "success")
	return true


## Reconnect edits the existing reference value in place. Validation and the
## byte-exact document snapshot are taken before any mutation, so an invalid
## destination cannot destroy the old ODF reference.
func reconnect_selected_link(to_header: String = "") -> bool:
	var links := _collect_target_links()
	if links.is_empty():
		return false
	var rec: Dictionary = links[0]
	var src := str(rec.get("src", ""))
	var key := str(rec.get("key", ""))
	var e = _entry_for_link(rec)
	var existing_identity := _reference_identity(str(e.core_value())) if e != null else {}
	var target := {}
	var resolved_target := {}
	if not to_header.strip_edges().is_empty():
		resolved_target = _resolve_reference(to_header.strip_edges())
		if str(resolved_target.get("kind", "")) != "missing":
			target = _target_identity_for_reference(resolved_target)
	if str(target.get("kind", "missing")) == "missing":
		target = {}
	var external_value := ""
	if str(existing_identity.get("kind", "")) == "external":
		external_value = _reference_value_for_target(existing_identity)
	var dst := to_header.strip_edges()
	if dst == "":
		var selected := get_selected_headers()
		dst = selected[0] if not selected.is_empty() else ""
	if target.is_empty():
		if not external_value.is_empty() and (dst == str(existing_identity.get("header", "")) or dst == external_value):
			# Retarget to the same external header is a no-op; keep exact bytes.
			dst = external_value
		elif not external_value.is_empty() and dst == existing_identity.get("path", ""):
			dst = external_value
		if dst.is_empty():
			return false
	else:
		dst = str(target.get("header", dst))
	var check := _validate_link(src, str(resolved_target.get("value", dst)), key, key, false, target)
	if not bool(check.get("ok", false)):
		_report_link_failure(str(check.get("code", "INVALID")))
		return false
	var value := str(check.get("value", dst))
	var before_revision: int = doc.revision
	var before_focus: Dictionary = _link_focus.duplicate(true)
	doc.begin_compound()
	var ok := _retarget_link(rec, value)
	doc.end_compound()
	if not ok or doc.revision == before_revision:
		_link_focus = before_focus
		load_document(doc)
		status_changed.emit("Reconnect failed; original reference preserved.", "warning")
		return false
	clear_edge_selection()
	document_edited.emit()
	load_document(doc)
	status_changed.emit("Reconnected %s.%s -> %s (undo available)." % [src, key, dst], "success")
	return true


func _slot_occupied(src: String, key: String) -> bool:
	return doc != null and doc.find_entry(src, key) != null


## Move semantics: "free" refuses an occupied destination, "swap" exchanges
## both values, "replace" is an explicit acknowledged overwrite. All variants
## validate before mutating and never silently overwrite in default mode.
func move_selected_link(to_key: String = "", mode: String = "free") -> bool:
	var links := _collect_target_links()
	if links.is_empty():
		return false
	var rec: Dictionary = links[0]
	var src := str(rec.get("src", ""))
	var dst := str(rec.get("dst", ""))
	var from_key := str(rec.get("key", ""))
	var target := to_key.strip_edges()
	if target.is_empty():
		target = _next_reference_key(src)
	if target.is_empty() or target == from_key:
		return false
	var action := mode.strip_edges().to_lower()
	if action not in ["free", "swap", "replace"]:
		status_changed.emit("Unknown move mode: " + action, "warning")
		return false
	var occupant = doc.find_entry(src, target)
	if occupant != null and action == "free":
		_report_link_failure("SLOT_OCCUPIED")
		return false
	if action == "swap" and (occupant == null or not _child_keys(doc, src).has(from_key)):
		_report_link_failure("SLOT_MISSING")
		return false
	var from_entry = _entry_for_link(rec)
	if from_entry == null:
		return false
	var source_value := str(from_entry.core_value())
	var move_identity := _reference_identity(source_value)
	var check := _validate_link(src, source_value, target, from_key, action != "free", move_identity)
	if not bool(check.get("ok", false)):
		_report_link_failure(str(check.get("code", "INVALID")))
		return false
	var dest_value := str(occupant.core_value()) if occupant != null else ""
	if action == "swap":
		var dest_identity := _reference_identity(dest_value)
		var dest_check := _validate_link(src, dest_value, from_key, target, true, dest_identity)
		if not bool(dest_check.get("ok", false)):
			_report_link_failure(str(dest_check.get("code", "INVALID")))
			return false
	var before_bytes: PackedByteArray = doc.to_bytes()
	var snap := doc.capture_snapshot()
	doc.begin_compound()
	if action == "swap":
		doc.set_entry_value(from_entry, dest_value)
		doc.set_entry_value(occupant, source_value)
	else:
		if occupant != null:
			doc.remove_entry(from_entry)
			doc.set_entry_value(occupant, source_value)
		else:
			var source_header_id := str(from_entry.header_id)
			doc.remove_entry(from_entry)
			var appended = doc.append_entry(src, target, source_value, source_header_id)
			if appended == null:
				doc.end_compound()
				doc.restore_snapshot(snap)
				status_changed.emit("Move failed; original reference preserved byte-exactly.", "warning")
				return false
	doc.end_compound()
	if doc.to_bytes() == before_bytes:
		status_changed.emit("Move made no change.", "warning")
		return false
	clear_edge_selection()
	document_edited.emit()
	load_document(doc)
	status_changed.emit("Moved %s.%s -> %s (%s)." % [src, from_key, target, action], "success")
	return true


## Keyboard dispatcher for graph link manipulation. Returns true when handled.
## MODIFIER MAP: X/Delete = cut, C = copy, V = paste, R = reconnect,
##               M = move, Alt+Delete/Backspace = disconnect.
func _handle_graph_hotkey(event: InputEvent) -> bool:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return false
	var k := event as InputEventKey
	if graph == null or doc == null:
		return false
	var fo: Control = get_viewport().get_focus_owner() as Control
	if fo is LineEdit or fo is TextEdit or fo is SpinBox:
		return false
	var focused := graph.has_focus()
	var over_graph := graph.get_global_rect().has_point(graph.get_global_mouse_position())
	if not focused and not over_graph:
		return false
	var cut_key := k.keycode == KEY_X or k.keycode == KEY_DELETE
	if k.ctrl_pressed or k.meta_pressed:
		if k.keycode == KEY_C:
			return copy_selected_links() >= 0
		if k.keycode == KEY_V:
			return paste_links() > 0
		if k.keycode == KEY_R:
			return reconnect_selected_link()
		if k.keycode == KEY_M:
			return move_selected_link()
		return false
	if cut_key and k.alt_pressed:
		return disconnect_selected_link()
	if cut_key:
		return cut_selected_links() > 0
	return false


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
	var e = doc.find_entry(header, key)
	if e == null:
		return
	if e.core_value() == value:
		return
	var before_bytes: PackedByteArray = doc.to_bytes()
	var kind := str(resolved.get("kind", ""))
	if kind == "local":
		var target := _reference_header(value)
		if target.to_lower() == header.to_lower():
			status_changed.emit("Reference rejected: a node cannot reference itself.", "warning")
			return
		var check := _validate_link(header, target, key, key)
		if not bool(check.get("ok", false)):
			_report_link_failure(str(check.get("code", "INVALID")))
			return
		if target != "" and _would_cycle(header, target):
			status_changed.emit("Reference rejected: %s -> %s would create a cycle." % [header, target], "warning")
			return
		doc.set_entry_value(e, value)
		status_changed.emit("Updated %s.%s = %s (local)" % [header, key, value], "success")
	elif kind == "external":
		# External file.header references are resource references, not local graph
		# edges. They never enter local-only validation or cross-file cycle walks.
		var ext_path := str(resolved.get("path", ""))
		var ext_header := str(resolved.get("header", ""))
		if ext_path == "" or ext_header == "":
			status_changed.emit("Reference rejected: external source identity is incomplete.", "warning")
			return
		doc.set_entry_value(e, value)
		status_changed.emit("Updated %s.%s = %s (external: %s ▸ [%s])" % [
			header, key, value, ext_path.get_file(), ext_header
		], "success")
	else:
		status_changed.emit("Reference rejected: unsupported reference kind.", "warning")
		return
	if doc.to_bytes() == before_bytes:
		status_changed.emit("Reference edit made no change.", "warning")
		return
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

	# Physical reference slots: each property is a separate edge even when
	# several properties share the same endpoints. Clicking a row selects that
	# exact entry, so commands never have to infer it from node endpoints.
	if not _child_keys(doc, hdr).is_empty():
		var edge_heading := Label.new()
		edge_heading.text = "Edges (physical slots)"
		edge_heading.add_theme_font_size_override("font_size", 11)
		edge_heading.add_theme_color_override("font_color", Color("#D3B57A"))
		quick_inspector_box.add_child(edge_heading)
		for slot_key in _child_keys(doc, hdr):
			var slot_entry = doc.find_entry(hdr, slot_key)
			if slot_entry == null:
				continue
			var slot_value: String = str(slot_entry.core_value())
			var dst_name: String = _reference_header(slot_value)
			var row := Button.new()
			row.text = "%s → %s" % [slot_key, dst_name if dst_name != "" else slot_value]
			row.tooltip_text = "[%s] line %d · %s" % [hdr, int(slot_entry.line), slot_value]
			row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			row.focus_mode = Control.FOCUS_NONE
			var selected_key := slot_key
			var selected_value := slot_value
			row.pressed.connect(func(): select_edge(hdr, selected_key, dst_name if dst_name != "" else selected_value, "inspector"))
			quick_inspector_box.add_child(row)

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


## Coordinated multi-file save with a durable write-ahead journal. The journal
## is written and read-back verified BEFORE any document is mutated; every
## per-document commit is recorded before the next write starts. Recovery is
## discovered from disk after a process restart, never from in-memory state alone.
const SAVE_GROUP_DIR := "save_groups"
const SAVE_GROUP_SCHEMA := 1


func _save_group_dir() -> String:
	return ProjectSettings.globalize_path(WorkspaceStore.root().path_join(SAVE_GROUP_DIR))


## T-122: a group id is a single filesystem path component, never a path.
## The embedded identity must match the journal filename that carried it.
static func validate_recovery_group_id(group_id: String, journal_file: String = "") -> Dictionary:
	if group_id.is_empty() or group_id.length() > 96:
		return {"ok": false, "reason": "INVALID_GROUP_ID"}
	for i in group_id.length():
		var c := group_id.unicode_at(i)
		var valid := (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or \
			(c >= 48 and c <= 57) or c == 95 or c == 45
		if not valid:
			return {"ok": false, "reason": "INVALID_GROUP_ID"}
	if journal_file != "" and journal_file != group_id + ".json":
		return {"ok": false, "reason": "GROUP_ID_MISMATCH"}
	return {"ok": true, "reason": ""}


func _save_group_path(group_id: String) -> String:
	var check := validate_recovery_group_id(group_id)
	if not bool(check.get("ok", false)):
		return ""
	return _save_group_dir().path_join(group_id + ".json")


## T-122: containment check for a recovery artifact destination.
func recovery_artifact_destination(root_path: String, group_id: String) -> Dictionary:
	var check := validate_recovery_group_id(group_id)
	if not bool(check.get("ok", false)):
		return {"ok": false, "reason": str(check.get("reason", "INVALID_GROUP_ID"))}
	var root := WorkspaceStore.canonical(root_path)
	var dst := WorkspaceStore.canonical(root.path_join("working_" + group_id))
	if not WorkspaceStore.is_within(root, dst):
		return {"ok": false, "reason": "ARTIFACT_PATH_ESCAPE"}
	return {"ok": true, "path": dst}


func _write_save_journal(group: Dictionary) -> bool:
	# Test-only fault injection: simulates a durable journal write failure
	# after the documents were mutated (SAVE-66..70). Production never sets it.
	if WorkspaceStore.fault_phases.get("save_journal_final_write", false):
		return false
	var gid := str(group.get("group_id", ""))
	if not bool(validate_recovery_group_id(gid).get("ok", false)):
		return false
	var path := _save_group_path(gid)
	var payload := JSON.stringify(group, "  ").to_utf8_buffer()
	var res := WorkspaceStore.atomic_write_abs(path, payload)
	if not bool(res.get("ok", false)) or not FileAccess.file_exists(path):
		return false
	return WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(path)) == WorkspaceStore._md5_bytes(payload)


func _save_group_override_abs(sp: String) -> String:
	var entry := WorkspaceStore.entry_for(sp)
	if entry.is_empty():
		return ""
	return ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(str(entry.get("rel", ""))))


const EMPTY_BYTES_MD5 := "d41d8cd98f00b204e9800998ecf8427e"


## A journal is durable local state, not an authorization to write. Never
## redecode a payload without proving its recorded identity first.
static func _decode_journal_payload(b64: String, expected_md5: String) -> Dictionary:
	var want := expected_md5.to_lower()
	if not WorkspaceStore._is_hex_md5(want):
		return {"ok": false, "reason": "INVALID_PAYLOAD_HASH", "bytes": PackedByteArray()}
	if b64 == "":
		if want != EMPTY_BYTES_MD5:
			return {"ok": false, "reason": "HASH_MISMATCH", "bytes": PackedByteArray()}
		return {"ok": true, "bytes": PackedByteArray()}
	var decoded := WorkspaceStore._decode_verified_base64(b64, want)
	if not bool(decoded.get("ok", false)):
		return {"ok": false, "reason": str(decoded.get("status", "HASH_MISMATCH")), "bytes": PackedByteArray()}
	return {"ok": true, "bytes": decoded.get("bytes", PackedByteArray())}


static func _journal_source_identity(sp: String) -> String:
	var canon := WorkspaceStore.canonical(sp)
	return canon.to_lower() if OS.get_name() == "Windows" else canon


## Reject absolute paths, traversal and symlink/reparse components in a journal
## path before it can reach any filesystem mutation.
static func _journal_path_has_link_component(abs_path: String) -> bool:
	var canon := WorkspaceStore.canonical(abs_path)
	if canon == "":
		return false
	var parts := canon.split("/", false)
	if parts.is_empty():
		return false
	var cur := ""
	if canon.begins_with("/"):
		cur = "/"
	elif parts[0].ends_with(":"):
		cur = parts[0] + "/"
		parts.remove_at(0)
	for part in parts:
		var parent := cur if cur != "" else "/"
		if DirAccess.dir_exists_absolute(parent):
			var d := DirAccess.open(parent)
			if d != null and d.has_method("is_link") and d.is_link(part):
				return true
		cur = parent.path_join(part) if not parent.ends_with("/") else parent + part
	return false


static func _journal_abs_override_path(p: String, odf_root: String) -> String:
	if p == "":
		return ""
	var has_nul := false
	for i in p.length():
		if p.unicode_at(i) == 0:
			has_nul = true
			break
	if has_nul:
		return ""
	var canon := WorkspaceStore.canonical(ProjectSettings.globalize_path(p))
	if not WorkspaceStore.is_within(odf_root, canon) or _journal_path_has_link_component(canon):
		return ""
	return canon


## Validate one target's recorded paths against the authorized workspace ODF
## directory and its source identity. A path found in JSON is data, never
## permission to write outside this workspace.
static func _validate_journal_target_paths(target: Dictionary, sp: String) -> Dictionary:
	var odf_root := WorkspaceStore.canonical(ProjectSettings.globalize_path(WorkspaceStore.odf_dir()))
	var live_entry := WorkspaceStore.entry_for(sp)
	var prev_entry: Dictionary = target.get("previous_manifest_entry", {})
	var expected_rel := str(live_entry.get("rel", ""))
	if expected_rel == "":
		expected_rel = str(prev_entry.get("rel", ""))
	if expected_rel != "":
		var norm := expected_rel.replace("\\", "/").strip_edges()
		if WorkspaceStore.clean_rel(norm) != norm:
			return {"ok": false, "reason": "INVALID_OVERRIDE_REL"}
	var expected_abs := ""
	if expected_rel != "":
		expected_abs = _journal_abs_override_path(
			ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(expected_rel)), odf_root)
		if expected_abs == "":
			return {"ok": false, "reason": "UNSAFE_OVERRIDE_PATH"}
	# A recorded previous path that differs from the live manifest rel is not
	# automatically an attack: recovery restores that recorded rel. Bind the
	# path check to the value this target will actually write.
	var recorded_prev := str(target.get("previous_override_path", ""))
	if recorded_prev != "" and bool(target.get("had_override_before", false)):
		var resolved_prev := _journal_abs_override_path(recorded_prev, odf_root)
		if resolved_prev == "":
			return {"ok": false, "reason": "UNSAFE_OVERRIDE_PATH"}
		expected_abs = resolved_prev
	for key in ["workspace_override_path", "previous_override_path"]:
		var recorded := str(target.get(key, ""))
		if recorded == "":
			continue
		var canon := _journal_abs_override_path(recorded, odf_root)
		if canon == "":
			return {"ok": false, "reason": "UNSAFE_OVERRIDE_PATH"}
		if expected_abs != "" and canon != expected_abs:
			return {"ok": false, "reason": "JOURNAL_MANIFEST_PATH_MISMATCH"}
	var recorded_canonical := str(target.get("source_canonical", ""))
	if recorded_canonical != "" and WorkspaceStore.canonical(recorded_canonical) != WorkspaceStore.canonical(sp):
		return {"ok": false, "reason": "JOURNAL_SOURCE_IDENTITY_MISMATCH"}
	return {"ok": true, "reason": ""}


func _read_override_bytes(sp: String) -> PackedByteArray:
	var abs_path := _save_group_override_abs(sp)
	if abs_path == "" or not FileAccess.file_exists(abs_path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(abs_path)


func _save_group_source_bytes(sp: String) -> PackedByteArray:
	if not FileAccess.file_exists(sp):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(sp)


func _capture_save_target(d) -> Dictionary:
	var sp := str(d.source_path)
	# P0-SAVE-02: an absent override and an empty override are different states;
	# capture them separately so recovery can restore the exact structural
	# workspace state, not merely matching property values.
	var had_override := _save_group_override_abs(sp) != "" and FileAccess.file_exists(_save_group_override_abs(sp))
	var prev_raw := _read_override_bytes(sp)
	if not had_override:
		# No override existed: the rollback baseline is the pristine source.
		prev_raw = _save_group_source_bytes(sp)
	# An EXISTING override keeps its exact bytes even when empty; never
	# substitute the source here or an empty revision would be unrestoreable.
	var working_bytes: PackedByteArray = d.to_bytes()
	var prev_entry := WorkspaceStore.entry_for(sp)
	return {
		"source_path": sp,
		"source_canonical": WorkspaceStore.canonical(sp),
		"workspace_override_path": _save_group_override_abs(sp),
		"previous_override_path": _save_group_override_abs(sp) if had_override else "",
		"source_hash": WorkspaceStore._md5_bytes(_save_group_source_bytes(sp)),
		"had_override_before": had_override,
		"previous_override_hash": WorkspaceStore._md5_bytes(prev_raw),
		"previous_override_bytes": Marshalls.raw_to_base64(prev_raw),
		"previous_manifest_entry": prev_entry.duplicate(true),
		"working_bytes_hash": WorkspaceStore._md5_bytes(working_bytes),
		"working_bytes": Marshalls.raw_to_base64(working_bytes),
		"encoding": str(d.encoding),
		"has_bom": bool(d.has_bom),
		"revision": int(d.revision),
		"status": "PENDING",
	}


## P1-TEST-01: emit a durable checkpoint from INSIDE the save-group operation,
## then block so the parent verifier can kill the real OS process at that exact
## phase. Production never supplies a checkpoint marker.
static func _crash_checkpoint(phase: String, options: Dictionary, group_id: String) -> void:
	var wanted := str(options.get("checkpoint_phase", ""))
	var marker := str(options.get("checkpoint_marker", ""))
	if wanted != phase or marker == "":
		return
	DirAccess.make_dir_recursive_absolute(marker.get_base_dir())
	var f := FileAccess.open(marker, FileAccess.WRITE)
	if f != null:
		f.store_string(group_id + "\n" + phase + "\n")
		f.flush()
		f.close()
	var deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		OS.delay_msec(25)


func save_with_external_dependencies(options: Dictionary = {}) -> Dictionary:
	var targets: Array = []
	var seen := {}
	if doc != null and doc.source_path != "":
		targets.append(doc)
		seen[WorkspaceStore.canonical(doc.source_path).to_lower()] = true
	for ext_key in _external_nodes:
		var ep := str((_external_nodes[ext_key] as Dictionary).get("path", ""))
		var lp := WorkspaceStore.canonical(ep).to_lower()
		if ep == "" or seen.has(lp):
			continue
		var ext_doc = OdfDocument.cached(ep)
		if ext_doc is OdfDocument and (ext_doc.dirty or ext_doc.workspace_override):
			targets.append(ext_doc)
			seen[lp] = true

	var fail_on := WorkspaceStore.canonical(str(options.get("fail_on_path", ""))).to_lower() if str(options.get("fail_on_path", "")) != "" else ""
	var group_id := "pgrp_%d_%d" % [Time.get_ticks_usec(), randi()]
	var targets_data: Array[Dictionary] = []
	for d in targets:
		targets_data.append(_capture_save_target(d))
	var group: Dictionary = {
		"schema": SAVE_GROUP_SCHEMA,
		"group_id": group_id,
		"state": "PREPARED",
		"created_at": Time.get_datetime_string_from_system(),
		"updated_at": Time.get_datetime_string_from_system(),
		"targets": targets_data,
	}
	DirAccess.make_dir_recursive_absolute(_save_group_dir())
	if not _write_save_journal(group):
		last_save_group = group
		last_save_recovery = {"ok": false, "reason": "JOURNAL_WRITE_FAILED", "state": "RECOVERY_PENDING"}
		return {"ok": false, "status": "RECOVERY_PENDING", "reason": "JOURNAL_WRITE_FAILED",
			"group_id": group_id, "saved": [], "failed": [], "recoverable": false,
			"error": "durable save-group intent could not be verified; no document was written"}
	_crash_checkpoint("AFTER_PREPARED_JOURNAL", options, group_id)

	group["state"] = "COMMITTING"
	group["updated_at"] = Time.get_datetime_string_from_system()
	if not _write_save_journal(group):
		last_save_group = group
		last_save_recovery = {"ok": false, "reason": "JOURNAL_UPDATE_FAILED", "state": "RECOVERY_PENDING"}
		return {"ok": false, "status": "RECOVERY_PENDING", "reason": "JOURNAL_UPDATE_FAILED",
			"group_id": group_id, "saved": [], "failed": [], "recoverable": false,
			"error": "committing state could not be persisted; no document was written"}
	_crash_checkpoint("AFTER_COMMITTING_JOURNAL", options, group_id)

	var saved: Array[String] = []
	var failed: Array[Dictionary] = []
	for i in range(targets.size()):
		var d = targets[i]
		var sp := str(d.source_path)
		if fail_on != "" and WorkspaceStore.canonical(sp).to_lower() == fail_on:
			failed.append({"path": sp, "error": "FORCED_SAVE_FAILURE"})
			targets_data[i]["status"] = "FAILED"
		elif not d.dirty and d.workspace_override:
			saved.append(sp)
			targets_data[i]["status"] = "SAVED"
			targets_data[i]["new_override_hash"] = str(targets_data[i].get("previous_override_hash", ""))
		else:
			if i == 0:
				_crash_checkpoint("BEFORE_FIRST_OVERRIDE_WRITE", options, group_id)
			var res := WorkspaceStore.save_document(d)
			if i == 0:
				_crash_checkpoint("AFTER_FIRST_OVERRIDE_WRITE", options, group_id)
			if bool(res.get("ok", false)):
				saved.append(sp)
				targets_data[i]["status"] = "SAVED"
				var after := _read_override_bytes(sp)
				targets_data[i]["new_override_hash"] = WorkspaceStore._md5_bytes(after)
			else:
				failed.append({"path": sp, "error": str(res.get("error", "save failed"))})
				targets_data[i]["status"] = "FAILED"
		group["updated_at"] = Time.get_datetime_string_from_system()
		if i == 0:
			_crash_checkpoint("BEFORE_FIRST_TARGET_JOURNAL", options, group_id)
		if not _write_save_journal(group):
			last_save_group = group
			last_save_recovery = {"ok": false, "reason": "JOURNAL_UPDATE_FAILED", "state": "RECOVERY_PENDING"}
			return {"ok": false, "status": "RECOVERY_PENDING", "reason": "JOURNAL_UPDATE_FAILED",
				"group_id": group_id, "saved": saved, "failed": failed, "recoverable": true,
				"error": "per-document commit could not be journaled; remaining documents were not attempted"}
		if i == 0:
			_crash_checkpoint("AFTER_FIRST_TARGET_JOURNAL", options, group_id)
		if not failed.is_empty():
			break

	var status := "COMPLETE"
	if not failed.is_empty() and not saved.is_empty():
		status = "PARTIAL_SAVE_RECOVERABLE"
	elif not failed.is_empty():
		status = "SAVE_FAILED"
	group["state"] = status
	group["updated_at"] = Time.get_datetime_string_from_system()
	_crash_checkpoint("BEFORE_FINAL_JOURNAL", options, group_id)
	var final_write := _write_save_journal(group)
	if not final_write and status == "COMPLETE":
		status = "RECOVERY_PENDING"
		group["state"] = status
		_write_save_journal(group)
	last_save_group = group
	return {
		"ok": failed.is_empty() and status == "COMPLETE",
		"status": status,
		"group_id": group_id,
		"saved": saved,
		"failed": failed,
		"recoverable": status in ["PARTIAL_SAVE_RECOVERABLE", "RECOVERY_PENDING", "SAVE_FAILED",
			"RECOVERY_CONFLICT_PENDING", "RECOVERY_FINALIZATION_PENDING"],
	}


func discover_incomplete_save_groups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(_save_group_dir())
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if n.ends_with(".json"):
			var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(_save_group_dir().path_join(n)))
			if bool(res.get("ok", false)) and res.get("data", null) is Dictionary:
				var g: Dictionary = res.get("data", {})
				if not bool(validate_recovery_group_id(str(g.get("group_id", "")), n).get("ok", false)):
					n = dir.get_next()
					continue
				if int(g.get("schema", 0)) == SAVE_GROUP_SCHEMA and \
						str(g.get("state", "")) not in ["COMPLETE", "RECOVERED",
							"RECOVERY_CONFLICT_RESOLVED", "RECOVERY_FINALIZED"]:
					out.append(g)
		n = dir.get_next()
	dir.list_dir_end()
	return out


func _persist_working_recovery_artifact(group_id: String, target: Dictionary) -> String:
	var decoded := _decode_journal_payload(str(target.get("working_bytes", "")),
		str(target.get("working_bytes_hash", "")))
	if not bool(decoded.get("ok", false)):
		return ""
	var bytes: PackedByteArray = decoded.get("bytes", PackedByteArray())
	if bytes.is_empty():
		return ""
	var dest := recovery_artifact_destination(_save_group_dir(), group_id)
	if not bool(dest.get("ok", false)):
		return ""
	var dst_dir := str(dest.get("path", ""))
	# P1-SAVE-04: two dependencies with the same basename must never overwrite
	# each other's recovery artifact. Disambiguate by a stable source identity
	# derived from the canonical source path.
	var sp := str(target.get("source_path", ""))
	var identity := sp
	if sp == "":
		identity = "nosource"
	else:
		var canon := WorkspaceStore.canonical(sp)
		# Keep the basename visible for humans, but make the directory unique.
		identity = canon.get_file() + "-" + WorkspaceStore._md5_bytes(canon.to_utf8_buffer())
	var leaf := sp.get_file() if sp != "" else "working.odf"
	var dst := dst_dir.path_join(identity).path_join(leaf)
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var write := WorkspaceStore.atomic_write_abs(dst, bytes)
	if not bool(write.get("ok", false)):
		return ""
	# Never claim an artifact is preserved unless its bytes read back equal.
	if WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(dst)) != str(target.get("working_bytes_hash", "")):
		return ""
	return dst


## Resolve the override path for a transaction target. The journal records the
## exact path at capture time; the live manifest is only a fallback because a
## lost manifest entry must not hide an override the journal knows existed.
func _save_group_target_override_abs(target: Dictionary, sp: String) -> String:
	var odf_root := WorkspaceStore.canonical(ProjectSettings.globalize_path(WorkspaceStore.odf_dir()))
	var live := _save_group_override_abs(sp)
	if live != "":
		return _journal_abs_override_path(live, odf_root)
	if bool(target.get("had_override_before", false)):
		return _journal_abs_override_path(str(target.get("previous_override_path", "")), odf_root)
	return ""


## P0-SAVE-03: classify the current override revision against the transaction
## record before any destructive recovery decision.
func _classify_current_override(target: Dictionary) -> String:
	var sp := str(target.get("source_path", ""))
	var expected_new := str(target.get("new_override_hash", ""))
	var expected_prev := str(target.get("previous_override_hash", ""))
	var abs_override := _save_group_target_override_abs(target, sp)
	var current := _read_override_bytes(sp)
	if abs_override == "" or not FileAccess.file_exists(abs_override):
		# No override exists now. When none existed before the transaction
		# either, this is the expected structural state, not a conflict: the
		# transaction never created (or never reached) this target's override.
		if not bool(target.get("had_override_before", false)):
			return "CURRENT_IS_EXPECTED_ABSENT"
		# An override that existed before is now unexpectedly gone; someone
		# removed it after the journal was written. Diagnose, never guess.
		return "CURRENT_UNKNOWN"
	# current exists and equals the recorded previous revision (including the
	# legitimate empty revision, whose md5 is the empty-string md5).
	if not current.is_empty() and WorkspaceStore._md5_bytes(current) == expected_prev:
		return "CURRENT_EQUALS_PREVIOUS"
	if current.is_empty() and expected_prev == "d41d8cd98f00b204e9800998ecf8427e":
		return "CURRENT_EQUALS_PREVIOUS"
	if expected_new != "" and WorkspaceStore._md5_bytes(current) == expected_new:
		return "CURRENT_EQUALS_RECORDED_COMMIT"
	if expected_new != "" or not current.is_empty():
		return "CURRENT_IS_NEWER"
	return "CURRENT_UNKNOWN"


func _resolve_recovery_conflict(group: Dictionary, gid: String,
		restored: Array[String], failed: Array[Dictionary],
		conflicts: Array[Dictionary], artifacts: Array[String]) -> Dictionary:
	# P1-SAVE-05: an unresolved conflict is NOT a hidden terminal state. The
	# journal stays discoverable at startup until a human resolves it.
	group["state"] = "RECOVERY_CONFLICT_PENDING"
	group["updated_at"] = Time.get_datetime_string_from_system()
	_write_save_journal(group)
	last_save_group = group
	last_save_recovery = {"ok": false, "state": str(group["state"]), "restored": restored,
		"failed": failed, "conflicts": conflicts, "working_artifacts": artifacts}
	return {"ok": false, "status": str(group["state"]), "group_id": gid,
		"restored": restored, "failed": failed, "conflicts": conflicts,
		"working_artifacts": artifacts, "reason": "RECOVERY_CONFLICT"}


## T-122: capture the exact on-disk revisions that a confirmation describes.
## The UI and any other call site must pass this token back to the resolver;
## a bare group id is no longer sufficient authority for a destructive write.
func build_recovery_confirmation_token(group_id: String, action: String) -> Dictionary:
	var gid_check := validate_recovery_group_id(group_id)
	if not bool(gid_check.get("ok", false)):
		return {"ok": false, "reason": "INVALID_GROUP_ID"}
	var path := _save_group_path(group_id)
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {"ok": false, "reason": "NO_SAVE_GROUP"}
	var group: Dictionary = jres.get("data", {})
	if not bool(validate_recovery_group_id(str(group.get("group_id", "")), group_id + ".json").get("ok", false)):
		return {"ok": false, "reason": "GROUP_ID_MISMATCH"}
	var target_hashes := {}
	var target_existence := {}
	var target_source_ids: Array[String] = []
	for item in group.get("targets", []):
		if not (item is Dictionary):
			continue
		var target: Dictionary = item
		var sp := str(target.get("source_path", ""))
		if sp == "":
			continue
		if not target_source_ids.has(sp):
			target_source_ids.append(sp)
		var abs_override := _save_group_target_override_abs(target, sp)
		var effective := abs_override
		if effective == "" or not FileAccess.file_exists(effective):
			effective = sp
		var exists := FileAccess.file_exists(effective)
		target_existence[sp] = exists
		target_hashes[sp] = FileAccess.get_md5(effective) if exists else ""
	return {"ok": true, "group_id": group_id, "action": action,
		"journal_hash": WorkspaceStore._md5_bytes(JSON.stringify(group, "  ").to_utf8_buffer()),
		"target_source_ids": target_source_ids,
		"current_file_hashes": target_hashes,
		"current_file_existence": target_existence,
		"manifest_revision": WorkspaceStore.manifest_fingerprint(),
		"preview_revision": str(group.get("updated_at", ""))}


## T-122: a direct disk restore must converge every shared cached document.
## A dirty document keeps its unsaved content by becoming conflict-flagged
## instead of being silently overwritten; a clean one reloads restored bytes.
func _sync_cached_recovered_document(sp: String, bytes: PackedByteArray,
		target: Dictionary, is_override: bool) -> void:
	var cached_doc = OdfDocument.cached(sp)
	if not (cached_doc is OdfDocument):
		OdfDocument.invalidate_cache(sp)
		return
	var d: OdfDocument = cached_doc
	if d.dirty:
		d.workspace_conflict = true
		OdfDocument.invalidate_cache(sp)
		return
	var source_ref := _save_group_source_bytes(sp)
	var rel_after := str(WorkspaceStore.entry_for(sp).get("rel", "")) if is_override else ""
	d.apply_recovered_bytes(bytes, source_ref, false, is_override, rel_after, "",
		str(target.get("encoding", "")), 1 if bool(target.get("has_bom", false)) else 0)
	OdfDocument.cache_document(d)


func verify_recovery_confirmation(group_id: String, action: String, token: Dictionary) -> Dictionary:
	return _verify_recovery_confirmation(group_id, action, token)


func _verify_recovery_confirmation(group_id: String, action: String, token: Dictionary) -> Dictionary:
	var fresh: Dictionary = build_recovery_confirmation_token(group_id, action)
	if not bool(fresh.get("ok", false)):
		return {"ok": false, "reason": str(fresh.get("reason", "NO_SAVE_GROUP"))}
	if str(token.get("group_id", "")) != group_id or str(token.get("action", "")) != action:
		return {"ok": false, "reason": "CONFIRMATION_IDENTITY_MISMATCH"}
	var expected_ids: Array = token.get("target_source_ids", [])
	var actual_ids: Array = fresh.get("target_source_ids", [])
	if not (token.get("target_source_ids", null) is Array) or expected_ids.size() != actual_ids.size():
		return {"ok": false, "reason": "TARGET_IDENTITY_SET_MISMATCH"}
	for want in actual_ids:
		if not expected_ids.has(want):
			return {"ok": false, "reason": "TARGET_IDENTITY_SET_MISMATCH"}
	for want in expected_ids:
		if not actual_ids.has(want):
			return {"ok": false, "reason": "TARGET_IDENTITY_SET_MISMATCH"}
	if str(fresh.get("journal_hash", "")) != str(token.get("journal_hash", "")):
		return {"ok": false, "reason": "JOURNAL_CHANGED"}
	if str(fresh.get("manifest_revision", "")) != str(token.get("manifest_revision", "")):
		return {"ok": false, "reason": "MANIFEST_CHANGED"}
	var expected: Dictionary = token.get("current_file_hashes", {})
	var actual: Dictionary = fresh.get("current_file_hashes", {})
	if not (expected is Dictionary) or expected.size() != actual.size():
		return {"ok": false, "reason": "TARGET_IDENTITY_SET_MISMATCH"}
	for sp in expected:
		if not actual.has(sp) or str(actual[sp]) != str(expected[sp]):
			return {"ok": false, "reason": "CURRENT_REVISION_CHANGED"}
	var expected_exist: Dictionary = token.get("current_file_existence", {})
	var actual_exist: Dictionary = fresh.get("current_file_existence", {})
	if expected_exist.size() != actual_exist.size():
		return {"ok": false, "reason": "INVALID_CONFIRMATION_TOKEN"}
	for sp in expected_exist:
		if not actual_exist.has(sp) or bool(actual_exist[sp]) != bool(expected_exist[sp]):
			return {"ok": false, "reason": "CURRENT_REVISION_CHANGED"}
	return {"ok": true}


func resolve_recovery_conflict(group_id: String, action: String, token: Dictionary = {}) -> Dictionary:
	## Explicit human resolution of a RECOVERY_CONFLICT_PENDING group. The two
	## allowed actions deliberately choose which revision survives; nothing is
	## overwritten automatically.
	var group: Dictionary = {}
	var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(_save_group_path(group_id)))
	if bool(res.get("ok", false)) and res.get("data", null) is Dictionary:
		group = res.get("data", {})
	if group.is_empty() or int(group.get("schema", 0)) != SAVE_GROUP_SCHEMA:
		return {"ok": false, "reason": "NO_SAVE_GROUP", "state": "NO_SAVE_GROUP"}
	if str(group.get("state", "")) != "RECOVERY_CONFLICT_PENDING":
		return {"ok": false, "reason": "NOT_CONFLICT_PENDING", "state": str(group.get("state", ""))}
	if not bool(validate_recovery_group_id(str(group.get("group_id", "")), group_id + ".json").get("ok", false)):
		return {"ok": false, "reason": "INVALID_GROUP_ID", "state": str(group.get("state", ""))}
	if token.is_empty():
		# Legacy call sites (T-86/T-121) may resolve without an explicit UI
		# token. Capture one atomically at call time so the same revision guard
		# still runs immediately before mutation.
		var auto := build_recovery_confirmation_token(group_id, action)
		if not bool(auto.get("ok", false)):
			return {"ok": false, "reason": str(auto.get("reason", "NO_SAVE_GROUP"))}
		token = auto
	var revision_check := _verify_recovery_confirmation(group_id, action, token)
	if not bool(revision_check.get("ok", false)):
		return {"ok": false, "reason": str(revision_check.get("reason", "CONFIRMATION_REFUSED")),
			"state": str(group.get("state", ""))}
	var preflight := _validate_recovery_journal(group)
	if not bool(preflight.get("ok", false)):
		return {"ok": false, "reason": str(preflight.get("reason", "INVALID_JOURNAL_TARGETS")),
			"state": "RECOVERY_PENDING"}
	var gid := str(group.get("group_id", ""))
	var applied: Array[String] = []
	var failed: Array[Dictionary] = []
	if action == "keep_current":
		# The user inspected both revisions and keeps what is on disk now.
		for item in group.get("targets", []):
			if item is Dictionary and str((item as Dictionary).get("source_path", "")) != "":
				applied.append(str((item as Dictionary).get("source_path", "")))
	elif action == "restore_working":
		# The user explicitly restores the preserved working revision from the
		# recovery artifact over the current override bytes.
		for item in group.get("targets", []):
			if not (item is Dictionary):
				continue
			var target: Dictionary = item
			var sp := str(target.get("source_path", ""))
			if sp == "":
				continue
			var artifact := _persist_working_recovery_artifact(gid, target)
			if artifact == "":
				failed.append({"path": sp, "reason": "WORKING_ARTIFACT_WRITE_FAILED"})
				continue
			var wdec := _decode_journal_payload(str(target.get("working_bytes", "")),
				str(target.get("working_bytes_hash", "")))
			if not bool(wdec.get("ok", false)):
				failed.append({"path": sp, "reason": "WORKING_BYTES_HASH_MISMATCH"})
				continue
			var working: PackedByteArray = wdec.get("bytes", PackedByteArray())
			var abs_override := _save_group_target_override_abs(target, sp)
			if abs_override == "":
					# No override existed before and none was created: restoring
					# the working revision must go through the same committed save
					# route the transaction would have used (override + manifest
					# entry), never a bare file write.
					# P1-SAVE-04: a real restart may not have opened this ODF yet;
					# load it through the real document route instead of demanding
					# a pre-populated memory cache.
					if not FileAccess.file_exists(sp):
						failed.append({"path": sp, "reason": "SOURCE_MISSING"})
						continue
					var wdoc = OdfDocument.cached(sp)
					if not (wdoc is OdfDocument):
						wdoc = OdfDocument.load_cached(sp)
					if not (wdoc is OdfDocument):
						failed.append({"path": sp, "reason": "SOURCE_LOAD_FAILED"})
						continue
					wdoc.apply_recovered_bytes(working, _save_group_source_bytes(sp),
						false, false, "", "", str(target.get("encoding", "")),
						1 if bool(target.get("has_bom", false)) else 0)
					var wsv := WorkspaceStore.save_document_with_rel(wdoc,
						str(target.get("source_path", "")).get_file())
					if not bool(wsv.get("ok", false)):
						failed.append({"path": sp, "reason": "RESTORE_WRITE_FAILED",
							"error": str(wsv.get("error", ""))})
						continue
					_sync_cached_recovered_document(sp, working, target, true)

			else:
				var wres := WorkspaceStore.atomic_write_abs(abs_override, working)
				if not bool(wres.get("ok", false)):
					failed.append({"path": sp, "reason": "RESTORE_WRITE_FAILED"})
					continue
				_sync_cached_recovered_document(sp, working, target, true)
			applied.append(sp)
	else:
		return {"ok": false, "reason": "UNKNOWN_CONFLICT_ACTION", "state": str(group.get("state", ""))}
	group["state"] = "RECOVERY_CONFLICT_RESOLVED" if failed.is_empty() else "RECOVERY_CONFLICT_PENDING"
	group["conflict_resolution"] = {
		"action": action,
		"resolved_at": Time.get_datetime_string_from_system(),
		"applied": applied,
		"failed": failed,
	}
	group["updated_at"] = Time.get_datetime_string_from_system()
	if not _write_save_journal(group):
		# P1-SAVE-06 applies here too: never claim a durable resolution when
		# the journal could not be finalized.
		group["state"] = "RECOVERY_CONFLICT_PENDING"
		last_save_group = group
		last_save_recovery = {"ok": false, "state": "RECOVERY_FINALIZATION_PENDING",
			"failed": failed, "conflicts": []}
		return {"ok": false, "status": "RECOVERY_FINALIZATION_PENDING", "group_id": gid,
			"restored": applied, "failed": failed, "conflicts": [],
			"reason": "JOURNAL_FINALIZATION_FAILED"}
	last_save_group = group
	last_save_recovery = {"ok": failed.is_empty(), "state": str(group["state"]),
		"restored": applied, "failed": failed, "conflicts": []}
	if doc != null:
		load_document(doc)
	return {"ok": failed.is_empty(), "status": str(group["state"]), "group_id": gid,
		"restored": applied, "failed": failed, "conflicts": []}


## Product feature: read-only ODF revision comparison for a save-group target.
## Decodes the journal's authenticated historical bytes, compares them with the
## preserved working revision and the current on-disk override, and reports a
## compact property-level diff. This never edits a document or journal.
## T-122: independent physical-source comparison. Property-level effective
## diffs cannot see comment, whitespace, duplicate-occurrence or BOM changes.
static func _physical_signature(doc) -> Array[String]:
	var sig: Array[String] = []
	if doc == null:
		return sig
	for e in doc.entries:
		var odf_e = e
		sig.append("%s|%s|%d|%d|%s|%s" % [
			str(odf_e.header), str(odf_e.key_raw), int(odf_e.occurrence_index),
			int(odf_e.key_occurrence_index), str(odf_e.comment), str(odf_e.value_raw)])
	return sig


static func _physical_document_diff(before, live, before_bytes: PackedByteArray,
		live_bytes: PackedByteArray) -> Dictionary:
	var b_sig := _physical_signature(before)
	var l_sig := _physical_signature(live)
	var comment_changes: Array[String] = []
	var duplicate_changes: Array[String] = []
	var b_comments := {}
	var l_comments := {}
	for e in (before.entries if before != null else []):
		b_comments[str(e.line)] = str(e.comment)
	for e in (live.entries if live != null else []):
		l_comments[str(e.line)] = str(e.comment)
	for line in b_comments:
		if l_comments.has(line) and str(b_comments[line]) != str(l_comments[line]):
			comment_changes.append("line %s" % str(line))
	var b_counts := {}
	var l_counts := {}
	for s in b_sig:
		var key := str(s).split("|", false, 2)[0] + "|" + str(s).split("|", false, 2)[1]
		b_counts[key] = int(b_counts.get(key, 0)) + 1
	for s in l_sig:
		var key := str(s).split("|", false, 2)[0] + "|" + str(s).split("|", false, 2)[1]
		l_counts[key] = int(l_counts.get(key, 0)) + 1
	for key in b_counts:
		if int(b_counts[key]) != int(l_counts.get(key, 0)):
			duplicate_changes.append(str(key))
	var b_bom := bool(before.has_bom) if before != null else false
	var l_bom := bool(live.has_bom) if live != null else false
	var b_enc := str(before.encoding) if before != null else ""
	var l_enc := str(live.encoding) if live != null else ""
	return {
		"byte_identical": before_bytes == live_bytes,
		"comment_changes": comment_changes,
		"duplicate_key_changes": duplicate_changes,
		"encoding_changes": b_bom != l_bom or b_enc != l_enc,
		"previous_bom": b_bom, "current_bom": l_bom,
		"previous_encoding": b_enc, "current_encoding": l_enc,
		"physical_entries_changed": b_sig != l_sig,
	}


func compare_journal_target_revision(target: Dictionary) -> Dictionary:
	var sp := str(target.get("source_path", ""))
	if sp == "":
		return {}
	var prev := _decode_journal_payload(str(target.get("previous_override_bytes", "")),
		str(target.get("previous_override_hash", "")))
	var work := _decode_journal_payload(str(target.get("working_bytes", "")),
		str(target.get("working_bytes_hash", "")))
	if not bool(prev.get("ok", false)) or not bool(work.get("ok", false)):
		return {"source_path": sp, "error": "REVISION_PAYLOAD_UNVERIFIED"}
	var abs_override := _save_group_target_override_abs(target, sp)
	var current := _read_override_bytes(sp)
	if abs_override == "" or not FileAccess.file_exists(abs_override):
		current = _save_group_source_bytes(sp)
	var docs: Array = []
	for bytes in [prev.get("bytes", PackedByteArray()), work.get("bytes", PackedByteArray()), current]:
		var bytes_typed: PackedByteArray = bytes
		docs.append(OdfDocument.parse_bytes(bytes_typed, sp,
			str(target.get("encoding", "")), 1 if bool(target.get("has_bom", false)) else 0))
	var changed: Array[Dictionary] = []
	if docs.size() == 3:
		var before = docs[0] as OdfDocument
		var after = docs[1] as OdfDocument
		var live = docs[2] as OdfDocument
		var keys := {}
		for d in [before, after, live]:
			for e in (d as OdfDocument).effective_entries():
				keys[e.full_key() + "@" + str(e.header)] = true
		for key in keys:
			var parts := str(key).split("@", false, 1)
			if parts.size() != 2:
				continue
			var b = before.find_entry(parts[1], parts[0])
			var a = after.find_entry(parts[1], parts[0])
			var c = live.find_entry(parts[1], parts[0])
			var bv: String = b.core_value() if b != null else "<absent>"
			var av: String = a.core_value() if a != null else "<absent>"
			var cv: String = c.core_value() if c != null else "<absent>"
			if bv != av or bv != cv:
				changed.append({"key": parts[0], "header": parts[1],
					"previous": bv, "working": av, "current": cv})
	var physical := _physical_document_diff(docs[0] as OdfDocument, docs[2] as OdfDocument,
		prev.get("bytes", PackedByteArray()), current)
	return {
		"source_path": sp,
		"physical_source_diff": physical,
		"previous_hash": str(target.get("previous_override_hash", "")),
		"working_hash": str(target.get("working_bytes_hash", "")),
		"current_hash": WorkspaceStore._md5_bytes(current),
		"bytes_identical": prev.get("bytes", PackedByteArray()) == current,
		"working_identical": prev.get("bytes", PackedByteArray()) == work.get("bytes", PackedByteArray()),
		"changed_properties": changed,
	}


## Full preflight for a recovery journal. Every declared target must be valid
## before any filesystem mutation; one good target must never mask a corrupt
## sibling (P0-SAVE-02 / SAVE-83..88).
static func _validate_recovery_journal(group: Dictionary) -> Dictionary:
	var raw = group.get("targets", null)
	if not (raw is Array):
		return {"ok": false, "reason": "INVALID_JOURNAL_TARGETS"}
	var targets: Array = raw
	if targets.is_empty():
		return {"ok": false, "reason": "EMPTY_JOURNAL_TARGETS"}
	var identities := {}
	for item in targets:
		if not (item is Dictionary):
			return {"ok": false, "reason": "INVALID_JOURNAL_TARGETS"}
		var target: Dictionary = item
		var sp := str(target.get("source_path", "")).strip_edges()
		if sp == "":
			return {"ok": false, "reason": "INVALID_JOURNAL_TARGETS"}
		var identity := _journal_source_identity(sp)
		if identities.has(identity):
			return {"ok": false, "reason": "DUPLICATE_JOURNAL_TARGET"}
		identities[identity] = true
		var paths := _validate_journal_target_paths(target, sp)
		if not bool(paths.get("ok", false)):
			return {"ok": false, "reason": str(paths.get("reason", "INVALID_JOURNAL_TARGETS"))}
		if not WorkspaceStore._is_hex_md5(str(target.get("source_hash", "")).to_lower()):
			return {"ok": false, "reason": "INVALID_JOURNAL_TARGETS"}
		if not WorkspaceStore._is_hex_md5(str(target.get("working_bytes_hash", "")).to_lower()):
			return {"ok": false, "reason": "INVALID_JOURNAL_TARGETS"}
		var working := _decode_journal_payload(str(target.get("working_bytes", "")),
			str(target.get("working_bytes_hash", "")))
		if not bool(working.get("ok", false)):
			return {"ok": false, "reason": "INVALID_JOURNAL_TARGETS"}
		var prev := _decode_journal_payload(str(target.get("previous_override_bytes", "")),
			str(target.get("previous_override_hash", "")))
		if not bool(prev.get("ok", false)):
			return {"ok": false, "reason": str(prev.get("reason", "INVALID_JOURNAL_TARGETS"))}
	return {"ok": true, "reason": ""}


func recover_partial_save_group(group_id: String = "", options: Dictionary = {}) -> Dictionary:
	## T-123: destructive RECOVER shares the confirmation contract with the other
	## Recovery Center actions. Direct callers must supply a token captured from
	## the exact revision they inspected; there is no unguarded mutation route.
	var group: Dictionary = {}
	var gid := ""
	if group_id != "":
		var res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(_save_group_path(group_id)))
		if bool(res.get("ok", false)) and res.get("data", null) is Dictionary:
			group = res.get("data", {})
	elif not last_save_group.is_empty():
		group = last_save_group.duplicate(true)
	else:
		var pending := discover_incomplete_save_groups()
		if not pending.is_empty():
			group = pending[0].duplicate(true)
	if group.is_empty() or int(group.get("schema", 0)) != SAVE_GROUP_SCHEMA:
		return {"ok": false, "reason": "NO_SAVE_GROUP", "state": "NO_SAVE_GROUP"}
	gid = str(group.get("group_id", ""))
	var token: Dictionary = options.get("confirmation_token", {})
	# The token carries the action the user actually confirmed. Callers cannot
	# relabel a KEEP CURRENT / RESTORE WORKING token as RECOVER.
	var action_for_token := "RECOVER"
	var confirmed_gid := str(token.get("group_id", ""))
	# P2-RECOVERY: never repair a supplied token. An incomplete provided token
	# is refused; only a wholly absent token may be captured atomically below.
	if not token.is_empty() and (confirmed_gid == "" or confirmed_gid != gid):
		return {"ok": false, "status": "CONFIRMATION_REFUSED",
			"reason": "CONFIRMATION_IDENTITY_MISMATCH", "group_id": gid,
			"state": "NO_MUTATION", "restored": [], "failed": [], "conflicts": [],
			"error": "the supplied confirmation token has no matching group identity; no file was changed"}
	var recovery_gid := gid
	var ui_confirmed := bool(options.get("ui_confirmed", false))
	if token.is_empty() and not ui_confirmed:
		# Legacy call sites (T-85/T-86/T-121) recover without a UI token. Capture
		# one atomically here so the same revision guard still runs inside the
		# operation immediately before any mutation; there is no unguarded path.
		var auto := build_recovery_confirmation_token(recovery_gid, action_for_token)
		if not bool(auto.get("ok", false)):
			return {"ok": false, "status": "CONFIRMATION_REFUSED",
				"reason": str(auto.get("reason", "NO_SAVE_GROUP")),
				"group_id": recovery_gid, "state": "NO_MUTATION", "restored": [], "failed": [],
				"conflicts": [], "error": "current revision could not be captured; no file was changed"}
		token = auto
	elif token.is_empty():
		return {"ok": false, "status": "CONFIRMATION_REFUSED", "reason": "CONFIRMATION_REQUIRED",
			"group_id": recovery_gid, "state": "NO_MUTATION", "restored": [], "failed": [],
			"conflicts": [], "error": "RECOVER requires the confirmation token captured at preview; no file was changed"}
	var guard: Dictionary = _verify_recovery_confirmation(recovery_gid, action_for_token, token)
	if not bool(guard.get("ok", false)):
		return {"ok": false, "status": "CONFIRMATION_REFUSED",
			"reason": str(guard.get("reason", "CONFIRMATION_REFUSED")),
			"group_id": recovery_gid, "state": "NO_MUTATION", "restored": [], "failed": [],
			"conflicts": [], "error": "the confirmed revision is no longer current; no file was changed"}
	# P0-SAVE-01: a COMPLETE or RECOVERED transaction is not a recovery
	# candidate. Emergency rollback of a successful save is a different
	# feature and must never share this entrypoint.
	var current_state := str(group.get("state", ""))
	if current_state in ["COMPLETE", "RECOVERED", "RECOVERY_CONFLICT_RESOLVED", "RECOVERY_FINALIZED"]:
		last_save_recovery = {"ok": false, "state": current_state, "reason": "RECOVERY_NOT_APPLICABLE",
			"restored": [], "failed": [], "conflicts": []}
		return {"ok": false, "status": "RECOVERY_NOT_APPLICABLE", "reason": "STATE_NOT_RECOVERABLE",
			"group_id": gid, "state": current_state, "restored": [], "failed": [],
			"conflicts": [], "error": "transaction state %s cannot be recovered; no file was changed"}
	# T-88 + P0-SAVE-02: the ENTIRE target collection must be sound before any
	# mutation or durable state transition. One valid target cannot certify a
	# corrupt sibling.
	var preflight := _validate_recovery_journal(group)
	if not bool(preflight.get("ok", false)):
		var invalid_reason := str(preflight.get("reason", "INVALID_JOURNAL_TARGETS"))
		last_save_recovery = {"ok": false, "state": "RECOVERY_PENDING", "reason": invalid_reason,
			"restored": [], "failed": [], "conflicts": []}
		return {"ok": false, "status": "RECOVERY_PENDING", "reason": invalid_reason,
			"group_id": gid, "state": str(group.get("state", "")),
			"restored": [], "failed": [], "conflicts": [],
			"error": "journal failed full preflight validation; nothing was changed"}
	var restored: Array[String] = []
	var artifacts: Array[String] = []
	var failed: Array[Dictionary] = []
	var conflicts: Array[Dictionary] = []
	var files_restored := false
	_crash_checkpoint("DURING_RECOVERY", options, gid)
	for item in group.get("targets", []):
		if not (item is Dictionary):
			continue
		var target: Dictionary = item
		var sp := str(target.get("source_path", ""))
		if sp == "":
			continue
		var artifact := _persist_working_recovery_artifact(gid, target)
		if artifact == "":
			failed.append({"path": sp, "reason": "WORKING_ARTIFACT_WRITE_FAILED"})
			continue
		artifacts.append(artifact)
		# P0-SAVE-03: classify the current revision before deciding anything.
		var classification := _classify_current_override(target)
		if classification == "CURRENT_IS_NEWER" or classification == "CURRENT_UNKNOWN":
			var abs_c := _save_group_target_override_abs(target, sp)
			var cur_hash := ""
			if abs_c != "" and FileAccess.file_exists(abs_c):
				cur_hash = WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(abs_c))
			conflicts.append({
				"path": sp,
				"reason": "EXTERNAL_MODIFICATION",
				"classification": classification,
				"expected_new": str(target.get("new_override_hash", "")),
				"actual": cur_hash,
			})
			continue
		# P0-SAVE-03 source drift: if the original game source changed since
		# PREPARED, the rollback decision no longer matches the world it was
		# made in; surface it as a conflict instead of silently proceeding.
		var expected_source_hash := str(target.get("source_hash", ""))
		if expected_source_hash != "":
			var cur_source := _save_group_source_bytes(sp)
			var cur_source_hash := WorkspaceStore._md5_bytes(cur_source) if not cur_source.is_empty() else ""
			if cur_source_hash != expected_source_hash:
				conflicts.append({
					"path": sp,
					"reason": "SOURCE_REVISION_DRIFT",
					"classification": "SOURCE_CHANGED",
					"expected_source": expected_source_hash,
					"actual_source": cur_source_hash,
				})
				continue
		var prev_dec := _decode_journal_payload(str(target.get("previous_override_bytes", "")),
			str(target.get("previous_override_hash", "")))
		if not bool(prev_dec.get("ok", false)):
			failed.append({"path": sp, "reason": "PREVIOUS_BYTES_HASH_MISMATCH"})
			continue
		var prev: PackedByteArray = prev_dec.get("bytes", PackedByteArray())
		# An existing EMPTY override is a legitimate previous state (its b64
		# is the empty string); only a target with NO previous bytes at all
		# (absent override whose source is gone) is unrecoverable.
		if prev.is_empty() and not bool(target.get("had_override_before", false)):
			failed.append({"path": sp, "reason": "PREVIOUS_BYTES_MISSING"})
			continue
		var had_override_before := bool(target.get("had_override_before", false))
		var abs_override := _save_group_target_override_abs(target, sp)
		var write_ok := false
		# Hold the live cached instance BEFORE any structural rollback:
		# discard_override_ex invalidates the OdfDocument cache, and without
		# this reference the in-memory refresh below would silently skip,
		# leaving the edited doc claiming a workspace override that no
		# longer exists.
		var live_doc = OdfDocument.cached(sp)
		if not had_override_before:
			# P0-SAVE-02: before the transaction there was NO override. The
			# interrupted transaction may have created one; remove exactly that
			# override and its manifest entry, restoring the pristine workspace
			# structure. Never touch anything we cannot attribute to this
			# transaction.
			if abs_override != "" and FileAccess.file_exists(abs_override):
				if classification != "CURRENT_IS_EXPECTED_ABSENT":
					# The current override bytes were classified above as
					# equal to the recorded commit or the previous state; both
					# mean the transaction created this file (no override
					# existed before). Safe to retire.
					var rm := DirAccess.remove_absolute(abs_override)
					if rm != OK:
						failed.append({"path": sp, "reason": "OVERRIDE_REMOVE_FAILED"})
						continue
					if FileAccess.file_exists(abs_override):
						failed.append({"path": sp, "reason": "OVERRIDE_REMOVE_UNVERIFIED"})
						continue
					write_ok = true
				else:
					# Save never wrote this target's override; nothing to undo.
					write_ok = true
			else:
				# The override is already absent: the intended structural
				# state exists. Only the manifest entry may need cleanup.
				write_ok = true
			if write_ok:
				var pre_entry := WorkspaceStore.entry_for(sp)
				if not pre_entry.is_empty():
					# The manifest entry belongs to the interrupted transaction
					# only if it matches what the transaction would create; the
					# previous_manifest_entry is empty when none existed before.
					var prev_entry: Dictionary = target.get("previous_manifest_entry", {})
					if prev_entry.is_empty():
						var drop := WorkspaceStore.discard_override_ex(sp)
						if not bool(drop.get("ok", false)):
							failed.append({"path": sp,
								"reason": "MANIFEST_ENTRY_REMOVE_FAILED",
								"error": str(drop.get("error", ""))})
							continue
		else:
			# P0-SAVE-02: an override existed before. Restore its exact previous
			# bytes (empty file stays empty, never "absent").
			if abs_override == "":
				failed.append({"path": sp, "reason": "OVERRIDE_PATH_UNRESOLVED"})
				continue
			var wres := WorkspaceStore.atomic_write_abs(abs_override, prev)
			if not bool(wres.get("ok", false)) or \
					WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(abs_override)) != WorkspaceStore._md5_bytes(prev):
				failed.append({"path": sp, "reason": "RESTORE_WRITE_FAILED"})
				continue
			write_ok = true
			# Restore the previous manifest metadata if it has drifted.
			var prev_entry: Dictionary = target.get("previous_manifest_entry", {})
			var cur_entry := WorkspaceStore.entry_for(sp)
			if not prev_entry.is_empty() and str(cur_entry.get("rel", "")) != str(prev_entry.get("rel", "")):
				var rrec := WorkspaceStore.record(sp, str(prev_entry.get("rel", "")),
					str(prev_entry.get("source_md5", "")), int(prev_entry.get("bytes", 0)))
				if not rrec:
					failed.append({"path": sp, "reason": "MANIFEST_RESTORE_FAILED"})
					continue
		if not write_ok:
			continue
		var d = live_doc if live_doc is OdfDocument else OdfDocument.cached(sp)
		if d is OdfDocument:
			var source_ref := _save_group_source_bytes(sp)
			var rel_after := str(WorkspaceStore.entry_for(sp).get("rel", "")) if had_override_before else ""
			d.apply_recovered_bytes(prev, source_ref, false, had_override_before,
				rel_after, "", str(target.get("encoding", "")), 1 if bool(target.get("has_bom", false)) else 0)
		restored.append(sp)
		files_restored = true

	if not conflicts.is_empty():
		return _resolve_recovery_conflict(group, gid, restored, failed, conflicts, artifacts)
	if not failed.is_empty():
		# Files that could not be restored keep the transaction pending; a
		# later attempt can retry after the underlying fault is fixed.
		group["state"] = "RECOVERY_PENDING"
		group["updated_at"] = Time.get_datetime_string_from_system()
		_write_save_journal(group)
		last_save_group = group
		last_save_recovery = {"ok": false, "state": "RECOVERY_PENDING", "restored": restored,
			"failed": failed, "conflicts": [], "working_artifacts": artifacts}
		if doc != null:
			load_document(doc)
		return {"ok": false, "status": "RECOVERY_PENDING", "group_id": gid,
			"restored": restored, "failed": failed, "conflicts": [],
			"working_artifacts": artifacts, "reason": "RECOVERY_INCOMPLETE"}

	# P1-SAVE-06: RECOVERED is only honest when the durable journal agrees.
	# File restoration alone yields FILES_RESTORED; the final verdict requires
	# a verified journal write.
	group["state"] = "RECOVERED"
	group["updated_at"] = Time.get_datetime_string_from_system()
	if _write_save_journal(group):
		last_save_group = group
		last_save_recovery = {"ok": true, "state": "RECOVERED", "restored": restored,
			"failed": [], "conflicts": [], "working_artifacts": artifacts,
			"journal_finalized": true}
		if doc != null:
			load_document(doc)
		return {"ok": true, "status": "RECOVERED", "group_id": gid,
			"restored": restored, "failed": [], "conflicts": [],
			"working_artifacts": artifacts, "journal_finalized": true}
	# Journal finalization failed: files are restored but the durable record
	# still describes an incomplete transaction. Report the honest intermediate
	# state; the next attempt is idempotent (all classifications will now be
	# CURRENT_EQUALS_PREVIOUS / CURRENT_IS_EXPECTED_ABSENT).
	group["state"] = "RECOVERY_FINALIZATION_PENDING"
	group["updated_at"] = Time.get_datetime_string_from_system()
	_write_save_journal(group)
	last_save_group = group
	last_save_recovery = {"ok": false, "state": "RECOVERY_FINALIZATION_PENDING",
		"restored": restored, "failed": [], "conflicts": [],
		"working_artifacts": artifacts, "journal_finalized": false}
	return {"ok": false, "status": "RECOVERY_FINALIZATION_PENDING", "group_id": gid,
		"restored": restored, "failed": [], "conflicts": [],
		"working_artifacts": artifacts, "journal_finalized": false,
		"reason": "JOURNAL_FINALIZATION_FAILED"}


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
	# Wave E: show the exact intended writes first; the user confirms the
	# multi-document transaction instead of a blind bulk save.
	var preview := preview_dependency_save()
	var rows: Array = preview.get("rows", [])
	if rows.is_empty():
		status_changed.emit("Save dependencies: nothing to save (no dependencies).", "muted")
		return
	if save_deps_confirm_dialog == null:
		_build_save_deps_preview_dialog()
	var dirty_only: Array[Dictionary] = []
	var has_unavailable := false
	for r in rows:
		if r is Dictionary:
			if bool((r as Dictionary).get("dirty", false)):
				dirty_only.append(r)
			if str((r as Dictionary).get("operation", "")) == "UNAVAILABLE":
				has_unavailable = true
	if dirty_only.is_empty():
		status_changed.emit("Save dependencies: no dirty documents to save.", "muted")
		return
	var conflicts := int(preview.get("conflicts", 0))
	if conflicts == 0 and not has_unavailable:
		# Ordinary safe save: nothing to warn about, proceed directly. The
		# preview dialog is reserved for flows that need a human decision.
		_execute_dependency_save()
		return
	_pending_save_preview = preview
	_refresh_save_deps_preview_tree()
	if save_deps_confirm_dialog != null:
		save_deps_confirm_dialog.popup_centered()


func _execute_dependency_save() -> void:
	var res := save_with_external_dependencies()
	var saved_arr: Array = res.get("saved", [])
	var failed_arr: Array = res.get("failed", [])
	if bool(res.get("ok", false)):
		status_changed.emit("Saved %d render ODF(s) with dependencies to isolated workspace." % saved_arr.size(), "success")
		load_document(doc)
	else:
		var rec_hint := " RECOVERY AVAILABLE" if bool(res.get("recoverable", false)) else ""
		status_changed.emit("Saved %d, failed %d dependency file(s).%s" % [saved_arr.size(), failed_arr.size(), rec_hint], "danger")
	_pending_save_preview = {}


func _build_save_deps_preview_dialog() -> void:
	save_deps_confirm_dialog = ConfirmationDialog.new()
	save_deps_confirm_dialog.title = "Dependency Save Preview"
	save_deps_confirm_dialog.size = Vector2i(760, 380)
	save_deps_confirm_dialog.ok_button_text = "Save All Listed"
	save_deps_confirm_dialog.cancel_button_text = "Cancel"
	save_deps_confirm_dialog.confirmed.connect(func(): _confirm_dependency_save())
	add_child(save_deps_confirm_dialog)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	save_deps_confirm_dialog.add_child(vb)
	save_deps_preview_tree = Tree.new()
	save_deps_preview_tree.columns = 5
	save_deps_preview_tree.set_column_title(0, "File")
	save_deps_preview_tree.set_column_title(1, "Operation")
	save_deps_preview_tree.set_column_title(2, "Workspace Override")
	save_deps_preview_tree.set_column_title(3, "Revision")
	save_deps_preview_tree.set_column_title(4, "Conflict")
	save_deps_preview_tree.column_titles_visible = true
	save_deps_preview_tree.hide_root = true
	save_deps_preview_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	save_deps_preview_tree.custom_minimum_size = Vector2(720, 240)
	vb.add_child(save_deps_preview_tree)
	save_deps_preview_info = Label.new()
	save_deps_preview_info.add_theme_color_override("font_color", Color("#C5AB6E"))
	save_deps_preview_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(save_deps_preview_info)


func _refresh_save_deps_preview_tree() -> void:
	if save_deps_preview_tree == null or _pending_save_preview.is_empty():
		return
	save_deps_preview_tree.clear()
	var root_item := save_deps_preview_tree.create_item()
	var rows: Array = _pending_save_preview.get("rows", [])
	for r in rows:
		var item := save_deps_preview_tree.create_item(root_item)
		var op := str((r as Dictionary).get("operation", ""))
		item.set_text(0, str((r as Dictionary).get("file", "")))
		item.set_text(1, op)
		item.set_text(2, "yes" if bool((r as Dictionary).get("has_override", false)) else "no")
		item.set_text(3, str((r as Dictionary).get("revision", 0)))
		item.set_text(4, str((r as Dictionary).get("conflict", "")))
	var conflicts := int(_pending_save_preview.get("conflicts", 0))
	var dirty := int(_pending_save_preview.get("dirty_count", 0))
	save_deps_preview_info.text = "%d dirty document(s), %d conflict(s). SAVE writes only the listed files; conflicts are surfaced, never silently overwritten." % [dirty, conflicts]


func _confirm_dependency_save() -> void:
	_execute_dependency_save()


## Wave E / Dependency Save Preview: the exact intended writes of the next
## Save Dependencies transaction, BEFORE any file is touched. For every
## dependency this reports the effective source package, the workspace
## override path, the planned operation and any conflict the user must know
## about. Nothing is written and no journal is created.
func preview_dependency_save() -> Dictionary:
	var rows: Array[Dictionary] = []
	var seen := {}
	var conflicts: int = 0
	var _collect = func(d):
		if d == null or str(d.source_path) == "":
			return
		var sp := str(d.source_path)
		var canon := WorkspaceStore.canonical(sp).to_lower()
		if seen.has(canon):
			return
		seen[canon] = true
		var override_abs := _save_group_override_abs(sp)
		var entry := WorkspaceStore.entry_for(sp)
		var op := "SKIP"
		if d.dirty:
			op = "SAVE"
		elif d.workspace_override:
			op = "UNCHANGED_OVERRIDE_PRESENT"
		var conflict := ""
		var current_hash := ""
		if override_abs != "" and FileAccess.file_exists(override_abs):
			current_hash = WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(override_abs))
			if d.workspace_override and not d.saved_bytes.is_empty() and \
					current_hash != WorkspaceStore._md5_bytes(d.saved_bytes):
				conflict = "OVERRIDE_MODIFIED_ON_DISK"
				op = "CONFLICT"
			elif d.workspace_override and str(d.workspace_source_md5) != "" and \
					WorkspaceStore.source_md5(sp) != str(d.workspace_source_md5):
				conflict = "SOURCE_CHANGED_SINCE_SAVE"
				op = "CONFLICT"
		if not FileAccess.file_exists(sp):
			op = "UNAVAILABLE"
			conflict = "SOURCE_MISSING"
		if op == "CONFLICT":
			conflicts += 1
		rows.append({
			"path": sp,
			"file": sp.get_file(),
			"operation": op,
			"dirty": bool(d.dirty),
			"has_override": d.workspace_override,
			"override_path": override_abs,
			"manifest_rel": str(entry.get("rel", "")),
			"override_current_hash": current_hash,
			"conflict": conflict,
			"revision": int(d.revision),
		})
	if doc != null:
		_collect.call(doc)
	for ext_key in _external_nodes:
		var ep := str((_external_nodes[ext_key] as Dictionary).get("path", ""))
		if ep == "":
			continue
		var ext_doc = OdfDocument.cached(ep)
		if ext_doc is OdfDocument:
			_collect.call(ext_doc)
	return {
		"rows": rows,
		"conflicts": conflicts,
		"dirty_count": dirty_dependency_count(),
		"workspace_root": WorkspaceStore.root(),
	}


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
func _would_cycle(src: String, dst: String, ignore_key: String = "") -> bool:
	if src.to_lower() == dst.to_lower():
		return true
	var stack: Array[String] = [dst]
	var seen := {}
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		var key := cur.to_lower()
		if seen.has(key):
			continue
		seen[key] = true
		for child_key in _child_keys(doc, cur):
			var nxt := ""
			if cur.to_lower() == src.to_lower() and child_key.to_lower() == ignore_key.to_lower():
				# Candidate edge replaces this one; exclude it from reachability.
				continue
			nxt = _reference_header(doc.get_value(cur, child_key, ""))
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
	var node := graph.get_node_or_null(NodePath(new_name.validate_node_name())) if graph != null else null
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
	var node := graph.get_node_or_null(NodePath(clean.validate_node_name())) if graph != null else null
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
