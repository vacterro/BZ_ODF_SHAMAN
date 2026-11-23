# T-78 / T-75 Release Check

- suite: canonical SAIPEN suite record `ec60a408a0ad774d-20261122T172114287252Z.json`, verdict PASS, 1105 checks / 0 red / 0 skipped (record current=true).
- focused: T-76 23/23, T-72 21/21, T-73 32/32, T-74 26/26; UI smoke 0 failures (`t78_ui_run5.log`).
- Windows build: `BZ_ODF_SHAMAN.exe` 112,285,920 bytes, sha256 d110c9150f5aea8045cf7c2cc691051ef5f6a98d9bc079c559919d7c676e2c6a.
- Benchmark: PASS measurement only; index 1691 ms, sim 13475.7 ms, memory 152.0 MB; soak_1m/10m PASS.
- BZ2R integrity: battlezone2.exe md5 e2fa7458cf26 (matches T-77 record); bzone.cfg sha256 7a79d5bca9535dde... (unchanged).
- Native: not executed; no authorized Steam session claim; NATIVE_VERIFIED=0, BLOCKED_EXTERNAL.
- AUDAPACK: config always_include extended with 13 real artifacts (backup config.json.bak-t78). Producer not run; no COMPLETE claim fabricated.
- saipen validate: VALID, CURRENT_PASS, 10 warnings (soft caps/stale producer packages only).
- GPU GUI: fresh self-verify at 1920x1061 on RTX 3060, theme goldendefault, 17028 ODFs, titan bolt rendered, screenshots + report in `.saipen/evidence/t78/gui_verify/`; native preflight BLOCKED_EXTERNAL: OLD_SHAMAN_STAGE_COLLISION (no native claim).
- Git publication: not pushed; publication remains operator decision.
