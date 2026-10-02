# CoRoute — Production Readiness Plan (v3.0)

CoRoute is a free, non-profit group-ride companion: live convoy map, rider
telemetry, SOS, quick-status cards, planned stops and a voice intercom.
This document records what was wrong in v2, what v3 changes, how it is deployed
at zero running cost, and what remains before store release.

---

## 1. Audit of v2 (what was blocking production)

### Intercom was slow (3–8 s) and got slower over time
* Each voice clip was recorded to an `.m4a` file, base64-encoded (+33 %), POSTed to the Oracle SODA REST API, **and** written to Firebase.
* Every other rider **polled** Oracle every 1.2 s with a full QBE query on a collection that was never pruned, then downloaded the base64 audio.
* Two screens each created their own recorder/player and subscribed separately, so audio could play twice.

### Data and audio leaked between groups
* The Firebase `voiceBursts` listener was only cancelled on *leave*, never when switching groups.
* The gateway WebSocket trusted whatever `convoyId` a client sent — no membership check.
* The admin fleet listener merged **every** group's riders/messages into memory on **every** device.
* The Oracle sync did a whole-document PUT of the entire convoy every 3 s from every rider → last-writer-wins; riders overwrote each other's positions, alerts and messages.

### Security
* Oracle **ADMIN** credentials were hard-coded in the APK (`Basic QURNSU46…`) → anyone could read/write/drop the whole database.
* Firebase rules were `.read: true, .write: true`.
* Passwords were stored in **plaintext** in SharedPreferences; "login" was a local lookup, so accounts did not exist across devices.
* The admin was decided by a hard-coded e-mail in the app; a release-keystore password was committed in `build.gradle.kts`.

### Battery / performance
* GPS stream at `distanceFilter: 3 m` with high accuracy, forever, even when parked.
* Compass listener called `setState` on every magnetometer sample → full map rebuild ~50×/s.
* Three network paths (Firebase RTDB, Oracle polling, WebSocket) active at once.

---

## 2. v3 architecture

```
┌───────────── Flutter app ─────────────┐        ┌────────── OCI Always Free VM ───────────┐      ┌─ Oracle ADB (Always Free) ─┐
│ ApiClient      (HTTPS /api, JWT)      │──────▶ │ Caddy (TLS, auto-renew)                  │      │ users, convoys,            │
│ RealtimeService(one WSS, auto-rejoin) │◀─────▶ │ gateway: auth · rooms · voice relay      │─────▶│ convoy_riders, messages,   │
│ IntercomService(PCM16 ↔ WS binary)    │        │          write-behind persistence        │ SODA │ alerts, trips, voice_log,  │
│ ConvoyService  (push-updated mirror)  │        │          retention + DB keep-alive       │ REST │ broadcasts                 │
└───────────────────────────────────────┘        └──────────────────────────────────────────┘      └────────────────────────────┘
```

* **Firebase is gone** (packages, Gradle plugin, config files). Oracle is the only database, reached **only** through the gateway.
* **Gateway = single authority.** Rooms live in memory; every mutation is a *per-rider patch* applied server-side; Oracle is written with write-behind (telemetry every 5 s per rider) or immediately (chat, alerts, config, membership).
* **Isolation.** A socket is bound to one room after a membership-checked `JOIN`; all fan-out is room-scoped; a rider can be in only one active convoy (joining another auto-leaves the first); the client additionally drops any event/audio that arrives after it left a room. Covered by automated tests (`gateway/test`, "ISOLATION").
* **Voice.** Microphone → PCM16 16 kHz mono → 40 ms binary frames → gateway → room (or one rider). No files, no base64, no database, no polling. Latency ≈ network RTT + ~100 ms jitter buffer. Floor control for the group channel; private channels are independent. No audio is ever stored (metadata only, purged after 7 days).
* **1:1 talk.** "Talk to" picker in the intercom dock: *Everyone* or a specific rider. The gateway validates the target is online in the same room and relays only to them; the receiver sees "private to you".
* **Accounts.** Registration is mandatory (e-mail + password, bcrypt-hashed, or Google Sign-In verified server-side). The gateway issues a 30-day JWT stored in the platform keystore. **Roles live in the `users` collection**; `BOOTSTRAP_ADMIN_EMAILS` only seeds the first admin, then roles are managed via `PATCH /api/admin/users/:id/role`.
* **Battery.** Adaptive GPS (high accuracy / 8 m while moving → medium / 25 m after 3 min stationary), telemetry pushed at most every 2.5 s or on 40 m movement, 30 s heartbeat when parked, one socket with server-side pings, microphone only open while PTT is held or VOX is armed, compass repaints throttled to 4 Hz. Android runs location as a foreground service so tracking survives screen-off.
* **Retention (zero maintenance).** Accounts, convoy records (name, members, dates, settings) and trip records (name, members, dates, distance/speed stats) are **kept forever**. Only per-rider GPS traces are stripped after 90 days; stale convoys auto-end after 36 h; a keep-alive stops the free ADB from pausing.

---

## 3. What changed in the code

### New (gateway/)
`src/server.js, app.js, config.js, auth.js, convoys.js, ws.js, routes.js, retention.js, oracle/{soda,repo,memory_soda}.js`, `test/gateway.test.js` (8 tests, all passing), `deploy/{RUNBOOK.md, .env.example, coroute-gateway.service, Caddyfile, oracle_setup.sql, smoke_test.sh}`, `scripts/init_db.js`.

### New (app)
`lib/core/config/app_config.dart`, `lib/data/services/{api_client,realtime_service,intercom_service}.dart`, `lib/presentation/widgets/intercom_dock.dart`.

### Rewritten
`lib/data/services/{auth_service,convoy_service,trip_storage_service}.dart`, `lib/main.dart`, `lib/core/constants/app_constants.dart`, `android/app/build.gradle.kts`, `android/settings.gradle.kts`, `android/app/src/main/AndroidManifest.xml`, `pubspec.yaml`, `test/coroute_unit_test.dart`.

### Edited
`convoy_dashboard_screen.dart`, `live_cockpit_map_screen.dart` (recorder/player code removed, shared `IntercomDock`, user identity by `userId`), `rider_home_screen.dart`, `access_gate_screen.dart`, `master_admin_dashboard.dart`, `trip_history_screen.dart`, `splash_screen.dart` (responsive max-width wrappers, server-decided roles, error handling).

### Removed
`lib/data/services/oracle_ai_service.dart`, `firebase.json`, `.firebaserc`, `database.rules.json`, `android/app/google-services.json`, `scratch/` (superseded by `gateway/`), dependencies `firebase_core`, `firebase_database`, `audioplayers`, `path_provider`, `share_plus`.

---

## 4. Rollout checklist

1. **Secrets hygiene (do first)** — rotate the Oracle ADMIN password; create the `COROUTE` schema (`gateway/deploy/oracle_setup.sql`); generate a new release keystore or at least change its password and keep it in `android/key.properties` (git-ignored). Treat the old APK's credentials as compromised.
2. **Deploy the gateway** — `sudo API_HOST=coroute.duckdns.org DUCKDNS_TOKEN=… bash gateway/deploy/install.sh` on the VM (details in `gateway/deploy/RUNBOOK.md`).
3. **Build the app** — `flutter pub get && flutter analyze && flutter test`, then `flutter build apk --release --dart-define=COROUTE_API=https://<your-host>`.
4. **Device test matrix** — two phones in one convoy + a third phone in a second convoy: verify PTT and VOX latency, 1:1 privacy, no cross-group chat/audio, reconnect after airplane-mode toggle, screen-off tracking for 10 min, rotation on every screen.
5. **Store readiness** — privacy policy is served at `https://<host>/privacy`; data-safety answers and the background-location declaration script are in `gateway/deploy/PLAY_STORE_CHECKLIST.md`; still needed: the declaration video, icon and screenshots.
6. **Observability (free)** — UptimeRobot (or similar) on `GET /api/health`; `journalctl -u coroute-gateway` for logs.

---

## 5. Roadmap to "best free riding app" (post-launch, still ₹0)

| Priority | Feature | Notes |
|---|---|---|
| P1 | Opus codec for voice | ~6× less data than PCM16 on mobile networks; needs an FFI Opus package. Protocol already carries `codec`. |
| done | Admin screen for user roles | `admin_users_screen.dart`, reachable from the admin dashboard toolbar. |
| P1 | Offline map tile cache | Cache OSM tiles for the planned route before departure (flutter_map tile provider with disk cache). |
| P2 | Crash detection | Accelerometer spike + stop → auto-SOS countdown. |
| P2 | Bluetooth helmet PTT | Map media-button events to PTT. |
| P2 | Ride replay from trip trails | Already stored for 90 days. |
| P3 | Push notifications when app is killed | Needs FCM/APNs transport (free) — only for notifications, not data. |
| P3 | iOS build | Code is cross-platform; needs Apple developer account (paid) — the one non-free item. |

---

## 6. Verification performed

* `gateway`: `npm test` → 8/8 passing (auth & hashing, DB-managed roles, convoy lifecycle, per-rider persistence without overwrite, **cross-group isolation of chat and audio**, **1:1 voice reaching only the target**, floor control, admin fleet/broadcast/dissolve, retention policy, unauthenticated socket rejection).
* `app`: the Dart sources were rewritten and reviewed; `flutter analyze` / `flutter test` must be run on a machine with the Flutter SDK (the build environment used for this change had no access to pub.dev). Run them before the first device test and fix any analyzer findings.
