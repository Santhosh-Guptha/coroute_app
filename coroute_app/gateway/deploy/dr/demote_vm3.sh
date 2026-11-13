#!/usr/bin/env bash
# Return vm3 to DR standby after a promotion (v3.56).  sudo bash deploy/dr/demote_vm3.sh [--yes] [--wait-s 600]
# Order matters: DNS back to the tenancy-1 NLB, wait out the DNS TTL while vm3 keeps serving the riders still
# pointed at it, make sure vm1/vm2 are up and serving, THEN vm3 returns to GATEWAY_ROLE=standby (its sockets get
# RECONNECT and land on the NLB).
set -euo pipefail
YES=0; WAIT=600
while [ $# -gt 0 ]; do case "$1" in --yes) YES=1;; --wait-s) WAIT="$2"; shift;; *) echo "unknown $1" >&2; exit 2;; esac; shift; done
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f /etc/coroute/dr.env ] && set -a && . /etc/coroute/dr.env && set +a
: "${NLB_PUBLIC_IP:?set NLB_PUBLIC_IP in /etc/coroute/dr.env}"
ask() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [ "$a" = y ]; }
ask "vm1 and vm2 are running and healthy behind the NLB? Switch DNS back to the NLB now?" || exit 1
bash "$HERE/dns_switch.sh" "$NLB_PUBLIC_IP"
echo "waiting ${WAIT}s for DNS caches (vm3 keeps serving meanwhile)"; sleep "$WAIT"
sed -i -E 's/^GATEWAY_ROLE=.*/GATEWAY_ROLE=standby/' /etc/coroute/gateway.env
systemctl restart coroute-gateway
sleep 5; curl -s http://127.0.0.1:3000/api/health | head -c 200; echo
echo "vm3 is a standby again (/api/health/live should be 503 standby): $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/health/live)"
