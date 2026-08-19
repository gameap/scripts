# Respawn — node installers

Installers for `gameap-respawn`, the node-side CLI of the GameAP Respawn
(backups) plugin. The plugin runs them on a node as a daemon task chain:

```
get-tool https://raw.githubusercontent.com/gameap/scripts/master/respawn/install-respawn-cli-linux.sh
install-respawn-cli-linux.sh --version=latest --with-engine
```

```
get-tool https://raw.githubusercontent.com/gameap/scripts/master/respawn/install-respawn-cli-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File install-respawn-cli-windows.ps1 -WithEngine
```

Both scripts install only the CLI. The backup engine (restic) is fetched by
the CLI (`gameap-respawn install-engine`): the release assets are bzip2/zip archives
and a minimal node has neither unpacker, while Go's standard library does. The
scripts also verify the published sha256 sums, resolve `latest` through
`releases.json` on GitHub / cdn.gameap.com / cdn.gameap.ru, and support a
rootless daemon (binary next to the script in the tools directory, state under
`${XDG_STATE_HOME:-~/.local/state}/gameap-respawn`).

`--check` / `-Check` reports the installed CLI and engine versions without
changing anything. (`--with-restic` / `-WithRestic` are still accepted as
aliases of `--with-engine` / `-WithEngine`.)

Manual test against a local mirror:

```
./install-respawn-cli-linux.sh --version=latest --download-base=file:///path/to/mirror --with-engine
```

where the mirror holds `gameap-respawn/releases.json` and
`gameap-respawn/<tag>/gameap-respawn-<tag>-linux-<arch>[.sha256]`.
