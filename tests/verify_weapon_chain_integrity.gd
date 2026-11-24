extends SceneTree
## WCH-01..10: an unresolved conventional weapon is not a direct-firing weapon.

const WeaponProfileScript = preload("res://scripts/sim/weapon_profile.gd")
const WeaponLabScript = preload("res://scripts/lab/weapon_lab.gd")
const ResourceIndexScript = preload("res://scripts/core/resource_index.gd")
const SchemaRegistryScript = preload("res://scripts/core/schema_registry.gd")

var passed := 0
var failed := 0
var tmp := ""


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


func _fixture(stem: String, weapon_text: String, ordnance: bool = true) -> Dictionary:
	var base := tmp.path_join(stem)
	var shooter := base.path_join("shooter.odf")
	var weapon := base.path_join("gun.odf")
	var target := base.path_join("target.odf")
	_write(shooter, "[GameObjectClass]\r\nweaponName1=\"gun\"\r\nweaponHard1=\"hp_gun\"\r\nmaxAmmo=100\r\nmaxEnergy=100\r\n")
	_write(weapon, weapon_text)
	OdfDocument.clear_all_cache()
	_write(target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	if ordnance:
		_write(base.path_join("bullet.odf"), "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\n")
	var idx := ResourceIndexScript.new()
	idx.roots.assign([{"path": tmp, "label": "wch", "kind": "test", "priority": 10, "enabled": true}])
	idx.scan(false)
	OdfDocument.clear_all_cache()
	return {"index": idx, "shooter": shooter, "target": target, "weapon": weapon}


func _slot(ctx: Dictionary) -> Dictionary:
	var profile: WeaponProfile = WeaponProfileScript.new()
	profile.resolve(ctx["index"], ctx["shooter"], ctx["target"], "", false)
	return profile.slot_source(0)


func _test_invalid_cannot_fire(ctx: Dictionary) -> void:
	var lab = WeaponLabScript.new()
	root.add_child(lab)
	lab.setup(ctx["index"], SchemaRegistryScript.new())
	lab.shooter_path = str(ctx["shooter"])
	lab.target_path = str(ctx["target"])
	lab.profile = WeaponProfileScript.new()
	lab.profile.resolve(ctx["index"], ctx["shooter"], ctx["target"], "", false)
	lab.fire_once()
	_check(lab.last_volley_result == null and lab.combat_scenario.shot_history.is_empty(),
		"WCH-07 invalid weapon chain cannot fire fabricated ordnance")
	lab.queue_free()


func _initialize() -> void:
	print("Weapon chain integrity verifier (WCH-01..10)")
	tmp = ProjectSettings.globalize_path("user://verify_wch_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)

	var missing := _fixture("missing", "[WeaponClass]\r\nclassLabel=\"Weapon\"\r\nshotDelay=0.05\r\n")
	var missing_profile: WeaponProfile = WeaponProfileScript.new()
	_check(not missing_profile.resolve(missing["index"], missing["shooter"], missing["target"], "", false),
		"WCH-01 missing ordName rejects the weapon chain")
	_check(not missing_profile.errors.is_empty() and missing_profile.errors[0].contains("no ordName"),
		"WCH-01 missing ordName reports an explicit error")
	_check(missing_profile.ordnance_path == "" and not missing_profile.is_beam_weapon,
		"WCH-03 missing ordName does not fabricate DIRECT_WEAPON")
	_check(not missing_profile.resolve(missing["index"], missing["shooter"], missing["target"], "", false) and
		str(missing_profile.slot_source(0).get("ordnance_status", "")) == "ORDNANCE_UNRESOLVED" and
		str(missing_profile.slot_source(0).get("ordnance_path", "")) == "",
		"WCH-04 per-slot and active profile agree on unresolved ordnance")

	var null_case := _fixture("null", "[WeaponClass]\r\nclassLabel=\"Weapon\"\r\nordName=NULL\r\nshotDelay=0.05\r\n")
	var null_profile: WeaponProfile = WeaponProfileScript.new()
	_check(not null_profile.resolve(null_case["index"], null_case["shooter"], null_case["target"], "", false),
		"WCH-02 ordName=NULL rejects an ordinary weapon")
	_check(not null_profile.resolve(null_case["index"], null_case["shooter"], null_case["target"], "", false) and
		str(null_profile.slot_source(0).get("ordnance_status", "")) == "ORDNANCE_UNRESOLVED",
		"WCH-04 per-slot NULL ordnance agrees with active profile")

	var arc := _fixture("arc", "[ArcCannonClass]\r\nordName=NULL\r\nfinishDist=300\r\n")
	var arc_profile: WeaponProfile = WeaponProfileScript.new()
	_check(arc_profile.resolve(arc["index"], arc["shooter"], arc["target"], "", false),
		"WCH-05 authentic ArcCannonClass with NULL ordName resolves")
	_check(arc_profile.is_beam_weapon and arc_profile.ordnance_path == arc["weapon"] and
		str(_slot(arc).get("ordnance_status", "")) == "DIRECT_WEAPON",
		"WCH-05 direct Arc source and per-slot status agree")

	var arc_header := _fixture("arc_header", "[ArcCannonClass]\r\nordName=NULL\r\nfinishDist=250\r\n")
	var arc_header_profile: WeaponProfile = WeaponProfileScript.new()
	_check(arc_header_profile.resolve(arc_header["index"], arc_header["shooter"], arc_header["target"], "", false),
		"WCH-05 ArcCannonClass header remains a direct-weapon control")

	var beam := _fixture("beam", "[WeaponClass]\r\nclassLabel=\"Beam\"\r\nordName=NULL\r\nfinishDist=400\r\nflashName=\"beam_flash\"\r\n")
	var beam_profile: WeaponProfile = WeaponProfileScript.new()
	_check(beam_profile.resolve(beam["index"], beam["shooter"], beam["target"], "", false) and
		beam_profile.is_beam_weapon,
		"WCH-06 documented Beam direct semantics remain valid")
	_check(beam_profile.shot_speed >= 5000.0 and beam_profile.life_span < 0.001 and
		beam_profile.is_beam_weapon and beam_profile.is_beam_render and
		beam_profile.weapon_path.ends_with("gun.odf"),
		"WCH-10 direct Beam keeps hitscan speed and direct source identity")

	var valid_base := tmp.path_join("valid")
	var valid_shooter := valid_base.path_join("shooter.odf")
	var valid_weapon := valid_base.path_join("gun.odf")
	var valid_target := valid_base.path_join("target.odf")
	_write(valid_shooter, "[GameObjectClass]\r\nweaponName1=\"gun\"\r\nweaponHard1=\"hp_gun\"\r\nmaxAmmo=100\r\nmaxEnergy=100\r\n")
	_write(valid_weapon, "[WeaponClass]\r\nclassLabel=\"Weapon\"\r\nordName=\"bullet\"\r\nshotDelay=0.05\r\n")
	_write(valid_base.path_join("bullet.odf"), "[OrdnanceClass]\r\nshotSpeed=120\r\nlifeSpan=2\r\ndamageValue(H)=10\r\n")
	_write(valid_target, "[GameObjectClass]\r\nmaxHealth=1000\r\narmorClass=\"H\"\r\n")
	var valid_idx := ResourceIndexScript.new()
	valid_idx.roots.assign([{"path": valid_base, "label": "wch", "kind": "test", "priority": 10, "enabled": true}])
	valid_idx.scan(false)
	OdfDocument.clear_all_cache()
	var valid_profile: WeaponProfile = WeaponProfileScript.new()
	_check(valid_profile.resolve(valid_idx, valid_shooter, valid_target, "", false) and
		valid_profile.ordnance_path.ends_with("bullet.odf") and
		str(valid_profile.slot_source(0).get("ordnance_status", "")) == "RESOLVED",
		"WCH-08 conventional Weapon to Ordnance chain still resolves")

	var bad_alt := _fixture("bad_alt", "[WeaponClass]\r\nordName=\"bullet\"\r\naltName=\"gun_alt\"\r\n")
	_write(bad_alt["weapon"].get_base_dir().path_join("gun_alt.odf"), "[WeaponClass]\r\nclassLabel=\"Weapon\"\r\nordName=NULL\r\n")
	bad_alt["index"].scan(false)
	var alt_profile: WeaponProfile = WeaponProfileScript.new()
	_check(alt_profile.resolve(bad_alt["index"], bad_alt["shooter"], bad_alt["target"], "", true) and
		alt_profile.alt == null,
		"WCH-09 invalid alternate ordnance does not silently become valid")

	_test_invalid_cannot_fire(missing)

	_remove_tree(tmp)
	print("\nWeapon Chain Integrity: %d checks, %d failure(s)" % [passed + failed, failed])
	print("RESULT: " + ("PASS" if failed == 0 else "FAIL"))
	quit(0 if failed == 0 else 1)
