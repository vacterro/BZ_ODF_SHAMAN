class_name WorkspaceStore
extends RefCounted
## Durable, isolated workspace for edited ODFs.
##
## Layout:
##   <root>/project.json      source -> override map
##   <root>/odf/<rel>         saved override bytes
##   <root>/backups/<rel>.bak previous saved revision
##   <root>/sweeps/           parameter sweep CSV
##
## The root is configurable through BZ_SHAMAN_WORKSPACE_ROOT so smoke tests can
## never write into (or delete) the production workspace. Writes are recoverable
## transactions: verified temp -> durable journal -> backup -> replace ->
## verify -> commit. An interrupted process is reconciled on the next start.
## This is deliberately not called crash-atomic: the replace has a finite
## window, but the journal guarantees the next start can finish or restore it.

const SCHEMA := 1
const ENV_ROOT := "BZ_SHAMAN_WORKSPACE_ROOT"

const PROTECTED_ROOTS := [
	{"label": "GAME", "path": "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R"},
	{"label": "WORKSHOP", "path": "V:/__STORE_V/_SOFT/Steam/steamapps/workshop/content/624970"},
	{"label": "VRV", "path": "V:/___VAC/__K/__CODE/_MISC/_BZDECOMP/vrv"},
	{"label": "WINTAGE", "path": "V:/___VAC/__K/__CODE/_TAMPERMONKEY/_WIN95THEME/Wintage"},
	{"label": "ENGINE_KNOWLEDGE", "path": "V:/___VAC/_BATTLEZONE"},
]

## Explicit transaction outcomes. Restored file bytes are not the same thing as
## a consistent project: a recovered replacement whose manifest entry could not
## be committed stays RECOVERY_PENDING until a later attempt succeeds.
const TX_COMMITTED := "COMMITTED"
const TX_ROLLED_BACK := "ROLLED_BACK"
const TX_RECOVERY_PENDING := "RECOVERY_PENDING"
const TX_UNRECOVERABLE := "UNRECOVERABLE"

## Test-only override; production resolution must go through root().
static var root_override := ""

## Test-only phase fault injection. Setting a phase simulates a process death at
## that point: the function returns an interrupted result and leaves the temp,
## backup and journal evidence exactly as a killed process would. Production
## code never sets these keys.
static var fault_phases: Dictionary = {}
## Result of the last recover_transactions() call, per outcome class.
static var last_recovery: Dictionary = {}
## Explicit staging roots registered during this process for staged_export journals.
static var registered_stage_roots: Array[String] = []
## Explicitly registered owned base directories for native staging.
static var registered_owned_stage_bases: Array[String] = []
## Optional test-only callback invoked when a phase is reached (for worker termination tests).
static var fault_callback: Callable = Callable()


static func _fault(phase: String) -> bool:
	if fault_callback.is_valid():
		fault_callback.call(phase)
	return bool(fault_phases.get(phase, false))


static func default_owned_stage_bases() -> Array[String]:
	return [
		canonical("user://native_tests"),
		canonical(root().path_join("native_staging")),
	]


static func owned_stage_bases() -> Array[String]:
	var out: Array[String] = []
	for b in default_owned_stage_bases():
		if b != "" and not out.has(b):
			out.append(b)
	for b in registered_owned_stage_bases:
		if b != "" and not out.has(b):
			out.append(b)
	return out


static func protected_roots(extra_protected: Array[String] = []) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for item in PROTECTED_ROOTS:
		list.append({"label": str(item.label), "path": canonical(str(item.path))})
	var res_root := canonical("res://")
	if res_root != "":
		list.append({"label": "PROJECT_SOURCE", "path": res_root})
	for p in extra_protected:
		var c := canonical(p)
		if c != "":
			list.append({"label": "DISCOVERED_SOURCE", "path": c})
	return list


static func check_protected_root(candidate: String, extra_protected: Array[String] = []) -> Dictionary:
	var canon := canonical(candidate)
	if canon == "":
		return {"protected": true, "label": "EMPTY", "error": "empty path"}
	var win := OS.get_name() == "Windows"
	var cmp := canon.to_lower() if win else canon
	for entry in protected_roots(extra_protected):
		var r := str(entry.get("path", ""))
		if r == "":
			continue
		var rcmp := r.to_lower() if win else r
		if cmp == rcmp or is_within(r, canon) or is_within(canon, r):
			return {
				"protected": true,
				"label": str(entry.get("label", "PROTECTED")),
				"error": "refusing protected root (%s): %s" % [str(entry.get("label", "PROTECTED")), canon],
			}
	return {"protected": false, "label": "", "error": ""}


static func register_stage_root(stage_root: String) -> bool:
	var canon := canonical(stage_root)
	if canon == "":
		return false
	var prot := check_protected_root(canon)
	if bool(prot.get("protected", false)):
		return false
	if not registered_stage_roots.has(canon):
		registered_stage_roots.append(canon)
	return true


static func _is_hex_md5(s: String) -> bool:
	if s.length() != 32:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		var is_digit := c >= 48 and c <= 57
		var is_lower_hex := c >= 97 and c <= 102
		var is_upper_hex := c >= 65 and c <= 70
		if not (is_digit or is_lower_hex or is_upper_hex):
			return false
	return true


static func root() -> String:
	var r := root_override
	if r == "":
		r = OS.get_environment(ENV_ROOT)
	if r == "":
		r = "user://workspace"
	return r.trim_suffix("/")


static func odf_dir() -> String:
	return root().path_join("odf")


static func backups_dir() -> String:
	return root().path_join("backups")


static func sweeps_dir() -> String:
	return root().path_join("sweeps")


static func transactions_dir() -> String:
	return root().path_join("transactions")


static func reset_transactions_dir() -> String:
	return root().path_join("reset_transactions")


static func project_file() -> String:
	return root().path_join("project.json")


## Reject absolute paths, drive letters and traversal. Returns "" when unsafe.
static func clean_rel(rel: String) -> String:
	var r := rel.replace("\\", "/").strip_edges()
	if r == "" or r.begins_with("/") or r.contains(":"):
		return ""
	# A NUL byte cannot appear in a real path. Scan code points instead of a
	# "\u0000" literal: the literal makes the GDScript compiler emit a Unicode
	# NUL warning on every project load.
	for i in r.length():
		if r.unicode_at(i) == 0:
			return ""
	var parts := r.split("/", false)
	if parts.is_empty():
		return ""
	var safe: Array[String] = []
	for p in parts:
		if p == "" or p == "." or p == "..":
			return ""
		safe.append(p)
	return "/".join(PackedStringArray(safe))


static func canonical(path: String) -> String:
	var p := ProjectSettings.globalize_path(path).replace("\\", "/").simplify_path()
	while p.contains("//"):
		p = p.replace("//", "/")
	if p.ends_with("/") and p.length() > 1:
		p = p.trim_suffix("/")
	return p


## True only for a strict descendant, never the root itself. Case-insensitive
## on Windows, which is the target platform for BZCC paths.
static func is_within(root_path: String, candidate: String) -> bool:
	var r := canonical(root_path)
	var c := canonical(candidate)
	if OS.get_name() == "Windows":
		r = r.to_lower()
		c = c.to_lower()
	if c == r:
		return false
	return c.begins_with(r + "/")


static func parse_json_safe(text: String) -> Dictionary:
	if text.strip_edges() == "":
		return {"ok": false, "data": null, "error": "empty JSON text", "line": 0}
	var j := JSON.new()
	var err := j.parse(text)
	if err != OK:
		return {
			"ok": false,
			"data": null,
			"error": j.get_error_message(),
			"line": j.get_error_line(),
		}
	return {"ok": true, "data": j.data, "error": "", "line": 0}


static func _manifest() -> Dictionary:
	if not FileAccess.file_exists(project_file()):
		return {"schema": SCHEMA, "entries": []}
	var jres := parse_json_safe(FileAccess.get_file_as_string(project_file()))
	var parsed = jres.get("data", null) if bool(jres.get("ok", false)) else null
	if not (parsed is Dictionary):
		_quarantine_manifest()
		return {"schema": SCHEMA, "entries": []}
	var entries = parsed.get("entries", [])
	if not (entries is Array):
		_quarantine_manifest()
		return {"schema": SCHEMA, "entries": []}
	return {"schema": SCHEMA, "entries": entries}


static func _quarantine_manifest() -> void:
	var path := project_file()
	if FileAccess.file_exists(path):
		var stamp := Time.get_datetime_string_from_system().replace(":", "-")
		DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(path + ".corrupt-" + stamp))


static func _write_manifest(entries: Array) -> bool:
	if _fault("manifest_write"):
		return false
	var dir := project_file().get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var body := JSON.stringify({"schema": SCHEMA, "updated": Time.get_datetime_string_from_system(), "entries": entries}, "  ")
	var res := atomic_write_abs(project_file(), body.to_utf8_buffer())
	return bool(res.ok)


static func entries() -> Array:
	return _manifest().entries


static func entry_for(source: String) -> Dictionary:
	for e in entries():
		var esrc := str(e.get("source", ""))
		if esrc == source or _same_canon_path(esrc, source):
			return e
	return {}


static func source_md5(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_md5(path)


static func record(source: String, rel: String, source_hash: String, size: int) -> bool:
	var safe := clean_rel(rel)
	if safe == "" or source == "":
		return false
	var list: Array = entries()
	var replaced := false
	for e in list:
		if str(e.get("source", "")) == source:
			e["rel"] = safe
			e["saved_at"] = Time.get_datetime_string_from_system()
			e["source_md5"] = source_hash
			e["bytes"] = size
			replaced = true
			break
	if not replaced:
		list.append({
			"source": source,
			"rel": safe,
			"saved_at": Time.get_datetime_string_from_system(),
			"source_md5": source_hash,
			"bytes": size,
		})
	return _write_manifest(list)


## Save with an explicitly chosen project-relative path (first save).
static func save_document_with_rel(doc, rel: String) -> Dictionary:
	if doc == null:
		return {"ok": false, "target": "", "error": "no document"}
	var safe := clean_rel(rel)
	if safe == "":
		return {"ok": false, "target": "", "error": "unsafe relative path: " + rel}
	if str(doc.workspace_rel) == "":
		for e in entries():
			if str(e.get("rel", "")) == safe and str(e.get("source", "")) != doc.source_path:
				safe = "sources/%s/%s" % [doc.source_path.md5_text().substr(0, 12), safe]
				break
	doc.workspace_rel = safe
	return save_document(doc)


## Save a document atomically and register it in the project manifest.
## Returns {ok, target, error, backup}.
## Finish or roll back every interrupted replacement under this workspace.
## Callable on startup and in tests after simulated crashes.
static func recover_transactions() -> int:
	last_recovery = {
		"committed": 0, "rolled_back": 0, "pending": 0, "unrecoverable": 0,
		"journals_kept": 0, "reasons": [],
	}
	var dir_path := transactions_dir()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
		return 0
	var dir := DirAccess.open(ProjectSettings.globalize_path(dir_path))
	if dir == null:
		return 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".json"):
			var journal_path := ProjectSettings.globalize_path(dir_path.path_join(name))
			var jres := parse_json_safe(FileAccess.get_file_as_string(journal_path))
			var parsed = jres.get("data", null) if bool(jres.get("ok", false)) else null
			if parsed is Dictionary:
				var check := _validate_journal(parsed, name)
				if not bool(check.get("ok", false)):
					last_recovery.unrecoverable += 1
					last_recovery.journals_kept += 1
					(last_recovery.reasons as Array).append({
						"journal": name,
						"status": TX_UNRECOVERABLE,
						"reason": str(check.get("reason", "INVALID_TRANSACTION_PATH")),
						"error": str(check.get("error", "")),
					})
				else:
					var outcome: String = _recover_one(parsed)
					if outcome == TX_COMMITTED or outcome == TX_ROLLED_BACK:
						DirAccess.remove_absolute(journal_path)
						last_recovery["committed" if outcome == TX_COMMITTED else "rolled_back"] += 1
					elif outcome == TX_RECOVERY_PENDING:
						# Keep the journal: it is the only durable record that the
						# manifest still needs reconciliation.
						last_recovery.pending += 1
						last_recovery.journals_kept += 1
					else:
						last_recovery.unrecoverable += 1
						last_recovery.journals_kept += 1
			else:
				last_recovery.unrecoverable += 1
				last_recovery.journals_kept += 1
				(last_recovery.reasons as Array).append({
					"journal": name,
					"status": TX_UNRECOVERABLE,
					"reason": "INVALID_TRANSACTION_JSON",
					"error": "corrupt journal JSON",
				})
		name = dir.get_next()
	dir.list_dir_end()
	return int(last_recovery.committed)


static func _same_canon_path(a: String, b: String) -> bool:
	var ca := canonical(a)
	var cb := canonical(b)
	if OS.get_name() == "Windows":
		return ca.to_lower() == cb.to_lower()
	return ca == cb


static func _valid_temp_sibling(temp: String, target: String) -> bool:
	if temp == "":
		return true
	var ctemp := canonical(temp)
	var ctarg := canonical(target)
	if not _same_canon_path(ctemp.get_base_dir(), ctarg.get_base_dir()):
		return false
	var tname := ctemp.get_file()
	var gname := ctarg.get_file()
	if OS.get_name() == "Windows":
		return tname.to_lower().begins_with(gname.to_lower() + ".tmp-")
	return tname.begins_with(gname + ".tmp-")


static func _infer_journal_op(journal: Dictionary, target: String) -> String:
	var op := str(journal.get("op", ""))
	if op != "":
		return op
	if str(journal.get("source", "")) != "" and str(journal.get("rel", "")) != "":
		return "workspace_odf"
	if is_within(root(), target):
		return "workspace_file"
	return "unknown"


static func _validate_journal(journal: Dictionary, journal_filename: String) -> Dictionary:
	var version := int(journal.get("version", 0))
	if version != 1:
		return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "unsupported journal version"}
	var target := str(journal.get("target", ""))
	var temp := str(journal.get("temp", ""))
	var backup := str(journal.get("backup", ""))
	var md5 := str(journal.get("md5", ""))
	var size := int(journal.get("size", -1))
	if target == "" or not _is_hex_md5(md5) or size < 0:
		return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "invalid target/md5/size"}
	var canon_target := canonical(target)
	if canon_target == "" or canon_target.contains(".."):
		return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "invalid canonical target"}

	# Never allow recovery to touch any protected source root.
	for candidate in [canon_target, temp, backup]:
		if candidate == "":
			continue
		var prot := check_protected_root(candidate)
		if bool(prot.get("protected", false)):
			return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": str(prot.get("error", "protected root"))}

	# Journal filename must match canonical target identity (or raw target identity).
	var expected_j1 := canon_target.md5_text() + ".json"
	var expected_j2 := target.md5_text() + ".json"
	var expected_j3 := (canon_target.to_lower() if OS.get_name() == "Windows" else canon_target).md5_text() + ".json"
	if journal_filename != "" and journal_filename != expected_j1 and journal_filename != expected_j2 and journal_filename != expected_j3:
		return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "journal filename/target identity mismatch"}

	if not _valid_temp_sibling(temp, canon_target):
		return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "invalid temp sibling path"}

	var op := _infer_journal_op(journal, canon_target)
	match op:
		"workspace_odf":
			var rel := str(journal.get("rel", ""))
			var safe := clean_rel(rel)
			if safe == "" or safe != rel.replace("\\", "/"):
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "invalid relative ODF path"}
			var expected_target := canonical(odf_dir().path_join(safe))
			if not is_within(odf_dir(), canon_target) or not _same_canon_path(canon_target, expected_target):
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "target outside workspace odf/ or rel mismatch"}
			if backup != "":
				var expected_bak := canonical(backups_dir().path_join(safe) + ".bak")
				if not is_within(backups_dir(), backup) or not _same_canon_path(backup, expected_bak):
					return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "invalid backup path for workspace_odf"}
			var source := str(journal.get("source", ""))
			if source == "" or is_within(odf_dir(), source) or is_within(backups_dir(), source) or is_within(transactions_dir(), source):
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "invalid source mapping"}
			for e in entries():
				if str(e.get("rel", "")) == safe and str(e.get("source", "")) != source:
					return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "manifest source mapping collision for rel: " + safe}
		"workspace_file":
			if not is_within(root(), canon_target):
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "workspace_file target outside workspace root"}
			if is_within(transactions_dir(), canon_target) or is_within(backups_dir(), canon_target):
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "workspace_file target inside reserved dir"}
			if backup != "" and not is_within(backups_dir(), backup):
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "workspace_file backup outside backups/"}
		"staged_export":
			var srel := str(journal.get("rel", ""))
			var ssafe := clean_rel(srel)
			if ssafe == "" or ssafe != srel.replace("\\", "/"):
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "invalid staged relative path"}
			var stage_ok := false
			for sroot in registered_stage_roots:
				if is_within(sroot, canon_target) and _same_canon_path(canon_target, sroot.path_join(ssafe)):
					stage_ok = true
					break
			if not stage_ok:
				for obase in owned_stage_bases():
					if is_within(obase, canon_target):
						stage_ok = true
						break
			if not stage_ok:
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "staged_export target outside registered staging roots"}
			if backup != "":
				return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "staged_export must not specify external backup"}
		_:
			return {"ok": false, "reason": "INVALID_TRANSACTION_PATH", "error": "unrecognized transaction op: " + op}

	return {"ok": true, "op": op, "target": canon_target}


static func _recover_one(journal: Dictionary) -> String:
	var target := canonical(str(journal.get("target", "")))
	var temp := canonical(str(journal.get("temp", ""))) if str(journal.get("temp", "")) != "" else ""
	var backup := canonical(str(journal.get("backup", ""))) if str(journal.get("backup", "")) != "" else ""
	var md5 := str(journal.get("md5", ""))
	var size := int(journal.get("size", -1))
	if target == "" or not _is_hex_md5(md5) or size < 0:
		return TX_UNRECOVERABLE
	var target_ok := FileAccess.file_exists(target) and _matches(FileAccess.get_file_as_bytes(target), md5, size)
	if not target_ok and temp != "" and FileAccess.file_exists(temp):
		var candidate := FileAccess.get_file_as_bytes(temp)
		if _matches(candidate, md5, size):
			if FileAccess.file_exists(target):
				DirAccess.remove_absolute(target)
			if DirAccess.rename_absolute(temp, target) == OK:
				target_ok = _matches(FileAccess.get_file_as_bytes(target), md5, size)
	if not target_ok and backup != "" and FileAccess.file_exists(backup):
		var previous := FileAccess.get_file_as_bytes(backup)
		if _write_verified(target, previous):
			if temp != "" and FileAccess.file_exists(temp):
				DirAccess.remove_absolute(temp)
			return TX_ROLLED_BACK
	if not target_ok:
		# Unrecoverable: keep the journal for inspection instead of deleting evidence.
		return TX_UNRECOVERABLE
	# The replacement is valid; reconcile the manifest if this was an ODF save.
	# Reconciliation is part of the transaction: without a verified manifest
	# commit the outcome is pending, never a silent success.
	if str(journal.get("source", "")) != "" and str(journal.get("rel", "")) != "":
		var source := str(journal.get("source", ""))
		var rel := str(journal.get("rel", ""))
		var entries_list: Array = entries()
		var found := false
		for e in entries_list:
			if str(e.get("source", "")) == source:
				e["rel"] = rel
				e["source_md5"] = str(journal.get("source_md5", ""))
				e["bytes"] = size
				e["saved_at"] = Time.get_datetime_string_from_system()
				found = true
				break
		if not found:
			entries_list.append({
				"source": source,
				"rel": rel,
				"saved_at": Time.get_datetime_string_from_system(),
				"source_md5": str(journal.get("source_md5", "")),
				"bytes": size,
			})
		if not _write_manifest(entries_list):
			return TX_RECOVERY_PENDING
		var confirmed := entry_for(source)
		if str(confirmed.get("rel", "")) != rel:
			return TX_RECOVERY_PENDING
	if temp != "" and FileAccess.file_exists(temp):
		DirAccess.remove_absolute(temp)
	return TX_COMMITTED


static func _md5_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func _matches(bytes: PackedByteArray, md5: String, size: int) -> bool:
	if size >= 0 and bytes.size() != size:
		return false
	return _md5_bytes(bytes) == md5


static func save_document(doc) -> Dictionary:
	if doc == null or doc.source_path == "":
		return {"ok": false, "target": "", "error": "no document"}
	var rel := str(doc.workspace_rel)
	var first_save := rel == ""
	if rel == "":
		rel = doc.source_path.get_file()
	var safe := clean_rel(rel)
	if safe == "":
		return {"ok": false, "target": "", "error": "unsafe relative path: " + rel}
	# Same relative path from different packages must never collide in the
	# workspace. Disambiguate by source path hash on the first save.
	if first_save:
		for e in entries():
			if str(e.get("rel", "")) == safe and str(e.get("source", "")) != doc.source_path:
				safe = "sources/%s/%s" % [doc.source_path.md5_text().substr(0, 12), safe]
				break
	var target := odf_dir().path_join(safe)
	if not is_within(odf_dir(), target):
		return {"ok": false, "target": "", "error": "target escapes workspace"}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
	var backup := backups_dir().path_join(safe) + ".bak"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(backup.get_base_dir()))
	var bytes: PackedByteArray = doc.to_bytes()
	var source_hash := source_md5(doc.source_path)
	var meta := {
		"op": "workspace_odf",
		"source": doc.source_path,
		"rel": safe,
		"source_md5": source_hash,
		"bytes": bytes.size(),
	}
	var res := transactional_write_abs(target, bytes, backup, meta, true)
	if not bool(res.get("ok", false)):
		return {
			"ok": false,
			"status": str(res.get("status", "")),
			"target": target,
			"journal": str(res.get("journal", "")),
			"error": str(res.get("error", "write failed")),
			"backup": backup,
		}
	var orig_journal := str(res.get("journal", ""))
	# The manifest is part of the save contract: if it cannot be updated, put
	# the previous override back rather than exposing a half-committed save.
	var recorded := record(doc.source_path, safe, source_hash, bytes.size())
	if recorded:
		# A write that did not land in the manifest is not a committed save.
		recorded = str(entry_for(doc.source_path).get("rel", "")) == safe
	if not recorded:
		var abs_target := canonical(target)
		var abs_backup := canonical(backup)
		var had_previous := FileAccess.file_exists(abs_backup)
		var rollback_proven := false
		if had_previous:
			var prev_bytes := FileAccess.get_file_as_bytes(abs_backup)
			var prev_md5 := _md5_bytes(prev_bytes)
			var prev_size := prev_bytes.size()
			if not _fault("rollback_write"):
				if _fault("rollback_after_remove"):
					if FileAccess.file_exists(abs_target):
						DirAccess.remove_absolute(abs_target)
				else:
					_write_verified(abs_target, prev_bytes)
			rollback_proven = FileAccess.file_exists(abs_target) and _matches(FileAccess.get_file_as_bytes(abs_target), prev_md5, prev_size)
		else:
			if not _fault("rollback_write") and not _fault("rollback_after_remove"):
				if FileAccess.file_exists(abs_target):
					DirAccess.remove_absolute(abs_target)
			rollback_proven = not FileAccess.file_exists(abs_target)
		if rollback_proven:
			commit_transaction(orig_journal)
			return {
				"ok": false,
				"status": TX_ROLLED_BACK,
				"target": target,
				"error": "manifest update failed; previous override restored",
				"backup": backup,
			}
		# Rollback could not be proven: keep the original journal + backup intact
		# so the next recovery pass can reconcile or restore safely.
		var target_has_new := FileAccess.file_exists(abs_target) and _matches(FileAccess.get_file_as_bytes(abs_target), _md5_bytes(bytes), bytes.size())
		var pending_status := TX_RECOVERY_PENDING if (target_has_new or had_previous) else TX_UNRECOVERABLE
		return {
			"ok": false,
			"status": pending_status,
			"target": target,
			"journal": orig_journal,
			"error": "manifest update failed and rollback failed; recovery pending (journal kept)",
			"backup": backup,
		}
	commit_transaction(orig_journal)
	doc.mark_saved(bytes)
	doc.workspace_override = true
	doc.workspace_rel = safe
	doc.workspace_conflict = false
	doc.workspace_source_md5 = source_hash
	return {"ok": true, "status": TX_COMMITTED, "target": target, "error": "", "backup": backup}


## Remove a saved override and its manifest entry, leaving the original game
## resource untouched. Deletion is a logical transaction: the manifest removal
## is committed first and the override bytes are preserved in backups/ until
## the operation completes, so a failed manifest write cannot orphan the last
## saved revision.
## Returns {ok, status, error, source_missing, source_changed, backup}.
static func discard_override_ex(source: String) -> Dictionary:
	var list: Array = entries()
	var kept: Array = []
	var removed_rel := ""
	var saved_md5 := ""
	for e in list:
		var esrc := str(e.get("source", ""))
		if esrc == source or _same_canon_path(esrc, source):
			removed_rel = clean_rel(str(e.get("rel", "")))
			saved_md5 = str(e.get("source_md5", ""))
		else:
			kept.append(e)
	if removed_rel == "":
		return {"ok": false, "status": "NOT_FOUND", "error": "no saved override for this source"}
	var target := odf_dir().path_join(removed_rel)
	if not is_within(odf_dir(), target):
		return {"ok": false, "status": "UNSAFE_PATH", "error": "override path escapes the workspace"}
	var current_exists := FileAccess.file_exists(target)
	var backup := backups_dir().path_join(removed_rel) + ".bak"
	if current_exists:
		if _fault("backup_write"):
			return {"ok": false, "status": "BACKUP_FAILED", "error": "could not preserve the current override revision (fault injected)"}
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(backup.get_base_dir()))
		if not _write_verified(backup, FileAccess.get_file_as_bytes(target)):
			return {"ok": false, "status": "BACKUP_FAILED", "error": "could not preserve the current override revision"}
	if not _write_manifest(kept):
		return {"ok": false, "status": TX_RECOVERY_PENDING, "error": "manifest update failed; override preserved", "backup": backup}
	# Verify the manifest really dropped the entry before touching the bytes.
	if str(entry_for(source).get("rel", "")) != "":
		_write_manifest(list)
		return {"ok": false, "status": "MANIFEST_UNCHANGED", "error": "manifest still references the override; nothing deleted"}
	if current_exists:
		var rm := DirAccess.remove_absolute(ProjectSettings.globalize_path(target))
		if rm != OK:
			# Roll the manifest back so the file and the record agree again.
			_write_manifest(list)
			return {"ok": false, "status": "RESTORE_FAILED", "error": "could not retire the override; manifest rolled back", "backup": backup}
	var current_hash := source_md5(source)
	OdfDocument.invalidate_cache(source)
	return {
		"ok": true,
		"status": TX_COMMITTED,
		"error": "",
		"backup": backup,
		"source_missing": current_hash == "",
		"source_changed": current_hash != "" and saved_md5 != "" and current_hash != saved_md5,
	}


## Backwards-compatible boolean wrapper; callers that need the reason should
## use discard_override_ex().
static func discard_override(source: String) -> bool:
	return bool(discard_override_ex(source).get("ok", false))


static func read_manifest() -> Dictionary:
	return _manifest()


## Create a durable recovery point before destructive multi-file or single-file
## reset operations (P0-01 / RST-14). Preserves working bytes, saved workspace
## override bytes, and manifest records; fails closed if any backup write fails.
static func create_reset_recovery_point(target_sources: Array, scope_label: String = "RESET_ALL") -> Dictionary:
	if _fault("reset_backup") or _fault("backup_write"):
		return {
			"ok": false,
			"status": "BACKUP_FAILED",
			"outcome": "RESET_FAILED_RECOVERABLE",
			"transaction_id": "",
			"path": "",
			"error": "recovery point creation failed (backup write fault)",
		}
	var tx_id := "rst_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	var rdir := ProjectSettings.globalize_path(reset_transactions_dir())
	var mk := DirAccess.make_dir_recursive_absolute(rdir)
	if mk != OK and not DirAccess.dir_exists_absolute(rdir):
		return {
			"ok": false,
			"status": "BACKUP_FAILED",
			"outcome": "RESET_FAILED_RECOVERABLE",
			"transaction_id": tx_id,
			"path": "",
			"error": "cannot create reset recovery directory: " + rdir,
		}
	var seen := {}
	var records := {}
	var manifest_snapshot: Array = entries().duplicate(true)
	for raw_src in target_sources:
		var sp := str(raw_src)
		if sp == "":
			continue
		var ckey := canonical(sp)
		if OS.get_name() == "Windows":
			ckey = ckey.to_lower()
		if seen.has(ckey):
			continue
		seen[ckey] = true
		var ws_entry := entry_for(sp)
		var had_override := not ws_entry.is_empty()
		var ws_rel := clean_rel(str(ws_entry.get("rel", ""))) if had_override else ""
		var saved_override_bytes := PackedByteArray()
		var backup_file := ""
		if had_override and ws_rel != "":
			var ws_abs := ProjectSettings.globalize_path(odf_dir().path_join(ws_rel))
			if FileAccess.file_exists(ws_abs):
				saved_override_bytes = FileAccess.get_file_as_bytes(ws_abs)
				backup_file = ProjectSettings.globalize_path(backups_dir().path_join(ws_rel) + ".reset.bak")
				DirAccess.make_dir_recursive_absolute(backup_file.get_base_dir())
				if not _write_verified(backup_file, saved_override_bytes):
					return {
						"ok": false,
						"status": "BACKUP_FAILED",
						"outcome": "RESET_FAILED_RECOVERABLE",
						"transaction_id": tx_id,
						"path": "",
						"error": "failed to verify override backup for " + sp.get_file(),
					}
		var working_bytes := PackedByteArray()
		var was_dirty := false
		var cdoc = OdfDocument.cached(sp)
		if cdoc == null:
			for k in OdfDocument._cache:
				if _same_canon_path(str(k), sp):
					cdoc = OdfDocument._cache[k]
					break
		if cdoc is OdfDocument:
			working_bytes = cdoc.to_bytes()
			was_dirty = bool(cdoc.dirty)
			if was_dirty:
				var wrel := ws_rel if ws_rel != "" else clean_rel("working/%s_%s" % [ckey.md5_text().substr(0, 8), sp.get_file()])
				if wrel != "":
					var wbak := ProjectSettings.globalize_path(backups_dir().path_join(wrel) + ".working.bak")
					DirAccess.make_dir_recursive_absolute(wbak.get_base_dir())
					if not _write_verified(wbak, working_bytes):
						return {
							"ok": false,
							"status": "BACKUP_FAILED",
							"outcome": "RESET_FAILED_RECOVERABLE",
							"transaction_id": tx_id,
							"path": "",
							"error": "failed to verify working-bytes backup for " + sp.get_file(),
						}
					if backup_file == "":
						backup_file = wbak
		records[sp] = {
			"source": sp,
			"canonical_source": canonical(sp),
			"had_override": had_override,
			"workspace_rel": ws_rel,
			"manifest_entry": ws_entry.duplicate(true),
			"saved_override_md5": _md5_bytes(saved_override_bytes) if not saved_override_bytes.is_empty() else "",
			"saved_override_base64": Marshalls.raw_to_base64(saved_override_bytes) if not saved_override_bytes.is_empty() else "",
			"was_dirty": was_dirty,
			"working_md5": _md5_bytes(working_bytes) if not working_bytes.is_empty() else "",
			"working_base64": Marshalls.raw_to_base64(working_bytes) if not working_bytes.is_empty() else "",
			"backup_path": backup_file,
		}
	var payload := {
		"schema": 1,
		"transaction_id": tx_id,
		"scope": scope_label,
		"created_at": Time.get_datetime_string_from_system(),
		"status": "PREPARED",
		"manifest_snapshot": manifest_snapshot,
		"records": records,
	}
	var tx_path := rdir.path_join(tx_id + ".json")
	var wres := atomic_write_abs(tx_path, JSON.stringify(payload, "  ").to_utf8_buffer())
	if not bool(wres.get("ok", false)):
		return {
			"ok": false,
			"status": "BACKUP_FAILED",
			"outcome": "RESET_FAILED_RECOVERABLE",
			"transaction_id": tx_id,
			"path": tx_path,
			"error": "could not write reset recovery transaction: " + str(wres.get("error", "")),
		}
	return {
		"ok": true,
		"status": "RECOVERY_POINT_READY",
		"transaction_id": tx_id,
		"path": tx_path,
		"record_count": records.size(),
		"records": records,
	}


## Update a reset recovery transaction's final status (never deletes recovery bytes on failure).
static func finalize_reset_recovery_point(tx_path: String, final_status: String, summary: Dictionary = {}) -> bool:
	if tx_path == "" or not FileAccess.file_exists(tx_path):
		return false
	var jres := parse_json_safe(FileAccess.get_file_as_string(tx_path))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return false
	var payload: Dictionary = jres.get("data", {})
	payload["status"] = final_status
	payload["finished_at"] = Time.get_datetime_string_from_system()
	payload["summary"] = summary.duplicate(true)
	var wres := atomic_write_abs(tx_path, JSON.stringify(payload, "  ").to_utf8_buffer())
	return bool(wres.get("ok", false))


## Restore saved overrides and/or working edits from a reset recovery transaction.
static func restore_reset_recovery_point(tx_path: String) -> Dictionary:
	if tx_path == "" or not FileAccess.file_exists(tx_path):
		return {"ok": false, "status": "NOT_FOUND", "error": "recovery point not found"}
	var jres := parse_json_safe(FileAccess.get_file_as_string(tx_path))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {"ok": false, "status": "CORRUPT_RECOVERY_POINT", "error": str(jres.get("error", "invalid JSON"))}
	var payload: Dictionary = jres.get("data", {})
	var recs = payload.get("records", {})
	if not (recs is Dictionary):
		return {"ok": false, "status": "CORRUPT_RECOVERY_POINT", "error": "missing records"}
	var restored: Array[String] = []
	var failed: Array[Dictionary] = []
	for sp in recs:
		var r: Dictionary = recs[sp]
		var had_ov := bool(r.get("had_override", false))
		var ws_rel := clean_rel(str(r.get("workspace_rel", "")))
		var ov_b64 := str(r.get("saved_override_base64", ""))
		var work_b64 := str(r.get("working_base64", ""))
		if had_ov and ws_rel != "" and ov_b64 != "":
			var ov_bytes := Marshalls.base64_to_raw(ov_b64)
			var exp_md5 := str(r.get("saved_override_md5", ""))
			if exp_md5 != "" and _md5_bytes(ov_bytes) != exp_md5:
				failed.append({"source": str(sp), "error": "override backup hash mismatch"})
				continue
			var target := odf_dir().path_join(ws_rel)
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
			var w := atomic_write_abs(target, ov_bytes)
			if not bool(w.get("ok", false)):
				failed.append({"source": str(sp), "error": str(w.get("error", "write failed"))})
				continue
			var ment: Dictionary = r.get("manifest_entry", {})
			if not record(str(sp), ws_rel, str(ment.get("source_md5", source_md5(str(sp)))), ov_bytes.size()):
				failed.append({"source": str(sp), "error": "manifest restore failed"})
				continue
		if work_b64 != "":
			var wbytes := Marshalls.base64_to_raw(work_b64)
			var exp_wmd5 := str(r.get("working_md5", ""))
			if exp_wmd5 == "" or _md5_bytes(wbytes) == exp_wmd5:
				var cdoc = OdfDocument.cached(str(sp))
				if cdoc is OdfDocument:
					cdoc.replace_text(wbytes.get_string_from_utf8())
					cdoc.dirty = bool(r.get("was_dirty", false))
					cdoc.workspace_override = had_ov
		restored.append(str(sp))
	return {"ok": failed.is_empty(), "status": "RESTORED" if failed.is_empty() else "PARTIAL_RESTORE", "restored": restored, "failed": failed}


## Explicitly discard ONLY unsaved in-memory edits, restoring the last saved
## workspace override if one exists, or the untouched factory source otherwise.
## Never modifies project.json or deletes a saved override (P0-02).
static func discard_unsaved_edits(doc) -> Dictionary:
	if doc == null or str(doc.source_path) == "":
		return {"ok": false, "status": "SOURCE_MISSING", "error": "invalid document"}
	var sp := str(doc.source_path)
	var ws_entry := entry_for(sp)
	if not ws_entry.is_empty():
		var rel := clean_rel(str(ws_entry.get("rel", "")))
		var target := odf_dir().path_join(rel)
		if rel != "" and FileAccess.file_exists(target):
			var ws_doc := OdfDocument.load_file(target)
			if ws_doc != null:
				doc.restore_factory_state_from(ws_doc)
				doc.workspace_override = true
				doc.workspace_rel = rel
				doc.workspace_source_md5 = str(ws_entry.get("source_md5", ""))
				var cur_md5 := source_md5(sp)
				doc.source_hash = cur_md5
				doc.workspace_conflict = cur_md5 == "" or (doc.workspace_source_md5 != "" and cur_md5 != doc.workspace_source_md5)
				OdfDocument.cache_document(doc)
				return {"ok": true, "status": "RESTORED_SAVED_REVISION", "had_override": true, "error": ""}
	if not FileAccess.file_exists(sp):
		return {"ok": false, "status": "SOURCE_MISSING", "error": "original source missing: " + sp}
	var fdoc := OdfDocument.load_file(sp)
	if fdoc == null:
		return {"ok": false, "status": "SOURCE_MISSING", "error": "cannot read original source: " + sp}
	doc.restore_factory_state_from(fdoc)
	OdfDocument.cache_document(doc)
	return {"ok": true, "status": "RESTORED_ORIGINAL_SOURCE", "had_override": false, "error": ""}


## Revert an in-memory OdfDocument back to its unmodified factory on-disk bytes
## and remove any saved workspace override for it, preserving object identity.
## P0-02: Returns structured outcome; NEVER mutates in-memory state when
## persistent workspace override removal or backup fails.
## Status values: SUCCESS, NO_OVERRIDE, BACKUP_FAILED, MANIFEST_FAILED,
## RECOVERY_PENDING, SOURCE_MISSING, SOURCE_CHANGED.
static func revert_document(doc) -> Dictionary:
	if doc == null or str(doc.source_path) == "":
		return {
			"ok": false,
			"status": "SOURCE_MISSING",
			"outcome": "SOURCE_MISSING",
			"had_override": false,
			"had_dirty": false,
			"already_default": false,
			"recovery_pending": false,
			"source_missing": true,
			"source_changed": false,
			"backup": "",
			"error": "invalid document or missing source_path",
		}
	var sp := str(doc.source_path)
	var ws_entry := entry_for(sp)
	var has_entry := not ws_entry.is_empty()
	var had_override := has_entry or bool(doc.workspace_override)
	var had_dirty := bool(doc.dirty)
	if not FileAccess.file_exists(sp):
		return {
			"ok": false,
			"status": "SOURCE_MISSING",
			"outcome": "SOURCE_MISSING",
			"had_override": had_override,
			"had_dirty": had_dirty,
			"already_default": false,
			"recovery_pending": false,
			"source_missing": true,
			"source_changed": false,
			"backup": "",
			"error": "original factory source file is missing: " + sp,
		}
	var fdoc := OdfDocument.load_file(sp)
	if fdoc == null:
		return {
			"ok": false,
			"status": "SOURCE_MISSING",
			"outcome": "SOURCE_MISSING",
			"had_override": had_override,
			"had_dirty": had_dirty,
			"already_default": false,
			"recovery_pending": false,
			"source_missing": true,
			"source_changed": false,
			"backup": "",
			"error": "could not load factory source file: " + sp,
		}
	var factory_bytes := fdoc.to_bytes()
	if not had_override and not had_dirty and doc.to_bytes() == factory_bytes:
		return {
			"ok": true,
			"status": "NO_OVERRIDE",
			"outcome": "NO_OVERRIDE",
			"had_override": false,
			"had_dirty": false,
			"already_default": true,
			"recovery_pending": false,
			"source_missing": false,
			"source_changed": false,
			"backup": "",
			"error": "",
		}
	var backup_path := ""
	var src_changed := false
	if has_entry:
		var disc := discard_override_ex(sp)
		if not bool(disc.get("ok", false)):
			var raw_st := str(disc.get("status", ""))
			var mapped_st := raw_st
			var rec_pend := false
			if raw_st == TX_RECOVERY_PENDING:
				mapped_st = "RECOVERY_PENDING"
				rec_pend = true
			elif raw_st == "MANIFEST_UNCHANGED":
				mapped_st = "MANIFEST_FAILED"
				rec_pend = true
			elif raw_st != "BACKUP_FAILED":
				mapped_st = "MANIFEST_FAILED"
			# Do NOT mutate `doc` in memory when persistent state could not be reconciled.
			return {
				"ok": false,
				"status": mapped_st,
				"raw_status": raw_st,
				"outcome": "RESET_FAILED_RECOVERABLE",
				"had_override": true,
				"had_dirty": had_dirty,
				"already_default": false,
				"recovery_pending": rec_pend,
				"source_missing": false,
				"source_changed": false,
				"backup": str(disc.get("backup", "")),
				"error": str(disc.get("error", "failed to remove workspace override")),
			}
		backup_path = str(disc.get("backup", ""))
		src_changed = bool(disc.get("source_changed", false))
	elif had_dirty:
		# Preserve dirty unsaved bytes in backups/ before discarding them.
		if _fault("backup_write"):
			return {
				"ok": false,
				"status": "BACKUP_FAILED",
				"outcome": "RESET_FAILED_RECOVERABLE",
				"had_override": had_override,
				"had_dirty": true,
				"already_default": false,
				"recovery_pending": false,
				"source_missing": false,
				"source_changed": false,
				"backup": "",
				"error": "could not preserve working bytes before reset",
			}
		var rel_key := clean_rel(doc.workspace_rel if str(doc.workspace_rel) != "" else ("working/%s_%s" % [canonical(sp).md5_text().substr(0, 8), sp.get_file()]))
		if rel_key != "":
			backup_path = backups_dir().path_join(rel_key) + ".bak"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(backup_path.get_base_dir()))
			if not _write_verified(ProjectSettings.globalize_path(backup_path), doc.to_bytes()):
				return {
					"ok": false,
					"status": "BACKUP_FAILED",
					"outcome": "RESET_FAILED_RECOVERABLE",
					"had_override": had_override,
					"had_dirty": true,
					"already_default": false,
					"recovery_pending": false,
					"source_missing": false,
					"source_changed": false,
					"backup": backup_path,
					"error": "working-bytes backup verification failed",
				}
	if not src_changed and doc.workspace_source_md5 != "" and fdoc.source_hash != "" and doc.workspace_source_md5 != fdoc.source_hash:
		src_changed = true
	doc.restore_factory_state_from(fdoc)
	doc.workspace_rel = ""
	doc.workspace_source_md5 = ""
	OdfDocument.cache_document(doc)
	return {
		"ok": true,
		"status": "SOURCE_CHANGED" if src_changed else "SUCCESS",
		"outcome": "SUCCESS",
		"had_override": had_override,
		"had_dirty": had_dirty,
		"already_default": false,
		"recovery_pending": false,
		"source_missing": false,
		"source_changed": src_changed,
		"backup": backup_path,
		"error": "",
	}


## Load every recorded override into the OdfDocument cache under its original
## source path. Returns the number restored. The original game file is never
## written; `workspace_conflict` marks a source changed after the save.
static func restore_cache() -> int:
	recover_transactions()
	var restored := 0
	for e in entries():
		var source := str(e.get("source", ""))
		var rel := clean_rel(str(e.get("rel", "")))
		if source == "" or rel == "":
			continue
		var target := odf_dir().path_join(rel)
		if not is_within(odf_dir(), target):
			continue
		if not FileAccess.file_exists(target):
			# Recover an interrupted replace from the last backup.
			var bak := backups_dir().path_join(rel) + ".bak"
			if not FileAccess.file_exists(bak):
				continue
			atomic_write_abs(target, FileAccess.get_file_as_bytes(bak))
		if OdfDocument.has_cached(source):
			continue
		var doc := OdfDocument.load_file(target)
		if doc == null:
			continue
		doc.source_path = source
		doc.workspace_override = true
		doc.workspace_rel = rel
		doc.workspace_source_md5 = str(e.get("source_md5", ""))
		var current := source_md5(source)
		doc.source_hash = current
		doc.workspace_conflict = current == "" or (doc.workspace_source_md5 != "" and current != doc.workspace_source_md5)
		doc.dirty = false
		OdfDocument.cache_document(doc)
		restored += 1
	return restored


## Staged export helper: strict-root checked atomic write.
static func write_staged(stage_root: String, rel: String, bytes: PackedByteArray) -> Dictionary:
	var safe := clean_rel(rel)
	if safe == "":
		return {"ok": false, "target": "", "error": "unsafe relative path: " + rel}
	var canon_stage := canonical(stage_root)
	var prot := check_protected_root(canon_stage)
	if bool(prot.get("protected", false)):
		return {"ok": false, "target": "", "error": str(prot.get("error", "protected stage root"))}
	var target := canon_stage.path_join(safe)
	if not is_within(canon_stage, target):
		return {"ok": false, "target": "", "error": "target escapes export root"}
	register_stage_root(canon_stage)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
	return transactional_write_abs(target, bytes, "", {"op": "staged_export", "stage_root": canon_stage, "rel": safe}, false)


## Backwards-compatible convenience: a committed recoverable transaction.
static func atomic_write_abs(target: String, bytes: PackedByteArray) -> Dictionary:
	return transactional_write_abs(target, bytes, "", {}, false)


## Write and replace with a journal. `keep_journal` lets a caller make the
## replacement and manifest update one recovery unit; the caller must then
## call commit_transaction(). Returns {ok,target,journal,error}.
static func transactional_write_abs(target: String, bytes: PackedByteArray, backup_path: String = "", journal_meta: Dictionary = {}, keep_journal: bool = false) -> Dictionary:
	var abs_target := canonical(target)
	if DirAccess.dir_exists_absolute(abs_target):
		return {"ok": false, "target": abs_target, "error": "target is a directory"}
	var existing_journal := _journal_path(abs_target)
	if FileAccess.file_exists(existing_journal):
		return {
			"ok": false,
			"status": TX_RECOVERY_PENDING,
			"target": abs_target,
			"journal": existing_journal,
			"error": "pending recovery journal exists for target; recover before retrying",
		}
	var dir := abs_target.get_base_dir()
	var mk := DirAccess.make_dir_recursive_absolute(dir)
	if mk != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "target": abs_target, "error": "cannot create " + dir}
	var temp := abs_target + ".tmp-" + str(Time.get_ticks_usec()) + "-" + str(randi())
	if not _write_verified(temp, bytes):
		return {"ok": false, "target": abs_target, "error": "temp write or verification failed"}
	var had_previous := FileAccess.file_exists(abs_target)
	if _fault("after_temp"):
		return {"ok": false, "target": abs_target, "error": "interrupted after temp write", "interrupted": true}
	var backup := ""
	if had_previous and backup_path != "":
		backup = canonical(backup_path)
		DirAccess.make_dir_recursive_absolute(backup.get_base_dir())
		var previous := FileAccess.get_file_as_bytes(abs_target)
		if not _write_verified(backup, previous):
			DirAccess.remove_absolute(temp)
			return {"ok": false, "target": abs_target, "error": "backup write failed"}
		if _fault("after_backup"):
			return {"ok": false, "target": abs_target, "error": "interrupted after backup", "interrupted": true}
	elif not had_previous and backup_path != "":
		# A stale backup must never masquerade as the previous revision.
		var stale := canonical(backup_path)
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(stale)
	var journal := existing_journal
	var record_meta := journal_meta.duplicate()
	record_meta["version"] = 1
	if not record_meta.has("op"):
		if str(record_meta.get("source", "")) != "" and str(record_meta.get("rel", "")) != "":
			record_meta["op"] = "workspace_odf"
		elif is_within(root(), abs_target):
			record_meta["op"] = "workspace_file"
		else:
			for obase in owned_stage_bases():
				if is_within(obase, abs_target):
					record_meta["op"] = "staged_export"
					record_meta["rel"] = abs_target.trim_prefix(obase).trim_prefix("/")
					break
	record_meta["target"] = abs_target
	record_meta["temp"] = temp
	record_meta["backup"] = backup
	record_meta["md5"] = _md5_bytes(bytes)
	record_meta["size"] = bytes.size()
	record_meta["created"] = Time.get_datetime_string_from_system()
	if not _write_verified(journal, JSON.stringify(record_meta, "  ").to_utf8_buffer()):
		DirAccess.remove_absolute(temp)
		return {"ok": false, "target": abs_target, "error": "journal write failed"}
	if _fault("after_journal"):
		return {"ok": false, "target": abs_target, "journal": journal, "error": "interrupted after journal", "interrupted": true}
	if had_previous:
		var rm := DirAccess.remove_absolute(abs_target)
		if rm != OK:
			DirAccess.remove_absolute(temp)
			DirAccess.remove_absolute(journal)
			return {"ok": false, "target": abs_target, "error": "cannot replace existing target: " + error_string(rm)}
		if _fault("after_remove_old"):
			return {"ok": false, "target": abs_target, "journal": journal, "error": "interrupted after removing the old target", "interrupted": true}
	var rn := DirAccess.rename_absolute(temp, abs_target)
	if rn != OK:
		if had_previous and backup != "" and FileAccess.file_exists(backup):
			_write_verified(abs_target, FileAccess.get_file_as_bytes(backup))
		DirAccess.remove_absolute(temp)
		if not keep_journal:
			DirAccess.remove_absolute(journal)
		return {"ok": false, "target": abs_target, "error": "rename failed: " + error_string(rn)}
	if _fault("after_rename"):
		return {"ok": false, "target": abs_target, "journal": journal, "error": "interrupted after rename", "interrupted": true}
	if not _matches(FileAccess.get_file_as_bytes(abs_target), _md5_bytes(bytes), bytes.size()):
		if had_previous and backup != "" and FileAccess.file_exists(backup):
			_write_verified(abs_target, FileAccess.get_file_as_bytes(backup))
		if not keep_journal:
			DirAccess.remove_absolute(journal)
		return {"ok": false, "target": abs_target, "error": "integrity check failed; previous revision restored"}
	if _fault("after_verify"):
		return {"ok": false, "target": abs_target, "journal": journal, "error": "interrupted after verification", "interrupted": true}
	if not keep_journal:
		if _fault("journal_cleanup"):
			return {"ok": false, "target": abs_target, "journal": journal, "error": "interrupted before journal cleanup", "interrupted": true}
		DirAccess.remove_absolute(journal)
	return {"ok": true, "target": abs_target, "journal": journal, "error": ""}


static func commit_transaction(journal_path: String) -> void:
	if _fault("journal_cleanup"):
		return
	if journal_path != "" and FileAccess.file_exists(journal_path):
		DirAccess.remove_absolute(journal_path)


static func _journal_path(abs_target: String) -> String:
	var dir := ProjectSettings.globalize_path(transactions_dir())
	DirAccess.make_dir_recursive_absolute(dir)
	var key := canonical(abs_target)
	if OS.get_name() == "Windows":
		key = key.to_lower()
	return dir.path_join(key.md5_text() + ".json")


## Write via a sibling temp and rename. Used for temps, backups and journals
## themselves; not a claim of crash atomicity for the final target.
static func _write_verified(path: String, bytes: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var temp := path + ".tmp-" + str(Time.get_ticks_usec()) + "-" + str(randi())
	var f := FileAccess.open(temp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK or not FileAccess.file_exists(temp) or not _matches(FileAccess.get_file_as_bytes(temp), _md5_bytes(bytes), bytes.size()):
		if FileAccess.file_exists(temp):
			DirAccess.remove_absolute(temp)
		return false
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if DirAccess.rename_absolute(temp, path) != OK:
		if FileAccess.file_exists(temp):
			DirAccess.remove_absolute(temp)
		return false
	return true
