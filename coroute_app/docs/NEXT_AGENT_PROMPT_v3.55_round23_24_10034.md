# CoRoute build 3.55.0+10034: release prompt (rounds 23 and 24)

Paste everything inside the block into the release agent.

```
You are the release agent for CoRoute (motorcycle group / solo riding SAFETY app: Flutter Android app + Node.js gateway
+ website + web admin + operator console). Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app,
branch release/v3.55.0. HEAD is b28909a (round 22, build 3.55.0+10033 on Play internal testing, gateway deployed).
Rounds 23 and 24 are in the working tree, uncommitted. Ship them as build 3.55.0+10034. Report after each section.
STOP at any failed safety gate.

=== 0. RULES ===
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths. Never commit _incoming/.
- Never hide or weaken SOS, the crash alarm, others' SOS banners, emergency texts, Medical ID, ride lock, lock-screen
  cockpit. Privacy zones must NEVER hide the position during an SOS / crash alarm / rider-down.
- Fix code, not tests, unless a text or layout changed on purpose (list every test you change and why).
- dart tool/play_policy_scan.dart -> 0 hits (the app never shows prices; expenses are records only).
- Read first: docs/features_355/communities_chat_v360.md sections 18 and 19, docs/features_355/trip_planning_lite_v363.md.

=== 1. WHAT IS NEW ===
Round 23 - pricing model switch (web admin > Configuration > Pricing model; default Group plans = today):
  Group plans (Community free + Small Group + Large Group bought by the host) OR Rider Pass (Community free + one
  monthly pass per rider, every feature, list price Rs 9, any number of riders join a pass holder's ride). Switching
  never cancels or refunds a running plan. The OWNER chooses the production model before launch: leave it on Group
  plans.
Round 24:
  A) Shareable ride card (WhatsApp square / Instagram Story) + rich WhatsApp invite preview (Open Graph on /join links).
  B) Guests and iPhone riders join from a browser (/ride/<CODE>): host approval, live map, browser position, SOS in/out.
  C) Trip planning lite: ride expenses ("who pays whom"), pre-ride checklist, weather at stops.
  D) Privacy zones (Profile > Privacy zones): position hidden near home / work; exact position always in an emergency.
  E) Admins: the app opens straight into the admin console (no "Admin" row in the rider profile); the website sends
     admins from /signin and /account to /admin.
  G) Web admin without duplicates (communities_chat_v360.md section 20): one Command center (Overview removed;
     Trends + Business summary in Business), one Settings (the portal), access mode and pricing only in Plans & pricing,
     e-mail settings only in E-mail. Old links redirect. Commit with 27.
  F) Download page: the 32-bit APK is labelled "old phones only" (64-bit-only phones like Galaxy S23/S24/S25 cannot
     install it).

=== 2. CHECK ===
git status --short must show only round 23/24 files (plus _incoming/). Report anything unexpected and stop.
Do NOT take pubspec.yaml from the sync zip (it was not included); the repo's version stays as it is until section 5.

=== 3. COMMITS (use git status so no changed file is left out) ===
23. feat(pricing): pricing model switch, Rider Pass (one rider, all features, 30 days, Rs 9 list price)
    gateway/src/pricing_model.js gateway/src/entitlements.js gateway/src/plans.js gateway/src/plan_pricing.js
    gateway/src/oracle/repo.js gateway/src/membership_routes.js gateway/src/subscription_routes.js
    gateway/public/admin/pricing_model.js gateway/public/assets/plans.js gateway/public/assets/account.js (Rider Pass
    label only if split is easy; else in 27) lib/presentation/admin/master_admin_dashboard.dart
    lib/presentation/admin/admin_users_screen.dart lib/presentation/admin/admin_payments_logic.dart
    gateway/test/pricing_model_363.test.js gateway/test/membership_plans.test.js gateway/test/plans_v2.test.js
24. feat(share): ride card for WhatsApp / Instagram, rich invite previews
    lib/domain/share/ride_card.dart lib/presentation/report/* lib/data/models/trip_report_model.dart
    lib/domain/timeline/timeline_text.dart gateway/src/invite_cards.js gateway/src/timeline.js gateway/src/report.js
    gateway/public/join*.html gateway/public/assets/og/* gateway/tool/og/* gateway/src/social_routes.js
    gateway/test/share_card_363.test.js test/ride_card_363_test.dart test/share_card_quick_reply_test.dart
25. feat(guest): riders without the app join from the browser
    gateway/src/guest_service.js gateway/public/ride/* gateway/src/route_policy.js gateway/deploy/route_split.md
    gateway/deploy/caddy/Caddyfile.vm1 lib/data/models/rider_model.dart gateway/test/guest_join_363.test.js
26. feat(trips): expenses, pre-ride checklist, weather at stops
    gateway/src/expenses.js gateway/src/weather_met.js gateway/src/geo.js lib/presentation/expenses/*
    lib/presentation/checklist/* lib/domain/expenses/* lib/presentation/trip_planner/* lib/presentation/home/ride_start_view.dart
    gateway/test/expenses_363.test.js test/trip_planning_lite_363_test.dart docs/features_355/trip_planning_lite_v363.md
27. feat(privacy): home / work privacy zones; admins open the admin console; download page note
    lib/domain/privacy/private_places.dart lib/data/services/private_places_store.dart lib/data/services/convoy_service.dart
    lib/domain/intel/intel_event.dart lib/data/services/intel_care_service.dart lib/main.dart
    lib/presentation/privacy/* lib/presentation/account/account_screen.dart lib/presentation/settings/private_places_card.dart
    lib/presentation/rider/live_cockpit_map_screen.dart lib/presentation/rider/rider_home_screen.dart
    gateway/src/convoys.js gateway/src/ws.js gateway/src/app.js gateway/src/auth.js gateway/src/routes.js
    gateway/public/assets/signin.js gateway/public/get.html gateway/public/admin/* (rest)
    gateway/test/privacy_zones_363.test.js test/privacy_zones_363_test.dart test/round6_wiring_356_test.dart
    test/access_control_and_admin_regression_test.dart gateway/test/intel_362_insights.test.js gateway/test/job_lease.test.js
    docs/features_355/communities_chat_v360.md docs/NEXT_AGENT_PROMPT_v3.55_round23_24_10034.md
    (Shared files such as convoys.js / ws.js / app.js / live_cockpit_map_screen.dart carry changes of several features:
    put each such file in the commit where most of its change belongs; correctness over perfect splitting.)
28. chore(release): 3.55.0+10034   pubspec.yaml (+ APK checksums as before)

=== 4. TESTS ===
- cd gateway && npm test -> 1532 tests, 0 failures. If public_ride_mirror, two_node_failover or jobs8/job_lease time
  out, re-run that file alone; a repeat failure alone is a real bug. Report which file needed a re-run.
- node deploy/gen_caddy_routes.js -> no diff after commit 25.
- flutter analyze -> 0 issues. flutter test -> all pass (new: ride_card_363, trip_planning_lite_363, privacy_zones_363,
  qa_double_tap_362). Widget tests never run before (written without the Flutter SDK): fix code first; list any test
  you change.
- dart tool/play_policy_scan.dart -> 0 hits.

=== 5. BUILD ===
- Bump pubspec to 3.55.0+10034 (commit 28). flutter build appbundle --release and the website APKs exactly as for
  10033 (64-bit arm64 main APK at public/coroute.apk; 32-bit at the 32-bit path).
- tool/check_16kb_alignment.sh on the AAB and both APKs -> all aligned.
- Confirm the main website APK is arm64-v8a (or universal). Galaxy S23/S24/S25 and Pixel 7+ cannot run 32-bit code.

=== 6. DEVICE QA (two Android phones incl. a Samsung Galaxy S24 or S23/S25 on One UI 6+, one iPhone with Safari,
    one tablet) ===
S) SAMSUNG S24 (owner report: "S24 kind of mobiles are not working"). On the S24:
   1. Uninstall any old CoRoute; install the NEW main APK from /download (not the 32-bit one). If the install fails,
      report the exact message.
   2. Open the app, sign in, grant location "Allow all the time", notifications, microphone, nearby devices.
   3. Start a ride: cockpit shows, position moves, screen off for 5 min: position keeps updating (the ride
      notification stays). Samsung battery: Settings > Battery > Background usage limits: CoRoute must NOT be in
      "Sleeping / Deep sleeping apps"; the app's own battery prompt must lead there.
   4. Talk (hold), hands-free, SOS hold, crash test mode, lock-screen cockpit, push with the app swiped away.
   5. If anything fails or crashes: adb logcat -d > s24.txt (or the app's diagnostics upload: web admin >
      Riders > the rider > Request app log) and send the log back to the owner; do not guess.
z14) Ride card: finish a ride -> trip report -> Share ride card -> WhatsApp square and Story; no route near the start,
     end or a saved privacy zone. Paste a ride invite link in WhatsApp: the preview card shows host first name, ride
     name, day.
z15) Browser rider: open the invite on the iPhone (Safari) -> "Join in your browser" -> name -> host taps Let in on
     the phone -> the iPhone sees the map and riders, shares position; the host sees the "Browser" badge; host raises
     SOS -> iPhone alarm (after one tap on the page); iPhone holds SOS 3 s -> the group gets the SOS; host removes the
     guest -> the page says removed.
z16) Expenses: add Fuel 600 paid by A split 3 ways on phone A; phone B sees it live; balances and "who pays whom"
     right; mark paid back. Checklist opens before Start / Join, "All good" works, never blocks. Weather line at stops.
z17) Privacy zone: save Home 500 m on phone A, start a ride at home: phone B and a guardian link show "Location hidden
     near a saved place" (no marker); ride out 550 m: A appears. Back inside the zone, raise SOS on A: B sees the
     EXACT position at once. Trip report / share card draw nothing inside the zone.
z18) Admin: sign in on the app with the admin account -> admin console directly (no rider home); profile has no Admin
     row. Website /signin as admin -> /admin. /account as admin -> /admin.
z20) Web admin: menu has one Settings (Configuration group), no Overview at the top, Business has Business summary +
     Trends; #/settings, #/settings/pricing, #/settings/email open Settings, Plans & pricing and E-mail > Settings.
z19) Pricing model (STAGING only): switch to Rider Pass -> /plans shows Community + Rider Pass Rs 9; test purchase;
     the pass holder hosts a ride that 15+ riders join; every feature works; switch back to Group plans; the pass
     keeps working until it ends. Production stays on Group plans until the owner decides.
Plus the safety regression: SOS, crash alarm, emergency texts, ride lock, Medical ID, lock-screen cockpit, closed-app
SOS push.

=== 7. DEPLOY ===
deploy/release.sh to both VMs as for 10033 (vm2 first, then vm1). After deploy: /api/health both nodes HEALTHY,
/ride/<code> page loads (CSP headers), a /join link shows og:title, web admin Configuration shows "Pricing model:
Group plans" and "Intelligence database: DB 1 only". Do not set INTEL_* variables (owner gives DB 2 details later).

=== 8. PLAY ===
Internal testing first. Release notes: "Share your ride as a card, friends without the app can join from their
browser, split ride expenses, a pre-ride checklist, weather at your stops, and privacy zones that hide where you
start and end (never in an emergency)." Data-safety form: no new data types leave the phone for privacy zones (kept
on the phone); expenses are user-entered records shared with the ride's riders (add "Other user-generated content" if
not already declared). Report the exact answers.

=== 9. REPORT TO THE OWNER ===
- S24 result (works / exact failure + log).
- Test counts, any re-run file, any test changed.
- Owner decisions still open: production pricing model (Group plans or Rider Pass), DB 2 details, iPhone app.
```
