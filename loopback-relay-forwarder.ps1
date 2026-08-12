[CmdletBinding()]
param(
    [switch]$Start,
    [switch]$Stop,
    [switch]$Worker,
    [switch]$SelfTest,
    [string]$HostIp,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$StateDir = Join-Path $env:ProgramData 'FIFA15-Preservation'
$PidPath = Join-Path $StateDir 'f15b-loopback-forwarder.pid'
$Ports = @(17502, 17503)

function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Fail([string]$Code, [string]$Text) { Write-Host "STOP [$Code]: $Text" -ForegroundColor Red; exit 1 }

function Get-ConfiguredHostIp {
    if ($HostIp) { return $HostIp }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Fail 'FORWARDER_CONFIG_MISSING' 'APPLIANCE-CONFIG.json is missing.'
    }
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch {
        Fail 'FORWARDER_CONFIG_INVALID' "APPLIANCE-CONFIG.json is invalid: $($_.Exception.Message)"
    }
    $value = [string]$config.host_ip
    $parsed = $null
    if (-not $value -or -not [Net.IPAddress]::TryParse($value, [ref]$parsed)) {
        Fail 'FORWARDER_CONFIG_INVALID' "Invalid host_ip in APPLIANCE-CONFIG.json: '$value'"
    }
    return $value
}

function Stop-Forwarder {
    if (-not (Test-Path -LiteralPath $PidPath -PathType Leaf)) { return }
    $text = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue).Trim()
    if ($text -match '^\d+$') {
        $id = [int]$text
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if ($process -and $process.CommandLine -and $process.CommandLine -match 'loopback-relay-forwarder\.ps1' -and $process.CommandLine -match '-Worker') {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            Info "Stopped FIFA loopback relay forwarder PID $id."
        }
    }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw "PowerShell parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
    if (($Ports | Sort-Object -Unique).Count -ne 2 -or 17502 -notin $Ports -or 17503 -notin $Ports) {
        throw 'Forwarder must contain exactly the two proven loopback service ports 17502 and 17503.'
    }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('F15B_LOOPBACK_FORWARDER_READY','127.0.0.1','ConnectAsync','17502','17503')) {
        if ($source -notmatch [regex]::Escape($marker)) { throw "Missing forwarder marker: $marker" }
    }
    Write-Host 'PASS: loopback relay forwarder parses and is scoped only to QoS 17502 + FUT REST 17503.' -ForegroundColor Green
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch {
        Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

if ($Stop) {
    Stop-Forwarder
    exit 0
}

if ($Worker) {
    if (-not $HostIp) { Fail 'FORWARDER_HOST_MISSING' 'Worker mode requires -HostIp.' }
    if (-not $LogPath) { Fail 'FORWARDER_LOG_MISSING' 'Worker mode requires -LogPath.' }
    $logDir = Split-Path -Parent $LogPath
    if ($logDir) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    Add-Type @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

public static class Fifa15LoopbackForwarder
{
    private static readonly object LogGate = new object();

    private static void Log(string path, string text)
    {
        lock (LogGate)
        {
            File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + text + Environment.NewLine, Encoding.UTF8);
        }
    }

    private static async Task CopyAsync(NetworkStream source, NetworkStream destination)
    {
        byte[] buffer = new byte[65536];
        while (true)
        {
            int count = await source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
            if (count <= 0) break;
            await destination.WriteAsync(buffer, 0, count).ConfigureAwait(false);
            await destination.FlushAsync().ConfigureAwait(false);
        }
    }

    private static async Task HandleAsync(TcpClient inbound, string host, int port, string logPath)
    {
        string source = "unknown";
        try
        {
            source = inbound.Client.RemoteEndPoint == null ? "unknown" : inbound.Client.RemoteEndPoint.ToString();
            using (inbound)
            using (TcpClient outbound = new TcpClient())
            {
                await outbound.ConnectAsync(host, port).ConfigureAwait(false);
                Log(logPath, "FORWARD_CONNECT local=127.0.0.1:" + port + " source=" + source + " remote=" + host + ":" + port);
                NetworkStream a = inbound.GetStream();
                NetworkStream b = outbound.GetStream();
                Task left = CopyAsync(a, b);
                Task right = CopyAsync(b, a);
                await Task.WhenAny(left, right).ConfigureAwait(false);
            }
        }
        catch (Exception ex)
        {
            Log(logPath, "FORWARD_ERROR port=" + port + " source=" + source + " error=" + ex.GetType().Name + ":" + ex.Message);
        }
    }

    private static async Task ListenAsync(string host, int port, string logPath)
    {
        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Log(logPath, "LISTEN local=127.0.0.1:" + port + " remote=" + host + ":" + port);
        while (true)
        {
            TcpClient inbound = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
            Task ignored = HandleAsync(inbound, host, port, logPath);
        }
    }

    public static void Run(string host, int[] ports, string logPath)
    {
        Task[] listeners = new Task[ports.Length];
        for (int i = 0; i < ports.Length; i++)
            listeners[i] = ListenAsync(host, ports[i], logPath);
        Task.WaitAll(listeners);
    }
}
'@

    [Fifa15LoopbackForwarder]::Run($HostIp, [int[]]$Ports, $LogPath)
    exit 0
}

if (-not $Start) { Fail 'FORWARDER_MODE_REQUIRED' 'Use -Start, -Stop, -Worker, or -SelfTest.' }

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
Stop-Forwarder
$resolvedHost = Get-ConfiguredHostIp

foreach ($port in $Ports) {
    $owner = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($owner) {
        Fail 'LOOPBACK_FORWARDER_PORT_IN_USE' "127.0.0.1:$port is already owned by PID $($owner.OwningProcess). No FIFA settings were changed."
    }
}

if (-not $LogPath) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $LogPath = Join-Path $desktop ("FIFA15-F15B-FORWARDER-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$child = Start-Process powershell.exe -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Worker','-HostIp',"`"$resolvedHost`"",'-LogPath',"`"$LogPath`""
) -WindowStyle Hidden -PassThru

$deadline = (Get-Date).AddSeconds(10)
do {
    Start-Sleep -Milliseconds 100
    $child.Refresh()
    if ($child.HasExited) {
        Fail 'LOOPBACK_FORWARDER_START_FAILED' "Forwarder exited during startup with code $($child.ExitCode). Check $LogPath"
    }
    $ready = $true
    foreach ($port in $Ports) {
        $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $child.Id } | Select-Object -First 1
        if (-not $listener) { $ready = $false; break }
    }
} until ($ready -or (Get-Date) -gt $deadline)

if (-not $ready) {
    Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
    Fail 'LOOPBACK_FORWARDER_START_FAILED' "Forwarder PID $($child.Id) did not own both 127.0.0.1:17502 and :17503 within 10 seconds. Check $LogPath"
}

Set-Content -LiteralPath $PidPath -Value $child.Id -Encoding ASCII -NoNewline
Write-Host "F15B_LOOPBACK_FORWARDER_READY PID=$($child.Id) host=$resolvedHost ports=$($Ports -join ',') log=$LogPath" -ForegroundColor Green
exit 0
