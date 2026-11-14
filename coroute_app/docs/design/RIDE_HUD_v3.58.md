# Ride HUD (round 11 redesign of the ride screen)

Build stays 3.55.0+10029. Code: `lib/presentation/rider/hud/*`, wired in `lib/presentation/rider/live_cockpit_map_screen.dart`.
Mocks (static HTML/CSS, same layout and tokens): scratchpad `redesign/hud_*.png` (see ROUND11_HUD_NOTES.md).

Owner request: ride screens "similar or better" than the competitor references, with all CoRoute features. We took
layout ideas only (dark map, destination pill, big turn card, right control column, a bottom sheet with a speed gauge
and ride stats). Brand, copy, icons and colours are CoRoute's (DESIGN_SYSTEM_v3.55: teal, Manrope, tokens, light/dark).

## 1. Layout (portrait, 412 x 915)

```
 ┌───────────────────────────────────────────┐
 │ (<)  [⚑ Gandikota            386 km · 9:03 ⌄]   back 56 dp + destination pill 56 dp
 │ [chips: Airbag · Remote · Low GPS · Offline]   only when present
 │ ┌───────────────────────────────────────┐ │
 │ │ [↰]  350 m                       (60) │ │  turn card: 64 dp arrow, 34 sp live distance,
 │ │      Turn left onto Sai Temple Rd     │ │  instruction + road, round 7 limit sign
 │ │ ↱ Then turn right onto NH 40          │ │  "then" line when the next manoeuvre is close
 │ │ ⤳ New route, 42 km              (x)   │ │  route / emergency route status (when any)
 │ └───────────────────────────────────────┘ │
 │ [⤴ Hairpin right   Comfortable  25 · 300 m]│  safety strip: one advisory at a time
 │ [Offline link · 5 riders, 2 hops]         │  round 10 chip (unchanged, own row)
 │ [alert slot: others' SOS / hazard cards]  │  unchanged (RideAlert / incident banners)
 │                                     [💬]  │  ride chat (group)
 │                                     [▲ ]  │  heading up / north up
 │                                     [≋ ]  │  map layers (places + where riders stop)
 │                                     [☾ ]  │  night map
 │ (SOS)                               [👥]  │  show all riders (group)
 ├───────────────────────────────────────────┤
 │ (72) 9:03 pm │ 386 km            [■ End]  │  collapsed: speed dial + limit ring, ETA, left, hold-to-end
 │ [👥 5 riders · lead 1.2 km ahead]          │  group status pill
 │ [🎙 Hold to talk ........ Intercom]        │  talk bar (group rides, unchanged)
 └───────────────────────────────────────────┘
```

The SOS button keeps its round 7 place: left, riding on the sheet's top edge, 68 dp in its 82 dp ring, always on top
and tappable in every sheet state. The CoRoute orbit control (draggable quick menu) is unchanged. Nothing safety
related moved into a menu.

### Sheet states (RideSheet snap points: collapsed = measured header, half = 0.5, full = sheetMax)

| State | Content |
|---|---|
| Collapsed | Speed dial (teal ring at or under the limit, amber over it, red past the +10 % margin, the round 9 automatic margin), ETA, km left, hold-to-end (64 dp, 1.2 s) or hold-to-leave; group pill; talk bar; stopped details when standing still. Without a destination: "Moving" time and "Ridden" km instead of ETA / left (never a made-up ETA). |
| Half | Arc speedometer with ticks, the effective-limit notch (round 9 effective limit: stricter of group / personal / town limit), the over-limit stretch tinted, a peak dot; ETA / Left / Max; **Ride so far** (avg moving speed, peak, ridden km, moving time, stops, stopped time); **Distance by speed** (bands by vehicle profile, km + %, bar, the current band in bold); **Over the limit** (time, distance, share; calm amber, or "Within the limit so far"). |
| Full | Weather / dark-soon lines, glove quick actions (intercom options, stops, fuel and next station, messages, safety health), roll call, convoy avatars, **Group list** (ride order: distance and minutes to me, Lead / Sweep, status, falling behind, battery, call), **Speed over the ride** chart (with the limit dashed), management group (riders, audio, group settings, guardian, share ETA, settings), pause / end / leave. |

`sheetMax` leaves the destination pill and the turn card visible above the full sheet (top reserve 200 dp, scaled
with text size), so navigation never disappears while the rider looks at stats.

### Landscape handlebar mount (915 x 412)

The sheet becomes the left side panel (same header and body), the map, top bar, turn card and control column sit on
the right, SOS at the panel's edge bottom-left of the map. Zoom buttons show only when the window is tall enough
(portrait >= 860 dp, landscape >= 640 dp); pinch and the speed zoom still work.

## 2. Variants

| Variant | Turn card | Collapsed sheet | Full sheet |
|---|---|---|---|
| Group, route | next turn + then-line | ETA / left / End, group pill, talk bar | group list, chat, intercom |
| Solo, route | next turn | ETA / left / End, "Solo ride" pill, no talk bar | no group parts |
| No route | road I am on ("Free ride" when unnamed), "No route · riding free" / "Solo · no route", limit sign | moving time / ridden km | as above |
| Route without a step ahead | "Continue on NH 44" / "Follow the route", "Gandikota in 386 km" | ETA / left | as above |
| Emergency navigation | red arrow tile, red status line with Stop | unchanged | unchanged |
| Night (dark theme / night map) | dark tokens | dark tokens | dark tokens |

Lanes are never shown (we have no lane data). The route has no manoeuvre list: the next turns come from the road steps
(`NextTurn.computeAhead`, marked addition in `lib/domain/route/next_turn.dart`, same rules as `NextTurn.compute`).

## 3. Where every existing feature went

| Feature | Before | Now |
|---|---|---|
| SOS hold button | left, on the sheet edge | unchanged |
| Others' SOS / crash banners, incident banners | HUD alert slot | unchanged (same slot, same size) |
| Crash alarm, SOS hold screen | full screen | unchanged |
| Round 7 limit sign | chip row under the top bar | inside the turn card (same `RoadLimitSign`, same size from `CockpitLayout`, "wrong limit?" tap only when standing still) |
| Round 7 bend chip | chip row | safety strip (56 dp, 26 sp advisory speed: larger than the old 18 sp chip) |
| Overspeed | top-bar border + MinimalSpeedAlert | MinimalSpeedAlert unchanged + speed dial ring + arc gauge marker |
| Offline link chip (round 10) | HUD column | unchanged, own row |
| Rescue finder (round 10) | its own screens / sheets | untouched |
| Intercom talk bar, intercom options | sheet header / quick actions | unchanged |
| Ride chat button | map controls | top of the control column (56 dp) |
| Places / layers incl. "where riders stop" | 44 dp map button | layers button in the column (same `showPlacesSheet`, `riderStopsSwitch: true`) |
| North up / heading up | 44 dp button | column (56 dp) |
| Recenter | "RECENTER" chip | 56 dp primary button in the column, only when panned |
| Zoom | 48 dp pair | 56 dp pair when there is room |
| Connection / GPS / tunnel / offline / airbag / remote | top bar pills | destination pill line (connection) + status chips; tunnel banner unchanged |
| Next stop / destination | top bar title | destination pill (tap: route options: change destination or stops (lead), add a stop for me, share ETA, open in navigation app) |
| End / leave ride | lifecycle bar at the bottom of the full sheet | also hold-to-end in the collapsed sheet; both run the same `_endRide` / `_leaveRide` (confirm dialog, offline queue, lock-screen gate) |
| Ride AOD | OLED view after 30 s | unchanged (its big speed number already is the minimal speed component; no new paint work on the AOD) |
| Lock-screen cockpit | locked mode rules | unchanged: route options, layers and the end-ride confirm are sheets / dialogs, so `LockedRouteGuard` asks for the unlock; calling a rider goes through `LockedCockpit.run(dialContact)` |

## 4. Better than the reference

1. **Safety first-class**: the speed dial ring and the arc gauge show the *effective* limit (group, personal, town and
   the road's posted limit), amber over it and red past the voice-warning margin; the reference only shows a number.
2. **One advisory strip** ordered like the warning scheduler (hazard > curve > limit > falling behind ...), with the
   comfortable speed for bends, instead of a turn card that hides warnings.
3. **"Then" line** only when it matters (next manoeuvre within 300 m of a turn that is at most 1.5 km away).
4. **No-route mode** is useful: road name + limit sign, and the sheet shows moving time and km instead of an empty ETA.
5. **Over the limit** stat (time, km, share) and **moving** average (stops do not drag it down), peak with spike
   rejection, stops counted, stats saved with the ride (survive an app restart).
6. **Bands follow the vehicle**: scooters / electric < 20, 20-40, 40-60, 60-80, 80+; most bikes < 40 ... 100+; sport,
   adventure, cars up to 120+.
7. **Group-aware**: group pill ("lead 1.2 km ahead", "Ravi falling behind"), group list with time gaps and battery,
   group view button, talk bar always in the collapsed sheet.
8. **Glove sized**: every ride control 56 dp or more (column buttons 56, back 56, pill 56, End 64, talk bar 56).
9. **Hold-to-end** instead of a one-tap STOP; the existing confirm and rules follow.
10. **Light and dark**, large text (clamped where numbers must fit), landscape side panel, lock-screen rules kept.

## 5. Map styling

The map stays on the existing raster OSM tiles (no new tile provider; offline packs depend on that URL). The dark
treatment already existed: `softDarkTileFilter` in `lib/core/theme/map_tiles.dart` (soft luminance inversion) whenever
the dark palette is on. Round 11 adds the **night map** button: it sets the same ride dark override the battery saver
uses (`ThemeController.setRideDarkOverride`), so the whole cockpit and the tiles go dark together. When the phone is
already in dark mode the button shows "on" and cannot force a light map (the override only forces dark).

## 6. Performance

* New parts sit behind RepaintBoundary: turn card, safety strip, speed dial, arc gauge, control column, charts.
* Ride stats never notify the cockpit: `SafetyService.hudStatsRevision` (a ValueNotifier) rebuilds only the stats
  cards; the accumulator does O(1) work per fix (25 histogram bins, trace capped at 240 points).
* The safety strip and the limit sign listen to `roadCare.roadView` themselves.
* The sheet drag still moves only `Positioned` widgets through `_sheetTop` / `_sheetMotion` listeners (unchanged).
* Known: the cockpit's `build` still runs when `ConvoyService` notifies (positions); that pre-dates this round. The new
  widgets are cheap in that build (no layout-heavy work, painters compare their inputs in `shouldRepaint`).
