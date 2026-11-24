extends Control
## BZ_ODF_SHAMAN application shell: resource browser, structured inspector,
## raw editor, dependency explorer, weapon lab, particle lab, safe export.

const APP_TITLE := "BZ_ODF_SHAMAN"
const SETTINGS_PATH := "user://settings.json"
const GAME_ROOT := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R"
const HoudiniScrubberScript = preload("res://scripts/ui/houdini_scrubber.gd")
const ModLoadoutScript = preload("res://scripts/core/mod_loadout.gd")
const BzMeshReaderScript = preload("res://scripts/core/bz_mesh_reader.gd")
const NativeSessionServiceScript = preload("res://scripts/native/native_session_service.gd")
const UI_SCALE_PRESETS := [0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0]

var index: ResourceIndex
var schema: SchemaRegistry
var theme_engine: WintageTheme
var dep_graph := DependencyGraph.new()
var current_doc: OdfDocument
var origin_path: String = ""
var origin_rel: String = ""
var show_raw_values := false
var ui_scale: float = 1.0
var master_volume: float = 0.85
var master_muted: bool = false
var active_collection_filter: String = "all"
var active_category_filter: String = "all"

var scan_thread: Thread
var scan_requested := false
var dep_timer: Timer
var search_timer: Timer

# UI
var top_bar: HFlowContainer
var status_label: Label
var status_counts: Label
var resource_tree: Tree
var search_edit: LineEdit
var collection_filter_option: OptionButton
var category_filter_option: OptionButton
var resource_context_menu: PopupMenu
var index_label: Label
var inspector_scroll: ScrollContainer
var inspector_box: VBoxContainer
var inspector_title: Label
var inspector_chain_bar: HFlowContainer
var inspector_filter_edit: LineEdit
var inspector_property_filter: String = ""
var raw_edit: TextEdit
var dep_summary: Label
var dep_tree: Tree
var diag_text: RichTextLabel
var model_text: RichTextLabel
var doc_tabs: TabContainer
var main_hsplit: HSplitContainer
var right_hsplit: HSplitContainer
var theme_option: OptionButton
var loadout_option: OptionButton
var font_aa_option: OptionButton
var ui_scale_option: OptionButton
var mute_button: Button
var reset_ui_button: Button
var reset_all_button: Button
var recovery_history_button: Button
var reset_doc_button: Button
var volume_scrubber: HBoxContainer
var _factory_doc_cache: Dictionary = {}
var active_loadout_id: String = "3532748119"
var active_loadout_profile = null
var save_loadout_button: Button
var live_swap_option: OptionButton
var live_swap_mode: String = "off"  # off, shooter, target, auto_lab
var reset_all_dialog: ConfirmationDialog
var reset_doc_dialog: ConfirmationDialog
var recovery_history_dialog: AcceptDialog
var recovery_history_tree: Tree
var recovery_history_info: Label
var _recovery_history_rows: Array[Dictionary] = []
var save_group_recovery_button: Button
var recovery_center_dialog: AcceptDialog
var recovery_center_tree: Tree
var recovery_center_info: Label
var _recovery_center_rows: Array[Dictionary] = []
var last_recovery_center_scan: Dictionary = {}
var recovery_confirm_dialog: ConfirmationDialog
var pending_recovery_action: Dictionary = {}
var reset_all_confirmation_pending := false
var reset_doc_confirmation_pending := false
var _reset_impact_rev: int = 0
var _pending_reset_all_snapshot: Dictionary = {}
var _pending_reset_doc_snapshot: Dictionary = {}
var _pending_project_config_reset := false
var last_reset_impact_preview: Dictionary = {}
var last_reset_all_report: Dictionary = {}
var last_reset_doc_result: Dictionary = {}
var last_recovery_restore_result: Dictionary = {}
var last_property_reset_info: Dictionary = {}
var actor_picker_dialog: AcceptDialog
var actor_picker_role: String = "shooter"
var actor_picker_search: LineEdit
var actor_picker_coll: OptionButton
var actor_picker_cat: OptionButton
var actor_picker_tree: Tree
var weapon_lab: WeaponLab
var particle_lab: ParticleLab
var audio_lab: AudioLab
var native_session_service = null
var open_dialog: FileDialog
var export_dialog: FileDialog
var overwrite_dialog: ConfirmationDialog
var overwrite_target := ""
var revert_dialog: ConfirmationDialog

var shooter_path := ""
var target_path := ""
var last_document_path := ""
var restored_overrides := 0
## Last staged export location and whether its report file was written.
var export_last_stage := ""
var export_last_report_ok := false


func _ready() -> void:
	schema = SchemaRegistry.new()
	schema.load_schemas()
	theme_engine = WintageTheme.new()
	theme_engine.load_themes()
	index = ResourceIndex.new()
	native_session_service = NativeSessionServiceScript.new()
	native_session_service.name = "NativeSessionService"
	add_child(native_session_service)
	native_session_service.recover_pending_sessions()
	_build_ui()
	_apply_theme("goldendefault")
	apply_master_volume(master_volume, master_muted)
	_load_settings()
	restored_overrides = WorkspaceStore.restore_cache()
	dep_timer = Timer.new()
	dep_timer.one_shot = true
	dep_timer.wait_time = 0.35
	dep_timer.timeout.connect(_refresh_dependencies)
	add_child(dep_timer)
	search_timer = Timer.new()
	search_timer.one_shot = true
	search_timer.wait_time = 0.18
	search_timer.timeout.connect(_populate_resources)
	add_child(search_timer)
	_set_status("Ready. Indexing resources in background…", "muted")
	_start_index_scan()
	if schema.loaded:
		index_label.text = schema.source_note
	scan_requested = true


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_panel := Panel.new()
	bg_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg_panel)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 3)
	add_child(root)

	# Top bar
	top_bar = HFlowContainer.new()
	top_bar.add_theme_constant_override("h_separation", 6)
	top_bar.add_theme_constant_override("v_separation", 3)
	root.add_child(top_bar)
	var title := Label.new()
	title.text = APP_TITLE
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color("#F0D060"))
	top_bar.add_child(title)
	var sub := Label.new()
	sub.text = "ODF authoring · sim · validation"
	sub.add_theme_color_override("font_color", Color("#9C9371"))
	top_bar.add_child(sub)
	top_bar.add_child(_top_button("Open...", _on_open_pressed, "Open ODF (Ctrl+O)"))
	top_bar.add_child(_top_button("Save", _on_save_pressed, "Save current ODF to workspace (Ctrl+S)"))
	top_bar.add_child(_top_button("Save all", save_all_edited, "Save every dirty document to workspace"))
	reset_all_button = _top_button("Reset All", request_reset_all_odfs, "Preview impact and confirm reverting all modified/overridden ODFs back to factory defaults")
	top_bar.add_child(reset_all_button)
	recovery_history_button = _top_button("Recovery", func(): open_recovery_history(), "Inspect and restore Reset Recovery Points (saved overrides & unsaved working revisions)")
	top_bar.add_child(recovery_history_button)
	save_group_recovery_button = _top_button("Recovery Center", func(): open_save_group_recovery_center(), "Discover interrupted Save Dependencies transactions and native cleanup intents; inspect, recover or resolve them safely")
	top_bar.add_child(save_group_recovery_button)
	top_bar.add_child(_top_button("Export...", _on_export_pressed, "Export staged overrides (dry-run report first)"))
	top_bar.add_child(_top_button("VSR test", _load_reference_scenario, "Load gatstabvsr / ivtank_vsr / ivscav_vsr"))
	top_bar.add_child(_top_button("Rescan", rescan_index, "Re-index roots without restarting"))
	top_bar.add_child(_top_button("Undo", _undo, "Ctrl+Z"))
	top_bar.add_child(_top_button("Redo", _redo, "Ctrl+Y"))

	var loadout_lbl := Label.new()
	loadout_lbl.text = "Loadout"
	top_bar.add_child(loadout_lbl)
	loadout_option = OptionButton.new()
	loadout_option.tooltip_text = "Active Workshop package priority for resolving duplicate ODFs across Inspector, Labs, Export & Native"
	for lp in [["VSR (3532748119)", "3532748119"], ["VSR Legacy (1325933293)", "1325933293"], ["VRV (3820486276)", "3820486276"], ["Stock Only (Base Game)", "stock"], ["Auto / All Mods", "auto"]]:
		loadout_option.add_item(str(lp[0]))
		loadout_option.set_item_metadata(loadout_option.item_count - 1, str(lp[1]))
	loadout_option.item_selected.connect(_on_loadout_selected)
	top_bar.add_child(loadout_option)
	save_loadout_button = _top_button("Save Loadout", func():
		var pid := "profile_" + (active_loadout_id if active_loadout_id != "" else "custom")
		save_loadout_profile(pid)
	, "Save current ModLoadout profile (packages, priority, explicit winners, workspace overrides, source hashes) to workspace/loadouts/")
	top_bar.add_child(save_loadout_button)
	index.set_active_package("3532748119")
	_refresh_loadout_option_profiles()
	var theme_label := Label.new()
	theme_label.text = "Theme"
	top_bar.add_child(theme_label)
	theme_option = OptionButton.new()
	theme_option.custom_minimum_size = Vector2(132, 0)
	theme_option.item_selected.connect(_on_theme_selected)
	top_bar.add_child(theme_option)

	var aa_label := Label.new()
	aa_label.text = "Font"
	top_bar.add_child(aa_label)
	font_aa_option = OptionButton.new()
	font_aa_option.tooltip_text = "Font antialiasing (No-AA default for crisp Win95 Verdana)"
	for pair in [["No-AA", "none"], ["Gray AA", "gray"], ["LCD AA", "lcd"]]:
		font_aa_option.add_item(str(pair[0]))
		font_aa_option.set_item_metadata(font_aa_option.item_count - 1, str(pair[1]))
	font_aa_option.item_selected.connect(_on_font_aa_selected)
	top_bar.add_child(font_aa_option)

	var scale_label := Label.new()
	scale_label.text = "UI"
	top_bar.add_child(scale_label)
	ui_scale_option = OptionButton.new()
	ui_scale_option.tooltip_text = "UI scale (Ctrl+ / Ctrl- / Ctrl+0)"
	for sc in UI_SCALE_PRESETS:
		ui_scale_option.add_item("%d%%" % int(round(sc * 100.0)))
		ui_scale_option.set_item_metadata(ui_scale_option.item_count - 1, sc)
		if absf(sc - 1.0) < 0.01:
			ui_scale_option.select(ui_scale_option.item_count - 1)
	ui_scale_option.item_selected.connect(_on_ui_scale_selected)
	top_bar.add_child(ui_scale_option)

	mute_button = Button.new()
	mute_button.text = "Vol"
	mute_button.toggle_mode = true
	mute_button.focus_mode = Control.FOCUS_NONE
	mute_button.tooltip_text = "Mute / unmute all application audio"
	mute_button.toggled.connect(func(muted: bool):
		apply_master_volume(master_volume, muted)
		_save_settings()
	)
	top_bar.add_child(mute_button)
	volume_scrubber = HoudiniScrubberScript.new()
	volume_scrubber.configure(0.0, 100.0, 1.0, master_volume * 100.0, "%", true, false, true)
	volume_scrubber.set_default_value(85.0)
	volume_scrubber.set_pill_width(48)
	volume_scrubber.custom_minimum_size = Vector2(120, 0)
	volume_scrubber.tooltip_text = "Master audio volume (slide, LMB drag, MMB Value Ladder, RMB reset to 85%)"
	volume_scrubber.value_changed.connect(func(v: float):
		apply_master_volume(clampf(v / 100.0, 0.0, 1.0), master_muted)
		_save_settings()
	)
	top_bar.add_child(volume_scrubber)
	reset_ui_button = _top_button("Reset UI", reset_ui_to_default, "Reset Theme (Golden Default), Font (No-AA), UI Scale (100%), and Volume (85%) to defaults")
	top_bar.add_child(reset_ui_button)

	# Three-pane main split — visible 8px grabbers and low min widths so every pane resizes smoothly.
	main_hsplit = HSplitContainer.new()
	main_hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hsplit.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
	root.add_child(main_hsplit)

	# Left: categorized resources
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(160, 0)
	left.clip_contents = true
	main_hsplit.add_child(left)
	var res_title := Label.new()
	res_title.text = "RESOURCE EXPLORER"
	res_title.add_theme_color_override("font_color", Color("#D3B57A"))
	left.add_child(res_title)

	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 4)
	left.add_child(filter_row)
	collection_filter_option = OptionButton.new()
	collection_filter_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collection_filter_option.tooltip_text = "Filter by mod collection (Stock, VSR, VRV, Workshop Mods, Addon)"
	for cp in [["All Mods", "all"], ["Stock (BZ2R)", "stock"], ["VSR", "vsr"], ["VRV", "vrv"], ["Workshop Mods", "mods"], ["Addon", "addon"]]:
		collection_filter_option.add_item(str(cp[0]))
		collection_filter_option.set_item_metadata(collection_filter_option.item_count - 1, str(cp[1]))
	collection_filter_option.item_selected.connect(func(i: int):
		active_collection_filter = str(collection_filter_option.get_item_metadata(i))
		_populate_resources()
	)
	filter_row.add_child(collection_filter_option)
	category_filter_option = OptionButton.new()
	category_filter_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	category_filter_option.tooltip_text = "Filter by ODF category"
	for cat_p in [["All Types", "all"], ["Vehicles", "vehicles"], ["Weapons", "weapons"], ["Ordnance", "ordnance"], ["Explosions / FX", "explosions / fx"], ["Buildings", "buildings"], ["Pilots & Props", "pilots & props"], ["Other", "other"]]:
		category_filter_option.add_item(str(cat_p[0]))
		category_filter_option.set_item_metadata(category_filter_option.item_count - 1, str(cat_p[1]))
	category_filter_option.item_selected.connect(func(i: int):
		active_category_filter = str(category_filter_option.get_item_metadata(i))
		_populate_resources()
	)
	filter_row.add_child(category_filter_option)

	search_edit = LineEdit.new()
	search_edit.placeholder_text = "Search ODFs (fuzzy name or fragment…)"
	search_edit.text_changed.connect(func(_t): search_timer.start())
	left.add_child(search_edit)
	index_label = Label.new()
	index_label.text = "Not indexed"
	index_label.clip_text = true
	index_label.add_theme_color_override("font_color", Color("#95804C"))
	left.add_child(index_label)
	resource_tree = Tree.new()
	resource_tree.columns = 2
	resource_tree.set_column_title(0, "ODF / Category")
	resource_tree.set_column_title(1, "In-Game Name / Info")
	resource_tree.column_titles_visible = true
	resource_tree.hide_root = true
	resource_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	resource_tree.item_selected.connect(_on_resource_selected)
	resource_tree.item_activated.connect(_on_resource_activated)
	resource_tree.gui_input.connect(_on_resource_tree_input)
	left.add_child(resource_tree)
	var left_buttons := HFlowContainer.new()
	left_buttons.add_theme_constant_override("h_separation", 4)
	left_buttons.add_theme_constant_override("v_separation", 3)
	left.add_child(left_buttons)
	left_buttons.add_child(_top_button("Set A (Shooter)", _use_selection_as_shooter, "Assign selected ODF as Object A (Shooter)"))
	left_buttons.add_child(_top_button("Set B (Target)", _use_selection_as_target, "Assign selected ODF as Object B (Target)"))
	left_buttons.add_child(_top_button("Send to Lab", _send_selection_to_lab, "Route selected ODF to Weapons Lab or Particle Lab automatically"))
	var swap_lbl := Label.new()
	swap_lbl.text = "Live-Swap"
	left_buttons.add_child(swap_lbl)
	live_swap_option = OptionButton.new()
	live_swap_option.tooltip_text = "Automatically swap Object A, Object B, Weapon on A, or active Lab preview while browsing ODFs (Right-Click to turn Off)"
	for lsp in [["Off", "off"], ["Object A (Shooter)", "shooter"], ["Object B (Target)", "target"], ["Weapon (on A)", "weapon"], ["Auto (A/Wpn/FX)", "auto_lab"]]:
		live_swap_option.add_item(str(lsp[0]))
		live_swap_option.set_item_metadata(live_swap_option.item_count - 1, str(lsp[1]))
	live_swap_option.item_selected.connect(func(idx: int):
		set_live_swap_mode(str(live_swap_option.get_item_metadata(idx)))
	)
	live_swap_option.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT and (ev as InputEventMouseButton).pressed:
			set_live_swap_mode("off")
			live_swap_option.accept_event()
	)
	left_buttons.add_child(live_swap_option)

	resource_context_menu = PopupMenu.new()
	resource_context_menu.add_item("Open in Inspector", 0)
	resource_context_menu.add_item("Set as Object A (Shooter)", 1)
	resource_context_menu.add_item("Set as Object B (Target)", 2)
	resource_context_menu.add_item("Send to Active Lab", 3)
	resource_context_menu.id_pressed.connect(func(id: int):
		match id:
			0: _on_resource_activated()
			1: _use_selection_as_shooter()
			2: _use_selection_as_target()
			3: _send_selection_to_lab()
	)
	add_child(resource_context_menu)

	# Center + right
	right_hsplit = HSplitContainer.new()
	right_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_hsplit.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
	main_hsplit.add_child(right_hsplit)
	doc_tabs = TabContainer.new()
	doc_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	doc_tabs.custom_minimum_size = Vector2(200, 0)
	doc_tabs.clip_contents = true
	doc_tabs.tab_changed.connect(func(tab_idx: int):
		if tab_idx == 1 and particle_lab != null:
			particle_lab.bind_context_document(current_doc, weapon_lab.profile if weapon_lab != null else null)
	)
	right_hsplit.add_child(doc_tabs)
	weapon_lab = WeaponLab.new()
	weapon_lab.name = "Weapons Lab"
	weapon_lab.setup(index, schema, native_session_service)
	weapon_lab.status_changed.connect(_set_status)
	weapon_lab.scenario_loaded.connect(_on_scenario_loaded)
	weapon_lab.timeline_event_selected.connect(_on_timeline_event_selected)
	weapon_lab.pick_actor_requested.connect(open_actor_picker)
	weapon_lab.inspect_path_requested.connect(open_document)
	weapon_lab.particle_graph_requested.connect(_open_particle_graph)
	weapon_lab.show_timeline_shot_requested.connect(_show_weapon_lab_shot)
	doc_tabs.add_child(weapon_lab)
	particle_lab = ParticleLab.new()
	particle_lab.name = "Particle Lab"
	particle_lab.setup(index, schema)
	particle_lab.status_changed.connect(_set_status)
	particle_lab.header_selected.connect(_on_render_header_selected)
	particle_lab.document_edited.connect(_on_particle_edited)
	particle_lab.open_path_requested.connect(open_document)
	doc_tabs.add_child(particle_lab)
	audio_lab = AudioLab.new()
	audio_lab.name = "Audio Lab"
	audio_lab.setup(index)
	audio_lab.status_changed.connect(_set_status)
	doc_tabs.add_child(audio_lab)
	var model_tab := _build_model_tab()
	model_tab.name = "Model Inspector"
	doc_tabs.add_child(model_tab)
	var docs_tab := _build_docs_tab()
	docs_tab.name = "Docs"
	doc_tabs.add_child(docs_tab)

	# Right: inspector / raw / deps
	var right := TabContainer.new()
	right.custom_minimum_size = Vector2(180, 0)
	right.clip_contents = true
	right_hsplit.add_child(right)

	var inspector_root := VBoxContainer.new()
	inspector_root.name = "Inspector"
	right.add_child(inspector_root)
	inspector_title = Label.new()
	inspector_title.text = "No document open"
	inspector_title.clip_text = true
	inspector_title.add_theme_color_override("font_color", Color("#F0D060"))
	inspector_root.add_child(inspector_title)

	# E2E Chain Breadcrumb Strip: 1-click navigation between Shooter A -> Weapon -> Ordnance -> Explosion -> Target B.
	inspector_chain_bar = HFlowContainer.new()
	inspector_chain_bar.add_theme_constant_override("h_separation", 4)
	inspector_chain_bar.add_theme_constant_override("v_separation", 2)
	inspector_root.add_child(inspector_chain_bar)

	var insp_toolbar := HBoxContainer.new()
	insp_toolbar.add_theme_constant_override("separation", 4)
	inspector_root.add_child(insp_toolbar)
	inspector_filter_edit = LineEdit.new()
	inspector_filter_edit.placeholder_text = "Filter properties (e.g. damage, speed, health)..."
	inspector_filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_filter_edit.text_changed.connect(func(txt: String):
		inspector_property_filter = txt.strip_edges().to_lower()
		_rebuild_inspector()
	)
	insp_toolbar.add_child(inspector_filter_edit)
	reset_doc_button = _top_button("Reset ODF", request_reset_current_doc, "Preview impact and confirm reverting current ODF back to its factory on-disk defaults")
	insp_toolbar.add_child(reset_doc_button)
	var raw_toggle := CheckButton.new()
	raw_toggle.text = "Raw"
	raw_toggle.tooltip_text = "Show exact raw ODF text values"
	raw_toggle.toggled.connect(func(on):
		show_raw_values = on
		_rebuild_inspector()
	)
	insp_toolbar.add_child(raw_toggle)
	inspector_scroll = ScrollContainer.new()
	inspector_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inspector_root.add_child(inspector_scroll)
	inspector_box = VBoxContainer.new()
	inspector_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_box.add_theme_constant_override("separation", 2)
	inspector_scroll.add_child(inspector_box)

	var raw_root := VBoxContainer.new()
	raw_root.name = "Raw ODF"
	right.add_child(raw_root)
	var raw_bar := HBoxContainer.new()
	raw_root.add_child(raw_bar)
	raw_bar.add_child(_top_button("Apply parsed text", _apply_raw_editor))
	raw_bar.add_child(_top_button("Discard unsaved", _reload_saved_revision))
	raw_bar.add_child(_top_button("Revert override…", _ask_revert_original))
	raw_bar.add_child(_top_button("Overwrite original…", _ask_overwrite_original))
	raw_edit = TextEdit.new()
	raw_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	raw_edit.custom_minimum_size = Vector2(0, 300)
	raw_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	raw_edit.add_theme_font_size_override("font_size", 12)
	raw_root.add_child(raw_edit)

	var deps_root := VBoxContainer.new()
	deps_root.name = "Dependencies"
	right.add_child(deps_root)
	dep_summary = Label.new()
	dep_summary.text = "Open a document to resolve references."
	dep_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	deps_root.add_child(dep_summary)
	dep_tree = Tree.new()
	dep_tree.columns = 3
	dep_tree.set_column_title(0, "Property")
	dep_tree.set_column_title(1, "Reference")
	dep_tree.set_column_title(2, "Resolution")
	dep_tree.column_titles_visible = true
	dep_tree.hide_root = true
	dep_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dep_tree.item_activated.connect(_on_dep_activated)
	deps_root.add_child(dep_tree)

	var diag_root := VBoxContainer.new()
	diag_root.name = "Diagnostics"
	right.add_child(diag_root)
	diag_text = RichTextLabel.new()
	diag_text.bbcode_enabled = true
	diag_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	diag_text.selection_enabled = true
	diag_root.add_child(diag_text)

	# Status bar
	var status_bar := HBoxContainer.new()
	root.add_child(status_bar)
	status_label = Label.new()
	status_label.text = "Starting…"
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.clip_text = true
	status_bar.add_child(status_label)
	status_counts = Label.new()
	status_counts.text = "fidelity: APPROXIMATED"
	status_counts.add_theme_color_override("font_color", Color("#969630"))
	status_bar.add_child(status_counts)

	open_dialog = FileDialog.new()
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.filters = PackedStringArray(["*.odf ; ODF files"])
	open_dialog.title = "Open ODF"
	open_dialog.current_dir = GAME_ROOT
	open_dialog.size = Vector2i(900, 620)
	open_dialog.file_selected.connect(open_document)
	add_child(open_dialog)
	export_dialog = FileDialog.new()
	export_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title = "Choose export directory (dry-run report is written first)"
	export_dialog.dir_selected.connect(_on_export_dir_selected)
	export_dialog.size = Vector2i(900, 620)
	add_child(export_dialog)
	overwrite_dialog = ConfirmationDialog.new()
	overwrite_dialog.title = "Overwrite original ODF?"
	overwrite_dialog.dialog_text = "This writes directly to the original game/mod resource.\nIt is blocked unless you explicitly confirm.\n\n"
	overwrite_dialog.confirmed.connect(_do_overwrite_original)
	add_child(overwrite_dialog)
	revert_dialog = ConfirmationDialog.new()
	revert_dialog.title = "Remove workspace override?"
	revert_dialog.dialog_text = "Deletes the saved workspace override and reloads the untouched original game/mod resource.\nUnsaved in-memory edits are also discarded.\n\nUse 'Discard unsaved' instead if you only want the last saved revision."
	revert_dialog.confirmed.connect(_do_revert_original)
	add_child(revert_dialog)
	reset_all_dialog = ConfirmationDialog.new()
	reset_all_dialog.title = "Confirm Reset All Workspace Overrides"
	reset_all_dialog.ok_button_text = "Create Recovery Point & Reset All"
	reset_all_dialog.confirmed.connect(func(): confirm_reset_all_odfs())
	reset_all_dialog.canceled.connect(func(): cancel_reset_all_odfs())
	add_child(reset_all_dialog)
	reset_doc_dialog = ConfirmationDialog.new()
	reset_doc_dialog.title = "Confirm Reset Current ODF"
	reset_doc_dialog.ok_button_text = "Reset ODF to Factory Default"
	reset_doc_dialog.confirmed.connect(func(): confirm_reset_current_doc())
	reset_doc_dialog.canceled.connect(func(): cancel_reset_current_doc())
	add_child(reset_doc_dialog)
	_build_recovery_history_dialog()
	_build_recovery_center_dialog()
	_scan_startup_recovery()
	_build_actor_picker_dialog()
	_populate_theme_option()
	# Initial comfortable split proportions (user can drag freely anywhere).
	main_hsplit.split_offset = 100
	right_hsplit.split_offset = -160


func _build_recovery_history_dialog() -> void:
	recovery_history_dialog = AcceptDialog.new()
	recovery_history_dialog.title = "Reset Recovery History"
	recovery_history_dialog.size = Vector2i(820, 480)
	recovery_history_dialog.ok_button_text = "Close"
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	recovery_history_dialog.add_child(vb)
	recovery_history_info = Label.new()
	recovery_history_info.text = "Select a Reset Recovery Point to restore saved workspace overrides and/or unsaved working revisions."
	recovery_history_info.add_theme_color_override("font_color", Color("#C5AB6E"))
	recovery_history_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(recovery_history_info)
	recovery_history_tree = Tree.new()
	recovery_history_tree.columns = 6
	recovery_history_tree.set_column_title(0, "Timestamp")
	recovery_history_tree.set_column_title(1, "Scope")
	recovery_history_tree.set_column_title(2, "Documents")
	recovery_history_tree.set_column_title(3, "Saved Override")
	recovery_history_tree.set_column_title(4, "Working Rev")
	recovery_history_tree.set_column_title(5, "Integrity")
	recovery_history_tree.column_titles_visible = true
	recovery_history_tree.hide_root = true
	recovery_history_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	recovery_history_tree.custom_minimum_size = Vector2(760, 310)
	vb.add_child(recovery_history_tree)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	vb.add_child(btn_row)
	btn_row.add_child(_top_button("Restore Working + Saved", func(): _restore_selected_recovery_point("full"), "Restore both saved workspace override and unsaved dirty working bytes from the selected recovery point"))
	btn_row.add_child(_top_button("Restore Saved Only", func(): _restore_selected_recovery_point("saved_only"), "Restore only the saved workspace override (discarding unsaved working edits)"))
	btn_row.add_child(_top_button("Restore Working Only", func(): _restore_selected_recovery_point("working_only"), "Restore only the unsaved working revision into memory as a dirty document"))
	btn_row.add_child(_top_button("Refresh", func(): _refresh_recovery_history_tree(), "Reload and re-verify recovery point hashes from disk"))
	add_child(recovery_history_dialog)


func list_recovery_history() -> Array[Dictionary]:
	_recovery_history_rows = WorkspaceStore.list_reset_recovery_points()
	return _recovery_history_rows.duplicate(true)


func _refresh_recovery_history_tree() -> int:
	_recovery_history_rows = WorkspaceStore.list_reset_recovery_points()
	if recovery_history_tree == null:
		return _recovery_history_rows.size()
	recovery_history_tree.clear()
	var root := recovery_history_tree.create_item()
	for i in _recovery_history_rows.size():
		var row: Dictionary = _recovery_history_rows[i]
		var item := recovery_history_tree.create_item(root)
		var docs: Array = row.get("documents", [])
		var doc_names: Array[String] = []
		for dp in docs:
			doc_names.append(str(dp).get_file())
		item.set_text(0, str(row.get("created_at", "")))
		item.set_text(1, str(row.get("scope", "RESET")))
		item.set_text(2, "%d: %s" % [docs.size(), ", ".join(doc_names).substr(0, 60)])
		item.set_text(3, "YES" if bool(row.get("has_saved_override", false)) else "no")
		item.set_text(4, "YES" if bool(row.get("has_working_revision", false)) else "no")
		var vstat := str(row.get("verification_status", "UNKNOWN"))
		item.set_text(5, vstat)
		if vstat == "VERIFIED":
			item.set_custom_color(5, Color("#81B681"))
		else:
			item.set_custom_color(5, Color("#E06C6C"))
		item.set_tooltip_text(0, "%s\n%s" % [str(row.get("transaction_id", "")), str(row.get("path", ""))])
		item.set_metadata(0, str(row.get("path", "")))
	if recovery_history_info != null:
		if _recovery_history_rows.is_empty():
			recovery_history_info.text = "No reset recovery points recorded in this workspace yet."
		else:
			recovery_history_info.text = "%d reset recovery point(s) found. Select one and choose a Restore action." % _recovery_history_rows.size()
	return _recovery_history_rows.size()


func open_recovery_history() -> int:
	var count := _refresh_recovery_history_tree()
	if recovery_history_dialog != null and is_inside_tree():
		recovery_history_dialog.popup_centered()
	return count


func _restore_selected_recovery_point(mode: String = "full") -> Dictionary:
	if recovery_history_tree == null:
		return {"ok": false, "status": "NO_SELECTION"}
	var sel := recovery_history_tree.get_selected()
	if sel == null:
		_set_status("Recovery History: select a recovery point first.", "warning")
		return {"ok": false, "status": "NO_SELECTION"}
	var tx_path := str(sel.get_metadata(0))
	return restore_recovery_point_ui(tx_path, mode)


func restore_recovery_point_ui(tx_path: String, mode: String = "full") -> Dictionary:
	var res := WorkspaceStore.restore_reset_recovery_point(tx_path, mode)
	last_recovery_restore_result = res
	var restored_list: Array = res.get("restored", [])
	var open_target := ""
	if current_doc != null and current_doc.source_path != "":
		open_target = current_doc.source_path
	elif not restored_list.is_empty():
		open_target = str(restored_list[0])
	if open_target != "" and (OdfDocument.cached(open_target) != null or FileAccess.file_exists(open_target)):
		open_document(open_target)
	if weapon_lab != null and shooter_path != "" and target_path != "":
		weapon_lab.reload_after_raw_edit()
	if particle_lab != null and particle_lab.doc != null:
		particle_lab.load_document(particle_lab.doc)
	if audio_lab != null and current_doc != null:
		audio_lab.set_document(current_doc)
	_refresh_recovery_history_tree()
	if bool(res.get("ok", false)):
		_set_status("Recovery restored %d file(s) [%s]." % [restored_list.size(), str(res.get("outcome", res.get("status", "RESTORED")))], "success")
	else:
		_set_status("Recovery reported %s (%d restored, %d failed)." % [
			str(res.get("status", "FAILED")), restored_list.size(), (res.get("failed", []) as Array).size()
		], "danger")
	return res


## T-86 / Wave E: build the Recovery Center dialog. Startup transaction
## discovery is read-only; every destructive action stays a deliberate,
## confirmed user choice routed through the audited recovery entrypoints.
func _build_recovery_center_dialog() -> void:
	recovery_center_dialog = AcceptDialog.new()
	recovery_center_dialog.title = "Recovery Center"
	recovery_center_dialog.size = Vector2i(940, 520)
	recovery_center_dialog.ok_button_text = "Close"
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	recovery_center_dialog.add_child(vb)
	recovery_center_info = Label.new()
	recovery_center_info.text = "Interrupted Save Dependencies transactions and incomplete native cleanup intents discovered from durable records on disk."
	recovery_center_info.add_theme_color_override("font_color", Color("#C5AB6E"))
	recovery_center_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(recovery_center_info)
	recovery_center_tree = Tree.new()
	recovery_center_tree.columns = 6
	recovery_center_tree.set_column_title(0, "Kind")
	recovery_center_tree.set_column_title(1, "ID / State")
	recovery_center_tree.set_column_title(2, "Affected files")
	recovery_center_tree.set_column_title(3, "Conflicts")
	recovery_center_tree.set_column_title(4, "Created")
	recovery_center_tree.set_column_title(5, "Resolution")
	recovery_center_tree.column_titles_visible = true
	recovery_center_tree.hide_root = true
	recovery_center_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	recovery_center_tree.custom_minimum_size = Vector2(880, 330)
	vb.add_child(recovery_center_tree)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	vb.add_child(btn_row)
	var recover_btn := Button.new()
	recover_btn.text = "Recover Selected Group"
	recover_btn.tooltip_text = "Roll the selected interrupted Save Dependencies transaction back to its pre-save state (byte-verified, conflict-checked)."
	recover_btn.pressed.connect(func(): _request_recovery_action("RECOVER"))
	btn_row.add_child(recover_btn)
	var keep_btn := Button.new()
	keep_btn.text = "Resolve Conflict: Keep Current"
	keep_btn.tooltip_text = "For a pending conflict group: keep the files as they are on disk now."
	keep_btn.pressed.connect(func(): _request_recovery_action("KEEP CURRENT"))
	btn_row.add_child(keep_btn)
	var work_btn := Button.new()
	work_btn.text = "Resolve Conflict: Restore Working"
	work_btn.tooltip_text = "For a pending conflict group: restore the preserved working revision from the recovery artifact."
	work_btn.pressed.connect(func(): _request_recovery_action("RESTORE WORKING"))
	btn_row.add_child(work_btn)
	var rescan_btn := Button.new()
	rescan_btn.text = "Rescan"
	rescan_btn.pressed.connect(func(): _refresh_recovery_center_tree())
	btn_row.add_child(rescan_btn)
	add_child(recovery_center_dialog)

	# UIREC-01..06: destructive recovery actions never fire directly from a
	# button. A confirmation shows the exact files, revisions and operation,
	# then revalidates the journal immediately before mutation.
	recovery_confirm_dialog = ConfirmationDialog.new()
	recovery_confirm_dialog.title = "Confirm Recovery Action"
	recovery_confirm_dialog.ok_button_text = "Confirm"
	recovery_confirm_dialog.cancel_button_text = "Cancel"
	add_child(recovery_confirm_dialog)
	recovery_confirm_dialog.confirmed.connect(_confirm_recovery_action)


## Read-only startup scan: incomplete save-group journals + incomplete native
## cleanup intents. Never mutates anything; only surfaces what durable
## records say so the user can decide.
func scan_recovery_center() -> Dictionary:
	var groups: Array[Dictionary] = []
	if particle_lab != null:
		groups = particle_lab.discover_incomplete_save_groups()
	var intents: Array[Dictionary] = []
	if native_session_service != null and native_session_service.runner != null:
		intents = native_session_service.runner.discover_cleanup_intents()
	return {
		"save_groups": groups,
		"cleanup_intents": intents,
		"count": groups.size() + intents.size(),
	}


func _scan_startup_recovery() -> void:
	last_recovery_center_scan = scan_recovery_center()
	var n := int(last_recovery_center_scan.get("count", 0))
	if n > 0:
		_set_status("Recovery Center: %d interrupted transaction(s) discovered. Open Recovery Center to inspect." % n, "warning")
		save_group_recovery_button.text = "Recovery Center (%d)" % n
	else:
		save_group_recovery_button.text = "Recovery Center"


func open_save_group_recovery_center() -> void:
	_refresh_recovery_center_tree()
	if recovery_center_dialog != null and is_inside_tree():
		recovery_center_dialog.popup_centered()


func _refresh_recovery_center_tree() -> void:
	if recovery_center_tree == null:
		return
	last_recovery_center_scan = scan_recovery_center()
	recovery_center_tree.clear()
	var root_item := recovery_center_tree.create_item()
	var groups: Array[Dictionary] = last_recovery_center_scan.get("save_groups", [])
	var intents: Array[Dictionary] = last_recovery_center_scan.get("cleanup_intents", [])
	recovery_center_info.text = "%d interrupted Save Dependencies transaction(s), %d incomplete native cleanup intent(s)." % [
		groups.size(), intents.size()]
	for g in groups:
		var item := recovery_center_tree.create_item(root_item)
		item.set_text(0, "SAVE GROUP")
		item.set_text(1, "%s\n%s" % [str(g.get("group_id", "")), str(g.get("state", ""))])
		var targets: Array = g.get("targets", [])
		item.set_text(2, str(targets.size()))
		item.set_text(3, str(g.get("conflict_resolution", {}).get("failed", []).size() if (g.get("conflict_resolution", {}) as Dictionary).has("failed") else 0))
		item.set_text(4, str(g.get("created_at", "")))
		item.set_text(5, "Recover / Resolve")
		item.set_metadata(0, {"kind": "save_group", "group": g})
	for it in intents:
		var item2 := recovery_center_tree.create_item(root_item)
		item2.set_text(0, "CLEANUP INTENT")
		item2.set_text(1, "%s\n%s" % [str(it.get("session_id", "")), str(it.get("intent_state", ""))])
		item2.set_text(2, str(it.get("remaining_owned_files", 0)))
		item2.set_text(3, str((it.get("unknown_files", []) as Array).size()))
		item2.set_text(4, str(it.get("intent_file", "")))
		item2.set_text(5, str(it.get("resolution", "UNKNOWN")))
		item2.set_metadata(0, {"kind": "cleanup_intent", "intent": it})
	var n := int(last_recovery_center_scan.get("count", 0))
	save_group_recovery_button.text = "Recovery Center (%d)" % n if n > 0 else "Recovery Center"


func _selected_recovery_row() -> Dictionary:
	if recovery_center_tree == null:
		return {}
	var sel := recovery_center_tree.get_selected()
	if sel == null:
		_set_status("Recovery Center: select a row first.", "warning")
		return {}
	return sel.get_metadata(0)


## UIREC-01: render an explicit preview of files, revisions and operation,
## distinguishing INSPECT / RECOVER / KEEP CURRENT / RESTORE WORKING.
func _preview_recovery_action(group: Dictionary, action: String) -> String:
	var targets: Array = group.get("targets", [])
	var lines: Array[String] = []
	lines.append("=== EFFECTIVE VALUE DIFF ===")
	lines.append("Operation: " + action)
	lines.append("Group: %s  State: %s" % [str(group.get("group_id", "")), str(group.get("state", ""))])
	lines.append("Affected files (%d):" % targets.size())
	for item in targets:
		if not (item is Dictionary):
			lines.append("  ! INVALID TARGET (journal will be refused)")
			continue
		var t: Dictionary = item
		lines.append("  %s" % str(t.get("source_path", "")))
		lines.append("    previous hash: %s" % str(t.get("previous_override_hash", "")))
		lines.append("    recorded commit: %s" % str(t.get("new_override_hash", "")))
		var diff: Dictionary = particle_lab.compare_journal_target_revision(t)
		if not diff.is_empty() and str(diff.get("error", "")) == "":
			var changes: Array = diff.get("changed_properties", [])
			lines.append("    effective diff: %d changed property/properties" % changes.size())
			for change in changes:
				var ch: Dictionary = change
				lines.append("      [%s] %s: %s -> %s (now %s)" % [
					str(ch.get("header", "")), str(ch.get("key", "")),
					str(ch.get("previous", "")), str(ch.get("working", "")), str(ch.get("current", "")),
				])
			var phys: Dictionary = diff.get("physical_source_diff", {})
			if not phys.is_empty():
				lines.append("    physical byte-identical: %s" % str(bool(phys.get("byte_identical", false))))
				for comment in (phys.get("comment_changes", []) as Array):
					lines.append("      comment change: %s" % str(comment))
				for dup in (phys.get("duplicate_key_changes", []) as Array):
					lines.append("      duplicate physical occurrence: %s" % str(dup))
				if bool(phys.get("encoding_changes", false)):
					lines.append("      encoding/BOM change: %s/%s -> %s/%s" % [
						str(phys.get("previous_encoding", "")), str(bool(phys.get("previous_bom", false))),
						str(phys.get("current_encoding", "")), str(bool(phys.get("current_bom", false)))])
				if bool(phys.get("physical_entries_changed", false)) and \
						(phys.get("comment_changes", []) as Array).is_empty() and \
						(phys.get("duplicate_key_changes", []) as Array).is_empty():
					lines.append("      physical entry changes (whitespace/order/line endings)")
			lines.append("    revision hashes: previous %s / working %s / current %s" % [
				str(diff.get("previous_hash", "")), str(diff.get("working_hash", "")),
				str(diff.get("current_hash", ""))])
	lines.append("Conflicts: %d" % int((group.get("conflict_resolution", {}) as Dictionary).get("failed", []).size()))
	lines.append("=== PHYSICAL SOURCE DIFF (above, per file) ===")
	lines.append("Preserved: unknown files and protected sources are never touched.")
	if action == "RECOVER":
		lines.append("Overwrites: recorded previous override bytes on affected files.")
	elif action == "KEEP CURRENT":
		lines.append("Overwrites: nothing; keeps current bytes, marks group resolved.")
	elif action == "RESTORE WORKING":
		lines.append("Overwrites: current override bytes with the preserved working revision.")
	return "\n".join(lines)


func _request_recovery_action(action: String) -> void:
	var meta := _selected_recovery_row()
	if meta.is_empty() or str(meta.get("kind", "")) != "save_group":
		_set_status("Recovery Center: select a SAVE GROUP row.", "warning")
		return
	var g: Dictionary = meta.get("group", {})
	var gid := str(g.get("group_id", ""))
	if gid == "" or particle_lab == null:
		_set_status("Recovery Center: group id missing or Particle Lab unavailable.", "danger")
		return
	var token: Dictionary = particle_lab.build_recovery_confirmation_token(gid, action)
	if not bool(token.get("ok", false)):
		_set_status("Recovery Center: cannot capture current revision (%s); action refused." % str(token.get("reason", "UNKNOWN")), "danger")
		return
	pending_recovery_action = token
	recovery_confirm_dialog.dialog_text = _preview_recovery_action(g, action)
	recovery_confirm_dialog.popup_centered()


func _confirm_recovery_action() -> void:
	if pending_recovery_action.is_empty():
		return
	var action := str(pending_recovery_action.get("action", ""))
	var gid := str(pending_recovery_action.get("group_id", ""))
	# T-122: the resolver itself revalidates journal, manifest and every
	# current file hash from the captured token before any mutation.
	var token: Dictionary = pending_recovery_action.duplicate(true)
	pending_recovery_action = {}
	if action == "RECOVER":
		_execute_recovery(gid, token)
	else:
		_execute_conflict_resolution(gid, action.to_lower(), token)


func _execute_recovery(gid: String, token: Dictionary = {}) -> void:
	var options := {"ui_confirmed": true}
	if not token.is_empty():
		options["confirmation_token"] = token
	var res: Dictionary = particle_lab.recover_partial_save_group(gid, options)
	if bool(res.get("ok", false)):
		_set_status("Recovery Center: group %s RECOVERED (%d file(s) restored)." % [gid, (res.get("restored", []) as Array).size()], "success")
	else:
		var state := str(res.get("status", str(res.get("reason", "FAILED"))))
		_set_status("Recovery Center: group %s -> %s (no unsafe overwrite was performed)." % [gid, state], "danger")
	_refresh_recovery_center_tree()


func _execute_conflict_resolution(gid: String, action: String, token: Dictionary = {}) -> void:
	if gid == "" or particle_lab == null:
		_set_status("Recovery Center: group id missing or Particle Lab unavailable.", "danger")
		return
	if not token.is_empty():
		var guard: Dictionary = particle_lab.verify_recovery_confirmation(gid, "restore_working" if action == "restore_working" else action, token)
		if not bool(guard.get("ok", false)):
			_set_status("Recovery Center: %s since preview; action refused." % str(guard.get("reason", "state changed")), "danger")
			_refresh_recovery_center_tree()
			return
	var res: Dictionary = particle_lab.resolve_recovery_conflict(gid, action, token)
	if bool(res.get("ok", false)):
		_set_status("Recovery Center: conflict resolved (%s) for %s." % [action, gid], "success")
	else:
		_set_status("Recovery Center: resolution %s -> %s." % [action, str(res.get("status", str(res.get("reason", "FAILED"))))], "danger")
	_refresh_recovery_center_tree()


func _build_actor_picker_dialog() -> void:
	actor_picker_dialog = AcceptDialog.new()
	actor_picker_dialog.title = "Pick Object"
	actor_picker_dialog.size = Vector2i(680, 520)
	actor_picker_dialog.ok_button_text = "Assign Selected"
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	actor_picker_dialog.add_child(vb)
	var hint := Label.new()
	hint.text = "Filter by Stock / VSR / VRV / Mods and double-click an ODF (or click Assign Selected)."
	hint.add_theme_color_override("font_color", Color("#C5AB6E"))
	vb.add_child(hint)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	vb.add_child(bar)
	actor_picker_coll = OptionButton.new()
	for cp in [["All Mods", "all"], ["Stock (BZ2R)", "stock"], ["VSR", "vsr"], ["VRV", "vrv"], ["Workshop Mods", "mods"], ["Addon", "addon"]]:
		actor_picker_coll.add_item(str(cp[0]))
		actor_picker_coll.set_item_metadata(actor_picker_coll.item_count - 1, str(cp[1]))
	actor_picker_coll.item_selected.connect(func(_i): _refresh_actor_picker())
	bar.add_child(actor_picker_coll)
	actor_picker_cat = OptionButton.new()
	for cat_p in [["Vehicles", "vehicles"], ["Buildings", "buildings"], ["Weapons", "weapons"], ["All Types", "all"]]:
		actor_picker_cat.add_item(str(cat_p[0]))
		actor_picker_cat.set_item_metadata(actor_picker_cat.item_count - 1, str(cat_p[1]))
	actor_picker_cat.item_selected.connect(func(_i): _refresh_actor_picker())
	bar.add_child(actor_picker_cat)
	actor_picker_search = LineEdit.new()
	actor_picker_search.placeholder_text = "Type ODF name (e.g. ivtank, ivscav, fvturr…)"
	actor_picker_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actor_picker_search.text_changed.connect(func(_t): _refresh_actor_picker())
	bar.add_child(actor_picker_search)
	actor_picker_tree = Tree.new()
	actor_picker_tree.columns = 3
	actor_picker_tree.set_column_title(0, "ODF")
	actor_picker_tree.set_column_title(1, "Collection / Mod")
	actor_picker_tree.set_column_title(2, "Category")
	actor_picker_tree.column_titles_visible = true
	actor_picker_tree.hide_root = true
	actor_picker_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	actor_picker_tree.custom_minimum_size = Vector2(620, 360)
	actor_picker_tree.item_activated.connect(_confirm_actor_picker)
	vb.add_child(actor_picker_tree)
	actor_picker_dialog.confirmed.connect(_confirm_actor_picker)
	add_child(actor_picker_dialog)


func open_actor_picker(role: String) -> void:
	actor_picker_role = "target" if role == "target" else "shooter"
	if actor_picker_dialog == null:
		return
	actor_picker_dialog.title = "Pick Object A (Shooter)" if actor_picker_role == "shooter" else "Pick Object B (Target)"
	actor_picker_search.text = ""
	_refresh_actor_picker()
	actor_picker_dialog.popup_centered()
	actor_picker_search.grab_focus()


func _refresh_actor_picker() -> void:
	if actor_picker_tree == null or index == null:
		return
	actor_picker_tree.clear()
	var root := actor_picker_tree.create_item()
	var coll := str(actor_picker_coll.get_item_metadata(actor_picker_coll.selected)) if actor_picker_coll.selected >= 0 else "all"
	var cat := str(actor_picker_cat.get_item_metadata(actor_picker_cat.selected)) if actor_picker_cat.selected >= 0 else "vehicles"
	var rows := index.search_filtered(actor_picker_search.text, coll, cat, 300)
	for r in rows:
		var item := actor_picker_tree.create_item(root)
		var rpath := str(r.path)
		var gname := index.get_game_name(rpath)
		var fn := rpath.get_file()
		item.set_text(0, ("%s — %s" % [fn, gname]) if (gname != "" and gname.to_lower() != fn.get_basename().to_lower()) else fn)
		item.set_text(1, str(r.get("mod_label", r.get("root", ""))))
		item.set_text(2, str(r.get("category", "")))
		item.set_tooltip_text(0, rpath)
		item.set_metadata(0, rpath)


func _confirm_actor_picker() -> void:
	if actor_picker_tree == null:
		return
	var sel := actor_picker_tree.get_selected()
	if sel == null:
		return
	var path := str(sel.get_metadata(0))
	if path == "":
		return
	actor_picker_dialog.hide()
	if actor_picker_role == "target":
		target_path = path
		weapon_lab.set_target(path)
		_set_status("Object B (Target) set: " + path.get_file(), "success")
	else:
		shooter_path = path
		weapon_lab.set_shooter(path)
		open_document(path)
		doc_tabs.current_tab = 0
		_set_status("Object A (Shooter) set: " + path.get_file(), "success")


func _build_model_tab() -> Control:
	var root := VBoxContainer.new()
	model_text = RichTextLabel.new()
	model_text.bbcode_enabled = true
	model_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	model_text.selection_enabled = true
	model_text.text = "Select an ODF to inspect its declared model, texture and sound references.\n\n[color=#81B681]DOCB .msh geometry, .material descriptors, DDS/TGA textures and hardpoints are decoded in the Weapons Lab.[/color]"
	root.add_child(model_text)
	return root


func _build_docs_tab() -> Control:
	var root := VBoxContainer.new()
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.selection_enabled = true
	text.text = "[b]BZ_ODF_SHAMAN — quick reference[/b]\n\n" \
		+ "• Select an ODF in the resource explorer; double-click to open it.\n" \
		+ "• The Inspector edits only the value span — comments, order and duplicates stay intact.\n" \
		+ "• Use the exact raw toggle to edit any value verbatim.\n" \
		+ "• Weapons Lab: choose a shooter and target, then FIRE.\n" \
		+ "• Particle Lab opens automatically for ODFs with renderBase headers.\n" \
		+ "• Saving writes to user://workspace, never to game data unless you confirm overwrite.\n" \
		+ "• Fidelity is APPROXIMATED until a scenario is compared against native BZCC.\n\n" \
		+ "[b]Documented schema[/b]\n" + str(schema.property_count()) + " properties across " + str(schema.classes.size()) + " classes.\n" \
		+ "Render bases: " + ", ".join(PackedStringArray(schema.render_bases())) + "\n" \
		+ "Simulate bases: " + ", ".join(PackedStringArray(schema.simulate_bases())) + "\n"
	root.add_child(text)
	return root


func _top_button(text: String, cb: Callable, tooltip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if tooltip != "":
		b.tooltip_text = tooltip
	b.pressed.connect(cb)
	return b


func _populate_theme_option() -> void:
	theme_option.clear()
	for slug in theme_engine.slugs:
		var label := str(theme_engine.themes[slug].get("label", slug))
		theme_option.add_item(label)
		theme_option.set_item_metadata(theme_option.item_count - 1, slug)
		if slug == theme_engine.current_slug:
			theme_option.select(theme_option.item_count - 1)


func _apply_theme(slug: String) -> void:
	theme_engine.select(slug)
	theme = theme_engine.build_theme()
	for dlg in [open_dialog, export_dialog, overwrite_dialog, revert_dialog, reset_all_dialog, reset_doc_dialog, recovery_history_dialog, actor_picker_dialog]:
		if dlg != null:
			dlg.theme = theme
	if theme_option:
		for i in range(theme_option.item_count):
			if str(theme_option.get_item_metadata(i)) == slug:
				theme_option.select(i)


func _on_theme_selected(i: int) -> void:
	var slug := str(theme_option.get_item_metadata(i))
	_apply_theme(slug)
	_save_settings()
	_set_status("Theme: " + str(theme_engine.themes[slug].get("label", slug)), "muted")


func apply_font_aa(mode: String) -> void:
	theme_engine.set_font_aa(mode)
	theme = theme_engine.build_theme()
	for dlg in [open_dialog, export_dialog, overwrite_dialog, revert_dialog, reset_all_dialog, reset_doc_dialog, recovery_history_dialog, actor_picker_dialog]:
		if dlg != null:
			dlg.theme = theme
	if font_aa_option != null:
		for i in font_aa_option.item_count:
			if str(font_aa_option.get_item_metadata(i)) == theme_engine.font_aa_mode:
				font_aa_option.select(i)
				break


func _on_font_aa_selected(i: int) -> void:
	var mode := str(font_aa_option.get_item_metadata(i))
	apply_font_aa(mode)
	_save_settings()
	_set_status("Font rendering: " + font_aa_option.get_item_text(i), "muted")


func apply_ui_scale(scale: float) -> void:
	ui_scale = clampf(scale, 0.75, 2.0)
	var win := get_window()
	if win != null:
		# Keep window content_scale_factor at 1.0 (1:1 screen pixels) and scale
		# WintageTheme's integer 1bpp bitmap font strike (9..24px) directly so zero
		# fractional glyph decimation or StyleBox tiling stripes ever occur.
		win.content_scale_factor = 1.0
	if theme_engine != null:
		theme_engine.set_ui_scale(ui_scale)
		theme = theme_engine.build_theme()
		for dlg in [open_dialog, export_dialog, overwrite_dialog, revert_dialog, reset_all_dialog, reset_doc_dialog, recovery_history_dialog, actor_picker_dialog]:
			if dlg != null:
				dlg.theme = theme
	if ui_scale_option != null:
		var best := -1
		var best_d := 999.0
		for i in ui_scale_option.item_count:
			var sc := float(ui_scale_option.get_item_metadata(i))
			if absf(sc - ui_scale) < best_d:
				best_d = absf(sc - ui_scale)
				best = i
		if best >= 0:
			ui_scale_option.select(best)


## Single shared path for switching the active mod loadout (P1-04 / Wave E ModLoadout).
## Keeps ResourceIndex, Weapons Lab, Particle Lab, Audio Lab, Inspector, and
## persisted project configuration synchronized.
func apply_active_loadout(pkg_id: String, persist: bool = true) -> void:
	var clean_pkg := pkg_id.strip_edges()
	if clean_pkg.begins_with("profile:"):
		load_loadout_profile(clean_pkg.trim_prefix("profile:"), persist)
		return
	if clean_pkg == "":
		clean_pkg = "auto"
	active_loadout_id = clean_pkg
	active_loadout_profile = null
	if index != null:
		index.set_active_package(clean_pkg)
	if loadout_option != null:
		for i in loadout_option.item_count:
			if str(loadout_option.get_item_metadata(i)) == clean_pkg:
				loadout_option.select(i)
				break
	if weapon_lab != null and shooter_path != "" and target_path != "":
		weapon_lab.reload_after_raw_edit()
	if particle_lab != null:
		particle_lab.bind_context_document(current_doc, weapon_lab.profile if weapon_lab != null else null)
	if audio_lab != null and current_doc != null:
		audio_lab.set_document(current_doc)
	_rebuild_inspector()
	_refresh_dependencies()
	_update_model_tab()
	_populate_resources()
	if persist:
		_save_settings()
	var label := loadout_option.get_item_text(loadout_option.selected) if (loadout_option != null and loadout_option.selected >= 0) else clean_pkg
	_set_status("Active Workshop Loadout: " + label, "success")


func _refresh_loadout_option_profiles() -> void:
	if loadout_option == null:
		return
	# Preserve the 5 built-in entries (VSR, VSR Legacy, VRV, Stock Only, Auto), then append saved persistent ModLoadout profiles.
	while loadout_option.item_count > 5:
		loadout_option.remove_item(loadout_option.item_count - 1)
	for prof in ModLoadoutScript.list_profiles():
		var pid := str(prof.get("profile_id", ""))
		var dname := str(prof.get("display_name", pid))
		if pid != "":
			loadout_option.add_item("Profile: " + dname)
			loadout_option.set_item_metadata(loadout_option.item_count - 1, "profile:" + pid)


func save_loadout_profile(profile_id: String, display_name: String = "",
		enabled_pkgs: Array = [], explicit_winners: Dictionary = {}) -> Dictionary:
	var prof = ModLoadoutScript.capture_from_index(profile_id, index, display_name, "BZCC", enabled_pkgs, explicit_winners)
	var sres: Dictionary = ModLoadoutScript.save_profile(prof)
	if bool(sres.get("ok", false)):
		active_loadout_profile = prof
		_refresh_loadout_option_profiles()
		_set_status("Saved ModLoadout profile '%s' (%d pkg(s), %d explicit winner(s))" % [
			prof.profile_id, prof.enabled_packages.size(), prof.explicit_resource_winners.size()
		], "success")
	else:
		_set_status("Save ModLoadout failed: " + str(sres.get("error", "")), "danger")
	return sres


func load_loadout_profile(profile_id: String, persist: bool = true) -> Dictionary:
	var prof = ModLoadoutScript.load_profile(profile_id)
	if prof == null:
		_set_status("ModLoadout profile not found: " + profile_id, "warning")
		return {"ok": false, "error": "not found"}
	active_loadout_profile = prof
	active_loadout_id = "profile:" + str(prof.profile_id)
	var applied: Dictionary = index.apply_loadout(prof) if index != null else {}
	_refresh_loadout_option_profiles()
	if loadout_option != null:
		for i in loadout_option.item_count:
			if str(loadout_option.get_item_metadata(i)) == active_loadout_id:
				loadout_option.select(i)
				break
	if weapon_lab != null and shooter_path != "" and target_path != "":
		weapon_lab.reload_after_raw_edit()
	if particle_lab != null:
		particle_lab.bind_context_document(current_doc, weapon_lab.profile if weapon_lab != null else null)
	if audio_lab != null and current_doc != null:
		audio_lab.set_document(current_doc)
	_rebuild_inspector()
	_refresh_dependencies()
	_update_model_tab()
	_populate_resources()
	if persist:
		_save_settings()
	var rep: Dictionary = prof.resolve_conflicts_report(index)
	_set_status("Loaded ModLoadout '%s' (%d pkg(s), %d conflict(s), %d missing)" % [
		prof.profile_id, prof.effective_package_order().size(),
		int(rep.get("conflicts_count", 0)), (rep.get("missing_dependencies", []) as Array).size()
	], "success")
	return {"ok": true, "profile": prof, "applied": applied, "report": rep}


func list_loadout_profiles() -> Array[Dictionary]:
	return ModLoadoutScript.list_profiles()


func _on_loadout_selected(i: int) -> void:
	if loadout_option == null:
		return
	apply_active_loadout(str(loadout_option.get_item_metadata(i)), true)


## RESET UI APPEARANCE only (P1-04 / RST-12): never changes active mod loadout.
func reset_ui_to_default() -> void:
	_apply_theme("goldendefault")
	apply_font_aa("none")
	apply_ui_scale(1.0)
	apply_master_volume(0.85, false)
	_save_settings()
	_set_status("Reset UI appearance (Golden Default, No-AA Verdana_m1 12px, 100% scale, 85% volume; mod loadout preserved).", "success")


## Explicit RESET MOD LOADOUT scope separated from UI appearance (P1-04).
func reset_mod_loadout_to_default() -> void:
	apply_active_loadout("3532748119", true)
	_set_status("Reset active mod loadout to default VSR (3532748119).", "success")


## Explicit RESET COMPLETE PROJECT CONFIGURATION scope (UI + Mod Loadout + optional Workspace Overrides).
## P1-04 / RST-22: When `include_workspace_overrides=true` and `confirmed=false`,
## performs ZERO UI, loadout, or workspace mutations until the impact snapshot is confirmed.
func reset_project_configuration_to_default(include_workspace_overrides: bool = false, confirmed: bool = false) -> Dictionary:
	if include_workspace_overrides and not confirmed:
		var preview := preview_reset_all_impact()
		if int(preview.get("total_affected_count", 0)) > 0:
			_pending_project_config_reset = true
			var req := request_reset_all_odfs()
			req["scope"] = "RESET_PROJECT_CONFIGURATION"
			req["project_config_pending"] = true
			return req
	_pending_project_config_reset = false
	var ws_report: Dictionary = {}
	if include_workspace_overrides:
		ws_report = reset_all_odfs_to_default(true)
		if not bool(ws_report.get("ok", false)) and str(ws_report.get("status", "")) != "NO_CHANGES":
			ws_report["scope"] = "RESET_PROJECT_CONFIGURATION"
			return ws_report
	reset_ui_to_default()
	reset_mod_loadout_to_default()
	if include_workspace_overrides:
		ws_report["scope"] = "RESET_PROJECT_CONFIGURATION"
		ws_report["project_config_reset"] = true
		ws_report["active_loadout"] = active_loadout_id
		return ws_report
	return {"ok": true, "status": "PROJECT_CONFIG_RESET", "active_loadout": active_loadout_id}


func _on_ui_scale_selected(i: int) -> void:
	var sc := float(ui_scale_option.get_item_metadata(i))
	apply_ui_scale(sc)
	_save_settings()
	_set_status("UI scale: %d%%" % int(round(ui_scale * 100.0)), "muted")


func apply_master_volume(vol_linear: float, muted: bool = false) -> void:
	master_volume = clampf(vol_linear, 0.0, 1.0)
	master_muted = muted
	var bus_idx := AudioServer.get_bus_index("Master")
	if bus_idx >= 0:
		AudioServer.set_bus_mute(bus_idx, master_muted or master_volume <= 0.001)
		AudioServer.set_bus_volume_db(bus_idx, linear_to_db(maxf(0.0001, master_volume)))
	if mute_button != null:
		mute_button.set_pressed_no_signal(master_muted)
		mute_button.text = "Muted" if master_muted else "Vol"
	if volume_scrubber != null:
		volume_scrubber.set_value_no_signal(roundf(master_volume * 100.0))


# ---------------------------------------------------------------- indexing

func _start_index_scan() -> void:
	if scan_thread != null and scan_thread.is_alive():
		return
	scan_thread = Thread.new()
	scan_thread.start(_scan_worker)


func _scan_worker() -> void:
	index.scan_or_load_cache(true)


func _process(_delta: float) -> void:
	if scan_thread != null and not scan_thread.is_alive():
		scan_thread.wait_to_finish()
		scan_thread = null
		_on_index_ready()
	if scan_requested and scan_thread != null:
		index_label.text = "Indexing… %d ODFs" % index.total_files


func _on_index_ready() -> void:
	scan_requested = false
	index_label.text = index.summary()
	status_counts.text = "fidelity: APPROXIMATED   ·   " + index.summary()
	_populate_resources()
	_set_status("Resource index ready. " + index.summary(), "success")
	if shooter_path != "" and target_path != "":
		weapon_lab.set_shooter(shooter_path)
		weapon_lab.set_target(target_path)
		if last_document_path != "" and FileAccess.file_exists(last_document_path):
			open_document(last_document_path)
		elif FileAccess.file_exists(shooter_path):
			open_document(shooter_path)
	elif shooter_path == "" or target_path == "":
		_auto_select_reference_scenario()
	if restored_overrides > 0:
		_set_status("Restored %d saved workspace override(s) from %s" % [restored_overrides, ProjectSettings.globalize_path(WorkspaceStore.root())], "success")
	var verify_dir := OS.get_environment("BZ_SHAMAN_VERIFY_GUI_DIR")
	if verify_dir != "":
		call_deferred("_run_gui_self_verify", verify_dir)


func _populate_resources() -> void:
	if resource_tree == null:
		return
	resource_tree.clear()
	var root := resource_tree.create_item()
	var q := search_edit.text.strip_edges()
	var counts := index.collection_counts()
	if q != "":
		var results := index.search_filtered(q, active_collection_filter, active_category_filter, 400)
		for r in results:
			var item := resource_tree.create_item(root)
			item.set_text(0, str(r.path).get_file())
			item.set_text(1, str(r.get("mod_label", r.get("root", ""))))
			item.set_tooltip_text(0, "%s\n[%s · %s]" % [str(r.path), str(r.get("mod_label", "")), str(r.get("category", ""))])
			item.set_metadata(0, str(r.path))
		index_label.text = "%d matches · Stock:%d VSR:%d VRV:%d Mods:%d" % [
			results.size(), int(counts.get("stock", 0)), int(counts.get("vsr", 0)),
			int(counts.get("vrv", 0)), int(counts.get("mods", 0))
		]
		return

	# Hierarchical categorized tree: Collection/Mod -> Category -> ODF (no flat 17k wall).
	var all_rows := index.search_filtered("", active_collection_filter, active_category_filter, 0)
	var grouped := {}  # mod_key -> {order, label, cats: {cat -> Array[Dictionary]}}
	var coll_order := {"stock": 0, "vsr": 1, "vrv": 2, "addon": 3, "mods": 4}
	for r in all_rows:
		var coll := str(r.get("collection", "mods"))
		var mod_lbl := str(r.get("mod_label", "Other"))
		var mkey := "%d|%s" % [int(coll_order.get(coll, 9)), mod_lbl]
		if not grouped.has(mkey):
			grouped[mkey] = {"label": mod_lbl, "collection": coll, "count": 0, "cats": {}}
		var entry: Dictionary = grouped[mkey]
		entry["count"] = int(entry["count"]) + 1
		var cat := str(r.get("category", "Other"))
		var cats: Dictionary = entry["cats"]
		if not cats.has(cat):
			cats[cat] = []
		(cats[cat] as Array).append(r)

	var mod_keys := grouped.keys()
	mod_keys.sort()
	var cat_order := ["Vehicles", "Weapons", "Ordnance", "Explosions / FX", "Buildings", "Pilots & Props", "Other"]
	for mkey in mod_keys:
		var mrec: Dictionary = grouped[mkey]
		var mod_item := resource_tree.create_item(root)
		mod_item.set_text(0, str(mrec.label))
		mod_item.set_text(1, "%d ODFs" % int(mrec.count))
		mod_item.set_custom_color(0, Color("#D3B57A"))
		mod_item.set_metadata(0, "")
		var coll_id := str(mrec.collection)
		# Expand Stock/VSR/VRV when explicitly filtered, collapse large mod lists by default.
		mod_item.collapsed = (active_collection_filter == "all" and coll_id == "mods") or (mod_keys.size() > 4 and coll_id != "stock" and coll_id != "vsr" and coll_id != "vrv")
		var cats: Dictionary = mrec.cats
		for cat_name in cat_order:
			if not cats.has(cat_name):
				continue
			var items: Array = cats[cat_name]
			items.sort_custom(func(a, b): return str(a.path).get_file().to_lower() < str(b.path).get_file().to_lower())
			var cat_item := resource_tree.create_item(mod_item)
			cat_item.set_text(0, cat_name)
			cat_item.set_text(1, "%d" % items.size())
			cat_item.set_custom_color(0, Color("#C5AB6E"))
			cat_item.set_metadata(0, "")
			cat_item.collapsed = (active_category_filter == "all")
			var cap := mini(items.size(), 500)
			for idx_i in cap:
				var rec: Dictionary = items[idx_i]
				var rpath := str(rec.path)
				var fn := rpath.get_file()
				var gname := index.get_game_name(rpath)
				var folder := str(rec.get("rel", "")).get_base_dir().get_file()
				var leaf := resource_tree.create_item(cat_item)
				leaf.set_text(0, fn)
				leaf.set_text(1, gname if gname != "" else folder)
				if gname != "":
					leaf.set_custom_color(1, Color("#E2CA95"))
				leaf.set_tooltip_text(0, ("%s — %s\n%s" % [fn, gname, rpath]) if gname != "" else rpath)
				leaf.set_metadata(0, rpath)
			if items.size() > cap:
				var more_leaf := resource_tree.create_item(cat_item)
				more_leaf.set_text(0, "… %d more (use Search)" % (items.size() - cap))
				more_leaf.set_custom_color(0, Color("#95804C"))
				more_leaf.set_metadata(0, "")
	index_label.text = "Stock:%d · VSR:%d · VRV:%d · Mods:%d" % [
		int(counts.get("stock", 0)), int(counts.get("vsr", 0)),
		int(counts.get("vrv", 0)), int(counts.get("mods", 0))
	]


func _on_resource_tree_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and resource_context_menu != null:
			var item := resource_tree.get_item_at_position(mb.position)
			if item != null and str(item.get_metadata(0)) != "":
				item.select(0)
				resource_context_menu.position = Vector2i(mb.global_position)
				resource_context_menu.popup()


func _on_open_pressed() -> void:
	open_dialog.popup_centered()


func set_live_swap_mode(mode: String) -> void:
	var clean := mode.strip_edges().to_lower()
	if not ["off", "shooter", "target", "weapon", "auto_lab"].has(clean):
		clean = "off"
	live_swap_mode = clean
	if live_swap_option != null:
		for i in live_swap_option.item_count:
			if str(live_swap_option.get_item_metadata(i)) == clean:
				live_swap_option.select(i)
				break
	_set_status("Live-Swap mode: " + clean, "muted")
	_save_settings()


func _is_weapon_odf(doc: OdfDocument) -> bool:
	if doc == null:
		return false
	for hdr in ["WeaponClass", "CannonClass", "LauncherClass", "GunClass", "MortarClass", "ArcCannonClass", "SpecialItemClass", "TargetingGunClass", "ThermalLauncherClass", "ImageLauncherClass", "RadarLauncherClass"]:
		if doc.has_header(hdr):
			return true
	return false


func _apply_live_swap_for_path(path: String) -> void:
	if path == "" or live_swap_mode == "off" or not FileAccess.file_exists(path):
		return
	var doc := OdfDocument.load_cached(path)
	if doc == null:
		return
	match live_swap_mode:
		"shooter":
			if not doc.is_render_odf() and not _is_weapon_odf(doc) and not doc.has_header("OrdnanceClass") and weapon_lab != null:
				shooter_path = path
				weapon_lab.set_shooter(path)
		"target":
			if not doc.is_render_odf() and not _is_weapon_odf(doc) and not doc.has_header("OrdnanceClass") and weapon_lab != null:
				target_path = path
				weapon_lab.set_target(path)
		"weapon":
			if _is_weapon_odf(doc) and weapon_lab != null and shooter_path != "" and target_path != "":
				weapon_lab.set_weapon_override(path.get_file().get_basename())
				if doc_tabs != null:
					doc_tabs.current_tab = 0
		"auto_lab":
			if doc.is_render_odf():
				if particle_lab != null:
					particle_lab.load_document(doc)
					if doc_tabs != null:
						doc_tabs.current_tab = 1
			elif _is_weapon_odf(doc):
				if weapon_lab != null and shooter_path != "" and target_path != "":
					weapon_lab.set_weapon_override(path.get_file().get_basename())
					if doc_tabs != null:
						doc_tabs.current_tab = 0
			elif not doc.has_header("OrdnanceClass") and weapon_lab != null:
				shooter_path = path
				weapon_lab.set_shooter(path)
				if doc_tabs != null:
					doc_tabs.current_tab = 0


func _on_resource_selected() -> void:
	var item := resource_tree.get_selected()
	if item == null:
		return
	var path := str(item.get_metadata(0))
	if path != "" and FileAccess.file_exists(path) and path != origin_path:
		open_document(path)
		_apply_live_swap_for_path(path)


func _on_resource_activated() -> void:
	var item := resource_tree.get_selected()
	if item == null:
		return
	var path := str(item.get_metadata(0))
	if path != "":
		open_document(path)
		if current_doc != null and current_doc.is_render_odf():
			doc_tabs.current_tab = 1


func _selected_resource() -> String:
	var item := resource_tree.get_selected()
	return str(item.get_metadata(0)) if item != null else ""


func _send_selection_to_lab() -> void:
	var path := _selected_resource()
	if path == "" and current_doc != null:
		path = current_doc.source_path
	if path == "":
		_set_status("Select an ODF in the Resource Explorer first.", "warning")
		return
	open_document(path)
	if current_doc != null and current_doc.is_render_odf():
		particle_lab.load_document(current_doc)
		doc_tabs.current_tab = 1
		_set_status("Loaded render ODF in Particle Lab: " + path.get_file(), "success")
		return
	_use_selection_as_shooter()


func _use_selection_as_shooter() -> void:
	var path := _selected_resource()
	if path == "":
		_set_status("Select a resource first.", "warning")
		return
	shooter_path = path
	weapon_lab.set_shooter(path)
	open_document(path)
	doc_tabs.current_tab = 0
	_set_status("Shooter set: " + path.get_file(), "muted")


func _use_selection_as_target() -> void:
	var path := _selected_resource()
	if path == "":
		_set_status("Select a resource first.", "warning")
		return
	target_path = path
	weapon_lab.set_target(path)
	_set_status("Target set: " + path.get_file(), "muted")


# ---------------------------------------------------------------- documents

func open_document(path: String) -> void:
	var doc := OdfDocument.load_cached(path)
	if doc == null:
		_set_status("Could not open " + path, "danger")
		return
	current_doc = doc
	origin_path = path
	origin_rel = _relative_for(path)
	raw_edit.text = doc.text
	last_document_path = path
	_update_doc_title()
	_rebuild_inspector()
	_refresh_dependencies()
	_update_model_tab()
	if particle_lab != null:
		particle_lab.bind_context_document(doc, weapon_lab.profile if weapon_lab != null else null)
	audio_lab.set_document(doc)
	_set_status("Opened %s (%d properties, %d headers, %s)" % [
		doc.get_display_name(), doc.entries.size(), doc.headers.size(), doc.encoding
	], "success")
	_save_settings()


func _open_particle_graph(path: String) -> void:
	var doc := OdfDocument.load_cached(path)
	if doc == null:
		_set_status("Could not open Particle Graph source " + path, "danger")
		return
	open_document(path)
	particle_lab.load_document(doc)
	doc_tabs.current_tab = 1
	_set_status("Opened Particle Graph: " + path.get_file(), "success")


func _show_weapon_lab_shot(shot_id: int) -> void:
	doc_tabs.current_tab = 0
	if weapon_lab.focus_shot_on_timeline(shot_id):
		_set_status("Timeline shot #%d selected." % shot_id, "success")
	else:
		_set_status("Timeline shot #%d was not found." % shot_id, "warning")


func _rebuild_inspector_chain_bar() -> void:
	if inspector_chain_bar == null:
		return
	for c in inspector_chain_bar.get_children():
		c.queue_free()
	var steps: Array[Dictionary] = []
	if shooter_path != "":
		var sa := shooter_path.get_file().get_basename()
		var ga := index.get_game_name(shooter_path) if index != null else ""
		steps.append({"label": "A: %s%s" % [sa, " (" + ga + ")" if (ga != "" and ga.to_lower() != sa.to_lower()) else ""], "path": shooter_path})
	if weapon_lab != null and weapon_lab.profile != null:
		var p := weapon_lab.profile
		if p.weapon_path != "":
			var gw := index.get_game_name(p.weapon_path) if index != null else ""
			steps.append({"label": "Wpn: %s%s" % [p.weapon_name, " (" + gw + ")" if (gw != "" and gw.to_lower() != p.weapon_name.to_lower()) else ""], "path": p.weapon_path})
		if p.ordnance_path != "":
			steps.append({"label": "Ord: " + p.ordnance_name, "path": p.ordnance_path})
		var xn := p.xpl_vehicle if p.xpl_vehicle != "" else p.xpl_ground
		var xp := index.resolve_path_from(xn, p.ordnance_path) if (xn != "" and index != null) else ""
		if xp != "":
			steps.append({"label": "Xpl: " + xn, "path": xp, "particle": true})
	if target_path != "":
		var sb := target_path.get_file().get_basename()
		var gb := index.get_game_name(target_path) if index != null else ""
		steps.append({"label": "B: %s%s" % [sb, " (" + gb + ")" if (gb != "" and gb.to_lower() != sb.to_lower()) else ""], "path": target_path})
	for s in steps:
		var sp := str(s.get("path", ""))
		var btn := Button.new()
		btn.text = str(s.get("label", ""))
		btn.focus_mode = Control.FOCUS_NONE
		btn.tooltip_text = "Open " + sp.get_file() + " in Inspector"
		var is_cur := (current_doc != null and WorkspaceStore.canonical(current_doc.source_path).to_lower() == WorkspaceStore.canonical(sp).to_lower())
		if is_cur:
			btn.add_theme_color_override("font_color", Color("#F0D060"))
		var to_particle := bool(s.get("particle", false))
		btn.pressed.connect(func():
			open_document(sp)
			if to_particle:
				doc_tabs.current_tab = 1
		)
		inspector_chain_bar.add_child(btn)
	if current_doc != null and current_doc.is_render_odf():
		var pl_btn := Button.new()
		pl_btn.text = "Edit Graph in Particle Lab →"
		pl_btn.focus_mode = Control.FOCUS_NONE
		pl_btn.pressed.connect(func():
			particle_lab.load_document(current_doc)
			doc_tabs.current_tab = 1
		)
		inspector_chain_bar.add_child(pl_btn)


func override_inherited_property(header: String, key_with_suffix: String, val: String) -> bool:
	if current_doc == null or header == "" or key_with_suffix == "":
		return false
	current_doc.append_entry(header, key_with_suffix, val)
	_after_edit()
	_rebuild_inspector()
	_set_status("Overrode inherited [%s] %s = %s in %s" % [header, key_with_suffix, val, current_doc.get_display_name()], "success")
	return true


func _rebuild_inspector() -> void:
	_rebuild_inspector_chain_bar()
	for c in inspector_box.get_children():
		c.queue_free()
	if current_doc == null:
		inspector_title.text = "No document open"
		return
	if not current_doc.warnings.is_empty():
		var warn := Label.new()
		warn.text = "⚠ %d parser warning(s) — see Diagnostics" % current_doc.warnings.size()
		warn.add_theme_color_override("font_color", Color("#D66464"))
		inspector_box.add_child(warn)
	for h in current_doc.headers:
		var entries: Array = []
		for e in current_doc.entries:
			if e.header == h.name:
				if inspector_property_filter != "":
					var hay: String = (str(h.name) + " " + str(e.full_key()) + " " + str(e.value_raw)).to_lower()
					if not hay.contains(inspector_property_filter):
						continue
				entries.append(e)
		if entries.is_empty():
			continue
		var panel := PanelContainer.new()
		inspector_box.add_child(panel)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		panel.add_child(vb)
		var hlabel := Label.new()
		hlabel.text = "[" + h.name + "]"
		hlabel.add_theme_color_override("font_color", Color("#F0D060"))
		hlabel.add_theme_font_size_override("font_size", 14)
		vb.add_child(hlabel)
		var tree_info := schema.class_tree(h.name)
		if not tree_info.is_empty():
			var tree_lbl := Label.new()
			tree_lbl.text = " → ".join(PackedStringArray(tree_info))
			tree_lbl.add_theme_color_override("font_color", Color("#9C9371"))
			tree_lbl.add_theme_font_size_override("font_size", 10)
			vb.add_child(tree_lbl)
		for e in entries:
			_add_entry_row(vb, e)
	_add_inherited_section()


func _add_inherited_section() -> void:
	if index == null or current_doc == null or index.count() == 0:
		return
	var inherited: Array = []
	for row in OdfInheritance.merged(current_doc, index):
		if bool(row.get("inherited", false)):
			if inspector_property_filter != "":
				var hay := ("%s %s%s %s %s" % [str(row.header), str(row.key), str(row.suffix), str(row.value), str(row.source).get_file()]).to_lower()
				if not hay.contains(inspector_property_filter):
					continue
			inherited.append(row)
	if inherited.is_empty():
		return
	var panel := PanelContainer.new()
	inspector_box.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "Inherited values (click '+ Override' to edit in this ODF)"
	title.add_theme_color_override("font_color", Color("#F0D060"))
	vb.add_child(title)
	var chain := OdfInheritance.describe_chain(current_doc, index)
	var chain_lbl := Label.new()
	chain_lbl.text = chain
	chain_lbl.add_theme_color_override("font_color", Color("#9C9371"))
	chain_lbl.add_theme_font_size_override("font_size", 10)
	chain_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(chain_lbl)
	var shown := 0
	for row in inherited:
		if shown >= 120:
			break
		var h_row := HBoxContainer.new()
		h_row.add_theme_constant_override("separation", 4)
		vb.add_child(h_row)
		var hdr_s := str(row.header)
		var key_s := str(row.key) + str(row.suffix)
		var val_s := str(row.value)
		var src_s := str(row.source)
		var line := Label.new()
		line.text = "[%s] %s = %s  ← %s" % [hdr_s, key_s, val_s, src_s.get_file()]
		line.add_theme_font_size_override("font_size", 11)
		line.add_theme_color_override("font_color", Color("#9C9371"))
		line.tooltip_text = src_s
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.clip_text = true
		h_row.add_child(line)
		var ov_btn := Button.new()
		ov_btn.text = "+ Override"
		ov_btn.focus_mode = Control.FOCUS_NONE
		ov_btn.tooltip_text = "Copy [%s] %s = %s into %s so you can adjust it with a slider" % [hdr_s, key_s, val_s, current_doc.get_display_name()]
		ov_btn.pressed.connect(func(): override_inherited_property(hdr_s, key_s, val_s))
		h_row.add_child(ov_btn)
		shown += 1
	if inherited.size() > shown:
		var more := Label.new()
		more.text = "… %d more inherited properties (use Filter box above)" % (inherited.size() - shown)
		more.add_theme_color_override("font_color", Color("#6E674E"))
		vb.add_child(more)


func _get_factory_doc(path: String) -> OdfDocument:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var canon := WorkspaceStore.canonical(path).to_lower()
	var disk_bytes := FileAccess.get_file_as_bytes(path)
	var disk_md5 := WorkspaceStore._md5_bytes(disk_bytes)
	if _factory_doc_cache.has(canon):
		var cached_rec = _factory_doc_cache[canon]
		if cached_rec is Dictionary and str(cached_rec.get("md5", "")) == disk_md5 and int(cached_rec.get("size", -1)) == disk_bytes.size():
			return cached_rec.get("doc", null)
	var fdoc := OdfDocument.load_file(path)
	if fdoc != null:
		_factory_doc_cache[canon] = {"doc": fdoc, "md5": disk_md5, "size": disk_bytes.size()}
	return fdoc


## Classify a property absent from the on-disk factory file so UI never falsely
## claims every absent property is an inherited override (P1-02).
func classify_absent_factory_property(doc: OdfDocument, e) -> Dictionary:
	if doc == null or e == null:
		return {"origin": "UNKNOWN_PROPERTY", "label": "unknown property", "parent_source": ""}
	if index != null:
		var chain := OdfInheritance.chain(doc, index)
		for i in range(1, chain.size()):
			var pdoc: OdfDocument = chain[i]
			if pdoc.find_entry(e.header, e.full_key()) != null:
				var pkg := index.package_of(pdoc.source_path)
				if pkg != "":
					return {
						"origin": "MOD_PROVIDED_PROPERTY",
						"label": "mod-provided property from %s (pkg %s)" % [pdoc.get_display_name(), pkg],
						"parent_source": pdoc.source_path,
					}
				return {
					"origin": "INHERITED_OVERRIDE",
					"label": "inherited value from %s" % pdoc.get_display_name(),
					"parent_source": pdoc.source_path,
				}
	if doc.workspace_override and doc.saved_text != "":
		var saved_doc := OdfDocument.parse_text(doc.saved_text, doc.source_path)
		if saved_doc.find_matching_entry(e) != null:
			return {
				"origin": "WORKSPACE_ADDED_PROPERTY",
				"label": "property added by a previous workspace edit",
				"parent_source": "",
			}
	if schema != null and not schema.property_info(e.header, e.key_raw).is_empty():
		return {
			"origin": "LOCAL_CUSTOM_PROPERTY",
			"label": "local custom property",
			"parent_source": "",
		}
	return {
		"origin": "UNKNOWN_PROPERTY",
		"label": "unknown custom property",
		"parent_source": "",
	}


func reset_entry_to_default(e) -> bool:
	if current_doc == null or e == null:
		return false
	var fdoc := _get_factory_doc(current_doc.source_path)
	var fentry = fdoc.find_matching_entry(e) if fdoc != null else null
	if fentry != null:
		last_property_reset_info = {
			"action": "RESTORE_FACTORY_VALUE",
			"header": e.header,
			"header_id": e.header_id,
			"occurrence_index": int(e.occurrence_index),
			"header_key_occurrence_index": int(e.header_key_occurrence_index),
			"key": e.full_key(),
			"factory_value": fentry.value_raw,
			"origin": "FACTORY_OCCURRENCE",
		}
		if str(e.value_raw) == str(fentry.value_raw):
			return false
		current_doc.set_entry_value(e, fentry.value_raw)
		_after_edit()
		_rebuild_inspector()
		_set_status("Reset [%s#%d] %s to factory default (%s)" % [e.header, int(e.occurrence_index), e.full_key(), fentry.value_raw], "success")
		return true
	else:
		var cls := classify_absent_factory_property(current_doc, e)
		var removed_key := "[%s] %s" % [e.header, e.full_key()]
		last_property_reset_info = {
			"action": "REMOVE_ABSENT_FROM_FACTORY",
			"header": e.header,
			"header_id": e.header_id,
			"occurrence_index": int(e.occurrence_index),
			"key": e.full_key(),
			"origin": str(cls.get("origin", "UNKNOWN_PROPERTY")),
			"label": str(cls.get("label", "")),
			"parent_source": str(cls.get("parent_source", "")),
		}
		current_doc.remove_entry(e)
		_after_edit()
		_rebuild_inspector()
		var orig := str(cls.get("origin", "UNKNOWN_PROPERTY"))
		if orig == "INHERITED_OVERRIDE" or orig == "MOD_PROVIDED_PROPERTY":
			_set_status("Removed local override %s (reverted to %s)" % [removed_key, str(cls.get("label", "inherited default"))], "success")
		else:
			_set_status("Removed %s (%s)" % [removed_key, str(cls.get("label", orig))], "success")
		return true


func _capture_reset_confirmation_snapshot(paths: Array, scope_label: String) -> Dictionary:
	_reset_impact_rev += 1
	var ident_map: Dictionary = {}
	var working_hashes: Dictionary = {}
	for raw_p in paths:
		var sp := str(raw_p)
		if sp == "":
			continue
		var ck := WorkspaceStore.canonical(sp)
		var norm := ck.to_lower() if OS.get_name() == "Windows" else ck
		ident_map[norm] = ck
		var w_md5 := ""
		var s_md5 := ""
		var is_dirty := false
		var has_ov := false
		var cdoc = OdfDocument.cached(sp)
		if cdoc == null:
			for k in OdfDocument._cache.keys():
				if WorkspaceStore._same_canon_path(str(k), sp):
					cdoc = OdfDocument._cache[k]
					break
		if cdoc is OdfDocument:
			w_md5 = WorkspaceStore._md5_bytes(cdoc.to_bytes())
			is_dirty = bool(cdoc.dirty)
			has_ov = bool(cdoc.workspace_override)
		var ws_ent := WorkspaceStore.entry_for(sp)
		if not ws_ent.is_empty():
			has_ov = true
			var wrel := WorkspaceStore.clean_rel(str(ws_ent.get("rel", "")))
			if wrel != "":
				var wabs := ProjectSettings.globalize_path(WorkspaceStore.odf_dir().path_join(wrel))
				if FileAccess.file_exists(wabs):
					s_md5 = WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(wabs))
		if w_md5 == "" and s_md5 != "":
			w_md5 = s_md5
		working_hashes[norm] = {
			"working_md5": w_md5,
			"saved_md5": s_md5,
			"dirty": is_dirty,
			"has_override": has_ov,
		}
	var ids: Array[String] = []
	for k in ident_map.keys():
		ids.append(str(k))
	ids.sort()
	return {
		"impact_revision": _reset_impact_rev,
		"scope": scope_label,
		"affected_resource_identities": ids,
		"working_hashes": working_hashes,
		"manifest_revision": WorkspaceStore.manifest_fingerprint(),
		"confirmation_nonce": "cnf_%d_%d" % [Time.get_ticks_usec(), randi() % 100000],
	}


static func _reset_snapshots_match(expected: Dictionary, current: Dictionary) -> bool:
	if expected.is_empty() or current.is_empty():
		return false
	if str(expected.get("manifest_revision", "")) != str(current.get("manifest_revision", "")):
		return false
	var a_ids: Array = expected.get("affected_resource_identities", [])
	var b_ids: Array = current.get("affected_resource_identities", [])
	if a_ids.size() != b_ids.size():
		return false
	for i in a_ids.size():
		if str(a_ids[i]) != str(b_ids[i]):
			return false
	var a_h: Dictionary = expected.get("working_hashes", {})
	var b_h: Dictionary = current.get("working_hashes", {})
	if a_h.size() != b_h.size():
		return false
	for k in a_h:
		if not b_h.has(k):
			return false
		var ha: Dictionary = a_h[k]
		var hb: Dictionary = b_h[k]
		if str(ha.get("working_md5", "")) != str(hb.get("working_md5", "")):
			return false
		if str(ha.get("saved_md5", "")) != str(hb.get("saved_md5", "")):
			return false
		if bool(ha.get("dirty", false)) != bool(hb.get("dirty", false)):
			return false
		if bool(ha.get("has_override", false)) != bool(hb.get("has_override", false)):
			return false
	return true


func request_reset_current_doc() -> Dictionary:
	if current_doc == null or current_doc.source_path == "":
		_set_status("Reset ODF: no document open.", "warning")
		last_reset_doc_result = {"ok": false, "status": "NO_DOCUMENT"}
		return last_reset_doc_result
	var sp := current_doc.source_path
	var has_ws := not WorkspaceStore.entry_for(sp).is_empty() or bool(current_doc.workspace_override)
	var is_dirty := bool(current_doc.dirty)
	var src_ok := FileAccess.file_exists(sp)
	var snap := _capture_reset_confirmation_snapshot([sp], "RESET_CURRENT_DOCUMENT")
	_pending_reset_doc_snapshot = snap
	var preview := {
		"scope": "RESET_CURRENT_DOCUMENT",
		"path": sp,
		"dirty": is_dirty,
		"workspace_override": has_ws,
		"source_conflict": bool(current_doc.workspace_conflict),
		"source_exists": src_ok,
		"confirmation_snapshot": snap,
		"confirmation_nonce": str(snap.get("confirmation_nonce", "")),
	}
	reset_doc_confirmation_pending = true
	if reset_doc_dialog != null:
		reset_doc_dialog.dialog_text = "Reset current ODF to factory default?\n\nFile: %s\nUnsaved edits: %s\nSaved workspace override: %s\nSource conflict: %s\nSnapshot rev: #%d\n\nA durable recovery point preserving BOTH saved override and unsaved working edits will be created before reset." % [
			sp, "YES" if is_dirty else "no", "YES" if has_ws else "no", "YES" if bool(current_doc.workspace_conflict) else "no", int(snap.get("impact_revision", 0))
		]
		if is_inside_tree():
			reset_doc_dialog.popup_centered()
	_set_status("Confirm Reset ODF for %s (no files changed yet)." % sp.get_file(), "warning")
	last_reset_doc_result = {
		"ok": false,
		"status": "CONFIRMATION_REQUIRED",
		"confirmation_required": true,
		"impact": preview,
		"confirmation_snapshot": snap,
		"confirmation_nonce": str(snap.get("confirmation_nonce", "")),
	}
	return last_reset_doc_result


func cancel_reset_current_doc() -> void:
	reset_doc_confirmation_pending = false
	_pending_reset_doc_snapshot.clear()
	if reset_doc_dialog != null and reset_doc_dialog.visible:
		reset_doc_dialog.hide()
	_set_status("Reset ODF cancelled; current document preserved.", "muted")


func confirm_reset_current_doc_ex(expected_nonce: String = "") -> Dictionary:
	if current_doc == null or current_doc.source_path == "":
		reset_doc_confirmation_pending = false
		_pending_reset_doc_snapshot.clear()
		last_reset_doc_result = {"ok": false, "status": "NO_DOCUMENT", "outcome": "NO_DOCUMENT"}
		return last_reset_doc_result
	if not _pending_reset_doc_snapshot.is_empty():
		var fresh := _capture_reset_confirmation_snapshot([current_doc.source_path], "RESET_CURRENT_DOCUMENT")
		var nonce_ok := expected_nonce == "" or expected_nonce == str(_pending_reset_doc_snapshot.get("confirmation_nonce", ""))
		if not nonce_ok or not _reset_snapshots_match(_pending_reset_doc_snapshot, fresh):
			var prev_snap := _pending_reset_doc_snapshot.duplicate(true)
			_pending_reset_doc_snapshot = fresh
			reset_doc_confirmation_pending = true
			if reset_doc_dialog != null:
				reset_doc_dialog.dialog_text = "STATE CHANGED BEFORE APPROVAL — PLEASE RE-CONFIRM\n\nFile: %s\nSnapshot rev: #%d\nDocument or workspace state changed since confirmation opened." % [
					current_doc.source_path, int(fresh.get("impact_revision", 0))
				]
				if is_inside_tree():
					reset_doc_dialog.popup_centered()
			_set_status("Reset ODF requires renewed confirmation: document/workspace changed since preview.", "warning")
			last_reset_doc_result = {
				"ok": false,
				"status": "IMPACT_CHANGED_RECONFIRM_REQUIRED",
				"reconfirmation_required": true,
				"confirmation_required": true,
				"previous_snapshot": prev_snap,
				"confirmation_snapshot": fresh,
				"confirmation_nonce": str(fresh.get("confirmation_nonce", "")),
			}
			return last_reset_doc_result
	reset_doc_confirmation_pending = false
	_pending_reset_doc_snapshot.clear()
	if reset_doc_dialog != null and reset_doc_dialog.visible:
		reset_doc_dialog.hide()
	return reset_current_doc_to_default_ex()


func confirm_reset_current_doc() -> bool:
	return bool(confirm_reset_current_doc_ex().get("ok", false))


func reset_current_doc_to_default_ex() -> Dictionary:
	if current_doc == null or current_doc.source_path == "":
		_set_status("Reset ODF: no document open.", "warning")
		last_reset_doc_result = {"ok": false, "status": "NO_DOCUMENT", "outcome": "NO_DOCUMENT"}
		return last_reset_doc_result
	var sp := current_doc.source_path
	var res := WorkspaceStore.revert_document(current_doc)
	last_reset_doc_result = res
	if not bool(res.get("ok", false)):
		_set_status("Reset ODF failed (%s / %s): %s" % [
			str(res.get("outcome", "RESET_FAILED_RECOVERABLE")),
			str(res.get("status", "FAILED")),
			str(res.get("error", "persistent workspace state unchanged")),
		], "danger")
		return res
	if not raw_edit.has_focus():
		raw_edit.text = current_doc.text
	_rebuild_inspector()
	_refresh_dependencies()
	_propagate_document_change(true)
	if str(res.get("status", "")) == "NO_OVERRIDE":
		_set_status("%s already matches factory default." % sp.get_file(), "muted")
	elif str(res.get("status", "")) == "SOURCE_CHANGED":
		_set_status("Reset %s to current on-disk source (recovery point: %s)." % [sp.get_file(), str(res.get("transaction_id", ""))], "warning")
	else:
		_set_status("Reset %s to factory default (recovery point: %s)." % [sp.get_file(), str(res.get("transaction_id", ""))], "success")
	return res


func reset_current_doc_to_default() -> bool:
	return bool(reset_current_doc_to_default_ex().get("ok", false))


## Step 1 (P0-01): Compute a complete deduplicated impact preview BEFORE any
## destructive mutation occurs.
func preview_reset_all_impact() -> Dictionary:
	var unique_sources: Dictionary = {}  # canon_lc -> original path
	var unsaved_dirty: Array[String] = []
	var saved_overrides: Array[String] = []
	var ext_particles: Array[String] = []
	var weapon_deps: Array[String] = []
	var conflicts: Array[String] = []
	var cannot_restore: Array[String] = []
	var seen_dirty := {}
	var seen_saved := {}
	var seen_conf := {}
	var seen_miss := {}
	var seen_ext := {}

	for path in OdfDocument._cache.keys():
		var d = OdfDocument._cache[path]
		if d is OdfDocument and str(d.source_path) != "" and (d.dirty or d.workspace_override):
			var sp := str(d.source_path)
			var ckey := WorkspaceStore.canonical(sp)
			if OS.get_name() == "Windows":
				ckey = ckey.to_lower()
			unique_sources[ckey] = sp
			if d.dirty and not seen_dirty.has(ckey):
				seen_dirty[ckey] = true
				unsaved_dirty.append(sp)
			if d.workspace_override and not seen_saved.has(ckey):
				seen_saved[ckey] = true
				saved_overrides.append(sp)
			if d.workspace_conflict and not seen_conf.has(ckey):
				seen_conf[ckey] = true
				conflicts.append(sp)
			if not FileAccess.file_exists(sp) and not seen_miss.has(ckey):
				seen_miss[ckey] = true
				cannot_restore.append(sp)

	for rec in WorkspaceStore.entries():
		if not (rec is Dictionary):
			continue
		var src_p := str(rec.get("source", ""))
		if src_p == "":
			continue
		var ckey2 := WorkspaceStore.canonical(src_p)
		if OS.get_name() == "Windows":
			ckey2 = ckey2.to_lower()
		if not unique_sources.has(ckey2):
			unique_sources[ckey2] = src_p
		if not seen_saved.has(ckey2):
			seen_saved[ckey2] = true
			saved_overrides.append(src_p)
		if not FileAccess.file_exists(src_p):
			if not seen_miss.has(ckey2):
				seen_miss[ckey2] = true
				cannot_restore.append(src_p)
		else:
			var smd5 := str(rec.get("source_md5", ""))
			if smd5 != "" and WorkspaceStore.source_md5(src_p) != smd5 and not seen_conf.has(ckey2):
				seen_conf[ckey2] = true
				conflicts.append(src_p)

	# Referenced external particle files in Particle Lab
	if particle_lab != null:
		for ext_k in particle_lab._external_nodes:
			var ep := str((particle_lab._external_nodes[ext_k] as Dictionary).get("path", ""))
			if ep != "":
				var ek := WorkspaceStore.canonical(ep).to_lower()
				if unique_sources.has(ek) and not seen_ext.has(ek):
					seen_ext[ek] = true
					ext_particles.append(ep)

	# Affected weapon dependencies in Weapons Lab chain
	if weapon_lab != null and weapon_lab.profile != null:
		var p := weapon_lab.profile
		for wp in [p.shooter_path, p.weapon_path, p.ordnance_path, p.target_path]:
			if wp != "":
				var wk := WorkspaceStore.canonical(wp).to_lower()
				if unique_sources.has(wk) and not weapon_deps.has(wp):
					weapon_deps.append(wp)

	var affected_files: Array[String] = []
	var ckeys := unique_sources.keys()
	ckeys.sort()
	for ck in ckeys:
		affected_files.append(str(unique_sources[ck]))

	var preview := {
		"scope": "RESET_ALL_WORKSPACE_OVERRIDES",
		"total_affected_count": affected_files.size(),
		"affected_files": affected_files,
		"unsaved_dirty_documents": unsaved_dirty,
		"saved_workspace_overrides": saved_overrides,
		"referenced_external_particles": ext_particles,
		"affected_weapon_dependencies": weapon_deps,
		"files_with_source_conflicts": conflicts,
		"files_cannot_restore": cannot_restore,
	}
	last_reset_impact_preview = preview
	return preview


func _format_reset_all_dialog_text(preview: Dictionary, snap: Dictionary, banner: String = "") -> String:
	var total := int(preview.get("total_affected_count", 0))
	var lines: Array[String] = []
	if banner != "":
		lines.append(banner)
		lines.append("")
	lines.append("RESET ALL WORKSPACE OVERRIDES — IMPACT PREVIEW (Snapshot #%d)" % int(snap.get("impact_revision", 0)))
	if _pending_project_config_reset:
		lines.append("Includes UI appearance + Mod Loadout reset upon confirmation.")
	lines.append("")
	lines.append("Total affected unique ODFs: %d" % total)
	lines.append("• Unsaved dirty documents: %d" % (preview.unsaved_dirty_documents as Array).size())
	lines.append("• Saved workspace overrides: %d" % (preview.saved_workspace_overrides as Array).size())
	lines.append("• Referenced external particle files: %d" % (preview.referenced_external_particles as Array).size())
	lines.append("• Affected weapon dependencies: %d" % (preview.affected_weapon_dependencies as Array).size())
	lines.append("• Files with source conflicts: %d" % (preview.files_with_source_conflicts as Array).size())
	lines.append("• Files that cannot be restored (source missing): %d" % (preview.files_cannot_restore as Array).size())
	lines.append("")
	lines.append("Affected resources:")
	var shown := 0
	for af in preview.affected_files:
		if shown >= 20:
			lines.append("  … and %d more" % (total - shown))
			break
		lines.append("  • " + str(af))
		shown += 1
	lines.append("")
	lines.append("A durable recovery point will be created before any reset.")
	return "\n".join(lines)


## Step 2 (P0-01 / P1-04): Request explicit confirmation bound to an exact
## impact snapshot. Performs ZERO mutations before user confirmation.
func request_reset_all_odfs() -> Dictionary:
	var preview := preview_reset_all_impact()
	var total := int(preview.get("total_affected_count", 0))
	if total == 0:
		_pending_reset_all_snapshot.clear()
		reset_all_confirmation_pending = false
		_set_status("Reset All: no unsaved edits or saved workspace overrides to reset.", "muted")
		last_reset_all_report = {
			"ok": true,
			"status": "NO_CHANGES",
			"confirmation_required": false,
			"impact": preview,
			"requested": 0,
			"attempted": 0,
			"succeeded": 0,
			"failed": 0,
			"skipped": 0,
			"already_default": 0,
			"recovery_pending": 0,
			"succeeded_files": [],
			"failed_files": [],
		}
		return last_reset_all_report
	var snap := _capture_reset_confirmation_snapshot(preview.get("affected_files", []), "RESET_ALL_WORKSPACE_OVERRIDES")
	_pending_reset_all_snapshot = snap
	preview["confirmation_snapshot"] = snap
	preview["confirmation_nonce"] = str(snap.get("confirmation_nonce", ""))
	last_reset_impact_preview = preview
	reset_all_confirmation_pending = true
	if reset_all_dialog != null:
		reset_all_dialog.dialog_text = _format_reset_all_dialog_text(preview, snap)
		if is_inside_tree():
			reset_all_dialog.popup_centered()
	_set_status("Reset All requires confirmation (%d affected ODF(s); nothing changed yet)." % total, "warning")
	return {
		"ok": false,
		"status": "CONFIRMATION_REQUIRED",
		"confirmation_required": true,
		"impact": preview,
		"confirmation_snapshot": snap,
		"confirmation_nonce": str(snap.get("confirmation_nonce", "")),
		"requested": total,
		"attempted": 0,
		"succeeded": 0,
		"failed": 0,
		"skipped": total,
		"already_default": 0,
		"recovery_pending": 0,
		"succeeded_files": [],
		"failed_files": [],
	}


func cancel_reset_all_odfs() -> void:
	reset_all_confirmation_pending = false
	_pending_reset_all_snapshot.clear()
	_pending_project_config_reset = false
	if reset_all_dialog != null and reset_all_dialog.visible:
		reset_all_dialog.hide()
	_set_status("Reset All cancelled; all edits, project settings, and workspace overrides preserved.", "muted")


## P1-04 / RST-21: Confirm Reset All ONLY if live workspace state still matches
## the approved confirmation snapshot; if anything changed since preview, refresh
## the impact preview and require renewed confirmation without mutating files.
func confirm_reset_all_odfs(expected_nonce: String = "") -> Dictionary:
	var fresh_preview := preview_reset_all_impact()
	var fresh_snap := _capture_reset_confirmation_snapshot(fresh_preview.get("affected_files", []), "RESET_ALL_WORKSPACE_OVERRIDES")
	if not _pending_reset_all_snapshot.is_empty():
		var nonce_ok := expected_nonce == "" or expected_nonce == str(_pending_reset_all_snapshot.get("confirmation_nonce", ""))
		if not nonce_ok or not _reset_snapshots_match(_pending_reset_all_snapshot, fresh_snap):
			var prev_snap := _pending_reset_all_snapshot.duplicate(true)
			_pending_reset_all_snapshot = fresh_snap
			fresh_preview["confirmation_snapshot"] = fresh_snap
			fresh_preview["confirmation_nonce"] = str(fresh_snap.get("confirmation_nonce", ""))
			last_reset_impact_preview = fresh_preview
			reset_all_confirmation_pending = true
			if reset_all_dialog != null:
				reset_all_dialog.dialog_text = _format_reset_all_dialog_text(
					fresh_preview, fresh_snap,
					"WORKSPACE CHANGED BEFORE APPROVAL — REVIEW UPDATED IMPACT AND RE-CONFIRM"
				)
				if is_inside_tree():
					reset_all_dialog.popup_centered()
			_set_status("Reset All blocked: workspace state changed since confirmation opened; please re-confirm.", "warning")
			last_reset_all_report = {
				"ok": false,
				"status": "IMPACT_CHANGED_RECONFIRM_REQUIRED",
				"reconfirmation_required": true,
				"confirmation_required": true,
				"impact": fresh_preview,
				"previous_snapshot": prev_snap,
				"confirmation_snapshot": fresh_snap,
				"confirmation_nonce": str(fresh_snap.get("confirmation_nonce", "")),
				"requested": int(fresh_preview.get("total_affected_count", 0)),
				"attempted": 0,
				"succeeded": 0,
				"failed": 0,
				"skipped": int(fresh_preview.get("total_affected_count", 0)),
				"already_default": 0,
				"recovery_pending": 0,
				"succeeded_files": [],
				"failed_files": [],
			}
			return last_reset_all_report
	var apply_proj_cfg := _pending_project_config_reset
	reset_all_confirmation_pending = false
	_pending_reset_all_snapshot.clear()
	_pending_project_config_reset = false
	if reset_all_dialog != null and reset_all_dialog.visible:
		reset_all_dialog.hide()
	var targets: Array = fresh_preview.get("affected_files", [])
	var report := _execute_transaction_reset(targets, "RESET_ALL_WORKSPACE_OVERRIDES")
	report["impact"] = fresh_preview
	report["confirmation_snapshot"] = fresh_snap
	if apply_proj_cfg and (bool(report.get("ok", false)) or str(report.get("status", "")) == "NO_CHANGES"):
		reset_ui_to_default()
		reset_mod_loadout_to_default()
		report["scope"] = "RESET_PROJECT_CONFIGURATION"
		report["project_config_reset"] = true
		report["active_loadout"] = active_loadout_id
	last_reset_all_report = report
	return report


## Explicit RESET SELECTED DOCUMENTS scope (P0-01).
func reset_selected_odfs_to_default(source_paths: Array, confirmed: bool = true) -> Dictionary:
	if not confirmed:
		return {
			"ok": false,
			"status": "CONFIRMATION_REQUIRED",
			"confirmation_required": true,
			"requested": source_paths.size(),
			"attempted": 0,
			"succeeded": 0,
			"failed": 0,
			"skipped": source_paths.size(),
			"already_default": 0,
			"recovery_pending": 0,
		}
	return _execute_transaction_reset(source_paths, "RESET_SELECTED_DOCUMENTS")


## Transaction-aware Reset All (P0-01 + P1-01):
## Calling without confirmation (`confirmed = false`) previews impact and opens
## the confirmation dialog without mutating any data.
func reset_all_odfs_to_default(confirmed: bool = false) -> Dictionary:
	if not confirmed:
		return request_reset_all_odfs()
	var preview := preview_reset_all_impact()
	var targets: Array = preview.get("affected_files", [])
	var report := _execute_transaction_reset(targets, "RESET_ALL_WORKSPACE_OVERRIDES")
	report["impact"] = preview
	last_reset_all_report = report
	return report


func _execute_transaction_reset(raw_sources: Array, scope_label: String) -> Dictionary:
	# Deduplicate strictly by canonical source identity (P1-01).
	var unique_paths: Array[String] = []
	var seen := {}
	for raw_p in raw_sources:
		var sp := str(raw_p)
		if sp == "":
			continue
		var ck := WorkspaceStore.canonical(sp)
		if OS.get_name() == "Windows":
			ck = ck.to_lower()
		if seen.has(ck):
			continue
		seen[ck] = true
		unique_paths.append(sp)

	var requested := unique_paths.size()
	if requested == 0:
		return {
			"ok": true,
			"status": "NO_CHANGES",
			"scope": scope_label,
			"transaction_id": "",
			"recovery_point": "",
			"requested": 0,
			"attempted": 0,
			"succeeded": 0,
			"failed": 0,
			"skipped": 0,
			"already_default": 0,
			"recovery_pending": 0,
			"succeeded_files": [],
			"failed_files": [],
			"results": {},
		}

	# Step 3: Durable recovery point BEFORE any destructive mutation.
	var rec_pt := WorkspaceStore.create_reset_recovery_point(unique_paths, scope_label)
	if not bool(rec_pt.get("ok", false)):
		_set_status("Reset aborted: recovery point creation failed (%s). No files were changed." % str(rec_pt.get("error", "")), "danger")
		return {
			"ok": false,
			"status": str(rec_pt.get("status", "BACKUP_FAILED")),
			"outcome": "RESET_FAILED_RECOVERABLE",
			"scope": scope_label,
			"transaction_id": str(rec_pt.get("transaction_id", "")),
			"recovery_point": str(rec_pt.get("path", "")),
			"requested": requested,
			"attempted": 0,
			"succeeded": 0,
			"failed": requested,
			"skipped": requested,
			"already_default": 0,
			"recovery_pending": 0,
			"succeeded_files": [],
			"failed_files": [{"error": str(rec_pt.get("error", "backup failed"))}],
			"results": {},
		}

	var tx_path := str(rec_pt.get("path", ""))
	var tx_id := str(rec_pt.get("transaction_id", ""))
	var attempted := 0
	var succeeded := 0
	var failed := 0
	var skipped := 0
	var already_default := 0
	var recovery_pending := 0
	var succeeded_files: Array[String] = []
	var failed_files: Array[Dictionary] = []
	var per_file_results: Dictionary = {}

	# Step 4: Execute each unique file once and inspect structured outcomes.
	for sp in unique_paths:
		attempted += 1
		var cdoc = OdfDocument.cached(sp)
		if cdoc == null:
			for k in OdfDocument._cache.keys():
				if WorkspaceStore._same_canon_path(str(k), sp):
					cdoc = OdfDocument._cache[k]
					break
		var rres: Dictionary
		if cdoc is OdfDocument:
			rres = WorkspaceStore.revert_document(cdoc, true)
		else:
			if not FileAccess.file_exists(sp):
				rres = {
					"ok": false,
					"status": "SOURCE_MISSING",
					"outcome": "SOURCE_MISSING",
					"recovery_pending": false,
					"error": "original source file is missing: " + sp,
				}
			else:
				var dres := WorkspaceStore.discard_override_ex(sp)
				if bool(dres.get("ok", false)):
					OdfDocument.invalidate_cache(sp)
					rres = {
						"ok": true,
						"status": "SOURCE_CHANGED" if bool(dres.get("source_changed", false)) else "SUCCESS",
						"outcome": "SUCCESS",
						"recovery_pending": false,
						"backup": str(dres.get("backup", "")),
						"error": "",
					}
				elif str(dres.get("status", "")) == "NOT_FOUND":
					rres = {
						"ok": true,
						"status": "NO_OVERRIDE",
						"outcome": "NO_OVERRIDE",
						"recovery_pending": false,
						"error": "",
					}
				else:
					var raw_st := str(dres.get("status", ""))
					var is_rp := raw_st == WorkspaceStore.TX_RECOVERY_PENDING or raw_st == "MANIFEST_UNCHANGED"
					rres = {
						"ok": false,
						"status": "RECOVERY_PENDING" if raw_st == WorkspaceStore.TX_RECOVERY_PENDING else ("BACKUP_FAILED" if raw_st == "BACKUP_FAILED" else "MANIFEST_FAILED"),
						"outcome": "RESET_FAILED_RECOVERABLE",
						"recovery_pending": is_rp,
						"backup": str(dres.get("backup", "")),
						"error": str(dres.get("error", "discard failed")),
					}
		per_file_results[sp] = rres
		if bool(rres.get("ok", false)):
			if str(rres.get("status", "")) == "NO_OVERRIDE":
				already_default += 1
			else:
				succeeded += 1
				succeeded_files.append(sp)
		else:
			failed += 1
			if bool(rres.get("recovery_pending", false)):
				recovery_pending += 1
			failed_files.append({
				"path": sp,
				"status": str(rres.get("status", "FAILED")),
				"outcome": str(rres.get("outcome", "RESET_FAILED_RECOVERABLE")),
				"error": str(rres.get("error", "")),
				"backup": str(rres.get("backup", "")),
			})

	var final_status := "SUCCESS" if failed == 0 else ("PARTIAL_FAILURE" if succeeded > 0 else "RESET_FAILED_RECOVERABLE")
	WorkspaceStore.finalize_reset_recovery_point(tx_path, final_status, {
		"requested": requested,
		"attempted": attempted,
		"succeeded": succeeded,
		"failed": failed,
		"already_default": already_default,
		"recovery_pending": recovery_pending,
	})

	# Step 5: Reconcile all live editors and simulations.
	if current_doc != null and current_doc.source_path != "":
		open_document(current_doc.source_path)
	if weapon_lab != null and shooter_path != "" and target_path != "":
		weapon_lab.reload_after_raw_edit()
	if particle_lab != null and particle_lab.doc != null:
		particle_lab.load_document(particle_lab.doc)
	if audio_lab != null and current_doc != null:
		audio_lab.set_document(current_doc)

	if failed == 0:
		_set_status("Reset %d of %d ODF(s) to factory defaults (recovery point: %s)." % [succeeded, requested, tx_id], "success")
	else:
		_set_status("Reset partial failure: %d succeeded, %d failed (%d recovery pending). Recovery point preserved: %s" % [
			succeeded, failed, recovery_pending, tx_id
		], "danger")

	return {
		"ok": failed == 0 and recovery_pending == 0,
		"status": final_status,
		"outcome": "SUCCESS" if failed == 0 else "RESET_FAILED_RECOVERABLE",
		"scope": scope_label,
		"transaction_id": tx_id,
		"recovery_point": tx_path,
		"requested": requested,
		"attempted": attempted,
		"succeeded": succeeded,
		"failed": failed,
		"skipped": skipped,
		"already_default": already_default,
		"recovery_pending": recovery_pending,
		"succeeded_files": succeeded_files,
		"failed_files": failed_files,
		"results": per_file_results,
	}


func _bind_rmb_reset(ctrl: Control, e) -> void:
	if ctrl == null or e == null:
		return
	ctrl.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				reset_entry_to_default(e)
				ctrl.accept_event()
	)


func _add_entry_row(parent: VBoxContainer, e) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	var fdoc := _get_factory_doc(current_doc.source_path) if current_doc != null else null
	var fentry = fdoc.find_matching_entry(e) if fdoc != null else null
	var is_modified: bool = (fentry == null) or (str(fentry.value_raw).strip_edges() != str(e.value_raw).strip_edges())
	var key := Label.new()
	key.text = e.full_key()
	key.tooltip_text = _entry_tooltip(e)
	key.custom_minimum_size = Vector2(180, 0)
	key.clip_text = true
	if e.shadowed_by != null:
		key.add_theme_color_override("font_color", Color("#95804C"))
		key.text = e.full_key() + " (shadowed)"
	elif e.shadow_of != null:
		key.add_theme_color_override("font_color", Color("#969630"))
		key.text = e.full_key() + " (effective)"
	elif is_modified:
		key.add_theme_color_override("font_color", Color("#F0D060"))
	row.add_child(key)
	var control: Control
	if show_raw_values:
		control = _raw_editor_for(e)
	else:
		control = _control_for(e, fentry)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Right-click on any non-scrubber value control also resets to factory default.
	if not control.has_method("begin_ladder"):
		_bind_rmb_reset(control, e)
		if control is HBoxContainer:
			for ch in control.get_children():
				if ch is Control and not ch.has_method("begin_ladder"):
					_bind_rmb_reset(ch as Control, e)
	row.add_child(control)
	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.focus_mode = Control.FOCUS_NONE
	if fentry != null:
		reset_btn.tooltip_text = "Reset [%s#%d] %s to factory default (%s) [or Right-Click value]" % [e.header, int(e.occurrence_index), e.full_key(), fentry.value_raw]
	else:
		var cls := classify_absent_factory_property(current_doc, e)
		reset_btn.tooltip_text = "Remove [%s] %s (%s) [or Right-Click value]" % [e.header, e.full_key(), str(cls.get("label", "local property"))]
	reset_btn.pressed.connect(func(): reset_entry_to_default(e))
	row.add_child(reset_btn)
	if e.shadowed_by != null:
		var tag := Label.new()
		tag.text = "overridden"
		tag.add_theme_color_override("font_color", Color("#95804C"))
		tag.add_theme_font_size_override("font_size", 10)
		row.add_child(tag)


func _entry_tooltip(e) -> String:
	var info := schema.property_info(e.header, e.key_raw)
	var lines: Array[String] = []
	lines.append("line %d  ·  [%s] %s" % [e.line, e.header, e.full_key()])
	if not info.is_empty():
		lines.append("defined in: " + str(info.get("definedIn", e.header)))
		var d: String = str(info.get("description", ""))
		if d != "":
			lines.append(d)
		lines.append("documented default: " + schema.documented_default(e.header, e.key_raw))
		lines.append("source: docs/%s line %s" % [str(info.get("doc", "ODF.md")), str(info.get("docLine", "?"))])
	else:
		lines.append("Not found in the extracted documentation registry — raw editing allowed.")
	lines.append("raw: " + e.value_raw)
	lines.append("effective: " + e.core_value())
	if e.comment != "":
		lines.append("comment: " + e.comment)
	return "\n".join(lines)


func _raw_editor_for(e) -> Control:
	var le := LineEdit.new()
	le.text = e.value_raw
	le.tooltip_text = _entry_tooltip(e)
	var apply := func(t: String) -> void:
		current_doc.set_entry_value(e, t)
		_after_edit()
	le.text_submitted.connect(apply)
	le.focus_exited.connect(_on_raw_committed.bind(le, e))
	return le


func _on_raw_committed(le: LineEdit, e) -> void:
	if current_doc != null and le.text != e.value_raw:
		current_doc.set_entry_value(e, le.text)
		_after_edit()


func _control_for(e, fentry = null) -> Control:
	var t: String = schema.infer_type(e.header, e.key_raw, e.value_raw)
	var core: String = e.core_value()
	match t:
		"bool":
			var cb := CheckButton.new()
			cb.button_pressed = current_doc.get_bool(e.header, e.key_raw, false)
			cb.text = "true"
			cb.tooltip_text = _entry_tooltip(e)
			cb.toggled.connect(func(on: bool):
				cb.text = "true" if on else "false"
				current_doc.set_entry_value(e, "true" if on else "false")
				_after_edit()
			)
			return cb
		"int":
			var sb = HoudiniScrubberScript.new()
			var iv := core.to_float() if not core.begins_with("0x") else float(core.hex_to_int())
			sb.configure(-1000000000.0, 1000000000.0, 1.0, iv, "", true, true, true)
			sb.set_exact_value(iv, core)
			if fentry != null:
				var fcore := str(fentry.core_value())
				sb.set_default_value(fcore.to_float() if not fcore.begins_with("0x") else float(fcore.hex_to_int()))
			sb.set_pill_width(68)
			sb.tooltip_text = "Slide, LMB drag, MMB Houdini Value Ladder, RMB reset to default\n" + _entry_tooltip(e)
			sb.value_changed.connect(func(v: float):
				if show_raw_values:
					return
				current_doc.set_entry_value(e, _fmt_num(v, false))
				_after_edit()
			)
			return sb
		"float":
			var sf = HoudiniScrubberScript.new()
			var fv := core.to_float()
			sf.configure(-1e12, 1e12, 0.01, fv, "", true, true, false)
			sf.set_exact_value(fv, core)
			if fentry != null:
				sf.set_default_value(str(fentry.core_value()).to_float())
			sf.set_pill_width(68)
			sf.tooltip_text = "Slide, LMB drag, MMB Houdini Value Ladder, RMB reset to default\n" + _entry_tooltip(e)
			sf.value_changed.connect(func(v: float):
				current_doc.set_entry_value(e, _fmt_num(v, true))
				_after_edit()
			)
			return sf
		"vector3":
			var hb := HBoxContainer.new()
			hb.add_theme_constant_override("separation", 3)
			var parts := core.split(" ", false)
			var fparts := str(fentry.core_value()).split(" ", false) if fentry != null else PackedStringArray()
			var axes := ["X:", "Y:", "Z:"]
			for axis in range(3):
				var sx = HoudiniScrubberScript.new()
				var av := parts[axis].to_float() if parts.size() > axis else 0.0
				var fav := fparts[axis].to_float() if fparts.size() > axis else av
				sx.configure(-1e9, 1e9, 0.05, av, "", false, true, false)
				sx.set_default_value(fav)
				sx.prefix = axes[axis]
				sx.set_pill_width(58)
				sx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sx.tooltip_text = "XYZ axis " + str(axis) + " (LMB drag / MMB Value Ladder / RMB reset to default)\n" + _entry_tooltip(e)
				sx.value_changed.connect(func(_v: float): _write_vector(e, hb))
				hb.add_child(sx)
			return hb
		"color":
			var cp := ColorPickerButton.new()
			cp.color = _parse_color(core)
			cp.custom_minimum_size = Vector2(90, 24)
			cp.tooltip_text = _entry_tooltip(e)
			cp.color_changed.connect(func(c: Color):
				var a := int(round(c.a * 255.0))
				current_doc.set_entry_value(e, "\"%d %d %d %d\"" % [int(round(c.r * 255.0)), int(round(c.g * 255.0)), int(round(c.b * 255.0)), a])
				_after_edit()
			)
			return cp
		"enum":
			var ob := OptionButton.new()
			var values := schema.enum_values(e.header, e.key_raw)
			values = values.duplicate()
			if not values.has(core):
				values.push_front(core)
			for v in values:
				ob.add_item(v)
				if v == core:
					ob.select(ob.item_count - 1)
			ob.tooltip_text = _entry_tooltip(e)
			ob.item_selected.connect(func(i: int):
				var val := ob.get_item_text(i)
				current_doc.set_entry_value(e, "\"" + val + "\"" if schema.infer_type(e.header, e.key_raw, val) == "string" else val)
				_after_edit()
			)
			return ob
		"reference":
			var hb := HBoxContainer.new()
			hb.add_theme_constant_override("separation", 2)
			var le := LineEdit.new()
			le.text = core
			le.tooltip_text = _entry_tooltip(e)
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var commit := func():
				var val := le.text.strip_edges()
				current_doc.set_entry_value(e, "\"" + val + "\"" if val != "" else "\"\"")
				_after_edit()
			le.text_submitted.connect(func(_t): commit.call())
			le.focus_exited.connect(commit)
			hb.add_child(le)
			var open := Button.new()
			open.text = "→"
			open.tooltip_text = "Resolve and open this reference"
			open.pressed.connect(func():
				var hit := index.resolve_path(le.text)
				if hit != "":
					open_document(hit)
				else:
					_set_status("Reference not found: " + le.text, "warning")
			)
			hb.add_child(open)
			return hb
		_:
			var le2 := LineEdit.new()
			le2.text = e.value_raw
			le2.tooltip_text = _entry_tooltip(e)
			var apply2 := func(text: String) -> void:
				current_doc.set_entry_value(e, text)
				_after_edit()
			le2.text_submitted.connect(apply2)
			le2.focus_exited.connect(_on_string_committed.bind(le2, e))
			return le2


func _on_string_committed(le: LineEdit, e) -> void:
	if current_doc != null and le.text != e.value_raw:
		current_doc.set_entry_value(e, le.text)
		_after_edit()



func _write_vector(e, hb: HBoxContainer) -> void:
	var vals: Array[String] = []
	for c in hb.get_children():
		if c.has_method("set_value_no_signal"):
			vals.append(_fmt_num(float(c.value), true))
	current_doc.set_entry_value(e, "\"" + " ".join(PackedStringArray(vals)) + "\"")
	_after_edit()


func _fmt_num(v: float, allow_decimal: bool) -> String:
	if not allow_decimal and abs(v - round(v)) < 0.00001:
		return str(int(round(v)))
	var s := "%.6f" % v
	s = s.rstrip("0").rstrip(".")
	return s if s != "" else "0"


func _parse_color(v: String) -> Color:
	var parts := v.split(" ", false)
	if parts.size() >= 3:
		var r := parts[0].to_float()
		var g := parts[1].to_float()
		var b := parts[2].to_float()
		var a := parts[3].to_float() if parts.size() > 3 else 255.0
		if r > 1.5 or g > 1.5 or b > 1.5 or a > 1.5:
			return Color(r / 255.0, g / 255.0, b / 255.0, a / 255.0)
		return Color(r, g, b, a)
	return Color.WHITE


func _doc_state(doc) -> String:
	if doc == null:
		return ""
	var parts: Array[String] = []
	parts.append("OVERRIDE" if doc.workspace_override else "ORIGINAL")
	if doc.dirty:
		parts.append("DIRTY")
	if doc.workspace_conflict:
		parts.append("CONFLICT")
	return " · ".join(PackedStringArray(parts))


func _update_doc_title() -> void:
	if current_doc == null or inspector_title == null:
		return
	var gname := index.get_game_name(current_doc.source_path) if index != null else ""
	var gtag := (" (\"%s\")" % gname) if gname != "" else ""
	inspector_title.text = current_doc.get_display_name() + gtag + "  [" + _doc_state(current_doc) + "]  ·  " + origin_path


## One propagation path for every document revision. `full_reload` re-resolves
## the dependency chain after undo/raw edits that may change structure.
func _propagate_document_change(full_reload: bool = false) -> void:
	if current_doc == null:
		return
	_update_doc_title()
	dep_timer.start()
	if particle_lab != null and particle_lab.doc != null and particle_lab.doc != current_doc and particle_lab.depends_on_path(current_doc.source_path):
		particle_lab.refresh_if_depends_on(current_doc)
	elif current_doc.is_render_odf() or particle_lab.doc == current_doc:
		particle_lab.load_document(current_doc)
	if audio_lab != null:
		audio_lab.set_document(current_doc)
	if weapon_lab != null:
		if full_reload:
			weapon_lab.reload_after_raw_edit()
		else:
			weapon_lab.refresh_after_edit()
	_update_model_tab()
	_update_doc_title()


func _after_edit() -> void:
	if current_doc == null:
		return
	if not raw_edit.has_focus():
		raw_edit.text = current_doc.text
	_propagate_document_change(false)
	_set_status("Edited — in-memory changes; save to the workspace to keep them", "warning")


func _apply_raw_editor() -> void:
	if current_doc == null:
		return
	# In-place replacement keeps document identity: WeaponProfile and the
	# particle/audio labs hold this exact object and must see the new values.
	current_doc.replace_text(raw_edit.text)
	_rebuild_inspector()
	_refresh_dependencies()
	_propagate_document_change(true)
	_set_status("Raw text applied in place (%d entries parsed, %d warnings)" % [current_doc.entries.size(), current_doc.warnings.size()], "warning")


## Discard unsaved edits only: reload the last saved workspace revision, or
## the original source when no override exists. The manifest is unchanged.
func _reload_saved_revision() -> void:
	if origin_path == "":
		return
	OdfDocument.invalidate_cache(origin_path)
	WorkspaceStore.restore_cache()
	open_document(origin_path)
	_set_status("Discarded unsaved edits; reloaded the last saved revision.", "muted")


func _ask_revert_original() -> void:
	if origin_path == "" or current_doc == null:
		return
	revert_dialog.dialog_text = "Remove the workspace override for:\n\n" + origin_path + "\n\nThe original resource is never modified. Unsaved edits are discarded."
	revert_dialog.popup_centered()


func _do_revert_original() -> void:
	if origin_path == "":
		return
	OdfDocument.invalidate_cache(origin_path)
	var result := WorkspaceStore.discard_override_ex(origin_path)
	open_document(origin_path)
	if bool(result.get("ok", false)):
		var note := ""
		if bool(result.get("source_missing", false)):
			note = " Source file is missing; only the saved override was removed."
		elif bool(result.get("source_changed", false)):
			note = " Source changed on disk since the save; the current source was reloaded."
		_set_status("Workspace override removed; original resource reloaded." + note, "warning" if note != "" else "muted")
	else:
		_set_status("Revert failed (%s): %s" % [str(result.get("status", "")), str(result.get("error", ""))], "danger")


func _undo() -> void:
	if current_doc == null:
		return
	current_doc.undo()
	raw_edit.text = current_doc.text
	_rebuild_inspector()
	_refresh_dependencies()
	_propagate_document_change(true)
	_set_status("Undo.", "muted")


func _redo() -> void:
	if current_doc == null:
		return
	current_doc.redo()
	raw_edit.text = current_doc.text
	_rebuild_inspector()
	_refresh_dependencies()
	_propagate_document_change(true)
	_set_status("Redo.", "muted")


# ---------------------------------------------------------------- dependencies

func _refresh_dependencies() -> void:
	if current_doc == null or dep_summary == null:
		return
	var result := dep_graph.analyze(current_doc, index)
	dep_summary.text = "%d nodes · %d edges · %d missing · %d cycle(s) · %d render node(s)" % [
		result.node_count, result.edge_count, result.missing_count, result.cycle_count, result.render_count
	]
	dep_tree.clear()
	var root := dep_tree.create_item()
	for e in result.edges:
		var item := dep_tree.create_item(root)
		item.set_text(0, str(e.key))
		item.set_text(1, str(e.value))
		if bool(e.resolved):
			var alts: Array[Dictionary] = []
			if str(e.kind) == "odf" or str(e.kind) == "render":
				alts = index.alternatives(str(e.value))
			var suffix := "" if alts.size() <= 1 else "  (%d sources)" % alts.size()
			item.set_text(2, "resolved · " + str(e.to).get_file() + suffix)
			item.set_metadata(0, str(e.to))
			var tip := str(e.to)
			if alts.size() > 1:
				tip += "\n\nAlternatives (precedence order):"
				for a in alts:
					tip += "\n• " + str(a.path)
			item.set_tooltip_text(2, tip)
		else:
			item.set_text(2, "MISSING (" + str(e.kind) + ")")
			item.set_metadata(0, "")
			item.set_custom_color(2, Color("#D37676"))
		if str(e.to) == "":
			continue
	var diag := "[b]Diagnostics[/b]\n\n"
	diag += "Document: %s\n" % current_doc.source_path
	diag += "Encoding: %s%s\n" % [current_doc.encoding, " (BOM)" if current_doc.has_bom else ""]
	diag += "Newline: %s\n" % ("CRLF" if current_doc.text.contains("\r\n") else "LF")
	diag += "Entries: %d   Headers: %d   Effective: %d\n\n" % [current_doc.entries.size(), current_doc.headers.size(), current_doc.effective_entries().size()]
	diag += "[b]Missing references (%d)[/b]\n" % result.missing_count
	for m in result.missing:
		diag += "• %s = %s  (%s)\n" % [str(m.key), str(m.value), str(m.kind)]
	diag += "\n[b]Cycles (%d)[/b]\n" % result.cycle_count
	for c in result.cycles:
		diag += "• %s -> %s (%s)\n" % [str(c.from).get_file(), str(c.to).get_file(), str(c.key)]
	diag += "\n[b]Parser warnings (%d)[/b]\n" % current_doc.warnings.size()
	for w in current_doc.warnings:
		diag += "• %s\n" % w
	var shadowed := 0
	for e in current_doc.entries:
		if e.shadowed_by != null:
			shadowed += 1
	diag += "\n[b]Duplicate declarations shadowed: %d[/b]\n" % shadowed
	if index != null:
		diag += "\n[b]Active ModLoadout Policy[/b]\nPolicy: %s · Strict filter: %s · Packages: %s\n" % [
			index.resolution_policy, str(index.strict_package_filter),
			", ".join(index.active_packages) if not index.active_packages.is_empty() else ("(stock only)" if index.strict_package_filter else "(auto / all)")
		]
		if not index.last_resolution_diagnostics.is_empty():
			diag += "[color=#D37676]Loadout diagnostics (%d):[/color]\n" % index.last_resolution_diagnostics.size()
			var shown_d := 0
			for rd in index.last_resolution_diagnostics:
				if shown_d >= 8:
					break
				diag += "• [%s] %s\n" % [str(rd.get("status", "")), str(rd.get("warning", ""))]
				shown_d += 1
	diag += "\n[b]Fidelity[/b]\nSimulation: APPROXIMATED. Data reading: DATA-DRIVEN (values come from the loaded ODFs). Native verification: none recorded.\n"
	diag_text.text = diag


func _on_dep_activated() -> void:
	var item := dep_tree.get_selected()
	if item == null:
		return
	var path := str(item.get_metadata(0))
	if path != "" and FileAccess.file_exists(path):
		open_document(path)


func _update_model_tab() -> void:
	if model_text == null or current_doc == null:
		return
	var lines: Array[String] = []
	lines.append("[b]Declared asset references[/b]\n")
	var keys := ["shotGeometry", "geometryName", "renderName", "textureName", "fireSound", "shotSound", "explSound"]
	var any := false
	for e in current_doc.effective_entries():
		for k in keys:
			if e.key_raw.to_lower() == str(k).to_lower():
				var val: String = e.core_value()
				if val == "":
					continue
				any = true
				var resolved := ""
				if str(k).to_lower().ends_with("sound"):
					resolved = index.find_asset(val, ["wav", "ogg", "mp3"])
				elif str(k).to_lower().contains("texture"):
					resolved = index.find_asset(val, ["tga", "dds", "png", "jpg"])
				elif str(k).to_lower().contains("geometry"):
					resolved = index.find_asset(val, ["msh", "msha", "fbx", "xsi"])
				lines.append("• [color=#D3B57A]%s[/color] = %s\n   %s" % [e.key_raw, val, resolved if resolved != "" else "[color=#D37676]not indexed[/color]"])
	if not any:
		lines.append("No model/texture/sound references declared.\n")
	# BZCC animation inspection (T-41): show embedded DOCB animation metadata and
	# the companion .msha lookup result without claiming skinning we never decode.
	var geometry_value := ""
	for e in current_doc.effective_entries():
		if e.key_raw.to_lower() == "geometryname":
			geometry_value = e.core_value()
			break
	if geometry_value != "":
		var msh_path := index.find_asset(geometry_value, ["msh"])
		if msh_path != "":
			var anim := BzMeshReaderScript.inspect_animation(msh_path, index, geometry_value)
			lines.append("
[b]BZCC animation inspection[/b]")
			lines.append("• baked model: %s" % msh_path.get_file())
			lines.append("• bones=%d poses=%d animations=%d detected=%s" % [
				int(anim.get("bone_count", 0)), int(anim.get("pose_count", 0)),
				int(anim.get("animation_count", 0)), str(anim.get("animation_detected", false)),
			])
			var msha := str(anim.get("msha_path", ""))
			lines.append("• companion .msha: %s" % (msha.get_file() if msha != "" else "[color=#D37676]not present in indexed roots[/color]"))
			lines.append("[color=#95804C]Only DOCB animation metadata is inspected; skin weights/tracks are not decoded and no skeleton play is claimed.[/color]")
	lines.append("\n[color=#81B681]DOCB .msh models, .material descriptors, DDS/TGA textures and hardpoints load in the Weapons Lab when geometryName resolves to a baked .msh; otherwise an explicit PLACEHOLDER MESH box is shown.[/color]")
	model_text.text = "\n".join(lines)


# ---------------------------------------------------------------- save / export

func _workspace_dir() -> String:
	return WorkspaceStore.odf_dir()


func _relative_for(path: String) -> String:
	var canon := WorkspaceStore.canonical(path)
	for r in index.roots:
		var root := WorkspaceStore.canonical(str(r.get("path", "")))
		if root == "":
			continue
		if WorkspaceStore.is_within(root, canon):
			var prefix := root + "/"
			if OS.get_name() == "Windows":
				return canon.substr(prefix.length())
			return canon.trim_prefix(prefix)
	return path.get_file()


func _on_save_pressed() -> void:
	if current_doc == null:
		_set_status("Nothing to save.", "warning")
		return
	var target := _save_doc(current_doc)
	if target == "":
		return
	_update_doc_title()
	_set_status("Saved workspace copy: " + ProjectSettings.globalize_path(target), "success")


## Saves every document with unsaved edits to the workspace. Returns the count.
func save_all_edited() -> int:
	var docs := OdfDocument.dirty_documents()
	var saved := 0
	var failed := 0
	for doc in docs:
		if _save_doc(doc) != "":
			saved += 1
		else:
			failed += 1
	if docs.is_empty():
		_set_status("No edited documents to save.", "muted")
	elif failed == 0:
		_set_status("Saved %d edited document(s) to %s" % [saved, ProjectSettings.globalize_path(_workspace_dir())], "success")
	else:
		_set_status("Saved %d edited document(s); %d failed (see Output)." % [saved, failed], "danger")
	return saved


func _save_doc(doc) -> String:
	if doc == null or doc.source_path == "":
		return ""
	var rel := str(doc.workspace_rel)
	if rel == "":
		rel = origin_rel if doc.source_path == origin_path else _relative_for(doc.source_path)
	if rel == "":
		rel = doc.source_path.get_file()
	var result := WorkspaceStore.save_document_with_rel(doc, rel)
	if not bool(result.get("ok", false)):
		_set_status("Save failed: " + str(result.get("error", "unknown")), "danger")
		return ""
	return str(result.get("target", ""))


func rescan_index() -> void:
	if scan_thread != null:
		if scan_thread.is_alive():
			_set_status("Resource scan is already running.", "warning")
			return
		scan_thread.wait_to_finish()
		scan_thread = null
	_set_status("Rescanning configured roots…", "muted")
	_start_index_scan()


func _on_export_pressed() -> void:
	if current_doc == null:
		_set_status("Open a document before exporting.", "warning")
		return
	export_dialog.popup_centered()


func _on_export_dir_selected(dir: String) -> void:
	if current_doc == null:
		return
	var root_abs := WorkspaceStore.canonical(dir)
	for r in index.roots:
		var g := WorkspaceStore.canonical(str(r.get("path", "")))
		if g != "" and (root_abs == g or WorkspaceStore.is_within(g, root_abs)):
			_set_status("Refusing to export into game data: " + dir, "danger")
			return
	var docs: Array = OdfDocument.workspace_documents()
	if not docs.has(current_doc):
		docs.append(current_doc)
	if docs.is_empty():
		_set_status("Nothing to export.", "warning")
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var stage := root_abs.path_join("shaman_export_" + stamp)
	# Two exports inside the same second must not overwrite the first report.
	var collision := 2
	while DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(stage)):
		stage = root_abs.path_join("shaman_export_%s_%d" % [stamp, collision])
		collision += 1
	var odf_dir := stage.path_join("odf")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(odf_dir))
	var lines: Array[String] = ["BZ_ODF_SHAMAN export", "Date: " + Time.get_datetime_string_from_system(), "Documents: %d" % docs.size(), ""]
	var used: Dictionary = {}
	var exported := 0
	var failed := 0
	for doc in docs:
		var rel := str(doc.workspace_rel)
		if rel == "":
			rel = _relative_for(doc.source_path)
		rel = WorkspaceStore.clean_rel(rel)
		if rel == "":
			rel = doc.source_path.get_file()
		var key := rel.to_lower() if OS.get_name() == "Windows" else rel
		if used.has(key) and str(used[key]) != doc.source_path:
			var disambiguated := "collisions/%s/%s" % [str(doc.source_path).md5_text().substr(0, 8), rel]
			lines.append("COLLISION %s: %s vs %s -> %s" % [rel, used[key], doc.source_path, disambiguated])
			rel = disambiguated
			key = rel.to_lower()
		used[key] = doc.source_path
		var bytes: PackedByteArray = doc.to_bytes()
		var res := WorkspaceStore.write_staged(odf_dir, rel, bytes)
		if bool(res.get("ok", false)):
			exported += 1
			lines.append("EXPORTED %s  bytes=%d md5=%s  source=%s" % [rel, bytes.size(), FileAccess.get_md5(str(res.target)), doc.source_path])
		else:
			failed += 1
			lines.append("FAILED %s: %s" % [rel, str(res.get("error", ""))])
	lines.append("")
	lines.append("Exported: %d   Failed: %d" % [exported, failed])
	lines.append("Dry-run staging: original game files untouched.")
	var report := stage.path_join("export_report.txt")
	var report_res := WorkspaceStore.atomic_write_abs(report, "\n".join(PackedStringArray(lines)).to_utf8_buffer())
	var report_ok := bool(report_res.get("ok", false))
	export_last_stage = ProjectSettings.globalize_path(stage)
	export_last_report_ok = report_ok
	if failed == 0 and report_ok:
		_set_status("Exported %d staged ODF(s): %s" % [exported, ProjectSettings.globalize_path(stage)], "success")
	elif failed == 0:
		_set_status("Exported %d ODF(s), but export_report.txt could not be written — treat as a partial export: %s" % [exported, str(report_res.get("error", ""))], "danger")
	else:
		_set_status("Exported %d, failed %d — see export_report.txt" % [exported, failed], "danger")


func _ask_overwrite_original() -> void:
	if current_doc == null or origin_path == "":
		return
	overwrite_target = origin_path
	overwrite_dialog.dialog_text = "This writes directly to:\n\n" + origin_path + "\n\nThe original game/mod resource will be modified. Confirm only if you own a backup and intend this."
	overwrite_dialog.popup_centered()


func _do_overwrite_original() -> void:
	if current_doc == null or overwrite_target == "":
		return
	var err := current_doc.save_to(overwrite_target)
	if err == OK:
		_set_status("Original overwritten (explicitly confirmed): " + overwrite_target, "danger")
	else:
		_set_status("Overwrite failed: " + error_string(err), "danger")


# ---------------------------------------------------------------- scenario

func _auto_select_reference_scenario() -> void:
	var tank := index.resolve_path("ivtank_vsr")
	var scav := index.resolve_path("ivscav_vsr")
	if tank == "" or scav == "":
		tank = index.resolve_path("ivtank4")
		scav = index.resolve_path("ivscav12")
		if tank == "" or scav == "":
			return
		_set_status("VSR scenario not found; loaded stock fallback (ivtank4 / ivscav12).", "warning")
	else:
		_set_status("Reference VSR scenario resolved: ivtank_vsr / ivscav_vsr.", "success")
	shooter_path = tank
	target_path = scav
	weapon_lab.set_shooter(tank)
	weapon_lab.set_target(scav)
	open_document(tank)
	doc_tabs.current_tab = 0


func _load_reference_scenario() -> void:
	if index.total_files == 0:
		_set_status("Resource index is still building.", "warning")
		return
	var tank := index.resolve_path("ivtank_vsr")
	var scav := index.resolve_path("ivscav_vsr")
	if tank == "" or scav == "":
		_set_status("VSR scenario not indexed. Open the ODFs manually.", "warning")
		return
	shooter_path = tank
	target_path = scav
	weapon_lab.set_shooter(tank)
	weapon_lab.set_target(scav)
	open_document(tank)
	doc_tabs.current_tab = 0
	var p = weapon_lab.profile
	if p != null:
		_set_status("Loaded VSR reference: %s -> %s -> %s" % [p.weapon_name, p.ordnance_name, p.target_name], "success")


func _on_scenario_loaded(profile: WeaponProfile) -> void:
	_rebuild_inspector_chain_bar()
	if profile == null:
		return
	status_counts.text = "fidelity: APPROXIMATED   ·   %s -> %s" % [profile.weapon_name, profile.ordnance_name]


func _on_timeline_event_selected(ev: Dictionary) -> void:
	var p := str(ev.get("odf_path", ""))
	if p != "" and FileAccess.file_exists(p):
		open_document(p)
		_set_status("Timeline event @ %.3fs [%s]: opened %s (%s)" % [
			float(ev.get("time", 0.0)), str(ev.get("kind", "")), p.get_file(), str(ev.get("key", ""))
		], "muted")


func _on_render_header_selected(header: String) -> void:
	_set_status("Render header selected: [" + header + "] — edit its properties in the Inspector.", "muted")


func _on_particle_edited() -> void:
	if current_doc == null:
		return
	if not raw_edit.has_focus():
		raw_edit.text = current_doc.text
	_rebuild_inspector()
	_refresh_dependencies()
	_update_model_tab()
	_update_doc_title()
	if audio_lab != null:
		audio_lab.set_document(current_doc)
	if weapon_lab != null:
		weapon_lab.refresh_after_edit()
	_set_status("Particle graph edited — save to the workspace to keep the change", "warning")


# ---------------------------------------------------------------- misc

func _set_status(text: String, kind: String = "muted") -> void:
	if status_label == null:
		return
	status_label.text = text
	status_label.add_theme_color_override("font_color", theme_engine.status_color(kind))


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := event as InputEventKey
	# T-76: graph link hotkeys get first refusal while the Particle Lab tab is
	# active and the pointer is over the graph; existing global shortcuts below
	# stay intact otherwise.
	if particle_lab != null and particle_lab.visible and particle_lab.has_method("_handle_graph_hotkey"):
		if particle_lab._handle_graph_hotkey(event):
			get_viewport().set_input_as_handled()
			return
	if k.ctrl_pressed and k.keycode == KEY_O:
		open_dialog.popup_centered()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_S:
		_on_save_pressed()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_Z:
		_undo()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_Y:
		_redo()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and (k.keycode == KEY_EQUAL or k.keycode == KEY_KP_ADD):
		apply_ui_scale(ui_scale + 0.15)
		_save_settings()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and (k.keycode == KEY_MINUS or k.keycode == KEY_KP_SUBTRACT):
		apply_ui_scale(ui_scale - 0.15)
		_save_settings()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_0:
		apply_ui_scale(1.0)
		_save_settings()
		get_viewport().set_input_as_handled()


func _settings_path() -> String:
	# Isolated test runs keep their settings inside their own root too.
	if OS.get_environment(WorkspaceStore.ENV_ROOT) != "":
		return WorkspaceStore.root().path_join("settings.json")
	return SETTINGS_PATH


func _load_settings() -> void:
	if not FileAccess.file_exists(_settings_path()):
		return
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(_settings_path()))
	var parsed = jres.get("data", null) if bool(jres.get("ok", false)) else null
	if not (parsed is Dictionary):
		return
	if parsed.has("font_aa"):
		apply_font_aa(str(parsed.get("font_aa", "none")))
	if parsed.has("theme") and theme_engine.themes.has(str(parsed.theme)):
		_apply_theme(str(parsed.theme))
	if parsed.has("ui_scale"):
		apply_ui_scale(float(parsed.get("ui_scale", 1.0)))
	if parsed.has("master_volume") or parsed.has("master_muted"):
		apply_master_volume(float(parsed.get("master_volume", 0.85)), bool(parsed.get("master_muted", false)))
	if parsed.has("active_loadout"):
		var saved_pkg := str(parsed.get("active_loadout", "3532748119")).strip_edges()
		if saved_pkg != "":
			active_loadout_id = saved_pkg
			if saved_pkg.begins_with("profile:"):
				var lp = ModLoadoutScript.load_profile(saved_pkg.trim_prefix("profile:"))
				if lp != null and index != null:
					active_loadout_profile = lp
					index.apply_loadout(lp)
			elif index != null:
				index.set_active_package(saved_pkg)
			_refresh_loadout_option_profiles()
			if loadout_option != null:
				for i in loadout_option.item_count:
					if str(loadout_option.get_item_metadata(i)) == saved_pkg:
						loadout_option.select(i)
						break
	if parsed.has("live_swap_mode"):
		live_swap_mode = str(parsed.get("live_swap_mode", "off"))
		if live_swap_option != null:
			for i in live_swap_option.item_count:
				if str(live_swap_option.get_item_metadata(i)) == live_swap_mode:
					live_swap_option.select(i)
					break
	shooter_path = str(parsed.get("shooter", ""))
	target_path = str(parsed.get("target", ""))
	last_document_path = str(parsed.get("last_document", ""))


func _save_settings() -> void:
	var data := {
		"theme": theme_engine.current_slug,
		"font_aa": theme_engine.font_aa_mode,
		"ui_scale": ui_scale,
		"master_volume": master_volume,
		"master_muted": master_muted,
		"active_loadout": active_loadout_id,
		"live_swap_mode": live_swap_mode,
		"shooter": shooter_path,
		"target": target_path,
		"last_document": last_document_path,
	}
	WorkspaceStore.atomic_write_abs(_settings_path(), JSON.stringify(data, "  ").to_utf8_buffer())


func _exit_tree() -> void:
	_join_scan()


func _join_scan() -> void:
	if scan_thread != null:
		if scan_thread.is_alive():
			index.cancel_scan()
			scan_thread.wait_to_finish()
		scan_thread = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_settings()
		_join_scan()


func _run_gui_self_verify(out_dir: String) -> void:
	var abs_out := ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(abs_out)
	await get_tree().process_frame
	await get_tree().process_frame
	var source_navigation_ok := weapon_lab.get_node_or_null("FiringSourceNavigation") != null
	if source_navigation_ok and weapon_lab.profile != null:
		var inspected_sources: Array[String] = []
		weapon_lab.inspect_path_requested.connect(func(path: String):
			inspected_sources.append(path)
		)
		weapon_lab.open_weapon_button.emit_signal("pressed")
		weapon_lab.open_ordnance_button.emit_signal("pressed")
		source_navigation_ok = inspected_sources.size() == 2 and \
			inspected_sources[0] == weapon_lab._firing_source_profile().weapon_path and \
			inspected_sources[1] == weapon_lab._firing_source_profile().ordnance_path
		doc_tabs.current_tab = 0
		weapon_lab.yaw_spin.value = 18.0
		weapon_lab.fire_once()
		await get_tree().create_timer(0.85).timeout
		await RenderingServer.frame_post_draw
		var first_shot_id := int(weapon_lab.last_volley_result.shot_ids[-1]) if weapon_lab.last_volley_result != null and not weapon_lab.last_volley_result.shot_ids.is_empty() else 0
		weapon_lab.show_timeline_shot_button.emit_signal("pressed")
		var timeline_navigation_ok := first_shot_id > 0 and weapon_lab.focus_shot_on_timeline(first_shot_id)
		var tex1 := get_viewport().get_texture()
		if tex1 != null:
			var img1 := tex1.get_image()
			if img1 != null:
				img1.save_png(abs_out.path_join("exe_weapons_lab.png"))
		var pre := weapon_lab.run_native_preflight()
		var p := weapon_lab.profile
		var xpl_name := p.xpl_vehicle if p.xpl_vehicle != "" else p.xpl_ground
		var xpl_path := index.resolve_path_from(xpl_name, p.ordnance_path) if xpl_name != "" else ""
		if xpl_path != "":
			open_document(xpl_path)
			doc_tabs.current_tab = 1
			await get_tree().process_frame
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var tex2 := get_viewport().get_texture()
			if tex2 != null:
				var img2 := tex2.get_image()
				if img2 != null:
					img2.save_png(abs_out.path_join("exe_particle_lab.png"))
		# Also verify Titan (fvatank -> garc_c -> arcbolt) live lightning + sandbox props in GPU viewport.
		var titan_p := index.resolve_path("fvatank.odf")
		var scav_p := index.resolve_path("ivscav.odf")
		var titan_bolt_ok := false
		if titan_p != "" and scav_p != "":
			doc_tabs.current_tab = 0
			weapon_lab.set_shooter(titan_p)
			weapon_lab.set_target(scav_p)
			weapon_lab.distance_slider.value = 90.0
			weapon_lab.yaw_spin.value = 0.0
			weapon_lab.add_terrain_ramp(Vector3(16.0, 2.5, -45.0))
			weapon_lab.add_wall(Vector3(-16.0, 3.0, -45.0))
			weapon_lab.apply_camera_preset("overview")
			await get_tree().process_frame
			weapon_lab.fire_once()
			await get_tree().create_timer(0.18).timeout
			await RenderingServer.frame_post_draw
			titan_bolt_ok = (weapon_lab.last_bolt_node != null and is_instance_valid(weapon_lab.last_bolt_node))
			var tex3 := get_viewport().get_texture()
			if tex3 != null:
				var img3 := tex3.get_image()
				if img3 != null:
					img3.save_png(abs_out.path_join("exe_titan_lightning.png"))
		var marker_roles := {}
		var marker_sources_ok := true
		var inspection_only_count := 0
		for identity in weapon_lab._hardpoint_marker_data:
			marker_roles[str(identity.get("hardpoint", ""))] = str(identity.get("marker_role", ""))
			if str(identity.get("marker_role", "")) == "GENERIC_MODEL_HARDPOINT":
				inspection_only_count += 1
				if str(identity.get("weapon_path", "")) != "" or str(identity.get("ordnance_path", "")) != "":
					marker_sources_ok = false
			elif str(identity.get("ordnance_status", "")) == "ORDNANCE_UNRESOLVED":
				marker_sources_ok = false
		var lines := PackedStringArray([
			"BZ_ODF_SHAMAN GUI Self-Verify",
			"theme=" + theme_engine.current_slug,
			"viewport=" + str(get_viewport_rect().size),
			"index=" + index.summary(),
			"shooter_model=" + JSON.stringify(weapon_lab.shooter_model_info),
			"target_model=" + JSON.stringify(weapon_lab.target_model_info),
			"hardpoint_mode=" + str(weapon_lab.hardpoint_mode),
			"hardpoint_markers=" + str(weapon_lab._hardpoint_marker_data.size()),
			"hardpoint_roles=" + JSON.stringify(marker_roles),
			"inspection_only_markers=" + str(inspection_only_count),
			"marker_sources_consistent=" + str(marker_sources_ok),
			"firing_policy=" + JSON.stringify(weapon_lab._last_firing_policy),
			"source_navigation_ok=" + str(source_navigation_ok),
			"timeline_navigation_ok=" + str(timeline_navigation_ok),
			"last_shot_identity=" + JSON.stringify(weapon_lab.last_volley_result.to_dict().get("per_barrel_results", []) if weapon_lab.last_volley_result != null else []),
			"spawned_effects=" + str(weapon_lab.spawned_effects),
			"titan_bolt_rendered=" + str(titan_bolt_ok),
			"rigid_floor_weapon_lab=" + str(weapon_lab.ground_body is StaticBody3D),
			"rigid_floor_particle_lab=" + str(particle_lab != null and particle_lab.preview_floor_body is StaticBody3D),
			"texture_browser_count=" + str(particle_lab.list_available_textures("", "fx", 120).size() if particle_lab != null else 0),
			"emitter_presets=" + str(particle_lab.EMITTER_PRESETS.size() if particle_lab != null else 0),
			"live_swap_modes=" + str(live_swap_option.item_count if live_swap_option != null else 0),
			"preflight_status=" + str((pre.get("preflight", {}) as Dictionary).get("status", "")),
			"preflight_route=" + str((pre.get("preflight", {}) as Dictionary).get("launch_route", "")),
			"preflight_reason=" + str((pre.get("preflight", {}) as Dictionary).get("reason", "")),
			"audio_pool=" + JSON.stringify(weapon_lab.audio_pool_status()),
			"camera_presets=" + str(weapon_lab.camera_preset_option.item_count if weapon_lab.camera_preset_option != null else 0),
			"save_deps_button=" + str(particle_lab != null and particle_lab.save_deps_button != null),
			"font_aa=" + theme_engine.font_aa_mode,
			"ui_scale=" + str(ui_scale),
			"master_volume=" + str(master_volume),
			"hud_tags=" + str(weapon_lab._hud_tags.size()),
			"collections=" + JSON.stringify(index.collection_counts()),
			"timeline_events=" + str(weapon_lab.timeline_events.size()),
			"telemetry_lines=" + str(weapon_lab.telemetry.get_line_count()),
		])
		WorkspaceStore.atomic_write_abs(abs_out.path_join("gui_verify_report.txt"), "\n".join(lines).to_utf8_buffer())
	get_tree().quit(0)
