# Evidence

All results below were refreshed on this machine on 2026-11-22 with
Godot `4.7.2.stable.official.ed1daf0bf`.

## Environment verified

- Game: `V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R` (bz2r_res present, 6.7 GB).
- Workshop: `V:\__STORE_V\_SOFT\Steam\steamapps\workshop\content\624970` (97 packages).
- VSR reference files present:
  - `…/3532748119/Recycler_Variants/Standard/ISDF/Weapons/Cannons/AT Stab/gatstabvsr_a.odf`
  - `…/gatstabvsr_c.odf`
  - `…/Vehicles/ivtank_vsr.odf`
  - `…/Vehicles/ivscav_vsr.odf`
- Docs: `BATTLEZONE/DOCS/ODF.md` (12,662 lines), `PARTICLE.md` (793 lines).
- Wintage: MIT, 16 theme JSON files.

## Test run — core

Command:

```bat
Godot_v4.7.2-stable_win64.exe --headless --path . --script res://tests/test_runner.gd
```

Result: `1,067 checks, 0 failure(s)` · `RESULT: PASS` (`TESTED_HEADLESS`), with no ObjectDB leak warning, no
`JSON.parse_string` parse errors, and completely empty stderr (covering all prior P0–P4 checks,
Native Launch Eligibility Gates & Safe Stock Addon Route `NL-01..NL-06`, Unified Combat Clock &
Reload/DoT State Machine `CB-01..CB-08`, Spatial/ODF-Isolated Sandboxed Replay & Baseline
Preservation `RP-01..RP-08`, Active-Experiment Cleanup Guard & Evidence Retention `NC-01..NC-07`,
Reset Safety `RST-01..RST-22`, Native Startup Diagnosis & Crash Log Correlation `NB-01..NB-08`,
Native Resource Closure & Auto Observation / Monitor Persistence `RC-01..RC-07`, `NM-03..NM-08`,
`N-D01..N-D10`, `N-E01..N-E08`, `ND-11..ND-15`, `SM-01..SM-07`, Persistent Combat State
`CombatActorState` / `CombatScenario` `CS-01..CS-12`, Particle Fidelity & real 44-byte `.msha`
inspection `PF-01..PF-04`, `T-36` Titan `fvatank` → `garc_c` → `arcbolt` `BoltBeamNode` & `garc_a`,
rigid floor `sim_ember` bounce & `BottomInteractsWithTerrain` clamping, homing missile `omegaTurn`
tracking, sloped terrain ramps, moving shooter velocity, multi-target splash, and `T-34`/`T-39` strict
`ModLoadout` profiles).

Highlights:

- Base corpus enumerated: 1,478 ODFs; all roundtrip byte-identically.
- VSR chain resolved with inheritance:
  `gatstabvsr_c → atstabvsr_c`, shotSpeed 120.0, lifeSpan 0.834, armor H,
  maxHealth 3000, damageValue(H) 100.0, range 100.08. `shotRadius` reads the editor
  fallback 0.5 because the documented not-inherited rule discards `bullet.odf`'s value.
- Graph header surgery: duplicating `Core` in a synthetic ODF produces `Core_copy` with both
  property lines and the same values; deleting it removes only that section; undo restores it and
  redo removes it again; deleting a missing header is refused.
- Explosion effect runtime: `xcoreturrxpl.odf` builds four particle classes (Core, Shock, Light,
  Chunks) plus an OmniLight, with duration 8.05 s from the chunks lifetime; a missing xpl is an
  explicit error, never an empty “success”.
- Non-inheritance: unitIcon/unitStatus/ignoreMissingInf (GameObjectClass) and shotRadius
  (OrdnanceClass) are excluded from ancestors; MorphTankClass.unitStatus still inherits; a
  child's own declaration wins.
- Fuzzy search: exact name first, `ivtk` finds `ivtank_vsr.odf`, `scv vsr` finds
  `ivscav_vsr.odf`, substring `turr` still matches, `zzzz` returns nothing.
- Dirty cache: a fresh cached document is not listed, append marks it dirty, clearing removes it.
- Alternate weapon: synthetic `altName` resolves one level, applies its own 200 damage and does
  not recurse; an unresolvable altName leaves the primary chain usable and is reported.
  The real VSR chain resolves `gatstabvsr_a -> atstabvsr_a`.
- Parameter sweep: 3-point shotSpeed and damageValue sweeps produced expected flight times
  and 50/100/150 damage with deltas; overrides were cleared and the temp ODF text was unchanged.
  CSV export is deterministic (3 comments + header + baseline + 3 rows) and quotes a comma in
  the scenario label.
- Simulated 80 m shot: hit at 0.650 s, 100.0 damage, monotonic telemetry, replay identical.
- Particles: `xcoreturrxpl.odf` found 4 render headers; real `draw_emit` found in
  `baked/Effects/Emitters`.
- Dependency graph: transitive + missing + cycle all detected.
- Audio: stock `amb_wind.wav` parsed as PCM 16-bit mono, AudioStreamWAV built, waveform
  peaks extracted; a 4-byte non-RIFF file was rejected with a clear error.
- Saved bytes (P0): edit 100→200, save, `to_bytes()` equals the override, save again with 250,
  reopen serves 250, and the original source still contains 100.
- Header occurrences (P0): `[A][B][A]` removal deletes only the selected occurrence; CRLF is not
  doubled; undo restores byte-identical text; an empty header's appended property stays before
  the next bracket line.
- Transaction matrix (P0): each real write phase (`after_temp`, `after_backup`, `after_journal`,
  `after_remove_old`, `after_rename`, `after_verify`) is interrupted with the test-only fault hook.
  Every restart yields a complete old revision or a complete new revision, with the manifest either
  reconciled or explicitly pending — never a missing target.
- Recovery outcomes (P0): a failing manifest during recovery returns `RECOVERY_PENDING`, keeps the
  journal and does not count as committed; the next attempt commits and removes the journal. A save
  whose manifest update fails restores the previous override bytes.
- Revert transaction (P0): a failing manifest leaves the override file and its entry intact; after
  the manifest is writable, the manifest entry is removed first and only then the override bytes;
  the retired revision stays in `backups/ord.odf.bak`. Missing and externally changed sources are
  reported with `source_missing` / `source_changed` and are never rewritten.
- Header ownership (P0): a trailing comment block belongs to the preceding section only when a blank
  line separates it from the next header; otherwise it stays for the next section. Duplicate render
  names keep distinct occurrence ids; rename rewrites every physical bracket and refuses collisions.
- Encodings: UTF-8 BOM, CRLF, no final newline, UTF-16LE and UTF-16BE all roundtrip byte-identically.
- Native adapter: real executable discovered read-only, MD5/size/build id recorded, scenario staged
  outside the game root, `STAGED_ONLY` manifest written, staging inside the game root refused.
- External cache: a clean cache reloads after an external edit; a dirty cache keeps its unsaved
  bytes and raises CONFLICT instead of silently serving stale source.
- Workshop scope: a user-disabled Workshop root stays excluded even when runtime workshop
  support is requested; runtime off excludes an enabled root as well.
- Collision ordering: a target just above the ground wins over the ground plane, ground wins over
  a farther target, and a sub-step lifetime expiry is placed at the lifetime fraction.
- Workspace safety: save leaves the source byte-identical; restart restores 200 from the manifest;
  externally changed source is flagged CONFLICT; same-name sources get distinct paths; `../` and
  directory-blocked writes fail without touching previous data; revert-to-original removes only
  the override.
- Cache coherence (P0): a parent override edit changes the child's merged value without
  `clear_cache()` and survives a rescan; raw `replace_text()` keeps document identity and the
  next shot uses the edited value (100 → 200 → 100).

## Test run — UI smoke

Command:

```bat
Godot_v4.7.2-stable_win64.exe --headless --path . res://tests/ui_smoke.tscn
```

Result: `265 checks, 0 failure(s)` · `RESULT: PASS` (`TESTED_HEADLESS`, empty stderr; includes authentic
`ivtank00.msh`, `fvtitan_skel.msh`, `ivscav00.msh` loading, `hp_cannon_1` turret yaw origin/direction,
live explosion FX edit + undo, Reset Safety `RST-01..RST-22`, strict `ModLoadout` `ML-06`,
app-owned `NativeSessionService` non-blocking GUI polling surviving tab switch to Particle Lab (`NM-01`, `NM-02`, `NM-09`),
Active-Experiment Cleanup Guard (`NC-01`, `NC-02`, `NC-04`), Unified `CombatScenario` Clock / Reload Enforcement / Pause / Single-Step / DoT (`CB-01..CB-06`),
Live Combat-State Timeline & Actor Inspector + Sandboxed Replay (`RP-08`), Native Launch Mode selector (`STOCK_ADDON` / `CUSTOM_CONFIG`),
3D Combat Actor HUD (Target Shield bar + Shooter Ammo/Energy/Reload readout), Houdini Value Ladder MMB/RMB resets,
Titan `garc_c` & `garc_a` live `BoltBeamNode` lightning, rigid `StaticBody3D` floors in both Labs,
Sandbox props, Particle Lab Texture Browser (`120` FX textures) + `11` emitter presets + Mute/Solo + rate/cost metrics,
Live-Swap, persistent `ModLoadout` save/load, Saved 3D Scene Presets, and Camera Bookmarks).

The smoke run exports `BZ_SHAMAN_WORKSPACE_ROOT` to a unique `user://smoke_workspace_*` root
and deletes only that root; production `user://workspace` is never the target. Settings are
redirected into the same root: `settings.json` SHA-256 was
`cafedeb259e32f428877204b54966df3d48d51e64072421ff95c4a8631511d80` before and after the run,
with an unchanged mtime.

Observed:

```
resource index built: 17028 ODFs
a document auto-opened
weapon lab scenario resolved
VSR weapon resolved: gatstabvsr_c
shotSpeed present: 120.0
damage derived: 100.0 (armor H)
FIRE ALT control present
alternate weapon resolved
alternate shot fired in UI
telemetry: weapon activated / impact / damage
damageValue(H) located or appended in ordnance ODF
edited damage applied by simulation (200.00)
editing never modified the original game file
undo propagated to the next simulated shot (100.00)
redo propagated to the next simulated shot (200.00)
edit propagation keeps the raw editor showing the applied value
edit propagation rebuilds the structured inspector
edit propagation refreshes dependencies
particle and audio labs share the live document revision
external file.header references become graph nodes
external node resolves to a real indexed file
external node offers an OPEN control
OPEN navigates to the referenced file
duplicate occurrences are labelled as a merged effective view
NEW NODE created a real render header
created node uses a documented renderBase value
RENAME renamed the render header
rename is undoable
export after save writes the saved 250 bytes
export report write is confirmed before success is announced
export report records the exported file hash
two exports in the same second get distinct stage directories
second export uses the newer saved revision
restart serves the last saved edit (275)
original game ODF is unchanged since the save
staged export file written
save-all saved the edited document(s)
save-all wrote the workspace file
save-all cleared the dirty flag
saved document bytes equal the current working revision
smoke workspace is the isolated test root
saved file stays inside the test root
exported ODF contains the edit
sweep offers a damageValue property for the target armor
parameter sweep produced 5 rows
sweep baseline uses the live 200 damage edit
sweep top point applies 250 damage
sweep results rendered in the UI
sweep rolled back: edit still reads 200
sweep CSV saved to workspace
sweep CSV header present
Audio Lab lists inherited weapon sound references
particle graph populated from real render ODF
found an unused render link to create
graph connection persisted as a real ODF reference
graph edit marks the document dirty
connect+disconnect restores byte-exact ODF
graph edit saved to the workspace
graph link restored after save + cache clear
FX toggle control present
impact spawned an explosion effect
effect node is in the 3D scene
telemetry records the explosion ODF and emitter count
restart clears explosion effects
graph duplicate created a real header: Core_copy
duplicate header has editable property lines
graph delete removed the duplicate header
graph undo restored the deleted header
graph redo removed it again
cycle detection sees the existing Core -> Shock edge
graph layout saved in the workspace
graph layout restored after reload
inspector populated
raw editor populated
schema registry loaded: 1490 properties
Wintage theme applied
settings stay inside the test root
workspace overrides restored after cache clear
saved damage 200 restored into the editor
restored document shows OVERRIDE state
manual rescan rebuilt the index (17028 ODFs)
```

Export evidence: `user://smoke_export/shaman_export_<timestamp>/odf/.../atstabvsr_c.odf`
plus `export_report.txt`. The original VSR ODF bytes were compared before/after editing and
were identical.

## Warning classification (P1)

Both diagnostics previously present in a PASS were reproduced and fixed; neither was suppressed.

| Diagnostic | Cause found | Fix | Re-run |
|---|---|---|---|
| `Unicode parsing error … Unexpected NUL character` ×3 | a literal NUL escape in `workspace_store.gd::clean_rel()` compiled by GDScript | scan code points (`unicode_at(i) == 0`) instead of a literal | 0 occurrences |
| `22 ObjectDB instances were leaked at exit` | `OdfEntry.shadowed_by` / `shadow_of` were strong entry↔entry references for duplicate properties, forming reference cycles that never free | both links are `WeakRef`-backed with the same object-or-null public behavior | no ObjectDB warning |

The core runner also clears the static document and inheritance caches before `quit()`. The
combined effect is visible in the same 336-check PASS (5.1 s, down from 8.2 s).

## Benchmark harness

Command:

```bat
tools\run_bench.cmd
```

Result (measurement only, no thresholds, 2026-11-22 Wave G `T-70` release run, Godot `4.7.2-stable`):

```
index: 17028 ODFs, 37161 asset names in 1213.4 ms
parse: 500 ODFs, 0.55 MB in 599.8 ms (0.9 MB/s)
inheritance: 100 cold merges of ivtank_vsr in 94.5 ms (0.94 ms each, 131 rows)
sim: 500 shots in 5896.9 ms (11.79 ms each, 500 hits)
memory: 148.4 MB static
```

## Windows package

Command:

```bat
tools\build_windows.cmd
```

Result: exit 0, `build/BZ_ODF_SHAMAN.exe` (`112,194,896` bytes, MD5 `5842931d1cf374dc7097044ebedae9ef`,
x86_64, embedded PCK, Godot 4.7.2 templates resolved from self-contained `editor_data/export_templates`),
rebuilt 2026-11-22 after Waves B–G (`T-65..T-70`).
The embedded PCK includes independent native launch eligibility gates (`NL-01..NL-06`), safe `STOCK_ADDON`
launch route, active-experiment cleanup guard (`NC-01..NC-07`), unified `CombatScenario` clock & fire/reload/DoT
state machine (`CB-01..CB-08`), immutable spatial/ODF-isolated `CombatReplaySnapshot` (`RP-01..RP-08`), and
Live Combat-State Timeline + Actor Inspector.

Interactive windowed GPU verification (`TESTED_GUI`, `BZ_SHAMAN_VERIFY_GUI_DIR`, isolated `BZ_SHAMAN_WORKSPACE_ROOT`):
- Exit code `0`, `theme=goldendefault`, `font_aa=none`, `ui_scale=1.0`, `master_volume=0.85`, viewport `1920x1061`
- Indexed `17028 ODFs, 37161 asset names` in `1418 ms`
- Authentic base-game `ivtank00.msh`, `fvtitan_skel.msh` (`6458` tris, `27` nodes, `fvatank00_d.dds`, `hp_cannon_1`/`hp_cannon_2`), and `ivscav00.msh` (`1942` tris) rendered with non-whitewashed `EMISSION_OP_MULTIPLY` materials, rigid `StaticBody3D` floors (`rigid_floor_weapon_lab=true`, `rigid_floor_particle_lab=true`), live reload HUD (`Shooter ammo: 2189/2200 energy: ∞ [READY]`), and 1bpp crisp `Verdana_m1` Golden Default chrome
- `titan_bolt_rendered=true`, `spawned_effects=3`, `audio_pool={active:2, capacity:8, plays:4, steals:0}`, `timeline_events=13`
- Original `BZ2R/battlezone2.exe` MD5 verified unchanged (`e2fa7458cf2604315f48915acd288689`), `bzone.cfg` SHA256 unchanged (`7a79d5bca9535ddea71cd492265adda7b2932177f769c3d4615c7407c2ba90de`), zero SHAMAN files in `BZ2R`
- Captured & visually inspected screenshots: `.saipen/evidence/gui_verify/exe_weapons_lab.png`, `exe_particle_lab.png`, `exe_titan_lightning.png`, `gui_verify_report.txt`

The exported binary also headless-boots cleanly (`build\BZ_ODF_SHAMAN.exe --headless --quit-after 120`, exit 0).

## Capability Status Table (2026-11-22)

| Capability | Status | Evidence |
|---|---|---|
| Lossless ODF parser/serializer (1,478 stock roundtrip) | `VERIFIED` (`TESTED_HEADLESS`) | `tests/test_runner.gd` |
| Unified Combat Clock, Reload/DoT & Spatial Sandboxed Replay (`CombatActorState`/`CombatScenario`) | `VERIFIED` (`APPROXIMATED`, `TESTED_HEADLESS` + `TESTED_GUI`) | `CS-01..CS-12`, `CB-01..CB-08`, `RP-01..RP-08`, `exe_weapons_lab.png` |
| Live Combat-State Timeline & Actor Inspector | `VERIFIED` (`TESTED_GUI` + `TESTED_HEADLESS`) | `tests/ui_smoke.gd`, `gui_verify_report.txt` (`timeline_events=13`) |
| Native launch eligibility gates (`NL-01..NL-06`) & safe `STOCK_ADDON` route | `VERIFIED` (staging/gates) / `BLOCKED_EXTERNAL` (live Steam) | `NL-01..NL-06`, `.saipen/evidence/native/native-probe-799678.json` |
| Native active-experiment cleanup guard & evidence retention (`NC-01..NC-07`) | `VERIFIED` (`TESTED_HEADLESS` + `TESTED_GUI`) | `NC-01..NC-07`, `tests/ui_smoke.gd` |
| Native startup diagnosis & `/config` classifier | `VERIFIED` (`TESTED_HEADLESS`) | `T-60-native-startup-diagnosis.md`, `NB-01..NB-08` |
| Native resource closure & `NativeSessionService` GUI monitor | `VERIFIED` (`TESTED_HEADLESS` + `TESTED_GUI`) | `RC-01..RC-07`, `NM-01..NM-10`, `native-probe-799678.json` |
| Particle Lab blend modes, UV animation & budgets | `VERIFIED` (`APPROXIMATED`, `TESTED_HEADLESS` + `TESTED_GUI`) | `PF-01..PF-04`, `exe_particle_lab.png` |
| Authentic DOCB `.msh` geometry & hardpoints | `VERIFIED` (`TESTED_HEADLESS` + `TESTED_GUI`) | `gui_verify_report.txt` |
| DOCB `.msha` header identity (44-byte stubs) | `VERIFIED` (`TESTED_HEADLESS`) | `PF-04` |
| `.msha` skeletal animation / skin weights | `NOT_IMPLEMENTED` | Explicitly reported in `BzMeshReader` |
| Live native BZCC LuaMission calibration | `BLOCKED_EXTERNAL` (`NATIVE_VERIFIED: 0`) | `STEAM_USER_NOT_LOGGED_IN` (`ActiveUser=0x0`) in this Windows session |

## Schema / coverage evidence

```
classes=128 properties=1490 renderBases=15 simulateBases=6
coverage: parsing COMPLETE 1490; editing COMPLETE 1424, RAW_ONLY 66;
preview APPROXIMATED 47, NOT_IMPLEMENTED 1443; native NOT_TESTED 1490
```

## Not evidenced (explicitly)

- Live native BZCC LuaMission observation and comparison (`NATIVE_VERIFIED = 0`). Controlled T-60 diagnostics (`.saipen/evidence/native/T-60-native-startup-diagnosis.md`) established that stock BZCC boots cleanly (`Battlezone 2026-11-22 11.26.43.3718.log`) and stock `ds_16.bmf` exists in `bz2r_res/interface/Fonts/DS/ds_16.bmf`; external `/config` paths outside `@rootdir` are skipped by BZCC 2.0.185 (`select_bzone_cfg`) while `BZ2R` remains strictly read-only.
- `.msha` skeletal/bone animation tracks and skin weights.
- OS-level mouse/keyboard click injection outside the Godot UI smoke / self-verify harness.
- Parameter sweep chart (CSV export exists and is tested).
