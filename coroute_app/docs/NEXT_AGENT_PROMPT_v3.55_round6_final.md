# CoRoute round 6: profile picture adjust, app audit fixes, business pages, clean-ups (build 3.55.0+10026)

Run AFTER round 4 (docs/NEXT_AGENT_PROMPT_v3.55_round4_intelligence.md) and round 5
(docs/NEXT_AGENT_PROMPT_v3.55_round5_infra.md) are applied. Rounds 4, 5 and 6 all ship as app build 3.55.0+10026 and
one gateway release. Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Round 3 (build 10025) is committed. Rounds 4 (road and safety intelligence), 5 (infrastructure and
speed) and 6 (this prompt) are in the working tree, uncommitted. Ship them together as build 3.55.0+10026.
Report after each section. STOP at any failed safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0.
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths. Real values live only in
  gateway/deploy/inventory.local.env (git-ignored) and on the VMs.
- Never weaken SOS, crash detection, emergency texts, Medical ID, the ride lock or the lock-screen cockpit.
- dart tool/play_policy_scan.dart must print 0 hits. Fix code, not tests, unless a text changed on purpose.
- If round 6 files are missing from the working tree, unpack coroute_v3.56_round6_files.zip: R6_BASE_MD5.txt lists the
  md5 each file was made from (repo md5 equal -> take the zip copy; different -> merge by hand; NONE -> new file).
  Do not commit R6_BASE_MD5.txt, _to_delete/ or _incoming/.
- Read first: docs/quality/ROUND6_APP_NOTES.md, docs/quality/ROUND6_GATEWAY_NOTES.md, docs/quality/APP_AUDIT_v3.56.md,
  docs/security/GIT_HISTORY_CLEANUP.md.

=== 1. URGENT BEFORE ANYTHING ELSE ===
 1. Two OS admin passwords are still in git history (removed from the files in round 5). Ask the owner to lock or
    rotate both accounts now. The optional history rewrite steps are in docs/security/GIT_HISTORY_CLEANUP.md - do NOT
    run them without the owner's yes.
 2. Fill gateway/deploy/inventory.local.env from inventory.example.env (new keys this round: OCI_TENANCY_OCID,
    OCI_COMPARTMENT_OCID, OCI_REGION and the others listed in ROUND6_GATEWAY_NOTES.md section 5). Scripts now stop with
    a clear message when a value is missing.

=== 2. WHAT IS NEW IN ROUND 6 ===
APP (details and file list: docs/quality/ROUND6_APP_NOTES.md)
 - Adjust profile picture: tap the picture in My profile -> Adjust picture / Take a new photo / Choose a new picture /
   Remove. Own cropper (round mask, drag, pinch zoom, rotate 90 degrees, reset, Save). The server keeps a private
   original (owner only, max 2048 px, 2 MB, EXIF/GPS stripped) plus the public round picture and crop numbers. Pictures
   uploaded before this round have no original, so Adjust works on the current picture. Same on the website /account
   ("Edit picture"). New routes are in gateway/src/social_routes.js (/api/me/avatar/*).
 - App audit (docs/quality/APP_AUDIT_v3.56.md, 32 findings; 2 high + 11 medium all fixed): replayed cached GPS fix,
   fix age on the wrong clock, stale/teleport fixes, parked-bike jitter, position stream never re-opened, battery prompt
   at every ride start, double tap on Start/Join, one notification per rider in batch frames, 48 dp map buttons, global
   error handler into the diagnostics log.
 - Lock-screen cockpit: a locked phone dials emergency lines (112, 108, 100, 1033) always and the rider's own emergency
   contact while their SOS/crash alarm is open; every other number waits for the unlock.
 - "Where riders stop" layer on the live ride map (off by default).
 - Risky-stretch hard-brake data now only from riders who opted in to "Help make roads safer"; warnings for everyone.
 - Private places (up to 3, on the phone only): within 300 m the route is not recorded, uploaded or used for road data.
   The live position during a ride is NOT hidden (group, guardian link, SOS need it).
 - Weather: gateway switched from Open-Meteo (non-commercial terms) to MET Norway (CC BY 4.0 / NLOD) behind
   WEATHER_PROVIDER=metno; credit "Based on data from MET Norway" in the app, API and privacy policy.
GATEWAY (details: docs/quality/ROUND6_GATEWAY_NOTES.md)
 - SAFETY-CRITICAL FIX: compare-and-replace now tests a scalar casRev on every document of the 15 compare-and-replace
   collections (the per-scalar precondition missed nested changes: job lease hand-back, coupon holds, a refund during an
   order claim). Old documents are handled on first use and seeded by the leased job cas-rev-seed.
 - Clean-ups: real OCIDs/IPs/e-mail/SSH public key removed from tracked deploy files and docs; route split classifies
   all 571 routes (96 LIVE, 475 WEB) and release.sh stops on an unclassified route; gateway/deploy/.env.example is
   tracked, placeholders only, and a test fails on an undocumented variable.
 - Business pages (web admin > Business, MASTER_ADMIN, nightly under the job lease): cohort retention, activation
   funnel, plan/coupon/campaign conversion, revenue and renewals, churn "At risk" list with win-back through the e-mail
   wizard (consent rules apply), best send time per rider, review list of payment/coupon/sign-up signals (never blocks),
   Monday 09:00 IST owner summary e-mail, Servers page.
 - Privacy policy: new sections "Understanding how CoRoute is used", "Profile picture", weather credit.

=== 3. COMMIT (after rounds 4 and 5 commits; git status shows no secrets, no real IPs) ===
 "fix(gateway): casRev precondition for every compare-and-replace", "feat(profile): adjust profile picture (app, web,
 gateway)", "fix(app): GPS accuracy, ride lifecycle and stability audit fixes", "feat(app): private places, rider stops
 on the ride map, lock-screen call rule", "feat(weather): MET Norway provider", "feat(web-admin): business pages, owner
 summary, servers page", "chore(deploy): inventory for real values, strict route split, tracked .env.example",
 "docs(v3.56): audit, round 6 notes, business analytics". Push.

=== 4. TEST AND BUILD ===
 1. cd gateway && npm ci && npm test -> expect 1343 passing (flaky alone-reruns: public_ride_mirror,
    two_node_failover, job_lease, login performance, email_marketing_357). npm audit --omit=dev -> 0 high/critical.
 2. Smokes print OK (Playwright installed; never reinstall): the round 3-5 smokes plus the business and cropper smokes
    named in the two ROUND6 notes.
 3. flutter pub get && flutter analyze && flutter test. NEVER RUN BEFORE (no Flutter in the dev sandbox): every test
    added in rounds 4, 5 and 6 (lists in the round 4 prompt, ROUND6_APP_NOTES.md section 4). Fix compile and test
    errors carefully, never by removing safety behaviour.
 4. dart tool/play_policy_scan.dart -> 0 hits.
 5. flutter build appbundle --release and flutter build apk --release --split-per-abi. First compile of the Kotlin
    added this round (cropper/image codec channel) and in rounds 3-4.

=== 5. STAGING FIRST (vm4) - MUST PASS BEFORE PRODUCTION ===
 1. Deploy to staging with gateway/deploy/release.sh (it stops at staging if a check fails).
 2. casRev on the real Oracle database (could not be tested in the sandbox): on staging run a coupon hold + release,
    a Razorpay test payment + refund, a job lease hand-back (restart one node), a session refresh. Check the documents
    carry casRev and no PATCH returns 4xx/5xx in the log. If Oracle rejects the new field: STOP and report.
 3. MET Norway: allow outbound api.met.no:443, set GEO_CONTACT (a contact e-mail or URL for the User-Agent, required by
    their terms), call /api/geo/weather once and check the credit line. The owner should read the NLOD 2.0 licence text
    once before release (ROUND6_APP_NOTES.md section 5 lists the URLs).
 4. Avatar: upload, adjust, re-adjust, remove on staging; the original is refused for another account.

=== 6. ENV (both production VMs, same values) ===
 - New optional vars (defaults fine): WEATHER_PROVIDER=metno, WEATHER_MET_URL, GEO_CONTACT (set it), BUSINESS_ANALYTICS=on,
   BUSINESS_PAGE_SIZE, BUSINESS_PAGE_PAUSE_MS, BUSINESS_MAX_RIDERS, BUSINESS_MAX_USERS, PEER_METRICS_URL, NODE_MEMORY_MB.
 - Servers page: on EACH VM add the other VM's private IP to METRICS_ALLOW (METRICS_ALLOW=loopback,<peer-private-ip>),
   or one METRICS_TOKEN in the Vault for both.
 - Round 4 and 5 env (INTEL_*, CRASH_BRAIN_MODE=shadow, INTEL_HASH_KEY in the Vault, LIVE_RIDER_CAP, DB limiter) as in
   their prompts.

=== 7. DEPLOY (release.sh: staging -> vm2 -> vm1, health check after each, automatic rollback) ===
 Encrypted backup + dry-run restore first. After both nodes run: /api/health HEALTHY, cas-rev-seed job finished (job
 list on the Servers page), website /account "Edit picture" works, /admin > Business loads (first numbers appear after
 the nightly job; run it once by hand as the notes describe).

=== 8. QA (report each; device checks on the release build from Play internal testing) ===
 - Picture P1.., GPS accuracy ride tests G1.., kill/recovery K1.., lock-screen L-items: docs/quality/ROUND6_APP_NOTES.md
   section 6.
 - Business B1.. and clean-ups C1..: docs/quality/ROUND6_GATEWAY_NOTES.md section 8.
 - Round 4 intelligence QA and round 5 infra checks: their own prompts.
 - EMERGENCY SAFETY GATE (any failure = STOP, no Play release): SOS with the screen locked, crash countdown, cancel
   window, "safe now", airplane-mode retry of emergency texts, SOS during a ride with the app killed and restarted,
   SOS from the lock-screen cockpit, Call 112 while locked.

=== 9. GOOGLE PLAY ===
 Upload 3.55.0+10026 to Internal testing. Data safety: no new data type this round (photos were already declared; the
 private original stays owner-only); the round 4 note on approximate location / app activity with consent still applies.
 Release notes: add "Adjust your profile picture", "Hazard and rough-road warnings", "More accurate speed and distance".

=== 10. OWNER DECISIONS TO ASK FOR ===
 - Lock/rotate the two leaked OS accounts; run the git history rewrite or not.
 - Weekly owner summary e-mail: on by default (administrators only) - keep?
 - METRICS_ALLOW (peer private IP) or METRICS_TOKEN for the Servers page.
 - The personal e-mail still in store/LISTING.md (public Play contact) and three Flutter test files: replace with a
   role address?
 - Open decisions from rounds 4 and 5 (rough-road warning default, minimum riders per spot, Ampere in tenancy 1, DR
   database, DNS provider, map tiles, LIVE_RIDER_CAP).

=== 11. REPORT ===
 Commit hashes, test counts (gateway, flutter test, analyze, policy scan), staging results (casRev on Oracle, MET
 Norway, avatar), deploy times, QA tables with phone model + Android version, Play status, open issues, decisions.
```
