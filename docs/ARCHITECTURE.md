# Architecture

## Shape

```
main.tscn
└─ MainWindow (Control)          scripts/ui/main_window.gd
   ├─ Resource explorer         ResourceIndex
   ├─ Weapons Lab               WeaponLab → WeaponProfile → ProjectileSim
   ├─ Particle Lab              ParticleLab → OdfDocument.render_headers()
   ├─ Inspector / Raw / Deps    OdfDocument, SchemaRegistry, DependencyGraph
   └─ status / export / theme   WintageTheme
```

The ODF data model has no dependency on Godot UI or rendering. `OdfDocument`,
`OdfInheritance`, `SchemaRegistry`, `ResourceIndex` and `DependencyGraph` are plain
`RefCounted` classes; tests run headless without a renderer.

## Core decisions

### 1. Splice, don't re-render

`OdfDocument` stores the original text and the exact character span of every value.
`set_entry_value()` replaces only that span, then shifts later spans. Everything else —
comments, header order, duplicate lines, newline convention — is untouched by construction.
With no edits, `to_bytes()` returns the original file bytes unchanged. Verified on 1,478
stock ODFs.

### 2. Last duplicate wins, but every declaration stays

A duplicate `[Header] key` is kept in the AST. The earlier entry is marked `shadowed_by`,
the later entry `shadow_of`. The inspector shows both and uses the later value as effective.
This matches the documented ODF rule without destroying evidence.

### 3. Inheritance is a separate resolution layer

`OdfInheritance` follows `classLabel` to a resolvable parent ODF, repeats (max depth 6, cycle
guard), then merges ancestor-first. Values remember their source path and whether they are
inherited. The inspector lists inherited values read-only; the simulation reads the merged
map. Properties the local docs mark as **not inherited** are scoped to their documenting
header and excluded from ancestor merging (`GameObjectClass.unitIcon` / `unitStatus` /
`ignoreMissingInf`, `OrdnanceClass.shotRadius`); a child's own declaration still applies.

### 4. One document instance per path

`OdfDocument.load_cached()` is the shared document store used by the inspector, dependency
graph, inheritance resolver and simulation. That is what makes “edit a value → fire again”
work without saving: the lab's `WeaponProfile` and the inspector point at the same object.
Raw text is applied with `replace_text()` on that object, so identity never changes.
`Revert` invalidates the cache entry and reloads from disk.

Saved overrides are loaded under the original source path by `WorkspaceStore`, and the
manifest records source, relative path, timestamp and source MD5. The original game file is
never written. A changed source is served with `workspace_conflict = true`; documents expose
ORIGINAL / OVERRIDE / DIRTY / CONFLICT state in the title.

`OdfInheritance` cache keys include the revision of every document in the resolved parent
chain plus the index generation. Editing a parent invalidates its descendants automatically;
no global `clear_cache()` is needed.

### 5. Background index, fixed layout

`ResourceIndex.scan()` runs on a `Thread`. The UI only reads after `scan_thread` joins, so no
dictionary is mutated while the main thread reads it. The index stores ODFs and asset names
with root/package/priority metadata; duplicate candidates are retained, not overwritten.
`generation` increments on each scan. Workshop inclusion is a scan-time parameter and is
restored afterwards; it never rewrites the user's enabled flags.

### 6. Simulation is data-driven and labelled

`WeaponProfile` resolves the real chain and re-reads merged values on every `refresh()`.
`ProjectileSim` is deterministic (fixed sub-step 1/240, seeded RNG) and exposes events with
real simulation timestamps. Fidelity is stated as `APPROXIMATED` wherever the model is an
editor interpretation, and `DATA-DRIVEN` where values come from files.

### 7. Theme tokens, not scripts

The Wintage repository is MIT. Only its JSON token files are shipped. `WintageTheme` builds a
Godot `Theme` (StyleBoxFlat bevels, SystemFont Verdana fallback, state colours) from those
tokens. Tampermonkey code is never executed.

## Subsystem status

| Subsystem | Status |
|---|---|
| Application shell | Working |
| Wintage theme engine | Working (16 themes) |
| ODF parser / serializer | Working, lossless |
| ODF inheritance | Working |
| Schema registry | 1,490 properties / 128 classes |
| Resource index & `ModLoadout` | `TESTED_HEADLESS` / `TESTED_GUI`: 17,028 ODFs + 37,161 unique asset names, persistent `ModLoadout` profiles (`scripts/core/mod_loadout.gd`) with explicit conflict winners shared by `ResourceIndex` & `NativeResourceClosureBuilder`, ranked fuzzy search, manual rescan |
| Dependency graph | Forward, missing, cycles, alternatives |
| Structured inspector | Working (`HoudiniScrubber` LMB drag / MMB Value Ladder / RMB reset-to-default on all value controls, occurrence-aware factory reset, Live-Swap `Off`/`A`/`B`/`Weapon`/`Auto`) |
| Raw editor | Working |
| Undo/redo | Working (text snapshots + compound graph edits) |
| Workspace saves & Reset Safety | `TESTED_HEADLESS` (`RST-01..RST-14`): recoverable transaction journal, confirmed Reset All with impact preview & durable recovery points, manifest failure preserves in-memory & saved overrides (`RESET_FAILED_RECOVERABLE`), scoped Particle Lab resets, UI reset isolated from active mod loadout |
| Weapons Lab & 3D Sandbox | `TESTED_HEADLESS` / `TESTED_GUI` (`APPROXIMATED`): DOCB `.msh` + hardpoints + `EMISSION_OP_MULTIPLY`, rigid `StaticBody3D` floor, world-space `BoltBeamNode` lightning (`draw_bolt`/`draw_beam`/`ArcCannonClass`), floor-bouncing embers/chunks + `BottomInteractsWithTerrain` clamping, homing missiles (`omegaTurn`), deterministic `shotVariance` spread, recoil kick, configurable Moving Target (`Strafe`/`Wiggle`/`Orbit`/`Approach`), Shooter Aim (`Manual`/`Track`/`Lead`/`Fixed Forward`), Wall/Terrain Ramp/Pillar props, Saved 3D Scene Presets, Camera Bookmarks, 3D `damageRadius` wireframe, interactive Timeline, bounded 8-channel audio pool, split native BZCC controls |
| Parameter sweep | Working (deterministic, in-memory overrides, no writes, CSV export) |
| Particle Lab | `TESTED_HEADLESS` / `TESTED_GUI` (`APPROXIMATED`): editable header graph, rigid `StaticBody3D` preview floor, visual Texture Browser (`120` FX textures), `11` emitter presets, Quick Render Inspector with ColorPickers & RMB resets, Mute (`M`) / Solo (`S`), rate/CPU/GPU cost metrics, cross-file `file.header` nodes, `SAVE DEPENDENCIES` with partial-save recovery, scoped resets |
| Audio Lab | PCM playback (plus Weapons Lab bounded 8-channel fire/explosion SFX pool), waveform, inherited refs; no distance/pitch model |
| Model viewer | `BzMeshReader` decodes DOCB v1 `.msh` hierarchy (`turret_y`/`turret_x`/`hp_*`), `.material`, DDS/TGA textures in Weapons Lab; embedded animation metadata (bone/pose/animation counts) and companion `.msha` lookup are reported honestly, skin weights/tracks remain `NOT_IMPLEMENTED` |
| Node graph authoring | Connections, reference editing/validation, header create/rename/duplicate/delete, multi-select, copy/paste, subgraph duplicate, compound undo/redo, `11` presets, visual Texture Browser, search, quick inspector with ColorPickers & Mute/Solo/metrics, cycle refusal, `SAVE DEPENDENCIES`, and layout persistence |
| Native BZCC adapter & runner | `STRUCTURALLY_VALID` / `TESTED_HEADLESS` (`N-D01..N-D10`, `N-E01..N-E08`, `ND-11..ND-15`, `SM-01..SM-07`): durable preflight package persistence, byte-exact MD5 hashes (`UTF-8`/`BOM`/`UTF-16LE`), checked durable transitions (`STATE_PERSIST_FAILED` / `RECOVERY_PENDING`), bounded async `NativeProcessMonitor` with pre-spawn PID capture/exe verification/mission-probe state machine/restart recovery, fail-closed staging/launch, honest production vs test evidence separation; live launch `BLOCKED_EXTERNAL` (`STEAM_USER_NOT_LOGGED_IN`, `NATIVE_VERIFIED: 0`) |
| Comparison / calibration | Evidence comparison implemented; native verified count `0` while live launch is blocked |
| Windows packaged export | Working with 4.7.2 templates (`tools/build_windows.cmd`) |
| Benchmark harness | `tools/run_bench.cmd` (index/parse/inherit/sim timings) |

## Data flow

```
disk ODF ──parse──► OdfDocument (text + spans + AST)
                       │
        schema ────────┼──► Inspector controls
        inheritance ───┼──► merged values ──► WeaponProfile ──► ProjectileSim ──► telemetry
        index ─────────┴──► DependencyGraph (forward refs, missing, cycles)
```

## Extension points

- Schema: regenerate `data/odf_schema.json` with `tools/extract_schema.py`; no code changes
  needed for new documented properties.
- Coverage: regenerate `data/coverage_registry.json` with `tools/build_coverage.py`.
- New weapon types: extend `WeaponProfile.refresh()` and `ProjectileSim` rather than adding
  special cases to the UI.
- Parameter sweeps: extend `ParameterSweep.PROPERTIES` and keep values transient in
  `WeaponProfile.overrides`; never mutate the shared document to vary a property.
- Native adapter: implement next to `scripts/core`, keep staging in `user://` and never write
  into game roots.
