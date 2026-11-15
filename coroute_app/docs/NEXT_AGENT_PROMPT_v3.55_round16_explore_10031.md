# CoRoute build 3.55.0+10031: release prompt (round 16, Explore admin + rider routes + own look + alignment)

Paste everything inside the block into the release agent.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Build 3.55.0+10030 is committed (latest commit 1a2356a). Round 16 is in the working tree,
uncommitted, and ships as build 3.55.0+10031 (pubspec already 3.55.0+10031). Commit, test, build, device QA, deploy
gateway + website, Play screenshots, Play internal testing. Report after each section. STOP at any failed safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0.
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths.
- Never hide or weaken SOS, the crash alarm, others' SOS banners, the rescue finder, warnings, Medical ID, ride lock,
  lock-screen cockpit, app lock. The Home Emergency key must stay solid red, first on screen and one tap away.
  Fix code, not tests, unless a text or layout changed on purpose (list each such test change in the report).
- dart tool/play_policy_scan.dart -> 0 hits.
- Competitor app: layout ideas only. No copied brand, text, icons, colours or screenshots.
- Read first: docs/features_355/explore_v359.md (the whole round), gateway/src/explore.js header comment.
- Do not commit _incoming/ (transfer zips; delete them after the commit).

=== 1. WHAT IS NEW ===
A) EXPLORE, CONFIGURED BY ADMIN (gateway/src/explore.js, gateway/public/admin/explore.js,
   lib/presentation/admin/admin_explore_screen.dart)
   - One config document: headline, subtitle, sections (featured "Picked for you", rider_routes "Ridden by CoRoute
     riders", near_you, categories, suggest: on/off, title, order), categories (6 built-in renamable/hideable + up to 6
     custom; a used category cannot be removed: 409 IN_USE; hiding one hides its places), featured (<=12 ids), rider
     route switches.
   - GET /api/public/explore (public, ETag, 120 s). GET|PUT /api/admin/explore/config (MASTER_ADMIN, audited).
     The old GET /api/public/destinations stays for older apps; the app falls back to it on 404.
   - Web admin: Website & community > Explore (destinations add/edit/photo/hide/delete with route counts; layout &
     categories; rider route moderation with a map preview). In-app admin: Content > Explore (places show/hide,
     star = featured; layout; routes hide/show/delete).
B) REAL RIDERS' ROUTES, OPT-IN, USERNAME SHOWN ("be the first to guide others")
   - Trip report card "Guide other riders to <place>" only when the ride passed within 3 km of an Explore place.
     Nothing is sent until the consent box is ticked and Share is tapped. Optional tip (140).
   - Phone and gateway both drop the first and last 1 km; gateway simplifies to <=300 points, no time of day, IST
     day only, username required (409 USERNAME_REQUIRED), <=3 per rider per place, 10 shares/day, <=2000 km,
     no 50 km gaps. Answer says if the rider is the first.
   - Ride detail: "Ridden by CoRoute riders" cards + the selected route on the map; none yet: "Ride it and be the
     first to guide others". Signed-in riders only; no user ids in the list.
   - Delete: Profile > My shared routes, moderator (audited), account deletion cascade (repo.deleteUserCascade).
   - Feature flag exploreRoutes (Community). Privacy page section "Routes you share on Explore" (#shared-routes).
   - route_policy.js + deploy/route_split.md: /api/explore/* is WEB; /api/public/explore is public.
C) COROUTE'S OWN LOOK (same features)
   - Bottom bar: rounded top, centre road-shaped "Ride" key (nav_plus key kept), amber lane marks under the selected
     tab. Home opens with the safety panel (readiness line, check rows, red Emergency), then "Your next ride".
     Explore: map strip, postcards, route tickets, squared chips. Shared visuals in lib/core/ui/route_visuals.dart
     (RoadStripe, RoadSectionHeader, RouteSparkline).
D) ALIGNMENT / TEXT OVERFLOW
   - tool/ui_lint/overflow_lint.py (python3, no SDK): 15 fixes (community, people, home hero, place card, membership
     dashboard, force update, ride wrap-up, device compatibility admin). Your 10030 layout fixes in home_screen.dart
     (padding, carousel height, hero card padding, title 1 line, FittedBox button, leaderboard row) and
     explore_screen.dart (chips as SingleChildScrollView + Row) were merged into the new versions: keep them.

=== 2. COMMITS (in this order; git add the listed paths only) ===
1. feat(gateway): admin-configurable Explore and riders' shared routes
   gateway/src/explore.js gateway/src/destinations.js gateway/src/routes.js gateway/src/feature_flags.js
   gateway/src/route_policy.js gateway/src/oracle/repo.js gateway/deploy/route_split.md
   gateway/test/explore_routes_359.test.js
2. feat(admin): Explore section in the web admin
   gateway/public/admin/explore.js gateway/public/admin/index.html gateway/public/admin/admin.css
3. docs(privacy): routes you share on Explore     gateway/public/privacy.html
4. feat(app): Explore from the admin config, riders' routes, share after a ride, in-app admin
   lib/domain/explore/ lib/data/services/explore_service.dart lib/presentation/explore/
   lib/presentation/report/trip_report_screen.dart lib/presentation/account/account_screen.dart
   lib/presentation/admin/admin_explore_screen.dart lib/presentation/admin/admin_nav.dart
5. feat(app): CoRoute's own look: road Ride key, lane marks, safety-first home, road section headers
   lib/core/ui/route_visuals.dart lib/core/ui/ui.dart lib/presentation/shell/coroute_nav_bar.dart
   lib/presentation/home/home_screen.dart
6. fix(app): text overflow and alignment on small screens and large fonts
   lib/presentation/social/community_screen.dart lib/presentation/social/people_screen.dart
   lib/presentation/map_places/place_card.dart lib/presentation/engagement/ride_wrapup_sheet.dart
   lib/presentation/update/force_update_screen.dart lib/presentation/subscription/membership_dashboard_screen.dart
   lib/presentation/admin/admin_device_compatibility_screen.dart tool/ui_lint/overflow_lint.py
7. test(app): Explore v3.59     test/explore_v359_pure_test.dart test/explore_v359_widgets_test.dart
8. docs(v3.59): Explore spec and round 16 prompt
   docs/features_355/explore_v359.md docs/NEXT_AGENT_PROMPT_v3.55_round16_explore_10031.md
9. chore(release): 3.55.0+10031    pubspec.yaml (+ checksums as in 10030)
   After commit 9: `git status --short` must show only _incoming/ (and ignored tool caches).

=== 3. TESTS ===
- cd gateway && npm test -> expect 1469 tests, 0 failures (1462 + 7 in explore_routes_359). Also
  node deploy/gen_caddy_routes.js must report no change (Caddyfile.vm1 in sync).
  If public_ride_mirror or two_node_failover time out in the full run, re-run those two files alone (they are
  timing tests that can miss under load; both passed alone here). A repeat failure alone is a real bug.
- flutter analyze -> 0 issues. flutter test -> all pass, including test/explore_v359_widgets_test.dart (Explore at
  text x1.3 and x2, light and dark, be-first card, nav bar) and test/explore_v359_pure_test.dart.
  Existing home / explore / shell tests may need key or text updates ONLY where the layout changed on purpose
  (safety panel now first, "Your next ride" header, Ride key label "Ride: start a ride..."). Never remove an
  Emergency or SOS assertion. Report every test you changed and why.
- python3 tool/ui_lint/overflow_lint.py -> 32 findings, all listed as reviewed in explore_v359.md section 5; a NEW
  finding is a bug to fix.
- dart tool/play_policy_scan.dart -> 0 hits.

=== 4. BUILD ===
flutter build appbundle --release (3.55.0+10031), same signing as 10030. Record size vs 10030.

=== 5. DEVICE QA (real phone; also a 320 dp wide emulator) ===
a) Alignment: Settings > Display size largest + Font size largest, 320 dp: Home, Explore, ride detail, trip
   report, Community, People, Profile, membership dashboard, admin screens. No yellow/black overflow stripes, no
   text over other text, no clipped buttons. Screenshot any problem and fix it.
b) Home: safety panel first, Emergency red and working (call/share flow unchanged), "Your next ride" carousel.
c) Bottom bar: Ride key opens the same sheet as before (Emergency first); lane marks on the selected tab; TalkBack
   reads "Ride: start a ride...".
d) Explore admin (web): change headline, re-order sections, rename/hide a category, add a custom category and use it
   on a destination, feature 2 places -> pull-to-refresh in the app shows it within 2 minutes. Try to remove a used
   category -> refused (IN_USE). Same in the in-app admin (Content > Explore).
e) Rider routes: ride (or replay a GPX) to within 3 km of an Explore place -> trip report card. Share disabled until
   consent ticked; share -> "first rider" message; ride detail shows the card and the route (first/last km missing,
   no time of day). Second account sees it with the username. Delete from Profile > My shared routes -> gone.
   Moderator hide/show/delete in web admin -> audited. Delete the account -> its routes gone.
   No username -> clear message. Turn flag exploreRoutes off -> no card, no section, API 404/disabled.
f) Be first: a place with no routes shows "Be the first to guide others" on Explore and on ride detail.
g) Offline: airplane mode -> Explore shows the saved copy; no crash.
h) Safety regression: SOS, crash alarm, ride lock, lock-screen cockpit, Medical ID still work.

=== 6. PLAY SCREENSHOTS ===
Home and Explore changed. Re-capture REAL screenshots from this build (not mocks) for phone and both tablets for
Home, Explore and ride detail, replace them in docs/store/play_assets_v3.58/ and upload. No competitor content, no
real rider names except a test account.

=== 7. DEPLOY ===
Deploy the gateway + website + admin with deploy/release.sh exactly as for 10030 (both VMs, health checks). Then
check: GET /api/public/explore returns config + destinations; /privacy#shared-routes loads; web admin Explore loads.

=== 8. PLAY ===
Upload the AAB to internal testing, release notes: "Explore you can trust: see the routes real riders took, share
yours to guide others, and a cleaner look that fits every screen."

=== 9. OWNER DECISIONS TO REPORT (do not decide) ===
- Should rider routes later show to signed-out visitors on the website? (now signed-in app only)
- Seed featured places for launch? (now none featured until an admin picks them)
- Any Play screenshot copy changes.
```
