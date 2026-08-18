<#
.SYNOPSIS
Read-only dump of fifa15.exe's DECRYPTED sections from the live process.

.DESCRIPTION
`fifa15.exe`'s `.xtext` is Denuvo-encrypted on disk (entropy 8.000), which is why
every static hunt has failed. Denuvo must decrypt code to run it, so the plaintext
exists in the live process - but it decrypts **lazily, page by page, only as code
executes**. The dumps taken on 2026-08-15 prove this: their first third sits at
entropy ~6.4 (real x86-64) and everything past ~50% sits at 8.00, still encrypted,
because the game had not executed those paths yet. Their `.rdata` came out empty,
which is why not one known string appears in 68 MB.

**Therefore: dump while the client is sitting in the state you care about.** For the
joiner stall that means dumping WHILE Player B is stuck in the lobby transition, not
after quitting - by then it is too late for nothing, but the pages you need have only
been decrypted if they have actually run.

MECHANISM, and why it is not instrumentation
    OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ) + ReadProcessMemory

That is a read of another process's memory. It is **not** a debugger, **not** an
injection, and it never calls WriteProcessMemory. It is the same mechanism this
project already uses elsewhere on this exact build, and specifically the reason it
does not trip the anti-debug that crashes this build under CDB or Frida.

This script never writes to the game, never suspends it, and never loads anything
into it. It is still a material change from "nothing was attached", so every
attestation that says so must be updated alongside it - see RUNTIME-TEST.md.

NOTE ON SECTIONS - learned the hard way from the 20260818-153503 dump
    This binary's layout is not the usual one, and the obvious names are wrong:

        .arch     0x00001000   31,300,575 virtual   0 RAW   <- data/strings, filled at runtime
        .rdata    0x02E7C000          209 bytes            <- a stub, not the real rdata
        .xtext    0x02E7E000   69,763,072            <- code only, no strings
        .pdata a  0x02CE2000    1,626,112            <- RUNTIME_FUNCTION table: function bounds

    The first dump asked for `.xtext, .rdata, .data`. It returned 33 MB of genuinely
    decrypted code and **not one readable string**, because every string lives in
    `.arch` - which has ZERO raw size on disk and only exists once the process has
    populated it. `.data` does not exist at all.

    So the default below is `.arch` (the data), `.xtext` (the code), `.pdata a`
    (function boundaries, which make the code far easier to carve up) and `.bss`.

.PARAMETER OutDir
Where to write the dump. Defaults to a timestamped folder under runs/.

.PARAMETER Sections
Which PE sections to dump. Defaults to the three that matter: the encrypted code
section and the two that carry strings/data.

.PARAMETER SelfTest
Parse-and-logic check with no process access at all.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [string[]]$Sections = @('.arch', '.xtext', '.pdata a', '.bss'),
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace Fifa15Dump -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, IntPtr dwSize, out IntPtr lpNumberOfBytesRead);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr hObject);
'@

# PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ. Deliberately NOT
# PROCESS_VM_WRITE or PROCESS_VM_OPERATION: this handle cannot modify the game.
$PROCESS_ACCESS = 0x1010

function Read-Mem {
    param([IntPtr]$Handle, [long]$Address, [int]$Length)
    $buffer = New-Object byte[] $Length
    $read = [IntPtr]::Zero
    $ok = [Fifa15Dump.Native]::ReadProcessMemory($Handle, [IntPtr]$Address, $buffer, [IntPtr]$Length, [ref]$read)
    if (-not $ok) { return $null }
    if ($read.ToInt64() -ne $Length) {
        if ($read.ToInt64() -le 0) { return $null }
        $short = New-Object byte[] $read.ToInt64()
        [Array]::Copy($buffer, $short, $read.ToInt64())
        return $short
    }
    return $buffer
}

# Entropy on a sample, not the whole megabyte: a full byte-histogram over 68 MB in
# PowerShell is minutes of work, and a 64 KiB sample separates 6.4 from 8.0 just as
# decisively. That distinction is the only thing this number is used for.
function Get-SampleEntropy {
    param([byte[]]$Data, [int]$Offset, [int]$SampleSize = 65536)
    $end = [Math]::Min($Offset + $SampleSize, $Data.Length)
    if ($end -le $Offset) { return 0.0 }
    $counts = New-Object 'int[]' 256
    for ($i = $Offset; $i -lt $end; $i++) { $counts[$Data[$i]]++ }
    $n = $end - $Offset
    $h = 0.0
    foreach ($c in $counts) {
        if ($c -gt 0) { $p = $c / $n; $h -= $p * [Math]::Log($p, 2) }
    }
    return [Math]::Round($h, 2)
}

function Get-SectionTable {
    param([IntPtr]$Handle, [long]$Base)
    $dos = Read-Mem -Handle $Handle -Address $Base -Length 0x40
    if (-not $dos) { throw 'Could not read the DOS header. Run this elevated, from the same session as the game.' }
    if ($dos[0] -ne 0x4D -or $dos[1] -ne 0x5A) { throw 'Module base is not a PE image (no MZ).' }
    $lfanew = [BitConverter]::ToInt32($dos, 0x3C)

    $pe = Read-Mem -Handle $Handle -Address ($Base + $lfanew) -Length 0x108
    if (-not $pe) { throw 'Could not read the PE header.' }
    if ($pe[0] -ne 0x50 -or $pe[1] -ne 0x45) { throw 'No PE signature at e_lfanew.' }
    $numberOfSections = [BitConverter]::ToUInt16($pe, 6)
    $sizeOfOptional = [BitConverter]::ToUInt16($pe, 20)
    $sectionTableRva = $lfanew + 24 + $sizeOfOptional

    $raw = Read-Mem -Handle $Handle -Address ($Base + $sectionTableRva) -Length (40 * $numberOfSections)
    if (-not $raw) { throw 'Could not read the section table.' }

    $result = @()
    for ($i = 0; $i -lt $numberOfSections; $i++) {
        $o = $i * 40
        $name = [Text.Encoding]::ASCII.GetString($raw, $o, 8).TrimEnd([char]0)
        $result += [pscustomobject]@{
            Name           = $name
            VirtualSize    = [BitConverter]::ToUInt32($raw, $o + 8)
            VirtualAddress = [BitConverter]::ToUInt32($raw, $o + 12)
        }
    }
    return $result
}

if ($SelfTest) {
    Write-Output 'Self-test (no process is opened, no memory is read):'
    Write-Output ("  access mask: 0x{0:X} (QUERY_LIMITED_INFORMATION | VM_READ - no write, no operation)" -f $PROCESS_ACCESS)
    Write-Output "  sections requested: $($Sections -join ', ')"
    $sample = [byte[]](0..255 | ForEach-Object { $_ })
    $flat = Get-SampleEntropy -Data $sample -Offset 0 -SampleSize 256
    if ([Math]::Abs($flat - 8.0) -gt 0.01) { throw "entropy of a uniform byte range should be 8.00, got $flat" }
    $zeros = New-Object byte[] 4096
    $zero = Get-SampleEntropy -Data $zeros -Offset 0 -SampleSize 4096
    if ($zero -ne 0.0) { throw "entropy of all-zero data should be 0.00, got $zero" }
    Write-Output '  entropy: uniform=8.00, constant=0.00 (separates encrypted from decrypted)'
    Write-Output 'PASS: dumper logic verified without touching any process.'
    exit 0
}

$process = Get-Process -Name 'fifa15' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $process) {
    Write-Warning 'fifa15.exe is not running. Start the game and reach the state you want captured, then run this.'
    exit 0
}

if (-not $OutDir) {
    $OutDir = Join-Path (Get-Location) ("fifa15-decrypted-{0}-PID{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $process.Id)
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$base = $process.MainModule.BaseAddress.ToInt64()
Write-Host ("Reading fifa15.exe PID {0}, module base 0x{1:X}" -f $process.Id, $base) -ForegroundColor Cyan

$handle = [Fifa15Dump.Native]::OpenProcess($PROCESS_ACCESS, $false, $process.Id)
if ($handle -eq [IntPtr]::Zero) {
    Write-Warning "OpenProcess failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())). Run this PowerShell as Administrator."
    exit 0
}

$summary = @()
try {
    $table = Get-SectionTable -Handle $handle -Base $base
    Write-Host ("Sections present: {0}" -f (($table | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Gray

    foreach ($want in $Sections) {
        $section = $table | Where-Object { $_.Name -eq $want } | Select-Object -First 1
        if (-not $section) { Write-Warning "section $want not found in the image"; continue }

        $size = [int]$section.VirtualSize
        $addr = $base + $section.VirtualAddress
        Write-Host ("  dumping {0}  RVA 0x{1:X}  {2:N0} bytes" -f $section.Name, $section.VirtualAddress, $size) -ForegroundColor Gray

        $data = New-Object byte[] $size
        $chunk = 1MB
        $got = 0
        for ($off = 0; $off -lt $size; $off += $chunk) {
            $len = [Math]::Min($chunk, $size - $off)
            $part = Read-Mem -Handle $handle -Address ($addr + $off) -Length $len
            if ($part) { [Array]::Copy($part, 0, $data, $off, $part.Length); $got += $part.Length }
        }

        $safe = $section.Name.TrimStart('.').Replace(' ', '_')
        $path = Join-Path $OutDir ("{0}-RVA-{1:X8}.bin" -f $safe, $section.VirtualAddress)
        [IO.File]::WriteAllBytes($path, $data)

        # Per-megabyte entropy. This is the verification that matters: ~6.0-6.6 is
        # real x64 code, ~8.0 is still-encrypted. A section that is mostly 8.0 means
        # the game had not executed that code yet - dump again from further in.
        $rows = @()
        for ($off = 0; $off -lt $size; $off += 1MB) {
            $rows += [pscustomobject]@{ MB = [int]($off / 1MB); Entropy = (Get-SampleEntropy -Data $data -Offset $off) }
        }
        $decrypted = @($rows | Where-Object { $_.Entropy -gt 0 -and $_.Entropy -lt 7.5 }).Count
        $encrypted = @($rows | Where-Object { $_.Entropy -ge 7.5 }).Count
        $rows | ForEach-Object { "{0,6} MB  entropy {1}" -f $_.MB, $_.Entropy } |
            Set-Content -LiteralPath (Join-Path $OutDir ("{0}-entropy.txt" -f $safe)) -Encoding UTF8

        Write-Host ("    read {0:N0}/{1:N0} bytes | decrypted-looking MB: {2} | still-encrypted MB: {3}" -f $got, $size, $decrypted, $encrypted) -ForegroundColor Green
        $summary += [pscustomobject]@{
            section = $section.Name; rva = ("0x{0:X}" -f $section.VirtualAddress)
            virtual_size = $size; bytes_read = $got
            decrypted_mb = $decrypted; encrypted_mb = $encrypted
        }
    }
} finally {
    [void][Fifa15Dump.Native]::CloseHandle($handle)
}

[pscustomobject]@{
    purpose        = 'FIFA15 decrypted-section dump for offline matchmaking RE'
    read_only      = $true
    mechanism      = 'OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|PROCESS_VM_READ) + ReadProcessMemory'
    debugger       = $false
    injection      = $false
    writes_to_game = $false
    process_id     = $process.Id
    module_base    = ("0x{0:X}" -f $base)
    captured_utc   = (Get-Date).ToUniversalTime().ToString('o')
    machine        = $env:COMPUTERNAME
    sections       = $summary
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'dump-manifest.json') -Encoding UTF8

Write-Host "Dump written to $OutDir" -ForegroundColor Green
Write-Host 'Nothing was written to the game and no debugger was attached.' -ForegroundColor Gray
exit 0
