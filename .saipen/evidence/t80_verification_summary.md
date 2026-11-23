# T-80 Verification Summary

Date: 2026-11-22. Engine: Godot 4.7.2-stable. New tickets: T-80. T-75 remains open.

## Product fixes (verified in current worktree)

- Particle Graph: one output port per physical `emitName`/`renderNameN` reference slot;
  mouse disconnect uses focused physical entry or exact port, keyboard disconnect shares
  the same identity-aware path, ambiguous parallel edges are refused as
  `AMBIGUOUS_GRAPH_CONNECTION`, and failed Move restores byte-exact ODF text, encoding,
  dirty flag and undo history via `OdfDocument.capture_snapshot()` / `restore_snapshot()`.
- Weapons: one resolved record per declared `weaponHardN`; missing hardpoints keep their
  declared position and are labelled `DECLARED_HARDPOINT_NOT_FOUND` with explicit fallback;
  SALVO records the selected barrel's real hardpoint/index in `ShotIdentity`; aggregate
  `VolleyResult` produces `FIRED` / `PARTIAL_SUCCESS` / `REJECTED` consistently and keeps
  per-barrel rejection reasons and resource costs.
- Replay: GUI job state derives from the result's own `complete`/`ok`/`reason`; a step-limit
  stop is `FAILED`, incomplete A/B is `FAILED`, one-sided completion is `PARTIAL_RESULT`,
  and mixed success is never reported as `COMPLETE`.
- T-75: read-only Native Stage Inventory button in the Native tab reports stage name,
  session id/state, ownership, hash status, unknown files and cleanup eligibility. It never
  deletes, renames or overwrites a stage.
- Documentation: `KNOWN_LIMITATIONS.md` corrected for persistent ResourceIndex cache,
  ODF/INI content fingerprint, payload verification, DOCB animation status, SALVO/TANDEM
  approximation, stage conflicts, AUDAPACK blocker and replay fidelity.

## Gates

- Canonical suite: PASS, 1105 ran / 1105 passed / 0 red; records
  `ec60a408a0ad774d-20261122T202724940760Z.json` and independent re-run
  `ec60a408a0ad774d-20261122T202902288765Z.json`; both `current=true`.
- Focused verifiers: T-72 23/23, T-73 35/35, T-74 27/27, T-76 35/35, new T-80 16/16.
- UI smoke: 0 failures.
- Windows build: PASS, `BZ_ODF_SHAMAN.exe` 112,299,184 bytes,
  sha256 `79e2aec439e6c58c1f1f2d26ec51463550c8aefa2e1fb7a8b2c966f9c2a5fb18`
  (rebuilt after REVIEW finding; previous 112,299,152-byte build superseded).
- Benchmark: PASS; index 17,028 ODFs / 37,161 asset names in 1059.2 ms;
  `soak_10m` PASS, memory delta after reset 2.73 MB.
- GPU GUI self-verify: PASS, exit 0, `theme=goldendefault`, viewport 1920x1061,
  `font_aa=none`, authentic meshes rendered, `titan_bolt_rendered=true`,
  `spawned_effects=6`, `timeline_events=26`; screenshots and report in
  `.saipen/evidence/t80/gui_verify/`.
- Native preflight during GPU run: `BLOCKED` / `OLD_SHAMAN_STAGE_COLLISION`.
  `NATIVE_VERIFIED` stays 0. No live game launch, no synthetic evidence.
- BZ2R integrity unchanged: `battlezone2.exe` md5 `e2fa7458cf2604315f48915acd288689`,
  `bzone.cfg` sha256 `7a79d5bca9535ddea71cd492265adda7b2932177f769c3d4615c7407c2ba90de`;
  zero SHAMAN files inside BZ2R.
- AUDAPACK: `BLOCKED_EXTERNAL: AUDAPACK_PRODUCER_AUTH`. No authorized producer route;
  127.0.0.1:8787 gave no response, 8080 `/v1/status` 404. No archive regenerated,
  no completeness claimed.
- REVIEW self-audit: found and fixed contradictory per-barrel `state` strings (a directly
  observable `RELOADING` on an accepted shot). Re-ran all gates on the changed bytes.
  No P0/P1 finding remains in scope.

## Honest classification

- Product fixes: `IMPLEMENTED_UNVERIFIED_GUI_INPUT` for mouse gestures (behavioral verifier
  covers handler and exact physical entry; no OS-level mouse driver automation).
- Core/focused suites, build, bench, GPU self-verify: `VERIFIED` on this machine.
- Native gameplay: `NOT_VERIFIED` / `NATIVE_VERIFIED: 0`.
- AUDAPACK: `BLOCKED_EXTERNAL`.
- Git publication: not performed; no authorization.
