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
| Password hashing | **scrypt** `scrypt$N$r$p$salt$hash`, N = 2^15, r = 8, p = 1 (about 100 ms, 32 MiB), on the libuv threadpool with bounded concurrency; legacy bcrypt verified in a worker thread and re-hashed at next sign-in | `password_hash.js`, `password_hash_worker.js` |
| Tokens | JWT (HS256) with claims `sub`, `name`, `role`, `email`, `pv` (password version), TTL `JWT_TTL_DAYS` (30); sliding refresh in `X-CoRoute-Token` after 24 h; a password change invalidates old tokens (`pv`) | `auth.js` |
| Account gate | every request and socket re-checks status/role/password version (cached 30 s); hold/block closes sockets with 4403 | `UserGate` |
| Rotation | `JWT_SECRET_PREVIOUS` accepted for verification only during a grace period | `config.js`, `app.js` |
| Brute force | sign-in 30 / 15 min per IP and 10 failed / 15 min per account; join by code 10 failures per rider / 30 per IP per 15 min; same 401 message and hashing work for unknown accounts | `routes.js` |
| Google sign-in | ID token verified server-side against `GOOGLE_CLIENT_IDS` / `GOOGLE_WEB_CLIENT_ID` | `auth.js` |
| Guest mode | removed (`/auth/guest` → 410) | `auth.js` |
| Admin roles | `MASTER_ADMIN` in the `users` collection; first admin from `BOOTSTRAP_ADMIN_EMAILS`, then `PATCH /api/admin/users/:id/role` | `routes.js` |
| App storage | tokens in `flutter_secure_storage`; SMS roster encrypted on the phone and deleted at ride end | app |

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
| Default site CSP (helmet, `app.js`) | Still allows `'unsafe-inline'` scripts and the Razorpay hosts for responses that set no CSP of their own (join, live link and 404 pages, static files). Their inline theme line was also moved to `theme-init.js`, so this can be tightened next. |
| `/.well-known/security.txt` | RFC 9116, built per request (`app.js` `securityTxt()`): Contact `mailto:` `SECURITY_CONTACT`, else `SUPPORT_EMAIL`, else the `/security` page; Expires one year ahead; Policy `/security` |
| Tokens in browsers | `sessionStorage` + `Authorization: Bearer`, never in a URL or cookie, so CSRF does not apply. The only cookie is the guardian pilot's httpOnly session. |
| Output encoding | server values inserted with `textContent`, never `innerHTML` (shop, admin, board) |
| CORS | off by default (`origin: false`); `CORS_ORIGINS` adds explicit origins plus the site origins |
| Other headers | `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(self Razorpay)`, `X-Content-Type-Options: nosniff`, `frameguard: deny` |
| Request ids | `X-Request-Id` on every response; logs carry it instead of bodies |
| Body limits | JSON 2 MB; webhooks raw 1 MB; socket frames 256 KiB |
| Logging | 5xx logged as method + route template + request id + first error line; payment paths log no bodies, tokens, signatures or e-mails (tested) |

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

## 9. Known limits and pending items

| # | Item | Risk | Action / owner |
|---|---|---|---|
| 1 | **JWT secret old values in git history** | token forgery if the old secret is still active | Rotate `JWT_SECRET` with the grace procedure (MASTER_AGENT_PROMPT §5.1). **Pending.** |
| 2 | **DB password rotation** | DB access with an old leaked value | Rotate `ORACLE_PASSWORD` (runbook 6.2). **Pending.** |
| 3 | **DuckDNS token in git history** (`gateway/deploy/setup_new_vm.sh`) | DNS hijack / certificate mis-issuance for the legacy host | Owner regenerates the token, Vault + Caddy env only, remove from the script. **Pending.** |
| 4 | **SSH key `vm_provision_ssh.key` on VM1** | lateral movement if VM1 is compromised | Move to Vault / admin machine. **Pending.** |
| 5 | Default site CSP allows `'unsafe-inline'` scripts | XSS impact on marketing pages | **Fixed for marketing and legal pages** (11 Nov 2026, `MARKETING_CSP`). The helmet default for the remaining pages (join, live link, 404) can drop `'unsafe-inline'` next. |
| 6 | HSTS on the new domain still `max-age=300` | downgrade window | Raise after a stable week (owner decision). |
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
