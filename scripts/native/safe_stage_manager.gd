class_name SafeStageManager
extends RefCounted
## Allowlisted staging manager for native BZCC tests and isolated exports.
##
## Staging is permitted only inside explicitly owned staging base roots
## (defaulting to user://native_tests and <workspace>/native_staging).
## Game installations, Steam Workshop, VRV, Wintage, Engine Knowledge,
## project source trees, junctions/symlinks and arbitrary unowned folders are
## unconditionally refused.
##
## Both restaging and cleanup verify current file MD5 against the stage manifest
## before overwriting or deleting anything so modified owned files or unknown
## files are never overwritten or deleted silently.

const MANIFEST_NAME := "stage_manifest.json"
const RECOVERY_MARKER_NAME := "stage_recovery_pending.json"
const BACKUP_SUBDIR := ".shaman_stage_backups"

## Test-only fault injection knobs. Production code never sets these.
static var fault_fail_rel := ""
static var fault_rollback_fail_rel := ""


static func _parse_json_safe(text: String) -> Dictionary:
	return WorkspaceStore.parse_json_safe(text)


static func owned_bases() -> Array[String]:
	return WorkspaceStore.owned_stage_bases()


static func clear_registered_bases() -> void:
	WorkspaceStore.registered_owned_stage_bases.clear()


static func register_owned_base(base_path: String, extra_protected: Array[String] = []) -> Dictionary:
	var canon := WorkspaceStore.canonical(base_path)
	if canon == "":
		return {"ok": false, "error": "empty staging base", "reason": "INVALID_STAGE_ROOT"}
	var prot := WorkspaceStore.check_protected_root(canon, extra_protected)
	if bool(prot.get("protected", false)):
		return {"ok": false, "error": str(prot.get("error", "protected root")), "reason": "FORBIDDEN_SOURCE_ROOT"}
	if _has_link_component(canon):
		return {"ok": false, "error": "symlink/junction detected in path: " + canon, "reason": "SYMLINK_REJECTED"}
	if not WorkspaceStore.registered_owned_stage_bases.has(canon):
		WorkspaceStore.registered_owned_stage_bases.append(canon)
	return {"ok": true, "base": canon}


static func check_protected_root(candidate: String, extra_protected: Array[String] = []) -> Dictionary:
	return WorkspaceStore.check_protected_root(candidate, extra_protected)


static func _is_hex_md5(s: String) -> bool:
	if s.length() != 32:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		var is_digit := c >= 48 and c <= 57
		var is_lower := c >= 97 and c <= 102
		var is_upper := c >= 65 and c <= 70
		if not (is_digit or is_lower or is_upper):
			return false
	return true


static func _has_link_component(abs_path: String) -> bool:
	var canon := WorkspaceStore.canonical(abs_path)
	if canon == "":
		return false
	var parts := canon.split("/", false)
	if parts.is_empty():
		return false
	var cur := ""
	if canon.begins_with("/"):
		cur = "/"
	elif parts[0].ends_with(":"):
		cur = parts[0] + "/"
		parts.remove_at(0)
	for part in parts:
		var parent := cur if cur != "" else "/"
		var next := parent.path_join(part) if not parent.ends_with("/") else parent + part
		if DirAccess.dir_exists_absolute(parent):
			var d := DirAccess.open(parent)
			if d != null and d.has_method("is_link") and d.is_link(part):
				return true
		cur = next
	return false


## T-223 / STAGE-RES: one reserved-stage path policy for SHAMAN-owned backup
## and metadata namespaces. T-224 extends the backup namespace to every path
## component so inventory and validation cannot disagree about protected data.
const RESERVED_STAGE_NAMES := [
	"stage_manifest.json", "stage_recovery_pending.json",
	"native_evidence.json", "stage_provenance.json", "stage_cleanup_receipt.json",
]


static func path_identity(rel: String) -> String:
	var clean := WorkspaceStore.clean_rel(rel).strip_edges().replace("\\", "/")
	if OS.get_name() == "Windows":
		var identity_parts: Array[String] = []
		for part in clean.split("/", false):
			identity_parts.append(part.trim_suffix(".").trim_suffix(" ").to_lower())
		return "/".join(PackedStringArray(identity_parts))
	return clean


static func _is_windows_alias_path(rel: String) -> bool:
	if OS.get_name() != "Windows":
		return false
	var clean := WorkspaceStore.clean_rel(rel).strip_edges().replace("\\", "/")
	for part in clean.split("/", false):
		if part != part.trim_suffix(".").trim_suffix(" "):
			return true
	return false


static func _is_backup_stage_path(rel: String) -> bool:
	var clean := WorkspaceStore.clean_rel(rel).strip_edges().replace("\\", "/")
	for part in clean.split("/", false):
		if part.to_lower() == BACKUP_SUBDIR:
			return true
	return false


static func _is_reserved_stage_path(rel: String) -> bool:
	var clean := WorkspaceStore.clean_rel(rel).strip_edges().replace("\\", "/")
	if clean == "":
		return false
	if _is_backup_stage_path(clean):
		return true
	for reserved in RESERVED_STAGE_NAMES:
		if clean.to_lower() == str(reserved).to_lower():
			return true
	return false


static func _same_path(a: String, b: String) -> bool:
	var ca := WorkspaceStore.canonical(a)
	var cb := WorkspaceStore.canonical(b)
	if OS.get_name() == "Windows":
		return ca.to_lower() == cb.to_lower()
	return ca == cb


static func _validate_manifest_dict(parsed, expected_stage_dir: String) -> Dictionary:
	if not (parsed is Dictionary):
		return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json is not a JSON object"}
	if int(parsed.get("schema", 0)) < 1:
		return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json missing valid schema"}
	if str(parsed.get("stage_id", "")).strip_edges() == "":
		return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json missing stage_id"}
	var m_root := str(parsed.get("stage_root", ""))
	if m_root == "" or not _same_path(m_root, expected_stage_dir):
		return {"ok": false, "reason": "MANIFEST_ROOT_MISMATCH", "error": "stage_manifest.json stage_root does not match stage dir"}
	var files = parsed.get("files", null)
	if not (files is Array):
		return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json files is not an Array"}
	var seen_paths := {}
	for item in files:
		if not (item is Dictionary):
			return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json contains non-dict file entry"}
		var raw_rel := str(item.get("rel", ""))
		var clean := WorkspaceStore.clean_rel(raw_rel)
		if clean == "" or clean != raw_rel.replace("\\", "/").strip_edges():
			return {"ok": false, "reason": "TRAVERSAL_REJECTED", "error": "stage_manifest.json contains unsafe path: " + raw_rel}
		if _is_windows_alias_path(raw_rel):
			return {"ok": false, "reason": "WINDOWS_PATH_ALIAS_REJECTED", "error": "stage_manifest.json contains a Windows alias path: " + raw_rel}
		if _is_reserved_stage_path(clean):
			return {"ok": false, "reason": "RESERVED_STAGE_PATH", "error": "stage_manifest.json names a reserved SHAMAN path: " + raw_rel}
		var identity := path_identity(clean)
		if seen_paths.has(identity):
			return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json contains duplicate physical path: " + raw_rel}
		seen_paths[identity] = true
		if not _is_hex_md5(str(item.get("md5", ""))):
			return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json entry missing valid md5: " + clean}
	return {"ok": true, "manifest": parsed}


static func allocate_stage_dir(prefix: String = "stage") -> String:
	var safe_prefix := prefix.strip_edges().replace("/", "_").replace("\\", "_").replace("..", "_")
	if safe_prefix == "":
		safe_prefix = "stage"
	var base := WorkspaceStore.canonical("user://native_tests")
	var candidate := base.path_join("%s_%d_%d" % [safe_prefix, Time.get_ticks_usec(), randi()])
	while DirAccess.dir_exists_absolute(candidate):
		candidate = base.path_join("%s_%d_%d" % [safe_prefix, Time.get_ticks_usec(), randi()])
	return candidate


static func validate_stage_destination(stage_root: String, extra_protected: Array[String] = []) -> Dictionary:
	var stage := WorkspaceStore.canonical(stage_root)
	if stage == "":
		return {"ok": false, "reason": "INVALID_STAGE_ROOT", "error": "empty stage root"}
	var prot := check_protected_root(stage, extra_protected)
	if bool(prot.get("protected", false)):
		return {"ok": false, "reason": "FORBIDDEN_SOURCE_ROOT", "error": str(prot.get("error", ""))}
	if _has_link_component(stage):
		return {"ok": false, "reason": "SYMLINK_REJECTED", "error": "refusing symlink/junction stage path: " + stage}
	var allowed := false
	var matched_base := ""
	for base in owned_bases():
		if WorkspaceStore.is_within(base, stage):
			allowed = true
			matched_base = base
			break
	if not allowed:
		return {
			"ok": false,
			"reason": "UNOWNED_STAGE_ROOT",
			"error": "refusing unowned stage directory outside allowlist: " + stage,
		}
	return {"ok": true, "stage": stage, "base": matched_base, "reason": "", "error": ""}


## Protected backups are a separate inventory class: the ordinary walker skips
## BACKUP_SUBDIR, so this is the authoritative reader for retained payload.
static func _list_protected_backup_files(stage_root: String) -> Array[String]:
	var out: Array[String] = []
	var backup_root := stage_root.path_join(BACKUP_SUBDIR)
	if not DirAccess.dir_exists_absolute(backup_root):
		return out
	_list_existing_rel_files(backup_root, stage_root, out)
	out.sort()
	return out


static func _list_existing_rel_files(dir_path: String, root_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if n != "." and n != "..":
			var full := dir_path.path_join(n)
			if dir.has_method("is_link") and dir.is_link(n):
				out.append(full.trim_prefix(root_path).trim_prefix("/"))
			elif dir.current_is_dir():
				_list_existing_rel_files(full, root_path, out)
			else:
				out.append(full.trim_prefix(root_path).trim_prefix("/"))
		n = dir.get_next()
	dir.list_dir_end()


## Stage files into an allowlisted stage directory.
## `options` supports:
##   stage_id: String (use caller/session immutable stage_id)
##   conflict_strategy: "refuse" (default) | "preserve" | "replace_with_backup"
static func stage(stage_root: String, files: Dictionary, metadata: Dictionary = {},
		dry_run: bool = false, extra_protected: Array[String] = [],
		options: Dictionary = {}) -> Dictionary:
	var check := validate_stage_destination(stage_root, extra_protected)
	if not bool(check.get("ok", false)):
		return check
	var stage_dir := str(check.get("stage", ""))
	var recovery_marker := stage_dir.path_join(RECOVERY_MARKER_NAME)
	if FileAccess.file_exists(recovery_marker) and not bool(options.get("clear_recovery", false)):
		return {
			"ok": false,
			"stage": stage_dir,
			"status": "RECOVERY_PENDING",
			"reason": "RECOVERY_PENDING",
			"recovery_pending": true,
			"recovery_marker": recovery_marker,
			"error": "refusing to restage while stage_recovery_pending.json is unresolved",
		}
	var manifest_path := stage_dir.path_join(MANIFEST_NAME)
	var owned_files: Dictionary = {}
	var owned_by_identity := {}
	var existing_stage_id := ""
	if FileAccess.file_exists(manifest_path):
		var jres := _parse_json_safe(FileAccess.get_file_as_string(manifest_path))
		if not bool(jres.get("ok", false)):
			return {
				"ok": false,
				"stage": stage_dir,
				"reason": "INVALID_STAGE_MANIFEST",
				"error": "corrupted existing stage_manifest.json: " + str(jres.get("error", "")),
			}
		var parsed = jres.get("data", null)
		var mcheck := _validate_manifest_dict(parsed, stage_dir)
		if not bool(mcheck.get("ok", false)):
			return {
				"ok": false,
				"stage": stage_dir,
				"reason": str(mcheck.get("reason", "INVALID_STAGE_MANIFEST")),
				"error": str(mcheck.get("error", "corrupted existing stage_manifest.json")),
			}
		existing_stage_id = str(parsed.get("stage_id", ""))
		for item in parsed.get("files", []):
			if item is Dictionary:
				var rel := str(item.get("rel", ""))
				owned_files[rel] = str(item.get("md5", "")).to_lower()
				owned_by_identity[path_identity(rel)] = rel

	var existing_unknown: Dictionary = {}
	var protected_backup_files: Array[String] = []
	if DirAccess.dir_exists_absolute(stage_dir):
		var existing_list: Array[String] = []
		_list_existing_rel_files(stage_dir, stage_dir, existing_list)
		for rel_existing in existing_list:
			if rel_existing == MANIFEST_NAME or rel_existing == RECOVERY_MARKER_NAME:
				continue
			if _is_backup_stage_path(rel_existing):
				protected_backup_files.append(rel_existing)
				continue
			if not owned_by_identity.has(path_identity(rel_existing)):
				existing_unknown[path_identity(rel_existing)] = true

	var conflict_strategy := str(options.get("conflict_strategy", "refuse")).strip_edges().to_lower()
	var explicit_stage_id := str(options.get("stage_id", "")).strip_edges()
	if existing_stage_id != "" and explicit_stage_id != "" and explicit_stage_id != existing_stage_id:
		return {
			"ok": false,
			"stage": stage_dir,
			"reason": "STAGE_IDENTITY_MISMATCH",
			"error": "existing stage_id %s cannot be replaced by %s through restaging" % [existing_stage_id, explicit_stage_id],
		}
	var planned: Array[Dictionary] = []
	var modified_conflicts: Array[Dictionary] = []
	var preserved_modified: Array[String] = []
	var explicit_backups_needed: Dictionary = {}
	var incoming_targets := {}

	for raw_rel in files:
		var raw_text := str(raw_rel)
		var safe := WorkspaceStore.clean_rel(raw_text)
		if safe == "":
			return {"ok": false, "stage": stage_dir, "reason": "TRAVERSAL_REJECTED", "error": "unsafe staged path: " + raw_text}
		if _is_windows_alias_path(raw_text):
			return {"ok": false, "stage": stage_dir, "reason": "WINDOWS_PATH_ALIAS_REJECTED", "error": "Windows alias stage path cannot be staged: " + raw_text}
		if _is_reserved_stage_path(safe):
			return {"ok": false, "stage": stage_dir, "reason": "RESERVED_STAGE_PATH", "error": "reserved SHAMAN stage path cannot be staged: " + raw_text}
		var safe_identity := path_identity(safe)
		if incoming_targets.has(safe_identity):
			return {
				"ok": false,
				"stage": stage_dir,
				"reason": "DUPLICATE_TARGET",
				"error": "incoming paths resolve to one physical stage file: " + str(incoming_targets[safe_identity]) + " / " + safe,
			}
		incoming_targets[safe_identity] = safe
		if existing_unknown.has(safe_identity):
			return {
				"ok": false,
				"stage": stage_dir,
				"reason": "UNOWNED_FILE_COLLISION",
				"error": "refusing to overwrite existing unknown file in stage dir: " + safe,
			}
		var target := WorkspaceStore.canonical(stage_dir.path_join(safe))
		if not WorkspaceStore.is_within(stage_dir, target):
			return {"ok": false, "stage": stage_dir, "reason": "TARGET_ESCAPES_STAGE", "error": "target escapes stage root: " + safe}
		if _has_link_component(target):
			return {"ok": false, "stage": stage_dir, "reason": "SYMLINK_REJECTED", "error": "refusing symlink/junction target path: " + safe}
		var raw = files[raw_rel]
		var bytes: PackedByteArray = raw if raw is PackedByteArray else str(raw).to_utf8_buffer()

		# P0-SAFETY-01: Mandatory MD5 verification before overwriting any existing owned file.
		if owned_by_identity.has(safe_identity):
			var owned_rel := str(owned_by_identity[safe_identity])
			var expected_md5 := str(owned_files[owned_rel]).to_lower()
			if FileAccess.file_exists(target):
				var current_md5 := FileAccess.get_md5(target).to_lower()
				if current_md5 != expected_md5:
					var conflict_info := {
						"rel": safe,
						"target": target,
						"manifest_md5": expected_md5,
						"current_md5": current_md5,
						"incoming_bytes": bytes.size(),
						"current_bytes": FileAccess.get_file_as_bytes(target).size(),
					}
					if conflict_strategy == "preserve":
						preserved_modified.append(safe)
						continue
					elif conflict_strategy == "replace_with_backup":
						explicit_backups_needed[safe] = target
					else:
						modified_conflicts.append(conflict_info)
						continue

		planned.append({"rel": safe, "target": target, "bytes": bytes})

	if not modified_conflicts.is_empty():
		return {
			"ok": false,
			"stage": stage_dir,
			"reason": "MODIFIED_OWNED_FILE_CONFLICT",
			"error": "refusing to overwrite modified owned file(s) without explicit strategy: " + ", ".join(modified_conflicts.map(func(c): return str(c.rel))),
			"conflicts": modified_conflicts,
			"strategies": ["preserve", "allocate_new", "diff", "replace_with_backup"],
		}

	if dry_run:
		var dry_items: Array[Dictionary] = []
		for item in planned:
			dry_items.append({"rel": item.rel, "bytes": (item.bytes as PackedByteArray).size()})
		return {
			"ok": true,
			"dry_run": true,
			"stage": stage_dir,
			"manifest": manifest_path,
			"planned": dry_items,
			"preserved": preserved_modified,
			"protected_backups": protected_backup_files,
		}

	DirAccess.make_dir_recursive_absolute(stage_dir)
	WorkspaceStore.register_stage_root(stage_dir)

	var backup_paths: Array[String] = []
	for brel in explicit_backups_needed:
		var bsrc := str(explicit_backups_needed[brel])
		var bdest := stage_dir.path_join(BACKUP_SUBDIR).path_join("%s.%d.bak" % [brel, Time.get_ticks_usec()])
		var bres := WorkspaceStore.atomic_write_abs(bdest, FileAccess.get_file_as_bytes(bsrc))
		if not bool(bres.get("ok", false)):
			return {
				"ok": false,
				"stage": stage_dir,
				"reason": "BACKUP_WRITE_FAILED",
				"error": "failed to back up modified owned file before replacement: " + brel,
			}
		backup_paths.append(bdest)

	var created_targets: Array[String] = []
	var overwritten_backups: Dictionary = {}
	var staged: Array[Dictionary] = []
	var failures: Array[Dictionary] = []
	for item in planned:
		var rel := str(item.rel)
		var target_path := str(item.target)
		var bytes: PackedByteArray = item.bytes
		var existed_before := FileAccess.file_exists(target_path)
		if existed_before and not overwritten_backups.has(target_path):
			overwritten_backups[target_path] = {"rel": rel, "bytes": FileAccess.get_file_as_bytes(target_path)}
		var res: Dictionary
		if fault_fail_rel != "" and rel == fault_fail_rel:
			res = {"ok": false, "error": "injected staging write failure on " + rel}
		else:
			res = WorkspaceStore.write_staged(stage_dir, rel, bytes)
		if bool(res.get("ok", false)):
			var target_written := str(res.get("target", target_path))
			if not existed_before:
				created_targets.append(target_written)
			staged.append({
				"rel": rel,
				"bytes": bytes.size(),
				"md5": FileAccess.get_md5(target_written),
			})
		else:
			failures.append({"rel": rel, "error": str(res.get("error", ""))})
			break

	if not failures.is_empty():
		var rb := _rollback_stage_writes(created_targets, overwritten_backups, stage_dir, preserved_modified)
		var pending := bool(rb.get("recovery_pending", false))
		var err_text := "staging failed; rollback incomplete — RECOVERY_PENDING" if pending else "staging failed; created files removed and overwritten owned files restored"
		return {
			"ok": false,
			"stage": stage_dir,
			"status": "RECOVERY_PENDING" if pending else "ROLLED_BACK",
			"reason": "RECOVERY_PENDING" if pending else "STAGE_WRITE_FAILED",
			"error": err_text,
			"failures": failures,
			"restored_overwritten": (rb.get("restored", []) as Array).size(),
			"rollback": rb,
			"recovery_pending": pending,
			"staged": staged,
		}

	# Merge any previously owned files that remain on disk and were not replaced in this call.
	var staged_identities := {}
	for sitem in staged:
		staged_identities[path_identity(str(sitem.rel))] = true
	var merged_files: Array[Dictionary] = staged.duplicate()
	for prev_rel in owned_files:
		if staged_identities.has(path_identity(prev_rel)):
			continue
		var prev_target := WorkspaceStore.canonical(stage_dir.path_join(prev_rel))
		if FileAccess.file_exists(prev_target):
			merged_files.append({
				"rel": prev_rel,
				"bytes": FileAccess.get_file_as_bytes(prev_target).size(),
				"md5": str(owned_files[prev_rel]),
			})

	var stage_id := explicit_stage_id
	if stage_id == "":
		stage_id = existing_stage_id if existing_stage_id != "" else stage_dir.get_file()
	if stage_id == "":
		stage_id = "stage_%d" % Time.get_ticks_usec()

	var stage_manifest := {
		"schema": 1,
		"stage_id": stage_id,
		"stage_root": stage_dir,
		"created": Time.get_datetime_string_from_system(),
		"metadata": metadata,
		"files": merged_files,
	}
	var mwrite := WorkspaceStore.atomic_write_abs(manifest_path, JSON.stringify(stage_manifest, "  ").to_utf8_buffer())
	if not bool(mwrite.get("ok", false)):
		var rb2 := _rollback_stage_writes(created_targets, overwritten_backups, stage_dir, preserved_modified)
		var pending2 := bool(rb2.get("recovery_pending", false))
		return {
			"ok": false,
			"stage": stage_dir,
			"status": "RECOVERY_PENDING" if pending2 else "ROLLED_BACK",
			"reason": "RECOVERY_PENDING" if pending2 else "STAGE_MANIFEST_FAILED",
			"error": "stage manifest write failed; rollback incomplete (RECOVERY_PENDING)" if pending2 else "stage manifest write failed; rolled back staged writes",
			"restored_overwritten": (rb2.get("restored", []) as Array).size(),
			"rollback": rb2,
			"recovery_pending": pending2,
		}

	return {
		"ok": true,
		"stage": stage_dir,
		"stage_id": stage_id,
		"manifest": manifest_path,
		"staged": staged,
		"preserved": preserved_modified,
		"backups": backup_paths,
		"protected_backups": protected_backup_files,
	}


## Roll back partial staging writes and return detailed recovery status.
## If any overwrite restore fails, persists durable RECOVERY_PENDING metadata
## and never falsely claims all overwritten files were restored.
static func _rollback_stage_writes(created_targets: Array[String], overwritten_backups: Dictionary,
		stage_dir: String, preserved: Array[String] = []) -> Dictionary:
	var restored: Array[String] = []
	var failed: Array[Dictionary] = []
	var removed_created: Array[String] = []
	for prev_target in overwritten_backups:
		var rec: Dictionary = overwritten_backups[prev_target]
		var rel := str(rec.get("rel", ""))
		var old_bytes: PackedByteArray = rec.get("bytes", PackedByteArray())
		var w: Dictionary
		if fault_rollback_fail_rel != "" and rel == fault_rollback_fail_rel:
			w = {"ok": false, "error": "injected rollback write failure on " + rel}
		else:
			w = WorkspaceStore.atomic_write_abs(str(prev_target), old_bytes)
		if bool(w.get("ok", false)):
			restored.append(rel if rel != "" else str(prev_target))
		else:
			failed.append({
				"rel": rel,
				"target": str(prev_target),
				"error": str(w.get("error", "rollback write failed")),
				"expected_md5": WorkspaceStore._md5_bytes(old_bytes),
			})
	for created in created_targets:
		if FileAccess.file_exists(created):
			if DirAccess.remove_absolute(created) == OK:
				removed_created.append(created)
				_prune_empty_parents(created.get_base_dir(), stage_dir)
			else:
				failed.append({"rel": created, "target": created, "error": "failed removing newly created staged file"})

	var recovery_pending := not failed.is_empty()
	var recovery_marker := ""
	if recovery_pending:
		recovery_marker = stage_dir.path_join(RECOVERY_MARKER_NAME)
		var rec_doc := {
			"schema": 1,
			"status": "RECOVERY_PENDING",
			"created": Time.get_datetime_string_from_system(),
			"stage_root": stage_dir,
			"restored": restored,
			"failed": failed,
			"preserved": preserved,
		}
		WorkspaceStore.atomic_write_abs(recovery_marker, JSON.stringify(rec_doc, "  ").to_utf8_buffer())
	return {
		"restored": restored,
		"failed": failed,
		"preserved": preserved.duplicate(),
		"removed_created": removed_created,
		"recovery_pending": recovery_pending,
		"recovery_marker": recovery_marker,
	}


## Cleanup removes only manifest-owned files whose current MD5 matches the
## manifest hash. Modified files are preserved and reported as
## MODIFIED_FILE_PRESERVED; unknown files are never touched; symlinks/junctions
## and corrupted manifests are unconditionally rejected.
## Read-only inventory of a SHAMAN stage directory. Establishes ownership,
## verifies current file hashes against the manifest, and reports whether a
## cleanup would be safe. It never writes, renames, or deletes anything.
static func inspect_stage(stage_root: String) -> Dictionary:
	var canon := WorkspaceStore.canonical(stage_root)
	var result := {
		"ok": false, "stage_root": canon, "stage_id": "",
		"ownership": "UNRESOLVED", "hash_status": "UNVERIFIED",
		"session_status": "UNKNOWN", "session_id": "",
		"unknown_files": [], "modified_files": [], "missing_files": [],
		"protected_backups": [],
		"cleanup_allowed": false,
		"reason": "STAGE_INSPECTION_INCOMPLETE",
	}
	if canon == "" or not DirAccess.dir_exists_absolute(canon):
		result["reason"] = "STAGE_MISSING"
		return result
	var manifest_path := canon.path_join(MANIFEST_NAME)
	if not FileAccess.file_exists(manifest_path):
		result["reason"] = "MANIFEST_MISSING"
		return result
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(manifest_path))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		result["reason"] = "MANIFEST_CORRUPT"
		return result
	var manifest: Dictionary = jres.get("data", {})
	var validation := _validate_manifest_dict(manifest, canon)
	if not bool(validation.get("ok", false)):
		result["reason"] = str(validation.get("reason", "MANIFEST_INVALID"))
		return result
	result["ok"] = true
	result["stage_id"] = str(manifest.get("stage_id", ""))
	result["ownership"] = "MANIFEST_OWNED"
	var files: Array = manifest.get("files", []) if manifest.get("files", []) is Array else []
	for item in files:
		if not (item is Dictionary):
			result["modified_files"].append("<invalid manifest row>")
			continue
		var rel := str((item as Dictionary).get("rel", ""))
		var expected := str((item as Dictionary).get("md5", "")).to_lower()
		var path := canon.path_join(rel)
		if not FileAccess.file_exists(path):
			result["missing_files"].append(rel)
		elif WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(path)).to_lower() != expected:
			result["modified_files"].append(rel)
	var existing: Array[String] = []
	_list_existing_rel_files(canon, canon, existing)
	var declared := {}
	for item in files:
		if item is Dictionary:
			declared[path_identity(str((item as Dictionary).get("rel", "")))] = true
	declared[path_identity(MANIFEST_NAME)] = true
	# native_evidence.json is written by SHAMAN itself; treat it as known
	# metadata, never as a foreign file that blocks safety checks by mistake.
	declared[path_identity("native_evidence.json")] = true
	for rel in existing:
		if _is_backup_stage_path(rel):
			result["protected_backups"].append(rel)
		elif not declared.has(path_identity(rel)):
			result["unknown_files"].append(rel)
	var evidence_path := canon.path_join("native_evidence.json")
	if FileAccess.file_exists(evidence_path):
		var eres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(evidence_path))
		if bool(eres.get("ok", false)) and (eres.get("data", null) is Dictionary):
			var evidence: Dictionary = eres.get("data", {})
			result["session_id"] = str(evidence.get("session_id", ""))
			result["session_status"] = str(evidence.get("status", "UNKNOWN"))
	# Unknown files are reported and always preserved by cleanup(); they do not
	# invalidate the integrity of the manifest-owned files themselves.
	result["hash_status"] = "MATCH" if result["missing_files"].is_empty() and result["modified_files"].is_empty() else "MISMATCH"
	# Terminal-only gate: STAGED/FAILED sessions stay untouched; no automatic
	# deletion for an unresolved, active, or modified stage.
	var terminal := str(result["session_status"]).to_upper() in ["COMPLETE", "CANCELLED", "TIMEOUT", "NATIVE_VERIFIED", "COMPARISON_COMPLETE", "FAILED"]
	result["cleanup_allowed"] = terminal and result["hash_status"] == "MATCH" and result["session_id"] != ""
	result["reason"] = "TERMINAL_OWNED_STAGE" if result["cleanup_allowed"] else "STAGE_OWNERSHIP_UNRESOLVED"
	return result


## Terminal states that may authorize cleanup only after an authoritative ledger
## check. Kept local so reconciliation never depends on a live runner instance.
const _TERMINAL_RECONCILE_STATES := [
	"COMPLETE", "CANCELLED", "TIMEOUT", "NATIVE_VERIFIED",
	"COMPARISON_COMPLETE", "FAILED", "CLEANED_UP",
]


## Read-only check for a still-running monitor in process_monitors.json beside
## the ledger. A persisted monitor that is active, non-terminal, or pending
## recovery makes cleanup ineligible even when the session record is terminal.
static func _active_monitor_for_session(ledger_file: String, session_id: String) -> Dictionary:
	var result := {"active": false, "status": "NOT_FOUND"}
	if ledger_file.is_empty() or session_id == "":
		return result
	var path := ledger_file.get_base_dir().path_join("process_monitors.json")
	if not FileAccess.file_exists(path):
		return result
	var parsed := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	if not bool(parsed.get("ok", false)) or not (parsed.get("data", null) is Dictionary):
		result["status"] = "CORRUPT"
		result["active"] = true
		return result
	var monitors = (parsed.get("data", {}) as Dictionary).get("monitors", null)
	if not (monitors is Dictionary):
		result["status"] = "CORRUPT"
		result["active"] = true
		return result
	if not (monitors as Dictionary).has(session_id):
		result["status"] = "NO_MONITOR"
		return result
	var mon = (monitors as Dictionary).get(session_id, null)
	if not (mon is Dictionary):
		result["status"] = "CORRUPT"
		result["active"] = true
		return result
	var d: Dictionary = mon
	var state := str(d.get("state", "")).to_upper()
	var terminal := state in ["COMPARISON_COMPLETE", "NATIVE_VERIFIED", "TIMEOUT", "CANCELLED", "FAILED"]
	var active := bool(d.get("active", false)) or not terminal
	if bool(d.get("recoverable", false)) or state == "RECOVERY_PENDING" or str(d.get("cancel_status", "")) == "CANCEL_REQUESTED":
		active = true
	result["state"] = state
	result["status"] = "TERMINAL" if (terminal and not active) else "ACTIVE"
	result["active"] = active
	return result


## Safe reconciliation decision for a stage. Reads the durable session ledger
## without modifying it. Active, unknown, hash-mismatched, and evidence-bearing
## stages are always protected. This method never deletes files.
##
## CLEANUP_ELIGIBLE requires ALL of: manifest ownership, matching hashes, a
## session id, a parseable ledger with that session in a terminal state, ledger
## and evidence agreeing, and no active/recoverable monitor. A corrupt, missing
## or disagreeing ledger can never authorize cleanup; it yields PROTECT with
## RECOVERY_PENDING so a human reconciliation step is required.
static func reconcile_stage(stage_root: String, ledger_path: String = "") -> Dictionary:
	var inspection := inspect_stage(stage_root)
	var result: Dictionary = inspection.duplicate(true)
	result["action"] = "NONE"
	result["reconciled_at"] = Time.get_datetime_string_from_system()
	result["evidence_preserved"] = true
	result["ledger_status"] = "NOT_FOUND"
	result["monitor_status"] = "NOT_CHECKED"
	result["recovery_pending"] = false
	result["reason"] = "STAGE_INSPECTION_INCOMPLETE"
	if not bool(inspection.get("ok", false)):
		# The inspection failed (STAGE_MISSING, MANIFEST_MISSING,
		# MANIFEST_CORRUPT, ...): keep its specific reason instead of masking
		# it with the generic placeholder.
		result["action"] = "PROTECT"
		result["reason"] = str(inspection.get("reason", "STAGE_INSPECTION_INCOMPLETE"))
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	var sid := str(inspection.get("session_id", ""))
	var evidence_state := str(inspection.get("session_status", "")).to_upper()
	var ledger_state := ""
	var ledger_file := ledger_path
	if ledger_file.is_empty():
		ledger_file = WorkspaceStore.root().path_join("native_sessions").path_join("session_ledger.json")
	if sid == "":
		result["ledger_status"] = "NO_SESSION_ID"
	elif not FileAccess.file_exists(ledger_file):
		result["ledger_status"] = "LEDGER_NOT_FOUND"
	else:
		var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(ledger_file))
		if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
			result["ledger_status"] = "LEDGER_CORRUPT"
		else:
			var items = (jres.get("data", {}) as Dictionary).get("sessions", null)
			var ledger_sessions = (jres.get("data", {}) as Dictionary).get("ledger", null)
			if not (items is Dictionary) and ledger_sessions is Dictionary:
				items = ledger_sessions
			if not (items is Dictionary):
				result["ledger_status"] = "LEDGER_CORRUPT"
			elif not (items as Dictionary).has(sid):
				result["ledger_status"] = "SESSION_NOT_IN_LEDGER"
			else:
				var rec = (items as Dictionary).get(sid, null)
				if not (rec is Dictionary) or str((rec as Dictionary).get("state", "")).strip_edges() == "":
					result["ledger_status"] = "RECORD_NO_STATE"
				else:
					ledger_state = str((rec as Dictionary).get("state", "")).to_upper()
					var ledger_sid := str((rec as Dictionary).get("session_id", ""))
					if ledger_sid != "" and ledger_sid.to_lower() != sid.to_lower():
						result["ledger_status"] = "SESSION_ID_MISMATCH"
						ledger_state = ""
					else:
						result["ledger_status"] = "MATCH"

	var monitor := _active_monitor_for_session(ledger_file, sid)
	result["monitor_status"] = str(monitor.get("status", "NOT_CHECKED"))
	result["active_monitor"] = bool(monitor.get("active", false))

	var terminal := _TERMINAL_RECONCILE_STATES
	if str(inspection.get("ownership", "")) != "MANIFEST_OWNED" or evidence_state.is_empty() or evidence_state == "UNKNOWN":
		result["protect_reason"] = "STAGE_OWNERSHIP_UNRESOLVED"
		result["action"] = "PROTECT"
		result["reason"] = "STAGE_OWNERSHIP_UNRESOLVED"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	if str(inspection.get("hash_status", "")) != "MATCH":
		result["protect_reason"] = "STAGE_HASH_MISMATCH"
		result["action"] = "PROTECT"
		result["reason"] = "STAGE_HASH_MISMATCH"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	# P1-NATIVE-01: a never-launched dry-run stage is disposable without a
	# terminal native-game state. It requires its own, deliberately narrower
	# policy: ownership + hashes must still be verified, and the session must be
	# provably STAGED (never launched, no monitor, no launch-requested
	# checkpoint). Launched sessions keep the full terminal reconciliation below.
	var never_launched_states := ["STAGED"]
	var monitor_preflight := str(monitor.get("status", "NOT_CHECKED"))
	var ledger_unresolved := ledger_state == ""
	if never_launched_states.has(evidence_state) and str(inspection.get("session_id", "")) != "":
		var launched_markers := ["LAUNCH_REQUESTED", "STEAM_PROCESS_STARTED", "MONITOR_ARMED",
			"GAME_PROCESS_CANDIDATE", "GAME_PROCESS_DETECTED", "GAME_PROCESS_VERIFIED",
			"MISSION_OBSERVED", "RESOURCE_PROBE_CONFIRMED", "GAME_STARTED", "MISSION_LOADED"]
		var provably_never_launched := false
		if ledger_file != "" and FileAccess.file_exists(ledger_file):
			var lres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(ledger_file))
			if bool(lres.get("ok", false)) and (lres.get("data", null) is Dictionary):
				var items_nl = (lres.get("data", {}) as Dictionary).get("sessions", null)
				var ledger_nl = (lres.get("data", {}) as Dictionary).get("ledger", null)
				if not (items_nl is Dictionary) and ledger_nl is Dictionary:
					items_nl = ledger_nl
				if items_nl is Dictionary and (items_nl as Dictionary).has(sid):
					var rec_nl = (items_nl as Dictionary).get(sid, {})
					if rec_nl is Dictionary:
						var sess_nl: Dictionary = (rec_nl as Dictionary).get("session", {})
						var launched := bool((rec_nl as Dictionary).get("launch_attempted", false))
						for cp in (sess_nl.get("checkpoints", []) as Array):
							if cp is Dictionary:
								var cp_state := str((cp as Dictionary).get("state", "")).to_upper()
								if launched_markers.has(cp_state):
									launched = true
									break
						# NC-44: the dry-run policy is additionally constrained to
						# ledger states that are themselves never-launched-safe;
						# a RECOVERY_PENDING record can never authorize it.
						var nl_state := str((rec_nl as Dictionary).get("state", "")).to_upper()
						provably_never_launched = not launched and nl_state in ["STAGED", "STAGE_MISSING"]
		# The dry-run shortcut demands POSITIVE proof: the ledger must contain
		# the session with no launch checkpoints, the monitor must be absent,
		# and the ledger must be resolvable at all.
		if provably_never_launched and not ledger_unresolved \
				and (monitor_preflight == "NO_MONITOR" or monitor_preflight == "NOT_FOUND") \
				and not bool(monitor.get("active", false)):
			result["action"] = "CLEANUP_ELIGIBLE_DRY_RUN"
			result["reason"] = "NEVER_LAUNCHED_OWNED_STAGE"
			result["cleanup_allowed"] = true
			result["never_launched"] = true
			return result
	if str(inspection.get("session_id", "")) == "":
		result["protect_reason"] = "NO_SESSION_ID"
		result["action"] = "PROTECT"
		result["reason"] = "NO_SESSION_ID"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	if ledger_state.is_empty():
		result["protect_reason"] = "LEDGER_STATE_UNRESOLVED"
		result["action"] = "PROTECT"
		result["reason"] = "LEDGER_STATE_UNRESOLVED"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	if not terminal.has(ledger_state):
		result["protect_reason"] = "STAGE_ACTIVE_OR_RECOVERABLE"
		result["action"] = "PROTECT"
		result["reason"] = "STAGE_ACTIVE_OR_RECOVERABLE"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	if evidence_state != ledger_state:
		result["protect_reason"] = "LEDGER_EVIDENCE_DISAGREE"
		result["action"] = "PROTECT"
		result["reason"] = "LEDGER_EVIDENCE_DISAGREE"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	if str(monitor.get("status", "")) == "CORRUPT":
		result["protect_reason"] = "MONITOR_STATE_UNRESOLVED"
		result["action"] = "PROTECT"
		result["reason"] = "MONITOR_STATE_UNRESOLVED"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	if bool(monitor.get("active", false)):
		result["protect_reason"] = "ACTIVE_MONITOR"
		result["action"] = "PROTECT"
		result["reason"] = "ACTIVE_MONITOR"
		result["cleanup_allowed"] = false
		result["recovery_pending"] = true
		return result
	result["action"] = "CLEANUP_ELIGIBLE"
	result["reason"] = "TERMINAL_OWNED_STAGE"
	result["cleanup_allowed"] = true
	return result


static func cleanup(stage_root: String, extra_protected: Array[String] = [],
		owned_updated_hashes: Dictionary = {}) -> Dictionary:
	var check := validate_stage_destination(stage_root, extra_protected)
	if not bool(check.get("ok", false)):
		return check
	var stage_dir := str(check.get("stage", ""))
	var manifest_path := stage_dir.path_join(MANIFEST_NAME)
	if not FileAccess.file_exists(manifest_path):
		return {"ok": false, "stage": stage_dir, "reason": "NO_STAGE_MANIFEST", "error": "refusing cleanup without stage_manifest.json"}
	var jres := _parse_json_safe(FileAccess.get_file_as_string(manifest_path))
	if not bool(jres.get("ok", false)):
		return {
			"ok": false,
			"stage": stage_dir,
			"reason": "INVALID_STAGE_MANIFEST",
			"error": "invalid stage_manifest.json: " + str(jres.get("error", "")),
		}
	var parsed = jres.get("data", null)
	var mcheck := _validate_manifest_dict(parsed, stage_dir)
	if not bool(mcheck.get("ok", false)):
		return {
			"ok": false,
			"stage": stage_dir,
			"reason": str(mcheck.get("reason", "INVALID_STAGE_MANIFEST")),
			"error": str(mcheck.get("error", "invalid stage_manifest.json")),
		}

	var removed := 0
	var preserved: Array[String] = []
	var rejected: Array[String] = []
	var results: Array[Dictionary] = []
	for item in parsed.get("files", []):
		var rel := WorkspaceStore.clean_rel(str(item.get("rel", "")))
		var expected_md5 := str(item.get("md5", "")).to_lower()
		var target := WorkspaceStore.canonical(stage_dir.path_join(rel))
		if not WorkspaceStore.is_within(stage_dir, target):
			rejected.append(rel)
			results.append({"rel": rel, "status": "TRAVERSAL_REJECTED"})
			continue
		if _has_link_component(target):
			rejected.append(rel)
			results.append({"rel": rel, "status": "SYMLINK_REJECTED"})
			continue
		if not FileAccess.file_exists(target):
			results.append({"rel": rel, "status": "ALREADY_ABSENT"})
			continue
		var actual_md5 := FileAccess.get_md5(target).to_lower()
		var allowed_override := str(owned_updated_hashes.get(rel, "")).to_lower()
		if actual_md5 != expected_md5 and (allowed_override == "" or actual_md5 != allowed_override):
			preserved.append(rel)
			results.append({
				"rel": rel,
				"status": "MODIFIED_FILE_PRESERVED",
				"expected_md5": expected_md5,
				"actual_md5": actual_md5,
			})
			continue
		if DirAccess.remove_absolute(target) == OK:
			removed += 1
			results.append({"rel": rel, "status": "REMOVED", "md5": actual_md5})
			_prune_empty_parents(target.get_base_dir(), stage_dir)
		else:
			rejected.append(rel)
			results.append({"rel": rel, "status": "REMOVE_FAILED", "md5": actual_md5})

	if not preserved.is_empty() or not rejected.is_empty():
		var reason := "MODIFIED_FILE_PRESERVED" if not preserved.is_empty() else "CLEANUP_PARTIAL_REJECTED"
		return {
			"ok": true,
			"partial": true,
			"status": "PARTIAL_CLEANUP",
			"reason": reason,
			"stage": stage_dir,
			"removed": removed,
			"preserved": preserved,
			"rejected": rejected,
			"results": results,
		}

	# P1-NATIVE-02: when unknown (non-manifest) files survive inside the stage,
	# the ownership manifest must NOT be deleted with the directory retained:
	# that would leave provenance-less leftovers. Instead record exactly what
	# was removed and keep a durable provenance receipt beside the stage, then
	# report the retained directory honestly.
	var surviving_unknown: Array[String] = []
	var remaining: Array[String] = []
	_list_existing_rel_files(stage_dir, stage_dir, remaining)
	var declared_after := {}
	declared_after[path_identity(MANIFEST_NAME)] = true
	declared_after[path_identity("native_evidence.json")] = true
	declared_after[path_identity("stage_provenance.json")] = true
	declared_after[path_identity("stage_cleanup_receipt.json")] = true
	for rel in remaining:
		if _is_backup_stage_path(rel):
			continue
		if not declared_after.has(path_identity(rel)):
			surviving_unknown.append(rel)
	var protected_backups: Array[String] = []
	for rel in remaining:
		if _is_backup_stage_path(rel):
			protected_backups.append(rel)
	if not surviving_unknown.is_empty() or not protected_backups.is_empty():
		var backup_hashes: Dictionary = {}
		for rel_b in protected_backups:
			backup_hashes[rel_b] = WorkspaceStore._md5_bytes(
				FileAccess.get_file_as_bytes(stage_dir.path_join(rel_b)))
		# A partial receipt must describe both retained classes honestly. The
		# foreign-file status is kept when foreign files survive so T-214's
		# receipt classifiers stay compatible; backup-only stages get their
		# own explicit status and both classes are listed in the payload.
		var receipt_status := "OWNED_FILES_REMOVED_FOREIGN_FILES_PRESERVED"
		if surviving_unknown.is_empty():
			receipt_status = "OWNED_FILES_REMOVED_BACKUPS_PRESERVED"
		var receipt := {
			"schema": 1,
			"status": receipt_status,
			"completed_at": Time.get_datetime_string_from_system(),
			"stage_root": stage_dir,
			"removed_files": results,
			"foreign_files_preserved": surviving_unknown,
			"protected_backups_preserved": protected_backups,
			"protected_backup_hashes": backup_hashes,
			"stage_directory_retained": true,
		}
		var receipt_path := stage_dir.path_join("stage_cleanup_receipt.json")
		receipt["stage_id"] = str(parsed.get("stage_id", ""))
		var evidence_result := _parse_json_safe(FileAccess.get_file_as_string(stage_dir.path_join("native_evidence.json")))
		var evidence_data = evidence_result.get("data", {})
		receipt["session_id"] = str(evidence_data.get("session_id", "")) if evidence_data is Dictionary else ""
		var provenance := _stage_provenance_snapshot(parsed, stage_dir)
		var receipt_payload := JSON.stringify(receipt, "  ").to_utf8_buffer()
		var prov_payload := JSON.stringify(provenance, "  ").to_utf8_buffer()
		# Test-only fault phases mirror WorkspaceStore.fault_phases; production
		# never sets these. They simulate a stale receipt and a failed write.
		var fault_receipt: bool = bool(WorkspaceStore.fault_phases.get("native_receipt_write", false))
		var fault_prov: bool = bool(WorkspaceStore.fault_phases.get("native_provenance_write", false))
		if fault_receipt and not FileAccess.file_exists(receipt_path):
			_write_stale_evidence(receipt_path)
		if fault_prov and not FileAccess.file_exists(stage_dir.path_join("stage_provenance.json")):
			_write_stale_evidence(stage_dir.path_join("stage_provenance.json"))
		var rw := WorkspaceStore.atomic_write_abs(receipt_path, receipt_payload) if not fault_receipt else {"ok": false}
		var pw := WorkspaceStore.atomic_write_abs(stage_dir.path_join("stage_provenance.json"), prov_payload) if not fault_prov else {"ok": false}
		# NPROV-01..04: existence alone proves nothing. Both artifacts must be
		# written successfully and read back byte-for-byte, and must carry the
		# current stage/session identity, before evidence can be claimed.
		var verify_fault: bool = bool(WorkspaceStore.fault_phases.get("native_receipt_verify", false))
		var receipt_ok := not verify_fault and bool(rw.get("ok", false)) and FileAccess.file_exists(receipt_path) and \
			WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(receipt_path)) == WorkspaceStore._md5_bytes(receipt_payload)
		var prov_ok := bool(pw.get("ok", false)) and FileAccess.file_exists(stage_dir.path_join("stage_provenance.json")) and \
			WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(stage_dir.path_join("stage_provenance.json"))) == WorkspaceStore._md5_bytes(prov_payload)
		if not receipt_ok or not prov_ok:
			var missing: Array[String] = []
			if not receipt_ok:
				missing.append("receipt")
			if not prov_ok:
				missing.append("provenance")
			return {
				"ok": true,
				"partial": true,
				"status": "CLEANUP_EVIDENCE_PENDING",
				"reason": "PROVENANCE_PERSISTENCE_FAILED",
				"stage": stage_dir,
				"removed": removed,
				"preserved": [],
				"rejected": [],
				"results": results,
				"foreign_files": surviving_unknown,
				"stage_directory_retained": true,
				"provenance_preserved": false,
				"evidence_failed": missing,
				"error": "durable cleanup evidence could not be verified: " + ", ".join(PackedStringArray(missing)),
			}
		var cleanup_status := "FOREIGN_FILES_PRESERVED"
		if surviving_unknown.is_empty() and not protected_backups.is_empty():
			cleanup_status = "CLEANUP_PARTIAL_BACKUPS_PRESERVED"
		return {
			"ok": true,
			"partial": true,
			"status": cleanup_status,
			"reason": "OWNED_FILES_REMOVED",
			"stage": stage_dir,
			"removed": removed,
			"preserved": [],
			"rejected": [],
			"results": results,
			"foreign_files": surviving_unknown,
			"protected_backups": protected_backups,
			"stage_directory_retained": true,
			"provenance_preserved": prov_ok,
			"receipt_verified": receipt_ok,
			"provenance_verified": prov_ok,
		}

	# The evidence artifact and the manifest are SHAMAN's own metadata; a full
	# clean removes them too so an owned stage leaves no orphan directory that
	# only exists to hold stale evidence (NC-39: empty stage dirs must go).
	DirAccess.remove_absolute(stage_dir.path_join("native_evidence.json"))
	DirAccess.remove_absolute(manifest_path)
	# T-223 / BAK-16..21: remove only a VERIFIED-EMPTY SHAMAN backup directory.
	# A nonempty backup remains protected by the partial branch above.
	var backup_dir := stage_dir.path_join(BACKUP_SUBDIR)
	var backup_dir_removed := true
	if DirAccess.dir_exists_absolute(backup_dir) and \
			_list_protected_backup_files(stage_dir).is_empty() and \
			_list_directory_entries(backup_dir).is_empty():
		backup_dir_removed = DirAccess.remove_absolute(backup_dir) == OK
	elif DirAccess.dir_exists_absolute(backup_dir):
		backup_dir_removed = false
	# Remove stage_dir itself only if completely empty (preserves unknown files!).
	var stage_root_removed := _remove_if_empty(stage_dir)
	if not backup_dir_removed or not stage_root_removed:
		return {
			"ok": true,
			"partial": true,
			"status": "CLEANUP_RETAINED_DIRECTORY",
			"reason": "EMPTY_BACKUP_DIRECTORY_REMOVAL_FAILED",
			"stage": stage_dir,
			"removed": removed,
			"preserved": [],
			"rejected": [],
			"results": results,
			"stage_directory_retained": true,
		}
	return {
		"ok": true,
		"partial": false,
		"status": "CLEAN",
		"reason": "",
		"stage": stage_dir,
		"removed": removed,
		"preserved": [],
		"rejected": [],
		"results": results,
	}


static func _write_stale_evidence(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string("{\"schema\":1,\"status\":\"STALE\"}")
		f.close()


## Durable provenance snapshot written when foreign files keep a stage
## directory alive after the owned files were removed. Reconciliation and
## inventory can then attribute survivors without the live manifest.
static func _stage_provenance_snapshot(manifest: Dictionary, stage_dir: String) -> Dictionary:
	return {
		"schema": 1,
		"stage_id": str(manifest.get("stage_id", "")),
		"stage_root": stage_dir,
		"recorded_at": Time.get_datetime_string_from_system(),
		"owned_files": manifest.get("files", []),
		"note": "owned files were removed; foreign files preserved; manifest content retained here",
	}


static func _prune_empty_parents(dir_path: String, stop_root: String) -> void:
	var cur := WorkspaceStore.canonical(dir_path)
	var stop := WorkspaceStore.canonical(stop_root)
	while cur != "" and cur != stop and WorkspaceStore.is_within(stop, cur):
		if not _remove_if_empty(cur):
			break
		cur = cur.get_base_dir()


## T-223: enumerate immediate entries of one directory, including nested
## directories, so an empty backup directory can be proven empty before removal.
static func _list_directory_entries(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		out.append("<unreadable>")
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n != "." and n != "..":
			out.append(n)
		n = d.get_next()
	d.list_dir_end()
	return out


static func _remove_if_empty(dir_path: String) -> bool:
	var d := DirAccess.open(dir_path)
	if d == null:
		return false
	d.list_dir_begin()
	var n := d.get_next()
	var empty := true
	while n != "":
		if n != "." and n != "..":
			empty = false
			break
		n = d.get_next()
	d.list_dir_end()
	if not empty:
		return false
	return DirAccess.remove_absolute(dir_path) == OK
