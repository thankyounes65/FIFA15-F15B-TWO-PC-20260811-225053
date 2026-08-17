@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FIFA 15 Player B - Native Matchmaking Observer

echo ====================================================================
echo   FIFA 15 PLAYER B - NATIVE MATCHMAKING OBSERVER
echo ====================================================================
echo   One unchanged-wire observation run. No scenario selection.
echo   Observes MatchSession success, 0x0B lifetime, and CardsDLL squad entry.
echo ====================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-PARITY.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
