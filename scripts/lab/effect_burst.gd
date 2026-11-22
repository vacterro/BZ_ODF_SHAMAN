class_name EffectBurst
extends Node3D
## One APPROXIMATED explosion/render burst built from a real BZCC ODF.
## Owns its lifetime, OmniLight decay, BottomInteractsWithTerrain ground clamping
## (preventing spheres/fireballs from clipping below y = 0), and rigid-floor /
## obstacle bouncing physics for sim_ember, sim_chunk, and sim_spray particles.

var duration: float = 1.0
var light_node: OmniLight3D
var light_peak_energy: float = 0.0
var age: float = 0.0
var floor_y: float = 0.0
var obstacles: Array = []

## Emitters whose bottom interacts with terrain (BZCC default true unless
## BottomInteractsWithTerrain = false): [{node, base_local_y, start_r, finish_r, anim_time, is_sphere}]
var terrain_clamped_emitters: Array[Dictionary] = []

## Physics-simulated bouncing particle groups (sim_ember / sim_chunk / sim_spray)
## rendered as MultiMeshInstance3D children of their CPUParticles3D emitter so
## root child count and CPUParticles3D introspection remain unchanged while
## particles genuinely bounce on y = floor_y and scene obstacles!
var bouncing_groups: Array[Dictionary] = []
var uv_animated_materials: Array[Dictionary] = []
var bounce_events_count: int = 0
var min_simulated_y: float = 999.0


func _ready() -> void:
	if light_node != null and is_instance_valid(light_node):
		light_peak_energy = light_node.light_energy
	_update_terrain_clamping()
	_step_bouncing_groups(0.0)


func step_simulation(delta: float) -> void:
	age += delta
	if light_node != null and is_instance_valid(light_node) and light_peak_energy > 0.0:
		var t: float = clampf(age / maxf(0.05, duration * 0.7), 0.0, 1.0)
		light_node.light_energy = light_peak_energy * (1.0 - t) * (1.0 - t)
	for uvm in uv_animated_materials:
		var mat = uvm.get("material", null)
		if mat is StandardMaterial3D:
			var speed := float(uvm.get("texture_speed", 0.0))
			var rate := float(uvm.get("texture_rate", 0.0))
			if absf(speed) > 0.0001:
				(mat as StandardMaterial3D).uv1_offset.y += speed * delta * 0.25
			if absf(rate) > 0.0001:
				(mat as StandardMaterial3D).uv1_offset.x += rate * delta * 0.15
	_update_terrain_clamping()
	_step_bouncing_groups(delta)


func _process(delta: float) -> void:
	step_simulation(delta)
	if age >= duration:
		queue_free()


func _update_terrain_clamping() -> void:
	var root_y := global_position.y if is_inside_tree() else position.y
	for rec in terrain_clamped_emitters:
		var node = rec.get("node", null)
		if not is_instance_valid(node) or not (node is Node3D):
			continue
		var anim_t := maxf(0.04, float(rec.get("anim_time", 1.0)))
		var frac := clampf(age / anim_t, 0.0, 1.0)
		var cur_r := lerpf(float(rec.get("start_r", 0.5)), float(rec.get("finish_r", 1.0)), frac)
		var base_y := float(rec.get("base_local_y", 0.0))
		# BZCC BottomInteractsWithTerrain: keep the bottom of the sprite/sphere at or above floor_y.
		var min_world_y := floor_y + cur_r + 0.04
		var needed_local_y := maxf(base_y, min_world_y - root_y)
		(node as Node3D).position.y = needed_local_y


func _step_bouncing_groups(delta: float) -> void:
	var root_pos := global_position if is_inside_tree() else position
	for grp in bouncing_groups:
		var mmi = grp.get("mmi", null)
		if not is_instance_valid(mmi) or not (mmi is MultiMeshInstance3D):
			continue
		var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
		if mm == null:
			continue
		var parts: Array = grp.get("particles", [])
		var grav := float(grp.get("gravity", -9.8))
		var rest := float(grp.get("restitution", 0.52))
		var sc_start: Color = grp.get("start_color", Color(1, 0.8, 0.3, 1))
		var sc_end: Color = grp.get("finish_color", Color(1, 0.2, 0.0, 0))
		var r_start := float(grp.get("start_radius", 0.15))
		var r_end := float(grp.get("finish_radius", 0.04))
		var align_vel := bool(grp.get("align_velocity", false))
		for i in parts.size():
			var pt: Dictionary = parts[i]
			var p_age: float = float(pt["age"]) + delta
			var p_life: float = maxf(0.05, float(pt["life"]))
			pt["age"] = p_age
			if p_age >= p_life:
				mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(0.0001, 0.0001, 0.0001)), Vector3(0, -100, 0)))
				continue
			var frac := clampf(p_age / p_life, 0.0, 1.0)
			var cur_r := maxf(0.02, lerpf(r_start, r_end, frac))
			var pos: Vector3 = pt["pos"]
			var vel: Vector3 = pt["vel"]
			if delta > 0.0:
				vel.y += grav * delta
				pos += vel * delta
				# Rigid floor collision + bounce (local space relative to root_pos)
				var min_local_y := (floor_y + cur_r) - root_pos.y
				if pos.y < min_local_y:
					pos.y = min_local_y
					if vel.y < -0.25:
						vel.y = absf(vel.y) * rest
						vel.x *= 0.76
						vel.z *= 0.76
						bounce_events_count += 1
					else:
						vel.y = 0.0
						vel.x *= 0.85
						vel.z *= 0.85
				# Bounce off scene obstacles (walls/ramps/pillars)
				var wpos := root_pos + pos
				for obs in obstacles:
					if not (obs is Dictionary):
						continue
					var opos: Vector3 = obs.get("position", Vector3.ZERO)
					var osize: Vector3 = obs.get("size", Vector3.ZERO)
					var half := osize * 0.5
					if absf(wpos.x - opos.x) <= half.x + cur_r and absf(wpos.z - opos.z) <= half.z + cur_r:
						var top_y := opos.y + half.y
						if str(obs.get("shape", "box")) == "ramp":
							var z_frac := clampf((opos.z + half.z - wpos.z) / maxf(0.1, osize.z), 0.0, 1.0)
							top_y = (opos.y - half.y) + osize.y * z_frac
						if wpos.y < top_y + cur_r and wpos.y >= (opos.y - half.y - 0.5):
							if vel.y < 0.0 and wpos.y > top_y - 1.2:
								pos.y = (top_y + cur_r) - root_pos.y
								vel.y = absf(vel.y) * rest
								bounce_events_count += 1
							else:
								vel.x = -vel.x * rest
								vel.z = -vel.z * rest
								bounce_events_count += 1
				pt["pos"] = pos
				pt["vel"] = vel
			var wy := root_pos.y + pos.y
			if wy < min_simulated_y:
				min_simulated_y = wy
			var col := sc_start.lerp(sc_end, frac)
			var basis := Basis.IDENTITY
			if align_vel and vel.length_squared() > 0.05:
				var up_dir := vel.normalized()
				var side_ref := Vector3.RIGHT if absf(up_dir.dot(Vector3.RIGHT)) < 0.95 else Vector3.FORWARD
				var x_ax := up_dir.cross(side_ref).normalized()
				var z_ax := x_ax.cross(up_dir).normalized()
				var stretch := clampf(vel.length() * 0.07, 1.0, 6.0)
				basis = Basis(x_ax * cur_r, up_dir * (cur_r * stretch), z_ax * cur_r)
			else:
				basis = Basis.from_scale(Vector3(cur_r, cur_r, cur_r))
			mm.set_instance_transform(i, Transform3D(basis, pos))
			mm.set_instance_color(i, col)
