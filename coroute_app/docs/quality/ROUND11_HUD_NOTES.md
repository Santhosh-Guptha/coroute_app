# Round 11 ride HUD notes (for the lead)

Redesign of the ride screen (cockpit) after the owner's competitor references. Build stays 3.55.0+10029.
Design: `docs/design/RIDE_HUD_v3.58.md`. Parallel work: Agent S owns the app shell / home / explore / community / chat /
profile / welcome; nothing of theirs was edited.

## 1. Files

**New (app):**
* `lib/domain/ride/ride_stats_accumulator.dart`: pure "Ride so far" / "Distance by speed" / over-limit / speed trace
  accumulator, JSON save / restore, `SpeedBandProfile` (bands per vehicle).
* `lib/presentation/rider/hud/hud_logic.dart`: pure rules (turn card text, then-line, group pill, rider gap, sheet
  snap points / states / sections, speed ring level, dial scale, safety strip pick, number formats).
* `lib/presentation/rider/hud/hud_top.dart`: `HudTopBar` (back + destination pill + status chips), `HudTurnCard`,
  `HudTurnModel`, `HudStatusChip`, `kHudGlove` (56).
* `lib/presentation/rider/hud/hud_speed.dart`: `HudSpeedDial`, `HudArcSpeedometer`.
* `lib/presentation/rider/hud/hud_controls.dart`: `HudControlColumn`, `HudControlButton`.
* `lib/presentation/rider/hud/hud_safety_strip.dart`: `HudSafetyStrip`.
* `lib/presentation/rider/hud/hud_sheet_parts.dart`: `HudCollapsedRow`, `HudHoldButton`, `HudGroupPillView`,
  `HudEtaRow`, `HudRideSoFar`, `HudSpeedBands`, `HudOverLimit`, `HudTripChart`, `HudRiderRow`, `HudSectionTitle`.

**Changed (my area):**
* `lib/presentation/rider/live_cockpit_map_screen.dart`: top bar -> HUD top bar + turn card + safety strip; recenter
  chip + zoom stack -> control column (night map, group view); sheet header -> collapsed HUD row + group pill (stopped
  details and talk bar kept); half / full sheet sections; route options sheet; `_fitGroup`, `_toggleNightMap`,
  `_hudTurnModel`, `_hudGroupPill`; top reserve 200 dp so the turn card stays above the full sheet.
* `lib/presentation/rider/widgets/road_ahead_chips.dart`: `showLimit` / `showCurve` (default true; the cockpit no
  longer shows the chip row, the sign and bend live in the turn card / strip).

**Marked minimal edits outside my area (data for the HUD):**
* `lib/data/services/safety_service.dart` ("Round 11 ride HUD (marked edit)"): `hudStats`, `hudStatsRevision`,
  feed from `_onFix` (also the offline solo branch), save every 30 s (SharedPreferences
  `coroute_hud_ride_stats_v1`, keyed by ride + rider), restore at ride start, reset in `_resetRide` and at a new
  offline solo ride. Over-limit counts against the stricter of the effective limit and the road's posted (not
  estimated) limit.
* `lib/domain/route/next_turn.dart` ("Round 11 HUD (marked edit)"): `NextTurn.computeAhead` (next N step starts).

Nothing in `lib/core/**` was changed (new components are in my folder; existing ones untouched).

**Tests:**
* `test/hud_ride_stats_accumulator_test.dart` (pure, 14): bands, profiles, parked jitter, bad accuracy / teleports,
  signal gap, stops, spike rejection, real peak, over-limit with allowance, no limit, save / restore, bad JSON, trace.
* `test/hud_logic_test.dart` (pure, 14): distance rounding, instructions, then-line rules, free ride title, group pill,
  rider gap, snap points, state / tap cycle, sections per state, side panel, speed ring levels, dial, strip pick.
* `test/hud_ride_sheet_test.dart` (widget, needs the Flutter SDK, not run here): collapsed / half / full sheet
  content, SOS on screen and hit-testable in each state (also 320 x 640 at 2.0 text), speed dial semantics, turn card,
  control column 56 dp and recenter only when panned.

Run: `DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/hud_ride_stats_accumulator_test.dart test/hud_logic_test.dart`
(28 passed). `dart analyze lib test`: no issues in my files (at the time of writing, Agent S's in-progress
`lib/presentation/home/home_screen.dart` and `rider_home_screen.dart` had errors from their own refactor).
`dart tool/play_policy_scan.dart`: 0 hits.

**Mocks:** `/tmp/claude-0/-home-claude/1c17a96b-6b0c-5ea8-aa7f-588a7257965d/scratchpad/redesign/hud_*.png`
(collapsed group light, half group dark, full group dark, solo no-route light, night with a hairpin + offline link,
landscape 915 x 412). Generator: `.../scratchpad/mockgen/gen.py` (no external hosts; bundled Manrope).

## 2. Stats rules (accumulator)

| Rule | Value |
|---|---|
| Ignore fix | accuracy > 50 m; jump > 200 m faster than 250 km/h (round 6 TrackRules) |
| Signal gap | > 2 min and moved > 50 m: no distance, no time |
| Moving | GPS speed >= 5 km/h; a fix without speed needs a move of max(25 m, 2 x accuracy) |
| Moving time cap | 30 s per fix interval (weak-signal patches do not lower the average) |
| Stop | below 5 km/h for 60 s after having moved, counted once |
| Peak | needs a neighbour fix within 5 s and a speed change <= 16 km/h per s; peak = lower of the pair |
| Over limit | segment speed > limit + 2 km/h (GPS reads true; speedometers read high) |
| Bands | 10 km/h bins, combined per vehicle profile at display time (no data lost if the profile changes) |
| Trace | one point per 30 s, halved past 240 points |
| Save | every 30 s; the last half minute can be lost on a hard kill |

## 3. Decisions (owner may change)

1. Hold-to-end (1.2 s) in the collapsed sheet, then the existing confirm dialog: two steps on purpose.
2. The limit ring is amber above the limit and red above the +10 % margin (where the voice warns), not red at once.
3. Over-limit stat uses the posted road limit, never an estimated one.
4. Without a destination the collapsed sheet shows moving time and km ridden, not "-".
5. Night map button reuses the ride dark override; it cannot force light while the phone is in dark mode.
6. Ride AOD left as it is (its speed number is already the minimal speed view).
7. Zoom buttons hidden on short windows (pinch and speed zoom remain).
8. The full sheet's group list adds a call button only when the rider shared a phone number; calls ask for the unlock
   while locked (dialContact).

## 4. Known gaps

* Widget tests and the cockpit wiring are not run (no Flutter SDK here); `dart analyze` and the pure tests are.
* Frame rate and drag smoothness not measured (no device).
* The cockpit build still runs on every ConvoyService notification (pre-existing); the new parts are cheap there.
* The safety strip shows the bend from roadView; hazards / falling behind still come as the existing alert cards in
  the slot under it (unchanged, never smaller). `HudSafetyStrip.extra` is ready for more advisories.
* Weather in the full sheet is the existing rain line (no new MET Norway call).

## 5. Device QA (H items)

- **H1 80 km/h glance test** (passenger holds a stopwatch, rider glances once): speed, next turn distance and the
  limit sign read in under 1 s; the then-line is noticed before a close double turn.
- **H2 Gloves** (winter and summer gloves): back, destination pill, every column button, End (hold), talk bar, SOS hold:
  first-try success >= 9 of 10; no accidental End (hold needs 1.2 s, then a confirm).
- **H3 Sunlight** (noon, max brightness, light theme): ETA, speed, limit ring colours and the strip readable; the
  amber ring is distinguishable from teal; red past the margin is obvious.
- **H4 Night** (dark theme / night map button): no white flashes, map soft dark, strip and SOS still high contrast; the
  night map button toggles and survives the battery saver turning on / off.
- **H5 Landscape handlebar mount** (915 x 412 class phones, and a 360 dp wide phone rotated): side panel readable,
  turn card not covered by the column, SOS reachable at the panel edge, no overflow at 1.3 text.
- **H6 SOS reachability**: in collapsed, half and full sheet, during a drag, with the strip and an alert card showing,
  at text scale 1.0 / 1.3 / 2.0, on a 320 dp phone: SOS visible and the hold works; never under the sheet.
- **H7 Low-end phone frame rate** (profile build, DevTools): sheet drag at 60 fps target (no frame > 16 ms on a
  mid-range, > 32 ms on a low-end), 20 riders, 1 Hz positions; rebuild counts show the stats cards rebuilding on
  their own revision and the strip only on a roadView change.
- **H8 Stats survive restart**: ride 10 km, force stop, reopen: Ride so far and bands continue from the saved values
  (at most 30 s lost); a new ride starts at zero; an offline solo ride starts at zero.
- **H9 Turn card**: planned route through a town: distance counts down (Now under 20 m), then-line appears for close
  double turns only, "Continue on ..." on long straights; emergency navigation turns the tile red with Stop.
- **H10 No route / solo**: road name and limit sign in the card, Moving / Ridden in the sheet, no group pill or talk bar
  in a solo ride.
- **H11 Lock screen**: locked cockpit: destination pill, layers and End ask for the unlock; SOS, talk, mute, map
  orientation, night map and group view work without; calling a rider from the group list asks for the unlock.
- **H12 Group pill / list**: as a follower "lead X ahead", as lead "last X behind", a rider falling behind turns the
  pill amber with the name; list order matches the ladder; battery and call shown.
