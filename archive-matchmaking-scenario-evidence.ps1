[CmdletBinding()]
param([datetime]$StartedUtc,[int]$RuntimeExitCode=0,[string]$Stage='runtime_finished',[switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$Root=Split-Path -Parent $PSCommandPath
$S=Get-Content -LiteralPath (Join-Path $Root 'MATCHMAKING-SCENARIO.json') -Raw | ConvertFrom-Json
$scenarioRoot=Join-Path $Root ("runs\matchmaking-scenarios\player-b\scenario-{0}-{1}" -f $S.scenario_id,$S.scenario_slug)
if ($SelfTest) {
    if ([int]$S.scenario_id -lt 1 -or [int]$S.scenario_id -gt 4) { throw 'scenario_id must be 1..4' }
    Write-Host "PASS: Player B scenario evidence target is $scenarioRoot; source selection is invocation-time bounded." -ForegroundColor Green
    exit 0
}
if (-not $StartedUtc) { $StartedUtc=(Get-Date).ToUniversalTime() }
$StartedUtc=$StartedUtc.ToUniversalTime(); $earliest=$StartedUtc.AddMinutes(-1)
$stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
$runDir=Join-Path $scenarioRoot $stamp; New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$branch=(& git -C $Root branch --show-current 2>$null | Select-Object -First 1); if($branch){$branch=$branch.Trim()}else{$branch='unknown'}
$head=(& git -C $Root rev-parse HEAD 2>$null | Select-Object -First 1); if($head){$head=$head.Trim()}else{$head='unknown'}
$desktop=[Environment]::GetFolderPath('Desktop')
$copied=0
if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) {
    $dest=Join-Path $runDir 'desktop-evidence'; New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach($file in Get-ChildItem -LiteralPath $desktop -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'FIFA15-F15B-*' -and $_.LastWriteTimeUtc -ge $earliest }) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dest $file.Name) -Force; $copied++
    }
    if ($copied -eq 0) { Remove-Item -LiteralPath $dest -Force -Recurse -ErrorAction SilentlyContinue }
}
Copy-Item -LiteralPath (Join-Path $Root 'MATCHMAKING-SCENARIO.json') -Destination (Join-Path $runDir 'MATCHMAKING-SCENARIO.json') -Force
@(
 'FIFA15 Player-B matchmaking scenario evidence manifest',
 "started_utc=$($StartedUtc.ToString('o'))","archived_utc=$((Get-Date).ToUniversalTime().ToString('o'))","player=B",
 "scenario_id=$($S.scenario_id)","scenario_slug=$($S.scenario_slug)","scenario_name=$($S.scenario_name)",
 "b_branch=$branch","b_commit=$head","b_expected_branch=$($S.b_branch)","package_attestation=$($S.package_attestation)",
 "expected_a_branch=$($S.expected_a_branch)","expected_a_build=$($S.expected_a_build)","candidate_id=$($S.candidate_id)",
 "wire_baseline=$($S.wire_baseline)","a_runtime_base=$($S.a_runtime_base)","b_runtime_base=$($S.b_runtime_base)",
 "protocol_delta=$($S.protocol_delta)","stage=$Stage","runtime_exit_code=$RuntimeExitCode","desktop_evidence_files_copied=$copied",
 'evidence_policy=local_only_no_automatic_upload',"expected_success=$($S.expected_success)","stop_point=$($S.stop_point)"
) | Set-Content -LiteralPath (Join-Path $runDir 'SCENARIO-MANIFEST.txt') -Encoding UTF8
$stamp | Set-Content -LiteralPath (Join-Path $scenarioRoot 'LATEST.txt') -Encoding ASCII
Write-Host "PASS: Player B evidence archived under $runDir" -ForegroundColor Green
if($copied -eq 0){Write-Host 'NOTE: no current-invocation Desktop evidence matched; stale prior evidence was not copied.' -ForegroundColor Yellow}
