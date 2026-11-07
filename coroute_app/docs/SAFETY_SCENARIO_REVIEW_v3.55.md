# CoRoute v3.55: safety and stability scenario review

Scope: everything changed since baseline `c83ba99` (Flutter rider app and Node.js gateway, two-VM HA).
Method: I read each changed path and traced the real-time sequence (each phone, each gateway node,
the mirror link and the database). Each defect got a regression test that fails on the pre-fix code
and passes after the fix. I checked the five gateway tests against HEAD sources in a scratch copy:
all five failed there. I checked the road-detector case by running the HEAD detector on the same
input.

Result legend: **verified**: behaves as expected, evidence cited. **fixed**: a defect was found and
fixed, with a test. **risk-open**: works as built, but there is a residual risk or a product choice
to decide.

## Defects found and fixed

| # | Area | Defect | Fix | Regression test |
|---|------|--------|-----|-----------------|
| D1 | Riding roles | Since 3.55 any rider can hold LEAD. When that rider left (or was removed), the ride had **no LEAD**. Incident and BEHIND notify lists, sweeper distress and the app's "who leads" all read role LEAD. | `leave()` hands LEAD back to the owner if the owner is still riding. It uses `_commitRoles`, so RIDER_UPDATE, ROLE_CHANGE and the timeline entry go out and the change is replicated. `gateway/src/convoys.js` (leave) | `safety_review_355.test.js` "the riding lead leaves..." |
| D2 | Auto roles vs BEHIND_SWEEPER | With automatic roles on, a rider dropping behind the sweeper became the sweeper after the 45 s hold. That happens before BEHIND_SWEEPER's 60 s hold, so the alert was closed as SWEEPER_CHANGED and the lagging (maybe broken-down) rider was told "you are now the sweeper". | The sweeper keeps the role while a BEHIND or SWEEPER_DISTRESS alert is open, or while the new back rider is more than `SWEEPER_BEHIND_M` behind them. `gateway/src/timeline.js` `_checkAutoRoles` | `safety_review_355.test.js` "automatic roles keep the sweeper..." |
| D3 | Saved road warnings | "Fixed?" (`POST /road-hazards/:id/clear`) was counted per request, not per rider. One rider tapping twice, or a script, removed a pothole warning for everyone. | Each rider counts once, using a salted key (no rider id stored, same scheme as `reporterKeys`). `gateway/src/oracle/repo.js` `clearRoadHazard`, `gateway/src/road_and_places.js` | `safety_review_355.test.js` "Fixed? ... counts once per rider" |
| D4 | Plans | A plan left by an earlier account with the same userId and a later `validUntil` kept winning `findMembershipByOwner()`. It then failed `belongsToAccount()`, so a rider who had just paid (or been granted a plan) was shown **Community**. The leftover's seats could also block an admin grant with CAPACITY_CONFLICT. | The leftover is retired (`EXPIRED`, `PREVIOUS_ACCOUNT`) when a plan activates. `assignPlan` ignores a leftover for capacity and extension. `gateway/src/membership_routes.js` `activateMembershipFromOrder`, `gateway/src/admin_plans.js` | `safety_review_355.test.js` "a plan left by an earlier account..." |
| D5 | Plans (unattended purge) | Daily retention ran `purgeOrphanMemberships()`, which hard-deletes plans whose owner lookup returns nothing. A bad read or a partial restore would erase paid plans for good. | If an unusually large share of owners looks missing (more than max(5, 20%)), nothing is removed and the run reports `orphanPurgeSkipped`. `gateway/src/oracle/repo.js` | `safety_review_355.test.js` "the unattended orphan-plan purge..." |
| D6 | Road warnings vs crash | The road detector ran **before** the crash detector on the same second, and its crash filter was weaker than the crash detector's own rules. A lowside slide (2-3 g, about 1.9 rad/s, under 45 degrees) was reported as a **POTHOLE**: the riders behind were warned and the spot was saved, while the crash alarm opened. | (a) `RoadSurfaceDetector.isCrashLike()` adds the crash detector's slide/fall and high-impact rules. (b) `SafetyService._onAccel` feeds the crash detector first and sends no road event while a crash is being evaluated or an alarm is open. `lib/domain/safety/road_surface_detector.dart`, `lib/data/services/safety_service.dart` | `test/road_places_355_test.dart` "a lowside slide second ... is never a pothole". The same check passed in a pure-Dart run; the HEAD detector returned `pothole`. |
| D7 | Feature switches | The `bleRemote` switch made the handlebar remote ignore **all** keys, including its SOS gestures (triple press, 2.5 s hold). | When the switch is off, only talk (single press) and the hazard marker (double press) stop. SOS gestures always work. `lib/data/services/ble_remote_service.dart` `_dispatchGesture` | Analyzer only (BLE needs a device). Listed for device validation. |
| D8 | Feature switches | The `offlineMesh` switch stopped the phone-to-phone link entirely, including the SOS beacon and its relay when there is no signal. | When the switch is off the mesh runs **SOS-only**: only SOS packets are sent, received and relayed. The switch is read per packet. `lib/data/services/p2p_mesh_service.dart` | Analyzer only (UDP transport). Listed for device validation. |
| D9 | Voice over emergencies | Role prompts, swap asks/results (`ConvoyService.speaker`) and engine-care tips were spoken, and engine tips shown, during an open SOS or crash alarm. | These lines are not spoken while my SOS is pending/open or any alert in the ride is unresolved. The engine tip is also not shown. The role and swap cards still show, below the SOS. `lib/data/services/convoy_service.dart` `_say`, `lib/data/services/safety_service.dart` `_onEngineFix` | Analyzer (Flutter service) |
| D10 | Place-review prompt | Suppressed only for **my own** SOS or alarm. | Also suppressed while any rider's SOS or crash alert is open. `lib/main.dart` (`emergencyOpen`) | Analyzer |
| D11 | Fuel auto-route | A fuel tap while another detour request was in flight (a route back to the group, or another pump) returned false and the pump was **not marked**. The rider's new choice was lost. | The pump is marked at once and its detour is fetched from the next fix once the in-flight request returns. The stale answer is dropped by the existing `identical()` and generation checks. `lib/domain/route/route_guide.dart` `addPersonalFuelStop` | Analyzer (RouteGuide needs Flutter foundation) |

## Scenario table

| Area | Scenario | Expected | Result | Evidence |
|------|----------|----------|--------|----------|
| Roles | Lead hands front to a rider; swap lead and sweeper; pack rider tries ROLE_SWAP | One LEAD; swap; 403 | verified | `ride_roles_355.test.js` test 1 |
| Roles | Owner demoted to PACK or SWEEPER keeps owner rights (route, end, roles) | `isLead()` checks owner first | verified | `convoys.js` `isLead`; `ride_roles_355` |
| Roles | Owner tries to move back while leading, with nobody else leading | 409 NEED_LEAD | verified | `sweeper.test.js` test 1 |
| Roles | Riding lead (non-owner) leaves or is removed | Owner takes LEAD; riders told | **fixed (D1)** | `safety_review_355` test 1 |
| Roles | Sweeper changes or leaves with BEHIND alerts open | Slots close as SWEEPER_CHANGED | verified | `timeline.js` `_checkSweeper`; `sweeper.test.js` |
| Roles | Incident notify / `_leadsAndSweeper` with owner demoted | Owner and new lead both notified (owner always included) | verified | `timeline.js` `_incidentNotify`, `_leadsAndSweeper` |
| Roles | Emergency roster or SMS plan with owner demoted | Owner listed as "lead" (rank 0) plus the real lead. Both texted first; no one lost | verified (label quirk, harmless) | `convoys.js` roster `rank`; `lib/domain/safety/sms_plan.dart` |
| Roles | Mesh packet role codec | LEAD=1, SWEEPER=2, else PACK, in 2 bits | verified | `lib/domain/mesh/mesh_packet_codec.dart:64,152` |
| Roles | Two-node mirror | RIDER_UPDATE replicates riders; meta (members, rolesChangedAt, autoRoles) replicates by delta; ROLE_CHANGE repeated to peer sockets | verified | `mirror.js` `_delta` |
| Roles | Split-brain merge (link down, roles changed on both nodes) | Roles follow the newer meta's side | risk-open | `mirror.js` `_mergeRider`. A rider who joined only on the older side keeps that side's role, so two LEADs are possible until the next change. |
| Roles | Reconnect merge in the app | My position stays local, my role comes from the server | verified | `convoy_service.dart` SNAPSHOT merge |
| Roles | 3.54 app in a 3.55 ride (receives LEAD, or owner demoted) | Old `canEditRoute` = creator or role LEAD (same rule); unknown ROLE_CHANGE ignored; old ROLE_SET SWEEPER/PACK follows the new plan | verified | `git show c83ba99:lib/data/services/convoy_service.dart` `canEditRoute` |
| Roles | Auto roles in a tight pack (under 150 m) | No flicker; hold 45 s; at most one change per 2 min | verified | `ride_roles_355` test 2 |
| Roles | Auto roles, rider dropping behind the sweeper | Sweeper kept; BEHIND_SWEEPER fires | **fixed (D2)** | `safety_review_355` test 2 |
| Roles | Auto roles, offline lead or sweeper | Role moves to fresh riders (sweeper kept while a distress alert is open) | verified / fixed (D2) | `timeline.js` `_checkAutoRoles` |
| Roles | Auto roles, rider off route (no projection) | Left out of the order; may lose LEAD | risk-open | Product: a lead on a detour hands over the front |
| Roles | Auto roles grant **lead rights** (end ride, change route) to whoever is at the front | Owner keeps rights; the front rider gets them too | **risk-open** | `convoys.js` `isLead`, `ws.js` TRIP_STATUS. Recommend: rights only for owner, head or a manually chosen lead. |
| Roles | Feature switch rideRoles/autoRoles off | Timeline stops auto roles; ROLE_SET LEAD / ROLE_SWAP / ROLE_AUTO on refused; turning off is always allowed | verified | `feature_flags.js` `wsFeaturesFor`; `feature_flags_355` |
| Road | Crash second reported as pothole | Never; crash alarm still opens | **fixed (D6)** | `road_places_355_test.dart` |
| Road | Road event while crash evaluation or alarm is open | None | **fixed (D6)** | `safety_service.dart` `_onAccel` |
| Road | Spam: jolt every second at 60 km/h for 10 min | At most about 3 per minute (20 s / 150 m spacing) | verified (31 events per 10 min, worst case) | pure-Dart run of `RoadSurfaceDetector` |
| Road | Only the riding lead of a joined, connected group ride reports; gateway re-checks lead or owner | 403 otherwise | verified | `convoy_service.dart` `reportRoadSurface`; `ws.js` ROAD_HAZARD |
| Road | Outbox ACK | ROAD_HAZARD_ACK clears by id, else the oldest sending item | verified | `convoy_service.dart` `_ackRoadHazard` |
| Road | Speech flood on receivers | Each warning spoken once per event at 50-350 m; saved ones only within 1.5 km | verified | `emergency_guidance.dart` road hazard loop |
| Road | Privacy of saved reports | No rider id; salted reporter and clearer keys; public view picks fields | verified / fixed (D3) | `road_and_places.js` `publicRoad`; `safety_review_355` test 3 |
| Road | "Fixed?" abuse | One vote per rider | **fixed (D3)** | `safety_review_355` test 3 |
| Road | Expiry | TTL by kind, renewed by new reports, purged by retention | verified | `road_and_places.js` `TTL_DAYS`; `retention.js` |
| Road | Two-node: live ROAD_HAZARD fan-out reaches only sockets on the receiving node | Riders on the peer node during a hand-back miss the live warning (saved report still served) | risk-open | `ws.js` ROAD_HAZARD (local `this.rooms`, no mirror relay) |
| Road | Gateway save path has no per-reporter save budget beyond the socket action budget | Bounded by app spacing and per-kind merge within 80 m | risk-open | `ws.js` ROAD_HAZARD save |
| Fuel | Tap during an in-flight detour (group route or another pump) | New pump marked; detour follows | **fixed (D11)** | `route_guide.dart` |
| Fuel | No signal or tunnel | Pump marked; retried every 30 s from fixes | verified | `route_guide.dart` `_checkFuelStop` |
| Fuel | Reached (60 m, or 150 m when slow) or passed (600 m beyond closest approach under 400 m) | Stop cleared, status reset, voice | verified | `route_guide.dart` `_checkFuelStop`; cockpit `_onFuelStopDone` |
| Fuel | Group plan changes mid-detour | Fuel stop kept and re-routed; group target dropped | verified | `route_guide.dart` plan change block |
| Fuel | Back on the plan before the pump | Detour not cancelled | verified | `route_guide.dart` `!_rejoin.isOff && _personalFuelStop == null` |
| Fuel | Route to group and fuel coexist | Group target first, then pump, then stops | verified | `_detourTail`, reroute waypoints |
| Fuel | fuelAutoRoute switch off | Pump shown, no detour | verified | cockpit `_autoRouteToFuel` |
| Alerts | Off-route, heritage, place-review, engine, role and swap cards vs SOS | SOS slot first (AlertArbiter); off-route and heritage hidden during SOS; place review never during any SOS (D10); engine tip never during emergency (D9) | verified / fixed | `live_cockpit_map_screen.dart` `_slots`; `ride_advisories.dart` `sosOpen` |
| Alerts | Voice during an open SOS | Role, swap and engine lines silent (D9); off-route and heritage silent (`sosOpen`) | **fixed (D9)** | `convoy_service.dart` `_say`; `safety_service.dart` |
| Alerts | Interaction while riding fast (off-route "Route to group", swap Accept/Decline, heritage "Add stop") | Cards need taps while moving | risk-open | Product: consider speed gating or voice-only while over 25 km/h |
| Swap | Pillion swap keeps pair integrity | New driver `isCoRiding=false`; new pillion `ridingWithUserId` = new driver | verified | `ride_swap_355.test.js`; `convoys.js` `answerSwap` |
| Swap | Phone and emergency contact follow the person | Only vehicle and co-ride fields swap; profile re-applied on re-join | verified | `convoys.js` `answerSwap`, join `rideVehicle` |
| Swap | Expiry, rate limit (4 per 10 min), one pending per pair, target-only answer, ride ended | 404 / 409 / 403 | verified | `ride_swap_355.test.js` |
| Swap | Requester and target on different nodes (hand-back) | Pending ask lives on the requester's node; the answer on the other node gets SWAP_EXPIRED | risk-open | `convoys.js` `requestSwap` (in-memory, documented) |
| Swap | `rideVehicle` 'PILLION' persists if co-riding later ends | Re-join keeps the 'PILLION' vehicle | risk-open (minor) | `convoys.js` join |
| Switches | Locked ids (sos, crashDetection, emergencySms, medicalId) | Never stored off; app always on | verified | `feature_flags.js` `cleanStored`/`isOn`; app `lockedIds`; `feature_flags_355` |
| Switches | DB outage or unknown id | Last known state or defaults ON | verified | `feature_flags.js` `refresh`; app `isOnIn` |
| Switches | SOS, crash, emergency SMS, check-in, report-down paths | No switch gates them (WS types not in `WS_FEATURE`) | verified | `feature_flags.js` `wsFeaturesFor` |
| Switches | Handlebar remote SOS | Never gated | **fixed (D7)** | `ble_remote_service.dart` |
| Switches | Offline mesh SOS beacon and relay | Never gated | **fixed (D8)** | `p2p_mesh_service.dart` |
| Switches | Admin-only, reason required, audit, WS push, peer poke | Yes | verified | `feature_flags.js` routes; `feature_flags_355` |
| Switches | A switch turned back ON while a phone was offline | Phone keeps it off until GET /features (resume, sign-in, 10 min); no push on connect when nothing is off | risk-open (non-safety features only) | `ws.js` HELLO; app `refresh` |
| Plans | Leftover of an earlier account shadows a new plan | New plan shown; leftover retired | **fixed (D4)** | `safety_review_355` test 4 |
| Plans | `belongsToAccount` with missing or odd createdAt | Missing or non-numeric means "belongs" (keeps the plan) | verified | `entitlements.js` `belongsToAccount` |
| Plans | Unattended orphan purge on a bad read | Nothing deleted | **fixed (D5)** | `safety_review_355` test 5 |
| Plans | Capacity change in a live ride | Capacity only grows; nobody removed mid-ride | verified | `convoys.js` `_currentCapacity` |
| Plans | Legacy tier vs assigned plan | Legacy tier ended when a plan is assigned | verified | `plans_cleanup_355.test.js` |
| Guest | Saved guest session at app start | Cleared once, with the message | verified | `lib/data/services/auth_service.dart` load |
| Guest | Guest mid-ride (old token) | Gateway 401 SESSION_INVALID with message (every build signs out); `/auth/guest` 410 | verified | `auth.js` `UserGate`, `me`, `loginAsGuest` |
| Guest | Signed-out rider and phone emergency calling | Lock-screen emergency call and OS Medical ID are OS features, untouched by the app; no regression found | verified (by inspection) | n/a |
| Security | New REST/WS inputs validated (roles, swap ids, road payload, reviews, photos, bike fields, switch ids) | Yes | verified | `validate.js` `bikeFields`/`roleOf`; `convoys.js` `SWAP_ID`; `road_and_places.js` |
| Security | Admin routes guarded | `requireAdmin` on `/admin/features`, `/admin/place-reviews`; enumeration test passes | verified | full suite |
| Security | Public endpoints (impact stats, road hazards, reviews) leak no PII | Counts under 10 hidden or rounded; first name only; no rider ids | verified | `public_privacy.js` `safeImpact`; `road_and_places.js` `reviewView` |
| Security | Review photos | Max 2 MB, image types only, shown after admin approval, owner-only before that | verified | `road_and_places.js` photo routes |

## Still pending / not yet stable

- **Needs real-device validation (sensor thresholds).** Pothole at 1.1 g dynamic, rough road at std 0.35 g for 6 of 10 s, phone in a pocket vs on a handlebar mount, Indian rural roads. Expect false positives on mounts. The spacing (20 s / 150 m) caps the rate at about 3 per minute but not the precision. Also check the new `isCrashLike()` thresholds against recorded crash and pothole traces.
- **BLE remote (D7) and mesh SOS-only (D8)** need on-device checks: triple press and 2.5 s hold with the `bleRemote` switch off; an SOS beacon over the UDP mesh with `offlineMesh` off.
- **OCI two-node drills**: split brain with role changes on both nodes, hand-back during a pending swap, live road warnings while sockets are split across nodes.
- **Product decisions to confirm.** ~~Auto roles grant full lead rights to the front rider~~ resolved after this review: an automatic lead has no lead rights (gateway `isLead`, app `canEditRoute`; test `ride_roles_355`). Off-route voice no longer asks a moving rider to tap. Off-route, swap and heritage cards need taps while moving. A lead going off route hands over the front under auto roles.
- **Known flaky test**: `public_ride_mirror` "two nodes ... road warnings replicate" (flaky on baseline too). It failed once in the full run, then failed once and passed once when run alone.
- Flutter widget and service tests cannot run here (no engine). Fixes D7-D11 are checked by the analyzer and by reading only. D6's core logic was also run as pure Dart.

## Test results (end state)

- `dart analyze lib test`: **No issues found!**
- Gateway full suite (`npm test`): **767 / 767 pass** in the final run (the `public_ride_mirror` test is timing-sensitive and can flake).
- New: `gateway/test/safety_review_355.test.js` (5 tests). All 5 fail on HEAD sources and pass with the fixes.
- New Dart test case in `test/road_places_355_test.dart` (crash slide is never a pothole).
