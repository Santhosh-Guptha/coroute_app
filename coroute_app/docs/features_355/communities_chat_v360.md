# v3.60: communities, chat, join approval, plans, cleaner app (round 17, build 3.55.0+10032)

Owner request (14 Nov 2026), owner choices: community chat up to **50** members; **every code join needs the host's
approval** (community invitees join directly); admin sets **features and limits per plan**.

## 1. Communities (crews, `gateway/src/crews.js` + `community_routes.js`)

| What | Rule |
|---|---|
| Public / private | `visibility` on the community (old crews stay private). Public: any signed-in rider sees name, picture, members, planned rides and joins at once. Private: everyone can find the name, description, picture and size; joining is a request |
| Join requests | `POST /api/communities/:id/join` (public: MEMBER; private: 202 REQUESTED, managers get `CREW_JOIN_REQUEST`), `DELETE` cancels. Managers: `GET /api/crews/:id/requests`, `POST .../requests/:username/approve|decline` (rider gets `CREW_JOIN_APPROVED`). Up to 200 waiting per community |
| Add / remove | Admin approves requests or invites friends (as before); admin removes members (as before). Leaving or removal drops that rider's ride answers |
| Picture | `POST /api/crews/:id/photo` (raw JPEG/PNG/WebP, cleaned like profile pictures, square cut on the phone), `DELETE` removes. Served by `/api/avatars/:id` |
| Find | `GET /api/communities/discover?q=` (public first, then by size; communities whose admin blocked me are hidden), `GET /api/communities/:id` |
| Hosted rides | Managers plan a ride: title, meeting place, destination, start (15 min to 6 months ahead), notes. Members answer **Interested / Not interested** (`POST .../rides/:rideId/answer`). Edit / cancel by the host or a manager. Members get `CREW_RIDE_NEW`. 10 planned at a time (plan limit). Rides older than 30 days are removed. At ride time the host starts a live ride and invites members from Rides (existing crew ride invites, no code, no approval) |
| Polls | unchanged (crew polls), gated by plan feature `crewPolls` |
| Switches | `crews`, `communityRides` (new) |

## 2. Join a ride: letters and digits, host approval (`convoys.js`)

* New codes: 6 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` with at least one letter and one digit (no 0/O/1/I/L).
  Old numeric codes still work.
* A new rider joining by code gets **202 PENDING** (no ride details). The host and the ride head see
  `pendingMembers` (first names) and a `JOIN_REQUEST` room event; the cockpit shows a "wants to join" card with
  **Let in / Not now**. `POST /api/convoys/:groupId/join-requests/:userId {approve}`. The rider gets
  `JOIN_APPROVED` / `JOIN_DECLINED` on the socket; the app waits on a "Waiting for the host" screen and asks again
  every 6 s. Requests last 30 min; a declined rider can ask again after 10 min; at most 20 waiting.
* No approval: the host and head, a rider already in (or earlier in) this ride, an approved rider, community ride
  invitees, operator rides (the operator approved the sign-up).
* `RIDE_JOIN_APPROVAL=false` turns it off; off by default under `NODE_ENV=test`.

## 3. Chat (`gateway/src/chat.js`, app `chat_service.dart`, `chat_thread_screen.dart`)

* Text only (any attachment field: 415 TEXT_ONLY), 1 to 1000 characters, 30 a minute, every message deleted 90 days
  after it was sent (hourly sweep; reads never return expired ones).
* Friend chat: friends only, closed for new messages after unfriend or block. Community chat: members of a community
  of up to `chatMembersMax` members (the community admin's plan, default **50**); bigger: no chat.
* `GET /api/chats`, `GET /api/chats/unread`, `POST /api/chats/dm {username}`, `GET|POST /api/chats/:id/messages`,
  `POST /api/chats/:id/read`, `DELETE /api/chats/:id/messages/:mid` (own; community managers any).
* Realtime `CHAT_MESSAGE` / `CHAT_DELETED`. Push **always**, except while the receiver is on a ride (no push, no
  in-app notice; the count waits). Account deletion removes my messages and my friend chats.
* Badges: **Messages** = friend + community unread + ride chat written by riders. **Alerts** = ride alerts.
  Automatic ride notices never count as messages.

## 4. Notifications

Friend requests / accepted, community invites, polls, join requests and approvals, new community rides and chat
messages are pushed even when the app has a live socket (the app shows one notice per eventId).

## 5. Friend profile

`GET /api/users/:username/rides-together` (friends only): group rides both riders were on (name, destination, day,
my km), shown as "Rides together", plus a **Message** button.

## 6. Settings and profile

* Removed: speed warning (now in the ride: cockpit quick settings), push notifications switch (always on; News
  opt-out kept), lock-screen cockpit switch (always on), siren alerts switch (always on; admin switch still applies).
* Profile rows: Account, Emergency, My shared routes, Clubs and tours (operators), Help & feedback (Rate inside),
  Privacy & terms, Admin, Settings. Removed: My trips (the "All trips" link stays), Notifications, Theme, Invite,
  Rate, Leaderboard (in Community).

## 7. Cockpit

One tap on the map hides every control and card (sheet, HUD, buttons); one more tap brings them back. SOS never
hides (it moves to the bottom corner). An important alert or a new join request brings the controls back.

## 8. Phone sessions

`SESSION_APP_IDLE_DAYS=0` and `SESSION_APP_ABSOLUTE_DAYS=0` (defaults): the app is never signed out by time. Sign-out,
password change, "sign out everywhere", refresh-token reuse and admin revoke still end a session at once. Web and
admin sessions keep their limits.

## 9. Features by plan (`gateway/src/plans.js`)

Web admin > Payments > **Features by plan**, in-app admin > System > **By plan**. Per plan (Community, Small Group,
Large Group): features `createCommunity`, `communityRides`, `crewPolls`, `communityChat`, `friendChat`,
`exploreRoutes`; limits `communitiesOwnedMax` (0-10), `communityMembersMax` (2-100), `chatMembersMax` (2-100, default
50), `upcomingRidesMax` (1-10). Defaults keep today's behaviour. Safety is never in the list. A feature switch off
still wins. `GET /api/me/plan-features` (app), `GET|PUT /api/admin/plan-features` (audited). Payments off: every
rider gets Large Group.

## 10. Operators in the app

Profile > **Run a club or tour on CoRoute**: the application form (same rules as the website), the review status,
and once approved **Open operator console** (website `/operator`: roster, rides, live map, attendance, broadcasts).

## Tests

`gateway/test/communities_chat_360.test.js` (8), `gateway/test/ride_join_approval_360.test.js` (1), updated
`push_355`, `push_two_node_355`, `security_357`, `gateway.test.js` (join code format). App: `test/v360_pure_test.dart`;
updated settings, profile and push routing tests.

## 11. Owner decisions and additions (15 Nov 2026)

* **Sessions**: riders signed in now stay signed in (confirmed).
* **Plans**: safety is free for everyone; every feature in the plan list is a plan feature. Default: **off on
  Community (free)**, on for Small Group and Large Group (`plans.js` `DEFAULT_FEATURES`). Free riders can still join
  communities, vote and answer rides; creating communities, hosting community rides, polls, community chat, friend
  chat and sharing routes need a group plan unless the admin turns them on for Community.
* **Community size**: the admin's choice per plan (`communityMembersMax`, 2 to 100; chat limit `chatMembersMax`).
* **No spoken off-route / re-route lines**: the route guide's prompts are not wired to the voice (`main.dart`
  `onPrompt: null`), the off-group line is not spoken (`RideAdvisories.speakOffRoute = false`), and "Routing you back
  to the group" is not spoken. Cards and the status line still show them.
* **Faster re-route**: off-route decided after 6 s (was 8 s), next request after 8 s (was 15 s), a request times out
  after 10 s (was 20 s; app HTTP timeout 10 s, was 15 s). Gateway: routing has its own queue
  (`GEO_ROUTE_MIN_INTERVAL_MS`, 250 ms) so a re-route never waits behind address look-ups in the shared 1.1 s queue.
* **Meet first** (riders start from different places): the planner switch "Riders meet at the start first" creates
  the ride with `gathering`. Each rider is routed on their own to the meeting point (their personal route on the
  map; the others show as dots); the cockpit card shows "Meet at X · 3 of 5 there · 2.4 km away" and, for the host /
  ride head, **Start ride**. `POST /api/convoys/:groupId/gathering {start}` or `{meetingPoint}` (host / head);
  room event `GATHERING`. A rider within 150 m counts as there.
* **No black Ride AOD**: the cockpit is never replaced by the black screen with speed and turns
  (`LiveCockpitMapScreen.rideAodEnabled = false`); when idle the cockpit only dims a little.

## 12. Cockpit layout, talk modes, safety latency (round 18, 15 Nov 2026)

* **One top bar** (`HudCombinedBar`, hud_top.dart): back, turn arrow, distance + instruction, the destination line
  "Nandi Hills · 48 km · 7:42 am" (tap: route options) and the limit sign in one card; the "then" line and the route
  status are slim strips inside it; status chips under it. `HudTopBar` / `HudTurnCard` stay for other screens/tests.
* **Short ride sheet**: one row (64 dp speed dial, ETA, km left, riders, talk button). The group pill shows only when
  something needs a look (rider falling behind, reconnecting). End / leave moved to the open sheet (RideLifecycleBar).
* **Talk button** (`CockpitTalkButton`): mic part (hold to talk; hands-free on: tap stops it; muted: tap unmutes) and
  an options part: **Hold to talk**, **Hands-free** (mic opens on the voice), **Who hears me** (Everyone or one rider:
  private talk) and **Talk button side**. Same IntercomService calls as before; admin switch `intercom` still hides it.
* **Left-hand controls**: setting `cockpit_controls_left_v1` (Quick settings > Controls side, or Talk options). Left:
  talk at the start of the row, the map buttons on the left, SOS on the right. Positions only; SOS hold unchanged.
* **Safety latency** (audit): SOS duplicate check waits at most 1.5 s (`SOS_LOOKUP_WAIT_MS`), the store at most 2 s
  (`SOS_STORE_WAIT_MS`) before the alert goes out; Medical ID fetched in parallel; no "0.00000, 0.00000" in SOS texts
  (server and phone); a waiting SOS keeps its last good position; HTTP backup even before the ride rejoin; helmet
  remote SOS before the first fix; group SMS after 20 s with no live link (45 s online); `CockpitSosButton` hold 3 s.
* Tests: `test/talk_button_state_361_test.dart` (pure, 5), `test/safety_latency_361_test.dart` (3),
  `test/hud_ride_sheet_test.dart` (+2, Flutter), `gateway/test/sos_latency_361.test.js`, SMS text test.

## 13. Safety gaps closed (round 19, 15 Nov 2026)

* **SOS push to closed apps**: `convoys._pushSos` sends `GROUP_SOS` ("SOS: Ravi needs help" / "Crash alert: Ravi",
  body "<ride name>. Open CoRoute to see where and help.") to every rider of the ride with no live socket (here or on
  the peer node), right after the room fan-out, not awaited. Data: groupId and alertId only (never a position or
  medical info). `urgent`: never held back by the per-rider push throttle or the admin push switch (push.js
  `URGENT_TYPES`). Closing the SOS sends `GROUP_SOS_RESOLVED` with the same collapse key / notification id, so it
  replaces the alarm. A resend of the same SOS pushes nothing new.
  Android (`CoRouteMessagingService.kt`): always shown (even with app push muted or the app in front), channel
  `coroute_sos_v2` (SOS alerts, alarm sound, bypass DND), category ALARM, lock-screen visible; the close uses
  "Group alerts". App in front: `push_router_host` also reconnects the socket at once (`RealtimeService.retryNow`).
  Tap: opens the app; the ride restores and its re-join brings the SOS card.
* **Late Medical ID**: a profile slower than 1.5 s never holds the SOS; `_lateMedical` waits up to
  `SOS_MEDICAL_LATE_MS` (15 s), adds the Medical ID to the still-open alert, stores it and sends the same ALERT again
  to the room (the app updates the alert in place: no second alarm). Nothing is added after the SOS closed.
* **HTTP SOS never refused**: the 12-a-minute limit is gone and the SOS route no longer counts toward the general
  240-a-minute API limit; only abuse far beyond any phone (600 a minute per account) gets 429. Resends with the same
  clientId and the storm guard keep the group from floods.
* Tests: `gateway/test/sos_push_medical_362.test.js` (5), `test/group_sos_push_362_test.dart` (pure, 1).

## 14. Phones stay signed in (round 20, 17 Nov 2026)

Owner: "still in mobile session is logging out". Causes found and fixed (no VM change needed):

| Cause | Fix |
|---|---|
| The 6-hourly session sweep deleted EVERY session record not used for 30 days, live phone sessions too: a phone unused for a month was signed out | `sessions.sweep` removes only records that ended (signed out / revoked, or past their own idle / hard limit) 30+ days ago. Live phone sessions are never removed |
| A refresh reply lost on a bad mobile network (or a new token the phone could not save before it was closed) was "theft" after 60 s: the whole session was revoked | Phone sessions accept the previous refresh token at any time (`REFRESH_REUSE_GRACE_APP_SEC`, 0 = any time). A token two rotations old is still theft. Web keeps 60 s |
| Older builds: the long token (JWT_TTL_DAYS 30) ran out and the rider was signed out even though the server session was fine | An expired long token that names a live phone session is accepted and renewed (`X-CoRoute-Token`); revoked / signed-out sessions still end |
| Android secure storage (flutter_secure_storage 11) wipes all stored values on any keystore error (`resetOnError` default true): a busy keystore after boot deleted the tokens | `lib/data/local/secure_store.dart` `kSecureStorage` with `resetOnError: false` for every secure store; token read retried up to ~10 s |

**Web admin > Admin > Phone sign-in** (`src/session_settings.js`, `public/admin/session_settings.js`): days without
opening the app and days after sign-in (0 = never, the default). A saved rule applies ONLY to phone sign-ins made after
saving (each new phone session keeps a copy, `appPol`); riders already signed in keep their rule, and sessions made
before v3.62 have no time limit whatever the VM .env says. MASTER_ADMIN saves; audited. `GET|PUT /api/admin/session-settings`.
Sign-out, password change, sign out everywhere, hold / block and admin revoke still end a session at once.

Tests: `gateway/test/sessions_stay_362.test.js` (6).

## 15. Web admin: command center and configuration portal (round 20)

* **Command center** (`#/command`, the new landing page; `public/admin/command.js`, `command.css`): live view that
  refreshes every 15 s while the tab is visible (Pause button): status strip (servers, push, feature switches, phone
  sign-in, safety locked on), live numbers (riders online over both nodes, live rides, open SOS (red, pulsing when
  above 0), active today, riders), Needs attention, Recent admin actions (audit), both servers (online, lag, memory,
  requests), quick actions. Uses existing endpoints only.
* **Configuration** (`#/config`): every setting as a card with its current value (access mode, phone sign-in, feature
  switches, features by plan, pricing, coupons, push, e-mail, message words, SOS SMS, weekly summary, Explore,
  operators, ratings, servers, audit log) and a filter box.
* **Feature switches on the web** (`#/features`, was app admin only): grouped switches with the last change and a
  reason asked on every change (audited, `PUT /api/admin/features/:id`); safety switches show "Always on".
* **Phone sign-in** page restyled (status card with phones signed in now).
* **Command palette**: Ctrl/Cmd + K or "Jump to" in the top bar: any page, theme switch, search.
* Menu icons, a Configuration group in the menu, smooth page entry; light and dark; respects reduced motion; phone
  width works (2-column numbers).

## 16. QA, security and intelligence round (round 21, 17 Nov 2026)

Done by three parallel workers (QA tester, security tester, intelligence), merged and run together.

**QA** (`gateway/test/qa_e2e_timing_362.test.js`, `test/qa_double_tap_362_test.dart`): ride flows end to end
(sign-in, join + approval, SOS, chat, reconnect, same account on two phones), double requests at once (one pending
join, one member, one alert, one message), 25 website pages at 360 to 1440 px, web admin and operator console with
2-step (authenticator, recovery codes, e-mailed codes). Test-gateway timings p50 / p95: sign-in 8 / 16 ms, join 8 /
16 ms, SOS 2 / 10 ms, chat send 3 / 3 ms. Fixed: operator console had no menu button below 1100 px (top bar + drawer);
admin inline styles dropped by the CSP (now applied through CSSOM); double clicks repeated admin / operator actions
(busy state until the server answers); double Enter on 2-step and password forms (operator, website, account);
cockpit "Let in" / "Not now" and "Start ride" acted twice; Garage "Save service" double save + controller disposed
twice; People Add / Accept sent twice.

**Security** (`gateway/test/security_362_hardening.test.js`, `src/input_guard.js`): `$`-keys and `__proto__` /
`constructor` stripped from every query, body and socket message (query parser `simple`); 2-step code checks for one
account run one at a time (no double use of a recovery / authenticator code in a race); a phone's previous refresh
token works at most 3 times after the 60 s window (`PREV_LATE_MAX`), then counts as theft; closed-app SOS pushes at
most 6 per rider per 10 min (the SOS itself is never limited); live phone session count cached 5 min. Reviewed and
sound: admin separation, IDOR on chat / communities / rides / operator routes, PATCH /me allow-list, no innerHTML,
CSP, SSRF host allow-lists, uploads, dependencies, secrets, Android exported components, pinning, cleartext off.
Open (low): 2-step race across two nodes at the same instant; Host header fallback when PUBLIC_ORIGIN is unset;
ride lock not re-checked on renewing an expired long token (old builds, same as the 24 h re-sign).

**Intelligence** (docs/intelligence/INTEL_DATABASE.md, INSIGHTS_v3.62.md): optional own database for intelligence
(`INTEL_SODA_URL`, `INTEL_ORACLE_USER`, `INTEL_ORACLE_PASSWORD`; unset = main database, no change), leased resumable
copy (`INTEL_DB_MIGRATE=1`: main -> dual writes -> intel), erase / export / backups follow the data. New: popular
roads (k >= 5 riders per cell chain), route difficulty (Easy / Moderate / Challenging + reasons,
`POST /api/intel/route-difficulty`, chip in Plan a ride), where and when riders stop, monthly trends, rider risk
(aggregate; one rider for MASTER_ADMIN only, audited). Web admin > Road & safety intelligence > Insights.

## 17. Round 22: DB 2 readiness and the last open security items

* DB 2: `scripts/intel_db_check.js` readiness check; `INTEL_DB_PROFILE=extended` (page views, e-mail log, rider
  scores, diagnostics, trip tracks); safety collections can never be moved; collections added after the switch are
  copied safely (pending -> migrated); web admin Configuration shows "Intelligence database: DB 1 only / Copying /
  DB 2 in use". docs/intelligence/INTEL_DATABASE.md "v3.62b additions".
* 2-step codes single use across both nodes (`mfa_used`, unique index; a database problem never blocks a sign-in).
* Generated links never use a forged Host header (`domains.requestOrigin`: PUBLIC_ORIGIN, else only own / loopback
  hosts, else the fallback origin).
* Ride lock also checked when an expired long token (older builds) is renewed.
* An SOS raised on the other node still gets its "closed" push (own cap: 6 per rider per 10 min, SOS under 6 h old).
* Tests: `gateway/test/intel_362b_added.test.js` (3), `gateway/test/security_362b.test.js` (4).

## 18. Pricing model switch: Group plans or Rider Pass (round 23, 17 Nov 2026)

Owner: "every rider pays 9 rs for one month with all features; only 2 plans: free Community (single user) and paid
one month all features; n riders can join rides; before prod I'll decide which to make".

Web admin > Configuration > **Pricing model** (`src/pricing_model.js`, `public/admin/pricing_model.js`):

| Model | Sold on the website | Hosting | Joining |
|---|---|---|---|
| **Group plans** (default, today) | Small Group (2-6), Large Group (7-12), bought by the host | host's plan seats | free |
| **Rider Pass** | Rider Pass: one rider, every feature, 30 days, list price Rs 9 (editable in Plans & pricing) | a pass holder hosts rides any number of riders join (server ceiling MAX_CONVOY_RIDERS) | free |

Both: Community stays free (solo rides, every safety feature); safety is never gated; switching never cancels or
refunds a running plan (a Small / Large Group or a Rider Pass bought before keeps working until it ends); only what
can be bought changes. A Rider Pass can be renewed any time (unused days are credited). Features by plan has a Rider
Pass column (all on by default). Admin assign plan, coupons (plan options follow the model), website plans page and
the app admin plan names know the Rider Pass. The app never shows prices (Play policy unchanged).
`GET|PUT /api/admin/pricing-model` (MASTER_ADMIN, audited). Tests: `gateway/test/pricing_model_363.test.js`.
Changed on purpose: `membership_plans.test.js` (catalog has 4 plans), `intel_362_insights.test.js` (fixed time of day,
was failing at night), `job_lease.test.js` real-timer test tolerant of a busy machine (still never twice per interval).

## 19. Round 24: share card, browser riders, trip planning lite, privacy zones, admin opens the console (17 Nov 2026)

* **Ride card + rich invite** (`lib/domain/share/ride_card.dart`, `report/ride_share_card.dart`, `gateway/src/invite_cards.js`):
  WhatsApp 1080x1080 and Story 1080x1920 cards (route sketch without the first / last 300 m and without anything near
  a privacy zone, km, time, rider score, hazards logged, safety line); `/join/<CODE>` and `/join/friend/<CODE>` carry
  Open Graph / Twitter tags (host first name, ride name, destination, day, riders; nothing else; generic for bad codes).
* **Guests and iPhone riders in the browser** (`gateway/src/guest_service.js`, `public/ride/`, `/ride/<CODE>`): first
  name + browser key, host approval as usual, live map, position from the browser, group list, SOS alarm in, hold-3-s
  SOS out (convoys.raiseSos), "Browser" badge in the app. Guest tokens: one ride, 12 h, refused by every other API.
  iPhone limits shown on the page (page must stay open; no crash detection or texts from a browser).
* **Trip planning lite** (docs/features_355/trip_planning_lite_v363.md): ride expenses with "who pays whom" (records
  only, no money moves), pre-ride checklist (never blocks a ride), weather at each stop (MET Norway, wind added).
* **Privacy zones** (Profile > Privacy zones; `private_places.dart` extended): Home / Work / Other at 300 m / 500 m /
  1 km, kept only on the phone. Inside a zone nobody (group, guardians, public pages, browser riders, live links) gets
  the position; the rider list says "Location hidden near a saved place". **In an emergency (SOS, crash alarm,
  rider-down) the exact position is always shared**, also inside a zone (tests prove it). Tracks and road data skip
  zones.
* **Admins: one place.** App: administrators open straight into the admin console (splash, sign-in, and a late-loaded
  role); the rider profile no longer has an "Admin" row (an admin who is riding keeps the cockpit until the ride ends).
  Website: an admin signing in goes to /admin; /account sends admins to /admin (`?rider=1` keeps the page).
* **Device compatibility (Samsung S24 report):** the website's 32-bit APK cannot be installed on 64-bit-only phones
  (Galaxy S23 / S24 / S25, Pixel 7 and newer); the download page now says "32-bit Android (old phones only)". Static
  review of targetSdk 36 rules (foreground service types and permissions, receiver export flags, 16 KB native
  alignment, exact alarms not used) found no blocker; a crash log from the S24 is needed for anything else (see
  release prompt part S).
* Tests: `share_card_363`, `guest_join_363`, `expenses_363`, `privacy_zones_363` (gateway); `ride_card_363`,
  `trip_planning_lite_363`, `privacy_zones_363` (Dart, pure). Changed on purpose: `share_card_quick_reply_test`,
  `round6_wiring_356_test`, `access_control_and_admin_regression_test`.
