# CoRoute feature status (as of v3.55 code, Nov 7, 2026)

Status legend:

- **Stable (code)**: implemented, analyzer clean, covered by gateway tests and/or pure-logic tests. Still needs the normal phone check before release.
- **Needs device check**: implemented, but correctness depends on sensors, radios, OS behaviour or real roads that cannot be tested here.
- **Pending**: planned, not built yet.
- **Not stable**: known open risk (see notes).

Admin switch: the id in Admin > Feature switches (`gateway/src/feature_flags.js`). "Locked" = can never be switched off.

## Safety (every rider, Community included)

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| SOS (hold, durable delivery, SMS fallback, lock screen) | Stable (code) · Needs device check | `sos` (locked) | No switch or plan can disable it; BLE remote SOS gestures and mesh SOS keep working even when their switches are off. |
| Crash detection (incl. slow traffic, false-positive suppression) | Needs device check | `crashDetection` (locked) | Road-surface detection never runs during a crash evaluation (3.55 fix D6). |
| Emergency texts / roster | Stable (code) | `emergencySms` (locked) | |
| Medical ID on lock screen | Stable (code) | `medicalId` (locked) | |
| Guardian live link | Stable (code) | `guardianLink` | |
| Nearby riders assistance network | Stable (code) | `assistNetwork` | App-side switch only (shares the emergency text path). |
| Pre-ride phone check | Stable (code) | — | |
| Siren detector | Needs device check | `sirenDetector` | |
| Handlebar BLE remote | Needs device check | `bleRemote` | Switch off stops talk and hazard marking only, never SOS. |
| Offline phone-to-phone mesh | Needs device check | `offlineMesh` | Switch off = SOS-only mode. |
| Road hazards from the lead (pothole, speed breaker, rough road) — new 3.55 | Needs device check | `roadHazards` | Thresholds need real-road tuning (mount vs pocket). |
| Saved road reports for later rides — new 3.55 | Stable (code) | `roadHistory` | No rider ids stored; expiry by kind; "Fixed?" counts once per rider. |
| Engine rest advice from bike details — new 3.55 | Stable (code) | `engineCare` | Rules of thumb, not a temperature reading. |
| Fuel range, warnings and auto-route to fuel (stabilised in 3.55) | Stable (code) · Needs device check | `fuelAutoRoute` | Offline retry and arrival detection need a real ride. |

## Riding and groups

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Live group map, regroup, spread / behind-sweeper alerts | Stable (code) | — | |
| Riding roles Lead / Middle / Sweeper, swap, position prompts — new 3.55 | Stable (code) | `rideRoles` | Owner keeps rights; leader leaving hands the lead back to the owner. |
| Automatic roles (front leads, last sweeps) — new 3.55 | Stable (code) | `autoRoles` | Off by default; automatic lead has no lead rights. Two-node split can briefly show two leads (open risk). |
| Off-route "Route to group" prompt — new 3.55 | Stable (code) · Needs device check | `offRouteGroupPrompt` | Needs a tap: shown when off route; voice asks to open CoRoute when safe. |
| Bike / rider-pillion swap — new 3.55 | Stable (code) | `vehicleSwap` | Pending asks live in memory; a failover drops them (rider asks again). |
| Push-to-talk intercom | Needs device check | `intercom` | |
| Group fuel sharing | Stable (code) | `groupFuel` | |
| Public ride, safe contact, road warnings from oncoming riders | Stable (code) | `publicRide` | |
| Nearby group discovery | Stable (code) | `discovery` | |
| Trip report, replay, ride analytics | Stable (code) | `rideAnalytics` | |
| Weather on the route | Stable (code) | `weather` | |

## Places

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Map places (fuel by type, hospitals, mechanics, food, stays…) — medium icons in 3.55 | Stable (code) | `mapPlaces` | Emergency hospitals stay visible even when switched off. |
| Route essentials | Stable (code) | `essentials` | |
| Historic places on the way — new 3.55 | Stable (code) | `heritagePlaces` | OSM coverage varies. |
| CoRoute rider place reviews (dwell prompt, stars, photo, map badge, moderation) — new 3.55 | Stable (code) | `placeReviews`, `reviewPrompt` | Photos shown after admin approval. Prompt after the ride ends is not shown yet (cockpit only). |

## Plans, admin, website

| Feature | Status | Notes |
|---|---|---|
| Community free / Small Group / Large Group, prorated upgrades, coupons | Stable (code) | |
| Admin "Change plan" gives a real membership — fixed in 3.55 | Stable (code) | Run "Reconcile" once after deploy. |
| Data cleanup removes memberships — fixed in 3.55 | Stable (code) | Mass-deletion guard in the daily purge. |
| Guest mode | Removed in 3.55 | Old guest sessions signed out with a message. |
| Admin feature switches — new 3.55 | Stable (code) | Locked safety ids. |
| Website: live usage + impact numbers, iOS coming soon, all pages redesigned — 3.55 | Stable (code) | Sections stay hidden until numbers pass the privacy floor (10). |
| iPhone app | Pending | TestFlight, then set the App Store URL; website switches automatically. |
| Play Store listing | Pending | Then set `PLAY_STORE_URL`. |

## v3.55 plan features built in phase 2 (Nov 8, 2026)

All are code-complete, analyzer clean, with pure-logic tests (and gateway tests where the server is involved). Every one has an admin switch. Details, thresholds and device checks: [features_355/](features_355/).

| Feature | Status | Admin switch | Doc |
|---|---|---|---|
| Sharp-bend warning | Needs device check | `bendWarning` | road_context.md |
| Smart speed limits (OSM maxspeed, school/hospital zones) | Needs device check (OSM coverage patchy) | `speedLimits` | road_context.md |
| High-altitude care | Needs device check (GPS altitude) | `altitudeCare` | road_context.md |
| Night riding care | Stable (code) | `nightCare` | road_context.md |
| Adaptive fatigue score | Needs device check | `fatigueScore` | sensor_safety.md |
| Rider-down check (bike falls when stopped) | Needs device check | `riderDown` | sensor_safety.md |
| Crash detection that learns from "I'm OK" (severe path never learns) | Needs device check | `crashLearning` | sensor_safety.md |
| Phone-mount check | Needs device check | `mountCheck` | sensor_safety.md |
| SOS battery reserve (<10 %) | Stable (code) · Needs device check | `sosBatteryReserve` | sensor_safety.md |
| Private ride safety report | Stable (code) | `safetyReport` | sensor_safety.md |
| Solo check-in by ETA | Needs device check (SMS in background on Play builds) | `soloCheckIn` | solo_guardian.md |
| No-signal ahead (own coverage log) | Needs device check | `noSignalAhead` | solo_guardian.md |
| Arrival message to guardians (link expires) | Stable (code) | `arrivalMessage` | solo_guardian.md |
| Help from public riders (consent) | Stable (code) | `publicRiderHelp` | solo_guardian.md |
| Start and arrival roll call | Stable (code) | `rollCall` | solo_guardian.md |
| Missing-rider check | Needs device check | `missingRiderCheck` | group_safety.md |
| Group stretch alert (lead threshold) | Stable (code) | `stretchAlert` | group_safety.md |
| Smart regroup point | Stable (code) | `regroupSuggest` | group_safety.md |
| Group break planner (levels only) | Stable (code) | `groupBreak` | group_safety.md |
| Buddy pairs (7+ riders) | Stable (code) | `buddyPairs` | group_safety.md |
| Risky-stretch heads-up (k ≥ 10 riders) | Stable (code) | `riskyStretch` | group_safety.md |
| Admin warnings delivered to riders | Stable (code) | `adminWarnings` | platform.md |
| Offline crash-incident queue | Retired (duplicate of the pending-SOS store, which already resends offline SOS once) | — | platform.md |
| Voice-command / siren services at start-up | No longer started at launch (no audio source) | — | platform.md |

## Still pending (cannot be done in code here)

- Flutter `flutter test` + Gradle release build; real-device rides for every "Needs device check" row.
- OCI two-VM deploy, failure drills, 30-min soak test (sets the live-rider cap), monthly restore test.
- Move review photos and APKs to Object Storage (code exists; settings only — steps in features_355/platform.md).
- Rotate the leaked JWT secret and DB password (runbook in features_355/platform.md; use a short 24–72 h grace window).
- Own domain instead of DuckDNS (steps in platform.md). iPhone TestFlight / App Store and Play Store listing.
- Small follow-ups: a text box for the admin "Warn" message (riders get a default guidelines line today); place-review question after the ride ends; "Need help" in the missing-rider check asks the group to wait rather than raising an SOS (confirm).

Product decisions still open: see [UX_NAMING_GUIDE_v3.55.md](UX_NAMING_GUIDE_v3.55.md) §4 (e.g. rename "Trip head" vs riding "Lead", taps needed while moving for off-route/swap/heritage cards, emergency button wording) and the owner decisions in the original v3.55 plan (medical-info consent switches, convoy join without a plan, credit beyond plan price, domain timing).
