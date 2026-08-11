[CmdletBinding()]
param(
    [switch]$Cleanup,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$RemoteClient = Join-Path $Root 'remote-client.ps1'
$RuntimeRoot = Join-Path $Root 'runtime'
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$ExactStatePath = Join-Path $env:ProgramData 'FIFA15-Preservation\two-pc-appliance-exact-state.json'
$OldStatePath = Join-Path $env:ProgramData 'FIFA15-Preservation\two-pc-appliance-state.json'
$StartMarker = '# BEGIN FIFA15-TWO-PC-APPLIANCE'
$EndMarker = '# END FIFA15-TWO-PC-APPLIANCE'
$Revision = 'restore-v3'

function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Step([string]$Text) { Write-Host "`n>> $Text" -ForegroundColor Cyan }
function Stop-WithMessage([string]$Text) { throw $Text }

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
        Stop-WithMessage 'Administrator approval was cancelled or Windows could not start the elevated tester.'
    }
}

function Read-ExactState {
    if (-not (Test-Path -LiteralPath $ExactStatePath)) { return $null }
    try { return Get-Content -LiteralPath $ExactStatePath -Raw | ConvertFrom-Json } catch {
        Stop-WithMessage "The saved restoration state is unreadable: $ExactStatePath. Do not run the test again; keep the file and contact thankyounes."
    }
}

function Write-ExactState($State) {
    $dir = Split-Path -Parent $ExactStatePath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ExactStatePath -Encoding UTF8
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') } finally { $sha.Dispose() }
}

function Find-Tailscale {
    foreach ($path in @("$env:ProgramFiles\Tailscale\tailscale.exe", "$env:ProgramFiles(x86)\Tailscale\tailscale.exe")) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-TailscaleIp([string]$Tailscale) {
    if (-not $Tailscale) { return $null }
    $value = @(& $Tailscale ip -4 2>$null) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    if ($value) { return $value.Trim() }
    return $null
}

function Get-ZSubstTarget {
    $line = @(& subst.exe 2>$null) | Where-Object { $_ -match '^(?i)Z:\\: => ' } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -replace '^(?i)Z:\\: =>\s*','').TrimEnd('\')
}

function Get-ProcessPath([string]$Name) {
    $proc = Get-CimInstance Win32_Process -Filter "Name='$Name'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.ExecutablePath) { return [string]$proc.ExecutablePath }
    return $null
}

function Get-ServiceSnapshot([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    return [ordered]@{ name=$Name; status=[string]$svc.Status }
}

function Assert-CleanPreState {
    if (Test-Path -LiteralPath $ExactStatePath) {
        Stop-WithMessage "A previous tester restoration snapshot still exists. Run CLEANUP-FIFA15-F15B.bat first: $ExactStatePath"
    }
    if (Test-Path -LiteralPath $RuntimeRoot) {
        Stop-WithMessage "The package-local runtime folder already exists. To avoid deleting pre-existing files, this tester will not proceed. Run CLEANUP-FIFA15-F15B.bat or use a fresh clone: $RuntimeRoot"
    }
    if (Get-ZSubstTarget) {
        Stop-WithMessage 'Z: already has a SUBST mapping. The tester will not replace an existing drive mapping.'
    }
    if (Test-Path 'Z:\') {
        Stop-WithMessage 'Z: is already a real or mapped drive. The tester will not change it.'
    }
    if (-not (Test-Path -LiteralPath $HostsPath -PathType Leaf)) {
        Stop-WithMessage "Windows hosts file is missing: $HostsPath"
    }
    $hostsText = Get-Content -LiteralPath $HostsPath -Raw -ErrorAction Stop
    if ($hostsText -match [regex]::Escape($StartMarker) -or $hostsText -match [regex]::Escape($EndMarker)) {
        Stop-WithMessage 'A FIFA15 tester hosts block already exists. Run CLEANUP-FIFA15-F15B.bat before starting another test.'
    }

    $tailscale = Find-Tailscale
    if ($tailscale) {
        $ip = Get-TailscaleIp $tailscale
        if (-not $ip) {
            Stop-WithMessage 'Tailscale is already installed on this PC but is not connected. Exact restoration cannot safely borrow/reconfigure a disconnected pre-existing installation. Connect your existing Tailscale yourself, or uninstall it before using this package.'
        }
        Info "Pre-existing Tailscale is connected at $ip and will be borrowed without reconfiguration."
    }

    $owner = Get-NetTCPConnection -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($owner) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.OwningProcess)" -ErrorAction SilentlyContinue
        $allowedEaNames = @('EADesktop.exe','EALauncher.exe','EALocalHostSvc.exe','EABackgroundService.exe','Origin.exe')
        if (-not $proc -or $proc.Name -notin $allowedEaNames) {
            $name = if ($proc) { $proc.Name } else { 'unknown process' }
            Stop-WithMessage "TCP 3216 is already owned by $name (PID $($owner.OwningProcess)). The tester will not kill an unrelated process."
        }
        Info "TCP 3216 is currently owned by EA software ($($proc.Name)); its state will be restored after the test."
    }
}

function Save-ExactPreState {
    Assert-CleanPreState

    Step 'Snapshotting exact pre-test machine state'
    $hostsBytes = [IO.File]::ReadAllBytes($HostsPath)
    $hostsInfo = Get-Item -LiteralPath $HostsPath -Force
    $hostsAcl = Get-Acl -LiteralPath $HostsPath
    $tailscale = Find-Tailscale
    $eaPath = Get-ProcessPath 'EADesktop.exe'
    $services = @()
    foreach ($name in @('EABackgroundService','EALocalHostSvc')) {
        $entry = Get-ServiceSnapshot $name
        if ($entry) { $services += $entry }
    }

    $state = [ordered]@{
        format = 3
        revision = $Revision
        started_utc = (Get-Date).ToUniversalTime().ToString('o')
        hosts_bytes_b64 = [Convert]::ToBase64String($hostsBytes)
        hosts_sha256 = Get-BytesSha256 $hostsBytes
        hosts_creation_utc = $hostsInfo.CreationTimeUtc.ToString('o')
        hosts_last_write_utc = $hostsInfo.LastWriteTimeUtc.ToString('o')
        hosts_last_access_utc = $hostsInfo.LastAccessTimeUtc.ToString('o')
        hosts_attributes = [int]$hostsInfo.Attributes
        hosts_acl_sddl = $hostsAcl.Sddl
        z_preexisting = $false
        runtime_preexisting = $false
        tailscale_preexisting = [bool]$tailscale
        tailscale_preexisting_ip = if ($tailscale) { Get-TailscaleIp $tailscale } else { $null }
        ea_desktop_was_running = [bool]$eaPath
        ea_desktop_path = $eaPath
        ea_services = $services
    }
    Write-ExactState ([pscustomobject]$state)
    Info "Exact restoration snapshot saved: $ExactStatePath"
    Info "Hosts preimage SHA-256: $($state.hosts_sha256)"
}

function Invoke-RemoteClient {
    param([string[]]$Arguments = @())
    if (-not (Test-Path -LiteralPath $RemoteClient -PathType Leaf)) {
        Stop-WithMessage "Missing launcher engine: $RemoteClient"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemoteClient @Arguments | Out-Host
    return [int]$LASTEXITCODE
}

function Stop-PackageProcesses {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'portable-lsx-responder\.ps1' -and $_.CommandLine -like "*$Root*" } |
        ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }

    $stub = Join-Path $RuntimeRoot 'EADesktop.exe'
    Get-CimInstance Win32_Process -Filter "Name='EADesktop.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($stub, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
}

function Restore-HostsExact($State) {
    if (-not $State.hosts_bytes_b64 -or -not $State.hosts_sha256) { Stop-WithMessage 'Saved hosts preimage is missing from restoration state.' }
    $bytes = [Convert]::FromBase64String([string]$State.hosts_bytes_b64)

    $currentAttributes = [IO.File]::GetAttributes($HostsPath)
    if (($currentAttributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        [IO.File]::SetAttributes($HostsPath, ($currentAttributes -bxor [IO.FileAttributes]::ReadOnly))
    }
    [IO.File]::WriteAllBytes($HostsPath, $bytes)

    if ($State.hosts_acl_sddl) {
        $acl = Get-Acl -LiteralPath $HostsPath
        $acl.SetSecurityDescriptorSddlForm([string]$State.hosts_acl_sddl)
        Set-Acl -LiteralPath $HostsPath -AclObject $acl
    }
    if ($State.hosts_creation_utc) { [IO.File]::SetCreationTimeUtc($HostsPath, [datetime]::Parse([string]$State.hosts_creation_utc).ToUniversalTime()) }
    if ($State.hosts_last_write_utc) { [IO.File]::SetLastWriteTimeUtc($HostsPath, [datetime]::Parse([string]$State.hosts_last_write_utc).ToUniversalTime()) }
    if ($State.hosts_last_access_utc) { [IO.File]::SetLastAccessTimeUtc($HostsPath, [datetime]::Parse([string]$State.hosts_last_access_utc).ToUniversalTime()) }
    if ($null -ne $State.hosts_attributes) { [IO.File]::SetAttributes($HostsPath, [IO.FileAttributes]([int]$State.hosts_attributes)) }

    ipconfig /flushdns | Out-Null
    $actual = Get-BytesSha256 ([IO.File]::ReadAllBytes($HostsPath))
    if (-not $actual.Equals([string]$State.hosts_sha256, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithMessage "Hosts restoration verification failed. Expected $($State.hosts_sha256), got $actual."
    }
    Info "PASS: hosts file restored byte-for-byte ($actual)."
}

function Restore-ZAndRuntime($State) {
    $target = Get-ZSubstTarget
    if ($target) {
        $expectedPrefix = $RuntimeRoot.TrimEnd('\')
        if ($target.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            & subst.exe Z: /D | Out-Null
            Info 'Removed package-created Z: SUBST mapping.'
        } else {
            Stop-WithMessage "Z: now points to an unrelated location ($target); cleanup refused to delete it."
        }
    }
    if (-not $State.runtime_preexisting -and (Test-Path -LiteralPath $RuntimeRoot)) {
        Remove-Item -LiteralPath $RuntimeRoot -Recurse -Force
        Info 'Removed package-local runtime files.'
    }
}

function Restore-EaState($State) {
    $clientNames = @('EADesktop','EALauncher','EACefSubProcess','EALaunchHelper','EAConnect_microsoft','ActivationUI')
    if ($State.ea_desktop_was_running) {
        if (-not (Get-Process -Name EADesktop -ErrorAction SilentlyContinue)) {
            $path = [string]$State.ea_desktop_path
            if ($path -and (Test-Path -LiteralPath $path)) {
                Start-Process $path | Out-Null
                Info 'Restored the pre-test EA Desktop running state.'
            } else {
                Stop-WithMessage 'EA Desktop was running before the test but its original executable path is no longer available.'
            }
        }
    } else {
        foreach ($name in $clientNames) {
            Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Info 'Restored the pre-test EA Desktop stopped state.'
    }

    foreach ($entry in @($State.ea_services)) {
        if (-not $entry -or -not $entry.name) { continue }
        $svc = Get-Service -Name ([string]$entry.name) -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $wanted = [string]$entry.status
        if ($wanted -eq 'Running' -and $svc.Status -ne 'Running') {
            Start-Service -Name $svc.Name
            $svc.WaitForStatus('Running',[TimeSpan]::FromSeconds(15))
        } elseif ($wanted -eq 'Stopped' -and $svc.Status -ne 'Stopped') {
            Stop-Service -Name $svc.Name -Force
            $svc.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))
        }
        Info "Restored service $($svc.Name) to $wanted."
    }
}

function Restore-TailscaleState($State) {
    if ($State.tailscale_preexisting) {
        $tailscale = Find-Tailscale
        if (-not $tailscale) { Stop-WithMessage 'Tailscale existed before the test but is now missing.' }
        $ip = Get-TailscaleIp $tailscale
        if (-not $ip) { Stop-WithMessage 'Pre-existing Tailscale was connected before the test but is now disconnected.' }
        if ($State.tailscale_preexisting_ip -and $ip -ne [string]$State.tailscale_preexisting_ip) {
            Stop-WithMessage "Pre-existing Tailscale address changed. Expected $($State.tailscale_preexisting_ip), got $ip."
        }
        Info "PASS: pre-existing Tailscale connection preserved at $ip."
        return
    }

    $tailscale = Find-Tailscale
    if ($tailscale) {
        $msi = Join-Path $Root 'tailscale-amd64.msi'
        if (Test-Path -LiteralPath $msi) {
            & $tailscale logout 2>$null | Out-Null
            $proc = Start-Process msiexec.exe -ArgumentList @('/x',"`"$msi`"",'/quiet','/norestart') -Wait -PassThru
            if ($proc.ExitCode -notin @(0,1605,3010)) {
                Stop-WithMessage "Package-created Tailscale could not be removed (Windows Installer $($proc.ExitCode))."
            }
            Start-Sleep -Seconds 2
        }
    }
    if (Find-Tailscale) { Stop-WithMessage 'Tailscale was absent before the test but is still installed after cleanup.' }
    Info 'PASS: Tailscale restored to the pre-test absent state.'
}

function Remove-StateFilesIfClean {
    Remove-Item -LiteralPath $ExactStatePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $OldStatePath -Force -ErrorAction SilentlyContinue
    $dir = Split-Path -Parent $ExactStatePath
    if (Test-Path -LiteralPath $dir) {
        $remaining = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-ExactState {
    $state = Read-ExactState
    if (-not $state) {
        Info 'No exact restoration snapshot exists; only package-owned legacy cleanup can be attempted.'
        Stop-PackageProcesses
        return $true
    }

    Step 'Restoring exact pre-test machine state'
    $failures = New-Object Collections.Generic.List[string]
    foreach ($action in @(
        @{ name='package processes'; block={ Stop-PackageProcesses } },
        @{ name='hosts'; block={ Restore-HostsExact $state } },
        @{ name='Z/runtime'; block={ Restore-ZAndRuntime $state } },
        @{ name='EA state'; block={ Restore-EaState $state } },
        @{ name='Tailscale'; block={ Restore-TailscaleState $state } }
    )) {
        try { & $action.block } catch { $failures.Add("$($action.name): $($_.Exception.Message)") }
    }

    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host 'RESTORATION INCOMPLETE - KEEP THE WINDOW OPEN' -ForegroundColor Red
        foreach ($failure in $failures) { Write-Host "  $failure" -ForegroundColor Red }
        Write-Host "  Snapshot retained for retry: $ExactStatePath" -ForegroundColor Yellow
        return $false
    }

    Remove-StateFilesIfClean
    Write-Host 'PASS: test-owned configuration restored to its recorded pre-test values.' -ForegroundColor Green
    return $true
}

function Invoke-SelfTest {
    Step 'Safety-wrapper self-test (no machine changes)'
    foreach ($path in @($PSCommandPath,$RemoteClient)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-WithMessage "Required script is missing: $path" }
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            Stop-WithMessage "PowerShell parse failed for $path`: $((@($errors | ForEach-Object Message)) -join '; ')"
        }
    }
    $rc = Invoke-RemoteClient -Arguments @('-SelfTest')
    if ($rc -ne 0) { Stop-WithMessage "Existing remote-client self-test failed with code $rc." }
    Info 'PASS: restoration wrapper parses and underlying tester self-test passes.'
}

try {
    if ($SelfTest) {
        Invoke-SelfTest
        exit 0
    }

    Ensure-Elevated

    if ($Cleanup) {
        Step 'Emergency cleanup'
        try { [void](Invoke-RemoteClient -Arguments @('-Cleanup')) } catch { Info "Underlying cleanup warning: $($_.Exception.Message)" }
        $ok = Restore-ExactState
        if (-not $ok) { exit 2 }
        exit 0
    }

    Save-ExactPreState
    Write-Host "`nExact-restoration wrapper active ($Revision)." -ForegroundColor Green
    $remoteRc = 1
    try {
        $remoteRc = Invoke-RemoteClient
    } finally {
        try { [void](Invoke-RemoteClient -Arguments @('-Cleanup')) } catch { Info "Underlying cleanup warning: $($_.Exception.Message)" }
        $restored = Restore-ExactState
        if (-not $restored) { $remoteRc = 2 }
    }
    exit $remoteRc
} catch {
    Write-Host "`nSTOP: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $ExactStatePath) {
        Write-Host 'An exact restoration snapshot exists. Run CLEANUP-FIFA15-F15B.bat if automatic cleanup did not complete.' -ForegroundColor Yellow
    }
    exit 1
}
