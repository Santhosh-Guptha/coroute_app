#!/usr/bin/env bash
# vm3 DR warm standby (v3.56). Run ON vm3 from an unpacked release (or the repo):  sudo bash deploy/dr/install_standby.sh
#
#   SECRETS_MODE=vault   tenancy-2 Vault copies of the secrets, read with vm3's instance principal (recommended: still works
#                        when tenancy 1 is suspended). Fill /etc/coroute/secret_ids.env with the TENANCY-2 secret OCIDs.
#   SECRETS_MODE=file    /etc/coroute/dr-secrets.env (0600) copied by the operator from vm2 over SSH (RUNBOOK "DR: secrets").
#   DR_TLS=dns           pre-provision both certificates now (needs the caddy-dns/duckdns build + DUCKDNS_TOKEN): default
#   DR_TLS=http          keep vm3's current Caddyfile; promote_vm3.sh installs Caddyfile.vm3-dr-http at promotion
#   STANDBY_RUN=1        keep the gateway running as GATEWAY_ROLE=standby (proves it boots against the database; no
#                        scheduled jobs, /api/health/live 503). STANDBY_RUN=0 installs it stopped (cold, less RAM).
#
# Then deploy the code with deploy/release.sh --with-dr (or remote_release.sh install ... standby) and start it.
# Idempotent. Never prints secrets. The ADB ACL must allow vm3's public IP (deploy/update_adb_acl.py).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # .../deploy
SECRETS_MODE="${SECRETS_MODE:-file}"; DR_TLS="${DR_TLS:-dns}"; STANDBY_RUN="${STANDBY_RUN:-1}"
PUBLIC_ORIGIN="${PUBLIC_ORIGIN:-https://coroute.devmonks.space}"
log() { echo "==> $*"; }
command -v node >/dev/null && node -v | grep -qE '^v(2[0-9])\.' || { echo "Node 20+ required (vm3 has Node 22)" >&2; exit 1; }

log "user and directories"
id coroute >/dev/null 2>&1 || useradd --system --home-dir /opt/coroute --shell /usr/sbin/nologin coroute
install -d -m 0755 /opt/coroute /opt/coroute/releases
install -d -o coroute -g coroute -m 0750 /opt/coroute/shared /opt/coroute/shared/data /var/lib/coroute
install -d -o root -g coroute -m 0750 /etc/coroute

log "/etc/coroute/gateway.env (settings only; GATEWAY_ROLE=standby)"
ENV=/etc/coroute/gateway.env
[ -f "$ENV" ] || { grep -vE '^(JWT_SECRET|JWT_SECRET_PREVIOUS|ORACLE_PASSWORD|RAZORPAY_[A-Z_]*(SECRET|KEY_ID)|SETTINGS_ENCRYPTION_KEY|DATA_ENC_KEY|DATA_ENC_KEYS_PREVIOUS|BLIND_INDEX_KEY|BACKUP_ENCRYPTION_KEY|BACKUP_PAR_URL|REVIEW_PHOTO_PAR_URL|MIRROR_KEY|DUCKDNS_TOKEN|TWILIO_AUTH_TOKEN|AWS_SECRET_ACCESS_KEY|INFOBIP_API_KEY|TELEPHONY_WEBHOOK_TOKEN|WHATSAPP_API_TOKEN|GUARDIAN_VAPID_PRIVATE_KEY|SMTP_PASS|SMTP_PASSWORD)=' "$SRC/.env.example" 2>/dev/null | sed -E '/^[A-Z_]+=/s/[[:space:]]+#.*$//' > "$ENV" || echo NODE_ENV=production > "$ENV"; }
set_kv() { if grep -qE "^$1=" "$ENV"; then sed -i -E "s|^$1=.*|$1=$2|" "$ENV"; else echo "$1=$2" >> "$ENV"; fi; }
set_kv NODE_ENV production; set_kv HOST 127.0.0.1; set_kv PORT 3000; set_kv NODE_NAME vm3; set_kv GATEWAY_ROLE standby
set_kv PUBLIC_ORIGIN "$PUBLIC_ORIGIN"; set_kv TRUST_PROXY loopback; set_kv NODE_COMPRESSION off; set_kv WS_DEFLATE off
sed -i -E '/^MIRROR_(LISTEN_HOST|PEER_URL)=/d' "$ENV"   # vm3 is not part of the vm1/vm2 mirror pair
chown root:coroute "$ENV"; chmod 0640 "$ENV"
echo "   copy the non-secret production settings (SMTP_HOST, MAIL_FROM, ORACLE_SODA_URL, ORACLE_USER, GOOGLE_CLIENT_IDS, ...) from vm2's gateway.env, keeping the lines above"

log "systemd units (gateway, secrets: mode $SECRETS_MODE)"
install -m 0644 "$SRC/coroute-gateway.service" /etc/systemd/system/coroute-gateway.service
install -m 0644 "$SRC/coroute-secrets.service" /etc/systemd/system/coroute-secrets.service
install -d /etc/systemd/system/coroute-secrets.service.d /etc/systemd/system/coroute-gateway.service.d
install -d -m 0755 /opt/coroute/dr
install -m 0755 "$SRC/dr/file_secrets.sh" /opt/coroute/dr/file_secrets.sh
if [ "$SECRETS_MODE" = file ]; then
  printf '[Service]\nExecStart=\nExecStart=/opt/coroute/dr/file_secrets.sh\n' > /etc/systemd/system/coroute-secrets.service.d/10-dr-file.conf
  [ -f /etc/coroute/dr-secrets.env ] || { install -m 0600 /dev/null /etc/coroute/dr-secrets.env; echo "   /etc/coroute/dr-secrets.env created EMPTY: fill it (RUNBOOK 'DR: secrets') before starting"; }
else
  rm -f /etc/systemd/system/coroute-secrets.service.d/10-dr-file.conf
  [ -x /usr/local/bin/oci ] || { python3 -m venv /opt/oci-cli && /opt/oci-cli/bin/pip install -q --upgrade pip oci-cli && ln -sf /opt/oci-cli/bin/oci /usr/local/bin/oci; }
  [ -f /etc/coroute/secret_ids.env ] || { install -m 0640 /dev/null /etc/coroute/secret_ids.env; echo "   fill /etc/coroute/secret_ids.env with the TENANCY-2 Vault secret OCIDs (NAME=ocid1.vaultsecret...)"; }
fi
# The secrets unit needs fetch_secrets.sh at the path in coroute-secrets.service even before the first release.
install -d -m 0755 /opt/coroute/gateway-bootstrap/deploy && install -m 0755 "$SRC/fetch_secrets.sh" /opt/coroute/gateway-bootstrap/deploy/fetch_secrets.sh
[ -e /opt/coroute/gateway ] || ln -sfn /opt/coroute/gateway-bootstrap /opt/coroute/gateway
install -d /etc/systemd/system/caddy.service.d
printf '[Unit]\nWants=coroute-secrets.service\nAfter=coroute-secrets.service\n[Service]\nEnvironmentFile=-/run/coroute/caddy.env\n' > /etc/systemd/system/caddy.service.d/coroute.conf
systemctl daemon-reload
systemctl enable coroute-secrets.service >/dev/null
if [ "$STANDBY_RUN" = 1 ]; then systemctl enable coroute-gateway.service >/dev/null; else systemctl disable coroute-gateway.service >/dev/null 2>&1 || true; fi

log "Caddy (DR_TLS=$DR_TLS)"
if [ "$DR_TLS" = dns ]; then
  if ! caddy list-modules 2>/dev/null | grep -q '^dns.providers.duckdns$'; then
    ARCH="$(dpkg --print-architecture)"
    curl -fsSL -o /usr/bin/caddy.custom "https://caddyserver.com/api/download?os=linux&arch=${ARCH}&p=github.com%2Fcaddy-dns%2Fduckdns"
    chmod 755 /usr/bin/caddy.custom
    /usr/bin/caddy.custom list-modules | grep -q '^dns.providers.duckdns$' || { echo "custom Caddy lacks duckdns" >&2; exit 1; }
    [ -e /usr/bin/caddy.default ] || dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy
    update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10 >/dev/null
    update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50 >/dev/null
    update-alternatives --set caddy /usr/bin/caddy.custom >/dev/null
  fi
  [ -f /etc/caddy/Caddyfile.pre-dr ] || cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-dr 2>/dev/null || true
  install -m 0644 "$SRC/caddy/Caddyfile.vm3-dr" /etc/caddy/Caddyfile
  echo "   /etc/caddy/Caddyfile = Caddyfile.vm3-dr (old one kept as Caddyfile.pre-dr). Reload after the secrets are in place:"
  echo "   systemctl restart coroute-secrets && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy"
else
  echo "   Caddyfile unchanged (HTTP-01 certificates can only be issued after the DNS switch: promote_vm3.sh --tls http)"
fi

log "watchdog and backups (units installed, configured by their env files)"
install -d -m 0755 /opt/coroute/watchdog
install -m 0755 "$SRC/watchdog/coroute_watchdog.js" /opt/coroute/watchdog/coroute_watchdog.js
install -m 0644 "$SRC/watchdog/coroute-watchdog.service" /etc/systemd/system/coroute-watchdog.service
[ -f /etc/coroute/watchdog.env ] || install -m 0640 -o root -g coroute "$SRC/watchdog/watchdog.example.env" /etc/coroute/watchdog.env
install -m 0755 "$SRC/nightly_backup.py" /opt/coroute/nightly_backup.py
install -m 0644 "$SRC/backup/coroute-backup.service" "$SRC/backup/coroute-backup.timer" /etc/systemd/system/
[ -f /etc/coroute/backup.env ] || install -m 0600 "$SRC/backup/backup.example.env" /etc/coroute/backup.env
systemctl daemon-reload
echo
echo "vm3 standby installed. Next (RUNBOOK 'DR and failover'):"
echo "  1. fill secrets ($SECRETS_MODE) and the non-secret settings in $ENV; add vm3's public IP to the ADB ACL"
echo "  2. deploy the code: gateway/deploy/release.sh --only vm3   (or remote_release.sh install <bundle> <id> <version> standby)"
echo "  3. systemctl restart coroute-secrets && systemctl start coroute-gateway && curl -s 127.0.0.1:3000/api/health"
echo "  4. edit /etc/coroute/watchdog.env, then systemctl enable --now coroute-watchdog"
echo "  5. edit /etc/coroute/backup.env, then systemctl enable --now coroute-backup.timer"
