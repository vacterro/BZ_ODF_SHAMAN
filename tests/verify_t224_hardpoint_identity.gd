extends SceneTree
## T-224 / WAVE E: hardpoint owner, source and firing identity.
##
## Run: Godot --headless --path . --script res://tests/verify_t224_hardpoint_identity.gd

const WeaponProfileScript = preload("res://scripts/sim/weapon_profile.gd")
const WeaponLabScript = preload("res://scripts/lab/weapon_lab.gd")
const SchemaRegistryScript = preload("res://scripts/core/schema_registry.gd")

var passed := 0
var failed := 0
var _fixture_nodes: Array[Node] = []


func _check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
		print("  ✓ " + msg)
	else:
		failed += 1
		print("  ✗ FAIL: " + msg)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _remove_tree(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
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


func _fixture(tmp: String, shared: bool, with_ordnance: bool = true) -> Dictionary:
	var shooter := tmp.path_join("shared.odf" if shared else "distinct.odf")
	var weapon_a := tmp.path_join("gun_a.odf")
	var weapon_b := tmp.path_join("gun_b.odf")
	var ord_a := tmp.path_join("bullet_a.odf")
	var ord_b := tmp.path_join("bullet_b.odf")
	var target := tmp.path_join("target.odf")
	var ord_line_a := "ordName=\"bullet_a\"\r\n" if with_ordnance else "ordName=\"missing_a\"\r\n"
	var ord_line_b := "ordName=\"bullet_b\"\r\n" if with_ordnance else "ordName=\"missing_b\"\r\n"
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun_a\"\r\nweaponHard1=\"hp_left\"\r\nweaponName2=\"gun_b\"\r\nweaponHard2=\"%s\"\r\nmaxAmmo=500\r\nmaxEnergy=500\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n" %
		["hp_left" if shared else "hp_right"])
	_write(weapon_a, "[WeaponClass]\r\n" + ord_line_a + "shotDelay=0.05\r\n")
	_write(weapon_b, "[WeaponClass]\r\n" + ord_line_b + "shotDelay=0.05\r\n")
	_write(ord_a, "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\nshotRadius=0.5\r\nammoCost=1\r\nenergyCost=1\r\n")
	_write(ord_b, "[OrdnanceClass]\r\nshotSpeed=90\r\nlifeSpan=2\r\ndamageValue(H)=20\r\nshotRadius=0.5\r\nammoCost=1\r\nenergyCost=1\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": tmp, "label": "t224", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	return {"idx": idx, "shooter": shooter, "target": target,
		"weapon_a": weapon_a, "weapon_b": weapon_b, "ord_a": ord_a, "ord_b": ord_b}


func _make_lab(ctx: Dictionary, mode: String = "SINGLE") -> Object:
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(ctx["idx"], SchemaRegistryScript.new())
	lab.shooter_path = str(ctx["shooter"])
	lab.target_path = str(ctx["target"])
	lab.barrel_mode = mode if mode != "UNRESOLVED" else "SINGLE"
	var prof := WeaponProfileScript.new()
	prof.resolve(ctx["idx"], str(ctx["shooter"]), str(ctx["target"]), "", true, 0, lab.barrel_mode)
	_check(mode == "UNRESOLVED" or (prof.weapon_slots.size() == 2 and
		not str(prof.weapon_slots[1].get("ordnance_status", "")).is_empty()),
		"setup: two weapon slots retain independent source metadata")
	lab.profile = prof
	lab.combat_scenario.create_new_scenario(prof, Vector3(0, 2, -50))
	var hp_left := Node3D.new()
	hp_left.name = "hp_left"
	hp_left.position = Vector3(1.5, 1.0, 0.0)
	var hp_right := Node3D.new()
	hp_right.name = "hp_right"
	hp_right.position = Vector3(-1.5, 1.0, 0.0)
	var hp_smoke := Node3D.new()
	hp_smoke.name = "hp_smoke"
	hp_smoke.position = Vector3(0.0, 2.0, 1.0)
	_fixture_nodes.append_array([hp_left, hp_right, hp_smoke])
	lab.shooter_model_info = {"ok": true, "msh_path": str(ctx["shooter"]),
		"hardpoints": {"hp_left": hp_left, "hp_right": hp_right, "hp_smoke": hp_smoke}}
	return lab


func _identities(lab: Object) -> Dictionary:
	lab._update_aim_overlay()
	var result := {}
	for identity in lab._hardpoint_marker_data:
		var d: Dictionary = identity
		result[str(d.get("hardpoint", ""))] = d
	return result


func _test_shared_owner(tmp: String) -> void:
	print("\n-- HP-AMB-01..06: shared hardpoint owners --")
	var ctx := _fixture(tmp.path_join("shared"), true)
	var lab = _make_lab(ctx)
	lab.status_changed.connect(func(message, _level): print("  ! status: " + str(message)))
	var ids := _identities(lab)
	var shared: Dictionary = ids["hp_left"]
	_check((shared.get("weapon_slots", []) as Array).size() == 2 and
		bool(shared.get("ambiguous", false)),
		"HP-AMB-02: shared marker reports both owners")
	_check(lab.select_hardpoint_marker(int(shared.get("marker_id", 0))) == false,
		"HP-AMB-03: ambiguous click does not silently switch to owner 0")
	_check(lab.active_weapon_slot == 0 and lab.profile.weapon_name == "gun_a",
		"HP-AMB-03: ambiguous click preserves current weapon context")
	lab._rebuild_actor_models()
	lab.shooter_model_info = {"ok": true, "msh_path": str(ctx["shooter"]),
		"hardpoints": {"hp_left": _fixture_nodes[0], "hp_right": _fixture_nodes[1], "hp_smoke": _fixture_nodes[2]}}
	lab._update_aim_overlay()
	lab.select_hardpoint("hp_left", 0, 1)
	_check(lab.switch_weapon_slot(1), "HP-AMB-04 setup: explicit owner switches profile")
	lab._rebuild_actor_models()
	lab.shooter_model_info = {"ok": true, "msh_path": str(ctx["shooter"]),
		"hardpoints": {"hp_left": _fixture_nodes[0], "hp_right": _fixture_nodes[1], "hp_smoke": _fixture_nodes[2]}}
	lab._update_aim_overlay()
	lab.select_hardpoint("hp_left", 0, 1)
	_check(lab.active_weapon_slot == 1 and lab.profile.weapon_name == "gun_b",
		"HP-AMB-04: explicit owner selection activates slot B")
	var selected: Dictionary = lab._marker_identity_for_slot("hp_left", int(shared.get("node_id", 0)), 1)
	_check(str(selected.get("weapon_path", "")).ends_with("gun_b.odf") and
		str(selected.get("ordnance_path", "")).ends_with("bullet_b.odf"),
		"HP-SRC-03: selected owner resolves its own Weapon and Ordnance ODF")
	lab.combat_scenario.shooter.reload_remaining = 0.0
	var volley: Dictionary = lab._fire_volley(false, "SINGLE", true)
	var shot: Dictionary = ((volley.get("per_barrel_results", []) as Array)[0] as Dictionary)
	var identity: Dictionary = shot.get("shot_identity", {})
	_check(int(identity.get("weapon_slot", -1)) == 1 and
		str(identity.get("hardpoint", "")) == "hp_left" and
		str(identity.get("weapon_path", "")).ends_with("gun_b.odf") and
		str(identity.get("ordnance_path", "")).ends_with("bullet_b.odf"),
		"HP-AMB-05/06: fired shot belongs to selected physical slot B")
	var snap: Dictionary = lab.combat_scenario.save_replay_snapshot("shared-B")
	var profile_snap: Dictionary = snap.get("weapon_profile", {})
	var restored: Object = WeaponProfileScript.from_snapshot(profile_snap)
	_check(restored != null and restored.weapon_slots.size() == 2 and
		restored.active_slot_index == 1 and restored.weapon_path.ends_with("gun_b.odf") and
		restored.ordnance_path.ends_with("bullet_b.odf"),
		"HP-AMB-06: replay retains exact physical slot identity")
	var replay: Dictionary = CombatScenario.replay_snapshot_sandboxed(snap)
	_check(bool(replay.get("ok", false)) and replay.get("accepted_shots", 0) >= 1,
		"HP-AMB-06: chronological replay accepts the recorded slot B shot")
	var corrupt: Dictionary = snap.duplicate(true)
	var commands: Array = corrupt.get("timeline_inputs", [])
	for command in commands:
		if str((command as Dictionary).get("type", "")) != "FIRE_SHOT":
			continue
		var shot_command: Dictionary = (command.get("shot_command", {}) as Dictionary).duplicate(true)
		shot_command["weapon_slot"] = 0
		command["shot_command"] = shot_command
		break
	corrupt["timeline_inputs"] = commands
	var rejected_replay: Dictionary = CombatScenario.replay_snapshot_sandboxed(corrupt)
	_check(not bool(rejected_replay.get("ok", true)),
		"HP-AMB-06: contradictory replay is not successful")
	_check(not (rejected_replay.get("replay_errors", []) as Array).is_empty() or
		str(rejected_replay.get("reason", "")) == "REPLAY_IDENTITY_MISMATCH",
		"HP-AMB-06: replay reports contradictory physical slot identity")


func _test_source_mismatch(tmp: String) -> void:
	print("\n-- HP-SRC-01..05: ordnance provenance follows the owner --")
	var ctx := _fixture(tmp.path_join("sources"), false)
	var lab = _make_lab(ctx)
	lab.status_changed.connect(func(message, _level): print("  ! status: " + str(message)))
	var ids := _identities(lab)
	var right: Dictionary = ids["hp_right"]
	var identity: Dictionary = lab._marker_identity_for_slot("hp_right", int(right.get("node_id", 0)), 1)
	_check(str(identity.get("weapon_path", "")).ends_with("gun_b.odf") and
		str(identity.get("ordnance_path", "")).ends_with("bullet_b.odf"),
		"HP-SRC-02/03: inactive owner B never inherits active owner A ordnance")
	var shared_ctx := _fixture(tmp.path_join("shared_neutral"), true)
	var shared_lab = _make_lab(shared_ctx)
	shared_lab.active_weapon_slot = -1
	var shared_identity: Dictionary = shared_lab._marker_identity("hp_left", shared_lab._hardpoint_node_map().get("hp_left", null), -2)
	_check(int(shared_identity.get("weapon_slot", 0)) == -1,
		"HP-SRC-02: neutral shared marker has no primary owner")
	_check(str(shared_identity.get("ordnance_status", "")) == "OWNER_SELECTION_REQUIRED" and
		str(shared_identity.get("weapon_path", "")) == "" and str(shared_identity.get("ordnance_path", "")) == "",
		"HP-SRC-02: neutral shared marker has no invented source")
	if lab.active_weapon_slot != 1:
		_check(lab.switch_weapon_slot(1), "HP-SRC-05 setup: owner B slot switch")
	lab._rebuild_actor_models()
	lab.shooter_model_info = {"ok": true, "msh_path": str(ctx["shooter"]),
		"hardpoints": {"hp_left": _fixture_nodes[3], "hp_right": _fixture_nodes[4], "hp_smoke": _fixture_nodes[5]}}
	lab._update_aim_overlay()
	_check(bool(lab.select_hardpoint("hp_right", 0, 1)),
		"HP-SRC-05 setup: selected owner B mount accepted")
	ids = _identities(lab)
	var active_identity: Dictionary = ids["hp_right"] if ids.has("hp_right") else {}
	_check(lab.active_weapon_slot == 1 and
		str(active_identity.get("ordnance_path", "")).ends_with("bullet_b.odf"),
		"HP-SRC-05: slot switch leaves Inspector source identity consistent")

	var unresolved_ctx := _fixture(tmp.path_join("unresolved"), false, false)
	var unresolved_lab = _make_lab(unresolved_ctx, "UNRESOLVED")
	# Frozen snapshots avoid live resolution; inspect the owning Weapon ODF directly.
	var profile := WeaponProfileScript.new()
	_check(not profile.resolve(unresolved_ctx["idx"], str(unresolved_ctx["shooter"]),
		str(unresolved_ctx["target"]), "", false, 1, "SINGLE"),
		"HP-SRC-04 setup: unresolved ordnance is rejected")
	unresolved_lab.profile = profile
	unresolved_lab.active_weapon_slot = 0
	var unresolved_ids := _identities(unresolved_lab)
	_check(str((unresolved_ids["hp_right"] as Dictionary).get("ordnance_status", "")) ==
		"ORDNANCE_UNRESOLVED" and
		str((unresolved_ids["hp_right"] as Dictionary).get("ordnance_path", "")) == "",
		"HP-SRC-04: unresolved ordnance is explicit, never substituted")


func _test_firing_selection(tmp: String) -> void:
	print("\n-- FSEL-01..07: profile-aware firing selection --")
	var ctx := _fixture(tmp.path_join("firing"), false)
	var lab = _make_lab(ctx)
	lab.status_changed.connect(func(message, _level): print("  ! status: " + str(message)))
	lab.select_hardpoint("hp_left")
	_check(lab._fire_selection_hardpoint == "hp_left",
		"FSEL-01 setup: explicit SINGLE selection recorded")
	_check(lab.switch_weapon_slot(1) and lab._fire_selection_hardpoint == "",
		"FSEL-03: incompatible hardpoint selection invalidated on slot switch")
	lab.combat_scenario.shooter.reload_remaining = 0.0
	var volley: Dictionary = lab._fire_volley(false, "SINGLE", true)
	var barrels: Array = volley.get("per_barrel_results", [])
	var identity: Dictionary = (barrels[0] as Dictionary).get("shot_identity", {})
	_check(int(identity.get("weapon_slot", -1)) == 1 and
		str(identity.get("hardpoint", "")) == "hp_right",
		"FSEL-04/07: automatic SINGLE policy fires and records displayed barrel")
	_check(lab.switch_weapon_slot(0), "FSEL-05 setup: slot switch succeeds")
	lab.shooter_model_info = {"ok": true, "msh_path": str(ctx["shooter"]),
		"hardpoints": {"hp_left": _fixture_nodes[3], "hp_right": _fixture_nodes[4], "hp_smoke": _fixture_nodes[5]}}
	lab._update_aim_overlay()
	_check(bool(lab.select_hardpoint("hp_left")), "FSEL-05 setup: compatible selection accepted")
	_check(lab._fire_selection_hardpoint == "hp_left",
		"FSEL-05 setup: compatible selection restored")
	var revision_ctx := _fixture(tmp.path_join("revision_stale"), false)
	var revision_lab = _make_lab(revision_ctx)
	revision_lab.select_hardpoint("hp_left")
	var selected_revision: String = revision_lab._weapon_revision()
	revision_lab._fire_selection_weapon_revision = selected_revision + ":stale"
	var stale_volley: Dictionary = revision_lab._fire_volley(false, "SINGLE", false)
	_check(revision_lab._fire_selection_hardpoint == "",
		"FSEL-03: revision-only stale selection invalidated before fire")
	_check(str((stale_volley.get("firing_policy", {}) as Dictionary).get("selection", "")) in
		["AUTOMATIC_FIRST_DECLARED", "AUTOMATIC_FIRST_DECLARED_SELECTION_RESET"],
		"FSEL-04: automatic SINGLE policy is recorded after reset")
	lab.barrel_mode = "SALVO"
	volley = lab._fire_volley(false, "SALVO", true)
	_check((volley.get("per_barrel_results", []) as Array).size() == 1,
		"FSEL-06: SALVO policy unaffected by SINGLE identity")


func _test_inspection_only(tmp: String) -> void:
	print("\n-- MARK-01..05: non-weapon hardpoints stay inspection-only --")
	var ctx := _fixture(tmp.path_join("inspection"), false)
	var lab = _make_lab(ctx)
	lab.status_changed.connect(func(message, _level): print("  ! status: " + str(message)))
	lab._rebuild_actor_models()
	lab.shooter_model_info = {"ok": true, "msh_path": str(ctx["shooter"]),
		"hardpoints": {"hp_left": _fixture_nodes[6], "hp_right": _fixture_nodes[7], "hp_smoke": _fixture_nodes[8]}}
	lab._update_aim_overlay()
	lab.select_hardpoint("hp_left")
	var ids := _identities(lab)
	var smoke: Dictionary = ids["hp_smoke"]
	_check(str(smoke.get("marker_role", "")) == "GENERIC_MODEL_HARDPOINT" and
		int(smoke.get("weapon_slot", -1)) == -1 and
		str(smoke.get("weapon_path", "")) == "" and str(smoke.get("ordnance_path", "")) == "",
		"MARK-01/03: smoke hardpoint has no invented weapon ownership")
	_check(lab.select_hardpoint_marker(int(smoke.get("marker_id", 0))) and
		lab._selected_hardpoint_name == "hp_smoke",
		"MARK-02: non-weapon marker remains selectable for inspection")
	_check(lab._fire_selection_hardpoint == "hp_left" and
		str(lab._selected_marker_identity().get("firing_eligibility", "")) == "INSPECTION_ONLY",
		"MARK-04: selecting inspection-only marker does not replace firing mount")
	lab.combat_scenario.shooter.reload_remaining = 0.0
	var volley: Dictionary = lab._fire_volley(false, "SINGLE", true)
	var fire_identity: Dictionary = ((volley.get("per_barrel_results", []) as Array)[0] as Dictionary).get("shot_identity", {})
	_check(str(fire_identity.get("hardpoint", "")) == "hp_left",
		"MARK-05: projectile origin never claims the smoke hardpoint")


func _initialize() -> void:
	print("T-224 Hardpoint identity verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t224_hp_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	_test_shared_owner(tmp)
	_test_source_mismatch(tmp)
	_test_firing_selection(tmp)
	_test_inspection_only(tmp)
	for n in _fixture_nodes:
		if is_instance_valid(n):
			n.free()
	_remove_tree(tmp)
	print("\nT-224 Hardpoint Identity: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
