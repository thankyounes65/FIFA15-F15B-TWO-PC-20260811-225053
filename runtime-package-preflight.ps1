[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$ExpectedBranch = 'integration/test-matchmaking-b-demangler-no-frida-v3'
$ExpectedHostBranch = 'integration/test-matchmaking-demangler-join-dedupe-v9'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$RuntimeTestPath = Join-Path $Root 'RUNTIME-TEST.md'
$ManagedHostsPath = Join-Path $Root 'fifa15-managed-hostnames.ps1'
$ForwarderPath = Join-Path $Root 'loopback-relay-forwarder.ps1'
$DemanglerPreflightPath = Join-Path $Root 'demangler-preflight.ps1'
$LauncherPath = Join-Path $Root 'RUN-FIFA15-F15B.bat'

function Fail([string]$Text) {
    Write-Host "PLAYER B PACKAGE PREFLIGHT FAILED: $Text" -ForegroundColor Red
    exit 43
}
function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "required runtime file is missing: $Path" }
}
function Require-Contains([string]$Path,[string[]]$Markers) {
    Require-File $Path
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($marker in $Markers) {
        if (-not $text.Contains($marker)) { Fail "runtime file $([IO.Path]::GetFileName($Path)) lost required marker: $marker" }
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
if ([int]$manifest.format -ne 3 -or [string]$manifest.role -ne 'f15b') { Fail 'unexpected package format/role.' }
if ([string]$manifest.runtime_branch -ne $ExpectedBranch) {
    Fail "package runtime_branch is '$($manifest.runtime_branch)', expected '$ExpectedBranch'."
}
if ([int]$manifest.runtime_features.demangler_host_port -ne 3658) { Fail 'manifest does not pin host ProtoMangle to TCP/3658.' }
$forwardPorts = @($manifest.runtime_features.loopback_forward_ports | ForEach-Object { [int]$_ } | Sort-Object -Unique)
foreach ($port in @(3658,17502,17503)) {
    if ($port -notin $forwardPorts) { Fail "manifest is missing required loopback forward port $port." }
}

$namedBranch = Get-NamedGitBranch
if ($namedBranch -and $namedBranch -ne $ExpectedBranch) { Fail "named Git checkout is '$namedBranch', expected '$ExpectedBranch'." }
if ($namedBranch) {
    Write-Host "  Player B provenance: named Git branch $namedBranch" -ForegroundColor Gray
} else {
    Write-Host '  Player B provenance: packaged/detached runtime; manifest branch stamp is authoritative.' -ForegroundColor Gray
}

Require-Contains $RuntimeTestPath @($ExpectedBranch,$ExpectedHostBranch,'no in-process','demangler')
Require-Contains $ManagedHostsPath @('demangler.ea.com')
Require-Contains $ForwarderPath @('3658','17502','17503','peach.online.ea.com','127.0.0.1')
Require-Contains $DemanglerPreflightPath @('/appliance/register?role=f15b','$request.Proxy = $null','DEMANGLER_HOST_UNREACHABLE')
Require-Contains $LauncherPath @('NO Frida/Stalker/native observer is attached','guest-network-observer.ps1','demangler-preflight.ps1')

# The known crash mechanism must not be started by the v3 launcher. Historical
# observer files may remain in the package for evidence archaeology; activation is forbidden.
$launcher = Get-Content -LiteralPath $LauncherPath -Raw
foreach ($forbidden in @(
    'guest-native-gsu-observer.ps1" -Start',
    'guest-native-gsu-trace.py',
    'append-native-gsu-evidence.ps1'
)) {
    if ($launcher.Contains($forbidden)) { Fail "v3 launcher still activates/refers to removed native diagnostic path: $forbidden" }
}

if ($SelfTest) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { Fail "runtime-package-preflight.ps1 parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
}

Write-Host 'PASS: Player B v3 package, demangler routes, forwarder and passive observer are coherent; no native/Frida FIFA instrumentation is armed.' -ForegroundColor Green
exit 0
