# CoRoute glossary

One name per concept. The UI names follow [docs/UX_NAMING_GUIDE_v3.55.md](../../UX_NAMING_GUIDE_v3.55.md);
code names are given where they differ. Written 11 Nov 2026.

## People and roles

| Term | Meaning | Code / API |
|---|---|---|
| **Rider** | Any signed-in CoRoute user. Target audience: licensed riders aged 18+. | role `RIDER` |
| **Pillion** | A passenger on another rider's bike, with their own phone. Keeps every safety feature; group checks count the bike once ("one bike = one answer"). | `vehicleType: 'Pillion Rider'`, `PILLION_SEAT`, `isCoRiding` |
| **Trip owner** | The rider who created the group/trip. Only the trip owner removes riders or ends the trip; keeps these rights whatever their riding role. Badge TRIP OWNER. | ride owner in `convoys.js` (`canManage`) |
| **Trip head** | A secondary owner for one trip who can change **the trip's settings only** (owner decision, 9 Nov). Cannot remove riders, end, pause, set roles or stops as such. Choosing one does not make them Lead. Badge TRIP HEAD. | `POST /api/convoys/:groupId/trip-head` |
| **Lead** | Riding role at the front who guides. With the trip owner, runs the ride on the road (stops, route, pause, roles, regroup, buddy pairs, Guardian group links). An **automatic** lead gets no management rights. | `LEAD` |
| **Middle** | Riding role between Lead and Sweeper (never "Pack" in the UI). | `MIDDLE` (`PACK` in the operator console API) |
| **Sweeper** | Riding role at the back; told when a rider falls behind them (300 m held 60 s). At most one. | `SWEEPER` |
| **Riding roles** | Lead / Middle / Sweeper together. Exactly one Lead, at most one Sweeper. | `ROLE_SET`, `ROLE_SWAP`, `ROLE_CHANGED` |
| **Automatic roles** | Off by default: the front rider leads and the last sweeps, changed at most every 2 min with hysteresis. | `ROLE_AUTO`, switch `autoRoles` |
| **Buddy pair** | Two riders in a large group who watch each other. | `BUDDY_ASSIGN`, switch `buddyPairs` |
| **Nearby rider / helper** | A rider of another group asked by the safety network to help in an SOS; sees only the point and distance until they tap "I Can Help". | `ASSIST_REQUEST`, `ASSIST_ANSWER` |
| **Guardian** | A family member or friend watching a rider through a **Guardian link** (Ride Guardian), PIN-protected, tier Basic / Live / Emergency. | `guardian_*` collections |
| **Emergency contact** | Name + phone in the rider's profile; texted in an SOS; shown to the accepted outside helper and the group while an alert is open. | `emergencyContact`, `emergencyContactName` |
| **Crew** | A standing circle of friends: crew admin, up to 3 co-admins, members; invitation only; polls are the only posts. | `crews`, `crew_members` |
| **Crew admin / co-admin** | Manager(s) of a crew. | crew member role |
| **Operator** | An approved tour operator, riding club, rental fleet or corporate fleet using the `/operator` console. Its roster is a **club crew**. | `operators`, switch `operators` |
| **Co-organiser** | A helper of an operator who can run the console (owner manages them). | `co-organisers` |
| **Club** | The member-facing name of an operator's roster (`/clubs`). | club crew `club: {operatorId}` |
| **Admin / master admin** | Staff with full console access. | `MASTER_ADMIN`, `requireAdmin` |
| **Staff** | Team accounts left out of rider analytics. | `STAFF_EMAILS` |
| **Former rider** | What remains of a deleted account in other riders' shared ride history. | `anonymise.js` |

## Rides

| Term | Meaning | Code / API |
|---|---|---|
| **Group ride** / **group** | Riders riding together in CoRoute. UI never says "convoy". | `convoys`, `groupId` |
| **Solo ride** | A ride with one seat (rider alone), with solo safety (ETA check-in, guardians). | `SOLO_TRIP_ONLY` |
| **Join code** | 6-digit code to join a ride; also `/join/<code>`. | `joinCode` |
| **Trip** | A finished ride in a rider's history, with a **trip report**, replay and timeline. | `trips`, `trip_events` |
| **Ride timeline** | Shared list of events (joined, stopped, off route, SOS ...). | `TimelineEngine` |
| **Stop / fuel stop / regroup point** | Planned or suggested places; the trip owner or Lead decides. | `STOP_*`, `REGROUP_*` |
| **Cockpit** | The in-ride main screen (map, pills, quick settings). | `live_cockpit_map_screen.dart` |
| **Ride notification** | Persistent Android notification during a ride (speed, limit, SOS / Talk / Mute / Leave). | `RideNotification.kt` |
| **Group settings** | Ride-level settings (speed limit, distances, nearby help default, automatic roles). Changed by the trip owner or trip head. | `CONFIG` |
| **Public ride** | A ride that lets riders of other groups contact it safely and share road warnings. | `PR_*`, switch `publicRide` |
| **Groups nearby** | Optional discovery of other groups on the same road. | `DISCOVERY`, `WAVE` |
| **Crew ride invite** | Invitation from a crew screen to a specific ride; Accept runs the normal join. | `ride_invites` |

## Safety

| Term | Meaning |
|---|---|
| **SOS** | Emergency alert to the group, guardians, nearby helpers and contacts. Hold 3 s. Always upper case. Locked on. |
| **Crash detection** | Phone-only detection of a likely crash → **crash alarm** with a 30 s countdown ("Possible accident detected. Are you okay?"), then an automatic SOS. Locked on. |
| **Bike down? / rider-down check** | Detection of a tipped bike at low speed. |
| **Possible incident** | Server-side backup: hard stop from speed then stillness; asks the lead and nearest riders to check. |
| **Missing-rider check** | Asks a rider who fell far behind "I'm OK / Need help / Send SOS (hold)". |
| **Emergency texts** | SMS to contacts and riders: from the phone's messages app when offline, and from the server (MSG91 / Twilio). Locked on. |
| **Live link** | `/e/<code>` page with first name, last position and Call 112, valid 30 min, at most 3 per alert. |
| **Medical ID** | Blood group, allergies, notes on the lock screen and to responders while an alert is open. Locked on. |
| **Safety health** | The phone check screen (permissions, battery, notifications, full-screen alarm) with fix buttons. |
| **Siren alerts** | Detection of ambulance / police / fire sirens on the phone mic during rides; nothing recorded. Has a rider switch (default on). |
| **Road hazard** | Pothole, speed breaker or rough road detected by the front phone and saved for later rides without rider ids. |
| **Risky stretch** | Road cell with many anonymous hard brakes. |
| **Safety network** | The gateway logic that finds nearby riders of other groups for an SOS. Admin switch `assistNetwork`. |
| **False alarm count** | Recent false alerts sent to other groups; limits requests from abusers. |
| **SOS battery reserve** | Keeps battery for SOS when low. |

## Plans, access and platform

| Term | Meaning |
|---|---|
| **Community (free)** | The free plan every rider has: solo rides and joining any ride. |
| **Small Group (2–6)** / **Large Group (7–12)** | Paid plans that let a rider **host** group rides; bought **only on the website**. One member with a plan hosts; others join free. |
| **Legacy plan** | Retired tiers (CoRoute Pro, Road Captain, Tour Operator, Individual) honoured until they end. |
| **Access mode** | Admin choice of **Paid** (default), **Free for everyone** or **Free up to limits** (hybrid), with optional scheduled change in IST. |
| **Capability / capabilities** | What the signed-in rider may do, computed by the gateway: `gated`, `canHostGroup`, `maxRiders`, `groupFeatures`, `hostedRidesLeft`, `reason`. The only plan information the app receives. |
| **Group features** | Features a free-tier ride may leave out: `intercom`, `rideRoles`, `autoRoles`, `crewRides`, `groupFuel`, `regroupSuggest`, `publicRide`, `discovery`, `vehicleSwap`. Safety is never one of them. |
| **Feature switch** | Admin on/off per feature (67 ids, 6 groups). Locked: `sos`, `crashDetection`, `emergencySms`, `medicalId`. Unknown = on. |
| **HELLO feature** | Protocol capability the gateway advertises on connect (`ride355`, `vehicle1`, `pillion2` ...); apps use a feature only if listed. |
| **Push kind** | Category of admin push: Update, Event, Safety tip, Community, Partner perk (off by default). Each has its own channel and opt-out. |
| **Partner perk** | A curated real-world perk at a partner business, pushed only to riders who opted in, max one per 7 days, no prices or codes. |
| **Offers e-mail** | Opt-in e-mail (website account page) for plan prices and coupons; unsubscribe and suppression list. |
| **Coupon** | Website discount code (QR / link `/get?coupon=CODE`), never shown in the app. |
| **Rider score** | Private 0–100 safety score; levels Learner / Steady / Skilled / **Ace Rider**; never rewards speed. |
| **Leaderboard** | Public boards by username and rounded totals; riders can opt out. |
| **Diagnostics log** | Privacy-safe technical log on the phone, sent only on the rider's action. |
| **Live node / web node** | VM1 (`GATEWAY_ROLE=live`: rides, sockets) and VM2 (`web`: website, payments, admin, mirror copy). |
| **Mirror** | Encrypted live replication of rides between the two gateway nodes. |
| **Job lease** | Exactly-once scheduled job ownership across the nodes. |
| **SODA** | Oracle's Simple Oracle Document Access REST API for JSON collections. |
| **PAR** | Object Storage pre-authenticated request URL (a secret). |
| **DLT** | India's TRAI Distributed Ledger Technology registration for commercial SMS (entity, sender id, templates). |
| **NLB** | OCI Network Load Balancer in front of both VMs. |
| **Play policy guard** | Server check (`policy_terms.js`) that refuses prices / buying words in anything sent to the app. |
