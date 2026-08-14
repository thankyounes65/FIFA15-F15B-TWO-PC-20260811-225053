[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$ExpectedBranch = 'integration/test-matchmaking-b-identity-session-v4'
$ExpectedHostBranch = 'integration/test-matchmaking-identity-session-coherence-v10'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$RuntimeTestPath = Join-Path $Root 'RUNTIME-TEST.md'
$ManagedHostsPath = Join-Path $Root 'fifa15-managed-hostnames.ps1'
$ForwarderPath = Join-Path $Root 'loopback-relay-forwarder.ps1'
$DemanglerPreflightPath = Join-Path $Root 'demangler-preflight.ps1'
$LauncherPath = Join-Path $Root 'RUN-FIFA15-F15B.bat'

function Fail([string]$Text) { Write-Host "PLAYER B PACKAGE PREFLIGHT FAILED: $Text" -ForegroundColor Red; exit 43 }
function Require-File([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "required runtime file is missing: $Path" } }
function Require-Contains([string]$Path,[string[]]$Markers) {
    Require-File $Path
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($marker in $Markers) { if (-not $text.Contains($marker)) { Fail "$([IO.Path]::GetFileName($Path)) lost required marker: $marker" } }
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
try { $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json } catch { Fail "invalid manifest: $($_.Exception.Message)" }
if ([int]$manifest.format -ne 3 -or [string]$manifest.role -ne 'f15b') { Fail 'unexpected package format/role.' }
if ([string]$manifest.runtime_branch -ne $ExpectedBranch) { Fail "manifest branch '$($manifest.runtime_branch)' != '$ExpectedBranch'." }
if ([bool]$manifest.runtime_features.in_process_fifa_instrumentation) { Fail 'v4 must not attach in-process FIFA instrumentation.' }
foreach ($port in @(3658,17502,17503)) {
    $ports = @($manifest.runtime_features.loopback_forward_ports | ForEach-Object { [int]$_ })
    if ($port -notin $ports) { Fail "manifest missing loopback forward port $port." }
}

$namedBranch = Get-NamedGitBranch
if ($namedBranch -and $namedBranch -ne $ExpectedBranch) { Fail "named checkout '$namedBranch' != '$ExpectedBranch'." }
Require-Contains $RuntimeTestPath @($ExpectedBranch,$ExpectedHostBranch,'no in-process','GameSessionUpdated','PlayerID')
Require-Contains $ManagedHostsPath @('demangler.ea.com')
Require-Contains $ForwarderPath @('3658','17502','17503','peach.online.ea.com','127.0.0.1')
Require-Contains $DemanglerPreflightPath @('/appliance/register?role=f15b','$request.Proxy = $null','DEMANGLER_HOST_UNREACHABLE')
Require-Contains $LauncherPath @('guest-network-observer.ps1','demangler-preflight.ps1','NO Frida/Stalker/native observer is attached')

$launcher = Get-Content -LiteralPath $LauncherPath -Raw
foreach ($forbidden in @('guest-native-gsu-observer.ps1" -Start','guest-native-gsu-trace.py','append-native-gsu-evidence.ps1')) {
    if ($launcher.Contains($forbidden)) { Fail "v4 launcher activates/refers to forbidden native path: $forbidden" }
}
if ($SelfTest) {
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { Fail "preflight parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
}
Write-Host 'PASS: Player B v4 package is paired with host v10; routing/passive evidence remain armed and in-process FIFA instrumentation remains disabled.' -ForegroundColor Green
exit 0
