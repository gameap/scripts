#!/bin/bash

# GameAP MySQL CLI installation script for Linux.
# Resolves the requested release, downloads the gameap-mysql binary and
# prepares its state directory.
#
# Releases are looked up in three sources — GitHub (canonical) plus the
# cdn.gameap.com / cdn.gameap.ru mirrors, which publish the verbatim GitHub
# releases payload as <mirror>/gameap-mysql/releases.json. Without --version
# the newest stable release is installed.
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
#   install-mysql-cli-linux.sh --version=latest

set -e

COMPONENT="gameap-mysql"
GITHUB_REPO="gameap/gameap-mysql"

# Empty means "resolve the newest stable release".
GAMEAP_MYSQL_VERSION=""
ALLOW_PRERELEASE=""
LIST_VERSIONS=""
SKIP_CHECKSUM=""
REQUIRE_CHECKSUM=""
DOWNLOAD_BASE=""
INSTALL_DIR=""
STATE_DIR=""

show_help() {
    echo "GameAP MySQL CLI installation script"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --version=VERSION        Release to install: 'latest' (default), or a"
    echo "                           version with or without the v prefix (0.1.1, v0.1.1)"
    echo "  --list-versions          Print the available releases and exit"
    echo "  --allow-prerelease       Consider prereleases when resolving 'latest'"
    echo "  --skip-checksum          Do not verify the published sha256 sum"
    echo "  --require-checksum       Fail instead of warning when the sha256 sum cannot"
    echo "                           be checked (missing sidecar, no hashing tool)"
    echo "  --install-dir=DIR        Binary directory (default: /usr/local/bin when writable,"
    echo "                           otherwise the directory of this script, then ~/.local/bin)"
    echo "  --state-dir=DIR          State directory (default: /var/lib/gameap-mysql as root,"
    echo "                           otherwise \${XDG_STATE_HOME:-\$HOME/.local/state}/gameap-mysql;"
    echo "                           a custom value must also be exported to the daemon as"
    echo "                           GAMEAP_MYSQL_STATE_DIR or the CLI will not find it)"
    echo "  --download-base=URL      Use a single custom mirror instead of the default"
    echo "                           GitHub/CDN sources; expects URL/${COMPONENT}/releases.json"
    echo "                           and URL/${COMPONENT}/TAG/${COMPONENT}-TAG-OS-ARCH"
    echo "  --help                   Show this help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version=*)
            GAMEAP_MYSQL_VERSION="${1#*=}"
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

if [ -n "$SKIP_CHECKSUM" ] && [ -n "$REQUIRE_CHECKSUM" ]; then
    echo "--skip-checksum and --require-checksum are mutually exclusive" >&2
    exit 1
fi

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
    probe_dir="$(mktemp -d -t gameap-mysql.XXXXXX)"

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
    tmp="$(mktemp /tmp/gameap-mysql-releases.XXXXXX)"

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

resolve_install_dir
resolve_state_dir

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
if [ -z "$GAMEAP_MYSQL_VERSION" ] || [ "$GAMEAP_MYSQL_VERSION" = "latest" ]; then
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
    TAG="$(_resolve_tag "$METADATA_FILE" "$GAMEAP_MYSQL_VERSION")"
    if [ -z "$TAG" ]; then
        echo "Release '${GAMEAP_MYSQL_VERSION}' not found. Available releases:" >&2
        _print_versions "$METADATA_FILE" >&2
        rm -f "$METADATA_FILE"
        exit 1
    fi
else
    # No metadata anywhere: fall back to the tag convention (vX.Y.Z) and let
    # the download surface the failure.
    case "$GAMEAP_MYSQL_VERSION" in
        v*) TAG="$GAMEAP_MYSQL_VERSION" ;;
        *)  TAG="v${GAMEAP_MYSQL_VERSION}" ;;
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

TMP_FILE=$(mktemp /tmp/gameap-mysql.XXXXXX)

echo "Downloading ${COMPONENT} ${TAG} (${OS}-${ARCH})..."

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
install -m 0755 "$TMP_FILE" "${INSTALL_DIR}/${COMPONENT}"

install -d -m 0700 "$STATE_DIR"

echo "Verifying installation..."
"${INSTALL_DIR}/${COMPONENT}" version --json

echo "${COMPONENT} ${TAG} installed to ${INSTALL_DIR}/${COMPONENT} (state: ${STATE_DIR})"

if [ "$INSTALL_DIR" != "/usr/local/bin" ]; then
    echo "Note: rootless install — gameap-daemon resolves the binary by name via its tools PATH."
fi
