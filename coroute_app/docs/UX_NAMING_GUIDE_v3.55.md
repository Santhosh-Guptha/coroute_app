# CoRoute v3.55: UX naming guide and wording review

Scope: the Flutter rider app and admin console (`lib/`). Baseline commit `c83ba99`.
Analyzer after the changes: `dart analyze lib test` → **No issues found!**
Widget tests can't run in this environment. Every test expectation that pointed at a changed string has been updated to match (listed below).

---

## 1. Conventions

| Topic | Rule | Notes |
|---|---|---|
| Screen titles, sheet titles, dialog titles | **Sentence case** ("Edit profile", "Payments & plan history", "Offline map packs") | Most `DsScreenHeader` / `AppBar` titles already use it. Proper nouns keep their capitals: CoRoute, Ride Guardian, SOS, Small Group, Large Group, Community. |
| Section headers | Write them in sentence case in the source; `DsSectionHeader` makes them upper case (`AppText.overline`) | Don't put ALL-CAPS literals in a section header. Write `DsSectionHeader('Riding role')`, not `Text('RIDING ROLE', style: AppText.overline)`. |
| Chips / badges | Upper case is fine (DsChip upper-cases them anyway): LEAD, SWEEPER, ACTIVE PLAN, ENDED | |
| Buttons | Short verb phrases in sentence case, 48 dp or taller: "Add bike", "Save changes", "Record service", "Search again", "Rate this place", "Update rating" | Exception, kept for now: the emergency buttons ("Need Help", "I Can Help", "Can't Assist", "Unable to Assist", "View Emergency"). See §4. |
| Units | `km`, `m`, `km/h`, `km/L`, `L`, `cc`. Never "Km", "KM", "Kms" or "KM/H" | Spoken text says "kilometers"/"meters" (the TTS strings and tests use US spelling). |
| Spelling | Indian/British English in written UI: colour, refuelling, metres in written text | |
| Ellipsis | "…" (one character) in loading text: "Searching…" | |
| Plain language | No internal terms: FEAT-02, telemetry, mesh, detour fetch, bottleneck, kill switch | "via Mesh" now reads "via Bluetooth". "Bottleneck rider" now reads "A rider is low on fuel". |

## 2. Glossary: one name per concept

| Concept | Name in the UI | Don't use | Where it shows |
|---|---|---|---|
| Riding position, front | **Lead** (the first rider in the convoy, who guides the others; mid-sentence "the lead") | Road Captain, Point, "LEAD (POINT)", leader, the Lead mid-sentence, "the lead" for who manages the trip | rider card (chip, Riding role segment), manage-riders badges, cockpit pills, RoleNotice, feature guide, admin (`adminRoleLabel`) |
| Riding position, middle | **Middle** | Pack, Rider (as a role badge) | `RideRole.label`, rider card segment, manage-riders badge, admin role label |
| Riding position, back | **Sweeper** | Sweep, SWEEP | everywhere above, plus the compact cockpit roster tag |
| The three of them together | **Riding roles** ("Riding role" for one rider); **Automatic roles** for the auto switch | "Lead and Sweep" | group settings, rider card, feature guide ("Riding roles"), plan benefits |
| The person who created the group/trip (governance) | **Trip owner** (badge TRIP OWNER, compact tag OWNER; sentence text "the trip owner") | Ride owner, host (as a noun), creator, organiser | manage-riders sheet, cockpit roster, admin ride lists ("trip owner Asha"), "Start or join" |
| A secondary owner for one trip who can change the trip's settings only (owner decision, Nov 9) | **Trip head** (badge TRIP HEAD, compact tag HEAD; sentence text "the trip head"; explanation "Trip head: can change the trip's settings. Only the trip owner removes riders or ends the trip.") | Trip Head mid-sentence, co-owner, route manager, "same rights as the trip owner" | manage-riders sheet; group settings ("Only the trip owner or trip head can change these.", "Trip head can change the trip's settings.") |
| Who changes the group settings, in sentences | **the trip owner or trip head** ("The trip owner or trip head decides." for the public ride) | "the lead" (the Lead is a riding position) | group settings, public ride, feature guide limit / feature hints |
| Who runs the ride on the road (stops, route, pause, roles, regroup, buddy pairs, Guardian group links) | **the trip owner or the Lead** ("Suggestion sent to the trip owner and the Lead.", "The trip owner or the Lead decides whether to add the stop.", "Skipped by the trip owner or the Lead.") | "the trip owner or trip head" (the trip head has settings only) | stop suggestions, meet here, trip report, Guardian group consent, automatic roles subtitle |
| Ending the trip, removing riders | **the trip owner** ("Only the trip owner can end the trip.", "Only the trip owner can remove riders.") | trip head, Lead | gateway errors, End Ride button (trip owner only) |
| The people in a ride | **group** / **group ride** | convoy (in UI text) | "Group spread", "Pause group ride", "Manage riders", "Your group" (SOS hold), "joined the ride / left the ride" |
| Free plan | **Community (free)** (short form "Community") | No plan, Solo plan, Free plan | membership, payment history, admin |
| Paid plans | **Small Group (2–6)**, **Large Group (7–12)** | Group (2–6), Group Membership (N Riders Capacity), Extended Group | membership card title, `UserMembership.name`, payment history, admin |
| Retired plans | **Legacy plan (CoRoute Pro / Road Captain / Tour Operator / Individual)** for riders; "Legacy: …" in admin | Individual Solo, "CoRoute Pro (legacy)" | payment history, owned-plan card |
| Plans screen | **Membership & plans** | CoRoute Membership & Plans, Membership & Plans | app bar, Account section header |
| Plan checkout | **Plan payment** | Membership Payment | payment screen app bar |
| Bike list screen | **Garage**; a bike is a **bike**; the Account section is **My bikes** | GARAGE & MOTORCYCLES, Add Motorcycle, My bike & Garage | garage screen, add/edit sheet ("Add bike" / "Edit bike"), Account, Ride start row ("Garage · My bikes & service") |
| Fuel place | **Fuel station** (unnamed fallback "Petrol pump") | Petrol bunk, petrol station, "Petrol Pump" | cockpit fuel sheets, fuel pills, low-range dialog. "petrol bunk" stays only as a voice hotword. |
| Group or personal refuel stop | **Fuel stop** | | snackbars, voice |
| Road surface kinds | **Pothole**, **Speed breaker**, **Rough road**; generic **Road hazard** ("Severe road hazard" when critical) | CAUTION: ROAD SURFACE ANOMALY, CRITICAL ROAD HAZARD | `RoadHazardHudPill`, `RoadSurfaceText` |
| Heritage POI | **Historic place** (map filter: **Historic places**) | Heritage | place card, map filter chip, cockpit slot "Historic place on your way" |
| Place ratings | **CoRoute rider reviews** (place card section); **Place reviews** (admin screen); actions **Rate this place** / **Update rating** | "CoRoute riders" as a heading, "Update your rating" | place card, review sheet, admin |
| Admin kill switches | **Feature switches** (screen title); nav item stays **Features** (one-word nav) | | admin features screen |
| Live link for family | **Ride Guardian** (feature), **Guardian link** (the link) | Ride Guardian Live Share | cockpit settings card, group settings, feature guide |
| Emergency | **SOS** (always upper case) | Sos, S.O.S | everywhere |
| Swaps | **Swap bikes**; **Change places (rider and pillion)** | Swap rider and pillion | rider card; matches the swap notices ("wants to change places", "changed places") |
| Off the group's route | "You left the group's route" → **Route to group** / **Ask group to wait** / **Keep my own route** | Continue my way | cockpit slot |

## 2b. Round 3 (Nov 9): new names for sound, calls and the lock screen

New rider-facing labels and phrases from the audio, mic and live-settings work. Use them exactly; the manuals use the same words.

### Settings > Voice & sound (rows hide when their admin switch is off)

| Label | Subtitle / choices | Setting key | Admin switch |
|---|---|---|---|
| **Speak warnings and directions** (existing) | "… Emergency alerts are always spoken." | `voiceWarnings` | — |
| **Pause music during alerts** (existing) | ordinary lines pause music instead of lowering it | `pauseOtherAudio` | — |
| **Lower music when speeding** | "Well over the speed limit, music gets quieter, then pauses. Back under the limit, it comes back. CoRoute alerts and the intercom stay loud." | `lowerMusicWhenSpeeding` | `speedAudio` |
| **Siren alerts** | "Warns you about ambulance, police and fire sirens, even when your earphones block outside sound. Listens on your phone during rides only. Nothing is recorded or sent." | `sirenAlerts` | `sirenDetector` |
| **Give way to the** | Automatic / Left / Right. "The side the siren alert tells you to keep to." | `giveWaySide` | `sirenDetector` |
| **Clean up my voice** | "Takes out breathing, wind and engine noise before the group hears you." | `voiceCleanup` | `voiceCleanup` |

### Spoken phrases

| Situation | Phrase |
|---|---|
| Siren close by (trend not yet known) | "Ambulance siren close by. Keep left and give way." / "Police siren close by. ..." / "Fire engine siren close by. ..." when the kind is clear, else "Emergency vehicle siren close by. Keep left and give way." (right-hand-traffic countries or setting Right: "Keep right") |
| Siren getting louder | "Ambulance approaching. Keep left and give way." (or Police / Fire engine / Emergency vehicle) |
| Far siren | "Ambulance siren in the distance." (or ... / "Emergency vehicle siren in the distance.") |
| Same siren clearly closer | "Ambulance getting closer. Keep left and give way." (or ... / "Emergency vehicle getting closer. ...") |
| Far over the limit | "Slow down. 95 km/h, limit 65." |
| After a call, critical | "Safety alert during your call: …" (+ "And 2 more safety alerts.") |
| After a call, ordinary | "While you were on the call: 2 road warnings, Asha fell behind." |
| Mic permission missing (said once) | "Siren alerts need the microphone. Allow it for CoRoute in phone settings to use them." |
| Crash detection turned off during a countdown (screen + notification) | "Crash detection is off for new alarms. This alarm is still running: tap I'm OK to cancel it." |

### Lock screen and notifications

| Item | Text |
|---|---|
| Ride notification line | "55 km/h · limit 60 · Warning in 1.2 km · Receiving Asha"; over the limit: "70 km/h (over 60)" |
| Intercom states | **Talking**, **Receiving** (name), **Group voice muted**, **Hands-free on**, **Voice paused (call)** |
| Buttons | SOS, **Talk** / **Talk off**, **Mute** / **Unmute**, Leave |
| Notification channels (Android settings) | **Critical ride alerts** (new), SOS (new id `coroute_sos_v2`) |

### Naming rules for this area

- Say **close by** or **approaching**, never **behind**, for sirens: one phone microphone cannot tell direction.
- A siren's kind (Ambulance / Police / Fire engine) is said only when the detector is confident; otherwise **Emergency vehicle**. Cockpit card: "AMBULANCE SIREN · GIVE WAY" / "EMERGENCY VEHICLE SIREN · GIVE WAY".
- Horn alerts were removed in 3.55 (no setting, card, phrase or admin switch).
- "Music" in rider text means any other app's audio. "Lower" = quieter, "pause" = stopped; don't use "duck" in UI text.
- Admin-only names (feature switches): "Lower music when speeding", "Calls: hold ride voice, let critical alerts through", "Intercom voice cleanup: noise, wind and breath", "Live bike change", "Siren detector".

## 2c. Round 4 (Nov 9): social, rider score, leaderboards, marketing and pillion

New rider-facing names from usernames / friends / crews, the rider score, the leaderboards, the Marketing studio and the pillion seat. The manuals use the same words.

### Glossary additions

| Concept | Name in the UI | Don't use | Where it shows |
|---|---|---|---|
| A standing circle of riding friends, outside a ride | **Crew** / **Crews** ("Create a crew", "My crews", "Join crew", "Leave crew", "Delete crew") | group, club, community (in UI text: "group" is the live ride, "Small Group" / "Large Group" are plans) | Crews screen, crew screen, profile row "Crews" |
| The rider who runs a crew | **Crew admin** (badge ADMIN on the crew screen) | owner, leader, host, Trip owner (that is a ride role) | crew screen, "You will be the crew admin." |
| Helpers of the crew admin (up to 3) | **Co-admin** (badge CO-ADMIN; actions "Make co-admin" / "Make member") | moderator, deputy | crew screen, member actions |
| Everyone else in a crew | **Member** (badge MEMBER) | follower, rider (as a crew role) | crew screen |
| A crew vote | **Poll** ("New poll", "Start poll", "Close poll", "Save my vote", "Remove my vote", "Who voted", "Closes in …") | survey, vote (as the noun for the whole thing), chat, comment | crew screen |
| Public rider name | **Username** ("Your username", "Change username", "@SwiftFalcon482" on rider cards) | handle, nickname, display name, ID | My profile, friends, crews, leaderboards, ride rider card |
| Mutual connection between riders | **Friends** ("Add a friend", "Send request", "Wants to be friends", "Accept" / "Decline", "Remove friend", "Block …", "Invite friends to CoRoute") | followers, contacts, connections, buddies (Buddy pairs is a ride safety feature) | Friends screen, My profile |
| Personal invite | **Invite code** / invite link ("Ride with me on CoRoute") | referral code (that is a coupon), join code (that is a ride) | Friends screen, My profile |
| Private safety score | **Rider score** ("Your rider score", "How safely you ride, 0 to 100"); parts **Speed discipline**, **Smoothness**, **Safety habits**, **Regular riding** | safe score, safety rating, SafeScore, points (in the app) | score screen, profile card, Trips header |
| Inviting crew members to a live ride | **Start a ride** (crew screen; "Invite crew to my ride" while I run a live ride), **Ride invitation** (screen title, push title), "<username> invited you to <ride> with <crew>", **Accept** / **Decline**, picker "Select all", "Invite 3 riders", statuses **Waiting / Joined / Declined / Expired** | "Join code" in this flow (no code is shared), "crew ride request", "summon" | crew screen, ride invitation screen, push, host snackbar ("Asha accepted your ride invitation") |
| Rider score levels | **Learner** (under 50), **Steady** (50–69), **Skilled** (70–84), **Ace Rider** (85+) | Beginner, Expert, Pro, Lead (a riding position), Road Captain (a retired plan name) | score screen |
| Public ranking | **Leaderboard** / **Leaderboards**; boards **Top score**, **Longest ride**, **Most km**, **Most hours**, **Most rides** (website tab: "Top rider"); opt-out row **Show my username on public leaderboards** | ranking, hall of fame | leaderboard screen, website, My profile |
| Admin image creator | **Marketing studio** (actions "Make an offer image", "Share PNG", "Share all sizes", "Copy caption") | poster maker, banner tool, creative studio | admin console Sections, Coupons tab |
| Bike kinds | **Bike type**: Commuter, Scooter, Sport, Cruiser, Adventure / Tourer, Off-road / Dirt, Electric, Cafe racer / Retro | vehicle class, category | garage add / edit sheet, "Complete your bike" |
| Required bike details before a ride | **Complete your bike** ("Save and continue") | Bike verification, KYC, mandatory profile | create / join a ride, home prompt |

### Pillion phrases

| Situation | Text |
|---|---|
| Joining without a bike | "I'm riding pillion (no bike)" |
| Pillion pick sheet | Title "Whose bike are you on?"; confirm "You'll ride pillion on Asha's Royal Enfield Classic 350 (Red). Confirm?"; note "Your group sees one bike with two people. Your phone keeps its safety features on."; buttons **Confirm** / **Not now**; "I am not riding pillion" |
| No free bike | "No free bike in this ride right now. Ask your rider to join the ride first." |
| Everyone (card and spoken) | "Kiran is riding pillion with Asha." |
| The rider of the bike | "Kiran is riding pillion with you" + "Not right? Decline within a minute, or remove them later from their rider card." Buttons **Decline** (first 60 s), later **Remove pillion** on the rider card |
| The pillion | "You're riding pillion with Asha" + "Hold on. Your phone keeps its safety features on." |
| Declined / removed / rider left | "Asha declined you as pillion. Pick the bike you ride on." / "Asha removed you as pillion" / "Asha left the ride. Pick the bike you ride on." |
| Map label and screen reader | "Asha + Kiran"; "Asha, Classic 350, red, with pillion Kiran, 42 km/h, Riding"; on the pillion's phone "You, riding pillion with Asha" |

### Naming rules for this area

- **Crew** is never "group": "group" stays for the people in a live ride, and the plans are "Small Group" / "Large Group". The crew roles (Crew admin, Co-admin, Member) never reuse ride roles (Trip owner, Trip head, Lead).
- Show riders to each other by **username** (and the first name to friends only); never a full name, phone or e-mail outside the rider's own profile.
- The rider score never talks about speed as good: say "within the limit", never "fast" or "quick". The website says "pts" after the score; the app shows the number alone.
- Resolved (owner, Nov 9): the top rider score level is **Ace Rider** (was "Road Captain", which stays only as the retired plan name "Legacy plan (Road Captain)" and in the "Don't use" list for the Lead riding position). Gateway `rider_score.js` LEVELS, app `levelDescription` (an older gateway's "Road Captain" is shown as "Ace Rider").

## 2d. Latest round (Nov 9): crew ride invitations, push notifications, trip head, Ace Rider

The manuals use the same words.

### Crew ride invitation texts

| Where | Text |
|---|---|
| Crew screen button | **Start a ride** (no live ride); **Invite crew to my ride** (I run a live ride) |
| Picker sheet | Title "Invite <crew> to your ride"; note "Pick who to invite. They get a notification and join when they accept. Your join code is not shared."; row **Select all (n)**; button **Pick riders** / **Invite 1 rider** / **Invite 3 riders** (sending: "Sending..."); empty "No one else is in this crew yet." |
| Picker statuses | **Waiting** / **Joined** / **Declined** / **Expired** |
| Summary after sending | "2 invited · 1 no seat left" |
| Not the trip owner | "You are in a ride someone else started. Only its trip owner can invite riders." |
| Push (app closed) | Title **Ride invitation**; body "<username> invited you to <ride> with <crew>" (no crew: "<username> invited you to <ride>") |
| Banner (app open) | "<username> invited you to <ride> with <crew>" + **View** |
| Invitation screen | Title **Ride invitation**; host "Asha (@SwiftFalcon482)"; "invited you to ride with <crew>"; ride name (or "Group ride"); "Cubbon Park Gate → Nandi Hills" (or "To …" / "From …"); "Started 10:24"; "3 of 6 riders"; note "Joining shares your live location with this group while you ride, like any group ride."; buttons **Accept** (busy "Joining...") / **Decline** |
| Invitation states | "You accepted this invitation." / "You declined this invitation." / "The host took this invitation back." / "This invitation has expired." / "This ride invitation is not available." |
| Several waiting | Title **Ride invitations**; empty "No ride invitations waiting." |
| Host snackbar | "Asha accepted your ride invitation" / "Asha declined your ride invitation" |

Don't use: "join code" in this flow (no code is shared), "crew ride request", "summon", "Ride invite" as a visible title (say **Ride invitation**).

### Push notification texts (app closed)

| Event | Title | Body |
|---|---|---|
| Friend request | Friend request | "<username> sent you a friend request" |
| Friend accepted | New friend | "<username> accepted your friend request" |
| Crew invite | Crew invite | "<username> invited you to the crew <crew>" |
| New poll | New poll in <crew> | "<username> asks: <question>" |
| Ride invitation | Ride invitation | "<username> invited you to <ride> with <crew>" |

Setting: Settings › Account & privacy › **Push notifications**, subtitle "Friend requests, crew invites, polls and ride invites when CoRoute is closed. Usernames only, never your location." Android channels: **Friends** and **Ride invites**. Never name a rider by full name, phone or e-mail in a push.

Note for a later gateway pass (not changed here, `gateway/src` was out of scope): `push.js` still has a fallback `RIDE_INVITE` template titled "Ride invite" ("… invited you to a ride: <ride>"). Crew ride invites send their own text ("Ride invitation"), so riders see the right title; align the fallback when `push.js` is next touched.

### Trip head: settings only

- Explanation line (manage-riders sheet): "Trip head: can change the trip's settings. Only the trip owner removes riders or ends the trip."
- In sentences: who changes **settings** = "the trip owner or trip head"; who **runs the ride on the road** (stops, route, pause, roles, regroup, buddy pairs, Guardian group links) = "the trip owner or the Lead"; who **ends the trip / removes riders** = "the trip owner" only.
- Choosing a trip head does **not** make them Lead and does not move the riding roles. Never write "trip head (lead)" or imply the trip head guides the ride.
- Errors: "Only the Trip owner can end the trip." / "Only the Trip owner can remove riders." / "Only the Trip owner or Lead can change the trip state." Crew ride invites: only the trip owner invites (the trip head cannot).

### Rider score levels

**Learner** (under 50), **Steady** (50–69), **Skilled** (70–84), **Ace Rider** (85+). "Road Captain" is only the retired plan name ("Legacy plan (Road Captain)").

### Pillion pair, one answer

Manual / help wording: "If you or your pillion answers “Are you OK?”, it counts for both of you." No new app string.

## 3. Changes made (file → before → after)

### Ride / cockpit
| File | Before | After |
|---|---|---|
| `presentation/ride/rider_card_sheet.dart` | `Text('RIDING ROLE', style: AppText.overline)` (×2) | `Semantics(header) DsSectionHeader('Riding role')` |
| 〃 | Role snackbar for yourself: "You will be told to move to the front." | "You are now Lead: ride at the front when it is safe." For another rider: "Asha is now Lead and will be told to move to the front." |
| 〃 | "Swap roles with me" showed even when both riders had the same role, and gave no feedback when it worked | Hidden when the roles match. Snackbar: "Swapping roles with Asha. You will both be told where to ride." |
| 〃 | Swap rider and pillion | Change places (rider and pillion) |
| `presentation/ride/group_settings_sheet.dart` | "Off: you set roles from a rider's card." | "Off: the lead sets roles from each rider's card." |
| 〃 | Guardian subtitle didn't say when the admin switch was off (the button just went grey) | "Guardian links: turned off for now." / "Guardian links are turned off for this group." |
| `presentation/rider/live_cockpit_map_screen.dart` | Petrol Bunks Near You / NEARBY PETROL STATIONS / Scan Nearby / Scanning... / No petrol bunks found… | Fuel stations near you / NEARBY FUEL STATIONS / Search again / Searching… / No fuel stations found within 25 km. |
| 〃 | "Select a station to navigate", "Verified fuel stations near current position" | "Tap a station to route there", "Mapped fuel stations around your position" |
| 〃 | "Fuel auto-route is turned off for now." | "Routing to fuel stations is turned off for now." |
| 〃 | No Reachable Station Ahead / "…exceed your estimated usable range… roadside emergency assist." | No reachable fuel station ahead / "Every mapped fuel station ahead is beyond your usable range (N km). Turn back to the last fuel station you passed, or call for roadside help." |
| 〃 | Refueling, "Petrol Pump" (×5) | Refuelling, "Petrol pump" |
| 〃 | Paused by Trip Head | Paused by the trip head |
| 〃 | Continue my way | Keep my own route |
| `presentation/rider/widgets/cockpit_action_stack.dart` | Low Fuel Alert / Petrol Bunks Near You / PETROL BUNKS NEAR YOU / Upcoming petrol bunks… / Scan Nearby / Locating verified petrol stations… / Manage Fuel Profile / Tap for bunks / Add Stop | Low fuel / Fuel stations near you / FUEL STATIONS NEAR YOU / Fuel stations ahead on your route or nearby / Search again / Finding fuel stations near you… / Fuel settings / Tap for fuel stations / Add stop |
| 〃 | " (via Mesh)", "Audio alerts safe", "Bottleneck rider needs fuel", "find the Lead", Refueling | " (via Bluetooth)", "Safety alerts still play", "A rider is low on fuel · Tap to find a station", "find the lead", Refuelling |
| `presentation/rider/widgets/road_hazard_hud_pill.dart` | CAUTION: CRITICAL ROAD HAZARD / CAUTION: SEVERE ROAD HAZARD / CAUTION: ROAD SURFACE ANOMALY; "300 meters ahead" | SEVERE ROAD HAZARD AHEAD / ROAD HAZARD AHEAD (kinds unchanged); "300 m ahead". The screen-reader label is in sentence case with "metres". "Fixed?" is now 48 dp tall and reads "Report this spot as fixed" to screen readers |
| `presentation/rider/widgets/minimal_cockpit_overlay.dart` | KM/H | km/h |
| `presentation/rider/widgets/minimal_cockpit_settings_cards.dart` | Convoy active / CONVOY SPREAD / Pause Convoy Ride / Resume Convoy Ride / SWEEP / Ride Guardian Live Share / "Live encrypted web tracking link…" | Group ride active / GROUP SPREAD / Pause group ride / Resume group ride / SWEEPER / Ride Guardian / "A private live link for family or friends" |
| `presentation/rider/widgets/rider_management_sheet.dart` | Manage Convoy Riders / CONVOY INVITE CODE / LEAD (POINT) / RIDER | Manage riders / INVITE CODE / LEAD / MIDDLE |
| `presentation/safety/sos_hold_screen.dart` | Convoy riders (…) | Your group (…) |
| `domain/notify/alert_policy.dart`, `domain/timeline/timeline_text.dart` | "X joined the convoy" / "X left the convoy" | "X joined the ride" / "X left the ride" |
| `domain/route/off_route_group.dart` | comments: "Continue my way" | "Keep my own route" (comments only) |

### Places
| File | Before | After |
|---|---|---|
| `presentation/map_places/place_card.dart` | heading "CoRoute riders" (could overflow next to the rating) | "CoRoute rider reviews", Flexible, one line with ellipsis, marked as a header |
| 〃 | Update your rating | Update rating (same as the review sheet) |
| `domain/places/poi_category.dart` | filter label "Heritage" | "Historic places" |

### Garage
| File | Before | After |
|---|---|---|
| `presentation/garage/garage_screen.dart` | App bar GARAGE & MOTORCYCLES; tooltip Add Motorcycle; empty state "No motorcycles…" / "Add motorcycle" | Garage; Add bike; "No bikes in your garage yet" / "Add bike" |
| 〃 | Bike subtitle "2024 · Make Model". The year was never entered by the rider (the sheet has no year field), so every bike showed the default year | "Make Model", or "Make and model not set" |
| 〃 | SERVICE OK / SERVICE OVERDUE / DUE IN N KM; Set Active; Record Service | Service OK / Service overdue / Service in N km; Set active; Record service |
| 〃 | Service dialog "Service Completed: X" / "Odometer reading at service:" / Confirm Service | "Record service: X" / "Odometer reading at the service" / Save service |
| 〃 | Sheet title ADD MOTORCYCLE / EDIT MOTORCYCLE; Bike Name; km/L; Current Odometer (km); SAVE TO GARAGE / SAVE CHANGES | Add bike / Edit bike; Bike name; Mileage (km/L); Current odometer (km); Save to garage / Save changes |
| 〃 | Fuel-type picker 40 dp | 48 dp |
| 〃 | Save-failure snackbar "Your plan keeps one bike in the garage." (plans never lock features) | "Could not save this bike. Try again." |
| `presentation/account/account_screen.dart` | My bike & Garage; Membership & Plans | My bikes; Membership & plans |
| `presentation/home/ride_start_view.dart` | row "Motorcycle · Garage & service" | "Garage · My bikes & service" |
| `presentation/settings/feature_catalog.dart` | Garage privacy said "Stays on your phone.", but 3.55 shares the bike colour with the group and a bike summary with CoRoute | States what is shared: the bike colour with the group, and model, engine size, tank and mileage with CoRoute |
| 〃 | "Lead and Sweep" entry (Lead / Sweep, "the Lead sets the Sweep") | "Riding roles": Lead / Middle / Sweeper and automatic roles |

### Plans / membership / payments
| File | Before | After |
|---|---|---|
| `presentation/subscription/membership_dashboard_screen.dart` | **Light-mode bug:** about 60 hard-coded `Colors.white*` / `redAccent` / `amberAccent` / `lightGreenAccent` on `AppTheme.card` (white text on white in light theme) | `AppTheme.text / text2 / muted / border / soft / sos / warnText / warnTint / warnBorder`, `StatusColors.success`. White text is kept only on the red Remove button |
| 〃 | CoRoute Membership & Plans; Payment & Invoice History; Verifying Membership Status / "Checking your plan..." | Membership & plans; Payments & plan history; Checking your plan / "This takes a few seconds." |
| 〃 | Safety-First Membership Guarantee; Single Active Trip Lock Engaged; "You are in a ride (grp_123) as OWNER." (showed a raw ID and role) | Safety is always free; You are already in a ride; "Leave or end your current ride to start another one." |
| 〃 | ACTIVE MEMBERSHIP / EXPIRED; Individual Solo Membership / Group Membership (6 Riders Capacity); Owner: You (Permanent & Non-transferable); Valid until: …; Seat Count: 3 / 6 seats | ACTIVE PLAN / ENDED; Small Group (2–6) / Large Group (7–12) / Legacy plan (Individual); You own this plan (not transferable); Valid until …; Seats used: 3 of 6 |
| 〃 | Reactivate Plan; Renew Current Plan (…); Membership Expired; Seat Capacity / Group Seat Capacity; "3 / 6 Seats"; seat(s) | Renew plan; Renew plan (…); Your plan has ended; Your seat / Group seats; "3 of 6 seats"; seat/seats |
| 〃 | "Solo plan: 1 seat. Upgrade below…" (×3); Rider Invitations / Group Participants; "Seat capacity reached…" | "This plan has 1 seat. Pick Small Group or Large Group below…"; Invite riders / Riders on your plan; "All N seats are taken. Remove a rider or pick a bigger plan." |
| 〃 | Invite Group Rider; "…join your convoys at zero extra cost"; Send Invite; Remove Rider?; "removed from group membership"; Failed to invite/remove rider | Invite a rider; "…ride in your group rides at no extra cost"; Send invite; Remove rider?; "removed from your plan"; "Could not invite/remove this rider. Try again." |
| 〃 | GROUP PARTICIPANT / Zero Extra Cost / Invited Member Access | INVITED RIDER / No extra cost / You ride on a friend's plan |
| 〃 | Renew or Switch Plan / Upgrade or Switch Plan / Select Membership Plan / "…switch to a different tier." / Current Active Plan (Tap to Extend) / Select & Pay ₹N / Solo Rider (1 Seat) / Group (N seats) | Renew or change plan / Upgrade or change plan / Choose a plan / "Pick a plan below to renew or change your plan." / Your plan · tap to extend / Buy for ₹N / 1 seat / Up to N riders |
| `presentation/subscription/membership_payment_screen.dart` | Membership Payment; "N Riders Capacity · Monthly Subscription"; PROMOTIONAL COUPON (OPTIONAL); Remove Coupon; "CODE Applied!"; Instant UPI Apps; Cards & Net Banking; Check Pending Order Status; Pay ₹N & Activate Membership; Activate Free Membership (₹0); 100% Free Activation; Total Payable | Plan payment; "Up to N riders · 30 days"; COUPON CODE (OPTIONAL); Remove coupon; "CODE applied"; UPI apps; Cards & net banking; Check payment status; Pay ₹N and start plan; Start plan for ₹0; Nothing to pay; Total to pay |
| 〃 | Raw exception text shown to riders ("Could not launch payment gateway: $e", "Payment checkout error: $e") and jargon ("Missing order reference from payment gateway") | "Could not open the payment page. Try again." / "Could not start the payment. Try again." / "The payment page returned no order. Check your payment history before you pay again." |
| 〃 | "Regroup points, lead and sweep" | "Regroup points and riding roles (lead, middle, sweeper)" |
| `presentation/subscription/payment_history_screen.dart` | CoRoute Pro (legacy) / Road Captain (legacy) / Tour Operator (legacy) / Individual / No plan | Legacy plan (CoRoute Pro) / (Road Captain) / (Tour Operator) / (Individual) / Community (free) |
| `data/models/membership_model.dart` (`UserMembership.name`) | Individual Solo / Group (2–6) / Group (7–12) | Legacy plan (Individual) / Small Group (2–6) / Large Group (7–12) |

### Admin
| File | Before | After |
|---|---|---|
| `presentation/admin/admin_features_screen.dart` | title Features | Feature switches (nav label stays "Features") |
| `presentation/admin/admin_rider_insights.dart` | Make rider (confusing: removes admin access) | Remove admin |
| `presentation/admin/admin_ui.dart` (`adminRoleLabel`) | Lead / Sweep / Rider | Lead / Sweeper / Middle |
| `presentation/admin/master_admin_dashboard.dart`, `admin_device_compatibility_screen.dart` | Access Denied | Access denied |

### Other screens
| File | Before | After |
|---|---|---|
| `presentation/trip_planner/offline_map_manager_screen.dart` | Offline Map Packs / Delete Map Pack? / Clear All Offline Map Packs? / Clear All / Verify Offline | Offline map packs / Delete map pack? / Delete all offline map packs? / Delete all / Check offline |
| `presentation/widgets/intercom_dock.dart` | Audio & Controls | Audio & controls |
| `presentation/report/trip_report_screen.dart` | tooltip Rate & Review Trip | Rate this ride (same as the card below it) |

### Tests updated to the new strings
`membership_ui_states_test`, `trip_creation_membership_gate_test`, `trip_creation_payment_journey_test`, `minimized_cockpit_sheet_test`, `offline_map_manager_test`, `access_control_and_admin_regression_test`, `convoy_mesh_integration_test`, `heritage_places_355_test`, `cockpit_enhancements_test`, `cockpit_top_pill_road_name_test`, `offline_maps_and_navigation_test`.

## 4. Remaining UX issues: need a design, product or owner decision

1. **Files owned by the safety/services agent (left untouched to avoid edit conflicts).**
   - `data/services/safety_service.dart`: the button label `'Route to Bunk'` (×2). Should be "Route to fuel station".
   - `data/services/route_essentials_service.dart`: fallback `'Petrol Pump'`. Should be "Petrol pump".
   - `data/services/helmet_voice_service.dart`: "Fuel stop requested at next petrol pump". Should be "…at the next fuel station".
   - The cockpit fuel de-duplication (`live_cockpit_map_screen.dart` ~l.2372) also matches the word "bunk". Keep that matcher until those labels change.
2. **Emergency button casing.** "Need Help", "I Can Help", "Can't Assist", "Unable to Assist", "View Emergency" and "EMERGENCY" are Title Case or caps. Every other button is sentence case. They are used in L10n (te/hi/…), notification actions and many safety tests, so changing them needs sign-off from safety and localisation.
3. **"Trip" vs "ride".** Live features say *ride*. History says *trip*: the "Trips" screen, "Trip report", "Trip owner / Trip head", "No events for this trip". Pick one, or document the split ("ride" while riding, "trip" once saved).
4. **Trip owner, trip head and riding Lead: decided by the owner (Nov 9), done.**
   - **Trip owner** = the person who created the group/trip. **Trip head** = a secondary owner for that one trip who can change the trip's group settings only (second owner decision, Nov 9: no removing riders, no ending the trip, no pause / roles / stops / route / buddy pairs as such; a trip head who rides as the picked Lead keeps the Lead's rights by that role). **Lead** = a riding role in that trip: the first rider in the convoy, who guides the others (with Middle and Sweeper).
   - Second decision applied (gateway `canChangeSettings` / `isLead` / `canManage`, app `canChangeGroupSettings` / `canEditRoute` / `canEndTrip`): stop, meet-here, trip-report and Guardian texts now say "the trip owner or the Lead"; the End Ride button shows for the trip owner only; gateway errors "Only the Trip owner or Lead can change the trip state." / "Only the Trip owner can end the trip." / "Only the Trip owner can remove riders."; choosing a trip head no longer moves the riding roles.
   - Text that says who *manages* the trip now says "the trip owner or trip head" (was "the lead"): group settings lock note and automatic-roles subtitle, meet-here sheet, stop suggestions (cockpit, route stops panel, historic place "Add stop"), public ride ("The trip owner or trip head decides."), Guardian group consent, feature guide hints (Riding roles, Group alerts, Nearby groups, Start or join), trip report ("Skipped by the trip owner or trip head."). "Disabled by lead" (ride feature summary) → "Turned off for this ride"; "The lead requires a PIN…" → "This ride needs a PIN for Guardian links."; "Paused by the trip head" → "Group ride paused" (the trip owner, the trip head or a set lead can pause).
   - Safety text keeps "your lead" ("Your lead was told…"): those alerts go to the riding lead and sweeper.
   - Admin ride lists: "lead Asha" (it was the creator) → "trip owner Asha"; search hint "Ride, trip owner or place"; plan seats "trip owner included".
   - Mid-sentence role names are lower case: "the lead", "the sweeper", "the trip owner", "the trip head". Badges stay upper case.
   - Role explanations: the manage-riders sheet now has one line per role ("Trip owner: created this trip." / "Trip head: can change the trip's settings. Only the trip owner removes riders or ends the trip." / "Lead: rides first and guides the group. Middle: rides between. Sweeper: rides last.") and shows the riding role badge next to the trip role (a trip owner who rides Lead shows TRIP OWNER and LEAD). The rider card's Riding role section and the feature guide's "Riding roles" entry explain the positions in one line and say they are not the trip owner / trip head.
   - Still to change, in files other agents own: `core/config/feature_gates.dart` ("The ride lead's audio…", unused, see 7) and `domain/voice/helmet_voice_hotword.dart` ("Fuel stop asked from the Lead." → "…from the lead.").
5. **The features guide has no 3.55 entries** for Place reviews, Historic places, Bike swap / change places, Road hazards (pothole / speed breaker / rough road), Engine rest advice and Route to group. The battery, data and privacy facts for each need product input.
6. **"Road joint ahead".** `RoadHazardClassification.transverseJoint` is a fourth kind beyond Pothole / Speed breaker / Rough road. Decide whether it folds into "Rough road".
7. **Dead jargon strings.** `core/config/feature_gates.dart` `featureName()` / `featureDescription()` ("Road Hazard Telemetry Mesh Broadcast", "Multi-Bike Motorcycle Garage", "Total Convoy Spread Alerts"…) are not used anywhere. Delete them, or rewrite them before anyone shows them.
8. **The rest of the membership screen still uses Title Case**: "Membership Activated!", "Membership Activated Successfully", "POPULAR", and some catalog names that come from the server ("Extended Group (7–12)", "Group Membership (2–6)" in test fixtures). The server catalog names should be set to "Small Group (2–6)" / "Large Group (7–12)".
9. **Garage.**
   - The record-service dialog silently ignores an empty or invalid odometer value (it shows no error).
   - `BikeProfile.year` defaults to 2024 and can't be edited. Either add a Year field or drop the field.
   - "Set active" vs the ACTIVE badge is fine, but "Primary" (`account_screen.dart` "PRIMARY") is a third word for the same idea.
10. **Hard-coded dark colours remain elsewhere.**
    - `admin_device_compatibility_screen.dart` uses `0xFF0D1117` and white.
    - The heritage, Guardian and hero cards use white on purpose (hero gradient).
    - The cockpit speed colours in `minimal_cockpit_overlay.dart`.
    - The membership expired/owned gradient still uses `Colors.red.shade900`.

    A token pass is needed for light theme on the admin diagnostics screens.
11. **"COCO" in fuel station rows** (`cockpit_action_stack.dart`). Many Indian riders know it ("company-owned, company-operated"), but it is jargon for some. Consider "Company-run".
12. **Taps while moving: decided by the owner (Nov 9), done: speak while moving, act when stopped.** Non-urgent cards that need a tap (off-route "Route to group", bike / rider-pillion swap request, historic place on the way, place review question) show their buttons only when the rider is stopped (3 km/h or less for 5 s; moving again at 8 km/h). While moving: one short line, once, and a compact chip with no buttons. A pillion can always tap. Safety cards (SOS, crash alarm, rider down, siren) are not affected. Gate: `domain/ride/ride_tap_gate.dart` (`RideTapGate`, pure). Lines and chips:

    | Card | Said once while moving | Chip while moving |
    |---|---|---|
    | Off the group's route | "You're off the route. Stop when safe to route to your group." (already stopped: "You left the group's route. Choose on the screen.") | "Off the group's route · Stop to choose" |
    | Swap ask | "Asha wants to swap bikes with you. Stop when safe to accept or decline." | "Asha wants to swap bikes with you · Stop to answer" |
    | Historic place | "Historic place on your way: Golconda Fort, …" (unchanged) | "Historic place ahead: Golconda Fort" |
    | Place review | "Rate Sri Sai Dhaba when you stop." | "Rate Sri Sai Dhaba when you stop" |

13. **Admin place reviews** show the raw category id (`fuel`, `other`). Map it with `PoiCategory.singular`.

14. **Round 3 wording to fix (owners of those files).**
    - (Admin switch `hornAlert` removed later in 3.55 with horn alerts.) The cockpit siren card now reads "EMERGENCY VEHICLE SIREN" with a "GIVE WAY" badge (was "BEHIND"/"YIELD"/"Audio ducked -20dB"). Fixed Nov 9.
    - The cockpit siren card (`siren_hud_pill.dart`) still has the code path for "EMERGENCY SIREN BEHIND" (only when `approachingFromBehind`, which the new mic path never sets), the badge "YIELD", the detail "Audio ducked -20dB", the fallback "Acoustic siren", the tooltip "Dismiss Alert" and the screen-reader hint "Yield right of way." Suggested: "Give way", "Music lowered", "Siren", "Dismiss", and the same "Keep left and give way" wording as the voice.

15. **Missing-rider check: decided by the owner (Nov 9), done.** The card keeps **I'm OK** and **Need help** (asks the group to wait, as before) and adds a separate red **Send SOS** button under it ("Send SOS · hold to send", "Keep holding…" while held), which must be held for 1.5 s like the big SOS button and raises the real SOS. The line above it: "Need help asks the group to wait. For an emergency, hold Send SOS."

16. **Place review question after the ride: done.** "Rate places from your ride" (at most 2 places, "You stayed 25 min. A quick rating helps the next riders.", **Rate** / **Skip**) after the ride ends, on the "Ride ended" screen or as a sheet after the trip review, only for places not answered in the cockpit and only while the `placeReviews` and `reviewPrompt` switches are on.
