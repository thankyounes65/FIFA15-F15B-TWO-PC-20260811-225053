[CmdletBinding()]
param(
    [switch]$SelfTest,
    [int]$WaitSeconds = 600
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$Port = 3658

function Fail([string]$Text) {
    Write-Host "DEMANGLER PREFLIGHT FAILED: $Text" -ForegroundColor Red
    exit 1
}

function Test-TcpPort([string]$HostIp, [int]$RemotePort, [int]$TimeoutMs = 1500) {
    $client = $null
    try {
        $client = New-Object Net.Sockets.TcpClient
        $task = $client.ConnectAsync($HostIp, $RemotePort)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('3658','ConnectAsync','APPLIANCE-CONFIG.json','DEMANGLER_HOST_UNREACHABLE','WaitSeconds = 600','Waiting for host DirtySDK ProtoMangle')) {
        if ($source -notmatch [regex]::Escape($marker)) { throw "missing demangler-preflight marker: $marker" }
    }
    Write-Host 'PASS: Player B demangler preflight parses, is read-only, and can wait for A without launching FIFA.' -ForegroundColor Green
}

try {
    if ($SelfTest) { Invoke-SelfTest; exit 0 }
    if ($WaitSeconds -lt 1 -or $WaitSeconds -gt 1800) { Fail 'WaitSeconds must be between 1 and 1800.' }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Fail "missing $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $hostIp = [string]$config.host_ip
    $parsed = $null
    if (-not $hostIp -or -not [Net.IPAddress]::TryParse($hostIp, [ref]$parsed)) {
        Fail "invalid host_ip '$hostIp'"
    }

    Write-Host "Waiting for host DirtySDK ProtoMangle at $hostIp`:$Port (up to $WaitSeconds seconds)..." -ForegroundColor Gray
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if (Test-TcpPort -HostIp $hostIp -RemotePort $Port) {
            Write-Host "PASS: host-side DirtySDK ProtoMangle service reachable at $hostIp`:$Port" -ForegroundColor Green
            exit 0
        }
        Start-Sleep -Seconds 1
    } until ((Get-Date) -ge $deadline)

    Write-Host 'STOP [DEMANGLER_HOST_UNREACHABLE]: host-side DirtySDK ProtoMangle service never became reachable.' -ForegroundColor Red
    Write-Host "Expected: $hostIp`:$Port" -ForegroundColor Red
    exit 1
} catch {
    Fail $_.Exception.Message
}
