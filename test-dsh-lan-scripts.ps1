param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$EnablePath = Join-Path $Root 'enable-dsh-lan.ps1'
$DisablePath = Join-Path $Root 'disable-dsh-lan.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

foreach ($path in @($EnablePath, $DisablePath)) {
    Assert-True (Test-Path -LiteralPath $path) "missing $path"
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "$path has PowerShell parse errors: $($parseErrors.Message -join '; ')"
    Assert-True (-not ($tokens.Text -contains '\')) "$path uses a backslash as a PowerShell line continuation"
}

$enable = Get-Content -Raw -LiteralPath $EnablePath
$disable = Get-Content -Raw -LiteralPath $DisablePath

Assert-True ($enable -match 'listenaddress=0\.0\.0\.0') 'enable script must listen on 0.0.0.0'
Assert-True ($enable -match 'connectaddress=127\.0\.0\.1') 'enable script must proxy to 127.0.0.1'
Assert-True ($enable -match 'listenport=\$ListenPort') 'enable script must use the configured listen port'
Assert-True ($enable -match 'connectport=\$ListenPort') 'enable script must use the configured connect port'
Assert-True ($enable -match '(?s)New-NetFirewallRule.+-Protocol TCP.+-LocalPort \$ListenPort.+-Profile Private.+-RemoteAddress LocalSubnet.+-InterfaceAlias \$InterfaceAlias') 'firewall rule must be TCP 3080, Private, LocalSubnet, and Wi-Fi only'
Assert-True ($enable -match 'Remove-NetFirewallRule -DisplayName \$RuleName') 'enable script must reconcile duplicate or incorrect named rules'
Assert-True ($enable -match 'trustedHosts:') 'enable script must configure DSH trustedHosts for the LAN IP'
Assert-True ($enable -match "'  disabled: true'") 'enable script must disable the auto directory picker while LAN access is active'
Assert-True ($enable -match '@deepseek-ai/dsh-host-directory-picker-browse') 'enable script must mount the browse directory-picker backend'
Assert-True ($enable -match '@deepseek-ai/dsh-client-ui-directory-picker-browse') 'enable script must mount the browse directory-picker client surface'
Assert-True ($enable -match '\$status -eq 404') 'trusted-host probe must accept the expected 404 after the API trust fence instead of requiring a real route'
Assert-True ($enable -match 'Get-NetTCPConnection.+127\.0\.0\.1') 'enable script must verify DSH listens on loopback'
Assert-True ($enable -match 'Invoke-WebRequest.+127\.0\.0\.1') 'enable script must verify local HTTP'
Assert-True ($enable -match '\[switch\]\$ValidateOnly') 'enable script must offer a non-mutating validation mode'
Assert-True ($enable -notmatch '(?i)\b(?:New-NetNat|Set-NetNat|Add-NetNatStaticMapping|UPnP)\b') 'enable script must not configure router or Internet forwarding'

Assert-True ($disable -match 'portproxy delete v4tov4') 'disable script must remove the v4tov4 portproxy'
Assert-True ($disable -match 'Remove-NetFirewallRule -DisplayName \$RuleName') 'disable script must remove the firewall rule'
Assert-True ($disable -match 'BackupPath') 'disable script must restore the prior DSH profile patch'

& $EnablePath -ValidateOnly | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'enable script validation mode must pass on the current machine'

Write-Host 'PASS: DSH LAN scripts satisfy syntax, safety, idempotency, rollback, and local-readiness checks.'
