# CoRoute security overview

Written 11 Nov 2026 from the code and the security docs ([docs/features_355/web_payments_security.md](../../features_355/web_payments_security.md),
[docs/features_355/web_admin.md](../../features_355/web_admin.md), [docs/features_355/platform.md](../../features_355/platform.md),
[docs/PRODUCTION_TWO_VM_RUNBOOK.md](../../PRODUCTION_TWO_VM_RUNBOOK.md)). Not a penetration test.

## 1. Assets and threat model summary

| Asset | Why it matters | Main threats |
|---|---|---|
| Live positions of riders | physical safety, stalking | cross-group leakage, account takeover, public link abuse |
| SOS / crash pipeline | life safety | denial of service, false alarms, broken deploys, provider outages |
| Medical info, emergency contacts, phone numbers | sensitive personal data | over-exposure to other riders, admins or logs |
| Accounts and tokens | access to all the above | credential stuffing, token theft, XSS |
| Payments and coupons | money | amount tampering, replay, coupon abuse |
| Admin console | full control | stolen admin session, CSRF/XSS, insider misuse |
| Secrets (JWT, DB, Razorpay, SMS, FCM, mirror, backup) | everything | leakage via git, logs, VM compromise |

Actors considered: curious or malicious riders (in or outside a group), anonymous internet users,
bots, a compromised browser extension, an insider admin, a cloud-side attacker with a stolen secret.

Key design answers:

- **Room isolation** (`ws.js`): a socket is authenticated at upgrade and bound to at most one ride
  after a membership-checked `JOIN`; every room action re-checks the binding, so telemetry, chat,
  alerts and audio cannot cross groups. Tests: `cross_group_privacy.test.js`.
- **Minimum disclosure across groups** (`safety_network.js`): riders of other groups get only the
  emergency point and distance until they accept; then first name, vehicle, and medical info /
  emergency contact only while the alert is open. The rider's phone number is never shared.
- **Public surfaces carry no identity**: live links show first name, position, times and Call 112;
  website stats are rounded with floors; leaderboards show usernames only.

## 2. Authentication and sessions

| Control | Detail | Where |
|---|---|---|
| Password hashing | **scrypt** `scrypt$N$r$p$salt$hash`, N = 2^15, r = 8, p = 3 (OWASP scrypt equivalent, about 300 ms, 32 MiB), on the libuv threadpool with bounded concurrency; older hashes (p = 1, legacy bcrypt) re-hashed at next sign-in. 3.57 password rules: 8–200 characters, bundled common / breached list, not the e-mail or callsign | `password_hash.js`, `password_policy.js` |
| Sessions (3.57) | server-side session records (`auth_sessions`: device, platform, created, last seen, keyed IP hash, hashed refresh token); every token carries `sid` and every request / socket message checks it. App ≥ 10025, website and consoles: 15-min access token + rotating refresh token with reuse detection (reuse revokes the whole session, audited); website refresh token in an httpOnly `__Host-` cookie. Older builds: the long sliding token, bound to a session. Idle / absolute: app 30 / 60 days (never ended mid-ride), web 60 min / 7 days, admin and operator 30 min / 12 h. Details: [sessions_and_security.md](../../features_355/sessions_and_security.md) | `sessions.js`, `security_routes.js` |
| Tokens | JWT (HS256) with claims `sub`, `name`, `role`, `email`, `pv` (password version), `sid` (session), `typ: at` (short); a password change invalidates old tokens (`pv`) and revokes the other sessions | `auth.js` |
| Account gate | every request and socket re-checks status/role/password version and the session (cached 30 s, dropped at once on revoke, on the peer node via the mirror); hold/block closes sockets with 4403, a revoked session with 4401 `SIGNED_OUT` | `UserGate`, `ws.js` |
| Sign-out | `/auth/logout` (this session), `/auth/logout-all`, `/me/sessions` list and revoke; hold / block / delete / password change or reset / e-mail change / losing the admin role revoke every session | `security_routes.js` |
| 2-step verification | TOTP + 10 single-use recovery codes; required for `MASTER_ADMIN` at the web admin sign-in (forced enrolment), optional for operators; break-glass `scripts/admin_mfa_reset.js` (runbook) | `totp.js`, `auth.js` |
| Recovery and re-auth | e-mail reset links (single use, 30 min, hash stored, every session ends); re-authentication (password or Google) for deletion, e-mail change and 2-step changes; new-device sign-in e-mails | `auth.js`, `security_routes.js` |
| Rotation | `JWT_SECRET_PREVIOUS` accepted for verification only during a grace period | `config.js`, `app.js` |
| Brute force | sign-in 30 / 15 min per IP and 10 failed / 15 min per account; 3.57 account lock after 10 wrong passwords (15 min, doubling to 24 h, e-mail notice) and a progressive delay; join by code 10 failures per rider / 30 per IP per 15 min; same 401 message and hashing work for unknown accounts | `routes.js`, `auth.js` |
| Google sign-in | ID token verified server-side (signature, audience `GOOGLE_CLIENT_IDS` / `GOOGLE_WEB_CLIENT_ID`, expiry, issuer, verified e-mail; a linked Google id must match) | `auth.js` |
| Guest mode | removed (`/auth/guest` → 410) | `auth.js` |
| Admin roles | `MASTER_ADMIN` in the `users` collection; first admin from `BOOTSTRAP_ADMIN_EMAILS`, then `PATCH /api/admin/users/:id/role` | `routes.js` |
| App storage | access and refresh tokens, phone, emergency contact and e-mail in `flutter_secure_storage` (Android Keystore, moved from SharedPreferences silently); SMS roster encrypted on the phone and deleted at ride end; no Android backup or device transfer | app |

## 3. Transport

- TLS by Caddy on both VMs (ACME DNS-01), HTTP → HTTPS. App release builds accept only `https://`
  gateways and `wss://` sockets.
- HSTS: one year + `includeSubDomains` on `coroute.duckdns.org`; `max-age=300` on
  `coroute.devmonks.space` until the owner raises it to one year (never `includeSubDomains` on
  `devmonks.space`). Helmet also sets HSTS on gateway responses.
- Mirror link between VMs: mutual HMAC challenge + AES-256-GCM per-direction keys with counter
  nonces (replay closes the link); port 3101 only between the two private IPs (NSG).
- Database: SODA over HTTPS; ADB network ACL limited to the two VMs' egress IPs; schema user
  `COROUTE`, never ADMIN.
- SSH: OCI Bastion sessions instead of public SSH (runbook 3.2).

## 4. Web security

| Control | Detail |
|---|---|
| CSP on shop pages (`/signin`, `/plans`, `/account`, `/receipt`, `/checkout`) | `web_shop.shopCsp()`: scripts only from self (plus Razorpay on `/plans` and `/checkout`, Google Identity on `/signin` when configured), no inline script, `frame-ancestors 'none'`, `base-uri 'none'`; no-store; `Referrer-Policy: no-referrer` |
| CSP on `/admin` | `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'none'; form-action 'none'; object-src 'none'` + `X-Frame-Options: DENY`, `X-Robots-Tag: noindex`, no-store; idle sign-out after 30 min |
| CSP on `/operator` | strict (`script-src 'self'`) like the admin |
| `/watch` (guardian) | `default-src 'none'; script-src 'self'`, OSM tiles only |
| Offer e-mail pages, push images, board images | `default-src 'none'` (+ `sandbox` for images) |
| CSP on marketing and legal pages (every `SITE_PAGES` route except the shop pages) | `pages.MARKETING_CSP` (set in `app.js`): `script-src 'self'` (no inline script: the theme line is `/assets/theme-init.js`), `img-src 'self' data: https:` (approved story photos), `connect-src 'self'`, `frame-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'`, `object-src 'none'`. JSON-LD blocks are data and are not executed. Test: `website_legal_356.test.js` |
| Default site CSP (helmet, `app.js`) | 3.57: `script-src 'self'`, `script-src-attr 'none'`, `connect-src 'self'`, `frame-src 'none'` for every response without its own policy (join, live link and 404 pages, static files, API answers). Style attributes still need `'unsafe-inline'`. |
| `/.well-known/security.txt` | RFC 9116, built per request (`app.js` `securityTxt()`): Contact `mailto:` `SECURITY_CONTACT`, else `SUPPORT_EMAIL`, else the `/security` page; Expires one year ahead; Policy `/security` |
| Tokens in browsers | 3.57: the 15-min access token in `sessionStorage` + `Authorization: Bearer`, never in a URL; the refresh token in an httpOnly, Secure, `__Host-` cookie (SameSite=Lax for the site, Strict for `/admin` and `/operator`) used only by `/auth/refresh` and `/auth/logout`, which need the `X-CoRoute-CSRF` header and an allowed Origin. Idle sign-out: site 60 min, consoles 30 min with a warning; sign-out goes to the home page; Back is re-checked (`pageshow`), APIs and private pages are `no-store`. |
| Output encoding | server values inserted with `textContent`, never `innerHTML` (shop, admin, board) |
| CORS | off by default (`origin: false`); `CORS_ORIGINS` adds explicit origins plus the site origins |
| Other headers | `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(self Razorpay)`, `X-Content-Type-Options: nosniff`, `frameguard: deny` |
| Request ids | `X-Request-Id` on every response; logs carry it instead of bodies |
| Body limits | JSON 2 MB; webhooks raw 1 MB; socket frames 256 KiB |
| Logging | 5xx logged as method + route template + request id + first error line; 3.57: every gateway log line passes the redacting logger (tokens, passwords, OTPs, e-mails, phone numbers) (`redact.js`, tested) |
| Route inventory | `route_policy.js` declares every route's policy; a test fails for an undeclared or unenforced route |
| WebSocket | browser Origin must be this site; tokens checked against the session on connect and on every message |

## 5. Mobile app

- Consumption-only: no payment SDK; the Play policy scan enforces it.
- Diagnostics redaction on the phone and again on the server.
- 3.57: `SEND_SMS` only (no READ_SMS / RECEIVE_SMS / READ_PHONE_STATE), asked after a disclosure; emergency texts go from the rider's SIM to their own contacts, max 30 a day; numbers stay in a private prefs file until 48 h after sending; logs keep the last 3 digits at most. Denied: the messages app opens prefilled.
- Release builds refuse non-HTTPS gateway overrides; the `COROUTE_API` value is never logged.
- Exported components: App Links verified by `assetlinks.json`; Share-in activity only parses
  text/links (`geo_links` on the server validates).

## 6. Payments

Full table of 21 threats and tests: [web_payments_security.md](../../features_355/web_payments_security.md). Highlights:

- The amount always comes from `plan_pricing.computeQuote`; Razorpay's order reply must echo it
  (else 502 `GATEWAY_AMOUNT_MISMATCH`).
- `/membership/verify` is bound to the order's rider, **including admins**; receipts are own-orders only.
- Atomic order claim (`claimRazorpayOrder`, compare-and-replace) so verify + two webhooks + two nodes
  activate once; replay of a different payment id → 409 `REPLAY_ATTACK_DETECTED`.
- HMAC-SHA256 with `timingSafeEqual`; webhook HMAC over the raw bytes; payment fetched and matched
  (order, amount, currency, status). Webhook event ids stored in `payment_events` (unique).
- Only one webhook URL active (`RAZORPAY_WEBHOOK_URL`); the other answers 410.
- Coupon brute-force brake (per rider + IP), uniform "not found" for private/missing codes, atomic
  caps under concurrency, minimum price floor, one code per order.
- Razorpay secrets saved in the admin are encrypted with `SETTINGS_ENCRYPTION_KEY` and never sent to
  the browser (`keySecretSet` only).
- Known limits: coupon brake is per node (caps are DB-atomic); if Razorpay is unreachable during
  verify the amount re-check is skipped (signature only).

## 7. Admin audit

- Every admin write is audited: plans, coupons, prices, minimum price, offers, board posts, feature
  switches (reason required to turn off), access mode (before/after + reason, last 50 changes),
  operator decisions (`operator.*`), role/status changes, Warn messages, diagnostics views and
  downloads, emergency contact fetches (`ADMIN_CONTACT`, number not stored), operator emergency
  contact views (`operator.sos_contacts_viewed`), live link create/revoke/view.
- Storage: `subscription_config` `k='audit'` (Plans & pricing > Audit log) and `safety_audit`
  (180 days, ids and codes only).
- The audit never stores a secret.

## 8. Privacy by design (security-relevant)

- Data minimisation per surface (see [../compliance/privacy_compliance_pack.md](../compliance/privacy_compliance_pack.md)).
- Retention jobs: routes 90 days, voice metadata 7 days, safety audit 180 days, diagnostics 30 days,
  SMS rows 48 h ([data_model.md §3](data_model.md#3-retention-and-purge-jobs)).
- Medical info: on the lock screen and to responders only while an alert is open; never to admins,
  never in the timeline or notifications; removed on resolve.
- Road hazards and risk cells stored without rider ids. Review photos EXIF-stripped, private
  folder, published only with consent and admin approval.
- Pushes are data-only with usernames; private on the lock screen.
- Account deletion is immediate and cascades; shared rides show "Former rider".
- Backups are encrypted (`BACKUP_ENCRYPTION_KEY`) before leaving the VM.
- 3.57 field encryption at rest: phone numbers, emergency contact, Medical ID fields and 2-step secrets are
  AES-256-GCM encrypted in the database (`DATA_ENC_KEY`, rotation with key ids, lazy migration); refresh tokens,
  reset links and recovery codes are stored as hashes only; session IPs as keyed hashes.

## 8b. Round 4: ride lock, sign-up verification, app lock

* **Ride lock.** While a rider's phone is on a live ride (or has an SOS / crash open) and was seen in the last
  `RIDE_LOCK_STALE_MIN` (10) minutes, a sign-in on any other device answers `423 RIDE_ACTIVE_ELSEWHERE` after the
  password check, naming only the device. Same device (hashed device key / install id) is allowed. Override: a 6-digit
  e-mailed code (10 min, 5 tries, rate limited) hands the ride over ("<rider> switched phones", SOS untouched) and
  revokes the old session; MASTER_ADMIN can "End ride lock" with a reason. All audited. State on the shared session
  records, so both nodes agree. Details: `docs/features_355/sessions_and_security.md` §9.
* **Revoked sessions in a ride** keep only a safety-only socket (own SOS / crash / position) until the ride ends.
* **Sign-up** verifies the e-mail first: the same 202 for new and registered addresses (no enumeration).
* **App:** optional fingerprint / screen-lock app lock (never during a ride or SOS), FLAG_SECURE on sign-in, code and
  Medical ID screens, socket token as the first message instead of the URL, CA-root pins for the gateway hosts.

## 9. Known limits and pending items

| # | Item | Risk | Action / owner |
|---|---|---|---|
| 1 | **JWT secret old values in git history** | token forgery if the old secret is still active | Rotate `JWT_SECRET` with the grace procedure (MASTER_AGENT_PROMPT §5.1). **Pending.** |
| 2 | **DB password rotation** | DB access with an old leaked value | Rotate `ORACLE_PASSWORD` (runbook 6.2). **Pending.** |
| 3 | **DuckDNS token in git history** (`gateway/deploy/setup_new_vm.sh`) | DNS hijack / certificate mis-issuance for the legacy host | Owner regenerates the token, Vault + Caddy env only, remove from the script. **Pending.** |
| 4 | **SSH key `vm_provision_ssh.key` on VM1** | lateral movement if VM1 is compromised | Move to Vault / admin machine. **Pending.** |
| 5 | Default site CSP allows `'unsafe-inline'` scripts | XSS impact on marketing pages | **Fixed** (marketing / legal pages 11 Nov 2026; helmet default 12 Nov 2026). |
| 5b | Field encryption needs `DATA_ENC_KEY` / `BLIND_INDEX_KEY` in Vault | without them phones / medical fields stay plaintext in the DB | Owner creates both (same on both VMs) before deploying 3.57. |
| 5c | `ADMIN_MFA_ENFORCE` | an admin password worked through the app / API without a code | **Fixed** (round 4): default `all` (app ≥ 10025 asks for the code; builds < 10025 keep `web`); `strict` after `MIN_APP_BUILD=10025`. |
| 6 | HSTS on the new domain still `max-age=300` | downgrade window | Gateway header configurable (`HSTS_MAX_AGE`, `HSTS_PRELOAD`); ramp-up steps in the RUNBOOK; raise dates: owner. |
| 6b | Certificate pins (round 4) | a CA root change outside the pin-set cuts that app build off the gateway until 2027-11-01 | Rotation checklist each release (RUNBOOK "Certificate pins"). |
| 7 | Coupon brake is per node | doubled attempts across two nodes | Accepted (caps are DB-atomic). |
| 8 | No external uptime monitoring / paging | slow detection | Owner to choose a monitor. |
| 9 | Kotlin added in 3.55/3.56 never compiled in the authoring environment | build / runtime defects in safety UI | First compile + device gate (MASTER_AGENT_PROMPT §3, §6). |
| 10 | Support e-mail default was a personal address in code | spam / personal exposure | **Fixed** (11 Nov 2026): no built-in default; set `SUPPORT_EMAIL` (and optionally `SECURITY_CONTACT`, `GEO_CONTACT`) to role addresses. Empty = pages show the home page contact form. |
| 11 | No third-party penetration test yet | unknown issues | Commission before scaling / partners (v3.57 plan). |

## 10. Responsible disclosure policy (draft)

> **Reporting a security issue in CoRoute**
>
> We welcome reports from security researchers and riders. If you think you found a vulnerability
> in the CoRoute app, website (`coroute.devmonks.space`, `coroute.duckdns.org`) or API:
>
> - E-mail the address in `SECURITY_CONTACT` (**[OWNER TO FILL: security@ role address]**) with the steps to reproduce, the impact you
>   expect, and your contact details. Please do not include other people's personal data.
> - We will acknowledge within 3 working days, keep you informed, and aim to fix critical issues
>   (anything that could affect SOS, crash alerts, live locations or medical info) within 14 days.
> - Please give us reasonable time to fix before any public disclosure (90 days by default).
>
> **In scope:** the Android app, the gateway API and WebSocket, the website, `/admin` and
> `/operator` login surfaces, live emergency links.
>
> **Out of scope:** denial-of-service or load testing; social engineering of staff or riders;
> physical attacks; third-party services (Razorpay, Google, Oracle Cloud, SMS providers); reports
> from automated scanners without a demonstrated impact; missing best-practice headers without an
> exploit.
>
> **Rules:** test only with your own accounts; never trigger a real SOS to people who are not part
> of your test; never access, change or keep other riders' data; stop and report as soon as you
> reach any personal data. We will not take legal action against good-faith research that follows
> these rules. We do not run a paid bounty at this time; we are happy to credit you.

**Published (11 Nov 2026):** `/security` (`gateway/public/security.html`) shows this policy without the
response targets above, which stay **[OWNER TO FILL]** until confirmed; `/.well-known/security.txt` is
served from config (`SECURITY_CONTACT`, else `SUPPORT_EMAIL`).
