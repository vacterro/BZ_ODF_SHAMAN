class_name ProjectileSim
extends RefCounted
## Deterministic, engine-independent projectile + damage simulation.
## This is the Godot preview model. It is labelled APPROXIMATED unless a
## scenario has been compared against a native BZCC run.

signal event_logged(time: float, kind: String, text: String)
signal shot_finished(result: Dictionary)

const GRAVITY := 9.81
const SUBSTEP := 1.0 / 240.0
const MAX_SUBSTEPS := 64
const ActorStateScript = preload("res://scripts/sim/combat_actor_state.gd")

## Launch-time identity for one projectile. Weapon switching changes the
## profile used for new shots; already-fired shots keep these frozen values.
class ShotIdentity:
	var shot_id: int = 0
	var weapon_name: String = ""
	var ordnance_name: String = ""
	var weapon_path: String = ""
	var ordnance_path: String = ""
	var source_revision: Dictionary = {}
	var hardpoint: String = ""
	var weapon_slot: int = -1
	var firing_context: String = "PRIMARY"
	var barrel_index: int = 0
	var barrel_mode: String = "SINGLE"
	var volley_id: int = 0
	var projectile_model: String = ""
	var render_name: String = ""
	var muzzle_render: String = ""
	var fire_sound: String = ""
	var shot_sound: String = ""
	var expl_sound: String = ""
	var xpl_vehicle: String = ""
	var xpl_ground: String = ""
	var xpl_expire: String = ""
	var damage_table: Dictionary = {}
	var damage: float = 0.0

	func to_dict() -> Dictionary:
		return {
			"shot_id": shot_id, "weapon_name": weapon_name,
			"ordnance_name": ordnance_name, "weapon_path": weapon_path,
			"ordnance_path": ordnance_path, "source_revision": source_revision.duplicate(true),
			"hardpoint": hardpoint, "weapon_slot": weapon_slot,
			"firing_context": firing_context,
			"barrel_index": barrel_index,
			"barrel_mode": barrel_mode, "volley_id": volley_id,
			"projectile_model": projectile_model, "render_name": render_name,
			"muzzle_render": muzzle_render, "fire_sound": fire_sound,
			"shot_sound": shot_sound, "expl_sound": expl_sound,
			"xpl_vehicle": xpl_vehicle, "xpl_ground": xpl_ground,
			"xpl_expire": xpl_expire, "damage_table": damage_table.duplicate(true),
			"damage": damage,
		}

	static func from_dict(d: Dictionary) -> ShotIdentity:
		var id := ShotIdentity.new()
		id.shot_id = int(d.get("shot_id", 0))
		id.weapon_name = str(d.get("weapon_name", ""))
		id.ordnance_name = str(d.get("ordnance_name", ""))
		id.weapon_path = str(d.get("weapon_path", ""))
		id.ordnance_path = str(d.get("ordnance_path", ""))
		var rev = d.get("source_revision", {})
		id.source_revision = (rev as Dictionary).duplicate(true) if rev is Dictionary else {}
		id.hardpoint = str(d.get("hardpoint", ""))
		id.weapon_slot = int(d.get("weapon_slot", -1))
		id.firing_context = str(d.get("firing_context", "PRIMARY"))
		id.barrel_index = int(d.get("barrel_index", 0))
		id.barrel_mode = str(d.get("barrel_mode", "SINGLE"))
		id.volley_id = int(d.get("volley_id", 0))
		id.projectile_model = str(d.get("projectile_model", ""))
		id.render_name = str(d.get("render_name", ""))
		id.muzzle_render = str(d.get("muzzle_render", ""))
		id.fire_sound = str(d.get("fire_sound", ""))
		id.shot_sound = str(d.get("shot_sound", ""))
		id.expl_sound = str(d.get("expl_sound", ""))
		id.xpl_vehicle = str(d.get("xpl_vehicle", ""))
		id.xpl_ground = str(d.get("xpl_ground", ""))
		id.xpl_expire = str(d.get("xpl_expire", ""))
		var dt = d.get("damage_table", {})
		id.damage_table = (dt as Dictionary).duplicate(true) if dt is Dictionary else {}
		id.damage = float(d.get("damage", 0.0))
		return id


class Shot:
	var shot_id: int = 0
	var identity: ShotIdentity = null
	var spawn_time: float = 0.0
	var impact_time: float = -1.0
	var origin: Vector3 = Vector3.ZERO
	var position: Vector3 = Vector3.ZERO
	var previous: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var speed: float = 0.0
	var age: float = 0.0
	var life_span: float = 1.0
	var radius: float = 0.2
	var damage_value: float = 0.0
	var damage_radius: float = 0.0
	var gravity: float = 0.0
	var omega_turn: float = 0.0
	var is_homing: bool = false
	var is_beam: bool = false
	var alive: bool = true
	var target_position: Vector3 = Vector3.ZERO
	var target_radius: float = 2.0
	var target_half_extents: Vector3 = Vector3.ZERO
	var target_bbox_center: Vector3 = Vector3.ZERO
	var target_bbox_offset: Vector3 = Vector3.ZERO
	var target_yaw_rad: float = 0.0
	var target_health: float = 1000.0
	var target_health_max: float = 1000.0
	var target_armor: String = "N"
	var xpl_vehicle: String = ""
	var xpl_ground: String = ""
	var xpl_expire: String = ""
	var render_name: String = ""
	var shot_sound: String = ""
	var weapon_name: String = ""
	var ordnance_name: String = ""
	var events: Array[Dictionary] = []
	var hit_kind: String = ""
	var hit_target_id: String = ""
	var hit_obstacle_id: String = ""
	var damage_applied: float = 0.0
	var hit_normal: Vector3 = Vector3.ZERO
	var target_shield_max: float = 0.0
	var target_shield: float = 0.0
	var target_shield_class: String = ""
	var shield_damage_ratio: float = 1.0
	var damage_shield_mult: float = 1.0
	var damage_table: Dictionary = {}
	var shield_damage_applied: float = 0.0
	var damage_to_hull: float = 0.0
	var ammo_cost: int = 0
	var ammo_spent: int = 0
	var energy_cost: float = 0.0
	var energy_spent: float = 0.0
	var shooter_ammo_remaining: int = 0
	var shooter_energy_remaining: float = 0.0
	var shooter_state: RefCounted = null
	var target_state: RefCounted = null
	var splash_hits: Array[Dictionary] = []
	var extra_targets: Array = []
	var obstacles: Array = []


var events: Array[Dictionary] = []
var shots: Array = []
var sim_time: float = 0.0
var rng := RandomNumberGenerator.new()
var seed_value: int = 1337
var _next_shot_id: int = 0


func _init(p_seed: int = 1337) -> void:
	seed_value = p_seed
	rng.seed = p_seed


func reset() -> void:
	events.clear()
	shots.clear()
	sim_time = 0.0
	_next_shot_id = 0
	rng.seed = seed_value


func spawn(profile: WeaponProfile, origin: Vector3, direction: Vector3, target_position: Vector3,
		target_health: float = -1.0, p_extra_targets: Array = [], p_obstacles: Array = [],
		shooter_velocity: Vector3 = Vector3.ZERO, p_shooter_state: RefCounted = null,
		p_target_state: RefCounted = null, p_physical_weapon_slot: int = -1,
		p_firing_context: String = "PRIMARY") -> Shot:
	profile.refresh()
	var s := Shot.new()
	_next_shot_id += 1
	s.shot_id = _next_shot_id
	s.spawn_time = sim_time
	s.impact_time = -1.0
	s.origin = origin
	s.position = origin
	s.previous = origin
	s.shooter_state = p_shooter_state
	s.target_state = p_target_state
	var launch_dir := direction.normalized()
	if profile.shot_variance > 0.00001:
		var yaw_off := rng.randf_range(-profile.shot_variance, profile.shot_variance)
		var pitch_off := rng.randf_range(-profile.shot_variance, profile.shot_variance)
		var right_ax := launch_dir.cross(Vector3.UP)
		if right_ax.length_squared() < 0.0001:
			right_ax = Vector3.RIGHT
		right_ax = right_ax.normalized()
		launch_dir = launch_dir.rotated(Vector3.UP, yaw_off).rotated(right_ax, pitch_off).normalized()
	s.velocity = launch_dir * profile.shot_speed + shooter_velocity
	s.speed = maxf(profile.shot_speed, s.velocity.length())
	s.life_span = profile.life_span
	s.radius = profile.shot_radius
	s.damage_table = profile.damage.duplicate(true)
	s.damage_shield_mult = profile.damage_shield
	s.damage_radius = profile.damage_radius
	# P1-SIM-02: Preserve persistent actor shield/hull instead of recreating full
	# shield per projectile when a persistent CombatActorState is bound.
	if p_target_state != null:
		s.target_shield_max = p_target_state.shield_max
		s.target_shield = p_target_state.shield_current
		s.target_shield_class = p_target_state.shield_class
		s.target_armor = p_target_state.armor_class
		s.target_health = p_target_state.hull_current
		s.target_health_max = p_target_state.hull_max
		s.shield_damage_ratio = profile.shield_damage_ratio_for_class(s.target_shield_class)
		s.damage_value = profile.damage_for_actor(s.target_armor, s.target_shield_class, s.target_shield)
	else:
		s.target_shield_max = profile.target_shield_max
		s.target_shield = profile.target_shield_max
		s.target_shield_class = profile.target_shield_class
		s.target_armor = profile.target_armor
		s.target_health = profile.target_health_max if target_health < 0.0 else target_health
		s.target_health_max = profile.target_health_max
		s.shield_damage_ratio = profile.shield_damage_ratio()
		s.damage_value = profile.expected_damage_for_target()
	# P1-SIM-01: Ammo and energy consumption belong strictly to the shooter,
	# NEVER derived from target.maxAmmo.
	s.ammo_cost = profile.ammo_cost
	s.energy_cost = profile.weapon_energy_cost
	if p_shooter_state != null:
		s.ammo_spent = s.ammo_cost if p_shooter_state.ammo_unlimited else mini(s.ammo_cost, p_shooter_state.ammo_max)
		s.energy_spent = s.energy_cost if p_shooter_state.energy_unlimited else minf(s.energy_cost, p_shooter_state.energy_max)
		s.shooter_ammo_remaining = p_shooter_state.ammo_current
		s.shooter_energy_remaining = p_shooter_state.energy_current
	else:
		s.ammo_spent = mini(s.ammo_cost, profile.shooter_ammo_max) if profile.shooter_ammo_max > 0 else s.ammo_cost
		s.energy_spent = minf(s.energy_cost, profile.shooter_energy_max) if profile.shooter_energy_max > 0.0 else s.energy_cost
		s.shooter_ammo_remaining = maxi(0, profile.shooter_ammo_max - s.ammo_spent) if profile.shooter_ammo_max > 0 else 0
		s.shooter_energy_remaining = maxf(0.0, profile.shooter_energy_max - s.energy_spent) if profile.shooter_energy_max > 0.0 else 0.0
	s.gravity = GRAVITY if profile.is_arcing else 0.0
	s.omega_turn = profile.omega_turn
	s.is_homing = profile.is_homing
	s.is_beam = profile.is_beam_render or profile.is_beam_weapon
	s.target_position = target_position
	s.target_radius = profile.target_radius
	s.target_half_extents = profile.target_half_extents
	s.target_bbox_offset = profile.target_bbox_offset
	s.target_yaw_rad = profile.target_yaw_rad
	if s.target_half_extents.length_squared() > 0.0001:
		var rot_off := profile.target_bbox_offset.rotated(Vector3.UP, profile.target_yaw_rad)
		s.target_bbox_center = target_position + rot_off
	else:
		s.target_bbox_center = target_position
	s.xpl_vehicle = profile.xpl_vehicle
	s.xpl_ground = profile.xpl_ground
	s.xpl_expire = profile.xpl_expire
	s.render_name = profile.render_name
	s.shot_sound = profile.shot_sound
	s.weapon_name = profile.weapon_name
	s.ordnance_name = profile.ordnance_name
	s.extra_targets = p_extra_targets
	s.obstacles = p_obstacles
	var snap: Dictionary = profile.snapshot_params()
	var revs = snap.get("odf_revisions", {})
	var id := ShotIdentity.new()
	id.shot_id = s.shot_id
	id.weapon_name = profile.weapon_name
	id.ordnance_name = profile.ordnance_name
	id.weapon_path = profile.weapon_path
	id.weapon_slot = p_physical_weapon_slot if p_physical_weapon_slot >= 0 else profile.active_slot_index
	id.firing_context = p_firing_context.strip_edges().to_upper() if p_firing_context.strip_edges() != "" else "PRIMARY"
	id.ordnance_path = profile.ordnance_path
	id.source_revision = (revs as Dictionary).duplicate(true) if revs is Dictionary else {}
	id.render_name = profile.render_name
	id.muzzle_render = profile.muzzle_render
	id.fire_sound = profile.fire_sound
	id.shot_sound = profile.shot_sound
	id.expl_sound = profile.expl_sound
	id.xpl_vehicle = profile.xpl_vehicle
	id.xpl_ground = profile.xpl_ground
	id.xpl_expire = profile.xpl_expire
	id.projectile_model = profile.shot_geometry
	id.damage_table = profile.damage.duplicate(true)
	id.damage = s.damage_value
	s.identity = id
	shots.append(s)
	_log("weapon", "Weapon activated: %s -> %s" % [profile.weapon_name, profile.ordnance_name])
	_log("projectile", "Projectile created at %s, speed %.2f m/s, life %.3f s" % [
		_fmt_vec(origin), profile.shot_speed, profile.life_span
	])
	if profile.shot_variance > 0.00001:
		_log("physics", "shotVariance=%.4f rad applied (seeded deterministic spread, APPROXIMATED)" % profile.shot_variance)
	if shooter_velocity.length() > 0.01:
		_log("physics", "Shooter velocity %s inherited (APPROXIMATED)" % _fmt_vec(shooter_velocity))
	if profile.is_homing:
		_log("physics", "Missile guidance enabled: omegaTurn=%.2f rad/s (APPROXIMATED)" % profile.omega_turn)
	if profile.is_arcing:
		_log("physics", "IsArcing=true: preview applies gravity %.2f m/s^2" % GRAVITY)
	if profile.render_name != "":
		_log("render", "Ordnance render reference: %s" % profile.render_name)
	if profile.shot_sound != "":
		_log("audio", "Ordnance sound reference: %s" % profile.shot_sound)
	if profile.fire_sound != "":
		_log("audio", "Weapon fire sound reference: %s" % profile.fire_sound)
	return s


## Update active shots with the live moving target transform (supports homing
## missile tracking and moving-target collision in real time).
func update_live_target(target_pos: Vector3, target_yaw_rad: float = 0.0) -> void:
	for s in shots:
		if not s.alive:
			continue
		s.target_position = target_pos
		s.target_yaw_rad = target_yaw_rad
		if s.target_half_extents.length_squared() > 0.0001:
			s.target_bbox_center = target_pos + s.target_bbox_offset.rotated(Vector3.UP, target_yaw_rad)
		else:
			s.target_bbox_center = target_pos


func update_live_extra_target(actor_id: String, pos: Vector3, yaw_rad: float = 0.0) -> void:
	if actor_id == "" or actor_id == "primary":
		return
	for s in shots:
		if not s.alive:
			continue
		for et in s.extra_targets:
			if et is Dictionary and str(et.get("id", "")) == actor_id:
				et["position"] = pos
				et["yaw_rad"] = yaw_rad


func advance(dt: float) -> void:
	if dt <= 0.0:
		return
	if shots.is_empty():
		sim_time += dt
		return
	var remaining := dt
	while remaining > 0.0:
		if shots.is_empty():
			sim_time += remaining
			break
		var step: float = minf(SUBSTEP, remaining)
		remaining -= step
		var step_start_t := sim_time
		sim_time += step
		var pending_hits: Array[Dictionary] = []
		for s_any in shots:
			var s: Shot = s_any
			if not s.alive:
				continue
			s.previous = s.position
			s.age += step
			if s.is_homing and s.omega_turn > 0.0 and s.velocity.length_squared() > 0.01:
				var aim_pt: Vector3 = s.target_bbox_center if s.target_half_extents.length_squared() > 0.0001 else s.target_position
				var to_tgt: Vector3 = aim_pt - s.position
				if to_tgt.length_squared() > 0.01:
					var cur_dir: Vector3 = s.velocity.normalized()
					var des_dir: Vector3 = to_tgt.normalized()
					var dot_v: float = clampf(cur_dir.dot(des_dir), -1.0, 1.0)
					var ang: float = acos(dot_v)
					if ang > 0.0001:
						var max_turn: float = s.omega_turn * step
						var turn_ang: float = minf(ang, max_turn)
						var axis: Vector3 = cur_dir.cross(des_dir)
						if axis.length_squared() > 0.000001:
							var new_dir: Vector3 = cur_dir.rotated(axis.normalized(), turn_ang).normalized()
							s.velocity = new_dir * maxf(0.1, s.speed)
			if s.gravity != 0.0:
				s.velocity.y -= s.gravity * step
			s.position += s.velocity * step
			var hit := _evaluate_shot_hit(s, step)
			if not hit.is_empty():
				hit["impact_time"] = step_start_t + step * clampf(float(hit.get("best_t", 1.0)), 0.0, 1.0)
				pending_hits.append(hit)
		if pending_hits.size() > 1:
			# Deterministic physical ordering within a substep (earliest impact first, tie-break by shot_id).
			pending_hits.sort_custom(func(a, b):
				var ta := float(a.get("best_t", 1.0))
				var tb := float(b.get("best_t", 1.0))
				if absf(ta - tb) > 0.000001:
					return ta < tb
				return int((a.get("shot") as Shot).shot_id) < int((b.get("shot") as Shot).shot_id)
			)
		for hit in pending_hits:
			var hs: Shot = hit.get("shot")
			if hs != null and hs.alive:
				hs.position = hit.get("position", hs.position)
				hs.hit_target_id = str(hit.get("hit_target_id", ""))
				hs.hit_obstacle_id = str(hit.get("hit_obstacle_id", ""))
				hs.impact_time = float(hit.get("impact_time", sim_time))
				var hkind := str(hit.get("kind", ""))
				hs.hit_normal = _hit_normal(hs, hkind)
				_finish(hs, hkind)
		shots = shots.filter(func(x): return x.alive)


func _check_shot(s: Shot, step: float) -> void:
	var hit := _evaluate_shot_hit(s, step)
	if hit.is_empty():
		return
	s.position = hit.get("position", s.position)
	s.hit_target_id = str(hit.get("hit_target_id", ""))
	s.hit_obstacle_id = str(hit.get("hit_obstacle_id", ""))
	var hkind := str(hit.get("kind", ""))
	s.hit_normal = _hit_normal(s, hkind)
	_finish(s, hkind)


func _evaluate_shot_hit(s: Shot, step: float) -> Dictionary:
	# Collect every event over the same segment and take the physically earliest
	# one. Checking ground first would misreport a target hit just above ground,
	# and checking targets before obstacles would let projectiles tunnel through walls.
	var delta := s.position - s.previous
	var best_t := INF
	var kind := ""
	var hit_tid := ""
	var hit_oid := ""
	if s.position.y <= 0.0 and s.previous.y > 0.0:
		best_t = s.previous.y / maxf(0.0001, s.previous.y - s.position.y)
		kind = "ground"
	var hit_t = null
	if s.target_half_extents.length_squared() > 0.0001:
		var exp_half := s.target_half_extents + Vector3(s.radius, s.radius, s.radius)
		hit_t = _ray_obb(s.previous, delta, s.target_bbox_center, exp_half, s.target_yaw_rad)
	else:
		hit_t = _ray_sphere(s.previous, delta, s.target_position, s.target_radius + s.radius)
	if hit_t != null and float(hit_t) < best_t:
		best_t = clampf(float(hit_t), 0.0, 1.0)
		kind = "vehicle"
		hit_tid = "primary"
		hit_oid = ""
	for et in s.extra_targets:
		if not (et is Dictionary):
			continue
		var epos: Vector3 = et.get("position", Vector3.ZERO)
		var ehalf: Vector3 = et.get("half_extents", Vector3.ZERO) if et.get("half_extents", null) is Vector3 else Vector3.ZERO
		var et_t = null
		if ehalf.length_squared() > 0.0001:
			et_t = _ray_obb(s.previous, delta, epos, ehalf + Vector3(s.radius, s.radius, s.radius), float(et.get("yaw_rad", 0.0)))
		else:
			var erad: float = float(et.get("radius", s.target_radius))
			et_t = _ray_sphere(s.previous, delta, epos, erad + s.radius)
		if et_t != null and float(et_t) < best_t:
			best_t = clampf(float(et_t), 0.0, 1.0)
			kind = "vehicle"
			hit_tid = str(et.get("id", "extra"))
			hit_oid = ""
	for obs in s.obstacles:
		if not (obs is Dictionary):
			continue
		var opos: Vector3 = obs.get("position", Vector3.ZERO)
		var osize: Vector3 = obs.get("size", Vector3(4, 4, 2))
		var half := osize * 0.5 + Vector3(s.radius, s.radius, s.radius)
		var obs_t = null
		if str(obs.get("shape", "box")) == "ramp":
			obs_t = _ray_ramp(s.previous, delta, opos, osize, s.radius)
		else:
			obs_t = _ray_aabb(s.previous, delta, opos, half)
		if obs_t != null and float(obs_t) < best_t:
			best_t = clampf(float(obs_t), 0.0, 1.0)
			kind = "obstacle"
			hit_tid = ""
			hit_oid = str(obs.get("id", "obstacle"))
	var age_before: float = maxf(0.0, s.age - step)
	if s.life_span > 0.0 and s.age >= s.life_span:
		var expire_t: float = clampf((s.life_span - age_before) / maxf(0.0001, step), 0.0, 1.0)
		if expire_t < best_t:
			best_t = expire_t
			kind = "expire"
			hit_tid = ""
			hit_oid = ""
	if kind == "":
		return {}
	return {
		"shot": s,
		"best_t": clampf(best_t, 0.0, 1.0),
		"position": s.previous + delta * clampf(best_t, 0.0, 1.0),
		"kind": kind,
		"hit_target_id": hit_tid,
		"hit_obstacle_id": hit_oid,
	}


func _finish(s: Shot, kind: String) -> void:
	s.alive = false
	s.hit_kind = kind
	if kind == "vehicle":
		_log("collision", "Collision detected (%s) at %s" % [s.hit_target_id if s.hit_target_id != "" else "primary", _fmt_vec(s.position)])
		var xpl := s.xpl_vehicle if s.xpl_vehicle != "" else s.xpl_ground
		_log("explosion", "Explosion ODF selected: %s" % (xpl if xpl != "" else "(none declared)"))
		if s.hit_target_id != "" and s.hit_target_id != "primary":
			var matched_extra: Dictionary = {}
			for et in s.extra_targets:
				if et is Dictionary and str(et.get("id", "")) == s.hit_target_id:
					matched_extra = et
					var ext_dmg_res := _apply_damage_to_extra_target(s, et, 1.0, "direct")
					s.damage_applied = float(ext_dmg_res.get("raw_damage", 0.0))
					s.shield_damage_applied = float(ext_dmg_res.get("shield_absorbed", 0.0))
					s.damage_to_hull = float(ext_dmg_res.get("hull_damage", 0.0))
					_log("damage", "Damage calculated on %s: %.2f (armor %s, shield %s %.2f/%.2f) -> hull %.2f / %.2f" % [
						str(et.get("name", s.hit_target_id)), s.damage_applied, str(et.get("armor", "N")),
						str(ext_dmg_res.get("shield_class", "none")), float(ext_dmg_res.get("shield_remaining", 0.0)),
						float(ext_dmg_res.get("shield_max", 0.0)), float(ext_dmg_res.get("hull_remaining", 0.0)),
						float(ext_dmg_res.get("hull_max", s.target_health_max))
					])
					break
			if matched_extra.is_empty():
				var fallback_res := _apply_primary_damage(s, s.damage_value, "direct")
				s.damage_applied = float(fallback_res.get("raw_damage", 0.0))
				s.shield_damage_applied = float(fallback_res.get("shield_absorbed", 0.0))
				s.damage_to_hull = float(fallback_res.get("hull_damage", 0.0))
		else:
			var raw_prim := _damage_for_actor_from_shot(s, s.target_armor, s.target_shield_class, s.target_state.shield_current if s.target_state != null else s.target_shield)
			var prim_res := _apply_primary_damage(s, raw_prim, "direct")
			s.damage_applied = float(prim_res.get("raw_damage", raw_prim))
			s.shield_damage_applied = float(prim_res.get("shield_absorbed", 0.0))
			s.damage_to_hull = float(prim_res.get("hull_damage", 0.0))
			_log("damage", "Damage calculated: %.2f (armor class %s, shield class %s %.2f/%.2f) -> target hull %.2f / %.2f" % [
				s.damage_applied, s.target_armor, s.target_shield_class if s.target_shield_class != "" else "none",
				s.target_shield, s.target_shield_max, s.target_health, s.target_health_max
			])
		if s.damage_radius > 0.0:
			_apply_multi_target_splash(s, s.hit_target_id)
		if s.render_name != "":
			_log("particles", "Impact render reference: %s" % s.render_name)
		else:
			_log("particles", "No ordnance renderName declared; explosion particleClass is not resolved in this slice.")
	elif kind == "obstacle":
		_log("collision", "Obstacle impact (%s) at %s — shot blocked" % [s.hit_obstacle_id, _fmt_vec(s.position)])
		_log("explosion", "Obstacle explosion ODF: %s" % (s.xpl_ground if s.xpl_ground != "" else "(none declared)"))
		if s.damage_radius > 0.0:
			_apply_multi_target_splash(s, "")
	elif kind == "ground":
		_log("collision", "Ground impact at %s" % _fmt_vec(s.position))
		_log("explosion", "Ground explosion ODF: %s" % (s.xpl_ground if s.xpl_ground != "" else "(none declared)"))
		if s.damage_radius > 0.0:
			_apply_multi_target_splash(s, "")
	elif kind == "expire":
		_log("expire", "Ordnance expired after %.3f s at %s" % [s.age, _fmt_vec(s.position)])
		_log("explosion", "Expiration explosion ODF: %s" % (s.xpl_expire if s.xpl_expire != "" else "(none declared)"))
	shot_finished.emit({
		"shot_id": s.shot_id,
		"spawn_time": s.spawn_time,
		"impact_time": s.impact_time if s.impact_time >= 0.0 else sim_time,
		"kind": kind,
		"hit_target_id": s.hit_target_id,
		"hit_obstacle_id": s.hit_obstacle_id,
		"position": s.position,
		"age": s.age,
		"damage": s.damage_applied,
		"damage_to_hull": s.damage_to_hull,
		"shield_damage": s.shield_damage_applied,
		"shield_remaining": s.target_shield,
		"shield_class": s.target_shield_class,
		"hit_normal": s.hit_normal,
		"ammo_cost": s.ammo_cost,
		"ammo_spent": s.ammo_spent,
		"energy_cost": s.energy_cost,
		"energy_spent": s.energy_spent,
		"shooter_ammo_remaining": s.shooter_ammo_remaining,
		"shooter_energy_remaining": s.shooter_energy_remaining,
		"splash_hits": s.splash_hits,
		"target_health": s.target_health,
		"ordnance": s.ordnance_name,
	})


func _shield_ratio_for(s: Shot, sclass: String) -> float:
	var sc := sclass.strip_edges().to_upper().substr(0, 1) if sclass != "" else ""
	if sc == "":
		return 1.0
	var base := 1.0
	match sc:
		"S": base = 0.75
		"D": base = 0.5
		"N", "A": base = 1.0
	return maxf(0.0, base * s.damage_shield_mult)


func _damage_for_actor_from_shot(s: Shot, armor: String, sclass: String, shield_cur: float) -> float:
	if s.damage_table.is_empty():
		return s.damage_value
	var key := armor if armor != "" else "N"
	var sc := sclass.strip_edges().to_upper().substr(0, 1) if sclass != "" else ""
	if sc != "" and shield_cur > 0.0 and s.damage_table.has(sc):
		key = sc
	return float(s.damage_table.get(key, s.damage_table.get("N", s.damage_value)))


## Apply damage to the primary target (using persistent CombatActorState when
## bound, or shot-local fallback for single-shot run_once tests).
func _apply_primary_damage(s: Shot, raw_damage: float, dmg_kind: String) -> Dictionary:
	if s.target_state != null:
		var ratio := _shield_ratio_for(s, str(s.target_state.shield_class))
		var res: Dictionary = s.target_state.apply_damage(raw_damage, ratio, dmg_kind)
		s.target_shield = float(s.target_state.shield_current)
		s.target_shield_max = float(s.target_state.shield_max)
		s.target_shield_class = str(s.target_state.shield_class)
		s.target_health = float(s.target_state.hull_current)
		s.target_health_max = float(s.target_state.hull_max)
		if float(res.get("shield_absorbed", 0.0)) > 0.0:
			_log("damage", "Shield class %s absorbed %.2f (ratio %.2f), spill to hull %.2f, shield %.2f / %.2f (APPROXIMATED)" % [
				s.target_shield_class, float(res.shield_absorbed), ratio, float(res.hull_damage), s.target_shield, s.target_shield_max
			])
		return res
	var to_hull := _apply_shield(s, raw_damage)
	s.target_health = maxf(0.0, s.target_health - to_hull)
	return {
		"raw_damage": raw_damage,
		"shield_absorbed": s.shield_damage_applied,
		"shield_remaining": s.target_shield,
		"shield_max": s.target_shield_max,
		"shield_class": s.target_shield_class,
		"hull_damage": to_hull,
		"hull_remaining": s.target_health,
		"hull_max": s.target_health_max,
	}


## Apply direct or splash damage to an extra target using ITS OWN armor and
## shield state (never leaking primary target shield parameters).
func _apply_damage_to_extra_target(s: Shot, et: Dictionary, falloff: float, dmg_kind: String) -> Dictionary:
	var actor_any = et.get("actor_state", null)
	if actor_any != null and actor_any is RefCounted and actor_any.has_method("apply_damage"):
		var actor = actor_any
		var base_dmg := _damage_for_actor_from_shot(s, str(actor.armor_class), str(actor.shield_class), float(actor.shield_current))
		var raw := base_dmg * falloff
		var ratio := _shield_ratio_for(s, str(actor.shield_class))
		var res: Dictionary = actor.apply_damage(raw, ratio, dmg_kind)
		et["health"] = float(actor.hull_current)
		et["max_health"] = float(actor.hull_max)
		et["shield"] = float(actor.shield_current)
		et["max_shield"] = float(actor.shield_max)
		et["shield_class"] = str(actor.shield_class)
		et["destroyed"] = bool(actor.destroyed)
		return res
	var armor := str(et.get("armor", "N"))
	var sh_max := maxf(0.0, float(et.get("max_shield", 0.0)))
	var sh_cur := maxf(0.0, float(et.get("shield", sh_max)))
	var sh_cls := str(et.get("shield_class", ""))
	var hp_max := maxf(1.0, float(et.get("max_health", s.target_health_max)))
	var hp_cur := maxf(0.0, float(et.get("health", hp_max)))
	var raw_d := _damage_for_actor_from_shot(s, armor, sh_cls, sh_cur) * falloff
	var absorbed := 0.0
	var to_hull := raw_d
	if sh_cur > 0.0 and sh_max > 0.0 and raw_d > 0.0:
		var r := maxf(0.0001, _shield_ratio_for(s, sh_cls))
		var sh_hit := raw_d * r
		absorbed = minf(sh_cur, sh_hit)
		sh_cur = maxf(0.0, sh_cur - absorbed)
		var spill := maxf(0.0, sh_hit - absorbed)
		to_hull = raw_d * (spill / sh_hit)
	hp_cur = maxf(0.0, hp_cur - to_hull)
	et["shield"] = sh_cur
	et["max_shield"] = sh_max
	et["shield_class"] = sh_cls
	et["health"] = hp_cur
	et["max_health"] = hp_max
	return {
		"raw_damage": raw_d,
		"shield_absorbed": absorbed,
		"shield_remaining": sh_cur,
		"shield_max": sh_max,
		"shield_class": sh_cls,
		"hull_damage": to_hull,
		"hull_remaining": hp_cur,
		"hull_max": hp_max,
	}


## Consume shield before hull. Shield ratio follows the documented BZCC
## mapping (N/A=1, S=0.75, D=0.5) multiplied by ordnance DamageShield; this is
## an APPROXIMATED preview model, not native engine damage.
func _apply_shield(s: Shot, raw_damage: float) -> float:
	if s.target_shield <= 0.0 or s.target_shield_max <= 0.0:
		return raw_damage
	var ratio := maxf(0.0001, s.shield_damage_ratio)
	var shield_hit := raw_damage * ratio
	var absorbed := minf(s.target_shield, shield_hit)
	s.target_shield = maxf(0.0, s.target_shield - absorbed)
	s.shield_damage_applied = absorbed
	var spill := maxf(0.0, shield_hit - absorbed)
	var hull_damage := raw_damage * spill / maxf(0.0001, shield_hit)
	_log("damage", "Shield class %s absorbed %.2f (ratio %.2f), spill to hull %.2f, shield %.2f / %.2f (APPROXIMATED)" % [
		s.target_shield_class if s.target_shield_class != "" else "none", absorbed, ratio, hull_damage, s.target_shield, s.target_shield_max
	])
	return hull_damage


## Collision normal from the resolved impact point. Spheres/BBoxes use the
## outward vector from the hit centre; ground uses +Y.
func _hit_normal(s: Shot, kind: String) -> Vector3:
	if kind == "ground":
		return Vector3.UP
	if kind == "expire":
		return Vector3.ZERO
	var center := s.target_position
	if kind == "vehicle" and s.target_half_extents.length_squared() > 0.0001:
		center = s.target_bbox_center
	elif kind == "obstacle":
		for obs in s.obstacles:
			if obs is Dictionary and str(obs.get("id", "")) == s.hit_obstacle_id:
				center = obs.get("position", center)
				break
	var outward := s.position - center
	if outward.length_squared() < 0.000001:
		return -s.velocity.normalized()
	return outward.normalized()


func _apply_multi_target_splash(s: Shot, skip_target_id: String) -> void:
	if s.damage_radius <= 0.0:
		return
	if skip_target_id != "primary":
		var d := s.position.distance_to(s.target_position)
		if d <= s.damage_radius:
			var falloff := clampf(1.0 - (d / s.damage_radius), 0.0, 1.0)
			var base_p := _damage_for_actor_from_shot(s, s.target_armor, s.target_shield_class, s.target_state.shield_current if s.target_state != null else s.target_shield)
			var splash := base_p * falloff
			if splash > 0.001:
				var pres := _apply_primary_damage(s, splash, "splash")
				if skip_target_id == "":
					s.damage_applied = splash
					s.shield_damage_applied = float(pres.get("shield_absorbed", 0.0))
					s.damage_to_hull = float(pres.get("hull_damage", 0.0))
				s.splash_hits.append({
					"id": "primary",
					"distance": d,
					"damage": splash,
					"shield_damage": float(pres.get("shield_absorbed", 0.0)),
					"shield_remaining": float(pres.get("shield_remaining", s.target_shield)),
					"damage_to_hull": float(pres.get("hull_damage", 0.0)),
					"health": s.target_health,
				})
				_log("damage", "Splash damage on primary (linear falloff, APPROXIMATED): %.2f at %.2f m -> shield %.2f, hull %.2f" % [
					splash, d, s.target_shield, s.target_health
				])
	for et in s.extra_targets:
		if not (et is Dictionary):
			continue
		var tid := str(et.get("id", ""))
		if tid == skip_target_id:
			continue
		var epos: Vector3 = et.get("position", Vector3.ZERO)
		var d2 := s.position.distance_to(epos)
		if d2 <= s.damage_radius:
			var fall2 := clampf(1.0 - (d2 / s.damage_radius), 0.0, 1.0)
			if fall2 > 0.0001:
				var eres := _apply_damage_to_extra_target(s, et, fall2, "splash")
				var sp2 := float(eres.get("raw_damage", 0.0))
				if sp2 > 0.001:
					s.splash_hits.append({
						"id": tid,
						"distance": d2,
						"damage": sp2,
						"shield_damage": float(eres.get("shield_absorbed", 0.0)),
						"shield_remaining": float(eres.get("shield_remaining", 0.0)),
						"damage_to_hull": float(eres.get("hull_damage", 0.0)),
						"health": float(eres.get("hull_remaining", et.get("health", 0.0))),
					})
					_log("damage", "Splash damage on %s (linear falloff, APPROXIMATED): %.2f at %.2f m -> shield %.2f, hull %.2f" % [
						str(et.get("name", tid)), sp2, d2, float(eres.get("shield_remaining", 0.0)), float(eres.get("hull_remaining", 0.0))
					])


func _ray_ramp(origin: Vector3, delta: Vector3, center: Vector3, size: Vector3, radius: float):
	# Sloped terrain wedge rising from y = bottom at front (+Z) to y = bottom + size.y at back (-Z).
	var half := size * 0.5
	var box_t = _ray_aabb(origin, delta, center, half + Vector3(radius, radius, radius))
	if box_t == null:
		return null
	var steps := 12
	var t0 := float(box_t)
	var bottom_y := center.y - half.y
	for i in range(steps + 1):
		var t := lerpf(t0, 1.0, float(i) / float(steps))
		var pt := origin + delta * t
		if absf(pt.x - center.x) <= half.x + radius and absf(pt.z - center.z) <= half.z + radius:
			var z_frac := clampf((center.z + half.z - pt.z) / maxf(0.05, size.z), 0.0, 1.0)
			var surf_y := bottom_y + size.y * z_frac
			if pt.y <= surf_y + radius and pt.y >= bottom_y - radius:
				return t
	return null


func _log(kind: String, text: String) -> void:
	var e := {"time": sim_time, "kind": kind, "text": text}
	events.append(e)
	event_logged.emit(sim_time, kind, text)


func _ray_sphere(origin: Vector3, dir: Vector3, center: Vector3, radius: float):
	var oc := origin - center
	var a := dir.dot(dir)
	if a < 0.0000001:
		return null
	var b := 2.0 * oc.dot(dir)
	var c := oc.dot(oc) - radius * radius
	if c <= 0.0:
		return 0.0  # origin already inside the collider
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return null
	var t := (-b - sqrt(disc)) / (2.0 * a)
	if t < 0.0 or t > 1.0:
		return null
	return t


func _ray_aabb(origin: Vector3, delta: Vector3, center: Vector3, half_extents: Vector3):
	var bmin := center - half_extents
	var bmax := center + half_extents
	var tmin := 0.0
	var tmax := 1.0
	for axis in range(3):
		var o := origin[axis]
		var d := delta[axis]
		if absf(d) < 0.0000001:
			if o < bmin[axis] or o > bmax[axis]:
				return null
		else:
			var inv := 1.0 / d
			var t1 := (bmin[axis] - o) * inv
			var t2 := (bmax[axis] - o) * inv
			if t1 > t2:
				var tmp := t1
				t1 = t2
				t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return null
	if tmin < 0.0 or tmin > 1.0:
		return null
	return tmin


func _ray_obb(origin: Vector3, delta: Vector3, center: Vector3, half_extents: Vector3, yaw_rad: float = 0.0):
	if absf(yaw_rad) < 0.0001:
		return _ray_aabb(origin, delta, center, half_extents)
	var local_origin := (origin - center).rotated(Vector3.UP, -yaw_rad)
	var local_delta := delta.rotated(Vector3.UP, -yaw_rad)
	return _ray_aabb(local_origin, local_delta, Vector3.ZERO, half_extents)


func _fmt_vec(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]


func telemetry_text() -> String:
	var lines: Array[String] = []
	for e in events:
		lines.append("%07.3f  %-11s %s" % [float(e.time), str(e.kind), str(e.text)])
	return "\n".join(lines)


## Headless helper used by tests: run one shot to completion.
static func run_once(profile: WeaponProfile, origin: Vector3, direction: Vector3, target: Vector3,
		max_time: float = 5.0, p_extra_targets: Array = [], p_obstacles: Array = []) -> Dictionary:
	var sim := ProjectileSim.new(1234)
	var s := sim.spawn(profile, origin, direction, target, -1.0, p_extra_targets, p_obstacles)
	var steps := 0
	while s.alive and sim.sim_time < max_time:
		sim.advance(1.0 / 60.0)
		steps += 1
		if steps > 100000:
			break
	return {
		"kind": s.hit_kind,
		"hit_target_id": s.hit_target_id,
		"hit_obstacle_id": s.hit_obstacle_id,
		"damage": s.damage_applied,
		"damage_to_hull": s.damage_to_hull,
		"shield_damage": s.shield_damage_applied,
		"shield_remaining": s.target_shield,
		"shield_class": s.target_shield_class,
		"hit_normal": s.hit_normal,
		"ammo_cost": s.ammo_cost,
		"ammo_spent": s.ammo_spent,
		"target_health": s.target_health,
		"time": s.age,
		"events": sim.events,
		"position": s.position,
	}
