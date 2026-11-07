# Road context (v3.55): sharp bends, smart speed limits, high-altitude care, night riding care

All four features are phone-only safety features. They are free on every plan (Community included) and work without signal; speed limits work from cached places cells. The gateway only fetches and caches the OSM data for speed limits. Each feature has its own admin switch (group Safety, on by default, can be switched off).

## Shared wiring

- `lib/data/services/road_care_service.dart` (new): `RoadCareService` feeds the four pure classes, applies the admin switches, then speaks and shows what they return. SafetyService owns it as `safety.roadCare`. It works like this:
  - **Fix hook.** SafetyService `_onFix` calls `roadCare.onFix(p, dark: _dark, otherLimitKmh: _lastCheckedLimit, otherActive: _isOverspeedActive)` right after `_checkSpeedLimit(p)`. It is never called in an offline solo ride, because that path returns early with crash detection only.
  - **Ride reset.** `_resetRide` calls `roadCare.reset()`.
  - **Emergencies.** It is silent and shows nothing while an emergency is open. That means my crash alarm, my SOS, or any unresolved alert in the group (the same rule as engine care). Each output path checks this again before it speaks.
  - **Voice.** Bends use `speakHazard` (P2, "sharp curve"). Everything else uses `speak(priority: warning)`, so the rider's voice-warning settings apply.
  - **Cockpit card.** There is one card at a time, `roadCare.notice`, ranked bend 4 > speed 3 > altitude 2 > night 1. It is added as a `_Slot` with `AlertPriority.routeInfo` next to the engine-care slot, so SOS, assist, hazard and group-safety cards always sort above it. It can be dismissed, needs no tap, and expires by itself.
- **Cockpit** (`live_cockpit_map_screen.dart`, small insertions):
  - It lends `roadCare.activeLine = () => _guide.active` (the RouteGuide line the rider follows: a personal re-route or the group plan).
  - It lends `roadCare.roadData = () => _places?.roadContext` (the cached places cells).
  - On dispose it clears both, but only if they are still its own.
  - It adds the card slot, and a `select` so the screen rebuilds when the notice or the night flag changes.
  - If the cockpit is not open, bends fall back to the convoy route line (`convoy.route.points`) and speed limits have no data, so nothing is warned.

## 1. Sharp-bend warning (switch `bendWarning`)

- **Pure class:** `lib/domain/route/bend_advisor.dart`.
- **Detection** runs once per line instance (cached by identity) on the route polyline:
  - Heading change is measured at each vertex. Same-direction turning vertices (≥ 3°, at most 60 m apart) are grouped into one bend.
  - A bend counts when it turns **≥ 40°** in total and its tightest part has an estimated radius of **≤ 200 m**. The tightest part is the shortest run of vertices that holds 75% of the turn; the radius is its arc length divided by the turn.
  - A corner of ≥ 60° that happens within 10 m of line is treated as a **junction turn** and skipped, because the navigation voice already announces it.
  - In an S-bend the two directions become two separate bends.
- **Advisory speed:** v = sqrt(2.5 m/s² × r), rounded down to 5 km/h, never below 20 km/h. For example r 60 m → 40 km/h, r 15 m → 20 km/h, r 200 m → 80 km/h.
- **When it warns:**
  - Only when the speed is ≥ 35 km/h and notably above the advisory: at least advisory + 10 km/h **and** at least advisory × 1.2. Slow town traffic is therefore never warned.
  - Lead distance = max(150 m, 6 s of riding + the distance to slow down gently at 2.5 m/s²), capped at 600 m.
  - Once per bend, with a 20 s cooldown between warnings.
  - Bends within 250 m of each other are chained into one warning ("Sharp bends in 300 m, slow to 30") using the slowest advisory.
  - No warning when off the line (> 40 m from it), or when the fix accuracy is worse than 50 m.
- **Rider position on the line:** a windowed projection (200 m behind to 600 m ahead of the last position, or RouteGuide's last match), so stacked hairpins do not make the position jump. If nothing in the window is within 40 m, the whole line is searched.
- **Speech:** "Sharp bend in 300 metres, slow to 35." **Card:** "Sharp bend in 300 m" / "Slow to 35 km/h."

## 2. Smart speed limits (switch `speedLimits`)

- **Gateway** (`gateway/src/poi_cells.js`):
  - Two new bounded Overpass groups are queried last:
    - `nwr["amenity"~"^(school|college|kindergarten)$"]` with `out center tags 200`.
    - `way["highway"]["maxspeed"]` with `out center tags 400`.
  - `compact` keeps only `amenity` for a school zone, and only `highway`, `maxspeed`, `maxspeed:type` and `source:maxspeed` for a road. Other places keep their usual whitelist.
  - The element cap went from 1500 to 2200.
  - The cache key moved to `poi:v3:`. While a v3 answer waits for upstream budget, a v2 answer (or else a v1 answer) is served as stale (`LEGACY_CACHE_KEYS`).
- **App data:**
  - `lib/domain/places/road_context.dart` (new): `RoadContextItem` parses those elements.
  - `PoiCellData` keeps them in a new `road` list, saved to and loaded from the disk cache together with the places.
  - `PlacePoi.fromWire` still drops them, so they never appear in the visible map layer or the category chips.
  - `MapPlacesService.roadContext` returns road limit points, school zones and hospital zones. Hospital zones come only from `amenity=hospital` / `healthcare=hospital`, not clinics. The result is cached until the cells change.
- **Pure class:** `lib/domain/safety/speed_limit_advisor.dart`. It works in three steps.
  - **Parsing:**
    - Plain numbers: "50" → 50, "30 km/h" → 30, "50 mph" → 80.
    - Implicit limits: "IN:urban" → 50, "IN:rural" → 80, "IN:motorway" → 100, "zone30" → 30.
    - With several values ("60;40") the first is used.
    - "none", "signals", "walk", "variable" and anything outside 5–140 give no limit.
    - `maxspeed` is used first, then `maxspeed:type`, then `source:maxspeed`.
  - **Road limit:**
    - A road point matches when it is within 40 m of the rider, or within 150 m ahead on the rider's heading and ≤ 15 m to the side.
    - The cells carry only one centre point per way, so a matched limit stays while the rider continues ≤ 600 m on a heading within 45° of the heading at the match. A turn drops it.
    - No match means no road limit.
  - **Zones:**
    - School: within 150 m, the limit is capped at 25 km/h. This applies only Monday to Saturday, 07:00–18:00 local time, and only where the road limit is unknown or ≤ 60.
    - Hospital: within 150 m, the limit is capped at 30 km/h, but only on a road whose known limit is ≤ 60. This avoids nagging on highways and flyovers that pass hospitals.
  - **Warning:**
    - It fires when the speed stays above limit + 5 km/h for 8 s.
    - The cooldown is 60 s per zone/limit key.
    - With no data nothing is warned.
- **Coordination with the existing group/personal limit** (SafetyService `_checkSpeedLimit`): the stricter limit applies and there is only one prompt.
  - Road care stays silent when the other limit is set and is as strict or stricter (≤ the road limit).
  - It also stays silent while the existing overspeed prompt is active.
  - The existing overspeed code is unchanged.
- **Battery:** speed limits are skipped while the SOS battery reserve is active.
- **Text:** "School zone. Slow to 25." / "Hospital zone. Slow to 30." / "Speed limit 50. Please slow down."

## 3. High-altitude care (switch `altitudeCare`)

- **Fix pipeline:**
  - `TrackPoint` got an optional `altM` (default null). It is not in `toJson`, so the stored and uploaded track is unchanged and raw altitude is never shared.
  - It is set from `Position.altitude` in `soloFixFrom` and in ConvoyService's main GPS-fix path. 0, which phones report when they have no altitude, maps to null.
  - Dead-reckoning and convergence fixes carry no altitude, and the rules ignore them.
- **Pure class:** `lib/domain/safety/altitude_care.dart`.
  - The altitude used is the median of the last 5 usable fixes, so GPS spikes are ignored.
  - Each level must hold for 30 s before it counts.
- **Rules:**
  - First time above 3,000 m in the ride: "You are above 3,000 metres. Ride slower, drink water, watch for headache or dizziness."
  - First time above 4,500 m: stronger wording (thin air, rest often, go lower on a bad headache, breathlessness or confusion).
  - Climb of more than 800 m within 60 min, counted only once the rider is above 2,500 m: "Fast climb. Take a 10-minute break." After that, counting starts again from that point.
  - At most one altitude reminder every 45 min.

## 4. Night riding care (switch `nightCare`)

- **Pure class:** `lib/domain/safety/night_care.dart`. Day or night comes from SafetyService's existing `_onDarkFix` / `DarkCheck`, which computes sunset on the phone.
- **Sunset note:** once per ride, and only if the ride saw daylight first: "Sun has set. Breaks come a little earlier tonight. Keep extra distance." It is spoken, and shown as a normal-tier card for 60 s.
- **Earlier break:** after sunset the break interval is 90 min instead of 2 h.
  - The hook is next to `_fatigue.onFix` in SafetyService: if the regular prompt is not due and the fatigue reminder setting is on, `roadCare.nightBreakDue(stretchStartMs, nowMs)` is called.
  - At 90 min it gives one softer break prompt per riding stretch: a spoken line plus an important card, with no escalation.
  - The regular 2 h FatigueTracker prompt, with its confirmation and Lead escalation, is unchanged and still comes at 2 h.
  - FatigueTracker was deliberately left untouched, because the fatigue-score work may change it.
- **Brighter alerts:**
  - `RideAlert.nightContrast` is a new static flag, set by road care when it is dark and night care is on. It gives every alert card elevation 6 and a 3 px border; important cards also get the darker amber `warnText` border colour.
  - `roadCare.isNight` is exposed, and the cockpit rebuilds when it changes.

## Admin switches

`gateway/src/feature_flags.js`, Safety group: `bendWarning`, `speedLimits`, `altitudeCare`, `nightCare`. All are switchable and on by default. The app reads them through SafetyService `featureOn`, which main.dart sets to `FeatureFlagsService.on`; unknown or null means on.

## Files

- **New:**
  - `lib/domain/route/bend_advisor.dart`
  - `lib/domain/safety/speed_limit_advisor.dart`
  - `lib/domain/safety/altitude_care.dart`
  - `lib/domain/safety/night_care.dart`
  - `lib/domain/places/road_context.dart`
  - `lib/data/services/road_care_service.dart`
  - `test/road_context_355_test.dart`
  - `test/road_care_service_355_test.dart`
- **Changed (small, anchored):**
  - `lib/data/services/safety_service.dart` (field, 3 hooks, reset)
  - `lib/presentation/rider/live_cockpit_map_screen.dart` (lend line and data, card slot, select)
  - `lib/data/services/map_places_service.dart` (`PoiCellData.road`, `roadContext`)
  - `lib/domain/tracking/track_point.dart` (`altM`)
  - `lib/data/services/solo_fix_source.dart`
  - `lib/data/services/convoy_service.dart` (altitude on the main fix)
  - `lib/core/ui/ride_alert.dart` (`nightContrast`)
  - `gateway/src/poi_cells.js`
  - `gateway/test/poi_cells.test.js`
  - `gateway/src/feature_flags.js`

## Tests

- **`test/road_context_355_test.dart`** (pure; also run here through a temporary shim on the Dart VM, 22/22 pass):
  - Bend detection on synthetic lines: a straight line, a gentle r 1 km curve, an r 15 m hairpin, an r 60 m S-bend, and a junction corner.
  - Advisory speed and lead distance.
  - A one-time chained warning, no warning when slow or off the line, line caching and windowed location.
  - maxspeed parsing, wire items, road matching, sticky limits, school and hospital rules, and hold, cooldown and precedence over the other limit.
  - Altitude: the 3,000 m and 4,500 m rules, fast climb, slow climb and missing altitude, spike rejection and the 45-min repeat.
  - Night: the sunset note rules and the 90-minute interval.
- **`test/road_care_service_355_test.dart`** (Flutter test, written for `flutter test`): a bend notice, silence during an emergency or with the switch off, no limit notice without data, and the night flag and contrast. Its logic was also run here against stubs (3/3 pass).
- **Gateway:** `node --test test/poi_cells.test.js test/feature_flags_355.test.js` passes 22/22. New tests cover the v3 query groups, school and road tag trimming, and v3 caching with v2 → v1 stale fallback.
- `dart analyze lib test`: no issues in these files.

## Needs real-device / field validation

- **Bend thresholds** (≥ 40°, r ≤ 200 m, 2.5 m/s², +10 km/h and +20%) on real OSRM route geometry in the ghats and the Himalaya:
  - how many warnings per hour;
  - whether coarse OSM hairpins get mistaken for junctions (corners within 10 m are skipped);
  - whether the 6 s lead feels right at highway speed.
- **Speed limit coverage.** OSM maxspeed tags in India are patchy, so the speed limit feature will often have no data, which is by design. Real-device testing should check:
  - whether centre-point matching plus the 600 m sticky limit gives believable limits on long ways;
  - false school or hospital zones near highways;
  - the size of cell payloads and Overpass time with the two extra groups (the 25 s timeout is shared).
- **GPS altitude quality** on a range of phones (some report 0 or ellipsoid height). Check whether the median-of-5 smoothing is enough, and whether the 30 s hold delays the 3,000 m reminder too much.
- **Night:** whether the sunset note arrives at the right time with the 5-minute dark re-check, and whether the stronger card border and shadow are readable on the dark map without being garish.
- **Voice:** bend warnings use the P2 hazard queue. Check that they never overlap navigation prompts badly, and that nothing speaks while an SOS or crash alarm is open.
