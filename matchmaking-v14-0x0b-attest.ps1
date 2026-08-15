[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$CandidateId = 'FIFA15-MM-V14-0X0B'
$PackageAttestation = 'F15B-GITHUB-KNOWN-GOOD-20260811-V14-0X0B-1'
$ExpectedHostBranch = 'integration/test-matchmaking-session-completion-0x0b-v14'
$ExpectedRepo = 'thankyounes65/FIFA15-F15B-TWO-PC-20260811-225053'
$ExpectedBranch = 'main'
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

function Get-RepoState {
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        throw "Player B must run from a Git checkout of $ExpectedRepo so the exact tested commit can be attested. Clone/pull the repository rather than using an old extracted package."
    }
    $branch = (& git -C $Root branch --show-current 2>$null | Select-Object -First 1)
    $commit = (& git -C $Root rev-parse HEAD 2>$null | Select-Object -First 1)
    if (-not $branch -or -not $commit) {
        throw 'Could not resolve Player B Git branch/commit.'
    }
    $branch = $branch.Trim()
    $commit = $commit.Trim().ToLowerInvariant()
    if ($branch -ne $ExpectedBranch) {
        throw "Wrong Player B branch. Expected $ExpectedBranch, found $branch."
    }
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "Invalid Player B Git commit: '$commit'"
    }
    return [pscustomobject]@{ Branch=$branch; Commit=$commit }
}

function Test-Contract {
    $config = Get-Config
    $repo = Get-RepoState
    if ($GatePort -ne 48216) { throw 'Candidate gate port changed unexpectedly.' }
    Write-Host 'PASS: dedicated Player B repository carries the FIFA15-MM-V14-0X0B attestation overlay.' -ForegroundColor Green
    Write-Host "  Candidate: $CandidateId" -ForegroundColor Gray
    Write-Host "  Repository: $ExpectedRepo" -ForegroundColor Gray
    Write-Host "  Branch: $($repo.Branch)" -ForegroundColor Gray
    Write-Host "  Commit: $($repo.Commit)" -ForegroundColor Gray
    Write-Host "  Package: $PackageAttestation" -ForegroundColor Gray
    Write-Host "  Expected A: $ExpectedHostBranch" -ForegroundColor Gray
    Write-Host "  Host IP: $($config.host_ip)" -ForegroundColor Gray
}

function Connect-CandidateGate([Net.Sockets.TcpClient]$Client,[string]$HostIp,[int]$Port) {
    $async = $null
    try {
        $async = $Client.BeginConnect($HostIp,$Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) {
            throw "Player A v14 candidate gate $HostIp`:$Port timed out. Start the Player A v14 runtime first."
        }
        $Client.EndConnect($async)
        if (-not $Client.Connected) {
            throw "Player A v14 candidate gate $HostIp`:$Port did not establish a TCP connection."
        }
    }
    catch {
        $detail = $_.Exception.Message
        throw "Player A v14 candidate gate $HostIp`:$Port is unreachable or refused the TCP connection. Detail: $detail"
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
$repo = Get-RepoState
$hostIp = [string]$config.host_ip
$client = New-Object Net.Sockets.TcpClient
try {
    Connect-CandidateGate -Client $client -HostIp $hostIp -Port $GatePort
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $stream = $client.GetStream()
    $helloText = "HELLO $CandidateId $($repo.Commit)"
    $hello = [Text.Encoding]::ASCII.GetBytes($helloText)
    $stream.Write($hello,0,$hello.Length)
    $stream.Flush()

    $buffer = New-Object byte[] 256
    $count = $stream.Read($buffer,0,$buffer.Length)
    $ack = [Text.Encoding]::ASCII.GetString($buffer,0,$count).Trim()
    $expectedAck = "ACCEPT $CandidateId $($repo.Commit)"
    if ($ack -ne $expectedAck) {
        throw "Player A did not accept exact v14 Player B repository commit; got '$ack'."
    }

    Write-Host "PASS: Player A and dedicated Player B repo agree on exact candidate $CandidateId." -ForegroundColor Green
    Write-Host "  Player B repo: $ExpectedRepo" -ForegroundColor Gray
    Write-Host "  Player B commit: $($repo.Commit)" -ForegroundColor Gray
    Write-Host "  Expected A branch: $ExpectedHostBranch" -ForegroundColor Gray
}
finally {
    $client.Close()
}
