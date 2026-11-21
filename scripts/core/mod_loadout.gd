class_name ModLoadout
extends RefCounted
## Persistent project-scoped ModLoadout profile (Wave E / Section 18).
##
## Stores enabled Workshop packages, explicit priority order, per-filename
## explicit conflict winners, workspace override references, source file hashes,
## and native-test eligibility diagnostics.
##
## HONEST FIDELITY NOTE: editor priority order is an explicit editor resolution
## policy, NOT a claim of verified native BZCC addon mount order.

const SCHEMA_VERSION := 1
const EDITOR_POLICY_NOTE := "Editor resolution policy (explicit winners -> priority_order -> base game); not verified BZCC engine mount order."

var profile_id: String = "default"
var display_name: String = "Default Loadout"
var game_version: String = "UNKNOWN"
var enabled_packages: Array[String] = []
var priority_order: Array[String] = []
var explicit_resource_winners: Dictionary = {}  # filename.odf (lc) -> canonical absolute path
var workspace_overrides: Dictionary = {}        # canonical source path -> {rel, source_md5}
var source_hashes: Dictionary = {}              # canonical source path -> byte-exact MD5
var native_test_eligibility: Dictionary = {}
var updated_at: String = ""
var policy_note: String = EDITOR_POLICY_NOTE


static func loadouts_dir() -> String:
	return WorkspaceStore.root().path_join("loadouts")


static func _sanitize_id(raw_id: String) -> String:
	var s := raw_id.strip_edges().to_lower()
	var out := ""
	for i in s.length():
		var c := s.substr(i, 1)
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out += c
		elif c == " " or c == ".":
			out += "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.trim_prefix("_").trim_suffix("_")
	return out if out != "" else "loadout"


func effective_package_order() -> Array[String]:
	var enabled_set := {}
	for p in enabled_packages:
		var clean := str(p).strip_edges()
		if clean != "":
			enabled_set[clean] = true
	var out: Array[String] = []
	for p in priority_order:
		var clean := str(p).strip_edges()
		if clean != "" and (enabled_set.is_empty() or enabled_set.has(clean)) and not out.has(clean):
			out.append(clean)
	for p in enabled_packages:
		var clean := str(p).strip_edges()
		if clean != "" and not out.has(clean):
			out.append(clean)
	return out


func set_explicit_winner(resource_name: String, canonical_path: String) -> void:
	var key := resource_name.strip_edges().to_lower()
	if key == "":
		return
	if not key.ends_with(".odf"):
		key += ".odf"
	var canon := WorkspaceStore.canonical(canonical_path)
	if canon != "":
		explicit_resource_winners[key] = canon
		if FileAccess.file_exists(canon):
			source_hashes[canon] = WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(canon))


func clear_explicit_winner(resource_name: String) -> void:
	var key := resource_name.strip_edges().to_lower()
	if not key.ends_with(".odf"):
		key += ".odf"
	explicit_resource_winners.erase(key)


func to_dict() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"profile_id": profile_id,
		"display_name": display_name,
		"game_version": game_version,
		"enabled_packages": enabled_packages.duplicate(),
		"priority_order": priority_order.duplicate(),
		"explicit_resource_winners": explicit_resource_winners.duplicate(true),
		"workspace_overrides": workspace_overrides.duplicate(true),
		"source_hashes": source_hashes.duplicate(true),
		"native_test_eligibility": native_test_eligibility.duplicate(true),
		"updated_at": updated_at if updated_at != "" else Time.get_datetime_string_from_system(),
		"policy_note": policy_note,
	}


static func from_dict(d: Dictionary):
	var m = new()
	m.profile_id = _sanitize_id(str(d.get("profile_id", "default")))
	m.display_name = str(d.get("display_name", m.profile_id))
	m.game_version = str(d.get("game_version", "UNKNOWN"))
	m.enabled_packages.clear()
	for p in d.get("enabled_packages", []):
		var s := str(p).strip_edges()
		if s != "" and not m.enabled_packages.has(s):
			m.enabled_packages.append(s)
	m.priority_order.clear()
	for p in d.get("priority_order", []):
		var s := str(p).strip_edges()
		if s != "" and not m.priority_order.has(s):
			m.priority_order.append(s)
	var winners = d.get("explicit_resource_winners", {})
	if winners is Dictionary:
		for k in winners:
			m.explicit_resource_winners[str(k).to_lower()] = WorkspaceStore.canonical(str(winners[k]))
	var ws_ov = d.get("workspace_overrides", {})
	if ws_ov is Dictionary:
		m.workspace_overrides = ws_ov.duplicate(true)
	var sh = d.get("source_hashes", {})
	if sh is Dictionary:
		m.source_hashes = sh.duplicate(true)
	var elig = d.get("native_test_eligibility", {})
	if elig is Dictionary:
		m.native_test_eligibility = elig.duplicate(true)
	m.updated_at = str(d.get("updated_at", ""))
	m.policy_note = str(d.get("policy_note", EDITOR_POLICY_NOTE))
	return m


static func capture_from_index(p_id: String, index: ResourceIndex, p_display_name: String = "",
		p_game_version: String = "", p_enabled_pkgs: Array = [], p_winners: Dictionary = {}):
	var m = new()
	m.profile_id = _sanitize_id(p_id)
	m.display_name = p_display_name.strip_edges() if p_display_name.strip_edges() != "" else m.profile_id
	m.game_version = p_game_version if p_game_version != "" else "UNKNOWN"
	var pkgs_src: Array = p_enabled_pkgs if not p_enabled_pkgs.is_empty() else (index.active_packages.duplicate() if index != null else [])
	for p in pkgs_src:
		var s := str(p).strip_edges()
		if s != "" and s != "auto" and not m.enabled_packages.has(s):
			m.enabled_packages.append(s)
			m.priority_order.append(s)
	if not p_winners.is_empty():
		for k in p_winners:
			m.set_explicit_winner(str(k), str(p_winners[k]))
	elif index != null and not index.explicit_resource_winners.is_empty():
		for k in index.explicit_resource_winners:
			m.set_explicit_winner(str(k), str(index.explicit_resource_winners[k]))
	# Snapshot active workspace overrides and byte-exact source hashes.
	for rec in WorkspaceStore.entries():
		if rec is Dictionary:
			var sp := WorkspaceStore.canonical(str(rec.get("source", "")))
			if sp != "":
				m.workspace_overrides[sp] = {
					"rel": str(rec.get("rel", "")),
					"source_md5": str(rec.get("source_md5", "")),
				}
				if FileAccess.file_exists(sp):
					m.source_hashes[sp] = WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(sp))
	m.updated_at = Time.get_datetime_string_from_system()
	if index != null:
		m.native_test_eligibility = m.evaluate_native_eligibility(index)
	return m


## Analyze resource provenance, multi-package conflicts, explicit conflict winners,
## and missing dependencies against a live ResourceIndex.
func resolve_conflicts_report(index: ResourceIndex, check_names: Array = []) -> Dictionary:
	var conflicts: Array[Dictionary] = []
	var missing: Array[String] = []
	var provenance: Dictionary = {}
	if index == null:
		return {"ok": false, "conflicts": conflicts, "missing_dependencies": missing, "provenance": provenance}

	var order := effective_package_order()
	var keys_to_scan: Array[String] = []
	if not check_names.is_empty():
		for nm in check_names:
			var k := str(nm).strip_edges().to_lower()
			if k != "" and not k.ends_with(".odf"):
				k += ".odf"
			if k != "" and not keys_to_scan.has(k):
				keys_to_scan.append(k)
	else:
		# Scan explicit winners plus all ODFs that appear in >1 enabled package or base+package.
		for wk in explicit_resource_winners:
			keys_to_scan.append(str(wk).to_lower())
		for fkey in index.files:
			var flist: Array = index.files[fkey]
			if flist.size() > 1:
				var in_scope := 0
				for c in flist:
					var pkg := str(c.get("package", ""))
					if order.is_empty() or pkg == "" or order.has(pkg):
						in_scope += 1
				if in_scope > 1 and not keys_to_scan.has(str(fkey)):
					keys_to_scan.append(str(fkey))

	for key in keys_to_scan:
		var cands: Array[Dictionary] = index.candidates(key)
		if cands.is_empty():
			missing.append(key)
			continue
		var scoped: Array[Dictionary] = []
		for c in cands:
			var pkg := str(c.get("package", ""))
			if order.is_empty() or pkg == "" or order.has(pkg):
				scoped.append(c)
		if scoped.is_empty():
			scoped = cands
		var winner: Dictionary = {}
		var rule := "default"
		if explicit_resource_winners.has(key):
			var wanted := WorkspaceStore.canonical(str(explicit_resource_winners[key]))
			for c in cands:
				if WorkspaceStore._same_canon_path(str(c.get("path", "")), wanted):
					winner = c
					rule = "explicit_winner"
					break
			if winner.is_empty() and FileAccess.file_exists(wanted):
				winner = {"path": wanted, "package": index.package_of(wanted), "kind": "explicit"}
				rule = "explicit_winner_disk"
		if winner.is_empty() and not order.is_empty():
			for pkg in order:
				for c in scoped:
					if str(c.get("package", "")) == pkg:
						winner = c
						rule = "priority_order:" + pkg
						break
				if not winner.is_empty():
					break
		if winner.is_empty():
			for c in scoped:
				if str(c.get("kind", "")) == "game":
					winner = c
					rule = "base_game"
					break
		if winner.is_empty():
			winner = scoped[0]
			rule = "fallback"
		var wpath := WorkspaceStore.canonical(str(winner.get("path", "")))
		provenance[key] = {
			"winner_path": wpath,
			"package_id": str(winner.get("package", "")),
			"kind": str(winner.get("kind", "")),
			"rule": rule,
			"alternatives_count": scoped.size(),
		}
		if scoped.size() > 1:
			conflicts.append({
				"resource": key,
				"winner_path": wpath,
				"winner_package": str(winner.get("package", "")),
				"resolution_rule": rule,
				"explicitly_resolved": rule.begins_with("explicit_winner"),
				"candidates_count": scoped.size(),
			})

	return {
		"ok": missing.is_empty(),
		"profile_id": profile_id,
		"effective_packages": order,
		"conflicts_count": conflicts.size(),
		"conflicts": conflicts,
		"missing_dependencies": missing,
		"provenance": provenance,
		"policy_note": policy_note,
	}


func evaluate_native_eligibility(index: ResourceIndex, required_odfs: Array = []) -> Dictionary:
	var reasons: Array[String] = []
	var missing_pkgs: Array[String] = []
	var missing_winners: Array[String] = []
	var order := effective_package_order()

	if index != null:
		var indexed_pkgs := {}
		for fkey in index.files:
			for c in index.files[fkey]:
				var pk := str(c.get("package", ""))
				if pk != "":
					indexed_pkgs[pk] = true
		for ep in order:
			if not indexed_pkgs.has(ep):
				missing_pkgs.append(ep)
				reasons.append("ENABLED_PACKAGE_NOT_INDEXED:" + ep)

	for wk in explicit_resource_winners:
		var wp := str(explicit_resource_winners[wk])
		if wp == "" or not FileAccess.file_exists(wp):
			missing_winners.append(str(wk))
			reasons.append("EXPLICIT_WINNER_MISSING:" + str(wk))

	var rep := resolve_conflicts_report(index, required_odfs)
	var missing_deps: Array = rep.get("missing_dependencies", [])
	for md in missing_deps:
		reasons.append("MISSING_DEPENDENCY:" + str(md))

	var eligible := reasons.is_empty()
	var status := "ELIGIBLE" if eligible else "INELIGIBLE"
	return {
		"eligible": eligible,
		"status": status,
		"reasons": reasons,
		"missing_packages": missing_pkgs,
		"missing_winners": missing_winners,
		"missing_dependencies": missing_deps,
		"conflicts_count": int(rep.get("conflicts_count", 0)),
		"policy_note": policy_note,
	}


static func save_profile(profile) -> Dictionary:
	if profile == null:
		return {"ok": false, "error": "null profile"}
	profile.profile_id = _sanitize_id(profile.profile_id)
	profile.updated_at = Time.get_datetime_string_from_system()
	var dir_abs := ProjectSettings.globalize_path(loadouts_dir())
	DirAccess.make_dir_recursive_absolute(dir_abs)
	var target := dir_abs.path_join(profile.profile_id + ".json")
	var payload := JSON.stringify(profile.to_dict(), "  ").to_utf8_buffer()
	var wres := WorkspaceStore.atomic_write_abs(target, payload)
	if not bool(wres.get("ok", false)):
		return {"ok": false, "error": str(wres.get("error", "write failed")), "path": target}
	return {"ok": true, "profile_id": profile.profile_id, "path": target}


static func load_profile(p_id: String):
	var clean := _sanitize_id(p_id)
	var path := ProjectSettings.globalize_path(loadouts_dir().path_join(clean + ".json"))
	if not FileAccess.file_exists(path):
		return null
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(path))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return null
	return from_dict(jres.get("data", {}))


static func list_profiles() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir_abs := ProjectSettings.globalize_path(loadouts_dir())
	var dir := DirAccess.open(dir_abs)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.to_lower().ends_with(".json"):
			var full := dir_abs.path_join(n)
			var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(full))
			if bool(jres.get("ok", false)) and jres.get("data", null) is Dictionary:
				var d: Dictionary = jres.get("data", {})
				out.append({
					"profile_id": str(d.get("profile_id", n.get_basename())),
					"display_name": str(d.get("display_name", n.get_basename())),
					"enabled_packages": d.get("enabled_packages", []),
					"updated_at": str(d.get("updated_at", "")),
					"path": full,
				})
		n = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return str(a.profile_id) < str(b.profile_id))
	return out


static func delete_profile(p_id: String) -> bool:
	var clean := _sanitize_id(p_id)
	var path := ProjectSettings.globalize_path(loadouts_dir().path_join(clean + ".json"))
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK
