@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FIFA 15 Player B - Working-Server QoS Probe v8

echo ====================================================================
echo   FIFA 15 PLAYER B - WORKING-SERVER QOS PROBE V8
echo ====================================================================
echo   Player B's wire is unchanged. No scenario selection.
echo   Player A now serves the full QoS probe protocol, so this
echo   client can finally measure its own bandwidth and NAT type.
echo   Candidate: FIFA15-MM-WORKING-SERVER-QOS-BW-ACK-V11
echo ====================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-PARITY.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
