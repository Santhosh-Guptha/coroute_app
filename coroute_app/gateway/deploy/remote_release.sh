#!/usr/bin/env bash
# Runs ON a gateway VM (sent by deploy/release.sh over ssh; also usable by hand). v3.56.
#
#   sudo bash remote_release.sh install  <bundle.tgz> <release-id> <expected-version> <role: live|web|staging|standby> [health-timeout-s]
#   sudo bash remote_release.sh rollback <role> [health-timeout-s]
#   sudo bash remote_release.sh status
#
# Layout (created on first use; the old /opt/coroute/gateway directory becomes releases/legacy-<time>):
#   /opt/coroute/releases/<id>/      one directory per release (code + node_modules), read-only for the service
#   /opt/coroute/gateway  -> releases/<id>    symlink switched atomically (mv -T); systemd and Caddy use this path
#   /opt/coroute/shared/data/        review photos and local state (releases/<id>/data links here)
#   /opt/coroute/shared/public/      APKs (releases/<id>/public/coroute*.apk link here)
#   /opt/coroute/releases/.previous  the release to go back to
# Health gate after the restart: /api/health is HEALTHY with the expected version, and for live/web nodes
# /api/health/live answers 200 (a live node may be 'syncing' first). A failed gate switches back and restarts.
set -euo pipefail
BASE="${COROUTE_BASE:-/opt/coroute}"   # override only for tests
REL="$BASE/releases"
CUR="$BASE/gateway"
SHARED="$BASE/shared"
log() { echo "[remote $(hostname) $(date -u +%H:%M:%S)] $*"; }

health() { # health <expected-version|''> <role> <timeout-s>
  local want="$1" role="$2" timeout="${3:-90}" t0 body live
  t0=$(date +%s)
  while :; do
    body=$(curl -fsS --max-time 5 http://127.0.0.1:3000/api/health 2>/dev/null || true)
    if echo "$body" | grep -q '"status":"HEALTHY"' && { [ -z "$want" ] || echo "$body" | grep -q "\"version\":\"$want\""; }; then
      if [ "$role" = live ] || [ "$role" = web ]; then
        live=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/api/health/live || true)
        if [ "$live" = 200 ]; then log "healthy: $(echo "$body" | head -c 200)"; return 0; fi
      else log "healthy: $(echo "$body" | head -c 200)"; return 0; fi
    fi
    if [ $(( $(date +%s) - t0 )) -ge "$timeout" ]; then log "NOT healthy after ${timeout}s: $(echo "$body" | head -c 300)"; return 1; fi
    sleep 3
  done
}

switch_to() { # switch_to <release dir>
  ln -sfn "$1" "$BASE/gateway.next"
  mv -T "$BASE/gateway.next" "$CUR"
}

migrate_layout() {
  install -d -m 0755 "$REL"
  install -d -o coroute -g coroute -m 0750 "$SHARED" "$SHARED/data"
  install -d -o root -g coroute -m 0755 "$SHARED/public"
  if [ -d "$CUR" ] && [ ! -L "$CUR" ]; then
    local legacy="$REL/legacy-$(date -u +%Y%m%d%H%M%S)"
    log "first release with the symlink layout: $CUR -> $legacy"
    if [ -d "$CUR/data" ] && [ ! -L "$CUR/data" ]; then cp -a "$CUR/data/." "$SHARED/data/" 2>/dev/null || true; fi
    for apk in "$CUR"/public/coroute*.apk "$CUR"/public/*.ipa; do [ -f "$apk" ] && cp -a "$apk" "$SHARED/public/"; done
    mv "$CUR" "$legacy"
    ln -sfn "$legacy" "$CUR"
  fi
}

link_shared() { # link_shared <release dir>
  local d="$1"
  rm -rf "$d/data"; ln -sfn "$SHARED/data" "$d/data"
  for apk in "$SHARED"/public/*; do [ -f "$apk" ] && ln -sfn "$apk" "$d/public/$(basename "$apk")"; done
  return 0
}

cmd="${1:-status}"
case "$cmd" in
  install)
    BUNDLE="$2"; ID="$3"; WANT="$4"; ROLE="$5"; TIMEOUT="${6:-90}"
    [ -f "$BUNDLE" ] || { log "bundle $BUNDLE missing"; exit 1; }
    migrate_layout
    PREV="$(readlink -f "$CUR")"
    DEST="$REL/$ID"
    if [ -d "$DEST" ]; then log "release $ID already unpacked: reusing"; else
      install -d -m 0755 "$DEST"
      tar -xzf "$BUNDLE" -C "$DEST"
      log "npm ci --omit=dev (this VM's architecture)"
      (cd "$DEST" && npm ci --omit=dev --no-audit --no-fund --loglevel=error)
      chown -R root:coroute "$DEST"; chmod -R g+rX,o+rX "$DEST"
    fi
    link_shared "$DEST"
    [ -x "$DEST/deploy/fetch_secrets.sh" ] || chmod 0755 "$DEST/deploy/fetch_secrets.sh"
    echo "$PREV" > "$REL/.previous"
    switch_to "$DEST"
    log "switched $CUR -> $DEST (previous: $PREV); restarting coroute-gateway"
    systemctl restart coroute-gateway
    if health "$WANT" "$ROLE" "$TIMEOUT"; then
      # keep the 3 newest releases plus the previous one
      ls -1dt "$REL"/*/ 2>/dev/null | tail -n +5 | while read -r old; do old="${old%/}"; [ "$old" = "$PREV" ] || [ "$old" = "$DEST" ] || rm -rf "$old"; done
      log "OK $ID"; exit 0
    fi
    log "health gate FAILED: rolling back to $PREV"
    switch_to "$PREV"; systemctl restart coroute-gateway
    if health "" "$ROLE" "$TIMEOUT"; then log "rolled back to $PREV (healthy)"; else log "ROLLBACK ALSO UNHEALTHY: check journalctl -u coroute-gateway"; fi
    exit 3
    ;;
  rollback)
    ROLE="${2:-web}"; TIMEOUT="${3:-90}"
    PREV="$(cat "$REL/.previous" 2>/dev/null || true)"
    [ -n "$PREV" ] && [ -d "$PREV" ] || { log "no previous release recorded"; exit 1; }
    NOW="$(readlink -f "$CUR")"
    switch_to "$PREV"; echo "$NOW" > "$REL/.previous"
    systemctl restart coroute-gateway
    health "" "$ROLE" "$TIMEOUT" && log "rolled back to $PREV" || { log "rollback unhealthy"; exit 3; }
    ;;
  status)
    echo "current:  $(readlink -f "$CUR" 2>/dev/null || echo "$CUR (not a symlink yet)")"
    echo "previous: $(cat "$REL/.previous" 2>/dev/null || echo none)"
    ls -1dt "$REL"/*/ 2>/dev/null | head -5 | sed 's/^/release:  /'
    curl -fsS --max-time 5 http://127.0.0.1:3000/api/health | head -c 300; echo
    ;;
  *) echo "usage: $0 install|rollback|status ..." >&2; exit 2;;
esac
