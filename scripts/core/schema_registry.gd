class_name SchemaRegistry
extends RefCounted
## ODF documentation registry extracted from the local BZCC docs
## (tools/extract_schema.py -> data/odf_schema.json). The registry supplies
## descriptions, documented defaults and type hints. It never invents bounds.

var classes: Dictionary = {}
var particle: Dictionary = {}
var loaded: bool = false
var source_note: String = ""

const ODF_SCHEMA_PATH := "res://data/odf_schema.json"
const PARTICLE_SCHEMA_PATH := "res://data/particle_schema.json"


func load_schemas() -> bool:
	var odf := _load_json(ODF_SCHEMA_PATH)
	if odf.is_empty():
		source_note = "Schema registry unavailable (%s missing)." % ODF_SCHEMA_PATH
		return false
	classes = odf.get("classes", {})
	particle = _load_json(PARTICLE_SCHEMA_PATH)
	loaded = true
	source_note = "ODF schema: %d classes, %d properties (from %s)" % [
		classes.size(), property_count(), str(odf.get("generatedFrom", "local docs"))
	]
	return true


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var txt := FileAccess.get_file_as_string(path)
	var jres := WorkspaceStore.parse_json_safe(txt)
	var parsed = jres.get("data", null) if bool(jres.get("ok", false)) else null
	return parsed if parsed is Dictionary else {}


func property_count() -> int:
	var n := 0
	for c in classes.values():
		n += (c.get("properties", {}) as Dictionary).size()
	return n


func class_info(type_name: String) -> Dictionary:
	return classes.get(type_name, {})


func class_tree(type_name: String) -> Array[String]:
	var info: Dictionary = classes.get(type_name, {})
	var tree: String = str(info.get("classTree", ""))
	if tree == "":
		return []
	var out: Array[String] = []
	for part in tree.split("->", false):
		out.append(part.strip_edges())
	return out


## Ancestor class names (including the class itself), derived from the
## documented class tree, e.g. CannonClass -> [EntityClass, WeaponClass, CannonClass].
func ancestry(type_name: String) -> Array[String]:
	var out: Array[String] = []
	for part in class_tree(type_name):
		var candidate: String = part + "Class"
		if classes.has(candidate):
			out.append(candidate)
	if out.is_empty() and classes.has(type_name):
		out.append(type_name)
	return out


func property_info(header_name: String, key: String) -> Dictionary:
	var leaf := header_name
	var chain := ancestry(leaf)
	if chain.is_empty():
		chain = [leaf]
	# Most-specific first so overrides win.
	chain.reverse()
	for cls in chain:
		var info: Dictionary = classes.get(cls, {})
		var props: Dictionary = info.get("properties", {})
		if props.has(key):
			var p: Dictionary = props[key].duplicate()
			p["definedIn"] = cls
			return p
	# Case-insensitive fallback (docs and corpus disagree on capitalisation).
	for cls in chain:
		var info: Dictionary = classes.get(cls, {})
		var props: Dictionary = info.get("properties", {})
		for pk in props:
			if str(pk).to_lower() == key.to_lower():
				var p2: Dictionary = props[pk].duplicate()
				p2["definedIn"] = cls
				return p2
	return {}


func describe(header_name: String, key: String) -> String:
	var info := property_info(header_name, key)
	return str(info.get("description", ""))


func documented_default(header_name: String, key: String) -> String:
	var info := property_info(header_name, key)
	if info.is_empty():
		return ""
	var d = info.get("defaultRaw", null)
	return "" if d == null else str(d)


## Infer a friendly editor type from schema + raw value.
func infer_type(header_name: String, key: String, raw_value: String) -> String:
	var info := property_info(header_name, key)
	var hint := str(info.get("typeHint", ""))
	if hint == "vector3":
		return "vector3"
	if hint == "hex":
		return "bitmask"
	if hint == "bool":
		return "bool"
	if hint == "int":
		return "int"
	if hint == "float":
		return "float"
	if hint == "string":
		return "string"
	var core := OdfDocument.core_value(raw_value)
	var lk := key.to_lower()
	if lk.begins_with("damagevalue") or lk.ends_with("count") or lk.ends_with("mask") or lk.ends_with("ammo") or lk.contains("num"):
		if core.is_valid_int():
			return "int"
	if lk.contains("color"):
		if core.split(" ", false).size() == 4:
			return "color"
	if core.to_lower() in ["true", "false"]:
		return "bool"
	if core.begins_with("0x"):
		return "bitmask"
	var parts := core.split(" ", false)
	if parts.size() == 3 and parts[0].is_valid_float() and parts[1].is_valid_float() and parts[2].is_valid_float():
		if lk.contains("veloc") or lk.contains("position") or lk.contains("variance") or lk.contains("offset") or lk.contains("vector") or lk.contains("rotation"):
			return "vector3"
		return "vector3"
	if core.is_valid_int():
		return "int"
	if core.is_valid_float():
		return "float"
	if lk.contains("name") or lk.ends_with("sound") or lk.contains("texture") or lk.contains("geometry") or lk.contains("class"):
		return "reference"
	return "string"


func enum_values(header_name: String, key: String) -> Array[String]:
	var lk := key.to_lower()
	if lk == "armorclass":
		return ["N", "L", "H", "S", "D", "A"]
	if lk == "renderbase":
		return particle.get("renderBases", [])
	if lk == "simulatebase":
		return particle.get("simulateBases", [])
	return []


func render_base_properties(base: String) -> Dictionary:
	var sections: Dictionary = particle.get("renderSections", {})
	var s: Dictionary = sections.get(base, {})
	return s.get("properties", {})


func render_bases() -> Array:
	return particle.get("renderBases", [])


func simulate_bases() -> Array:
	return particle.get("simulateBases", [])


## Flat list of class names sorted, used by search/UI.
func class_names() -> Array[String]:
	var out: Array[String] = []
	for k in classes.keys():
		out.append(str(k))
	out.sort()
	return out


func search_properties(query: String, limit: int = 200) -> Array[Dictionary]:
	var q := query.strip_edges().to_lower()
	var out: Array[Dictionary] = []
	if q == "":
		return out
	for cls_name in classes:
		var props: Dictionary = classes[cls_name].get("properties", {})
		for pname in props:
			var p: Dictionary = props[pname]
			if str(pname).to_lower().contains(q) or str(p.get("description", "")).to_lower().contains(q):
				out.append({
					"class": cls_name,
					"name": pname,
					"defaultRaw": p.get("defaultRaw", null),
					"description": p.get("description", ""),
					"docLine": p.get("docLine", 0),
				})
				if out.size() >= limit:
					return out
	return out
