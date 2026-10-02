# CoRoute — Project Context

Free, non-profit group-ride companion (Flutter) with a Node.js gateway and Oracle Autonomous DB.
Full architecture, audit and rollout plan: [PRODUCTION_PLAN.md](PRODUCTION_PLAN.md). Server deployment: [gateway/deploy/RUNBOOK.md](gateway/deploy/RUNBOOK.md).

## Quick reference
- **App package**: `space.devmonks.coroute_app`
- **Version**: `3.0.0+60`
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
