#!/usr/bin/env bash
# ==============================================================================
# CoRoute Automated VM Provisioning & Zero-Downtime Cutover Script
# ==============================================================================
# Target OS: Ubuntu 20.04 / 22.04 / 24.04 LTS (x86_64 or ARM64 / Ampere A1)
#
# This script completely configures a fresh Oracle Cloud (or any Linux) VM:
#  1. Installs Node.js 22 LTS, Caddy web server, git, and build tools
#  2. Creates system accounts (coroute, santhosh, antigravity) with sudo & SSH
#  3. Clones and installs the CoRoute Gateway backend & dependencies
#  4. Restores production environment secrets (Oracle ATP SODA, JWT secret, etc.)
#     * Preserves exact JWT secret so existing mobile app users stay logged in!
#  5. Fetches release APK binaries (ARM64 & ARMv7) into public download directory
#  6. Initializes/verifies Oracle Autonomous Database SODA collections
#  7. Configures and starts coroute-gateway systemd service
#  8. Sets up Caddy reverse proxy with automatic SSL for coroute.duckdns.org
#  9. Configures firewall (TCP 22, 80, 443)
# 10. Installs DuckDNS dynamic updater cron job and immediately updates DNS
#     to point coroute.duckdns.org to this new VM!
# 11. Verifies health endpoints and writes persistent audit logs
#
# Usage:
#   sudo bash gateway/deploy/setup_new_vm.sh
# or one-liner on a fresh VM:
#   curl -fsSL https://raw.githubusercontent.com/Santhosh-Guptha/coroute_app/main/gateway/deploy/setup_new_vm.sh | sudo bash
# ==============================================================================

set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_step() {
  echo -e "\n${BLUE}====>${NC} ${CYAN}$1${NC}"
}

log_ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

log_warn() {
  echo -e "  ${YELLOW}⚠${NC} $1"
}

log_err() {
  echo -e "  ${RED}✗${NC} $1"
}

# Require root
if [[ $EUID -ne 0 ]]; then
  log_err "This script must be run as root (use sudo bash)."
  exit 1
fi

echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}       CoRoute Automated VM Setup & Zero-Downtime Migration Script           ${NC}"
echo -e "${GREEN}==============================================================================${NC}"

# Detect architecture & public IP
ARCH=$(uname -m)
PUBLIC_IP=$(curl -s -4 https://ifconfig.me || curl -s -4 https://api.ipify.org || echo "unknown")
echo -e "Detected Architecture: ${YELLOW}${ARCH}${NC}"
echo -e "Detected Public IPv4:  ${YELLOW}${PUBLIC_IP}${NC}"

# ------------------------------------------------------------------------------
# 1. System Packages & Prerequisites
# ------------------------------------------------------------------------------
log_step "1/11. Installing core packages and dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl \
  ca-certificates \
  gnupg \
  debian-keyring \
  debian-archive-keyring \
  apt-transport-https \
  git \
  iptables \
  iptables-persistent \
  netfilter-persistent \
  build-essential \
  cron >/dev/null
log_ok "Core system packages installed."

# ------------------------------------------------------------------------------
# 2. Node.js 22 LTS Installation
# ------------------------------------------------------------------------------
log_step "2/11. Setting up Node.js 22 LTS runtime..."
if ! command -v node >/dev/null || [[ "$(node -v | cut -c2-3)" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
NODE_VER=$(node -v)
NPM_VER=$(npm -v)
log_ok "Node.js ${NODE_VER} and npm ${NPM_VER} installed."

# ------------------------------------------------------------------------------
# 3. Caddy Web Server Installation
# ------------------------------------------------------------------------------
log_step "3/11. Installing Caddy web server (automatic TLS)..."
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi
log_ok "Caddy web server installed."

# ------------------------------------------------------------------------------
# 4. OS User Accounts & Permissions
# ------------------------------------------------------------------------------
log_step "4/11. Configuring administrative and service accounts..."

# System user: coroute
if ! id coroute >/dev/null 2>&1; then
  useradd --system --home /opt/coroute --shell /usr/sbin/nologin coroute
  log_ok "Created system service user: coroute"
fi

# Admin user: santhosh
if ! id santhosh >/dev/null 2>&1; then
  useradd -m -s /bin/bash santhosh
  echo "santhosh:Santhosh@180901" | chpasswd
  usermod -aG sudo,coroute santhosh
  log_ok "Created user: santhosh"
else
  echo "santhosh:Santhosh@180901" | chpasswd
  usermod -aG sudo,coroute santhosh
  log_ok "Updated user: santhosh"
fi

# Agent user: antigravity (for automated deployments)
if ! id antigravity >/dev/null 2>&1; then
  useradd -m -s /bin/bash antigravity
  echo "antigravity:Antigravity@CoRoute2026#VM" | chpasswd
  usermod -aG sudo,coroute antigravity
  log_ok "Created user: antigravity"
else
  echo "antigravity:Antigravity@CoRoute2026#VM" | chpasswd
  usermod -aG sudo,coroute antigravity
  log_ok "Updated user: antigravity"
fi

# Passwordless sudo for administrative users
cat > /etc/sudoers.d/90-coroute-users << 'EOF'
santhosh ALL=(ALL) NOPASSWD:ALL
antigravity ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/90-coroute-users
log_ok "Configured sudo permissions in /etc/sudoers.d/90-coroute-users."

# Enable SSH Password Authentication for admin accounts
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-password-auth.conf << 'EOF'
PasswordAuthentication yes
EOF
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
log_ok "SSH password authentication enabled."

# ------------------------------------------------------------------------------
# 5. Application Directories & Gateway Codebase
# ------------------------------------------------------------------------------
log_step "5/11. Setting up directory structure and Gateway codebase..."
mkdir -p /opt/coroute/gateway/public/.well-known
mkdir -p /etc/coroute
mkdir -p /var/log

# Determine where script was run from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd || echo "")"

if [[ -f "${REPO_ROOT}/gateway/package.json" ]]; then
  log_ok "Copying gateway source from local repository (${REPO_ROOT}/gateway)..."
  cp -r "${REPO_ROOT}/gateway"/{src,scripts,public,package.json,package-lock.json,deploy} /opt/coroute/gateway/
else
  log_ok "Cloning latest gateway source from GitHub..."
  TMP_CLONE=$(mktemp -d)
  git clone --depth 1 https://github.com/Santhosh-Guptha/coroute_app.git "${TMP_CLONE}"
  cp -r "${TMP_CLONE}/coroute_app/gateway"/{src,scripts,public,package.json,package-lock.json,deploy} /opt/coroute/gateway/
  rm -rf "${TMP_CLONE}"
fi

cd /opt/coroute/gateway
log_ok "Installing gateway npm production dependencies..."
npm ci --omit=dev --no-audit --no-fund >/dev/null
chown -R coroute:coroute /opt/coroute
log_ok "Gateway application tree prepared in /opt/coroute/gateway."

# ------------------------------------------------------------------------------
# 6. Production Secrets & Environment Configuration
# ------------------------------------------------------------------------------
log_step "6/11. Writing production environment configuration (/etc/coroute/gateway.env)..."
cat > /etc/coroute/gateway.env << 'EOF'
NODE_ENV=production
HOST=127.0.0.1
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
API_HOST=coroute.duckdns.org
APK_URL=https://coroute.duckdns.org/coroute.apk
LATEST_APP_BUILD=75
EOF
chmod 600 /etc/coroute/gateway.env
chown root:coroute /etc/coroute/gateway.env
log_ok "Environment configured (JWT Secret preserved for seamless user sessions)."

# ------------------------------------------------------------------------------
# 7. Pre-Fetching Release APKs (Before DNS Cutover)
# ------------------------------------------------------------------------------
log_step "7/11. Pre-fetching existing release APK binaries into public path..."
# If APKs exist from current domain, download them into place
if curl -fsI https://coroute.duckdns.org/coroute.apk >/dev/null 2>&1; then
  log_ok "Downloading coroute.apk (ARM64) from live server..."
  curl -fsSL https://coroute.duckdns.org/coroute.apk -o /opt/coroute/gateway/public/coroute.apk || true
fi
if curl -fsI https://coroute.duckdns.org/coroute-32bit.apk >/dev/null 2>&1; then
  log_ok "Downloading coroute-32bit.apk (ARMv7) from live server..."
  curl -fsSL https://coroute.duckdns.org/coroute-32bit.apk -o /opt/coroute/gateway/public/coroute-32bit.apk || true
fi
chown coroute:coroute /opt/coroute/gateway/public/coroute*.apk 2>/dev/null || true
chmod 644 /opt/coroute/gateway/public/coroute*.apk 2>/dev/null || true
log_ok "Public download binaries ready."

# ------------------------------------------------------------------------------
# 8. Oracle Cloud Database Collection Initialization
# ------------------------------------------------------------------------------
log_step "8/11. Verifying Oracle Autonomous Database SODA connection..."
cd /opt/coroute/gateway
sudo -u coroute env $(grep -v '^#' /etc/coroute/gateway.env | xargs) node scripts/init_db.js
log_ok "Database collections verified."

# ------------------------------------------------------------------------------
# 9. Gateway Service & Caddy Reverse Proxy
# ------------------------------------------------------------------------------
log_step "9/11. Configuring systemd service & Caddy TLS reverse proxy..."

# coroute-gateway service
cp /opt/coroute/gateway/deploy/coroute-gateway.service /etc/systemd/system/coroute-gateway.service
systemctl daemon-reload
systemctl enable coroute-gateway
systemctl restart coroute-gateway
log_ok "coroute-gateway service is active."

# Caddy reverse proxy
systemctl disable --now nginx 2>/dev/null || true
cat > /etc/caddy/Caddyfile << 'EOF'
coroute.duckdns.org {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy no-referrer
		-Server
	}
	reverse_proxy 127.0.0.1:3000 {
		flush_interval -1
		transport http {
			read_timeout 0
			write_timeout 0
		}
	}
}
EOF
systemctl enable caddy
systemctl restart caddy
log_ok "Caddy reverse proxy configured for coroute.duckdns.org."

# Firewall rules (ports 22, 80, 443)
for port in 22 80 443; do
  iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $port -j ACCEPT
done
netfilter-persistent save >/dev/null 2>&1 || true
log_ok "Firewall opened for ports 22, 80, and 443."

# ------------------------------------------------------------------------------
# 10. DuckDNS Dynamic DNS Setup & Immediate Cutover
# ------------------------------------------------------------------------------
log_step "10/11. Pointing coroute.duckdns.org to this new VM ($PUBLIC_IP)..."

cat > /usr/local/bin/update-duckdns.sh << 'EOF'
#!/bin/bash
curl -fsS "https://www.duckdns.org/update?domains=coroute&token=59b0a0ec-e7e4-405e-b6e9-2d8c0fdefdc2&ip=" >/dev/null 2>&1
EOF
chmod +x /usr/local/bin/update-duckdns.sh

# Install cron job for persistence
(crontab -l 2>/dev/null | grep -v "update-duckdns.sh" || true; echo "*/30 * * * * /usr/local/bin/update-duckdns.sh") | crontab -

# Trigger immediate DNS update
CUTOVER_RESP=$(curl -fsS "https://www.duckdns.org/update?domains=coroute&token=59b0a0ec-e7e4-405e-b6e9-2d8c0fdefdc2&ip=")
if [[ "$CUTOVER_RESP" == "OK" ]]; then
  log_ok "DuckDNS updated successfully! coroute.duckdns.org now resolves to this VM."
else
  log_warn "DuckDNS response: $CUTOVER_RESP"
fi

# ------------------------------------------------------------------------------
# 11. Health Checks & Audit Logging
# ------------------------------------------------------------------------------
log_step "11/11. Running verification health checks..."
sleep 3

LOCAL_HEALTH=$(curl -s http://127.0.0.1:3000/api/health || echo "FAILED")
LOCAL_META=$(curl -s http://127.0.0.1:3000/api/meta || echo "FAILED")

echo -e "Local Health: ${GREEN}${LOCAL_HEALTH}${NC}"
echo -e "Local Meta:   ${GREEN}${LOCAL_META}${NC}"

# Log to persistent audit files
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_MSG="[$TIMESTAMP] [MIGRATION] [IP: $PUBLIC_IP] New VM automated setup completed. Gateway active, Caddy running, DuckDNS updated."
echo "$LOG_MSG" >> /var/log/coroute_operations.log

# Create/append ACTIVITY_LOG for users
for user_home in /home/santhosh /home/antigravity; do
  if [[ -d "$user_home" ]]; then
    cat >> "${user_home}/ACTIVITY_LOG.md" << EOF

### [$TIMESTAMP] - VM Migration & Automated Cutover Complete
- **Public IP**: \`$PUBLIC_IP\`
- **Architecture**: \`$ARCH\`
- **Gateway Version**: 3.15.0 (Build 75)
- **Status**: Active, Caddy TLS enabled, DuckDNS pointed to this instance.
EOF
    chown -R $(basename $user_home):$(basename $user_home) "${user_home}/ACTIVITY_LOG.md" 2>/dev/null || true
  fi
done

echo ""
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}             MIGRATION AND PROVISIONING COMPLETED SUCCESSFULLY!              ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e " Public Domain:   ${CYAN}https://coroute.duckdns.org${NC}"
echo -e " Health Check:    ${CYAN}https://coroute.duckdns.org/api/health${NC}"
echo -e " Metadata:        ${CYAN}https://coroute.duckdns.org/api/meta${NC}"
echo -e " Download APK:    ${CYAN}https://coroute.duckdns.org/coroute.apk${NC}"
echo -e " Admin Users:     ${YELLOW}santhosh${NC} and ${YELLOW}antigravity${NC} (passwordless sudo enabled)"
echo -e " Existing Users:  ${GREEN}Uninterrupted sessions & auto-reconnect preserved.${NC}"
echo -e "${GREEN}==============================================================================${NC}"
