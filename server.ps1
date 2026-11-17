$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$projectPrefix = $projectRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$jsonPath = Join-Path $projectRoot 'leaderboard.json'
$csvPath = Join-Path $projectRoot 'leaderboard.csv'
$port = 8766
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$apiCorsHeaders = @{
    'Access-Control-Allow-Origin' = '*'
    'Access-Control-Allow-Methods' = 'GET, POST, OPTIONS'
    'Access-Control-Allow-Headers' = 'Content-Type'
    'Access-Control-Allow-Private-Network' = 'true'
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    [System.IO.File]::WriteAllText($jsonPath, '[]', $utf8NoBom)
}
if (-not (Test-Path -LiteralPath $csvPath)) {
    $csvHeader = [string][char]0xFEFF + '"Peringkat";"Nama pemain";"Skor";"Total soal";"Selesai pada"' + "`r`n"
    [System.IO.File]::WriteAllText($csvPath, $csvHeader, $utf8NoBom)
}

function Get-LeaderboardEntries {
    $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $parsed = ConvertFrom-Json -InputObject $raw
    $entries = @($parsed | Where-Object {
        $_ -and $_.id -is [string] -and $_.name -is [string] -and
        $_.score -ne $null -and $_.totalQuestions -ne $null -and $_.completedAt -is [string]
    })
    return @($entries | Sort-Object `
        @{ Expression = { [int]$_.score }; Descending = $true }, `
        @{ Expression = { [datetime]$_.completedAt }; Ascending = $true }, `
        @{ Expression = { [string]$_.id }; Ascending = $true })
}

function ConvertTo-JsonArray($Entries) {
    if (-not $Entries -or $Entries.Count -eq 0) { return '[]' }
    return ConvertTo-Json -InputObject ([object[]]$Entries) -Depth 5
}

function ConvertTo-CsvField([object]$Value) {
    $text = [string]$Value
    if ($text -match '^[=+@-]') { $text = "'" + $text }
    return '"' + $text.Replace('"', '""') + '"'
}

function Save-LeaderboardFiles($Entries) {
    $sortedEntries = @($Entries | Sort-Object `
        @{ Expression = { [int]$_.score }; Descending = $true }, `
        @{ Expression = { [datetime]$_.completedAt }; Ascending = $true }, `
        @{ Expression = { [string]$_.id }; Ascending = $true })
    $jsonText = ConvertTo-JsonArray $sortedEntries
    $csvLines = New-Object 'System.Collections.Generic.List[string]'
    $csvLines.Add('"Peringkat";"Nama pemain";"Skor";"Total soal";"Selesai pada"')
    for ($index = 0; $index -lt $sortedEntries.Count; $index++) {
        $entry = $sortedEntries[$index]
        $fields = @(($index + 1), $entry.name, $entry.score, $entry.totalQuestions, $entry.completedAt)
        $csvLines.Add((($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ';'))
    }
    $csvText = [string][char]0xFEFF + ($csvLines -join "`r`n") + "`r`n"

    $jsonTemp = "$jsonPath.tmp"
    $csvTemp = "$csvPath.tmp"
    [System.IO.File]::WriteAllText($jsonTemp, $jsonText, $utf8NoBom)
    [System.IO.File]::WriteAllText($csvTemp, $csvText, $utf8NoBom)
    Move-Item -LiteralPath $jsonTemp -Destination $jsonPath -Force
    Move-Item -LiteralPath $csvTemp -Destination $csvPath -Force
    return $sortedEntries
}

function Read-HttpLine($Stream) {
    $lineBuffer = New-Object System.IO.MemoryStream
    while ($true) {
        $nextByte = $Stream.ReadByte()
        if ($nextByte -lt 0 -or $nextByte -eq 10) { break }
        if ($nextByte -ne 13) { $lineBuffer.WriteByte([byte]$nextByte) }
        if ($lineBuffer.Length -gt 8192) { throw 'HTTP header terlalu panjang.' }
    }
    return [System.Text.Encoding]::ASCII.GetString($lineBuffer.ToArray())
}

function Read-HttpRequest($Stream) {
    $requestLine = Read-HttpLine $Stream
    if ([string]::IsNullOrWhiteSpace($requestLine)) { return $null }
    $parts = $requestLine.Split(' ')
    if ($parts.Length -lt 2) { throw 'Baris HTTP tidak valid.' }
    $headers = @{}
    while ($true) {
        $line = Read-HttpLine $Stream
        if ([string]::IsNullOrEmpty($line)) { break }
        $separator = $line.IndexOf(':')
        if ($separator -gt 0) { $headers[$line.Substring(0, $separator).Trim()] = $line.Substring($separator + 1).Trim() }
    }
    $body = [byte[]]@()
    if ($headers.ContainsKey('Content-Length')) {
        $length = [int]$headers['Content-Length']
        if ($length -lt 0 -or $length -gt 32768) { throw 'Ukuran body HTTP tidak valid.' }
        if ($length -gt 0) {
            $body = New-Object byte[] $length
            $offset = 0
            while ($offset -lt $length) {
                $count = $Stream.Read($body, $offset, $length - $offset)
                if ($count -le 0) { throw 'Body HTTP terpotong.' }
                $offset += $count
            }
        }
    }
    return [pscustomobject]@{ Method = $parts[0].ToUpperInvariant(); Target = $parts[1]; Headers = $headers; Body = $body }
}

function Send-Response($Stream, [int]$Status, [string]$ContentType, [byte[]]$Bytes, [hashtable]$Headers, [bool]$HeadOnly) {
    $reason = switch ($Status) { 200 { 'OK' } 206 { 'Partial Content' } 400 { 'Bad Request' } 403 { 'Forbidden' } 404 { 'Not Found' } 405 { 'Method Not Allowed' } 416 { 'Range Not Satisfiable' } default { 'Internal Server Error' } }
    $headerLines = New-Object 'System.Collections.Generic.List[string]'
    $headerLines.Add("HTTP/1.1 $Status $reason")
    $headerLines.Add("Content-Type: $ContentType")
    $headerLines.Add("Content-Length: $($Bytes.Length)")
    $headerLines.Add('Connection: close')
    foreach ($key in $Headers.Keys) { $headerLines.Add("${key}: $($Headers[$key])") }
    $headerLines.Add('')
    $headerLines.Add('')
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(($headerLines -join "`r`n"))
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if (-not $HeadOnly -and $Bytes.Length -gt 0) { $Stream.Write($Bytes, 0, $Bytes.Length) }
    $Stream.Flush()
}

function Send-Text($Stream, [int]$Status, [string]$ContentType, [string]$Text, [hashtable]$Headers, [bool]$HeadOnly) {
    Send-Response $Stream $Status $ContentType ([System.Text.Encoding]::UTF8.GetBytes($Text)) $Headers $HeadOnly
}

function Get-ContentType([string]$Extension) {
    switch ($Extension.ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'text/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.csv' { return 'text/csv; charset=utf-8' }
        '.png' { return 'image/png' }
        '.jpg' { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.webp' { return 'image/webp' }
        '.svg' { return 'image/svg+xml' }
        '.mp4' { return 'video/mp4' }
        '.webm' { return 'video/webm' }
        '.mov' { return 'video/quicktime' }
        '.mp3' { return 'audio/mpeg' }
        '.ogg' { return 'audio/ogg' }
        '.pdf' { return 'application/pdf' }
        default { return 'application/octet-stream' }
    }
}

function Serve-StaticFile($ClientStream, $Request, [string]$RequestPath) {
    $relativePath = [Uri]::UnescapeDataString($RequestPath.TrimStart('/')).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = 'index.html' }
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
    if (-not $fullPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text $ClientStream 403 'text/plain; charset=utf-8' 'Forbidden' @{} ($Request.Method -eq 'HEAD')
        return
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Send-Text $ClientStream 404 'text/plain; charset=utf-8' 'Not found' @{} ($Request.Method -eq 'HEAD')
        return
    }

    $fileStream = [System.IO.File]::OpenRead($fullPath)
    try {
        $fileLength = $fileStream.Length
        $start = [long]0
        $end = $fileLength - 1
        $rangeHeader = $Request.Headers['Range']
        if ($rangeHeader) {
            $rangeMatch = [regex]::Match($rangeHeader, '^bytes=(\d*)-(\d*)$')
            if (-not $rangeMatch.Success -or $fileLength -eq 0) {
                Send-Text $ClientStream 416 'text/plain; charset=utf-8' 'Range not satisfiable' @{ 'Content-Range' = "bytes */$fileLength" } ($Request.Method -eq 'HEAD')
                return
            }
            if ($rangeMatch.Groups[1].Value) {
                $start = [long]$rangeMatch.Groups[1].Value
                if ($rangeMatch.Groups[2].Value) { $end = [long]$rangeMatch.Groups[2].Value }
            } elseif ($rangeMatch.Groups[2].Value) {
                $suffixLength = [long]$rangeMatch.Groups[2].Value
                $start = [Math]::Max(0, $fileLength - $suffixLength)
            }
            if ($start -ge $fileLength -or $end -lt $start) {
                Send-Text $ClientStream 416 'text/plain; charset=utf-8' 'Range not satisfiable' @{ 'Content-Range' = "bytes */$fileLength" } ($Request.Method -eq 'HEAD')
                return
            }
            $end = [Math]::Min($end, $fileLength - 1)
            $status = 206
            $extraHeaders = @{ 'Content-Range' = "bytes $start-$end/$fileLength" }
        } else {
            $status = 200
            $extraHeaders = @{}
        }

        $contentLength = $end - $start + 1
        $ContextHeaders = @{ 'Accept-Ranges' = 'bytes'; 'Cache-Control' = 'no-cache' }
        foreach ($key in $extraHeaders.Keys) { $ContextHeaders[$key] = $extraHeaders[$key] }
        $headerLines = New-Object 'System.Collections.Generic.List[string]'
        $reason = if ($status -eq 206) { 'Partial Content' } else { 'OK' }
        $headerLines.Add("HTTP/1.1 $status $reason")
        $headerLines.Add("Content-Type: $(Get-ContentType ([System.IO.Path]::GetExtension($fullPath)))")
        $headerLines.Add("Content-Length: $contentLength")
        $headerLines.Add('Connection: close')
        foreach ($key in $ContextHeaders.Keys) { $headerLines.Add("${key}: $($ContextHeaders[$key])") }
        $headerLines.Add('')
        $headerLines.Add('')
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(($headerLines -join "`r`n"))
        $ClientStream.Write($headerBytes, 0, $headerBytes.Length)
        if ($Request.Method -ne 'HEAD') {
            $null = $fileStream.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] 65536
            $remaining = $contentLength
            while ($remaining -gt 0) {
                $readCount = $fileStream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
                if ($readCount -le 0) { break }
                $ClientStream.Write($buffer, 0, $readCount)
                $remaining -= $readCount
            }
        }
        $ClientStream.Flush()
    } finally {
        $fileStream.Dispose()
    }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
$listener.Start()
Write-Host "PMI berjalan pada port $port. Buka alamat yang sesuai di perangkat peserta:"
$networkAddresses = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up } |
    ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
    Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($_.Address) } |
    ForEach-Object { $_.Address.ToString() } |
    Sort-Object -Unique
foreach ($address in $networkAddresses) { Write-Host "  http://${address}:$port/" }
Write-Host "  http://127.0.0.1:$port/ (perangkat server saja)"
Write-Host 'Tekan Ctrl+C untuk menghentikan server.'

$listenerRunning = $true
while ($listenerRunning) {
    $client = $listener.AcceptTcpClient()
    $networkStream = $client.GetStream()
    try {
        $request = Read-HttpRequest $networkStream
        if (-not $request) { continue }
        $path = [Uri]::UnescapeDataString(($request.Target -split '\?', 2)[0])
        $headOnly = $request.Method -eq 'HEAD'
        if ($path -eq '/api/leaderboard' -and $request.Method -eq 'OPTIONS') {
            Send-Text $networkStream 200 'text/plain; charset=utf-8' '' $apiCorsHeaders $false
        } elseif ($path -eq '/api/leaderboard' -and $request.Method -eq 'GET') {
            $entries = @(Get-LeaderboardEntries)
            Send-Text $networkStream 200 'application/json; charset=utf-8' (ConvertTo-JsonArray $entries) $apiCorsHeaders $false
        } elseif ($path -eq '/api/leaderboard' -and $request.Method -eq 'POST') {
            $posted = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($request.Body))
            $scoreValue = 0
            $totalValue = 0
            $parsedDate = [datetime]::MinValue
            if (-not $posted -or -not $posted.id -or [string]::IsNullOrWhiteSpace([string]$posted.name) -or
                ([string]$posted.name).Length -gt 30 -or
                -not [int]::TryParse([string]$posted.score, [ref]$scoreValue) -or $scoreValue -lt 0 -or
                -not [int]::TryParse([string]$posted.totalQuestions, [ref]$totalValue) -or $totalValue -lt 1 -or $scoreValue -gt $totalValue -or
                -not [datetime]::TryParse([string]$posted.completedAt, [ref]$parsedDate)) {
                Send-Text $networkStream 400 'text/plain; charset=utf-8' 'Data skor tidak valid.' $apiCorsHeaders $false
            } else {
                $entry = [pscustomobject]@{
                    id = [string]$posted.id
                    name = ([string]$posted.name).Trim()
                    score = $scoreValue
                    totalQuestions = $totalValue
                    completedAt = $parsedDate.ToUniversalTime().ToString('o')
                }
                $entries = @(Get-LeaderboardEntries | Where-Object { $_.id -ne $entry.id })
                $entries += $entry
                $savedEntries = @(Save-LeaderboardFiles $entries)
                Send-Text $networkStream 200 'application/json; charset=utf-8' (ConvertTo-JsonArray $savedEntries) $apiCorsHeaders $false
            }
        } elseif ($path -eq '/api/leaderboard.csv' -and $request.Method -eq 'GET') {
            $bytes = [System.IO.File]::ReadAllBytes($csvPath)
            Send-Response $networkStream 200 'text/csv; charset=utf-8' $bytes @{} $false
        } elseif ($request.Method -in @('GET', 'HEAD')) {
            Serve-StaticFile $networkStream $request $path
        } else {
            Send-Text $networkStream 405 'text/plain; charset=utf-8' 'Method not allowed' @{} $headOnly
        }
    } catch {
        Write-Warning $_.Exception.Message
        try { Send-Text $networkStream 500 'text/plain; charset=utf-8' 'Kesalahan server lokal.' $apiCorsHeaders $false } catch { }
    } finally {
        $networkStream.Dispose()
        $client.Close()
    }
}
