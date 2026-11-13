# Curve prediction and road speed limits (round 7, build 3.55.0+10026)

> Round 9 (Nov 13): the rider choices described here were reduced to fixed defaults (Ride AOD when idle, screen on
> only while moving, lock-screen cockpit under Settings › Advanced; bends / limit sign / overspeed always on with an
> automatic +10 % margin; Strong noise reduction with automatic wind-noise mode). See docs/quality/ROUND9_SETTINGS_NOTES.md.

Advisory features for the ride cockpit. They never replace the signs on the road, and they never show or speak
while an SOS or a crash alarm is open.

| Part | Where it runs | Needs signal while riding? |
|---|---|---|
| Bends on the planned route | phone, from the route line | no |
| Bends in free riding | phone, from road cells kept on disk | no (cells are fetched before / between) |
| Road speed limit (map tag or estimate) | phone, from road cells | no |
| Road cells | gateway: cache in front of Overpass (OpenStreetMap) | only to fetch new cells |
| "Wrong limit" votes | gateway, database | to send a vote (after the ride) |

## 1. Curve prediction

Code: `lib/domain/road/curve_predictor.dart` (`CurveAnalyzer`, `CurveWarner`), `road_ahead_engine.dart`.

1. The line (route, or the road ahead) is projected to metres and **resampled every 10 m**.
2. Heading at each sample = chord over two steps (20 m); the turn between samples is smoothed 1-2-1. A point that is
   a few metres off does not make a bend.
3. Samples turning the same way (gaps up to 25 m) are one bend. Radius = arc length of the tightest part (shortest
   run holding 70% of the turn, less one step for the smoothing) / that turn.
4. Class:

| Class | Rule | Icon |
|---|---|---|
| hairpin | turn >= 135 deg and radius <= 30 m | U-turn arrow |
| sharp | radius <= 40 m, or <= 60 m with a turn >= 75 deg (turn >= 30 deg) | turn arrow |
| medium | radius <= 100 m (turn >= 25 deg) | slight-turn arrow |
| gentle | radius <= 250 m (turn >= 25 deg) | never announced |

5. Direction: sign of the net turn (left / right). Series: three or more bends (medium or tighter) with gaps up to
   150 m are announced once: "Series of bends for 2 km, first one right."
6. **Advisory speed** `v = sqrt(a * r)`, rounded down to 5 km/h, at least 15 km/h:

| Condition | Lateral budget |
|---|---|
| normal | 0.28 g |
| dark (after sunset at the place) | 0.24 g |
| rain (only when known; no weather source rides with the phone today, so never set) | 0.20 g |
| cautious setting | minus 0.03 g (floor 0.15 g) |
| learned bend (riders brake hard / skid there) | class + 1 and about 15% slower |

   Never above the road's speed limit when one is known.
7. **When it warns** (`CurveWarner`): 7 s before the bend at the current speed (never less than 80 m, never more than
   400 m); only at 25 km/h or more and only when faster than the advisory + margin (5 km/h and 10%); once per bend
   (the bend is recognised again by its apex position when the look-ahead line is rebuilt); 8 s between two
   warnings; less than 15 m before the bend nothing is said (too late to help). A corner at a junction on a planned
   route is left to the navigation voice.
8. Output: voice (through the warning scheduler, section 4), a cockpit card, and a chip with the arrow, the
   advisory speed and the distance. The chip stays until the apex is passed.

### Free riding (no route, or off the route)

`RoadMatcher` (`lib/domain/road/road_matcher.dart`) matches each fix to a road of the loaded cells: distance (up to
35 m), heading agreement (within 60 deg; one-way roads only in their direction), continuity with the last matched
road, service roads last. It then follows the road for 700 m and, at its end, the **most likely continuation**: the
road sharing the end point with the smallest turn, preferring the same name and class. If the best continuation
turns more than 50 deg, or two candidates are about equally likely, the line ends there: **no guessing through a
junction**. No cells, no match, no heading, below 15 km/h: silent.

### Learned curves

Hazard cells of kind `hard_brake` / `skid` (k-anonymous, from the round 4 road intelligence, already cached on the
phone) within 120 m of a bend's apex raise its class one step and lower its advisory speed.

## 2. Road cells

Gateway `src/road_cells.js`, `GET /api/geo/roads?cell=<geohash-6>` (about 1.2 km x 0.6 km).

* One bounded Overpass query per cell: ways of 15 road classes with geometry, schools / hospitals, a building count
  and a built-up land-use count.
* Reduced to: class index, name, `maxspeed`, `maxspeed:motorcycle`, `maxspeed:type` / `source:maxspeed` /
  `zone:maxspeed`, one-way, lit, lanes, geometry clipped to the cell + 165 m, simplified (Douglas-Peucker 2 m),
  delta-encoded in 1e-5 degrees. Private roads, roads closed to motorcycles, parking aisles and driveways are
  dropped. At most 1,200 ways / 14,000 points per cell (most important classes first).
* Stored gzip in `geo_cache` (`roads:v1:<cell>`), TTL 30 days, served stale for up to 180 days while a refresh
  waits. `ETag`, `304`, `Content-Encoding: gzip`.
* Memory: LRU of gzip buffers bounded in bytes (`ROAD_CELLS_MEM_MB`, 12 MB).
* Upstream manners: 1 call at a time per node, 6 a minute, 2,000 a day, exponential backoff after a refusal
  (30 s ... 15 min). Over budget: `202 {pending, retryAfterS}`. User-Agent with site and contact.
* Phone (`lib/data/services/road_data_service.dart`): cells around the rider and ahead on the heading (up to 9,
  every 150 m / 20 s), cells along the route when the route's tiles are fetched (ride start, re-route, saving
  offline maps), one request at a time, on-disk LRU of 30 MB, refresh after 7 days when online. Up to 24 cells in
  memory.

## 3. Speed limits

Code: `lib/domain/road/speed_limit_resolver.dart`, data file `lib/domain/road/india_speed_limits.dart`.

Order (first hit wins):

1. `maxspeed:motorcycle`, then `maxspeed` (numbers; mph converted). A car limit above 80 reads **80** (motorcycle
   maximum).
2. A rider correction (section 3.3): replaces an estimate, or lowers a tagged limit. Never raises one.
3. The implied type: `IN:urban` -> 60 (70 is the car value), `IN:rural` -> 60 (80 on a divided road), `zone30` -> 30.
   Shown as an estimate.
4. The estimate table. Shown as "~50" with "est.".
5. Typical rider speeds: **only a sanity check** (`SpeedLimitResolver.sanity`): riders much slower than an estimate
   lower its confidence; the number never changes. The phone does not receive speed aggregates today, so this is
   code + tests only (see the round 7 notes).

### 3.1 Estimate table (motorcycles, India)

Statutory maximum (source S1): expressway 80 (where motorcycles are allowed), divided road of 4 lanes or more 80,
within municipal limits 60, other roads 60. Values below those are deliberately conservative guesses.

| Road class (OSM `highway`) | Built-up | Not built-up | Confidence | Basis |
|---|---|---|---|---|
| motorway | 80 | 80 | high | S1 expressway (many expressways ban two-wheelers; the app does not know which) |
| trunk | 50 | 60 (80 if divided) | low / medium | S1 other roads 60; 4-lane divided 80 |
| primary | 50 | 60 (80 if divided) | low / medium | as above |
| secondary | 50 | 60 | low / medium | S1 municipal 60, other roads 60 |
| tertiary, unclassified | 40 | 50 | low | guess below S1 |
| residential | 30 | 30 | low | guess |
| living_street, service | 20 | 20 | low | guess |
| *_link | min(class, 40) | min(class, 40) | low | guess |

* "Divided" = one-way carriageway with 2+ lanes on trunk / primary (medium confidence: inferred).
* "Built-up" = the cell has >= 150 buildings, or built-up land use with >= 30 buildings, or at least half of its
  road points are residential streets; a lit road counts as built-up. OpenStreetMap buildings are incomplete in
  much of India, so this is a guess.
* Per-state overrides: the structure exists (`IndiaSpeedLimits.stateOverrides`) and is **empty**. No state
  notification was verified in this round. Add one only with its gazette notification as the source.

### 3.2 Cockpit and overspeed

* Round sign: map / corrected limit. "~50" + "est.": estimate or implied type. "school" / "hospital" under the sign.
* Over = above limit + tolerance (setting: 5 / 10 / 15 / 20 %, default 10 %, never less than 5 km/h) for 2 s. Strong
  = more than 20% over: the sign fills red.
* Voice **once** per stretch, then the sign only. Strong speaks once more. Re-armed after 20 s under the limit.
* An **estimated limit never speaks**.
* School / hospital (amenity within 150 m of a road with a tagged limit; schools Mon-Sat 07:00-18:00): no tolerance.
  The 3.55 caps (school 25, hospital 30 from the places cells) still warn as before.
* A limit change is announced only when the new limit is lower and the rider is above it.
* The group / personal speed limit, when as strict or already warning, speaks instead (one prompt).

### 3.3 "Wrong limit" votes

* Rider: tap the sign while standing still, or Settings > Road safety > "Limits on your last ride" after the ride.
  One tap on the right value. Never offered while moving or on a locked phone.
* Gateway: `POST /api/geo/limit-corrections`. Needs "Help make roads safer" (same consent as the other road
  intelligence). One vote per rider per road (a keyed hash, never the rider id), 30 a day.
* Applies when >= 3 distinct riders (`ROAD_LIMIT_K_MIN`, never below 3) agree on a value (a tie: the lower one).
  It never raises (or repeats) a tagged limit and never exceeds 80. Admin can reject, reopen or apply a value under
  the same never-upward rule. Account deletion removes the rider's votes and re-decides the road.
* A real fix belongs in OpenStreetMap: the admin list links each road.

## 4. One warning scheduler

`lib/domain/safety/warning_scheduler.dart`, used by `RoadCareService` for every advisory voice line.

Priority: SOS / crash alarm > other riders' SOS (both outside the scheduler; they silence it) > hazard hotspot >
sharp curve > speed limit > falling behind > rough road > fatigue / night / altitude > twisty information.

* Never two voices at once: a new warning waits; one that is two steps more urgent interrupts.
* Gaps per kind, 2.5 s between any two, at most 4 a minute (hazard and curve are exempt from the per-minute cap).
* A waiting warning expires (curve 3 s, hazard 6 s).
* An emergency empties the queue at once; nothing advisory is spoken until it is over. The scheduler never stops
  the voice engine itself, so it can not cut an SOS announcement.
* Only the voice is scheduled. Cards and chips always show (except during an emergency).

## 5. Limits of accuracy (read this)

* Map lines are simplified and can be several metres off. Radius is an estimate: typically within about 25% on
  clean geometry (tests), worse on coarse mapping. A hairpin drawn with three points reads wider or tighter than
  it is.
* The map can be out of date: new roads, changed limits, temporary works are not there.
* Banking, surface, gradient, traffic, weather, tyres and load are not known. The advisory speed is a comfort
  figure for a dry, clean road, not a safe speed.
* Free riding predicts along the most likely continuation and stops at unclear junctions. After a turn it needs a
  few fixes to match the new road.
* Many Indian roads have no `maxspeed` tag. An estimate is a guess from road class and surroundings; it can be
  wrong in both directions. That is why it is marked "~ est." and never speaks.
* State and local limits lower than the national maximum are not in the table.
* GPS error (accuracy worse than 50 m) pauses everything.
* 60 fps and real-road behaviour were not measured in this environment (no Flutter SDK, no device).

## 6. Sources, licences, attribution

| Id | What | Source (read on 2026-11-13) | Licence / terms |
|---|---|---|---|
| S1 | Motorcycle maximum speeds | MoRTH notification S.O. 1522(E), 6 April 2018 (F. No. RT-11028/07/2017-MVL), read at https://www.acma.in/uploads/ciculer-attachement/FN-April2018-Speedlimits.pdf and https://www.scconline.com/blog/post/2018/04/17/speed-limit-notified-for-on-roads-vehicles-in-india/ | Government notification (facts) |
| S2 | Meaning of `maxspeed`, implied types, units | https://wiki.openstreetmap.org/wiki/Key:maxspeed | reference only |
| S3 | India row of the default limits table (urban 70 / 60 ..., used as a cross-check of S1) | https://wiki.openstreetmap.org/wiki/Default_speed_limits | reference only |
| S4 | Overpass public instance: about 10,000 requests and 1 GB a day, 429 / 504 meaning; an app for non-OSM users should run its own instance | https://dev.overpass-api.de/overpass-doc/en/preface/commons.html | usage policy |
| S5 | Road data | OpenStreetMap contributors | ODbL 1.0. The OSM copyright page could not be fetched from here (blocked by the fetch tool); the project already attributes OSM under ODbL (see `docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md`). |

* Attribution: "(C) OpenStreetMap contributors" is on the map already; the settings card, the wrong-limit sheet and
  the admin list answer carry it for the road data. Website wording: see the round 7 notes.
* S1 also says that speeds within 5% of the maximum are not prosecuted; the app's tolerance is a comfort setting and
  not legal advice.
* **Owner decision (S4):** the gateway's budgets keep one node far below the public instance's fair use, but the
  policy asks apps to run their own instance. `ROAD_CELLS_OVERPASS_URL` is ready for that. No code was copied from
  any source; the curvature, matching and resolver code is original.

## 7. Switches

Rider: Curve warnings (on), Speed limit display (on), Overspeed warning (on), tolerance, voice warnings (existing).
Admin feature switches (existing): `bendWarning`, `speedLimits`. Off in the SOS battery reserve.
Gateway env: `ROAD_CELLS_*`, `ROAD_LIMIT_K_MIN` (`deploy/.env.example`).

## 8. Tests

Dart (pure, `tool/pure_dart_test/run.sh`): `test/curve_speed_curves_test.dart`, `curve_speed_limits_test.dart`,
`curve_speed_engine_test.dart`, `curve_speed_cockpit_layout_test.dart`, `safety_fast_scheduler_test.dart`,
`safety_fast_sos_path_test.dart`. Gateway: `test/road_cells_357.test.js`, `test/safety_fast_sos_http_357.test.js`.
