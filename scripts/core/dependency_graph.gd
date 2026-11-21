class_name DependencyGraph
extends RefCounted
## Forward dependency resolution for ODFs: weapons -> ordnance -> explosions ->
## particle renders -> textures/sounds/models. Reports missing files, duplicate
## sources and cycles instead of hiding them.

const MAX_NODES := 400
const MAX_DEPTH := 8

var nodes: Dictionary = {}      # abs path -> {doc, depth, title, refs}
var edges: Array[Dictionary] = []
var missing: Array[Dictionary] = []
var cycles: Array[Dictionary] = []


func analyze(doc: OdfDocument, index: ResourceIndex) -> Dictionary:
	nodes.clear()
	edges.clear()
	missing.clear()
	cycles.clear()
	if doc == null:
		return summary()
	_walk(doc, str(doc.source_path), 0, index, [])
	return summary()


func _walk(doc: OdfDocument, path: String, depth: int, index: ResourceIndex, stack: Array) -> void:
	if nodes.size() >= MAX_NODES or depth > MAX_DEPTH:
		return
	if nodes.has(path):
		return
	nodes[path] = {
		"doc": doc,
		"depth": depth,
		"title": doc.get_display_name(),
		"refs": [],
		"is_render": doc.is_render_odf(),
	}
	var refs := extract_refs(doc)
	nodes[path]["refs"] = refs
	for ref in refs:
		var target := ""
		if str(ref.kind) == "odf_inherit":
			target = index.resolve_path_from(str(ref.value), path)
			if target == "":
				continue  # classLabel is usually a game label, not a file.
		elif str(ref.kind) == "odf" or str(ref.kind) == "render":
			target = index.resolve_path_from(str(ref.value), path)
		elif str(ref.kind) == "model" or str(ref.kind) == "texture" or str(ref.kind) == "audio":
			target = index.find_asset(str(ref.value), _exts_for(str(ref.kind)))
		if target == "":
			missing.append({"from": path, "key": ref.key, "value": ref.value, "kind": ref.kind})
			edges.append({"from": path, "from_title": doc.get_display_name(), "to": "", "key": ref.key, "value": ref.value, "resolved": false, "kind": ref.kind})
			continue
		edges.append({"from": path, "from_title": doc.get_display_name(), "to": target, "key": ref.key, "value": ref.value, "resolved": true, "kind": ref.kind})
		if str(ref.kind) == "odf" or str(ref.kind) == "render" or str(ref.kind) == "odf_inherit":
			if stack.has(target):
				cycles.append({"from": path, "to": target, "key": ref.key})
				continue
			var child := OdfDocument.load_cached(target)
			if child != null:
				_walk(child, target, depth + 1, index, stack + [target])


func _exts_for(kind: String) -> Array[String]:
	match kind:
		"model":
			return ["msh", "msha", "fbx", "xsi"]
		"texture":
			return ["tga", "dds", "png", "jpg", "bmp"]
		"audio":
			return ["wav", "ogg", "mp3"]
		_:
			return []


static func extract_refs(doc: OdfDocument) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in doc.entries:
		if e.shadowed_by != null:
			continue
		var key: String = str(e.key_raw).to_lower()
		var value: String = e.core_value()
		if value == "":
			continue
		var kind := ""
		if key.begins_with("weaponname"):
			kind = "odf"
		elif key == "ordname" or key == "altname":
			kind = "odf"
		elif key.begins_with("xpl"):
			kind = "odf"
		elif key.begins_with("particleclass"):
			kind = "render"
		elif key == "rendername" or key.begins_with("rendername"):
			kind = "render"
		elif key.begins_with("effectname"):
			kind = "render"
		elif key == "emitname" or key == "flashname":
			kind = "render"
		elif key == "shotgeometry":
			kind = "model"
		elif key.ends_with("sound") or key.contains("soundeffect"):
			kind = "audio"
		elif key == "texturename" or key == "texture":
			kind = "texture"
		elif key == "classlabel":
			# classLabel doubles as ODF inheritance when it names a real file.
			kind = "odf_inherit"
		if kind == "":
			continue
		out.append({"key": e.key_raw, "value": value, "kind": kind, "header": e.header, "line": e.line})
	return out


func summary() -> Dictionary:
	var render_count := 0
	for n in nodes.values():
		if bool(n.get("is_render", false)):
			render_count += 1
	return {
		"nodes": nodes,
		"edges": edges,
		"missing": missing,
		"cycles": cycles,
		"node_count": nodes.size(),
		"edge_count": edges.size(),
		"missing_count": missing.size(),
		"cycle_count": cycles.size(),
		"render_count": render_count,
	}


func children_of(path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in edges:
		if str(e.from) == path and bool(e.resolved):
			out.append(e)
	return out


func display_tree_lines() -> Array[String]:
	var lines: Array[String] = []
	var root := ""
	var best := 999
	for p in nodes:
		var d := int(nodes[p].depth)
		if d < best:
			best = d
			root = p
	if root == "":
		return lines
	_lines(root, "", lines, {})
	return lines


func _lines(path: String, prefix: String, lines: Array[String], seen: Dictionary) -> void:
	if seen.has(path):
		lines.append(prefix + "... (cycle)")
		return
	seen[path] = true
	if nodes.has(path):
		lines.append(prefix + str(nodes[path].title))
	for e in children_of(path):
		_lines(str(e.to), prefix + "  ", lines, seen)
