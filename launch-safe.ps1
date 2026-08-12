[CmdletBinding()]
param(
    [switch]$Cleanup,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$SafeRun = Join-Path $Root 'safe-run.ps1'
$JoinKey = Join-Path $Root 'JOIN.key'
$HeldKey = Join-Path $Root 'JOIN.key.not-used-with-existing-tailscale'
$EaGuardRevision = 'startup-evidence-v3'

function Find-Tailscale {
    foreach ($path in @("$env:ProgramFiles\Tailscale\tailscale.exe", "$env:ProgramFiles(x86)\Tailscale\tailscale.exe")) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Has-ExistingTailscaleConnection {
    $tailscale = Find-Tailscale
    if (-not $tailscale) { return $false }
    $ip = @(& $tailscale ip -4 2>$null) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    return [bool]$ip
}

function Restore-HeldKey {
    if ((Test-Path -LiteralPath $HeldKey) -and -not (Test-Path -LiteralPath $JoinKey)) {
        Move-Item -LiteralPath $HeldKey -Destination $JoinKey -Force
        Write-Host '  Restored temporarily quarantined JOIN.key to its original package name.' -ForegroundColor Gray
    } elseif ((Test-Path -LiteralPath $HeldKey) -and (Test-Path -LiteralPath $JoinKey)) {
        throw 'Both JOIN.key and its quarantined copy exist. Cleanup will not guess which one is authoritative.'
    }
}

function Start-KnownGoodEaCompatibilityGuard {
    return Start-Job -ArgumentList $Root,$EaGuardRevision -ScriptBlock {
        param([string]$PackageRoot,[string]$Revision)
        $ErrorActionPreference = 'Continue'

        function Emit-EaEnvironment([string]$Phase) {
            $eaNames = @(
                'EADesktop.exe','EABackgroundService.exe','EALocalHostSvc.exe',
                'EALauncher.exe','EALaunchHelper.exe','EAConnect_microsoft.exe',
                'EACefSubProcess.exe','IGOProxy32.exe','IGOProxy64.exe','ActivationUI.exe'
            )
            $rows = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in $eaNames } |
                Sort-Object Name,ProcessId)
            $cefCount = @($rows | Where-Object { $_.Name -eq 'EACefSubProcess.exe' }).Count
            $localHostCount = @($rows | Where-Object { $_.Name -eq 'EALocalHostSvc.exe' }).Count
            $igoCount = @($rows | Where-Object { $_.Name -in @('IGOProxy32.exe','IGOProxy64.exe') }).Count
            Write-Output "EA_ENV phase=$Phase total=$($rows.Count) cef=$cefCount localhost=$localHostCount igo=$igoCount"
            foreach ($row in $rows) {
                $path = if ($row.ExecutablePath) { [string]$row.ExecutablePath } else { '<unknown>' }
                $cmd = if ($row.CommandLine) { ([string]$row.CommandLine -replace '[\r\n]+',' ') } else { '<unknown>' }
                if ($cmd.Length -gt 300) { $cmd = $cmd.Substring(0,300) + '...' }
                Write-Output "EA_PROCESS phase=$Phase name=$($row.Name) pid=$($row.ProcessId) parent=$($row.ParentProcessId) path=$path cmd=$cmd"
            }
            $desktop = $rows | Where-Object { $_.Name -eq 'EADesktop.exe' -and $_.ExecutablePath } | Select-Object -First 1
            if ($desktop -and (Test-Path -LiteralPath $desktop.ExecutablePath -PathType Leaf)) {
                try {
                    $vi = (Get-Item -LiteralPath $desktop.ExecutablePath).VersionInfo
                    Write-Output "EA_DESKTOP_VERSION phase=$Phase file=$($vi.FileVersion) product=$($vi.ProductVersion)"
                } catch {}
            }
        }

        function Emit-StartupFileFingerprint([string]$GameDir) {
            if (-not $GameDir -or -not (Test-Path -LiteralPath $GameDir -PathType Container)) {
                Write-Output 'FILE_FINGERPRINT unavailable: game directory could not be resolved.'
                return
            }
            Write-Output "FILE_FINGERPRINT_BEGIN game_dir=$GameDir"
            $referenceHashes = @{
                'bcenginezf.dll'='009E8936E4E79499E189FE4A4E821B283FF8E830BE697F5E55873677BB4C3B01'
                'd3dcompiler_46.dll'='9614DE7BAC24091E2ABAF70B3C852DDF9B92A48157C557C3C63D81D88D4D5CEB'
                'dbdata.dll'='FDDB8D45464CEF3FF089609DC71342D347AF62A36FB1E4AE8A75FBCA33DF88BF'
                'itsame_origin.dll'='5B141FB03C6F50228E48DDAF8DFB49428194A1F01BE1A63C826C5BCE4DEC487A'
                'originsetup.exe'='EC0765A1F39E55A39E378150270F39E90C93ADEE59272B947011232C3CED524D'
                'winui.dll'='B4B1935EE76F434685F0515B0E5DFC18ADFD2DAEAE50F32EF85EC6FFAAADE63C'
            }
            $names = @(
                'BCEnginezf.dll','buttonData.ini','buttonDataKeyBoardMouse.ini','buttonDataXenon.ini',
                'CardsDLLzf.dll','CPY.ini','d3dcompiler_46.dll','dbdata.dll','fifa15.par','install.ini',
                'ItsAMe_Origin.dll','memoryfw.ini','memoryfw_postboot.ini','OriginSetup.exe','OriginSetup.ini',
                'sysdllzf.dll','winui.dll'
            )
            foreach ($name in $names) {
                $path = Join-Path $GameDir $name
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    Write-Output "FILE_FINGERPRINT name=$name status=MISSING"
                    continue
                }
                try {
                    $item = Get-Item -LiteralPath $path
                    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                    $key = $name.ToLowerInvariant()
                    $reference = if ($referenceHashes.ContainsKey($key)) { $referenceHashes[$key] } else { $null }
                    $compare = if ($reference) {
                        if ($hash.Equals($reference,[StringComparison]::OrdinalIgnoreCase)) { 'MATCH_KNOWN_WORKING' } else { 'DIFF_KNOWN_WORKING' }
                    } elseif ($key -eq 'sysdllzf.dll') {
                        if ($hash -eq 'AE283399CA945FE910F819D61101A527A744753F6E0C46406C324C8721EE63F5') { 'KNOWN_WORKING_LOGGING_ENABLED' }
                        elseif ($hash -eq 'B477BACB277F43A9C93C4E4D8B47E1F0F8B6B2E9751A218448B8D1B17A5DCF87') { 'KNOWN_ORIGINAL_LOGGING_DISABLED' }
                        else { 'UNKNOWN_VARIANT' }
                    } else { 'NO_REFERENCE_HASH_YET' }
                    Write-Output "FILE_FINGERPRINT name=$name bytes=$($item.Length) sha256=$hash compare=$compare"
                } catch {
                    Write-Output "FILE_FINGERPRINT name=$name status=READ_ERROR error=$($_.Exception.Message)"
                }
            }
            Write-Output 'FILE_FINGERPRINT_END'
        }

        Write-Output "EA_COMPAT_GUARD_READY revision=$Revision package_root=$PackageRoot"
        Write-Output 'EA_COMPAT_GUARD: waiting for package LSX ownership of 127.0.0.1:3216.'

        $lsxOwner = $null
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline -and -not $lsxOwner) {
            $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($listener) {
                $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
                if ($proc -and $proc.CommandLine -and $proc.CommandLine -match 'portable-lsx-responder\.ps1' -and $proc.CommandLine -like "*$PackageRoot*") {
                    $lsxOwner = [int]$listener.OwningProcess
                    break
                }
            }
            Start-Sleep -Milliseconds 25
        }

        if (-not $lsxOwner) {
            Write-Output 'EA_COMPAT_GUARD: package LSX ownership was not observed before timeout; service state was not changed.'
            return
        }
        Write-Output "EA_COMPAT_GUARD: package LSX confirmed on 3216 pid=$lsxOwner."

        $svc = Get-Service -Name EABackgroundService -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Output 'EA_COMPAT_GUARD: EABackgroundService is not installed; cannot reproduce the known-good EA state.'
            return
        }
        try {
            if ($svc.Status -ne 'Running') {
                Start-Service -Name EABackgroundService -ErrorAction Stop
                $svc.WaitForStatus('Running',[TimeSpan]::FromSeconds(15))
                $svc.Refresh()
            }
        } catch {
            Write-Output "EA_COMPAT_GUARD: failed to start EABackgroundService: $($_.Exception.Message)"
            return
        }
        Write-Output "EA_COMPAT_GUARD: EABackgroundService status=$($svc.Status) before FIFA launch."

        Start-Sleep -Milliseconds 100
        $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $listener -or [int]$listener.OwningProcess -ne $lsxOwner) {
            $newOwner = if ($listener) { [int]$listener.OwningProcess } else { 0 }
            Write-Output "EA_COMPAT_GUARD: ERROR LSX lost 3216 after starting EABackgroundService; expected=$lsxOwner actual=$newOwner."
            return
        }
        Write-Output "EA_COMPAT_GUARD: PASS EABackgroundService running while package LSX still owns 3216 pid=$lsxOwner."
        Emit-EaEnvironment 'pre-fifa'

        $fifa = $null
        $fifaDeadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $fifaDeadline -and -not $fifa) {
            $fifa = Get-Process -Name fifa15 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $fifa) { Start-Sleep -Milliseconds 10 }
        }
        if (-not $fifa) {
            Write-Output 'EA_COMPAT_GUARD: fifa15.exe was not observed after the known-good EA state was established.'
            return
        }

        $pidValue = [int]$fifa.Id
        $fifaCim = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
        $gameDir = $null
        if ($fifaCim -and $fifaCim.ExecutablePath) { $gameDir = Split-Path -Parent ([string]$fifaCim.ExecutablePath) }
        $parentPid = if ($fifaCim) { [int]$fifaCim.ParentProcessId } else { 0 }
        $parent = if ($parentPid -gt 0) { Get-CimInstance Win32_Process -Filter "ProcessId=$parentPid" -ErrorAction SilentlyContinue } else { $null }
        $parentName = if ($parent) { [string]$parent.Name } else { '<unknown>' }
        $parentPath = if ($parent -and $parent.ExecutablePath) { [string]$parent.ExecutablePath } else { '<unknown>' }
        Write-Output "STARTUP_CONTEXT fifa_pid=$pidValue parent_pid=$parentPid parent_name=$parentName parent_path=$parentPath game_dir=$gameDir"
        Emit-EaEnvironment 'fifa-observed'
        Write-Output "EA_COMPAT_GUARD: observed fifa15 pid=$pidValue; sampling early modules and sockets."

        $seenConnections = @{}
        $lastMs = 0
        foreach ($sampleMs in @(0,25,50,75,100,125,150,175,200,225,250,500,1000)) {
            if ($sampleMs -gt $lastMs) { Start-Sleep -Milliseconds ($sampleMs - $lastMs) }
            $lastMs = $sampleMs
            $procNow = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            $alive = [bool]$procNow
            $modules = @()
            if ($procNow -and $sampleMs -in @(0,50,100,250,500,1000)) {
                try {
                    $modules = @($procNow.Modules | Where-Object { $_.ModuleName -in @('ItsAMe_Origin.dll','sysdllzf.dll') } | ForEach-Object { $_.ModuleName })
                } catch {}
            }
            if ($procNow) {
                foreach ($conn in @(Get-NetTCPConnection -OwningProcess $pidValue -ErrorAction SilentlyContinue)) {
                    $key = "$($conn.LocalAddress):$($conn.LocalPort)->$($conn.RemoteAddress):$($conn.RemotePort):$($conn.State)"
                    if (-not $seenConnections.ContainsKey($key)) {
                        $seenConnections[$key] = $true
                        $kind = if ($conn.RemotePort -eq 3216 -or $conn.LocalPort -eq 3216) { 'LSX_TOUCH' }
                            elseif ($conn.RemotePort -in @(42127,42230,42128,17502,17503)) { 'RELAY_TOUCH' }
                            else { 'OTHER_TCP' }
                        Write-Output "STARTUP_TCP kind=$kind t=${sampleMs}ms $key"
                    }
                }
            }
            $serviceNow = Get-Service -Name EABackgroundService -ErrorAction SilentlyContinue
            $serviceStatus = if ($serviceNow) { [string]$serviceNow.Status } else { '<missing>' }
            if ($sampleMs -in @(0,50,100,250,500,1000)) {
                Write-Output "EA_COMPAT sample t=${sampleMs}ms alive=$alive service=$serviceStatus modules=$($modules -join ',')"
            }
            if (-not $alive) { break }
        }

        $lsxTouch = @($seenConnections.Keys | Where-Object { $_ -match ':3216' }).Count -gt 0
        $relayTouch = @($seenConnections.Keys | Where-Object { $_ -match ':(42127|42230|42128|17502|17503):' }).Count -gt 0
        Write-Output "STARTUP_EVIDENCE_SUMMARY fifa_pid=$pidValue lsx_touch=$lsxTouch relay_touch=$relayTouch connection_count=$($seenConnections.Count)"
        Emit-StartupFileFingerprint $gameDir
    }
}

function Wait-EaCompatibilityGuardReady($Job) {
    if (-not $Job) { throw 'EA compatibility guard job was not created.' }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $rows = @(Receive-Job -Job $Job -Keep -ErrorAction SilentlyContinue)
        if (@($rows | Where-Object { [string]$_ -match '^EA_COMPAT_GUARD_READY ' }).Count -gt 0) {
            Write-Host "  EA compatibility guard is actively watching before the safe runner starts ($EaGuardRevision)." -ForegroundColor Gray
            return
        }
        if ($Job.State -eq 'Failed') {
            throw 'EA compatibility guard failed before the safe runner started.'
        }
        Start-Sleep -Milliseconds 50
    }
    throw 'EA compatibility guard did not become ready before the safe runner; FIFA was not started.'
}

function Stop-AndReportEaCompatibilityGuard($Job) {
    if (-not $Job) { return }
    try {
        Wait-Job -Job $Job -Timeout 10 | Out-Null
        Receive-Job -Job $Job -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    } finally {
        Stop-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "SELF-TEST FAILED: $((@($errors | ForEach-Object Message)) -join '; ')" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path -LiteralPath $SafeRun -PathType Leaf)) {
        Write-Host 'SELF-TEST FAILED: missing safe-run.ps1' -ForegroundColor Red
        exit 1
    }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @(
        'Start-KnownGoodEaCompatibilityGuard','Wait-EaCompatibilityGuardReady','EA_COMPAT_GUARD_READY',
        'EABackgroundService','portable-lsx-responder','EA_ENV phase=','STARTUP_CONTEXT','STARTUP_TCP',
        'STARTUP_EVIDENCE_SUMMARY','FILE_FINGERPRINT_BEGIN','CPY.ini'
    )) {
        if ($source -notmatch [regex]::Escape($marker)) {
            Write-Host "SELF-TEST FAILED: missing startup-evidence marker: $marker" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host 'PASS: launch guard parses; known-good EA state is preserved; passive EA/process/socket/game-file evidence is armed before FIFA; emergency cleanup still reaches exact restore.' -ForegroundColor Green
    exit 0
}

if (-not (Test-Path -LiteralPath $SafeRun -PathType Leaf)) {
    Write-Host 'STOP: safe-run.ps1 is missing.' -ForegroundColor Red
    exit 1
}

if ($Cleanup) {
    $keyError = $null
    try { Restore-HeldKey } catch { $keyError = $_.Exception.Message }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SafeRun -Cleanup | Out-Host
    $cleanupRc = [int]$LASTEXITCODE

    if ($keyError) {
        Write-Host "WARNING: PC cleanup was attempted, but package key-file restoration needs review: $keyError" -ForegroundColor Yellow
        exit 1
    }
    exit $cleanupRc
}

Restore-HeldKey
$held = $false
$eaGuard = $null
try {
    if ((Has-ExistingTailscaleConnection) -and (Test-Path -LiteralPath $JoinKey)) {
        if (Test-Path -LiteralPath $HeldKey) {
            Write-Host 'STOP: both JOIN.key and its held copy exist. Do not continue; keep both files and tell thankyounes.' -ForegroundColor Red
            exit 1
        }
        Move-Item -LiteralPath $JoinKey -Destination $HeldKey
        $held = $true
        Write-Host '  Existing Tailscale connection detected; JOIN.key is quarantined for this run and cannot switch accounts/tailnets.' -ForegroundColor Gray
    }

    Write-Host "  Startup evidence guard arming ($EaGuardRevision): runtime behavior is unchanged; it will observe EA readiness, FIFA sockets and file fingerprints." -ForegroundColor Gray
    $eaGuard = Start-KnownGoodEaCompatibilityGuard
    Wait-EaCompatibilityGuardReady $eaGuard
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SafeRun | Out-Host
    $rc = [int]$LASTEXITCODE
} finally {
    Stop-AndReportEaCompatibilityGuard $eaGuard
    if ($held) { Restore-HeldKey }
}
exit $rc
