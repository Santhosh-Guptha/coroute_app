# CoRoute Gateway — Deployment Runbook (OCI Always Free, ₹0/month)

Target: the existing Oracle Cloud VM (`<vm-public-ip>`, Ubuntu) + the Always Free
Autonomous Database. Everything below is one-time; afterwards the service
restarts itself, renews its own TLS certificate, rotates its own logs and prunes
its own data.

---

## 0. Prerequisites (10 min)

1. A hostname for the API. **Free option (used by default): DuckDNS.** Go to https://www.duckdns.org, sign in
   (GitHub/Google), create the subdomain **`coroute`** (→ `coroute.duckdns.org`) and set its IP to `<vm-public-ip>`.
   Copy your DuckDNS *token*; the installer can re-point the record for you (`DUCKDNS_TOKEN=…`).
   If `coroute` is taken, pick another name and build the app with `--dart-define=COROUTE_API=https://<name>.duckdns.org`.
   (Let's Encrypt needs a hostname; the OCI public IP is static, so the record never needs updating.)
2. OCI → Networking → the VM's subnet **Security List**: allow ingress TCP **80** and **443** from `0.0.0.0/0`.
   On the VM itself: `sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT && sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT && sudo netfilter-persistent save`
3. Google Cloud Console → the OAuth client used by the app (`87798956679-…apps.googleusercontent.com`) — keep its **Web client ID**; it goes into `GOOGLE_CLIENT_IDS`. (Google Sign-In in the app must request an ID token with that web client as `serverClientId`; see the Flutter section of PRODUCTION_PLAN.md.)

## 0b. Custom domain (launch requirement)

**The two-VM cluster (NLB + `deploy/caddy/Caddyfile.vm1/.vm2`) follows `docs/DOMAIN_MIGRATION_devmonks.md`**: the
Caddyfiles already serve `coroute.devmonks.space` and `coroute.duckdns.org`, the gateway takes `PUBLIC_ORIGIN`,
`LEGACY_ORIGINS` and `REDIRECT_LEGACY_HOST`, and the app defaults to the new name with a fallback. The steps below
are for a single VM installed with `install.sh`.

The DuckDNS name is for testing. Before launch, point your own domain at the VM and let Caddy issue its certificate:

1. At your DNS provider (for devmonks.space, or whichever domain you choose) add **A record** `coroute` → `<vm-public-ip>` (giving `coroute.devmonks.space`).
2. On the VM, re-run the installer with both hostnames so existing test builds keep working while the new one takes over:
   `sudo API_HOST="coroute.devmonks.space, coroute.duckdns.org" bash gateway/deploy/install.sh`
   (Caddy accepts a comma-separated list of site addresses; certificates are issued for each.)
3. Set `PUBLIC_ORIGIN=https://coroute.devmonks.space` in `/etc/coroute/gateway.env` and restart the gateway. The app already defaults to `https://coroute.devmonks.space` (`AppConfig.defaultApiBaseUrl`, with the DuckDNS fallback); the website takes its origin from `PUBLIC_ORIGIN`.
4. Check `https://coroute.devmonks.space/`, `/privacy`, `/terms` and `/api/health`.

## 1. Database: dedicated low-privilege schema (5 min)

Database Actions → SQL (as ADMIN) → run `deploy/oracle_setup.sql` after replacing `<strong-password>`.
Then **rotate the ADMIN password** — the old APK shipped it — and disable REST on ADMIN as the script's footer shows.

Resulting SODA URL: `https://<adb-host>.adb.ap-hyderabad-1.oraclecloudapps.com/ords/coroute/soda/latest`

## 2. Install the gateway (10 min)

**Fast path — one command.** Copy the repo to the VM (`scp -r coroute_app ubuntu@<vm-public-ip>:~/` or `git clone`), then:
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

One APK per CPU type keeps the download small (most phones need only the 64-bit one), and
the Play Store gets an app bundle (Play splits it per phone by itself).

```bash
flutter pub get
# APKs for the website download (64-bit and 32-bit ARM phones)
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64 \
  --obfuscate --split-debug-info=build/symbols
# App bundle for the Play Store
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
```
(`COROUTE_API` defaults to `https://coroute.devmonks.space` in `lib/core/config/app_config.dart`, with an automatic
fallback to `https://coroute.duckdns.org` when the new name cannot be reached (`docs/DOMAIN_MIGRATION_devmonks.md`).
Pass `--dart-define=COROUTE_API=https://<host>` only for another gateway: an override has no fallback. Keep `build/symbols` for reading crash stack traces; it is not committed.)

Publish the APKs on the gateway (the website's Download button and `GET /download` serve them;
no other hosting is needed):

```bash
scp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   ubuntu@<vm-public-ip>:/tmp/coroute.apk
scp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk ubuntu@<vm-public-ip>:/tmp/coroute-32bit.apk
# on the VM
sudo install -o coroute -g coroute -m 644 /tmp/coroute.apk       /opt/coroute/gateway/public/coroute.apk
sudo install -o coroute -g coroute -m 644 /tmp/coroute-32bit.apk /opt/coroute/gateway/public/coroute-32bit.apk
```
`/download` sends people to `PLAY_STORE_URL` when it is set, otherwise to `APK_URL` (default: `<origin>/coroute.apk`).
`/download/32bit` sends them to `APK_ARM32_URL` (default: `<origin>/coroute-32bit.apk`) for older 32-bit phones.
If `/etc/coroute/gateway.env` still has an old `APK_URL=` line (for example a GitHub releases page), remove it so the
default above is used. The `rsync --delete` in section 7 would remove the APKs: run it with
`--exclude 'coroute*.apk'`, or copy the APKs again after upgrading.

After the first release with R8 enabled, smoke-test on a real phone: Google sign-in, start a ride, the lock-screen
notification with its SOS and Leave buttons, one local alert notification, and push-to-talk. If one of them fails,
set `isMinifyEnabled` and `isShrinkResources` back to `false` in `android/app/build.gradle.kts` (split APKs and
compressed native libraries keep most of the size saving).

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

## 6b. Payments data: backup & restore

Everything money-related lives in two SODA collections:

| Collection | What | Keyed by |
|---|---|---|
| `subscription_config` | order ledger (`k='rzp_order'`), refunds and webhook ids on each order, pricing (`k='pricing'`), offers (`k='offer'`), admin audit trail (`k='audit'`), encrypted Razorpay settings (`k='razorpay'`), sweeper status (`k='sweep'`) | `k` + `orderId` / `id` |
| `users` | each rider's `subscriptionTier`, `subscriptionValidUntil`, `pendingTier`, `paymentHistory`, `subscriptionHistory` | `userId` |

Razorpay also keeps every order, payment and refund (Dashboard → Transactions), so the ledger can always be
re-checked against it. The Razorpay settings document holds secrets encrypted with `JWT_SECRET`: a restore onto
a gateway with a different `JWT_SECRET` keeps the key ids but the secrets must be re-entered in the admin console.

**Nightly export (on the VM, as root).** Pages through the SODA REST API with the schema user from
`/etc/coroute/gateway.env` and keeps 30 days of gzipped JSON in `/var/backups/coroute`:

```bash
sudo tee /usr/local/bin/coroute-backup >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/coroute/gateway.env; set +a
out=/var/backups/coroute/$(date -u +%F); mkdir -p "$out"; chmod 700 /var/backups/coroute
for coll in subscription_config users; do
  offset=0; : > "$out/$coll.jsonl"
  while :; do
    page=$(curl -fsS -u "$ORACLE_USER:$ORACLE_PASSWORD" "$ORACLE_SODA_URL/$coll?fields=value&limit=500&offset=$offset")
    echo "$page" | jq -c '.items[].value' >> "$out/$coll.jsonl"
    [ "$(echo "$page" | jq -r '.hasMore')" = "true" ] || break
    offset=$((offset + 500))
  done
  gzip -f "$out/$coll.jsonl"
done
find /var/backups/coroute -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
EOF
sudo chmod 700 /usr/local/bin/coroute-backup && sudo apt-get install -y jq
echo '17 2 * * * root /usr/local/bin/coroute-backup >> /var/log/coroute-backup.log 2>&1' | sudo tee /etc/cron.d/coroute-backup
sudo /usr/local/bin/coroute-backup && ls -l /var/backups/coroute/$(date -u +%F)
```

Copy the folder off the VM now and then (`scp -r ubuntu@<vm>:/var/backups/coroute ./`). For a spreadsheet copy of
the ledger, an admin can download `GET /api/admin/payments/export.csv?from=&to=` from the admin console.

**Restore** (only into an empty or damaged collection; the gateway upserts by `orderId` / `userId`, so never
import twice into a live one):

1. `sudo systemctl stop coroute-gateway` so the sweeper and webhooks do not write in between.
2. In Database Actions → SODA (or `soda drop`/`soda create`), empty the damaged collection.
3. Import, 500 documents per request:
   ```bash
   set -a; . /etc/coroute/gateway.env; set +a
   d=/var/backups/coroute/2026-10-27   # the day to restore
   for coll in subscription_config users; do
     zcat "$d/$coll.jsonl.gz" | split -l 500 - /tmp/restore_${coll}_
     for f in /tmp/restore_${coll}_*; do
       jq -s '.' "$f" | curl -fsS -u "$ORACLE_USER:$ORACLE_PASSWORD" -H 'Content-Type: application/json' \
         -X POST --data-binary @- "$ORACLE_SODA_URL/$coll?action=insert" >/dev/null
     done
     rm -f /tmp/restore_${coll}_*
   done
   ```
4. `sudo systemctl start coroute-gateway` (collections and indexes are checked at boot), then compare
   `GET /api/admin/subscription/overview` and the CSV export with Razorpay Dashboard → Transactions for the days
   since the backup. A payment Razorpay captured after the backup is re-applied when its webhook is re-sent
   (Dashboard → Webhooks → the event → Resend), because orders are activated once per `orderId`.

## 6c. Going live with Razorpay

1. **KYC.** Razorpay Dashboard → Account & Settings → complete business KYC (PAN, bank account, website
   `https://coroute.duckdns.org` with the privacy, terms and contact pages). Live keys appear only after activation.
2. **Live keys.** Dashboard (Live mode) → Account & Settings → API Keys → generate. In the CoRoute app open the
   admin console → Payment gateway, paste the live key id (`rzp_live_…`) and secret, press **Test** (checks them
   against Razorpay), then switch the mode to **live**. No redeploy; the secret is stored encrypted and never shown
   again. Test-mode orders already in the ledger keep their test keys for verification and refunds.
3. **Webhook.** Dashboard (Live mode) → Account & Settings → Webhooks → Add:
   * URL: `https://coroute.duckdns.org/api/subscription/webhook`
   * Events: `payment.captured`, `order.paid`, `payment.failed`, `refund.processed`
   * Secret: a new random value (`openssl rand -hex 24`); paste the same value as the live webhook secret in the
     admin console. Unsigned or wrongly signed calls are refused (400); bodies over 1 MB are refused (413);
     repeated deliveries are recognised by `x-razorpay-event-id`.
   Do the same in Test mode with the test webhook secret so test payments are confirmed too.
4. **Smoke test** with a real ₹1 offer or the cheapest plan: pay in the app, check the plan activates, then refund it
   from the admin console (Payments → Refund) and confirm `refund.processed` arrives (the refund shows PROCESSED).
5. Everything an admin changes (prices, offers, coupons, keys, grants, revokes, refunds) is listed in the admin
   console's audit trail (`GET /api/admin/audit`).

## 7. Upgrading the gateway

```bash
sudo rsync -a --delete --exclude node_modules --exclude 'coroute*.apk' gateway/ /opt/coroute/gateway/
cd /opt/coroute/gateway && sudo npm ci --omit=dev && sudo chown -R coroute:coroute /opt/coroute
sudo systemctl restart coroute-gateway
```
On `SIGTERM` the gateway flushes in-memory telemetry to Oracle before exiting; clients reconnect automatically and re-join their convoy.

## Release order for 3.14 (rider safety): gateway first, then the app

The 3.14 app (build 74) uses new socket messages (ACK, SOS_RESPOND, CHECK_IN, BYE, PRESENCE) and the
`GET /api/convoys/:groupId/emergency-roster` endpoint. It only turns them on when the gateway's HELLO lists
them (`protocol: 2`, `features: [...]`), so a 3.14 app on an older gateway keeps working as 3.13, but none of
the new safety features work until the gateway is upgraded. Older apps (3.11 to 3.13) keep working on the new
gateway unchanged.

1. Upgrade the gateway (section 7). Check: `curl -s https://coroute.duckdns.org/api/health` shows `"version":"3.14.0"`,
   and `./deploy/smoke_test.sh https://coroute.duckdns.org` passes.
2. In `/etc/coroute/gateway.env` set `LATEST_APP_BUILD=74` (the default is already 74) and restart.
3. Only then publish the app: the APKs on the gateway (section 4) and the Play release. The Play release also needs the
   SMS permission declaration approved first (see `PLAY_STORE_CHECKLIST.md`, "Permissions declarations").
4. Do not raise `MIN_APP_BUILD` for this release: riders on 3.11 to 3.13 still get the server safety net
   (possible incident, no-signal escalation) and still receive emergency texts from 3.14 riders.

New settings (all optional, defaults shown in `deploy/.env.example`): `INCIDENT_*`, `NO_SIGNAL_ESCALATE_MIN`,
`NO_SIGNAL_MIN_KMH`, `ROSTER_PER_MIN`, `ROSTER_VALID_H`, `SMS_MAX_RECIPIENTS`, `CLIENT_ID_CACHE`, `CLIENT_ID_TTL_H`,
`SOS_RESPONDERS_MAX`, `MEDICAL_ALLERGIES_MAX`, `MEDICAL_NOTES_MAX`. Nothing needs to be set for a normal install.

Privacy notes for operators: phone numbers in the emergency roster and medical info are never written to the logs.
Medical info is removed from an SOS alert when it is resolved and when the trip ends (retention also removes any
left over on resolved alerts). Admin screens never show it.

## Release order for 3.15 (rider safety network, discovery): gateway first, then the app

The 3.15 app (build 75) sends new socket messages (`REPORT_DOWN`, `ASSIST_ANSWER`, `NET_REPORT_FALSE`, `WAVE`, and
`caps: ["net1"]` with every JOIN) only when the gateway's HELLO lists `net1` / `discovery1`. A 3.14 gateway answers
those messages with `ERROR 400`, so the app must not be released before the gateway. Everything new the gateway sends
(`EMERGENCY_UPDATE`, `ASSIST_*`, `HAZARD*`, `DISCOVERY`, `WAVED`) goes only to sockets that announced `net1`, so 3.11
to 3.14 apps are unaffected; they only see extra fields on `ALERT`, `ALERT_RESOLVED`, `CONFIG` and the snapshot, which
they ignore. Their SOS alerts are still searched for by the network (server side), they are never asked to help.

1. Upgrade the gateway (section 7). Check: `curl -s https://coroute.duckdns.org/api/health` shows `"version":"3.15.0"`,
   `./deploy/smoke_test.sh https://coroute.duckdns.org` passes, and the log shows no `[net]` or `[discovery]` warnings.
2. In `/etc/coroute/gateway.env` set `LATEST_APP_BUILD=75` (the default was 75 in 3.15; 76 since 3.16) and restart.
3. Only then publish the app (APKs on the gateway, section 4, and the Play release; see `PLAY_STORE_CHECKLIST.md` for
   the Data safety and listing changes).
4. Do not raise `MIN_APP_BUILD` for this release.
5. A new collection `safety_audit` is created at boot (`migrate()`, idempotent). Nothing to run by hand.

Switches: `SAFETY_NET_ENABLED=0` stops requests to other groups and accident warnings (own-group SOS, statuses and
expiry keep working); `DISCOVERY_ENABLED=0` turns off "groups nearby". Both remove their HELLO feature, so 3.15 apps hide
the related controls. All other settings are optional (`deploy/.env.example`, section "3.15").

Load and the free OSRM server: matching uses only memory (live convoys, route geometry already stored with each convoy);
one timer every 15 s for the network and one every 60 s for discovery, both idle when nothing is open. The OSRM table
service is used only for riders without a planned route, at most 2 calls per emergency and 6 per minute for the whole
gateway, through the same polite queue as routes, with a 3 s timeout; a request to a rider on a planned route is never
held up by it. A test with 200 live convoys, 2000 riders and 50 open emergencies on dense 3000-point routes took about
25 ms per network tick (350 ms once for building the route indexes).

Operations:
* Admin view: `GET /api/admin/safety` (open incidents, riders with false alarms in the last 30 days, the latest 100
  audit rows). Reset a rider's false alarm count with `POST /api/admin/users/<userId>/false-alarms/reset`.
* A rider with 3 false alarms (that riders of other groups were asked to help with) in 30 days is "throttled": their own
  group is alerted as always, other groups get at most one request, 60 s later, and no accident warning unless it was an
  automatic crash alert.
* After a restart, open emergencies get their network search back when their convoy is loaded again (a candidate may be
  asked once more; harmless).
* Privacy notes: the safety log holds ids and short codes only (no positions, names or text) and is purged after
  `AUDIT_RETENTION_DAYS` (180) and on account deletion. The network summary (responders, ETAs) lives in memory only;
  an alert stores just the responders' first names, statuses and times (`netResponders`).

## Release order for 3.16 (safety round): gateway first, then the app

The 3.16 app (build 76) sends `ROLE_SET` (sweeper), `CHECK_IN` with `context: FOLLOW_UP`, `CONFIG.townLimitKmh` and
calls the new REST endpoints (`/api/geo/weather`, `/api/convoys/:id/alerts/:id/live-link`) only when the gateway's HELLO
lists `ride316`. Everything new the gateway sends is either a new timeline type (`STALE_UPDATE`, `LOW_BATTERY`,
`BEHIND_SWEEPER`, `ROLE_CHANGED`, `FOLLOW_UP`), which 3.14 and 3.15 apps print as a generic line, or an extra field on an
existing message (`nearestHospital`, `liveLink`, `townLimitKmh`, `farByRoad`, `OVERSPEED.data.context`), which they ignore.

1. Upgrade the gateway (section 7). Check: `curl -s https://coroute.duckdns.org/api/health` shows `"version":"3.16.0"`
   and `./deploy/smoke_test.sh https://coroute.duckdns.org` passes.
2. Outbound allow-list / firewall: 3.16 adds ONE new outbound host, `api.open-meteo.com` (HTTPS, weather on the
   route, no key). Everything else still goes to the OSM hosts of section "Free OpenStreetMap services". If the host
   cannot be allowed, set `WEATHER_URL=` (empty): the app then shows no weather line (503 `WEATHER_OFF`).
3. In `/etc/coroute/gateway.env` set `LATEST_APP_BUILD=76` (the default is already 76) and restart.
4. Only then publish the app (APKs on the gateway, section 4, and the Play release; `PLAY_STORE_CHECKLIST.md`).
5. Do not raise `MIN_APP_BUILD` for this release. No new collections, no manual steps: new alert fields (`liveLink`
   hash and times, `nearestHospital`) live on the existing alert documents; weather and hospital answers in `geo_cache`.

Budgets (all in `deploy/.env.example`, section "3.16"):
* Weather: one Open-Meteo call per review and per ride start with up to 5 route points, rounded to a 0.1 degree grid and
  cached 30 minutes for everyone (memory, then `geo_cache`). Global `WEATHER_PER_MIN=20` upstream calls a minute (over
  budget: cached cells are answered, the rest are null), `WEATHER_USER_PER_MIN=6` per rider. Attribution "Weather data by
  Open-Meteo.com" is shown in the app and on the privacy page.
* Nearest hospital: one Nominatim search per HIGH or CRITICAL alert (never for LOW), after the ALERT went out and never
  awaited by it, skipped when the polite OSM queue would wait more than `HOSPITAL_MAX_WAIT_MS`; answers cached 30 days per
  1 km cell, "nothing found" 6 hours.
* Live emergency links (`/e/<token>`): the token (24 random bytes, base64url, 32 chars) is returned once to the rider or
  lead and only its sha256 is stored with the alert; 30 minutes, revocable, revoked automatically when the alert closes,
  at most 3 per alert. The public JSON view and page are limited to 60 requests a minute per IP, sent with `no-store`,
  `X-Robots-Tag: noindex` and `Referrer-Policy: no-referrer`, and show the first name, last position and time only.
  Audit rows `LIVE_LINK` (CREATE / REVOKE / EXPIRE / VIEW) carry ids, never the token.
* Admin "call the emergency contact" (`POST /api/admin/emergencies/:groupId/:alertId/contact`, 10 a minute per admin)
  answers the contact once for the call; the audit row `ADMIN_CONTACT CALL` holds the admin, rider, alert and time,
  never the number. Both audit kinds appear in `GET /api/admin/safety`.

Server-side rules (no new timers; they ride on the telemetry path and the existing 30 s timeline tick): stale rider
(`STALE_UPDATE`, thresholds from the group's own update rhythm, parked phones excluded, closed by the next fix or
replaced by OFFLINE), low battery (`LOW_BATTERY` at 15%, closed at 25% or when charging), sweeper (`ROLE_SET` by the
lead only, one per room; `BEHIND_SWEEPER` after 60 s more than 300 m behind on the route), town speed limit
(`OVERSPEED.data.context = TOWN` within 1 km of the start, planned stops and the destination). All are plain timeline
entries with a `notify` list (lead and sweeper); the apps turn them into alerts.

## Free-tier capacity notes

* Voice is PCM16 @ 16 kHz: 32 KB/s per *active speaker* (16 KB/s from a phone in data saver mode, 8 kHz). A convoy of 10 where one person speaks = 32 KB/s in, 288 KB/s out — trivial for the VM; OCI Always Free includes 10 TB/month egress.
* The Always Free ADB allows 20 GB. A rider document is ~1 KB; a convoy's full GPS history is never stored (only the latest position per rider) and trip trails are trimmed by retention, so storage stays flat in the tens of MB.
* Always Free compute: either VM.Standard.E2.1.Micro (1 OCPU / 1 GB) or up to 2 OCPU / 12 GB of Ampere A1 per account (Always Free; corrected 13 Nov 2026, not 4 / 24). The gateway is I/O-bound and comfortably serves hundreds of concurrent riders on the Micro shape; move to A1 for thousands.

## Retiring old app builds (MIN_APP_BUILD)
1. In the app, as admin: Feedback & analytics, App versions. It lists the builds riders used in the last 30 days and, for each build, how many riders would be locked out if it became the minimum.
2. Builds before 65 do not report their number; they show as "Older than build 65".
3. When a build shows "Safe to make this the minimum", set it on the server and restart:
   ```
   sudo sed -i "s/^MIN_APP_BUILD=.*/MIN_APP_BUILD=66/" /etc/coroute/gateway.env   # add the line if it is missing
   sudo systemctl restart coroute-gateway
   ```
   Riders below the minimum see "Update required" with a download button.
4. Keep `LATEST_APP_BUILD` equal to the build of the APK (or Play release) you published.

## After the Play Store listing is live
Add `PLAY_STORE_URL=https://play.google.com/store/apps/details?id=space.devmonks.coroute_app` to `/etc/coroute/gateway.env` and restart the gateway. `/download` (used by the website buttons and the app's update screen) then opens the Play Store instead of the APK.

---

## 8. Zero-Downtime VM Migration & Automatic Cutover

When replacing or upgrading your Oracle Cloud VM (e.g. migrating from `VM.Standard.E2.1.Micro` to `VM.Standard.A1.Flex` Ampere ARM64), the entire setup and DNS cutover can be executed with **a single command on the new VM**:

```bash
curl -fsSL https://raw.githubusercontent.com/Santhosh-Guptha/coroute_app/main/gateway/deploy/setup_new_vm.sh | sudo bash
```

### Why Existing Users Are Not Disturbed:
1. **Decoupled Database**: All accounts, convoys, emergency profiles, and telemetry live in Oracle Cloud Autonomous Database (`ATP 26ai` SODA in Hyderabad). No database data lives on the VM.
2. **Session Continuity**: The setup script automatically configures the exact same `JWT_SECRET` in `/etc/coroute/gateway.env`. Existing users on Google Play Store will **not** be logged out.
3. **Domain Indirection**: Mobile apps connect to `coroute.duckdns.org`, not an IP address. The script automatically updates DuckDNS to point to the new VM IP upon setup completion.
4. **Resilient Sockets**: The mobile app's WebSocket engine automatically detects connection drops and reconnects within 1–3 seconds, re-joining active rides without rider action.
5. **Pre-Fetched APKs**: Before switching DNS, the script automatically downloads the release APK binaries from the active server into `/opt/coroute/gateway/public/`.

### Administrative accounts (redacted in v3.56)
An earlier version of this section listed two administrator user names with their passwords in plain text and turned
on SSH password login. **Those passwords are compromised (they are in git history): lock or rotate both accounts**
(`sudo passwd -l <user>` after confirming key login) and use SSH keys only. `deploy/host/apply.sh` disables SSH
password login (section "v3.56 host tuning"). Never write a password, token or key into this repository.

## Sessions & security (3.57)

Docs: `docs/features_355/sessions_and_security.md`, findings `docs/security/SECURITY_AUDIT_v3.55.md`.

### New secrets (OCI Vault -> /run/coroute/secrets.env, identical on VM1 and VM2)

| Secret | Create with | Notes |
|---|---|---|
| `DATA_ENC_KEY` | `openssl rand -base64 32` | AES-256-GCM field encryption. Set `DATA_ENC_KEY_ID=k1` (non-secret, gateway.env). |
| `BLIND_INDEX_KEY` | `openssl rand -base64 32` | keyed hashes (session IP hash, device fingerprints). |
| `DATA_ENC_KEYS_PREVIOUS` | only during a rotation | `k1:<old base64>`; keep it until `node scripts/encrypt_fields.js` (dry run) shows 0 to encrypt. |

Never print them, never put them in git or in `gateway.env`. Losing `DATA_ENC_KEY` loses the encrypted phone numbers,
emergency contacts and Medical ID fields: keep a Vault backup of the secret version. `GET /api/health` reports
`dataEncryption: ON | OFF | KEY_MISSING` (KEY_MISSING = this node meets values written with a key it lacks: fix the
env on that node before anything else; SOS texts would have no contact numbers).

### Key rotation

1. New key in Vault; set `DATA_ENC_KEYS_PREVIOUS=k1:<old>`, `DATA_ENC_KEY=<new>`, `DATA_ENC_KEY_ID=k2` on BOTH nodes.
2. Restart VM2, then VM1. Reads re-encrypt lazily; `node scripts/encrypt_fields.js --write` finishes the rest.
3. When the dry run shows 0, remove `DATA_ENC_KEYS_PREVIOUS` (both nodes).

### Admin 2-step break-glass

An administrator who lost the authenticator phone AND the recovery codes:

1. Two people present (four-eyes). Verify the admin's identity out of band (call back on the known number).
2. On a gateway VM, as the service user, with the production env loaded:
   `node scripts/admin_mfa_reset.js <admin e-mail> "<ticket id and reason>"`
3. It turns 2-step off for that account, ends every session of the account and writes an `AUTH / MFA_BREAK_GLASS`
   audit row. The admin enrols again at the next web admin sign-in (scan the new QR, store the new recovery codes).
4. Note the ticket in `VM_OPERATIONS_LOG.md`. If no admin can sign in at all, `ADMIN_MFA_ENFORCE=off` on VM2 for
   the minutes needed (restart), enrol, then set it back to `all` and restart.

### Incident: a token or session may be stolen

* One rider: Admin console (or the rider at /account) "Sign out of all devices"; or `POST /api/auth/logout-all` with
  the rider's token. Sockets close at once on both nodes.
* Everyone: rotate `JWT_SECRET` (with `JWT_SECRET_PREVIOUS` only if you need a grace period; without it every
  session ends and riders sign in again; rides keep their safety features locally).


## Round 4 security (ride lock, sign-up verification, 2-step, pins, HSTS)

Docs: `docs/features_355/sessions_and_security.md` §9-§12. New settings (all optional, defaults shown) are listed in
`deploy/.env.example` under "round 4". SMTP must work: verification links, ride sign-in codes, 2-step e-mail codes and
deletion links all go by e-mail (`SMTP_HOST` / `MAIL_FROM`). Check after deploy: create an account on `/signin` with a
real address and confirm the link arrives (Gmail and Outlook, inbox not spam).

### Release order

Both gateway nodes first (VM2 then VM1), then the app. Old app builds keep working: the ride lock answers them with a
readable `error`, sign-up gives them a readable message (`REGISTER_VERIFY_LEGACY=verify`), account deletion e-mails a
link, their admin screens keep `web` 2-step rules, and their sockets keep `?token=`.

### Ride lock support cases

* "My phone died / was stolen during a ride and I cannot sign in": the sign-in screen offers **Send code to my e-mail**.
* No access to the e-mail: web admin › Riders › the rider › More › **End ride lock…** (MASTER_ADMIN, reason required,
  audited). It does not end the ride or any SOS.
* Emergency switch: `RIDE_LOCK=off` on both nodes, restart (blocks stop at once; nothing else changes).

### WebSocket tokens and access logs

Apps from 10025 send the token as the first socket message, never in the URL. Builds before 10025 still use
`/ws?token=…`. The gateway logger redacts `token=` values. Caddy writes no access log in our Caddyfiles; if you ever add
one, strip the query token and the auth headers:

```
log {
	output file /var/log/caddy/access.log
	format filter {
		wrap json
		fields {
			request>uri query {
				replace token REDACTED
			}
			request>headers>Authorization replace REDACTED
			request>headers>Sec-Websocket-Protocol replace REDACTED
			request>headers>Cookie replace REDACTED
		}
	}
}
```

(`Sec-WebSocket-Protocol` can carry `coroute.bearer.<token>` from other clients.) Never log request bodies.

### HSTS ramp-up

The gateway sends `Strict-Transport-Security: max-age=$HSTS_MAX_AGE; includeSubDomains[; preload]`; Caddy also sets
it per host (`deploy/caddy/Caddyfile.vm*`). `coroute.duckdns.org` already has one year. For `coroute.devmonks.space`:

1. Now: Caddy `max-age=300` (5 min). Check every page, `/api`, `/ws` and the app on that host for a week.
2. Week 2: `max-age=86400` (1 day) in Caddy, `HSTS_MAX_AGE=86400` on both nodes.
3. Week 3: `max-age=604800` (7 days).
4. Week 5: `max-age=31536000` (1 year). Keep `includeSubDomains` on the `coroute.` host only (other sites live on
   `devmonks.space`).
5. Preload (`HSTS_PRELOAD=true`) only if the owner wants it AND the apex `devmonks.space` and every subdomain are HTTPS
   forever: a subdomain cannot be preloaded alone, and removal from the preload list takes months. Not recommended now.

Going back: lower max-age first and wait out the old one; browsers keep the last value until it expires.

### Certificate pins (Android release builds)

`android/app/src/main/res/xml/network_security_config.xml` pins the two gateway hosts to CA ROOT keys (SPKI SHA-256):
ISRG Root X1 and X2 (Let's Encrypt, Caddy's first issuer), USERTrust RSA and ECC (ZeroSSL, Caddy's automatic fallback
when Let's Encrypt fails) and, as backups, Sectigo Public Server Authentication Root R46 and E46. The pin-set has
`expiration="2027-11-01"`: after that date Android ignores the pins (fails open) and checks normal system trust.

Rotation checklist (every release, and at least every 6 months):

1. Is the expiration more than 6 months away? If not, move it to about 12 months after the release date.
2. Has Let's Encrypt or ZeroSSL/Sectigo announced a new root (for example a new ISRG root generation)? If yes, add
   its pin in an app release at least 2 months before they start issuing from it. Compute a pin from the root
   certificate, never copy it from a web page:
   `openssl x509 -in Root.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`
3. Changing CA (for example to Google Trust Services): add the new CA's roots in an app release first, wait until
   most riders updated, only then switch Caddy.
4. If a wrong pin ever ships: riders on that build cannot reach the gateway (SOS texts and the lock-screen Medical ID
   still work, they do not use the gateway). Fix: ship an app update; as a server-side bridge, make Caddy serve a
   chain from a pinned CA (`issuer acme` with the Let's Encrypt directory, `preferred_chains { root_common_name "ISRG Root X1" }`).
5. Debug builds accept user-installed CAs and skip the pins (`debug-overrides`); release builds never do.

Optional (not applied: needs `caddy validate` on the VM first, and newer Caddy versions need a ZeroSSL API key for `issuer zerossl`): make the issuer explicit so the chain is predictable:

```
tls {
	issuer acme {
		dir https://acme-v02.api.letsencrypt.org/directory
		dns duckdns {env.DUCKDNS_TOKEN}
		dns_challenge_override_domain _acme-challenge.coroute.duckdns.org
		resolvers 1.1.1.1 8.8.8.8
	}
	issuer zerossl {
		dns duckdns {env.DUCKDNS_TOKEN}
	}
	protocols tls1.2 tls1.3
}
```

---

## v3.56 infrastructure (roles, tuning, DR, watchdog, backups, releases, load tests, scaling)

Plan and numbers: `docs/infra/INFRASTRUCTURE_PLAN_v3.56.md`. Step-by-step execution prompt for the release agent:
`docs/NEXT_AGENT_PROMPT_v3.55_round5_infra.md`. Hosts are SSH aliases `vm1`..`vm5`; real addresses only in the
untracked `deploy/inventory.local.env` (template `inventory.example.env`).

### Roles

| VM | Role | `GATEWAY_ROLE` | Caddyfile | `host/apply.sh --role` |
|---|---|---|---|---|
| vm1 | realtime primary (WS, convoys, SOS), NLB primary | `live` | `caddy/Caddyfile.vm1` | `realtime` |
| vm2 | web / admin / webhooks + hot mirror, NLB backup | `web` | `caddy/Caddyfile.vm2` | `web` |
| vm3 | DR warm standby + watchdog + offsite backups + restore drill (tenancy 2) | `standby` | `caddy/Caddyfile.vm3-dr` | `dr` |
| vm4 | staging / canary + load-test runner + watchdog of vm3 (tenancy 2) | (own) | `caddy/Caddyfile.vm4-staging` | `staging` |
| vm5 | A1 worker: Valhalla, tiles, Umami, batch (tenancy 2, pending) | — | `caddy/Caddyfile.vm5-worker` | `worker` |

`GATEWAY_ROLE=standby`: the gateway boots and answers `/api/health` (so the watchdog proves it can reach the
database), never takes a job lease, and `/api/health/live` answers 503 `standby`.

### Host tuning (`deploy/host/apply.sh`)

```bash
sudo ./deploy/host/apply.sh --role realtime --peer-ip <vm2 private ip> --dry-run   # read the diff first
sudo ./deploy/host/apply.sh --role realtime --peer-ip <vm2 private ip>
```
Idempotent. sysctl (`/etc/sysctl.d/90-coroute.conf`: somaxconn 4096, tw_reuse, file-max, swappiness 10,
vfs_cache_pressure 50, keepalives, small socket buffer minimums, fq/bbr), nofile 65535, journald 200 MB / 14 days,
logrotate for Caddy, unattended security upgrades (no reboot, never nodejs/caddy), fail2ban (sshd), SSH keys-only /
no root / no passwords (refuses if the sudo user has no `authorized_keys`), firewall (iptables on vm1/vm2 because of
the OCI image rules, ufw on vm3-vm5), systemd drop-ins (`Restart=always`, `TimeoutStopSec=45`, `MemoryMax`, heap),
safe `gateway.env` keys when absent (`NODE_COMPRESSION=off`, `HTTP_KEEPALIVE_MS=75000`, `ORACLE_MAX_INFLIGHT=10`,
`WS_DEFLATE=off`, `SHUTDOWN_DRAIN_MS=15000` on vm1/vm2). It never restarts the gateway, never deletes firewall rules,
and does not enable zram (the micros have swap files; zram costs CPU the 1/8 OCPU lacks). After apply:
`systemctl restart coroute-gateway` on vm2, check health, then vm1 (or let the next release restart them).

NLB: set the backend set health check to HTTPS `/api/health/live`, interval 5 s, timeout 3 s, 2 retries, so
`SHUTDOWN_DRAIN_MS=15000` moves new connections to vm2 before vm1 tells its sockets to reconnect.

### Releases (`deploy/release.sh`)

From the owner's machine (Linux, macOS, WSL or Windows Git Bash; needs bash, tar, gzip, ssh, scp, node):
```bash
cp gateway/deploy/inventory.example.env gateway/deploy/inventory.local.env   # once, fill in
gateway/deploy/release.sh                    # vm4 -> smoke + quick load -> (confirm) vm2 -> (confirm) vm1
gateway/deploy/release.sh --with-dr          # ... and vm3 standby
gateway/deploy/release.sh --only vm4         # staging only
gateway/deploy/release.sh --rollback vm1     # previous release on vm1
```
Each VM gets `/opt/coroute/releases/<version-time-git>/` (npm ci on the VM), the `/opt/coroute/gateway` symlink
switches atomically, the gateway restarts, and the health gate (HEALTHY, expected version, `/api/health/live` 200 on
vm1/vm2) must pass within `HEALTH_TIMEOUT_S` or the VM switches back by itself and the release stops. Data and APKs
live in `/opt/coroute/shared/` (first run migrates the old directory to `releases/legacy-<time>`). Static assets are
precompressed in the bundle (`.gz`, `.zst` when zstd exists) for Caddy's `file_server`.

Caddy (v3.56 Caddyfiles) is installed separately, one VM at a time, vm2 first:
```bash
sudo cp /opt/coroute/gateway/deploy/caddy/Caddyfile.vm2 /etc/caddy/Caddyfile        # vm1: Caddyfile.vm1, then
# vm1 only: put vm2's private IP into the WEB reverse_proxy line, exactly as setup_node.sh does with PEER_IP
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy
gateway/deploy/staging/smoke.sh https://coroute.devmonks.space                        # read-only smoke test
```

### DR: vm3 warm standby and failover

Install: `sudo SECRETS_MODE=vault|file DR_TLS=dns bash deploy/dr/install_standby.sh`, then `release.sh --only vm3`.
* **Secrets.** Preferred: copies of the production secrets in the **tenancy-2 Vault**, read with vm3's instance
  principal (`/etc/coroute/secret_ids.env` with tenancy-2 OCIDs; dynamic group + policy in tenancy 2). Works when
  tenancy 1 is suspended, which a cross-tenancy read of the tenancy-1 Vault would not. Stopgap (`SECRETS_MODE=file`):
  ```bash
  # from the owner's machine; the values are never printed
  ssh vm2 'sudo cat /run/coroute/secrets.env /run/coroute/caddy.env' | ssh vm3 'sudo install -m 600 /dev/stdin /etc/coroute/dr-secrets.env'
  ```
* **Certificates** are obtained on vm3 by DNS-01 (DuckDNS) while it is a standby, so a promotion only switches DNS.
* **Database.** The standby reaches the production ADB over its public endpoint (vm3's IP on the ADB ACL). For a
  tenancy-1 suspension the DR ADB in tenancy 2 (owner decision) must hold last night's restore:
  `RESTORE_SODA_URL=... node scripts/backup_restore.js --file <newest> --wipe` (never production: the script refuses
  the backup's source host).

**Promote (manual by default):** only when vm1 AND vm2 are down. `sudo bash deploy/dr/promote_vm3.sh` (refuses while
the public site answers 200; asks before each step): `GATEWAY_ROLE=all`, restart, wait for `/api/health/live` 200,
Caddy reload, DNS of both names to vm3 (`deploy/dr/dns_switch.sh`: DuckDNS by API; devmonks.space by the provider API
when `/etc/coroute/dns.env` has it, otherwise the script prints the exact record to set by hand). Settings for the
scripts: `/etc/coroute/dr.env` on vm3 (`VM3_PUBLIC_IP`, `NLB_PUBLIC_IP`, `PUBLIC_HOST`).
**Back to normal:** start vm1/vm2, confirm they are healthy behind the NLB, then `sudo bash deploy/dr/demote_vm3.sh`
(DNS back to the NLB, waits out the TTL while vm3 still serves, then standby). Never run vm1 and a promoted vm3 at the
same time for longer than the DNS switch: they do not mirror each other.
**Automatic option:** `WATCH_AUTO_PROMOTE=1` in `/etc/coroute/watchdog.env` promotes once after `public`, `vm1` and
`vm2` were all down for `WATCH_PROMOTE_AFTER_MIN` (15) minutes. Off unless the owner decides otherwise.

### Watchdog (vm3, and vm4 watching vm3)

`/opt/coroute/watchdog/coroute_watchdog.js` (no dependencies, ≈ 30 MB): every 30 s checks each `WATCH_TARGETS`
entry (`http`: 2xx and `HEALTHY` for `/api/health`; `ws`: upgrade 101), one alert e-mail after 3 failures in a row,
one recovery e-mail, a daily summary at 03:00 UTC with uptime per target, the last backup and the last restore drill.
Mail through the existing SMTP settings (password from `/run/coroute/secrets.env`). Per-node checks use the VM's
public IP with the TLS name `coroute.duckdns.org` (Caddy's `:443` answers `/api/health/live` by IP).
```bash
sudo nano /etc/coroute/watchdog.env      # from deploy/watchdog/watchdog.example.env
sudo systemctl enable --now coroute-watchdog && journalctl -u coroute-watchdog -f
```
Uptime Kuma was considered: ≈ 150-250 MB with its database, too much next to the standby gateway on 1 GB.

### Backups (v3.56)

| Layer | Where | What | Keep |
|---|---|---|---|
| 1 | gateway job (both VMs, leased) | encrypted hourly `critical` + nightly `full` to the tenancy-1 bucket (PAR) | `BACKUP_RETENTION_DAYS` (30) |
| 2 | vm3 `coroute-backup.timer` 22:40 UTC (`deploy/nightly_backup.py`) | encrypted full export (same AES-256-GCM format) to vm3's disk `/var/backups/coroute/{daily,weekly,monthly}` | 7 daily, 4 weekly, 3 monthly |
| 3 | same run | copy to the tenancy-2 bucket through `OFFSITE_PAR_URL` (write-only PAR) | bucket lifecycle rule, 100 days |
| check | same run + `coroute-restore-drill.timer` (Sundays) | decrypt, verify the manifest, restore every collection into an in-memory DB, compare counts, mail the result | `/var/lib/coroute-backup/last*.json` |

```bash
sudo nano /etc/coroute/backup.env                                   # OFFSITE_PAR_URL, ALERT_TO (deploy/backup/backup.example.env)
sudo python3 /opt/coroute/nightly_backup.py --dry-run && sudo python3 /opt/coroute/nightly_backup.py
sudo systemctl enable --now coroute-backup.timer
sudo cp /opt/coroute/gateway/deploy/backup/coroute-restore-drill.* /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now coroute-restore-drill.timer && sudo systemctl start coroute-restore-drill
```
The old `nightly_backup.py` uploaded unencrypted JSON; it is replaced. Object Storage Always Free: 20 GB and 50,000
requests a month per tenancy; layer 3 uses about 60 requests a month. Keep `BACKUP_ENCRYPTION_KEY` in the owner's
password manager too: without it no backup can be read.

### Load tests

`gateway/tool/load/README.md`. Locally: `node tool/load/ws_load.js --riders 3000 --group-size 8 --hz 0.4`. Staging:
`deploy/staging/quick_load.sh` (also the release gate). Never against production (the tools refuse it).

### Metrics and load shedding

`curl -s http://127.0.0.1:3000/metrics` on a VM (Prometheus text; loopback only, 404 through Caddy). Watch:
`coroute_event_loop_lag_ms{quantile="0.99"}`, `coroute_ws_connections`, `coroute_db_calls_total`,
`coroute_db_queue_length`, `coroute_load_shedding`, `coroute_process_resident_memory_bytes`. Load shedding (`LOAD_SHED=on`)
answers 503 + Retry-After for non-essential reads only (reviews, community stats, leaderboards, intel layers, POI
cells, analytics) while the event loop lags > 250 ms, > 200 requests are in flight, the heap is > 90 % or > 200 DB
calls wait. Never shed: SOS, alerts, crash reports, auth, convoys / ride telemetry, guardian, live links, health,
payment webhooks, WebSockets. Drill: `LOAD_SHED=force` on staging.

### Scaling triggers

| Signal (vm1) | Action |
|---|---|
| > 500 concurrent riders sustained, or lag p99 > 100 ms for 10 min, or CPU steal (`%st` in `top`) > 30 % | plan the A1 realtime move (plan section 5) |
| `coroute_ws_connections` > 2,000 on a micro | set / check `LIVE_RIDER_CAP=2500` |
| `coroute_db_calls_total` rate > 300/s | `INTEL_CONSENT_TTL_MS=300000`, `WS_GATE_TTL_MS=300000` |
| `coroute_db_queue_length` > 0 for minutes | ADB is the bottleneck: check its CPU in the console |
| disk on vm3 > 80 % | lower backup retention or move old monthly copies offsite only |

## Round 8 realtime (abuse limits, compact frames, big rides, SOS probe and twin continuation, stage 1, stage 4 prepared)

Details, settings and measured numbers: `docs/quality/ROUND8_REALTIME_NOTES.md`. Plan: `docs/infra/HIGH_TRAFFIC_PLAN_v3.57.md`.

### Abuse limits (on by default)

Per IP: 50 open sockets (`WS_MAX_CONN_PER_IP`) and 120 new sockets a minute (`WS_CONN_PER_MIN_PER_IP`), refused at the
upgrade with HTTP 429. The IP is taken from `X-Forwarded-For` through `TRUST_PROXY` (Caddy always sets it); a direct
loopback connection without it (tools on the VM) is not counted. Per account: 30 new sockets a minute (close 4429
`TOO_MANY_CONNECTS`) and `WS_MAX_SOCKETS_PER_USER` open (oldest closed). Per socket: token buckets per message class
(`WS_RL_*`); over budget = dropped (+ ERROR 429 for chat / actions), a `RATE_LIMIT` warning frame, and close 4429
`RATE_LIMIT_<CLASS>` for a socket that keeps flooding; refused JOINs close 4429 `JOIN_FLOOD`; invalid frames 4400
`INVALID_FRAMES`. **SOS and alert messages are never counted, dropped or schema-rejected**; the SOS budget per socket
never drops below `WS_SOS_FLOOR_PER_10S` (10) and above it the rider's open alert is echoed back.
Watch: `curl -s 127.0.0.1:3000/metrics | grep 'coroute_ws_events_total{kind="rl'`. A NAT exit (office, carrier CGNAT)
hitting `rlIpConcurrent`: raise `WS_MAX_CONN_PER_IP` (or 0 = off) and restart; a phone build looping: `rlUserConnect`.

### Compact positions (`pos2`) and interest management

The gateway advertises `pos2`; apps from this round send P2 frames and get RU2 batches, older apps keep JSON. Kill
switch: `WS_POS2=off` (stops advertising; P2 still accepted). Big rides: above `WS_INTEREST_ABOVE` (30) sockets each
rider gets its nearest 20, the lead / sweeper / owner and anyone in alert at full rate, the rest every 5 s; alerts
always reach everyone. Off: `WS_INTEREST=off`.

### SOS continuation on the twin (automatic)

The live node sends an "SOS pending delivery" record to its mirror peer before it stores and fans out a new alert.
If the link dies first, the peer stores the alert if needed, sends it to its sockets (riders reconnecting there see it
in the SNAPSHOT) and starts the safety network / SMS round. Check after a failover:
`curl -s 127.0.0.1:3000/metrics | grep coroute_ws` and the gateway log line `continued SOS ... (the peer died before its fan-out)`.

### SOS probe (watchdog, staging only)

One-time setup on **staging**: two accounts used only by the probe (e-mails in the watchdog env, password in the
secrets file), one group named `SOS probe staging` with exactly those two riders, created and joined by signing in
once with the probe's device identity (`deploy/watchdog/sos_probe.js` `probeDevice`, so the ride lock lets the probe
sign in again every 15 min). Then in `/etc/coroute/watchdog.env`: `WATCH_SOS_PROBE=1`, `WATCH_SOS_PROBE_URL`,
`WATCH_SOS_PROBE_API`, `WATCH_SOS_PROBE_GROUP`, `WATCH_SOS_PROBE_EMAIL_A/B` (template `watchdog.example.env`) and
`WATCH_SOS_PROBE_PASSWORD` in `/run/coroute/secrets.env`; restart `coroute-watchdog`. It refuses any host without
"staging" in its name and any group with another rider. Mail on > 1 s or failure (then hourly while bad), recovery
mail, daily summary line, status file `/var/lib/coroute-watchdog/sos_probe.json`.

### Stage 1: A1 as the live node

`gateway/deploy/stage1_live_a1.sh --a1 a1 --a1-ip <a1 private ip> --vm1-ip <vm1 private ip> --vm2-ip <vm2 private ip>`
walks the order and checks each step (asks before every change; `--step N` resumes):
1. check the A1 (aarch64, 2 OCPU / 12 GB: the Always Free size per account), vm1 / vm2 healthy;
2. install it as a LIVE node paired with vm2 (`setup_node.sh`, `host/apply.sh --role live-a1`: heap 2048 MB,
   MemoryHigh 4 GB / MemoryMax 5 GB, `GATEWAY_ROLE=live`, `LIVE_RIDER_CAP=2500`), release the current build to it;
3. firewalls: vm2 accepts the A1 on 3000 / 3101, vm1 accepts it on 3000;
4. **NLB: drain vm1** (console), then vm1 restarts as `GATEWAY_ROLE=web` without mirror settings: its riders move to vm2;
5. start the A1: it dials vm2's mirror listener (vm2 is never restarted while it holds riders), syncs, serves; install
   `Caddyfile.vm1` on it with WEB upstreams vm2 then vm1;
6. **NLB: the A1 becomes the primary backend**, vm2 stays the backup, vm1 is removed;
7. vm2 hands riders back to the A1 (RECONNECT in batches);
8. vm2's `MIRROR_PEER_URL` points at the A1 for its next restart; add the A1 to the watchdog targets; run the gate.
`LIVE_RIDER_CAP` stays 2500 until the twin is an A1 too (stage 2), then 6000.

**Stage 1: rollback.** NLB: vm1 back as primary (A1 drained); on vm1 `GATEWAY_ROLE=live` and its mirror settings back
(`MIRROR_LISTEN_HOST`, `MIRROR_PEER_URL=ws://<vm2 private ip>:3101/mirror`), restart vm1; stop the A1's gateway once
vm2 has handed the riders back to vm1.

### Stage gates (`tool/load/ws_load.js --preset ...`)

```bash
node tool/load/ws_load.js --preset gate2x   --target-riders 2500 --target wss://staging.<domain>/ws --tokens tokens.json --gate
node tool/load/ws_load.js --preset soak     --target-riders 2500 ... --seconds 86400
node tool/load/ws_load.js --preset failover --target-riders 2500 ... --failover-cmd "ssh vm4 sudo systemctl kill -s KILL coroute-gateway"
node tool/load/ws_load.js --preset flood    --target-riders 2500 ... --gate
```
The summary prints PASS / FAIL per target (SOS p99 < 150 ms, positions p99 < 250 ms, every SOS delivered, >= 99 %
back within 10 s, flood limits engaged). Record results in `docs/infra/` with the date. Never against production.

### Stage 4: second live pair (prepared, not enabled)

`SHARDS=1` (default) changes nothing. When a second pair exists: `SHARDS=2 SHARD_PAIRS=a,b SHARD_SELF=<pair>` on every
node; `node deploy/gen_caddy_shards.js --shards 2 --upstream a="<a-live>:3000 <a-twin>:3000" --upstream b="..."`
prints the Caddy matchers (`/ws?g=<groupId>`, `/api/convoys/<groupId>/...`, `?shard=<pair>`) to put before the generic
LIVE handles. Apps resolve a join code first with `GET /api/shard?code=` and join with `?shard=<pair>`; the app side of
this (opening `/ws?g=<groupId>`) is not built yet. `--table` prints which buckets each pair owns.
