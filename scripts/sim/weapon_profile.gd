class_name WeaponProfile
extends RefCounted
## Resolves a real shooter ODF -> weapon ODF -> ordnance ODF chain and reads
## the values the preview simulation uses. Every value is traceable to a file.

var index: ResourceIndex
var shooter_doc: OdfDocument
var weapon_doc: OdfDocument
var ordnance_doc: OdfDocument
var target_doc: OdfDocument

var shooter_path: String = ""
var weapon_path: String = ""
var ordnance_path: String = ""
var target_path: String = ""

var weapon_name: String = ""
var weapon_hardpoint: String = ""
var ordnance_name: String = ""
var shooter_geometry: String = ""
var shooter_geometry_scale: float = 1.0
var target_geometry: String = ""
var target_geometry_scale: float = 1.0
## Alternate WeaponClass resolved from the weapon's altName (morph/deploy
## switch). Null when the chain declares none or it does not resolve.
var alt: WeaponProfile = null
var weapon_header: String = ""
var ordnance_header: String = "OrdnanceClass"

var errors: Array[String] = []
var notes: Array[String] = []

# Values are re-read on refresh() so inspector edits take effect immediately.
var shot_speed: float = 0.0
var life_span: float = 1.0
var shot_radius: float = 0.0
var is_arcing: bool = false
var fire_sound: String = ""
var shot_sound: String = ""
var muzzle_render: String = ""
var expl_sound: String = ""
var shot_delay: float = 1.0
var salvo_count: int = 1
var salvo_delay: float = 0.0
var shot_variance: float = 0.0
var kick_veloc: float = 0.0
var omega_turn: float = 0.0
var is_homing: bool = false
var is_beam_weapon: bool = false
var is_beam_render: bool = false
var weapon_class_label: String = ""
var ordnance_class_label: String = ""
var recoil_node_name: String = ""
var weapon_hardpoints: Array[String] = []
var ammo_cost: int = 0
var weapon_energy_cost: float = 0.0
var damage_shield: float = 1.0
var damage: Dictionary = {}
var damage_radius: float = 0.0
var xpl_ground: String = ""
var xpl_vehicle: String = ""
var xpl_expire: String = ""
var render_name: String = ""
var shot_geometry: String = ""

# Shooter-owned combat resource properties (P1-SIM-01, P1-SIM-03)
var shooter_ammo_max: int = 0
var shooter_energy_max: float = 0.0
var shooter_health_max: float = 1000.0
var shooter_armor: String = "H"

# Target values
var target_health_max: float = 0.0
var target_shield_max: float = 0.0
var target_shield_class: String = ""
var target_ammo_max: int = 0
var target_armor: String = "N"
var target_radius: float = 2.0
var target_half_extents: Vector3 = Vector3.ZERO
var target_bbox_offset: Vector3 = Vector3.ZERO
var target_yaw_rad: float = 0.0
var target_name: String = ""
var target_health_documented: bool = false

## In-memory value overrides used by the parameter sweep (and nothing else).
## Keys are normalised "property|suffix" ids; no file is ever written.
var overrides: Dictionary = {}

## True when reconstructed from an immutable CombatReplaySnapshot so refresh()
## preserves captured historical ODF values even after live ODF edits (P1-SIM-03).
var is_frozen_snapshot: bool = false
var captured_odf_revisions: Dictionary = {}


func resolve(p_index: ResourceIndex, p_shooter_path: String, p_target_path: String,
		p_weapon_override: String = "", p_resolve_alt: bool = true) -> bool:
	index = p_index
	errors.clear()
	notes.clear()
	alt = null
	shooter_path = p_shooter_path
	target_path = p_target_path
	shooter_doc = OdfDocument.load_cached(shooter_path)
	target_doc = OdfDocument.load_cached(target_path) if target_path != "" else null
	if shooter_doc == null:
		errors.append("Shooter ODF could not be loaded: " + shooter_path)
		return false
	_read_target()
	if not _resolve_weapon_chain(p_weapon_override):
		return false
	refresh()
	var shooter_chain := OdfInheritance.describe_chain(shooter_doc, index)
	if shooter_chain.contains("->"):
		notes.append("Shooter inheritance: " + shooter_chain)
	if weapon_doc != null:
		var wchain := OdfInheritance.describe_chain(weapon_doc, index)
		if wchain.contains("->"):
			notes.append("Weapon inheritance: " + wchain)
	if ordnance_doc != null:
		var ochain := OdfInheritance.describe_chain(ordnance_doc, index)
		if ochain.contains("->"):
			notes.append("Ordnance inheritance: " + ochain)
	if target_doc != null:
		var tchain := OdfInheritance.describe_chain(target_doc, index)
		if tchain.contains("->"):
			notes.append("Target inheritance: " + tchain)
	if p_resolve_alt:
		_resolve_alt()
	return true


func _resolve_weapon_chain(weapon_override: String = "") -> bool:
	weapon_name = ""
	weapon_hardpoint = ""
	weapon_path = ""
	weapon_doc = null
	var hards: Dictionary = {}
	for e in shooter_doc.effective_entries():
		var k: String = str(e.key_raw).to_lower()
		if k.begins_with("weaponhard"):
			hards[k.trim_prefix("weaponhard")] = e.core_value()
	if weapon_override != "":
		var override_hit := index.resolve_path_from(weapon_override, shooter_path)
		if override_hit == "":
			errors.append("Weapon override not found in indexed roots: " + weapon_override)
			return false
		weapon_name = weapon_override
		weapon_path = override_hit
		for e in shooter_doc.effective_entries():
			var k: String = str(e.key_raw).to_lower()
			if k.begins_with("weaponname") and str(e.core_value()).to_lower() == weapon_override.to_lower():
				weapon_hardpoint = str(hards.get(k.trim_prefix("weaponname"), ""))
				break
	else:
		# weaponName1..N live under GameObjectClass (variants may put them elsewhere).
		for e in shooter_doc.effective_entries():
			var k: String = str(e.key_raw).to_lower()
			if k.begins_with("weaponname"):
				var candidate: String = e.core_value()
				if candidate != "":
					var hit := index.resolve_path_from(candidate, shooter_path)
					if hit != "":
						weapon_name = candidate
						weapon_path = hit
						weapon_hardpoint = str(hards.get(k.trim_prefix("weaponname"), ""))
						break
	if weapon_hardpoint == "":
		var chain := OdfInheritance.chain(shooter_doc, index)
		for idx_c in range(1, chain.size()):
			var parent_doc: OdfDocument = chain[idx_c]
			for pe in parent_doc.effective_entries():
				var pk: String = str(pe.key_raw).to_lower()
				if pk.begins_with("weaponhard"):
					var slot: String = pk.trim_prefix("weaponhard")
					if slot == "1" or parent_doc.get_value("GameObjectClass", "weaponName" + slot, "").to_lower() == weapon_name.to_lower():
						weapon_hardpoint = pe.core_value()
						break
			if weapon_hardpoint != "":
				break
	if weapon_name == "":
		errors.append("Shooter ODF declares no resolvable weaponNameN.")
		return false
	weapon_doc = OdfDocument.load_cached(weapon_path)
	if weapon_doc == null:
		errors.append("Weapon ODF could not be loaded: " + weapon_path)
		return false
	# Collect matching weaponHardN / recoilNameN for multi-hardpoint weapons (e.g. Titan dual garc_c).
	weapon_hardpoints.clear()
	recoil_node_name = ""
	var recoils := {}
	for e in shooter_doc.effective_entries():
		var k := str(e.key_raw).to_lower()
		if k.begins_with("recoilname"):
			recoils[k.trim_prefix("recoilname")] = e.core_value()
	for e in shooter_doc.effective_entries():
		var k := str(e.key_raw).to_lower()
		if k.begins_with("weaponname") and str(e.core_value()).to_lower() == weapon_name.to_lower():
			var slot := k.trim_prefix("weaponname")
			var hp := str(hards.get(slot, ""))
			if hp != "" and not weapon_hardpoints.has(hp):
				weapon_hardpoints.append(hp)
			if recoil_node_name == "" and recoils.has(slot):
				recoil_node_name = str(recoils[slot])
	if weapon_hardpoints.is_empty() and weapon_hardpoint != "":
		weapon_hardpoints.append(weapon_hardpoint)

	ordnance_name = ""
	ordnance_path = ""
	is_beam_weapon = false
	weapon_class_label = _find_value(weapon_doc, ["classLabel"]).strip_edges().to_lower()
	for e in weapon_doc.effective_entries():
		if e.key_raw.to_lower() == "ordname":
			ordnance_name = e.core_value()
			break
	if ordnance_name == "" or ordnance_name.to_lower() == "null":
		# Support direct beam / ArcCannonClass weapons (e.g. Titan garc_a.odf with ordName = NULL).
		var has_direct_arc := weapon_doc.has_header("ArcCannonClass") or weapon_class_label == "arccannon" or weapon_class_label == "beam" or _find_value(weapon_doc, ["finishDist"]) != ""
		if has_direct_arc:
			is_beam_weapon = true
			ordnance_name = weapon_name + " (arc)"
			ordnance_path = weapon_path
			ordnance_doc = weapon_doc
			notes.append("Direct Arc/Beam weapon (%s, ordName=NULL): firing via [ArcCannonClass]." % weapon_name)
			return true
		errors.append("Weapon %s has no ordName." % weapon_name)
		return false
	ordnance_path = index.resolve_path_from(ordnance_name, weapon_path)
	if ordnance_path == "":
		errors.append("Ordnance ODF not found in indexed roots: " + ordnance_name)
		return false
	ordnance_doc = OdfDocument.load_cached(ordnance_path)
	if ordnance_doc == null:
		errors.append("Ordnance ODF could not be loaded: " + ordnance_path)
		return false
	return true


## altName names another WeaponClass used after a morph/deploy switch. The
## alternate profile is resolved with its own override and does not resolve
## altName recursively (stock pairs point at each other: c <-> a).
func _resolve_alt() -> void:
	alt = null
	if weapon_doc == null:
		return
	var name := _find_value(weapon_doc, ["altName"]).strip_edges()
	if name == "":
		return
	var hit := index.resolve_path_from(name, weapon_path)
	if hit == "" or hit == weapon_path:
		notes.append("Alt weapon '%s' is declared but not resolvable." % name)
		return
	var candidate := WeaponProfile.new()
	if candidate.resolve(index, shooter_path, target_path, name, false):
		alt = candidate
		notes.append("Alt weapon: %s -> %s" % [candidate.weapon_name, candidate.ordnance_name])
	else:
		notes.append("Alt weapon '%s' did not resolve a complete chain." % name)


func _read_target() -> void:
	target_health_max = 1000.0
	target_shield_max = 0.0
	target_shield_class = ""
	target_ammo_max = 0
	target_armor = "N"
	target_radius = 2.0
	target_name = target_path.get_file().get_basename() if target_path != "" else "none"
	target_health_documented = false
	if target_doc == null:
		return
	var health := _find_value(target_doc, ["maxHealth"])
	if health != "":
		target_health_max = max(1.0, health.to_float())
		target_health_documented = true
	else:
		target_health_max = 1000.0
		notes.append("Target maxHealth not declared; preview uses 1000 (editor default, not game data).")
	var armor := _find_value(target_doc, ["armorClass"])
	if armor != "":
		target_armor = armor.strip_edges().to_upper().substr(0, 1)
	else:
		notes.append("Target declares no armorClass; preview uses N (none).")
	var radius := _find_value(target_doc, ["collisionRadius", "shotRadius"])
	if radius != "":
		target_radius = max(0.2, radius.to_float())
	var shield_max := _find_value(target_doc, ["maxShield", "shieldHealth"])
	if shield_max != "":
		target_shield_max = maxf(0.0, shield_max.to_float())
	var shield_class := _find_value(target_doc, ["shieldClass"])
	if shield_class != "":
		target_shield_class = shield_class.strip_edges().to_upper().substr(0, 1)
	var ammo_max := _find_value(target_doc, ["maxAmmo"])
	if ammo_max != "":
		target_ammo_max = maxi(0, ammo_max.to_int())
	var nm := _find_value(target_doc, ["unitName"])
	if nm != "":
		target_name = nm


func refresh() -> void:
	if is_frozen_snapshot:
		return
	if shooter_doc != null:
		shooter_geometry = _find_value(shooter_doc, ["geometryName"])
		shooter_geometry_scale = _float_or(_find_value(shooter_doc, ["geometryScale"]), 1.0)
		var sh_ammo := _find_value(shooter_doc, ["maxAmmo"])
		shooter_ammo_max = maxi(0, sh_ammo.to_int()) if sh_ammo != "" else 0
		var sh_energy := _find_value(shooter_doc, ["maxEnergy", "energyMax"])
		shooter_energy_max = maxf(0.0, sh_energy.to_float()) if sh_energy != "" else 0.0
		var sh_hp := _find_value(shooter_doc, ["maxHealth"])
		shooter_health_max = maxf(1.0, sh_hp.to_float()) if sh_hp != "" else 1000.0
		var sh_arm := _find_value(shooter_doc, ["armorClass"])
		shooter_armor = sh_arm.strip_edges().to_upper().substr(0, 1) if sh_arm != "" else "H"
	if target_doc != null:
		target_geometry = _find_value(target_doc, ["geometryName"])
		target_geometry_scale = _float_or(_find_value(target_doc, ["geometryScale"]), 1.0)
		var t_hp := _find_value(target_doc, ["maxHealth"])
		if t_hp != "":
			target_health_max = maxf(1.0, t_hp.to_float())
			target_health_documented = true
		var t_arm := _find_value(target_doc, ["armorClass"])
		if t_arm != "":
			target_armor = t_arm.strip_edges().to_upper().substr(0, 1)
		# Shield/ammo are live-tunable preview fields; re-read on every refresh
		# so set_override() from the sweep and inspector edits take effect.
		var shield_max := _find_value(target_doc, ["maxShield", "shieldHealth"])
		target_shield_max = maxf(0.0, shield_max.to_float()) if shield_max != "" else 0.0
		var shield_class := _find_value(target_doc, ["shieldClass"])
		target_shield_class = shield_class.strip_edges().to_upper().substr(0, 1) if shield_class != "" else ""
		var ammo_max := _find_value(target_doc, ["maxAmmo"])
		target_ammo_max = maxi(0, ammo_max.to_int()) if ammo_max != "" else 0
	if weapon_doc != null:
		weapon_class_label = _find_value(weapon_doc, ["classLabel"]).strip_edges().to_lower()
		fire_sound = _find_value(weapon_doc, ["fireSound", "activeSound"])
		muzzle_render = _find_value(weapon_doc, ["flashName", "renderName"])
		shot_delay = _float_or(_find_value(weapon_doc, ["shotDelay"]), 1.0)
		salvo_count = max(1, _int_or(_find_value(weapon_doc, ["salvoCount"]), 1))
		salvo_delay = _float_or(_find_value(weapon_doc, ["salvoDelay"]), 0.0)
		shot_variance = maxf(0.0, _float_or(_find_value(weapon_doc, ["shotVariance"]), 0.0))
		kick_veloc = _float_or(_find_value(weapon_doc, ["kickVeloc"]), 0.0)
		weapon_header = str(weapon_doc.header_names()[0]) if not weapon_doc.header_names().is_empty() else "WeaponClass"
	if ordnance_doc != null:
		ordnance_header = str(ordnance_doc.header_names()[0]) if not ordnance_doc.header_names().is_empty() else "OrdnanceClass"
		ordnance_class_label = _find_value(ordnance_doc, ["classLabel"]).strip_edges().to_lower()
		if is_beam_weapon:
			var fdist := maxf(10.0, _float_or(_find_value(ordnance_doc, ["finishDist", "aiRange"]), 100.0))
			shot_speed = 1e6
			life_span = fdist / shot_speed
			shot_radius = 0.6
			is_arcing = false
			shot_sound = _find_value(ordnance_doc, ["activeSound", "shotSound"])
			shot_geometry = ""
			render_name = _find_value(ordnance_doc, ["flashName", "renderName"])
			if render_name == "" and ordnance_doc.has_header("Flash"):
				render_name = weapon_name + ".Flash"
		else:
			shot_speed = _float_or(_find_value(ordnance_doc, ["shotSpeed"]), 0.0)
			life_span = _float_or(_find_value(ordnance_doc, ["lifeSpan"]), 1e30)
			shot_radius = max(0.05, _float_or(_find_value(ordnance_doc, ["shotRadius"]), 0.5))
			is_arcing = _bool_or(_find_value(ordnance_doc, ["IsArcing"]), false)
			shot_sound = _find_value(ordnance_doc, ["shotSound"])
			shot_geometry = _find_value(ordnance_doc, ["shotGeometry"])
			if shot_geometry.to_lower() == "null":
				shot_geometry = ""
			render_name = _find_value(ordnance_doc, ["renderName"])
		omega_turn = maxf(0.0, _float_or(_find_value(ordnance_doc, ["omegaTurn", "turnRate"]), 0.0))
		is_homing = omega_turn > 0.0 or ordnance_class_label.contains("missile") or ordnance_class_label.contains("torpedo")
		if is_homing and omega_turn <= 0.0:
			omega_turn = 1.2
		if absf(kick_veloc) < 0.001:
			kick_veloc = _float_or(_find_value(ordnance_doc, ["kickVeloc"]), 0.0)
		is_beam_render = is_beam_weapon or ordnance_class_label == "beam" or (shot_speed >= 5000.0 and life_span < 0.05)
		if not is_beam_render and render_name != "" and index != null:
			is_beam_render = EffectRuntime.is_bolt_or_beam_ref(index, render_name, ordnance_path)
		xpl_ground = _find_value(ordnance_doc, ["xplGround"])
		xpl_vehicle = _find_value(ordnance_doc, ["xplVehicle"])
		xpl_expire = _find_value(ordnance_doc, ["xplExpire"])
		ammo_cost = maxi(0, _int_or(_find_value(ordnance_doc, ["ammoCost"]), 0))
		if ammo_cost == 0 and weapon_doc != null:
			ammo_cost = maxi(0, _int_or(_find_value(weapon_doc, ["ammoCost"]), 0))
		weapon_energy_cost = maxf(0.0, _float_or(_find_value(ordnance_doc, ["energyCost"]), 0.0))
		if weapon_energy_cost <= 0.0 and weapon_doc != null:
			weapon_energy_cost = maxf(0.0, _float_or(_find_value(weapon_doc, ["energyCost"]), 0.0))
		damage_shield = maxf(0.0, _float_or(_find_value(ordnance_doc, ["DamageShield"]), 1.0))
		damage.clear()
		for letter in ["N", "L", "H", "S", "D", "A"]:
			var v := _find_value(ordnance_doc, ["damageValue", "damagevalue"], "(" + letter + ")")
			if v != "":
				damage[letter] = v.to_float()
		if xpl_vehicle != "":
			var xpl_path := index.resolve_path_from(xpl_vehicle, ordnance_path)
			if xpl_path != "":
				var xpl := OdfDocument.load_cached(xpl_path)
				if xpl != null:
					damage_radius = _float_or(_find_value(xpl, ["damageRadius"]), 0.0)
					expl_sound = _find_value(xpl, ["explSound", "soundEffect"])


func expected_damage() -> float:
	return expected_damage_for_target()


## Shielded targets use damageValue(S|D|A) when declared; unshielded targets
## use the documented armor-class value. Falls back to damageValue(N).
func expected_damage_for_target() -> float:
	return damage_for_actor(target_armor, target_shield_class, target_shield_max)


func damage_for_actor(p_armor: String, p_shield_class: String = "", p_shield_current: float = 0.0) -> float:
	var key := p_armor if p_armor != "" else "N"
	var sc := p_shield_class.strip_edges().to_upper().substr(0, 1) if p_shield_class != "" else ""
	if sc != "" and p_shield_current > 0.0 and damage.has(sc):
		key = sc
	return float(damage.get(key, damage.get("N", 0.0)))


## BZCC documents shieldRatio N/A=1.0, S=0.75, D=0.5. DamageShield from the
## ordnance scales this multiplier (APPROXIMATED preview model).
func shield_damage_ratio() -> float:
	return shield_damage_ratio_for_class(target_shield_class)


func shield_damage_ratio_for_class(sclass: String) -> float:
	var sc := sclass.strip_edges().to_upper().substr(0, 1) if sclass != "" else ""
	if sc == "":
		return 1.0
	var base := 1.0
	match sc:
		"S": base = 0.75
		"D": base = 0.5
		"N", "A": base = 1.0
	return maxf(0.0, base * damage_shield)


func range_estimate() -> float:
	if life_span > 1e20:
		return INF
	return shot_speed * life_span


func damage_table() -> String:
	var parts: Array[String] = []
	for letter in ["N", "L", "H", "S", "D", "A"]:
		if damage.has(letter):
			parts.append("%s=%s" % [letter, str(damage[letter])])
	return ", ".join(parts)


## Set a transient override for the next refresh()/simulation. The document on
## disk and the shared OdfDocument are untouched.
func set_override(name: String, value: String) -> void:
	overrides[override_id(name)] = str(value)


func clear_overrides() -> void:
	overrides.clear()


static func override_id(name: String) -> String:
	var n := name.strip_edges()
	var suffix := ""
	var p := n.find("(")
	if p >= 0:
		suffix = n.substr(p)
		n = n.substr(0, p)
	return n.to_lower() + "|" + suffix.to_lower()


func _find_value(doc: OdfDocument, keys: Array, suffix: String = "") -> String:
	if doc == null or index == null:
		return ""
	# Overrides win even when the property is absent from the merged chain
	# (e.g. shotRadius is documented as not inherited).
	for wanted in keys:
		var oid := str(wanted).to_lower() + "|" + suffix.to_lower()
		if overrides.has(oid):
			return str(overrides[oid])
	for row in OdfInheritance.merged(doc, index):
		var k: String = str(row.key).to_lower()
		if str(row.suffix).to_lower() != suffix.to_lower():
			continue
		for wanted in keys:
			if k == str(wanted).to_lower():
				return str(row.value)
	return ""


func _float_or(v: String, fallback: float) -> float:
	if v.strip_edges() == "":
		return fallback
	var f := v.to_float()
	return f if is_finite(f) else fallback


func _int_or(v: String, fallback: int) -> int:
	if v.strip_edges() == "":
		return fallback
	return v.to_int()


func _bool_or(v: String, fallback: bool) -> bool:
	if v.strip_edges() == "":
		return fallback
	var c := v.substr(0, 1).to_lower()
	return not (c == "f" or c == "n" or c == "0")


## Capture an immutable dictionary snapshot of all effective weapon/ordnance/actor
## parameters and source ODF revisions for deterministic replay across ODF edits.
func snapshot_params() -> Dictionary:
	if not is_frozen_snapshot:
		refresh()
	var revs := captured_odf_revisions.duplicate(true)
	if not is_frozen_snapshot:
		revs = {}
		for pair in [
			["shooter", shooter_path, shooter_doc],
			["weapon", weapon_path, weapon_doc],
			["ordnance", ordnance_path, ordnance_doc],
			["target", target_path, target_doc],
		]:
			var role := str(pair[0])
			var p := str(pair[1])
			var doc: OdfDocument = pair[2]
			if doc != null:
				revs[role] = {
					"path": p,
					"md5": WorkspaceStore._md5_bytes(doc.to_bytes()),
					"dirty": doc.dirty,
				}
			elif p != "":
				revs[role] = {"path": p, "md5": "", "dirty": false}
	return {
		"shooter_path": shooter_path,
		"weapon_path": weapon_path,
		"ordnance_path": ordnance_path,
		"target_path": target_path,
		"weapon_name": weapon_name,
		"weapon_hardpoint": weapon_hardpoint,
		"ordnance_name": ordnance_name,
		"weapon_header": weapon_header,
		"ordnance_header": ordnance_header,
		"weapon_class_label": weapon_class_label,
		"ordnance_class_label": ordnance_class_label,
		"shot_speed": shot_speed,
		"life_span": life_span,
		"shot_radius": shot_radius,
		"is_arcing": is_arcing,
		"fire_sound": fire_sound,
		"shot_sound": shot_sound,
		"muzzle_render": muzzle_render,
		"expl_sound": expl_sound,
		"shot_delay": shot_delay,
		"salvo_count": salvo_count,
		"salvo_delay": salvo_delay,
		"shot_variance": shot_variance,
		"kick_veloc": kick_veloc,
		"omega_turn": omega_turn,
		"is_homing": is_homing,
		"is_beam_weapon": is_beam_weapon,
		"is_beam_render": is_beam_render,
		"ammo_cost": ammo_cost,
		"weapon_energy_cost": weapon_energy_cost,
		"damage_shield": damage_shield,
		"damage": damage.duplicate(true),
		"damage_radius": damage_radius,
		"xpl_ground": xpl_ground,
		"xpl_vehicle": xpl_vehicle,
		"xpl_expire": xpl_expire,
		"render_name": render_name,
		"shot_geometry": shot_geometry,
		"shooter_ammo_max": shooter_ammo_max,
		"shooter_energy_max": shooter_energy_max,
		"shooter_health_max": shooter_health_max,
		"shooter_armor": shooter_armor,
		"target_health_max": target_health_max,
		"target_shield_max": target_shield_max,
		"target_shield_class": target_shield_class,
		"target_ammo_max": target_ammo_max,
		"target_armor": target_armor,
		"target_radius": target_radius,
		"target_half_extents": [target_half_extents.x, target_half_extents.y, target_half_extents.z],
		"target_bbox_offset": [target_bbox_offset.x, target_bbox_offset.y, target_bbox_offset.z],
		"target_yaw_rad": target_yaw_rad,
		"target_name": target_name,
		"odf_revisions": revs,
	}


static func from_snapshot(snap: Dictionary) -> WeaponProfile:
	var p := new()
	p.is_frozen_snapshot = true
	p.shooter_path = str(snap.get("shooter_path", ""))
	p.weapon_path = str(snap.get("weapon_path", ""))
	p.ordnance_path = str(snap.get("ordnance_path", ""))
	p.target_path = str(snap.get("target_path", ""))
	p.weapon_name = str(snap.get("weapon_name", ""))
	p.weapon_hardpoint = str(snap.get("weapon_hardpoint", ""))
	p.ordnance_name = str(snap.get("ordnance_name", ""))
	p.weapon_header = str(snap.get("weapon_header", ""))
	p.ordnance_header = str(snap.get("ordnance_header", "OrdnanceClass"))
	p.weapon_class_label = str(snap.get("weapon_class_label", ""))
	p.ordnance_class_label = str(snap.get("ordnance_class_label", ""))
	p.shot_speed = float(snap.get("shot_speed", 0.0))
	p.life_span = float(snap.get("life_span", 1.0))
	p.shot_radius = float(snap.get("shot_radius", 0.5))
	p.is_arcing = bool(snap.get("is_arcing", false))
	p.fire_sound = str(snap.get("fire_sound", ""))
	p.shot_sound = str(snap.get("shot_sound", ""))
	p.muzzle_render = str(snap.get("muzzle_render", ""))
	p.expl_sound = str(snap.get("expl_sound", ""))
	p.shot_delay = float(snap.get("shot_delay", 1.0))
	p.salvo_count = int(snap.get("salvo_count", 1))
	p.salvo_delay = float(snap.get("salvo_delay", 0.0))
	p.shot_variance = float(snap.get("shot_variance", 0.0))
	p.kick_veloc = float(snap.get("kick_veloc", 0.0))
	p.omega_turn = float(snap.get("omega_turn", 0.0))
	p.is_homing = bool(snap.get("is_homing", false))
	p.is_beam_weapon = bool(snap.get("is_beam_weapon", false))
	p.is_beam_render = bool(snap.get("is_beam_render", false))
	p.ammo_cost = int(snap.get("ammo_cost", 0))
	p.weapon_energy_cost = float(snap.get("weapon_energy_cost", 0.0))
	p.damage_shield = float(snap.get("damage_shield", 1.0))
	var dm = snap.get("damage", {})
	p.damage = (dm as Dictionary).duplicate(true) if dm is Dictionary else {}
	p.damage_radius = float(snap.get("damage_radius", 0.0))
	p.xpl_ground = str(snap.get("xpl_ground", ""))
	p.xpl_vehicle = str(snap.get("xpl_vehicle", ""))
	p.xpl_expire = str(snap.get("xpl_expire", ""))
	p.render_name = str(snap.get("render_name", ""))
	p.shot_geometry = str(snap.get("shot_geometry", ""))
	p.shooter_ammo_max = int(snap.get("shooter_ammo_max", 0))
	p.shooter_energy_max = float(snap.get("shooter_energy_max", 0.0))
	p.shooter_health_max = float(snap.get("shooter_health_max", 1000.0))
	p.shooter_armor = str(snap.get("shooter_armor", "H"))
	p.target_health_max = float(snap.get("target_health_max", 1000.0))
	p.target_shield_max = float(snap.get("target_shield_max", 0.0))
	p.target_shield_class = str(snap.get("target_shield_class", ""))
	p.target_ammo_max = int(snap.get("target_ammo_max", 0))
	p.target_armor = str(snap.get("target_armor", "N"))
	p.target_radius = float(snap.get("target_radius", 2.0))
	var he = snap.get("target_half_extents", [0.0, 0.0, 0.0])
	if he is Array and (he as Array).size() >= 3:
		p.target_half_extents = Vector3(float(he[0]), float(he[1]), float(he[2]))
	var bo = snap.get("target_bbox_offset", [0.0, 0.0, 0.0])
	if bo is Array and (bo as Array).size() >= 3:
		p.target_bbox_offset = Vector3(float(bo[0]), float(bo[1]), float(bo[2]))
	p.target_yaw_rad = float(snap.get("target_yaw_rad", 0.0))
	p.target_name = str(snap.get("target_name", ""))
	var revs = snap.get("odf_revisions", {})
	p.captured_odf_revisions = (revs as Dictionary).duplicate(true) if revs is Dictionary else {}
	return p
