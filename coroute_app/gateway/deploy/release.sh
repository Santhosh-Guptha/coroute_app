#!/usr/bin/env bash
# CoRoute gateway release (v3.56), run from the owner's machine (Linux, macOS, WSL or Windows Git Bash).
#
#   gateway/deploy/release.sh [--inventory gateway/deploy/inventory.local.env] [--only vm4|vm2|vm1]
#                             [--skip-load] [--skip-tests] [--skip-route-check] [--yes] [--dry-run]
#                             [--rollback vm1|vm2|vm3|vm4] [--with-dr]
#
# Order: build the bundle -> vm4 staging (deploy, smoke, quick load check) -> vm2 (web + mirror) -> vm1 (live)
# [-> vm3 DR standby with --with-dr or --only vm3, so the standby always runs the same code].
# Each VM: upload, unpack into /opt/coroute/releases/<id>, npm ci there, switch the /opt/coroute/gateway symlink,
# restart, health gate (HEALTHY + expected version; /api/health/live 200 on vm1/vm2). A failed gate switches back
# to the previous release automatically (deploy/remote_release.sh) and the release STOPS: vm1 is never touched
# after a failure on vm4 or vm2. Needs: bash, tar, gzip, ssh, scp, node (for the route check and the bundle);
# the SSH aliases in the inventory (passwordless sudo on the VMs). Never contains or prints secrets.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."          # -> gateway/
GW_DIR="$(pwd)"
INV="deploy/inventory.local.env"; ONLY=""; SKIP_LOAD=0; SKIP_TESTS=0; SKIP_ROUTES=0; YES=0; DRY=0; ROLLBACK=""; WITH_DR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --inventory) INV="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --skip-load) SKIP_LOAD=1; shift;;
    --skip-tests) SKIP_TESTS=1; shift;;
    --skip-route-check) SKIP_ROUTES=1; shift;;
    --yes) YES=1; shift;;
    --dry-run) DRY=1; shift;;
    --rollback) ROLLBACK="$2"; shift 2;;
    --with-dr) WITH_DR=1; shift;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[ -f "$INV" ] || { echo "inventory $INV not found: cp deploy/inventory.example.env deploy/inventory.local.env and fill it in" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$INV"; set +a
VM1_SSH="${VM1_SSH:-vm1}"; VM2_SSH="${VM2_SSH:-vm2}"; VM3_SSH="${VM3_SSH:-vm3}"; VM4_SSH="${VM4_SSH:-vm4}"
HEALTH_TIMEOUT_S="${HEALTH_TIMEOUT_S:-90}"; STAGING_HOST="${STAGING_HOST:-staging.coroute.devmonks.space}"; PUBLIC_HOST="${PUBLIC_HOST:-coroute.devmonks.space}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"
say() { printf '\n==> %s\n' "$*"; }
SUMMARY=()
note() { local m="$*"; [ "$DRY" = 1 ] && m="[dry-run] $m"; SUMMARY+=("$m"); echo "    $m"; }
run() { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }
rssh() { ssh $SSH_OPTS "$@"; }

role_of() { case "$1" in "$VM1_SSH") echo live;; "$VM2_SSH") echo web;; "$VM3_SSH") echo standby;; "$VM4_SSH") echo staging;; *) echo web;; esac; }

if [ -n "$ROLLBACK" ]; then
  host_var="$(echo "$ROLLBACK" | tr '[:lower:]' '[:upper:]')_SSH"; host="${!host_var:-$ROLLBACK}"
  say "rollback $host"
  run rssh "$host" "sudo bash -s -- rollback $(role_of "$host") $HEALTH_TIMEOUT_S" < deploy/remote_release.sh
  exit $?
fi

VERSION="$(node -p "require('./package.json').version")"
GIT="$( (git rev-parse --short HEAD 2>/dev/null || echo nogit) | tr -d '\r')"
ID="${VERSION}-$(date -u +%Y%m%d%H%M%S)-${GIT}"
say "release $ID (gateway $VERSION)"

say "1/6 preflight"
for c in tar gzip ssh scp node; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 2; }; done
# Round 6: STRICT. Every route the gateway serves must be classified LIVE (vm1) or WEB (vm2) in deploy/route_split.md
# and the generated Caddy matcher must be current; an unclassified route would silently go to vm2.
if [ "$SKIP_ROUTES" = 1 ]; then note "WARNING: route split check skipped (--skip-route-check)"
elif ROUTE_OUT="$(node deploy/gen_caddy_routes.js --check 2>&1)"; then note "route split complete (gen_caddy_routes --check)"
else
  echo "$ROUTE_OUT" | tail -40 >&2
  echo "route split check failed: classify the routes above in deploy/route_split.md, run node deploy/gen_caddy_routes.js, then release again" >&2
  [ "$DRY" = 1 ] && note "route split check FAILED (dry run continues)" || exit 1
fi
if [ "$SKIP_TESTS" = 0 ] && [ -d node_modules ]; then
  echo "    running the gateway tests (npm test; --skip-tests to skip)"
  run npm test --silent >/dev/null 2>&1 && note "npm test passed" || { [ "$DRY" = 1 ] || { echo "npm test failed: fix before releasing" >&2; exit 1; }; }
fi
HOSTS="$VM4_SSH $VM2_SSH $VM1_SSH"; { [ "$WITH_DR" = 1 ] || [ "$ONLY" = "$VM3_SSH" ]; } && HOSTS="$HOSTS $VM3_SSH"
for h in $HOSTS; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$h" ] && continue
  if [ "$DRY" = 0 ]; then rssh "$h" "sudo -n true && command -v node >/dev/null && systemctl is-enabled coroute-gateway >/dev/null" || { echo "cannot use $h (ssh / sudo / gateway unit)" >&2; exit 2; }; fi
  note "$h reachable"
done

say "2/6 build the bundle"
BUILD="$(mktemp -d 2>/dev/null || mktemp -d -t coroute)"
trap 'rm -rf "$BUILD"' EXIT
STAGE="$BUILD/gateway"; mkdir -p "$STAGE"
# Copy with tar (no rsync on Git Bash): code, website, deploy material and the load tools; no tests, no secrets.
tar -cf - --exclude=node_modules --exclude=./data --exclude=.env --exclude='*.env.local' --exclude='inventory.local.env' \
  --exclude='public/*.apk' --exclude='public/*.ipa' --exclude=./test --exclude='*.log' . | tar -xf - -C "$STAGE"
# Precompressed assets for Caddy's file_server (precompressed zstd gzip): no per-request compression.
n=0
while IFS= read -r f; do gzip -9 -k -f "$f"; n=$((n+1)); command -v zstd >/dev/null && zstd -q -19 -k -f "$f" -o "$f.zst"; done < <(find "$STAGE/public/assets" "$STAGE/public/fonts" -type f \( -name '*.css' -o -name '*.js' -o -name '*.svg' -o -name '*.json' -o -name '*.txt' \) 2>/dev/null)
echo "$ID" > "$STAGE/RELEASE"
BUNDLE="$BUILD/coroute-gateway-$ID.tgz"
tar -czf "$BUNDLE" -C "$STAGE" .
note "bundle $(basename "$BUNDLE") ($(du -h "$BUNDLE" | cut -f1), $n assets precompressed)"

deploy_one() { # deploy_one <ssh host>
  local h="$1" role; role="$(role_of "$h")"
  say "deploy $h (role $role)"
  run scp $SSH_OPTS -q "$BUNDLE" "$h:/tmp/coroute-gateway-$ID.tgz"
  if run rssh "$h" "sudo bash -s -- install /tmp/coroute-gateway-$ID.tgz $ID $VERSION $role $HEALTH_TIMEOUT_S" < deploy/remote_release.sh; then
    note "$h: $ID healthy"
    run rssh "$h" "rm -f /tmp/coroute-gateway-$ID.tgz" || true
  else
    note "$h: FAILED health gate, rolled back to the previous release. STOP."
    printf '%s\n' "${SUMMARY[@]}"; exit 1
  fi
}

public_check() { # public_check <host> <label>
  local host="$1" label="$2" code ws
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/api/health" || true)
  ws=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: Y29yb3V0ZXJlbGVhc2UxMg==' "https://$host/ws" || true)
  local css; css=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/assets/site.css" || true)
  note "$label https://$host: /api/health $code, /ws upgrade $ws, static $css"
  [ "$DRY" = 1 ] || { [ "$code" = 200 ] && [ "$ws" = 101 ]; }
}

if [ -z "$ONLY" ] || [ "$ONLY" = "$VM4_SSH" ]; then
  say "3/6 staging ($VM4_SSH): deploy, smoke, quick load check"
  deploy_one "$VM4_SSH"
  public_check "$STAGING_HOST" "staging" || { note "staging public check failed. STOP."; printf '%s\n' "${SUMMARY[@]}"; exit 1; }
  if [ "$SKIP_LOAD" = 0 ]; then
    # Seeds STAGING_LOAD_RIDERS riders into the staging database (refuses a production database) and runs the
    # WebSocket load test from vm4 against the staging host through its Caddy. A quick gate, not a benchmark.
    out=$(run rssh "$VM4_SSH" "cd /opt/coroute/gateway && sudo bash deploy/staging/quick_load.sh ${STAGING_LOAD_RIDERS:-300} ${STAGING_LOAD_SECONDS:-30} $STAGING_HOST" || true)
    echo "$out" | tail -5
    if [ "$DRY" = 0 ] && ! echo "$out" | grep -q 'QUICK_LOAD_OK'; then note "staging quick load check failed. STOP."; printf '%s\n' "${SUMMARY[@]}"; exit 1; fi
    note "staging quick load: $(echo "$out" | grep -o 'QUICK_LOAD_OK.*' | head -1)"
  fi
fi

if [ -z "$ONLY" ] || [ "$ONLY" = "$VM2_SSH" ]; then
  if [ "$YES" = 0 ] && [ "$DRY" = 0 ] && [ -z "$ONLY" ]; then read -r -p "    staging is good. Deploy to $VM2_SSH (web + mirror)? [y/N] " a; [ "$a" = y ] || { note "stopped before $VM2_SSH"; printf '%s\n' "${SUMMARY[@]}"; exit 0; }; fi
  say "4/6 $VM2_SSH (web + mirror)"
  deploy_one "$VM2_SSH"
  public_check "$PUBLIC_HOST" "production after $VM2_SSH" || { note "public check failed after $VM2_SSH: roll back with --rollback vm2. STOP."; printf '%s\n' "${SUMMARY[@]}"; exit 1; }
fi

if [ -z "$ONLY" ] || [ "$ONLY" = "$VM1_SSH" ]; then
  if [ "$YES" = 0 ] && [ "$DRY" = 0 ] && [ -z "$ONLY" ]; then read -r -p "    Deploy to $VM1_SSH (LIVE: riders move to $VM2_SSH for ~30 s and back)? [y/N] " a; [ "$a" = y ] || { note "stopped before $VM1_SSH"; printf '%s\n' "${SUMMARY[@]}"; exit 0; }; fi
  say "5/6 $VM1_SSH (live)"
  deploy_one "$VM1_SSH"
  if [ "$DRY" = 0 ]; then
    m=$(rssh "$VM1_SSH" "curl -s --max-time 5 http://127.0.0.1:3000/api/health/live" || true)
    echo "$m" | grep -q '"connected":true' && note "$VM1_SSH mirror link to $VM2_SSH: connected" || note "WARNING: $VM1_SSH mirror not connected yet: $m"
  fi
  public_check "$PUBLIC_HOST" "production after $VM1_SSH" || note "WARNING: public check failed after $VM1_SSH (check the NLB backend health)"
fi

if [ "$ONLY" = "$VM3_SSH" ] || { [ -z "$ONLY" ] && [ "$WITH_DR" = 1 ]; }; then
  say "DR standby $VM3_SSH (same code, GATEWAY_ROLE=standby)"
  deploy_one "$VM3_SSH"
fi

say "6/6 summary ($ID)"
printf '  %s\n' "${SUMMARY[@]}"
echo "  rollback any node: gateway/deploy/release.sh --rollback vm1|vm2|vm4"
