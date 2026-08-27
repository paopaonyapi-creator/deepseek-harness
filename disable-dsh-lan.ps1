param()

$ErrorActionPreference = 'Stop'
$ListenPort = 3080
$RuleName = 'DSH Web LAN 3080'
$ProfilePatchPath = Join-Path $env:USERPROFILE '.dsh\profiles\web\cordis.patch.yml'
$BackupPath = Join-Path $env:USERPROFILE '.dsh\profiles\web\cordis.patch.before-dsh-lan.yml'
$StatusPath = Join-Path (Split-Path -Parent $PSCommandPath) 'dsh-lan-status.json'
$ManagedMarker = '# Managed by enable-dsh-lan.ps1'

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator rights are required. Run this script with Run as administrator.'
}

$entries = netsh interface portproxy show v4tov4
$present = $entries | Where-Object { $_ -match '^\s*0\.0\.0\.0\s+3080\s+127\.0\.0\.1\s+3080\s*$' }
if ($present) {
    netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "netsh failed to remove the DSH portproxy (exit $LASTEXITCODE)."
    }
}

$rules = @(Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)
if ($rules.Count -gt 0) {
    Remove-NetFirewallRule -DisplayName $RuleName
}

if (Test-Path -LiteralPath $BackupPath) {
    $current = Get-Content -Raw -LiteralPath $ProfilePatchPath
    if ($current -notmatch [regex]::Escape($ManagedMarker)) {
        throw "The DSH profile patch has user changes. LAN network access is closed, but the saved patch was not restored from $BackupPath."
    }
    Copy-Item -LiteralPath $BackupPath -Destination $ProfilePatchPath -Force
    Remove-Item -LiteralPath $BackupPath
}
elseif ((Test-Path -LiteralPath $ProfilePatchPath) -and
    ((Get-Content -Raw -LiteralPath $ProfilePatchPath) -match [regex]::Escape($ManagedMarker))) {
    Set-Content -LiteralPath $ProfilePatchPath -Value '[]' -Encoding utf8
}

[ordered]@{
    enabled = $false
    localUrl = "http://127.0.0.1:$ListenPort/"
    routerForwarding = $false
    checkedAt = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $StatusPath -Encoding utf8

Write-Host 'SUCCESS: DSH LAN access is disabled; the local DSH server was left running.'
