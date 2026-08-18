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
$Candidate='FIFA15-MM-WORKING-SERVER-QOS-PACING-PREAUTH-V12'
$Package='F15B-MM-WORKING-SERVER-SETUP-BURST-V3'
$ExpectedBranch='integration/test-matchmaking-working-server-setup-burst-v3'
$ExpectedHostBuild='build_pairing_working_server_qos_pacing_preauth_v12.rs'
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
    # Peer session v5. The document must be declared as being about the
    # PEER; the self-directed 0x0001 has always been sent and closes nothing.
    if ([string]$overlay.lead6_scope -ne 'peer_usersession_extended_data_0x0001+open_nat_type') { throw "PACKAGE-MANIFEST Lead 6 scope mismatch: $($overlay.lead6_scope)" }
    if (-not $overlay.peer_extended_data_0x0001_sent_before_gamesetup) { throw 'PACKAGE-MANIFEST must declare the peer 0x0001 sent before GameSetup.' }
    if ([int]$overlay.peer_published_nat_type -ne 1) { throw "PACKAGE-MANIFEST must declare the open published NAT type, found: $($overlay.peer_published_nat_type)" }
    if ([int]$overlay.peer_observed_nat_type -ne 5) { throw "PACKAGE-MANIFEST must record the observed NAT stub it replaces, found: $($overlay.peer_observed_nat_type)" }
    if (-not $overlay.peer_bandwidth_not_fabricated_from_capture) { throw 'PACKAGE-MANIFEST must record that retail bandwidth is not fabricated.' }
    if (-not [string]$overlay.lead6_hnet_hypothesis_refuted) { throw 'PACKAGE-MANIFEST must record that the v4 HNET hypothesis was refuted.' }
    # Relay topology v6. Both halves of retail's rule must be declared:
    # advertising the relay, and the peer INIP that makes it safe.
    if ([string]$overlay.lead7_scope -ne 'relay_topology+peer_inip_equals_exip') { throw "PACKAGE-MANIFEST Lead 7 scope mismatch: $($overlay.lead7_scope)" }
    if ([string]$overlay.peer_endpoint_mode -ne 'relay_11000_host_11001_guest') { throw "PACKAGE-MANIFEST must declare the relay peer endpoint mode, found: $($overlay.peer_endpoint_mode)" }
    if (-not $overlay.peer_documents_publish_inip_equal_exip) { throw 'PACKAGE-MANIFEST must declare the peer INIP==EXIP rule, without which relay mode was already refuted once.' }
    if (-not $overlay.recipient_own_roster_entry_keeps_private_inip) { throw 'PACKAGE-MANIFEST must declare that the recipient keeps its own private INIP.' }
    if (-not [string]$overlay.lead7_previous_relay_attempt_refuted_because) { throw 'PACKAGE-MANIFEST must record why the earlier relay attempt was refuted.' }
    # Peer QoS v7. The two figures have unequal evidence and the manifest
    # must say so, so a later reader cannot mistake the inference for a fact.
    if ([string]$overlay.lead8_scope -ne 'peer_qos_populated_no_zero_bandwidth_advertisement') { throw "PACKAGE-MANIFEST Lead 8 scope mismatch: $($overlay.lead8_scope)" }
    if ([int]$overlay.peer_qos_upstream_bps -ne 123456789) { throw "PACKAGE-MANIFEST must declare retail's canned upstream constant, found: $($overlay.peer_qos_upstream_bps)" }
    if ([int]$overlay.peer_qos_downstream_bps -le 0) { throw 'PACKAGE-MANIFEST must declare a non-zero published downstream figure.' }
    if ([string]$overlay.peer_qos_downstream_status -notmatch 'inference') { throw 'PACKAGE-MANIFEST must record the downstream figure as an inference, not a measurement.' }
    if (-not $overlay.self_echo_still_reports_client_measured_zero) { throw 'PACKAGE-MANIFEST must record that the self echo is left alone.' }
    if (-not [string]$overlay.lead8_root_cause) { throw 'PACKAGE-MANIFEST must record the real root cause behind the zero bandwidth.' }
    # QoS probe v8. This is the first candidate that can affect the login
    # path, so the manifest must state what moved and why.
    if ([string]$overlay.lead9_scope -ne 'qos_probe_protocol_bandwidth_firewall_firetype_and_udp_probes') { throw "PACKAGE-MANIFEST Lead 9 scope mismatch: $($overlay.lead9_scope)" }
    if (-not $overlay.lead9_firewall_opens_udp_17502) { throw 'PACKAGE-MANIFEST must record that UDP 17502 is opened; without it the probes never arrive and the measurement silently never completes.' }
    if (-not [string]$overlay.lead9_ping_site_now_routable) { throw 'PACKAGE-MANIFEST must record why the ping site moved off loopback.' }
    if ([string]$overlay.lead9_firetype_to_natt_mapping -notmatch 'unresolved') { throw 'PACKAGE-MANIFEST must keep the firetype-to-NATT mapping recorded as unresolved.' }
    # QoS config v9. v8 proved its own routes were never exercised - the gate is
    # the QOSS block itself, one step earlier. The manifest must scope the SVID
    # fix to the profile that actually runs, not claim a blanket rewrite.
    if ([string]$overlay.lead10_scope -ne 'qoss_time_added_universal+qoss_svid_fifa14compat_profile_no_longer_zero') { throw "PACKAGE-MANIFEST Lead 10 scope mismatch: $($overlay.lead10_scope)" }
    if ([int]$overlay.lead10_time_added_ms -ne 5000) { throw "PACKAGE-MANIFEST must declare retail's QOSS.TIME value, found: $($overlay.lead10_time_added_ms)" }
    if ([int]$overlay.lead10_svid_value -ne 1161889797) { throw "PACKAGE-MANIFEST must declare retail's QOSS.SVID value, found: $($overlay.lead10_svid_value)" }
    if (-not $overlay.lead10_svid_fix_scoped_to_running_profile_only) { throw 'PACKAGE-MANIFEST must record that the SVID fix is scoped to the profile that actually runs, not a blanket change.' }
    if (-not [string]$overlay.lead10_corroboration) { throw 'PACKAGE-MANIFEST must record the FIFA14 cross-reference corroboration, distinct from FIFA15 evidence.' }
    # Lead 10 was refuted. Recording it as still-open would be false provenance,
    # and it is exactly the kind of drift that makes a scorecard unreadable.
    if ([string]$overlay.lead10_result -notmatch 'REFUTED') { throw 'PACKAGE-MANIFEST must record that Lead 10 was refuted by run 20260818-144512.' }
    # QoS reply v11. The blocking defect is the reply SHAPE, so the manifest
    # must name it, and must keep the marker's meaning recorded as an inference
    # rather than promoting it to a fact the capture does not support.
    if ([string]$overlay.lead11_scope -ne 'qos_probe_reply_shape_for_every_probe+firetype_wrapper+firewall_declaration+little_endian_qosip+retail_headers') { throw "PACKAGE-MANIFEST Lead 11 scope mismatch: $($overlay.lead11_scope)" }
    if (-not [string]$overlay.lead11_defect_2_type_three_probe_got_bare_echo) { throw 'PACKAGE-MANIFEST must name the bare-echo defect that actually stalled the run.' }
    if ([string]$overlay.lead11_small_probe_marker_status -notmatch 'inference') { throw 'PACKAGE-MANIFEST must keep the small-probe marker recorded as an inference, not a confirmed address.' }
    if (-not [string]$overlay.lead11_validated_by_byte_for_byte_replay) { throw 'PACKAGE-MANIFEST must record that the reply rule is validated against the captured bytes.' }
    if (-not [bool]$overlay.lead11_every_qos_message_now_byte_verified) { throw 'PACKAGE-MANIFEST must record that every QoS message is byte-verified against the capture.' }
    # Lead 11 was a PARTIAL, and the manifest must say so - it is the first
    # forward movement in six candidates and recording it as a plain pass or a
    # plain failure would both be false provenance.
    if ([string]$overlay.lead11_result -notmatch 'PARTIAL') { throw 'PACKAGE-MANIFEST must record Lead 11 as the partial it was.' }
    # QoS bandwidth-ack v12. The acknowledgement is the whole candidate, and
    # the 20-byte echo it must NOT disturb is the part that already works.
    if ([string]$overlay.lead12_scope -ne 'bandwidth_probe_acknowledged_with_index_plus_one_and_little_endian_count') { throw "PACKAGE-MANIFEST Lead 12 scope mismatch: $($overlay.lead12_scope)" }
    if (-not [bool]$overlay.lead12_twenty_byte_probes_still_verbatim_echo) { throw 'PACKAGE-MANIFEST must record that 20-byte probes stay a verbatim echo; that path already works.' }
    if (-not [string]$overlay.lead12_validated_by_captured_bandwidth_replay) { throw 'PACKAGE-MANIFEST must record the captured-bandwidth replay validation.' }
    if (-not [string]$overlay.lead12_capture_pkt_size_defect_fixed) { throw 'PACKAGE-MANIFEST must record the capture truncation defect that hid the bandwidth phase.' }
    # The joiner-only stall must stay recorded as unexplained. Promoting it to
    # a cause would be exactly the kind of co-occurrence claim the method bans.
    if ([string]$overlay.lead12_role_asymmetry_recorded_not_explained -notmatch 'NOT explained') { throw 'PACKAGE-MANIFEST must keep the joiner-only stall recorded as unexplained.' }
    # Lead 12 was a PARTIAL and the marker's meaning graduated from Inference
    # to Confirmed. Both must be recorded or the provenance drifts.
    if ([string]$overlay.lead12_result -notmatch 'PARTIAL') { throw 'PACKAGE-MANIFEST must record Lead 12 as the partial it was.' }
    if ([string]$overlay.lead12_marker_meaning_now_confirmed -notmatch 'Confirmed') { throw 'PACKAGE-MANIFEST must record that the probe marker meaning is now Confirmed.' }
    # QoS pacing + PreAuth v13. Two bundled changes; the manifest must name
    # both discriminators, keep the spacing an inference, and keep CIDS/MAID
    # explicitly out of scope.
    if ([string]$overlay.lead13_scope -ne 'bandwidth_reply_pacing_plus_preauth_field_alignment') { throw "PACKAGE-MANIFEST Lead 13 scope mismatch: $($overlay.lead13_scope)" }
    if (-not [bool]$overlay.lead13_bundled_because_discriminators_cannot_be_confused) { throw 'PACKAGE-MANIFEST must record why two changes were bundled.' }
    if ([string]$overlay.lead13_change_a_spacing_is_inference_and_tunable -notmatch 'control arm') { throw 'PACKAGE-MANIFEST must keep the reply spacing an inference with a control arm.' }
    if (-not [string]$overlay.lead13_cids_and_maid_deliberately_untouched) { throw 'PACKAGE-MANIFEST must record that CIDS and MAID are deliberately out of scope.' }
    # The REQ=2 correction is load-bearing for how future runs are scored.
    if ([string]$overlay.lead13_req2_is_not_server_triggered -notmatch 'NOTHING exchanged') { throw 'PACKAGE-MANIFEST must record that REQ=2 is not server-triggered.' }
    # v7 recorded the upstream figure's mechanism wrongly. The corrected entry
    # must not silently revert to the old claim.
    if ([string]$overlay.peer_qos_upstream_status -notmatch 'handed to the client') { throw 'PACKAGE-MANIFEST must keep the corrected account of where the upstream figure comes from.' }


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
    if (-not $runtimeText.Contains('# FIFA15 Player B Working-Server QoS Pacing + PreAuth v12')) {
        throw 'RUNTIME-TEST.md is not the Player B QoS-pacing-preauth v12 package contract.'
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
    Write-Host "PASS: portable Player B QoS-pacing-preauth v12 attestation pins package=$Package, host=$HostIp`:$Port, A=$ExpectedBranch/$ExpectedHostBuild, parity baseline=$ExpectedBaseline, Lead 13 scope=$($PackageManifest.matchmaking_overlay.lead13_scope) (two bundled changes with non-overlapping discriminators - bandwidth replies paced to reproduce the captured 4.624 ms span so the client can measure a real downstream, and the PreAuth reply aligned on EEFA, ESRC, SVER and two missing CONF keys), Lead 12 recorded as the partial it was, the probe marker meaning now Confirmed as the client observed external address, CIDS and MAID deliberately out of scope, and REQ=2 recorded as not server-triggered." -ForegroundColor Green
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
