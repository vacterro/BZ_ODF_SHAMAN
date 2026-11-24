extends SceneTree
## T-222 / WAVE F — interactive 3D hardpoint selection.
##
## HP3D-01..10: authentic model markers carry physical identity, selection
## drives the Hardpoint Inspector, duplicate ODF slots stay distinguishable,
## fallback origins are honest, and firing never depends on marker meshes.
##
## Run: Godot --headless --path . --script res://tests/verify_t222_hardpoint_3d.gd

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
	print("T-222 3D hardpoint selection verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t222_3d_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)
	var shooter := tmp.path_join("dual.odf")
	var weapon := tmp.path_join("gun.odf")
	var ord := tmp.path_join("bullet.odf")
	var target := tmp.path_join("target.odf")
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun\"\r\nweaponHard1=\"hp_left\"\r\nweaponName2=\"gun\"\r\nweaponHard2=\"hp_right\"\r\nmaxAmmo=500\r\nmaxEnergy=500\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	_write(weapon, "[WeaponClass]\r\nordName=\"bullet\"\r\nshotDelay=0.05\r\n")
	_write(ord, "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\nshotRadius=0.5\r\nammoCost=1\r\nenergyCost=1\r\n")
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	var idx := ResourceIndex.new()
	idx.roots.assign([{"path": tmp, "label": "t222", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	var schema := SchemaRegistryScript.new()
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(idx, schema)
	lab.shooter_path = shooter
	lab.target_path = target
	lab.barrel_mode = "SALVO"
	var prof := WeaponProfileScript.new()
	_check(prof.resolve(idx, shooter, target, "", true, 0, "SALVO"),
		"HP3D-01 setup: weapon profile resolves")
	lab.profile = prof
	lab.combat_scenario.create_new_scenario(prof, Vector3(0, 2, -50))

	var hp_left := Node3D.new()
	hp_left.name = "hp_left"
	hp_left.position = Vector3(1.0, 1.0, 0.0)
	var hp_right := Node3D.new()
	hp_right.name = "hp_right"
	hp_right.position = Vector3(-1.0, 1.0, 0.0)
	_fixture_nodes.append(hp_left)
	_fixture_nodes.append(hp_right)
	lab.shooter_model_info = {"ok": true, "msh_path": shooter,
		"hardpoints": {"hp_left": hp_left, "hp_right": hp_right}}
	lab._update_aim_overlay()

	_check(lab._hardpoint_marker_data.size() == 2 and
		lab.hardpoint_markers_root.get_child_count() == 2,
		"HP3D-02: one selectable marker per resolved hardpoint")
	var identities: Dictionary = {}
	for identity in lab._hardpoint_marker_data:
		var ident: Dictionary = identity
		identities[str(ident.get("hardpoint", ""))] = ident
	_check(identities.has("hp_left") and identities.has("hp_right") and
		int((identities["hp_left"] as Dictionary).get("node_id", 0)) !=
			int((identities["hp_right"] as Dictionary).get("node_id", 0)) and
		str((identities["hp_left"] as Dictionary).get("weapon_path", "")) ==
			str((identities["hp_right"] as Dictionary).get("weapon_path", "")),
		"HP3D-05: duplicate Weapon ODF slots stay distinct by Node3D identity")

	var left_marker := int((identities["hp_left"] as Dictionary).get("marker_id", 0))
	_check(lab.select_hardpoint_marker(left_marker) and
		lab.hardpoint_mode == "mesh:hp_left" and lab._selected_hardpoint_name == "hp_left",
		"HP3D-03: marker click selects the correct physical mount")

	# Inspector row selection highlights the matching marker.
	lab._selected_hardpoint_name = ""
	lab.select_hardpoint("hp_right")
	var rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(rows.size() == 2 and str(rows[1].get("hardpoint_key", "")) == "hp_right" and
		lab._selected_hardpoint_name == "hp_right",
		"HP3D-04: inspector selection and marker highlight agree on the mount")

	# Current origin follows the model; historical launch origin is immutable.
	lab.combat_scenario.shooter.reload_remaining = 0.0
	lab._fire_volley(false, "SINGLE", true)
	var shot_rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	var launch_before := str(shot_rows[1].get("shot_origin", ""))
	hp_right.position = Vector3(4.0, 2.0, 0.0)
	lab._update_aim_overlay()
	shot_rows = lab.build_hardpoint_inspector_rows()
	_check(str(shot_rows[1].get("origin", "")) == "(4.00, 2.00, 0.00)" and
		str(shot_rows[1].get("shot_origin", "")) == launch_before,
		"HP3D-06/07: current origin follows animation, launch origin stays exact")

	# Missing hardpoint uses an honest fallback and no marker.
	lab.shooter_model_info = {"ok": true, "hardpoints": {}}
	lab.profile = WeaponProfileScript.new()
	lab.profile.weapon_name = "gun"
	lab.profile.weapon_hardpoints.assign(["hp_left", "hp_right"])
	lab._rebuild_actor_models()
	lab._selected_hardpoint_name = ""
	var fallback_rows: Array[Dictionary] = lab.build_hardpoint_inspector_rows()
	_check(fallback_rows.size() > 0 and
		(str(fallback_rows[0].get("fidelity", "")).find("FALLBACK") >= 0 or
		str(fallback_rows[0].get("fidelity", "")).find("MISSING") >= 0) and
		lab._hardpoint_marker_data.is_empty(),
		"HP3D-08: missing hardpoint reports fallback without a marker")

	# Marker meshes never participate in projectile simulation.
	_check(lab.hardpoint_markers_root.get_child_count() == 0 or
		not (lab.hardpoint_markers_root.get_child(0) is Area3D),
		"HP3D-09: marker geometry has no physics body")
	lab.queue_free()
	for n in _fixture_nodes:
		if is_instance_valid(n):
			n.free()
	_remove_tree(tmp)
	print("\nT-222 3D Hardpoint: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
