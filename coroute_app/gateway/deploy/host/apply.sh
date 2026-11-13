#!/usr/bin/env bash
# CoRoute host tuning and hardening (v3.56). Idempotent: safe to run again; --dry-run shows every change first.
#
#   sudo ./host/apply.sh --role realtime|live-a1|web|dr|staging|worker [--dry-run] [--peer-ip <private ip>] [--ignore-ips "a b"]
#                        [--skip-ssh] [--skip-firewall] [--force-ssh]
#
#   realtime  vm1  live gateway (WS, convoys, SOS)          heap 384 MB, MemoryMax 700 MB, iptables (OCI image rules)
#   live-a1   A1   stage 1 live node, Ampere ARM 2 OCPU / 12 GB (Always Free size per account): heap 2048 MB,
#                  MemoryHigh 4 GB, MemoryMax 5 GB (the rest: Caddy, page cache, a voice relay process), iptables,
#                  GATEWAY_ROLE=live, LIVE_RIDER_CAP 2500 while the twin is the vm2 micro (6000 once the twin is an A1)
#   web       vm2  web/admin/webhooks + hot mirror           heap 384 MB, MemoryMax 700 MB, iptables
#   dr        vm3  DR standby gateway, watchdog, backups     heap 320 MB, MemoryMax 600 MB, ufw (as today)
#   staging   vm4  staging / canary / load-test runner        heap 320 MB, MemoryMax 600 MB, ufw (as today)
#   worker    vm5  A1 12 GB: Valhalla, tiles, batch jobs     heap 1536 MB, MemoryMax 3 GB, ufw
#
# What it does (each step prints "= unchanged" or "+ changed"):
#   sysctl (somaxconn, tw_reuse, file-max, swappiness=10, vfs_cache_pressure=50, keepalives, small socket buffers),
#   nofile limits, journald caps (200 MB / 14 days), logrotate for Caddy, unattended security upgrades (no reboot,
#   never nodejs/caddy), fail2ban (sshd), SSH keys-only / no root / no passwords, firewall per role, systemd drop-ins
#   (Restart=always, TimeoutStopSec, MemoryMax, heap size; the existing NoNewPrivileges/ProtectSystem hardening of
#   coroute-gateway.service stays), and safe gateway.env tuning keys (only added when absent, never secrets).
# What it never does: delete firewall rules, touch secrets, restart the gateway (a release or the operator does),
# enable zram (the micros already have swap files; zram costs CPU the 1/8 OCPU does not have), reboot.
set -euo pipefail

ROLE=""; DRY=0; PEER_IP=""; IGNORE_IPS=""; SKIP_SSH=0; SKIP_FW=0; FORCE_SSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --peer-ip) PEER_IP="$2"; shift 2;;
    --ignore-ips) IGNORE_IPS="$2"; shift 2;;
    --skip-ssh) SKIP_SSH=1; shift;;
    --skip-firewall) SKIP_FW=1; shift;;
    --force-ssh) FORCE_SSH=1; shift;;
    -h|--help) sed -n '2,27p' "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
case "$ROLE" in realtime|live-a1|web|dr|staging|worker) ;; *) echo "--role realtime|live-a1|web|dr|staging|worker is required" >&2; exit 2;; esac
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/files"
CHANGED=0
say() { echo "==> $*"; }
run() { if [ "$DRY" = 1 ]; then echo "   [dry-run] $*"; else eval "$@"; fi; }

# put_file <src-content-file> <dest> <mode>: writes only when different; shows the diff.
put_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then echo "   = $dest unchanged"; return 1; fi
  echo "   + $dest"
  if [ -f "$dest" ]; then diff -u "$dest" "$src" | sed 's/^/     /' | head -40 || true; else sed 's/^/     /' "$src" | head -40; fi
  if [ "$DRY" = 0 ]; then install -D -m "$mode" "$src" "$dest"; fi
  CHANGED=1
  return 0
}
tmpf() { mktemp "${TMPDIR:-/tmp}/coroute-host.XXXXXX"; }

case "$ROLE" in
  realtime|web) HEAP=384; MEM_HIGH=640M; MEM_MAX=700M; FW=iptables;;
  live-a1)      HEAP=2048; MEM_HIGH=4G; MEM_MAX=5G; FW=iptables;;
  dr|staging)   HEAP=320; MEM_HIGH=560M; MEM_MAX=600M; FW=ufw;;
  worker)       HEAP=1536; MEM_HIGH=2560M; MEM_MAX=3G; FW=ufw;;
esac
# Use whatever firewall the VM already uses (OCI Ubuntu images ship iptables rules; vm3/vm4 run ufw today).
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then FW=ufw; elif [ "$FW" = ufw ] && ! command -v ufw >/dev/null; then FW=iptables; fi

say "CoRoute host apply: role=$ROLE dry-run=$DRY firewall=$FW heap=${HEAP}MB host=$(hostname)"
if [ "$ROLE" = live-a1 ]; then
  # Round 8 stage 1: the Always Free Ampere A1 is 2 OCPU / 12 GB per account (not 4 / 24).
  arch=$(uname -m); cpus=$(nproc); memg=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
  echo "   machine: $arch, $cpus CPU, ${memg} GB"
  [ "$arch" = aarch64 ] || echo "   ! not aarch64: live-a1 is tuned for the Ampere A1 (use --role realtime on a micro)"
  { [ "$cpus" -ge 2 ] && [ "$memg" -ge 11 ]; } || echo "   ! expected 2 OCPU / 12 GB: heap ${HEAP} MB may be too large here"
fi
free -m | sed 's/^/   /'; swapon --show 2>/dev/null | sed 's/^/   /' || true

say "1/10 sysctl"
if put_file "$FILES/90-coroute-sysctl.conf" /etc/sysctl.d/90-coroute.conf; then run "sysctl --system >/dev/null"; fi
if modprobe -n tcp_bbr 2>/dev/null; then
  t=$(tmpf); printf 'net.ipv4.tcp_congestion_control=bbr\n' > "$t"
  if put_file "$t" /etc/sysctl.d/91-coroute-bbr.conf; then run "modprobe tcp_bbr && sysctl -p /etc/sysctl.d/91-coroute-bbr.conf >/dev/null"; fi
  rm -f "$t"
fi

say "2/10 limits"
put_file "$FILES/limits-coroute.conf" /etc/security/limits.d/90-coroute.conf || true

say "3/10 journald caps"
if put_file "$FILES/journald-coroute.conf" /etc/systemd/journald.conf.d/coroute.conf; then run "systemctl restart systemd-journald"; fi

say "4/10 logrotate (Caddy)"
put_file "$FILES/logrotate-caddy" /etc/logrotate.d/coroute-caddy || true

say "5/10 unattended security upgrades"
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null"; CHANGED=1; fi
put_file "$FILES/unattended-20auto" /etc/apt/apt.conf.d/20auto-upgrades || true
put_file "$FILES/unattended-52coroute" /etc/apt/apt.conf.d/52coroute-unattended || true

say "6/10 fail2ban (sshd)"
if ! dpkg -s fail2ban >/dev/null 2>&1; then run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null"; CHANGED=1; fi
t=$(tmpf); ign="$IGNORE_IPS"; [ -n "$PEER_IP" ] && ign="$ign $PEER_IP"
sed "s|__IGNORE_IPS__|${ign}|" "$FILES/fail2ban-coroute.conf" > "$t"
if put_file "$t" /etc/fail2ban/jail.d/coroute.conf; then run "systemctl enable --now fail2ban >/dev/null 2>&1; systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban"; fi
rm -f "$t"

say "7/10 SSH: keys only, no root login, no passwords"
if [ "$SKIP_SSH" = 1 ]; then echo "   skipped (--skip-ssh)"; else
  ADMIN_USER="${SUDO_USER:-}"
  KEYS=""; [ -n "$ADMIN_USER" ] && KEYS="$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys"
  if [ "$FORCE_SSH" = 0 ] && { [ -z "$ADMIN_USER" ] || [ ! -s "$KEYS" ]; }; then
    echo "   ! REFUSED: the user running sudo (${ADMIN_USER:-unknown}) has no ~/.ssh/authorized_keys. Disabling passwords now"
    echo "     could lock you out. Add your key first (ssh-copy-id), or pass --force-ssh if another key user exists."
  else
    echo "   key login verified for $ADMIN_USER ($(grep -c . "$KEYS" 2>/dev/null || echo ?) key(s))"
    for u in $(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd); do
      st=$(passwd -S "$u" 2>/dev/null | awk '{print $2}'); [ "$st" = P ] && echo "   ! user $u has a usable password: lock it after confirming key access (sudo passwd -l $u)"
    done
    if put_file "$FILES/sshd-10-coroute-hardening.conf" /etc/ssh/sshd_config.d/10-coroute-hardening.conf; then
      if [ "$DRY" = 0 ]; then
        if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd; echo "   sshd reloaded (open sessions stay)";
        else echo "   ! sshd -t failed: removing the new file"; rm -f /etc/ssh/sshd_config.d/10-coroute-hardening.conf; exit 1; fi
      fi
    fi
    [ "$DRY" = 0 ] && sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|pubkeyauthentication) ' | sed 's/^/   effective: /' || true
  fi
fi

say "8/10 firewall ($FW, role $ROLE)"
if [ "$SKIP_FW" = 1 ]; then echo "   skipped (--skip-firewall)"; else
  if [ "$FW" = iptables ]; then
    allow() { if iptables -C INPUT "$@" -j ACCEPT 2>/dev/null; then echo "   = iptables $*"; else echo "   + iptables $*"; run "iptables -I INPUT 1 $* -j ACCEPT"; CHANGED=1; fi; }
    allow -p tcp --dport 443 -m conntrack --ctstate NEW
    allow -p tcp --dport 80 -m conntrack --ctstate NEW
    allow -p udp --dport 443
    if [ "$ROLE" = realtime ] || [ "$ROLE" = live-a1 ] || [ "$ROLE" = web ]; then
      if [ -n "$PEER_IP" ]; then
        allow -p tcp -s "$PEER_IP" --dport 3000 -m conntrack --ctstate NEW
        allow -p tcp -s "$PEER_IP" --dport 3101 -m conntrack --ctstate NEW
      else echo "   ! --peer-ip not given: the gateway (3000) and mirror (3101) peer rules were not checked"; fi
    fi
    [ "$DRY" = 0 ] && [ "$CHANGED" = 1 ] && command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
  else
    if ! command -v ufw >/dev/null; then run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null"; fi
    ufw_allow() { if ufw status 2>/dev/null | grep -qE "^$1 .*ALLOW"; then echo "   = ufw $1"; else echo "   + ufw allow $1"; run "ufw allow $1 >/dev/null"; CHANGED=1; fi; }
    ufw_allow 22/tcp; ufw_allow 80/tcp; ufw_allow 443/tcp; ufw_allow 443/udp
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then echo "   + ufw enable (22/80/443 allowed first)"; run "ufw --force enable >/dev/null"; fi
  fi
  echo "   listening ports now:"; { ss -ltnH 2>/dev/null || netstat -ltn 2>/dev/null | tail -n +3; } | awk '{print $4}' | sort -u | sed 's/^/     /' || true
  echo "   (3000 must be reachable only from the peer / loopback; 3101 only from the mirror peer)"
fi

say "9/10 systemd drop-ins (gateway: Restart=always, TimeoutStopSec=45, MemoryMax=$MEM_MAX, heap ${HEAP} MB; caddy: Restart=always)"
RELOAD=0
if [ -f /etc/systemd/system/coroute-gateway.service ]; then
  t=$(tmpf); sed -e "s|__HEAP_MB__|$HEAP|" -e "s|__MEM_HIGH__|$MEM_HIGH|" -e "s|__MEM_MAX__|$MEM_MAX|" "$FILES/gateway-dropin.conf" > "$t"
  put_file "$t" /etc/systemd/system/coroute-gateway.service.d/10-v356.conf && RELOAD=1
  rm -f "$t"
  run "install -d -o coroute -g coroute -m 0750 /opt/coroute/shared /opt/coroute/shared/data"
else echo "   (no coroute-gateway.service on this VM yet: gateway drop-in skipped)"; fi
if systemctl list-unit-files caddy.service 2>/dev/null | grep -q '^caddy.service'; then put_file "$FILES/caddy-dropin.conf" /etc/systemd/system/caddy.service.d/20-v356.conf && RELOAD=1; fi
[ "$RELOAD" = 1 ] && run "systemctl daemon-reload"
echo "   restart is NOT done here: the next release (deploy/release.sh) or 'systemctl restart coroute-gateway' applies it"

say "10/10 gateway.env tuning (added only when absent; never secrets)"
ENVF=/etc/coroute/gateway.env
if [ -f "$ENVF" ]; then
  add_kv() { if grep -qE "^$1=" "$ENVF"; then echo "   = $1=$(grep -E "^$1=" "$ENVF" | head -1 | cut -d= -f2-)"; else echo "   + $1=$2"; run "printf '%s=%s\n' '$1' '$2' >> $ENVF"; CHANGED=1; fi; }
  add_kv NODE_COMPRESSION off            # Caddy compresses (zstd/gzip) off the event loop
  add_kv HTTP_KEEPALIVE_MS 75000         # above Caddy's 60 s upstream keep-alive
  add_kv ORACLE_MAX_INFLIGHT 10          # Always Free ADB session budget shared by every node
  add_kv WS_DEFLATE off                  # measured: +240 KB RSS per socket, 2x CPU on batches
  case "$ROLE" in
    realtime|web) add_kv SHUTDOWN_DRAIN_MS 15000;;   # NLB stops sending riders before the stop (needs TimeoutStopSec 45)
    live-a1)
      add_kv SHUTDOWN_DRAIN_MS 15000
      add_kv GATEWAY_ROLE live                       # stage 1: the A1 holds the rides; vm2 stays web + mirror
      add_kv LIVE_RIDER_CAP 2500                     # the pair is as safe as its smaller node (vm2 micro); 6000 with an A1 twin
      add_kv WS_MAX_CONN_PER_IP 50                   # round 8 abuse limits (NAT-friendly)
      add_kv WS_INTEREST_ABOVE 30;;                  # round 8 interest management in big rides
    dr) add_kv GATEWAY_ROLE standby;;
  esac
  echo "   recommended, set by the owner (not automatic): LIVE_RIDER_CAP (micro: 2500; A1 pair: 6000), INTEL_CONSENT_TTL_MS=300000 at > 3k riders"
  # Round 8 job queue (docs/features_355/job_queue.md, docs/quality/ROUND8_JOBS_NOTES.md): set by the owner, in order.
  echo "   round 8 jobs (owner, in rollout order): 1) JOBS_QUEUE=on on every gateway (in-process workers) 2) coroute-worker on vm2/vm5 3) JOBS_SEPARATE_WORKER=on on the live node"
  case "$ROLE" in
    realtime) echo "   realtime: keep live work only: once coroute-worker runs elsewhere set JOBS_SEPARATE_WORKER=on here (WORKER_INPROCESS=auto already yields to any other worker)";;
    web) echo "   web: WORKER_INPROCESS=auto works jobs inside this gateway (WORKER_INPROCESS_SHARE=0.5); a separate worker: deploy/worker/coroute-worker.service";;
    worker) echo "   worker: install deploy/worker/coroute-worker.service + /etc/coroute/worker.env (WORKER_TYPES, WORKER_CONCURRENCY; vm3 low priority: Nice=10, WORKER_TYPES=batch)";;
  esac
else echo "   (no $ENVF yet)"; fi

echo
if [ "$DRY" = 1 ]; then echo "DRY RUN finished: nothing was changed. Re-run without --dry-run to apply."; else echo "Applied (role $ROLE). Changed: $CHANGED"; fi
