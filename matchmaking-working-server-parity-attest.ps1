[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$Root=Split-Path -Parent $PSCommandPath
$Config=Get-Content -LiteralPath (Join-Path $Root 'APPLIANCE-CONFIG.json') -Raw | ConvertFrom-Json
$HostIp=[string]$Config.host_ip
$Port=48216
$Candidate='FIFA15-MM-WORKING-SERVER-PID-PROMOTION-V2'
$Package='F15B-MM-WORKING-SERVER-PID-PROMOTION-V2'
$ExpectedBranch='integration/test-matchmaking-working-server-pid-promotion-v2'

function Assert-LocalState {
    if (-not $HostIp) { throw 'APPLIANCE-CONFIG.json has no host_ip' }

    foreach ($path in @(
        'RUNTIME-TEST.md',
        'RUN-FIFA15-F15B.bat',
        'RUN-FIFA15-F15B-PARITY.ps1',
        'COLLECT-PLAYER-B-EVIDENCE.ps1',
        'diagnostic-run.ps1',
        'guest-network-observer.ps1',
        'VERIFY-PLAYER-B-GAME-FILES.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf)) {
            throw "Missing Player B prerequisite: $path"
        }
    }

    $runtimeText=Get-Content -LiteralPath (Join-Path $Root 'RUNTIME-TEST.md') -Raw
    if (-not $runtimeText.Contains('# FIFA15 Player B Working-Server PID Promotion v2')) {
        throw 'RUNTIME-TEST.md is not the Player B PID-promotion v2 package contract.'
    }
    if (-not $runtimeText.Contains($ExpectedBranch)) {
        throw "RUNTIME-TEST.md does not pin expected Player B branch $ExpectedBranch."
    }

    $launcherText=Get-Content -LiteralPath (Join-Path $Root 'RUN-FIFA15-F15B.bat') -Raw
    if (-not $launcherText.Contains('RUN-FIFA15-F15B-PARITY.ps1')) {
        throw 'RUN-FIFA15-F15B.bat is not wired to the passive parity-family runner.'
    }
}

Assert-LocalState
if($SelfTest){
    Write-Host "PASS: portable Player B PID-promotion v2 attestation pins package=$Package host=$HostIp`:$Port and exact branch contract without requiring Git." -ForegroundColor Green
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
