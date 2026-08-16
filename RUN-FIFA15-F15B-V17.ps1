[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$Source = Join-Path $Root 'RUN-FIFA15-F15B-V16.bat'
$Temp = Join-Path $env:TEMP ("RUN-FIFA15-F15B-V17-{0}.bat" -f $PID)

function Replace-Exact([ref]$Text,[string]$Old,[string]$New,[string]$Label) {
    $count = ([regex]::Matches($Text.Value,[regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "$Label expected one v16 launcher anchor, found $count" }
    $Text.Value = $Text.Value.Replace($Old,$New)
}

if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Missing inherited fixed v16 launcher: $Source" }
$text = (Get-Content -LiteralPath $Source -Raw).Replace("`r`n","`n").Replace("`r","`n")
$ref = [ref]$text
Replace-Exact $ref 'title FIFA 15 Remote Player - f15b - V16 Native Handoff Diagnostic' 'title FIFA 15 Remote Player - f15b - V17 A Self GSU NPSI' 'title'
Replace-Exact $ref 'set "CANDIDATE_ID=FIFA15-MM-V16-B-NATIVE-HANDOFF"' 'set "CANDIDATE_ID=FIFA15-MM-V17-A-SELF-GSU-NPSI"' 'candidate id'
Replace-Exact $ref 'set "PACKAGE_TOKEN=F15B-GITHUB-DIAGNOSTIC-20260815-V16-NATIVE-HANDOFF-2"' 'set "PACKAGE_TOKEN=F15B-GITHUB-DIAGNOSTIC-20260815-V17-SELF-GSU-NPSI-1"' 'package token'
Replace-Exact $ref 'set "EXPECTED_A=integration/test-matchmaking-b-native-handoff-v16"' 'set "EXPECTED_A=integration/test-matchmaking-a-self-gsu-npsi-v17"' 'expected A branch'
Replace-Exact $ref 'set "EXPECTED_BUILD=build_pairing_gsu_npsi_v15.rs"' 'set "EXPECTED_BUILD=build_pairing_gsu_npsi_v17.rs"' 'expected A build'
$text = $ref.Value.Replace('matchmaking-v16-candidate-attest.ps1','matchmaking-v17-candidate-attest.ps1')
$text = $text.Replace('FIFA 15 F15B v16 exact-attempt diagnostic','FIFA 15 F15B v17 exact-attempt diagnostic; B runtime inherited from fixed v16')
$text = $text.Replace('FIFA 15 PLAYER B - V16 NATIVE HANDOFF DIAGNOSTIC','FIFA 15 PLAYER B - V17 A SELF GSU NPSI')
$text = $text.Replace('No matchmaking wire changes. No FIFA code hook/debugger attach.','Guest matchmaking/boot stack is unchanged from fixed v16. A v17 changes creator/self 0x73 only. No FIFA code hook/debugger attach.')
$text = $text.Replace('PLAYER B V16 ATTEMPT FINISHED','PLAYER B V17 ATTEMPT FINISHED')
$text = $text.Replace('V16 is diagnostic-only: a matchmaking failure is evidence, not proof that the relay packet contract changed.','Player B remains diagnostic-only on the fixed v16 stack; the sole game-wire variable is on Player A v17.')
$text = $text.Replace('=== V16 LAUNCHER RESULT ===','=== V17 LAUNCHER RESULT (B STACK INHERITED FROM V16) ===')

foreach ($required in @(
    'FIFA15-MM-V17-A-SELF-GSU-NPSI',
    'F15B-GITHUB-DIAGNOSTIC-20260815-V17-SELF-GSU-NPSI-1',
    'integration/test-matchmaking-a-self-gsu-npsi-v17',
    'build_pairing_gsu_npsi_v17.rs',
    'matchmaking-v17-candidate-attest.ps1',
    'matchmaking-v16-native-handoff-attest.ps1',
    'classify-network-observer-v16.ps1',
    'collect-evidence-v16.ps1'
)) {
    if (-not $text.Contains($required)) { throw "Rendered v17 B launcher lost required marker: $required" }
}
foreach ($forbidden in @(
    'set "CANDIDATE_ID=FIFA15-MM-V16-B-NATIVE-HANDOFF"',
    'set "EXPECTED_A=integration/test-matchmaking-b-native-handoff-v16"',
    'matchmaking-v16-candidate-attest.ps1'
)) {
    if ($text.Contains($forbidden)) { throw "Rendered v17 B launcher retained stale candidate marker: $forbidden" }
}

if ($SelfTest) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'matchmaking-v17-candidate-attest.ps1') -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'v17 candidate attestor self-test failed' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'matchmaking-v16-native-handoff-attest.ps1') -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'inherited v16 native attestor self-test failed' }
    Write-Host 'PASS: v17 B launcher renders from exact fixed v16 runtime, changes candidate metadata only, and retains v16 native/network evidence tools.' -ForegroundColor Green
    exit 0
}

[IO.File]::WriteAllText($Temp,$text,[Text.UTF8Encoding]::new($false))
try {
    & cmd.exe /d /c "call `"$Temp`""
    exit [int]$LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}
