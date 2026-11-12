# CoRoute v3.55 round 3: full prompt for the release agent (12 Nov 2026)

Covers everything done on 12 Nov 2026 after build 3.55.0+10024 (HEAD 0eb61ac):
A) web admin Riders + simple e-mail wizard + console and /account clean-up,
B) sessions & security, C) ride lock + sign-up verification + remaining security items,
D) cockpit on the lock screen + Ride AOD + Android 16 Live Update.
Ships the gateway/website AND app build 3.55.0+10025. Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway on
two OCI VMs + website + web admin + operator console). Build 3.55.0+10024 is deployed. Ship the next increment: commit,
test, build 3.55.0+10025, deploy the gateway (VM2 then VM1), QA, Play internal testing. Report after each section.
STOP at any failed safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0, Flutter
  C:\Users\santhosh\flutter. Background: PROJECT_CONTEXT.md, docs/MASTER_AGENT_PROMPT_v3.55.md (deploy + Play sections),
  docs/NEXT_AGENT_PROMPT_v3.55_round2.md, docs/handbook/README.md.
- The changes are already in the working tree (uncommitted, ~150 files). If any are missing, they come as
  coroute_v3.55_round3_files.zip (full files made against a510e31; BASE_MD5_a510e31.txt has the base md5 of each MODIFIED
  file: repo md5 == base -> take the zip copy; different -> merge by hand; pubspec.yaml keeps 3.55.0+10025).
- Never commit or print secrets (CLUSTER_CREDENTIALS.md, .env, key.properties, keystores, FCM JSON, SMTP/Razorpay keys,
  DATA_ENC_KEY, BLIND_INDEX_KEY). Secrets live in OCI Vault and /etc/coroute/*.env or /run/coroute/secrets.env.
- Do not commit _to_delete/, _incoming/, BASE_MD5_a510e31.txt or ../.dart_tool. Delete coroute_app/_to_delete/ after the commit.
- The app shows no prices/payments/coupons: dart tool/play_policy_scan.dart must print 0 hits.
- Never weaken SOS, crash detection, emergency texts, the lock-screen Medical ID or "Call 112". Fix code, not tests,
  unless a text changed on purpose.

=== 1. WHAT IS NEW ===
A) WEBSITE: web admin Riders, e-mail wizard, consoles (gateway + gateway/public only)
   - Riders (docs/features_355/web_riders_admin.md): gateway/src/admin_riders.js + public/admin/riders.js. List/search/
     filters, rider page (no phone or medical data), Assign plan (existing admin grant + "Plan assigned" e-mail, once),
     personal single-use coupon bound to the rider + "Coupon for you" e-mail (only with Offers consent, or a noted
     "service message"; otherwise the code is shown to share by hand), 1:1 e-mail, global search, GET /api/me/coupons.
     Endpoints: GET /api/admin/riders, GET /api/admin/riders/:userId, POST /api/admin/riders/:userId/{preview,email/check,
     assign-plan,coupon,email}, GET /api/admin/search?q=, GET /api/admin/email-wizard/templates (MASTER_ADMIN, rate
     limited, audited). Templates plan_assigned and coupon_gift (Settings > Templates).
   - E-mail wizard (docs/features_355/email_marketing.md "The wizard"): ONE menu item "E-mail", 3 steps Who / What /
     Check & send, tabs History / Automations / Templates / Settings; "Push notifications" is push only. Files:
     public/admin/email_wizard.js (new), email_studio.js, notify.js, src/email_marketing.js (sendDirect; account notices
     to up to 50 named riders: NEW behaviour), src/templates.js, src/notifications.js.
   - Console (docs/features_355/web_admin.md): grouped menu, Overview, global search ("/"), Settings hub, Audit log,
     tablet drawer, light/dark; public/admin/index.html, admin.js (old links redirect), console.js (new), admin.css.
   - Rider console /account: profile, plan, Your coupons, payments + receipts, recent rides (/trip/<id>), clubs,
     e-mail choices, security; public/account.html, assets/account.js, shop.css.
B) SECURITY ROUND 3: sessions, sign-out, 2-step, encryption (docs/features_355/sessions_and_security.md,
   docs/security/SECURITY_AUDIT_v3.55.md, gateway/deploy/RUNBOOK.md "Sessions & security")
   - Gateway: server-side sessions (collection auth_sessions, created at boot), 15-min access + rotating refresh tokens
     with reuse detection (app >= 10025, website, consoles); older builds keep their tokens, bound to sessions silently;
     logout / logout-all / sessions list; idle + absolute lifetimes; revoke on password change/reset, e-mail change,
     hold/block, deletion, losing admin; account lock after 10 wrong passwords; password rules; reset links (30 min,
     once); re-auth for sensitive actions; new-device e-mail; TOTP 2-step + recovery codes; AES-256-GCM field encryption
     (phone, emergency contacts, medical, TOTP secrets; lazy migration; e-mail blind index); log redaction; strict CSP;
     no-store on /api and private pages; WebSocket Origin check; route permission table test; npm audit fixed.
     New: src/sessions.js, security_routes.js, field_crypto.js, redact.js, totp.js, password_policy.js, route_policy.js,
     scripts/admin_mfa_reset.js, scripts/encrypt_fields.js.
   - Website: refresh token in an httpOnly __Host- cookie; idle sign-out (site 60 min; /admin and /operator 30 min with a
     2-min warning); sign-out -> home page /; Back after sign-out shows nothing private; /account "Where you're signed
     in" + "Sign out of all devices" + change e-mail; /signin forgot password + 2-step; /admin 2-step set-up.
   - App: tokens in the keystore; refresh once, then sign-out; Sign out dialog (this phone / all devices, "Keep emergency
     info on this phone" default on) -> server revoke + push token removed + wipe -> welcome screen, Back cannot return;
     NEVER signed out during a ride / SOS / crash countdown / convoy / pending emergency texts (SessionGuard); delete
     account asks for the password; "Emergency? Call 112" on the sign-in screen;
     android/app/src/main/res/xml/data_extraction_rules.xml (manifest needs it; it is UNTRACKED today: commit it).
C) SECURITY ROUND 4: ride lock and remaining items (sessions_and_security.md §9-§12, RUNBOOK "Round 4 security")
   - Ride lock (owner rule: no sign-in on another device while the current device is on an active ride): every sign-in
     route returns 423 RIDE_ACTIVE_ELSEWHERE "You're on a ride on <device>. End the ride on that phone to sign in here."
     (password checked first; no location shown). Same device id may sign in again; unlocks when the ride ends or the
     riding phone is unseen 10 min; already signed-in other devices cannot start/join a ride (409). Escape: 6-digit
     e-mail code (10 min, 5 tries) -> new device signed in, group told "<rider> switched phones", open SOS untouched,
     old session revoked, notice e-mail. Admin: rider page "On a ride" + "End ride lock" (reason, audited).
     New: src/ride_lock.js, email_codes.js, security_emails.js; app lib/presentation/auth/ride_lock_dialog.dart.
   - Sign-up verification: register always answers the same 202 + verification link (24 h); already-registered address
     gets "Someone tried to create an account" instead of 409; unverified accounts purged after 7 days; old builds get a
     readable message (REGISTER_VERIFY_LEGACY=verify). App "Check your inbox" screen.
   - Old builds deleting without a password: 202 + e-mail confirmation link (30 min, once).
   - Admin 2-step in the app (MFA prompt); e-mail code fallback for operators; ADMIN_MFA_ENFORCE default = all
     (builds < 10025 keep the web-only rule).
   - App lock (optional fingerprint / screen lock, off by default; never during a ride; SOS / 112 / Medical ID work
     locked): AppSecurityChannel.kt, app_lock_service.dart, app_lock_gate.dart, app_lock_policy.dart.
   - FLAG_SECURE only on sign-in, the code dialog, Medical ID form, 2-step prompt (secure_screen.dart).
   - WebSocket token sent as the first message (old ?token= still accepted); revoked session during a ride = safety-only
     socket (sends own SOS/crash/position, receives nothing).
   - Certificate pins in res/xml/network_security_config.xml (ISRG X1/X2 + USERTrust RSA/ECC + Sectigo backups; only the
     two CoRoute hosts; expiration 2027-11-01; debug builds bypass).
   - HSTS configurable (HSTS_MAX_AGE, HSTS_PRELOAD).
D) COCKPIT ON THE LOCK SCREEN + RIDE AOD (app only; docs/features_355/lock_screen_cockpit.md)
   - During a ride, signed in, setting on ("Show cockpit on lock screen while riding", default on, same key as 3.54) and
     the cockpit in front: MainActivity shows over the keyguard (RideWindowChannel.kt). Never turns the screen on for it.
     Locked mode: padlock chip; private screens/actions need the unlock (requestDismissKeyguard) and continue after it;
     chat shows "New message from <name>" only; Back does nothing; off at ride end / sign-out.
   - Ride AOD after 30 s idle (When idle: Ride AOD / Dim / Sleep), burn-in shift each minute, alerts wake the full
     cockpit; Keep screen on: Only while moving (default; sleeps after 2 min stopped: NEW behaviour) / Always during a
     ride; battery < 15 % and thermal critical -> sleep with a notice; thermal severe -> AOD after 10 s.
   - Android 16 Live Update for the ride notification (POST_PROMOTED_NOTIFICATIONS, normal permission; reflection for
     API 36 calls; no dependency bump; no USE_FULL_SCREEN_INTENT). On Android 16 the notification has max 3 buttons.

=== 2. COMMIT (after git status shows no secrets staged) ===
 1. "feat(web-admin): riders, assign plan, personal coupons, 1:1 e-mail"
 2. "feat(web-admin): simple e-mail wizard, console navigation, rider account console"
 3. "feat(security): server sessions, sign-out everywhere, idle sign-out, 2-step, field encryption"
 4. "feat(security): ride lock, sign-up verification, app lock, pins, safety-only sockets"
 5. "feat(app): cockpit on lock screen, Ride AOD, Android 16 live update"
 6. "docs(v3.55): security audit, sessions, lock-screen cockpit, handbook, round 3 prompt"
 7. "chore(release): 3.55.0+10025". Delete _to_delete/. Push.

=== 3. TEST AND BUILD ===
 1. cd gateway && npm ci && npm test -> expect 1197 passing (flaky alone-reruns: public_ride_mirror, two_node_failover,
    job_lease, login performance). npm audit --omit=dev -> 0 high/critical.
 2. Smokes (Playwright installed; never reinstall), each prints OK, look at the screenshots:
    node tool/web_console_smoke.js <dir>; node tool/web_admin_smoke.js <dir>; node tool/operators_smoke.js <dir>;
    node tool/security_smoke.js <dir>; node tool/security_round4_smoke.js <dir>.
 3. flutter pub get && flutter analyze && flutter test. These new/changed tests have NEVER run (no Flutter in the dev
    sandbox) - fix compile/test errors carefully, never by removing safety behaviour:
    test/session_security_357_test.dart, account_security_round4_test.dart, lock_screen_cockpit_policy_test.dart,
    ride_aod_policy_test.dart, next_turn_live_update_test.dart, settings_lock_cockpit_migration_test.dart,
    locked_cockpit_gate_test.dart, ride_aod_view_test.dart, settings_minimal_355_test.dart, network_settings_test.dart,
    network_settings_ui_test.dart, ride_notification_service_test.dart.
 4. dart tool/play_policy_scan.dart -> 0 hits.
 5. flutter build appbundle --release and flutter build apk --release --split-per-abi (no COROUTE_API; COROUTE_FCM_*
    gradle properties). FIRST compile of the new Kotlin: AppSecurityChannel.kt, RideWindowChannel.kt, changed
    MainActivity.kt, SafetyChannel.kt, RideNotification.kt (compileSdk 37, minSdk 23). Resource linking must pass with
    data_extraction_rules.xml and network_security_config.xml.

=== 4. ENV AND KEYS (both VMs, SAME values) ===
 1. NEW SECRETS (OCI Vault -> /run/coroute/secrets.env; never git, never gateway.env):
    DATA_ENC_KEY and BLIND_INDEX_KEY (each: openssl rand -base64 32). Back both up offline: losing DATA_ENC_KEY loses the
    encrypted phone numbers / contacts / medical details. Add the Vault OCIDs to the secrets mapping (setup_node.sh prints
    the template lines). DATA_ENC_KEYS_PREVIOUS only during a rotation.
 2. gateway.env (non-secret): DATA_ENC_KEY_ID=k1. Defaults are fine for the rest (see gateway/deploy/.env.example):
    ADMIN_MFA_ENFORCE=all, RIDE_LOCK=on, RIDE_LOCK_STALE_MIN=10, EMAIL_CODE_TTL_MIN=10, EMAIL_CODE_MAX_TRIES=5,
    REGISTER_VERIFY_TTL_HOURS=24, REGISTER_PURGE_DAYS=7, REGISTER_VERIFY_LEGACY=verify, MODERN_APP_BUILD=10025,
    DELETE_CONFIRM_TTL_MIN=30, WS_AUTH_TIMEOUT_MS=5000, ACCESS_TOKEN_TTL_MIN=15, SESSION_* lifetimes, LOGIN_LOCK_*,
    PASSWORD_RESET_TTL_MIN=30, HSTS_MAX_AGE=31536000, HSTS_PRELOAD=false.
 3. Confirm set: SMTP_HOST/PORT/USER/PASS, MAIL_FROM, MAIL_REPLY_TO, MAIL_POSTAL_ADDRESS, PUBLIC_ORIGIN, SUPPORT_EMAIL,
    JWT_SECRET (same on both nodes). SMTP MUST work: sign-up is impossible without the verification e-mail.
 4. Caddy: redact token= from access logs (RUNBOOK "Round 4 security").

=== 5. DEPLOY GATEWAY + WEBSITE (VM2 then VM1) ===
 1. Encrypted DB backup to durable storage + dry-run restore BEFORE deploying.
 2. Nothing to migrate at deploy: auth_sessions is created at boot; field encryption is lazy. Both nodes need the same
    DATA_ENC_KEY / BLIND_INDEX_KEY / JWT_SECRET before VM1 restarts (the mirror carries session revokes; an older peer
    ignores them safely during the minutes between restarts).
 3. Deploy VM2, restart, check: /api/health (dataEncryption = ON; KEY_MISSING = keys differ, fix first), /admin loads
    (2-step set-up), /account, /signin, /operator, no console errors. Then VM1, same checks.
 4. Optional after both run with keys: node scripts/encrypt_fields.js (dry run) then --write.
 5. MIN_APP_BUILD stays unchanged. Update the website APKs + SHA256SUMS and the gateway latest build to 10025.
 6. Hard-refresh browsers (admin assets are versioned).

=== 6. QA (production, test accounts; device checks on the RELEASE build from Play internal testing; report each) ===
WEBSITE
 1  /admin opens on Overview; "/" search finds a rider by username and e-mail, an order id, a coupon code.
 2  Riders: search, filters, sort, pages; no phone or medical data anywhere.
 3  Rider page: plan + payments, coupons, e-mail choices (read-only), rides, diagnostics, audit trail.
 4  Assign Small Group 30 days with a reason, e-mail on: rider's app shows the plan within seconds; exactly one "Plan
    assigned" e-mail (Gmail + Outlook inbox); audit row. "Until a date" works; missing reason refused.
 5  Personal coupon, rider WITHOUT offer consent: e-mail off with explanation, code + link shown; tick "service message"
    + note -> e-mail goes, note in audit. Rider WITH consent: offer e-mail with unsubscribe; code works once on /plans for
    that rider only (Razorpay test mode); /account > Your coupons lists it.
 6  E-mail wizard, one rider, quick account message: checklist green, sent, result card; suppressed address -> Send disabled.
 7  Several riders (account message) and an audience offer (Festive offer + coupon + unique codes): live counts,
    preview mobile/dark, Send test to me, schedule 10 min ahead -> sends; History shows results.
 8  Old bookmark /admin#/notifications/email opens E-mail; Settings > Templates edits "Plan assigned".
 9  /account phone + desktop, light + dark: all sections; recent rides open /trip/<id>; e-mail switches save.
 10 Tablet 1024 px: admin drawer opens/closes (Escape), dialogs fit.
SESSIONS (round 3)
 S1  App: Sign out (keep emergency info ticked) -> welcome screen; Back does NOT return; lock-screen Medical ID still there.
 S2  Sign out with the box unticked -> lock-screen card cleared.
 S3  In a convoy ride, Sign out -> "You can sign out after the ride"; end ride -> signed out within ~15 s.
 S4  In a ride, "Sign out of all devices" from /account on a laptop -> phone keeps the ride, SOS still texts the contact;
     signed out after the ride. S5 same during a crash countdown / open SOS.
 S6  Signed out: "Emergency? Call 112" dials; lock-screen Medical ID opens.
 S7  An OLD build (10024) signed in before the deploy keeps working; /account lists it; "Sign this device out" works.
 S8  New build: 20 min in background -> no sign-in asked; 1 h airplane mode in a ride -> never signed out.
 S9  Password changed elsewhere -> this phone signed out (not during a ride); delete account asks for the password.
 S10 Website: sign out -> home page; Back shows no account data; second tab stays signed in; idle 60 min -> signed out.
 S11 Forgot password -> link once, 30 min -> every device signed out; old link fails.
 S12 10 wrong passwords -> "Too many attempts" + one e-mail; works after 15 min.
 S13 Change e-mail (password) -> link to new address, notice to old; after confirming every device signed out.
 S14 /admin: first sign-in forces 2-step (store the 10 recovery codes OFFLINE); recovery code works once; 28 min idle ->
     "Still there?" -> 30 min signed out; Sign out -> home page. S15 /operator: idle warning + sign-out -> home page.
 S16 New-device e-mail on a new phone/browser (not for the first device).
 S17 curl -sI: /api/me and /account no-store; HSTS present; CSP without 'unsafe-inline' script.
 S18 Both nodes dataEncryption ON; a test rider's phone fields in the DB start with "enc:v1:".
RIDE LOCK AND ROUND 4
 R1  Phone A on a solo ride -> sign in on phone B: "You're on a ride on <A>" dialog, Call 112 visible; same on /signin,
     /admin, /operator, Google sign-in. Wrong password still "Invalid credentials".
 R2  B: Send code to my e-mail -> code arrives, resend counts down; wrong code shows tries left; right code signs B in;
     A signed out but SOS on A still reaches the group and contact; group sees "<name> switched phones"; notice e-mail.
 R3  Open SOS on A, then R2 on B: SOS stays open for the group and on the live link.
 R4  End the ride on A -> B signs in at once. A in airplane mode 11 min -> B signs in.
 R5  Force-stop / reinstall on A during its ride -> sign in on A again works.
 R6  A tablet signed in before the ride cannot start or join a ride during it.
 R7  /admin rider shows "On a ride (<A>)"; End ride lock (reason) -> B can sign in; audit row.
 R8  App lock on: kill + reopen -> lock; SOS, Call 112, Medical ID work locked; 5 min background -> lock; NEVER locks
     during a ride / convoy / crash countdown. Android 8: screen-lock confirmation. No screen lock on phone: explained.
 R9  FLAG_SECURE: screenshots blocked on sign-in, code dialog, Medical ID form, 2-step prompt; allowed on map/cockpit.
 R10 Admin screens in the new app: 2-step prompt -> code -> loads; recovery code once; old build admin still works.
 R11 Pins (release build): works on coroute.devmonks.space and coroute.duckdns.org; with a mitm user CA the release build
     REFUSES the gateway (debug accepts); map tiles still load.
 R12 Sign-up app + website: "Check your inbox" -> link -> sign in works; before the link "Confirm your e-mail first";
     same address again -> same screen + "Someone tried..." e-mail to the owner.
 R13 Old build (10024): sign-up shows the readable message; ride lock sentence shown; Delete account -> local sign-out,
     e-mail link deletes; sockets connect.
 R14 No "token=" in any Caddy/proxy log line; sockets reconnect after a gateway restart.
 E-mails to check in Gmail AND Outlook (inbox not spam, dark mode, links/code readable): Confirm your e-mail, Someone
 tried to create an account, Ride sign-in code, Signed in during a ride, Confirm deleting your account, Your CoRoute
 sign-in code (operator), New sign-in, Sign-in paused, Password changed, Plan assigned, Coupon for you.
LOCK-SCREEN COCKPIT AND RIDE AOD (Pixel on Android 16 + one Samsung + one Android 7-9 phone)
 L1  Power press during a ride (solo and group) -> wake: cockpit without unlocking, live updates; same after timeout;
     the screen never wakes by itself on a normal update.
 L2  Locked: Chat, rider card, End ride, Settings, Share ETA -> unlock sheet; after fingerprint/PIN the action continues;
     Cancel -> back to the cockpit.
 L3  Locked: SOS hold, I'm OK, Call 112, Medical ID, Mute/Unmute, Talk work without unlocking; Back does nothing;
     crash countdown and others' SOS still show over the lock screen.
 L4  Locked chat shows "New message from <name>" only; text after unlocking.
 L5  Ride ends while locked -> normal lock screen at once; after sign-out never the cockpit; setting off -> normal lock screen.
 L6  Unlock, open chat, power -> normal lock screen; back on the cockpit -> cockpit again.
 L7  30 s idle -> Ride AOD (speed, next turn, leader distance, time, battery, Hold SOS); shifts each minute; tap ->
     full cockpit; Hold SOS works on the AOD; Dim / Sleep options behave as named.
 L8  On the AOD: another rider's SOS, crash countdown, siren, off-route, regroup -> full cockpit at normal brightness.
 L9  Only while moving: stopped 2+ min -> may sleep with notice; Always: on until 5 min parked; battery < 15 % ->
     sleeps; heat (adb shell cmd thermalservice override-status 3 / 4) -> AOD after 10 s / sleep; reset after.
 L10 Android 16 Pixel: Live Update chip, lock screen + AOD, progress bar, SOS/Talk/Mute/Map; Live updates off ->
     old notification. Samsung One UI 8: note Now Bar. Android 13-15 unchanged.
 L11 Battery: 1 h ride each with Ride AOD, Dim, Sleep -> report % per hour (hints say 6-10 %/h screen on, 2-4 %/h AOD).
 L12 App lock never shows during the ride (also over the lock screen); locks again after the ride. Android 8/9 L1-L3 work.
EMERGENCY SAFETY GATE (any failure = STOP, no Play release): re-run round 2 section 6 (emergency texts: SOS with the
 screen locked, crash countdown, cancel window, "safe now", airplane mode retry) and MASTER_AGENT_PROMPT section 6 A
 on the 10025 release build, now also with the cockpit shown over the lock screen.

=== 7. GOOGLE PLAY ===
 1. Upload 3.55.0+10025 to Internal testing; run section 6 device checks on the Play-installed build.
 2. Data safety: add "Device or other IDs - collected, used for security / fraud prevention, not shared" (hashed
    Android id + random install id sent at sign-in). Privacy policy already updated; check the link.
 3. POST_PROMOTED_NOTIFICATIONS is a normal permission: no declaration form; mention nothing else changed in the SMS
    declaration. No USE_FULL_SCREEN_INTENT change.
 4. Release notes (docs/handbook/users/release_notes_v3.55_users.md), add: "Your ride screen now shows when you wake the
    phone during a ride, without unlocking.", "Stronger sign-in: sign out of all devices, optional fingerprint lock,
    no sign-in on another phone while you're riding."
 5. Continue the remaining Play steps (closed testing 12+ testers for 14 days, production application, staged rollout).

=== 8. OWNER DECISIONS TO ASK FOR (do not change without an answer) ===
 - Keys created and backed up (section 4.1).
 - When to raise MIN_APP_BUILD to 10025 (then ADMIN_MFA_ENFORCE=strict); until then old builds keep weaker deletion.
 - HSTS raise dates for coroute.devmonks.space (RUNBOOK ramp-up; preload not recommended).
 - Certificate pin check before each release (RUNBOOK rotation checklist; pins expire 2027-11-01).
 - "Only while moving" default (screen sleeps after 2 min stopped) - keep, or make "Always during a ride" default.
 - Still open: maps/routing decision (round 2 section 8), grievance officer and refund timelines.

=== 9. REPORT ===
Commit hashes, build number, APK/AAB checksums, deploy times, test counts (gateway, flutter test, analyze, policy scan),
smoke results, QA table (1-10, S1-S18, R1-R14, L1-L12, safety gate) with phone model + Android version and screenshots of
failures, e-mail inbox/spam results, battery numbers (L11), Play Console status, open issues, decisions needed.
```
