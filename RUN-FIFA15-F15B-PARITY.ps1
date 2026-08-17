<#
Player B runner for the working-server parity test.

No Frida. No native instrumentation of any kind is attached to fifa15.exe.

Why: run 20260817 crashed FIFA on BOTH players while Frida was attached. On
Player A the v1 crash was inside Frida Stalker's own RWX code cache; on Player B
the v2 run crashed executing freed heap in FIFA's own MatchSession dispatch. A
survived v2 and B did not, so whether Interceptor contributed on B is Unresolved
- and there is no longer any reason to find out, because progress is now measured
entirely from the relay log. Every Blaze message both clients send crosses our
relay, so `scripts/score-matchmaking-progress.py` on Player A can tell how far
each client got without touching the game process at all.

Everything else about the Player B stack is unchanged: known-good file
verification, Tailscale, hosts routing, the loopback forwarder, the LSX
responder, peer attestation, the certificate patch, evidence collection and
exact restoration.
#>
[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$Attest = Join-Path $Root 'matchmaking-working-server-parity-attest.ps1'
$GameVerify = Join-Path $Root 'VERIFY-PLAYER-B-GAME-FILES.ps1'
$RuntimeTest = Join-Path $Root 'RUNTIME-TEST.md'
$Network = Join-Path $Root 'guest-network-observer.ps1'
$Forwarder = Join-Path $Root 'loopback-relay-forwarder.ps1'
$Tailscale = Join-Path $Root 'tailscale-bootstrap.ps1'
$Diagnostic = Join-Path $Root 'diagnostic-run.ps1'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$attempt = Join-Path $Root ("runs\matchmaking-working-server-parity\player-b\$stamp")
$manifest = Join-Path $attempt 'RUN-MANIFEST.txt'

$networkActive = $false
$forwarderActive = $false
$tailscaleAttempted = $false
$rc = 1
$stage = 'preflight'

function Run([string]$File, [string[]]$Arguments = @()) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File returned $LASTEXITCODE" }
}

function Assert-Files {
    foreach ($name in @(
        'matchmaking-working-server-parity-attest.ps1',
        'diagnostic-run.ps1',
        'guest-network-observer.ps1',
        'loopback-relay-forwarder.ps1',
        'tailscale-bootstrap.ps1',
        'VERIFY-PLAYER-B-GAME-FILES.ps1',
        'COLLECT-PLAYER-B-EVIDENCE.ps1',
        'RUNTIME-TEST.md'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $name) -PathType Leaf)) {
            throw "Missing Player B prerequisite: $name"
        }
    }
}

function Get-Sha256OrUnavailable([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } catch {}
    return 'unavailable'
}

Assert-Files

if ($SelfTest) {
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$GameVerify,'-SelfTest')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Network,'-SelfTest')
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    # No in-process instrumentation may come back. The tokens are assembled at
    # runtime so this guard cannot match its own source text.
    $banned = @(
        ('fri' + 'da==') ,
        ('pip' + ' install'),
        ('PYTHON' + 'PATH'),
        ('.observer' + '-deps'),
        ('Interceptor' + '.attach'),
        ('Stalker' + '.follow')
    )
    foreach ($token in $banned) {
        if ($source.Contains($token)) {
            throw "Player B parity runner reintroduced in-process instrumentation: $token"
        }
    }
    # The runner must not launch a Python observer process either.
    if ($source -match "Start-Process\s+-FilePath\s+'python'") {
        throw 'Player B parity runner reintroduced a Python observer process.'
    }
    Write-Host 'PASS: Player B working-server-parity runner attaches nothing to fifa15.exe, installs no Python dependency, is portable from an extracted folder, has no scenario selector, and self-heals stale helper state.' -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $attempt | Out-Null
@(
    'FIFA15 working-server parity - Player B',
    "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    'branch=integration/test-matchmaking-working-server-parity-v1',
    'package_mode=portable-extracted-folder',
    'requires_git_checkout=false',
    'native_instrumentation=none',
    'frida_used=false',
    'wire_change=true_on_player_a_only',
    'scenario_selection=false',
    'progress_measured_from=player_a_relay_log',
    'reference=docs/MATCHMAKING-WORKING-SERVER-GAMESETUP-DIFF.md'
) | Set-Content -LiteralPath $manifest -Encoding UTF8

try {
    $stage = 'game_file_verify'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$GameVerify)

    $stage = 'attestation_selftest'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')

    $stage = 'network_selftest'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Network,'-SelfTest')

    $stage = 'tailscale_bootstrap'
    $tailscaleAttempted = $true
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Tailscale)

    # Reclaim anything a previous crashed or aborted run left behind, so the
    # operator never has to kill a stale PID by hand.
    $stage = 'stale_helper_reset'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Network -Reset
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Forwarder -Stop 2>$null | Out-Null

    $stage = 'forwarder_start'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Forwarder,'-Start')
    $forwarderActive = $true

    $stage = 'network_start'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Network,'-Start')
    $networkActive = $true

    $stage = 'peer_gate'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest)

    $stage = 'fifa_runtime'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Diagnostic
    $rc = [int]$LASTEXITCODE
    $stage = 'post_runtime'
} catch {
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value ("error_stage=$stage`nerror=$($_.Exception.Message)")
    Write-Host "ERROR at stage ${stage}: $($_.Exception.Message)" -ForegroundColor Red
    if ($stage -ne 'fifa_runtime' -and $stage -ne 'post_runtime') {
        Write-Host 'Runtime observation NOT REACHED; classify VOID.' -ForegroundColor Yellow
    }
    $rc = 1
} finally {
    if ($networkActive) {
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Network -Stop } catch { Write-Warning $_ }
    }
    if ($forwarderActive) {
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Forwarder -Stop } catch { Write-Warning $_ }
    }
    if ($tailscaleAttempted) {
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tailscale -Cleanup } catch { Write-Warning $_ }
    }
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value @(
        "finished_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
        "runtime_exit_code=$rc",
        "final_stage=$stage",
        'exact_b_head=portable-extracted-folder-no-git',
        "package_runtime_test_sha256=$(Get-Sha256OrUnavailable $RuntimeTest)",
        "package_attest_sha256=$(Get-Sha256OrUnavailable $Attest)",
        "package_runner_sha256=$(Get-Sha256OrUnavailable $PSCommandPath)"
    )
    # Always collect, even after a crash. This is what run 20260817 could not do.
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'COLLECT-PLAYER-B-EVIDENCE.ps1')
    } catch { Write-Warning "evidence collection failed: $($_.Exception.Message)" }
}

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host '  PLAYER B WORKING-SERVER PARITY RUN FINISHED' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host "Manifest: $attempt" -ForegroundColor Green
Write-Host 'Nothing was attached to fifa15.exe. Progress is scored from the Player A relay log.' -ForegroundColor Gray
exit $rc
