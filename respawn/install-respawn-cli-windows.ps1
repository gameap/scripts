#Requires -Version 5.1

<#
GameAP Respawn CLI installation script for Windows.

Resolves the requested release, downloads the gameap-respawn binary and, with
-WithEngine, lets the CLI fetch its backup engine (restic). The engine is
downloaded by the CLI, not by this script: it knows the release layout,
verifies the published checksums and unpacks the zip archive without any
extra tools.

Releases are looked up in three sources - GitHub (canonical) plus the
cdn.gameap.com / cdn.gameap.ru mirrors, which publish the verbatim GitHub
releases payload as <mirror>/gameap-respawn/releases.json. Without -ReleaseVersion
the newest stable release is installed.

Invoked by the panel's Respawn plugin as a daemon task chain:
  get-tool .../respawn/install-respawn-cli-windows.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File install-respawn-cli-windows.ps1 -WithEngine
#>

param(
    [string]$ReleaseVersion = "",
    [switch]$ListVersions,
    [switch]$AllowPrerelease,
    [switch]$SkipChecksum,
    [switch]$RequireChecksum,
    [string]$DownloadBase = "",

    [string]$InstallDir = "C:\gameap\tools\gameap-respawn",
    [string]$StateDir = "",
    [Alias("WithRestic")]
    [switch]$WithEngine,
    [Alias("ResticVersion")]
    [string]$EngineVersion = "",
    [switch]$Check,
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

$COMPONENT = "gameap-respawn"
$GITHUB_REPO = "gameap/gameap-respawn"

function Show-Help {
    Write-Host @"
GameAP Respawn CLI installation script for Windows

Usage: powershell -NoProfile -ExecutionPolicy Bypass -File install-respawn-cli-windows.ps1 [options]

Release options:
  -ReleaseVersion VERSION   Release to install: 'latest' (default), or a version
                            with or without the v prefix (0.1.1, v0.1.1)
  -ListVersions             Print the available releases and exit
  -AllowPrerelease          Consider prereleases when resolving 'latest'
  -SkipChecksum             Do not verify the published sha256 sum
  -RequireChecksum          Fail instead of warning when the sha256 sum cannot
                            be checked
  -DownloadBase URL         Use a single custom mirror instead of the default
                            GitHub/CDN sources; expects URL/$COMPONENT/releases.json
                            and URL/$COMPONENT/TAG/$COMPONENT-TAG-windows-ARCH.exe

Installation options:
  -InstallDir DIR           Binary directory (default: C:\gameap\tools\gameap-respawn)
  -StateDir DIR             State directory (default: %ProgramData%\GameAP\gameap-respawn;
                            a custom value must also reach the daemon as
                            GAMEAP_RESPAWN_STATE_DIR or the CLI will not find it)
  -WithEngine               After installing the CLI, run '$COMPONENT install-engine'
                            so the node is ready to back up
  -EngineVersion VERSION    engine version for -WithEngine (default: the one the
                            CLI was tested against)
  -Check                    Report the installed CLI and engine versions and exit
                            without changing anything (exit 1 when unhealthy)
  -Help                     Show this help

Re-running the script upgrades the binary in place; the state directory and
the repository credentials in it are never touched.
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
            $request.UserAgent = "gameap-respawn-installer"
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
                -Headers @{ "User-Agent" = "gameap-respawn-installer" }
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
# Main

$binaryPath = [IO.Path]::Combine($InstallDir, "$COMPONENT.exe")

if ($StateDir) {
    $env:GAMEAP_RESPAWN_STATE_DIR = $StateDir
}

# -Check: the panel uses this to see what a node has without reinstalling.
if ($Check) {
    $cli = $null
    if (Test-Path -LiteralPath $binaryPath -PathType Leaf) {
        $cli = $binaryPath
    } else {
        $found = Get-Command "$COMPONENT.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $cli = $found.Source }
    }

    if (-not $cli) {
        Exit-WithError "$COMPONENT is not installed"
    }

    $probe = Invoke-NativeCommand -FilePath $cli -Arguments @("version", "--json") -IgnoreExitCode
    $text = ($probe.Output | Out-String)
    Write-Host $text.TrimEnd()

    if ($text -match '"supported":true') {
        exit 0
    }

    Exit-WithError "the backup engine is missing or too old; run: $cli install-engine"
}

$arch = $null
if (-not $ListVersions) {
    $arch = Get-Architecture
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

$tempFile = [IO.Path]::GetTempFileName()
try {
    Write-Host "Downloading $COMPONENT $tag (windows-$arch)..."
    Save-Binary -Sources $sources -Tag $tag -Asset $asset -Destination $tempFile

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -LiteralPath $tempFile -Destination $binaryPath -Force
} finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Verifying installation..."
$verify = Invoke-NativeCommand -FilePath $binaryPath -Arguments @("version", "--json") -ErrorMessage "$COMPONENT does not run on this node"
Write-Host (($verify.Output | Out-String).TrimEnd())

Write-Host "$COMPONENT $tag installed to $binaryPath"

if ($WithEngine) {
    Write-Host "Installing the backup engine through $COMPONENT..."

    $arguments = @("install-engine", "--json")
    if ($EngineVersion) {
        $arguments += "--engine-version=$EngineVersion"
    }

    $install = Invoke-NativeCommand -FilePath $binaryPath -Arguments $arguments -IgnoreExitCode
    $text = ($install.Output | Out-String)
    Write-Host $text.TrimEnd()

    if ($text -notmatch '"code":"OK"') {
        Exit-WithError "engine installation failed; the CLI is installed, run '$binaryPath install-engine' to retry"
    }
}
