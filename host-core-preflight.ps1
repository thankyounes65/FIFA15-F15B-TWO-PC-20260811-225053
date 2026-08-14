[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ReadyPort = 48215
$CorePorts = @(42127,42230,42128,17502,17503)

function Test-TcpPort([string]$HostIp, [int]$Port, [int]$TimeoutMs = 3000) {
    $client = $null
    try {
        $client = New-Object Net.Sockets.TcpClient
        $task = $client.ConnectAsync($HostIp, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch { return $false }
    finally { if ($client) { $client.Close() } }
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    if (($CorePorts -join ',') -ne '42127,42230,42128,17502,17503') { throw 'core port contract drifted' }
    Write-Host 'PASS: host core preflight parses and pins redirector, Blaze, QoS and FUT ports; no network connection was attempted.' -ForegroundColor Green
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch {
        Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "missing $ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $hostIp = [string]$config.host_ip
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($hostIp,[ref]$parsed)) { throw "invalid host_ip '$hostIp'" }

    Write-Host ''
    Write-Host 'Waiting for host READY and verifying every Player B relay prerequisite...' -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(10)
    $ready = $false
    while ((Get-Date) -lt $deadline -and -not $ready) {
        $client = $null
        try {
            $client = New-Object Net.Sockets.TcpClient
            $client.ReceiveTimeout = 2000
            $task = $client.ConnectAsync($hostIp,$ReadyPort)
            if ($task.Wait(1500) -and $client.Connected) {
                $stream = $client.GetStream()
                $buffer = New-Object byte[] 16
                $count = $stream.Read($buffer,0,$buffer.Length)
                $text = [Text.Encoding]::ASCII.GetString($buffer,0,$count)
                if ($text -match 'READY') { $ready = $true }
            }
        } catch {} finally { if ($client) { $client.Close() } }
        if (-not $ready) { Start-Sleep -Seconds 2 }
    }
    if (-not $ready) { throw "host $hostIp never reported READY on TCP $ReadyPort" }

    $failed = New-Object Collections.Generic.List[int]
    foreach ($port in $CorePorts) {
        if (Test-TcpPort -HostIp $hostIp -Port $port) {
            Write-Host "  PASS: host $hostIp TCP $port reachable." -ForegroundColor Green
        } else {
            $failed.Add($port)
            Write-Host "  FAIL: host $hostIp TCP $port unreachable." -ForegroundColor Red
        }
    }
    if ($failed.Count -gt 0) {
        throw "host READY is visible but required relay port(s) are unreachable: $($failed -join ', ')"
    }
    Write-Host 'HOST_CORE_PREREQUISITES_VERIFIED=true' -ForegroundColor Green
    exit 0
} catch {
    Write-Host "STOP [HOST_CORE_PREREQUISITE_FAILED]: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
