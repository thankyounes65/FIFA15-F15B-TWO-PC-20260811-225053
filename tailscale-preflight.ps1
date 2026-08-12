[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'

function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Pass([string]$Text) { Write-Host "  PASS: $Text" -ForegroundColor Green }
function Fail([string]$Code, [string]$Text) {
    Write-Host ''
    Write-Host "STOP [$Code]: $Text" -ForegroundColor Red
    exit 1
}

function Find-Tailscale {
    foreach ($path in @("$env:ProgramFiles\Tailscale\tailscale.exe", "$env:ProgramFiles(x86)\Tailscale\tailscale.exe")) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Invoke-TailscaleCli {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )
    $token = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $env:TEMP "fifa15-ts-$token.out.txt"
    $stderrPath = Join-Path $env:TEMP "fifa15-ts-$token.err.txt"
    try {
        $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Stdout = [string]$stdout
            Stderr = [string]$stderr
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-TailscaleCgnatIp([string]$Ip) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $parsed.GetAddressBytes()
    return ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127)
}

function Test-StatusContainsHost([string]$StatusText, [string]$HostIp) {
    if (-not $StatusText -or -not $HostIp) { return $false }
    $escaped = [regex]::Escape($HostIp)
    foreach ($line in ($StatusText -split "`r?`n")) {
        if ($line -match "^\s*$escaped(?:\s|$)") { return $true }
    }
    return $false
}

function Read-HostIp {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Fail 'PACKAGE_CONFIG_MISSING' "Missing APPLIANCE-CONFIG.json: $ConfigPath"
    }
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch {
        Fail 'PACKAGE_CONFIG_INVALID' "APPLIANCE-CONFIG.json could not be parsed: $($_.Exception.Message)"
    }
    $hostIp = [string]$config.host_ip
    if (-not (Test-TailscaleCgnatIp $hostIp)) {
        Fail 'HOST_IP_INVALID' "Configured host address '$hostIp' is not a Tailscale IPv4 address in 100.64.0.0/10."
    }
    return $hostIp
}

function Invoke-SelfTest {
    Write-Host 'Tailscale preflight self-test (no network or machine changes)' -ForegroundColor Cyan
    if (-not (Test-StatusContainsHost '100.91.142.54 host user windows idle' '100.91.142.54')) {
        throw 'status parser failed to recognize the configured host'
    }
    if (Test-StatusContainsHost '100.64.1.2 another-host user windows idle' '100.91.142.54') {
        throw 'status parser falsely recognized an unrelated peer'
    }
    if (-not (Test-TailscaleCgnatIp '100.91.142.54')) { throw 'CGNAT validator rejected a valid Tailscale address' }
    if (Test-TailscaleCgnatIp '192.168.1.5') { throw 'CGNAT validator accepted a non-Tailscale address' }
    [void](Read-HostIp)
    Pass 'shared-host parser and package host address checks passed.'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch {
        Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$hostIp = Read-HostIp
$tailscale = Find-Tailscale
if (-not $tailscale) {
    Info 'Tailscale is not installed. The main launcher may install it and use the private JOIN.key path.'
    exit 0
}

$ipResult = Invoke-TailscaleCli -Exe $tailscale -Arguments @('ip','-4')
$localIp = @($ipResult.Stdout -split "`r?`n" | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
if ($localIp.Count -eq 0 -or -not $localIp[0]) {
    Fail 'TAILSCALE_NOT_CONNECTED' 'Tailscale is already installed but is not connected. Do not sign into thankyounes account. Connect your own Tailscale account first, then accept the shared-machine invite and rerun this BAT.'
}
$localIp = $localIp[0].Trim()
Info "Existing Tailscale connection: $localIp"

$statusResult = Invoke-TailscaleCli -Exe $tailscale -Arguments @('status')
if ($statusResult.ExitCode -ne 0) {
    $detail = (($statusResult.Stderr + ' ' + $statusResult.Stdout).Trim())
    Fail 'TAILSCALE_STATUS_FAILED' "Could not inspect the existing Tailscale peer list. $detail"
}

if (-not (Test-StatusContainsHost -StatusText $statusResult.Stdout -HostIp $hostIp)) {
    Fail 'TAILSCALE_HOST_NOT_SHARED' "This PC is connected to its own Tailscale account, but thankyounes host $hostIp is not visible in 'tailscale status'. Stay signed into your own account. Accept the Tailscale machine-share invite for thankyounes host, then rerun RUN-FIFA15-F15B.bat. No network settings were changed."
}
Pass "thankyounes host $hostIp is visible in this PC's Tailscale peer list."

$pingResult = Invoke-TailscaleCli -Exe $tailscale -Arguments @('ping','--c=1','--timeout=5s','--until-direct=false',$hostIp)
if ($pingResult.ExitCode -eq 0) {
    $line = @($pingResult.Stdout -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Count -gt 0) { Pass "Tailscale tunnel reached host: $($line[0].Trim())" }
    else { Pass 'Tailscale tunnel reached the shared host.' }
} else {
    Write-Host '  WARNING: the host is shared/visible but a Tailscale ping did not complete yet.' -ForegroundColor Yellow
    Write-Host '  The launcher will still wait for the host readiness beacon; this can be normal if the host PC is still coming online.' -ForegroundColor Yellow
}

exit 0
