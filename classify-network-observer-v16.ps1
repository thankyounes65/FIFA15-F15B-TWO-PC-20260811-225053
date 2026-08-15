[CmdletBinding()]
param(
    [string]$LogPath,
    [datetime]$SinceUtc = [datetime]::MinValue,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Get-ObservationCode([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 43 }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() })
    $fifa = $lines -contains 'fifa_observed=true'
    $lsx = $lines -contains 'fifa_lsx_connected=true'
    $blaze = $lines -contains 'fifa_blaze_connected=true'
    if ($lsx -and $blaze) { return 0 }
    if ($fifa -and -not $lsx) { return 41 }
    if ($lsx -and -not $blaze) { return 42 }
    return 43
}

function Resolve-NetworkLog {
    if ($LogPath) { return (Resolve-Path -LiteralPath $LogPath -ErrorAction Stop).Path }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $candidate = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-NETWORK-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($candidate.Count -ne 1) { return $null }
    return $candidate[0].FullName
}

function Invoke-SelfTest {
    $root = Join-Path $env:TEMP ('fifa15-v16-observer-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $cases = @(
            @{ Name='crlf-success'; Bytes=[Text.Encoding]::UTF8.GetBytes("fifa_observed=true`r`nfifa_lsx_connected=true`r`nfifa_blaze_connected=true`r`n"); Want=0 },
            @{ Name='fifa-only'; Bytes=[Text.Encoding]::UTF8.GetBytes("fifa_observed=true`r`nfifa_lsx_connected=false`r`nfifa_blaze_connected=false`r`n"); Want=41 },
            @{ Name='lsx-no-blaze'; Bytes=[Text.Encoding]::UTF8.GetBytes("fifa_observed=true`r`nfifa_lsx_connected=true`r`nfifa_blaze_connected=false`r`n"); Want=42 },
            @{ Name='empty'; Bytes=[byte[]]@(); Want=43 }
        )
        foreach ($case in $cases) {
            $path = Join-Path $root ($case.Name + '.log')
            [IO.File]::WriteAllBytes($path,$case.Bytes)
            $got = Get-ObservationCode $path
            if ($got -ne $case.Want) { throw "$($case.Name): expected $($case.Want), got $got" }
        }
        if ((Get-ObservationCode (Join-Path $root 'missing.log')) -ne 43) { throw 'missing log must classify 43' }
        Write-Host 'PASS: v16 classifier handles CRLF and returns 0/41/42/43 on the intended LSX/Blaze boundaries.' -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
$resolved = Resolve-NetworkLog
if (-not $resolved) {
    Write-Host 'NETWORK_OBSERVER_V16_RESULT=NO_CURRENT_NETWORK_LOG' -ForegroundColor Red
    exit 43
}
$code = Get-ObservationCode $resolved
switch ($code) {
    0  { Write-Host 'NETWORK_OBSERVER_V16_RESULT=LSX_AND_BLAZE_CONFIRMED' -ForegroundColor Green }
    41 { Write-Host 'NETWORK_OBSERVER_V16_RESULT=FIFA_NEVER_CONNECTED_TO_PACKAGE_LSX' -ForegroundColor Red }
    42 { Write-Host 'NETWORK_OBSERVER_V16_RESULT=LSX_OK_BLAZE_NOT_REACHED' -ForegroundColor Red }
    default { Write-Host 'NETWORK_OBSERVER_V16_RESULT=FIFA_OR_NETWORK_BOUNDARY_NOT_OBSERVED' -ForegroundColor Red }
}
Write-Host "NETWORK_OBSERVER_V16_LOG=$resolved" -ForegroundColor Gray
exit $code
