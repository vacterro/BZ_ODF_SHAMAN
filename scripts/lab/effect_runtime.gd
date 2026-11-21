class_name EffectRuntime
extends RefCounted
## Builds APPROXIMATED live visual effects from real BZCC ExplosionClass and
## Render ODF headers.
##
## Supports distinct preview implementations for documented render classes:
## draw_emit, draw_multi, draw_sprite, draw_trail, draw_twirl_trail, draw_bolt,
## draw_tracer, draw_geom, draw_light, draw_twirl, draw_sphere, and generic
## fallbacks. Follows both local headers and external `file.header` references
## live from OdfDocument.load_cached() so edits in Inspector, Raw ODF, Particle
## Graph, or Undo/Redo take effect on the very next shot without stale state.

const MAX_CLASSES := 16
const MAX_PARTICLES := 160
const MAX_DEPTH := 6
const BzMeshReaderScript = preload("res://scripts/core/bz_mesh_reader.gd")
const BoltBeamScript = preload("res://scripts/lab/bolt_beam_node.gd")
const RibbonTrailScript = preload("res://scripts/lab/ribbon_trail_node.gd")


static func build(p_index: ResourceIndex, xpl_path: String, position: Vector3,
		scale_factor: float = 1.0, p_obstacles: Array = [], floor_y: float = 0.0) -> Dictionary:
	var result := {
		"ok": false, "root": null, "duration": 0.0, "classes": [],
		"render_types": [], "emitters": 0, "errors": [], "path": xpl_path,
	}
	if xpl_path == "" or not FileAccess.file_exists(xpl_path):
		result.errors.append("explosion ODF not found: " + (xpl_path if xpl_path != "" else "(none)"))
		return result
	var doc := OdfDocument.load_cached(xpl_path)
	if doc == null:
		result.errors.append("cannot read explosion ODF: " + xpl_path)
		return result
	var main: String = _explosion_header(doc)
	if main == "":
		result.errors.append("no ExplosionClass/particleTypes header in " + xpl_path.get_file())
		return result
	var root := EffectBurst.new()
	root.name = "ExplosionBurst"
	root.position = position
	root.floor_y = floor_y
	root.obstacles = p_obstacles
	var count: int = doc.get_int(main, "particleTypes", 0)
	if count <= 0:
		for h in doc.header_names():
			if h != main:
				count += 1
	count = clampi(count, 0, MAX_CLASSES)
	var duration: float = 0.5
	var seen := {}
	var visited := {}
	for i in range(1, count + 1):
		var cls := doc.get_value(main, "particleClass%d" % i, "")
		if cls == "" or seen.has(cls.to_lower()):
			continue
		seen[cls.to_lower()] = true
		var target_doc := doc
		var header := _find_header(doc, cls)
		if header == "" and cls.contains(".") and p_index != null:
			var ext_path := p_index.resolve_path_from(cls.get_basename(), doc.source_path)
			if ext_path != "":
				var ext_doc := OdfDocument.load_cached(ext_path)
				if ext_doc != null:
					var h2 := _find_header(ext_doc, cls.get_extension())
					if h2 != "":
						target_doc = ext_doc
						header = h2
		if header == "":
			result.errors.append("particleClass%d header missing: %s" % [i, cls])
			continue
		var count_i: int = doc.get_int(main, "particleCount%d" % i, 1)
		var veloc := _vec(doc.get_value(main, "particleVeloc%d" % i, ""))
		var bias := _vec(doc.get_value(main, "particleBias%d" % i, ""))
		var pos_var := _vec(doc.get_value(main, "particlePosVar%d" % i, ""))
		var child_res := _build_render_node(p_index, target_doc, header, count_i, veloc, bias, scale_factor, 0, visited, true, pos_var)
		for err in child_res.errors:
			result.errors.append(err)
		for node in child_res.nodes:
			root.add_child(node)
			if node is OmniLight3D and root.light_node == null:
				root.light_node = node
			_register_burst_physics(root, node)
		result.emitters += int(child_res.emitters)
		if int(child_res.emitters) > 0:
			result.classes.append(header)
		for rt in child_res.render_types:
			if not (result.render_types as Array).has(rt):
				(result.render_types as Array).append(rt)
		duration = maxf(duration, float(child_res.duration))

	if result.emitters == 0:
		result.errors.append("no renderable particle class in " + xpl_path.get_file())
		root.queue_free()
		return result
	root.duration = clampf(duration + 0.05, 0.1, 30.0)
	result.ok = true
	result.root = root
	result.duration = root.duration
	return result


## Check whether a render reference resolves to draw_bolt or draw_beam (or contains one via draw_multi/draw_emit).
static func is_bolt_or_beam_ref(p_index: ResourceIndex, ref: String, context_path: String) -> bool:
	var resolved := _resolve_render_target(p_index, null, ref, context_path)
	if not bool(resolved.get("ok", false)):
		return false
	var d: OdfDocument = resolved.doc
	var h: String = str(resolved.header)
	var rb := d.get_value(h, "renderBase", "").to_lower()
	if rb == "draw_bolt" or rb == "draw_beam":
		return true
	if rb == "draw_multi" or rb == "draw_emit":
		var ename := d.get_value(h, "emitName", "")
		if ename != "" and is_bolt_or_beam_ref(p_index, ename, d.source_path):
			return true
		for k in range(1, 16):
			var rn := d.get_value(h, "renderName%d" % k, "")
			if rn != "" and is_bolt_or_beam_ref(p_index, rn, d.source_path):
				return true
	return false


## Build a live animated world-space lightning / energy beam node (draw_bolt,
## draw_beam, draw_tracer) spanning `start_pos -> end_pos` over `animateTime`.
static func build_bolt_beam(p_index: ResourceIndex, ref: String, context_path: String,
		start_pos: Vector3, end_pos: Vector3, scale_factor: float = 1.0, floor_y: float = 0.05) -> Dictionary:
	var out := {"ok": false, "root": null, "duration": 0.6, "render_base": "draw_bolt", "errors": []}
	var doc: OdfDocument = null
	var header := ""
	if ref != "":
		var resolved := _resolve_render_target(p_index, null, ref, context_path)
		if bool(resolved.get("ok", false)):
			doc = resolved.doc
			header = str(resolved.header)
			# Unwrap draw_multi / draw_emit to find the draw_bolt / draw_beam child header if present.
			var rb0 := doc.get_value(header, "renderBase", "").to_lower()
			if rb0 == "draw_multi" or rb0 == "draw_emit":
				for k in range(1, 16):
					var rn := doc.get_value(header, "renderName%d" % k, "")
					if rn == "" and k == 1:
						rn = doc.get_value(header, "emitName", "")
					if rn == "":
						continue
					var sub_r := _resolve_render_target(p_index, doc, rn, doc.source_path)
					if bool(sub_r.get("ok", false)):
						var srb := (sub_r.doc as OdfDocument).get_value(str(sub_r.header), "renderBase", "").to_lower()
						if srb == "draw_bolt" or srb == "draw_beam" or srb == "draw_tracer":
							doc = sub_r.doc
							header = str(sub_r.header)
							break
	var bolt := BoltBeamScript.new()
	bolt.name = "BoltBeam_" + (header if header != "" else "Arc")
	bolt.start_pos = start_pos
	bolt.end_pos = end_pos
	bolt.floor_y = floor_y
	if doc != null and header != "":
		var rb := doc.get_value(header, "renderBase", "draw_bolt").to_lower()
		bolt.render_base = rb if rb != "" else "draw_bolt"
		bolt.start_color = _color(doc.get_value(header, "startColor", ""), Color(1.0, 1.0, 1.0, 1.0))
		bolt.finish_color = _color(doc.get_value(header, "finishColor", ""), Color(0.0, 1.0, 0.86, 0.0))
		bolt.start_radius = maxf(0.08, doc.get_float(header, "startRadius", 0.7) * scale_factor)
		bolt.finish_radius = maxf(0.02, doc.get_float(header, "finishRadius", 0.05) * scale_factor)
		bolt.segment_length = maxf(1.0, doc.get_float(header, "segmentLength", 7.0))
		var sv := _vec(doc.get_value(header, "segmentVariance", ""))
		bolt.segment_variance = sv if sv.length() > 0.001 else (Vector3(1.8, 1.8, 0.5) if bolt.render_base == "draw_bolt" else Vector3.ZERO)
		var anim_t := doc.get_float(header, "animateTime", doc.get_float(header, "lifeTime", 0.8))
		if anim_t <= 0.02 or anim_t > 15.0:
			anim_t = 0.65
		bolt.animate_time = anim_t
		bolt.duration = clampf(maxf(anim_t, doc.get_float(header, "lifeTime", anim_t)), 0.18, 10.0)
		bolt.texture_rate = doc.get_float(header, "textureRate", 0.3)
		bolt.texture_speed = doc.get_float(header, "textureSpeed", -8.0)
		var blend := doc.get_value(header, "textureBlend", "one one modulate").to_lower()
		bolt.is_additive = blend == "" or blend.contains("one one") or blend.contains("srcalpha one") or blend.ends_with(" add")
		var tex_name := doc.get_value(header, "textureName", "")
		if tex_name != "":
			bolt.albedo_texture = _load_particle_texture(p_index, tex_name, doc.source_path)
	else:
		bolt.render_base = "draw_bolt"
		bolt.animate_time = 0.5
		bolt.duration = 0.5
	out.ok = true
	out.root = bolt
	out.duration = bolt.duration
	out.render_base = bolt.render_base
	return out


## Build a live render effect from a standalone render reference (e.g. weapon
## flashName, ordnance renderName, or "file.header") at `position`.
static func build_render_ref(p_index: ResourceIndex, ref: String, context_path: String,
		position: Vector3, scale_factor: float = 1.0, one_shot: bool = true,
		p_obstacles: Array = [], floor_y: float = 0.0) -> Dictionary:
	var result := {
		"ok": false, "root": null, "duration": 0.5, "classes": [],
		"render_types": [], "emitters": 0, "errors": [],
	}
	var resolved := _resolve_render_target(p_index, null, ref, context_path)
	if not bool(resolved.get("ok", false)):
		result.errors.append("render reference unresolved: " + ref)
		return result
	var doc: OdfDocument = resolved.doc
	var header: String = str(resolved.header)
	var visited := {}
	var child_res := _build_render_node(p_index, doc, header, 1, Vector3.ZERO, Vector3.ZERO, scale_factor, 0, visited, one_shot)
	if int(child_res.emitters) == 0 and (child_res.nodes as Array).is_empty():
		result.errors.append("render reference produced no visible nodes: " + ref)
		return result
	var root := EffectBurst.new()
	root.name = "Render_" + header
	root.position = position
	root.floor_y = floor_y
	root.obstacles = p_obstacles
	for node in child_res.nodes:
		root.add_child(node)
		if node is OmniLight3D and root.light_node == null:
			root.light_node = node
		_register_burst_physics(root, node)
	root.duration = clampf(float(child_res.duration) + 0.05, 0.1, 30.0)
	result.ok = true
	result.root = root
	result.duration = root.duration
	result.emitters = int(child_res.emitters)
	result.classes = [header]
	result.render_types = child_res.render_types
	result.errors = child_res.errors
	return result


static func _register_burst_physics(root: EffectBurst, node: Node) -> void:
	if node == null or root == null:
		return
	if node.has_meta("terrain_clamp"):
		var tc: Dictionary = (node.get_meta("terrain_clamp") as Dictionary).duplicate()
		tc["node"] = node
		root.terrain_clamped_emitters.append(tc)
	if node.has_meta("bouncing_group"):
		var bg: Dictionary = node.get_meta("bouncing_group")
		root.bouncing_groups.append(bg)


## Build live preview nodes for every render header in a single ODF document
## (used by ParticleLab so Graph/Inspector/Raw edits share the exact same renderer).
static func build_document_preview(p_index: ResourceIndex, doc: OdfDocument) -> Dictionary:
	var out := {"emitters": [], "nodes": [], "render_types": [], "header_nodes": {}}
	if doc == null:
		return out
	var renders := doc.render_headers()
	var idx := 0
	for h in renders:
		var visited := {}
		var res := _build_render_node(p_index, doc, h.name, 1, Vector3.ZERO, Vector3.ZERO, 1.0, 0, visited, false)
		var holder := Node3D.new()
		holder.name = "Preview_" + h.name
		holder.set_meta("header", h.name)
		holder.position = Vector3((idx % 3 - 1) * 3.0, 0.5 + int(idx / 3) * 0.2, 0.0)
		var rb := doc.get_value(h.name, "renderBase", "").to_lower()
		for n in res.nodes:
			# Apply static terrain clamping in continuous Particle Lab preview so spheres never clip below y=0.
			if n is Node3D and n.has_meta("terrain_clamp"):
				var tc: Dictionary = n.get_meta("terrain_clamp")
				var max_r := maxf(float(tc.get("start_r", 0.5)), float(tc.get("finish_r", 0.5)))
				(n as Node3D).position.y = maxf((n as Node3D).position.y, max_r * 0.45)
			holder.add_child(n)
			if n is CPUParticles3D:
				(out.emitters as Array).append(n)
		# Also spawn an animated BoltBeam preview for draw_bolt / draw_beam headers in Particle Lab!
		if rb == "draw_bolt" or rb == "draw_beam":
			var bres := build_bolt_beam(p_index, doc.source_path.get_file().get_basename() + "." + h.name, doc.source_path, Vector3(-2.8, 1.2, 0.0), Vector3(2.8, 1.2, 0.0))
			if bool(bres.get("ok", false)) and bres.get("root", null) != null:
				var bn = bres.root
				bn.duration = 9999.0
				holder.add_child(bn)
		# Animated crossed-ribbon trail for continuous draw_trail / draw_twirl_trail.
		if rb == "draw_trail" or rb == "draw_twirl_trail":
			var trail = build_ribbon_trail(doc, h.name)
			if trail != null:
				holder.add_child(trail)
		(out.nodes as Array).append(holder)
		(out.header_nodes as Dictionary)[h.name] = holder
		for rt in res.render_types:
			if not (out.render_types as Array).has(rt):
				(out.render_types as Array).append(rt)
		idx += 1
	return out


static func _build_render_node(p_index: ResourceIndex, doc: OdfDocument, header: String,
		count_i: int, veloc: Vector3, bias: Vector3, scale_factor: float,
		depth: int, visited: Dictionary, one_shot: bool = true, pos_var: Vector3 = Vector3.ZERO) -> Dictionary:
	var out := {"nodes": [], "emitters": 0, "duration": 0.1, "render_types": [], "errors": []}
	if doc == null or header == "" or depth > MAX_DEPTH:
		return out
	var vkey := (doc.source_path + "|" + header).to_lower()
	if visited.has(vkey):
		return out
	visited[vkey] = true

	var base: String = doc.get_value(header, "renderBase", "").to_lower()
	if base == "draw_null":
		visited.erase(vkey)
		return out
	if base != "":
		(out.render_types as Array).append(base)

	var lifetime: float = clampf(doc.get_float(header, "lifeTime",
		doc.get_float(header, "lifeSpan", 1.0)), 0.1, 30.0)
	out.duration = maxf(out.duration, lifetime)

	# Container/dispatcher render classes: draw_emit, draw_multi
	if base == "draw_emit" or base == "draw_multi":
		var child_refs: Array[String] = []
		var emit_ref := doc.get_value(header, "emitName", "")
		if emit_ref != "":
			child_refs.append(emit_ref)
		for k in range(1, 33):
			var rn := doc.get_value(header, "renderName%d" % k, "")
			if rn != "":
				child_refs.append(rn)
		var emit_vel := _vec(doc.get_value(header, "emitVelocity", ""))
		var emit_var := _vec(doc.get_value(header, "emitVariance", ""))
		var emit_pos_var := _vec(doc.get_value(header, "emitPosVariance", doc.get_value(header, "emitPosVar", "")))
		var sub_vel := veloc + emit_vel
		if emit_var.length() > 0.001 and sub_vel.length() <= 0.001:
			sub_vel = emit_var
		var sub_count := maxi(count_i, doc.get_int(header, "maxCount", count_i))
		var emit_delay := doc.get_float(header, "emitDelay", 0.0)
		if base == "draw_emit" and emit_delay > 0.01 and emit_delay < lifetime and sub_count <= 2:
			sub_count = clampi(int(ceilf(lifetime / emit_delay)), 2, 24)
		for cref in child_refs:
			var resolved := _resolve_render_target(p_index, doc, cref, doc.source_path)
			if not bool(resolved.get("ok", false)):
				out.errors.append("child render missing: " + cref)
				continue
			var sub := _build_render_node(p_index, resolved.doc, str(resolved.header), sub_count, sub_vel, bias, scale_factor, depth + 1, visited, one_shot, pos_var + emit_pos_var)
			for n in sub.nodes:
				if emit_pos_var.length() > 0.001 and n is Node3D:
					(n as Node3D).position += Vector3(0.0, emit_pos_var.y * 0.25, 0.0)
				(out.nodes as Array).append(n)
			out.emitters += int(sub.emitters)
			out.duration = maxf(out.duration, float(sub.duration))
			for rt in sub.render_types:
				if not (out.render_types as Array).has(rt):
					(out.render_types as Array).append(rt)
			for err in sub.errors:
				(out.errors as Array).append(err)
		# If draw_emit/draw_multi had no resolvable children, still emit a subtle marker burst if it declares colors
		if int(out.emitters) > 0:
			visited.erase(vkey)
			return out

	if base == "draw_light":
		var light := _build_light(doc, header, scale_factor)
		if light != null:
			(out.nodes as Array).append(light)
		# Per PARTICLE.md (LightRenderClass): lensFlare controls whether a soft
		# lightflare.dds sprite renders at origin. Never draw an untextured solid box.
		var flash := _build_particle_emitter(doc, header, base, maxi(1, count_i), veloc, bias, p_index, scale_factor, one_shot, pos_var)
		if flash != null:
			(out.nodes as Array).append(flash)
			out.emitters += 1
		visited.erase(vkey)
		return out

	if base == "draw_geom":
		var geom_name := doc.get_value(header, "geomName", "")
		if geom_name == "":
			geom_name = doc.get_value(header, "geometryName", "")
		if geom_name != "" and p_index != null:
			var msh := BzMeshReaderScript.resolve_msh_for_geometry(p_index, geom_name, doc.source_path)
			if msh != "":
				var built := BzMeshReaderScript.build_scene(msh, p_index, geom_name)
				if bool(built.get("ok", false)) and built.get("root", null) != null:
					(out.nodes as Array).append(built.root)
					out.emitters += 1
					visited.erase(vkey)
					return out

	var emitter := _build_particle_emitter(doc, header, base, count_i, veloc, bias, p_index, scale_factor, one_shot, pos_var)
	if emitter != null:
		(out.nodes as Array).append(emitter)
		out.emitters += 1
	visited.erase(vkey)
	return out


static func _resolve_render_target(p_index: ResourceIndex, local_doc: OdfDocument,
		ref: String, context_path: String) -> Dictionary:
	var v := ref.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if v == "":
		return {"ok": false}
	if not v.contains("."):
		if local_doc != null:
			var h := _find_header(local_doc, v)
			if h != "":
				return {"ok": true, "doc": local_doc, "header": h}
		if p_index != null and context_path != "":
			var path := p_index.resolve_path_from(v, context_path)
			if path != "":
				var d := OdfDocument.load_cached(path)
				if d != null:
					var h2 := _explosion_header(d)
					if h2 == "" and not d.render_headers().is_empty():
						h2 = d.render_headers()[0].name
					if h2 != "":
						return {"ok": true, "doc": d, "header": h2}
		return {"ok": false}
	var file_ref := v.get_basename()
	var wanted_header := v.get_extension()
	var ext_path := p_index.resolve_path_from(file_ref, context_path) if p_index != null else ""
	if ext_path == "" and context_path != "":
		var sib := context_path.get_base_dir().path_join(file_ref + ".odf")
		if FileAccess.file_exists(sib):
			ext_path = sib
	if ext_path == "":
		return {"ok": false}
	var ext_doc := OdfDocument.load_cached(ext_path)
	if ext_doc == null:
		return {"ok": false}
	var h3 := _find_header(ext_doc, wanted_header)
	if h3 == "":
		return {"ok": false}
	return {"ok": true, "doc": ext_doc, "header": h3}


static func _explosion_header(doc: OdfDocument) -> String:
	for h in doc.header_names():
		if doc.find_entry(h, "particleTypes") != null or doc.find_entry(h, "particleClass1") != null:
			return h
	for h in doc.header_names():
		if doc.get_value(h, "classLabel", "").to_lower() == "explosion":
			return h
	return ""


static func _find_header(doc: OdfDocument, wanted: String) -> String:
	for h in doc.header_names():
		if h.to_lower() == wanted.to_lower():
			return h
	var leaf := wanted.get_extension() if wanted.contains(".") else wanted
	for h in doc.header_names():
		if h.to_lower() == leaf.to_lower():
			return h
	return ""


static func _make_radial_glow_texture(soft_smoke: bool = false) -> ImageTexture:
	var sz := 64
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var half := float(sz - 1) * 0.5
	for y in sz:
		for x in sz:
			var dx := (float(x) - half) / half
			var dy := (float(y) - half) / half
			var r2 := dx * dx + dy * dy
			var falloff := 0.0
			if r2 < 1.0:
				var r := sqrt(r2)
				if soft_smoke:
					falloff = pow(1.0 - r, 1.6)
				else:
					falloff = exp(-r2 * 4.5) * (1.0 - r2)
			img.set_pixel(x, y, Color(falloff, falloff, falloff, clampf(falloff, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


static func _make_streak_mesh(width: float, length: float, mat: Material) -> ArrayMesh:
	## Crossed double-quad along +Y (matches BZCC draw_trail/draw_tracer cross-section).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := width * 0.5
	var hl := length * 0.5
	# Quad 1 in XY plane
	st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, -hl, 0))
	st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(hw, -hl, 0))
	st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, hl, 0))
	st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, -hl, 0))
	st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, hl, 0))
	st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(-hw, hl, 0))
	# Quad 2 in ZY plane
	st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(0, -hl, -hw))
	st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(0, -hl, hw))
	st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(0, hl, hw))
	st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(0, -hl, -hw))
	st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(0, hl, hw))
	st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(0, hl, -hw))
	var am := st.commit()
	if am.get_surface_count() > 0:
		am.surface_set_material(0, mat)
	return am


static func _load_particle_texture(p_index: ResourceIndex, tex_name: String, context_path: String) -> ImageTexture:
	if tex_name == "" or p_index == null:
		return null
	# Per PARTICLE.md line 250: BZCC internally converts texture extensions to .dds.
	var tex_path: String = p_index.find_asset_near(tex_name, ["dds", "tga", "png", "jpg"], context_path)
	if tex_path == "":
		return null
	var img: Image = BzMeshReaderScript.load_image_any(tex_path)
	if img != null and not img.is_empty():
		return ImageTexture.create_from_image(img)
	return null


static func _build_particle_emitter(doc: OdfDocument, header: String, base: String,
		count_i: int, veloc: Vector3, bias: Vector3, p_index: ResourceIndex,
		scale_factor: float, one_shot: bool, pos_var: Vector3 = Vector3.ZERO) -> CPUParticles3D:
	if base == "draw_null":
		return null
	var lifetime: float = clampf(doc.get_float(header, "lifeTime",
		doc.get_float(header, "lifeSpan", doc.get_float(header, "emitLife", 1.0))), 0.08, 30.0)
	var anim_time: float = doc.get_float(header, "animateTime", lifetime)
	if anim_time <= 0.001 or anim_time > 1e6:
		anim_time = lifetime
	var emit_delay := doc.get_float(header, "emitDelay", 0.0)
	var max_cnt := doc.get_int(header, "maxCount", 0)
	var amount: int = clampi(maxi(count_i, 1), 1, MAX_PARTICLES)
	if base == "draw_light" or base == "draw_planar" or base == "draw_sphere" or base == "draw_wave":
		amount = clampi(maxi(count_i, 1), 1, 4)
	elif base == "draw_sprite":
		amount = clampi(maxi(count_i, 1), 1, 16)
	elif base == "draw_trail" or base == "draw_twirl_trail":
		var rate_cnt := int(round(lifetime / maxf(0.025, emit_delay if (emit_delay > 0.0 and emit_delay < 10.0) else 0.06)))
		amount = clampi(maxi(count_i, mini(rate_cnt, 36)), 3, MAX_PARTICLES)
	elif max_cnt > 0 and count_i <= 1:
		amount = clampi(mini(max_cnt, 24), 1, MAX_PARTICLES)

	var p := CPUParticles3D.new()
	p.name = "FX_" + header
	p.one_shot = one_shot
	p.emitting = true
	var is_continuous_trail := (base == "draw_trail" or base == "draw_twirl_trail") and not one_shot
	p.explosiveness = 0.92 if (one_shot and not is_continuous_trail) else 0.0
	p.lifetime = lifetime
	p.amount = amount
	p.randomness = 0.25 if (base == "draw_sprite" or base == "draw_bolt" or base == "draw_tracer" or base == "draw_planar" or base == "draw_sphere") else 0.45
	p.local_coords = false
	p.direction = Vector3(0, 1, 0)

	# BZCC particleVeloc is half-extent velocity variance; particleBias adds directional offset.
	var emit_vel := _vec(doc.get_value(header, "emitVelocity", ""))
	var emit_var := _vec(doc.get_value(header, "emitVariance", ""))
	var vel_box := Vector3(absf(veloc.x), absf(veloc.y), absf(veloc.z)) + Vector3(absf(emit_var.x), absf(emit_var.y), absf(emit_var.z))
	var mean_vel := bias + emit_vel
	var speed_mag := maxf(mean_vel.length(), vel_box.length() * 0.45)
	if base == "draw_planar" or base == "draw_sphere" or base == "draw_light":
		p.initial_velocity_min = 0.0
		p.initial_velocity_max = 0.0
		p.spread = 0.0
	elif speed_mag > 0.01:
		p.direction = mean_vel.normalized() if mean_vel.length() > 0.01 else Vector3(0, 1, 0)
		p.initial_velocity_min = maxf(0.1, (mean_vel.length() * 0.45 + vel_box.length() * 0.12) * scale_factor)
		p.initial_velocity_max = maxf(0.25, (mean_vel.length() * 0.85 + vel_box.length() * 0.55) * scale_factor)
		if vel_box.length() > 0.01:
			p.spread = clampf(45.0 + (vel_box.length() / maxf(1.0, mean_vel.length() + 1.0)) * 55.0, 20.0, 180.0)
		else:
			p.spread = 15.0
	else:
		p.initial_velocity_min = 0.0
		p.initial_velocity_max = 0.0
		p.spread = 180.0

	var sim: String = doc.get_value(header, "simulateBase", "sim_null").to_lower()
	if sim == "sim_ember" or sim == "sim_chunk" or sim == "sim_spray":
		p.gravity = Vector3(0, -9.8, 0)
	elif sim == "sim_smoke" or sim == "sim_dust":
		p.gravity = Vector3(0, 0.35, 0)
		p.damping_min = 1.2
		p.damping_max = 2.4
	else:
		p.gravity = Vector3.ZERO

	# True BZCC startRadius / finishRadius (diameter = 2 * radius).
	var srad: float = maxf(0.01, doc.get_float(header, "startRadius", 0.5) * scale_factor)
	var frad: float = maxf(0.005, doc.get_float(header, "finishRadius", srad) * scale_factor)
	if base == "draw_light":
		# Light radius is OmniLight range; optional lens flare sprite is compact.
		var lf := doc.get_value(header, "lensFlare", "true").strip_edges().to_lower()
		var flare_on := (lf != "0" and lf != "false")
		srad = clampf(srad * (0.14 if flare_on else 0.06), 0.15, 3.5)
		frad = clampf(frad * (0.04 if flare_on else 0.02), 0.05, 1.0)
	var max_rad := maxf(srad, frad)
	p.scale_amount_min = max_rad
	p.scale_amount_max = max_rad * (1.0 if (base == "draw_planar" or base == "draw_sphere" or base == "draw_light") else 1.15)
	var anim_frac := clampf(anim_time / maxf(0.05, lifetime), 0.05, 1.0)
	var sc_curve := Curve.new()
	sc_curve.add_point(Vector2(0.0, clampf(srad / max_rad, 0.005, 1.0)))
	sc_curve.add_point(Vector2(anim_frac, clampf(frad / max_rad, 0.005, 1.0)))
	if anim_frac < 0.99:
		sc_curve.add_point(Vector2(1.0, clampf(frad / max_rad, 0.005, 1.0)))
	p.scale_amount_curve = sc_curve

	var rot := doc.get_float(header, "rotationRate", 0.0)
	if base == "draw_twirl" or base == "draw_twirl_trail":
		var rr := absf(rot) if absf(rot) > 0.001 else 3.0
		p.angle_min = -180.0
		p.angle_max = 180.0
		p.angular_velocity_min = -rr * 18.0
		p.angular_velocity_max = rr * 18.0

	# Material following BZCC textureBlend ("SourceMode DestMode TextureMethod").
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_keep_scale = true

	var blend := doc.get_value(header, "textureBlend", "").to_lower()
	var is_additive := blend.contains("one one") or blend.contains("srcalpha one") or blend.ends_with(" add") or base == "draw_light"
	var is_sub := blend.contains("invsrc invsrc") or blend.contains("zero invsrc")
	if is_additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	elif is_sub:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_SUB
	else:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.albedo_color = Color(1, 1, 1, 1)

	var tex_name: String = doc.get_value(header, "textureName", "")
	if base == "draw_light" and tex_name == "":
		tex_name = "lightflare.tga"
	var loaded_tex := _load_particle_texture(p_index, tex_name, doc.source_path)
	if loaded_tex != null:
		mat.albedo_texture = loaded_tex
	else:
		# Smooth procedural radial texture fallback — never render an untextured solid square.
		mat.albedo_texture = _make_radial_glow_texture(not is_additive)

	if base == "draw_light":
		var lf2 := doc.get_value(header, "lensFlare", "true").strip_edges().to_lower()
		if lf2 == "0" or lf2 == "false":
			mat.albedo_color = Color(1, 1, 1, 0.22)
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		var q_l := QuadMesh.new()
		q_l.size = Vector2(2.0, 2.0)
		q_l.material = mat
		p.mesh = q_l
	elif base == "draw_planar" or base == "draw_wave":
		# Per PARTICLE.md: PlanarRender / WaveRender renders flat along the ground surface.
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		p.position.y += 0.06
		var plane := PlaneMesh.new()
		plane.size = Vector2(2.0, 2.0)
		plane.material = mat
		p.mesh = plane
	elif base == "draw_sphere":
		# Per PARTICLE.md: SphereRender uses 16 latitude bands x 32 longitude segments.
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 32
		sphere.rings = 16
		sphere.material = mat
		p.mesh = sphere
	elif base == "draw_bolt":
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		p.particle_flag_align_y = true
		var box := BoxMesh.new()
		var length := clampf(doc.get_float(header, "segmentLength", 2.5), 0.3, 12.0)
		box.size = Vector3(0.22, length, 0.22)
		box.material = mat
		p.mesh = box
	elif base == "draw_trail" or base == "draw_tracer" or base == "draw_beam":
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		p.particle_flag_align_y = true
		var tlen := doc.get_float(header, "tracerLength", doc.get_float(header, "segmentLength", 1.8))
		tlen = clampf(tlen / maxf(0.05, max_rad), 1.5, 24.0)
		p.mesh = _make_streak_mesh(2.0, tlen, mat)
	elif base == "draw_geom":
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		var prism := PrismMesh.new()
		prism.size = Vector3(0.8, 1.0, 0.8)
		prism.material = mat
		p.mesh = prism
	elif base == "draw_twirl" or base == "draw_twirl_trail":
		# BILLBOARD_PARTICLES + billboard_keep_scale enables true spin & exact radius scaling.
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		var quad_tw := QuadMesh.new()
		quad_tw.size = Vector2(2.0, 2.0)
		quad_tw.material = mat
		p.mesh = quad_tw
	else:
		# draw_sprite and generic particle classes
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		var quad := QuadMesh.new()
		quad.size = Vector2(2.0, 2.0)
		quad.material = mat
		p.mesh = quad

	var ramp := Gradient.new()
	var sc := _color(doc.get_value(header, "startColor", ""), Color(1, 0.75, 0.3, 1))
	var fc := _color(doc.get_value(header, "finishColor", ""), Color(1, 0.3, 0.05, 0))
	ramp.set_color(0, sc)
	if anim_frac < 0.99:
		ramp.add_point(anim_frac, fc)
	ramp.set_color(ramp.get_point_count() - 1, fc)
	p.color_ramp = ramp

	# BZCC BottomInteractsWithTerrain (defaults to true unless explicitly false/0).
	var biwt_raw := doc.get_value(header, "BottomInteractsWithTerrain", "true").strip_edges().to_lower()
	var bottom_interacts := (biwt_raw != "false" and biwt_raw != "0" and biwt_raw != "no")
	if bottom_interacts and (base == "draw_sphere" or base == "draw_twirl" or base == "draw_sprite"):
		p.set_meta("terrain_clamp", {
			"base_local_y": p.position.y,
			"start_r": srad,
			"finish_r": frad,
			"anim_time": anim_time,
			"is_sphere": base == "draw_sphere",
		})

	# Rigid-floor bouncing physics layer for sim_ember / sim_chunk / sim_spray in bursts
	# so sparks and chunks genuinely bounce off y = 0 and obstacles instead of falling underground!
	if one_shot and (sim == "sim_ember" or sim == "sim_chunk" or sim == "sim_spray"):
		var b_count := clampi(maxi(count_i, amount), 4, 96)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "BouncingPhysics_" + header
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.instance_count = b_count
		var b_mat := mat.duplicate() as StandardMaterial3D
		if base == "draw_trail" or base == "draw_tracer":
			b_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
			mm.mesh = _make_streak_mesh(1.4, 3.6, b_mat)
		elif base == "draw_geom" or sim == "sim_chunk":
			b_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
			var cm := BoxMesh.new()
			cm.size = Vector3(1.1, 0.7, 1.3)
			cm.material = b_mat
			mm.mesh = cm
		else:
			b_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			var bq := QuadMesh.new()
			bq.size = Vector2(2.0, 2.0)
			bq.material = b_mat
			mm.mesh = bq
		mmi.multimesh = mm
		var rng := RandomNumberGenerator.new()
		rng.seed = int(Time.get_ticks_usec()) ^ header.hash()
		var pts: Array = []
		for bi in b_count:
			var p0 := Vector3(
				rng.randf_range(-pos_var.x, pos_var.x) * 0.5,
				maxf(0.05, rng.randf_range(0.0, maxf(0.25, pos_var.y * 0.5))),
				rng.randf_range(-pos_var.z, pos_var.z) * 0.5
			)
			var vx := mean_vel.x + rng.randf_range(-vel_box.x, vel_box.x) * 0.5
			var vy := maxf(1.5, mean_vel.y + rng.randf_range(-vel_box.y * 0.3, maxf(3.0, vel_box.y * 0.65)))
			var vz := mean_vel.z + rng.randf_range(-vel_box.z, vel_box.z) * 0.5
			pts.append({
				"pos": p0,
				"vel": Vector3(vx, vy, vz) * scale_factor,
				"age": 0.0,
				"life": lifetime * rng.randf_range(0.65, 1.0),
			})
		p.add_child(mmi)
		# Hide the non-colliding CPUParticles3D draw pass while preserving all its
		# properties/mesh for introspection and rendering our floor-colliding MultiMesh instead.
		p.transparency = 1.0
		p.set_meta("bouncing_group", {
			"mmi": mmi,
			"particles": pts,
			"gravity": -9.8,
			"restitution": 0.42 if sim == "sim_chunk" else 0.58,
			"start_color": sc,
			"finish_color": fc,
			"start_radius": maxf(0.08, srad),
			"finish_radius": maxf(0.02, frad),
			"align_velocity": base == "draw_trail" or base == "draw_tracer",
		})

	return p


static func _build_light(doc: OdfDocument, header: String, scale_factor: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "FXLight_" + header
	var sc := _color(doc.get_value(header, "startColor", ""), Color(1, 0.6, 0.3, 1))
	light.light_color = Color(sc.r, sc.g, sc.b)
	var frad: float = doc.get_float(header, "finishRadius", 20.0)
	var srad: float = doc.get_float(header, "startRadius", 20.0)
	light.omni_range = clampf(maxf(srad, frad) * 0.45 * scale_factor, 3.0, 90.0)
	light.light_energy = clampf(3.5 + doc.get_float(header, "attenuateConstant", 1.0), 1.0, 8.0)
	light.shadow_enabled = false
	return light


## Build an animated ribbon preview from the header's declared radius/color
## and a deterministic curved sample path (APPROXIMATED, no native geometry).
static func build_ribbon_trail(doc: OdfDocument, header: String):
	if doc == null:
		return null
	var sr := maxf(0.02, doc.get_float(header, "startRadius", 0.3))
	var fr := maxf(0.02, doc.get_float(header, "finishRadius", sr))
	var col := _color(doc.get_value(header, "color1", doc.get_value(header, "color", "1 1 1 1")), Color(1, 1, 1, 0.8))
	var life := maxf(0.1, doc.get_float(header, "lifeTime", doc.get_float(header, "lifeSpan", 1.0)))
	var arc := clampf(doc.get_float(header, "animateTime", 1.0) * 0.35, 0.15, 1.8)
	var pts := RibbonTrailScript.build_path(Vector3(-2.2, 0.6, 0), Vector3(2.2, 0.6, -0.4), arc, 24)
	var trail = RibbonTrailScript.new()
	trail.name = "Trail_" + header
	trail.set_meta("header", header)
	trail.set_meta("render_base", "draw_trail")
	trail.set_meta("trail_radius", (sr + fr) * 0.5)
	trail.set_meta("trail_points", pts.size())
	trail.set_meta("trail_life", life)
	trail.configure(pts, (sr + fr) * 0.5, col, maxf(0.5, 3.0 / life), 1.0 / life)
	return trail


static func _vec(raw: String) -> Vector3:
	var parts := raw.replace(",", " ").split(" ", false)
	if parts.size() < 2:
		return Vector3.ZERO
	var x := parts[0].to_float()
	var y := parts[1].to_float()
	var z := parts[2].to_float() if parts.size() > 2 else 0.0
	return Vector3(x, y, z)


static func _color(raw: String, fallback: Color) -> Color:
	var parts := raw.replace(",", " ").split(" ", false)
	if parts.size() < 3:
		return fallback
	var r := parts[0].to_float()
	var g := parts[1].to_float()
	var b := parts[2].to_float()
	var a := parts[3].to_float() if parts.size() > 3 else 255.0
	if r > 1.5 or g > 1.5 or b > 1.5 or a > 1.5:
		return Color(clampf(r / 255.0, 0.0, 1.0), clampf(g / 255.0, 0.0, 1.0), clampf(b / 255.0, 0.0, 1.0), clampf(a / 255.0, 0.0, 1.0))
	return Color(clampf(r, 0.0, 1.0), clampf(g, 0.0, 1.0), clampf(b, 0.0, 1.0), clampf(a, 0.0, 1.0))
