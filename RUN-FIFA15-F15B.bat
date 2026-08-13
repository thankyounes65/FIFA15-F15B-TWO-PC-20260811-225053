@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1"
set "BOOTRC=%ERRORLEVEL%"
if not "%BOOTRC%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
  echo.
  echo The FIFA 15 appliance stopped while preparing Tailscale with error %BOOTRC%.
  echo Send the newest FIFA15-F15B-DIAG-*.txt file from your Desktop to thankyounes.
  pause
  exit /b %BOOTRC%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Start
set "FWDRC=%ERRORLEVEL%"
if not "%FWDRC%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
  echo.
  echo The FIFA 15 appliance stopped while preparing remote QoS/FUT routing with error %FWDRC%.
  echo Nothing in FIFA was changed. Send the newest FIFA15-F15B-FORWARDER-*.log from your Desktop to thankyounes.
  pause
  exit /b %FWDRC%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnostic-run.ps1"
set "RC=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
set "FWDSTOPRC=%ERRORLEVEL%"
if not "%FWDSTOPRC%"=="0" if "%RC%"=="0" set "RC=3"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
set "CLEANRC=%ERRORLEVEL%"
if not "%CLEANRC%"=="0" (
  echo.
  echo Tailscale restoration reported error %CLEANRC%.
  echo Run CLEANUP-FIFA15-F15B.bat if restoration was incomplete.
  if "%RC%"=="0" set "RC=2"
)

echo.
echo Collecting the three Player-B evidence files into one ZIP...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-evidence.ps1"
set "EVIDRC=%ERRORLEVEL%"
if not "%EVIDRC%"=="0" (
  echo WARNING: automatic evidence bundling failed with error %EVIDRC%.
  echo Keep the newest FIFA15-F15B-DIAG-*.txt and FIFA15-F15B-FORWARDER-*.log files on the Desktop.
)

if not "%RC%"=="0" (
  echo.
  echo The FIFA 15 appliance stopped with error %RC%.
  echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from your Desktop to thankyounes.
  echo Run CLEANUP-FIFA15-F15B.bat if restoration was incomplete.
  pause
) else (
  echo.
  echo Test finished. Send the newest FIFA15-F15B-EVIDENCE-*.zip from your Desktop to thankyounes.
)
exit /b %RC%
