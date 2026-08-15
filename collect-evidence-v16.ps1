[CmdletBinding()]
param(
    [Parameter(ParameterSetName='Collect', Mandatory=$true)][string]$DiagPath,
    [Parameter(ParameterSetName='Collect')][string]$NetworkPath,
    [Parameter(ParameterSetName='Collect')][string]$NativePath,
    [Parameter(ParameterSetName='SelfTest', Mandatory=$true)][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$V15Collector = Join-Path $Root 'collect-evidence-v15.ps1'

function Get-PointerFromDiag([string]$Path,[string]$Key) {
    $prefix = $Key + '='
    $line = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_.Trim().StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -Last 1)
    if ($line.Count -ne 1) { return $null }
    $value = $line[0].Trim().Substring($prefix.Length).Trim()
    if (-not $value -or $value -eq '<missing>') { return $null }
    return $value
}

function Resolve-ExactFile([string]$Path,[string]$Desktop,[string]$Pattern,[string]$Label) {
    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $item = Get-Item -LiteralPath $resolved -ErrorAction Stop
    if ($item.Directory.FullName -ne $Desktop) { throw "$Label escaped Desktop evidence directory: $resolved" }
    if ($item.Name -notlike $Pattern) { throw "$Label has unexpected filename: $resolved" }
    return $item
}

function Invoke-SelfTest {
    if (-not (Test-Path -LiteralPath $V15Collector -PathType Leaf)) { throw "Missing $V15Collector" }
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('NetworkPath','NativePath','network_observer_log','native_attestation_log','Resolve-ExactFile','V16 EXACT-ATTEMPT EVIDENCE BINDING','EXPLICIT_ATTEMPT_PATHS_NO_NEWEST_FILE_HEURISTIC','Compress-Archive')) {
        if (-not $source.Contains($marker)) { throw "missing v16 evidence marker: $marker" }
    }
    Write-Host 'PASS: v16 evidence binder accepts explicit exact-attempt network/native paths; CI separately rejects newest-file selection logic.' -ForegroundColor Green
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

$resolved = (Resolve-Path -LiteralPath $DiagPath -ErrorAction Stop).Path
$item = Get-Item -LiteralPath $resolved -ErrorAction Stop
if ($item.PSIsContainer -or $item.Name -notlike 'FIFA15-F15B-DIAG-*.txt') { throw "Unexpected diagnostic path: $resolved" }
$desktop = $item.Directory.FullName
$stamp = [IO.Path]::GetFileNameWithoutExtension($item.Name).Substring('FIFA15-F15B-DIAG-'.Length)

if (-not $NetworkPath) { $NetworkPath = Get-PointerFromDiag -Path $resolved -Key 'network_observer_log' }
if (-not $NativePath) { $NativePath = Get-PointerFromDiag -Path $resolved -Key 'native_attestation_log' }
$network = Resolve-ExactFile -Path $NetworkPath -Desktop $desktop -Pattern 'FIFA15-F15B-NETWORK-*.log' -Label 'network log'
$native = Resolve-ExactFile -Path $NativePath -Desktop $desktop -Pattern 'FIFA15-F15B-NATIVE-V16-*.log' -Label 'native attestation log'

Add-Content -LiteralPath $resolved -Encoding UTF8 -Value @(
    '',
    '=== V16 EXACT-ATTEMPT EVIDENCE BINDING ===',
    "collection_bound_diag=$resolved",
    "network_log=$([string]$(if($network){$network.FullName}else{'<missing>'}))",
    "native_attestation_log=$([string]$(if($native){$native.FullName}else{'<missing>'}))",
    'evidence_selection_policy=EXPLICIT_ATTEMPT_PATHS_NO_NEWEST_FILE_HEURISTIC',
    "collection_bound_utc=$((Get-Date).ToUniversalTime().ToString('o'))"
)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $V15Collector -DiagPath $resolved
$rc = [int]$LASTEXITCODE
if ($rc -ne 0) { exit $rc }

$zipPath = Join-Path $desktop "FIFA15-F15B-EVIDENCE-$stamp.zip"
if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw "Expected exact evidence ZIP was not created: $zipPath" }
$meta = Join-Path $env:TEMP "FIFA15-F15B-V16-EVIDENCE-META-$stamp.txt"
@(
    'FIFA 15 Player B v16 diagnostic evidence manifest',
    "generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    "diag=$resolved",
    'evidence_selection_policy=EXPLICIT_ATTEMPT_PATHS_NO_NEWEST_FILE_HEURISTIC',
    "network_found=$([bool]$network)",
    "network_path=$([string]$(if($network){$network.FullName}else{'<missing>'}))",
    "native_attestation_found=$([bool]$native)",
    "native_attestation_path=$([string]$(if($native){$native.FullName}else{'<missing>'}))"
) | Set-Content -LiteralPath $meta -Encoding UTF8

$extra = @($meta)
if ($network) { $extra += $network.FullName }
if ($native) { $extra += $native.FullName }
foreach ($path in $extra) {
    Compress-Archive -LiteralPath $path -DestinationPath $zipPath -Update -CompressionLevel Optimal
}
Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue

Write-Host "PASS: v16 evidence ZIP includes exact diagnostic plus explicitly bound network/native evidence: $zipPath" -ForegroundColor Green
if (-not $network) { Write-Host 'WARNING: exact-attempt network log was missing; runtime result may be VOID.' -ForegroundColor Yellow }
if (-not $native) { Write-Host 'WARNING: exact-attempt native attestation log was missing; runtime result may be VOID.' -ForegroundColor Yellow }
exit 0
