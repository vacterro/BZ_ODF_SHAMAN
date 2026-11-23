# T-81 result

Status: VERIFIED (product), BLOCKED_EXTERNAL (native gameplay, AUDAPACK producer).

## Graph ports

- `scripts/lab/particle_lab.gd`: each `GraphNode` now has one direct child `Control` per slot.
  Slot 0 is input-only; each physical reference (`emitName`, `renderName1..N`) owns exactly one
  output port; a separate `+ ADD` output port creates the next free key.
- Edges attach to the exact source port. Occupied-port drag selects the existing physical key and
  refuses with `PORT_OCCUPIED` instead of creating another property. Exact-key highlight mirrors
  `GraphEdit.set_connection_activity`. Unresolved disconnect rebuilds the visual graph from the
  ODF rather than hiding a live reference.
- Headless verifier `tests/verify_t81_graph_ports.gd`: 21 checks, 0 failures.
- Windowed verifier `tests/verify_t81_windowed_ports.gd`: 4 checks, 0 failures; actual
  `GraphNode` state `output=5 input=1 children=6` for three references plus `emitName` and add port.

## Native stage reconciliation

- `SafeStageManager.reconcile_stage()` reads the durable session ledger on top of the read-only
  inventory. It returns `PROTECT` for unresolved ownership, hash mismatch, and active/recoverable
  sessions; `CLEANUP_ELIGIBLE` only for a manifest-owned terminal stage with matching hashes.
- It never deletes; any removal still needs an explicit authorized cleanup call.
- T-73 verifier: 40 checks, 0 failures (5 new NSTAGE checks).

## Gates

- Canonical suite: PASS 1105/1105, records
  `.saipen/evidence/suite/ec60a408a0ad774d-20261122T214907259883Z.json` and
  `...215216482471Z.json` (review rerun).
- Focused: T-72 23/23, T-73 40/40, T-74 27/27, T-76 36/36, T-80 16/16, T-81 21/21 + 4/4.
- UI smoke: 0 failures.
- Windows build: `build/BZ_ODF_SHAMAN.exe`, 112299184 bytes,
  SHA256 `79e2aec439e6c58c1f1f2d26ec51463550c8aefa2e1fb7a8b2c966f9c2a5fb18`.
- Packaged GUI self-verify: PASS; screenshots and report in this directory.
- SAIPEN: `saipen validate` CURRENT_PASS; T-81 finished via `ticket done --closure-mode own_patch`.
  Publication not authorized; T-75 remains the top workable ticket.

## Known limitations

- OS-level mouse-drag automation remains outside automated tests. Windowed verification uses real
  Godot `GraphEdit`/`GraphNode` controls and handler-level interactions.
- `NATIVE_VERIFIED = 0`; no live BZCC gameplay observation.
- AUDAPACK producer remains `BLOCKED_EXTERNAL: AUDAPACK_PRODUCER_AUTH`.
