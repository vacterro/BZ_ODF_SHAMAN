class_name BoltBeamNode
extends Node3D
## Authentic APPROXIMATED BZCC draw_bolt / draw_beam / draw_tracer world-space
## lightning and energy beam renderer.
##
## Spans two 3D points (muzzle origin -> impact/end point) with crossed double
## glowing ribbons, jagged perpendicular segmentVariance displacement animated
## over animateTime, UV scrolling (textureRate/textureSpeed), additive blending,
## and rigid floor clamping (y >= 0.06) so arcs never clip underground.

var start_pos: Vector3 = Vector3.ZERO
var end_pos: Vector3 = Vector3.FORWARD * 50.0
var start_color: Color = Color(1.0, 1.0, 1.0, 1.0)
var finish_color: Color = Color(0.0, 1.0, 0.86, 0.0)
var start_radius: float = 0.7
var finish_radius: float = 0.05
var segment_length: float = 7.0
var segment_variance: Vector3 = Vector3(2.0, 2.0, 0.5)
var animate_time: float = 0.8
var duration: float = 0.8
var texture_rate: float = 0.3
var texture_speed: float = -8.0
var floor_y: float = 0.05
var is_additive: bool = true
var albedo_texture: Texture2D = null
var render_base: String = "draw_bolt"

var age: float = 0.0
var _jitter_accum: float = 0.0
var _rng := RandomNumberGenerator.new()
var _mesh_instance: MeshInstance3D
var _core_instance: MeshInstance3D
var _light: OmniLight3D
var _mat_outer: StandardMaterial3D
var _mat_core: StandardMaterial3D
var _offsets: Array[Vector3] = []
var _fork_offsets: Array[Vector3] = []
var _seg_count: int = 8


func _ready() -> void:
	_rng.seed = int(Time.get_ticks_usec()) ^ int(absf(start_pos.x * 131.0 + end_pos.z * 97.0))
	var dist := start_pos.distance_to(end_pos)
	_seg_count = clampi(int(ceilf(dist / maxf(1.5, segment_length))), 4, 48)
	if render_base == "draw_beam" or render_base == "draw_tracer":
		_seg_count = clampi(_seg_count, 2, 16)

	_mat_outer = StandardMaterial3D.new()
	_mat_outer.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_outer.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_mat_outer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_outer.vertex_color_use_as_albedo = true
	_mat_outer.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_outer.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if is_additive else BaseMaterial3D.BLEND_MODE_MIX
	_mat_outer.albedo_texture = albedo_texture if albedo_texture != null else _make_bolt_texture()

	_mat_core = StandardMaterial3D.new()
	_mat_core.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_core.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_mat_core.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_core.vertex_color_use_as_albedo = true
	_mat_core.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_core.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat_core.albedo_texture = _mat_outer.albedo_texture

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "BoltOuterRibbon"
	_mesh_instance.material_override = _mat_outer
	add_child(_mesh_instance)

	_core_instance = MeshInstance3D.new()
	_core_instance.name = "BoltCoreRibbon"
	_core_instance.material_override = _mat_core
	add_child(_core_instance)

	_light = OmniLight3D.new()
	_light.name = "BoltGlowLight"
	_light.position = (start_pos + end_pos) * 0.5 + Vector3(0.0, 1.0, 0.0)
	_light.light_color = Color(start_color.r, start_color.g, start_color.b).lerp(Color(finish_color.r, finish_color.g, finish_color.b), 0.35)
	_light.omni_range = clampf(dist * 0.35, 8.0, 36.0)
	_light.light_energy = 2.8
	_light.shadow_enabled = false
	add_child(_light)

	_regenerate_jitter()
	_rebuild_ribbons(0.0)


func rebuild_mesh() -> void:
	if _mesh_instance == null or _core_instance == null:
		return
	var dist := start_pos.distance_to(end_pos)
	var desired := clampi(int(ceilf(dist / maxf(1.5, segment_length))), 4, 48)
	if render_base == "draw_beam" or render_base == "draw_tracer":
		desired = clampi(desired, 2, 16)
	if desired != _seg_count:
		_seg_count = desired
		_regenerate_jitter()
	if _light != null and is_instance_valid(_light):
		_light.position = (start_pos + end_pos) * 0.5 + Vector3(0.0, 1.0, 0.0)
		_light.omni_range = clampf(dist * 0.35, 8.0, 36.0)
	var t := clampf(age / maxf(0.04, animate_time), 0.0, 1.0)
	_rebuild_ribbons(t)


func _process(delta: float) -> void:
	age += delta
	if age >= duration:
		queue_free()
		return
	var t := clampf(age / maxf(0.04, animate_time), 0.0, 1.0)
	_jitter_accum += delta
	# Electric crackle re-jitter ~22 Hz for draw_bolt
	if render_base == "draw_bolt" and _jitter_accum >= 0.045:
		_jitter_accum = 0.0
		_regenerate_jitter()
	_rebuild_ribbons(t)
	if _light != null and is_instance_valid(_light):
		_light.light_energy = 2.8 * (1.0 - t) * (1.0 - t)


func _regenerate_jitter() -> void:
	_offsets.clear()
	_fork_offsets.clear()
	var var_mag := segment_variance
	if render_base == "draw_beam" or render_base == "draw_tracer":
		var_mag = var_mag * 0.08
	for i in range(_seg_count + 1):
		if i == 0 or i == _seg_count:
			_offsets.append(Vector3.ZERO)
			_fork_offsets.append(Vector3.ZERO)
		else:
			var edge_fade := sin(PI * float(i) / float(_seg_count))
			_offsets.append(Vector3(
				_rng.randf_range(-var_mag.x, var_mag.x) * edge_fade,
				_rng.randf_range(-var_mag.y, var_mag.y) * edge_fade,
				_rng.randf_range(-var_mag.z, var_mag.z) * edge_fade
			))
			_fork_offsets.append(Vector3(
				_rng.randf_range(-var_mag.x * 1.35, var_mag.x * 1.35) * edge_fade,
				_rng.randf_range(-var_mag.y * 1.35, var_mag.y * 1.35) * edge_fade,
				_rng.randf_range(-var_mag.z, var_mag.z) * edge_fade
			))


func _rebuild_ribbons(t: float) -> void:
	var delta_vec := end_pos - start_pos
	var dist := delta_vec.length()
	if dist < 0.01:
		return
	var fwd := delta_vec / dist
	var up_ref := Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.96 else Vector3.RIGHT
	var side_a := fwd.cross(up_ref).normalized()
	var side_b := fwd.cross(side_a).normalized()

	var col := start_color.lerp(finish_color, t)
	var core_col := Color(
		minf(1.0, col.r * 0.5 + 0.5),
		minf(1.0, col.g * 0.5 + 0.5),
		minf(1.0, col.b * 0.5 + 0.5),
		col.a
	)
	var rad := maxf(0.03, lerpf(start_radius, maxf(0.04, finish_radius), t))
	var uv_scroll := age * texture_speed
	var uv_scale := maxf(0.05, texture_rate)

	var pts: Array[Vector3] = []
	var fork_pts: Array[Vector3] = []
	for i in range(_seg_count + 1):
		var frac := float(i) / float(_seg_count)
		var base_pt := start_pos.lerp(end_pos, frac)
		var off: Vector3 = _offsets[i] if i < _offsets.size() else Vector3.ZERO
		var pt := base_pt + side_a * off.x + side_b * off.y + fwd * off.z
		pt.y = maxf(floor_y, pt.y)
		pts.append(pt)
		if render_base == "draw_bolt" and segment_variance.length() > 0.15:
			var foff: Vector3 = _fork_offsets[i] if i < _fork_offsets.size() else Vector3.ZERO
			var fpt := base_pt + side_a * foff.x + side_b * foff.y + fwd * foff.z
			fpt.y = maxf(floor_y, fpt.y)
			fork_pts.append(fpt)

	_mesh_instance.mesh = _build_crossed_ribbon_mesh(pts, fork_pts, side_a, side_b, rad, col, uv_scale, uv_scroll)
	_core_instance.mesh = _build_crossed_ribbon_mesh(pts, [], side_a, side_b, rad * 0.36, core_col, uv_scale, uv_scroll)


func _build_crossed_ribbon_mesh(pts: Array[Vector3], secondary: Array[Vector3], side_a: Vector3, side_b: Vector3,
		rad: float, col: Color, uv_scale: float, uv_scroll: float) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_ribbon(im, pts, side_a, rad, col, uv_scale, uv_scroll)
	_append_ribbon(im, pts, side_b, rad, col, uv_scale, uv_scroll)
	if secondary.size() >= 2:
		var fcol := Color(col.r, col.g, col.b, col.a * 0.55)
		_append_ribbon(im, secondary, side_a, rad * 0.55, fcol, uv_scale, uv_scroll * 1.15)
		_append_ribbon(im, secondary, side_b, rad * 0.55, fcol, uv_scale, uv_scroll * 1.15)
	im.surface_end()
	return im


func _append_ribbon(im: ImmediateMesh, pts: Array[Vector3], side: Vector3, rad: float,
		col: Color, uv_scale: float, uv_scroll: float) -> void:
	var accum_dist := 0.0
	for i in range(pts.size() - 1):
		var p0 := pts[i]
		var p1 := pts[i + 1]
		var seg_d := p0.distance_to(p1)
		var v0 := accum_dist * uv_scale + uv_scroll
		var v1 := (accum_dist + seg_d) * uv_scale + uv_scroll
		accum_dist += seg_d
		var a0 := p0 - side * rad
		var b0 := p0 + side * rad
		var a1 := p1 - side * rad
		var b1 := p1 + side * rad
		im.surface_set_color(col); im.surface_set_uv(Vector2(0.0, v0)); im.surface_add_vertex(a0)
		im.surface_set_color(col); im.surface_set_uv(Vector2(1.0, v0)); im.surface_add_vertex(b0)
		im.surface_set_color(col); im.surface_set_uv(Vector2(1.0, v1)); im.surface_add_vertex(b1)
		im.surface_set_color(col); im.surface_set_uv(Vector2(0.0, v0)); im.surface_add_vertex(a0)
		im.surface_set_color(col); im.surface_set_uv(Vector2(1.0, v1)); im.surface_add_vertex(b1)
		im.surface_set_color(col); im.surface_set_uv(Vector2(0.0, v1)); im.surface_add_vertex(a1)


static func _make_bolt_texture() -> ImageTexture:
	var w := 64
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var half := float(w - 1) * 0.5
	for y in h:
		for x in w:
			var dx := absf(float(x) - half) / half
			var glow := exp(-dx * dx * 7.5) * (1.0 - dx * 0.85)
			var core := exp(-dx * dx * 32.0)
			var v := clampf(glow * 0.85 + core * 0.65, 0.0, 1.0)
			img.set_pixel(x, y, Color(v, v, v, v))
	return ImageTexture.create_from_image(img)
