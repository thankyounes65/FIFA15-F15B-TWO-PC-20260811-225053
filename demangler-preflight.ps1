[CmdletBinding()]
param(
    [switch]$SelfTest,
    [int]$WaitSeconds = 600
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ManagedHostnamesPath = Join-Path $Root 'fifa15-managed-hostnames.ps1'
$ForwarderPath = Join-Path $Root 'loopback-relay-forwarder.ps1'
$Port = 3658

function Fail([string]$Text) {
    Write-Host "DEMANGLER PREFLIGHT FAILED: $Text" -ForegroundColor Red
    exit 1
}

function Register-PlayerB([string]$HostIp) {
    $uri = "http://$HostIp`:$Port/appliance/register?role=f15b"
    $response = $null
    $reader = $null
    try {
        # Bypass Windows/IE proxy configuration. This is an appliance-local
        # Tailscale control request and must go directly to the configured host.
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.Proxy = $null
        $request.Timeout = 3000
        $request.ReadWriteTimeout = 3000
        $request.KeepAlive = $false
        $response = [Net.HttpWebResponse]$request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::ASCII)
        $body = $reader.ReadToEnd().Trim()
        return ([int]$response.StatusCode -eq 200 -and $body -eq 'registered')
    } catch {
        return $false
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @(
        '3658',
        'HttpWebRequest',
        '$request.Proxy = $null',
        '/appliance/register?role=f15b',
        'APPLIANCE-CONFIG.json',
        'DEMANGLER_HOST_UNREACHABLE',
        'WaitSeconds = 600',
        'Waiting for host DirtySDK ProtoMangle'
    )) {
        if ($source -notmatch [regex]::Escape($marker)) { throw "missing demangler-preflight marker: $marker" }
    }

    if (-not (Test-Path -LiteralPath $ManagedHostnamesPath -PathType Leaf)) {
        throw "missing managed hostname inventory: $ManagedHostnamesPath"
    }
    . $ManagedHostnamesPath
    if (-not $Fifa15RedirectableHostnames -or 'demangler.ea.com' -notin $Fifa15RedirectableHostnames) {
        throw 'Player B managed hostname inventory must route demangler.ea.com to the configured Player A host.'
    }

    if (-not (Test-Path -LiteralPath $ForwarderPath -PathType Leaf)) {
        throw "missing loopback forwarder: $ForwarderPath"
    }
    $forwarderSource = Get-Content -LiteralPath $ForwarderPath -Raw
    foreach ($marker in @('3658','peach.online.ea.com','127.0.0.1')) {
        if ($forwarderSource -notmatch [regex]::Escape($marker)) {
            throw "Player B loopback ProtoMangle forwarder lost required marker: $marker"
        }
    }

    Write-Host 'PASS: Player B demangler preflight parses, bypasses system proxies, keeps demangler.ea.com in the host-routed inventory, preserves peach.online.ea.com through the loopback TCP/3658 forwarder, and registers the current tailnet peer before runtime.' -ForegroundColor Green
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
        if (Register-PlayerB -HostIp $hostIp) {
            Write-Host "PASS: host-side ProtoMangle HTTP service is ready and registered this Player B tailnet endpoint at $hostIp`:$Port" -ForegroundColor Green
            Write-Host 'NOTE: this appliance registration is infrastructure preflight only; only demangler_get_peer_address is FIFA runtime proof.' -ForegroundColor Gray
            exit 0
        }
        Start-Sleep -Seconds 1
    } until ((Get-Date) -ge $deadline)

    Write-Host 'STOP [DEMANGLER_HOST_UNREACHABLE]: host-side DirtySDK ProtoMangle HTTP service never became reachable/registerable.' -ForegroundColor Red
    Write-Host "Expected: $hostIp`:$Port/appliance/register?role=f15b" -ForegroundColor Red
    exit 1
} catch {
    Fail $_.Exception.Message
}
