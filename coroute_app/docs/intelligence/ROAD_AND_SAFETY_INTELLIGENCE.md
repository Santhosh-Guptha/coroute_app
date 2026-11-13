# Road & safety intelligence (v3.55 round 4, build 10026)

Safety first, then business. Everything runs on what we have today: 2 × OCI E2.1.Micro (1/8 OCPU, 1 GB) and the
Always Free Autonomous DB. Capacity reasoning and measured numbers: [CAPABILITY_v3.56.md](CAPABILITY_v3.56.md).
Business analytics (built in round 6) and what waits for vm5: [BUSINESS_ANALYTICS.md](BUSINESS_ANALYTICS.md). Release prompt:
[../NEXT_AGENT_PROMPT_v3.55_round4_intelligence.md](../NEXT_AGENT_PROMPT_v3.55_round4_intelligence.md).

Licences: all own code, plus Leaflet 1.9.4 (BSD-2-Clause, admin maps only, [licence](licenses/LEAFLET_LICENSE.txt)).
Valhalla (MIT) and OSRM (BSD-2) are servers, not linked code. Map data OpenStreetMap (ODbL, attribution shown).
No paid API, no service with non-commercial terms is added. Weather is excluded (see §9).

## 1. What was built

| # | Feature | State | Where |
|---|---|---|---|
| 0 | Privacy base: opt-in consent, trimming, k-anonymity, monthly keyed hashes, 90-day raw retention, delete / export | **Done** | `gateway/src/intel/privacy.js`, `engine.js`, `routes.js`; app `intel_care_service.dart`, `road_safety_screen.dart`, `intel_prompt_host.dart`; website `/account#roads` |
| 1 | Hazard hotspots + "Hazard ahead" warning | **Done** (device check pending) | gateway `hz` cells; app `AheadMonitor`, `RideSignalDetector`; admin Hazard map |
| 2 | Crash brain (fewer false alarms) | **Done, shadow by default** | `gateway/src/intel/crash_brain.js`; app `CrashBrainParams`, `CrashDetector.setBrainImpactScale`; admin Crash brain |
| 3 | Falling behind + regroup suggestion | **Done** (2-phone check pending) | app `FallingBehindPredictor`, `RegroupAdvisor`, `GroupSafetyService` |
| 4 | Fatigue and night nudges | **Done** | app `LongRideNudges` (phone only) |
| 5 | Real rider stops + no-fuel gaps | **Done** (map layer in Plan a ride only, not on the live cockpit map) | gateway `st` cells, `fuelGaps`; app "Where riders stop" layer + fuel gap warning in Plan a ride, `FuelGapFinder`, regroup suggestions |
| 6 | Motorcycle ETAs from own data | **Done** (needs data to show) | gateway `rd` cells, `etaAdjust` in `POST /api/geo/route`; app "ETA based on riders" |
| 7 | Road quality / potholes | **Done** | app `PotholeIntelGate`; gateway `rq` cells; admin Road quality; app "Rough road ahead" |
| 8 | Twisty roads / ghat score | **Done** | gateway `rd` turn per km; app `TwistyMeter` (ride report), `TwistyAhead` |
| 9 | Dangerous times per region | **Done** (no weather) | gateway `dt` cells, `rideTip`; admin Dangerous times |
| 10 | Valhalla motorcycle routing | **Prepared, owner-gated** | `gateway/src/intel/router_adapter.js`, `gateway/deploy/valhalla/` |
| B | Business analytics | **Built in round 6** (micro-VM sized) | [BUSINESS_ANALYTICS.md](BUSINESS_ANALYTICS.md) |

## 2. Data flow

```
 phone (consenting rider)                         gateway (any node)                     job-lease holder (one node)
 ───────────────────────                          ──────────────────                     ───────────────────────────
 hard brake / swerve / skid / pothole  ──batch──► POST /api/intel/events ─┐
   (trimmed 300 m, privacy zones, queued offline)                         │
 crash alarm numbers + outcome ─────────────────► POST /api/intel/crash ──┤  intel_raw (insert only,
 "Was this a real crash?" ──────────────────────► POST /api/intel/crash/feedback  monthly rider hash, 90 days)
                                                                           │                 │ every 5 min
 WS positions (already sent for the ride) ──────► accumulator per rider ──┤                 ▼
                                                  (trim FIFO, cells, stops) │       intel-aggregate: fold rows into
 SOS / crash alert raised ──────────────────────► convoys 'emergency' ─────┘       intel_cells (decayed, distinct riders)
                                                                                    intel-daily: purge, prune, crash
 everyone: GET /api/intel/hazards|road-quality|twisty|stops?tiles=…  ◄── both nodes read, 10 min cache per tile
           GET /api/intel/ride-tip, /crash-params, POST /api/geo/route (ETA factor), POST /api/intel/fuel-gaps
```

Riders without consent send nothing extra: their positions reach the gateway for the ride as before, and the
intelligence ignores them (one cached lookup per position).

## 3. Privacy (DPDP-minded; legal review still open)

| Rule | How it is enforced | Test |
|---|---|---|
| Opt-in, off by default, timestamped | `intel_consent` doc per rider: `on`, `at`, `source`, `promptedAt`, last 20 changes | `intel_privacy_356` consent |
| One-time friendly prompt after the first completed ride | `ConsentPromptPolicy` + `IntelPromptHost` (never riding / during an alarm; "Not now" remembered) | `intel_consent_prompt_356_test.dart` |
| Only consenting riders feed aggregates | consent checked at ingest **and** again when raw rows are written; off discards open ride counters and the phone's queue | `intel_privacy_356` gating |
| Everyone receives warnings | read endpoints need a sign-in only; no consent check | `intel_hazards_356` API |
| First / last 300 m dropped | gateway `RideTrimmer` (start radius + 300 m path FIFO thrown away at ride end), phone `IntelEventQueue` (same) | both |
| Near saved home / work | zone support in both trimmers. **The app has no saved home / work places today**, so the list is empty; ready for when they exist | unit tests with a zone |
| SOS / crash cells | start trim applies; **end trim does not** (a crash often ends the ride where it happened; the cell is the hazard). Documented exception | `intel_hazards_356` |
| k-anonymity | a cell is answered only with ≥ `INTEL_K_MIN` (5) distinct riders in one India month (current month's set or the best past month) | `intel_privacy_356` k-min |
| Rider ids | never stored: `HMAC-SHA256(INTEL_HASH_KEY, month|userId)`, 16 hex chars on raw rows, 10-char prefix in a cell's current-month set (≤ 64), dropped at month change (only the count stays) | distinct counting test |
| No medical data, no phone numbers | none of the inputs carry them; crash features are numbers, phone maker, path, outcome | review |
| Raw rows deleted after 90 days | `intel-daily` `purgeRaw` (`INTEL_RAW_DAYS`) | retention test |
| Aggregates decay | half-life 90 days (`INTEL_HALF_LIFE_DAYS`); near-zero cells pruned | decay test |
| Delete my contributions | app Settings > Road safety, website `/account#roads`, admin Data & privacy: unprocessed rows deleted at once; processed rows (≤ 90 days) are marked and the next run **subtracts them exactly** (decay-aware) from the cells and removes the rider's hash from current sets, then deletes them | delete test |
| What cannot be deleted (told honestly) | contributions older than 90 days live only inside anonymous decayed totals; de-identified crash training rows (no hash, no time finer than a month, no position) | wording on all three surfaces |
| Account deletion | `deleteUserCascade` → delete contributions + consent record | gateway test |

**Crash alarm data and consent (decision taken, owner to confirm).** Crash features carry no position, but they are
linked to a rider's monthly hash while raw. They are collected **only with "Help make roads safer"** (conservative).
DPDP §7 "legitimate use for safety" could allow collecting the outcome without consent; that needs legal review
(owner decision O-2).

## 4. Thresholds

| Signal | Rule (phone) |
|---|---|
| Hard brake | existing `HardBrakeCounter`: peak 1.6-4 g + ≥ 20 km/h drop within 6 s, one per 10 s |
| Swerve | rotation ≥ 2.6 rad/s at ≥ 30 km/h, tilt < 25° (no corner lean), below crash level, mounted phone, one per 20 s |
| Skid | rotation ≥ 2.0 rad/s + tilt ≥ 30° at ≥ 15 km/h, then a ≥ 12 km/h drop within 4 s |
| Pothole / rough | existing `RoadSurfaceDetector`; shared only above 20 km/h; pocket / loose skipped; unknown mount confidence × 0.5; speed breakers never |
| SOS / crash | from the gateway's alert (sources MANUAL / CRASH_AUTO / NEED_HELP / WEARABLE; reports by others excluded) |

| Aggregate | Rule (gateway) |
|---|---|
| Hazard score | weights crash 5, SOS 4, skid 3, swerve 2, hard brake 1 (× confidence), decayed; public answer when raw ≥ 3 (score ≥ 15 of 100); `high` at ≥ 10 |
| Direction | 8 heading buckets; a cell lists buckets with ≥ 25 % of the directed score |
| Road quality | pothole 1, rough 0.5; public at raw ≥ 2 |
| Stops | still within 60 m for 4-90 min on the trimmed track; geohash-7; typical minutes; 4-hour time-of-day band; cached place within 150 m |
| ETA factor | per leg: riders' time / router time over the covered part; ≥ 50 % of the leg covered by cells with ≥ k riders and ≥ 120 s of data; capped 0.6-1.6 |
| Twistiness | heading change per km at ≥ 20 km/h (steps ≥ 15 m, turns < 120°); score = deg/km ÷ 3, max 100; ghat ≥ 50 (150°/km); needs ≥ 2 km ridden in the cell |
| Dangerous times | geohash-4 × weekday/weekend × hour; best 2-hour window; pre-ride tip when this hour carries ≥ 2× its share and ≥ 8 % of the region's signals |

| Warning (phone) | Rule |
|---|---|
| Hazard ahead | 300-500 m ahead, bearing within 35° of my heading, cell direction ±45°, ≥ 15 km/h, accuracy ≤ 50 m, **one per 2 km**, never the same cell twice per ride, never over an SOS / crash UI (rank 4 in the road care slot; also on the lock-screen cockpit) |
| Rough road ahead | same geometry, **one per 5 km**, rank 1 (lowest), on by default |
| Twisty section | sections of ≥ 2 km on the planned route, heads-up 1 km before, once per section, rank 2 |
| Break / nudges | earlier break at 1 h 30 / 1 h 45 if chosen (the 2 h reminder is always on), strong nudge at 4 h then every 30 min, night notice after 30 min between 23:00-05:00 + break reminder 1 h later, lead's group version at the interval and at 4 h, snooze 20 min |
| Falling behind | gap to the group's median along-route position grows ≥ 150 m/min (least squares over 2 min, ≥ 6 samples), gap ≥ 500 m, not stopped within 300 m of a meeting point / planned stop; one per rider per 10 min, one per group per 2 min; lead and sweep phones |
| Pre-ride tip | at most once a day |

**Why "Rough road ahead" is on by default:** potholes injure riders and break rims at night; the warning is rare
(one per 5 km at most), short, lowest priority (never replaces another road notice) and silent during emergencies.
Riders can turn it off in Settings > Road safety.

## 5. Crash brain safety rules (enforced in code and tests)

1. **Shadow by default** (`CRASH_BRAIN_MODE=shadow`): each new alarm gets a logged verdict ("would still alarm?");
   phones get `params: null`.
2. **Hard floor:** only the plain high-impact thresholds (raw 4.0 g, dynamic 3.8 g) may be scaled, within 0.9-1.15.
   The severe fast path (7 g / 6 g), high-side, slide, low-speed and rider-down paths and the countdown never read it.
   Suggestions are never above 1.15; the app clamps again and rejects out-of-range values.
3. A scale is suggested only if it would have missed **no labelled real crash** (all data, 5 % margin).
4. **≥ 200 labelled alarms** per phone-maker group (else the global model, else nothing; `CRASH_BRAIN_MIN_LABELS`
   cannot go below 200).
5. **MASTER_ADMIN approval** in the web admin (Crash brain page: confusion matrix and false-alarm rate before / after
   on held-out data) and `CRASH_BRAIN_MODE=approved`. **Rollback** restores the previous approval or none.
6. The app downloads `GET /api/intel/crash-params?model=` (version + SHA-256 checksum over
   `version|group|scale`), verifies it, and falls back to 1.0 on any error.

Model: logistic regression (7 features), batch gradient descent from zero weights, 600 iterations, L2 1e-3:
deterministic. Held-out = rows whose SHA-1(id) byte 0 % 5 = 0.

## 6. Owner switches

| Env | Default | Effect |
|---|---|---|
| `INTEL_ENABLED` | true | master switch (collection + intel API) |
| `INTEL_KILL` | false | kill switch: stops collection and aggregation at once, reads answer empty |
| `INTEL_K_MIN` | 5 | k-anonymity |
| `INTEL_RAW_DAYS` | 90 | raw retention |
| `INTEL_HALF_LIFE_DAYS` | 90 | decay |
| `INTEL_TRIM_M` | 300 | start / end trim |
| `CRASH_BRAIN_MODE` | shadow | shadow / approved / off |
| `ROUTER_KIND` | osrm | osrm / valhalla (+ `OSRM_TABLE_URL` keeps the safety network on OSRM) |
| `FUEL_GAP_KM` | 80 | fuel gap threshold (gateway endpoint; the app planner uses 80) |
| `INTEL_HASH_KEY` | derived (warning) | **new secret** for OCI Vault |
| `INTEL_MAX_ACCUMULATORS`, `INTEL_MAX_CELLS_PER_RIDE`, `INTEL_JOB_MAX_CELLS`, `INTEL_JOB_EVERY_MIN`, `INTEL_CACHE_TTL_S` | 500, 200, 2000, 5, 600 | memory / CPU bounds |

Admin feature switches (new): `hazardAhead`, `longRideNudges` (Safety), `roughRoadAhead`, `twistyAhead` (Riding),
`fallingBehind` (Group). Unknown = on, as before. SOS, crash detection, emergency texts and Medical ID stay locked on.

Existing behaviour kept: the 3.55 risky-stretch heads-up (`road_risk.js`, hard brakes, k ≥ 10, no consent switch)
is unchanged; folding it into the consented hazard layer is owner decision O-5.

## 7. Health, ops, two nodes

* `GET /api/health` → `intel`: enabled, kMin, rawDays, crash brain mode, router, `lastAggregateAt`, `lastDailyAt`,
  aggregate counts per layer (capped at 1000 = "1000+"), this node's accumulators / queue / memory estimate.
* Leases: `intel-aggregate` (5 min) and `intel-daily` (24 h), prefer `web`. Only the holder writes `intel_cells`.
  Admin "Run aggregation now" answers 409 on the node that does not hold the lease.
* Mirror: consent changes poke the other node (`ic` extension) so its 60 s cache drops the rider at once.
* Collections: `intel_consent`, `intel_raw`, `intel_cells`, `intel_meta`, `intel_crash_train` (created at boot).

## 8. Tiles (admin maps)

The admin maps load `tile.openstreetmap.org` standard tiles (the website's tile source) with attribution. OSM's tile
usage policy allows light use and forbids bulk downloading; the admin console is a handful of users, so the volume is
tiny. Risk: the policy can change or block heavy users; if that happens, switch the `TILE` constant in
`public/admin/intel.js` (and the admin CSP `img-src`) to a self-hosted or licensed tile server. The app keeps its own
offline map cache; the intelligence adds no app tile traffic.

## 9. Not built

* **Weather in dangerous times**: no unrestricted free weather source. Open-Meteo's free tier is non-commercial
  (the existing 3.16 route weather uses it: owner decision O-W1). Add a licensed source later behind a new env.
* Map matching to road segments, Valhalla at runtime, raw track storage: not on the micro VMs (see capability note).

## 9b. Round 7: curve prediction, road speed limits, one warning scheduler

Full design, estimate table, sources and limits of accuracy: [../features_355/curve_and_speed_limit.md](../features_355/curve_and_speed_limit.md).
Notes for the lead: [../quality/ROUND7_SAFETY_NOTES.md](../quality/ROUND7_SAFETY_NOTES.md).

| # | Feature | State | Where |
|---|---|---|---|
| 11 | Curve prediction on the phone (route line; road cells in free riding): class, side, series, advisory speed, time-based warning, no nagging | **Done** (device check pending) | `lib/domain/road/curve_predictor.dart`, `road_matcher.dart`, `road_ahead_engine.dart` |
| 12 | Road cells (OSM ways per geohash-6 cell, 30-day cache, gzip, polite Overpass use) | **Done** | gateway `src/road_cells.js`, `GET /api/geo/roads`; app `road_data_service.dart` (30 MB disk LRU) |
| 13 | Road speed limit: map tag, rider correction, implied type, estimate ("~ est."), overspeed rule | **Done** (device check pending) | `speed_limit_resolver.dart`, `india_speed_limits.dart`, cockpit `road_ahead_chips.dart` |
| 14 | "Wrong limit" votes (consent, k >= 3, never upward) + admin list API | **Done** (admin page: request to the website agent) | `POST /api/geo/limit-corrections`, `/api/admin/geo/limit-corrections` |
| 15 | Learned curves: hard-brake / skid cells raise a bend's class | **Done** | `IntelCareService.onHardBrakeSpots` -> `CurveAnalyzer.analyze(hardBrakeSpots:)` |
| 16 | One scheduler for advisory voice warnings | **Done** | `lib/domain/safety/warning_scheduler.dart`, `RoadCareService` |

Changes to earlier rows: the 3.55 sharp-bend warning (`BendAdvisor`) and the road part of the 3.55 speed-limit
warning are replaced by rows 11 and 13 while riding (the old classes remain for the lock of their tests and as the
fallback when the new engine is not attached). The 3.55 school / hospital caps stay. Section 9 "Map matching to road
segments ... not on the micro VMs" still holds for the **gateway**; matching now happens on the **phone**.

Warning order (voice): SOS / crash > others' SOS > hazard hotspot > sharp curve > speed limit > falling behind >
rough road > fatigue / night / altitude > twisty section.

New owner switches: `ROAD_CELLS_OVERPASS_URL`, `ROAD_CELLS_TTL_DAYS` (30), `ROAD_CELLS_MEM_MB` (12),
`ROAD_CELLS_UPSTREAM_PER_MIN` (6), `ROAD_CELLS_UPSTREAM_PER_DAY` (2000), `ROAD_CELLS_CONCURRENCY` (1),
`ROAD_LIMIT_K_MIN` (3). `GET /api/health` -> `roads`. New collection `road_limit_votes` (keyed rider hash, deleted
with the account). No lease job: cells are built on demand.

## 10. Tests

Gateway: `test/intel_privacy_356`, `intel_hazards_356`, `intel_crash_brain_356`, `intel_road_356`,
`intel_router_356`, `intel_memory_356` (+ route policy, feature switches). Dart: `test/intel_hazard_ahead_356_test`,
`intel_falling_behind_356_test`, `intel_long_ride_nudges_356_test`, `intel_pothole_signals_356_test`,
`intel_consent_prompt_356_test`. Playwright: `node tool/intel_admin_smoke.js <dir>` (admin pages light / dark,
`/account` consent card desktop / mobile).
