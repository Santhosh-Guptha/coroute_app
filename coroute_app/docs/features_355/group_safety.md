# 3.55 group safety

Area: `group_safety`. Six features from the v3.55 plan table "Group and community safety features"
(the first five need a group ride, risky-stretch heads-up works for every plan, solo rides included).
Every decision is made on the phone from what it already has: the riders' relayed positions, its own
fixes, the cached map-places corridor and its own fatigue score. The gateway only relays
(CHECK_IN, BUDDY_PING), stores (the stretch setting, buddy pairs, anonymous hard-brake cells) and fans
out. Phones share levels and events, never raw sensor data.

Phone service: `lib/data/services/group_safety_service.dart` (`GroupSafetyService`, provider in
`lib/main.dart`, not lazy). It ticks every 5 s during a ride, listens to the socket (`SNAPSHOT`,
`RIDER_UPDATE`, `RIDER_LEFT`, `BUDDIES`, `BUDDY_PING`) and its own fixes, and exposes `notices` (cards).
Pure logic (unit tested): `lib/domain/ride/missing_rider_check.dart`, `group_stretch.dart`,
`regroup_point.dart`, `group_break_planner.dart`, `buddy_watch.dart`, `group_safety_rider.dart`,
`lib/domain/safety/risky_stretch.dart`.

Cockpit: `lib/presentation/ride/group_safety_cards.dart` (`GroupSafetyCard`, `BuddyLine`); one anchored
loop in `live_cockpit_map_screen.dart` `_slots()` adds the cards as `_Slot`s with tier important/normal,
i.e. priority `groupSafety`/`routeInfo`: SOS, crash, incidents, assistance and hazards always rank
above. The slot `message` is left empty (the card is the `child`), so the cockpit's fuel de-dup filter
cannot hide a regroup card at a fuel station.

Safety rules applied everywhere:
* Never speaks while an SOS / crash alarm is open (`_say` checks `SafetyService.alarm`, my open SOS,
  a pending SOS and any unresolved alert of the ride), and never asks anything while one is open.
* At 15 km/h or more the lead/buddy cards are information only ("Stop safely to act on it."); the
  missing-rider card only exists while the rider is stopped.
* Hold times, cooldowns and once-per-X rules on every card (below).

Admin switches (gateway/src/feature_flags.js, default on, not locked): group `Group`:
`missingRiderCheck`, `stretchAlert`, `regroupSuggest`, `groupBreak`, `buddyPairs`; group `Riding`:
`riskyStretch`. The app reads them through `GroupSafetyService.featureOn = FeatureFlagsService.on`
(null/unknown = on). The gateway enforces `buddyPairs` on `BUDDY_ASSIGN` / `BUDDY_PING` (WS_FEATURE) and
`riskyStretch` on `/api/road-risk/*` (403 FEATURE_OFF).

---

## 1. Missing-rider check (`missingRiderCheck`) — done

**Behaviour (each rider's own phone).** "Are you OK? The group is moving on" (spoken once, amber card)
when all of these hold:
* I have been stopped for 3 min (slower than 5 km/h and within 80 m of where I stopped), or my phone
  saw no new fix for 3 min (silent phone counts as stopped since the last fix);
* at least 60 % of the other fresh riders (update within 2 min) are moving (15 km/h or more);
* the nearest moving rider is more than 1 km away and that distance grew by at least 300 m since I
  stopped (riding away, not parked around the corner);
* I gave no stop reason, no SOS / crash alarm is open, and I did not already answer during this stop
  (15 min quiet).

Answers: **I'm OK** (STATUS reason CUSTOM, message "I'm OK", so the lead sees why on my rider card),
**Need help** (asks the group to wait + STATUS "Needs help"; SOS stays one tap away), **Waiting for
fuel / Photo stop / Taking a break** (STATUS FUELING / PHOTO_STOP / REST_BREAK). A status reason clears
by itself when I ride again (existing ConvoyService rule).

No answer in 90 s → `sendCheckIn(CheckInResult.noReply, awayM, context: CheckInContext.missingRider)`
through the existing outbox/CHECK_IN path; the gateway opens its existing `NO_REPLY:<uid>` timeline
entry (now with `data.context = 'MISSING_RIDER'`), and the lead/sweeper get the existing "No reply from
Ravi" alert with the text "Stopped while the group moved on and did not answer Are you OK".
A later "I'm OK" also sends CHECK_IN OK, which closes that entry.

**No duplicates:** the no-reply is NOT sent when my phone has seen a server alert about me in the last
5 min: an open or recently closed SEPARATED, POSSIBLE_INCIDENT, NO_REPLY or BEHIND_SWEEPER entry, or a
STOPPED entry open for 20 min or more (the point where AlertPolicy tells the lead). The card stays and
says "Your lead was told".

The card goes away by itself when I ride again, the group comes back within 800 m, or an alarm opens.

**Gateway:** relay only. `timeline.js checkIn()` keeps `context: 'MISSING_RIDER'` on NO_REPLY (one line).
**App edits:** `CheckInContext.missingRider` (safety_wire.dart), NO_REPLY text branch (alert_policy.dart).

## 2. Group stretch alert (`stretchAlert`) — done

**Behaviour (lead's phone: riding lead or owner).** Spread = along-route distance between the
front-most and the last fresh rider on the route (within 300 m of `convoy.routeLine`; riders off the
route or stale are left out; fewer than 2 → no reading, the state is held). Over the threshold for
30 s → amber card + voice "Group spread 4 kilometers, slow down"; repeated at most every 5 min while
still over; cleared when back under 80 % of the threshold.

**Setting:** `featurePolicy.stretchAlertKm`, lead-only like the other group settings, choices
1 / 2 / 3 / 5 km, default 3. Gateway `feature_policy.js` (`DEFAULTS`, `CHOICES`, validation in
`policyPatch`: anything else → "Invalid feature setting"); app `RideFeaturePolicy.stretchAlertKm` and a
"Group spread alert (km)" chip row in `group_settings_sheet.dart`.

## 3. Smart regroup point (`regroupSuggest`) — done

Inside the stretch card: "Regroup at Indian Oil, 4.2 km ahead" (ahead of the lead) with **Set regroup
point**, which uses the existing meeting-point flow (`RoutePlan.meetingPlacement` +
`ConvoyService.addMeetingPoint`, the same as "Meet here"; the button shows only when this phone may
edit the route and is slow).

Picker (`RegroupPointPicker`): places from the cached map-places cells (`MapPlacesService.all`, no
network) of category fuel, food or a rest place (stay, toilet); within 300 m of the route; between 2 and
10 km ahead of the LAST rider and not behind the lead; fuel before food before rest, then nearest to the
middle of that window. No place fits (or the spread is wider than the window) → the card says how far
the last rider is behind instead.

## 4. Group break planner (`groupBreak`) — done

* Each phone sends only its fatigue level 0..3 in the existing TELEMETRY (`fatigueLevel`), from its own
  0–100 score (`SafetyService.fatigueLevel`, from the sensor-safety hub): 0 under 40, 1 40–69,
  2 70–84 (break advised), 3 85+. Hook: `ConvoyService.fatigueLevel` (set by GroupSafetyService; null
  while the switch is off = not sent).
* Gateway (`convoys.js`): `fatigueLevel` in TELEMETRY_FIELDS; `sanitizeTelemetry` keeps only a finite
  number rounding to 0..3 (anything else dropped), stamps `fatigueAt`; `publicRider.fatigueLevel` is the
  level while under 10 min old, else 0 (older apps never send it → 0). `fatigueAt` stays on the server.
* Lead's phone: at least 2 riders, or at least 30 % of the fresh riders, at level 2+ for 60 s → card
  "Several riders need a break. Plan a stop?" with a count only ("3 riders are getting tired.") and the
  smart regroup place as the stop; **Plan stop** adds it as a planned stop (15 min). Again at most every
  30 min. The card never names who is tired. (Note: the level is in the rider record every group member
  receives, like battery; the app shows it to nobody.)

## 5. Buddy pairs (`buddyPairs`, Large Group) — done

**Gateway (`gateway/src/buddies.js`, wired in app.js as `convoys.buddies`):**
* Deterministic pairs: riders ordered by sha256(groupId:userId), paired one after the other; odd count →
  the last pair is a trio (a→b→c→a, each rider still watches exactly one). Stored as
  `meta.buddies {userId: buddyId}`, in the snapshot as `buddies`, every change broadcast as
  `BUDDIES {buddies, byUserId}`.
* Automatic when a ride reaches 7 riders with no pairs yet; re-paired on every join/leave keeping every
  intact pair (the orphan and the newcomer are paired; an odd one out joins or breaks up a trio).
* `BUDDY_ASSIGN` (lead: riding lead, owner or master admin; member check; plan check host seats ≥ 7 or
  riders ≥ 7 → else 403 PLAN_REQUIRED) gives everyone fresh pairs.
* `BUDDY_PING {userId, kind: CHECK|OK}`: only between buddies (else 403 NOT_BUDDY), relayed with
  `userMessage` to that one rider only, one per pair and kind per 30 s.

**App:** "Your buddy: Kiran" (+ Assign / Reassign for the lead) in Group settings → Buddy pairs
(`BuddyLine`). My phone watches my buddy: offline (no update 2 min), more than 1 km behind me along the
route (as the crow flies when there is no route, while I move), or stopped more than 300 m away while I
keep moving with no stop reason — for 2 min → card "Check on Kiran" with **Call**, **Send a check**,
**They're fine** (10 min snooze), **Ask group to wait** (taps only when slow). "Send a check" sends
BUDDY_PING; the buddy's phone shows "Your buddy is checking on you — tap I'm OK" (spoken), and I'm OK
sends BUDDY_PING OK back ("Kiran is OK", snoozes my card).

## 6. Risky-stretch heads-up (`riskyStretch`, every plan) — done

**Phone:** every new hard brake counted by SafetyService (`hardStops`, HardBrakeCounter) is queued at
once as the ~200 m cell centre + heading bucket (8 × 45°) — the exact spot is never kept; at most 3 per
cell and direction, 200 in all; sent every 10 min and at ride end as `POST /api/road-risk/brakes
{events:[{lat,lng,h}]}` (no user id in the payload; kept and retried on network/5xx/429).
Cells are fetched at ride start and every 30 min (`GET /api/road-risk/near?groupId=`); heads-up once
per cell per ride when it is up to 500 m ahead (along the route when possible) in my direction
(within 67.5°) at 15 km/h+: "Many riders brake hard on this stretch. Ride carefully." (30 s card).

**Gateway (`gateway/src/road_risk.js`, collection `road_risk`, created lazily):** per cell + heading
bucket only `{riskId, cell, hb, lat, lng (cell centre), count, reporters (≤ 200 salted hashes),
reporterCount, firstDay, lastDay}`. The reporter hash is HMAC(secret, cell:hb:userId), so hashes cannot
link one rider across cells. `near` returns only cells with ≥ 10 distinct reporters within 120 m of the
ride's route (3 km of the start–destination line without a route), members only, as `{id, lat, lng,
headingBucket, headingDeg}` — no counts or hashes. Retention (retention.js): cells with no event for
180 days are removed. Grid step 0.002° in both apps (`RiskGrid.step` / `STEP`).

---

## Tests

* Gateway `test/group_safety_355.test.js` (12): stretchAlertKm validation (pure + CONFIG lead-only),
  fatigueLevel sanitising / freshness / socket fan-out, buddy assignment determinism / odd counts /
  re-pairing / auto at 7 / snapshot / lead-only / plan check, BUDDY_PING relay-only / NOT_BUDDY /
  throttle, road-risk store k ≥ 10 / heading split / no user ids / retention, REST auth / near-route
  filter / members only / switch off, missing-rider NO_REPLY context through CHECK_IN.
  Also run green: timeline, safety_behaviour, net_compat, feature_flags_355, feature_policy, rider_patch,
  room_snapshot, ride_swap_355, sweeper, incident, follow_up_admin, outbox, plans_cleanup_355, gateway,
  two_node_failover.
* Dart `test/group_safety_355_test.dart` (17, pure): missing-rider decisions (ask, no-reply,
  suppression, parked group, reason, emergency, 60 % rule, silent phone, quiet after answer), spread
  and stretch hysteresis, regroup picker (priority, window, off-route, behind lead), break planner
  trigger / quiet time / buckets, buddy check (behind, offline, stopped, together, snooze), risky
  stretch grid / queue / announcer. Executed with a flutter_test shim under `dart` (all pass); the
  Flutter runner itself is not available here.

## Needs real-device validation

* Missing-rider thresholds with real GPS drift (80 m anchor, 5 km/h stop speed) and phones whose GPS
  distance filter stops fixes when parked (treated as stopped after 3 min of silence).
* Along-route spread on winding ghat roads and routes with loops (projection to the nearest segment).
* Whether the map-places corridor is loaded far enough ahead (the corridor fetch follows the rider; a
  lead far ahead of the last rider may not have the cells around the window yet → no suggestion).
* Hard-brake rate per rider and the 10-rider threshold in practice (cells may take months to confirm).
* The buddy "behind" rule without a planned route (straight-line distance while moving).
* Voice timing next to navigation prompts (all lines use the important tier).
