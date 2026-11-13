# Round 9: speed limit changed mid-ride, and fewer settings (v3.55.0+10027)

Owner request (verbatim): "remove unnecessary setting options toggles make them on default reduce the settings
and one more is if in between the ride or trip if i change the speed limit its not reflecting resolve them"

Scope: `lib/**` and `test/**`. The gateway needed no change (verified, see 1.3). The build number is unchanged.

## 1. Speed limit changed during a ride

### 1.1 What can be changed, and the path of each

| Limit | Who changes it | Path |
|---|---|---|
| My own speed warning (Settings › Speed warning) | the rider | `SettingsService.setSpeedLimitWarningKmh` → notify → `SafetyService._onSettings` → `_recheckSpeedLimit` → `_checkSpeedLimit` (also on every fix) → `OverspeedGate` → `VoiceService.speakOverspeed` + the overspeed card; cockpit top bar `context.select` on the setting |
| Group speed limit / town limit (Group settings) | lead, co-lead / trip head (server-checked `canChangeSettings`, 403 `NOT_LEAD` otherwise) | `ConvoyService.updateGroupConfig` (optimistic + CONFIG) → gateway `convoys.updateConfig` → `_emit('CONFIG')` to the room and the mirror → every phone's CONFIG handler → `ConvoyModel.copyWith` → `SafetyService._onConvoy` → `_recheckSpeedLimit` |
| Road limit margin, limit sign, overspeed warning (round 7 "Bends and speed limits") | the rider (until this round) | `RoadCareService.roadPrefs` closure read on every fix → `RoadAheadEngine` → `OverspeedPolicy` |
| Vehicle profile speed cap | none exists (EV / bike profiles carry fuel and engine data only; `motorcycle` limits come from the road data) | — |
| Cockpit sign, Ride AOD, lock-screen notification, Android 16 Live Update | shows the limit | cockpit computes `effectiveSpeedLimit` in `build`; the notification reads `SafetyService.currentSpeedLimit` |

Most of the plumbing was already live (fixed by the 3.55 settings audit, `docs/SETTINGS_LIVE_AUDIT_v3.55.md`): the
limit is re-read on every fix, a settings or CONFIG change re-judges the last fix at once, the gateway applies
the new meta on the next fix and broadcasts CONFIG. What the rider saw and heard did not follow.

### 1.2 Root causes (plainly)

1. **The voice dropped the warning for the new limit.** `speakOverspeed` used the dedupe key
   `overspeed_<wall-clock minute>` with the voice's 10-minute dedupe window, and the line ("Over limit. 72 km/h.")
   never said the limit. A rider who was warned and then changed the limit (or whose lead did) within the same
   minute got a silent warning: the voice threw it away as a duplicate. The 25 s reminder of the same minute was
   dropped the same way. So the change sounded ignored.
2. **The lock-screen notification and the Live Update kept the old limit for 10-20 s.** `SafetyService` only
   notified when a prompt changed, so a new limit with no prompt change reached `RideNotificationService` only at
   its normal refresh (10 s, 20 s in battery saver), and if the convoy listener ran first it built the
   notification from the old value. The Live Update had no limit at all, and the **Ride AOD did not show a limit**.
3. **An offline solo ride never used the limit from Settings.** `_checkSpeedLimit` required a convoy ride
   (`_port.rideActive`) and the solo path returned before it.
4. **Raising my own limit above the group limit (or a lead raising the group limit above a rider's own) changed
   nothing, with no explanation.** The stricter limit wins (a deliberate safety rule, kept), but Settings showed
   only the chip the rider picked, so it looked broken.

Not causes (checked): no value copied into a ride object at start; listeners are attached (`_port` and
`_settings` in the `SafetyService` constructor); the round 7 prefs are a closure read per fix; the cockpit
rebuilds through `context.select`; the gateway broadcasts CONFIG to the whole room after the write; the mirror
replicates `meta` on every event and relays CONFIG to the peer's sockets; the app's CONFIG handler runs whatever
the ride state; the warning scheduler keeps no threshold (it only spaces road warnings); the lock-screen cockpit
is the same Flutter cockpit over the keyguard.

### 1.3 Fixes

| # | Fix | Where |
|---|---|---|
| 1 | Overspeed voice key = `overspeed_l<limit>_<second>`, dedupe window 5 s (the gate already spaces warnings 25 s), the line always says the limit: "Over limit. 72 km/h, limit 60." / "Slow down. 95 km/h, limit 65." | `lib/domain/safety/overspeed_voice.dart` (pure), `VoiceService.speakOverspeed` (`speak` gained an optional `dedupeWindow`) |
| 2 | `SafetyService` notifies when the limit it warns at changes; `RideNotificationService` pushes at once when the limit differs from the one it last showed (also after a push that was in flight); the limit rides in the Live Update text ("· Limit 60", or its own "Speed limit 60 km/h" card on a solo ride) | `safety_service.dart` `_checkSpeedLimit`, `ride_notification_service.dart` `_limitChanged`, `live_update.dart` |
| 3 | Ride AOD shows "Limit 60" (red "Over limit 60" when over) | `ride_aod_view.dart`, cockpit `_aodView` |
| 4 | The offline solo ride checks my own limit on every fix; the limit is reset at ride end and solo end (never carried into the next ride) | `safety_service.dart` |
| 5 | Settings › Speed warning has one line saying which limit warns now: "Now: group limit 80 km/h (stricter than yours)." / "Now: your limit 60 km/h (stricter than the group's 80)." | `speedWarningLine` in `effective_speed_limit.dart`, `settings_screen.dart` |
| 6 | The cockpit speed alert's spoken label says "limit", not "group limit" (it is often the rider's own) | `minimal_cockpit_overlay.dart` |

Permissions are unchanged: only the trip owner, trip head or lead can change the group limit, checked by the
gateway. **Old builds in the same ride:** nothing on the wire changed (CONFIG is the same message with the same
fields); an old build applies the new group limit exactly as before (it still has the voice dedupe issue on its
own phone).

Gateway: no change. Verified with a scratch two-node test (not committed): the lead on node A sets 60 then 100,
a member on node B and a second member that never sent HELLO features (old build) both receive both CONFIGs,
node B's `room.meta.speedLimitKmh` follows, and a member's CONFIG is refused (`NOT_LEAD`) with the meta unchanged.
The existing `gateway/test/config_live_355.test.js` already covers the broadcast, the permission and the
timeline judging new fixes at the new limit.

## 2. Fewer settings, sensible defaults on

Principle: the app works with zero configuration; a row stays only when the rider has a real decision (consent,
privacy, legal, data use, language, theme) or it is a quick control. Counted below: every switch or picker a
rider could change (data entries such as the emergency contact, fuel, quick-reply order, private places and
links are not counted).

**Before: 35. After: 18 (17 removed or merged into a fixed default, 49 %).** Main Settings screen switches
(without push / app lock): 5 → 2. Road safety screen: 10 controls → 1 (the consent). Intercom options: 3 → 1.

| Setting (before) | Where it was | Now | New value | Why |
|---|---|---|---|---|
| Speed warning | Settings › Safety | **kept** | the rider's (0 = group limit) | The limit the owner changes; now says which limit applies |
| Voice alerts | Settings › Ride | **removed** from Settings, kept as the quick-settings **Voice** tile | rider's (on) | A quick control during a ride (owner list); stored value kept |
| Siren alerts | Settings › Ride | **kept** | on | Owner decision Nov 9 (uses the microphone) |
| Language | Settings › Ride | **kept** | system | Must stay |
| Battery saver | Settings › Ride | **removed** from Settings, kept as the quick-settings tile | rider's (auto at 20 %) | Automatic already; quick control; stored value kept |
| Data saver | Settings › Ride | **kept** | off | Changes data use materially |
| Show cockpit on lock screen while riding | Settings › Ride screen | **kept**, moved to **Advanced** | on | Privacy: shows the group's names and positions on a locked phone |
| When idle (Ride AOD / Dim / Sleep) | Settings › Ride screen | **merged** | Ride AOD | Falls back by itself: sleeps below 15 % battery, after 5 min parked, when too hot; AOD sooner when hot |
| Keep screen on (moving / always) | Settings › Ride screen | **merged** | only while moving | Clearly right; stops longer than 2 min let the screen sleep |
| App lock | Settings › App & privacy | **kept** | off | Needs device credentials; security choice |
| Lock after | Settings › App & privacy | **kept** (only when app lock is on) | 5 min | Part of the app lock choice |
| Appearance | Settings › App & privacy | **kept** | automatic | Theme |
| Push notifications | Settings › App & privacy | **kept** | on | Must stay |
| News and updates | Settings › App & privacy | **kept** | on | Marketing choice |
| Events, Safety tips, Community, Partner perks | Settings › App & privacy | **kept** (4) | on, on, on, off | Marketing choices |
| Show me on leaderboards | Settings › App & privacy | **kept** | on | Privacy |
| Pause music for alerts | Settings › More | **removed** | off (music lowered) | Critical lines always pause music; ordinary lines lower it |
| Lower music when speeding | Settings › More | **removed** | on | Safety; admin switch `speedAudio` still applies |
| Navigation app | Settings › More | **kept** in Advanced | Automatic | 3.55 owner decision (Google Maps / Mappls) |
| Help make roads safer | Road safety | **kept** | **off** (opt-in) | Consent; never turned on by any migration |
| Hazard warnings | Road safety | **removed** | on | Safety |
| Rough road ahead | Road safety | **removed** | on; "Mute this ride" on its card | Safety, rate-limited (1 per 5 km, lowest priority) |
| Twisty section ahead | Road safety | **removed** | on; "Mute this ride" on its card | Safety, rate-limited |
| Long ride and night nudges | Road safety | **removed** | on; Snooze / "Mute this ride" | Fatigue safety |
| Break reminder interval | Road safety | **removed** | 2 h (a stored 1 h 30 / 1 h 45 is kept, the safer side) | The 2 h reminder is always on |
| Curve warnings | Road safety › Bends and speed limits | **removed** | on | Safety; speaks only when faster than the bend's speed |
| Speed limit display | Bends and speed limits | **removed** | on | Safety |
| Overspeed warning | Bends and speed limits | **removed** | on | Safety; says it once, estimates never speak |
| Warn when over by (5-20 %) | Bends and speed limits | **merged** | automatic: +10 %, at least 5 km/h, 0 near schools / hospitals | One clearly right value |
| About estimated limits (expandable) | Bends and speed limits | moved to help text | — | Plain text on the card |
| Noise reduction (Strong / Normal / Off) | Intercom options | **merged** | Strong | Owner asked for excellent noise suppression |
| Wind-noise mode | Intercom options | **merged** | automatic (on) | Gusts are ducked only while nobody speaks |
| Remote or headset button (hardware PTT) | Intercom options | **kept** | off | Changes what the volume button does; accessory-specific |

Not counted as settings and unchanged: "Hear the group" and "Microphone" (intercom quick controls), Night map
(quick tile), emergency contact & Medical ID, fuel, quick-reply order, private places, road data (Clear), wrong
limits, sign out / delete account (Profile).

### Hidden control: "Mute this ride"

Rough road, twisty road and long ride / night nudge cards in the ride screen carry a **Mute this ride** action
(`RideWarningMute`, pure; `RoadCareService.muteForRide`). It quiets the card and its voice line for that kind
until the ride ends (`RoadCareService.reset` at every ride start and end). Hazard, bend, speed-limit, SOS,
crash and the 2 h break reminder can never be muted. An action button was used instead of a long-press: it is
simpler, visible and glove-friendly on the existing card.

### Strings

The removed rows were English-only (Settings is not translated). No l10n key was removed; the hi / te tables are
unchanged. The `SettingsScreen` text constants of removed rows stay (unused by the screen) for callers.

## 3. Migration rules

`SettingsService.safetyDefaultsVersion` 2 → **3** (step 3 runs once; a phone several versions behind runs every
missing step in order). The pure plan is `SettingsRound9.plan` (`lib/domain/safety/settings_round9.dart`).

- **Ignored and treated as ON (or the fixed default)**, whatever is stored, from the first launch: the getters of
  every removed setting return the fixed value (`curveWarnings`, `roadLimitDisplay`, `roadOverspeedWarning`,
  `lowerMusicWhenSpeeding`, `windNoiseMode` = true; `roadOverspeedTolerancePct` = 10; `rideIdleMode` = Ride AOD;
  `keepScreenOnMode` = only while moving; `pauseOtherAudio` = false; `noiseReduction` = Strong;
  `IntelSettings` hazard / rough / twisty / nudges = true). The setters are kept for callers and do nothing.
- **Step 3 rewrites** the five switches above to `true` and **deletes** the retired choice keys
  (`road_overspeed_tolerance_pct`, `ride_idle_mode_v1`, `ride_keep_screen_on_v1`, `coroute_pause_other_audio`,
  `noise_reduction_v1`). Road safety warnings live in `intel_settings_v1`: their stored `false` is ignored on
  read and written back as `true` on the next save.
- **Voice nags, decided per item:** rough road, twisty and nudges come back ON for a rider who had them off
  (they are rate-limited and now mutable per ride). No exception was needed.
- **Never turned on silently:** "Help make roads safer" (`con` in `intel_settings_v1` and the server consent),
  push kinds (partner perks stays off unless chosen), leaderboards, the lock-screen cockpit choice. No step
  writes any of them (`SettingsRound9.neverTouched`, tested).
- **Rider choices kept:** voice alerts, battery saver (quick controls), siren alerts, data saver, language, speed
  warning, app lock, hardware PTT, a shorter break interval (90 / 105 min).
- **Old keys never crash:** nothing reads the retired keys any more; the speed warning is read with a type check
  (a wrong type stored by an old build or a restored backup reads as 0 instead of aborting the whole load).

## 4. Tests

- `test/round9_speed_limit_live_pure_test.dart` (pure, **16 passed** with `tool/pure_dart_test/run.sh`): own limit
  lowered / raised mid-ride (warned within two fixes, voice names the new limit, a second limit in the same minute
  is still spoken, the old minute key shown to collide), group limit lowered / switched off by the lead, the
  stricter rule and the Settings line, the automatic road margin, migration step 3 plan (writes only "on", never
  consent / privacy / rider keys), "Mute this ride" kinds and reset.
- `test/round9_settings_live_test.dart` (widget, analyzed; run with `flutter test`): `SafetyService` with a test
  port: own limit lowered (limit changes at once, listeners notified, warning with the new limit on the next fix,
  voice says "limit 80"); two limits in one minute both spoken; the lead's CONFIG lowered then raised; offline
  solo ride warns at my own limit and resets at the end; the ride notification pushes at once with "limit 80"
  and the Live Update text; Ride AOD limit; migration step 3 with `SharedPreferences` (stored offs and old
  choices ignored and rewritten, rider and privacy choices kept); corrupt stored speed warning; `IntelSettings`
  offs ignored, consent untouched; the Bends and speed limits card has no switches; `RoadCareService` mute.
- Updated on purpose (behaviour changed): `settings_minimal_355_test` (2 switches on the main screen, Advanced
  holds the lock-screen cockpit, removed rows gone, small-phone 320 x 568 test, version 3),
  `network_settings_ui_test` (2 switches, no voice alerts row), `voice_hud_notification_test` (no voice alerts
  row), `settings_lock_cockpit_migration_test` (when idle / keep screen on fixed and deleted once),
  `voice_service_test` (pause music cannot be switched on; changed limit is spoken), `audio_and_calls_355_test`
  (lower music when speeding always on).
- `dart analyze lib test`: no issues. `dart tool/play_policy_scan.dart`: 0 hits. All 13 pure test files pass.

## 5. Device QA checklist

Speed limit changed mid-ride (S-items):

- [ ] **S1 Own limit, lowered.** Group limit Off. Settings › Speed warning 100, ride at about 85. Open Settings
      from the cockpit and tap 80. Within 1-2 s: the card "SLOW DOWN … limit of 80", the voice "Over limit. 85
      km/h, limit 80.", the top bar badge "Over 80". Repeat within the same minute with 60: spoken again.
- [ ] **S2 Own limit, raised.** From S1, tap 120: the card goes on the next fix, the badge reads "Limit 120".
- [ ] **S3 Own limit above the group limit.** Group limit 80, own 100: Settings line reads "Now: group limit 80
      km/h (stricter than yours)."; warnings stay at 80.
- [ ] **S4 Group limit by the lead.** Lead phone: Group settings › Group speed limit 60 while a member rides at
      70. Member phone within 1-2 s (plus network): card, voice "limit 60", badge "Over 60". Lead raises to 100:
      member's card goes. A member tapping a chip changes nothing (chips disabled; the gateway refuses).
- [ ] **S5 Seen on the lock screen.** Member phone locked during S4: the ride notification line changes to
      "… (over 60)" / "limit 60" at once, not 10-20 s later; on Android 16 the Live Update text shows "Limit 60".
- [ ] **S6 Ride AOD.** Leave the screen 30 s: the AOD shows "Limit 60", red "Over limit 60" when over.
- [ ] **S7 Lock-screen cockpit.** Press power and wake: the cockpit over the keyguard shows the new limit badge.
- [ ] **S8 Old build in the group.** One member on the previous build: it receives the lead's new limit (its card
      and badge follow); nothing breaks on the 3.55 phones.
- [ ] **S9 Offline solo ride.** Airplane mode, start an offline solo ride with own limit 50, ride at 60: warned.
- [ ] **S10 Two nodes.** With the mirror on, a member connected to VM2 receives the lead's change made on VM1.

Settings screen:

- [ ] **S11 Small phone (about 320 x 568 dp, largest font).** Settings: no overflow, Advanced opens with one tap,
      the speed warning line wraps; Road safety shows the consent and the always-on note only.
- [ ] **S12 Upgrade from a phone with old choices** (rough road off, When idle = Sleep, noise reduction Off,
      pause music on, "Help make roads safer" off): after the update rough road warns (with "Mute this ride"), the
      AOD shows when idle, voice is strongly cleaned, music only lowers, and the consent is still **off**.
- [ ] **S13 Mute this ride.** Tap it on a rough road card: no more rough road cards or voice that ride; hazards
      still warn; the next ride warns again.
- [ ] **S14 Quick settings.** Voice and Battery saver tiles still toggle and the choice survives a restart.

## 6. Owner decisions needed

1. **Stricter limit wins.** Kept: a rider cannot raise their own warning above the lead's group limit (the group
   limit is a group safety rule, and the gateway logs group overspeed regardless). The Settings line now explains
   it. If the owner prefers "my own setting always wins on my phone", it is a one-line change in
   `effectiveSpeedLimit`.
2. **Voice alerts and battery saver** left Settings and live only in the ride screen's quick settings (the
   "Safety is always on" sheet says where). Say if either should come back as a Settings row.
3. **Lock-screen cockpit** stays a choice (privacy), under Advanced, default on.
