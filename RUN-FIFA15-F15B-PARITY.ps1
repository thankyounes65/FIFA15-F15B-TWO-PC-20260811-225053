<#
Player B runner for the working-server setup burst v3 test.

No Frida or other in-process instrumentation is attached to fifa15.exe. Player B
keeps the already-proven boot/connect stack unchanged. This branch changes only
candidate/package provenance so Player A's post-GameSetup notification burst is
the sole runtime protocol variable. Leads 1-3 were Confirmed by run
20260817-064947 and are inherited unchanged on the Player A side.
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
$Collect = Join-Path $Root 'COLLECT-PLAYER-B-EVIDENCE.ps1'
$ExpectedBranch = 'integration/test-matchmaking-working-server-setup-burst-v3'
$Candidate = 'FIFA15-MM-WORKING-SERVER-SETUP-BURST-V3'
$Package = 'F15B-MM-WORKING-SERVER-SETUP-BURST-V3'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$attempt = Join-Path $Root ("runs\matchmaking-working-server-setup-burst-v3\player-b\$stamp")
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
        'RUNTIME-TEST.md',
        'APPLIANCE-CONFIG.json',
        'PACKAGE-MANIFEST.json'
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
    # The collector is the only thing that returns this run to Player A. A
    # regression there is invisible until the ZIP arrives without the attempt
    # manifest, so prove it here rather than after the run.
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Collect,'-SelfTest')
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    $banned = @(
        ('fri' + 'da=='),
        ('pip' + ' install'),
        ('PYTHON' + 'PATH'),
        ('.observer' + '-deps'),
        ('Interceptor' + '.attach'),
        ('Stalker' + '.follow')
    )
    foreach ($token in $banned) {
        if ($source.Contains($token)) {
            throw "Player B v3 runner reintroduced in-process instrumentation: $token"
        }
    }
    if ($source -match "Start-Process\s+-FilePath\s+'python'") {
        throw 'Player B v3 runner reintroduced a Python observer process.'
    }
    Write-Host "PASS: Player B v3 runner pins $ExpectedBranch / $Candidate / $Package, attaches nothing to fifa15.exe, and retains the known-good boot/connect stack." -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $attempt | Out-Null
@(
    'FIFA15 working-server setup burst v3 - Player B',
    "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    "branch=$ExpectedBranch",
    "candidate_id=$Candidate",
    "package_attestation=$Package",
    'package_mode=portable-extracted-folder',
    'requires_git_checkout=false',
    'native_instrumentation=none',
    'frida_used=false',
    'wire_change=true_on_player_a_only',
    'player_a_wire_scope=post_gamesetup_burst_00e7_then_0016_peer_msid_then_0064_gsta1',
    'leads_1_3_inherited_unchanged=true',
    'lead4_enabled=true',
    'lead4_scope=4a_0016_peer_msid+4b_00e7+4b_0064_gsta1',
    'lead4_00c9_reproduced=false',
    'scenario_selection=false',
    'progress_measured_from=player_a_relay_log_and_trace',
    'reference=docs/MATCHMAKING-WORKING-SERVER-SETUP-BURST-V3.md'
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
        "package_runner_sha256=$(Get-Sha256OrUnavailable $PSCommandPath)",
        "package_manifest_sha256=$(Get-Sha256OrUnavailable (Join-Path $Root 'PACKAGE-MANIFEST.json'))",
        "appliance_config_sha256=$(Get-Sha256OrUnavailable (Join-Path $Root 'APPLIANCE-CONFIG.json'))"
    )
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'COLLECT-PLAYER-B-EVIDENCE.ps1')
    } catch { Write-Warning "evidence collection failed: $($_.Exception.Message)" }
}

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host '  PLAYER B SETUP-BURST V3 RUN FINISHED' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host "Manifest: $attempt" -ForegroundColor Green
Write-Host 'Nothing was attached to fifa15.exe. Progress is scored from Player A relay/trace evidence.' -ForegroundColor Gray
exit $rc
