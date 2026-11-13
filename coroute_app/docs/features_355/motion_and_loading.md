# Motion, loading and responsive layout (round 7)

One system for how the app moves, loads and fits the screen. Everything is in `lib/core/ui/` and is
exported by `core/ui/ui.dart`. No new packages: Flutter SDK only.

**Safety rule (never break it):** the crash alarm, SOS hold, emergency SOS, Medical ID, ride lock, app
lock and the lock-screen cockpit never wait for an animation, a skeleton or a loader. Page routes named
`safety/...` are drawn at full size and opacity on their first frame and take taps on that frame.

## 1. Files

| File | What it holds |
| --- | --- |
| `motion_spec.dart` (pure Dart) | `MotionMs` 120 / 200 / 300 ms (+ page 350, shimmer 1300, search debounce 280), `MotionLevel` full / reduced / none, `SpringSpec`, `MotionSpec` rules |
| `app_motion.dart` | `AppMotion` (durations, curves, spring, reduce-motion), `AppPageTransitionsBuilder`, `appFadeRoute`, `AppScrollBehavior`, `FadeThroughIndexedStack`, `FadeThroughSwitcher`, `showAppDialog`, `AppHaptics` |
| `skeleton.dart` | `Shimmer`, `SkeletonBox/Line/Paragraph/ListTile/Card/StatRow/Profile`, `SkeletonList`, `SkeletonRows`, `SkeletonCards`, `SkeletonSwitcher`, `TopProgressLine` |
| `async_view.dart` | `SwrController<T>` + `SwrView<T>` (stale-while-revalidate), `AppRefresh`, `runWhenIdle` |
| `optimistic.dart` (pure Dart) | `Optimistic.run`, `Debouncer`, `LatestGate`, `SwrCache` |
| `pressable.dart` | `Pressable`, `PressScale`, `AsyncButton`, `AnimatedCount`, `showAppToast`, `OptimisticSwitch` |
| `adaptive_spec.dart` (pure Dart) / `adaptive.dart` | `AdaptiveSpec`, `Adaptive.of(context)`, `AdaptiveBuilder`, `ContentWidth`, `TwoPane`, `MinTapTarget`, `AdaptiveRow`, `BottomActionBar` |
| `app_image.dart` | `AppNetworkImage`, `decodeSize`, `AppHero`, `FrostedAppBar` |
| `empty_state.dart` | `EmptyState`, new `ErrorState` (with Retry) |

## 2. Motion tokens

- Durations: `AppMotion.fast` 120 ms (pressed states), `medium` 200 ms (content swaps, tab fade-through),
  `slow` 300 ms (dialogs), `page` 350 ms (page push), `sheetIn` 230 ms (same as before round 7).
- Curves: `AppMotion.standard` easeOutCubic (enter), `exit` easeInCubic, `move` easeInOutCubic,
  `spring` (a `SpringCurve` of `SpringSpec.sheet`, clamped so a sheet cannot overshoot).
- Drag release: `controller.animateWith(AppMotion.release(from: x, to: 1, velocity: v))`.
- The old `Motion.*` tokens in `ui_tokens.dart` still work (cockpit and safety code use them).

### Reduced motion

`AppMotion.levelOf(context)`:

| Level | When | Effect |
| --- | --- | --- |
| `none` | system "Remove animations" (`MediaQuery.disableAnimations`) | pages, dialogs and sheets appear in place; no shimmer; no pressed scale; counters show the value |
| `reduced` | the rider's battery saver (`AppMotion.batterySaver`, set in `main.dart` from `SettingsService.batterySaver`) | pages fade in 120 ms (no slide / parallax), no shimmer loop, no pressed scale, no hero flight, no blur |
| `full` | otherwise | everything |

Use `AppMotion.durationOf(context, AppMotion.medium)` for your own implicit animations and
`AppMotion.reducedOf(context)` to skip decorative motion.

## 3. Navigation

- **Pages**: `ThemeData.pageTransitionsTheme = appPageTransitionsTheme` (in `AppTheme.themeFor`). Every
  `MaterialPageRoute` gets the iOS horizontal slide with parallax of the page below and the interactive
  edge-swipe back. Only transforms and opacity are animated. Nothing to change at call sites.
- Edge-swipe back is off (by the framework) on the first route, on `PopScope(canPop: false)` screens and
  on `fullscreenDialog` routes. A route named `map/...` slides but has no edge swipe (for full-screen
  maps whose left edge is used for panning).
- **Full-screen dialogs** (`fullscreenDialog: true`) rise from the bottom.
- **Safety routes** (`RouteSettings.name` starting with `safety/`, the names in
  `LockScreenCockpitPolicy`): no transition at all.
- **Replacing the whole stack** (splash to home): `appFadeRoute((_) => const Home())`, a 200 ms fade.
- **Tabs**: `FadeThroughIndexedStack(index: i, builders: [...])` builds a tab on first visit, keeps it
  alive and fades through on a switch.
- **Dialogs**: `showAppDialog(context, builder: ...)` (fade + scale from 94 % on the spring).
  `confirmAction` uses it.
- **Sheets**: `showAppSheet(...)`; raw `showModalBottomSheet` calls pass
  `sheetAnimationStyle: AppMotion.sheetStyleOf(context)`.
- **Scrolling**: `MaterialApp.scrollBehavior = const AppScrollBehavior()` gives every list the same
  bounce, no glow.

## 4. Loading: what to use when

| Situation | Use |
| --- | --- |
| First load, nothing to show | a skeleton shaped like the content: `SkeletonList()`, `SkeletonList.cards()`, `SkeletonProfile()`, `SkeletonRows(count: 4)` / `SkeletonCards(count: 3)` inside an existing list, `SkeletonParagraph(lines: 3)` for plan / capability text |
| Data already on screen, refreshing | keep the data; `TopProgressLine(active: refreshing)` (shows after 90 ms, stays at least 260 ms) |
| A button started work | `AsyncButton(label:, onPressed: () async {...})` or `DsButton(loading: true)`: spinner inside the button, page never blocked |
| The rider pulls down | `AppRefresh(onRefresh:, child:)` (medium haptic) |
| Loading failed, nothing to show | `ErrorState(onRetry: ...)` |
| Loading failed, old data on screen | keep the data, `showAppToast(context, '...', error: true)` |
| Nothing to list | `EmptyState(...)` |

Never: a full-screen spinner, a modal "please wait" over the page, a blank screen.

`LoadingState` (older screens) takes `skeleton: (_) => const SkeletonList()` for its first-load state.

### Stale-while-revalidate

```dart
late final _crews = SwrController<List<Crew>>(cacheKey: 'crews', fetch: api.crews)..load();

SwrView<List<Crew>>(
  controller: _crews,
  skeleton: (_) => const SkeletonList.cards(),
  isEmpty: (l) => l.isEmpty,
  empty: (_) => const EmptyState(icon: Icons.groups_rounded, title: 'No crews yet'),
  builder: (_, crews) => ListView.builder(itemCount: crews.length, itemBuilder: ...),
)
```

The cached value (`SwrCache.shared`, memory only, cleared at sign-out) is on screen in the first frame;
the fetch runs unless the entry is younger than `ttl` (45 s: going back and forth does not refetch);
the new value replaces the old in place. Screens with their own state can use the cache directly
(`SwrCache.shared.peek<T>(key)` in `initState`, `put` after the fetch): crew page, rider profile,
leaderboard and score do this.

### Optimistic UI

```dart
Optimistic.run<bool>(
  read: () => liked, apply: (v) => setState(() => liked = v), next: !liked,
  commit: (v) => api.setLiked(id, v),              // throw or answer false = refused
  onError: (_) => showAppToast(context, 'Could not save. Try again.', error: true),
  key: 'like:$id',                                 // a double tap is not sent twice
);
```

`OptimisticSwitch(value:, onSave:)` is the ready-made switch. Use it only for cheap, reversible actions
(settings, join / leave, like, vote, mark read). Never for SOS, payments, deleting, ending a ride.

## 5. Micro-interactions

- `Pressable(onTap:, child:)`: scale + dim while pressed, light haptic. `PressScale` adds only the look
  to a control with its own tap handling (used by `DsButton` and tappable `DsCard`); it listens to raw
  pointers and cannot delay or swallow a tap.
- Haptics: `AppHaptics.light()` primary tap, `.selection()` value changed (`DsSwitchRow`, `DsSegment`
  do it themselves), `.medium()` committed action / pull-to-refresh.
- `AnimatedCount(86)` for numbers that change.
- `AppHero(tag: AppHero.avatar(username), child: ...)` or `UserAvatar(heroTag: ...)`: the tag must be
  unique on its screen.
- `FrostedAppBar` with `Scaffold(extendBodyBehindAppBar: true)`: blur only at full motion.
- Lists that insert / remove single rows: `AnimatedList` or `AnimatedSize` + `FadeThroughSwitcher`.

## 6. Responsive layout

`final a = Adaptive.of(context);`

| Class | Width | Gutter |
| --- | --- | --- |
| `compact` | < 360 dp | 12 |
| `normal` | 360 to 599 dp | 16 |
| `large` | >= 600 dp | 24 |

- `a.pagePadding()` centres a 640 dp column on wide windows and respects cut-outs in landscape.
- `TwoPane(list:, detail:)` shows two panes from 720 dp (`TwoPane.active(context)` to decide between
  selecting and pushing).
- `AdaptiveRow` moves the trailing part under the text on compact windows or with big text.
- `BottomActionBar` keeps primary actions at the bottom (thumb reach), inside the safe area, stacked on
  compact windows or with big text.
- `MinTapTarget` guarantees 48 x 48 dp. Text is laid out up to scale 1.3 (`main.dart` caps it).
- Use `AdaptiveBuilder` inside sheets and panes (it measures the space the widget really has, so
  split-screen and foldables work).

## 7. Images

`AppNetworkImage(url, width:, height:)` decodes at the size shown (`decodeSize`: dp x pixel ratio, steps
of 32 px, max 3x), shows a grey placeholder of the same size, fades in, and falls back on error.
`UserAvatar` uses it.

## 8. Perceived speed

- Start-up: the independent reads before `runApp` run side by side (same things ready at the first
  frame as before).
- `StartupWarmup` (`lib/presentation/widgets/startup_warmup.dart`): 3 s after sign-in, when no ride is
  active, it loads the garage, the leaderboard and my score into the cache.
- Search fields: `Debouncer()` (280 ms) + `LatestGate` so an old answer never replaces a newer one.

## 9. Tests

- `test/ux_perf_motion_spec_test.dart`: pure logic, runs with `tool/pure_dart_test/run.sh`.
- `test/ux_perf_motion_widgets_test.dart`, `test/ux_perf_responsive_test.dart`: widget tests
  (`flutter test`).
