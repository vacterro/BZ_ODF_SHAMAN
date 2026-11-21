class_name RibbonTrailNode
extends Node3D
## Animated crossed-ribbon trail preview for BZCC draw_trail/draw_twirl_trail.
## The ribbon follows a caller-supplied sampled path and scrolls its UVs over
## time so the trail appears to flow without any native engine dependency.

var points: Array[Vector3] = []
var radius: float = 0.12
var color: Color = Color(1, 1, 1, 1)
var uv_scale: float = 2.0
var scroll_speed: float = 1.5
var age: float = 0.0
var mesh_instance: MeshInstance3D

var _material: StandardMaterial3D


func _init() -> void:
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "RibbonMesh"
	add_child(mesh_instance)
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = _material


func configure(p_points: Array[Vector3], p_radius: float, p_color: Color,
		p_uv_scale: float = 2.0, p_scroll_speed: float = 1.5) -> void:
	points = p_points.duplicate()
	radius = maxf(0.01, p_radius)
	color = p_color
	uv_scale = maxf(0.1, p_uv_scale)
	scroll_speed = p_scroll_speed
	rebuild(0.0)


func _process(delta: float) -> void:
	age += delta
	rebuild(age)


func rebuild(t: float) -> void:
	if points.size() < 2:
		mesh_instance.mesh = null
		return
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var first := points[0]
	var last := points[points.size() - 1]
	var fwd := last - first
	if fwd.length_squared() < 0.000001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var up_ref := Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.96 else Vector3.RIGHT
	var side_a := fwd.cross(up_ref).normalized()
	var side_b := fwd.cross(side_a).normalized()
	_append(im, points, side_a, radius, color, uv_scale, t * scroll_speed)
	_append(im, points, side_b, radius, color, uv_scale, t * scroll_speed)
	var core := Color(minf(1.0, color.r * 0.5 + 0.5), minf(1.0, color.g * 0.5 + 0.5),
		minf(1.0, color.b * 0.5 + 0.5), color.a)
	_append(im, points, side_a, radius * 0.34, core, uv_scale, t * scroll_speed * 1.3)
	_append(im, points, side_b, radius * 0.34, core, uv_scale, t * scroll_speed * 1.3)
	im.surface_end()
	mesh_instance.mesh = im


func _append(im: ImmediateMesh, pts: Array[Vector3], side: Vector3, rad: float,
		col: Color, scale: float, scroll: float) -> void:
	var accum := 0.0
	for i in range(pts.size() - 1):
		var p0 := pts[i]
		var p1 := pts[i + 1]
		var seg := p0.distance_to(p1)
		var v0 := accum * scale + scroll
		var v1 := (accum + seg) * scale + scroll
		accum += seg
		var a0 := p0 - side * rad
		var b0 := p0 + side * rad
		var a1 := p1 - side * rad
		var b1 := p1 + side * rad
		im.surface_set_color(col); im.surface_set_uv(Vector2(0, v0)); im.surface_add_vertex(a0)
		im.surface_set_color(col); im.surface_set_uv(Vector2(1, v0)); im.surface_add_vertex(b0)
		im.surface_set_color(col); im.surface_set_uv(Vector2(1, v1)); im.surface_add_vertex(b1)
		im.surface_set_color(col); im.surface_set_uv(Vector2(0, v0)); im.surface_add_vertex(a0)
		im.surface_set_color(col); im.surface_set_uv(Vector2(1, v1)); im.surface_add_vertex(b1)
		im.surface_set_color(col); im.surface_set_uv(Vector2(0, v1)); im.surface_add_vertex(a1)


static func build_path(start: Vector3, end: Vector3, arc: float, segments: int = 24) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var segs := maxi(2, segments)
	for i in range(segs + 1):
		var t := float(i) / float(segs)
		var p := start.lerp(end, t)
		p.y += sin(t * PI) * arc
		out.append(p)
	return out
