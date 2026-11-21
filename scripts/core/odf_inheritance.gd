class_name OdfInheritance
extends RefCounted
## Resolves ODF inheritance: classLabel names a parent ODF file, and the child
## only declares differences. Properties are merged ancestor-first, with the
## child's last duplicate winning. Some properties are documented as not
## inherited (e.g. shotRadius); consumers must not assume every merged value is
## inherited by the game.

const MAX_DEPTH := 6

## The local ODF documentation marks these properties as NOT inherited by the
## game. The rule is scoped to the header that documents it, so e.g.
## MorphTankClass.unitStatus (a deployed-state override with no such note) is
## still inherited normally.
const NON_INHERITED := {
	"gameobjectclass|uniticon": true,
	"gameobjectclass|unitstatus": true,
	"gameobjectclass|ignoremissinginf": true,
	"ordnanceclass|shotradius": true,
}

static var _cache: Dictionary = {}


static func clear_cache() -> void:
	_cache.clear()


static func parent_path(doc: OdfDocument, index: ResourceIndex) -> String:
	if doc == null or index == null:
		return ""
	for e in doc.effective_entries():
		if str(e.key_raw).to_lower() == "classlabel":
			var name: String = e.core_value()
			if name == "":
				continue
			var hit := index.resolve_path_from(name, doc.source_path)
			if hit != "" and hit != doc.source_path:
				return hit
			return ""
	return ""


## [doc, parent, grandparent, ...]
static func chain(doc: OdfDocument, index: ResourceIndex) -> Array:
	var out: Array = []
	if doc == null:
		return out
	var seen: Dictionary = {}
	var cur := doc
	var depth := 0
	while cur != null and depth <= MAX_DEPTH:
		out.append(cur)
		seen[cur.source_path] = true
		var parent := parent_path(cur, index)
		if parent == "" or seen.has(parent):
			break
		var pdoc := OdfDocument.load_cached(parent)
		if pdoc == null:
			break
		cur = pdoc
		depth += 1
	return out


## Merged effective properties, ancestor-first. Each row records provenance.
static func merged(doc: OdfDocument, index: ResourceIndex) -> Array:
	if doc == null:
		return []
	var docs := chain(doc, index)
	# Dependency-aware key: every path in the resolved chain contributes its
	# current revision, so editing a parent invalidates all descendants.
	var key_parts: Array[String] = []
	for d in docs:
		key_parts.append(str(d.source_path) + ":" + str(d.revision))
	var generation := index.generation if index != null else 0
	var cache_key := "g%d|%s" % [generation, "|".join(PackedStringArray(key_parts))]
	if _cache.has(cache_key):
		return _cache[cache_key]
	docs.reverse()
	var map: Dictionary = {}
	for d in docs:
		var ancestor: bool = d != doc
		for e in d.effective_entries():
			if ancestor and is_non_inherited(e):
				continue
			var id := str(e.header).to_lower() + "|" + str(e.key_raw).to_lower() + str(e.suffix).to_lower()
			map[id] = {
				"header": e.header,
				"key": e.key_raw,
				"suffix": e.suffix,
				"value": e.core_value(),
				"raw": e.value_raw,
				"line": e.line,
				"inherited": d != doc,
				"source": d.source_path,
			}
	var out: Array[Dictionary] = []
	for v in map.values():
		out.append(v)
	_cache[cache_key] = out
	return out


## True when the documentation says the game does not inherit this property
## from a parent ODF. Suffixed variants (e.g. unitIcon1) are not covered by the
## documented rule and keep normal inheritance.
static func is_non_inherited(entry) -> bool:
	if entry == null or str(entry.suffix) != "":
		return false
	var id := str(entry.header).to_lower() + "|" + str(entry.key_raw).to_lower()
	return NON_INHERITED.has(id)


static func describe_chain(doc: OdfDocument, index: ResourceIndex) -> String:
	var names: Array[String] = []
	for d in chain(doc, index):
		names.append(d.get_display_name())
	return " -> ".join(PackedStringArray(names))


static func inherited_count(doc: OdfDocument, index: ResourceIndex) -> int:
	var n := 0
	for row in merged(doc, index):
		if bool(row.inherited):
			n += 1
	return n
