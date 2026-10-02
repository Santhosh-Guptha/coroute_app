#!/usr/bin/env bash
# Run ONCE on the VM after the first install, as root:
#   sudo bash gateway/deploy/post_deploy_hardening.sh
# 1) rotates the JWT secret (all sessions sign out — fine before launch)
# 2) optionally stores a new DuckDNS token (regenerate it at duckdns.org first)
# 3) tightens env-file permissions, pulls the latest code and re-runs the installer
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ENV_FILE=/etc/coroute/gateway.env
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==> Rotating JWT_SECRET"
NEW=$(openssl rand -base64 48 | tr -d '\n')
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$NEW|" "$ENV_FILE"

read -rp "New DuckDNS token (blank to keep current): " TOKEN
if [[ -n "$TOKEN" ]]; then
  cat > /usr/local/bin/update-duckdns.sh <<SH
#!/bin/bash
curl -fsS "https://www.duckdns.org/update?domains=coroute&token=${TOKEN}&ip=" >/dev/null 2>&1
SH
  chmod 700 /usr/local/bin/update-duckdns.sh
  /usr/local/bin/update-duckdns.sh && echo "DuckDNS updated"
fi

read -rp "New Oracle COROUTE password (blank to keep current): " -s OPASS; echo
if [[ -n "$OPASS" ]]; then
  sed -i "s|^ORACLE_PASSWORD=.*|ORACLE_PASSWORD=$OPASS|" "$ENV_FILE"
  echo "Remember to run in Database Actions:  ALTER USER coroute IDENTIFIED BY \"<same password>\";"
fi

chmod 600 "$ENV_FILE"; chown root:coroute "$ENV_FILE"

echo "==> Pulling latest code and re-installing"
if [[ -d "$REPO_DIR/.git" ]]; then (cd "$REPO_DIR" && git pull --ff-only) || true; fi
API_HOST="$(grep -E '^API_HOST=' "$ENV_FILE" | cut -d= -f2-)"
API_HOST="${API_HOST:-coroute.duckdns.org}" bash "$REPO_DIR/gateway/deploy/install.sh"

echo "==> Checks"
curl -fsS "https://${API_HOST:-coroute.duckdns.org}/api/health" && echo
curl -fsS -o /dev/null -w "homepage: %{http_code}\n" "https://${API_HOST:-coroute.duckdns.org}/"
echo "Done. Still to do by hand in Database Actions (as ADMIN):"
echo "  ALTER USER admin IDENTIFIED BY \"<new strong password>\";"
echo "  BEGIN ORDS_ADMIN.ENABLE_SCHEMA(p_enabled => FALSE, p_schema => 'ADMIN'); COMMIT; END; /"
