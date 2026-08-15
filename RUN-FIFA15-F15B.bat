@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b - V15 GSU NPSI

set "CANDIDATE_ID=FIFA15-MM-V15-GSU-NPSI"
set "PACKAGE_TOKEN=F15B-GITHUB-KNOWN-GOOD-20260815-V15-GSU-NPSI-1"
set "EXPECTED_A=integration/test-matchmaking-gsu-npsi-v15"
set "EXPECTED_BUILD=build_pairing_gsu_npsi_v15.rs"
set "RC=0"
set "OBSRC=0"
set "EVIDRC=0"
set "STAGE=invocation_start"
set "OBSERVER_ACTIVE=0"
set "FORWARDER_ACTIVE=0"
set "TAILSCALE_ATTEMPTED=0"

for /f "usebackq delims=" %%S in (`powershell.exe -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmssfff'"`) do set "RUN_STAMP=%%S"
for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"`) do set "DESKTOP=%%D"
if not defined RUN_STAMP (
  echo ERROR: could not create the v15 invocation run stamp.
  endlocal & exit /b 90
)
if not defined DESKTOP (
  echo ERROR: could not resolve the Desktop evidence path.
  endlocal & exit /b 91
)
set "DIAG_PATH=!DESKTOP!\FIFA15-F15B-DIAG-!RUN_STAMP!.txt"

powershell.exe -NoProfile -Command "$p=$env:DIAG_PATH; @('FIFA 15 F15B v15 exact-attempt diagnostic','started_utc='+[DateTime]::UtcNow.ToString('o'),'run_stamp='+$env:RUN_STAMP,'candidate_id='+$env:CANDIDATE_ID,'package_attestation='+$env:PACKAGE_TOKEN,'expected_a_branch='+$env:EXPECTED_A,'expected_a_build='+$env:EXPECTED_BUILD,'package_root='+$PWD.Path,'stage=invocation_start','') | Set-Content -LiteralPath $p -Encoding UTF8"
if errorlevel 1 (
  echo ERROR: could not create exact-attempt diagnostic !DIAG_PATH!.
  endlocal & exit /b 92
)

echo.
echo ====================================================================
echo   FIFA 15 PLAYER B - V15 GSU/NPSI
echo ====================================================================
echo   Candidate: !CANDIDATE_ID!
echo   Package:   !PACKAGE_TOKEN!
echo   Expected A: !EXPECTED_A!
echo   Expected build: !EXPECTED_BUILD!
echo   Run stamp: !RUN_STAMP!
echo   Exact diagnostic: !DIAG_PATH!
echo ====================================================================
echo.

set "STAGE=tailscale_bootstrap"
set "TAILSCALE_ATTEMPTED=1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1"
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)

set "STAGE=loopback_forwarder_start"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Start
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)
set "FORWARDER_ACTIVE=1"

set "STAGE=v15_attestation_selftest"
echo Verifying !CANDIDATE_ID! package agreement before FIFA is touched...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0matchmaking-v15-gsu-npsi-attest.ps1" -SelfTest
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)

set "STAGE=v15_candidate_gate"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0matchmaking-v15-gsu-npsi-attest.ps1"
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)

set "STAGE=network_observer_selftest"
echo Verifying read-only Player B LSX/Blaze network observer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -SelfTest
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)

set "STAGE=network_observer_start"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Start
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)
set "OBSERVER_ACTIVE=1"

set "STAGE=diagnostic_runtime"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnostic-run.ps1"
set "RC=!ERRORLEVEL!"

rem diagnostic-run creates the detailed current-attempt diagnostic after its own
rem preflight. Resolve only diagnostics created no earlier than our invocation
rem anchor; on an early failure the anchor itself remains the exact evidence.
for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -Command "$a=Get-Item -LiteralPath $env:DIAG_PATH; $f=Get-ChildItem -LiteralPath $a.DirectoryName -Filter 'FIFA15-F15B-DIAG-*.txt' -File -ErrorAction SilentlyContinue ^| Where-Object { $_.CreationTimeUtc -ge $a.CreationTimeUtc } ^| Sort-Object LastWriteTimeUtc -Descending ^| Select-Object -First 1; if($f){$f.FullName}else{$a.FullName}"`) do set "DIAG_PATH=%%D"

:finalize
set "FINAL_STAGE=!STAGE!"

if "!OBSERVER_ACTIVE!"=="1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Stop -AppendToNewestDiag
  set "OBSRC=!ERRORLEVEL!"
  set "OBSERVER_ACTIVE=0"
  if "!RC!"=="0" if not "!OBSRC!"=="0" set "RC=!OBSRC!"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Stop >nul 2>&1
)

if "!FORWARDER_ACTIVE!"=="1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop
  set "FWDSTOPRC=!ERRORLEVEL!"
  set "FORWARDER_ACTIVE=0"
  if not "!FWDSTOPRC!"=="0" if "!RC!"=="0" set "RC=3"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0loopback-relay-forwarder.ps1" -Stop >nul 2>&1
)

if "!TAILSCALE_ATTEMPTED!"=="1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailscale-bootstrap.ps1" -Cleanup
  set "CLEANRC=!ERRORLEVEL!"
  if not "!CLEANRC!"=="0" if "!RC!"=="0" set "RC=2"
) else (
  set "CLEANRC=0"
)

powershell.exe -NoProfile -Command "$p=$env:DIAG_PATH; if(Test-Path -LiteralPath $p){ Add-Content -LiteralPath $p -Encoding UTF8 -Value @('','=== V15 LAUNCHER RESULT ===','run_stamp='+$env:RUN_STAMP,'candidate_id='+$env:CANDIDATE_ID,'package_attestation='+$env:PACKAGE_TOKEN,'final_stage='+$env:FINAL_STAGE,'launcher_exit_code='+$env:RC,'observer_exit_code='+$env:OBSRC,'tailscale_cleanup_exit_code='+$env:CLEANRC,'finished_utc='+[DateTime]::UtcNow.ToString('o')) }"

echo.
echo Collecting exact-attempt Player-B diagnostic, network, forwarder and crash evidence...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-evidence-v15.ps1" -DiagPath "!DIAG_PATH!"
set "EVIDRC=!ERRORLEVEL!"
if not "!EVIDRC!"=="0" (
  echo WARNING: automatic evidence bundling failed with error !EVIDRC!.
  echo Exact diagnostic remains: !DIAG_PATH!
)

if "!OBSRC!"=="41" (
  echo.
  echo PLAYER B PREREQUISITE FAILURE: FIFA never established its required local LSX connection.
  echo This is before Blaze matchmaking; do not treat it as a matchmaking branch result.
)
if "!OBSRC!"=="42" (
  echo.
  echo PLAYER B PREREQUISITE FAILURE: local LSX worked, but FIFA never established Blaze TCP 42128 to Player A.
  echo This is before matchmaking pairing; do not treat it as a matchmaking branch result.
)

if not "!RC!"=="0" (
  echo.
  echo ====================================================================
  echo   PLAYER B V15 ATTEMPT ENDED WITH ERROR !RC! AT !FINAL_STAGE!
  echo ====================================================================
  echo Exact diagnostic: !DIAG_PATH!
  if "!EVIDRC!"=="0" echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from this attempt.
  echo Run CLEANUP-FIFA15-F15B.bat if restoration was incomplete.
  pause
) else (
  echo.
  echo ====================================================================
  echo   PLAYER B V15 ATTEMPT FINISHED - LSX/BLAZE OBSERVER RC !OBSRC!
  echo ====================================================================
  echo Exact diagnostic: !DIAG_PATH!
  if "!EVIDRC!"=="0" echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from this attempt.
)

set "FINAL_RC=!RC!"
endlocal & exit /b %FINAL_RC%
