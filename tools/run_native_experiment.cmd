@echo off
setlocal
set "ROOT=%~dp0.."
set "GODOT=V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
"%GODOT%" --headless --path "%ROOT%" --script res://tests/native_experiment_probe.gd
exit /b %ERRORLEVEL%
