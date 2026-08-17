@echo off
setlocal EnableExtensions
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0COLLECT-PLAYER-B-EVIDENCE.ps1" %*
echo.
pause
endlocal
