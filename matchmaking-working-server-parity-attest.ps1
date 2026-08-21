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
$Candidate='FIFA15-MM-QOS-STATE-PARITY-V1'
$Package='F15B-MM-QOS-STATE-PARITY-V1'
$ExpectedBranch='integration/test-matchmaking-qos-state-parity-v1'
$ExpectedHostBuild='build_pairing_working_server_qos_state_parity_v15b.rs'
$ExpectedBaseline='77e527180a6cf3810e5eafc4be1cb40230a0fd99'

function Assert-LocalState {
    if (-not $HostIp) { throw 'APPLIANCE-CONFIG.json has no host_ip' }
    foreach ($path in @(
        'RUNTIME-TEST.md','RUN-FIFA15-F15B.bat','RUN-FIFA15-F15B-QOS-STATE-PARITY.ps1',
        'COLLECT-PLAYER-B-EVIDENCE.ps1','diagnostic-run.ps1','guest-network-observer.ps1',
        'VERIFY-PLAYER-B-GAME-FILES.ps1','capture-blaze-traffic.ps1',
        'APPLIANCE-CONFIG.json','PACKAGE-MANIFEST.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf)) {
            throw "Missing Player B prerequisite: $path"
        }
    }

    $gitDir=Join-Path $Root '.git'
    if(Test-Path -LiteralPath $gitDir){
        $branch=(& git -C $Root branch --show-current 2>$null | Select-Object -First 1).Trim()
        if($branch -ne $ExpectedBranch){throw "Wrong Player B branch: $branch; expected $ExpectedBranch"}
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
    if ([bool]$overlay.changes_matchmaking_wire_protocol) { throw 'Player B package must not change matchmaking wire protocol.' }
    if ([string]$overlay.instrumentation -ne 'none') { throw 'Player B package must use no instrumentation.' }
    if (-not [bool]$overlay.qos_dbps_ubps_retained_per_user) { throw 'PACKAGE-MANIFEST lost measured-QoS ownership hypothesis.' }
    if (-not [bool]$overlay.self_qdat_uses_client_measurement) { throw 'PACKAGE-MANIFEST lost self-QDAT measurement rule.' }
    if (-not [bool]$overlay.peer_qdat_uses_client_measurement_when_nonzero) { throw 'PACKAGE-MANIFEST lost peer-QDAT measurement rule.' }
    if (-not [bool]$overlay.game_nqos_uses_host_measurement_when_nonzero) { throw 'PACKAGE-MANIFEST lost GAME.NQOS measurement rule.' }
    if ([bool]$overlay.qosip_endian_changed) { throw 'This candidate must not change qosip endian behavior.' }
    if ([bool]$overlay.req_logic_changed) { throw 'This candidate must not change REQ logic.' }
    if ([bool]$overlay.native_pregame_changed) { throw 'This candidate must not change native pregame code.' }

    $runtimeText=Get-Content -LiteralPath (Join-Path $Root 'RUNTIME-TEST.md') -Raw
    foreach($marker in @($Candidate,$Package,$ExpectedBranch,$ExpectedHostBuild)) {
        if (-not $runtimeText.Contains($marker)) { throw "RUNTIME-TEST.md missing $marker" }
    }
    $launcherText=Get-Content -LiteralPath (Join-Path $Root 'RUN-FIFA15-F15B.bat') -Raw
    if (-not $launcherText.Contains($Candidate)) { throw 'RUN-FIFA15-F15B.bat banner does not name current candidate.' }
    if (-not $launcherText.Contains('RUN-FIFA15-F15B-QOS-STATE-PARITY.ps1')) { throw 'RUN-FIFA15-F15B.bat is not wired to QoS state-parity runner.' }
}

Assert-LocalState
if($SelfTest){
    Write-Host "PASS: Player B QoS state-parity v1 package pins $Package, host=$HostIp`:$Port, A=$ExpectedBranch/$ExpectedHostBuild, baseline=$ExpectedBaseline, no instrumentation, no B wire changes." -ForegroundColor Green
    exit 0
}

$client=New-Object Net.Sockets.TcpClient
$async=$null
try {
    $async=$client.BeginConnect($HostIp,$Port,$null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) { throw "Player A QoS state-parity gate $HostIp`:$Port timed out" }
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
    if ($ack -ne $expected) { throw "Player A rejected QoS state-parity package; got '$ack'" }
    Write-Host 'PASS: Player A accepted exact Player B QoS state-parity package.' -ForegroundColor Green
} finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
