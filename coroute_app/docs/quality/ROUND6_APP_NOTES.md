# Round 6 app notes (3.56 work on build 3.55.0+10026)

Companion to `APP_AUDIT_v3.56.md` and `docs/features_355/profile_photo_adjust.md`.

## 1. What was built

1. **Adjust your profile picture** (app, website, gateway): own cropper, private original + round picture + crop
   numbers, re-adjust later. `docs/features_355/profile_photo_adjust.md`.
2. **App audit**: 32 findings; 2 High and 11 Medium fixed, 3 of 9 Low fixed. `APP_AUDIT_v3.56.md`.
3. **Pending items**
   * a) Calls from the locked cockpit are gated (rule below).
   * b) "Where riders stop" on the live ride map: off by default, switch in **Places on map**, hidden during alerts.
   * c) Risky-stretch hard-brake counts need the "Help make roads safer" opt-in (app and gateway); warnings for all.
   * d) Route weather: MET Norway by default (`WEATHER_PROVIDER=metno`). Terms in section 5.
   * e) Private places (up to 3, phone only).
   * f) The cropper is not FLAG_SECURE (asserted by a test).
   * g) No TODO / FIXME in `lib/`; open follow-ups listed in the audit.

### The lock-screen call rule (a)

> A locked phone calls emergency services, and the rider's own emergency contact while the rider's own SOS or crash
> alarm is open. Every other number waits for the phone's unlock.

* Always: 112, 108, 100, 1033 (`SafetyConstants.emergencyNumbers`). They reveal nothing, and Android's own lock
  screen allows emergency calls.
* The rider's own emergency contact, only while `SafetyService.emergencyOpen` (own SOS or crash alarm): a hurt
  rider or a bystander reaches the family without a fingerprint; outside an emergency a found phone can not ring
  the owner's family.
* Everything else (another rider, another rider's emergency contact, a buddy, a place): the unlock sheet opens, the
  call starts when the unlock succeeds. Those numbers belong to other people.
* The SOS sheet (`emergency_sos_sheet.dart`) is the rider's own emergency and is **never** held back.
* Code: `LockScreenCockpitPolicy.callNeedsUnlock`, `callFromCockpit` (`locked_cockpit_gate.dart`); call sites:
  `dialNumber` (incident banner / sheet, safety card, assist sheet), buddy card, rider card.

### Private places (e): what is and is not hidden

Phone only (`SharedPreferences` key `private_places_v1`); no server storage was needed, so none was added. Within
300 m: the track recorder drops the point before it is stored or uploaded (so it is absent from trip reports, the
shared trip page, route pictures and GPX for everyone), the road-data queue treats the place as a privacy zone, and
hard brakes are not queued. **Not hidden, on purpose:** the live position during a ride (group map, guardian live
link, SOS, crash alert). Kept across sign-out (clearing them silently would switch a protection off). Picking the
place uses the normal map picker (map tiles and a reverse-lookup of the point through the gateway, like any map
search; the gateway is not told that it is a private place). Trip distance near a private place is not counted
(at most 300 m per place and pass).

## 2. Files

**New (app):** `lib/domain/media/avatar_crop.dart`, `lib/data/services/avatar_image_codec.dart`,
`lib/presentation/social/avatar_crop_screen.dart`, `android/.../ImageEncodeChannel.kt`,
`lib/domain/tracking/fix_gate.dart` (FixGate, GpsRestartBackoff, BatteryExemptionAsk),
`lib/domain/privacy/private_places.dart`, `lib/data/services/private_places_store.dart`,
`lib/presentation/settings/private_places_card.dart`, `lib/presentation/map_places/rider_stops_layer.dart`.

**Changed (app):** `lib/data/services/convoy_service.dart` (GPS gate, fix age clock, stream restart, create / join
guard, coalesced rider notifications, battery question), `background_service.dart`, `friends_service.dart`,
`group_safety_service.dart`, `intel_care_service.dart`, `track_recorder.dart`, `weather_service.dart` (comments),
`lib/main.dart` (consent + private places wiring), `lib/presentation/social/profile_screen.dart`,
`lib/presentation/security/locked_cockpit_gate.dart`, `lib/domain/security/lock_screen_cockpit_policy.dart`,
`lib/presentation/ride/incident_banner.dart`, `group_safety_cards.dart`, `rider_card_sheet.dart`,
`lib/presentation/widgets/emergency_sos_sheet.dart` (comment only), `lib/presentation/map_places/place_chips.dart`,
`lib/presentation/rider/live_cockpit_map_screen.dart` (rider stops layer, 48 dp zoom buttons),
`lib/presentation/rider/map/map_orientation_button.dart`, `lib/presentation/settings/road_safety_screen.dart`,
`lib/presentation/trip_planner/trip_review_sheet.dart`, `lib/core/l10n/strings_safety.dart`,
`android/.../MainActivity.kt` (registers `coroute/image`).

**New (tests):** `test/avatar_crop_356_test.dart`, `avatar_crop_screen_356_test.dart`, `fix_gate_356_test.dart`,
`lock_call_rule_356_test.dart`, `private_places_356_test.dart`, `round6_wiring_356_test.dart`;
`gateway/test/avatar_adjust_356.test.js`, `avatar_adjust_web_356.test.js`, `weather_met_356.test.js`,
`gateway/test/fixtures/metno_locationforecast_complete.json`. **Changed tests:** `test/l10n_test.dart`,
`test/ride316_ui_test.dart`, `gateway/test/weather.test.js`, `qa316_behaviour.test.js`, `group_safety_355.test.js`.

**New (tool):** `tool/pure_dart_test/run.sh` + `shim.dart`: runs pure Dart tests without the Flutter SDK
(`DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/fix_gate_356_test.dart`).

**Gateway (owned modules):** `src/avatars.js`, `src/social_routes.js` (avatar routes only), `src/weather_met.js`
(new), `src/geo.js` (weather section only), `src/road_risk.js`. **Website:** `public/account.html`,
`public/assets/account.js`, `public/assets/shop.css`.

**Shared files touched, smallest possible edit:**
* `gateway/public/privacy.html`: weather paragraph and provider row now name MET Norway; new short section
  "Profile picture" + its contents-list entry.
* `docs/PLAYSTORE_PERMISSIONS.md`: the Data safety row said "photos: No", which contradicted
  `play_store_compliance.md`; split into a "Photos: Yes" row and the rest.
* `docs/handbook/**` (user guide, privacy summary, Play compliance row, API reference, deployment, architecture).

## 3. Endpoints

| Change | Endpoint |
|---|---|
| New | `POST /api/me/avatar/original`, `POST /api/me/avatar/crop`, `GET /api/me/avatar/original` |
| Changed | `POST /api/me/avatar` (drops a stored original), `DELETE /api/me/avatar` and `DELETE /api/admin/users/:userId/avatar` (remove both), `GET /api/me/profile` (+ `avatarAdjustable`, `avatarCrop`, `avatarOriginalTag`) |
| Changed | `POST /api/road-risk/brakes`: stores nothing without the road-data opt-in (`reason: 'NO_CONSENT'`) |
| Changed | `POST /api/geo/weather`: same shape; `source` / `attribution` name the provider; an hour the provider did not publish is `null` |

**Nothing has to be mounted in `gateway/src/app.js`.** Every new route lives in `social_routes.js`, which is
already registered. `config.js` was not edited: `WEATHER_PROVIDER` and `WEATHER_MET_URL` are read in
`src/weather_met.js` (they are already listed in `gateway/deploy/.env.example`).

**For the gateway / deploy agent:**
* Outbound allowlist / firewall: add `api.met.no:443` (weather answers `null` points until it is reachable).
* `GEO_CONTACT` should be set: MET Norway requires an identifying User-Agent with a contact
  (`config.providerUserAgent` already carries the site and that address).
* Optional: a retention sweep for `avatars` documents with `kind: 'original', pending: true` older than a day.
* After deploy, one smoke call: `POST /api/geo/weather` with one point; expect `source: "MET Norway"` and a
  non-null point. The parser was tested against a fixture built from MET's documented model, not a live answer
  (the workspace proxy refused api.met.no).
* Full `npm test` at the end of this round: 1312 tests, 1310 pass. `config_env_example_356` fails on
  `BUSINESS_ANALYTICS`, `NODE_MEMORY_MB`, `PEER_METRICS_URL` (`src/business/*`, not this agent's files). The
  other failure (`qa316_behaviour` weather case) was this round's and is fixed.

## 4. Test results

| Check | Result |
|---|---|
| `dart analyze lib test` | No issues found |
| `dart tool/play_policy_scan.dart` | 0 hits |
| Pure Dart (stand-in runner) | avatar crop 12, fix gate 17, lock call rule 7, private places 3, round 6 wiring 6: all pass |
| Regression, pure Dart | crash detector 32, false-positive guards 6, sensor safety 34, lock-screen cockpit policy 13, Ride AOD 16, screen awake 6, intel (5 files) 40, group safety 18, speed estimator 11, location cadence 6: all pass |
| Gateway, files touched | avatar_adjust 6, avatar_adjust_web 4, weather_met 6, weather 4, group_safety 12, usernames_friends 19, qa316: all pass |
| Widget tests | written, **not run** (no Flutter SDK): `avatar_crop_screen_356_test.dart`, the changed `ride316_ui_test.dart` and `l10n_test.dart` |
| Kotlin | not compiled here; `ImageEncodeChannel.kt` uses `android.graphics.Bitmap` and Flutter's `MethodChannel` only (minSdk 23 safe) |

## 5. Weather: what the terms say (read on 2026-11-12)

| Source | Facts | URL |
|---|---|---|
| Open-Meteo, free API | "You may only use the free API services for non-commercial purposes." Commercial includes "Websites or apps that have subscriptions or display advertisements." Limits: "Less than 10'000 API calls per day, 5'000 per hour and 600 per minute." Data licence CC BY 4.0. CoRoute sells plans, so the free tier does not fit. | https://open-meteo.com/en/terms |
| MET Norway, licence | "Data and products are licensed under Norwegian license for public data (NLOD) and Creative Commons 4.0 BY"; "freely available to the public for use, dissemination and further processing"; credit "Data from The Norwegian Meteorological Institute" or "Based on data from MET Norway". The MET pages do not use the word "commercial"; the permission comes from the two licences, which both allow use for any purpose with credit (CC BY 4.0 in so many words). | https://api.met.no/doc/License , https://www.met.no/en/free-meteorological-data/Licensing-and-crediting |
| MET Norway, terms of service (last revision shown: 2026-11-05) | Identifying User-Agent with app or domain and a contact; fake or generic ones are abuse and get 403. HTTPS only. Coordinates with at most 4 decimals. "Never repeat requests until the time indicated in the Expires response header"; use If-Modified-Since. "Keep total traffic below 20 requests per second"; more needs an agreement. Mobile apps "must not retrieve new data as long as the application is not in use" and should go through a proxy. No delivery guarantee, no SLA. | https://api.met.no/doc/TermsOfService |
| MET Norway, Locationforecast 2.0 | Any coordinate on Earth; 9-10 days; outside the Nordics updated every 6 hours, "avoid repeating identical requests more often than every 3 hours elsewhere" (Expires says exactly when); `complete` has `probability_of_precipitation`, but only for 6 hour windows, not per hour. | https://api.met.no/weatherapi/locationforecast/2.0/documentation , https://api.met.no/doc/locationforecast/datamodel |
| India Meteorological Department APIs | The public page asks for IP whitelisting and "proper attribution to IMD" and states no licence or commercial terms. Not usable without an agreement. | https://mausam.imd.gov.in/responsive/apis.php |

Not read: the NLOD 2.0 text itself (`https://data.norge.no/nlod/en/2.0`, the fetch was not approved in this session)
and the Open-Meteo licence page. **Before release the owner (or counsel) should read NLOD 2.0 / CC BY 4.0 once**;
this note is an engineering reading, not legal advice.

**How the gateway follows the rules** (`src/weather_met.js`, `src/geo.js`): phones never call MET (gateway proxy);
User-Agent `CoRoute/<version> (+<site>; <contact>)`; coordinates are the 0.1 degree cell (1 decimal); a cell is kept
at least `WEATHER_CACHE_MIN` (30 min) **and** until its `Expires` time (capped at 6 h), then revalidated with
`If-Modified-Since` (304 keeps it); at most `WEATHER_PER_MIN` (20) upstream calls a minute for the whole gateway;
credit "Weather: based on data from MET Norway (api.met.no), licence CC BY 4.0 / NLOD 2.0" in the API answer, shown
by the app under the weather line, and in the privacy policy. "Based on" because the hourly chance of rain is
derived: MET gives it for 6 hours, so an hour with forecast rain is at least 60 %, a dry hour at most 45 %.
`WEATHER_PROVIDER=open-meteo` keeps the old provider for an installation that has a commercial plan with them.
Empty `WEATHER_URL` still switches weather off.

## 6. Device QA checklist

**Picture (P)**
* P1 New picture from the gallery: cropper opens; drag, pinch, slider, turn left / right, reset, double tap; Save;
  the round picture updates in My profile, People and the ride map.
* P2 New picture from the camera (front), portrait and landscape: the preview is upright (EXIF orientation).
* P3 Adjust picture later: opens the original at the saved zoom / position / turn; change and save; the public
  picture changes, the original does not get smaller or blurrier after five rounds.
* P4 Airplane mode: Adjust says the picture could not be loaded; Save shows the error and keeps the screen.
* P5 A rider with a picture from before this version: the note about the missing original shows; after Save the
  next Adjust has no note.
* P6 Remove picture: gone in the app and on /account; Adjust is no longer offered.
* P7 Website /account: Edit picture with mouse, touch and keyboard only (Tab to the preview, arrows, + -, [ ], 0,
  Tab to Save); then Adjust in the app shows the same crop, and the other way round.
* P8 A 12 MP camera JPEG and a 20 MB PNG: saved (downscaled) or a clear "too large" message; no crash, no ANR.
* P9 Download the public picture and the original (owner) and check with an EXIF viewer: no GPS, no camera model.
* P10 Screenshot of the cropper works (not FLAG_SECURE); sign-in and Medical ID still refuse screenshots.
* P11 Admin removes the picture: the rider's Adjust is gone and `GET /api/me/avatar/original` is 404.
* P12 Small phone (5 inch) and landscape: every control reachable, Save visible.

**GPS accuracy (G)**
* G1 Ride 10 km in town with stops at lights: the own marker never jumps backwards when starting from a light
  (cadence change), speed readout unchanged from 10026.
* G2 Park for 10 min with the screen on: the marker stays put (no wandering), group members see no movement, trip
  distance does not grow. Then push the bike 50 m: the marker follows.
* G3 Underpass / tunnel on a planned route: coasting starts and ends as before; at the exit the marker does not
  jump to a wild point first.
* G4 Indoors after parking (network fix of several hundred metres accuracy): the marker keeps the parking spot for
  30 s, then shows the coarse position (so "last seen" is honest).
* G5 Mock-location app on: positions are used; the diagnostics log holds one `gps_mock_provider` line.
* G6 Set the phone clock 2 min ahead (automatic time off), ride a planned route at 40 km/h: no permanent "tunnel"
  state; set it 2 min behind: coasting in a real underpass still starts. With the clock 10 min ahead the first
  seconds may be dropped (`gps_fix_dropped` in the log), then positions flow.
* G7 During a ride force-stop Google Play services' location (or toggle location off and on quickly): positions
  come back without restarting the app (`gps_stream_reopen` in the log).
* G8 Highway at 100+ km/h for 10 min: no `gps_teleport_dropped` lines.
* G9 Two phones side by side on one bike: recorded distance within 2 % of each other and of the odometer.
* G10 First ride after install, answer Deny to the battery question: it is not asked again at the next rides for a
  week; the pre-ride phone check still offers it.

**Kill and recovery (K)**
* K1 Swipe the app away mid-ride: the ride notification stays; reopening shows the same ride, track continues,
  the gap is not drawn as a straight line.
* K2 Force stop mid-ride, reopen: ride restored, pending messages sent once (no duplicates).
* K3 Reboot mid-ride: after opening the app the ride is restored; nothing starts by itself before that.
* K4 Kill during an open SOS: reopening shows the SOS still open and it is sent once.
* K5 OEM battery killer (Xiaomi / Oppo / Vivo / Samsung) with the screen off for 30 min: positions keep flowing.
* K6 Double tap "Start ride" and "Join" on a slow network (2G throttle): one ride, one membership.
* K7 Group of 20+ (or the load tool): the cockpit stays smooth; no dropped frames when a position batch arrives.
* K8 Airplane mode for 5 min mid-ride, then back: one reconnect, outbox in order, no reconnect storm in the log.
* K9 Token expiry mid-ride (15 min access token): no sign-out, no gap in telemetry.

**Lock screen, layers, privacy (L)**
* L1 Locked cockpit, another rider's SOS banner: "Call contact" asks for the unlock, then dials. "Call 112" on the
  padlock chip dials at once.
* L2 Own SOS open, phone locked: calling the own emergency contact from the SOS sheet dials at once.
* L3 Places on map sheet during a ride: "Where riders stop" is off; on shows the coffee / fuel rings; raise an SOS
  from a second phone: the rings hide; the choice survives an app restart.
* L4 Private place at home: ride away and back; the trip report, the shared trip page and the GPX start and end
  about 300 m from home; the group still saw the live position at home during the ride.
* L5 "Help make roads safer" off: brake hard five times; nothing is posted to `/road-risk/brakes` (proxy log).

## 7. Play Data safety

* **Photos:** already declared (profile picture, review photos) in
  `docs/handbook/compliance/play_store_compliance.md`. The private original is the same data type, same purpose
  (app functionality), optional, not shared, deletable: **no new data type**; the row's description was updated.
  `docs/PLAYSTORE_PERMISSIONS.md` contradicted it ("photos: No") and was corrected. Check that the live Play
  Console form says Photos = collected, not shared, optional.
* **Location:** no change in what is collected. Private places are never sent. Fewer points are uploaded near
  them; hard-brake cells are collected only with the opt-in.
* **No new permission**, no new SDK, no new pub dependency. Weather goes to MET Norway instead of Open-Meteo
  (rounded route points, from the server): update the "third parties" list in the store listing's privacy policy
  (the website policy is updated).
