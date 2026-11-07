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
| Riding position, front | **Lead** | Road Captain, Point, "LEAD (POINT)" | rider card (chip, Riding role segment), manage-riders badges, cockpit pills, RoleNotice, feature guide, admin (`adminRoleLabel`) |
| Riding position, middle | **Middle** | Pack, Rider (as a role badge) | `RideRole.label`, rider card segment, manage-riders badge, admin role label |
| Riding position, back | **Sweeper** | Sweep, SWEEP | everywhere above, plus the compact cockpit roster tag |
| The three of them together | **Riding roles** ("Riding role" for one rider); **Automatic roles** for the auto switch | "Lead and Sweep" | group settings, rider card, feature guide ("Riding roles"), plan benefits |
| Ride creator (governance) | **Trip owner** (badge TRIP OWNER, compact tag OWNER) | Ride owner | manage-riders sheet, cockpit roster |
| Route manager (governance) | **Trip head** (badge TRIP HEAD, compact tag HEAD; sentence text "the trip head") | Trip Head mid-sentence | manage-riders sheet, "Paused by the trip head" |
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
4. **Trip head vs riding Lead.** Since 3.55 the riding Lead can be anyone, while the *trip head* manages the route. The manage-riders sheet shows TRIP OWNER, TRIP HEAD, LEAD and SWEEPER side by side. Riders will likely mix up "head" and "lead". Consider renaming *Trip head* (for example "Route manager"), or merging the two ideas.
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
12. **The off-route voice line** asks a moving rider to "Tap Route to group". This is a safety and product call: either say "Route to group is on the screen", or offer the voice command.
13. **Admin place reviews** show the raw category id (`fuel`, `other`). Map it with `PoiCategory.singular`.
