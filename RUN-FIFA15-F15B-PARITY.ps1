<#
Player B runner for the working-server QoS probe v8 test.

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
$Capture = Join-Path $Root 'capture-blaze-traffic.ps1'
$ExpectedBranch = 'integration/test-matchmaking-working-server-setup-burst-v3'
$Candidate = 'FIFA15-MM-WORKING-SERVER-QOS-BW-ACK-V11'
$Package = 'F15B-MM-WORKING-SERVER-SETUP-BURST-V3'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$attempt = Join-Path $Root ("runs\matchmaking-working-server-setup-burst-v3\player-b\$stamp")
$manifest = Join-Path $attempt 'RUN-MANIFEST.txt'

$networkActive = $false
$captureActive = $false
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
        'capture-blaze-traffic.ps1',
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
    # Player A's relay log proves what it SENT. Only a capture here shows
    # what arrived and, if FIFA rejects a frame, which frame preceded the RST.
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Capture,'-SelfTest')
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
            throw "Player B QoS-probe v8 runner reintroduced in-process instrumentation: $token"
        }
    }
    if ($source -match "Start-Process\s+-FilePath\s+'python'") {
        throw 'Player B QoS-probe v8 runner reintroduced a Python observer process.'
    }
    # RUN-FIFA15-F15B.bat prints its own hardcoded candidate banner before this
    # script ever runs, and nothing previously checked it against $Candidate.
    # It silently drifted for two whole candidates (v4, v5) with every other
    # self-test still green, because the banner is cosmetic and gates nothing -
    # until an operator reads it and reasonably concludes the wrong candidate
    # is loaded. Checked here so that class of drift fails the self-test.
    $launcherPath = Join-Path $Root 'RUN-FIFA15-F15B.bat'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "Missing Player B launcher: $launcherPath"
    }
    $launcherText = Get-Content -LiteralPath $launcherPath -Raw
    if (-not $launcherText.Contains($Candidate)) {
        throw "RUN-FIFA15-F15B.bat banner does not name the current candidate $Candidate; it will mislead the operator even though every other self-test passes."
    }
    Write-Host "PASS: Player B QoS-bandwidth-ack v11 runner pins $ExpectedBranch / $Candidate / $Package, attaches nothing to fifa15.exe, retains the known-good boot/connect stack, and RUN-FIFA15-F15B.bat's own banner names the current candidate." -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $attempt | Out-Null
@(
    'FIFA15 working-server QoS probe v8 - Player B',
    "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    "branch=$ExpectedBranch",
    "candidate_id=$Candidate",
    "package_attestation=$Package",
    'package_mode=portable-extracted-folder',
    'requires_git_checkout=false',
    'native_instrumentation=none',
    'frida_used=false',
    'wire_change=true_on_player_a_only',
    'player_a_wire_scope=post_gamesetup_burst_00e7_0016_peer_msid_0064_gsta1_00c9+ungated_gsta130_echo+paired_promotion',
    'leads_1_3_inherited_unchanged=true',
    'lead4_enabled=true',
    'lead4_scope=4a_0016_peer_msid+4b_00e7+4b_0064_gsta1+4b_00c9',
    'lead4_00c9_reproduced=true',
    'lead4_00c9_basis=decoded_from_lossless_capture_empty_lists',
    'gsta130_echo_gated_on_peer_edge=false',
    'promotion_bundle_order=paired_per_player',
    'fut_post_match_returns=requester_own_squad',
    'fut_opponent_route=squad/active/user/<peer persona>',
    'gsu_shape=gid_plus_empty_xnnc_xses_single_send',
    'gsu_second_trigger_retired=true',
    '0x000b_send_retired=true',
    'scenario_selection=false',
    'progress_measured_from=player_a_relay_log_and_trace',
    'player_b_wire_capture=filtered_pktmon_full_packets',
    'player_b_wire_capture_blaze_port=42128',
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

    $stage = 'wire_capture_start'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Capture,'-Start')
    $captureActive = $true

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
    if ($captureActive) {
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Capture -Stop -OutDir $attempt } catch { Write-Warning $_ }
    }
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
