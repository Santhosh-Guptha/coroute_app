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
- **Role**: Automation & Assistant Operations User
- **Home**: `/home/antigravity`
- **Groups**: `sudo`, `coroute`
- **SSH Access**: Key-based (`~/.ssh/authorized_keys`) & Password authentication enabled
- **Sudo Privilege**: Full passwordless sudo via `/etc/sudoers.d/90-coroute-users`

---

## Release Log

### Release 3.13.0+73 (2026-10-08)
- **Operator User**: `antigravity`
- **Activities**:
  1. Automated test suites executed: Flutter (378/378 passed) & Gateway (78/78 passed).
  2. Release split APKs compiled: `app-arm64-v8a-release.apk` (10.6 MB), `app-armeabi-v7a-release.apk` (10.2 MB).
  3. Git remote sync: Commits `c562db5` and `9912bbb` pushed to `origin/main`.
  4. Gateway deployment: Synced updated gateway codebase to `/opt/coroute/gateway/`.
  5. Environment configuration: Updated `/etc/coroute/gateway.env` (`LATEST_APP_BUILD=73`, personal email `santhoshbukka5@gmail.com`).
  6. APK publication: Installed release binaries in `/opt/coroute/gateway/public/`.
  7. Service reload: `coroute-gateway.service` restarted and verified `HEALTHY`.
  8. OS Account Provisioning: Created users `santhosh` and `antigravity` with SSH and sudo configuration.
