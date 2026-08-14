@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b - Identity Session V4

set "PACKAGE_PREFLIGHT=%~dp0runtime-package-preflight.ps1"
if not exist "%PACKAGE_PREFLIGHT%" (
  echo PLAYER B PREFLIGHT FAILED - MISSING RUNTIME PACKAGE PREFLIGHT.
  pause
  exit /b 43
)

echo.
echo Verifying Player B packaged runtime provenance before any machine changes...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PACKAGE_PREFLIGHT%" -SelfTest
if errorlevel 1 (
  echo PLAYER B PREFLIGHT FAILED - FIFA WAS NOT LAUNCHED.
  pause
  exit /b 43
)

rem A previous diagnostic branch may have left a waiting native observer PID. Stop
rem it before FIFA exists; v4 never starts or self-tests the observer.
if exist "%~dp0guest-native-gsu-observer.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-native-gsu-observer.ps1" -Stop >nul 2>&1
)

echo.
echo ============================================================
echo   FIFA15 PLAYER B - IDENTITY / SESSION V4
echo ============================================================
echo   Paired host: integration/test-matchmaking-postmesh-gsu-v10
 echo   Match behavior: host v10 owns post-mesh GameSessionUpdated ordering correction.
echo   Routing: retain proven Tailscale + ProtoMangle/QoS/FUT forwarders.
echo   Crash isolation: NO Frida/Stalker/native observer is attached.
echo   Passive LSX/Blaze/network observation remains enabled.
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1"
set "BOOTRC=%ERRORLEVEL%"
if not "%BOOTRC%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
  echo The FIFA 15 appliance stopped while preparing Tailscale with error %BOOTRC%.
  pause
  exit /b %BOOTRC%
)

echo.
echo Verifying host-side DirtySDK ProtoMangle before FIFA is touched...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0demangler-preflight.ps1" -SelfTest
if errorlevel 1 goto :guest_preflight_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0demangler-preflight.ps1"
if errorlevel 1 goto :guest_preflight_failed

echo.
echo Verifying loopback QoS/FUT/ProtoMangle forwarder...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -SelfTest
if errorlevel 1 goto :guest_preflight_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Start
set "FWDRC=%ERRORLEVEL%"
if not "%FWDRC%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
  echo The FIFA 15 appliance stopped while preparing remote routing with error %FWDRC%.
  pause
  exit /b %FWDRC%
)

echo.
echo Verifying and starting passive Player B LSX/Blaze network observer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -SelfTest
set "OBSSELFRC=%ERRORLEVEL%"
if not "%OBSSELFRC%"=="0" goto :guest_preflight_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Start
set "OBSSTARTRC=%ERRORLEVEL%"
if not "%OBSSTARTRC%"=="0" goto :guest_preflight_failed

echo.
echo V4 crash guard active: native GSU/Frida observer is intentionally NOT started.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnostic-run.ps1"
set "RC=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Stop -AppendToNewestDiag
set "OBSRC=%ERRORLEVEL%"
if "%RC%"=="0" if not "%OBSRC%"=="0" set "RC=%OBSRC%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
set "FWDSTOPRC=%ERRORLEVEL%"
if not "%FWDSTOPRC%"=="0" if "%RC%"=="0" set "RC=3"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
set "CLEANRC=%ERRORLEVEL%"
if not "%CLEANRC%"=="0" (
  echo Tailscale restoration reported error %CLEANRC%.
  echo Run CLEANUP-FIFA15-F15B.bat if restoration was incomplete.
  if "%RC%"=="0" set "RC=2"
)

echo.
echo Collecting Player-B diagnostic, passive network, demangler-forwarder and crash evidence...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-evidence.ps1"
set "EVIDRC=%ERRORLEVEL%"
if not "%EVIDRC%"=="0" (
  echo WARNING: automatic evidence bundling failed with error %EVIDRC%.
  echo Keep the newest FIFA15-F15B-DIAG, NETWORK and FORWARDER files from the Desktop.
)

if "%OBSRC%"=="41" (
  echo PLAYER B PREREQUISITE FAILURE: FIFA never established required local LSX.
)
if "%OBSRC%"=="42" (
  echo PLAYER B PREREQUISITE FAILURE: local LSX worked, but FIFA never established Blaze TCP 42128.
)

if not "%RC%"=="0" (
  echo.
  echo The FIFA 15 appliance stopped with error %RC%.
  echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from the Desktop.
  pause
) else (
  echo.
  echo Test finished against host post-mesh GSU v10 with passive network diagnostics only.
  echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from the Desktop.
)
exit /b %RC%

:guest_preflight_failed
echo.
echo PLAYER B PREFLIGHT FAILED - FIFA WAS NOT LAUNCHED.
echo The mandatory demangler/network prerequisite failed above.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Stop >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
pause
exit /b 1
