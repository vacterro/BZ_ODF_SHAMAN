# Native BZCC testing

## Current state

**Structurally valid LuaMission BZN generation, exact stage-to-BZCC mount mapping (with stock `@rootdir\maps`),
opt-in `/logconsole` (disabled by default), `/config` rootdir-compatibility diagnostics, session-correlated
crash-log forensics, strict stock/VSR resource closure, app-owned non-blocking `NativeSessionService` GUI
monitoring across tabs, automatic session-bound observation collection in `poll_monitor`, checked
`process_monitors.json` persistence, event-driven Lua states (`contract_version: 2`, no time-based `SHOT_OBSERVED`),
and MD5-verified staging cleanup are implemented and regression-tested.**

No live native BZCC calibration is claimed (`NATIVE_VERIFIED: 0`). Controlled T-60 diagnosis corrected the
earlier T-20 misdiagnosis (`.saipen/evidence/native/T-60-native-startup-diagnosis.md`):

- Visual inspection of `.saipen/evidence/native/t20_bzcc_fatal_dialog.png` shows the actual dialog string is
  `Unable to load console font 'ds_16.bmf' -- check MOD installation and/or .cfg` (NOT `ds16.brf`).
- Stock **`ds_16.bmf` EXISTS** in `V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R\bz2r_res\interface\Fonts\DS\ds_16.bmf`.
- Read-only inspection of Steam's `localconfig.vdf:69` confirms Steam LaunchOptions are `/disablemipmaps /nointro /tps 30`
  (Steam does **NOT** inject `/logconsole`; SHAMAN itself previously injected `/logconsole`, now opt-in `false`).
- **Control A** (stock Steam launch) boots cleanly to the shell (`Battlezone 2026-11-22 11.26.43.3718.log`, 49,164 bytes) with zero font errors.
- **Control C / E2** (SHAMAN `/config` with absolute `C:\...` or relative `..\..\...` path outside `@rootdir`) logs `Command line /config used` and skips `ConfigureFileSystem()` completely (0 `AddDirRecurse` lines), leaving `@rootdir\bz2r_res` unmounted so `ds_16.bmf` cannot be loaded (`CONFIG_PATH_NOT_LOADED_NO_FILESYS`).
- **Control E_REF** (bare filename inside `@rootdir`, e.g. `VRV_T960_*.cfg`) parses `ConfigureFileSystem()` and loads missions normally (`Battlezone 2026-11-22 01.15.56.6515.log`, 43,965 bytes).
- **Steam UX constraint:** `steam.exe -applaunch 624970 <args>` displays Steam's interactive `"Launch Game with custom arguments"` confirmation modal.
- Because `SafeStageManager` keeps `BZ2R` strictly read-only, SHAMAN does not silently drop `.cfg` files into `BZ2R`; `diagnose_config_path_compatibility()` reports `CONFIG_REQUIRES_ROOTDIR_PLACEMENT` and gives exact operator instructions.

Implemented in `scripts/native/` (`native_experiment_session.gd`, `native_resource_closure.gd`,
`safe_stage_manager.gd`, `native_test_adapter.gd`, `native_experiment_runner.gd`,
`native_process_monitor.gd`, `native_session_service.gd`):

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
  (`operator_instructions.txt` → `AWAITING_OPERATOR`) workflows.
  Checked transitions (`T-40` / P1-02) persist the session record and ledger before any
  externally visible success; a failed persist returns `STATE_PERSIST_FAILED` /
  `RECOVERY_PENDING` and is preserved on restart. The bounded asynchronous
  `NativeProcessMonitor` (`P1-03`) captures preexisting game PIDs before Steam spawn, verifies a
  new `battlezone2.exe` by path and MD5, advances through mission/probe states, bounds both poll
  count and timeout, persists across restart (`resume_monitor`), and never promotes synthetic or
  unattested observations to `NATIVE_VERIFIED`;
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
| Checked durable session transitions (`STATE_PERSIST_FAILED` / `RECOVERY_PENDING`) | `IMPLEMENTED` / `TESTED_HEADLESS` | Validated by `ND-11..ND-15` (`T-40`) |
| Bounded asynchronous `NativeProcessMonitor` with PID/exe verification, mission/probe state machine, restart recovery, timeout/cancel | `IMPLEMENTED` / `TESTED_HEADLESS` | Validated by `SM-01..SM-07` (`T-40`) |
| Independent launch eligibility gates (`STRUCTURALLY_VALID`, `RESOURCE_CLOSURE_VALID`, `STAGE_ELIGIBLE`, `CONFIG_COMPATIBLE`, `EXECUTION_ENVIRONMENT_READY`, `LAUNCH_ELIGIBLE`) & `CONFIG_REQUIRES_ROOTDIR_PLACEMENT` mandatory launch block | `VERIFIED` (`TESTED_HEADLESS`) | Validated by `NL-01..NL-06` (`T-65`); incompatible external `/config` can stage for manual handoff (with SHA256/collision check) but is unconditionally rejected from process launch |
| Safe Stock Addon launch route (`STOCK_ADDON` via stock `bzone.cfg` `@mydocsdir\addon\SHAMAN_*`) | `VERIFIED` (dry-run staging) / `BLOCKED_EXTERNAL` (live Steam) | Verified read-only that stock `bzone.cfg` mounts `@mydocsdir\addon` first (`CONFIG_STOCK_ADDON_ROUTE`), stages without `/config` or `bzshell_init.cfg` pollution, cleans up only owned files (`NL-05`, `.saipen/evidence/native/native-probe-799678.json`) |
| Active-experiment cleanup guard (`ACTIVE_EXPERIMENT_CANNOT_CLEANUP`) & separate evidence retention | `VERIFIED` (`TESTED_HEADLESS` + `TESTED_GUI`) | Validated by `NC-01..NC-07` (`T-68`); rejected cleanup preserves `NativeSessionService` timer/monitor; evidence copied outside stage root before cleanup |
| Live Steam BZCC execution & engine health-delta calibration | `BLOCKED_EXTERNAL` (`NATIVE_VERIFIED: 0`) | Live Steam client session is unauthenticated (`ActiveUser=0x0`, `STEAM_USER_NOT_LOGGED_IN`) in this Windows session; original `BZ2R` untouched |

## Remaining adapter work (for an operator-authorized `@rootdir` run)

1. **Operator-authorized `@rootdir` `.cfg` placement** — Because BZCC 2.0.185 `select_bzone_cfg` only resolves `/config <bare_name.cfg>` inside `@rootdir` (`BZ2R\`) and `BZ2R` is read-only by safety policy, an operator who wants live native execution must place or copy the staged `shaman_native.cfg` into `BZ2R\` and confirm Steam's custom-arguments dialog (or launch `battlezone2.exe` in the logged-in Steam user session).
2. **Engine observation & calibration (`NOT_IMPLEMENTED` until live run completes)** — confirm real `battlezone2.exe` process + LuaMission load + resource probe + `WriteToFile` output (`contract_version: 2`), then compare Godot vs native BZCC before marking any scenario `NATIVE_VERIFIED`.

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
