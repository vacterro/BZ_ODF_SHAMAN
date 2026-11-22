class_name CombatScenario
extends RefCounted
## Persistent deterministic combat scenario owning shooter + multiple targets +
## ProjectileSim state, single simulation clock, combat event stream, and
## immutable replay snapshots (P0-SIM-01, P0-SIM-02, P1-SIM-03, P1-SIM-04).

signal combat_event(ev: Dictionary)

const ActorStateScript = preload("res://scripts/sim/combat_actor_state.gd")

var scenario_id: String = ""
var seed_value: int = 1337
var sim: ProjectileSim
var shooter = null
var targets: Dictionary = {}  # actor_id -> CombatActorState ("primary" + secondary ids)
var obstacles: Array = []
var shot_history: Array[Dictionary] = []
var timeline_inputs: Array[Dictionary] = []
var combat_events: Array[Dictionary] = []
var saved_replay_snapshots: Array[Dictionary] = []

var _initial_shooter_snap: Dictionary = {}
var _initial_target_snaps: Dictionary = {}
var _initial_obstacles_snap: Array = []
var _initial_profile_snap: Dictionary = {}
var _last_profile_snap: Dictionary = {}
var _baseline_captured: bool = false

static var _seq := 0


func _init(p_seed: int = 1337, p_scenario_id: String = "") -> void:
	_seq += 1
	seed_value = p_seed
	scenario_id = p_scenario_id if p_scenario_id != "" else "scn_%d_%d" % [p_seed, _seq]
	sim = ProjectileSim.new(p_seed)
	sim.shot_finished.connect(_on_sim_shot_finished)
	shooter = ActorStateScript.create_shooter("shooter_a", "Shooter A")
	targets["primary"] = ActorStateScript.create_target("primary", "Target B")


func _emit_combat_event(kind: String, detail: String, actor_id: String = "",
		odf_path: String = "", odf_key: String = "", extra: Dictionary = {}) -> Dictionary:
	var ev := {
		"time": sim.sim_time,
		"kind": kind,
		"actor_id": actor_id,
		"detail": detail,
		"odf_path": odf_path,
		"odf_key": odf_key,
		"approximated": true,
	}
	for k in extra:
		ev[k] = extra[k]
	combat_events.append(ev)
	combat_event.emit(ev)
	return ev


## Explicit lifecycle op 1: Create a brand-new scenario from profile and capture
## a fresh initial replay baseline.
func create_new_scenario(profile: WeaponProfile, target_pos: Vector3 = Vector3(0, 0, -50),
		p_obstacles: Array = []) -> void:
	if not p_obstacles.is_empty():
		obstacles = _clone_obstacles(p_obstacles)
	configure_from_profile(profile, target_pos, false)


## Explicit lifecycle op 2: Update effective ODF parameters in place without
## redefining the initial replay baseline or discarding active cooldown/effects
## (P1-SIM-04).
func update_effective_odf_parameters(profile: WeaponProfile, target_pos = null) -> void:
	if profile == null:
		return
	profile.refresh()
	if shooter == null or primary_target() == null or not _baseline_captured:
		configure_from_profile(profile, target_pos if target_pos is Vector3 else Vector3(0, 0, -50), false)
		return
	var prev_ammo_max: int = shooter.ammo_max
	var prev_energy_max: float = shooter.energy_max
	shooter.display_name = profile.shooter_path.get_file().get_basename() if profile.shooter_path != "" else shooter.display_name
	shooter.weapon_name = profile.weapon_name
	shooter.hull_max = maxf(1.0, profile.shooter_health_max)
	shooter.hull_current = minf(shooter.hull_current, shooter.hull_max)
	shooter.armor_class = profile.shooter_armor
	shooter.ammo_max = maxi(0, profile.shooter_ammo_max)
	shooter.ammo_unlimited = shooter.ammo_max <= 0
	if not shooter.ammo_unlimited:
		if prev_ammo_max <= 0:
			shooter.ammo_current = shooter.ammo_max
		else:
			shooter.ammo_current = mini(shooter.ammo_current, shooter.ammo_max)
	shooter.energy_max = maxf(0.0, profile.shooter_energy_max)
	shooter.energy_unlimited = shooter.energy_max <= 0.0
	if not shooter.energy_unlimited:
		if prev_energy_max <= 0.0:
			shooter.energy_current = shooter.energy_max
		else:
			shooter.energy_current = minf(shooter.energy_current, shooter.energy_max)
	shooter.shot_delay = maxf(0.0, profile.shot_delay)
	if shooter.reload_remaining > shooter.shot_delay and shooter.shot_delay > 0.0:
		shooter.reload_remaining = shooter.shot_delay

	var prim = primary_target()
	prim.display_name = profile.target_name if profile.target_name != "" else prim.display_name
	prim.hull_max = maxf(1.0, profile.target_health_max)
	prim.hull_current = minf(prim.hull_current, prim.hull_max)
	prim.armor_class = profile.target_armor if profile.target_armor != "" else "N"
	prim.shield_max = maxf(0.0, profile.target_shield_max)
	prim.shield_current = minf(prim.shield_current, prim.shield_max)
	prim.shield_class = profile.target_shield_class
	prim.radius = maxf(0.2, profile.target_radius)
	prim.half_extents = profile.target_half_extents
	prim.bbox_offset = profile.target_bbox_offset
	if target_pos is Vector3:
		prim.position = target_pos
	prim.destroyed = prim.destroyed and prim.hull_current <= 0.0001

	var prof_snap := profile.snapshot_params()
	_last_profile_snap = prof_snap
	timeline_inputs.append({
		"type": "CHANGE_PROFILE",
		"time": sim.sim_time,
		"profile": prof_snap,
	})
	_emit_combat_event("PROFILE_CHANGED", "ODF parameters updated: %s -> %s (baseline preserved)" % [
		profile.weapon_name, profile.ordnance_name
	], "shooter_a", profile.weapon_path, "shotDelay")


## Explicit lifecycle op 3: Swap active weapon during an ongoing experiment
## while preserving shooter resources, active effects, elapsed cooldown (when
## applicable), and the original replay baseline (P1-SIM-04).
func change_weapon(profile: WeaponProfile, preserve_cooldown: bool = true) -> void:
	if profile == null:
		return
	profile.refresh()
	if shooter == null or primary_target() == null or not _baseline_captured:
		configure_from_profile(profile, primary_target().position if primary_target() != null else Vector3(0, 0, -50), false)
		return
	var prev_reload: float = float(shooter.reload_remaining)
	shooter.weapon_name = profile.weapon_name
	shooter.shot_delay = maxf(0.0, profile.shot_delay)
	if preserve_cooldown:
		shooter.reload_remaining = minf(prev_reload, shooter.shot_delay) if shooter.shot_delay > 0.0 else 0.0
	else:
		shooter.reload_remaining = 0.0
	var prof_snap := profile.snapshot_params()
	_last_profile_snap = prof_snap
	timeline_inputs.append({
		"type": "CHANGE_PROFILE",
		"time": sim.sim_time,
		"weapon_swap": true,
		"preserve_cooldown": preserve_cooldown,
		"profile": prof_snap,
	})
	_emit_combat_event("PROFILE_CHANGED", "Weapon changed to %s -> %s (baseline preserved)" % [
		profile.weapon_name, profile.ordnance_name
	], "shooter_a", profile.weapon_path, "ordName")


## Configure scenario from profile. When `preserve_state = true` and a baseline
## was already captured, updates actors in place while keeping the original
## initial replay baseline, active effects, and reload state intact (P1-SIM-04).
func configure_from_profile(profile: WeaponProfile, target_pos: Vector3 = Vector3(0, 0, -50),
		preserve_state: bool = false) -> void:
	if profile == null:
		return
	profile.refresh()
	if preserve_state and _baseline_captured and shooter != null and primary_target() != null:
		update_effective_odf_parameters(profile, target_pos)
		return

	var prev_shooter_ammo: int = int(shooter.ammo_current) if shooter != null else 0
	var prev_shooter_energy: float = float(shooter.energy_current) if shooter != null else 0.0
	var prev_shooter_reload: float = float(shooter.reload_remaining) if shooter != null else 0.0
	var prev_shooter_effects: Array = shooter.active_effects.duplicate(true) if shooter != null else []
	var prev_shooter_pos: Vector3 = shooter.position if shooter != null else Vector3.ZERO
	var prev_shooter_vel: Vector3 = shooter.velocity if shooter != null else Vector3.ZERO
	var prev_shooter_yaw: float = float(shooter.yaw_rad) if shooter != null else 0.0

	var prev_primary = targets.get("primary", null)
	var prev_hull := float(prev_primary.hull_current) if prev_primary != null else profile.target_health_max
	var prev_shield := float(prev_primary.shield_current) if prev_primary != null else profile.target_shield_max
	var prev_destroyed := bool(prev_primary.destroyed) if prev_primary != null else false
	var prev_prim_effects: Array = prev_primary.active_effects.duplicate(true) if prev_primary != null else []

	shooter = ActorStateScript.create_shooter(
		"shooter_a",
		profile.shooter_path.get_file().get_basename() if profile.shooter_path != "" else "Shooter A",
		profile.shooter_ammo_max,
		profile.shooter_energy_max,
		profile.shooter_health_max,
		profile.shooter_armor,
		profile.shot_delay
	)
	shooter.weapon_name = profile.weapon_name
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
		shooter.reload_remaining = prev_shooter_reload
		shooter.position = prev_shooter_pos
		shooter.velocity = prev_shooter_vel
		shooter.yaw_rad = prev_shooter_yaw
		shooter.active_effects = []
		for e_s in prev_shooter_effects:
			if e_s is Dictionary:
				shooter.active_effects.append((e_s as Dictionary).duplicate(true))
		primary.hull_current = minf(primary.hull_max, prev_hull)
		primary.shield_current = minf(primary.shield_max, prev_shield)
		primary.destroyed = prev_destroyed and primary.hull_current <= 0.0001
		primary.active_effects = []
		for e_t in prev_prim_effects:
			if e_t is Dictionary:
				primary.active_effects.append((e_t as Dictionary).duplicate(true))

	targets["primary"] = primary
	_last_profile_snap = profile.snapshot_params()
	if not preserve_state or not _baseline_captured:
		capture_replay_baseline(profile, obstacles)


func add_or_update_target(actor) -> void:
	if actor == null or str(actor.actor_id) == "":
		return
	targets[actor.actor_id] = actor
	if not _initial_target_snaps.has(actor.actor_id):
		_initial_target_snaps[actor.actor_id] = actor.snapshot()


func remove_target(actor_id: String) -> void:
	if actor_id == "primary":
		return
	targets.erase(actor_id)
	_initial_target_snaps.erase(actor_id)


func primary_target():
	return targets.get("primary", null)


func all_actors() -> Array:
	var out: Array = []
	if shooter != null:
		out.append(shooter)
	if targets.has("primary"):
		out.append(targets["primary"])
	for tid in targets:
		if tid != "primary" and targets[tid] != null:
			out.append(targets[tid])
	return out


## Record an actor transform change on the simulation timeline so moving-target
## replays reproduce the exact spatial sequence (P1-SIM-03).
func record_actor_transform(actor_id: String, pos: Vector3, vel: Vector3 = Vector3.ZERO, yaw: float = 0.0) -> void:
	var actor = shooter if actor_id == "shooter_a" else targets.get(actor_id, null)
	if actor == null:
		return
	var changed: bool = not (actor.position as Vector3).is_equal_approx(pos) or not (actor.velocity as Vector3).is_equal_approx(vel) or absf(float(actor.yaw_rad) - yaw) > 0.0005
	actor.position = pos
	actor.velocity = vel
	actor.yaw_rad = yaw
	if actor_id == "primary":
		sim.update_live_target(pos, yaw)
	if changed:
		timeline_inputs.append({
			"type": "MOVE_ACTOR",
			"time": sim.sim_time,
			"actor_id": actor_id,
			"position": [pos.x, pos.y, pos.z],
			"velocity": [vel.x, vel.y, vel.z],
			"yaw_rad": yaw,
			"radius": actor.radius,
			"half_extents": [actor.half_extents.x, actor.half_extents.y, actor.half_extents.z],
			"bbox_offset": [actor.bbox_offset.x, actor.bbox_offset.y, actor.bbox_offset.z],
		})


## Apply a timed status / DoT effect to an actor and record it for replay.
func apply_status_effect(actor_id: String, effect_name: String, dps: float,
		duration_s: float, shield_ratio: float = 1.0) -> bool:
	var actor = shooter if actor_id == "shooter_a" else targets.get(actor_id, null)
	if actor == null or duration_s <= 0.0:
		return false
	actor.add_effect(effect_name, dps, duration_s, shield_ratio)
	timeline_inputs.append({
		"type": "ADD_EFFECT",
		"time": sim.sim_time,
		"actor_id": actor_id,
		"effect_name": effect_name,
		"dps": dps,
		"duration_s": duration_s,
		"shield_ratio": shield_ratio,
	})
	_emit_combat_event("STATUS_EFFECT_APPLIED", "%s applied to %s (%.1f dps for %.2fs, APPROXIMATED)" % [
		effect_name, actor.display_name, dps, duration_s
	], actor_id)
	return true


func capture_initial_snapshots() -> void:
	if shooter != null:
		_initial_shooter_snap = shooter.snapshot()
	_initial_target_snaps.clear()
	for tid in targets:
		var t = targets[tid]
		if t != null:
			_initial_target_snaps[tid] = t.snapshot()
	_initial_obstacles_snap = _clone_obstacles(obstacles)
	_baseline_captured = true


func capture_replay_baseline(profile: WeaponProfile = null, p_obstacles: Array = []) -> Dictionary:
	if not p_obstacles.is_empty():
		obstacles = _clone_obstacles(p_obstacles)
	if profile != null:
		_initial_profile_snap = profile.snapshot_params()
		_last_profile_snap = _initial_profile_snap.duplicate(true)
	capture_initial_snapshots()
	return build_replay_snapshot("baseline")


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
		obstacles = _clone_obstacles(_initial_obstacles_snap)
		sim.reset()
		shot_history.clear()
		timeline_inputs.clear()
		combat_events.clear()


## True when any projectile is in flight OR any actor has active reload cooldown
## or DoT effects that require simulation clock progression (P0-SIM-01).
func has_active_timers() -> bool:
	if not sim.shots.is_empty():
		return true
	if shooter != null and (shooter.reload_remaining > 0.0001 or not shooter.active_effects.is_empty()):
		return true
	for tid in targets:
		var t = targets[tid]
		if t != null and (t.reload_remaining > 0.0001 or not t.active_effects.is_empty()):
			return true
	return false


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


## Fire one shot using shooter-owned ammo/energy, coherent fire permission state
## machine, and persistent target states (P0-SIM-02).
## `fire_mode`: "SINGLE" | "HOLD" | "BURST" | "SALVO_FOLLOWUP" | "CHARGED"
func fire_shot(profile: WeaponProfile, origin: Vector3, direction: Vector3,
		target_position: Vector3, p_obstacles: Array = [],
		shooter_velocity: Vector3 = Vector3.ZERO,
		enforce_reload: bool = true, p_extra_targets: Array = [],
		fire_mode: String = "SINGLE") -> Dictionary:
	if profile == null:
		return {"ok": false, "state": "DISABLED", "reason": "NO_PROFILE", "shot": null}
	profile.refresh()
	if not _baseline_captured:
		capture_replay_baseline(profile, p_obstacles)
	if not p_obstacles.is_empty():
		obstacles = _clone_obstacles(p_obstacles)
	var mode_up := fire_mode.strip_edges().to_upper()
	var effective_enforce_reload := enforce_reload and mode_up != "SALVO_FOLLOWUP"
	_emit_combat_event("FIRE_REQUESTED", "Fire %s requested (%s -> %s)" % [
		mode_up, profile.weapon_name, profile.ordnance_name
	], "shooter_a", profile.weapon_path, "shotDelay")

	# Atomic check + resource consumption in a single transition (never double-deducts).
	var res: Dictionary = shooter.consume_fire_resources(
		profile.ammo_cost, profile.weapon_energy_cost, profile.shot_delay,
		effective_enforce_reload, true
	)
	if not bool(res.get("ok", false)):
		var rej_state := str(res.get("state", "DISABLED"))
		var rej_reason := str(res.get("reason", "FIRE_REJECTED"))
		_emit_combat_event("SHOT_REJECTED", "%s (%s) reload=%.3fs ammo=%d energy=%.1f" % [
			rej_state, rej_reason, float(shooter.reload_remaining), shooter.ammo_current, shooter.energy_current
		], "shooter_a", profile.weapon_path, "shotDelay", {"permission_state": rej_state, "reason": rej_reason})
		return {
			"ok": false,
			"state": rej_state,
			"reason": rej_reason,
			"reload_remaining": float(shooter.reload_remaining),
			"ammo_remaining": shooter.ammo_current,
			"energy_remaining": shooter.energy_current,
			"shot": null,
		}

	var prof_snap := profile.snapshot_params()
	_last_profile_snap = prof_snap
	var extras := p_extra_targets if not p_extra_targets.is_empty() else extra_target_dicts()
	var prim = primary_target()
	if prim != null:
		# Sync live target_position into primary actor & record movement if position changed.
		if not prim.position.is_equal_approx(target_position):
			record_actor_transform("primary", target_position, prim.velocity, prim.yaw_rad)
		profile.target_half_extents = prim.half_extents
		profile.target_bbox_offset = prim.bbox_offset
		profile.target_yaw_rad = prim.yaw_rad
		profile.target_radius = prim.radius

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

	_emit_combat_event("SHOT_ACCEPTED", "%s accepted (reload=%.2fs)" % [mode_up, shooter.reload_remaining],
		"shooter_a", profile.weapon_path, "shotDelay", {"fire_mode": mode_up})
	if shot.ammo_spent > 0:
		_emit_combat_event("AMMO_CONSUMED", "Ammo -%d (remaining %d)" % [shot.ammo_spent, shooter.ammo_current],
			"shooter_a", profile.ordnance_path, "ammoCost", {"ammo_spent": shot.ammo_spent, "ammo_remaining": shooter.ammo_current})
	if shot.energy_spent > 0.0:
		_emit_combat_event("ENERGY_CONSUMED", "Energy -%.1f (remaining %.1f)" % [shot.energy_spent, shooter.energy_current],
			"shooter_a", profile.weapon_path, "energyCost", {"energy_spent": shot.energy_spent, "energy_remaining": shooter.energy_current})
	_emit_combat_event("PROJECTILE_SPAWNED", "%s speed=%.1f m/s life=%.2fs" % [
		profile.ordnance_name, profile.shot_speed, profile.life_span
	], "shooter_a", profile.ordnance_path, "shotSpeed")

	var record := {
		"origin": [origin.x, origin.y, origin.z],
		"direction": [direction.x, direction.y, direction.z],
		"target_position": [target_position.x, target_position.y, target_position.z],
		"shooter_velocity": [shooter_velocity.x, shooter_velocity.y, shooter_velocity.z],
		"weapon_name": profile.weapon_name,
		"ordnance_name": profile.ordnance_name,
		"ammo_spent": shot.ammo_spent,
		"energy_spent": shot.energy_spent,
		"fire_mode": mode_up,
		"enforce_reload": effective_enforce_reload,
		"time": sim.sim_time,
		"profile_snapshot": prof_snap,
		"obstacles": _clone_obstacles(p_obstacles),
	}
	shot_history.append(record)
	timeline_inputs.append({
		"type": "FIRE_SHOT",
		"time": sim.sim_time,
		"shot_command": record.duplicate(true),
	})
	return {
		"ok": true,
		"state": str(res.get("state", "READY")),
		"reason": "",
		"shot": shot,
		"ammo_spent": shot.ammo_spent,
		"energy_spent": shot.energy_spent,
		"ammo_remaining": shooter.ammo_current,
		"energy_remaining": shooter.energy_current,
		"reload_remaining": float(shooter.reload_remaining),
	}


## Fire one shot and step until resolution (used by deterministic headless tests
## and replay verification).
func fire_and_resolve(profile: WeaponProfile, origin: Vector3, direction: Vector3,
		target_position: Vector3, max_time: float = 5.0,
		p_obstacles: Array = [], shooter_velocity: Vector3 = Vector3.ZERO,
		enforce_reload: bool = false) -> Dictionary:
	var fired := fire_shot(profile, origin, direction, target_position, p_obstacles, shooter_velocity, enforce_reload)
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


## Single authoritative simulation step: advances ProjectileSim clock and ticks
## shooter + all targets (reload cooldowns, DoT effects, destruction) exactly once.
func advance(dt: float) -> Array[Dictionary]:
	var tick_events: Array[Dictionary] = []
	if dt <= 0.0:
		return tick_events
	sim.advance(dt)
	if shooter != null:
		var s_evs: Array[Dictionary] = shooter.tick(dt)
		for ev in s_evs:
			tick_events.append(ev)
			_handle_actor_tick_event(shooter, ev)
	for tid in targets:
		var t = targets[tid]
		if t != null:
			var t_evs: Array[Dictionary] = t.tick(dt)
			for ev in t_evs:
				tick_events.append(ev)
				_handle_actor_tick_event(t, ev)
	return tick_events


func _handle_actor_tick_event(actor, ev: Dictionary) -> void:
	var et := str(ev.get("event_type", ""))
	if et == "reload_ready":
		_emit_combat_event("RELOAD_READY", "%s weapon reload complete" % actor.display_name,
			actor.actor_id, str(_last_profile_snap.get("weapon_path", "")), "shotDelay")
	elif et == "dot":
		_emit_combat_event("STATUS_EFFECT_TICK", "%s took %.2f DoT (%s) -> shield %.1f hull %.1f" % [
			actor.display_name, float(ev.get("raw_damage", 0.0)), str(ev.get("effect_name", "dot")),
			float(ev.get("shield_remaining", 0.0)), float(ev.get("hull_remaining", 0.0))
		], actor.actor_id, "", "active_effects", ev)
		if float(ev.get("shield_absorbed", 0.0)) > 0.0:
			_emit_combat_event("SHIELD_ABSORBED", "%s shield absorbed %.2f (rem %.1f)" % [
				actor.display_name, float(ev.get("shield_absorbed", 0.0)), float(ev.get("shield_remaining", 0.0))
			], actor.actor_id, str(_last_profile_snap.get("target_path", "")), "maxShield")
		if float(ev.get("hull_damage", 0.0)) > 0.0:
			_emit_combat_event("HULL_DAMAGED", "%s hull -%.2f (rem %.1f)" % [
				actor.display_name, float(ev.get("hull_damage", 0.0)), float(ev.get("hull_remaining", 0.0))
			], actor.actor_id, str(_last_profile_snap.get("target_path", "")), "maxHealth")
		if bool(ev.get("just_destroyed", false)):
			_emit_combat_event("ACTOR_DESTROYED", "%s destroyed by %s" % [
				actor.display_name, str(ev.get("effect_name", "dot"))
			], actor.actor_id, str(_last_profile_snap.get("target_path", "")), "maxHealth")


func _on_sim_shot_finished(res: Dictionary) -> void:
	var kind := str(res.get("kind", ""))
	var tid := str(res.get("hit_target_id", ""))
	var ord_path := str(_last_profile_snap.get("ordnance_path", ""))
	var tgt_path := str(_last_profile_snap.get("target_path", ""))
	_emit_combat_event("PROJECTILE_HIT", "%s (%s) dmg=%.1f" % [
		kind, tid if tid != "" else str(res.get("hit_obstacle_id", "none")), float(res.get("damage", 0.0))
	], tid, ord_path, "damageValue", res)
	var sh_abs := float(res.get("shield_damage", 0.0))
	if sh_abs > 0.0:
		_emit_combat_event("SHIELD_ABSORBED", "%s shield absorbed %.1f (rem %.1f)" % [
			tid if tid != "" else "primary", sh_abs, float(res.get("shield_remaining", 0.0))
		], tid if tid != "" else "primary", tgt_path, "maxShield")
	var hull_dmg := float(res.get("damage_to_hull", 0.0))
	if hull_dmg > 0.0:
		_emit_combat_event("HULL_DAMAGED", "%s hull -%.1f (rem %.1f)" % [
			tid if tid != "" else "primary", hull_dmg, float(res.get("target_health", 0.0))
		], tid if tid != "" else "primary", tgt_path, "maxHealth")
	var target_actor = targets.get(tid if tid != "" else "primary", null)
	if target_actor != null and bool(target_actor.destroyed) and hull_dmg > 0.0 and float(target_actor.hull_current) <= 0.0001:
		_emit_combat_event("ACTOR_DESTROYED", "%s destroyed" % target_actor.display_name,
			target_actor.actor_id, tgt_path, "maxHealth")


## Build an immutable CombatReplaySnapshot capturing initial actor states,
## transforms, hitboxes, obstacles, ODF revisions, weapon profile, and timeline
## input events (P1-SIM-03).
func build_replay_snapshot(label: String = "") -> Dictionary:
	var snap_id := "replay_%s_%d" % [scenario_id, saved_replay_snapshots.size() + 1]
	var init_targets := {}
	for tid in _initial_target_snaps:
		init_targets[tid] = (_initial_target_snaps[tid] as Dictionary).duplicate(true)
	var odf_revs: Dictionary = (_initial_profile_snap.get("odf_revisions", {}) as Dictionary).duplicate(true)
	var snap := {
		"schema": 1,
		"snapshot_id": snap_id,
		"label": label if label != "" else snap_id,
		"scenario_id": scenario_id,
		"seed_value": seed_value,
		"captured_at_sim_time": sim.sim_time,
		"initial_shooter": _initial_shooter_snap.duplicate(true),
		"initial_targets": init_targets,
		"obstacles": _clone_obstacles(_initial_obstacles_snap),
		"odf_revisions": odf_revs,
		"weapon_profile": _initial_profile_snap.duplicate(true),
		"timeline_inputs": timeline_inputs.duplicate(true),
		"shot_commands": shot_history.duplicate(true),
	}
	return snap


func save_replay_snapshot(label: String = "") -> Dictionary:
	var snap := build_replay_snapshot(label)
	saved_replay_snapshots.append(snap)
	return snap.duplicate(true)


static func _vec3(v, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback


static func _clone_obstacles(obs_list: Array) -> Array:
	var out: Array = []
	for obs in obs_list:
		if obs is Dictionary:
			out.append((obs as Dictionary).duplicate(true))
	return out


## Replay an immutable CombatReplaySnapshot inside a completely isolated
## sandboxed CombatScenario instance so the user's active scenario is NEVER
## overwritten unexpectedly (P1-SIM-03, RP-04, RP-05, RP-08).
static func replay_snapshot_sandboxed(snap: Dictionary, p_obstacles_override: Array = []) -> Dictionary:
	var sandbox := new(int(snap.get("seed_value", 1337)), str(snap.get("scenario_id", "replay")) + "_sandbox")
	var init_sh: Dictionary = snap.get("initial_shooter", {}) if snap.get("initial_shooter", {}) is Dictionary else {}
	if not init_sh.is_empty():
		sandbox.shooter.restore_snapshot(init_sh)
	sandbox.targets.clear()
	var init_tgts: Dictionary = snap.get("initial_targets", {}) if snap.get("initial_targets", {}) is Dictionary else {}
	for tid in init_tgts:
		var td: Dictionary = init_tgts[tid]
		var actor = ActorStateScript.create_target(str(tid), str(td.get("display_name", tid)))
		actor.restore_snapshot(td)
		sandbox.targets[str(tid)] = actor
	if not sandbox.targets.has("primary"):
		sandbox.targets["primary"] = ActorStateScript.create_target("primary", "Target B")
	var base_obs: Array = _clone_obstacles(p_obstacles_override) if not p_obstacles_override.is_empty() else _clone_obstacles(snap.get("obstacles", []))
	sandbox.obstacles = base_obs
	sandbox._initial_profile_snap = (snap.get("weapon_profile", {}) as Dictionary).duplicate(true)
	sandbox._last_profile_snap = sandbox._initial_profile_snap.duplicate(true)
	sandbox.capture_initial_snapshots()

	var results: Array[Dictionary] = []
	var inputs: Array = snap.get("timeline_inputs", [])
	if inputs.is_empty() and not (snap.get("shot_commands", []) as Array).is_empty():
		for sc in snap.get("shot_commands", []):
			inputs.append({"type": "FIRE_SHOT", "time": float((sc as Dictionary).get("time", 0.0)), "shot_command": sc})

	for ev in inputs:
		if not (ev is Dictionary):
			continue
		var ev_t := float(ev.get("time", sandbox.sim.sim_time))
		while sandbox.sim.sim_time + 0.0001 < ev_t:
			var step_dt := minf(1.0 / 60.0, ev_t - sandbox.sim.sim_time)
			sandbox.advance(step_dt)
		var etype := str(ev.get("type", ""))
		match etype:
			"MOVE_ACTOR":
				var aid := str(ev.get("actor_id", ""))
				var actor = sandbox.shooter if aid == "shooter_a" else sandbox.targets.get(aid, null)
				if actor != null:
					actor.position = _vec3(ev.get("position", null), actor.position)
					actor.velocity = _vec3(ev.get("velocity", null), actor.velocity)
					actor.yaw_rad = float(ev.get("yaw_rad", actor.yaw_rad))
					if ev.has("radius"):
						actor.radius = maxf(0.2, float(ev.get("radius", actor.radius)))
					if ev.has("half_extents"):
						actor.half_extents = _vec3(ev.get("half_extents", null), actor.half_extents)
					if ev.has("bbox_offset"):
						actor.bbox_offset = _vec3(ev.get("bbox_offset", null), actor.bbox_offset)
					if aid == "primary":
						sandbox.sim.update_live_target(actor.position, actor.yaw_rad)
			"ADD_EFFECT":
				sandbox.apply_status_effect(
					str(ev.get("actor_id", "primary")),
					str(ev.get("effect_name", "dot")),
					float(ev.get("dps", 0.0)),
					float(ev.get("duration_s", 0.0)),
					float(ev.get("shield_ratio", 1.0))
				)
			"CHANGE_PROFILE":
				var pdict: Dictionary = ev.get("profile", {}) if ev.get("profile", {}) is Dictionary else {}
				if not pdict.is_empty():
					var frozen_c := WeaponProfile.from_snapshot(pdict)
					if bool(ev.get("weapon_swap", false)):
						sandbox.change_weapon(frozen_c, bool(ev.get("preserve_cooldown", true)))
					else:
						sandbox.update_effective_odf_parameters(frozen_c)
			"FIRE_SHOT":
				var cmd: Dictionary = ev.get("shot_command", {}) if ev.get("shot_command", {}) is Dictionary else {}
				var psnap: Dictionary = cmd.get("profile_snapshot", snap.get("weapon_profile", {}))
				var frozen_prof: WeaponProfile = WeaponProfile.from_snapshot(psnap) if not psnap.is_empty() else null
				if frozen_prof == null:
					continue
				var shot_obs: Array = _clone_obstacles(cmd.get("obstacles", [])) if not (cmd.get("obstacles", []) as Array).is_empty() else base_obs
				var r := sandbox.fire_and_resolve(
					frozen_prof,
					_vec3(cmd.get("origin", Vector3.ZERO)),
					_vec3(cmd.get("direction", Vector3.FORWARD)),
					_vec3(cmd.get("target_position", Vector3(0, 0, -50))),
					5.0,
					shot_obs,
					_vec3(cmd.get("shooter_velocity", Vector3.ZERO)),
					bool(cmd.get("enforce_reload", false))
				)
				results.append(r)

	# Finish any remaining simulation time up to captured_at_sim_time (e.g., trailing DoT/reload).
	var target_end_t := float(snap.get("captured_at_sim_time", sandbox.sim.sim_time))
	var guard := 0
	while sandbox.sim.sim_time + 0.0001 < target_end_t and guard < 60000:
		sandbox.advance(minf(1.0 / 60.0, target_end_t - sandbox.sim.sim_time))
		guard += 1

	var target_states := {}
	for tid in sandbox.targets:
		var t = sandbox.targets[tid]
		if t != null:
			target_states[tid] = {
				"hull": t.hull_current,
				"shield": t.shield_current,
				"destroyed": t.destroyed,
				"position": [t.position.x, t.position.y, t.position.z],
				"velocity": [t.velocity.x, t.velocity.y, t.velocity.z],
				"yaw_rad": t.yaw_rad,
			}
	return {
		"ok": true,
		"sandboxed": true,
		"snapshot_id": str(snap.get("snapshot_id", "")),
		"shots_replayed": results.size(),
		"results": results,
		"shooter_ammo": sandbox.shooter.ammo_current,
		"shooter_energy": sandbox.shooter.energy_current,
		"shooter_reload": sandbox.shooter.reload_remaining,
		"targets": target_states,
		"sim_time": sandbox.sim.sim_time,
		"combat_events": sandbox.combat_events.duplicate(true),
	}


## Deterministically replay the recorded scenario from its captured initial
## baseline. When `sandboxed = true`, runs in an isolated sandbox without
## mutating `self` (RP-08). Uses captured frozen per-shot profiles so later ODF
## edits never alter historical replays (RP-05).
func replay_deterministic(profile: WeaponProfile = null, p_obstacles: Array = [],
		sandboxed: bool = false) -> Dictionary:
	var snap := build_replay_snapshot("deterministic_replay")
	if sandboxed:
		return replay_snapshot_sandboxed(snap, p_obstacles)
	var saved_inputs := timeline_inputs.duplicate(true)
	var saved_history := shot_history.duplicate(true)
	var saved_end_t := sim.sim_time
	reset("ALL")
	var results: Array[Dictionary] = []
	var use_inputs := not saved_inputs.is_empty()
	if use_inputs:
		for ev in saved_inputs:
			if not (ev is Dictionary):
				continue
			var ev_t := float(ev.get("time", sim.sim_time))
			while sim.sim_time + 0.0001 < ev_t:
				advance(minf(1.0 / 60.0, ev_t - sim.sim_time))
			var etype := str(ev.get("type", ""))
			match etype:
				"MOVE_ACTOR":
					var aid := str(ev.get("actor_id", ""))
					record_actor_transform(aid, _vec3(ev.get("position", null)), _vec3(ev.get("velocity", null)), float(ev.get("yaw_rad", 0.0)))
				"ADD_EFFECT":
					apply_status_effect(str(ev.get("actor_id", "primary")), str(ev.get("effect_name", "dot")),
						float(ev.get("dps", 0.0)), float(ev.get("duration_s", 0.0)), float(ev.get("shield_ratio", 1.0)))
				"CHANGE_PROFILE":
					var pdict: Dictionary = ev.get("profile", {}) if ev.get("profile", {}) is Dictionary else {}
					if not pdict.is_empty():
						var frozen_c := WeaponProfile.from_snapshot(pdict)
						if bool(ev.get("weapon_swap", false)):
							change_weapon(frozen_c, bool(ev.get("preserve_cooldown", true)))
						else:
							update_effective_odf_parameters(frozen_c)
				"FIRE_SHOT":
					var cmd: Dictionary = ev.get("shot_command", {}) if ev.get("shot_command", {}) is Dictionary else {}
					var psnap: Dictionary = cmd.get("profile_snapshot", {})
					var use_prof: WeaponProfile = WeaponProfile.from_snapshot(psnap) if not psnap.is_empty() else profile
					if use_prof == null:
						continue
					var obs_use := p_obstacles if not p_obstacles.is_empty() else _clone_obstacles(cmd.get("obstacles", []))
					var r := fire_and_resolve(
						use_prof,
						_vec3(cmd.get("origin", Vector3.ZERO)),
						_vec3(cmd.get("direction", Vector3.FORWARD)),
						_vec3(cmd.get("target_position", Vector3(0, 0, -50))),
						5.0,
						obs_use,
						_vec3(cmd.get("shooter_velocity", Vector3.ZERO)),
						bool(cmd.get("enforce_reload", false))
					)
					results.append(r)
		var guard := 0
		while sim.sim_time + 0.0001 < saved_end_t and guard < 60000:
			advance(minf(1.0 / 60.0, saved_end_t - sim.sim_time))
			guard += 1
	else:
		for rec in saved_history:
			var psnap: Dictionary = rec.get("profile_snapshot", {})
			var use_prof: WeaponProfile = WeaponProfile.from_snapshot(psnap) if not psnap.is_empty() else profile
			if use_prof == null:
				continue
			var r := fire_and_resolve(
				use_prof,
				_vec3(rec.get("origin", Vector3.ZERO)),
				_vec3(rec.get("direction", Vector3.FORWARD)),
				_vec3(rec.get("target_position", Vector3(0, 0, -50))),
				5.0,
				p_obstacles,
				_vec3(rec.get("shooter_velocity", Vector3.ZERO))
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
				"position": [t.position.x, t.position.y, t.position.z],
				"velocity": [t.velocity.x, t.velocity.y, t.velocity.z],
				"yaw_rad": t.yaw_rad,
			}
	return {
		"ok": true,
		"sandboxed": false,
		"shots_replayed": results.size(),
		"results": results,
		"shooter_ammo": shooter.ammo_current,
		"shooter_energy": shooter.energy_current,
		"shooter_reload": shooter.reload_remaining,
		"targets": target_states,
		"sim_time": sim.sim_time,
		"combat_events": combat_events.duplicate(true),
	}
