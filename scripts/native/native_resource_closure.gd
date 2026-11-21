class_name NativeResourceClosureBuilder
extends RefCounted
## Transitive resource closure analyzer for native BZCC experiments.
## Reuses ResourceIndex directly so Godot preview and native staging never use
## two conflicting ODF resolution algorithms. Distinguishes stage-owned
## overrides, base-game resources, Workshop resources, external dependencies,
## missing dependencies, and ambiguous Workshop sources.

const STATUS_COMPLETE := "RESOURCE_CLOSURE_COMPLETE"
const STATUS_PARTIAL := "RESOURCE_CLOSURE_PARTIAL"
const STATUS_AMBIGUOUS := "RESOURCE_AMBIGUOUS"
const STATUS_MISSING := "RESOURCE_MISSING"
const STATUS_MISSING_OR_DISABLED := "MISSING_OR_DISABLED_RESOURCE"
const STATUS_EXPLICIT_WINNER_DISABLED := "EXPLICIT_WINNER_DISABLED_PACKAGE"
const STATUS_COLLISION := "STAGING_RESOURCE_COLLISION"

const MAX_TRANSITIVE_DEPTH := 12
const MAX_AUTO_STAGE_FILES := 64

## ODF keys that reference child ODFs needed by BZCC when spawning or firing.
const ODF_DEP_KEYS := [
	"classlabel",
	"weaponname1", "weaponname2", "weaponname3", "weaponname4", "weaponname5",
	"ordname", "altname",
	"xplground", "xplvehicle", "xplbuilding", "xplchunk", "xplcrash", "xplexpire",
	"rendername", "flashname",
	"emitname",
]


static func _odf_key(name: String) -> String:
	var n := name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if n == "":
		return ""
	if n.contains("/") or n.contains("\\"):
		n = n.get_file()
	if n.contains("."):
		var ext := n.get_extension().to_lower()
		if ext != "odf":
			n = n.get_basename()
	if not n.to_lower().ends_with(".odf"):
		n += ".odf"
	return n.to_lower()


## Resolve an ODF name via ResourceIndex with explicit active Workshop package
## filtering, strict disabled-package exclusion (P1-01 / ML-04 / ML-05), and
## cross-package ambiguity detection.
static func resolve_odf_with_ambiguity(index: ResourceIndex, odf_ref: String,
		context_path: String = "", active_packages: Array[String] = [],
		strict_mode: bool = true, force_strict: bool = false) -> Dictionary:
	var key := _odf_key(odf_ref)
	if key == "" or index == null:
		return {"found": false, "ambiguous": false, "status": "RESOURCE_NOT_FOUND", "candidates": [], "selected": {}}
	var cands: Array[Dictionary] = index.candidates(key)
	if cands.is_empty() and not index.explicit_resource_winners.has(key):
		return {"found": false, "ambiguous": false, "status": "RESOURCE_NOT_FOUND", "candidates": [], "selected": {}}

	var use_strict := strict_mode and (force_strict or not active_packages.is_empty() or bool(index.strict_package_filter))

	# 0. Explicit ModLoadout resource conflict winner (identical identity across editor & native staging).
	if not index.explicit_resource_winners.is_empty() and index.explicit_resource_winners.has(key):
		var wanted_p := str(index.explicit_resource_winners[key])
		var matched_exp: Dictionary = {}
		for c in cands:
			if WorkspaceStore._same_canon_path(str(c.get("path", "")), wanted_p):
				matched_exp = c
				break
		if matched_exp.is_empty() and FileAccess.file_exists(wanted_p):
			var dpkg := index.package_of(wanted_p)
			matched_exp = {"path": wanted_p, "package": dpkg, "kind": "workshop" if dpkg != "" else "explicit"}
		if not matched_exp.is_empty():
			var wpkg := str(matched_exp.get("package", ""))
			var wkind := str(matched_exp.get("kind", ""))
			var is_disabled_ws := use_strict and (wkind == "workshop" or wpkg != "") and not active_packages.has(wpkg)
			if is_disabled_ws and not bool(index.allow_disabled_explicit_winners):
				return {
					"found": false,
					"ambiguous": false,
					"disabled_explicit_winner": true,
					"status": STATUS_EXPLICIT_WINNER_DISABLED,
					"reason": STATUS_EXPLICIT_WINNER_DISABLED,
					"blocked_packages": [wpkg],
					"candidates": cands,
					"selected": {},
					"rule": "explicit_winner_disabled",
				}
			return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": matched_exp, "rule": "explicit_loadout_winner"}

	# 1. Explicit active mod profile packages take precedence in declared order.
	if not active_packages.is_empty():
		for pkg in active_packages:
			for c in cands:
				if str(c.get("package", "")) == pkg:
					return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": c, "rule": "active_package:" + pkg}

	# 2. Same Workshop package as context document (ONLY if enabled under strict mode!).
	var ctx_pkg := index.package_of(context_path) if context_path != "" else ""
	if ctx_pkg != "" and (not use_strict or active_packages.has(ctx_pkg)):
		for c in cands:
			if str(c.get("package", "")) == ctx_pkg:
				return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": c, "rule": "context_package:" + ctx_pkg}

	# 3. Partition Workshop vs Base Game / Addon candidates.
	var workshop_pkgs: Dictionary = {}
	var disabled_pkgs: Array[String] = []
	var game_cand: Dictionary = {}
	var addon_cand: Dictionary = {}
	for c in cands:
		var kind := str(c.get("kind", ""))
		var wp := str(c.get("package", ""))
		if kind == "workshop" or wp != "":
			if not use_strict or active_packages.has(wp):
				if wp != "" and not workshop_pkgs.has(wp):
					workshop_pkgs[wp] = c
			else:
				if wp != "" and not disabled_pkgs.has(wp):
					disabled_pkgs.append(wp)
		elif kind == "game" and game_cand.is_empty():
			game_cand = c
		elif kind == "addon" and addon_cand.is_empty():
			addon_cand = c

	if not use_strict and workshop_pkgs.size() > 1 and active_packages.is_empty():
		var ws_paths: Array[String] = []
		for wp in workshop_pkgs:
			ws_paths.append(str((workshop_pkgs[wp] as Dictionary).get("path", "")))
		return {
			"found": true,
			"ambiguous": true,
			"status": STATUS_AMBIGUOUS,
			"candidates": cands,
			"workshop_packages": workshop_pkgs.keys(),
			"conflicting_paths": ws_paths,
			"selected": {},
			"rule": "ambiguous_workshop",
		}

	# 4. Base game / addon match (when base game fallback is enabled).
	if bool(index.allow_base_game_fallback):
		if not game_cand.is_empty() and (use_strict or workshop_pkgs.is_empty()):
			return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": game_cand, "rule": "base_game"}
		if not addon_cand.is_empty() and (use_strict or workshop_pkgs.is_empty()):
			return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": addon_cand, "rule": "addon"}

	# 5. Strict isolation: NEVER consume a disabled Workshop package!
	if use_strict:
		return {
			"found": false,
			"ambiguous": false,
			"disabled_only": not disabled_pkgs.is_empty(),
			"status": STATUS_MISSING_OR_DISABLED,
			"reason": STATUS_MISSING_OR_DISABLED,
			"blocked_packages": disabled_pkgs,
			"candidates": cands,
			"selected": {},
			"rule": "blocked_disabled_package",
		}

	if workshop_pkgs.size() == 1 and active_packages.is_empty() and game_cand.is_empty():
		var only_pkg := str(workshop_pkgs.keys()[0])
		return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": workshop_pkgs[only_pkg], "rule": "single_workshop:" + only_pkg}
	if not game_cand.is_empty():
		return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": game_cand, "rule": "base_game"}
	return {"found": true, "ambiguous": false, "status": "RESOLVED", "candidates": cands, "selected": cands[0], "rule": "highest_priority"}


## Build a full native resource closure report for a scenario.
## `spec` may contain:
##   shooter_odf, target_odf, weapon_odf, ordnance_odf (String names or paths)
##   staged_files: Dictionary (rel -> bytes/String)
##   mounted_workshop_packages: Array[String] (packages mounted in shaman_native.cfg)
##   active_packages: Array[String] (explicit mod loadout profile)
##   require_models: bool (default false for minimal headless damage probe, true for strict check)
static func build_closure(spec: Dictionary, index: ResourceIndex,
		discovery: Dictionary = {}) -> Dictionary:
	var staged_files: Dictionary = spec.get("staged_files", {})
	var mounted_pkgs: Array[String] = []
	for p in spec.get("mounted_workshop_packages", []):
		mounted_pkgs.append(str(p))
	var active_pkgs: Array[String] = []
	var has_explicit_pkgs := spec.has("active_packages")
	if has_explicit_pkgs:
		for p in spec.get("active_packages", []):
			var sp := str(p).strip_edges()
			if sp != "":
				active_pkgs.append(sp)
	elif index != null and not index.active_packages.is_empty():
		for ap in index.active_packages:
			active_pkgs.append(str(ap))
	var strict_native := true
	if index != null and has_explicit_pkgs and active_pkgs.is_empty():
		# Explicitly passed active_packages=[] means stock-only strict loadout!
		strict_native = true

	var game_root := WorkspaceStore.canonical(str(discovery.get("game_root", NativeTestAdapter.DEFAULT_GAME_ROOT)))
	var res_root := WorkspaceStore.canonical(str(discovery.get("res_root", game_root.path_join("bz2r_res"))))
	var check_base_disk := bool(spec.get("check_base_disk", true))

	# Index staged ODF filenames (lowercase) -> rel path
	var staged_odf_map: Dictionary = {}
	var staged_asset_map: Dictionary = {}
	for raw_rel in staged_files:
		var rel := str(raw_rel).replace("\\", "/")
		var fname := rel.get_file().to_lower()
		if fname.ends_with(".odf"):
			staged_odf_map[fname] = rel
		else:
			staged_asset_map[fname] = rel

	var stage_owned_overrides: Array[Dictionary] = []
	var base_game_resources: Array[Dictionary] = []
	var workshop_resources: Array[Dictionary] = []
	var unmounted_workshop_resources: Array[Dictionary] = []
	var external_dependencies: Array[Dictionary] = []
	var missing_dependencies: Array[Dictionary] = []
	var ambiguous_resources: Array[Dictionary] = []
	var staging_collisions: Array[Dictionary] = []
	var resource_identities: Array[Dictionary] = []
	var output_path_owners: Dictionary = {}  # "assets/odf/name.odf" -> canonical_source_path
	var model_refs: Array[Dictionary] = []
	var audio_refs: Array[Dictionary] = []
	var texture_refs: Array[Dictionary] = []

	# Check explicit staging collisions passed in spec ("staging_collisions" or duplicate output mappings).
	if spec.has("staging_sources") and spec.staging_sources is Array:
		var seen_out := {}
		for ssrc in spec.staging_sources:
			var sp := WorkspaceStore.canonical(str(ssrc))
			var fn := sp.get_file().to_lower()
			var out_rel := "assets/odf/" + fn
			if seen_out.has(out_rel) and str(seen_out[out_rel]) != sp:
				staging_collisions.append({
					"output_path": "assets/ODF/" + sp.get_file(),
					"first_source": str(seen_out[out_rel]),
					"second_source": sp,
					"reason": STATUS_COLLISION,
				})
			else:
				seen_out[out_rel] = sp

	var required_roles := [
		{"role": "shooter", "ref": str(spec.get("shooter_odf", "")), "missing_code": "MISSING_SHOOTER_ODF"},
		{"role": "target", "ref": str(spec.get("target_odf", "")), "missing_code": "MISSING_TARGET_ODF"},
		{"role": "weapon", "ref": str(spec.get("weapon_odf", "")), "missing_code": "MISSING_WEAPON_ODF"},
		{"role": "ordnance", "ref": str(spec.get("ordnance_odf", "")), "missing_code": "MISSING_ORDNANCE_ODF"},
	]

	var visited_odfs: Dictionary = {}
	var queue: Array[Dictionary] = []
	var primary_missing_reason := ""

	for item in required_roles:
		var ref := str(item.ref).strip_edges()
		if ref == "":
			missing_dependencies.append({
				"role": item.role,
				"name": "",
				"required": true,
				"reason": item.missing_code,
				"detail": "required %s ODF not specified" % item.role,
			})
			if primary_missing_reason == "":
				primary_missing_reason = str(item.missing_code)
			continue
		queue.append({
			"role": item.role,
			"ref": ref,
			"context": str(spec.get(item.role + "_path", "")),
			"required": true,
			"missing_code": item.missing_code,
			"depth": 0,
		})

	# Optional explicit explosion / particle references.
	for opt_key in ["explosion_odf", "particle_render_odf"]:
		var oref := str(spec.get(opt_key, "")).strip_edges()
		if oref != "":
			queue.append({
				"role": opt_key,
				"ref": oref,
				"context": str(spec.get("ordnance_path", "")),
				"required": false,
				"missing_code": "MISSING_" + opt_key.to_upper(),
				"depth": 0,
			})

	var all_resolved_odfs: Dictionary = {}

	while not queue.is_empty():
		var cur: Dictionary = queue.pop_front()
		var key := _odf_key(str(cur.ref))
		if key == "":
			continue
		var ctx := str(cur.get("context", ""))
		var depth := int(cur.get("depth", 0))
		var is_req := bool(cur.get("required", false))
		var role := str(cur.get("role", "transitive"))

		# 1. Check stage-owned overrides first (highest precedence in shaman_native.cfg).
		if staged_odf_map.has(key):
			var staged_visit_id := "staged:" + key
			if visited_odfs.has(staged_visit_id):
				continue
			visited_odfs[staged_visit_id] = true
			var srel := str(staged_odf_map[key])
			var sraw = staged_files.get(srel, staged_files.get(srel.trim_prefix("assets/"), ""))
			var sdoc := _parse_staged_odf(sraw, srel)
			var entry := {"role": role, "name": key, "rel": srel, "source": "stage_override", "required": is_req}
			stage_owned_overrides.append(entry)
			all_resolved_odfs[key] = entry
			if sdoc != null and depth < MAX_TRANSITIVE_DEPTH:
				_enqueue_odf_children(sdoc, ctx, depth + 1, is_req, queue, model_refs, audio_refs, texture_refs)
			continue

		# 2. Resolve through ResourceIndex (shared strict resolution with Godot preview; P1-01 / ML-04 / ML-05).
		var res := resolve_odf_with_ambiguity(index, key, ctx, active_pkgs, strict_native, has_explicit_pkgs)
		var res_status := str(res.get("status", ""))
		if res_status == STATUS_EXPLICIT_WINNER_DISABLED or res_status == STATUS_MISSING_OR_DISABLED:
			var blk_visit_id := "blk:" + key
			if visited_odfs.has(blk_visit_id):
				continue
			visited_odfs[blk_visit_id] = true
			if role == "classlabel" and not is_req:
				continue
			missing_dependencies.append({
				"role": role,
				"name": key,
				"required": is_req,
				"reason": res_status,
				"blocked_packages": res.get("blocked_packages", []),
				"detail": "ODF '%s' (%s) blocked by strict active loadout (%s; packages=%s)" % [key, role, res_status, str(res.get("blocked_packages", []))],
			})
			if is_req and primary_missing_reason == "":
				primary_missing_reason = res_status
			continue
		if bool(res.get("ambiguous", false)):
			var amb_visit_id := "amb:" + key
			if visited_odfs.has(amb_visit_id):
				continue
			visited_odfs[amb_visit_id] = true
			ambiguous_resources.append({
				"role": role,
				"name": key,
				"required": is_req,
				"packages": res.get("workshop_packages", []),
				"paths": res.get("conflicting_paths", []),
				"reason": "RESOURCE_AMBIGUOUS",
			})
			if is_req and primary_missing_reason == "":
				primary_missing_reason = "RESOURCE_AMBIGUOUS"
			continue

		var sel: Dictionary = res.get("selected", {})
		var disk_path := str(sel.get("path", ""))
		var kind := str(sel.get("kind", ""))
		var pkg := str(sel.get("package", ""))

		# Fallback direct check in stock bz2r_res when index is absent or stock-only probe.
		if disk_path == "" and check_base_disk and res_root != "" and DirAccess.dir_exists_absolute(res_root):
			var direct_hit := _find_in_dir_ci(res_root, key)
			if direct_hit != "":
				disk_path = direct_hit
				kind = "game"
				pkg = ""

		if disk_path == "" or not FileAccess.file_exists(disk_path):
			var miss_visit_id := "miss:" + key
			if visited_odfs.has(miss_visit_id):
				continue
			visited_odfs[miss_visit_id] = true
			# Ignore built-in C++ classLabels (e.g. "wingman", "cannon", "bullet", "scavenger")
			# that are engine class names rather than parent ODF filenames.
			if role == "classlabel" and not is_req:
				continue
			missing_dependencies.append({
				"role": role,
				"name": key,
				"required": is_req,
				"reason": str(cur.get("missing_code", "RESOURCE_MISSING")),
				"detail": "ODF '%s' (%s) not found in staged assets or indexed game/workshop roots" % [key, role],
			})
			if is_req and primary_missing_reason == "":
				primary_missing_reason = str(cur.get("missing_code", "RESOURCE_MISSING"))
			continue

		var canon_disk := WorkspaceStore.canonical(disk_path)
		var disk_visit_id := "disk:" + canon_disk.to_lower()
		if visited_odfs.has(disk_visit_id):
			continue
		visited_odfs[disk_visit_id] = true
		var out_key := "assets/odf/" + key
		if output_path_owners.has(out_key) and str(output_path_owners[out_key]).to_lower() != canon_disk.to_lower():
			staging_collisions.append({
				"role": role,
				"name": key,
				"output_path": "assets/ODF/" + key,
				"first_source": str(output_path_owners[out_key]),
				"second_source": canon_disk,
				"reason": STATUS_COLLISION,
			})
			if primary_missing_reason == "":
				primary_missing_reason = STATUS_COLLISION
		else:
			output_path_owners[out_key] = canon_disk

		var ident: Dictionary = index.resource_identity(sel, ctx) if index != null else {
			"canonical_source_path": canon_disk,
			"package_id": pkg,
			"relative_path": key,
			"filename": key,
			"content_hash": FileAccess.get_md5(disk_path),
			"workspace_revision": 0,
			"active_loadout_id": active_pkgs[0] if not active_pkgs.is_empty() else "auto",
		}
		resource_identities.append(ident)

		var rec := {
			"role": role,
			"name": key,
			"path": disk_path,
			"canonical_source_path": canon_disk,
			"identity": ident,
			"kind": kind,
			"package": pkg,
			"required": is_req,
			"mounted_in_native": false,
		}
		if kind == "game" or (res_root != "" and WorkspaceStore.is_within(res_root, disk_path)):
			rec["mounted_in_native"] = true
			base_game_resources.append(rec)
		elif kind == "workshop" or pkg != "":
			var pkg_mounted := mounted_pkgs.has(pkg)
			rec["mounted_in_native"] = pkg_mounted
			workshop_resources.append(rec)
			if not pkg_mounted:
				unmounted_workshop_resources.append(rec)
				var ws_req := is_req or bool(cur.get("workshop_required", false))
				if ws_req:
					missing_dependencies.append({
						"role": role,
						"name": key,
						"required": true,
						"package": pkg,
						"path": disk_path,
						"reason": "MISSING_WORKSHOP_PACKAGE",
						"detail": "Workshop ODF '%s' (package %s) is neither staged nor mounted in shaman_native.cfg" % [key, pkg],
					})
					if primary_missing_reason == "":
						primary_missing_reason = "MISSING_WORKSHOP_PACKAGE"
		else:
			external_dependencies.append(rec)
			if is_req:
				missing_dependencies.append({
					"role": role,
					"name": key,
					"required": true,
					"path": disk_path,
					"reason": "EXTERNAL_DEPENDENCY_UNSTAGED",
					"detail": "External ODF '%s' is outside bz2r_res and not staged" % key,
				})
				if primary_missing_reason == "":
					primary_missing_reason = "EXTERNAL_DEPENDENCY_UNSTAGED"

		all_resolved_odfs[key] = rec
		if depth < MAX_TRANSITIVE_DEPTH:
			var doc := OdfDocument.load_cached(disk_path)
			if doc != null:
				_enqueue_odf_children(doc, disk_path, depth + 1, is_req, queue, model_refs, audio_refs, texture_refs)

	# Resolve asset references (models, audio, textures) read-only for diagnostics.
	var missing_assets: Array[Dictionary] = []
	for mref in model_refs:
		var aname := str(mref.name)
		var found_m := staged_asset_map.has(aname.to_lower())
		if not found_m and index != null:
			var resolved_m := index.find_asset_near(aname, ["msh", "xsi", "fbx"], str(mref.context))
			found_m = resolved_m != ""
			mref["path"] = resolved_m
		mref["found"] = found_m
		if not found_m:
			missing_assets.append(mref)

	for sref in audio_refs:
		var aname2 := str(sref.name)
		var found_s := staged_asset_map.has(aname2.to_lower())
		if not found_s and index != null:
			var resolved_s := index.find_asset_near(aname2, ["wav", "ogg", "mp3"], str(sref.context))
			found_s = resolved_s != ""
			sref["path"] = resolved_s
		sref["asset_class"] = "AUDIO"
		sref["found"] = found_s
		if not found_s:
			missing_assets.append(sref)

	for tref in texture_refs:
		var aname3 := str(tref.name)
		var found_t := staged_asset_map.has(aname3.to_lower())
		if not found_t and index != null:
			var resolved_t := index.find_asset_near(aname3, ["dds", "tga", "png", "bmp", "jpg"], str(tref.context))
			found_t = resolved_t != ""
			tref["path"] = resolved_t
		tref["asset_class"] = "TEXTURE"
		tref["found"] = found_t
		if not found_t:
			missing_assets.append(tref)

	var req_missing := 0
	var opt_missing := 0
	for m in missing_dependencies:
		if bool(m.get("required", false)):
			req_missing += 1
		else:
			opt_missing += 1

	var status := STATUS_COMPLETE
	var closure_status := "COMPLETE"
	if not staging_collisions.is_empty():
		status = STATUS_COLLISION
		closure_status = "OUTPUT_PATH_COLLISION"
	elif not ambiguous_resources.is_empty():
		status = STATUS_AMBIGUOUS
		closure_status = "AMBIGUOUS_RESOURCE"
	elif req_missing > 0:
		status = STATUS_MISSING
		closure_status = "MISSING_REQUIRED_RESOURCE"
	elif opt_missing > 0 or not missing_assets.is_empty() or not unmounted_workshop_resources.is_empty():
		status = STATUS_PARTIAL
		closure_status = "PARTIAL_OPTIONAL_ASSETS"

	return {
		"ok": status == STATUS_COMPLETE or status == STATUS_PARTIAL,
		"strict_complete": status == STATUS_COMPLETE,
		"status": status,
		"closure_status": closure_status,
		"reason": "" if (status == STATUS_COMPLETE or status == STATUS_PARTIAL) else (primary_missing_reason if primary_missing_reason != "" else status),
		"stage_owned_overrides": stage_owned_overrides,
		"base_game_resources": base_game_resources,
		"workshop_resources": workshop_resources,
		"unmounted_workshop_resources": unmounted_workshop_resources,
		"external_dependencies": external_dependencies,
		"missing_dependencies": missing_dependencies,
		"missing_assets": missing_assets,
		"ambiguous_resources": ambiguous_resources,
		"staging_collisions": staging_collisions,
		"resource_identities": resource_identities,
		"models": model_refs,
		"sounds": audio_refs,
		"textures": texture_refs,
		"resolved_count": all_resolved_odfs.size(),
	}


## Collect minimal required staged ODF bytes for unmounted Workshop / override
## ODFs in a closure (bounded to MAX_AUTO_STAGE_FILES, never blindly copying
## an entire Workshop package).
static func build_minimal_staged_odfs(profile: WeaponProfile, index: ResourceIndex,
		discovery: Dictionary = {}, include_workshop_transitive: bool = true) -> Dictionary:
	var staged: Dictionary = {}
	if profile == null:
		return staged
	var docs_to_stage: Array = []
	for d in [profile.shooter_doc, profile.target_doc, profile.weapon_doc, profile.ordnance_doc]:
		if d != null and d.source_path != "":
			docs_to_stage.append(d)

	var res_root := WorkspaceStore.canonical(str(discovery.get("res_root", NativeTestAdapter.DEFAULT_GAME_ROOT + "/bz2r_res")))
	var seen: Dictionary = {}
	var queue: Array[String] = []

	for d in docs_to_stage:
		var spath: String = str(d.source_path)
		var fname: String = spath.get_file()
		var key: String = fname.to_lower()
		if seen.has(key):
			continue
		seen[key] = true
		var in_base := res_root != "" and WorkspaceStore.is_within(res_root, spath)
		if d.dirty or d.workspace_override or (include_workshop_transitive and not in_base):
			staged["assets/ODF/" + fname] = d.to_bytes()
		if include_workshop_transitive:
			_collect_parent_refs(d, spath, index, queue)

	while not queue.is_empty() and staged.size() < MAX_AUTO_STAGE_FILES:
		var next_path: String = queue.pop_front()
		var fname2 := next_path.get_file()
		var key2 := fname2.to_lower()
		if seen.has(key2):
			continue
		seen[key2] = true
		var in_base2 := res_root != "" and WorkspaceStore.is_within(res_root, next_path)
		var doc2 := OdfDocument.load_cached(next_path)
		if doc2 == null:
			continue
		if doc2.dirty or doc2.workspace_override or not in_base2:
			staged["assets/ODF/" + fname2] = doc2.to_bytes()
			_collect_parent_refs(doc2, next_path, index, queue)

	return staged


static func _collect_parent_refs(doc: OdfDocument, ctx_path: String, index: ResourceIndex, queue: Array[String]) -> void:
	if doc == null or index == null:
		return
	for e in doc.effective_entries():
		var kl := str(e.key_raw).to_lower()
		if ODF_DEP_KEYS.has(kl) or kl.begins_with("rendername"):
			var v := str(e.core_value()).strip_edges()
			if v == "":
				continue
			var p := index.resolve_path_from(v, ctx_path)
			if p != "" and FileAccess.file_exists(p):
				queue.append(p)


static func _parse_staged_odf(raw, rel: String) -> OdfDocument:
	var txt: String = (raw as PackedByteArray).get_string_from_utf8() if raw is PackedByteArray else str(raw)
	if txt.strip_edges() == "":
		return null
	return OdfDocument.parse_text(txt, rel)


static func _enqueue_odf_children(doc: OdfDocument, ctx: String, next_depth: int,
		parent_required: bool, queue: Array[Dictionary], model_refs: Array[Dictionary],
		audio_refs: Array[Dictionary], texture_refs: Array[Dictionary]) -> void:
	for e in doc.effective_entries():
		var kl := str(e.key_raw).to_lower()
		var v := str(e.core_value()).strip_edges()
		if v == "":
			continue
		if kl == "classlabel":
			# Note: engine built-in classLabels (wingman, cannon, bullet) are skipped if unresolved,
			# while real parent ODFs found in unmounted Workshop packages are flagged as required.
			queue.append({"role": "classlabel", "ref": v, "context": ctx, "required": false, "workshop_required": parent_required, "missing_code": "MISSING_PARENT_ODF", "depth": next_depth})
		elif kl == "ordname" or kl.begins_with("weaponname"):
			queue.append({"role": kl, "ref": v, "context": ctx, "required": parent_required, "workshop_required": parent_required, "missing_code": "MISSING_CHILD_ODF", "depth": next_depth})
		elif ODF_DEP_KEYS.has(kl) or kl.begins_with("rendername"):
			queue.append({"role": kl, "ref": v, "context": ctx, "required": false, "workshop_required": false, "missing_code": "MISSING_CHILD_ODF", "depth": next_depth})
		elif kl == "geometryname" or kl == "shotgeometry":
			model_refs.append({"key": kl, "name": v, "context": ctx})
		elif kl == "firesound" or kl == "shotsound" or kl == "explsound":
			audio_refs.append({"key": kl, "name": v, "context": ctx})
		elif kl == "texturename":
			texture_refs.append({"key": kl, "name": v, "context": ctx})


static func _find_in_dir_ci(dir_path: String, target_lower: String) -> String:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var n := dir.get_next()
	var subdirs: Array[String] = []
	while n != "":
		if n != "." and n != "..":
			var full := dir_path.path_join(n)
			if dir.current_is_dir():
				subdirs.append(full)
			elif n.to_lower() == target_lower:
				dir.list_dir_end()
				return full
		n = dir.get_next()
	dir.list_dir_end()
	for sub in subdirs:
		var hit := _find_in_dir_ci(sub, target_lower)
		if hit != "":
			return hit
	return ""
