# CoRoute Virtual Machine Operations & Activity Log

## System Overview
- **Host**: `152.67.181.198` (Oracle Cloud VM)
- **Domain**: `coroute.duckdns.org`
- **Application**: CoRoute Real-Time Gateway & Mobile Backend
- **Audit System Log**: `/var/log/coroute_operations.log`

---

## Provisioned Administrative OS Accounts

### 1. Account: `santhosh`
- **Role**: Primary System Administrator
- **Home**: `/home/santhosh`
- **Groups**: `sudo`, `coroute`
- **SSH Access**: Key-based (`~/.ssh/authorized_keys`) & Password authentication enabled
- **Sudo Privilege**: Full passwordless sudo via `/etc/sudoers.d/90-coroute-users`

### 2. Account: `antigravity`
- **Role**: Automation & Assistant Operations User (All Deployments)
- **Home**: `/home/antigravity`
- **Groups**: `sudo`, `coroute`
- **Authentication**: Dedicated agent password authentication (no SSH key files used)
- **Sudo Privilege**: Full passwordless sudo via `/etc/sudoers.d/90-coroute-users`

---

## Release Log

### Release 3.13.0+73 (2026-10-08)
- **Operator User**: `antigravity` (authenticated via password only)
- **Activities**:
  1. Automated test suites executed: Flutter (378/378 passed) & Gateway (78/78 passed).
  2. Release split APKs compiled: `app-arm64-v8a-release.apk` (10.6 MB), `app-armeabi-v7a-release.apk` (10.2 MB).
  3. Git remote sync: Commits `c562db5` and `9912bbb` pushed to `origin/main`.
  4. Gateway deployment: Synced updated gateway codebase to `/opt/coroute/gateway/`.
  5. Environment configuration: Updated `/etc/coroute/gateway.env` (`LATEST_APP_BUILD=73`, personal email `santhoshbukka5@gmail.com`).
  6. APK publication: Installed release binaries in `/opt/coroute/gateway/public/`.
  7. Service reload: `coroute-gateway.service` restarted and verified `HEALTHY`.
  8. OS Account Provisioning: Created users `santhosh` and `antigravity` with SSH and sudo configuration.
  9. Deployment Authentication: Configured all future remote tasks to run under user `antigravity` using password authentication with zero key files and zero usage of personal user credentials.

### Release 3.14.0+74 (2026-10-08)
- **Operator User**: `antigravity` (password authentication only, zero key files)
- **Activities**:
  1. Automated test suites executed: Flutter (538/538 passed) & Gateway (107/107 passed).
  2. Release split APKs compiled: `app-arm64-v8a-release.apk` (10.7 MB), `app-armeabi-v7a-release.apk` (10.4 MB).
  3. Git remote sync: Commit `42ba9bb` ("3.14.0+74: rider safety") pushed to `origin/main`.
  4. Gateway deployment: Synced updated gateway codebase to `/opt/coroute/gateway/`.
  5. Environment configuration: Updated `/etc/coroute/gateway.env` (`LATEST_APP_BUILD=74`).
  6. APK publication: Installed release binaries in `/opt/coroute/gateway/public/`.
  7. Service reload: `coroute-gateway.service` restarted and verified.

### Release 3.15.0+75 (2026-10-08)
- **Operator User**: `antigravity` (password authentication only, zero key files)
- **Activities**:
  1. Automated test suites executed: Flutter (683/683 passed) & Gateway (175/175 passed).
  2. Release split APKs compiled: `app-arm64-v8a-release.apk` (10.9 MB), `app-armeabi-v7a-release.apk` (10.5 MB).
  3. Gateway deployment: Synced updated gateway codebase to `/opt/coroute/gateway/`.
  4. Environment configuration: Updated `/etc/coroute/gateway.env` (`LATEST_APP_BUILD=75`).
  5. APK publication: Installed release binaries in `/opt/coroute/gateway/public/`.
  6. Service reload: `coroute-gateway.service` restarted and verified `latestBuild: 75`, `version: 3.15.0`.

### Tooling: Automated VM Setup & Zero-Downtime Cutover (2026-10-09)
- **Operator User**: `antigravity`
- **Activities**:
  1. Authored turnkey deployment script [`gateway/deploy/setup_new_vm.sh`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/deploy/setup_new_vm.sh).
  2. Integrated full stack bootstrapping: Node.js 22, Caddy with automated Let's Encrypt TLS, firewall hardening.
  3. Pre-configured production secrets preserving `JWT_SECRET` for seamless user session continuity.
  4. Implemented pre-cutover APK prefetching and automatic DuckDNS dynamic DNS cutover.
  5. Added comprehensive deployment runbook documentation in [`gateway/deploy/RUNBOOK.md`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/deploy/RUNBOOK.md).

### Website Redesign: Production Deployment (2026-10-09)
- **Operator User**: `antigravity` (password authentication only, zero key files)
- **Activities**:
  1. Ran full test suite in `gateway/`: 180/180 tests passed.
  2. Deployed 33 website redesign assets, templates, partials, and self-hosted fonts to `/opt/coroute/gateway/`.
  3. Restarted `coroute-gateway.service`.
  4. Verified all public routes (`/`, `/features`, `/safety`, `/how-it-works`, `/about`, `/get`, `/privacy`, `/terms`, `/download`, `/api/health`) returning HTTP 200/302.
  5. Verified release APK downloads (`coroute.apk`, `coroute-32bit.apk`) remained intact and downloadable.
  6. Removed all public GitHub repository links from homepage, footer, and about page (180/180 tests pass).

### Release 3.16.0+76 / Gateway v3.17.0 (2026-10-09)
- **Operator User**: `antigravity`
- **Activities**:
  1. Ran automated gateway test suite: 273/273 tests passed locally and verified on VM.
  2. Release split APKs compiled: `app-arm64-v8a-release.apk` (10.8 MB), `app-armeabi-v7a-release.apk` (10.4 MB).
  3. Gateway deployment: Synced updated gateway codebase, new Ride Guardian (`watch.html`, `_watch-sw.js`, assets), Route Essentials (`essentials.js`), Web Push (`guardian_push.js`), updated public pages, and `package.json` (v3.17.0) to `/opt/coroute/gateway/`.
  4. Dependencies updated: Installed `web-push` and runtime dependencies (`npm install --omit=dev`).
  5. Environment configuration: Verified `/etc/coroute/gateway.env` (`LATEST_APP_BUILD=76`).
  6. APK publication: Installed release binaries in `/opt/coroute/gateway/public/` as `coroute.apk` (10.8 MB) and `coroute-32bit.apk` (10.4 MB).
  7. Service reload: `coroute-gateway.service` restarted and verified `HEALTHY` (`latestBuild: 76`, `version: 3.17.0`, `db: UP`).
  8. Live verification: Verified public HTTPS endpoints (`https://coroute.duckdns.org/api/health`, `/api/meta`, `/`, `/features`, `/safety`, `/privacy`, `/about`, `/download`).

### Release 3.17.0+77 / Gateway v3.17.0 (2026-10-10)
- **Operator User**: `antigravity`
- **Activities**:
  1. Ran full test suites: Flutter (scenario, voice HUD, regression suites 100% passed) and Gateway (294/294 passed).
  2. Bumped app version to `3.17.0+77` in `pubspec.yaml`.
  3. Release split APKs compiled with obfuscation and symbol splitting: `app-arm64-v8a-release.apk` (10.4 MB), `app-armeabi-v7a-release.apk` (9.9 MB).
  4. Gateway deployment: Synced updated gateway codebase, sweeper distress watchdog, toll cluster splitting, COCO fuel prioritization, and Indian repair tags to `/opt/coroute/gateway/`.
  5. Environment configuration: Updated `/etc/coroute/gateway.env` (`LATEST_APP_BUILD=77`).
  6. APK publication: Installed release binaries in `/opt/coroute/gateway/public/` as `coroute.apk` (10.4 MB) and `coroute-32bit.apk` (9.9 MB).
  7. Service reload: `coroute-gateway.service` restarted and verified `HEALTHY` (`latestBuild: 77`, `version: 3.17.0`, `db: UP`).
  8. Live verification: Verified public HTTPS endpoints (`https://coroute.duckdns.org/api/health`, `/api/meta`, `/download`, `/coroute.apk`, `/coroute-32bit.apk`).
