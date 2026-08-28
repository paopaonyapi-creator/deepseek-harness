#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dsh - DeepSeek Harness CLI wrapper
.DESCRIPTION
    Calls the built dsh CLI from the repo root.
    Faster than pnpm dsh because it uses the pre-built JavaScript.
.EXAMPLE
    dsh web
    dsh web --port 8080
    dsh --profile headless "run the tests"
#>

$scriptDir = Split-Path -Parent $PSCommandPath
$binPath = [System.IO.Path]::Combine($scriptDir, 'apps', 'cli', 'lib', 'bin.js')

if (-not (Test-Path -LiteralPath $binPath)) {
    Write-Error ('dsh built binary not found at: ' + $binPath)
    Write-Error 'Run pnpm run build in the repo root first.'
    exit 1
}

$node = Get-Command node -ErrorAction Stop
try {
    & $node.Source $binPath @args
    exit $LASTEXITCODE
}
catch {
    Write-Error $_
    exit 1
}
