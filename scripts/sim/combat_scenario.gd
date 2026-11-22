class_name CombatScenario
extends RefCounted
## Persistent deterministic combat scenario owning shooter + multiple targets +
## ProjectileSim state across sequential shots and replays (P1-SIM-01..03).

const ActorStateScript = preload("res://scripts/sim/combat_actor_state.gd")

var seed_value: int = 1337
var sim: ProjectileSim
var shooter = null
var targets: Dictionary = {}  # actor_id -> CombatActorState ("primary" + secondary ids)
var obstacles: Array = []
var shot_history: Array[Dictionary] = []
var _initial_shooter_snap: Dictionary = {}
var _initial_target_snaps: Dictionary = {}


func _init(p_seed: int = 1337) -> void:
	seed_value = p_seed
	sim = ProjectileSim.new(p_seed)
	shooter = ActorStateScript.create_shooter("shooter_a", "Shooter A")
	targets["primary"] = ActorStateScript.create_target("primary", "Target B")


func configure_from_profile(profile: WeaponProfile, target_pos: Vector3 = Vector3(0, 0, -50),
		preserve_state: bool = false) -> void:
	if profile == null:
		return
	profile.refresh()
	var prev_shooter_ammo: int = int(shooter.ammo_current) if shooter != null else 0
	var prev_shooter_energy: float = float(shooter.energy_current) if shooter != null else 0.0
	var prev_primary = targets.get("primary", null)
	var prev_hull := float(prev_primary.hull_current) if prev_primary != null else profile.target_health_max
	var prev_shield := float(prev_primary.shield_current) if prev_primary != null else profile.target_shield_max
	var prev_destroyed := bool(prev_primary.destroyed) if prev_primary != null else false

	shooter = ActorStateScript.create_shooter(
		"shooter_a",
		profile.shooter_path.get_file().get_basename() if profile.shooter_path != "" else "Shooter A",
		profile.shooter_ammo_max,
		profile.shooter_energy_max,
		profile.shooter_health_max,
		profile.shooter_armor,
		profile.shot_delay
	)
	var primary = ActorStateScript.create_target(
		"primary",
		profile.target_name if profile.target_name != "" else "Target B",
		profile.target_health_max,
		profile.target_armor,
		profile.target_shield_max,
		profile.target_shield_class,
		target_pos,
		profile.target_radius
	)
	primary.half_extents = profile.target_half_extents
	primary.bbox_offset = profile.target_bbox_offset
	primary.yaw_rad = profile.target_yaw_rad

	if preserve_state:
		if not shooter.ammo_unlimited:
			shooter.ammo_current = mini(shooter.ammo_max, prev_shooter_ammo)
		if not shooter.energy_unlimited:
			shooter.energy_current = minf(shooter.energy_max, prev_shooter_energy)
		primary.hull_current = minf(primary.hull_max, prev_hull)
		primary.shield_current = minf(primary.shield_max, prev_shield)
		primary.destroyed = prev_destroyed and primary.hull_current <= 0.0001

	targets["primary"] = primary
	capture_initial_snapshots()


func add_or_update_target(actor) -> void:
	if actor == null or str(actor.actor_id) == "":
		return
	targets[actor.actor_id] = actor
	_initial_target_snaps[actor.actor_id] = actor.snapshot()


func remove_target(actor_id: String) -> void:
	if actor_id == "primary":
		return
	targets.erase(actor_id)
	_initial_target_snaps.erase(actor_id)


func primary_target():
	return targets.get("primary", null)


func capture_initial_snapshots() -> void:
	if shooter != null:
		_initial_shooter_snap = shooter.snapshot()
	_initial_target_snaps.clear()
	for tid in targets:
		var t = targets[tid]
		if t != null:
			_initial_target_snaps[tid] = t.snapshot()


func reset(scope: String = "ALL") -> void:
	if scope == "ALL" or scope == "SHOOTER":
		if shooter != null:
			if not _initial_shooter_snap.is_empty():
				shooter.restore_snapshot(_initial_shooter_snap)
			else:
				shooter.reset_to_initial()
	if scope == "ALL" or scope == "TARGETS":
		for tid in targets:
			var t = targets[tid]
			if t == null:
				continue
			if _initial_target_snaps.has(tid):
				t.restore_snapshot(_initial_target_snaps[tid])
			else:
				t.reset_to_initial()
	if scope == "ALL":
		sim.reset()
		shot_history.clear()


## Build extra_targets array synchronized with persistent CombatActorState entries.
func extra_target_dicts() -> Array:
	var out: Array = []
	for tid in targets:
		if tid == "primary":
			continue
		var t = targets[tid]
		if t == null:
			continue
		out.append({
			"id": t.actor_id,
			"name": t.display_name,
			"position": t.position,
			"radius": t.radius,
			"half_extents": t.half_extents,
			"yaw_rad": t.yaw_rad,
			"armor": t.armor_class,
			"health": t.hull_current,
			"max_health": t.hull_max,
			"shield": t.shield_current,
			"max_shield": t.shield_max,
			"shield_class": t.shield_class,
			"actor_state": t,
		})
	return out


## Fire one shot using shooter-owned ammo/energy and persistent target states.
func fire_shot(profile: WeaponProfile, origin: Vector3, direction: Vector3,
		target_position: Vector3, p_obstacles: Array = [],
		shooter_velocity: Vector3 = Vector3.ZERO,
		enforce_reload: bool = false, p_extra_targets: Array = []) -> Dictionary:
	if profile == null:
		return {"ok": false, "reason": "NO_PROFILE", "shot": null}
	profile.refresh()
	var chk: Dictionary = shooter.can_fire(profile.ammo_cost, profile.weapon_energy_cost, enforce_reload)
	if not bool(chk.get("ok", false)):
		return {
			"ok": false,
			"reason": str(chk.get("reason", "FIRE_REJECTED")),
			"ammo_remaining": shooter.ammo_current,
			"energy_remaining": shooter.energy_current,
			"shot": null,
		}
	var res: Dictionary = shooter.consume_fire_resources(profile.ammo_cost, profile.weapon_energy_cost, profile.shot_delay)
	var extras := p_extra_targets if not p_extra_targets.is_empty() else extra_target_dicts()
	var prim = primary_target()
	var shot := sim.spawn(
		profile, origin, direction, target_position,
		prim.hull_current if prim != null else -1.0,
		extras, p_obstacles, shooter_velocity,
		shooter, prim
	)
	shot.ammo_spent = int(res.get("ammo_spent", 0))
	shot.energy_spent = float(res.get("energy_spent", 0.0))
	shot.shooter_ammo_remaining = shooter.ammo_current
	shot.shooter_energy_remaining = shooter.energy_current
	var record := {
		"origin": origin,
		"direction": direction,
		"target_position": target_position,
		"shooter_velocity": shooter_velocity,
		"weapon_name": profile.weapon_name,
		"ordnance_name": profile.ordnance_name,
		"ammo_spent": shot.ammo_spent,
		"energy_spent": shot.energy_spent,
		"time": sim.sim_time,
	}
	shot_history.append(record)
	return {
		"ok": true,
		"reason": "",
		"shot": shot,
		"ammo_spent": shot.ammo_spent,
		"energy_spent": shot.energy_spent,
		"ammo_remaining": shooter.ammo_current,
		"energy_remaining": shooter.energy_current,
	}


## Fire one shot and step until resolution (used by deterministic headless tests
## and replay verification).
func fire_and_resolve(profile: WeaponProfile, origin: Vector3, direction: Vector3,
		target_position: Vector3, max_time: float = 5.0,
		p_obstacles: Array = [], shooter_velocity: Vector3 = Vector3.ZERO) -> Dictionary:
	var fired := fire_shot(profile, origin, direction, target_position, p_obstacles, shooter_velocity, false)
	if not bool(fired.get("ok", false)):
		return fired
	var s = fired.get("shot", null)
	var steps := 0
	var t_start := sim.sim_time
	while s != null and s.alive and (sim.sim_time - t_start) < max_time:
		advance(1.0 / 60.0)
		steps += 1
		if steps > 100000:
			break
	var prim = primary_target()
	return {
		"ok": true,
		"kind": s.hit_kind if s != null else "",
		"hit_target_id": s.hit_target_id if s != null else "",
		"damage": s.damage_applied if s != null else 0.0,
		"damage_to_hull": s.damage_to_hull if s != null else 0.0,
		"shield_damage": s.shield_damage_applied if s != null else 0.0,
		"shield_remaining": prim.shield_current if prim != null else 0.0,
		"hull_remaining": prim.hull_current if prim != null else 0.0,
		"ammo_cost": s.ammo_cost if s != null else 0,
		"ammo_spent": int(fired.get("ammo_spent", 0)),
		"ammo_remaining": shooter.ammo_current,
		"energy_spent": float(fired.get("energy_spent", 0.0)),
		"energy_remaining": shooter.energy_current,
		"splash_hits": s.splash_hits if s != null else [],
		"destroyed": prim.destroyed if prim != null else false,
	}


func advance(dt: float) -> void:
	sim.advance(dt)
	if shooter != null:
		shooter.tick(dt)
	for tid in targets:
		var t = targets[tid]
		if t != null:
			t.tick(dt)


## Deterministically replay the recorded shot_history from the captured initial
## snapshots and return the final state summary.
func replay_deterministic(profile: WeaponProfile, p_obstacles: Array = []) -> Dictionary:
	var saved_history := shot_history.duplicate(true)
	reset("ALL")
	var results: Array[Dictionary] = []
	for rec in saved_history:
		var r := fire_and_resolve(
			profile,
			rec.get("origin", Vector3.ZERO),
			rec.get("direction", Vector3.FORWARD),
			rec.get("target_position", Vector3(0, 0, -50)),
			5.0,
			p_obstacles,
			rec.get("shooter_velocity", Vector3.ZERO)
		)
		results.append(r)
	var target_states := {}
	for tid in targets:
		var t = targets[tid]
		if t != null:
			target_states[tid] = {
				"hull": t.hull_current,
				"shield": t.shield_current,
				"destroyed": t.destroyed,
			}
	return {
		"shots_replayed": results.size(),
		"results": results,
		"shooter_ammo": shooter.ammo_current,
		"shooter_energy": shooter.energy_current,
		"targets": target_states,
	}
