[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$CandidateId = 'FIFA15-MM-V13-V2'
$PackageAttestation = 'F15B-GITHUB-KNOWN-GOOD-20260811-V13V2-1'
$ExpectedHostBranch = 'integration/test-matchmaking-joiner-result-v13-v2'
$GatePort = 48216

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Missing appliance config: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ([string]$config.candidate_id -ne $CandidateId) {
        throw "Wrong candidate_id: '$($config.candidate_id)'"
    }
    if ([string]$config.package_attestation -ne $PackageAttestation) {
        throw "Wrong package_attestation: '$($config.package_attestation)'"
    }
    if ([string]$config.expected_host_branch -ne $ExpectedHostBranch) {
        throw "Wrong expected_host_branch: '$($config.expected_host_branch)'"
    }
    if (-not [string]$config.host_ip) {
        throw 'Player B host_ip is missing.'
    }
    return $config
}

function Test-Contract {
    $config = Get-Config
    if ($GatePort -ne 48216) { throw 'Candidate gate port changed unexpectedly.' }
    Write-Host 'PASS: known-good Player B appliance carries the FIFA15-MM-V13-V2 attestation overlay.' -ForegroundColor Green
    Write-Host "  Candidate: $CandidateId" -ForegroundColor Gray
    Write-Host "  Package: $PackageAttestation" -ForegroundColor Gray
    Write-Host "  Expected A: $ExpectedHostBranch" -ForegroundColor Gray
    Write-Host "  Host IP: $($config.host_ip)" -ForegroundColor Gray
}

function Connect-CandidateGate([Net.Sockets.TcpClient]$Client,[string]$HostIp,[int]$Port) {
    $async = $null
    try {
        $async = $Client.BeginConnect($HostIp,$Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) {
            throw "Player A v13-v2 candidate gate $HostIp`:$Port timed out. Start the Player A v13-v2 runtime first."
        }
        $Client.EndConnect($async)
        if (-not $Client.Connected) {
            throw "Player A v13-v2 candidate gate $HostIp`:$Port did not establish a TCP connection."
        }
    }
    catch {
        $detail = $_.Exception.Message
        throw "Player A v13-v2 candidate gate $HostIp`:$Port is unreachable or refused the TCP connection. Detail: $detail"
    }
    finally {
        if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    }
}

if ($SelfTest) {
    Test-Contract
    exit 0
}

$config = Get-Config
$hostIp = [string]$config.host_ip
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
    if ($ack -ne $expectedAck) {
        throw "Player A did not accept the exact v13-v2 known-good B package; got '$ack'."
    }

    Write-Host "PASS: Player A and known-good Player B package agree on exact candidate $CandidateId." -ForegroundColor Green
    Write-Host "  Package attestation: $PackageAttestation" -ForegroundColor Gray
    Write-Host "  Expected A branch: $ExpectedHostBranch" -ForegroundColor Gray
}
finally {
    $client.Close()
}
