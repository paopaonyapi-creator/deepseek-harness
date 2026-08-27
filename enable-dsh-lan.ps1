param(
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ListenPort = 3080
$RuleName = 'DSH Web LAN 3080'
$InterfaceAlias = 'Wi-Fi'
$ProfilePatchPath = Join-Path $env:USERPROFILE '.dsh\profiles\web\cordis.patch.yml'
$BackupPath = Join-Path $env:USERPROFILE '.dsh\profiles\web\cordis.patch.before-dsh-lan.yml'
$StatusPath = Join-Path (Split-Path -Parent $PSCommandPath) 'dsh-lan-status.json'
$ManagedMarker = '# Managed by enable-dsh-lan.ps1'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LanAddress {
    $profile = Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction Stop
    if ($profile.NetworkCategory -ne 'Private') {
        throw "Interface '$InterfaceAlias' must use the Private network profile; current profile is $($profile.NetworkCategory)."
    }

    $addresses = @(Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $_.IPAddress -notmatch '^(127|169\.254)\.' -and
            $_.AddressState -eq 'Preferred'
        })
    if ($addresses.Count -ne 1) {
        throw "Expected exactly one active IPv4 address on '$InterfaceAlias'; found $($addresses.Count)."
    }
    return [string]$addresses[0].IPAddress
}

function Assert-DshLocalReady {
    $listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $listener) {
        throw "DSH is not listening at 127.0.0.1:$ListenPort."
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
    if (-not $process -or $process.CommandLine -notmatch 'deepseek-harness.+apps\\cli\\lib\\bin\.js.+\bweb\b') {
        throw "Port 127.0.0.1:$ListenPort is not owned by the expected DSH Web process."
    }

    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri "http://127.0.0.1:$ListenPort/"
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>DSH Local Build</title>') {
        throw "DSH local HTTP verification failed at http://127.0.0.1:$ListenPort/."
    }
}

function Get-PortProxyEntries {
    $lines = netsh interface portproxy show v4tov4
    foreach ($line in $lines) {
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') {
            [pscustomobject]@{
                ListenAddress = $Matches[1]
                ListenPort = [int]$Matches[2]
                ConnectAddress = $Matches[3]
                ConnectPort = [int]$Matches[4]
            }
        }
    }
}

function Test-TrustedApi {
    param([string]$LanAddress)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Get,
            "http://127.0.0.1:$ListenPort/api/dsh-lan-trust-probe"
        )
        $request.Headers.Host = "$($LanAddress):$ListenPort"
        [void]$request.Headers.TryAddWithoutValidation('Origin', "http://$($LanAddress):$ListenPort")
        [void]$request.Headers.TryAddWithoutValidation('Sec-Fetch-Site', 'same-origin')
        $response = $client.Send($request)
        return [int]$response.StatusCode
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Set-DshLanProfile {
    param([string]$LanAddress)

    if (-not (Test-Path -LiteralPath $ProfilePatchPath)) {
        throw "DSH Web profile patch is missing: $ProfilePatchPath"
    }

    $current = Get-Content -Raw -LiteralPath $ProfilePatchPath
    if (Test-Path -LiteralPath $BackupPath) {
        if ($current -notmatch [regex]::Escape($ManagedMarker)) {
            throw "A DSH LAN backup exists but the active profile patch is no longer managed by this script. Refusing to overwrite user changes."
        }
    }
    else {
        Copy-Item -LiteralPath $ProfilePatchPath -Destination $BackupPath
    }

    $patchLines = @(
        $ManagedMarker,
        '# Trusts one private Wi-Fi IPv4 authority and uses the in-browser directory picker.',
        '# Restored by disable-dsh-lan.ps1.',
        '- id: web-runtime',
        '  config:',
        '    openBrowser: !!js ctx.webStartup.openBrowser',
        '    printUrl: true',
        '    surfaceContext: true',
        "    trustedHosts: ['$LanAddress']",
        '',
        '- id: directory-picker',
        '  disabled: true',
        '- insert:',
        '    - id: directory-picker-browse',
        "      name: '@deepseek-ai/dsh-host-directory-picker-browse'",
        '    - id: ui-directory-picker-browse',
        "      name: '@deepseek-ai/dsh-client-ui-directory-picker-browse'"
    )
    Set-Content -LiteralPath $ProfilePatchPath -Value $patchLines -Encoding utf8

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $status = Test-TrustedApi -LanAddress $LanAddress
        # The probe path intentionally has no route: 404 proves the request
        # crossed the trust fence, whereas an untrusted LAN authority gets 403.
        if ($status -eq 404) { return }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "DSH did not accept the trusted LAN authority after its profile hot reload; last API status was $status."
}

function Ensure-PortProxy {
    $listeners = @(Get-PortProxyEntries | Where-Object {
        $_.ListenAddress -eq '0.0.0.0' -and $_.ListenPort -eq $ListenPort
    })
    if ($listeners.Count -gt 1) {
        throw "More than one portproxy listener exists at 0.0.0.0:$ListenPort."
    }
    if ($listeners.Count -eq 1) {
        $entry = $listeners[0]
        if ($entry.ConnectAddress -ne '127.0.0.1' -or $entry.ConnectPort -ne $ListenPort) {
            throw "A conflicting portproxy already owns 0.0.0.0:$ListenPort."
        }
        return
    }

    netsh interface portproxy add v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 connectport=$ListenPort connectaddress=127.0.0.1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "netsh failed to add the DSH portproxy (exit $LASTEXITCODE)."
    }
}

function Test-OurFirewallRule {
    param([Microsoft.Management.Infrastructure.CimInstance]$Rule)

    $port = $Rule | Get-NetFirewallPortFilter
    $address = $Rule | Get-NetFirewallAddressFilter
    $interface = $Rule | Get-NetFirewallInterfaceFilter
    return (
        $Rule.Enabled -eq 'True' -and
        $Rule.Direction -eq 'Inbound' -and
        $Rule.Action -eq 'Allow' -and
        $Rule.Profile -eq 'Private' -and
        $port.Protocol -eq 'TCP' -and
        [string]$port.LocalPort -eq [string]$ListenPort -and
        $address.RemoteAddress -contains 'LocalSubnet' -and
        $interface.InterfaceAlias -contains $InterfaceAlias
    )
}

function Assert-NoBroadPortRule {
    $broad = foreach ($rule in Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow) {
        $port = $rule | Get-NetFirewallPortFilter
        if ([string]$port.LocalPort -ne [string]$ListenPort) { continue }
        $profileText = [string]$rule.Profile
        if ($rule.DisplayName -ne $RuleName -and ($profileText -match 'Public|Any')) {
            $rule
        }
    }
    if (@($broad).Count -gt 0) {
        throw "Another enabled inbound allow rule exposes TCP $ListenPort on Public/Any profile: $($broad.DisplayName -join ', ')."
    }
}

function Ensure-FirewallRule {
    Assert-NoBroadPortRule
    $rules = @(Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 1 -and (Test-OurFirewallRule -Rule $rules[0])) {
        return
    }
    if ($rules.Count -gt 0) {
        Remove-NetFirewallRule -DisplayName $RuleName
    }

    New-NetFirewallRule -DisplayName $RuleName -Enabled True -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ListenPort -Profile Private -RemoteAddress LocalSubnet -InterfaceAlias $InterfaceAlias | Out-Null
    $created = @(Get-NetFirewallRule -DisplayName $RuleName -ErrorAction Stop)
    if ($created.Count -ne 1 -or -not (Test-OurFirewallRule -Rule $created[0])) {
        throw 'Firewall rule verification failed.'
    }
    Assert-NoBroadPortRule
}

function Write-Status {
    param([string]$LanAddress, [bool]$Enabled)
    [ordered]@{
        enabled = $Enabled
        localUrl = "http://127.0.0.1:$ListenPort/"
        lanUrl = "http://$($LanAddress):$ListenPort/"
        interface = $InterfaceAlias
        firewallProfile = 'Private'
        remoteAddress = 'LocalSubnet'
        routerForwarding = $false
        checkedAt = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StatusPath -Encoding utf8
}

$lanIp = Get-LanAddress
Assert-DshLocalReady

if ($ValidateOnly) {
    Write-Host "VALID: DSH is ready at http://127.0.0.1:$ListenPort/; planned mobile URL is http://$($lanIp):$ListenPort/."
    exit 0
}

if (-not (Test-IsAdministrator)) {
    throw 'Administrator rights are required. Run this script with Run as administrator.'
}

Set-DshLanProfile -LanAddress $lanIp
Ensure-PortProxy
Ensure-FirewallRule

$proxy = @(Get-PortProxyEntries | Where-Object {
    $_.ListenAddress -eq '0.0.0.0' -and
    $_.ListenPort -eq $ListenPort -and
    $_.ConnectAddress -eq '127.0.0.1' -and
    $_.ConnectPort -eq $ListenPort
})
if ($proxy.Count -ne 1) {
    throw 'The exact DSH portproxy was not present after setup.'
}

$lanResponse = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri "http://$($lanIp):$ListenPort/"
if ($lanResponse.StatusCode -ne 200 -or $lanResponse.Content -notmatch '<title>DSH Local Build</title>') {
    throw "LAN HTTP verification failed at http://$($lanIp):$ListenPort/."
}
if ((Test-TrustedApi -LanAddress $lanIp) -ne 404) {
    throw 'DSH LAN API trust verification failed.'
}

Write-Status -LanAddress $lanIp -Enabled $true
Write-Host "SUCCESS: Open http://$($lanIp):$ListenPort/ from a phone on the same Wi-Fi."
