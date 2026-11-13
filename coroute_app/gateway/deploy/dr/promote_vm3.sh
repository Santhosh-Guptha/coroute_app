#!/usr/bin/env bash
# Promote vm3 from DR standby to the single serving node (v3.56). MANUAL by default: asks before every step.
#   sudo bash deploy/dr/promote_vm3.sh [--yes] [--force] [--tls dns|http] [--no-dns]
# Use ONLY when vm1 AND vm2 are down (tenancy-1 suspension, region outage, both VMs lost). Two serving nodes that do
# not mirror each other would each load the same rides: the script refuses while the public site or the NLB answer
# healthy, unless --force. After vm1/vm2 are back: deploy/dr/demote_vm3.sh FIRST, then start them.
set -euo pipefail
YES=0; FORCE=0; TLS=dns; DNS=1
while [ $# -gt 0 ]; do case "$1" in --yes) YES=1;; --force) FORCE=1;; --tls) TLS="$2"; shift;; --no-dns) DNS=0;; *) echo "unknown $1" >&2; exit 2;; esac; shift; done
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f /etc/coroute/dr.env ] && set -a && . /etc/coroute/dr.env && set +a     # VM3_PUBLIC_IP, NLB_PUBLIC_IP, PUBLIC_HOST
PUBLIC_HOST="${PUBLIC_HOST:-coroute.devmonks.space}"
ask() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [ "$a" = y ]; }
echo "==> checking production before promoting"
pub=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$PUBLIC_HOST/api/health" || true)
echo "   https://$PUBLIC_HOST/api/health -> ${pub:-no answer}"
if [ "$pub" = 200 ] && [ "$FORCE" = 0 ]; then echo "Production answers 200: refusing (split brain). Use --force only if you are sure vm1 and vm2 are stopped." >&2; exit 1; fi
ask "Promote vm3 to serve production now?" || exit 1
echo "==> 1/4 gateway role standby -> all"
sed -i -E 's/^GATEWAY_ROLE=.*/GATEWAY_ROLE=all/' /etc/coroute/gateway.env
systemctl restart coroute-secrets
systemctl enable --now coroute-gateway >/dev/null; systemctl restart coroute-gateway
for i in $(seq 1 40); do code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:3000/api/health/live || true); [ "$code" = 200 ] && break; sleep 3; done
[ "$code" = 200 ] || { echo "gateway not serving (/api/health/live $code): journalctl -u coroute-gateway" >&2; exit 1; }
curl -s http://127.0.0.1:3000/api/health | head -c 300; echo
echo "==> 2/4 Caddy (TLS $TLS)"
if [ "$TLS" = http ]; then cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-promote.$(date +%s)" 2>/dev/null || true; install -m 0644 "$HERE/../caddy/Caddyfile.vm3-dr-http" /etc/caddy/Caddyfile; fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null && systemctl reload caddy
echo "==> 3/4 DNS -> vm3 (${VM3_PUBLIC_IP:-<VM3_PUBLIC_IP not set in /etc/coroute/dr.env>})"
if [ "$DNS" = 1 ]; then
  [ -n "${VM3_PUBLIC_IP:-}" ] || { echo "set VM3_PUBLIC_IP in /etc/coroute/dr.env" >&2; exit 1; }
  ask "Switch DNS of $PUBLIC_HOST and the DuckDNS name to vm3?" && bash "$HERE/dns_switch.sh" "$VM3_PUBLIC_IP"
fi
echo "==> 4/4 verify through vm3's Caddy"
curl -s --max-time 10 --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST/api/health" | head -c 200; echo
echo
echo "vm3 is serving (GATEWAY_ROLE=all: it takes every scheduled job after the lease grace, about 2 minutes)."
echo "Riders reconnect on their own once their DNS cache expires (TTL 300 s). Watch: journalctl -u coroute-gateway -f"
echo "Back to normal later: deploy/dr/demote_vm3.sh (DNS back to the NLB first), then start vm1/vm2."
