#!/bin/bash

# GameAP MySQL CLI installation script for Linux.
# Downloads the gameap-mysql release binary and prepares its state directory.
#
# Works both as root (system-wide: /usr/local/bin + /var/lib/gameap-mysql)
# and from a rootless GameAP setup (non-root gameap-daemon): without write
# access to /usr/local/bin the binary is installed next to this script —
# the daemon tools directory, which gameap-daemon puts on its PATH — and the
# state directory falls back to the user state dir the CLI resolves itself
# (${XDG_STATE_HOME:-$HOME/.local/state}/gameap-mysql).
#
# Invoked by the panel's MySQL plugin as a daemon task chain:
#   get-tool .../mysql/install-mysql-cli-linux.sh
#   install-mysql-cli-linux.sh --version=X.Y.Z

set -e

GAMEAP_MYSQL_VERSION="0.1.0"
DOWNLOAD_BASE=""
INSTALL_DIR=""
STATE_DIR=""

show_help() {
    echo "GameAP MySQL CLI installation script"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --version=VERSION        CLI version to install (default: ${GAMEAP_MYSQL_VERSION})"
    echo "  --install-dir=DIR        Binary directory (default: /usr/local/bin when writable,"
    echo "                           otherwise the directory of this script, then ~/.local/bin)"
    echo "  --state-dir=DIR          State directory (default: /var/lib/gameap-mysql as root,"
    echo "                           otherwise \${XDG_STATE_HOME:-\$HOME/.local/state}/gameap-mysql;"
    echo "                           a custom value must also be exported to the daemon as"
    echo "                           GAMEAP_MYSQL_STATE_DIR or the CLI will not find it)"
    echo "  --download-base=URL      Use a single custom mirror instead of the default"
    echo "                           GitHub/CDN mirror list; expects"
    echo "                           URL/gameap-mysql/VERSION/gameap-mysql-VERSION-OS-ARCH"
    echo "  --help                   Show this help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version=*)
            GAMEAP_MYSQL_VERSION="${1#*=}"
            ;;
        --install-dir=*)
            INSTALL_DIR="${1#*=}"
            ;;
        --state-dir=*)
            STATE_DIR="${1#*=}"
            ;;
        --download-base=*)
            DOWNLOAD_BASE="${1#*=}"
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case $ARCH in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

resolve_install_dir() {
    if [ -n "$INSTALL_DIR" ]; then
        return
    fi

    if [ -w /usr/local/bin ]; then
        INSTALL_DIR="/usr/local/bin"
        return
    fi

    script_dir=$(cd "$(dirname "$0")" && pwd)
    if [ -w "$script_dir" ]; then
        # get-tool drops this script into the daemon tools directory, which
        # gameap-daemon prepends to its PATH — the natural rootless target.
        INSTALL_DIR="$script_dir"
        return
    fi

    INSTALL_DIR="${HOME}/.local/bin"
}

# Mirrors the CLI's own state-dir resolution (internal/platform): root uses
# the system directory; a non-root daemon uses it only when pre-provisioned
# writable, otherwise the XDG user state directory.
resolve_state_dir() {
    if [ -n "$STATE_DIR" ]; then
        return
    fi

    if [ "$(id -u)" -eq 0 ]; then
        STATE_DIR="/var/lib/gameap-mysql"
        return
    fi

    if [ -d /var/lib/gameap-mysql ] && [ -w /var/lib/gameap-mysql ]; then
        STATE_DIR="/var/lib/gameap-mysql"
        return
    fi

    STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/gameap-mysql"
}

_url_host() {
    local host="${1#*://}"
    echo "${host%%/*}"
}

# Measure HTTPS response latency (seconds) to a URL with a HEAD request.
# HTTP probing is used instead of ICMP ping on purpose: ping may be missing
# on minimal systems, ICMP is often filtered, and ICMP reachability does not
# imply HTTPS reachability (which is exactly why the mirrors exist). If a
# mirror ever stops answering HEAD, switch to a ranged GET: -r 0-0 instead of -I.
_probe_mirror_latency() {
    curl -fsIL --connect-timeout 5 --max-time 10 -o /dev/null -w '%{time_total}' "$1"
}

# Probe all given mirror URLs in parallel and store them in the global
# ordered_mirrors array, fastest first. Mirrors that fail the probe are
# appended at the end in the given order instead of being dropped: a HEAD
# failure does not always mean a GET would fail.
ordered_mirrors=()
_order_mirrors() {
    local urls=("$@")
    ordered_mirrors=()

    _probe_dir="$(mktemp -d -t gameap-mysql.XXXXXX)"

    local i
    for i in "${!urls[@]}"; do
        (
            local t
            t="$(_probe_mirror_latency "${urls[$i]}")" \
                && printf '%s %s\n' "${t}" "${urls[$i]}" > "${_probe_dir}/${i}"
        ) &
    done
    # A bare `wait` always returns 0, so it is safe under set -e. Failed
    # probes are detected by their missing result file, not by exit status.
    wait

    # curl always prints %{time_total} with a '.' decimal separator, but
    # sort -n would misread '.' in locales whose separator is ','.
    local line url
    while read -r line; do
        [[ -n "${line}" ]] || continue
        url="${line#* }"
        echo "  $(_url_host "${url}"): ${line%% *}s"
        ordered_mirrors+=("${url}")
    done < <(LC_ALL=C sort -n "${_probe_dir}"/* 2>/dev/null)

    local reachable=${#ordered_mirrors[@]}
    for i in "${!urls[@]}"; do
        if [[ ! -e "${_probe_dir}/${i}" ]]; then
            echo "  $(_url_host "${urls[$i]}"): no response, kept as a fallback"
            ordered_mirrors+=("${urls[$i]}")
        fi
    done

    if [[ "${reachable}" -eq 0 ]]; then
        echo "No mirror answered the probe, mirrors will be tried in the default order."
    fi

    rm -rf "${_probe_dir}"
    _probe_dir=""
}

resolve_install_dir
resolve_state_dir

BINARY_FILE="gameap-mysql-${GAMEAP_MYSQL_VERSION}-${OS}-${ARCH}"

# GitHub is the canonical source; the CDN mirrors keep the installation
# working where GitHub is slow or unreachable.
mirror_urls=(
    "https://github.com/gameap/gameap-mysql/releases/download/${GAMEAP_MYSQL_VERSION}/${BINARY_FILE}"
    "https://cdn.gameap.com/gameap-mysql/${GAMEAP_MYSQL_VERSION}/${BINARY_FILE}"
    "https://cdn.gameap.ru/gameap-mysql/${GAMEAP_MYSQL_VERSION}/${BINARY_FILE}"
)

if [ -n "$DOWNLOAD_BASE" ]; then
    mirror_urls=("${DOWNLOAD_BASE}/gameap-mysql/${GAMEAP_MYSQL_VERSION}/${BINARY_FILE}")
fi

if [ "${#mirror_urls[@]}" -gt 1 ]; then
    echo "Choosing the fastest gameap-mysql download mirror..."
    _order_mirrors "${mirror_urls[@]}"
else
    ordered_mirrors=("${mirror_urls[@]}")
fi

TMP_FILE=$(mktemp /tmp/gameap-mysql.XXXXXX)
trap 'rm -f "$TMP_FILE"' EXIT

echo "Downloading gameap-mysql v${GAMEAP_MYSQL_VERSION} (${OS}-${ARCH})..."

downloaded=""
for mirror_url in "${ordered_mirrors[@]}"; do
    echo "Downloading from $(_url_host "${mirror_url}")..."
    if curl -fsSL --connect-timeout 10 -o "$TMP_FILE" "${mirror_url}"; then
        downloaded="1"
        break
    fi
    echo "Failed to download from ${mirror_url}, trying the next mirror..." >&2
done

if [[ -z "${downloaded}" ]]; then
    echo "Failed to download gameap-mysql. Mirrors tried:" >&2
    printf '  - %s\n' "${ordered_mirrors[@]}" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "$TMP_FILE" "${INSTALL_DIR}/gameap-mysql"

install -d -m 0700 "$STATE_DIR"

echo "Verifying installation..."
"${INSTALL_DIR}/gameap-mysql" version --json

echo "gameap-mysql v${GAMEAP_MYSQL_VERSION} installed to ${INSTALL_DIR}/gameap-mysql (state: ${STATE_DIR})"

if [ "$INSTALL_DIR" != "/usr/local/bin" ]; then
    echo "Note: rootless install — gameap-daemon resolves the binary by name via its tools PATH."
fi
