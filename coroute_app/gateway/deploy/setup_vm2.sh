#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo " Configuring CoRoute Relay VM 2 (129.225.79.93) "
echo "=============================================="

# 1. Swapfile (2GB) for stability
if [ ! -f /swapfile ]; then
  echo "[1/7] Creating 2GB swap space..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
free -h

# 2. System Packages & Node.js 22 LTS
echo "[2/7] Installing base packages and Node.js 22 LTS..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git build-essential ca-certificates iptables-persistent netfilter-persistent >/dev/null

if ! command -v node >/dev/null || [[ "$(node -v | cut -c2-3)" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
echo "Node: $(node -v) | NPM: $(npm -v)"

# 3. Create coroute user & directories
echo "[3/7] Setting up system user and directory..."
if ! id coroute >/dev/null 2>&1; then
  useradd --system --home /opt/coroute --shell /usr/sbin/nologin coroute
fi
mkdir -p /opt/coroute/gateway /etc/coroute /var/log/coroute

# 4. Copy gateway files
echo "[4/7] Deploying gateway code..."
cp -r /home/ubuntu/gateway/* /opt/coroute/gateway/
cd /opt/coroute/gateway
npm install --omit=dev

# 5. Environment configuration
echo "[5/7] Writing /etc/coroute/gateway.env..."
cat > /etc/coroute/gateway.env << 'EOF'
NODE_ENV=production
HOST=0.0.0.0
PORT=3000
ORACLE_SODA_URL=https://gfe473165e66472-coroutedb.adb.ap-hyderabad-1.oraclecloudapps.com/ords/coroute/soda/latest
ORACLE_USER=COROUTE
ORACLE_PASSWORD=DevMonks#Adp2026!Ride
JWT_SECRET=0oFOo4EZMkqdTYW2CcdM3ZUqZUv2NqY8IMCH9UqOJki23ENaBnmFZ/c1CbUbYU65
JWT_TTL_DAYS=30
GOOGLE_CLIENT_IDS=87798956679-ivggpbpote5cf2cvi8mtg8gja3r1sfve.apps.googleusercontent.com
BOOTSTRAP_ADMIN_EMAILS=santhoshbukka5@gmail.com
RETENTION_ENDED_CONVOY_DAYS=90
RETENTION_VOICE_LOG_DAYS=7
RETENTION_STALE_CONVOY_HOURS=36
API_HOST=129.225.79.93
LATEST_APP_BUILD=103
MIN_APP_BUILD=60
GUARDIAN_ENABLED=true
EOF

chmod 600 /etc/coroute/gateway.env
chown -R coroute:coroute /opt/coroute /etc/coroute /var/log/coroute

# 6. Systemd service
echo "[6/7] Setting up coroute-gateway service..."
cat > /etc/systemd/system/coroute-gateway.service << 'EOF'
[Unit]
Description=CoRoute Relay Gateway (Node.js)
After=network.target

[Service]
Type=simple
User=coroute
WorkingDirectory=/opt/coroute/gateway
EnvironmentFile=/etc/coroute/gateway.env
ExecStart=/usr/bin/node src/server.js
Restart=always
RestartSec=5
StandardOutput=append:/var/log/coroute/gateway.log
StandardError=append:/var/log/coroute/gateway-err.log
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable coroute-gateway
systemctl restart coroute-gateway

# 7. Firewall configuration (ports 22, 80, 443, 3000)
echo "[7/7] Configuring firewall..."
for port in 22 80 443 3000; do
  iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $port -j ACCEPT
done
netfilter-persistent save >/dev/null 2>&1 || true

sleep 3
systemctl is-active coroute-gateway.service
echo "Testing local gateway status:"
curl -s http://127.0.0.1:3000/status
echo ""
curl -s http://127.0.0.1:3000/api/meta
echo ""
echo "=== VM 2 SETUP COMPLETED SUCCESSFULLY ==="
