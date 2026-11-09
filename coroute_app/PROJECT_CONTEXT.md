# CoRoute — Project Context

Free, non-profit group-ride companion (Flutter) with a Node.js gateway and Oracle Autonomous DB.
UI follows the CoRoute design canvas; tokens in `core/theme`, primitives in `core/ui/design_kit.dart`.
Full architecture, audit and rollout plan: [PRODUCTION_PLAN.md](PRODUCTION_PLAN.md). Server deployment: [gateway/deploy/RUNBOOK.md](gateway/deploy/RUNBOOK.md).

## Current state: v3.55 (Nov 10, 2026)
Deployed to production (VM2 then VM1). Tests passing (Flutter 2,142/2,146; Gateway 918/918).
Release artifacts built: APK and AppBundle (build 10019).
Domain migrated to `https://coroute.devmonks.space` with `https://coroute.duckdns.org` redirecting website and maintaining backward compatibility for API, sockets, and live tracking.
Read first:
- [docs/V3_55_RELEASE.md](docs/V3_55_RELEASE.md): every 3.55 request, how it was done, compatibility, release steps.
- [docs/FEATURE_STATUS.md](docs/FEATURE_STATUS.md): all features with status (stable / needs device check / pending) and admin switch ids.
- [docs/SAFETY_SCENARIO_REVIEW_v3.55.md](docs/SAFETY_SCENARIO_REVIEW_v3.55.md): real-time safety scenarios, defects fixed, open risks.
- [docs/UX_NAMING_GUIDE_v3.55.md](docs/UX_NAMING_GUIDE_v3.55.md): one name per concept on every screen.

Key 3.55 concepts: riding roles Lead/Middle/Sweeper (+ automatic roles) separate from the trip owner's rights; admin
Feature switches (`gateway/src/feature_flags.js`, safety ids locked on); plans assigned by admins are real memberships
(`gateway/src/admin_plans.js`); guest mode removed; road reports and place reviews (`gateway/src/road_and_places.js`);
no sample data anywhere (website numbers come from `/api/public/alltime-stats` and `/api/public/leaderboard`).

## Quick reference
- **App package**: `space.devmonks.coroute_app`
- **Version**: `3.55.0+10019` in pubspec
- **Backend**: `gateway/` (Node 22, Express + ws) on two OCI VMs behind OCI Network Load Balancer and Caddy (TLS).
- **Database**: Oracle Autonomous DB (Always Free) via ORDS SODA, **only from the gateway**, using the dedicated `COROUTE` schema (never ADMIN).
- **API default URL**: `https://coroute.devmonks.space` with automatic fallback to `https://coroute.duckdns.org`.
- **Admin accounts**: stored in the `users` collection (`role = MASTER_ADMIN`); first admin seeded by `BOOTSTRAP_ADMIN_EMAILS` on the server, then managed via `PATCH /api/admin/users/:id/role`.
- **Secrets**: none in this repository. Server secrets live in OCI Vault and `/etc/coroute/*.env`; Android signing in `android/key.properties` (git-ignored).

## Commands
```bash
# app
flutter pub get && flutter analyze && flutter test
flutter build apk --release --dart-define=COROUTE_API=https://coroute.duckdns.org

# gateway
cd gateway && npm ci && npm test
ORACLE_SODA_URL=memory ORACLE_USER=x ORACLE_PASSWORD=x JWT_SECRET=$(openssl rand -base64 48) npm start   # local, no DB
```
