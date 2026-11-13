#!/usr/bin/env bash
# Round 8: Stage 1 of docs/infra/HIGH_TRAFFIC_PLAN_v3.57.md - make an Ampere A1 in account 1 the LIVE node.
#
#   gateway/deploy/stage1_live_a1.sh --a1 a1 --a1-ip <a1 private ip> --vm1-ip <vm1 private ip> --vm2-ip <vm2 private ip> [--step N] [--yes]
#
# Run from the owner's machine with SSH aliases a1 / vm1 / vm2 (real addresses only in the untracked
# deploy/inventory.local.env and ~/.ssh/config, never in git). Every step prints what it will do, checks first,
# and asks before changing anything (--yes skips the questions; --step N starts at step N after an interruption).
# Load balancer changes are done by you in the OCI console (or the printed oci CLI template), then confirmed here.
#
# Result: A1 (2 OCPU / 12 GB, the Always Free size per account) = GATEWAY_ROLE=live, NLB primary; vm2 = web + mirror
# twin, NLB backup; vm1 = second web node behind the A1's Caddy (no longer an NLB backend). Riders keep their rides:
# they move vm1 -> vm2 (drain) -> A1 (hand-back), the way a release already moves them.
#
# Order (why): the mirror pairs exactly two nodes, so vm1 leaves the pair BEFORE the A1 joins it; the A1 dials vm2
# (vm2 accepts any peer with the right MIRROR_KEY on its listener, so vm2 is never restarted while it holds riders);
# the A1 enters the NLB as primary only once it is linked and serving; vm2 then hands riders back to it.
# Rollback at any step: put vm1 back as NLB primary with GATEWAY_ROLE=live (RUNBOOK "Stage 1: rollback").
set -euo pipefail

A1=a1; VM1=vm1; VM2=vm2; A1_IP=""; VM1_IP=""; VM2_IP=""; STEP=1; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --a1) A1="$2"; shift 2;; --vm1) VM1="$2"; shift 2;; --vm2) VM2="$2"; shift 2;;
    --a1-ip) A1_IP="$2"; shift 2;; --vm1-ip) VM1_IP="$2"; shift 2;; --vm2-ip) VM2_IP="$2"; shift 2;;
    --step) STEP="$2"; shift 2;; --yes) YES=1; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[ -n "$A1_IP" ] && [ -n "$VM1_IP" ] && [ -n "$VM2_IP" ] || { echo "--a1-ip, --vm1-ip and --vm2-ip (private addresses) are required" >&2; exit 2; }

say() { printf '\n==> %s\n' "$*"; }
ask() { [ "$YES" = 1 ] && return 0; read -r -p "    $* [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }
wait_done() { [ "$YES" = 1 ] && { echo "    (--yes: assuming done: $*)"; return 0; }; read -r -p "    Done in the console: $* ? [y/N] " a; [ "$a" = y ] || { echo "stopped; resume with --step $1"; exit 1; }; }
remote() { local host="$1"; shift; ssh -o BatchMode=yes "$host" "$@"; }
live_health() { remote "$1" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/health/live" 2>/dev/null || echo 000; }
live_riders() { remote "$1" "curl -s http://127.0.0.1:3000/api/health/live" 2>/dev/null | sed -n 's/.*"liveRiders":\([0-9]*\).*/\1/p'; }
mirror_up() { remote "$1" "curl -s http://127.0.0.1:3000/metrics" 2>/dev/null | sed -n 's/^coroute_mirror_up \([01]\).*/\1/p'; }
set_env() { # host key value: sets KEY=value in /etc/coroute/gateway.env (replaces or appends; never secrets)
  remote "$1" "sudo sed -i '/^$2=/d' /etc/coroute/gateway.env && echo '$2=$3' | sudo tee -a /etc/coroute/gateway.env >/dev/null"
}

step() { [ "$STEP" -le "$1" ]; }

if step 1; then
  say "1/8 Check the A1 ($A1): Ampere ARM, 2 OCPU / 12 GB, reachable, Node 20+"
  remote "$A1" 'uname -m; nproc; awk "/MemTotal/ {printf \"%d GB\n\", \$2/1048576}" /proc/meminfo; node -v 2>/dev/null || echo "node: missing"'
  echo "    vm1 live: $(live_health "$VM1") ($(live_riders "$VM1") riders), vm2 live: $(live_health "$VM2"), mirror up on vm1: $(mirror_up "$VM1")"
  ask "Continue (A1 looks right, vm1 + vm2 healthy)?" || exit 1
fi

if step 2; then
  say "2/8 Install the gateway on the A1 (setup_node.sh as a LIVE node paired with vm2), host tuning live-a1"
  echo "    on $A1: sudo NODE_NAME=a1 NODE_ROLE=live NODE_IP=$A1_IP PEER_IP=$VM2_IP bash /opt/coroute/gateway/deploy/setup_node.sh"
  echo "            sudo /opt/coroute/gateway/deploy/host/apply.sh --role live-a1 --peer-ip $VM2_IP"
  echo "    then from here: gateway/deploy/release.sh --only $A1   (the release health gate must pass)"
  echo "    Secrets: the same Vault secrets as vm1 (instance principal of the A1 in the dynamic group), MIRROR_KEY included."
  if ask "Run setup_node.sh and apply.sh on $A1 now?"; then
    remote "$A1" "sudo NODE_NAME=a1 NODE_ROLE=live NODE_IP=$A1_IP PEER_IP=$VM2_IP bash /opt/coroute/gateway/deploy/setup_node.sh"
    remote "$A1" "sudo /opt/coroute/gateway/deploy/host/apply.sh --role live-a1 --peer-ip $VM2_IP"
  fi
  # The A1 dials vm2 (vm2's listener accepts it); LIVE_RIDER_CAP: the pair is as safe as the vm2 micro.
  if ask "Set MIRROR_PEER_URL=ws://$VM2_IP:3101/mirror, GATEWAY_ROLE=live, LIVE_RIDER_CAP=2500 on $A1 (gateway NOT started yet)?"; then
    set_env "$A1" MIRROR_PEER_URL "ws://$VM2_IP:3101/mirror"; set_env "$A1" GATEWAY_ROLE live; set_env "$A1" LIVE_RIDER_CAP 2500
    remote "$A1" "sudo systemctl stop coroute-gateway || true"
  fi
fi

if step 3; then
  say "3/8 Firewalls: vm2 accepts the A1 on 3000/3101; vm1 accepts the A1 on 3000 (web routes from the A1's Caddy)"
  if ask "Run apply.sh on vm2 (--peer-ip $A1_IP) and vm1 (--peer-ip $A1_IP)?"; then
    remote "$VM2" "sudo /opt/coroute/gateway/deploy/host/apply.sh --role web --peer-ip $A1_IP --skip-ssh"
    remote "$VM1" "sudo /opt/coroute/gateway/deploy/host/apply.sh --role web --peer-ip $A1_IP --skip-ssh"
  fi
fi

if step 4; then
  say "4/8 Drain vm1 to vm2 (vm1 leaves the NLB and the mirror pair; riders keep their rides on vm2)"
  echo "    OCI console: Network Load Balancer -> backend set -> vm1: set 'drain' (or offline). vm2 stays the backup."
  echo "    oci nlb backend update --network-load-balancer-id <nlb-ocid> --backend-set-name <set> --backend-name <vm1 backend> --is-drain true --is-backup false --is-offline false --weight 1"
  wait_done 4 "vm1 is draining in the NLB"
  if ask "Restart vm1's gateway as GATEWAY_ROLE=web without a mirror (its riders get RECONNECT and move to vm2)?"; then
    set_env "$VM1" GATEWAY_ROLE web
    remote "$VM1" "sudo sed -i '/^MIRROR_LISTEN_HOST=/d;/^MIRROR_PEER_URL=/d' /etc/coroute/gateway.env && sudo systemctl restart coroute-gateway"
  fi
  for i in $(seq 1 30); do n=$(live_riders "$VM2"); echo "    vm2 holds ${n:-?} live riders"; sleep 2; [ "$i" -ge 5 ] && break; done
fi

if step 5; then
  say "5/8 Start the A1: it dials vm2, syncs every ride (snapshot), then serves"
  ask "Start coroute-gateway on $A1?" && remote "$A1" "sudo systemctl start coroute-gateway"
  for i in $(seq 1 30); do
    h=$(live_health "$A1"); m=$(mirror_up "$A1")
    echo "    A1 /api/health/live $h, mirror up $m"
    [ "$h" = 200 ] && [ "$m" = 1 ] && break
    sleep 2
  done
  [ "$(live_health "$A1")" = 200 ] || { echo "    ! the A1 is not serving: check journalctl -u coroute-gateway on it; vm2 still holds the rides"; exit 1; }
  echo "    Caddy on the A1: deploy/caddy/Caddyfile.vm1 with the WEB upstreams '$VM2_IP:3000 $VM1_IP:3000' (vm2 first)."
  echo "    sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy"
  wait_done 5 "Caddy on the A1 is installed and validated"
fi

if step 6; then
  say "6/8 NLB: the A1 becomes the primary backend; vm2 stays the backup; vm1 is removed"
  echo "    oci nlb backend create ... --ip-address $A1_IP --port 443 --is-backup false   (health check: HTTPS /api/health/live, 5 s / 3 s / 2 retries)"
  echo "    oci nlb backend delete ... --backend-name <vm1 backend>"
  wait_done 6 "the A1 is the NLB primary and healthy; vm1 is removed"
fi

if step 7; then
  say "7/8 Hand-back: vm2 tells its riders to reconnect (MIRROR_HANDBACK_DELAY_MS after the A1 serves); they land on the A1"
  for i in $(seq 1 40); do
    a=$(live_riders "$A1"); b=$(live_riders "$VM2")
    echo "    A1 ${a:-?} riders, vm2 ${b:-?} riders (the count is the pair's: watch it move in coroute_ws_connections)"
    sleep 3; [ "$i" -ge 10 ] && break
  done
  remote "$A1" "curl -s http://127.0.0.1:3000/metrics | grep -E '^coroute_ws_connections|^coroute_mirror_up|coroute_event_loop_lag_ms\\{quantile=\"0.99\"'" || true
  remote "$VM2" "curl -s http://127.0.0.1:3000/metrics | grep -E '^coroute_ws_connections'" || true
fi

if step 8; then
  say "8/8 Make it permanent on vm2 and check the watchdog"
  if ask "Set MIRROR_PEER_URL=ws://$A1_IP:3101/mirror on vm2 (used from its next restart; restart only once riders are on the A1)?"; then
    set_env "$VM2" MIRROR_PEER_URL "ws://$A1_IP:3101/mirror"
  fi
  echo "    watchdog (vm3): add 'a1|http|https://<a1-public-ip>/api/health/live|coroute.duckdns.org' to WATCH_TARGETS; keep vm1 as a web check."
  echo "    Gate: run tool/load/ws_load.js --preset gate2x --target-riders 2500 against staging and the SOS probe; record results in docs/infra/."
  echo "    LIVE_RIDER_CAP stays 2500 until the twin is an A1 too (stage 2), then 6000."
fi
echo
echo "Stage 1 steps finished. RUNBOOK: 'Stage 1: A1 as the live node'."
