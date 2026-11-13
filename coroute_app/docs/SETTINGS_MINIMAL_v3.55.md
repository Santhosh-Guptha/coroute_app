# Minimal settings (v3.55)

> Round 9 (Nov 13) reduced the settings further and fixed more defaults: see
> `docs/quality/ROUND9_SETTINGS_NOTES.md` (it supersedes the rows below for voice alerts, battery saver, the Ride
> screen choices, the music choices, the road safety switches and voice clarity).

Owner direction: "Make the user's settings minimal and make most of them default, for the security
and safety of users." Also: "simple, understandable. Less text, more understanding."

What changed:
- Safety features are always on. They have no switch.
- Siren alerts have a switch again (owner decision, Nov 9 late): Settings › Ride › **Siren alerts**,
  on by default.
- The Settings screen keeps 12 rows in 3 small groups (Safety health joined the Safety group on Nov 11).
- Less-used choices sit under one collapsed **More settings** row.
- Quick settings in the cockpit show 3 big toggles.

Screenshots of the HTML replica (390x844, design tokens from `lib/core/theme/app_palette.dart`) are in
`docs/settings_minimal_355/`: `light.png`, `dark.png`, `light_more.png`, `dark_more.png`,
`quick_light.png` and `quick_dark.png`.

## Decision table

**Visible** means the row is on the main screen. **More** means it is under "More settings" (one tap).
**Fixed** means it has no UI and the value is fixed.

| Setting | Before (default) | Now | Value | Why |
|---|---|---|---|---|
| Crash detection | Switch, off asked to confirm (on) | **Fixed** | On | Safety: a crash with detection off reaches nobody |
| SOS, incl. lock-screen SOS | No switch | **Fixed** | On | Safety |
| Ride on lock screen (distances + SOS button) | Switch (on) | **Fixed** | On | The SOS button must be reachable without unlocking. Other groups' emergencies show no names |
| Emergency texts | Switch, asked for SEND_SMS (**off**) | **Fixed** | On | Safety: 3.57 phone-first, every SOS texts the emergency contacts from the rider's SIM by itself (SEND_SMS asked after the disclosure; "safe now" follow-up always on); an undelivered SOS also texts the group. SEND_SMS denied: the texts open in the messages app, ready to send. Carrier SMS charges apply |
| Medical ID on the lock screen | No switch | **Fixed** | On | Already mandatory |
| "Are you OK?" check-in (far from group) | Switch (on) | **Fixed** | On | Safety |
| Solo ETA check-in | Switch (on), admin `soloCheckIn` | **Fixed** | On | Safety. Still needs an emergency contact; the admin switch still applies |
| No-signal ahead | Switch (on), admin `noSignalAhead` | **Fixed** | On | Safety. The admin switch still applies |
| Break reminder | Switch (on) | **Fixed** | On | Fatigue safety |
| Road / accident warnings | Switch (on) | **Fixed** | On | Safety |
| Critical alerts pause music | No switch | **Fixed** | On | P0 already pauses other audio (VoiceService) |
| Auto re-route | Switch (on) | **Fixed** | On | Safety: never ride on without a route |
| Clean up my voice (intercom) | Switch (on), admin `voiceCleanup` | **Fixed** | On | Clear group talk. The admin switch still applies |
| Keep screen on while riding | Quick settings toggle (on) | **Fixed** | On | The rider always sees alerts. Battery saver may dim the screen |
| Battery kept for SOS, arrival message to guardians | No switch | **Fixed** | On | Unchanged |
| Settings apply live | No switch | **Fixed** | On | Unchanged (SETTINGS_LIVE_AUDIT_v3.55.md) |
| Emergency contact & Medical ID | Link | **Visible** (link) | Data | This is data, not a setting. The row turns amber when no contact is set |
| Speed warning (personal limit) | Chips (group limit) | **Visible** | Group limit / 50-120 | The warning is always on. The rider picks only the limit |
| Voice alerts | Switch (on) | **Visible** | On | User choice. Emergencies are always spoken |
| Siren alerts | Switch (on), admin `sirenDetector` | **Visible** (Ride) | On | Owner decision: a switch, on by default. Subtitle "Listens on your phone during rides. Nothing is recorded." Off releases the microphone at once (the mic stays open only if the intercom needs it). The row hides when the admin switch is off |
| Language | Dropdown (system) | **Visible** | System | There are 4 options (System, English, Hindi, Telugu) |
| Battery saver | Switch (off; turns itself on at 20 %) | **Visible** | Auto | User choice. SOS and crash detection never reduced |
| Data saver | Switch (off) | **Visible** | Off | User choice |
| Appearance (night mode) | Link | **Visible** (link) | Automatic | User choice |
| Push notifications | Switch (on) | **Visible** | On | User choice. Hidden when the build has no push |
| Show me on leaderboards | Profile only (on) | **Visible** (also stays on Profile) | On | Privacy is the user's choice. Shown when the profile is loaded |
| Pause music for alerts (vs lower) | Switch (off) | **More** | Off (lower) | Comfort |
| Lower music when speeding | Switch (on), admin `speedAudio` | **More** | On | Comfort. The row hides when the admin switch is off |
| Give way to the | Auto/Left/Right (Auto), with siren alerts | **Fixed** (Nov 11) | Automatic (phone's country; India = left) | Owner decision. A stored Left / Right is reset to Automatic by migration v2 |
| Safety report in my score | Score screen only (on), admin `riderScore` | **Fixed** (Nov 11) | On | Owner decision. Counts only (never route or position). A rider who had it off: rides that ended before the migration are never sent (`coroute_rider_score_send_from_v1`). The score screen shows one plain line |
| Help nearby riders | Switch (on) | **Fixed** (Nov 11) | On | Owner decision (see *Privacy note*). Server field `assistHelp`; admin switch `assistNetwork` still pauses the feature for everyone |
| Ask nearby riders to help me | Switch (on) | **Fixed** (Nov 11) | On | Owner decision (see *Privacy note*). Server field `assistAsk` |
| Fuel (tank range) | Link | **More** (link) | Data | Data, not a setting |
| Offline maps | Link to the pack manager | **Fixed** (Nov 11), no row | Automatic | Saved at ride start, kept 7 days after the trip, 300 MB cap (see *Offline maps*) |
| Safety health (phone check) | Link under More ("Phone check") | **Visible** (Safety) | n/a | Same screen as the cockpit's Safety health tile |
| Permissions, Features guide | Links | **More** (links) | n/a | Tools and help |
| Rate CoRoute, Send feedback, Diagnostics | Rows under More (and again on Profile) | **Removed** from Settings | n/a | They live once, in Profile › Help (Diagnostics inside Send feedback) |
| Hardware PTT button | Intercom dock | unchanged (dock) | Off | Not a Settings row |
| Share fuel estimate | Fuel sheet | unchanged (sheet) | Off | Privacy, kept beside the data it shares |

Settings that were already fixed before 3.55 keep their values: emergency voice, after-dark voice,
tunnel mode, the rich ride notification, saving route maps on Wi-Fi, and how long a map alert stays.
No technical setting such as bitrate, cadence, debug or tile cache is exposed to riders.

## Round 2 (Nov 11): fixed defaults, minimal Profile, automatic offline maps

Owner direction: "make these fixed defaults and remove their rows", "Profile tab → minimal".

### Settings rows removed

Help nearby riders (on), Ask nearby riders to help me (on), Give way to the (Automatic), Safety report
in my score (on), Offline maps (automatic), and the duplicate Rate CoRoute, Send feedback and
Diagnostics rows. `SettingsScreen.removedRowKeys` lists their old keys (tests check none is shown).
The "Safety is always on" list now also names **Help nearby riders** and **Ask nearby riders to help
me**. **Safety health** moved from More ("Phone check") to the Safety group.

### Migration v2 (`SettingsService.safetyDefaultsVersion` = 2)

- Steps run once each, in order: a rider still on version 0 gets step 1 then step 2; a rider on
  version 1 gets only step 2 (siren alerts, a rider choice since step 1, are never forced again).
- Step 2 writes `give_way_side_v1` = `auto` and calls `RiderScoreService.adoptAlwaysOn`: it writes
  `coroute_rider_score_use_report_v1` = true and, only when it was false, stores
  `coroute_rider_score_send_from_v1` = now so rides recorded while it was off are never sent.
- `SettingsService.giveWaySide` always returns `auto`; `setGiveWaySide` is a no-op.
  `RiderScoreService.setUseSafetyReport(false)` is ignored.
- Help / Ask nearby riders live on the gateway profile (`assistHelp`, `assistAsk`). `AuthService`
  reports both as always on; whenever `/me` (or a sign-in) still says one is off, it sends
  `PATCH /me {assistHelp: true, assistAsk: true}` once per signed-in rider and app run. It skips this
  while the admin switch `assistNetwork` is off (the feature is paused for everyone and the rider's
  value is left alone). `updateNetworkPrefs` / `updateProfile` never send "off". The gateway is
  unchanged: its per-rider switches still exist and older apps keep working.
- The "Riders helping riders" sheet before the first ride stays (it explains the feature) but has
  no switches; Continue saves both on with the consent.

### Privacy note (owner decision)

Until Nov 11 a rider could switch off being asked to help (`assistHelp`) and other groups being asked
to help them (`assistAsk`). Per owner decision both are now always on for every rider. What is
shared did not change: before anyone accepts, riders of other groups see only the emergency point
and the distance (no name, group or phone number); after one accepts, they see the first name, the
vehicle type and colour and, while the alert is open, the medical info and emergency contact (as
already documented under "Medical info to responders", Nov 9). The rider's own phone number is
never shared. The website was updated to match: `gateway/public/privacy.html` (#nearby-help: the
"You can turn off ..." paragraph is replaced; #hard-braking now states the five per-ride counts the
rider score sends, always on; #offline-maps describes the automatic maps and retention),
`privacy-and-security.html` ("Switch things off" → "Choose the extras"), `safety.html` (nearby riders
"Always on"), `how-it-works.html` and `terms.html` (no "unless you turn off").

The group lead's group-level "nearby help" switch (`assistDefault` in group settings) is unchanged.

### Profile tab (`AccountScreen`)

Top box: picture (when profile photos are on), full name and @username; tap opens My profile (the
details: picture, username, name, stats, plus **Edit details** and **Change password**, moved there).
The gear in the box opens Settings. Then **My bikes**, **Emergency contact & Medical ID** (amber
until a contact is set), the rider score card and a **Leaderboard** row (admin switch
`leaderboard`), the Admin row for admins only, **Help** (exactly three rows: **Send feedback**,
**Rate CoRoute**, **Privacy & terms**) and **Account** (**Sign out**, **Delete account**).

Removed from Profile: Your plan (and the plan screen entries: the home plan chip is no longer
tappable, the membership push only refreshes, the features guide has no plan link; the admin console
keeps "Rider view of Your plan"), Ride history (Trips tab), Your ride analytics (Trips tab and My
profile stats), My profile row (the top box), the separate Report a problem / Suggest a safety
feature rows, Privacy policy / Terms of use rows (now the Privacy & terms sheet with **Your data** →
https://coroute.devmonks.space/privacy-and-security).

**Send feedback** is one screen: category chips (Report a problem · Suggest a safety feature · Other,
sent as `/me/feedback` topics `bug` / `idea` / `other`), the message, **Attach diagnostics log**
(off; after the message is sent it runs the same upload as Diagnostics › Send logs), **You may
reply by e-mail**, and the **View diagnostics** link (the Diagnostics screen's only entry). The ride
analytics "suggest" link opens it on "Suggest a safety feature". `ReportProblemScreen` and
`SuggestFeatureScreen` were removed.

### Safety health

The cockpit's **Safety health** tile and the Settings row open `PreRidePhoneCheckScreen.open` (fresh
check; the mic test is skipped during a ride), never Settings. The cockpit settings card keeps a
separate **Settings** row (`SecondaryManagementGroup.onOpenSettings`). Fix buttons open the specific
system page: notifications blocked for good → CoRoute's notification settings (new native
`openNotificationSettings`); background use blocked → the app's battery page (new
`PhoneCheckFix.backgroundUse`, native `openAppBatterySettings`, falling back to the battery
optimisation list, then app info); battery optimisation → the system "allow" dialog; full-screen
alarm → its system page; sound → sound settings; location / mic / Bluetooth blocked for good → the
app's permission page (app info; Android has no direct per-permission page).

### Offline maps (automatic)

- Saving is unchanged: at ride start on Wi-Fi outside data saver (SafetyService), the cockpit's
  background preparation during the ride, and the planner's background prefetch after creating a
  trip. Each now records a trip map (`SavedMapPack` with `tripId`, id `trip_<groupId>`).
- When the ride ends (`SafetyService.onTripEnded` → `OfflineMapRetentionService.tripEnded`) the
  ride's tiles are unpinned and its map gets `completedAt`.
- `OfflineMapRetention` (pure, `lib/domain/geo/offline_map_retention.dart`): keep
  `keepAfterTrip` = 7 days after the trip, `keepUnridden` = 30 days for a map whose trip never ended,
  total `maxBytes` = 300 MB with least recently used first; the ride in progress is never deleted.
  The sweep runs at app start and after every ride; it deletes the doomed maps' tiles (except tiles a
  kept map shares) and protects kept maps' tiles from the cache's own 30-day / LRU pruning.
- The tile cache default budget is now 300 MB (`SafetyConstants.tileCacheMaxBytes`).
- Past trips (trip report, replay, trip history map) use `appTileLayer(pastTrip: true)`: the online
  map first and nothing saved; any saved tile (however old) only when offline.
- The offline map manager and tile verification screens were removed (no rider UI).

## Quick settings (cockpit)

The quick settings show 3 big tiles. Each tile is at least 96 dp tall, uses about a third of the
width, and the whole tile toggles:
- **Voice** (On / Muted)
- **Night map** (On / Auto)
- **Battery saver** (On / Auto)

One line under the tiles says "Emergencies are always spoken." The Screen always on tile is gone
because the screen always stays on while riding. The constructor still accepts `keepScreenOn` and
`onToggleKeepScreenOn`, so the cockpit does not need to change. The Guardian link, Fuel and offline
nav quick actions stay.

## Migration (SettingsService)

- `SettingsService.alwaysOnKeys` lists the stored keys of every fixed safety setting: crash, SMS,
  fatigue, solo check-in, ETA check-in, no-signal ahead, hazards, lock screen, auto re-route and
  voice cleanup. Siren alerts left this list (they have a switch again).
- `load()` sets these fields to true and ignores a stored "off". `loadSoundSettings()` does the same
  for voice cleanup and reads siren alerts from `siren_alerts_v1` (default on).
- Siren alerts migration: the version-1 migration still writes siren alerts on
  (`safetyDefaultsV1Keys` = `alwaysOnKeys` + siren). A rider it already turned on stays on and can now
  turn it off; that choice is kept (the migration runs once). Nothing is ever forced off.
- The first time `load()` runs with `keySafetyDefaultsVersion` (`settings_safety_defaults_version`)
  missing or lower than `safetyDefaultsVersion` (1), it rewrites every always-on key to `true`, then
  saves the version. To add a setting later, add it to `alwaysOnKeys` and bump the version.
- The setters keep their old signatures, so callers do not change. They accept "on", refuse "off",
  and send no notification when they refuse.
- The migration never turns a setting off. Rider choices (voice, pause music, battery saver, data
  saver, speed limit, language, horn, give-way side) are never touched.
- Admin feature switches still win where they existed. A row whose admin switch is off is hidden,
  and the service still checks the switch at use time.

## Tests

Round 2 (Nov 11):
- `test/settings_minimal_355_test.dart`: migration v2 (give-way to Automatic, score report on with
  the send-from cut-off only when it was off, siren choice untouched); give-way cannot change; none
  of `removedRowKeys` with More open; Safety health is on the main screen and opens
  `PreRidePhoneCheckScreen`; the always-on list names help / ask nearby riders.
- `test/network_settings_ui_test.dart`: no nearby riders switches anywhere; "off" is never sent; a
  profile the gateway still has off is written back on once (`PATCH /me`); the consent sheet has no
  switches.
- `test/profile_minimal_test.dart` (new): top box (name, @username, gear); no plan / ride history /
  report / suggest / diagnostics / change password rows; Help has exactly three rows; Account has
  Sign out and Delete account; Privacy & terms sheet; the feedback screen's categories, diagnostics
  toggle (off) and link.
- `test/offline_map_retention_test.dart` (new): retention and LRU decisions (pure), pack fields, the
  sweep with a real tile cache in a temp folder, and `tripEnded`.
- Updated: `access_control_and_admin_regression_test`, `membership_plan_access_test` (chip not
  tappable), `minimized_cockpit_sheet_test` ("Safety health"), `services/pre_ride_phone_check_test`
  (`backgroundUse`), `offline_maps_and_navigation_test` (300 MB), `offline_map_manager_test` (pure
  parts only), `ride316_ui_test` / `route_map_pack_card_test` (fake `start` signature),
  `ui_audit_batch2/3`, gateway `live_page.test.js`. Removed: `suggest_feature_form_test.dart`.

Round 1:

- New file `test/settings_minimal_355_test.dart` checks that:
  - always-on settings are on by default, and each setter refuses "off" without notifying;
  - siren alerts are on by default, turn off and on, keep the choice, and the old forced "on" stays
    on (group "siren alerts switch");
  - the migration forces a stored "off" to on, writes the version key, and leaves rider choices alone;
  - a stale "off" stored after the migration is still ignored;
  - the screen shows 4 switches (voice alerts, siren alerts, battery saver, data saver) and none of
    the removed safety rows; the siren switch turns off with one tap;
  - More starts collapsed and opens with one tap;
  - the speed warning chips still change the value;
  - quick settings show 3 tiles of at least 96 dp and no screen-on tile.
- Updated to the new design:
  - `network_settings_ui_test`, `network_settings_test`, `low_data_test`;
  - `crash_alarm_screen_test`, `safety_service_test`, `pre_ride_checklist_test`;
  - `emergency_roster_test`, `convoy_network_test`, `ride_notification_service_test`;
  - `settings_live_355_test`, `glove_cockpit_shortcuts_test`, `ride316_ui_test` (Fuel is under More;
    the language test checks the Language label).
- The analyzer was run here. The tests were not, because the Flutter engine is not available.

## Follow-ups (owned by other areas)

- `SafetyService.alarmRunsWithDetectionOff` and the pre-ride checklist's "turn crash detection on"
  button can no longer happen. They are harmless and can be removed later.
- The cockpit `_keepScreenOn` toggle has no UI any more. It stays true. Battery saver dimming is the
  cockpit's job.
