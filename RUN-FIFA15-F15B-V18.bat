@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title FIFA 15 Remote Player - f15b - V18 Deferred JoinCompleted

set "CANDIDATE_ID=FIFA15-MM-V18-DEFER-JOIN-COMPLETED"
set "PACKAGE_TOKEN=F15B-GITHUB-DIAGNOSTIC-20260815-V18-DEFER-JOIN-COMPLETED-1"
set "EXPECTED_A=integration/test-matchmaking-defer-join-completed-v18"
set "EXPECTED_BUILD=build_pairing_defer_join_completed_v18.rs"
set "WIRE_BASELINE=53dbaafb32030d6790beb0c16d336acd68cc1d49"
set "RC=0"
set "RAWOBSRC=0"
set "OBSRC=0"
set "EVIDRC=0"
set "STAGE=invocation_start"
set "OBSERVER_ACTIVE=0"
set "FORWARDER_ACTIVE=0"
set "TAILSCALE_ATTEMPTED=0"
set "NETWORK_PATH="

for /f "usebackq delims=" %%S in (`powershell.exe -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmssfff'"`) do set "RUN_STAMP=%%S"
for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"`) do set "DESKTOP=%%D"
if not defined RUN_STAMP (
  echo ERROR: could not create v18 invocation stamp.
  endlocal & exit /b 90
)
if not defined DESKTOP (
  echo ERROR: could not resolve Desktop evidence path.
  endlocal & exit /b 91
)
set "DIAG_PATH=!DESKTOP!\FIFA15-F15B-DIAG-!RUN_STAMP!.txt"
set "NATIVE_PATH=!DESKTOP!\FIFA15-F15B-NATIVE-V16-!RUN_STAMP!.log"

powershell.exe -NoProfile -Command "$p=$env:DIAG_PATH; @('FIFA 15 F15B v18 exact-attempt diagnostic; B runtime inherited from fixed v16','started_utc='+[DateTime]::UtcNow.ToString('o'),'run_stamp='+$env:RUN_STAMP,'candidate_id='+$env:CANDIDATE_ID,'package_attestation='+$env:PACKAGE_TOKEN,'expected_a_branch='+$env:EXPECTED_A,'expected_a_build='+$env:EXPECTED_BUILD,'wire_protocol_baseline_commit='+$env:WIRE_BASELINE,'guest_runtime_inherited_from_v16=true','guest_matchmaking_wire_change=false','native_execution_probe=false','native_attestation_log='+$env:NATIVE_PATH,'stage=invocation_start','') | Set-Content -LiteralPath $p -Encoding UTF8"
if errorlevel 1 (
  echo ERROR: could not create exact-attempt v18 diagnostic !DIAG_PATH!.
  endlocal & exit /b 92
)

echo.
echo ====================================================================
echo   FIFA 15 PLAYER B - V18 DEFERRED JOINCOMPLETED
echo ====================================================================
echo   Candidate: !CANDIDATE_ID!
echo   Package:   !PACKAGE_TOKEN!
echo   Expected A: !EXPECTED_A!
echo   Wire baseline: !WIRE_BASELINE!
echo   Guest boot/network/native stack is inherited unchanged from fixed v16.
echo   A v18 changes one lifecycle send: immediate joiner JoinCompleted is deferred.
echo   Exact diagnostic: !DIAG_PATH!
echo   Exact native map: !NATIVE_PATH!
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

set "STAGE=v18_offline_package_selftests"
echo Verifying v18 package and inherited fixed-v16 evidence stack before FIFA is touched...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0matchmaking-v18-candidate-attest.ps1" -SelfTest
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0matchmaking-v16-native-handoff-attest.ps1" -SelfTest
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0classify-network-observer-v16.ps1" -SelfTest
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-evidence-v16.ps1" -SelfTest
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)

set "STAGE=v18_candidate_gate"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0matchmaking-v18-candidate-attest.ps1"
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)

set "STAGE=v16_native_address_map_attestation"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0matchmaking-v16-native-handoff-attest.ps1" -OutputPath "!NATIVE_PATH!"
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
  set "RC=!STEP_RC!"
  goto :finalize
)

set "STAGE=network_observer_selftest"
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
for /f "usebackq delims=" %%N in (`powershell.exe -NoProfile -Command "$p=Join-Path $env:TEMP 'fifa15-f15b-network-observer.json'; if(Test-Path -LiteralPath $p){$s=Get-Content -LiteralPath $p -Raw ^| ConvertFrom-Json; if($s.log_path){[IO.Path]::GetFullPath([string]$s.log_path)}}"`) do set "NETWORK_PATH=%%N"
if not defined NETWORK_PATH (
  echo ERROR: network observer did not expose its exact current-attempt log path.
  set "RC=93"
  goto :finalize
)
echo   Exact network log: !NETWORK_PATH!

set "STAGE=diagnostic_runtime"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnostic-run.ps1"
set "RC=!ERRORLEVEL!"

for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -Command "$a=Get-Item -LiteralPath $env:DIAG_PATH; $f=Get-ChildItem -LiteralPath $a.DirectoryName -Filter 'FIFA15-F15B-DIAG-*.txt' -File -ErrorAction SilentlyContinue ^| Where-Object { $_.CreationTimeUtc -ge $a.CreationTimeUtc } ^| Sort-Object LastWriteTimeUtc -Descending ^| Select-Object -First 1; if($f){$f.FullName}else{$a.FullName}"`) do set "DIAG_PATH=%%D"

:finalize
set "FINAL_STAGE=!STAGE!"

if "!OBSERVER_ACTIVE!"=="1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-network-observer.ps1" -Stop
  set "RAWOBSRC=!ERRORLEVEL!"
  set "OBSERVER_ACTIVE=0"
  if defined NETWORK_PATH (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0classify-network-observer-v16.ps1" -LogPath "!NETWORK_PATH!"
    set "OBSRC=!ERRORLEVEL!"
  ) else (
    set "OBSRC=43"
  )
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

powershell.exe -NoProfile -Command "$p=$env:DIAG_PATH; if(Test-Path -LiteralPath $p){ Add-Content -LiteralPath $p -Encoding UTF8 -Value @('','=== V18 LAUNCHER RESULT (B STACK INHERITED FROM V16) ===','run_stamp='+$env:RUN_STAMP,'candidate_id='+$env:CANDIDATE_ID,'package_attestation='+$env:PACKAGE_TOKEN,'wire_protocol_baseline_commit='+$env:WIRE_BASELINE,'network_observer_log='+$env:NETWORK_PATH,'native_attestation_log='+$env:NATIVE_PATH,'final_stage='+$env:FINAL_STAGE,'launcher_exit_code='+$env:RC,'legacy_observer_exit_code='+$env:RAWOBSRC,'v16_observer_exit_code='+$env:OBSRC,'tailscale_cleanup_exit_code='+$env:CLEANRC,'finished_utc='+[DateTime]::UtcNow.ToString('o')) }"

echo.
echo Collecting exact-attempt Player-B diagnostic, network, native-address-map, forwarder and crash evidence...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-evidence-v16.ps1" -DiagPath "!DIAG_PATH!" -NetworkPath "!NETWORK_PATH!" -NativePath "!NATIVE_PATH!"
set "EVIDRC=!ERRORLEVEL!"
if not "!EVIDRC!"=="0" echo WARNING: automatic v16 evidence bundling failed with error !EVIDRC!.

if "!OBSRC!"=="41" echo PLAYER B PREREQUISITE FAILURE: FIFA never established its required local LSX connection.
if "!OBSRC!"=="42" echo PLAYER B PREREQUISITE FAILURE: local LSX worked, but FIFA never established Blaze TCP 42128 to Player A.
if "!OBSRC!"=="43" echo PLAYER B PREREQUISITE FAILURE: current-attempt FIFA/network boundary was not observed.

echo.
echo ====================================================================
echo   PLAYER B V18 ATTEMPT FINISHED - RC !RC! - OBSERVER !OBSRC!
echo ====================================================================
echo Exact diagnostic: !DIAG_PATH!
if defined NETWORK_PATH echo Exact network log: !NETWORK_PATH!
echo Exact native map: !NATIVE_PATH!
if "!EVIDRC!"=="0" echo Send the newest FIFA15-F15B-EVIDENCE-*.zip from this attempt.
echo Player B remains on the fixed v16 stack; the sole A-side lifecycle variable is deferred joiner JoinCompleted.
if not "!RC!"=="0" pause

for %%R in (!RC!) do endlocal & exit /b %%R
