[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$SafeRun = Join-Path $Root 'safe-run.ps1'
$Revision = 'diagnostics-v1'
$Desktop = [Environment]::GetFolderPath('Desktop')

function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Step([string]$Text) { Write-Host "`n>> $Text" -ForegroundColor Cyan }

function Ensure-Elevated {
    if ($SelfTest) { return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    $child = Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait -PassThru
    exit $child.ExitCode
}

function Classify-Outcome([string]$Text, [int]$ExitCode) {
    $rules = @(
        @{ id='WINDOWS_ARCH_UNSUPPORTED'; pattern='requires native x64 Windows|not an x64 PE executable'; meaning='The Windows or FIFA executable architecture is not the supported native x64 build.' },
        @{ id='PACKAGE_INVALID'; pattern='Required package file is missing|failed its SHA-256 integrity check|wrong size|self-test failed|invalid host_ip'; meaning='The tester package is incomplete, damaged, or inconsistent.' },
        @{ id='FIFA_NOT_FOUND'; pattern='FIFA 15 could not be found|selected FIFA 15 executable does not exist|selected file is not named fifa15\.exe'; meaning='The launcher could not identify the installed FIFA 15 executable.' },
        @{ id='TAILSCALE_PRESTATE_UNSAFE'; pattern='Tailscale is already installed.*not connected|Pre-existing Tailscale.*disconnected|Tailscale existed before the test but is now missing'; meaning='A pre-existing Tailscale state could not be borrowed/restored safely.' },
        @{ id='TAILSCALE_JOIN_FAILED'; pattern='Could not join the private network|private-network install failed|did not become connected|JOIN\.key.*invalid|JOIN\.key is missing'; meaning='The guest could not join the private test network.' },
        @{ id='HOST_NOT_READY'; pattern='never reported READY'; meaning='The host-side launcher did not become ready before the timeout.' },
        @{ id='HOST_RELAY_UNREACHABLE'; pattern='relay port 42127 is not reachable'; meaning='The guest reached the host readiness beacon but could not reach the FIFA relay listener.' },
        @{ id='LSX_PORT_CONFLICT'; pattern='TCP 3216 is already owned by|will not kill an unrelated process'; meaning='Another process already owns the FIFA LSX port and the tester refused to disturb it.' },
        @{ id='LSX_RESPONDER_FAILED'; pattern='LSX responder did not become|lost ownership of 127\.0\.0\.1:3216'; meaning='The bundled FIFA LSX responder could not keep the required local port.' },
        @{ id='HOSTS_ROUTING_FAILED'; pattern='Hosts routing verification failed'; meaning='The temporary FIFA hostname routing did not install as expected.' },
        @{ id='FIFA_LAUNCH_HANDOFF'; pattern='launched FIFA 15 process did not remain running long enough to patch|fifa15\.exe exited before it could be patched'; meaning='Starting fifa15.exe did not leave the expected game process alive. A retail EA/DRM launch handoff is one possible cause.' },
        @{ id='CERTIFICATE_LAYOUT_DIFFERENT'; pattern='does not map the known certificate patch location safely'; meaning='The running FIFA image layout differs from the tested build. The known certificate RVA/address is not safely usable on this executable.' },
        @{ id='CERTIFICATE_PROCESS_ACCESS_FAILED'; pattern='Windows refused access to inspect/patch FIFA 15 memory|OpenProcess failed'; meaning='Windows would not allow the launcher to inspect or patch the running FIFA process.' },
        @{ id='CERTIFICATE_PREIMAGE_READ_FAILED'; pattern='pre-patch ReadProcessMemory failed|Could not inspect the launched FIFA 15 main module'; meaning='The expected certificate patch region could not be inspected in the running FIFA process.' },
        @{ id='CERTIFICATE_WRITE_FAILED'; pattern='WriteProcessMemory failed'; meaning='The relay certificate could not be written into the running FIFA process.' },
        @{ id='CERTIFICATE_READBACK_FAILED'; pattern='certificate readback mismatch|post-patch ReadProcessMemory failed'; meaning='The certificate patch was written/read but could not be verified exactly.' },
        @{ id='RESTORATION_INCOMPLETE'; pattern='RESTORATION INCOMPLETE'; meaning='The test ended, but at least one recorded pre-test machine setting could not be restored automatically.' }
    )
    foreach ($rule in $rules) {
        if ($Text -match $rule.pattern) { return [pscustomobject]$rule }
    }
    if ($ExitCode -eq 0 -and $Text -match 'FIFA 15 ready .*relay certificate verified') {
        return [pscustomobject]@{ id='RUNTIME_LAUNCH_VERIFIED'; meaning='FIFA launched and the relay certificate patch was verified. Any later failure is beyond basic retail/launcher compatibility.' }
    }
    if ($ExitCode -eq 0) {
        return [pscustomobject]@{ id='RUN_COMPLETED'; meaning='The one-click tester completed without a launcher error.' }
    }
    return [pscustomobject]@{ id='UNCLASSIFIED_FAILURE'; meaning='The launcher stopped at a boundary not yet mapped to a specific diagnosis. The captured decisive lines should be reviewed.' }
}

function Get-DecisiveLines([string[]]$Lines) {
    $selected = @($Lines | Where-Object {
        $_ -match 'STOP:|PASS:|ERROR:|Warning:|FIFA 15 ready|relay|Tailscale|private network|3216|Hosts routing|certificate|patch|RESTORATION|Found FIFA|SHA-256|base=|imageEnd='
    })
    if ($selected.Count -gt 24) { $selected = $selected[($selected.Count-24)..($selected.Count-1)] }
    return $selected
}

function Write-DiagnosticReport([string[]]$Lines, [int]$ExitCode) {
    $text = ($Lines -join "`n")
    $diagnosis = Classify-Outcome -Text $text -ExitCode $ExitCode
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $report = Join-Path $Desktop "FIFA15-F15B-DIAG-$stamp.txt"
    $config = $null
    try { $config = Get-Content (Join-Path $Root 'APPLIANCE-CONFIG.json') -Raw | ConvertFrom-Json } catch {}
    $decisive = Get-DecisiveLines $Lines

    $body = New-Object Collections.Generic.List[string]
    $body.Add('FIFA 15 F15B ONE-CLICK DIAGNOSTIC')
    $body.Add('===================================')
    $body.Add("diagnosis=$($diagnosis.id)")
    $body.Add("meaning=$($diagnosis.meaning)")
    $body.Add("exit_code=$ExitCode")
    $body.Add("diagnostic_revision=$Revision")
    if ($config -and $config.test_id) { $body.Add("test_id=$($config.test_id)") }
    $body.Add("utc=$((Get-Date).ToUniversalTime().ToString('o'))")
    $body.Add('')
    $body.Add('DECISIVE OUTPUT')
    $body.Add('---------------')
    foreach ($line in $decisive) { $body.Add([string]$line) }
    $body | Set-Content -LiteralPath $report -Encoding UTF8

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host " DIAGNOSIS: $($diagnosis.id)" -ForegroundColor Yellow
    Write-Host " $($diagnosis.meaning)" -ForegroundColor Yellow
    Write-Host " Report: $report" -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Get-ChildItem -LiteralPath $Desktop -Filter 'FIFA15-F15B-EVIDENCE-*.zip' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($zip -and $zip.LastWriteTimeUtc -gt (Get-Date).ToUniversalTime().AddMinutes(-30)) {
            $archive = [IO.Compression.ZipFile]::Open($zip.FullName,[IO.Compression.ZipArchiveMode]::Update)
            try {
                $old = $archive.GetEntry('COMPATIBILITY-DIAGNOSIS.txt')
                if ($old) { $old.Delete() }
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$report,'COMPATIBILITY-DIAGNOSIS.txt',[IO.Compression.CompressionLevel]::Optimal) | Out-Null
            } finally { $archive.Dispose() }
            Info "Diagnosis added to evidence ZIP: $($zip.FullName)"
        }
    } catch { Info "Could not add diagnosis to evidence ZIP: $($_.Exception.Message)" }

    return $diagnosis.id
}

function Invoke-SelfTest {
    Step 'Diagnostic wrapper self-test (no machine changes)'
    if (-not (Test-Path -LiteralPath $SafeRun)) { throw "Missing safe-run.ps1: $SafeRun" }
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors) { throw (($errors | ForEach-Object Message) -join '; ') }

    $cases = @(
        @{ text='This FIFA build/runtime does not map the known certificate patch location safely (base=0x150000000, imageEnd=0x152000000).'; rc=1; want='CERTIFICATE_LAYOUT_DIFFERENT' },
        @{ text='The launched FIFA 15 process did not remain running long enough to patch.'; rc=1; want='FIFA_LAUNCH_HANDOFF' },
        @{ text='Host reports READY, but the FIFA relay port 42127 is not reachable from this PC.'; rc=1; want='HOST_RELAY_UNREACHABLE' },
        @{ text='FIFA 15 ready (PID 1234); relay certificate verified.'; rc=0; want='RUNTIME_LAUNCH_VERIFIED' }
    )
    foreach ($case in $cases) {
        $got = (Classify-Outcome -Text $case.text -ExitCode $case.rc).id
        if ($got -ne $case.want) { throw "classifier expected $($case.want), got $got" }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SafeRun -SelfTest | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "safe-run self-test failed with code $LASTEXITCODE" }
    Write-Host 'PASS: diagnostic classifier and existing safety/runtime self-tests passed.' -ForegroundColor Green
}

try {
    if ($SelfTest) { Invoke-SelfTest; exit 0 }
    Ensure-Elevated
    if (-not (Test-Path -LiteralPath $SafeRun)) { throw "Missing safe-run.ps1: $SafeRun" }

    Step 'Running FIFA 15 tester with automatic failure diagnosis'
    $captured = New-Object Collections.Generic.List[string]
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SafeRun 2>&1 | ForEach-Object {
            $line = [string]$_
            $captured.Add($line)
            Write-Host $line
        }
        $rc = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }

    [void](Write-DiagnosticReport -Lines $captured.ToArray() -ExitCode $rc)
    exit $rc
} catch {
    $lines = @("STOP: $($_.Exception.Message)")
    [void](Write-DiagnosticReport -Lines $lines -ExitCode 1)
    exit 1
}
