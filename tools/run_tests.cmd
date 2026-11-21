@echo off
setlocal
set "ROOT=%~dp0.."
set "GODOT=V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
echo == Core tests ==
"%GODOT%" --headless --path "%ROOT%" --script res://tests/test_runner.gd
if errorlevel 1 goto :fail
echo.
echo == UI smoke ==
"%GODOT%" --headless --path "%ROOT%" res://tests/ui_smoke.tscn
if errorlevel 1 goto :fail
echo.
echo ALL TESTS PASSED
exit /b 0
:fail
echo.
echo TESTS FAILED
exit /b 1
