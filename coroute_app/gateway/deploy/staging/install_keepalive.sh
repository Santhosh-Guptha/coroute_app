#!/usr/bin/env bash
# Installs and enables the staging Autonomous Database keep-alive timer.
# Run on vm1 (or any VM with access to /run/coroute/secrets.env and /opt/coroute/gateway).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="/opt/coroute/gateway"

echo "1. Installing scripts/staging_keepalive.js to $GATEWAY_DIR/scripts/..."
SRC="$SCRIPT_DIR/../../scripts/staging_keepalive.js"
DEST="$GATEWAY_DIR/scripts/staging_keepalive.js"
if [ -f "$SRC" ] && [ "$(realpath "$SRC")" != "$(realpath "$DEST" 2>/dev/null || true)" ]; then
  install -o coroute -g coroute -m 0755 "$SRC" "$DEST"
else
  chown coroute:coroute "$DEST"
  chmod 0755 "$DEST"
fi

echo "2. Installing systemd units..."
install -o root -g root -m 0644 "$SCRIPT_DIR/coroute-staging-keepalive.service" /etc/systemd/system/coroute-staging-keepalive.service
install -o root -g root -m 0644 "$SCRIPT_DIR/coroute-staging-keepalive.timer" /etc/systemd/system/coroute-staging-keepalive.timer

echo "3. Reloading systemd and enabling timer..."
systemctl daemon-reload
systemctl enable --now coroute-staging-keepalive.timer

echo "4. Testing one run now..."
systemctl start coroute-staging-keepalive.service
systemctl status coroute-staging-keepalive.service --no-pager

echo "5. Verifying timer status..."
systemctl list-timers --no-pager | grep staging-keepalive || true
echo "INSTALL_KEEPALIVE_OK"
