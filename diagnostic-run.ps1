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

function Get-Diagnosis([string]$Text, [int]$ExitCode) {
    if ($Text -match 'FIFA 15 ready \(PID .*relay certificate verified') { return 'RUNTIME_LAUNCH_VERIFIED' }
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
    if ((Get-Diagnosis 'FIFA 15 ready (PID 123); relay certificate verified.' 0) -ne 'RUNTIME_LAUNCH_VERIFIED') { throw 'success classifier failed' }
    Write-Host 'PASS: durable diagnostic wrapper parses and classifies known boundaries without changing the machine.' -ForegroundColor Green
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
