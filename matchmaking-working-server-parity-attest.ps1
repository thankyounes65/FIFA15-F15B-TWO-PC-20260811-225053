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
$Candidate='FIFA15-MM-WORKING-SERVER-PID-PROMOTION-V2'
$Package='F15B-MM-WORKING-SERVER-PID-PROMOTION-V2'
$ExpectedBranch='integration/test-matchmaking-working-server-pid-promotion-v2'
$ExpectedHostBuild='build_pairing_working_server_pid_promotion_v2.rs'
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
    if ([bool]$overlay.lead4_enabled) { throw 'PACKAGE-MANIFEST unexpectedly enables Lead 4.' }
    if ([bool]$overlay.changes_matchmaking_wire_protocol) { throw 'Player B package must not change matchmaking wire protocol.' }

    $runtimeText=Get-Content -LiteralPath (Join-Path $Root 'RUNTIME-TEST.md') -Raw
    if (-not $runtimeText.Contains('# FIFA15 Player B Working-Server PID Promotion v2')) {
        throw 'RUNTIME-TEST.md is not the Player B PID-promotion v2 package contract.'
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
    Write-Host "PASS: portable Player B PID-promotion v2 attestation pins package=$Package, host=$HostIp`:$Port, A=$ExpectedBranch/$ExpectedHostBuild, parity baseline=$ExpectedBaseline, and Lead 4 disabled." -ForegroundColor Green
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
    if ($ack -ne $expected) { throw "Player A rejected PID-promotion v2 package; got '$ack'" }
    Write-Host 'PASS: Player A accepted the exact Player B PID-promotion v2 package.' -ForegroundColor Green
} finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
