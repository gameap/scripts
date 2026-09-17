# Respawn — node installers

Installers for `gameap-respawn`, the node-side CLI of the GameAP Respawn
(backups) plugin. The plugin runs them on a node as a daemon task chain:

```
rm -f '{node_tools_path}/install-respawn-cli-linux.sh' '{node_work_path}/install-respawn-cli-linux.sh'
get-tool https://raw.githubusercontent.com/gameap/scripts/master/respawn/install-respawn-cli-linux.sh
install-respawn-cli-linux.sh --version=latest
```

```
powershell -NoProfile -NonInteractive -Command "Remove-Item -LiteralPath '{node_tools_path}/install-respawn-cli-windows.ps1' -Force -ErrorAction SilentlyContinue"
get-tool https://raw.githubusercontent.com/gameap/scripts/master/respawn/install-respawn-cli-windows.ps1
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{node_tools_path}/install-respawn-cli-windows.ps1" -ReleaseVersion latest -InstallDir "{node_tools_path}/gameap-respawn"
```

The first task removes the copy an earlier run left behind: `get-tool` resumes
a download onto an existing file instead of replacing it, which splices two
versions of a changed script together.

`get-tool` saves a script into the daemon tools directory (`<work_path>\tools`
on Windows) and puts that directory on the daemon's PATH, which is how the
bare Linux script name resolves. PowerShell resolves `-File` against the task's
working directory (the work path), so the Windows script is addressed through
`{node_tools_path}`, which the daemon expands to its tools directory before it
splits the command.

Both scripts install the CLI and then check that the node can run its backup
engine (`gameap-respawn version --json --verify-engine`). The
scripts also verify the published sha256 sums and resolve `latest` through
`releases.json` on GitHub / cdn.gameap.com / cdn.gameap.ru. The Linux script
supports a rootless daemon (binary next to the script in the tools directory,
state under `${XDG_STATE_HOME:-~/.local/state}/gameap-respawn`); the Windows
script installs into the directory it is given (`-InstallDir`, default
`C:\gameap\tools\gameap-respawn`) and needs write access there rather than
administrator rights.

`--check` / `-Check` reports the installed CLI and engine versions without
changing anything.

Manual test against a local mirror:

```
./install-respawn-cli-linux.sh --version=latest --download-base=file:///path/to/mirror
```

where the mirror holds `gameap-respawn/releases.json` and
`gameap-respawn/<tag>/gameap-respawn-<tag>-linux-<arch>[.sha256]`.
