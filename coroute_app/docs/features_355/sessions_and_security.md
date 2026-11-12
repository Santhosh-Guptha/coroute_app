# Sessions and security (3.57 round, app build 3.55.0+10025)

Findings and status: [docs/security/SECURITY_AUDIT_v3.55.md](../security/SECURITY_AUDIT_v3.55.md).
Code: `gateway/src/sessions.js`, `security_routes.js`, `auth.js`, `field_crypto.js`, `redact.js`, `totp.js`,
`password_policy.js`, `route_policy.js`; website `public/assets/shop.js`, `signin.js`, `account.js`,
`public/admin/admin.js`, `public/operator/operator.js`; app `lib/data/services/api_client.dart`, `auth_service.dart`,
`session_guard.dart`, `lib/domain/auth/session_policy.dart`, `lib/presentation/account/sign_out_flow.dart`.

## 1. Sessions

Every sign-in creates one record in `auth_sessions`:

| Field | Meaning |
|---|---|
| `sessionId` | `ses_…`, carried in every token as `sid` |
| `userId`, `kind` | `app` (build ≥ 10025), `legacy` (older builds / API clients), `web`, `admin`, `operator` |
| `deviceLabel`, `platform`, `uaSummary` | "Galaxy S24", "android", "Chrome on Windows" (no device ids) |
| `ipHash` | keyed HMAC of the IP (`BLIND_INDEX_KEY`), never the IP |
| `createdAt`, `lastSeenAt`, `absoluteExpiresAt` | lifetimes below |
| `refreshHash`, `refreshCounter`, `prevRefreshHash`, `rotatedAt` | SHA-256 of the refresh token, rotation state |
| `mfa`, `reauthAt`, `revokedAt`, `revokeReason` | 2-step passed, last re-authentication, end |

| Kind | Access token | Refresh token | Idle | Absolute |
|---|---|---|---|---|
| app (≥ 10025) | 15 min | rotating, in the Android Keystore | 30 days | 60 days, **extended while riding** |
| legacy (< 10025) | 30 days, sliding (`X-CoRoute-Token`) as before | none | 30 days | none (retire with `MIN_APP_BUILD`) |
| web (`/account`, `/plans` …) | 15 min (`sessionStorage`) | rotating, httpOnly `__Host-cr_rt` cookie, SameSite=Lax | 60 min | 7 days |
| admin (`/admin`) | 15 min | `__Host-cr_adm`, SameSite=Strict | 30 min | 12 h |
| operator (`/operator`) | 15 min | `__Host-cr_op`, SameSite=Strict | 30 min | 12 h |

* **Rotation and reuse detection.** `POST /api/auth/refresh` rotates the refresh token. The token just before the
  current one, presented within `REFRESH_REUSE_GRACE_SEC` (60 s) of its rotation, rotates again (a lost reply, a second
  tab: never a sign-out). Any other older token = theft: the whole session is revoked and audited (`AUTH / REFRESH_REUSE`).
* **Every check sees the session.** Each authenticated request and each socket message checks it (cached for
  `USER_GATE_TTL_MS`, dropped at once on this node by every revoke and on the peer node by mirror extension `ss`).
  Revoked sockets close with 4401 `SIGNED_OUT` (4403 for hold / block).
* **What revokes every session of an account:** sign out of all devices, password change (others) and reset, e-mail
  change, account deletion (records erased with the account), hold / block, losing the admin role, admin password reset.
* **A sign-out never cuts a live ride (server).** When a session is signed out or revoked (this device, all devices,
  password change or reset, e-mail change, losing the admin role, idle / expiry), REST calls with it are refused at
  once, but a socket of a rider who is in a live ride on that node stays open (and a reconnect from a tunnel is let back
  in) until the ride ends or the rider leaves it, then closes 4401 `SIGNED_OUT`: SOS, crash alerts and positions keep
  reaching the group. Hold, block and account deletion still close every socket at once (admin decisions, unchanged).
* **Never signed out mid-ride (server).** An app session past its absolute lifetime is extended by 24 h at refresh when
  the rider is in a live ride or has an open alert (memory rooms, else `active_trips`), audited `SESSION_EXTENDED_RIDE`.
  Idle (30 days) cannot happen during a ride: socket traffic keeps `lastSeenAt` fresh.

### Compatibility (never lock riders out)

* Builds before 10025 send no `X-CoRoute-Session: 2`: they get the long sliding token, now bound to a `legacy` session.
* A token issued before this release (no `sid`) still works; the first call creates a `legacy` session and the reply
  carries a session-bound `X-CoRoute-Token` (every app build adopts it). "Sign out of all devices" also ends such
  tokens (`users.tokensValidAfter`).
* `MIN_APP_BUILD` is unchanged by this release. Raising it to 10025 later ends long tokens and the re-auth exemption.

## 2. Sign-out

**App** (Profile › Account › Sign out; Account keeps exactly two rows):
1. Dialog: **Sign out** (this phone) or **Sign out of all devices**, and **Keep emergency info on this phone** (on by
   default). Kept, the lock-screen Medical ID card (contact, blood group, allergies, notes) stays until the rider
   removes it or another account signs in, because SOS and crash alerts work without an account. Removed, it is cleared.
2. The push token is removed on the gateway (while the token still works), the session is revoked (`/auth/logout`, or
   `/auth/logout-all` first for every device — that one fails visibly when offline), the access and refresh tokens are
   deleted from the keystore, the profile (keystore) and cached personal data (ride chats, trip cache, images) are wiped,
   the realtime session ends.
3. The welcome / sign-in screen replaces the whole navigation stack: Back cannot return.

**Never during a ride.** While a ride, a convoy, an SOS or crash / rider-down countdown, or pending emergency texts run
(`SessionGuard`), the sign-out waits: the rider's own tap says "You can sign out after the ride…" and happens when the
ride is over; a session ended by the gateway keeps the screen, the profile and the emergency contact (SOS texts keep
working) and shows a notice, then signs out after the ride. Account deletion is explicit and wipes everything.

**Website / consoles.** Sign out ends the server session, clears the cookie (`Clear-Site-Data: "cache"` on the site)
and goes to the home page `/` with the history entry replaced. Other tabs follow (BroadcastChannel on the site,
storage event in the consoles). Private pages are `no-store` and re-checked on `pageshow` (back/forward cache).

## 3. Automatic sign-out when unused

* Rider website: 60 min without activity (shared by every tab), then the server session ends.
* Web admin and operator console: 30 min, with a "Still there?" dialog 2 min before (Stay signed in / Sign out now).
  QA can shorten (never lengthen) it per tab: `sessionStorage['cr.idleMs']`.
* App: the session ends on the server after 30 days unused. Never during a ride (above).

## 4. Authentication

* Passwords: scrypt N=2^15, r=8, p=3 (re-hashed at the next sign-in from older parameters). 8–200 characters, not on the
  bundled common / breached list (with trivial variants), not the e-mail or callsign (422 `WEAK_PASSWORD`).
* Lockout: 10 wrong passwords lock password sign-in for 15 min (doubling up to 24 h), one e-mail notice; progressive
  delay after the third failure for known and unknown accounts; locked and rate-limited answer the same 429.
* No enumeration: the same error for a wrong password and an unknown account; reset always answers 202 with the same
  timing; register always answers the same generic 202 and verifies the address by e-mail (§12).
* Reset by e-mail: `/signin#reset=<token>` (fragment: never in a log or Referer), single use, 30 min, hash stored,
  every session ends afterwards.
* Google: ID token verified server side (signature, audience = our client ids, expiry, issuer, verified e-mail; a linked
  Google id must match).
* New-device e-mail "New sign-in to CoRoute on <device>" (transactional, once per device fingerprint).
* 2-step verification (TOTP): required for `MASTER_ADMIN` at the web admin sign-in; round 4 default
  `ADMIN_MFA_ENFORCE=all` also requires a 2-step session for admin API calls from app builds ≥ 10025 and the consoles
  (the app asks for the code, §11); older builds keep `web`; `strict` = every client; `off`. First sign-in forces enrolment (QR + key, code, ten
  recovery codes shown once). Operators may enrol (`POST /api/me/mfa/setup`); then their console and website sign-ins
  ask for a code. App sign-ins never ask for a code (an admin is also a rider); admin tools in the app ask on first use.
  Break-glass: `gateway/deploy/RUNBOOK.md`.
* Re-authentication (`POST /api/auth/reauth`, password or Google ID token, valid 10 min, signing in counts): account
  deletion (clients with the new sessions), e-mail change, 2-step changes. The app asks for the password (or Google)
  when deleting the account.

## 5. Authorization

`gateway/src/route_policy.js` declares the policy of every route (public with a reason, auth, admin, operator, page);
`test/route_policy_357.test.js` walks the express app and fails for an undeclared route, a stale entry, or a route that
does not enforce its policy (anonymous 401, rider 403 on admin routes). Object-level checks (trips, ride rosters and
timelines, receipts, orders, crews, operator consoles, admin riders, sessions) have tests. Admin actions stay audited.

## 6. Data protection

* In transit: HTTPS only (Caddy), HSTS (gateway: 1 year + includeSubDomains; Caddy per host), strict CSP without inline
  script, `frame-ancestors 'none'` + `X-Frame-Options: DENY`, Referrer-Policy, Permissions-Policy, `no-store` on APIs
  and private pages, CORS allowlist, CSRF guard on the two cookie calls, WebSocket Origin check. App: cleartext off,
  system CAs, and (round 4) CA-root pins for the two gateway hosts that fail open after 2027-11-01 (§11).
* At rest (gateway): AES-256-GCM field encryption of phone, emergency contact (number, name), blood group, allergies,
  medical notes and 2-step secrets in `users`, and the roster copies in `convoy_riders` / `room_snapshots`
  (`DATA_ENC_KEY`, key id per value, rotation with `DATA_ENC_KEYS_PREVIOUS`, lazy migration, `scripts/encrypt_fields.js`).
  Refresh tokens, reset / e-mail links and recovery codes are stored as hashes only. E-mail stays the plain lookup column.
* At rest (app): tokens and the profile's phone / emergency contact / e-mail in the Android Keystore; no Android backup
  or device transfer (`data_extraction_rules.xml`).
* Logs: the gateway logger redacts tokens, passwords, OTPs, e-mails and phone numbers (`src/redact.js`); the app's
  diagnostics log already keeps path templates only.

## 7. Endpoints

`POST /api/auth/refresh`, `/auth/logout`, `/auth/logout-all`, `/auth/reauth`, `/auth/password/forgot`,
`/auth/password/reset`, `/auth/email/confirm`, `/auth/mfa/verify`, `/auth/mfa/enroll/start`, `/auth/mfa/enroll/confirm`;
`GET /api/me/sessions`, `DELETE /api/me/sessions/:sessionId`, `GET /api/me/security`, `POST /api/me/email`,
`POST /api/me/mfa/setup | confirm | recovery-codes`, `DELETE /api/me/mfa`. Sign-in answers (`/auth/login`, `/register`,
`/google`) add `sessionId`, `sessionKind`, `refreshToken` (app ≥ 10025) and `accessExpiresAt`, or `{ mfa, mfaToken }`.

## 8. Follow-ups

Round 4 closed every follow-up of round 3 (sections 9-12). Remaining owner decisions are in the audit
(`docs/security/SECURITY_AUDIT_v3.55.md`, "Owner decisions").

## 9. Ride lock (round 4)

Owner rule: "restrict the user to login in another device if current device is in a active ride". Code:
`gateway/src/ride_lock.js`, `email_codes.js`, `security_emails.js`; app `lib/domain/auth/account_flows.dart`,
`lib/presentation/auth/ride_lock_dialog.dart`; website `public/assets/signin.js`. Tests: `gateway/test/ride_lock_357.test.js`,
`test/account_security_round4_test.dart`, `tool/security_round4_smoke.js`.

**When it locks.** A session becomes the riding one when its device starts or joins a ride (REST `POST /convoys`,
`/convoys/join`) or its socket JOINs a live ride (solo rides are rooms too). The lock is active while that ride is still
on (planning / started / paused and the rider still in it) or the rider has an SOS / crash alert still open in it, AND
the session was seen within `RIDE_LOCK_STALE_MIN` (10) minutes (any HTTP call, or socket traffic: the hub writes
`rideSeenAt` at most every 2 minutes). The state lives on the session record in the database both nodes share, so the
web node (where sign-ins land) sees the lock set by the live node; ride state is read from the local room when loaded,
else from the convoy record and open alerts. Ended ride: unlocked at once. Silent phone: unlocked after 10 minutes.

**What it blocks.** Every sign-in on another device: password, Google, the 2-step step, the website, `/account`, the web
admin, the operator console, old app builds; and a refresh of a session that never passed a lock check created after
the ride began. Answer: `423 RIDE_ACTIVE_ELSEWHERE`, `error: "You're on a ride on Pixel 7. End the ride on that phone to
sign in here."`, `device`, `lockToken` (15 min). The password is checked first: a wrong password is the usual 401, so the
lock never reveals an account. No ride details or places. Old builds show `error` as is.

**What it allows.** The same device: same device key (SHA-256 of Android's app-scoped device id, made on the phone; the
gateway stores a keyed hash) or same install id (random per install), so a crash, an app kill or a reinstall never locks
the rider out of their own ride. Sessions signed in before the ride stay signed in, but cannot start or join a ride
(`409 RIDE_ACTIVE_ELSEWHERE`, REST and socket JOIN).

**Escape hatch ("Use e-mail code").** `POST /api/auth/ride-lock/code { lockToken }` e-mails "Ride sign-in code" (6 digits,
10 min, only an HMAC stored, single use, 5 wrong tries, one per 60 s and 5 per hour per account, plus IP limits).
`POST /api/auth/ride-lock/verify { lockToken, code }` signs the new device in and hands the ride over: the rider stays in
the ride, the group gets `RIDER_HANDOVER` and the chat card "<rider> switched phones" (told by the node that holds the
room, through mirror extension `rl` when needed); an open SOS is never touched; then the old session is revoked (its
socket stays in safety-only mode until the ride ends, §10) and a "Signed in during a ride" notice is e-mailed.

**Admin.** Web admin › Riders › rider: chip "On a ride (Pixel 7)"; More › **End ride lock…** (MASTER_ADMIN, reason
required, audited in the rider audit and `safety_audit`). The ride and its alerts continue; the lock does not come
back for that ride. Every block, code, override and admin end is audited (`AUTH / RIDE_LOCK_*`).

**Switch.** `RIDE_LOCK=off` turns it off (rollback only).

## 10. Revoked sessions during a ride: safety-only sockets (round 4)

A session revoked while its socket is in a live ride (sign out everywhere, password change, ride lock handover, idle)
keeps that socket until the ride ends, in safety-only mode: it receives `SAFETY_ONLY`, control messages and its own
alerts only (no other rider's positions, chat, voice, member data or snapshot, no fleet), and may only send `SOS` (crash
alerts are SOS), positions, `PING`, `BYE`, `LAST_GASP_BEACON`, `JOIN` / `LEAVE`. Anything else answers
`ERROR 403 SAFETY_ONLY`. Hold, block and deletion still close everything at once.

**WebSocket authentication.** Apps from 10025 open `/ws` without a token and send `{ "type": "AUTH", "token": … }` as the
first message (5 s, `WS_AUTH_TIMEOUT_MS`); other clients may use the subprotocol pair `coroute.v1`,
`coroute.bearer.<token>` (the server echoes only `coroute.v1`). `?token=` stays for older builds. If an older gateway
refuses a first-message socket ("Unauthorized" before HELLO) the app retries once with `?token=`.

## 11. App: app lock, FLAG_SECURE, admin 2-step, pins (round 4)

* **App lock** (Settings › App & privacy › "Lock CoRoute with fingerprint or screen lock", off by default; "Lock after":
  every time, 1, 5 (default), 15, 30 min). Framework APIs only (`AppSecurityChannel.kt`): BiometricPrompt with device
  credential on Android 9+, `KeyguardManager.createConfirmDeviceCredentialIntent` on 6-8. Turning it on needs a screen
  lock and one successful unlock. Locks on a cold start and after the delay in the background; never during a ride, a
  convoy, an SOS, a crash / rider-down countdown or pending emergency texts, and an existing lock drops at once when one
  starts. The lock screen keeps **SOS**, **Call 112** and **Medical ID** usable without unlocking. Rules:
  `lib/domain/security/app_lock_policy.dart`.
* **FLAG_SECURE** only on: sign-in / create account, the ride lock code dialog, the Medical ID / emergency contact form,
  the 2-step prompt. Never on maps or ride screens.
* **Cockpit on the lock screen** (later round, docs/features_355/lock_screen_cockpit.md): during a ride only, signed in,
  with the setting on, the ride screen is shown over the keyguard (`setShowWhenLocked`, never `turnScreenOn`); anything
  private (chat text, profile, settings, history, ending the ride, sharing, calling contacts) needs the phone's unlock
  (`requestDismissKeyguard`). It never shows after the ride or after sign-out. A ride is exactly what keeps the app lock
  away, so the two never cover each other; the app lock applies again after the ride.
* **Admin 2-step in the app.** An admin call answered `403 MFA_REQUIRED` opens the 2-step prompt (authenticator code or
  recovery code; operators may ask for an e-mailed code); `POST /api/auth/mfa/step-up` marks the session, the call
  repeats once. `MASTER_ADMIN` never gets e-mail codes. Not enrolled yet: the prompt says to enrol at the web admin.
* **E-mail 2-step for operators.** `POST /api/me/mfa/email { enable }` (re-auth); then the console / website sign-in
  step offers "E-mail me a code" (`POST /api/auth/mfa/email-code`). TOTP stays preferred.
* **Certificate pins** (release builds): CA roots of Let's Encrypt and ZeroSSL/Sectigo for the two gateway hosts,
  failing open after 2027-11-01. Rotation: RUNBOOK "Certificate pins".

## 12. Sign-up verification and old-build deletion (round 4)

* `POST /api/auth/register` answers the same `202 { pending, message: "Check your e-mail to finish creating your
  account" }` for a new and a registered address (same work, padded timing). A new account is created unverified with
  a single-use 24 h link (`/signin#verify=…`, hash stored); it cannot sign in (`403 EMAIL_NOT_VERIFIED` after the right
  password) until `POST /api/auth/email/verify`. A registered address gets "Someone tried to create an account with your
  e-mail…" (at most every 6 hours). A repeated pending sign-up re-sends the link and never replaces the first password.
  Callsigns are public and still answer `409 CALLSIGN_TAKEN` (checked before the address). Resend:
  `POST /api/auth/register/resend` (always 202, one per 60 s, 3 per hour). Google sign-in and a password reset link
  count as verified. Accounts from before round 4 are verified. Unconfirmed sign-ups are purged after 7 days (leased job).
* **Old builds (< 10025).** They expect a token. Chosen (safe) default `REGISTER_VERIFY_LEGACY=verify`: they get the
  same verification, answered with `400 EMAIL_VERIFICATION_SENT` whose `error` ("Check your e-mail to finish creating your
  account. Open the link we sent you, then sign in here…") the old sign-up form shows as is, identical for every address.
  `allow` restores 201 + token / 409 for them (and the enumeration signal). API clients without a build header count as old.
* **Deletion from old builds.** `DELETE /api/me` from a legacy session without the password: `202 DELETE_CONFIRM_SENT`
  with a readable message, and "Confirm deleting your CoRoute account" (single use, 30 min, `/account#confirm-delete=…`,
  one more click). With the password in the body it deletes at once. Note: old builds treat any 2xx as done and sign
  out locally; the account stays until the link is opened.

### Round 4 endpoints

`POST /api/auth/ride-lock/code`, `/auth/ride-lock/verify`, `/auth/email/verify`, `/auth/register/resend`,
`/auth/mfa/email-code`, `/auth/delete/confirm` (public, rate limited); `POST /api/auth/mfa/step-up`,
`/auth/mfa/step-up/email-code`, `/me/mfa/email` (signed in); `GET /api/admin/riders/:id/ride-lock`,
`POST /api/admin/riders/:id/ride-lock/end` (admin).
