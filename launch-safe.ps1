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
    Write-Host 'PASS: launch guard parses; existing Tailscale cannot consume JOIN.key; emergency cleanup always reaches the machine restore.' -ForegroundColor Green
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

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SafeRun | Out-Host
    $rc = [int]$LASTEXITCODE
} finally {
    if ($held) { Restore-HeldKey }
}
exit $rc
