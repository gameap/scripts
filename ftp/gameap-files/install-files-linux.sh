#!/bin/bash

# GameAP Files server installation script for Linux.
# Resolves the requested release, downloads the gameap-files binary, writes the
# configuration and installs the systemd unit.
#
# Works as root and as an unprivileged user. As root the binary goes to
# /usr/local/bin and a system unit is installed. As any other user — a rootless
# gameap-daemon — the binary is installed next to this script (the daemon tools
# directory, which gameap-daemon prepends to its PATH) and the service is a
# systemd user unit managed with systemctl --user. The configuration lives in
# <data-dir>/.plugins/files in both modes: gameap-daemon confines the panel's
# Files plugin to the data directory, so that is the only place the panel can
# manage users. A configuration left in /etc/gameap-files by an earlier release
# is migrated on the first run.
#
# Releases are looked up in three sources — GitHub (canonical) plus the
# cdn.gameap.com / cdn.gameap.ru mirrors, which publish the verbatim GitHub
# releases payload as <mirror>/gameap-files/releases.json. Without --version
# the newest stable release is installed.
#
# Invoked by the panel's Files plugin as a daemon task chain:
#   get-tool .../ftp/gameap-files/install-files-linux.sh
#   install-files-linux.sh --data-dir=/srv/gameap

set -e

COMPONENT="gameap-files"
GITHUB_REPO="gameap/gameap-files"
UNIT_NAME="gameap-files"

# Resolved by resolve_layout once the arguments are parsed; see the header.
MODE=""                                # root | rootless
INSTALL_DIR=""                         # --install-dir
CONFIG_DIR=""                          # --config-dir, default <data-dir>/.plugins/files
USERS_DIR=""
LEGACY_CONFIG_DIR="/etc/gameap-files"  # --legacy-config-dir
BINARY=""
UNIT_FILE=""
UNIT_TARGET=""
FORCE=""
CHECK_ONLY=""
SKIP_PORT_CHECK=""

# Empty means "resolve the newest stable release".
GAMEAP_FILES_VERSION=""
ALLOW_PRERELEASE=""
LIST_VERSIONS=""
SKIP_CHECKSUM=""
REQUIRE_CHECKSUM=""
DOWNLOAD_BASE=""

# Default values
DATA_DIR=""
FTP_LISTEN_ADDR=":21"
FTP_PASSIVE_PORT_MIN="30000"
FTP_PASSIVE_PORT_MAX="30100"
FTP_PUBLIC_HOST=""
FTP_TLS_ENABLED="false"
FTP_TLS_IMPLICIT_PORT=":990"
SFTP_LISTEN_ADDR=":2222"

show_help() {
    cat << EOF
GameAP Files Server Installation Script

Usage: $0 [OPTIONS]

Required:
    --data-dir=DIR              Data directory for game servers (the gameap-daemon
                                work path); the configuration is kept inside it

Server options:
    --ftp-listen-address=ADDR   FTP listen address (default: :21)
    --ftp-passive-port-min=N    FTP passive port range start (default: 30000)
    --ftp-passive-port-max=N    FTP passive port range end (default: 30100)
    --ftp-public-host=HOST      FTP public host for passive mode
    --ftp-tls-enabled=BOOL      Enable FTP TLS (default: false)
    --ftp-tls-implicit-port=N   FTP implicit TLS port (default: :990)
    --sftp-listen-address=ADDR  SFTP listen address (default: :2222)

Installation options:
    --install-dir=DIR           Binary directory (default: /usr/local/bin as root,
                                otherwise the directory of this script when it is
                                writable, then ~/.local/bin)
    --config-dir=DIR            Configuration directory
                                (default: <data-dir>/.plugins/files)
    --legacy-config-dir=DIR     Where an earlier release kept its configuration;
                                migrated into --config-dir on the first run
                                (default: /etc/gameap-files)
    --force                     Regenerate config.yaml even if it already exists
                                (the previous file is kept as config.yaml.bak)
    --skip-port-check           Rootless only: accept listen ports below the
                                unprivileged floor (the binary must carry
                                CAP_NET_BIND_SERVICE, which is lost on every upgrade)
    --check                     Report the installed version, mode and paths and
                                exit without changing anything (exit 1 when not
                                installed)

Release options:
    --version=VERSION           Release to install: 'latest' (default), or a
                                version with or without the v prefix (1.0.0, v1.0.0)
    --list-versions             Print the available releases and exit
    --allow-prerelease          Consider prereleases when resolving 'latest'
    --skip-checksum             Do not verify the published sha256 sum
    --require-checksum          Fail instead of warning when the sha256 sum cannot
                                be checked (missing sidecar, no hashing tool)
    --download-base=URL         Use a single custom mirror instead of the default
                                GitHub/CDN sources; expects URL/${COMPONENT}/releases.json
                                and URL/${COMPONENT}/TAG/${COMPONENT}-TAG-OS-ARCH
    --help                      Show this help message

An existing users.d directory and SSH host key are never touched, and
config.yaml is only rewritten with --force, so re-running the script upgrades
the binary and the unit without losing the server's data. A configuration left
in /etc/gameap-files by an earlier release is migrated into the new location on
the first run.

Rootless: as root the binary goes to /usr/local/bin and a system unit is
installed. As any other user (a rootless gameap-daemon) the binary is installed
next to this script, the unit goes to ~/.config/systemd/user and is managed with
systemctl --user; this needs lingering (sudo loginctl enable-linger <user>) and
listen ports of 1024 or higher (for example --ftp-listen-address=:2121).

Examples:
    $0 --data-dir=/srv/gameap
    $0 --data-dir=/srv/gameap --ftp-listen-address=0.0.0.0:21 --sftp-listen-address=0.0.0.0:2222
    $0 --data-dir=/srv/gameap --ftp-tls-enabled=true --ftp-public-host=example.com
    $0 --data-dir=/home/gameap/gameap --ftp-listen-address=:2121   # rootless
    $0 --data-dir=/srv/gameap --check
EOF
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir=*)
            DATA_DIR="${1#*=}"
            ;;
        --ftp-listen-address=*)
            FTP_LISTEN_ADDR="${1#*=}"
            ;;
        --ftp-passive-port-min=*)
            FTP_PASSIVE_PORT_MIN="${1#*=}"
            ;;
        --ftp-passive-port-max=*)
            FTP_PASSIVE_PORT_MAX="${1#*=}"
            ;;
        --ftp-public-host=*)
            FTP_PUBLIC_HOST="${1#*=}"
            ;;
        --ftp-tls-enabled=*)
            FTP_TLS_ENABLED="${1#*=}"
            ;;
        --ftp-tls-implicit-port=*)
            FTP_TLS_IMPLICIT_PORT="${1#*=}"
            ;;
        --sftp-listen-address=*)
            SFTP_LISTEN_ADDR="${1#*=}"
            ;;
        --install-dir=*)
            INSTALL_DIR="${1#*=}"
            ;;
        --config-dir=*)
            CONFIG_DIR="${1#*=}"
            ;;
        --legacy-config-dir=*)
            LEGACY_CONFIG_DIR="${1#*=}"
            ;;
        --force)
            FORCE="1"
            ;;
        --skip-port-check)
            SKIP_PORT_CHECK="1"
            ;;
        --check)
            CHECK_ONLY="1"
            ;;
        --version=*)
            GAMEAP_FILES_VERSION="${1#*=}"
            ;;
        --list-versions)
            LIST_VERSIONS="1"
            ;;
        --allow-prerelease)
            ALLOW_PRERELEASE="1"
            ;;
        --skip-checksum)
            SKIP_CHECKSUM="1"
            ;;
        --require-checksum)
            REQUIRE_CHECKSUM="1"
            ;;
        --download-base=*)
            DOWNLOAD_BASE="${1#*=}"
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -n "$SKIP_CHECKSUM" ] && [ -n "$REQUIRE_CHECKSUM" ]; then
    echo "--skip-checksum and --require-checksum are mutually exclusive" >&2
    exit 1
fi

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Installation layout
#
# Mode is decided by the uid: the unit scope (system or --user) and the
# writability of /etc/systemd/system follow it, not the binary directory.

resolve_layout() {
    if [ "$(id -u)" -eq 0 ]; then
        MODE="root"
        [ -n "$INSTALL_DIR" ] || INSTALL_DIR="/usr/local/bin"
        UNIT_FILE="/etc/systemd/system/${UNIT_NAME}.service"
        UNIT_TARGET="multi-user.target"
    else
        MODE="rootless"
        if [ -z "$INSTALL_DIR" ]; then
            local script_dir
            script_dir="$(cd "$(dirname "$0")" && pwd)"
            if [ -w "$script_dir" ]; then
                # get-tool drops this script into the daemon tools directory,
                # which gameap-daemon prepends to its PATH — the natural target.
                INSTALL_DIR="$script_dir"
            else
                INSTALL_DIR="${HOME}/.local/bin"
            fi
        fi
        UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${UNIT_NAME}.service"
        UNIT_TARGET="default.target"
    fi

    [ -n "$CONFIG_DIR" ] || CONFIG_DIR="${DATA_DIR}/.plugins/files"
    USERS_DIR="${CONFIG_DIR}/users.d"
    BINARY="${INSTALL_DIR}/${COMPONENT}"
}

# Paths end up in a YAML double-quoted scalar, a systemd ExecStart line and an
# unquoted heredoc; spaces are fine in all three, these characters are not.
_assert_plain_abs_path() {
    case "$2" in
        /*) ;;
        *)
            echo "Error: $1 must be an absolute path, got '$2'" >&2
            exit 1
            ;;
    esac
    case "$2" in
        *\"*|*\\*|*\$*|*\`*|*[[:cntrl:]]*)
            echo "Error: $1 must not contain quotes, backslashes, \$ or backticks: '$2'" >&2
            exit 1
            ;;
    esac
}

# systemd expands %-specifiers in unit files.
_unit_escape() {
    printf '%s' "$1" | sed 's/%/%%/g'
}

# Port of a Go listen address (":21", "0.0.0.0:21", "[::]:21", "host:21");
# empty when there is none, in which case the binary reports the problem.
_port_of() {
    local port="${1##*:}"
    case "$port" in
        ''|*[!0-9]*) echo "" ;;
        *) echo "$port" ;;
    esac
}

_require_unprivileged_port() {
    local flag="$1" value="$2" floor="$3" port
    port="$(_port_of "$value")"
    if [ -z "$port" ] || [ "$port" -ge "$floor" ]; then
        return 0
    fi
    cat >&2 << MSG
Error: ${flag}=${value} asks for port ${port}, but a rootless install runs ${COMPONENT} as $(id -un), which cannot bind ports below ${floor}.
Pick a port of ${floor} or higher (for example --ftp-listen-address=:2121 or --ftp-tls-implicit-port=:9990), or as root either
lower the floor permanently with 'sysctl -w net.ipv4.ip_unprivileged_port_start=${port}' (this script honours it), or grant
the capability to the binary after every install ('setcap cap_net_bind_service=+ep ${BINARY}') and re-run with --skip-port-check.
MSG
    exit 1
}

# A unit that dies on bind is the least helpful failure, so privileged ports
# are rejected before anything is downloaded.
check_rootless_ports() {
    if [ "$MODE" != "rootless" ] || [ -n "$SKIP_PORT_CHECK" ]; then
        return 0
    fi
    local floor
    floor="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)"
    case "$floor" in
        ''|*[!0-9]*) floor=1024 ;;
    esac
    _require_unprivileged_port --ftp-listen-address "$FTP_LISTEN_ADDR" "$floor"
    _require_unprivileged_port --sftp-listen-address "$SFTP_LISTEN_ADDR" "$floor"
    if [ "$FTP_TLS_ENABLED" = "true" ]; then
        _require_unprivileged_port --ftp-tls-implicit-port "$FTP_TLS_IMPLICIT_PORT" "$floor"
    fi
    _require_unprivileged_port --ftp-passive-port-min ":${FTP_PASSIVE_PORT_MIN}" "$floor"
}

# systemctl --user needs the user manager's runtime directory. Mirrors what
# gameap-daemon does (processmanager/systemd.go): the environment first, then
# /run/user/<uid>.
export_user_manager_env() {
    [ "$MODE" = "rootless" ] || return 0
    if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
        XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export XDG_RUNTIME_DIR
    fi
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        export DBUS_SESSION_BUS_ADDRESS
    fi
}

user_manager_hint() {
    local user
    user="$(id -un)"
    echo "A rootless install registers a systemd user unit, which needs the user manager (user@$(id -u).service) of ${user} to be running."
    echo "Either log in as ${user} through a real session (ssh, not su or sudo -u), or enable lingering so it runs at boot:"
    echo "  sudo loginctl enable-linger ${user}"
}

require_user_manager() {
    [ "$MODE" = "rootless" ] || return 0
    if [ ! -d "$XDG_RUNTIME_DIR" ] || ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "Error: no systemd user manager is reachable for $(id -un) (XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR})." >&2
        user_manager_hint >&2
        exit 1
    fi
}

warn_if_not_lingering() {
    local user linger
    user="$(id -un)"
    linger="$(loginctl show-user "$user" --property=Linger --value 2>/dev/null || true)"
    if [ "$linger" != "yes" ]; then
        echo "Warning: lingering is not enabled for ${user}: the ${UNIT_NAME} user service stops when the last session of ${user} ends and does not start at boot." >&2
        echo "Enable it once, as root:  sudo loginctl enable-linger ${user}" >&2
    fi
}

# An earlier root install leaves a system unit that keeps the ports and the
# old configuration; the user unit cannot take over from it.
warn_if_system_unit_active() {
    [ "$MODE" = "rootless" ] || return 0
    if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
        echo "Warning: a system-wide ${UNIT_NAME} service is active (an earlier root install). It keeps its ports and ${LEGACY_CONFIG_DIR}; stop it as root before relying on the user service:  sudo systemctl disable --now ${UNIT_NAME}" >&2
    fi
}

ensure_data_dir() {
    if [ -d "$DATA_DIR" ]; then
        if [ "$MODE" = "rootless" ] && [ ! -w "$DATA_DIR" ]; then
            echo "Error: ${DATA_DIR} is not writable by $(id -un); a rootless install keeps its configuration in ${CONFIG_DIR}." >&2
            exit 1
        fi
        return 0
    fi
    echo "Creating data directory ${DATA_DIR}..."
    if ! mkdir -p "$DATA_DIR"; then
        echo "Error: cannot create ${DATA_DIR}" >&2
        exit 1
    fi
}

warn_if_config_outside_data_dir() {
    case "$CONFIG_DIR" in
        "$DATA_DIR"/*) ;;
        *)
            echo "Warning: ${CONFIG_DIR} is outside ${DATA_DIR}; gameap-daemon confines the panel's Files plugin to the data directory, so the panel will not be able to manage users there." >&2
            ;;
    esac
}

_systemctl() {
    if [ "$MODE" = "root" ]; then
        systemctl "$@"
    else
        systemctl --user "$@"
    fi
}

_systemctl_label() {
    if [ "$MODE" = "root" ]; then
        echo "systemctl"
    else
        echo "systemctl --user"
    fi
}

_systemctl_or_die() {
    if ! _systemctl "$@"; then
        echo "Error: $(_systemctl_label) $* failed." >&2
        [ "$MODE" != "rootless" ] || user_manager_hint >&2
        exit 1
    fi
}

# Configuration file and binary recorded in an installed unit.
_unit_config() {
    sed -n 's/.* -c "\{0,1\}\([^"]*config\.yaml\)"\{0,1\}.*/\1/p' "$1" 2>/dev/null | head -n 1
}

_unit_binary() {
    sed -n 's/^ExecStart="\{0,1\}\([^" ]*\)"\{0,1\} .*/\1/p' "$1" 2>/dev/null | head -n 1
}

_installed_version() {
    "$1" version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

_migration_status() {
    local legacy_config="${LEGACY_CONFIG_DIR}/config.yaml"
    if [ -f "${CONFIG_DIR}/config.yaml" ]; then
        if [ -e "$legacy_config" ]; then
            echo "done (leftovers at ${LEGACY_CONFIG_DIR}, safe to remove)"
        else
            echo "not needed"
        fi
        return 0
    fi
    if [ ! -d "$LEGACY_CONFIG_DIR" ]; then
        echo "not needed (fresh install)"
    elif [ -r "$legacy_config" ]; then
        echo "pending from ${LEGACY_CONFIG_DIR} (the next install run migrates it)"
    elif [ -e "$legacy_config" ] || [ ! -x "$LEGACY_CONFIG_DIR" ]; then
        echo "unknown: ${LEGACY_CONFIG_DIR} is not readable by $(id -un); run as root: sudo ${BINARY} migrate --from ${LEGACY_CONFIG_DIR} --to ${CONFIG_DIR}"
    else
        echo "not needed (${LEGACY_CONFIG_DIR} has no config.yaml)"
    fi
}

# --check: describe the installation without changing anything. Never
# requires a user manager, so a user without one still gets a report.
report_status() {
    local binary="$BINARY"
    if [ ! -x "$binary" ]; then
        local from_unit
        from_unit="$(_unit_binary "$UNIT_FILE")"
        if [ -n "$from_unit" ] && [ -x "$from_unit" ]; then
            binary="$from_unit"
        elif command -v "$COMPONENT" >/dev/null 2>&1; then
            binary="$(command -v "$COMPONENT")"
        else
            echo "${COMPONENT} is not installed (looked for ${BINARY} and ${UNIT_FILE})" >&2
            return 1
        fi
    fi

    local version mode_label config_state users_state unit_state unit_config
    version="$(_installed_version "$binary")"
    mode_label="$MODE"
    [ "$MODE" != "rootless" ] || mode_label="rootless (user $(id -un))"

    if [ -f "${CONFIG_DIR}/config.yaml" ]; then
        config_state="present"
    else
        config_state="missing"
    fi

    if [ -d "$USERS_DIR" ]; then
        users_state="$(find "$USERS_DIR" -maxdepth 1 \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | wc -l | tr -d ' ') user files"
    else
        users_state="missing"
    fi

    unit_config=""
    if [ -f "$UNIT_FILE" ]; then
        unit_state="$(_systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true), $(_systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
        unit_config="$(_unit_config "$UNIT_FILE")"
    else
        unit_state="not installed"
    fi

    echo "${COMPONENT} ${version:-unknown version}"
    echo "  mode:      ${mode_label}"
    echo "  binary:    ${binary}"
    echo "  data dir:  ${DATA_DIR:-unknown}"
    echo "  config:    ${CONFIG_DIR}/config.yaml (${config_state})"
    echo "  users:     ${USERS_DIR} (${users_state})"
    echo "  unit:      ${UNIT_FILE} (${unit_state})"
    if [ -n "$unit_config" ] && [ "$unit_config" != "${CONFIG_DIR}/config.yaml" ]; then
        echo "             ExecStart still uses ${unit_config}; re-run the installer"
    fi
    echo "  migration: $(_migration_status)"
    if [ -n "$DATA_DIR" ] && [ -d "${DATA_DIR}/etc/gameap-files" ]; then
        echo "  note:      stray ${DATA_DIR}/etc/gameap-files left by an earlier Files plugin; the panel removes it after an update"
    fi
}

# Moves a configuration kept outside the data directory by an earlier release.
# Runs before any new file is written, so a fresh configuration never ends up
# on top of a half-moved tree.
migrate_legacy_config() {
    local legacy_config="${LEGACY_CONFIG_DIR}/config.yaml"

    [ ! -f "${CONFIG_DIR}/config.yaml" ] || return 0
    [ "$LEGACY_CONFIG_DIR" != "$CONFIG_DIR" ] || return 0
    [ -d "$LEGACY_CONFIG_DIR" ] || return 0

    if [ ! -r "$legacy_config" ]; then
        if [ -e "$legacy_config" ] || [ ! -x "$LEGACY_CONFIG_DIR" ]; then
            cat >&2 << MSG
Warning: ${LEGACY_CONFIG_DIR} exists but is not readable by $(id -un), so the previous configuration and
users cannot be migrated by this run; a fresh configuration is written instead. To migrate later, as root:
  systemctl --user stop ${UNIT_NAME}                 (as $(id -un))
  mv ${CONFIG_DIR} ${CONFIG_DIR}.fresh               (migrate does nothing while a config.yaml exists there)
  sudo ${BINARY} migrate --from ${LEGACY_CONFIG_DIR} --to ${CONFIG_DIR}
  sudo chown -R $(id -un): ${CONFIG_DIR}
  systemctl --user start ${UNIT_NAME}                (as $(id -un))
MSG
        else
            echo "Note: ${LEGACY_CONFIG_DIR} has no config.yaml, nothing to migrate from it." >&2
        fi
        return 0
    fi

    echo "Migrating the configuration from ${LEGACY_CONFIG_DIR} to ${CONFIG_DIR}..."
    if ! "$BINARY" migrate --from "$LEGACY_CONFIG_DIR" --to "$CONFIG_DIR"; then
        echo "Error: migration failed; the destination has no configuration yet, so the next run retries it, and the previous files stay where they are. Fix the problem and re-run." >&2
        exit 1
    fi
}

# Absolute paths on purpose: --version may pin an older release that resolves
# a relative path against the working directory of the process, and migrate
# rewrites them anyway when the directory moves.
write_config() {
    cat > "${CONFIG_DIR}/config.yaml" << EOF
server:
  name: "GameAP Files Server"
  data_dir: "${DATA_DIR}"

ftp:
  enabled: true
  listen_addr: "${FTP_LISTEN_ADDR}"
  passive_port_min: ${FTP_PASSIVE_PORT_MIN}
  passive_port_max: ${FTP_PASSIVE_PORT_MAX}
  public_host: "${FTP_PUBLIC_HOST}"
  idle_timeout: 300
  tls:
    enabled: ${FTP_TLS_ENABLED}
    cert_file: "${CONFIG_DIR}/tls/server.crt"
    key_file: "${CONFIG_DIR}/tls/server.key"
    implicit_port: "${FTP_TLS_IMPLICIT_PORT}"
    required: false

sftp:
  enabled: true
  listen_addr: "${SFTP_LISTEN_ADDR}"
  host_key_file: "${CONFIG_DIR}/ssh/host_ed25519_key"
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
  directory: "${CONFIG_DIR}/users.d"
  hot_reload: true
EOF
}

# One template serves both modes: After=network.target is ignored by a user
# manager, and User= is deliberately absent — the service runs as whoever
# installed it.
write_unit() {
    mkdir -p "$(dirname "$UNIT_FILE")"

    echo "Installing systemd unit ${UNIT_FILE}..."
    cat > "$UNIT_FILE" << EOF
[Unit]
Description=GameAP Files Server
After=network.target

[Service]
Type=simple
ExecStart="$(_unit_escape "$BINARY")" serve -c "$(_unit_escape "${CONFIG_DIR}/config.yaml")"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=${UNIT_TARGET}
EOF
}

_url_host() {
    local host="${1#*://}"
    echo "${host%%/*}"
}

# ---------------------------------------------------------------------------
# Release sources
#
# Every source answers two things: the release metadata (used to resolve a tag)
# and the binary itself. GitHub is canonical; the CDN mirrors publish the same
# metadata as a static releases.json so installs keep working where GitHub is
# slow, blocked or rate-limited.

source_names=()
source_kinds=()
source_bases=()
source_meta_urls=()

_register_sources() {
    if [ -n "$DOWNLOAD_BASE" ]; then
        local base="${DOWNLOAD_BASE%/}"
        source_names+=("$(_url_host "$base")")
        source_kinds+=("cdn")
        source_bases+=("$base")
        source_meta_urls+=("${base}/${COMPONENT}/releases.json")
        return
    fi

    source_names+=("github.com")
    source_kinds+=("github")
    source_bases+=("https://github.com")
    source_meta_urls+=("https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100")

    local cdn
    for cdn in "https://cdn.gameap.com" "https://cdn.gameap.ru"; do
        source_names+=("$(_url_host "$cdn")")
        source_kinds+=("cdn")
        source_bases+=("$cdn")
        source_meta_urls+=("${cdn}/${COMPONENT}/releases.json")
    done
}

# Download URL of one asset from a given source.
_download_url() {
    local idx="$1" tag="$2" asset="$3"

    if [ "${source_kinds[$idx]}" = "github" ]; then
        echo "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}"
    else
        echo "${source_bases[$idx]}/${COMPONENT}/${tag}/${asset}"
    fi
}

# Measure HTTPS response latency (seconds) to a URL with a HEAD request.
# HTTP probing is used instead of ICMP ping on purpose: ping may be missing
# on minimal systems, ICMP is often filtered, and ICMP reachability does not
# imply HTTPS reachability (which is exactly why the mirrors exist). If a
# mirror ever stops answering HEAD, switch to a ranged GET: -r 0-0 instead of -I.
_probe_mirror_latency() {
    curl -fsIL --connect-timeout 5 --max-time 10 -o /dev/null -w '%{time_total}' "$1"
}

# Probe every source's metadata URL in parallel and store source indexes in
# the global ordered_sources array, fastest first. The metadata URL is probed
# rather than the binary URL because it always exists — probing a versioned
# binary reports "no response" for every mirror whenever the version itself is
# wrong, which hides the real error. Sources that fail the probe are appended
# at the end instead of being dropped: a HEAD failure does not always mean a
# GET would fail.
ordered_sources=()
_order_sources() {
    ordered_sources=()

    if [ "${#source_meta_urls[@]}" -le 1 ]; then
        ordered_sources=(0)
        return
    fi

    echo "Choosing the fastest ${COMPONENT} release source..."

    local probe_dir
    probe_dir="$(mktemp -d -t gameap-files.XXXXXX)"

    local i
    for i in "${!source_meta_urls[@]}"; do
        (
            local t
            t="$(_probe_mirror_latency "${source_meta_urls[$i]}")" \
                && printf '%s %s\n' "${t}" "${i}" > "${probe_dir}/${i}"
        ) &
    done
    # A bare `wait` always returns 0, so it is safe under set -e. Failed
    # probes are detected by their missing result file, not by exit status.
    wait

    # curl always prints %{time_total} with a '.' decimal separator, but
    # sort -n would misread '.' in locales whose separator is ','.
    local line idx
    while read -r line; do
        [[ -n "${line}" ]] || continue
        idx="${line#* }"
        echo "  ${source_names[$idx]}: ${line%% *}s"
        ordered_sources+=("${idx}")
    done < <(LC_ALL=C sort -n "${probe_dir}"/* 2>/dev/null)

    local reachable=${#ordered_sources[@]}
    for i in "${!source_meta_urls[@]}"; do
        if [[ ! -e "${probe_dir}/${i}" ]]; then
            echo "  ${source_names[$i]}: no response, kept as a fallback"
            ordered_sources+=("${i}")
        fi
    done

    if [[ "${reachable}" -eq 0 ]]; then
        echo "No source answered the probe, they will be tried in the default order."
    fi

    rm -rf "${probe_dir}"
}

# ---------------------------------------------------------------------------
# Release metadata
#
# Both GitHub and the mirrors serve the same payload: the verbatim
# `GET /repos/<repo>/releases?per_page=100` array, newest release first, with
# drafts and prereleases included. One parser therefore covers all sources.
#
# jq is deliberately not required — it is absent on many minimal game-server
# nodes. grep extracts the three fields that matter and awk walks them: inside
# a release object GitHub emits tag_name, then draft, then prerelease, and
# those keys appear nowhere else (nested author/asset objects do not carry
# them, and release notes have their quotes escaped, so `"tag_name"` cannot
# match inside a body). Both the pretty-printed API output and a minified
# mirror copy parse identically.

_release_fields() {
    grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"\|"draft"[[:space:]]*:[[:space:]]*[a-z]*\|"prerelease"[[:space:]]*:[[:space:]]*[a-z]*' "$1"
}

# Newest release that is neither a draft nor (unless allowed) a prerelease.
_latest_tag() {
    _release_fields "$1" | awk -v allow_pre="${ALLOW_PRERELEASE}" '
        /"tag_name"/    { split($0, f, "\""); tag = f[4]; draft = ""; next }
        /"draft"/       { draft = ($0 ~ /true/) ? "true" : "false"; next }
        /"prerelease"/  {
            pre = ($0 ~ /true/) ? "true" : "false"
            if (tag != "" && draft == "false" && (pre == "false" || allow_pre == "1")) {
                print tag
                exit
            }
            next
        }
    '
}

# Exact tag of a requested version, accepting it with or without the v prefix.
_resolve_tag() {
    _release_fields "$1" | awk -v want="$2" -v vwant="v$2" '
        /"tag_name"/ {
            split($0, f, "\"")
            if (f[4] == want || f[4] == vwant) { print f[4]; exit }
        }
    '
}

_print_versions() {
    _release_fields "$1" | awk '
        /"tag_name"/    { split($0, f, "\""); tag = f[4]; draft = ""; next }
        /"draft"/       { draft = ($0 ~ /true/) ? "true" : "false"; next }
        /"prerelease"/  {
            pre = ($0 ~ /true/) ? "true" : "false"
            note = ""
            if (draft == "true") note = "  (draft)"
            else if (pre == "true") note = "  (prerelease)"
            if (tag != "") print "  " tag note
            next
        }
    '
}

# Fetch metadata from the first source that answers. Sets METADATA_FILE and
# METADATA_SOURCE, or leaves METADATA_FILE empty when every source failed.
METADATA_FILE=""
METADATA_SOURCE=""
# Declared here too so the EXIT trap can reference it before the download step.
TMP_FILE=""
_fetch_metadata() {
    local idx tmp
    tmp="$(mktemp /tmp/gameap-files-releases.XXXXXX)"

    for idx in "${ordered_sources[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 30 -o "${tmp}" "${source_meta_urls[$idx]}" \
            && [ -s "${tmp}" ]; then
            METADATA_FILE="${tmp}"
            METADATA_SOURCE="${source_names[$idx]}"
            return 0
        fi
        echo "Could not read releases from ${source_names[$idx]}, trying the next source..." >&2
    done

    rm -f "${tmp}"
    return 0
}

_sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

# Not being able to check a sum is tolerated by default — releases predating
# the checksums, or a node without a hashing tool, should still install — but
# --require-checksum turns every such case into a failure.
_checksum_unavailable() {
    if [ -n "$REQUIRE_CHECKSUM" ]; then
        echo "Checksum required but $1" >&2
        return 1
    fi
    echo "Warning: $1, skipping verification" >&2
    return 0
}

# Verify the download against the .sha256 published next to it. A mismatch
# always fails, so the caller moves on to the next source.
_verify_checksum() {
    local file="$1" url="$2" raw expected actual

    if [ -n "$SKIP_CHECKSUM" ]; then
        return 0
    fi

    if ! raw="$(curl -fsSL --connect-timeout 10 --max-time 30 "${url}.sha256" 2>/dev/null)"; then
        _checksum_unavailable "no checksum published for this build"
        return $?
    fi

    expected="$(printf '%s\n' "${raw}" | awk 'NF { print $1; exit }')"
    if [ -z "${expected}" ]; then
        _checksum_unavailable "the published checksum is empty"
        return $?
    fi

    if ! actual="$(_sha256_of "${file}")"; then
        _checksum_unavailable "neither sha256sum nor shasum is available"
        return $?
    fi

    if [ "${expected}" != "${actual}" ]; then
        echo "Checksum mismatch: expected ${expected}, got ${actual}" >&2
        return 1
    fi

    echo "Checksum verified."
}

# One trap for every temp file, installed before the first one is created:
# the resolution steps below have several exit paths, and `set -e` can end the
# run anywhere in between. The explicit `rm -f` calls further down stay — they
# free the metadata early, before a potentially long download — and re-running
# rm on an already-removed or empty path is harmless.
_cleanup() {
    rm -f "${METADATA_FILE}" "${TMP_FILE}" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight: everything that can be rejected without touching the network.

if [ -z "$LIST_VERSIONS" ]; then
    if [ -z "$DATA_DIR" ] && { [ -z "$CHECK_ONLY" ] || [ -z "$CONFIG_DIR" ]; }; then
        echo "Error: --data-dir is required" >&2
        echo "Use --help for usage information" >&2
        exit 1
    fi
    if [ -n "$DATA_DIR" ]; then
        DATA_DIR="${DATA_DIR%/}"
        _assert_plain_abs_path --data-dir "$DATA_DIR"
    fi

    resolve_layout
    _assert_plain_abs_path --install-dir "$INSTALL_DIR"
    _assert_plain_abs_path --config-dir "$CONFIG_DIR"
    _assert_plain_abs_path --legacy-config-dir "$LEGACY_CONFIG_DIR"
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "Error: systemd (systemctl) is required" >&2
        exit 1
    fi
    export_user_manager_env

    if [ -n "$CHECK_ONLY" ]; then
        report_status
        exit $?
    fi

    check_rootless_ports
    require_user_manager
    warn_if_system_unit_active
    ensure_data_dir
    warn_if_config_outside_data_dir
fi

_register_sources
_order_sources
_fetch_metadata

if [ -n "$LIST_VERSIONS" ]; then
    if [ -z "$METADATA_FILE" ]; then
        echo "Failed to read the release list from any source." >&2
        exit 1
    fi
    echo "Available ${COMPONENT} releases (from ${METADATA_SOURCE}):"
    _print_versions "$METADATA_FILE"
    rm -f "$METADATA_FILE"
    exit 0
fi

TAG=""
if [ -z "$GAMEAP_FILES_VERSION" ] || [ "$GAMEAP_FILES_VERSION" = "latest" ]; then
    if [ -z "$METADATA_FILE" ]; then
        echo "Failed to resolve the latest ${COMPONENT} version. Sources tried:" >&2
        printf '  - %s\n' "${source_meta_urls[@]}" >&2
        echo "Pass --version=X.Y.Z to install a specific release without the lookup." >&2
        exit 1
    fi
    TAG="$(_latest_tag "$METADATA_FILE")"
    if [ -z "$TAG" ]; then
        echo "No suitable release found in the release list from ${METADATA_SOURCE}." >&2
        echo "Use --allow-prerelease if only prereleases are published." >&2
        exit 1
    fi
    echo "Latest ${COMPONENT} release: ${TAG} (via ${METADATA_SOURCE})"
elif [ -n "$METADATA_FILE" ]; then
    TAG="$(_resolve_tag "$METADATA_FILE" "$GAMEAP_FILES_VERSION")"
    if [ -z "$TAG" ]; then
        echo "Release '${GAMEAP_FILES_VERSION}' not found. Available releases:" >&2
        _print_versions "$METADATA_FILE" >&2
        rm -f "$METADATA_FILE"
        exit 1
    fi
else
    # No metadata anywhere: fall back to the tag convention (vX.Y.Z) and let
    # the download surface the failure.
    case "$GAMEAP_FILES_VERSION" in
        v*) TAG="$GAMEAP_FILES_VERSION" ;;
        *)  TAG="v${GAMEAP_FILES_VERSION}" ;;
    esac
    echo "Warning: no release source answered; assuming tag ${TAG}." >&2
fi

BINARY_FILE="${COMPONENT}-${TAG}-${OS}-${ARCH}"

if [ -n "$METADATA_FILE" ] \
    && ! grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${BINARY_FILE}\"" "$METADATA_FILE"; then
    echo "Release ${TAG} has no ${OS}-${ARCH} build (expected asset ${BINARY_FILE})." >&2
    rm -f "$METADATA_FILE"
    exit 1
fi

rm -f "$METADATA_FILE"
METADATA_FILE=""

TMP_FILE=$(mktemp /tmp/gameap-files.XXXXXX)

echo "Installing ${COMPONENT} ${TAG} (${OS}-${ARCH})..."

downloaded=""
tried_urls=()
for idx in "${ordered_sources[@]}"; do
    download_url="$(_download_url "$idx" "$TAG" "$BINARY_FILE")"
    tried_urls+=("${download_url}")

    echo "Downloading from ${source_names[$idx]}..."
    if ! curl -fsSL --connect-timeout 10 -o "$TMP_FILE" "${download_url}"; then
        echo "Failed to download from ${download_url}, trying the next source..." >&2
        continue
    fi

    if ! _verify_checksum "$TMP_FILE" "${download_url}"; then
        echo "Discarding the download from ${source_names[$idx]}, trying the next source..." >&2
        continue
    fi

    downloaded="1"
    break
done

if [[ -z "${downloaded}" ]]; then
    echo "Failed to download ${COMPONENT}. URLs tried:" >&2
    printf '  - %s\n' "${tried_urls[@]}" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
previous="$(_installed_version "$BINARY")"
if [ -n "$previous" ]; then
    echo "Replacing installed ${COMPONENT} ${previous}..."
fi
install -m 0755 "$TMP_FILE" "$BINARY"

migrate_legacy_config

# The parent is normally the panel's .plugins directory, which gameap-daemon
# creates world readable; the configuration itself is kept private.
mkdir -p "$(dirname "$CONFIG_DIR")"
install -d -m 0750 "$CONFIG_DIR" "$USERS_DIR" "${CONFIG_DIR}/tls"
install -d -m 0700 "${CONFIG_DIR}/ssh"

# Generate SSH host key if not exists
if [ ! -f "${CONFIG_DIR}/ssh/host_ed25519_key" ]; then
    echo "Generating SSH host key..."
    "$BINARY" genkey -t ed25519 -o "${CONFIG_DIR}/ssh/host_ed25519_key"
fi

if [ -f "${CONFIG_DIR}/config.yaml" ] && [ -z "$FORCE" ]; then
    echo "Configuration already exists at ${CONFIG_DIR}/config.yaml, keeping it (use --force to regenerate)."
else
    if [ -f "${CONFIG_DIR}/config.yaml" ]; then
        cp -p "${CONFIG_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml.bak"
        echo "Regenerating configuration, previous file kept as ${CONFIG_DIR}/config.yaml.bak"
    else
        echo "Creating configuration..."
    fi
    write_config
    chmod 0640 "${CONFIG_DIR}/config.yaml"
fi

# Checked before the unit is touched: a configuration problem should surface as
# one readable message here, not as a service that dies in a restart loop.
echo "Verifying configuration..."
if ! "$BINARY" validate -c "${CONFIG_DIR}/config.yaml"; then
    echo "Error: the configuration at ${CONFIG_DIR}/config.yaml is invalid; the service was not (re)started." >&2
    exit 1
fi

write_unit
[ "$MODE" != "rootless" ] || warn_if_not_lingering
_systemctl_or_die daemon-reload
_systemctl_or_die enable "$UNIT_NAME"
_systemctl_or_die restart "$UNIT_NAME"

# restart returns as soon as the process is running, which says nothing about
# the ports: a gameap-files that cannot bind dies within a second or two.
sleep 2
state="$(_systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
if [ "$state" != "active" ]; then
    journal_scope=""
    [ "$MODE" = "root" ] || journal_scope=" --user"
    echo "Warning: ${UNIT_NAME} is ${state:-inactive} shortly after starting." >&2
    echo "See: journalctl${journal_scope} -u ${UNIT_NAME} -n 50   (a port already in use is the usual cause)" >&2
fi

mode_label="$MODE"
[ "$MODE" != "rootless" ] || mode_label="rootless (user $(id -un))"

echo
echo "${COMPONENT} ${TAG} installed successfully."
echo "  mode:     ${mode_label}"
echo "  binary:   ${BINARY}"
echo "  config:   ${CONFIG_DIR}/config.yaml"
echo "  users:    ${USERS_DIR}"
echo "  data dir: ${DATA_DIR}"
echo "  unit:     ${UNIT_FILE} (${state:-unknown})"
if [ "$MODE" = "rootless" ]; then
    echo "Note: rootless install — gameap-daemon resolves the binary by name via its tools PATH; manage the service with: systemctl --user status ${UNIT_NAME}"
    if [ "$INSTALL_DIR" = "${HOME}/.local/bin" ]; then
        echo "Note: ${INSTALL_DIR} is not on the daemon's PATH; the panel's status check (gameap-files version) will not find the binary there. Re-run with --install-dir=<data-dir>/tools to fix that." >&2
    fi
fi
