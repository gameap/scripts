Installation scripts for the [GameAP Files](https://github.com/gameap/gameap-files) server —
an FTP/FTPS/SFTP server for game server files, managed by the panel's Files plugin.

| Script | Platform |
|---|---|
| `install-files-linux.sh` | Linux, systemd |
| `install-files-windows.ps1` | Windows, [shawl](https://github.com/mtkennerly/shawl) service wrapper |
| `uninstall-files-windows.ps1` | Windows |

Both installers resolve the release from GitHub or the `cdn.gameap.com` / `cdn.gameap.ru`
mirrors — whichever answers fastest — and verify the published sha256 sum before installing.
Without a version argument the newest stable release is installed.

Re-running an installer upgrades the binary and the service. An existing `users.d` directory
and SSH host key are never touched, and the configuration is only rewritten when explicitly
asked for, so no server data is lost.

## Linux

```bash
./install-files-linux.sh --data-dir=/srv/gameap
```

Installs `/usr/local/bin/gameap-files`, writes `/etc/gameap-files/config.yaml`, generates the
ed25519 host key and enables the `gameap-files` systemd unit.

Run `./install-files-linux.sh --help` for the full option list, or `--list-versions` to see the
available releases.

## Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-files-windows.ps1 -DataDir C:\gameap\servers
```

Requires an elevated session. Installs to `C:\gameap\tools\gameap-files` with the configuration
in `config\` beside the binary, and service logs in `C:\gameap\services\logs\gameap-files`.
Use `-InstallDir` and `-ConfigDir` to place them elsewhere.

The installer also opens the FTP, passive, SFTP and — with `-FtpTlsEnabled` — implicit FTPS
ports in Windows Firewall. Pass `-SkipFirewall` to leave the firewall alone.

With `-FtpTlsEnabled` the server expects a certificate and a private key at
`config\tls\server.crt` and `config\tls\server.key` (under `-ConfigDir`). Place them there
beforehand or pass `-FtpTlsCertFile` and `-FtpTlsKeyFile` and the installer copies them in;
if either file is missing, the installer stops before writing a TLS-enabled configuration.

Run with `-Help` for the full option list, or `-ListVersions` for the available releases.

### shawl is a prerequisite

`gameap-files` does not implement the Windows service control protocol, so the service is a
[shawl](https://github.com/mtkennerly/shawl) wrapper — the same process manager gameap-daemon
uses. gameapctl installs shawl at `C:\gameap\tools\shawl\shawl.exe`; the installer looks there
and on `PATH`, and stops with an explanation if it finds neither. Point it at another copy with
`-ShawlPath`.

The service runs as `NT AUTHORITY\NETWORK SERVICE`, which is granted read access to the
installation and modify access to the data and log directories.

### Uninstalling

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-files-windows.ps1
```

Removes the service, the firewall rules, the binary and the logs. The configuration, `users.d`
and the SSH host key are kept unless `-Purge` is given. Game server files are never touched,
and shawl is left in place because gameap-daemon shares it.
