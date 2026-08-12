@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Remote Player Cleanup - f15b

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
set "FWDRC=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch-safe.ps1" -Cleanup
set "RC=%ERRORLEVEL%"
if not "%FWDRC%"=="0" if "%RC%"=="0" set "RC=%FWDRC%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
set "TSRC=%ERRORLEVEL%"
if not "%TSRC%"=="0" if "%RC%"=="0" set "RC=%TSRC%"

if not "%RC%"=="0" echo Cleanup reported error %RC%. Keep this window open and send the message/diagnostic to thankyounes.
pause
exit /b %RC%
