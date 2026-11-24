# Testing

## Commands

```bat
tools\run_tests.cmd
```

Equivalent:

```bat
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/test_runner.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_weapon_chain_integrity.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_alternate_physical_slot.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t122_recovery_coherence.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t123_lifecycle_contract.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t128_cleanup_contract.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t214_receipt_trust.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t214_hardpoint_inspector.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t221_native_identity.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t221_hardpoint_provenance.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t224_stage_safety.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_windows_path_identity.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/verify_t224_hardpoint_identity.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . res://tests/ui_smoke.tscn
```

## Canonical suite — last run: 2026-11-24 (`TESTED_HEADLESS`)

`tests/test_runner.gd`: 1,106 checks, 0 failures. `verify_t122_recovery_coherence.gd`:
28/28 PASS. `verify_t123_lifecycle_contract.gd`: 31/31 PASS.
`verify_t128_cleanup_contract.gd`: 44/44 PASS. `verify_t214_receipt_trust.gd`:
35/35 PASS (NFR-01..14, NDS-01..06). `verify_t214_hardpoint_inspector.gd`:
21/21 PASS (PHI-07..27). `verify_weapon_chain_integrity.gd`: 14/14 PASS
(WCH-01..10, including rejection of missing/NULL `ordName`, authentic Arc/Beam controls,
and fire refusal). `verify_alternate_physical_slot.gd`: 31/31 PASS
(ALT-SLOT-01..10, including replay identity and TANDEM barrel preservation).
T-221 native identity 13/13 PASS (NDS-20..25, NID-01..05), T-221 hardpoint provenance 24/24 PASS (PHI-33..44, ALT-01..06), T-222 stage identity 8/8 PASS, T-222 backup inventory 12/12 PASS, T-222 3D hardpoint 8/8 PASS, T-223 reserved paths 11/11 PASS, T-223 cleanup truth 8/8 PASS, T-223 hardpoint fire 10/10 PASS, T-223 viewport picking 6/6 PASS, T-224 physical stage safety 28/28 PASS, and T-224 hardpoint identity 39/39 PASS.
Canonical frozen-tree rerun: 1,485 checks PASS, 0 failures, `tree_changed_during_run=false`, suite record `1c236f4e4e1a4a51-20261124T194817494416Z`.
The earlier leak was two `Node3D` hardpoint fixtures in the T-214/T-221 test harness, never a product resource leak; both verifiers now free them.
Focused regressions also PASS: T-121 journal trust (34/34), T-121 crash phases
(37/37), T-86 recovery integrity (75/75), T-85 save recovery (11/11),
T-85 graph events (6/6), T-80 identity (21/21 including PHI-01..06 hardpoint
inspector), T-81 graph ports (35/35), T-73 native safety (62/62).

Core suite (`tests/test_runner.gd`) coverage:

| Category | Coverage |
|---|---|
| Native launch eligibility & stock addon (`NL-01..06`, `T-65`) | independent gates (`STRUCTURALLY_VALID`, `RESOURCE_CLOSURE_VALID`, `STAGE_ELIGIBLE`, `CONFIG_COMPATIBLE`, `EXECUTION_ENVIRONMENT_READY`, `LAUNCH_ELIGIBLE`), external `/config` blocked from process launch with `CONFIG_REQUIRES_ROOTDIR_PLACEMENT` while manual handoff provides SHA256 + collision check, `STOCK_ADDON` route inspecting stock `bzone.cfg` (`@mydocsdir\addon` first) and staging/cleaning only owned `SHAMAN_*` files, zero writes to `BZ2R` |
| Unified combat clock, reload & DoT (`CB-01..08`, `T-66`) | `CombatScenario.advance()` single clock advancing `sim_time` even after projectiles finish, 1.0s reload schedule (`t=0.0` accept, `t=0.2`/`0.9` reject, `t=1.0+` accept, `RELOAD_READY` event), single-deduct ammo/energy, `READY`/`RELOADING`/`INSUFFICIENT_AMMO`/`INSUFFICIENT_ENERGY`/`DESTROYED`/`DISABLED` permission state machine, pause/single-step, DoT persistence, burst vs `SALVO_FOLLOWUP` |
| Spatial replay snapshots & baseline preservation (`RP-01..08`, `T-67`) | `reset("ALL")` restores `position`, `velocity`, `yaw_rad`, `radius`, `half_extents`, `bbox_offset`; moving-target replay determinism; immutable `CombatReplaySnapshot` isolating historical runs from subsequent ODF edits; `update_effective_odf_parameters()`/`change_weapon()`/`configure_from_profile(..., true)` preserving initial baseline, reload & effects; sandboxed replay leaving active scenario untouched |
| Native active-experiment cleanup guard (`NC-01..07`, `T-68`) | active monitor rejects `cleanup_stage()` (`ACTIVE_EXPERIMENT_CANNOT_CLEANUP`), `NativeSessionService` timer remains active after rejection, `cancel_monitor()` persists `CANCELLED` across restart, terminal cleanup succeeds while preserving unknown/modified files and retaining evidence artifact outside disposable stage root |
| Native startup diagnosis & log correlation (`NB-01..08`, `T-60`) | `/logconsole` opt-in (absent by default), stock `@rootdir\maps` mount, `CONFIG_REQUIRES_ROOTDIR_PLACEMENT` vs bare `@rootdir` config check, `CONFIG_PATH_NOT_LOADED_NO_FILESYS` vs `EXTERNAL_MISSING_FONT` classification, session-correlated crash log selection (`P1-EVIDENCE-01`), stock `ds_16.bmf` presence |
| Native completeness & monitor persistence (`RC-01..07`, `NM-03..08`, `P1-NATIVE-06`, `T-61`) | strict stock-only vs VSR closure, synthetic ordnance-only probe rejected when `require_complete_closure=true`, automatic `observation_expected_path` resolution in `poll_monitor`, foreign-session rejection, checked `process_monitors.json` persistence (`MONITOR_PERSIST_FAILED`/`RECOVERY_PENDING`), event-driven Lua without time-based `SHOT_OBSERVED` |
| Persistent Combat State (`CS-01..12`, `T-62`) | `CombatActorState`/`CombatScenario` shooter-owned ammo/energy independent of target `maxAmmo`, multi-shot depletion & `INSUFFICIENT_AMMO`/`INSUFFICIENT_ENERGY` block, persistent target shield & hull across shots, independent secondary target shield/hull + splash propagation, reset & deterministic replay, live ODF edit + undo |
| Particle Fidelity & `.msha` (`PF-01..04`, `T-63`) | `parse_texture_blend` ADD/MUL/SUB/MIX, `EffectBurst` UV scroll animation (`textureSpeed`/`textureRate`), per-emitter performance budgets, real 44-byte BZCC Workshop `.msha` DOCB v1 header inspection |
| Reset safety (`RST-04..05,09,11,13..14`) | manifest failure blocks false reset success (`RESET_FAILED_RECOVERABLE`), durable recovery point create/restore, occurrence-aware physical duplicate reset, full factory header restore removing custom properties |
| Damage/shield/ammo + hit normals (`DS-01..05`, `T-41`) | `maxShield`/`shieldClass`/`maxAmmo` parsed, `damageValue(S/D/A)` and shieldRatio applied before hull spill, `ammoCost` consumed, outward hit normal emitted in `shot_finished`/`run_once`, no-shield path unchanged |
| Animated trails + animation inspection (`TR-01..04`, `T-41`) | crossed-ribbon trail generated and rebuilt for `draw_twirl_trail`, deterministic curved path, real DOCB `.msh` animation metadata inspected, non-DOCB `.msha` rejected |
| Checked native transitions & async monitor (`ND-11..15`, `SM-01..07`, `T-40`) | ledger/instruction/evidence write failures fail closed as `STATE_PERSIST_FAILED` / `RECOVERY_PENDING`; monitor ignores pre-spawn PIDs and mismatched exe/MD5, verifies new game PID, advances mission/probe states, rejects synthetic evidence, resumes across restart, and bounds timeout/cancel |
| Native durability & evidence (`N-D01..10`, `N-E01..08`) | preflight package/session/ledger persistence failure rejected, 1-byte tamper (`PREFLIGHT_SNAPSHOT_HASH_MISMATCH`), corrupt base64, wrong session, UTF-16LE byte-exact source hashing, fail-closed staging/launch, fake PID/mission/probe options ignored, synthetic rejected, operator-imported unattested |
| Titan FX, Floor Physics & Sandbox (`T-36`) | `fvatank` → `garc_c` → `arcbolt` `BoltBeamNode`, `garc_a` `ArcCannonClass` (`ordName=NULL`, 400 dmg), `sim_ember` rigid floor bouncing (`min_y >= 0.0`, `bounce_events_count > 0`), `BottomInteractsWithTerrain` clamping, homing missile (`omegaTurn`) tracking wiggling target, sloped terrain ramp interception/clearance, `shotVariance` spread, shooter velocity inheritance, multi-target splash |
| Persistent `ModLoadout` (`T-34`) | JSON save/load/list/delete under `workspace/loadouts/`, multi-package priority order, explicit per-ODF conflict winner shared identically by `ResourceIndex` and `NativeResourceClosureBuilder`, missing dependency & native eligibility reporting |
| Parser | synthetic CRLF, comments, block comments, quoted `;`, BOM, no-op bytes |
| Duplicates | both declarations preserved; last effective; shadow links |
| Serializer | no-op roundtrip, single-property splice, append |
| Corpus | **all 1,478 base ODFs** byte-identical on no-op |
| Resource index | duplicate candidates, priority winner, missing resolution |
| Fuzzy search | exact/prefix ranking, subsequence (`ivtk`), multi-token, no false positives |
| Dirty cache | fresh document not listed; append marks dirty; clearing removes it |
| Workspace | recoverable transaction, byte-identical source, restore after restart, CONFLICT detection, same-name isolation, traversal/blocked-write rejection, raw replace identity |
| Saved bytes | edit 100→200 → `to_bytes()` equals saved override; second 250 save; reopen 250; original remains 100; revert-to-original removes only the override |
| Transaction recovery | all six real write phases interrupted (temp, backup, journal, old removal, rename, verify) leave a complete old or new revision; missing target + verified temp completes the new revision; missing temp restores the preserved backup; journal removed; manifest reconciled |
| Recovery outcomes | manifest failure during recovery reports RECOVERY_PENDING and keeps the journal; retry commits it; save with a failing manifest restores the previous override; revert commits the manifest before retiring the override and keeps the retired revision in `backups/` |
| Header occurrences | `[A][B][A]` removes only the selected occurrence, CRLF safe, undo byte-identical, empty-header insertion stays inside its section; trailing comments stay with the section they follow only when separated by a blank line; duplicate render names keep per-occurrence identities; rename rewrites both physical brackets |
| Encodings | UTF-8 BOM, CRLF, LF, no final newline, UTF-16LE and UTF-16BE (BOM) roundtrip byte-identical; duplicate same-name properties preserved |
| Native adapter & closure | read-only executable discovery, MD5/size/build-id, `NativeExperimentSession` single identity (N-S1..N-S5), `NativeResourceClosureBuilder` dependency closure & Workshop ambiguity/requirement propagation (N-R1..N-R7), BZN/mount/Lua validation (N1..N7), Steam routes (S1..S6), expected-vs-observed ODF hash semantics & synthetic attestation separation (E1..E8, N-E1..N-E8), `SafeStageManager` MD5 cleanup, restaging MD5 guard, `RECOVERY_PENDING` lock & structured rollback (F1..F12), error-aware JSON parsing (`WorkspaceStore.parse_json_safe`) |
| Native runner | `NativeExperimentRunner` durable session ledger across restart (`recover_sessions`), split `preflight` / `stage` / `launch` (`STEAM_MANAGED` + `OPERATOR_MANUAL` handoff) / `collect_observation` (`contract_version: 1`, `GetCurHealth_delta`, `TIMEOUT`/`FAILED`) / `cleanup_stage` |
| External cache | clean cache reloads after an external edit; dirty cache preserves unsaved bytes and flags CONFLICT |
| Workshop scope | disabled root stays excluded even when runtime workshop support is requested; runtime off excludes it too |
| Collision order & scene | target above ground beats ground; ground beats farther target; sub-step lifetime expiry; 3D AABB obstacle interception & earliest-hit ordering; independent secondary target health |
| Cache revision | parent edit invalidates child merge without a global cache clear; stable across rescan |
| Dependency graph | transitive chain, missing ref, cycle |
| Particles | real 4-header render ODF, all bases, byte-exact roundtrip, real `draw_emit` |
| Graph editing | drag link -> real emitName/renderNameN property; disconnect removes the line; byte-exact after connect+disconnect; link survives save + cache clear; duplicate/delete header; undo/redo; cycle detection; layout saved/restored in the workspace |
| Effects | real `xcoreturrxpl.odf` builds 4 classes + light, duration follows chunks (8 s), missing ODF is reported |
| Audio | real RIFF/WAVE PCM parse, stream construction, peaks, invalid-file rejection |
| Inheritance | documented non-inherited keys excluded; child declarations kept; MorphTank exception |
| Alternate weapon | `altName` resolution, one-level recursion guard, alternate damage, broken altName leaves the primary usable |
| Sweep | linear values, in-memory overrides (including an absent not-inherited key), damage deltas, rollback, no disk write, deterministic CSV with quoted fields |
| Weapons | VSR chain, inheritance (health/armor/damage), flight time, deterministic replay |

Fixtures are read from the installed game and Workshop; nothing copyrighted is copied into the
repository.

## `tests/ui_smoke.tscn` — last run: 265 checks, 0 failures (`TESTED_HEADLESS`)

Boots the real main scene and verifies:

- all prior UI workflows + Reset Safety (`RST-01..RST-14` confirmation/cancel/scoped Particle Lab reset/UI reset preserving active mod loadout), Houdini Value Ladder physical MMB/RMB tests, rigid `StaticBody3D` floors in Weapons Lab & Particle Lab, Titan `garc_c` & `garc_a` live `BoltBeamNode` lightning persisting in `effect_root`, Sandbox `wiggle`/`orbit` Moving Target + `lead`/`track` Shooter Aim + Wall/Terrain Ramp/Pillar props, Particle Lab visual Texture Browser (`120` FX textures) + `11` presets + Mute/Solo + emitter rate/CPU/GPU metrics, RMB resets on sliders/scrubbers, Live-Swap (`Off`/`Object A`/`Object B`/`Weapon`/`Auto`), persistent `ModLoadout` save/load, Saved 3D Scene Presets, and Camera Bookmarks;

- background index builds 17,028 ODFs;
- VSR scenario auto-loads (`gatstabvsr_c` → `atstabvsr_c`, 120 m/s, damage 100 vs armor H);
- FIRE produces weapon/collision/damage telemetry;
- FIRE ALT fires the resolved `altName` chain and its telemetry names that weapon;
- editing `damageValue(H)` to 200 changes the next shot to 200.00;
- undo propagates to the weapon profile and the next shot (100.00), and redo restores 200.00;
- edit propagation also refreshes the raw editor content, the structured inspector, the dependency
  summary and the weapon profile; the particle and audio labs hold the same document object;
- the original game file on disk is unchanged;
- the run uses a unique `user://smoke_workspace_*` root (env `BZ_SHAMAN_WORKSPACE_ROOT`), not production data;
- settings are written inside that root; the production `settings.json` hash is unchanged;
- save-all writes the edited document to that isolated workspace, clears its dirty flag, and
  `to_bytes()` equals the saved file (no stale-source shortcut);
- clearing the document cache and restoring from the manifest brings back damage 200 with OVERRIDE state;
- Rescan rebuilds the index to 17,028 ODFs without restarting;
- staged export writes the edited ODF and contains the edit;
- save → export exports the saved 250/275 bytes, the report write is confirmed, its text contains the
  exported MD5, and two exports in the same second get distinct stage directories;
- after a cache clear + manifest restore the editor serves the last saved edit while the original
  game source keeps its own hash;
- a real cross-file render ODF produces external graph nodes, each with an OPEN control that opens
  the referenced file;
- duplicate physical headers appear as one `merged` node; NEW NODE creates a real documented
  `draw_sprite` header and RENAME renames it (undoable);
- a real render ODF populates the particle graph;
- dragging a connection writes a real reference, marks the document dirty, and disconnecting restores the original bytes;
- the graph link survives save-to-workspace, cache clear and restore (OVERRIDE state);
- graph duplicate/delete operate on real headers and undo/redo restore them;
- cycle detection sees an existing edge in the loaded document;
- node positions are saved to the isolated workspace and restored after reload;
- an impact spawns an APPROXIMATED explosion burst from the real xpl ODF, appears in the 3D scene,
  is recorded in telemetry with its emitter count, and restart clears it;
- a 5-point damageValue sweep renders rows, uses the live 200 edit as baseline, rolls back to
  200, and saves its CSV to the workspace;
- split native GUI controls (`PREFLIGHT`, `STAGE`, `LAUNCH / HANDOFF`, `COLLECT`, `CLEANUP`) drive
  `NativeExperimentRunner` durable sessions end-to-end inside the isolated workspace;
- 3D Weapons Lab scene authoring: 5 camera presets (`overview`, `muzzle`, `target`, `side`, `top`),
  target transform offset & yaw, 3D obstacle interception protecting target hull, independent secondary
  target damage, interactive Timeline panel (`filter`, `scrub_timeline_to`, `select_timeline_event`),
  and bounded 8-channel audio pool remaining strictly at 8 channels across 12 rapid plays;
- Particle Lab `SAVE DEPENDENCIES` toolbar button tracks dirty external dependencies with a badge,
  refreshes live 3D preview when an external `file.header` ODF is edited, and saves coordinated
  workspace overrides without touching original files;
- the Audio Lab lists inherited weapon sounds;
- inspector, raw editor, schema (1,490 properties) and theme are live.

## Not covered

- Interactive mouse/keyboard UI automation.
- Multiple workshop package orders beyond the same-package/base/other policy.
- Audio playback in headless mode; compressed WAV codecs (metadata only).
- Native BZCC live execution (preflight, closure, allowlisted staging, durable session ledger,
  controlled Lua contract, checked transitions, async monitor, and evidence gate tests pass; the
  original isolated session was `BLOCKED` by `STEAM_USER_NOT_LOGGED_IN` (`ActiveUser = 0x0`), a later
  GUI session reported `STRUCTURALLY_VALID` / `STEAM_MANAGED`, and no live-attested launch has run;
  `BZ2R` is read-only).
- Interactive GUI run of the packaged Windows GUI (`build/BZ_ODF_SHAMAN.exe`) is verified via
  windowed OpenGL self-verification (`BZ_SHAMAN_VERIFY_GUI_DIR` capturing `exe_weapons_lab.png`,
  `exe_particle_lab.png`, and `gui_verify_report.txt`); mouse/keyboard OS-level input automation is
  still outside automated tests.
- Performance budget thresholds or CI regression gates (the bench harness measures only).

## `tests/bench.gd` — measurement only

```bat
tools\run_bench.cmd
```

Prints index scan, 500-file parse throughput, 100 cold inheritance merges, 500 deterministic
shots and static memory. There is no pass/fail threshold; compare runs by hand. Last run (2026-11-22 Wave G `T-70`):

```
index: 17028 ODFs, 37161 asset names in 1213.4 ms
parse: 500 ODFs, 0.55 MB in 599.8 ms (0.9 MB/s)
inheritance: 100 cold merges of ivtank_vsr in 94.5 ms (0.94 ms each, 131 rows)
sim: 500 shots in 5896.9 ms (11.79 ms each, 500 hits)
memory: 148.4 MB static
```

## Regression rule

A passing unit test is not a completed workflow. Any feature claimed complete must also be
exercised through the running application (the smoke test exists for that reason).
