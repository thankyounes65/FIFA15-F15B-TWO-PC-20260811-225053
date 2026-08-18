<#
.SYNOPSIS
One broad, read-only capture of FIFA 15's live address space, taken while the
lobby is stuck.

.DESCRIPTION
DEAD END THIS REPLACES - DO NOT REPEAT IT

Two section dumps were taken (runs 20260818-153503 and -155040). Both looked
successful - 33 MB of `.xtext` genuinely decrypted - and both contained not one
readable program string. That is not a bad section list, it is the answer:

    .data     does not exist
    .rdata    a 209-byte stub
    .arch     31,300,575 virtual / ZERO raw; 97% zero when dumped, and the
              non-zero remainder is the packer's own little-endian pointer
              tables into 0x02EA****, i.e. offsets into .xtext
    .xtext    69,763,072, 33 MB of it decrypted; code only, 95% non-zero
    .bss      59,310; nothing

CORRECTION, after this script's first real run: the conclusion drawn from those
two dumps - "FIFA 15 keeps no program strings in any PE section" - is REFUTED.

The strings are in a section called `.reloc a` (RVA 0x1DDB000, 15,757,312 bytes,
read/write data), a Denuvo-renamed data section wearing the relocation table's
name. The section dumper never found it because its list is hardcoded to
.arch/.xtext/.pdata a/.bss. `.reloc a` is also plaintext ON DISK - verified that
`setPlayerAttributes` sits at raw 0x867320 = VA 0x142641F20, the same address
this scanner reported live - so the string corpus never needed a live capture at
all. `.xtext`, the code, is the part that genuinely does: it is encrypted on disk
and decrypts lazily as paths execute.

This scanner is still the right tool for anything that only exists at runtime -
heap state, which regions hold what, and confirming that memory matches the file
- and it is what found `.reloc a` in the first place. Walking the address space
does not depend on guessing a section name, which is exactly why it worked.

WHAT THIS DOES

    VirtualQueryEx    enumerate every region in the address space
    ReadProcessMemory read the committed, readable ones
    per region        printable-ASCII density, printable runs (ASCII and
                      UTF-16LE), and needle matches within those runs

and then keeps, under a total size budget:

    * every region containing a known needle          (priority)
    * the remaining regions by printable density, highest first, down to
      -MinPrintableDensity (default 10%)

`strings.txt` is written for EVERY readable region regardless of whether its
bytes are kept, because it is small, it compresses well, and it is the artifact
that actually answers "where do the strings live". `regions.txt` records the
complete map including what was skipped and why, so a miss is interpretable
rather than blank.

WHAT THIS IS NOT

Strictly read-only, and by the same mechanism as the section dumper:
PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ (0x1010), no debugger, no
injection, no thread suspension, and nothing is ever written into the game. It
is not a debugger and does not trip the anti-debug that crashes this build under
Frida or CDB.

WHAT THIS IS NOT, PART TWO

This is a means, not the answer. It locates where the client keeps its strings
and hands the next session an address-anchored corpus. Finding what actually
gates the client sending SetPlayerAttributes {REQ:"2"} is reverse-engineering
work that starts after this capture lands - disassembly around the addresses
this finds, with capstone. A successful run of this script is a starting point,
not a result.

TIMING

Denuvo decrypts lazily, page by page, only as code executes. Everything this
reads is only readable because the lobby path has already run. Take the capture
WHILE the joiner is stuck; a capture after the game closes is worthless.

OUTPUT
    regions.txt        full region map, every region, kept or not
    regions.csv        the same, machine-readable
    strings.txt        VA <tab> A|W <tab> text, for every readable region
    hits.txt           needle matches, with VA and the containing string
    modules.txt        loaded modules, so a VA can be attributed
    scan-manifest.json totals and the read-only attestation
    region-*.bin       only the regions that were kept

.PARAMETER RegionBudgetMB
Total budget for region-*.bin. The evidence ZIP has to stay sendable; the last
one that went out was 52 MB, and string-dense regions compress several-fold.

.PARAMETER SelfTest
Verify every decision this makes, with no process opened and no memory read.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [string]$ProcessName = 'fifa15',
    [int]$ProcessId = 0,
    [string[]]$Needles = @(
        'setPlayerAttributes',
        'updateMeshConnection',
        'finalizeGameCreation',
        'advanceGameState',
        'startMatchmaking',
        'resetDedicatedServer',
        'PEER_TO_PEER_FULL_MESH',
        'ACTIVE_CONNECTING',
        'GameManagerComponent',
        'NotifyGameSetup',
        'ConnectionGroup',
        'MeshEndpoint',
        'OSDK_gameMode',
        'squad/list',
        'blaze'
    ),
    [int]$RegionBudgetMB = 128,
    [int]$PerRegionCapMB = 64,
    [int]$StringsBudgetMB = 48,
    [int]$MinStringLength = 6,
    [int]$MaxStringLength = 512,
    [double]$MinPrintableDensity = 0.10,
    [int]$TimeLimitSeconds = 600,
    [switch]$Zip,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# powershell.exe -File hands a comma-separated argument to a [string[]] parameter
# as ONE string, not as an array. That silently produced a run with zero needle
# hits during self-testing, because the single "a,b,c" needle matches nothing.
# Every caller here launches via -File, so split it back out rather than relying
# on the caller to know.
function ConvertTo-NeedleList {
    param([string[]]$Raw)
    return , @($Raw |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique)
}
$Needles = ConvertTo-NeedleList -Raw $Needles
if ($Needles.Count -eq 0) { throw 'no needles left after parsing; pass at least one' }

# Read-only by construction: QUERY_LIMITED_INFORMATION | VM_READ.
# No VM_WRITE (0x20), no VM_OPERATION (0x8), no debug rights.
$PROCESS_ACCESS = 0x1010

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Fifa15Scan {

  [StructLayout(LayoutKind.Sequential)]
  public struct MemInfo64 {
    public ulong BaseAddress;
    public ulong AllocationBase;
    public uint  AllocationProtect;
    public uint  Alignment1;
    public ulong RegionSize;
    public uint  State;
    public uint  Protect;
    public uint  Type;
    public uint  Alignment2;
  }

  public class RegionRow {
    public ulong  Base;
    public ulong  Size;
    public ulong  AllocBase;
    public uint   State;
    public uint   Protect;
    public uint   Type;
    public bool   Readable;
    public bool   Scanned;
    public long   BytesRead;
    public long   Printable;
    public long   Holes;
    public int    Hits;
    public int    Strings;
    public bool   Kept;
    public long   Dumped;
    public bool   Truncated;
    public string Note = "";
    public double Density {
      get { return BytesRead > 0 ? (double)Printable / (double)BytesRead : 0.0; }
    }
  }

  public class Run {
    public ulong  Va;
    public string Text;
    public bool   Wide;
  }

  public static class Native {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, out MemInfo64 mbi, IntPtr len);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
  }

  // Pure decision logic, separated so the self-test can exercise all of it with
  // no process open and no memory read.
  public static class Scanner {
    public const uint MEM_COMMIT    = 0x1000;
    public const uint PAGE_GUARD    = 0x100;
    public const uint PAGE_NOACCESS = 0x01;

    public static bool IsReadable(uint state, uint protect) {
      if (state != MEM_COMMIT) return false;              // reserved or free
      if ((protect & PAGE_GUARD) != 0) return false;      // touching it would fire the guard
      uint p = protect & 0xFF;                            // strip NOCACHE / WRITECOMBINE
      if (p == PAGE_NOACCESS) return false;
      return p == 0x02 || p == 0x04 || p == 0x08 || p == 0x20 || p == 0x40 || p == 0x80;
    }

    static bool Printable(byte b) {
      return (b >= 0x20 && b <= 0x7E) || b == 0x09;
    }

    public static long CountPrintable(byte[] buf, int len) {
      long n = 0;
      for (int i = 0; i < len; i++) if (Printable(buf[i])) n++;
      return n;
    }

    public static List<Run> ExtractAscii(byte[] buf, int len, ulong va, int minLen, int maxLen) {
      List<Run> found = new List<Run>();
      int start = -1;
      for (int i = 0; i < len; i++) {
        if (Printable(buf[i])) {
          if (start < 0) start = i;
          if (i - start + 1 >= maxLen) {
            found.Add(Make(Encoding.ASCII.GetString(buf, start, maxLen), va + (ulong)start, false));
            start = -1;
          }
        } else {
          if (start >= 0 && i - start >= minLen)
            found.Add(Make(Encoding.ASCII.GetString(buf, start, i - start), va + (ulong)start, false));
          start = -1;
        }
      }
      if (start >= 0 && len - start >= minLen)
        found.Add(Make(Encoding.ASCII.GetString(buf, start, len - start), va + (ulong)start, false));
      return found;
    }

    // UTF-16LE runs, detected on even offsets from the region base. Region bases
    // are page-aligned, so this finds normally-aligned wide strings; odd-aligned
    // ones are not claimed to be covered.
    public static List<Run> ExtractWide(byte[] buf, int len, ulong va, int minLen, int maxLen) {
      List<Run> found = new List<Run>();
      int start = -1, count = 0;
      for (int i = 0; i + 1 < len; i += 2) {
        if (Printable(buf[i]) && buf[i + 1] == 0) {
          if (start < 0) { start = i; count = 0; }
          count++;
          if (count >= maxLen) { found.Add(MakeWide(buf, start, count, va)); start = -1; }
        } else {
          if (start >= 0 && count >= minLen) found.Add(MakeWide(buf, start, count, va));
          start = -1;
        }
      }
      if (start >= 0 && count >= minLen) found.Add(MakeWide(buf, start, count, va));
      return found;
    }

    static Run Make(string text, ulong va, bool wide) {
      Run r = new Run(); r.Va = va; r.Text = text; r.Wide = wide; return r;
    }

    static Run MakeWide(byte[] buf, int start, int count, ulong va) {
      char[] c = new char[count];
      for (int k = 0; k < count; k++) c[k] = (char)buf[start + k * 2];
      return Make(new string(c), va + (ulong)start, true);
    }
  }

  public class ScanSession : IDisposable {
    IntPtr h;
    StreamWriter strings;
    StreamWriter hits;
    string[] needles;

    public int  MinLen         = 6;
    public int  MaxLen         = 512;
    public int  ChunkBytes     = 64 * 1024 * 1024;
    public long StringsBudget  = 48L * 1024 * 1024;
    public long StringsBytes   = 0;
    public bool StringsTruncated = false;
    public long TotalStrings   = 0;
    public int  TotalHits      = 0;

    public ScanSession(int pid, int access, string stringsPath, string hitsPath, string[] needleList) {
      h = Native.OpenProcess(access, false, pid);
      if (h == IntPtr.Zero)
        throw new InvalidOperationException("OpenProcess failed, Win32 error " + Marshal.GetLastWin32Error());
      needles = needleList;
      UTF8Encoding enc = new UTF8Encoding(false);
      strings = new StreamWriter(stringsPath, false, enc, 1 << 20);
      hits    = new StreamWriter(hitsPath,    false, enc, 1 << 16);
      hits.WriteLine("# needle matches. VA is the address of the match itself.");
      strings.WriteLine("# VA\tenc\ttext   (A = ASCII, W = UTF-16LE)");
    }

    public RegionRow[] EnumRegions() {
      List<RegionRow> rows = new List<RegionRow>();
      ulong address = 0;
      IntPtr size = (IntPtr)Marshal.SizeOf(typeof(MemInfo64));
      while (address < 0x00007FFFFFFF0000UL) {
        MemInfo64 mbi;
        if (Native.VirtualQueryEx(h, (IntPtr)(long)address, out mbi, size) == IntPtr.Zero) break;
        if (mbi.RegionSize == 0) break;
        RegionRow r = new RegionRow();
        r.Base = mbi.BaseAddress; r.Size = mbi.RegionSize; r.AllocBase = mbi.AllocationBase;
        r.State = mbi.State; r.Protect = mbi.Protect; r.Type = mbi.Type;
        r.Readable = Scanner.IsReadable(mbi.State, mbi.Protect);
        rows.Add(r);
        ulong next = mbi.BaseAddress + mbi.RegionSize;
        if (next <= address) break;
        address = next;
      }
      return rows.ToArray();
    }

    // Fills buf[0..len) from the target. Tries the whole span first; on failure
    // falls back to 64 KB blocks so one unreadable page does not discard a whole
    // region. Unread bytes stay zero and are counted as holes.
    long ReadInto(ulong addr, byte[] buf, int len, out long holes) {
      holes = 0;
      IntPtr read;
      if (Native.ReadProcessMemory(h, (IntPtr)(long)addr, buf, (IntPtr)len, out read)) {
        long n = read.ToInt64();
        holes = len - n;
        return n;
      }
      const int BLOCK = 64 * 1024;
      byte[] tmp = new byte[BLOCK];
      long got = 0;
      for (int off = 0; off < len; off += BLOCK) {
        int want = Math.Min(BLOCK, len - off);
        IntPtr r2;
        if (Native.ReadProcessMemory(h, (IntPtr)(long)(addr + (ulong)off), tmp, (IntPtr)want, out r2)) {
          int n = (int)r2.ToInt64();
          Buffer.BlockCopy(tmp, 0, buf, off, n);
          got += n;
          holes += want - n;
        } else {
          holes += want;
        }
      }
      return got;
    }

    public void Analyze(RegionRow r) {
      if (!r.Readable) return;
      r.Scanned = true;
      ulong remaining = r.Size;
      ulong offset = 0;
      byte[] buf = null;
      while (remaining > 0) {
        int want = (int)Math.Min(remaining, (ulong)ChunkBytes);
        if (buf == null || buf.Length < want) buf = new byte[want];
        else Array.Clear(buf, 0, want);
        long holes;
        long got = ReadInto(r.Base + offset, buf, want, out holes);
        r.Holes += holes;
        if (got > 0) {
          int len = want;                       // holes are zeros, and zeros are not printable
          r.BytesRead += len;
          r.Printable += Scanner.CountPrintable(buf, len);
          Emit(r, Scanner.ExtractAscii(buf, len, r.Base + offset, MinLen, MaxLen));
          Emit(r, Scanner.ExtractWide (buf, len, r.Base + offset, MinLen, MaxLen));
        }
        offset    += (ulong)want;
        remaining -= (ulong)want;
      }
      if (r.Size > (ulong)ChunkBytes)
        r.Note = "chunked; runs crossing a chunk boundary are split";
    }

    void Emit(RegionRow r, List<Run> runs) {
      for (int i = 0; i < runs.Count; i++) {
        Run run = runs[i];
        r.Strings++;
        TotalStrings++;
        string line = "0x" + run.Va.ToString("X12") + "\t" + (run.Wide ? "W" : "A") + "\t" + run.Text;
        if (StringsBytes + line.Length + 2 <= StringsBudget) {
          strings.WriteLine(line);
          StringsBytes += line.Length + 2;
        } else {
          StringsTruncated = true;
        }
        for (int n = 0; n < needles.Length; n++) {
          int at = run.Text.IndexOf(needles[n], StringComparison.Ordinal);
          while (at >= 0) {
            ulong va = run.Va + (ulong)(run.Wide ? at * 2 : at);
            hits.WriteLine("0x" + va.ToString("X12") + "\tregion 0x" + r.Base.ToString("X12")
                           + "\t" + needles[n] + "\t" + Context(run.Text, at, needles[n].Length));
            r.Hits++; TotalHits++;
            at = run.Text.IndexOf(needles[n], at + 1, StringComparison.Ordinal);
          }
        }
      }
    }

    // A needle can land inside a 512-character run; print a window around the
    // match rather than the whole run, so hits.txt stays readable.
    static string Context(string text, int at, int needleLen) {
      int from = Math.Max(0, at - 60);
      int to   = Math.Min(text.Length, at + needleLen + 60);
      return (from > 0 ? "..." : "") + text.Substring(from, to - from) + (to < text.Length ? "..." : "");
    }

    public long Dump(RegionRow r, string path, long cap) {
      int len = (int)Math.Min(r.Size, (ulong)cap);
      byte[] buf = new byte[len];
      long holes;
      ReadInto(r.Base, buf, len, out holes);
      File.WriteAllBytes(path, buf);
      r.Dumped = len;
      r.Truncated = (ulong)len < r.Size;
      return len;
    }

    public void Dispose() {
      if (strings != null) { strings.Flush(); strings.Dispose(); strings = null; }
      if (hits    != null) { hits.Flush();    hits.Dispose();    hits = null; }
      if (h != IntPtr.Zero) { Native.CloseHandle(h); h = IntPtr.Zero; }
    }
  }
}
'@

# Which regions get their bytes kept, in what order, under the budget. Pure, so
# the self-test can prove the budget is actually enforced.
function Select-RegionsToDump {
    param(
        [object[]]$Rows,
        [double]$MinDensity,
        [long]$BudgetBytes,
        [long]$PerRegionCapBytes
    )
    $withHits = @($Rows | Where-Object { $_.Scanned -and $_.Hits -gt 0 } | Sort-Object { [double]$_.Base })
    $dense    = @($Rows | Where-Object { $_.Scanned -and $_.Hits -eq 0 -and $_.Density -ge $MinDensity } |
                  Sort-Object -Property @{ Expression = { $_.Density }; Descending = $true })
    $picked = @()
    $spent = [int64]0
    foreach ($r in (@($withHits) + @($dense))) {
        $take = [int64][Math]::Min([int64]$r.Size, $PerRegionCapBytes)
        if ($spent + $take -gt $BudgetBytes) { continue }
        $spent += $take
        $picked += $r
    }
    return , $picked
}

if ($SelfTest) {
    Write-Output 'Self-test - no process is opened, no memory is read:'
    Write-Output ("  access mask 0x{0:X}: QUERY_LIMITED_INFORMATION | VM_READ, no VM_WRITE, no VM_OPERATION" -f $PROCESS_ACCESS)

    if (-not [Fifa15Scan.Scanner]::IsReadable(0x1000, 0x04)) { throw 'committed read-write must be readable' }
    if ([Fifa15Scan.Scanner]::IsReadable(0x2000, 0x04))      { throw 'reserved memory must not be read' }
    if ([Fifa15Scan.Scanner]::IsReadable(0x1000, 0x104))     { throw 'guard pages must not be read' }
    if ([Fifa15Scan.Scanner]::IsReadable(0x1000, 0x01))      { throw 'PAGE_NOACCESS must not be read' }
    if (-not [Fifa15Scan.Scanner]::IsReadable(0x1000, 0x220)){ throw 'PAGE_EXECUTE_READ|NOCACHE must be readable' }
    Write-Output '  region filter: accepts committed readable, rejects reserved, guard and no-access'

    $hay = [Text.Encoding]::ASCII.GetBytes("`0`0`0`0setPlayerAttributes`0short`0`0updateMeshConnection`0")
    $runs = [Fifa15Scan.Scanner]::ExtractAscii($hay, $hay.Length, [uint64]0x140000000, 6, 512)
    $texts = @($runs | ForEach-Object { $_.Text })
    if ($texts -notcontains 'setPlayerAttributes')  { throw 'ASCII run extraction missed setPlayerAttributes' }
    if ($texts -notcontains 'updateMeshConnection') { throw 'ASCII run extraction missed updateMeshConnection' }
    if ($texts -contains 'short')                   { throw 'runs shorter than the minimum must be dropped' }
    $first = @($runs | Where-Object { $_.Text -eq 'setPlayerAttributes' })[0]
    if ($first.Va -ne [uint64]0x140000004) { throw ("VA should be base+4, got 0x{0:X}" -f $first.Va) }
    Write-Output '  ASCII runs: found at the right VAs, sub-minimum runs dropped'

    $wideBytes = New-Object byte[] 64
    $w = 'REQ_gate_wide'
    for ($i = 0; $i -lt $w.Length; $i++) { $wideBytes[8 + $i * 2] = [byte][char]$w[$i] }
    $wruns = [Fifa15Scan.Scanner]::ExtractWide($wideBytes, $wideBytes.Length, [uint64]0x7FF000000000, 6, 512)
    if (@($wruns | ForEach-Object { $_.Text }) -notcontains $w) { throw 'UTF-16LE run extraction failed' }
    if (@($wruns)[0].Va -ne [uint64]0x7FF000000008) { throw 'UTF-16LE VA is wrong' }
    Write-Output '  UTF-16LE runs: found at the right VA'

    $mixed = New-Object byte[] 100
    for ($i = 0; $i -lt 20; $i++) { $mixed[$i] = 0x41 }
    $pc = [Fifa15Scan.Scanner]::CountPrintable($mixed, $mixed.Length)
    if ($pc -ne 20) { throw "printable count should be 20, got $pc" }
    Write-Output '  density: 20/100 printable counted exactly, so the 10% floor means what it says'

    $fake = @(
        [pscustomobject]@{ Base=[uint64]0x1000; Size=[uint64]100; Scanned=$true; Hits=0; Density=0.90 },
        [pscustomobject]@{ Base=[uint64]0x2000; Size=[uint64]100; Scanned=$true; Hits=2; Density=0.01 },
        [pscustomobject]@{ Base=[uint64]0x3000; Size=[uint64]100; Scanned=$true; Hits=0; Density=0.50 },
        [pscustomobject]@{ Base=[uint64]0x4000; Size=[uint64]100; Scanned=$true; Hits=0; Density=0.02 },
        [pscustomobject]@{ Base=[uint64]0x5000; Size=[uint64]100; Scanned=$false; Hits=9; Density=0.99 }
    )
    $sel = Select-RegionsToDump -Rows $fake -MinDensity 0.10 -BudgetBytes 250 -PerRegionCapBytes 1000
    if ($sel.Count -ne 2) { throw "budget of 250 over 100-byte regions should admit 2, admitted $($sel.Count)" }
    if ($sel[0].Base -ne 0x2000) { throw 'a needle hit must outrank a denser region with no hit' }
    if ($sel[1].Base -ne 0x1000) { throw 'remaining picks must go by density, highest first' }
    $sel2 = Select-RegionsToDump -Rows $fake -MinDensity 0.10 -BudgetBytes 10000 -PerRegionCapBytes 1000
    if (@($sel2 | Where-Object { $_.Base -eq 0x4000 }).Count -ne 0) { throw 'below-floor density must never be picked' }
    if (@($sel2 | Where-Object { $_.Base -eq 0x5000 }).Count -ne 0) { throw 'unscanned regions must never be picked' }
    Write-Output '  selection: hits first, then density, budget enforced, floor and unscanned respected'

    $split = ConvertTo-NeedleList -Raw @('a,b , c', 'b', '', 'd')
    if (($split -join '|') -ne 'a|b|c|d') { throw "needle parsing produced '$($split -join '|')'" }
    if ($Needles.Count -lt 2) { throw 'the default needle list collapsed to a single needle' }
    Write-Output ("  needles: a -File comma list splits back into {0} separate needles, deduped" -f $split.Count)

    Write-Output 'PASS: every decision this script makes is verified, with no process touched.'
    exit 0
}

if ([IntPtr]::Size -ne 8) {
    Write-Warning 'This must run under 64-bit PowerShell to read a 64-bit process. Use C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe.'
    exit 0
}

if ($ProcessId -gt 0) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) {
        Write-Warning "PID $ProcessId is not running."
        exit 0
    }
} else {
    $candidateProcs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($candidateProcs.Count -eq 0) {
        Write-Warning "$ProcessName is not running. Reach the state you care about - the stuck lobby - and then run this."
        exit 0
    }
    if ($candidateProcs.Count -gt 1) {
        Write-Warning ("{0} instances of {1} are running (PIDs {2}); scanning the first. Use -ProcessId to choose." -f `
            $candidateProcs.Count, $ProcessName, (($candidateProcs | ForEach-Object { $_.Id }) -join ', '))
    }
    $process = $candidateProcs[0]
}

if (-not $OutDir) {
    $OutDir = Join-Path (Get-Location) ("fifa15-memscan-{0}-PID{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $process.Id)
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stringsPath = Join-Path $OutDir 'strings.txt'
$hitsPath    = Join-Path $OutDir 'hits.txt'

# Module list first: without it a VA in strings.txt cannot be attributed.
$moduleRows = @()
try {
    foreach ($m in $process.Modules) {
        $moduleRows += ("0x{0:X12}  {1,12:N0}  {2}" -f [uint64]$m.BaseAddress.ToInt64(), $m.ModuleMemorySize, $m.FileName)
    }
} catch {
    $moduleRows += "module enumeration unavailable: $($_.Exception.Message)"
}
$moduleRows | Set-Content -LiteralPath (Join-Path $OutDir 'modules.txt') -Encoding UTF8

Write-Host ("Walking the address space of {0} PID {1} ..." -f $process.ProcessName, $process.Id) -ForegroundColor Cyan

$session = $null
$rows = @()
$timedOut = $false
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $session = New-Object Fifa15Scan.ScanSession($process.Id, $PROCESS_ACCESS, $stringsPath, $hitsPath, $Needles)
    $session.MinLen        = $MinStringLength
    $session.MaxLen        = $MaxStringLength
    $session.StringsBudget = [int64]$StringsBudgetMB * 1MB

    $rows = $session.EnumRegions()
    $readable = @($rows | Where-Object { $_.Readable })
    Write-Host ("  {0:N0} regions, {1:N0} readable, {2:N0} MB committed and readable" -f `
        $rows.Count, $readable.Count, (($readable | Measure-Object -Property Size -Sum).Sum / 1MB)) -ForegroundColor Gray

    $done = 0
    foreach ($r in $readable) {
        if ($sw.Elapsed.TotalSeconds -ge $TimeLimitSeconds) {
            $timedOut = $true
            $r.Note = 'not scanned: time limit reached'
            continue
        }
        $session.Analyze($r)
        $done++
        if (($done % 200) -eq 0) {
            Write-Host ("  {0}/{1} regions, {2:N0} strings, {3} needle hits so far" -f `
                $done, $readable.Count, $session.TotalStrings, $session.TotalHits) -ForegroundColor DarkGray
        }
    }

    $picked = Select-RegionsToDump -Rows $rows -MinDensity $MinPrintableDensity `
                                   -BudgetBytes ([int64]$RegionBudgetMB * 1MB) `
                                   -PerRegionCapBytes ([int64]$PerRegionCapMB * 1MB)
    foreach ($r in $picked) {
        $name = "region-{0:X12}-{1}.bin" -f $r.Base, $r.Size
        $bytes = $session.Dump($r, (Join-Path $OutDir $name), [int64]$PerRegionCapMB * 1MB)
        $r.Kept = $true
        Write-Host ("  kept 0x{0:X12}  {1,7:N1} MB  density {2:P1}  hits {3}" -f `
            $r.Base, ($bytes / 1MB), $r.Density, $r.Hits) -ForegroundColor Green
    }
} finally {
    if ($session) { $session.Dispose() }
    $sw.Stop()
}

$header = @(
    'base              size           state  protect  type      dens%   strings  hits  kept  note',
    '----------------  -------------  -----  -------  --------  ------  -------  ----  ----  ----'
)
$regionLines = $rows | ForEach-Object {
    "0x{0:X12}  {1,13:N0}  0x{2:X4} 0x{3:X5}  0x{4:X6}  {5,5:N1}  {6,7:N0}  {7,4}  {8,4}  {9}" -f `
        $_.Base, $_.Size, $_.State, $_.Protect, $_.Type, ($_.Density * 100), $_.Strings, $_.Hits,
        $(if ($_.Kept) { 'yes' } elseif ($_.Readable) { 'no' } else { '-' }),
        $(if ($_.Note) { $_.Note } elseif (-not $_.Readable) { 'not readable' } else { '' })
}
($header + $regionLines) | Set-Content -LiteralPath (Join-Path $OutDir 'regions.txt') -Encoding UTF8

$rows | Select-Object `
    @{n='base';       e={ "0x{0:X12}" -f $_.Base }},
    @{n='size';       e={ $_.Size }},
    @{n='alloc_base'; e={ "0x{0:X12}" -f $_.AllocBase }},
    @{n='state';      e={ "0x{0:X}" -f $_.State }},
    @{n='protect';    e={ "0x{0:X}" -f $_.Protect }},
    @{n='type';       e={ "0x{0:X}" -f $_.Type }},
    Readable, Scanned, BytesRead, Printable, Holes, Strings, Hits, Kept, Dumped, Truncated,
    @{n='density';    e={ [math]::Round($_.Density, 4) }},
    Note |
    Export-Csv -LiteralPath (Join-Path $OutDir 'regions.csv') -NoTypeInformation -Encoding UTF8

$readableRows = @($rows | Where-Object { $_.Readable })
$scannedRows  = @($rows | Where-Object { $_.Scanned })
$keptRows     = @($rows | Where-Object { $_.Kept })
$manifest = [pscustomobject]@{
    purpose        = 'FIFA15 live address-space capture: the PE sections contain no strings, so this walks memory instead'
    read_only      = $true
    debugger       = $false
    injection      = $false
    thread_suspend = $false
    writes_to_game = $false
    mechanism      = 'OpenProcess(0x1010) + VirtualQueryEx + ReadProcessMemory'
    process_name   = $process.ProcessName
    process_id     = $process.Id
    machine        = $env:COMPUTERNAME
    captured_utc   = (Get-Date).ToUniversalTime().ToString('o')
    elapsed_seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    time_limit_reached = $timedOut
    regions_total  = $rows.Count
    regions_readable = $readableRows.Count
    regions_scanned  = $scannedRows.Count
    regions_kept     = $keptRows.Count
    bytes_scanned    = (($scannedRows | Measure-Object -Property BytesRead -Sum).Sum)
    bytes_unreadable_holes = (($scannedRows | Measure-Object -Property Holes -Sum).Sum)
    bytes_dumped     = (($keptRows | Measure-Object -Property Dumped -Sum).Sum)
    strings_found    = $(if ($session) { $session.TotalStrings } else { 0 })
    strings_truncated_by_budget = $(if ($session) { $session.StringsTruncated } else { $false })
    needle_hits      = $(if ($session) { $session.TotalHits } else { 0 })
    needles          = $Needles
    min_string_length = $MinStringLength
    min_printable_density = $MinPrintableDensity
    region_budget_mb = $RegionBudgetMB
    strings_budget_mb = $StringsBudgetMB
    wide_strings_note = 'UTF-16LE runs are detected on even offsets from each region base; odd-aligned wide strings are not claimed to be covered'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'scan-manifest.json') -Encoding UTF8

$totalBytes = (Get-ChildItem -LiteralPath $OutDir -File -Recurse | Measure-Object -Property Length -Sum).Sum
Write-Host ''
Write-Host ("Scanned {0:N0} MB across {1:N0} of {2:N0} readable regions in {3:N0}s." -f `
    ($manifest.bytes_scanned / 1MB), $scannedRows.Count, $readableRows.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host ("{0:N0} strings, {1:N0} needle hits, {2} region(s) kept. Output {3:N0} MB in {4}" -f `
    $manifest.strings_found, $manifest.needle_hits, $keptRows.Count, ($totalBytes / 1MB), $OutDir) -ForegroundColor Green
if ($timedOut) {
    Write-Host 'Time limit reached: regions.txt marks what was not scanned. Re-run with a larger -TimeLimitSeconds if that matters.' -ForegroundColor Yellow
}
if ($manifest.strings_found -eq 0) {
    Write-Host 'No strings anywhere in readable memory. regions.txt is the whole map, so that is a real answer, not a blank one.' -ForegroundColor Yellow
}

if ($Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = "$OutDir.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($OutDir, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Host ("ZIP: {0} ({1:N0} MB)" -f $zipPath, ((Get-Item -LiteralPath $zipPath).Length / 1MB)) -ForegroundColor Green
}

exit 0
