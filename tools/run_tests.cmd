@echo off
setlocal
set "ROOT=%~dp0.."
set "GODOT=V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
echo == Core tests ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/test_runner.gd
if errorlevel 1 goto :fail
echo.
echo == Weapon chain integrity ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_weapon_chain_integrity.gd
if errorlevel 1 goto :fail
echo.
echo == Alternate physical slot provenance ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_alternate_physical_slot.gd
if errorlevel 1 goto :fail
echo.
echo == T-122 coherence ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t122_recovery_coherence.gd
if errorlevel 1 goto :fail
echo.
echo == T-123 lifecycle contract ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t123_lifecycle_contract.gd
if errorlevel 1 goto :fail
echo.
echo == T-128 cleanup contract ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t128_cleanup_contract.gd
if errorlevel 1 goto :fail
echo.
echo == T-214 receipt trust ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t214_receipt_trust.gd
if errorlevel 1 goto :fail
echo.
echo == T-214 hardpoint inspector ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t214_hardpoint_inspector.gd
if errorlevel 1 goto :fail
echo.
echo == T-221 native identity ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t221_native_identity.gd
if errorlevel 1 goto :fail
echo.
echo == T-221 hardpoint provenance ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t221_hardpoint_provenance.gd
if errorlevel 1 goto :fail
echo.
echo == T-222 stage identity ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t222_stage_identity.gd
if errorlevel 1 goto :fail
echo.
echo == T-222 backup inventory ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t222_backup_inventory.gd
if errorlevel 1 goto :fail
echo.
echo == T-222 3D hardpoint selection ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t222_hardpoint_3d.gd
if errorlevel 1 goto :fail
echo.
echo == T-223 reserved paths ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t223_reserved_paths.gd
if errorlevel 1 goto :fail
echo.
echo == T-223 cleanup truth ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t223_cleanup_truth.gd
if errorlevel 1 goto :fail
echo.
echo == T-223 hardpoint fire ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t223_hardpoint_fire.gd
if errorlevel 1 goto :fail
echo.
echo == T-223 viewport picking ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t223_viewport_pick.gd
if errorlevel 1 goto :fail
echo.
echo == T-224 physical stage safety ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t224_stage_safety.gd
if errorlevel 1 goto :fail
echo.
echo == Windows path identity ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_windows_path_identity.gd
if errorlevel 1 goto :fail
echo.
echo == T-224 hardpoint identity ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/verify_t224_hardpoint_identity.gd
if errorlevel 1 goto :fail
echo.
echo == UI smoke ==
"%GODOT%" --headless --path "%ROOT%" res://tests/ui_smoke.tscn
if errorlevel 1 goto :fail
echo.
echo Ran 1106 core + 14 weapon-chain integrity + 31 alternate physical-slot provenance + 28 T-122 coherence + 31 T-123 contract + 44 T-128 cleanup contract + 35 T-214 receipt trust + 21 T-214 hardpoint inspector + 13 T-221 native identity + 24 T-221 hardpoint provenance + 8 T-222 stage identity + 12 T-222 backup inventory + 8 T-222 3D hardpoint + 11 T-223 reserved paths + 8 T-223 cleanup truth + 10 T-223 hardpoint fire + 6 T-223 viewport picking + 28 T-224 stage safety + 8 Windows path identity + 39 T-224 hardpoint identity tests in canonical BZ_ODF_SHAMAN suite
echo OK (core=1106, weapon_chain=14, alternate_slot=31, t122=28, t123=31, t128=44, t214_receipt=35, t214_hardpoint=21, t221_native=13, t221_hardpoint=24, t222_stage=8, t222_backup=12, t222_3d=8, t223_res=11, t223_clean=8, t223_fire=10, t223_pick=6, t224_stage=28, winpath=8, t224_hardpoint=39, ui=0 failures)
echo ALL TESTS PASSED
exit /b 0
:fail
echo.
echo TESTS FAILED
exit /b 1
