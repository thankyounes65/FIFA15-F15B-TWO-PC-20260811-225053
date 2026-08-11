@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote-client.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo The FIFA 15 appliance stopped with error %RC%.
  echo Nothing should need manual repair; run CLEANUP-FIFA15-F15B.bat if needed.
  pause
)
exit /b %RC%
