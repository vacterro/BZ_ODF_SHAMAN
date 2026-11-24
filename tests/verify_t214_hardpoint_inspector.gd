extends SceneTree
## T-214 — Physical Hardpoint Inspector provenance verifier.
##
## Covers PHI-07..27 of the 2026-11-23 night-shift handoff:
##   * a Shot ID is bound to the weapon and physical barrel that fired it,
##   * ammo/energy come from the live CombatScenario shooter, never from
##     nonexistent ShotIdentity fields,
##   * the current hardpoint origin and the historical launch origin are shown
##     separately and never reconstructed from the animated transform.
##
## Run: Godot --headless --path . --script res://tests/verify_t214_hardpoint_inspector.gd

const WeaponProfileScript = preload("res://scripts/sim/weapon_profile.gd")
const WeaponLabScript = preload("res://scripts/lab/weapon_lab.gd")
const SchemaRegistryScript = preload("res://scripts/core/schema_registry.gd")

var passed := 0
var failed := 0


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
	if dir != null:
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


func _initialize() -> void:
	print("T-214 Hardpoint Inspector provenance verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t214_phi_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var shooter := tmp.path_join("tank.odf")
	var weapon_a := tmp.path_join("gun.odf")
	var weapon_b := tmp.path_join("gunB.odf")
	var ord := tmp.path_join("bullet.odf")
	var target := tmp.path_join("target.odf")
	# Two physical barrels belong to the same weapon name (TANDEM mount).
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun\"\r\nweaponHard1=\"hp_left\"\r\nweaponName2=\"gun\"\r\nweaponHard2=\"hp_right\"\r\nmaxAmmo=500\r\nmaxEnergy=250\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	_write(weapon_a, "[WeaponClass]\r\nordName=\"bullet\"\r\nshotDelay=0.05\r\n")
	_write(weapon_b, "[WeaponClass]\r\nordName=\"bullet\"\r\nshotDelay=0.05\r\n")
	_write(ord, "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=60\r\nshotRadius=0.5\r\nammoCost=5\r\nenergyCost=10\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")

	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": tmp, "label": "t214", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	var schema := SchemaRegistryScript.new()
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(idx, schema)
	lab.shooter_path = shooter
	lab.target_path = target
	lab.barrel_mode = "TANDEM"
	var prof := WeaponProfileScript.new()
	_check(prof.resolve(idx, shooter, target, "", true, 0, "TANDEM"), "T-214 setup: weapon profile resolves")
	lab.profile = prof
	lab.combat_scenario.create_new_scenario(prof, Vector3(0, 2, -50))

	var hp_left := Node3D.new()
	hp_left.name = "hp_left"
	hp_left.position = Vector3(1.0, 1.0, 0.0)
	var hp_right := Node3D.new()
	hp_right.name = "hp_right"
	hp_right.position = Vector3(-1.0, 1.0, 0.0)
	lab.shooter_model_info = {"ok": true, "hardpoints": {"hp_left": hp_left, "hp_right": hp_right}}

	# ---- PHI-14: TANDEM keeps every physical barrel on its own hardpoint.
	lab._fire_volley(false, "TANDEM", true)
	var rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(rows.size() == 2 and str(rows[0].get("hardpoint", "")) == "hp_left" and
		str(rows[1].get("hardpoint", "")) == "hp_right",
		"PHI-07/14: TANDEM lists both physical barrels in declared order")
	_check(str(rows[0].get("shot", "")).begins_with("#") and str(rows[0].get("shot", "")).contains("hp_left") and
		str(rows[1].get("shot", "")).contains("hp_right"),
		"PHI-08/14: each row shows the Shot ID of its own barrel")

	# ---- PHI-15..21: resources are the shooter's authoritative current state.
	var sh = lab.combat_scenario.shooter
	var expect_ammo := "%d/%d" % [int(sh.ammo_current), int(sh.ammo_max)]
	var expect_energy := "%.0f/%.0f" % [float(sh.energy_current), float(sh.energy_max)]
	_check(str(rows[0].get("ammo", "")) == expect_ammo, "PHI-15: ammo column equals CombatScenario.shooter ammo")
	_check(str(rows[0].get("energy", "")) == expect_energy, "PHI-16: energy column equals CombatScenario.shooter energy")
	_check(int(sh.ammo_current) < 500, "PHI-21 setup: the volley actually spent ammo")
	var ammo_after_first := int(sh.ammo_current)
	var energy_after_first := float(sh.energy_current)
	lab._fire_volley(false, "TANDEM", false)
	rows = lab.build_hardpoint_inspector_rows()
	_check(int(sh.ammo_current) < ammo_after_first and
		str(rows[0].get("ammo", "")) == "%d/%d" % [int(sh.ammo_current), int(sh.ammo_max)],
		"PHI-21: displayed ammo tracks the shooter after firing")
	_check(float(sh.energy_current) < energy_after_first and
		str(rows[0].get("energy", "")) == "%.0f/%.0f" % [float(sh.energy_current), float(sh.energy_max)],
		"PHI-20/21: TANDEM energy totals and display stay accurate")
	sh.ammo_unlimited = true
	sh.energy_unlimited = true
	rows = lab.build_hardpoint_inspector_rows()
	_check(str(rows[0].get("ammo", "")) == "∞" and str(rows[0].get("energy", "")) == "∞",
		"PHI-17/18: unlimited ammo and energy render as ∞")
	sh.ammo_unlimited = false
	sh.energy_unlimited = false

	# ---- PHI-22..25: current transform and launch origin are different facts.
	lab._fire_volley(false, "TANDEM", false)
	rows = lab.build_hardpoint_inspector_rows()
	var launch_a := str(rows[0].get("shot_origin", ""))
	_check(launch_a.begins_with("("), "PHI-22/25: launch origin captured at fire time")
	hp_left.position = Vector3(5.0, 3.0, 0.0)
	rows = lab.build_hardpoint_inspector_rows()
	_check(str(rows[0].get("origin", "")) == "(5.00, 3.00, 0.00)",
		"PHI-24: current hardpoint origin follows the model transform")
	_check(str(rows[0].get("shot_origin", "")) == launch_a,
		"PHI-25: historical launch origin stays at the fired position")

	# ---- PHI-14 (SALVO): only the selected physical barrel gets a shot.
	lab.barrel_mode = "SALVO"
	lab._barrel_cycle = 1
	lab._fire_volley(false, "SINGLE", false)
	rows = lab.build_hardpoint_inspector_rows()
	_check(str(rows[0].get("shot", "")) == "not fired" and str(rows[1].get("shot", "")).begins_with("#"),
		"PHI-14: SALVO binds the shot to the selected barrel only")

	# ---- PHI-07..13: a different weapon must never inherit the old shot.
	var stale = WeaponProfileScript.new()
	stale.weapon_name = "gunB"
	stale.weapon_path = weapon_b
	stale.ordnance_name = "bullet"
	stale.weapon_hardpoints.assign(["hp_left", "hp_right"])
	lab.profile = stale
	rows = lab.build_hardpoint_inspector_rows()
	var any_old_shot := false
	for r in rows:
		if str(r.get("shot", "")).begins_with("#"):
			any_old_shot = true
	_check(not any_old_shot, "PHI-09: weapon B never inherits weapon A's Shot ID")
	_check(str(rows[0].get("shot", "")) == "LAST_SHOT_NOT_FOR_CURRENT_WEAPON",
		"PHI-09: inspector states the last shot belongs to another weapon")
	_check(str(rows[0].get("shot_origin", "")) == "unavailable",
		"PHI-27: another weapon's launch origin is not shown either")

	lab.profile = prof
	rows = lab.build_hardpoint_inspector_rows()
	_check(str(rows[1].get("shot", "")).begins_with("#"),
		"PHI-10/11: switching back restores the historical shot with its own provenance")

	# ---- PHI-12: the real override path also rebinds instead of relabelling.
	var overridden: bool = lab.set_weapon_override("gunB")
	_check(overridden, "PHI-12 setup: live weapon override resolves")
	rows = lab.build_hardpoint_inspector_rows()
	var override_leak := false
	for r in rows:
		if str(r.get("shot", "")).begins_with("#"):
			override_leak = true
	_check(overridden and not override_leak,
		"PHI-12: live weapon override clears stale inspector shot data")

	# ---- PHI-19: a rejected shot never fabricates resources or identity.
	var lab2 = WeaponLabScript.new()
	root.add_child(lab2)
	lab2.setup(idx, schema)
	lab2.shooter_path = shooter
	lab2.target_path = target
	lab2.barrel_mode = "TANDEM"
	var prof2 := WeaponProfileScript.new()
	prof2.resolve(idx, shooter, target, "", true, 0, "TANDEM")
	lab2.profile = prof2
	lab2.combat_scenario.create_new_scenario(prof2, Vector3(0, 2, -50))
	lab2.shooter_model_info = {"ok": true, "hardpoints": {"hp_left": hp_left, "hp_right": hp_right}}
	var sh2 = lab2.combat_scenario.shooter
	sh2.reload_remaining = 5.0
	lab2._fire_volley(false, "SINGLE", true)
	var rows2: Array[Dictionary] = lab2.build_hardpoint_inspector_rows()
	var fabricated := false
	for r in rows2:
		if str(r.get("shot", "")).begins_with("#"):
			fabricated = true
	_check(not fabricated and str(rows2[0].get("ammo", "")) == "%d/%d" % [int(sh2.ammo_current), int(sh2.ammo_max)],
		"PHI-19: rejected shot shows no shot identity and no spent resources")

	# ---- PHI-13: no volley means no invented identity.
	lab2.last_volley_result = null
	rows2 = lab2.build_hardpoint_inspector_rows()
	var invented := false
	for r in rows2:
		if str(r.get("shot", "")) != "not fired":
			invented = true
	_check(not invented, "PHI-13: reset state reports not fired, never a new Shot ID")

	lab.shooter_model_info = {}
	lab2.shooter_model_info = {}
	lab.queue_free()
	lab2.queue_free()
	hp_left.free()
	hp_right.free()
	_remove_tree(tmp)
	print("\nT-214 Hardpoint Inspector: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
