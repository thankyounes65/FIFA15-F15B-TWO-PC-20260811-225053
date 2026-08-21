[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2

$Root=Split-Path -Parent $PSCommandPath
$Attest=Join-Path $Root 'matchmaking-working-server-parity-attest.ps1'
$GameVerify=Join-Path $Root 'VERIFY-PLAYER-B-GAME-FILES.ps1'
$Network=Join-Path $Root 'guest-network-observer.ps1'
$Forwarder=Join-Path $Root 'loopback-relay-forwarder.ps1'
$Tailscale=Join-Path $Root 'tailscale-bootstrap.ps1'
$Diagnostic=Join-Path $Root 'diagnostic-run.ps1'
$Collect=Join-Path $Root 'COLLECT-PLAYER-B-EVIDENCE.ps1'
$Capture=Join-Path $Root 'capture-blaze-traffic.ps1'
$RuntimeTest=Join-Path $Root 'RUNTIME-TEST.md'
$Candidate='FIFA15-MM-QOS-STATE-PARITY-V1'
$Package='F15B-MM-QOS-STATE-PARITY-V1'
$ExpectedBranch='integration/test-matchmaking-qos-state-parity-v1'

$stamp=Get-Date -Format 'yyyyMMdd-HHmmssfff'
$attempt=Join-Path $Root ("runs\matchmaking-qos-state-parity-v1\player-b\$stamp")
$manifest=Join-Path $attempt 'RUN-MANIFEST.txt'
$networkActive=$false
$captureActive=$false
$forwarderActive=$false
$tailscaleAttempted=$false
$rc=1
$stage='preflight'

function Run([string]$File,[string[]]$Arguments=@()) {
    & $File @Arguments
    if($LASTEXITCODE -ne 0){throw "$File returned $LASTEXITCODE"}
}
function Hash-OrUnavailable([string]$Path){
    try{if(Test-Path -LiteralPath $Path -PathType Leaf){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}}catch{}
    'unavailable'
}
function Assert-Files {
    foreach($name in @(
        'matchmaking-working-server-parity-attest.ps1','diagnostic-run.ps1',
        'guest-network-observer.ps1','loopback-relay-forwarder.ps1','tailscale-bootstrap.ps1',
        'VERIFY-PLAYER-B-GAME-FILES.ps1','COLLECT-PLAYER-B-EVIDENCE.ps1',
        'capture-blaze-traffic.ps1','RUNTIME-TEST.md','APPLIANCE-CONFIG.json','PACKAGE-MANIFEST.json'
    )){
        if(-not(Test-Path -LiteralPath (Join-Path $Root $name) -PathType Leaf)){throw "Missing Player B prerequisite: $name"}
    }
}

Assert-Files
if($SelfTest){
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$GameVerify,'-SelfTest')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Network,'-SelfTest')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Collect,'-SelfTest')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Capture,'-SelfTest')
    $source=Get-Content -LiteralPath $PSCommandPath -Raw
    foreach($token in @(('Interceptor'+'.attach'),('Stalker'+'.follow'))){if($source.Contains($token)){throw "In-process instrumentation token present: $token"}}
    Write-Host "PASS: Player B QoS state-parity runner pins $ExpectedBranch / $Candidate / $Package and reuses the proven passive boot/network/capture stack." -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $attempt | Out-Null
@(
    'FIFA15 QoS state parity v1 - Player B',
    "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    "branch=$ExpectedBranch",
    "candidate_id=$Candidate",
    "package_attestation=$Package",
    'native_instrumentation=none',
    'frida_used=false',
    'player_b_wire_change=false',
    'player_a_wire_scope=preserve_client_measured_qdat_into_self_peer_and_game_documents',
    'primary_runtime_discriminator=measured_qdat_then_gameplay_udp_payload_ge_150',
    'req2_secondary_marker_only=true',
    'player_b_wire_capture=filtered_pktmon_full_packets'
) | Set-Content -LiteralPath $manifest -Encoding UTF8

try{
    $stage='game_file_verify'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$GameVerify)
    $stage='attestation_selftest'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')
    $stage='network_selftest'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Network,'-SelfTest')
    $stage='tailscale_bootstrap'; $tailscaleAttempted=$true; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Tailscale)
    $stage='stale_helper_reset'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Network -Reset; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Forwarder -Stop 2>$null | Out-Null
    $stage='forwarder_start'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Forwarder,'-Start'); $forwarderActive=$true
    $stage='network_start'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Network,'-Start'); $networkActive=$true
    $stage='wire_capture_start'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Capture,'-Start'); $captureActive=$true
    $stage='peer_gate'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest)
    $stage='fifa_runtime'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Diagnostic; $rc=[int]$LASTEXITCODE; $stage='post_runtime'
}catch{
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value ("error_stage=$stage`nerror=$($_.Exception.Message)")
    Write-Host "ERROR at stage ${stage}: $($_.Exception.Message)" -ForegroundColor Red
    if($stage -ne 'fifa_runtime' -and $stage -ne 'post_runtime'){Write-Host 'Runtime observation NOT REACHED; classify VOID.' -ForegroundColor Yellow}
    $rc=1
}finally{
    if($captureActive){try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Capture -Stop -OutDir $attempt}catch{Write-Warning $_}}
    if($networkActive){try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Network -Stop}catch{Write-Warning $_}}
    if($forwarderActive){try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Forwarder -Stop}catch{Write-Warning $_}}
    if($tailscaleAttempted){try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tailscale -Cleanup}catch{Write-Warning $_}}
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value @(
        "finished_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
        "runtime_exit_code=$rc","final_stage=$stage",
        "package_runtime_test_sha256=$(Hash-OrUnavailable $RuntimeTest)",
        "package_attest_sha256=$(Hash-OrUnavailable $Attest)",
        "package_runner_sha256=$(Hash-OrUnavailable $PSCommandPath)",
        "package_manifest_sha256=$(Hash-OrUnavailable (Join-Path $Root 'PACKAGE-MANIFEST.json'))",
        "appliance_config_sha256=$(Hash-OrUnavailable (Join-Path $Root 'APPLIANCE-CONFIG.json'))"
    )
    try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Collect}catch{Write-Warning "evidence collection failed: $($_.Exception.Message)"}
}

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host '  PLAYER B QOS STATE PARITY V1 RUN FINISHED' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host "Attempt: $attempt" -ForegroundColor Green
Write-Host 'Nothing attached to fifa15.exe. Preserve the automatic evidence ZIP.' -ForegroundColor Gray
exit $rc
