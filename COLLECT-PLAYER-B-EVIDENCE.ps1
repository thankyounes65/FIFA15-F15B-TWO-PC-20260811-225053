<#
Collect every Player B artifact from the last run into one ZIP on the Desktop.

Written because run 20260817 lost Player B entirely: FIFA appeared to crash and
the operator could not find any evidence. This never requires Git, never needs
the run to have succeeded, and never deletes anything.

It gathers, if present:
  - EVERY per-attempt evidence folder under runs\<any-experiment>\player-b.
    This is deliberately not a hardcoded experiment name: each candidate writes
    its RUN-MANIFEST.txt under its own runs\<experiment>\player-b\<stamp>\ path,
    and the previous hardcoded runs\matchmaking-native-observer\player-b lookup
    silently shipped a ZIP with no attempt manifest in it whenever the current
    candidate had a different name.
  - the network observer / forwarder / diagnostic logs this package writes to the Desktop
  - fifa15.exe crash dumps from the per-user CrashDumps folder
  - Windows Error Reporting records that name fifa15.exe
  - a short environment summary

Usage (as Administrator, from the extracted Player B package folder):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\COLLECT-PLAYER-B-EVIDENCE.ps1

-EnableCrashDumps additionally turns on Windows LocalDumps for fifa15.exe so a
FUTURE crash produces a full dump. It does not affect the current run.
#>
[CmdletBinding()]
param(
    [switch]$EnableCrashDumps,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$Desktop = [Environment]::GetFolderPath('Desktop')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$staging = Join-Path $env:TEMP "FIFA15-F15B-COLLECT-$stamp"
$zip = Join-Path $Desktop "FIFA15-F15B-EVIDENCE-$stamp.zip"

function Note([string]$m) { Write-Host "  $m" -ForegroundColor Gray }
function Head([string]$m) { Write-Host $m -ForegroundColor Cyan }

function Copy-Into([string]$Source, [string]$SubDir) {
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    $dest = Join-Path $staging $SubDir
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    try {
        Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        Note "could not copy $Source : $($_.Exception.Message)"
        return $false
    }
}

if ($SelfTest) {
    $selfText = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('matchmaking-native-observer', 'CrashDumps', 'ReportArchive', 'Compress-Archive')) {
        if (-not $selfText.Contains($marker)) {
            throw "collector lost marker: $marker"
        }
    }
    # Fail closed if the attempt scan is ever narrowed back to one hardcoded
    # experiment name. That regression shipped ZIPs with no RUN-MANIFEST.txt.
    foreach ($required in @(
        "`$runsRoot = Join-Path `$Root 'runs'",
        "Join-Path `$_.FullName 'player-b'",
        "`$found['player_b_attempt_folders'] = `$attempts.Count"
    )) {
        if (-not $selfText.Contains($required)) {
            throw "collector no longer scans every runs\<experiment>\player-b folder: $required"
        }
    }
    if ($selfText.Contains("Join-Path `$Root 'runs\matchmaking-native-observer\player-b'")) {
        throw 'collector reintroduced the hardcoded single-experiment evidence path.'
    }
    Write-Host 'PASS: Player B evidence collector parses, needs no Git, and searches every runs\<experiment>\player-b attempt folder, Desktop logs, crash dumps and WER records.' -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $staging | Out-Null
$found = [ordered]@{}

Head 'FIFA 15 Player B - evidence collection'
Note "package root: $Root"

# 1. Per-attempt evidence produced by the run itself, for EVERY experiment name.
# Never hardcode one experiment folder here: the runner writes its
# RUN-MANIFEST.txt under runs\<experiment>\player-b\<stamp>\, and a stale name
# produced a ZIP with no attempt manifest at all. matchmaking-native-observer is
# named only so this comment records the path that used to be hardcoded.
$runsRoot = Join-Path $Root 'runs'
$attempts = @()
if (Test-Path -LiteralPath $runsRoot -PathType Container) {
    $attempts = @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'player-b' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue } |
        Sort-Object Name)
}
if ($attempts.Count -gt 0) {
    Note "player-b attempt folders found: $($attempts.Count)"
    foreach ($a in $attempts) {
        # Keep the experiment name in the ZIP so two candidates never collide.
        $experiment = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $a.FullName))
        [void](Copy-Into $a.FullName (Join-Path 'attempts' $experiment))
        Note "  $experiment\$($a.Name)  files=$(@(Get-ChildItem -LiteralPath $a.FullName -File).Count)"
    }
} else {
    Note 'no runs\<experiment>\player-b folder - the run may have failed before the manifest was written'
}
$found['player_b_attempt_folders'] = $attempts.Count

# 2. Desktop logs this package writes.
$deskLogs = @(Get-ChildItem -LiteralPath $Desktop -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'FIFA15-F15B-*' -and $_.Extension -in @('.log', '.txt') })
foreach ($f in $deskLogs) { [void](Copy-Into $f.FullName 'desktop-logs') }
Note "desktop logs collected: $($deskLogs.Count)"
$found['desktop_logs'] = $deskLogs.Count

# 3. Crash dumps for fifa15.exe.
$dumpDirs = @(
    (Join-Path $env:LOCALAPPDATA 'CrashDumps'),
    (Join-Path $env:USERPROFILE 'AppData\Local\CrashDumps')
) | Select-Object -Unique
$dumps = @()
foreach ($d in $dumpDirs) {
    if (Test-Path -LiteralPath $d) {
        $dumps += @(Get-ChildItem -LiteralPath $d -File -Filter 'fifa15*.dmp' -ErrorAction SilentlyContinue)
    }
}
$dumps = @($dumps | Sort-Object LastWriteTimeUtc -Descending)
$found['crash_dumps'] = $dumps.Count
if ($dumps.Count -gt 0) {
    Note "crash dumps found: $($dumps.Count)"
    # Dumps are multi-GB. Record them, and copy only if small enough to move.
    $manifest = foreach ($d in $dumps) {
        "{0}|bytes={1}|modified_utc={2}" -f $d.FullName, $d.Length, $d.LastWriteTimeUtc.ToString('o')
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $staging 'crash') | Out-Null
    Set-Content -LiteralPath (Join-Path $staging 'crash\CRASH-DUMPS-FOUND.txt') -Encoding UTF8 -Value $manifest
    foreach ($d in $dumps | Select-Object -First 1) {
        if ($d.Length -lt 300MB) {
            Note "  copying $($d.Name) ($([math]::Round($d.Length/1MB)) MB)"
            [void](Copy-Into $d.FullName 'crash')
        } else {
            Note "  $($d.Name) is $([math]::Round($d.Length/1MB)) MB - NOT copied, path recorded instead"
        }
    }
} else {
    Note 'no fifa15 crash dump found (LocalDumps is probably not enabled on this machine)'
}

# 4. Windows Error Reporting records naming fifa15.
$werRoots = @(
    'C:\ProgramData\Microsoft\Windows\WER\ReportArchive',
    'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')
)
$werCount = 0
foreach ($wr in $werRoots) {
    if (-not (Test-Path -LiteralPath $wr)) { continue }
    $cand = @(Get-ChildItem -LiteralPath $wr -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*fifa15*' -or $_.Name -like '*FIFA*' } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 10)
    foreach ($c in $cand) {
        if (Copy-Into $c.FullName 'wer') { $werCount++ }
    }
}
Note "WER report folders collected: $werCount"
$found['wer_reports'] = $werCount

# 5. Recent application-error events for fifa15.
try {
    $events = Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000, 1001; StartTime = (Get-Date).AddDays(-2) } -ErrorAction Stop |
        Where-Object { $_.Message -like '*fifa15*' } | Select-Object -First 20
    if ($events) {
        $lines = foreach ($e in $events) { "--- $($e.TimeCreated.ToUniversalTime().ToString('o')) id=$($e.Id)`n$($e.Message)" }
        Set-Content -LiteralPath (Join-Path $staging 'application-error-events.txt') -Encoding UTF8 -Value $lines
        Note "application error events captured: $($events.Count)"
        $found['app_error_events'] = $events.Count
    } else {
        Note 'no fifa15 application error events in the last 2 days'
        $found['app_error_events'] = 0
    }
} catch {
    Note "could not read the Application event log: $($_.Exception.Message)"
    $found['app_error_events'] = 'unavailable'
}

# 6. Environment summary.
$summary = @(
    "collected_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    "computer=$env:COMPUTERNAME",
    "user=$env:USERNAME",
    "package_root=$Root",
    "localdumps_enabled=$(if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\fifa15.exe') { 'yes' } else { 'no' })"
)
foreach ($k in $found.Keys) { $summary += "$k=$($found[$k])" }
Set-Content -LiteralPath (Join-Path $staging 'COLLECTION-SUMMARY.txt') -Encoding UTF8 -Value $summary

# 7. Zip it.
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Head '===================================================================='
Head '  PLAYER B EVIDENCE COLLECTED'
Head '===================================================================='
Write-Host "  $zip" -ForegroundColor Green
foreach ($k in $found.Keys) { Note "$k = $($found[$k])" }

if ($EnableCrashDumps) {
    Write-Host ''
    Head 'Enabling Windows LocalDumps for fifa15.exe (affects FUTURE crashes only)'
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\fifa15.exe'
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DumpFolder' -Value "$env:USERPROFILE\AppData\Local\CrashDumps" -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DumpCount' -Value 5 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DumpType' -Value 2 -PropertyType DWord -Force | Out-Null
    Note 'LocalDumps enabled: full dumps, up to 5 kept, in %USERPROFILE%\AppData\Local\CrashDumps'
} else {
    Write-Host ''
    Note 'If no crash dump was found, re-run once with -EnableCrashDumps so the NEXT crash is captured.'
}
