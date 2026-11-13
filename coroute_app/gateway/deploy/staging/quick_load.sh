#!/usr/bin/env bash
# Staging quick load gate (v3.56), run ON vm4 by deploy/release.sh:  sudo bash deploy/staging/quick_load.sh <riders> <seconds> <staging host>
# Seeds riders into the staging database (tool/load/seed_staging.js refuses production), runs tool/load/ws_load.js
# through the staging Caddy, prints the JSON result and "QUICK_LOAD_OK ..." when every rider joined, every SOS reached
# every group member, no errors, and the position fan-out p99 stayed under 1500 ms (a micro, with the load
# generator on the same VM: a gate for regressions, not a benchmark).
set -euo pipefail
RIDERS="${1:-300}"; SECONDS_="${2:-30}"; HOST="${3:-staging.coroute.devmonks.space}"
cd /opt/coroute/gateway
set -a; . /etc/coroute/gateway.env; [ -f /run/coroute/secrets.env ] && . /run/coroute/secrets.env; [ -f /etc/coroute/staging.env ] && . /etc/coroute/staging.env; set +a
DBHOST=$(node -e "try{process.stdout.write(new URL(process.env.ORACLE_SODA_URL).host)}catch{}")
TOK=$(mktemp /tmp/coroute-load-tokens.XXXXXX.json)
trap 'rm -f "$TOK"' EXIT
node tool/load/seed_staging.js --riders "$RIDERS" --group-size 8 --out "$TOK" --confirm-db "$DBHOST"
RES=$(node tool/load/ws_load.js --target "wss://$HOST/ws" --tokens "$TOK" --hz 0.4 --seconds "$SECONDS_" --sos-per-min 20 --ramp 100 --json)
echo "$RES"
echo "$RES" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s.trim().split("\n").pop());
const ok=r.joined===r.riders&&r.errors===0&&r.sos.deliveries===r.sos.expected&&(r.fanoutLatencyMs.p99??0)<1500;
console.log(`${ok?"QUICK_LOAD_OK":"QUICK_LOAD_FAIL"} riders=${r.joined}/${r.riders} fanout_p50=${r.fanoutLatencyMs.p50}ms p95=${r.fanoutLatencyMs.p95}ms p99=${r.fanoutLatencyMs.p99}ms sos=${r.sos.deliveries}/${r.sos.expected} sos_p99=${r.sos.latencyMs.p99}ms errors=${r.errors}`);
process.exit(ok?0:1);});'
