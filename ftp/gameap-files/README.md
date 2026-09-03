Installation scripts for the [GameAP Files](https://github.com/gameap/gameap-files) server —
an FTP/FTPS/SFTP server for game server files, managed by the panel's Files plugin.

| Script | Platform |
|---|---|
| `install-files-linux.sh` | Linux, systemd (root or rootless) |
| `install-files-windows.ps1` | Windows, [shawl](https://github.com/mtkennerly/shawl) service wrapper |
| `uninstall-files-windows.ps1` | Windows |

Both installers resolve the release from GitHub or the `cdn.gameap.com` / `cdn.gameap.ru`
mirrors — whichever answers fastest — and verify the published sha256 sum before installing.
Without a version argument the newest stable release is installed.

Re-running an installer upgrades the binary and the service. An existing `users.d` directory
and SSH host key are never touched, and the configuration is only rewritten when explicitly
asked for (`--force` / `-Force`, the previous file is kept as `config.yaml.bak`), so no server
data is lost.

## Where the configuration lives

The configuration is kept **inside the data directory**, in `<data-dir>/.plugins/files/`
(`config.yaml`, `users.d/`, `ssh/`, `tls/`). That is the service directory the panel keeps for
its Files plugin on every node, and the only place the panel can write to: gameap-daemon
confines plugin file operations to the node work path, which is the data directory. The server
itself keeps the directory out of every FTP/SFTP client's reach.

### Migration from an earlier layout

Earlier releases kept the configuration in `/etc/gameap-files` (Linux) or in `config\` beside
the binary (Windows). On the first run against such a node the installer moves it: `users.d`,
`ssh` and `tls` are copied with their permissions, the paths inside `config.yaml` are rewritten,
the result is validated, the moved files are removed from the old location and the service is
re-registered against the new file. The installer passes the old directory to
`gameap-files migrate`; run it with `--dry-run` yourself to preview.

Nothing is migrated once `<data-dir>/.plugins/files/config.yaml` exists, so re-running is
harmless. `--legacy-config-dir` / `-LegacyConfigDir` point the installer at a non-default old
location. A rootless run cannot read a root-owned `/etc/gameap-files`; it says so, writes a
fresh configuration, and prints the commands to migrate as root afterwards.

## Linux

```bash
./install-files-linux.sh --data-dir=/srv/gameap
```

| | as root | as any other user (rootless gameap-daemon) |
|---|---|---|
| binary | `/usr/local/bin/gameap-files` | next to the script, i.e. the daemon tools directory `<data-dir>/tools/` (on the daemon `PATH`); `~/.local/bin` when that is not writable |
| configuration | `<data-dir>/.plugins/files/` | `<data-dir>/.plugins/files/` |
| unit | `/etc/systemd/system/gameap-files.service`, `systemctl` | `~/.config/systemd/user/gameap-files.service`, `systemctl --user` |
| runs as | root | the installing user |

The mode follows the uid; `--install-dir` and `--config-dir` override the defaults.

### Rootless prerequisites

- A reachable systemd user manager: run the installer from a real session (ssh, not `su` or
  `sudo -u`), or enable lingering once as root with `sudo loginctl enable-linger <user>`. The
  installer sets `XDG_RUNTIME_DIR` to `/run/user/<uid>` when it is unset and stops with an
  explanation when `systemctl --user` cannot be reached.
- Lingering, so the service survives logout and starts at boot. The installer warns when it
  is off.
- Listen ports of 1024 or higher: `--ftp-listen-address=:2121 --sftp-listen-address=:2222`.
  The installer refuses privileged ports before downloading anything; it honours
  `net.ipv4.ip_unprivileged_port_start`, and `--skip-port-check` is for binaries that carry
  `CAP_NET_BIND_SERVICE` (`setcap` has to be repeated after every upgrade).
- A writable data directory. The panel writes user files as the daemon user, which is the
  same user, so nothing else is needed.

An earlier root install is not converted: its system unit keeps the ports and
`/etc/gameap-files`. Stop it as root (`systemctl disable --now gameap-files`), migrate as root,
`chown` the result to the daemon user, then run the installer as that user.

### Checking a node

```bash
./install-files-linux.sh --data-dir=/srv/gameap --check
```

Prints the installed version, mode, binary, configuration and users directory, unit state and
whether a migration is pending, without changing anything (exit 1 when nothing is installed).

Run `./install-files-linux.sh --help` for the full option list, or `--list-versions` to see the
available releases.

## Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-files-windows.ps1 -DataDir C:\gameap
```

Requires an elevated session. Installs the binary to `C:\gameap\tools\gameap-files`, the
configuration to `<DataDir>\.plugins\files`, and service logs to
`C:\gameap\services\logs\gameap-files`. Use `-InstallDir` and `-ConfigDir` to place them
elsewhere. `-Check` reports the installed version, paths and service state without changing
anything.

The installer also opens the FTP, passive, SFTP and — with `-FtpTlsEnabled` — implicit FTPS
ports in Windows Firewall. Pass `-SkipFirewall` to leave the firewall alone.

With `-FtpTlsEnabled` the server expects a certificate and a private key at
`<ConfigDir>\tls\server.crt` and `<ConfigDir>\tls\server.key`. Place them there beforehand or
pass `-FtpTlsCertFile` and `-FtpTlsKeyFile` and the installer copies them in; if either file is
missing, the installer stops before writing a TLS-enabled configuration.

Run with `-Help` for the full option list, or `-ListVersions` for the available releases.

### shawl is a prerequisite

`gameap-files` does not implement the Windows service control protocol, so the service is a
[shawl](https://github.com/mtkennerly/shawl) wrapper — the same process manager gameap-daemon
uses. gameapctl installs shawl at `C:\gameap\tools\shawl\shawl.exe`; the installer looks there
and on `PATH`, and stops with an explanation if it finds neither. Point it at another copy with
`-ShawlPath`.

The service runs as `NT AUTHORITY\NETWORK SERVICE`, which is granted read access to the
installation and the configuration directory and modify access to the data and log
directories. The read grant is inheritable, so user files the daemon writes later stay
readable for the service.

### Uninstalling

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-files-windows.ps1
```

Removes the service, the firewall rules, the binary and the logs. The configuration, `users.d`
and the SSH host key are kept unless `-Purge` is given, which removes `<DataDir>\.plugins\files`
and nothing else. Game server files are never touched, and shawl is left in place because
gameap-daemon shares it.
