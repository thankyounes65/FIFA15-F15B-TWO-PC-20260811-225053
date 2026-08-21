@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FIFA 15 Player B - QoS State Parity V1

echo ====================================================================
echo   FIFA 15 PLAYER B - QOS STATE PARITY V1
echo ====================================================================
echo   Player B wire behavior is unchanged. No instrumentation.
echo   Player A preserves FIFA-authored QDAT DBPS/UBPS instead of
echo   discarding them and republishing zero/capture constants.
echo   Candidate: FIFA15-MM-QOS-STATE-PARITY-V1
echo   Package:   F15B-MM-QOS-STATE-PARITY-V1
echo ====================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-QOS-STATE-PARITY.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
