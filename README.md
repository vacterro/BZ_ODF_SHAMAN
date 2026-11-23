**v0.0.1**

# BZ_ODF_SHAMAN

Visual ODF authoring, simulation and validation laboratory for **Battlezone: Combat Commander**.
Godot 4.7 · Windows x64 · Wintage **Golden Default** theme.

> Status: working vertical slices P0–P4 + Autonomous Night Shift Waves B–G (`T-60..T-70`): Independent Native Launch Eligibility Gates (`STRUCTURALLY_VALID`, `RESOURCE_CLOSURE_VALID`, `STAGE_ELIGIBLE`, `CONFIG_COMPATIBLE`, `EXECUTION_ENVIRONMENT_READY`, `LAUNCH_ELIGIBLE`, `NL-01..NL-06`) enforcing `CONFIG_REQUIRES_ROOTDIR_PLACEMENT` before process launch, Safe Stock Addon launch route (`STOCK_ADDON` via stock `bzone.cfg` `@mydocsdir\addon` without modifying `BZ2R`), Active-Experiment Cleanup Guard (`ACTIVE_EXPERIMENT_CANNOT_CLEANUP` + evidence retention outside disposable stage, `NC-01..NC-07`), Unified `CombatScenario` Clock & Fire/Reload/DoT State Machine (`CB-01..CB-08`), Immutable `CombatReplaySnapshot` with Full Spatial/Hitbox Restoration & ODF Revision Isolation (`RP-01..RP-08`), Live Combat-State Timeline & Actor Inspector in Weapons Lab, Particle Lab Fidelity (`PF-01..PF-04`), and real 44-byte DOCB `.msha` header inspection.
> Live BZCC launch comparison remains `NATIVE_VERIFIED: 0`: `STOCK_ADDON` dry-run staging (`tools\run_native_experiment.cmd`) verified complete stock closure and `CONFIG_STOCK_ADDON_ROUTE` without touching `BZ2R`, while live Steam execution in this Windows session is `BLOCKED_EXTERNAL` (`STEAM_USER_NOT_LOGGED_IN`, `ActiveUser=0x0`). See [docs/NATIVE_TESTING.md](docs/NATIVE_TESTING.md) and [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).

## What works now

- **Lossless ODF core** — source-aware parser/serializer with byte-exact no-op roundtrip over
  all **1,478** stock base-game ODFs. Edits splice only the value span; comments, ordering,
  duplicate declarations, CRLF/LF, BOM and encoding survive.
- **ODF inheritance** — `classLabel` parent chains are resolved across 17,028 indexed ODFs
  (base + Workshop). Example: `ivscav_vsr → ivscav` supplies `maxHealth=3000`, `armorClass=H`;
  `atstabvsr_c → atstab_c` supplies `damageValue(H)=100`.
- **Schema registry** — **1,490** documented properties across **128** classes, extracted from
  the local `ODF.md`; all **15** documented render bases and **6** simulate bases.
- **Structured inspector** — bool/int/float/vector/color/enum/reference controls, exact-raw
  toggle, shadowed duplicates, inherited values, documented defaults/descriptions/tooltips,
  undo/redo, raw editor.
- **Resource explorer + dependency graph** — 17,028 ODFs and 37,161 unique asset names
  indexed with ranked fuzzy search, context-aware asset lookup (same package → base game → other mods),
  duplicate candidates, missing references, cycles and *alternatives* shown per reference.
  Search ranks exact → prefix → substring → subsequence and requires every whitespace-separated token.
- **Weapons Lab & 3D Sandbox** — real shooter → weapon → ordnance chain (including direct `ArcCannonClass` `ordName = NULL` beams like `garc_a`), authentic **DOCB `.msh`** 3D meshes (`ivtank00.msh`, `fvtitan_skel.msh`, `ivscav00.msh`), `.material` descriptors, DDS/TGA textures and `hp_*` hardpoints (with explicit `PLACEHOLDER MESH` fallback when undecoded), rigid `StaticBody3D` floor (`y = 0`), world-space animated `BoltBeamNode` lightning (`draw_bolt`/`draw_beam`, e.g. Titan `garc_c` → `arcbolt`), floor-bouncing `sim_ember`/`sim_chunk`/`sim_spray` debris and `BottomInteractsWithTerrain` clamping, barrel recoil kick, deterministic `shotVariance` spread, moving shooter velocity inheritance, homing missile guidance (`omegaTurn`), configurable Moving Target patterns (`Stationary`/`Strafe`/`Wiggle`/`Orbit`/`Approach` + Speed/Amplitude/Frequency/XYZ/Yaw), Shooter Aim modes (`Manual`/`Track`/`Lead`/`Fixed Forward`), placeable rigid sandbox props (`Wall`, sloped `Terrain Ramp`, `Pillar`, `Box`, secondary `Targets`), Saved 3D Scene Presets & Camera Bookmarks, 3D `damageRadius` splash wireframe overlay, live-swap while browsing ODFs (`Off`/`Object A`/`Object B`/`Weapon`/`Auto`), compact `Telemetry` / interactive `Timeline` / `Scene` / `Sweep` / `Native BZCC` tabs, bounded 8-channel audio pool, **FIRE ALT** for `altName`, and split native BZCC controls backed by a durable session ledger.
- **Parameter sweep** — batch-run one property (shotSpeed, lifeSpan, shotRadius, damageValue)
  across a range with a baseline row and per-point damage/flight deltas. Values are in-memory
  overrides; no ODF file is written. Results export to CSV under `user://workspace/sweeps/`.
- **Benchmark harness** — `tools/run_bench.cmd` measures index scan, ODF parse throughput,
  cold inheritance merges and deterministic shots; numbers, not pass thresholds.
- **Particle Lab** — real render ODFs become an editable header graph with rigid `StaticBody3D`
  preview floor, visual **Texture Browser** (thumbnails, search, FX/Fire/Smoke/Bolt categories),
  11 ready-to-use documented emitter presets (`Fireball`, `Arc Lightning`, `Shockwave Ring`,
  `Plasma Sphere`, `Bouncing Embers`, `Ground Dust`, `Bouncing Debris`, `Sparks`, `Beam Bolt`,
  `Smoke Trail`, `Flash Light`), Quick Render Inspector with `ColorPickerButton` RGBA swatches,
  `renderBase`/`simulateBase`/`textureBlend` dropdowns, `BottomInteractsWithTerrain` toggle,
  per-emitter **Mute (`M`) / Solo (`S`)**, live emission rate / active count / CPU+GPU cost
  metrics, RMB reset-to-default on every value control, scoped resets (`RESET THIS ODF` /
  `RESET SELECTED NODE` / `RESET SELECTED EXTERNAL ODF` / confirmed `RESET DEPENDENCY GRAPH`),
  and coordinated `SAVE DEPENDENCIES` with partial-save recovery.
- **Persistent `ModLoadout` profiles** — save/load multi-package priority lists, explicit per-ODF
  conflict winners shared identically by `ResourceIndex` and `NativeResourceClosureBuilder`,
  workspace override snapshots, source hashes, and native-test eligibility reports (explicitly
  labelled as editor resolution policy, not verified BZCC mount order).
- **Audio Lab** — resolves declared *and inherited* sound references, parses real RIFF/WAVE
  PCM assets, draws a waveform and plays them, with loop/volume controls.
- **Safe export / workspace** — recoverable save transactions (verified temp, durable journal,
  backup, replace, startup reconciliation; not advertised as crash-atomic), a `project.json` manifest
  and persistent overrides restored on the next launch (ORIGINAL / OVERRIDE / DIRTY /
  CONFLICT). Staged export writes every workspace override with a report and MD5; original
  game files are never written unless you explicitly confirm an overwrite dialog. “Save all
  edited” writes every dirty document, and “Rescan” rebuilds the index without restarting.
  Tests run against an isolated `BZ_SHAMAN_WORKSPACE_ROOT`, never production data.
- **Wintage themes** — all 16 theme token files shipped (MIT); live theme switching, persisted.

## Reference scenario (verified)

The handoff's VTStats scenario resolves against installed Workshop content:

```
gatstabvsr_c (ivtank_vsr)  →  atstabvsr_c (ordnance, inherits atstab_c)  →  ivscav_vsr
shotSpeed 120 m/s · lifeSpan 0.834 s · range 100.08 m · shotRadius 0.5 (editor fallback;
documented as not inherited, so bullet.odf's value is correctly ignored)
target armor H · damageValue(H) = 100 · target maxHealth 3000
```

Edit `damageValue(H)` to `200` in the inspector, fire again, and telemetry reports **200.00**
damage against the same hull. The original file on disk is unchanged; the export is staged.

The workshop package `3532748119` contains the VSR files. Other installed packages also
provide `atstab_c.odf` with different values; the resolver shows every alternative and prefers
same-package → base game → other mods. This is a preview policy, not a claim about BZCC's
actual addon mount order.

## Run

```bat
run.cmd
```

or directly:

```bat
"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" --path "V:\___VAC\__K\__CODE\_MISC\_BZ_ODF_SHAMAN"
```

First launch indexes the base game and Workshop in a background thread (~2–3 s on the
reference machine, 17,028 ODFs), then auto-loads the VSR scenario if present, else the
stock `ivtank4` / `ivscav12` fallback.

## Tests

```bat
tools\run_tests.cmd
```

Last verified run (2026-11-23): **1,106 core checks + 28 T-122 coherence + 31 T-123 lifecycle + 44 T-128 cleanup-contract checks (1,209 PASS, 0 failures) and UI smoke PASS**, covering: ODF core, full 1,478-file stock corpus roundtrip, precedence, fuzzy search, dirty cache, non-inherited properties, alternate weapon, parameter sweep, dependency graph, particles, explosion runtime, blend modes & UV animation (`PF-01..PF-04`), rigid floor bounce (`sim_ember`/`BottomInteractsWithTerrain`), Titan `draw_bolt` / `ArcCannonClass` lightning, homing missiles (`omegaTurn`), sloped terrain ramps, Unified `CombatScenario` Clock, Reload/DoT State Machine & Spatial/ODF-Isolated Sandboxed Replay (`CS-01..CS-12`, `CB-01..CB-08`, `RP-01..RP-08`), Live Combat-State Timeline & Actor Inspector, WAV audio, DOCB `.msh` + hardpoints + `EMISSION_OP_MULTIPLY` + real 44-byte `.msha` header inspection, Reset Safety (`RST-01..RST-22`), Native Launch Eligibility Gates & Safe Stock Addon Route (`NL-01..NL-06`, `NB-01..NB-08`), Active-Experiment Cleanup Guard & Evidence Retention (`NC-01..NC-07`), Native Resource Closure & GUI `NativeSessionService` Monitor (`RC-01..RC-07`, `NM-01..NM-10`, `N-D01..N-D10`, `N-E01..N-E08`, `ND-11..ND-15`, `SM-01..SM-07`), Persistent `ModLoadout` profiles, Saved Scene Presets, Camera Bookmarks, Particle Lab Texture Browser + 11 presets + Mute/Solo/metrics, RMB value resets, Houdini Value Ladder, Live-Swap, and real `OS.kill` transaction recovery, plus T-128 cross-session stage ownership, evidence-based cleanup finalization, strict discovery ledger/intent mapping, honest `durable_complete` API results and full recovery-token identity. A Windows release package exports (`build/BZ_ODF_SHAMAN.exe`, `112,395,360` bytes, SHA256 `0cc94a10b57c671751d6117e3157882a35a540dfe79bcd0faf0dce576a9c6917`), headless-boots cleanly, and passes windowed GPU self-verification (`.saipen/evidence/gui_verify/t128_final/` screenshots and report; see [docs/EVIDENCE.md](docs/EVIDENCE.md)).

## Documentation

| Document | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | subsystems, data flow, design decisions |
| [docs/ODF_COMPATIBILITY.md](docs/ODF_COMPATIBILITY.md) | parser/serializer semantics, coverage |
| [docs/RESOURCE_RESOLUTION.md](docs/RESOURCE_RESOLUTION.md) | roots, precedence, duplicates, cycles |
| [docs/PREVIEW_FIDELITY.md](docs/PREVIEW_FIDELITY.md) | what the simulation models and what it does not |
| [docs/PARTICLE_GRAPH.md](docs/PARTICLE_GRAPH.md) | render graph and preview mapping |
| [docs/NATIVE_TESTING.md](docs/NATIVE_TESTING.md) | staging, launch plan, honest blockers |
| [docs/WINTAGE_THEMES.md](docs/WINTAGE_THEMES.md) | token → Godot theme pipeline |
| [docs/TESTING.md](docs/TESTING.md) | test inventory and evidence |
| [docs/EVIDENCE.md](docs/EVIDENCE.md) | captured commands and results |
| [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) | every known gap |

## Safety

- Original game/Workshop/Wintage/VRV files are treated as read-only inputs.
- Saving writes to `user://workspace/odf/...` and records `user://workspace/project.json`;
  export writes to a timestamped folder.
- Export into a configured game root is refused.
- Overwriting an original requires an explicit confirmation dialog.

## Layout

```
scripts/core/   ODF document, schema, inheritance, resource index, dependency graph, theme, DOCB mesh, WAV
scripts/sim/    weapon profiling, deterministic projectile/obstacle/multi-target simulation, parameter sweep
scripts/lab/    Weapons Lab, Particle Lab, Audio Lab, effect runtime
scripts/native/ NativeExperimentSession, NativeResourceClosureBuilder, SafeStageManager, NativeTestAdapter, NativeExperimentRunner
scripts/ui/     application shell (inspector, raw editor, deps, export, GPU self-verify)
data/           extracted schema + coverage registry
tools/          docs extractor, coverage builder, test/build launchers
tests/          headless test runner + UI smoke scene
themes/         Wintage token files (MIT)
```
