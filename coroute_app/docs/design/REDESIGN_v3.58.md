# CoRoute redesign v3.58: shell, Home, Explore, Community, Chat, Profile, Welcome

Owner request: screens in the spirit of the competitor references (layout ideas and quality bar only), with all
CoRoute features, in CoRoute's own identity (teal, Manrope, design system v3.55 tokens, light + dark, motto
"Ride together. Stay safe."). No competitor names, logos, taglines, text or photos are used anywhere.

Build stays 3.55.0+10029. The navigation HUD / cockpit is Agent H's (lib/presentation/rider, lib/presentation/ride);
this document covers everything around it.

## 1. Navigation map

```
Splash ──signed out──> Welcome ──Get started──────────> Create account (LoginScreen, register mode)
                              └─I already have an account> Sign in (LoginScreen: password, Google, verify,
                                                            ride lock dialog, "Emergency? Call 112")
Splash ──signed in──> App shell (RiderHomeScreen)

App shell: bottom bar  [Home] [Explore] ( + ) [Community] [Chat]
  Home ............ HomeTab.ride   (no ride: new HomeScreen; ride active: the cockpit, bar hidden as today)
  Explore ......... HomeTab.explore
  +  .............. Quick actions sheet (not a tab)
  Community ....... HomeTab.people  (CommunityScreen; the full People hub opens from it)
  Chat ............ HomeTab.chat
  hidden tabs ..... HomeTab.trips (My trips), HomeTab.alerts (bell), HomeTab.profile (avatar)
                    Opened from Home's header / Profile; the bar shows no selection; Back returns to Home.
```

`RiderHomeScreen.selectTab(context, HomeTab.x)` keeps working for every existing caller (cockpit "Alerts",
trips "New ride", alerts "Show on map").

## 2. Screens and where every feature goes

### Quick actions (+)
Start solo ride (offline solo, crash detection + SOS by text) · Plan / start a group ride (trip planner, profile
and phone-check gates unchanged) · Join with a code · Plan a trip (planner) · Suggest a place (feedback) ·
Emergency (red row: the existing SOS sheet with call contact / 112, Medical ID, live link).

### Home (no ride)
| Block | Source |
|---|---|
| Greeting by time of day + first name | `RideStartView.greetingFor`, AuthService |
| Header: Alerts bell (badge), theme toggle, avatar → Profile | TimelineService/ConvoyService badge, ThemeController, FriendsService avatar |
| One alert slot (reconnecting + SOS, add safety details, ride ended, ride saved), admin warning | unchanged from the old Home |
| Hero carousel: Rides near you → Explore · Start a group ride · Your last ride · Safety check before you ride | Explore data, startRide, TripStorageService, PreRidePhoneCheckScreen |
| Safety strip (calm): crash detection, emergency contact, offline SOS, and an Emergency button | SettingsService, AuthService, EmergencySosSheet |
| Rotating nudge (dismissible, comes back after 3 days if still missing): emergency contact, Medical ID, Nearby devices, crash detection | `lib/domain/home/safety_nudges.dart` |
| Solo ride (offline) card while it runs: status, SOS, end | the old `_OfflineSoloCard` logic, moved |
| Riding communities: crews (Open), crew / club invites (Accept), clubs (Open), Join a club with code, Start a crew | CrewsService, new ClubsService (GET /api/clubs) |
| Your ride stats: km, rides, rider score, leaderboard rank, Full view | TripStorageService/HomeAnalytics, RiderScoreService |
| Upcoming: ride invites, club rides, open crew polls | RideInvitesService, ClubsService, CrewsService |
| Bike status: range, intercom, garage | the old bike status list |
| Pending trip review check | `PendingTripReviewCheck` (unchanged) |

### Explore
Search + Add · "Rides near you" with chips All / Breakfast / Night / One day / Weekend / Twisty roads / Ghats ·
ranked by straight-line distance × 1.3 road factor from the rider's last fix · #1 as a hero card, then a list with
thumbnail, category, ~km, ~time · "Public rides near you" (live public groups from the discovery feature, when
switched on). Data: new admin-curated destinations (gateway `src/destinations.js`).

### Ride detail
Gradient / admin photo header · ~km, ~time, category · route preview (flutter_map + `appTileLayer`, straight
guide line, honest label) · Road intel along the way (anonymous k-anonymous cells): hazard hotspots, rough road,
twistiness, where riders stop, risky times (ride tip), fuel note · Ride solo / Plan group ride (trip planner with
the destination filled in) / Navigate (Google Maps / Mappls hand-off).

### Community
Header + share invite · search riders (opens the People hub search) · requests waiting · crews & clubs rail ·
leaderboard + rider score card · friends preview and "People you rode with" · links to the full People hub
(friends, crews, requests unchanged).

### Chat
Live ride chat (active ride → opens the cockpit chat) · ride chats kept on this phone from the last 10 rides
(read only, opened in the trip report) · crews have no message thread: a clear empty state says chat opens with a
ride. No new messaging backend (proposal below).

### Profile (avatar on Home)
Cover photo (new, owner-only original + public cover) + avatar (round 6 adjust flow) · name, @username,
"Riding since <month year>" · "Complete your riding profile" checklist with progress (bike, emergency contact,
Medical ID, avatar, Nearby devices, pre-ride check, riding interests) · My preferences (bike, riding style,
interests) · Rider score card · My rides (upcoming + recent, trip reports) · Settings & info: My trips, Account,
Notifications, Theme, Safety & emergency, Privacy, Invite friends, Rate the app, Help & support, Leaderboard,
Admin (admins), Advanced (Settings) · Sign out (existing SignOutFlow) · Delete account (existing two-step).

### Welcome
CoRoute mark (assets/branding/coroute_icon.png) · "Ride together. / Stay safe." · one line: crash detection,
SOS without signal, live group tracking and helmet intercom · Get started · I already have an account ·
Emergency? Call 112.

## 3. SOS is never buried
- Cockpit: unchanged (Agent H).
- Home: the safety strip's red "Emergency" button sits right under the hero, visible without scrolling on a
  320x568 phone; the reconnecting alert keeps its SOS; the offline solo card keeps SOS.
- The + sheet has Emergency as its first row.
- Welcome / sign in: "Emergency? Call 112". Lock screen Medical ID and the app-lock emergency button unchanged.
- Safety routes stay instant (`safety/` route names untouched).

## 4. What is better than the reference
- Safety visible but calm: a status strip (crash detection, contact, offline SOS) + one Emergency button.
- One rotating nudge instead of a permanent banner; it comes back only while something is still missing.
- Explore shows road intel the competitor does not have: hazard hotspots, rough road, twistiness, rider stops,
  risky times, fuel note; and ranks by real distance from you.
- Profile checklist includes the safety items that matter (Medical ID, Nearby devices for SOS without signal,
  pre-ride phone check), not just interests.
- Placeholder art is our own gradient + line illustration: no stock photos, nothing hotlinked.
- Reduced motion: carousel does not auto-scroll; skeletons, cached data first, 48 dp targets, text scale 1.3.

## 5. Admin / lead requests
- Web admin UI for curated destinations (`/api/admin/destinations*`, MASTER_ADMIN): list, add/edit, photo upload,
  active switch, delete. API is done; gateway/public/admin is not mine.
- Public club directory with "Request to join": clubs are invite / link only today. Proposal: an opt-in
  `listed` flag on approved operators + `POST /api/clubs/:operatorId/requests` reviewed in the operator console.
  The app shows "Join with a code" until then.
- Persistent crew chat: not built (no new messaging backend). Proposal: crew threads on the existing crew
  store with the same moderation as ride chat (report queue, hide), 30-day retention.
- Riding interests / style are kept on the phone only; proposal to sync them with `/me/profile`.

## 6. Mock screenshots
Static HTML/CSS mocks mirroring the Flutter layouts (Welcome, Home, Explore, Ride detail, Community, Chat,
Profile), rendered at 412x915 in dark and light:
`/tmp/claude-0/-home-claude/1c17a96b-6b0c-5ea8-aa7f-588a7257965d/scratchpad/redesign/<screen>_<dark|light>.png`.
Files, endpoints and device QA: `docs/quality/ROUND11_UI_NOTES.md`.
