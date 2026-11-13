#!/usr/bin/env bash
# Points the production names at an IP (v3.56): DuckDNS by its API (token from /run/coroute/caddy.env), and
# coroute.devmonks.space through the DNS provider's API when configured (DNS_PROVIDER=cloudflare with CF_API_TOKEN,
# CF_ZONE_ID, CF_RECORD_ID in /etc/coroute/dns.env, 0600) or by hand (the script prints the exact record to set).
#   sudo bash deploy/dr/dns_switch.sh <ip> [--dry-run]
# TTL: keep 300 s on both records so a switch reaches most phones within about 5 minutes.
set -euo pipefail
IP="${1:?usage: dns_switch.sh <ip> [--dry-run]}"; DRY=0; [ "${2:-}" = --dry-run ] && DRY=1
[[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "not an IPv4 address: $IP" >&2; exit 2; }
[ -f /run/coroute/caddy.env ] && set -a && . /run/coroute/caddy.env && set +a
[ -f /etc/coroute/dns.env ] && set -a && . /etc/coroute/dns.env && set +a
DUCK_DOMAIN="${DUCK_DOMAIN:-coroute}"
if [ -n "${DUCKDNS_TOKEN:-}" ]; then
  if [ "$DRY" = 1 ]; then echo "[dry-run] DuckDNS $DUCK_DOMAIN.duckdns.org -> $IP"; else
    r=$(curl -fsS --max-time 15 "https://www.duckdns.org/update?domains=$DUCK_DOMAIN&token=$DUCKDNS_TOKEN&ip=$IP" || echo FAIL)
    echo "DuckDNS $DUCK_DOMAIN.duckdns.org -> $IP: $r"; [ "$r" = OK ] || exit 1
  fi
else echo "DUCKDNS_TOKEN not available here: set $DUCK_DOMAIN.duckdns.org -> $IP at https://www.duckdns.org by hand"; fi
case "${DNS_PROVIDER:-manual}" in
  cloudflare)
    : "${CF_API_TOKEN:?}" "${CF_ZONE_ID:?}" "${CF_RECORD_ID:?}"
    if [ "$DRY" = 1 ]; then echo "[dry-run] Cloudflare coroute.devmonks.space A -> $IP (proxied=false, ttl 300)"; else
      curl -fsS --max-time 15 -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
        --data "{\"content\":\"$IP\",\"ttl\":300,\"proxied\":false}" | grep -q '"success":true' && echo "Cloudflare coroute.devmonks.space -> $IP: OK" || { echo "Cloudflare update failed"; exit 1; }
    fi;;
  *) echo "MANUAL STEP: at the devmonks.space DNS provider set   coroute.devmonks.space.  A  $IP  (TTL 300)";;
esac
echo "check: dig +short coroute.devmonks.space @1.1.1.1 ; dig +short $DUCK_DOMAIN.duckdns.org @8.8.8.8"
