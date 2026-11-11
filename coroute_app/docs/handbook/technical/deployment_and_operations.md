# CoRoute deployment and operations

Audience: whoever deploys and runs the gateway. Secrets are referenced by **name only**; values
live in OCI Vault and `/etc/coroute/*.env` / `/run/coroute/secrets.env` on the VMs, never in git.
Written 11 Nov 2026.

Primary procedures (read these, this page summarises and indexes them):

- **[docs/MASTER_AGENT_PROMPT_v3.55.md](../../MASTER_AGENT_PROMPT_v3.55.md)**: the release agent prompt
  (commit, build, test, two-VM deploy, security tasks, device gate, soak, Play publish).
- [docs/PRODUCTION_TWO_VM_RUNBOOK.md](../../PRODUCTION_TWO_VM_RUNBOOK.md): OCI setup, provisioning,
  verification, secret rotation, deploy, drills, rollback.
- [gateway/deploy/RUNBOOK.md](../../../gateway/deploy/RUNBOOK.md): single-VM install, Caddy, first admin,
  Razorpay go-live, release order history, `MIN_APP_BUILD`.
- [gateway/deploy/route_split.md](../../../gateway/deploy/route_split.md): LIVE vs WEB route classification.
- [docs/DOMAIN_MIGRATION_devmonks.md](../../DOMAIN_MIGRATION_devmonks.md): domain move.
- [gateway/deploy/VM_OPERATIONS_LOG.md](../../../gateway/deploy/VM_OPERATIONS_LOG.md): what was done on
  the VMs (names only).
- [docs/SERVER_LOAD.md](../../SERVER_LOAD.md), [docs/BATTERY.md](../../BATTERY.md).

## 1. Environments

| Environment | What | Notes |
|---|---|---|
| Production | VM1 (`GATEWAY_ROLE=live`) + VM2 (`GATEWAY_ROLE=web`) behind the OCI NLB; Oracle Autonomous DB (Always Free, Hyderabad); Object Storage; Vault | Domains `coroute.devmonks.space` (canonical) and `coroute.duckdns.org` (legacy). VM private IPs in the runbook. |
| Restore target | A second Autonomous DB ("DB2") with the `COROUTE` schema | Used for restore drills; never restore into production first. |
| Local / CI | `ORACLE_SODA_URL=memory` | The test suite boots full gateways in memory (`createApp`). |
| Razorpay test mode | `RAZORPAY_MODE=test` or admin setting | End-to-end purchase test before live mode. |

There is no separate staging cluster today; the load test scripts must target a staging copy, not
production.

## 2. Environment variable catalogue

Source: `gateway/src/config.js` plus variables read directly by modules. "Vault" = secret, kept in
OCI Vault and delivered to `/run/coroute/secrets.env` by `coroute-secrets.service`.

### 2.1 Core

| Name | Purpose | Default | Secret |
|---|---|---|---|
| `NODE_ENV` | `production` / `test` | production | |
| `PORT`, `HOST` | listen address (Caddy in front) | 3000, 127.0.0.1 | |
| `ORACLE_SODA_URL` | ORDS SODA endpoint (`memory` for local) | required | |
| `ORACLE_USER` | schema user (`COROUTE`) | required | |
| `ORACLE_PASSWORD` | DB password | required | Vault |
| `ORACLE_TIMEOUT_MS` | SODA request timeout | 6000 | |
| `JWT_SECRET` | signs rider tokens (≥ 32 chars) | required | Vault |
| `JWT_SECRET_PREVIOUS` | rotation grace: still accepted, never signed | empty | Vault |
| `JWT_TTL_DAYS` / `TOKEN_REFRESH_AFTER_HOURS` | token life / sliding refresh | 30 / 24 | |
| `SETTINGS_ENCRYPTION_KEY` | 32 random bytes base64: encrypts admin-saved Razorpay secrets, signs checkout links | empty (warns) | Vault |
| `PASSWORD_SCRYPT_N`, `_R`, `_P` | scrypt cost | 32768, 8, 1 | |
| `PASSWORD_HASH_CONCURRENCY`, `PASSWORD_BCRYPT_WORKERS` | hashing concurrency | 2, 1 | |
| `BOOTSTRAP_ADMIN_EMAILS` (alias `ADMIN_EMAILS`) | seeds first MASTER_ADMIN accounts | empty | |
| `STAFF_EMAILS` | staff accounts left out of rider analytics | empty | |
| `USER_GATE_TTL_MS` | account cache | 30000 | |
| `GOOGLE_CLIENT_IDS`, `GOOGLE_WEB_CLIENT_ID` | Google ID-token audiences; web button on `/signin` | empty | |
| `TRUST_PROXY` | proxies whose X-Forwarded-For is trusted (VM1 `loopback`; VM2 `loopback,<VM1 private IP>`) | loopback | |
| `CORS_ORIGINS` | extra CORS origins (site origins always added) | empty | |
| `SUPPORT_EMAIL` | role contact address shown on the legal pages, receipts and sent to map providers | empty (pages then show the home page contact form) | set a role address such as support@ |
| `SECURITY_CONTACT` | contact in `/.well-known/security.txt` and on `/security` | `SUPPORT_EMAIL` | role address such as security@ |

### 2.2 Two-VM, mirror and jobs

| Name | Purpose | Default |
|---|---|---|
| `GATEWAY_ROLE` | `live` / `web` / `all` | all |
| `NODE_NAME` | node id for leases and mirror | hostname |
| `MIRROR_LISTEN_HOST`, `MIRROR_LISTEN_PORT`, `MIRROR_PEER_URL` | mirror link | off, 3101, off |
| `MIRROR_KEY` (Vault, ≥ 32 chars, same on both) | mirror auth and encryption | — |
| `MIRROR_ACK_TIMEOUT_MS`, `MIRROR_HANDBACK_DELAY_MS`, `MIRROR_HANDBACK_PER_SEC`, `MIRROR_STARTUP_WAIT_MS`, `MIRROR_SYNC_TIMEOUT_MS` | mirror tuning | 400, 15000, 25, 3000, 30000 |
| `LIVE_RIDER_CAP` | distinct live riders before new ones get 503 `SERVER_BUSY` (0 = off) | 0 |
| `JOB_LEASE_TTL_MS`, `JOB_LEASE_HEARTBEAT_MS`, `JOB_LEASE_GRACE_MS` | leases | 60000, 15000, 120000 |
| `WS_COALESCE_ABOVE`, `WS_COALESCE_MS`, `WS_POSITION_DROP_BYTES`, `WS_MAX_BUFFERED_BYTES`, `WS_MAX_SOCKETS_PER_USER`, `WS_OUT_SOFT_BYTES`, `VOICE_MAX_FPS`, `LIVE_REJOIN_GRACE_MS` | socket fan-out guards | 20, 500, 256 KiB, 4 MiB, 8, 128 KiB, 100, 15 min |

### 2.3 Domains, website and app versions

| Name | Purpose | Default |
|---|---|---|
| `PUBLIC_ORIGIN` | canonical origin for every generated link (`https://coroute.devmonks.space`) | empty = links on the legacy host |
| `LEGACY_ORIGINS` | still-served origins (CORS, guardian Origin) | `https://coroute.duckdns.org` |
| `REDIRECT_LEGACY_HOST` | 301 website pages on legacy host (never `/api`, `/ws`, `/.well-known`, `/e/`, `/watch`) | false (owner decided true for this release) |
| `PLAY_STORE_URL` | turns website buttons to Play and shows "Rate on Google Play" | empty |
| `APK_URL`, `APK_ARM32_URL` | website APK links | `<origin>/coroute.apk`, `/coroute-32bit.apk` |
| `APP_STORE_URL`, `IOS_TESTFLIGHT_URL`, `IOS_IPA_URL` | iOS (empty = "coming soon") | empty |
| `MIN_APP_BUILD` / `LATEST_APP_BUILD` | force update / update available | 60 / 10019 |
| `PAYMENTS_ENABLED` | `false` = everything free (overrides access mode) | true in production |

### 2.4 Rides, safety and retention tuning

All have safe defaults; change only with a reason. Groups (see `config.js` for every name):

- Join and limits: `JOIN_WINDOW_MIN` 15, `JOIN_MAX_FAILURES` 10, `JOIN_MAX_FAILURES_PER_IP` 30,
  `MAX_CONVOY_RIDERS` 50, `WS_ACTIONS_PER_SEC` 10, `WS_ALARMS_PER_10S` 3, `ROSTER_PER_MIN` 6,
  `ROSTER_VALID_H` 12, `SMS_MAX_RECIPIENTS` 10, `SOS_RESPONDERS_MAX` 50, `CLIENT_ID_CACHE`,
  `CLIENT_ID_TTL_H`, `SOS_DEDUPE_MS`.
- Trips and tracks: `TRIP_MAX_TRAIL_POINTS` 4000, `MAX_TRIPS_PER_USER` 500, `TRIP_MAX_BYTES` 1 MiB,
  `TRACK_MAX_POINTS`, `TRACK_BATCH_FLUSH_MS`, `TRACK_BATCH_MAX`, `TRACK_UPLOAD_GRACE_MIN`,
  `REPORT_DELAY_MS`, `REPORT_REBUILD_MS`, `RIDER_PERSIST_INTERVAL_MS` 15000.
- Retention: `TRACK_RETENTION_DAYS` 90, `TRACK_DETAIL_DAYS` 14, `TRACK_SIMPLIFY_TOLERANCE_M` 5,
  `RETENTION_ENDED_CONVOY_DAYS` 90, `RETENTION_STALE_CONVOY_HOURS` 36, `RETENTION_VOICE_LOG_DAYS` 7,
  `AUDIT_RETENTION_DAYS` 180, `GEO_CACHE_DAYS` 30, `RETENTION_RUN_EVERY_MINUTES` 360,
  `DB_KEEPALIVE_EVERY_MINUTES` 720.
- Timeline: `TIMELINE_TICK_MS` 2000, `STOP_RADIUS_M`, `STOP_EXIT_M`, `OFF_ROUTE_M` 300,
  `OFFLINE_ALERT_MIN` 5, `OVERSPEED_TOLERANCE_KMH` 2, `OVERSPEED_HOLD_MS` 2000,
  `OVERSPEED_CLEAR_MS`, `OVERSPEED_RENOTIFY_MS`, `STATIONARY_ALERT_MIN` 20, `REACH_RADIUS_M`,
  `TOWN_RADIUS_M` 1000, `STALE_MIN_S` 90, `STALE_FACTOR` 3, `SWEEPER_BEHIND_M` 300,
  `CONVOY_SPLIT_*`, `REGROUP_*`, `SWEEPER_*`, `BATTERY_LOW_PCT` 15, `BATTERY_OK_PCT` 25.
- Possible incident: `INCIDENT_FROM_KMH` 40, `INCIDENT_STOP_KMH` 5, `INCIDENT_STOP_WITHIN_S` 15,
  `INCIDENT_STILL_S` 120, `INCIDENT_STILL_RADIUS_M` 40, `INCIDENT_STOP_NEAR_M` 300,
  `INCIDENT_NEAREST` 2, `INCIDENT_GROUP_NEAR_M` 150, `INCIDENT_STILL_GROUP_S` 300,
  `NO_SIGNAL_ESCALATE_MIN` 10, `NO_SIGNAL_MIN_KMH` 30.
- Safety network / discovery / public ride: `SAFETY_NET_ENABLED` 1, `DISCOVERY_ENABLED` 1,
  `PUBLIC_RIDE_ENABLED` 1, `EMERGENCY_EXPIRE_MIN` 180, `EMERGENCY_CANCEL_GRACE_S` 60, the `NET_*`
  family (radii 5 / 10 km, `NET_NOTIFY_MAX` 3, `NET_PENDING_MAX` 3, OSRM limits ...),
  `NET_PUBLIC_RADIUS_M` 2000, `DISCOVERY_*`, `PUBLIC_RIDE_*`, `ROAD_WARN_*`, `HAZARD_AHEAD_M`,
  `HAZARD_MAX_RECIPIENTS`, `REPORT_DOWN_PER_10MIN`, `REPORT_FALSE_PER_H`, `ABUSE_*`.
- Live links: `LIVE_LINK_MIN` 30, `LIVE_LINK_PER_ALERT` 3. Hospitals: `HOSPITAL_MAX_WAIT_MS` 5000.
- Medical limits: `MEDICAL_ALLERGIES_MAX` 120, `MEDICAL_NOTES_MAX` 200.
- Voice: `VOICE_MAX_FRAME_BYTES` 16384, `VOICE_STREAM_IDLE_MS` 1500, `VOICE_MAX_STREAM_MS` 60000.

### 2.5 Maps and weather

`GEO_SEARCH_URL` (Nominatim), `GEO_ROUTE_URL` (OSRM), `GEO_PHOTON_URL` (Photon), `GEO_COUNTRY` (`in`),
`GEO_COUNTRY_BBOX`, `GEO_PHOTON_MIN_INTERVAL_MS`, `GEO_REVERSE_TIMEOUT_MS`, `GEO_MIN_INTERVAL_MS`,
`GEO_CONTACT`, `POI_OVERPASS_URL`, `ESSENTIALS_OVERPASS_URL`, `WEATHER_URL` (Open-Meteo; empty
disables), `WEATHER_CACHE_MIN`, `WEATHER_PER_MIN`, `WEATHER_USER_PER_MIN`.

### 2.6 Messaging

| Name | Purpose | Default | Secret |
|---|---|---|---|
| `FCM_SERVICE_ACCOUNT_JSON` or `FCM_SERVICE_ACCOUNT_FILE`, `FCM_PROJECT_ID` | push sender | off (tokens stored, sends are logged no-ops) | Vault |
| `PUSH_CAMPAIGN_RATE`, `PUSH_NEWS_DAILY_CAP`, `PUSH_IMAGE_DIR` | campaigns | 50/s, 2/day, data dir | |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASS`, `MAIL_FROM`, `MAIL_REPLY_TO` | e-mail (receipts, offers, operator notices) | off; port 587 STARTTLS | `SMTP_PASS` Vault |
| `OFFER_EMAIL_RATE` | offer e-mails per second | 5 | |
| `OPERATOR_REVIEW_EMAIL` | operator application notices | falls back to `SUPPORT_EMAIL` | |
| `SMS_PROVIDER` | `off` / `msg91` / `twilio` | off (until DLT approved) | |
| `SMS_SENDER_ID`, `SMS_DLT_ENTITY_ID`, `SMS_DLT_TEMPLATE_ID_SOS`, `SMS_DLT_TEMPLATE_ID_SAFE`, `MSG91_TEMPLATE_ID_SOS`, `MSG91_TEMPLATE_ID_SAFE` | DLT registration | empty | |
| `MSG91_AUTH_KEY`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` (`TWILIO_PHONE_NUMBER`), `TWILIO_MESSAGING_SERVICE_SID` | providers | empty | Vault |
| `SMS_WEBHOOK_TOKEN` | path token for delivery receipts | empty | Vault |
| `SMS_MAX_PER_SOS`, `SMS_MAX_PER_USER_DAY`, `SMS_SAFE_SMS` | SMS limits / "safe now" text | 5, 20, true | |
| `TELEPHONY_PRIMARY_PROVIDER`, `TELEPHONY_SECONDARY_PROVIDER`, `AWS_SNS_*`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `INFOBIP_*`, `TELEPHONY_WEBHOOK_URL`, `TELEPHONY_WEBHOOK_TOKEN`, `WHATSAPP_*` | older provider chain (`emergency_sms_gateway.js`) | twilio, webhook | keys Vault |
| `GUARDIAN_ENABLED`, `GUARDIAN_PUSH_ENABLED`, `GUARDIAN_VAPID_PUBLIC_KEY`, `GUARDIAN_VAPID_PRIVATE_KEY`, `GUARDIAN_VAPID_SUBJECT` | Ride Guardian pilot (needs HTTPS `PUBLIC_ORIGIN`) | false | private key Vault |

### 2.7 Payments

| Name | Purpose | Default | Secret |
|---|---|---|---|
| `RAZORPAY_MODE` | `test` / `live` (admin setting overrides) | — | |
| `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_TEST_KEY_ID`, `RAZORPAY_TEST_KEY_SECRET`, `RAZORPAY_LIVE_KEY_ID`, `RAZORPAY_LIVE_KEY_SECRET` | keys (or admin-saved, encrypted with `SETTINGS_ENCRYPTION_KEY`) | — | Vault |
| `RAZORPAY_WEBHOOK_SECRET`, `RAZORPAY_TEST_WEBHOOK_SECRET`, `RAZORPAY_LIVE_WEBHOOK_SECRET` | webhook HMAC | — | Vault |
| `RAZORPAY_WEBHOOK_URL` | which webhook URL is active: `subscription` or `membership` | subscription | |

### 2.8 Storage and backups

| Name | Purpose | Default | Secret |
|---|---|---|---|
| `REVIEW_PHOTO_STORE`, `REVIEW_PHOTO_DIR`, `REVIEW_PHOTO_PAR_URL` | review photos on disk or Object Storage | disk, `gateway/data/review-photos` | PAR URL Vault |
| `DIAG_LOG_STORE`, `DIAG_LOG_PAR_URL` | diagnostics logs in DB or Object Storage | DB | PAR URL Vault |
| `BACKUP_PAR_URL`, `BACKUP_ENCRYPTION_KEY` | encrypted backups | off | Vault (keep the key also in the owner's password manager) |
| `BACKUP_CRITICAL_EVERY_MINUTES`, `BACKUP_FULL_HOUR_UTC`, `BACKUP_RETENTION_DAYS` | schedule | 60, 21, 30 | |
| `DUCKDNS_TOKEN` | Caddy DNS-01 for both certificates (Caddy env, not the gateway) | — | Vault |

## 3. Deploy

Full procedure: MASTER_AGENT_PROMPT section 4 and PRODUCTION_TWO_VM_RUNBOOK section 7. Summary:

1. Take an encrypted DB backup to durable storage (Object Storage, not `/tmp`) and dry-run restore it.
2. Build the release from the pushed commit: `npm ci --omit=dev`, include `gateway/public`,
   `gateway/deploy`, `gateway/scripts`.
3. Confirm `/etc/coroute/gateway.env` on **both** VMs (`PUBLIC_ORIGIN`, `LEGACY_ORIGINS`,
   `REDIRECT_LEGACY_HOST`, `FCM_*`, `SMTP_*`, `SMS_PROVIDER`, stores, `OPERATOR_REVIEW_EMAIL` ...)
   and that the Vault secret ids are present.
4. Deploy **VM2 first**, restart, run checks; then **VM1**. Only when `deploy/` changed: units and
   Caddyfile via `setup_node.sh`, then `systemctl reload caddy`.
5. Checks on both hosts: `/api/health` 200, `/`, `/features`, `/privacy-and-security`,
   `/leaderboard`, `/updates`, `/plans`, `/signin`, `/account`, `/operators/apply`, `/admin`,
   identical `/.well-known/assetlinks.json`, legacy host `/` 301 while `/api/health` 200, WebSocket
   HELLO lists `ride355`, `vehicle1`, `pillion2`. `gateway/deploy/smoke_test.sh` helps.
6. One-time admin tasks after this release: `POST /api/admin/usernames/backfill`, Plans
   "Reconcile", set the access mode, confirm feature switch ids (no `hornAlert`), send a test push.
7. Razorpay test-mode purchase end to end, then refund from `/admin`.
8. Old-app check: a 3.54/3.55 build signs in and joins through `coroute.duckdns.org`.

systemd: `coroute-gateway.service` (`User=coroute`, `Restart=always`, `RestartSec=2`,
`MemoryMax=700M`, `Requires=coroute-secrets.service`), `coroute-secrets.service` (Vault fetch via
instance principal into tmpfs). Rollback: rsync `/opt/coroute/rollback/` and restart, VM2 first
(do not roll back past the scrypt release; fix forward).

## 4. Monitoring and logs

| What | How |
|---|---|
| Gateway logs | `journalctl -u coroute-gateway -f` (no bodies or personal data; 5xx lines carry method, route template, status and `req=<request id>`) |
| Caddy | `journalctl -u caddy -f` |
| Secrets fetch | `journalctl -u coroute-secrets -b` (names the failing secret, never its value) |
| Health | `GET /api/health` (DB, leases: `curl -s localhost:3000/api/health \| jq .leases`), `GET /api/health/live` (mirror connected, `liveRiders`, `eventLoopLagMs`) |
| Memory | `systemctl show coroute-gateway -p MemoryCurrent` |
| Time sync | `chronyc tracking` (leases depend on it) |
| Request tracing | `X-Request-Id` on every response; the app logs it in `network.api_error` diagnostics entries, so a rider's sent log can be matched to server lines |
| Rider diagnostics | `/admin` > Diagnostics logs (list, view, download; "Ask for logs" sends a push) |
| Product health | `/admin` overview, analytics, feature analytics, emergencies, Play Console vitals (crash-free ≥ 99.5 % target before advancing rollout) |
| Security audit | `gateway/deploy/audit_security.sh`, `post_deploy_hardening.sh`, `harden_security.sh` |

Alerting: there is no paging integration in the repository. The NLB health check and systemd
restarts are the automatic defence; an external uptime monitor on `/api/health/live` for both hosts
is recommended (owner to choose a service).

## 5. Scaling and soak

- `LIVE_RIDER_CAP` (both VMs, same value): raise in 25 % steps while peak `eventLoopLagMs` < 100
  and memory < 550 MB; lower when either is exceeded. Riders already riding are never refused.
- 30-minute soak with simulated riders: `node test/integration/live_convoy_verifier.js`; load test:
  `node gateway/scripts/load_convoy_ws.js` against a staging copy. Capacity notes:
  [docs/SERVER_LOAD.md](../../SERVER_LOAD.md).
- `MAX_CONVOY_RIDERS` (50) is the server ceiling per ride; plans advertise 12.

## 6. Backups and restore

- Automatic: `backup-critical` hourly and `backup-full` daily (after 21:00 UTC), encrypted with
  `BACKUP_ENCRYPTION_KEY`, to the backups bucket through `BACKUP_PAR_URL`, kept 30 days. If the PAR
  cannot list, add an Object Storage lifecycle rule (prefix `coroute/`, delete after 30 days).
- Restore (always into DB2 first): `node scripts/backup_restore.js --latest full --dry-run` with
  `RESTORE_SODA_URL`, `RESTORE_ORACLE_USER`, `RESTORE_ORACLE_PASSWORD`, `BACKUP_PRODUCTION_HOSTS`
  (exact command: PRODUCTION_TWO_VM_RUNBOOK 9.3). Production restore requires
  `--i-understand-this-overwrites-production`, both gateways stopped.
- Monthly restore drill recommended; quarterly at minimum (drill 6).
- Payments ledger notes: [gateway/deploy/RUNBOOK.md §6b](../../../gateway/deploy/RUNBOOK.md).

## 7. Domain and TLS

- Caddy issues both certificates by DNS-01 through DuckDNS (`DUCKDNS_TOKEN`); the devmonks.space
  challenge is a CNAME to the DuckDNS challenge name. Owner DNS: A record for
  `coroute.devmonks.space` → NLB public IP, `_acme-challenge` CNAME.
- HSTS on `coroute.devmonks.space` starts at `max-age=300`; raise to `31536000` after one stable
  week (owner decision) and reload Caddy. Never `includeSubDomains` on devmonks.space.
- Keep `coroute.duckdns.org` served at least 6 months (installed apps).
- After each Play signing change, add the App signing SHA-256 to `gateway/public/.well-known/assetlinks.json`.

## 8. Failover drills

Run quarterly (PRODUCTION_TWO_VM_RUNBOOK section 8): (1) kill gateway on VM1, (2) reboot VM1,
(3) VM2 down, (4) cut the mirror link, (5) database outage (live rides continue in memory;
sign-in and payments fail; `/api/health/live` stays 200), (6) backup restore into DB2,
(7) secrets unavailable. Before the Play production launch: stop the live node mid-ride and confirm
takeover, reconnects and **SOS still delivered** (MASTER_AGENT_PROMPT section 7).

## 9. Secrets rotation runbook

Log every rotation (date, secret name, who) in `gateway/deploy/VM_OPERATIONS_LOG.md`, never values.

| Secret | Procedure |
|---|---|
| `JWT_SECRET` | New Vault version; move the old value to `JWT_SECRET_PREVIOUS`; restart VM2 then VM1. Old tokens are accepted and refreshed (`X-CoRoute-Token`). After 24-72 h remove `JWT_SECRET_PREVIOUS`. No forced sign-outs. (Runbook 6.1, `docs/features_355/platform.md`.) **Pending: old values are in git history.** |
| `ORACLE_PASSWORD` | Change in ADB for `COROUTE`, new Vault version, restart both VMs promptly (runbook 6.2). **Pending.** |
| `DUCKDNS_TOKEN` | Owner regenerates at DuckDNS (the old token is in git history: `gateway/deploy/setup_new_vm.sh`), store only in Vault + Caddy env, remove from the script, verify certificate renewal. **Pending.** |
| `MIRROR_KEY` | New value on both VMs at once (link re-authenticates). |
| `SETTINGS_ENCRYPTION_KEY` | Re-save Razorpay secrets in `/admin` after changing; checkout links signed with the old key stop working. |
| Razorpay keys / webhook secrets | Rotate in the Razorpay dashboard, then Vault or `/admin` > Payment gateway; test mode first. |
| `SMTP_PASS`, SMS keys, `SMS_WEBHOOK_TOKEN` | Provider dashboard → Vault → restart; update the receipt URL for the webhook token. |
| `FCM_SERVICE_ACCOUNT_JSON` | New key in Google Cloud, Vault, restart, delete the old key. |
| PAR URLs | Create the new PAR, Vault, restart, then delete the old PAR (runbook 6.4). |
| SSH key `vm_provision_ssh.key` on VM1 | **Pending:** move off VM1 to Vault / admin machine only. |

## 10. Routine operations

- OS patches: unattended security upgrades; when `/var/run/reboot-required` exists reboot VM2,
  verify, then VM1. Node.js and Caddy are upgraded deliberately, VM2 first.
- After Play production: set `PLAY_STORE_URL`, set `LATEST_APP_BUILD` to the released build.
- Admin hygiene: review the audit log and diagnostics weekly; reconcile memberships after bulk
  account deletions.
