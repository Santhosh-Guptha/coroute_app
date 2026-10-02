#!/usr/bin/env bash
# One-shot installer / upgrader for the CoRoute gateway on an Ubuntu OCI VM.
# Usage (from a copy of the repo on the VM):
#   sudo API_HOST=coroute.duckdns.org [DUCKDNS_TOKEN=xxxx] bash gateway/deploy/install.sh
# Idempotent: re-running upgrades the code and restarts the service. Secrets are
# asked for only the first time and stored in /etc/coroute/gateway.env (chmod 600).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
API_HOST="${API_HOST:-}"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/coroute/gateway.env

echo "==> Packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https >/dev/null
if ! command -v node >/dev/null || [[ "$(node -v | cut -c2-3)" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq && apt-get install -y -qq caddy >/dev/null
fi

echo "==> User and directories"
id coroute >/dev/null 2>&1 || useradd --system --home /opt/coroute --shell /usr/sbin/nologin coroute
mkdir -p /opt/coroute/gateway /etc/coroute

echo "==> Code"
cp -r "$SRC_DIR"/{src,scripts,public,package.json,package-lock.json} /opt/coroute/gateway/
cd /opt/coroute/gateway && npm ci --omit=dev --no-audit --no-fund >/dev/null
chown -R coroute:coroute /opt/coroute

if [[ ! -f "$ENV_FILE" ]]; then
  echo "==> First-time configuration"
  read -rp "Oracle SODA URL (…/ords/coroute/soda/latest): " SODA
  read -rp "Oracle schema user [COROUTE]: " OUSER; OUSER="${OUSER:-COROUTE}"
  read -rsp "Oracle schema password: " OPASS; echo
  read -rp "Google OAuth web client ID(s), comma separated (blank to disable Google Sign-In): " GIDS
  read -rp "Bootstrap admin e-mail(s), comma separated: " ADMINS
  [[ -n "$API_HOST" ]] || read -rp "Public API hostname (DNS → this VM): " API_HOST
  cat > "$ENV_FILE" <<ENV
NODE_ENV=production
HOST=127.0.0.1
PORT=3000
ORACLE_SODA_URL=$SODA
ORACLE_USER=$OUSER
ORACLE_PASSWORD=$OPASS
JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
JWT_TTL_DAYS=30
GOOGLE_CLIENT_IDS=$GIDS
BOOTSTRAP_ADMIN_EMAILS=$ADMINS
RETENTION_ENDED_CONVOY_DAYS=90
RETENTION_VOICE_LOG_DAYS=7
RETENTION_STALE_CONVOY_HOURS=36
API_HOST=$API_HOST
ENV
  chmod 600 "$ENV_FILE"; chown root:coroute "$ENV_FILE"
else
  API_HOST="${API_HOST:-$(grep -E '^API_HOST=' "$ENV_FILE" | cut -d= -f2-)}"
fi
[[ -n "$API_HOST" ]] || { echo "API_HOST missing"; exit 1; }

echo "==> Database collections/indexes"
sudo -u coroute env $(grep -v '^#' "$ENV_FILE" | xargs) node scripts/init_db.js

echo "==> systemd"
cp "$SRC_DIR/deploy/coroute-gateway.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now coroute-gateway
systemctl restart coroute-gateway

if [[ -n "${DUCKDNS_TOKEN:-}" ]]; then
  DUCK_HOST=$(tr ',' '\n' <<<"$API_HOST" | tr -d ' ' | grep '\.duckdns\.org$' | head -1 || true)
  if [[ -n "$DUCK_HOST" ]]; then
    echo "==> DuckDNS: pointing $DUCK_HOST at this VM's public IP"
    curl -fsS "https://www.duckdns.org/update?domains=${DUCK_HOST%%.duckdns.org}&token=${DUCKDNS_TOKEN}&ip=" && echo
  fi
fi

echo "==> Caddy (TLS for $API_HOST)"
systemctl disable --now nginx 2>/dev/null || true
sed "s|api.coroute.example.com|$API_HOST|" "$SRC_DIR/deploy/Caddyfile" > /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy

echo "==> Firewall (iptables, persisted if netfilter-persistent exists)"
for p in 80 443; do iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $p -j ACCEPT; done
command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null || true

sleep 2
echo "==> Health"
curl -fsS http://127.0.0.1:3000/api/health && echo
FIRST_HOST="${API_HOST%%,*}"; FIRST_HOST="${FIRST_HOST// /}"
echo "Done. Website: https://$FIRST_HOST/   API: https://$FIRST_HOST/api/health   (TLS certificate is issued on first request; allow ~30 s)"
echo "Privacy: https://$FIRST_HOST/privacy   Terms: https://$FIRST_HOST/terms"
