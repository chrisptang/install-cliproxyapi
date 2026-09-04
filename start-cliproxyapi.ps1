#Requires -Version 5.1
<#
.SYNOPSIS
Installs and manages CLIProxyAPI and cpa-usage-keeper on Windows.

.DESCRIPTION
The manager installs both applications into the current user's LocalAppData
directory. It creates current-user Scheduled Tasks for login startup, crash
restart, and a daily update check at a user-selected time (default 09:00).
Administrator privileges are not
required.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\start-cliproxyapi.ps1 install -Port 9000

.EXAMPLE
.\start-cliproxyapi.ps1 install -Lan -ApiKey ([guid]::NewGuid().ToString('N'))

.EXAMPLE
.\start-cliproxyapi.ps1 status
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'install', 'update', 'start', 'stop', 'restart', 'status', 'uninstall',
        'keeper-install', 'keeper-update', 'keeper-start', 'keeper-stop',
        'keeper-restart', 'help'
    )]
    [string]$Command = 'install',

    # Used only for GitHub API and release downloads. Pass an empty string to
    # connect directly. The selected value is persisted for daily updates.
    [AllowEmptyString()]
    [string]$GitHubProxy,

    [ValidateRange(1, 65535)]
    [int]$Port = 8317,

    # Bind 0.0.0.0 instead of 127.0.0.1 so other machines on the local network
    # can reach the proxy. Requires -ApiKey, because binding 0.0.0.0 also exposes
    # the management API and the shipped "local-key" default is public.
    [switch]$Lan,

    # API key clients must present. Also becomes the management secret-key.
    [ValidatePattern('^[A-Za-z0-9._~-]{16,}$')]
    [string]$ApiKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'start-cliproxyapi.ps1 can only run on Windows.'
}

[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

$script:GitHubProxyWasSpecified = $PSBoundParameters.ContainsKey('GitHubProxy')
$script:PortWasSpecified = $PSBoundParameters.ContainsKey('Port')
if ($script:PortWasSpecified -and $Command -ne 'install') {
    throw '-Port is only supported with the install command.'
}
$script:LanWasSpecified = $PSBoundParameters.ContainsKey('Lan')
$script:ApiKeyWasSpecified = $PSBoundParameters.ContainsKey('ApiKey')
if ($script:LanWasSpecified -and $Command -ne 'install') {
    throw '-Lan is only supported with the install command.'
}
if ($script:ApiKeyWasSpecified -and $Command -ne 'install') {
    throw '-ApiKey is only supported with the install command.'
}
# Binding 0.0.0.0 exposes the proxy AND its management API to the whole local
# network, so the shipped "local-key" default must not be reused there.
if ($script:LanWasSpecified -and -not $script:ApiKeyWasSpecified) {
    throw ('-Lan requires -ApiKey: binding 0.0.0.0 exposes the proxy and its management ' +
           'API to the local network, and the default key is public.')
}
$script:ProxyPort = $Port
$script:ProxyHost = if ($Lan) { '0.0.0.0' } else { '127.0.0.1' }
$script:ProxyApiKey = if ($script:ApiKeyWasSpecified) { $ApiKey } else { 'local-key' }

$script:DataDir = Join-Path $env:LOCALAPPDATA 'CLIProxyAPI'
$script:LogDir = Join-Path $script:DataDir 'logs'
$script:KeeperDataDir = Join-Path $script:DataDir 'keeper-data'
$script:BinPath = Join-Path $script:DataDir 'cli-proxy-api.exe'
$script:KeeperBinPath = Join-Path $script:DataDir 'cpa-usage-keeper.exe'
$script:ConfigPath = Join-Path $script:DataDir 'config.yaml'
$script:KeeperEnvPath = Join-Path $script:KeeperDataDir '.env'
$script:VersionFile = Join-Path $script:DataDir '.cliproxyapi-version'
$script:KeeperVersionFile = Join-Path $script:DataDir '.cpa-usage-keeper-version'
$script:SettingsPath = Join-Path $script:DataDir 'manager-settings.json'
$script:InstalledManagerPath = Join-Path $script:DataDir 'start-cliproxyapi.ps1'

$script:ProxyTask = 'CLIProxyAPI Proxy'
$script:ProxyUpdateTask = 'CLIProxyAPI Proxy Update'
$script:KeeperTask = 'CLIProxyAPI Usage Keeper'
$script:KeeperUpdateTask = 'CLIProxyAPI Usage Keeper Update'

$script:ProxyRepo = 'router-for-me/CLIProxyAPI'
$script:KeeperRepo = 'Willxup/cpa-usage-keeper'
$script:KeeperPort = 30000
$script:UpdateTime = '09:00'

function Write-Log {
    param([string]$Message)
    Write-Host "[cliproxyapi] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Warning "[cliproxyapi] $Message"
}

function Read-UpdateTime {
    while ($true) {
        $value = Read-Host 'Daily update time [09:00] (HH:mm)'
        if ([string]::IsNullOrWhiteSpace($value)) { $value = '09:00' }
        if ($value -match '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') {
            $script:UpdateTime = $value
            return
        }
        Write-Warn "Invalid time: $value (expected HH:mm, for example 09:00 or 23:30)."
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Initialize-Directories {
    @($script:DataDir, $script:LogDir, $script:KeeperDataDir) | ForEach-Object {
        [System.IO.Directory]::CreateDirectory($_) | Out-Null
    }
}

function Resolve-GitHubProxy {
    if ($script:GitHubProxyWasSpecified) {
        return $GitHubProxy
    }

    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $settings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            if ($null -ne $settings.GitHubProxy) {
                return [string]$settings.GitHubProxy
            }
        }
        catch {
            Write-Warn "Unable to read $($script:SettingsPath); using environment/default proxy."
        }
    }

    if ($env:http_proxy) { return $env:http_proxy }
    if ($env:HTTP_PROXY) { return $env:HTTP_PROXY }
    return 'http://127.0.0.1:7890'
}

$script:GitHubProxy = Resolve-GitHubProxy

function Save-ManagerSettings {
    Initialize-Directories
    $json = @{ GitHubProxy = $script:GitHubProxy } | ConvertTo-Json
    Write-Utf8NoBom -Path $script:SettingsPath -Content $json
}

function Install-ManagerCopy {
    Initialize-Directories
    $source = $PSCommandPath
    if (-not $source) {
        throw 'Cannot determine the current manager script path.'
    }

    $sourceFullPath = [System.IO.Path]::GetFullPath($source)
    $targetFullPath = [System.IO.Path]::GetFullPath($script:InstalledManagerPath)
    if (-not $sourceFullPath.Equals($targetFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $sourceFullPath -Destination $targetFullPath -Force
        Write-Log "Installed manager script at $targetFullPath"
    }
}

function Get-WindowsArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    switch -Regex ($architecture) {
        '^(AMD64|x86_64)$' {
            return @{ Proxy = 'amd64'; Keeper = 'amd64'; Display = 'x64' }
        }
        '^(ARM64|aarch64)$' {
            return @{ Proxy = 'aarch64'; Keeper = 'arm64'; Display = 'ARM64' }
        }
        default {
            throw "Unsupported Windows architecture: $architecture. Only x64 and ARM64 are supported."
        }
    }
}

function Get-GitHubParameters {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $parameters = @{
        Uri             = $Uri
        UseBasicParsing = $true
        Headers         = @{ 'User-Agent' = 'install-cliproxyapi-windows' }
    }
    if ($script:GitHubProxy) {
        $parameters.Proxy = $script:GitHubProxy
    }
    return $parameters
}

function Get-LatestReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$AssetPattern
    )

    Write-Log "Checking latest release for $Repository ..."
    $parameters = Get-GitHubParameters -Uri "https://api.github.com/repos/$Repository/releases/latest"
    $release = Invoke-RestMethod @parameters
    $asset = @($release.assets) | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    if (-not $release.tag_name -or -not $asset) {
        throw "Could not find a release asset matching '$AssetPattern' in $Repository."
    }

    return [PSCustomObject]@{
        Tag = [string]$release.tag_name
        Url = [string]$asset.browser_download_url
        Name = [string]$asset.name
    }
}

function Get-LocalVersion {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return (Get-Content -LiteralPath $Path -Raw).Trim()
    }
    return 'none'
}

function Test-TaskExists {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    return $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Test-TaskRunning {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    return $null -ne $task -and $task.State -eq 'Running'
}

function Stop-ManagedTask {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    if (-not (Test-TaskExists -TaskName $TaskName)) {
        return
    }

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not (Test-TaskRunning -TaskName $TaskName)) { break }
        Start-Sleep -Milliseconds 250
    }
}

function Start-ManagedTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$RequiredBinary
    )
    if (-not (Test-Path -LiteralPath $RequiredBinary)) {
        throw "Required binary is missing: $RequiredBinary. Run install first."
    }
    if (-not (Test-TaskExists -TaskName $TaskName)) {
        throw "Scheduled Task '$TaskName' is not installed. Run install first."
    }
    if (-not (Test-TaskRunning -TaskName $TaskName)) {
        Start-ScheduledTask -TaskName $TaskName
    }
}

function Install-LatestBinary {
    param([Parameter(Mandatory = $true)][ValidateSet('Proxy', 'Keeper')][string]$Kind)

    $architecture = Get-WindowsArchitecture
    if ($Kind -eq 'Proxy') {
        $repository = $script:ProxyRepo
        $assetPattern = "_windows_$($architecture.Proxy)\.zip$"
        $binaryName = 'cli-proxy-api.exe'
        $destination = $script:BinPath
        $versionFile = $script:VersionFile
        $taskName = $script:ProxyTask
    }
    else {
        $repository = $script:KeeperRepo
        $assetPattern = "_windows_$($architecture.Keeper)\.zip$"
        $binaryName = 'cpa-usage-keeper.exe'
        $destination = $script:KeeperBinPath
        $versionFile = $script:KeeperVersionFile
        $taskName = $script:KeeperTask
    }

    $release = Get-LatestReleaseAsset -Repository $repository -AssetPattern $assetPattern
    $currentVersion = Get-LocalVersion -Path $versionFile
    if ($currentVersion -eq $release.Tag -and (Test-Path -LiteralPath $destination)) {
        Write-Log "$Kind is already up to date ($currentVersion)."
        return [PSCustomObject]@{ Updated = $false; WasRunning = (Test-TaskRunning -TaskName $taskName) }
    }

    $temporaryDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cliproxyapi-" + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($temporaryDir) | Out-Null
    try {
        $archivePath = Join-Path $temporaryDir $release.Name
        Write-Log "Downloading $Kind $($release.Tag) ($($release.Name)) ..."
        $parameters = Get-GitHubParameters -Uri $release.Url
        $parameters.OutFile = $archivePath
        Invoke-WebRequest @parameters | Out-Null

        $extractDir = Join-Path $temporaryDir 'extracted'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
        $extractedBinary = Get-ChildItem -LiteralPath $extractDir -Filter $binaryName -File -Recurse |
            Select-Object -First 1
        if (-not $extractedBinary) {
            throw "Binary '$binaryName' was not found in $($release.Name)."
        }

        $wasRunning = Test-TaskRunning -TaskName $taskName
        if ($wasRunning) {
            Stop-ManagedTask -TaskName $taskName
        }
        Copy-Item -LiteralPath $extractedBinary.FullName -Destination $destination -Force
        Write-Utf8NoBom -Path $versionFile -Content $release.Tag
        Write-Log "Installed $Kind $($release.Tag) at $destination"
        return [PSCustomObject]@{ Updated = $true; WasRunning = $wasRunning }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDir) {
            Remove-Item -LiteralPath $temporaryDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Sync-ProxyPortFromConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return }

    $content = Get-Content -LiteralPath $script:ConfigPath -Raw
    $match = [regex]::Match($content, '(?m)^port:\s*([0-9]+)\s*(?:#.*)?$')
    if ($match.Success) {
        $configuredPort = [int]$match.Groups[1].Value
        if ($configuredPort -ge 1 -and $configuredPort -le 65535) {
            $script:ProxyPort = $configuredPort
        }
    }
}

function Set-ConfiguredProxyPort {
    $content = Get-Content -LiteralPath $script:ConfigPath -Raw
    $regex = [regex]'(?m)^(port:\s*)[^\s#]+(.*)$'
    if ($regex.IsMatch($content)) {
        $replacement = '${1}' + [string]$script:ProxyPort + '${2}'
        $content = $regex.Replace($content, $replacement, 1)
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`nport: $($script:ProxyPort)`r`n"
    }
    Write-Utf8NoBom -Path $script:ConfigPath -Content $content
    Write-Log "Set CLIProxyAPI port to $($script:ProxyPort) in $($script:ConfigPath)."
}

function Set-ConfiguredProxyHost {
    $content = Get-Content -LiteralPath $script:ConfigPath -Raw
    # Drop any previous bind note (stock or ours) so it cannot contradict the new
    # value, and so repeated runs do not stack up comment lines.
    $content = [regex]::Replace(
        $content,
        '(?m)^(?:# Bind to localhost only by default\.|# Bound to 0\.0\.0\.0 by -Lan: reachable from the local network\.)\r?\n',
        '')
    $note = if ($script:ProxyHost -eq '0.0.0.0') {
        "# Bound to 0.0.0.0 by -Lan: reachable from the local network.`r`n"
    } else { '' }
    $regex = [regex]'(?m)^(host:\s*)[^\s#]+(.*)$'
    if ($regex.IsMatch($content)) {
        $replacement = $note + 'host: "' + $script:ProxyHost + '"${2}'
        $content = $regex.Replace($content, $replacement, 1)
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`n" + $note + 'host: "' + $script:ProxyHost + '"' + "`r`n"
    }
    Write-Utf8NoBom -Path $script:ConfigPath -Content $content
    Write-Log "Set CLIProxyAPI host to $($script:ProxyHost) in $($script:ConfigPath)."
}

# Replaces the api-keys list (and the management secret-key) with the single key
# given via -ApiKey. Any other keys previously listed are dropped.
function Set-ConfiguredApiKey {
    $content = Get-Content -LiteralPath $script:ConfigPath -Raw
    $keysRegex = [regex]'(?m)^api-keys:[^\S\r\n]*\r?\n(?:[^\S\r\n]+-[^\r\n]*\r?\n)*'
    if ($keysRegex.IsMatch($content)) {
        $content = $keysRegex.Replace($content, "api-keys:`r`n  - $($script:ProxyApiKey)`r`n", 1)
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`napi-keys:`r`n  - $($script:ProxyApiKey)`r`n"
    }
    $secretRegex = [regex]'(?m)^([^\S\r\n]+secret-key:[^\S\r\n]*)[^\r\n]*$'
    if ($secretRegex.IsMatch($content)) {
        $content = $secretRegex.Replace($content, '${1}"' + $script:ProxyApiKey + '"', 1)
        Write-Utf8NoBom -Path $script:ConfigPath -Content $content
        Write-Log "Set api-keys and remote-management.secret-key to the provided key in $($script:ConfigPath)."
    }
    else {
        Write-Utf8NoBom -Path $script:ConfigPath -Content $content
        Write-Warn "Set api-keys in $($script:ConfigPath), but found no remote-management.secret-key to update."
        Write-Warn 'Check that the management key is not still the default before exposing this host.'
    }
}

function Ensure-Config {
    Initialize-Directories
    if (Test-Path -LiteralPath $script:ConfigPath) {
        if ($script:PortWasSpecified) {
            Set-ConfiguredProxyPort
        }
        else {
            Sync-ProxyPortFromConfig
        }
        if ($script:ApiKeyWasSpecified) {
            Set-ConfiguredApiKey
        }
        if ($script:LanWasSpecified) {
            Set-ConfiguredProxyHost
        }
        if (-not $script:PortWasSpecified -and -not $script:ApiKeyWasSpecified -and -not $script:LanWasSpecified) {
            Write-Log 'config.yaml already exists; leaving it untouched.'
        }
        return
    }

    $authDir = (Join-Path $HOME '.cli-proxy-api').Replace('\', '/')
    $content = @"
# CLIProxyAPI config generated by start-cliproxyapi.ps1
# Bind address. 127.0.0.1 = this machine only; 0.0.0.0 (-Lan) = reachable from
# the local network.
host: "$($script:ProxyHost)"
port: $($script:ProxyPort)
auth-dir: "$authDir"
api-keys:
  - $($script:ProxyApiKey)
remote-management:
  allow-remote: true
  secret-key: "$($script:ProxyApiKey)"
debug: false
streaming:
  keepalive-seconds: 15
  bootstrap-retries: 1
nonstream-keepalive-interval: 15
commercial-mode: true
usage-statistics-enabled: true
pprof:
  enable: false
  addr: "127.0.0.1:8316"
request-retry: 2
max-retry-credentials: 2
max-retry-interval: 8
transient-error-cooldown-seconds: -1
routing:
  strategy: "fill-first"
  session-affinity: true
  session-affinity-ttl: "2h"
codex:
  identity-confuse: false
quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true
redis-usage-queue-retention-seconds: 60
logging-to-file: true
"@
    Write-Utf8NoBom -Path $script:ConfigPath -Content $content
    Write-Log "Created $($script:ConfigPath) (host: $($script:ProxyHost), API key and management key: $($script:ProxyApiKey))."
}

function Ensure-UsageStatisticsEnabled {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return }
    $content = Get-Content -LiteralPath $script:ConfigPath -Raw
    if ($content -match '(?m)^\s*usage-statistics-enabled:\s*true(?:\s*(?:#.*)?)$') {
        return
    }
    if ($content -match '(?m)^\s*usage-statistics-enabled:') {
        $content = [regex]::Replace(
            $content,
            '(?m)^(\s*usage-statistics-enabled:\s*)[^\s#]+(.*)$',
            '${1}true${2}'
        )
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`nusage-statistics-enabled: true`r`n"
    }
    Write-Utf8NoBom -Path $script:ConfigPath -Content $content
    Write-Log 'Enabled usage-statistics-enabled for cpa-usage-keeper.'
}

function Set-KeeperBaseUrl {
    $content = Get-Content -LiteralPath $script:KeeperEnvPath -Raw
    $baseUrl = "http://127.0.0.1:$($script:ProxyPort)"
    $regex = [regex]'(?m)^CPA_BASE_URL=.*$'
    if ($regex.IsMatch($content)) {
        $content = $regex.Replace($content, "CPA_BASE_URL=$baseUrl", 1)
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`nCPA_BASE_URL=$baseUrl`r`n"
    }
    Write-Utf8NoBom -Path $script:KeeperEnvPath -Content $content
    Write-Log "Set cpa-usage-keeper CPA_BASE_URL to $baseUrl."
}

function Set-KeeperManagementKey {
    $content = Get-Content -LiteralPath $script:KeeperEnvPath -Raw
    $regex = [regex]'(?m)^CPA_MANAGEMENT_KEY=.*$'
    if ($regex.IsMatch($content)) {
        $content = $regex.Replace($content, "CPA_MANAGEMENT_KEY=$($script:ProxyApiKey)", 1)
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`nCPA_MANAGEMENT_KEY=$($script:ProxyApiKey)`r`n"
    }
    Write-Utf8NoBom -Path $script:KeeperEnvPath -Content $content
    Write-Log 'Set cpa-usage-keeper CPA_MANAGEMENT_KEY to match config.yaml.'
}

function Ensure-KeeperEnvironment {
    Initialize-Directories
    if (Test-Path -LiteralPath $script:KeeperEnvPath) {
        if ($script:PortWasSpecified) {
            Set-KeeperBaseUrl
        }
        # The dashboard authenticates with the management key; keep it in sync with
        # the secret-key just written into config.yaml, or it silently gets no data.
        if ($script:ApiKeyWasSpecified) {
            Set-KeeperManagementKey
        }
        if (-not $script:PortWasSpecified -and -not $script:ApiKeyWasSpecified) {
            Write-Log 'cpa-usage-keeper .env already exists; leaving it untouched.'
        }
        return
    }

    if (-not $script:PortWasSpecified) {
        Sync-ProxyPortFromConfig
    }
    $content = @"
# cpa-usage-keeper config generated by start-cliproxyapi.ps1
CPA_BASE_URL=http://127.0.0.1:$($script:ProxyPort)
CPA_MANAGEMENT_KEY=$($script:ProxyApiKey)
APP_PORT=$($script:KeeperPort)
WORK_DIR=.
AUTH_ENABLED=false
TZ=Asia/Shanghai
"@
    Write-Utf8NoBom -Path $script:KeeperEnvPath -Content $content
    Write-Log "Created $($script:KeeperEnvPath) (dashboard port $($script:KeeperPort))."
}

function New-ServiceTaskSettings {
    return New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
}

function New-UpdateTaskSettings {
    return New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
}

function Register-ManagerTasks {
    param([switch]$KeeperOnly)

    Initialize-Directories
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId

    if (-not $KeeperOnly) {
        $proxyAction = New-ScheduledTaskAction `
            -Execute $script:BinPath `
            -Argument ('-config "{0}"' -f $script:ConfigPath) `
            -WorkingDirectory $script:DataDir
        Register-ScheduledTask `
            -TaskName $script:ProxyTask `
            -Action $proxyAction `
            -Trigger $logonTrigger `
            -Principal $principal `
            -Settings (New-ServiceTaskSettings) `
            -Description 'Run CLIProxyAPI at user logon and restart it after a crash.' `
            -Force | Out-Null
    }

    $keeperAction = New-ScheduledTaskAction `
        -Execute $script:KeeperBinPath `
        -WorkingDirectory $script:KeeperDataDir
    Register-ScheduledTask `
        -TaskName $script:KeeperTask `
        -Action $keeperAction `
        -Trigger $logonTrigger `
        -Principal $principal `
        -Settings (New-ServiceTaskSettings) `
        -Description 'Run cpa-usage-keeper at user logon and restart it after a crash.' `
        -Force | Out-Null

    $powerShellPath = (Get-Process -Id $PID).Path
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At $script:UpdateTime
    if (-not $KeeperOnly) {
        $proxyUpdateArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Command update' -f $script:InstalledManagerPath
        $proxyUpdateAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $proxyUpdateArguments -WorkingDirectory $script:DataDir
        Register-ScheduledTask `
            -TaskName $script:ProxyUpdateTask `
            -Action $proxyUpdateAction `
            -Trigger $dailyTrigger `
            -Principal $principal `
            -Settings (New-UpdateTaskSettings) `
            -Description "Check CLIProxyAPI for updates every day at $($script:UpdateTime)." `
            -Force | Out-Null
    }

    $keeperUpdateArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Command keeper-update' -f $script:InstalledManagerPath
    $keeperUpdateAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $keeperUpdateArguments -WorkingDirectory $script:DataDir
    Register-ScheduledTask `
        -TaskName $script:KeeperUpdateTask `
        -Action $keeperUpdateAction `
        -Trigger $dailyTrigger `
        -Principal $principal `
        -Settings (New-UpdateTaskSettings) `
        -Description "Check cpa-usage-keeper for updates every day at $($script:UpdateTime)." `
        -Force | Out-Null

    Write-Log 'Registered login/startup and daily-update Scheduled Tasks.'
}

function Start-Proxy {
    Start-ManagedTask -TaskName $script:ProxyTask -RequiredBinary $script:BinPath
    Write-Log "CLIProxyAPI started at http://127.0.0.1:$($script:ProxyPort)."
}

function Stop-Proxy {
    Stop-ManagedTask -TaskName $script:ProxyTask
    Write-Log 'CLIProxyAPI stopped.'
}

function Start-Keeper {
    Start-ManagedTask -TaskName $script:KeeperTask -RequiredBinary $script:KeeperBinPath
    Write-Log "cpa-usage-keeper started at http://127.0.0.1:$($script:KeeperPort)."
}

function Stop-Keeper {
    Stop-ManagedTask -TaskName $script:KeeperTask
    Write-Log 'cpa-usage-keeper stopped.'
}

function Restart-Proxy {
    $keeperWasRunning = Test-TaskRunning -TaskName $script:KeeperTask
    if ($keeperWasRunning) { Stop-Keeper }
    Stop-Proxy
    Start-Proxy
    if ($keeperWasRunning) { Start-Keeper }
}

function Restart-Keeper {
    Stop-Keeper
    Start-Keeper
}

function Show-TaskStatus {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return 'not installed' }
    return [string]$task.State
}

# Best-effort LAN address of this machine, for the post-install hint only.
function Get-LanIpHint {
    try {
        $ip = Get-NetIPConfiguration |
            Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
            Select-Object -First 1 -ExpandProperty IPv4Address |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    }
    catch { }
    return '<this-machine-ip>'
}

# Reads the effective host:port out of config.yaml for status (which runs without
# -Lan/-Port, so the script variables still hold defaults).
function Get-ConfiguredListenSummary {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return 'unknown (no config.yaml)' }
    $content = Get-Content -LiteralPath $script:ConfigPath -Raw
    $bindHost = '127.0.0.1'
    $bindPort = [string]$script:ProxyPort
    $m = [regex]::Match($content, '(?m)^host:\s*"?([^"\s#]+)"?')
    if ($m.Success) { $bindHost = $m.Groups[1].Value }
    $m = [regex]::Match($content, '(?m)^port:\s*(\d+)')
    if ($m.Success) { $bindPort = $m.Groups[1].Value }
    if ($bindHost -eq '0.0.0.0') {
        return "${bindHost}:${bindPort} (LAN - reachable at http://$(Get-LanIpHint):${bindPort})"
    }
    return "${bindHost}:${bindPort} (this machine only)"
}

function Show-Status {
    $architecture = Get-WindowsArchitecture
    Write-Host "Architecture:       $($architecture.Display)"
    Write-Host "Data directory:     $($script:DataDir)"
    Write-Host "Proxy version:      $(Get-LocalVersion -Path $script:VersionFile)"
    Write-Host "Proxy binary:       $(if (Test-Path -LiteralPath $script:BinPath) { 'present' } else { 'MISSING' })"
    Write-Host "Proxy task:         $(Show-TaskStatus -TaskName $script:ProxyTask)"
    Write-Host "Proxy update task:  $(Show-TaskStatus -TaskName $script:ProxyUpdateTask)"
    Write-Host "Config:             $(if (Test-Path -LiteralPath $script:ConfigPath) { $script:ConfigPath } else { 'MISSING' })"
    Write-Host "Listen:             $(Get-ConfiguredListenSummary)"
    Write-Host "Keeper version:     $(Get-LocalVersion -Path $script:KeeperVersionFile)"
    Write-Host "Keeper binary:      $(if (Test-Path -LiteralPath $script:KeeperBinPath) { 'present' } else { 'MISSING' })"
    Write-Host "Keeper task:        $(Show-TaskStatus -TaskName $script:KeeperTask)"
    Write-Host "Keeper update task: $(Show-TaskStatus -TaskName $script:KeeperUpdateTask)"
    Write-Host "Dashboard:          http://127.0.0.1:$($script:KeeperPort)"
}

function Install-All {
    Read-UpdateTime
    Write-Log '=== Installing CLIProxyAPI manager for Windows ==='
    Initialize-Directories
    Install-ManagerCopy
    Save-ManagerSettings
    Ensure-Config
    Ensure-UsageStatisticsEnabled
    Ensure-KeeperEnvironment
    Install-LatestBinary -Kind Proxy | Out-Null
    Install-LatestBinary -Kind Keeper | Out-Null
    Register-ManagerTasks
    Start-Proxy
    Start-Keeper
    if ($script:ProxyHost -eq '0.0.0.0') {
        Write-Log "=== Installation complete. CPA on $($script:ProxyHost):$($script:ProxyPort) (LAN). ==="
        Write-Log "LAN clients: http://$(Get-LanIpHint):$($script:ProxyPort) - they must send the api-key you set."
        Write-Log 'The dashboard stays bound to this machine only.'
        Write-Log "If Windows Firewall blocks it, allow inbound TCP $($script:ProxyPort) for the private network."
    }
    else {
        Write-Log '=== Installation complete. ==='
    }
    Show-Status
}

function Install-Keeper {
    Read-UpdateTime
    Initialize-Directories
    Install-ManagerCopy
    Save-ManagerSettings
    Ensure-Config
    Ensure-UsageStatisticsEnabled
    Ensure-KeeperEnvironment
    Install-LatestBinary -Kind Keeper | Out-Null
    Register-ManagerTasks -KeeperOnly
    Start-Keeper
}

function Invoke-WithUpdateLock {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $mutex = New-Object System.Threading.Mutex($false, 'Local\CLIProxyAPIManagerUpdate')
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
        }
        catch [System.Threading.AbandonedMutexException] {
            # The prior updater terminated unexpectedly; ownership is transferred here.
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Another update is still running after 10 minutes.'
        }
        & $Action
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Update-Proxy {
    Ensure-Config
    $keeperWasRunning = Test-TaskRunning -TaskName $script:KeeperTask
    if ($keeperWasRunning) { Stop-Keeper }
    try {
        $result = Install-LatestBinary -Kind Proxy
        if ($result.Updated -or $result.WasRunning) {
            Start-Proxy
        }
    }
    finally {
        if ($keeperWasRunning) { Start-Keeper }
    }
}

function Update-Keeper {
    Ensure-KeeperEnvironment
    $result = Install-LatestBinary -Kind Keeper
    if ($result.Updated -or $result.WasRunning) {
        Start-Keeper
    }
}

function Uninstall-Manager {
    Write-Log 'Stopping and removing Scheduled Tasks (downloaded files are kept).'
    @($script:ProxyTask, $script:KeeperTask, $script:ProxyUpdateTask, $script:KeeperUpdateTask) |
        ForEach-Object {
            if (Test-TaskExists -TaskName $_) {
                Stop-ManagedTask -TaskName $_
                Unregister-ScheduledTask -TaskName $_ -Confirm:$false
            }
        }
    Write-Log "Uninstalled. Data remains in $($script:DataDir)."
}

function Show-Help {
    @'
Usage:
  .\start-cliproxyapi.ps1 [command] [-GitHubProxy <url>] [-Port <1-65535>]

Commands:
  install          Install/update both apps, register tasks, and start them (default)
                   -Port overrides the default CLIProxyAPI port 8317
                   -Lan binds 0.0.0.0 so the local network can reach the proxy;
                   it requires -ApiKey (>=16 chars of A-Z a-z 0-9 . _ ~ -), since
                   binding 0.0.0.0 also exposes the management API. The
                   cpa-usage-keeper dashboard stays bound to 127.0.0.1.
  update           Update CLIProxyAPI and restart it only when needed
  start|stop       Start or stop CLIProxyAPI
  restart|status   Restart CLIProxyAPI or show status for both apps
  uninstall        Remove Scheduled Tasks; keep binaries, config, and data
  keeper-install   Install/update and start cpa-usage-keeper
  keeper-update    Update cpa-usage-keeper and restart it only when needed
  keeper-start     Start cpa-usage-keeper
  keeper-stop      Stop cpa-usage-keeper
  keeper-restart   Restart cpa-usage-keeper

Proxy examples:
  .\start-cliproxyapi.ps1 install -GitHubProxy http://127.0.0.1:1080
  .\start-cliproxyapi.ps1 install -GitHubProxy ""   # direct connection

LAN example:
  .\start-cliproxyapi.ps1 install -Lan -ApiKey ([guid]::NewGuid().ToString('N'))
'@ | Write-Host
}

switch ($Command) {
    'install'        { Invoke-WithUpdateLock -Action { Install-All } }
    'update'         { Invoke-WithUpdateLock -Action { Update-Proxy } }
    'start'          { Start-Proxy }
    'stop'           { Stop-Proxy }
    'restart'        { Restart-Proxy }
    'status'         { Show-Status }
    'uninstall'      { Uninstall-Manager }
    'keeper-install' { Invoke-WithUpdateLock -Action { Install-Keeper } }
    'keeper-update'  { Invoke-WithUpdateLock -Action { Update-Keeper } }
    'keeper-start'   { Start-Keeper }
    'keeper-stop'    { Stop-Keeper }
    'keeper-restart' { Restart-Keeper }
    'help'           { Show-Help }
}
