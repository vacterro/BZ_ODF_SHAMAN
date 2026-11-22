class_name CombatActorState
extends RefCounted
## Persistent per-actor combat state (P1-SIM-01, P1-SIM-02, P1-SIM-03).
## Owns hull, shield, shooter-owned ammo/energy, reload cooldown, active status
## effects, and destruction state across sequential shots. Never recreated per
## projectile unless the operator explicitly resets the actor or scenario.

var actor_id: String = ""
var role: String = "target"  # "shooter" or "target"
var display_name: String = ""

var hull_max: float = 1000.0
var hull_current: float = 1000.0
var armor_class: String = "N"

var shield_max: float = 0.0
var shield_current: float = 0.0
var shield_class: String = ""

var ammo_max: int = 0
var ammo_current: int = 0
var ammo_unlimited: bool = true

var energy_max: float = 0.0
var energy_current: float = 0.0
var energy_unlimited: bool = true

var shot_delay: float = 0.0
var reload_remaining: float = 0.0

var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var yaw_rad: float = 0.0
var radius: float = 2.0
var half_extents: Vector3 = Vector3.ZERO
var bbox_offset: Vector3 = Vector3.ZERO

var destroyed: bool = false
var active_effects: Array[Dictionary] = []


static func create_shooter(p_id: String, p_name: String, p_ammo_max: int = 0,
		p_energy_max: float = 0.0, p_hull_max: float = 1000.0, p_armor: String = "H",
		p_shot_delay: float = 0.0) -> CombatActorState:
	var st := new()
	st.actor_id = p_id
	st.role = "shooter"
	st.display_name = p_name
	st.hull_max = maxf(1.0, p_hull_max)
	st.hull_current = st.hull_max
	st.armor_class = p_armor
	st.ammo_max = maxi(0, p_ammo_max)
	st.ammo_current = st.ammo_max
	st.ammo_unlimited = st.ammo_max <= 0
	st.energy_max = maxf(0.0, p_energy_max)
	st.energy_current = st.energy_max
	st.energy_unlimited = st.energy_max <= 0.0
	st.shot_delay = maxf(0.0, p_shot_delay)
	st.reload_remaining = 0.0
	return st


static func create_target(p_id: String, p_name: String, p_hull_max: float = 1000.0,
		p_armor: String = "N", p_shield_max: float = 0.0, p_shield_class: String = "",
		p_position: Vector3 = Vector3.ZERO, p_radius: float = 2.0) -> CombatActorState:
	var st := new()
	st.actor_id = p_id
	st.role = "target"
	st.display_name = p_name
	st.hull_max = maxf(1.0, p_hull_max)
	st.hull_current = st.hull_max
	st.armor_class = p_armor if p_armor != "" else "N"
	st.shield_max = maxf(0.0, p_shield_max)
	st.shield_current = st.shield_max
	st.shield_class = p_shield_class.strip_edges().to_upper().substr(0, 1) if p_shield_class != "" else ""
	st.position = p_position
	st.radius = maxf(0.2, p_radius)
	return st


func reset_to_initial() -> void:
	hull_current = hull_max
	shield_current = shield_max
	ammo_current = ammo_max
	energy_current = energy_max
	reload_remaining = 0.0
	destroyed = false
	active_effects.clear()


func can_fire(ammo_cost: int, energy_cost: float = 0.0, enforce_reload: bool = false) -> Dictionary:
	if destroyed:
		return {"ok": false, "reason": "SHOOTER_DESTROYED"}
	if enforce_reload and reload_remaining > 0.0001:
		return {"ok": false, "reason": "WEAPON_RELOADING", "reload_remaining": reload_remaining}
	if ammo_cost > 0 and not ammo_unlimited and ammo_current < ammo_cost:
		return {
			"ok": false,
			"reason": "INSUFFICIENT_AMMO",
			"ammo_current": ammo_current,
			"ammo_cost": ammo_cost,
		}
	if energy_cost > 0.0 and not energy_unlimited and energy_current + 0.0001 < energy_cost:
		return {
			"ok": false,
			"reason": "INSUFFICIENT_ENERGY",
			"energy_current": energy_current,
			"energy_cost": energy_cost,
		}
	return {"ok": true, "reason": ""}


func consume_fire_resources(ammo_cost: int, energy_cost: float = 0.0, p_shot_delay: float = -1.0) -> Dictionary:
	var chk := can_fire(ammo_cost, energy_cost, false)
	if not bool(chk.get("ok", false)):
		return {
			"ok": false,
			"reason": str(chk.get("reason", "CANNOT_FIRE")),
			"ammo_spent": 0,
			"energy_spent": 0.0,
			"ammo_remaining": ammo_current,
			"energy_remaining": energy_current,
		}
	var spent_ammo := 0
	if ammo_cost > 0:
		if ammo_unlimited:
			spent_ammo = ammo_cost
		else:
			spent_ammo = mini(ammo_current, ammo_cost)
			ammo_current = maxi(0, ammo_current - spent_ammo)
	var spent_energy := 0.0
	if energy_cost > 0.0:
		if energy_unlimited:
			spent_energy = energy_cost
		else:
			spent_energy = minf(energy_current, energy_cost)
			energy_current = maxf(0.0, energy_current - spent_energy)
	if p_shot_delay >= 0.0:
		shot_delay = p_shot_delay
	if shot_delay > 0.0:
		reload_remaining = shot_delay
	return {
		"ok": true,
		"reason": "",
		"ammo_spent": spent_ammo,
		"energy_spent": spent_energy,
		"ammo_remaining": ammo_current,
		"energy_remaining": energy_current,
	}


## Apply incoming damage through this actor's persistent shield before spilling
## any remaining fraction to hull (APPROXIMATED BZCC shield model).
func apply_damage(raw_damage: float, shield_ratio: float = 1.0, damage_kind: String = "direct") -> Dictionary:
	var dmg := maxf(0.0, raw_damage)
	var shield_before := shield_current
	var hull_before := hull_current
	var shield_absorbed := 0.0
	var hull_damage := dmg
	if shield_current > 0.0 and shield_max > 0.0 and dmg > 0.0:
		var eff_ratio := maxf(0.0001, shield_ratio)
		var shield_hit := dmg * eff_ratio
		shield_absorbed = minf(shield_current, shield_hit)
		shield_current = maxf(0.0, shield_current - shield_absorbed)
		var spill := maxf(0.0, shield_hit - shield_absorbed)
		hull_damage = dmg * (spill / shield_hit)
	hull_current = maxf(0.0, hull_current - hull_damage)
	var just_destroyed := (not destroyed) and hull_current <= 0.0001
	if just_destroyed:
		destroyed = true
	return {
		"actor_id": actor_id,
		"kind": damage_kind,
		"raw_damage": dmg,
		"shield_before": shield_before,
		"shield_absorbed": shield_absorbed,
		"shield_remaining": shield_current,
		"shield_max": shield_max,
		"shield_class": shield_class,
		"hull_before": hull_before,
		"hull_damage": hull_damage,
		"hull_remaining": hull_current,
		"hull_max": hull_max,
		"destroyed": destroyed,
		"just_destroyed": just_destroyed,
	}


func add_effect(effect_name: String, dps: float, duration_s: float, shield_ratio: float = 1.0) -> void:
	if duration_s <= 0.0:
		return
	active_effects.append({
		"name": effect_name,
		"dps": maxf(0.0, dps),
		"remaining_s": duration_s,
		"shield_ratio": shield_ratio,
	})


func tick(dt: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if reload_remaining > 0.0:
		reload_remaining = maxf(0.0, reload_remaining - dt)
	if active_effects.is_empty():
		return out
	var keep: Array[Dictionary] = []
	for eff in active_effects:
		var step_dt := minf(dt, float(eff.get("remaining_s", 0.0)))
		var dps := float(eff.get("dps", 0.0))
		if step_dt > 0.0 and dps > 0.0 and not destroyed:
			var res := apply_damage(dps * step_dt, float(eff.get("shield_ratio", 1.0)), "dot:" + str(eff.get("name", "effect")))
			out.append(res)
		var rem := float(eff.get("remaining_s", 0.0)) - dt
		if rem > 0.0001:
			var copy := eff.duplicate(true)
			copy["remaining_s"] = rem
			keep.append(copy)
	active_effects = keep
	return out


func snapshot() -> Dictionary:
	return {
		"actor_id": actor_id,
		"role": role,
		"display_name": display_name,
		"hull_max": hull_max,
		"hull_current": hull_current,
		"armor_class": armor_class,
		"shield_max": shield_max,
		"shield_current": shield_current,
		"shield_class": shield_class,
		"ammo_max": ammo_max,
		"ammo_current": ammo_current,
		"ammo_unlimited": ammo_unlimited,
		"energy_max": energy_max,
		"energy_current": energy_current,
		"energy_unlimited": energy_unlimited,
		"shot_delay": shot_delay,
		"reload_remaining": reload_remaining,
		"position": [position.x, position.y, position.z],
		"velocity": [velocity.x, velocity.y, velocity.z],
		"yaw_rad": yaw_rad,
		"radius": radius,
		"destroyed": destroyed,
		"active_effects": active_effects.duplicate(true),
	}


func restore_snapshot(d: Dictionary) -> void:
	hull_max = float(d.get("hull_max", hull_max))
	hull_current = float(d.get("hull_current", hull_max))
	armor_class = str(d.get("armor_class", armor_class))
	shield_max = float(d.get("shield_max", shield_max))
	shield_current = float(d.get("shield_current", shield_max))
	shield_class = str(d.get("shield_class", shield_class))
	ammo_max = int(d.get("ammo_max", ammo_max))
	ammo_current = int(d.get("ammo_current", ammo_max))
	ammo_unlimited = bool(d.get("ammo_unlimited", ammo_max <= 0))
	energy_max = float(d.get("energy_max", energy_max))
	energy_current = float(d.get("energy_current", energy_max))
	energy_unlimited = bool(d.get("energy_unlimited", energy_max <= 0.0))
	shot_delay = float(d.get("shot_delay", shot_delay))
	reload_remaining = float(d.get("reload_remaining", 0.0))
	destroyed = bool(d.get("destroyed", false))
	active_effects = []
	for eff in d.get("active_effects", []):
		if eff is Dictionary:
			active_effects.append((eff as Dictionary).duplicate(true))
