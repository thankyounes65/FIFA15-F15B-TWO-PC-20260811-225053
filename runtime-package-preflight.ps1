[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$ExpectedBranch = 'integration/test-matchmaking-b-demangler-native-v2'
$ExpectedHostBranch = 'integration/test-matchmaking-demangler-join-dedupe-v8'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$RuntimeTestPath = Join-Path $Root 'RUNTIME-TEST.md'
$ManagedHostsPath = Join-Path $Root 'fifa15-managed-hostnames.ps1'
$ForwarderPath = Join-Path $Root 'loopback-relay-forwarder.ps1'
$DemanglerPreflightPath = Join-Path $Root 'demangler-preflight.ps1'
$NativeObserverPath = Join-Path $Root 'guest-native-gsu-observer.ps1'
$NativeTracerPath = Join-Path $Root 'guest-native-gsu-trace.py'
$AppenderPath = Join-Path $Root 'append-native-gsu-evidence.ps1'
$ExpectedFifaHash = '3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB'

function Fail([string]$Text) {
    Write-Host "PLAYER B PACKAGE PREFLIGHT FAILED: $Text" -ForegroundColor Red
    exit 43
}

function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "required runtime file is missing: $Path"
    }
}

function Require-Contains([string]$Path, [string[]]$Markers) {
    Require-File $Path
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($marker in $Markers) {
        if (-not $text.Contains($marker)) {
            Fail "runtime file $([IO.Path]::GetFileName($Path)) lost required marker: $marker"
        }
    }
}

function Get-NamedGitBranch {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
    if (-not $git) { return $null }
    & $git.Source -C $Root rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { return $null }
    $branch = @(& $git.Source -C $Root branch --show-current 2>$null | Select-Object -First 1)
    if ($branch.Count -eq 0 -or -not $branch[0]) { return $null }
    return ([string]$branch[0]).Trim()
}

Require-File $ManifestPath
try { $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json } catch {
    Fail "PACKAGE-MANIFEST.json is invalid: $($_.Exception.Message)"
}
if ([int]$manifest.format -ne 3 -or [string]$manifest.role -ne 'f15b') {
    Fail 'PACKAGE-MANIFEST.json is not the expected Player B format/role.'
}
if ([string]$manifest.runtime_branch -ne $ExpectedBranch) {
    Fail "package runtime_branch is '$($manifest.runtime_branch)', expected '$ExpectedBranch'. Re-download or update the Player B tester package."
}
if ([int]$manifest.runtime_features.demangler_host_port -ne 3658) {
    Fail 'package manifest does not pin host ProtoMangle to TCP/3658.'
}
$forwardPorts = @($manifest.runtime_features.loopback_forward_ports | ForEach-Object { [int]$_ } | Sort-Object -Unique)
foreach ($port in @(3658,17502,17503)) {
    if ($port -notin $forwardPorts) { Fail "package manifest is missing required loopback forward port $port." }
}

$namedBranch = Get-NamedGitBranch
if ($namedBranch -and $namedBranch -ne $ExpectedBranch) {
    Fail "named Git checkout is '$namedBranch', expected '$ExpectedBranch'."
}
if ($namedBranch) {
    Write-Host "  Player B provenance: named Git branch $namedBranch" -ForegroundColor Gray
} else {
    Write-Host "  Player B provenance: packaged/detached runtime; Git branch name is not required." -ForegroundColor Gray
}

Require-Contains $RuntimeTestPath @($ExpectedBranch,$ExpectedHostBranch,'demangler','native')
Require-Contains $ManagedHostsPath @('demangler.ea.com')
Require-Contains $ForwarderPath @('3658','17502','17503','peach.online.ea.com','127.0.0.1')
Require-Contains $DemanglerPreflightPath @('/appliance/register?role=f15b','$request.Proxy = $null','DEMANGLER_HOST_UNREACHABLE')
Require-Contains $NativeObserverPath @($ExpectedBranch,$ExpectedFifaHash)
Require-Contains $NativeTracerPath @('0x47BC5B7','guest_gsu_branch_event','GSU_STALKER_WINDOW_MS = 150','GSU_STALKER_EVENT_CAP = 256')
Require-Contains $AppenderPath @($ExpectedBranch,'NATIVE-GSU-MANIFEST','Compress-Archive')

if ($SelfTest) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        Fail "runtime-package-preflight.ps1 parse failed: $((@($errors | ForEach-Object Message)) -join '; ')"
    }
}

Write-Host 'PASS: Player B package/runtime provenance, production+test demangler routes, native observer contract and evidence appender are coherent; no FIFA or machine state was changed.' -ForegroundColor Green
exit 0
