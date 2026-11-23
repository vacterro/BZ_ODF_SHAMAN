# T-85 verification summary — SAIHANDOFF-19

## Requested change (SRC-026)
Durable multi-file save recovery, safe native cleanup, honest graph events,
T-75 progress and continued visual laboratory work.

## Verified changes
- `SAVE DEPENDENCIES` now writes a verified write-ahead journal before any ODF
  mutation, records every committed document, and persists honest final states
  (`PREPARED`, `COMMITTING`, `COMPLETE`, `PARTIAL_SAVE_RECOVERABLE`,
  `RECOVERY_PENDING`, `RECOVERED`, `RECOVERY_CONFLICT`, `UNRECOVERABLE` via
  fault paths). `discover_incomplete_save_groups()` finds interrupted groups
  after restart. Recovery restores the previous override byte-for-byte and
  writes a separate working artifact preserving unsaved edits, encoding, BOM,
  comments and whitespace. External modifications produce `RECOVERY_CONFLICT`.
  Evidence: `t85_save_red.log` (pre-fix state-dishonesty failure + missing
  restart API), `t85_save_green.log` (11/11).
- Runtime `NativeExperimentRunner.cleanup_stage()` now applies the authoritative
  `SafeStageManager.reconcile_stage()` verdict before deletion, blocks
  `RECOVERY_PENDING`, `FAILED`, `PARTIAL_CLEANUP`, active/recoverable/nonterminal
  monitors, and writes a read-back verified `CLEANUP_PREPARED` intent before any
  file removal. Failed final commits are recorded `CLEANUP_RECOVERY_PENDING`.
  Unknown files are reported but preserved by the existing cleanup routine;
  modified manifest-owned files block cleanup. Evidence:
  `t85_native_red.log` → `t85_native_green.log` (62/62), core cleanup cases updated.
- Graph Disconnect/Cut/Paste emit `document_edited` only for real ODF mutations.
  `last_graph_batch` reports requested/succeeded/failed/failure_reasons and
  `NO_CHANGE`/`PARTIAL`/`COMPLETE` status. Evidence:
  `t85_graph_red.log` (3 failures) → `t85_graph_green.log` (6/6).
- Docs synced in `docs/PARTICLE_GRAPH.md` and `docs/KNOWN_LIMITATIONS.md`.
  Temporary `tests/tmp*` diagnostic scripts were removed earlier and remain absent.

## Gate results
- Canonical suite: PASS 1105/1105/0, current record
  `.saipen/evidence/suite/ec60a408a0ad774d-20261123T010228707148Z.json`.
- Focused: save 11/11, graph events 6/6, native safety 62/62, ports 35/35,
  cross-file 17/17, replay 23/23, visual 27/27, weapons 36/36, identity 16/16.
- Core direct run: 1106 checks / 0 failures; UI smoke: 0 failures.
- Windows release: fresh export, sha256
  `e495c97b2b515ebe4c8aa21be5796d97dbd81930f75a9432b6772615ab395a17`.
- GPU GUI: exit 0, theme goldendefault, viewport 1920x1061, 17028 ODFs,
  `spawned_effects=6`, `titan_bolt_rendered=true`, preflight BLOCKED (no native
  launch), screenshots in `.saipen/evidence/t85/gui_verify_postreview/`.
- Benchmark: PASS, 10-minute soak PASS, memory delta 2.73 MB.
- `saipen validate`: VALID / CURRENT_PASS.
- BZ2R integrity unchanged; zero SHAMAN files in BZ2R.

## Scope notes
T-75 remains TODO. Real BZCC launch remains BLOCKED_EXTERNAL
(`STEAM_USER_NOT_LOGGED_IN`, `OLD_SHAMAN_STAGE_COLLISION`); no fake native
evidence; `NATIVE_VERIFIED = 0`. AUDAPACK remains `BLOCKED_EXTERNAL:
AUDAPACK_PRODUCER_AUTH` and no archive/completeness claim was fabricated.
Publication pending; Git worktree remains dirty and no push was performed.
