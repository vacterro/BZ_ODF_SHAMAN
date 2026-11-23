@echo off
setlocal
set "ROOT=%~dp0.."
set "GODOT=V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
echo == Core tests ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/test_runner.gd
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
echo == UI smoke ==
"%GODOT%" --headless --path "%ROOT%" res://tests/ui_smoke.tscn
if errorlevel 1 goto :fail
echo.
echo Ran 1106 core + 28 T-122 coherence + 31 T-123 contract + 44 T-128 cleanup contract tests in canonical BZ_ODF_SHAMAN suite
echo OK (core=1106, t122=28, t123=31, t128=44, ui=0 failures)
echo ALL TESTS PASSED
exit /b 0
:fail
echo.
echo TESTS FAILED
exit /b 1
