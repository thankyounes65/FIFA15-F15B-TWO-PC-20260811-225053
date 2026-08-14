@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b - Demangler + Native GSU V2

set "PACKAGE_PREFLIGHT=%~dp0runtime-package-preflight.ps1"
if not exist "%PACKAGE_PREFLIGHT%" (
  echo.
  echo PLAYER B PREFLIGHT FAILED - MISSING RUNTIME PACKAGE PREFLIGHT.
  echo Re-download or update the Player B tester package.
  pause
  exit /b 43
)

echo.
echo Verifying Player B packaged runtime provenance before any machine changes...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PACKAGE_PREFLIGHT%" -SelfTest
if errorlevel 1 (
  echo.
  echo PLAYER B PREFLIGHT FAILED - FIFA WAS NOT LAUNCHED.
  echo The package/runtime provenance check failed above.
  pause
  exit /b 43
)

echo.
echo ============================================================
echo   FIFA15 PLAYER B - DEMANGLER + NATIVE GSU V2
echo ============================================================
echo   Behavioral change: Player B can reach DirtySDK ProtoMangle
 echo   on TCP/3658 through the host preservation service.
echo   Diagnostics: LSX/Blaze sockets + exact-byte native GSU trace.
echo ============================================================
echo.

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

echo.
echo Verifying the host-side DirtySDK ProtoMangle service before FIFA is touched...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0demangler-preflight.ps1" -SelfTest
if errorlevel 1 goto :guest_preflight_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0demangler-preflight.ps1"
if errorlevel 1 goto :guest_preflight_failed

echo.
echo Verifying the loopback QoS/FUT/ProtoMangle forwarder...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -SelfTest
if errorlevel 1 goto :guest_preflight_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Start
set "FWDRC=%ERRORLEVEL%"
if not "%FWDRC%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
  echo.
  echo The FIFA 15 appliance stopped while preparing remote QoS/FUT/demangler routing with error %FWDRC%.
  echo Nothing in FIFA was changed. Send the newest FIFA15-F15B-FORWARDER-*.log from your Desktop to thankyounes.
  pause
  exit /b %FWDRC%
)

echo.
echo Verifying the read-only Player B LSX/Blaze network observer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -SelfTest
set "OBSSELFRC=%ERRORLEVEL%"
if not "%OBSSELFRC%"=="0" goto :guest_preflight_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Start
set "OBSSTARTRC=%ERRORLEVEL%"
if not "%OBSSTARTRC%"=="0" goto :guest_preflight_failed

echo.
echo Verifying and arming the exact-byte-guarded Player B native GameSetup/JoinCompleted/GSU observer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-native-gsu-observer.ps1" -SelfTest
set "NATIVESELFRC=%ERRORLEVEL%"
if not "%NATIVESELFRC%"=="0" goto :guest_preflight_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0append-native-gsu-evidence.ps1" -SelfTest
set "APPENDSELFRC=%ERRORLEVEL%"
if not "%APPENDSELFRC%"=="0" goto :guest_preflight_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-native-gsu-observer.ps1" -Start
set "NATIVESTARTRC=%ERRORLEVEL%"
if not "%NATIVESTARTRC%"=="0" goto :guest_preflight_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnostic-run.ps1"
set "RC=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Stop -AppendToNewestDiag
set "OBSRC=%ERRORLEVEL%"
if "%RC%"=="0" if not "%OBSRC%"=="0" set "RC=%OBSRC%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-native-gsu-observer.ps1" -Stop
set "NATIVERC=%ERRORLEVEL%"
if "%RC%"=="0" if not "%NATIVERC%"=="0" set "RC=%NATIVERC%"

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
echo Collecting Player-B diagnostic, network, native GSU, demangler-forwarder and crash evidence into one ZIP...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-evidence.ps1"
set "EVIDRC=%ERRORLEVEL%"
if not "%EVIDRC%"=="0" (
  echo WARNING: automatic evidence bundling failed with error %EVIDRC%.
  echo Keep the newest FIFA15-F15B-DIAG-*.txt, FIFA15-F15B-NETWORK-*.log, FIFA15-F15B-NATIVE-GSU-* and FIFA15-F15B-FORWARDER-*.log files on the Desktop.
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0append-native-gsu-evidence.ps1"
  set "APPENDRC=!ERRORLEVEL!"
  if not "!APPENDRC!"=="0" echo WARNING: native GSU files could not be appended automatically; keep the Desktop FIFA15-F15B-NATIVE-GSU-* files with the ZIP.
)

if "%OBSRC%"=="41" (
  echo.
  echo PLAYER B PREREQUISITE FAILURE: FIFA never established its required local LSX connection.
  echo This is before Blaze matchmaking; do not treat it as a Matchmaking branch result.
)
if "%OBSRC%"=="42" (
  echo.
  echo PLAYER B PREREQUISITE FAILURE: local LSX worked, but FIFA never established Blaze TCP 42128 to the host relay.
  echo This is before matchmaking pairing; do not treat it as a Matchmaking branch result.
)

if not "%RC%"=="0" (
  echo.
  echo The FIFA 15 appliance stopped with error %RC%.
  echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from your Desktop to thankyounes.
  echo Run CLEANUP-FIFA15-F15B.bat if restoration was incomplete.
  pause
) else (
  echo.
  echo Test finished with Player B demangler routing, LSX/Blaze and native GSU diagnostics armed.
  echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from your Desktop to thankyounes.
)
exit /b %RC%

:guest_preflight_failed
echo.
echo PLAYER B PREFLIGHT FAILED - FIFA WAS NOT LAUNCHED.
echo The demangler/network/native observer check failed above.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-native-gsu-observer.ps1" -Stop >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Stop >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
pause
exit /b 1
