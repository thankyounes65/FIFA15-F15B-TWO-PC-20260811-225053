[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$OutputPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'APPLIANCE-CONFIG.json'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$CandidateId = 'FIFA15-MM-V16-B-NATIVE-HANDOFF'
$PackageAttestation = 'F15B-GITHUB-DIAGNOSTIC-20260815-V16-NATIVE-HANDOFF-1'
$ExpectedHostBranch = 'integration/test-matchmaking-b-native-handoff-v16'
$ExpectedHostBuild = 'build_pairing_gsu_npsi_v15.rs'
$WireBaseline = '53dbaafb32030d6790beb0c16d336acd68cc1d49'
$ExpectedExeBytes = 87268816L
$ExpectedExeSha256 = '3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB'
$ExpectedImageBase = [Convert]::ToUInt64('140000000',16)
$Targets = [ordered]@{
    GAMESETUP_POST_STAGE_1 = 0x047BF5BF
    GAMESETUP_POST_STAGE_2 = 0x047BF830
    MM_SESSION_SUCCESS_BRIDGE = 0x034A5CF0
    GAME_CALLBACK_1 = 0x034A6350
    GAME_CALLBACK_2 = 0x034A5E60
    GAME_CALLBACK_3 = 0x034A5F00
    MM_VALIDATED_DISPATCH_0B = 0x04859E69
    MM_VALIDATED_CORE_0B = 0x047BE2F9
    PRE_GAME_NOTIFY = 0x047DDEB0
    PRE_GAME_STATE = 0x047DDFF3
}

function Read-Contract {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing $ConfigPath" }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Missing $ManifestPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ([string]$config.candidate_id -ne $CandidateId) { throw 'APPLIANCE-CONFIG candidate mismatch' }
    if ([string]$config.package_attestation -ne $PackageAttestation) { throw 'APPLIANCE-CONFIG package mismatch' }
    if ([string]$config.expected_host_branch -ne $ExpectedHostBranch) { throw 'APPLIANCE-CONFIG host branch mismatch' }
    if ([string]$config.expected_host_build -ne $ExpectedHostBuild) { throw 'APPLIANCE-CONFIG host build mismatch' }
    if ([string]$manifest.matchmaking_overlay.candidate_id -ne $CandidateId) { throw 'PACKAGE-MANIFEST candidate mismatch' }
    if ([string]$manifest.matchmaking_overlay.package_attestation -ne $PackageAttestation) { throw 'PACKAGE-MANIFEST package mismatch' }
    if ([string]$manifest.matchmaking_overlay.wire_protocol_baseline_commit -ne $WireBaseline) { throw 'PACKAGE-MANIFEST wire baseline mismatch' }
    if (-not [bool]$manifest.matchmaking_overlay.diagnostic_only) { throw 'PACKAGE-MANIFEST must declare diagnostic_only=true' }
}

function Resolve-FifaExe {
    $dirs = New-Object Collections.Generic.List[string]
    if ($GameDir) { $dirs.Add($GameDir) }
    if ($env:FIFA15_GAME_DIR) { $dirs.Add($env:FIFA15_GAME_DIR) }
    foreach ($p in @(
        'C:\Program Files (x86)\Origin Games\FIFA 15',
        'C:\Program Files\EA Games\FIFA 15',
        'C:\Program Files (x86)\EA Games\FIFA 15',
        'C:\Games\FIFA 15','D:\Games\FIFA 15','E:\Games\FIFA 15','F:\Games\FIFA 15','G:\Games\FIFA 15'
    )) { $dirs.Add($p) }
    foreach ($dir in $dirs) {
        try {
            $full = [IO.Path]::GetFullPath($dir)
            $exe = Join-Path $full 'fifa15.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
        } catch {}
    }
    throw 'Could not auto-resolve the exact Player B fifa15.exe. Set FIFA15_GAME_DIR or use -GameDir; FIFA was not started.'
}

function Read-PeLayout([string]$Path) {
    $fs = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $br = New-Object IO.BinaryReader($fs)
    try {
        $fs.Position = 0x3c
        $pe = $br.ReadInt32()
        $fs.Position = $pe
        if ($br.ReadUInt32() -ne 0x00004550) { throw 'PE signature mismatch' }
        [void]$br.ReadUInt16()
        $sections = [int]$br.ReadUInt16()
        $fs.Position += 12
        $optionalSize = [int]$br.ReadUInt16()
        [void]$br.ReadUInt16()
        $optionalStart = $fs.Position
        if ($br.ReadUInt16() -ne 0x20b) { throw 'Expected PE32+ optional header' }
        $fs.Position = $optionalStart + 24
        $imageBase = $br.ReadUInt64()
        $sectionStart = $optionalStart + $optionalSize
        $items = @()
        $fs.Position = $sectionStart
        for ($i=0; $i -lt $sections; $i++) {
            $name = [Text.Encoding]::ASCII.GetString($br.ReadBytes(8)).Trim([char]0)
            $virtualSize = $br.ReadUInt32()
            $virtualAddress = $br.ReadUInt32()
            $sizeRaw = $br.ReadUInt32()
            $ptrRaw = $br.ReadUInt32()
            $fs.Position += 16
            $items += [pscustomobject]@{ Name=$name; VirtualSize=[uint64]$virtualSize; VirtualAddress=[uint64]$virtualAddress; SizeRaw=[uint64]$sizeRaw; PtrRaw=[uint64]$ptrRaw }
        }
        return [pscustomobject]@{ ImageBase=[uint64]$imageBase; Sections=$items }
    }
    finally { $br.Close(); $fs.Close() }
}

function Get-RvaFingerprint([string]$Path,$Layout,[uint64]$Rva) {
    $section = $null
    foreach ($s in $Layout.Sections) {
        $span = [Math]::Max([double]$s.VirtualSize,[double]$s.SizeRaw)
        if ($Rva -ge $s.VirtualAddress -and $Rva -lt ($s.VirtualAddress + [uint64]$span)) { $section = $s; break }
    }
    if (-not $section) { throw ('RVA 0x{0:X8} is not mapped by any PE section' -f $Rva) }
    $delta = $Rva - $section.VirtualAddress
    if ($delta -ge $section.SizeRaw) { throw ('RVA 0x{0:X8} is virtual-only in section {1}' -f $Rva,$section.Name) }
    $offset = $section.PtrRaw + $delta
    $fs = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $fs.Position = [int64]$offset
        $bytes = New-Object byte[] 16
        $count = $fs.Read($bytes,0,$bytes.Length)
        if ($count -ne 16) { throw ('short read at RVA 0x{0:X8}' -f $Rva) }
        return [pscustomobject]@{ Section=$section.Name; FileOffset=[uint64]$offset; Bytes=(($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ') }
    }
    finally { $fs.Close() }
}

function Invoke-SelfTest {
    Read-Contract
    if ($Targets.Count -ne 10) { throw "Expected 10 native boundary RVAs, got $($Targets.Count)" }
    if ($Targets.MM_VALIDATED_DISPATCH_0B -ne 0x04859E69) { throw '0x0B dispatcher RVA drifted' }
    if ($Targets.MM_SESSION_SUCCESS_BRIDGE -ne 0x034A5CF0) { throw 'MatchSession success bridge RVA drifted' }
    if ($Targets.PRE_GAME_STATE -ne 0x047DDFF3) { throw 'PRE_GAME state RVA drifted' }
    Write-Host 'PASS: v16 native handoff attestor pins exact executable hash, image base, wire baseline and 10 same-title boundary RVAs.' -ForegroundColor Green
    Write-Host 'NOTE: this attestor is read-only and proves address-map identity, NOT execution reachability.' -ForegroundColor Yellow
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
Read-Contract
$exe = Resolve-FifaExe
$item = Get-Item -LiteralPath $exe
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToUpperInvariant()
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $OutputPath) { $OutputPath = Join-Path $desktop ("FIFA15-F15B-NATIVE-V16-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmssfff')) }
$rows = New-Object Collections.Generic.List[string]
$rows.Add('FIFA 15 Player B v16 native handoff address-map attestation')
$rows.Add("generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))")
$rows.Add("candidate_id=$CandidateId")
$rows.Add("package_attestation=$PackageAttestation")
$rows.Add("wire_protocol_baseline_commit=$WireBaseline")
$rows.Add('execution_probe=false')
$rows.Add('instrumentation_policy=READ_ONLY_STATIC_PE_ATTESTATION_NO_PROCESS_ATTACH_NO_MEMORY_WRITE')
$rows.Add('interpretation=address-map identity only; absence/presence of execution is not inferred from this file')
$rows.Add("fifa_path=$exe")
$rows.Add("fifa_bytes=$($item.Length)")
$rows.Add("fifa_sha256=$hash")
if ([int64]$item.Length -ne $ExpectedExeBytes -or $hash -ne $ExpectedExeSha256) {
    $rows.Add('native_attestation=FAIL_EXACT_EXECUTABLE_MISMATCH')
    $rows | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "NATIVE_V16_LOG=$OutputPath" -ForegroundColor Gray
    Write-Host 'STOP: Player B fifa15.exe does not match the exact known-good build; runtime result would be VOID.' -ForegroundColor Red
    exit 44
}
$layout = Read-PeLayout $exe
$rows.Add(('image_base=0x{0:X}' -f $layout.ImageBase))
if ($layout.ImageBase -ne $ExpectedImageBase) {
    $rows.Add('native_attestation=FAIL_IMAGE_BASE_MISMATCH')
    $rows | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    exit 45
}
foreach ($entry in $Targets.GetEnumerator()) {
    $fp = Get-RvaFingerprint -Path $exe -Layout $layout -Rva ([uint64]$entry.Value)
    $va = $ExpectedImageBase + [uint64]$entry.Value
    $rows.Add(('target={0} rva=0x{1:X8} va=0x{2:X} section={3} file_offset=0x{4:X} bytes16={5}' -f $entry.Key,[uint64]$entry.Value,$va,$fp.Section,$fp.FileOffset,$fp.Bytes))
}
$rows.Add('native_attestation=PASS_EXACT_EXECUTABLE_AND_ADDRESS_MAP')
$rows | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "PASS: exact Player B FIFA15 executable/address map attested: $OutputPath" -ForegroundColor Green
Write-Host 'NOTE: no process was attached and no memory was modified; this does not claim callback execution.' -ForegroundColor Yellow
exit 0
