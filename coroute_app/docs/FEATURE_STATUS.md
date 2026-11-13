# CoRoute feature status (as of v3.55 code, Nov 9, 2026; latest round: push notifications, crew ride invites, own domain)

To release: paste [DEPLOY_PROMPT_v3.55.md](DEPLOY_PROMPT_v3.55.md) into the owner's coding agent (the primary, self-contained deployment prompt).

Status legend:

- **Stable (code)**: implemented, analyzer clean, covered by gateway tests and/or pure-logic tests. Still needs the normal phone check before release.
- **Needs device check**: implemented, but correctness depends on sensors, radios, OS behaviour or real roads that cannot be tested here.
- **Pending**: planned, not built yet.
- **Not stable**: known open risk (see notes).

Admin switch: the id in Admin > Feature switches (`gateway/src/feature_flags.js`). "Locked" = can never be switched off.

## Safety (every rider, Community included)

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| SOS (hold, durable delivery, SMS fallback, lock screen) | Stable (code) · Needs device check | `sos` (locked) | No switch or plan can disable it; BLE remote SOS gestures and mesh SOS keep working even when their switches are off. |
| Crash detection (incl. slow traffic, false-positive suppression) | Needs device check | `crashDetection` (locked) | Road-surface detection never runs during a crash evaluation (3.55 fix D6). |
| Emergency texts / roster | Stable (code) | `emergencySms` (locked) | |
| Medical ID on lock screen | Stable (code) | `medicalId` (locked) | |
| Medical info to responders (owner decision Nov 9) | Stable (code) · Needs device check | `medicalId` (locked) | No consent switch ("Share with a rider who comes to help" removed; a stored `responderMedical` from old apps is ignored). When entered, it is on the lock screen and goes to responders only while the rider's SOS or crash alert is open: the ride group, guardians (blood group, allergies, notes on the guardian link) and a rider from another group who accepted to help (also the emergency contact name and phone). Profile note: "Shown to responders in an emergency and on your lock screen." Tests: gateway `net_privacy`, `guardians`, Dart `medical_profile_test`. |
| Guardian live link | Stable (code) | `guardianLink` | During an open alert the link also shows the rider's medical info (Nov 9). Sharing the whole group: Trip owner or a Lead the owner picked (the trip head changes settings only). |
| Nearby riders assistance network | Stable (code) | `assistNetwork` | **Always on since Nov 11** (owner decision): "Help nearby riders" and "Ask nearby riders to help me" have no switch; the app writes `assistHelp` / `assistAsk` back on (`PATCH /me`) when the gateway still has one off, unless `assistNetwork` is off. Shares the emergency text path. The request carries no name or medical info; after a rider accepts, they get the first name, bike, medical info and emergency contact while the alert is open. |
| Pre-ride phone check ("Safety health") | Stable (code) · Needs device check | — | Nov 11: the cockpit tile and Settings › Safety › Safety health open it (they opened Settings). Fix buttons open the specific system page (notifications, the app's battery page for background use, battery optimisation, full-screen alarm, sound); new native `openNotificationSettings` / `openAppBatterySettings` need a check on Pixel, Samsung, Xiaomi. |
| Siren detector | Needs device check | `sirenDetector` | Rebuilt in 3.55 on the shared ride mic (wail / yelp / hi-lo, alert only after 2.5 s of continuous siren, ambulance / police / fire engine named when confident, approaching / moving away, nearness, give-way line). For riders who cannot hear outside (Nov 9). See the v3.55 sound section below. |
| Handlebar BLE remote | Needs device check | `bleRemote` | Switch off stops talk and hazard marking only, never SOS. |
| Offline phone-to-phone mesh | Needs device check | `offlineMesh` | Switch off = SOS-only mode. |
| Road hazards from the lead (pothole, speed breaker, rough road) — new 3.55 | Needs device check | `roadHazards` | Thresholds need real-road tuning (mount vs pocket). |
| Saved road reports for later rides — new 3.55 | Stable (code) | `roadHistory` | No rider ids stored; expiry by kind; "Fixed?" counts once per rider. |
| Engine rest advice from bike details — new 3.55 | Stable (code) | `engineCare` | Rules of thumb, not a temperature reading. |
| Fuel range, warnings and auto-route to fuel (stabilised in 3.55) | Stable (code) · Needs device check | `fuelAutoRoute` | Offline retry and arrival detection need a real ride. |

## Riding and groups

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Live group map, regroup, spread / behind-sweeper alerts | Stable (code) | — | |
| Riding roles Lead / Middle / Sweeper, swap, position prompts — new 3.55 | Stable (code) | `rideRoles` | Owner keeps rights; leader leaving hands the lead back to the owner. Naming (Nov 9): **Trip owner** = created the group/trip; **Trip head** = secondary owner for that one trip who can change the trip's group settings only (owner decision, Nov 9: no removing riders, no ending the trip, no pause / roles / stops; choosing a trip head no longer makes them Lead; gateway `canChangeSettings`); **Lead** = riding role at the front who guides (with Middle and Sweeper). A Lead the owner picked may change settings and pause / resume, not end the trip. Manage-riders sheet explains each role in one line. Test `ride_roles_355`. |
| Automatic roles (front leads, last sweeps) — new 3.55 | Stable (code) · Needs OCI two-node drill | `autoRoles` | Off by default; automatic lead has no management rights. Two-lead split fixed (Nov 9): only the node that owns the room computes automatic roles (single writer), and any merged state with two LEADs keeps the earlier lead (`fixDoubleLead`). Test `ride_roles_355`; confirm in the failover drill. |
| Off-route "Route to group" prompt — new 3.55 | Stable (code) · Needs device check | `offRouteGroupPrompt` | Speak while moving, act when stopped (Nov 9): while moving one line ("You're off the route. Stop when safe to route to your group.") and a chip; the buttons show when stopped (≤ 3 km/h for 5 s; a pillion can always tap). Same gate for the swap ask, historic place and place review cards (`RideTapGate`). |
| Bike / rider-pillion swap — new 3.55 | Stable (code) · Needs OCI two-node drill | `vehicleSwap` | Pending asks are stored in the ride meta (`pendingSwaps`) and replicated, so they survive a restart or failover (Nov 9); cleared when the ride ends. Test `ride_swap_355`. While moving, the ask is a voice line + chip; Accept / Decline show when stopped. |
| Bike markers, bike shapes, mandatory bike details, pillion seat — new 3.55 | Stable (code) · Needs device check | `pillionSeat` | One bike marker per bike (type shape in the bike colour, two people with a pillion); garage bike type picker; complete bike details before riding as a rider (never for SOS, never mid-ride; old apps only marked incomplete); the pillion confirms the bike (HELLO `pillion2`, `PILLION_SEAT` / `PILLION_UNSEAT`), the rider may decline within 60 s. See [features_355/bike_markers_pillion.md](features_355/bike_markers_pillion.md). Tests `pillion_seat_355`, `bike_markers_garage_355_test`. |
| Push-to-talk intercom | Needs device check | `intercom` | |
| Group fuel sharing | Stable (code) | `groupFuel` | |
| Public ride, safe contact, road warnings from oncoming riders | Stable (code) | `publicRide` | |
| Nearby group discovery | Stable (code) | `discovery` | |
| Trip report, replay, ride analytics | Stable (code) | `rideAnalytics` | |
| Weather on the route | Stable (code) | `weather` | |

## Places

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Map places (fuel by type, hospitals, mechanics, food, stays…) — medium icons in 3.55 | Stable (code) | `mapPlaces` | Emergency hospitals stay visible even when switched off. |
| Route essentials | Stable (code) | `essentials` | |
| Historic places on the way — new 3.55 | Stable (code) | `heritagePlaces` | OSM coverage varies. |
| CoRoute rider place reviews (dwell prompt, stars, photo, map badge, moderation) — new 3.55 | Stable (code) · Needs device check (post-ride sheet) | `placeReviews`, `reviewPrompt` | Photos shown after admin approval. After the ride ends, places not answered in the cockpit are asked about on the "Ride ended" screen / a sheet after the trip review (at most 2, skippable; `placeReviews` + `reviewPrompt`). |

## Plans, admin, website

| Feature | Status | Notes |
|---|---|---|
| Community free / Small Group / Large Group, prorated upgrades, coupons | Stable (code) | |
| Upgrade only while a paid plan runs (owner decision Nov 9 late) | Stable (code) | Enforced on the gateway (`409 DOWNGRADE_NOT_ALLOWED` on quote, validate-coupon, order, activate-free and purchase); shown on the website only (3.56: the app sells nothing). Admin "Change plan" exempt. Test `plans_v2`. |
| Play payments policy: the app is consumption-only — new 3.56 (owner decision Nov 10) | Stable (code) · Needs device check | No payment SDK (Razorpay removed), no prices or buying words, no steering to the website in the app, notifications or store listing. Read-only "Your plan" card (plan name, what it includes, status, end date, "Your plan is managed in your CoRoute account."); neutral gate texts (`PlanGateMessages`); neutral `SUBSCRIPTION_*` pushes; admin payments / coupons / pricing / revenue / Marketing removed from the app (staff note row "Payments, coupons and marketing are managed in the web admin."). Coupon QR into the app (`/get`, `coroute://get`, Install Referrer) removed. A website purchase unlocks at once (socket / push -> `fetchMyMembership`). Scan: `dart tool/play_policy_scan.dart` = 0 hits. See [play_payments_policy.md](features_355/play_payments_policy.md). Tests: Dart `your_plan_card_test`, gateway `play_policy_push_355`. |
| One plan per group ride (owner decision Nov 9) | Stable (code) | One member with a plan hosts; others join free with the code and get the host's group features for that ride (`/api/membership/my` effective entitlements while on a hosted PLANNING / STARTED / PAUSED ride). Test `membership_plans`. |
| Admin "Change plan" gives a real membership — fixed in 3.55 | Stable (code) | Run "Reconcile" once after deploy. |
| Data cleanup removes memberships — fixed in 3.55 | Stable (code) | Mass-deletion guard in the daily purge. |
| Guest mode | Removed in 3.55 | Old guest sessions signed out with a message. |
| Admin feature switches — new 3.55 | Stable (code) | Locked safety ids. |
| Website: live usage + impact numbers, iOS coming soon, all pages redesigned — 3.55 | Stable (code) | Sections stay hidden until numbers pass the privacy floor (10). |
| iPhone app | Pending | TestFlight, then set the App Store URL; website switches automatically. |
| Play Store listing | Pending | Then set `PLAY_STORE_URL`. |

## v3.55 plan features built in phase 2 (Nov 8, 2026)

All are code-complete, analyzer clean, with pure-logic tests (and gateway tests where the server is involved). Every one has an admin switch. Details, thresholds and device checks: [features_355/](features_355/).

| Feature | Status | Admin switch | Doc |
|---|---|---|---|
| Sharp-bend warning | Needs device check | `bendWarning` | road_context.md |
| Smart speed limits (OSM maxspeed, school/hospital zones) | Needs device check (OSM coverage patchy) | `speedLimits` | road_context.md |
| High-altitude care | Needs device check (GPS altitude) | `altitudeCare` | road_context.md |
| Night riding care | Stable (code) | `nightCare` | road_context.md |
| Adaptive fatigue score | Needs device check | `fatigueScore` | sensor_safety.md |
| Rider-down check (bike falls when stopped) | Needs device check | `riderDown` | sensor_safety.md |
| Crash detection that learns from "I'm OK" (severe path never learns) | Needs device check | `crashLearning` | sensor_safety.md |
| Phone-mount check | Needs device check | `mountCheck` | sensor_safety.md |
| SOS battery reserve (<10 %) | Stable (code) · Needs device check | `sosBatteryReserve` | sensor_safety.md |
| Private ride safety report | Stable (code) | `safetyReport` | sensor_safety.md |
| Solo check-in by ETA | Needs device check (SMS in background on Play builds) | `soloCheckIn` | solo_guardian.md |
| No-signal ahead (own coverage log) | Needs device check | `noSignalAhead` | solo_guardian.md |
| Arrival message to guardians (link expires) | Stable (code) | `arrivalMessage` | solo_guardian.md |
| Help from public riders (consent) | Stable (code) | `publicRiderHelp` | solo_guardian.md |
| Start and arrival roll call | Stable (code) | `rollCall` | solo_guardian.md |
| Missing-rider check (I'm OK / Need help + red "Send SOS · hold to send", 1.5 s hold, Nov 9) | Needs device check | `missingRiderCheck` | group_safety.md |
| Group stretch alert (lead threshold) | Stable (code) | `stretchAlert` | group_safety.md |
| Smart regroup point | Stable (code) | `regroupSuggest` | group_safety.md |
| Group break planner (levels only) | Stable (code) | `groupBreak` | group_safety.md |
| Buddy pairs (7+ riders) | Stable (code) | `buddyPairs` | group_safety.md |
| Risky-stretch heads-up (k ≥ 10 riders) | Stable (code) | `riskyStretch` | group_safety.md |
| Admin warnings delivered to riders (Warn text box, ≤ 280 characters, guidelines line as a quick option, Nov 9) | Stable (code) | `adminWarnings` | platform.md |
| Offline crash-incident queue | Retired (duplicate of the pending-SOS store, which already resends offline SOS once) | — | platform.md |
| Voice-command / siren services at start-up | No longer started at launch (no audio source). Siren detection now runs only during a ride, on the shared ride mic (see the v3.55 sound section) | — | platform.md |

## Round 4 road & safety intelligence (Nov 12, 2026, build 10026)

| Feature | Status | Admin switch | Doc |
|---|---|---|---|
| Help make roads safer (opt-in consent, trimming, k-anonymity, delete / export) | Built (code + tests) | env `INTEL_ENABLED`, `INTEL_KILL` | docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md |
| Hazard ahead warning (hotspots) | Built, needs device check | `hazardAhead` | same |
| Rough road ahead (potholes) | Built, needs device check | `roughRoadAhead` | same |
| Twisty section ahead, twisty km in the ride report | Built, needs device check | `twistyAhead` | same |
| Long ride and night nudges, lead's group break | Built, needs device check | `longRideNudges` | same |
| Falling-behind alert + regroup at learned stops | Built, needs 2-phone check | `fallingBehind` (+ `regroupSuggest`) | same |
| Rider stops, no-fuel gap warning in planning | Built | — | same |
| ETA based on riders | Built (shows once data exists) | — | same |
| Dangerous times + pre-ride tip (no weather) | Built | `hazardAhead` | same |
| Crash brain | Built, **shadow** (`CRASH_BRAIN_MODE`) | — | same |
| Valhalla motorcycle routing | Prepared (A1 only) | env `ROUTER_KIND` | gateway/deploy/valhalla/README.md |

## v3.55 sound, calls and live settings (Nov 9, 2026)

Third round of 3.55 work: what the rider hears with music and calls, the lock screen, siren alerts (horn alerts were removed), a cleaner intercom voice, and settings that apply in the middle of a ride. Details: [features_355/audio_and_calls.md](features_355/audio_and_calls.md), [features_355/sound_awareness_and_intercom.md](features_355/sound_awareness_and_intercom.md), [SETTINGS_LIVE_AUDIT_v3.55.md](SETTINGS_LIVE_AUDIT_v3.55.md).

Honest baseline for this whole section: the Dart code is analyzer-checked and the pure logic and DSP were run with plain `dart`. The Flutter widget and service tests could not run here (no engine), and **the Kotlin changes (`TtsChannel.kt`, `MediaVolumeGuard.kt`, `PhoneCallChannel.kt`, `RideNotification.kt`, `MainActivity.kt`, manifest, notification layout) have not been compiled** (no Android SDK here). Every audio row needs a phone.

### Settings that apply live mid-ride

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Speed warning uses the stricter of the group limit and my own limit, re-checked at once on any change | Stable (code) | — (`speedLimits` for map limits) | `effectiveSpeedLimit()`; also used by the cockpit chip and the lock-screen line. Tests: `settings_live_355_test.dart`, gateway `config_live_355.test.js`. |
| Town / near-stop limit applied on the rider's own phone | Stable (code) · Needs device check | — | `groupLimitAt()`, same 1 km rule as the gateway. Check near a planned stop on a real ride. |
| Quick settings rows follow the state (Voice, Battery saver, Screen on) | Stable (code) | — | The sheet now listens; a second tap no longer repeats the same change. |
| Voice off then on keeps hands-free armed | Stable (code) | `intercom` | VOX re-armed on unmute if it was armed before. |
| Queued voice lines dropped when warnings or group voice are turned off | Stable (code) | — | P0 / P1 lines are never dropped. Lines already inside the Android speech engine: audio round, needs device check. |
| Break reminder switch respected mid-ride | Stable (code) | `fatigueScore` | Fix: the 2-hour rule spoke even with the reminder off. |
| Solo ETA check-in re-arms when switched back on | Stable (code) | `soloCheckIn` | Same fix for the admin switch. |
| Data saver change mid-ride (intercom rate, skipped weather / map save) | Stable (code) · Needs device check | — | Short mic re-open during hands-free talk; check there is no audible gap. |
| Group setting sliders send once, on release | Stable (code) | — | `ReleaseSlider`; repeated taps within 1.5 s no longer send the same change twice. Optimistic value with a 6 s re-read. |
| Offline group-policy change tells the lead it was not sent | Stable (code) | — | Before: dropped without a word. |
| Bike colour and model update live for the group (`RIDER_VEHICLE`) | Stable (code) · Needs device check | `riderVehicleLive` | One update per rider per 10 s; refused for a pillion or after a bike swap; this ride only (never the profile). Older apps and gateways are unaffected (HELLO feature `vehicle1`). Tests: `rider_vehicle_355.test.js`, `rider_vehicle_355_test.dart`. |
| Fuel type and learned mileage follow a mid-ride bike change | Stable (code) | — | `FuelEconomyService.useBike()`. |
| Crash detection switched off during a countdown | Stable (code) · Needs device check | `crashDetection` (locked) | The running alarm continues (never cancelled behind the rider) and says: "Crash detection is off for new alarms. This alarm is still running: tap I'm OK to cancel it." New alarms stop at once. |
| Admin `intercom` off during a held talk ends the talk | Stable (code) · Needs device check | `intercom` | Stream ends, mic closes, VOX leaves. |
| Admin `sirenDetector` off releases the audio duck | Stable (code) · Needs device check | `sirenDetector` | |

### Music, alerts and phone calls

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| CoRoute alerts lower other apps' music (duck), or pause it with "Pause music during alerts" | Needs device check | — | One duck per burst of lines; music back about 0.7 s after the last line. Check Spotify, YouTube Music, JioSaavn. |
| Critical lines (SOS, crash countdown, rider down, siren close, "Are you OK?", 40 %+ over the limit) pause music; alarm stream on the speaker, media speech in the headset when one is connected | Needs device check | — (never muted by settings) | Speaker: heard even at media volume 0, and through Do Not Disturb when the rider allows CoRoute DND access. Headset (helmet set, ANC earbuds, wired): played in the headset only (not the speaker), media volume raised to at least 60 % for the line. |
| Lower music when speeding (10 % over → 60 %, 25 % → 30 %, 40 % → paused; back 5 s after riding 3 km/h under) | Needs device check | `speedAudio` | Setting in Settings > Voice & sound, default on. Stops touching the volume if the rider changes it; restores at once on ride end, SOS, crash alarm, switch off or 15 s without a GPS fix; restores after an app kill. Check Bluetooth absolute-volume phones. **Nov 10 fix (owner: "not working"):** uses the strictest of the group, personal and **road / school / hospital zone** limit (it ignored road limits, and group / personal are 0 by default), works on offline solo rides, applies the lowering after an overspeed line that was playing (it used to give up), and falls back to ducking / pausing by audio focus when the volume cannot be set (fixed-volume device, DND, ignoring headset). Diagnostics in logcat. |
| Speech latency (alert decision → sound) | Needs device check | — | **Nov 10 (owner: "alerts are so late"):** engine warmed at ride start (was: on the first alert, and re-started during solo rides), offline low-latency voice, siren lines and "Slow down." pre-synthesised (start ~0.1 s), earcon for other P0-P2 lines, priority preemption (a hazard no longer waits behind a group line). See features_355/alert_latency.md "Speech output". |
| Calls: ordinary lines held and summarised after the call; critical lines get a short tone and phrase in the call audio | Needs device check | `callAwareAlerts` | Caller does not hear the phrase (stock Android; some OEMs may drop it, buzz and heads-up remain). After the call: "Safety alert during your call: …" then "While you were on the call: 2 road warnings, Asha fell behind." Switch off = 3.54 behaviour. |
| Ringing: ordinary lines wait; critical lines play in full on the alarm stream | Needs device check | `callAwareAlerts` | Some phones never report ringing; then the call is seen when it connects. |
| Hands-free talk comes back after a call | Needs device check | `intercom` | Mic released during the call, re-opened after. |
| Speech engine missing or failing: tone + vibration, heads-up for critical lines | Stable (code) · Needs device check | — | New channel **Critical ride alerts**. |

### Lock screen

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Ride notification shows speed (rounded to 5), limit, next warning ahead and intercom state | Stable (code) · Needs device check | — | e.g. "55 km/h · limit 60 · Warning in 1.2 km · Receiving Asha". No position or private data. |
| Talk on/off and Mute/Unmute buttons on the ride notification, usable without unlocking | Needs device check | `intercom` | Android 14: microphone foreground service started from a notification action must be checked. Talk never opens the mic outside a ride or with the intercom switched off. |
| Critical alerts over the lock screen (another rider's SOS full screen) | Needs device check | — | Android 14+ may deny full-screen intents; a heads-up shows instead. |
| New channels: `coroute_critical_alerts`, `coroute_sos_v2` (alarm sound, insistent, bypass DND) | Needs device check | — | `coroute_sos_v2` replaces `coroute_sos`. DND bypass only after the rider allows CoRoute DND access. |

### Sirens and the intercom voice

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| One shared ride microphone for detection and intercom | Needs device check | — | Opens only while needed. Detection always records from the **phone's built-in mic** (raw `mic` source, no SCO), even with earbuds or a helmet set connected (Nov 9). Hands-free talk with a headset also uses the phone mic, cleaned in software, so detection keeps working (weaker voice than the helmet mic); push-to-talk uses the helmet mic only while held (detection skips those frames). Released during calls, at < 15 % battery (detection only), and when switches go off. Lock-screen capture needs the foreground service with the microphone type. |
| Emergency-vehicle siren alerts (wail, yelp, hi-lo incl. Indian hi-lo; approaching / moving away; nearness; "Keep left and give way") | Needs device check | `sirenDetector` | **Purpose (Nov 9): riders who cannot hear outside** (ANC earbuds, helmet set, music). Rider can't hear outside (headset connected, music, intercom playing or a call): the line is spoken in the earbuds / helmet, music pauses, vibration, card, lock-screen heads-up. Rider can hear (phone speaker, no music): card + vibration + one tone. "Tell my group" removed. **Owner report round (Nov 10):** alert only after the siren sounded **continuously for 2.5 s** (gaps ≤ 0.4 s), so chirps, honks, musical truck horns, reversing beepers, ringtones and temple music never alert; the kind is said when confident ("Ambulance siren close by. Keep left and give way.", "Police approaching. ...", "Fire engine ..."; else "Emergency vehicle ..."): hi-lo = ambulance, yelp / wail-yelp = police, slow low wail = fire engine, electronic wail alone = generic; the phone's own sound on its speaker is ignored; an approaching siren re-alerts once per 30 s. Synthetic results: alert 2.8–3.1 s after the siren starts (13 dB under the ride noise; 3.8–5.1 s at 19 dB under), right kind in all 17 cases, 0 false alerts in 22 negative cases and 20 min of mixed audio. Give-way side from the setting "Give way to the" (Automatic uses the phone's country). **Never claims "behind"** (one mic has no direction). Setting **Siren alerts** (Settings › Ride, on by default; owner decision Nov 9 late): off releases the mic at once. |
| Horn alerts | **Removed** (owner, Nov 10) | — (admin switch `hornAlert` removed) | Detector, setting, cockpit horn card and admin switch removed; the stored setting is deleted at start-up. The mic opens only for sirens and the intercom. |
| False alarms in synthetic tests | Stable (code), lab only | — | 0 siren alerts over 20 min of mixed negative audio (engines, clipping wind, speech, chords, musical truck horns, beepers, ringtones, temple music, rain with honking) and the single-noise tests. Real roads not yet tried. |
| Intercom voice cleanup (wind/engine high-pass, noise suppression, breath suppression, voice gate, AGC + limiter) | Needs device check | `voiceCleanup` | Setting "Clean up my voice", default on. Synthetic: breath −30 dB, wind gusts −34.5 dB, steady riding noise −24 to −25 dB with speech −0.7 dB; the hands-free gate opened on 0 frames of breath, wind or hiss. Added latency 12 ms. |
| Receive-side limiter (one loud rider does not blast) | Stable (code) | — | No added latency. |

Known limits (by design or physics): a phone in a pocket at speed may not hear a siren (mount or tank bag is best); helmet / earbud mics are never used for detection; "can't hear outside" is a best guess from the phone's audio state (an open-face helmet with no earphones counts as "can hear"); call-only (HFP) helmet sets get critical lines on the phone speaker; an 11 Hz "phaser" is not detected; two sirens at once take longer and stay generic; music on the phone's own speaker pauses detection while it plays; the trend ("approaching") needs about 4 s; screen-off haptics may not vibrate on some phones (the spoken alert works); the DSP runs on the UI isolate (a few % of one core expected).

Naming note: the siren card says "AMBULANCE SIREN · GIVE WAY" (or POLICE / FIRE ENGINE when confident, else "EMERGENCY VEHICLE SIREN · GIVE WAY"): one phone mic cannot tell direction, so nothing says "behind".

### Speed accuracy (Nov 9)

Owner report: bike speedometer 86, app 79–80 with a limit of 80. Finding: the app was not under-reading; motorcycle speedometers over-read by law (UN ECE R39 / CMVR: up to 10 % + 4 km/h above the true speed, never below), so an indicated 86 is a true ~79–80. The limit check uses the true (GPS) speed, so no warning was correct. Details: [features_355/speed_accuracy.md](features_355/speed_accuracy.md).

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Speed estimator (`domain/tracking/speed_estimator.dart`): one number for cockpit, overspeed check, telemetry, track and crash detector | Stable (code) · Needs device check | — | Fixes 7 real defects: missing GPS (Doppler) speed read as 0; no outlier rejection; 1 Hz jitter (adaptive Kalman filter); frozen speed in poor-accuracy patches on route rides; distance filter while riding (now 0); battery-saver stopped band (4 s); no stop hysteresis (0 below 2.5 km/h, leaves 0 above 4). 11 tests in `speed_estimator_test.dart` (run with plain `dart`). Check against a GPS speed app on a real ride, and that the app reads a few km/h below the bike's speedometer. |
| "Speedometer offset" per bike (display only) | Declined by the owner (Nov 9): not built | — | Was proposed as an optional garage setting (e.g. +0 to +10 %) so the cockpit number matches the bike's speedometer; overspeed check, telemetry, reports and the gateway would keep the true GPS speed. Not built. |

### Taps while moving (Nov 9)

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Speak while moving, act when stopped (`RideTapGate`) | Stable (code) · Needs device check | per card (`offRouteGroupPrompt`, `vehicleSwap`, `heritagePlaces`, `reviewPrompt`) | Off-route, swap ask, historic place and place review: one voice line and a compact chip (no buttons) while moving; the full card with buttons when stopped (≤ 3 km/h for 5 s; moving again at 8 km/h). A pillion can always tap. Safety cards (SOS, crash alarm, rider down, siren, missing-rider check) are not affected. |

## v3.55 social, score, website, marketing, bikes (Nov 9)

Fourth round of 3.55 work: usernames, profiles and friends; crews with polls; the rider score and public leaderboards; all-time website numbers; the admin Marketing studio; bike markers, bike types, mandatory bike details and the pillion seat. Details: [features_355/usernames_friends_profiles.md](features_355/usernames_friends_profiles.md), [rider_score.md](features_355/rider_score.md), [crews_polls.md](features_355/crews_polls.md), [marketing_studio.md](features_355/marketing_studio.md), [bike_markers_pillion.md](features_355/bike_markers_pillion.md).

Honest baseline: the server logic is covered by new gateway tests (the docs agent re-ran the seven new suites, 65 / 65, and the full gateway suite, **878 / 878**, Nov 9). The app side has pure-Dart tests and was analyzer-checked by the feature agents; no Flutter engine or phone was available, so every screen, the map markers and the share / photo / deep-link flows still need a phone. All eight new switches are on by default and not locked.

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Automatic unique usernames (e.g. `SwiftFalcon482`; change once per 30 days; capitals-only change always allowed) | Stable (code) | — (core, no switch) | Allocated at sign-up, lazily at sign-in / `/me`, and by a startup backfill (job lease `username-backfill`; also `POST /api/admin/usernames/backfill`). Unique ignoring case via reservation documents (first insert wins on two nodes). Reserved words (admin, coroute, support, …, incl. `c0route`), profanity (English + Hindi) and contact-like names (7+ digits, e-mail providers) refused. Generated names never use the rider's real name. Tests: `usernames_friends_355`, Dart `username_rules_test`. |
| My profile (picture, username, full name, trips, km, riding hours, longest trip, largest group, rider score, bikes in garage, member since) | Stable (code) · Needs device check | — | Stats from stored trips, each group ride counted once (server trip wins over the phone copy), cached 2 min. Opened from the Profile tab top box (Nov 11); Edit details and Change password live here. Screen and live username availability check not run on a phone. |
| Profile pictures | Stable (code) · Needs device check | `profilePhotos` | Phone downsizes to 512 px JPEG; server checks magic bytes, ≤ 2 MB, ≤ 2048 px, strips EXIF / XMP / IPTC (no server re-encode). New random id per upload. Initials circle as fallback. Check camera / gallery picker and upload on a phone. |
| Friends (by username or personal invite link, mutual approval, blocks) | Stable (code) · Needs device check | `friends` (blocks keep working when off) | Non-friends see username + picture only; friends also see first name and totals (trips, km, hours, score). Never phone, e-mail, medical, location, guardian, plan or userId (tested on names and values). Blocks are silent (same answers as an unknown name; shadow requests). Limits 20 requests / day, 50 pending, 500 friends. Invite link `/join/friend/<CODE>` opens the app (App Links on `/join/`), or is remembered through sign-up. Check the link opens the app and the snackbar / system notice. |
| Crews (standing circle of friends; admin, up to 3 co-admins, members; invitation only, friends only; no chat) | Stable (code) · Needs device check | `crews` | Only mutual friends of the inviter; the friend must accept; no stranger search; non-members get the same 404 as an unknown crew; member rows carry username, first name, picture and role only. Limits: 100 riders, 10 crews run / 30 joined, invites last 14 days. Admin hands over or the oldest co-admin / member takes over. Admin console "Crews" moderation (audited). "Start a ride with this crew": see the crew ride invites row below. Tests: `crews_polls_355`, Dart `crews_polls_355_test`. |
| Crew polls (single or multiple choice, named or anonymous, deadline 10 min–30 days, "Ride date" template) | Stable (code) · Needs device check | `crewPolls` | Polls are the only thing members post. Vote, change or remove until it closes; results live by push (never who voted in the push). Members start polls only if the crew setting allows. Check invite → accept → vote across 2–3 phones. |
| Rider score (private 0–100: speed discipline 40, smoothness 25, safety habits 25, regular riding 10; levels Learner / Steady / Skilled / Ace Rider (renamed from Road Captain by the owner; an older gateway's "Road Captain" shows as Ace Rider); after 3 rides of 10 km+) | Stable (code) | `riderScore` | Never rewards speed (speeds above the limit are only penalised, speeds are not even stored); SOS, crash alarms, "Bike down?", hard stops, signal loss and night riding are never read. Capped at 70 while speed discipline is unmeasured. Phone sends only five counts per ride; always on since Nov 11 (owner decision, no switch; for a rider who had it off, rides before the change are never sent). Recent rides weigh more (60-day half-life); daily recompute job. Tests: `rider_score_355` (11), Dart `rider_score_355_test`. Score screen and profile card need a phone look. |
| Public leaderboards (Top score, Longest ride, Most km, Most hours, Most rides; username only; opt-out) | Stable (code) · Needs device check | `leaderboard` | Riders appear after 3 rides of 10 km+, with a username and "Show my username on public leaderboards" on (default on; off hides them at the next 5-min cache refresh). Rounded totals, never userId, real name, place, date or ride. Implausible rides (> 2000 km, > 150 km/h average) never count publicly. In the app (Trips header) and on the website `/leaderboard` + home section (hidden until a board has a rider). Test: `website_leaderboard_355`. |
| Website all-time totals (riders on the road, hours on the road, km, rides, group rides, largest group, longest trip, bikes, safety tiles, "This week" line) | Stable (code) · Needs device check (layout on real phones) | `communityStatsWebsite` (existing; off hides the section) | `GET /api/public/alltime-stats`: one node computes the totals every 5 min into one document (`public_stats_alltime`), every node serves it (60 s memory). Same floors as the impact numbers: counts below 10 read 0, rounded down. Riders = registered riders with at least one completed ride; hours = moving time added up. Test: `public_stats_alltime_355`. Screenshots checked at phone, mid and desktop widths, light and dark (sample data). |
| Marketing studio (admin: coupon offer images, starter templates, layers, QR code, Share PNG / all sizes with caption) | Removed from the app in 3.56 (web admin only) | `marketingStudio` (group Platform) | Admin-only; every route `requireAdmin` first. Binds ACTIVE / SCHEDULED coupons live (`{code}`, `{discount}`, `{validUntil}`, …); coupon view never carries usages or rider ids. Images: JPEG / PNG / WebP ≤ 2 MB, metadata stripped. QR encoder checked against a reference encoder. Editor and painter not run on a device (Flutter); save to gallery goes through the share sheet; the QR link applies the code in the app (row "Coupon QR / link" above). Test: `marketing_templates_355`. |
| Bike markers on the ride map (bike shape by type, bike colour, ring / status / role cues, faces travel direction) | Needs device check (marker legibility) | `riderVehicleLive` (existing; colour updates) | Eight original silhouettes (Commuter, Scooter, Sport, Cruiser, Adventure / Tourer, Off-road, Electric, Cafe racer / Retro), same in garage and map; cached per type / colour / size. Rendered to SVG at 24 and 64 px for a visual check only; check legibility in sunlight, dark map and at 10+ riders. |
| Bike types in the garage (type picker with shapes, guessed from the model) | Stable (code) · Needs device check | — | The guess only pre-selects; the rider confirms. Unknown names draw as Commuter. |
| Bike details mandatory before riding ("Complete your bike" on create / join; EV rules) | Stable (code) · Needs device check | — | Make and model, type, colour always; engine 50–2500 cc, tank 2–40 L, mileage 5–120 km/L for fuel bikes; electric: no engine or tank, mileage 2–25 km/kWh, battery optional. Never for SOS, never mid-ride, never locks the app; closing the sheet only cancels that create / join. Older apps are not refused (`bikeComplete: false`). |
| Pillion seat (pillion picks the bike and confirms; everyone is told; rider can decline for 60 s; one marker with two riders) | Stable (code) · Needs device check | `pillionSeat` (off: old `CORIDER` link, separate markers) | HELLO `pillion2`, `PILLION_SEAT` / `PILLION_UNSEAT`, events `PILLION_SEATED` / `PILLION_UNSEATED` (reasons DECLINED, REMOVED, PILLION_LEFT, RIDER_LEFT, MOVED). The pillion's phone keeps crash detection, SOS and fall checks unchanged; group safety counts the bike once (missing-rider check, spread, break planner, timeline). Test: `pillion_seat_355`, Dart `bike_markers_garage_355_test`. Check the flow on 2–3 phones. |
| Pillion pair: one answer counts for both (missing-rider check) | Stable (code) · Needs device check | `pillionSeat`, `missingRiderCheck` | Owner decision (Nov 9). If the rider or the seated pillion answers "Are you OK?" (I'm OK, a stop reason, Need help or SOS), the check closes on both phones and the lead gets one notice at most; an answer older than the current stop does not count. Gateway: no second `NO_REPLY` for the bike partner; an OK closes the partner's `NO_REPLY` too. Each phone still asks its own question and keeps crash detection / SOS. Tests: `pillion_seat_355`, Dart `group_safety_355_test`, `pillion_group_safety_355_test`. Details: [bike_markers_pillion.md](features_355/bike_markers_pillion.md). |

## v3.55 latest round (Nov 9): push notifications, crew ride invites, own domain

Details: [features_355/push_notifications.md](features_355/push_notifications.md), [crews_polls.md](features_355/crews_polls.md) ("Crew rides"), [DOMAIN_MIGRATION_devmonks.md](DOMAIN_MIGRATION_devmonks.md). Gateway suite after this round (docs agent, Nov 9): **904 / 904**. Dart pure tests `push_routing_355_test`, `crew_ride_invites_355_test`, `gateway_hosts_test` (not run with `flutter test`); the new Kotlin (`PushChannel.kt`, `CoRouteMessagingService.kt`) has never been compiled.

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Push notifications when CoRoute is closed (friend request / accepted, crew invite, new poll, ride invite) | Stable (code) · Needs device check · Needs owner setup | `pushNotifications` (Platform) | FCM HTTP v1, data-only messages naming the other rider by username only (no phone, e-mail, location, medical, userId; tested). Pushed only when no live socket got the event; ride invites always. Up to 5 tokens per rider; removed on sign-out, switch off, account erase and dead-token answers. Settings › Account & privacy › **Push notifications** (default on, shown only when the build has the Firebase values). Needs the owner's Firebase project: 4 client values as build properties `COROUTE_FCM_*`, service account JSON as server secret `FCM_SERVICE_ACCOUNT_JSON` (Vault). Without them nothing breaks (in-app notices only). Gateway test `push_355`. |
| Crew ride invites ("Start a ride" / "Invite crew to my ride"; Ride invitation screen with Accept / Decline) | Stable (code) · Needs device check | `crewRides` (Community; also needs `crews`) | Any crew member who is the trip owner of a live ride can invite chosen members (picker with "Select all", statuses Waiting / Joined / Declined / Expired). The invitee gets a high-priority push ("<username> invited you to <ride> with <crew>") and the **Ride invitation** screen (host, crew, ride, start → destination names, riders, Accept / Decline). Accept runs the normal join: profile check, permissions, **Complete your bike** or pillion pick, pre-ride checklist; seats follow the host's plan (`SOLO_TRIP_ONLY`, `RIDE_FULL`); no join code in any push; invites expire after 12 h or at ride end. The trip head cannot invite. Gateway test `crew_ride_invites_355`, Dart `crew_ride_invites_355_test`. |
| Own domain `coroute.devmonks.space` with DuckDNS fallback | Stable (code) · Needs owner setup (DNS, DLT, Razorpay, Play Console) · Needs device check | — | Gateway `PUBLIC_ORIGIN` builds every link; `LEGACY_ORIGINS` (DuckDNS) served in full; optional `REDIRECT_LEGACY_HOST` (website pages only, off). App default host is the new name with an automatic fallback to DuckDNS (build **without** `COROUTE_API`); App Links on both hosts; Caddy serves both names (certificate via the `_acme-challenge` CNAME). Keep DuckDNS at least 6 months. Tests `domain_migration`, Dart `gateway_hosts_test`. Hygiene: the DuckDNS token is in plain text in `gateway/deploy/setup_new_vm.sh`: rotate it and keep it only in Vault. |

## Small follow-ups (Nov 9, late)

| Fix | Status | Admin switch | Notes |
|---|---|---|---|
| After-ride place review list survives an app restart | Stable (code) · Needs device check | `placeReviews`, `reviewPrompt` | The unanswered after-ride places (at most 2, ride id, place id / name / category / position, stay, kept 7 days) are stored in shared preferences (`place_review_after_ride_v1`, `PendingPlaceReviews` in `ride_end_reviews.dart`) while the ride goes on and at its end, restored on start, asked once on the next app open (not during a ride or an SOS), and shown on the trip report (Summary tab) of that ride. Rate or Skip removes them. Tests: `after_ride_reviews_persist_test` (pure part run with a Dart shim; service part analyzer-checked). |
| One notice across two servers (socket + push) | Stable (code) · Needs device check | `pushNotifications` | Push now treats a rider connected to the OTHER node as connected (mirror `LU` carries every signed-in socket, `mirror.userOnPeer`). Socket message and push carry the same `eventId` (`push.stampEvent`); the app shows one notice per id in 10 min (`NoticeDedupe`; background system notifications cannot be deduped, accepted). Tests: gateway `push_two_node_355` (3), updated `crew_ride_invites_355`; Dart `notice_dedupe_355_test`. Details: [push_notifications.md](features_355/push_notifications.md). |
| Admin and replay maps: a seated pillion rides on the two-up bike | Stable (code) · Needs device check | `pillionSeat` | Admin convoy inspector and master admin fleet map use the cockpit plan (`BikeMarkerPlan.forViewer`); the replay merges a pillion within 150 m of their rider using the ride snapshot the phone holds. Finished rides the phone no longer holds and the trip report's Route tab still show one marker per rider (tracks carry no pillion links). Test: `bike_markers_viewer_355_test`. |
| Commuter, electric and retro tell apart at 57 px | Needs device check (sunlight, dark map) | — | New top-down marks: commuter carrier rack + slim tank + flat seat; electric cyan flank strips, nose bar and hub motor, no engine / exhaust; retro chrome-ring round headlight, twin round mirrors, chrome tank strip, wide bench with tan stitching. Map + garage assets regenerated (1.07 MB in all). `tool/map_bikes/preview.mjs --mode types`. Details: [bike_markers_pillion.md](features_355/bike_markers_pillion.md). |

## v3.55 diagnostics logs (Nov 10)

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Persistent app log on the phone (JSON lines, 7 days / 20 MB, gzip, crash-safe append, privacy redaction, debug level behind "Detailed logs" for 24 h) | Stable (code) · Needs device check | — | `lib/domain/diag/*`, `lib/data/services/diag_log_service.dart`. Instrumented: ride start/end, battery, permissions, GPS 30 s summary, speed outliers, overspeed decisions, alert pipeline (AudioDiagLog bridge), crash detector candidates / drops / alarm open-cancel-send, SOS raise / send / ack / cancel / SMS fallback, siren, intercom, socket, push, friends / ride invites, API errors, lifecycle, Flutter / zone / isolate errors. Tests: Dart `diag_log_355_test`. |
| Native crash + main-thread stall capture (Kotlin `CrashLog`) | Needs device check | — | Written to `files/diag/native_crashes.jsonl`, merged at the next start. |
| Diagnostics (Profile › Help › Send feedback › View diagnostics since Nov 11; send, share file, viewer of the last 500 entries with category filter, clear) | Stable (code) · Needs device check | — | "Send safety logs automatically" default off; "Detailed logs" for admins / 7 taps. |
| Post-ride safety prompt ("send the log of this ride?") after SOS / crash alarm / false-alarm cancel | Needs device check | — | Never during a ride; once per ride. |
| Gateway upload `POST /api/me/diagnostics` (gzip ≤ 5 MB, 5/day, server-side PII strip, 30-day retention, deleted with the account) and admin viewer / download / "Ask for logs" with audit | Stable (code) | `diagnosticsUpload` | `gateway/src/diag_logs.js`; tests `diagnostics_355`. Storage: Object Storage with `DIAG_LOG_STORE=par` (+ `DIAG_LOG_PAR_URL` or the review photo PAR), else database chunks. |
| Request ids on every gateway response and 5xx error logging with the request id | Stable (code) | — | Server log locations and pull commands: [features_355/diagnostics_logs.md](features_355/diagnostics_logs.md#server-logs). |
| Log summary tool `tool/diag/analyze_logs.js` | Stable (code) | — | Alert latencies, false-alarm reasons, socket drops, errors by count. |

## Minimal Profile and fixed defaults (Nov 11, owner direction)

| Feature | Status | Admin switch | Notes |
|---|---|---|---|
| Profile tab, minimal: top box (picture, name, @username → My profile; gear → Settings), My bikes, Emergency contact & Medical ID, rider score + Leaderboard, Help (Send feedback, Rate CoRoute, Privacy & terms), Account (Sign out, Delete account) | Stable (code) · Needs device check | `leaderboard` (row), `riderScore` (card), `profilePhotos` (picture) | No plan, no ride history, no separate report / suggest rows. Change password and Edit details moved to My profile. Test `profile_minimal_test`. |
| Send feedback: one screen (Report a problem · Suggest a safety feature · Other), optional "Attach diagnostics log", "View diagnostics" link | Stable (code) · Needs device check | — | `POST /me/feedback` topics `bug` / `idea` / `other`; the log uses the Diagnostics upload. Replaces Report a problem, Suggest a safety feature and the old Send feedback screen. |
| Plan screen removed from rider entry points | Stable (code) | — | Profile row, home chip tap, membership push and features guide link removed; the admin console keeps "Rider view of Your plan". Server capability logic unchanged. |
| Fixed defaults with no Settings row: help / ask nearby riders (on), give-way side (Automatic), safety report in my score (on), offline maps (automatic); Rate / Feedback / Diagnostics rows removed from Settings | Stable (code) | — | Settings migration v2 (`settings_safety_defaults_version` = 2). Website privacy, privacy-and-security, safety, how-it-works and terms texts updated. docs/SETTINGS_MINIMAL_v3.55.md. |
| Automatic offline maps with retention: trip map saved at ride start, kept 7 days after the trip, 30 days if the trip never ended, 300 MB cap (LRU), ride in progress never deleted; past trips use online tiles with a cached fallback | Stable (code) · Needs device check | — | `OfflineMapRetention` (pure) + `OfflineMapRetentionService` (sweep at start and after each ride). Offline map manager screen removed. Test `offline_map_retention_test`. |

## Still pending (cannot be done in code here)

- Flutter `flutter test` + Gradle release build; real-device rides for every "Needs device check" row.
- **Kotlin / Gradle build of the 3.55 native audio changes** (`TtsChannel.kt`, new `MediaVolumeGuard.kt`, `PhoneCallChannel.kt`, `RideNotification.kt`, new `PushChannel.kt` and `CoRouteMessagingService.kt`, `MainActivity.kt`, manifest, `ride_notif_expanded.xml`, Firebase Gradle dependencies): never compiled here. Build once and fix any compile errors before device tests.
- **Audio device checks** (2–4 phones, one with a Bluetooth helmet set): duck vs pause with Spotify / YouTube Music / JioSaavn; critical lines at media volume 0 and in DND (after granting DND access); "Lower music when speeding" steps and restore, incl. Bluetooth absolute volume; call-aware alerts (phrase heard in the call, not by the caller; post-call summary; ringing detection without READ_PHONE_STATE); lock-screen Talk / Mute on Android 14; full-screen SOS vs heads-up; siren detection with the phone on a mount, in a tank bag and in a pocket at 40–60 km/h (and 80 km/h), and with ANC earbuds + music (line in the earbuds only, not the speaker); helmet set mic routing (detection on the built-in mic, push-to-talk on the helmet mic while held, hands-free on the phone mic); siren kinds (ambulance hi-lo, police yelp, fire) and musical truck horns / beepers not alerting; speech latency and music lowering from the audio diagnostics (`adb logcat -s CoRouteAudio flutter`); speed against a GPS speed app; hold "Send SOS" on the missing-rider card; chips while moving and the full card when stopped; hands-free gate against breath and wind at 60–100 km/h; mic indicator off within a second when detection switches go off; hands-free back after a call. Full list: [NEXT_AGENT_PROMPT_v3.55.md](NEXT_AGENT_PROMPT_v3.55.md).
- OCI two-VM deploy, failure drills, 30-min soak test (sets the live-rider cap), monthly restore test.
- Move review photos and APKs to Object Storage (code exists; settings only — steps in features_355/platform.md).
- Rotate the leaked JWT secret and DB password (runbook in features_355/platform.md; use a short 24–72 h grace window).
- Own domain `coroute.devmonks.space`: code ready; owner adds the DNS A record and `_acme-challenge` CNAME, DLT URL whitelisting, Razorpay webhook, Play Console URLs (`DOMAIN_MIGRATION_devmonks.md`). Rotate the DuckDNS token (plain text in `setup_new_vm.sh`) into Vault. Play Store listing; iPhone stays "coming soon".
- Firebase project for push notifications (owner): 4 client values for the build, service account JSON in Vault (`push_notifications.md`).
- **Latest round device checks**: crew ride invite push with the app killed → Ride invitation screen → Accept → Complete your bike / pillion → joined; push for friend / crew / poll with the app killed, token refresh, sign-out stops pushes; pillion pair one answer for both; trip head settings-only; domain fallback (block the new host → app uses DuckDNS); invite links open the app on both hosts.
- OCI two-node drill for the Nov 9 failover fixes (pending swap asks survive a failover; one lead after a split).
- **Round 4 (social, score, website, marketing, bikes) device checks**: bike marker legibility (sun, dark map, 10+ riders, two-rider bike), "Complete your bike" on create / join, pillion seat flow on 2–3 phones, profile photo upload, friend invite link opens the app, crew invite + poll, Marketing studio export / share. After deploy run the username backfill once (`POST /api/admin/usernames/backfill`). Website leaderboards stay hidden until riders pass the 3-ride rule.
- Gateway suite: **904 / 904** in the docs agent's run after the latest round (Nov 9). Before that: **878 / 878** in the docs agent's run after round 4 (Nov 9; the earlier `route.test.js` and `job_lease` failures did not reproduce). Earlier note, kept for history: Gateway suite Nov 9: 810 / 812. Fix `route.test.js` "trip planned on the map" (denied `STOP_ACCEPT` now returns `reason: 'NOT_LEAD'`, the test expects none); `job_lease` two-node timer test is timing-sensitive.

Decided by the owner and built on Nov 9 (no longer open): sirens for riders who can't hear outside (horn alerts removed Nov 10) ("Tell my group" removed); medical info without a consent switch; missing-rider "Send SOS"; taps while moving; one host plan per group ride; Trip owner / Trip head / Lead naming; admin Warn text box; place review after the ride; swap asks across a failover and the two-lead split; latest round: trip head = settings only, top rider score level "Ace Rider", pillion pair one answer for both, own domain `coroute.devmonks.space`, emergency contact to an accepted outside helper = yes, speedometer offset = no, website "riders" definition = OK. See [V3_55_RELEASE.md](V3_55_RELEASE.md) "Owner decisions, Nov 9".

Product decisions still open:
- **When to turn on `REDIRECT_LEGACY_HOST`** (not before the minimum build covers the first new-host build; DuckDNS stays served at least 6 months).
- **HSTS raise** on `coroute.devmonks.space` (300 s → 1 year) after the domain checks pass.
- ~~Credit beyond the plan price~~: decided Nov 9 late. Downgrades are blocked, so upgrade credit is capped at the new price and nothing is carried over.
- Smaller wording items in [UX_NAMING_GUIDE_v3.55.md](UX_NAMING_GUIDE_v3.55.md) §4 (e.g. emergency button casing, "trip" vs "ride").
