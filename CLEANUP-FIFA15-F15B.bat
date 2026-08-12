@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Remote Player Cleanup - f15b
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch-safe.ps1" -Cleanup
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo Cleanup reported error %RC%. Keep this window open and send the message to thankyounes.
pause
exit /b %RC%
