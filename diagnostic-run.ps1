[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSCommandPath
$Preflight = Join-Path $Root 'tailscale-preflight.ps1'
$Launcher = Join-Path $Root 'launch-safe.ps1'

function Ensure-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    try {
        $child = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") -Verb RunAs -Wait -PassThru
        exit $child.ExitCode
    } catch {
        Write-Host 'STOP [ADMIN_REQUIRED]: Administrator approval was cancelled or Windows could not start the elevated tester.' -ForegroundColor Red
        exit 1
    }
}

function Test-HostsWriteLock([string]$Text) {
    if (-not $Text) { return $false }
    return ($Text -match 'drivers\\etc\\hosts.*being used by another process|GetContentWriterIOError.*hosts|Set-Content.*hosts.*IOException')
}

function Get-Diagnosis([string]$Text, [int]$ExitCode) {
    if ($Text -match 'FIFA 15 ready \(PID .*relay certificate verified') { return 'RUNTIME_LAUNCH_VERIFIED' }
    if ($Text -match 'STOP \[HOSTS_WRITE_LOCKED\]') { return 'HOSTS_WRITE_LOCKED' }
    if ($Text -match 'TAILSCALE_HOST_NOT_SHARED') { return 'TAILSCALE_HOST_NOT_SHARED' }
    if ($Text -match 'TAILSCALE_NOT_CONNECTED') { return 'TAILSCALE_NOT_CONNECTED' }
    if ($Text -match 'TAILSCALE_NOT_INSTALLED') { return 'TAILSCALE_NOT_INSTALLED' }
    if ($Text -match 'TAILSCALE_STATUS_FAILED') { return 'TAILSCALE_STATUS_FAILED' }
    if ($Text -match 'Host reports READY, but the FIFA relay port 42127 is not reachable') { return 'HOST_RELAY_UNREACHABLE' }
    if ($Text -match 'never reported READY') { return 'HOST_NOT_READY' }
    if ($Text -match 'TCP 3216 is already owned') { return 'LSX_PORT_CONFLICT' }
    if ($Text -match 'LSX responder did not become the verified owner|LSX responder lost ownership') { return 'LSX_RESPONDER_FAILED' }
    if ($Text -match 'pre-patch ReadProcessMemory failed') { return 'CERTIFICATE_PREIMAGE_READ_FAILED' }
    if ($Text -match 'does not map the known certificate patch location safely') { return 'CERTIFICATE_LAYOUT_DIFFERENT' }
    if ($Text -match 'Windows refused access to inspect/patch FIFA 15 memory') { return 'CERTIFICATE_PROCESS_ACCESS_FAILED' }
    if ($Text -match 'WriteProcessMemory failed') { return 'CERTIFICATE_WRITE_FAILED' }
    if ($Text -match 'certificate readback mismatch|post-patch ReadProcessMemory failed') { return 'CERTIFICATE_READBACK_FAILED' }
    if ($Text -match 'FIFA 15 could not be found or selected') { return 'FIFA_NOT_FOUND' }
    if ($Text -match 'launched FIFA 15 process did not remain running long enough to patch') { return 'FIFA_EXITED_DURING_LAUNCH' }
    if ($ExitCode -eq 0) { return 'RUN_COMPLETED' }
    return 'UNCLASSIFIED_FAILURE'
}

function Invoke-LoggedScript([string]$Path, [string]$DiagPath) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $line = "STOP [PACKAGE_FILE_MISSING]: Missing required launcher script: $Path"
        Write-Host $line -ForegroundColor Red
        Add-Content -LiteralPath $DiagPath -Value $line -Encoding UTF8
        return 1
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object {
        $line = $_.ToString()
        Write-Host $line
        Add-Content -LiteralPath $DiagPath -Value $line -Encoding UTF8
    }
    return [int]$LASTEXITCODE
}

function Invoke-SelfTest {
    foreach ($path in @($PSCommandPath,$Preflight,$Launcher)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "missing $path" }
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) { throw "$path parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
    }
    if ((Get-Diagnosis 'STOP [TAILSCALE_HOST_NOT_SHARED]: nope' 1) -ne 'TAILSCALE_HOST_NOT_SHARED') { throw 'Tailscale classifier failed' }
    if ((Get-Diagnosis 'Certificate patch failed: pre-patch ReadProcessMemory failed' 1) -ne 'CERTIFICATE_PREIMAGE_READ_FAILED') { throw 'certificate classifier failed' }
    if ((Get-Diagnosis 'STOP [HOSTS_WRITE_LOCKED]: retry exhausted' 1) -ne 'HOSTS_WRITE_LOCKED') { throw 'hosts-lock classifier failed' }
    if (-not (Test-HostsWriteLock "Set-Content : The process cannot access the file 'C:\WINDOWS\System32\drivers\etc\hosts' because it is being used by another process.")) { throw 'hosts-lock detector failed' }
    if ((Get-Diagnosis 'FIFA 15 ready (PID 123); relay certificate verified.' 0) -ne 'RUNTIME_LAUNCH_VERIFIED') { throw 'success classifier failed' }
    Write-Host 'PASS: durable diagnostic wrapper parses, classifies known boundaries, and recognizes transient hosts locks without changing the machine.' -ForegroundColor Green
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch {
        Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Ensure-Elevated

$desktop = [Environment]::GetFolderPath('Desktop')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$diagPath = Join-Path $desktop "FIFA15-F15B-DIAG-$stamp.txt"
@(
    'FIFA 15 F15B two-PC diagnostic',
    "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    "computer=$env:COMPUTERNAME",
    "package_root=$Root",
    ''
) | Set-Content -LiteralPath $diagPath -Encoding UTF8

Write-Host "Diagnostic log: $diagPath" -ForegroundColor Cyan
$rc = Invoke-LoggedScript -Path $Preflight -DiagPath $diagPath
if ($rc -eq 0) {
    $rc = Invoke-LoggedScript -Path $Launcher -DiagPath $diagPath

    if ($rc -ne 0) {
        $firstAttemptText = [string](Get-Content -LiteralPath $diagPath -Raw -ErrorAction SilentlyContinue)
        if (Test-HostsWriteLock $firstAttemptText) {
            $retryNote = 'AUTO-RETRY: Windows temporarily locked the hosts file. The first attempt restored cleanly; waiting two seconds and retrying the complete guest launch once.'
            Write-Host $retryNote -ForegroundColor Yellow
            Add-Content -LiteralPath $diagPath -Value @('', $retryNote, '') -Encoding UTF8
            Start-Sleep -Seconds 2

            $beforeRetry = [string](Get-Content -LiteralPath $diagPath -Raw -ErrorAction SilentlyContinue)
            $retryStart = $beforeRetry.Length
            $rc = Invoke-LoggedScript -Path $Launcher -DiagPath $diagPath
            $afterRetry = [string](Get-Content -LiteralPath $diagPath -Raw -ErrorAction SilentlyContinue)
            $retryText = if ($afterRetry.Length -gt $retryStart) { $afterRetry.Substring($retryStart) } else { '' }

            if ($rc -ne 0 -and (Test-HostsWriteLock $retryText)) {
                $lockLine = 'STOP [HOSTS_WRITE_LOCKED]: Windows kept the hosts file locked across one clean automatic retry. No matchmaking conclusion can be drawn.'
                Write-Host $lockLine -ForegroundColor Red
                Add-Content -LiteralPath $diagPath -Value $lockLine -Encoding UTF8
            }
        }
    }
}

$text = Get-Content -LiteralPath $diagPath -Raw -ErrorAction SilentlyContinue
$diagnosis = Get-Diagnosis -Text ([string]$text) -ExitCode $rc
@(
    '',
    "diagnosis=$diagnosis",
    "exit_code=$rc",
    "finished_utc=$((Get-Date).ToUniversalTime().ToString('o'))"
) | Add-Content -LiteralPath $diagPath -Encoding UTF8

Write-Host ''
if ($rc -eq 0) {
    Write-Host "RESULT: $diagnosis" -ForegroundColor Green
} else {
    Write-Host "RESULT: $diagnosis" -ForegroundColor Red
}
Write-Host "SEND THIS FILE TO THANKYOUNES: $diagPath" -ForegroundColor Yellow
exit $rc
