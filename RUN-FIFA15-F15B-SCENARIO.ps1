[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateRange(1,4)][int]$Scenario)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$SuitePath = Join-Path $Root 'MATCHMAKING-SCENARIO-SUITE.json'
$TemplatePath = Join-Path $Root 'RUN-FIFA15-F15B-V18.bat'
$AttestPath = Join-Path $Root 'matchmaking-scenario-suite-attest.ps1'
if (-not (Test-Path -LiteralPath $SuitePath -PathType Leaf)) { throw "Missing $SuitePath" }
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw "Missing inherited v18 launcher $TemplatePath" }

$suite = Get-Content -LiteralPath $SuitePath -Raw | ConvertFrom-Json
$entry = @($suite.scenarios | Where-Object { [int]$_.id -eq $Scenario })
if ($entry.Count -ne 1) { throw "Scenario $Scenario did not resolve uniquely." }
$entry = $entry[0]
$package = [string]$suite.b_package
$started = [DateTime]::UtcNow
$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$scenarioRoot = Join-Path $Root ("runs\matchmaking-scenarios\player-b\scenario-{0}-{1}" -f $Scenario,[string]$entry.slug)
$attemptDir = Join-Path $scenarioRoot $stamp
New-Item -ItemType Directory -Force -Path $attemptDir | Out-Null

$env:SCENARIO_ID = [string]$Scenario
$env:SCENARIO_SLUG = [string]$entry.slug
$env:CANDIDATE_ID = [string]$entry.candidate_id
$env:PACKAGE_TOKEN = $package
$env:EXPECTED_A = [string]$entry.a_branch
$env:EXPECTED_BUILD = [string]$entry.a_build

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AttestPath -Scenario $Scenario -SelfTest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$template = Get-Content -LiteralPath $TemplatePath -Raw
$replacements = @(
    @('set "CANDIDATE_ID=FIFA15-MM-V18-DEFER-JOIN-COMPLETED"', 'set "CANDIDATE_ID=' + [string]$entry.candidate_id + '"'),
    @('set "PACKAGE_TOKEN=F15B-GITHUB-DIAGNOSTIC-20260815-V18-DEFER-JOIN-COMPLETED-1"', 'set "PACKAGE_TOKEN=' + $package + '"'),
    @('set "EXPECTED_A=integration/test-matchmaking-defer-join-completed-v18"', 'set "EXPECTED_A=' + [string]$entry.a_branch + '"'),
    @('set "EXPECTED_BUILD=build_pairing_defer_join_completed_v18.rs"', 'set "EXPECTED_BUILD=' + [string]$entry.a_build + '"'),
    @('matchmaking-v18-candidate-attest.ps1', 'matchmaking-scenario-suite-attest.ps1'),
    @('title FIFA 15 Remote Player - f15b - V18 Deferred JoinCompleted', 'title FIFA 15 Remote Player - f15b - Matchmaking Scenario %SCENARIO_ID%'),
    @('FIFA 15 PLAYER B - V18 DEFERRED JOINCOMPLETED', 'FIFA 15 PLAYER B - MATCHMAKING SCENARIO %SCENARIO_ID%'),
    @('A v18 changes one lifecycle send: immediate joiner JoinCompleted is deferred.', 'A scenario is selected by MATCHMAKING-SCENARIO-SUITE.json; Player-B runtime is unchanged.'),
    @('PLAYER B V18 ATTEMPT FINISHED', 'PLAYER B MATCHMAKING SCENARIO %SCENARIO_ID% FINISHED'),
    @('Player B remains on the fixed v16 stack; the sole A-side lifecycle variable is deferred joiner JoinCompleted.', 'Player B remains on the fixed v16/v18 stack; see SCENARIO-MANIFEST.txt for the exact isolated A-side variable.')
)
foreach ($pair in $replacements) {
    $old = [string]$pair[0]
    $new = [string]$pair[1]
    if (-not $template.Contains($old)) { throw "Scenario renderer lost required v18 launcher anchor: $old" }
    $template = $template.Replace($old,$new)
}

$tempPath = Join-Path $Root ('.RUN-FIFA15-F15B-SCENARIO-' + $PID + '.bat')
[IO.File]::WriteAllText($tempPath,$template,[Text.Encoding]::ASCII)
Copy-Item -LiteralPath $tempPath -Destination (Join-Path $attemptDir 'RENDERED-PLAYER-B-RUNTIME.bat') -Force
Copy-Item -LiteralPath $SuitePath -Destination (Join-Path $attemptDir 'MATCHMAKING-SCENARIO-SUITE.json') -Force

$startLines = @(
    'FIFA15 Player-B matchmaking scenario attempt',
    'started_utc=' + $started.ToString('o'),
    'scenario_id=' + $Scenario,
    'scenario_slug=' + [string]$entry.slug,
    'scenario_name=' + [string]$entry.name,
    'candidate_id=' + [string]$entry.candidate_id,
    'expected_a_branch=' + [string]$entry.a_branch,
    'expected_a_build=' + [string]$entry.a_build,
    'b_branch=' + [string]$suite.b_branch,
    'b_package=' + $package,
    'guest_runtime_change=false',
    'automatic_publication=false'
)
Set-Content -LiteralPath (Join-Path $attemptDir 'SCENARIO-MANIFEST.txt') -Value $startLines -Encoding UTF8

$rc = 99
try {
    Push-Location $Root
    try {
        & $env:ComSpec /d /c ('call "' + $tempPath + '"')
        $rc = $LASTEXITCODE
    }
    finally { Pop-Location }
}
finally {
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
}

$finished = [DateTime]::UtcNow
$desktop = [Environment]::GetFolderPath('Desktop')
$copied = New-Object System.Collections.Generic.List[string]
function Copy-EvidenceFile([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $source = Get-Item -LiteralPath $path
    $dest = Join-Path $attemptDir $source.Name
    Copy-Item -LiteralPath $source.FullName -Destination $dest -Force
    if (-not $copied.Contains($dest)) { [void]$copied.Add($dest) }
}

$locations = @($desktop,$Root) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
foreach ($location in $locations) {
    Get-ChildItem -LiteralPath $location -File -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTimeUtc -ge $started.AddSeconds(-2) -and (
            $_.Name -like 'FIFA15-F15B-DIAG-*' -or
            $_.Name -like 'FIFA15-F15B-NATIVE-*' -or
            $_.Name -like 'FIFA15-F15B-EVIDENCE-*.zip' -or
            $_.Name -like 'FIFA15-F15B-NETWORK-*'
        )
    } | ForEach-Object { Copy-EvidenceFile $_.FullName }
}

$diag = @($copied | Where-Object { [IO.Path]::GetFileName($_) -like 'FIFA15-F15B-DIAG-*' } | Sort-Object | Select-Object -Last 1)
if ($diag.Count -eq 1) {
    foreach ($line in (Get-Content -LiteralPath $diag[0] -ErrorAction SilentlyContinue)) {
        if ($line -match '^(network_observer_log|native_attestation_log)=(.+)$') { Copy-EvidenceFile $Matches[2].Trim() }
    }
}

$head = ''
try { $head = (& git -C $Root rev-parse HEAD 2>$null).Trim() } catch { $head = 'unavailable' }
$manifestPath = Join-Path $attemptDir 'SCENARIO-MANIFEST.txt'
Add-Content -LiteralPath $manifestPath -Encoding UTF8 -Value @(
    'finished_utc=' + $finished.ToString('o'),
    'launcher_exit_code=' + $rc,
    'exact_b_head=' + $head,
    'evidence_file_count=' + $copied.Count
)
foreach ($path in ($copied | Sort-Object -Unique)) {
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ('evidence=' + [IO.Path]::GetFileName($path) + '|sha256=' + $hash)
}
Set-Content -LiteralPath (Join-Path $scenarioRoot 'LATEST.txt') -Value $attemptDir -Encoding UTF8

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host ("  PLAYER B SCENARIO {0} ARCHIVED LOCALLY" -f $Scenario) -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host "Evidence: $attemptDir" -ForegroundColor Green
Write-Host 'No GitHub upload/publish step was attempted.' -ForegroundColor Gray
exit $rc
