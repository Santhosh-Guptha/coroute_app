# Round 7 safety notes (for the lead)

Curve prediction, road speed limits, faster safety response, responsive cockpit chips. Build stays 3.55.0+10026.
Design and sources: `docs/features_355/curve_and_speed_limit.md`.

## 1. What was built

| Area | Result |
|---|---|
| Curve prediction | New pure engine (resample 10 m, smoothed curvature, class / side / series, advisory speed, time-based warning, no-nag, once per bend). Route line, or road cells in free riding with map matching and "most likely continuation". Learned bends from hard-brake / skid cells. |
| Road cells | Gateway cache in front of Overpass per geohash-6 cell (30 days, gzip, ETag, byte-bounded memory, per-minute / per-day budget, backoff, concurrency 1). Phone: prefetch around the rider and along the route, 30 MB disk LRU. |
| Speed limits | Map tag -> rider correction -> implied type -> estimate table (data file, sources, confidence). Cockpit sign, "~ est." style, overspeed rule (tolerance, strong level, voice once), school / hospital, limit-drop announcement. |
| Corrections | One-tap "wrong limit" (standing still or after the ride), consent, k >= 3 riders, never upward, admin list / reject / apply API. |
| Faster safety | See section 3. |
| Warning scheduler | One scheduler for all advisory voice lines (priorities, gaps, 4 a minute, never two at once, emergency pre-emption). |
| Cockpit | Limit sign + bend chip behind a RepaintBoundary with their own listenable; layout per screen form; other riders' markers dead-reckon past a late report. |
| Settings | Card "Bends and speed limits" in Settings > Road safety. |

## 2. Files

**New (app):** `lib/domain/road/{curve_predictor,road_cell,road_matcher,road_ahead_engine,speed_limit_resolver,india_speed_limits,cockpit_layout}.dart`,
`lib/domain/safety/{warning_scheduler,sos_fast_path}.dart`, `lib/domain/net/inbound_frame_sequencer.dart`,
`lib/data/services/road_data_service.dart`, `lib/presentation/rider/widgets/{road_ahead_chips,road_ahead_settings_card}.dart`.

**Changed (app, my area):** `lib/domain/tracking/nav_motion.dart` (`GlideTrack`), `lib/data/services/road_care_service.dart`
(engine, scheduler, `roadView`), `safety_service.dart` (wiring only: `_roadAhead`, `roadData`, prefs), `intel_care_service.dart`
(two hooks), `settings_service.dart` (4 settings), `convoy_service.dart` (`_sendSosOverHttp`), `realtime_service.dart`
(frame sequencer), `group_safety_service.dart` (`advisoryGate`), `lib/presentation/rider/live_cockpit_map_screen.dart`
(chips, `_triggerSos` fast path, wrong-limit sheet), `widgets/smooth_rider_marker_layer.dart` (GlideTrack),
`android/.../AccelStream.kt` (impact bucket flushed at once).

**Changed (Agent U's area, minimal and additive):** `lib/presentation/settings/road_safety_screen.dart`: one import and
one section (header + `DsCard` holding `RoadAheadSettingsCard`) at the end of the list. Nothing in `lib/core/**`,
`lib/main.dart` or `lib/core/l10n` was touched (new texts are English literals, like the other road-care lines).

**New (gateway):** `src/road_cells.js`, `test/road_cells_357.test.js`, `test/safety_fast_sos_http_357.test.js`,
`test/fixtures/overpass_roads_cell.json` (hand-made, not copied from OSM).
**Changed (gateway):** `src/app.js` (mount, returned object), `src/routes.js` (`roads` in `/api/health`,
`POST /convoys/:groupId/sos`), `deploy/route_split.md`, `deploy/caddy/Caddyfile.vm1` (regenerated),
`deploy/.env.example`.

**Docs:** `docs/features_355/curve_and_speed_limit.md` (new), this file (new),
`docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md` (section 9b), `docs/handbook/users/user_guide.md` (section 12),
`docs/handbook/technical/api_reference.md` (4 rows).

**Tests (Dart, pure):** `test/curve_speed_curves_test.dart` (19), `curve_speed_limits_test.dart` (23),
`curve_speed_engine_test.dart` (8), `curve_speed_cockpit_layout_test.dart` (4), `safety_fast_scheduler_test.dart` (16),
`safety_fast_sos_path_test.dart` (5). Run: `DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/<file>`.

## 3. Faster safety response: what was found, changed and measured

| Path | Before | After | Measured |
|---|---|---|---|
| SOS, position in the rider record | sent synchronously | unchanged | n/a |
| SOS, no position in the rider record but the safety service has a fix | waited for a fresh GPS fix, up to 5 s | sent in the same call, before any await | test: 800 ms simulated GPS -> under 10 ms |
| SOS, no position in memory | fresh GPS fix, up to 5 s | system last-known position, at most 300 ms, then fresh fix (5 s cap), then sent anyway | test: 900 ms -> under 250 ms |
| SOS transport | socket only (a half-dead socket is noticed after up to 100 s) | socket + HTTP `POST /convoys/:gid/sos` in parallel, de-duplicated by clientId on the gateway | gateway test: one alert whichever lane is first |
| SOS vs UI / analytics | `_raise` already saved, sent and logged with no await; the sheet opened after | unchanged; the SOS sheet still opens after the send | code review |
| SMS | deliberate fallback 45 s after an unconfirmed SOS (`smsFallbackAfter`) | **not changed** (changing it would change the false-SOS behaviour agreed in 3.55) | n/a |
| Crash: sensor -> Dart | 50 Hz, hardware batch up to 2 s, 1 s buckets, flush spacing 500 ms, one main-thread hop | a closed bucket with a peak of 3 g or more is flushed at once (up to 0.5 s sooner); buckets unchanged | not measurable here (Kotlin, device) |
| Crash: alarm UI / sound | `_openAlarm` sets state, starts the native alarm notification (not awaited), haptic, `notifyListeners`; the host pushes the screen from the listener | unchanged: already within one frame, sound does not wait for the route | code review |
| Alerts from others | each socket frame handled on arrival | small frames as before; frames of 96 KB or more decoded off the UI thread; while frames wait, alerts overtake positions, never a snapshot | test: order `[batch, ALERT, pos, pos]` |
| Advisory voice | separate cooldowns per feature | one scheduler | 8 tests |
| Markers | linear tween to each report, stop until the next | dead reckoning past a late report (at most 60% of the interval, 1.2 s), eased, no jump | test: no stall, no backwards step, bounded coast |

Not changed on purpose: `accelMaxLatencyUs` (2 s hardware batching). Lowering it to 500 ms would cut up to 1.5 s
from crash detection at a battery cost that needs a device measurement: **owner decision**.

Pre-warm at ride start: the emergency roster, message text and contacts were already cached by
`ConvoyService` / `SafetyService` (roster store, `PendingSosStore`); the only cold item found was the position, now
covered by the fast path above.

Not measurable here: frame rate, real sensor latency, real network latency (no Flutter SDK, no device).

## 4. Env vars, endpoints, route split, collections

| Env (all optional) | Default |
|---|---|
| `ROAD_CELLS_OVERPASS_URL` | falls back to `POI_OVERPASS_URL`, then `ESSENTIALS_OVERPASS_URL` |
| `ROAD_CELLS_TTL_DAYS` | 30 |
| `ROAD_CELLS_MEM_MB` | 12 |
| `ROAD_CELLS_UPSTREAM_PER_MIN` | 6 |
| `ROAD_CELLS_UPSTREAM_PER_DAY` | 2000 |
| `ROAD_CELLS_CONCURRENCY` | 1 |
| `ROAD_LIMIT_K_MIN` | 3 (never below 3) |

| Route | Class | Access |
|---|---|---|
| `GET /api/geo/roads?cell=` | WEB (new row) | signed-in rider |
| `POST /api/geo/limit-corrections` | WEB (new row) | signed-in rider, consent |
| `GET /api/admin/geo/limit-corrections`, `POST /api/admin/geo/limit-corrections/:way` | WEB (existing `/api/admin/*` row) | MASTER_ADMIN |
| `POST /api/convoys/:groupId/sos` | LIVE (new row) | signed-in member of the ride |

Collection `road_limit_votes` (created at boot). `geo_cache` keys `roads:v1:<cell>` (gzip, base64). Memory per node:
at most `ROAD_CELLS_MEM_MB` of gzip buffers plus one cell being built (a cell document is capped at 1,200 ways /
14,000 points, the Overpass answer at 64 MB by `maxsize`, typically well under 1 MB).

## 5. Requests for other agents

**Agent U (app UX):**
1. `lib/main.dart`: one line so "falling behind" goes through the scheduler:
   `gs.advisoryGate = safety.roadCare.mayAdviseFallingBehind;` (next to `..alarmOpen`). Without it the voice works as before.
2. `RoadAheadSettingsCard` and `WrongLimitSheet` use plain Flutter (SwitchListTile, ListTile, OutlinedButton,
   `showModalBottomSheet`). When the UI kit has settings rows / the app bottom sheet / haptics / skeletons, adopt
   them there. `RoadAheadChips` could use the motion helpers for the chip appearing (it has no animation now).
3. `lib/core/l10n`: the new texts are English literals (curve / limit speech, chip labels, settings card). Move them
   to the string tables when the other road-care lines move.
4. Help / features guide: add "Bends and speed limits" using `RoadAheadSettingsCard.estimatedHelp`.

**Agent W (website / web admin; `gateway/public` was not edited):**
1. Web admin page "Speed limit corrections" (Intelligence group): table from `GET /api/admin/geo/limit-corrections`
   (`items[]`: way, cell, status, applied, tagKmh, riders, values, shown, updatedAt, osm link; `kMin`; `health`), filter
   `?status=open|applied|rejected`, buttons Reject / Reopen / Apply (`POST .../:way {action, kmh}`), a 409
   `ABOVE_OSM_TAG` shown as "fix the tag in OpenStreetMap". Add its script to the admin CSP as usual.
2. Servers / health page: show `health.roads` (cells in memory, bytes, backoff, calls today).
3. Attribution: the site footer / about should say road and place data are "(C) OpenStreetMap contributors (ODbL)".
4. `privacy.html`, suggested addition under road and safety data:

> **Speed limit reports.** If you tell us a speed limit shown in the app is wrong, we store the road, the value you
> chose and a one-way code that stands for your account (not your name or rider id), so that one rider counts once.
> We use it only to correct the limit shown to riders once at least three riders agree. This needs "Help make roads
> safer" to be on. Your reports are deleted with your account. When the app fetches road data it sends the map square
> it needs (about 1 km), not your position or route.

   Consent register rows: `road_limit_votes` (consent; until account deletion), `geo_cache roads:v1:*` (no personal data).

## 6. Owner decisions

1. **Overpass.** The public instance's policy asks apps for non-OSM users to run their own instance. The budgets keep
   use small (2,000 calls a day per node at most, 30-day cache). For growth: own Overpass or a regional extract
   behind `ROAD_CELLS_OVERPASS_URL`.
2. **Accelerometer batching** (section 3).
3. **Estimated limits never speak.** Change only after field checks.
4. **Corrected limits are shown without "~".** They are rider reports, not signs; say if "~" is preferred.
5. **State overrides** are empty until a notification is verified.
6. **Old gateways.** The app's HTTP SOS lane and road cells need this gateway; with an older one they fail quietly
   (404 / no data) and everything else works as before.

## 7. Known gaps (honest list)

* Flutter widget tests could not be run (no SDK). `dart analyze lib test` is clean; pure logic is tested. The new
  widgets, `RoadCareService` wiring, `RealtimeService` sequencer wiring and the Kotlin change are **untested on a
  device**.
* Existing Flutter tests that push socket frames of 96 KB or more through `RealtimeService.debugReceive` would now
  see them delivered asynchronously (none was found by reading; not run).
* Advisory voice lines that used to overlap in time are now spaced or dropped by the scheduler (cards unchanged);
  a 3.55 test that counts spoken lines with a fake voice could notice (the existing `road_care_service_355_test`
  uses no voice).
* Rain is never set (no licensed live weather on the phone).
* The typical-speed sanity check has no data on the phone yet (the `rd` aggregates are not served as speeds).
* The phone does not send `If-None-Match` (ApiClient does not expose headers); it refetches a cell after 7 days.
* Wrong-limit list survives only until the next ride starts or the app is closed.
* Lock-screen cockpit and Ride AOD: the chips are part of the same cockpit column and hide in an emergency; the
  wrong-limit sheet is refused while locked. Not checked on a device.

## 8. Device QA checklist

**Curves**
- V1 Known ghat with a planned route (dry, daylight): each hairpin taken 10+ km/h above the advisory is announced
  once, 6-8 s ahead, with the right side; the chip shows arrow, speed, distance and goes after the apex.
- V2 Same road at or below the advisory speed: silence. Straight highway for 10 km: silence.
- V3 Stacked hairpins: one "Series of bends for ... km"; no voice per hairpin.
- V4 Free riding (no route) on the same ghat with signal at the start: warnings as in V1 after the first 1-2 km.
- V5 Free riding in flight mode after V4 (cells on disk): same warnings. Fresh area in flight mode: silence, no error.
- V6 After sunset: the advisory is 5 km/h lower on medium bends.
- V7 Junction turn on a route: only the navigation voice speaks. Fork in free riding: no warning for the branch not taken.
- V8 Curve warnings off in Settings: no voice, no chip. Admin switch `bendWarning` off: same.
- V9 During an SOS / crash alarm: no chip, no voice; they return after it is resolved.

**Speed limits**
- V10 Road with a posted and mapped limit: plain sign with that number. Car limit 100 on a highway: sign shows 80.
- V11 Road without a tag: "~" number with "est."; compare with the table for city street, rural road, residential lane.
- V12 Over a mapped limit by more than the margin for 2 s: one voice line, then only the red ring; 20% over: filled
  red and one more line. Back under for 20 s, over again: speaks again.
- V13 Over an estimated limit: sign colours only, no voice.
- V14 Tolerance 5% and 20%: the threshold moves (never under 5 km/h).
- V15 Entering a lower limit above it: "Speed limit now 40." Entering a higher one: silence.
- V16 School with a mapped road limit on a weekday morning: warning without margin; Sunday: normal margin.
- V17 Group / personal limit stricter than the road's: only the group warning speaks.
- V18 Standing still: tap the sign, choose a value, snackbar thanks; moving: tap does nothing. Three accounts report
  the same value: the sign changes after the cell refreshes (up to 7 days, or Clear road data).
- V19 Settings > Road safety: switches persist over a restart; storage size grows on a ride; Clear empties it.

**Faster safety**
- V20 SOS stopwatch: hold completes -> group phone shows the alert. Record with good signal, weak signal, and right
  after switching Wi-Fi to mobile data (the HTTP lane should deliver while the socket reconnects).
- V21 SOS in the first seconds of a ride before the first GPS fix: sent within about half a second, position filled.
- V22 Diagnostics log has `sos fast_path` (src, waitMs) and `sos http` (ok, ms).
- V23 Crash test rig (`docs/SAFETY_DEVICE_TESTS.md`): time from impact to alarm sound; compare with a 3.55 build.
  False-positive guards unchanged (pothole, phone drop, speed breaker).
- V24 Other rider's SOS in a 50+ rider group: banner appears without the map freezing.
- V25 Two warnings due together (hazard + bend + rough road): one voice at a time, bend / hazard first, nothing over an SOS.

**Cockpit and performance**
- V26 Marker smoothness: follow a rider at 1 Hz and on a weak network (reports every 2-3 s): bikes glide, no jumps,
  no sliding backwards on braking.
- V27 320 dp phone, 360 dp phone, large text (1.3 and 2.0), landscape handlebar mount, tablet, split screen: sign
  and chip never overlap the top bar, speed alert, action column or SOS; primary controls stay 56 dp.
- V28 Lock-screen cockpit and Ride AOD: sign and chip visible when unlocked-over-lock, no tap action while locked;
  AOD unaffected.
- V29 Low-end phone profiling (profile build, DevTools): rebuild counts for the cockpit at 1 Hz (the chips rebuild
  alone on a limit / bend change), raster and UI thread under 16 ms with 20 riders, jank during a snapshot of a
  large group, memory with 24 road cells loaded, battery over a 2 h ride with road data on vs off.
