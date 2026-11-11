# Bike markers, bike shapes, mandatory bike details and the pillion seat (3.55)

## What riders see

- **Ride map (3.56, 3D)**: every bike is one marker: a top-down **3D motorcycle with its rider**
  (helmet with visor, shoulders, arms on the bars), in the bike's type and colour (`vehicleColor`),
  with a soft shadow on the map, like a navigation app's 3D car arrow. No plate. It turns to the
  rider's heading (smoothed between reports by `SmoothMarkerLayer`, passed down as `MarkerHeading`;
  below 3 km/h or without a GPS course it keeps the last heading, `HeadingHold`), so the old heading
  arrow is gone. State cues: a soft ground halo / ring under the bike (rider colour while moving,
  amber when stopped or with a warning, pulsing red for SOS, blue glow for me, white ring and 12 %
  larger when selected), an upright status dot, an upright role chip (L lead, S sweeper),
  desaturated and translucent when stale. The name / speed label under it is unchanged, and so are
  the screen-reader labels. Admin live maps and the trip report / replay use the same 3D marker
  (replay heading from the track: `ReplayTrack.headingAt`).
- **Pillion**: a seated pillion has no dot of their own. Their rider's bike shows two people (the
  pillion behind, light helmet and jacket), the
  label says "Asha + Kiran", and screen readers hear "Asha, Classic 350, red, with pillion Kiran,
  42 km/h, Riding". On the pillion's phone the pair is drawn at the pillion's own position (it
  follows their camera). If the rider's phone goes quiet (more than 20 s older than the pillion's),
  the pillion's position carries the bike, so the pair never disappears.
- **Garage**: each bike card shows the bike as a rendered 3D 3/4 view of its type in its colour
  (3.56, same models as the map); the add / edit sheet has a bike type picker (each type with its
  3D view), pre-selected from the model. The pillion confirm shows the bike with two people.
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
Unknown names fall back to commuter for drawing.

### 3D bikes (3.56)

Owner feedback: the plate marker looked like a sticker; riders should be 3D vehicles. Each type has
an original procedural model (tool/map_bikes, three.js), recognisable from above: Commuter; Scooter
(apron, floorboard, small wheels, bulbous body); Sport (narrow pointed fairing, clip-ons, tucked
rider); Cruiser (long wheelbase, wide pull-back bars, chrome, laid-back rider); Adventure / Tourer
(wide bars with hand guards, tall screen, panniers + top box); Off-road (narrow, knobby tyres, high
fender, number plate, elbows-up rider); Electric (one smooth shell, glowing cyan light blades);
Cafe racer / Retro (round tank, round chrome headlight, single seat hump).

Follow-up (Nov 9): Commuter, Electric and Retro looked alike at the cockpit size (~57 px). Now the
Commuter has a slim tank, a flat square seat and a light **carrier rack** past the tail; the Electric
has no engine or exhaust, a pointed teardrop shell with a **cyan light strip along each flank**, a
cyan nose bar and a wide hub motor with cyan rings; the Retro has a **round headlight with a flat
chrome ring**, **twin round mirrors** on stalks, a chrome tank strip, a wide flat bench with a tan
stitching band and an upright rider. Check sheet: `preview.mjs --mode types --size 57` (8 types,
1 / 2 riders, 3 colours, light and dark map). Assets regenerated for these three types (map and
garage), 1.07 MB in all.

Assets (`BikeSprites`, `assets/map_bikes/<type>_<1|2>_<layer>.png` and `assets/garage_bikes/
<type>_<0|2>_<layer>.png`, 1x / 2.0x / 3.0x, palette PNG, about 1.1 MB in all): map layers `shadow`,
`base`, `paint` (white shading, tinted at runtime with `BlendMode.modulate`, dark colours lifted by
`BikeSprites.paintArgb`), `gloss`; heroes `base`, `paint`, `gloss`. Regenerate:
`tool/map_bikes/README.md`. The vector silhouettes (`bike_silhouette.dart`, 64 × 44 design box)
stay as the fallback when an image cannot be loaded (`BikeSilhouette(vector: true)` forces them).

Performance: flutter_map draws markers as widgets, so the 3D bike is never re-rendered per heading:
base + tinted paint + gloss are merged once per type + colour + people + pixel size (`BikeMarkerKey`,
LRU of 64, `BikeSpriteCache.merged`) and each marker draws that bitmap and the shadow under a
rotation transform (the merged image sits in a `RepaintBoundary`; a heading change only moves the
layer). `BikeSpriteCache.precache` decodes the images when the ride map opens. The cache key has an
optional heading bucket (`headingBucket`, 10°) for platforms that bake bitmaps per direction.
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

### Asked once, kept in the garage (3.56, owner bug Nov 11)

Owner: "When creating a ride it asks for the bike details every time. Make it one time and sync it
with the garage."

Root causes:
1. **Start-up sync wiped the server copy.** `GarageBinding` sent the bike summary whenever the
   profile arrived (`/me`), also before the garage had loaded, and for an empty garage (a new
   install). That summary was all empty, so `PATCH /me` cleared the rider's bike on the server.
2. **The server copy was incomplete and never read back.** The profile kept model, cc, colour, tank,
   mileage and cooling, but not the confirmed bike type or the fuel type, and refused electric
   mileage below 5 km/kWh. Nothing restored the garage from it, so every new install, reinstall,
   cleared app data or second phone started with an empty garage and the sheet came back.
3. **A complete bike added in the garage did not become the ride bike** while the active one was
   incomplete, so create / join kept asking about the old bike.
4. The one-time home prompt also ran for pillion accounts.

Now (`lib/domain/garage/bike_sync.dart`, pure, `test/bike_details_once_356_test.dart`):
- One source of truth: the garage's active bike. `BikeGate.ensureReady` awaits the garage load,
  lets the profile fill what this phone is missing (`GarageBinding.restoreFromServer`), then decides
  (`BikeGatePlan.decide`). The sheet saves into the garage (edits the active bike, or creates it and
  makes it active), and the create / join goes on at once. Once complete it never asks again unless
  the rider changes the bike to an incomplete one.
- Home prompt (`BikeGatePlan.shouldPromptOnce`): once (shown or dismissed), never for a pillion
  account, a complete bike or an empty garage.
- `GarageService.isLoaded`; nothing syncs before the load. `BikeSync.mayShare`: no summary for an
  empty garage. `BikeSync.changes`: only changed keys, and only keys the gateway returned (an older
  gateway never sees the new ones).
- Profile round-trip: `bikeType` ('' = not confirmed; one of the type ids) and `bikeFuel`
  (`petrol | diesel | cng | ev`) added to the bike summary (`/me`, `PATCH /me`); mileage accepted
  from 2 (electric km/kWh). `BikeSync.merge` restores: an empty garage gets the server bike (details
  the server lacks stay missing, never made up); a local bike of the same model only gets the
  details it is missing; a value the rider gave on the phone is never replaced; a different bike on
  the phone is left alone (it is sent up instead). Gateway test: `bike_details_once_356.test.js`.
- `GarageService.saveBike`: a complete bike becomes active when the active one is incomplete.
- Garage edits still reach the ride live (`GarageBinding` → `ConvoyService.setActiveBikeDetails` /
  `RIDER_VEHICLE`). Pillion path unchanged.

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
- Maps watched from outside the ride use the same once-per-bike plan (follow-up, Nov 9):
  `BikeMarkerPlan.forViewer` in the admin convoy inspector and the master admin fleet map (one
  two-up 3D marker, name "Arjun + Meera", the rider's bike look). The replay (`ReplayScreen` →
  `TripRouteMap.pillionOf`) takes the seated pairs from the ride snapshot the phone holds
  (`seatedPairs`) and merges a pillion into the rider's two-up marker only while the two tracks are
  within 150 m (`replayBikes`; the pillion carries the bike when the rider has no track at that
  moment). Limitation: the stored tracks and the trip report carry no pillion links, so a finished
  ride the phone no longer holds (and the trip report's Route tab) still shows one marker per rider.

## Tests

- Gateway: `gateway/test/pillion_seat_355.test.js` (validation, broadcast to all, decline /
  remove / get off / rider left / moved, rate limit, snapshot and stored room snapshot, old
  `CORIDER`, switch off). `net_compat` HELLO list updated.
- App (pure): `test/bike_markers_viewer_355_test.dart` (admin maps and replay: `forViewer`,
  `nameOf`, `seatedPairs`, `replayBikes`).
- App (pure): `test/bike_markers_garage_355_test.dart` (type inference, mandatory details incl.
  electric, suggestions, marker plan, cue, colours, cache key and LRU, labels, pillion seat rules
  and notices, `RIDER_VEHICLE` with the type; 3.56: asset paths per type / riders, cache key heading
  bucket, colour names incl. "Kaza Brown", paint tint lift, heading hold, replay heading). `garage_355_test` preset check covers electric presets.
