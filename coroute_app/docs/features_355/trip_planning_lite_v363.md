# v3.63 trip planning lite (owner approved 17 Nov 2026)

## Expense split (gateway `src/expenses.js`, app `lib/presentation/expenses/expenses_screen.dart`)

Records the riders keep for themselves: what was spent, who paid, who shares it, and the shortest "who pays whom"
list. CoRoute never moves, collects or charges money here; the app shows plain numbers (no currency symbol, Play
policy scan 0 hits).

* Who: every rider of the ride (now or earlier in it). Open to add / edit / settle during the ride and for 30 days
  after its last activity; read-only until 90 days; then removed (hourly sweep). Edit / delete only what you added.
  "Paid back" can be recorded only by the two riders involved; undo own record.
* Split equally among chosen riders (exact paise; leftover paise on the first ids) or custom amounts (must add up).
* A double tap within 10 s returns the first record (no duplicate). Max 300 records per ride; 40 changes a minute.
* Realtime `EXPENSES_CHANGED { version }` to the room; the screen reloads.
* REST (members only): `GET|POST /api/convoys/:groupId/expenses`, `PUT|DELETE /api/convoys/:groupId/expenses/:id`,
  `POST /api/convoys/:groupId/expenses/settle`, `DELETE /api/convoys/:groupId/expenses/settle/:id`. LIVE routes
  (deploy/route_split.md).
* Account erase: the rider's own records are removed; their name in other rides becomes "Deleted rider".
* App: "Ride expenses" row in the open ride sheet (group rides), receipt icon on the trip report, add / edit sheet with
  Fuel / Food / Toll / Stay / Parking / Repair chips.

## Pre-ride checklist (`lib/domain/expenses/pre_ride_checklist.dart`, `lib/presentation/checklist/`)

Licence, RC, insurance, PUC, tyres, chain, brakes, lights, fuel, helmet and gear, phone charged, emergency contacts set,
Medical ID set ("Set" opens the profile), offline map saved. Tick items or "All good"; add your own items, remove
defaults (bring them back). Ticks are kept 18 h (one ride), the list stays; stored on the phone. Opened from Plan a
ride, the start (review) sheet and Join a ride. Never blocks starting or joining, never shown while riding.

## Weather at stops

The route weather the app already asks for (MET Norway through `POST /api/geo/weather`) now also returns wind
(`windKmh`). Each named stop and the destination shows "Warangal · 3 PM · rain 60% · 28°C · wind 14 km/h" in the
review sheet, Plan a ride (after review) and the open ride sheet. Nothing in data saver or without an answer.

## Tests

`gateway/test/expenses_363.test.js` (5), `test/trip_planning_lite_363_test.dart` (5, pure).
