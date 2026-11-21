class_name WeaponLab
extends VBoxContainer
## Interactive shooter -> target laboratory with authentic DOCB .msh geometry,
## hardpoint firing and labelled PLACEHOLDER MESH fallback when undecoded.

signal status_changed(text: String, kind: String)
signal scenario_loaded(profile: WeaponProfile)
signal events_changed
signal timeline_event_selected(event: Dictionary)
signal pick_actor_requested(role: String)
signal inspect_path_requested(path: String)

const AUDIO_POOL_SIZE := 8
const CAMERA_PRESETS := ["overview", "muzzle", "target", "side", "top"]
const TARGET_MOTION_MODES := ["stationary", "strafe", "wiggle", "orbit", "approach"]
const SHOOTER_AIM_MODES := ["manual", "track", "lead", "fixed_forward"]

var index: ResourceIndex
var schema: SchemaRegistry
var profile: WeaponProfile
var sim := ProjectileSim.new(20261121)

const BzMeshReaderScript = preload("res://scripts/core/bz_mesh_reader.gd")
const NativeAdapterScript = preload("res://scripts/native/native_test_adapter.gd")
const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")
const HoudiniScrubberScript = preload("res://scripts/ui/houdini_scrubber.gd")

var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var container: SubViewportContainer
var viewport_host: Control
var hud_labels_layer: Control
var lab_vsplit: VSplitContainer
var _hud_tags: Array[Dictionary] = []
var shooter_node: Node3D
var target_node: Node3D
var target_material: StandardMaterial3D
var projectile_root: Node3D
var effect_root: Node3D
var aim_overlay: MeshInstance3D
var bbox_overlay: MeshInstance3D
var hardpoint_markers_root: Node3D
var shooter_model_info: Dictionary = {}
var target_model_info: Dictionary = {}
var shooter_hardpoint_node: Node3D = null
var hardpoint_mode: String = "editor-defined"
var projectiles: Array[Dictionary] = []
var last_fx_result: Dictionary = {}
var audio_player: AudioStreamPlayer
var audio_pool: Array[AudioStreamPlayer] = []
var _audio_pool_cursor := 0
var audio_voice_steals := 0
var audio_plays_count := 0
var effects_enabled := true
var overlays_enabled := true
var fx_button: Button
var overlays_button: Button
var hardpoint_option: OptionButton
var target_motion_option: OptionButton
var target_motion_mode: String = "strafe"
var target_speed_spin: HBoxContainer
var target_amp_spin: HBoxContainer
var target_freq_spin: HBoxContainer
var target_offset_x_spin: HBoxContainer
var target_offset_y_spin: HBoxContainer
var target_yaw_spin: HBoxContainer
var shooter_aim_option: OptionButton
var shooter_aim_mode: String = "manual"
var shooter_offset_x_spin: HBoxContainer
var shooter_yaw_spin: HBoxContainer
var shooter_speed_spin: HBoxContainer
var prop_dist_pct_spin: HBoxContainer
var prop_x_spin: HBoxContainer
var ground_body: StaticBody3D
var last_bolt_node: Node3D = null
var _recoil_offset := 0.0
var _recoil_node: Node3D = null
var _recoil_rest_pos := Vector3.ZERO
var _target_velocity := Vector3.ZERO
var _prev_target_pos := Vector3.ZERO
var _has_prev_target_pos := false
var camera_preset_option: OptionButton
var scene_preset_option: OptionButton
var cam_bookmark_option: OptionButton
var camera_bookmarks: Dictionary = {}
var active_camera_preset: String = "overview"
var shooter_pos_offset := Vector3.ZERO
var target_pos_offset := Vector3.ZERO
var shooter_yaw_offset_deg := 0.0
var target_yaw_offset_deg := 0.0
var obstacles_root: Node3D
var extra_targets_root: Node3D
var obstacles: Array[Dictionary] = []
var extra_targets: Array[Dictionary] = []
var _obstacle_seq := 0
var _extra_target_seq := 0
var spawned_effects := 0
var fx_log: Array[String] = []
var timeline_events: Array[Dictionary] = []
var timeline_tree: Tree
var timeline_filter_option: OptionButton
var timeline_scrub_slider: HSlider
var timeline_time_label: Label
var audio_pool_label: Label
var bottom_tabs: TabContainer
var _timeline_filter := "all"
var _timeline_filtered_events: Array[Dictionary] = []
var baseline_snapshot: Dictionary = {}
var last_comparison: Dictionary = {}
var _target_phase := 0.0
var _last_impact_pos := Vector3.ZERO
var _has_last_impact := false

var shooter_path: String = ""
var target_path: String = ""

# UI refs
var shooter_label: Label
var target_label: Label
var pick_a_button: Button
var pick_b_button: Button
var swap_ab_button: Button
var chain_a_button: Button
var chain_wpn_button: Button
var chain_ord_button: Button
var chain_xpl_button: Button
var chain_b_button: Button
var distance_slider: HSlider
var distance_spin: HBoxContainer
var elevation_spin: HBoxContainer
var yaw_spin: HBoxContainer
var fire_button: Button
var alt_button: Button
var burst_button: Button
var hold_button: Button
var pause_button: Button
var speed_spin: HBoxContainer
var telemetry: TextEdit
var stats_label: RichTextLabel
var health_bar: ProgressBar
var health_label: Label
var sweep_property: OptionButton
var sweep_from: HBoxContainer
var sweep_to: HBoxContainer
var sweep_steps: HBoxContainer
var sweep_output: TextEdit
var native_runner = null
var active_native_session_id: String = ""
var native_preflight_button: Button
var native_stage_button: Button
var native_launch_button: Button
var native_handoff_button: Button
var native_collect_button: Button
var native_compare_button: Button
var native_cleanup_button: Button
var reset_ab_button: Button
var reset_aim_button: Button
var reset_scene_button: Button
var native_status_label: Label
var default_shooter_path: String = ""
var default_target_path: String = ""

var _running := false
var _paused := false
var _continuous := false
var _fire_cooldown := 0.0
var _burst_left := 0
var _burst_timer := 0.0
var _cam_yaw := deg_to_rad(42.0)
var _cam_pitch := deg_to_rad(18.0)
var _cam_dist := 18.0
var _cam_focus := Vector3(0, 1.5, -5.0)
var _dragging := false
var _drag_last := Vector2.ZERO
var _current_health := 1000.0
var last_sweep: Dictionary = {}


func setup(p_index: ResourceIndex, p_schema: SchemaRegistry) -> void:
	index = p_index
	schema = p_schema
	native_runner = NativeRunnerScript.new()
	var rec: Dictionary = native_runner.recover_sessions()
	_build_ui()
	_build_world()
	if int(rec.get("recovered", 0)) > 0:
		var latest: Array = native_runner.list_sessions()
		if not latest.is_empty():
			active_native_session_id = str((latest[0] as Dictionary).get("session_id", ""))
		_update_native_controls("Recovered %d durable native session(s)" % int(rec.get("recovered", 0)))


func _build_ui() -> void:
	add_theme_constant_override("separation", 4)
	clip_contents = true

	# Top Bar 1: E2E Combat Chain & A/B Actor Setup (1-click jump to any ODF in the chain).
	var ab_row := HFlowContainer.new()
	ab_row.add_theme_constant_override("h_separation", 4)
	ab_row.add_theme_constant_override("v_separation", 3)
	add_child(ab_row)

	pick_a_button = _mk_button("Pick A...")
	pick_a_button.tooltip_text = "Choose Object A (shooter vehicle/turret)"
	pick_a_button.pressed.connect(func(): pick_actor_requested.emit("shooter"))
	ab_row.add_child(pick_a_button)

	chain_a_button = _mk_button("A: (none)")
	chain_a_button.tooltip_text = "Click to inspect/edit Shooter A ODF in the Inspector"
	chain_a_button.pressed.connect(func():
		if shooter_path != "":
			inspect_path_requested.emit(shooter_path)
	)
	ab_row.add_child(chain_a_button)

	chain_wpn_button = _mk_button("-> Wpn: -")
	chain_wpn_button.tooltip_text = "Click to inspect/edit Weapon ODF (shotDelay, salvoCount, flashName, fireSound)"
	chain_wpn_button.pressed.connect(func():
		if profile != null and profile.weapon_path != "":
			inspect_path_requested.emit(profile.weapon_path)
	)
	ab_row.add_child(chain_wpn_button)

	chain_ord_button = _mk_button("-> Ord: -")
	chain_ord_button.tooltip_text = "Click to inspect/edit Ordnance ODF (damageValue, shotSpeed, lifeSpan)"
	chain_ord_button.pressed.connect(func():
		if profile != null and profile.ordnance_path != "":
			inspect_path_requested.emit(profile.ordnance_path)
	)
	ab_row.add_child(chain_ord_button)

	chain_xpl_button = _mk_button("-> Xpl: -")
	chain_xpl_button.tooltip_text = "Click to inspect/edit Explosion ODF in Inspector & Particle Lab"
	chain_xpl_button.pressed.connect(func():
		if profile != null and index != null:
			var xname := profile.xpl_vehicle if profile.xpl_vehicle != "" else profile.xpl_ground
			var xp := index.resolve_path_from(xname, profile.ordnance_path) if xname != "" else ""
			if xp != "":
				inspect_path_requested.emit(xp)
	)
	ab_row.add_child(chain_xpl_button)

	swap_ab_button = _mk_button("Swap A<->B")
	swap_ab_button.tooltip_text = "Swap Shooter A and Target B"
	swap_ab_button.pressed.connect(swap_actors)
	ab_row.add_child(swap_ab_button)

	pick_b_button = _mk_button("Pick B...")
	pick_b_button.tooltip_text = "Choose Object B (target unit/building)"
	pick_b_button.pressed.connect(func(): pick_actor_requested.emit("target"))
	ab_row.add_child(pick_b_button)

	chain_b_button = _mk_button("B: (none)")
	chain_b_button.tooltip_text = "Click to inspect/edit Target B ODF (maxHealth, armorClass)"
	chain_b_button.pressed.connect(func():
		if target_path != "":
			inspect_path_requested.emit(target_path)
	)
	ab_row.add_child(chain_b_button)

	reset_ab_button = _mk_button("Reset A/B")
	reset_ab_button.tooltip_text = "Reset Object A (Shooter) and Object B (Target) to factory default test pair"
	reset_ab_button.pressed.connect(reset_actors_to_default)
	ab_row.add_child(reset_ab_button)

	# Keep shooter_label / target_label populated for diagnostics & test introspection.
	shooter_label = Label.new()
	shooter_label.visible = false
	ab_row.add_child(shooter_label)
	target_label = Label.new()
	target_label.visible = false
	ab_row.add_child(target_label)

	# Top Bar 2: Primary Combat Fire & Aim Controls (UI.md hierarchy first: primary action obvious).
	var fire_row := HFlowContainer.new()
	fire_row.add_theme_constant_override("h_separation", 5)
	fire_row.add_theme_constant_override("v_separation", 3)
	add_child(fire_row)
	fire_button = _mk_button("FIRE ONCE")
	fire_button.custom_minimum_size = Vector2(88, 24)
	fire_button.pressed.connect(fire_once)
	fire_row.add_child(fire_button)
	alt_button = _mk_button("FIRE ALT")
	alt_button.pressed.connect(fire_alt)
	fire_row.add_child(alt_button)
	burst_button = _mk_button("BURST")
	burst_button.pressed.connect(start_burst)
	fire_row.add_child(burst_button)
	hold_button = _mk_button("CONTINUOUS")
	hold_button.toggle_mode = true
	hold_button.toggled.connect(_on_hold_toggled)
	fire_row.add_child(hold_button)
	var stop := _mk_button("STOP")
	stop.pressed.connect(stop_fire)
	fire_row.add_child(stop)
	var restart := _mk_button("RESTART")
	restart.pressed.connect(restart_test)
	fire_row.add_child(restart)

	fire_row.add_child(_mk_label("Range"))
	distance_slider = HSlider.new()
	distance_slider.min_value = 10
	distance_slider.max_value = 400
	distance_slider.step = 1
	distance_slider.value = 120
	distance_slider.custom_minimum_size = Vector2(90, 18)
	distance_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	distance_slider.tooltip_text = "Range slider (Right-Click to reset to default range)"
	distance_slider.value_changed.connect(_on_distance_changed)
	_bind_rmb_reset(distance_slider, func():
		var def_r := float(distance_spin.default_value) if distance_spin != null else 120.0
		distance_slider.value = def_r
	)
	fire_row.add_child(distance_slider)
	distance_spin = _mk_spin(10, 400, 1, false, true)
	distance_spin.value = 120
	distance_spin.set_default_value(120.0)
	distance_spin.suffix = " m"
	distance_spin.set_pill_width(58)
	distance_spin.tooltip_text = "Drag LMB to scrub, MMB for Houdini Value Ladder, RMB to reset (120 m)"
	distance_spin.value_changed.connect(func(v): distance_slider.value = v)
	fire_row.add_child(distance_spin)
	fire_row.add_child(_mk_label("Pitch"))
	elevation_spin = _mk_spin(-30, 60, 0.5, false)
	elevation_spin.suffix = "°"
	elevation_spin.value = 0
	elevation_spin.set_default_value(0.0)
	elevation_spin.set_pill_width(52)
	elevation_spin.tooltip_text = "Turret pitch (LMB drag / MMB Value Ladder / RMB reset to 0°)"
	elevation_spin.value_changed.connect(func(_v): _apply_aim_transform())
	fire_row.add_child(elevation_spin)
	fire_row.add_child(_mk_label("Yaw"))
	yaw_spin = _mk_spin(-45, 45, 0.5, false)
	yaw_spin.suffix = "°"
	yaw_spin.value = 0
	yaw_spin.set_default_value(0.0)
	yaw_spin.set_pill_width(52)
	yaw_spin.tooltip_text = "Turret yaw (LMB drag / MMB Value Ladder / RMB reset to 0°)"
	yaw_spin.value_changed.connect(func(_v): _apply_aim_transform())
	fire_row.add_child(yaw_spin)
	fire_row.add_child(_mk_label("HP"))
	hardpoint_option = OptionButton.new()
	hardpoint_option.custom_minimum_size = Vector2(104, 0)
	hardpoint_option.item_selected.connect(_on_hardpoint_selected)
	fire_row.add_child(hardpoint_option)
	fire_row.add_child(_mk_label("Cam"))
	camera_preset_option = OptionButton.new()
	camera_preset_option.custom_minimum_size = Vector2(88, 0)
	for cp in CAMERA_PRESETS:
		camera_preset_option.add_item(cp.capitalize())
		camera_preset_option.set_item_metadata(camera_preset_option.item_count - 1, cp)
	camera_preset_option.item_selected.connect(func(idx: int):
		apply_camera_preset(str(camera_preset_option.get_item_metadata(idx)))
	)
	camera_preset_option.tooltip_text = "Camera preset (Right-Click to reset to Overview)"
	_bind_rmb_reset(camera_preset_option, func(): apply_camera_preset("overview"))
	fire_row.add_child(camera_preset_option)
	fire_row.add_child(_mk_label("Speed"))
	speed_spin = _mk_spin(0.05, 4.0, 0.05, false)
	speed_spin.value = 1.0
	speed_spin.set_default_value(1.0)
	speed_spin.suffix = "×"
	speed_spin.set_pill_width(52)
	fire_row.add_child(speed_spin)
	fx_button = _mk_button("FX ON")
	fx_button.toggle_mode = true
	fx_button.button_pressed = true
	fx_button.tooltip_text = "Spawn APPROXIMATED explosion particles from the real xplGround/xplVehicle ODF"
	fx_button.toggled.connect(func(on: bool):
		effects_enabled = on
		fx_button.text = "FX ON" if on else "FX OFF"
	)
	fire_row.add_child(fx_button)
	overlays_button = _mk_button("BBOX ON")
	overlays_button.toggle_mode = true
	overlays_button.button_pressed = true
	overlays_button.tooltip_text = "Toggle 3D bounding-box, mesh labels, hardpoint and impact overlays"
	overlays_button.toggled.connect(func(on: bool):
		overlays_enabled = on
		overlays_button.text = "BBOX ON" if on else "BBOX OFF"
		_update_aim_overlay()
		if hud_labels_layer != null:
			hud_labels_layer.visible = on
	)
	fire_row.add_child(overlays_button)
	reset_aim_button = _mk_button("Reset Aim")
	reset_aim_button.tooltip_text = "Reset Range (120m), Pitch (0°), Yaw (0°), Camera (Overview), Speed (1x), FX/BBOX ON"
	reset_aim_button.pressed.connect(reset_aim_to_default)
	fire_row.add_child(reset_aim_button)

	# Resizable vertical split: 3D viewport on top, stats + 5-tab workbench on bottom.
	lab_vsplit = VSplitContainer.new()
	lab_vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lab_vsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab_vsplit.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
	add_child(lab_vsplit)

	viewport_host = Control.new()
	viewport_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_host.custom_minimum_size = Vector2(160, 160)
	viewport_host.clip_contents = true
	lab_vsplit.add_child(viewport_host)

	container = SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.gui_input.connect(_on_viewport_input)
	viewport_host.add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.handle_input_locally = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_2X
	container.add_child(viewport)

	hud_labels_layer = Control.new()
	hud_labels_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud_labels_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_labels_layer.clip_contents = true
	viewport_host.add_child(hud_labels_layer)

	var bottom_panel := VBoxContainer.new()
	bottom_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_panel.custom_minimum_size = Vector2(160, 140)
	bottom_panel.add_theme_constant_override("separation", 3)
	bottom_panel.clip_contents = true
	lab_vsplit.add_child(bottom_panel)

	var stats_row := HBoxContainer.new()
	stats_row.add_theme_constant_override("separation", 8)
	bottom_panel.add_child(stats_row)
	stats_label = RichTextLabel.new()
	stats_label.bbcode_enabled = true
	stats_label.fit_content = true
	stats_label.scroll_active = false
	stats_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_label.custom_minimum_size = Vector2(0, 36)
	stats_row.add_child(stats_label)
	var health_box := VBoxContainer.new()
	health_box.custom_minimum_size = Vector2(170, 0)
	stats_row.add_child(health_box)
	health_label = Label.new()
	health_label.text = "Target hull: -"
	health_box.add_child(health_label)
	health_bar = ProgressBar.new()
	health_bar.max_value = 1000
	health_bar.value = 1000
	health_bar.show_percentage = false
	health_box.add_child(health_bar)

	# 5 focused bottom workbench tabs: Telemetry | Timeline | Scene & Targets | Sweep | Native BZCC
	bottom_tabs = TabContainer.new()
	bottom_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_tabs.custom_minimum_size = Vector2(0, 110)
	bottom_panel.add_child(bottom_tabs)

	# Tab 1: Telemetry & Snapshot Comparison
	var tel_tab := VBoxContainer.new()
	tel_tab.name = "Telemetry"
	bottom_tabs.add_child(tel_tab)
	var tel_header := HFlowContainer.new()
	tel_header.add_theme_constant_override("h_separation", 5)
	tel_header.add_theme_constant_override("v_separation", 2)
	tel_tab.add_child(tel_header)
	pause_button = _mk_button("PAUSE")
	pause_button.toggle_mode = true
	pause_button.toggled.connect(_on_pause_toggled)
	tel_header.add_child(pause_button)
	var step := _mk_button("STEP")
	step.pressed.connect(_step_once)
	tel_header.add_child(step)
	var snap_btn := _mk_button("SNAPSHOT")
	snap_btn.tooltip_text = "Capture current shot metrics as before/after baseline"
	snap_btn.pressed.connect(snapshot_shot_baseline)
	tel_header.add_child(snap_btn)
	var cmp_btn := _mk_button("COMPARE")
	cmp_btn.tooltip_text = "Compare current shot against captured baseline"
	cmp_btn.pressed.connect(compare_with_snapshot)
	tel_header.add_child(cmp_btn)
	var clear_btn := _mk_button("Clear")
	clear_btn.pressed.connect(func(): telemetry.text = "")
	tel_header.add_child(clear_btn)
	var fidelity := Label.new()
	fidelity.text = "PREVIEW: APPROXIMATED"
	fidelity.add_theme_color_override("font_color", Color("#9C9371"))
	tel_header.add_child(fidelity)
	telemetry = TextEdit.new()
	telemetry.editable = false
	telemetry.size_flags_vertical = Control.SIZE_EXPAND_FILL
	telemetry.placeholder_text = "Simulation telemetry appears here."
	tel_tab.add_child(telemetry)

	# Tab 2: Interactive Audiovisual Timeline
	var tl_tab := VBoxContainer.new()
	tl_tab.name = "Timeline"
	bottom_tabs.add_child(tl_tab)
	var tl_bar := HFlowContainer.new()
	tl_bar.add_theme_constant_override("h_separation", 6)
	tl_bar.add_theme_constant_override("v_separation", 2)
	tl_tab.add_child(tl_bar)
	tl_bar.add_child(_mk_label("Filter"))
	timeline_filter_option = OptionButton.new()
	for pair in [["All", "all"], ["Weapon/Impact", "combat"], ["FX", "fx"], ["Audio", "audio"]]:
		timeline_filter_option.add_item(str(pair[0]))
		timeline_filter_option.set_item_metadata(timeline_filter_option.item_count - 1, str(pair[1]))
	timeline_filter_option.item_selected.connect(func(idx: int):
		filter_timeline(str(timeline_filter_option.get_item_metadata(idx)))
	)
	timeline_filter_option.tooltip_text = "Filter timeline events (Right-Click to reset to All)"
	_bind_rmb_reset(timeline_filter_option, func():
		timeline_filter_option.select(0)
		filter_timeline("all")
	)
	tl_bar.add_child(timeline_filter_option)
	tl_bar.add_child(_mk_label("Scrub"))
	timeline_scrub_slider = HSlider.new()
	timeline_scrub_slider.min_value = 0.0
	timeline_scrub_slider.max_value = 1.0
	timeline_scrub_slider.step = 0.005
	timeline_scrub_slider.custom_minimum_size = Vector2(160, 18)
	timeline_scrub_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	timeline_scrub_slider.tooltip_text = "Scrub timeline (Right-Click to reset to 0.0s)"
	timeline_scrub_slider.value_changed.connect(func(v: float): scrub_timeline_to(v))
	_bind_rmb_reset(timeline_scrub_slider, func(): timeline_scrub_slider.value = 0.0)
	tl_bar.add_child(timeline_scrub_slider)
	timeline_time_label = Label.new()
	timeline_time_label.text = "t=0.000 s (0 events)"
	timeline_time_label.add_theme_color_override("font_color", Color("#F0D060"))
	tl_bar.add_child(timeline_time_label)
	audio_pool_label = Label.new()
	audio_pool_label.text = "Audio pool: 0/%d active (steals: 0)" % AUDIO_POOL_SIZE
	audio_pool_label.add_theme_color_override("font_color", Color("#9C9371"))
	tl_bar.add_child(audio_pool_label)
	timeline_tree = Tree.new()
	timeline_tree.columns = 4
	timeline_tree.set_column_title(0, "Time (s)")
	timeline_tree.set_column_title(1, "Event")
	timeline_tree.set_column_title(2, "Detail")
	timeline_tree.set_column_title(3, "ODF / Key")
	timeline_tree.column_titles_visible = true
	timeline_tree.hide_root = true
	timeline_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	timeline_tree.item_activated.connect(_on_timeline_item_activated)
	timeline_tree.item_selected.connect(_on_timeline_item_selected)
	tl_tab.add_child(timeline_tree)

	# Tab 3: Scene & Multi-Target / Obstacle / Sandbox Authoring
	var sc_tab := VBoxContainer.new()
	sc_tab.name = "Scene"
	sc_tab.add_theme_constant_override("separation", 3)
	bottom_tabs.add_child(sc_tab)
	var scene_row := HFlowContainer.new()
	scene_row.add_theme_constant_override("h_separation", 6)
	scene_row.add_theme_constant_override("v_separation", 3)
	sc_tab.add_child(scene_row)
	scene_row.add_child(_mk_label("Tgt Motion"))
	target_motion_option = OptionButton.new()
	target_motion_option.custom_minimum_size = Vector2(106, 0)
	target_motion_option.tooltip_text = "Moving Target pattern (Right-Click to reset to Strafe)"
	for mp in [["Stationary", "stationary"], ["Strafe (L-R)", "strafe"], ["Wiggle (S)", "wiggle"], ["Orbit", "orbit"], ["Approach", "approach"]]:
		target_motion_option.add_item(str(mp[0]))
		target_motion_option.set_item_metadata(target_motion_option.item_count - 1, str(mp[1]))
	target_motion_option.select(1)
	target_motion_option.item_selected.connect(func(idx: int):
		var m := str(target_motion_option.get_item_metadata(idx))
		set_target_motion_mode(m, true)
	)
	_bind_rmb_reset(target_motion_option, func(): set_target_motion_mode("strafe", false))
	scene_row.add_child(target_motion_option)
	scene_row.add_child(_mk_label("Tgt Speed"))
	target_speed_spin = _mk_spin(0.0, 60.0, 1.0, false)
	target_speed_spin.suffix = " m/s"
	target_speed_spin.value = 0.0
	target_speed_spin.set_default_value(0.0)
	target_speed_spin.set_pill_width(64)
	scene_row.add_child(target_speed_spin)
	scene_row.add_child(_mk_label("Amp"))
	target_amp_spin = _mk_spin(2.0, 60.0, 1.0, false)
	target_amp_spin.suffix = " m"
	target_amp_spin.value = 18.0
	target_amp_spin.set_default_value(18.0)
	target_amp_spin.set_pill_width(54)
	target_amp_spin.value_changed.connect(func(_v: float): _update_target_position())
	scene_row.add_child(target_amp_spin)
	scene_row.add_child(_mk_label("Wiggle"))
	target_freq_spin = _mk_spin(0.2, 5.0, 0.1, false)
	target_freq_spin.suffix = "×"
	target_freq_spin.value = 1.0
	target_freq_spin.set_default_value(1.0)
	target_freq_spin.set_pill_width(50)
	scene_row.add_child(target_freq_spin)
	scene_row.add_child(_mk_label("Tgt X"))
	target_offset_x_spin = _mk_spin(-80.0, 80.0, 1.0, false)
	target_offset_x_spin.suffix = " m"
	target_offset_x_spin.set_default_value(0.0)
	target_offset_x_spin.set_pill_width(58)
	target_offset_x_spin.value_changed.connect(func(v: float):
		target_pos_offset.x = v
		_update_target_position()
	)
	scene_row.add_child(target_offset_x_spin)
	scene_row.add_child(_mk_label("Tgt Y"))
	target_offset_y_spin = _mk_spin(0.0, 40.0, 0.5, false)
	target_offset_y_spin.suffix = " m"
	target_offset_y_spin.value = 0.0
	target_offset_y_spin.set_default_value(0.0)
	target_offset_y_spin.set_pill_width(54)
	target_offset_y_spin.value_changed.connect(func(v: float):
		target_pos_offset.y = v
		_update_target_position()
	)
	scene_row.add_child(target_offset_y_spin)
	scene_row.add_child(_mk_label("Tgt Yaw"))
	target_yaw_spin = _mk_spin(-180.0, 180.0, 5.0, false)
	target_yaw_spin.suffix = "°"
	target_yaw_spin.set_default_value(0.0)
	target_yaw_spin.set_pill_width(58)
	target_yaw_spin.value_changed.connect(func(v: float):
		target_yaw_offset_deg = v
		if target_node != null:
			target_node.rotation_degrees.y = v
		_sync_target_bbox_to_profile()
		_update_aim_overlay()
	)
	scene_row.add_child(target_yaw_spin)

	var sandbox_row := HFlowContainer.new()
	sandbox_row.add_theme_constant_override("h_separation", 6)
	sandbox_row.add_theme_constant_override("v_separation", 3)
	sc_tab.add_child(sandbox_row)
	sandbox_row.add_child(_mk_label("Shooter Aim"))
	shooter_aim_option = OptionButton.new()
	shooter_aim_option.custom_minimum_size = Vector2(118, 0)
	shooter_aim_option.tooltip_text = "Shooter aiming behavior (Right-Click to reset to Manual)"
	for ap in [["Manual (Pitch/Yaw)", "manual"], ["Track Target", "track"], ["Lead Target", "lead"], ["Fixed Forward", "fixed_forward"]]:
		shooter_aim_option.add_item(str(ap[0]))
		shooter_aim_option.set_item_metadata(shooter_aim_option.item_count - 1, str(ap[1]))
	shooter_aim_option.item_selected.connect(func(idx: int):
		set_shooter_aim_mode(str(shooter_aim_option.get_item_metadata(idx)))
	)
	_bind_rmb_reset(shooter_aim_option, func(): set_shooter_aim_mode("manual"))
	sandbox_row.add_child(shooter_aim_option)
	sandbox_row.add_child(_mk_label("Sh X"))
	shooter_offset_x_spin = _mk_spin(-40.0, 40.0, 1.0, false)
	shooter_offset_x_spin.suffix = " m"
	shooter_offset_x_spin.set_default_value(0.0)
	shooter_offset_x_spin.set_pill_width(54)
	shooter_offset_x_spin.value_changed.connect(func(v: float):
		set_shooter_transform(Vector3(v, shooter_pos_offset.y, shooter_pos_offset.z), shooter_yaw_offset_deg)
	)
	sandbox_row.add_child(shooter_offset_x_spin)
	sandbox_row.add_child(_mk_label("Sh Yaw"))
	shooter_yaw_spin = _mk_spin(-180.0, 180.0, 5.0, false)
	shooter_yaw_spin.suffix = "°"
	shooter_yaw_spin.set_default_value(0.0)
	shooter_yaw_spin.set_pill_width(54)
	shooter_yaw_spin.value_changed.connect(func(v: float):
		set_shooter_transform(shooter_pos_offset, v)
	)
	sandbox_row.add_child(shooter_yaw_spin)
	sandbox_row.add_child(_mk_label("Sh Vel"))
	shooter_speed_spin = _mk_spin(-40.0, 40.0, 1.0, false)
	shooter_speed_spin.suffix = " m/s"
	shooter_speed_spin.set_default_value(0.0)
	shooter_speed_spin.set_pill_width(60)
	shooter_speed_spin.tooltip_text = "Simulated forward shooter velocity inherited by projectiles (RMB reset to 0)"
	sandbox_row.add_child(shooter_speed_spin)
	sandbox_row.add_child(_mk_label("Prop Z%"))
	prop_dist_pct_spin = _mk_spin(10.0, 90.0, 5.0, false, true)
	prop_dist_pct_spin.value = 50.0
	prop_dist_pct_spin.set_default_value(50.0)
	prop_dist_pct_spin.suffix = "%"
	prop_dist_pct_spin.set_pill_width(48)
	sandbox_row.add_child(prop_dist_pct_spin)
	sandbox_row.add_child(_mk_label("Prop X"))
	prop_x_spin = _mk_spin(-40.0, 40.0, 1.0, false)
	prop_x_spin.value = 0.0
	prop_x_spin.set_default_value(0.0)
	prop_x_spin.suffix = " m"
	prop_x_spin.set_pill_width(52)
	sandbox_row.add_child(prop_x_spin)
	var add_wall_btn := _mk_button("+ WALL")
	add_wall_btn.tooltip_text = "Place a rigid blocking wall between shooter and target at Prop Z% / Prop X"
	add_wall_btn.pressed.connect(func():
		var d := distance_slider.value if distance_slider != null else 120.0
		var pct := (float(prop_dist_pct_spin.value) / 100.0) if prop_dist_pct_spin != null else 0.5
		var px := float(prop_x_spin.value) if prop_x_spin != null else 0.0
		add_wall(Vector3(px, 3.0, -d * pct))
	)
	sandbox_row.add_child(add_wall_btn)
	var add_ramp_btn := _mk_button("+ TERRAIN RAMP")
	add_ramp_btn.tooltip_text = "Place a sloped 3D terrain wedge/ramp with rigid collision"
	add_ramp_btn.pressed.connect(func():
		var d := distance_slider.value if distance_slider != null else 120.0
		var pct := (float(prop_dist_pct_spin.value) / 100.0) if prop_dist_pct_spin != null else 0.5
		var px := float(prop_x_spin.value) if prop_x_spin != null else 0.0
		add_terrain_ramp(Vector3(px, 2.5, -d * pct))
	)
	sandbox_row.add_child(add_ramp_btn)
	var add_pillar_btn := _mk_button("+ PILLAR")
	add_pillar_btn.tooltip_text = "Place a rigid cover pillar"
	add_pillar_btn.pressed.connect(func():
		var d := distance_slider.value if distance_slider != null else 120.0
		var pct := (float(prop_dist_pct_spin.value) / 100.0) if prop_dist_pct_spin != null else 0.5
		var px := float(prop_x_spin.value) if prop_x_spin != null else 0.0
		add_pillar(Vector3(px, 4.0, -d * pct))
	)
	sandbox_row.add_child(add_pillar_btn)
	var add_obs_btn := _mk_button("+ BOX")
	add_obs_btn.tooltip_text = "Place a rigid blocking cover box"
	add_obs_btn.pressed.connect(func():
		var d := distance_slider.value if distance_slider != null else 120.0
		var pct := (float(prop_dist_pct_spin.value) / 100.0) if prop_dist_pct_spin != null else 0.5
		var px := float(prop_x_spin.value) if prop_x_spin != null else 0.0
		add_obstacle(Vector3(px, 2.5, -d * pct), Vector3(6.0, 5.0, 2.0), "Cover")
	)
	sandbox_row.add_child(add_obs_btn)
	var clr_obs_btn := _mk_button("CLEAR PROPS")
	clr_obs_btn.pressed.connect(clear_obstacles)
	sandbox_row.add_child(clr_obs_btn)
	var add_tgt_btn := _mk_button("+ TARGET")
	add_tgt_btn.tooltip_text = "Add a secondary target beside the primary target"
	add_tgt_btn.pressed.connect(func():
		var d := distance_slider.value if distance_slider != null else 120.0
		var side := (1.0 if extra_targets.size() % 2 == 0 else -1.0) * (10.0 + float(int(extra_targets.size() / 2)) * 8.0)
		add_extra_target(Vector3(side, 2.0, -d), "Target %d" % (extra_targets.size() + 2))
	)
	sandbox_row.add_child(add_tgt_btn)
	var clr_tgt_btn := _mk_button("CLEAR TARGETS")
	clr_tgt_btn.pressed.connect(clear_extra_targets)
	sandbox_row.add_child(clr_tgt_btn)
	reset_scene_button = _mk_button("Reset Scene")
	reset_scene_button.tooltip_text = "Reset shooter/target transforms, motion pattern, aim mode, and clear all props/targets"
	reset_scene_button.pressed.connect(reset_scene_to_default)
	sandbox_row.add_child(reset_scene_button)

	# Saved 3D Scene Presets & Camera Bookmarks (Wave E / T-34)
	var preset_row := HFlowContainer.new()
	preset_row.add_theme_constant_override("h_separation", 6)
	preset_row.add_theme_constant_override("v_separation", 2)
	sc_tab.add_child(preset_row)
	preset_row.add_child(_mk_label("Scene Preset"))
	scene_preset_option = OptionButton.new()
	scene_preset_option.custom_minimum_size = Vector2(120, 0)
	scene_preset_option.tooltip_text = "Saved 3D sandbox scene presets (actors, motion, aim, props, camera)"
	preset_row.add_child(scene_preset_option)
	var save_sp_btn := _mk_button("SAVE PRESET")
	save_sp_btn.tooltip_text = "Save current 3D sandbox layout (actors, motion, props, camera) into workspace/scene_presets/"
	save_sp_btn.pressed.connect(func():
		var nm := "preset_%d" % (list_scene_presets().size() + 1)
		save_scene_preset(nm)
	)
	preset_row.add_child(save_sp_btn)
	var load_sp_btn := _mk_button("LOAD PRESET")
	load_sp_btn.pressed.connect(func():
		if scene_preset_option != null and scene_preset_option.selected >= 0:
			load_scene_preset(str(scene_preset_option.get_item_metadata(scene_preset_option.selected)))
	)
	preset_row.add_child(load_sp_btn)
	preset_row.add_child(_mk_label("Cam Bookmark"))
	cam_bookmark_option = OptionButton.new()
	cam_bookmark_option.custom_minimum_size = Vector2(110, 0)
	cam_bookmark_option.tooltip_text = "Saved 3D camera bookmarks"
	preset_row.add_child(cam_bookmark_option)
	var save_cb_btn := _mk_button("SAVE CAM")
	save_cb_btn.pressed.connect(func():
		var nm := "cam_%d" % (camera_bookmarks.size() + 1)
		save_camera_bookmark(nm)
	)
	preset_row.add_child(save_cb_btn)
	var load_cb_btn := _mk_button("LOAD CAM")
	load_cb_btn.pressed.connect(func():
		if cam_bookmark_option != null and cam_bookmark_option.selected >= 0:
			apply_camera_bookmark(str(cam_bookmark_option.get_item_metadata(cam_bookmark_option.selected)))
	)
	preset_row.add_child(load_cb_btn)
	_refresh_scene_preset_ui()
	_load_camera_bookmarks_from_disk()
	_refresh_camera_bookmark_ui()

	var sc_hint := Label.new()
	sc_hint.text = "Sandbox: configure Moving Target (Strafe/Wiggle/Orbit/Approach) to test homing missiles, switch Shooter Aim (Manual/Track/Lead/Forward), and place Walls, Terrain Ramps, Pillars, or extra Targets. RMB on any value resets to default."
	sc_hint.add_theme_color_override("font_color", Color("#9C9371"))
	sc_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sc_tab.add_child(sc_hint)

	# Tab 4: Parameter Sweep (controls + output table together in one logical tab)
	var sw_tab := VBoxContainer.new()
	sw_tab.name = "Sweep"
	bottom_tabs.add_child(sw_tab)
	var sweep_row := HFlowContainer.new()
	sweep_row.add_theme_constant_override("h_separation", 6)
	sweep_row.add_theme_constant_override("v_separation", 3)
	sw_tab.add_child(sweep_row)
	sweep_row.add_child(_mk_label("Property"))
	sweep_property = OptionButton.new()
	for p in ParameterSweep.PROPERTIES:
		sweep_property.add_item(str(p.label))
		sweep_property.set_item_metadata(sweep_property.item_count - 1, str(p.id))
	sweep_property.custom_minimum_size = Vector2(140, 0)
	sweep_property.item_selected.connect(func(_i): _sync_sweep_bounds())
	sweep_row.add_child(sweep_property)
	sweep_row.add_child(_mk_label("From"))
	sweep_from = _mk_spin(0.0, 100000.0, 0.25, false)
	sweep_from.set_pill_width(68)
	sweep_row.add_child(sweep_from)
	sweep_row.add_child(_mk_label("To"))
	sweep_to = _mk_spin(0.0, 100000.0, 0.25, false)
	sweep_to.set_pill_width(68)
	sweep_row.add_child(sweep_to)
	sweep_row.add_child(_mk_label("Steps"))
	sweep_steps = _mk_spin(2.0, float(ParameterSweep.MAX_STEPS), 1.0, false, true)
	sweep_steps.value = 5
	sweep_steps.set_pill_width(48)
	sweep_row.add_child(sweep_steps)
	var sweep_button := _mk_button("RUN SWEEP")
	sweep_button.pressed.connect(run_parameter_sweep)
	sweep_row.add_child(sweep_button)
	var sweep_save := _mk_button("SAVE CSV")
	sweep_save.pressed.connect(func(): save_sweep_csv())
	sweep_row.add_child(sweep_save)
	sweep_output = TextEdit.new()
	sweep_output.editable = false
	sweep_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sweep_output.placeholder_text = "Parameter sweep results (in-memory overrides; no files written)."
	sw_tab.add_child(sweep_output)

	# Tab 5: Native BZCC Experiment Runner (isolated from daily preview controls; P0-01 split controls)
	var nat_tab := VBoxContainer.new()
	nat_tab.name = "Native BZCC"
	bottom_tabs.add_child(nat_tab)
	var native_row := HFlowContainer.new()
	native_row.add_theme_constant_override("h_separation", 6)
	native_row.add_theme_constant_override("v_separation", 3)
	nat_tab.add_child(native_row)
	native_preflight_button = _mk_button("PREPARE EXPERIMENT")
	native_preflight_button.tooltip_text = "Read-only preflight: BZN, Lua contract, mount cfg, resource closure, and Steam route"
	native_preflight_button.pressed.connect(func(): run_native_preflight_only())
	native_row.add_child(native_preflight_button)
	native_stage_button = _mk_button("STAGE RESOURCES")
	native_stage_button.tooltip_text = "Stage isolated BZCC experiment under user://native_tests (never writes into BZ2R)"
	native_stage_button.pressed.connect(func(): run_native_stage())
	native_row.add_child(native_stage_button)
	native_launch_button = _mk_button("LAUNCH BZCC")
	native_launch_button.tooltip_text = "Explicitly launch BZCC via Steam (-applaunch 624970) after preflight and staging"
	native_launch_button.pressed.connect(func(): run_native_launch(true))
	native_row.add_child(native_launch_button)
	native_handoff_button = _mk_button("MANUAL STEAM HANDOFF")
	native_handoff_button.tooltip_text = "Prepare durable operator handoff instructions (AWAITING_OPERATOR) without launching a process"
	native_handoff_button.pressed.connect(func(): run_native_handoff())
	native_row.add_child(native_handoff_button)
	native_collect_button = _mk_button("COLLECT RESULTS")
	native_collect_button.tooltip_text = "Collect and validate BZCC WriteToFile observation against Godot prediction"
	native_collect_button.pressed.connect(func(): run_native_collect())
	native_row.add_child(native_collect_button)
	native_compare_button = _mk_button("COMPARE")
	native_compare_button.tooltip_text = "Compare collected native observation against Godot prediction"
	native_compare_button.pressed.connect(func(): run_native_collect())
	native_row.add_child(native_compare_button)
	native_cleanup_button = _mk_button("CLEANUP")
	native_cleanup_button.tooltip_text = "MD5-verified SafeStageManager cleanup (preserves modified/unknown files)"
	native_cleanup_button.pressed.connect(func(): run_native_cleanup())
	native_row.add_child(native_cleanup_button)
	native_status_label = Label.new()
	native_status_label.text = "Native: idle (NATIVE_VERIFIED: 0)"
	native_status_label.add_theme_color_override("font_color", Color("#9C9371"))
	nat_tab.add_child(native_status_label)


func _build_world() -> void:
	world = Node3D.new()
	world.name = "TestRange"
	viewport.add_child(world)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#1c1408")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#887b66")
	e.ambient_light_energy = 0.65
	e.fog_enabled = false
	env.environment = e
	world.add_child(env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52, -35, 0)
	light.light_color = Color("#fff3dc")
	light.light_energy = 0.95
	light.shadow_enabled = true
	world.add_child(light)

	var ground := MeshInstance3D.new()
	ground.name = "GroundMesh"
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color("#2a2317")
	gm.roughness = 1.0
	ground.material_override = gm
	world.add_child(ground)

	# Rigid floor StaticBody3D (top plane at exact y = 0.0) so rigid bodies,
	# raycasts, and floor-bouncing effects never clip beneath the floor.
	ground_body = StaticBody3D.new()
	ground_body.name = "RigidFloor"
	var gcol := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(600.0, 2.0, 600.0)
	gcol.shape = gbox
	gcol.position = Vector3(0.0, -1.0, 0.0)
	ground_body.add_child(gcol)
	world.add_child(ground_body)

	var grid := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in range(-15, 16):
		var x := float(i) * 20.0
		var col := Color("#665033") if i % 5 != 0 else Color("#95804C")
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(x, 0.02, -300))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(x, 0.02, 300))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(-300, 0.02, x))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(300, 0.02, x))
	im.surface_end()
	grid.mesh = im
	grid.material_override = mat
	world.add_child(grid)

	shooter_node = _make_placeholder("SHOOTER", Color("#4a6b63"), Vector3(4, 2.2, 6))
	shooter_node.position = Vector3(0, 1.1, 0)
	world.add_child(shooter_node)
	hardpoint_markers_root = Node3D.new()
	hardpoint_markers_root.name = "HardpointMarkers"
	world.add_child(hardpoint_markers_root)
	aim_overlay = MeshInstance3D.new()
	aim_overlay.name = "AimOverlay"
	world.add_child(aim_overlay)
	bbox_overlay = MeshInstance3D.new()
	bbox_overlay.name = "BBoxOverlay"
	world.add_child(bbox_overlay)
	target_node = _make_placeholder("TARGET", Color("#7a3a2a"), Vector3(3.2, 3.0, 5))
	target_node.position = Vector3(0, 1.5, -120)
	world.add_child(target_node)
	projectile_root = Node3D.new()
	world.add_child(projectile_root)
	effect_root = Node3D.new()
	world.add_child(effect_root)
	obstacles_root = Node3D.new()
	obstacles_root.name = "Obstacles"
	world.add_child(obstacles_root)
	extra_targets_root = Node3D.new()
	extra_targets_root.name = "ExtraTargets"
	world.add_child(extra_targets_root)

	camera = Camera3D.new()
	camera.fov = 55
	world.add_child(camera)
	audio_pool.clear()
	for _ch in range(AUDIO_POOL_SIZE):
		var ap := AudioStreamPlayer.new()
		add_child(ap)
		audio_pool.append(ap)
	audio_player = audio_pool[0]
	_update_camera()
	_update_target_position()


func _make_placeholder(title: String, color: Color, size: Vector3) -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.75
	m.emission_enabled = true
	m.emission = color * 0.12
	mesh.material_override = m
	root.add_child(mesh)
	var label := Label3D.new()
	label.text = title + "\nPLACEHOLDER MESH"
	label.font_size = 28
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color("#E2CA95")
	label.outline_modulate = Color(0, 0, 0, 0.8)
	label.outline_size = 6
	label.position = Vector3(0, size.y * 0.5 + 2.2, 0)
	root.add_child(label)
	return root


func _update_camera() -> void:
	if camera == null:
		return
	var offset := Vector3(
		sin(_cam_yaw) * cos(_cam_pitch),
		sin(_cam_pitch),
		cos(_cam_yaw) * cos(_cam_pitch)
	) * _cam_dist
	camera.look_at_from_position(_cam_focus + offset, _cam_focus, Vector3.UP)


func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_drag_last = mb.position
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_cam_dist = max(6.0, _cam_dist * 0.88)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_cam_dist = min(240.0, _cam_dist * 1.12)
			_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var d := mm.position - _drag_last
		_drag_last = mm.position
		_cam_yaw -= d.x * 0.008
		_cam_pitch = clamp(_cam_pitch + d.y * 0.008, deg_to_rad(-10), deg_to_rad(80))
		_update_camera()


func _on_distance_changed(v: float) -> void:
	if distance_spin.value != v:
		distance_spin.set_value_no_signal(v)
	_update_target_position()


func set_target_motion_mode(mode: String, auto_enable_speed: bool = false) -> bool:
	var clean := mode.strip_edges().to_lower()
	if not TARGET_MOTION_MODES.has(clean):
		return false
	target_motion_mode = clean
	if target_motion_option != null:
		for i in target_motion_option.item_count:
			if str(target_motion_option.get_item_metadata(i)) == clean:
				target_motion_option.select(i)
				break
	if clean == "stationary":
		_target_velocity = Vector3.ZERO
	elif auto_enable_speed and target_speed_spin != null and float(target_speed_spin.value) <= 0.01:
		target_speed_spin.value = 14.0
	_update_target_position()
	status_changed.emit("Target motion pattern: " + clean, "muted")
	return true


func set_shooter_aim_mode(mode: String) -> bool:
	var clean := mode.strip_edges().to_lower()
	if not SHOOTER_AIM_MODES.has(clean):
		return false
	shooter_aim_mode = clean
	if shooter_aim_option != null:
		for i in shooter_aim_option.item_count:
			if str(shooter_aim_option.get_item_metadata(i)) == clean:
				shooter_aim_option.select(i)
				break
	_apply_aim_transform()
	status_changed.emit("Shooter aim mode: " + clean, "muted")
	return true


func _compute_target_motion_offset() -> Vector3:
	if target_motion_mode == "stationary":
		return Vector3.ZERO
	var spd := float(target_speed_spin.value) if target_speed_spin != null else 0.0
	if spd <= 0.001:
		return Vector3.ZERO
	var amp := float(target_amp_spin.value) if target_amp_spin != null else 18.0
	var freq := float(target_freq_spin.value) if target_freq_spin != null else 1.0
	var ph := _target_phase
	match target_motion_mode:
		"wiggle":
			return Vector3(
				sin(ph) * amp + sin(ph * (2.3 * freq)) * (amp * 0.35),
				0.0,
				cos(ph * (1.4 * freq)) * (amp * 0.4)
			)
		"orbit":
			return Vector3(sin(ph) * amp, 0.0, (cos(ph) - 1.0) * amp * 0.75)
		"approach":
			return Vector3(sin(ph * 0.5) * (amp * 0.25), 0.0, sin(ph) * amp)
		_:
			# "strafe"
			return Vector3(sin(ph) * amp, 0.0, 0.0)


func _update_target_position() -> void:
	if target_node == null:
		return
	var d := distance_slider.value if distance_slider != null else 120.0
	var y_off := 1.5
	if bool(target_model_info.get("ok", false)):
		var b: AABB = target_model_info.get("bounds", AABB())
		y_off = maxf(0.0, -b.position.y)
	var motion_off := _compute_target_motion_offset()
	target_node.position = Vector3(
		target_pos_offset.x + motion_off.x,
		y_off + target_pos_offset.y + motion_off.y,
		-d + target_pos_offset.z + motion_off.z
	)
	target_node.rotation_degrees.y = target_yaw_offset_deg
	if active_camera_preset == "overview":
		_cam_focus = Vector3(0, 2, -d * 0.55)
		_cam_dist = clamp(28.0 + d * 0.35, 28.0, 180.0)
	_update_camera()
	_update_aim_overlay()


func apply_camera_preset(preset_id: String) -> bool:
	var pid := preset_id.strip_edges().to_lower()
	if not CAMERA_PRESETS.has(pid):
		return false
	active_camera_preset = pid
	var d := distance_slider.value if distance_slider != null else 120.0
	var sp := shooter_node.position if shooter_node != null else Vector3.ZERO
	var tp := target_node.position if target_node != null else Vector3(0, 2, -d)
	match pid:
		"overview":
			_cam_focus = Vector3(0, 2.0, -d * 0.55)
			_cam_yaw = deg_to_rad(42.0)
			_cam_pitch = deg_to_rad(18.0)
			_cam_dist = clampf(28.0 + d * 0.35, 28.0, 180.0)
		"muzzle":
			_cam_focus = sp + Vector3(0, 2.0, -3.0)
			_cam_yaw = deg_to_rad(25.0)
			_cam_pitch = deg_to_rad(10.0)
			_cam_dist = 14.0
		"target":
			_cam_focus = tp + Vector3(0, 1.8, 0.0)
			_cam_yaw = deg_to_rad(32.0)
			_cam_pitch = deg_to_rad(16.0)
			_cam_dist = 18.0
		"side":
			_cam_focus = (sp + tp) * 0.5 + Vector3(0, 2.0, 0)
			_cam_yaw = deg_to_rad(90.0)
			_cam_pitch = deg_to_rad(8.0)
			_cam_dist = clampf(d * 0.85, 24.0, 180.0)
		"top":
			_cam_focus = (sp + tp) * 0.5
			_cam_yaw = deg_to_rad(0.0)
			_cam_pitch = deg_to_rad(78.0)
			_cam_dist = clampf(d * 0.95, 30.0, 200.0)
	if camera_preset_option != null:
		for i in camera_preset_option.item_count:
			if str(camera_preset_option.get_item_metadata(i)) == pid:
				camera_preset_option.select(i)
				break
	_update_camera()
	status_changed.emit("Camera preset: " + pid.capitalize(), "muted")
	return true


# --------------------------------------------------- Camera Bookmarks & Scene Presets (T-34)

func _camera_bookmarks_path() -> String:
	return ProjectSettings.globalize_path(WorkspaceStore.root().path_join("camera_bookmarks.json"))


func _scene_presets_dir() -> String:
	return ProjectSettings.globalize_path(WorkspaceStore.root().path_join("scene_presets"))


func _sanitize_preset_name(raw_name: String) -> String:
	var s := raw_name.strip_edges().to_lower()
	var out := ""
	for i in s.length():
		var c := s.substr(i, 1)
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out += c
		elif c == " ":
			out += "_"
	return out if out != "" else "preset"


func _load_camera_bookmarks_from_disk() -> void:
	camera_bookmarks.clear()
	var p := _camera_bookmarks_path()
	if not FileAccess.file_exists(p):
		return
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(p))
	if bool(jres.get("ok", false)) and jres.get("data", null) is Dictionary:
		camera_bookmarks = (jres.get("data", {}) as Dictionary).duplicate(true)


func _refresh_camera_bookmark_ui() -> void:
	if cam_bookmark_option == null:
		return
	cam_bookmark_option.clear()
	var names := list_camera_bookmarks()
	if names.is_empty():
		cam_bookmark_option.add_item("(no bookmarks)")
		cam_bookmark_option.set_item_metadata(0, "")
		return
	for nm in names:
		cam_bookmark_option.add_item(nm)
		cam_bookmark_option.set_item_metadata(cam_bookmark_option.item_count - 1, nm)


func list_camera_bookmarks() -> Array[String]:
	var out: Array[String] = []
	for k in camera_bookmarks.keys():
		out.append(str(k))
	out.sort()
	return out


func save_camera_bookmark(bookmark_name: String) -> Dictionary:
	var nm := _sanitize_preset_name(bookmark_name)
	var rec := {
		"name": nm,
		"focus": [_cam_focus.x, _cam_focus.y, _cam_focus.z],
		"yaw": _cam_yaw,
		"pitch": _cam_pitch,
		"dist": _cam_dist,
		"preset": active_camera_preset,
	}
	camera_bookmarks[nm] = rec
	var p := _camera_bookmarks_path()
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var wres := WorkspaceStore.atomic_write_abs(p, JSON.stringify(camera_bookmarks, "  ").to_utf8_buffer())
	_refresh_camera_bookmark_ui()
	status_changed.emit("Saved camera bookmark: " + nm, "success")
	return {"ok": bool(wres.get("ok", false)), "name": nm, "bookmark": rec, "path": p}


func apply_camera_bookmark(bookmark_name: String) -> bool:
	var nm := _sanitize_preset_name(bookmark_name)
	if not camera_bookmarks.has(nm):
		_load_camera_bookmarks_from_disk()
	if not camera_bookmarks.has(nm):
		return false
	var rec: Dictionary = camera_bookmarks[nm]
	var foc: Array = rec.get("focus", [0.0, 2.0, -60.0])
	if foc.size() >= 3:
		_cam_focus = Vector3(float(foc[0]), float(foc[1]), float(foc[2]))
	_cam_yaw = float(rec.get("yaw", _cam_yaw))
	_cam_pitch = float(rec.get("pitch", _cam_pitch))
	_cam_dist = float(rec.get("dist", _cam_dist))
	active_camera_preset = "bookmark:" + nm
	_update_camera()
	status_changed.emit("Applied camera bookmark: " + nm, "success")
	return true


func _refresh_scene_preset_ui() -> void:
	if scene_preset_option == null:
		return
	scene_preset_option.clear()
	var names := list_scene_presets()
	if names.is_empty():
		scene_preset_option.add_item("(no presets)")
		scene_preset_option.set_item_metadata(0, "")
		return
	for nm in names:
		scene_preset_option.add_item(nm)
		scene_preset_option.set_item_metadata(scene_preset_option.item_count - 1, nm)


func list_scene_presets() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(_scene_presets_dir())
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.to_lower().ends_with(".json"):
			out.append(n.get_basename())
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func capture_scene_preset(preset_name: String) -> Dictionary:
	var obs_arr: Array[Dictionary] = []
	for obs in obstacles:
		var op: Vector3 = obs.get("position", Vector3.ZERO)
		var osz: Vector3 = obs.get("size", Vector3(4, 4, 2))
		obs_arr.append({
			"label": str(obs.get("label", "Cover")),
			"shape": str(obs.get("shape", "box")),
			"color": str(obs.get("color", "#5a4d38")),
			"position": [op.x, op.y, op.z],
			"size": [osz.x, osz.y, osz.z],
		})
	var et_arr: Array[Dictionary] = []
	for et in extra_targets:
		var ep: Vector3 = et.get("position", Vector3.ZERO)
		et_arr.append({
			"name": str(et.get("name", "Target")),
			"position": [ep.x, ep.y, ep.z],
			"max_health": float(et.get("max_health", 1000.0)),
		})
	return {
		"schema_version": 1,
		"name": _sanitize_preset_name(preset_name),
		"shooter_path": shooter_path,
		"target_path": target_path,
		"distance": distance_slider.value if distance_slider != null else 120.0,
		"pitch": elevation_spin.value if elevation_spin != null else 0.0,
		"yaw": yaw_spin.value if yaw_spin != null else 0.0,
		"target_motion_mode": target_motion_mode,
		"target_speed": target_speed_spin.value if target_speed_spin != null else 0.0,
		"target_amp": target_amp_spin.value if target_amp_spin != null else 18.0,
		"target_freq": target_freq_spin.value if target_freq_spin != null else 1.0,
		"target_pos_offset": [target_pos_offset.x, target_pos_offset.y, target_pos_offset.z],
		"target_yaw_offset_deg": target_yaw_offset_deg,
		"shooter_aim_mode": shooter_aim_mode,
		"shooter_pos_offset": [shooter_pos_offset.x, shooter_pos_offset.y, shooter_pos_offset.z],
		"shooter_yaw_offset_deg": shooter_yaw_offset_deg,
		"shooter_speed": shooter_speed_spin.value if shooter_speed_spin != null else 0.0,
		"obstacles": obs_arr,
		"extra_targets": et_arr,
		"camera": {
			"focus": [_cam_focus.x, _cam_focus.y, _cam_focus.z],
			"yaw": _cam_yaw,
			"pitch": _cam_pitch,
			"dist": _cam_dist,
			"preset": active_camera_preset,
		},
	}


func save_scene_preset(preset_name: String) -> Dictionary:
	var nm := _sanitize_preset_name(preset_name)
	var data := capture_scene_preset(nm)
	var dir := _scene_presets_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(nm + ".json")
	var wres := WorkspaceStore.atomic_write_abs(path, JSON.stringify(data, "  ").to_utf8_buffer())
	_refresh_scene_preset_ui()
	status_changed.emit("Saved 3D scene preset: " + nm, "success")
	return {"ok": bool(wres.get("ok", false)), "name": nm, "path": path, "data": data}


func load_scene_preset(preset_name: String) -> Dictionary:
	var nm := _sanitize_preset_name(preset_name)
	var path := _scene_presets_dir().path_join(nm + ".json")
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "preset not found: " + nm}
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {"ok": false, "error": "invalid preset JSON"}
	var d: Dictionary = jres.get("data", {})
	var sp := str(d.get("shooter_path", ""))
	var tp := str(d.get("target_path", ""))
	if sp != "" and FileAccess.file_exists(sp) and sp != shooter_path:
		set_shooter(sp)
	if tp != "" and FileAccess.file_exists(tp) and tp != target_path:
		set_target(tp)
	if distance_slider != null and d.has("distance"):
		distance_slider.value = float(d.get("distance", 120.0))
	if elevation_spin != null and d.has("pitch"):
		elevation_spin.value = float(d.get("pitch", 0.0))
	if yaw_spin != null and d.has("yaw"):
		yaw_spin.value = float(d.get("yaw", 0.0))
	set_target_motion_mode(str(d.get("target_motion_mode", "strafe")), false)
	if target_speed_spin != null:
		target_speed_spin.value = float(d.get("target_speed", 0.0))
	if target_amp_spin != null:
		target_amp_spin.value = float(d.get("target_amp", 18.0))
	if target_freq_spin != null:
		target_freq_spin.value = float(d.get("target_freq", 1.0))
	var toff: Array = d.get("target_pos_offset", [0.0, 0.0, 0.0])
	if toff.size() >= 3:
		set_target_transform(Vector3(float(toff[0]), float(toff[1]), float(toff[2])), float(d.get("target_yaw_offset_deg", 0.0)))
	set_shooter_aim_mode(str(d.get("shooter_aim_mode", "manual")))
	var soff: Array = d.get("shooter_pos_offset", [0.0, 0.0, 0.0])
	if soff.size() >= 3:
		set_shooter_transform(Vector3(float(soff[0]), float(soff[1]), float(soff[2])), float(d.get("shooter_yaw_offset_deg", 0.0)))
	if shooter_speed_spin != null:
		shooter_speed_spin.value = float(d.get("shooter_speed", 0.0))
	clear_obstacles()
	for o in d.get("obstacles", []):
		if o is Dictionary:
			var op: Array = o.get("position", [0, 2.5, -50])
			var osz: Array = o.get("size", [6, 5, 2])
			if op.size() >= 3 and osz.size() >= 3:
				add_obstacle(
					Vector3(float(op[0]), float(op[1]), float(op[2])),
					Vector3(float(osz[0]), float(osz[1]), float(osz[2])),
					str(o.get("label", "Cover")),
					str(o.get("shape", "box")),
					str(o.get("color", "#5a4d38"))
				)
	clear_extra_targets()
	for et in d.get("extra_targets", []):
		if et is Dictionary:
			var ep: Array = et.get("position", [10, 2, -100])
			if ep.size() >= 3:
				add_extra_target(Vector3(float(ep[0]), float(ep[1]), float(ep[2])), str(et.get("name", "Target")), float(et.get("max_health", -1.0)))
	var cam: Dictionary = d.get("camera", {})
	if not cam.is_empty():
		var cf: Array = cam.get("focus", [0, 2, -60])
		if cf.size() >= 3:
			_cam_focus = Vector3(float(cf[0]), float(cf[1]), float(cf[2]))
		_cam_yaw = float(cam.get("yaw", _cam_yaw))
		_cam_pitch = float(cam.get("pitch", _cam_pitch))
		_cam_dist = float(cam.get("dist", _cam_dist))
		active_camera_preset = str(cam.get("preset", "overview"))
		_update_camera()
	status_changed.emit("Loaded 3D scene preset: " + nm, "success")
	return {"ok": true, "name": nm, "data": d}


func set_shooter_transform(pos: Vector3, yaw_deg: float = 0.0) -> void:
	shooter_pos_offset = pos
	shooter_yaw_offset_deg = yaw_deg
	if shooter_offset_x_spin != null:
		shooter_offset_x_spin.set_value_no_signal(pos.x)
	if shooter_yaw_spin != null:
		shooter_yaw_spin.set_value_no_signal(yaw_deg)
	if shooter_node != null:
		var base_y := 1.1
		if bool(shooter_model_info.get("ok", false)):
			var b: AABB = shooter_model_info.get("bounds", AABB())
			base_y = maxf(0.0, -b.position.y)
		shooter_node.position = Vector3(pos.x, base_y + pos.y, pos.z)
		shooter_node.rotation_degrees.y = yaw_deg
	_apply_aim_transform()


func set_target_transform(pos_offset: Vector3, yaw_deg: float = 0.0) -> void:
	target_pos_offset = pos_offset
	target_yaw_offset_deg = yaw_deg
	if target_offset_x_spin != null:
		target_offset_x_spin.set_value_no_signal(pos_offset.x)
	if target_offset_y_spin != null:
		target_offset_y_spin.set_value_no_signal(pos_offset.y)
	if target_yaw_spin != null:
		target_yaw_spin.set_value_no_signal(yaw_deg)
	_update_target_position()


func add_obstacle(pos: Vector3, size: Vector3, label: String = "Cover", shape: String = "box", color_hex: String = "#5a4d38") -> Dictionary:
	_obstacle_seq += 1
	var oid := "obs_%d" % _obstacle_seq
	var node := StaticBody3D.new()
	node.name = "Obstacle_" + oid
	node.position = pos
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color_hex)
	mat.roughness = 0.85
	var col := CollisionShape3D.new()
	if shape == "ramp":
		var hx := size.x * 0.5
		var hy := size.y * 0.5
		var hz := size.z * 0.5
		# Sloped terrain wedge rising from front (+hz, bottom -hy) to back (-hz, top +hy).
		var v_fl := Vector3(-hx, -hy, hz)
		var v_fr := Vector3(hx, -hy, hz)
		var v_bl := Vector3(-hx, -hy, -hz)
		var v_br := Vector3(hx, -hy, -hz)
		var v_tl := Vector3(-hx, hy, -hz)
		var v_tr := Vector3(hx, hy, -hz)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for tri in [
			[v_fl, v_fr, v_tr], [v_fl, v_tr, v_tl], # sloped top face
			[v_bl, v_tl, v_tr], [v_bl, v_tr, v_br], # back vertical wall
			[v_fl, v_tl, v_bl],                     # left side triangle
			[v_fr, v_br, v_tr],                     # right side triangle
			[v_fl, v_bl, v_br], [v_fl, v_br, v_fr], # bottom face
		]:
			var n := ((tri[1] as Vector3) - (tri[0] as Vector3)).cross((tri[2] as Vector3) - (tri[0] as Vector3)).normalized()
			st.set_normal(n)
			st.add_vertex(tri[0])
			st.set_normal(n)
			st.add_vertex(tri[1])
			st.set_normal(n)
			st.add_vertex(tri[2])
		mi.mesh = st.commit()
		var cshape := ConvexPolygonShape3D.new()
		cshape.points = PackedVector3Array([v_fl, v_fr, v_bl, v_br, v_tl, v_tr])
		col.shape = cshape
	elif shape == "pillar":
		var cm := CylinderMesh.new()
		cm.top_radius = minf(size.x, size.z) * 0.5
		cm.bottom_radius = cm.top_radius
		cm.height = size.y
		cm.radial_segments = 12
		mi.mesh = cm
		var cy := CylinderShape3D.new()
		cy.radius = cm.top_radius
		cy.height = size.y
		col.shape = cy
	else:
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		var bx := BoxShape3D.new()
		bx.size = size
		col.shape = bx
	mi.material_override = mat
	node.add_child(mi)
	node.add_child(col)
	if obstacles_root != null:
		obstacles_root.add_child(node)
	var rec := {"id": oid, "label": label, "shape": shape, "position": pos, "size": size, "color": color_hex, "node": node}
	obstacles.append(rec)
	_update_aim_overlay()
	_rebuild_hud_tags()
	status_changed.emit("Added %s %s at (%.1f, %.1f, %.1f)" % [label, oid, pos.x, pos.y, pos.z], "muted")
	return rec


func add_wall(pos: Vector3, size: Vector3 = Vector3(12.0, 6.0, 1.8), label: String = "Wall") -> Dictionary:
	return add_obstacle(pos, size, label, "box", "#695e49")


func add_terrain_ramp(pos: Vector3, size: Vector3 = Vector3(14.0, 5.0, 12.0), label: String = "Terrain Ramp") -> Dictionary:
	return add_obstacle(pos, size, label, "ramp", "#4d462e")


func add_pillar(pos: Vector3, size: Vector3 = Vector3(3.0, 8.0, 3.0), label: String = "Pillar") -> Dictionary:
	return add_obstacle(pos, size, label, "pillar", "#5f5848")


func move_obstacle(oid: String, pos: Vector3, size: Vector3 = Vector3.ZERO) -> bool:
	for obs in obstacles:
		if str(obs.get("id", "")) == oid:
			obs["position"] = pos
			if size != Vector3.ZERO:
				obs["size"] = size
			var n: Node3D = obs.get("node", null)
			if is_instance_valid(n):
				n.position = pos
				if size != Vector3.ZERO and n.get_child_count() > 0 and n.get_child(0) is MeshInstance3D:
					var bm := BoxMesh.new()
					bm.size = size
					(n.get_child(0) as MeshInstance3D).mesh = bm
			_update_aim_overlay()
			_rebuild_hud_tags()
			return true
	return false


func clear_obstacles() -> void:
	obstacles.clear()
	_clear_node_children(obstacles_root)
	_update_aim_overlay()
	_rebuild_hud_tags()
	status_changed.emit("Cleared all obstacles.", "muted")


func add_extra_target(pos: Vector3, label: String = "Aux Target", max_hp: float = -1.0) -> Dictionary:
	_extra_target_seq += 1
	var tid := "target_%d" % _extra_target_seq
	var hp := max_hp if max_hp > 0.0 else (profile.target_health_max if profile != null else 1000.0)
	var rad := profile.target_radius if profile != null else 2.2
	var armor := profile.target_armor if profile != null else "H"
	var node := _make_placeholder(label, Color("#8a4630"), Vector3(3.0, 2.6, 4.6))
	node.name = "ExtraTarget_" + tid
	node.position = pos
	if extra_targets_root != null:
		extra_targets_root.add_child(node)
	var rec := {
		"id": tid,
		"name": label,
		"position": pos,
		"radius": rad,
		"health": hp,
		"max_health": hp,
		"armor": armor,
		"node": node,
	}
	extra_targets.append(rec)
	_update_aim_overlay()
	_rebuild_hud_tags()
	status_changed.emit("Added target %s at (%.1f, %.1f, %.1f)" % [label, pos.x, pos.y, pos.z], "muted")
	return rec


func clear_extra_targets() -> void:
	extra_targets.clear()
	_clear_node_children(extra_targets_root)
	_update_aim_overlay()
	_rebuild_hud_tags()
	status_changed.emit("Cleared secondary targets.", "muted")


func set_shooter(path: String) -> void:
	if default_shooter_path == "" and path != "":
		default_shooter_path = path
	shooter_path = path
	shooter_label.text = "Shooter: " + path.get_file() + "  —  " + path
	_reload_scenario()


func set_target(path: String) -> void:
	if default_target_path == "" and path != "":
		default_target_path = path
	target_path = path
	target_label.text = "Target: " + path.get_file() + "  —  " + path
	_reload_scenario()


func set_weapon_override(weapon_ref: String) -> bool:
	if shooter_path == "" or target_path == "" or weapon_ref.strip_edges() == "":
		return false
	var candidate := WeaponProfile.new()
	if not candidate.resolve(index, shooter_path, target_path, weapon_ref.strip_edges()):
		return false
	profile = candidate
	_current_health = profile.target_health_max
	_clear_projectiles()
	sim.reset()
	_update_stats()
	_update_health_display()
	_sync_sweep_property_labels()
	_sync_sweep_bounds()
	_update_chain_buttons()
	status_changed.emit("Live-swapped weapon: %s -> %s" % [profile.weapon_name, profile.ordnance_name], "success")
	scenario_loaded.emit(profile)
	return true


func reset_actors_to_default() -> void:
	if default_shooter_path != "":
		shooter_path = default_shooter_path
	elif index != null:
		shooter_path = index.resolve_path("ivtank_vsr.odf")
		if shooter_path == "":
			shooter_path = index.resolve_path("ivtank.odf")
	if default_target_path != "":
		target_path = default_target_path
	elif index != null:
		target_path = index.resolve_path("ivscav_vsr.odf")
		if target_path == "":
			target_path = index.resolve_path("ivscav.odf")
	_reload_scenario()
	status_changed.emit("Reset A/B actors to default test pair.", "success")


func reset_aim_to_default() -> void:
	var def_range := 120.0
	if profile != null and is_finite(profile.range_estimate()) and profile.range_estimate() > 5.0:
		def_range = clampf(profile.range_estimate() * 0.75, 10.0, 400.0)
	if distance_slider != null:
		distance_slider.value = def_range
	if distance_spin != null:
		distance_spin.set_value_no_signal(def_range)
	if elevation_spin != null:
		elevation_spin.value = 0.0
	if yaw_spin != null:
		yaw_spin.value = 0.0
	if speed_spin != null:
		speed_spin.value = 1.0
	if fx_button != null:
		fx_button.button_pressed = true
	if overlays_button != null:
		overlays_button.button_pressed = true
	apply_camera_preset("overview")
	restart_test()
	status_changed.emit("Reset aim, range, camera, and speed to defaults.", "success")


func reset_scene_to_default() -> void:
	target_pos_offset = Vector3.ZERO
	target_yaw_offset_deg = 0.0
	shooter_pos_offset = Vector3.ZERO
	shooter_yaw_offset_deg = 0.0
	_target_phase = 0.0
	_target_velocity = Vector3.ZERO
	_has_prev_target_pos = false
	set_target_motion_mode("strafe", false)
	set_shooter_aim_mode("manual")
	if target_speed_spin != null:
		target_speed_spin.value = 0.0
	if target_amp_spin != null:
		target_amp_spin.value = 18.0
	if target_freq_spin != null:
		target_freq_spin.value = 1.0
	if target_offset_x_spin != null:
		target_offset_x_spin.value = 0.0
	if target_offset_y_spin != null:
		target_offset_y_spin.value = 0.0
	if target_yaw_spin != null:
		target_yaw_spin.value = 0.0
	if shooter_offset_x_spin != null:
		shooter_offset_x_spin.value = 0.0
	if shooter_yaw_spin != null:
		shooter_yaw_spin.value = 0.0
	if shooter_speed_spin != null:
		shooter_speed_spin.value = 0.0
	if prop_dist_pct_spin != null:
		prop_dist_pct_spin.value = 50.0
	if prop_x_spin != null:
		prop_x_spin.value = 0.0
	if target_node != null:
		target_node.rotation_degrees.y = 0.0
	set_shooter_transform(Vector3.ZERO, 0.0)
	clear_obstacles()
	clear_extra_targets()
	_update_target_position()
	_sync_target_bbox_to_profile()
	_update_aim_overlay()
	status_changed.emit("Reset 3D sandbox scene (cleared props/targets and centered actors).", "success")


func _reload_scenario() -> void:
	if shooter_path == "" or target_path == "":
		return
	profile = WeaponProfile.new()
	var ok := profile.resolve(index, shooter_path, target_path)
	_current_health = profile.target_health_max if profile != null else 1000.0
	_clear_projectiles()
	sim.reset()
	fx_log.clear()
	timeline_events.clear()
	_has_last_impact = false
	_target_phase = 0.0
	spawned_effects = 0
	telemetry.text = ""
	_rebuild_actor_models()
	for err in profile.errors:
		_append_telemetry(0.0, "ERROR", err)
	for note in profile.notes:
		_append_telemetry(0.0, "NOTE", note)
	if ok and is_finite(profile.range_estimate()) and profile.range_estimate() > 5.0:
		var fit: float = clampf(profile.range_estimate() * 0.75, 10.0, 400.0)
		distance_slider.value = fit
		distance_spin.set_value_no_signal(fit)
		_update_target_position()
	_apply_aim_transform()
	_update_stats()
	_update_health_display()
	_sync_sweep_property_labels()
	_sync_sweep_bounds()
	_update_chain_buttons()
	if ok:
		status_changed.emit("Scenario: %s -> %s" % [profile.weapon_name, profile.ordnance_name], "success")
		scenario_loaded.emit(profile)
	else:
		status_changed.emit("Scenario incomplete: " + "; ".join(profile.errors), "danger")
		_append_telemetry(0.0, "ERROR", "Scenario incomplete; firing is disabled until the chain resolves.")


func _update_chain_buttons() -> void:
	if chain_a_button != null:
		var a_base := shooter_path.get_file().get_basename() if shooter_path != "" else "(none)"
		var a_gname := index.get_game_name(shooter_path) if (index != null and shooter_path != "") else ""
		var a_title := ("%s (%s)" % [a_base, a_gname]) if (a_gname != "" and a_gname.to_lower() != a_base.to_lower()) else a_base
		var a_msh := ""
		if bool(shooter_model_info.get("ok", false)):
			a_msh = " [" + str((shooter_model_info.get("provenance", {}) as Dictionary).get("msh_path", "")).get_file() + "]"
		chain_a_button.text = "A: %s%s" % [a_title, a_msh]
	if chain_b_button != null:
		var b_base := target_path.get_file().get_basename() if target_path != "" else "(none)"
		var b_gname := index.get_game_name(target_path) if (index != null and target_path != "") else ""
		var b_title := ("%s (%s)" % [b_base, b_gname]) if (b_gname != "" and b_gname.to_lower() != b_base.to_lower()) else b_base
		var b_msh := ""
		if bool(target_model_info.get("ok", false)):
			b_msh = " [" + str((target_model_info.get("provenance", {}) as Dictionary).get("msh_path", "")).get_file() + "]"
		chain_b_button.text = "B: %s%s" % [b_title, b_msh]
	if profile != null:
		if chain_wpn_button != null:
			var w_gname := index.get_game_name(profile.weapon_path) if (index != null and profile.weapon_path != "") else ""
			var w_lbl := profile.weapon_name if profile.weapon_name != "" else "-"
			if w_gname != "" and w_gname.to_lower() != w_lbl.to_lower():
				w_lbl += " (" + w_gname + ")"
			chain_wpn_button.text = "-> Wpn: " + w_lbl
			chain_wpn_button.disabled = (profile.weapon_path == "")
		if chain_ord_button != null:
			chain_ord_button.text = "-> Ord: " + (profile.ordnance_name if profile.ordnance_name != "" else "-")
			chain_ord_button.disabled = (profile.ordnance_path == "")
		if chain_xpl_button != null:
			var xn := profile.xpl_vehicle if profile.xpl_vehicle != "" else profile.xpl_ground
			chain_xpl_button.text = "-> Xpl: " + (xn if xn != "" else "-")
			chain_xpl_button.disabled = (xn == "")


func _sync_target_bbox_to_profile() -> void:
	if profile == null:
		return
	var tb: AABB = target_model_info.get("bounds", AABB(Vector3(-1.6, -1.5, -2.5), Vector3(3.2, 3.0, 5.0)))
	profile.target_half_extents = tb.size * 0.5
	# _shot_geometry().target already places target_pos.y at target_node.position.y + local_aabb_center.y,
	# so only horizontal X/Z center offsets need to be added to target_pos.
	var local_aabb_center := tb.position + tb.size * 0.5
	profile.target_bbox_offset = Vector3(local_aabb_center.x, 0.0, local_aabb_center.z)
	profile.target_yaw_rad = deg_to_rad(target_yaw_offset_deg)
	if profile.alt != null:
		profile.alt.target_half_extents = profile.target_half_extents
		profile.alt.target_bbox_offset = profile.target_bbox_offset
		profile.alt.target_yaw_rad = profile.target_yaw_rad


func _clear_node_children(n: Node) -> void:
	if n == null:
		return
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


func _rebuild_actor_models() -> void:
	shooter_model_info = {}
	target_model_info = {}
	shooter_hardpoint_node = null
	hardpoint_mode = "editor-defined"
	if shooter_node == null or target_node == null or profile == null:
		return
	_clear_node_children(shooter_node)
	if profile.shooter_geometry != "":
		var msh_path := BzMeshReaderScript.resolve_msh_for_geometry(index, profile.shooter_geometry, profile.shooter_path, profile.shooter_geometry_scale)
		if msh_path != "":
			var res := BzMeshReaderScript.build_scene(msh_path, index, "DOCB .msh (from %s)" % profile.shooter_geometry)
			if bool(res.get("ok", false)):
				shooter_model_info = res
				var root: Node3D = res.root
				shooter_node.add_child(root)
				var b: AABB = res.bounds
				shooter_node.position = Vector3(shooter_pos_offset.x, maxf(0.0, -b.position.y) + shooter_pos_offset.y, shooter_pos_offset.z)
				shooter_node.rotation_degrees.y = shooter_yaw_offset_deg
				_recoil_node = _find_node_ci(root, profile.recoil_node_name) if profile.recoil_node_name != "" else null
				if _recoil_node != null:
					_recoil_rest_pos = _recoil_node.position
				else:
					_recoil_rest_pos = Vector3.ZERO
				_recoil_offset = 0.0
				_add_model_label(shooter_node, profile.shooter_path.get_file().get_basename(), "DOCB .msh: " + msh_path.get_file(), b.size.y + maxf(0.0, -b.position.y))
				var hps: Dictionary = res.get("hardpoints", {})
				var wanted := profile.weapon_hardpoint.to_lower()
				if wanted != "" and hps.has(wanted):
					shooter_hardpoint_node = hps[wanted]
					hardpoint_mode = "mesh:" + wanted
				elif hps.has("hp_cannon_1"):
					shooter_hardpoint_node = hps["hp_cannon_1"]
					hardpoint_mode = "mesh:hp_cannon_1"
				var prov: Dictionary = res.get("provenance", {})
				shooter_label.text = "Shooter: %s — %s (%d tris, %d nodes, hp=%s)" % [
					profile.shooter_path.get_file(), msh_path.get_file(),
					int(prov.get("triangle_count", 0)), int(prov.get("node_count", 0)),
					hardpoint_mode
				]
	if not bool(shooter_model_info.get("ok", false)):
		var ph := _make_placeholder("SHOOTER", Color("#4a6b63"), Vector3(4, 2.2, 6))
		for c in ph.get_children():
			ph.remove_child(c)
			shooter_node.add_child(c)
		ph.queue_free()
		shooter_node.position = Vector3(0, 1.1, 0)
		shooter_label.text = "Shooter: %s — PLACEHOLDER MESH (hp=editor-defined)" % profile.shooter_path.get_file()

	_clear_node_children(target_node)
	if profile.target_geometry != "":
		var tmsh := BzMeshReaderScript.resolve_msh_for_geometry(index, profile.target_geometry, profile.target_path, profile.target_geometry_scale)
		if tmsh != "":
			var tres := BzMeshReaderScript.build_scene(tmsh, index, "DOCB .msh (from %s)" % profile.target_geometry)
			if bool(tres.get("ok", false)):
				target_model_info = tres
				var troot: Node3D = tres.root
				target_node.add_child(troot)
				var tb: AABB = tres.bounds
				_add_model_label(target_node, profile.target_path.get_file().get_basename(), "DOCB .msh: " + tmsh.get_file(), tb.size.y + maxf(0.0, -tb.position.y))
				var tprov: Dictionary = tres.get("provenance", {})
				target_label.text = "Target: %s — %s (%d tris)" % [
					profile.target_path.get_file(), tmsh.get_file(), int(tprov.get("triangle_count", 0))
				]
	if not bool(target_model_info.get("ok", false)):
		var tph := _make_placeholder("TARGET", Color("#7a3a2a"), Vector3(3.2, 3.0, 5))
		for c in tph.get_children():
			tph.remove_child(c)
			target_node.add_child(c)
		tph.queue_free()
		target_label.text = "Target: %s — PLACEHOLDER MESH" % profile.target_path.get_file()
	_populate_hardpoint_picker()
	_sync_target_bbox_to_profile()
	_update_target_position()
	_rebuild_hud_tags()


func _populate_hardpoint_picker() -> void:
	if hardpoint_option == null:
		return
	hardpoint_option.clear()
	if bool(shooter_model_info.get("ok", false)):
		var hps: Dictionary = shooter_model_info.get("hardpoints", {})
		var keys: Array = hps.keys()
		keys.sort()
		var sel_idx := 0
		for k in keys:
			var nm := str(k)
			hardpoint_option.add_item(nm)
			if hardpoint_mode == "mesh:" + nm:
				sel_idx = hardpoint_option.item_count - 1
		if hardpoint_option.item_count > 0:
			hardpoint_option.select(sel_idx)
			hardpoint_option.disabled = false
			return
	hardpoint_option.add_item("editor-defined")
	hardpoint_option.disabled = true


func _on_hardpoint_selected(idx: int) -> void:
	if hardpoint_option == null or idx < 0 or idx >= hardpoint_option.item_count:
		return
	select_hardpoint(hardpoint_option.get_item_text(idx))


func select_hardpoint(hp_name: String) -> bool:
	if not bool(shooter_model_info.get("ok", false)):
		return false
	var hps: Dictionary = shooter_model_info.get("hardpoints", {})
	var key := hp_name.strip_edges().to_lower()
	if not hps.has(key):
		return false
	shooter_hardpoint_node = hps[key]
	hardpoint_mode = "mesh:" + key
	if hardpoint_option != null:
		for i in hardpoint_option.item_count:
			if hardpoint_option.get_item_text(i).to_lower() == key:
				hardpoint_option.select(i)
				break
	_update_aim_overlay()
	status_changed.emit("Active hardpoint: " + hardpoint_mode, "muted")
	return true


func swap_actors() -> void:
	if shooter_path == "" or target_path == "":
		status_changed.emit("Swap A↔B requires both Object A and Object B to be set.", "warning")
		return
	var tmp := shooter_path
	shooter_path = target_path
	target_path = tmp
	_reload_scenario()


func _add_model_label(parent: Node3D, title: String, subtitle: String, height_y: float) -> void:
	# Store crisp 2D screen-space HUD label metadata on the 3D node (no blurry 3D Label3D).
	parent.set_meta("hud_title", title)
	parent.set_meta("hud_subtitle", subtitle)
	parent.set_meta("hud_height_y", maxf(2.6, height_y + 0.9))
	_rebuild_hud_tags()


func _rebuild_hud_tags() -> void:
	if hud_labels_layer == null:
		return
	for c in hud_labels_layer.get_children():
		c.queue_free()
	_hud_tags.clear()
	if shooter_node != null:
		var st := str(shooter_node.get_meta("hud_title", shooter_path.get_file().get_basename() if shooter_path != "" else "Shooter"))
		var sg := index.get_game_name(shooter_path) if (index != null and shooter_path != "") else ""
		if sg != "" and not st.to_lower().contains(sg.to_lower()):
			st += " (" + sg + ")"
		var ss := str(shooter_node.get_meta("hud_subtitle", "PLACEHOLDER MESH"))
		var sh := float(shooter_node.get_meta("hud_height_y", 3.6))
		_create_hud_tag(shooter_node, "A [SHOOTER] %s · %s" % [st, ss], sh, Color("#008080"), Color("#E2CA95"))
	if target_node != null:
		var tt := str(target_node.get_meta("hud_title", target_path.get_file().get_basename() if target_path != "" else "Target"))
		var tg := index.get_game_name(target_path) if (index != null and target_path != "") else ""
		if tg != "" and not tt.to_lower().contains(tg.to_lower()):
			tt += " (" + tg + ")"
		var ts := str(target_node.get_meta("hud_subtitle", "PLACEHOLDER MESH"))
		var th := float(target_node.get_meta("hud_height_y", 4.0))
		_create_hud_tag(target_node, "B [TARGET] %s · %s" % [tt, ts], th, Color("#963030"), Color("#F2C4B5"))
	for obs in obstacles:
		var onode = obs.get("node", null)
		if onode is Node3D:
			var sz: Vector3 = obs.get("size", Vector3(4, 4, 2))
			_create_hud_tag(onode, "[OBSTACLE] " + str(obs.get("label", obs.get("name", "Cover"))), sz.y * 0.5 + 0.8, Color("#969630"), Color("#E2CA95"))
	for et in extra_targets:
		var enode = et.get("node", null)
		if enode is Node3D:
			_create_hud_tag(enode, "[B+] %s (%.0f/%.0f)" % [str(et.get("name", "Target")), float(et.get("health", 0.0)), float(et.get("max_health", 0.0))], 3.2, Color("#963030"), Color("#F2C4B5"), et)
	_update_hud_tags()


func _create_hud_tag(node: Node3D, text: String, height_y: float, border_col: Color, text_col: Color, extra_ref: Dictionary = {}) -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# UI.md Iron Law 2 & 3: zero transparency, 2px sunken/framed box on compareBack (#14120C).
	panel.add_theme_stylebox_override("panel", WintageTheme.bevel_box(Color("#14120C"), border_col, Color("#100E08"), 5, 2))
	var lbl := Label.new()
	lbl.text = text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", text_col)
	panel.add_child(lbl)
	hud_labels_layer.add_child(panel)
	_hud_tags.append({"node": node, "height_y": height_y, "panel": panel, "label": lbl, "extra_ref": extra_ref})


func _update_hud_tags() -> void:
	if hud_labels_layer == null or camera == null or viewport == null:
		return
	if not overlays_enabled:
		hud_labels_layer.visible = false
		return
	hud_labels_layer.visible = true
	var vsize := container.size if container != null else Vector2.ZERO
	if vsize.x < 10.0 or vsize.y < 10.0:
		return
	for tag in _hud_tags:
		var node = tag.get("node", null)
		var panel: PanelContainer = tag.get("panel", null)
		if not is_instance_valid(node) or not is_instance_valid(panel):
			continue
		var extra_ref: Dictionary = tag.get("extra_ref", {})
		if not extra_ref.is_empty():
			var lbl: Label = tag.get("label", null)
			if is_instance_valid(lbl):
				lbl.text = "[B+] %s (%.0f/%.0f)" % [str(extra_ref.get("name", "Target")), float(extra_ref.get("health", 0.0)), float(extra_ref.get("max_health", 0.0))]
		var wpos: Vector3 = (node as Node3D).global_position + Vector3(0.0, float(tag.get("height_y", 3.5)), 0.0)
		if camera.is_position_behind(wpos):
			panel.visible = false
			continue
		var spos := camera.unproject_position(wpos)
		var psize := panel.get_combined_minimum_size()
		var px := floorf(spos.x - psize.x * 0.5)
		var py := floorf(spos.y - psize.y - 4.0)
		panel.visible = px + psize.x > 0.0 and px < vsize.x and py + psize.y > 0.0 and py < vsize.y
		panel.position = Vector2(clampf(px, 2.0, maxf(2.0, vsize.x - psize.x - 2.0)), clampf(py, 2.0, maxf(2.0, vsize.y - psize.y - 2.0)))


func _find_node_ci(root: Node, target_name: String) -> Node3D:
	if root == null or target_name.strip_edges() == "":
		return null
	var needle := target_name.strip_edges().to_lower()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is Node3D and cur.name.to_lower() == needle:
			return cur as Node3D
		for ch in cur.get_children():
			stack.append(ch)
	return null


func _apply_aim_transform() -> void:
	if bool(shooter_model_info.get("ok", false)):
		var ty: Node3D = shooter_model_info.get("turret_y", null)
		var tx: Node3D = shooter_model_info.get("turret_x", null)
		var yaw_rad := deg_to_rad(yaw_spin.value if yaw_spin != null else 0.0)
		var pitch_rad := deg_to_rad(elevation_spin.value if elevation_spin != null else 0.0)
		if (shooter_aim_mode == "track" or shooter_aim_mode == "lead") and shooter_node != null and target_node != null:
			var aim_target := target_node.position + Vector3(0.0, 1.2, 0.0)
			if shooter_aim_mode == "lead" and profile != null and profile.shot_speed > 1.0:
				var tof := aim_target.distance_to(shooter_node.position) / profile.shot_speed
				aim_target += _target_velocity * clampf(tof, 0.0, 4.0)
			var delta_w := aim_target - (shooter_node.position + Vector3(0.0, 1.8, 0.0))
			var local_d := delta_w.rotated(Vector3.UP, -deg_to_rad(shooter_yaw_offset_deg))
			if local_d.length_squared() > 0.01:
				yaw_rad += atan2(-local_d.x, -local_d.z)
				var horiz := Vector2(local_d.x, local_d.z).length()
				pitch_rad += atan2(local_d.y, maxf(0.01, horiz))
		if ty != null:
			ty.rotation = Vector3(0.0, yaw_rad, 0.0)
		if tx != null:
			tx.rotation = Vector3(pitch_rad, 0.0, 0.0)
	_update_aim_overlay()


func _world_transform_in_lab(node: Node3D) -> Transform3D:
	var chain: Array[Node3D] = []
	var cur: Node = node
	while cur != null and cur != world:
		if cur is Node3D:
			chain.append(cur as Node3D)
		cur = cur.get_parent()
	var xf := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		xf = xf * chain[i].transform
	return xf


func _is_under_turret(node: Node3D) -> Dictionary:
	var under_y := false
	var under_x := false
	var cur: Node = node
	while cur != null and cur != shooter_node:
		var nm := cur.name.to_lower()
		if nm == "turret_y":
			under_y = true
		elif nm == "turret_x":
			under_x = true
		cur = cur.get_parent()
	return {"yaw": under_y, "pitch": under_x}


func _update_aim_overlay() -> void:
	if aim_overlay == null or hardpoint_markers_root == null:
		return
	_clear_node_children(hardpoint_markers_root)
	if bool(shooter_model_info.get("ok", false)):
		var hps: Dictionary = shooter_model_info.get("hardpoints", {})
		for hp_name in hps:
			var hp_node: Node3D = hps[hp_name]
			var xf := _world_transform_in_lab(hp_node)
			var is_active := hp_node == shooter_hardpoint_node
			var marker := MeshInstance3D.new()
			var sp := SphereMesh.new()
			sp.radius = 0.22 if is_active else 0.11
			sp.height = sp.radius * 2.0
			marker.mesh = sp
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.albedo_color = Color("#ffdf73") if is_active else Color("#6ec2a8")
			marker.material_override = m
			marker.position = xf.origin
			hardpoint_markers_root.add_child(marker)

	var geom := _shot_geometry()
	var origin: Vector3 = geom.origin
	var dir: Vector3 = geom.direction
	var target_pos: Vector3 = geom.target
	var ray_len: float = clampf((target_pos - origin).length() + 10.0, 20.0, 260.0)
	if profile != null and is_finite(profile.range_estimate()) and profile.range_estimate() > 1.0:
		ray_len = minf(ray_len, profile.range_estimate())

	# Predict hit against target 3D BBOX (or ground plane / obstacles) for visual impact marker.
	var hit_pt := origin + dir * ray_len
	var hit_kind := "ray"
	var t_ground := -1.0
	if absf(dir.y) > 0.0001 and dir.y < 0.0 and origin.y > 0.0:
		t_ground = -origin.y / dir.y
	var t_best := ray_len
	var tb: AABB = target_model_info.get("bounds", AABB(Vector3(-1.6, -1.5, -2.5), Vector3(3.2, 3.0, 5.0)))
	var t_node_pos := target_node.position if target_node != null else (target_pos - Vector3(0.0, 1.5, 0.0))
	var t_local_center := tb.position + tb.size * 0.5
	var t_yaw_rad := deg_to_rad(target_yaw_offset_deg)
	var t_world_center := t_node_pos + t_local_center.rotated(Vector3.UP, t_yaw_rad)
	var s_rad := profile.shot_radius if profile != null else 0.2
	var t_half := tb.size * 0.5 + Vector3(s_rad, s_rad, s_rad)
	var obb_t = sim._ray_obb(origin, dir * ray_len, t_world_center, t_half, t_yaw_rad)
	if obb_t != null:
		var t_hit := float(obb_t) * ray_len
		if t_hit >= 0.0 and t_hit <= t_best:
			t_best = t_hit
			hit_kind = "target"
	for obs in obstacles:
		var opos: Vector3 = obs.get("position", Vector3.ZERO)
		var osize: Vector3 = obs.get("size", Vector3(4, 4, 2))
		var obs_t = null
		if str(obs.get("shape", "box")) == "ramp":
			obs_t = sim._ray_ramp(origin, dir * ray_len, opos, osize, s_rad)
		else:
			obs_t = sim._ray_aabb(origin, dir * ray_len, opos, osize * 0.5 + Vector3(s_rad, s_rad, s_rad))
		if obs_t != null:
			var t_ohit := float(obs_t) * ray_len
			if t_ohit >= 0.0 and t_ohit < t_best:
				t_best = t_ohit
				hit_kind = "obstacle"
	if t_ground >= 0.0 and t_ground < t_best:
		t_best = t_ground
		hit_kind = "ground"
	hit_pt = origin + dir * t_best

	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var lmat := StandardMaterial3D.new()
	lmat.vertex_color_use_as_albedo = true
	lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Launch / barrel axis + trajectory ray
	im.surface_set_color(Color("#ffd27a"))
	im.surface_add_vertex(origin)
	im.surface_set_color(Color("#ff7b3b") if hit_kind == "target" else Color("#78c2ad"))
	im.surface_add_vertex(hit_pt)
	im.surface_end()
	aim_overlay.mesh = im
	aim_overlay.material_override = lmat

	if hit_kind != "ray":
		var imp := MeshInstance3D.new()
		var isp := SphereMesh.new()
		isp.radius = 0.35
		isp.height = 0.7
		imp.mesh = isp
		var imat := StandardMaterial3D.new()
		imat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		imat.albedo_color = Color("#ff5e3a")
		imp.material_override = imat
		imp.position = hit_pt
		hardpoint_markers_root.add_child(imp)
	_update_bbox_overlay()


func _update_bbox_overlay() -> void:
	if bbox_overlay == null:
		return
	if not overlays_enabled:
		bbox_overlay.mesh = null
		return
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var bmat := StandardMaterial3D.new()
	bmat.vertex_color_use_as_albedo = true
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if shooter_node != null:
		var sb: AABB = shooter_model_info.get("bounds", AABB(Vector3(-2, -1.1, -3), Vector3(4, 2.2, 6)))
		_draw_wire_aabb(im, AABB(shooter_node.position + sb.position, sb.size), Color("#6ec2a8"))
	if target_node != null:
		var tb: AABB = target_model_info.get("bounds", AABB(Vector3(-1.6, -1.5, -2.5), Vector3(3.2, 3.0, 5)))
		_draw_wire_obb(im, target_node.position, tb, deg_to_rad(target_yaw_offset_deg), Color("#e07050"))
	for obs in obstacles:
		var opos: Vector3 = obs.get("position", Vector3.ZERO)
		var osize: Vector3 = obs.get("size", Vector3(4, 4, 2))
		_draw_wire_aabb(im, AABB(opos - osize * 0.5, osize), Color("#d3b57a"))
	for et in extra_targets:
		var epos: Vector3 = et.get("position", Vector3.ZERO)
		_draw_wire_aabb(im, AABB(epos - Vector3(1.5, 1.3, 2.3), Vector3(3.0, 2.6, 4.6)), Color("#d37676"))
	if _has_last_impact:
		var p := _last_impact_pos
		var c := Color("#ffe066")
		for axis in [Vector3(1.2, 0, 0), Vector3(0, 1.2, 0), Vector3(0, 0, 1.2)]:
			im.surface_set_color(c)
			im.surface_add_vertex(p - axis)
			im.surface_set_color(c)
			im.surface_add_vertex(p + axis)
	# 3D damageRadius splash sphere wireframe overlay around impact (or target).
	if profile != null and profile.damage_radius > 0.5:
		var scenter := _last_impact_pos if _has_last_impact else (target_node.position if target_node != null else Vector3.ZERO)
		_draw_wire_sphere(im, scenter, profile.damage_radius, Color("#d48a3b"))
	im.surface_end()
	bbox_overlay.mesh = im
	bbox_overlay.material_override = bmat


func _draw_wire_sphere(im: ImmediateMesh, center: Vector3, radius: float, col: Color, segs: int = 24) -> void:
	for i in range(segs):
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		var c0 := cos(a0) * radius
		var s0 := sin(a0) * radius
		var c1 := cos(a1) * radius
		var s1 := sin(a1) * radius
		# XZ horizontal ring (clamped above floor)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(center.x + c0, maxf(0.05, center.y), center.z + s0))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(center.x + c1, maxf(0.05, center.y), center.z + s1))
		# XY ring
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(center.x + c0, maxf(0.05, center.y + s0), center.z))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(center.x + c1, maxf(0.05, center.y + s1), center.z))
		# YZ ring
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(center.x, maxf(0.05, center.y + s0), center.z + c0))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(center.x, maxf(0.05, center.y + s1), center.z + c1))


func _draw_wire_aabb(im: ImmediateMesh, box: AABB, col: Color) -> void:
	_draw_wire_obb(im, Vector3.ZERO, box, 0.0, col)


func _draw_wire_obb(im: ImmediateMesh, origin_pos: Vector3, local_box: AABB, yaw_rad: float, col: Color) -> void:
	var p := local_box.position
	var s := local_box.size
	var local_corners := [
		p, p + Vector3(s.x, 0, 0), p + Vector3(s.x, 0, s.z), p + Vector3(0, 0, s.z),
		p + Vector3(0, s.y, 0), p + Vector3(s.x, s.y, 0), p + Vector3(s.x, s.y, s.z), p + Vector3(0, s.y, s.z),
	]
	var corners: Array[Vector3] = []
	for lc in local_corners:
		corners.append(origin_pos + (lc as Vector3).rotated(Vector3.UP, yaw_rad))
	var edges := [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]
	for e in edges:
		im.surface_set_color(col)
		im.surface_add_vertex(corners[e[0]])
		im.surface_set_color(col)
		im.surface_add_vertex(corners[e[1]])


## Re-read values from the shared documents after a structured edit. The
## scenario identity is unchanged, so a full re-resolve is unnecessary.
func refresh_after_edit() -> void:
	if profile == null:
		return
	profile.refresh()
	_update_stats()
	_update_health_display()
	_sync_sweep_bounds()


## Full re-resolve after raw text can change the dependency chain itself.
func reload_after_raw_edit() -> void:
	if shooter_path != "" and target_path != "":
		_reload_scenario()


func _sweep_property_id() -> String:
	if sweep_property == null or sweep_property.selected < 0:
		return "shotSpeed"
	return str(sweep_property.get_item_metadata(sweep_property.selected))


func _current_property_value(prop: String) -> float:
	if profile == null:
		return 0.0
	match prop:
		"shotSpeed":
			return profile.shot_speed
		"lifeSpan":
			return profile.life_span
		"shotRadius":
			return profile.shot_radius
		"damageValue(H)":
			return profile.expected_damage()
	if prop.begins_with("damageValue("):
		return profile.expected_damage()
	return 0.0


func _sync_sweep_property_labels() -> void:
	if sweep_property == null:
		return
	for i in sweep_property.item_count:
		if str(sweep_property.get_item_metadata(i)).begins_with("damageValue("):
			var prop := "damageValue(%s)" % (profile.target_armor if profile != null else "H")
			sweep_property.set_item_metadata(i, prop)
			sweep_property.set_item_text(i, prop)


func _sync_sweep_bounds() -> void:
	if sweep_from == null or profile == null:
		return
	var prop := _sweep_property_id()
	var cur := _current_property_value(prop)
	var lo := 0.0
	var hi := 1.0
	if is_finite(cur) and cur > 0.0:
		lo = cur * 0.5
		hi = cur * 1.5
	sweep_from.set_value_no_signal(snappedf(lo, 0.001))
	sweep_to.set_value_no_signal(snappedf(hi, 0.001))


func _shot_geometry() -> Dictionary:
	var d := distance_slider.value if distance_slider != null else 120.0
	var target_y := 2.0
	if bool(target_model_info.get("ok", false)) and target_node != null:
		var tb: AABB = target_model_info.get("bounds", AABB())
		target_y = target_node.position.y + tb.position.y + tb.size.y * 0.5
	elif target_node != null:
		target_y = target_node.position.y + 0.5
	var target_pos := Vector3(
		target_node.position.x if target_node != null else 0.0,
		target_y,
		target_node.position.z if target_node != null else -d
	)

	var origin := (shooter_node.position + Vector3(0, 0.7, 0)) if shooter_node != null else Vector3(0, 1.8, 0)
	if shooter_hardpoint_node != null:
		var xf_o := _world_transform_in_lab(shooter_hardpoint_node)
		origin = xf_o.origin
	var yaw_val := deg_to_rad(yaw_spin.value if yaw_spin != null else 0.0)
	var pitch_val := deg_to_rad(elevation_spin.value if elevation_spin != null else 0.0)

	var dir: Vector3
	if shooter_aim_mode == "track" or shooter_aim_mode == "lead":
		var aim_pt := target_pos
		if shooter_aim_mode == "lead" and profile != null and profile.shot_speed > 1.0:
			var tof := (target_pos - origin).length() / profile.shot_speed
			aim_pt += _target_velocity * clampf(tof, 0.0, 4.0)
		dir = (aim_pt - origin).normalized()
		if absf(pitch_val) > 0.0001:
			var r_ax := dir.cross(Vector3.UP)
			if r_ax.length_squared() > 0.0001:
				dir = dir.rotated(r_ax.normalized(), pitch_val)
		if absf(yaw_val) > 0.0001:
			dir = dir.rotated(Vector3.UP, yaw_val)
	elif shooter_aim_mode == "fixed_forward":
		dir = Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, deg_to_rad(shooter_yaw_offset_deg))
		var right_f := dir.cross(Vector3.UP).normalized()
		dir = dir.rotated(right_f, pitch_val).rotated(Vector3.UP, yaw_val)
	elif shooter_hardpoint_node != null:
		var xf := _world_transform_in_lab(shooter_hardpoint_node)
		origin = xf.origin
		dir = (-xf.basis.z).normalized()
		var flags := _is_under_turret(shooter_hardpoint_node)
		if not bool(flags.get("pitch", false)):
			dir = dir.rotated(Vector3.RIGHT, pitch_val)
		if not bool(flags.get("yaw", false)):
			dir = dir.rotated(Vector3.UP, yaw_val)
	else:
		dir = (target_pos - origin).normalized()
		dir = dir.rotated(Vector3.RIGHT, pitch_val)
		dir = dir.rotated(Vector3.UP, yaw_val)
	return {"origin": origin, "direction": dir.normalized(), "target": target_pos, "hardpoint": hardpoint_mode}


func _predict_beam_endpoint(origin: Vector3, dir: Vector3, prof: WeaponProfile) -> Vector3:
	var max_len := 180.0
	if prof != null and is_finite(prof.range_estimate()) and prof.range_estimate() > 1.0:
		max_len = minf(prof.range_estimate(), 300.0)
	var t_best := max_len
	if dir.y < -0.0001 and origin.y > 0.0:
		var tg := -origin.y / dir.y
		if tg >= 0.0 and tg < t_best:
			t_best = tg
	var s_rad := prof.shot_radius if prof != null else 0.4
	var tb: AABB = target_model_info.get("bounds", AABB(Vector3(-1.6, -1.5, -2.5), Vector3(3.2, 3.0, 5.0)))
	var t_node_pos := target_node.position if target_node != null else Vector3(0, 1.5, -120)
	var t_yaw_rad := deg_to_rad(target_yaw_offset_deg)
	var t_world_center := t_node_pos + (tb.position + tb.size * 0.5).rotated(Vector3.UP, t_yaw_rad)
	var obb_t = sim._ray_obb(origin, dir * max_len, t_world_center, tb.size * 0.5 + Vector3(s_rad, s_rad, s_rad), t_yaw_rad)
	if obb_t != null:
		var th := float(obb_t) * max_len
		if th >= 0.0 and th < t_best:
			t_best = th
	for obs in obstacles:
		var opos: Vector3 = obs.get("position", Vector3.ZERO)
		var osize: Vector3 = obs.get("size", Vector3(4, 4, 2))
		var obs_t = sim._ray_ramp(origin, dir * max_len, opos, osize, s_rad) if str(obs.get("shape", "box")) == "ramp" else sim._ray_aabb(origin, dir * max_len, opos, osize * 0.5 + Vector3(s_rad, s_rad, s_rad))
		if obs_t != null:
			var toh := float(obs_t) * max_len
			if toh >= 0.0 and toh < t_best:
				t_best = toh
	return origin + dir * t_best


## Batch sweep: baseline + N deterministic shots with an in-memory override.
## Returns the same dictionary ParameterSweep.run produced (usable from tests).
func run_parameter_sweep() -> Dictionary:
	if profile == null:
		status_changed.emit("Sweep: no scenario loaded.", "warning")
		return {}
	var prop := _sweep_property_id()
	var geom := _shot_geometry()
	sweep_output.text = "Running %d points for %s…" % [int(sweep_steps.value), prop]
	var result := ParameterSweep.run(profile, prop, sweep_from.value, sweep_to.value,
		int(sweep_steps.value), geom.origin, geom.direction, geom.target)
	last_sweep = result
	sweep_output.text = format_sweep(result)
	status_changed.emit("Sweep %s: %d point(s), in-memory only." % [prop, result.get("rows", []).size()], "success")
	return result


func _scenario_label() -> String:
	if profile == null:
		return ""
	return "%s -> %s -> %s" % [
		profile.shooter_path.get_file(), profile.weapon_name, profile.ordnance_name
	]


## Writes the last sweep to user://workspace/sweeps/ and returns the absolute
## path (empty on failure). Never touches game or ODF files.
func save_sweep_csv() -> String:
	if last_sweep.is_empty():
		status_changed.emit("Sweep CSV: run a sweep first.", "warning")
		return ""
	var dir := ProjectSettings.globalize_path(WorkspaceStore.sweeps_dir())
	var mk := DirAccess.make_dir_recursive_absolute(dir)
	if mk != OK:
		status_changed.emit("Sweep CSV: cannot create " + dir + " (" + error_string(mk) + ")", "danger")
		return ""
	var prop := str(last_sweep.get("property", "sweep")).to_lower()
	prop = prop.replace("(", "_").replace(")", "")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := dir.path_join("%s_%s_sweep.csv" % [stamp, prop])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		status_changed.emit("Sweep CSV: write failed (" + error_string(FileAccess.get_open_error()) + ")", "danger")
		return ""
	f.store_string(ParameterSweep.to_csv(last_sweep, _scenario_label()))
	f.close()
	status_changed.emit("Sweep CSV saved: " + path, "success")
	return path


func format_sweep(result: Dictionary) -> String:
	if result.is_empty() or result.get("rows", []).is_empty():
		return "Sweep produced no rows."
	var prop := str(result.get("property", ""))
	var base: Dictionary = result.get("baseline", {})
	var lines: Array[String] = []
	lines.append("SWEEP %s   baseline: %s damage, %s s flight, %s   (%s)" % [
		prop, _num(float(base.get("damage", 0.0))), _num(float(base.get("time", 0.0))),
		str(base.get("kind", "-")), _num(float(base.get("range", 0.0))) + " m range"
	])
	lines.append("  value        damage      delta     time s   result")
	for row in result.get("rows", []):
		var delta := float(row.damage_delta)
		var delta_text := ("+" if delta >= 0.0 else "") + _num(delta)
		lines.append("  %-10s  %8s  %8s  %7s   %s" % [
			_num(float(row.value)), _num(float(row.damage)), delta_text,
			_num(float(row.time)), str(row.kind)
		])
	for note in result.get("notes", []):
		lines.append("  " + str(note))
	return "\n".join(lines)


func _update_stats() -> void:
	if profile == null or stats_label == null:
		return
	var rng := profile.range_estimate()
	var dps := 0.0
	if profile.shot_delay > 0.0:
		dps = profile.expected_damage() * float(profile.salvo_count) / profile.shot_delay
	var txt := "[b]%s[/b] -> [color=#D3B57A]%s[/color] -> [color=#C5AB6E]%s[/color]\n" % [
		profile.weapon_name, profile.ordnance_name, profile.target_name
	]
	txt += "speed %s m/s   life %s s   range %s   radius %s m   damage %s (%s)   est. DPS %.1f   shotDelay %.2f s" % [
		_num(profile.shot_speed), _num(profile.life_span), ("∞" if rng == INF else _num(rng)),
		_num(profile.shot_radius), _num(profile.expected_damage()), profile.target_armor, dps, profile.shot_delay
	]
	if profile.alt != null:
		txt += "\nalt: %s -> %s   speed %s m/s   damage %s (%s)" % [
			profile.alt.weapon_name, profile.alt.ordnance_name,
			_num(profile.alt.shot_speed), _num(profile.alt.expected_damage()), profile.alt.target_armor
		]
	stats_label.text = txt


func _update_health_display() -> void:
	if health_bar == null or profile == null:
		return
	health_bar.max_value = max(1.0, profile.target_health_max)
	if _current_health < 0.0:
		_current_health = profile.target_health_max
	health_bar.value = _current_health
	health_label.text = "Target hull: %.0f / %.0f  (armor %s)" % [_current_health, profile.target_health_max, profile.target_armor]
	var frac: float = _current_health / maxf(1.0, profile.target_health_max)
	target_material = null
	if target_node:
		for c in target_node.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).material_override is StandardMaterial3D:
				target_material = (c as MeshInstance3D).material_override
				target_material.albedo_color = Color("#7a3a2a").lerp(Color("#2a2317"), 1.0 - frac)
				break


func fire_once() -> void:
	if profile == null:
		status_changed.emit("No scenario loaded.", "warning")
		return
	if not profile.errors.is_empty():
		status_changed.emit("Cannot fire: " + profile.errors[0], "danger")
		return
	_fire_one()
	_running = true


func fire_alt() -> void:
	if profile == null:
		status_changed.emit("No scenario loaded.", "warning")
		return
	if profile.alt == null:
		status_changed.emit("This weapon chain declares no resolvable altName.", "warning")
		return
	_fire_one(true)
	_running = true


func start_burst() -> void:
	if profile == null or not profile.errors.is_empty():
		return
	_burst_left = max(1, profile.salvo_count)
	_burst_timer = 0.0
	_running = true
	status_changed.emit("Burst: %d shot(s)" % _burst_left, "muted")


func stop_fire() -> void:
	_continuous = false
	_burst_left = 0
	hold_button.set_pressed_no_signal(false)


func _on_pause_toggled(on: bool) -> void:
	_paused = on
	pause_button.text = "RESUME" if on else "PAUSE"


func _on_hold_toggled(on: bool) -> void:
	_continuous = on
	if on:
		_running = true
		_fire_cooldown = 0.0


func _step_once() -> void:
	_paused = true
	pause_button.set_pressed_no_signal(true)
	pause_button.text = "RESUME"
	sim.advance(1.0 / 60.0)
	_sync_projectiles()
	_refresh_telemetry()


func restart_test() -> void:
	sim.reset()
	_clear_projectiles()
	spawned_effects = 0
	fx_log.clear()
	timeline_events.clear()
	_has_last_impact = false
	_target_phase = 0.0
	telemetry.text = ""
	_running = false
	_paused = false
	_burst_left = 0
	_continuous = false
	hold_button.set_pressed_no_signal(false)
	pause_button.set_pressed_no_signal(false)
	pause_button.text = "PAUSE"
	if profile != null:
		_current_health = profile.target_health_max
	for et in extra_targets:
		et["health"] = float(et.get("max_health", _current_health))
	_rebuild_timeline_panel()
	_update_health_display()
	status_changed.emit("Test reset.", "muted")


func _fire_one(use_alt: bool = false) -> void:
	var prof := profile
	if use_alt:
		if profile == null or profile.alt == null:
			return
		prof = profile.alt
	prof.refresh()
	if prof.shot_speed <= 0.0:
		_append_telemetry(sim.sim_time, "ERROR", "shotSpeed is 0; the ordnance cannot travel.")
		return
	var geom := _shot_geometry()
	var origin: Vector3 = geom.origin
	var target_pos: Vector3 = geom.target
	var shooter_vel := Vector3.ZERO
	if shooter_speed_spin != null and absf(float(shooter_speed_spin.value)) > 0.01:
		var fwd := Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, deg_to_rad(shooter_yaw_offset_deg))
		shooter_vel = fwd * float(shooter_speed_spin.value)
	var shot := sim.spawn(prof, origin, geom.direction, target_pos, _current_health, extra_targets, obstacles, shooter_vel)
	_record_timeline(sim.sim_time, "WEAPON_ACTIVATE", "%s -> %s (hp=%s)" % [prof.weapon_name, prof.ordnance_name, hardpoint_mode], prof.weapon_path, "ordName")

	# Barrel recoil kick (APPROXIMATED from kickVeloc / recoilNameN).
	var kick_mag := clampf(absf(prof.kick_veloc) * 0.28, 0.15, 0.85) if absf(prof.kick_veloc) > 0.01 else 0.22
	_recoil_offset = kick_mag

	if effects_enabled and effect_root != null and prof.muzzle_render != "":
		var mres := EffectRuntime.build_render_ref(index, prof.muzzle_render, prof.weapon_path, origin, 1.0, true, obstacles, 0.0)
		if bool(mres.get("ok", false)) and mres.get("root", null) != null:
			effect_root.add_child(mres.root)
			spawned_effects += 1
			var mmsg := "Muzzle %s (%d emitter(s))" % [prof.muzzle_render, int(mres.emitters)]
			fx_log.append("%07.3f  %-11s %s" % [sim.sim_time, "FX_MUZZLE", mmsg])
			_record_timeline(sim.sim_time, "FX_MUZZLE", mmsg, prof.weapon_path, "flashName")

	if prof.fire_sound != "":
		_play_sound_asset(prof.fire_sound, prof.weapon_path, "SFX_FIRE")

	# World-space persistent lightning / beam effect (draw_bolt, draw_beam, ArcCannonClass).
	# Lives under effect_root so ultra-fast hitscan shots (e.g. Titan arcbolt shotSpeed=1e6,
	# lifeSpan=175e-6) still render a full crackling bolt across origin -> hit_pos over animateTime.
	var bolt_node: Node3D = null
	var is_bolt_shot := prof.is_beam_render or prof.is_beam_weapon or (prof.render_name != "" and EffectRuntime.is_bolt_or_beam_ref(index, prof.render_name, prof.ordnance_path))
	if effects_enabled and effect_root != null and is_bolt_shot:
		var bolt_ref := prof.render_name if prof.render_name != "" else prof.muzzle_render
		var bolt_ctx := prof.ordnance_path if prof.render_name != "" else prof.weapon_path
		var end_pt := _predict_beam_endpoint(origin, geom.direction, prof)
		var bres := EffectRuntime.build_bolt_beam(index, bolt_ref, bolt_ctx, origin, end_pt, 1.0, 0.05)
		if bool(bres.get("ok", false)) and bres.get("root", null) != null:
			bolt_node = bres.root
			effect_root.add_child(bolt_node)
			last_bolt_node = bolt_node
			spawned_effects += 1
			var bmsg := "Bolt/Beam %s [%s] %.1fm (%.2fs)" % [bolt_ref if bolt_ref != "" else prof.ordnance_name, str(bres.get("render_base", "draw_bolt")), origin.distance_to(end_pt), float(bres.get("duration", 0.6))]
			fx_log.append("%07.3f  %-11s %s" % [sim.sim_time, "FX_BOLT", bmsg])
			_record_timeline(sim.sim_time, "FX_BOLT", bmsg, bolt_ctx, "renderName")

	var proj_node := Node3D.new()
	proj_node.position = origin
	if (geom.direction as Vector3).length() > 0.001:
		proj_node.look_at_from_position(origin, origin + (geom.direction as Vector3), Vector3.UP)
	var attached_real_mesh := false
	if prof.shot_geometry != "" and index != null:
		var pmsh := BzMeshReaderScript.resolve_msh_for_geometry(index, prof.shot_geometry, prof.ordnance_path)
		if pmsh != "":
			var pbuilt := BzMeshReaderScript.build_scene(pmsh, index, prof.shot_geometry)
			if bool(pbuilt.get("ok", false)) and pbuilt.get("root", null) != null:
				proj_node.add_child(pbuilt.root)
				attached_real_mesh = true
	if not attached_real_mesh and bolt_node == null:
		var mesh := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		var r: float = clampf(prof.shot_radius, 0.12, 1.4)
		sphere.radius = r
		sphere.height = r * 2.0
		mesh.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color("#ffd27a")
		mat.emission_enabled = true
		mat.emission = Color("#ffb347")
		mat.emission_energy_multiplier = 2.0
		mesh.material_override = mat
		proj_node.add_child(mesh)
	if effects_enabled and prof.render_name != "" and bolt_node == null:
		var rres := EffectRuntime.build_render_ref(index, prof.render_name, prof.ordnance_path, Vector3.ZERO, 1.0, false, obstacles, 0.0)
		if bool(rres.get("ok", false)) and rres.get("root", null) != null:
			proj_node.add_child(rres.root)
	projectile_root.add_child(proj_node)
	projectiles.append({"shot": shot, "mesh": proj_node, "bolt": bolt_node})
	_refresh_telemetry()


func _record_timeline(t: float, kind: String, text: String, odf_path: String = "", key: String = "") -> void:
	timeline_events.append({
		"time": t,
		"kind": kind,
		"text": text,
		"odf_path": odf_path,
		"key": key,
		"approximated": true,
	})
	_rebuild_timeline_panel()


func _event_matches_filter(ev: Dictionary, cat: String) -> bool:
	var k := str(ev.get("kind", ""))
	match cat:
		"combat":
			return k == "WEAPON_ACTIVATE" or k == "IMPACT" or k == "OBSTACLE_HIT"
		"fx":
			return k.begins_with("FX_")
		"audio":
			return k.begins_with("SFX_")
		_:
			return true


func filter_timeline(category: String) -> Array[Dictionary]:
	_timeline_filter = category.strip_edges().to_lower()
	if _timeline_filter == "":
		_timeline_filter = "all"
	_rebuild_timeline_panel()
	return _timeline_filtered_events.duplicate(true)


func _rebuild_timeline_panel() -> void:
	_timeline_filtered_events.clear()
	var max_t := 0.0
	for ev in timeline_events:
		max_t = maxf(max_t, float(ev.get("time", 0.0)))
		if _event_matches_filter(ev, _timeline_filter):
			_timeline_filtered_events.append(ev)
	if timeline_scrub_slider != null:
		timeline_scrub_slider.max_value = maxf(0.1, max_t)
	if timeline_time_label != null:
		timeline_time_label.text = "t=%.3f s (%d/%d events)" % [sim.sim_time, _timeline_filtered_events.size(), timeline_events.size()]
	_update_audio_pool_label()
	if timeline_tree == null:
		return
	timeline_tree.clear()
	var root := timeline_tree.create_item()
	for i in _timeline_filtered_events.size():
		var ev: Dictionary = _timeline_filtered_events[i]
		var item := timeline_tree.create_item(root)
		item.set_text(0, "%.3f" % float(ev.get("time", 0.0)))
		item.set_text(1, str(ev.get("kind", "")))
		item.set_text(2, str(ev.get("text", "")))
		var odf_file := str(ev.get("odf_path", "")).get_file()
		var key_name := str(ev.get("key", ""))
		item.set_text(3, "%s · %s" % [odf_file, key_name] if odf_file != "" else key_name)
		item.set_metadata(0, i)


func select_timeline_event(idx: int) -> Dictionary:
	if idx < 0 or idx >= _timeline_filtered_events.size():
		return {}
	var ev: Dictionary = _timeline_filtered_events[idx]
	var t := float(ev.get("time", 0.0))
	if timeline_scrub_slider != null:
		timeline_scrub_slider.set_value_no_signal(t)
	if timeline_time_label != null:
		timeline_time_label.text = "t=%.3f s [%s] (%d/%d)" % [t, str(ev.get("kind", "")), idx + 1, _timeline_filtered_events.size()]
	timeline_event_selected.emit(ev)
	return ev


func scrub_timeline_to(time_s: float) -> Dictionary:
	if timeline_time_label != null:
		timeline_time_label.text = "t=%.3f s (%d/%d events)" % [time_s, _timeline_filtered_events.size(), timeline_events.size()]
	var best_idx := -1
	for i in _timeline_filtered_events.size():
		if float(_timeline_filtered_events[i].get("time", 0.0)) <= time_s + 0.0005:
			best_idx = i
	if best_idx < 0 and not _timeline_filtered_events.is_empty():
		best_idx = 0
	if best_idx >= 0:
		if timeline_tree != null and timeline_tree.get_root() != null:
			var child := timeline_tree.get_root().get_first_child()
			var cur := 0
			while child != null:
				if cur == best_idx:
					child.select(0)
					break
				cur += 1
				child = child.get_next()
		return _timeline_filtered_events[best_idx]
	return {}


func _on_timeline_item_selected() -> void:
	if timeline_tree == null:
		return
	var item := timeline_tree.get_selected()
	if item != null:
		var idx := int(item.get_metadata(0))
		if idx >= 0 and idx < _timeline_filtered_events.size():
			var ev: Dictionary = _timeline_filtered_events[idx]
			var t := float(ev.get("time", 0.0))
			if timeline_scrub_slider != null:
				timeline_scrub_slider.set_value_no_signal(t)
			if timeline_time_label != null:
				timeline_time_label.text = "t=%.3f s [%s]" % [t, str(ev.get("kind", ""))]


func _on_timeline_item_activated() -> void:
	if timeline_tree == null:
		return
	var item := timeline_tree.get_selected()
	if item != null:
		select_timeline_event(int(item.get_metadata(0)))


func _acquire_audio_player() -> AudioStreamPlayer:
	if audio_pool.is_empty():
		for _ch in range(AUDIO_POOL_SIZE):
			var ap := AudioStreamPlayer.new()
			add_child(ap)
			audio_pool.append(ap)
		audio_player = audio_pool[0]
	for ap in audio_pool:
		if is_instance_valid(ap) and not ap.playing:
			return ap
	# All channels busy -> bounded voice steal (round-robin oldest channel).
	var stolen: AudioStreamPlayer = audio_pool[_audio_pool_cursor % audio_pool.size()]
	_audio_pool_cursor = (_audio_pool_cursor + 1) % audio_pool.size()
	audio_voice_steals += 1
	if is_instance_valid(stolen):
		stolen.stop()
	return stolen


func audio_pool_status() -> Dictionary:
	var active := 0
	for ap in audio_pool:
		if is_instance_valid(ap) and ap.playing:
			active += 1
	return {
		"capacity": AUDIO_POOL_SIZE,
		"size": audio_pool.size(),
		"active": active,
		"plays": audio_plays_count,
		"steals": audio_voice_steals,
	}


func _update_audio_pool_label() -> void:
	if audio_pool_label == null:
		return
	var st := audio_pool_status()
	audio_pool_label.text = "Audio pool: %d/%d active · plays %d · steals %d" % [
		int(st.active), int(st.capacity), int(st.plays), int(st.steals)
	]


func _play_sound_asset(sound_ref: String, context_path: String, tag: String) -> Dictionary:
	if index == null or sound_ref == "":
		return {"ok": false}
	var path := index.find_asset_near(sound_ref, ["wav", "ogg", "mp3"], context_path)
	if path == "":
		return {"ok": false, "ref": sound_ref}
	var wav := WavReader.read(path)
	if wav.ok and wav.stream != null:
		var ch := _acquire_audio_player()
		var ch_idx := audio_pool.find(ch)
		if ch != null:
			ch.stream = wav.stream
			if ch.is_inside_tree():
				ch.play()
			audio_plays_count += 1
		var desc := "%s (%.2f s, ch %d/%d)" % [path.get_file(), wav.duration, ch_idx + 1, AUDIO_POOL_SIZE]
		fx_log.append("%07.3f  %-11s %s" % [sim.sim_time, tag, desc])
		_record_timeline(sim.sim_time, tag, desc, context_path, "fireSound" if tag == "SFX_FIRE" else "sound")
		return {"ok": true, "path": path, "duration": wav.duration, "time": sim.sim_time, "tag": tag, "channel": ch_idx}
	return {"ok": false, "path": path}


## Capture deterministic metrics for the current WeaponProfile + range to compare
## before/after ODF edits side-by-side.
func snapshot_shot_baseline() -> Dictionary:
	if profile == null:
		return {}
	profile.refresh()
	var geom := _shot_geometry()
	var sim_copy := ProjectileSim.new(20261121)
	var shot := sim_copy.spawn(profile, geom.origin, geom.direction, geom.target, profile.target_health_max)
	var guard := 0
	while shot.alive and guard < 4000:
		sim_copy.advance(1.0 / 60.0)
		guard += 1
	baseline_snapshot = {
		"weapon": profile.weapon_name,
		"ordnance": profile.ordnance_name,
		"damage": shot.damage_applied,
		"expected_damage": profile.expected_damage(),
		"flight_time": shot.age,
		"hit_kind": shot.hit_kind,
		"shot_speed": profile.shot_speed,
		"range_m": (geom.target - geom.origin).length(),
	}
	_append_telemetry(sim.sim_time, "SNAPSHOT", "Baseline captured: dmg=%.2f flight=%.3fs hit=%s" % [
		float(baseline_snapshot.damage), float(baseline_snapshot.flight_time), str(baseline_snapshot.hit_kind)
	])
	status_changed.emit("Captured shot baseline snapshot (dmg=%.1f)" % float(baseline_snapshot.damage), "success")
	return baseline_snapshot


func compare_with_snapshot() -> Dictionary:
	if profile == null or baseline_snapshot.is_empty():
		status_changed.emit("Compare: capture a SNAPSHOT before editing first.", "warning")
		return {"ok": false}
	profile.refresh()
	var geom := _shot_geometry()
	var sim_copy := ProjectileSim.new(20261121)
	var shot := sim_copy.spawn(profile, geom.origin, geom.direction, geom.target, profile.target_health_max)
	var guard := 0
	while shot.alive and guard < 4000:
		sim_copy.advance(1.0 / 60.0)
		guard += 1
	var dmg_delta: float = float(shot.damage_applied) - float(baseline_snapshot.get("damage", 0.0))
	var time_delta: float = float(shot.age) - float(baseline_snapshot.get("flight_time", 0.0))
	last_comparison = {
		"ok": true,
		"before": baseline_snapshot.duplicate(true),
		"after": {
			"damage": shot.damage_applied,
			"expected_damage": profile.expected_damage(),
			"flight_time": shot.age,
			"hit_kind": shot.hit_kind,
			"shot_speed": profile.shot_speed,
		},
		"damage_delta": dmg_delta,
		"flight_time_delta": time_delta,
	}
	var msg := "Before->After: dmg %.1f->%.1f (%+.1f)  flight %.3fs->%.3fs (%+.3fs)" % [
		float(baseline_snapshot.damage), shot.damage_applied, dmg_delta,
		float(baseline_snapshot.flight_time), shot.age, time_delta,
	]
	_append_telemetry(sim.sim_time, "COMPARE", msg)
	status_changed.emit(msg, "success")
	return last_comparison


func _process(delta: float) -> void:
	_update_hud_tags()
	if profile == null:
		return
	var speed: float = float(speed_spin.value) if speed_spin else 1.0
	var dt := delta * speed
	# Animate barrel recoil kick recovery smoothly.
	if _recoil_offset > 0.001:
		_recoil_offset = maxf(0.0, _recoil_offset - delta * 3.8)
		if is_instance_valid(_recoil_node):
			_recoil_node.position = _recoil_rest_pos + Vector3(0.0, 0.0, _recoil_offset)
	# Step configurable Moving Target continuously when speed > 0 (even between shots)
	# so users can observe strafe/wiggle/orbit/approach and fire homing missiles at it.
	if not _paused and target_speed_spin != null and float(target_speed_spin.value) > 0.0 and target_motion_mode != "stationary":
		var amp := maxf(2.0, float(target_amp_spin.value) if target_amp_spin != null else 18.0)
		var prev_pos := target_node.position if target_node != null else Vector3.ZERO
		_target_phase += dt * (float(target_speed_spin.value) / amp)
		_update_target_position()
		if target_node != null and dt > 0.0001:
			if _has_prev_target_pos:
				_target_velocity = (target_node.position - prev_pos) / dt
			_prev_target_pos = target_node.position
			_has_prev_target_pos = true
		if shooter_aim_mode == "track" or shooter_aim_mode == "lead":
			_apply_aim_transform()
	elif target_speed_spin == null or float(target_speed_spin.value) <= 0.001 or target_motion_mode == "stationary":
		_target_velocity = Vector3.ZERO
	if _running and not _paused:
		if target_node != null:
			var g_live := _shot_geometry()
			sim.update_live_target(g_live.target, deg_to_rad(target_yaw_offset_deg))
		sim.advance(dt)
		_sync_projectiles()
		if _continuous:
			_fire_cooldown -= dt
			if _fire_cooldown <= 0.0:
				_fire_one()
				_fire_cooldown = max(0.02, profile.shot_delay)
		if _burst_left > 0:
			_burst_timer -= dt
			if _burst_timer <= 0.0:
				_fire_one()
				_burst_left -= 1
				_burst_timer = max(0.0, salvo_delay_or_zero())
		_refresh_telemetry()
		# Keep stepping while any projectile is in flight or fire is queued.
		_running = _continuous or _burst_left > 0 or _any_alive()


func salvo_delay_or_zero() -> float:
	return profile.salvo_delay if profile != null else 0.0


func _any_alive() -> bool:
	for p in projectiles:
		var s = p.shot
		if s.alive:
			return true
	return false


func _sync_projectiles() -> void:
	var keep: Array[Dictionary] = []
	for p in projectiles:
		var s = p.shot
		var mesh = p.mesh
		var bolt = p.get("bolt", null)
		if is_instance_valid(bolt) and bolt.has_method("rebuild_mesh"):
			bolt.end_pos = s.position
			bolt.rebuild_mesh()
		if is_instance_valid(mesh):
			mesh.position = s.position
			if s.velocity.length_squared() > 0.01:
				var fwd_pt: Vector3 = s.position + s.velocity.normalized()
				if not s.position.is_equal_approx(fwd_pt):
					mesh.look_at_from_position(s.position, fwd_pt, Vector3.UP)
			if not s.alive:
				mesh.queue_free()
				_last_impact_pos = s.position
				_has_last_impact = true
				var tl_kind := "OBSTACLE_HIT" if s.hit_kind == "obstacle" else "IMPACT"
				var tl_detail := "obstacle %s blocked shot" % s.hit_obstacle_id if s.hit_kind == "obstacle" else "%s hit %s (dmg=%.1f)" % [s.hit_kind, s.hit_target_id if s.hit_target_id != "" else "primary", s.damage_applied]
				_record_timeline(sim.sim_time, tl_kind, tl_detail, profile.ordnance_path if profile != null else "", "damageValue")
				_spawn_impact_effect(s)
				if s.hit_kind == "vehicle" and (s.hit_target_id == "" or s.hit_target_id == "primary"):
					_current_health = s.target_health
					_update_health_display()
				elif not (s.splash_hits as Array).is_empty():
					_current_health = s.target_health
					_update_health_display()
				_update_bbox_overlay()
				continue
		keep.append(p)
	projectiles = keep
	_update_stats()
	_update_health_display()


func _refresh_telemetry() -> void:
	var lines: Array[String] = []
	for e in sim.events:
		lines.append("%07.3f  %-11s %s" % [float(e.time), str(e.kind), str(e.text)])
	lines.append_array(fx_log)
	telemetry.text = "\n".join(lines)
	events_changed.emit()


func _append_telemetry(t: float, kind: String, text: String) -> void:
	telemetry.text += ("\n" if telemetry.text != "" else "") + "%07.3f  %-11s %s" % [t, kind, text]


func _spawn_impact_effect(s) -> void:
	if not effects_enabled or profile == null or effect_root == null:
		return
	var declared := ""
	if s.hit_kind == "vehicle":
		declared = s.xpl_vehicle
	elif s.hit_kind == "expire":
		declared = s.xpl_expire if s.xpl_expire != "" else s.xpl_ground
	else:
		declared = s.xpl_ground
	if declared == "":
		declared = s.xpl_ground
	if declared == "":
		return
	var path: String = index.resolve_path_from(declared, profile.ordnance_path) if index != null else ""
	if path == "":
		path = declared
	var result := EffectRuntime.build(index, path, s.position, 1.0, obstacles, 0.0)
	last_fx_result = result
	if not result.ok:
		fx_log.append("%07.3f  %-11s %s" % [sim.sim_time, "FX", "Explosion effect unavailable: " + "; ".join(result.errors)])
		_refresh_telemetry()
		return
	effect_root.add_child(result.root)
	spawned_effects += 1
	var rtypes := ", ".join(PackedStringArray(result.get("render_types", [])))
	var fx_msg := "Explosion burst %s: %d emitter(s), %.2f s [%s] (APPROXIMATED)" % [
		path.get_file(), int(result.emitters), float(result.duration), rtypes]
	fx_log.append("%07.3f  %-11s %s" % [sim.sim_time, "FX", fx_msg])
	_record_timeline(sim.sim_time, "FX_EXPLOSION", fx_msg, path, "particleTypes")
	if profile.expl_sound != "":
		_play_sound_asset(profile.expl_sound, path, "SFX_XPL")
	_refresh_telemetry()


func _clear_effects() -> void:
	if effect_root == null:
		return
	for c in effect_root.get_children():
		c.queue_free()


func _clear_projectiles() -> void:
	for p in projectiles:
		if is_instance_valid(p.mesh):
			p.mesh.queue_free()
	projectiles.clear()
	_clear_effects()


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("#C5AB6E"))
	return l


func _mk_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	return b


func _bind_rmb_reset(ctrl: Control, callback: Callable) -> void:
	if ctrl == null:
		return
	ctrl.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				callback.call()
				ctrl.accept_event()
	)


func _mk_spin(min_v: float, max_v: float, step: float, show_slider: bool = false, rounded: bool = false) -> HBoxContainer:
	var s = HoudiniScrubberScript.new()
	s.configure(min_v, max_v, step, clampf(0.0, min_v, max_v), "", show_slider, false, rounded)
	return s


func _num(v: float) -> String:
	if is_inf(v):
		return "∞"
	if abs(v - round(v)) < 0.0001:
		return str(int(round(v)))
	return "%.3f" % v


func _update_native_controls(note: String = "") -> void:
	if native_status_label == null:
		return
	if active_native_session_id == "" or native_runner == null:
		native_status_label.text = note if note != "" else "Native: idle (NATIVE_VERIFIED: 0)"
		return
	var rec: Dictionary = native_runner.get_session_record(active_native_session_id)
	var st := str(rec.get("state", "IDLE"))
	var rt := str(rec.get("launch_route", ""))
	var rsn := str(rec.get("reason", ""))
	var txt := "Native [%s]: %s" % [active_native_session_id.substr(0, 18), st]
	if rt != "":
		txt += " · " + rt
	if rsn != "":
		txt += " (" + rsn + ")"
	if note != "":
		txt += " — " + note
	native_status_label.text = txt


func run_native_preflight_only(options: Dictionary = {}) -> Dictionary:
	if profile == null:
		status_changed.emit("Native preflight: load a weapon scenario first.", "warning")
		return {"ok": false}
	if native_runner == null:
		native_runner = NativeRunnerScript.new()
	var res: Dictionary = native_runner.preflight(profile, index, options)
	active_native_session_id = str(res.get("session_id", ""))
	var pre: Dictionary = res.get("preflight", {})
	var disc: Dictionary = pre.get("discovery", {})
	_append_telemetry(sim.sim_time, "NATIVE_PRE", "Session=%s  build_id=%s  route=%s  status=%s  reason=%s" % [
		active_native_session_id, str(disc.get("build_id", "UNKNOWN")), str(pre.get("launch_route", "")),
		str(pre.get("status", "")), str(pre.get("reason", ""))
	])
	for b in pre.get("blockers", []):
		_append_telemetry(sim.sim_time, "NATIVE_BLK", str(b))
	_update_native_controls()
	status_changed.emit("Native preflight: %s [%s]" % [str(pre.get("status", "")), str(pre.get("launch_route", ""))], "warning" if not bool(pre.get("launch_ready", false)) else "success")
	return res


func run_native_stage(options: Dictionary = {}) -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		var pre := run_native_preflight_only(options)
		if not bool(pre.get("ok", false)) and str(pre.get("session_id", "")) == "":
			return pre
	var res: Dictionary = native_runner.stage(active_native_session_id, {}, options)
	_append_telemetry(sim.sim_time, "NATIVE_STG", "Session=%s  state=%s  stage=%s" % [
		active_native_session_id, str(res.get("state", "FAILED")), str((res.get("staged", {}) as Dictionary).get("stage", ""))
	])
	_update_native_controls()
	status_changed.emit("Native stage: %s" % str(res.get("state", "FAILED")), "success" if bool(res.get("ok", false)) else "danger")
	return res


func run_native_launch(execute_process: bool = false, options: Dictionary = {}) -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		status_changed.emit("Native launch: run PREFLIGHT and STAGE first.", "warning")
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var opts := options.duplicate(true)
	opts["execute_process"] = execute_process
	var res: Dictionary = native_runner.launch(active_native_session_id, opts)
	_append_telemetry(sim.sim_time, "NATIVE_RUN", "Session=%s  state=%s  route=%s  reason=%s" % [
		active_native_session_id, str(res.get("state", "")), str(res.get("route", "")), str(res.get("reason", ""))
	])
	_update_native_controls()
	status_changed.emit("Native launch: %s [%s]" % [str(res.get("state", "")), str(res.get("route", ""))], "success" if bool(res.get("ok", false)) else "warning")
	return res


func run_native_handoff(options: Dictionary = {}) -> Dictionary:
	var opts := options.duplicate(true)
	opts["manual_handoff"] = true
	return run_native_launch(false, opts)


func run_native_collect(observation_path_override: String = "") -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		status_changed.emit("Native collect: no active session.", "warning")
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = native_runner.collect_observation(active_native_session_id, observation_path_override)
	_append_telemetry(sim.sim_time, "NATIVE_OBS", "Session=%s  state=%s  verified=%s  reason=%s" % [
		active_native_session_id, str(res.get("state", "")), str(res.get("verified", false)), str(res.get("reason", ""))
	])
	_update_native_controls()
	status_changed.emit("Native collect: %s" % str(res.get("state", "")), "success" if bool(res.get("ok", false)) else "warning")
	return res


func run_native_cleanup() -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		status_changed.emit("Native cleanup: no active session.", "warning")
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = native_runner.cleanup_stage(active_native_session_id)
	_append_telemetry(sim.sim_time, "NATIVE_CLN", "Session=%s  state=%s" % [active_native_session_id, str(res.get("state", ""))])
	_update_native_controls()
	status_changed.emit("Native cleanup: %s" % str(res.get("state", "")), "success" if bool(res.get("ok", false)) else "warning")
	return res


## Combined helper used by GUI self-verify: runs preflight + stage through
## NativeExperimentRunner and returns {preflight, staged, session_id}.
func run_native_preflight() -> Dictionary:
	var pre_res := run_native_preflight_only()
	if str(pre_res.get("session_id", "")) == "":
		return {"ok": false, "preflight": pre_res.get("preflight", {}), "staged": {}}
	var stg_res := run_native_stage()
	return {
		"ok": bool(pre_res.get("ok", false)) and bool(stg_res.get("ok", false)),
		"session_id": active_native_session_id,
		"preflight": pre_res.get("preflight", {}),
		"staged": stg_res.get("staged", {}),
	}
