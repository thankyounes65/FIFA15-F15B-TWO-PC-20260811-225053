@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FIFA 15 Player B - Working-Server Relay Topology v6

echo ====================================================================
echo   FIFA 15 PLAYER B - WORKING-SERVER RELAY TOPOLOGY V6
echo ====================================================================
echo   Player B's wire is unchanged. No scenario selection.
echo   Player A advertises both players at its UDP relay (11000/11001),
echo   matching retail's server-relayed peer addressing.
echo   Candidate: FIFA15-MM-WORKING-SERVER-RELAY-TOPOLOGY-V6
echo ====================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-PARITY.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
