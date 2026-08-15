[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Root = Split-Path -Parent $PSCommandPath
$ExpectedBranch = 'integration/test-matchmaking-b-joiner-result-v13'
$ExpectedHostBranch = 'integration/test-matchmaking-joiner-result-v13'
$ManifestPath = Join-Path $Root 'PACKAGE-MANIFEST.json'
$RuntimeTestPath = Join-Path $Root 'RUNTIME-TEST.md'
$ManagedHostsPath = Join-Path $Root 'fifa15-managed-hostnames.ps1'
$ForwarderPath = Join-Path $Root 'loopback-relay-forwarder.ps1'
$DemanglerPreflightPath = Join-Path $Root 'demangler-preflight.ps1'
$LauncherPath = Join-Path $Root 'RUN-FIFA15-F15B.bat'
$GitMetadataPath = Join-Path $Root '.git'

function Fail([string]$Text) { Write-Host "PLAYER B PACKAGE PREFLIGHT FAILED: $Text" -ForegroundColor Red; exit 43 }
function Require-File([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "required runtime file is missing: $Path" } }
function Require-Contains([string]$Path,[string[]]$Markers) {
    Require-File $Path
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($marker in $Markers) {
        if ($text.IndexOf($marker,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Fail "$([IO.Path]::GetFileName($Path)) lost required marker: $marker"
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
try { $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json } catch { Fail "invalid manifest: $($_.Exception.Message)" }
if ([int]$manifest.format -ne 3 -or [string]$manifest.role -ne 'f15b') { Fail 'unexpected package format/role.' }
if ([string]$manifest.runtime_branch -ne $ExpectedBranch) { Fail "manifest branch '$($manifest.runtime_branch)' != '$ExpectedBranch'." }
if ([string]$manifest.runtime_features.paired_host_branch -ne $ExpectedHostBranch) { Fail "manifest host branch '$($manifest.runtime_features.paired_host_branch)' != '$ExpectedHostBranch'." }
if ([bool]$manifest.runtime_features.in_process_fifa_instrumentation) { Fail 'v13 must not attach in-process FIFA instrumentation.' }
foreach ($port in @(3658,17502,17503)) {
    $ports = @($manifest.runtime_features.loopback_forward_ports | ForEach-Object { [int]$_ })
    if ($port -notin $ports) { Fail "manifest missing loopback forward port $port." }
}

# A checked-out repository must prove the exact named runtime branch. A GitHub
# archive/package intentionally has no .git metadata, so it cannot satisfy
# branch --show-current. In that archive case the embedded v13 manifest plus the
# exact runtime marker checks below are the provenance contract.
if (Test-Path -LiteralPath $GitMetadataPath) {
    $namedBranch = Get-NamedGitBranch
    if (-not $namedBranch) { Fail 'Git metadata is present, but a named Player B runtime branch could not be resolved.' }
    if ($namedBranch -ne $ExpectedBranch) { Fail "named checkout '$namedBranch' != '$ExpectedBranch'." }
    Write-Host "PASS: Player B Git checkout branch is exactly $ExpectedBranch." -ForegroundColor Green
} else {
    Write-Host 'INFO: no .git metadata is present; treating this as a packaged GitHub archive and validating embedded v13 provenance.' -ForegroundColor Cyan
}

Require-Contains $RuntimeTestPath @($ExpectedBranch,$ExpectedHostBranch,'no in-process FIFA instrumentation','REAS.RSLT=1','SUCCESS_JOINED_NEW_GAME','ACTIVE_CONNECTED','NotifyPlayerJoinCompleted')
Require-Contains $ManagedHostsPath @('demangler.ea.com')
Require-Contains $ForwarderPath @('3658','17502','17503','peach.online.ea.com','127.0.0.1')
Require-Contains $DemanglerPreflightPath @('/appliance/register?role=f15b','$request.Proxy = $null','DEMANGLER_HOST_UNREACHABLE')
Require-Contains $LauncherPath @($ExpectedBranch,$ExpectedHostBranch,'REAS.RSLT = 1','SUCCESS_JOINED_NEW_GAME','guest-network-observer.ps1','demangler-preflight.ps1','NO Frida/Stalker/native observer is attached','Stopping any stale passive Player B network observer')

$launcher = Get-Content -LiteralPath $LauncherPath -Raw
foreach ($forbidden in @('guest-native-gsu-observer.ps1" -Start','guest-native-gsu-trace.py','append-native-gsu-evidence.ps1','integration/test-matchmaking-postmesh-gsu-v10','integration/test-matchmaking-b-promotion-notification-v12','integration/test-matchmaking-promotion-notification-bundle-v12')) {
    if ($launcher.Contains($forbidden)) { Fail "v13 launcher activates/refers to forbidden or stale path: $forbidden" }
}
if ($SelfTest) {
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { Fail "preflight parse failed: $((@($errors | ForEach-Object Message)) -join '; ')" }
}
Write-Host 'PASS: Player B v13 package provenance matches the exact paired branches, retains v12 routing/passive evidence, and has no in-process FIFA instrumentation.' -ForegroundColor Green
exit 0
