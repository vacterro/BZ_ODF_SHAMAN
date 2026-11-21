class_name BzMeshReader
extends RefCounted
## Reader for Battlezone: Combat Commander baked .msh (DOCB v1) files.
##
## Parses the full node hierarchy (main_body, turret_y, turret_x, recoil,
## hardpoints hp_*), per-node transforms, vertex/surface geometry, .material
## definitions and DDS/TGA/PNG textures into a Godot Node3D hierarchy.
##
## Coordinate conversion: BZCC uses DirectX left-handed coordinates (+X right,
## +Y up, +Z forward) with CCW front faces. Flipping Z -> -Z converts to
## Godot right-handed (-Z forward, +Y up, +X right) AND converts triangle
## winding to Godot CW front faces in one proper basis change.

const MAGIC := "DOCB"
const TOK_CHILD := 0xf74c51ee
const TOK_SIBLING := 0xb8990880
const TOK_END := 0xa93eb864
const TOK_EOF := 0xe3bb47f1
const MAT_SIG := 0x9709513e
const MAT_TEX := 0x7951fc0b
const MAT_END := 0x9709513f
const MAX_COUNT := 1 << 20


## Resolve an ODF geometryName (e.g. "ivtank00.fbx" or "ivtank00.xsi") +
## optional geometryScale into an actual baked .msh file via ResourceIndex.
static func resolve_msh_for_geometry(index: ResourceIndex, geometry_name: String,
		context_odf: String = "", geometry_scale: float = 1.0) -> String:
	if index == null:
		return ""
	var clean := geometry_name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if clean == "":
		return ""
	var base := clean.get_basename()
	var candidates: Array[String] = []
	if absf(geometry_scale - 1.0) > 0.0001:
		candidates.append("%s_%.2f.msh" % [base, geometry_scale])
	candidates.append(base + ".msh")
	if clean.to_lower().ends_with(".msh"):
		candidates.insert(0, clean)
	for cand in candidates:
		var hit := index.find_asset_near(cand, ["msh"], context_odf)
		if hit != "":
			return hit
	return ""


## Inspect embedded BZCC DOCB animation metadata without inventing skinning.
## Returns pose/bone/animation counts and the actual baked file identity. A
## standalone .msha is only reported as a companion DOCB asset; no real sample
## is available on this host, so no skeletal bind pose is claimed.
static func inspect_animation(path: String, index: ResourceIndex = null,
		geometry_name: String = "") -> Dictionary:
	var out := {
		"ok": false, "path": path, "msha_path": "", "source": "", "bone_count": 0,
		"pose_count": 0, "animation_count": 0, "animation_detected": false,
		"node_count": 0, "errors": [],
	}
	if path == "" or not FileAccess.file_exists(path):
		out.errors.append("animation source not found: " + path)
		return out
	var msh_path := path
	if not path.to_lower().ends_with(".msh") and geometry_name != "" and index != null:
		msh_path = resolve_msh_for_geometry(index, geometry_name)
	if msh_path == "" or not FileAccess.file_exists(msh_path):
		out.errors.append("baked .msh source not found for animation inspection")
		return out
	var bytes := FileAccess.get_file_as_bytes(msh_path)
	if bytes.size() < 64 or bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		out.errors.append("not a DOCB animation source: " + msh_path.get_file())
		return out
	out.ok = true
	out.path = msh_path
	out.source = "DOCB .msh embedded animation metadata"
	if geometry_name != "":
		var base := geometry_name.get_basename()
		out.msha_path = index.find_asset_near(base + ".msha", ["msha"], "") if index != null else ""
	var sp := StreamPeerBuffer.new()
	sp.data_array = bytes
	sp.big_endian = false
	sp.seek(52)
	var _root := _read_text(sp, bytes)
	sp.seek(sp.get_position() + 4 + 76)
	for elem in [12, 12, 8, 4, 20]:
		if not _skip_array(sp, bytes.size(), elem):
			out.errors.append("unreadable geometry section while reaching animation metadata")
			return out
	var n_surf := sp.get_u32()
	if n_surf > MAX_COUNT:
		out.errors.append("bad surface count")
		return out
	for _i in n_surf:
		sp.seek(sp.get_position() + 12)
		_read_mat_record(sp, bytes)
	var n_weights := sp.get_u32()
	if n_weights > MAX_COUNT:
		out.errors.append("bad weight count")
		return out
	for _i in n_weights:
		var k := sp.get_u32()
		if k > MAX_COUNT or sp.get_position() + k * 6 > bytes.size():
			out.errors.append("bad weight list")
			return out
		sp.seek(sp.get_position() + k * 6)
	var n_reg := sp.get_u32()
	if n_reg > MAX_COUNT:
		out.errors.append("bad region count")
		return out
	for _i in n_reg:
		sp.seek(sp.get_position() + 16)
		_read_mat_record(sp, bytes)
	if not _skip_array(sp, bytes.size(), 2) or not _skip_array(sp, bytes.size(), 16):
		out.errors.append("unreadable surf/plane sections")
		return out
	var bone_count := sp.get_u32()
	if bone_count > MAX_COUNT or sp.get_position() + bone_count * 64 > bytes.size():
		out.errors.append("bad bone count")
		return out
	sp.seek(sp.get_position() + bone_count * 64)
	var n_poses := sp.get_u32()
	if n_poses > MAX_COUNT or sp.get_position() + n_poses * 36 > bytes.size():
		out.errors.append("bad pose count")
		return out
	sp.seek(sp.get_position() + n_poses * 36)
	var n_anim := sp.get_u32()
	out.bone_count = int(bone_count)
	out.pose_count = int(n_poses)
	out.animation_count = int(n_anim)
	out.animation_detected = n_poses > 0 or n_anim > 0
	var scene := build_scene(msh_path, index)
	if bool(scene.get("ok", false)):
		out.node_count = int((scene.get("provenance", {}) as Dictionary).get("node_count", 0))
	var scene_root = scene.get("root", null)
	if scene_root != null and scene_root is Node:
		(scene_root as Node).free()
	return out


## Parse a DOCB .msha file's header identity. This only proves the asset is a
## DOCB animation container; it does not decode tracks or skin weights.
static func inspect_msha_file(path: String) -> Dictionary:
	var out := {"ok": false, "path": path, "version": 0, "layout": 0, "body_len": 0, "errors": []}
	if path == "" or not FileAccess.file_exists(path):
		out.errors.append("msha file not found")
		return out
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 52 or bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		out.errors.append("not a DOCB .msha file")
		return out
	out.ok = true
	out.version = int(bytes.decode_u32(4))
	out.layout = int(bytes.decode_u32(8))
	out.body_len = int(bytes.decode_u32(48))
	return out


## Parse a DOCB .msh file and build a Godot Node3D tree + provenance metadata.
## Returns {ok, root, hardpoints, turret_y, turret_x, bounds, provenance, errors}.
static func build_scene(msh_path: String, index: ResourceIndex = null,
		source_format_hint: String = "") -> Dictionary:
	var out := {
		"ok": false,
		"root": null,
		"hardpoints": {},
		"turret_y": null,
		"turret_x": null,
		"bounds": AABB(),
		"provenance": {
			"msh_path": msh_path,
			"source_format": source_format_hint if source_format_hint != "" else "DOCB .msh",
			"node_count": 0,
			"vertex_count": 0,
			"triangle_count": 0,
			"materials": [],
			"textures_loaded": [],
			"hardpoints": [],
		},
		"errors": [],
	}
	if msh_path == "" or not FileAccess.file_exists(msh_path):
		out.errors.append("mesh file not found: " + msh_path)
		return out
	var bytes := FileAccess.get_file_as_bytes(msh_path)
	if bytes.size() < 64 or bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		out.errors.append("not a DOCB .msh file: " + msh_path.get_file())
		return out
	var version := bytes.decode_u32(4)
	var layout := bytes.decode_u32(8)
	var body_len := bytes.decode_u32(48)
	if version != 1 or layout != 1 or body_len > bytes.size() - 52:
		out.errors.append("unsupported DOCB version/layout in " + msh_path.get_file())
		return out

	var sp := StreamPeerBuffer.new()
	sp.data_array = bytes
	sp.big_endian = false
	sp.seek(52)

	var root_name := _read_text(sp, bytes)
	var _radius := sp.get_float()
	sp.seek(sp.get_position() + 76 + 28) # matrix(64) + half(12) + 7 words(28)

	# Skip combined geometry sections (we build per-node meshes from the node tree
	# so turrets/barrels rotate independently while sharing the exact same UVs/materials).
	if not _skip_array(sp, bytes.size(), 12): out.errors.append("bad positions"); return out
	if not _skip_array(sp, bytes.size(), 12): out.errors.append("bad normals"); return out
	if not _skip_array(sp, bytes.size(), 8): out.errors.append("bad uvs"); return out
	if not _skip_array(sp, bytes.size(), 4): out.errors.append("bad colors"); return out
	if not _skip_array(sp, bytes.size(), 20): out.errors.append("bad faces"); return out
	var n_surf := sp.get_u32()
	if n_surf > MAX_COUNT: out.errors.append("bad surf count"); return out
	for _i in n_surf:
		sp.seek(sp.get_position() + 12)
		_read_mat_record(sp, bytes)
	var n_weights := sp.get_u32()
	if n_weights > MAX_COUNT: out.errors.append("bad weight count"); return out
	for _i in n_weights:
		var k := sp.get_u32()
		if k > MAX_COUNT or sp.get_position() + k * 6 > bytes.size():
			out.errors.append("bad weight list")
			return out
		sp.seek(sp.get_position() + k * 6)
	var n_reg := sp.get_u32()
	if n_reg > MAX_COUNT: out.errors.append("bad reg count"); return out
	for _i in n_reg:
		sp.seek(sp.get_position() + 16)
		_read_mat_record(sp, bytes)
	if not _skip_array(sp, bytes.size(), 2): out.errors.append("bad surf indices"); return out
	if not _skip_array(sp, bytes.size(), 16): out.errors.append("bad planes"); return out
	if not _skip_array(sp, bytes.size(), 64): out.errors.append("bad bones"); return out
	var n_poses := sp.get_u32()
	if n_poses > MAX_COUNT or sp.get_position() + n_poses * 36 > bytes.size():
		out.errors.append("bad poses")
		return out
	sp.seek(sp.get_position() + n_poses * 36)
	var n_anim := sp.get_u32()
	var tree_pos := sp.get_position()
	if n_anim > 0:
		tree_pos = _find_node_tree_start(bytes, tree_pos, root_name)
		if tree_pos < 0:
			out.errors.append("could not locate node tree after animations")
			return out
		sp.seek(tree_pos)

	var mat_cache := {}
	var stats := {
		"nodes": 0,
		"verts": 0,
		"tris": 0,
		"materials": [],
		"textures": [],
		"hardpoints": {},
		"turret_y": null,
		"turret_x": null,
	}
	var root_node := _parse_node_recursive(sp, bytes, msh_path, index, mat_cache, stats)
	if root_node == null:
		out.errors.append("failed to parse node tree in " + msh_path.get_file())
		return out

	var bounds := _compute_bounds(root_node)
	out.ok = true
	out.root = root_node
	out.hardpoints = stats.hardpoints
	out.turret_y = stats.turret_y
	out.turret_x = stats.turret_x
	out.bounds = bounds
	out.provenance.node_count = stats.nodes
	out.provenance.vertex_count = stats.verts
	out.provenance.triangle_count = stats.tris
	out.provenance.materials = stats.materials
	out.provenance.textures_loaded = stats.textures
	out.provenance.hardpoints = (stats.hardpoints as Dictionary).keys()
	return out


static func _parse_node_recursive(sp: StreamPeerBuffer, bytes: PackedByteArray,
		msh_path: String, index: ResourceIndex, mat_cache: Dictionary,
		stats: Dictionary) -> Node3D:
	if sp.get_available_bytes() < 24:
		return null
	var node_name := _read_text(sp, bytes)
	if node_name == "":
		node_name = "node_%d" % stats.nodes
	var _node_idx := sp.get_u32()
	var _one := sp.get_u32()
	var _flags := sp.get_u32()
	var m := PackedFloat32Array()
	m.resize(16)
	for k in 16:
		m[k] = sp.get_float()
	var _u0 := sp.get_u32()
	if not _skip_array(sp, bytes.size(), 16):
		return null
	var n_verts := sp.get_u32()
	if n_verts > MAX_COUNT or sp.get_position() + n_verts * 32 > bytes.size():
		return null
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	positions.resize(n_verts)
	normals.resize(n_verts)
	uvs.resize(n_verts)
	for i in n_verts:
		var px := sp.get_float()
		var py := sp.get_float()
		var pz := sp.get_float()
		var nx := sp.get_float()
		var ny := sp.get_float()
		var nz := sp.get_float()
		var u := sp.get_float()
		var v := sp.get_float()
		positions[i] = Vector3(px, py, -pz)
		normals[i] = Vector3(nx, ny, -nz).normalized()
		uvs[i] = Vector2(u, v)

	var n_surfs := sp.get_u32()
	if n_surfs > MAX_COUNT:
		return null
	var surfs: Array[Dictionary] = []
	for _s in n_surfs:
		var _snode := sp.get_u32()
		var _sverts := sp.get_u32()
		var sindices := sp.get_u32()
		var _sfirst := sp.get_u32()
		var mrec := _read_mat_record(sp, bytes)
		surfs.append({"indices": sindices, "mat": mrec})

	var n_indices := sp.get_u32()
	if n_indices > MAX_COUNT or sp.get_position() + n_indices * 2 > bytes.size():
		return null
	var indices := PackedInt32Array()
	indices.resize(n_indices)
	for i in n_indices:
		indices[i] = sp.get_u16()

	var node: Node3D
	if n_verts > 0 and n_indices >= 3 and not surfs.is_empty():
		var mi := MeshInstance3D.new()
		var am := ArrayMesh.new()
		var cursor := 0
		for surf in surfs:
			var cnt := int(surf.indices)
			if cnt < 3 or cursor + cnt > n_indices:
				cursor += cnt
				continue
			var slice := indices.slice(cursor, cursor + cnt)
			cursor += cnt
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = positions
			arrays[Mesh.ARRAY_NORMAL] = normals
			arrays[Mesh.ARRAY_TEX_UV] = uvs
			arrays[Mesh.ARRAY_INDEX] = slice
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var surf_idx := am.get_surface_count() - 1
			var mat := _resolve_material(surf.mat, msh_path, index, mat_cache, stats)
			if mat != null:
				am.surface_set_material(surf_idx, mat)
		mi.mesh = am
		node = mi
		stats.verts += n_verts
		stats.tris += n_indices / 3
	else:
		node = Node3D.new()

	node.name = node_name
	node.transform = _convert_matrix(m)
	stats.nodes += 1
	var lower := node_name.to_lower()
	if lower.begins_with("hp_") or lower.begins_with("barrel"):
		(stats.hardpoints as Dictionary)[lower] = node
	if lower == "turret_y" and stats.turret_y == null:
		stats.turret_y = node
	elif lower == "turret_x" and stats.turret_x == null:
		stats.turret_x = node

	if sp.get_available_bytes() >= 4:
		var tok := sp.get_u32()
		if tok == TOK_CHILD:
			while sp.get_available_bytes() >= 4:
				var child := _parse_node_recursive(sp, bytes, msh_path, index, mat_cache, stats)
				if child != null:
					node.add_child(child)
				if sp.get_available_bytes() < 4:
					break
				var next_tok := sp.get_u32()
				if next_tok == TOK_SIBLING:
					continue
				elif next_tok == TOK_END or next_tok == TOK_EOF:
					break
				else:
					break
		elif tok == TOK_END or tok == TOK_EOF:
			pass
	return node


## Convert BZCC row-major LH matrix M into Godot RH Transform3D via S * M * S
## where S = diag(1, 1, -1).
static func _convert_matrix(m: PackedFloat32Array) -> Transform3D:
	var col_x := Vector3(m[0], m[1], -m[2])
	var col_y := Vector3(m[4], m[5], -m[6])
	var col_z := Vector3(-m[8], -m[9], m[10])
	var origin := Vector3(m[12], m[13], -m[14])
	return Transform3D(Basis(col_x, col_y, col_z), origin)


static func _resolve_material(mrec: Dictionary, msh_path: String,
		index: ResourceIndex, mat_cache: Dictionary, stats: Dictionary) -> StandardMaterial3D:
	var mat_name := str(mrec.get("name", ""))
	var tex_hint := str(mrec.get("texture", ""))
	var cache_key := (mat_name + "|" + tex_hint).to_lower()
	if mat_cache.has(cache_key):
		return mat_cache[cache_key]

	var std := StandardMaterial3D.new()
	std.albedo_color = Color(0.78, 0.75, 0.68, 1.0)
	std.roughness = 0.72
	std.metallic = 0.12
	std.metallic_specular = 0.35
	var diff_tex := tex_hint
	var norm_tex := ""
	var emis_tex := ""
	var mat_path := ""
	if mat_name != "":
		if index != null:
			mat_path = index.find_asset_near(mat_name, ["material"], msh_path)
		else:
			var direct := msh_path.get_base_dir().path_join(mat_name)
			if FileAccess.file_exists(direct):
				mat_path = direct
	if mat_path != "" and FileAccess.file_exists(mat_path):
		if not (stats.materials as Array).has(mat_name):
			(stats.materials as Array).append(mat_name)
		var parsed := _parse_material_file(FileAccess.get_file_as_string(mat_path))
		if parsed.has("diffuse_color"):
			std.albedo_color = parsed.diffuse_color
		if parsed.has("diffuse_tex"):
			diff_tex = str(parsed.diffuse_tex)
		if parsed.has("normal_tex"):
			norm_tex = str(parsed.normal_tex)
		if parsed.has("emissive_tex"):
			emis_tex = str(parsed.emissive_tex)

	if diff_tex != "":
		var tex := _load_texture_near(diff_tex, msh_path, index)
		if tex != null:
			std.albedo_texture = tex
			# When a diffuse texture is loaded, use pure neutral white multiplier
			# so the texture's true colors render without gray/white washout.
			std.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
			if not (stats.textures as Array).has(diff_tex):
				(stats.textures as Array).append(diff_tex)
	if norm_tex != "":
		var ntex := _load_texture_near(norm_tex, msh_path, index)
		if ntex != null:
			std.normal_enabled = true
			std.normal_texture = ntex
			std.normal_scale = 0.75
	if emis_tex != "":
		var etex := _load_texture_near(emis_tex, msh_path, index)
		if etex != null:
			std.emission_enabled = true
			std.emission_texture = etex
			# Critical: Godot 4 defaults to EMISSION_OP_ADD, which adds `std.emission`
			# to every pixel and whitewashes the entire vehicle mesh! Use MULTIPLY so
			# only non-black pixels in `_e.dds` emit light.
			std.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
			std.emission = Color(1.0, 1.0, 1.0, 1.0)
			std.emission_energy_multiplier = 0.65

	mat_cache[cache_key] = std
	return std


static func _parse_material_file(text: String) -> Dictionary:
	var out := {}
	var section := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("//") or line.begins_with(";"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2).to_lower()
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var k := line.substr(0, eq).strip_edges().to_lower()
		var v := line.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		if section == "solid" and k == "diffuse":
			var p := v.split(" ", false)
			if p.size() >= 3:
				out["diffuse_color"] = Color(p[0].to_float(), p[1].to_float(), p[2].to_float(), p[3].to_float() if p.size() > 3 else 1.0)
		elif section == "texture":
			if k == "diffuse":
				out["diffuse_tex"] = v
			elif k == "normal":
				out["normal_tex"] = v
			elif k == "emissive":
				out["emissive_tex"] = v
	return out


static func _load_texture_near(tex_name: String, msh_path: String, index: ResourceIndex) -> Texture2D:
	var path := ""
	if index != null:
		path = index.find_asset_near(tex_name, ["dds", "tga", "png", "jpg"], msh_path)
	else:
		for sub in ["textures", ""]:
			var p := msh_path.get_base_dir().path_join(sub).path_join(tex_name) if sub != "" else msh_path.get_base_dir().path_join(tex_name)
			if FileAccess.file_exists(p):
				path = p
				break
	if path == "" or not FileAccess.file_exists(path):
		return null
	var img := load_image_any(path)
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


## Load DDS, TGA, PNG or JPG into an Image cleanly without triggering
## unsupported extension errors from Image.load_from_file on .dds.
static func load_image_any(path: String) -> Image:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var ext := path.get_extension().to_lower()
	if ext == "dds":
		var buf := FileAccess.get_file_as_bytes(path)
		if buf.size() < 128 or buf.slice(0, 4).get_string_from_ascii() != "DDS ":
			return null
		var pf_flags := buf.decode_u32(80)
		if (pf_flags & 0x4) != 0: # DDPF_FOURCC
			var fourcc := buf.slice(84, 88).get_string_from_ascii()
			# Skip formats unsupported by Godot's built-in DDS reader (e.g. BC5S) cleanly.
			if fourcc == "BC5S" or fourcc == "":
				return null
		elif (pf_flags & 0x40) == 0 and (pf_flags & 0x20000) == 0:
			return null
		var img := Image.new()
		if img.load_dds_from_buffer(buf) == OK and not img.is_empty():
			return img
		return null
	var img2 := Image.load_from_file(path)
	if img2 != null and not img2.is_empty():
		return img2
	return null


static func _read_text(sp: StreamPeerBuffer, bytes: PackedByteArray) -> String:
	if sp.get_available_bytes() < 2:
		return ""
	var n := sp.get_u16()
	if n == 0:
		return ""
	if sp.get_position() + n > bytes.size():
		sp.seek(bytes.size())
		return ""
	var s := bytes.slice(sp.get_position(), sp.get_position() + n - 1).get_string_from_utf8()
	sp.seek(sp.get_position() + n)
	return s


static func _skip_array(sp: StreamPeerBuffer, total_size: int, elem_size: int) -> bool:
	if sp.get_available_bytes() < 4:
		return false
	var count := sp.get_u32()
	if count > MAX_COUNT or sp.get_position() + count * elem_size > total_size:
		return false
	sp.seek(sp.get_position() + count * elem_size)
	return true


static func _read_mat_record(sp: StreamPeerBuffer, bytes: PackedByteArray) -> Dictionary:
	var rec := {"name": "", "texture": ""}
	if sp.get_available_bytes() < 4:
		return rec
	var sig := sp.get_u32()
	if sig != MAT_SIG:
		sp.seek(sp.get_position() - 4)
		return rec
	rec["name"] = _read_text(sp, bytes)
	if sp.get_available_bytes() < 68:
		return rec
	sp.seek(sp.get_position() + 68)
	if sp.get_available_bytes() >= 4:
		var p1 := sp.get_u32()
		if p1 == MAT_TEX:
			rec["texture"] = _read_text(sp, bytes)
			if sp.get_available_bytes() >= 8:
				sp.seek(sp.get_position() + 8)
		else:
			sp.seek(sp.get_position() - 4)
	if sp.get_available_bytes() >= 4:
		var p2 := sp.get_u32()
		if p2 != MAT_END:
			sp.seek(sp.get_position() - 4)
	return rec


static func _find_node_tree_start(bytes: PackedByteArray, from_pos: int, root_name: String) -> int:
	if root_name == "":
		return -1
	var pat := root_name.to_utf8_buffer()
	var n := pat.size()
	for i in range(from_pos + 2, bytes.size() - n - 8):
		if bytes.decode_u16(i - 2) != n + 1:
			continue
		var matched := true
		for j in n:
			if bytes[i + j] != pat[j]:
				matched = false
				break
		if matched and bytes[i + n] == 0:
			# Verify node_idx == 0 and next word == 1
			var after := i + n + 1
			if after + 8 <= bytes.size() and bytes.decode_u32(after) == 0 and bytes.decode_u32(after + 4) == 1:
				return i - 2
	return -1


static func _compute_bounds(root: Node3D) -> AABB:
	var box := AABB()
	var has := false
	var stack: Array[Dictionary] = [{"node": root, "xf": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var item: Dictionary = stack.pop_back()
		var n: Node3D = item.node
		var xf: Transform3D = (item.xf as Transform3D) * n.transform
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				var aabb := mi.mesh.get_aabb()
				for corner_i in 8:
					var c := xf * aabb.get_endpoint(corner_i)
					if not has:
						box = AABB(c, Vector3.ZERO)
						has = true
					else:
						box = box.expand(c)
		for child in n.get_children():
			if child is Node3D:
				stack.append({"node": child, "xf": xf})
	return box if has else AABB(Vector3(-2, 0, -2), Vector3(4, 2, 4))
