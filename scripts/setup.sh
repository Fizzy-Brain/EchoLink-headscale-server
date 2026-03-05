#!/usr/bin/env bash
# =============================================================================
# EchoLink Headscale Server — GCP Setup Script
# =============================================================================
# Run this on a fresh GCP e2-micro VM (Debian/Ubuntu).
# Must be run as root: sudo bash setup.sh
#
# What this does:
#   1. Installs the headscale binary
#   2. Creates the headscale system user and directories
#   3. Copies your config and ACL policy to /etc/headscale/
#   4. Installs and starts the systemd service
#   5. Patches the DERP IPv4 in config with the real GCP external IP
#
# Before running:
#   - You must have your domain (echo-link.app) pointing to this VM's IP
#   - Fill in oidc.client_id and oidc.client_secret in config.yaml
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
HEADSCALE_VERSION="0.23.0"   # Change to latest release if needed
HEADSCALE_BIN="/usr/bin/headscale"
CONFIG_DIR="/etc/headscale"
DATA_DIR="/var/lib/headscale"
SERVICE_FILE="/etc/systemd/system/headscale.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# --- Checks ------------------------------------------------------------------
[[ $EUID -ne 0 ]] && fail "Run as root: sudo bash setup.sh"

OS=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
[[ "$OS" != "debian" && "$OS" != "ubuntu" ]] && \
    warn "Tested on Debian/Ubuntu. Your OS ($OS) may need adjustments."

log "Starting EchoLink Headscale setup..."

# --- Detect GCP external IP --------------------------------------------------
log "Detecting public IP from GCP metadata..."
GCP_EXTERNAL_IP=$(curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
    2>/dev/null || curl -sf ifconfig.me 2>/dev/null || echo "")

if [[ -z "$GCP_EXTERNAL_IP" ]]; then
    warn "Could not detect external IP automatically."
    read -rp "Enter this VM's public IP address: " GCP_EXTERNAL_IP
fi
log "Using external IP: $GCP_EXTERNAL_IP"

# --- Validate config exists --------------------------------------------------
[[ ! -f "$REPO_ROOT/config.yaml" ]] && \
    fail "config.yaml not found in $REPO_ROOT. Run from the repo root."

[[ ! -f "$REPO_ROOT/acl-policy.hujson" ]] && \
    fail "acl-policy.hujson not found in $REPO_ROOT."

# Warn if OIDC credentials are still placeholders
if grep -q "your-oidc-client-id" "$REPO_ROOT/config.yaml"; then
    warn "oidc.client_id is still a placeholder in config.yaml!"
    warn "Headscale will start but OIDC login will NOT work."
    warn "Set your real Google OAuth credentials and restart with:"
    warn "  sudo systemctl restart headscale"
fi

# --- Install dependencies ----------------------------------------------------
log "Updating package list..."
apt-get update -qq

log "Installing dependencies..."
apt-get install -y -qq curl wget

# --- Download headscale binary -----------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_TAG="amd64" ;;
    aarch64) ARCH_TAG="arm64" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
esac

DOWNLOAD_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_${ARCH_TAG}"

if [[ -f "$HEADSCALE_BIN" ]]; then
    INSTALLED_VER=$("$HEADSCALE_BIN" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    if [[ "$INSTALLED_VER" == "$HEADSCALE_VERSION" ]]; then
        log "headscale v$HEADSCALE_VERSION already installed, skipping download."
    else
        warn "Upgrading headscale from $INSTALLED_VER to $HEADSCALE_VERSION..."
        systemctl stop headscale 2>/dev/null || true
        wget -qO "$HEADSCALE_BIN" "$DOWNLOAD_URL"
        chmod +x "$HEADSCALE_BIN"
    fi
else
    log "Downloading headscale v$HEADSCALE_VERSION ($ARCH_TAG)..."
    wget -qO "$HEADSCALE_BIN" "$DOWNLOAD_URL"
    chmod +x "$HEADSCALE_BIN"
fi

log "Headscale binary: $("$HEADSCALE_BIN" version)"

# --- Create headscale system user --------------------------------------------
if ! id "headscale" &>/dev/null; then
    log "Creating headscale system user..."
    useradd \
        --system \
        --no-create-home \
        --shell /sbin/nologin \
        headscale
else
    log "headscale user already exists."
fi

# --- Create directories ------------------------------------------------------
log "Creating directories..."

mkdir -p "$CONFIG_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/cache"   # For Let's Encrypt certificate cache

chown -R headscale:headscale "$DATA_DIR"
chmod 750 "$DATA_DIR"
chmod 750 "$CONFIG_DIR"

# --- Copy config files -------------------------------------------------------
log "Copying config.yaml to $CONFIG_DIR/..."

# Patch the DERP IPv4 placeholder with the real external IP before copying
TMP_CONFIG=$(mktemp)
sed "s/198\.51\.100\.1/$GCP_EXTERNAL_IP/g" "$REPO_ROOT/config.yaml" > "$TMP_CONFIG"

# Also remove the placeholder IPv6 DERP line if it still has the example value.
# The embedded DERP works fine with IPv4 only.
sed -i '/ipv6: 2001:db8::1/d' "$TMP_CONFIG"

cp "$TMP_CONFIG" "$CONFIG_DIR/config.yaml"
rm -f "$TMP_CONFIG"

chown headscale:headscale "$CONFIG_DIR/config.yaml"
chmod 640 "$CONFIG_DIR/config.yaml"

log "Copying acl-policy.hujson to $CONFIG_DIR/..."
cp "$REPO_ROOT/acl-policy.hujson" "$CONFIG_DIR/acl-policy.hujson"
chown headscale:headscale "$CONFIG_DIR/acl-policy.hujson"
chmod 640 "$CONFIG_DIR/acl-policy.hujson"

# --- Install systemd service --------------------------------------------------
log "Installing systemd service..."
cp "$REPO_ROOT/packaging/systemd/headscale.service" "$SERVICE_FILE"

# Update service description to EchoLink branding
sed -i 's/headscale coordination server for Tailscale/EchoLink — Headscale Coordination Server/' "$SERVICE_FILE"

systemctl daemon-reload

# --- Enable and start --------------------------------------------------------
log "Enabling headscale service..."
systemctl enable headscale

if systemctl is-active --quiet headscale; then
    log "Reloading headscale (already running)..."
    systemctl reload headscale
else
    log "Starting headscale..."
    systemctl start headscale
fi

sleep 2

# --- Status check ------------------------------------------------------------
echo ""
if systemctl is-active --quiet headscale; then
    log "Headscale is running."
    systemctl status headscale --no-pager -l | tail -5
else
    fail "Headscale failed to start. Check logs: journalctl -u headscale -n 50"
fi

# --- GCP Firewall Reminder ---------------------------------------------------
echo ""
echo "=================================================================="
echo "  GCP FIREWALL RULES REQUIRED"
echo "  Run these in GCP Console > VPC Network > Firewall rules,"
echo "  or via gcloud CLI:"
echo ""
echo "  gcloud compute firewall-rules create echolink-http \\"
echo "    --allow tcp:80 --description='Let'\''s Encrypt challenge'"
echo ""
echo "  gcloud compute firewall-rules create echolink-https \\"
echo "    --allow tcp:443 --description='Headscale HTTPS + DERP'"
echo ""
echo "  gcloud compute firewall-rules create echolink-stun \\"
echo "    --allow udp:3478 --description='STUN NAT traversal'"
echo ""
echo "  gcloud compute firewall-rules create echolink-wireguard \\"
echo "    --allow udp:41641 --description='WireGuard direct'"
echo "=================================================================="
echo ""

# --- Next Steps --------------------------------------------------------------
echo "=================================================================="
echo "  SETUP COMPLETE"
echo ""
echo "  External IP  : $GCP_EXTERNAL_IP"
echo "  Server URL   : $(grep '^server_url' "$CONFIG_DIR/config.yaml" | awk '{print $2}')"
echo "  Config       : $CONFIG_DIR/config.yaml"
echo "  ACL Policy   : $CONFIG_DIR/acl-policy.hujson"
echo "  Database     : $DATA_DIR/db.sqlite"
echo "  Logs         : journalctl -u headscale -f"
echo ""
echo "  Remaining steps:"
if grep -q "your-oidc-client-id" "$CONFIG_DIR/config.yaml"; then
echo "  [ ] Set oidc.client_id + oidc.client_secret in config.yaml"
echo "      then: sudo systemctl restart headscale"
else
echo "  [x] OIDC credentials configured"
fi
echo "  [ ] Open GCP firewall ports (see above)"
echo "  [ ] Verify TLS: curl -I https://echo-link.app"
echo "  [ ] Test OIDC login from a Tailscale client"
echo "=================================================================="
