@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\launch.ps1" -InstallShortcut
echo.
pause