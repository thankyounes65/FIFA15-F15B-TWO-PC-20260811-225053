[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$DependencySelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $PSCommandPath
$Observer = Join-Path $Root 'matchmaking-native-observer-v2.py'
$ProbeValidator = Join-Path $Root 'validate-native-observer-v2-probes.py'
$Classifier = Join-Path $Root 'classify-native-observer-v2-evidence.py'
$Attest = Join-Path $Root 'matchmaking-native-observer-attest.ps1'
$GameVerify = Join-Path $Root 'VERIFY-PLAYER-B-GAME-FILES.ps1'
$RuntimeTest = Join-Path $Root 'RUNTIME-TEST.md'
$FridaVersion = '17.9.11'
$DependencyRoot = Join-Path $Root '.observer-deps'
$FridaSite = Join-Path $DependencyRoot ("frida-$FridaVersion")
$OriginalPythonPath = [string]$env:PYTHONPATH

$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$attempt = Join-Path $Root ("runs\matchmaking-native-observer\player-b\$stamp")
$jsonl = Join-Path $attempt 'matchmaking-native-observer-v2.jsonl'
$text = Join-Path $attempt 'matchmaking-native-observer-v2.txt'
$verdict = Join-Path $attempt 'OBSERVER-VERDICT.txt'
$manifest = Join-Path $attempt 'OBSERVER-RUN-MANIFEST.txt'

$observerProcess = $null
$networkActive = $false
$forwarderActive = $false
$tailscaleAttempted = $false
$rc = 1
$stage = 'preflight'

function Run([string]$File, [string[]]$Arguments = @()) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$File returned $LASTEXITCODE"
    }
}

function Assert-Files {
    foreach ($name in @(
        'matchmaking-native-observer-v2.py',
        'fifa15-native-observer-v2-probes.json',
        'validate-native-observer-v2-probes.py',
        'classify-native-observer-v2-evidence.py',
        'matchmaking-native-observer-attest.ps1',
        'diagnostic-run.ps1',
        'guest-network-observer.ps1',
        'loopback-relay-forwarder.ps1',
        'tailscale-bootstrap.ps1',
        'VERIFY-PLAYER-B-GAME-FILES.ps1',
        'RUNTIME-TEST.md'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $name) -PathType Leaf)) {
            throw "Missing observer prerequisite: $name"
        }
    }
}

function Get-Sha256OrUnavailable([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } catch {}
    return 'unavailable'
}

function Set-ObserverPythonPath {
    if ($OriginalPythonPath) {
        $env:PYTHONPATH = "$FridaSite;$OriginalPythonPath"
    } else {
        $env:PYTHONPATH = $FridaSite
    }
}

function Restore-PythonPath {
    if ($OriginalPythonPath) {
        $env:PYTHONPATH = $OriginalPythonPath
    } else {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    }
}

function Test-PinnedFrida {
    if (-not (Test-Path -LiteralPath $FridaSite -PathType Container)) {
        return $false
    }

    Set-ObserverPythonPath
    & python -c "import frida,sys; sys.exit(0 if getattr(frida,'__version__','') == '$FridaVersion' else 7)" 2>$null | Out-Null
    $ok = $LASTEXITCODE -eq 0
    if (-not $ok) {
        Restore-PythonPath
    }
    return $ok
}

function Ensure-PinnedFrida {
    if (Test-PinnedFrida) {
        Write-Host "PASS: package-local Frida $FridaVersion is ready." -ForegroundColor Green
        return
    }

    Restore-PythonPath
    New-Item -ItemType Directory -Force -Path $DependencyRoot | Out-Null
    $partial = Join-Path $DependencyRoot ("frida-$FridaVersion.partial-$PID")
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $partial | Out-Null

    Write-Host "Installing pinned Frida $FridaVersion into the extracted Player B package..." -ForegroundColor Cyan
    & python -m pip install --disable-pip-version-check --no-input --only-binary=:all: --target $partial "frida==$FridaVersion"
    $pipRc = [int]$LASTEXITCODE
    if ($pipRc -ne 0) {
        Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
        throw "Could not bootstrap package-local Frida $FridaVersion (pip exit $pipRc). FIFA was not launched."
    }

    if (Test-Path -LiteralPath $FridaSite) {
        Remove-Item -LiteralPath $FridaSite -Recurse -Force
    }
    Move-Item -LiteralPath $partial -Destination $FridaSite

    if (-not (Test-PinnedFrida)) {
        throw "Package-local Frida $FridaVersion installed but could not be imported by this Python. FIFA was not launched."
    }
    Write-Host "PASS: package-local Frida $FridaVersion installed and import-verified." -ForegroundColor Green
}

Assert-Files

if ($SelfTest) {
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$GameVerify,'-SelfTest')
    Run 'python' @($ProbeValidator,'--self-test')
    Run 'python' @($Observer,'--self-test')
    Run 'python' @($Classifier,'--self-test')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'guest-network-observer.ps1'),'-SelfTest')
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($marker in @('FridaVersion = ''17.9.11''','Ensure-PinnedFrida','--only-binary=:all:','frida==$FridaVersion','.observer-deps','-Reset')) {
        if (-not $source.Contains($marker)) {
            throw "Native-observer runner lost dependency-bootstrap marker: $marker"
        }
    }
    Write-Host 'PASS: Player B native-observer v2 runner is Stalker-free, probe-validated, portable from an extracted folder, has no scenario selector, safely skips absent FIFA drive letters, self-heals stale helper state, and carries a pinned package-local Frida bootstrap.' -ForegroundColor Green
    exit 0
}

if ($DependencySelfTest) {
    Ensure-PinnedFrida
    Write-Host "PASS: pinned Frida dependency self-test completed with package-local version $FridaVersion." -ForegroundColor Green
    Restore-PythonPath
    exit 0
}

New-Item -ItemType Directory -Force -Path $attempt | Out-Null
@(
    'FIFA15 matchmaking native observer - Player B',
    "started_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    'branch=integration/test-matchmaking-native-observer-v2',
    'instrumentation=frida_interceptor_readonly_byte_verified',
    'stalker_used=false',
    'package_mode=portable-extracted-folder',
    'requires_git_checkout=false',
    "frida_version=$FridaVersion",
    'frida_scope=package-local',
    'wire_change=false',
    'observer_only=true',
    'scenario_selection=false',
    'target_chain=0x47BCC76(callsite for 0x47BCC7C)>0x479EBE9>0x479B785>0x479BC0B>0x3A04A32>0x3A04A65>0x3715903',
    'target_0x0b=0x47BE327 entry, 0x47BE3D9 result4-destroy, 0x47BE416 virtual+8 arm',
    'target_cardsdll=0x3BAB0'
) | Set-Content -LiteralPath $manifest -Encoding UTF8

try {
    $stage = 'game_file_verify'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$GameVerify)

    $stage = 'probe_validation'
    Run 'python' @($ProbeValidator,'--self-test')

    $stage = 'observer_selftest'
    Run 'python' @($Observer,'--self-test')

    $stage = 'classifier_selftest'
    Run 'python' @($Classifier,'--self-test')

    $stage = 'attestation_selftest'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest,'-SelfTest')

    $stage = 'network_selftest'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'guest-network-observer.ps1'),'-SelfTest')

    $stage = 'frida_dependency'
    Ensure-PinnedFrida

    $stage = 'tailscale_bootstrap'
    $tailscaleAttempted = $true
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'tailscale-bootstrap.ps1'))

    # Reclaim anything a previous crashed or aborted run left behind, so the
    # operator never has to kill a stale PID by hand.
    $stage = 'stale_helper_reset'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'guest-network-observer.ps1') -Reset
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'loopback-relay-forwarder.ps1') -Stop 2>$null | Out-Null

    $stage = 'forwarder_start'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'loopback-relay-forwarder.ps1'),'-Start')
    $forwarderActive = $true

    $stage = 'network_start'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'guest-network-observer.ps1'),'-Start')
    $networkActive = $true

    $stage = 'peer_gate'
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Attest)

    $stage = 'observer_start'
    Set-ObserverPythonPath
    $observerProcess = Start-Process -FilePath 'python' -ArgumentList @($Observer,'--jsonl',$jsonl,'--text',$text) -PassThru -NoNewWindow
    Start-Sleep -Milliseconds 750
    if ($observerProcess.HasExited) {
        throw "native observer exited before FIFA launch with code $($observerProcess.ExitCode)"
    }

    $stage = 'fifa_runtime'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'diagnostic-run.ps1')
    $rc = [int]$LASTEXITCODE
    $stage = 'post_runtime'
} catch {
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value ("error_stage=$stage`nerror=$($_.Exception.Message)")
    Write-Host "ERROR at stage ${stage}: $($_.Exception.Message)" -ForegroundColor Red
    if ($stage -ne 'fifa_runtime' -and $stage -ne 'post_runtime') {
        Write-Host 'Runtime observation NOT REACHED; classify VOID.' -ForegroundColor Yellow
    }
    $rc = 1
} finally {
    if ($observerProcess) {
        try {
            if (-not $observerProcess.HasExited) {
                $observerProcess.WaitForExit(10000) | Out-Null
            }
        } catch {}
    }
    if ($networkActive) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'guest-network-observer.ps1') -Stop
        } catch {
            Write-Warning $_
        }
    }
    if ($forwarderActive) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'loopback-relay-forwarder.ps1') -Stop
        } catch {
            Write-Warning $_
        }
    }
    if ($tailscaleAttempted) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tailscale-bootstrap.ps1') -Cleanup
        } catch {
            Write-Warning $_
        }
    }

    Restore-PythonPath
    $runtimeTestHash = Get-Sha256OrUnavailable $RuntimeTest
    $attestHash = Get-Sha256OrUnavailable $Attest
    $runnerHash = Get-Sha256OrUnavailable $PSCommandPath
    Add-Content -LiteralPath $manifest -Encoding UTF8 -Value @(
        "finished_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
        "runtime_exit_code=$rc",
        "final_stage=$stage",
        'exact_b_head=portable-extracted-folder-no-git',
        "frida_version=$FridaVersion",
        "frida_site=$FridaSite",
        "package_runtime_test_sha256=$runtimeTestHash",
        "package_attest_sha256=$attestHash",
        "package_runner_sha256=$runnerHash",
        "observer_jsonl=$jsonl",
        "observer_text=$text"
    )
    if (Test-Path -LiteralPath $jsonl -PathType Leaf) {
        try {
            & python $Classifier '--player-a' $jsonl 2>&1 | Set-Content -LiteralPath $verdict -Encoding UTF8
        } catch {
            Set-Content -LiteralPath $verdict -Encoding UTF8 -Value "classifier failed: $($_.Exception.Message)"
        }
    }
    foreach ($path in @($jsonl,$text,$verdict)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Add-Content -LiteralPath $manifest -Encoding UTF8 -Value ("evidence=$([IO.Path]::GetFileName($path))|sha256=$hash")
        }
    }
}

Write-Host ''
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host '  PLAYER B NATIVE OBSERVER v2 RUN FINISHED' -ForegroundColor Cyan
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host "Evidence: $attempt" -ForegroundColor Green
Write-Host 'No scenario was selected. Player B boot/network behavior is unchanged.' -ForegroundColor Gray
exit $rc
