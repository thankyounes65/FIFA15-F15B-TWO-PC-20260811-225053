@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnostic-run.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo The FIFA 15 appliance stopped with error %RC%.
  echo Send the FIFA15-F15B-DIAG-*.txt file from your Desktop to thankyounes.
  echo Run CLEANUP-FIFA15-F15B.bat only if the window says restoration was incomplete.
  pause
)
exit /b %RC%
