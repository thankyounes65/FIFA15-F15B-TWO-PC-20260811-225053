[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$CandidateId = 'FIFA15-MM-V15-GSU-NPSI'
$PackageAttestation = 'F15B-GITHUB-KNOWN-GOOD-20260815-V15-GSU-NPSI-1'
$PackageRevision = 'ea-readiness-v1+loopback-forwarder-17502-17503+matchmaking-v15-gsu-npsi-evidence1'
$ExpectedHostBranch = 'integration/test-matchmaking-gsu-npsi-v15'
$ExpectedHostBuild = 'build_pairing_gsu_npsi_v15.rs'
$GatePort = 48216

function Get-Contract {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Missing appliance config: $ConfigPath"
    }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Missing package manifest: $ManifestPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

    if ([string]$config.candidate_id -ne $CandidateId) { throw "Wrong candidate_id in APPLIANCE-CONFIG.json: '$($config.candidate_id)'" }
    if ([string]$config.package_attestation -ne $PackageAttestation) { throw "Wrong package_attestation in APPLIANCE-CONFIG.json: '$($config.package_attestation)'" }
    if ([string]$config.expected_host_branch -ne $ExpectedHostBranch) { throw "Wrong expected_host_branch in APPLIANCE-CONFIG.json: '$($config.expected_host_branch)'" }
    if ([string]$config.expected_host_build -ne $ExpectedHostBuild) { throw "Wrong expected_host_build in APPLIANCE-CONFIG.json: '$($config.expected_host_build)'" }
    if ([int]$config.attestation_gate_port -ne $GatePort) { throw "Wrong attestation_gate_port in APPLIANCE-CONFIG.json: '$($config.attestation_gate_port)'" }
    if (-not [string]$config.host_ip) { throw 'Player B host_ip is missing.' }

    if ([string]$manifest.package_revision -ne $PackageRevision) { throw "Wrong package_revision in PACKAGE-MANIFEST.json: '$($manifest.package_revision)'" }
    if ([string]$manifest.matchmaking_overlay.candidate_id -ne $CandidateId) { throw "Wrong candidate_id in PACKAGE-MANIFEST.json: '$($manifest.matchmaking_overlay.candidate_id)'" }
    if ([string]$manifest.matchmaking_overlay.package_attestation -ne $PackageAttestation) { throw "Wrong package_attestation in PACKAGE-MANIFEST.json: '$($manifest.matchmaking_overlay.package_attestation)'" }
    if ([string]$manifest.matchmaking_overlay.expected_host_branch -ne $ExpectedHostBranch) { throw "Wrong expected_host_branch in PACKAGE-MANIFEST.json: '$($manifest.matchmaking_overlay.expected_host_branch)'" }
    if ([string]$manifest.matchmaking_overlay.expected_host_build -ne $ExpectedHostBuild) { throw "Wrong expected_host_build in PACKAGE-MANIFEST.json: '$($manifest.matchmaking_overlay.expected_host_build)'" }
    if ([int]$manifest.matchmaking_overlay.gate_port -ne $GatePort) { throw "Wrong gate_port in PACKAGE-MANIFEST.json: '$($manifest.matchmaking_overlay.gate_port)'" }
    if ([bool]$manifest.matchmaking_overlay.requires_git_checkout) { throw 'Portable v15 Player B package unexpectedly requires a Git checkout.' }
    if (-not [bool]$manifest.matchmaking_overlay.portable_extracted_folder_supported) { throw 'PACKAGE-MANIFEST.json does not authorize portable extracted-folder execution.' }
    if (-not [bool]$manifest.matchmaking_overlay.exact_attempt_evidence_binding) { throw 'PACKAGE-MANIFEST.json does not require exact-attempt evidence binding.' }

    return [pscustomobject]@{ Config=$config; Manifest=$manifest }
}

function Test-Contract {
    $contract = Get-Contract
    if ($GatePort -ne 48216) { throw 'Candidate gate port changed unexpectedly.' }
    Write-Host 'PASS: portable Player B package carries the exact FIFA15-MM-V15-GSU-NPSI contract.' -ForegroundColor Green
    Write-Host "  Candidate: $CandidateId" -ForegroundColor Gray
    Write-Host "  Package token: $PackageAttestation" -ForegroundColor Gray
    Write-Host "  Package revision: $PackageRevision" -ForegroundColor Gray
    Write-Host "  Expected A: $ExpectedHostBranch" -ForegroundColor Gray
    Write-Host "  Expected A build: $ExpectedHostBuild" -ForegroundColor Gray
    Write-Host "  Host IP: $($contract.Config.host_ip)" -ForegroundColor Gray
    Write-Host '  Exact-attempt evidence binding: REQUIRED' -ForegroundColor Gray
    Write-Host '  Git checkout required: NO (fresh extracted GitHub ZIP is supported)' -ForegroundColor Gray
}

function Connect-CandidateGate([Net.Sockets.TcpClient]$Client,[string]$HostIp,[int]$Port) {
    $async = $null
    try {
        $async = $Client.BeginConnect($HostIp,$Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) {
            throw "Player A v15 candidate gate $HostIp`:$Port timed out. Start Player A option 5 / v15 first."
        }
        $Client.EndConnect($async)
        if (-not $Client.Connected) { throw "Player A v15 candidate gate $HostIp`:$Port did not establish a TCP connection." }
    }
    catch {
        $detail = $_.Exception.Message
        throw "Player A v15 candidate gate $HostIp`:$Port is unreachable or refused the TCP connection. Detail: $detail"
    }
    finally {
        if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    }
}

if ($SelfTest) {
    Test-Contract
    exit 0
}

$contract = Get-Contract
$hostIp = [string]$contract.Config.host_ip
$client = New-Object Net.Sockets.TcpClient
try {
    Connect-CandidateGate -Client $client -HostIp $hostIp -Port $GatePort
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
    $expectedAck = "ACCEPT $CandidateId $PackageAttestation"
    if ($ack -ne $expectedAck) { throw "Player A did not accept exact v15 Player B package token; got '$ack'." }

    Write-Host "PASS: Player A and Player B agree on exact candidate $CandidateId." -ForegroundColor Green
    Write-Host "  Player B package token: $PackageAttestation" -ForegroundColor Gray
    Write-Host "  Player B package revision: $PackageRevision" -ForegroundColor Gray
    Write-Host "  Expected A branch: $ExpectedHostBranch" -ForegroundColor Gray
    Write-Host "  Expected A build: $ExpectedHostBuild" -ForegroundColor Gray
}
finally {
    $client.Close()
}
