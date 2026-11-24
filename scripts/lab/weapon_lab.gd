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
signal particle_graph_requested(path: String)
signal show_timeline_shot_requested(shot_id: int)

const AUDIO_POOL_SIZE := 8
const CAMERA_PRESETS := ["overview", "muzzle", "target", "side", "top"]
const TARGET_MOTION_MODES := ["stationary", "strafe", "wiggle", "orbit", "approach"]
const SHOOTER_AIM_MODES := ["manual", "track", "lead", "fixed_forward"]

const CombatScenarioScript = preload("res://scripts/sim/combat_scenario.gd")
var index: ResourceIndex
var schema: SchemaRegistry
var profile: WeaponProfile
var combat_scenario = CombatScenarioScript.new(20261121)
var sim: ProjectileSim = combat_scenario.sim

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
## T-76: active vehicle weapon slot and multi-barrel firing policy.
var active_weapon_slot: int = 0
var barrel_mode: String = "TANDEM"
var weapon_option: OptionButton = null
var barrel_mode_option: OptionButton = null
var _barrel_cycle: int = 0
var open_weapon_button: Button
var open_ordnance_button: Button
var show_timeline_shot_button: Button
var _volley_counter: int = 0
var last_volley_result = null

## Structured result for one multi-barrel firing decision. Ammo and energy are
## charged per accepted barrel; reload is enforced once per volley.
class VolleyResult:
	var volley_id: int = 0
	var weapon_identity: String = ""
	var weapon_path: String = ""
	var weapon_slot: int = -1
	var firing_context: String = "PRIMARY"
	var barrel_mode: String = "SINGLE"
	var firing_policy: Dictionary = {}
	var requested_barrels: Array[String] = []
	var accepted_barrels: Array[String] = []
	var rejected_barrels: Array[String] = []
	var shot_ids: Array[int] = []
	var ammo_spent: int = 0
	var energy_spent: float = 0.0
	var reload_remaining: float = 0.0
	var partial_failure: bool = false
	var complete: bool = false
	var ok: bool = false
	var failure_reasons: Array[String] = []
	## Per-barrel diagnostics: keeps exact hardpoint identity and origin status
	## even when a declared hardpoint is absent from the loaded model.
	var resolved_barrels: Array[Dictionary] = []

	func to_dict() -> Dictionary:
		return {
			"volley_id": volley_id, "weapon_identity": weapon_identity,
			"weapon_path": weapon_path, "weapon_slot": weapon_slot,
			"firing_context": firing_context, "barrel_mode": barrel_mode,
			"firing_policy": firing_policy.duplicate(true),
			"requested_barrels": requested_barrels.duplicate(),
			"accepted_barrels": accepted_barrels.duplicate(),
			"rejected_barrels": rejected_barrels.duplicate(),
			"shot_ids": shot_ids.duplicate(), "ammo_spent": ammo_spent,
			"energy_spent": energy_spent, "reload_remaining": reload_remaining,
			"partial_failure": partial_failure, "complete": complete, "ok": ok,
			"failure_reasons": failure_reasons.duplicate(),
			"state": ("PARTIAL_SUCCESS" if partial_failure else ("FIRED" if ok else "REJECTED")),
			"accepted_shots": shot_ids.size(), "rejected_shots": rejected_barrels.size(),
			"per_barrel_results": resolved_barrels.duplicate(true),
			"resource_costs": {"ammo_spent": ammo_spent, "energy_spent": energy_spent},
		}

	static func from_dict(d: Dictionary) -> VolleyResult:
		var r := VolleyResult.new()
		r.volley_id = int(d.get("volley_id", 0))
		r.weapon_identity = str(d.get("weapon_identity", ""))
		r.weapon_path = str(d.get("weapon_path", ""))
		r.weapon_slot = int(d.get("weapon_slot", -1))
		r.firing_context = str(d.get("firing_context", "PRIMARY"))
		r.barrel_mode = str(d.get("barrel_mode", "SINGLE"))
		var policy = d.get("firing_policy", {})
		r.firing_policy = (policy as Dictionary).duplicate(true) if policy is Dictionary else {}
		for v in d.get("requested_barrels", []):
			r.requested_barrels.append(str(v))
		for v in d.get("accepted_barrels", []):
			r.accepted_barrels.append(str(v))
		for v in d.get("rejected_barrels", []):
			r.rejected_barrels.append(str(v))
		for v in d.get("shot_ids", []):
			r.shot_ids.append(int(v))
		r.ammo_spent = int(d.get("ammo_spent", 0))
		r.energy_spent = float(d.get("energy_spent", 0.0))
		r.reload_remaining = float(d.get("reload_remaining", 0.0))
		r.partial_failure = bool(d.get("partial_failure", false))
		r.complete = bool(d.get("complete", false))
		r.ok = bool(d.get("ok", false))
		for v in d.get("failure_reasons", []):
			r.failure_reasons.append(str(v))
		for v in d.get("per_barrel_results", []):
			if v is Dictionary:
				r.resolved_barrels.append((v as Dictionary).duplicate(true))
		return r

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
var actor_inspector_tree: Tree
var replay_snapshot_option: OptionButton
var capture_replay_button: Button
var run_replay_button: Button
var compare_replay_button: Button
var add_dot_button: Button
var anim_clip_option: OptionButton
var anim_play_button: Button
var _anim_playing: bool = false
var _anim_clip_name: String = ""
var _anim_time_s: float = 0.0
var projectile_traj_overlay: MeshInstance3D
var last_replay_result: Dictionary = {}
var last_replay_comparison: Dictionary = {}
var _active_replay_runner = null
var _active_replay_label: String = ""
var _replay_ab_queue: Array[Dictionary] = []
var _replay_ab_results: Array[Dictionary] = []
var _replay_ab_ids: Array[String] = []
var _replay_paused: bool = false
## Single replay job owner. Only one job may exist at a time; every result
## is bound to the snapshot IDs captured when the job was created.
var _replay_job_id: int = 0
var _replay_job_type: String = ""
var _replay_job_state: String = "IDLE"
var _replay_job_snapshot_ids: Array[String] = []
var _last_actor_inspector_sig: String = ""
var hardpoint_inspector_tree: Tree = null
var _last_hardpoint_inspector_sig: String = ""
var _burst_is_first_shot: bool = true
var native_launch_mode_option: OptionButton
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
var shield_bar: ProgressBar
var shield_label: Label
var shooter_resource_label: Label
var sweep_property: OptionButton
var sweep_from: HBoxContainer
var sweep_to: HBoxContainer
var sweep_steps: HBoxContainer
var sweep_output: TextEdit
var native_session_service = null
var native_runner = null
var active_native_session_id: String = ""
var native_preflight_button: Button
var native_stage_button: Button
var native_launch_button: Button
var native_handoff_button: Button
var native_arm_manual_button: Button
var native_collect_button: Button
var native_compare_button: Button
var native_cleanup_button: Button
var native_cancel_button: Button
var native_resume_button: Button
var reset_ab_button: Button
var reset_aim_button: Button
var reset_scene_button: Button
var native_status_label: Label
var native_stage_inventory_label: Label
var last_native_stage_inventory: Array[Dictionary] = []
var native_monitor_label: Label
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
## T-222 / HP3D: viewport marker picking state. Markers carry full identity,
## never only a display name, so duplicate hardpoint aliases stay distinct.
var _hardpoint_marker_data: Array[Dictionary] = []
var _selected_hardpoint_name: String = ""
var _selected_hardpoint_node_id: int = 0
## T-223 / FIRE-3D: explicit SINGLE-fire mount chosen through marker/inspector.
var _fire_selection_hardpoint: String = ""
var _fire_selection_weapon_slot: int = -1
var _fire_selection_weapon_revision: String = ""
var _last_firing_policy: Dictionary = {}
var _drag_last := Vector2.ZERO
var _current_health := 1000.0
var _current_shield := 0.0
var last_sweep: Dictionary = {}


func setup(p_index: ResourceIndex, p_schema: SchemaRegistry, p_native_service = null) -> void:
	index = p_index
	schema = p_schema
	native_session_service = p_native_service
	if combat_scenario != null and not combat_scenario.combat_event.is_connected(_on_combat_scenario_event):
		combat_scenario.combat_event.connect(_on_combat_scenario_event)
	var rec: Dictionary = {}
	if native_session_service != null:
		native_session_service.ensure_initialized()
		native_runner = native_session_service.runner
		if not native_session_service.session_updated.is_connected(_on_native_session_updated):
			native_session_service.session_updated.connect(_on_native_session_updated)
		active_native_session_id = str(native_session_service.active_session_id)
	else:
		native_runner = NativeRunnerScript.new()
		rec = native_runner.recover_sessions()
	_build_ui()
	_build_world()
	if active_native_session_id != "":
		_update_native_controls()
	elif int(rec.get("recovered", 0)) > 0:
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
		var source_profile := _firing_source_profile()
		if source_profile != null and source_profile.weapon_path != "":
			inspect_path_requested.emit(source_profile.weapon_path)
	)
	ab_row.add_child(chain_wpn_button)

	chain_ord_button = _mk_button("-> Ord: -")
	chain_ord_button.tooltip_text = "Click to inspect/edit Ordnance ODF (damageValue, shotSpeed, lifeSpan)"
	chain_ord_button.pressed.connect(func():
		var source_profile := _firing_source_profile()
		if source_profile != null and source_profile.ordnance_path != "":
			inspect_path_requested.emit(source_profile.ordnance_path)
	)
	ab_row.add_child(chain_ord_button)

	chain_xpl_button = _mk_button("-> Xpl: -")
	chain_xpl_button.tooltip_text = "Click to open the resolved Explosion ODF in Particle Graph"
	chain_xpl_button.pressed.connect(func():
		var source_profile := _firing_source_profile()
		if source_profile != null and index != null:
			var xname := source_profile.xpl_vehicle if source_profile.xpl_vehicle != "" else source_profile.xpl_ground
			var xp := index.resolve_path_from(xname, source_profile.ordnance_path) if xname != "" else ""
			if xp != "":
				particle_graph_requested.emit(xp)
	)
	ab_row.add_child(chain_xpl_button)

	var shot_nav_row := HFlowContainer.new()
	shot_nav_row.name = "FiringSourceNavigation"
	shot_nav_row.add_theme_constant_override("h_separation", 4)
	shot_nav_row.add_theme_constant_override("v_separation", 3)
	add_child(shot_nav_row)
	open_weapon_button = _mk_button("OPEN WEAPON ODF")
	open_weapon_button.tooltip_text = "Open the exact Weapon ODF for the selected physical slot"
	open_weapon_button.pressed.connect(func(): _open_firing_source(false))
	shot_nav_row.add_child(open_weapon_button)
	open_ordnance_button = _mk_button("OPEN ORDNANCE ODF")
	open_ordnance_button.tooltip_text = "Open the exact Ordnance ODF for the selected physical slot"
	open_ordnance_button.pressed.connect(func(): _open_firing_source(true))
	shot_nav_row.add_child(open_ordnance_button)
	show_timeline_shot_button = _mk_button("SHOW TIMELINE EVENT")
	show_timeline_shot_button.tooltip_text = "Select the most recent shot for the current physical slot"
	show_timeline_shot_button.pressed.connect(func():
		if last_volley_result == null or last_volley_result.shot_ids.is_empty():
			status_changed.emit("No shot is available for Timeline navigation.", "warning")
			return
		show_timeline_shot_requested.emit(int(last_volley_result.shot_ids[-1]))
	)
	shot_nav_row.add_child(show_timeline_shot_button)

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
	# T-76: vehicle weapon slot picker (AT Stab / minigun / mortar ...).
	fire_row.add_child(_mk_label("Wpn"))
	weapon_option = OptionButton.new()
	weapon_option.custom_minimum_size = Vector2(150, 0)
	weapon_option.tooltip_text = "Vehicle weapon slot (weaponName1..N). Switch to fire AT Stab, minigun, mortar, etc."
	weapon_option.item_selected.connect(_on_weapon_slot_selected)
	fire_row.add_child(weapon_option)
	# T-76: multi-barrel policy for weapons with several weaponHardN barrels.
	fire_row.add_child(_mk_label("Barrels"))
	barrel_mode_option = OptionButton.new()
	for bm in ["TANDEM", "SALVO", "SINGLE"]:
		barrel_mode_option.add_item(bm)
		barrel_mode_option.set_item_metadata(barrel_mode_option.item_count - 1, bm)
	barrel_mode_option.select(0)
	barrel_mode_option.tooltip_text = "TANDEM: all barrels fire together; SALVO: barrels cycle on salvoDelay; SINGLE: one barrel per shot."
	barrel_mode_option.item_selected.connect(_on_barrel_mode_selected)
	fire_row.add_child(barrel_mode_option)
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
	health_box.custom_minimum_size = Vector2(215, 0)
	health_box.add_theme_constant_override("separation", 2)
	stats_row.add_child(health_box)
	health_label = Label.new()
	health_label.text = "Target hull: -"
	health_box.add_child(health_label)
	health_bar = ProgressBar.new()
	health_bar.max_value = 1000
	health_bar.value = 1000
	health_bar.show_percentage = false
	health_bar.custom_minimum_size = Vector2(0, 10)
	health_box.add_child(health_bar)
	shield_label = Label.new()
	shield_label.text = "Target shield: none"
	shield_label.add_theme_color_override("font_color", Color("#7cd8ff"))
	health_box.add_child(shield_label)
	shield_bar = ProgressBar.new()
	shield_bar.max_value = 100
	shield_bar.value = 0
	shield_bar.show_percentage = false
	shield_bar.custom_minimum_size = Vector2(0, 8)
	health_box.add_child(shield_bar)
	shooter_resource_label = Label.new()
	shooter_resource_label.text = "Shooter ammo: ∞  energy: ∞"
	shooter_resource_label.add_theme_color_override("font_color", Color("#F0D060"))
	health_box.add_child(shooter_resource_label)

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

	# Tab 2: Combat-State Timeline + Live Actor Inspector (HSplit preserves 5-tab workbench)
	var tl_tab := VBoxContainer.new()
	tl_tab.name = "Timeline"
	bottom_tabs.add_child(tl_tab)
	var tl_bar := HFlowContainer.new()
	tl_bar.add_theme_constant_override("h_separation", 6)
	tl_bar.add_theme_constant_override("v_separation", 2)
	tl_tab.add_child(tl_bar)
	tl_bar.add_child(_mk_label("Filter"))
	timeline_filter_option = OptionButton.new()
	for pair in [["All", "all"], ["Combat State", "combat"], ["FX", "fx"], ["Audio", "audio"]]:
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
	timeline_scrub_slider.custom_minimum_size = Vector2(130, 18)
	timeline_scrub_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	timeline_scrub_slider.tooltip_text = "Scrub timeline (Right-Click to reset to 0.0s)"
	timeline_scrub_slider.value_changed.connect(func(v: float): scrub_timeline_to(v))
	_bind_rmb_reset(timeline_scrub_slider, func(): timeline_scrub_slider.value = 0.0)
	tl_bar.add_child(timeline_scrub_slider)
	timeline_time_label = Label.new()
	timeline_time_label.text = "t=0.000 s (0 events)"
	timeline_time_label.add_theme_color_override("font_color", Color("#F0D060"))
	tl_bar.add_child(timeline_time_label)
	capture_replay_button = _mk_button("CAPTURE REPLAY")
	capture_replay_button.tooltip_text = "Save immutable CombatReplaySnapshot (actors, transforms, ODF revisions, shots)"
	capture_replay_button.pressed.connect(func(): capture_replay_snapshot())
	tl_bar.add_child(capture_replay_button)
	replay_snapshot_option = OptionButton.new()
	replay_snapshot_option.custom_minimum_size = Vector2(108, 0)
	replay_snapshot_option.tooltip_text = "Select captured replay snapshot to run in isolated sandbox"
	tl_bar.add_child(replay_snapshot_option)
	run_replay_button = _mk_button("REPLAY SANDBOX")
	run_replay_button.tooltip_text = "Deterministically replay selected snapshot without mutating current active scenario"
	run_replay_button.pressed.connect(func(): start_incremental_replay())
	tl_bar.add_child(run_replay_button)
	compare_replay_button = _mk_button("COMPARE A/B")
	compare_replay_button.tooltip_text = "Run isolated sandboxed replays of the last two captured snapshots and diff outcomes"
	compare_replay_button.pressed.connect(func(): start_bounded_ab_replay())
	tl_bar.add_child(compare_replay_button)
	add_dot_button = _mk_button("+ TEST DoT")
	add_dot_button.tooltip_text = "Apply APPROXIMATED burn DoT (25 dps for 4.0s) to primary target"
	add_dot_button.pressed.connect(func(): apply_test_dot())
	tl_bar.add_child(add_dot_button)
	audio_pool_label = Label.new()
	audio_pool_label.text = "Audio pool: 0/%d active (steals: 0)" % AUDIO_POOL_SIZE
	audio_pool_label.add_theme_color_override("font_color", Color("#9C9371"))
	tl_bar.add_child(audio_pool_label)
	var tl_split := HSplitContainer.new()
	tl_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tl_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tl_tab.add_child(tl_split)
	timeline_tree = Tree.new()
	timeline_tree.columns = 4
	timeline_tree.set_column_title(0, "Time (s)")
	timeline_tree.set_column_title(1, "Event")
	timeline_tree.set_column_title(2, "Detail")
	timeline_tree.set_column_title(3, "ODF / Key")
	timeline_tree.column_titles_visible = true
	timeline_tree.hide_root = true
	timeline_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	timeline_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline_tree.custom_minimum_size = Vector2(260, 0)
	timeline_tree.item_activated.connect(_on_timeline_item_activated)
	timeline_tree.item_selected.connect(_on_timeline_item_selected)
	tl_split.add_child(timeline_tree)
	actor_inspector_tree = Tree.new()
	actor_inspector_tree.columns = 7
	actor_inspector_tree.set_column_title(0, "Actor")
	actor_inspector_tree.set_column_title(1, "Hull")
	actor_inspector_tree.set_column_title(2, "Shield")
	actor_inspector_tree.set_column_title(3, "Ammo / Energy")
	actor_inspector_tree.set_column_title(4, "Armor / Wpn")
	actor_inspector_tree.set_column_title(5, "Reload / FX")
	actor_inspector_tree.set_column_title(6, "Pos / Vel")
	actor_inspector_tree.column_titles_visible = true
	actor_inspector_tree.hide_root = true
	actor_inspector_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	actor_inspector_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actor_inspector_tree.custom_minimum_size = Vector2(260, 0)
	tl_split.add_child(actor_inspector_tree)
	hardpoint_inspector_tree = Tree.new()
	var hp_columns := ["Hardpoint", "Owner / Role", "Weapon / Ordnance", "Firing Policy", "Fidelity", "Resolved Node3D", "Current Origin", "Shot ID", "Shot Origin (launch)", "Shot Rev", "Rev Status", "Ammo (now)", "Energy (now)", "Reload"]
	hardpoint_inspector_tree.item_activated.connect(_on_hardpoint_row_activated)
	hardpoint_inspector_tree.item_selected.connect(_on_hardpoint_row_selected)
	hardpoint_inspector_tree.columns = hp_columns.size()
	for i in hp_columns.size():
		hardpoint_inspector_tree.set_column_title(i, hp_columns[i])
	hardpoint_inspector_tree.column_titles_visible = true
	hardpoint_inspector_tree.hide_root = true
	hardpoint_inspector_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hardpoint_inspector_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hardpoint_inspector_tree.custom_minimum_size = Vector2(300, 0)
	hardpoint_inspector_tree.tooltip_text = "Physical hardpoint identity per declared slot: current model origin, the launch origin and Shot ID of the last volley fired by THIS weapon, and the shooter's current ammo/energy. A shot from another weapon is never relabelled here."
	tl_split.add_child(hardpoint_inspector_tree)

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
	sandbox_row.add_child(_mk_label("Anim"))
	anim_clip_option = OptionButton.new()
	anim_clip_option.custom_minimum_size = Vector2(106, 0)
	anim_clip_option.tooltip_text = "Embedded DOCB .msh animation clip on Shooter A (moves attached hardpoints live)"
	anim_clip_option.add_item("(static)")
	anim_clip_option.disabled = true
	anim_clip_option.item_selected.connect(func(idx: int):
		if idx >= 0 and idx < anim_clip_option.item_count:
			select_animation_clip(anim_clip_option.get_item_text(idx))
	)
	sandbox_row.add_child(anim_clip_option)
	anim_play_button = _mk_button("Anim Play")
	anim_play_button.tooltip_text = "Play or pause selected DOCB .msh animation clip on Shooter A"
	anim_play_button.pressed.connect(func(): set_animation_playing(not _anim_playing))
	sandbox_row.add_child(anim_play_button)
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
	native_row.add_child(_mk_label("Mode"))
	native_launch_mode_option = OptionButton.new()
	native_launch_mode_option.custom_minimum_size = Vector2(150, 0)
	native_launch_mode_option.add_item("Stock Addon (@mydocsdir)")
	native_launch_mode_option.set_item_metadata(0, "STOCK_ADDON")
	native_launch_mode_option.add_item("Custom /config (Stage)")
	native_launch_mode_option.set_item_metadata(1, "CUSTOM_CONFIG")
	native_launch_mode_option.tooltip_text = "STOCK_ADDON uses stock bzone.cfg @mydocsdir\\addon without modifying BZ2R; CUSTOM_CONFIG generates external shaman_native.cfg (operator @rootdir handoff)"
	native_row.add_child(native_launch_mode_option)
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
	native_arm_manual_button = _mk_button("ARM MANUAL OBSERVATION")
	native_arm_manual_button.tooltip_text = "Arm non-blocking monitoring (MONITOR_ARMED) before manual Steam launch; persists across restart"
	native_arm_manual_button.pressed.connect(func(): run_native_arm_manual_observation())
	native_row.add_child(native_arm_manual_button)
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
	native_cancel_button = _mk_button("CANCEL MONITOR")
	native_cancel_button.tooltip_text = "Stop automatic non-blocking polling for the active native session"
	native_cancel_button.pressed.connect(func(): run_native_cancel_monitor())
	native_row.add_child(native_cancel_button)
	native_resume_button = _mk_button("RESUME MONITOR")
	native_resume_button.tooltip_text = "Resume automatic non-blocking monitoring for a pending native session"
	native_resume_button.pressed.connect(func(): run_native_resume_monitor())
	native_row.add_child(native_resume_button)
	native_status_label = Label.new()
	native_status_label.text = "Native: idle (NATIVE_VERIFIED: 0)"
	native_status_label.add_theme_color_override("font_color", Color("#9C9371"))
	nat_tab.add_child(native_status_label)
	native_monitor_label = Label.new()
	native_monitor_label.text = "SESSION: - | STATE: IDLE | PID: 0 | MISSION: WAITING | PROBE: WAITING | OBS: NONE | ELAPSED: 0.0s / 30.0s"
	native_monitor_label.add_theme_color_override("font_color", Color("#F0D060"))
	nat_tab.add_child(native_monitor_label)

	# T-75: read-only native stage inventory. Never renames, overwrites or
	# deletes a stage; unresolved ownership stays visibly unresolved.
	var stage_heading := _mk_label("Native stage inventory (read-only)")
	stage_heading.add_theme_font_size_override("font_size", 14)
	nat_tab.add_child(stage_heading)
	var inspect_row := HFlowContainer.new()
	inspect_row.add_theme_constant_override("h_separation", 6)
	nat_tab.add_child(inspect_row)
	var inspect_button := _mk_button("INSPECT EXISTING STAGES")
	inspect_button.tooltip_text = "Read-only inventory: ownership, session state, hash status, unknown files and cleanup eligibility"
	inspect_button.pressed.connect(func(): inspect_native_stages())
	inspect_row.add_child(inspect_button)
	native_stage_inventory_label = _mk_label("No stage inventory requested.")
	native_stage_inventory_label.add_theme_color_override("font_color", Color("#D37676"))
	nat_tab.add_child(native_stage_inventory_label)


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
	projectile_traj_overlay = MeshInstance3D.new()
	projectile_traj_overlay.name = "ProjectileTrajOverlay"
	world.add_child(projectile_traj_overlay)
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


## T-222 / HP3D: click a marker, or select one by identity from code/tests.
## Shared mounts need an explicit owner; inspection-only nodes never become fire mounts.
func select_hardpoint_marker(marker_id: int, owner_slot: int = -2) -> bool:
	var selected_identity: Dictionary = {}
	for identity in _hardpoint_marker_data:
		if int((identity as Dictionary).get("marker_id", 0)) == marker_id:
			selected_identity = identity
			break
	if selected_identity.is_empty():
		return false
	var hp_name := str(selected_identity.get("hardpoint", ""))
	var owner_slots: Array = selected_identity.get("weapon_slots", [])
	if bool(selected_identity.get("ambiguous", false)) and owner_slot == -2:
		_select_marker_inspection(selected_identity)
		status_changed.emit("Shared hardpoint %s requires an explicit owner slot: %s" % [
			hp_name, str(owner_slots)], "warning")
		return false
	var selected_slot := owner_slot
	if selected_slot == -2:
		selected_slot = int(selected_identity.get("weapon_slot", -1))
	var slot_switch_attempted := selected_slot >= 0 and selected_slot != active_weapon_slot
	var switched := not slot_switch_attempted
	if slot_switch_attempted:
		var previous_selection := _fire_selection_hardpoint
		switched = switch_weapon_slot(selected_slot)
		if switched:
			_restore_fire_selection(previous_selection, selected_slot)
	if not switched:
		return false
	if not slot_switch_attempted:
		if select_hardpoint(hp_name, int(selected_identity.get("node_id", 0)), selected_slot):
			status_changed.emit("3D hardpoint selected: %s (slot %d)" % [hp_name, selected_slot], "muted")
			return true
	_select_marker_inspection(selected_identity)
	status_changed.emit("3D hardpoint selected for inspection: %s (unresolved node)" % hp_name, "warning")
	return hp_name != ""


func select_hardpoint_marker_owner(marker_id: int, owner_slot: int) -> bool:
	return select_hardpoint_marker(marker_id, owner_slot)


func _select_marker_inspection(identity: Dictionary) -> void:
	_selected_hardpoint_name = str(identity.get("hardpoint", "")).strip_edges().to_lower()
	_selected_hardpoint_node_id = int(identity.get("node_id", 0))
	var node := _find_hardpoint_node_by_id(int(identity.get("node_id", 0)))
	shooter_hardpoint_node = node if node != null else shooter_hardpoint_node
	if str(identity.get("marker_role", "")) == "GENERIC_MODEL_HARDPOINT":
		hardpoint_mode = "inspection:" + _selected_hardpoint_name
	elif _selected_hardpoint_name != "":
		hardpoint_mode = "declared:" + _selected_hardpoint_name
	_update_aim_overlay()
	refresh_hardpoint_inspector(true)


func _find_hardpoint_node_by_id(node_id: int) -> Node3D:
	var by_id = shooter_model_info.get("nodes_by_id", {})
	if by_id is Dictionary:
		var cached = (by_id as Dictionary).get(node_id, null)
		if cached is Node3D:
			return cached
	for identity in _hardpoint_marker_data:
		var d: Dictionary = identity
		if int(d.get("node_id", 0)) != node_id:
			continue
		var hps: Dictionary = shooter_model_info.get("hardpoints", {}) if bool(shooter_model_info.get("ok", false)) else {}
		var key := str(d.get("hardpoint", "")).to_lower()
		if hps.has(key) and hps[key] is Node3D:
			return hps[key]
	return null


func _selected_marker_identity() -> Dictionary:
	var selected := _selected_marker_identity_record()
	if not selected.is_empty():
		return selected
	var owners := _marker_owners(_selected_hardpoint_name)
	var selected_slot := active_weapon_slot if any_owner_is_active(owners) else -1
	var node := _find_hardpoint_node_by_id(_selected_hardpoint_node_id)
	return _marker_identity(_selected_hardpoint_name, node, selected_slot) if _selected_hardpoint_name != "" else {}


func _selected_marker_identity_record() -> Dictionary:
	for identity in _hardpoint_marker_data:
		var d: Dictionary = identity
		if str(d.get("hardpoint", "")).to_lower() == _selected_hardpoint_name and \
				int(d.get("node_id", 0)) == _selected_hardpoint_node_id:
			return d
	return {}


## Screen position for a marker. Uses the lab-local transform, which matches
## the packaged viewport and also works when a verifier builds the lab outside
## a viewport tree.
func _marker_world_position(marker: Node3D) -> Vector3:
	if marker == null:
		return Vector3.ZERO
	if marker.is_inside_tree() and camera != null and camera.is_inside_tree():
		return marker.global_transform.origin
	return _world_transform_in_lab(marker).origin


func _marker_screen_position(marker: Node3D) -> Vector2:
	if camera == null or viewport == null or marker == null:
		return Vector2(-1, -1)
	var world_pos := _marker_world_position(marker)
	if camera.is_inside_tree():
		if camera.is_position_behind(world_pos):
			return Vector2(-1, -1)
		return camera.unproject_position(world_pos)
	# Lab-local projection used by headless tests and by the packaged viewport
	# when the camera node has not entered the scene tree yet.
	var xf := _world_transform_in_lab(camera)
	var to_point := world_pos - xf.origin
	var forward := -xf.basis.z.normalized()
	var z := to_point.dot(forward)
	if z <= 0.0001:
		return Vector2(-1, -1)
	var x := to_point.dot(xf.basis.x.normalized())
	var y := to_point.dot(xf.basis.y.normalized())
	var rect := viewport.get_visible_rect()
	var fov_rad := deg_to_rad(camera.fov)
	var half_h := tan(fov_rad * 0.5) * z
	var half_w := half_h * maxf(0.1, rect.size.x / maxf(1.0, rect.size.y))
	return Vector2((x / maxf(0.0001, half_w) * 0.5 + 0.5) * rect.size.x,
		(0.5 - y / maxf(0.0001, half_h) * 0.5) * rect.size.y)


func _pick_hardpoint_at_screen(screen_pos: Vector2) -> bool:
	if camera == null or viewport == null:
		return false
	var from: Vector3
	var dir: Vector3
	if camera.is_inside_tree():
		from = camera.project_ray_origin(screen_pos)
		dir = camera.project_ray_normal(screen_pos)
	else:
		# Headless verifiers can project through the camera's lab-local pose.
		var xf := _world_transform_in_lab(camera)
		var origin := xf.origin
		var forward := -xf.basis.z.normalized()
		var right := xf.basis.x.normalized()
		var up := xf.basis.y.normalized()
		var rect := viewport.get_visible_rect()
		var sx := ((screen_pos.x / maxf(1.0, rect.size.x)) - 0.5) * 2.0
		var sy := (0.5 - (screen_pos.y / maxf(1.0, rect.size.y))) * 2.0
		var half_h := tan(deg_to_rad(camera.fov) * 0.5)
		var half_w := half_h * maxf(0.1, rect.size.x / maxf(1.0, rect.size.y))
		from = origin
		dir = (forward + right * sx * half_w + up * sy * half_h).normalized()
	var best_id := 0
	var best_dist := INF
	for identity in _hardpoint_marker_data:
		var marker_id := int((identity as Dictionary).get("marker_id", 0))
		var marker := _find_marker_by_id(hardpoint_markers_root, marker_id)
		if marker == null:
			continue
		var marker_pos: Vector3 = marker.position
		if marker.is_inside_tree():
			marker_pos = marker.global_transform.origin
		var to_marker := marker_pos - from
		var along := to_marker.dot(dir)
		if along <= 0.0:
			continue
		var perpendicular := (to_marker - dir * along).length()
		if perpendicular <= 0.35 and along < best_dist:
			best_dist = along
			best_id = marker_id
	return best_id != 0 and select_hardpoint_marker(best_id)


func _find_marker_by_id(node: Node, marker_id: int) -> MeshInstance3D:
	if node == null:
		return null
	if node is MeshInstance3D and int(node.get_instance_id()) == marker_id:
		return node as MeshInstance3D
	for c in node.get_children():
		var found := _find_marker_by_id(c, marker_id)
		if found != null:
			return found
	return null


func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and _pick_hardpoint_at_screen(mb.position):
				return
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
	combat_scenario.change_weapon(profile, true)
	_current_health = combat_scenario.primary_target().hull_current
	_current_shield = combat_scenario.primary_target().shield_current
	_update_stats()
	_update_health_display()
	refresh_actor_inspector(true)
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
	var ok := profile.resolve(index, shooter_path, target_path, "", true, active_weapon_slot, barrel_mode)
	combat_scenario.configure_from_profile(profile, target_node.position if target_node != null else Vector3(0, 0, -50), false)
	_current_health = combat_scenario.primary_target().hull_current if profile != null else 1000.0
	_current_shield = combat_scenario.primary_target().shield_current if profile != null else 0.0
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
	_populate_weapon_picker()
	if ok:
		status_changed.emit("Scenario: %s -> %s" % [profile.weapon_name, profile.ordnance_name], "success")
		scenario_loaded.emit(profile)
	else:
		status_changed.emit("Scenario incomplete: " + "; ".join(profile.errors), "danger")
		_append_telemetry(0.0, "ERROR", "Scenario incomplete; firing is disabled until the chain resolves.")


func _firing_source_profile() -> WeaponProfile:
	if profile == null:
		return null
	if last_volley_result != null and str(last_volley_result.firing_context) == "ALTERNATE" and \
			int(last_volley_result.weapon_slot) == active_weapon_slot and profile.alt != null:
		return profile.alt
	return profile


func _open_firing_source(ordnance: bool) -> void:
	var source_profile := _firing_source_profile()
	if source_profile == null:
		status_changed.emit("No weapon chain is loaded.", "warning")
		return
	var path := source_profile.ordnance_path if ordnance else source_profile.weapon_path
	if path == "":
		status_changed.emit("The selected firing chain has no resolved %s ODF." % ("Ordnance" if ordnance else "Weapon"), "warning")
		return
	inspect_path_requested.emit(path)


func _update_chain_buttons() -> void:
	var source_profile := _firing_source_profile()
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
	if source_profile != null:
		if chain_wpn_button != null:
			var w_gname := index.get_game_name(source_profile.weapon_path) if (index != null and source_profile.weapon_path != "") else ""
			var w_lbl := source_profile.weapon_name if source_profile.weapon_name != "" else "-"
			if w_gname != "" and w_gname.to_lower() != w_lbl.to_lower():
				w_lbl += " (" + w_gname + ")"
			chain_wpn_button.text = "-> Wpn: " + w_lbl
			chain_wpn_button.disabled = (source_profile.weapon_path == "")
		if chain_ord_button != null:
			chain_ord_button.text = "-> Ord: " + (source_profile.ordnance_name if source_profile.ordnance_name != "" else "-")
			chain_ord_button.disabled = (source_profile.ordnance_path == "")
		if chain_xpl_button != null:
			var xn := source_profile.xpl_vehicle if source_profile.xpl_vehicle != "" else source_profile.xpl_ground
			chain_xpl_button.text = "-> Xpl: " + (xn if xn != "" else "-")
			chain_xpl_button.disabled = (xn == "")
	if open_weapon_button != null:
		open_weapon_button.disabled = source_profile == null or source_profile.weapon_path == ""
	if open_ordnance_button != null:
		open_ordnance_button.disabled = source_profile == null or source_profile.ordnance_path == ""
	if show_timeline_shot_button != null:
		show_timeline_shot_button.disabled = last_volley_result == null or last_volley_result.shot_ids.is_empty()


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


func _rebuild_actor_models(preserve_hardpoint_nodes: Dictionary = {}, restore_hardpoint_ids: Dictionary = {}) -> void:
	shooter_model_info = {}
	target_model_info = {}
	shooter_hardpoint_node = null
	hardpoint_mode = "editor-defined"
	_selected_hardpoint_name = ""
	_selected_hardpoint_node_id = 0
	_clear_fire_selection()
	_last_firing_policy = {}
	_hardpoint_marker_data.clear()
	if shooter_node == null or target_node == null or profile == null:
		return
	_clear_node_children(shooter_node)
	if profile.shooter_geometry != "":
		var msh_path := BzMeshReaderScript.resolve_msh_for_geometry(index, profile.shooter_geometry, profile.shooter_path, profile.shooter_geometry_scale)
		if msh_path != "":
			var res := BzMeshReaderScript.build_scene(msh_path, index, "DOCB .msh (from %s)" % profile.shooter_geometry)
			if bool(res.get("ok", false)):
				if not (res.get("hardpoints", {}) is Dictionary):
					res["hardpoints"] = {}
				var built_hps: Dictionary = res.get("hardpoints", {})
				for key in preserve_hardpoint_nodes:
					if not built_hps.has(key):
						built_hps[key] = preserve_hardpoint_nodes[key]
				var previous_ids = restore_hardpoint_ids
				if previous_ids.is_empty():
					previous_ids = shooter_model_info.get("nodes_by_id", {})
				var node_ids: Dictionary = previous_ids.duplicate() if previous_ids is Dictionary else {}
				for hp_key in built_hps:
					node_ids[int((built_hps[hp_key] as Node3D).get_instance_id())] = built_hps[hp_key]
				var selected_node := _find_hardpoint_node_by_id(_selected_hardpoint_node_id)
				if selected_node == null:
					selected_node = _hardpoint_node_map().get(_selected_hardpoint_name, null)
				var selected_name := _selected_hardpoint_name
				shooter_model_info = res
				shooter_model_info["hardpoints"] = built_hps
				shooter_model_info["nodes_by_id"] = node_ids
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
				var wanted := profile.weapon_hardpoint.to_lower()
				if wanted != "" and built_hps.has(wanted):
					shooter_hardpoint_node = built_hps[wanted]
					hardpoint_mode = "mesh:" + wanted
				elif built_hps.has("hp_cannon_1"):
					shooter_hardpoint_node = built_hps["hp_cannon_1"]
					hardpoint_mode = "mesh:hp_cannon_1"
				if selected_node != null and selected_name != "":
					shooter_hardpoint_node = selected_node
					hardpoint_mode = "mesh:" + selected_name
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
	_populate_animation_picker()
	_sync_target_bbox_to_profile()
	_update_target_position()
	_rebuild_hud_tags()


func _populate_animation_picker() -> void:
	_anim_playing = false
	_anim_time_s = 0.0
	_anim_clip_name = ""
	if anim_play_button != null:
		anim_play_button.text = "Anim Play"
	if anim_clip_option == null:
		return
	anim_clip_option.clear()
	if bool(shooter_model_info.get("ok", false)):
		var names: Array = shooter_model_info.get("animation_names", [])
		if not names.is_empty():
			for nm in names:
				anim_clip_option.add_item(str(nm))
			anim_clip_option.select(0)
			anim_clip_option.disabled = false
			_anim_clip_name = str(names[0])
			return
	anim_clip_option.add_item("(static)")
	anim_clip_option.disabled = true


func select_animation_clip(clip_name: String) -> bool:
	if not bool(shooter_model_info.get("ok", false)):
		return false
	var anims: Dictionary = shooter_model_info.get("animations", {})
	if not anims.has(clip_name):
		return false
	_anim_clip_name = clip_name
	_anim_time_s = 0.0
	if anim_clip_option != null:
		for i in anim_clip_option.item_count:
			if anim_clip_option.get_item_text(i) == clip_name:
				anim_clip_option.select(i)
				break
	var res := BzMeshReaderScript.apply_animation_pose(shooter_model_info, clip_name, 0.0, true)
	_update_aim_overlay()
	return bool(res.get("ok", false))


func set_animation_playing(playing: bool) -> void:
	if playing and (_anim_clip_name == "" or not bool(shooter_model_info.get("ok", false))):
		_anim_playing = false
	else:
		_anim_playing = playing
	if anim_play_button != null:
		anim_play_button.text = "Anim Stop" if _anim_playing else "Anim Play"


func step_model_animation(dt: float) -> Dictionary:
	if not bool(shooter_model_info.get("ok", false)) or _anim_clip_name == "":
		return {"ok": false}
	_anim_time_s += maxf(0.0, dt)
	var res := BzMeshReaderScript.apply_animation_pose(shooter_model_info, _anim_clip_name, _anim_time_s, true)
	if bool(res.get("ok", false)):
		_update_aim_overlay()
	return res


## Live per-projectile trajectory + estimated time-to-impact telemetry for active shots.
func active_projectile_telemetry() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tgt_pos := target_node.position if target_node != null else Vector3(0, 2, -50)
	for p in projectiles:
		var s = p.get("shot", null)
		if s == null or not bool(s.alive):
			continue
		var dist: float = (s.position as Vector3).distance_to(tgt_pos)
		var spd: float = maxf(0.01, (s.velocity as Vector3).length())
		var eta := dist / spd
		out.append({
			"shot_id": int(s.shot_id),
			"position": s.position,
			"velocity": s.velocity,
			"age": float(s.age),
			"distance_to_target": dist,
			"eta_s": eta,
			"predicted_point": (s.position as Vector3) + (s.velocity as Vector3) * minf(eta, maxf(0.0, float(s.life_span) - float(s.age))),
		})
	return out


func _update_projectile_trajectories() -> void:
	if projectile_traj_overlay == null:
		return
	var rows := active_projectile_telemetry()
	if rows.is_empty() or not overlays_enabled:
		projectile_traj_overlay.mesh = null
		return
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for r in rows:
		var p0: Vector3 = r.get("position", Vector3.ZERO)
		var p1: Vector3 = r.get("predicted_point", p0)
		im.surface_set_color(Color("#f0d060"))
		im.surface_add_vertex(p0)
		im.surface_set_color(Color("#ff7b3b"))
		im.surface_add_vertex(p1)
	im.surface_end()
	projectile_traj_overlay.mesh = im
	projectile_traj_overlay.material_override = mat


## Compare two captured replay snapshots side-by-side in isolated sandboxes (Wave E).
func compare_replay_snapshots(snap_a_id: String, snap_b_id: String) -> Dictionary:
	if combat_scenario == null:
		return {"ok": false, "summary": "no combat scenario"}
	var snap_a: Dictionary = {}
	var snap_b: Dictionary = {}
	for s in combat_scenario.saved_replay_snapshots:
		var sid := str((s as Dictionary).get("snapshot_id", ""))
		if sid == snap_a_id:
			snap_a = s
		if sid == snap_b_id:
			snap_b = s
	if snap_a.is_empty() or snap_b.is_empty():
		return {"ok": false, "summary": "capture at least two replay snapshots first"}
	var ra: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap_a)
	var rb: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap_b)
	last_replay_comparison = CombatScenarioScript.compare_replay_results(ra, rb)
	last_replay_comparison["snapshot_a"] = snap_a_id
	last_replay_comparison["snapshot_b"] = snap_b_id
	_append_telemetry(sim.sim_time, "REPLAY_AB", str(last_replay_comparison.get("summary", "")))
	status_changed.emit(str(last_replay_comparison.get("summary", "")), "success")
	return last_replay_comparison


func compare_last_two_replays() -> Dictionary:
	if combat_scenario == null or (combat_scenario.saved_replay_snapshots as Array).size() < 2:
		status_changed.emit("Compare A/B: capture at least two replay snapshots first.", "warning")
		return {"ok": false}
	var snaps: Array = combat_scenario.saved_replay_snapshots
	var id_a := str((snaps[snaps.size() - 2] as Dictionary).get("snapshot_id", ""))
	var id_b := str((snaps[snaps.size() - 1] as Dictionary).get("snapshot_id", ""))
	return compare_replay_snapshots(id_a, id_b)


## T-76: fill the weapon-slot picker from the profile's resolved weaponNameN
## slots and keep it in sync with the active slot.
func _populate_weapon_picker() -> void:
	if weapon_option == null:
		return
	weapon_option.clear()
	if profile != null and not profile.weapon_slots.is_empty():
		for resolved_index in profile.weapon_slots.size():
			var slot: Dictionary = profile.weapon_slots[resolved_index]
			var wname := str(slot.get("weapon", ""))
			var snum := str(slot.get("slot", ""))
			weapon_option.add_item("W%s: %s" % [snum, wname])
			weapon_option.set_item_metadata(weapon_option.item_count - 1, int(slot.get("resolved_index", resolved_index)))
		var sel := clampi(active_weapon_slot, 0, weapon_option.item_count - 1)
		weapon_option.select(sel)
		weapon_option.disabled = false
	else:
		weapon_option.add_item("(no weapon slots)")
		weapon_option.disabled = true
	if barrel_mode_option != null:
		for i in barrel_mode_option.item_count:
			if str(barrel_mode_option.get_item_metadata(i)) == barrel_mode:
				barrel_mode_option.select(i)
				break


func _on_weapon_slot_selected(idx: int) -> void:
	if weapon_option == null or idx < 0 or idx >= weapon_option.item_count:
		return
	switch_weapon_slot(int(weapon_option.get_item_metadata(idx)))


func _on_barrel_mode_selected(idx: int) -> void:
	if barrel_mode_option == null or idx < 0 or idx >= barrel_mode_option.item_count:
		return
	barrel_mode = str(barrel_mode_option.get_item_metadata(idx))
	if profile != null:
		profile.barrel_mode = barrel_mode
	status_changed.emit("Barrel mode: %s" % barrel_mode, "muted")


## Switch the active vehicle weapon slot without resetting the scenario clock.
func switch_weapon_slot(slot_index: int) -> bool:
	if shooter_path == "" or target_path == "":
		return false
	var node_map_before := _hardpoint_node_map()
	var selected_node_before := _find_hardpoint_node_by_id(_selected_hardpoint_node_id)
	var selected_name_before := _selected_hardpoint_name
	var model_was_rebuilt := bool(shooter_model_info.get("ok", false)) and profile != null and profile.shooter_geometry == ""
	var node_ids_before := {}
	for key in node_map_before:
		node_ids_before[int((node_map_before[key] as Node3D).get_instance_id())] = node_map_before[key]
	var candidate := WeaponProfile.new()
	if profile != null and profile.shooter_geometry != "":
		candidate.shooter_geometry = profile.shooter_geometry
		candidate.shooter_geometry_scale = profile.shooter_geometry_scale
		candidate.target_geometry = profile.target_geometry
		candidate.target_geometry_scale = profile.target_geometry_scale
	if not candidate.resolve(index, shooter_path, target_path, "", true, slot_index, barrel_mode):
		status_changed.emit("Weapon slot %d could not be resolved: %s" % [
			slot_index + 1, "; ".join(candidate.errors)], "warning")
		return false
	var requested_slot := slot_index
	var resolved_slot := -1
	for slot_dict in candidate.weapon_slots:
		if int((slot_dict as Dictionary).get("resolved_index", -1)) == requested_slot:
			resolved_slot = requested_slot
			break
	if resolved_slot < 0 and requested_slot >= 0 and requested_slot < candidate.weapon_slots.size():
		resolved_slot = requested_slot
		active_weapon_slot = requested_slot
		candidate.resolve(index, shooter_path, target_path, "", true, requested_slot, barrel_mode)
	if resolved_slot < 0:
		status_changed.emit("Weapon slot %d is not a resolved physical slot." % (slot_index + 1), "warning")
		return false
	active_weapon_slot = resolved_slot
	candidate.active_slot_index = resolved_slot
	profile = candidate
	if combat_scenario.shooter != null:
		combat_scenario.change_weapon(profile, true)
	# In-flight shots keep their launch-time identity and visual nodes.
	_rebuild_actor_models(node_map_before, node_ids_before)
	if model_was_rebuilt:
		shooter_model_info["hardpoints"] = node_map_before
		shooter_model_info["nodes_by_id"] = node_ids_before
		if selected_node_before != null and selected_name_before != "":
			shooter_hardpoint_node = selected_node_before
			hardpoint_mode = "mesh:" + selected_name_before
		_selected_hardpoint_name = selected_name_before
		_selected_hardpoint_node_id = int(selected_node_before.get_instance_id()) if selected_node_before != null else 0
		_update_aim_overlay()
	_revalidate_fire_selection()
	_populate_weapon_picker()
	_populate_hardpoint_picker()
	_update_chain_buttons()
	status_changed.emit("Weapon slot: %s (%s) — %d barrel(s), %s" % [
		profile.weapon_name, profile.ordnance_name, profile.weapon_hardpoints.size(), barrel_mode
	], "success")
	scenario_loaded.emit(profile)
	return true


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
	var selected_name := str(hardpoint_option.get_item_text(idx))
	var owners := _marker_owners(selected_name)
	var selected_owner := active_weapon_slot if any_owner_is_active(owners) else -1
	if owners.size() > 1 and selected_owner < 0:
		status_changed.emit("Shared hardpoint %s requires an explicit owning weapon slot." % selected_name, "warning")
		refresh_hardpoint_inspector(true)
		return
	select_hardpoint(selected_name, 0, selected_owner)


func any_owner_is_active(owners: Array[Dictionary]) -> bool:
	for owner in owners:
		if int((owner as Dictionary).get("resolved_index", -1)) == active_weapon_slot:
			return true
	return false


func _hardpoint_node_map() -> Dictionary:
	var hps: Dictionary = {}
	var model_hps: Dictionary = shooter_model_info.get("hardpoints", {}) if bool(shooter_model_info.get("ok", false)) else {}
	var by_id = shooter_model_info.get("nodes_by_id", {})
	if not (by_id is Dictionary) and not model_hps.is_empty():
		by_id = {}
		for hp_key in model_hps:
			var model_node = model_hps[hp_key]
			if model_node is Node3D:
				(by_id as Dictionary)[int((model_node as Node3D).get_instance_id())] = model_node
		shooter_model_info["nodes_by_id"] = by_id
	for key in model_hps:
		var node: Node3D = model_hps[key]
		if node != null:
			hps[str(key).to_lower()] = node
	if hps.is_empty() and not _hardpoint_marker_data.is_empty():
		for identity in _hardpoint_marker_data:
			var d: Dictionary = identity
			var node_id := int(d.get("node_id", 0))
			var cached = (by_id as Dictionary).get(node_id, null) if by_id is Dictionary else null
			var key := str(d.get("hardpoint", "")).to_lower()
			if cached is Node3D and key != "":
				hps[key] = cached
	if not hps.is_empty():
		return hps
	for marker in hardpoint_markers_root.get_children() if hardpoint_markers_root != null else []:
		if marker is Node3D and marker.has_meta("hardpoint_identity"):
			var identity: Dictionary = marker.get_meta("hardpoint_identity")
			var key := str(identity.get("hardpoint", "")).to_lower()
			if key != "" and not hps.has(key):
				var node := _find_hardpoint_node_by_id(int(identity.get("node_id", 0)))
				if node != null:
					hps[key] = node
	if hps.is_empty() and not _hardpoint_marker_data.is_empty():
		for identity in _hardpoint_marker_data:
			var key := str((identity as Dictionary).get("hardpoint", "")).to_lower()
			var node := _find_hardpoint_node_by_id(int((identity as Dictionary).get("node_id", 0)))
			if key != "" and node != null:
				hps[key] = node
	return hps


func select_hardpoint(hp_name: String, node_id: int = 0, preferred_owner_slot: int = -2) -> bool:
	var hps := _hardpoint_node_map()
	var key := hp_name.strip_edges().to_lower()
	if not hps.has(key):
		return false
	var node: Node3D = hps[key]
	if node_id > 0 and int(node.get_instance_id()) != node_id:
		return false
	var identity := _marker_identity(key, node, preferred_owner_slot)
	shooter_hardpoint_node = node
	hardpoint_mode = "mesh:" + key
	_selected_hardpoint_name = key
	_selected_hardpoint_node_id = int(node.get_instance_id())
	if str(identity.get("firing_eligibility", "")) != "INSPECTION_ONLY":
		_set_fire_selection(key, int(identity.get("weapon_slot", -1)),
			str(identity.get("weapon_revision", "")))
	else:
		hardpoint_mode = "inspection:" + key
	if hardpoint_option != null:
		for i in hardpoint_option.item_count:
			if hardpoint_option.get_item_text(i).to_lower() == key:
				hardpoint_option.select(i)
				break
	_update_aim_overlay()
	refresh_hardpoint_inspector(true)
	status_changed.emit("Active hardpoint: " + hardpoint_mode, "muted")
	return true


func _restore_fire_selection(hardpoint: String, weapon_slot: int) -> void:
	if hardpoint == "":
		return
	for owner in _marker_owners(hardpoint):
		if int((owner as Dictionary).get("resolved_index", -1)) == weapon_slot:
			var revision := _weapon_revision()
			_set_fire_selection(hardpoint, weapon_slot, revision)
			return


func _clear_fire_selection() -> void:
	_fire_selection_hardpoint = ""
	_fire_selection_weapon_slot = -1
	_fire_selection_weapon_revision = ""


func _weapon_revision() -> String:
	if profile == null:
		return ""
	var revisions: Dictionary = profile.snapshot_params().get("odf_revisions", {})
	var weapon: Dictionary = revisions.get("weapon", {})
	return "%s:%s:%s" % [str(weapon.get("path", profile.weapon_path)),
		str(weapon.get("md5", "")), str(weapon.get("dirty", false))]


func _set_fire_selection(hardpoint: String, weapon_slot: int, revision: String) -> void:
	_fire_selection_hardpoint = hardpoint.strip_edges().to_lower()
	_fire_selection_weapon_slot = weapon_slot
	_fire_selection_weapon_revision = revision


func _validate_fire_selection() -> void:
	if _fire_selection_hardpoint == "":
		return
	var current_revision := _weapon_revision()
	var owners := _marker_owners(_fire_selection_hardpoint)
	var slot_matches := false
	for owner in owners:
		if int((owner as Dictionary).get("resolved_index", -1)) == _fire_selection_weapon_slot:
			slot_matches = true
			break
	var hps: Dictionary = shooter_model_info.get("hardpoints", {}) if bool(shooter_model_info.get("ok", false)) else {}
	var hardpoint_valid := hps.has(_fire_selection_hardpoint)
	if not slot_matches or _fire_selection_weapon_slot != active_weapon_slot or \
			_fire_selection_weapon_revision != current_revision or not hardpoint_valid:
		_clear_fire_selection()
		status_changed.emit("SINGLE selection invalidated; automatic first declared barrel policy is active.", "warning")


func _revalidate_fire_selection() -> void:
	_validate_fire_selection()


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


## T-223 / HP3D-11..18: marker ownership comes from authoritative physical
## weapon slot declarations, not the currently active slot. A shared hardpoint
## keeps all owners explicit instead of silently picking one.
func _effective_weapon_slots() -> Array:
	if profile == null:
		return []
	var stored: Array = profile.snapshot_params().get("weapon_slots", [])
	if stored is Array and not (stored as Array).is_empty():
		return stored
	return profile.weapon_slots


func _marker_owners(hp_name: String) -> Array[Dictionary]:
	var owners: Array[Dictionary] = []
	if profile == null:
		return owners
	var key := hp_name.strip_edges().to_lower()
	for slot in _effective_weapon_slots():
		var sd: Dictionary = slot
		var hps: Array = sd.get("hardpoints", []) if sd.get("hardpoints", []) is Array else []
		var slot_hp := str(sd.get("hardpoint", ""))
		if slot_hp.to_lower() == key:
			owners.append(sd)
			continue
		for hp in hps:
			if str(hp).to_lower() == key:
				owners.append(sd)
				break
	return owners


func _marker_role(owners: Array[Dictionary]) -> String:
	if owners.is_empty():
		return "GENERIC_MODEL_HARDPOINT"
	if owners.size() > 1:
		return "SHARED_WEAPON_MOUNT"
	return "WEAPON_MUZZLE"


func _marker_identity_for_slot(hp_name: String, node_id: int, owner_slot: int) -> Dictionary:
	var node := _find_hardpoint_node_by_id(node_id)
	return _marker_identity(hp_name, node, owner_slot)


func _marker_identity(hp_name: String, node: Node3D, preferred_owner_slot: int = -2) -> Dictionary:
	var prov: Dictionary = (shooter_model_info.get("provenance", {}) as Dictionary) if \
		bool(shooter_model_info.get("ok", false)) else {}
	var owners := _marker_owners(hp_name)
	var role := _marker_role(owners)
	var owner_slots: Array[int] = []
	for owner in owners:
		owner_slots.append(int((owner as Dictionary).get("resolved_index", -1)))
	var primary: Dictionary = {}
	var owner_slot := -1
	if not owners.is_empty():
		if preferred_owner_slot != -2:
			for owner in owners:
				if int((owner as Dictionary).get("resolved_index", -1)) == preferred_owner_slot:
					primary = owner
					break
		if primary.is_empty():
			for owner in owners:
				if int((owner as Dictionary).get("resolved_index", -1)) == active_weapon_slot:
					primary = owner
					break
		if primary.is_empty() and owners.size() == 1:
			primary = owners[0]
		owner_slot = int(primary.get("resolved_index", -1)) if not primary.is_empty() else -1
	var ordnance_status := str(primary.get("ordnance_status", "ORDNANCE_UNRESOLVED")) if not primary.is_empty() else ("OWNER_SELECTION_REQUIRED" if not owners.is_empty() else "NOT_APPLICABLE")
	var firing_eligibility := "INSPECTION_ONLY" if owners.is_empty() else "WEAPON_MOUNT"
	var source_revision: Dictionary = primary.get("source_revision", {}) if not primary.is_empty() else {}
	var shooter_rev: Dictionary = prov.get("source_revision", {})
	if shooter_rev.is_empty() and profile != null:
		shooter_rev = profile.snapshot_params().get("odf_revisions", {}).get("shooter", {})
	return {
		"hardpoint": hp_name,
		"node_id": node.get_instance_id() if node != null else 0,
		"node_name": node.name if node != null else "",
		"vehicle_source": str(shooter_model_info.get("msh_path", "")) if \
			bool(shooter_model_info.get("ok", false)) else str(prov.get("msh_path", "")),
		"vehicle_source_revision": shooter_rev.duplicate(true),
		"weapon_slot": owner_slot,
		"weapon_slots": owner_slots,
		"weapon_slot_label": str(primary.get("slot", "")) if not primary.is_empty() else "",
		"ambiguous": owners.size() > 1,
		"marker_role": role,
		"firing_eligibility": firing_eligibility,
		"weapon_path": str(primary.get("path", "")) if not primary.is_empty() else "",
		"ordnance_path": str(primary.get("ordnance_path", "")) if not primary.is_empty() else "",
		"ordnance_status": ordnance_status,
		"weapon_revision": "%s:%s:%s" % [str(source_revision.get("weapon", {}).get("path", "")),
			str(source_revision.get("weapon", {}).get("md5", "")),
			str(source_revision.get("weapon", {}).get("dirty", false))],
		"source_revision": source_revision.duplicate(true),
		"owners": owners.duplicate(true),
		"fallback": node == null,
	}


func _update_aim_overlay() -> void:
	if aim_overlay == null or hardpoint_markers_root == null:
		return
	_clear_node_children(hardpoint_markers_root)
	_hardpoint_marker_data.clear()
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
			var identity := _marker_identity(str(hp_name), hp_node)
			identity["marker_id"] = marker.get_instance_id()
			identity["transform"] = [xf.origin.x, xf.origin.y, xf.origin.z]
			_hardpoint_marker_data.append(identity)
			marker.set_meta("hardpoint_identity", identity)
			hardpoint_markers_root.add_child(marker)
	var marker_count := hardpoint_markers_root.get_child_count()

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
	# The impact marker is transient overlay geometry, not a hardpoint marker.
	while hardpoint_markers_root.get_child_count() > marker_count:
		var extra := hardpoint_markers_root.get_child(hardpoint_markers_root.get_child_count() - 1)
		hardpoint_markers_root.remove_child(extra)
		extra.queue_free()
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


func _shot_geometry(hp_override: Node3D = null) -> Dictionary:
	var hp: Node3D = hp_override if is_instance_valid(hp_override) else shooter_hardpoint_node
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
	if hp != null:
		var xf_o := _world_transform_in_lab(hp)
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
	elif hp != null:
		var xf := _world_transform_in_lab(hp)
		origin = xf.origin
		dir = (-xf.basis.z).normalized()
		var flags := _is_under_turret(hp)
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
	var prim = combat_scenario.primary_target()
	var hp_max := float(prim.hull_max) if prim != null else maxf(1.0, profile.target_health_max)
	if prim != null:
		_current_health = float(prim.hull_current)
		_current_shield = float(prim.shield_current)
	health_bar.max_value = maxf(1.0, hp_max)
	if _current_health < 0.0:
		_current_health = hp_max
	health_bar.value = _current_health
	var destroyed_tag := " [DESTROYED]" if (prim != null and bool(prim.destroyed)) else ""
	health_label.text = "Target hull: %.0f / %.0f  (armor %s)%s" % [_current_health, hp_max, profile.target_armor, destroyed_tag]
	if shield_bar != null and shield_label != null:
		var sh_max := float(prim.shield_max) if prim != null else profile.target_shield_max
		var sh_cur := float(prim.shield_current) if prim != null else _current_shield
		var sh_cls := str(prim.shield_class) if prim != null else profile.target_shield_class
		shield_bar.max_value = maxf(1.0, sh_max)
		shield_bar.value = sh_cur if sh_max > 0.0 else 0.0
		if sh_max > 0.0:
			shield_label.text = "Target shield: %.0f / %.0f  (class %s)" % [sh_cur, sh_max, sh_cls if sh_cls != "" else "N"]
		else:
			shield_label.text = "Target shield: none"
	if shooter_resource_label != null and combat_scenario.shooter != null:
		var sh = combat_scenario.shooter
		var ammo_s := "∞" if bool(sh.ammo_unlimited) else "%d/%d" % [int(sh.ammo_current), int(sh.ammo_max)]
		var energy_s := "∞" if bool(sh.energy_unlimited) else "%.0f/%.0f" % [float(sh.energy_current), float(sh.energy_max)]
		var rld_s := "READY" if float(sh.reload_remaining) <= 0.0001 else ("RELOAD %.2fs" % float(sh.reload_remaining))
		shooter_resource_label.text = "Shooter ammo: %s  energy: %s  [%s]" % [ammo_s, energy_s, rld_s]
	refresh_actor_inspector(false)
	var frac: float = _current_health / maxf(1.0, hp_max)
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
	_fire_volley(false, "SINGLE", true)
	_running = true


## T-76: fire one volley according to the barrel policy. TANDEM fires every
## weaponHardN barrel from its own hardpoint in the same frame; SALVO cycles one
## barrel per shot; SINGLE fires exactly one barrel. Returns the first result.
func _fire_volley(use_alt: bool, fire_mode: String, enforce_reload: bool) -> Dictionary:
	# One record per declared slot: missing hardpoints keep their position and
	# identity instead of shifting later Node3D references into earlier barrels.
	var hps: Dictionary = shooter_model_info.get("hardpoints", {}) if bool(shooter_model_info.get("ok", false)) else {}
	var resolved: Array[Dictionary] = []
	var seen_names: Dictionary = {}
	if profile != null:
		for hp in profile.weapon_hardpoints:
			var nm := str(hp)
			if nm == "" or seen_names.has(nm.to_lower()):
				continue
			seen_names[nm.to_lower()] = true
			var node: Node3D = hps.get(nm.to_lower(), null) if hps.has(nm.to_lower()) else null
			var status := "VALID_RESOLVED_HARDPOINT" if node != null else "DECLARED_HARDPOINT_NOT_FOUND"
			resolved.append({
				"physical_slot": resolved.size(), "hardpoint_name": nm,
				"node3d": node, "source_identity": "declared",
				"available": node != null, "fallback_used": node == null,
				"diagnostic": status,
			})
	var hp_names: Array[String] = []
	if profile != null:
		for hp in profile.weapon_hardpoints:
			var hp_name_text := str(hp)
			if hp_name_text != "":
				hp_names.append(hp_name_text)
	var fallback_origin := hp_names.is_empty()
	var no_declared := fallback_origin
	if fallback_origin:
		hp_names.append("")
	if no_declared:
		resolved.append({
			"physical_slot": 0, "hardpoint_name": "",
			"node3d": shooter_hardpoint_node, "source_identity": "editor-defined",
			"available": false, "fallback_used": true,
			"diagnostic": "NO_DECLARED_HARDPOINTS",
		})
	var mode := barrel_mode.strip_edges().to_upper()
	if mode not in ["TANDEM", "SALVO", "SINGLE"]:
		mode = "TANDEM"
	_volley_counter += 1
	var volley := VolleyResult.new()
	volley.volley_id = _volley_counter
	# T-214 / PHI-07..13: a volley belongs to the weapon that actually fired it.
	# The alt chain is a different weapon and must not inherit the primary name.
	var fire_profile = profile
	if use_alt and profile != null and profile.alt != null:
		fire_profile = profile.alt
	volley.weapon_identity = str(fire_profile.weapon_name) if fire_profile != null else ""
	volley.weapon_path = str(fire_profile.weapon_path) if fire_profile != null else ""
	volley.weapon_slot = active_weapon_slot
	volley.firing_context = "ALTERNATE" if use_alt else "PRIMARY"
	volley.barrel_mode = mode
	volley.resolved_barrels = resolved.duplicate(true)
	for i in range(volley.resolved_barrels.size()):
		var pending: Dictionary = volley.resolved_barrels[i]
		pending["fired"] = false
		pending["state"] = "NOT_FIRED"
		pending["accepted"] = false
		volley.resolved_barrels[i] = pending
	var first_result: Dictionary = {}
	var volley_enforce = false # documented TANDEM contract: extra barrels bypass reload
	# SALVO/SINGLE cycle over resolved records; TANDEM fires every resolved
	# record in declared order. Barrel index is never a compacted array offset.
	var order: Array[int] = []
	if mode == "TANDEM":
		for i in range(resolved.size()):
			order.append(i)
		_last_firing_policy = {"mode": mode, "selection": "ALL_DECLARED_IN_ORDER",
			"weapon_slot": active_weapon_slot, "weapon_revision": _weapon_revision(), "hardpoint": ""}
	elif mode == "SALVO":
		order.append(_barrel_cycle % resolved.size())
		_barrel_cycle = (_barrel_cycle + 1) % resolved.size()
		_last_firing_policy = {"mode": mode, "selection": "ROUND_ROBIN_DECLARED",
			"weapon_slot": active_weapon_slot, "weapon_revision": _weapon_revision(),
			"hardpoint": str((resolved[order[0]] as Dictionary).get("hardpoint_name", ""))}
	else:
		_validate_fire_selection()
		var single_idx := 0
		var single_policy := "AUTOMATIC_FIRST_DECLARED"
		if _fire_selection_hardpoint != "":
			var selected_idx := -1
			for i in range(resolved.size()):
				if str((resolved[i] as Dictionary).get("hardpoint_name", "")).to_lower() == \
						_fire_selection_hardpoint.to_lower():
					selected_idx = i
					break
			if selected_idx >= 0:
				single_idx = selected_idx
				single_policy = "EXPLICIT_SLOT_%d_HARDPOINT" % active_weapon_slot
			else:
				_clear_fire_selection()
				single_policy = "AUTOMATIC_FIRST_DECLARED_SELECTION_RESET"
		_last_firing_policy = {
			"mode": mode,
			"selection": single_policy,
			"weapon_slot": active_weapon_slot,
			"weapon_revision": _weapon_revision(),
			"hardpoint": str((resolved[single_idx] as Dictionary).get("hardpoint_name", "")),
		}
		order.append(single_idx)
	volley.firing_policy = _last_firing_policy.duplicate(true)
	for barrel_index in order:
		var rec: Dictionary = resolved[barrel_index]
		var hp_name := str(rec.get("hardpoint_name", ""))
		var hp_for_shot: Node3D = rec.get("node3d", null)
		if hp_for_shot == null:
			hp_for_shot = shooter_hardpoint_node
		volley.requested_barrels.append(hp_name)
		var enforce := enforce_reload if volley.accepted_barrels.is_empty() else false
		var r := _fire_one(use_alt, fire_mode, enforce, hp_for_shot, hp_name, barrel_index, mode, volley.volley_id)
		if first_result.is_empty():
			first_result = r
		var shot = r.get("shot", null)
		var shot_identity: Dictionary = {}
		if shot != null and shot.identity != null:
			shot_identity = shot.identity.to_dict()
		var per_barrel := {
			"physical_slot": barrel_index, "weapon_slot": volley.weapon_slot,
			"firing_context": volley.firing_context, "hardpoint_name": hp_name,
			"diagnostic": str(rec.get("diagnostic", "")),
			"fallback_used": bool(rec.get("fallback_used", false)),
			"state": "FIRED" if bool(r.get("ok", false)) else str(r.get("state", "REJECTED")),
			"reason": str(r.get("reason", "")),
			"accepted": bool(r.get("ok", false)),
			"shot_identity": shot_identity,
			"weapon_name": str(shot_identity.get("weapon_name", volley.weapon_identity)),
			"weapon_path": str(shot_identity.get("weapon_path", volley.weapon_path)),
			"volley_id": volley.volley_id,
		}
		# PHI-22..27: the launch origin is captured at fire time. It must never be
		# reconstructed later from the animated hardpoint transform.
		if shot != null:
			var launch: Vector3 = shot.origin
			per_barrel["launch_origin"] = [launch.x, launch.y, launch.z]
			per_barrel["launch_origin_available"] = true
		else:
			per_barrel["launch_origin_available"] = false
		volley.resolved_barrels[barrel_index] = per_barrel
		if bool(r.get("ok", false)):
			volley.accepted_barrels.append(hp_name)
			if shot != null:
				volley.shot_ids.append(int(shot.shot_id))
			volley.ammo_spent += int(r.get("ammo_spent", 0))
			volley.energy_spent += float(r.get("energy_spent", 0.0))
			volley.reload_remaining = maxf(volley.reload_remaining, float(r.get("reload_remaining", 0.0)))
		else:
			volley.rejected_barrels.append(hp_name)
			volley.failure_reasons.append(str(r.get("reason", "FIRE_REJECTED")))
	volley.partial_failure = not volley.rejected_barrels.is_empty() and not volley.accepted_barrels.is_empty()
	volley.ok = not volley.accepted_barrels.is_empty()
	volley.complete = volley.rejected_barrels.is_empty()
	last_volley_result = volley
	refresh_hardpoint_inspector(true)
	if volley.partial_failure:
		status_changed.emit("Volley %d partial failure: %d/%d barrels accepted" % [
			volley.volley_id, volley.accepted_barrels.size(), volley.requested_barrels.size()
		], "warning")
	var aggregate := volley.to_dict()
	aggregate["fallback_origin"] = fallback_origin
	aggregate["failure_reasons"] = volley.failure_reasons.duplicate()
	return aggregate


func fire_alt() -> void:
	if profile == null:
		status_changed.emit("No scenario loaded.", "warning")
		return
	if profile.alt == null:
		status_changed.emit("This weapon chain declares no resolvable altName.", "warning")
		return
	# Alternate weapon (altName) uses an independent weapon mode mount; barrel
	# policy still applies when the mount has several barrels.
	_fire_volley(true, "SINGLE", false)
	_running = true


func start_burst() -> void:
	if profile == null or not profile.errors.is_empty():
		return
	_burst_left = max(1, profile.salvo_count)
	_burst_is_first_shot = true
	_burst_timer = 0.0
	_running = true
	status_changed.emit("Burst: %d shot(s)" % _burst_left, "muted")


func stop_fire() -> void:
	_continuous = false
	_burst_left = 0
	_burst_is_first_shot = true
	hold_button.set_pressed_no_signal(false)


func _on_pause_toggled(on: bool) -> void:
	_paused = on
	pause_button.text = "RESUME" if on else "PAUSE"


func _on_hold_toggled(on: bool) -> void:
	_continuous = on
	if on:
		_running = true
		_fire_cooldown = 0.0


func step_simulation_once(dt: float = 1.0 / 60.0) -> Array[Dictionary]:
	_paused = true
	if pause_button != null:
		pause_button.set_pressed_no_signal(true)
		pause_button.text = "RESUME"
	var tick_evs: Array[Dictionary] = combat_scenario.advance(dt)
	_sync_projectiles()
	_refresh_telemetry()
	_update_health_display()
	refresh_actor_inspector(true)
	return tick_evs


func _step_once() -> void:
	step_simulation_once(1.0 / 60.0)


func restart_test() -> void:
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
	_burst_is_first_shot = true
	_continuous = false
	hold_button.set_pressed_no_signal(false)
	pause_button.set_pressed_no_signal(false)
	pause_button.text = "PAUSE"
	if profile != null:
		if combat_scenario.shooter != null and combat_scenario.primary_target() != null and combat_scenario._baseline_captured:
			combat_scenario.reset("ALL")
			combat_scenario.update_effective_odf_parameters(profile)
			var prim0 = combat_scenario.primary_target()
			if target_node != null and prim0 != null:
				target_node.position = prim0.position
				target_node.rotation_degrees.y = rad_to_deg(float(prim0.yaw_rad))
		else:
			combat_scenario.create_new_scenario(profile, target_node.position if target_node != null else Vector3(0, 0, -50), obstacles)
		_current_health = combat_scenario.primary_target().hull_current
		_current_shield = combat_scenario.primary_target().shield_current
	else:
		sim.reset()
	for et in extra_targets:
		et["health"] = float(et.get("max_health", _current_health))
		et["shield"] = float(et.get("max_shield", 0.0))
		if et.get("actor_state", null) != null and et.get("actor_state").has_method("reset_to_initial"):
			et["actor_state"].reset_to_initial()
	_rebuild_timeline_panel()
	_update_health_display()
	refresh_actor_inspector(true)
	status_changed.emit("Test reset.", "muted")


func _fire_one(use_alt: bool = false, fire_mode: String = "SINGLE", enforce_reload: bool = true,
		hp_override: Node3D = null, hp_name: String = "", barrel_index: int = 0,
		barrel_mode: String = "SINGLE", volley_id: int = 0) -> Dictionary:
	var prof := profile
	if use_alt:
		if profile == null or profile.alt == null:
			return {"ok": false, "state": "DISABLED", "reason": "NO_ALT_PROFILE"}
		prof = profile.alt
	if prof == null:
		return {"ok": false, "state": "DISABLED", "reason": "NO_PROFILE"}
	prof.refresh()
	if prof.shot_speed <= 0.0:
		_append_telemetry(sim.sim_time, "ERROR", "shotSpeed is 0; the ordnance cannot travel.")
		return {"ok": false, "state": "DISABLED", "reason": "ZERO_SHOT_SPEED"}
	var geom := _shot_geometry(hp_override)
	var origin: Vector3 = geom.origin
	var target_pos: Vector3 = geom.target
	var shooter_vel := Vector3.ZERO
	if shooter_speed_spin != null and absf(float(shooter_speed_spin.value)) > 0.01:
		var fwd := Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, deg_to_rad(shooter_yaw_offset_deg))
		shooter_vel = fwd * float(shooter_speed_spin.value)
	# Ensure CombatScenario is initialized without resetting depleted persistent combat state.
	if combat_scenario.shooter == null or combat_scenario.primary_target() == null or not combat_scenario._baseline_captured:
		combat_scenario.create_new_scenario(prof, target_pos, obstacles)
	# P0-SIM-02: Single atomic fire permission + resource consumption transition inside CombatScenario.
	var fire_res: Dictionary = combat_scenario.fire_shot(
		prof, origin, geom.direction, target_pos, obstacles, shooter_vel, enforce_reload, extra_targets,
		fire_mode, hp_name, barrel_index, barrel_mode, volley_id,
		active_weapon_slot, "ALTERNATE" if use_alt else "PRIMARY"
	)
	if not bool(fire_res.get("ok", false)):
		var rej := str(fire_res.get("reason", "FIRE_REJECTED"))
		var rej_st := str(fire_res.get("state", "DISABLED"))
		_append_telemetry(sim.sim_time, "FIRE_REJECTED", "%s (%s): reload=%.2fs ammo=%d (cost %d), energy=%.1f (cost %.1f)" % [
			rej_st, rej, float(combat_scenario.shooter.reload_remaining),
			int(combat_scenario.shooter.ammo_current), prof.ammo_cost,
			float(combat_scenario.shooter.energy_current), prof.weapon_energy_cost
		])
		status_changed.emit("Fire blocked: %s (%s)" % [rej_st, rej], "warning")
		_update_health_display()
		return fire_res
	var shot = fire_res.get("shot", null)
	if shot == null:
		return fire_res
	_update_health_display()
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
	projectiles.append({
		"shot": shot,
		"mesh": proj_node,
		"bolt": bolt_node,
		"identity": shot.identity.to_dict() if shot.identity != null else {},
	})
	_refresh_telemetry()
	return fire_res


func _on_combat_scenario_event(ev: Dictionary) -> void:
	var kind := str(ev.get("kind", "COMBAT"))
	var detail := str(ev.get("detail", ""))
	var odf_p := str(ev.get("odf_path", ""))
	var odf_k := str(ev.get("odf_key", ""))
	_record_timeline(float(ev.get("time", sim.sim_time)), kind, detail, odf_p, odf_k)
	var shot_id := int(ev.get("shot_id", 0))
	if shot_id > 0 and not timeline_events.is_empty():
		for index in range(timeline_events.size() - 1, -1, -1):
			if str(timeline_events[index].get("kind", "")) in ["SHOT_ACCEPTED", "PROJECTILE_SPAWNED"]:
				timeline_events[index]["shot_id"] = shot_id
				break
	_rebuild_timeline_panel()


func refresh_actor_inspector(force: bool = false) -> void:
	if actor_inspector_tree == null or combat_scenario == null:
		return
	var actors: Array = combat_scenario.all_actors()
	var sig_parts: PackedStringArray = []
	for a in actors:
		var eff_s := ""
		for e in a.active_effects:
			eff_s += "%s:%.1fs," % [str(e.get("name", "dot")), float(e.get("remaining_s", 0.0))]
		sig_parts.append("%s|%.1f/%.1f|%.1f/%.1f|%d/%d|%.1f/%.1f|%s|%s|%.2f|%.1f,%.1f,%.1f|%.1f,%.1f,%.1f|%s|%s" % [
			str(a.actor_id), float(a.hull_current), float(a.hull_max),
			float(a.shield_current), float(a.shield_max),
			int(a.ammo_current), int(a.ammo_max),
			float(a.energy_current), float(a.energy_max),
			str(a.armor_class), str(a.weapon_name), float(a.reload_remaining),
			float(a.position.x), float(a.position.y), float(a.position.z),
			float(a.velocity.x), float(a.velocity.y), float(a.velocity.z),
			str(a.destroyed), eff_s
		])
	var sig := ";".join(sig_parts)
	if not force and sig == _last_actor_inspector_sig:
		return
	_last_actor_inspector_sig = sig
	actor_inspector_tree.clear()
	var root := actor_inspector_tree.create_item()
	for a in actors:
		var item := actor_inspector_tree.create_item(root)
		var state_tag := " [DESTROYED]" if bool(a.destroyed) else (" [DISABLED]" if bool(a.disabled) else "")
		item.set_text(0, "%s (%s)%s" % [str(a.display_name), str(a.role), state_tag])
		item.set_text(1, "%.1f / %.0f" % [float(a.hull_current), float(a.hull_max)])
		item.set_text(2, ("%.1f / %.0f (%s)" % [float(a.shield_current), float(a.shield_max), str(a.shield_class) if str(a.shield_class) != "" else "N"]) if float(a.shield_max) > 0.0 else "none")
		var am_s := "∞" if bool(a.ammo_unlimited) else "%d/%d" % [int(a.ammo_current), int(a.ammo_max)]
		var en_s := "∞" if bool(a.energy_unlimited) else "%.0f/%.0f" % [float(a.energy_current), float(a.energy_max)]
		item.set_text(3, "%s | %s" % [am_s, en_s])
		item.set_text(4, "%s | %s" % [str(a.armor_class), str(a.weapon_name) if str(a.weapon_name) != "" else "-"])
		var rld_txt := "READY" if float(a.reload_remaining) <= 0.0001 else ("RLD %.2fs" % float(a.reload_remaining))
		var eff_names: PackedStringArray = []
		for e in a.active_effects:
			eff_names.append("%s(%.1fs)" % [str(e.get("name", "dot")), float(e.get("remaining_s", 0.0))])
		item.set_text(5, rld_txt + ((" | " + ", ".join(eff_names)) if not eff_names.is_empty() else ""))
		item.set_text(6, "(%.1f,%.1f,%.1f) v=%.1f" % [float(a.position.x), float(a.position.y), float(a.position.z), (a.velocity as Vector3).length()])
	refresh_hardpoint_inspector(true)


## T-214 / PHI-07..14, T-221 / PHI-33..38, ALT-01..06: a stored volley belongs
## to the exact physical mount and firing mode that fired it. Equal weapon ODF
## names or paths in two slots never bind one slot's shot to another.
func _volley_matches_current_weapon(cur_name: String, cur_path: String) -> bool:
	if last_volley_result == null or profile == null:
		return false
	var volley = last_volley_result
	var v_name := str((volley as Object).get("weapon_identity"))
	var v_path := str((volley as Object).get("weapon_path"))
	var context := str((volley as Object).get("firing_context"))
	if context == "":
		context = "PRIMARY"
	if context == "ALTERNATE" and profile.alt == null:
		return false
	var target_name := cur_name
	var target_path := cur_path
	if context == "ALTERNATE":
		target_name = str(profile.alt.weapon_name)
		target_path = str(profile.alt.weapon_path)
	if v_name != "" and target_name != "" and v_name.to_lower() != target_name.to_lower():
		return false
	if v_path != "" and target_path != "":
		if WorkspaceStore.canonical(v_path) != WorkspaceStore.canonical(target_path):
			return false
	elif v_name == "" or target_name == "" or v_name.to_lower() != target_name.to_lower():
		return false
	var v_slot := int((volley as Object).get("weapon_slot"))
	if v_slot >= 0 and v_slot != active_weapon_slot:
		return false
	return true


## T-221 / PHI-41..44: one predicate for every historical shot column. The
## Shot ID and its launch origin must agree with the row's weapon, physical
## slot, hardpoint and shot identity, or neither is displayed.
## T-221 / WAVE H: double-click a Hardpoint Inspector row to jump the Combat
## State Timeline to the event of the shot shown in that physical mount.
func focus_shot_on_timeline(shot_id: int) -> bool:
	if shot_id <= 0:
		return false
	for i in timeline_events.size():
		var ev: Dictionary = timeline_events[i]
		if int(ev.get("shot_id", 0)) != shot_id:
			continue
		filter_timeline("all")
		for j in _timeline_filtered_events.size():
			if int((_timeline_filtered_events[j] as Dictionary).get("shot_id", 0)) != shot_id:
				continue
			if timeline_tree != null and timeline_tree.get_root() != null:
				var child := timeline_tree.get_root().get_first_child()
				var cur := 0
				while child != null:
					if cur == j:
						child.select(0)
						break
					cur += 1
					child = child.get_next()
			select_timeline_event(j)
			return true
	return false


func _on_hardpoint_row_selected() -> void:
	if hardpoint_inspector_tree == null:
		return
	var item := hardpoint_inspector_tree.get_selected()
	if item == null:
		return
	var hp_name := str(item.get_metadata(1))
	if hp_name != "" and hp_name != _selected_hardpoint_name:
		select_hardpoint(hp_name, int(item.get_metadata(2)))


func _on_hardpoint_row_activated() -> void:
	if hardpoint_inspector_tree == null:
		return
	var item := hardpoint_inspector_tree.get_selected()
	if item == null:
		return
	var shot_id := int(item.get_metadata(0))
	if focus_shot_on_timeline(shot_id):
		status_changed.emit("Timeline: shot #%d selected from Hardpoint Inspector" % shot_id, "muted")


func _shot_row_agrees(rec: Dictionary, hp_name: String, weapon_agrees: bool) -> bool:
	if not weapon_agrees or rec.is_empty():
		return false
	var identity: Dictionary = rec.get("shot_identity", {})
	if identity.is_empty():
		return false
	var v_slot := int(rec.get("weapon_slot", -1))
	if v_slot >= 0 and v_slot != active_weapon_slot:
		return false
	var hp_from_shot := str(identity.get("hardpoint", ""))
	if hp_name != "" and hp_from_shot != "" and hp_from_shot.to_lower() != hp_name.to_lower():
		return false
	if hp_from_shot == "" and hp_name != "":
		var declared := str(rec.get("hardpoint_name", ""))
		if declared.to_lower() != hp_name.to_lower():
			return false
	return true


## PHI-01..27: show the physical identity of each declared weapon slot. Shot
## data is bound to the weapon that fired it, resources come from the live
## shooter, and current origin is kept separate from launch origin.
func build_hardpoint_inspector_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if combat_scenario == null:
		return rows
	var shooter = combat_scenario.shooter
	var cur_name := str(profile.weapon_name) if profile != null else ""
	var cur_path := str(profile.weapon_path) if profile != null else ""
	var volley_bound := _volley_matches_current_weapon(cur_name, cur_path)
	var volley_stale := last_volley_result != null and not volley_bound
	var hps: Dictionary = shooter_model_info.get("hardpoints", {}) if bool(shooter_model_info.get("ok", false)) else {}
	var by_slot := {}
	if volley_bound:
		var shots = (last_volley_result as Object).get("resolved_barrels")
		if shots is Array:
			for b in (shots as Array):
				if b is Dictionary:
					by_slot[int((b as Dictionary).get("physical_slot", -1))] = b
	# PHI-15..21: authoritative CURRENT resource state, never invented fields.
	var ammo_txt := "-"
	var energy_txt := "-"
	var reload_txt := "-"
	if shooter != null:
		ammo_txt = "∞" if bool(shooter.ammo_unlimited) else "%d/%d" % [int(shooter.ammo_current), int(shooter.ammo_max)]
		energy_txt = "∞" if bool(shooter.energy_unlimited) else "%.0f/%.0f" % [float(shooter.energy_current), float(shooter.energy_max)]
		reload_txt = "READY" if float(shooter.reload_remaining) <= 0.0001 else "RLD %.2fs" % float(shooter.reload_remaining)
	var names: Array[String] = []
	if profile != null:
		for hp in profile.weapon_hardpoints:
			var nm := str(hp)
			if nm != "" and not names.has(nm):
				names.append(nm)
	if names.is_empty() and profile != null:
		names.append("")
	if bool(shooter_model_info.get("ok", false)):
		var all_hps: Dictionary = shooter_model_info.get("hardpoints", {})
		var model_keys: Array = all_hps.keys()
		model_keys.sort()
		for raw_key in model_keys:
			var key := str(raw_key)
			if not names.has(key):
				names.append(key)
	for i in names.size():
		var nm := names[i]
		var node: Node3D = hps.get(nm.to_lower(), null) if hps.has(nm.to_lower()) and hps[nm.to_lower()] is Node3D else null
		var rec: Dictionary = by_slot.get(i, {})
		var fidelity := "RESOLVED_MODEL_NODE" if node != null else ("DECLARED_BUT_MISSING" if nm != "" else "FALLBACK_ORIGIN")
		if rec.is_empty() and nm == "":
			fidelity = "APPROXIMATED"
		var origin_txt := "n/a"
		var declared_name := str(rec.get("hardpoint_name", nm))
		if node == null and declared_name != "" and hps.has(declared_name.to_lower()) and \
				hps[declared_name.to_lower()] is Node3D:
			node = hps[declared_name.to_lower()]
			fidelity = "RESOLVED_MODEL_NODE"
		if node != null:
			var xf := _world_transform_in_lab(node)
			origin_txt = "(%.2f, %.2f, %.2f)" % [xf.origin.x, xf.origin.y, xf.origin.z]
		var identity: Dictionary = rec.get("shot_identity", {})
		var owners := _marker_owners(nm)
		var marker_identity := _marker_identity(nm, node)
		var owner_indices: Array = marker_identity.get("weapon_slots", [])
		var marker_role := str(marker_identity.get("marker_role", "GENERIC_MODEL_HARDPOINT"))
		var owner_txt := "INSPECTION_ONLY · " + marker_role
		var source_txt := "no weapon owner"
		if not owners.is_empty():
			var selected_owner := active_weapon_slot if owner_indices.has(active_weapon_slot) else -1
			var slot_source := profile.slot_source(selected_owner) if selected_owner >= 0 and profile != null else {}
			if slot_source.is_empty() and selected_owner >= 0:
				slot_source = WeaponProfile.slot_source_from_slots(_effective_weapon_slots(), selected_owner)
			var selected_name := str(slot_source.get("weapon", ""))
			if selected_name == "" and not slot_source.is_empty():
				selected_name = str(slot_source.get("path", "")).get_file()
			owner_txt = "owners=%s · active=%d" % [str(owner_indices), selected_owner]
			if selected_owner < 0:
				source_txt = "OWNER_SELECTION_REQUIRED"
			else:
				var ordnance_txt := str(slot_source.get("ordnance_name", ""))
				var ordnance_path := str(slot_source.get("ordnance_path", ""))
				if ordnance_txt == "" and ordnance_path != "":
					ordnance_txt = ordnance_path.get_file()
				if str(slot_source.get("ordnance_status", "")) == "ORDNANCE_UNRESOLVED":
					ordnance_txt = "ORDNANCE_UNRESOLVED"
				source_txt = "%s → %s" % [selected_name if selected_name != "" else "-",
					ordnance_txt if ordnance_txt != "" else "-"]
		var firing_txt := "INSPECTION_ONLY" if owners.is_empty() else "%s · %s" % [
			str(profile.barrel_mode) if profile != null else barrel_mode,
			str(_last_firing_policy.get("selection", "NOT_FIRED_YET"))]
		var rec_weapon := str(rec.get("weapon_name", ""))
		var context := str(rec.get("firing_context", "PRIMARY"))
		var shown_weapon := cur_name
		if context == "ALTERNATE" and profile != null and profile.alt != null:
			shown_weapon = str(profile.alt.weapon_name)
		var weapon_agrees := volley_bound and (rec_weapon == "" or shown_weapon == "" or \
			rec_weapon.to_lower() == shown_weapon.to_lower())
		var shot_matches_row := _shot_row_agrees(rec, nm, weapon_agrees)
		var shot_prefix := "ALT#" if context == "ALTERNATE" else "#"
		var sid_txt := "not fired"
		if shot_matches_row:
			sid_txt = "%s%s hp=%s" % [shot_prefix, str(identity.get("shot_id", "?")),
				str(identity.get("hardpoint", nm))]
		elif volley_stale:
			sid_txt = "LAST_SHOT_NOT_FOR_CURRENT_WEAPON"
		var shot_origin_txt := "unavailable"
		if shot_matches_row and bool(rec.get("launch_origin_available", false)):
			var launch = rec.get("launch_origin", null)
			if launch is Array and (launch as Array).size() == 3:
				shot_origin_txt = "(%.2f, %.2f, %.2f)" % [float(launch[0]), float(launch[1]), float(launch[2])]
		var shot_rev_txt := "unavailable"
		var rev_status_txt := "REVISION_UNVERIFIED"
		if shot_matches_row:
			var shot_rev: Dictionary = identity.get("source_revision", {})
			var current_rev: Dictionary = profile.snapshot_params().get("odf_revisions", {}) if profile != null else {}
			var comparisons: Array[String] = []
			for role in ["shooter", "weapon", "ordnance"]:
				var old_entry: Dictionary = shot_rev.get(role, {})
				var new_entry: Dictionary = current_rev.get(role, {})
				var old_md5 := str(old_entry.get("md5", ""))
				var new_md5 := str(new_entry.get("md5", ""))
				if old_md5 == "":
					comparisons.append("%s=SHOT_REV_UNKNOWN" % role)
				elif new_md5 == "":
					comparisons.append("%s=SOURCE_MISSING" % role)
				elif old_md5 == new_md5:
					comparisons.append("%s=IDENTICAL" % role)
				else:
					comparisons.append("%s=SOURCE_CHANGED" % role)
			shot_rev_txt = "weapon:%s" % str((shot_rev.get("weapon", {}) as Dictionary).get("md5", "?")).substr(0, 8)
			rev_status_txt = ", ".join(comparisons)
		rows.append({
			"hardpoint": nm if nm != "" else "(editor-defined)",
			"hardpoint_key": nm,
			"weapon": cur_name if cur_name != "" else "-",
			"owner_role": owner_txt,
			"weapon_ordnance": source_txt,
			"firing_policy": firing_txt,
			"firing_eligibility": str(marker_identity.get("firing_eligibility", "INSPECTION_ONLY")),
			"marker_role": marker_role,
			"weapon_slots": owner_indices,
			"weapon_path": str(marker_identity.get("weapon_path", "")),
			"ordnance_path": str(marker_identity.get("ordnance_path", "")),
			"ordnance_status": str(marker_identity.get("ordnance_status", "NOT_APPLICABLE")),
			"source_revision": marker_identity.get("source_revision", {}),
			"fidelity": fidelity,
			"node_id": int(node.get_instance_id()) if node != null else 0,
			"node": node.name if node != null else "-",
			"origin": origin_txt,
			"shot": sid_txt,
			"shot_weapon": rec_weapon,
			"firing_context": context,
			"shot_id": int(identity.get("shot_id", 0)) if shot_matches_row else 0,
			"shot_origin": shot_origin_txt,
			"shot_revision": shot_rev_txt,
			"revision_status": rev_status_txt,
			"ammo": ammo_txt,
			"energy": energy_txt,
			"reload": reload_txt,
		})
	return rows


func refresh_hardpoint_inspector(force: bool = false) -> void:
	if hardpoint_inspector_tree == null:
		return
	var rows := build_hardpoint_inspector_rows()
	var sig := JSON.stringify(rows)
	if not force and sig == _last_hardpoint_inspector_sig:
		return
	_last_hardpoint_inspector_sig = sig
	hardpoint_inspector_tree.clear()
	var root := hardpoint_inspector_tree.create_item()
	for row in rows:
		var item := hardpoint_inspector_tree.create_item(root)
		item.set_text(0, str(row.get("hardpoint", "")))
		item.set_text(1, str(row.get("owner_role", "")))
		item.set_text(2, str(row.get("weapon_ordnance", "")))
		item.set_text(3, str(row.get("firing_policy", "")))
		item.set_text(4, str(row.get("fidelity", "")))
		item.set_text(5, str(row.get("node", "")))
		item.set_text(6, str(row.get("origin", "")))
		item.set_text(7, str(row.get("shot", "")))
		item.set_text(8, str(row.get("shot_origin", "")))
		item.set_text(9, str(row.get("shot_revision", "")))
		item.set_text(10, str(row.get("revision_status", "")))
		item.set_text(11, str(row.get("ammo", "")))
		item.set_text(12, str(row.get("energy", "")))
		item.set_text(13, str(row.get("reload", "")))
		item.set_metadata(0, int(row.get("shot_id", 0)))
		item.set_metadata(1, str(row.get("hardpoint_key", "")))
		item.set_metadata(2, int(row.get("node_id", 0)))
		item.set_metadata(3, str(row.get("weapon_path", "")))
		item.set_metadata(4, str(row.get("ordnance_path", "")))


func capture_replay_snapshot(label: String = "") -> Dictionary:
	if combat_scenario == null:
		return {}
	var lbl := label if label != "" else ("Run %d (%s)" % [combat_scenario.saved_replay_snapshots.size() + 1, profile.weapon_name if profile != null else "sim"])
	var snap: Dictionary = combat_scenario.save_replay_snapshot(lbl)
	if replay_snapshot_option != null:
		replay_snapshot_option.add_item(str(snap.get("label", lbl)))
		replay_snapshot_option.set_item_metadata(replay_snapshot_option.item_count - 1, str(snap.get("snapshot_id", "")))
		replay_snapshot_option.select(replay_snapshot_option.item_count - 1)
	status_changed.emit("Captured replay snapshot: %s (%d shot(s))" % [lbl, (snap.get("shot_commands", []) as Array).size()], "success")
	return snap


func _resolve_replay_snapshot(snapshot_id: String = "") -> Dictionary:
	if combat_scenario == null or combat_scenario.saved_replay_snapshots.is_empty():
		return {}
	var target_id := snapshot_id
	if target_id == "" and replay_snapshot_option != null and replay_snapshot_option.selected >= 0:
		target_id = str(replay_snapshot_option.get_item_metadata(replay_snapshot_option.selected))
	var chosen: Dictionary = combat_scenario.saved_replay_snapshots[-1]
	if target_id != "":
		for s in combat_scenario.saved_replay_snapshots:
			if str((s as Dictionary).get("snapshot_id", "")) == target_id:
				chosen = s
				break
	return chosen


func _finish_replay_report(label: String, res: Dictionary) -> void:
	last_replay_result = res
	var prim_st: Dictionary = (res.get("targets", {}) as Dictionary).get("primary", {})
	_append_telemetry(sim.sim_time, "REPLAY", "Sandboxed replay '%s': %d shot(s) (%d acc / %d rej, peak_concurrent=%d), ammo=%d, primary hull=%.1f shield=%.1f" % [
		label, int(res.get("shots_replayed", 0)), int(res.get("accepted_shots", 0)),
		int(res.get("rejected_shots", 0)), int(res.get("max_concurrent_shots", 0)),
		int(res.get("shooter_ammo", 0)), float(prim_st.get("hull", 0.0)), float(prim_st.get("shield", 0.0))
	])
	var complete := bool(res.get("complete", true))
	var reason := str(res.get("reason", "REPLAY_COMPLETE"))
	if not complete:
		status_changed.emit("Replay stopped: %s (%d/%d events, %d in flight)" % [
			reason, int(res.get("events_processed", 0)),
			int(res.get("events_processed", 0)) + int(res.get("events_remaining", 0)),
			int(res.get("projectiles_in_flight", 0))
		], "danger")
		return
	status_changed.emit("Sandboxed replay complete: %d shot(s), peak %d concurrent (active scenario untouched)" % [
		int(res.get("shots_replayed", 0)), int(res.get("max_concurrent_shots", 0))
	], "success")


## A terminal replay is not automatically a successful replay. The result's
## own `complete`/`ok`/`reason` fields decide the visible job state.
func _replay_job_state_from_result(res: Dictionary) -> String:
	var complete := bool(res.get("complete", false))
	var ok := bool(res.get("ok", complete))
	if not complete or not ok:
		return "FAILED"
	return "COMPLETE"


## Incremental non-blocking GUI replay for large many-shot snapshots (RPL-14).
func start_incremental_replay(snapshot_id: String = "") -> Dictionary:
	if _replay_job_state in ["QUEUED", "RUNNING", "PAUSED", "CANCEL_REQUESTED"]:
		status_changed.emit("Replay already running; cancel or wait before starting another.", "warning")
		return {"ok": false, "reason": "REPLAY_ALREADY_RUNNING"}
	var chosen := _resolve_replay_snapshot(snapshot_id)
	if chosen.is_empty():
		status_changed.emit("Replay: capture a replay snapshot first.", "warning")
		return {"ok": false, "reason": "NO_REPLAY_SNAPSHOT"}
	_replay_job_id += 1
	_replay_job_type = "single"
	_replay_job_state = "RUNNING"
	_replay_paused = false
	_replay_job_snapshot_ids = [str(chosen.get("snapshot_id", ""))]
	_replay_ab_queue.clear()
	_replay_ab_results.clear()
	_replay_ab_ids.clear()
	_active_replay_label = str(chosen.get("label", str(chosen.get("snapshot_id", "replay"))))
	_active_replay_runner = CombatScenarioScript.create_replay_runner(chosen)
	var first_step: Dictionary = _active_replay_runner.step(18, 6.0)
	if bool(first_step.get("done", false)):
		var res: Dictionary = first_step.get("result", {})
		_active_replay_runner = null
		_replay_job_state = _replay_job_state_from_result(res)
		last_replay_result = res
		last_replay_result["job_state"] = _replay_job_state
		_finish_replay_report(_active_replay_label, res)
		return {"ok": true, "done": true, "result": res}
	status_changed.emit("Replaying '%s' incrementally (%.0f%%)…" % [_active_replay_label, float(first_step.get("progress", 0.0)) * 100.0], "muted")
	return {"ok": true, "done": false, "progress": float(first_step.get("progress", 0.0))}


func replay_selected_snapshot(snapshot_id: String = "") -> Dictionary:
	# RPL-30..34: primary GUI replay is always incremental and cancellable;
	# synchronous execution remains available only via the static sim API.
	var started := start_incremental_replay(snapshot_id)
	if not bool(started.get("ok", false)):
		return started
	if bool(started.get("done", false)):
		return started.get("result", {})
	return {"ok": true, "running": true, "reason": "REPLAY_IN_PROGRESS"}


func cancel_replay() -> void:
	if _replay_job_state in ["IDLE", "COMPLETE", "CANCELLED", "FAILED"]:
		return
	_replay_job_state = "CANCELLED"
	_replay_ab_queue.clear()
	_active_replay_runner = null
	_replay_ab_results.clear()
	_replay_ab_ids.clear()
	_replay_paused = false
	status_changed.emit("Replay cancelled; active scenario preserved.", "warning")


func toggle_replay_pause() -> void:
	if _replay_job_state in ["IDLE", "COMPLETE", "CANCELLED", "FAILED"]:
		status_changed.emit("No active replay to pause.", "warning")
		return
	_replay_paused = not _replay_paused
	_replay_job_state = "PAUSED" if _replay_paused else "RUNNING"
	status_changed.emit("Replay paused." if _replay_paused else "Replay resumed.", "muted")


func start_bounded_ab_replay() -> Dictionary:
	if combat_scenario == null or (combat_scenario.saved_replay_snapshots as Array).size() < 2:
		status_changed.emit("Compare A/B: capture at least two replay snapshots first.", "warning")
		return {"ok": false, "reason": "NO_REPLAY_SNAPSHOT"}
	if _replay_job_state in ["QUEUED", "RUNNING", "PAUSED", "CANCEL_REQUESTED"] or 			_active_replay_runner != null or not _replay_ab_queue.is_empty():
		status_changed.emit("Compare A/B already running.", "warning")
		return {"ok": false, "reason": "REPLAY_ALREADY_RUNNING"}
	var snaps: Array = combat_scenario.saved_replay_snapshots
	_replay_ab_ids = [
		str((snaps[snaps.size() - 2] as Dictionary).get("snapshot_id", "")),
		str((snaps[snaps.size() - 1] as Dictionary).get("snapshot_id", "")),
	]
	_replay_job_id += 1
	_replay_job_type = "ab"
	_replay_job_state = "QUEUED"
	_replay_paused = false
	_replay_ab_results.clear()
	_replay_ab_queue = snaps.slice(maxi(0, snaps.size() - 2), snaps.size()).duplicate(true)
	_replay_job_snapshot_ids = _replay_ab_ids.duplicate()
	status_changed.emit("Compare A/B: queued 2 bounded replays.", "muted")
	return {"ok": true, "queued": 2}


func _advance_ab_queue() -> void:
	if _replay_ab_queue.is_empty():
		return
	var next_snap: Dictionary = _replay_ab_queue[0]
	_replay_ab_queue.remove_at(0)
	var runner = CombatScenarioScript.create_replay_runner(next_snap)
	var first_step: Dictionary = runner.step(18, 6.0)
	if not bool(first_step.get("done", false)):
		_active_replay_runner = runner
		_active_replay_label = "A/B " + str(_replay_ab_results.size() + 1)
		return
	_replay_ab_results.append(first_step.get("result", {}))
	_finish_ab_if_ready()


func _finish_ab_if_ready() -> void:
	if _replay_ab_queue.is_empty() and _replay_ab_results.size() >= 2:
		var a: Dictionary = _replay_ab_results[0]
		var b: Dictionary = _replay_ab_results[1]
		last_replay_comparison = CombatScenarioScript.compare_replay_results(a, b)
		last_replay_comparison["snapshot_a"] = _replay_ab_ids[0]
		last_replay_comparison["snapshot_b"] = _replay_ab_ids[1]
		last_replay_comparison["job_id"] = _replay_job_id
		last_replay_comparison["complete"] = bool(a.get("complete", false)) and bool(b.get("complete", false))
		last_replay_comparison["reasons"] = [str(a.get("reason", "")), str(b.get("reason", ""))]
		var both_ok := bool(a.get("ok", false)) and bool(b.get("ok", false))
		var partial := bool(last_replay_comparison.get("complete", false)) and not both_ok
		if not bool(last_replay_comparison.get("complete", false)):
			_replay_job_state = "FAILED"
			status_changed.emit("A/B replay incomplete: " + str(last_replay_comparison.get("reasons", [])), "danger")
		elif partial:
			_replay_job_state = "PARTIAL_RESULT"
			status_changed.emit("A/B replay partial: " + str(last_replay_comparison.get("summary", "")), "warning")
		else:
			_replay_job_state = "COMPLETE"
			status_changed.emit(str(last_replay_comparison.get("summary", "")), "success")
		last_replay_comparison["job_state"] = _replay_job_state
		_replay_ab_results.clear()
		_replay_ab_ids.clear()


func apply_test_dot(actor_id: String = "primary", effect_name: String = "Burn (APPROX)", dps: float = 25.0, duration_s: float = 4.0) -> bool:
	if combat_scenario == null:
		return false
	var ok: bool = combat_scenario.apply_status_effect(actor_id, effect_name, dps, duration_s)
	if ok:
		_running = true
		_update_health_display()
		refresh_actor_inspector(true)
		status_changed.emit("Applied %s (%.1f dps, %.1fs) to %s" % [effect_name, dps, duration_s, actor_id], "muted")
	return ok


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
			return k in [
				"WEAPON_ACTIVATE", "IMPACT", "OBSTACLE_HIT",
				"FIRE_REQUESTED", "SHOT_ACCEPTED", "SHOT_REJECTED",
				"AMMO_CONSUMED", "ENERGY_CONSUMED", "PROJECTILE_SPAWNED",
				"PROJECTILE_HIT", "SHIELD_ABSORBED", "HULL_DAMAGED",
				"ACTOR_DESTROYED", "RELOAD_READY", "STATUS_EFFECT_TICK",
				"STATUS_EFFECT_APPLIED", "PROFILE_CHANGED"
			]
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
	if _active_replay_runner != null and not _replay_paused:
		var rstep: Dictionary = _active_replay_runner.step(18, 6.0)
		if bool(rstep.get("done", false)):
			var rres: Dictionary = rstep.get("result", {})
			_active_replay_runner = null
			if not _replay_ab_queue.is_empty() or not _replay_ab_results.is_empty():
				_replay_ab_results.append(rres)
				_finish_ab_if_ready()
				_advance_ab_queue()
			else:
				_replay_job_state = _replay_job_state_from_result(rres)
				last_replay_result = rres
				last_replay_result["job_state"] = _replay_job_state
				_finish_replay_report(_active_replay_label, rres)
	elif _active_replay_runner == null and not _replay_ab_queue.is_empty() and not _replay_paused and _replay_job_state != "CANCELLED":
		_advance_ab_queue()
	_update_hud_tags()
	if profile == null:
		return
	var speed: float = float(speed_spin.value) if speed_spin else 1.0
	var dt := delta * speed
	if _anim_playing and not _paused and _anim_clip_name != "":
		step_model_animation(dt)
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
			combat_scenario.record_actor_transform("primary", g_live.target, _target_velocity, deg_to_rad(target_yaw_offset_deg))
		# P0-SIM-01: Single authoritative simulation clock owned by CombatScenario.
		# Never call sim.advance(dt) directly here or tick actor state twice.
		combat_scenario.advance(dt)
		_sync_projectiles()
		if _continuous:
			if combat_scenario.shooter != null and float(combat_scenario.shooter.reload_remaining) <= 0.0001:
				var hres := _fire_volley(false, "HOLD", true)
				if not bool(hres.get("ok", false)) and str(hres.get("state", "")) in ["INSUFFICIENT_AMMO", "INSUFFICIENT_ENERGY", "DESTROYED", "DISABLED"]:
					stop_fire()
		if _burst_left > 0:
			_burst_timer -= dt
			if _burst_timer <= 0.0:
				var bmode := "BURST" if _burst_is_first_shot else "SALVO_FOLLOWUP"
				var enforce_rld := _burst_is_first_shot
				var bres := _fire_volley(false, bmode, enforce_rld)
				if bool(bres.get("ok", false)):
					_burst_left -= 1
					_burst_is_first_shot = false
					_burst_timer = max(0.0, salvo_delay_or_zero())
				elif str(bres.get("state", "")) != "RELOADING":
					_burst_left = 0
					_burst_is_first_shot = true
		_refresh_telemetry()
		_update_health_display()
		# Keep stepping while any projectile is in flight, fire is queued, or
		# reload/DoT timers remain active on any actor (P0-SIM-01).
		_running = _continuous or _burst_left > 0 or _any_alive() or combat_scenario.has_active_timers()


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
				_record_timeline(sim.sim_time, tl_kind, tl_detail,
				(s.identity.ordnance_path if s.identity != null and s.identity.ordnance_path != "" else (profile.ordnance_path if profile != null else "")), "damageValue")
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
	_update_projectile_trajectories()
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
	var ctx := profile.ordnance_path if profile != null else ""
	var expl_sound := profile.expl_sound if profile != null else ""
	if s.identity != null:
		ctx = s.identity.ordnance_path if s.identity.ordnance_path != "" else ctx
		expl_sound = s.identity.expl_sound if s.identity.expl_sound != "" else expl_sound
	var path: String = index.resolve_path_from(declared, ctx) if index != null else ""
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
	if expl_sound != "":
		_play_sound_asset(expl_sound, path, "SFX_XPL")
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


func _on_native_session_updated(session_id: String, snap: Dictionary) -> void:
	if session_id != "":
		active_native_session_id = session_id
	_update_native_controls("", snap)


func _update_native_controls(note: String = "", snap_override: Dictionary = {}) -> void:
	if native_status_label == null:
		return
	var snap: Dictionary = snap_override
	if snap.is_empty() and native_session_service != null:
		snap = native_session_service.get_status_snapshot(active_native_session_id)
	if active_native_session_id == "" or native_runner == null:
		native_status_label.text = note if note != "" else "Native: idle (NATIVE_VERIFIED: 0)"
		if native_monitor_label != null:
			native_monitor_label.text = "SESSION: - | STATE: IDLE | PID: 0 | MISSION: WAITING | PROBE: WAITING | OBS: NONE | ELAPSED: 0.0s / 30.0s"
		return
	var rec: Dictionary = native_runner.get_session_record(active_native_session_id)
	var st := str(snap.get("state", rec.get("state", "IDLE")))
	var rt := str(snap.get("launch_route", rec.get("launch_route", "")))
	var rsn := str(snap.get("reason", rec.get("reason", "")))
	var cst := str(snap.get("cancel_status", rec.get("cancel_status", "")))
	var txt := "Native [%s]: %s" % [active_native_session_id.substr(0, 18), st]
	if rt != "":
		txt += " · " + rt
	if cst == "CANCELLATION_PERSIST_FAILED":
		txt += " [CANCELLATION_PERSIST_FAILED]"
	elif rsn != "":
		txt += " (" + rsn + ")"
	if note != "":
		txt += " — " + note
	native_status_label.text = txt
	if native_monitor_label != null:
		var extra_tag := " | CANCEL: " + cst if cst == "CANCELLATION_PERSIST_FAILED" else ""
		native_monitor_label.text = "SESSION: %s | STATE: %s | PID: %d | MISSION: %s | PROBE: %s | OBS: %s | ELAPSED: %.1fs / %.1fs%s" % [
			active_native_session_id.substr(0, 18),
			st,
			int(snap.get("game_pid", 0)),
			str(snap.get("mission_status", "WAITING")),
			str(snap.get("resource_probe", "WAITING")),
			str(snap.get("observation_status", "WAITING")),
			float(snap.get("elapsed_s", 0.0)),
			float(snap.get("timeout_s", 30.0)),
			extra_tag,
		]


func run_native_preflight_only(options: Dictionary = {}) -> Dictionary:
	if profile == null:
		status_changed.emit("Native preflight: load a weapon scenario first.", "warning")
		return {"ok": false}
	if native_runner == null:
		native_runner = native_session_service.runner if native_session_service != null else NativeRunnerScript.new()
	var opts := options.duplicate(true)
	if not opts.has("launch_mode") and native_launch_mode_option != null and native_launch_mode_option.selected >= 0:
		opts["launch_mode"] = str(native_launch_mode_option.get_item_metadata(native_launch_mode_option.selected))
	var res: Dictionary = native_session_service.preflight(profile, index, opts) if native_session_service != null else native_runner.preflight(profile, index, opts)
	active_native_session_id = str(res.get("session_id", ""))
	var pre: Dictionary = res.get("preflight", {})
	var disc: Dictionary = pre.get("discovery", {})
	_append_telemetry(sim.sim_time, "NATIVE_PRE", "Session=%s  mode=%s  build_id=%s  route=%s  stage_ok=%s  cfg_ok=%s  launch_ok=%s  reason=%s" % [
		active_native_session_id, str(pre.get("launch_mode", "CUSTOM_CONFIG")),
		str(disc.get("build_id", "UNKNOWN")), str(pre.get("launch_route", "")),
		str(bool(pre.get("stage_eligible", false))), str(bool(pre.get("config_compatible", false))),
		str(bool(pre.get("launch_eligible", false))), str(pre.get("reason", ""))
	])
	for b in pre.get("blockers", []):
		_append_telemetry(sim.sim_time, "NATIVE_BLK", str(b))
	_update_native_controls()
	status_changed.emit("Native preflight: %s [%s / %s]" % [str(pre.get("status", "")), str(pre.get("launch_route", "")), str(pre.get("launch_mode", ""))], "warning" if not bool(pre.get("launch_eligible", false)) else "success")
	return res


## T-75 read-only inventory of existing SHAMAN stages. Any unresolved or
## non-terminal stage stays untouched; no cleanup is performed here.
func inspect_native_stages(stage_roots: Array[String] = []) -> Array[Dictionary]:
	var roots := stage_roots.duplicate()
	if roots.is_empty():
		var addon_root := ProjectSettings.globalize_path("user://native_stage_inventory")
		var docs := OS.get_environment("USERPROFILE").path_join("Documents/My Games/Battlezone Combat Commander/Addon")
		if DirAccess.dir_exists_absolute(docs):
			roots.append(docs)
		if DirAccess.dir_exists_absolute(addon_root):
			roots.append(addon_root)
	last_native_stage_inventory.clear()
	var lines: Array[String] = []
	for root in roots:
		var d := DirAccess.open(root)
		if d == null:
			continue
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if name != "." and name != ".." and name.begins_with("SHAMAN_") and d.current_is_dir():
				var stage_path: String = root.path_join(name)
				var inspection: Dictionary = SafeStageScript.inspect_stage(stage_path)
				var res: Dictionary = SafeStageScript.reconcile_stage(stage_path)
				res["stage_name"] = name
				res["inspection_candidate"] = bool(inspection.get("cleanup_allowed", false))
				last_native_stage_inventory.append(res)
				lines.append("%s | session=%s | state=%s | ownership=%s | hashes=%s | unknown=%d | ledger=%s | monitor=%s | reconciliation=%s | cleanup=%s" % [
					name, str(res.get("session_id", "-")), str(res.get("session_status", "UNKNOWN")),
					str(res.get("ownership", "UNRESOLVED")), str(res.get("hash_status", "UNVERIFIED")),
					(res.get("unknown_files", []) as Array).size(),
					str(res.get("ledger_status", "NOT_FOUND")), str(res.get("monitor_status", "NOT_CHECKED")),
					str(res.get("reason", "STAGE_INSPECTION_INCOMPLETE")),
					"allowed" if bool(res.get("cleanup_allowed", false)) else "refused",
				])
			name = d.get_next()
		d.list_dir_end()
	if native_stage_inventory_label != null:
		native_stage_inventory_label.text = "\n".join(lines) if not lines.is_empty() else "No SHAMAN stages found."
	var unresolved := 0
	for rec in last_native_stage_inventory:
		if str(rec.get("ownership", "UNRESOLVED")) == "UNRESOLVED":
			unresolved += 1
	if unresolved > 0:
		status_changed.emit("Native stage inventory: %d stage(s), %d ownership unresolved; no files changed." % [
			last_native_stage_inventory.size(), unresolved
		], "warning")
	return last_native_stage_inventory


func run_native_stage(options: Dictionary = {}) -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		var pre := run_native_preflight_only(options)
		if not bool(pre.get("ok", false)) and str(pre.get("session_id", "")) == "":
			return pre
	var res: Dictionary = native_session_service.stage(active_native_session_id, {}, options) if native_session_service != null else native_runner.stage(active_native_session_id, {}, options)
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
	var res: Dictionary = native_session_service.launch(active_native_session_id, opts) if native_session_service != null else native_runner.launch(active_native_session_id, opts)
	_append_telemetry(sim.sim_time, "NATIVE_RUN", "Session=%s  state=%s  route=%s  reason=%s" % [
		active_native_session_id, str(res.get("state", "")), str(res.get("route", "")), str(res.get("reason", ""))
	])
	_update_native_controls()
	status_changed.emit("Native launch: %s [%s]" % [str(res.get("state", "")), str(res.get("route", ""))], "success" if bool(res.get("ok", false)) else "warning")
	return res


func run_native_cancel_monitor() -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		return {"ok": false, "reason": "NO_ACTIVE_MONITOR"}
	var res: Dictionary = native_session_service.cancel_monitoring(active_native_session_id) if native_session_service != null else native_runner.cancel_monitor(active_native_session_id)
	_append_telemetry(sim.sim_time, "NATIVE_MON", "Monitor cancelled: state=%s" % str(res.get("state", "")))
	_update_native_controls()
	return res


func run_native_resume_monitor() -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		return {"ok": false, "reason": "NO_MONITOR_TO_RESUME"}
	var res: Dictionary = native_session_service.resume_monitoring(active_native_session_id) if native_session_service != null else native_runner.resume_monitor(active_native_session_id)
	_append_telemetry(sim.sim_time, "NATIVE_MON", "Monitor resumed: state=%s active=%s" % [str(res.get("state", "")), str(res.get("active", false))])
	_update_native_controls()
	return res


func run_native_handoff(options: Dictionary = {}) -> Dictionary:
	var opts := options.duplicate(true)
	opts["manual_handoff"] = true
	return run_native_launch(false, opts)


func run_native_arm_manual_observation(options: Dictionary = {}) -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		status_changed.emit("Arm manual observation: run PREPARE EXPERIMENT and STAGE RESOURCES first.", "warning")
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = native_session_service.arm_manual_observation(active_native_session_id, options) if native_session_service != null else native_runner.arm_manual_observation(active_native_session_id, options)
	_append_telemetry(sim.sim_time, "NATIVE_MON", "Manual observation armed: state=%s active=%s" % [str(res.get("state", "")), str(res.get("active", false))])
	_update_native_controls()
	status_changed.emit("Manual observation: %s" % str(res.get("state", "FAILED")), "success" if bool(res.get("ok", false)) else "warning")
	return res


func run_native_collect(observation_path_override: String = "") -> Dictionary:
	if active_native_session_id == "" or native_runner == null:
		status_changed.emit("Native collect: no active session.", "warning")
		return {"ok": false, "reason": "NO_ACTIVE_SESSION"}
	var res: Dictionary = native_session_service.collect_observation(active_native_session_id, observation_path_override) if native_session_service != null else native_runner.collect_observation(active_native_session_id, observation_path_override)
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
	var res: Dictionary = native_session_service.cleanup_stage(active_native_session_id) if native_session_service != null else native_runner.cleanup_stage(active_native_session_id)
	var rsn := str(res.get("reason", ""))
	_append_telemetry(sim.sim_time, "NATIVE_CLN", "Session=%s  state=%s  reason=%s" % [active_native_session_id, str(res.get("state", "")), rsn])
	_update_native_controls()
	if bool(res.get("cleanup_rejected", false)):
		status_changed.emit("Cleanup blocked (%s): click CANCEL MONITOR first." % rsn, "warning")
	else:
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
