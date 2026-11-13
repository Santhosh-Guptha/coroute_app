#!/usr/bin/env bash
# Idempotent provisioning of one CoRoute gateway node on a fresh Ubuntu 22.04/24.04 OCI VM (micro or A1).
# Contains no secrets: secrets come from OCI Vault at boot (coroute-secrets.service -> deploy/fetch_secrets.sh).
#
#   sudo NODE_NAME=vm1 NODE_ROLE=live NODE_IP=<vm1-private-ip> PEER_IP=<vm2-private-ip> bash deploy/setup_node.sh
#   sudo NODE_NAME=vm2 NODE_ROLE=web  NODE_IP=<vm2-private-ip> PEER_IP=<vm1-private-ip> bash deploy/setup_node.sh
#
# Installs: Node 22, Caddy with the DuckDNS DNS module, OCI CLI, chrony, unattended security upgrades,
# a 2 GB swap file, the coroute user and directories, systemd units, the node's Caddyfile, firewall rules
# (443/80 public; 3000 and 3101 from PEER_IP only). Safe to re-run (e.g. after changing the role).
# Code: copy the gateway to /opt/coroute/gateway (see the runbook) before starting the gateway.
set -euo pipefail

NODE_NAME="${NODE_NAME:?set NODE_NAME (vm1 / vm2)}"
NODE_ROLE="${NODE_ROLE:?set NODE_ROLE (live / web)}"
NODE_IP="${NODE_IP:?set NODE_IP (this VM private IP)}"
PEER_IP="${PEER_IP:?set PEER_IP (the other VM private IP)}"
DOMAIN="${DOMAIN:-coroute.duckdns.org}"
# Canonical origin for generated links. During the domain move: PUBLIC_ORIGIN=https://coroute.devmonks.space
# (docs/DOMAIN_MIGRATION_devmonks.md); the Caddyfiles serve both names whatever DOMAIN is.
PUBLIC_ORIGIN="${PUBLIC_ORIGIN:-https://$DOMAIN}"
APP_DIR=/opt/coroute/gateway
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../gateway/deploy
case "$NODE_ROLE" in live|web) ;; *) echo "NODE_ROLE must be live or web" >&2; exit 1;; esac
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
log() { echo "==> $*"; }
export DEBIAN_FRONTEND=noninteractive
ARCH="$(dpkg --print-architecture)"   # amd64 (E2.1.Micro) or arm64 (A1.Flex)

log "packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg jq unattended-upgrades chrony python3-venv \
  debian-keyring debian-archive-keyring apt-transport-https iptables-persistent netfilter-persistent >/dev/null
systemctl enable --now chrony >/dev/null 2>&1 || true   # job leases compare wall clocks across the VMs

log "swap (2 GB)"
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  [ -f /swapfile ] || { fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048; }
  chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
cat > /etc/sysctl.d/90-coroute.conf <<'SYS'
vm.swappiness=10
net.core.somaxconn=4096
net.ipv4.tcp_keepalive_time=120
SYS
sysctl --system >/dev/null

log "Node.js 22"
if ! node -v 2>/dev/null | grep -q '^v22\.'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi

log "Caddy (+ github.com/caddy-dns/duckdns)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq && apt-get install -y -qq caddy >/dev/null
fi
if ! caddy list-modules 2>/dev/null | grep -q '^dns.providers.duckdns$'; then
  # The packaged binary stays as caddy.default; the custom build (same version line + duckdns) wins.
  curl -fsSL -o /usr/bin/caddy.custom "https://caddyserver.com/api/download?os=linux&arch=${ARCH}&p=github.com%2Fcaddy-dns%2Fduckdns"
  chmod 755 /usr/bin/caddy.custom
  /usr/bin/caddy.custom list-modules | grep -q '^dns.providers.duckdns$' || { echo "custom Caddy lacks duckdns" >&2; exit 1; }
  if [ ! -e /usr/bin/caddy.default ]; then dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy; fi
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10 >/dev/null
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50 >/dev/null
  update-alternatives --set caddy /usr/bin/caddy.custom >/dev/null
fi

log "OCI CLI (instance principal reads Vault secrets)"
if [ ! -x /opt/oci-cli/bin/oci ]; then
  python3 -m venv /opt/oci-cli
  /opt/oci-cli/bin/pip install -q --upgrade pip oci-cli
fi
ln -sf /opt/oci-cli/bin/oci /usr/local/bin/oci

log "user and directories"
id coroute >/dev/null 2>&1 || useradd --system --home-dir /opt/coroute --shell /usr/sbin/nologin coroute
install -d -o root -g root -m 0755 /opt/coroute
install -d -o root -g root -m 0755 "$APP_DIR"
install -d -o coroute -g coroute -m 0750 "$APP_DIR/data" /var/lib/coroute
install -d -o root -g coroute -m 0750 /etc/coroute

log "/etc/coroute/gateway.env (settings, no secrets)"
ENV=/etc/coroute/gateway.env
if [ ! -f "$ENV" ]; then
  if [ -f "$SRC_DIR/.env.example" ]; then
    # Only the non-secret lines of the example; secret keys are removed (they come from Vault).
    grep -vE '^(JWT_SECRET|JWT_SECRET_PREVIOUS|ORACLE_PASSWORD|RAZORPAY_[A-Z_]*(SECRET|KEY_ID)|SETTINGS_ENCRYPTION_KEY|DATA_ENC_KEY|DATA_ENC_KEYS_PREVIOUS|BLIND_INDEX_KEY|BACKUP_ENCRYPTION_KEY|BACKUP_PAR_URL|REVIEW_PHOTO_PAR_URL|MIRROR_KEY|DUCKDNS_TOKEN|TWILIO_AUTH_TOKEN|AWS_SECRET_ACCESS_KEY|INFOBIP_API_KEY|TELEPHONY_WEBHOOK_TOKEN|WHATSAPP_API_TOKEN|GUARDIAN_VAPID_PRIVATE_KEY)=' \
      "$SRC_DIR/.env.example" | sed -E '/^[A-Z_]+=/s/[[:space:]]+#.*$//' > "$ENV"   # systemd keeps inline comments: drop them
  else
    echo "NODE_ENV=production" > "$ENV"
  fi
fi
set_kv() { # set_kv KEY VALUE: replace or append KEY=VALUE in $ENV
  if grep -qE "^$1=" "$ENV"; then sed -i -E "s|^$1=.*|$1=$2|" "$ENV"; else echo "$1=$2" >> "$ENV"; fi
}
set_kv NODE_ENV production
set_kv HOST 0.0.0.0          # Caddy (loopback) and the peer VM (VCN, firewalled to PEER_IP) reach it
set_kv PORT 3000
set_kv NODE_NAME "$NODE_NAME"
set_kv GATEWAY_ROLE "$NODE_ROLE"
set_kv PUBLIC_ORIGIN "$PUBLIC_ORIGIN"
if [ "$NODE_ROLE" = web ]; then set_kv TRUST_PROXY "loopback,$PEER_IP"; else set_kv TRUST_PROXY loopback; fi
chown root:coroute "$ENV"; chmod 0640 "$ENV"

log "/etc/coroute/secret_ids.env (OCIDs of Vault secrets; not secret)"
IDS=/etc/coroute/secret_ids.env
if [ ! -f "$IDS" ]; then
  cat > "$IDS" <<'IDSEOF'
# NAME=<OCID of the Vault secret holding that value>. Fill in every line, then:
#   systemctl restart coroute-secrets && systemctl restart coroute-gateway caddy
# Lines starting with # are ignored. DUCKDNS_TOKEN goes to Caddy only.
#JWT_SECRET=ocid1.vaultsecret.oc1....
#JWT_SECRET_PREVIOUS=ocid1.vaultsecret.oc1....
#ORACLE_PASSWORD=ocid1.vaultsecret.oc1....
#RAZORPAY_LIVE_KEY_ID=ocid1.vaultsecret.oc1....
#RAZORPAY_LIVE_KEY_SECRET=ocid1.vaultsecret.oc1....
#RAZORPAY_LIVE_WEBHOOK_SECRET=ocid1.vaultsecret.oc1....
#TWILIO_AUTH_TOKEN=ocid1.vaultsecret.oc1....
#MIRROR_KEY=ocid1.vaultsecret.oc1....
#SETTINGS_ENCRYPTION_KEY=ocid1.vaultsecret.oc1....
#DATA_ENC_KEY=ocid1.vaultsecret.oc1....
#BLIND_INDEX_KEY=ocid1.vaultsecret.oc1....
#BACKUP_ENCRYPTION_KEY=ocid1.vaultsecret.oc1....
#REVIEW_PHOTO_PAR_URL=ocid1.vaultsecret.oc1....
#BACKUP_PAR_URL=ocid1.vaultsecret.oc1....
#DUCKDNS_TOKEN=ocid1.vaultsecret.oc1....
IDSEOF
fi
chown root:root "$IDS"; chmod 0640 "$IDS"

log "systemd units"
install -m 0644 "$SRC_DIR/coroute-gateway.service" /etc/systemd/system/coroute-gateway.service
install -m 0644 "$SRC_DIR/coroute-secrets.service" /etc/systemd/system/coroute-secrets.service
install -d /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/coroute.conf <<'DROP'
[Unit]
Wants=coroute-secrets.service
After=coroute-secrets.service
[Service]
EnvironmentFile=/run/coroute/caddy.env
DROP
if [ "$SRC_DIR" != "$APP_DIR/deploy" ]; then
  # fetch_secrets.sh must exist where the unit expects it, even before the code is deployed.
  install -d -m 0755 "$APP_DIR/deploy"
  install -m 0755 "$SRC_DIR/fetch_secrets.sh" "$APP_DIR/deploy/fetch_secrets.sh"
fi
chmod 0755 "$APP_DIR/deploy/fetch_secrets.sh"
systemctl daemon-reload
systemctl enable coroute-secrets.service coroute-gateway.service caddy.service >/dev/null

log "Caddyfile ($NODE_ROLE)"
CF="$SRC_DIR/caddy/Caddyfile.vm1"; [ "$NODE_ROLE" = web ] && CF="$SRC_DIR/caddy/Caddyfile.vm2"
[ -f /etc/caddy/Caddyfile.orig ] || cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.orig 2>/dev/null || true
case "$DOMAIN" in
  # The shipped Caddyfiles already serve both names (and delegate the new name's ACME challenge to DuckDNS).
  coroute.duckdns.org|coroute.devmonks.space) cp "$CF" /etc/caddy/Caddyfile ;;
  *) sed "s/coroute\.duckdns\.org/$DOMAIN/g" "$CF" > /etc/caddy/Caddyfile ;;
esac
# VM1 forwards WEB routes to the peer's gateway: use the real peer IP.
sed -i "s/VM2_PRIVATE_IP/$PEER_IP/g" /etc/caddy/Caddyfile
grep -q "VM2_PRIVATE_IP" /etc/caddy/Caddyfile && { echo "Caddyfile still holds the VM2_PRIVATE_IP placeholder" >&2; exit 1; }
caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true

log "firewall (iptables): 443/80 public; 3000 and 3101 from $PEER_IP only"
allow() { iptables -C INPUT "$@" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 "$@" -j ACCEPT; }
allow -p tcp --dport 443 -m conntrack --ctstate NEW
allow -p tcp --dport 80 -m conntrack --ctstate NEW
allow -p udp --dport 443                                 # HTTP/3 (optional; the NLB forwards TCP only by default)
allow -p tcp -s "$PEER_IP" --dport 3000 -m conntrack --ctstate NEW
allow -p tcp -s "$PEER_IP" --dport 3101 -m conntrack --ctstate NEW
netfilter-persistent save >/dev/null

log "unattended security upgrades (no automatic reboot: reboot one VM at a time, see runbook)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AU
cat > /etc/apt/apt.conf.d/52coroute-unattended <<'UU'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Node.js and Caddy are upgraded deliberately (runbook), never in the background.
Unattended-Upgrade::Package-Blacklist { "nodejs"; "caddy"; };
UU

log "journald: cap logs at 200 MB"
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/coroute.conf
systemctl restart systemd-journald

echo
echo "Node $NODE_NAME ($NODE_ROLE) provisioned."
if [ ! -f "$APP_DIR/package.json" ]; then
  echo "Next: deploy the code to $APP_DIR (runbook: Deploy), fill /etc/coroute/secret_ids.env, then"
else
  echo "Next: fill /etc/coroute/secret_ids.env (if not done), then"
fi
echo "  systemctl restart coroute-secrets && systemctl restart coroute-gateway caddy"
