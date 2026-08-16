[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$Launcher = Join-Path $Root 'RUN-FIFA15-F15B-V18.bat'
$Contract = Join-Path $Root 'MATCHMAKING-V18-CANDIDATE.json'

if (-not (Test-Path -LiteralPath $Launcher -PathType Leaf)) { throw "Missing static v18 launcher: $Launcher" }
if (-not (Test-Path -LiteralPath $Contract -PathType Leaf)) { throw "Missing v18 candidate contract: $Contract" }

$text = Get-Content -LiteralPath $Launcher -Raw
foreach ($required in @(
    'FIFA15-MM-V18-DEFER-JOIN-COMPLETED',
    'F15B-GITHUB-DIAGNOSTIC-20260815-V18-DEFER-JOIN-COMPLETED-1',
    'integration/test-matchmaking-defer-join-completed-v18',
    'build_pairing_defer_join_completed_v18.rs',
    'matchmaking-v18-candidate-attest.ps1',
    'matchmaking-v16-native-handoff-attest.ps1',
    'classify-network-observer-v16.ps1',
    'collect-evidence-v16.ps1',
    'guest_runtime_inherited_from_v16=true',
    'guest_matchmaking_wire_change=false',
    'cd /d "%~dp0"'
)) {
    if (-not $text.Contains($required)) { throw "Static v18 B launcher lost required marker: $required" }
}

foreach ($forbidden in @(
    'set "CANDIDATE_ID=FIFA15-MM-V16-B-NATIVE-HANDOFF"',
    'set "PACKAGE_TOKEN=F15B-GITHUB-DIAGNOSTIC-20260815-V16-NATIVE-HANDOFF-2"',
    'set "EXPECTED_A=integration/test-matchmaking-b-native-handoff-v16"',
    'set "EXPECTED_BUILD=build_pairing_gsu_npsi_v15.rs"',
    'matchmaking-v16-candidate-attest.ps1'
)) {
    if ($text.Contains($forbidden)) { throw "Static v18 B launcher retained stale candidate marker: $forbidden" }
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'matchmaking-v18-candidate-attest.ps1') -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'v18 candidate attestor self-test failed' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'matchmaking-v16-native-handoff-attest.ps1') -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'inherited v16 native attestor self-test failed' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'classify-network-observer-v16.ps1') -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'inherited v16 network classifier self-test failed' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'collect-evidence-v16.ps1') -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'inherited v16 evidence collector self-test failed' }

    Write-Host 'PASS: v18 Player-B launcher is static, pins the exact v18 A candidate/package, and retains the fixed-v16 boot/native/network evidence stack.' -ForegroundColor Green
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

& cmd.exe /d /c "call `"$Launcher`""
exit [int]$LASTEXITCODE
