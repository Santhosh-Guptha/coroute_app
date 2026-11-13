# Round 7: speed, motion, loaders, responsive screens (UX / performance agent)

Build stays 3.55.0+10026. System guide: `docs/features_355/motion_and_loading.md`.

Owner request: "can we do anything for application fastness and speedness and processing and real time
loaders for smooth transitioning like apps in iOS devices ... make them enhanced for fast response and
responsive mobile screens".

**Not measured here.** There is no Flutter SDK and no device in this environment: no frame times, no
start-up time, no jank numbers exist for this round. The widget tests were written and pass the analyzer
but have NOT been run. Everything under "Device QA" below is still to do.

## 1. Audit findings and what was done

| # | Area | Finding | Done |
| --- | --- | --- | --- |
| A1 | Start-up | Before `runApp`, six reads were awaited one after the other (orientations, package info, theme, settings, sound settings, tile cache) | They run side by side (`Future.wait`) and all still finish before `runApp`: nothing that was ready at the first frame is later now. Provider order and every safety service untouched |
| A2 | Start-up | `tz_data.initializeTimeZones()` is synchronous on the UI thread before the first frame | Left as is: `AlarmNotifier` (not mine) schedules with it and a deferred init could race. See request S6 |
| A3 | Start-up | Sweeps (`OfflineMapRetentionService`, `RideStatsStore`, `ReviewPromptStore`) | Already not awaited. No change |
| A4 | Navigation | No `pageTransitionsTheme`: Android default zoom; no edge-swipe back | iOS slide + parallax + edge-swipe back for every `MaterialPageRoute` via the theme; `safety/...` routes get no transition |
| A5 | Navigation | Splash replaced by Home with a page transition | 200 ms cross-fade (`appFadeRoute`) |
| A6 | Navigation | Full-screen maps would lose left-edge panning to the back swipe | Map picker and trip planner routes are named `map/...` (slide, no swipe) |
| A7 | Dialogs / sheets | 19 raw `showDialog` and 8 raw `showModalBottomSheet` calls with their own timings | All in my area use `showAppDialog` / `AppMotion.sheetStyleOf` (reduce-motion aware). Not changed on purpose: `auth/ride_lock_dialog.dart`, `auth/mfa_prompt_dialog.dart`, `widgets/sheet_coordinator.dart` (SOS-protected), everything in `safety/` and `rider/` |
| A8 | Loading | 20 places showed a centred spinner for the first load (profile, rider profile, crew page + members, ride invitation + picker, people search, leaderboard, score, analytics, diagnostics log, trip events, place ratings, plan check, admin crews / diag logs / device compatibility) | Skeletons shaped like the content |
| A9 | Loading | Screens refetched and showed a spinner on every open (crew page, rider profile, leaderboard, score) | Last value shown at once from `SwrCache`, refreshed in place; a failed refresh keeps the old data |
| A10 | Loading | No indication while old data refreshes on profile / crew page | `TopProgressLine` |
| A11 | Buttons | `DsButton` had no busy state; screens swapped the button for a spinner or disabled the page | `DsButton(loading:)`, `AsyncButton` |
| A12 | Optimistic | A single-choice poll vote waited for the server before the tick moved | Tick moves at once, goes back if refused, double tap not sent twice |
| A13 | Images | `UserAvatar` decoded per exact pixel size (many cache entries), no placeholder, popped in; place photos and admin place photos were decoded at FULL size for an 84 / 132 dp tile | `AppNetworkImage`: sized decode in 32 px steps, placeholder, fade-in |
| A14 | Lists | 77 `ListView(children:)` vs 10 builders in my area. Most are short settings-style pages. Long ones: leaderboard (up to 50 rows built at once), admin lists | Not converted this round (risk without a device run). Listed in "Left for next round" |
| A15 | Scrolling | Mixed physics (clamping glow on some lists, bouncing on others) | One `AppScrollBehavior` for the app |
| A16 | Rebuild scope | `DsCard` / `DsButton` pressed state would have needed `setState` in screens | Press feedback lives in `PressScale` (rebuilds only itself); skeleton bones only repaint |
| A17 | UI thread | `jsonDecode` in my area: only one small saved-place read (map picker). Route parsing and ride analytics already use `compute`. Diagnostics bundle already uses `Isolate.run` | No change needed |
| A18 | Search | Admin users search and people search are already debounced; route planner debounced | `Debouncer` + `LatestGate` provided for new code |
| A19 | Responsive | Membership dashboard and pre-ride phone check stretched edge to edge on tablets / landscape | Centred 640 dp column (`Adaptive.pagePadding`) |
| A20 | Responsive | `DsChip` had no `maxLines` (a long translation pushed the row out) | One line + ellipsis |
| A21 | Tap targets | `DsRoundButton` default size is 44 dp (< 48) | Not changed (cockpit layouts depend on it). Request S5 |
| A22 | Haptics | Only confirm dialogs and safety controls gave haptics | Selection tick on `DsSwitchRow` / `DsSegment`, medium on pull-to-refresh, light on `Pressable` / `AsyncButton` |
| A23 | Perceived speed | Leaderboard / score / garage loaded only when opened | `StartupWarmup`: 3 s after sign-in, never during a ride |
| A24 | Bug found by the tests | `SwrCache.load` waited on itself (`whenComplete(() => map.remove(key))` returned the future) | Fixed before anything used it |

## 2. What was built

- Motion system, loaders, optimistic helpers, adaptive helper, sized images: see the file table in
  `docs/features_355/motion_and_loading.md`.
- Reduced motion: system "Remove animations" = no animation; battery saver = short fades, no loops.

## 3. Files

New: `lib/core/ui/motion_spec.dart`, `app_motion.dart`, `skeleton.dart`, `async_view.dart`,
`optimistic.dart`, `pressable.dart`, `adaptive_spec.dart`, `adaptive.dart`, `app_image.dart`,
`lib/presentation/widgets/startup_warmup.dart`, `test/ux_perf_motion_spec_test.dart`,
`test/ux_perf_motion_widgets_test.dart`, `test/ux_perf_responsive_test.dart`,
`docs/features_355/motion_and_loading.md`, this file.

Changed (core): `lib/core/ui/ui.dart` (exports), `design_kit.dart` (`DsButton.loading`, press feedback on
`DsButton` / tappable `DsCard`, haptic on `DsSwitchRow` / `DsSegment`, `DsChip` ellipsis),
`loading_state.dart` (`skeleton:`), `empty_state.dart` (`ErrorState`), `app_bottom_sheet.dart`,
`confirm.dart`, `lib/core/theme/app_theme.dart` (`pageTransitionsTheme`).

Changed (`lib/main.dart`, four marked blocks): parallel start-up reads + battery-saver bridge,
`scrollBehavior`, cache reset at sign-out, `StartupWarmup.schedule` after sign-in.

Changed (screens): `splash/splash_screen.dart`, `social/` (`profile_screen`, `rider_profile_screen`,
`crew_detail_screen`, `people_screen`, `ride_invite_screen`, `user_avatar`), `score/` (`leaderboard_screen`,
`rider_score_screen`), `analytics/ride_analytics_screen`, `settings/` (`diagnostics_screen`,
`road_safety_screen`), `subscription/membership_dashboard_screen`, `diagnostics/pre_ride_phone_check_screen`,
`report/trip_report_screen`, `map_places/` (`place_card`, `place_chips`, `place_review_sheet`,
`after_ride_place_reviews`), `map_picker/map_picker_screen`, `trip_planner/share_in_opener`,
`home/ride_start_view`, `garage/` (`garage_screen`, `complete_bike_sheet`), `account/` (`account_screen`,
`sign_out_flow`), `ride/` (`public_ride_widgets`, `pillion_seat_sheet`), `admin/` (`admin_crews_screen`,
`admin_diag_logs_screen`, `admin_device_compatibility_screen`, `admin_place_reviews_screen`,
`admin_reviews_screen`, `admin_payments_widgets`, `admin_rider_insights`, `admin_features_screen`).

Nothing was edited in `lib/domain`, `lib/data`, `lib/presentation/rider`, `lib/presentation/safety`,
`gateway/`.

## 4. Behaviour changes other agents will notice

1. Every `MaterialPageRoute` now slides (350 ms) and can be swiped back from the left edge, including
   routes pushed from `rider/` (trip history, replay). Routes named `safety/...` are instant.
2. Every list bounces (global scroll behaviour).
3. `showAppSheet` opens on a spring curve in the same 230 ms as before; `confirmAction` uses the new
   dialog motion (visible from the first frames; 300 ms to settle).
4. `DsButton` and tappable `DsCard` shrink slightly while pressed (visual only, taps unchanged).
   `DsSwitchRow` and `DsSegment` give a selection haptic.
5. With battery saver on, page transitions become a 120 ms fade.

## 5. Requests for other agents

### Agent S (safety; `rider/`, `safety/`, `domain/`, `data/services/`)

- **S1 Keep safety routes named.** The instant path depends on `RouteSettings.name` starting with
  `safety/` (today `LockScreenCockpitPolicy.routeCrashAlarm`, `routeSosHold`, `routeEmergencySos`). Any
  new safety page route must use that prefix. Please do not rename the prefix without telling me:
  `AppMotion.instantRoutePrefix`.
- **S2 Edge-swipe back on rider routes.** Pushed routes in `rider/` with a full-screen map
  (`ride_replay_screen`, trip detail) now have a 20 dp back-swipe zone on the left edge. If that fights
  map panning, name the route `map/<something>` (`RouteSettings(name: 'map/replay')`): it keeps the
  slide and drops the swipe. Screens that must not be left by a swipe already are safe if they use
  `PopScope(canPop: false)`.
- **S3 Cockpit: how to use the helpers** (all from `core/ui/ui.dart`; none of them may sit in front of
  SOS, the crash alarm or the lock-screen cockpit):
  - Skeletons: rider list / group sheet first load: `SkeletonRows(count: 4)`; trip history first page:
    `SkeletonList.cards()`; in `LoadingState` pass `skeleton: (_) => const SkeletonList()`.
  - Refresh in place: `TopProgressLine(active: ...)` at the top of a sheet.
  - Motion: `AppMotion.durationOf(context, AppMotion.medium)` for HUD pill fades so battery saver and
    "remove animations" are honoured; `FadeThroughSwitcher` for swapping HUD content; do NOT wrap SOS /
    hold-to-talk in `Pressable` (they have their own gesture timing). `PressScale` is safe on secondary
    cockpit buttons.
  - Haptics: `AppHaptics.selection()` for cockpit toggles, `.light()` for secondary taps. Keep your own
    heavy / alarm haptics as they are. `AppHaptics.enabled = false` exists if the SOS battery reserve
    should silence decorative haptics.
  - Adaptive: `AdaptiveBuilder(builder: (ctx, a) => ...)` inside the cockpit overlay gives `a.isCompact`
    (< 360 dp), `a.landscape`, `a.shortHeight` (< 480 dp usable: landscape phone), `a.bigText`
    (>= 1.15); `a.pick(compact:, normal:, large:)` for pill sizes. `MinTapTarget` for small HUD chips.
  - Rider avatars in the cockpit: `AppNetworkImage` (or `UserAvatar`) for sized decode.
- **S4 Battery reserve.** `AppMotion.batterySaver` follows `SettingsService.batterySaver` only. If the
  SOS battery reserve or `ConvoyService.batterySaverActive` should also reduce motion, set
  `AppMotion.batterySaver.value = true` while they are active (one line where those states change).
- **S5 `DsRoundButton` default 44 dp.** Callers in `rider/` that rely on the default are below the 48 dp
  target. Either pass `size: 48` or tell me the default can change.
- **S6 `tz_data.initializeTimeZones()`** runs on the UI thread before the first frame in `main.dart` and
  again lazily in `AlarmNotifier`? If `AlarmNotifier` always initialises before its first use, the call
  in `main.dart` can move after the first frame. Please confirm; I did not move it.
- **S7 Data services with a public cache.** `RiderScoreService` is created per screen, so I seed
  `score` / `leaderboard` from `SwrCache`. A small static last-value cache in the service would be
  cleaner. Low priority.
- **S8 Home shell.** `RiderHomeScreen` already keeps tabs alive. `FadeThroughIndexedStack` is a drop-in
  for its `IndexedStack` if you want the fade-through on tab switches (the Ride tab must stay the
  first built tab, as today).

### Agent W (website)

- None. For parity, the tokens are 120 / 200 / 300 ms, ease-out cubic, and `prefers-reduced-motion`
  should map to "none".

## 6. Tests and checks

- `dart analyze lib test`: no issues (whole tree, including the other agents' files at the time of the run).
- `dart tool/play_policy_scan.dart`: 0 hits.
- `tool/pure_dart_test/run.sh test/ux_perf_motion_spec_test.dart`: 26 passed.
- `test/ux_perf_motion_widgets_test.dart` (transition theme, slide, edge swipe, safety routes instant,
  reduce motion, battery saver, tab fade-through keep-alive, skeleton to content, stale-while-revalidate,
  error + retry, optimistic switch roll-back, poll vote, inline button progress, pressed state, counter,
  haptics, decode size, spring curve) and `test/ux_perf_responsive_test.dart` (breakpoints, two panes,
  tap targets, trailing stack, bottom bar, UI kit and loaders / poll card / leaderboard at 320x568,
  360x800, 412x915, 800x1280, 915x412, 568x320 at text scale 1.0 and 1.3): **written, analyzer-clean,
  not run** (no Flutter SDK). Run `flutter test test/ux_perf_*` first on a machine with the SDK; expect
  to adjust a few expectations.
- The existing widget suite was not run either. Places where my changes could touch older tests: tests
  that expect a `CircularProgressIndicator` on the screens in A8 (a search found none), tests that count
  haptic calls around `DsSwitchRow` / `DsSegment` (found none), tests that drive page transitions with
  fixed `pump` durations (page push is now 350 ms).

## 7. Device QA checklist

Run a profile build: `flutter run --profile`, DevTools Performance (frame chart, "Raster" vs "UI"),
and `adb shell dumpsys gfxinfo space.devmonks.coroute_app framestats` (`... reset` before each case). Targets: 60 Hz phone: 99th percentile frame < 16.6 ms; 120 Hz phone: < 8.3 ms
on page pushes and list scrolls; no frame > 32 ms during a push.

| # | Case | Check |
| --- | --- | --- |
| U1 | 120 Hz phone, page push / pop / edge-swipe back (Home > Profile > Rider) | smooth at 120 Hz, no dropped frames in gfxinfo; swipe follows the finger; cancelling the swipe returns cleanly |
| U2 | Low-end phone (2-3 GB RAM, 60 Hz), same flows + cold start | cold start to first frame vs the previous build (`adb shell am start -W`); no jank on push; skeleton shimmer does not drop frames |
| U3 | **Crash alarm, SOS hold, emergency SOS from every screen and mid-transition** | on screen in the first frame, no slide / fade, buttons work at once; also while a page push or a sheet is animating; also with battery saver and "remove animations" |
| U4 | Lock-screen cockpit, ride lock, app lock | unchanged behaviour; no page transition over the keyguard path; app lock covers at once |
| U5 | Small screen (320-360 dp wide), font size largest | no overflow stripes, no clipped text on Profile, Crew, People, Leaderboard, Score, Settings, Garage, Plan, Trip report; buttons >= 48 dp |
| U6 | Tablet / unfolded foldable, portrait and landscape; split-screen | centred columns, nothing stretched; plan page and phone check centred; rotate mid-screen keeps state |
| U7 | System "Remove animations" on | pages, dialogs, sheets appear in place; skeletons static; nothing loops |
| U8 | Battery saver setting on | pages fade (no slide); no shimmer; cockpit unaffected |
| U9 | Slow network (throttle to 2G) | skeletons appear at once and match the content layout (no jump when content arrives); top progress line on refresh; buttons show their own spinner; nothing blocks the page |
| U10 | Offline | cached profile / crew / leaderboard / score show at once; error state with "Try again" when there is no cache; toast (not a blank page) when a refresh fails |
| U11 | Poll vote with the network off | tick moves, then goes back, message shown; double tap sends once |
| U12 | Avatars and place photos | no pop-in (fade), no layout jump; memory in DevTools lower on a list of 50 avatars than the previous build |
| U13 | Map picker and trip planner | left-edge pan moves the map, does not go back; system back still works |
| U14 | Rider routes with maps (replay, trip detail; Agent S) | decide on S2 |
| U15 | Lists | same bounce everywhere; pull-to-refresh works on short lists; no glow |
| U16 | Sign out, sign in as another rider | no data of the previous rider on Profile / Crew / Leaderboard position (cache cleared) |
| U17 | During a ride | `StartupWarmup` does not run (no extra requests in the gateway log 3 s after sign-in while a ride is active) |
| U18 | Haptics | selection tick on switches / segments; nothing new on SOS / alarm controls |
| U19 | Keyboard | text fields in sheets stay above the keyboard; `BottomActionBar` moves above it; no typing lag in People search |
| U20 | Hero | search result avatar flies to the rider profile and back, also with an edge-swipe |

## 8. Left for next round

- Convert the long `ListView(children:)` pages to builders with `itemExtent` / `prototypeItem`
  (leaderboard rows, admin users / reviews / ride history).
- Two-pane settings / profile / history on tablets (`TwoPane` exists; the screens still push pages).
- Use `SwrController` / `SwrView` on the remaining fetch-on-open screens (admin lists, ride invitation,
  place card ratings) and `OptimisticSwitch` on the server-backed toggles (leaderboard opt-in, crew
  settings).
- `FrostedAppBar` and `FadeThroughIndexedStack` are built and tested but not yet used by a screen
  (the app's screens use `DsScreenHeader` inside the scroll view; the tab shell is Agent S's).
- `AnimatedCount` on the score and profile numbers.
