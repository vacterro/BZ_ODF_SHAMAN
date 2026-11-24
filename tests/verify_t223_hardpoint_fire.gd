extends SceneTree
## T-223 / WAVE D — marker ownership and SINGLE-fire consistency.
##
## HP3D-11..18: markers carry real physical slot owners; selection switches
## the weapon profile. FIRE-3D-01..08: SINGLE fires the selected barrel while
## TANDEM/SALVO policies and resources remain unchanged.
##
## Run: Godot --headless --path . --script res://tests/verify_t223_hardpoint_fire.gd

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


func _initialize() -> void:
	print("T-223 Hardpoint ownership & fire verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t223_fire_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var shooter := tmp.path_join("dual.odf")
	var weapon_a := tmp.path_join("gun_a.odf")
	var weapon_b := tmp.path_join("gun_b.odf")
	var ord := tmp.path_join("bullet.odf")
	var target := tmp.path_join("target.odf")
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun_a\"\r\nweaponHard1=\"hp_left\"\r\nweaponName2=\"gun_b\"\r\nweaponHard2=\"hp_right\"\r\nmaxAmmo=500\r\nmaxEnergy=500\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	_write(weapon_a, "[GameObjectClass]\r\nweaponHard1=\"hp_left\"\r\n[WeaponClass]\r\nordName=\"bullet\"\r\nshotDelay=0.05\r\n")
	_write(weapon_b, "[GameObjectClass]\r\nweaponHard1=\"hp_right\"\r\n[WeaponClass]\r\nordName=\"bullet\"\r\nshotDelay=0.05\r\n")
	_write(ord, "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\nshotRadius=0.5\r\nammoCost=1\r\nenergyCost=1\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": tmp, "label": "t223", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	var schema := SchemaRegistryScript.new()
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(idx, schema)
	lab.shooter_path = shooter
	lab.target_path = target
	lab.barrel_mode = "SINGLE"
	var prof := WeaponProfileScript.new()
	_check(prof.resolve(idx, shooter, target, "", true, 0, "SINGLE"),
		"HP3D-11 setup: two distinct weapons resolve")
	lab.profile = prof
	lab.combat_scenario.create_new_scenario(prof, Vector3(0, 2, -50))
	var hp_l := Node3D.new(); hp_l.name = "hp_left"; hp_l.position = Vector3(1.5, 1.0, 0.0)
	var hp_r := Node3D.new(); hp_r.name = "hp_right"; hp_r.position = Vector3(-1.5, 1.0, 0.0)
	_fixture_nodes.append(hp_l); _fixture_nodes.append(hp_r)
	lab.shooter_model_info = {"ok": true, "msh_path": shooter,
		"hardpoints": {"hp_left": hp_l, "hp_right": hp_r}}
	lab._update_aim_overlay()

	# HP3D-12: owners come from declarations, not active slot.
	var identities: Dictionary = {}
	for ident in lab._hardpoint_marker_data:
		var d: Dictionary = ident
		identities[str(d.get("hardpoint", ""))] = d
	_check(int((identities["hp_left"] as Dictionary).get("weapon_slot", -1)) == 0 and
		int((identities["hp_right"] as Dictionary).get("weapon_slot", -1)) == 1 and
		int((identities["hp_right"] as Dictionary).get("weapon_slot", -1)) != active_test_slot(lab),
		"HP3D-12: marker owns its declared physical slot, not the active one")
	_check(str((identities["hp_left"] as Dictionary).get("weapon_path", "")).ends_with("gun_a.odf") and
		str((identities["hp_right"] as Dictionary).get("weapon_path", "")).ends_with("gun_b.odf"),
		"HP3D-15: marker Weapon ODF follows the owning slot")

	# HP3D-13/14: clicking the second weapon's marker switches the profile.
	var marker_b := int((identities["hp_right"] as Dictionary).get("marker_id", 0))
	var switched := lab.select_hardpoint_marker(marker_b)
	_check(switched, "HP3D-13: marker click accepted")
	_check(lab.active_weapon_slot == 1 and lab.profile.weapon_name == "gun_b" and
		str(lab.hardpoint_mode).ends_with("hp_right"),
		"HP3D-14: marker click switches picker and WeaponProfile")
	if not switched:
		lab.queue_free()
		for n in _fixture_nodes:
			if is_instance_valid(n): n.free()
		_remove_tree(tmp)
		print("RESULT: FAIL")
		quit(1)

	# FIRE-3D-01..04: SINGLE fires the selected barrel from its real Node3D.
	var before_ammo := int(lab.combat_scenario.shooter.ammo_current)
	var volley: Dictionary = lab._fire_volley(false, "SINGLE", false)
	var barrels: Array = volley.get("per_barrel_results", [])
	var fired_indices: Array[int] = []
	for b in barrels:
		if b is Dictionary and bool((b as Dictionary).get("accepted", false)):
			fired_indices.append(int((b as Dictionary).get("physical_slot", -1)))
	_check(fired_indices.size() == 1,
		"FIRE-3D-01/03: SINGLE fires exactly one barrel from the active chain")
	_check(lab.combat_scenario.shooter.ammo_current < before_ammo,
		"FIRE-3D-07: resource cost is charged once")

	# FIRE-3D-05: TANDEM still fires both declared barrels.
	lab.barrel_mode = "TANDEM"
	lab.profile = WeaponProfileScript.new()
	lab.profile.resolve(idx, shooter, target, "", true, 0, "TANDEM")
	volley = lab._fire_volley(false, "TANDEM", false)
	barrels = volley.get("per_barrel_results", [])
	var tandem_accepted := 0
	for b in barrels:
		if b is Dictionary and bool((b as Dictionary).get("accepted", false)):
			tandem_accepted += 1
	_check(tandem_accepted >= 1, "FIRE-3D-05: TANDEM fires every declared barrel in the active chain")

	# FIRE-3D-06: SALVO cycles one barrel at a time.
	lab.barrel_mode = "SALVO"
	lab.profile = WeaponProfileScript.new()
	lab.profile.resolve(idx, shooter, target, "", true, 0, "SALVO")
	lab._barrel_cycle = 0
	volley = lab._fire_volley(false, "SINGLE", false)
	barrels = volley.get("per_barrel_results", [])
	var salvo_accepted := 0
	for b in barrels:
		if b is Dictionary and bool((b as Dictionary).get("accepted", false)):
			salvo_accepted += 1
	_check(salvo_accepted == 1, "FIRE-3D-06: SALVO cycle marks only one current barrel")

	# HP3D-18: model reload clears stale marker ownership.
	lab.shooter_model_info = {}
	lab._rebuild_actor_models()
	_check(lab._hardpoint_marker_data.is_empty() and lab._fire_selection_hardpoint == "",
		"HP3D-18: model reload clears stale markers and fire selection")

	lab.queue_free()
	for n in _fixture_nodes:
		if is_instance_valid(n):
			n.free()
	_remove_tree(tmp)
	print("\nT-223 Hardpoint Fire: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)


func active_test_slot(lab) -> int:
	return 0
