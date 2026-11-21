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

class Shot:
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
	var shield_damage_applied: float = 0.0
	var damage_to_hull: float = 0.0
	var ammo_cost: int = 0
	var ammo_spent: int = 0
	var splash_hits: Array[Dictionary] = []
	var extra_targets: Array = []
	var obstacles: Array = []


var events: Array[Dictionary] = []
var shots: Array = []
var sim_time: float = 0.0
var rng := RandomNumberGenerator.new()
var seed_value: int = 1337


func _init(p_seed: int = 1337) -> void:
	seed_value = p_seed
	rng.seed = p_seed


func reset() -> void:
	events.clear()
	shots.clear()
	sim_time = 0.0
	rng.seed = seed_value


func spawn(profile: WeaponProfile, origin: Vector3, direction: Vector3, target_position: Vector3,
		target_health: float = -1.0, p_extra_targets: Array = [], p_obstacles: Array = [],
		shooter_velocity: Vector3 = Vector3.ZERO) -> Shot:
	profile.refresh()
	var s := Shot.new()
	s.origin = origin
	s.position = origin
	s.previous = origin
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
	s.damage_value = profile.expected_damage_for_target()
	s.damage_radius = profile.damage_radius
	s.target_shield_max = profile.target_shield_max
	s.target_shield = profile.target_shield_max
	s.target_shield_class = profile.target_shield_class
	s.shield_damage_ratio = profile.shield_damage_ratio()
	s.ammo_cost = profile.ammo_cost
	s.ammo_spent = mini(s.ammo_cost, profile.target_ammo_max if profile.target_ammo_max > 0 else s.ammo_cost)
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
	s.target_health = profile.target_health_max if target_health < 0.0 else target_health
	s.target_health_max = profile.target_health_max
	s.target_armor = profile.target_armor
	s.xpl_vehicle = profile.xpl_vehicle
	s.xpl_ground = profile.xpl_ground
	s.xpl_expire = profile.xpl_expire
	s.render_name = profile.render_name
	s.shot_sound = profile.shot_sound
	s.weapon_name = profile.weapon_name
	s.ordnance_name = profile.ordnance_name
	s.extra_targets = p_extra_targets
	s.obstacles = p_obstacles
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


func advance(dt: float) -> void:
	var remaining := dt
	while remaining > 0.0 and not shots.is_empty():
		var step: float = minf(SUBSTEP, remaining)
		remaining -= step
		sim_time += step
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
			_check_shot(s, step)
		shots = shots.filter(func(x): return x.alive)


func _check_shot(s: Shot, step: float) -> void:
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
		return
	s.position = s.previous + delta * clampf(best_t, 0.0, 1.0)
	s.hit_target_id = hit_tid
	s.hit_obstacle_id = hit_oid
	s.hit_normal = _hit_normal(s, kind)
	_finish(s, kind)


func _finish(s: Shot, kind: String) -> void:
	s.alive = false
	s.hit_kind = kind
	if kind == "vehicle":
		_log("collision", "Collision detected (%s) at %s" % [s.hit_target_id if s.hit_target_id != "" else "primary", _fmt_vec(s.position)])
		var xpl := s.xpl_vehicle if s.xpl_vehicle != "" else s.xpl_ground
		_log("explosion", "Explosion ODF selected: %s" % (xpl if xpl != "" else "(none declared)"))
		var applied := s.damage_value
		s.damage_applied = applied
		var to_hull := _apply_shield(s, applied)
		s.damage_to_hull = to_hull
		if s.hit_target_id != "" and s.hit_target_id != "primary":
			var matched_extra: Dictionary = {}
			for et in s.extra_targets:
				if et is Dictionary and str(et.get("id", "")) == s.hit_target_id:
					var hp_cur := float(et.get("health", s.target_health_max))
					var hp_max := float(et.get("max_health", s.target_health_max))
					et["health"] = maxf(0.0, hp_cur - to_hull)
					matched_extra = et
					_log("damage", "Damage calculated on %s: %.2f (armor class %s, shield class %s) -> hull %.2f / %.2f" % [
						str(et.get("name", s.hit_target_id)), applied, str(et.get("armor", s.target_armor)),
						s.target_shield_class, float(et["health"]), hp_max
					])
					break
			if matched_extra.is_empty():
				s.target_health = max(0.0, s.target_health - to_hull)
		else:
			s.target_health = max(0.0, s.target_health - to_hull)
			_log("damage", "Damage calculated: %.2f (armor class %s, shield class %s) -> target hull %.2f / %.2f" % [
				applied, s.target_armor, s.target_shield_class if s.target_shield_class != "" else "none",
				s.target_health, s.target_health_max
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
		"splash_hits": s.splash_hits,
		"target_health": s.target_health,
		"ordnance": s.ordnance_name,
	})


## Consume shield before hull. Shield ratio follows the documented BZCC
## mapping (N/A=1, S=0.75, D=0.5) multiplied by ordnance DamageShield; this is
## an APPROXIMATED preview model, not native engine damage.
func _apply_shield(s: Shot, raw_damage: float) -> float:
	if s.target_shield_max <= 0.0 or s.target_shield_class == "":
		return raw_damage
	var shield_hit := raw_damage * s.shield_damage_ratio
	var absorbed := minf(s.target_shield, shield_hit)
	s.target_shield = maxf(0.0, s.target_shield - absorbed)
	s.shield_damage_applied = absorbed
	var spill := maxf(0.0, shield_hit - absorbed)
	var hull_damage := raw_damage * spill / maxf(0.0001, shield_hit)
	_log("damage", "Shield class %s absorbed %.2f (ratio %.2f), spill to hull %.2f, shield %.2f / %.2f (APPROXIMATED)" % [
		s.target_shield_class, absorbed, s.shield_damage_ratio, hull_damage, s.target_shield, s.target_shield_max
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
			var splash := s.damage_value * falloff
			if splash > 0.001:
				if skip_target_id == "":
					s.damage_applied = splash
				s.target_health = maxf(0.0, s.target_health - splash)
				s.splash_hits.append({"id": "primary", "distance": d, "damage": splash, "health": s.target_health})
				_log("damage", "Splash damage on primary (linear falloff, APPROXIMATED): %.2f at %.2f m -> hull %.2f" % [
					splash, d, s.target_health
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
			var sp2 := s.damage_value * fall2
			if sp2 > 0.001:
				var hp_cur := float(et.get("health", s.target_health_max))
				et["health"] = maxf(0.0, hp_cur - sp2)
				s.splash_hits.append({"id": tid, "distance": d2, "damage": sp2, "health": float(et["health"])})
				_log("damage", "Splash damage on %s (linear falloff, APPROXIMATED): %.2f at %.2f m -> hull %.2f" % [
					str(et.get("name", tid)), sp2, d2, float(et["health"])
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
