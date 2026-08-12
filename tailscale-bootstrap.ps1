[CmdletBinding()]
param(
    [switch]$Cleanup,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$MsiPath = Join-Path $Root 'tailscale-amd64.msi'
$StatePath = Join-Path $env:ProgramData 'FIFA15-Preservation\two-pc-tailscale-bootstrap.json'
$Desktop = [Environment]::GetFolderPath('Desktop')

function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Step([string]$Text) { Write-Host "`n>> $Text" -ForegroundColor Cyan }
function Pass([string]$Text) { Write-Host "  PASS: $Text" -ForegroundColor Green }

function Write-Diagnostic([string]$Code, [string]$Text) {
    try {
        if (-not $Desktop) { return }
        $path = Join-Path $Desktop ("FIFA15-F15B-DIAG-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        @(
            'FIFA 15 F15B two-PC diagnostic',
            ('started_utc=' + (Get-Date).ToUniversalTime().ToString('o')),
            ('computer=' + $env:COMPUTERNAME),
            ('package_root=' + $Root),
            '',
            ("STOP [$Code]: $Text"),
            '',
            ('diagnosis=' + $Code),
            'exit_code=1',
            ('finished_utc=' + (Get-Date).ToUniversalTime().ToString('o'))
        ) | Set-Content -LiteralPath $path -Encoding UTF8
        Write-Host "  Diagnostic saved: $path" -ForegroundColor Yellow
    } catch {}
}

function Fail([string]$Code, [string]$Text) {
    Write-Host ''
    Write-Host "STOP [$Code]: $Text" -ForegroundColor Red
    Write-Diagnostic -Code $Code -Text $Text
    exit 1
}

function Ensure-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($Cleanup) { $args += '-Cleanup' }
    if ($SelfTest) { $args += '-SelfTest' }
    try {
        $child = Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait -PassThru
        exit $child.ExitCode
    } catch {
        Fail 'TAILSCALE_ADMIN_CANCELLED' 'Administrator approval was cancelled, so Tailscale could not be prepared.'
    }
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
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$Visible
    )

    if ($Visible) {
        $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        return [pscustomobject]@{ ExitCode=[int]$process.ExitCode; Stdout=''; Stderr='' }
    }

    $token = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $env:TEMP "fifa15-ts-bootstrap-$token.out.txt"
    $stderrPath = Join-Path $env:TEMP "fifa15-ts-bootstrap-$token.err.txt"
    try {
        $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        return [pscustomobject]@{ ExitCode=[int]$process.ExitCode; Stdout=[string]$stdout; Stderr=[string]$stderr }
    } finally {
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-TailscaleIp([string]$Exe) {
    if (-not $Exe) { return $null }
    $result = Invoke-TailscaleCli -Exe $Exe -Arguments @('ip','-4')
    if ($result.ExitCode -ne 0) { return $null }
    $ip = @($result.Stdout -split "`r?`n" | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
    if ($ip.Count -eq 0 -or -not $ip[0]) { return $null }
    return $ip[0].Trim()
}

function Write-State {
    $dir = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [ordered]@{
        format = 1
        installed_by_bootstrap = $true
        installed_utc = (Get-Date).ToUniversalTime().ToString('o')
        msi = $MsiPath
    } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Remove-StateIfClean {
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    $dir = Split-Path -Parent $StatePath
    if (Test-Path -LiteralPath $dir) {
        $remaining = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf)) { throw 'bundled Tailscale MSI is missing' }
    if ((Get-Item -LiteralPath $MsiPath).Length -lt 1MB) { throw 'bundled Tailscale MSI is unexpectedly small' }
    Pass 'Tailscale bootstrap parses and bundled MSI is present; no machine changes were made.'
}

function Ensure-TailscaleReady {
    $tailscale = Find-Tailscale
    if ($tailscale) {
        $ip = Get-TailscaleIp $tailscale
        if ($ip) {
            Info "Tailscale already installed and connected at $ip; bootstrap will not change it."
            return
        }
        Fail 'TAILSCALE_PREEXISTING_NOT_CONNECTED' 'Tailscale was already installed on this PC but is not connected. To preserve the tester PC exactly, the package will not reconfigure a pre-existing installation. Sign into YOUR OWN Tailscale account, accept thankyounes shared-machine invite, then rerun the BAT.'
    }

    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf)) {
        Fail 'TAILSCALE_INSTALLER_MISSING' 'The bundled Tailscale installer is missing. Re-download the tester repo/package.'
    }
    $signature = Get-AuthenticodeSignature -FilePath $MsiPath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        Fail 'TAILSCALE_INSTALLER_UNTRUSTED' "The bundled Tailscale MSI did not have a valid Windows signature (status=$($signature.Status))."
    }

    Step 'Installing Tailscale automatically for this test'
    $install = Start-Process msiexec.exe -ArgumentList @('/i',"`"$MsiPath`"",'/quiet','/norestart') -Wait -PassThru
    if ($install.ExitCode -notin @(0,3010)) {
        Fail 'TAILSCALE_INSTALL_FAILED' "Windows Installer returned code $($install.ExitCode)."
    }
    Write-State

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $tailscale = Find-Tailscale
    } until ($tailscale -or (Get-Date) -gt $deadline)
    if (-not $tailscale) {
        Fail 'TAILSCALE_INSTALL_INCOMPLETE' 'Tailscale installed but tailscale.exe did not appear within 30 seconds.'
    }

    Write-Host ''
    Write-Host 'Tailscale is installed. A browser/login prompt may open now.' -ForegroundColor Cyan
    Write-Host 'SIGN IN WITH YOUR OWN TAILSCALE ACCOUNT - never use thankyounes login.' -ForegroundColor Yellow
    Write-Host 'If thankyounes already shared the host machine with you, accept that invite in the same account.' -ForegroundColor Yellow
    Write-Host ''

    # No auth key is used. Tailscale documents that `tailscale up` authenticates when needed.
    # Disable Tailscale DNS on this temporary installation because the previous tester observed
    # MagicDNS breaking EA name resolution; this installation is removed after the test.
    $up = Invoke-TailscaleCli -Exe $tailscale -Arguments @('up','--timeout=5m','--unattended=true','--accept-dns=false') -Visible
    if ($up.ExitCode -ne 0) {
        Fail 'TAILSCALE_LOGIN_FAILED' 'Tailscale did not finish its normal browser authentication. Sign in with YOUR OWN account when prompted and rerun the BAT if needed.'
    }

    $ip = Get-TailscaleIp $tailscale
    if (-not $ip) {
        Fail 'TAILSCALE_LOGIN_INCOMPLETE' 'Tailscale authentication finished but this PC still has no Tailscale IPv4 address.'
    }
    Pass "Temporary Tailscale connection ready at $ip (Tailscale DNS disabled for this test)."
}

function Cleanup-BootstrapTailscale {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        Info 'No package-installed Tailscale bootstrap state exists; nothing to remove.'
        return
    }

    Step 'Restoring pre-test Tailscale-absent state'
    $tailscale = Find-Tailscale
    if ($tailscale) {
        try { [void](Invoke-TailscaleCli -Exe $tailscale -Arguments @('logout')) } catch {}
    }

    if (Test-Path -LiteralPath $MsiPath -PathType Leaf) {
        $uninstall = Start-Process msiexec.exe -ArgumentList @('/x',"`"$MsiPath`"",'/quiet','/norestart') -Wait -PassThru
        if ($uninstall.ExitCode -notin @(0,1605,3010)) {
            Fail 'TAILSCALE_UNINSTALL_FAILED' "Windows Installer returned code $($uninstall.ExitCode) while restoring the pre-test Tailscale-absent state."
        }
    }

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $remaining = Find-Tailscale
    } until (-not $remaining -or (Get-Date) -gt $deadline)
    if ($remaining) {
        Fail 'TAILSCALE_UNINSTALL_INCOMPLETE' 'The package installed Tailscale for this test, but it is still installed after cleanup. Run CLEANUP-FIFA15-F15B.bat again.'
    }

    Remove-StateIfClean
    Pass 'Tailscale restored to the pre-test absent state.'
}

try {
    if ($SelfTest) { Invoke-SelfTest; exit 0 }
    Ensure-Elevated
    if ($Cleanup) { Cleanup-BootstrapTailscale; exit 0 }
    Ensure-TailscaleReady
    exit 0
} catch {
    Fail 'TAILSCALE_BOOTSTRAP_UNEXPECTED' $_.Exception.Message
}
