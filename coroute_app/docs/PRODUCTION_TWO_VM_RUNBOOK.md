# CoRoute production: two-VM runbook

Ordered, copy-pasteable steps for running the CoRoute gateway on two OCI VMs behind a Network Load Balancer.
Every command block says where it runs: **[laptop]** (OCI Cloud Shell or WSL/Linux with the OCI CLI and this repo; commands use GNU `base64`/`date`),
**[VM1]**, **[VM2]** (over Bastion, as `ubuntu` with sudo), **[console]** (OCI web console).
Replace `<...>` placeholders. Nothing in this document is a secret; secrets live in OCI Vault only.

Reference files (all in `coroute_app/gateway/`):
`deploy/setup_node.sh`, `deploy/fetch_secrets.sh`, `deploy/coroute-gateway.service`, `deploy/coroute-secrets.service`,
`deploy/caddy/Caddyfile.vm1`, `deploy/caddy/Caddyfile.vm2`, `deploy/route_split.md`, `deploy/gen_caddy_routes.js`,
`deploy/.env.example`, `scripts/backup_restore.js`.

---

## 1. Architecture

```
                         coroute.duckdns.org  (A record -> NLB reserved public IP)
                                       |
                        +--------------+---------------+
                        |  OCI Network Load Balancer   |  TCP 443 (+80), source IP preserved
                        |  health: HTTPS :443 /api/health/live -> 200
                        |  backend VM1 = primary, VM2 = is_backup
                        +------+-----------------+------+
                               |                 :  (only when VM1 is unhealthy)
                               v                 v
  +----------------------------------+    +----------------------------------+
  | VM1  <vm1-private-ip>   GATEWAY_ROLE=live|    | VM2  <vm2-private-ip>   GATEWAY_ROLE=web |
  | Caddy :443 (TLS, DuckDNS DNS-01)  |    | Caddy :443 (TLS, DuckDNS DNS-01)  |
  |  LIVE routes -> 127.0.0.1:3000    |    |  everything -> 127.0.0.1:3000     |
  |  WEB routes  -> <vm2-private-ip>:3000 ---+--->|                                   |
  |               (fallback local)    |    |                                   |
  | gateway :3000  rooms, sockets     |<==>| gateway :3000  website, payments, |
  |                mirror :3101       |3101|  admin, mirror copy of all rides  |
  +----------------+-----------------+    +----------------+------------------+
                   |  SODA REST (HTTPS)                    |
                   +-------------------+-------------------+
                                       v
                       Oracle Autonomous DB (ACL: the two VMs' egress IPs)
           OCI Vault (secrets, instance principal)    Object Storage (photos PAR, backups PAR)
```

- **LIVE** (VM1): WebSocket `/ws`, convoys/rooms, SOS dispatch and live links, Ride Guardian, live pages,
  admin screens that read live rooms. **WEB** (VM2): website, auth, profile reads, payments, memberships,
  subscriptions, coupons, reviews/photos, other admin, downloads. The audited list with reasons is
  `gateway/deploy/route_split.md`; the VM1 Caddy matcher is generated from it.
- **Failover**: VM1 unhealthy -> NLB sends everything to VM2, which already holds a mirror copy of every ride
  (port 3101). VM2 down -> VM1's Caddy serves WEB routes locally (active health checks, 10 s).
- **Scheduled jobs** run once across both VMs (`src/job_lease.js`, `leases` collection): web-preferred
  `retention`, `db-keepalive`, `subscriptions`, `coupon-seed`, `backup-critical`, `backup-full` on VM2;
  live-preferred `guardian-push`, `convoy-auto-end` on VM1. The other node takes a job over only after the
  lease has been expired for 120 s, and hands it back when the preferred node returns.
- **Secrets**: OCI Vault -> `coroute-secrets.service` (instance principal, `deploy/fetch_secrets.sh`) ->
  `/run/coroute/secrets.env` (tmpfs, 0600). Nothing secret on disk or in images.

## 2. Prerequisites

- Two Ubuntu 22.04/24.04 VMs in one VCN/subnet with private IPs **<vm1-private-ip>** (VM1) and **<vm2-private-ip>** (VM2)
  (E2.1.Micro or A1.Flex), Oracle Cloud Agent with the **Bastion** plugin enabled (Instance -> Oracle Cloud Agent).
- The Autonomous Database with the dedicated low-privilege `COROUTE` schema (see `deploy/RUNBOOK.md` section 2)
  and its SODA URL.
- A DuckDNS account with the subdomain `coroute` and its token.
- [laptop] OCI CLI configured for your tenancy (`oci setup config`), `jq`, `openssl`, `ssh`. Shell variables
  used below:

```bash
# [laptop]
export C=<compartment OCID>            # compartment holding everything
export REGION=<region, e.g. ap-hyderabad-1>
export NS=$(oci os ns get --query data --raw-output)
export VM1_ID=<VM1 instance OCID>  VM2_ID=<VM2 instance OCID>
```

## 3. OCI console / CLI setup (once, in this order)

### 3.1 Network security (NSG) and firewall

[console] Networking -> VCN -> Network Security Groups -> create **coroute-gw**, attach it to both VMs' VNICs
(Instance -> Attached VNICs -> Edit -> NSG). Rules:

| Dir | Source / Dest | Proto/Port | Why |
|---|---|---|---|
| Ingress | 0.0.0.0/0 | TCP 443 | clients via NLB (source IP preserved) and NLB health checks |
| Ingress | 0.0.0.0/0 | TCP 80 | HTTP -> HTTPS redirect (optional) |
| Ingress | <vm1-private-ip>/32 | TCP 3000, TCP 3101 | VM1 -> VM2 gateway and mirror |
| Ingress | <vm2-private-ip>/32 | TCP 3000, TCP 3101 | VM2 -> VM1 gateway and mirror |
| Ingress | <Bastion private endpoint IP>/32 | TCP 22 | SSH through Bastion only (3.2) |
| Egress | 0.0.0.0/0 | all | ADB, Vault, Object Storage, Razorpay, OSM, DuckDNS, apt |

Then **remove port 22 from 0.0.0.0/0** everywhere: VCN -> Security Lists -> Default Security List -> delete the
`0.0.0.0/0 TCP 22` ingress rule (and any 3000 rule). `setup_node.sh` mirrors the same ports in iptables
(443/80 public, 3000/3101 from the peer only).

### 3.2 Bastion (replaces public SSH)

[console] Identity & Security -> Bastion -> Create: target the VMs' subnet, CIDR allow list = your public IP/32.
Note the Bastion's **private endpoint IP** (used in the NSG rule above).

```bash
# [laptop] one session per VM (3 h); prints the SSH command
oci bastion session create-managed-ssh --bastion-id <bastion OCID> --target-resource-id $VM1_ID \
  --target-os-username ubuntu --ssh-public-key-file ~/.ssh/id_ed25519.pub --session-ttl 10800 --wait-for-state SUCCEEDED
# Connect (session OCID from the output; same for VM2 with <vm2-private-ip>):
ssh -i ~/.ssh/id_ed25519 -o ProxyCommand="ssh -i ~/.ssh/id_ed25519 -W %h:%p -p 22 <session OCID>@host.bastion.$REGION.oci.oraclecloud.com" ubuntu@<vm1-private-ip>
```
Use the same `-o ProxyCommand=...` with `scp` to copy files.

### 3.3 Autonomous DB network ACL

[VM1] and [VM2]: `curl -s https://ifconfig.me` -> each VM's egress IP (its public IP, or the NAT gateway IP).
[console] Autonomous Database -> Network -> Access control list -> Edit: **IP addresses = the two egress IPs only**
(add your laptop IP temporarily when using Database Actions, then remove it). If the VMs egress through one NAT
gateway, that single IP is the list. Check from each VM:
`curl -s -o /dev/null -w '%{http_code}\n' -u COROUTE:<pw> <ORACLE_SODA_URL>` -> `200` (do this once by hand;
the password is not stored on the VM).

### 3.4 Vault and secrets

[console] Identity & Security -> Vault -> Create vault **coroute-vault** (default, not virtual private) -> Master
encryption key **coroute-key** (Software protection, AES 256). Create one secret per row (name `coroute-<NAME>`,
plain-text content). Generate random values on the laptop without echoing them:

| NAME (env key) | Value | Notes |
|---|---|---|
| JWT_SECRET | `openssl rand -base64 48` | signs sessions |
| JWT_SECRET_PREVIOUS | (only during a rotation, 6.1) | verification only |
| ORACLE_PASSWORD | COROUTE schema password | 6.2 to rotate |
| RAZORPAY_LIVE_KEY_ID / RAZORPAY_LIVE_KEY_SECRET / RAZORPAY_LIVE_WEBHOOK_SECRET | from Razorpay | or set in the admin console |
| TWILIO_AUTH_TOKEN (and other SMS provider keys in use) | from the provider | |
| MIRROR_KEY | `openssl rand -base64 48` | same on both VMs |
| SETTINGS_ENCRYPTION_KEY | `openssl rand -base64 32` | Razorpay settings + checkout links |
| BACKUP_ENCRYPTION_KEY | `openssl rand -base64 32` | **also store in your password manager** |
| REVIEW_PHOTO_PAR_URL | PAR URL from 3.6 | bearer secret |
| BACKUP_PAR_URL | PAR URL from 3.6 | bearer secret |
| DUCKDNS_TOKEN | DuckDNS token | Caddy only |

```bash
# [laptop] create a secret without the value touching shell history
export VAULT=<vault OCID> KEY=<master key OCID>
mk() { read -rs -p "$1: " V; echo; oci vault secret create-base64 --compartment-id $C --vault-id $VAULT --key-id $KEY \
  --secret-name "coroute-$1" --secret-content-content "$(printf %s "$V" | base64 -w0)" --query data.id --raw-output; unset V; }
mk ORACLE_PASSWORD       # paste the value; prints the secret OCID -> keep for secret_ids.env
# random values generated straight into the Vault (never displayed): NAME and number of random bytes
mkgen() { oci vault secret create-base64 --compartment-id $C --vault-id $VAULT --key-id $KEY --secret-name "coroute-$1" \
  --secret-content-content "$(openssl rand -base64 $2 | tr -d '\n' | base64 -w0)" --query data.id --raw-output; }
mkgen JWT_SECRET 48; mkgen MIRROR_KEY 48; mkgen SETTINGS_ENCRYPTION_KEY 32; mkgen BACKUP_ENCRYPTION_KEY 32
# copy BACKUP_ENCRYPTION_KEY into your password manager (backups are unreadable without it):
oci secrets secret-bundle get --secret-id <its OCID> --query 'data."secret-bundle-content".content' --raw-output | base64 -d; echo
```
Keep the printed OCIDs: they go into `/etc/coroute/secret_ids.env` on both VMs (`NAME=<OCID>`; not secret).

### 3.5 Dynamic group and policy (instance principal)

[console] Identity -> Domains -> Default -> Dynamic groups -> create **coroute-gateways**:
```
Any {instance.id = '<VM1 instance OCID>', instance.id = '<VM2 instance OCID>'}
```
[console] Identity -> Policies (compartment `<compartment>`) -> create **coroute-gateways-secrets**:
```
Allow dynamic-group coroute-gateways to read secret-bundles in compartment <compartment> where target.vault.id = '<vault OCID>'
Allow service objectstorage-<region> to manage object-family in compartment <compartment>
```
(With identity domains the subject may need to be `dynamic-group 'Default'/'coroute-gateways'`. The second line
lets lifecycle rules delete objects.) Check later from a VM: `oci secrets secret-bundle get --auth instance_principal
--secret-id <any secret OCID> --query 'data."secret-bundle-content"."content-type"'` -> `"BASE64"`.

### 3.6 Object Storage buckets, PARs, lifecycle

```bash
# [laptop] private buckets, versioning off (deleted photos must not survive as old versions)
oci os bucket create --compartment-id $C --name coroute-review-photos --public-access-type NoPublicAccess --versioning Disabled
oci os bucket create --compartment-id $C --name coroute-backups       --public-access-type NoPublicAccess --versioning Disabled
# PARs (bucket level). Photos: read + write. Backups: write + list, and read (the backup job reads its state
# file coroute/state/last-full.json; restores read the backups).
EXP=$(date -u -d '+1 year' +%Y-%m-%dT00:00:00Z)
oci os preauth-request create --bucket-name coroute-review-photos --name gw-photos  --access-type AnyObjectReadWrite --time-expires $EXP --query 'data."access-uri"' --raw-output
oci os preauth-request create --bucket-name coroute-backups       --name gw-backups --access-type AnyObjectReadWrite --bucket-listing-action ListObjects --time-expires $EXP --query 'data."access-uri"' --raw-output
# Each PAR URL = https://objectstorage.$REGION.oraclecloud.com<access-uri>  (ends with /o/) -> Vault (3.4)
oci os object-lifecycle-policy put --bucket-name coroute-backups --force --items \
  '[{"name":"expire-30d","action":"DELETE","timeAmount":30,"timeUnit":"DAYS","isEnabled":true,"objectNameFilter":{"inclusionPrefixes":["coroute/"]}}]'
```
Put a calendar reminder 2 weeks before `$EXP` (PAR rotation, 6.4).

### 3.7 Network Load Balancer

[console] Networking -> Load balancers -> **Network load balancer** -> Create:
- Public, **reserved public IP** (create new: `coroute-nlb-ip`), the VMs' VCN, a public subnet.
- Listener **tcp443**: TCP, port 443. Backend set **gw-443**:
  - Preserve source IP: **on** (default; the gateway rate-limits by client IP)
  - Instant failover: **on**, with TCP reset **on** (sockets on a failed VM are reset at once and reconnect)
  - Fail open: off. "Operationally active backends preferred": **off** (traffic must return to VM1)
  - Health check: **HTTPS**, port **443**, URL path **/api/health/live**, status **200**,
    interval **5000 ms**, timeout **3000 ms**, retries **2** (failover in about 10-15 s)
  - Backends: **<vm1-private-ip>:443** (weight 1) and **<vm2-private-ip>:443** with **Backup = on** (`is_backup`)
- Second listener **tcp80** (TCP 80) with backend set **gw-80**: same settings, backends on port 80,
  health check still HTTPS 443 /api/health/live.

The OCI NLB supports `is_backup` per backend: VM2 receives no new traffic until VM1 fails its health check. If
your console/region does not show "Backup", use weights instead (VM1 weight 100, VM2 weight 1) and accept that
~1 % of new connections land on VM2 (it serves them correctly through the mirror), or drain VM2
(`is_drain`) during normal operation and undrain it in an incident.

Health checks connect by IP without SNI; Caddy answers them through `default_sni` and its `:443` block (only
`/api/health/live`, everything else 404). If backends show *Critical* while `curl -k https://<vm1-private-ip>/api/health/live`
answers 200 on the VM, switch the health check to TCP 443 temporarily and report it.

### 3.8 DuckDNS

```bash
# [laptop]  -> "OK"
curl "https://www.duckdns.org/update?domains=coroute&token=<DuckDNS token>&ip=<NLB reserved public IP>"
```
Remove any DuckDNS updater on old VMs (`crontab -l`, `/etc/cron.d/*duck*`): it would point the name back at a VM.

## 4. Provision the nodes (VM2 first, then VM1)

DuckDNS holds a single TXT record, so the two Caddy instances must not request certificates at the same time:
finish VM2 (certificate obtained) before starting Caddy on VM1. Renewals then fall on different days.

### 4.1 Build and copy the code
```bash
# [laptop] from coroute_app/
node gateway/deploy/gen_caddy_routes.js --check        # every route classified LIVE/WEB
tar --exclude=gateway/node_modules --exclude='gateway/.env*' --exclude=gateway/deploy/__pycache__ \
    -czf /tmp/gateway.tgz gateway
scp -o ProxyCommand="..." /tmp/gateway.tgz ubuntu@<vm2-private-ip>:/tmp/
```

### 4.2 Provision
```bash
# [VM2]
sudo mkdir -p /opt/coroute && sudo tar -xzf /tmp/gateway.tgz -C /opt/coroute
cd /opt/coroute/gateway
sudo NODE_NAME=vm2 NODE_ROLE=web NODE_IP=<vm2-private-ip> PEER_IP=<vm1-private-ip> bash deploy/setup_node.sh
sudo PUPPETEER_SKIP_DOWNLOAD=1 npm ci --omit=dev --no-audit --no-fund
```
(VM1: `NODE_NAME=vm1 NODE_ROLE=live NODE_IP=<vm1-private-ip> PEER_IP=<vm2-private-ip>`.) Re-running `setup_node.sh` is safe.

### 4.3 Settings (no secrets) - `/etc/coroute/gateway.env`
`setup_node.sh` created it from `deploy/.env.example` and set `NODE_ENV`, `HOST=0.0.0.0`, `PORT`, `NODE_NAME`,
`GATEWAY_ROLE`, `PUBLIC_ORIGIN=https://coroute.duckdns.org` and `TRUST_PROXY` (VM1 `loopback`, VM2
`loopback,<vm1-private-ip>`). Edit (`sudo nano /etc/coroute/gateway.env`) and set at least:

```ini
ORACLE_SODA_URL=https://<adb-host>/ords/coroute/soda/latest
ORACLE_USER=COROUTE
GOOGLE_CLIENT_IDS=<...>
BOOTSTRAP_ADMIN_EMAILS=<...>
REVIEW_PHOTO_STORE=par
LIVE_RIDER_CAP=150                      # same value on both VMs (section 9.4)
# mirror  (VM1 values; on VM2 swap the two IPs)
MIRROR_LISTEN_HOST=<vm1-private-ip>
MIRROR_PEER_URL=ws://<vm2-private-ip>:3101/mirror
```
Do not put any key from the Vault table into this file.

### 4.4 Secret OCIDs - `/etc/coroute/secret_ids.env`
Uncomment and fill every line with the OCIDs from 3.4 (`NAME=ocid1.vaultsecret...`). Then:
```bash
# [VM2]
sudo systemctl restart coroute-secrets          # journal: "wrote N secret(s): ... (values not shown)"
sudo systemctl restart coroute-gateway caddy
journalctl -u caddy -f                          # wait for "certificate obtained successfully"
curl -s http://127.0.0.1:3000/api/health | jq '{status,role,node,leases,version}'
```
Repeat 4.1-4.4 for VM1 once VM2 has its certificate.

### 4.5 Website
The website is served by the gateway itself (`gateway/public`, WEB role: VM2, with VM1 as fallback), so it deploys with
the gateway tarball on both VMs. iPhone download buttons appear only when `APP_STORE_URL` (or `IOS_TESTFLIGHT_URL` /
`IOS_IPA_URL`) is set in `/etc/coroute/gateway.env` on BOTH VMs; otherwise every page says "No iOS version yet."
Copy the current APKs into `gateway/public/` before building the tarball (the /download links serve them).

## 5. Verification checklist

Run after provisioning and after every deploy. Expected values in comments.

```bash
# [laptop]
curl -s https://coroute.duckdns.org/api/health | jq '{status,role,node,db}'   # HEALTHY, live, vm1, UP
curl -s https://coroute.duckdns.org/api/health/live | jq '{ok,state,mirror}'   # ok true, serving, connected true
curl -sI https://coroute.duckdns.org/ | grep -i -E 'x-coroute-node|strict-transport'   # vm2/web ; max-age=31536000
curl -sI https://coroute.duckdns.org/api/meta | grep -i x-coroute-node          # vm2/web   (WEB route)
curl -s -o /dev/null -w '%{http_code}\n' https://coroute.duckdns.org/api/convoys/active   # 401 from vm1 (LIVE)
curl -sI https://coroute.duckdns.org/api/convoys/active | grep -i x-coroute-node          # vm1/live
openssl s_client -connect coroute.duckdns.org:443 -servername coroute.duckdns.org -tls1_1 </dev/null 2>&1 | grep -i -m1 -E 'alert|no protocols'  # TLS 1.1 refused
curl -sI http://coroute.duckdns.org/ | head -1                                   # 308 redirect to https
```
```bash
# [VM1]
curl -s http://<vm2-private-ip>:3000/api/health | jq '{role,node,leases}'   # web, vm2, [retention, db-keepalive, subscriptions, backup-...]
curl -s http://127.0.0.1:3000/api/health | jq '.leases'              # [convoy-auto-end] (+ guardian-push when enabled)
sudo ls -l /run/coroute; findmnt -no FSTYPE /run                    # secrets.env -rw------- coroute; tmpfs
systemctl is-active coroute-secrets coroute-gateway caddy chrony     # active x4
sudo iptables -S INPUT | grep -E 'dport (443|80|3000|3101)'          # 3000/3101 only from <vm2-private-ip>
journalctl -u coroute-gateway --since '-10 min' | grep -i -E 'error|lease' | tail
```
- [console] NLB -> backend set -> backends: VM1 **OK**, VM2 **OK (backup)**.
- App: sign in, start a ride with two phones, send a chat and a position, raise and resolve a test SOS (test
  group), open the website, the download page, the admin console (payments page loads keys as "set").
- Backups: after the first hour, `journalctl -u coroute-gateway | grep '\[backup\]'` on VM2 shows a critical backup.

## 6. Secret rotation

General pattern: update the Vault secret (new version becomes CURRENT), then on **VM2 first, then VM1**:
`sudo systemctl restart coroute-secrets && sudo systemctl restart coroute-gateway`.
```bash
# [laptop] new version of an existing secret
upd() { read -rs -p "$1: " V; echo; oci vault secret update-base64 --secret-id "$2" \
  --secret-content-content "$(printf %s "$V" | base64 -w0)" >/dev/null && echo updated; unset V; }
```

### 6.1 JWT_SECRET (no forced sign-outs)
Tokens signed by one VM must stay valid on the other during the switch, so it takes three steps:
1. **Prepare**: create secret `coroute-JWT_SECRET_PREVIOUS` holding the **new** value; add
   `JWT_SECRET_PREVIOUS=<its OCID>` to `secret_ids.env` on both VMs; restart secrets + gateway (VM2, VM1).
   Both VMs now accept the new secret but still sign with the old one. Log: `JWT_SECRET_PREVIOUS is configured`.
2. **Swap**: `upd JWT_SECRET <JWT_SECRET OCID>` (new value) and `upd JWT_SECRET_PREVIOUS <its OCID>` (old value);
   restart (VM2, VM1). New tokens use the new secret; old tokens are accepted and refreshed (`X-CoRoute-Token`).
3. **After 30 days** (`JWT_TTL_DAYS`): remove the `JWT_SECRET_PREVIOUS` line from `secret_ids.env` on both VMs,
   restart, then delete the Vault secret. Riders who did not open the app in those 30 days sign in again.
Make sure `SETTINGS_ENCRYPTION_KEY` was deployed and the admin payment page opened once before step 2
(that migrates saved Razorpay secrets off the JWT-derived key).

### 6.2 Database password
```sql
-- [console] ADB -> Database Actions -> SQL, as ADMIN
ALTER USER COROUTE IDENTIFIED BY "<new password>";
```
Order: `upd ORACLE_PASSWORD <OCID>` -> run the ALTER USER -> immediately restart secrets + gateway on VM2 and
VM1. Between ALTER and restart (seconds) database calls fail; rides continue in memory and are written after the
restart.

### 6.3 Other secrets
- **MIRROR_KEY**: same value on both; restart VM2 then VM1 promptly (the mirror link is down in between).
- **SETTINGS_ENCRYPTION_KEY**: no automatic re-encryption from an old settings key: after rotating, re-enter the
  Razorpay secrets in the admin console. Checkout links issued in the last minutes stop working.
- **BACKUP_ENCRYPTION_KEY**: new backups use the new key. Keep the old key (password manager) until the last
  backup made with it has expired (30 days).
- **DUCKDNS_TOKEN**: regenerate on duckdns.org, `upd`, then `systemctl restart coroute-secrets caddy` (both VMs).
- **Razorpay / SMS keys**: rotate at the provider, `upd`, restart.

### 6.4 PAR URLs
Create a new PAR (3.6), `upd REVIEW_PHOTO_PAR_URL` / `BACKUP_PAR_URL`, restart both VMs, verify (5), then
delete the old PAR: `oci os preauth-request delete --bucket-name <bucket> --par-id <old id>`.

## 7. Deploy procedure (one VM at a time, VM2 first)

```bash
# [laptop]
node gateway/deploy/gen_caddy_routes.js --check && (cd gateway && npm test)
tar --exclude=gateway/node_modules --exclude='gateway/.env*' --exclude=gateway/deploy/__pycache__ -czf /tmp/gateway.tgz gateway
scp -o ProxyCommand="..." /tmp/gateway.tgz ubuntu@<vm2-private-ip>:/tmp/      # then the same to <vm1-private-ip>
```
```bash
# [VM2] then, after its checks pass, [VM1]
set -e
REL=/opt/coroute/releases/$(date -u +%Y%m%d%H%M); sudo mkdir -p $REL
sudo tar -xzf /tmp/gateway.tgz -C $REL --strip-components=1
(cd $REL && sudo PUPPETEER_SKIP_DOWNLOAD=1 npm ci --omit=dev --no-audit --no-fund)
sudo rsync -a --delete --exclude data/ /opt/coroute/gateway/ /opt/coroute/rollback/    # keep the running version
sudo rsync -a --delete --exclude data/ $REL/ /opt/coroute/gateway/
# Only when deploy/ changed: units / Caddyfile
sudo NODE_NAME=<vm> NODE_ROLE=<role> NODE_IP=<ip> PEER_IP=<peer> bash /opt/coroute/gateway/deploy/setup_node.sh
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
sudo systemctl restart coroute-gateway
sleep 5; curl -s http://127.0.0.1:3000/api/health | jq '{status,version,role}'
curl -s http://127.0.0.1:3000/api/health/live | jq '{ok,state,mirror}'      # VM1: "syncing" for a few s, then serving
```
- VM2 restart: VM1's Caddy serves WEB routes locally meanwhile; no rider impact.
- VM1 restart: the gateway drains (rides flushed, mirror told, sockets asked to reconnect, leases released) within
  20 s. `/api/health/live` turns 503, the NLB moves riders to VM2 (mirror keeps their rides), and back to VM1 once it
  is serving again (hand-back after `MIRROR_HANDBACK_DELAY_MS`). Prefer low-traffic hours for VM1.
- Both VMs must run the same version: compare `version` in `/api/health` of both before leaving.

## 8. Failure drills (run quarterly; expected results)

| # | Drill | Do | Expected |
|---|---|---|---|
| 1 | Gateway crash on VM1 | [VM1] `sudo systemctl kill -s KILL coroute-gateway` | systemd restarts it within 2 s; phones reconnect (a few 502s from Caddy meanwhile); rides intact (mirror copy on VM2 + DB). If the restart takes longer than ~10 s the NLB fails over to VM2 and back. Live-preferred job leases of the dead process expire after 60 s and are retaken by the new VM1 process; no job runs twice. |
| 2 | Reboot VM1 | [VM1] `sudo reboot` | NLB marks VM1 unhealthy in 10-15 s; all traffic (LIVE + WEB) to VM2; riders reconnect to VM2 with their rides, voice and SOS working. After boot: secrets fetched, gateway `syncing` -> `serving`, NLB back to VM1, riders handed back. `guardian-push`/`convoy-auto-end` run on VM2 meanwhile only if VM1 stays down > 3 min (60 s TTL + 120 s grace). |
| 3 | VM2 down | [VM2] `sudo systemctl stop coroute-gateway` (or stop the instance) | VM1's Caddy marks <vm2-private-ip> down within 10 s; WEB routes served by VM1 (in-flight requests retried locally for up to 5 s). Mirror link down; VM1 serves alone. Web-preferred jobs move to VM1 120 s after their leases end (at once released on a graceful stop, 60 s TTL otherwise). Start VM2: it takes its jobs back on request. |
| 4 | Cut the mirror link | [VM1] `sudo iptables -I INPUT -p tcp -s <vm2-private-ip> --dport 3101 -j DROP` and [VM2] same with `-s <vm1-private-ip>` | `/api/health/live` `mirror.connected:false` on both after ~3.5 s; rides continue on VM1; WEB unaffected (port 3000). Remove with `-D` instead of `-I`: link back in seconds, unacknowledged events resent, snapshots merged. |
| 5 | Database outage | [console] ADB ACL: remove both VM IPs (or stop the ADB) for 5 min | `/api/health` 503 `db: DOWN`; `/api/health/live` stays 200 (NLB does not fail over). Live rides, chat, positions, voice continue in memory; sign-in and payments fail with 5xx; signed-in riders stay signed in (account cache). Lease renewals fail: no job starts anywhere until the DB is back. Restore the ACL: writes resume, `/api/health` 200 within 30 s. |
| 6 | Backup restore into DB2 | see 9.3 | dry run lists every collection with counts equal to the manifest; the restore writes the same counts; a test login against a gateway pointed at DB2 (local `npm start` with ORACLE_SODA_URL of DB2) works. |
| 7 | Secrets unavailable | [VM2] `sudo systemctl stop coroute-secrets` | `/run/coroute/secrets.env` removed and the gateway stopped (Requires=). `sudo systemctl start coroute-gateway` fetches again. With Vault/policy broken, `journalctl -u coroute-secrets` names the secret that failed (never its value). |

## 9. Routine operations

### 9.1 Deploy
Section 7. Run `node deploy/gen_caddy_routes.js --check` whenever routes changed; if it lists an UNCLASSIFIED
route, add it to `deploy/route_split.md` (LIVE when it touches rooms, sockets, live links or the hub), run
`node deploy/gen_caddy_routes.js` (rewrites the VM1 matcher), deploy VM1's Caddyfile with `setup_node.sh` + reload.

### 9.2 Rotate
Section 6. Keep a log entry (date, secret, who) in `deploy/VM_OPERATIONS_LOG.md` (names only, never values).

### 9.3 Restore a backup (into a second database, never production first)
```bash
# [VM2] DB2 = a second Autonomous DB with the COROUTE schema (deploy/RUNBOOK.md section 2) and the VM IPs in its ACL
cd /opt/coroute/gateway
sudo -u coroute env $(sudo cat /etc/coroute/gateway.env /run/coroute/secrets.env | grep -E '^(BACKUP_PAR_URL|BACKUP_ENCRYPTION_KEY)=' | tr -d "'") \
  RESTORE_SODA_URL=<DB2 SODA URL> RESTORE_ORACLE_USER=COROUTE RESTORE_ORACLE_PASSWORD="$(read -rs -p 'DB2 password: ' P; echo "$P")" \
  BACKUP_PRODUCTION_HOSTS=<production ADB host> \
  node scripts/backup_restore.js --latest full --dry-run
# then the same command without --dry-run (add --wipe only for a non-empty DB2)
```
Restoring into production requires `--i-understand-this-overwrites-production`: stop both gateways first, restore,
start VM2, then VM1, and run section 5.

### 9.4 Scaling the live rider cap
`LIVE_RIDER_CAP` = riders with a live socket across both VMs before new riders get `503 SERVER_BUSY`
(riders already riding are never refused). Watch `liveRiders` and `eventLoopLagMs` in `/api/health/live` and
`MemoryCurrent` (`systemctl show coroute-gateway -p MemoryCurrent`) at peak. Raise in steps of 25 % while peak
`eventLoopLagMs` < 100 and memory < 550 MB; lower when either is exceeded. Change the value in
`/etc/coroute/gateway.env` on **both** VMs, restart VM2 then VM1. Load test before a big event:
`node scripts/load_convoy_ws.js` against a staging copy.

### 9.5 OS patching and reboots
Unattended upgrades install security updates without rebooting. When `/var/run/reboot-required` exists:
reboot VM2, wait for section 5 to pass, then reboot VM1 (drill 2 behaviour). Node.js and Caddy are held back
from unattended upgrades: upgrade them deliberately, VM2 first (`sudo apt-get install nodejs`; Caddy:
re-run `setup_node.sh` after removing `/usr/bin/caddy.custom`).

### 9.6 Logs and health
`journalctl -u coroute-gateway -f`, `journalctl -u caddy -f`, `journalctl -u coroute-secrets -b`.
Job leases: `curl -s localhost:3000/api/health | jq .leases` on each VM. Time sync matters for leases:
`chronyc tracking` (offset well below 1 s).

## 10. Rollback

- **Code**: [affected VM] `sudo rsync -a --delete --exclude data/ /opt/coroute/rollback/ /opt/coroute/gateway/ &&
  sudo systemctl restart coroute-gateway`, VM2 first. Caveats when rolling back to a build **before** this
  release: (a) accounts that signed in since were re-hashed to `scrypt$...` and cannot sign in on a bcrypt-only
  build (do not roll back past it; fix forward); (b) Razorpay secrets migrated to `v2:` read as "not set" on an
  older build (it falls back to the environment keys); (c) `JWT_SECRET_PREVIOUS` is ignored by older builds.
- **Caddy**: `sudo cp /etc/caddy/Caddyfile.orig /etc/caddy/Caddyfile && sudo systemctl reload caddy` restores the
  pre-setup file; or re-run `setup_node.sh` from the previous release's `deploy/`.
- **Back to one VM**: [console] NLB: set VM2 backend offline (or remove it); [VM1] set `GATEWAY_ROLE=all`,
  remove `MIRROR_*` from `gateway.env`, install `deploy/caddy/Caddyfile.vm2` as VM1's Caddyfile (everything
  local), restart gateway and reload Caddy. Jobs then all run on VM1 (role `all` takes every lease at once).
- **Secret rotation gone wrong**: put the previous value back as a new Vault secret version (`upd`) and restart
  both VMs; for JWT, swap `JWT_SECRET` and `JWT_SECRET_PREVIOUS` back (both stay accepted).
- **DNS**: point DuckDNS back to a VM's public IP (3.8 with that IP) only if the NLB itself is broken.

## 11. Environment keys added for the two-VM setup

Non-secret (gateway.env): `NODE_NAME`, `GATEWAY_ROLE`, `TRUST_PROXY`, `JOB_LEASE_TTL_MS`, `JOB_LEASE_HEARTBEAT_MS`,
`JOB_LEASE_GRACE_MS`, `PASSWORD_SCRYPT_N/R/P`, `PASSWORD_HASH_CONCURRENCY`, `PASSWORD_BCRYPT_WORKERS`,
`MIRROR_LISTEN_HOST`, `MIRROR_LISTEN_PORT`, `MIRROR_PEER_URL`, `MIRROR_ACK_TIMEOUT_MS`, `MIRROR_HANDBACK_DELAY_MS`,
`MIRROR_HANDBACK_PER_SEC`, `MIRROR_STARTUP_WAIT_MS`, `MIRROR_SYNC_TIMEOUT_MS`, `LIVE_RIDER_CAP`, `REVIEW_PHOTO_STORE`,
`BACKUP_CRITICAL_EVERY_MINUTES`, `BACKUP_FULL_HOUR_UTC`, `BACKUP_RETENTION_DAYS`, `TRACK_DETAIL_DAYS`.
Vault: `JWT_SECRET`, `JWT_SECRET_PREVIOUS`, `ORACLE_PASSWORD`, Razorpay and SMS keys, `MIRROR_KEY`,
`SETTINGS_ENCRYPTION_KEY`, `BACKUP_ENCRYPTION_KEY`, `REVIEW_PHOTO_PAR_URL`, `BACKUP_PAR_URL`, `DUCKDNS_TOKEN`.
Descriptions and defaults: `gateway/deploy/.env.example`.
