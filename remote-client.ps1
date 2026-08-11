[CmdletBinding()]
param(
    [switch]$Cleanup,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$ManagedHostnamesPath = Join-Path $Root 'fifa15-managed-hostnames.ps1'
$StatePath = Join-Path $env:ProgramData 'FIFA15-Preservation\two-pc-appliance-state.json'
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$StartMarker = '# BEGIN FIFA15-TWO-PC-APPLIANCE'
$EndMarker = '# END FIFA15-TWO-PC-APPLIANCE'
$ReadyPort = 48215
$PackageRevision = 'hardening-v2'
$RelayHostnames = @()
$PatchPreimageSha256 = $null

function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Step([string]$Text) { Write-Host "`n>> $Text" -ForegroundColor Cyan }
function Fail([string]$Text) { Write-Host "`nSTOP: $Text" -ForegroundColor Red; exit 1 }

function Ensure-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
        if ($Cleanup) { $args += '-Cleanup' }
        try {
            $child = Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait -PassThru
            exit $child.ExitCode
        } catch {
            Fail 'Administrator approval was cancelled or Windows could not start the elevated test.'
        }
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

function Confirm-HostsBlock([string]$HostIp) {
    $lines = @(Get-Content $HostsPath)
    foreach ($name in $RelayHostnames) {
        $expected = "$HostIp`t$name"
        if ($lines -notcontains $expected) { Fail "Hosts routing verification failed for $name." }
    }
    if ($lines -notcontains "127.0.0.1`tpeach.online.ea.com") {
        Fail 'Hosts routing verification failed for the local DirtySDK demangler entry.'
    }
    Info "Hosts routing verified: $($RelayHostnames.Count) relay names + local demangler pin."
}

function Find-Tailscale {
    foreach ($path in @("$env:ProgramFiles\Tailscale\tailscale.exe", "$env:ProgramFiles(x86)\Tailscale\tailscale.exe")) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-ManifestBinaryEntry([string]$Name) {
    if (-not (Test-Path $ManifestPath)) { return $null }
    try { $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json } catch { return $null }
    if ($manifest.PSObject.Properties.Name -contains 'binary_files') {
        return @($manifest.binary_files) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    }
    if ($manifest -is [System.Array]) {
        return @($manifest) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    }
    return $null
}

function Assert-BinaryIntegrity([string]$Name, [switch]$Optional) {
    $path = Join-Path $Root $Name
    if (-not (Test-Path $path)) {
        if ($Optional) { return }
        Fail "Required package file is missing: $Name"
    }
    $entry = Get-ManifestBinaryEntry $Name
    if (-not $entry -or -not $entry.sha256) { Fail "No binary integrity record exists for $Name." }
    if ($entry.bytes -and (Get-Item $path).Length -ne [int64]$entry.bytes) {
        Fail "$Name has the wrong size. Re-download/extract the tester package."
    }
    $actual = (Get-FileHash $path -Algorithm SHA256).Hash
    if (-not $actual.Equals([string]$entry.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Name failed its SHA-256 integrity check. Re-download/extract the tester package."
    }
}

function Assert-SupportedWindowsArchitecture {
    $nativeArch = $null
    try {
        $nativeArch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction Stop).PROCESSOR_ARCHITECTURE
    } catch {}
    if (-not $nativeArch) { $nativeArch = $env:PROCESSOR_ARCHITECTURE }
    if (-not [Environment]::Is64BitOperatingSystem -or $nativeArch -ne 'AMD64') {
        Fail "This tester package requires native x64 Windows (AMD64). Detected '$nativeArch'. Windows-on-ARM/Parallels is intentionally blocked because it is not a valid runtime for this test."
    }
    Info "PASS: native Windows architecture is $nativeArch."
}

function Invoke-PackageSelfTest {
    Step 'Preflight: validating the tester package'
    foreach ($name in @(
        'APPLIANCE-CONFIG.json',
        'PACKAGE-MANIFEST.json',
        'fifa15-managed-hostnames.ps1',
        'lsx-table.json',
        'portable-lsx-responder.ps1',
        'remote-client.ps1',
        'README-FIRST.txt',
        'RUN-FIFA15-F15B.bat',
        'ca_modulus_1024.bin'
    )) {
        if (-not (Test-Path (Join-Path $Root $name))) { Fail "Required package file is missing: $name" }
    }

    try { $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { Fail "APPLIANCE-CONFIG.json is invalid: $_" }
    if ($config.format -ne 1 -or $config.role -ne 'f15b' -or -not $config.host_ip) {
        Fail 'APPLIANCE-CONFIG.json is missing the expected f15b test fields.'
    }
    $parsedIp = $null
    if (-not [Net.IPAddress]::TryParse([string]$config.host_ip, [ref]$parsedIp)) {
        Fail "APPLIANCE-CONFIG.json contains an invalid host_ip: $($config.host_ip)"
    }

    try { $lsxTable = Get-Content (Join-Path $Root 'lsx-table.json') -Raw | ConvertFrom-Json } catch { Fail "lsx-table.json is invalid: $_" }
    if ($lsxTable.format -ne 1 -or $lsxTable.title -notmatch '15' -or -not $lsxTable.table) {
        Fail 'lsx-table.json is not the expected FIFA 15 LSX table.'
    }

    Assert-BinaryIntegrity 'ca_modulus_1024.bin'
    Assert-BinaryIntegrity 'tailscale-amd64.msi' -Optional

    $lsxScript = Join-Path $Root 'portable-lsx-responder.ps1'
    $table = Join-Path $Root 'lsx-table.json'
    $selfTestOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lsxScript -TablePath $table -SelfTest 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Fail "Bundled LSX responder self-test failed: $($selfTestOutput -join ' ')"
    }
    Info 'PASS: package files, JSON, binary assets, and LSX responder self-test.'
}

function Test-TcpPort([string]$HostIp, [int]$Port, [int]$TimeoutMs = 2500) {
    $client = $null
    try {
        $client = New-Object Net.Sockets.TcpClient
        $task = $client.ConnectAsync($HostIp, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Ensure-Tailscale([ref]$InstalledHere, [ref]$JoinedHere) {
    $tailscale = Find-Tailscale
    if (-not $tailscale) {
        $msi = Join-Path $Root 'tailscale-amd64.msi'
        if (-not (Test-Path $msi)) { Fail 'The bundled private-network installer is missing. Ask thankyounes for a fresh ZIP.' }
        Assert-BinaryIntegrity 'tailscale-amd64.msi'
        Step 'Installing the private network component silently'
        $process = Start-Process msiexec.exe -ArgumentList @('/i',"`"$msi`"",'/quiet','/norestart') -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010)) { Fail "Private-network install failed with Windows Installer code $($process.ExitCode)." }
        $InstalledHere.Value = $true
        Write-State ([pscustomobject]@{
            tailscale_installed_by_package = $true
            tailscale_joined_by_package = $false
            started = (Get-Date).ToString('o')
        })
        $deadline = (Get-Date).AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 500
            $tailscale = Find-Tailscale
        } until ($tailscale -or (Get-Date) -gt $deadline)
        if (-not $tailscale) { Fail 'The private network installed but its command-line tool was not found.' }
    }

    $existingIp = @(& $tailscale ip -4 2>$null) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    if ($existingIp) {
        Info "Existing private-network connection detected at $($existingIp.Trim()); it will not be reconfigured or logged out."
        return $tailscale
    }

    $keyPath = Join-Path $Root 'JOIN.key'
    if (-not (Test-Path $keyPath)) {
        Fail 'No existing private-network connection and JOIN.key is missing. Ask thankyounes for a fresh test key/package.'
    }
    $key = (Get-Content $keyPath -Raw).Trim()
    if (-not $key -or -not $key.StartsWith('tskey-')) {
        Fail 'JOIN.key is empty or invalid. Ask thankyounes for a fresh test key/package.'
    }

    Step 'Joining the private FIFA test network automatically'
    $output = & $tailscale up --auth-key=$key --hostname=fifa15-f15b --unattended=true 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "Could not join the private network: $($output -join ' ')" }
    $JoinedHere.Value = $true
    Write-State ([pscustomobject]@{
        tailscale_installed_by_package = [bool]$InstalledHere.Value
        tailscale_joined_by_package = $true
        started = (Get-Date).ToString('o')
    })
    Remove-Item $keyPath -Force -ErrorAction SilentlyContinue

    $deadline = (Get-Date).AddSeconds(30)
    $ip = $null
    do {
        Start-Sleep -Milliseconds 500
        $ip = @(& $tailscale ip -4 2>$null) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    } until ($ip -or (Get-Date) -gt $deadline)
    if (-not $ip) { Fail 'The private network joined but did not become connected. Ask thankyounes for a fresh package/key.' }
    Info "Private network ready: $($ip.Trim())"
    return $tailscale
}

function Wait-HostReady([string]$HostIp) {
    Step 'Waiting for thankyounes PC to be fully ready'
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        $client = $null
        try {
            $client = New-Object Net.Sockets.TcpClient
            $client.ReceiveTimeout = 2000
            $client.SendTimeout = 2000
            $task = $client.ConnectAsync($HostIp, $ReadyPort)
            if ($task.Wait(1500) -and $client.Connected) {
                $stream = $client.GetStream()
                $buffer = New-Object byte[] 16
                $count = $stream.Read($buffer, 0, $buffer.Length)
                $text = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                if ($text -match 'READY') {
                    $client.Close()
                    if (-not (Test-TcpPort -HostIp $HostIp -Port 42127 -TimeoutMs 3000)) {
                        Fail 'Host reports READY, but the FIFA relay port 42127 is not reachable from this PC.'
                    }
                    Info 'Host reports READY and relay TCP 42127 is reachable.'
                    return
                }
            }
        } catch {} finally {
            if ($client) { $client.Close() }
        }
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
    foreach ($drive in @('C','D','E','F','G','H')) {
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

function Select-Fifa15Interactive {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select your FIFA 15 fifa15.exe'
        $dialog.Filter = 'FIFA 15 (fifa15.exe)|fifa15.exe|All files (*.*)|*.*'
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    } catch {}
    return $null
}

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { return 0 }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -le 0 -or $peOffset -gt ($stream.Length - 6)) { return 0 }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return 0 }
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Assert-FifaExecutable([string]$Path) {
    if (-not (Test-Path $Path)) { Fail 'The selected FIFA 15 executable does not exist.' }
    if (-not ([IO.Path]::GetFileName($Path)).Equals('fifa15.exe', [StringComparison]::OrdinalIgnoreCase)) {
        Fail 'The selected file is not named fifa15.exe.'
    }
    $machine = Get-PeMachine $Path
    if ($machine -ne 0x8664) { Fail ("The selected fifa15.exe is not an x64 PE executable (machine=0x{0:X4})." -f $machine) }
    $hash = (Get-FileHash $Path -Algorithm SHA256).Hash
    Info "PASS: FIFA executable is x64; SHA-256 $hash"
    return $hash
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
    $lsxProcess = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$lsxScript`"",'-TablePath',"`"$table`"") -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(20)
    $listener = $null
    do {
        Start-Sleep -Milliseconds 300
        if ($lsxProcess.HasExited) { break }
        $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $lsxProcess.Id } | Select-Object -First 1
    } until ($listener -or (Get-Date) -gt $deadline)
    if (-not $listener) {
        Stop-Process -Id $lsxProcess.Id -Force -ErrorAction SilentlyContinue
        Fail 'The bundled LSX responder did not become the verified owner of 127.0.0.1:3216.'
    }
    Info "Bundled LSX responder owns 127.0.0.1:3216 (PID $($lsxProcess.Id))."

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

    Start-Sleep -Seconds 1
    $verified = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 3216 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -eq $lsxProcess.Id } | Select-Object -First 1
    if (-not $verified) { Fail 'The bundled LSX responder lost ownership of 127.0.0.1:3216 during startup.' }
    Info 'PASS: LSX responder still owns port 3216 after EA compatibility startup.'
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

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') } finally { $sha.Dispose() }
}

function Launch-AndPatchFifa([string]$Exe) {
    Step 'Launching FIFA 15 and applying the relay certificate patch'
    $stale = @(Get-Process fifa15 -ErrorAction SilentlyContinue)
    if ($stale.Count -gt 0) { Fail 'A fifa15.exe process appeared before launch. Close FIFA completely and run the tester again.' }

    $modulus = Join-Path $Root 'ca_modulus_1024.bin'
    Assert-BinaryIntegrity 'ca_modulus_1024.bin'
    $bytes = [IO.File]::ReadAllBytes($modulus)

    $launch = Start-Process $Exe -WorkingDirectory (Split-Path -Parent $Exe) -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    $process = $null
    do {
        Start-Sleep -Milliseconds 50
        $process = Get-Process -Id $launch.Id -ErrorAction SilentlyContinue
    } until ($process -or $launch.HasExited -or (Get-Date) -gt $deadline)
    if (-not $process -or -not $process.ProcessName.Equals('fifa15', [StringComparison]::OrdinalIgnoreCase)) {
        Fail 'The launched FIFA 15 process did not remain running long enough to patch.'
    }

    Start-Sleep -Milliseconds 500
    try { $mainModule = $process.MainModule } catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail 'Could not inspect the launched FIFA 15 main module.'
    }
    $expectedBase = [Convert]::ToInt64('140000000',16)
    $addressValue = [Convert]::ToInt64('141E1F1A0',16)
    $baseValue = $mainModule.BaseAddress.ToInt64()
    $endValue = $baseValue + [int64]$mainModule.ModuleMemorySize
    if ($baseValue -ne $expectedBase -or $addressValue -lt $baseValue -or ($addressValue + 128) -gt $endValue) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail ("This FIFA build/runtime does not map the known certificate patch location safely (base=0x{0:X}, imageEnd=0x{1:X}). No memory was modified." -f $baseValue,$endValue)
    }

    Ensure-PatchType
    $handle = [Fifa15Native]::OpenProcess(0x1438, $false, [uint32]$process.Id)
    if ($handle -eq [IntPtr]::Zero) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail 'Windows refused access to inspect/patch FIFA 15 memory.'
    }
    try {
        $address = New-Object IntPtr $addressValue
        $before = New-Object byte[] 128
        $readBefore = [IntPtr]::Zero
        if (-not [Fifa15Native]::ReadProcessMemory($handle, $address, $before, 128, [ref]$readBefore) -or $readBefore.ToInt64() -ne 128) {
            throw 'pre-patch ReadProcessMemory failed'
        }
        $script:PatchPreimageSha256 = Get-BytesSha256 $before
        Info "Certificate patch site verified readable; preimage SHA-256 $script:PatchPreimageSha256"

        if ([Convert]::ToBase64String($before) -ne [Convert]::ToBase64String($bytes)) {
            $written = [IntPtr]::Zero
            if (-not [Fifa15Native]::WriteProcessMemory($handle, $address, $bytes, $bytes.Length, [ref]$written) -or $written.ToInt64() -ne 128) {
                throw 'WriteProcessMemory failed'
            }
        } else {
            Info 'Relay certificate was already present at the verified patch site; write skipped.'
        }

        $check = New-Object byte[] 128
        $read = [IntPtr]::Zero
        if (-not [Fifa15Native]::ReadProcessMemory($handle, $address, $check, 128, [ref]$read) -or $read.ToInt64() -ne 128) {
            throw 'post-patch ReadProcessMemory failed'
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
    if ($state -and $state.tailscale_joined_by_package) {
        $tailscale = Find-Tailscale
        if ($tailscale) { & $tailscale logout 2>$null | Out-Null }
    }
    if ($state -and $state.tailscale_installed_by_package -and (Test-Path (Join-Path $Root 'tailscale-amd64.msi'))) {
        $process = Start-Process msiexec.exe -ArgumentList @('/x',"`"$(Join-Path $Root 'tailscale-amd64.msi')`"",'/quiet','/norestart') -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010)) { Info "Warning: private-network uninstall returned Windows Installer code $($process.ExitCode)." }
    }
    Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    Info 'Cleanup complete.'
}

if ($Cleanup) {
    Ensure-Elevated
    Do-Cleanup
    exit 0
}

if (-not (Test-Path $ManagedHostnamesPath)) { Fail 'fifa15-managed-hostnames.ps1 is missing. Re-download/extract the tester package.' }
. $ManagedHostnamesPath
$RelayHostnames = $Fifa15RedirectableHostnames
if (-not $RelayHostnames -or $RelayHostnames.Count -lt 1) { Fail 'Managed FIFA 15 hostname list did not load.' }

Assert-SupportedWindowsArchitecture
Invoke-PackageSelfTest
if ($SelfTest) {
    Write-Host "`nALL TESTER PACKAGE SELF-TESTS PASSED. No admin rights, network changes, or FIFA launch were used." -ForegroundColor Green
    exit 0
}

Ensure-Elevated
if (-not (Test-Path $ConfigPath)) { Fail 'APPLIANCE-CONFIG.json is missing. Ask thankyounes for a fresh ZIP.' }
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.host_ip) { Fail 'The package does not contain a host address.' }

Step 'Preflight: checking for a stale FIFA 15 process'
if (Get-Process fifa15 -ErrorAction SilentlyContinue) {
    Fail 'FIFA 15 is already running. Close it completely, then run this tester again. Nothing has been changed yet.'
}
Info 'PASS: no stale fifa15.exe process.'

Step 'Preflight: locating and validating FIFA 15'
$fifa = Find-Fifa15
if (-not $fifa) {
    Info 'FIFA 15 was not found in the common install locations. Select fifa15.exe in the file picker.'
    $fifa = Select-Fifa15Interactive
}
if (-not $fifa) { Fail 'FIFA 15 could not be found or selected. Nothing has been changed yet.' }
$fifaHash = Assert-FifaExecutable $fifa
Info "Found FIFA 15: $fifa"

$installedHere = $false
$joinedHere = $false
$evidenceFolder = $null
try {
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ' FIFA 15 REMOTE PLAYER - f15b' -ForegroundColor Green
    Write-Host " Package revision: $PackageRevision" -ForegroundColor Green
    Write-Host ' Everything except game navigation is automatic.' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green

    $tailscale = Ensure-Tailscale -InstalledHere ([ref]$installedHere) -JoinedHere ([ref]$joinedHere)
    Write-State ([pscustomobject]@{
        tailscale_installed_by_package = $installedHere
        tailscale_joined_by_package = $joinedHere
        started = (Get-Date).ToString('o')
    })
    Wait-HostReady $config.host_ip

    Prepare-OriginLsx
    Step 'Routing FIFA 15 services to thankyounes relay'
    Set-HostsBlock $config.host_ip
    Confirm-HostsBlock $config.host_ip
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
            package_revision=$PackageRevision
            host_ip=$config.host_ip
            machine=$env:COMPUTERNAME
            native_architecture=(try { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE } catch { $env:PROCESSOR_ARCHITECTURE })
            fifa_exe_path=$fifa
            fifa_exe_sha256=$fifaHash
            patch_preimage_sha256=$PatchPreimageSha256
            tailscale_installed_by_package=$installedHere
            tailscale_joined_by_package=$joinedHere
            utc=(Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content (Join-Path $evidenceFolder 'MANIFEST.json')
        $zip = Join-Path $desktop "FIFA15-F15B-EVIDENCE-$stamp.zip"
        Compress-Archive -Path (Join-Path $evidenceFolder '*') -DestinationPath $zip -Force
        Write-Host "Evidence: $zip" -ForegroundColor Green
    } catch {}
    try { Do-Cleanup } catch { Write-Host "Cleanup warning: $_" -ForegroundColor Yellow }
    if ($evidenceFolder -and (Test-Path $evidenceFolder)) { Remove-Item $evidenceFolder -Recurse -Force -ErrorAction SilentlyContinue }
}
