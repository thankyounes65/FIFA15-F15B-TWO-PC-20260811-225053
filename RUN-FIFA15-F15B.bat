@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FIFA 15 Player B - Working-Server Peer QoS v7

echo ====================================================================
echo   FIFA 15 PLAYER B - WORKING-SERVER PEER QOS V7
echo ====================================================================
echo   Player B's wire is unchanged. No scenario selection.
echo   Player A now publishes real network capacity for each peer
echo   instead of advertising both players at zero bandwidth.
echo   Candidate: FIFA15-MM-WORKING-SERVER-PEER-QOS-V7
echo ====================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-PARITY.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
