class_name OdfDocument
extends RefCounted
## Lossless, source-aware ODF document.
##
## The document keeps the original text and character spans for every value.
## Editing a property splices only that value's character range, so comments,
## ordering, duplicate declarations, whitespace and the original newline
## convention survive untouched. With no edits, to_bytes() returns the exact
## original bytes.

signal changed
signal undo_state_changed

const HEADER_RE := "\\[([^\\[\\]]+)\\]"
const PROP_RE := "^\\s*([A-Za-z_][A-Za-z0-9_\\.]*)\\s*(\\([^)]*\\))?\\s*=\\s*(.*)$"

class OdfHeader:
	var name: String = ""
	var line: int = 0
	## Stable identity of this physical occurrence, independent of its name.
	var id: String = ""
	var occurrence_index: int = 0
	var end_line: int = 0
	var first_entry = null
	var last_entry = null

class OdfEntry:
	var header: String = ""
	var key_raw: String = ""
	var key_lc: String = ""
	var header_id: String = ""
	var occurrence_index: int = 0
	var key_occurrence_index: int = 0
	var header_key_occurrence_index: int = 0
	var suffix: String = ""
	var value_raw: String = ""
	var value_start: int = 0
	var value_end: int = 0
	var line: int = 0
	var comment: String = ""
	# Duplicate links are weak: entry -> entry strong references form a reference
	# cycle, and a cyclic RefCounted is never freed (it leaked one pair per
	# duplicate property at every exit). WeakRef keeps the same public values
	# (object or null) while letting the document own the entries.
	var _shadowed_by = null
	var _shadow_of = null
	var shadowed_by:
		get:
			return _shadowed_by.get_ref() if _shadowed_by is WeakRef else null
		set(value):
			_shadowed_by = weakref(value) if value != null else null
	var shadow_of:
		get:
			return _shadow_of.get_ref() if _shadow_of is WeakRef else null
		set(value):
			_shadow_of = weakref(value) if value != null else null

	func full_key() -> String:
		return key_raw + suffix

	func is_shadowed() -> bool:
		return shadowed_by != null

	func core_value() -> String:
		return OdfDocument.core_value(value_raw)

var source_path: String = ""
var text: String = ""
var original_bytes: PackedByteArray = PackedByteArray()
var encoding: String = "utf-8"
var has_bom: bool = false

var entries: Array = []
## Unique header names in source order (legacy view used by the Inspector).
var headers: Array = []
## Every physical [Header] occurrence, including duplicates, in source order.
var header_occurrences: Array = []
var warnings: Array[String] = []

## Last materialized bytes and the exact text they represent. These are not
## the original source bytes once a workspace save happens: to_bytes() must
## return the current working state even when dirty is false.
var saved_bytes: PackedByteArray = PackedByteArray()
var saved_text: String = ""

var dirty: bool = false
## Monotonic content revision. Consumers key caches on it so a parent edit is
## visible to every descendant without a global cache flush.
var revision: int = 0
## Workspace provenance. source_path stays the original game path while the
## bytes may come from a saved override.
var workspace_override: bool = false
var workspace_conflict: bool = false
var workspace_rel: String = ""
var workspace_source_md5: String = ""
## Fingerprint of the file this document was loaded from, used to surface
## external edits instead of silently serving stale cached content.
var source_hash: String = ""
var _undo: Array[String] = []
var _redo: Array[String] = []
var _max_history: int = 100
var _compound_depth: int = 0
var _compound_pushed: bool = false

## Test-only fault injection for atomic graph Move rollback regression.
static var fault_append_entry_fail_key: String = ""

# Shared document store: the inspector, dependency graph, inheritance resolver
# and simulation must all see the same in-memory document so edits are live.
static var _cache: Dictionary = {}


static func load_cached(path: String) -> OdfDocument:
	if _cache.has(path):
		var cached_doc = _cache[path]
		if cached_doc is OdfDocument:
			var current := FileAccess.get_md5(path) if FileAccess.file_exists(path) else ""
			if cached_doc.workspace_override:
				if current != "" and cached_doc.workspace_source_md5 != "" and current != cached_doc.workspace_source_md5:
					cached_doc.workspace_conflict = true
				return cached_doc
			if current != "" and cached_doc.source_hash != "" and current != cached_doc.source_hash:
				if cached_doc.dirty:
					cached_doc.workspace_conflict = true
					return cached_doc
				_cache.erase(path)
			else:
				return cached_doc
	var doc := load_file(path)
	if doc != null:
		_cache[path] = doc
	return doc


static func cache_document(doc: OdfDocument) -> void:
	if doc != null and doc.source_path != "":
		_cache[doc.source_path] = doc


static func has_cached(path: String) -> bool:
	return _cache.has(path)


static func cached(path: String):
	return _cache.get(path)


## Every cached document carrying a workspace override or unsaved edits.
static func workspace_documents() -> Array:
	var out: Array = []
	for key in _cache:
		var doc = _cache[key]
		if doc is OdfDocument and doc.source_path != "" and (doc.dirty or doc.workspace_override):
			out.append(doc)
	out.sort_custom(func(a, b): return str(a.source_path) < str(b.source_path))
	return out


static func invalidate_cache(path: String) -> void:
	_cache.erase(path)


static func clear_all_cache() -> void:
	_cache.clear()


## Documents with unsaved in-memory edits, sorted by path. Used by save-all so
## no edited document is silently left behind.
static func dirty_documents() -> Array:
	var out: Array = []
	for key in _cache:
		var doc = _cache[key]
		if doc is OdfDocument and doc.dirty and doc.source_path != "":
			out.append(doc)
	out.sort_custom(func(a, b): return str(a.source_path) < str(b.source_path))
	return out


static func parse_text(value: String, path: String = "") -> OdfDocument:
	var doc := OdfDocument.new()
	doc.source_path = path
	doc.text = value
	doc._parse()
	doc.saved_text = value
	doc.saved_bytes = value.to_utf8_buffer()
	return doc


static func decode_bytes_info(bytes: PackedByteArray, forced_encoding: String = "", forced_has_bom: int = -1) -> Dictionary:
	var encoding_out := "utf-8"
	var bom_out := false
	var body := bytes
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		bom_out = true
		body = bytes.slice(3)
		encoding_out = "utf-8"
	elif bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE:
		bom_out = true
		body = bytes.slice(2)
		encoding_out = "utf-16le"
	elif bytes.size() >= 2 and bytes[0] == 0xFE and bytes[1] == 0xFF:
		bom_out = true
		body = bytes.slice(2)
		encoding_out = "utf-16be"
	else:
		if forced_encoding != "":
			encoding_out = forced_encoding
		if forced_has_bom >= 0:
			bom_out = forced_has_bom != 0
	var decoded_text := ""
	if encoding_out == "utf-16le":
		decoded_text = body.get_string_from_utf16()
	elif encoding_out == "utf-16be":
		var swapped := body.duplicate()
		var i := 0
		while i + 1 < swapped.size():
			var t := swapped[i]
			swapped[i] = swapped[i + 1]
			swapped[i + 1] = t
			i += 2
		decoded_text = swapped.get_string_from_utf16()
	else:
		decoded_text = body.get_string_from_utf8()
	return {
		"text": decoded_text,
		"encoding": encoding_out,
		"has_bom": bom_out,
	}


static func parse_bytes(bytes: PackedByteArray, path: String = "", forced_encoding: String = "", forced_has_bom: int = -1) -> OdfDocument:
	var doc := OdfDocument.new()
	doc.source_path = path
	doc.original_bytes = bytes.duplicate()
	var info := decode_bytes_info(bytes, forced_encoding, forced_has_bom)
	doc.encoding = str(info.get("encoding", "utf-8"))
	doc.has_bom = bool(info.get("has_bom", false))
	doc.text = str(info.get("text", ""))
	doc._parse()
	doc.saved_text = doc.text
	doc.saved_bytes = bytes.duplicate()
	return doc


static func load_file(path: String) -> OdfDocument:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	var doc := parse_bytes(bytes, path)
	doc.source_hash = FileAccess.get_md5(path)
	return doc


func get_display_name() -> String:
	return source_path.get_file()


func _parse() -> void:
	entries.clear()
	headers.clear()
	header_occurrences.clear()
	warnings.clear()
	var line_starts: Array[int] = [0]
	var i := 0
	while i < text.length():
		if text[i] == "\n":
			line_starts.append(i + 1)
		i += 1
	var lines := text.split("\n")
	var header_map: Dictionary = {}
	var occurrence_counts: Dictionary = {}
	var key_occurrence_counts: Dictionary = {}
	var header_key_occurrence_counts: Dictionary = {}
	var seen: Dictionary = {}
	var current: OdfHeader = null
	var in_block := false
	var line_no := 0
	for raw_line in lines:
		var start: int = line_starts[line_no] if line_no < line_starts.size() else 0
		var line: String = raw_line
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)
		var scan := _scan_comment(line, in_block)
		in_block = scan["block"]
		var comment_start: int = scan["comment_start"]
		var code: String = line if comment_start < 0 else line.substr(0, comment_start)
		var comment: String = "" if comment_start < 0 else line.substr(comment_start)
		var prop_base := 0
		var header_re := RegEx.create_from_string(HEADER_RE)
		if code.strip_edges().begins_with("["):
			var matches := header_re.search_all(code)
			if not matches.is_empty():
				for m in matches:
					var hname: String = m.get_string(1).strip_edges()
					var hkey := hname.to_lower()
					var occ := OdfHeader.new()
					occ.name = hname
					occ.line = line_no + 1
					occ.occurrence_index = int(occurrence_counts.get(hkey, 0))
					occ.id = "%s#%d" % [hkey, occ.occurrence_index]
					occurrence_counts[hkey] = occ.occurrence_index + 1
					header_occurrences.append(occ)
					if not header_map.has(hkey):
						var canonical := OdfHeader.new()
						canonical.name = hname
						canonical.line = line_no + 1
						canonical.id = occ.id
						headers.append(canonical)
						header_map[hkey] = canonical
					current = occ
				prop_base = matches[matches.size() - 1].get_end()
		var prop_code := code.substr(prop_base)
		if prop_code.strip_edges().is_empty():
			line_no += 1
			continue
		if not prop_code.contains("="):
			if prop_code.strip_edges().begins_with("["):
				line_no += 1
				continue
			line_no += 1
			continue
		var re := RegEx.create_from_string(PROP_RE)
		var pm := re.search(prop_code)
		if pm == null:
			warnings.append("line %d: malformed property ignored: %s" % [line_no + 1, prop_code.strip_edges()])
			line_no += 1
			continue
		if current == null:
			warnings.append("line %d: property outside any header: %s" % [line_no + 1, prop_code.strip_edges()])
			line_no += 1
			continue
		var key_part: String = pm.get_string(1)
		var suffix: String = pm.get_string(2)
		var value_rel_start: int = prop_base + pm.get_start(3)
		var value_rel_end: int = prop_base + pm.get_end(3)
		var raw_value: String = code.substr(value_rel_start, value_rel_end - value_rel_start)
		# Trim trailing whitespace from the captured value, keep inner bytes.
		var trimmed := raw_value.rstrip(" \t")
		value_rel_end = value_rel_start + trimmed.length()
		var e := OdfEntry.new()
		e.header = current.name
		e.header_id = current.id
		e.occurrence_index = current.occurrence_index
		e.key_raw = key_part
		e.key_lc = (key_part + suffix).to_lower()
		e.suffix = suffix
		e.value_raw = trimmed
		e.value_start = start + value_rel_start
		e.value_end = start + value_rel_end
		e.line = line_no + 1
		e.comment = comment
		var key_id := current.name.to_lower() + "|" + e.key_lc
		var hkey_id := current.id + "|" + e.key_lc
		e.key_occurrence_index = int(key_occurrence_counts.get(key_id, 0))
		key_occurrence_counts[key_id] = e.key_occurrence_index + 1
		e.header_key_occurrence_index = int(header_key_occurrence_counts.get(hkey_id, 0))
		header_key_occurrence_counts[hkey_id] = e.header_key_occurrence_index + 1
		if seen.has(key_id):
			var prev = seen[key_id]
			prev.shadowed_by = e
			e.shadow_of = prev
		seen[key_id] = e
		entries.append(e)
		if current.first_entry == null:
			current.first_entry = e
		current.last_entry = e
		var canonical = header_map.get(current.name.to_lower(), null)
		if canonical != null:
			if canonical.first_entry == null:
				canonical.first_entry = e
			canonical.last_entry = e
		line_no += 1
	# Physical ranges are derived from bracket lines, never from merged names.
	for hi in range(header_occurrences.size()):
		var occ = header_occurrences[hi]
		occ.end_line = header_occurrences[hi + 1].line - 1 if hi + 1 < header_occurrences.size() else lines.size()


static func _scan_comment(line: String, block_active: bool) -> Dictionary:
	var in_block := block_active
	var in_quote := false
	var comment_start := -1
	var i := 0
	var n := line.length()
	while i < n:
		if in_block:
			var close := line.find("*/", i)
			if close < 0:
				if comment_start < 0:
					comment_start = i
				return {"comment_start": comment_start, "block": true}
			in_block = false
			i = close + 2
			continue
		var c := line[i]
		if in_quote:
			if c == "\"":
				in_quote = false
			i += 1
			continue
		if c == "\"":
			in_quote = true
			i += 1
			continue
		if c == ";" or (c == "/" and i + 1 < n and line[i + 1] == "/"):
			if comment_start < 0:
				comment_start = i
			break
		if c == "/" and i + 1 < n and line[i + 1] == "*":
			if comment_start < 0:
				comment_start = i
			in_block = true
			i += 2
			continue
		i += 1
	return {"comment_start": comment_start, "block": in_block}


func effective_entries() -> Array:
	var out: Array = []
	for e in entries:
		if e.shadowed_by == null:
			out.append(e)
	return out


func find_entry(header_name: String, key: String):
	var hid := header_name.to_lower()
	var kid := key.to_lower()
	var found = null
	for e in entries:
		if e.header.to_lower() == hid and e.key_lc == kid:
			found = e
	return found


## Occurrence-aware entry lookup matching physical header occurrence and
## within-header declaration index (P1-02). Never returns a different physical
## header occurrence's value when `header_occ_index >= 0` is requested.
func find_entry_occurrence(header_name: String, key_with_suffix: String,
		header_occ_index: int = -1, header_key_occ_index: int = -1,
		doc_key_occ_index: int = -1):
	var hid := header_name.to_lower()
	var kid := key_with_suffix.to_lower()
	if header_occ_index >= 0:
		var last_in_header_occ = null
		for e in entries:
			if e.header.to_lower() == hid and e.occurrence_index == header_occ_index and e.key_lc == kid:
				if header_key_occ_index < 0 or e.header_key_occurrence_index == header_key_occ_index:
					return e
				last_in_header_occ = e
		if last_in_header_occ != null and header_key_occ_index >= 0:
			return null
		return null
	if doc_key_occ_index >= 0:
		for e in entries:
			if e.header.to_lower() == hid and e.key_lc == kid and e.key_occurrence_index == doc_key_occ_index:
				return e
		return null
	return find_entry(header_name, key_with_suffix)


## Match a specific physical entry occurrence from another revision of this ODF.
func find_matching_entry(target_entry):
	if target_entry == null:
		return null
	var full_k: String = target_entry.full_key()
	return find_entry_occurrence(
		target_entry.header,
		full_k,
		int(target_entry.occurrence_index),
		int(target_entry.header_key_occurrence_index),
		int(target_entry.key_occurrence_index)
	)


## Replace one physical header occurrence in-place with the exact lines from
## `factory_doc`'s corresponding occurrence (P1-03), removing any workspace-added
## custom properties in that header while preserving all other sections and comments.
func replace_header_occurrence_from_factory(factory_doc: OdfDocument, header_name: String,
		occurrence_index: int = -1) -> bool:
	if factory_doc == null or header_name.strip_edges() == "":
		return false
	var target_occ_idx := occurrence_index if occurrence_index >= 0 else maxi(0, header_occurrence_count(header_name) - 1)
	var occ = _find_occurrence(header_name, target_occ_idx)
	if occ == null:
		return false
	var f_occ_count := factory_doc.header_occurrence_count(header_name)
	if f_occ_count <= 0:
		return false
	var f_occ_idx := target_occ_idx if target_occ_idx < f_occ_count else (f_occ_count - 1)
	var f_occ = factory_doc._find_occurrence(header_name, f_occ_idx)
	if f_occ == null:
		return false

	var self_bounds := _section_line_bounds(occ)
	var fac_bounds := factory_doc._section_line_bounds(f_occ)
	var self_lines := text.split("\n")
	var fac_lines := factory_doc.text.split("\n")
	var nl := "\r\n" if text.contains("\r\n") else "\n"

	var rebuilt := PackedStringArray()
	for i in range(0, int(self_bounds.first)):
		rebuilt.append(self_lines[i].trim_suffix("\r"))
	for fi in range(int(fac_bounds.first), int(fac_bounds.last_content) + 1):
		if fi >= 0 and fi < fac_lines.size():
			rebuilt.append(fac_lines[fi].trim_suffix("\r"))
	# Preserve blank separator line if followed by another section.
	if int(self_bounds.last) + 1 < self_lines.size():
		rebuilt.append("")
	for i2 in range(int(self_bounds.last) + 1, self_lines.size()):
		rebuilt.append(self_lines[i2].trim_suffix("\r"))

	var new_text := nl.join(rebuilt)
	if new_text == text:
		return false
	_push_undo()
	text = new_text
	_parse()
	dirty = text != saved_text
	changed.emit()
	return true


func _section_line_bounds(h) -> Dictionary:
	var lines := text.split("\n")
	var first: int = h.line - 1
	var last: int = first
	if h.last_entry != null:
		last = maxi(last, h.last_entry.line - 1)
	var limit: int = lines.size() - 1
	if h.end_line > h.line:
		limit = mini(limit, h.end_line - 1)
	var j := last + 1
	while j <= limit:
		var probe := lines[j].strip_edges()
		if probe.begins_with(";") or probe.begins_with("//"):
			j += 1
			continue
		break
	if j > last + 1 and j <= limit and lines[j].strip_edges() == "":
		last = j - 1
	elif j == limit + 1 and j > last + 1:
		last = j - 1
	var last_content := last
	while last + 1 <= limit and lines[last + 1].strip_edges() == "":
		last += 1
	return {"first": first, "last_content": last_content, "last": last}


## Restore in-memory state from a freshly loaded factory OdfDocument without
## replacing the OdfDocument instance (preserving references held by views/labs).
func restore_factory_state_from(factory_doc: OdfDocument) -> void:
	if factory_doc == null:
		return
	text = factory_doc.text
	original_bytes = factory_doc.original_bytes.duplicate()
	saved_bytes = factory_doc.saved_bytes.duplicate()
	saved_text = factory_doc.saved_text
	encoding = factory_doc.encoding
	has_bom = factory_doc.has_bom
	source_hash = factory_doc.source_hash
	_parse()
	revision += 1
	dirty = false
	workspace_override = false
	workspace_conflict = false
	_undo.clear()
	_redo.clear()
	undo_state_changed.emit()
	changed.emit()


## Apply byte-exact recovered working bytes in-place (encoding/BOM-aware),
## keeping saved reference bytes separate from dirty unsaved working bytes.
## Byte-exact in-place snapshot restore with undo history preserved. Used when a
## compound mutation fails after it already changed the document: replaying undo
## cannot guarantee the original bytes when compound push state differs.
func restore_snapshot(snap: Dictionary) -> bool:
	if not bool(snap.get("ok", false)):
		return false
	text = str(snap.get("text", ""))
	encoding = str(snap.get("encoding", encoding))
	has_bom = bool(snap.get("has_bom", has_bom))
	saved_text = str(snap.get("saved_text", saved_text))
	saved_bytes = (snap.get("saved_bytes", PackedByteArray()) as PackedByteArray).duplicate()
	dirty = bool(snap.get("dirty", dirty))
	revision = int(snap.get("revision", revision)) + 1
	_compound_depth = 0
	_compound_pushed = false
	if snap.has("undo"):
		_undo = (snap["undo"] as Array).duplicate()
	if snap.has("redo"):
		_redo = (snap["redo"] as Array).duplicate()
	_parse()
	changed.emit()
	undo_state_changed.emit()
	return true


func capture_snapshot() -> Dictionary:
	return {
		"ok": true, "text": text, "encoding": encoding, "has_bom": has_bom,
		"saved_text": saved_text, "saved_bytes": saved_bytes.duplicate(),
		"dirty": dirty, "revision": revision,
		"undo": _undo.duplicate(), "redo": _redo.duplicate(),
	}


func apply_recovered_bytes(working_bytes: PackedByteArray, saved_ref_bytes: PackedByteArray = PackedByteArray(),
		is_dirty: bool = false, is_override: bool = false, ws_rel: String = "", ws_src_md5: String = "",
		forced_encoding: String = "", forced_has_bom: int = -1) -> bool:
	if working_bytes.is_empty() and saved_ref_bytes.is_empty():
		return false
	var active_bytes := working_bytes if not working_bytes.is_empty() else saved_ref_bytes
	var w_info := decode_bytes_info(active_bytes, forced_encoding, forced_has_bom)
	encoding = str(w_info.get("encoding", encoding))
	has_bom = bool(w_info.get("has_bom", has_bom))
	text = str(w_info.get("text", ""))
	if not saved_ref_bytes.is_empty():
		var s_info := decode_bytes_info(saved_ref_bytes, encoding, 1 if has_bom else 0)
		saved_bytes = saved_ref_bytes.duplicate()
		saved_text = str(s_info.get("text", ""))
	else:
		saved_bytes = active_bytes.duplicate()
		saved_text = text
	_parse()
	revision += 1
	dirty = is_dirty or (active_bytes != saved_bytes)
	workspace_override = is_override
	workspace_rel = ws_rel
	if ws_src_md5 != "":
		workspace_source_md5 = ws_src_md5
	_undo.clear()
	_redo.clear()
	undo_state_changed.emit()
	changed.emit()
	return true


func get_value(header_name: String, key: String, fallback: String = "") -> String:
	var e = find_entry(header_name, key)
	if e == null:
		return fallback
	return e.core_value()


func get_float(header_name: String, key: String, fallback: float = 0.0) -> float:
	var v := get_value(header_name, key, "")
	if v == "":
		return fallback
	var f := v.to_float()
	return f if is_finite(f) else fallback


func get_int(header_name: String, key: String, fallback: int = 0) -> int:
	var v := get_value(header_name, key, "")
	if v == "":
		return fallback
	if v.begins_with("0x") or v.begins_with("0X"):
		return v.hex_to_int()
	return v.to_int()


func get_bool(header_name: String, key: String, fallback: bool = false) -> bool:
	var v := get_value(header_name, key, "")
	if v == "":
		return fallback
	var first := v.substr(0, 1).to_lower()
	if first == "f" or first == "n" or first == "0":
		return false
	return true


## Header names in source order, including duplicates.
func header_names() -> Array[String]:
	var out: Array[String] = []
	for h in headers:
		out.append(h.name)
	return out


## Render headers are any header declaring renderBase or simulateBase.
func render_headers() -> Array:
	var out: Array = []
	for h in headers:
		var rb = find_entry(h.name, "renderBase")
		var sb = find_entry(h.name, "simulateBase")
		if rb != null or sb != null:
			out.append(h)
	return out


func is_render_odf() -> bool:
	return not render_headers().is_empty()


func begin_compound() -> void:
	if _compound_depth == 0:
		_compound_pushed = false
	_compound_depth += 1


func end_compound() -> void:
	if _compound_depth > 0:
		_compound_depth -= 1
	if _compound_depth == 0:
		_compound_pushed = false


func _push_undo() -> void:
	revision += 1
	if _compound_depth > 0:
		if _compound_pushed:
			return
		_compound_pushed = true
	_undo.append(text)
	if _undo.size() > _max_history:
		_undo.pop_front()
	_redo.clear()
	undo_state_changed.emit()


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo() -> void:
	if _undo.is_empty():
		return
	_redo.append(text)
	text = _undo.pop_back()
	_parse()
	revision += 1
	dirty = text != saved_text
	undo_state_changed.emit()
	changed.emit()


func redo() -> void:
	if _redo.is_empty():
		return
	_undo.append(text)
	text = _redo.pop_back()
	_parse()
	revision += 1
	dirty = text != saved_text
	undo_state_changed.emit()
	changed.emit()


## Replace the whole document text in place. Document identity stays stable, so
## live WeaponProfile/ParticleLab references see the new values immediately.
func replace_text(new_text: String) -> void:
	if new_text == text:
		return
	_push_undo()
	text = new_text
	_parse()
	dirty = true
	changed.emit()


## Replace only the value span of an entry. Returns the new raw text.
func set_entry_value(entry, new_raw: String) -> void:
	if entry == null:
		return
	if entry.value_raw == new_raw:
		return
	_push_undo()
	var old_len: int = entry.value_end - entry.value_start
	var abs_start: int = entry.value_start
	text = text.substr(0, abs_start) + new_raw + text.substr(entry.value_end)
	var delta: int = new_raw.length() - old_len
	for e in entries:
		if e == entry:
			continue
		if e.value_start >= entry.value_end:
			e.value_start += delta
			e.value_end += delta
	entry.value_raw = new_raw
	entry.value_end = abs_start + new_raw.length()
	dirty = true
	changed.emit()


## Append a property line at the end of the header's section (before the next
## header or EOF). Used by the node graph when a new child reference is added.
func append_entry(header_name: String, key: String, raw_value: String, header_id: String = ""):
	if fault_append_entry_fail_key != "" and key.strip_edges().to_lower() == fault_append_entry_fail_key.to_lower():
		return null
	var h = null
	for candidate in header_occurrences:
		if header_id != "" and candidate.id == header_id:
			h = candidate
			break
		if header_id == "" and candidate.name.to_lower() == header_name.to_lower():
			h = candidate
			if candidate.last_entry != null:
				break
	if h == null:
		# Create a new header at end of file.
		_push_undo()
		var sep := "" if text.ends_with("\n") or text.is_empty() else "\n"
		text += sep + "[" + header_name + "]\n" + key + " = " + raw_value
		_parse()
		dirty = true
		changed.emit()
		return find_entry(header_name, key)
	var insert_at := text.length()
	if h.last_entry != null:
		var line_end := text.find("\n", h.last_entry.value_end)
		insert_at = text.length() if line_end < 0 else line_end + 1
	else:
		# An empty header owns exactly its bracket line: insert before the next
		# section so the property cannot leak into an unrelated header.
		var header_start := _line_start_offset(h.line)
		var header_end := text.find("\n", header_start)
		insert_at = text.length() if header_end < 0 else header_end + 1
	_push_undo()
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	var block := key + " = " + raw_value + nl
	if insert_at >= text.length() and not text.ends_with("\n"):
		block = nl + block
	text = text.substr(0, insert_at) + block + text.substr(insert_at)
	_parse()
	dirty = true
	changed.emit()
	return find_entry(header_name, key)


## Remove a property's whole source line. Used by the particle graph when a
## reference edge is disconnected; comments and unrelated lines stay intact.
func remove_entry(entry) -> bool:
	if entry == null:
		return false
	var line_start := text.substr(0, entry.value_start).rfind("\n")
	line_start = 0 if line_start < 0 else line_start + 1
	var nl := text.find("\n", entry.value_end)
	var line_end := text.length() if nl < 0 else nl + 1
	_push_undo()
	text = text.substr(0, line_start) + text.substr(line_end)
	_parse()
	dirty = true
	changed.emit()
	return true


## Extract the raw property body lines of a header occurrence for lossless
## copy/paste within or across OdfDocuments.
func extract_header_body(source: String, occurrence_index: int = -1) -> String:
	var occ_idx := occurrence_index
	if occ_idx < 0:
		occ_idx = maxi(0, header_occurrence_count(source) - 1)
	var occ = _find_occurrence(source, occ_idx)
	if occ == null:
		return ""
	var lines := text.split("\n")
	var last_idx: int = occ.line - 1
	if occ.last_entry != null:
		last_idx = maxi(last_idx, occ.last_entry.line - 1)
	var block := ""
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	for idx in range(occ.line, last_idx + 1):
		if idx >= 0 and idx < lines.size():
			block += lines[idx].trim_suffix("\r") + nl
	return block


## Append a new [new_name] header with a pre-extracted raw body block at EOF.
func append_header_block(new_name: String, body_block: String) -> bool:
	var clean := new_name.strip_edges()
	if clean == "" or has_header(clean) or body_block == "":
		return false
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	var normalized := body_block.replace("\r\n", "\n").replace("\n", nl)
	if not normalized.ends_with(nl):
		normalized += nl
	_push_undo()
	var sep := "" if text.ends_with("\n") or text.is_empty() else nl
	text += sep + "[" + clean + "]" + nl + normalized
	_parse()
	dirty = true
	changed.emit()
	return true


## Copy every local property line of a header into a new header at EOF.
## Line text, comments and duplicate keys are preserved; inherited values are
## intentionally not flattened so the copy stays an editable ODF header.
func duplicate_header(source: String, new_name: String, occurrence_index: int = 0) -> bool:
	if source == "" or new_name == "" or has_header(new_name):
		return false
	var occ = _find_occurrence(source, occurrence_index)
	if occ == null:
		return false
	var lines := text.split("\n")
	var last_idx: int = occ.line - 1
	if occ.last_entry != null:
		last_idx = maxi(last_idx, occ.last_entry.line - 1)
	var block := ""
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	for idx in range(occ.line, last_idx + 1):
		if idx >= 0 and idx < lines.size():
			block += lines[idx].trim_suffix("\r") + nl
	if block == "":
		return false
	_push_undo()
	var sep := "" if text.ends_with("\n") or text.is_empty() else nl
	text += sep + "[" + new_name + "]" + nl + block
	_parse()
	dirty = true
	changed.emit()
	return true


## Rename a physical header name. Only the bracket span changes: properties,
## comments and blank lines stay in their original lines. occurrence_index < 0
## renames every occurrence of that name (the graph's merged identity).
func rename_header(old_name: String, new_name: String, occurrence_index: int = -1) -> bool:
	var new_clean := new_name.strip_edges()
	if old_name.strip_edges() == "" or new_clean == "":
		return false
	if new_clean.contains("[") or new_clean.contains("]") or new_clean.contains("="):
		return false
	if new_clean.to_lower() != old_name.to_lower() and has_header(new_clean):
		return false
	var targets: Array = []
	for occ in header_occurrences:
		if occ.name.to_lower() != old_name.to_lower():
			continue
		if occurrence_index >= 0 and occ.occurrence_index != occurrence_index:
			continue
		targets.append(occ)
	if targets.is_empty():
		return false
	var lines := text.split("\n")
	var changed_any := false
	for occ in targets:
		var idx: int = occ.line - 1
		if idx < 0 or idx >= lines.size():
			continue
		var line: String = lines[idx]
		if line.ends_with("\r"):
			line = line.trim_suffix("\r")
		var open := line.find("[")
		var close := line.find("]", open + 1)
		if open < 0 or close < 0:
			continue
		if line.substr(open + 1, close - open - 1).strip_edges().to_lower() != old_name.to_lower():
			continue
		lines[idx] = line.substr(0, open + 1) + new_clean + line.substr(close)
		changed_any = true
	if not changed_any:
		return false
	_push_undo()
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	var rebuilt := PackedStringArray()
	for line in lines:
		rebuilt.append(str(line).trim_suffix("\r"))
	text = nl.join(rebuilt)
	_parse()
	dirty = true
	changed.emit()
	return true


func _line_start_offset(line_1based: int) -> int:
	var line := 1
	var offset := 0
	while line < line_1based:
		var nl := text.find("\n", offset)
		if nl < 0:
			return text.length()
		offset = nl + 1
		line += 1
	return offset


func _find_occurrence(header_name: String, occurrence_index: int):
	var idx := 0
	for candidate in header_occurrences:
		if candidate.name.to_lower() != header_name.to_lower():
			continue
		if idx == occurrence_index:
			return candidate
		idx += 1
	return null


func header_occurrence_count(header_name: String) -> int:
	var n := 0
	for h in header_occurrences:
		if h.name.to_lower() == header_name.to_lower():
			n += 1
	return n


func header_id_for(header_name: String, occurrence_index: int = 0) -> String:
	var occ = _find_occurrence(header_name, occurrence_index)
	return occ.id if occ != null else ""


## Remove exactly one physical header occurrence. Adjacent sections, including
## another header with the same name, stay byte-identical.
func remove_header(header_name: String, occurrence_index: int = 0) -> bool:
	var h = _find_occurrence(header_name, occurrence_index)
	if h == null:
		return false
	var lines := text.split("\n")
	var first: int = h.line - 1
	var last: int = first
	if h.last_entry != null:
		last = maxi(last, h.last_entry.line - 1)
	# Never cross the next bracket line even if blank lines follow the section.
	var limit: int = lines.size() - 1
	if h.end_line > h.line:
		limit = mini(limit, h.end_line - 1)
	# Comment ownership rule: a comment block after the last property belongs to
	# this section only when a blank line separates it from the next header.
	# A comment immediately preceding the next bracket line belongs to that next
	# section instead, so it is never deleted with this one.
	var j := last + 1
	while j <= limit:
		var probe := lines[j].strip_edges()
		if probe.begins_with(";") or probe.begins_with("//"):
			j += 1
			continue
		break
	if j > last + 1 and j <= limit and lines[j].strip_edges() == "":
		last = j - 1
	while last + 1 <= limit and lines[last + 1].strip_edges() == "":
		last += 1
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	var rebuilt := PackedStringArray()
	for i in lines.size():
		if i < first or i > last:
			rebuilt.append(lines[i].trim_suffix("\r"))
	_push_undo()
	text = nl.join(rebuilt)
	_parse()
	dirty = true
	changed.emit()
	return true


func has_header(header_name: String) -> bool:
	for h in headers:
		if h.name.to_lower() == header_name.to_lower():
			return true
	return false


func header_entry_count(header_name: String, occurrence_index: int = -1) -> int:
	var n := 0
	for e in entries:
		if e.header.to_lower() != header_name.to_lower():
			continue
		if occurrence_index < 0 or e.occurrence_index == occurrence_index:
			n += 1
	return n


func set_header_value(header_name: String, key: String, raw_value: String) -> void:
	var e = find_entry(header_name, key)
	if e != null:
		set_entry_value(e, raw_value)


## Recoverable save with a sibling .bak and a durable transaction journal.
## Not advertised as crash-atomic: the journal lets the next start finish or
## restore the replacement instead of silently losing the only copy.
func save_to(path: String = "") -> Error:
	var target := path if path != "" else source_path
	if target == "":
		return ERR_INVALID_PARAMETER
	var bytes := to_bytes()
	var res := WorkspaceStore.transactional_write_abs(target, bytes, target + ".bak")
	if not bool(res.get("ok", false)):
		return ERR_FILE_CANT_WRITE
	source_path = target
	saved_text = text
	saved_bytes = bytes
	dirty = false
	revision += 1
	return OK


## Record the exact bytes that were just durably saved. Source bytes remain a
## separate snapshot; this is the working revision consumers must reuse.
func mark_saved(bytes: PackedByteArray) -> void:
	saved_text = text
	saved_bytes = bytes
	dirty = false


func to_bytes() -> PackedByteArray:
	# dirty is metadata, not proof that the bytes equal the source. After a
	# workspace save this returns the saved working revision; only an exact
	# text match may reuse the last materialized snapshot.
	if text == saved_text and not saved_bytes.is_empty():
		return saved_bytes
	var body: PackedByteArray
	if encoding == "utf-16le":
		body = text.to_utf16_buffer()
	elif encoding == "utf-16be":
		body = text.to_utf16_buffer()
		var swapped := body.duplicate()
		var i := 0
		while i + 1 < swapped.size():
			var t := swapped[i]
			swapped[i] = swapped[i + 1]
			swapped[i + 1] = t
			i += 2
		body = swapped
	else:
		body = text.to_utf8_buffer()
	if has_bom:
		var bom := PackedByteArray()
		if encoding == "utf-16le":
			bom = PackedByteArray([0xFF, 0xFE])
		elif encoding == "utf-16be":
			bom = PackedByteArray([0xFE, 0xFF])
		else:
			bom = PackedByteArray([0xEF, 0xBB, 0xBF])
		body = bom + body
	return body


func to_text() -> String:
	return text


static func core_value(raw: String) -> String:
	var v := raw.strip_edges()
	if v.length() >= 2 and v[0] == "\"" and v[v.length() - 1] == "\"":
		return v.substr(1, v.length() - 2)
	return v
