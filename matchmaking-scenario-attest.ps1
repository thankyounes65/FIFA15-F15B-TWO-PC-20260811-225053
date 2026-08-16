[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ScenarioPath = Join-Path $Root 'MATCHMAKING-SCENARIO.json'
function Get-State {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing inherited Player-B config: $ConfigPath" }
    if (-not (Test-Path -LiteralPath $ScenarioPath -PathType Leaf)) { throw "Missing scenario contract: $ScenarioPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $s = Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json
    foreach ($name in @('scenario_id','scenario_slug','candidate_id','package_attestation','b_branch','expected_a_branch','expected_a_build','wire_baseline','a_runtime_base','b_runtime_base','gate_port','protocol_delta')) {
        if (-not $s.PSObject.Properties[$name] -or -not [string]$s.$name) { throw "Scenario contract missing $name" }
    }
    if ([int]$s.scenario_id -lt 1 -or [int]$s.scenario_id -gt 4) { throw 'scenario_id must be 1..4' }
    if ([int]$s.gate_port -ne 48216) { throw 'scenario gate port drifted from 48216' }
    if (-not [string]$config.host_ip) { throw 'Player B host_ip is missing from APPLIANCE-CONFIG.json' }
    $branch = (& git -C $Root branch --show-current 2>$null | Select-Object -First 1)
    if (-not $branch) { throw 'Could not resolve current Player-B git branch.' }
    $branch = $branch.Trim()
    if ($branch -ne [string]$s.b_branch) { throw "Wrong Player-B branch: $branch; expected $($s.b_branch)" }
    & git -C $Root merge-base --is-ancestor ([string]$s.b_runtime_base) HEAD
    if ($LASTEXITCODE -ne 0) { throw "Player-B branch is not descended from fixed-v16 base $($s.b_runtime_base)" }
    [pscustomobject]@{ Config=$config; Scenario=$s; Branch=$branch }
}
$state = Get-State
$s = $state.Scenario
if ($SelfTest) {
    foreach ($relative in @('RUN-FIFA15-F15B-V18.bat','matchmaking-v16-native-handoff-attest.ps1','classify-network-observer-v16.ps1','collect-evidence-v16.ps1','guest-network-observer.ps1','diagnostic-run.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) { throw "Inherited fixed-v16 runtime file missing: $relative" }
    }
    Write-Host "PASS: Player-B scenario $($s.scenario_id) pins branch/package/A candidate while preserving fixed-v16 runtime stack." -ForegroundColor Green
    Write-Host "  B: $($s.b_branch)" -ForegroundColor Gray
    Write-Host "  A: $($s.expected_a_branch) / $($s.expected_a_build)" -ForegroundColor Gray
    Write-Host "  Candidate: $($s.candidate_id)" -ForegroundColor Gray
    exit 0
}
$client = New-Object Net.Sockets.TcpClient
$async = $null
try {
    $hostIp = [string]$state.Config.host_ip
    $async = $client.BeginConnect($hostIp,[int]$s.gate_port,$null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) { throw "Player A scenario gate $hostIp`:$($s.gate_port) timed out" }
    $client.EndConnect($async)
    if (-not $client.Connected) { throw 'scenario gate TCP connection did not establish' }
    $client.ReceiveTimeout=5000; $client.SendTimeout=5000
    $stream=$client.GetStream()
    $helloText="HELLO $($s.candidate_id) $($s.package_attestation)"
    $hello=[Text.Encoding]::ASCII.GetBytes($helloText); $stream.Write($hello,0,$hello.Length); $stream.Flush()
    $buffer=New-Object byte[] 256; $count=$stream.Read($buffer,0,$buffer.Length)
    $ack=[Text.Encoding]::ASCII.GetString($buffer,0,$count).Trim()
    $expected="ACCEPT $($s.candidate_id) $($s.package_attestation)"
    if ($ack -ne $expected) { throw "Player A rejected scenario package; got '$ack'" }
    Write-Host "PASS: Player A accepted Player-B scenario $($s.scenario_id) package $($s.package_attestation)." -ForegroundColor Green
} finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
