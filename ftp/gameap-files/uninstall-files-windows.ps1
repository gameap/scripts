#Requires -Version 5.1

<#
GameAP Files server uninstallation script for Windows.

Removes the Windows service, the firewall rules and the binary. The
configuration, the users.d directory and the SSH host key are kept unless
-Purge is given, so an uninstall/install cycle does not lose the server's users.

The game server data directory is never touched.
#>

param(
    [string]$InstallDir = "C:\gameap\tools\gameap-files",
    [string]$ConfigDir = "",
    [string]$LogDir = "",
    [string]$ServiceName = "gameap-files",
    [switch]$Purge,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# The panel reads this script's output from a daemon task, where a PowerShell
# exception blob is far less useful than the message alone.
trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

$COMPONENT = "gameap-files"
$FIREWALL_RULE_PREFIX = "GameAP_Files"

function Show-Help {
    Write-Host @"
GameAP Files Server uninstallation script for Windows

Usage: powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-files-windows.ps1 [options]

Options:
  -InstallDir DIR    Binary directory (default: C:\gameap\tools\gameap-files)
  -ConfigDir DIR     Configuration directory (default: read back from the
                     installed service, then <InstallDir>\config)
  -LogDir DIR        Service log directory
                     (default: C:\gameap\services\logs\<ServiceName>)
  -ServiceName NAME  Windows service name (default: gameap-files)
  -Purge             Also delete the configuration, users.d and the SSH host key
  -Help              Show this help

Without -Purge the configuration directory is left in place, so reinstalling
keeps the existing users and host key. The game server data directory is never
touched.

Examples:
  ... -File uninstall-files-windows.ps1
  ... -File uninstall-files-windows.ps1 -Purge
"@
}

if ($Help) {
    Show-Help
    exit 0
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

function Remove-FirewallRule {
    param([string]$Name)

    $existing = Invoke-NativeCommand -FilePath "netsh.exe" `
        -Arguments @("advfirewall", "firewall", "show", "rule", "name=$Name") -IgnoreExitCode
    if ($existing.ExitCode -ne 0) {
        return
    }

    # netsh answers "No rules match the specified criteria" with exit 1, which is
    # not worth failing an uninstall over.
    $removed = Invoke-NativeCommand -FilePath "netsh.exe" `
        -Arguments @("advfirewall", "firewall", "delete", "rule", "name=$Name") -IgnoreExitCode
    if ($removed.ExitCode -ne 0) {
        Write-Warning "Could not delete firewall rule $Name (netsh exit $($removed.ExitCode))"
        return
    }

    Write-Host "  $Name removed"
}

if (-not (Test-Administrator)) {
    [Console]::Error.WriteLine("Administrator privileges are required to remove the service and firewall rules.")
    exit 1
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

# The service command line records where the install actually put things, so an
# installation that used a custom -InstallDir/-ConfigDir can be removed without
# having to repeat those arguments here.
if ($service -and -not $PSBoundParameters.ContainsKey("ConfigDir")) {
    $imagePath = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).PathName
    if ($imagePath -match '\s-c\s+"?(.+?\.yaml)"?(\s|$)') {
        $ConfigDir = Split-Path -Parent $Matches[1]
        Write-Host "Configuration directory taken from the service: $ConfigDir"
    }
}

if (-not $ConfigDir) { $ConfigDir = [IO.Path]::Combine($InstallDir, "config") }
if (-not $LogDir) { $LogDir = [IO.Path]::Combine("C:\gameap\services\logs", $ServiceName) }

if ($service) {
    Write-Host "Removing the $ServiceName service..."

    if ($service.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }

    # shawl has no `remove` subcommand; the service is a plain SCM entry.
    # 1060 is "service does not exist" and 1072 "already marked for deletion" -
    # both mean the goal is already met.
    $deleted = Invoke-NativeCommand -FilePath "sc.exe" -Arguments @("delete", $ServiceName) -IgnoreExitCode
    if ($deleted.ExitCode -notin @(0, 1060, 1072)) {
        throw "Failed to delete the $ServiceName service (sc exit $($deleted.ExitCode))"
    }

    # A deleted service lingers in the "marked for deletion" state until every
    # handle to it is closed, and the binary stays locked until then.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
} else {
    Write-Host "Service $ServiceName is not installed, skipping."
}

Write-Host "Removing Windows Firewall rules..."
foreach ($suffix in @("FTP", "FTP_Passive", "FTPS", "SFTP")) {
    Remove-FirewallRule -Name "${FIREWALL_RULE_PREFIX}_${suffix}"
}

$binaryPath = [IO.Path]::Combine($InstallDir, "$COMPONENT.exe")
if (Test-Path -LiteralPath $binaryPath) {
    Write-Host "Removing $binaryPath..."
    Remove-Item -LiteralPath $binaryPath -Force
}

if (Test-Path -LiteralPath $LogDir) {
    Write-Host "Removing $LogDir..."
    Remove-Item -LiteralPath $LogDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Purge) {
    if (Test-Path -LiteralPath $ConfigDir) {
        Write-Warning "-Purge also deletes the SFTP host key: every SFTP client will report a changed host key after a reinstall, and all users.d accounts are lost."
        Write-Host "Removing $ConfigDir (-Purge)..."
        Remove-Item -LiteralPath $ConfigDir -Recurse -Force
    }

    # Only remove the install directory once it is empty: a custom -ConfigDir may
    # live elsewhere, and the directory may be shared with other tools.
    if ((Test-Path -LiteralPath $InstallDir) -and
        -not (Get-ChildItem -LiteralPath $InstallDir -Force)) {
        Remove-Item -LiteralPath $InstallDir -Force
    }

    Write-Host ""
    Write-Host "$COMPONENT removed completely."
} else {
    Write-Host ""
    Write-Host "$COMPONENT removed. Configuration kept at $ConfigDir (use -Purge to delete it)."
}

Write-Host "Game server files were not touched, and shawl was left in place - it is shared with gameap-daemon."
