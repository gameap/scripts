#Requires -Version 5.1

<#
GameAP Files server installation script for Windows.

Resolves the requested release, downloads the gameap-files binary, writes the
configuration and registers the Windows service.

Releases are looked up in three sources - GitHub (canonical) plus the
cdn.gameap.com / cdn.gameap.ru mirrors, which publish the verbatim GitHub
releases payload as <mirror>/gameap-files/releases.json. Without -ReleaseVersion
the newest stable release is installed.

Windows has no systemd equivalent and the binary does not implement the Windows
service control protocol, so the service is a shawl wrapper - the same process
manager gameap-daemon and gameapctl already use. shawl is expected to be present
(gameapctl installs it to C:\gameap\tools\shawl); this script does not fetch it.

Invoked by the panel's Files plugin as a daemon task chain:
  get-tool .../ftp/gameap-files/install-files-windows.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File install-files-windows.ps1 -DataDir C:\gameap\servers
#>

param(
    [string]$DataDir = "",

    [string]$FtpListenAddress = ":21",
    [int]$FtpPassivePortMin = 30000,
    [int]$FtpPassivePortMax = 30100,
    [string]$FtpPublicHost = "",
    [switch]$FtpTlsEnabled,
    [string]$FtpTlsImplicitPort = ":990",
    [string]$SftpListenAddress = ":2222",

    [string]$ReleaseVersion = "",
    [switch]$ListVersions,
    [switch]$AllowPrerelease,
    [switch]$SkipChecksum,
    [switch]$RequireChecksum,
    [string]$DownloadBase = "",

    [string]$InstallDir = "C:\gameap\tools\gameap-files",
    [string]$ConfigDir = "",
    [string]$LogDir = "",
    [string]$ShawlPath = "",
    [string]$ServiceName = "gameap-files",
    [switch]$SkipFirewall,
    [switch]$FixDataDirAcl,
    [switch]$Force,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
# Invoke-WebRequest renders a progress bar on every chunk, which dominates the
# runtime of a download on Windows PowerShell 5.1.
$ProgressPreference = "SilentlyContinue"

# The panel reads this script's output from a daemon task, where a PowerShell
# exception blob is far less useful than the message alone.
trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

$COMPONENT = "gameap-files"
$GITHUB_REPO = "gameap/gameap-files"
$SHAWL_DEFAULT_PATH = "C:\gameap\tools\shawl\shawl.exe"
$FIREWALL_RULE_PREFIX = "GameAP_Files"

function Show-Help {
    Write-Host @"
GameAP Files Server installation script for Windows

Usage: powershell -NoProfile -ExecutionPolicy Bypass -File install-files-windows.ps1 [options]

Required:
  -DataDir DIR              Data directory for game servers

Server options:
  -FtpListenAddress ADDR    FTP listen address (default: :21)
  -FtpPassivePortMin N      FTP passive port range start (default: 30000)
  -FtpPassivePortMax N      FTP passive port range end (default: 30100)
  -FtpPublicHost HOST       FTP public host for passive mode
  -FtpTlsEnabled            Enable FTP TLS
  -FtpTlsImplicitPort PORT  FTP implicit TLS port (default: :990)
  -SftpListenAddress ADDR   SFTP listen address (default: :2222)

Release options:
  -ReleaseVersion VERSION   Release to install: 'latest' (default), or a version
                            with or without the v prefix (1.0.0, v1.0.0)
  -ListVersions             Print the available releases and exit
  -AllowPrerelease          Consider prereleases when resolving 'latest'
  -SkipChecksum             Do not verify the published sha256 sum
  -RequireChecksum          Fail instead of warning when the sha256 sum cannot be
                            checked (missing sidecar, no hashing tool)
  -DownloadBase URL         Use a single custom mirror instead of the default
                            GitHub/CDN sources; expects URL/$COMPONENT/releases.json
                            and URL/$COMPONENT/TAG/$COMPONENT-TAG-windows-ARCH.exe

Installation options:
  -InstallDir DIR           Binary directory (default: C:\gameap\tools\gameap-files)
  -ConfigDir DIR            Configuration directory (default: <InstallDir>\config)
  -LogDir DIR               Service log directory
                            (default: C:\gameap\services\logs\<ServiceName>)
  -ShawlPath PATH           shawl.exe to wrap the service with
                            (default: $SHAWL_DEFAULT_PATH, then PATH)
  -ServiceName NAME         Windows service name (default: gameap-files)
  -SkipFirewall             Do not create Windows Firewall rules
  -FixDataDirAcl            Apply the data directory ACL to every existing file
                            as well, not just to the directory itself (slow on a
                            large data directory; only needed when inheritance
                            has been broken)
  -Force                    Regenerate config.yaml even if it already exists
                            (the previous file is kept as config.yaml.bak)
  -Help                     Show this help

An existing users.d directory and SSH host key are never touched, and config.yaml
is only rewritten with -Force, so re-running the script upgrades the binary and
the service without losing the server's data.

Examples:
  ... -File install-files-windows.ps1 -DataDir C:\gameap\servers
  ... -File install-files-windows.ps1 -DataDir C:\gameap\servers -FtpListenAddress 0.0.0.0:21
  ... -File install-files-windows.ps1 -DataDir C:\gameap\servers -FtpTlsEnabled -FtpPublicHost example.com
"@
}

if ($Help) {
    Show-Help
    exit 0
}

if ($SkipChecksum -and $RequireChecksum) {
    [Console]::Error.WriteLine("-SkipChecksum and -RequireChecksum are mutually exclusive")
    exit 1
}

# Windows PowerShell 5.1 negotiates SSL3/TLS 1.0 by default, which GitHub and the
# CDN both refuse. 3072 is Tls12 as a literal: on .NET 4.0-era systems the named
# enum member does not exist and referencing it fails to parse. -bor keeps
# whatever the administrator has already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch {
    Write-Warning "Could not enable TLS 1.2; downloads from GitHub will most likely fail."
}

function Exit-WithError {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
    exit 1
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Native executables do not raise PowerShell errors, so $ErrorActionPreference
# never sees them - every external call has to be checked explicitly.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$ErrorMessage,
        [switch]$IgnoreExitCode
    )

    # Under `$ErrorActionPreference = "Stop"` a native command that merely writes
    # to stderr raises a terminating error as soon as 2>&1 wraps the line in an
    # ErrorRecord - before the exit code can be looked at. Relaxing the
    # preference for the call keeps the exit code the only thing that decides.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
        if ($output) {
            Write-Host ($output | Out-String).TrimEnd()
        }
        $message = if ($ErrorMessage) { $ErrorMessage } else { "$FilePath failed" }
        throw "${message} (exit code ${exitCode})"
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-Architecture {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        "x86" {
            # A 32-bit PowerShell on a 64-bit host reports x86; the host
            # architecture is what the binary has to match.
            if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") { return "amd64" }
            if ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64") { return "arm64" }
        }
    }

    throw "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE). Only amd64 and arm64 are published."
}

function Resolve-ShawlPath {
    param([string]$Preferred)

    foreach ($candidate in @($Preferred, $SHAWL_DEFAULT_PATH)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $found = Get-Command "shawl.exe" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) {
        return $found.Source
    }

    throw @"
shawl.exe not found.

gameap-files has no built-in Windows service support, so the service is a shawl
wrapper. shawl ships with gameap-daemon: install the daemon with gameapctl, or
pass an existing binary with -ShawlPath.

Looked in: $SHAWL_DEFAULT_PATH and PATH.
"@
}

# ---------------------------------------------------------------------------
# Release sources
#
# Every source answers two things: the release metadata (used to resolve a tag)
# and the binary itself. GitHub is canonical; the CDN mirrors publish the same
# metadata as a static releases.json so installs keep working where GitHub is
# slow, blocked or rate-limited.

function Get-Sources {
    if ($DownloadBase) {
        $base = $DownloadBase.TrimEnd("/")
        return @(
            [pscustomobject]@{
                Name    = ([Uri]$base).Host
                Kind    = "cdn"
                Base    = $base
                MetaUrl = "$base/$COMPONENT/releases.json"
            }
        )
    }

    $sources = @(
        [pscustomobject]@{
            Name    = "github.com"
            Kind    = "github"
            Base    = "https://github.com"
            MetaUrl = "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=100"
        }
    )

    foreach ($cdn in @("https://cdn.gameap.com", "https://cdn.gameap.ru")) {
        $sources += [pscustomobject]@{
            Name    = ([Uri]$cdn).Host
            Kind    = "cdn"
            Base    = $cdn
            MetaUrl = "$cdn/$COMPONENT/releases.json"
        }
    }

    return $sources
}

function Get-AssetUrl {
    param([pscustomobject]$Source, [string]$Tag, [string]$Asset)

    if ($Source.Kind -eq "github") {
        return "https://github.com/$GITHUB_REPO/releases/download/$Tag/$Asset"
    }

    return "$($Source.Base)/$COMPONENT/$Tag/$Asset"
}

# Probe every source's metadata URL in parallel and return the sources ordered
# fastest first. The metadata URL is probed rather than the binary URL because it
# always exists - probing a versioned binary reports "no response" for every
# mirror whenever the version itself is wrong, which hides the real error.
# Sources that fail the probe are appended at the end instead of being dropped:
# a HEAD failure does not always mean a GET would fail.
#
# HTTP probing is used instead of ICMP ping on purpose: ICMP is often filtered,
# and ICMP reachability does not imply HTTPS reachability - which is exactly why
# the mirrors exist.
function Get-OrderedSources {
    param([pscustomobject[]]$Sources)

    if ($Sources.Count -le 1) {
        return $Sources
    }

    Write-Host "Choosing the fastest $COMPONENT release source..."

    $probe = {
        param($url)

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $request = [Net.WebRequest]::Create($url)
            $request.Method = "HEAD"
            $request.Timeout = 10000
            $request.UserAgent = "gameap-files-installer"
            $response = $request.GetResponse()
            $response.Close()
            $watch.Stop()
            return $watch.Elapsed.TotalSeconds
        } catch {
            return $null
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $Sources.Count)
    $pool.Open()

    $running = @()
    foreach ($source in $Sources) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool
        [void]$shell.AddScript($probe).AddArgument($source.MetaUrl)
        $running += [pscustomobject]@{
            Source = $source
            Shell  = $shell
            Handle = $shell.BeginInvoke()
        }
    }

    $measured = @()
    foreach ($item in $running) {
        $latency = $null
        try {
            $latency = $item.Shell.EndInvoke($item.Handle) | Select-Object -First 1
        } catch {
            $latency = $null
        }
        $item.Shell.Dispose()

        $measured += [pscustomobject]@{ Source = $item.Source; Latency = $latency }
    }

    $pool.Close()
    $pool.Dispose()

    $reachable = @($measured | Where-Object { $null -ne $_.Latency } | Sort-Object Latency)
    $unreachable = @($measured | Where-Object { $null -eq $_.Latency })

    if ($reachable.Count -eq 0) {
        Write-Host "No source answered the probe, they will be tried in the default order."
        return $Sources
    }

    $ordered = @()
    foreach ($item in $reachable) {
        Write-Host ("  {0}: {1:N3}s" -f $item.Source.Name, $item.Latency)
        $ordered += $item.Source
    }
    foreach ($item in $unreachable) {
        Write-Host "  $($item.Source.Name): no response, kept as a fallback"
        $ordered += $item.Source
    }

    return $ordered
}

# ---------------------------------------------------------------------------
# Release metadata
#
# Both GitHub and the mirrors serve the same payload: the verbatim
# `GET /repos/<repo>/releases?per_page=100` array, newest release first, with
# drafts and prereleases included. One parser therefore covers all sources.

# Invoke-WebRequest returns .Content as a byte array whenever the response is not
# typed as text, which is how GitHub and S3 serve release assets - and, depending
# on how it was uploaded, sometimes releases.json too.
function ConvertTo-Text {
    param($Content)

    if ($Content -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString($Content)
    }

    return [string]$Content
}

function Get-ReleaseMetadata {
    param([pscustomobject[]]$Sources)

    foreach ($source in $Sources) {
        try {
            $response = Invoke-WebRequest -Uri $source.MetaUrl -UseBasicParsing -TimeoutSec 30 `
                -Headers @{ "User-Agent" = "gameap-files-installer" }
            $releases = (ConvertTo-Text $response.Content) | ConvertFrom-Json
            if ($releases) {
                return [pscustomobject]@{ Releases = @($releases); Source = $source }
            }
        } catch {
            Write-Warning "Could not read releases from $($source.Name), trying the next source..."
        }
    }

    return $null
}

function Get-LatestTag {
    param([object[]]$Releases)

    foreach ($release in $Releases) {
        if ($release.draft) { continue }
        if ($release.prerelease -and -not $AllowPrerelease) { continue }
        return $release.tag_name
    }

    return $null
}

# Accepts a requested version with or without the v prefix.
function Resolve-Tag {
    param([object[]]$Releases, [string]$Wanted)

    foreach ($release in $Releases) {
        if ($release.tag_name -eq $Wanted -or $release.tag_name -eq "v$Wanted") {
            return $release.tag_name
        }
    }

    return $null
}

function Show-Versions {
    param([object[]]$Releases)

    foreach ($release in $Releases) {
        $note = ""
        if ($release.draft) { $note = "  (draft)" }
        elseif ($release.prerelease) { $note = "  (prerelease)" }
        Write-Host "  $($release.tag_name)$note"
    }
}

function Test-AssetPublished {
    param([object[]]$Releases, [string]$Tag, [string]$Asset)

    foreach ($release in $Releases) {
        if ($release.tag_name -ne $Tag) { continue }
        foreach ($published in $release.assets) {
            if ($published.name -eq $Asset) { return $true }
        }
        return $false
    }

    return $false
}

# ---------------------------------------------------------------------------
# Download

# Not being able to check a sum is tolerated by default - releases predating the
# checksums should still install - but -RequireChecksum turns every such case
# into a rejected download, so the caller moves on to the next source.
function Confirm-ChecksumUnavailable {
    param([string]$Reason)

    if ($RequireChecksum) {
        Write-Warning "Checksum required but $Reason"
        return $false
    }

    Write-Warning "$Reason, skipping verification"
    return $true
}

# Verify the download against the .sha256 published next to it. A mismatch always
# fails, so the caller moves on to the next source.
function Test-Checksum {
    param([string]$Path, [string]$Url)

    if ($SkipChecksum) {
        return $true
    }

    $raw = $null
    try {
        $raw = ConvertTo-Text (Invoke-WebRequest -Uri "$Url.sha256" -UseBasicParsing -TimeoutSec 30).Content
    } catch {
        return (Confirm-ChecksumUnavailable "no checksum published for this build")
    }

    # The sidecar holds `<sum>  <file name>`, sometimes with CRLF line endings.
    $firstLine = $raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1
    $expected = if ($firstLine) { ($firstLine.Trim() -split "\s+")[0] } else { $null }

    if (-not $expected) {
        return (Confirm-ChecksumUnavailable "the published checksum is empty")
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash

    # Get-FileHash returns upper case and sha256sum publishes lower case; -ne is
    # case-insensitive for strings, which is what makes this comparison correct.
    if ($expected -ne $actual) {
        Write-Warning "Checksum mismatch: expected $expected, got $actual"
        return $false
    }

    Write-Host "Checksum verified."
    return $true
}

function Save-Binary {
    param([pscustomobject[]]$Sources, [string]$Tag, [string]$Asset, [string]$Destination)

    $tried = @()

    foreach ($source in $Sources) {
        $url = Get-AssetUrl -Source $source -Tag $Tag -Asset $Asset
        $tried += $url

        Write-Host "Downloading from $($source.Name)..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 600
        } catch {
            Write-Warning "Failed to download from $url, trying the next source..."
            continue
        }

        if (-not (Test-Checksum -Path $Destination -Url $url)) {
            Write-Warning "Discarding the download from $($source.Name), trying the next source..."
            continue
        }

        return
    }

    throw ("Failed to download ${COMPONENT}. URLs tried:`n" + (($tried | ForEach-Object { "  - $_" }) -join "`n"))
}

# ---------------------------------------------------------------------------
# Configuration

# YAML double-quoted scalars treat a backslash as an escape character, so a
# Windows path has to be written with forward slashes. The Go side resolves both
# forms identically.
function ConvertTo-YamlPath {
    param([string]$Path)

    return ($Path -replace "\\", "/")
}

function New-ConfigFile {
    param([string]$Path)

    $tlsEnabled = if ($FtpTlsEnabled) { "true" } else { "false" }

    # virtual_paths are deliberately absent: gameap-files validates them with
    # filepath.IsAbs, which rejects "/name" on Windows and would make the whole
    # user file fail to load.
    $content = @"
server:
  name: "GameAP Files Server"
  data_dir: "$(ConvertTo-YamlPath $DataDir)"

ftp:
  enabled: true
  listen_addr: "$FtpListenAddress"
  passive_port_min: $FtpPassivePortMin
  passive_port_max: $FtpPassivePortMax
  public_host: "$FtpPublicHost"
  idle_timeout: 300
  tls:
    enabled: $tlsEnabled
    cert_file: "$(ConvertTo-YamlPath ([IO.Path]::Combine($ConfigDir, 'tls\server.crt')))"
    key_file: "$(ConvertTo-YamlPath ([IO.Path]::Combine($ConfigDir, 'tls\server.key')))"
    implicit_port: "$FtpTlsImplicitPort"
    required: false

sftp:
  enabled: true
  listen_addr: "$SftpListenAddress"
  host_key_file: "$(ConvertTo-YamlPath ([IO.Path]::Combine($ConfigDir, 'ssh\host_ed25519_key')))"
  idle_timeout: 300

security:
  argon2:
    memory: 65536
    iterations: 3
    parallelism: 4
    salt_length: 16
    key_length: 32
  rate_limit:
    max_failures: 5
    window_duration: 15m
    block_duration: 30m

logging:
  level: "info"
  format: "json"
  output: "stdout"
  audit_log: ""

users:
  directory: "$(ConvertTo-YamlPath ([IO.Path]::Combine($ConfigDir, 'users.d')))"
  hot_reload: true
"@

    # Out-File -Encoding UTF8 writes a BOM on Windows PowerShell 5.1.
    [IO.File]::WriteAllText($Path, $content, (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Service account and permissions

# NETWORK SERVICE, as the well-known SID. icacls takes the SID directly with a
# leading '*', which is both locale-independent and what gameapctl already emits
# (pkg/oscore/chown_windows.go).
$NETWORK_SERVICE_SID = "S-1-5-20"

# sc.exe, unlike icacls, rejects a raw SID and needs the account name - which is
# localised, hence the lookup rather than a hardcoded "NT AUTHORITY\...".
function Get-NetworkServiceAccount {
    $sid = New-Object Security.Principal.SecurityIdentifier($NETWORK_SERVICE_SID)
    return $sid.Translate([Security.Principal.NTAccount]).Value
}

function Grant-PathAccess {
    param(
        [string]$Path,
        [ValidateSet("R", "RX", "M")][string]$Permission,
        # Applying an ACL to every existing child is what makes this slow; new
        # children inherit from (OI)(CI) either way.
        [switch]$Recurse,
        [switch]$WarnOnly
    )

    # The grant spec has to be one quoted argument: bare (OI)(CI) would be read
    # as PowerShell grouping.
    $arguments = @($Path, "/grant", "*${NETWORK_SERVICE_SID}:(OI)(CI)$Permission", "/C", "/Q")
    if ($Recurse) { $arguments += "/T" }

    $result = Invoke-NativeCommand -FilePath "icacls.exe" -Arguments $arguments -IgnoreExitCode
    if ($result.ExitCode -ne 0) {
        $message = "Failed to grant $Permission on $Path (icacls exit $($result.ExitCode))"
        if ($WarnOnly) { Write-Warning $message } else { throw $message }
    }
}

# ---------------------------------------------------------------------------
# Firewall

function Get-PortFromAddress {
    param([string]$Address)

    $separator = $Address.LastIndexOf(":")
    if ($separator -lt 0) { return $null }

    $port = $Address.Substring($separator + 1)
    if ($port -match "^\d+$") { return $port }

    return $null
}

function Add-FirewallRule {
    param([string]$Name, [string]$LocalPort, [string]$Source)

    if (-not $LocalPort) {
        Write-Warning "No port could be parsed from '$Source', skipping firewall rule $Name."
        return
    }

    $existing = Invoke-NativeCommand -FilePath "netsh.exe" `
        -Arguments @("advfirewall", "firewall", "show", "rule", "name=$Name") -IgnoreExitCode
    if ($existing.ExitCode -eq 0) {
        Write-Host "  $Name already exists, skipping"
        return
    }

    Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @(
        "advfirewall", "firewall", "add", "rule",
        "name=$Name", "dir=in", "action=allow", "protocol=TCP", "localport=$LocalPort"
    ) -ErrorMessage "Failed to add firewall rule $Name" | Out-Null

    Write-Host "  $Name allowed on TCP $LocalPort"
}

# ---------------------------------------------------------------------------
# Service

function Remove-ExistingService {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return }

    Write-Host "Service $Name already exists, recreating it..."

    if ($service.Status -ne "Stopped") {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }

    Invoke-NativeCommand -FilePath "sc.exe" -Arguments @("delete", $Name) -IgnoreExitCode | Out-Null

    # A deleted service lingers in the "marked for deletion" state until every
    # handle to it is closed, and creating it again in that window fails.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }

    throw "Service $Name is still registered 30s after deletion; reboot and retry."
}

function Install-GameapFilesService {
    param(
        [string]$Name,
        [string]$Shawl,
        [string]$BinaryPath,
        [string]$ConfigPath,
        [string]$WorkingDirectory,
        [string]$ServiceLogDir,
        [string]$Account
    )

    # shawl has no `remove`, and no option for the service account or display
    # name - `add` registers the service, sc.exe adjusts what it cannot set.
    Invoke-NativeCommand -FilePath $Shawl -Arguments @(
        "add",
        "--name", $Name,
        "--restart",
        "--restart-delay", "5000",
        "--stop-timeout", "10000",
        "--cwd", $WorkingDirectory,
        "--log-dir", $ServiceLogDir,
        "--log-as", "$Name.log",
        "--log-rotate", "daily",
        "--log-retain", "7",
        "--",
        $BinaryPath, "serve", "-c", $ConfigPath
    ) -ErrorMessage "Failed to register the $Name service with shawl" | Out-Null

    # sc.exe requires a space after each `=`, which is why the value is a
    # separate argument here.
    Invoke-NativeCommand -FilePath "sc.exe" -Arguments @(
        "config", $Name, "start=", "auto", "obj=", $Account, "DisplayName=", "GameAP Files Server"
    ) -ErrorMessage "Failed to configure the $Name service" | Out-Null

    Invoke-NativeCommand -FilePath "sc.exe" `
        -Arguments @("description", $Name, "GameAP Files FTP/SFTP server") -IgnoreExitCode | Out-Null

    # shawl restarts the wrapped process; this covers shawl itself dying.
    Invoke-NativeCommand -FilePath "sc.exe" -Arguments @(
        "failure", $Name, "reset=", "60", "actions=", "restart/5000/restart/10000/restart/30000"
    ) -IgnoreExitCode | Out-Null
}

# ---------------------------------------------------------------------------
# Main

# Everything that can be rejected without touching the network is checked first,
# so a malformed invocation fails immediately instead of after the mirror probes.
if (-not $ListVersions) {
    if (-not $DataDir) {
        Exit-WithError "-DataDir is required. Use -Help for usage information."
    }

    if (-not (Test-Administrator)) {
        Exit-WithError "Administrator privileges are required to install the service and firewall rules."
    }

    if ($FtpPassivePortMin -gt $FtpPassivePortMax) {
        Exit-WithError "-FtpPassivePortMin ($FtpPassivePortMin) is greater than -FtpPassivePortMax ($FtpPassivePortMax)"
    }
}

# shawl quotes any argument containing a space but does not escape what is inside
# the quotes, so a directory that both contains a space and ends in a separator
# produces `"C:\game files\"` in the service ImagePath - where the trailing
# backslash escapes the closing quote and the service command line is garbage.
$InstallDir = $InstallDir.TrimEnd("\", "/")
if ($ConfigDir) { $ConfigDir = $ConfigDir.TrimEnd("\", "/") }
if ($LogDir) { $LogDir = $LogDir.TrimEnd("\", "/") }
if ($DataDir) { $DataDir = $DataDir.TrimEnd("\", "/") }

if (-not $ConfigDir) { $ConfigDir = [IO.Path]::Combine($InstallDir, "config") }
if (-not $LogDir) { $LogDir = [IO.Path]::Combine("C:\gameap\services\logs", $ServiceName) }

$arch = $null
$shawl = $null
if (-not $ListVersions) {
    $arch = Get-Architecture
    $shawl = Resolve-ShawlPath -Preferred $ShawlPath
    Write-Host "Using shawl at $shawl"
}

$sources = Get-OrderedSources -Sources (Get-Sources)
$metadata = Get-ReleaseMetadata -Sources $sources

if ($ListVersions) {
    if (-not $metadata) {
        Exit-WithError "Failed to read the release list from any source."
    }
    Write-Host "Available $COMPONENT releases (from $($metadata.Source.Name)):"
    Show-Versions -Releases $metadata.Releases
    exit 0
}

$tag = $null
if (-not $ReleaseVersion -or $ReleaseVersion -eq "latest") {
    if (-not $metadata) {
        Exit-WithError @"
Failed to resolve the latest $COMPONENT version. Sources tried:
$((($sources | ForEach-Object { "  - $($_.MetaUrl)" }) -join "`n"))
Pass -ReleaseVersion X.Y.Z to install a specific release without the lookup.
"@
    }

    $tag = Get-LatestTag -Releases $metadata.Releases
    if (-not $tag) {
        Exit-WithError "No suitable release found in the release list from $($metadata.Source.Name). Use -AllowPrerelease if only prereleases are published."
    }
    Write-Host "Latest $COMPONENT release: $tag (via $($metadata.Source.Name))"
} elseif ($metadata) {
    $tag = Resolve-Tag -Releases $metadata.Releases -Wanted $ReleaseVersion
    if (-not $tag) {
        Write-Host "Release '$ReleaseVersion' not found. Available releases:"
        Show-Versions -Releases $metadata.Releases
        Exit-WithError "Release '$ReleaseVersion' not found."
    }
} else {
    # No metadata anywhere: fall back to the tag convention (vX.Y.Z) and let the
    # download surface the failure.
    $tag = if ($ReleaseVersion.StartsWith("v")) { $ReleaseVersion } else { "v$ReleaseVersion" }
    Write-Warning "No release source answered; assuming tag $tag."
}

$asset = "$COMPONENT-$tag-windows-$arch.exe"

if ($metadata -and -not (Test-AssetPublished -Releases $metadata.Releases -Tag $tag -Asset $asset)) {
    Exit-WithError "Release $tag has no windows-$arch build (expected asset $asset)."
}

$binaryPath = [IO.Path]::Combine($InstallDir, "$COMPONENT.exe")
$configPath = [IO.Path]::Combine($ConfigDir, "config.yaml")
$usersDir = [IO.Path]::Combine($ConfigDir, "users.d")
$sshKeyPath = [IO.Path]::Combine($ConfigDir, "ssh\host_ed25519_key")

$tempFile = [IO.Path]::GetTempFileName()
try {
    Write-Host "Downloading $COMPONENT $tag (windows-$arch)..."
    Save-Binary -Sources $sources -Tag $tag -Asset $asset -Destination $tempFile

    foreach ($dir in @($InstallDir, $ConfigDir, $usersDir, ([IO.Path]::Combine($ConfigDir, "ssh")), ([IO.Path]::Combine($ConfigDir, "tls")), $LogDir, $DataDir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    # The binary is locked while the service runs, so it has to go before the copy.
    Remove-ExistingService -Name $ServiceName

    Copy-Item -LiteralPath $tempFile -Destination $binaryPath -Force
} finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $sshKeyPath)) {
    Write-Host "Generating SSH host key..."
    Invoke-NativeCommand -FilePath $binaryPath -Arguments @("genkey", "-t", "ed25519", "-o", $sshKeyPath) `
        -ErrorMessage "Failed to generate the SSH host key" | Out-Null
}

if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
    Write-Host "Configuration already exists at $configPath, keeping it (use -Force to regenerate)."
} else {
    if (Test-Path -LiteralPath $configPath) {
        Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force
        Write-Host "Regenerating configuration, previous file kept as $configPath.bak"
    } else {
        Write-Host "Creating configuration..."
    }
    New-ConfigFile -Path $configPath
}

# Checked before the service exists: a config problem should surface as one
# readable message here, not as a service that starts and dies in a restart loop.
Write-Host "Verifying configuration..."
Invoke-NativeCommand -FilePath $binaryPath -Arguments @("validate", "-c", $configPath) `
    -ErrorMessage "The generated configuration is invalid" | Out-Null

$account = Get-NetworkServiceAccount
Write-Host "Granting $account access to the data and configuration directories..."
# The service only ever reads its own installation; the game server files and the
# service logs are the two places it writes to (it calls MkdirAll on a user's
# home directory at every login).
Grant-PathAccess -Path $InstallDir -Permission "RX" -Recurse
Grant-PathAccess -Path $ConfigDir -Permission "R" -Recurse
Grant-PathAccess -Path $LogDir -Permission "M" -Recurse
# Deliberately not recursive: a data directory can hold millions of game server
# files, and walking all of them would take longer than the panel's task timeout.
# Inheritance covers everything created from here on; -FixDataDirAcl forces the
# full pass when inheritance has been broken.
Grant-PathAccess -Path $DataDir -Permission "M" -Recurse:$FixDataDirAcl -WarnOnly

if ($SkipFirewall) {
    Write-Host "Skipping firewall rules (-SkipFirewall)."
} else {
    Write-Host "Configuring Windows Firewall..."
    Add-FirewallRule -Name "${FIREWALL_RULE_PREFIX}_FTP" `
        -LocalPort (Get-PortFromAddress $FtpListenAddress) -Source $FtpListenAddress
    Add-FirewallRule -Name "${FIREWALL_RULE_PREFIX}_FTP_Passive" `
        -LocalPort "$FtpPassivePortMin-$FtpPassivePortMax" -Source "passive port range"
    Add-FirewallRule -Name "${FIREWALL_RULE_PREFIX}_SFTP" `
        -LocalPort (Get-PortFromAddress $SftpListenAddress) -Source $SftpListenAddress
    if ($FtpTlsEnabled) {
        Add-FirewallRule -Name "${FIREWALL_RULE_PREFIX}_FTPS" `
            -LocalPort (Get-PortFromAddress $FtpTlsImplicitPort) -Source $FtpTlsImplicitPort
    }
}

Write-Host "Installing Windows service..."
Install-GameapFilesService -Name $ServiceName -Shawl $shawl -BinaryPath $binaryPath `
    -ConfigPath $configPath -WorkingDirectory $InstallDir -ServiceLogDir $LogDir -Account $account

Start-Service -Name $ServiceName

# Start-Service returns as soon as the SCM reports shawl running, which says
# nothing about the wrapped process. Give it a moment and look again: a
# gameap-files that fails to bind its ports dies within a second or two.
Start-Sleep -Seconds 3
$service = Get-Service -Name $ServiceName
if ($service.Status -ne "Running") {
    Write-Warning "The $ServiceName service is $($service.Status) shortly after starting."
    Write-Warning "See $LogDir\$ServiceName.log_rCURRENT.log for the reason."
    Write-Warning "A port that is already in use is the usual cause; on Windows also check reserved ranges with: netsh int ipv4 show excludedportrange protocol=tcp"
}

Write-Host ""
Write-Host "$COMPONENT $tag installed successfully."
Write-Host "  binary:  $binaryPath"
Write-Host "  config:  $configPath"
Write-Host "  users:   $usersDir"
Write-Host "  logs:    $LogDir"
Write-Host "  service: $ServiceName ($($service.Status))"
