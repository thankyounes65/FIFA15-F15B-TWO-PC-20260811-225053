@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-preflight.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo The FIFA 15 appliance stopped during the Tailscale preflight with error %RC%.
  echo Read the STOP code above. Do not sign into thankyounes Tailscale account.
  pause
  exit /b %RC%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0safe-run.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo The FIFA 15 appliance stopped with error %RC%.
  echo Run CLEANUP-FIFA15-F15B.bat if the window says restoration was incomplete.
  pause
)
exit /b %RC%
