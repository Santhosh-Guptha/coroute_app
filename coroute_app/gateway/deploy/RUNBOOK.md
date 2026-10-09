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

The DuckDNS name is for testing. Before launch, point your own domain at the VM and let Caddy issue its certificate:

1. At your DNS provider (for devmonks.space, or whichever domain you choose) add **A record** `coroute` → `<vm-public-ip>` (giving `coroute.devmonks.space`).
2. On the VM, re-run the installer with both hostnames so existing test builds keep working while the new one takes over:
   `sudo API_HOST="coroute.devmonks.space, coroute.duckdns.org" bash gateway/deploy/install.sh`
   (Caddy accepts a comma-separated list of site addresses; certificates are issued for each.)
3. Make the custom domain the app's default: in `lib/core/config/app_config.dart` set `defaultValue: 'https://coroute.devmonks.space'`, and in `gateway/public/index.html`, `store/LISTING.md` and `PLAY_STORE_CHECKLIST.md` replace `coroute.duckdns.org`. Rebuild the app.
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
  --obfuscate --split-debug-info=build/symbols --dart-define=COROUTE_API=https://coroute.duckdns.org
# App bundle for the Play Store
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols --dart-define=COROUTE_API=https://coroute.duckdns.org
```
(`COROUTE_API` defaults to `https://coroute.duckdns.org` in `lib/core/config/app_config.dart`, so the flag is optional unless you chose another hostname. Keep `build/symbols` for reading crash stack traces; it is not committed.)

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
* Always Free compute: either VM.Standard.E2.1.Micro (1 OCPU / 1 GB) or up to 4 OCPU / 24 GB of Ampere A1. The gateway is I/O-bound and comfortably serves hundreds of concurrent riders on the Micro shape; move to A1 for thousands.

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

### Administrative Accounts Created:
* `santhosh` (password `Santhosh@180901`) with passwordless sudo.
* `antigravity` (password `Antigravity@CoRoute2026#VM`) with passwordless sudo for automated deployments.
* SSH Password authentication enabled in `/etc/ssh/sshd_config.d/50-password-auth.conf`.
