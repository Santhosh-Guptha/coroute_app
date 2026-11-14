# Round 11 UI notes: v3.58 redesign (shell, Home, Explore, Community, Chat, Profile, Welcome)

Plan and screen map: `docs/design/REDESIGN_v3.58.md`. Build stays 3.55.0+10029.
Mock screenshots (HTML/CSS, Playwright, 412x915, dark + light):
`/tmp/claude-0/-home-claude/1c17a96b-6b0c-5ea8-aa7f-588a7257965d/scratchpad/redesign/` (`<screen>_<theme>.png`,
`*_full.png` for long pages; generator `../mockgen/gen.py`, renderer `../mockgen/render.py`).

## Files

New (app)
- `lib/presentation/shell/coroute_nav_bar.dart`: bottom bar Home · Explore · + · Community · Chat (48 dp+, badges spoken).
- `lib/presentation/shell/quick_actions_sheet.dart`: "+" sheet (Emergency first, solo, group, join, plan, suggest).
- `lib/presentation/shell/shell_badges.dart`: alerts / community / chat badge counts (same rules as before).
- `lib/presentation/home/home_screen.dart`: new Home. `home/device_safety_facts.dart`: Nearby devices + phone check facts.
- `lib/presentation/explore/explore_screen.dart`, `explore/ride_detail_screen.dart`.
- `lib/presentation/social/community_screen.dart`, `social/communities_rail.dart`, `social/club_widgets.dart`.
- `lib/presentation/chat/chat_list_screen.dart`.
- `lib/presentation/onboarding/welcome_screen.dart`.
- `lib/core/ui/place_art.dart` (shared, exported by ui.dart): `PlaceArt`, `CarouselDots`, `SectionTitle`, `InfoPill`.
- `lib/domain/explore/destinations.dart`, `domain/home/safety_nudges.dart`, `domain/home/home_feed.dart`,
  `domain/profile/riding_checklist.dart` (pure).
- `lib/data/services/explore_service.dart`, `data/services/clubs_service.dart`, `data/local/rider_prefs_store.dart`.

Changed (app)
- `lib/presentation/rider/rider_home_screen.dart` (Agent H's folder, shell part only, announced): `HomeTab` gains
  `explore` and `chat`; bodies Home/Explore/Community/Chat; `CoRouteNavBar` replaces `NavigationBar`; the old
  `_AlertsNavIcon` moved to `ShellBadges`; the People tab opener is no longer registered (`PeopleScreen.open`
  pushes the hub). Cockpit, notifications, back handling unchanged.
- `lib/presentation/home/ride_start_view.dart`: `alertFor()`, `OfflineSoloCard`, `BikeStatusCard` are public (reused).
- `lib/presentation/account/account_screen.dart`: redesigned Profile; every key / title its tests use is kept.
- `lib/presentation/social/people_screen.dart`: `focusSearch`.
- `lib/presentation/auth/login_screen.dart`: `startInRegister` (Welcome "Get started").
- `lib/presentation/splash/splash_screen.dart`: first launch opens Welcome (signed-out returning riders: sign in).
- `lib/data/services/friends_service.dart`: `coverUrl`, `saveCover`, `removeCover`; `domain/social/friends_models.dart`: `coverPathOf`.
- `lib/data/services/avatar_image_codec.dart`: `renderCover` (wide cut, no metadata).
- `lib/data/services/ride_chat_store.dart`: `archivedRides()` for the Chat tab.

Gateway
- New `src/destinations.js` (curated destinations), `src/covers.js` (cover photo).
- `src/routes.js` (registration), `src/social_routes.js` (cover routes, erase, admin removal, `coverUrl` for self
  and friends only), `src/route_policy.js` (2 public routes), `src/config.js` + `deploy/.env.example`
  (`DESTINATIONS_ENABLED`), `deploy/route_split.md` (cover rows; destinations are covered by `/api/public/*` and
  `/api/admin/*`). `node deploy/gen_caddy_routes.js --check`: complete.

Tests
- Pure (run with `tool/pure_dart_test/run.sh`): `test/ui10_explore_ranking_test.dart` (8), `ui10_nudge_rotation_test.dart` (10),
  `ui10_profile_checklist_test.dart` (6): all pass.
- Widget (need the Flutter SDK): `test/ui10_shell_nav_test.dart`, `test/ui10_home_sections_test.dart`.
- Updated for the new shell: `test/behaviour_regressions_test.dart`, `test/e2e/ui_level_test.dart`,
  `test/e2e/application_level_test.dart` (first launch = Welcome).
- Gateway: `test/destinations_358.test.js`, `test/covers_358.test.js`.

## Endpoints

| Method | Path | Policy | Notes |
|---|---|---|---|
| GET | /api/public/destinations | public | active places, admin order; 60 s node cache, `Cache-Control: public, max-age=300`, ETag/304 |
| GET | /api/public/destinations/:id/photo | public | admin photo of an active place only |
| GET, POST | /api/admin/destinations | admin | list (inactive too) / create |
| PATCH, DELETE | /api/admin/destinations/:id | admin | audited (`destination.*`) |
| POST, GET, DELETE | /api/admin/destinations/:id/photo | admin | raw JPEG/PNG/WebP, 2 MB, EXIF stripped, disk or Object Storage |
| POST | /api/me/cover/original | auth | private original (owner only), `cvo_` id |
| POST | /api/me/cover | auth | public wide cover; `?original=&cx=&cy=&zoom=&rot=` keeps the original |
| GET | /api/me/cover/original | auth | owner only |
| DELETE | /api/me/cover | auth | removes cover + originals |
| GET | /api/covers/:coverId | auth | 404 for riders the owner blocked |
| DELETE | /api/admin/users/:userId/cover | admin | moderation, audited `user.cover.remove` |

Existing APIs now used by the app: `GET /api/clubs`, `POST /api/clubs/invites/:id/accept|decline`,
`POST /api/clubs/join`, `GET /api/intel/{hazards,road-quality,twisty,stops}?tiles=`, `GET /api/intel/ride-tip`,
`GET /api/me/score`, `GET /api/me/leaderboard`.

## Decisions worth knowing
- SOS: Home's safety strip has a red "Emergency" button above the fold (opens the existing SOS sheet: call contact /
  112, live link, Medical ID); Emergency is the first row of "+"; the reconnecting alert and the offline solo card keep
  their SOS; Welcome and sign in keep "Call 112". The cockpit is untouched.
- Distances are computed on the phone (straight line x 1.3, 45 km/h); the rider's position never goes to the server.
- Ride detail preview draws an honest straight guide line (no routing call per destination; the planner routes).
- "Request to join" is not offered: clubs are invite / link only today. "Join with a code" and invites instead.
- Cover photo is a centre cut (8:3, 1600 px) of the picked picture; re-framing UI is a follow-up (the original is kept).
- Riding interests / style live on the phone only.
- Membership status chip stays on Home (unchanged component; shows nothing unless plans are enforced).

## Device QA (U-items)
- U1 First launch: Welcome in light and dark; "Get started" opens Create account, "I already have an account" opens
  Sign in; Call 112 dials; Back from Sign in returns to Welcome.
- U2 Sign out (Profile) lands on Welcome with the stack cleared.
- U3 Bottom bar: 4 destinations + "+", 48 dp targets with gloves, haptic on tap; Community badge = requests; Home
  badge = alerts; nothing highlighted on Profile / Alerts / Trips; Android Back from any tab returns to Home.
- U4 "+" sheet: Emergency opens the SOS sheet (nothing is sent by opening it); solo / group / join keep their gates
  (safety details, phone check, permissions, bike details).
- U5 Ride start: the cockpit replaces Home and the bar hides; ride end returns to Home with "Ride saved".
- U6 Home: greeting by time; theme toggle flips light/dark; avatar opens Profile; bell opens Alerts.
- U7 Carousel auto-advances every 6 s, stops while touched, does not move with "Remove animations" on.
- U8 Nudge: fresh account shows emergency contact; "x" shows the next one; returns after 3 days if still missing;
  "Allow" for Nearby devices shows the system prompt (Android 12+), app settings when blocked.
- U9 Communities rail: crew invite -> People requests; club invite Accept; Join a club with a code; Start a crew.
- U10 Stats: km / rides from trips, score, leaderboard rank; "Full view" opens the score screen.
- U11 Explore offline: the saved list shows with "Offline" line; online: fresh list; chips filter; search; empty state.
- U12 Ride detail: preview map, road intel (or the "not enough data" line), Plan group ride opens the planner with
  the destination filled, Navigate opens Google Maps / Mappls.
- U13 Admin uploads a destination photo (API): it shows on Explore after <= 5 minutes; inactive places disappear.
- U14 Chat: empty state without rides; live ride card during a ride; archived ride chats open read only.
- U15 Profile: add / remove cover (EXIF-free on the server), checklist progress updates after each step, Notifications
  sheet, Theme, Safety & emergency, Invite friends, Advanced = Settings.
- U16 320 dp phone at text 1.3 and a tablet: no overflow on all new screens; TalkBack reads nav slots with badges,
  checklist items as checked / not checked.

## For the lead
- Web admin UI for destinations (`/api/admin/destinations*`) is needed (gateway/public/admin not touched).
- Proposals (not built): public club directory with "Request to join"; crew chat threads; server sync of riding
  interests; cover re-frame UI.
