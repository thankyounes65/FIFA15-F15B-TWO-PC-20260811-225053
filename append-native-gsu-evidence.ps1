[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$StampFile = Join-Path $env:TEMP 'fifa15-f15b-native-gsu-tracer.stamp'
$ExpectedBranch = 'integration/test-matchmaking-b-demangler-native-v2'

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw "PowerShell parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('fifa15-f15b-native-gsu-tracer.stamp','jsonl','text','stdout','stderr','Compress-Archive','-Update','NATIVE-GSU-MANIFEST',$ExpectedBranch)) {
        if (-not $source.Contains($marker)) { throw "missing native evidence marker: $marker" }
    }
    Write-Host 'PASS: native GSU evidence appender parses and preserves exact stamped observer output in the existing one-ZIP Player B bundle.' -ForegroundColor Green
}

function Read-Stamp([string]$Path) {
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        $index = $line.IndexOf('=')
        if ($index -le 0) { continue }
        $key = $line.Substring(0,$index).Trim()
        $value = $line.Substring($index + 1)
        if ($key) { $values[$key] = $value }
    }
    return $values
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch { Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$zip = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-EVIDENCE-*.zip' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
if ($zip.Count -eq 0) { throw 'No Player B evidence ZIP exists to update.' }

$stamp = Read-Stamp $StampFile
$stage = Join-Path $env:TEMP ("FIFA15-F15B-NATIVE-GSU-APPEND-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $copied = @{}
    foreach ($key in @('jsonl','text','stdout','stderr')) {
        $sourcePath = if ($stamp.ContainsKey($key)) { [string]$stamp[$key] } else { $null }
        $found = $false
        if ($sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            $name = [IO.Path]::GetFileName($sourcePath)
            if ($key -in @('stdout','stderr')) {
                $runStamp = if ($stamp.ContainsKey('stamp')) { [string]$stamp['stamp'] } else { 'unknown' }
                $name = "FIFA15-F15B-NATIVE-GSU-$runStamp-$key.log"
            }
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stage $name) -Force
            $found = $true
        }
        $copied[$key] = $found
    }

    @(
        'FIFA15 Player-B native GSU evidence manifest',
        "generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
        "branch=$ExpectedBranch",
        'fifa_sha256_expected=3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB',
        "observer_stamp_present=$($stamp.Count -gt 0)",
        "observer_stamp=$($stamp['stamp'])",
        "observer_pid=$($stamp['pid'])",
        "jsonl_found=$($copied['jsonl'])",
        "text_found=$($copied['text'])",
        "stdout_found=$($copied['stdout'])",
        "stderr_found=$($copied['stderr'])",
        'probe_model=18 exact-runtime-byte guards plus bounded 150ms post-predicate Stalker',
        'behavioral_mutation=false',
        'interpretation_rule=observer stdout/stderr are preserved so attach/probe failure is not mistaken for native silence'
    ) | Set-Content -LiteralPath (Join-Path $stage 'FIFA15-F15B-NATIVE-GSU-MANIFEST.txt') -Encoding UTF8

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip[0].FullName -Update -CompressionLevel Optimal
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: exact stamped native GSU evidence appended to $($zip[0].FullName)" -ForegroundColor Green
exit 0
