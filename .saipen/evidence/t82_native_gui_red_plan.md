# T-82 native GUI/monitor RED control plan

## Defects to prove (from SAIHANDOFF-18)
- P0-NATIVE-01: WeaponLab.inspect_native_stages uses inspect_stage.cleanup_allowed
  instead of authoritative reconcile_stage; GUI can display `cleanup=allowed` for
  corrupt/absent ledger or active monitor.
- P1-NATIVE-02: _active_monitor_for_session treats nonterminal monitor state with
  active=false as TERMINAL; recovery/cancel flags not checked independently.

## Oracle
Extend tests/verify_t73_native_safety.gd with NSTAGE-17..27, using the same
stage manifest/ledger/monitor fixture already used by NSTAGE-01..16.
RED run before implementation: .saipen/evidence/t82_native_gui_red.log
GREEN run after: .saipen/evidence/t82_native_gui_green.log
