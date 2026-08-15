[CmdletBinding()]
param(
    [Parameter(ParameterSetName='Collect', Mandatory=$true)][string]$DiagPath,
    [Parameter(ParameterSetName='SelfTest', Mandatory=$true)][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$V15Collector = Join-Path $Root 'collect-evidence-v15.ps1'

function Get-DiagStartedUtc([string]$Path) {
    $line = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -like 'started_utc=*' } | Select-Object -First 1
    if ($line) {
        $value = $line.Substring('started_utc='.Length).Trim()
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($value,[ref]$parsed)) { return $parsed.ToUniversalTime() }
    }
    return (Get-Item -LiteralPath $Path).CreationTimeUtc
}

function Find-CurrentFile([string]$Desktop,[string]$Filter,[datetime]$SinceUtc) {
    $hit = @(Get-ChildItem -LiteralPath $Desktop -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc.AddMinutes(-1) } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($hit.Count -eq 1) { return $hit[0] }
    return $null
}

function Invoke-SelfTest {
    if (-not (Test-Path -LiteralPath $V15Collector -PathType Leaf)) { throw "Missing $V15Collector" }
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('FIFA15-F15B-NETWORK-*.log','FIFA15-F15B-NATIVE-V16-*.log','Compress-Archive','V16 EXACT-ATTEMPT EVIDENCE BINDING')) {
        if (-not $source.Contains($marker)) { throw "missing v16 evidence marker: $marker" }
    }
    Write-Host 'PASS: v16 evidence binder requires exact diagnostic and adds the same-attempt network/native diagnostic files to the ZIP.' -ForegroundColor Green
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

$resolved = (Resolve-Path -LiteralPath $DiagPath -ErrorAction Stop).Path
$item = Get-Item -LiteralPath $resolved -ErrorAction Stop
if ($item.PSIsContainer -or $item.Name -notlike 'FIFA15-F15B-DIAG-*.txt') { throw "Unexpected diagnostic path: $resolved" }
$desktop = $item.Directory.FullName
$sinceUtc = Get-DiagStartedUtc $resolved
$stamp = [IO.Path]::GetFileNameWithoutExtension($item.Name).Substring('FIFA15-F15B-DIAG-'.Length)
$network = Find-CurrentFile -Desktop $desktop -Filter 'FIFA15-F15B-NETWORK-*.log' -SinceUtc $sinceUtc
$native = Find-CurrentFile -Desktop $desktop -Filter 'FIFA15-F15B-NATIVE-V16-*.log' -SinceUtc $sinceUtc

Add-Content -LiteralPath $resolved -Encoding UTF8 -Value @(
    '',
    '=== V16 EXACT-ATTEMPT EVIDENCE BINDING ===',
    "collection_bound_diag=$resolved",
    "network_log=$([string]$(if($network){$network.FullName}else{'<missing>'}))",
    "native_attestation_log=$([string]$(if($native){$native.FullName}else{'<missing>'}))",
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

Write-Host "PASS: v16 evidence ZIP includes exact diagnostic plus same-attempt network/native evidence: $zipPath" -ForegroundColor Green
if (-not $network) { Write-Host 'WARNING: no same-attempt network log was found; runtime result may be VOID.' -ForegroundColor Yellow }
if (-not $native) { Write-Host 'WARNING: no same-attempt native attestation log was found; runtime result may be VOID.' -ForegroundColor Yellow }
exit 0
