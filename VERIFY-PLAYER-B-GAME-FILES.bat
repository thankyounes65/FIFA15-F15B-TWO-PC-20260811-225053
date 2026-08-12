@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Player B Known-Good File Audit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFY-PLAYER-B-GAME-FILES.ps1" -Strict
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo The audit found a difference from the recorded Player B baseline.
  echo Read PLAYER-B-BOOT-AND-CONNECT.md before changing any FIFA files.
  pause
)
exit /b %RC%
