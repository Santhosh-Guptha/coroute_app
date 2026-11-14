# CoRoute build 3.55.0+10030: complete release prompt (rounds 11-15, everything done on 14 Nov 2026)

One prompt for everything still uncommitted in the working tree: round 11 (app redesign + ride HUD), round 12 (website
story + Play graphics), round 13 (new helmet logo everywhere), round 14 (website works on every device), round 15
(website cleanup: repeated sections removed). It replaces the separate round 11, 13 and 14 prompts (those stay in docs/ for reference). Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Build 3.55.0+10029 is committed (latest commit a3b4a46). Rounds 11-15 are in the working tree,
uncommitted, and ship together as build 3.55.0+10030 (pubspec already 3.55.0+10030). Commit, test, build, device QA,
deploy gateway + website, Play graphics, Play internal testing. Report after each section. STOP at any failed safety
gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0.
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths.
- Never hide or weaken SOS, the crash alarm, others' SOS banners, the rescue finder, warnings, Medical ID, ride lock,
  lock-screen cockpit, app lock. Fix code, not tests, unless a text changed on purpose. dart tool/play_policy_scan.dart
  -> 0 hits.
- Read first:
  app redesign:   docs/design/REDESIGN_v3.58.md, docs/design/RIDE_HUD_v3.58.md, docs/quality/ROUND11_UI_NOTES.md,
                  docs/quality/ROUND11_HUD_NOTES.md
  website/Play:   docs/quality/ROUND12_WEBSITE_NOTES.md, docs/store/play_assets_v3.58/README.md
  logo:           docs/brand/BRAND_GUIDE_v3.58.md
  devices:        docs/quality/WEBSITE_DEVICE_COMPAT_v3.58.md, tool/web_compat/README.md
  cleanup:        docs/quality/WEBSITE_CLEANUP_v3.58.md
- Do not commit _incoming/ (transfer zips; delete them after the commit) or tool/web_compat/node_modules. 21 old
  website screenshots (dark-*, guardians-*, sirens-* in gateway/public/assets/screens) were deleted from the working
  tree on purpose: stage the deletions with `git add -A gateway/public/assets/screens`.
- Logo files are generated: change tool/brand/build_brand.py and run `python3 tool/brand/build_brand.py` (fontTools +
  rsvg-convert), never edit the logo PNGs by hand. Website CSS: after ANY CSS change run
  `cd tool/web_compat && npm install && node css_compat.js`; never hand-edit lines marked /* compat */ or
  compat:generated.

=== 1. WHAT IS NEW ===
A) APP REDESIGN (round 11; competitor layout ideas only, our own brand, copy and assets)
   - Bottom bar Home · Explore · + · Community · Chat. "+" sheet: Emergency (first, red), Start solo ride, Start or plan
     a group ride, Join with a code, Plan a trip, Suggest a place.
   - Home: greeting, bell/theme/avatar, hero cards, "Ride safety" strip with a red Emergency button, rotating safety
     nudge, riding communities, ride stats + leaderboard rank, upcoming rides, bike status.
   - Explore: search + Add, category chips, ranked rides near you (distance on the phone only), ride detail with road
     intel (hazards, rough road, twistiness, rider stops, risky times, fuel) + Ride solo / Plan group ride / Navigate.
   - Community (crews, clubs, requests, score, leaderboard, friends); Chat (live ride chat + recent ride chats, no new
     backend); Profile (cover photo + avatar, "Complete your riding profile" checklist, preferences, my rides,
     Settings & info, existing sign-out/delete); Welcome ("Ride together. Stay safe.", Get started / I already have
     an account, Emergency? Call 112). First launch opens Welcome instead of the 3 onboarding pages.
   - Gateway: curated destinations (public read + MASTER_ADMIN CRUD with photo upload; 10 South India places seeded,
     names/coordinates/categories only; DESTINATIONS_ENABLED) and cover photo (same pipeline as avatars).
B) RIDE HUD (round 11, lib/presentation/rider/hud/): destination pill + route options, turn card with live distance
   and a "Then" line, speed-limit sign in the card, one-at-a-time safety strip, 56 dp right control column, bottom
   sheet collapsed (limit-ring speed dial, ETA, km left, hold-to-end, group pill, talk bar) / half (arc speedometer
   with limit marker, ride so far, distance by speed, over the limit) / full (group list, speed chart); landscape side
   panel. Pure Dart lib/domain/ride/ride_stats_accumulator.dart, saved every 30 s.
C) WEBSITE STORY + PLAY GRAPHICS (round 12): home scroll story "A ride with CoRoute" (7 chapters, SVG visuals in
   assets/story.js, reduced-motion and no-JS fallbacks; still no phone screenshots on home); new app screens on
   features, safety, how it works, get, guide; honest offline link / rescue beacon wording; Get page Bluetooth line;
   privacy page Bluetooth section (offline link, rescue beacon, headsets, finder microphone). Play graphics in
   docs/store/play_assets_v3.58/ (8 phone 1080x2160, 7" and 10" tablet sets, feature graphic, icon, listing text),
   RENDERED FROM DESIGN MOCKS by node tool/store_assets/render.js: section 6 re-captures them from the real build.
D) NEW LOGO (round 13): the rider's helmet is the "o" of CoRoute (visor = road ahead, amber light = lead rider). The
   old curved-road mark is retired everywhere.
   - Android: launcher icon (legacy, round, adaptive foreground on teal), NEW monochrome layer (Android 13+ themed
     icons), android:roundIcon, splash icon; NEW notification small icon drawable/ic_stat_coroute.xml (white helmet)
     used by the ride notification and push messages (Kotlin RideNotification/CoRouteMessagingService), the ride
     foreground service (BackgroundService.rideNotificationIcon + manifest meta-data
     space.devmonks.coroute_app.NOTIFICATION_ICON), the crash alarm (alarm_notifier.dart) and Firebase's own
     notifications (manifest default_notification_icon/color). res/raw/keep.xml keeps it from resource shrinking.
     Before: the small icon was the colour launcher icon (a white blob on Android 7+).
   - Screens: lib/core/ui/coroute_logo.dart (CoRouteAppIcon, CoRouteWordmark, CoRouteHelmet) on splash, welcome,
     sign-in, update-required, licences page, admin consoles, the shared ride card. Tests updated on purpose:
     test/e2e/application_level_test.dart, test/share_card_quick_reply_test.dart.
   - iOS AppIcon set + Flutter web icons regenerated (files only). Play: store/icon_512.png, feature graphic, all
     screenshots re-rendered with the logo. Website: favicons, apple-touch, icon-192/512/maskable, site.webmanifest
     (teal), header/footer wordmark (icon only under 380 px), receipt mark, og-image.png, /brand/ files.
   - E-mails (gateway/src/email_brand.js): wordmark image /brand/email-wordmark.png (alt text "CoRoute" in teal) and
     teal instead of the old purple in welcome/lifecycle, offers, marketing studio, receipts/refunds; security e-mails
     keep NO images (teal text header, teal buttons); ride summary map line teal; admin e-mail previews recoloured.
E) WEBSITE ON EVERY DEVICE (round 14; 16 problems found and fixed, table in WEBSITE_DEVICE_COMPAT_v3.58.md):
   - No sideways scrolling on Galaxy Fold (280 px) or with system text 150-200 %: site.js fitHeader() drops the header
     theme button, then "Get the app" (both also in the menu/footer); footer grid minmax(0,1fr); buttons wrap.
   - Older iPhones/Androids: site.js no longer crashes on Safari < 14 (matchMedia addListener fallback); focus ring
     restored on Safari < 15.4; fallbacks for clamp/min/max, svh, color-mix, inset, logical margins/paddings, flex gap
     (.no-flexgap set by theme-init.js), split :has()/:focus-visible selector lists, -webkit-backdrop-filter,
     aspect-ratio boxes; story shows still frames without aspect-ratio; /watch guardian page rewritten to ES2019;
     photo editor button hidden where it cannot work.
   - iPhone landscape safe areas; <noscript> notices on the 10 JavaScript-only pages; low-end phones (<= 2 GB RAM or
     <= 2 cores) get the still hero poster; "CoRoute" spelled correctly across the website (was "Coroute").
   - New tool tool/web_compat (css_compat.js) and test gateway/test/website_device_compat_358.test.js (7 checks);
     website.test.js and live_page.test.js updated for the "CoRoute" spelling (text changed on purpose).
F) WEBSITE CLEANUP (round 15; the owner said the site had too many repeated things):
   - Home page 22 -> 11 sections, about 4,600 -> 2,500 words: removed the sections that repeated the scroll story and
     "Six things" (crash/SOS twice more, group tools twice more, trip report, ride analytics, how-it-works steps,
     group-rides pitch, numbers + leaderboard teaser, help-us-build); each idea now lives once, on its own page, and
     the home links /features, /safety, /how-it-works#faq, /leaderboard, /privacy-and-security.
   - One FAQ for the site (12 answers) on /how-it-works#faq; the old how-it-works answers that were out of date (intercom
     needs data, host pays a membership) are gone. Rate card moved under the rider reviews. /features impact strip
     removed (home has the full block, /safety keeps its safety strip).
   - Dead code removed: the "CoRoute in numbers"/ride analytics script in site.js and every unused CSS rule in
     home.css, site.css, pages.css (382 KB -> 289 KB across the main files). Before/after screenshots of all 26 pages
     at 390 and 1280 px: no visual change from the CSS clean-up.
   - Tests updated on purpose: website, website_privacy_messaging, website_impact_355, website_ios_blocks,
     website_leaderboard_355, website_live, website_stories_render.

=== 2. COMMIT ===
IMPORTANT: the top-level .gitignore (line 29 "*.xml" and a png rule) silently ignores NEW Android resources. Force-add
and verify with `git status --short --ignored`:
  git add -f android/app/src/main/res/drawable/ic_stat_coroute.xml android/app/src/main/res/raw/keep.xml \
    android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml \
    android/app/src/main/res/mipmap-*/ic_launcher_round.png android/app/src/main/res/mipmap-*/ic_launcher_monochrome.png \
    docs/brand/png
Also ALREADY missing from git before today (confirmed with git ls-files): android/app/src/main/res/values/share_in.xml,
android/app/src/main/res/values-night/colors.xml, android/app/src/main/res/drawable/ride_notif_pill_sos_solid.xml.
Force-add them too (a clean checkout cannot build without them). Then narrow the *.xml / png rules in the top-level
.gitignore so Android resources are never ignored (keep the secrets rules exactly as they are).
Commits, in order:
 1 "feat(app): redesign shell, home, explore, community, chat, profile, welcome"
 2 "feat(ride): new ride HUD with stats sheet"
 3 "feat(gateway): curated destinations, cover photo"
 4 "feat(website): scroll story, new app screens, privacy Bluetooth section"
 5 "feat(brand): helmet logo masters and generator (docs/brand, tool/brand)"
 6 "feat(app): helmet launcher, themed and notification icons, logo in screens"
 7 "feat(website): helmet logo, favicons, manifest, og image; e-mail brand header"
 8 "fix(website): works on every device (narrow and large-text layouts, older Safari/Chrome fallbacks, safe areas)"
   + "refactor(website): one place for each idea, one FAQ, unused CSS and scripts removed"
 9 "chore(tool): web_compat CSS fallback tool" + "test(website): device compatibility guards"
10 "docs(store): Play graphics v3.58 with the new logo" + "docs(v3.58): redesign, logo, device notes"
11 "chore(build): track Android resources hidden by .gitignore"
12 "chore(release): 3.55.0+10030". Push.

=== 3. TEST AND BUILD ===
1. cd gateway && npm ci && npm test -> 1462 passing (1458 + 7 device checks - 3 tests for removed home
   sections; flaky alone-reruns: public_ride_mirror, two_node_failover, job_lease, login performance,
   email_marketing_357).
2. cd tool/web_compat && npm install && node css_compat.js --check -> "compat check: up to date".
3. flutter pub get && flutter analyze && flutter test. NEVER RUN BEFORE: test/ui10_*, test/hud_* (widget), the updated
   shell tests, test/e2e/ui_level_test.dart (new profile), test/e2e/application_level_test.dart and
   test/share_card_quick_reply_test.dart (wordmark). Expect some widget expectations to need adjusting to the real
   render; SOS must stay visible and tappable in every HUD sheet state. Golden tests that include splash / welcome /
   sign-in headers may need new goldens: regenerate only those and list them.
4. dart tool/play_policy_scan.dart -> 0 hits.
5. Release build (appbundle + split APKs); tool/check_16kb_alignment.sh passes. aapt2 must accept ic_stat_coroute.xml,
   ic_launcher_round.xml and res/raw/keep.xml; check the release APK contains res/drawable*/ic_stat_coroute* and
   mipmap*/ic_launcher_monochrome* (resource shrinking did not drop them). Release-build R8 check of the new screens.

=== 4. DEVICE QA (release build; phone model + Android version for each) ===
- App U1-U16 (ROUND11_UI_NOTES.md) and HUD H1-H12 (ROUND11_HUD_NOTES.md): every tab, the "+" sheet, Emergency
  reachable from Home without scrolling on a small phone, Explore ranking, ride detail actions, profile checklist,
  cover photo upload, Welcome for new and returning users; HUD at 80 km/h glance test, gloves, sunlight, night,
  landscape mount, SOS reachable in all sheet states, low-end phone frame rate, hold-to-end.
- Logo L1-L4: launcher icon on Android 8, 12, 13+ (themed icons on: helmet), round-icon launcher, Samsung; status
  bar + shade for ride notification, foreground service, push, crash alarm full-screen and heads-up: white helmet,
  never a white square or the old mark; splash light/dark, Welcome, sign-in, update-required, licences, admin header;
  shared ride card image shows the wordmark (light + dark).
- SAFETY GATE (any failure = STOP): crash countdown + alarm over the lock screen + emergency SMS as in 10029; SOS
  notification actions (I'm OK, SOS) from the lock screen; lock-screen cockpit rules; warnings still spoken; rescue
  finder opens from an SOS.

=== 5. DEPLOY GATEWAY + WEBSITE ===
release.sh (staging -> vm2 -> vm1). On staging first, then production:
- Website W1-W13 (ROUND12_WEBSITE_NOTES.md, incl. Safari iOS and slow 3G): home story scrolls smoothly (phone +
  desktop), reduced motion shows still frames, pages show the new screens, /privacy Bluetooth section, admin
  destinations API works (no admin page yet).
- Cleanup: home shows 11 sections, every link to /features, /safety, /how-it-works#faq, /leaderboard works; the FAQ on
  /how-it-works opens; e-mail links to /#feedback still land on the form; the impact block appears once real totals
  exist.
- Logo W-L1-W-L4: favicon in Chrome/Firefox/Safari, iOS Add to Home Screen icon, Android install icon (maskable);
  header/footer wordmark light/dark and at 360 px; og-image link preview in WhatsApp; test e-mails to Gmail and
  Outlook with images on and off (welcome, receipt, offer, security code with no images).
- Devices D1-D7 (WEBSITE_DEVICE_COMPAT_v3.58.md): old iPhone Safari (iOS 12.5-14.x if available), current iPhone
  portrait+landscape, Galaxy Fold folded / Samsung Internet, low-end Android, Android largest font + display size,
  iPad + desktop Firefox/Safari/Edge, JavaScript off. If no old iPhone is available use a cloud device service and say
  which devices were real. Any sideways scroll or menu that does not open = fix + re-run css_compat.js.
- WEBSITE SAFETY GATE: /watch (guardian live link) and /e/<token> (live emergency link) open and update on an old
  iPhone and a current Android; SOS/live pages are never blank.

=== 6. GOOGLE PLAY GRAPHICS (must match the real app) ===
1. On a phone with build 10030 and demo data (fictional names), capture each of the 8 screens in
   docs/store/play_assets_v3.58/README.md (adb shell settings put global sysui_demo_allowed 1 + demo mode; adb exec-out
   screencap -p). Where the real screen differs from the rendered file, replace it (caption band via
   node tool/store_assets/render.js fed with the real capture, or the real capture in Play's caption-free layout).
2. Tablets: only after checking on a real tablet (no tablet-specific layout).
3. Upload: app icon store/icon_512.png (new helmet logo; reviewed with the release), feature graphic
   docs/store/play_assets_v3.58/feature_graphic_1024x500.png, phone screenshots (2-8), tablet sets, short/full
   description and release notes from listing_text.md. Alt text <= 140 characters each.
4. Internal testing 3.55.0+10030; mapping file + native symbols. LATEST_APP_BUILD=10030 on both VMs (never raise
   MIN_APP_BUILD); website APKs + SHA256SUMS.

=== 7. OWNER DECISIONS (report, do not decide) ===
- Public club directory ("Request to join") needs a backend change: proposal in REDESIGN_v3.58.md. Crew chat threads:
  proposal only. Web admin page for destinations (API ready). Cover photo re-framing screen not built.
- Ride detail map draws a straight line (the planner does the road route). Riding interests stored on the phone only.
- One website screenshot set for light and dark; tablet screenshots are phone layouts at tablet width; offline-link
  Play screenshot shows full signal icons (Google rule) while the screen says "No mobile signal".
- Still open from earlier rounds: mesh per-rider signatures; stricter-of-limits rule; lock-screen cockpit switch;
  Ampere A1 in account 1; rotate the leaked admin passwords.

=== 8. REPORT ===
Commit hashes, build number, checksums, test counts (gateway, flutter test, analyze, policy scan, css_compat --check),
APK resource check, list of force-added files and the .gitignore change, device QA tables (U, H, L, safety gate),
website tables (W, W-L, D1-D7, website safety gate), which Play screenshots were replaced by real captures, Play
status, open issues, decisions needed.
```
