#!/bin/bash
set -e

GAMEAP_FILES_VERSION="1.0.0"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/gameap-files"
USERS_DIR="${CONFIG_DIR}/users.d"

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
    --data-dir=DIR              Data directory for game servers

Optional:
    --ftp-listen-address=ADDR   FTP listen address (default: :21)
    --ftp-passive-port-min=N    FTP passive port range start (default: 30000)
    --ftp-passive-port-max=N    FTP passive port range end (default: 30100)
    --ftp-public-host=HOST      FTP public host for passive mode
    --ftp-tls-enabled=BOOL      Enable FTP TLS (default: false)
    --ftp-tls-implicit-port=N   FTP implicit TLS port (default: :990)
    --sftp-listen-address=ADDR  SFTP listen address (default: :2222)
    --version=VERSION           GameAP Files version to install (default: 1.0.0)
    --help                      Show this help message

Examples:
    $0 --data-dir=/home/servers
    $0 --data-dir=/home/servers --ftp-listen-address=0.0.0.0:21 --sftp-listen-address=0.0.0.0:2222
    $0 --data-dir=/home/servers --ftp-tls-enabled=true --ftp-public-host=example.com
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
        --version=*)
            GAMEAP_FILES_VERSION="${1#*=}"
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
    shift
done

# Validate required parameters
if [ -z "$DATA_DIR" ]; then
    echo "Error: --data-dir is required"
    echo "Use --help for usage information"
    exit 1
fi

echo "Installing gameap-files v${GAMEAP_FILES_VERSION}..."

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Download binary
DOWNLOAD_URL="https://packages.gameap.com/gameap-files/${GAMEAP_FILES_VERSION}/gameap-files-${OS}-${ARCH}"
echo "Downloading from ${DOWNLOAD_URL}..."
curl -fsSL -o /tmp/gameap-files "$DOWNLOAD_URL"
chmod +x /tmp/gameap-files
mv /tmp/gameap-files "${INSTALL_DIR}/gameap-files"

# Create directories
mkdir -p "$CONFIG_DIR" "$USERS_DIR"

# Generate SSH host key if not exists
if [ ! -f "${CONFIG_DIR}/ssh_host_ed25519_key" ]; then
    echo "Generating SSH host key..."
    "${INSTALL_DIR}/gameap-files" genkey -t ed25519 -o "${CONFIG_DIR}/ssh_host_ed25519_key"
fi

# Create default config if not exists
if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
    echo "Creating configuration..."
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
    cert_file: "/etc/gameap-files/tls/server.crt"
    key_file: "/etc/gameap-files/tls/server.key"
    implicit_port: "${FTP_TLS_IMPLICIT_PORT}"
    required: false

sftp:
  enabled: true
  listen_addr: "${SFTP_LISTEN_ADDR}"
  host_key_file: "/etc/gameap-files/ssh/host_ed25519_key"
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
  directory: "/etc/gameap-files/users.d"
  hot_reload: true
EOF
fi

# Install systemd service
echo "Installing systemd service..."
cat > /etc/systemd/system/gameap-files.service << 'EOF'
[Unit]
Description=GameAP Files Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gameap-files serve -c /etc/gameap-files/config.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable gameap-files
systemctl start gameap-files

echo "gameap-files installed successfully!"
