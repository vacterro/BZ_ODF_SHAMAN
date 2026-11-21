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
	for item in files:
		if not (item is Dictionary):
			return {"ok": false, "reason": "INVALID_STAGE_MANIFEST", "error": "stage_manifest.json contains non-dict file entry"}
		var raw_rel := str(item.get("rel", ""))
		var clean := WorkspaceStore.clean_rel(raw_rel)
		if clean == "" or clean != raw_rel.replace("\\", "/").strip_edges():
			return {"ok": false, "reason": "TRAVERSAL_REJECTED", "error": "stage_manifest.json contains unsafe path: " + raw_rel}
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
				if n != BACKUP_SUBDIR:
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
				owned_files[str(item.get("rel", ""))] = str(item.get("md5", "")).to_lower()

	var existing_unknown: Dictionary = {}
	if DirAccess.dir_exists_absolute(stage_dir):
		var existing_list: Array[String] = []
		_list_existing_rel_files(stage_dir, stage_dir, existing_list)
		for rel_existing in existing_list:
			if rel_existing == MANIFEST_NAME or rel_existing == RECOVERY_MARKER_NAME:
				continue
			if not owned_files.has(rel_existing):
				existing_unknown[rel_existing] = true

	var conflict_strategy := str(options.get("conflict_strategy", "refuse")).strip_edges().to_lower()
	var planned: Array[Dictionary] = []
	var modified_conflicts: Array[Dictionary] = []
	var preserved_modified: Array[String] = []
	var explicit_backups_needed: Dictionary = {}

	for raw_rel in files:
		var safe := WorkspaceStore.clean_rel(str(raw_rel))
		if safe == "" or safe == MANIFEST_NAME or safe == RECOVERY_MARKER_NAME:
			return {"ok": false, "stage": stage_dir, "reason": "TRAVERSAL_REJECTED", "error": "unsafe staged path: " + str(raw_rel)}
		if existing_unknown.has(safe):
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
		if owned_files.has(safe) and FileAccess.file_exists(target):
			var expected_md5 := str(owned_files[safe]).to_lower()
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
	var staged_by_rel: Dictionary = {}
	for sitem in staged:
		staged_by_rel[str(sitem.rel)] = sitem
	var merged_files: Array[Dictionary] = staged.duplicate()
	for prev_rel in owned_files:
		if staged_by_rel.has(prev_rel):
			continue
		var prev_target := WorkspaceStore.canonical(stage_dir.path_join(prev_rel))
		if FileAccess.file_exists(prev_target):
			merged_files.append({
				"rel": prev_rel,
				"bytes": FileAccess.get_file_as_bytes(prev_target).size(),
				"md5": str(owned_files[prev_rel]),
			})

	var explicit_stage_id := str(options.get("stage_id", "")).strip_edges()
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

	DirAccess.remove_absolute(manifest_path)
	# Remove stage_dir itself only if completely empty (preserves unknown files!).
	_remove_if_empty(stage_dir)
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


static func _prune_empty_parents(dir_path: String, stop_root: String) -> void:
	var cur := WorkspaceStore.canonical(dir_path)
	var stop := WorkspaceStore.canonical(stop_root)
	while cur != "" and cur != stop and WorkspaceStore.is_within(stop, cur):
		if not _remove_if_empty(cur):
			break
		cur = cur.get_base_dir()


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
