# CoRoute build 3.55.0+10032: release prompt (round 17: communities, chat, join approval, plans, cleaner app)

Paste everything inside the block into the release agent.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Build 3.55.0+10030 is committed (latest commit 1a2356a). Two rounds are in the working tree,
uncommitted: round 16 (3.55.0+10031, docs/NEXT_AGENT_PROMPT_v3.55_round16_explore_10031.md) and round 17 (this prompt).
Ship them together as build 3.55.0+10032 (pubspec already 3.55.0+10032). Commit round 16 first exactly as its prompt
section 2 says (skip its pubspec commit), then round 17 below (commits 1-21, including L to P in section 1). Then test, build, device QA, deploy, Play. Report after
each section. STOP at any failed safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0.
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths.
- Never hide or weaken SOS, the crash alarm, others' SOS banners, the rescue finder, warnings, Medical ID, ride lock,
  lock-screen cockpit, app lock. The cockpit SOS button must stay visible when the controls are hidden.
  Fix code, not tests, unless a text or layout changed on purpose (list every test you change and why).
- dart tool/play_policy_scan.dart -> 0 hits. Chat is TEXT ONLY: never add photo, video, voice or file sending.
- Read first: docs/features_355/communities_chat_v360.md (the whole round), then docs/features_355/explore_v359.md.
- Do not commit _incoming/ (transfer zips and the r17x folder; delete them after the commits).

=== 1. WHAT IS NEW (round 17) ===
A) COMMUNITIES (crews): public / private, join requests with admin approval, admin adds (approves) / removes,
   community picture, hosted rides with Interested / Not interested, polls (unchanged). Find communities screen.
   Gateway src/crews.js, src/community_routes.js; app communities_service.dart, community_widgets.dart,
   crew_detail_screen.dart, crew_create_flow.dart, community_screen.dart.
B) JOIN A RIDE: codes are 6 letters and digits (no 0/O/1/I/L); every code join waits for the host / ride head
   (202 PENDING, cockpit card "Let in / Not now", POST /api/convoys/:groupId/join-requests/:userId). Community ride
   invitees and operator rides join directly. Env RIDE_JOIN_APPROVAL (default on; off under NODE_ENV=test).
   App join_waiting_screen.dart, join_requests_card.dart, convoy_service.dart (pendingJoin, decideJoinRequest).
C) CHAT: friends 1:1 and community chat (communities up to 50 members = plan limit chatMembersMax), text only,
   90 days, delete own message, push always EXCEPT while the receiver rides. Gateway src/chat.js; app
   chat_service.dart, chat_list_screen.dart, chat_thread_screen.dart. Messages badge = chat + ride chat written by
   riders; automatic ride notices count only on Alerts.
D) PUSH: friend / community / chat notices push even with a live socket (app dedupes by eventId). New types
   CHAT_MESSAGE, CREW_JOIN_REQUEST, CREW_JOIN_APPROVED, CREW_RIDE_NEW (push_routing.dart, push_router_host.dart).
E) FRIEND PROFILE: Rides together (GET /api/users/:username/rides-together) + Message button.
F) SETTINGS / PROFILE: removed speed warning (now in cockpit quick settings), push switch (always on; News opt-out
   kept), lock-screen cockpit switch (always on), siren switch (always on). Profile rows cut to Account, Emergency,
   My shared routes, Clubs and tours, Help & feedback (Rate inside), Privacy & terms, Admin, Settings.
G) COCKPIT: one tap on the map hides every control and card; one tap brings them back; SOS never hides; an
   important alert or a join request brings them back.
H) SESSIONS: phone app never signed out by time (SESSION_APP_IDLE_DAYS=0, SESSION_APP_ABSOLUTE_DAYS=0 defaults).
I) FEATURES BY PLAN: src/plans.js, web admin public/admin/plan_features.js (Payments > Features by plan), in-app
   admin System > By plan (admin_plan_features_screen.dart). Defaults: OFF on Community (free), ON for group plans
   (see L). Safety never listed.
J) OPERATORS IN THE APP: Profile > Run a club or tour on CoRoute (operator_apply_screen.dart): apply, status,
   Open operator console.
K) Privacy page: new section "Chat and communities" (#chat-communities). .env.example documents the new variables.

L) OWNER DECISIONS + ADDITIONS (15 Nov, docs/features_355/communities_chat_v360.md section 11):
   - plan features default OFF on Community (free), on for group plans (src/plans.js DEFAULT_FEATURES);
   - no spoken off-route / re-route lines (main.dart onPrompt null, ride_advisories.dart speakOffRoute false);
   - faster re-route: lib/domain/navigation/reroute_rules.dart (6 s hold, 8 s interval, 10 s timeout),
     lib/data/services/geo_service.dart (10 s), gateway src/geo.js own route queue (GEO_ROUTE_MIN_INTERVAL_MS 250);
   - meet first: planner switch, ConvoyModel.gathering (RideGathering), convoy_service startFromMeetingPoint,
     cockpit GatheringCard + personal route to the meeting point, gateway convoys.updateGathering +
     POST /api/convoys/:groupId/gathering;
   - no black Ride AOD (live_cockpit_map_screen.dart rideAodEnabled = false).
   Commit these as:
   13. feat: meet first, faster re-route, no spoken re-route, no black AOD, plan defaults
       (all the files above + test/navigation/reroute_logic_test.dart + gateway/test/ride_join_approval_360.test.js
       + gateway/test/communities_chat_360.test.js + lib/data/models/convoy_model.dart
       + lib/presentation/rider/widgets/gathering_card.dart + lib/presentation/trip_planner/trip_planner_screen.dart)
   QA: m) host plans a ride with "Riders meet at the start first"; three riders from three places each see their own
   route to the meeting point; the card counts arrivals; host taps Start ride; the group route takes over.
   n) ride off the route: no voice line; the status line shows "Off the planned route, finding a new route" and a
   new route appears within about 10 s with signal. o) leave the cockpit idle for 5 minutes while moving and while
   stopped: never a black screen; the cockpit stays (it may dim). p) a free (Community) account sees chat, community
   creation and ride hosting as "not included in your plan"; a group-plan account has them.
   Widget tests that expect the Ride AOD, spoken re-route lines or the old 8 s / 15 s / 20 s timings must be updated
   on purpose (list them).

M) ROUND 18 (15 Nov, communities_chat_v360.md section 12): one combined cockpit top bar (HudCombinedBar), short
   ride sheet with a compact talk button (hold / hands-free / private talk to one rider), left-hand controls
   (cockpit_controls_left_v1: talk + map buttons left, SOS right), and the safety latency audit (SOS never waits on
   a slow database: SOS_LOOKUP_WAIT_MS 1500 / SOS_STORE_WAIT_MS 2000; no 0,0 in SOS texts; offline group SMS 20 s).
   Commit these as:
   14. feat(app): combined cockpit top bar, short sheet, talk modes, left-hand controls
       lib/presentation/rider/hud/hud_top.dart lib/presentation/rider/hud/hud_sheet_parts.dart
       lib/presentation/rider/live_cockpit_map_screen.dart lib/presentation/rider/widgets/cockpit_talk_button.dart
       lib/presentation/rider/widgets/glove_quick_settings_modal.dart lib/domain/audio/talk_button_state.dart
       lib/data/services/settings_service.dart test/talk_button_state_361_test.dart test/hud_ride_sheet_test.dart
   15. fix(safety): SOS latency and texts
       gateway/src/convoys.js gateway/src/config.js gateway/deploy/.env.example gateway/src/emergency_sms_gateway.js
       gateway/test/sos_latency_361.test.js gateway/test/emergency_sms_gateway.test.js gateway/test/two_node_failover.test.js
       lib/domain/safety/sms_plan.dart lib/data/services/convoy_service.dart lib/data/services/ble_remote_service.dart
       lib/data/services/safety_service.dart lib/core/constants/safety_constants.dart
       lib/presentation/rider/widgets/minimal_cockpit_overlay.dart test/safety_latency_361_test.dart
   (convoys.js / convoy_service.dart also carry commit 13 changes: commit 13 and 15 together if splitting is hard.)
   QA: q) cockpit top is ONE card (turn + destination + limit); tap the destination line -> route options.
   r) collapsed sheet is one row; End / Leave are in the open sheet. s) Talk: hold -> group hears; options ->
   Hands-free -> speak without touching; tap mic -> hands-free off. Private -> pick Anu -> only Anu hears (B hears
   nothing, button shows "Anu"); Everyone resets. t) Quick settings > Controls side Left -> talk at the left of the
   row, map buttons left, SOS right; one tap map-only keeps SOS (right corner). u) airplane mode SOS: group SMS
   after ~20 s; a slow database never delays the alert to the group (server log: SOS sent before the store ends).
   Widget tests that expect MinimalHoldToTalkBar, hud_end_ride or hud_group_pill in the COCKPIT collapsed sheet,
   or separate HudTopBar / HudTurnCard in the cockpit, must be updated on purpose (list them).

N) ROUND 19 (communities_chat_v360.md section 13): SOS push to riders whose app is closed (GROUP_SOS /
   GROUP_SOS_RESOLVED), late Medical ID (SOS_MEDICAL_LATE_MS 15000), HTTP SOS never refused (600/min abuse cap only).
   Commit as:
   16. fix(safety): SOS push to closed apps, late Medical ID, HTTP SOS never refused
       gateway/src/push.js gateway/src/convoys.js gateway/src/config.js gateway/src/routes.js gateway/deploy/.env.example
       gateway/test/sos_push_medical_362.test.js
       android/app/src/main/kotlin/space/devmonks/coroute_app/CoRouteMessagingService.kt
       lib/domain/notify/push_routing.dart lib/presentation/widgets/push_router_host.dart test/group_sos_push_362_test.dart
   (make it right after 15, before 12). The Kotlin file could not be compiled where it was written: build it first
   and fix any compile error without changing behaviour.
   QA: v) phone B force-stops CoRoute (swipe away) during a ride; A raises SOS -> B gets "SOS: <A> needs help"
   with the alarm sound within seconds, even in Do Not Disturb if alarms are allowed; tap -> app opens on the ride
   with the SOS card. A cancels -> B's notification changes to "<A>'s SOS is closed". With app push muted in Android
   for "Friends" the SOS still shows. w) slow network on A's profile (or a test account with Medical ID): the group
   sees the Medical ID on the SOS card within ~15 s. x) 15 SOS presses within a minute over HTTP: none refused.

O) ROUND 20 (communities_chat_v360.md sections 14 and 15): phones stay signed in (sweep keeps live phone sessions,
   lost-reply refresh grace on phones, expired long tokens renewed, secure storage never wiped, admin Phone sign-in
   rule for new sign-ins only) and the web admin command center / configuration portal / feature switches / palette.
   Commit as:
   17. fix(sessions): phones stay signed in; admin phone sign-in rule for new sign-ins
       gateway/src/sessions.js gateway/src/session_settings.js gateway/src/auth.js gateway/src/config.js
       gateway/src/app.js gateway/src/routes.js gateway/deploy/.env.example gateway/test/sessions_stay_362.test.js
       lib/data/local/secure_store.dart lib/data/services/api_client.dart lib/data/local/roster_store.dart
       lib/data/local/sensitive_prefs.dart lib/data/services/offline_link/offline_link_service.dart
   18. feat(admin): command center, configuration portal, feature switches on the web, command palette
       gateway/public/admin/command.js gateway/public/admin/command.css gateway/public/admin/session_settings.js
       gateway/public/admin/index.html gateway/public/admin/admin.js
   QA: z1) a phone signed in today is still signed in after: airplane mode for an hour mid-refresh, force stop and
   reopen, a reboot, 31 days unused (set lastSeenAt back on a test session), and an app update. z2) web admin opens on
   Command center; numbers update every 15 s; Pause works; Ctrl+K finds "Feature switches"; turning a non-safety switch
   off asks a reason and shows in Recent admin actions; SOS / crash show "Always on". z3) Phone sign-in: save 30 / 0 ->
   a NEW phone sign-in gets the rule; a phone signed in before keeps working after 31 days; save 0 / 0 again.

P) ROUND 21 (communities_chat_v360.md section 16; docs/intelligence/INTEL_DATABASE.md, INSIGHTS_v3.62.md): QA fixes,
   security hardening, own intelligence database + insights. Commit as (use `git status` to place every changed file;
   nothing may be left out):
   19. fix(qa): double taps / double submits, operator console on phones, admin styles under CSP
       gateway/public/operator/* gateway/public/admin/* (except intel.js) gateway/public/assets/signin.js
       gateway/public/assets/account.js lib/presentation/rider/widgets/join_requests_card.dart
       lib/presentation/rider/widgets/gathering_card.dart lib/presentation/garage/garage_screen.dart
       lib/presentation/social/people_screen.dart gateway/test/qa_e2e_timing_362.test.js test/qa_double_tap_362_test.dart
   20. fix(security): input guard, 2-step race, refresh replay cap, SOS push cap
       gateway/src/input_guard.js gateway/src/ws.js gateway/src/auth.js gateway/src/sessions.js gateway/src/convoys.js
       gateway/test/security_362_hardening.test.js
   21. feat(intel): own intelligence database, insights (popular roads, route difficulty, stops, trends, risk)
       gateway/src/oracle/intel_store.js gateway/src/intel/* gateway/src/app.js gateway/src/config.js
       gateway/deploy/.env.example gateway/public/admin/intel.js lib/domain/intel/route_difficulty.dart
       lib/presentation/trip_planner/trip_planner_screen.dart gateway/test/intel_362_*.test.js
       test/route_difficulty_362_test.dart docs/intelligence/*
   QA: z4) every cockpit / admin / operator button double tapped: one action. z5) operator console on a phone: menu
   opens and closes. z6) Plan a ride with a route: the difficulty chip shows (or nothing without data). z7) web admin
   Insights loads; with INTEL_SODA_URL set on a staging pair, run INTEL_DB_MIGRATE=1 and watch Main -> Copying ->
   Own database; then remove INTEL_DB_MIGRATE. z8) a recovery code used twice at once: one succeeds.

=== 2. COMMITS (round 17, after round 16's commits 1-8) ===
1. feat(gateway): communities public/private, join requests, picture, hosted rides
   gateway/src/crews.js gateway/src/crew_routes.js gateway/src/community_routes.js gateway/src/crew_ride_invites.js
2. feat(gateway): ride join codes with letters and digits, host approval
   gateway/src/convoys.js gateway/src/config.js gateway/deploy/.env.example gateway/deploy/route_split.md
   gateway/deploy/caddy/Caddyfile.vm1 gateway/test/ride_join_approval_360.test.js gateway/test/gateway.test.js
   gateway/test/operators_356.test.js
3. feat(gateway): friend and community chat (text only, 90 days), rides together, notices always pushed
   gateway/src/chat.js gateway/src/push.js gateway/src/social_routes.js gateway/test/push_355.test.js
   gateway/test/push_two_node_355.test.js
4. feat(gateway): features and limits by plan; phone sessions without a time limit
   gateway/src/plans.js gateway/src/routes.js gateway/src/feature_flags.js gateway/src/explore.js
   gateway/src/sessions.js gateway/test/security_357.test.js gateway/test/communities_chat_360.test.js
5. feat(admin): Features by plan        gateway/public/admin/plan_features.js gateway/public/admin/index.html
6. docs(privacy): chat and communities   gateway/public/privacy.html
7. feat(app): communities (find, join, requests, picture, rides), chat, rides together
   lib/data/services/communities_service.dart lib/data/services/chat_service.dart
   lib/data/services/plan_features_service.dart lib/data/services/crews_service.dart lib/main.dart
   lib/presentation/social/ lib/presentation/chat/ lib/presentation/shell/shell_badges.dart
   lib/domain/notify/push_routing.dart lib/presentation/widgets/push_router_host.dart
8. feat(app): join approval, one-tap map-only cockpit, speed warning in the ride
   lib/data/services/convoy_service.dart lib/presentation/home/join_waiting_screen.dart
   lib/presentation/home/ride_start_view.dart lib/presentation/rider/live_cockpit_map_screen.dart
   lib/presentation/rider/widgets/join_requests_card.dart lib/presentation/rider/widgets/glove_quick_settings_modal.dart
9. feat(app): fewer settings and profile rows; push, siren and lock-screen cockpit always on; operators in the app
   lib/data/services/settings_service.dart lib/data/services/push_service.dart
   lib/presentation/settings/settings_screen.dart lib/presentation/account/ lib/presentation/engagement/rate_and_feedback.dart
   lib/presentation/admin/admin_nav.dart lib/presentation/admin/admin_plan_features_screen.dart
10. test(app): v3.60          test/v360_pure_test.dart test/push_routing_355_test.dart test/settings_minimal_355_test.dart
    test/settings_lock_cockpit_migration_test.dart test/round9_settings_live_test.dart test/profile_minimal_test.dart
    test/ui10_home_sections_test.dart
11. docs(v3.60): communities_chat_v360.md and this prompt
    docs/features_355/communities_chat_v360.md docs/NEXT_AGENT_PROMPT_v3.55_round17_communities_10032.md
    Before commit 12: make commits 13 to 21 (section 1, L to P).
12. chore(release): 3.55.0+10032   pubspec.yaml (+ checksums as in 10030)
   After commit 12: `git status --short` shows only _incoming/ (and ignored caches).

=== 3. TESTS ===
- cd gateway && npm test -> expect 1508 tests, 0 failures. If public_ride_mirror or two_node_failover time out,
  re-run those two files alone (timing tests); a repeat failure alone is a real bug.
- node deploy/gen_caddy_routes.js -> no change after commit 2.
- flutter analyze -> 0 issues. flutter test -> all pass. Expected intentional changes are already in the tests
  listed in commit 10. Likely more to update ON PURPOSE (report each): tests that tap the cockpit map expecting the
  sheet to collapse (now: hides controls), tests that find 'settings_speed_warning', 'settings_siren_alerts',
  'settings_push_notifications', 'settings_lock_screen_cockpit', profile rows removed, numeric join codes,
  "Crew name" / "Create crew" texts (now "Community"). Never remove an SOS / Emergency assertion.
- Add widget tests for: JoinWaitingScreen (pending -> approved pops true), JoinRequestsCard (Let in calls approve),
  ChatThreadScreen (send shows a pending bubble, then the sent one; closed chat shows the reason), cockpit map tap
  hides HUD and keeps the SOS button (key of RideSosButton) on screen.
- dart tool/play_policy_scan.dart -> 0 hits.

=== 4. BUILD ===
flutter build appbundle --release (3.55.0+10032), same signing as 10030.

=== 5. DEVICE QA (two phones A and B; also a 320 dp emulator with the largest font) ===
a) Communities: A creates a PRIVATE community with a picture; B finds it (Community > Find communities), sees only
   name / picture / size, asks to join; A gets a push, approves in Join requests; B is in. A removes B. A makes it
   PUBLIC; B joins at once and sees members and rides before joining.
b) Hosted ride: A plans a ride (tomorrow 6 am); B gets a push, taps Interested, then Not interested; counts change.
   A edits and cancels. At ride time A starts a ride from the community Rides tab and invites; B joins without a code.
c) Join approval: A starts a ride; code has letters and digits. B enters the code (lower case works): "Waiting for
   the host". A's cockpit shows "B wants to join": Not now -> B sees "Not let in"; B asks again after 10 min, A taps
   Let in -> B is in within seconds. A rider already in the ride re-joins after a network drop without approval.
d) Chat: A and B friends: Message from B's profile; text both ways, unread badge on Chat tab, read clears it; long
   press -> Copy / Delete. Community chat for a community of <= 50. Unfriend -> chat closed. No image / file option
   anywhere. While B is on a ride: A's messages arrive with NO notification and no sound; after the ride the badge
   shows them. Ride alerts (regroup, stopped rider) never raise the Chat badge.
e) Push: with B's app open on Home, a friend request from A still shows a notification (exactly one).
f) Friend profile: Rides together lists rides both took.
g) Settings: no speed warning, push, siren or lock-screen switches. Cockpit quick settings has "Speed warning
   (km/h)" chips and the warning applies. Lock-screen cockpit works with the phone locked. Siren alerts work.
   Profile shows the short list; Help & feedback has Rate CoRoute.
h) Cockpit: tap the map -> only the map and the SOS button; tap again -> everything back. While hidden, trigger a
   test alert (or have B ask to join) -> controls come back. SOS hold works while hidden.
i) Sessions: leave the phone signed in; set the device clock forward 90 days (or wait for the next prompt-free day
   after QA) -> still signed in. Sign out / sign out everywhere still sign out at once.
j) Admin: web admin Payments > Features by plan: turn off "Create communities" for Community (free) on a test
   account without a plan -> app hides creation (toast) and the API answers PLAN_FEATURE; set chat limit 2 ->
   community chat closes for a 3-member community; restore defaults. Same page in the in-app admin (System > By plan).
k) Operators: Profile > Run a club or tour on CoRoute -> apply; web admin Operators approves; the app shows
   "approved" and Open operator console opens /operator.
l) Safety regression: SOS, crash alarm, ride lock, Medical ID, guardians, lock-screen cockpit.

=== 6. PLAY SCREENSHOTS ===
Re-capture real screenshots (phone + tablets) for Home, Explore, Community (a community page with rides), Chat and the
cockpit (controls hidden and shown). Data-safety form: add "Messages (other in-app messages)": collected, shared with
the recipients only, deleted after 90 days, user can request deletion (account deletion). Report the exact answers.

=== 7. DEPLOY ===
deploy/release.sh as for 10030 (both VMs). Set nothing for RIDE_JOIN_APPROVAL / SESSION_APP_* (defaults are the
owner's choices). Check: /privacy#chat-communities; web admin Features by plan loads; GET /api/communities/discover
answers for a signed-in rider.

=== 8. PLAY ===
Internal testing; release notes: "Communities you can open to everyone or keep private, ride plans with
'interested', text chat with friends and communities, hosts let riders in, and a cockpit that clears to just the map
with one tap. New: riders can meet at a spot first, faster re-routing, one clean top bar, hands-free and private
talk, and controls for the left hand."

=== 9. OWNER DECISIONS (already decided, 15 Nov; do not change) ===
- Riders stay signed in (no forced sign-out, no time limit on phones).
- Safety is free for everyone; every feature in Features by plan is OFF on Community (free), ON for group plans.
- Community size is the admin's choice per plan (2 to 100); chat limit chatMembersMax (default 50).
- No spoken off-route / re-route lines; no black Ride AOD; one combined cockpit top bar; short sheet; talk modes
  (hold / hands-free / private); left-hand controls option.
Report anything else that needs an owner decision; do not decide it.
```
