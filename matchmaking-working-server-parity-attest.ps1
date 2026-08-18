[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$Root=Split-Path -Parent $PSCommandPath
$ConfigPath=Join-Path $Root 'APPLIANCE-CONFIG.json'
$PackagePath=Join-Path $Root 'PACKAGE-MANIFEST.json'
$Config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$PackageManifest=Get-Content -LiteralPath $PackagePath -Raw | ConvertFrom-Json
$HostIp=[string]$Config.host_ip
$Port=48216
$Candidate='FIFA15-MM-WORKING-SERVER-LOBBY-ENTRY-V4'
$Package='F15B-MM-WORKING-SERVER-SETUP-BURST-V3'
$ExpectedBranch='integration/test-matchmaking-working-server-setup-burst-v3'
$ExpectedHostBuild='build_pairing_working_server_lobby_entry_v4.rs'
$ExpectedBaseline='8ac9f914685ddf8dc60ca95a21addb674de6716b'

function Assert-LocalState {
    if (-not $HostIp) { throw 'APPLIANCE-CONFIG.json has no host_ip' }

    foreach ($path in @(
        'RUNTIME-TEST.md',
        'RUN-FIFA15-F15B.bat',
        'RUN-FIFA15-F15B-PARITY.ps1',
        'COLLECT-PLAYER-B-EVIDENCE.ps1',
        'diagnostic-run.ps1',
        'guest-network-observer.ps1',
        'VERIFY-PLAYER-B-GAME-FILES.ps1',
        'capture-blaze-traffic.ps1',
        'APPLIANCE-CONFIG.json',
        'PACKAGE-MANIFEST.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf)) {
            throw "Missing Player B prerequisite: $path"
        }
    }

    if ([string]$Config.candidate_id -ne $Candidate) { throw "APPLIANCE-CONFIG candidate mismatch: $($Config.candidate_id)" }
    if ([string]$Config.package_attestation -ne $Package) { throw "APPLIANCE-CONFIG package mismatch: $($Config.package_attestation)" }
    if ([string]$Config.expected_host_branch -ne $ExpectedBranch) { throw "APPLIANCE-CONFIG host branch mismatch: $($Config.expected_host_branch)" }
    if ([string]$Config.expected_host_build -ne $ExpectedHostBuild) { throw "APPLIANCE-CONFIG host build mismatch: $($Config.expected_host_build)" }
    if ([string]$Config.wire_protocol_baseline_commit -ne $ExpectedBaseline) { throw "APPLIANCE-CONFIG baseline mismatch: $($Config.wire_protocol_baseline_commit)" }

    $overlay=$PackageManifest.matchmaking_overlay
    if ([string]$overlay.candidate_id -ne $Candidate) { throw "PACKAGE-MANIFEST candidate mismatch: $($overlay.candidate_id)" }
    if ([string]$overlay.package_attestation -ne $Package) { throw "PACKAGE-MANIFEST package mismatch: $($overlay.package_attestation)" }
    if ([string]$overlay.expected_host_branch -ne $ExpectedBranch) { throw "PACKAGE-MANIFEST host branch mismatch: $($overlay.expected_host_branch)" }
    if ([string]$overlay.expected_host_build -ne $ExpectedHostBuild) { throw "PACKAGE-MANIFEST host build mismatch: $($overlay.expected_host_build)" }
    if ([string]$overlay.wire_protocol_baseline_commit -ne $ExpectedBaseline) { throw "PACKAGE-MANIFEST baseline mismatch: $($overlay.wire_protocol_baseline_commit)" }
    # v3 IS the Lead 4 post-GameSetup burst, so recording it as disabled would be
    # false provenance.
    if (-not [bool]$overlay.lead4_enabled) { throw 'PACKAGE-MANIFEST does not record the Lead 4 burst this candidate tests.' }
    # 0x00C9 is now decoded from the lossless capture, so reproducing it is
    # evidence-backed rather than invention. What must stay true is that the
    # two lifecycle corrections are declared and Player B changes no wire.
    if (-not [bool]$overlay.lead4_00c9_reproduced) { throw 'PACKAGE-MANIFEST no longer reproduces the decoded 0x00C9.' }
    if ([string]$overlay.lead4_scope -ne '4a_0016_joining_msid+4b_00e7_host_only+4b_0064_gsta1+4b_00c9') { throw "PACKAGE-MANIFEST Lead 4 scope mismatch: $($overlay.lead4_scope)" }
    # Lobby entry v4. The HNET arm is the primary change and the one whose
    # regression would break transport, so it is pinned explicitly rather
    # than left to the free-text scope string.
    if ([string]$overlay.lead5_scope -ne 'hnet_arm2_ip_pair_address+0x000c_async_status+0x006e_game_settings_mirror') { throw "PACKAGE-MANIFEST Lead 5 scope mismatch: $($overlay.lead5_scope)" }
    if ([int]$overlay.hnet_network_address_arm -ne 2) { throw "PACKAGE-MANIFEST must declare HNET NetworkAddress arm 2, found: $($overlay.hnet_network_address_arm)" }
    if (-not $overlay.async_status_0x000c_per_client) { throw 'PACKAGE-MANIFEST must declare the per-client 0x000C async status.' }
    if (-not $overlay.game_settings_0x006e_mirrored_to_both) { throw 'PACKAGE-MANIFEST must declare the 0x006E game-settings mirror.' }
    if (-not [string]$overlay.lead5_fifa_division_deliberately_not_sent) { throw 'PACKAGE-MANIFEST must record why fifaDivision is deliberately not sent.' }

    if ([bool]$overlay.gsta130_echo_gated_on_peer_edge) { throw 'PACKAGE-MANIFEST still gates the GSTA=130 echo; the capture shows it ungated.' }
    if ([string]$overlay.promotion_bundle_order -ne 'paired_per_player') { throw "PACKAGE-MANIFEST promotion order mismatch: $($overlay.promotion_bundle_order)" }
    # The capture is explicit that POST /match echoes the requester's own
    # squad; declaring anything else would be false provenance.
    if ([string]$overlay.fut_post_match_returns -ne 'requester_own_squad') { throw "PACKAGE-MANIFEST fut POST /match contract mismatch: $($overlay.fut_post_match_returns)" }
    if ([string]$overlay.fut_opponent_route -notmatch 'squad/active/user') { throw 'PACKAGE-MANIFEST does not declare the captured opponent route.' }
    if ([string]$overlay.gsu_shape -ne 'gid_plus_empty_xnnc_xses_single_send') { throw "PACKAGE-MANIFEST GSU shape mismatch: $($overlay.gsu_shape)" }
    if (-not [bool]$overlay.gsu_second_trigger_retired) { throw 'PACKAGE-MANIFEST does not record the retired second GSU trigger.' }
    if (-not [bool]$overlay.'0x000b_send_retired') { throw 'PACKAGE-MANIFEST does not record the retired 0x000B send.' }
    if ([string]$overlay.player_b_wire_capture -notmatch '42128') { throw 'PACKAGE-MANIFEST does not declare the Player B Blaze wire capture.' }
    if ([bool]$overlay.changes_matchmaking_wire_protocol) { throw 'Player B package must not change matchmaking wire protocol.' }

    $runtimeText=Get-Content -LiteralPath (Join-Path $Root 'RUNTIME-TEST.md') -Raw
    if (-not $runtimeText.Contains('# FIFA15 Player B Working-Server Lobby Entry v4')) {
        throw 'RUNTIME-TEST.md is not the Player B lobby-entry v4 package contract.'
    }
    if (-not $runtimeText.Contains($ExpectedBranch)) {
        throw "RUNTIME-TEST.md does not pin expected branch $ExpectedBranch."
    }
    if (-not $runtimeText.Contains($ExpectedHostBuild)) {
        throw "RUNTIME-TEST.md does not pin expected host build $ExpectedHostBuild."
    }

    $launcherText=Get-Content -LiteralPath (Join-Path $Root 'RUN-FIFA15-F15B.bat') -Raw
    if (-not $launcherText.Contains('RUN-FIFA15-F15B-PARITY.ps1')) {
        throw 'RUN-FIFA15-F15B.bat is not wired to the passive parity-family runner.'
    }
}

Assert-LocalState
if($SelfTest){
    Write-Host "PASS: portable Player B lobby-entry v4 attestation pins package=$Package, host=$HostIp`:$Port, A=$ExpectedBranch/$ExpectedHostBuild, parity baseline=$ExpectedBaseline, Lead 5 scope=$($PackageManifest.matchmaking_overlay.lead5_scope) (GAME.HNET as NetworkAddress arm 2 so the joiner starts its peer flow, 0x000C after each StartMatchmaking ack, 0x0004 answered and mirrored as 0x006E), the whole setup-burst v3 window inherited unchanged, fifaDivision deliberately not fabricated for game mode 81, and a filtered Player B wire capture on 42128." -ForegroundColor Green
    exit 0
}

$client=New-Object Net.Sockets.TcpClient
$async=$null
try {
    $async=$client.BeginConnect($HostIp,$Port,$null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) { throw "Player A PID-promotion gate $HostIp`:$Port timed out" }
    $client.EndConnect($async)
    $client.ReceiveTimeout=5000
    $client.SendTimeout=5000
    $stream=$client.GetStream()
    $hello=[Text.Encoding]::ASCII.GetBytes("HELLO $Candidate $Package")
    $stream.Write($hello,0,$hello.Length)
    $stream.Flush()
    $buffer=New-Object byte[] 256
    $count=$stream.Read($buffer,0,$buffer.Length)
    $ack=[Text.Encoding]::ASCII.GetString($buffer,0,$count).Trim()
    $expected="ACCEPT $Candidate $Package"
    if ($ack -ne $expected) { throw "Player A rejected setup-burst v3 package; got '$ack'" }
    Write-Host 'PASS: Player A accepted the exact Player B setup-burst v3 package.' -ForegroundColor Green
} finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
