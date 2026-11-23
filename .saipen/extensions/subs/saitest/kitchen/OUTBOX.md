# OUTBOX

## W-003: native blocker reproduction verified
- **status:** stale
- **summary:** saihunt no-findings result independently reproduced by current suite and build.
- **main_project_refs:** [tests/native_experiment_probe.gd, tools/run_native_experiment.cmd, docs/NATIVE_TESTING.md]
- **critical:** false
- **producer:** saitest
- **source_head:** 3ef3e6db81d66a7ccb164e4b99d35ff60412011b
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** repo suite, Windows build, native evidence artifact
- **payload:** []
- **verified:** PASS -- saipen test suite run T-43 PASS; tools/build_windows.cmd exit 0
- **instructions:** no integration required
- **details:**
  Scenario verdict NOT_REPRODUCED for new project defect; documented BZCC console-font blocker remains an external engine limitation already evidenced.

## W-004: native blocker reproduction verified
- **status:** stale
- **summary:** saihunt no-findings result independently reproduced by current suite and build.
- **main_project_refs:** [tests/native_experiment_probe.gd, tools/run_native_experiment.cmd, docs/NATIVE_TESTING.md]
- **critical:** false
- **producer:** saitest
- **source_head:** 727e38a0f2a7536a7f5d0075b252df930d26610d
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** repo suite, Windows build, native evidence artifact
- **payload:** []
- **verified:** PASS -- saipen test suite run T-43 PASS; tools/build_windows.cmd exit 0
- **instructions:** no integration required
- **details:**
  Scenario verdict NOT_REPRODUCED for new project defect; documented BZCC console-font blocker remains an external engine limitation already evidenced.

## W-005: native blocker reproduction verified
- **status:** stale
- **summary:** saihunt no-findings result independently reproduced by current suite and build.
- **main_project_refs:** [tests/native_experiment_probe.gd, tools/run_native_experiment.cmd, docs/NATIVE_TESTING.md]
- **critical:** false
- **producer:** saitest
- **source_head:** 8c261a93f38b1d7d919daf42cdcacab3cde34262
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** repo suite, Windows build, native evidence artifact
- **payload:** []
- **verified:** PASS -- saipen test suite run T-43 PASS; tools/build_windows.cmd exit 0
- **instructions:** no integration required
- **details:**
  Scenario verdict NOT_REPRODUCED for new project defect; documented BZCC console-font blocker remains an external engine limitation already evidenced.

## W-006: native blocker reproduction verified
- **status:** stale
- **summary:** saihunt no-findings result independently reproduced by current suite and build.
- **main_project_refs:** [tests/native_experiment_probe.gd, tools/run_native_experiment.cmd, docs/NATIVE_TESTING.md]
- **critical:** false
- **producer:** saitest
- **source_head:** fc8e78f5eef5807d4c5f52713cf09d1190ac1001
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** repo suite, Windows build, native evidence artifact
- **payload:** []
- **verified:** PASS -- saipen test suite run T-43 PASS; tools/build_windows.cmd exit 0
- **instructions:** no integration required
- **details:**
  Scenario verdict NOT_REPRODUCED for new project defect; documented BZCC console-font blocker remains an external engine limitation already evidenced.

## W-007: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** stale
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-008: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** reviewed
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-009: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** reviewed
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-010: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** reviewed
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-011: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** stale
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-012: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** reviewed
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-013: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** reviewed
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-014: adversarial probes of T-86 save-group recovery — 2 reproduced
- **status:** reviewed
- **summary:** Malformed/empty journal false-RECOVERED reproduced then fixed by Core T-88; regression probes now pass.
- **main_project_refs:** [scripts/lab/particle_lab.gd]
- **critical:** true
- **severity:** P1
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "boundary / input abuse" against recover_partial_save_group and discover_incomplete_save_groups; three minimal GDScript probes under this role's kitchen, executed headless.
- **payload:** []
- **verified:** PASS -- core T-88 fix applied; re-run of probes now returns: malformed status=RECOVERY_PENDING durable_state=PARTIAL_SAVE_RECOVERABLE, empty status=RECOVERY_PENDING still_discoverable=1, control COMPLETE guard RECOVERY_NOT_APPLICABLE twice. Original RED evidence: (1) kitchen/probe_malformed_journal.gd with targets [string,int,null] returned status=RECOVERED ok=true durable_state=RECOVERED; (2) kitchen/probe_empty_group.gd with targets [] returned status=RECOVERED restored=0 and group vanished from discovery; control kitchen/probe_repeat.gd returned RECOVERY_NOT_APPLICABLE twice for COMPLETE group (guard holds).
- **instructions:** Integrate as a new Core ticket: recover_partial_save_group must reject journals with empty/invalid targets before declaring RECOVERED; return RECOVERY_PENDING / INVALID_JOURNAL_TARGETS with no durable false-complete write. No fix applied by saitest.
- **details:**
  Both reproduced probes write a schema-1 journal with state PARTIAL_SAVE_RECOVERABLE, then call the recovery entrypoint. The function skips every non-Dictionary target and reaches its final `group["state"] = "RECOVERED"` branch with restored=[], failed=[], conflicts=[]; _write_save_journal persists that verdict. A crash recovery UI would show a successful recovery even though nothing was restored and the original transaction is now hidden from discovery. This is distinct from T-86's completed-save guard (which holds). The repeated-recovery scenario confirms the COMPLETE guard is sound. Probes are read-only toward main project source; they live only inside this role's kitchen.

## W-015: adversarial re-check of current tree — no new reproduction
- **status:** stale
- **summary:** No new defect reproduced; saihunt's clean result independently re-checked on the current tree.
- **main_project_refs:** [scripts/lab/particle_lab.gd, scripts/core/workspace_store.gd, scripts/native/native_session_service.gd, tools/run_tests.cmd, tools/build_windows.cmd]
- **critical:** false
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** scenario family "order and repetition / damaged state" — rerun the previously reproduced malformed/empty journal recovery probes against the current tree plus canonical suite and Windows build; scenario family "boundary" — empty/degenerate path guard re-check in save/recovery and native session cleanup; read-only execution only, no project tree mutation.
- **payload:** []
- **verified:** PASS -- tools\run_tests.cmd exit 0 (core 1106/1106, T-122 28/28, T-123 31/31, UI 0 failures, ALL TESTS PASSED); tools\build_windows.cmd exit 0 with Windows executable produced; prior RED conditions stay closed by T-88/T-121/T-122/T-123 regression coverage; saipen outbox check saitest returned OUTBOX_VALID.
- **instructions:** no integration required; payload [] is intentional. Sensor stage satisfied for this crew epoch.
- **details:** Scenario verdict NOT_REPRODUCED for a new project defect. The malformed/empty journal false-RECOVERED condition (historically REPRODUCED in W-007..W-014, fixed under T-88) stays closed on the current tree: canonical suite carries its regression coverage and passes. No new input-abuse, boundary, repetition, environment, resource, damaged-state or adversarial-content scenario reproduced a defect not already tracked. Native/AUDAPACK and BZCC limitations remain external and tracked under T-75. No fix attempted by saitest.

## W-016: independent T-128 suite reproduction — no new finding
- **status:** reviewed
- **summary:** Independently reproduced the current declared T-128 suite and canonical suite; no new project defect.
- **main_project_refs:** [tests/verify_t128_cleanup_contract.gd, tools/run_tests.cmd, docs/TESTING.md]
- **critical:** false
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:e04b8a9e3023b230e5fe7f44c132674f41a3915896701ee608912583250e9d22
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** declared T-128 suite command 43764bfc12053f9a, canonical tools/run_tests.cmd, Windows build evidence in T-128 E-1644/E-1654.
- **payload:** []
- **verified:** PASS -- suite record 43764bfc12053f9a-20261123T195459624881Z.json T-128 44/44 0 failures; canonical suite PASS per E-1637/E-1654; saipen outbox check saitest OUTBOX_VALID.
- **instructions:** no integration required; payload [] is intentional. Sensor stage satisfied for this crew epoch.
- **details:** Scenario verdict NOT_REPRODUCED for a new project defect. T-128 cleanup-contract safety gaps were fixed and verified under T-128; the documented native BZCC blocker remains external and is tracked under T-75.

## W-017: independent suite reproduction — no finding for 0.0.1 release tree
- **status:** reviewed
- **summary:** Independently reproduced fresh T-128 suite 44/44 and canonical suite PASS; no new defect.
- **main_project_refs:** [README.md, scripts/, tools/, tests/, docs/]
- **critical:** false
- **producer:** saitest
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:594f1818a66f6cc17f8273e563d32d40aafcae5f5c0baeac31982b7b352308a1
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** bounded current-source review of owned surface for release 0.0.1.
- **payload:** []
- **verified:** PASS -- suite record 43764bfc12053f9a-20261123T202558094960Z.json PASS
- **instructions:** no integration required; payload [] intentional. Sensor stage satisfied for this crew epoch.
- **details:** No new actionable finding; package bound to the current 0.0.1 release source identity.

## W-018: independent suite reproduction — published 0.0.1 tree
- **status:** reviewed
- **summary:** Fresh T-128 suite 44/44 and canonical suite PASS reproduced; no new defect.
- **main_project_refs:** [README.md, scripts/, tools/, tests/, docs/]
- **critical:** false
- **producer:** saitest
- **source_head:** a37a6e46dc50f6cbafb0a1fc817f1185a5ce30bc
- **source_tree_fingerprint:** git-delta-v1:c66baf69a8306f3b95dfc7badb5f72b088f8de8408e933efadc4d149721a1195
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** bounded current-source review of owned surface for published release 0.0.1.
- **payload:** []
- **verified:** PASS -- suite record PASS; saipen validate CURRENT_PASS
- **instructions:** no integration required; payload [] intentional. Sensor stage satisfied for this crew epoch.
- **details:** No new actionable finding; package bound to the published 0.0.1 source identity.

## W-019: current-source sensor review — no finding
- **status:** reviewed
- **summary:** Sensor review clean against published release 0.0.1 tree.
- **main_project_refs:** [README.md, scripts/, tools/, tests/, docs/]
- **critical:** false
- **producer:** saitest
- **source_head:** 714cb81cbcb7622afeb0b6939e5d93f9ea7a68df
- **source_tree_fingerprint:** git-delta-v1:c66baf69a8306f3b95dfc7badb5f72b088f8de8408e933efadc4d149721a1195
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** bounded review of owned surface against current source identity.
- **payload:** []
- **verified:** PASS -- canonical suite PASS; saipen validate CURRENT_PASS.
- **instructions:** no integration required; payload [] intentional.
- **details:** No new actionable finding on the current tree.

## W-020: shipped-release sensor review
- **status:** reviewed
- **summary:** Sensor review clean against shipped v0.0.1 tree.
- **main_project_refs:** [README.md, scripts/, tools/, tests/, docs/]
- **critical:** false
- **producer:** saitest
- **source_head:** f0a75f8d38e681ec2e0a1e54961c916706ee0416
- **source_tree_fingerprint:** git-delta-v1:c66baf69a8306f3b95dfc7badb5f72b088f8de8408e933efadc4d149721a1195
- **role_revision:** sha256:801fbfdc4be680d87b18cd21e6246d83fad5b474ebd7fe82efa83918cecf2f08
- **coverage:** owned surface reviewed against shipped release tree.
- **payload:** []
- **verified:** PASS -- canonical suite PASS; saipen validate CURRENT_PASS.
- **instructions:** no integration required; payload [] intentional.
- **details:** No new actionable finding on the shipped tree.
