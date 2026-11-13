# CoRoute round 7: app smoothness, curve and speed-limit warnings, faster SOS, new home page hero (build 3.55.0+10027)

Rounds 4, 5 and 6 are committed as build 3.55.0+10026 (commit 2451b6c). Round 7 is in the working tree, uncommitted,
and ships as app build 3.55.0+10027 (pubspec already bumped) plus one gateway release. Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Rounds 4-6 are committed as build 3.55.0+10026. Round 7 is in the working tree, uncommitted: ship
it as build 3.55.0+10027. Use the round 6 prompt (docs/NEXT_AGENT_PROMPT_v3.55_round6_final.md) for the rules, staging
gate, deploy flow and safety gate; anything in it not yet finished for 10026 (staging casRev check, device QA, Play
upload) is done on 10027 instead.
Report after each section. STOP at any failed safety gate.

=== 0. RULES ===
- Same rules as the round 6 prompt (no secrets or real IPs in git; never weaken SOS, crash detection, emergency texts,
  Medical ID, ride lock, lock-screen cockpit; policy scan 0 hits; fix code, not tests, unless a text changed on purpose).
- If round 7 files are missing from the working tree, unpack coroute_v3.56_round7_files.zip: R7_BASE_MD5.txt lists the
  md5 each file was made from (repo md5 equal -> take the zip copy; different -> merge by hand; NONE -> new file).
  Do not commit R7_BASE_MD5.txt.
- Read first: docs/quality/ROUND7_UX_NOTES.md, docs/quality/ROUND7_SAFETY_NOTES.md, docs/quality/ROUND7_WEBSITE_NOTES.md,
  docs/features_355/motion_and_loading.md, docs/features_355/curve_and_speed_limit.md.

=== 1. WHAT IS NEW IN ROUND 7 ===
APP SMOOTHNESS (lib/core/ui; docs/features_355/motion_and_loading.md)
 - iOS-style page slide with edge-swipe back for every normal page, spring sheets and dialogs, motion tokens
   (120/200/300 ms); "remove animations" switches motion off, battery saver reduces it. Routes named safety/... (crash
   alarm, SOS hold, emergency SOS) have NO transition: they appear instantly.
 - Loaders: content-shaped skeletons instead of 20 full-screen spinners, top progress line, cached data shown at once
   and refreshed in place, inline button progress, pull-to-refresh, optimistic actions with rollback, error + retry.
 - Start-up: six sequential awaits before runApp now run in parallel (safety service order unchanged); idle warm-up 3 s
   after sign-in, never during a ride. Avatars and place photos decode at display size.
 - Responsive helper (compact < 360, normal, large >= 600) used on several screens; a full small-screen pass is device QA.
CURVES, SPEED LIMITS, FASTER SAFETY (docs/features_355/curve_and_speed_limit.md)
 - Curve warnings on the phone, offline: bends from the route line or, in free riding, from the matched road; classes
   gentle / medium / sharp / hairpin; advisory speed (0.28 g, lower in the dark, never above the limit); voice + chip
   about 7 s ahead (80-400 m), only when faster than the advisory speed, once per bend; silent when unsure.
 - Road cells: gateway/src/road_cells.js caches OSM ways per ~1 km cell for 30 days (Overpass with per-minute and per-day
   budgets, backoff, one upstream call at a time); GET /api/geo/roads; the phone keeps a 30 MB disk cache.
 - Speed limits: OSM tag (motorcycle cap 80) > rider correction > implied type > estimate table
   (lib/domain/road/india_speed_limits.dart, MoRTH S.O. 1522(E) 2018). Estimates show as "~50 est." and never speak.
   Overspeed: +10 % (min 5 km/h), strong above 20 %, voice once then visual; no margin near schools and hospitals.
 - "Wrong limit" one-tap report (stopped or after the ride; needs the road-data consent; 3 riders; never raises a tagged
   limit): POST /api/geo/limit-corrections, admin API GET|POST /api/admin/geo/limit-corrections[/:way]. No admin PAGE
   yet (API only).
 - One warning scheduler for all advisory voice lines (hazard > curve > speed limit > falling behind > rough road >
   fatigue > twisty), never two at once, silenced by SOS/crash.
 - Faster SOS: sent before any await using the last known position (tests: 800 ms -> under 10 ms with a fix in memory;
   900 ms -> under 250 ms without); socket AND HTTP in parallel with de-dupe (new LIVE route POST
   /api/convoys/:groupId/sos); crash impact bucket flushed at once (Kotlin); big frames decoded off the UI thread, alerts
   overtake waiting positions.
 - Cockpit: limit sign and bend chip repaint on their own; layouts for small phone, large text, landscape, tablet, split
   screen; other riders' markers glide between reports.
 - Settings > Road safety: "Bends and speed limits" card.
WEBSITE (docs/quality/ROUND7_WEBSITE_NOTES.md)
 - Home page only: phone screenshots removed (hero phones, the screens gallery, the SOS phone, the trip-report phone);
   other pages unchanged. The moving-convoy WebGL hero (assets/hero3d.js) is back at the top: six bikes on a mountain
   road, day/night with the theme, static drawing as first frame and for reduced motion / no WebGL.
 - Privacy policy: "Speed limit reports" paragraph + OpenStreetMap (ODbL) credit.

=== 2. COMMIT (after the round 6 commits) ===
 "perf(app): motion system, skeleton loaders, parallel start-up, responsive helper", "feat(safety): curve warnings,
 speed limits with estimates, wrong-limit reports, road cells", "perf(safety): instant SOS send with HTTP lane, alert-first
 frames, warning scheduler, cockpit repaint scope", "feat(website): home hero animation, no phone screens on home",
 "docs(v3.56): round 7 notes", "chore(release): 3.55.0+10027". Push.

=== 3. TEST AND BUILD (in addition to round 6 section 4) ===
 1. cd gateway && npm test -> expect 1355 passing.
 2. flutter test: NEVER RUN BEFORE - test/ux_perf_*.dart, test/curve_speed_*.dart, test/safety_fast_*.dart. Older widget
    tests that pump page transitions with fixed durations may need updating: a push is now 350 ms (use pumpAndSettle).
    A safety screen must still appear with a single pump: if such a test fails, fix the code, not the test.
 3. First compile of the Kotlin change in the crash sensor flush.

=== 4. ENV (optional, defaults fine; all in gateway/deploy/.env.example) ===
 ROAD_CELLS_OVERPASS_URL, ROAD_CELLS_TTL_DAYS=30, ROAD_CELLS_MEM_MB, ROAD_CELLS_UPSTREAM_PER_MIN,
 ROAD_CELLS_UPSTREAM_PER_DAY, ROAD_CELLS_CONCURRENCY=1, ROAD_LIMIT_K_MIN=3. New collection road_limit_votes.
 Allow outbound to the Overpass host on both VMs. Regenerate the Caddy route matcher (the new SOS route is LIVE).

=== 5. STAGING CHECKS (add to round 6 section 5) ===
 - GET /api/geo/roads?cell=<a cell in Bengaluru> returns ways with gzip + ETag; a second call is a cache hit;
   /api/health shows health.roads.
 - POST /api/convoys/:groupId/sos with the same clientId as a socket SOS creates ONE alert.
 - Home page: the convoy moves, pauses when scrolled away, static with reduced motion; no console errors; other pages
   still show their phone pictures.

=== 6. DEVICE QA (release build; report each with phone model + Android version) ===
 - U1-U20 (smoothness, frame timing with `adb shell dumpsys gfxinfo space.devmonks.coroute_app framestats` on a 120 Hz
   phone and a 2-3 GB phone, cold start vs build 10025, small screens at the largest font, tablet, reduce motion):
   docs/quality/ROUND7_UX_NOTES.md.
 - V1-V29 (curve warnings on a known ghat with and without a route and in flight mode, limits on roads with known
   signs, "~ est." display, overspeed voice, SOS stopwatch incl. a network switch, crash rig timing vs 3.55, marker
   smoothness, landscape mount, lock-screen cockpit and AOD): docs/quality/ROUND7_SAFETY_NOTES.md.
 - W1-W12 (home page on phones, tablets, desktop, light/dark, slow phone, Safari iOS): ROUND7_WEBSITE_NOTES.md.
 - SAFETY GATE additions (any failure = STOP): crash alarm and SOS screens appear instantly while a page transition is
   running, with battery saver on and with "remove animations" on (U3); SOS reaches the group within 2 s on mobile data;
   an SOS during a curve/speed warning silences the warning at once.

=== 7. OWNER DECISIONS ===
 - Overpass: the public server's policy asks apps to run their own instance; fine at today's small volume with the
   budgets, but move to an own Overpass or a regional extract on vm5 for growth.
 - Crash sensor batching: lowering the 2 s hardware batch would detect a crash up to 1.5 s sooner at a battery cost that
   needs a device measurement.
 - Home page: the "How it works" button sits partly over the road on desktop; the SOS graphic and the example trip card
   replaced phone pictures - keep or go text-only.
 - Speed-limit estimates can be wrong either way (most Indian roads have no tag; no state overrides verified): keep the
   "est." display on, or hide estimates.

=== 8. REPORT ===
 As in round 6, plus: frame timing numbers, cold-start time, SOS stopwatch results, curve/limit ride results.
```
