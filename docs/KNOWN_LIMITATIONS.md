# Known limitations

Ordered by impact. None of these is silently removed from scope.

## Native game integration

- **Live BZCC `/config` path restriction, safe `STOCK_ADDON` route & Steam authentication (`NATIVE_VERIFIED: 0`).**
  Controlled T-60 diagnostics (`.saipen/evidence/native/T-60-native-startup-diagnosis.md`) proved that
  stock BZCC 2.0.185 boots cleanly (`Battlezone 2026-11-22 11.26.43.3718.log`) and that stock
  `ds_16.bmf` exists in `bz2r_res/interface/Fonts/DS/ds_16.bmf`. BZCC 2.0.185's `select_bzone_cfg`
  (`i76win.cpp` RVA `0xfbc34`) only loads bare `/config <filename.cfg>` files inside `@rootdir` (`BZ2R\`),
  skipping `ConfigureFileSystem()` for external paths. SHAMAN now enforces independent launch eligibility
  gates (`NL-01..NL-06`) so unresolved `CONFIG_REQUIRES_ROOTDIR_PLACEMENT` blocks process launch while
  still permitting staging and explicit operator handoff (with SHA256 + collision check), and also
  provides the safe `STOCK_ADDON` route mounting uniquely named owned `SHAMAN_*` folders via stock
  `bzone.cfg`'s `@mydocsdir\addon` without modifying `BZ2R`. Live Steam execution in the current Windows
  session remains `BLOCKED_EXTERNAL` (`STEAM_USER_NOT_LOGGED_IN`, `ActiveUser=0x0`), so `NATIVE_VERIFIED`
  remains honestly `0`.
- Reload requirements inside BZCC (scene/mission/full restart) are not measured.
- No supported live modification inside the running game is claimed.

## Assets

- **DOCB `.msh` models are decoded for static geometry, `.material` descriptors, DDS/TGA textures,
  and `hp_*`/turret hierarchy.** Real 44-byte DOCB v1 `.msha` header identity is parsed honestly
  (`is_empty_stub`, `skeletal_skinning_supported = false`), while full `.msha` skeletal tracks,
  skin weights, and BC5S-compressed DDS normal maps remain `NOT_IMPLEMENTED`; undecoded models fall
  back to clearly labelled `PLACEHOLDER MESH` boxes.
- `.pak` archives are not unpacked, so assets stored only inside `.pak` files are not loaded.
- Audio Lab plays uncompressed PCM WAVs and draws waveforms; Weapons Lab mixes fire/explosion
  WAVs through a bounded 8-channel multichannel pool linked to the interactive Timeline panel;
  compressed WAV codecs show metadata only, and there is no distance attenuation or pitch variation.
- Team colour and animations are not previewed.
- The Model Inspector tab lists declared references; 3D inspection lives in the Weapons Lab.

## Simulation (`APPROXIMATED`)

- Rigid flat floor (`StaticBody3D` at `y = 0`) plus placeable sandbox Walls, Pillars, Boxes, and sloped 3D Terrain Ramps (`shape="ramp"`) with ray-vs-wedge and particle-bounce collision; no full heightmap terrain, water, or mesh-accurate building colliders.
- Oriented 3D bounding-box (OBB) and sphere/ramp collision; ignores exact hull mesh triangles, collision layers, and `boxCollide`.
- Persistent actor-level combat state (`CombatActorState` / `CombatScenario`, `T-62`, `T-66`, `T-67`) unifies projectile stepping, shooter-owned ammo/energy, reload cooldown enforcement (`READY`/`RELOADING`/`INSUFFICIENT_AMMO`/`INSUFFICIENT_ENERGY`/`DESTROYED`/`DISABLED`), persistent shield/hull across sequential shots, DoT status effects, independent secondary target shields and splash propagation, and immutable spatial/ODF-isolated sandboxed `CombatReplaySnapshot` replays as `APPROXIMATED` preview models; no real shield mesh/texture animation, deflection angle, regeneration, mines, deployables, or friendly fire are simulated.
- Approximated beam/lightning (`BoltBeamNode` for `draw_bolt`/`draw_beam`/`ArcCannonClass`), homing missile turning (`omegaTurn`), seeded `shotVariance` spread, recoil kick, moving shooter velocity inheritance, configurable Moving Target patterns (`Strafe`/`Wiggle`/`Orbit`/`Approach`), and Shooter Aim modes (`Manual`/`Track`/`Lead`/`Fixed Forward`) are implemented as `APPROXIMATED` preview models, not native engine formulas.
- Salvos/bursts use `salvoCount`/`salvoDelay`; `altName` alternate fire is previewable via FIRE ALT, but the `switchMask`/deploy transition itself and morph timing are not modelled. Ammo and energy use the selected alternate ordnance costs exactly once. Physical slot identity is passed independently of the alternate `WeaponProfile` into volley, request, `ShotIdentity`, snapshot and replay records.
- Multi-target splash falloff is linear (`APPROXIMATED`) across primary and secondary targets on vehicle/obstacle/ground impacts.
- Multi-barrel firing resolves one record per declared `weaponHardN` and preserves missing-hardpoint
  positions; SALVO cycles those records and stores the actual hardpoint in `ShotIdentity`. Replay GUI
  states distinguish `RUNNING`, `PAUSED`, `CANCELLED`, `COMPLETE`, `FAILED` and `PARTIAL_RESULT`; a
  step-limit stop is `FAILED`, never `COMPLETE`. The Physical Hardpoint Inspector on the Timeline tab
  shows one row per declared slot with `RESOLVED_MODEL_NODE`, `DECLARED_BUT_MISSING`,
  `FALLBACK_ORIGIN` or `APPROXIMATED` fidelity and the last fired `ShotIdentity`; it never promotes a
  guessed origin to a verified physical hardpoint. Replay fidelity remains `APPROXIMATED`.
- No native tick-rate/unit calibration; treat distances as editor metres (`NATIVE_VERIFIED: 0`).

## ODF editing

- Header/property case is preserved; duplicate headers are grouped by name, not by file position
  for lookup.
- Raw-editor “Apply” replaces the document (and clears its undo stack); it is explicit.
- Undo history is in-memory only, not persisted.
- Batch editing across several properties and side-by-side ODF comparison are not implemented
  (immutable `CombatReplaySnapshot` capture & sandboxed replay are implemented in Weapons Lab).
  A related read-only view exists for interrupted transactions: `compare_journal_target_revision()`
  decodes hash-authenticated previous/working bytes from a save-group journal and lists changed
  ODF properties in the Recovery Center confirmation preview. T-122 extends the same read-only view
  with an independent `physical_source_diff`: byte equality plus comment, duplicate-occurrence and
  encoding/BOM differences, so a comment-only change is never shown as an effective-value change.
  It is a recovery aid, not a general pre-commit diff tool.
- T-122 recovery trust boundary: a save-group `group_id` is a single validated path component bound
  to its journal filename; `restore_working` refuses a current revision changed after the confirmation
  preview (journal hash, manifest fingerprint, per-file MD5 and existence are captured in a revision
  token and rechecked immediately before mutation); successful direct restores converge or invalidate
  cached `OdfDocument` instances. Legacy callers without an explicit UI token get an atomically
  captured token at call time, so the same guard always runs.
- The parameter sweep varies exactly one property over a numeric range; it does not combine
  values. CSV export is implemented (`save_sweep_csv`) and covered by the UI smoke test.
- No project manifest/module import/export packaging beyond single-ODF staging.

## Particles

- Physical reference slots are shown as separate `OUT n · renderNameN` ports and as a physical-slot
  list. A mouse disconnect uses the port/focused physical entry; parallel references with no
  selected slot are refused as `AMBIGUOUS_GRAPH_CONNECTION` instead of removing the first match.
  Keyboard and mouse disconnect share the same identity-aware removal path. A failed move restores
  byte-exact original ODF bytes, encoding, dirty flag and undo history.
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
- `PERSISTENT_RESOURCEINDEX_CACHE: IMPLEMENTED`, `ODF/INI_CONTENT_FINGERPRINT: IMPLEMENTED`,
  and `CACHE_PAYLOAD_VERIFICATION: IMPLEMENTED`. A warm launch loads the persistent cache instead
  of rescanning; the Rescan button still rebuilds from scratch and there is no filesystem watcher.
  `BINARY_ASSET_CONTENT_HASHING: PARTIAL / METADATA-BASED` — binary mesh/texture cache validity is
  metadata-based, not a verified byte identity.
- Saves use a recoverable per-file transaction (verified temp → durable journal → backup →
  replace → verify → commit; startup reconciliation). This is not crash-atomic: a process kill
  during the remove/rename window is recovered from the journal, not prevented. Recovery reports
  explicit outcomes (`COMMITTED`, `ROLLED_BACK`, `RECOVERY_PENDING`, `UNRECOVERABLE`); a failed
  manifest reconciliation keeps the journal for retry and never counts as committed. Revert-to-
  original commits the manifest removal before retiring the override bytes and keeps the retired
  revision in `backups/`. There is no all-or-nothing multi-file transaction or workspace browser/
  diff. Restored overrides are flagged OVERRIDE/CONFLICT; there is no merge UI for conflicts.
- A dirty cached document never has external source changes overwritten; it is marked CONFLICT.
  A clean cache reloads the source; index fingerprints and payloads are persisted with checksum verification.
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
- T-86 Recovery Center: startup discovery is read-only and lists interrupted Save Dependencies
  save groups plus incomplete native cleanup intents from durable records; every recover /
  resolve action is a deliberate user choice. Discovery does not repair anything silently, and
  a `CLEANUP_FINALIZATION_PENDING` intent surfaces as retry-eligible rather than auto-deleting.
- T-86 Dependency Save Preview: SAVE DEPENDENCIES computes a read-only preview (operation,
  override presence, revision, conflicts). With zero conflicts it saves directly (one click);
  with conflicts or unavailable sources it opens a confirmation dialog listing every intended
  write before any journal or file is touched.

## Models and native validation

- Baked **DOCB v1 `.msh`** meshes (e.g. `ivtank00.msh`, `ivscav00.msh`), `.material` descriptors,
  DDS/TGA textures, `turret_y`/`turret_x` hierarchy, and `hp_*` hardpoints are decoded by
  `scripts/core/bz_mesh_reader.gd` and displayed in the Weapons Lab. Real 44-byte DOCB v1 `.msha`
  header identity is parsed (`EMBEDDED_DOCB_ANIMATION: IMPLEMENTED`), but timing is
  `APPROXIMATED` and `EXTERNAL_MSHA_SKELETAL_SKINNING: NOT_IMPLEMENTED`; any unresolvable model
  falls back to an explicit `PLACEHOLDER MESH` box.
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
  which is still not a live attested run (`NATIVE_VERIFIED: 0`).
- Native stage conflicts are real: three `SHAMAN_*` stages exist in the BZCC Addon folder. Two are
  manifest-owned with matching hashes in `STAGED` state; one has no manifest
  (`STAGE_OWNERSHIP_UNRESOLVED`). The read-only stage inventory button in the Native tab reports
  session id, state, ownership, hash status, unknown files and cleanup eligibility. Cleanup is
  refused for every non-terminal or unresolved stage; no game, Workshop or stage file is deleted
  automatically. `SafeStageManager.reconcile_stage()` reads the durable session ledger on top
  of the read-only inventory. Cleanup eligibility now requires manifest ownership, matching
  hashes, a session id, a parseable ledger whose record has the same session id in a terminal
  state, agreement between ledger and evidence state, and no active or recoverable
  `process_monitors.json` entry. Corrupt, missing, absent-session, disagreeing or
  monitor-active cases return `PROTECT` with `recovery_pending: true` instead of
  `CLEANUP_ELIGIBLE`. Monitor validation checks the persisted state independently of the
  `active` flag: a nonterminal or unknown state with `active=false` is still `ACTIVE` for
  cleanup purposes and stays protected; a terminal state with `recoverable=true` or a pending
  cancellation is also protected. The Native stage inventory uses this same reconciliation
  verdict as its final cleanup column, so the GUI cannot show `allowed` when the authoritative
  check says `PROTECT`; manifest inspection is kept only as a separate preliminary candidate.
  It never deletes; any removal still requires an explicit authorized cleanup call. The actual
  `NativeExperimentRunner.cleanup_stage()` route now applies the same authoritative
  reconciliation before deletion. `RECOVERY_PENDING`, `FAILED` and `PARTIAL_CLEANUP` sessions are
  protected even when a mutable monitor object looks terminal; active, recoverable, nonterminal
  or unknown monitor states also block deletion. A durable `CLEANUP_PREPARED` intent is written
  and read back before any file is removed; a final commit failure is recorded as
  `CLEANUP_RECOVERY_PENDING` so no false `CLEANED_UP` state is published.
- T-86 native cleanup hardening: a never-launched `STAGED` stage is cleanup-eligible only with
  POSITIVE proof (ledger record present with a never-launched-safe state, no launch-requested
  checkpoint, no monitor, hashes matching); anything less stays `PROTECT`. When unknown files
  survive cleanup, the manifest is retained alongside a `stage_provenance.json` snapshot and a
  `stage_cleanup_receipt.json` naming every preserved foreign file — the result honestly reports
  `FOREIGN_FILES_PRESERVED` + `stage_directory_retained` instead of implying the directory
  vanished. The final `CLEANUP_COMPLETE` intent write is read back and verified; an unverifiable
  finalization publishes `CLEANUP_FINALIZATION_PENDING` in the ledger and session record.
  `NativeExperimentRunner.discover_cleanup_intents()` provides the read-only startup scan of
  incomplete intents (schema, session identity, ledger, monitor, remaining owned files, foreign
  survivors, retry classification) used by the Recovery Center. T-122 separates terminal outcomes:
  a partial cleanup retaining foreign files writes `CLEANUP_PARTIAL_FOREIGN_FILES_PRESERVED` to both
  ledger and intent (never an unqualified `CLEANUP_COMPLETE`), while `discover_cleanup_intents(true)`
  keeps completed history inspectable; by default only actionable intents count toward the Recovery
  Center warning total, so a normal restart after successful cleanup no longer produces a false
  interrupted-transaction warning.
- T-128 native cleanup contract: the shared authorization gate binds requested session ID, session
  record ID, session object ID, stage evidence ID, manifest `stage_id` and reconciled ledger session;
  a stage owned by another session is refused by both normal and terminal entrypoints. Finalization-only
  retry never treats a missing manifest as proof: it requires a verified stage cleanup receipt bound to
  the same session/stage or a durable `ok=true`, non-partial prior cleanup plus a clean file inventory;
  otherwise `FINALIZATION_EVIDENCE_INSUFFICIENT` protects the stage. Discovery uses strict
  intent-to-ledger correspondence (`CLEANUP_COMPLETE` ↔ `CLEANED_UP`, partial ↔ `PARTIAL_CLEANUP`)
  and reports missing receipts, unclassified stage contents and wrong-session receipts as drift.
  Cleanup results report `files_cleanup_ok`, `ledger_commit_ok`, `intent_finalized`,
  `durable_complete` and `recovery_required`; `ok` means durable completion only. A supplied recovery
  token with a missing or mismatched `group_id` is refused and never rewritten.
- T-86 save-group recovery integrity (see also the ODF editing section): a `COMPLETE` or
  `RECOVERED` group is refused with `RECOVERY_NOT_APPLICABLE` and zero mutation; recovery
  restores the exact pre-transaction structural state (absent override stays absent and its
  manifest entry is removed; existing overrides restore byte-exact previous bytes; an empty
  override stays present and empty); unknown or newer current revisions and source revision
  drift block rollback as `RECOVERY_CONFLICT_PENDING` which stays discoverable at startup until
  an explicit `keep_current` / `restore_working` resolution; working-copy artifacts are stored
  under a unique per-source identity (no basename collisions) and hash-verified; the final
  `RECOVERED` verdict requires a verified durable journal write, otherwise the honest
  `RECOVERY_FINALIZATION_PENDING` is reported. A true cross-process verifier
  (`tests/verify_t86_cross_process_save.gd` + `tests/save_group_worker.gd`) kills a real Godot
  OS process mid-save and recovers from fresh processes.
- T-221 native identity and physical mount provenance: a missing stage is `STAGE_MISSING_UNVERIFIED`
  unless the durable record proves a full, non-partial cleanup bound to the same session, stage ID
  and stage root; an empty intent stage root is `INVALID_STAGE_IDENTITY`. Finalization refuses a
  durable record whose stage root differs from the in-memory session and refuses records missing
  required session/stage identities. Hardpoint Inspector shots bind to the physical weapon slot and
  firing mode (PRIMARY/ALTERNATE) as well as weapon identity; the Shot ID and historical launch
  origin share one row predicate, so a wrong hardpoint hides both. Double-clicking a shot row
  selects its event in the Combat State Timeline. The earlier `ObjectDB` leak warning was traced
  to Node3D fixtures in the test harness and fixed there; no product resource leak was observed.
- T-222 durable identity and backup provenance: the shared cleanup-identity authority compares
  durable `stage_id` by value with the in-memory session and refuses conflicting top-level/nested
  identities; a backup-only stage is reported as `BACKUPS_PRESERVED` with `backup_files` in startup
  discovery and `OWNED_FILES_REMOVED_BACKUPS_PRESERVED` / `CLEANUP_PARTIAL_BACKUPS_PRESERVED` from
  cleanup. Backup bytes and ownership metadata stay intact; empty backup directories do not create
  a false partial state. The 3D Hardpoint Inspector draws one selectable marker per resolved model
  hardpoint, links marker clicks to the picker and inspector row, and keeps shot identity tied to
  the physical mount and PRIMARY/ALTERNATE context.
- `SRC-036` closure remains `BLOCKED_FRAMEWORK`: the stored contract and live CLI both expose one
  actionable clause (`SRC-036:R001`, disposition `UNKNOWN`), while the T-221 closure event recorded
  `requirements=0/actionable=0`; `saipen ship` was additionally refused by an ambiguous release
  continuation with the existing `v0.0.1` tag. No source disposition, release tag or installed SAIPEN
  code was changed from this project; an owning-framework decision is required.
  The live CLI now supports authenticated suite receipt references (`suite:<record-id>`):
  `SRC-036:R001`, `SRC-037:R001` and `SRC-038:R001` were verified from the canonical
  T-221..T-223 suite record, without editing coverage files. Their tickets were unblocked
  into TODO for normal lifecycle re-entry; historical implementation evidence is preserved.
- T-223 reserved stage namespace: ordinary staging refuses backup, manifest, recovery-marker,
  native-evidence, provenance and cleanup-receipt paths (case-insensitive on Windows); a verified
  empty backup directory is removed before CLEAN, while any retained backup is reported as a
  partial outcome with byte-exact backups and a bound receipt. Finalization refuses a backup-only
  stage without a compatible receipt. Viewport markers derive ownership from physical weapon-slot
  declarations; marker clicks switch the weapon picker and profile, and SINGLE fire uses the
  selected mount while TANDEM/SALVO policies are unchanged.
- T-224 physical file identity: `.shaman_stage_backups` is reserved as a path component at every depth; protected backup files remain inventoried and are never ordinary staged payloads. Windows staging compares case-folded relative identities for unknown files, manifest ownership, incoming duplicates and hash guards while preserving the caller's display spelling. Existing manifests containing case-aliased rows are rejected. Ordinary restaging cannot replace an existing `stage_id` (`STAGE_IDENTITY_MISMATCH`). Shared hardpoints keep all owning slots and require an explicit owner selection; marker ordnance is resolved from that owner's Weapon ODF, never borrowed from the active profile. Non-weapon model hardpoints are `INSPECTION_ONLY`, and SINGLE selection is revalidated against slot, hardpoint and source revision before every shot. Replay refuses contradictory recorded physical slot identity instead of silently reporting success.
- AUDAPACK producer access is `BLOCKED_EXTERNAL: AUDAPACK_PRODUCER_AUTH` (bridge `/v1/status` returned
  HTTP 403). The audit ZIP is not regenerated and no COMPLETE status is claimed.

## Build

- A Windows x86_64 release with embedded PCK builds and boots with Godot 4.7.2 templates
  (`tools/build_windows.cmd`, including self-contained `editor_data/export_templates`).
- The package is unsigned, has no installer, and has been verified both headless and in an
  automated windowed GPU run (`exe_weapons_lab.png`, `exe_particle_lab.png`, `gui_verify_report.txt`).
- Performance is measured by `tools/run_bench.cmd`, but no budget thresholds or CI regression
  gate exist; numbers are for comparison only.
