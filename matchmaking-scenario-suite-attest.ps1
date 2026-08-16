[CmdletBinding()]
param(
    [ValidateRange(0,4)][int]$Scenario = 0,
    [switch]$SelfTest,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$SuitePath = Join-Path $Root 'MATCHMAKING-SCENARIO-SUITE.json'

function Get-Suite {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing inherited Player-B config: $ConfigPath" }
    if (-not (Test-Path -LiteralPath $SuitePath -PathType Leaf)) { throw "Missing scenario suite contract: $SuitePath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $suite = Get-Content -LiteralPath $SuitePath -Raw | ConvertFrom-Json
    if (-not [string]$config.host_ip) { throw 'Player B inherited host_ip is missing' }
    if ([string]$suite.b_branch -ne 'diagnostic/matchmaking-scenario-suite-20260816') { throw 'scenario suite B branch contract drifted' }
    if ([string]$suite.b_package -ne 'F15B-MM-SCENARIO-SUITE-1') { throw 'scenario suite package token drifted' }
    if ([int]$suite.attestation_gate_port -ne 48216) { throw 'scenario suite gate port drifted' }
    if ([bool]$suite.guest_runtime_change) { throw 'scenario suite must not claim a Player-B runtime/protocol change' }
    $items = @($suite.scenarios)
    if ($items.Count -ne 4) { throw "scenario suite must contain exactly four scenarios; found $($items.Count)" }
    if ((@($items.id | Sort-Object -Unique) -join ',') -ne '1,2,3,4') { throw 'scenario suite ids must be exactly 1,2,3,4' }
    return [pscustomobject]@{ Config=$config; Suite=$suite; Items=$items }
}

function Resolve-Scenario([object]$state, [int]$id) {
    if ($id -eq 0 -and $env:SCENARIO_ID) { $id = [int]$env:SCENARIO_ID }
    if ($id -lt 1 -or $id -gt 4) { throw 'Scenario must be 1, 2, 3, or 4.' }
    $entry = @($state.Items | Where-Object { [int]$_.id -eq $id })
    if ($entry.Count -ne 1) { throw "Scenario $id did not resolve uniquely." }
    return $entry[0]
}

function Assert-SelectedEnvironment([object]$state, [object]$entry) {
    $checks = @{
        SCENARIO_ID = [string]$entry.id
        SCENARIO_SLUG = [string]$entry.slug
        CANDIDATE_ID = [string]$entry.candidate_id
        PACKAGE_TOKEN = [string]$state.Suite.b_package
        EXPECTED_A = [string]$entry.a_branch
        EXPECTED_BUILD = [string]$entry.a_build
    }
    foreach ($name in $checks.Keys) {
        $actual = [Environment]::GetEnvironmentVariable($name)
        if ($actual -and $actual -ne $checks[$name]) { throw "$name mismatch: expected '$($checks[$name])', got '$actual'" }
    }
}

$state = Get-Suite
if ($All) {
    foreach ($entry in $state.Items) {
        if (-not [string]$entry.slug -or -not [string]$entry.candidate_id -or -not [string]$entry.a_branch -or -not [string]$entry.a_build) {
            throw "Scenario $($entry.id) has an incomplete contract."
        }
    }
    Write-Host 'PASS: Player-B scenario suite contains four complete isolated A-candidate contracts.' -ForegroundColor Green
    exit 0
}

$entry = Resolve-Scenario $state $Scenario
Assert-SelectedEnvironment $state $entry
if ($SelfTest) {
    Write-Host "PASS: Player-B scenario $($entry.id) contract is coherent; fixed v16/v18 guest runtime is reused unchanged." -ForegroundColor Green
    Write-Host "  Scenario: $($entry.name)" -ForegroundColor Gray
    Write-Host "  A branch: $($entry.a_branch)" -ForegroundColor Gray
    Write-Host "  Candidate: $($entry.candidate_id)" -ForegroundColor Gray
    exit 0
}

$hostIp = [string]$state.Config.host_ip
$gatePort = [int]$state.Suite.attestation_gate_port
$candidate = [string]$entry.candidate_id
$package = [string]$state.Suite.b_package
$client = New-Object Net.Sockets.TcpClient
$async = $null
try {
    $async = $client.BeginConnect($hostIp,$gatePort,$null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) { throw "Player A scenario gate $hostIp`:$gatePort timed out" }
    $client.EndConnect($async)
    if (-not $client.Connected) { throw 'scenario gate TCP connection did not establish' }
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $stream = $client.GetStream()
    $helloText = "HELLO $candidate $package"
    $hello = [Text.Encoding]::ASCII.GetBytes($helloText)
    $stream.Write($hello,0,$hello.Length)
    $stream.Flush()
    $buffer = New-Object byte[] 256
    $count = $stream.Read($buffer,0,$buffer.Length)
    $ack = [Text.Encoding]::ASCII.GetString($buffer,0,$count).Trim()
    $expected = "ACCEPT $candidate $package"
    if ($ack -ne $expected) { throw "Player A rejected scenario $($entry.id) package; got '$ack'" }
    Write-Host "PASS: Player A accepted scenario $($entry.id) / $candidate / $package." -ForegroundColor Green
}
finally {
    if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
    $client.Close()
}
