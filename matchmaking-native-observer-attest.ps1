[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$Root=Split-Path -Parent $PSCommandPath
$Config=Get-Content -LiteralPath (Join-Path $Root 'APPLIANCE-CONFIG.json') -Raw | ConvertFrom-Json
$HostIp=[string]$Config.host_ip
$Port=48216
$Candidate='FIFA15-MM-NATIVE-OBSERVER-V1'
$Package='F15B-MM-NATIVE-OBSERVER-V1'
$ExpectedBranch='integration/test-matchmaking-native-observer-v1'
function Assert-LocalState {
    if (-not $HostIp) { throw 'APPLIANCE-CONFIG.json has no host_ip' }
    $branch=(& git -C $Root branch --show-current 2>$null | Select-Object -First 1).Trim()
    if ($branch -ne $ExpectedBranch) { throw "Wrong Player B branch: $branch; expected $ExpectedBranch" }
    foreach ($path in @('matchmaking-native-observer.py','diagnostic-run.ps1','guest-network-observer.ps1','VERIFY-PLAYER-B-GAME-FILES.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf)) { throw "Missing Player B observer prerequisite: $path" }
    }
}
Assert-LocalState
if ($SelfTest) {
    Write-Host "PASS: scenario-free Player B observer attestation pins branch=$ExpectedBranch package=$Package host=$HostIp`:$Port." -ForegroundColor Green
    exit 0
}
$client=New-Object Net.Sockets.TcpClient
$async=$null
try {
    $async=$client.BeginConnect($HostIp,$Port,$null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) { throw "Player A observer gate $HostIp`:$Port timed out" }
    $client.EndConnect($async);$client.ReceiveTimeout=5000;$client.SendTimeout=5000;$stream=$client.GetStream()
    $hello=[Text.Encoding]::ASCII.GetBytes("HELLO $Candidate $Package");$stream.Write($hello,0,$hello.Length);$stream.Flush()
    $buffer=New-Object byte[] 256;$count=$stream.Read($buffer,0,$buffer.Length);$ack=[Text.Encoding]::ASCII.GetString($buffer,0,$count).Trim()
    $expected="ACCEPT $Candidate $Package"
    if ($ack -ne $expected) { throw "Player A rejected native observer package; got '$ack'" }
    Write-Host 'PASS: Player A accepted the Player B native-observer package. No scenario or wire variant was selected.' -ForegroundColor Green
} finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
