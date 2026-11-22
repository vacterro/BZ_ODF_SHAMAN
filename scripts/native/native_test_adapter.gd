class_name NativeTestAdapter
extends RefCounted
## Native BZCC validation: scenario package builder, BZN/mount preflight,
## Steam launch capability routes, process-local trusted execution attestation,
## and session-bound native observation comparison.
##
## Provenance note: the process-local trusted session registry establishes
## application-level provenance (preventing synthetic/schema-only dicts from
## self-certifying as NATIVE_VERIFIED); it is not a cryptographic tamper-proof
## guarantee against a hostile local administrator.

const EXE_NAME := "battlezone2.exe"
const DEFAULT_GAME_ROOT := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R"
const STEAM_APP_ID := "624970"
const MANIFEST_NAME := "native_evidence.json"
const DEFAULT_MISSION_BASE := "shaman_shot"
const DEFAULT_TERRAIN_NAME := "test"
const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")
const NativeSessionScript = preload("res://scripts/native/native_experiment_session.gd")
const ResourceClosureScript = preload("res://scripts/native/native_resource_closure.gd")

const LIMITATIONS := [
	"Live BZCC launch via Steam requires an active logged-in Steam client session for AppID 624970.",
	"Application-level trusted receipts verify runner provenance in-process, not cryptographic tamper resistance.",
	"ODF resource reload timing in BZCC requires a fresh mission start.",
	"Workshop mount order in the editor is an editor policy until verified per-mod in BZCC.",
]

const EVIDENCE_STATES := [
	"DRAFT",
	"STAGED",
	"STRUCTURALLY_VALID",
	"RESOURCES_MOUNTED",
	"LAUNCH_REQUESTED",
	"STEAM_PROCESS_STARTED",
	"GAME_STARTED",
	"GAME_PROCESS_DETECTED",
	"MISSION_LOADED",
	"MISSION_OBSERVED",
	"RESOURCE_PROBE_CONFIRMED",
	"OBSERVATION_CAPTURED",
	"COMPARISON_COMPLETE",
	"NATIVE_VERIFIED",
	"TIMEOUT",
	"BLOCKED",
	"FAILED",
]

const LAUNCH_ROUTES := [
	"DIRECT_EXECUTABLE",
	"STEAM_MANAGED",
	"STEAM_LAUNCH_OPTIONS",
	"OPERATOR_MANUAL",
	"UNSUPPORTED",
]

const LUA_EXPERIMENT_STATES := [
	"INITIALIZING",
	"OBJECTS_SPAWNED",
	"WEAPON_ASSIGNED",
	"READY",
	"FIRE_REQUESTED",
	"FIRE_CONFIRMED",
	"HEALTH_DELTA_OBSERVED",
	"IMPACT_CONFIRMED",
	"MEASUREMENT_COMPLETE",
	"TIMEOUT",
	"FAILED",
]

## Process-local trusted execution registry: session_id -> receipt Dictionary.
## Only runner-controlled APIs (begin_trusted_session / confirm_trusted_execution
## / capture_trusted_observation) may populate or advance these entries.
static var _trusted_sessions: Dictionary = {}
static var _session_seq := 0


static func clear_trusted_sessions() -> void:
	_trusted_sessions.clear()


static func get_trusted_session(session_id: String) -> Dictionary:
	if _trusted_sessions.has(session_id):
		return (_trusted_sessions[session_id] as Dictionary).duplicate(true)
	return {}


## Parse Valve KeyValues line tokens (e.g. `"buildid"		"20345678"`).
## Returns {ok, build_id, error} where missing/invalid yields "UNKNOWN".
static func parse_appmanifest_build_id(acf_text: String) -> Dictionary:
	if acf_text.strip_edges() == "":
		return {"ok": false, "build_id": "UNKNOWN", "error": "empty appmanifest"}
	for line in acf_text.split("\n"):
		var tokens := _parse_kv_quoted_tokens(line)
		if tokens.size() >= 2 and str(tokens[0]).to_lower() == "buildid":
			var raw := str(tokens[1]).strip_edges()
			if raw == "":
				return {"ok": false, "build_id": "UNKNOWN", "error": "buildid is empty"}
			if not _is_ascii_digits(raw):
				return {"ok": false, "build_id": "UNKNOWN", "error": "buildid is non-numeric: " + raw}
			return {"ok": true, "build_id": raw, "error": ""}
	return {"ok": false, "build_id": "UNKNOWN", "error": "buildid not found in appmanifest"}


static func parse_appmanifest_launcher_path(acf_text: String) -> String:
	for line in acf_text.split("\n"):
		var tokens := _parse_kv_quoted_tokens(line)
		if tokens.size() >= 2 and str(tokens[0]).to_lower() == "launcherpath":
			return WorkspaceStore.canonical(str(tokens[1]).strip_edges())
	return ""


static func _parse_kv_quoted_tokens(line: String) -> Array[String]:
	var out: Array[String] = []
	var i := 0
	var n := line.length()
	while i < n:
		var ch := line.substr(i, 1)
		if ch == "/" and i + 1 < n and line.substr(i + 1, 1) == "/":
			break
		if ch == "\"":
			i += 1
			var buf := ""
			var closed := false
			while i < n:
				var c := line.substr(i, 1)
				if c == "\\" and i + 1 < n:
					buf += line.substr(i + 1, 1)
					i += 2
					continue
				if c == "\"":
					closed = true
					i += 1
					break
				buf += c
				i += 1
			if closed:
				out.append(buf)
			continue
		i += 1
	return out


static func _is_ascii_digits(s: String) -> bool:
	if s.is_empty():
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true


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


static func _to_win_path(p: String) -> String:
	return WorkspaceStore.canonical(p).replace("/", "\\")


static func _same_path(a: String, b: String) -> bool:
	var ca := WorkspaceStore.canonical(a)
	var cb := WorkspaceStore.canonical(b)
	if OS.get_name() == "Windows":
		return ca.to_lower() == cb.to_lower()
	return ca == cb


static func _hash_dict(d: Dictionary) -> String:
	return JSON.stringify(d, "", true).md5_text()


## Read-only Steam client environment probe (never writes into Steam or BZ2R).
static func detect_steam_environment(discovery: Dictionary = {}) -> Dictionary:
	var steam_exe := str(discovery.get("steam_exe", ""))
	if steam_exe == "":
		var game_root := str(discovery.get("game_root", DEFAULT_GAME_ROOT))
		var steam_root := WorkspaceStore.canonical(game_root).get_base_dir().get_base_dir().get_base_dir()
		var candidate := steam_root.path_join("steam.exe")
		if FileAccess.file_exists(candidate):
			steam_exe = candidate
	var steam_present := steam_exe != "" and FileAccess.file_exists(steam_exe)
	var active_pid := 0
	var active_user := 0
	var steam_running := false
	var steam_logged_in := false
	var probe_detail := ""
	if OS.get_name() == "Windows":
		var out: Array = []
		var rc := OS.execute("reg", ["query", "HKCU\\Software\\Valve\\Steam\\ActiveProcess"], out, true)
		if rc == 0 and not out.is_empty():
			var txt := str(out[0])
			for raw_line in txt.split("\n"):
				var line := raw_line.strip_edges()
				if line.begins_with("pid"):
					var parts := line.split(" ", false)
					if parts.size() >= 3:
						active_pid = parts[2].hex_to_int() if parts[2].begins_with("0x") else int(parts[2])
				elif line.begins_with("ActiveUser"):
					var parts2 := line.split(" ", false)
					if parts2.size() >= 3:
						active_user = parts2[2].hex_to_int() if parts2[2].begins_with("0x") else int(parts2[2])
		if active_pid > 0:
			var pout: Array = []
			var prc := OS.execute("tasklist", ["/FI", "PID eq %d" % active_pid, "/NH"], pout, true)
			if prc == 0 and not pout.is_empty() and str(pout[0]).to_lower().contains("steam.exe"):
				steam_running = true
		steam_logged_in = steam_running and active_user > 0
		if not steam_present:
			probe_detail = "steam.exe not found"
		elif not steam_running:
			probe_detail = "steam.exe present but not running in current Windows session (ActiveUser=0x%x)" % active_user
		elif not steam_logged_in:
			probe_detail = "steam.exe running but no Steam user logged in (ActiveUser=0x0)"
		else:
			probe_detail = "Steam client running and logged in (pid=%d, ActiveUser=0x%x)" % [active_pid, active_user]
	else:
		probe_detail = "non-Windows host"
	var routes: Array[String] = []
	if steam_present:
		routes.append("STEAM_MANAGED")
		routes.append("STEAM_LAUNCH_OPTIONS")
		routes.append("OPERATOR_MANUAL")
	if bool(discovery.get("ok", false)):
		routes.append("DIRECT_EXECUTABLE")
	if routes.is_empty():
		routes.append("UNSUPPORTED")
	return {
		"steam_exe": steam_exe,
		"steam_present": steam_present,
		"steam_running": steam_running,
		"steam_logged_in": steam_logged_in,
		"active_pid": active_pid,
		"active_user": active_user,
		"detail": probe_detail,
		"supported_routes": routes,
	}


## Read-only discovery. Never writes into the game root.
static func discover(game_root: String = DEFAULT_GAME_ROOT, probe_steam: bool = true) -> Dictionary:
	var root := WorkspaceStore.canonical(game_root)
	var exe := root.path_join(EXE_NAME)
	var out := {
		"ok": false,
		"game_root": root,
		"exe": exe,
		"exe_md5": "",
		"exe_bytes": 0,
		"build_id": "UNKNOWN",
		"build_id_valid": false,
		"build_id_error": "",
		"data_root": root.path_join("Data"),
		"res_root": root.path_join("bz2r_res"),
		"missions_dll_root": root.path_join("Missions"),
		"luamission_dll_present": false,
		"workshop_root": "",
		"addon_root": "",
		"steam_exe": "",
		"steam": {},
		"limitations": LIMITATIONS.duplicate(),
	}
	if not DirAccess.dir_exists_absolute(root) or not FileAccess.file_exists(exe):
		return out
	out.ok = true
	out.exe_md5 = FileAccess.get_md5(exe)
	out.exe_bytes = FileAccess.get_file_as_bytes(exe).size()
	out.luamission_dll_present = FileAccess.file_exists(root.path_join("Missions/LuaMission.dll"))
	# Steam layout: <steamapps>/common/BZ2R -> <steamapps>/appmanifest_624970.acf
	var steamapps := root.get_base_dir().get_base_dir()
	var manifest := steamapps.path_join("appmanifest_" + STEAM_APP_ID + ".acf")
	if FileAccess.file_exists(manifest):
		var acf_text := FileAccess.get_file_as_string(manifest)
		var parsed := parse_appmanifest_build_id(acf_text)
		out.build_id = str(parsed.get("build_id", "UNKNOWN"))
		out.build_id_valid = bool(parsed.get("ok", false))
		out.build_id_error = str(parsed.get("error", ""))
		out.steam_exe = parse_appmanifest_launcher_path(acf_text)
	else:
		out.build_id_error = "appmanifest not found: " + manifest
	if out.steam_exe == "":
		var fallback_steam := steamapps.get_base_dir().path_join("steam.exe")
		if FileAccess.file_exists(fallback_steam):
			out.steam_exe = fallback_steam
	var workshop := steamapps.path_join("workshop/content/" + STEAM_APP_ID)
	if DirAccess.dir_exists_absolute(workshop):
		out.workshop_root = workshop
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs != "":
		var addon := docs.path_join("My Games/Battlezone Combat Commander/Addon")
		if DirAccess.dir_exists_absolute(addon):
			out.addon_root = addon
	if probe_steam:
		out.steam = detect_steam_environment(out)
	return out


static func _extra_protected_from_discovery(discovery: Dictionary, allow_mydocs_addon_stage: bool = false) -> Array[String]:
	var out: Array[String] = []
	var keys := ["game_root", "data_root", "res_root", "missions_dll_root", "workshop_root"]
	if not allow_mydocs_addon_stage:
		keys.append("addon_root")
	for k in keys:
		var p := str(discovery.get(k, ""))
		if p != "":
			out.append(p)
	return out


## Generate a structurally valid BZCC v1192 ASCII BZN fixture selecting
## luamission.dll and a verified stock terrain (default: `test` from
## bz2r_res/datapak/test.{trn,ter,wat}). Matches the verified ASCII schema
## observed in real BZCC LuaMission maps (e.g. sbxcon.bzn).
static func build_minimal_luamission_bzn(mission_base: String = DEFAULT_MISSION_BASE,
		terrain_name: String = DEFAULT_TERRAIN_NAME) -> String:
	var mbase := mission_base.strip_edges().get_basename()
	if mbase == "":
		mbase = DEFAULT_MISSION_BASE
	var tname := terrain_name.strip_edges()
	if tname == "":
		tname = DEFAULT_TERRAIN_NAME
	var zeros_1024 := "0".repeat(1024)
	var pad1 := "0".repeat(512) + "1" + "0".repeat(511)
	var lines := [
		"version [1] =",
		"1192",
		"saveType [1] =",
		"0",
		"binarySave [1] =",
		"false",
		"msn_filename = %s.bzn" % mbase,
		"seq_count [1] =",
		"7",
		"saveType [1] =",
		"0",
		"g_TerrainName = %s" % tname,
		"size [1] =",
		"1",
		"[GameObject]",
		"objClass = player",
		"seqno [1] =",
		"1",
		"team [1] =",
		"1",
		"label = unnamed_player",
		"isUser [1] =",
		"true",
		"objAddr = 00000001",
		"transform [1] =",
		"  right.x [1] =",
		"1.00000000e+00",
		"  right.y [1] =",
		"0.00000000e+00",
		"  right.z [1] =",
		"0.00000000e+00",
		"  up.x [1] =",
		"0.00000000e+00",
		"  up.y [1] =",
		"1.00000000e+00",
		"  up.z [1] =",
		"0.00000000e+00",
		"  front.x [1] =",
		"0.00000000e+00",
		"  front.y [1] =",
		"0.00000000e+00",
		"  front.z [1] =",
		"1.00000000e+00",
		"  posit.x [1] =",
		"0.00000000e+00",
		"  posit.y [1] =",
		"2.00000000e+00",
		"  posit.z [1] =",
		"-4.00000000e+01",
		"abandoned [1] =",
		"0",
		"curAmmo [1] =",
		"1.20000000e+03",
		"maxAmmo [1] =",
		"1.20000000e+03",
		"addAmmo [1] =",
		"5.00000000e+00",
		"curPilot = isuser",
		"illumination [1] =",
		"1.00000000e+00",
		"euler =",
		" mass [1] =",
		"1.30762100e+04",
		" mass_inv [1] =",
		"7.64747601e-05",
		" v_mag [1] =",
		"0.00000000e+00",
		" v_mag_inv [1] =",
		"0.00000000e+00",
		" I [1] =",
		"1.44904813e+05",
		" k_i [1] =",
		"6.90108209e-06",
		" v [1] =",
		"  x [1] =",
		"0.00000000e+00",
		"  y [1] =",
		"0.00000000e+00",
		"  z [1] =",
		"0.00000000e+00",
		" omega [1] =",
		"  x [1] =",
		"0.00000000e+00",
		"  y [1] =",
		"0.00000000e+00",
		"  z [1] =",
		"0.00000000e+00",
		" Accel [1] =",
		"  x [1] =",
		"0.00000000e+00",
		"  y [1] =",
		"0.00000000e+00",
		"  z [1] =",
		"0.00000000e+00",
		"name = Observer",
		"saveFlags [1] =",
		"104",
		"isVisible [1] =",
		"65535",
		"EffectsMask [1] =",
		"65535",
		"isSeen [1] =",
		"2",
		"groupNumber [1] =",
		"-1",
		"undefaicmd =",
		"priority [1] =",
		"0",
		"what = 00000000",
		"who [1] =",
		"0",
		"where = 00000000",
		"param [1] =",
		"0",
		"aiProcess [1] =",
		"true",
		"independence [1] =",
		"1",
		"groupTargets = " + zeros_1024,
		"dllName = luamission.dll",
		"[AiMission]",
		"[AOIs]",
		"size [1] =",
		"0",
		"[AiPaths]",
		"count [1] =",
		"0",
		"hasEntered [1] =",
		"false",
		"ownerObj [1] =",
		"0",
		"ownerObj [1] =",
		"0",
		"ownerObj [1] =",
		"0",
		"PadData = " + pad1,
		"PadData2 = " + zeros_1024,
	]
	return "\r\n".join(lines) + "\r\n"


## Parse and validate a staged mission package: BZN header, luamission.dll
## selection, matching .lua script, terrain .trn/.ter dependencies, and shell
## launch target in bzshell_init.cfg.
static func validate_mission_package(files: Dictionary, game_root: String = DEFAULT_GAME_ROOT) -> Dictionary:
	var bzn_rel := ""
	var bzn_text := ""
	var lua_rels: Array[String] = []
	var shell_init_text := ""
	for raw_rel in files:
		var rel := str(raw_rel).replace("\\", "/")
		var lower := rel.to_lower()
		if lower.ends_with(".bzn") and bzn_rel == "":
			bzn_rel = rel
			var raw = files[raw_rel]
			bzn_text = (raw as PackedByteArray).get_string_from_utf8() if raw is PackedByteArray else str(raw)
		elif lower.ends_with(".lua"):
			lua_rels.append(rel)
		elif lower.ends_with("bzshell_init.cfg"):
			var sraw = files[raw_rel]
			shell_init_text = (sraw as PackedByteArray).get_string_from_utf8() if sraw is PackedByteArray else str(sraw)

	if bzn_rel == "" or bzn_text.strip_edges() == "":
		return {
			"ok": false,
			"reason": "MISSING_MISSION_BZN",
			"errors": ["generated scenario package does not contain a mission .bzn file"],
		}

	var parsed := _parse_ascii_bzn_meta(bzn_text)
	if not bool(parsed.get("ok", false)):
		return {
			"ok": false,
			"reason": "INVALID_MISSION_BZN",
			"errors": [str(parsed.get("error", "invalid BZN structure"))],
		}

	var bzn_file := bzn_rel.get_file()
	var bzn_base := bzn_file.get_basename().to_lower()
	var msn_file := str(parsed.get("msn_filename", "")).strip_edges()
	if msn_file == "" or msn_file.to_lower() != bzn_file.to_lower():
		return {
			"ok": false,
			"reason": "BZN_IDENTITY_MISMATCH",
			"errors": ["BZN msn_filename '%s' does not match staged file '%s'" % [msn_file, bzn_file]],
		}

	var dll_name := str(parsed.get("dll_name", "")).strip_edges().to_lower()
	if dll_name != "luamission.dll":
		return {
			"ok": false,
			"reason": "INCOMPATIBLE_MISSION_TYPE",
			"errors": ["BZN dllName is '%s'; expected 'luamission.dll'" % dll_name],
		}

	var matched_lua := ""
	for lrel in lua_rels:
		if lrel.get_file().get_basename().to_lower() == bzn_base:
			matched_lua = lrel
			break
	if matched_lua == "":
		return {
			"ok": false,
			"reason": "BZN_LUA_MISMATCH",
			"errors": ["no matching %s.lua found for BZN %s (found: %s)" % [bzn_base, bzn_file, ", ".join(lua_rels)]],
		}

	var lua_raw = files.get(matched_lua, "")
	var lua_text: String = (lua_raw as PackedByteArray).get_string_from_utf8() if lua_raw is PackedByteArray else str(lua_raw)
	if lua_text.contains("io.open("):
		return {
			"ok": false,
			"reason": "UNSUPPORTED_LUA_IO",
			"errors": ["LuaMission disables io.open; use WriteToFile() instead"],
		}

	var terrain := str(parsed.get("terrain", "")).strip_edges()
	var terrain_check := _resolve_terrain_dependencies(terrain, files, game_root)
	if not bool(terrain_check.get("ok", false)):
		return {
			"ok": false,
			"reason": "MISSING_TERRAIN_DEPENDENCY",
			"errors": [str(terrain_check.get("error", "terrain files unresolved: " + terrain))],
		}

	if shell_init_text != "":
		var expected_cmd := "shell.single.launch " + bzn_file
		if not shell_init_text.to_lower().contains(expected_cmd.to_lower()):
			return {
				"ok": false,
				"reason": "LAUNCH_TARGET_MISMATCH",
				"errors": ["bzshell_init.cfg launch target does not reference " + bzn_file],
			}

	return {
		"ok": true,
		"reason": "",
		"errors": [],
		"bzn_rel": bzn_rel,
		"bzn_file": bzn_file,
		"lua_rel": matched_lua,
		"terrain": terrain,
		"terrain_files": terrain_check.get("paths", {}),
		"dll_name": dll_name,
		"version": int(parsed.get("version", 0)),
	}


static func _parse_ascii_bzn_meta(bzn_text: String) -> Dictionary:
	var lines := bzn_text.replace("\r\n", "\n").split("\n")
	if lines.size() < 10:
		return {"ok": false, "error": "BZN too short"}
	if not lines[0].strip_edges().begins_with("version [1] ="):
		return {"ok": false, "error": "missing BZN version header"}
	var ver := int(lines[1].strip_edges())
	if ver < 1100 or ver > 1300:
		return {"ok": false, "error": "unsupported BZN version: %d" % ver}
	var msn_filename := ""
	var terrain := ""
	var dll_name := ""
	var has_game_object := false
	var has_ai_mission := false
	for raw_line in lines:
		var line := raw_line.strip_edges()
		if line.begins_with("msn_filename ="):
			msn_filename = line.substr("msn_filename =".length()).strip_edges()
		elif line.begins_with("g_TerrainName ="):
			terrain = line.substr("g_TerrainName =".length()).strip_edges()
		elif line.begins_with("TerrainName =") and terrain == "":
			terrain = line.substr("TerrainName =".length()).strip_edges()
		elif line.begins_with("dllName ="):
			dll_name = line.substr("dllName =".length()).strip_edges()
		elif line == "[GameObject]":
			has_game_object = true
		elif line == "[AiMission]":
			has_ai_mission = true
	if not has_game_object or not has_ai_mission:
		return {"ok": false, "error": "BZN missing [GameObject] or [AiMission] sections"}
	return {
		"ok": true,
		"version": ver,
		"msn_filename": msn_filename,
		"terrain": terrain,
		"dll_name": dll_name,
	}


static func _resolve_terrain_dependencies(terrain: String, staged_files: Dictionary, game_root: String) -> Dictionary:
	if terrain == "":
		return {"ok": false, "error": "BZN declares empty terrain name"}
	var found := {}
	var required_exts := ["trn", "ter"]
	var t_low := terrain.to_lower()
	for ext in required_exts:
		var wanted := "%s.%s" % [t_low, ext]
		for rel in staged_files:
			if str(rel).get_file().to_lower() == wanted:
				found[ext] = "staged:" + str(rel)
				break
		if found.has(ext):
			continue
		var root := WorkspaceStore.canonical(game_root)
		var candidates := [
			root.path_join("bz2r_res/datapak/%s.%s" % [terrain, ext]),
			root.path_join("bz2r_res/datapak/%s.%s" % [terrain, ext.to_upper()]),
			root.path_join("bz2r_res/Missions/%s/%s.%s" % [terrain, terrain, ext]),
		]
		for c in candidates:
			if FileAccess.file_exists(c):
				found[ext] = c
				break
	if found.size() < required_exts.size():
		var missing: Array[String] = []
		for ext in required_exts:
			if not found.has(ext):
				missing.append("%s.%s" % [terrain, ext])
		return {"ok": false, "error": "missing terrain dependency: " + ", ".join(missing)}
	return {"ok": true, "paths": found}


## Build explicit mapping between Godot staging location, BZCC virtual
## filesystem mount, writable MyDocs profile, and session observation paths.
static func build_mount_plan(stage_root: String, stage_id: String, session_id: String = "",
		mission_base: String = DEFAULT_MISSION_BASE) -> Dictionary:
	var canon_stage := WorkspaceStore.canonical(stage_root)
	var assets_dir := canon_stage.path_join("assets")
	var clean_tag := "SHAMAN_" + stage_id.replace("/", "_").replace("\\", "_").replace(" ", "_").substr(0, 24)
	var sid := session_id if session_id != "" else stage_id
	var safe_sid := sid.replace("/", "_").replace("\\", "_").replace(" ", "_")
	var docs := WorkspaceStore.canonical(OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
	var profile_dir := docs.path_join("My Games/Battlezone Combat Commander").path_join(clean_tag) if docs != "" else ""
	var logs_dir := profile_dir.path_join("Logs") if profile_dir != "" else ""
	var obs_filename := "shaman_obs_%s.json" % safe_sid
	return {
		"stage_absolute_path": canon_stage,
		"assets_mount_path": assets_dir,
		"assets_mount_win": _to_win_path(assets_dir),
		"bzcc_config_path": canon_stage.path_join("shaman_native.cfg"),
		"bzcc_config_win": _to_win_path(canon_stage.path_join("shaman_native.cfg")),
		"bzcc_mydocs_tag": clean_tag,
		"bzcc_writable_profile_dir": profile_dir,
		"bzcc_logs_dir": logs_dir,
		"startup_log_path": profile_dir.path_join("battlezone.log") if profile_dir != "" else "",
		"observation_filename": obs_filename,
		"observation_expected_path": logs_dir.path_join(obs_filename) if logs_dir != "" else "",
		"mission_bzn": mission_base + ".bzn",
		"mission_lua": mission_base + ".lua",
	}


## Verify shaman_native.cfg mounts the exact canonical staged assets directory
## rather than an unrelated @mydocsdir\addon folder.
static func validate_mount_config(cfg_text: String, stage_root: String) -> Dictionary:
	if cfg_text.strip_edges() == "":
		return {"ok": false, "reason": "MISSING_MOUNT_CONFIG", "error": "shaman_native.cfg is empty or missing"}
	var expected_assets := WorkspaceStore.canonical(stage_root).path_join("assets")
	var mounted_dirs: Array[String] = []
	for raw_line in cfg_text.replace("\r\n", "\n").split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("AddDirRecurse("):
			var q1 := line.find("\"")
			var q2 := line.find("\"", q1 + 1)
			if q1 >= 0 and q2 > q1:
				mounted_dirs.append(line.substr(q1 + 1, q2 - q1 - 1))
	if mounted_dirs.is_empty():
		return {"ok": false, "reason": "MOUNT_PATH_MISMATCH", "error": "ConfigureStream declares no AddDirRecurse paths"}
	var first_mount := mounted_dirs[0]
	if first_mount.to_lower().begins_with("@mydocsdir"):
		return {
			"ok": false,
			"reason": "MOUNT_PATH_MISMATCH",
			"error": "first mount '%s' points to @mydocsdir instead of staged assets '%s'" % [first_mount, _to_win_path(expected_assets)],
		}
	if not _same_path(first_mount, expected_assets):
		return {
			"ok": false,
			"reason": "MOUNT_PATH_MISMATCH",
			"error": "mounted path '%s' does not match staged assets '%s'" % [first_mount, _to_win_path(expected_assets)],
		}
	return {"ok": true, "reason": "", "mounted_dirs": mounted_dirs, "expected_assets": expected_assets}


## Create a single immutable NativeExperimentSession shared across Lua, BZN,
## mount config, staging manifest, runner receipt, and evidence.
static func create_session(stage_root: String, scenario: Dictionary, discovery: Dictionary = {},
		mission_base: String = DEFAULT_MISSION_BASE, terrain_name: String = DEFAULT_TERRAIN_NAME,
		session_id: String = "", launch_nonce: String = "") -> RefCounted:
	return NativeSessionScript.create(stage_root, scenario, discovery, mission_base, terrain_name, session_id, launch_nonce)


## Build the reproducible LuaMission BZN + controlled Lua state machine +
## bzshell_init + exact-mount filesystem config package driven by a single
## NativeExperimentSession so every artifact shares exact immutable identifiers.
static func build_experiment_files_for_session(session: RefCounted, profile: WeaponProfile,
		staged_odfs: Dictionary = {}) -> Dictionary:
	if session == null:
		return {}
	var files := build_experiment_files(
		profile, session.stage_id, staged_odfs, session.stage_root,
		session.session_id, session.launch_nonce, session.mission_basename, session.terrain_name
	)
	session.expected_odf_hashes.clear()
	for raw_rel in files:
		var rel := str(raw_rel).replace("\\", "/")
		if rel.to_lower().ends_with(".odf"):
			var raw = files[raw_rel]
			var bytes: PackedByteArray = raw if raw is PackedByteArray else str(raw).to_utf8_buffer()
			var role := "mount_marker" if rel.get_file().to_lower() == "shaman_mount_marker.odf" else "staged_odf"
			session.set_expected_odf_hash(rel, WorkspaceStore._md5_bytes(bytes), role, "", rel.get_file())
	return files


## Build the reproducible LuaMission BZN + controlled Lua state machine +
## bzshell_init + exact-mount filesystem config package inside an isolated stage.
static func build_experiment_files(profile: WeaponProfile, stage_id: String,
		staged_odfs: Dictionary = {}, stage_root: String = "",
		session_id: String = "", launch_nonce: String = "",
		mission_base: String = DEFAULT_MISSION_BASE,
		terrain_name: String = DEFAULT_TERRAIN_NAME) -> Dictionary:
	var resolved_stage := stage_root if stage_root != "" else WorkspaceStore.canonical("user://native_tests").path_join(stage_id)
	var sid := session_id if session_id != "" else ("sess_" + stage_id)
	var nonce := launch_nonce if launch_nonce != "" else (sid + "_" + str(Time.get_ticks_usec())).md5_text().substr(0, 16)
	var mount := build_mount_plan(resolved_stage, stage_id, sid, mission_base)
	var files: Dictionary = {}
	var primary_odf_cfg := ""
	var primary_odf_md5 := ""
	for raw_rel in staged_odfs:
		var rel := str(raw_rel).replace("\\", "/")
		var target_rel := rel if rel.to_lower().begins_with("assets/") else "assets/" + rel
		files[target_rel] = staged_odfs[raw_rel]
		if primary_odf_cfg == "" and target_rel.to_lower().ends_with(".odf"):
			primary_odf_cfg = target_rel.get_file()
			var raw = staged_odfs[raw_rel]
			var bytes: PackedByteArray = raw if raw is PackedByteArray else str(raw).to_utf8_buffer()
			primary_odf_md5 = WorkspaceStore._md5_bytes(bytes)

	var shooter_cfg := profile.shooter_path.get_file().get_basename() if profile != null else "ivtank_vsr"
	var target_cfg := profile.target_path.get_file().get_basename() if profile != null else "ivscav_vsr"
	var weapon_cfg := profile.weapon_name if profile != null and profile.weapon_name != "" else "gatstabvsr_c"
	var ord_cfg := profile.ordnance_name if profile != null and profile.ordnance_name != "" else "atstabvsr_c"
	var armor_cls := profile.target_armor if profile != null and profile.target_armor != "" else "H"
	if primary_odf_cfg == "":
		primary_odf_cfg = ord_cfg + ".odf"

	# Unique test-only marker ODF mounted from stage assets to verify RESOURCES_MOUNTED in BZCC.
	var marker_val := "SHAMAN_MNT_" + nonce
	files["assets/ODF/shaman_mount_marker.odf"] = "[ShamanMarker]\r\nstageMarker = \"%s\"\r\nsessionId = \"%s\"\r\n" % [marker_val, sid]

	var cfg_lines := [
		"ConfigureFileSystem()",
		"{",
		"\tAppendToMyDocs(\"%s\");" % str(mount.bzcc_mydocs_tag),
		"\tConfigureStream(\"base\")",
		"\t{",
		"\t\tAddDirRecurse(\"%s\");" % str(mount.assets_mount_win),
		"\t\tAddDirRecurse(\"@rootdir\\bz2r_res\");",
		"\t\tAddLangDir(\"@rootdir\\bz2r_loc\");",
		"\t\tAddDir(\"@rootdir\\bz2r_loc\");",
		"\t\tAddDirRecurse(\"@rootdir\\maps\");",
		"\t}",
		"\tSetActiveStream(\"base\");",
		"\tSetPilotsDirectory(\"@mydocsdir\\pilots\");",
		"\tSetSavesDirectory(\"@mydocsdir\\saved\");",
		"}",
	]
	files["shaman_native.cfg"] = "\r\n".join(cfg_lines) + "\r\n"
	files["assets/Config/bzshell_init.cfg"] = "Exec(\"bzgame_init.cfg\");\r\nCmd(\"shell.single.launch %s.bzn\");\r\n" % mission_base
	files["assets/Missions/%s.bzn" % mission_base] = build_minimal_luamission_bzn(mission_base, terrain_name)
	files["assets/Missions/%s.inf" % mission_base] = "[DESCRIPTION]\r\nmissionName = \"SHAMAN Native Shot Probe\"\r\n"
	files["assets/Missions/%s.lua" % mission_base] = _build_controlled_lua_script({
		"session_id": sid,
		"launch_nonce": nonce,
		"scenario_id": "scn_" + weapon_cfg,
		"shooter": shooter_cfg,
		"target": target_cfg,
		"weapon": weapon_cfg,
		"ordnance": ord_cfg,
		"ordnance_odf": primary_odf_cfg,
		"armor": armor_cls,
		"marker_val": marker_val,
		"obs_filename": str(mount.observation_filename),
		"expected_odf_md5": primary_odf_md5,
	})
	return files


static func _build_controlled_lua_script(p: Dictionary) -> String:
	# Uses verified BZCC LuaMission.dll APIs: WriteToFile (writes under
	# @mydocsdir\Logs), PrintConsoleMessage, GetTerrainHeightAndNormal,
	# GetCurHealth/GetMaxHealth/GetHealth, GetTime/GetTPS, OpenODF/GetODFString,
	# BuildObject, GiveWeapon, SetWeaponMask, FireAt, Attack. Never uses io.open.
	# Never invents SHOT_OBSERVED solely from elapsed time (P1-NATIVE-06).
	var lines := [
		"-- Auto-generated controlled BZCC LuaMission probe for BZ_ODF_SHAMAN",
		"-- Event-driven states: INITIALIZING -> OBJECTS_SPAWNED -> WEAPON_ASSIGNED -> READY -> FIRE_REQUESTED -> [FIRE_CONFIRMED] -> HEALTH_DELTA_OBSERVED / IMPACT_CONFIRMED -> MEASUREMENT_COMPLETE | TIMEOUT | FAILED",
		"local SESSION_ID = \"%s\"" % str(p.session_id),
		"local LAUNCH_NONCE = \"%s\"" % str(p.launch_nonce),
		"local SCENARIO_ID = \"%s\"" % str(p.scenario_id),
		"local SHOOTER_ODF = \"%s\"" % str(p.shooter),
		"local TARGET_ODF = \"%s\"" % str(p.target),
		"local WEAPON_ODF = \"%s\"" % str(p.weapon),
		"local ORDNANCE_ODF = \"%s\"" % str(p.ordnance_odf),
		"local ARMOR_CLASS = \"%s\"" % str(p.armor),
		"local EXPECTED_MARKER = \"%s\"" % str(p.marker_val),
		"local OBS_FILE = \"%s\"" % str(p.obs_filename),
		"local EXPECTED_ODF_MD5 = \"%s\"" % str(p.expected_odf_md5),
		"",
		"local state = \"INITIALIZING\"",
		"local shooter, target = nil, nil",
		"local hp_before, hp_max, ratio_before = 0, 0, 1.0",
		"local ammo_before = -1.0",
		"local fire_confirmed = false",
		"local health_delta_observed = false",
		"local shot_count_status = \"SHOT_COUNT_UNKNOWN\"",
		"local start_time, fire_time, impact_time = 0.0, 0.0, 0.0",
		"local odf_probe_damage, odf_probe_speed, odf_probe_life, mount_marker_seen = -1.0, -1.0, -1.0, \"\"",
		"local err_msg = \"\"",
		"local finalized = false",
		"",
		"local function esc(s)",
		"  return tostring(s or \"\"):gsub('\\\\', '\\\\\\\\'):gsub('\"', '\\\\\"')",
		"end",
		"",
		"local function write_observation(final_state, hp_now, ratio_now)",
		"  if finalized then return end",
		"  finalized = true",
		"  state = final_state",
		"  local now_t = GetTime()",
		"  local elapsed = now_t - start_time",
		"  local flight = (impact_time > 0 and fire_time > 0) and (impact_time - fire_time) or 0.0",
		"  local dmg = hp_before - hp_now",
		"  local tps = GetTPS and GetTPS() or 20",
		"  local mounted_ok = (mount_marker_seen == EXPECTED_MARKER) and \"true\" or \"false\"",
		"  local fc_str = fire_confirmed and \"true\" or \"false\"",
		"  local hd_str = health_delta_observed and \"true\" or \"false\"",
		"  -- Expected vs observed ODF semantics: LuaMission has OpenODF/GetODFFloat,",
		"  -- never file hashing, so observed_odf_md5 stays empty instead of echoing",
		"  -- EXPECTED_ODF_MD5 as if Lua computed a digest.",
		"  local json = string.format(",
		"    '{\"contract_version\":2,\"measurement_method\":\"GetCurHealth_delta\",\"session_id\":\"%s\",\"launch_nonce\":\"%s\",\"scenario_id\":\"%s\",\"state\":\"%s\",\"shooter\":\"%s\",\"target\":\"%s\",\"weapon\":\"%s\",\"ordnance\":\"%s\",\"hp_before\":%.3f,\"hp_after\":%.3f,\"hp_max\":%.3f,\"health_ratio_before\":%.6f,\"health_ratio_after\":%.6f,\"damage\":%.3f,\"elapsed_mission_s\":%.4f,\"fire_to_impact_s\":%.4f,\"tps\":%d,\"odf_probe_damage\":%.3f,\"odf_probe_speed\":%.3f,\"odf_probe_life\":%.3f,\"expected_odf_md5\":\"%s\",\"observed_odf_md5\":\"\",\"observed_odf_hash_available\":false,\"mount_marker\":\"%s\",\"resources_mounted\":%s,\"fire_confirmed\":%s,\"health_delta_observed\":%s,\"shot_count_status\":\"%s\",\"error\":\"%s\"}\\n',",
		"    esc(SESSION_ID), esc(LAUNCH_NONCE), esc(SCENARIO_ID), esc(state),",
		"    esc(SHOOTER_ODF), esc(TARGET_ODF), esc(WEAPON_ODF), esc(ORDNANCE_ODF),",
		"    hp_before, hp_now, hp_max, ratio_before, ratio_now, dmg,",
		"    elapsed, flight, tps, odf_probe_damage, odf_probe_speed, odf_probe_life, esc(EXPECTED_ODF_MD5), esc(mount_marker_seen), mounted_ok, fc_str, hd_str, esc(shot_count_status), esc(err_msg)",
		"  )",
		"  WriteToFile(OBS_FILE, json, false)",
		"  PrintConsoleMessage(\"SHAMAN_OBSERVATION_WRITTEN: \" .. OBS_FILE .. \" state=\" .. state)",
		"end",
		"",
		"function Start()",
		"  start_time = GetTime()",
		"  PrintConsoleMessage(\"SHAMAN_STATE: INITIALIZING session=\" .. SESSION_ID)",
		"  local hMarker = OpenODF and OpenODF(\"shaman_mount_marker.odf\") or nil",
		"  if hMarker and GetODFString then",
		"    mount_marker_seen = GetODFString(hMarker, \"ShamanMarker\", \"stageMarker\", \"\") or \"\"",
		"  end",
		"  local hOrd = OpenODF and OpenODF(ORDNANCE_ODF) or nil",
		"  if hOrd and GetODFFloat then",
		"    odf_probe_damage = GetODFFloat(hOrd, \"OrdnanceClass\", \"damageValue(\" .. ARMOR_CLASS .. \")\", -1.0) or -1.0",
		"    odf_probe_speed = GetODFFloat(hOrd, \"OrdnanceClass\", \"shotSpeed\", -1.0) or -1.0",
		"    odf_probe_life = GetODFFloat(hOrd, \"OrdnanceClass\", \"lifeSpan\", -1.0) or -1.0",
		"  end",
		"  local sy = GetTerrainHeightAndNormal and select(1, GetTerrainHeightAndNormal(SetVector(0, 0, 0))) or 10.0",
		"  local ty = GetTerrainHeightAndNormal and select(1, GetTerrainHeightAndNormal(SetVector(0, 0, 80))) or 10.0",
		"  shooter = BuildObject(SHOOTER_ODF, 1, SetVector(0, sy + 2.0, 0))",
		"  target = BuildObject(TARGET_ODF, 2, SetVector(0, ty + 2.0, 80))",
		"  if not IsValid(shooter) or not IsValid(target) then",
		"    err_msg = \"BuildObject failed for shooter or target\"",
		"    write_observation(\"FAILED\", 0, 0)",
		"    return",
		"  end",
		"  state = \"OBJECTS_SPAWNED\"",
		"  hp_before = GetCurHealth(target)",
		"  hp_max = GetMaxHealth(target)",
		"  ratio_before = GetHealth(target)",
		"  GiveWeapon(shooter, WEAPON_ODF)",
		"  if SetWeaponMask then SetWeaponMask(shooter, 1) end",
		"  if GetCurAmmo then ammo_before = GetCurAmmo(shooter) end",
		"  state = \"WEAPON_ASSIGNED\"",
		"  state = \"READY\"",
		"  fire_time = GetTime()",
		"  Attack(shooter, target, 1)",
		"  if FireAt then FireAt(shooter, target, true) end",
		"  state = \"FIRE_REQUESTED\"",
		"  PrintConsoleMessage(\"SHAMAN_STATE: FIRE_REQUESTED hp_before=\" .. tostring(hp_before))",
		"end",
		"",
		"function Update()",
		"  if finalized then return end",
		"  local elapsed = GetTime() - start_time",
		"  local alive = IsValid(target)",
		"  local hp_now = alive and GetCurHealth(target) or 0",
		"  local ratio_now = alive and GetHealth(target) or 0.0",
		"  if not fire_confirmed and IsValid(shooter) and GetCurAmmo and ammo_before >= 0 then",
		"    local ammo_now = GetCurAmmo(shooter)",
		"    if ammo_now < ammo_before then",
		"      fire_confirmed = true",
		"      shot_count_status = \"AMMO_DELTA_CONFIRMED\"",
		"      state = \"FIRE_CONFIRMED\"",
		"    end",
		"  end",
		"  if hp_now < hp_before then",
		"    impact_time = GetTime()",
		"    health_delta_observed = true",
		"    state = fire_confirmed and \"IMPACT_CONFIRMED\" or \"HEALTH_DELTA_OBSERVED\"",
		"    write_observation(\"MEASUREMENT_COMPLETE\", hp_now, ratio_now)",
		"    return",
		"  end",
		"  if elapsed >= 8.0 then",
		"    err_msg = \"timeout waiting for impact\"",
		"    write_observation(\"TIMEOUT\", hp_now, ratio_now)",
		"  end",
		"end",
	]
	return "\n".join(lines) + "\n"


## Compute lowercase hex SHA256 digest of raw bytes (used for operator handoff
## provenance when preparing a controlled @rootdir config placement).
static func sha256_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode().to_lower()


## Read-only inspection of stock `bzone.cfg` verifying whether BZCC mounts
## `@mydocsdir\addon` first in `ConfigureStream("base")`. Never mutates BZ2R.
static func inspect_stock_bzone_cfg(game_root: String = DEFAULT_GAME_ROOT) -> Dictionary:
	var cfg_path := WorkspaceStore.canonical(game_root).path_join("bzone.cfg")
	if not FileAccess.file_exists(cfg_path):
		return {
			"ok": false,
			"exists": false,
			"path": cfg_path,
			"mounts_addon_first": false,
			"first_mount": "",
			"reason": "STOCK_BZONE_CFG_MISSING",
		}
	var txt := FileAccess.get_file_as_string(cfg_path)
	var mounts: Array[String] = []
	for raw_line in txt.replace("\r\n", "\n").split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("//"):
			continue
		if line.begins_with("AddDirRecurse("):
			var q1 := line.find("\"")
			var q2 := line.find("\"", q1 + 1)
			if q1 >= 0 and q2 > q1:
				mounts.append(line.substr(q1 + 1, q2 - q1 - 1))
	var first_m := mounts[0] if not mounts.is_empty() else ""
	var addon_first := first_m.to_lower().replace("/", "\\") == "@mydocsdir\\addon"
	return {
		"ok": addon_first,
		"exists": true,
		"path": cfg_path,
		"mounts_addon_first": addon_first,
		"first_mount": first_m,
		"mounts": mounts,
		"reason": "" if addon_first else "STOCK_ADDON_MOUNT_NOT_FIRST",
	}


## Build a safe stock-addon staging plan under My Documents
## (`Documents/My Games/Battlezone Combat Commander/addon/SHAMAN_<stage_id>`).
## Zero writes to BZ2R or Workshop; stock `bzone.cfg` mounts `@mydocsdir\addon` first.
static func build_stock_addon_stage_plan(stage_id: String, session_id: String = "",
		mission_base: String = DEFAULT_MISSION_BASE, docs_override: String = "") -> Dictionary:
	var docs := WorkspaceStore.canonical(docs_override if docs_override != "" else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
	var bz_docs := docs.path_join("My Games/Battlezone Combat Commander") if docs != "" else ""
	var addon_base := bz_docs.path_join("addon") if bz_docs != "" else ""
	var safe_id := stage_id.strip_edges().replace("/", "_").replace("\\", "_").replace(" ", "_").replace("..", "_")
	if safe_id == "":
		safe_id = "stage_" + str(Time.get_ticks_usec())
	if not safe_id.begins_with("SHAMAN_"):
		safe_id = "SHAMAN_" + safe_id
	var stage_root := addon_base.path_join(safe_id) if addon_base != "" else ""
	var sid := session_id if session_id != "" else safe_id
	var safe_sid := sid.replace("/", "_").replace("\\", "_").replace(" ", "_")
	var logs_dir := bz_docs.path_join("Logs") if bz_docs != "" else ""
	var obs_filename := "shaman_obs_%s.json" % safe_sid
	return {
		"launch_mode": "STOCK_ADDON",
		"addon_base": addon_base,
		"stage_id": safe_id,
		"stage_absolute_path": stage_root,
		"assets_mount_path": stage_root.path_join("assets") if stage_root != "" else "",
		"assets_mount_win": _to_win_path(stage_root.path_join("assets")) if stage_root != "" else "",
		"bzcc_writable_profile_dir": bz_docs,
		"bzcc_logs_dir": logs_dir,
		"startup_log_path": bz_docs.path_join("battlezone.log") if bz_docs != "" else "",
		"observation_filename": obs_filename,
		"observation_expected_path": logs_dir.path_join(obs_filename) if logs_dir != "" else "",
		"mission_bzn": mission_base + ".bzn",
		"mission_lua": mission_base + ".lua",
	}


## Prepare a controlled operator fallback descriptor for placing a generated
## `.cfg` inside `@rootdir` (BZ2R). Strictly read-only: computes SHA256, checks
## for destination filename collision, and requires explicit operator approval.
static func prepare_rootdir_config_handoff(cfg_path: String, game_root: String = DEFAULT_GAME_ROOT,
		cfg_bytes: PackedByteArray = PackedByteArray()) -> Dictionary:
	var c_cfg := WorkspaceStore.canonical(cfg_path)
	var c_root := WorkspaceStore.canonical(game_root)
	var bare_name := c_cfg.get_file()
	if bare_name == "":
		bare_name = "shaman_native.cfg"
	var dest_path := c_root.path_join(bare_name)
	var raw := cfg_bytes
	if raw.is_empty() and c_cfg != "" and FileAccess.file_exists(c_cfg):
		raw = FileAccess.get_file_as_bytes(c_cfg)
	var sha256 := sha256_bytes(raw) if not raw.is_empty() else ""
	var collision := FileAccess.file_exists(dest_path)
	return {
		"source_path": _to_win_path(c_cfg),
		"destination_path": _to_win_path(dest_path),
		"recommended_filename": bare_name,
		"sha256": sha256,
		"byte_length": raw.size(),
		"collision_detected": collision,
		"requires_operator_approval": true,
		"auto_write_permitted": false,
		"warning": ("Destination file '%s' already exists in BZ2R; back up existing file before copying or choose a unique filename." % bare_name) if collision else "",
	}


## Diagnose whether a `/config` path can be opened by BZCC 2.0.185's
## select_bzone_cfg (i76win.cpp RVA 0xfbc34), which only loads bare filenames
## inside @rootdir and skips ConfigureFileSystem() for arbitrary absolute or
## parent-traversal paths outside BZ2R.
static func diagnose_config_path_compatibility(cfg_path: String, game_root: String = DEFAULT_GAME_ROOT) -> Dictionary:
	var c_cfg := WorkspaceStore.canonical(cfg_path)
	var c_root := WorkspaceStore.canonical(game_root)
	var cfg_dir := c_cfg.get_base_dir()
	var in_root := _same_path(cfg_dir, c_root)
	var bare_name := c_cfg.get_file()
	return {
		"ok": in_root,
		"in_game_root": in_root,
		"config_arg": bare_name if in_root else _to_win_path(c_cfg),
		"recommended_rootdir_filename": bare_name,
		"requires_rootdir_placement": not in_root,
		"code": "CONFIG_IN_ROOTDIR" if in_root else "CONFIG_REQUIRES_ROOTDIR_PLACEMENT",
		"warning": "" if in_root else (
			"BZCC 2.0.185 /config only resolves bare filenames inside @rootdir (%s). " % _to_win_path(c_root)
			+ "Passing an external path causes BZCC to skip ConfigureFileSystem() and fail loading ds_16.bmf. "
			+ "BZ2R is kept strictly read-only; operator may copy %s into @rootdir and pass /config %s." % [_to_win_path(c_cfg), bare_name]
		),
	}


## Classify a BZCC startup failure from startup log text and/or fatal dialog
## text without conflating unmounted `/config` paths with missing game fonts.
static func classify_startup_failure(log_text: String, dialog_text: String = "") -> Dictionary:
	var low_log := log_text.to_lower()
	var low_dlg := dialog_text.to_lower()
	var used_cmd_config := low_log.contains("command line /config used")
	var has_mounts := low_log.contains("config: 'adddirrecurse'") or low_log.contains("adding recurse")
	var mentions_font := low_dlg.contains("ds_16.bmf") or low_dlg.contains("ds16.brf") or low_dlg.contains("unable to load console font") or low_log.contains("ds_16.bmf")
	if used_cmd_config and not has_mounts:
		return {
			"code": "CONFIG_PATH_NOT_LOADED_NO_FILESYS",
			"cause": "SHAMAN_OR_CMDLINE_CONFIG_OUTSIDE_ROOTDIR",
			"font_missing_externally": false,
			"stock_resources_mounted": false,
			"detail": "BZCC recognized /config but parsed zero AddDirRecurse mounts; @rootdir\\bz2r_res was never mounted so stock ds_16.bmf could not load.",
		}
	if mentions_font and has_mounts:
		return {
			"code": "EXTERNAL_MISSING_FONT",
			"cause": "GAME_INSTALLATION_RESOURCE_MISSING",
			"font_missing_externally": true,
			"stock_resources_mounted": true,
			"detail": "Console font ds_16.bmf failed to load even after bz2r_res mounted; verify Steam game files.",
		}
	if low_dlg.contains("launch game with custom arguments"):
		return {
			"code": "STEAM_CUSTOM_ARGS_MODAL_PENDING",
			"cause": "STEAM_CONFIRMATION_REQUIRED",
			"font_missing_externally": false,
			"stock_resources_mounted": has_mounts,
			"detail": "Steam requires interactive Continue confirmation for custom launch arguments.",
		}
	if has_mounts:
		return {
			"code": "STARTUP_FILESYS_MOUNTED",
			"cause": "NONE",
			"font_missing_externally": false,
			"stock_resources_mounted": true,
			"detail": "BZCC mounted filesystem streams normally.",
		}
	return {
		"code": "UNKNOWN_STARTUP_STATE",
		"cause": "INSUFFICIENT_LOG_EVIDENCE",
		"font_missing_externally": false,
		"stock_resources_mounted": false,
		"detail": "Log lacks /config and filesys lines.",
	}


## Correlate BZCC startup/crash logs against a specific SHAMAN session instead
## of blindly picking the newest Battlezone-Crashed*.log file (P1-EVIDENCE-01).
static func correlate_crash_logs(docs_dir: String, session_info: Dictionary,
		launch_started_unix: int = 0) -> Dictionary:
	var result := {
		"matched": false,
		"confidence": "UNRELATED",
		"selected_log": "",
		"selected_score": 0,
		"selected_tail": "",
		"candidates": [],
	}
	var dir := DirAccess.open(docs_dir)
	if dir == null:
		return result
	var stage_root := str(session_info.get("stage_root", "")).replace("/", "\\").to_lower()
	var stage_id := str(session_info.get("stage_id", "")).to_lower()
	var session_id := str(session_info.get("session_id", "")).to_lower()
	var cfg_name := str(session_info.get("config_path", "")).get_file().to_lower()
	var mission_bzn := str(session_info.get("mission_bzn", DEFAULT_MISSION_BASE + ".bzn")).to_lower()
	var best_score := -1
	var best_path := ""
	var best_tail := ""
	var best_conf := "UNRELATED"
	for name in dir.get_files():
		var sname := str(name)
		var low_name := sname.to_lower()
		if not low_name.ends_with(".log"):
			continue
		if not (low_name.begins_with("battlezone-crashed") or low_name.begins_with("battlezone ")):
			continue
		var full := docs_dir.path_join(sname)
		var mtime := int(FileAccess.get_modified_time(full))
		var txt := FileAccess.get_file_as_string(full)
		var low_txt := txt.to_lower()
		var score := 0
		var reasons: Array[String] = []
		var time_ok := launch_started_unix <= 0 or mtime >= (launch_started_unix - 2)
		if not time_ok:
			reasons.append("predates_launch")
		if stage_root != "" and (low_txt.contains(stage_root) or low_txt.contains(stage_root.replace("\\", "/"))):
			score += 60
			reasons.append("stage_root_match")
		if stage_id != "" and low_txt.contains(stage_id):
			score += 40
			reasons.append("stage_id_match")
		if session_id != "" and low_txt.contains(session_id):
			score += 50
			reasons.append("session_id_match")
		if cfg_name != "" and low_txt.contains(cfg_name):
			score += 25
			reasons.append("config_name_match")
		if mission_bzn != "" and low_txt.contains(mission_bzn):
			score += 25
			reasons.append("mission_bzn_match")
		if time_ok and launch_started_unix > 0:
			var delta := absi(mtime - launch_started_unix)
			if delta <= 180:
				score += 10
				reasons.append("timestamp_window")
		var conf := "UNRELATED"
		if score >= 60 and time_ok:
			conf = "CONFIRMED"
		elif score >= 35 and time_ok:
			conf = "HIGH"
		elif score >= 10 and time_ok:
			conf = "POSSIBLY_RELATED_LOG"
		var cand := {
			"path": full,
			"name": sname,
			"mtime": mtime,
			"score": score,
			"confidence": conf,
			"reasons": reasons,
		}
		(result["candidates"] as Array).append(cand)
		if time_ok and score > best_score and conf != "UNRELATED":
			best_score = score
			best_path = full
			best_conf = conf
			var lines := txt.split("\n")
			var tail_arr: Array[String] = []
			for i in range(maxi(0, lines.size() - 16), lines.size()):
				tail_arr.append(str(lines[i]).strip_edges())
			best_tail = "\n".join(tail_arr)
	if best_path != "":
		result["matched"] = best_conf in ["CONFIRMED", "HIGH"]
		result["confidence"] = best_conf
		result["selected_log"] = best_path
		result["selected_score"] = best_score
		result["selected_tail"] = best_tail
	return result


## Build exact launch command descriptor for a given launch capability route.
## `/logconsole` is opt-in (default false) so SHAMAN never injects extra flags
## behind the operator's back (P0-NATIVE-01).
## Supports `launch_mode = "STOCK_ADDON"` (stock bzone.cfg mounts `@mydocsdir\addon`
## first without external `/config`) as well as `"CUSTOM_CONFIG"`.
static func build_launch_command(route: String, discovery: Dictionary, cfg_path: String,
		mission_bzn: String = DEFAULT_MISSION_BASE + ".bzn",
		include_logconsole: bool = false,
		launch_mode: String = "CUSTOM_CONFIG") -> Dictionary:
	var game_root := str(discovery.get("game_root", DEFAULT_GAME_ROOT))
	var is_stock_addon := launch_mode.strip_edges().to_upper() == "STOCK_ADDON"
	var cfg_diag: Dictionary
	var game_args: Array[String] = ["/nointro", "/win"]
	if include_logconsole:
		game_args.append("/logconsole")
	var flags_prefix := "/nointro /win /logconsole" if include_logconsole else "/nointro /win"
	var launch_opts_text := ""
	if is_stock_addon:
		var stock_chk := inspect_stock_bzone_cfg(game_root)
		var addon_ok := bool(stock_chk.get("ok", false))
		cfg_diag = {
			"ok": addon_ok,
			"in_game_root": false,
			"stock_addon_route": true,
			"config_arg": "",
			"recommended_rootdir_filename": "",
			"requires_rootdir_placement": false,
			"code": "CONFIG_STOCK_ADDON_ROUTE" if addon_ok else str(stock_chk.get("reason", "STOCK_ADDON_MOUNT_NOT_FIRST")),
			"warning": "" if addon_ok else "Stock bzone.cfg does not mount @mydocsdir\\addon first; stock addon route unavailable.",
			"stock_bzone_cfg": stock_chk,
		}
		game_args.append(mission_bzn)
		launch_opts_text = "%s \"%s\"" % [flags_prefix, mission_bzn]
	else:
		cfg_diag = diagnose_config_path_compatibility(cfg_path, game_root)
		var cfg_arg := str(cfg_diag.get("config_arg", _to_win_path(cfg_path)))
		game_args.append_array(["/config", cfg_arg, mission_bzn])
		launch_opts_text = "%s /config \"%s\" \"%s\"" % [flags_prefix, cfg_arg, mission_bzn]
	match route:
		"STEAM_MANAGED":
			var steam_exe := str(discovery.get("steam_exe", ""))
			var sargs: Array[String] = ["-applaunch", STEAM_APP_ID]
			sargs.append_array(game_args)
			return {
				"route": "STEAM_MANAGED",
				"launch_mode": "STOCK_ADDON" if is_stock_addon else "CUSTOM_CONFIG",
				"executable": steam_exe,
				"args": sargs,
				"game_args": game_args,
				"include_logconsole": include_logconsole,
				"config_diagnostics": cfg_diag,
				"steam_app_id": STEAM_APP_ID,
				"game_version": str(discovery.get("build_id", "UNKNOWN")),
				"supported": steam_exe != "" and FileAccess.file_exists(steam_exe),
			}
		"STEAM_LAUNCH_OPTIONS":
			return {
				"route": "STEAM_LAUNCH_OPTIONS",
				"launch_mode": "STOCK_ADDON" if is_stock_addon else "CUSTOM_CONFIG",
				"executable": str(discovery.get("steam_exe", "")),
				"args": game_args,
				"game_args": game_args,
				"include_logconsole": include_logconsole,
				"config_diagnostics": cfg_diag,
				"launch_options_text": launch_opts_text,
				"steam_app_id": STEAM_APP_ID,
				"game_version": str(discovery.get("build_id", "UNKNOWN")),
				"supported": str(discovery.get("steam_exe", "")) != "",
			}
		"OPERATOR_MANUAL":
			return {
				"route": "OPERATOR_MANUAL",
				"launch_mode": "STOCK_ADDON" if is_stock_addon else "CUSTOM_CONFIG",
				"executable": str(discovery.get("steam_exe", "")),
				"args": game_args,
				"game_args": game_args,
				"include_logconsole": include_logconsole,
				"config_diagnostics": cfg_diag,
				"launch_options_text": launch_opts_text,
				"steam_app_id": STEAM_APP_ID,
				"game_version": str(discovery.get("build_id", "UNKNOWN")),
				"instructions": "Log into Steam for AppID %s and launch BZCC with %s%s" % [
					STEAM_APP_ID, launch_opts_text,
					(" (Note: " + str(cfg_diag.warning) + ")") if str(cfg_diag.warning) != "" else ""
				],
				"supported": true,
			}
		"DIRECT_EXECUTABLE":
			return {
				"route": "DIRECT_EXECUTABLE",
				"launch_mode": "STOCK_ADDON" if is_stock_addon else "CUSTOM_CONFIG",
				"executable": str(discovery.get("exe", "")),
				"args": game_args,
				"game_args": game_args,
				"include_logconsole": include_logconsole,
				"config_diagnostics": cfg_diag,
				"steam_app_id": STEAM_APP_ID,
				"game_version": str(discovery.get("build_id", "UNKNOWN")),
				"supported": bool(discovery.get("ok", false)),
			}
		_:
			return {
				"route": "UNSUPPORTED",
				"launch_mode": "STOCK_ADDON" if is_stock_addon else "CUSTOM_CONFIG",
				"executable": "",
				"args": [],
				"game_args": [],
				"include_logconsole": include_logconsole,
				"config_diagnostics": cfg_diag,
				"steam_app_id": STEAM_APP_ID,
				"game_version": str(discovery.get("build_id", "UNKNOWN")),
				"supported": false,
			}


## Classify launch outcomes cleanly so Steam handoff (exit 53) is never
## misclassified as a broken install, and game-process startup alone never
## counts as mission success or NATIVE_VERIFIED.
static func classify_launch_result(route: String, exit_code: int, process_seen: bool,
		mission_loaded: bool, observation_captured: bool, timed_out: bool) -> Dictionary:
	if timed_out:
		return {
			"state": "TIMEOUT",
			"reason": "LAUNCH_OR_OBSERVATION_TIMEOUT",
			"handoff": false,
			"mission_ok": false,
			"verified": false,
		}
	if route == "DIRECT_EXECUTABLE" and exit_code == 53 and not process_seen:
		return {
			"state": "LAUNCH_REQUESTED",
			"reason": "STEAM_HANDOFF_REQUIRED",
			"handoff": true,
			"mission_ok": false,
			"verified": false,
		}
	if not process_seen:
		return {
			"state": "FAILED",
			"reason": "GAME_PROCESS_NOT_STARTED",
			"handoff": false,
			"mission_ok": false,
			"verified": false,
		}
	if not mission_loaded:
		return {
			"state": "GAME_STARTED",
			"reason": "MISSION_NOT_LOADED",
			"handoff": false,
			"mission_ok": false,
			"verified": false,
		}
	if not observation_captured:
		return {
			"state": "MISSION_LOADED",
			"reason": "OBSERVATION_MISSING",
			"handoff": false,
			"mission_ok": true,
			"verified": false,
		}
	return {
		"state": "OBSERVATION_CAPTURED",
		"reason": "",
		"handoff": false,
		"mission_ok": true,
		"verified": false,
	}


## Stage a scenario under an isolated allowlisted root via SafeStageManager.
## `files` maps a relative path to PackedByteArray or String.
## When `session` is provided, every identifier (session_id, launch_nonce,
## stage_id, mount_plan, scenario_hash, expected_odf_hashes) is inherited from
## that single immutable NativeExperimentSession.
static func stage_scenario(stage_root: String, files: Dictionary, scenario: Dictionary,
		discovery: Dictionary = {}, dry_run: bool = false,
		session: RefCounted = null, options: Dictionary = {}) -> Dictionary:
	var is_stock_addon := str(options.get("launch_mode", "")).strip_edges().to_upper() == "STOCK_ADDON"
	if not is_stock_addon and session != null and str(session.mount_plan.get("launch_mode", "")).to_upper() == "STOCK_ADDON":
		is_stock_addon = true
	var stage_leaf := WorkspaceStore.canonical(stage_root).get_file()
	var allow_addon := is_stock_addon and stage_leaf.begins_with("SHAMAN_")
	var extra_protected := _extra_protected_from_discovery(discovery, allow_addon)
	var stage_opts := options.duplicate(true)
	if session != null and str(stage_opts.get("stage_id", "")) == "":
		stage_opts["stage_id"] = session.stage_id
	var stage_res := SafeStageScript.stage(stage_root, files, {"scenario": scenario}, dry_run, extra_protected, stage_opts)
	if not bool(stage_res.get("ok", false)):
		return stage_res
	if dry_run:
		return stage_res
	var stage := str(stage_res.get("stage", ""))
	var staged: Array = stage_res.get("staged", [])
	var scenario_copy: Dictionary = (session.scenario as Dictionary).duplicate(true) if session != null else scenario.duplicate(true)
	if str(scenario_copy.get("id", "")) == "":
		scenario_copy["id"] = str(stage_res.get("stage_id", "scenario_" + str(Time.get_ticks_usec())))
	var stage_id: String = str(session.stage_id) if session != null else str(stage_res.get("stage_id", ""))
	var sid: String = str(session.session_id) if session != null else str(scenario_copy.get("session_id", ""))
	var nonce: String = str(session.launch_nonce) if session != null else str(scenario_copy.get("launch_nonce", ""))
	var mount_plan: Dictionary = (session.mount_plan as Dictionary).duplicate(true) if session != null else build_mount_plan(stage, stage_id, sid)
	var expected_odf_hashes: Dictionary = {}
	if session != null and not (session.expected_odf_hashes as Dictionary).is_empty():
		expected_odf_hashes = (session.expected_odf_hashes as Dictionary).duplicate(true)
	for item in staged:
		if item is Dictionary and str(item.get("rel", "")).to_lower().ends_with(".odf"):
			var rel := str(item.get("rel", ""))
			var md5 := str(item.get("md5", "")).to_lower()
			var role := "mount_marker" if rel.get_file().to_lower() == "shaman_mount_marker.odf" else "staged_odf"
			expected_odf_hashes[rel] = {
				"rel": rel,
				"md5": md5,
				"role": role,
				"odf_name": rel.get_file(),
				"source": "staged_disk_md5",
			}
			if session != null:
				session.set_expected_odf_hash(rel, md5, role, "", rel.get_file())

	var scn_hash: String = str(session.scenario_hash) if session != null else _hash_dict(scenario_copy)
	var evidence := {
		"schema": 4,
		"created": Time.get_datetime_string_from_system(),
		"status": "STAGED",
		"session_id": sid,
		"launch_nonce": nonce,
		"stage_id": stage_id,
		"staging_manifest": str(stage_res.get("manifest", "")),
		"mount_plan": mount_plan,
		"mount_marker": session.mount_marker if session != null else "",
		"resources_mounted": false,
		"game": discovery,
		"scenario": scenario_copy,
		"scenario_hash": scn_hash,
		"staged": staged,
		"expected_odf_hashes": expected_odf_hashes,
		"observed_odf_hashes": {},
		"launch_record": {
			"executed": false,
			"route": "UNSUPPORTED",
			"exe": str(discovery.get("exe", "")),
			"launch_args": [],
			"exit_code": -1,
			"process_id": 0,
			"process_start_time": "",
			"mission_loaded_at": "",
			"launched_at": "",
		},
		"session_receipt": {},
		"native_observation": {},
		"comparison": {},
		"godot_prediction": scenario_copy.get("godot_prediction", {}),
		"difference": "",
		"limitations": LIMITATIONS,
	}
	var manifest := stage.path_join(MANIFEST_NAME)
	var write := WorkspaceStore.atomic_write_abs(manifest, JSON.stringify(evidence, "  ").to_utf8_buffer())
	if not bool(write.get("ok", false)):
		SafeStageScript.cleanup(stage, extra_protected)
		return {"ok": false, "stage": stage, "error": "evidence manifest write failed", "staged": staged}
	var sm_path := str(stage_res.get("manifest", ""))
	if session != null:
		session.stage_manifest_path = sm_path
		session.stage_manifest_hash = FileAccess.get_md5(sm_path) if sm_path != "" and FileAccess.file_exists(sm_path) else ""
		session.evidence_path = manifest
		session.add_checkpoint("STAGED", "Staged %d file(s) under %s" % [staged.size(), stage])
	return {
		"ok": true,
		"stage": stage,
		"stage_id": stage_id,
		"session_id": sid,
		"launch_nonce": nonce,
		"manifest": manifest,
		"stage_manifest": sm_path,
		"mount_plan": mount_plan,
		"evidence": evidence,
		"staged": staged,
	}


## Register a runner-controlled trusted session receipt in process-local memory.
## When `session` is provided (recommended), inherits its immutable session_id,
## launch_nonce, stage_id, scenario_hash, mount_marker, and expected_odf_hashes.
static func begin_trusted_session(stage_result: Dictionary, discovery: Dictionary,
		scenario: Dictionary, launch_route: String = "STEAM_MANAGED",
		session: RefCounted = null) -> Dictionary:
	return _register_session_receipt(stage_result, discovery, scenario, launch_route, session, "RUNNER_ATTESTED", false)


## Register an explicitly synthetic test-only session receipt. Such sessions
## remain clearly marked `synthetic = true`, `attestation_mode = "SYNTHETIC_TEST"`
## and can NEVER pass `is_native_verified()` or claim `NATIVE_VERIFIED`.
static func begin_synthetic_session(stage_result: Dictionary, discovery: Dictionary,
		scenario: Dictionary, launch_route: String = "OPERATOR_MANUAL",
		session: RefCounted = null) -> Dictionary:
	return _register_session_receipt(stage_result, discovery, scenario, launch_route, session, "SYNTHETIC_TEST", true)


static func _register_session_receipt(stage_result: Dictionary, discovery: Dictionary,
		scenario: Dictionary, launch_route: String, session: RefCounted,
		attestation_mode: String, is_synthetic: bool) -> Dictionary:
	_session_seq += 1
	var stage_manifest := str(stage_result.get("stage_manifest", ""))
	var sm_hash := FileAccess.get_md5(stage_manifest) if stage_manifest != "" and FileAccess.file_exists(stage_manifest) else ""
	var ev_in: Dictionary = stage_result.get("evidence", {}) if stage_result.get("evidence", {}) is Dictionary else {}
	var sid := ""
	var nonce := ""
	var stage_id := str(stage_result.get("stage_id", ""))
	var mount_marker := ""
	if session != null:
		sid = session.session_id
		nonce = session.launch_nonce
		stage_id = session.stage_id
		mount_marker = session.mount_marker
	else:
		sid = str(ev_in.get("session_id", "")).strip_edges()
		nonce = str(ev_in.get("launch_nonce", "")).strip_edges()
		mount_marker = str(ev_in.get("mount_marker", "")).strip_edges()
	if sid == "":
		sid = "shaman_sess_%d_%d" % [Time.get_ticks_usec(), _session_seq]
	if nonce == "":
		nonce = ("%s|%s|%d" % [sid, sm_hash, randi()]).md5_text()
	var scenario_copy: Dictionary = (session.scenario as Dictionary).duplicate(true) if session != null else scenario.duplicate(true)
	if str(scenario_copy.get("id", "")) == "":
		scenario_copy["id"] = stage_id if stage_id != "" else sid
	var scn_hash: String = str(session.scenario_hash) if session != null else (str(ev_in.get("scenario_hash", "")) if str(ev_in.get("scenario_hash", "")) != "" else _hash_dict(scenario_copy))
	var odf_hashes: Dictionary = {}
	for item in stage_result.get("staged", []):
		if item is Dictionary and str(item.get("rel", "")).to_lower().ends_with(".odf"):
			odf_hashes[str(item.get("rel", ""))] = str(item.get("md5", "")).to_lower()
	var expected_hashes: Dictionary = (session.expected_odf_hashes as Dictionary).duplicate(true) if session != null else (ev_in.get("expected_odf_hashes", {}) as Dictionary).duplicate(true)
	var receipt := {
		"session_id": sid,
		"launch_nonce": nonce,
		"stage_id": stage_id,
		"stage_root": str(stage_result.get("stage", session.stage_root if session != null else "")),
		"scenario_id": str(scenario_copy.get("id", "")),
		"scenario_hash": scn_hash,
		"staging_manifest": stage_manifest,
		"staging_manifest_hash": sm_hash,
		"executable_hash": str(discovery.get("exe_md5", "")),
		"staged_odf_hashes": odf_hashes,
		"expected_odf_hashes": expected_hashes,
		"mount_marker": mount_marker,
		"launch_route": launch_route,
		"attestation_mode": attestation_mode,
		"synthetic": is_synthetic,
		"process_id": 0,
		"process_start_time": "",
		"mission_loaded_at": "",
		"resources_mounted": false,
		"startup_log_path": "",
		"observation_artifact_path": "",
		"observation_artifact_hash": "",
		"observation_capture_method": "",
		"comparison_hash": "",
		"execution_confirmed": false,
		"observation_confirmed": false,
	}
	_trusted_sessions[sid] = receipt
	return receipt.duplicate(true)


## Runner controller hook: attest that an actual BZCC process ran for `session_id`
## and whether the staged resources & target mission loaded.
static func confirm_trusted_execution(session_id: String, process_id: int,
		process_start_time: String, launch_route: String, launch_args: Array,
		exit_code: int, mission_loaded_at: String = "",
		startup_log_path: String = "", resources_mounted: bool = false) -> Dictionary:
	if not _trusted_sessions.has(session_id):
		return {"ok": false, "reason": "UNKNOWN_TRUSTED_SESSION"}
	if process_id <= 0 or process_start_time == "":
		return {"ok": false, "reason": "INVALID_PROCESS_IDENTITY"}
	if not LAUNCH_ROUTES.has(launch_route) or launch_route == "UNSUPPORTED":
		return {"ok": false, "reason": "INVALID_LAUNCH_ROUTE"}
	var receipt: Dictionary = _trusted_sessions[session_id]
	receipt["process_id"] = process_id
	receipt["process_start_time"] = process_start_time
	receipt["launch_route"] = launch_route
	receipt["launch_args"] = launch_args.duplicate()
	receipt["exit_code"] = exit_code
	receipt["mission_loaded_at"] = mission_loaded_at
	receipt["startup_log_path"] = startup_log_path
	receipt["resources_mounted"] = resources_mounted
	receipt["execution_confirmed"] = (mission_loaded_at != "") and not bool(receipt.get("synthetic", false))
	_trusted_sessions[session_id] = receipt
	return {"ok": true, "receipt": receipt.duplicate(true)}


## Verify every staged ODF recorded in `staged_odf_hashes` still exists on disk
## under `stage_root` with the exact expected MD5 digest.
static func verify_staged_odf_hashes_on_disk(stage_root: String, staged_odf_hashes: Dictionary) -> Dictionary:
	var checked := 0
	var mismatches: Array[Dictionary] = []
	var root := WorkspaceStore.canonical(stage_root)
	for rel in staged_odf_hashes:
		var expected := ""
		var entry = staged_odf_hashes[rel]
		if entry is Dictionary:
			expected = str(entry.get("md5", "")).to_lower()
		else:
			expected = str(entry).to_lower()
		var target := WorkspaceStore.canonical(root.path_join(str(rel)))
		checked += 1
		if not FileAccess.file_exists(target):
			mismatches.append({"rel": str(rel), "reason": "MISSING_STAGED_ODF", "expected_md5": expected, "actual_md5": ""})
			continue
		var actual := FileAccess.get_md5(target).to_lower()
		if expected != "" and actual != expected:
			mismatches.append({"rel": str(rel), "reason": "STAGED_ODF_DRIFT", "expected_md5": expected, "actual_md5": actual})
	return {"ok": mismatches.is_empty(), "checked": checked, "mismatches": mismatches}


## Runner controller hook: bind an on-disk observation JSON artifact to a
## trusted session, verify session ID, nonce, mount marker, expected-vs-observed
## ODF hash semantics, and scenario revision, and compute the Godot-vs-native comparison.
static func capture_trusted_observation(evidence: Dictionary, session_id: String,
		observation_path: String, godot_prediction: Dictionary,
		capture_method: String = "bzcc_luamission_writetofile") -> Dictionary:
	var updated := evidence.duplicate(true)
	updated.erase("capture_error")
	updated.erase("capture_parse_error")
	if not _trusted_sessions.has(session_id):
		updated["status"] = "FAILED"
		updated["capture_error"] = "UNKNOWN_TRUSTED_SESSION"
		return updated
	var method_lc := capture_method.strip_edges().to_lower()
	if method_lc == "" or method_lc == "synthetic" or method_lc == "forged" or method_lc == "manual" or method_lc == "mock":
		updated["status"] = "FAILED"
		updated["capture_error"] = "SYNTHETIC_CAPTURE_METHOD"
		return updated
	if observation_path == "" or not FileAccess.file_exists(observation_path):
		updated["status"] = "MISSION_LOADED"
		updated["capture_error"] = "OBSERVATION_ARTIFACT_MISSING"
		return updated
	var obs_jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(observation_path))
	if not bool(obs_jres.get("ok", false)) or not (obs_jres.get("data", null) is Dictionary):
		updated["status"] = "FAILED"
		updated["capture_error"] = "OBSERVATION_JSON_INVALID"
		updated["capture_parse_error"] = str(obs_jres.get("error", "invalid JSON"))
		return updated
	var obs_parsed: Dictionary = obs_jres.get("data", {})
	if bool(obs_parsed.get("synthetic", false)):
		updated["status"] = "FAILED"
		updated["capture_error"] = "SYNTHETIC_OBSERVATION_REJECTED"
		return updated
	var receipt: Dictionary = _trusted_sessions[session_id]
	if str(obs_parsed.get("session_id", "")) != session_id:
		updated["status"] = "FAILED"
		updated["capture_error"] = "SESSION_ID_MISMATCH"
		return updated
	var obs_nonce := str(obs_parsed.get("launch_nonce", ""))
	if str(receipt.get("launch_nonce", "")) != "" and obs_nonce != str(receipt.get("launch_nonce", "")):
		updated["status"] = "FAILED"
		updated["capture_error"] = "LAUNCH_NONCE_MISMATCH"
		return updated
	var expected_marker := str(receipt.get("mount_marker", ""))
	var obs_marker := str(obs_parsed.get("mount_marker", ""))
	if expected_marker != "" and obs_marker != "" and obs_marker != expected_marker:
		updated["status"] = "FAILED"
		updated["capture_error"] = "MOUNT_MARKER_MISMATCH"
		return updated

	# Expected vs observed ODF hash semantics:
	# 1. Verify every staged ODF on disk still matches the expected staging manifest MD5.
	var staged_odfs: Dictionary = receipt.get("staged_odf_hashes", {})
	var stage_root := str(receipt.get("stage_root", ""))
	if stage_root == "" and str(receipt.get("staging_manifest", "")) != "":
		stage_root = str(receipt.get("staging_manifest", "")).get_base_dir()
	var disk_check := verify_staged_odf_hashes_on_disk(stage_root, staged_odfs) if (stage_root != "" and not staged_odfs.is_empty()) else {"ok": true, "checked": 0, "mismatches": []}
	if not bool(disk_check.get("ok", false)):
		updated["status"] = "FAILED"
		updated["capture_error"] = "STAGED_ODF_DRIFT"
		updated["staged_odf_mismatches"] = disk_check.get("mismatches", [])
		return updated

	# 2. Validate expected_odf_md5 (if echoed by Lua) against staged ODF hashes.
	var reported_expected := str(obs_parsed.get("expected_odf_md5", "")).to_lower()
	if not staged_odfs.is_empty() and reported_expected != "":
		var matched_exp := false
		for rel in staged_odfs:
			if str(staged_odfs[rel]).to_lower() == reported_expected:
				matched_exp = true
				break
		if not matched_exp:
			updated["status"] = "FAILED"
			updated["capture_error"] = "EXPECTED_ODF_HASH_MISMATCH"
			return updated

	# 3. Validate observed_odf_md5 (or legacy odf_md5) ONLY when actually reported.
	var obs_odf_md5 := str(obs_parsed.get("observed_odf_md5", obs_parsed.get("odf_md5", ""))).to_lower()
	var obs_hash_verified := false
	if not staged_odfs.is_empty() and obs_odf_md5 != "":
		var matched_odf := false
		for rel in staged_odfs:
			if str(staged_odfs[rel]).to_lower() == obs_odf_md5:
				matched_odf = true
				break
		if not matched_odf:
			updated["status"] = "FAILED"
			updated["capture_error"] = "ODF_HASH_MISMATCH"
			return updated
		obs_hash_verified = true

	var obs_hash := FileAccess.get_md5(observation_path)
	var now := Time.get_datetime_string_from_system()
	var obs: Dictionary = obs_parsed.duplicate(true)
	obs["provenance"] = capture_method
	obs["measurement_method"] = str(obs.get("measurement_method", "GetCurHealth_delta"))
	obs["observed_at"] = str(obs.get("observed_at", now))
	obs["artifacts"] = [observation_path]
	obs["artifact_md5"] = obs_hash
	obs["staged_odf_disk_verified"] = bool(disk_check.get("ok", false))
	obs["observed_odf_md5"] = obs_odf_md5
	obs["observed_odf_hash_available"] = obs_odf_md5 != ""
	obs["observed_odf_hash_verified"] = obs_hash_verified
	if obs_odf_md5 == "":
		obs["observed_odf_hash_note"] = "LuaMission.dll cannot hash ODF files; verified via staged disk MD5 + OpenODF runtime probe"

	var pred_dmg := float(godot_prediction.get("damage", 0.0))
	var obs_dmg := float(obs.get("damage", 0.0))
	var delta := obs_dmg - pred_dmg
	var comp := {
		"result": "MATCH" if absf(delta) < 0.01 else "DIFF",
		"damage_delta": delta,
		"godot_damage": pred_dmg,
		"native_damage": obs_dmg,
		"scenario_hash": str(receipt.get("scenario_hash", "")),
		"compared_at": now,
	}
	var comp_hash := _hash_dict(comp)

	receipt["observation_artifact_path"] = observation_path
	receipt["observation_artifact_hash"] = obs_hash
	receipt["observation_capture_method"] = capture_method
	receipt["comparison_hash"] = comp_hash
	receipt["observation_confirmed"] = not bool(receipt.get("synthetic", false))
	if bool(obs.get("resources_mounted", false)):
		receipt["resources_mounted"] = true
	_trusted_sessions[session_id] = receipt

	updated["session_id"] = session_id
	updated["launch_nonce"] = str(receipt.get("launch_nonce", ""))
	updated["session_receipt"] = receipt.duplicate(true)
	updated["resources_mounted"] = bool(receipt.get("resources_mounted", false))
	updated["observed_odf_hashes"] = {
		"available": obs_odf_md5 != "",
		"observed_odf_md5": obs_odf_md5,
		"verified_against_expected": obs_hash_verified,
		"staged_disk_verified": bool(disk_check.get("ok", false)),
		"odf_probe_damage": float(obs.get("odf_probe_damage", -1.0)),
	}
	updated["launch_record"] = {
		"executed": bool(receipt.get("execution_confirmed", false)),
		"route": str(receipt.get("launch_route", "")),
		"exe": str((updated.get("game", {}) as Dictionary).get("exe", "")),
		"launch_args": receipt.get("launch_args", []),
		"exit_code": int(receipt.get("exit_code", -1)),
		"process_id": int(receipt.get("process_id", 0)),
		"process_start_time": str(receipt.get("process_start_time", "")),
		"mission_loaded_at": str(receipt.get("mission_loaded_at", "")),
		"launched_at": str(receipt.get("process_start_time", "")),
	}
	updated["native_observation"] = obs
	updated["godot_prediction"] = godot_prediction.duplicate(true)
	updated["difference"] = "delta=%.3f (native=%.3f vs godot=%.3f)" % [delta, obs_dmg, pred_dmg]
	updated["comparison"] = comp
	updated["verified_at"] = now
	updated["status"] = "NATIVE_VERIFIED" if not bool(receipt.get("synthetic", false)) else "COMPARISON_COMPLETE"
	var verdict := validate_native_evidence(updated)
	if not bool(verdict.get("verified", false)):
		updated["status"] = str(verdict.get("state", "COMPARISON_COMPLETE"))
	return updated


## Separate evidence schema validation from real process-local execution
## attestation, observation provenance, and scenario-revision comparison.
static func validate_native_evidence(evidence: Dictionary) -> Dictionary:
	var missing: Array[String] = []
	var errors: Array[String] = []
	if evidence.is_empty():
		return {
			"verified": false,
			"schema_valid": false,
			"artifacts_present": false,
			"execution_confirmed": false,
			"observation_confirmed": false,
			"comparison_complete": false,
			"expected_odf_hashes_verified": false,
			"observed_odf_hash_available": false,
			"mount_verified": false,
			"attestation_kind": "NONE",
			"synthetic": true,
			"state": "DRAFT",
			"missing": ["evidence"],
			"errors": ["empty evidence"],
		}

	var status := str(evidence.get("status", "DRAFT"))
	var game = evidence.get("game", {})
	var exe_md5 := ""
	if not (game is Dictionary) or not bool(game.get("ok", false)):
		missing.append("game.ok")
	else:
		var exe := str(game.get("exe", ""))
		exe_md5 = str(game.get("exe_md5", ""))
		if exe == "" or not FileAccess.file_exists(exe):
			missing.append("game.exe")
		elif not _is_hex_md5(exe_md5):
			missing.append("game.exe_md5")
		elif FileAccess.get_md5(exe) != exe_md5:
			errors.append("game.exe_md5 mismatch against executable on disk")
		var bid := str(game.get("build_id", ""))
		if not bool(game.get("build_id_valid", false)) or not _is_ascii_digits(bid):
			missing.append("game.build_id")

	var scenario = evidence.get("scenario", {})
	var scenario_hash := str(evidence.get("scenario_hash", ""))
	if not (scenario is Dictionary) or str(scenario.get("id", scenario.get("scenario_id", ""))) == "":
		missing.append("scenario.id")
	elif scenario_hash == "":
		scenario_hash = _hash_dict(scenario)

	var staged = evidence.get("staged", [])
	if not (staged is Array) or staged.is_empty():
		missing.append("staged")
	else:
		for item in staged:
			if not (item is Dictionary) or str(item.get("rel", "")) == "" or not _is_hex_md5(str(item.get("md5", ""))):
				errors.append("staged item missing rel or md5")
				break

	var stage_manifest := str(evidence.get("staging_manifest", ""))
	var sm_disk_hash := ""
	var artifacts_present := true
	if stage_manifest == "" or not FileAccess.file_exists(stage_manifest):
		missing.append("staging_manifest")
		artifacts_present = false
	else:
		sm_disk_hash = FileAccess.get_md5(stage_manifest)
		var sm_jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(stage_manifest))
		var sm_parsed = sm_jres.get("data", null) if bool(sm_jres.get("ok", false)) else null
		if not (sm_parsed is Dictionary) or not (sm_parsed.get("files", []) is Array) or (sm_parsed.get("files", []) as Array).is_empty():
			errors.append("staging_manifest content invalid")
			artifacts_present = false

	var launch = evidence.get("launch_record", {})
	if not (launch is Dictionary) or not bool(launch.get("executed", false)):
		missing.append("launch_record.executed")
	else:
		if str(launch.get("exe", "")) == "" or str(launch.get("launched_at", "")) == "":
			missing.append("launch_record.metadata")
		var largs = launch.get("launch_args", [])
		if not (largs is Array) or largs.is_empty():
			missing.append("launch_record.launch_args")
		if not launch.has("exit_code"):
			missing.append("launch_record.exit_code")

	var observed = evidence.get("native_observation", {})
	var valid_artifacts := 0
	var primary_obs_path := ""
	var observed_odf_hash_available := false
	if not (observed is Dictionary) or observed.is_empty():
		missing.append("native_observation")
		artifacts_present = false
	else:
		var prov := str(observed.get("provenance", ""))
		var prov_lc := prov.to_lower()
		var method := str(observed.get("measurement_method", ""))
		var obs_at := str(observed.get("observed_at", ""))
		if prov == "" or prov_lc == "forged" or prov_lc == "manual" or prov_lc == "synthetic" or prov_lc == "mock":
			missing.append("native_observation.provenance")
		if bool(observed.get("synthetic", false)):
			errors.append("native_observation explicitly marked synthetic")
		if method == "":
			missing.append("native_observation.measurement_method")
		if obs_at == "":
			missing.append("native_observation.observed_at")
		observed_odf_hash_available = bool(observed.get("observed_odf_hash_available", str(observed.get("observed_odf_md5", "")) != ""))
		var artifacts = observed.get("artifacts", [])
		if artifacts is Array:
			for a in artifacts:
				var apath := str(a)
				if apath != "" and FileAccess.file_exists(apath) and FileAccess.get_file_as_bytes(apath).size() > 0:
					valid_artifacts += 1
					if primary_obs_path == "":
						primary_obs_path = apath
		var ev_path := str(evidence.get("evidence_path", ""))
		if valid_artifacts == 0:
			if ev_path == "" or not FileAccess.file_exists(ev_path) or FileAccess.get_file_as_bytes(ev_path).size() <= 0:
				missing.append("native_observation.artifacts")
				artifacts_present = false
			else:
				valid_artifacts = 1
				primary_obs_path = ev_path

	var comp = evidence.get("comparison", {})
	var comparison_complete := false
	if not (comp is Dictionary) or str(comp.get("result", "")) == "" or str(comp.get("compared_at", "")) == "":
		missing.append("comparison")
	else:
		comparison_complete = true
	var pred = evidence.get("godot_prediction", {})
	if not (pred is Dictionary) or pred.is_empty():
		missing.append("godot_prediction")
		comparison_complete = false
	if str(evidence.get("created", "")) == "" and str(evidence.get("verified_at", "")) == "":
		missing.append("timestamp")

	var schema_valid := missing.is_empty() and errors.is_empty()

	# Process-local trusted execution attestation (strictly separated from synthetic/test records).
	var execution_confirmed := false
	var observation_confirmed := false
	var expected_odf_hashes_verified := false
	var mount_verified := false
	var attestation_kind := "NONE"
	var receipt_in = evidence.get("session_receipt", {})
	if receipt_in is Dictionary and not receipt_in.is_empty():
		var sid := str(receipt_in.get("session_id", ""))
		if sid != "" and _trusted_sessions.has(sid):
			var trusted: Dictionary = _trusted_sessions[sid]
			var mode := str(trusted.get("attestation_mode", "RUNNER_ATTESTED"))
			var is_syn_receipt := bool(trusted.get("synthetic", false)) or mode != "RUNNER_ATTESTED"
			if is_syn_receipt:
				attestation_kind = "SYNTHETIC"
			else:
				attestation_kind = "RUNNER_ATTESTED"
				var nonce_ok := str(receipt_in.get("launch_nonce", "")) == str(trusted.get("launch_nonce", ""))
				var exe_ok := str(trusted.get("executable_hash", "")) != "" and str(trusted.get("executable_hash", "")) == exe_md5
				var sm_ok := str(trusted.get("staging_manifest_hash", "")) != "" and str(trusted.get("staging_manifest_hash", "")) == sm_disk_hash
				var scn_ok := str(trusted.get("scenario_hash", "")) == scenario_hash
				mount_verified = bool(trusted.get("resources_mounted", false))
				var proc_ok := int(trusted.get("process_id", 0)) > 0 and str(trusted.get("mission_loaded_at", "")) != "" and bool(trusted.get("execution_confirmed", false)) and mount_verified
				var sroot := str(trusted.get("stage_root", ""))
				if sroot == "" and stage_manifest != "":
					sroot = stage_manifest.get_base_dir()
				var staged_odf_map: Dictionary = trusted.get("staged_odf_hashes", {})
				if sroot != "" and not staged_odf_map.is_empty():
					var dchk := verify_staged_odf_hashes_on_disk(sroot, staged_odf_map)
					expected_odf_hashes_verified = bool(dchk.get("ok", false))
					if not expected_odf_hashes_verified:
						errors.append("staged ODF on disk drifted from expected manifest hash")
				else:
					expected_odf_hashes_verified = true
				if nonce_ok and exe_ok and sm_ok and scn_ok and proc_ok and expected_odf_hashes_verified:
					execution_confirmed = true
				elif not scn_ok:
					errors.append("scenario_hash mismatch against trusted session receipt")
				if execution_confirmed and bool(trusted.get("observation_confirmed", false)):
					var t_obs_path := str(trusted.get("observation_artifact_path", ""))
					var t_obs_hash := str(trusted.get("observation_artifact_hash", ""))
					if t_obs_path != "" and FileAccess.file_exists(t_obs_path) and FileAccess.get_md5(t_obs_path) == t_obs_hash:
						if str(observed.get("session_id", "")) == sid:
							observation_confirmed = true
						else:
							errors.append("observation session_id does not match trusted receipt")
				if comparison_complete and str(comp.get("scenario_hash", "")) != "":
					if str(comp.get("scenario_hash", "")) != str(trusted.get("scenario_hash", "")):
						comparison_complete = false
						errors.append("comparison scenario_hash does not match trusted session")

	var synthetic := (attestation_kind != "RUNNER_ATTESTED") or not (execution_confirmed and observation_confirmed)
	var verified := status == "NATIVE_VERIFIED" and schema_valid and artifacts_present and execution_confirmed and observation_confirmed and comparison_complete and expected_odf_hashes_verified and mount_verified and not synthetic and errors.is_empty()

	var computed_state := status
	if not verified and status == "NATIVE_VERIFIED":
		if not errors.is_empty():
			computed_state = "FAILED"
		elif schema_valid and synthetic:
			computed_state = "COMPARISON_COMPLETE"
		else:
			computed_state = "DRAFT"

	return {
		"verified": verified,
		"schema_valid": schema_valid,
		"artifacts_present": artifacts_present and valid_artifacts > 0,
		"execution_confirmed": execution_confirmed,
		"observation_confirmed": observation_confirmed,
		"comparison_complete": comparison_complete,
		"expected_odf_hashes_verified": expected_odf_hashes_verified,
		"observed_odf_hash_available": observed_odf_hash_available,
		"mount_verified": mount_verified,
		"attestation_kind": attestation_kind,
		"synthetic": synthetic,
		"state": computed_state,
		"missing": missing,
		"errors": errors,
	}


## True only when a real, runner-attested native execution passes every schema,
## artifact, trusted-session, and scenario-revision gate. Synthetic dicts return false.
static func is_native_verified(evidence: Dictionary) -> bool:
	return bool(validate_native_evidence(evidence).get("verified", false))


## Read-only preflight verifying executable, build ID, staging isolation,
## BZN + Lua + terrain closure, mount config mapping, session identity consistency,
## resource closure (when index/spec provided), config path compatibility, and
## Steam launch route. Computes independent execution gates (P0-NATIVE-01):
##   STRUCTURALLY_VALID, RESOURCE_CLOSURE_VALID, STAGE_ELIGIBLE,
##   CONFIG_COMPATIBLE, EXECUTION_ENVIRONMENT_READY, LAUNCH_ELIGIBLE.
static func preflight_experiment(stage_root: String, files: Dictionary, scenario: Dictionary,
		discovery: Dictionary = {}, steam_override: Dictionary = {},
		session: RefCounted = null, index: ResourceIndex = null,
		closure_spec: Dictionary = {}, launch_options: Dictionary = {}) -> Dictionary:
	var disc := discovery if not discovery.is_empty() else discover()
	var issues: Array[String] = []
	var blockers: Array[String] = []
	var primary_reason := ""
	var launch_mode := str(launch_options.get("launch_mode", "CUSTOM_CONFIG")).strip_edges().to_upper()
	if launch_mode != "STOCK_ADDON":
		launch_mode = "CUSTOM_CONFIG"

	if not bool(disc.get("ok", false)):
		issues.append("BZCC executable not found at " + str(disc.get("exe", "")))
		primary_reason = "MISSING_GAME_EXECUTABLE"
	if not bool(disc.get("build_id_valid", false)):
		issues.append("Steam build ID invalid or missing: " + str(disc.get("build_id", "")))
		if primary_reason == "":
			primary_reason = "INVALID_BUILD_ID"
	if str(scenario.get("id", "")) == "":
		issues.append("scenario.id missing")
		if primary_reason == "":
			primary_reason = "MISSING_SCENARIO_ID"

	var stage_leaf := WorkspaceStore.canonical(stage_root).get_file()
	var allow_addon_dest := (launch_mode == "STOCK_ADDON") and stage_leaf.begins_with("SHAMAN_")
	var extra_prot := _extra_protected_from_discovery(disc, allow_addon_dest)
	var dest_check := SafeStageScript.validate_stage_destination(stage_root, extra_prot)
	if not bool(dest_check.get("ok", false)):
		issues.append("stage destination rejected: " + str(dest_check.get("error", "")))
		if primary_reason == "":
			primary_reason = str(dest_check.get("reason", "INVALID_STAGE_ROOT"))
	if files.is_empty():
		issues.append("no staged scenario files provided")
		if primary_reason == "":
			primary_reason = "EMPTY_STAGE_FILES"

	# P0-NATIVE-01: Validate real LuaMission BZN + Lua + terrain + launch target.
	var pkg_check := validate_mission_package(files, str(disc.get("game_root", DEFAULT_GAME_ROOT)))
	if not bool(pkg_check.get("ok", false)):
		for e in pkg_check.get("errors", []):
			issues.append(str(e))
		if primary_reason == "":
			primary_reason = str(pkg_check.get("reason", "INVALID_MISSION_PACKAGE"))

	# P0-NATIVE-02: Validate mount config (CUSTOM_CONFIG) or stock addon marker safety (STOCK_ADDON).
	var mount_check: Dictionary = {}
	if launch_mode == "STOCK_ADDON":
		var has_marker := files.has("assets/ODF/shaman_mount_marker.odf")
		var pollutes_shell := files.has("assets/Config/bzshell_init.cfg")
		var stock_chk := inspect_stock_bzone_cfg(str(disc.get("game_root", DEFAULT_GAME_ROOT)))
		mount_check = {
			"ok": has_marker and not pollutes_shell and bool(stock_chk.get("ok", false)),
			"mode": "STOCK_ADDON",
			"has_marker": has_marker,
			"pollutes_shell_init": pollutes_shell,
			"stock_bzone_cfg": stock_chk,
			"reason": "" if (has_marker and not pollutes_shell and bool(stock_chk.get("ok", false))) else ("STOCK_ADDON_SHELL_POLLUTION" if pollutes_shell else ("MISSING_MOUNT_MARKER" if not has_marker else str(stock_chk.get("reason", "STOCK_ADDON_MOUNT_NOT_FIRST")))),
		}
		if not bool(mount_check.get("ok", false)):
			issues.append("stock addon mount validation failed: " + str(mount_check.get("reason", "")))
			if primary_reason == "":
				primary_reason = str(mount_check.get("reason", "STOCK_ADDON_INVALID"))
	else:
		var cfg_raw = files.get("shaman_native.cfg", "")
		var cfg_text: String = (cfg_raw as PackedByteArray).get_string_from_utf8() if cfg_raw is PackedByteArray else str(cfg_raw)
		mount_check = validate_mount_config(cfg_text, stage_root)
		if not bool(mount_check.get("ok", false)):
			issues.append(str(mount_check.get("error", "mount path mismatch")))
			if primary_reason == "":
				primary_reason = str(mount_check.get("reason", "MOUNT_PATH_MISMATCH"))

	# P0-SESSION: Validate single NativeExperimentSession identity across generated Lua and mount plan.
	var session_check: Dictionary = {}
	if session != null:
		session_check = session.validate_consistency(files, session.mount_plan)
		if not bool(session_check.get("ok", false)):
			for se in session_check.get("errors", []):
				issues.append(str(se))
			if primary_reason == "":
				primary_reason = str(session_check.get("reason", "SESSION_IDENTITY_MISMATCH"))

	# P0-CLOSURE: Validate transitive ODF resource closure when requested.
	var closure_report: Dictionary = {}
	var resource_closure_valid := true
	if index != null or not closure_spec.is_empty():
		var cspec := closure_spec.duplicate(true)
		if not cspec.has("staged_files"):
			cspec["staged_files"] = files
		closure_report = ResourceClosureScript.build_closure(cspec, index, disc)
		if session != null:
			session.closure_report = closure_report.duplicate(true)
		if not bool(closure_report.get("ok", false)):
			resource_closure_valid = false
			var creason := str(closure_report.get("reason", closure_report.get("status", "RESOURCE_MISSING")))
			issues.append("resource closure failed (%s)" % creason)
			if primary_reason == "":
				primary_reason = creason

	# P0-NATIVE-03: Evaluate Steam launch capability route (never require mutating BZ2R).
	var steam_env: Dictionary = steam_override if not steam_override.is_empty() else (disc.get("steam", {}) as Dictionary)
	if steam_env.is_empty():
		steam_env = detect_steam_environment(disc)
	var launch_route := "UNSUPPORTED"
	var blocker_reason := ""
	if not bool(steam_env.get("steam_present", false)):
		launch_route = "UNSUPPORTED"
		blocker_reason = "STEAM_CLIENT_MISSING"
		blockers.append("Steam client not found for AppID %s; cannot use STEAM_MANAGED route" % STEAM_APP_ID)
	elif not bool(steam_env.get("steam_logged_in", false)):
		launch_route = "OPERATOR_MANUAL"
		blocker_reason = "STEAM_USER_NOT_LOGGED_IN"
		blockers.append("Steam client is present (%s) but no Steam user is logged in in this Windows session (%s); direct battlezone2.exe launch hands off to Steam (exit 53) and BZ2R is read-only" % [
			str(steam_env.get("steam_exe", "")), str(steam_env.get("detail", "ActiveUser=0x0"))
		])
	else:
		launch_route = "STEAM_MANAGED"

	var cfg_override := str(launch_options.get("config_path_override", "")).strip_edges()
	var cfg_path := WorkspaceStore.canonical(cfg_override) if cfg_override != "" else (
		WorkspaceStore.canonical(str(session.config_path)) if (session != null and str(session.config_path) != "") else WorkspaceStore.canonical(stage_root).path_join("shaman_native.cfg")
	)
	var mission_bzn := str(pkg_check.get("bzn_file", DEFAULT_MISSION_BASE + ".bzn"))
	var include_logconsole := bool(launch_options.get("include_logconsole", false))
	var launch_cmd := build_launch_command(launch_route, disc, cfg_path, mission_bzn, include_logconsole, launch_mode)
	var cfg_diag: Dictionary = launch_cmd.get("config_diagnostics", {}) if launch_cmd.get("config_diagnostics", {}) is Dictionary else {}
	var config_compatible := bool(cfg_diag.get("ok", false))
	var rootdir_handoff: Dictionary = {}
	if not config_compatible:
		var cfg_raw_bytes := PackedByteArray()
		if files.has("shaman_native.cfg"):
			var cr = files["shaman_native.cfg"]
			cfg_raw_bytes = cr if cr is PackedByteArray else str(cr).to_utf8_buffer()
		rootdir_handoff = prepare_rootdir_config_handoff(cfg_path, str(disc.get("game_root", DEFAULT_GAME_ROOT)), cfg_raw_bytes)
		var cfg_code := str(cfg_diag.get("code", "CONFIG_REQUIRES_ROOTDIR_PLACEMENT"))
		blockers.append(str(cfg_diag.get("warning", "External /config path requires @rootdir placement (%s)" % cfg_code)))
		if blocker_reason == "":
			blocker_reason = cfg_code

	if session != null:
		session.launch_route = launch_route
		session.launch_command = launch_cmd.duplicate(true)

	var structurally_valid := issues.is_empty()
	var stage_eligible := structurally_valid and resource_closure_valid
	var execution_environment_ready := (launch_route == "STEAM_MANAGED") and bool(launch_cmd.get("supported", false))
	var launch_ready := stage_eligible and config_compatible and execution_environment_ready and blockers.is_empty()
	var launch_eligible := launch_ready
	var status := "STRUCTURALLY_VALID" if launch_ready else ("BLOCKED" if stage_eligible else "FAILED")
	if primary_reason == "" and blocker_reason != "":
		primary_reason = blocker_reason

	return {
		"ok": structurally_valid,
		"structurally_valid": structurally_valid,
		"resource_closure_valid": resource_closure_valid,
		"stage_eligible": stage_eligible,
		"config_compatible": config_compatible,
		"execution_environment_ready": execution_environment_ready,
		"launch_ready": launch_ready,
		"launch_eligible": launch_eligible,
		"gates": {
			"STRUCTURALLY_VALID": structurally_valid,
			"RESOURCE_CLOSURE_VALID": resource_closure_valid,
			"STAGE_ELIGIBLE": stage_eligible,
			"CONFIG_COMPATIBLE": config_compatible,
			"EXECUTION_ENVIRONMENT_READY": execution_environment_ready,
			"LAUNCH_ELIGIBLE": launch_eligible,
		},
		"launch_mode": launch_mode,
		"status": status,
		"reason": primary_reason,
		"issues": issues,
		"blockers": blockers,
		"config_diagnostics": cfg_diag,
		"rootdir_handoff": rootdir_handoff,
		"mission_package": pkg_check,
		"mount_validation": mount_check,
		"session_consistency": session_check,
		"resource_closure": closure_report,
		"steam": steam_env,
		"launch_route": launch_route,
		"launch_command": launch_cmd,
		"launch_args": launch_cmd.get("game_args", []),
		"discovery": disc,
	}


## Schema-level helper for recording an observation + comparison (used by
## unit tests and non-attested offline inspection). Never self-promotes to
## NATIVE_VERIFIED without a valid process-local trusted execution receipt.
static func record_observation_and_compare(evidence: Dictionary,
		observation: Dictionary, godot_prediction: Dictionary,
		artifact_paths: Array[String]) -> Dictionary:
	var updated := evidence.duplicate(true)
	updated.erase("capture_error")
	updated.erase("capture_parse_error")
	var now := Time.get_datetime_string_from_system()
	var obs := observation.duplicate(true)
	obs["observed_at"] = str(obs.get("observed_at", now))
	obs["artifacts"] = artifact_paths.duplicate()
	updated["native_observation"] = obs
	updated["godot_prediction"] = godot_prediction.duplicate(true)
	var pred_dmg := float(godot_prediction.get("damage", 0.0))
	var obs_dmg := float(obs.get("damage", 0.0))
	var delta := obs_dmg - pred_dmg
	updated["difference"] = "delta=%.3f (native=%.3f vs godot=%.3f)" % [delta, obs_dmg, pred_dmg]
	updated["comparison"] = {
		"result": "MATCH" if absf(delta) < 0.01 else "DIFF",
		"damage_delta": delta,
		"godot_damage": pred_dmg,
		"native_damage": obs_dmg,
		"scenario_hash": str(updated.get("scenario_hash", "")),
		"compared_at": now,
	}
	updated["verified_at"] = now
	updated["status"] = "NATIVE_VERIFIED"
	var verdict := validate_native_evidence(updated)
	if not bool(verdict.get("verified", false)):
		updated["status"] = str(verdict.get("state", "COMPARISON_COMPLETE"))
	return updated
