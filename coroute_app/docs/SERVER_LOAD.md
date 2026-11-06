# Server load: what the gateway computes per ride, and what moved to the phone

Status: November 2026 (Agent 3). Measured on the dev VM with Node 22 (one core); numbers are
CPU time per operation from micro-benchmarks of the real functions, not production profiles.

## Rule

The gateway keeps only what must be **shared** or **trusted**: message relay and fan-out,
persistence (tracks, timeline, trips), SOS / alert fan-out and SMS dispatch, guardian views,
membership and payments, and the group timeline (it needs every rider's data).
Everything a phone can work out from its own data runs on the phone.

## Audit (per ride)

| Work | Where | Trigger | Cost before | Now |
|---|---|---|---|---|
| Off-route check for the group timeline (`timeline.onTelemetry`) | gateway | every fix of every rider (1 - 2.5 s) | full scan of the planned line: **~220 us per fix** on a 3,000-point route (one `pointToSegment` per segment) | at most every **5 s** per rider, searching **±150 segments around the rider's last segment first** (full scan only when the rider is not near the route there): **~14 us per check**. About **40-80x less**. The OFF_ROUTE entry still needs 60 s off route, so a 5 s check changes nothing visible. |
| Trip report (`finishTrip`) | gateway | trip end, then **every late track upload** (debounced 30 s) | late upload = **full group rebuild**: all riders' tracks loaded and decoded, all analysed (~23 ms per 4 h track at 1 Hz + ~11 ms for trail and wire), all confirmed STOPPED / MOVING entries deleted and rewritten, 2 reverse geocodes and 1 trip document per rider | late upload = **only that rider** (`scheduleRebuild(gid, userId)`): one track loaded, one analysis, that rider's entries and trip document. The other rows of the report are reused as they are. 20 riders, 5 stragglers: 100 rider-analyses -> 5 (**~95% less**). Unknown uploader (old code paths) still rebuilds everything. |
| Trip summary numbers for my trip (distance, riding time, stops, top / average speed, trail) | **phone** (new) | trip end | phone waited for the server report (needed the network, a minute later) | computed on the phone from its own recorded track (`TrackRecorder.summaryOf` -> `TripStats`, same rules as the gateway's `analyseTrack`, tested to give the same numbers). Saved with the trip at once (offline too) and sent as `clientStats`. The gateway **uses them for a rider whose track never reached it** (no server work; before, such riders got rough numbers from live timeline entries). |
| Ahead / behind, ETA to the next stop or the destination for my own view | phone | - | already on the phone (route guide); the server only computes the sweeper rule (along-route, windowed, every 5 s per convoy) because it needs every rider | unchanged |
| Off-route banner / re-route for the rider | phone | - | already on the phone | unchanged |
| Fuel range and stations | phone (Agent 2) | - | - | see Agent 2 |
| Timeline tick (offline, stale, incident, regroup) | gateway | every 30 s | O(riders) bookkeeping per active room, no I/O unless an entry opens: < 0.1 ms per room | unchanged (the tick is what notices *missing* fixes, so it cannot be event-driven) |
| Separation / sub-clusters / sweeper | gateway | at most every 5 s per convoy | O(riders^2) haversines: 20 riders = 400 per 5 s, < 0.1 ms | unchanged |
| Discovery (public rides meeting) | gateway | every 60 s | returns at once with fewer than 2 public rides; grid of 0.1 deg cells, bounded pairs | unchanged |
| Safety network tick | gateway | every 15 s | returns at once without an open incident | unchanged |
| Geo proxies (search, reverse, route, essentials, fuel) | gateway | on request | cached and rate limited per user | unchanged |
| Track upload | gateway | every ~60 s per rider | validated, micro-batched insert | unchanged; points are now never dead-reckoned estimates (see below) |

### Rough totals

A 20-rider convoy on a 3,000-point route, fixes every ~1.5 s:

* off-route: before 20 / 1.5 x 220 us = **~2.9 ms CPU per second** (0.3% of a core, i.e. ~35 such
  convoys per core for this alone); after 20 / 5 x 14 us = **~0.06 ms per second** (~50x less).
* report after the trip: before ~0.7 s CPU + ~40 DB writes per rider **per late upload**; after
  the same only once at the end, then ~35 ms + that rider's writes per late upload.

## Old app builds

* No `clientStats` in the trip: the gateway does exactly what it did before (server track, else
  live timeline entries).
* Old apps read the first four elements of `/tracks` points; the new fifth element (`brk`) and the
  `segmented` flag are ignored by them. Trail points may carry `gap: true`, also ignored.
* GPX now has one `<trkseg>` per recorded piece (valid GPX 1.1; every app reads it).

## The wrong route in the trip summary (fixed with this change)

Root causes, all fixed:

1. **Tunnel coasting was recorded as the ridden track** (`convoy_service.dart`, dead-reckoning
   tick and `_onPosition`): the coasting engine walks along the **planned route**, and when GPS
   came back the *blend* between that estimate and the real fix was recorded with the real fix's
   accuracy (the first blended point is exactly the coasted point on the planned route). Coasting
   starts after only 3 s without a fix at > 15 km/h with a route set, so this happened often, and
   always drew the plan where the rider had taken another road. Now estimated positions are
   never recorded (`TrackRecorder.onFix(estimated: true)`); the real GPS fix is.
2. **Signal gaps were joined with straight solid lines**: the stored trip trail
   (`report.js`) was one Douglas-Peucker line over the whole ride without breaks, and the trip
   history map, the 2D replay and the share card drew it as one polyline. Now the track is cut into
   segments (> 2 min without a fix while moving, or a > 500 m impossible jump), the trail marks the
   first point after a gap (`gap: true`), `/tracks` marks it (`brk`), GPX uses one `<trkseg>` per
   piece, and every map draws gaps dotted (or not at all).
3. **The planned line was drawn as if ridden**: the share card sketch fell back to the planned
   line when there was no track, and the route map drew the plan with a solid 6 px casing. Now the
   sketch is only the rider's own track (or nothing), and the plan is an optional faint dashed layer
   labelled "Planned" (off by default on the route map).
4. **One bad first fix could throw away the ride and create a straight jump**: the old filter
   compared each fix with the last kept one only. Now short runs only reachable by an impossible
   jump are dropped (gateway `filterPoints`, app `TrackCleaner.clean`) and the phone filter
   re-anchors after three agreeing fixes.
5. Distance never counts an impossible link; `gapDistanceM` (straight lines across signal gaps)
   is reported separately and is never drawn as ridden.
