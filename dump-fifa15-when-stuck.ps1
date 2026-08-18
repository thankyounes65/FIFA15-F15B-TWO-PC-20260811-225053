<#
.SYNOPSIS
Sit alongside a FIFA 15 session and dump the decrypted code on demand.

.DESCRIPTION
Denuvo decrypts `.xtext` **lazily, page by page, only as code executes**. The dumps
taken on 2026-08-15 prove it: their first third is real x86-64 (entropy ~6.4) and
everything past ~50% is still encrypted (entropy 8.00), because the game had never
run those paths. So a dump is only useful if it is taken **while the client is in
the state you care about** - for the joiner stall, that means while Player B is
sitting in the lobby transition that never completes.

That is a moment only the person at the keyboard can identify, which is why this
prompts rather than guesses. It can dump as many times as you like; each dump goes
into its own subfolder, so dumping at two different moments is cheap and is often
more informative than one.

This never writes to the game. See dump-fifa15-decrypted-sections.ps1 for why
ReadProcessMemory is not a debugger and does not trip the anti-debug that crashes
this build under Frida.

.PARAMETER OutDir
Where the dumps go. Each press writes a numbered subfolder here.

.PARAMETER Dumper
Path to dump-fifa15-decrypted-sections.ps1.

.PARAMETER SelfTest
Verify wiring without a game or a prompt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$OutDir = '',
    [Parameter(Mandatory = $false)][string]$Dumper = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

if (-not $Dumper) {
    $Dumper = Join-Path (Split-Path -Parent $PSCommandPath) 'dump-fifa15-decrypted-sections.ps1'
}

if ($SelfTest) {
    if (-not (Test-Path -LiteralPath $Dumper -PathType Leaf)) {
        throw "dumper not found beside this script: $Dumper"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dumper -SelfTest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'the underlying dumper failed its own self-test' }
    Write-Output 'PASS: on-demand dumper is wired to a dumper that self-tests, and prompts rather than guessing the moment.'
    exit 0
}

if (-not $OutDir) { $OutDir = Join-Path (Get-Location) 'decrypted-dumps' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host '  DECRYPTED-CODE DUMP - press ENTER at the moment that matters' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Leave this window open for the whole session.' -ForegroundColor Gray
Write-Host ''
Write-Host 'When the game is STUCK - the lobby that never finishes loading -' -ForegroundColor Yellow
Write-Host 'come back here and press ENTER. Do it WHILE it is still stuck,' -ForegroundColor Yellow
Write-Host 'not after closing the game: the code we need is only readable' -ForegroundColor Yellow
Write-Host 'once it has actually run.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'You can press ENTER more than once. Type Q then ENTER to stop.' -ForegroundColor Gray
Write-Host ''

$index = 0
while ($true) {
    $answer = Read-Host 'Press ENTER to dump now (or Q to finish)'
    if ($answer -and $answer.Trim().ToUpperInvariant().StartsWith('Q')) { break }

    $fifa = Get-Process -Name 'fifa15' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $fifa) {
        Write-Host '  fifa15.exe is not running right now - nothing to read. Start the game first.' -ForegroundColor Yellow
        continue
    }

    $index++
    $target = Join-Path $OutDir ("dump-{0:d2}-{1}" -f $index, (Get-Date -Format 'HHmmss'))
    Write-Host "  dumping to $target ..." -ForegroundColor Cyan
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dumper -OutDir $target
        Write-Host '  done. You can keep playing; press ENTER again at any other interesting moment.' -ForegroundColor Green
    } catch {
        Write-Warning "  dump failed: $($_.Exception.Message)"
    }
    Write-Host ''
}

Write-Host "Finished. $index dump(s) written to $OutDir" -ForegroundColor Green
exit 0
