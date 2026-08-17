@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FIFA 15 Player B - Working-Server Setup Burst v3

echo ====================================================================
echo   FIFA 15 PLAYER B - WORKING-SERVER SETUP BURST V3
echo ====================================================================
echo   Player B's wire is unchanged. No scenario selection.
echo   Player A is testing the post-GameSetup notification burst only.
echo   Candidate: FIFA15-MM-WORKING-SERVER-SETUP-BURST-V3
echo ====================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-PARITY.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
