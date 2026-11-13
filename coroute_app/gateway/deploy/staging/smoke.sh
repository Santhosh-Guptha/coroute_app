#!/usr/bin/env bash
# Read-only smoke test (v3.56): safe against production and staging (creates nothing).
#   deploy/staging/smoke.sh https://coroute.devmonks.space
# Checks /api/health (HEALTHY), /status, /api/meta, a static asset with cache headers, the WebSocket upgrade (101)
# and that /metrics is NOT public. Exit 1 on the first failure.
set -uo pipefail
BASE="${1:?usage: smoke.sh https://host}"
fail=0
chk() { local name="$1" want="$2" got="$3"; if [ "$got" = "$want" ]; then echo "  ok   $name ($got)"; else echo "  FAIL $name: got $got, want $want"; fail=1; fi; }
h=$(curl -s --max-time 10 "$BASE/api/health"); echo "$h" | grep -q '"status":"HEALTHY"' && echo "  ok   /api/health HEALTHY $(echo "$h" | grep -o '"version":"[^"]*"')" || { echo "  FAIL /api/health: $(echo "$h" | head -c 200)"; fail=1; }
chk /status 200 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/status")"
chk /api/meta 200 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/api/meta")"
cc=$(curl -sI --max-time 10 "$BASE/assets/site.css?v=smoke" | tr -d '\r' | grep -i '^cache-control:' | cut -d' ' -f2-)
echo "$cc" | grep -q immutable && echo "  ok   static asset cache ($cc)" || echo "  note static asset cache: '${cc:-none}' (immutable expected once the v3.56 Caddyfile is installed)"
chk "/ws upgrade" 101 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: Y29yb3V0ZXNtb2tldGVzdA==' "$BASE/ws")"
chk "/metrics not public" 404 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/metrics")"
[ "$fail" = 0 ] && echo "SMOKE OK $BASE" || { echo "SMOKE FAILED $BASE"; exit 1; }
