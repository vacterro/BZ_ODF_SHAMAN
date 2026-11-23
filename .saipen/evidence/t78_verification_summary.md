# T-78 Verification Summary (2026-11-22)

## Product fixes
- Particle Graph: central link validator; atomic in-place reconnect with byte-identical failure; self-link/indirect-cycle rejection; free/swap/replace move modes; revision-aware edge focus with GUI click selection and highlight; text-editor focus guard for Ctrl+C/X/V.
- Weapons: ShotIdentity frozen at launch (paths/revisions/hardpoint/barrel/volley/FX/damage); weapon switching keeps in-flight visuals; impact FX/sound resolve from shot provenance; explicit compact slot index mapping; VolleyResult with accepted/rejected barrels, shot IDs, spend totals, partial_failure; SALVO starts at barrel 0.
- Replay: primary GUI Replay and A/B use bounded incremental runners; cancel/pause; honest REPLAY_STEP_LIMIT_EXCEEDED with ok=false and diagnostics; test option max_steps_total.
- ResourceIndex: CACHE_SCHEMA 2 with canonical payload SHA256, type/count validation, workspace isolation preserved, safe rescan fallback.
- AUDAPACK config: 13 required real evidence artifacts added to always_include (backup: config.json.bak-t78); producer status not fabricated.

## Evidence (absolute paths)
- Baseline: V:/___VAC/__K/__CODE/_MISC/_BZ_ODF_SHAMAN/.saipen/evidence/t78_baseline_tests.log
- Suite after fixes: .../t78_suite_run1.log
- Focused verifiers: T-76 23/23, T-72 21/21, T-73 32/32, T-74 26/26 (run directly with Godot 4.7.2)
- UI smoke: .../t78_ui_run5.log (0 failures)
- Bench: .../t78_bench.log (PASS; index 1691ms, sim 13475ms, memory 152.0MB)
- Windows build: .../t78_windows_build.log (112,285,920 B; SHA256 d110c9150f5aea8045cf7c2cc691051ef5f6a98d9bc079c559919d7c676e2c6a)
- Godot import check: .../t78_godot_import.log (0 errors)

## Honest limitations
- T-26 baseline native-launch assertion depended on real Steam eligibility; UI smoke now uses isolated Steam mock. No synthetic NATIVE_VERIFIED.
- AUDAPACK producer was not run; config inclusion fix only. Audit snapshot status remains whatever the real producer reports.
