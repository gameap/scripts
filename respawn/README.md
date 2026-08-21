# Respawn — node installers

Installers for `gameap-respawn`, the node-side CLI of the GameAP Respawn
(backups) plugin. The plugin runs them on a node as a daemon task chain:

```
get-tool https://raw.githubusercontent.com/gameap/scripts/master/respawn/install-respawn-cli-linux.sh
install-respawn-cli-linux.sh --version=latest
```

```
get-tool https://raw.githubusercontent.com/gameap/scripts/master/respawn/install-respawn-cli-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File install-respawn-cli-windows.ps1
```

Both scripts install the CLI and then check that the node can run its backup
engine (`gameap-respawn version --json --verify-engine`). The
scripts also verify the published sha256 sums, resolve `latest` through
`releases.json` on GitHub / cdn.gameap.com / cdn.gameap.ru, and support a
rootless daemon (binary next to the script in the tools directory, state under
`${XDG_STATE_HOME:-~/.local/state}/gameap-respawn`).

`--check` / `-Check` reports the installed CLI and engine versions without
changing anything.

Manual test against a local mirror:

```
./install-respawn-cli-linux.sh --version=latest --download-base=file:///path/to/mirror
```

where the mirror holds `gameap-respawn/releases.json` and
`gameap-respawn/<tag>/gameap-respawn-<tag>-linux-<arch>[.sha256]`.
