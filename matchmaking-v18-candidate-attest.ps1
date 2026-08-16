[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ContractPath = Join-Path $Root 'MATCHMAKING-V18-CANDIDATE.json'
$CandidateId = 'FIFA15-MM-V18-DEFER-JOIN-COMPLETED'
$PackageAttestation = 'F15B-GITHUB-DIAGNOSTIC-20260815-V18-DEFER-JOIN-COMPLETED-1'
$ExpectedHostBranch = 'integration/test-matchmaking-defer-join-completed-v18'
$ExpectedHostBuild = 'build_pairing_defer_join_completed_v18.rs'
$WireBaseline = '53dbaafb32030d6790beb0c16d336acd68cc1d49'
$RuntimeBase = '7d918d23fe7e697035d6b2b4f9c7afdff1b62206'
$GuestRuntimeBase = 'c116ce720c6193fcaf5b6a4d3a0693c16454cdc9'
$GatePort = 48216

function Get-Contract {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing inherited v16 config: $ConfigPath" }
    if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) { throw "Missing v18 overlay contract: $ContractPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    if (-not [string]$config.host_ip) { throw 'Player B inherited host_ip is missing' }
    if ([string]$contract.candidate_id -ne $CandidateId) { throw 'wrong v18 candidate_id' }
    if ([string]$contract.package_attestation -ne $PackageAttestation) { throw 'wrong v18 package_attestation' }
    if ([string]$contract.source_branch -ne 'diagnostic/v18-defer-join-completed-20260815') { throw 'wrong v18 source branch' }
    if ([string]$contract.expected_host_branch -ne $ExpectedHostBranch) { throw 'wrong v18 expected host branch' }
    if ([string]$contract.expected_host_build -ne $ExpectedHostBuild) { throw 'wrong v18 expected host build' }
    if ([string]$contract.wire_protocol_baseline_commit -ne $WireBaseline) { throw 'wrong v18 FIFA15 wire baseline' }
    if ([string]$contract.tested_v16_runtime_base -ne $RuntimeBase) { throw 'wrong tested v16 A runtime base' }
    if ([string]$contract.guest_runtime_base_commit -ne $GuestRuntimeBase) { throw 'wrong inherited v16 B runtime base' }
    if ([int]$contract.attestation_gate_port -ne $GatePort) { throw 'wrong v18 gate port' }
    if ([bool]$contract.changes_guest_boot_stack -or [bool]$contract.changes_guest_network_observer -or [bool]$contract.changes_guest_native_attestor -or [bool]$contract.changes_guest_matchmaking_wire_protocol) {
        throw 'v18 B overlay must not claim any guest runtime/protocol change'
    }
    if ([string]$contract.host_matchmaking_wire_delta -ne 'defer_joiner_join_completed_until_mesh_promotion') { throw 'wrong host wire delta declaration' }
    return [pscustomobject]@{ Config=$config; Contract=$contract }
}

function Invoke-SelfTest {
    $state = Get-Contract
    if ($GatePort -ne 48216) { throw 'candidate gate port drifted' }
    Write-Host 'PASS: v18 Player B overlay pins exact A candidate/package while preserving fixed v16 B runtime stack.' -ForegroundColor Green
    Write-Host "  Host IP: $($state.Config.host_ip)" -ForegroundColor Gray
    Write-Host "  Inherited B runtime base: $GuestRuntimeBase" -ForegroundColor Gray
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
$state = Get-Contract
$hostIp = [string]$state.Config.host_ip
$client = New-Object Net.Sockets.TcpClient
$async = $null
try {
    $async = $client.BeginConnect($hostIp,$GatePort,$null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) { throw "Player A v18 candidate gate $hostIp`:$GatePort timed out" }
    $client.EndConnect($async)
    if (-not $client.Connected) { throw 'candidate gate TCP connection did not establish' }
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $stream = $client.GetStream()
    $helloText = "HELLO $CandidateId $PackageAttestation"
    $hello = [Text.Encoding]::ASCII.GetBytes($helloText)
    $stream.Write($hello,0,$hello.Length)
    $stream.Flush()
    $buffer = New-Object byte[] 256
    $count = $stream.Read($buffer,0,$buffer.Length)
    $ack = [Text.Encoding]::ASCII.GetString($buffer,0,$count).Trim()
    $expected = "ACCEPT $CandidateId $PackageAttestation"
    if ($ack -ne $expected) { throw "Player A rejected exact v18 package; got '$ack'" }
    Write-Host "PASS: Player A accepted exact v18 B overlay $PackageAttestation." -ForegroundColor Green
}
finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
