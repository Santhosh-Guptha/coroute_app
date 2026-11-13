#!/usr/bin/env bash
# DR secrets from a local file (v3.56), for vm3 when tenancy-1 Vault cannot be read from tenancy 2 and no tenancy-2
# Vault copy exists yet. Replaces fetch_secrets.sh through a coroute-secrets.service drop-in (install_standby.sh).
#   /etc/coroute/dr-secrets.env  (root:root 0600, NAME=value lines, written by the operator over SSH, never in git)
#   -> /run/coroute/secrets.env  (tmpfs, 0600 coroute)   and   DUCKDNS_TOKEN -> /run/coroute/caddy.env (0600 root)
# Never prints a value.
set -euo pipefail
umask 077
SRC="${DR_SECRETS_FILE:-/etc/coroute/dr-secrets.env}"
OUT=/run/coroute
[ -r "$SRC" ] || { echo "[file_secrets] $SRC missing (see RUNBOOK, DR: secrets)" >&2; exit 1; }
[ "$(stat -c %a "$SRC")" = 600 ] || { echo "[file_secrets] $SRC must be mode 600" >&2; exit 1; }
mkdir -p "$OUT"; chown root:coroute "$OUT"; chmod 0750 "$OUT"
case "$(stat -f -c %T "$OUT")" in tmpfs|ramfs) ;; *) echo "[file_secrets] $OUT is not tmpfs" >&2; exit 1;; esac
gw="$(mktemp "$OUT/.s.XXXXXX")"; cd_="$(mktemp "$OUT/.c.XXXXXX")"
grep -E '^[A-Z][A-Z0-9_]*=' "$SRC" | grep -v '^DUCKDNS_TOKEN=' > "$gw" || true
grep -E '^DUCKDNS_TOKEN=' "$SRC" > "$cd_" || true
for r in JWT_SECRET ORACLE_PASSWORD; do grep -q "^$r=" "$gw" || { rm -f "$gw" "$cd_"; echo "[file_secrets] $r missing in $SRC" >&2; exit 1; }; done
chown coroute:coroute "$gw"; chmod 0600 "$gw"; chown root:root "$cd_"; chmod 0600 "$cd_"
mv -f "$gw" "$OUT/secrets.env"; mv -f "$cd_" "$OUT/caddy.env"
echo "[file_secrets] wrote $(grep -c . "$OUT/secrets.env") secret(s) (values not shown)"
