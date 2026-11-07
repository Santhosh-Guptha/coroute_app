# CoRoute — Project Context

Free, non-profit group-ride companion (Flutter) with a Node.js gateway and Oracle Autonomous DB.
UI follows the CoRoute design canvas; tokens in `core/theme`, primitives in `core/ui/design_kit.dart`.
Full architecture, audit and rollout plan: [PRODUCTION_PLAN.md](PRODUCTION_PLAN.md). Server deployment: [gateway/deploy/RUNBOOK.md](gateway/deploy/RUNBOOK.md).

## Current state: v3.55 (Nov 7, 2026)
Code-complete on top of 3.54.0+10018, not yet built with Flutter, run on phones or deployed. Read first:
- [docs/V3_55_RELEASE.md](docs/V3_55_RELEASE.md): every 3.55 request, how it was done, compatibility, release steps.
- [docs/FEATURE_STATUS.md](docs/FEATURE_STATUS.md): all features with status (stable / needs device check / pending) and admin switch ids.
- [docs/SAFETY_SCENARIO_REVIEW_v3.55.md](docs/SAFETY_SCENARIO_REVIEW_v3.55.md): real-time safety scenarios, defects fixed, open risks.
- [docs/UX_NAMING_GUIDE_v3.55.md](docs/UX_NAMING_GUIDE_v3.55.md): one name per concept on every screen.

Key 3.55 concepts: riding roles Lead/Middle/Sweeper (+ automatic roles) separate from the trip owner's rights; admin
Feature switches (`gateway/src/feature_flags.js`, safety ids locked on); plans assigned by admins are real memberships
(`gateway/src/admin_plans.js`); guest mode removed; road reports and place reviews (`gateway/src/road_and_places.js`);
no sample data anywhere (website numbers come from `/api/public/usage-stats` and `/api/public/impact-stats`).

Analyzer without a local Flutter engine: a Dart SDK of the same version plus the project's pub cache and Flutter
`packages/` sources in `.dart_tool/package_config.json` is enough for `dart analyze lib test` (that is how 3.55 was checked).

## Quick reference
- **App package**: `space.devmonks.coroute_app`
- **Version**: `3.54.0+10018` in pubspec (bump to 3.55.0 at release)
- **Backend**: `gateway/` (Node 22, Express + ws) on the OCI Always Free VM, behind Caddy (TLS).
- **Database**: Oracle Autonomous DB (Always Free) via ORDS SODA, **only from the gateway**, using the dedicated `COROUTE` schema (never ADMIN).
- **API base URL**: build-time `--dart-define=COROUTE_API=https://coroute.duckdns.org` (default in `lib/core/config/app_config.dart`).
- **Admin accounts**: stored in the `users` collection (`role = MASTER_ADMIN`); first admin seeded by `BOOTSTRAP_ADMIN_EMAILS` on the server, then managed via `PATCH /api/admin/users/:id/role`.
- **Secrets**: none in this repository. Server secrets live in `/etc/coroute/gateway.env`; Android signing in `android/key.properties` (git-ignored).

## Commands
```bash
# app
flutter pub get && flutter analyze && flutter test
flutter build apk --release --dart-define=COROUTE_API=https://coroute.duckdns.org

# gateway
cd gateway && npm ci && npm test
ORACLE_SODA_URL=memory ORACLE_USER=x ORACLE_PASSWORD=x JWT_SECRET=$(openssl rand -base64 48) npm start   # local, no DB
```
