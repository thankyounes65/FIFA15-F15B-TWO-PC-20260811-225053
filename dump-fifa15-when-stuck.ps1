<#
.SYNOPSIS
Sit alongside a FIFA 15 session and capture it on demand, while it is stuck.

.DESCRIPTION
Denuvo decrypts `.xtext` **lazily, page by page, only as code executes**. The dumps
taken on 2026-08-15 prove it: their first third is real x86-64 (entropy ~6.4) and
everything past ~50% is still encrypted (entropy 8.00), because the game had never
run those paths. So a capture is only useful if it is taken **while the client is in
the state you care about** - for the joiner stall, that means while Player B is
sitting in the lobby transition that never completes.

That is a moment only the person at the keyboard can identify, which is why this
prompts rather than guesses. It can capture as many times as you like; each press
goes into its own subfolder, so capturing at two different moments is cheap and is
often more informative than one.

ONE PRESS TAKES TWO CAPTURES

  sections\   the decrypted PE sections. This is the code. It works - 33 MB of
              `.xtext` decrypted correctly - and it is why we know what follows.

  memscan\    the live address space. The section dumps contained ZERO readable
              program strings, twice, because FIFA 15 keeps none in any PE
              section: `.data` does not exist, `.rdata` is a 209-byte stub, and
              `.arch` is 97% zeros over the packer's own pointer tables. The
              strings are in memory the PE headers do not describe, so this walks
              it directly. See scan-fifa15-live-memory.ps1.

Both are read-only. Neither is a debugger and neither injects anything; the only
contact with the game is ReadProcessMemory through a 0x1010 handle. See
dump-fifa15-decrypted-sections.ps1 for why that does not trip the anti-debug that
crashes this build under Frida.

.PARAMETER OutDir
Where the captures go. Each press writes a numbered subfolder here.

.PARAMETER Dumper
Path to dump-fifa15-decrypted-sections.ps1.

.PARAMETER Scanner
Path to scan-fifa15-live-memory.ps1.

.PARAMETER SelfTest
Verify wiring without a game or a prompt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$OutDir = '',
    [Parameter(Mandatory = $false)][string]$Dumper = '',
    [Parameter(Mandatory = $false)][string]$Scanner = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSCommandPath
if (-not $Dumper)  { $Dumper  = Join-Path $here 'dump-fifa15-decrypted-sections.ps1' }
if (-not $Scanner) { $Scanner = Join-Path $here 'scan-fifa15-live-memory.ps1' }

if ($SelfTest) {
    foreach ($tool in @($Dumper, $Scanner)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            throw "capture tool not found beside this script: $tool"
        }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dumper -SelfTest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'the section dumper failed its own self-test' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Scanner -SelfTest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'the address-space scanner failed its own self-test' }
    Write-Output 'PASS: on-demand capture is wired to a section dumper AND an address-space scanner, both self-testing, and prompts rather than guessing the moment.'
    exit 0
}

if (-not $OutDir) { $OutDir = Join-Path (Get-Location) 'decrypted-dumps' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host '  FIFA 15 CAPTURE - press ENTER at the moment that matters' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Leave this window open for the whole session.' -ForegroundColor Gray
Write-Host ''
Write-Host 'When the game is STUCK - the lobby that never finishes loading -' -ForegroundColor Yellow
Write-Host 'come back here and press ENTER. Do it WHILE it is still stuck,' -ForegroundColor Yellow
Write-Host 'not after closing the game: the code and the strings we need are' -ForegroundColor Yellow
Write-Host 'only readable once that path has actually run.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Each press takes two captures: the decrypted sections, then a walk' -ForegroundColor Gray
Write-Host 'of the whole address space. The second one takes a minute or two.' -ForegroundColor Gray
Write-Host 'Both are read-only. Leave the game alone while they run.' -ForegroundColor Gray
Write-Host ''
Write-Host 'You can press ENTER more than once. Type Q then ENTER to stop.' -ForegroundColor Gray
Write-Host ''

$index = 0
while ($true) {
    $answer = Read-Host 'Press ENTER to capture now (or Q to finish)'
    if ($answer -and $answer.Trim().ToUpperInvariant().StartsWith('Q')) { break }

    $fifa = Get-Process -Name 'fifa15' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $fifa) {
        Write-Host '  fifa15.exe is not running right now - nothing to read. Start the game first.' -ForegroundColor Yellow
        continue
    }

    $index++
    $target = Join-Path $OutDir ("dump-{0:d2}-{1}" -f $index, (Get-Date -Format 'HHmmss'))
    New-Item -ItemType Directory -Force -Path $target | Out-Null

    # The sections first: it is fast and proven. Then the address-space walk,
    # which is the one that can actually find strings.
    Write-Host "  [1/2] decrypted sections -> $target\sections ..." -ForegroundColor Cyan
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dumper -OutDir (Join-Path $target 'sections')
        if ($LASTEXITCODE -ne 0) { Write-Warning "  section dump exited $LASTEXITCODE" }
    } catch {
        Write-Warning "  section dump failed: $($_.Exception.Message)"
    }

    Write-Host "  [2/2] address-space scan -> $target\memscan (this one takes a while) ..." -ForegroundColor Cyan
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Scanner `
            -ProcessId $fifa.Id -OutDir (Join-Path $target 'memscan')
        if ($LASTEXITCODE -ne 0) { Write-Warning "  address-space scan exited $LASTEXITCODE" }
    } catch {
        Write-Warning "  address-space scan failed: $($_.Exception.Message)"
    }

    Write-Host '  done. You can keep playing; press ENTER again at any other interesting moment.' -ForegroundColor Green
    Write-Host ''
}

Write-Host "Finished. $index capture(s) written to $OutDir" -ForegroundColor Green
exit 0
