# Testing

## Commands

```bat
tools\run_tests.cmd
```

Equivalent:

```bat
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . --script res://tests/test_runner.gd
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --headless --path . res://tests/ui_smoke.tscn
```

## `tests/test_runner.gd` — last run: 803 checks, 0 failures (`TESTED_HEADLESS`)

| Category | Coverage |
|---|---|
| Reset safety (`RST-04..05,09,11,13..14`) | manifest failure blocks false reset success (`RESET_FAILED_RECOVERABLE`), durable recovery point create/restore, occurrence-aware physical duplicate reset, full factory header restore removing custom properties |
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

## `tests/ui_smoke.tscn` — last run: 225 checks, 0 failures (`TESTED_HEADLESS`)

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
  controlled Lua contract, and evidence gate tests pass; live launch is `BLOCKED` by
  `STEAM_USER_NOT_LOGGED_IN`, `ActiveUser = 0x0`, in the isolated Windows session and `BZ2R` is read-only).
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
shots and static memory. There is no pass/fail threshold; compare runs by hand. Last run (2026-11-21 Wave G `T-35`):

```
index: 17028 ODFs, 37161 asset names in 1321.0 ms
parse: 500 ODFs, 0.55 MB in 633.4 ms (0.9 MB/s)
inheritance: 100 cold merges of ivtank_vsr in 88.6 ms (0.89 ms each, 131 rows)
sim: 500 shots in 3763.5 ms (7.53 ms each, 500 hits)
memory: 147.6 MB static
```

## Regression rule

A passing unit test is not a completed workflow. Any feature claimed complete must also be
exercised through the running application (the smoke test exists for that reason).
