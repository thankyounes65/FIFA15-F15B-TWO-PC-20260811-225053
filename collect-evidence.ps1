[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$DesktopPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Read-At([IO.FileStream]$Stream, [long]$Offset, [int]$Count) {
    if ($Offset -lt 0 -or $Count -lt 0) { throw "invalid read offset=$Offset count=$Count" }
    $buffer = New-Object byte[] $Count
    $Stream.Position = $Offset
    $done = 0
    while ($done -lt $Count) {
        $n = $Stream.Read($buffer, $done, $Count - $done)
        if ($n -le 0) { throw "unexpected EOF at offset=$($Offset + $done)" }
        $done += $n
    }
    return $buffer
}

function U32([byte[]]$Bytes, [int]$Offset = 0) { return [BitConverter]::ToUInt32($Bytes, $Offset) }
function U64([byte[]]$Bytes, [int]$Offset = 0) { return [BitConverter]::ToUInt64($Bytes, $Offset) }

function Read-U32At([IO.FileStream]$Stream, [long]$Offset) { return U32 (Read-At $Stream $Offset 4) }
function Read-U64At([IO.FileStream]$Stream, [long]$Offset) { return U64 (Read-At $Stream $Offset 8) }

function Read-MiniDumpString([IO.FileStream]$Stream, [uint32]$Rva) {
    if ($Rva -eq 0) { return '' }
    $byteCount = [int](Read-U32At $Stream $Rva)
    if ($byteCount -le 0 -or $byteCount -gt 65536) { return '' }
    return [Text.Encoding]::Unicode.GetString((Read-At $Stream ($Rva + 4) $byteCount))
}

function Get-Hex([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join ' ')
}

function Find-Module($Modules, [uint64]$Address) {
    foreach ($m in @($Modules)) {
        $end = [uint64]$m.Base + [uint64]$m.Size
        if ($Address -ge [uint64]$m.Base -and $Address -lt $end) { return $m }
    }
    return $null
}

function Read-DumpMemory([IO.FileStream]$Stream, $Ranges, [uint64]$Address, [int]$Count) {
    if ($Count -le 0) { return $null }
    foreach ($r in @($Ranges)) {
        $start = [uint64]$r.Start
        $size = [uint64]$r.Size
        if ($Address -ge $start) {
            $delta = $Address - $start
            if ($delta -le $size -and [uint64]$Count -le ($size - $delta)) {
                return Read-At $Stream ([long]([uint64]$r.FileRva + $delta)) $Count
            }
        }
    }
    return $null
}

function Get-MiniDumpSummary([string]$DumpPath) {
    $stream = New-Object IO.FileStream($DumpPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $header = Read-At $stream 0 32
        if ([Text.Encoding]::ASCII.GetString($header,0,4) -ne 'MDMP') { throw 'not a Windows minidump' }
        $streamCount = [int](U32 $header 8)
        $directoryRva = [uint32](U32 $header 12)
        if ($streamCount -lt 1 -or $streamCount -gt 512) { throw "implausible stream count $streamCount" }

        $directories = @()
        for ($i = 0; $i -lt $streamCount; $i++) {
            $d = Read-At $stream ($directoryRva + (12 * $i)) 12
            $directories += [pscustomobject]@{ Type=[uint32](U32 $d 0); Size=[uint32](U32 $d 4); Rva=[uint32](U32 $d 8) }
        }

        $modules = @()
        $moduleStream = @($directories | Where-Object { $_.Type -eq 4 } | Select-Object -First 1)
        if ($moduleStream.Count -gt 0) {
            $rva = [uint32]$moduleStream[0].Rva
            $count = [int](Read-U32At $stream $rva)
            if ($count -gt 4096) { throw "implausible module count $count" }
            for ($i = 0; $i -lt $count; $i++) {
                $row = Read-At $stream ($rva + 4 + (108 * $i)) 108
                $base = [uint64](U64 $row 0)
                $size = [uint32](U32 $row 8)
                $nameRva = [uint32](U32 $row 20)
                $name = Read-MiniDumpString $stream $nameRva
                $modules += [pscustomobject]@{ Base=$base; Size=$size; Name=$name }
            }
        }

        $ranges = @()
        $memoryList = @($directories | Where-Object { $_.Type -eq 5 } | Select-Object -First 1)
        if ($memoryList.Count -gt 0) {
            $rva = [uint32]$memoryList[0].Rva
            $count = [int](Read-U32At $stream $rva)
            if ($count -gt 1000000) { throw "implausible memory range count $count" }
            for ($i = 0; $i -lt $count; $i++) {
                $row = Read-At $stream ($rva + 4 + (16 * $i)) 16
                $ranges += [pscustomobject]@{ Start=[uint64](U64 $row 0); Size=[uint64](U32 $row 8); FileRva=[uint64](U32 $row 12) }
            }
        } else {
            $memory64 = @($directories | Where-Object { $_.Type -eq 9 } | Select-Object -First 1)
            if ($memory64.Count -gt 0) {
                $rva = [uint32]$memory64[0].Rva
                $count = [uint64](Read-U64At $stream $rva)
                $dataRva = [uint64](Read-U64At $stream ($rva + 8))
                if ($count -gt 1000000) { throw "implausible memory64 range count $count" }
                $cursor = $dataRva
                for ([uint64]$i = 0; $i -lt $count; $i++) {
                    $row = Read-At $stream ([long]($rva + 16 + (16 * $i))) 16
                    $start = [uint64](U64 $row 0)
                    $size = [uint64](U64 $row 8)
                    $ranges += [pscustomobject]@{ Start=$start; Size=$size; FileRva=$cursor }
                    $cursor += $size
                }
            }
        }

        $exceptionStream = @($directories | Where-Object { $_.Type -eq 6 } | Select-Object -First 1)
        if ($exceptionStream.Count -eq 0) { throw 'minidump has no exception stream' }
        $er = [uint32]$exceptionStream[0].Rva
        $threadId = [uint32](Read-U32At $stream $er)
        $exceptionCode = [uint32](Read-U32At $stream ($er + 8))
        $exceptionFlags = [uint32](Read-U32At $stream ($er + 12))
        $exceptionAddress = [uint64](Read-U64At $stream ($er + 24))
        $parameterCount = [int](Read-U32At $stream ($er + 32))
        if ($parameterCount -gt 15) { $parameterCount = 15 }
        $parameters = @()
        for ($i = 0; $i -lt $parameterCount; $i++) { $parameters += [uint64](Read-U64At $stream ($er + 40 + (8 * $i))) }

        $contextSize = [int](Read-U32At $stream ($er + 160))
        $contextRva = [uint32](Read-U32At $stream ($er + 164))
        $context = if ($contextSize -gt 0 -and $contextSize -le 65536) { Read-At $stream $contextRva $contextSize } else { $null }
        $registerOffsets = [ordered]@{
            RAX=0x78; RCX=0x80; RDX=0x88; RBX=0x90; RSP=0x98; RBP=0xA0; RSI=0xA8; RDI=0xB0;
            R8=0xB8; R9=0xC0; R10=0xC8; R11=0xD0; R12=0xD8; R13=0xE0; R14=0xE8; R15=0xF0; RIP=0xF8
        }
        $regs = [ordered]@{}
        foreach ($name in $registerOffsets.Keys) {
            $offset = [int]$registerOffsets[$name]
            $regs[$name] = if ($context -and $context.Length -ge ($offset + 8)) { [uint64](U64 $context $offset) } else { [uint64]0 }
        }

        $faultModule = Find-Module $modules $exceptionAddress
        $faultModuleName = if ($faultModule) { [IO.Path]::GetFileName([string]$faultModule.Name) } else { '<unknown>' }
        $faultRva = if ($faultModule) { [uint64]($exceptionAddress - [uint64]$faultModule.Base) } else { [uint64]0 }

        $accessType = '<unknown>'
        $accessAddress = [uint64]0
        if ($exceptionCode -eq 0xC0000005 -and $parameters.Count -ge 2) {
            switch ([uint64]$parameters[0]) { 0 { $accessType='read' } 1 { $accessType='write' } 8 { $accessType='execute' } default { $accessType="type_$($parameters[0])" } }
            $accessAddress = [uint64]$parameters[1]
        }

        $signature = 'UNKNOWN'
        if ($faultModuleName -ieq 'fifa15.exe' -and $faultRva -eq 0x3455F73) { $signature = 'HOST_HTTP_CALLBACK_3455F73' }
        if ($faultModuleName -ieq 'fifa15.exe' -and $faultRva -eq 0x30627B5) { $signature = 'PLAYER_B_PROTOHTTP_APND_30627B5' }

        $rows = New-Object Collections.Generic.List[string]
        $file = Get-Item -LiteralPath $DumpPath
        $rows.Add('FIFA 15 automatic crash summary')
        $rows.Add("generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))")
        $rows.Add("computer=$env:COMPUTERNAME")
        $rows.Add("dump_name=$($file.Name)")
        $rows.Add("dump_path=$($file.FullName)")
        $rows.Add("dump_bytes=$($file.Length)")
        $rows.Add("dump_last_write_utc=$($file.LastWriteTimeUtc.ToString('o'))")
        $rows.Add("known_signature=$signature")
        $rows.Add("thread_id=$threadId")
        $rows.Add(('exception_code=0x{0:x8}' -f $exceptionCode))
        $rows.Add(('exception_flags=0x{0:x8}' -f $exceptionFlags))
        $rows.Add(('exception_address=0x{0:x16}' -f $exceptionAddress))
        $rows.Add("fault_module=$faultModuleName")
        if ($faultModule) { $rows.Add(('fault_rva=0x{0:x}' -f $faultRva)) }
        $rows.Add("access_type=$accessType")
        if ($accessAddress -ne 0) { $rows.Add(('access_address=0x{0:x16}' -f $accessAddress)) }
        $rows.Add("stream_count=$streamCount")
        $rows.Add("memory_range_count=$($ranges.Count)")
        $rows.Add('')
        $rows.Add('[registers]')
        foreach ($name in $regs.Keys) { $rows.Add(('{0}=0x{1:x16}' -f $name,[uint64]$regs[$name])) }

        $rip = [uint64]$regs['RIP']
        if ($rip -ne 0) {
            $codeStart = if ($rip -ge 32) { $rip - 32 } else { [uint64]0 }
            $code = Read-DumpMemory $stream $ranges $codeStart 96
            if ($code) {
                $rows.Add('')
                $rows.Add('[fault_code_bytes]')
                $rows.Add(('start=0x{0:x16}' -f $codeStart))
                $rows.Add((Get-Hex $code))
            }
        }

        $rsp = [uint64]$regs['RSP']
        if ($rsp -ne 0) {
            $stack = Read-DumpMemory $stream $ranges $rsp 1024
            if ($stack) {
                $rows.Add('')
                $rows.Add('[stack_module_addresses]')
                $seen = @{}
                $emitted = 0
                for ($i = 0; $i -le ($stack.Length - 8) -and $emitted -lt 48; $i += 8) {
                    $q = [uint64](U64 $stack $i)
                    $m = Find-Module $modules $q
                    if ($m) {
                        $key = ('{0:x16}' -f $q)
                        if (-not $seen.ContainsKey($key)) {
                            $seen[$key] = $true
                            $rows.Add(('stack+0x{0:x3}=0x{1:x16} {2}+0x{3:x}' -f $i,$q,[IO.Path]::GetFileName([string]$m.Name),($q-[uint64]$m.Base)))
                            $emitted++
                        }
                    }
                }
            }
        }

        $rows.Add('')
        $rows.Add('[mapped_register_memory]')
        foreach ($name in @('RCX','RDX','RBX','RBP','RSI','RDI','R8','R9')) {
            $address = [uint64]$regs[$name]
            if ($address -eq 0) { continue }
            $bytes = Read-DumpMemory $stream $ranges $address 128
            if ($bytes) {
                $rows.Add(('{0}=0x{1:x16}' -f $name,$address))
                $rows.Add((Get-Hex $bytes))
            }
        }

        return @($rows)
    } finally {
        $stream.Dispose()
    }
}

function Get-DiagStartUtc([string]$DiagPath) {
    $line = Get-Content -LiteralPath $DiagPath -ErrorAction SilentlyContinue | Where-Object { $_ -like 'started_utc=*' } | Select-Object -First 1
    if ($line) {
        $value = $line.Substring('started_utc='.Length)
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    }
    return (Get-Item -LiteralPath $DiagPath).CreationTimeUtc.AddMinutes(-1)
}

function Wait-LatestFifaDump([datetime]$SinceUtc, [int]$TimeoutSeconds = 60) {
    $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    $lastPath = $null
    $lastSize = -1L
    $stable = 0
    do {
        $candidates = @()
        $local = Join-Path $env:LOCALAPPDATA 'CrashDumps'
        if (Test-Path -LiteralPath $local) {
            $candidates += @(Get-ChildItem -LiteralPath $local -Filter 'fifa15*.dmp' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc.AddMinutes(-1) })
        }
        if ($candidates.Count -eq 0) {
            $wer = Join-Path $env:ProgramData 'Microsoft\Windows\WER'
            if (Test-Path -LiteralPath $wer) {
                $candidates += @(Get-ChildItem -LiteralPath $wer -Filter '*.dmp' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*fifa15*' -and $_.LastWriteTimeUtc -ge $SinceUtc.AddMinutes(-1) })
            }
        }
        $latest = @($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        if ($latest.Count -gt 0) {
            $item = $latest[0]
            if ($lastPath -eq $item.FullName -and $lastSize -eq $item.Length -and $item.Length -gt 0) { $stable++ } else { $stable = 0 }
            $lastPath = $item.FullName
            $lastSize = $item.Length
            if ($stable -ge 2) { return $item.FullName }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date).ToUniversalTime() -lt $deadline)
    return $lastPath
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { throw "PowerShell parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('PLAYER_B_PROTOHTTP_APND_30627B5','HOST_HTTP_CALLBACK_3455F73','Compress-Archive','CrashDumps','SEND ONLY THIS ZIP')) {
        if (-not $source.Contains($marker)) { throw "missing evidence collector marker: $marker" }
    }
    Write-Host 'PASS: evidence collector parses and contains minidump exception/register/module extraction plus one-ZIP bundling.' -ForegroundColor Green
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch { Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}

$desktop = if ($DesktopPath) { $DesktopPath } else { [Environment]::GetFolderPath('Desktop') }
if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) { throw "Desktop path unavailable: $desktop" }

$diag = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-DIAG-*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
if ($diag.Count -eq 0) { throw 'No FIFA15-F15B-DIAG-*.txt was found on the Desktop.' }
$diag = $diag[0]
$stamp = [IO.Path]::GetFileNameWithoutExtension($diag.Name).Substring('FIFA15-F15B-DIAG-'.Length)
$sinceUtc = Get-DiagStartUtc $diag.FullName

$forwarder = @(Get-ChildItem -LiteralPath $desktop -Filter 'FIFA15-F15B-FORWARDER-*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $sinceUtc.AddMinutes(-2) } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)

$summaryPath = Join-Path $desktop "FIFA15-F15B-CRASH-$stamp.txt"
$dumpPath = Wait-LatestFifaDump -SinceUtc $sinceUtc -TimeoutSeconds 60
if ($dumpPath) {
    try {
        $summary = Get-MiniDumpSummary -DumpPath $dumpPath
        $summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    } catch {
        @(
            'FIFA 15 automatic crash summary',
            "generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
            "computer=$env:COMPUTERNAME",
            "dump_path=$dumpPath",
            'dump_found=true',
            'parse_status=FAILED',
            "parse_error=$($_.Exception.Message)",
            'NOTE: keep the local .dmp in case deeper analysis is required.'
        ) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    }
} else {
    @(
        'FIFA 15 automatic crash summary',
        "generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
        "computer=$env:COMPUTERNAME",
        'dump_found=false',
        'known_signature=NO_NEW_FIFA_DUMP',
        "searched_since_utc=$($sinceUtc.ToString('o'))",
        'NOTE: no new fifa15 minidump was found for this run.'
    ) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
}

$bundleName = "FIFA15-F15B-EVIDENCE-$stamp"
$stageRoot = Join-Path $env:TEMP $bundleName
Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
Copy-Item -LiteralPath $diag.FullName -Destination (Join-Path $stageRoot $diag.Name) -Force
Copy-Item -LiteralPath $summaryPath -Destination (Join-Path $stageRoot ([IO.Path]::GetFileName($summaryPath))) -Force
if ($forwarder.Count -gt 0) {
    Copy-Item -LiteralPath $forwarder[0].FullName -Destination (Join-Path $stageRoot $forwarder[0].Name) -Force
} else {
    @(
        'FIFA15 Player-B forwarder log placeholder',
        'forwarder_log_found=false',
        "searched_since_utc=$($sinceUtc.ToString('o'))"
    ) | Set-Content -LiteralPath (Join-Path $stageRoot "FIFA15-F15B-FORWARDER-MISSING-$stamp.log") -Encoding UTF8
}

$zipPath = Join-Path $desktop "$bundleName.zip"
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -LiteralPath $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' PLAYER-B EVIDENCE BUNDLE READY' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "SEND ONLY THIS ZIP TO THANKYOUNES: $zipPath" -ForegroundColor Yellow
Write-Host 'The large .dmp stays local. Keep it temporarily only if deeper analysis is requested.' -ForegroundColor Gray
exit 0
