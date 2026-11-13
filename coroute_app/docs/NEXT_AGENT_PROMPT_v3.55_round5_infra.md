# Paste-ready prompt: CoRoute round 5, infrastructure (v3.56 performance release, host tuning, DR, backups)

Copy everything below the line into the release agent that has SSH access (`ssh vm1` .. `ssh vm4`, later `vm5`).

---

You are the release agent for **CoRoute**, a motorcycle group/solo **safety** app (SOS, crash alerts, emergency
texts, live convoys). Riders may be on the road while you work. Work from the repository root on the owner's machine
(`gateway/` is the Node.js gateway). Read first: `docs/infra/INFRASTRUCTURE_PLAN_v3.56.md` (plan, numbers, decisions)
and `gateway/deploy/RUNBOOK.md` section "v3.56 infrastructure".

## Step 0: get the code in and commit it

- Prerequisite: round 4 intelligence (build 3.55.0+10026) is applied in the working tree (and committed per
  `docs/NEXT_AGENT_PROMPT_v3.55_round4_intelligence.md`).
- If the round 5 files are not in the working tree yet, unpack `coroute_v3.56_round5_infra_files.zip` with this rule:
  `R5_BASE_MD5.txt` lists, for every file, the md5 of the round-4 version it was made from. If the repo copy's md5
  matches, take the zip copy; if it differs, merge by hand; `NONE` = new file. Do not commit `R5_BASE_MD5.txt`.
- `git status`: no secrets, no real IPs. Commit: "perf(gateway): position batching, cached session gate, DB limiter,
  load shedding, metrics", "feat(deploy): host tuning, release.sh, DR standby, watchdog, encrypted backups, restore
  drill", "docs(v3.56): infrastructure plan, runbook, architecture". Push.
- Then `cd gateway && npm ci && npm test` -> expect 1266 passing (flaky alone-reruns: public_ride_mirror,
  two_node_failover, job_lease, login performance); `flutter test test/` for the `RIDER_UPDATES` change in
  `lib/data/services/realtime_service.dart`.
- URGENT FIRST: `gateway/deploy/RUNBOOK.md` section 8 and `setup_new_vm.sh` used to contain two admin passwords (still
  in git history). Ask the owner to lock or rotate both accounts before anything else.

## Ground rules (apply to every step)

1. **Never weaken SOS, crash detection, emergency texts or the ride lock.** If anything you are about to do could
   interrupt an open SOS, wait and re-check (`curl -s http://127.0.0.1:3000/api/admin/emergencies` needs an admin
   token; simpler: on vm1 `journalctl -u coroute-gateway --since -10min | grep -ci "sos\|alert"` and ask the owner).
2. **STOP on a failed health check.** After every change: `curl -s http://127.0.0.1:3000/api/health` on the VM must
   say `"status":"HEALTHY"`, and on vm1/vm2 `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/health/live`
   must be `200` (vm3 standby: `503`). Publicly `gateway/deploy/staging/smoke.sh https://coroute.devmonks.space`
   must print `SMOKE OK`. If not: undo the last step (each step says how), report, and wait for the owner.
3. **One VM at a time, vm2 before vm1** for anything that restarts a gateway or Caddy (vm1 holds the riders; vm2
   takes them while vm1 restarts). Never restart vm1 and vm2 together.
4. **No secrets anywhere**: never print, paste, commit or log a secret value; never put real IPs, OCIDs, tenancy
   e-mails or key paths in tracked files. Real values go in `gateway/deploy/inventory.local.env` (git-ignored; copy
   from `inventory.example.env`) and in files on the VMs.
5. **Dry-run first** for every script that offers it. Paste the dry-run output summary in your report.
6. **Do not commit, reset, stash or check out in git.** Only free, permissive tools; stay inside OCI Always Free (no
   paid shapes, no paid load balancer, no extra block volume in tenancy 2: it is at 194/200 GB).
7. Time box: if a step takes more than 30 minutes of trouble, stop and report.

## Owner decisions (ask the owner at the start; record the answers in the report)

| # | Decision | Default if no answer |
|---|---|---|
| D1 | The two admin accounts whose passwords were in the old RUNBOOK (section 8): lock their passwords and use keys only. Confirm which key the agent uses on each VM. | **Required before step 2** (SSH hardening refuses without a key) |
| D2 | Realtime on an A1: try for an A1 in **tenancy 1** too (recommended) / accept cross-tenancy peering for vm5 / keep vm5 as worker only. What is tenancy 2's home region? | vm5 = worker only |
| D3 | Create the second Always Free ADB in **tenancy 2** as the DR database (nightly restore target). | not created (DR = manual restore first) |
| D4 | Valhalla on vm5 and `ROUTER_KIND=valhalla` after a week of comparison. | build, do not switch |
| D5 | Map tiles: PMTiles vector (app project) / server-rendered raster on vm5 / stay on OSM tiles for now. | stay on OSM tiles |
| D6 | Umami analytics on vm5. | no |
| D7 | Weekly encrypted backup copy to the owner's own storage (outside OCI). | yes, owner downloads monthly |
| D8 | Automatic DR promotion (`WATCH_AUTO_PROMOTE=1`, after 15 min of total outage). | **off** (mail + manual promote) |
| D9 | DNS provider of devmonks.space; if Cloudflare: a scoped API token for one record (for `dns_switch.sh`). | manual DNS switch |
| D10 | Restore drill on vm4 (needs the production backup key on staging) or only on vm3. | vm3 only |
| D11 | `LIVE_RIDER_CAP=2500` on vm1/vm2. | set it |
| D12 | Does staging (vm4) have its own database (required for the load test; never production)? | if not: skip the staging load test, report |

## Step 0: inventory and preflight (read-only)

```bash
cp -n gateway/deploy/inventory.example.env gateway/deploy/inventory.local.env   # fill in real values (git-ignored)
git check-ignore gateway/deploy/inventory.local.env                              # must print the path
for h in vm1 vm2 vm3 vm4; do echo "== $h"; ssh $h 'hostname; uptime; free -m | head -2; df -h / | tail -1; swapon --show | tail -n +2; node -v; caddy version | cut -c1-20; systemctl is-active coroute-gateway caddy coroute-secrets 2>/dev/null | tr "\n" " "; echo; curl -s --max-time 5 http://127.0.0.1:3000/api/health | head -c 200; echo'; done
gateway/deploy/staging/smoke.sh https://coroute.devmonks.space
```
Record versions, memory, disk, swap and health per VM. **Verify:** vm1/vm2 HEALTHY. Note what vm3/vm4 currently run
(Caddyfile, services) before changing them: `ssh vm3 'sudo cat /etc/caddy/Caddyfile; systemctl list-units --type=service --state=running | head -40'`.

## Step 1: backups FIRST (nothing else before this is verified)

1.1 Fresh encrypted full backup on vm2 into a local folder (the gateway's own exporter; same AES-256-GCM format as
the hourly/nightly jobs):
```bash
ssh vm2 'sudo bash -c "set -a; . /etc/coroute/gateway.env; . /run/coroute/secrets.env; set +a; install -d -m 700 /var/backups/coroute-pre-v356; cd /opt/coroute/gateway && node scripts/backup_export.js --set full --out /var/backups/coroute-pre-v356"'
ssh vm2 'sudo ls -la /var/backups/coroute-pre-v356'
```
1.2 Verify it restores (decrypt + manifest + full restore into memory, no database touched). The drill script is new
in this release; run it from a temporary folder next to the old code:
```bash
scp gateway/scripts/restore_drill.js vm2:/tmp/restore_drill.js
ssh vm2 'sudo bash -c "rm -rf /tmp/drill && mkdir -p /tmp/drill/scripts && cp /tmp/restore_drill.js /tmp/drill/scripts/ && ln -s /opt/coroute/gateway/src /tmp/drill/src && ln -s /opt/coroute/gateway/node_modules /tmp/drill/node_modules && set -a && . /run/coroute/secrets.env && set +a && node /tmp/drill/scripts/restore_drill.js --latest-dir /var/backups/coroute-pre-v356"'
```
**Verify:** the JSON line says `"ok":true`, `mismatches: []`, a plausible `documents` count. **STOP if not ok.**
1.3 Check the existing scheduled backups (layer 1): `ssh vm2 'journalctl -u coroute-gateway --since -26h | grep -i "\[backup" | tail -5'`
(and vm1). Report the last `critical` and `full` runs. If none ran in 26 h, report it (do not fix secrets yourself).
1.4 (D7) Tell the owner where the pre-release backup is; it is encrypted, so a copy to their own storage is safe:
`scp vm2:/var/backups/coroute-pre-v356/* <owner folder>` (needs sudo-readable copy: `ssh vm2 'sudo cp -r /var/backups/coroute-pre-v356 /tmp/pre && sudo chown -R $USER /tmp/pre'`, then delete `/tmp/pre`).

## Step 2: host tuning per VM (dry-run first, then apply; vm4 -> vm3 -> vm2 -> vm1)

Copy the tooling (the release in step 4 brings it too, but tuning comes first):
```bash
for h in vm1 vm2 vm3 vm4; do tar -C gateway/deploy -czf - host | ssh $h 'rm -rf /tmp/coroute-host && mkdir -p /tmp/coroute-host && tar -xzf - -C /tmp/coroute-host'; done
```
For each VM (roles: vm4 `staging`, vm3 `dr`, vm2 `web --peer-ip <vm1 private ip>`, vm1 `realtime --peer-ip <vm2 private ip>`):
```bash
ssh vm4 'sudo /tmp/coroute-host/host/apply.sh --role staging --dry-run'     # read every "+" line
ssh vm4 'sudo /tmp/coroute-host/host/apply.sh --role staging'
```
**Verify after each VM:**
* a NEW ssh session still works: `ssh vm4 'sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin) "'` shows `no`;
  if the script printed "REFUSED" for SSH, stop and resolve D1 (never use `--force-ssh` without the owner).
* `ssh vm4 'sysctl vm.swappiness net.core.somaxconn; sudo fail2ban-client status sshd | head -3; sudo ufw status | head -8 || sudo iptables -S INPUT | head -12'`
* the gateway was not restarted by the script: health unchanged.
vm2 and vm1: the script adds `SHUTDOWN_DRAIN_MS=15000` and a systemd drop-in (`TimeoutStopSec=45`). Apply them with a
restart, **vm2 first**: `ssh vm2 'sudo systemctl restart coroute-gateway'` -> wait for health 200 + `/api/health/live`
200 -> then vm1 the same way (riders move to vm2 for about 30 s and back; check `journalctl -u coroute-gateway -n 50`
on vm1 shows `syncing` then `serving`). **Undo:** `sudo rm /etc/systemd/system/coroute-gateway.service.d/10-v356.conf
&& sudo systemctl daemon-reload` and remove the added `gateway.env` lines.
D11: if approved, add `LIVE_RIDER_CAP=2500` to `/etc/coroute/gateway.env` on vm1 and vm2 (applied by the release restart).
NLB (OCI console, tenancy 1): backend set health check HTTPS `/api/health/live`, interval 5000 ms, timeout 3000 ms,
retries 2. Report the old values.

## Step 3: vm4 staging refresh and load test against staging (report the numbers)

3.1 D12: staging must use its own database. `ssh vm4 'grep -E "^(PUBLIC_ORIGIN|ORACLE_SODA_URL)=" /etc/coroute/gateway.env | sed "s#//.*@#//***@#"'`.
If it is the production ADB host: STOP the load part and report (seeding production is forbidden; the seed tool refuses anyway).
3.2 Create `/etc/coroute/staging.env` on vm4 (root 0600): `PRODUCTION_DB_HOSTS=<production ADB host>` (not secret; never in git).
3.3 Caddy on vm4: back up the current file, install `deploy/caddy/Caddyfile.vm4-staging` (comes with the release in
3.4; or scp it now), `sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy`.
3.4 Deploy staging only and run the quick load gate:
```bash
gateway/deploy/release.sh --only vm4 --dry-run && gateway/deploy/release.sh --only vm4
```
**Verify:** `staging ... /api/health 200, /ws upgrade 101`, `QUICK_LOAD_OK`. Then the longer staging measurements
(generator on vm4 itself = regression gate, not capacity; if possible also run `ws_load.js` from the owner's machine):
```bash
ssh vm4 'cd /opt/coroute/gateway && sudo bash deploy/staging/quick_load.sh 600 60 staging.coroute.devmonks.space'
ssh vm4 'cd /opt/coroute/gateway && node tool/load/http_load.js --target https://staging.coroute.devmonks.space --connections 20 --seconds 30 --json'
ssh vm4 'curl -s http://127.0.0.1:3000/metrics | grep -E "^coroute_(event_loop_lag_ms|process_resident|ws_connections|db_calls_total)" | head -20; top -bn1 | head -5'
```
Report: riders joined, fan-out p50/p95/p99, SOS deliveries/expected and p99, HTTP req/s per path, gateway RSS,
event-loop lag p99, CPU steal (`%st`). Compare with the local numbers in the plan (section 4: micro ≈ 6-8x slower sustained).

## Step 4: gateway performance release (staging -> vm2 -> vm1) with release.sh

```bash
gateway/deploy/release.sh --dry-run          # read the plan
gateway/deploy/release.sh                    # confirms before vm2 and before vm1
```
The script builds the bundle (precompressed assets), deploys vm4 (smoke + quick load), then vm2, then vm1, each with
a health gate and automatic rollback. **Verify after vm2 and after vm1:** `smoke.sh https://coroute.devmonks.space`
= `SMOKE OK`; `ssh vm1 'curl -s http://127.0.0.1:3000/api/health/live'` shows `"connected":true` (mirror); one real
phone: open a ride with two phones, positions move, press SOS -> the other phone alerts within seconds -> resolve it.
**Undo:** `gateway/deploy/release.sh --rollback vm1` (then vm2).

4.2 Caddy v3.56 config (static from disk, precompressed, keep-alive, `/metrics` 404). vm2 first:
```bash
ssh vm2 'sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-v356 && sudo cp /opt/coroute/gateway/deploy/caddy/Caddyfile.vm2 /etc/caddy/Caddyfile && sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy'
```
vm1: same with `Caddyfile.vm1`, then replace the peer address in the WEB `reverse_proxy` line with vm2's private IP
(exactly as `setup_node.sh` does), validate, reload. **Verify:** `curl -sI "https://coroute.devmonks.space/assets/site.css?v=1" | grep -i -E "cache-control|content-encoding"`
shows `immutable` (and `gzip`/`zstd` with `-H 'Accept-Encoding: gzip'`); `curl -s -o /dev/null -w '%{http_code}' https://coroute.devmonks.space/metrics` = 404;
`smoke.sh` OK; the website and `/admin` load in a browser. **Undo:** copy `Caddyfile.pre-v356` back, reload.

## Step 5: vm3 DR standby, watchdog, offsite backup copy, restore drill

5.1 ADB ACL: add vm3's public IP (`gateway/deploy/update_adb_acl.py`, or the console). **Verify** from vm3:
`curl -s -o /dev/null -w '%{http_code}' <ORDS base URL>` is not a connection error.
5.2 Secrets (D-tenancy-2 Vault preferred): either create copies of every secret in a tenancy-2 Vault (+ dynamic
group for vm3 + policy `allow dynamic-group <dg> to read secret-bundles in compartment <c>`) and fill
`/etc/coroute/secret_ids.env` on vm3 with the tenancy-2 OCIDs, or the stopgap file copy (values never printed):
`ssh vm2 'sudo cat /run/coroute/secrets.env /run/coroute/caddy.env' | ssh vm3 'sudo install -m 600 /dev/stdin /etc/coroute/dr-secrets.env'`.
5.3 Install the standby and deploy the code:
```bash
scp -r gateway/deploy vm3:/tmp/coroute-deploy       # install_standby.sh runs before the first release on vm3
ssh vm3 'sudo SECRETS_MODE=file DR_TLS=dns bash /tmp/coroute-deploy/dr/install_standby.sh'   # or SECRETS_MODE=vault
ssh vm3 'sudo nano /etc/coroute/gateway.env'   # copy the NON-secret production settings from vm2 (keep GATEWAY_ROLE=standby, HOST=127.0.0.1, NODE_NAME=vm3)
gateway/deploy/release.sh --only vm3
ssh vm3 'sudo /tmp/coroute-host/host/apply.sh --role dr --dry-run && sudo /tmp/coroute-host/host/apply.sh --role dr'
ssh vm3 'sudo systemctl restart coroute-secrets && sudo systemctl restart coroute-gateway && sleep 5 && curl -s 127.0.0.1:3000/api/health | head -c 300; echo; curl -s -o /dev/null -w "live %{http_code}\n" 127.0.0.1:3000/api/health/live'
ssh vm3 'sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy; sleep 60; sudo journalctl -u caddy --since -5min | grep -i "certificate obtained" | tail -3'
```
**Verify:** health HEALTHY with `"role":"standby"` and `"leases":[]`; live `503`; certificates obtained for both
names (DuckDNS has one TXT record: if vm1/vm2 are renewing at that moment Caddy retries; check again in 10 min).
Write `/etc/coroute/dr.env` on vm3 (root 0600): `VM3_PUBLIC_IP=`, `NLB_PUBLIC_IP=`, `PUBLIC_HOST=coroute.devmonks.space`.
D9: if Cloudflare, `/etc/coroute/dns.env` (0600): `DNS_PROVIDER=cloudflare CF_API_TOKEN= CF_ZONE_ID= CF_RECORD_ID=`.
5.4 DR drill WITHOUT switching DNS: `ssh vm3 'sudo bash /opt/coroute/gateway/deploy/dr/dns_switch.sh <vm3 public ip> --dry-run'`
and `curl -s --resolve coroute.devmonks.space:443:<vm3 public ip> https://coroute.devmonks.space/api/health` from
the owner's machine (vm3 answers with a valid certificate). **Do not run promote_vm3.sh** unless vm1 and vm2 are down.
5.5 Watchdog: `ssh vm3 'sudo nano /etc/coroute/watchdog.env'` (targets with real IPs, SMTP settings, `ALERT_TO`, D8),
`sudo systemctl enable --now coroute-watchdog`, `journalctl -u coroute-watchdog -n 20`. **Verify** an alert path: add a
bogus target `test|http|http://127.0.0.1:9/x`, wait 2 minutes for the DOWN mail, remove it (a RECOVERED mail is not
sent for a removed target), restart. On vm4 run a second watchdog with targets `vm3` (vm3's public IP
`/api/health` through its Caddy with the TLS name) and `public`: copy `coroute_watchdog.js` + unit + env the same way.
5.6 Offsite backup: create the tenancy-2 bucket `coroute-offsite` (private, Standard), lifecycle rule delete after
100 days, a PAR "Permit object writes" on the bucket expiring in 1 year. Put it in `/etc/coroute/backup.env` on vm3
(`OFFSITE_PAR_URL=`, `ALERT_TO=`). Then:
```bash
ssh vm3 'sudo python3 /opt/coroute/nightly_backup.py --dry-run; sudo python3 /opt/coroute/nightly_backup.py; sudo cat /var/lib/coroute-backup/last.json'
ssh vm3 'sudo systemctl enable --now coroute-backup.timer && systemctl list-timers | grep coroute'
```
**Verify:** `last.json` has `"ok":true`, `"offsite":"uploaded 2 file(s)"`, `verify.ok` true; the objects appear in
the bucket. 5.7 Weekly restore drill (D10: vm3): install `deploy/backup/coroute-restore-drill.{service,timer}`,
`systemctl enable --now coroute-restore-drill.timer`, `systemctl start coroute-restore-drill`, check
`/var/lib/coroute-backup/last-drill.json` `"ok":true` and the drill mail.
5.8 D3: if the tenancy-2 DR ADB exists: restore the newest backup into it once
(`RESTORE_SODA_URL=... RESTORE_ORACLE_USER=... RESTORE_ORACLE_PASSWORD=... node scripts/backup_restore.js --file <newest> --wipe`
on vm3; refuses the production host) and report counts; then schedule it nightly after the backup (owner approval).

## Step 6: vm5 (only when the A1 capacity is granted)

6.1 `ssh vm5 'uname -m; nproc; free -g; df -h /'` (expect aarch64, 2 CPUs, 12 GB). Add a swap file of 8 GB for the
build (`fallocate -l 8G /swapfile2 ...`). `host/apply.sh --role worker --dry-run`, then apply.
6.2 Valhalla (`gateway/deploy/valhalla/README.md`) with `server_threads=2` and `concurrency=2` (2 OCPU) and
`mem_limit: 11g`; bind to `127.0.0.1:8002` (not a private VCN IP: vm5 is in tenancy 2). Caddy on vm5:
`deploy/caddy/Caddyfile.vm5-worker` with `GATEWAY_EGRESS_IPS` = vm1/vm2 public egress IPs in `/etc/caddy/coroute-worker.env`
(caddy unit `EnvironmentFile`), DNS `routing.<domain>` -> vm5. **Verify:** the smoke route from the README through
`https://routing.<domain>/route?json=...` from vm1 succeeds and from elsewhere answers 403.
6.3 D4: do NOT switch `ROUTER_KIND` yet. Compare 20 typical routes OSRM vs Valhalla and report.
6.4 D5 (tiles): report the PMTiles size for India and the decision; nothing in the app changes this round.
6.5 D2: if realtime on A1 is approved, write the plan for the peering / NLB backend test first; do not move riders.

## Step 7: report (to the owner)

A short report with: decisions D1-D12 and their answers; per step done / skipped / failed with the verification
output (health JSON, smoke results); the staging load numbers (step 3) next to the plan's local numbers; release id
and per-VM result; Caddy cache headers check; DR standby state (role, certificates, watchdog running, first daily
summary time); backup `last.json` and drill result; anything you undid and why; open issues (for example: tracked
files that still contain real infrastructure values such as the private IPs in `deploy/caddy/Caddyfile.vm1/.vm2`
comments and the tenancy OCID in `deploy/auto_provision_ampere.py`, which the owner should move to the untracked inventory).
