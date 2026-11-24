extends SceneTree
## ALT-SLOT-01..10: physical mount identity is independent of the firing profile.

const WeaponProfileScript = preload("res://scripts/sim/weapon_profile.gd")
const WeaponLabScript = preload("res://scripts/lab/weapon_lab.gd")
const CombatScenarioScript = preload("res://scripts/sim/combat_scenario.gd")
const ResourceIndexScript = preload("res://scripts/core/resource_index.gd")
const SchemaRegistryScript = preload("res://scripts/core/schema_registry.gd")

var passed := 0
var failed := 0
var tmp := ""
var fixture_nodes: Array[Node] = []


func _check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
		print("  PASS " + msg)
	else:
		failed += 1
		print("  FAIL " + msg)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_check(false, "write fixture " + path)
		return
	f.store_string(text)
	f.close()


func _remove_tree(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _fixture() -> Dictionary:
	var base := tmp.path_join("vehicle")
	var shooter := base.path_join("shooter.odf")
	var weapon := base.path_join("gun_a.odf")
	var alt_weapon := base.path_join("gun_a_alt.odf")
	var target := base.path_join("target.odf")
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun_a\"\r\nweaponHard1=\"hp_left\"\r\nweaponName2=\"gun_a\"\r\nweaponHard2=\"hp_right\"\r\nmaxAmmo=100\r\nmaxEnergy=100\r\nmaxHealth=1000\r\n")
	_write(weapon, "[WeaponClass]\r\nordName=\"bullet\"\r\naltName=\"gun_a_alt\"\r\nshotDelay=0.05\r\n")
	_write(alt_weapon, "[WeaponClass]\r\nordName=\"bullet_alt\"\r\naltName=\"gun_a\"\r\nshotDelay=0.05\r\n")
	_write(base.path_join("bullet.odf"), "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\nammoCost=2\r\nenergyCost=3\r\n")
	_write(base.path_join("bullet_alt.odf"), "[OrdnanceClass]\r\nshotSpeed=90\r\nlifeSpan=2\r\ndamageValue(H)=12\r\nammoCost=2\r\nenergyCost=3\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	var idx := ResourceIndexScript.new()
	idx.roots.assign([{"path": tmp, "label": "alt_slot", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	return {"index": idx, "shooter": shooter, "target": target, "weapon": weapon}


func _make_lab(ctx: Dictionary) -> Object:
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(ctx["index"], SchemaRegistryScript.new())
	lab.shooter_path = str(ctx["shooter"])
	lab.target_path = str(ctx["target"])
	lab.barrel_mode = "SINGLE"
	var profile: WeaponProfile = WeaponProfileScript.new()
	_check(profile.resolve(ctx["index"], ctx["shooter"], ctx["target"], "", true, 0, "SINGLE"),
		"ALT-SLOT setup: profile resolves")
	lab.profile = profile
	lab.combat_scenario.create_new_scenario(profile, Vector3(0, 2, -50))
	var left := Node3D.new()
	left.name = "hp_left"
	left.position = Vector3(1.0, 1.0, 0.0)
	var right := Node3D.new()
	right.name = "hp_right"
	right.position = Vector3(-1.0, 1.0, 0.0)
	fixture_nodes.append_array([left, right])
	lab.shooter_model_info = {"ok": true, "hardpoints": {"hp_left": left, "hp_right": right}}
	return lab


func _fire_and_capture(lab: Object, alternate: bool, slot: int) -> Dictionary:
	_check(lab.switch_weapon_slot(slot), "ALT-SLOT setup: switch to physical slot %d" % slot)
	lab.combat_scenario.shooter.reload_remaining = 0.0
	var before_ammo := int(lab.combat_scenario.shooter.ammo_current)
	var before_energy := float(lab.combat_scenario.shooter.energy_current)
	if alternate:
		lab.fire_alt()
	else:
		lab._fire_volley(false, "SINGLE", true)
	var volley = lab.last_volley_result
	var identity: Dictionary = {}
	if not volley.resolved_barrels.is_empty():
		identity = volley.resolved_barrels[0].get("shot_identity", {})
	var history: Array = lab.combat_scenario.shot_history
	var request: Dictionary = history[-1] if not history.is_empty() else {}
	return {
		"volley": volley,
		"identity": identity,
		"request": request,
		"ammo_spent": before_ammo - int(lab.combat_scenario.shooter.ammo_current),
		"energy_spent": before_energy - float(lab.combat_scenario.shooter.energy_current),
	}


func _test_slot(ctx: Dictionary, slot: int) -> void:
	print("\n-- Alternate physical slot %d --" % slot)
	var lab := _make_lab(ctx)
	var fired := _fire_and_capture(lab, true, slot)
	var volley = fired["volley"]
	var identity: Dictionary = fired["identity"]
	var request: Dictionary = fired["request"]
	_check(volley.ok and int(volley.weapon_slot) == slot,
		"ALT-SLOT-%02d VolleyResult keeps physical slot %d" % [slot + 1, slot])
	_check(int(identity.get("weapon_slot", -1)) == slot,
		"ALT-SLOT-%02d ShotIdentity keeps physical slot %d" % [slot + 1, slot])
	_check(int(request.get("weapon_slot", -1)) == slot,
		"ALT-SLOT-04 CombatScenario request keeps physical slot %d" % slot)
	_check(int(volley.weapon_slot) == int(identity.get("weapon_slot", -2)) and
		int(request.get("weapon_slot", -2)) == int(identity.get("weapon_slot", -1)),
		"ALT-SLOT-03 volley, request and identity agree")
	_check(str(volley.firing_context) == "ALTERNATE" and
		str(request.get("firing_context", "")) == "ALTERNATE",
		"ALT-SLOT-03 alternate firing context is not relabelled primary")
	_check(int(fired["ammo_spent"]) == 2 and is_equal_approx(float(fired["energy_spent"]), 3.0),
		"ALT-SLOT-10 alternate shot has no extra ammo or energy cost")
	var snapshot: Dictionary = lab.combat_scenario.save_replay_snapshot("alt-slot-%d" % slot)
	var replay: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snapshot)
	_check(bool(replay.get("ok", false)) and int(replay.get("accepted_shots", 0)) == 1,
		"ALT-SLOT-06 replay restores and accepts physical slot %d" % slot)
	var replay_results: Array = replay.get("results", [])
	var replay_identity: Dictionary = replay_results[0].get("shot_identity", {}) if not replay_results.is_empty() else {}
	_check(int(replay_identity.get("weapon_slot", -2)) == slot and
		str(replay_identity.get("firing_context", "")) == "ALTERNATE",
		"ALT-SLOT-06 replay restores the exact physical slot and alternate context")
	var commands: Array = snapshot.get("timeline_inputs", [])
	var serialized_slot := -2
	for command in commands:
		if str(command.get("type", "")) == "FIRE_SHOT":
			serialized_slot = int(command.get("shot_command", {}).get("weapon_slot", -2))
			break
	_check(serialized_slot == slot,
		"ALT-SLOT-05 replay snapshot serializes physical slot %d" % slot)
	if slot == 1:
		_check(str(identity.get("weapon_path", "")).ends_with("gun_a_alt.odf") and
			int(identity.get("weapon_slot", -1)) == 1,
			"ALT-SLOT-08 same Weapon ODF in two mounts retains slot 2 provenance")
	var inspected: Array[String] = []
	lab.inspect_path_requested.connect(func(path: String): inspected.append(path))
	lab.fire_alt()
	lab.open_weapon_button.emit_signal("pressed")
	lab.open_ordnance_button.emit_signal("pressed")
	_check(inspected.size() == 2 and inspected[0].ends_with("gun_a_alt.odf") and inspected[1].ends_with("bullet_alt.odf"),
		"ALT-SLOT-08 source navigation opens the fired alternate Weapon and Ordnance ODFs")
	var timeline_requested: Array[int] = []
	lab.show_timeline_shot_requested.connect(func(shot_id: int): timeline_requested.append(shot_id))
	lab.show_timeline_shot_button.emit_signal("pressed")
	_check(timeline_requested.size() == 1 and timeline_requested[0] > 0 and
		lab.focus_shot_on_timeline(timeline_requested[0]),
		"ALT-SLOT-08 Timeline navigation targets the fired alternate shot")
	lab.queue_free()


func _initialize() -> void:
	print("Alternate physical-slot provenance verifier (ALT-SLOT-01..10)")
	tmp = ProjectSettings.globalize_path("user://verify_alt_slot_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var ctx := _fixture()
	_test_slot(ctx, 0)
	_test_slot(ctx, 1)

	var primary_lab := _make_lab(ctx)
	var primary := _fire_and_capture(primary_lab, false, 1)
	_check(int(primary["identity"].get("weapon_slot", -1)) == 1 and
		str(primary["volley"].firing_context) == "PRIMARY",
		"ALT-SLOT-07 PRIMARY firing remains unchanged")
	primary_lab.queue_free()

	var tandem_lab := _make_lab(ctx)
	_check(tandem_lab.switch_weapon_slot(1), "ALT-SLOT-09 setup: physical slot 2 selected")
	tandem_lab.barrel_mode = "TANDEM"
	tandem_lab.combat_scenario.shooter.reload_remaining = 0.0
	tandem_lab.fire_alt()
	var tandem_volley = tandem_lab.last_volley_result
	var barrel_ids: Array[int] = []
	var barrel_slots: Array[int] = []
	for barrel in tandem_volley.resolved_barrels:
		barrel_ids.append(int(barrel.get("shot_identity", {}).get("barrel_index", -1)))
		barrel_slots.append(int(barrel.get("shot_identity", {}).get("weapon_slot", -1)))
	_check(barrel_ids == [0, 1] and barrel_slots == [1, 1],
		"ALT-SLOT-09 TANDEM alternate preserves barrel identities and physical slot")
	tandem_lab.queue_free()

	for node in fixture_nodes:
		if is_instance_valid(node):
			node.free()
	_remove_tree(tmp)
	print("\nAlternate Physical Slot: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
