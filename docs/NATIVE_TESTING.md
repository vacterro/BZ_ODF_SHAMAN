# Native BZCC testing

## Current state

**Structurally valid LuaMission BZN generation, exact stage-to-BZCC mount mapping, Steam launch
capability routing, controlled `WriteToFile` LuaMission scripting, process-local trusted session
attestation, and MD5-verified staging cleanup are implemented and regression-tested.**
Live native BZCC execution on this host is explicitly `BLOCKED` by `STEAM_USER_NOT_LOGGED_IN`
(`ActiveUser = 0x0` in the isolated Windows session; Steam client is present at
`V:\__STORE_V\_SOFT\Steam\steam.exe` and direct `battlezone2.exe` launch exits `53` to trigger
`SteamAPI_RestartAppIfNecessary`). Native verified count remains `0` and nothing claims otherwise.

Implemented in `scripts/native/` (`native_experiment_session.gd`, `native_resource_closure.gd`,
`safe_stage_manager.gd`, `native_test_adapter.gd`, `native_experiment_runner.gd`):

- **Single immutable experiment identity (`NativeExperimentSession`)** — binds `session_id`,
  `launch_nonce`, `scenario_hash`, `stage_root`, `observation_path`, `expected_odf_hashes`, and
  `attestation_kind` (`RUNNER_LIVE` vs `SYNTHETIC_TEST`) in one record across preflight, staging,
  launch, observation collection, and cleanup;
- **Resource closure & Workshop ambiguity validation (`NativeResourceClosureBuilder`)** — walks
  shooter/weapon/ordnance/explosion/render/model/audio dependencies, detects missing assets,
  Workshop package ambiguity (`RESOURCE_AMBIGUOUS`), and unmounted Workshop requirements
  (`workshop_required`) before staging or launch;
- **Durable runner & split GUI controls (`NativeExperimentRunner`)** — persists sessions to
  `<WorkspaceStore.root()>/native_sessions/session_ledger.json` + per-session JSON files,
  recovers active/staged/awaiting sessions across restart (`recover_sessions()`), and exposes
  five explicit controls in Weapons Lab (`PREFLIGHT`, `STAGE`, `LAUNCH / HANDOFF`, `COLLECT`,
  `CLEANUP`) supporting both `STEAM_MANAGED` (`-applaunch 624970`) and `OPERATOR_MANUAL`
  (`operator_instructions.txt` → `AWAITING_OPERATOR`) workflows;
- **Game & Steam discovery** — resolves `battlezone2.exe`, `Missions/LuaMission.dll`, Data/Res
  roots, Workshop root, Addon folder, and `steam.exe` (`LauncherPath` in `appmanifest_624970.acf`),
  plus read-only Steam active session status (`HKCU\Software\Valve\Steam\ActiveProcess`);
- **Version evidence** — MD5 and byte size of `battlezone2.exe` plus numeric Steam `buildid`
  extracted with a Valve KeyValues parser from `appmanifest_624970.acf` (non-numeric/missing → `UNKNOWN`);
- **Allowlisted staging, restaging guard & MD5 cleanup (`SafeStageManager`)** — permits staging only inside owned roots
  (`user://native_tests` or registered bases), refuses `BZ2R`, Workshop, `VRV`, `Wintage`,
  `BZ2_ENGINE_KNOWLEDGE`, project source, symlinks/junctions, traversal paths, and unowned roots.
  Refuses restaging while `stage_recovery_pending.json` (`RECOVERY_PENDING`) exists, preserves
  user-modified files across restaging and cleanup (`MODIFIED_FILE_PRESERVED` / `PARTIAL_CLEANUP`),
  and restores previously overwritten owned files on mid-overwrite failure;
- **Valid LuaMission BZN + mount mapping** — `build_minimal_luamission_bzn()` generates a valid
  ASCII v1192 BZCC `.bzn` (`dllName = luamission.dll`, stock `test` terrain resolved against
  `bz2r_res/datapak/test.{trn,ter}`). `shaman_native.cfg` mounts the exact canonical
  `<stage_root>\assets` directory via `AddDirRecurse(...)` instead of an unrelated `@mydocsdir\addon`,
  validated by `validate_mission_package()` and `validate_mount_config()`;
- **Controlled LuaMission script (`WriteToFile`, `contract_version: 1`)** — avoids disabled `io.open`,
  uses verified `LuaMission.dll` APIs (`WriteToFile`, `PrintConsoleMessage`, `GetCurHealth`, `GetMaxHealth`,
  `GetTerrainHeightAndNormal`, `OpenODF`, `GetODFString`/`GetODFFloat`, `FireAt`, `Attack`,
  `GetTime`, `GetTPS`) with a 10-state machine (`INITIALIZING` → `MEASUREMENT_COMPLETE`/`TIMEOUT`/`FAILED`),
  `measurement_method: "GetCurHealth_delta"`, and honest `expected_odf_md5` vs empty `observed_odf_md5`
  (`observed_odf_hash_available: false`) while Godot verifies staged ODF disk MD5s (`STAGED_ODF_DRIFT`);
- **Steam launch capability routes** — distinguishes `STEAM_MANAGED`, `STEAM_LAUNCH_OPTIONS`,
  `OPERATOR_MANUAL`, `DIRECT_EXECUTABLE`, and `UNSUPPORTED`. Direct-exe exit `53` is classified as
  `STEAM_HANDOFF_REQUIRED`, never as a broken install, and BZ2R is never modified;
- **Separated schema validation vs trusted runner attestation** — `validate_native_evidence()`
  separates `schema_valid`, `artifacts_present`, `execution_confirmed`, `observation_confirmed`,
  `comparison_complete`, `resources_mounted`, and `synthetic`. Synthetic test sessions
  (`begin_synthetic_session`, `SYNTHETIC_CAPTURE_METHOD`) and manually fabricated dictionaries are
  rejected by `is_native_verified()` (`SYNTHETIC_OBSERVATION_REJECTED`). Only `RUNNER_LIVE` sessions
  with matching `session_id`, `launch_nonce`, `scenario_hash`, disk-verified staged ODF MD5s,
  `resources_mounted = true`, and on-disk artifacts pass `is_native_verified()`.

What already existed and still applies:

- in-memory edits are never written to game data;
- “Save to workspace” writes `user://workspace/odf/<relative path>`;
- “Export staged” writes a timestamped folder containing the ODF plus
  `export_report.txt` (date, source, exported path, byte count, MD5);
- exporting inside a configured game root is refused;
- overwriting an original requires an explicit confirmation dialog.

## Launch discovery (verified inputs)

- Game root exists: `V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R`.
- Workshop content exists: `V:\__STORE_V\_SOFT\Steam\steamapps\workshop\content\624970`.
- No game executable path is assumed by the app; the operator must supply it.

## Status Taxonomy (Wave C / Wave D — Honest Evidence)

| Capability | Status | Notes |
|---|---|---|
| ASCII v1192 `luamission.dll` `.bzn` + exact-mount `/config` + `WriteToFile` Lua contract | `STRUCTURALLY_VALID` / `TESTED_HEADLESS` | Validated by `N1..N7`, `N-S1..N-S5`, `N-R1..N-R7` |
| Durable preflight package persistence, byte-exact MD5 hash verification (`UTF-8`/`BOM`/`UTF-16LE`), fail-closed staging/launch | `IMPLEMENTED` / `TESTED_HEADLESS` | Validated by `N-D01..N-D10` |
| Production vs test evidence gate (fake PID/mission/probe options ignored, synthetic rejected, operator-imported unattested) | `IMPLEMENTED` / `TESTED_HEADLESS` | Validated by `N-E01..N-E08` |
| Persistent `ModLoadout` explicit conflict winner shared identically by `ResourceIndex` and `NativeResourceClosureBuilder` | `IMPLEMENTED` / `TESTED_HEADLESS` | Validated by `T-34` |
| Live Steam BZCC execution & engine health-delta calibration | `BLOCKED_EXTERNAL` (`NATIVE_VERIFIED: 0`) | Steam client logged out (`ActiveUser = 0x0` -> `STEAM_USER_NOT_LOGGED_IN`); original `BZ2R` untouched |

## Remaining adapter work (when a logged-in Steam session is available)

1. **Operator / Steam live execution (`BLOCKED_EXTERNAL`)** — run the already-implemented `PREPARE EXPERIMENT` → `STAGE RESOURCES` → `LAUNCH BZCC` (or `MANUAL STEAM HANDOFF`) pipeline inside a logged-in Steam session for AppID 624970.
2. **Engine observation & calibration (`NOT_IMPLEMENTED` until live run completes)** — confirm real `battlezone2.exe` process + LuaMission load + resource probe + `WriteToFile` output, then compare Godot vs native BZCC before marking any scenario `NATIVE_VERIFIED`.

## Reload semantics (must be stated per change)

ODF resources are loaded by the engine at different times. Unless a supported live-reload
mechanism is demonstrated, expect:

- weapon/ordnance changes: mission or game restart;
- object/health changes: mission restart;
- particle/texture changes: possibly a scene or render-state reload.

The application must explain this instead of implying true live in-game modification.

## Safety rules for the future adapter

- Never write into `bz2r_res`, `addon`, Workshop packages, or VRV source by default.
- Transactional writes with backup/rollback; dry-run by default.
- Record every generated file.
- Refuse to launch if staging contains unresolved references that would mask the test.
- Treat any process-memory technique as unsupported unless documented.
