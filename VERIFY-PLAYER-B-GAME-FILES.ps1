[CmdletBinding()]
param(
    [string]$GameDir,
    [switch]$Strict,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$ContractPath = Join-Path $Root 'PLAYER-B-KNOWN-GOOD.json'

function Fail([string]$Text) {
    Write-Host "STOP: $Text" -ForegroundColor Red
    exit 1
}

function Resolve-GameDir {
    if ($GameDir) {
        $candidate = [IO.Path]::GetFullPath($GameDir)
        if (-not (Test-Path -LiteralPath (Join-Path $candidate 'fifa15.exe') -PathType Leaf)) {
            Fail "No fifa15.exe found in -GameDir '$candidate'."
        }
        return $candidate
    }

    foreach ($candidate in @(
        'C:\Program Files (x86)\Origin Games\FIFA 15',
        'C:\Program Files\EA Games\FIFA 15',
        'C:\Games\FIFA 15',
        'F:\Games\FIFA 15'
    )) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'fifa15.exe') -PathType Leaf) {
            return $candidate
        }
    }

    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.OpenFileDialog
    $picker.Title = 'Select the fifa15.exe whose Player B files you want to verify'
    $picker.Filter = 'FIFA 15 executable (fifa15.exe)|fifa15.exe|Executable files (*.exe)|*.exe'
    $picker.CheckFileExists = $true
    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Fail 'No FIFA 15 installation was selected.'
    }
    return Split-Path -Parent $picker.FileName
}

function Invoke-SelfTest {
    if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
        throw 'PLAYER-B-KNOWN-GOOD.json is missing.'
    }
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    if ([int]$contract.format -ne 1) { throw 'Unsupported known-good contract format.' }
    $paths = @($contract.game_files | ForEach-Object { [string]$_.relative_path })
    foreach ($required in @('fifa15.exe','ItsAMe_Origin.dll','sysdllzf.dll','CardsDLLzf.dll','dbdata.dll','dlc\dlc_powdll\dlc\powdll\powdllzf.dll')) {
        if ($required -notin $paths) { throw "Known-good contract is missing $required" }
    }
    $sys = @($contract.game_files | Where-Object { $_.relative_path -eq 'sysdllzf.dll' })[0]
    if ($sys.sha256 -ne 'B477BACB277F43A9C93C4E4D8B47E1F0F8B6B2E9751A218448B8D1B17A5DCF87') {
        throw 'Player B sysdllzf.dll contract no longer pins the successful logging-disabled hash.'
    }
    Write-Host 'PASS: Player B known-good file contract parses and contains the critical exact-baseline entries.' -ForegroundColor Green
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 } catch {
        Write-Host "SELF-TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    Fail "Missing contract: $ContractPath"
}
$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
$resolvedGameDir = Resolve-GameDir

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host ' FIFA 15 PLAYER B - KNOWN-GOOD GAME FILE AUDIT' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host " Game directory: $resolvedGameDir"
Write-Host " Contract:       $ContractPath"
Write-Host ''

$hardFailures = 0
$baselineWarnings = 0
$provenanceWarnings = 0

foreach ($entry in @($contract.game_files)) {
    $relative = [string]$entry.relative_path
    $policy = [string]$entry.policy
    $status = [string]$entry.status
    $expectedHash = ([string]$entry.sha256).ToUpperInvariant()
    $expectedBytes = if ($entry.PSObject.Properties.Name -contains 'bytes' -and $null -ne $entry.bytes) { [int64]$entry.bytes } else { $null }
    $path = Join-Path $resolvedGameDir $relative

    $isHard = $policy -in @('required_to_reproduce_exact_current_baseline')
    $isBaseline = $policy -in @('preserve_exact_current_baseline')
    $isProvenanceOnly = $status -like '*NOT_POST_COPY_FINGERPRINTED*'

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($isHard) {
            Write-Host "FAIL    $relative  MISSING" -ForegroundColor Red
            $hardFailures++
        } elseif ($isBaseline) {
            Write-Host "WARN    $relative  MISSING from exact-current baseline" -ForegroundColor Yellow
            $baselineWarnings++
        } else {
            Write-Host "INFO    $relative  not present (reference/provenance entry)" -ForegroundColor DarkGray
            if ($isProvenanceOnly) { $provenanceWarnings++ }
        }
        continue
    }

    $item = Get-Item -LiteralPath $path
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    $hashOk = $actualHash -eq $expectedHash
    $sizeOk = $true
    if ($null -ne $expectedBytes) { $sizeOk = [int64]$item.Length -eq $expectedBytes }

    if ($hashOk -and $sizeOk) {
        $label = if ($isProvenanceOnly) { 'MATCH*' } else { 'MATCH' }
        $color = if ($isProvenanceOnly) { 'Yellow' } else { 'Green' }
        Write-Host ("{0,-7} {1}  bytes={2} sha256={3}" -f $label,$relative,$item.Length,$actualHash) -ForegroundColor $color
        if ($isProvenanceOnly) {
            Write-Host '        * hash matches the host/donor reference; the historical successful Ian diagnostic did not independently fingerprint this nested DLC file.' -ForegroundColor DarkYellow
        }
        continue
    }

    $detail = "bytes=$($item.Length) sha256=$actualHash expected_bytes=$expectedBytes expected_sha256=$expectedHash"
    if ($isHard) {
        Write-Host "FAIL    $relative  $detail" -ForegroundColor Red
        $hardFailures++
    } elseif ($isBaseline) {
        Write-Host "WARN    $relative  $detail" -ForegroundColor Yellow
        $baselineWarnings++
    } else {
        Write-Host "INFO    $relative  $detail" -ForegroundColor DarkGray
        if ($isProvenanceOnly) { $provenanceWarnings++ }
    }
}

Write-Host ''
Write-Host "Hard failures:       $hardFailures"
Write-Host "Baseline warnings:   $baselineWarnings"
Write-Host "Provenance warnings: $provenanceWarnings"
Write-Host ''

if ($hardFailures -gt 0) {
    Write-Host 'RESULT: NOT the proven Player B boot baseline.' -ForegroundColor Red
    exit 2
}
if ($Strict -and ($baselineWarnings -gt 0 -or $provenanceWarnings -gt 0)) {
    Write-Host 'RESULT: core boot files match, but this is not an exact reconstruction of the recorded current/manual-copy baseline.' -ForegroundColor Yellow
    exit 3
}
Write-Host 'RESULT: required Player B boot files match the recorded known-good contract.' -ForegroundColor Green
if ($baselineWarnings -gt 0 -or $provenanceWarnings -gt 0) {
    Write-Host 'Use -Strict when you want the audit to fail on exact-baseline/provenance differences too.' -ForegroundColor Yellow
}
exit 0
