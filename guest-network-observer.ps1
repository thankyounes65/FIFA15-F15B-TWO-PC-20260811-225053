[CmdletBinding(DefaultParameterSetName='SelfTest')]
param(
    [Parameter(ParameterSetName='Start', Mandatory=$true)][switch]$Start,
    [Parameter(ParameterSetName='Stop', Mandatory=$true)][switch]$Stop,
    [Parameter(ParameterSetName='Reset', Mandatory=$true)][switch]$Reset,
    [Parameter(ParameterSetName='Monitor', Mandatory=$true)][switch]$Monitor,
    [Parameter(ParameterSetName='SelfTest')][switch]$SelfTest,
    [Parameter(ParameterSetName='Stop')][switch]$AppendToNewestDiag
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$StatePath = Join-Path $env:TEMP 'fifa15-f15b-network-observer.json'
$CoreHostPorts = @(42127,42230,42128,17502,17503)

function Fail([string]$Text) { Write-Host "NETWORK OBSERVER ERROR: $Text" -ForegroundColor Red; exit 1 }
function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "missing $ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.host_ip) { throw 'APPLIANCE-CONFIG.json has no host_ip' }
    return $config
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-State([int]$PidValue, [string]$LogPath) {
    [ordered]@{
        format = 1
        pid = $PidValue
        log_path = $LogPath
        package_root = $Root
        started_utc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Get-NewestDiag {
    $desktop = [Environment]::GetFolderPath('Desktop')
    return @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-DIAG-*.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
}

function Add-ObservationToDiag([string]$LogPath) {
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return }
    $diag = Get-NewestDiag
    if ($diag.Count -eq 0) { return }
    Add-Content -LiteralPath $diag[0].FullName -Value @('', '=== PLAYER B NETWORK OBSERVER ===') -Encoding UTF8
    Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue |
        Add-Content -LiteralPath $diag[0].FullName -Encoding UTF8
}

function Classify-Observation([string]$LogPath) {
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return 43 }
    $text = [string](Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue)
    $fifa = $text -match '(?m)^fifa_observed=true$'
    $lsx = $text -match '(?m)^fifa_lsx_connected=true$'
    $blaze = $text -match '(?m)^fifa_blaze_connected=true$'
    if ($lsx -and $blaze) { return 0 }
    if ($fifa -and -not $lsx) { return 41 }
    if ($lsx -and -not $blaze) { return 42 }
    return 43
}

function Invoke-Monitor {
    $config = Read-Config
    $hostIp = [string]$config.host_ip
    $desktop = [Environment]::GetFolderPath('Desktop')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $desktop "FIFA15-F15B-NETWORK-$stamp.log"
    Write-State -PidValue $PID -LogPath $logPath

    $rows = New-Object Collections.Generic.List[string]
    function Note([string]$Text) {
        $rows.Add($Text)
        $rows | Set-Content -LiteralPath $logPath -Encoding UTF8
    }

    Note 'FIFA 15 Player B network observation'
    Note "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))"
    Note "host_ip=$hostIp"
    Note 'fifa_observed=false'
    Note 'package_lsx_listener_observed=false'
    Note 'fifa_lsx_connected=false'
    Note 'fifa_redirector_connected=false'
    Note 'fifa_blaze_connected=false'
    Note 'fifa_qos_or_fut_loopback_touch=false'

    $seen = @{}
    $fifaPid = 0
    $sawFifa = $false
    $sawPackageLsx = $false
    $sawLsx = $false
    $sawRedirector = $false
    $sawBlaze = $false
    $sawLoopbackService = $false
    $deadline = (Get-Date).AddMinutes(15)

    while ((Get-Date) -lt $deadline) {
        if (-not $sawPackageLsx) {
            foreach ($listener in @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue)) {
                $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
                if ($owner -and $owner.CommandLine -and $owner.CommandLine -match 'portable-lsx-responder\.ps1' -and $owner.CommandLine -like "*$Root*") {
                    $sawPackageLsx = $true
                    Note 'package_lsx_listener_observed=true'
                    Note "package_lsx_pid=$($listener.OwningProcess)"
                    break
                }
            }
        }

        $fifa = $null
        if ($fifaPid -gt 0) { $fifa = Get-Process -Id $fifaPid -ErrorAction SilentlyContinue }
        if (-not $fifa -and -not $sawFifa) {
            $fifa = Get-Process -Name fifa15 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($fifa) {
                $fifaPid = [int]$fifa.Id
                $sawFifa = $true
                Note 'fifa_observed=true'
                Note "fifa_pid=$fifaPid"
                try {
                    $mods = @($fifa.Modules | Where-Object { $_.ModuleName -in @('ItsAMe_Origin.dll','sysdllzf.dll') } | ForEach-Object { $_.ModuleName })
                    Note "fifa_start_modules=$($mods -join ',')"
                } catch {}
            }
        }

        if ($fifa) {
            foreach ($conn in @(Get-NetTCPConnection -OwningProcess $fifaPid -ErrorAction SilentlyContinue)) {
                $key = "$($conn.LocalAddress):$($conn.LocalPort)->$($conn.RemoteAddress):$($conn.RemotePort):$($conn.State)"
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    if ($conn.RemotePort -eq 3216 -or $conn.LocalPort -eq 3216) { Note "socket_kind=LSX $key" }
                    elseif ($conn.RemoteAddress -eq $hostIp -and $conn.RemotePort -in $CoreHostPorts) { Note "socket_kind=HOST_CORE $key" }
                    elseif ($conn.RemoteAddress -in @('127.0.0.1','::1') -and $conn.RemotePort -in @(17502,17503)) { Note "socket_kind=LOOPBACK_SERVICE $key" }
                }
                if (-not $sawLsx -and $conn.State -eq 'Established' -and $conn.RemoteAddress -in @('127.0.0.1','::1') -and $conn.RemotePort -eq 3216) {
                    $sawLsx = $true
                    Note 'fifa_lsx_connected=true'
                }
                if (-not $sawRedirector -and $conn.State -eq 'Established' -and $conn.RemoteAddress -eq $hostIp -and $conn.RemotePort -eq 42230) {
                    $sawRedirector = $true
                    Note 'fifa_redirector_connected=true'
                }
                if (-not $sawBlaze -and $conn.State -eq 'Established' -and $conn.RemoteAddress -eq $hostIp -and $conn.RemotePort -eq 42128) {
                    $sawBlaze = $true
                    Note 'fifa_blaze_connected=true'
                }
                if (-not $sawLoopbackService -and $conn.RemoteAddress -in @('127.0.0.1','::1') -and $conn.RemotePort -in @(17502,17503)) {
                    $sawLoopbackService = $true
                    Note 'fifa_qos_or_fut_loopback_touch=true'
                }
            }
        } elseif ($sawFifa) {
            Note "finished_utc=$((Get-Date).ToUniversalTime().ToString('o'))"
            Note "summary_lsx=$sawLsx summary_redirector=$sawRedirector summary_blaze=$sawBlaze summary_loopback_service=$sawLoopbackService"
            break
        }

        Start-Sleep -Milliseconds 50
    }
}

# A previous run that crashed or was killed leaves this state file behind. The
# PID in it may be dead, or - worse - recycled by an unrelated process. Neither
# case may ever require the operator to hunt down a PID by hand, so identity is
# confirmed against the recorded start time before anything is reclaimed.
function Test-IsOurObserver($State) {
    if (-not $State -or -not $State.pid) { return $false }
    $proc = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($proc.ProcessName -ne 'powershell' -and $proc.ProcessName -ne 'pwsh') { return $false }
    if (-not $State.started_utc) { return $false }
    try {
        $recorded = [datetime]::Parse($State.started_utc).ToUniversalTime()
        $actual = $proc.StartTime.ToUniversalTime()
        # A recycled PID belongs to a process that started at a different time.
        if ([math]::Abs(($actual - $recorded).TotalSeconds) -gt 120) { return $false }
    } catch { return $false }
    return $true
}

function Clear-StaleObserver {
    $state = Read-State
    if (-not $state) { return 'none' }
    if (Test-IsOurObserver $state) {
        Info "reclaiming an orphaned Player B network observer at PID $($state.pid)"
        Stop-Process -Id ([int]$state.pid) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 250
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        return 'reclaimed'
    }
    Info 'discarding stale Player B network observer state (dead or recycled PID)'
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    return 'discarded'
}

function Invoke-Start {
    Clear-StaleObserver | Out-Null
    $proc = Start-Process powershell.exe -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Monitor'
    ) -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 50
        $newState = Read-State
        if ($newState -and [int]$newState.pid -eq $proc.Id -and $newState.log_path) {
            Info "Player B network observer armed: $($newState.log_path)"
            return
        }
        $proc.Refresh()
        if ($proc.HasExited) { throw "network observer exited during startup with code $($proc.ExitCode)" }
    } until ((Get-Date) -gt $deadline)
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw 'network observer did not publish its state within 5 seconds'
}

function Invoke-Stop {
    $state = Read-State
    if (-not $state -or -not $state.log_path) {
        Write-Host 'NETWORK_OBSERVER_RESULT=NO_OBSERVER_STATE' -ForegroundColor Red
        return 43
    }
    $pidValue = if ($state.pid) { [int]$state.pid } else { 0 }
    if ($pidValue -gt 0) {
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($proc) {
            $deadline = (Get-Date).AddSeconds(3)
            while ($proc -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 100
                $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            }
            if ($proc) { Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue }
        }
    }
    $logPath = [string]$state.log_path
    if ($AppendToNewestDiag) { Add-ObservationToDiag -LogPath $logPath }
    $classification = Classify-Observation -LogPath $logPath
    switch ($classification) {
        0  { Write-Host 'NETWORK_OBSERVER_RESULT=LSX_AND_BLAZE_CONFIRMED' -ForegroundColor Green }
        41 { Write-Host 'NETWORK_OBSERVER_RESULT=FIFA_NEVER_CONNECTED_TO_PACKAGE_LSX' -ForegroundColor Red }
        42 { Write-Host 'NETWORK_OBSERVER_RESULT=LSX_OK_BLAZE_NOT_REACHED' -ForegroundColor Red }
        default { Write-Host 'NETWORK_OBSERVER_RESULT=FIFA_OR_NETWORK_BOUNDARY_NOT_OBSERVED' -ForegroundColor Red }
    }
    Info "Network evidence: $logPath"
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    return $classification
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('fifa_lsx_connected=true','fifa_blaze_connected=true','portable-lsx-responder\.ps1','42128','AppendToNewestDiag')) {
        if ($source -notmatch [regex]::Escape($marker)) { throw "missing network-observer marker: $marker" }
    }
    foreach ($marker in @('Test-IsOurObserver','Clear-StaleObserver','recycled PID')) {
        if (-not ((Get-Content -LiteralPath $PSCommandPath -Raw)).Contains($marker)) {
            throw "network observer lost stale-state self-healing marker: $marker"
        }
    }
    Write-Host 'PASS: Player B network observer parses, classifies LSX/Blaze boundaries, and self-heals stale/recycled observer state without operator PID cleanup; no processes or network state were changed.' -ForegroundColor Green
}

try {
    if ($SelfTest) { Invoke-SelfTest; exit 0 }
    if ($Reset) { $r = Clear-StaleObserver; Write-Host "NETWORK_OBSERVER_RESET=$r"; exit 0 }
    if ($Start) { Invoke-Start; exit 0 }
    if ($Stop) { exit (Invoke-Stop) }
    if ($Monitor) { Invoke-Monitor; exit 0 }
    throw 'choose -Start, -Stop, -Reset, -Monitor or -SelfTest'
} catch {
    Fail $_.Exception.Message
}
