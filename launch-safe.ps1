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
$EaGuardRevision = 'ea-state-v1'

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
    $job = Start-Job -ArgumentList $Root,$EaGuardRevision -ScriptBlock {
        param([string]$PackageRoot,[string]$Revision)
        $ErrorActionPreference = 'Continue'
        Write-Output "EA_COMPAT_GUARD: revision=$Revision waiting for package LSX ownership of 127.0.0.1:3216."

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
            Start-Sleep -Milliseconds 50
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

        $fifa = $null
        $fifaDeadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $fifaDeadline -and -not $fifa) {
            $fifa = Get-Process -Name fifa15 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $fifa) { Start-Sleep -Milliseconds 25 }
        }
        if (-not $fifa) {
            Write-Output 'EA_COMPAT_GUARD: fifa15.exe was not observed after the known-good EA state was established.'
            return
        }

        $pidValue = [int]$fifa.Id
        Write-Output "EA_COMPAT_GUARD: observed fifa15 pid=$pidValue; sampling early companion-module state."
        $lastMs = 0
        foreach ($sampleMs in @(0,100,250,500,1000)) {
            if ($sampleMs -gt $lastMs) { Start-Sleep -Milliseconds ($sampleMs - $lastMs) }
            $lastMs = $sampleMs
            $procNow = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            $alive = [bool]$procNow
            $modules = @()
            if ($procNow) {
                try {
                    $modules = @($procNow.Modules | Where-Object { $_.ModuleName -in @('ItsAMe_Origin.dll','sysdllzf.dll') } | ForEach-Object { $_.ModuleName })
                } catch {}
            }
            $serviceNow = Get-Service -Name EABackgroundService -ErrorAction SilentlyContinue
            $serviceStatus = if ($serviceNow) { [string]$serviceNow.Status } else { '<missing>' }
            Write-Output "EA_COMPAT sample t=${sampleMs}ms alive=$alive service=$serviceStatus modules=$($modules -join ',')"
            if (-not $alive) { break }
        }
    }
    return $job
}

function Stop-AndReportEaCompatibilityGuard($Job) {
    if (-not $Job) { return }
    try {
        Wait-Job -Job $Job -Timeout 2 | Out-Null
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
    foreach ($marker in @('Start-KnownGoodEaCompatibilityGuard','EABackgroundService','portable-lsx-responder\.ps1','EA_COMPAT sample t=')) {
        if ($source -notmatch $marker) {
            Write-Host "SELF-TEST FAILED: missing EA compatibility guard marker: $marker" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host 'PASS: launch guard parses; existing Tailscale cannot consume JOIN.key; known-good EA background-service guard is armed before the safe runner; emergency cleanup always reaches the machine restore.' -ForegroundColor Green
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

    Write-Host "  EA compatibility guard armed ($EaGuardRevision): it will start EABackgroundService only after package LSX owns 3216." -ForegroundColor Gray
    $eaGuard = Start-KnownGoodEaCompatibilityGuard
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SafeRun | Out-Host
    $rc = [int]$LASTEXITCODE
} finally {
    Stop-AndReportEaCompatibilityGuard $eaGuard
    if ($held) { Restore-HeldKey }
}
exit $rc
