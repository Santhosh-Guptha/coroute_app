# CoRoute security audit v3.55 (sessions, authentication, authorization, data protection)

Date: 12 Nov 2026. Scope: gateway (`gateway/src`), website (`gateway/public`: site, `/account`, `/admin`, `/operator`),
Android app (`lib/`, `android/`). Owner request: sessions, authentication, authorization, sign-out everywhere,
automatic sign-out when unused, encryption of personal data, payments, "no loopholes", and after sign-out the
home screen. Design and behaviour: [docs/features_355/sessions_and_security.md](../features_355/sessions_and_security.md).

Status values: **Fixed** (in code, tested), **Fixed, needs owner** (in code; needs a secret / a decision before it
takes effect), **Mitigated** (risk reduced, not removed), **Accepted** (documented decision), **Follow-up** (not
done in this round, why stated).

## How the audit was done

* Read the auth, session, routing, WebSocket, mirror, payment, upload and website client code; the app's API client,
  WebSocket client, auth service, session binder, sign-out paths, local storage and Android manifest.
* Walked every express route (480) and called each anonymously and as a plain rider: 379 answered 401 anonymously,
  every `/api/admin/*` route answered 403 to a rider, the rest are listed public routes. This is now a permanent
  test (`gateway/test/route_policy_357.test.js`, table `gateway/src/route_policy.js`).
* `npm audit --omit=dev`, headers of every page type, cookie flags, CSP, Back-button / bfcache behaviour in Chromium.

## Findings

| # | Severity | Issue | Fix | Status |
|---|---|---|---|---|
| 1 | High | No server-side sessions. A JWT stayed valid for 30 days whatever happened; "sign out" only forgot it on the device. | `auth_sessions` records (device, platform, created, last seen, keyed IP hash, UA summary, hashed refresh token); every token carries `sid`; every request and socket message checks the session (cached 30 s, invalidated at once on revoke, on the peer node through mirror extension `ss`). | Fixed |
| 2 | High | Long-lived bearer tokens everywhere (30 days, also in website `sessionStorage`); no refresh rotation, no theft detection. | 15-minute access tokens + rotating refresh tokens (`rt1.<sid>.<n>.<secret>`, only SHA-256 stored) with reuse detection: an older token revokes the whole session and is audited (`AUTH / REFRESH_REUSE`). A token re-used within 60 s (lost reply, second tab) rotates again instead of signing out. Compare-and-replace prevents two refreshes rotating from the same state. Website refresh token in an httpOnly `__Host-` cookie. | Fixed |
| 3 | High | Sign-out did not end the session on the server; open sockets stayed connected. | `POST /api/auth/logout`, `/logout-all`, `DELETE /api/me/sessions/:id`; sockets of the session close with 4401 `SIGNED_OUT` on both nodes. Safety exception: a rider's socket in a live ride stays until the ride ends (SOS relay is never cut by a sign-out; REST is refused at once); hold / block / deletion still close everything at once. | Fixed |
| 4 | High | Web admin protected by a password only. | TOTP 2-step (RFC 6238, ±1 step, replay refused) with 10 single-use recovery codes, **forced enrolment at the first web admin sign-in** for `MASTER_ADMIN`, optional for operators; secrets encrypted at rest; break-glass script + runbook. | Fixed |
| 5 | High | `AndroidManifest.xml` referenced `@xml/data_extraction_rules`, which did not exist: the release build fails at resource linking. | Added `res/xml/data_extraction_rules.xml` excluding every domain from cloud backup and device transfer (`allowBackup=false`, `fullBackupContent=false` kept for older Android). | Fixed (needs the Gradle build to confirm) |
| 6 | High | Phone numbers, emergency contact and Medical ID stored in plaintext in the database (users, ride rosters, room snapshots). | AES-256-GCM field encryption with key ids and rotation (`DATA_ENC_KEY`, `DATA_ENC_KEY_ID`, `DATA_ENC_KEYS_PREVIOUS`), applied for every module through an encrypting SODA wrapper; lazy migration on read (compare-and-replace, a concurrent update always wins); `scripts/encrypt_fields.js` to finish it; health reports `KEY_MISSING`; an unknown key never returns ciphertext as a phone number. | Fixed, needs owner (keys in OCI Vault) |
| 7 | Medium | Wrong passwords limited only per node in memory; no account lock, no notice. | Per-account lock after 10 failures (15 min, doubling to 24 h) stored in the account, e-mail notice, progressive delay for known and unknown accounts, identical 429 answer for "locked" and "rate limited". | Fixed |
| 8 | Medium | No self-service password reset (riders e-mailed support for a temporary password). | `POST /api/auth/password/forgot` (always 202, same timing) and `/reset`: 32-byte token in a URL fragment, only its hash stored, single use, 30 minutes, max 3 per hour; every session ends after the reset. | Fixed |
| 9 | Medium | Registration said "This email is already registered" (409 told that an address exists). | Round 4: e-mail verification first. Register always answers the same generic 202 ("Check your e-mail to finish creating your account", same work and padded timing); a new account waits for a single-use 24 h link (hash stored) and cannot sign in before it; a registered address gets a "someone tried to create an account with your e-mail" mail instead of a 409; resend rate limited; unconfirmed sign-ups purged after 7 days; Google and reset links count as verified; old accounts are verified. Builds < 10025: `REGISTER_VERIFY_LEGACY=verify` (default) gives them the same flow with a readable message. Callsigns stay public (409 CALLSIGN_TAKEN, checked before the address). Tests: `register_verify_357.test.js`. | Fixed |
| 10 | Medium | Hold / block did not end sessions; re-activation revived old tokens. | Hold, block, deletion, password change / reset, e-mail change and losing the admin role revoke every session (sockets 4403 for hold / block). Gaining a role does not (rights are read from the database on every call; the web admin asks for 2-step at its own sign-in). | Fixed |
| 11 | Medium | No re-authentication for sensitive actions. | `POST /api/auth/reauth` (password or Google ID token) marks the session for 10 minutes; needed for account deletion (clients with the new sessions), e-mail change, 2-step changes. Wrong password = 403 `REAUTH_FAILED` (never a sign-out). | Fixed |
| 12 | Medium | No way to change the e-mail address safely. | Re-auth, confirmation link to the new address, notice to the old one, sessions end after the change; a taken address gets the same answer and no mail. Not for Google accounts. | Fixed |
| 13 | Medium | Default CSP (every response without its own policy) allowed `'unsafe-inline'` scripts and Razorpay. | Strict default `script-src 'self'`, `script-src-attr 'none'`, `connect-src 'self'`, `frame-src 'none'`. Pages that need Razorpay / Google keep their own narrow policies. Style attributes still need `'unsafe-inline'` in `style-src`. | Fixed (styles: Accepted, Low) |
| 14 | Medium | API answers had no `Cache-Control`; Back after sign-out could show cached data. | `no-store` on every `/api` answer unless a public route sets caching; private pages already `no-store`; `pageshow` (bfcache) re-check on `/account`, `/receipt`, `/trip`, `/admin`, `/operator`; `Clear-Site-Data: "cache"` on website sign-out. | Fixed |
| 15 | Medium | WebSocket upgrade accepted any browser Origin. | Same-host, site origins or `CORS_ORIGINS` only; no Origin (the app) accepted. | Fixed |
| 16 | Medium | Log lines could carry e-mails, phone numbers or tokens from module logs. | Redacting logger wraps the gateway logger (JWTs, Bearer, refresh tokens, `password=`/`otp=`/`token=` values, e-mails masked, phones to last 4 digits). | Fixed |
| 17 | Medium | `npm audit --omit=dev`: body-parser < 1.20.9 (high, DoS), qs < 6.16.1 (moderate). | Lockfile updated: body-parser 1.20.9, qs 6.16.2 (patch releases, no API change). | Fixed |
| 18 | Medium | App: when the gateway ended a session (revoke, expiry), the app tore down the running ride at once: convoy session ended, emergency contact cleared, sign-in screen pushed — even during an SOS. | `SessionGuard`: a sign-out (any cause) waits while a ride, convoy, SOS / crash countdown or pending emergency texts run; the profile and emergency contact stay; it runs when the ride is over. | Fixed |
| 19 | Medium | App sign-out: no server revoke, ride chat archive and image cache left on the phone, emergency info cleared silently. | Push token removed first, server revoke, tokens wiped from the keystore, chats / trip cache / images wiped, then the welcome screen with the stack cleared. Dialog: this phone or all devices, "Keep emergency info on this phone" (default on). | Fixed |
| 20 | Medium | App kept phone, emergency contact and e-mail in plaintext SharedPreferences. | Moved to the Android Keystore (flutter_secure_storage), migrated silently; SharedPreferences only as a fallback when the keystore is unavailable (an offline SOS never loses the contact). | Fixed |
| 21 | Medium | `ADMIN_MFA_ENFORCE=web`: an admin password still worked through the app / API without a code. | Round 4: default `all`: admin API calls from app builds ≥ 10025 and the consoles need a 2-step session; the app asks for the code on `MFA_REQUIRED` (step-up `POST /api/auth/mfa/step-up`) and repeats the call. Builds < 10025 (legacy sessions) keep `web` so they are not locked out; `strict` covers every client once `MIN_APP_BUILD` reaches 10025. E-mail codes as a fallback for operators, never for MASTER_ADMIN. | Fixed (strict: owner, with MIN_APP_BUILD) |
| 22 | Low | scrypt N=2^15, r=8, p=1 (below the OWASP equivalent). | p=3 (OWASP scrypt equivalent of N=2^17); hashes at older parameters are re-hashed at the next sign-in. | Fixed |
| 23 | Low | Password rule was length only. | Min 8, max 200, bundled common / breached list with trivial variants, not the e-mail or callsign, no runs / repeats (422 `WEAK_PASSWORD`). | Fixed |
| 24 | Low | Google sign-in: issuer not checked explicitly; a linked Google id was not enforced. | `iss` checked (library also checks signature, audience, expiry); an account with `googleSub` answers only to that Google account. | Fixed |
| 25 | Low | No notice of sign-ins on new devices. | "New sign-in to CoRoute on <device>" e-mail once per device fingerprint (keyed hash), never for the first device. | Fixed |
| 26 | Low | No list of signed-in devices, no "sign out everywhere". | `/account` "Where you're signed in" (sign out each), "Sign out of all devices" on `/account` and in the app. | Fixed |
| 27 | Low | Website / admin sign-out returned to a sign-in card; admin idle sign-out had no warning; operator idle 60 min. | Sign out -> home page (`/`, history replaced). Admin and operator: 30 min idle with a warning dialog 2 min before, server session revoked. Rider site: 60 min, shared across tabs. | Fixed |
| 28 | Low | No central inventory of route access. | `route_policy.js` + test that fails for an undeclared route or one that does not enforce its policy. | Fixed |
| 29 | Low | WebSocket token travelled as `?token=` (could be logged by a proxy). | Round 4: apps ≥ 10025 send `{type: AUTH, token}` as the first message within 5 s (`WS_AUTH_TIMEOUT_MS`), or the subprotocol pair `coroute.v1` + `coroute.bearer.<token>`; `?token=` stays for older builds; the app falls back to it once against an older gateway. Gateway logs redact `token=`; Caddy log filter guidance in the RUNBOOK. | Fixed (old builds: until MIN_APP_BUILD) |
| 30 | Low | Certificate pinning not used. | Round 4: Android `pin-set` for `coroute.devmonks.space` and `coroute.duckdns.org` only, on CA root keys computed from the root certificates: ISRG Root X1 + X2 (Let's Encrypt), USERTrust RSA + ECC (ZeroSSL, Caddy's fallback) and Sectigo R46 + E46 as backups; `expiration=2027-11-01` (fails open); debug builds may use user CAs. Residual risk: a CA moving to a root not in the set before the next app release would cut riders on that build off the gateway (SOS texts and lock-screen Medical ID do not need it); rotation checklist in the RUNBOOK. | Fixed (rotation: owner, each release) |
| 31 | Low | Optional app lock not available. | Round 4: Settings "Lock CoRoute with fingerprint or screen lock" (off by default), framework BiometricPrompt / KeyguardManager through `AppSecurityChannel.kt` (no new dependency); cold start and 5 min (configurable) in the background; never during a ride, convoy, SOS, crash countdown or pending emergency texts; SOS, Call 112 and Medical ID work while locked. | Fixed (needs the Gradle build and a device check) |
| 32 | Low | `FLAG_SECURE` not set on sensitive screens. | Round 4: reference-counted FLAG_SECURE on sign-in / create account, the ride lock code dialog, the Medical ID / emergency contact form and the 2-step prompt; never on maps or ride screens. | Fixed (needs a device check) |
| 33 | Low | Rate limits are per node (memory store). | Account lock is stored in the database (both nodes); IP limits per node are acceptable for two nodes. | Accepted |
| 34 | Low | E-mail address is not field-encrypted. | It is the sign-in identifier, unique index and admin search key; Oracle ADB encrypts all data at rest (TDE). `blindIndex()` is ready for a later step. | Accepted |
| 35 | Low | Builds before 10025 keep long sliding tokens and deleted the account without re-authentication. | Round 4: their deletion without the password now e-mails a single-use 30-minute confirmation link (202 + readable message). Long tokens stay bound to sessions (revocable, idle 30 days) until `MIN_APP_BUILD` is raised to 10025. | Fixed (deletion) / Accepted (long tokens until MIN_APP_BUILD) |
| 36 | Info | HSTS: Caddy sends 300 s on `coroute.devmonks.space`. | Gateway header configurable (`HSTS_MAX_AGE`, `HSTS_PRELOAD`, tested); ramp-up steps (1 day, 7 days, 1 year) and the preload caveat (apex domain) in the RUNBOOK. | Fixed (raise dates: owner) |
| 37 | Info | Payments (website only). | Re-verified: order created server side at the server price; HMAC signature timing-safe; webhook signature + replay table across both URLs; amount / currency / plan / captured must match; idempotent settlement under concurrency; coupons validated server side, personal codes bound to the rider, caps hold; receipts and verify only for the order's rider (admins included). Existing tests + new IDOR test. The Play app shows no prices / payments (policy scan 0). | No change needed |
| 38 | Info | Two-node mirror. | HMAC challenge-response with `MIRROR_KEY`, encrypted frames, private interface only. Session revokes now replicate (extension `ss`). | No change needed |
| 39 | Info | CSRF / CORS. | APIs use Bearer tokens (not sent automatically by browsers). The only cookie-authenticated calls (refresh, logout) need `X-CoRoute-CSRF: 1` + allowed Origin + SameSite (Lax site, Strict consoles). CORS allowlist from `CORS_ORIGINS` + site origins, else none. | Fixed / OK |
| 40 | Info | Uploads and diagnostics. | Authenticated, size-limited (JSON 2 MB; bundles and photos have their own limits), rate-limited (5 diagnostics / day), prohibited keys refused, admin-only viewing. | No change needed |
| 41 | Info | Object-level access (IDOR). | Checked trips, ride rosters / timelines / tracks / GPX, receipts, orders, crews, operator consoles, admin riders, sessions: another rider gets 403 / 404. New tests in `security_357.test.js`. | No change needed |
| 42 | High | Owner rule: a second device could sign in while the rider's phone is on a ride (stolen account takeover mid-ride, two devices sending the same rider). | Round 4 ride lock (`src/ride_lock.js`): every sign-in route answers 423 `RIDE_ACTIVE_ELSEWHERE` for another device while a session's device is on a live ride (or has an open SOS / crash) and was seen within 10 min; password checked first (no enumeration), device label only; same device / install id allowed; earlier sessions cannot start or join a ride (409). E-mail code override (6 digits, 10 min, hashed, 5 tries, rate limited) hands the ride over ("<rider> switched phones", SOS kept), revokes the old session, notice e-mail. Admin "End ride lock" (MASTER_ADMIN, reason, audited). State on the shared session records (both nodes). Tests: `ride_lock_357.test.js` (12, incl. two nodes). | Fixed |
| 43 | Medium | A session revoked during a ride kept a full socket (other riders' positions, chat, members) until the ride ended. | Round 4 safety-only mode: own SOS / crash / position and keep-alives in, control messages and own alerts out; everything else refused (`SAFETY_ONLY`). | Fixed |
| 44 | Low | No second factor for operators without an authenticator app. | Round 4: e-mailed 6-digit codes (opt-in, re-auth, TOTP preferred, never MASTER_ADMIN), single use, 10 min, 5 tries, rate limited. | Fixed |

## Tests

* Gateway: `test/security_357.test.js` (30 tests), `test/route_policy_357.test.js` (4), round 4 `test/ride_lock_357.test.js` (12),
  `test/register_verify_357.test.js` (9). Full suite: see the round 4 report in `docs/NEXT_AGENT_PROMPT_v3.55_round3.md` §7.
* Browser (round 4): `node tool/security_round4_smoke.js <dir>`: website sign-in blocked during a ride -> e-mail code ->
  signed in (old phone in safety-only mode), phone width, create account -> Check your inbox -> link -> sign in.
* Browser: `node tool/security_smoke.js <dir>` (Playwright): website sign-out -> home, Back after sign-out shows no private
  data, new tab continues through the cookie, admin 2-step set-up, idle warning, automatic sign-out with the server
  session revoked. The other console smoke tools still pass (`web_admin_smoke`, `web_console_smoke`, `operators_smoke`).
* App: `test/session_security_357_test.dart` (refresh once / single flight / end only on gateway codes, sign-out wipe,
  emergency info kept, never mid-ride, welcome screen with the stack cleared). `dart analyze lib test`: no issues.
  Round 4: `test/account_security_round4_test.dart` (ride lock dialog flow, check inbox, 2-step prompt and step-up retry,
  app lock rules, FLAG_SECURE counting, socket auth helpers, pin-set checks). Flutter tests could not run in this
  environment (the Flutter SDK download is blocked by the egress policy): run `flutter test` before the build.

## Owner decisions / actions

1. Create `DATA_ENC_KEY` and `BLIND_INDEX_KEY` in OCI Vault (same on both VMs) before deploying; keep a Vault backup.
2. HSTS raise dates for `coroute.devmonks.space` (finding 36, RUNBOOK "HSTS ramp-up"); preload not recommended.
3. When to raise `MIN_APP_BUILD` to 10025 (findings 29, 35); then `ADMIN_MFA_ENFORCE=strict` (finding 21).
4. Certificate pins: check the RUNBOOK rotation list before every release; the pin-set fails open on 2027-11-01.
5. Device checks on a release build (QA list in `docs/NEXT_AGENT_PROMPT_v3.55_round3.md` §7): ride lock, app lock,
   FLAG_SECURE, pinning, old-build compatibility; new e-mails in Gmail and Outlook.
6. Privacy / Play Data safety: the app now sends a hashed device key and a random install id (security: the ride
   lock); declare "Device or other IDs - security / fraud prevention, not shared" in the Play Data safety form.

Every row above is Fixed, or Accepted with its reason (styles in CSP #13, per-node IP limits #33, e-mail not
field-encrypted #34, long tokens of old builds #35 until MIN_APP_BUILD).
