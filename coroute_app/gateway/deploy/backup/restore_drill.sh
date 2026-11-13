#!/usr/bin/env bash
# Weekly restore drill (v3.56).   sudo bash deploy/backup/restore_drill.sh [--source local|par]
#   local (vm3, default): the newest backup in BACKUP_DIR
#   par   (vm4): the newest object under coroute-offsite/ through OFFSITE_READ_PAR_URL (read + list PAR)
# Decrypts, verifies the manifest, restores every collection into an in-memory database and compares counts
# (scripts/restore_drill.js), writes /var/lib/coroute-backup/last-drill.json and e-mails the result (DRILL_MAIL_TO).
# Needs BACKUP_ENCRYPTION_KEY (secrets). Writes no database.
set -euo pipefail
SOURCE=local; [ "${1:-}" = --source ] && SOURCE="${2:-local}"
GW=/opt/coroute/gateway
set -a; for f in /etc/coroute/gateway.env /run/coroute/secrets.env /etc/coroute/backup.env; do [ -f "$f" ] && . "$f"; done; set +a
: "${BACKUP_ENCRYPTION_KEY:?BACKUP_ENCRYPTION_KEY missing (secrets)}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; chmod 700 "$TMP"
if [ "$SOURCE" = par ]; then
  : "${OFFSITE_READ_PAR_URL:?set OFFSITE_READ_PAR_URL in /etc/coroute/backup.env}"
  P="${OFFSITE_READ_PAR_URL%/}/"
  NAME=$(curl -fsS --max-time 60 "${P}?prefix=coroute-offsite/&fields=name,timeCreated" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=(JSON.parse(s).objects||[]).filter(x=>x.name.endsWith(".json.gz.enc"));
    o.sort((a,b)=>String(b.timeCreated||b.name).localeCompare(String(a.timeCreated||a.name)));process.stdout.write(o.length?o[0].name:"");});')
  [ -n "$NAME" ] || { echo "no backup found in the offsite bucket" >&2; exit 1; }
  curl -fsS --max-time 600 -o "$TMP/backup.json.gz.enc" "$P$NAME"
  curl -fsS --max-time 60 -o "$TMP/backup.manifest.json" "$P${NAME%.json.gz.enc}.manifest.json"
  FILE="$TMP/backup.json.gz.enc"
else
  FILE=$(cd "$GW" && node -e "process.stdout.write(require('./scripts/restore_drill').newestBackup(process.argv[1])||'')" "${BACKUP_DIR:-/var/backups/coroute}")
  [ -n "$FILE" ] || { echo "no backup in ${BACKUP_DIR:-/var/backups/coroute}" >&2; exit 1; }
fi
mkdir -p /var/lib/coroute-backup
set +e
OUT=$(cd "$GW" && NODE_OPTIONS=--max-old-space-size=512 node scripts/restore_drill.js --file "$FILE" --mail); RC=$?
set -e
echo "$OUT" | tail -1 | tee /var/lib/coroute-backup/last-drill.json
exit $RC
