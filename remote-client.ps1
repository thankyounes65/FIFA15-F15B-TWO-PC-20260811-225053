[CmdletBinding()]
param([switch]$Cleanup)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$StatePath = Join-Path $env:ProgramData 'FIFA15-Preservation\two-pc-appliance-state.json'
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$StartMarker = '# BEGIN FIFA15-TWO-PC-APPLIANCE'
$EndMarker = '# END FIFA15-TWO-PC-APPLIANCE'
$ReadyPort = 48215
# This script only ever runs from the flat f15b package
# (BUILD-TWO-PC-APPLIANCE.ps1 stages it at the ZIP root), never in place
# from scripts\two-pc-appliance\ - the builder copies
# scripts\fifa15-managed-hostnames.ps1 to that same stage directory so this
# resolves there too.
. (Join-Path $Root 'fifa15-managed-hostnames.ps1')
$RelayHostnames = $Fifa15RedirectableHostnames

function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Step([string]$Text) { Write-Host "`n>> $Text" -ForegroundColor Cyan }
function Fail([string]$Text) { Write-Host "`nSTOP: $Text" -ForegroundColor Red; exit 1 }

function Ensure-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
        if ($Cleanup) { $args += '-Cleanup' }
        Start-Process powershell.exe -ArgumentList $args -Verb RunAs
        exit 0
    }
}

function Read-State {
    if (Test-Path $StatePath) {
        try { return Get-Content $StatePath -Raw | ConvertFrom-Json } catch {}
    }
    return $null
}

function Write-State($State) {
    $dir = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $State | ConvertTo-Json -Depth 5 | Set-Content $StatePath -Encoding UTF8
}

function Remove-HostsBlock {
    if (-not (Test-Path $HostsPath)) { return }
    $lines = @(Get-Content $HostsPath)
    $output = New-Object Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $lines) {
        if ($line.TrimEnd() -eq $StartMarker) { $inside = $true; continue }
        if ($line.TrimEnd() -eq $EndMarker) { $inside = $false; continue }
        if (-not $inside) { $output.Add($line) }
    }
    Set-Content $HostsPath -Value $output -Encoding ASCII
    ipconfig /flushdns | Out-Null
}

function Set-HostsBlock([string]$HostIp) {
    Remove-HostsBlock
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($StartMarker)
    foreach ($name in $RelayHostnames) { $lines.Add("$HostIp`t$name") }
    $lines.Add("127.0.0.1`tpeach.online.ea.com")
    $lines.Add($EndMarker)
    Add-Content $HostsPath -Value $lines -Encoding ASCII
    ipconfig /flushdns | Out-Null
}

function Find-Tailscale {
    foreach ($path in @("$env:ProgramFiles\Tailscale\tailscale.exe", "$env:ProgramFiles(x86)\Tailscale\tailscale.exe")) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Ensure-Tailscale([ref]$InstalledHere) {
    $tailscale = Find-Tailscale
    if (-not $tailscale) {
        $msi = Join-Path $Root 'tailscale-amd64.msi'
        if (-not (Test-Path $msi)) { Fail 'The bundled private-network installer is missing. Ask thankyounes for a fresh ZIP.' }
        Step 'Installing the private network component silently'
        $process = Start-Process msiexec.exe -ArgumentList @('/i',"`"$msi`"",'/quiet','/norestart') -Wait -PassThru
        if ($process.ExitCode -ne 0) { Fail "Private-network install failed with Windows Installer code $($process.ExitCode)." }
        Start-Sleep -Seconds 3
        $tailscale = Find-Tailscale
        if (-not $tailscale) { Fail 'The private network installed but its command-line tool was not found.' }
        $InstalledHere.Value = $true
    }

    $keyPath = Join-Path $Root 'JOIN.key'
    if (Test-Path $keyPath) {
        $key = (Get-Content $keyPath -Raw).Trim()
        if ($key) {
            Step 'Joining the private FIFA test network automatically'
            $output = & $tailscale up --auth-key=$key --hostname=fifa15-f15b --unattended=true 2>&1
            if ($LASTEXITCODE -ne 0) { Fail "Could not join the private network: $($output -join ' ')" }
            Remove-Item $keyPath -Force -ErrorAction SilentlyContinue
        }
    }

    $ip = (& $tailscale ip -4 2>$null | Select-Object -First 1)
    if (-not $ip) { Fail 'The private network is installed but not connected. Ask thankyounes for a fresh package/key.' }
    Info "Private network ready: $($ip.Trim())"
    return $tailscale
}

function Wait-HostReady([string]$HostIp) {
    Step 'Waiting for thankyounes PC to be fully ready'
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        try {
            $client = New-Object Net.Sockets.TcpClient
            $task = $client.ConnectAsync($HostIp, $ReadyPort)
            if ($task.Wait(1500) -and $client.Connected) {
                $stream = $client.GetStream()
                $buffer = New-Object byte[] 16
                $count = $stream.Read($buffer, 0, $buffer.Length)
                $text = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                $client.Close()
                if ($text -match 'READY') { Info 'Host reports READY.'; return }
            }
            $client.Close()
        } catch {}
        Start-Sleep -Seconds 2
    }
    Fail 'thankyounes PC never reported READY. Ask them to run RUN-TWO-PC-HOST.bat and leave it open.'
}

function Find-Fifa15 {
    $candidates = New-Object Collections.Generic.List[string]
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $candidates.Add((Join-Path $base 'EA Games\FIFA 15\fifa15.exe'))
            $candidates.Add((Join-Path $base 'Origin Games\FIFA 15\fifa15.exe'))
        }
    }
    foreach ($drive in @('C','D','E','F','G')) {
        foreach ($relative in @('Games\FIFA 15\fifa15.exe','EA Games\FIFA 15\fifa15.exe','Origin Games\FIFA 15\fifa15.exe')) {
            $candidates.Add("$drive`:\$relative")
        }
    }
    foreach ($path in $candidates) {
        if (Test-Path $path) { return (Resolve-Path $path).Path }
    }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $hit = Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*FIFA 15*' } | Select-Object -First 1
        if ($hit -and $hit.InstallLocation) {
            $path = Join-Path $hit.InstallLocation 'fifa15.exe'
            if (Test-Path $path) { return (Resolve-Path $path).Path }
        }
    }
    return $null
}

function Stop-BundledLsx {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'portable-lsx-responder\.ps1' } |
        ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
}

function Stop-BundledEaStub {
    $stub = Join-Path $Root 'runtime\EADesktop.exe'
    Get-CimInstance Win32_Process -Filter "Name='EADesktop.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($stub, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
}

function Prepare-OriginLsx {
    Step 'Preparing the self-contained Origin/LSX compatibility layer'

    foreach ($name in @('EADesktop','EABackgroundService','EALauncher','EACefSubProcess','EALocalHostSvc','EALaunchHelper','EAConnect_microsoft','ActivationUI')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Stop-BundledLsx
    Stop-BundledEaStub

    $owner = Get-NetTCPConnection -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($owner) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.OwningProcess)" -ErrorAction SilentlyContinue
        if ($process -and $process.Name -in @('python.exe','pythonw.exe','powershell.exe')) {
            Stop-Process -Id ([int]$owner.OwningProcess) -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        } else {
            Fail "TCP 3216 is already owned by $($process.Name) (PID $($owner.OwningProcess)). It was not touched."
        }
    }

    $shimRoot = Join-Path $Root 'runtime\origin-shim'
    $originDir = Join-Path $shimRoot 'Program Files (x86)\Origin'
    $originExe = Join-Path $originDir 'Origin.exe'
    New-Item -ItemType Directory -Path $originDir -Force | Out-Null
    if (-not (Test-Path $originExe)) {
        Copy-Item (Join-Path $env:WINDIR 'System32\rundll32.exe') $originExe -Force
    }

    $current = @(& subst.exe 2>$null) | Where-Object { $_ -match '^(?i)Z:\\: => ' } | Select-Object -First 1
    if ($current) {
        $target = ($current -replace '^(?i)Z:\\: =>\s*','').TrimEnd('\')
        if (-not $target.Equals($shimRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Fail "Z: is already substituted to another location: $target. The appliance will not replace an unrelated mapping."
        }
    } elseif (Test-Path 'Z:\') {
        Fail 'Z: is already a real or mapped drive. FIFA 15 requires that drive letter for its Origin compatibility path.'
    } else {
        & subst.exe Z: $shimRoot
        if ($LASTEXITCODE -ne 0) { Fail 'Could not create the temporary Z: Origin compatibility drive.' }
    }

    $lsxScript = Join-Path $Root 'portable-lsx-responder.ps1'
    $table = Join-Path $Root 'lsx-table.json'
    if (-not (Test-Path $lsxScript) -or -not (Test-Path $table)) { Fail 'Bundled LSX runtime files are missing. Ask thankyounes for a fresh ZIP.' }
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$lsxScript`"",'-TablePath',"`"$table`"") -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 300
        $listener = Get-NetTCPConnection -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    } until ($listener -or (Get-Date) -gt $deadline)
    if (-not $listener) { Fail 'The bundled LSX responder could not claim 127.0.0.1:3216.' }
    Info 'Bundled LSX responder owns 127.0.0.1:3216.'

    $realEa = 'C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe'
    if (Test-Path $realEa) {
        Start-Process $realEa | Out-Null
        Info 'Existing EA Desktop process started after LSX claimed its port.'
    } else {
        $eaStub = Join-Path $Root 'runtime\EADesktop.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $eaStub) -Force | Out-Null
        Copy-Item (Join-Path $env:WINDIR 'System32\PING.EXE') $eaStub -Force
        Start-Process $eaStub -ArgumentList @('-t','127.0.0.1') -WorkingDirectory (Split-Path -Parent $eaStub) -WindowStyle Hidden | Out-Null
        Info 'No EA Desktop installation found; bundled process-presence compatibility stub started.'
    }
}

function Stop-OriginLsx {
    Stop-BundledLsx
    Stop-BundledEaStub
    $shimRoot = Join-Path $Root 'runtime\origin-shim'
    $current = @(& subst.exe 2>$null) | Where-Object { $_ -match '^(?i)Z:\\: => ' } | Select-Object -First 1
    if ($current) {
        $target = ($current -replace '^(?i)Z:\\: =>\s*','').TrimEnd('\')
        if ($target.Equals($shimRoot, [StringComparison]::OrdinalIgnoreCase)) { & subst.exe Z: /D | Out-Null }
    }
}

function Ensure-PatchType {
    if ('Fifa15Native' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Fifa15Native {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] data, int size, out IntPtr written);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] data, int size, out IntPtr read);
}
'@
}

function Launch-AndPatchFifa([string]$Exe) {
    Step 'Launching FIFA 15 and applying the relay certificate patch'
    $modulus = Join-Path $Root 'ca_modulus_1024.bin'
    if (-not (Test-Path $modulus) -or (Get-Item $modulus).Length -ne 128) { Fail 'Bundled relay certificate is missing or corrupt.' }
    $bytes = [IO.File]::ReadAllBytes($modulus)
    $launch = Start-Process $Exe -WorkingDirectory (Split-Path -Parent $Exe) -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    $process = $null
    do {
        Start-Sleep -Milliseconds 50
        $process = Get-Process fifa15 -ErrorAction SilentlyContinue | Select-Object -First 1
    } until ($process -or $launch.HasExited -or (Get-Date) -gt $deadline)
    if (-not $process) { Fail 'FIFA 15 did not remain running long enough to patch.' }

    Start-Sleep -Milliseconds 500
    Ensure-PatchType
    $handle = [Fifa15Native]::OpenProcess(0x1438, $false, [uint32]$process.Id)
    if ($handle -eq [IntPtr]::Zero) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail 'Windows refused access to patch FIFA 15 memory.'
    }
    try {
        $address = New-Object IntPtr ([Convert]::ToInt64('141E1F1A0',16))
        $written = [IntPtr]::Zero
        if (-not [Fifa15Native]::WriteProcessMemory($handle, $address, $bytes, $bytes.Length, [ref]$written) -or $written.ToInt64() -ne 128) {
            throw 'WriteProcessMemory failed'
        }
        $check = New-Object byte[] 128
        $read = [IntPtr]::Zero
        if (-not [Fifa15Native]::ReadProcessMemory($handle, $address, $check, 128, [ref]$read) -or $read.ToInt64() -ne 128) {
            throw 'ReadProcessMemory failed'
        }
        if ([Convert]::ToBase64String($check) -ne [Convert]::ToBase64String($bytes)) { throw 'certificate readback mismatch' }
    } catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail "Certificate patch failed: $_"
    } finally {
        [Fifa15Native]::CloseHandle($handle) | Out-Null
    }
    Info "FIFA 15 ready (PID $($process.Id)); relay certificate verified."
    return $process
}

function Do-Cleanup {
    Step 'Restoring this PC'
    Remove-HostsBlock
    Stop-OriginLsx
    $state = Read-State
    if ($state -and $state.tailscale_installed_by_package -and (Test-Path (Join-Path $Root 'tailscale-amd64.msi'))) {
        $tailscale = Find-Tailscale
        if ($tailscale) { & $tailscale logout 2>$null | Out-Null }
        Start-Process msiexec.exe -ArgumentList @('/x',"`"$(Join-Path $Root 'tailscale-amd64.msi')`"",'/quiet','/norestart') -Wait | Out-Null
    }
    Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    Info 'Cleanup complete.'
}

Ensure-Elevated
if ($Cleanup) { Do-Cleanup; exit 0 }
if (-not (Test-Path $ConfigPath)) { Fail 'APPLIANCE-CONFIG.json is missing. Ask thankyounes for a fresh ZIP.' }
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.host_ip) { Fail 'The package does not contain a host address.' }

$installedHere = $false
$evidenceFolder = $null
try {
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ' FIFA 15 REMOTE PLAYER - f15b' -ForegroundColor Green
    Write-Host ' Everything except game navigation is automatic.' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green

    $tailscale = Ensure-Tailscale -InstalledHere ([ref]$installedHere)
    Write-State ([pscustomobject]@{ tailscale_installed_by_package=$installedHere; started=(Get-Date).ToString('o') })
    Wait-HostReady $config.host_ip

    $fifa = Find-Fifa15
    if (-not $fifa) { Fail 'FIFA 15 could not be found automatically. The package assumes the game is already installed.' }
    Info "Found FIFA 15: $fifa"

    Prepare-OriginLsx
    Step 'Routing FIFA 15 services to thankyounes relay'
    Set-HostsBlock $config.host_ip
    Info 'Temporary routing installed; DirtySDK demangler remains local.'

    $game = Launch-AndPatchFifa $fifa
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host ' YOUR ONLY JOB NOW:' -ForegroundColor Yellow
    Write-Host ' Ultimate Team -> Online Single Match -> Search' -ForegroundColor Yellow
    Write-Host ' Do not cancel once searching.' -ForegroundColor Yellow
    Write-Host ' Close FIFA when the test is finished; cleanup is automatic.' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow

    Wait-Process -Id $game.Id
} finally {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $evidenceFolder = Join-Path $env:TEMP "fifa15-f15b-evidence-$stamp"
    New-Item -ItemType Directory -Path $evidenceFolder -Force | Out-Null
    try { ipconfig /all | Out-File (Join-Path $evidenceFolder 'ipconfig.txt') } catch {}
    try { route print | Out-File (Join-Path $evidenceFolder 'routes.txt') } catch {}
    try {
        Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Where-Object { $_.RemoteAddress -eq $config.host_ip } |
            Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess |
            ConvertTo-Json | Set-Content (Join-Path $evidenceFolder 'relay-connections.json')
    } catch {}
    try {
        [ordered]@{
            test_id=$config.test_id
            role='f15b'
            host_ip=$config.host_ip
            machine=$env:COMPUTERNAME
            utc=(Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content (Join-Path $evidenceFolder 'MANIFEST.json')
        $zip = Join-Path $desktop "FIFA15-F15B-EVIDENCE-$stamp.zip"
        Compress-Archive -Path (Join-Path $evidenceFolder '*') -DestinationPath $zip -Force
        Write-Host "Evidence: $zip" -ForegroundColor Green
    } catch {}
    Do-Cleanup
    if ($evidenceFolder -and (Test-Path $evidenceFolder)) { Remove-Item $evidenceFolder -Recurse -Force -ErrorAction SilentlyContinue }
}
