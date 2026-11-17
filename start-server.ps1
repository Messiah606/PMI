$ErrorActionPreference = 'Stop'
$serverScriptPath = Join-Path $PSScriptRoot 'server.ps1'
& $serverScriptPath
