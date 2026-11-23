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
var _input_seq: int = 0
var _event_seq: int = 0
var _last_kf_by_actor: Dictionary = {}
var _pending_kf_by_actor: Dictionary = {}
var _transform_total_recorded: int = 0
var _transform_compressed_count: int = 0

static var _seq := 0


func _next_input_seq() -> int:
	_input_seq += 1
	return _input_seq


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
	_event_seq += 1
	var ev := {}
	for k in extra:
		if k == "kind":
			ev["sub_kind"] = extra[k]
		elif k == "time":
			ev["sub_time"] = extra[k]
		elif k == "seq":
			continue
		else:
			ev[k] = extra[k]
	ev["seq"] = _event_seq
	ev["time"] = float(extra.get("impact_time", sim.sim_time)) if kind == "PROJECTILE_HIT" and extra.has("impact_time") else sim.sim_time
	ev["kind"] = kind
	ev["actor_id"] = actor_id
	ev["detail"] = detail
	ev["odf_path"] = odf_path
	ev["odf_key"] = odf_key
	ev["approximated"] = true
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
		"seq": _next_input_seq(),
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
		"seq": _next_input_seq(),
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


## Record an actor transform change on the simulation timeline with deterministic
## piecewise-linear compression so 1-min and 10-min moving-target soaks remain
## memory-bounded without losing replay accuracy (P1-SIM-03 / Wave E).
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
	elif actor_id != "shooter_a":
		sim.update_live_extra_target(actor_id, pos, yaw)
	if not changed:
		return
	_transform_total_recorded += 1
	var now_t := sim.sim_time
	if _last_kf_by_actor.has(actor_id):
		var lk: Dictionary = _last_kf_by_actor[actor_id]
		var lk_idx := int(lk.get("tl_idx", -1))
		var lk_t := float(lk.get("time", 0.0))
		var lk_pos: Vector3 = lk.get("pos", Vector3.ZERO)
		var lk_vel: Vector3 = lk.get("vel", Vector3.ZERO)
		var lk_yaw := float(lk.get("yaw", 0.0))
		var dt_kf := maxf(0.0, now_t - lk_t)
		var predicted := lk_pos + lk_vel * dt_kf
		var vel_same := (vel - lk_vel).length() <= 0.01
		var yaw_same := absf(yaw - lk_yaw) <= 0.002
		var pos_err := (pos - predicted).length()
		if vel_same and yaw_same and pos_err <= 0.02 and lk_idx >= 0 and lk_idx < timeline_inputs.size():
			_transform_compressed_count += 1
			var prev_ev: Dictionary = timeline_inputs[lk_idx]
			prev_ev["compressed_end_time"] = now_t
			prev_ev["compressed_end_pos"] = [pos.x, pos.y, pos.z]
			prev_ev["compressed_frames"] = int(prev_ev.get("compressed_frames", 0)) + 1
			timeline_inputs[lk_idx] = prev_ev
			return
	_pending_kf_by_actor.erase(actor_id)
	var new_idx := timeline_inputs.size()
	_last_kf_by_actor[actor_id] = {"time": now_t, "pos": pos, "vel": vel, "yaw": yaw, "tl_idx": new_idx}
	timeline_inputs.append({
		"seq": _next_input_seq(),
		"type": "MOVE_ACTOR",
		"time": now_t,
		"actor_id": actor_id,
		"position": [pos.x, pos.y, pos.z],
		"velocity": [vel.x, vel.y, vel.z],
		"yaw_rad": yaw,
		"radius": actor.radius,
		"half_extents": [actor.half_extents.x, actor.half_extents.y, actor.half_extents.z],
		"bbox_offset": [actor.bbox_offset.x, actor.bbox_offset.y, actor.bbox_offset.z],
	})


func _flush_pending_transform(actor_id: String = "") -> void:
	var keys := [actor_id] if actor_id != "" else _pending_kf_by_actor.keys()
	for raw_aid in keys:
		var aid := str(raw_aid)
		if not _pending_kf_by_actor.has(aid):
			continue
		var pk: Dictionary = _pending_kf_by_actor[aid]
		_pending_kf_by_actor.erase(aid)
		var actor = shooter if aid == "shooter_a" else targets.get(aid, null)
		if actor == null:
			continue
		var pos: Vector3 = pk.get("pos", actor.position)
		var vel: Vector3 = pk.get("vel", actor.velocity)
		var yaw := float(pk.get("yaw", actor.yaw_rad))
		var pt := float(pk.get("time", sim.sim_time))
		_last_kf_by_actor[aid] = {"time": pt, "pos": pos, "vel": vel, "yaw": yaw}
		timeline_inputs.append({
			"seq": _next_input_seq(),
			"type": "MOVE_ACTOR",
			"time": pt,
			"actor_id": aid,
			"position": [pos.x, pos.y, pos.z],
			"velocity": [vel.x, vel.y, vel.z],
			"yaw_rad": yaw,
			"radius": actor.radius,
			"half_extents": [actor.half_extents.x, actor.half_extents.y, actor.half_extents.z],
			"bbox_offset": [actor.bbox_offset.x, actor.bbox_offset.y, actor.bbox_offset.z],
		})


func timeline_compression_stats() -> Dictionary:
	return {
		"total_recorded": _transform_total_recorded,
		"compressed_count": _transform_compressed_count,
		"timeline_size": timeline_inputs.size(),
	}


## Apply a timed status / DoT effect to an actor and record it for replay.
func apply_status_effect(actor_id: String, effect_name: String, dps: float,
		duration_s: float, shield_ratio: float = 1.0) -> bool:
	var actor = shooter if actor_id == "shooter_a" else targets.get(actor_id, null)
	if actor == null or duration_s <= 0.0:
		return false
	actor.add_effect(effect_name, dps, duration_s, shield_ratio)
	timeline_inputs.append({
		"seq": _next_input_seq(),
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
		_input_seq = 0
		_event_seq = 0
		_last_kf_by_actor.clear()
		_pending_kf_by_actor.clear()
		_transform_total_recorded = 0
		_transform_compressed_count = 0


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
		fire_mode: String = "SINGLE", p_hardpoint: String = "",
		p_barrel_index: int = 0, p_barrel_mode: String = "SINGLE",
		p_volley_id: int = 0) -> Dictionary:
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

	var prof_snap := profile.snapshot_params()
	_last_profile_snap = prof_snap
	var req_record := {
		"origin": [origin.x, origin.y, origin.z],
		"direction": [direction.x, direction.y, direction.z],
		"target_position": [target_position.x, target_position.y, target_position.z],
		"shooter_velocity": [shooter_velocity.x, shooter_velocity.y, shooter_velocity.z],
		"weapon_name": profile.weapon_name,
		"ordnance_name": profile.ordnance_name,
		"ammo_spent": 0,
		"energy_spent": 0.0,
		"fire_mode": mode_up,
		"enforce_reload": effective_enforce_reload,
		"time": sim.sim_time,
		"profile_snapshot": prof_snap,
		"obstacles": _clone_obstacles(p_obstacles),
		"hardpoint": p_hardpoint,
		"barrel_index": p_barrel_index,
		"barrel_mode": p_barrel_mode,
		"volley_id": p_volley_id,
	}

	# Atomic check + resource consumption in a single transition (never double-deducts).
	var res: Dictionary = shooter.consume_fire_resources(
		profile.ammo_cost, profile.weapon_energy_cost, profile.shot_delay,
		effective_enforce_reload, true
	)
	if not bool(res.get("ok", false)):
		var rej_state := str(res.get("state", "DISABLED"))
		var rej_reason := str(res.get("reason", "FIRE_REJECTED"))
		req_record["accepted"] = false
		req_record["rejected_state"] = rej_state
		req_record["rejected_reason"] = rej_reason
		# Record rejected fire requests on the input timeline so replay reproduces
		# the exact acceptance/rejection history (P0-SIM-01 / RPL-10).
		timeline_inputs.append({
			"seq": _next_input_seq(),
			"type": "FIRE_SHOT",
			"time": sim.sim_time,
			"accepted": false,
			"shot_command": req_record.duplicate(true),
		})
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
	if shot.identity != null:
		shot.identity.hardpoint = p_hardpoint
		shot.identity.barrel_index = p_barrel_index
		shot.identity.barrel_mode = p_barrel_mode
		shot.identity.volley_id = p_volley_id
	shot.shooter_ammo_remaining = shooter.ammo_current
	shot.shooter_energy_remaining = shooter.energy_current

	_emit_combat_event("SHOT_ACCEPTED", "%s accepted (reload=%.2fs)" % [mode_up, shooter.reload_remaining],
		"shooter_a", profile.weapon_path, "shotDelay", {"fire_mode": mode_up, "shot_id": shot.shot_id})
	if shot.ammo_spent > 0:
		_emit_combat_event("AMMO_CONSUMED", "Ammo -%d (remaining %d)" % [shot.ammo_spent, shooter.ammo_current],
			"shooter_a", profile.ordnance_path, "ammoCost", {"ammo_spent": shot.ammo_spent, "ammo_remaining": shooter.ammo_current})
	if shot.energy_spent > 0.0:
		_emit_combat_event("ENERGY_CONSUMED", "Energy -%.1f (remaining %.1f)" % [shot.energy_spent, shooter.energy_current],
			"shooter_a", profile.weapon_path, "energyCost", {"energy_spent": shot.energy_spent, "energy_remaining": shooter.energy_current})
	_emit_combat_event("PROJECTILE_SPAWNED", "%s speed=%.1f m/s life=%.2fs" % [
		profile.ordnance_name, profile.shot_speed, profile.life_span
	], "shooter_a", profile.ordnance_path, "shotSpeed", {"shot_id": shot.shot_id})

	req_record["ammo_spent"] = shot.ammo_spent
	req_record["energy_spent"] = shot.energy_spent
	req_record["accepted"] = true
	req_record["shot_id"] = shot.shot_id
	req_record["shot_identity"] = shot.identity.to_dict() if shot.identity != null else {}
	shot_history.append(req_record)
	timeline_inputs.append({
		"seq": _next_input_seq(),
		"type": "FIRE_SHOT",
		"time": sim.sim_time,
		"accepted": true,
		"shot_command": req_record.duplicate(true),
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


## Incremental chronological replay runner (P0-SIM-01 / RPL-09..RPL-16).
## Schedules all input events on ONE authoritative simulation clock without
## calling blocking fire_and_resolve(), preserving overlapping projectile
## lifetimes, exact reload rejections, mid-flight DoT ticks, moving targets,
## same-time event ordering, and bounded frame-budget UI stepping.
class ReplayRunner:
	extends RefCounted
	var snap: Dictionary = {}
	var sandbox = null
	var base_obs: Array = []
	var fallback_profile: WeaponProfile = null
	var sorted_inputs: Array[Dictionary] = []
	var cursor: int = 0
	var target_end_t: float = 0.0
	var last_fire_time: float = -1.0
	var stop_at_capture_time: bool = false
	var drain_max_extra_s: float = 5.0
	var drain_elapsed_s: float = 0.0
	var has_move_events: bool = false
	var sandboxed_flag: bool = true
	var done: bool = false
	var results: Array[Dictionary] = []
	var _shot_id_to_result_idx: Dictionary = {}
	var _active_compressed_spans: Dictionary = {}
	var accepted_shots: int = 0
	var rejected_shots: int = 0
	var max_concurrent_shots: int = 0
	var _steps_total: int = 0
	var _final_result: Dictionary = {}
	var terminal_status: String = ""
	var max_steps_total: int = 120000

	func _init(p_sandbox, p_snap: Dictionary, p_base_obs: Array, p_fallback_profile: WeaponProfile = null,
			p_sandboxed: bool = true, p_options: Dictionary = {}) -> void:
		sandbox = p_sandbox
		snap = p_snap.duplicate(true)
		base_obs = p_base_obs
		fallback_profile = p_fallback_profile
		sandboxed_flag = p_sandboxed
		max_steps_total = maxi(1, int(p_options.get("max_steps_total", 120000)))
		stop_at_capture_time = bool(p_options.get("stop_at_capture_time", false))
		drain_max_extra_s = maxf(0.1, float(p_options.get("max_drain_s", 5.0)))
		target_end_t = float(snap.get("captured_at_sim_time", 0.0))

		var raw_inputs: Array = snap.get("timeline_inputs", [])
		if raw_inputs.is_empty() and not (snap.get("shot_commands", []) as Array).is_empty():
			var idx_fb := 0
			for sc in snap.get("shot_commands", []):
				idx_fb += 1
				raw_inputs.append({
					"seq": idx_fb,
					"type": "FIRE_SHOT",
					"time": float((sc as Dictionary).get("time", 0.0)),
					"shot_command": sc,
				})
		var decorated: Array[Dictionary] = []
		for i in raw_inputs.size():
			var ev = raw_inputs[i]
			if not (ev is Dictionary):
				continue
			var copy: Dictionary = (ev as Dictionary).duplicate(true)
			if not copy.has("_orig_idx"):
				copy["_orig_idx"] = i
			if str(copy.get("type", "")) == "MOVE_ACTOR":
				has_move_events = true
			if str(copy.get("type", "")) == "FIRE_SHOT":
				last_fire_time = maxf(last_fire_time, float(copy.get("time", 0.0)))
			decorated.append(copy)
		decorated.sort_custom(func(a, b):
			var ta := float(a.get("time", 0.0))
			var tb := float(b.get("time", 0.0))
			if absf(ta - tb) > 0.000001:
				return ta < tb
			var sa := int(a.get("seq", int(a.get("_orig_idx", 0))))
			var sb := int(b.get("seq", int(b.get("_orig_idx", 0))))
			if sa != sb:
				return sa < sb
			return int(a.get("_orig_idx", 0)) < int(b.get("_orig_idx", 0))
		)
		sorted_inputs = decorated
		if sandbox != null and sandbox.sim != null and not sandbox.sim.shot_finished.is_connected(_on_shot_finished):
			sandbox.sim.shot_finished.connect(_on_shot_finished)

	func _on_shot_finished(res: Dictionary) -> void:
		var sid := int(res.get("shot_id", 0))
		if not _shot_id_to_result_idx.has(sid):
			return
		var idx := int(_shot_id_to_result_idx[sid])
		if idx < 0 or idx >= results.size():
			return
		var prim = sandbox.primary_target()
		var entry: Dictionary = results[idx]
		entry["resolved"] = true
		entry["kind"] = str(res.get("kind", ""))
		entry["hit_target_id"] = str(res.get("hit_target_id", ""))
		entry["hit_obstacle_id"] = str(res.get("hit_obstacle_id", ""))
		entry["damage"] = float(res.get("damage", 0.0))
		entry["damage_to_hull"] = float(res.get("damage_to_hull", 0.0))
		entry["shield_damage"] = float(res.get("shield_damage", 0.0))
		entry["shield_remaining"] = float(res.get("shield_remaining", prim.shield_current if prim != null else 0.0))
		entry["hull_remaining"] = float(res.get("target_health", prim.hull_current if prim != null else 0.0))
		entry["splash_hits"] = (res.get("splash_hits", []) as Array).duplicate(true)
		entry["impact_time"] = float(res.get("impact_time", sandbox.sim.sim_time))
		entry["destroyed"] = prim.destroyed if prim != null else false
		results[idx] = entry

	func _dispatch_event(ev: Dictionary) -> void:
		var etype := str(ev.get("type", ""))
		match etype:
			"MOVE_ACTOR":
				var aid := str(ev.get("actor_id", ""))
				var actor = sandbox.shooter if aid == "shooter_a" else sandbox.targets.get(aid, null)
				if actor != null:
					var pos := CombatScenario._vec3(ev.get("position", null), actor.position)
					var vel := CombatScenario._vec3(ev.get("velocity", null), actor.velocity)
					var yaw := float(ev.get("yaw_rad", actor.yaw_rad))
					if ev.has("radius"):
						actor.radius = maxf(0.2, float(ev.get("radius", actor.radius)))
					if ev.has("half_extents"):
						actor.half_extents = CombatScenario._vec3(ev.get("half_extents", null), actor.half_extents)
					if ev.has("bbox_offset"):
						actor.bbox_offset = CombatScenario._vec3(ev.get("bbox_offset", null), actor.bbox_offset)
					sandbox.record_actor_transform(aid, pos, vel, yaw)
					if ev.has("compressed_end_time") and ev.has("compressed_end_pos"):
						var et := float(ev.get("compressed_end_time", sandbox.sim.sim_time))
						var st := float(ev.get("time", sandbox.sim.sim_time))
						if et > st + 0.00001:
							_active_compressed_spans[aid] = {
								"start_time": st,
								"end_time": et,
								"start_pos": pos,
								"end_pos": CombatScenario._vec3(ev.get("compressed_end_pos", null), pos),
								"yaw": yaw,
							}
						else:
							_active_compressed_spans.erase(aid)
					else:
						_active_compressed_spans.erase(aid)
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
				var frozen_prof: WeaponProfile = WeaponProfile.from_snapshot(psnap) if (psnap is Dictionary and not psnap.is_empty()) else fallback_profile
				if frozen_prof == null:
					return
				var shot_obs: Array = CombatScenario._clone_obstacles(cmd.get("obstacles", [])) if not (cmd.get("obstacles", []) as Array).is_empty() else base_obs
				var prim = sandbox.primary_target()
				var fire_target_pos: Vector3 = prim.position if (has_move_events and prim != null) else CombatScenario._vec3(cmd.get("target_position", Vector3(0, 0, -50)))
				var fmode := str(cmd.get("fire_mode", "SINGLE"))
				var enf_rld := bool(cmd.get("enforce_reload", false))
				var fired: Dictionary = sandbox.fire_shot(
					frozen_prof,
					CombatScenario._vec3(cmd.get("origin", Vector3.ZERO)),
					CombatScenario._vec3(cmd.get("direction", Vector3.FORWARD)),
					fire_target_pos,
					shot_obs,
					CombatScenario._vec3(cmd.get("shooter_velocity", Vector3.ZERO)),
					enf_rld,
					[],
					fmode,
					str(cmd.get("hardpoint", "")),
					int(cmd.get("barrel_index", 0)),
					str(cmd.get("barrel_mode", "SINGLE")),
					int(cmd.get("volley_id", 0))
				)
				if bool(fired.get("ok", false)):
					accepted_shots += 1
					max_concurrent_shots = maxi(max_concurrent_shots, sandbox.sim.shots.size())
					var s = fired.get("shot", null)
					var entry := {
						"ok": true,
						"accepted": true,
						"resolved": false,
						"shot_id": s.shot_id if s != null else 0,
						"fire_time": sandbox.sim.sim_time,
						"impact_time": -1.0,
						"kind": "",
						"hit_target_id": "",
						"damage": 0.0,
						"damage_to_hull": 0.0,
						"shield_damage": 0.0,
						"shield_remaining": prim.shield_current if prim != null else 0.0,
						"hull_remaining": prim.hull_current if prim != null else 0.0,
						"ammo_cost": s.ammo_cost if s != null else 0,
						"ammo_spent": int(fired.get("ammo_spent", 0)),
						"ammo_remaining": sandbox.shooter.ammo_current,
						"energy_spent": float(fired.get("energy_spent", 0.0)),
						"energy_remaining": sandbox.shooter.energy_current,
						"splash_hits": [],
						"destroyed": prim.destroyed if prim != null else false,
					}
					var idx := results.size()
					results.append(entry)
					if s != null:
						_shot_id_to_result_idx[s.shot_id] = idx
				else:
					rejected_shots += 1
					results.append({
						"ok": false,
						"accepted": false,
						"resolved": true,
						"fire_time": sandbox.sim.sim_time,
						"state": str(fired.get("state", "REJECTED")),
						"reason": str(fired.get("reason", "FIRE_REJECTED")),
						"reload_remaining": float(fired.get("reload_remaining", 0.0)),
						"ammo_remaining": sandbox.shooter.ammo_current,
						"energy_remaining": sandbox.shooter.energy_current,
					})

	func _finalize(reason: String = "REPLAY_COMPLETE") -> Dictionary:
		done = true
		terminal_status = reason
		if sandbox != null and sandbox.sim != null and sandbox.sim.shot_finished.is_connected(_on_shot_finished):
			sandbox.sim.shot_finished.disconnect(_on_shot_finished)
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
		var complete := reason == "REPLAY_COMPLETE"
		_final_result = {
			"ok": complete,
			"complete": complete,
			"reason": reason,
			"status": reason,
			"steps_executed": _steps_total,
			"events_processed": cursor,
			"events_remaining": maxi(0, sorted_inputs.size() - cursor),
			"requested_end_time": target_end_t,
			"projectiles_in_flight": sandbox.sim.shots.size(),
			"sandboxed": sandboxed_flag,
			"snapshot_id": str(snap.get("snapshot_id", "")),
			"shots_replayed": accepted_shots,
			"fire_requests_replayed": results.size(),
			"accepted_shots": accepted_shots,
			"rejected_shots": rejected_shots,
			"max_concurrent_shots": max_concurrent_shots,
			"results": results.duplicate(true),
			"shooter_ammo": sandbox.shooter.ammo_current,
			"shooter_energy": sandbox.shooter.energy_current,
			"shooter_reload": sandbox.shooter.reload_remaining,
			"targets": target_states,
			"sim_time": sandbox.sim.sim_time,
			"in_flight_at_end": sandbox.sim.shots.size(),
			"combat_events": sandbox.combat_events.duplicate(true),
		}
		return _final_result

	func progress() -> float:
		if done:
			return 1.0
		var denom := maxf(0.001, target_end_t)
		return clampf(sandbox.sim.sim_time / denom, 0.0, 0.99)

	func _integrate_moving_actors(_dt: float) -> void:
		if _active_compressed_spans.is_empty() or sandbox == null:
			return
		var cur_t: float = float(sandbox.sim.sim_time)
		for aid in _active_compressed_spans.keys():
			var span: Dictionary = _active_compressed_spans[aid]
			var st := float(span.get("start_time", 0.0))
			var et := float(span.get("end_time", 0.0))
			var sp0: Vector3 = span.get("start_pos", Vector3.ZERO)
			var ep0: Vector3 = span.get("end_pos", sp0)
			var yaw := float(span.get("yaw", 0.0))
			var frac := clampf((cur_t - st) / maxf(0.0001, et - st), 0.0, 1.0)
			var interp := sp0.lerp(ep0, frac)
			var actor = sandbox.shooter if aid == "shooter_a" else sandbox.targets.get(aid, null)
			if actor != null:
				actor.position = interp
				actor.yaw_rad = yaw
				if aid == "primary":
					sandbox.sim.update_live_target(interp, yaw)
				elif aid != "shooter_a":
					sandbox.sim.update_live_extra_target(str(aid), interp, yaw)
			if cur_t >= et:
				_active_compressed_spans.erase(aid)

	## Execute up to `max_sim_steps` simulation ticks or `max_wall_ms` ms of work.
	func step(max_sim_steps: int = 30, max_wall_ms: float = 8.0) -> Dictionary:
		if done:
			return {"done": true, "progress": 1.0, "sim_time": sandbox.sim.sim_time, "result": _final_result}
		var t_wall0 := Time.get_ticks_usec()
		var steps_here := 0
		while steps_here < max_sim_steps and _steps_total < max_steps_total:
			if max_wall_ms > 0.0 and steps_here > 0:
				var elapsed_ms := float(Time.get_ticks_usec() - t_wall0) / 1000.0
				if elapsed_ms >= max_wall_ms:
					break
			# 1. Dispatch any scheduled events due at or before current sim_time.
			var dispatched_any := false
			while cursor < sorted_inputs.size():
				var ev: Dictionary = sorted_inputs[cursor]
				var ev_t := float(ev.get("time", sandbox.sim.sim_time))
				if ev_t <= sandbox.sim.sim_time + 0.00005:
					_dispatch_event(ev)
					cursor += 1
					dispatched_any = true
				else:
					break
			# 2. If more input events remain, advance toward next event timestamp.
			if cursor < sorted_inputs.size():
				var next_t := float(sorted_inputs[cursor].get("time", sandbox.sim.sim_time))
				var dt := minf(1.0 / 60.0, maxf(0.0001, next_t - sandbox.sim.sim_time))
				_integrate_moving_actors(dt)
				sandbox.advance(dt)
				max_concurrent_shots = maxi(max_concurrent_shots, sandbox.sim.shots.size())
				steps_here += 1
				_steps_total += 1
				continue
			# 3. All scheduled inputs dispatched: advance to captured_at_sim_time.
			if sandbox.sim.sim_time + 0.0001 < target_end_t:
				var dt2 := minf(1.0 / 60.0, target_end_t - sandbox.sim.sim_time)
				_integrate_moving_actors(dt2)
				sandbox.advance(dt2)
				max_concurrent_shots = maxi(max_concurrent_shots, sandbox.sim.shots.size())
				steps_here += 1
				_steps_total += 1
				continue
			# 4. Legacy/unadvanced snapshots captured right at last_fire_time with
			# live shots still in flight: drain remaining projectiles unless caller
			# requested strict cutoff at capture time.
			var should_drain: bool = (not stop_at_capture_time) and (not (sandbox.sim.shots as Array).is_empty()) and (target_end_t <= last_fire_time + 0.0001) and (drain_elapsed_s < drain_max_extra_s)
			if should_drain:
				var dt3 := 1.0 / 60.0
				_integrate_moving_actors(dt3)
				sandbox.advance(dt3)
				drain_elapsed_s += dt3
				max_concurrent_shots = maxi(max_concurrent_shots, sandbox.sim.shots.size())
				steps_here += 1
				_steps_total += 1
				continue
			# Complete!
			if not dispatched_any or cursor >= sorted_inputs.size():
				var res := _finalize()
				return {"done": true, "progress": 1.0, "sim_time": sandbox.sim.sim_time, "result": res}
		if _steps_total >= max_steps_total:
			var res_g := _finalize("REPLAY_STEP_LIMIT_EXCEEDED")
			return {"done": true, "complete": false, "reason": "REPLAY_STEP_LIMIT_EXCEEDED",
				"progress": progress(), "sim_time": sandbox.sim.sim_time, "result": res_g}
		return {"done": false, "progress": progress(), "sim_time": sandbox.sim.sim_time, "result": {}}

	func run_to_completion() -> Dictionary:
		var guard := 0
		while not done and guard < 10000:
			step(240, 0.0)
			guard += 1
		if not done:
			return _finalize("REPLAY_STEP_LIMIT_EXCEEDED")
		return _final_result


## Create an incremental bounded chronological ReplayRunner for a captured
## CombatReplaySnapshot (P0-SIM-01 / RPL-14).
static func create_replay_runner(snap: Dictionary, p_obstacles_override: Array = [],
		options: Dictionary = {}) -> ReplayRunner:
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
	return ReplayRunner.new(sandbox, snap, base_obs, null, true, options)


## Replay an immutable CombatReplaySnapshot inside a completely isolated
## sandboxed CombatScenario instance so the user's active scenario is NEVER
## overwritten unexpectedly (P0-SIM-01, P1-SIM-03, RP-04..08, RPL-09..16).
static func replay_snapshot_sandboxed(snap: Dictionary, p_obstacles_override: Array = [],
		options: Dictionary = {}) -> Dictionary:
	var runner := create_replay_runner(snap, p_obstacles_override, options)
	return runner.run_to_completion()


## Compare two deterministic replay results side-by-side (A/B comparison).
static func compare_replay_results(res_a: Dictionary, res_b: Dictionary) -> Dictionary:
	if res_a.is_empty() or res_b.is_empty():
		return {"ok": false, "identical": false, "summary": "missing replay result"}
	var targets_a: Dictionary = res_a.get("targets", {}) if res_a.get("targets", {}) is Dictionary else {}
	var targets_b: Dictionary = res_b.get("targets", {}) if res_b.get("targets", {}) is Dictionary else {}
	var all_tids: Array[String] = []
	for k in targets_a:
		if not all_tids.has(str(k)):
			all_tids.append(str(k))
	for k in targets_b:
		if not all_tids.has(str(k)):
			all_tids.append(str(k))
	all_tids.sort()
	var target_diffs := {}
	var identical := true
	for tid in all_tids:
		var ta: Dictionary = targets_a.get(tid, {})
		var tb: Dictionary = targets_b.get(tid, {})
		var dh := float(tb.get("hull", 0.0)) - float(ta.get("hull", 0.0))
		var ds := float(tb.get("shield", 0.0)) - float(ta.get("shield", 0.0))
		if absf(dh) > 0.05 or absf(ds) > 0.05:
			identical = false
		target_diffs[tid] = {"hull_a": float(ta.get("hull", 0.0)), "hull_b": float(tb.get("hull", 0.0)), "hull_delta": dh, "shield_a": float(ta.get("shield", 0.0)), "shield_b": float(tb.get("shield", 0.0)), "shield_delta": ds}
	var shots_a := int(res_a.get("accepted_shots", res_a.get("shots_replayed", 0)))
	var shots_b := int(res_b.get("accepted_shots", res_b.get("shots_replayed", 0)))
	var rej_a := int(res_a.get("rejected_shots", 0))
	var rej_b := int(res_b.get("rejected_shots", 0))
	if shots_a != shots_b or rej_a != rej_b:
		identical = false
	var prim_diff: Dictionary = target_diffs.get("primary", {"hull_delta": 0.0, "shield_delta": 0.0})
	return {
		"ok": true,
		"identical": identical,
		"shots_a": shots_a,
		"shots_b": shots_b,
		"shots_delta": shots_b - shots_a,
		"rejected_a": rej_a,
		"rejected_b": rej_b,
		"primary_hull_delta": float(prim_diff.get("hull_delta", 0.0)),
		"primary_shield_delta": float(prim_diff.get("shield_delta", 0.0)),
		"sim_time_delta": float(res_b.get("sim_time", 0.0)) - float(res_a.get("sim_time", 0.0)),
		"event_count_a": (res_a.get("combat_events", []) as Array).size(),
		"event_count_b": (res_b.get("combat_events", []) as Array).size(),
		"target_diffs": target_diffs,
		"summary": "A/B Replay: %s | shots %d->%d | primary hull %+.1f, shield %+.1f" % [
			"IDENTICAL" if identical else "DIFF", shots_a, shots_b,
			float(prim_diff.get("hull_delta", 0.0)), float(prim_diff.get("shield_delta", 0.0))
		],
	}


## Deterministically replay the recorded scenario from its captured initial
## baseline. When `sandboxed = true`, runs in an isolated sandbox without
## mutating `self` (RP-08). Uses chronological event scheduling (never blocking
## per-shot fire_and_resolve) and frozen per-shot profiles (RP-05, RPL-09..16).
func replay_deterministic(profile: WeaponProfile = null, p_obstacles: Array = [],
		sandboxed: bool = false, options: Dictionary = {}) -> Dictionary:
	var snap := build_replay_snapshot("deterministic_replay")
	if sandboxed:
		return replay_snapshot_sandboxed(snap, p_obstacles, options)
	var base_obs := _clone_obstacles(p_obstacles) if not p_obstacles.is_empty() else _clone_obstacles(_initial_obstacles_snap)
	reset("ALL")
	var runner := ReplayRunner.new(self, snap, base_obs, profile, false, options)
	return runner.run_to_completion()
