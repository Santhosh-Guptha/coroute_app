# CoRoute round 11: app redesign, ride HUD, website story, Play Store graphics (build 3.55.0+10030)

Round 10 is committed as build 3.55.0+10029. Round 11 (app redesign + ride HUD) and round 12 (website + Play assets)
are in the working tree, uncommitted, and ship together as build 3.55.0+10030 (pubspec already bumped).
Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Build 3.55.0+10029 is committed. Ship the redesign as build 3.55.0+10030: commit, test, build,
device QA, deploy gateway + website, re-capture Play screenshots from the real build, Play internal testing.
Report after each section. STOP at any failed safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0.
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths.
- Never hide or weaken SOS, the crash alarm, others' SOS banners, the rescue finder, warnings, Medical ID, ride lock,
  lock-screen cockpit, app lock. Fix code, not tests, unless a text changed on purpose. Policy scan -> 0 hits.
- Read first: docs/design/REDESIGN_v3.58.md, docs/design/RIDE_HUD_v3.58.md, docs/quality/ROUND11_UI_NOTES.md,
  docs/quality/ROUND11_HUD_NOTES.md, docs/quality/ROUND12_WEBSITE_NOTES.md, docs/store/play_assets_v3.58/README.md.
- R11_DELETED.txt (if present in the transfer zip) lists 21 old website screenshots (dark-*, guardians-*, sirens-* in
  gateway/public/assets/screens) to `git rm`. Do not commit R11_DELETED.txt, _to_delete/ or _incoming/.

=== 1. WHAT IS NEW ===
A) App redesign (inspired by a competitor's layout ideas; our own brand, copy and assets):
   - bottom bar Home · Explore · + · Community · Chat; "+" sheet: Emergency (first, red), Start solo ride, Start or
     plan a group ride, Join with a code, Plan a trip, Suggest a place;
   - Home: greeting, bell/theme/avatar, hero cards, "Ride safety" strip with a red Emergency button, rotating safety
     nudge, riding communities, ride stats + leaderboard rank, upcoming rides, bike status;
   - Explore: search + Add, category chips, ranked rides near you (distance on the phone only), ride detail with road
     intel (hazards, rough road, twistiness, rider stops, risky times, fuel) + Ride solo / Plan group ride / Navigate;
   - Community (crews, clubs, requests, score, leaderboard, friends), Chat (live ride chat + recent ride chats; no new
     backend), Profile (cover photo + avatar, "Complete your riding profile" checklist, preferences, my rides,
     Settings & info list, existing sign-out/delete), Welcome ("Ride together. Stay safe.", Get started / I already
     have an account, Emergency? Call 112). First launch now opens Welcome instead of the 3 onboarding pages.
   - Gateway: curated destinations (public read + MASTER_ADMIN CRUD with photo upload; 10 South India places seeded,
     names/coordinates/categories only, no photos; DESTINATIONS_ENABLED) and cover photo (same pipeline as avatars).
B) Ride HUD (lib/presentation/rider/hud/): destination pill + route options, turn card with live distance and a "Then"
   line, speed-limit sign in the card, one-at-a-time safety strip, 56 dp right control column, bottom sheet
   collapsed (limit-ring speed dial, ETA, km left, hold-to-end, group pill, talk bar) / half (arc speedometer with
   limit marker, ride so far, distance by speed, over the limit) / full (group list, speed chart); landscape side
   panel. Pure Dart ride stats accumulator (lib/domain/ride/ride_stats_accumulator.dart), saved every 30 s.
C) Website: home scroll story "A ride with CoRoute" (7 chapters, SVG visuals in assets/story.js, reduced-motion and
   no-JS fallbacks; still no phone screenshots on home); new app screens on features, safety, how it works, get,
   guide; honest offline link / rescue beacon wording; Get page Bluetooth line fixed; privacy page Bluetooth section
   rewritten (offline link, rescue beacon, headsets, finder microphone).
D) Play graphics in docs/store/play_assets_v3.58/: 8 phone screenshots 1080x2160, 7" and 10" tablet sets, feature
   graphic 1024x500, icon 512x512, listing text. RENDERED FROM DESIGN MOCKS: section 6 re-captures them.

=== 2. COMMIT ===
"feat(app): redesign shell, home, explore, community, chat, profile, welcome",
"feat(ride): new ride HUD with stats sheet", "feat(gateway): curated destinations, cover photo",
"feat(website): scroll story, new app screens, privacy Bluetooth section", "docs(store): Play graphics v3.58",
"docs(v3.58): redesign notes", "chore(release): 3.55.0+10030". Push.

=== 3. TEST AND BUILD ===
1. cd gateway && npm ci && npm test -> expect 1458 passing (flaky alone-reruns: public_ride_mirror, two_node_failover,
   job_lease, login performance, email_marketing_357).
2. flutter pub get && flutter analyze && flutter test. NEVER RUN BEFORE: test/ui10_*, test/hud_* (widget), the updated
   shell tests and test/e2e/ui_level_test.dart (profile expectations follow the new profile). Expect some widget
   expectations to need adjusting to the real render; SOS must stay visible and tappable in every HUD sheet state.
3. Release build; tool/check_16kb_alignment.sh passes; release-build R8 check of the new screens.

=== 4. DEVICE QA (release build; phone model + Android version) ===
- U1-U16 (ROUND11_UI_NOTES.md) and H1-H12 (ROUND11_HUD_NOTES.md): every tab, the "+" sheet, Emergency reachable from
  Home without scrolling on a small phone, Explore ranking near you, ride detail actions, profile checklist, cover
  photo upload, Welcome flow for new and returning users; HUD at 80 km/h glance test, gloves, sunlight, night,
  landscape mount, SOS reachable in all sheet states, low-end phone frame rate, hold-to-end.
- SAFETY GATE (any failure = STOP): crash countdown + SOS + emergency SMS as in 10029; lock-screen cockpit rules;
  warnings still spoken; rescue finder opens from an SOS.

=== 5. DEPLOY GATEWAY + WEBSITE ===
release.sh (staging -> vm2 -> vm1). Then: home story scrolls smoothly (phone + desktop), reduced motion shows still
frames, pages show the new screens, /privacy Bluetooth section, admin destinations API works (no admin page yet).
W1-W13 in ROUND12_WEBSITE_NOTES.md (incl. Safari iOS, slow 3G).

=== 6. PLAY STORE GRAPHICS (must match the real app) ===
1. On a phone with build 10030 and demo data (fictional names), capture each of the 8 screens listed in
   docs/store/play_assets_v3.58/README.md (adb shell settings put global sysui_demo_allowed 1 + demo mode for a clean
   status bar; adb exec-out screencap -p). Compare with the rendered files; where the real screen differs, replace the
   screenshot (keep the caption band style with node tool/store_assets/render.js, feeding the real capture, or
   upload the real capture with Play's own caption-free layout).
2. Tablets: only use tablet screenshots after checking them on a real tablet (the app has no tablet-specific layout).
3. Upload: icon, feature graphic, phone screenshots (2-8), tablet sets, short/full description and release notes
   from listing_text.md. Alt text <= 140 characters each.
4. Internal testing 3.55.0+10030; mapping file + native symbols. LATEST_APP_BUILD=10030 on both VMs; website APKs +
   SHA256SUMS.

=== 7. OWNER DECISIONS ===
- Public club directory ("Request to join") needs a backend change: proposal in REDESIGN_v3.58.md.
- Crew chat threads: proposal only.
- Ride detail map draws a straight line (the planner does the road route).
- Cover photo re-framing screen not built yet.
- Riding interests stored on the phone only.
- One website screenshot set for light and dark; tablet screenshots are phone layouts at tablet width.
- Offline-link Play screenshot shows full signal icons (Google rule) while the screen says "No mobile signal".
- Web admin page for destinations (API ready).

=== 8. REPORT ===
Commit hashes, build number, checksums, test counts, device QA tables, website checks, which Play screenshots were
replaced by real captures, Play status, open issues, decisions.
```
