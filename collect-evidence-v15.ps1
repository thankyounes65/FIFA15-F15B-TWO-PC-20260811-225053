[CmdletBinding()]
param(
    [Parameter(ParameterSetName='Collect', Mandatory=$true)][string]$DiagPath,
    [Parameter(ParameterSetName='SelfTest', Mandatory=$true)][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$Collector = Join-Path $Root 'collect-evidence.ps1'

function Assert-Collector {
    if (-not (Test-Path -LiteralPath $Collector -PathType Leaf)) {
        throw "Missing legacy evidence collector: $Collector"
    }
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($Collector,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        throw "collect-evidence.ps1 parse failed: $((@($errors | ForEach-Object Message)) -join '; ')"
    }
    $source = Get-Content -LiteralPath $Collector -Raw
    if ($source -notmatch 'FIFA15-F15B-DIAG-\*\.txt') { throw 'legacy collector no longer discovers Player B diagnostics' }
    if ($source -notmatch 'FIFA15-F15B-EVIDENCE-') { throw 'legacy collector no longer produces the expected evidence ZIP' }
}

if ($SelfTest) {
    Assert-Collector
    Write-Host 'PASS: v15 evidence binder can invoke the proven collector and requires an exact diagnostic attempt.' -ForegroundColor Green
    exit 0
}

Assert-Collector
$resolved = (Resolve-Path -LiteralPath $DiagPath -ErrorAction Stop).Path
$item = Get-Item -LiteralPath $resolved -ErrorAction Stop
if ($item.PSIsContainer) { throw "Diagnostic path is not a file: $resolved" }
if ($item.Name -notlike 'FIFA15-F15B-DIAG-*.txt') { throw "Unexpected diagnostic filename: $($item.Name)" }

$desktop = $item.Directory.FullName
Add-Content -LiteralPath $resolved -Encoding UTF8 -Value @(
    '',
    '=== V15 EXACT-ATTEMPT EVIDENCE BINDING ===',
    "collection_bound_diag=$resolved",
    "collection_bound_utc=$((Get-Date).ToUniversalTime().ToString('o'))"
)
$item.LastWriteTimeUtc = [DateTime]::UtcNow

$newest = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-DIAG-*.txt' -File -ErrorAction Stop |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1)
if ($newest.Count -ne 1 -or $newest[0].FullName -ne $resolved) {
    $actual = if ($newest.Count -gt 0) { $newest[0].FullName } else { '<none>' }
    throw "Exact-attempt bind failed: expected newest diagnostic '$resolved', got '$actual'."
}

Write-Host "Evidence collector bound to exact diagnostic: $resolved" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Collector -DesktopPath $desktop
$rc = [int]$LASTEXITCODE
if ($rc -ne 0) {
    Write-Host "Evidence collector failed with exit code $rc; exact diagnostic remains at $resolved." -ForegroundColor Red
}
exit $rc
