@echo off
setlocal
set "APP=%~dp0"
set "GODOT=V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
if not exist "%GODOT%" (
  if /I "%GODOT%"=="godot" goto :run_path
  echo Godot not found at "%GODOT%" and not on PATH.
  echo Install Godot 4.x or edit run.cmd with your executable path.
  exit /b 2
)
:run_path
"%GODOT%" --path "%APP%"
exit /b %ERRORLEVEL%
