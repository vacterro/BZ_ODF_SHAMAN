extends SceneTree
## T-221 / WAVE C — physical weapon-slot shot provenance.
##
## PHI-33..40: one Weapon ODF in two physical slots does not share a Shot ID.
## PHI-41..44: Shot ID and historical launch origin use one row predicate.
## ALT-01..06: alternate (altName) shots keep a distinct firing context.
##
## Run: Godot --headless --path . --script res://tests/verify_t221_hardpoint_provenance.gd

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


func _mk_lab(tmp: String, idx: ResourceIndex, schema, shooter: String, target: String):
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(idx, schema)
	lab.shooter_path = shooter
	lab.target_path = target
	lab.barrel_mode = "SALVO"
	var prof := WeaponProfileScript.new()
	_check(prof.resolve(idx, shooter, target, "", true, 0, "SALVO"),
		"setup: weapon profile resolves")
	lab.profile = prof
	lab.combat_scenario.create_new_scenario(prof, Vector3(0, 2, -50))
	var hp_left := Node3D.new()
	hp_left.name = "hp_left"
	hp_left.position = Vector3(1.0, 1.0, 0.0)
	var hp_right := Node3D.new()
	hp_right.name = "hp_right"
	hp_right.position = Vector3(-1.0, 1.0, 0.0)
	lab.shooter_model_info = {"ok": true, "hardpoints": {"hp_left": hp_left, "hp_right": hp_right}}
	_fixture_nodes.append(hp_left)
	_fixture_nodes.append(hp_right)
	return lab


func _any_shot(rows: Array[Dictionary]) -> bool:
	for r in rows:
		if str(r.get("shot", "")).begins_with("#"):
			return true
	return false


func _test_same_odf_two_slots(tmp: String, idx: ResourceIndex, schema) -> void:
	print("\n-- PHI-33..40: same Weapon ODF in two physical slots --")
	# Two slots with the same Weapon ODF but different hardpoints.
	var shooter := tmp.path_join("dual.odf")
	var weapon := tmp.path_join("gun.odf")
	var ord := tmp.path_join("bullet.odf")
	var target := tmp.path_join("target.odf")
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun\"\r\nweaponHard1=\"hp_left\"\r\nweaponName2=\"gun\"\r\nweaponHard2=\"hp_right\"\r\nmaxAmmo=500\r\nmaxEnergy=500\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	_write(weapon, "[WeaponClass]\r\nordName=\"bullet\"\r\nshotDelay=0.05\r\n")
	_write(ord, "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\nshotRadius=0.5\r\nammoCost=1\r\nenergyCost=1\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	idx.scan(false)
	var lab = _mk_lab(tmp.path_join("phi33"), idx, schema, shooter, target)
	_check(lab.profile.weapon_slots.size() == 2 and
		str(lab.profile.weapon_slots[0].get("weapon", "")) == str(lab.profile.weapon_slots[1].get("weapon", "")),
		"PHI-33 setup: both slots resolve the same Weapon ODF")

	# Fire the first physical barrel only.
	lab._barrel_cycle = 0
	lab._fire_volley(false, "SINGLE", true)
	var rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(str(rows[0].get("shot", "")).begins_with("#") and
		str(rows[1].get("shot", "")) == "not fired",
		"PHI-34: shot bound to the fired physical slot/barrel")

	# Switch to the other physical slot with the same weapon ODF.
	_check(lab.switch_weapon_slot(1), "PHI-35 setup: switch to slot 2 succeeds")
	rows = lab.build_hardpoint_inspector_rows()
	_check(not _any_shot(rows),
		"PHI-36: slot 2 does not inherit slot 1 Shot ID")
	_check(str(rows[0].get("shot", "")).find("NOT_FOR_CURRENT") >= 0 or
		str(rows[1].get("shot", "")).find("NOT_FOR_CURRENT") >= 0,
		"PHI-36: inspector names the slot mismatch")

	# Switch back; historical shot is accessible again.
	_check(lab.switch_weapon_slot(0), "PHI-37 setup: switch back to slot 1 succeeds")
	rows = lab.build_hardpoint_inspector_rows()
	_check(str(rows[0].get("shot", "")).begins_with("#"),
		"PHI-38: historical slot 1 shot remains accessible")
	var spent := int(lab.combat_scenario.shooter.ammo_current)
	rows = lab.build_hardpoint_inspector_rows()
	_check(spent < 500 and str(rows[0].get("ammo", "")).begins_with(str(spent)),
		"PHI-40: displayed ammo is the live shooter value")

	# TANDEM barrel ordering is unchanged by slot binding.
	lab.barrel_mode = "TANDEM"
	lab.active_weapon_slot = 0
	lab.combat_scenario.shooter.reload_remaining = 0.0
	lab.profile = WeaponProfileScript.new()
	lab.profile.resolve(idx, shooter, target, "", true, 0, "TANDEM")
	lab._fire_volley(false, "TANDEM", true)
	rows = lab.build_hardpoint_inspector_rows()
	_check(rows.size() == 2 and str(rows[0].get("shot", "")).begins_with("#") and
		str(rows[1].get("shot", "")).begins_with("#"),
		"PHI-39: TANDEM still fires both declared barrels in order")
	lab.queue_free()
	_reset_tmp()


func _test_row_identity(tmp: String, idx: ResourceIndex, schema) -> void:
	print("\n-- PHI-41..44: shot identity and launch origin share one predicate --")
	var shooter := tmp.path_join("tank2.odf")
	var weapon := tmp.path_join("gun2.odf")
	var ord := tmp.path_join("bullet2.odf")
	var target := tmp.path_join("target2.odf")
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun2\"\r\nweaponHard1=\"hp_left\"\r\nweaponName2=\"gun2\"\r\nweaponHard2=\"hp_right\"\r\nmaxAmmo=500\r\nmaxEnergy=500\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	_write(weapon, "[WeaponClass]\r\nordName=\"bullet2\"\r\nshotDelay=0.05\r\n")
	_write(ord, "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\nshotRadius=0.5\r\nammoCost=1\r\nenergyCost=1\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	idx.scan(false)
	var lab = _mk_lab(tmp.path_join("phi41"), idx, schema, shooter, target)
	lab.barrel_mode = "TANDEM"
	lab._fire_volley(false, "TANDEM", true)
	var rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(str(rows[0].get("shot", "")).begins_with("#") and
		str(rows[0].get("shot_origin", "")).begins_with("("),
		"PHI-43: matching identity shows both Shot ID and launch origin")

	# Corrupt the stored hardpoint of one barrel's shot identity.
	var volley = lab.last_volley_result
	var bad: Dictionary = (volley.resolved_barrels[0] as Dictionary).duplicate(true)
	var ident: Dictionary = (bad.get("shot_identity", {}) as Dictionary).duplicate(true)
	ident["hardpoint"] = "hp_wrong"
	bad["shot_identity"] = ident
	volley.resolved_barrels[0] = bad
	rows = lab.build_hardpoint_inspector_rows()
	_check(not str(rows[0].get("shot", "")).begins_with("#"),
		"PHI-41: wrong hardpoint hides Shot ID")
	_check(str(rows[0].get("shot_origin", "")) == "unavailable",
		"PHI-42: wrong hardpoint also hides historical launch origin")
	_check(str(rows[0].get("origin", "")).begins_with("("),
		"PHI-44: current hardpoint origin stays independently visible")
	_check(str(rows[1].get("shot", "")).begins_with("#"),
		"PHI-43: the correctly-bound barrel still shows its own shot")

	# WAVE H: double-click navigation from a shot row to the Combat Timeline.
	var nav_id := int(rows[1].get("shot_id", 0))
	_check(nav_id > 0 and lab.focus_shot_on_timeline(nav_id) and
		int((lab.timeline_tree.get_selected() as TreeItem).get_metadata(0)) >= 0,
		"HP-NAV: Hardpoint Inspector shot row selects its Timeline event")
	_check(not lab.focus_shot_on_timeline(0),
		"HP-NAV: no shot ID performs no Timeline navigation")
	lab.queue_free()
	_reset_tmp()


func _test_alternate(tmp: String, idx: ResourceIndex, schema) -> void:
	print("\n-- ALT-01..06: alternate firing context --")
	var shooter := tmp.path_join("alt_tank.odf")
	var weapon := tmp.path_join("alt_gun.odf")
	var alt_weapon := tmp.path_join("alt_gun_b.odf")
	var ord := tmp.path_join("alt_bullet.odf")
	var target := tmp.path_join("alt_target.odf")
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"alt_gun\"\r\nweaponHard1=\"hp_left\"\r\nmaxAmmo=500\r\nmaxEnergy=500\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	_write(weapon, "[WeaponClass]\r\nordName=\"alt_bullet\"\r\naltName=\"alt_gun_b\"\r\nshotDelay=0.05\r\n")
	_write(alt_weapon, "[WeaponClass]\r\nordName=\"alt_bullet\"\r\naltName=\"alt_gun\"\r\nshotDelay=0.05\r\n")
	_write(ord, "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\nshotRadius=0.5\r\nammoCost=1\r\nenergyCost=1\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	idx.scan(false)
	var lab = _mk_lab(tmp.path_join("alt01"), idx, schema, shooter, target)
	_check(lab.profile.alt != null and
		str(lab.profile.alt.weapon_name) == "alt_gun_b",
		"ALT-01 setup: altName chain resolves")

	lab.barrel_mode = "SINGLE"
	lab._fire_volley(false, "SINGLE", true)
	var primary_rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(primary_rows.size() > 0 and str(primary_rows[0].get("shot", "")).begins_with("#") and
		str(primary_rows[0].get("firing_context", "PRIMARY")) == "PRIMARY" and
		str(primary_rows[0].get("shot_weapon", "")) == "alt_gun",
		"ALT-01: primary shot is marked PRIMARY with its own identity")

	lab.combat_scenario.shooter.reload_remaining = 0.0
	lab.fire_alt()
	var rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(_any_alt_shot(rows),
		"ALT-02/03: alternate shot is displayed as an ALTERNATE context")
	_check(str(lab.last_volley_result.weapon_identity) == "alt_gun_b" and
		str((lab.last_volley_result as Object).get("firing_context")) == "ALTERNATE",
		"ALT-05: last volley keeps alternate weapon identity, not primary")
	_check(not str(rows[0].get("shot", "")).begins_with("#alt_gun#"),
		"ALT-05: alternate shot is not relabelled as a primary shot")
	lab.queue_free()
	_reset_tmp()


func _any_alt_shot(rows: Array[Dictionary]) -> bool:
	for r in rows:
		if str(r.get("shot", "")).begins_with("ALT#") and \
				str(r.get("firing_context", "")) == "ALTERNATE":
			return true
	return false


func _reset_tmp() -> void:
	pass


func _initialize() -> void:
	print("T-221 Hardpoint physical-slot provenance verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t221_phi_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": tmp, "label": "t221", "kind": "test", "priority": 10, "enabled": true}])
	var schema := SchemaRegistryScript.new()
	_test_same_odf_two_slots(tmp, idx, schema)
	_test_row_identity(tmp, idx, schema)
	_test_alternate(tmp, idx, schema)
	for n in _fixture_nodes:
		if is_instance_valid(n):
			n.free()
	_remove_tree(tmp)
	print("\nT-221 Hardpoint Provenance: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
