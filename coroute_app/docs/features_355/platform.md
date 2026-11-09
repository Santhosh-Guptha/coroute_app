# 3.55 platform and reliability

Area: platform. Source: docs/NEXT_RELEASE_PLAN_v3.55.md, "Platform and reliability".

| Work item | Status here |
| --- | --- |
| Wire or retire the offline crash-incident queue | Done: retired (the pending-SOS store already covers it) |
| Retire voice-command and siren services that receive no audio | Done: not created any more until a real audio source exists |
| Deliver admin warnings to riders | Done: gateway, app card, admin switch `adminWarnings`, tests |
| Background job hygiene (retention, indexes, memberships guard) | Checked: nothing missing, no change |
| Code health (`dart analyze lib test`) | Clean at the time of writing |
| Drills, soak test, Object Storage switch-over, restore test, secret rotation, own domain | Can't be done from this repo: runbooks below |

---

## 1. Offline crash-incident queue: retired

**What the code did.** `LocalIncidentStore` (JSON file) and `DurableEventQueue` / `FileDurableEventQueue`
(a priority queue with idempotency keys and backoff) were optional `SafetyService` constructor parameters.
`main.dart` never passed them, so in production they were always null. Nothing ever read the queue back
(`peekPending` had no caller) and nothing read the incident file. When they were set, the code queued a
second copy of every crash/SOS (`crash_<id>` / `sos_<id>` keys) that nothing would ever send.

**Why I retired it instead of wiring it.** The offline crash path already exists and is tested:
`SafetyService._sendCrash` → `ConvoyService.raiseSos` → `PendingSos` saved to SharedPreferences
(`PendingSosStore`). It is sent at once when connected, again on every re-join (`SNAPSHOT` →
`_sendPendingSos`) and on the 10 s unconfirmed-resend tick, and loaded again after an app restart
(`_loadPendingSos`). It always uses the same `clientId`, and the gateway stores an SOS once per
(rider, clientId) (`convoys.js` raiseSos / `findAlertByClientId`). A crash raise also upgrades a waiting
manual SOS and keeps its clientId. Wiring the queue to the gateway would have been a second sender for
the same emergency (two clientIds → two alerts) or a copy of the pending-SOS store. The offline solo ride
has no gateway to send to; its SOS goes out by text message at once, as before.

**Changes**
- `lib/data/services/safety_service.dart`: removed the `incidentStore` / `eventQueue` parameters, fields,
  getters, the local incident writes and the two `enqueue` calls. `triggerManualSos` now raises the SOS
  without first awaiting two (null) stores. The crash and SOS behaviour is otherwise unchanged.
- Deleted `lib/data/local/durable_event_queue.dart`, `lib/data/local/file_durable_event_queue.dart`,
  `lib/data/local/local_incident_store.dart`, `lib/domain/sync/durable_event.dart` and
  `test/durable_event_queue_test.dart`.
- `lib/domain/safety/crash_incident.dart`: keeps only the detector enums (`CrashScenario`,
  `MovementState`), which `crash_detector.dart` uses. `CrashIncident` / `IncidentStatus` are gone.
- `test/offline_safety_and_crash_test.dart`: the queue tests are replaced by a test that checks a crash
  SOS raised offline round-trips through its saved form with its crash fields, and is resent with the
  same clientId. The detector tests are unchanged. Existing coverage of the real path:
  `test/sos_queue_test.dart` (saved across a restart, crash upgrade keeps the clientId, resend).

**Needs a real device:** turn on airplane mode → crash alarm → let it time out → kill the app →
turn airplane mode off → open the app. The group must get exactly one crash alert.

## 2. Voice-command and siren services: no longer created at start-up

**What the code did.**
- `HelmetVoiceService` (hotwords such as "CoRoute I'm OK" and "CoRoute SOS") was a `lazy: false`
  provider in `main.dart`. Nothing ever calls `processSpeech`: there is no speech recogniser, and the
  mic runs only during PTT/VOX (FEAT-MIC-01). Its only caller was the cockpit, which called
  `stopListening()` on a service that never listened.
- `SirenAcousticDetector`: every ride cockpit created a private one, but nothing ever set
  `intercom.onMicChunk = detector.processPcmChunk`, so it never got a frame.

**Changes**
- `lib/main.dart`: the `HelmetVoiceService` provider registration is removed and replaced by a comment
  saying when to add it back (lazily, once a speech source exists). The classes, the hotword matcher and
  their tests stay.
- `lib/presentation/rider/live_cockpit_map_screen.dart`: the cockpit no longer creates a private
  `SirenAcousticDetector`. It still uses one when an app-level provider supplies it. The siren `_Slot`
  stays: it shows only when an event exists, which needs a fed detector.
- **Crash safety:** the only readers are `context.read<HelmetVoiceService?>()` and
  `context.read<SirenAcousticDetector?>()`. Both are nullable and every use is `?.`. No
  `watch`/`read` of the non-null types exists anywhere in `lib/`.
- The admin switch `sirenDetector` and `FeatureGates.sirenAcousticDetector` are unchanged.

**Turning a feature back on later:** register `ChangeNotifierProvider<SirenAcousticDetector>` (lazy) and
connect `processPcmChunk` to the intercom's PTT/VOX chunks. Do the same for `HelmetVoiceService` with a
recogniser that runs only while the mic is already open.

**Needs a real device:** compare memory and battery at idle and during a ride (Android Studio profiler)
with 3.54. Check that the cockpit opens, closes and reopens with no errors.

## 3. Admin warnings delivered to riders

**Behaviour**
- In the admin console, Public ride reports → report → **Warn** works as before. The report is
  ACTIONED/WARN and a `WARNED` row goes into the contact log, which now also records `delivered: true`
  when the rider got the warning. In addition, the reported rider now gets the warning:
  - stored on their user document in `pendingWarnings` (at most 5, newest kept) until they acknowledge it
  - pushed at once over the socket, `{type:'ADMIN_WARNING', id, message, at}`, on either VM
    (`Hub.sendToUser` relays through the mirror)
- `PATCH /api/admin/public-ride/reports/:id` takes an optional `message`. It is plain text: control and
  zero-width characters and `<`/`>` are removed, spaces are collapsed, and it is cut at 280 characters.
  If it is empty, this default line is sent: "Please follow the public ride guidelines: be respectful and
  share only ride and road safety information." The console sends no message today, so the default is
  used. Its confirm dialog now says the rider sees the message.
- Rider API, on the authenticated `/api` router:
  - `GET /api/me/warnings` → `{warnings:[{id, message, at}]}`. The report id and the admin identity are
    never sent.
  - `POST /api/me/warnings/:id/ack` → 200, or 404 when the warning isn't this rider's.
- Admin only: delivery runs only from `publicRideAdminRouter`, behind `requireAuth` + `requireAdmin`.
  A rider gets 403 (tested).
- Audited: `safety_audit` gets kind `ADMIN_WARNING` with detail `SENT` / `ACK`. The warning id goes in
  `incidentId` and the actor/subject in `actorId`/`subjectId`. The text is never stored in the audit.
- Erasing an account removes the user document, and its warnings with it.
- **App:** `AdminWarningsService` reads the list at start, after sign-in and on resume, and also listens
  for the socket push. `AdminWarningCard` on Home (`RideStartView`, which shows only with no ride
  active, so it never covers ride or SOS alerts) shows "Message from moderators" and "A message from
  CoRoute moderators: …". **Acknowledge** posts the ack. The close button hides the card until the next
  start.
- **Switch `adminWarnings`** (gateway `feature_flags.js`, group Platform, on by default). When it is
  off, the gateway delivers nothing (the report is still recorded as before), `GET /me/warnings` returns
  an empty list, and the app shows nothing. Acknowledging still works.

**Files:** `gateway/src/admin_warnings.js` (new), `gateway/src/public_ride.js` (`adminWarnings` hook in
`setReportStatus`, `message` in the PATCH), `gateway/src/app.js` (constructs it), `gateway/src/routes.js`
(rider routes), `gateway/src/safety_audit.js` (new kind), `gateway/src/feature_flags.js` (catalog entry),
`lib/data/services/admin_warnings_service.dart` (new), `lib/presentation/widgets/admin_warning_card.dart`
(new), `lib/presentation/home/ride_start_view.dart` (one line), `lib/main.dart` (provider),
`lib/presentation/admin/admin_ride_reports.dart` (confirm text).

**Tests:** `gateway/test/admin_warnings.test.js` has 4 unit tests and 1 end-to-end test. The end-to-end
test covers: report → admin WARN with a message → the rider's socket gets `ADMIN_WARNING` →
`/me/warnings` → another rider can't ack it → ack → empty list → the contact log says delivered. It also
checks that a rider can't warn and that the switch off delivers nothing. App:
`test/admin_warnings_service_test.dart` (analyzer-checked; Flutter tests can't run here).

**Next step (optional):** add a short message field to the console's Warn dialog. The API already
accepts `message`.

## 4. Background job hygiene: checked, no change needed

`gateway/src/retention.js` and `gateway/src/oracle/repo.js`:
- `road_hazards`: `purgeExpiredRoadHazards` runs daily. The `road_hazards_exp_ix` index on `expiresAt`
  serves it.
- `place_reviews`: erasing an account removes the rider's reviews and their photos (`deleteUserCascade`).
  The `place_reviews_user_ix` index on `userId` serves it. Place, id and lat indexes exist too.
- Road-risk cells: purged after 180 days (`RoadRiskStore.purgeOld`).
- Memberships orphan purge: the guard is in place. When more than max(5, 20 %) of owners look missing,
  nothing is removed and `orphanPurgeSkipped` is reported. It is covered by
  `gateway/test/safety_review_355.test.js`.
- The new `pendingWarnings` lives on the user document, so there is no new collection and nothing to purge.

## 5. Code health

`/opt/dartpkg/bin/dart analyze lib test` reports "No issues found!". During the run, infos showed up
briefly in `road_care_service.dart` and `sensor_safety_hub.dart` while another agent was editing them.
They were gone at the final run. I didn't touch them.

---

## Not possible here: runbooks

None of these can be done from this repo: no Flutter engine or Gradle, and no OCI tenancy access. The
general secret and deploy procedures are in `docs/PRODUCTION_TWO_VM_RUNBOOK.md`. The steps below are the
exact ones for 3.55.

### Flutter tests and Gradle build
On a machine with Flutter, run `flutter test` (new: `test/admin_warnings_service_test.dart`; changed:
`test/offline_safety_and_crash_test.dart`; deleted: `test/durable_event_queue_test.dart`), then
`flutter build apk --release --split-per-abi`.

### Two-VM failure drills, 30-minute soak, monthly restore test
Use runbook §8 (drills), `gateway/scripts/load_convoy_ws.js` (soak; record peak live riders, p95
latency and RSS on both VMs), and §9.3 (restore into DB 2 with `--dry-run` first, monthly). Write the
measured live-rider cap into `LIVE_RIDER_CAP` (§9.4).

### Moving review photos and APKs to Object Storage
The code is already in place:
- Review **and place** photos: `gateway/src/review_photos.js` (`REVIEW_PHOTO_STORE=par`,
  `REVIEW_PHOTO_PAR_URL`) on top of `gateway/src/object_store.js` (PAR client; deletes overwrite the
  object with a tombstone when DELETE isn't allowed). Trip feedback, place reviews and account erase all
  use the same store.
  1. Create the bucket and PAR (runbook §3.6, `coroute-review-photos`, versioning **off**). Put the PAR
     URL in Vault as `coroute-REVIEW_PHOTO_PAR_URL` and add its OCID to `/etc/coroute/secret_ids.env`
     on both VMs.
  2. On VM2: `node scripts/migrate_review_photos_to_par.js --dry-run`, then run it without
     `--dry-run`, then with `--verify`.
  3. Set `REVIEW_PHOTO_STORE=par` in `/etc/coroute/gateway.env` on both VMs. Restart VM2, then VM1:
     `sudo systemctl restart coroute-secrets && sudo systemctl restart coroute-gateway`.
  4. Check that existing photos show in the app and that a new upload works. Then archive
     `REVIEW_PHOTO_DIR`.
- **APKs:** `/download` redirects to `PLAY_STORE_URL`, then `APK_URL`, then `<origin>/coroute.apk`
  (`/download/32bit` uses `APK_ARM32_URL`). Upload both APKs to a bucket. Create an **object-level
  read-only** PAR for each, with an expiry of about one year and a calendar reminder. Set
  `APK_URL=<par>/coroute.apk` and `APK_ARM32_URL=<par>/coroute-32bit.apk` in `gateway.env` and restart.
  Update `SHA256SUMS.txt` with each release. The in-app update link (`/api/meta` `downloadUrl`) goes
  through `/download`, so it follows automatically.

### Rotating the leaked JWT secret (old values are in git history)
The gateway supports a grace window (`JWT_SECRET_PREVIOUS` is accepted but never used to sign;
`config.js` refuses a value under 32 characters or one equal to `JWT_SECRET`; `auth.js`
`verifyToken`).

**Important: the old secret is public.** For as long as it sits in `JWT_SECRET_PREVIOUS`, anyone can
forge tokens signed with it. Keep the window short (24–72 h, not 30 days), or skip it and accept that
every rider signs in once.

From the laptop (OCI CLI, `mk`/`upd` helpers from runbook §3.4 and §6):
1. Keep the old value as the grace secret: `mk JWT_SECRET_PREVIOUS` and paste the **current (leaked)**
   value. Add `JWT_SECRET_PREVIOUS=<printed OCID>` to `/etc/coroute/secret_ids.env` on **both** VMs.
2. Generate the new secret straight into Vault, without displaying it:
   `oci vault secret update-base64 --secret-id <coroute-JWT_SECRET OCID> --secret-content-content "$(openssl rand -base64 48 | tr -d '\n' | base64 -w0)"`
   Then restart in this order: **VM2**, then **VM1**, each with
   `sudo systemctl restart coroute-secrets && sudo systemctl restart coroute-gateway`.
   Keep the gap between the two restarts to seconds: during it, VM1 still signs with the old secret
   and VM2 accepts both. The log should show `JWT_SECRET_PREVIOUS is configured`. Old tokens are
   accepted and come back with a fresh `X-CoRoute-Token`.
3. If you want zero failed requests during the switch, use the 3-step variant in runbook §6.1
   (prepare → swap → remove).
4. When the grace window ends (24–72 h): remove the `JWT_SECRET_PREVIOUS` line on both VMs, restart
   VM2 then VM1, and delete the Vault secret (`oci vault secret schedule-secret-deletion`).
5. Before step 2: make sure `SETTINGS_ENCRYPTION_KEY` is deployed and the admin payment page has been
   opened once, which migrates the Razorpay secrets off the JWT-derived key.
6. Rotate `MIRROR_KEY` and `SETTINGS_ENCRYPTION_KEY` too if they were ever committed (runbook §6.3).
   Log the rotation (names only) in `gateway/deploy/VM_OPERATIONS_LOG.md`.

### Rotating the leaked database password
1. Store the new value in Vault: `upd ORACLE_PASSWORD <coroute-ORACLE_PASSWORD OCID>` (prompted; it
   isn't kept in shell history).
2. In the OCI console: Autonomous Database → Database Actions → SQL, as ADMIN:
   `ALTER USER COROUTE IDENTIFIED BY "<new password>";`
   Also rotate the ADMIN password (ADB → More actions → Administrator password) if it leaked.
3. **Right away**, restart VM2, then VM1:
   `sudo systemctl restart coroute-secrets && sudo systemctl restart coroute-gateway`.
   Between the ALTER and the restart, database writes fail. Rides keep going in memory and are written
   after the restart. Do this outside peak riding hours.
4. Check `/api/health/live` returns 200 on both VMs and that a test ride saves. Check that the backup
   jobs run on VM2 (`journalctl -u coroute-gateway | grep '\[backup\]'`).
5. If DB 2 (restore target) shares the password, rotate it too.
6. Optional: purge the old values from git history (`git filter-repo --replace-text`) and force-push.
   This doesn't make the old values safe. Rotation is what closes the leak.

### Own domain instead of DuckDNS
The chosen domain is `coroute.devmonks.space`: follow `docs/DOMAIN_MIGRATION_devmonks.md` (the Caddyfiles, gateway
and app are already prepared for it). The generic steps below stay for reference.

1. Buy a domain (for example `coroute.in`) and host its DNS at a regular provider that has a Caddy
   DNS-01 plugin: OCI DNS (`caddy-dns/oracle`, uses the instance principal) or Cloudflare free DNS-only
   (`caddy-dns/cloudflare`, API token). Add an `A` record for `coroute.in` (and `www`) pointing to the
   **NLB reserved public IP**, TTL 300.
2. Build Caddy with the new DNS plugin (`deploy/setup_node.sh` installs the DuckDNS build today). In
   `gateway/deploy/caddy/Caddyfile.vm1` and `Caddyfile.vm2`: change `default_sni`, the site address
   (`coroute.in, coroute.duckdns.org`) and the `dns` line (for example `dns cloudflare
   {env.CF_API_TOKEN}`). Put the token in Vault (`coroute-CF_API_TOKEN`) in place of `DUCKDNS_TOKEN`.
   Keep the DuckDNS name in the site list during the transition, so app builds that have the old
   address built in keep working.
3. Get the certificates one VM at a time (VM2 first, wait for "certificate obtained", then VM1), as
   with DuckDNS.
4. In `/etc/coroute/gateway.env` on both VMs: `PUBLIC_ORIGIN=https://coroute.in`, and the CORS origins
   if set. Restart VM2, then VM1.
5. In the app, change `AppConfig.defaultApiBaseUrl` (`lib/core/config/app_config.dart`) and the
   invite-link host in `android/app/src/main/AndroidManifest.xml` (both hosts, so old links still
   open). Serve `/.well-known/assetlinks.json` on the new host. Ship the release. Older builds keep
   using the DuckDNS name until the minimum build is raised.
6. After most riders are on the new build (watch app builds in the admin console), raise the minimum
   build. Then remove the DuckDNS name from Caddy, delete the DuckDNS updater and token, and remove
   `duckdns` from the NSG egress note.
