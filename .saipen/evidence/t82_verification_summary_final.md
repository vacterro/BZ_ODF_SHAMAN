# T-82 final verification summary (handoff-18 findings)

## Request coverage
SRC-023 / T-82: GraphEdit slot/output port identity, external edges, native cleanup
safety, fresh Windows release, T-75/product continuation. The handoff-18 findings
addressed integration-level regressions inside the same external-edge and native
cleanup-safety scope; no duplicate ticket was created for them.

## Defects found and repaired with RED/GREEN controls
- External `file.header` was collapsed to a bare local header during Move/Swap/
  Replace and Reconnect when a local header had the same name. Fixed by carrying
  the exact reference value in `_reference_identity` through Move and by emitting
  the exact `file.header` token from `_reference_value_for_target` / resolved target.
  Occupied external port focus now keeps the external header identity.
- Native GUI inventory used `inspect_stage().cleanup_allowed`, a weaker check than
  `reconcile_stage()`. It now calls `reconcile_stage()` as the authoritative verdict
  and keeps manifest inspection only as `inspection_candidate`.
- `_active_monitor_for_session()` treated a nonterminal or unknown monitor state with
  `active=false` as TERMINAL. Validation now checks terminal state, `active`,
  `recoverable`, recovery and cancel flags independently.

RED controls: `.saipen/evidence/t82_xref_red.log` (8 failures),
`.saipen/evidence/t82_native_gui_red.log` (8 failures).
GREEN: `.saipen/evidence/t82_xref_green.log` (16/16; extended 17/17 after REVIEW finding in `t82_xref_swap_red/green.log`),
`.saipen/evidence/t82_native_gui_green.log` (57/57).
Native oracle unchanged between red/green; cross-file oracle checks unchanged, only
temporary debug prints were removed after the red run.

## Final gate results
- Canonical suite: PASS 1105/1105/0, current record
  `.saipen/evidence/suite/ec60a408a0ad774d-20261122T234149175476Z.json`.
- Focused: cross-file 17/17, ports headless 35/35, ports windowed 7/7,
  native safety 57/57, replay 23/23, visual/index 27/27, weapons/hotkeys 36/36,
  identity 16/16.
- UI smoke: 0 failures.
- Windows release: fresh export, sha256
  `9463307d5d5e91b66e69764355e9bb47736473a2e86ffda39de0ca507c273530`.
- GPU GUI: exit 0, `theme=goldendefault`, viewport 1920x1061, 17028 ODFs,
  `spawned_effects=6`, `titan_bolt_rendered=true`, `preflight_status=BLOCKED`;
  evidence in `.saipen/evidence/t82/gui_verify_postreview/`.
- Benchmark: PASS, soak_10m PASS, memory delta after reset 2.73 MB.
- BZ2R integrity unchanged: battlezone2.exe md5 e2fa7458cf2604315f48915acd288689,
  bzone.cfg sha256 7a79d5bca9535ddea71cd492265adda7b2932177f769c3d4615c7407c2ba90de,
  zero SHAMAN files in BZ2R.
- `saipen validate`: VALID / CURRENT_PASS.

## Source hashes
- particle_lab.gd sha256 898c2f132aac0201c1c63dcbc5509c0a6cc0b5523e17695810dbaa9c827b93a9
- weapon_lab.gd sha256 41458bddfa71b70261737d1112f91266d8905d73c0fb95dc54c9db5d28a2e0bb
- safe_stage_manager.gd sha256 c3f22cd2ffaa629e8f3d8e66913cce0cd3fff46caaab0a1fc86cb77d8f228057
- verify_t82_cross_file.gd sha256 217af855c8949eeeb2bb8a64be372dc5553e22cd71b82c6bc5c8147d49563a20
- verify_t73_native_safety.gd sha256 c488d931645bb283c2339f23f56499201ebb689fbe8732ec1f5e1429eb250de8

## Scope notes
Temporary diagnostic scripts listed in the handoff were inspected; none were
referenced by harnesses or docs and were removed from the release tree. Docs synced.
NATIVE_VERIFIED remains 0. AUDAPACK remains BLOCKED_EXTERNAL /
AUDAPACK_PRODUCER_AUTH; no archive or authorization was fabricated. T-75 live Steam
and publication remain pending.
