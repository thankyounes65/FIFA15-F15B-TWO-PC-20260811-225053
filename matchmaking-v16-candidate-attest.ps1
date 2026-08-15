[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$CandidateId = 'FIFA15-MM-V16-B-NATIVE-HANDOFF'
$PackageAttestation = 'F15B-GITHUB-DIAGNOSTIC-20260815-V16-NATIVE-HANDOFF-1'
$PackageRevision = 'ea-readiness-v1+loopback-forwarder-17502-17503+matchmaking-v16-native-handoff-diagnostic1'
$ExpectedHostBranch = 'integration/test-matchmaking-b-native-handoff-v16'
$ExpectedHostBuild = 'build_pairing_gsu_npsi_v15.rs'
$WireBaseline = '53dbaafb32030d6790beb0c16d336acd68cc1d49'
$GatePort = 48216

function Get-Contract {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([string]$config.candidate_id -ne $CandidateId) { throw 'wrong config candidate_id' }
    if ([string]$config.package_attestation -ne $PackageAttestation) { throw 'wrong config package_attestation' }
    if ([string]$config.expected_host_branch -ne $ExpectedHostBranch) { throw 'wrong config expected_host_branch' }
    if ([string]$config.expected_host_build -ne $ExpectedHostBuild) { throw 'wrong config expected_host_build' }
    if ([string]$config.wire_protocol_baseline_commit -ne $WireBaseline) { throw 'wrong config wire baseline' }
    if ([int]$config.attestation_gate_port -ne $GatePort) { throw 'wrong config gate port' }
    if (-not [string]$config.host_ip) { throw 'Player B host_ip is missing' }
    if ([string]$manifest.package_revision -ne $PackageRevision) { throw 'wrong package revision' }
    $m = $manifest.matchmaking_overlay
    if ([string]$m.candidate_id -ne $CandidateId -or [string]$m.package_attestation -ne $PackageAttestation) { throw 'wrong manifest candidate/package' }
    if ([string]$m.expected_host_branch -ne $ExpectedHostBranch -or [string]$m.expected_host_build -ne $ExpectedHostBuild) { throw 'wrong manifest A contract' }
    if ([string]$m.wire_protocol_baseline_commit -ne $WireBaseline) { throw 'wrong manifest wire baseline' }
    if (-not [bool]$m.diagnostic_only -or [bool]$m.changes_matchmaking_wire_protocol -or [bool]$m.native_execution_probe) { throw 'v16 diagnostic safety flags are wrong' }
    if (-not [bool]$m.network_log_mandatory_in_bundle -or -not [bool]$m.native_attestation_log_mandatory_in_bundle) { throw 'v16 evidence requirements are not pinned' }
    return [pscustomobject]@{ Config=$config; Manifest=$manifest }
}

function Invoke-SelfTest {
    $contract = Get-Contract
    if ($GatePort -ne 48216) { throw 'candidate gate port drifted' }
    Write-Host 'PASS: v16 Player B package pins exact candidate/package, tested-v15 wire baseline and diagnostic-only safety flags.' -ForegroundColor Green
    Write-Host "  Host IP: $($contract.Config.host_ip)" -ForegroundColor Gray
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
$contract = Get-Contract
$hostIp = [string]$contract.Config.host_ip
$client = New-Object Net.Sockets.TcpClient
$async = $null
try {
    $async = $client.BeginConnect($hostIp,$GatePort,$null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) { throw "Player A v16 candidate gate $hostIp`:$GatePort timed out" }
    $client.EndConnect($async)
    if (-not $client.Connected) { throw 'candidate gate TCP connection did not establish' }
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $stream = $client.GetStream()
    $helloText = "HELLO $CandidateId $PackageAttestation"
    $hello = [Text.Encoding]::ASCII.GetBytes($helloText)
    $stream.Write($hello,0,$hello.Length); $stream.Flush()
    $buffer = New-Object byte[] 256
    $count = $stream.Read($buffer,0,$buffer.Length)
    $ack = [Text.Encoding]::ASCII.GetString($buffer,0,$count).Trim()
    $expected = "ACCEPT $CandidateId $PackageAttestation"
    if ($ack -ne $expected) { throw "Player A rejected exact v16 package; got '$ack'" }
    Write-Host "PASS: Player A accepted exact v16 diagnostic package $PackageAttestation." -ForegroundColor Green
}
finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
