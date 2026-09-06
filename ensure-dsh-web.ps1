# Ensures the DSH Web backend for LAN access is listening on 127.0.0.1:3098.
# Idempotent and safe without administrator rights: exits 0 when already up,
# otherwise starts one hidden backend and waits for its listener.
# Used by DSH-LAN.cmd, the Startup shortcut, and the 5-minute watchdog task.

$ErrorActionPreference = 'Stop'
$BackendPort = 3098
$RepoRoot = Split-Path -Parent $PSCommandPath
$BinPath = Join-Path $RepoRoot 'apps\cli\lib\bin.js'

$listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $BackendPort -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($listener) {
    Write-Host "OK: backend already listening on 127.0.0.1:$BackendPort (PID $($listener.OwningProcess))."
    exit 0
}

if (-not (Test-Path -LiteralPath $BinPath)) {
    throw "dsh built binary not found at $BinPath. Run 'pnpm run build' in the repo root first."
}

$node = Get-Command node -ErrorAction Stop
$LogDir = Join-Path ([IO.Path]::GetTempPath()) 'dsh-web-3098'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogOut = Join-Path $LogDir 'backend.out.log'
$LogErr = Join-Path $LogDir 'backend.err.log'
# Quote the script path: Start-Process joins array arguments with spaces, so a
# path containing spaces (e.g. C:\Users\AD PAO\...) must carry its own quotes.
$BinArg = '"' + $BinPath + '"'
Start-Process -FilePath $node.Source -ArgumentList @($BinArg, 'web', '--port', "$BackendPort", '--no-open') -WorkingDirectory $RepoRoot -WindowStyle Hidden -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr | Out-Null

$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 500
    $listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $BackendPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
} while (-not $listener -and (Get-Date) -lt $deadline)

if (-not $listener) {
    throw "backend did not appear on 127.0.0.1:$BackendPort within 30 seconds (see $LogErr)."
}
Write-Host "STARTED: backend listening on 127.0.0.1:$BackendPort (PID $($listener.OwningProcess))."
Write-Host 'Phone URL (same Wi-Fi): http://192.168.1.127:3080/'
