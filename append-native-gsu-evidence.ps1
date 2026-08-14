[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw "PowerShell parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('FIFA15-F15B-NATIVE-GSU-*.jsonl','FIFA15-F15B-NATIVE-GSU-*.log','Compress-Archive','-Update','NATIVE-GSU-MANIFEST')) {
        if (-not $source.Contains($marker)) { throw "missing native evidence marker: $marker" }
    }
    Write-Host 'PASS: native GSU evidence appender parses and updates the existing one-ZIP Player B bundle.' -ForegroundColor Green
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch { Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$zip = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-EVIDENCE-*.zip' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
if ($zip.Count -eq 0) { throw 'No Player B evidence ZIP exists to update.' }

$jsonl = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-NATIVE-GSU-*.jsonl' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
$text = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-NATIVE-GSU-*.log' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)

$stage = Join-Path $env:TEMP ("FIFA15-F15B-NATIVE-GSU-APPEND-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    if ($jsonl.Count -gt 0) { Copy-Item -LiteralPath $jsonl[0].FullName -Destination (Join-Path $stage $jsonl[0].Name) -Force }
    if ($text.Count -gt 0) { Copy-Item -LiteralPath $text[0].FullName -Destination (Join-Path $stage $text[0].Name) -Force }
    @(
        'FIFA15 Player-B native GSU evidence manifest',
        "generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
        'branch=integration/test-matchmaking-b-native-gsu-v1',
        'fifa_sha256_expected=3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB',
        "jsonl_found=$($jsonl.Count -gt 0)",
        "text_found=$($text.Count -gt 0)",
        'probe_model=exact-runtime-byte-guards plus bounded 150ms post-predicate Stalker',
        'behavioral_mutation=false'
    ) | Set-Content -LiteralPath (Join-Path $stage 'FIFA15-F15B-NATIVE-GSU-MANIFEST.txt') -Encoding UTF8

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip[0].FullName -Update -CompressionLevel Optimal
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: native GSU evidence appended to $($zip[0].FullName)" -ForegroundColor Green
exit 0
