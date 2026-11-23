class_name ResourceIndex
extends RefCounted
## Searchable index of ODFs and assets across configured roots.
## Precedence is configurable and every duplicate is retained so the UI can
## show the effective source plus alternatives. It does not guess silently.

signal scan_progress(done: int, label: String)
signal scan_finished(count: int)

const DEFAULT_GAME_ROOT := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R"
const DEFAULT_WORKSHOP_ROOT := "V:/__STORE_V/_SOFT/Steam/steamapps/workshop/content/624970"
const SETTINGS_PATH := "user://resource_roots.json"
const ASSET_EXTS := ["wav", "msh", "msha", "material", "dds", "tga", "png", "bmp", "fbx", "xsi", "ogg", "mp3", "jpg", "jpeg"]

const VSR_PACKAGE_IDS := ["1325933293", "3532748119"]
const VRV_PACKAGE_IDS := ["3820486276"]
const POLICY_STRICT_ACTIVE_LOADOUT := "STRICT_ACTIVE_LOADOUT"
const POLICY_EDITOR_PREVIEW_FALLBACK := "EDITOR_PREVIEW_FALLBACK"

const BUILTIN_STEM_NAMES := {
	"ivscav": "Scavenger", "fvscav": "Scavenger", "evscav": "Scavenger", "cvscav": "Scavenger",
	"ivtank": "Sabre", "fvtank": "Warrior", "fvptank": "Warrior", "evtank": "Xares", "cvtank": "Gorgon",
	"ivatank": "Attila", "fvatank": "Titan", "evatank": "Hedoux",
	"ivscout": "Scout", "fvscout": "Scout", "fvpscou": "Scout", "evscout": "locust", "cvscout": "Drone",
	"ivmbike": "Jackal", "ivmisl": "Avenger", "ivrckt": "Rocket Tank",
	"ivturr": "Turret", "fvturr": "Guardian", "fvpturr": "Guardian", "fvmturr": "Megaturret", "evturr": "oko",
	"ivwalk": "Walker", "fvwalk": "Mauler", "cvwalk": "Talon",
	"ivapc": "APC", "ivbomb": "Bomber", "ivintc": "Interceptor",
	"ivserv": "Service Truck", "fvserv": "Healer", "evserv": "Servitor",
	"ivcons": "Constructor", "fvcons": "Builder", "fvpcon": "Builder", "fvcos2": "Builder", "evcons": "Creator",
	"ivrecy": "Recycler", "fvrecy": "Matriarch", "fvrec2": "Matriarch", "evrecy": "Procreator",
	"ivdrop": "Dropship", "fvdrop": "Dropship", "ivtug": "Tug", "fvtug": "Hauler",
	"fvarch": "Lancer", "fvars2": "Lancer", "fvartl": "Archer",
	"fvsent": "Sentry", "fvpsnt": "Sentry", "fvsav": "Fury", "fvburn": "Burn",
	"ibrecy": "Recycler", "fbrecy": "Matriarch", "ibfact": "Factory", "fbfact": "Kiln",
	"ibpgen": "Power Generator", "fbpgen": "Lung", "ibcbun": "Relay Bunker", "fbantm": "Antenna Mound",
	"ibarmo": "Armory", "fbstro": "Stronghold", "ibsbay": "Service Bay", "fbdowe": "Dower",
	"ibtcen": "Tech Center", "fbover": "Overseer", "ibtrain": "Training Facility", "fbforg": "Forge",
	"ibgtow": "Gun Tower", "fbspir": "Gun Spire", "ibbomb": "Bomber Bay", "fbjas2": "Jas2",
	"ispilo": "ISDF Pilot", "fspilo": "Scion Pilot", "issold": "ISDF Soldier",
	"gatstab": "AT-Stabber", "atstab": "AT-Stabber", "gplasma": "Plasma Cannon",
	"gchain": "Chain Gun", "gminigun": "Minigun", "glaser": "Combat Laser",
	"gblast": "Blast Cannon", "gmagg": "MAG Cannon", "gsonic": "Sonic Gun",
	"garc": "Arc Cannon", "ggauss": "Gauss Gun", "gquill": "Quill",
	"gshadow": "Shadow Salvo", "ghornet": "Hornet", "gcomend": "FAF Missile",
	"gmdmgun": "Mortar", "gmortar": "Mortar", "gsplint": "Splinter",
}

var roots: Array[Dictionary] = []
var files: Dictionary = {}        # "name.odf" -> Array[Dictionary{path, root, rel, kind, priority, collection, mod_label, category}]
var assets_by_name: Dictionary = {}  # "texture.dds" -> Array[Dictionary{path, root, priority}]
var package_names: Dictionary = {}   # workshop_pkg_id -> display mod name
var extension_counts: Dictionary = {}
var total_files: int = 0
## Bumped on every scan so resolution caches can invalidate dependency-aware.
var generation: int = 0
var last_scan_msec: int = 0
var scanning: bool = false
var _cancel: bool = false
## Explicit active mod loadout packages in priority order (e.g. ["3532748119"]).
var active_packages: Array[String] = []
## Active persistent ModLoadout profile id and explicit per-ODF conflict winners.
var active_loadout_profile_id: String = ""
var explicit_resource_winners: Dictionary = {}  # filename.odf (lc) -> canonical path
## P1-01 / ML-01..ML-05: Strict loadout isolation policy & diagnostics.
var resolution_policy: String = POLICY_STRICT_ACTIVE_LOADOUT
var strict_package_filter: bool = false
var allow_base_game_fallback: bool = true
var allow_disabled_explicit_winners: bool = false
var last_resolution_diagnostics: Array[Dictionary] = []
var _game_name_cache: Dictionary = {}


func _init() -> void:
	load_settings()


func default_roots() -> Array[Dictionary]:
	return [
		{"path": DEFAULT_GAME_ROOT + "/bz2r_res", "label": "Base game (bz2r_res)", "kind": "game", "priority": 10, "enabled": true},
		{"path": DEFAULT_GAME_ROOT + "/addon", "label": "Addon (loose override)", "kind": "addon", "priority": 20, "enabled": true},
		{"path": DEFAULT_WORKSHOP_ROOT, "label": "Steam Workshop 624970", "kind": "workshop", "priority": 30, "enabled": true},
	]


func load_settings() -> void:
	roots.clear()
	var parsed = null
	if FileAccess.file_exists(SETTINGS_PATH):
		var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(SETTINGS_PATH))
		if bool(jres.get("ok", false)):
			parsed = jres.get("data", null)
	if parsed is Array and not parsed.is_empty():
		for r in parsed:
			if r is Dictionary and r.has("path"):
				roots.append(r)
	if roots.is_empty():
		roots = default_roots()


func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(roots, "  "))
		f.close()


func set_root_enabled(path: String, enabled: bool) -> void:
	for r in roots:
		if str(r.get("path", "")) == path:
			r["enabled"] = enabled


func add_root(path: String, label: String, kind: String, priority: int = 100) -> void:
	roots.append({"path": path, "label": label, "kind": kind, "priority": priority, "enabled": true})
	save_settings()


func available_roots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in roots:
		if bool(r.get("enabled", true)) and DirAccess.dir_exists_absolute(str(r.get("path", ""))):
			out.append(r)
	return out


func scan(include_workshop: bool = false) -> void:
	scanning = true
	_cancel = false
	generation += 1
	var t0 := Time.get_ticks_msec()
	files.clear()
	assets_by_name.clear()
	package_names.clear()
	extension_counts.clear()
	_game_name_cache.clear()
	total_files = 0
	# Scope is user_enabled AND runtime_allowed. Never mutate the saved root
	# flags to make a scan include something the user disabled.
	var enabled_roots: Array[Dictionary] = []
	for r in available_roots():
		if str(r.get("kind", "")) == "workshop" and not include_workshop:
			continue
		enabled_roots.append(r)
	for r in enabled_roots:
		var root_path := str(r.get("path", ""))
		if not DirAccess.dir_exists_absolute(root_path):
			continue
		if str(r.get("kind", "")) == "workshop":
			_discover_workshop_names(root_path)
		scan_progress.emit(total_files, str(r.get("label", root_path)))
		_scan_dir(root_path, root_path, r)
		if _cancel:
			break
	last_scan_msec = Time.get_ticks_msec() - t0
	scanning = false
	scan_finished.emit(total_files)


func _discover_workshop_names(ws_root: String) -> void:
	var dir := DirAccess.open(ws_root)
	if dir == null:
		return
	dir.list_dir_begin()
	var pkg := dir.get_next()
	while pkg != "":
		if dir.current_is_dir() and pkg != "." and pkg != "..":
			var pkg_dir := ws_root.path_join(pkg)
			package_names[pkg] = _read_workshop_mod_name(pkg_dir, pkg)
		pkg = dir.get_next()
	dir.list_dir_end()


func _read_workshop_mod_name(pkg_dir: String, pkg_id: String) -> String:
	for ini_name in [pkg_id + ".ini", "Mod.ini", "mod.ini"]:
		var ini_path := pkg_dir.path_join(ini_name)
		if not FileAccess.file_exists(ini_path):
			continue
		var txt := FileAccess.get_file_as_string(ini_path)
		var fallback_comment_name := ""
		for line in txt.split("\n"):
			var trimmed := line.strip_edges()
			var commented := trimmed.begins_with(";") or trimmed.begins_with("//")
			var clean := trimmed.trim_prefix(";").trim_prefix("//").strip_edges()
			var eq := clean.find("=")
			if eq <= 0:
				continue
			var k := clean.substr(0, eq).strip_edges().to_lower()
			var v := clean.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges()
			if k == "modname" and v != "":
				if not commented:
					return v
				elif fallback_comment_name == "":
					fallback_comment_name = v
		if fallback_comment_name != "":
			return fallback_comment_name
	# Fallback: first meaningful subfolder name
	var d := DirAccess.open(pkg_dir)
	if d != null:
		d.list_dir_begin()
		var sub := d.get_next()
		while sub != "":
			if d.current_is_dir() and sub != "." and sub != "..":
				var low := sub.to_lower()
				if low != "autoreg" and low != "config" and low != "addonassets" and low != "images" and low != "missions":
					d.list_dir_end()
					return sub
			sub = d.get_next()
		d.list_dir_end()
	return "Mod " + pkg_id


static func _classify_collection(kind: String, pkg_id: String, pkg_name: String, rel: String) -> String:
	if kind == "game":
		return "stock"
	if kind == "addon":
		return "addon"
	var p_low := pkg_name.to_lower()
	var r_low := rel.to_lower()
	if VRV_PACKAGE_IDS.has(pkg_id) or p_low.contains("vrv") or p_low.contains("vacuum recycler") or r_low.contains("/vrv/"):
		return "vrv"
	if VSR_PACKAGE_IDS.has(pkg_id) or p_low.contains("vsr") or p_low.contains("vet strat") or r_low.contains("recycler_variants"):
		return "vsr"
	return "mods"


static func _classify_category(rel: String, filename: String) -> String:
	var r := rel.replace("\\", "/").to_lower()
	var f := filename.to_lower().get_basename()
	if r.contains("/explos") or r.contains("/effects") or r.contains("/emitters") or r.contains("/particles") or f.begins_with("x"):
		return "Explosions / FX"
	if r.contains("/ordnance") or r.contains("/ammo"):
		return "Ordnance"
	if r.contains("/weapons") or r.contains("/cannons") or r.contains("/guns") or r.contains("/missiles") or r.contains("/mortars") or r.contains("/rockets") or r.contains("/mines") or r.contains("/specials"):
		if f.begins_with("g") or f.begins_with("ap"):
			return "Weapons"
		return "Ordnance"
	if r.contains("/vehicles") or r.contains("/craft") or r.contains("/ships"):
		return "Vehicles"
	if r.contains("/buildings") or r.contains("/structures") or r.contains("/turrets"):
		return "Buildings"
	if r.contains("/pilots") or r.contains("/powerups") or r.contains("/props") or r.contains("/trees"):
		return "Pilots & Props"
	# Filename heuristic fallback (BZ2/BZCC stock naming conventions)
	if f.begins_with("iv") or f.begins_with("fv") or f.begins_with("ev") or f.begins_with("cv") or f.begins_with("av"):
		return "Vehicles"
	if f.begins_with("ib") or f.begins_with("fb") or f.begins_with("eb") or f.begins_with("cb"):
		return "Buildings"
	if f.begins_with("g"):
		return "Weapons"
	if f.begins_with("ap"):
		return "Pilots & Props"
	if f.begins_with("ispilo") or f.begins_with("fspilo"):
		return "Pilots & Props"
	return "Other"


func _scan_dir(abs_dir: String, root_path: String, root: Dictionary) -> void:
	if _cancel:
		return
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if _cancel:
			break
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		var full := abs_dir.path_join(name)
		if dir.current_is_dir():
			_scan_dir(full, root_path, root)
		else:
			var ext := name.get_extension().to_lower()
			if ext == "odf":
				var rel := full.trim_prefix(root_path).trim_prefix("/")
				var key := name.to_lower()
				if not files.has(key):
					files[key] = []
				var kind := str(root.get("kind", "game"))
				var pkg := rel.get_slice("/", 0) if kind == "workshop" else ""
				var pkg_name := str(package_names.get(pkg, pkg)) if pkg != "" else ""
				var coll := _classify_collection(kind, pkg, pkg_name, rel)
				var mod_lbl := "Stock (BZ2R)"
				if kind == "addon":
					mod_lbl = "Addon"
				elif kind == "workshop":
					if coll == "vrv":
						mod_lbl = "VRV (%s)" % pkg
					elif coll == "vsr":
						mod_lbl = "VSR · %s (%s)" % [pkg_name if pkg_name != "" else "VSR", pkg]
					else:
						mod_lbl = "%s (%s)" % [pkg_name if pkg_name != "" else pkg, pkg]
				var cat := _classify_category(rel, name)
				files[key].append({
					"path": full,
					"root": str(root.get("label", root_path)),
					"kind": kind,
					"rel": rel,
					"package": pkg,
					"collection": coll,
					"mod_label": mod_lbl,
					"category": cat,
					"priority": int(root.get("priority", 10)),
				})
				extension_counts[ext] = int(extension_counts.get(ext, 0)) + 1
				total_files += 1
				if total_files % 500 == 0:
					scan_progress.emit(total_files, name)
			elif ASSET_EXTS.has(ext):
				var akey := name.to_lower()
				var arel := full.trim_prefix(root_path).trim_prefix("/")
				if not assets_by_name.has(akey):
					assets_by_name[akey] = []
				assets_by_name[akey].append({
					"path": full,
					"root": str(root.get("label", root_path)),
					"kind": str(root.get("kind", "game")),
					"package": arel.get_slice("/", 0) if str(root.get("kind", "")) == "workshop" else "",
					"priority": int(root.get("priority", 10)),
				})
				extension_counts[ext] = int(extension_counts.get(ext, 0)) + 1
		name = dir.get_next()
	dir.list_dir_end()


func cancel_scan() -> void:
	_cancel = true


func set_active_packages(pkgs: Array, strict: bool = true) -> void:
	active_packages.clear()
	for p in pkgs:
		var s := str(p).strip_edges()
		if s != "" and s != "auto" and s != "all" and s != "stock" and s != "base" and not active_packages.has(s):
			active_packages.append(s)
	strict_package_filter = strict
	last_resolution_diagnostics.clear()
	generation += 1


func set_active_package(pkg_id: String) -> void:
	var s := pkg_id.strip_edges()
	var low := s.to_lower()
	active_loadout_profile_id = ""
	explicit_resource_winners.clear()
	resolution_policy = POLICY_STRICT_ACTIVE_LOADOUT
	allow_base_game_fallback = true
	allow_disabled_explicit_winners = false
	if s == "" or low == "all" or low == "auto":
		set_active_packages([], false)
	elif low == "stock" or low == "base" or low == "none":
		set_active_packages([], true)
	else:
		set_active_packages([s], true)


## Apply a persistent ModLoadout profile (enabled packages, priority order,
## resolution policy, and explicit per-ODF conflict winners) so editor, labs,
## and native staging share the exact same effective resource identity.
func apply_loadout(loadout) -> Dictionary:
	if loadout == null:
		return {"ok": false, "error": "null loadout"}
	active_loadout_profile_id = str(loadout.profile_id)
	var pol := str(loadout.resolution_policy).strip_edges()
	resolution_policy = pol if (pol == POLICY_STRICT_ACTIVE_LOADOUT or pol == POLICY_EDITOR_PREVIEW_FALLBACK) else POLICY_STRICT_ACTIVE_LOADOUT
	allow_base_game_fallback = bool(loadout.allow_base_game_fallback)
	allow_disabled_explicit_winners = bool(loadout.allow_disabled_explicit_winners)
	explicit_resource_winners.clear()
	for k in loadout.explicit_resource_winners:
		explicit_resource_winners[str(k).to_lower()] = WorkspaceStore.canonical(str(loadout.explicit_resource_winners[k]))
	# Explicit ModLoadout ALWAYS enables strict package filtering (even if enabled_packages == []).
	set_active_packages(loadout.effective_package_order(), true)
	return {
		"ok": true,
		"profile_id": active_loadout_profile_id,
		"resolution_policy": resolution_policy,
		"strict_package_filter": strict_package_filter,
		"active_packages": active_packages.duplicate(),
		"explicit_winners": explicit_resource_winners.size(),
	}


## Build a canonical source-aware ResourceIdentity dictionary (P0-03).
func resource_identity(path_or_entry, context_path: String = "") -> Dictionary:
	var rec: Dictionary = {}
	var disk_path := ""
	if path_or_entry is Dictionary:
		rec = path_or_entry
		disk_path = str(rec.get("path", ""))
	else:
		var s := str(path_or_entry).strip_edges()
		if s.contains("/") or s.contains("\\") or FileAccess.file_exists(s):
			disk_path = s
		else:
			rec = resolve_from(s, context_path)
			disk_path = str(rec.get("path", ""))
	var canon := WorkspaceStore.canonical(disk_path) if disk_path != "" else ""
	var fname := canon.get_file() if canon != "" else str(path_or_entry).get_file()
	var pkg := str(rec.get("package", "")) if not rec.is_empty() else (package_of(canon) if canon != "" else "")
	var rel := str(rec.get("rel", fname)) if not rec.is_empty() else fname
	var rev := 0
	var chash := ""
	if canon != "":
		var cached_doc = OdfDocument.cached(canon)
		if cached_doc != null:
			rev = int(cached_doc.revision)
			chash = WorkspaceStore._md5_bytes(cached_doc.to_bytes())
		elif FileAccess.file_exists(canon):
			chash = WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(canon))
	return {
		"canonical_source_path": canon,
		"package_id": pkg,
		"relative_path": rel,
		"filename": fname.to_lower(),
		"content_hash": chash,
		"workspace_revision": rev,
		"active_loadout_id": active_packages[0] if not active_packages.is_empty() else "auto",
	}


## Resolve human-readable in-game name (unitName / wpnName, e.g. ivscav -> "Scavenger",
## ivtank -> "Sabre") from the ODF or its baseName/classLabel inheritance chain.
func get_game_name(path_or_ref: String) -> String:
	var raw := path_or_ref.strip_edges()
	if raw == "":
		return ""
	var path := raw
	if not (raw.contains("/") or raw.contains("\\")):
		path = resolve_path(raw)
	var cache_key := path.to_lower() if path != "" else raw.to_lower()
	if _game_name_cache.has(cache_key):
		return str(_game_name_cache[cache_key])

	var visited := {}
	var cur_path := path
	for _hop in range(4):
		if cur_path == "" or visited.has(cur_path.to_lower()) or not FileAccess.file_exists(cur_path):
			break
		visited[cur_path.to_lower()] = true
		var info := _extract_quick_odf_names(cur_path)
		var uname := str(info.get("name", ""))
		if uname != "":
			var stem_low := raw.get_file().get_basename().to_lower()
			if (stem_low.begins_with("fvscav") or stem_low.begins_with("ivscav")) and (uname == "Harvester" or uname == "Distributor"):
				uname = "Scavenger"
			_game_name_cache[cache_key] = uname
			return uname
		var parent_ref := str(info.get("parent", ""))
		if parent_ref == "":
			break
		cur_path = resolve_path_from(parent_ref, cur_path)

	var stem_fb := _stem_fallback_name(raw.get_file().get_basename())
	_game_name_cache[cache_key] = stem_fb
	return stem_fb


static func _stem_fallback_name(stem_raw: String) -> String:
	var stem := stem_raw.to_lower()
	for k in ["_vsr", "_vrv", "_m", "_mb", "cpu", "dm", "s03", "s04", "13", "10x", "_c", "_a", "00"]:
		if stem.ends_with(k) and stem.length() > k.length() + 3:
			stem = stem.substr(0, stem.length() - k.length())
	if BUILTIN_STEM_NAMES.has(stem):
		return str(BUILTIN_STEM_NAMES[stem])
	for prefix in BUILTIN_STEM_NAMES:
		if stem.begins_with(prefix):
			return str(BUILTIN_STEM_NAMES[prefix])
	return ""


static func _extract_quick_odf_names(path: String) -> Dictionary:
	var cached_doc = OdfDocument.cached(path)
	if cached_doc != null:
		for key_pair in [["GameObjectClass", "unitName"], ["WeaponClass", "wpnName"]]:
			var v: String = str(cached_doc.get_value(key_pair[0], key_pair[1], "")).strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges()
			if v != "":
				return {"name": v, "parent": ""}
		var b: String = str(cached_doc.get_value("GameObjectClass", "baseName", "")).strip_edges().trim_prefix("\"").trim_suffix("\"")
		if b == "":
			b = str(cached_doc.get_value("GameObjectClass", "classLabel", "")).strip_edges().trim_prefix("\"").trim_suffix("\"")
		if b == "":
			b = str(cached_doc.get_value("WeaponClass", "classLabel", "")).strip_edges().trim_prefix("\"").trim_suffix("\"")
		if b == "":
			b = str(cached_doc.get_value("OrdnanceClass", "classLabel", "")).strip_edges().trim_prefix("\"").trim_suffix("\"")
		return {"name": "", "parent": b}

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"name": "", "parent": ""}
	var chunk := f.get_buffer(mini(2048, int(f.get_length()))).get_string_from_ascii()
	f.close()
	var unit_name := ""
	var wpn_name := ""
	var base_name := ""
	var class_label := ""
	for raw_line in chunk.split("\n"):
		var line := raw_line.strip_edges()
		if line == "" or line.begins_with("//") or line.begins_with(";") or line.begins_with("["):
			continue
		var eq := line.find("=")
		if eq <= 0:
			continue
		var k := line.substr(0, eq).strip_edges().to_lower()
		if k != "unitname" and k != "wpnname" and k != "basename" and k != "classlabel":
			continue
		var val := line.substr(eq + 1).strip_edges()
		var sc := val.find("//")
		if sc >= 0:
			val = val.substr(0, sc).strip_edges()
		val = val.trim_prefix("\"").trim_suffix("\"").strip_edges()
		if val == "":
			continue
		if k == "unitname":
			unit_name = val
			break
		elif k == "wpnname":
			wpn_name = val
		elif k == "basename":
			base_name = val
		elif k == "classlabel":
			class_label = val
	var best_name := unit_name if unit_name != "" else wpn_name
	var best_parent := base_name if base_name != "" else class_label
	return {"name": best_name, "parent": best_parent}


## All candidates for a reference, highest precedence first.
func candidates(name: String) -> Array[Dictionary]:
	var key := name.to_lower()
	if not key.ends_with(".odf"):
		key += ".odf"
	var list: Array = files.get(key, [])
	var out: Array[Dictionary] = []
	for c in list:
		out.append(c)
	out.sort_custom(func(a, b):
		var pa := str(a.get("package", ""))
		var pb := str(b.get("package", ""))
		var ia := active_packages.find(pa) if pa != "" else -1
		var ib := active_packages.find(pb) if pb != "" else -1
		if ia >= 0 and ib < 0:
			return true
		if ib >= 0 and ia < 0:
			return false
		if ia >= 0 and ib >= 0 and ia != ib:
			return ia < ib
		if int(a.priority) == int(b.priority):
			return str(a.path) < str(b.path)
		return int(a.priority) > int(b.priority)
	)
	return out


func _record_resolution_diagnostic(diag: Dictionary) -> void:
	if last_resolution_diagnostics.size() >= 100:
		last_resolution_diagnostics.pop_front()
	last_resolution_diagnostics.append(diag)


## Canonical policy-aware ODF resolution (P1-01 / ML-01..ML-05).
## Under STRICT_ACTIVE_LOADOUT (default for explicit loadouts & native):
##   - Disabled Workshop packages are NEVER silently substituted.
##   - Explicit winners pointing to disabled packages emit EXPLICIT_WINNER_DISABLED_PACKAGE.
## Under EDITOR_PREVIEW_FALLBACK:
##   - Fallback to a disabled package is allowed ONLY with explicit status
##     RESOLVED_WITH_PREVIEW_FALLBACK and non-empty provenance warning.
func resolve_ex(name: String, context_path: String = "", policy_override: String = "",
		active_pkgs_override = null) -> Dictionary:
	var clean := _clean_ref(name)
	var lck := clean.to_lower()
	var eff_policy := policy_override.strip_edges() if policy_override.strip_edges() != "" else resolution_policy
	if eff_policy != POLICY_STRICT_ACTIVE_LOADOUT and eff_policy != POLICY_EDITOR_PREVIEW_FALLBACK:
		eff_policy = POLICY_STRICT_ACTIVE_LOADOUT
	var use_strict := strict_package_filter or (not active_packages.is_empty()) or (active_pkgs_override is Array)
	var eff_pkgs: Array[String] = []
	if active_pkgs_override is Array:
		for p in active_pkgs_override:
			var sp := str(p).strip_edges()
			if sp != "" and not eff_pkgs.has(sp):
				eff_pkgs.append(sp)
	else:
		eff_pkgs = active_packages.duplicate()

	var list := candidates(clean)
	if list.is_empty() and not explicit_resource_winners.has(lck):
		return {
			"found": false,
			"entry": {},
			"path": "",
			"package": "",
			"kind": "",
			"rule": "not_found",
			"status": "RESOURCE_NOT_FOUND",
			"warning": "",
			"blocked_disabled_packages": [],
			"policy": eff_policy,
		}

	# 0. Explicit per-ODF conflict winner check (ML-03).
	if explicit_resource_winners.has(lck):
		var wanted := str(explicit_resource_winners[lck])
		var matched: Dictionary = {}
		for c in list:
			if WorkspaceStore._same_canon_path(str(c.get("path", "")), wanted):
				matched = c
				break
		if matched.is_empty() and FileAccess.file_exists(wanted):
			var dpkg := package_of(wanted)
			matched = {"path": wanted, "package": dpkg, "kind": "workshop" if dpkg != "" else "explicit"}
		if not matched.is_empty():
			var wpkg := str(matched.get("package", ""))
			var wkind := str(matched.get("kind", ""))
			var is_disabled_ws := use_strict and (wkind == "workshop" or wpkg != "") and not eff_pkgs.has(wpkg)
			if is_disabled_ws and not allow_disabled_explicit_winners:
				var warn_dw := "Explicit winner '%s' belongs to disabled Workshop package '%s'" % [lck, wpkg]
				_record_resolution_diagnostic({
					"resource": lck,
					"status": "EXPLICIT_WINNER_DISABLED_PACKAGE",
					"package": wpkg,
					"path": wanted,
					"policy": eff_policy,
					"warning": warn_dw,
				})
				if eff_policy == POLICY_STRICT_ACTIVE_LOADOUT:
					return {
						"found": false,
						"entry": {},
						"path": "",
						"package": wpkg,
						"kind": wkind,
						"rule": "explicit_winner_disabled",
						"status": "EXPLICIT_WINNER_DISABLED_PACKAGE",
						"warning": warn_dw,
						"blocked_disabled_packages": [wpkg],
						"policy": eff_policy,
					}
				return {
					"found": true,
					"entry": matched,
					"path": str(matched.get("path", "")),
					"package": wpkg,
					"kind": wkind,
					"rule": "explicit_winner_disabled_fallback",
					"status": "RESOLVED_WITH_PREVIEW_FALLBACK",
					"warning": warn_dw + " (allowed via EDITOR_PREVIEW_FALLBACK)",
					"blocked_disabled_packages": [wpkg],
					"policy": eff_policy,
				}
			return {
				"found": true,
				"entry": matched,
				"path": str(matched.get("path", "")),
				"package": wpkg,
				"kind": wkind,
				"rule": "explicit_winner",
				"status": "RESOLVED",
				"warning": "",
				"blocked_disabled_packages": [],
				"policy": eff_policy,
			}

	# 1. Partition candidates into allowed vs disabled Workshop vs base game / addon.
	var allowed_ws: Array[Dictionary] = []
	var disabled_ws: Array[Dictionary] = []
	var blocked_pkgs: Array[String] = []
	var base_game: Array[Dictionary] = []
	var addon_list: Array[Dictionary] = []
	var other_list: Array[Dictionary] = []
	for c in list:
		var kind := str(c.get("kind", ""))
		var cpkg := str(c.get("package", ""))
		if kind == "workshop" or cpkg != "":
			if not use_strict or eff_pkgs.has(cpkg):
				allowed_ws.append(c)
			else:
				disabled_ws.append(c)
				if cpkg != "" and not blocked_pkgs.has(cpkg):
					blocked_pkgs.append(cpkg)
		elif kind == "game":
			base_game.append(c)
		elif kind == "addon":
			addon_list.append(c)
		else:
			other_list.append(c)

	# 2. Active package priority order.
	if not eff_pkgs.is_empty():
		for ap in eff_pkgs:
			for c in allowed_ws:
				if str(c.get("package", "")) == ap:
					return {
						"found": true, "entry": c, "path": str(c.get("path", "")),
						"package": ap, "kind": str(c.get("kind", "")),
						"rule": "active_package:" + ap, "status": "RESOLVED",
						"warning": "", "blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
					}

	# 3. Same Workshop package as context document (ONLY when not disabled under strict filter!).
	var ctx_pkg := package_of(context_path) if context_path != "" else ""
	if ctx_pkg != "" and (not use_strict or eff_pkgs.has(ctx_pkg)):
		for c in allowed_ws:
			if str(c.get("package", "")) == ctx_pkg:
				return {
					"found": true, "entry": c, "path": str(c.get("path", "")),
					"package": ctx_pkg, "kind": str(c.get("kind", "")),
					"rule": "context_package:" + ctx_pkg, "status": "RESOLVED",
					"warning": "", "blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
				}

	# 4. Base game / addon / custom non-workshop roots.
	if allow_base_game_fallback:
		if not base_game.is_empty():
			var bg: Dictionary = base_game[0]
			return {
				"found": true, "entry": bg, "path": str(bg.get("path", "")),
				"package": "", "kind": "game", "rule": "base_game", "status": "RESOLVED",
				"warning": "", "blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
			}
		if not addon_list.is_empty():
			var ad: Dictionary = addon_list[0]
			return {
				"found": true, "entry": ad, "path": str(ad.get("path", "")),
				"package": "", "kind": "addon", "rule": "addon", "status": "RESOLVED",
				"warning": "", "blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
			}
		if not other_list.is_empty():
			var ot: Dictionary = other_list[0]
			return {
				"found": true, "entry": ot, "path": str(ot.get("path", "")),
				"package": "", "kind": str(ot.get("kind", "")), "rule": "other_root", "status": "RESOLVED",
				"warning": "", "blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
			}

	# 5. Unscoped Auto mode (all Workshop packages enabled).
	if not use_strict and not allowed_ws.is_empty():
		var aw: Dictionary = allowed_ws[0]
		return {
			"found": true, "entry": aw, "path": str(aw.get("path", "")),
			"package": str(aw.get("package", "")), "kind": str(aw.get("kind", "")),
			"rule": "auto_workshop", "status": "RESOLVED",
			"warning": "", "blocked_disabled_packages": [], "policy": eff_policy,
		}

	# 6. Only disabled Workshop candidates remain: strict block OR explicit provenance-warned preview fallback.
	if not disabled_ws.is_empty():
		if eff_policy == POLICY_EDITOR_PREVIEW_FALLBACK:
			var fb: Dictionary = disabled_ws[0]
			var fb_pkg := str(fb.get("package", ""))
			var fb_warn := "Resource '%s' not in active loadout; using disabled package '%s' via EDITOR_PREVIEW_FALLBACK" % [lck, fb_pkg]
			_record_resolution_diagnostic({
				"resource": lck,
				"status": "RESOLVED_WITH_PREVIEW_FALLBACK",
				"package": fb_pkg,
				"path": str(fb.get("path", "")),
				"policy": eff_policy,
				"warning": fb_warn,
			})
			return {
				"found": true, "entry": fb, "path": str(fb.get("path", "")),
				"package": fb_pkg, "kind": str(fb.get("kind", "")),
				"rule": "editor_preview_fallback", "status": "RESOLVED_WITH_PREVIEW_FALLBACK",
				"warning": fb_warn, "blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
			}
		var blk_warn := "Resource '%s' only exists in disabled Workshop package(s): %s" % [lck, ", ".join(blocked_pkgs)]
		_record_resolution_diagnostic({
			"resource": lck,
			"status": "MISSING_OR_DISABLED_RESOURCE",
			"blocked_packages": blocked_pkgs,
			"policy": eff_policy,
			"warning": blk_warn,
		})
		return {
			"found": false, "entry": {}, "path": "", "package": "", "kind": "",
			"rule": "blocked_disabled_package", "status": "MISSING_OR_DISABLED_RESOURCE",
			"warning": blk_warn, "blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
		}

	return {
		"found": false, "entry": {}, "path": "", "package": "", "kind": "",
		"rule": "base_game_fallback_disabled", "status": "MISSING_OR_DISABLED_RESOURCE",
		"warning": "Base game fallback disabled and no enabled package provides '%s'" % lck,
		"blocked_disabled_packages": blocked_pkgs, "policy": eff_policy,
	}


func resolve(name: String) -> Dictionary:
	return resolve_ex(name, "").get("entry", {})


func resolve_path(name: String) -> String:
	var hit := resolve_ex(name, "")
	return str(hit.get("path", "")) if bool(hit.get("found", false)) else ""


## Context-aware resolution used by dependency and inheritance chains.
## Delegates to resolve_ex() so editor, labs, and native staging enforce one
## consistent strict loadout policy.
func resolve_from(name: String, context_path: String) -> Dictionary:
	return resolve_ex(name, context_path).get("entry", {})


func resolve_path_from(name: String, context_path: String) -> String:
	var hit := resolve_ex(name, context_path)
	return str(hit.get("path", "")) if bool(hit.get("found", false)) else ""


func package_of(path: String) -> String:
	var p := path.replace("\\", "/")
	for r in roots:
		if str(r.get("kind", "")) != "workshop":
			continue
		var root := str(r.get("path", "")).replace("\\", "/")
		if p.begins_with(root):
			return p.trim_prefix(root).trim_prefix("/").get_slice("/", 0)
	return ""


func alternatives(name: String) -> Array[Dictionary]:
	return candidates(_clean_ref(name))


func _clean_ref(name: String) -> String:
	var n := name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if n.contains("."):
		var ext := n.get_extension().to_lower()
		if ext != "odf":
			# Render refs are "file.header".
			n = n.get_basename()
	if not n.ends_with(".odf"):
		n += ".odf"
	return n


## Ranked search over indexed ODF file names. Every whitespace-separated token
## must match; an exact/prefix/substring hit outranks a subsequence hit ("ivtk"
## still finds ivtank_vsr.odf). Ties are ordered by path, so results are stable.
func search(query: String, limit: int = 500) -> Array[Dictionary]:
	var q := query.strip_edges().to_lower()
	var out: Array[Dictionary] = []
	if q == "":
		var keys := files.keys()
		keys.sort()
		for key in keys:
			var list: Array = files[key]
			if not list.is_empty():
				out.append(list[0])
				if out.size() >= limit:
					break
		return out
	var tokens := q.split(" ", false)
	var scored: Array[Dictionary] = []
	for key in files:
		var name := str(key)
		var total := 0
		var matched := true
		for t in tokens:
			var s := _token_score(name, str(t))
			if s <= 0:
				matched = false
				break
			total += s
		if not matched:
			continue
		var list: Array = files[key]
		if list.is_empty():
			continue
		var row: Dictionary = list[0].duplicate()
		row["match_score"] = total
		scored.append(row)
	scored.sort_custom(func(a, b):
		if int(a.match_score) != int(b.match_score):
			return int(a.match_score) > int(b.match_score)
		return str(a.path) < str(b.path)
	)
	return scored.slice(0, mini(limit, scored.size()))


func _token_score(name: String, token: String) -> int:
	if token == "":
		return 0
	if name.get_basename() == token or name == token:
		return 9000
	if name.begins_with(token):
		return 8000 - name.length()
	var idx := name.find(token)
	if idx >= 0:
		return 6000 - idx * 20 - name.length()
	# Subsequence fallback: characters in order, with a bonus for runs and for
	# starting a word. Reject if any character is missing.
	var pos := 0
	var run := 0
	var score := 1000
	for i in name.length():
		var ch := name.substr(i, 1)
		if pos < token.length() and ch == token.substr(pos, 1):
			score += 10 + run * 5
			var prev := "" if i == 0 else name.substr(i - 1, 1)
			if i == 0 or prev == "_" or prev == "-" or prev == "." or prev == "/":
				score += 30
			run += 1
			pos += 1
		else:
			run = 0
	if pos == token.length():
		return score - name.length()
	return 0


func count() -> int:
	return total_files


func summary() -> String:
	if total_files == 0:
		return "No resources indexed"
	return "%d ODFs, %d asset names indexed in %d ms" % [total_files, assets_by_name.size(), last_scan_msec]


## Filtered search across all entries (supports Stock/VSR/VRV/Mods/Addon collections
## and object categories, preserving duplicates across different collections).
func search_filtered(query: String, collection: String = "all", category: String = "all",
		limit: int = 500) -> Array[Dictionary]:
	var q := query.strip_edges().to_lower()
	var coll_f := collection.strip_edges().to_lower()
	var cat_f := category.strip_edges().to_lower()
	var tokens := q.split(" ", false) if q != "" else PackedStringArray()
	var scored: Array[Dictionary] = []
	for key in files:
		var name := str(key)
		var gname := _stem_fallback_name(name.get_basename()).to_lower()
		var score := 1
		if not tokens.is_empty():
			score = 0
			var matched := true
			for t in tokens:
				var tok_s := str(t)
				var s := _token_score(name, tok_s)
				if gname != "":
					s = maxi(s, _token_score(gname, tok_s))
				if s <= 0:
					matched = false
					break
				score += s
			if not matched:
				continue
		var list: Array = files[key]
		for item in list:
			if coll_f != "" and coll_f != "all" and str(item.get("collection", "")) != coll_f:
				continue
			if cat_f != "" and cat_f != "all" and str(item.get("category", "")).to_lower() != cat_f:
				continue
			var row: Dictionary = (item as Dictionary).duplicate()
			row["match_score"] = score
			scored.append(row)
			if q == "" and coll_f == "all" and cat_f == "all":
				break
	scored.sort_custom(func(a, b):
		if int(a.match_score) != int(b.match_score):
			return int(a.match_score) > int(b.match_score)
		return str(a.path) < str(b.path)
	)
	if limit > 0 and scored.size() > limit:
		return scored.slice(0, limit)
	return scored


func collection_counts() -> Dictionary:
	var counts := {"all": 0, "stock": 0, "vsr": 0, "vrv": 0, "mods": 0, "addon": 0}
	for key in files:
		for item in files[key]:
			counts["all"] = int(counts["all"]) + 1
			var c := str(item.get("collection", "mods"))
			counts[c] = int(counts.get(c, 0)) + 1
	return counts


func _asset_candidates(leaf: String, extensions: Array[String]) -> Array[String]:
	## BZCC internally maps legacy texture extensions (e.g. .tga/.bmp) to baked .dds
	## (PARTICLE.md line 250). Always try the exact name first, then swap extension
	## across `extensions` so baked .dds assets resolve automatically.
	var candidates: Array[String] = []
	var seen := {}
	var ext := leaf.get_extension().to_lower()
	if ext != "":
		candidates.append(leaf)
		seen[leaf.to_lower()] = true
		var stem := leaf.get_basename()
		for e in extensions:
			var alt := stem + "." + e.to_lower()
			if not seen.has(alt.to_lower()):
				candidates.append(alt)
				seen[alt.to_lower()] = true
	else:
		for e in extensions:
			var alt2 := leaf + "." + e.to_lower()
			if not seen.has(alt2.to_lower()):
				candidates.append(alt2)
				seen[alt2.to_lower()] = true
	return candidates


func find_asset_near(name: String, extensions: Array[String], context_path: String = "") -> String:
	var clean := name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if clean == "":
		return ""
	var leaf := clean.get_file() if (clean.contains("/") or clean.contains("\\")) else clean
	var candidates := _asset_candidates(leaf, extensions)
	if context_path != "":
		var base_dir := context_path.get_base_dir()
		for sub in ["", "textures", "materials"]:
			var d := base_dir.path_join(sub) if sub != "" else base_dir
			for cand in candidates:
				var direct := d.path_join(cand)
				if FileAccess.file_exists(direct):
					return direct
				# Case-insensitive fallback inside the same folder
				var dir := DirAccess.open(d)
				if dir != null:
					dir.list_dir_begin()
					var fn := dir.get_next()
					while fn != "":
						if not dir.current_is_dir() and fn.to_lower() == cand.to_lower():
							dir.list_dir_end()
							return d.path_join(fn)
						fn = dir.get_next()
					dir.list_dir_end()
	return find_asset(name, extensions, context_path)


func find_asset(name: String, extensions: Array[String], context_path: String = "") -> String:
	## Asset lookup against the indexed asset map (active_packages -> same enabled package -> base game -> addon).
	## Under STRICT_ACTIVE_LOADOUT with strict_package_filter, disabled Workshop packages are never substituted.
	var clean := name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if clean == "":
		return ""
	if clean.contains("/") or clean.contains("\\"):
		clean = clean.get_file()
	var candidates := _asset_candidates(clean, extensions)
	var pkg := package_of(context_path) if context_path != "" else ""
	var use_strict := strict_package_filter or (not active_packages.is_empty())
	for cand in candidates:
		var list: Array = assets_by_name.get(cand.to_lower(), [])
		if not list.is_empty():
			if not active_packages.is_empty():
				for ap in active_packages:
					for item in list:
						if str(item.get("package", "")) == ap:
							return str(item.path)
			if pkg != "" and (not use_strict or active_packages.has(pkg)):
				for item in list:
					if str(item.get("package", "")) == pkg:
						return str(item.path)
			for item in list:
				if str(item.get("kind", "")) == "game":
					return str(item.path)
			for item in list:
				if str(item.get("kind", "")) == "addon":
					return str(item.path)
			if not use_strict or resolution_policy == POLICY_EDITOR_PREVIEW_FALLBACK:
				var best: Dictionary = list[0]
				for item in list:
					if int(item.priority) > int(best.priority):
						best = item
				return str(best.path)
	# Fall back to a direct filename scan of the common flat asset dirs (non-workshop roots when strict).
	for r in available_roots():
		if use_strict and str(r.get("kind", "")) == "workshop":
			continue
		var root := str(r.get("path", ""))
		for sub in ["audio", "effects", "baked", "bakedm", "interface", "objects", ""]:
			for cand in candidates:
				var p := root.path_join(sub).path_join(cand) if sub != "" else root.path_join(cand)
				if FileAccess.file_exists(p):
					return p
	return ""


func asset_count() -> int:
	return assets_by_name.size()


const CACHE_SCHEMA := 3

## Cache lives inside the active workspace. Fingerprints bind workspace override
## state, so a cache written for one workspace must never be read by another.
static func default_cache_path() -> String:
	return WorkspaceStore.root().path_join("resource_index_cache.json")


func _collect_dir_fingerprint_rows(abs_dir: String, root_path: String, rows: Array[String]) -> void:
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	var subdirs: Array[String] = []
	var fnames: Array[String] = []
	while n != "":
		if n != "." and n != "..":
			var full := abs_dir.path_join(n)
			if dir.current_is_dir():
				subdirs.append(full)
			else:
				var ext := n.get_extension().to_lower()
				if ext == "odf" or ext == "ini" or ASSET_EXTS.has(ext):
					fnames.append(n)
		n = dir.get_next()
	dir.list_dir_end()
	fnames.sort()
	for fn in fnames:
		var fp := abs_dir.path_join(fn)
		var rel := fp.trim_prefix(root_path).trim_prefix("/")
		var mtime := FileAccess.get_modified_time(fp)
		var flen := 0
		var fa := FileAccess.open(fp, FileAccess.READ)
		if fa != null:
			flen = int(fa.get_length())
			fa.close()
		var content_id := ""
		var ext := fn.get_extension().to_lower()
		# Strong content tier: active ODFs and INI/package metadata are small and
		# decisive for resource identity. Bulk binary assets stay metadata-only,
		# so startup never hashes the entire Workshop collection.
		if ext == "odf" or ext == "ini":
			var content_bytes := FileAccess.get_file_as_bytes(fp)
			content_id = WorkspaceStore._md5_bytes(content_bytes) if not content_bytes.is_empty() else "d41d8cd98f00b204e9800998ecf8427e"
		rows.append("F|%s|%d|%d|%s" % [rel.to_lower(), flen, mtime, content_id])
	subdirs.sort()
	for sd in subdirs:
		_collect_dir_fingerprint_rows(sd, root_path, rows)


## Compute a deterministic SHA256 fingerprint across all enabled roots, file
## metadata (paths, sizes, mtimes), active ModLoadout/package priority state,
## explicit resource winners, and WorkspaceStore overrides (Wave E).
func compute_roots_fingerprint(include_workshop: bool = true) -> Dictionary:
	var lines: Array[String] = []
	lines.append("SCHEMA=%d|WORKSHOP=%s" % [CACHE_SCHEMA, str(include_workshop)])
	lines.append("LOADOUT=%s|POLICY=%s|STRICT=%s|BASE_FB=%s|DIS_WIN=%s" % [
		active_loadout_profile_id, resolution_policy, str(strict_package_filter),
		str(allow_base_game_fallback), str(allow_disabled_explicit_winners)
	])
	lines.append("ACTIVE_PKGS=" + ",".join(active_packages))
	var wkeys := explicit_resource_winners.keys()
	wkeys.sort()
	for wk in wkeys:
		lines.append("WIN|%s=%s" % [str(wk), str(explicit_resource_winners[wk])])
	# Include WorkspaceStore manifest & override files so saving/reverting any override invalidates the cache!
	var ws_root := WorkspaceStore.canonical(WorkspaceStore.root())
	var ws_proj := ws_root.path_join("project.json")
	if FileAccess.file_exists(ws_proj):
		lines.append("WS_PROJ|" + WorkspaceStore._md5_bytes(FileAccess.get_file_as_bytes(ws_proj)))
	else:
		lines.append("WS_PROJ|NONE")
	var ws_odf_dir := ws_root.path_join("odf")
	if DirAccess.dir_exists_absolute(ws_odf_dir):
		var ws_rows: Array[String] = []
		_collect_dir_fingerprint_rows(ws_odf_dir, ws_odf_dir, ws_rows)
		for wr in ws_rows:
			lines.append("WS_" + wr)
	var file_count := 0
	for r in available_roots():
		var kind := str(r.get("kind", ""))
		if kind == "workshop" and not include_workshop:
			continue
		var rpath := WorkspaceStore.canonical(str(r.get("path", "")))
		lines.append("ROOT|%s|%s|%d|%s" % [rpath.to_lower(), kind, int(r.get("priority", 10)), str(r.get("label", ""))])
		var r_rows: Array[String] = []
		_collect_dir_fingerprint_rows(rpath, rpath, r_rows)
		file_count += r_rows.size()
		lines.append_array(r_rows)
	var payload := "\n".join(lines).to_utf8_buffer()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(payload)
	var sha := ctx.finish().hex_encode().to_lower()
	return {"ok": true, "fingerprint": sha, "tracked_entries": file_count, "include_workshop": include_workshop}


func _canonical_json_value(value):
	if value is Dictionary:
		var out := {}
		for k in (value as Dictionary).keys():
			out[str(k)] = _canonical_json_value((value as Dictionary)[k])
		return out
	if value is Array:
		var arr := []
		for v in (value as Array):
			arr.append(_canonical_json_value(v))
		return arr
	if value is float and is_equal_approx(float(value), roundf(float(value))):
		return int(value)
	return value


func _sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode().to_lower()


## Persist the scanned ResourceIndex along with its live SHA256 fingerprint.
func save_index_cache(cache_path: String = "", include_workshop: bool = true) -> Dictionary:
	var target := cache_path.strip_edges() if cache_path.strip_edges() != "" else default_cache_path()
	var abs_target := WorkspaceStore.canonical(target)
	var fp := compute_roots_fingerprint(include_workshop)
	var payload := JSON.stringify({
		"total_files": total_files,
		"files": files,
		"assets_by_name": assets_by_name,
		"package_names": package_names,
		"extension_counts": extension_counts,
	})
	var doc := {
		"schema": CACHE_SCHEMA,
		"payload_sha256": _sha256_hex(payload.to_utf8_buffer()),
		"saved_at": Time.get_datetime_string_from_system(),
		"include_workshop": include_workshop,
		"fingerprint": str(fp.get("fingerprint", "")),
		"total_files": total_files,
		"files": files,
		"assets_by_name": assets_by_name,
		"package_names": package_names,
		"extension_counts": extension_counts,
	}
	var wres := WorkspaceStore.atomic_write_abs(abs_target, JSON.stringify(doc).to_utf8_buffer())
	if not bool(wres.get("ok", false)):
		return {"ok": false, "reason": "CACHE_WRITE_FAILED", "error": str(wres.get("error", ""))}
	return {"ok": true, "path": abs_target, "fingerprint": str(fp.get("fingerprint", "")), "total_files": total_files}


## Load a previously saved ResourceIndex ONLY when the live SHA256 fingerprint
## (roots, priorities, file sizes/mtimes, active ModLoadout, WorkspaceStore
## overrides) matches the cached fingerprint bit-for-bit.
func load_index_cache(include_workshop: bool = true, cache_path: String = "") -> Dictionary:
	var target := cache_path.strip_edges() if cache_path.strip_edges() != "" else default_cache_path()
	var abs_target := WorkspaceStore.canonical(target)
	if not FileAccess.file_exists(abs_target):
		return {"ok": false, "cache_hit": false, "reason": "CACHE_MISSING", "path": abs_target}
	var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(abs_target))
	if not bool(jres.get("ok", false)) or not (jres.get("data", null) is Dictionary):
		return {"ok": false, "cache_hit": false, "reason": "CACHE_CORRUPT", "path": abs_target}
	var doc: Dictionary = jres.get("data", {})
	if int(doc.get("schema", 0)) != CACHE_SCHEMA:
		return {"ok": false, "cache_hit": false, "reason": "CACHE_SCHEMA_MISMATCH", "path": abs_target}
	var live_fp := compute_roots_fingerprint(include_workshop)
	var cached_fp := str(doc.get("fingerprint", ""))
	if cached_fp == "" or cached_fp != str(live_fp.get("fingerprint", "")):
		return {
			"ok": false,
			"cache_hit": false,
			"reason": "FINGERPRINT_MISMATCH",
			"cached_fingerprint": cached_fp,
			"live_fingerprint": str(live_fp.get("fingerprint", "")),
		}
	if bool(doc.get("include_workshop", false)) != include_workshop:
		return {"ok": false, "cache_hit": false, "reason": "CACHE_WORKSHOP_MISMATCH", "path": abs_target}
	var cached_payload := {
		"total_files": doc.get("total_files", null),
		"files": doc.get("files", null),
		"assets_by_name": doc.get("assets_by_name", null),
		"package_names": doc.get("package_names", null),
		"extension_counts": doc.get("extension_counts", null),
	}
	var required_maps := ["files", "assets_by_name", "package_names", "extension_counts"]
	for key in required_maps:
		if not (doc.get(key, null) is Dictionary):
			return {"ok": false, "cache_hit": false, "reason": "CACHE_INVALID_FIELD_TYPE", "path": abs_target}
	if not (doc.get("total_files", null) is int or doc.get("total_files", null) is float):
		return {"ok": false, "cache_hit": false, "reason": "CACHE_INVALID_FIELD_TYPE", "path": abs_target}
	var cache_counts: Dictionary = doc.get("extension_counts", {})
	for ck in cache_counts.keys():
		if not (cache_counts[ck] is int or cache_counts[ck] is float):
			return {"ok": false, "cache_hit": false, "reason": "CACHE_INVALID_FIELD_TYPE", "path": abs_target}
	var payload_str := JSON.stringify(cached_payload)
	var expected_hash := str(doc.get("payload_sha256", ""))
	var payload_hash := _sha256_hex(payload_str.to_utf8_buffer())
	# JSON round-trip turns integers into floats; canonicalize every numeric
	# level before hashing so a valid cache survives a save/load cycle.
	var normalized_hash := _sha256_hex(JSON.stringify(_canonical_json_value(cached_payload)).to_utf8_buffer())
	if expected_hash == "" or (payload_hash != expected_hash and normalized_hash != expected_hash):
		return {"ok": false, "cache_hit": false, "reason": "CACHE_PAYLOAD_HASH_MISMATCH", "path": abs_target}
	var cached_files: Dictionary = cached_payload["files"]
	var cached_counts: Dictionary = cached_payload["extension_counts"]
	var sum_counts := 0
	for key in cached_counts.keys():
		if not (cached_counts[key] is int or cached_counts[key] is float):
			return {"ok": false, "cache_hit": false, "reason": "CACHE_INVALID_FIELD_TYPE", "path": abs_target}
		sum_counts += int(cached_counts[key])
	for key in cached_files.keys():
		if not (cached_files[key] is Array):
			return {"ok": false, "cache_hit": false, "reason": "CACHE_INVALID_FIELD_TYPE", "path": abs_target}
	var cached_file_entries := 0
	for key in cached_files.keys():
		cached_file_entries += (cached_files[key] as Array).size()
	if int(cached_payload["total_files"]) != cached_file_entries or sum_counts != cached_file_entries:
		return {"ok": false, "cache_hit": false, "reason": "CACHE_COUNT_MISMATCH", "path": abs_target}
	var t0 := Time.get_ticks_msec()
	files = cached_files.duplicate(true)
	assets_by_name = (cached_payload["assets_by_name"] as Dictionary).duplicate(true)
	package_names = (cached_payload["package_names"] as Dictionary).duplicate(true)
	extension_counts = cached_counts.duplicate(true)
	total_files = int(cached_payload["total_files"])
	_game_name_cache.clear()
	generation += 1
	last_scan_msec = Time.get_ticks_msec() - t0
	scan_finished.emit(total_files)
	return {"ok": true, "cache_hit": true, "reason": "", "fingerprint": cached_fp, "total_files": total_files, "load_ms": last_scan_msec}


func invalidate_cache(cache_path: String = "") -> void:
	var target := cache_path.strip_edges() if cache_path.strip_edges() != "" else default_cache_path()
	var abs_target := WorkspaceStore.canonical(target)
	if FileAccess.file_exists(abs_target):
		DirAccess.remove_absolute(abs_target)


## Application index-build entry point: reuse a fingerprint-valid cache when it
## still matches the live roots, otherwise scan and persist a fresh one. A cache
## write failure must never prevent the index from being built.
func scan_or_load_cache(include_workshop: bool = true, cache_path: String = "") -> Dictionary:
	var hit := load_index_cache(include_workshop, cache_path)
	if bool(hit.get("ok", false)) and bool(hit.get("cache_hit", false)):
		hit["scanned"] = false
		return hit
	scan(include_workshop)
	var saved := save_index_cache(cache_path, include_workshop)
	var result := {
		"ok": true,
		"cache_hit": false,
		"scanned": true,
		"reason": str(hit.get("reason", "CACHE_MISS")),
		"fingerprint": str(saved.get("fingerprint", "")),
		"cache_saved": bool(saved.get("ok", false)),
		"total_files": total_files,
	}
	return result


## Return rich live provenance for any resource reference: effective source,
## package identity, content hash/revision, workspace override flag, alternative
## candidates across packages/roots, and honest preview fidelity.
func provenance_summary(name: String, context_path: String = "") -> Dictionary:
	var resolved := resolve_ex(name, context_path)
	var found := bool(resolved.get("found", false))
	var entry: Dictionary = resolved.get("entry", {}) if resolved.get("entry", {}) is Dictionary else {}
	var eff_path := str(resolved.get("path", ""))
	var ident := resource_identity(entry if not entry.is_empty() else eff_path, context_path) if found else {}
	var ws_entry := WorkspaceStore.entry_for(eff_path) if eff_path != "" else {}
	var has_ws := not ws_entry.is_empty()
	var alts_raw := alternatives(name)
	var alts_out: Array[Dictionary] = []
	for c in alts_raw:
		var cp := str(c.get("path", ""))
		if found and WorkspaceStore._same_canon_path(cp, eff_path):
			continue
		alts_out.append({
			"path": cp,
			"package_id": str(c.get("package", "")),
			"mod_label": str(c.get("mod_label", "")),
			"kind": str(c.get("kind", "")),
			"priority": int(c.get("priority", 0)),
		})
	var cat := str(entry.get("category", ""))
	var fidelity := "EDITING_COMPLETE"
	if cat in ["Weapons", "Ordnance", "Explosions / FX", "Vehicles"]:
		fidelity = "APPROXIMATED"
	return {
		"found": found,
		"resource": _clean_ref(name).to_lower(),
		"effective_path": eff_path,
		"package_id": str(resolved.get("package", "")),
		"mod_label": str(entry.get("mod_label", "Stock (BZ2R)" if str(resolved.get("kind", "")) == "game" else "")),
		"collection": str(entry.get("collection", "")),
		"kind": str(resolved.get("kind", "")),
		"content_hash": str(ident.get("content_hash", "")),
		"workspace_revision": int(ident.get("workspace_revision", 0)),
		"has_workspace_override": has_ws,
		"active_loadout_profile_id": active_loadout_profile_id,
		"rule": str(resolved.get("rule", "")),
		"status": str(resolved.get("status", "")),
		"warning": str(resolved.get("warning", "")),
		"alternatives": alts_out,
		"preview_fidelity": fidelity,
	}
