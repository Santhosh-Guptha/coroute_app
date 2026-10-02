# CoRoute Gateway — Deployment Runbook (OCI Always Free, ₹0/month)

Target: the existing Oracle Cloud VM (`152.67.181.198`, Ubuntu) + the Always Free
Autonomous Database. Everything below is one-time; afterwards the service
restarts itself, renews its own TLS certificate, rotates its own logs and prunes
its own data.

---

## 0. Prerequisites (10 min)

1. A hostname for the API. **Free option (used by default): DuckDNS.** Go to https://www.duckdns.org, sign in
   (GitHub/Google), create the subdomain **`coroute`** (→ `coroute.duckdns.org`) and set its IP to `152.67.181.198`.
   Copy your DuckDNS *token*; the installer can re-point the record for you (`DUCKDNS_TOKEN=…`).
   If `coroute` is taken, pick another name and build the app with `--dart-define=COROUTE_API=https://<name>.duckdns.org`.
   (Let's Encrypt needs a hostname; the OCI public IP is static, so the record never needs updating.)
2. OCI → Networking → the VM's subnet **Security List**: allow ingress TCP **80** and **443** from `0.0.0.0/0`.
   On the VM itself: `sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT && sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT && sudo netfilter-persistent save`
3. Google Cloud Console → the OAuth client used by the app (`87798956679-…apps.googleusercontent.com`) — keep its **Web client ID**; it goes into `GOOGLE_CLIENT_IDS`. (Google Sign-In in the app must request an ID token with that web client as `serverClientId`; see the Flutter section of PRODUCTION_PLAN.md.)

## 1. Database: dedicated low-privilege schema (5 min)

Database Actions → SQL (as ADMIN) → run `deploy/oracle_setup.sql` after replacing `<strong-password>`.
Then **rotate the ADMIN password** — the old APK shipped it — and disable REST on ADMIN as the script's footer shows.

Resulting SODA URL: `https://<adb-host>.adb.ap-hyderabad-1.oraclecloudapps.com/ords/coroute/soda/latest`

## 2. Install the gateway (10 min)

**Fast path — one command.** Copy the repo to the VM (`scp -r coroute_app ubuntu@152.67.181.198:~/` or `git clone`), then:
```bash
cd ~/coroute_app && sudo API_HOST=coroute.duckdns.org DUCKDNS_TOKEN=<your-token> bash gateway/deploy/install.sh
```
It installs Node 22 + Caddy, creates the service user, asks once for the Oracle schema URL/password, Google client ID(s)
and bootstrap admin e-mail, generates the JWT secret, creates the DB collections, enables TLS and opens the firewall.
Re-run the same command later to upgrade. The manual equivalent follows.

```bash
# on the VM
sudo apt-get update && sudo apt-get install -y curl git
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs

sudo useradd --system --home /opt/coroute --shell /usr/sbin/nologin coroute || true
sudo mkdir -p /opt/coroute /etc/coroute
sudo rsync -a --delete gateway/ /opt/coroute/gateway/      # copy this folder (scp/rsync/git)
cd /opt/coroute/gateway && sudo npm ci --omit=dev
sudo chown -R coroute:coroute /opt/coroute

sudo cp deploy/.env.example /etc/coroute/gateway.env
sudo nano /etc/coroute/gateway.env       # fill ORACLE_*, JWT_SECRET (openssl rand -base64 48), GOOGLE_CLIENT_IDS, BOOTSTRAP_ADMIN_EMAILS
sudo chmod 600 /etc/coroute/gateway.env && sudo chown root:coroute /etc/coroute/gateway.env

# create collections + indexes (idempotent; also runs at every boot)
sudo -u coroute env $(sudo cat /etc/coroute/gateway.env | xargs) node scripts/init_db.js

sudo cp deploy/coroute-gateway.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now coroute-gateway
sudo systemctl status coroute-gateway --no-pager
curl -s http://127.0.0.1:3000/api/health
```

## 3. TLS with Caddy (auto-renewing, 5 min)

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy
sudo systemctl disable --now nginx 2>/dev/null || true     # the old nginx on :80 must go
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile
sudo sed -i 's/api.coroute.example.com/coroute.duckdns.org/' /etc/caddy/Caddyfile   # your hostname
sudo systemctl reload caddy
curl -s https://coroute.duckdns.org/api/health
./deploy/smoke_test.sh https://coroute.duckdns.org
```

## 4. Build the app against it

```bash
flutter pub get
flutter build apk --release --dart-define=COROUTE_API=https://coroute.duckdns.org
```
(`COROUTE_API` defaults to `https://coroute.duckdns.org` in `lib/core/config/app_config.dart`, so the flag is optional unless you chose another hostname.)

## 5. First admin

Sign in (password or Google) with an address listed in `BOOTSTRAP_ADMIN_EMAILS` → that account is stored as `MASTER_ADMIN` in the database.
From then on, promote/demote from the **Users & roles** screen in the admin dashboard, or via the API:
```bash
curl -X PATCH https://coroute.duckdns.org/api/admin/users/usr_someone/role -H "Authorization: Bearer <admin JWT>" -H 'Content-Type: application/json' -d '{"role":"MASTER_ADMIN"}'
```
You can then remove `BOOTSTRAP_ADMIN_EMAILS` from the env file; roles live in the DB.

## 6. Operations (what "no maintenance" looks like)

| Concern | Handled by |
|---|---|
| Process crash / VM reboot | `systemd` `Restart=always`, `enable`d unit |
| TLS certificate expiry | Caddy renews automatically |
| Log growth | journald (size-capped, rotated) — `journalctl -u coroute-gateway -f` |
| Database growth | built-in retention: GPS traces stripped after 90 days, voice metadata after 7 days; accounts, convoy and trip records kept |
| Always-Free DB auto-pause (7 days idle) | built-in keep-alive ping every 12 h |
| Stale convoys (phone died, app uninstalled) | auto-ended after 36 h without activity |
| Node security updates | `sudo apt-get upgrade` whenever convenient; `unattended-upgrades` is on by default on Ubuntu |

Health: `GET /api/health` → `{"status":"HEALTHY","db":"UP",…}` (503 if the DB is unreachable). Point any free uptime monitor (e.g. UptimeRobot free tier) at it if you want a ping when it's down.

## 7. Upgrading the gateway

```bash
sudo rsync -a --delete --exclude node_modules gateway/ /opt/coroute/gateway/
cd /opt/coroute/gateway && sudo npm ci --omit=dev && sudo chown -R coroute:coroute /opt/coroute
sudo systemctl restart coroute-gateway
```
On `SIGTERM` the gateway flushes in-memory telemetry to Oracle before exiting; clients reconnect automatically and re-join their convoy.

## Free-tier capacity notes

* Voice is PCM16 @ 16 kHz: 32 KB/s per *active speaker*. A convoy of 10 where one person speaks = 32 KB/s in, 288 KB/s out — trivial for the VM; OCI Always Free includes 10 TB/month egress.
* The Always Free ADB allows 20 GB. A rider document is ~1 KB; a convoy's full GPS history is never stored (only the latest position per rider) and trip trails are trimmed by retention, so storage stays flat in the tens of MB.
* Always Free compute: either VM.Standard.E2.1.Micro (1 OCPU / 1 GB) or up to 4 OCPU / 24 GB of Ampere A1. The gateway is I/O-bound and comfortably serves hundreds of concurrent riders on the Micro shape; move to A1 for thousands.
