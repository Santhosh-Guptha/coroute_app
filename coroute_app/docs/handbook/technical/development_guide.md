# CoRoute development guide

For engineers and coding agents working in this repository. Written 11 Nov 2026.

## 1. Repository layout

| Path | What |
|---|---|
| `lib/` | Flutter app (see [mobile_app.md](mobile_app.md)) |
| `android/app/` | Kotlin platform code, manifest, Gradle (`build.gradle.kts`) |
| `test/` | Dart tests (238 `*_test.dart` files, about 2,176 `test`/`testWidgets` cases) |
| `gateway/src/` | Node.js gateway (see [architecture.md](architecture.md)) |
| `gateway/public/` | Website, `/admin` web admin, `/operator` console, live and guardian pages |
| `gateway/test/` | Gateway tests (152 `*.test.js` files, **1,091 tests**) plus helpers (`_helpers.js`, `_net_helpers.js`, `_par_server.js`) |
| `gateway/deploy/` | Caddyfiles, systemd units, setup and hardening scripts, runbooks |
| `gateway/scripts/` | `init_db.js`, `backup_restore.js`, `load_convoy_ws.js` ... |
| `tool/` | `play_policy_scan.dart`, `web_admin_smoke.js`, `operators_smoke.js`, `diag/analyze_logs.js`, `map_bikes/` (bike marker renders), `design_contrast.py` |
| `docs/` | Release notes, feature docs (`features_355/`), runbooks, testing docs, manuals, this handbook |
| `store/`, `release/` | Play listing assets, release artifacts per version |
| `design/` | Design canvas material |

Never commit: `CLUSTER_CREDENTIALS.md`, `.env` files, `android/key.properties`, keystores, the FCM
service-account JSON, SMTP / SMS / Razorpay keys. `.gitignore` covers the known ones; check
`git status` before every commit.

## 2. Setup

### 2.1 App

```bash
# Flutter 3.47.1 (Dart 3.13.1)
flutter pub get
flutter analyze
flutter test
# debug run against a local gateway (debug builds may use plain HTTP on a LAN)
flutter run --dart-define=COROUTE_API=http://192.168.1.10:3000
```

Release builds must **not** pass `COROUTE_API` (it disables the DuckDNS fallback):

```bash
flutter build appbundle --release \
  -PCOROUTE_FCM_APP_ID=... -PCOROUTE_FCM_API_KEY=... -PCOROUTE_FCM_PROJECT_ID=... -PCOROUTE_FCM_SENDER_ID=...
flutter build apk --release --split-per-abi      # website download APKs
```

(Firebase values are given by the owner as Gradle properties or CI secrets, never committed.
Without them the build works and push is off.)

### 2.2 Gateway

```bash
cd gateway
npm ci
npm test                                   # node --test test/*.test.js (about 3 minutes)
# local server without a database (in-memory SODA):
ORACLE_SODA_URL=memory ORACLE_USER=x ORACLE_PASSWORD=x \
JWT_SECRET=$(openssl rand -base64 48) npm start
```

Node 22 in production (`engines: >=20`). Dependencies: express, ws, helmet, cors,
express-rate-limit, jsonwebtoken, bcryptjs (legacy hashes), google-auth-library, nodemailer
10.2.1, razorpay, web-push, dotenv. Dev: puppeteer (website/admin smoke tests).

## 3. Tests

| Suite | Command | Count (11 Nov 2026) | Notes |
|---|---|---|---|
| Gateway | `cd gateway && npm test` | **1,091 / 1,091 pass** (run for this handbook, 174 s) | Known timing-sensitive: `public_ride_mirror`, `two_node_failover` hand-back, `job_lease` real timers, login performance. Re-run alone; they must pass alone. |
| Dart / Flutter | `flutter test` | ~2,176 cases in 238 files; last recorded full run 2,142 / 2,146 (PROJECT_CONTEXT, Nov 10) | The 4 `ui_audit` path_provider tests need a device. Pure-logic tests also run with plain `dart test` where they import no Flutter. |
| Analyzer | `flutter analyze` (or `dart analyze lib test`) | No issues expected | |
| Play policy | `dart run tool/play_policy_scan.dart` | **0 hits** (verified 11 Nov 2026) | Release gate |
| Web admin smoke | `node tool/web_admin_smoke.js` | | Puppeteer against a local gateway |
| Operators smoke | `node tool/operators_smoke.js` | | |
| Live convoy soak | `node test/integration/live_convoy_verifier.js` | | 30-minute soak with simulated riders (sets `LIVE_RIDER_CAP`) |
| Load | `node gateway/scripts/load_convoy_ws.js` | | Against a staging copy only |

Test inventory by area: [qa_test_plan.md](qa_test_plan.md).

Rules:

- Fix code, not tests, unless a test asserts text that was changed on purpose (then follow the
  [UX naming guide](../../UX_NAMING_GUIDE_v3.55.md)).
- New gateway behaviour gets a `gateway/test/<feature>_<version>.test.js` suite; new app decisions
  get a pure `domain/` function with a `test/<feature>_test.dart`.
- Safety invariants must keep tests: [docs/testing/safety_invariants.md](../../testing/safety_invariants.md).

## 4. Coding conventions

### 4.1 General

- Safety first: nothing may stop SOS, crash detection, emergency texts or the lock-screen Medical
  ID. These are locked switches and fixed settings; never add a code path that gates them on a
  plan, the access mode, a feature switch or a setting.
- Backward compatibility: old apps must keep working. New behaviour goes behind new REST endpoints,
  new socket types, new optional fields or a new **HELLO feature** the app checks before using.
  Never raise `MIN_APP_BUILD` casually.
- Privacy by design: no personal data in logs (log method, route template, request id, first error
  line only); round coordinates in anything public; never send another rider's userId, phone,
  e-mail or medical info in pushes or personal socket messages.
- No sample or mock data in production pages or screens.
- Play policy: the app contains no prices, payments, coupons or buying words (see
  [../compliance/play_store_compliance.md](../compliance/play_store_compliance.md)).

### 4.2 Gateway

- `'use strict'`, CommonJS, one module per area; route registration functions take
  `{r, repo, wrap, requireAdmin, flagsOf}`.
- Validate input in the gateway (`validate.js`), never trust the client; return `{error, code}`.
- Every admin write is audited (`addAudit`, `subscription_config k='audit'` or `safety_audit`).
- Scheduled work goes through `lease.run(name, everyMs, fn, {prefer})`; never a bare `setInterval`
  that writes data.
- Database access only through `oracle/repo.js` or a module's own collection helper; use
  compare-and-replace for anything two nodes can race on.
- Add each new route to `gateway/deploy/route_split.md` (LIVE if it touches rooms, sockets, live
  links or the hub) and run `node deploy/gen_caddy_routes.js --check`.

### 4.3 App

- `domain/` is pure Dart; `data/services/` adapts; `presentation/` renders.
- Use design-kit primitives (`Ds*`) and tokens from `app_palette.dart`; no hard-coded colours.
- Text: sentence case, one name per concept ([glossary.md](glossary.md)); spoken text in
  `L10n` (English, Hindi, Telugu).
- Settings: new safety behaviour is a fixed default (add to `SettingsService.alwaysOnKeys` and bump
  `safetyDefaultsVersion`); rider choices are only for comfort and privacy.
- Taps while moving: non-safety cards show as a voice line + chip while moving and a full card
  when stopped (`domain/ride/ride_tap_gate.dart`).

### 4.4 Web pages

- No inline scripts on shop, admin and operator pages (strict CSP); insert server text with
  `textContent`, never `innerHTML`.
- Tokens in `sessionStorage`, sent as Bearer; never in a URL or cookie.

## 5. How to add a feature switch

1. **Gateway catalog**: add an entry in `gateway/src/feature_flags.js` `CATALOG`:
   `f('myFeature', '<Safety|Riding|Group|Places|Community|Platform>', 'Label', 'One-line description')`.
   Default on; never `locked` unless it is core safety (only `sos`, `crashDetection`,
   `emergencySms`, `medicalId` are locked).
2. **Enforce on the server** where the server is involved: REST guard (`registerFeatureFlagPublicGuards`
   or a check in the route returning 403 `FEATURE_OFF`) and/or socket guard (`wsFeaturesFor` /
   `firstOff` in `ws.js`). Never block a live safety path.
3. **App**: gate UI and behaviour with `featureOn('myFeature')` / `featureOnNow` from
   `lib/presentation/widgets/feature_switch.dart` (unknown = on). Hide related setting rows when off,
   and still check at use time in the service.
4. **Free tier (optional)**: if a "free up to limits" ride may leave it out, add the id to the
   gateable list in `access_mode.js` (never a safety feature).
5. **Tests**: extend `gateway/test/feature_flags_355.test.js` (catalog, enforcement) and add an app
   test for the hidden row / disabled behaviour.
6. **Docs**: add the switch id to the feature doc and to [docs/FEATURE_STATUS.md](../../FEATURE_STATUS.md);
   the admin console lists it automatically (Admin > Feature switches).
7. After deploy, open Admin > Feature switches once to confirm the store has the new id.

## 6. Release versioning

- App version in `pubspec.yaml` `version: x.y.z+N`. `N` is the Android versionCode and must be the
  **next unused build number** across Play Console and the website APKs (currently `3.55.0+10022`
  in the tree; MASTER_AGENT_PROMPT plans `+10023` for the Play upload).
- Gateway version in `gateway/package.json` (`3.55.0`); `LATEST_APP_BUILD` (default 10019 in
  `config.js`, set the env to the released build) tells apps an update exists; `MIN_APP_BUILD`
  (default 60) forces updates. **Never raise `MIN_APP_BUILD` in this release.**
- Website APKs: `gateway/public/coroute*.apk` with `gateway/public/SHA256SUMS.txt` updated on every
  publish.
- Release notes: `docs/V<version>_RELEASE.md`; status: `docs/FEATURE_STATUS.md`; next plan:
  `docs/NEXT_RELEASE_PLAN_v3.56.md`.
- Deploy order: gateway first (VM2 then VM1), then the app.
- Commit prefixes used so far: `feat(v3.55):`, `docs(v3.55):`, `fix(...)`. Agents never commit
  unless the owner asks.

## 7. Where to read first

[PROJECT_CONTEXT.md](../../../PROJECT_CONTEXT.md) → [docs/V3_55_RELEASE.md](../../V3_55_RELEASE.md) →
[docs/FEATURE_STATUS.md](../../FEATURE_STATUS.md) → [docs/MASTER_AGENT_PROMPT_v3.55.md](../../MASTER_AGENT_PROMPT_v3.55.md) →
the feature doc in `docs/features_355/` for the area you touch.
