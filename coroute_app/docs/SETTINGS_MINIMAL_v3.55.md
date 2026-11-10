# Minimal settings (v3.55)

Owner direction: "Make the user's settings minimal and make most of them default, for the security
and safety of users." Also: "simple, understandable. Less text, more understanding."

What changed:
- Safety features are always on. They have no switch.
- Siren alerts have a switch again (owner decision, Nov 9 late): Settings › Ride › **Siren alerts**,
  on by default.
- The Settings screen keeps 11 rows in 3 small groups.
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
| Emergency texts (SMS fallback) | Switch, asked for SEND_SMS (**off**) | **Fixed** | On | Safety: an undelivered SOS must still reach people. Without SEND_SMS (Play build), the texts open in the messages app, ready to send. SMS charges apply |
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
| Give way to the | Auto/Left/Right (Auto), with siren alerts | **More** | Auto | Rarely changed. The row hides when `sirenDetector` is off |
| Safety report in my score | Score screen only (on), admin `riderScore` | **More** (also stays on the score screen) | On | Privacy is the user's choice. Turning it off deletes the counts already sent |
| Help nearby riders | Switch (on) | **More** | On | Privacy and consent (assist network) |
| Ask nearby riders to help me | Switch (on) | **More** | On | Privacy and consent: shares my SOS with nearby strangers |
| Fuel (tank range) | Link | **More** (link) | Data | Data, not a setting |
| Offline maps, Permissions, Phone check, Features guide | Links | **More** (links) | n/a | Tools and help |
| Hardware PTT button | Intercom dock | unchanged (dock) | Off | Not a Settings row |
| Share fuel estimate | Fuel sheet | unchanged (sheet) | Off | Privacy, kept beside the data it shares |

Settings that were already fixed before 3.55 keep their values: emergency voice, after-dark voice,
tunnel mode, the rich ride notification, saving route maps on Wi-Fi, and how long a map alert stays.
No technical setting such as bitrate, cadence, debug or tile cache is exposed to riders.

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
