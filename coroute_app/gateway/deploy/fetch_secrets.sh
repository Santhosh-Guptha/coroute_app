#!/usr/bin/env bash
# Reads the gateway's secrets from OCI Vault with the instance principal (no API keys on the VM) and writes
#   /run/coroute/secrets.env   NAME='value' lines for coroute-gateway.service  (tmpfs, 0600, owner coroute)
#   /run/coroute/caddy.env     DUCKDNS_TOKEN only, for caddy.service           (tmpfs, 0600, owner root)
# The secret OCIDs (not secret themselves) are listed in /etc/coroute/secret_ids.env as  NAME=ocid1.vaultsecret...
# Never prints a value. Run by coroute-secrets.service (root) before the gateway and Caddy start.
set -euo pipefail
umask 077

IDS_FILE="${SECRET_IDS_FILE:-/etc/coroute/secret_ids.env}"
OUT_DIR="${SECRETS_DIR:-/run/coroute}"
OCI_BIN="${OCI_BIN:-$(command -v oci || echo /usr/local/bin/oci)}"
RUN_AS="${RUN_AS:-coroute}"
REQUIRED="${REQUIRED_SECRETS:-JWT_SECRET ORACLE_PASSWORD}"
CADDY_ONLY="DUCKDNS_TOKEN"

log() { echo "[fetch_secrets] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -r "$IDS_FILE" ] || die "$IDS_FILE not found (see docs/PRODUCTION_TWO_VM_RUNBOOK.md, Vault step)"
[ -x "$OCI_BIN" ] || die "OCI CLI not found ($OCI_BIN); run deploy/setup_node.sh"
id "$RUN_AS" >/dev/null 2>&1 || die "user $RUN_AS missing"
RUN_GROUP="$(id -gn "$RUN_AS")"

mkdir -p "$OUT_DIR"
chown root:"$RUN_GROUP" "$OUT_DIR"
chmod 0750 "$OUT_DIR"
case "$(stat -f -c %T "$OUT_DIR" 2>/dev/null || echo unknown)" in
  tmpfs|ramfs) ;;
  *) die "$OUT_DIR is not on tmpfs: refusing to write secrets to disk" ;;
esac

tmp_gw="$(mktemp "$OUT_DIR/.secrets.XXXXXX")"
tmp_caddy="$(mktemp "$OUT_DIR/.caddy.XXXXXX")"
trap 'rm -f "$tmp_gw" "$tmp_caddy"' EXIT

# One systemd EnvironmentFile line. Safe characters are written as is; anything else single-quoted.
env_line() {
  local name="$1" value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) die "$name contains a line break (store it base64 or single-line)";;
  esac
  if [[ "$value" =~ ^[A-Za-z0-9_./:@%+=,~-]*$ ]]; then
    printf '%s=%s\n' "$name" "$value"
  elif [[ "$value" != *"'"* ]]; then
    printf "%s='%s'\n" "$name" "$value"
  else
    die "$name contains a single quote: not representable in an EnvironmentFile"
  fi
}

fetch() { # $1 = secret OCID; prints the decoded value on stdout (captured, never shown)
  local id="$1" attempt b64
  for attempt in 1 2 3 4 5; do
    if b64="$("$OCI_BIN" secrets secret-bundle get --auth instance_principal --secret-id "$id" --stage CURRENT \
          --query 'data."secret-bundle-content".content' --raw-output 2>/dev/null)" && [ -n "$b64" ]; then
      printf '%s' "$b64" | base64 -d
      return 0
    fi
    sleep $((attempt * 3))
  done
  return 1
}

count=0
declare -A seen=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [ -z "$line" ] && continue
  [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(ocid1\.vaultsecret\.[A-Za-z0-9._-]+)$ ]] || die "bad line in $IDS_FILE (expected NAME=ocid1.vaultsecret...)"
  name="${BASH_REMATCH[1]}"; ocid="${BASH_REMATCH[2]}"
  value="$(fetch "$ocid")" || die "could not read secret $name from OCI Vault (dynamic group / policy / network?)"
  [ -n "$value" ] || die "secret $name is empty"
  if [[ "$name" =~ _PAR_URL$ ]]; then
    value="${value//oraclecloudapps.com/oraclecloud.com}"
  fi
  if [[ " $CADDY_ONLY " == *" $name "* ]]; then
    env_line "$name" "$value" >> "$tmp_caddy"
  else
    env_line "$name" "$value" >> "$tmp_gw"
  fi
  seen[$name]=1
  count=$((count + 1))
  unset value
done < "$IDS_FILE"

for r in $REQUIRED; do
  [ -n "${seen[$r]:-}" ] || die "required secret $r is not listed in $IDS_FILE"
done

chown "$RUN_AS":"$RUN_GROUP" "$tmp_gw"; chmod 0600 "$tmp_gw"
chown root:root "$tmp_caddy"; chmod 0600 "$tmp_caddy"
mv -f "$tmp_gw" "$OUT_DIR/secrets.env"
mv -f "$tmp_caddy" "$OUT_DIR/caddy.env"
trap - EXIT
log "wrote $count secret(s): $(printf '%s ' "${!seen[@]}")(values not shown)"
