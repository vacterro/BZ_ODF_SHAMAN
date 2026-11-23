# T-82 verification summary

## Own description of requested change
Mode 2 night shift: fix GraphEdit slot/output port identity, external edges,
native cleanup safety, verify fresh Windows release, continue T-75 and product work.

## Change present and demonstrated
- GraphNode direct-child slot controls bind each physical ODF reference to a real
  GraphEdit output port; the +ADD sentinel owns its own port and never reuses an
  occupied slot. Port-first identity resolves local and external `file.header`
  edges to the exact reference entry; external identity carries canonical path,
  package and header. Evidence: `.saipen/evidence/t82_now_ports.log`
  (35/35), `.saipen/evidence/t82_now_windowed.log` (7/7, output=5 input=1),
  `.saipen/evidence/t82_now_ui.log` (287 checks, 0 failures).
- `SafeStageManager.reconcile_stage` remains read-only and refuses cleanup unless
  manifest ownership, hashes, terminal ledger state, evidence agreement and
  monitor state all agree. Corrupt/missing/disagreeing ledger yields PROTECT with
  RECOVERY_PENDING. Evidence: `.saipen/evidence/t82_now_native.log` (46/46),
  including NSTAGE-02, NSTAGE-09 and the corrupt-ledger control previously red
  in `.saipen/evidence/t82_native_red.log`.
- RED control for native cleanup: pre-fix log shows NSTAGE-02 and NSTAGE-05
  failures while current verifier passes those cases; records preserved as
  `.saipen/evidence/t82_native_red.log` and `.saipen/evidence/t82_now_native.log`.

## Release gates
- Canonical suite: PASS, 1105 ran / 1105 passed / 0 red, current record
  `.saipen/evidence/suite/ec60a408a0ad774d-20261122T230856492062Z.json`.
- Windows release: fresh export after final sources, `BZ_ODF_SHAMAN.exe` and
  `build/BZ_ODF_SHAMAN.exe` 112312192 bytes, sha256
  `cece2b7f8267307cd6c0cde3975e1c2d5f279f47059bc4afbcd8f21fa2689642`.
- GPU GUI self-verify on fresh exe: exit 0, theme goldendefault, viewport
  1920x1061, index 17028 ODFs, spawned_effects=6, titan_bolt_rendered=true,
  preflight BLOCKED (no native launch), font_aa=none, timeline_events=26,
  screenshots + report in `.saipen/evidence/t82/gui_verify/`.
- Benchmark: PASS (measurement only), index 1100.5 ms, soak_10m PASS,
  memory delta after reset 2.73 MB, `.saipen/evidence/t82_bench.log`.
- BZ2R integrity unchanged: battlezone2.exe md5 e2fa7458cf2604315f48915acd288689,
  bzone.cfg sha256 7a79d5bca9535ddea71cd492265adda7b2932177f769c3d4615c7407c2ba90de,
  zero SHAMAN files in BZ2R.
- Validation: `saipen validate` CURRENT_PASS, gate core.

## Scope notes
- No code change was required this BUILD phase: port identity and ledger safety
  were already present in the live worktree. Work performed is RED/GREEN control,
  fresh release, full gate proof and evidence.
- Native live Steam launch remains externally blocked; no synthetic
  NATIVE_VERIFIED claim. AUDAPACK producer remains unauthorized; no archive
  regenerated. T-75 native/AUDAPACK publication stays pending.
