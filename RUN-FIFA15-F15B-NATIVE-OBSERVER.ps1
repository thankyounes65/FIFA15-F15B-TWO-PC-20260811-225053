[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$Root=Split-Path -Parent $PSCommandPath
$Observer=Join-Path $Root 'matchmaking-native-observer.py'
$Attest=Join-Path $Root 'matchmaking-native-observer-attest.ps1'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmssfff'
$attempt=Join-Path $Root ("runs\matchmaking-native-observer\player-b\$stamp")
$jsonl=Join-Path $attempt 'native-observer.jsonl'
$text=Join-Path $attempt 'native-observer.txt'
$manifest=Join-Path $attempt 'OBSERVER-RUN-MANIFEST.txt'
$observerProcess=$null
$networkActive=$false
$forwarderActive=$false
$tailscaleAttempted=$false
$rc=1
$stage='preflight'
function Run([string]$File,[string[]]$Arguments=@()) { & $File @Arguments; if($LASTEXITCODE -ne 0){throw "$File returned $LASTEXITCODE"} }
function Assert-Files { foreach($name in @('matchmaking-native-observer.py','matchmaking-native-observer-attest.ps1','diagnostic-run.ps1','guest-network-observer.ps1','loopback-relay-forwarder.ps1','tailscale-bootstrap.ps1','VERIFY-PLAYER-B-GAME-FILES.ps1')){if(-not(Test-Path -LiteralPath (Join-Path $Root $name) -PathType Leaf)){throw "Missing observer prerequisite: $name"}} }
Assert-Files
if($SelfTest){
    Run 'python' @($Observer,'--self-test')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')
    Write-Host 'PASS: Player B native-observer runner has no scenario selector and reuses the existing boot/network stack.' -ForegroundColor Green
    exit 0
}
New-Item -ItemType Directory -Force -Path $attempt | Out-Null
@(
 'FIFA15 matchmaking native observer - Player B',
 "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
 'branch=integration/test-matchmaking-native-observer-v1',
 'wire_change=false','observer_only=true','scenario_selection=false',
 'target_chain=0x47BCC7C>0x479EBE9>0x479BC0B>0x3A04A32>0x3715903',
 'target_0x0b=0x47BE327..0x47BE448','target_cardsdll=0x3BAB0'
) | Set-Content -LiteralPath $manifest -Encoding UTF8
try {
    $stage='game_file_verify'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'VERIFY-PLAYER-B-GAME-FILES.ps1'))
    $stage='observer_selftest'; Run 'python' @($Observer,'--self-test')
    $stage='attestation_selftest'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')
    $stage='network_selftest'; Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'guest-network-observer.ps1'),'-SelfTest')

    $stage='tailscale_bootstrap';$tailscaleAttempted=$true;Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'tailscale-bootstrap.ps1'))
    $stage='forwarder_start';Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'loopback-relay-forwarder.ps1'),'-Start');$forwarderActive=$true
    $stage='network_start';Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'guest-network-observer.ps1'),'-Start');$networkActive=$true
    $stage='peer_gate';Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest)

    $stage='observer_start';$observerProcess=Start-Process -FilePath 'python' -ArgumentList @($Observer,'--jsonl',$jsonl,'--text',$text) -PassThru -NoNewWindow
    Start-Sleep -Milliseconds 500
    if($observerProcess.HasExited){throw "native observer exited before FIFA launch with code $($observerProcess.ExitCode)"}

    $stage='fifa_runtime'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'diagnostic-run.ps1');$rc=[int]$LASTEXITCODE
    $stage='post_runtime'
} catch {
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value ("error_stage=$stage`nerror=$($_.Exception.Message)")
    Write-Host "ERROR at stage ${stage}: $($_.Exception.Message)" -ForegroundColor Red
    if($stage -ne 'fifa_runtime' -and $stage -ne 'post_runtime'){Write-Host 'Runtime observation NOT REACHED; classify VOID.' -ForegroundColor Yellow}
    $rc=1
} finally {
    if($observerProcess){try{if(-not $observerProcess.HasExited){$observerProcess.WaitForExit(10000)|Out-Null}}catch{}}
    if($networkActive){try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'guest-network-observer.ps1') -Stop}catch{Write-Warning $_}}
    if($forwarderActive){try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'loopback-relay-forwarder.ps1') -Stop}catch{Write-Warning $_}}
    if($tailscaleAttempted){try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tailscale-bootstrap.ps1') -Cleanup}catch{Write-Warning $_}}
    $head=(& git -C $Root rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value @("finished_utc=$((Get-Date).ToUniversalTime().ToString('o'))","runtime_exit_code=$rc","final_stage=$stage","exact_b_head=$head","observer_jsonl=$jsonl","observer_text=$text")
    foreach($path in @($jsonl,$text)){if(Test-Path -LiteralPath $path -PathType Leaf){$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();Add-Content -LiteralPath $manifest -Encoding UTF8 -Value ("evidence=$([IO.Path]::GetFileName($path))|sha256=$hash")}}
}
Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host '  PLAYER B NATIVE OBSERVER RUN FINISHED' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host "Evidence: $attempt" -ForegroundColor Green
Write-Host 'No scenario was selected. Player B boot/network behavior is unchanged.' -ForegroundColor Gray
exit $rc
