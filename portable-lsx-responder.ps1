[CmdletBinding()]
param(
    [string]$TablePath = (Join-Path $PSScriptRoot 'lsx-table.json'),
    [int]$Port = 3216,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Key = [byte[]](0..15)

function ConvertTo-Hex([byte[]]$Bytes) {
    return -join ($Bytes | ForEach-Object { $_.ToString('x2') })
}

function ConvertFrom-Hex([string]$Text) {
    if (($Text.Length % 2) -ne 0) { throw 'odd-length hex frame' }
    $out = New-Object byte[] ($Text.Length / 2)
    for ($i = 0; $i -lt $out.Length; $i++) {
        $out[$i] = [Convert]::ToByte($Text.Substring($i * 2, 2), 16)
    }
    return $out
}

function New-RandomBytes([int]$Count) {
    $bytes = New-Object byte[] $Count
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return $bytes
}

function Invoke-AesEncrypt([string]$Text) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $Key
        $enc = $aes.CreateEncryptor()
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ConvertTo-Hex ($enc.TransformFinalBlock($bytes, 0, $bytes.Length))
    } finally { $aes.Dispose() }
}

function Invoke-AesDecrypt([string]$Hex) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $Key
        $dec = $aes.CreateDecryptor()
        $bytes = ConvertFrom-Hex $Hex
        return [Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($bytes, 0, $bytes.Length))
    } finally { $aes.Dispose() }
}

function Get-RequestKey([string]$Xml) {
    $m = [regex]::Match($Xml, '<Request[^>]*>\s*<(\w+)([^>]*)', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $name = $m.Groups[1].Value
    $attrs = $m.Groups[2].Value
    foreach ($selector in @('GameInfoId','SettingId','GameInfoID')) {
        $a = [regex]::Match($attrs, $selector + '="([^"]*)"', 'IgnoreCase')
        if ($a.Success) { return "$name`:$selector=$($a.Groups[1].Value)" }
    }
    return $name
}

function New-AuthTokenElement {
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
    $bytes = New-RandomBytes 35
    $body = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    $plain = "AT0:3.0:3.0:240:$body`:8008:sc01v"
    $value = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($plain)).TrimEnd('=')
    return "<AuthToken value=`"$value`"/>"
}

function Get-ResponseBody([string]$KeyName, [string]$Raw, $Data) {
    if ($KeyName -and $KeyName.StartsWith('GetGameInfo:')) {
        $value = if ($KeyName.EndsWith('LANGUAGES')) { 'en_US' } else { 'true' }
        return "<GetGameInfoResponse GameInfo=`"$value`"/>"
    }
    if ($KeyName -and $Data.table.PSObject.Properties.Name -contains $KeyName) {
        return [string]$Data.table.$KeyName
    }
    $verb = if ($KeyName) { $KeyName.Split(':')[0] } else { '' }
    switch ($verb) {
        'GetAuthToken' { return New-AuthTokenElement }
        'QueryFriends' { return '<QueryFriendsResponse></QueryFriendsResponse>' }
        'GetBlockList' { return '<GetBlockListResponse Return="Success"/>' }
        'GetWalletBalance' { return '<GetWalletBalanceResponse Balance="0"/>' }
        'QueryEntitlements' { return '<QueryEntitlementsResponse/>' }
        'QueryOffers' { return '<QueryOffersResponse/>' }
        'SelectStore' { return '<ErrorSuccess Code="0" Description=""/>' }
        default { return '<ErrorSuccess Code="0" Description=""/>' }
    }
}

function Send-Plain($Stream, [string]$Xml) {
    $bytes = [Text.Encoding]::ASCII.GetBytes($Xml + [char]0)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
    Write-Host " -> $($Xml.Substring(0, [Math]::Min(150, $Xml.Length)))"
}

function Send-Encrypted($Stream, [string]$Xml) {
    $frame = (Invoke-AesEncrypt $Xml) + [char]0
    $bytes = [Text.Encoding]::ASCII.GetBytes($frame)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
    Write-Host " -> $($Xml.Substring(0, [Math]::Min(150, $Xml.Length)))"
}

function Invoke-Session($Client, $Data) {
    $stream = $Client.GetStream()
    $challenge = ConvertTo-Hex (New-RandomBytes 16)
    Send-Plain $stream "<LSX><Event sender=`"EALS`"><Challenge key=`"$challenge`" version=`"13,754,0,6267`" build=`"release`"/></Event></LSX>"

    $buf = ''
    $read = New-Object byte[] 65536
    try {
        while ($Client.Connected) {
            $count = $stream.Read($read, 0, $read.Length)
            if ($count -le 0) { break }
            $buf += [Text.Encoding]::ASCII.GetString($read, 0, $count)
            while ($buf.Contains([char]0)) {
                $idx = $buf.IndexOf([char]0)
                $raw = $buf.Substring(0, $idx)
                $buf = $buf.Substring($idx + 1)
                if (-not $raw.Trim()) { continue }
                if ($raw.TrimStart().StartsWith('<LSX>')) {
                    $xml = $raw
                } elseif ($raw -match '^[0-9a-fA-F]{32,}$') {
                    try { $xml = Invoke-AesDecrypt $raw.Trim() } catch { continue }
                } else { continue }
                Write-Host " <- $($xml.Substring(0, [Math]::Min(180, $xml.Length)))"

                $ridMatch = [regex]::Match($xml, 'id="(\d+)"')
                if ($xml.Contains('ChallengeResponse')) {
                    $keyMatch = [regex]::Match($xml, '\bkey="([0-9a-fA-F]+)"')
                    $accepted = if ($keyMatch.Success) { Invoke-AesEncrypt $keyMatch.Groups[1].Value } else { Invoke-AesEncrypt $challenge }
                    $rid = if ($ridMatch.Success) { $ridMatch.Groups[1].Value } else { '1' }
                    Send-Plain $stream "<LSX><Response id=`"$rid`" sender=`"EALS`"><ChallengeAccepted response=`"$accepted`"/></Response></LSX>"
                    Start-Sleep -Milliseconds 400
                    foreach ($eventBody in @($Data.events)) {
                        Send-Encrypted $stream "<LSX><Event sender=`"EbisuSDK`">$eventBody</Event></LSX>"
                    }
                    Send-Encrypted $stream '<LSX><Event sender="EbisuSDK"><IGOEvent State="DOWN"/></Event></LSX>'
                    continue
                }
                if ($ridMatch.Success) {
                    $requestKey = Get-RequestKey $xml
                    $body = Get-ResponseBody -KeyName $requestKey -Raw $xml -Data $Data
                    Send-Encrypted $stream "<LSX><Response id=`"$($ridMatch.Groups[1].Value)`" sender=`"EbisuSDK`">$body</Response></LSX>"
                }
            }
        }
    } finally {
        $stream.Dispose(); $Client.Close()
    }
}

if (-not (Test-Path $TablePath)) { throw "LSX table missing: $TablePath" }
$data = Get-Content $TablePath -Raw | ConvertFrom-Json
if ($data.format -ne 1 -or $data.title -notmatch '15' -or -not $data.table) { throw 'invalid or non-FIFA15 LSX table' }

if ($SelfTest) {
    $sample = '<LSX><Request id="9"><GetGameInfo GameInfoId="LANGUAGES"/></Request></LSX>'
    $round = Invoke-AesDecrypt (Invoke-AesEncrypt $sample)
    if ($round -ne $sample) { throw 'AES round-trip failed' }
    if ((Get-RequestKey $sample) -ne 'GetGameInfo:GameInfoId=LANGUAGES') { throw 'request-key parser failed' }
    Write-Host "PASS: portable LSX responder self-test; table=$($data.table.PSObject.Properties.Count) answers title=$($data.title)"
    exit 0
}

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Portable FIFA15 LSX responder listening on 127.0.0.1:$Port"
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        Write-Host "LSX client connected from $($client.Client.RemoteEndPoint)"
        Invoke-Session -Client $client -Data $data
    }
} finally { $listener.Stop() }
