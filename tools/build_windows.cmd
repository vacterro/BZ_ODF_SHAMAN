@echo off
setlocal
set "ROOT=%~dp0.."
set "GODOT_DIR=V:\__STORE_V\_SOFT\Godot\4.7.2-stable"
set "GODOT=%GODOT_DIR%\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
set "TEMPLATES="
if exist "%GODOT_DIR%\editor_data\export_templates\4.7.2.stable\windows_release_x86_64.exe" (
  set "TEMPLATES=%GODOT_DIR%\editor_data\export_templates\4.7.2.stable"
) else if exist "%GODOT_DIR%\export_templates\4.7.2.stable\windows_release_x86_64.exe" (
  set "TEMPLATES=%GODOT_DIR%\export_templates\4.7.2.stable"
) else if exist "%APPDATA%\Godot\export_templates\4.7.2.stable\windows_release_x86_64.exe" (
  set "TEMPLATES=%APPDATA%\Godot\export_templates\4.7.2.stable"
)
if "%TEMPLATES%"=="" (
  echo Export templates for Godot 4.7.2 are not installed.
  echo Install them from the Godot editor ^(Editor ^> Manage Export Templates^),
  echo then rerun this script.
  exit /b 2
)
if not exist "%ROOT%\export_presets.cfg" (
  echo export_presets.cfg is missing. Add a "Windows Desktop" preset in the editor first.
  exit /b 2
)
if not exist "%ROOT%\build" mkdir "%ROOT%\build"
"%GODOT%" --headless --path "%ROOT%" --export-release "Windows Desktop" "%ROOT%\build\BZ_ODF_SHAMAN.exe"
if errorlevel 1 exit /b 1
copy /Y "%ROOT%\build\BZ_ODF_SHAMAN.exe" "%ROOT%\BZ_ODF_SHAMAN.exe" >nul
if errorlevel 1 exit /b 1
echo Built: %ROOT%\BZ_ODF_SHAMAN.exe ^(and %ROOT%\build\BZ_ODF_SHAMAN.exe^)
exit /b 0
