[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$Root=Split-Path -Parent $PSCommandPath
$ScenarioPath=Join-Path $Root 'MATCHMAKING-SCENARIO.json'
$Template=Join-Path $Root 'RUN-FIFA15-F15B-V18.bat'
$Attest=Join-Path $Root 'matchmaking-scenario-attest.ps1'
$Archive=Join-Path $Root 'archive-matchmaking-scenario-evidence.ps1'
if(-not(Test-Path -LiteralPath $ScenarioPath -PathType Leaf)){throw "Missing $ScenarioPath"}
$S=Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json
function Parse-Ps([string]$Path){$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)|Out-Null;if($e -and $e.Count){throw "$Path parse errors: $(($e|ForEach-Object Message)-join '; ')"}}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Attest -SelfTest
if($LASTEXITCODE -ne 0){throw 'scenario attestation self-test failed'}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Archive -SelfTest
if($LASTEXITCODE -ne 0){throw 'scenario evidence archive self-test failed'}
Parse-Ps $Attest; Parse-Ps $Archive
if(-not(Test-Path -LiteralPath $Template -PathType Leaf)){throw 'Missing proven v18/fixed-v16 launcher template'}
$text=(Get-Content -LiteralPath $Template -Raw).Replace("`r`n","`n").Replace("`r","`n")
$replacements=[ordered]@{
 'set "CANDIDATE_ID=FIFA15-MM-V18-DEFER-JOIN-COMPLETED"'=('set "CANDIDATE_ID='+[string]$S.candidate_id+'"');
 'set "PACKAGE_TOKEN=F15B-GITHUB-DIAGNOSTIC-20260815-V18-DEFER-JOIN-COMPLETED-1"'=('set "PACKAGE_TOKEN='+[string]$S.package_attestation+'"');
 'set "EXPECTED_A=integration/test-matchmaking-defer-join-completed-v18"'=('set "EXPECTED_A='+[string]$S.expected_a_branch+'"');
 'set "EXPECTED_BUILD=build_pairing_defer_join_completed_v18.rs"'=('set "EXPECTED_BUILD='+[string]$S.expected_a_build+'"');
 'matchmaking-v18-candidate-attest.ps1'='matchmaking-scenario-attest.ps1';
 'title FIFA 15 Remote Player - f15b - V18 Deferred JoinCompleted'=('title FIFA 15 Remote Player - scenario '+[string]$S.scenario_id);
 'set "STAGE=v18_offline_package_selftests"'='set "STAGE=scenario_offline_package_selftests"';
 'set "STAGE=v18_candidate_gate"'='set "STAGE=scenario_candidate_gate"'
}
foreach($pair in $replacements.GetEnumerator()){
 $count=([regex]::Matches($text,[regex]::Escape([string]$pair.Key))).Count
 if($count -lt 1){throw "launcher template lost required anchor: $($pair.Key)"}
 $text=$text.Replace([string]$pair.Key,[string]$pair.Value)
}
if($text.Contains('matchmaking-v18-candidate-attest.ps1')){throw 'rendered launcher retained old v18 candidate attestor'}
if($SelfTest){Write-Host "PASS: Player-B scenario $($S.scenario_id) launcher renders from fixed-v16/v18 runtime with only scenario candidate/package gate substitutions." -ForegroundColor Green;exit 0}
$startedUtc=(Get-Date).ToUniversalTime(); $rc=1; $stage='rendered_runtime'
$temp=Join-Path $Root ("RUN-FIFA15-F15B-SCENARIO-{0}-{1}.bat" -f $S.scenario_id,[guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($temp,$text,[Text.UTF8Encoding]::new($false))
try{
 Write-Host "PLAYER B MATCHMAKING SCENARIO $($S.scenario_id): $($S.scenario_name)" -ForegroundColor Cyan
 Write-Host "B branch: $($S.b_branch)"; Write-Host "Expected A: $($S.expected_a_branch)"; Write-Host "Candidate: $($S.candidate_id)"
 & cmd.exe /d /c ("call `"{0}`"" -f $temp); $rc=[int]$LASTEXITCODE; $stage='runtime_finished'
} catch {Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; $stage='wrapper_failure'; $rc=1}
finally{
 Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
 try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Archive -StartedUtc $startedUtc -RuntimeExitCode $rc -Stage $stage}catch{Write-Warning "Scenario archive failed: $_"}
}
Write-Host "Player B scenario $($S.scenario_id) finished RC $rc. Evidence remains local under runs\matchmaking-scenarios\player-b\scenario-$($S.scenario_id)-$($S.scenario_slug)."
exit $rc
