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

### Release 3.18.0+78 / Gateway v3.18.0 (2026-10-12)
- **Operator User**: `antigravity`
- **Activities**:
  1. Ran full automated test suites: Flutter (1,019/1,019 passed) and Gateway (314/314 passed). Static analysis `flutter analyze` 0 issues.
  2. Bumped app version to `3.18.0+78` in `pubspec.yaml` and gateway version to `3.18.0` in `package.json`.
  3. Integrated glove-friendly Cockpit Shortcuts Dock suite, high-speed haptic tactile controls, and quick settings modal.
  4. Resolved deep security audit findings:
     - Enforced system-only CA trust and prohibited cleartext traffic via `network_security_config.xml`.
     - Hardened Gateway HTTP headers with Content-Security-Policy, Permissions-Policy, X-Frame-Options DENY, and nosniff.
     - Enforced emergency monotonicity and persistent alert existence validation in `resolveSos`.
  5. Compiled production split APKs with R8 code shrinking and ABI splitting:
     - `app-arm64-v8a-release.apk` (11.1 MB)
     - `app-armeabi-v7a-release.apk` (10.8 MB)
  6. APK publication: Installed release binaries in `gateway/public/` as `coroute.apk` (11.1 MB) and `coroute-32bit.apk` (10.8 MB).
  7. Gateway & Website update: Built-in website dynamically serves version `3.18` with origin-aware canonical metadata and live APK download endpoints.

### Release 3.19.0+79 / Gateway v3.19.0 (2026-10-12)
- **Operator User**: `antigravity` (password authentication only, zero key files)
- **Activities**:
  1. Ran full automated test suites: Flutter (1,025/1,025 passed, 100%) and Gateway (314/314 passed, 100%). Static analysis `flutter analyze` 0 issues.
  2. Bumped app version to `3.19.0+79` in `pubspec.yaml` and gateway version to `3.19.0` in `gateway/package.json`.
  3. UI/UX decluttering & feature implementation:
     - Decluttered live cockpit: Floating center dock removed; repositioned horizontally atop collapsed sheet alongside 56dp Glove SOS button and Recenter button.
     - 7-button Glove Shortcuts Dock: Added dedicated Ride Guardian share link (`LINK`) and live Fuel usable range (`185k`) buttons with full backwards compatibility.
     - Glove Quick Settings Modal: Added top in-flight primary action cards for Guardian Link and Fuel/Range.
     - Group Settings Sheet: Redesigned into structured cards with top Ride Guardian card and compliant ListTile hierarchy.
     - Quick Stop Reason Picker: 4 oversized glove buttons with clean SVG vector icons and ZERO raw emojis.
  4. Compiled production split APKs with R8 shrinking and ABI splitting:
     - `app-arm64-v8a-release.apk` (11.1 MB)
     - `app-armeabi-v7a-release.apk` (10.8 MB)
  5. APK publication: Installed release binaries in `/opt/coroute/gateway/public/` as `coroute.apk` (11.1 MB) and `coroute-32bit.apk` (10.8 MB).
  6. Environment configuration: Updated `/etc/coroute/gateway.env` (`LATEST_APP_BUILD=79`).
  7. Service reload: `coroute-gateway.service` restarted and verified `HEALTHY` (`latestBuild: 79`, `version: 3.19.0`, `db: UP`).
  8. Live verification: Public HTTPS endpoints verified (`https://coroute.duckdns.org/api/health`, `/api/meta`, `/download`, `/coroute.apk`, `/coroute-32bit.apk`).

### Release 3.20.0+80 / Gateway v3.20.0 (2026-10-12)
- **Operator User**: `antigravity`
- **Activities**:
  1. Ran full automated test suites:
     - Flutter: 1,026/1,026 tests passed (100%), `flutter analyze` 0 issues.
     - Gateway: 314/314 tests passed (100%).
  2. Bumped app version to `3.20.0+80` in `coroute_app/pubspec.yaml` and gateway version to `3.20.0` in `gateway/package.json`.
  3. Feature Implementations:
     - **In-Cockpit Popups Only**: Eliminated all jarring full-screen route deviations; all overlays (Orbit HUD, Quick Settings, Guardian, Fuel Radar, Group Settings, Stop Picker) now render directly over the live map canvas.
     - **Draggable CoRoute Orbit Control FAB**: 52dp thumb-accessible floating button with smooth inertial drag, magnetic screen-edge snapping, glowing amber orbit rings, and 6-tile Quick Access popup HUD.
     - **Live Speed Badging**: Real-time speeds displayed directly on all convoy rider markers on the map (`SB • 72 KM/H`, `VP • 68 KM/H`, etc.) with high-contrast pills.
     - **Figma Design System & Interactive Plugin**: 14 pixel-perfect In-Cockpit Popup artboards generated across Dark & Light modes with native prototyping reactions via compiled Figma plugin.
  4. Compiled production split APKs with R8 code shrinking and ABI splitting:
     - `app-arm64-v8a-release.apk` (11.1 MB, SHA-256: `EF99DF34D76CA017E0913933429F424C9418637E293B1ECF1C94FFFB708D4BC9`)
     - `app-armeabi-v7a-release.apk` (10.8 MB, SHA-256: `79B6B081879697F317F4181256969A50B1AA17D3DF7F06F0BBDD35D9F3640E95`)
  5. APK Publication & Deployment:
     - Published to `/opt/coroute/gateway/public/coroute.apk` and `/opt/coroute/gateway/public/coroute-32bit.apk`.
     - Synchronized gateway configuration (`src/config.js` and `package.json`).
  6. Environment Configuration:
     - Updated `/etc/coroute/gateway.env` with `LATEST_APP_BUILD=80`.
  7. Service Reload & Health Verification:
     - Restarted `coroute-gateway.service`.
     - Verified live health via HTTPS: `version: 3.20.0`, `latestBuild: 80`, `status: HEALTHY`, `db: UP`.
     - Verified APK download headers (`HTTP 200 OK`, `application/vnd.android.package-archive`).
  8. Audited system logs: Appended operation to `/var/log/coroute_operations.log` and user activity logs.

