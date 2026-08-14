[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Start,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$Tracer = Join-Path $Root 'guest-native-gsu-trace.py'
$PidFile = Join-Path $env:TEMP 'fifa15-f15b-native-gsu-tracer.pid'
$StampFile = Join-Path $env:TEMP 'fifa15-f15b-native-gsu-tracer.stamp'
$ExpectedFifaHash = '3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB'
$ExpectedBranch = 'integration/test-matchmaking-b-native-gsu-v1'

function Fail([string]$Text, [int]$Code = 1) {
    Write-Host "STOP [NATIVE_GSU_OBSERVER]: $Text" -ForegroundColor Red
    exit $Code
}

function Get-Python {
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $command) { Fail 'Python is required for the read-only native matcher observer. Install Python before this diagnostic run.' 40 }
    return $command.Source
}

function Assert-Frida([string]$Python) {
    & $Python -c "import frida; print(frida.__version__)" >$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail 'Python is present but the frida module is missing. Run: python -m pip install frida' 40
    }
}

function Assert-Branch {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
    if (-not $git) { Fail 'git is unavailable; cannot prove the Player B diagnostic branch.' 43 }
    $branch = (& $git.Source -C $Root branch --show-current 2>$null | Select-Object -First 1)
    if (-not $branch -or $branch.Trim() -ne $ExpectedBranch) {
        Fail "wrong Player B branch. Expected $ExpectedBranch; found $branch" 43
    }
}

function Assert-ExactFifa {
    $statePath = Join-Path $env:ProgramData 'FIFA15-Preservation\two-pc-appliance-exact-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Fail "exact-state snapshot is missing: $statePath" 43
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $fifaPath = [string]$state.fifa_path
    if (-not $fifaPath -or -not (Test-Path -LiteralPath $fifaPath -PathType Leaf)) {
        Fail 'could not resolve fifa15.exe from the package exact-state snapshot.' 43
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fifaPath).Hash.ToUpperInvariant()
    if ($hash -ne $ExpectedFifaHash) {
        Fail "fifa15.exe hash mismatch. Expected $ExpectedFifaHash; found $hash" 43
    }
}

function Invoke-SelfTest {
    if (-not (Test-Path -LiteralPath $Tracer -PathType Leaf)) { Fail "missing native tracer: $Tracer" 43 }
    Assert-Branch
    $python = Get-Python
    Assert-Frida $python
    & $python $Tracer --self-test
    if ($LASTEXITCODE -ne 0) { Fail "native tracer self-test failed with code $LASTEXITCODE" 43 }
    $source = Get-Content -LiteralPath $Tracer -Raw
    foreach ($marker in @(
        '0x47BC5B7',
        '84c0',
        'guest_gamesessionupdated_network_gate',
        'guest_gsu_branch_event',
        'GSU_STALKER_WINDOW_MS = 150',
        'GSU_STALKER_EVENT_CAP = 256',
        $ExpectedFifaHash.ToLowerInvariant()
    )) {
        if (-not $source.Contains($marker)) { Fail "native tracer lost required marker: $marker" 43 }
    }
    Write-Host 'PASS: Player B native GSU observer is exact-branch, Python/Frida-ready, exact-byte guarded and bounded.' -ForegroundColor Green
}

function Stop-Existing {
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return }
    $value = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($value -match '^\d+$') {
        Stop-Process -Id ([int]$value) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

function Start-Observer {
    Invoke-SelfTest
    Assert-ExactFifa
    Stop-Existing
    $python = Get-Python
    $desktop = [Environment]::GetFolderPath('Desktop')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonl = Join-Path $desktop "FIFA15-F15B-NATIVE-GSU-$stamp.jsonl"
    $text = Join-Path $desktop "FIFA15-F15B-NATIVE-GSU-$stamp.log"
    $stdout = Join-Path $env:TEMP "fifa15-f15b-native-gsu-$stamp.out.log"
    $stderr = Join-Path $env:TEMP "fifa15-f15b-native-gsu-$stamp.err.log"
    $process = Start-Process -FilePath $python -ArgumentList @(
        '-u',
        "`"$Tracer`"",
        '--wait','600',
        '--jsonl',"`"$jsonl`"",
        '--text',"`"$text`""
    ) -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    [string]$process.Id | Set-Content -LiteralPath $PidFile -Encoding ASCII
    @(
        "stamp=$stamp",
        "pid=$($process.Id)",
        "jsonl=$jsonl",
        "text=$text",
        "stdout=$stdout",
        "stderr=$stderr",
        "branch=$ExpectedBranch",
        "fifa_sha256=$ExpectedFifaHash"
    ) | Set-Content -LiteralPath $StampFile -Encoding UTF8
    Write-Host "PASS: Player B native GSU observer armed pid=$($process.Id); it will attach when fifa15.exe appears." -ForegroundColor Green
}

function Stop-Observer {
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
        Write-Host 'Player B native GSU observer has no active pid file.' -ForegroundColor Yellow
        return
    }
    $value = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($value -notmatch '^\d+$') {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return
    }
    $process = Get-Process -Id ([int]$value) -ErrorAction SilentlyContinue
    if ($process) {
        if (-not $process.WaitForExit(10000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Write-Host 'Player B native GSU observer was still attached after FIFA workflow exit and was stopped after the evidence grace period.' -ForegroundColor Yellow
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Player B native GSU observer stopped; Desktop JSONL/text evidence is preserved.' -ForegroundColor Green
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
if ($Start) { Start-Observer; exit 0 }
if ($Stop) { Stop-Observer; exit 0 }
Fail 'Specify -SelfTest, -Start, or -Stop.' 2
