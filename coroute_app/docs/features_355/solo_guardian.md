# Solo and guardian safety (v3.55)

Area: solo_guardian. Five features from the v3.55 plan: Solo check-in timer, No-signal ahead, Arrival message, Help from public riders, Start and arrival roll call. The logic runs on the phone. The gateway only relays, stores small markers and fans out.

| Feature | Switch id | Rider setting | Status |
| --- | --- | --- | --- |
| Solo check-in timer | `soloCheckIn` | Settings > Safety > "Solo check-in timer" (`etaCheckIn`, on) | Done (needs device checks) |
| No-signal ahead | `noSignalAhead` | Settings > Safety > "No-signal ahead" (`noSignalAhead`, on) | Done (needs device checks) |
| Arrival message | `arrivalMessage` | none | Done (gateway tested) |
| Help from public riders | `publicRiderHelp` | uses the existing "Ask nearby riders" and "Help other riders" switches | Done (gateway tested) |
| Start and arrival roll call | `rollCall` | none | Done (analyzer and pure tests only) |

All five switches are in `gateway/src/feature_flags.js` (Safety group, plus `rollCall` in Group). None of them is locked, and none of them gates SOS, crash or emergency texts. On the phone they are read with `FeatureFlagsService.on` / `context.featureOn`, where unknown means on.

## 1. Solo check-in timer

**Behaviour.** The timer arms when a solo ride with a destination is STARTED, the rider has an emergency contact (7 or more digits), the setting is on and the switch is on. A solo ride here means `ConvoyModel.isSolo`, so a group ride where only I am riding also counts.
- The deadline is ETA + max(20 min, 25 % of the ETA). The ETA is computed on the phone with `RideFacts.remainingM` along the route line, at the route's pace (`RideFacts.etaFor`). Without a usable route it falls back to straight-line distance x 1.3 at 40 km/h. No signal is needed.
- Re-arming happens only while I am moving (15 km/h or faster), checked every 30 s. The deadline only ever moves later, and never to less than 10 min from now. While I am stopped the deadline stays put, so a fallen rider is still checked on. A moving rider is never asked; the deadline just follows the ETA.
- At the deadline, if I am stopped or slow: the prompt "Are you OK?" appears, with the buttons "I'm fine" and "Add 30 min". It is shown through SafetyService's prompt list, so it also appears as the lock-screen prompt notification. Voice says "Are you OK? Tap I am fine on the screen." in the important tier.
- After 3 min with no answer, one text goes to the emergency contact: "CoRoute check-in: <name> has not reached <destination> by HH:MM and did not answer. Last known position at HH:MM: <maps link>". The prompt then says that the contact was texted. If I tap "I'm fine" after that, a follow-up text "<name> answered "I'm fine" at HH:MM" is sent, but only when the first text was actually sent.
- "I'm fine" re-arms the timer for max(30 min, ETA + margin). "Add 30 min" moves the deadline 30 min later. Swiping the card away counts as "Add 30 min".
- Disarmed when I arrive: either the gateway's destination arrival for me, or within 200 m of the destination on the phone, which works offline. Also disarmed on ride end, when someone joins the ride, when the setting or switch is turned off, or when the contact is removed. It is armed at most once per ride.
- Nothing is asked and nothing is texted while a crash alarm or an SOS of mine is open (`SafetyService.emergencyOpen`, a pending SOS or my open alert). The step waits until the emergency is closed.

**Texting path.** The phone's `SmsSender` (`NativeSmsSender`) is used when the build may send SMS (`capability().ready`). Otherwise it opens the messages app with the text filled in (`SmsComposer`), but only while the app is in front. **Limitation:** on Play builds without SEND_SMS, an unresponsive rider's phone in the background cannot text automatically. The prompt and lock-screen notification still appear. This is documented for the owner. There is no server-side or paid SMS fallback (plan principle).

**Files.** `lib/domain/safety/eta_check_in.dart` (pure state machine and SMS texts), `lib/data/services/solo_guardian_service.dart`, and hooks in `lib/data/services/safety_service.dart` (`showOwnedPrompt`, `removeOwnedPrompt`, `emergencyOpen`, plus 5 lines at the start of `answerPrompt`), `lib/data/services/settings_service.dart` (`etaCheckIn`), `lib/presentation/settings/settings_screen.dart` (switch) and `lib/main.dart` (provider, not lazy).

**Tests.** `test/solo_eta_check_in_test.dart` covers the margin, arming, ask then escalate, later-only re-arming with the 10 min floor, "I'm fine" / "Add 30 min" (including the follow-up flag), disarm and the SMS text. These were run with the Dart VM through a temporary shim (6/6 pass), since Flutter tests cannot run here.

**Real-device validation.** Timer with the screen off (Timer.periodic plus foreground location service). SMS on a sideload build with SEND_SMS and with no data signal. Composer on a Play build. Prompt notification actions ("I'm fine" / "Add 30 min" from the lock screen go through `SafetyService._onPromptAction`). Voice not speaking during an SOS.

## 2. No-signal ahead

**Behaviour.**
- **Coverage log.** On every ride (solo or group) each fix, at most every 5 s and only with accuracy of 100 m or better, records online or offline (`RealtimeService.isConnected`) into a ~500 m cell (`CoverageLog.cellKey`: a 1/222 degree latitude band and a cos-corrected longitude step). Each ride counts as one pass per cell. A pass is offline if the signal dropped anywhere in the cell during that ride. The log keeps at most 5,000 cells, dropping the least recently passed first. It is saved in SharedPreferences (`coverage_log_v1`) every 2 min while it has changed, and at ride end. The log never leaves the phone.
- **Decision.** Every 30 s during a STARTED ride, only while online and on the route (within 300 m), not during an emergency, and at most once per 10 min. It looks for a stretch whose first dead cell starts 2 to 5 km ahead along the route. A cell is dead when it was offline in 2 or more passes and more often offline than online. A stretch that already starts within 2 km is skipped as too late. The stretch continues through dead or unlogged cells and ends at the first cell with signal (at most 60 km). Back online time = end of the stretch / the route's pace (or my speed, or 40 km/h).
- **Sending.** Once per stretch per ride, the phone sends WS `SIGNAL_AHEAD { backAt, near? }`. `near` is the planned stop or destination within 10 km of the stretch start, if there is one. The gateway (`gateway/src/signal_ahead.js`) checks the message: backAt must be 1 min to 3 h ahead, near is at most 60 characters with controls and links stripped, and there is one notice per rider per 5 min. It keeps the notice in memory only, sends the room event `SIGNAL_AHEAD { userId, name, near, backAt }` to the group, and Ride Guardian links of the rider (LIVE and BASIC, never EMERGENCY_ONLY) get `signalAhead`. The guardian page then shows "Entering a no-signal stretch near X, expected back online around HH:MM. The last reported location is shown." When the phone is back online after having been offline, it sends `SIGNAL_AHEAD { clear: true }`. The notice also lapses on its own 30 min after backAt, and is dropped when the room ends.
- **Rider card.** "No signal ahead": "Your phone had no signal for about N km from X km ahead on earlier rides. Your group and guardians were told you expect to be back online around HH:MM." It is shown for 3 min. Other riders of my ride see "<name>: no signal ahead" for 10 min or until cleared. Both are normal-tier route-info slots in the cockpit, so they never rank above safety slots and are informational and dismissible. Nothing is spoken.
- **Why not STATUS.** The existing status reason is cleared by the phone as soon as the rider moves (`ConvoyService` location update), so a moving rider's "no signal ahead" status would vanish at once. A dedicated relay-only message is used instead (switch-gated in `WS_FEATURE`).

**Files.** `lib/domain/safety/coverage_log.dart` and `lib/data/services/solo_guardian_service.dart`; cockpit slot and rebuild selector in `live_cockpit_map_screen.dart` (small anchored insertions); `gateway/src/signal_ahead.js`; `gateway/src/ws.js` (one `case`, plus a budget entry in ACTION_TYPES); `gateway/src/app.js` (wiring); `gateway/src/guardians.js` (`signalAhead` in the personal projection); `gateway/public/assets/guardian.js` (text).

**Tests.** `test/coverage_log_test.dart` covers cell size, one pass per ride, the online-to-offline flip in a pass, 2-pass detection with the 2 to 5 km window, a single pass not being enough, mostly-online cells not being dead, LRU cap and save/restore (4/4 pass on the VM shim). The gateway test `gateway/test/guardian_arrival.test.js` ("no-signal ahead") covers validation, cooldown, group event, guardian field, EMERGENCY_ONLY exclusion and clear.

**Real-device validation.** Real dead zones (ghats, tunnels). Offline detection: `RealtimeService` state may lag a few seconds behind the radio. Whether a phone with "online" but no data (captive or weak signal) logs falsely. Guardian page wording. Two-VM note: the notice is memory-only on the node that runs the room, so a guardian view built on the peer node misses it. This is acceptable because it is informational.

## 3. Arrival message

**Behaviour.** `gateway/src/guardian_arrival.js` listens to the room events ConvoyManager already emits and writes one "arrived" marker per rider:
- on `DESTINATION_ARRIVALS` with `allReachedAt` (everyone reached the destination; for a solo ride that is the rider's own arrival), or
- on `TRIP_STATUS ENDED` by a rider. A `system` end, when a ride was emptied or abandoned, is **not** "safe".

Riders with an open (unresolved) SOS or crash alert never get a marker. Markers go in the trip events collection under groupId `guardian:<groupId>` (so the riders' own timeline never shows them), with eventId `ARRIVED-<groupId>-<userId>`. The first write wins, so the message is sent once and its time never moves.

After that, `GuardianService`:
- shows status `ARRIVED` with `arrivedAt` and **no position**, and no movement status. A GROUP link shows ARRIVED when every shared rider arrived.
- puts "Arrived safely" in the timeline.
- expires the link 2 h after the arrival (`ARRIVED_KEEP_MS`); sessions and new exchanges then get 410.
- still shows an SOS raised after the arrival as an emergency.

Guardian web push (`guardian_push.js`): `stateOf` carries `arrived`, so one push goes out, titled "CoRoute: arrived safely" with the body "The rider arrived safely. Location sharing has stopped." It contains no names (trip preference; not for EMERGENCY_ONLY, as before). The guardian page shows "Arrived safely. Location sharing has stopped." Switch `arrivalMessage` off: no markers are written.

**Files.** `gateway/src/guardian_arrival.js` (new), `gateway/src/guardians.js`, `gateway/src/guardian_push.js`, `gateway/src/oracle/repo.js` (`guardianArrival`, `addGuardianArrival`), `gateway/src/app.js`, `gateway/public/assets/guardian.js`.

**Tests.** `gateway/test/guardian_arrival.test.js` covers: arrival shows ARRIVED with no position and a timeline entry; it is sent once (a later end keeps the first time); it is not in the rider timeline; link expiry; normal end vs system end vs open SOS; partial arrivals ignored; an emergency after arrival still shown; switch off; delivery through ConvoyManager 'event'; and a single "arrived safely" push without names. Existing guardian suites pass (41 tests).

**Real-device validation.** End-to-end with the guardian pilot env (`GUARDIAN_ENABLED`, `GUARDIAN_PUSH_ENABLED`): the push on Android Chrome and iOS Safari, and the page after arrival.

## 4. Help from public riders

**What already happened.** The safety network (`safety_network.js`) already considers riders of *every* live convoy, so riders of public rides were already asked when the route rules matched: they had to be on their own route with the point ahead, or heading straight at it at 15 km/h or more. A rider of a public ride who was parked, on a side road or without a route was never asked. Public-ride blocks and suspensions were not applied.

**Added** (`_publicCandidate`, switch `publicRiderHelp`). A rider of a ride with public ride on (`publicRideOf(meta.publicRide).on`) who is within 2 km in a straight line (`NET_PUBLIC_RADIUS_M`, clamped to 200 to 5000 m) is a candidate (mode `PUBLIC`) when the route and heading rules do not pick them. ETA = distance x the detour factor at the network's speed model, with the stopped penalty when parked.
- Same consent as the network: the subject's "Ask nearby riders" (`assistAsk` / `assistDefault`) and the helper's "Help other riders" (`assistHelp`). Same caps, rate limits, per-group limits and ETA-vs-own-group rule. Riders with their own open emergency or already responding are excluded.
- Never across a public-ride block in either direction with any subject of the incident. Never a rider whose public ride is suspended (`publicRides.blocked` / `suspendedUntil`, wired with `network.publicRides = publicRides` in app.js).
- `ASSIST_REQUEST` adds `publicRide: true` and still carries no name, id, phone or medical info. Medical info is shared only after acceptance and only with `responderMedical` (unchanged).

**Tests.** `gateway/test/public_rider_help.test.js`: a parked public-ride rider 700 m away is asked (and the request has no identity fields), while the same rider in a private ride is not (existing rules unchanged). Help switched off, or the subject's group not asking: nobody is asked. A block, a suspension or the admin switch off keeps the rider out. `safety_network.test.js` and `public_ride.test.js` still pass.

**Real-device validation.** A field run with two phones: a parked public ride near a staged SOS, checking the request card on the helper's phone.

## 5. Start and arrival roll call

**Behaviour** (group rides only, informational). `RollCallCard` sits in the ride sheet above the riders list:
- **Start roll call.** During the first 15 min of the ride, and until everyone has joined, each rider is "Joined" or "Not yet". "Joined" means a position reported since the ride started, with 5 min slack. The ride start is the first time this phone saw the ride STARTED, or its creation time when that is under 15 min ago.
- **Arrival roll call.** Once anyone has reached the destination (`convoy.destinationArrivals`), each rider is "Arrived" or "On the way", with the summary "N of M arrived" or "Everyone has arrived".
- Riders still to tick are listed first. At most 12 rows, then "and N more".
- No new server data. When everyone has arrived, the gateway's existing `destinationAllReachedAt` triggers "Arrived safely" on the guardian links of the group's riders (item 3).

**Files.** `lib/domain/group/roll_call.dart` (pure), `lib/presentation/ride/roll_call_card.dart`, and one line plus imports in `live_cockpit_map_screen.dart`.

**Tests.** `test/roll_call_test.dart` covers the start window, everyone joined, old positions not counting, the arrival phase, and solo or unknown start (4/4 pass on the VM shim).

**Real-device validation.** Layout in the ride sheet (light and dark, large text), and the start time after an app restart mid-ride.

## Tests run

- `dart analyze lib test`: No issues found (at the time of writing).
- Pure Dart via the VM with a temporary flutter_test shim (deleted afterwards): solo_eta_check_in 6/6, coverage_log 4/4, roll_call 4/4.
- Gateway: `node --test` on guardian_arrival, public_rider_help, guardians, guardian_push, guardians_integration, guardian_browser, guardian_push_http, feature_flags_355, public_ride, safety_network: 91 pass, 0 fail.
