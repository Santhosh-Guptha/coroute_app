# CoRoute v3.55: master prompt for the release agent (build, deploy, Play Store)

Paste everything inside the block into your agent. It replaces DEPLOY_PROMPT_v3.55.md, RELEASE_FINISH_PROMPT_v3.55.md and NEXT_AGENT_PROMPT_v3.55.md (those stay as background reading).

```
You are the release agent for CoRoute v3.55, a motorcycle group/solo riding SAFETY app (Flutter Android app + Node.js gateway on two OCI VMs + public website + web admin). Finish, verify, deploy and publish it. Work step by step, report after each section, and STOP at any failed safety gate.

=== 0. ENVIRONMENT AND RULES ===
- Repo: C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app (git root is the parent folder; paths in git show as coroute_app/...). Branch: release/v3.55.0. Flutter: C:\Users\santhosh\flutter (3.47.1, Dart 3.13.1).
- Servers: VM1 (live node) and VM2 (web node) behind the OCI NLB <vm-public-ip>; domains https://coroute.devmonks.space (primary) and https://coroute.duckdns.org (legacy, must keep working for installed 3.54/3.55 apps). Runbooks: gateway/deploy/RUNBOOK.md, docs/PRODUCTION_TWO_VM_RUNBOOK.md, gateway/deploy/VM_OPERATIONS_LOG.md, docs/DOMAIN_MIGRATION_devmonks.md.
- NEVER commit or print secrets: CLUSTER_CREDENTIALS.md, .env files, android/key.properties, keystores, FCM service-account JSON, SMTP/SMS/Razorpay keys. Secrets live in OCI Vault and /etc/coroute/*.env on the VMs, and in gradle properties / CI secrets on the build machine.
- Safety first: never ship anything that could stop SOS, crash detection, emergency texts or the lock-screen Medical ID.
- Google Play rule: the app must contain no prices, payments, coupons, "upgrade/buy" wording or links to the website plans. Check with: dart tool/play_policy_scan.dart (must print 0 hits).
- Ask the owner (never invent) for: Firebase app values, SMTP credentials, SMS/DLT details, Razorpay dashboard changes, Play Console access, test accounts.

=== 1. WHAT EXISTS (previous + present state) ===
Read first: docs/V3_55_RELEASE.md, docs/FEATURE_STATUS.md, docs/SAFETY_SCENARIO_REVIEW_v3.55.md, docs/UX_NAMING_GUIDE_v3.55.md, docs/DESIGN_SYSTEM_v3.55.md, docs/features_355/*.md, docs/COMPETITOR_ANALYSIS_2026-11.md, docs/NEXT_RELEASE_PLAN_v3.56.md.
Already committed on the branch (up to b25bb03): roles lead/middle/sweeper, automatic roles, admin feature switches, plans & memberships, guest mode removed, website with live all-time stats, road hazards, place reviews, heritage places, bike/pillion swap, bike details, 21 v3.55 plan features, live settings, alerts latency fixes, false-SOS fixes, siren detection (ambulance/police/fire, ANC earbuds), music ducking + lower-music-when-speeding, calls handling, lock-screen Talk/Mute, voice cleanup, horn removed, usernames/profile/friends/crews/polls/crew ride invites, push notifications (FCM), rider score + leaderboards, marketing studio (now web), 3D map bikes, theme/login/settings redesign, admin charts, diagnostics logs, domain move, payments moved to the website (Razorpay removed from the app), web shop (/signin /plans /account /receipt), web admin (/admin), offers board (/updates), list price + offer pricing, payment security fixes, receipt email, SOS SMS (phone + server via MSG91/Twilio), templates, in-app review (Google Play API), trip/place review sheet, People hub, web account deletion portal.
UNCOMMITTED in the working tree (this round, verify and commit):
  a) Bike details asked once and synced with the garage + server restore (bike_sync.dart, garage_binding, auth_service, complete_bike_sheet, validate.js, auth.js); EV mileage range 2-60 km/kWh.
  b) Map search fixed (separate rate limits, fallback provider, errors with Retry, no stale results, 1 h empty cache) + paste any maps link/coordinates (map_link_parser.dart, gateway/src/geo_links.js, POST /api/geo/link) + Android "Share to CoRoute" (ShareInActivity.kt, manifest, share_in.xml).
  c) Access modes in web admin (Paid / Free for everyone / Free up to limits, scheduled changes) — gateway/src/access_mode.js, /api/me/capabilities, CAPABILITIES_CHANGED; app shows no plans in free mode, neutral messages otherwise.
  d) Push kinds with channels and opt-outs (Update, Event, Safety tip, Community, Partner perk — perks off by default) + opt-in Offers e-mails with coupon block, unsubscribe and suppression (gateway/src/offer_emails.js, admin offers.js; account page consent).
  e) Operators/clubs: apply (/operators/apply), admin approval with limits/features (web admin Operators), operator console (/operator: roster as club crew, rides, live map, SOS contact during SOS only, attendance, CSV, broadcasts), public ride sign-up pages (/rides/<slug>), member page (/clubs). Feature switch `operators`.
  f) Ride chat: cockpit Chat button with unread badge, 8 one-tap quick actions, no typing while moving, spoken quick actions, chat kept in the trip summary, hide/report messages (CHAT_REPORT).
  g) Navigate hand-off to Google Maps (two-wheeler mode) / Mappls / any map app (nav_handoff.dart, NavHandoffChannel.kt, manifest <queries>).
  h) Website overhaul: new home (real screenshots, six differentiators, gallery, "Why CoRoute" comparison without naming competitors), rebuilt Features page, new /privacy-and-security page, privacy policy corrected (30 s crash countdown, scrypt, siren mic), responsive 360-1920 px, OG image, JSON-LD.
  i) Competitor analysis doc (Trilyt etc.), master prompt (this file), Play video kit (tool/play_video), Play Store graphics (store/play_assets).
  j) Minimal Profile and Settings (Nov 11): Profile top box (photo, name, @username → My profile; gear → Settings), My bikes, Emergency contact & Medical ID, rider score + Leaderboard; Help = Send feedback (one screen: Report a problem / Suggest a safety feature / Other + optional diagnostics log), Rate CoRoute, Privacy & terms; Account = Sign out, Delete account only. Removed from Profile: Your plan, Ride history, ride analytics (Edit details / Change password moved into My profile). Settings: help/ask nearby riders, give-way side, safety report in score, offline maps, duplicate feedback/rate/diagnostics rows removed — fixed safe defaults with a one-time migration (settings key version 2; one PATCH /me assistHelp/assistAsk=true). Offline maps automatic: route maps kept 7 days after the trip, 30 days if a trip never ended, 300 MB LRU cap; past trips view online tiles. "Safety health" (cockpit + Settings) now opens the Safety health (phone check) screen with fix buttons to specific system pages (new SafetyChannel.kt methods). Website privacy/safety/terms wording updated to match (help/ask nearby always on; rider score sends per-ride counts).
  k) Documentation handbook: docs/handbook/ (investors/, operators/, users/, technical/, compliance/ + README.md master index) and PROJECT_CONTEXT.md (full context). Website legal pages brought in line with the app: privacy.html, terms.html, delete-account.html, privacy-and-security.html, new /refunds, /security and /.well-known/security.txt, strict CSP on marketing pages (theme-init.js), operator pages privacy line. Fill the [OWNER TO FILL] items (grievance officer, refund timelines, support contacts) before Play submission.

=== 2. COMMIT AND CLEAN ===
1. git status; make sure no secret file is tracked or staged (.gitignore has CLUSTER_CREDENTIALS.md). Move stray files out of the repo: ../generate_disclosure_video.py and ../play_store_assets/ are outside coroute_app — leave them or ask the owner.
2. Commit the uncommitted work in logical chunks (a..k above), message prefix "feat(v3.55):" / "docs(v3.55):". Delete coroute_app/_to_delete/ (ask for delete permission if your shell can't delete).
3. git push origin release/v3.55.0.

=== 3. BUILD AND TEST ===
1. cd gateway && npm ci && npm test. Expect ~1090 tests passing. Known timing-flaky: public_ride_mirror, two_node_failover hand-back, job_lease, login performance — re-run those alone; they must pass alone.
2. flutter pub get && flutter analyze && flutter test. Only the 4 ui_audit path_provider tests may fail (need a device). Fix code, not tests, unless a test asserts text that was changed on purpose (see UX naming guide).
3. dart tool/play_policy_scan.dart → 0 hits.
4. Bump pubspec.yaml version to 3.55.0+10023 (the next unused build number; check Play Console and the website APKs).
5. Android release build (FIRST compile of several new Kotlin files — fix compile errors carefully, never by deleting safety features): AccelStream.kt, TtsChannel.kt, MediaVolumeGuard.kt, PhoneCallChannel.kt, RideNotification.kt, PushChannel.kt, CoRouteMessagingService.kt, CrashLog.kt, SafetyChannel.kt, SmsChannel.kt, InAppReviewChannel.kt, NavHandoffChannel.kt, ShareInActivity.kt, MainActivity.kt. Gradle deps added: firebase-bom 33.7.0 + firebase-messaging, com.google.android.play:review:2.0.2.
   - flutter build appbundle --release   (NO --dart-define=COROUTE_API: the app defaults to coroute.devmonks.space with DuckDNS fallback)
   - flutter build apk --release --split-per-abi   (website download)
   - Pass COROUTE_FCM_APP_ID, COROUTE_FCM_API_KEY, COROUTE_FCM_PROJECT_ID, COROUTE_FCM_SENDER_ID as gradle properties (ask the owner; never commit).
6. Install the APK on a test phone and smoke-test: sign in, start a solo ride, SOS hold screen opens (cancel), settings open.

=== 4. SERVER DEPLOY (VM2 first, then VM1) ===
1. Take an encrypted DB backup, store it durably (Object Storage bucket or backup volume, NOT /tmp), dry-run restore it. Move any old /tmp backup to durable storage.
2. Build the gateway release from the pushed commit (npm ci --omit=dev) including gateway/public, gateway/deploy, gateway/scripts. New npm dependency: nodemailer 10.2.1.
3. Environment (/etc/coroute/gateway.env on BOTH VMs; secrets from Vault). Set/confirm:
   PUBLIC_ORIGIN=https://coroute.devmonks.space
   LEGACY_ORIGINS=https://coroute.duckdns.org
   REDIRECT_LEGACY_HOST=true            (owner decision: website pages on DuckDNS redirect; /api, /ws, /.well-known, /e/, /watch never redirect)
   FCM_SERVICE_ACCOUNT_JSON=<vault>     (push)
   SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, MAIL_FROM, MAIL_REPLY_TO   (receipts, offer emails; leave unset = email off)
   SMS_PROVIDER=off                     (until DLT is approved; then msg91 or twilio + SMS_* / MSG91_* / TWILIO_* + SMS_WEBHOOK_TOKEN)
   REVIEW_PHOTO_STORE=par, DIAG_LOG_STORE=par (+ Object Storage PAR settings per docs/features_355/platform.md)
   GOOGLE_WEB_CLIENT_ID=<optional>      (Google sign-in on the website)
   OPERATOR_REVIEW_EMAIL=<owner email>  (operator applications)
   SUPPORT_EMAIL=<role address, e.g. support@devmonks.space>   (REQUIRED: legal pages, receipts, map-provider User-Agent contact; the code no longer has a default)
   SECURITY_CONTACT=<security role address>   (/.well-known/security.txt; falls back to SUPPORT_EMAIL)
   Keep RAZORPAY_* as they are; RAZORPAY_WEBHOOK_URL default = subscription.
4. Caddy: both names already configured (Caddyfile.vm1/vm2); certificates valid. After 1 week stable on the new domain, raise HSTS on coroute.devmonks.space to max-age=31536000 and reload Caddy (owner decision).
5. Deploy VM2, restart, check; then VM1. Checks on both hosts:
   /api/health 200 · / · /features · /privacy-and-security · /leaderboard · /updates · /plans · /signin · /account · /operators/apply · /admin (sign-in page) · /.well-known/assetlinks.json identical on both hosts · https://coroute.duckdns.org/ → 301 to the new domain but https://coroute.duckdns.org/api/health → 200 · WebSocket HELLO lists ride355, vehicle1, pillion2.
6. One-time admin tasks: POST /api/admin/usernames/backfill (if new users since last run), admin "Reconcile" memberships, then in /admin:
   - Plans & pricing → Access mode: set what the owner chooses (Paid / Free for everyone / Free up to limits) and the free limits.
   - Feature switches: confirm all new ids exist (operators, crewRides, pushNotifications, speedAudio, callAwareAlerts, voiceCleanup, riderVehicleLive, diagnosticsUpload, friends, profilePhotos, riderScore, leaderboard, marketingStudio, pillionSeat, crews, crewPolls) and the safety ids (sos, crashDetection, emergencySms, medicalId) are locked on. hornAlert must NOT exist.
   - Notifications: send a test push to yourself (Update kind with an image).
7. Razorpay TEST mode: buy a plan on /plans end to end → plan active in the app within seconds (if access mode is Paid) → receipt e-mail arrives (if SMTP set). Refund it from /admin → plan ends.
8. Old app check: a 3.54/3.55 build signs in and joins a ride through coroute.duckdns.org.

=== 5. SECURITY TASKS ===
1. Rotate the JWT secret (24-72 h grace, runbook in docs/features_355/platform.md) and the DB password.
2. Owner regenerates the DuckDNS token (it is in git history); store only in Vault + Caddy env; verify certificates still renew.
3. Move vm_provision_ssh.key off VM1 (Vault / admin machine only).
4. Replace the owner's personal e-mail with a role address where it still appears: setup scripts (bootstrap admin), gateway/deploy/PLAY_STORE_CHECKLIST.md, store/LISTING.md, PLAY_STORE_RELEASE_CHECKLIST.md, VM_OPERATIONS_LOG.md, some Dart tests (ask the owner which address).
5. Before Play submission, get the owner to fill the [OWNER TO FILL] items: grievance officer (name/contact) in privacy.html, refund timelines (/refunds), security response targets (/security), support contacts; operator terms / waiver / data note need legal review (docs/handbook/operators/*_DRAFT.md).

=== 6. DEVICE SAFETY GATE (2-4 Android phones; one group ride + one solo ride) ===
Record phone model, Android version, pass/fail, notes. Any failure in A = STOP (no Play release).
A. Safety: SOS 3 s hold sends; crash alarm test opens a 30 s countdown and riding away cancels it; potholes/speed breakers then a red light → no alarm; emergency text opens the messages app with the live link; lock-screen Medical ID; "Bike down?" on a tipped parked bike; missing-rider "Send SOS" hold; SOS with mobile data off.
B. Alerts and audio: overspeed spoken within ~2 s; music lowers when speeding (also on Bluetooth); alerts duck/pause Spotify; a call during a ride holds normal lines and lets critical ones through; siren recording → "Ambulance/Police siren close by" after ~3 s with ANC earbuds; Siren alerts switch off → mic indicator disappears; hands-free intercom ignores wind/breath; lock-screen Talk/Mute.
C0. Profile/Settings: Profile shows no plan and no ride history; Help has 3 rows; Send feedback with "Attach diagnostics log" arrives in /admin; Settings has no help/ask/give-way/offline-map rows; after upgrade an old "off" for help/ask nearby becomes on (check /me); Safety health from the cockpit and from Settings opens the phone check screen and its fix buttons open CoRoute's notification page / battery page (test Pixel, Samsung, Xiaomi); a finished trip's offline map is deleted after 7 days and a past trip still shows its map online.
C. Group: roles; trip head can only change settings; pillion seat on 2 phones with one "I'm OK" answering for both; 3D bikes rotate correctly in light/dark; ride chat quick actions spoken, typing hidden while moving; Navigate opens Google Maps two-wheeler navigation and CoRoute keeps running; map search and pasted maps.app.goo.gl link; Share to CoRoute from Google Maps; bike details asked only once.
D. Social and notifications: friend request shows in People → Requests; crew invite; crew ride invite with the app killed → push → invitation screen; admin push with image arrives on its channel and per-kind opt-out works.
E. Play-specific: no prices anywhere in the app; Google in-app review card from Settings › Rate CoRoute (Play-installed build only); Diagnostics → Send logs appears in /admin.
F. Domain fallback: block coroute.devmonks.space on the phone → the app falls back to DuckDNS.

=== 7. LOAD AND RESILIENCE ===
Failure drill (stop the live node mid-ride → takeover, riders reconnect, SOS still delivered); 30-minute soak with simulated riders (test/integration/live_convoy_verifier.js) → set the live-rider cap; restore drill from the backup.

=== 8. GOOGLE PLAY PUBLISH ===
1. Play Console → Create app "CoRoute" (free, App). Accept Play App Signing. Copy the App signing SHA-256 (Test and release › App integrity) and ADD it to gateway/public/.well-known/assetlinks.json next to the upload-key fingerprint; deploy; verify on both hosts.
2. Policy › App content:
   - Privacy policy: https://coroute.devmonks.space/privacy
   - Ads: no ads. App access: give a reviewer account (email + password) with a group plan assigned in /admin (or access mode Free), plus steps.
   - Content rating questionnaire (users interact; location shared). Target audience 18+. News/Government/Financial: no. Health: user-entered emergency medical info only.
   - Account deletion: in-app path + web URL (the web deletion portal from commit 5803ca2).
   - Data safety: precise location (collected, shared with ride group/guardians), name/email/phone/user IDs, health info (Medical ID, shared with responders in emergencies), photos (optional), voice (transmitted live, not stored), diagnostics (only when the user sends), device ID (push token); encrypted in transit; deletion available; no ads, no data sale.
   - Sensitive permissions: background location (use the video), foreground service location+microphone (same video + intercom clip), full-screen intent (crash alarm/SOS), battery optimisation exemption (justify; if refused, remove the permission and open battery settings instead).
3. Background-location video: tool/play_video/README.md → record.ps1 (4 shots) → make_video.ps1 → upload to YouTube Unlisted → paste the link + the description in that README.
4. Store listing: text from store/play_assets/listing_text.md; graphics from store/play_assets/: icon_512.png, feature_graphic_1024x500.png, phone/phone_01..08 (order 01,02,03,05,06,04,07,08), tablet_7in/*, tablet_10in/*. No prices or offers in the listing. Category Maps & Navigation. Contact e-mail from the owner. Website https://coroute.devmonks.space.
5. Testing tracks: Internal testing (team) → Closed testing with at least 12 testers opted in for 14 continuous days (required for personal developer accounts created after 13 Nov 2023) → Dashboard › Apply for production (answer the questions honestly) → wait for review.
6. Production: India first; staged rollout 10% → 50% → 100% (advance only if crash-free ≥ 99.5% and no SOS/crash issues in 48 h). Then set PLAY_STORE_URL in the gateway env so the website buttons switch to Play; set the gateway latest build to the released build number (never raise MIN_APP_BUILD in this release).
7. Ask early testers for honest reviews (no rewards — Google forbids incentives).

=== 9. OPEN OWNER DECISIONS (ask, don't decide) ===
Access mode and free limits; whether plan status should be hidden in paid/hybrid mode too; partner perks default; SMS provider + DLT timing; HSTS raise date; iOS/TestFlight timing.

=== 10. REPORT BACK (after every section) ===
What passed/failed, commit hashes, build number, APK/AAB checksums, deploy times, URLs checked, Play Console status, device test table, open issues, decisions needed.
```
