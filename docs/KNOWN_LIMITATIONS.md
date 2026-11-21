# Known limitations

Ordered by impact. None of these is silently removed from scope.

## Native game integration

- **Live BZCC launch is reproducible, but the engine exits before mission initialization.**
  `NativeTestAdapter` generates structurally validated ASCII v1192 `luamission.dll` `.bzn` scenarios
  with verified stock `test` terrain, exact `<stage>/assets` `AddDirRecurse` mount configs, controlled
  `WriteToFile` Lua state-machine scripts, Steam launch capability routing (`STEAM_MANAGED`,
  `STEAM_LAUNCH_OPTIONS`, `OPERATOR_MANUAL`, `DIRECT_EXECUTABLE`, `UNSUPPORTED`), and separated
  schema-vs-trusted-session evidence attestation. T-20 observed a logged-in Steam client,
  `steam_appid.txt` present in read-only `BZ2R`, and `steam.exe -applaunch 624970` successfully
  spawning `battlezone2.exe` with the staged `/config` and `shaman_shot.bzn`. BZCC 2.0.185 then
  terminated roughly four seconds after startup, before any `Config: 'AddDirRecurse'` or mission
  initialization line, and never produced the session-bound LuaMission observation artifact.
  The exact launch and shutdown are recorded in
  `.saipen/evidence/native/T-20-native-probe-1136976.json` and the BZCC startup log it names.
  No live engine measurement or calibration is claimed; read-only `BZ2R` is never modified, and
  native verified count remains `0`. The original `STEAM_USER_NOT_LOGGED_IN` / exit 53 state was
  a session-specific condition and is no longer the current blocker.
- Reload requirements inside BZCC (scene/mission/full restart) are not measured.
- No supported live modification inside the running game is claimed.

## Assets

- **DOCB `.msh` models are decoded for static geometry, `.material` descriptors, DDS/TGA textures,
  and `hp_*`/turret hierarchy.** `.msha` files, animations, skin weights, and BC5S-compressed DDS
  normal maps are not decoded; undecoded models fall back to clearly labelled `PLACEHOLDER MESH` boxes.
- `.pak` archives are not unpacked, so assets stored only inside `.pak` files are not loaded.
- Audio Lab plays uncompressed PCM WAVs and draws waveforms; Weapons Lab mixes fire/explosion
  WAVs through a bounded 8-channel multichannel pool linked to the interactive Timeline panel;
  compressed WAV codecs show metadata only, and there is no distance attenuation or pitch variation.
- Team colour and animations are not previewed.
- The Model Inspector tab lists declared references; 3D inspection lives in the Weapons Lab.

## Simulation (`APPROXIMATED`)

- Rigid flat floor (`StaticBody3D` at `y = 0`) plus placeable sandbox Walls, Pillars, Boxes, and sloped 3D Terrain Ramps (`shape="ramp"`) with ray-vs-wedge and particle-bounce collision; no full heightmap terrain, water, or mesh-accurate building colliders.
- Oriented 3D bounding-box (OBB) and sphere/ramp collision; ignores exact hull mesh triangles, collision layers, and `boxCollide`.
- Shield absorption is an APPROXIMATED preview: `shieldClass` ratio and `DamageShield` multiplier are applied before hull spill, but no real shield mesh/texture animation, deflection angle, or regeneration is simulated. Damage-over-time, status effects, mines, deployables, and friendly fire remain `NOT_IMPLEMENTED`.
- Approximated beam/lightning (`BoltBeamNode` for `draw_bolt`/`draw_beam`/`ArcCannonClass`), homing missile turning (`omegaTurn`), seeded `shotVariance` spread, recoil kick, moving shooter velocity inheritance, configurable Moving Target patterns (`Strafe`/`Wiggle`/`Orbit`/`Approach`), and Shooter Aim modes (`Manual`/`Track`/`Lead`/`Fixed Forward`) are implemented as `APPROXIMATED` preview models, not native engine formulas.
- Salvos/bursts use `salvoCount`/`salvoDelay`; `altName` alternate fire is previewable via FIRE ALT, but the `switchMask`/deploy transition itself, ammo cost, and morph timing are not modelled.
- Multi-target splash falloff is linear (`APPROXIMATED`) across primary and secondary targets on vehicle/obstacle/ground impacts.
- No native tick-rate/unit calibration; treat distances as editor metres (`NATIVE_VERIFIED: 0`).

## ODF editing

- Header/property case is preserved; duplicate headers are grouped by name, not by file position
  for lookup.
- Raw-editor “Apply” replaces the document (and clears its undo stack); it is explicit.
- Undo history is in-memory only, not persisted.
- Batch editing across several properties, diff-before-commit review, side-by-side ODF
  comparison, presets and before/after replay are not implemented.
- The parameter sweep varies exactly one property over a numeric range; it does not combine
  values. CSV export is implemented (`save_sweep_csv`) and covered by the UI smoke test.
- No project manifest/module import/export packaging beyond single-ODF staging.

## Particles

- Connections and reference values are editable and persisted as emitName/renderNameN; nodes can
  be created (`NEW NODE`, documented `draw_sprite` template), renamed (all local references are
  rewritten), duplicated (local property lines only, inheritance is not flattened), multi-selected,
  copied/pasted, subgraph-duplicated with internal edge remapping, preset-inserted, searched,
  quick-inspected, and unreferenced headers deleted, with compound document undo/redo and cycle
  refusal; node positions persist per source path in `workspace/graph_layout.json`.
- External render references (`file.header`) are resolved through the resource index relative to the
  referring ODF (with same-directory sibling fallback) and drawn as separate external nodes showing
  live header preview fields, `DIRTY`/`OVERRIDE` tags, and an `OPEN` control. Editing an external
  referenced ODF immediately refreshes the Particle Lab live 3D preview, and the `SAVE DEPENDENCIES`
  button saves dirty external dependencies alongside the active ODF into the workspace. External
  files are still edited after opening them rather than inline inside the parent graph node.
- A header name that occurs more than once is a single merged graph node labelled `merged ×N`; the
  values shown and edited are the effective (last) physical occurrence. Physical-occurrence editing
  for duplicates lives in the Inspector/parser, not as separate graph nodes.
- Explosion bursts read particleClass/count/velocity, lifeTime, colours, radii and simulateBase, and
  play resolved PCM explosion WAVs through the bounded 8-channel audio pool; particle counts and
  sizes are editor-scaled and expansion curves are simplified. `xplExpire` falls back to the ground
  explosion when the ODF declares none.
- Preview maps a subset of documented fields across 11 render bases; animated crossed-ribbon trails approximate `draw_trail`/`draw_twirl_trail`, while exact engine ribbon geometry, LOD, and light attenuation remain approximations.
- Live Parameter Inspection reports parsed ODF values vs aggregate node counts, lifetime and radius-curve points; per-particle selection/lifetime inspection is still not implemented.
- `draw_billboard` is unknown/unsupported (not in local docs); kept editable as raw text.

## Resources

- Precedence is an editor policy (same package → base → other mods), not verified engine mount
  order. Conflicting Workshop packages exist for `atstab_c.odf` (100 vs 140 heavy damage).
- `.pak` archives are not indexed.
- Asset references are matched by filename, not by model/material internal paths.
- Indexing is in-memory only; each launch rescans. The Rescan button rebuilds the full index
  from scratch; there is no filesystem watcher or incremental rescan.
- Saves use a recoverable per-file transaction (verified temp → durable journal → backup →
  replace → verify → commit; startup reconciliation). This is not crash-atomic: a process kill
  during the remove/rename window is recovered from the journal, not prevented. Recovery reports
  explicit outcomes (`COMMITTED`, `ROLLED_BACK`, `RECOVERY_PENDING`, `UNRECOVERABLE`); a failed
  manifest reconciliation keeps the journal for retry and never counts as committed. Revert-to-
  original commits the manifest removal before retiring the override bytes and keeps the retired
  revision in `backups/`. There is no all-or-nothing multi-file transaction or workspace browser/
  diff. Restored overrides are flagged OVERRIDE/CONFLICT; there is no merge UI for conflicts.
- A dirty cached document never has external source changes overwritten; it is marked CONFLICT.
  A clean cache reloads the source, but there is no persistent index fingerprint cache yet.
- The workspace root can be redirected with `BZ_SHAMAN_WORKSPACE_ROOT`; smoke tests use a
  unique temporary root. There is no UI control for switching roots yet.
- If a source ODF disappears after saving, its override can still be restored in CONFLICT
  state (from the manifest) and exported; there is no pruning or source-remap UI yet.

## UI

- Layout is a fixed three-pane shell plus tabs; panels are resizable but not dockable, and
  layout/workspace presets are not persisted.
- No multi-viewport or multi-document tabs.
- Search covers ODF file names only (ranked fuzzy); not file contents, directory paths or
  asset names.
- No keyboard shortcut customisation; only Ctrl+O/S/Z/Y.
- Theme is a token conversion, not pixel-identical browser chrome.
- No screenshots/recording/report export beyond the text export report.
- Sweep results are text rows plus a CSV file; there is no chart or multi-property matrix.

## Models and native validation

- Baked **DOCB v1 `.msh`** meshes (e.g. `ivtank00.msh`, `ivscav00.msh`), `.material` descriptors,
  DDS/TGA textures, `turret_y`/`turret_x` hierarchy, and `hp_*` hardpoints are decoded by
  `scripts/core/bz_mesh_reader.gd` and displayed in the Weapons Lab; `.msha` and animations are not
  decoded, and any unresolvable model falls back to an explicit `PLACEHOLDER MESH` box.
- `scripts/native/` (`NativeExperimentSession`, `NativeResourceClosureBuilder`, `SafeStageManager`,
  `NativeTestAdapter`, `NativeExperimentRunner`) enforces single immutable session identity,
  resource closure + Workshop ambiguity checks, allowlisted staging (`user://native_tests`) with
  MD5-verified cleanup (`MODIFIED_FILE_PRESERVED`), restaging MD5 guard, `RECOVERY_PENDING` lock,
  and mid-overwrite rollback, durable session ledger across restart, split native GUI controls,
  validated `luamission.dll` `.bzn` + exact-mount `/config` + `WriteToFile` Lua contract
  (`contract_version: 1`), expected-vs-observed ODF hash verification, and strict separation of
  synthetic vs runner-attested receipts, checked durable transitions, and the bounded async
  `NativeProcessMonitor`. Live launch reports `BLOCKED` (`STEAM_USER_NOT_LOGGED_IN`) when no logged-in
  Steam session is active; a later GUI session reported `STRUCTURALLY_VALID` / `STEAM_MANAGED`,
  which is still not a live attested run (`NATIVE VERIFIED` count remains `0`).

## Build

- A Windows x86_64 release with embedded PCK builds and boots with Godot 4.7.2 templates
  (`tools/build_windows.cmd`, including self-contained `editor_data/export_templates`).
- The package is unsigned, has no installer, and has been verified both headless and in an
  automated windowed GPU run (`exe_weapons_lab.png`, `exe_particle_lab.png`, `gui_verify_report.txt`).
- Performance is measured by `tools/run_bench.cmd`, but no budget thresholds or CI regression
  gate exist; numbers are for comparison only.
