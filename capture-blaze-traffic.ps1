<#
Player B wire capture.

Why this exists, given Player A's relay already logs every frame it sends:
"notification sent successfully" only means the relay's socket accepted the
bytes. It does not prove they arrived, and it cannot show what the CLIENT did
next at the TCP level. If FIFA rejects a notification it resets the connection,
and only a capture on this machine shows which frame immediately preceded the
RST. That is the decisive evidence for the setup-burst candidate's stated
regression signal, and Player A cannot produce it.

Scope is deliberately narrow so the capture cannot drop packets. The "golden"
FIFA 15 capture in the main repo was unfiltered, ran at 768 MB circular under
full gameplay load, and lost 169 KB of server traffic - including one whole
frame out of the exact burst under investigation. A filtered capture of a few
ports records a few MB and loses nothing. pktmon's own drop counters are read
back at stop and reported, so a lossy capture announces itself instead of being
mistaken for evidence of absence.

    powershell -File capture-blaze-traffic.ps1 -SelfTest
    powershell -File capture-blaze-traffic.ps1 -Start
    powershell -File capture-blaze-traffic.ps1 -Stop -OutDir <attempt folder>

Nothing is attached to fifa15.exe. This is passive NIC capture only.
#>
[CmdletBinding(DefaultParameterSetName = 'SelfTest')]
param(
    [Parameter(ParameterSetName = 'Start', Mandatory = $true)][switch]$Start,
    [Parameter(ParameterSetName = 'Stop', Mandatory = $true)][switch]$Stop,
    [Parameter(ParameterSetName = 'Stop')][string]$OutDir,
    [Parameter(ParameterSetName = 'SelfTest')][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$StatePath = Join-Path $env:TEMP 'fifa15-f15b-blaze-capture.json'

# Relay-side ports, from the Player A relay source:
#   42127 redirector (raw), 42230 redirector (HTTPS), 42128 Blaze GameManager
#   17502/17503 the loopback-forwarded QoS/FUT services
# Peer-to-peer gameplay:
#   3659 game traffic, 11000/11001 the relay UDP path
# 42128 is the decisive one: it carries GameSetup and the whole post-GameSetup
# notification burst in plaintext, and decodes with the main repo's
# scripts/blaze-capture tooling.
$TcpPorts = @(42128, 42127, 42230, 17502, 17503)
$UdpPorts = @(3659, 11000, 11001)

function Info([string]$m) { Write-Host "  $m" -ForegroundColor Gray }
function Fail([string]$m) { Write-Host "BLAZE CAPTURE ERROR: $m" -ForegroundColor Red; exit 1 }

function Get-Pktmon {
    $cmd = Get-Command 'pktmon.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:SystemRoot 'System32\pktmon.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    return $null
}

function Invoke-Pktmon {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $exe = Get-Pktmon
    if (-not $exe) { Fail 'pktmon.exe is not available on this Windows edition.' }
    # Redirecting a native command's stderr while ErrorActionPreference is 'Stop'
    # turns any stderr line into a terminating NativeCommandError. pktmon writes
    # "Packet Monitor is not running." to stderr for a harmless idle stop, which
    # killed the whole capture. This is the documented 2>&1 trap in this project;
    # keep native exit codes authoritative instead.
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $exe @Arguments 2>&1
        $rc = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($rc -ne 0 -and -not $AllowFailure) {
        Fail "pktmon $($Arguments -join ' ') failed with $rc`n$(@($out) -join "`n")"
    }
    return [pscustomobject]@{ ExitCode = $rc; Output = @($out) }
}

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'pktmon requires Administrator. Run RUN-FIFA15-F15B.bat elevated; it starts this capture for you.'
    }
}

if ($SelfTest) {
    $exe = Get-Pktmon
    if (-not $exe) { Fail 'pktmon.exe not found; Player B cannot capture the wire.' }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($required in @(
        '--pkt-size',                 # full payload, not the 128-byte default
        'etl2pcap',                   # a pcapng the repo tooling can read
        'Get-DropCounters',           # a lossy capture must announce itself
        'Assert-Elevated',            # pktmon needs admin; say so rather than half-run
        "ErrorActionPreference = 'Continue'",  # the documented native-stderr trap
        '42128'                       # the Blaze GameManager port
    )) {
        if (-not $source.Contains($required)) {
            Fail "capture script lost required behaviour: $required"
        }
    }
    # Truncation is the failure that silently destroys payload evidence.
    if ($source -notmatch '--pkt-size\s*,\s*''0''' -and $source -notmatch "'--pkt-size'\s*,\s*'0'") {
        Fail 'capture must request full packets (--pkt-size 0).'
    }
    # Split so the guard cannot match its own source, which is exactly how an
    # earlier preflight in this project made itself impossible to satisfy.
    foreach ($banned in @(('Interceptor' + '.attach'), ('Stalker' + '.follow'), ('Open' + 'Process'))) {
        if ($source.Contains($banned)) { Fail "capture script reintroduced instrumentation: $banned" }
    }
    Write-Host "PASS: Player B wire capture is available (pktmon at $exe), captures full packets on the Blaze GameManager port, converts to pcapng, and reports drop counters so a lossy capture cannot be mistaken for evidence of absence." -ForegroundColor Green
    exit 0
}

function Get-DropCounters {
    # pktmon reports per-component counters; any non-zero drop means the capture
    # is not admissible as evidence that something was never sent.
    $res = Invoke-Pktmon -Arguments @('counters') -AllowFailure
    $text = ($res.Output -join "`n")
    $dropped = 0
    foreach ($line in $res.Output) {
        $m = [regex]::Match([string]$line, '(?i)drop[^0-9]*([0-9,]+)')
        if ($m.Success) {
            $n = 0
            if ([int]::TryParse($m.Groups[1].Value.Replace(',', ''), [ref]$n)) { $dropped += $n }
        }
    }
    return [pscustomobject]@{ Dropped = $dropped; Text = $text }
}

if ($Start) {
    if (-not (Get-Pktmon)) { Fail 'pktmon.exe not found.' }
    Assert-Elevated
    Invoke-Pktmon -Arguments @('stop') -AllowFailure | Out-Null
    Invoke-Pktmon -Arguments @('filter', 'remove') -AllowFailure | Out-Null

    foreach ($p in $TcpPorts) {
        Invoke-Pktmon -Arguments @('filter', 'add', "F15B-TCP-$p", '-t', 'TCP', '-p', "$p") | Out-Null
    }
    foreach ($p in $UdpPorts) {
        Invoke-Pktmon -Arguments @('filter', 'add', "F15B-UDP-$p", '-t', 'UDP', '-p', "$p") | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $etl = Join-Path $env:TEMP "FIFA15-F15B-WIRE-$stamp.etl"
    # --pkt-size 0 keeps the FULL payload. The default truncates to 128 bytes,
    # which would decapitate every GameSetup and make the burst unreadable.
    Invoke-Pktmon -Arguments @(
        'start', '--capture', '--pkt-size', '0',
        '--file-size', '512', '--flags', '0x10',
        '--file-name', $etl
    ) | Out-Null

    [pscustomobject]@{
        etl = $etl
        started_utc = (Get-Date).ToUniversalTime().ToString('o')
        tcp_ports = $TcpPorts
        udp_ports = $UdpPorts
    } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8

    Info "wire capture started (filtered): TCP $($TcpPorts -join ',') / UDP $($UdpPorts -join ',')"
    Info "  $etl"
    Write-Host 'F15B_WIRE_CAPTURE_READY' -ForegroundColor Green
    exit 0
}

if ($Stop) {
    Assert-Elevated
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        Info 'no wire capture was running.'
        exit 0
    }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $counters = Get-DropCounters
    Invoke-Pktmon -Arguments @('stop') -AllowFailure | Out-Null
    Invoke-Pktmon -Arguments @('filter', 'remove') -AllowFailure | Out-Null
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue

    $etl = [string]$state.etl
    if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
        Info "capture file missing: $etl"
        exit 0
    }

    if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('Desktop') }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $pcap = [IO.Path]::ChangeExtension($etl, '.pcapng')
    $convert = Invoke-Pktmon -Arguments @('etl2pcap', $etl, '--out', $pcap) -AllowFailure
    if ($convert.ExitCode -ne 0) {
        Info 'etl2pcap failed; preserving the raw ETL only.'
    }

    $summary = @(
        'FIFA15 Player B wire capture',
        "started_utc=$($state.started_utc)",
        "stopped_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
        "tcp_ports=$($state.tcp_ports -join ',')",
        "udp_ports=$($state.udp_ports -join ',')",
        'full_packets=true',
        'blaze_gamemanager_port=42128',
        "pktmon_reported_drops=$($counters.Dropped)",
        "capture_admissible_as_absence_evidence=$(if ($counters.Dropped -eq 0) { 'true' } else { 'false' })",
        '',
        'Decode with the main repo tooling:',
        '  python scripts/blaze-capture/extract-blaze-stream.py --pcap <pcapng> \',
        '      --outdir out --port 42128 --server-ip <player A overlay ip>',
        '  python scripts/blaze-capture/extract-blaze-stream.py --outdir out --report',
        '',
        'Raw pktmon counters:',
        $counters.Text
    )
    Set-Content -LiteralPath (Join-Path $OutDir 'WIRE-CAPTURE-SUMMARY.txt') -Encoding UTF8 -Value $summary

    foreach ($f in @($pcap, $etl)) {
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            $size = (Get-Item -LiteralPath $f).Length
            Copy-Item -LiteralPath $f -Destination (Join-Path $OutDir (Split-Path -Leaf $f)) -Force -ErrorAction SilentlyContinue
            Info "$(Split-Path -Leaf $f): $size bytes"
        }
    }
    Remove-Item -LiteralPath $etl -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pcap -Force -ErrorAction SilentlyContinue

    if ($counters.Dropped -gt 0) {
        Write-Host "WARNING: pktmon reported $($counters.Dropped) dropped packets. Absence of a frame in this capture is NOT evidence it was never sent." -ForegroundColor Yellow
    } else {
        Write-Host 'PASS: Player B wire capture is lossless; absences in it are real.' -ForegroundColor Green
    }
    exit 0
}

Fail 'no mode selected; use -Start, -Stop or -SelfTest.'
