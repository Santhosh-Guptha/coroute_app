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
