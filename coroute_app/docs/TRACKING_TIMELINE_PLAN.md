# CoRoute: Group Tracking, Timeline, Route Planning and Live Notifications

Implementation plan, version 1 (5 October 2026). Target: app 3.1.0+61, gateway 3.1.0.

## Status (5 October 2026)

**Phase 1 is built.** Retention default confirmed: the timeline is kept forever, raw tracks and timeline coordinates are deleted after 90 days.

- **Gateway:** `tracks.js`, `timeline.js`, `report.js`, `geo.js`, `geo_math.js`; REST and WS endpoints; retention. Tests: 21/21 (8 new: stop detection, chunk validation, membership window, a full 4-rider simulated ride with group isolation, the report, late uploads, retention, and the geo proxy).
- **App:** recorder, upload queue (SQLite), uploader, stop detector, timeline service and wording, live status notification text. Tests in `test/tracking_test.dart`.

**Decisions made while building:**

- **Notification spike result:** no native bridge needed for the member list. `flutter_foreground_task` 11.0.3 already uses `BigTextStyle` and re-posts the same id, so `updateService(title, text)` gives a one-line collapsed view (first line) and a full expanded list, keeps the SOS/Leave buttons, and stays silent (LOW channel, onlyAlertOnce). Android 16 Live Updates (ProgressStyle) is the only part that would still need native code; it is optional and deferred.
- **Upload path:** phones upload points with `POST /api/convoys/:id/tracks` (batches of up to 20 chunks), not the WebSocket. This also works after the trip ended (30-minute grace), and a late upload rebuilds the report automatically. WS `TRACK` exists as well.
- **Stops:** live stops are detected by the gateway from telemetry (the 30 s parked heartbeat included), so no separate `STOP_EVENT` command is needed. The phone runs the same rule locally for its own display.

**Phase 1 deployed** (commit `41751ea`, app 3.1.0+61, gateway 3.1.0).

**Phase 2 built (written to the project, awaiting analyze/test):**

- **Live group timeline** (convoy screen, timeline icon): newest first, filters by type (Stops, Alerts, Riding, Group) and by rider. Tap an entry to open it on the map.
- **Replay:** time slider and play at 30x, 120x or 600x. Every rider's marker shows where they were at that moment, with a 10-minute tail. No position is drawn across a signal gap longer than 10 minutes. Opened from an entry, it starts at that moment with a pin and that rider highlighted.
- **Trip report** (history, for trips built by the server): your ride tiles, a member comparison table (distance, riding, stopped, stops, average, top speed, time behind the group, no signal, arrived), the full timeline, the replay, a GPX share of your own route, and a text summary share.
- Stable colours per rider everywhere. Wide and landscape layouts adapt.

**Sign-out fix (reported 2026-10-05):** riders were being signed out, or thrown out of their convoy, during bad network.

- **Causes:**
  - The app treated any 401 as "session ended", including Wi-Fi login pages and proxies.
  - It treated a 404 from `/me` as a deleted account.
  - Any 403/404 socket error dropped the convoy, including a 1:1 call to a rider who is offline.
  - A failed keystore read on start counted as signed out.
  - Sessions expired after 30 days with no refresh.
- **Fixes:**
  - The gateway now sends machine-readable codes (`SESSION_INVALID`, `ACCOUNT_GONE`, `NOT_MEMBER`, `CONVOY_GONE`), and the app acts only on those.
  - Non-JSON responses are never treated as session decisions.
  - A convoy drop is double-checked with `/convoys/active` before leaving.
  - Keystore reads and writes are retried.
  - Sliding session: `/me` returns a fresh token (`X-CoRoute-Token`) once a day, built from the database user, so active riders are never signed out. The realtime link uses the refreshed token, and a refused socket (4401) triggers a check instead of a sign-out.
  - Tests: gateway `session.test.js`, app `coroute_unit_test.dart` ("Bad networks never sign anyone out").

**Phase 3 built (map picking and multi-stop route):**

- **Gateway:**
  - `createConvoy` accepts `start` and `stops[]`.
  - Route through start, planned stops and destination, via the OSRM proxy. When OSRM is down it falls back to a straight-line route marked `approximate`. Stale answers are discarded.
  - Stop status `PLANNED`, `SUGGESTED` or `SKIPPED`.
  - WS commands: `STOP_ADD` (the lead's stops are planned, others' become suggestions), `STOP_SUGGEST`, `STOP_ACCEPT`, `STOP_DECLINE`, `STOP_REMOVE`, `STOP_SKIP`, `STOP_REORDER`, `ROUTE_SET` (start or destination).
  - Pushes `ROUTE` and `DESTINATION`.
  - Timeline entries `STOP_SUGGESTED`, `STOP_SKIPPED`, `ROUTE_CHANGED`.
  - Geofence ignores suggested and skipped stops. Test: `route.test.js`.
- **App:**
  - `MapPickerScreen`: centre pin, tap, search, my location, place name, stop category and planned stay.
  - `TripPlannerScreen` replaces the create dialog: name, start, destination, reorderable stops, live route preview with distance and time per leg.
  - `RouteStopsPanel` on the convoy Stops tab and the cockpit sheet. The lead adds, reorders, skips, removes stops and changes the destination; members suggest; the lead accepts or declines.
  - The cockpit map draws the route and numbered stops. Long-press adds or suggests a stop.
  - The status notification uses distance along the route to the destination.
  - `routing_service.dart` (direct calls from the app to OSM) removed.

**Phase 4 built (alerts):**

- **Logic:** `AlertPolicy` (pure, tested) plus `AlertService` (flutter_local_notifications 19). Four channels: SOS (max, alarm category, insistent sound until seen), group alerts (high), trip updates (default) and activity (low).
- **Standing alerts, reconciled every 30 s and on each timeline change** (shown when true, removed when resolved):
  - SOS: everyone except the sender.
  - Stopped at or beyond 20 min: lead and sweeper.
  - Separated: the rider and the lead/sweeper.
  - No signal at or beyond 5 min: lead.
  - Off route: the rider and the lead.
- **One-time alerts** for live entries (auto-removed after 10 min): destination or stop reached, stop suggested (to the lead), joined/left, route changed.
- **Quiet in the foreground:** while the app is open, only SOS is posted. Notifications are grouped per trip, with no coordinates in the text.
- **Full screen:** the full-screen SOS intent was deliberately not used (Play policy, and the activity would have to show over the lock screen at all times). The insistent alarm sound covers it.
- Android build: core library desugaring (`desugar_jdk_libs 2.1.4`), `VIBRATE` permission.

App version 3.3.0+63.

## 0. Goals and decisions

| # | Goal | Done when |
|---|---|---|
| G1 | Every member of a group is tracked for the whole trip | Every member's real track (not their last position) is stored and shown for the whole trip |
| G2 | One group timeline showing who did what, where, when and how | Every member sees the same ordered timeline, live and after the trip |
| G3 | Stops and rest measured exactly | Each stop has arrival, departure, duration, coordinates and place name; totals for moving and rest time |
| G4 | Start, destination and stops picked on the map | Search, tap, long-press or centre-pin selection everywhere a place is needed |
| G5 | Route through every stop | Multi-waypoint route, distance and time per leg, ETA per rider |
| G6 | Live status notification on the lock screen | One ongoing notification updated in place; alerts posted separately and cleared once resolved |

Fixed constraints (from earlier decisions): zero running cost (OCI Always Free + free OSM services), no extra battery drain, server-enforced group isolation, no hardcoded settings (thresholds live in the database or the environment), Android first (no iOS build yet).

**Retention (default, awaiting Haswanth's confirmation):**

- **Kept forever:** the timeline (who, what, when, how long, place name) and the per-member statistics.
- **Deleted after 90 days:** raw GPS track chunks, plus the coordinates on timeline entries (the place name stays).

---

## 1. Why the current code fails

| Symptom | Root cause (file) |
|---|---|
| Trip history shows no route | `ConvoyService.buildTripHistory` stores one point per rider: their position when the trip ended |
| Distance is wrong | Computed as average *current* speed × duration, not from a recorded track |
| No stop durations | Stops are never detected or saved; only `stoppedSince` exists, and only live |
| No start location | `createConvoy` sends only the destination; `startLocationName` is never filled from a real point |
| Can't pick on the map | Destination by text search only; stops are "Checkpoint N" at the leader's current position |
| Route ignores stops | `RoutingService.fetchRoute` covers start→end only and calls the public OSRM server directly from the app |
| Notification is a plain line | `BackgroundService.start` posts one text line on a LOW channel; there are no alert channels |

---

## 2. Architecture

```
 Phone (each member)                          Gateway (single authority)                 Oracle ADB (COROUTE)
 ------------------------------------------   -----------------------------------------  -----------------------
 GPS stream (existing, adaptive)
   ├─ TrackFilter ──► TrackRecorder ──► sqflite queue ──► TRACK batches (WS) ──► TrackStore ──► track_chunks (90 d)
   ├─ StopDetector ──► STOP_EVENT (live) ─────────────────────────────────────► TimelineEngine ─► trip_events (forever,
   └─ TELEMETRY (existing, 2.5 s / 40 m) ───────────────────────────────────► (separation,        coords stripped 90 d)
                                                                               offline, off-route,
 NotificationController ◄── TIMELINE / RIDERS / ROUTE events ◄─────────────── geofences, SOS)
   ├─ live status (native, same id as FGS)                                    ReportBuilder ───► trips.report (forever)
   └─ alert channels (flutter_local_notifications)                            GeoProxy ────────► geo_cache (30 d)
                                                                               (Nominatim, OSRM)
 MapPicker / TripPlanner ──► /api/geo/* , ROUTE_SET, STOP_* ─────────────────► ConvoyManager (meta.route, meta.stops)
 TimelineScreen / Replay / Report ◄── /api/convoys/:id/timeline, /tracks, /api/trips/:id/report, /gpx
```

Principles:

- **Timeline is computed on the server.** Phones report what they detect. The gateway confirms each report against the uploaded track and decides the final entry, so every member sees the same timeline.
- **Live entries come from phone events; accuracy comes from the server.** Stops show up the moment a phone reports them. When the full track arrives, the server checks the times against it and corrects them if needed (a correction is broadcast as `TIMELINE_UPDATE`).
- **No extra GPS.** Recording uses the fixes the app already takes. The only new disk cost is SQLite inserts, written in batches of 10.

---

## 3. Data model (Oracle SODA collections)

### 3.1 `track_chunks` (new, deleted after 90 days)

```json
{
  "groupId": "GRP-7KQ2", "userId": "u_123", "seq": 42,
  "startTs": 1791188400000, "endTs": 1791188700000, "count": 118,
  "enc": "<delta-encoded polyline: lat,lng at 1e5 precision>",
  "t":   [0, 2500, 2510, ...],          // ms deltas from startTs
  "v":   [41, 43, 44, ...],             // speed km/h, integer
  "acc": [6, 5, 8, ...],                // accuracy m, integer
  "createdAt": 1791188705000
}
```

- Unique index on `groupId + userId + seq`, so uploading the same chunk twice changes nothing. Range index on `groupId + startTs`.
- At most 120 points per chunk. Size is about 10 to 12 bytes per point, so an 8-hour ride is roughly 130 KB per rider. That is far inside the 20 GB Always Free limit for 90 days of use.

### 3.2 `trip_events` (new, kept forever; coordinates removed after 90 days)

```json
{
  "eventId": "EV-9F2A1C", "groupId": "GRP-7KQ2", "userId": "u_123", "userName": "Priya",
  "type": "STOPPED", "startedAt": 1791190000000, "endedAt": 1791191080000, "durationMs": 1080000,
  "lat": 17.24051, "lng": 78.42977, "placeName": "HP fuel station, Shamshabad",
  "data": { "reason": "FUELING", "avgSpeedBefore": 62 },
  "source": "device|server", "confidence": "confirmed|provisional", "updatedAt": 1791191090000
}
```

Index on `groupId + startedAt`, plus an index on `userId`.

**Event types:**

| Type | Who | Source | Notes |
|---|---|---|---|
| `TRIP_STARTED` / `TRIP_PAUSED` / `TRIP_RESUMED` / `TRIP_ENDED` | Group | server | from TRIP_STATUS |
| `JOINED` / `LEFT` / `REMOVED` | Member | server | sets the membership window |
| `MOVING` | Member | server | stretch between stops: distance, duration, avg/max speed (a summary entry, collapsed by default) |
| `STOPPED` | Member | device → server confirms | ≥ stop threshold within 50 m; open until departure |
| `STATUS` | Member | device | rider chose a reason: fuelling, flat tyre, rest, medical… |
| `SEPARATED` / `REGROUPED` | Member | server | gap from the convoy centre larger than `distanceThresholdMeters` for 60 s, then back inside 80% of it |
| `OFF_ROUTE` / `BACK_ON_ROUTE` | Member | server | more than 300 m from the route line for 60 s |
| `OFFLINE` / `ONLINE` | Member | server | no update for 5 min; duration is filled in when the member reconnects |
| `STOP_REACHED` | Member + group roll-up | server | within 150 m of a planned stop; group entry says "3 of 4 riders" |
| `DESTINATION_REACHED` | Member + group roll-up | server | |
| `SOS_RAISED` / `SOS_RESOLVED` | Member | server | existing alerts, mirrored here |
| `STOP_ADDED` / `STOP_SUGGESTED` / `ROUTE_CHANGED` | Member | server | planning changes |
| `CORIDE_START` / `CORIDE_END` | Member | server | pillion / riding with someone |

### 3.3 `geo_cache` (new, deleted after 30 days)

`{ "k": "rev:17.2405,78.4298" | "q:<hash>" | "r:<hash>", "value": {...}, "createdAt" }`, with a unique index on `k`.

### 3.4 Changes to existing collections

- `convoys` gains `start {lat,lng,name}`, `route {waypoints[], polyline(enc), legs[{distanceM,durationS}], distanceM, durationS, computedAt}`, `stopPoints[].{source, suggestedBy, status: PLANNED|SUGGESTED|VISITED|SKIPPED, arrivedAt, plannedDwellMin}`, and the new thresholds `stationaryAlertMinutes` (default 20), `offRouteMeters` (300) and `offlineAlertMinutes` (5).
- `convoy_riders` gains `joinedAt`, `leftAt`, `lastTrackSeq`.
- `trips` gains `report` (§7) and `members[{userId,name,joinedAt,leftAt}]`. `breadcrumbTrail` is replaced by `trackRef: {groupId}` (old data stays readable).

---

## 4. Phone side (Flutter)

### 4.1 New dependencies (all free)

`sqflite ^2.4` (offline queue), `flutter_local_notifications ^19` (alert channels), `path ^1.9`. Everything else is already present.

### 4.2 New files

| File | Responsibility |
|---|---|
| `lib/domain/tracking/geo_math.dart` | haversine, bearing, point-to-polyline distance, along-route progress, polyline encode/decode, Douglas–Peucker |
| `lib/domain/tracking/track_filter.dart` | Drops: accuracy > 30 m; implied speed > 250 km/h; timestamp going backwards; drift under 3 m while stationary. Holds the last accepted fix. |
| `lib/domain/tracking/stop_detector.dart` | State machine `MOVING → CANDIDATE → STOPPED → MOVING`. A candidate starts when speed < 3 km/h or there is no movement beyond 50 m. It becomes STOPPED after `stopThresholdSeconds` (convoy setting, default 120). It leaves STOPPED once 60 m from the stop centre with speed > 8 km/h. The stop centre is recalculated from the fixes during the stop. Emits `StopStarted` and `StopEnded(duration)`. Pure Dart, fully unit-testable. |
| `lib/data/local/track_db.dart` | sqflite tables `points(groupId,userId,ts,lat,lng,v,acc,hdg,uploaded)` and `pending_events(json)`. Inserts batched every 10 fixes; uploaded rows pruned after 2 days. |
| `lib/data/services/track_recorder.dart` | Subscribes to the accepted-fix stream from `ConvoyService._onPosition`, feeds TrackFilter → db + StopDetector, emits `STOP_EVENT` |
| `lib/data/services/track_uploader.dart` | Every 30 s or 60 points while connected: builds a chunk (≤120 points, encoded), sends `TRACK`, marks rows uploaded on `TRACK_ACK{seq}`. On reconnect, drains the backlog oldest first, 1 chunk per 300 ms. |
| `lib/data/services/timeline_service.dart` | Loads `/timeline?since=`, applies `TIMELINE` / `TIMELINE_UPDATE` pushes, exposes filtered lists per member and type |
| `lib/data/services/geo_service.dart` | Replaces `routing_service.dart`: calls `/api/geo/search`, `/reverse`, `/route` on the gateway only |
| `lib/data/services/notification_controller.dart` | Builds live status text and alert notifications (§6) |
| `android/app/src/main/kotlin/.../TripStatusNotifier.kt` | Native bridge (MethodChannel `coroute/notify`) posting the status notification (§6.2) |
| `lib/presentation/map_picker/map_picker_screen.dart` | §5.1 |
| `lib/presentation/trip_planner/trip_planner_screen.dart` | Start, destination, stops, route preview; replaces the create-convoy dialog |
| `lib/presentation/timeline/timeline_screen.dart` | Timeline tab (live) + filters + tap-to-map |
| `lib/presentation/timeline/replay_view.dart` | Time slider over the map showing every member's position at time T |
| `lib/presentation/report/trip_report_screen.dart` | Summary, member comparison table, per-member detail, GPX/image share |

### 4.3 Changes to existing files

- **`convoy_service.dart`:**
  - pass accepted fixes to `TrackRecorder`;
  - remove `buildTripHistory` estimation (history comes from the server report);
  - send `start` on create;
  - handle the `ROUTE`, `STOPS`, `TIMELINE` and `TIMELINE_UPDATE` events.
- **`background_service.dart`:** stop calling `updateService` for text; the native notifier owns the content (§6.2).
- **`live_cockpit_map_screen.dart`:**
  - route line and next-stop/destination chip with ETA;
  - long-press to add or suggest a stop;
  - timeline bottom-sheet tab.
- **`convoy_dashboard_screen.dart`:** Timeline and Planning tabs; stop list with drag to reorder, accept/reject suggestions, skip.
- **`trip_history_screen.dart`:** opens `TripReportScreen`; older trips without a track show a "no detailed track" state.
- **`permissions_screen.dart`:** notification permission asked in context, plus the full-screen and promoted-notification explanations (§6.4).
- **`AndroidManifest.xml`:** `USE_FULL_SCREEN_INTENT`, `POST_PROMOTED_NOTIFICATIONS` (API 36), and the SOS full-screen activity theme.

### 4.4 Battery budget

No new GPS listener. SQLite inserts are batched. Uploads share the existing WebSocket. Notification redraws are capped (§6.2). Target: under 3% extra battery per hour against today's build, measured on one device over a 1-hour ride. If it goes over, the first change is a longer upload interval.

---

## 5. Map picking and route

### 5.1 MapPickerScreen

- **Search bar:** debounce 600 ms, at least 3 characters. Results are biased towards the current map view and the device's country.
- **Picking a point:**
  - fixed centre pin over a draggable map (default);
  - tap to move the pin;
  - long-press elsewhere for a quick pick;
  - "My location" button.
- **Address under the pin:** reverse-geocoded once the map stops moving for 800 ms.
- **Confirm sheet:** name (editable), category for stops (fuel, food, rest, scenic, toll, other), planned stay in minutes (optional).
- **Returns** `PickedPlace{lat,lng,name,category,dwellMin}`. Used for start, destination, add stop, suggest stop and edit stop.

### 5.2 TripPlannerScreen (replaces the create dialog)

- Trip name; start (defaults to current location, reverse-geocoded); destination; stop list (add, drag to reorder, swipe to delete).
- Live route preview: total distance and time, plus each leg. "Fastest order" is offered only when there are more than two stops (uses OSRM `trip`).
- Launch → `POST /api/convoys` with `start`, `destination` and `stops`. The server computes and stores the route.

### 5.3 During the ride

- **Leader and co-leader** can add, remove, reorder or skip stops and change the destination. Each change sends `ROUTE_SET` or `STOP_*`, the server recalculates the route, and everyone receives `ROUTE`.
- **Members** send `STOP_SUGGEST`. The leader sees a card with Accept / Decline. Accepting turns it into a normal stop.
- **Automatic progress:** when a rider comes within 150 m of a stop, `STOP_REACHED` fires and the stop is marked visited once the leader or a majority arrives. A skipped stop is recorded with who skipped it.
- **Per rider:** distance and ETA to the next stop and to the destination, from progress along the route line (straight-line fallback when there is no route).

### 5.4 GeoProxy (gateway)

- **Search:** `GET /api/geo/search?q=&lat=&lng=` → Nominatim `search`. Cached 30 days by normalised query.
- **Reverse:** `GET /api/geo/reverse?lat=&lng=` → Nominatim `reverse`, coordinates rounded to 4 decimals (about 11 m). Cached 30 days.
- **Route:** `POST /api/geo/route {waypoints[]}` → OSRM `route/v1/driving/...?overview=full&geometries=polyline` (max 25 waypoints). Cached by waypoint hash.
- **Usage limits:** one global queue limited to 1 request per second for Nominatim (its usage policy), with a proper User-Agent and contact email. Per-user limit of 30 requests per minute.
- **No hardcoded providers:** `GEO_SEARCH_URL`, `GEO_ROUTE_URL` and `GEO_CONTACT` come from env, so providers can change without an app release.

---

## 6. Notifications

### 6.1 Channels

| Channel id | Importance | Sound | Lock screen | Use |
|---|---|---|---|---|
| `coroute_convoy` (existing FGS) | LOW, onlyAlertOnce | none | public, no coordinates | live trip status |
| `coroute_sos` | MAX | alarm, vibration pattern | public | SOS; full-screen intent where permitted |
| `coroute_alerts` | HIGH | default | public | stationary, separated, offline |
| `coroute_updates` | DEFAULT | soft | public | off-route, stop/destination reached, suggestions |
| `coroute_activity` | LOW | none | private | joined, left, route changed |

All alert notifications share the group key `trip_<groupId>` with a summary notification.

### 6.2 Live status (state, updated in place)

- **Single notification:** the foreground-service notification id `1001` is re-posted by `TripStatusNotifier.kt` through `NotificationManager.notify(1001, ...)` with the same channel, so there is only ever one status notification.
- **Collapsed text:** `formatCollapsed()` sorts members by distance from me and prints `Name 0.8 km ahead`, up to 3 entries, then `+N`. Names are cut to 10 characters. A member who is stopped shows `Name stopped 12m`. Ahead/behind comes from progress along the route; without a route, from the bearing relative to my heading.
- **Expanded:** `InboxStyle`, one line per member: `Priya  1.3 km behind · 54 km/h · 20 s ago`, plus a progress line `64 / 210 km · next: Lunch 12 km · ETA 14:40`.
- **Android 16+:** `Notification.ProgressStyle` with `setRequestPromotedOngoing(true)`; the status chip shows the distance to the next stop. Stops are progress points along the bar. The member list moves to the content text (ProgressStyle can't hold an inbox list), and the full list is one tap away.
- **Buttons:** SOS, Talk (opens the cockpit with the intercom), Leave.
- **Redraw rules:** only when the formatted text changes, and at most once every 10 s (immediately for a new stop or SOS). Distances rounded to 0.1 km under 10 km, 1 km above.
- **Fallback:** if a plugin update re-posts its own text over ours, `NotificationController` re-applies the content within one second. If that proves unreliable on a device, we switch to a separate `flutter_local_notifications` ongoing notification and minimise the FGS one. This is decided in the Phase 4 device test.

### 6.3 Alerts (events)

| Event | Channel | Who is notified | Cleared when |
|---|---|---|---|
| SOS_RAISED | sos (+ full screen) | everyone except the sender | SOS_RESOLVED |
| STOPPED ≥ `stationaryAlertMinutes` | alerts | leader + sweeper; everyone if the member also sets a status | member moves |
| SEPARATED | alerts | leader + the separated member | REGROUPED |
| OFFLINE ≥ `offlineAlertMinutes` | alerts | leader | ONLINE |
| OFF_ROUTE | updates | the member + leader | BACK_ON_ROUTE |
| STOP_REACHED / DESTINATION_REACHED (group roll-up) | updates | everyone | auto-dismiss after 10 min |
| STOP_SUGGESTED | updates | leader | accepted or declined |
| JOINED / LEFT | activity | everyone | auto-dismiss after 10 min |

- **Stable ids:** each notification id is a hash of `type + userId`, so a repeat updates the existing notification instead of stacking a new one.
- **Quiet while looking:** nothing is posted while the cockpit is in the foreground. An in-app banner shows instead, except for SOS.

### 6.4 Permissions (asked in context)

1. **Notification permission** (Android 13+), at the first create/join: "So you can see your group and SOS alerts on the lock screen."
2. **Full-screen SOS** (Android 14+, `canUseFullScreenIntent()`), once, from the SOS settings row. If refused, SOS uses the MAX channel with an alarm sound.
3. **Promoted notifications** (Android 16+), shown only if the system reports them as not allowed.

---

## 7. Timeline, replay and report

### 7.1 TimelineEngine (gateway, `src/timeline.js`)

- **Per room in memory:** last fix per member, open stop, separation state, off-route state, last-seen timer and route geometry (decoded once).
- **Inputs:** TELEMETRY (live), TRACK chunks (accurate, possibly late), STOP_EVENT, STATUS, SOS, membership and route changes.
- **Separation:** distance from the convoy centre (median of member positions, which ignores one runaway). Uses hysteresis (exit at 80%) and a 60 s minimum, so it can't flap.
- **Confirmation:** a device STOPPED arrives as `provisional`. Once track chunks cover the period, the engine re-runs the same stop rule on the points and corrects start/end or drops false stops. The result is `confirmed` and sent as `TIMELINE_UPDATE`.
- **MOVING summaries** are written at each stop start and at trip end, from the track: distance (sum of filtered segments), duration, average and maximum speed.
- **Place names:** the reverse lookup runs once per event through the GeoProxy queue; the name is added with a TIMELINE_UPDATE.
- **Writing:** write-behind (like riders); open events are rewritten when they close.

### 7.2 Visibility rules (server-enforced)

- Timeline and tracks are readable only by members of that group. Each viewer sees only the period from their own `joinedAt` to `leftAt`, plus the group-level entries.
- Admins see everything through the existing admin role (audited in the log).
- The join screen states: "Your position, stops and route are visible to members of this group for this trip."

### 7.3 Timeline screen

- **Rows:** time · member avatar or initials (colour per member) · what · where · how long/how far. Grouped by hour, newest at the bottom while live.
- **Filters:** member chips, plus types (Stops, Alerts, Planning, All).
- **Tap a row:** the map pans to the place and highlights that member's track around the time.
- **Live:** pushes are animated in; a sticky "Now" header.

### 7.4 Replay

- **Slider** across the trip time, with play at 1×, 10× or 60×.
- **At each time T:** every member's position is calculated between their two nearest track points. Markers are drawn with name labels; each tail shows the last 10 minutes.
- **Data:** loaded once with `GET /api/convoys/:id/tracks?simplify=15m` (Douglas–Peucker on the server). That's about 300 KB for 10 riders × 8 h.

### 7.5 Report (`ReportBuilder`, built at TRIP_ENDED, stored in `trips.report`, kept forever)

```json
{
  "group": { "durationMs": ..., "distanceM": ..., "plannedStops": 4, "visitedStops": 3 },
  "members": [{
    "userId": "u_123", "name": "Priya", "joinedAt": ..., "leftAt": ...,
    "distanceM": 208400, "movingMs": ..., "restMs": ..., "offlineMs": ..., "separatedMs": ...,
    "stops": 5, "longestStopMs": ..., "avgMovingKmh": 58.2, "maxKmh": 96,
    "firstFix": {"ts":..., "placeName":"Gachibowli"}, "lastFix": {"ts":..., "placeName":"Kurnool"},
    "sos": 0
  }]
}
```

- **Trip Report screen:**
  - summary tiles;
  - member comparison table (sortable);
  - per-member page with timeline, track map coloured by speed band (0–20 / 20–60 / 60+ km/h) and stop list.
- **Share:** `GET /api/trips/:id/gpx?userId=` (own track always; others' within the visibility rule), plus a rendered summary image.
- **Rider trip history:** lists trips from the server with this report. The local `TripStorageService` becomes a cache.

---

## 8. Gateway API additions

**WebSocket (all require JOIN to the room; `userId` always comes from the JWT):**

| Command | Payload | Checks |
|---|---|---|
| `TRACK` | `{seq, startTs, enc, t[], v[], acc[]}` | ≤120 points, ≤12 KB, timestamps within trip ±10 min and not in the future, lat/lng valid, seq increasing; replies `TRACK_ACK{seq}` |
| `STOP_EVENT` | `{phase: START|END, ts, lat, lng}` | rate ≤ 1 per 10 s |
| `ROUTE_SET` | `{start?, destination?, stops?[]}` | leader/co-leader |
| `STOP_SUGGEST` / `STOP_ACCEPT` / `STOP_DECLINE` / `STOP_REORDER` / `STOP_REMOVE` / `STOP_SKIP` | ids, lat/lng, name, category | role checks |
| `TIMELINE_SINCE` | `{since}` | catch-up after reconnect |

Server pushes: `ROUTE`, `STOPS`, `TIMELINE`, `TIMELINE_UPDATE`, `TRACK_ACK`.

**REST:** `GET /api/convoys/:id/timeline?since=&userId=&types=`, `GET /api/convoys/:id/tracks?userId=&from=&to=&simplify=`, `GET /api/trips/:id/report`, `GET /api/trips/:id/gpx?userId=`, `GET /api/geo/search`, `GET /api/geo/reverse`, `POST /api/geo/route`.

**New gateway files:** `src/timeline.js`, `src/tracks.js` (validation, encode/decode, simplify), `src/geo.js` (proxy, queue, cache), `src/report.js`, `src/geo_math.js` (shared maths, same tests as the Dart version).

**Config (env, with defaults):** `TRACK_MAX_POINTS=120`, `TRACK_RETENTION_DAYS=90`, `STOP_RADIUS_M=50`, `STOP_EXIT_M=60`, `OFF_ROUTE_M=300`, `OFFLINE_ALERT_MIN=5`, `STATIONARY_ALERT_MIN=20`, `GEO_SEARCH_URL`, `GEO_ROUTE_URL`, `GEO_CONTACT`, `GEO_CACHE_DAYS=30`. Per-convoy values override them from `convoys`.

**Retention changes (`retention.js`):** delete `track_chunks` older than 90 days; null `lat`/`lng` on `trip_events` older than 90 days (keep `placeName`); delete `geo_cache` older than 30 days. The policy comment and `privacy.html` are updated to match.

---

## 9. Security and abuse checks

- **Isolation:** every new read and write is checked for room membership and the viewer's membership window. New tests in the style of the existing ISOLATION test: a member of group A gets nothing from B's timeline, tracks, report or GPX.
- **Own data only:** track points are accepted only for the sender's own `userId` and only while they are a member of an active trip.
- **Size and rate limits:** existing `ws` frame cap; TRACK at most 1 per second; geo endpoints rate-limited per user.
- **Lock screen and logs:** no coordinates on the lock screen; coordinates never written to server logs.
- **GPX export:** a member can always export their own track; another member's only within their membership window.

---

## 10. Tests

| Area | Tests |
|---|---|
| Dart `geo_math` | haversine against known pairs; polyline encode/decode round-trip; distance from point to polyline; progress along route |
| Dart `track_filter` | drops bad accuracy, spikes, out-of-order fixes, standstill drift |
| Dart `stop_detector` | simulated traces: fuel stop of 18 min → one stop of 18 min ±10 s; slow traffic at 4–6 km/h → no stop; signal halt of 90 s → no stop; GPS drift while parked → one stop |
| Dart `notification_controller` | collapsed formatting with 1, 3, 4 and 12 members; truncation and `+N`; no redraw when text unchanged; alert id stability; alert cleared on resolve |
| Dart widget | Timeline rows and filters; MapPicker returns the chosen point; report table renders with 0 and 10 members; landscape layout has no overflow |
| Gateway `tracks` | validation rejects future/oversized/foreign-user chunks; duplicate seq does nothing |
| Gateway `timeline` | simulated 4-rider trip produces the expected sequence (start, join, stop, separation, regroup, off-route, stop reached, destination, end); provisional stop corrected by track |
| Gateway isolation | timeline/tracks/report/gpx across groups and outside membership window → 403 |
| Gateway retention | chunks deleted at 90 days, events kept with coordinates removed |
| Gateway geo | cache hit avoids a second upstream call; queue spaces Nominatim calls 1 per second |

Total after the work: about 45 gateway tests and 45 Flutter tests, all run by the agent on the build machine.

---

## 11. Phases and acceptance

### Phase 1: Recording and the group timeline (backend first)

- Gateway: `tracks.js`, `timeline.js`, `report.js`, collections, WS commands, REST, retention, tests.
- App: `geo_math`, `track_filter`, `stop_detector`, `track_db`, `track_recorder`, `track_uploader`, `timeline_service`, tests.
- **Done when:** a simulated 4-rider trip produces a correct timeline and report in tests; on a real ride, two phones show each other's stops live, and switching one phone to airplane mode for 10 minutes leaves no gap after reconnect.

### Phase 2: Timeline UI, replay and report

- Timeline tab, filters, tap-to-map, replay slider, Trip Report with comparison table, GPX/image share, history moved to server reports.
- **Done when:** a ride's report shows the right totals (distance within 3% of a reference app) and each stop's duration within 15 s of a stopwatch.

### Phase 3: Map picker, planner and route

- GeoProxy and cache, MapPicker, TripPlanner, multi-stop route, stop suggestions and acceptance, automatic stop visit, ETA, off-route detection.
- **Done when:** a trip planned entirely on the map (start, 3 stops, destination) routes through every stop; a suggestion from a member reaches the leader and appears for everyone after acceptance.

### Phase 4: Notifications

- Channels, `NotificationController`, `TripStatusNotifier.kt` (InboxStyle + Android 16 ProgressStyle), alerts with auto-clear, contextual permissions, SOS full screen.
- **Done when:**
  - with the phone locked for 10 minutes, the status keeps updating with no repeated sound;
  - stopping a member for 20 minutes posts one alert, which clears when they move;
  - SOS appears full screen where permitted, otherwise as an alarm notification;
  - nothing ever stacks into more than one status notification.

### Phase 5: Hardening and release

- Battery measurement, OEM background checks (Xiaomi, Samsung, Vivo, Oppo, plus the existing battery-optimisation prompt), privacy policy update, version 3.1.0+61, set `MIN_APP_BUILD` only after the rollout, deploy the gateway, release notes.

**Order of risk:** Phase 4's native notification replacement is the only part not yet proven on this plugin version. To contain that, the bridge is spiked first (half a day) at the start of Phase 1, so the fallback decision is made early.

---

## 12. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Public Nominatim/OSRM limits or downtime | Gateway cache + queue; straight-line fallback for the route; provider URLs in env; self-hosting OSRM on the Ampere VM stays an option later |
| OSM tile usage policy for app traffic | Correct User-Agent now; tile URL already in config; can switch to another free provider without code changes |
| Phone makers killing background apps | Battery exemption prompt (exists), OEM guidance screen; the recorder resumes from SQLite so data isn't lost, and the timeline marks the gap as OFFLINE |
| Plugin re-posts over the native notification | Re-apply logic plus the planned fallback (§6.2) |
| Play policy on full-screen intent | Ask at runtime; fall back to the alarm channel; data-safety answers updated |
| Storage growth | Chunk encoding (~12 bytes/point), 90-day deletion, size check in the admin insights screen |
| Privacy expectations | Clear notice at join, membership-window visibility, no coordinates on the lock screen or in logs, own-data GPX export |

---

## 13. Not included

iOS Live Activities and notification threads (when the iOS app exists), elevation profile, automatic crash detection, offline map tiles, speed alerts for individual riders.
