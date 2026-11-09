# Bike markers, bike shapes, mandatory bike details and the pillion seat (3.55)

## What riders see

- **Ride map**: every bike is one marker: a small white plate with the bike's shape (its type) in
  the bike's colour (`vehicleColor`). The plate keeps the old cues: ring colour (rider colour while
  moving, amber when stopped, red for SOS, teal glow for me), status dot, a role letter (L lead,
  S sweeper), selected glow, faded when the position is stale. The bike faces the way it travels
  (mirrored when heading left on the screen); the heading arrow still points exactly.
- **Pillion**: a seated pillion has no dot of their own. Their rider's bike shows two people, the
  label says "Asha + Kiran", and screen readers hear "Asha, Classic 350, red, with pillion Kiran,
  42 km/h, Riding". On the pillion's phone the pair is drawn at the pillion's own position (it
  follows their camera). If the rider's phone goes quiet (more than 20 s older than the pillion's),
  the pillion's position carries the bike, so the pair never disappears.
- **Garage**: each bike card shows the bike's shape instead of a round icon; the add / edit sheet
  has a bike type picker (each type with its shape), pre-selected from the model.
- **Before riding**: creating or joining a ride as a rider needs a bike with complete details. If
  something is missing, "Complete your bike" opens inline, pre-filled (preset for the model, type
  guess). Joining offers "I'm riding pillion (no bike)", which then asks which bike they sit on.
  Existing riders with an incomplete bike are asked once on the home screen.

## Bike types and shapes

`BikeType` (`lib/domain/garage/bike_type.dart`), wire id = rider record `vehicleKind`:

| id | Label | Inferred from (examples) |
|---|---|---|
| `commuter` | Commuter | Splendor, Shine, Pulsar 150, Platina |
| `scooter` | Scooter | Activa, Jupiter, Access, Ntorq |
| `sport` | Sport | R15, Duke, Apache RTR, Pulsar NS, Ninja |
| `cruiser` | Cruiser | Meteor, Avenger, Rebel, X440 |
| `adventure` | Adventure / Tourer | Himalayan, GS, Xpulse 200T, Tiger, Scram |
| `offroad` | Off-road / Dirt | Xpulse, CRF, EXC |
| `electric` | Electric | Ather, Ola, Chetak, iQube (or fuel type Electric) |
| `retro` | Cafe racer / Retro | Classic 350, Interceptor, Jawa, Hunter |

The guess only pre-selects; a bike counts as complete when the rider picked / confirmed the type.
Unknown names fall back to commuter for drawing. The silhouettes are original, simple vector
designs (`lib/presentation/garage/bike_silhouette.dart`: SVG-style path data, 64 × 44 design box)
and are the same on the map and in the garage. Visual check: the same data rendered to SVG at
24 px and 64 px, with one and two riders and on the marker plate.

Performance: one recorded `Picture` per type + colour + people + cue + 4 px size bucket
(`BikeMarkerKey`, LRU of 96, `BikeGlyphCache`), replayed by every marker each frame.

## Mandatory bike details

`BikeDetails` / `validateBikeDetails` (`lib/domain/garage/bike_details.dart`):

| Detail | Petrol / diesel / CNG | Electric |
|---|---|---|
| Make and model | required | required |
| Bike type | required (confirmed) | required |
| Engine size | 50 to 2500 cc | not asked |
| Colour | required | required |
| Tank | 2 to 40 L (kg) | battery kWh optional |
| Mileage | 5 to 120 km/L | 2 to 25 km/kWh |

Never enforced for SOS, never mid-ride, never locks the app: closing the sheet only cancels that
create / join. The gateway never refuses an older app: the rider record gets `bikeComplete: false`.

## Protocol (gateway)

Rider record (`publicRider`, room snapshot, replicated like the rest):
`vehicleKind` ('' unknown), `bikeComplete` (bool, the app's claim), `pillionSeatAt` (ms, 0 = none).
Create / join `rider` and `RIDER_VEHICLE` accept `vehicleKind` (one of the ids, else dropped at
join / 400 `BAD_VEHICLE` live) and `bikeComplete` (only with a bike field).

HELLO feature **`pillion2`**.

| Message | Who | Effect |
|---|---|---|
| `PILLION_SEAT {withUserId, clientId}` | the pillion | Links pillion → rider. Checks: group ride, not ended, target in the ride, not themselves (400 `BAD_PILLION`), target is not a pillion (409 `TARGET_PILLION`), target has no other pillion (409 `SEAT_TAKEN`), caller carries no pillion (409 `HAS_PILLION`), 6 per 10 min (409 `PILLION_RATE`). Same seat again = no-op. Moving to another bike tells the first rider (`MOVED`). Admin switch `pillionSeat` off: 403 `FEATURE_OFF`. |
| `PILLION_UNSEAT {userId?, clientId}` | the pillion (no id) or the rider of that bike (pillion's id) | Unlinks. Reason `PILLION_LEFT`, or `DECLINED` within 60 s of the seat / `REMOVED` later. Anyone else: 403 `NOT_YOUR_PILLION`; nothing to undo: 409 `NOT_SEATED`. Never feature-gated. |

Room events (to everyone): `RIDER_UPDATE` for the pillion, then
`PILLION_SEATED {pillion:{userId,name}, rider:{userId,name,vehicleModel,vehicleColor,vehicleKind}, at, declineBy}` and
`PILLION_UNSEATED {pillion, rider, reason, byUserId}` with reason `DECLINED | REMOVED | PILLION_LEFT | RIDER_LEFT | MOVED`.
A rider who leaves unlinks their pillion (`RIDER_LEFT`, the pillion is asked to pick again); a
pillion who leaves frees the seat. The link ends with the ride (the records go).

Compatibility: older apps keep using `CORIDER` (still accepted; it now refuses a link to oneself)
and see a pillion as a normal rider with `isCoRiding`. Older apps ignore the new event types and
fields. The new app uses `PILLION_SEAT` only when HELLO lists `pillion2` and the switch is on,
else falls back to `CORIDER`.

## App behaviour

- `ConvoyService.seatPillion / unseatPillion / pillionOffer / pillionNeedsSeat / requestPillionPick`.
  Everyone gets the card and spoken line "Kiran is riding pillion with Asha" (swap notice slot).
  The rider gets "Kiran is riding pillion with you" with Decline for a minute (chip while moving);
  "Remove pillion" stays on the pillion's rider card. A pillion without a bike gets "Pick the bike
  you ride on" (a pillion can always tap).
- Safety: the pillion's phone keeps every safety feature (crash detection, SOS, fall checks)
  exactly as before; only the map marker merges. `BikeMarkerPlan.countedOncePerBike` lists riders
  once per bike for stats. Group safety counts a seated pillion once per bike too
  (`BikeMarkerPlan.safetyRoster`: missing-rider check, spread, group break; the bike carries the
  pillion's position when the rider's phone went quiet; a buddy on my own bike is not watched; the
  roll call marks a seated pillion joined / arrived with their bike). Gateway timeline
  (`oncePerBike` in `timeline.js`): no SEPARATED / BEHIND_SWEEPER entry for a seated pillion apart
  from their rider, packs in CONVOY_SPLIT are counted in bikes, and a seated pillion is never picked
  as the automatic lead / sweeper.
- **Missing-rider check, one bike = one answer (owner decision, Nov 9).** If either the rider or the
  seated pillion answers "Are you OK?" (I'm OK, a stop reason, Need help, or SOS), the check closes on
  both phones and the lead gets one notice at most. App: the answer already reaches the other phone as
  the answering rider's `RIDER_UPDATE` (`statusReason` + `stoppedSince`); `GroupSafetyService` passes
  the bike partner's answer time (`BikeMarkerPlan.partnerOf`) to `MissingRiderCheck.evaluate
  (partnerAnsweredAtMs)`, which closes the card (`MissingRiderAction.answeredOnOtherPhone`) and never
  sends "no answer" for that stop; an answer older than the current stop (2 min clock slack) does not
  count. If this phone had already told the lead, it sends I'm OK (`CHECK_IN OK`). An SOS opens an alert,
  which already closes the check on every phone. Gateway (`timeline.checkIn`, `bikePartnerOf`): a
  missing-rider `NO_REPLY` is not opened when the bike partner's `NO_REPLY` is already open
  (`{opened:false, sameBike}`) or the partner answered within 15 min (`{opened:false, answeredOnBike}`);
  an OK closes the partner's `NO_REPLY` too (`data.answeredBy: 'BIKE_PARTNER'`), never their possible
  incident. Tests: `pillion_seat_355.test.js` (one bike, one answer), `test/group_safety_355_test.dart`.
- Admin switch `pillionSeat` (Group): off → pillions are drawn as their own markers and the old
  `CORIDER` link is used.

## Tests

- Gateway: `gateway/test/pillion_seat_355.test.js` (validation, broadcast to all, decline /
  remove / get off / rider left / moved, rate limit, snapshot and stored room snapshot, old
  `CORIDER`, switch off). `net_compat` HELLO list updated.
- App (pure): `test/bike_markers_garage_355_test.dart` (type inference, mandatory details incl.
  electric, suggestions, marker plan, cue, colours, cache key and LRU, labels, pillion seat rules
  and notices, `RIDER_VEHICLE` with the type). `garage_355_test` preset check covers electric presets.
