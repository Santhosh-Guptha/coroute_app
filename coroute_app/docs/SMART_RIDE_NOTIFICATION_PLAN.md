> Current implementation, verification and remaining work: [Implementation checklist](IMPLEMENTATION_CHECKLIST.md). This plan includes future work and is not a completion report.

# Smart ride notification: Route Essentials plan addendum

Status: approved product requirement, implementation pending. This document extends the Route Essentials / Personal and Group Fuel Intelligence plan. It does not mark the existing implementation complete. The earlier Dart library/analyzer fixes passed the user-reported validation. The subsequent shared ride coordinator changes await a new validation run.

## Existing implementation to extend

- `lib/data/services/ride_notification_service.dart`: notification lifecycle, throttling, background-service replacement and action dispatch.
- `lib/domain/notify/notification_snapshot.dart`: immutable notification content, rider ladder, emergency modes and deduplication.
- `lib/core/constants/ride_notification_constants.dart`: two riders per side, ten-second normal update interval and existing actions.
- `android/app/src/main/kotlin/space/devmonks/coroute_app/RideNotification.kt`: native RemoteViews and PendingIntent handling.
- `android/app/src/main/res/layout/ride_notif_collapsed.xml` and `ride_notif_expanded.xml`: existing native templates.
- `lib/presentation/rider/rider_home_screen.dart`: navigation from notification actions.

Keep one ongoing foreground ride notification using the existing id and channel. Preserve rich-notification and lock-screen settings, emergency priorities, fallback behaviour and SOS hold-to-send flow. Do not create a media session or media playback service for this feature.

## Display modes

Collapsed: ride name and one actionable summary, for example "Fuel 12 km ahead | est. usable range 84 km". If fuel is unknown, use the next planned stop or group state. Emergencies replace routine summaries.

Expanded Group view: a compact route-relative line with the current rider explicitly marked "You", nearest ahead/behind riders, signed distances, and travel direction. Initial phone layout uses one rider per side; show up to the existing two per side only when height and text size permit. Show "+N riders" to open the complete rider sheet. Use fixed semantic slots, not a proportional scale that would hide close riders. Mark the line "not to scale" through accessible description and expanded details.

Example: "Rahul -1.4 km -- You -- Kiran +2.1 km". All distances are from the current rider, not distances between adjacent riders. When route relation is unavailable or ambiguous, show "distance away / direction unavailable" rather than an ahead/behind claim. Off-route riders appear separately. Stale riders retain last-known position and age; never present a stale relative order as current.

Expanded Fuel view: keep You as the reference and display two upcoming mapped stations on a separate line, plus estimated usable range and one explanation. Example: "You -- Fuel A +12 km -- Fuel B +80 km" and "68 km between mapped stations; est. usable range 54 km". Do not mix from-rider distances with gaps. Distinguish along-route progress from road access distance and extra detour. Where current road access is unknown, label that clearly and suppress skip advice. Never use actual-looking fuel percentages without a sensor.

Other context views use the same space: planned stop with arrival count, route weather with forecast arrival time, or a priority alert. Do not display every rider, place and alert simultaneously.

## Interaction

- The system expansion affordance reveals the large notification; expansion cannot be guaranteed by the app.
- Tapping the Group or Fuel view selector may replace the expanded content in place using native supported controls. No notification mini-app, scroll list or nested popup is required.
- Tapping a rider opens their current rider sheet. Tapping the fuel icon or fuel summary opens Route Essentials filtered to Fuel, showing next stations, road distances, gaps, detours, estimate confidence and freshness. Tapping an alert opens that specific alert's description and actions.
- Use an icon plus short text ("Fuel", "Offline", "Regroup"), never colour or an unexplained symbol alone. Collapse multiple routine alerts into one priority item and "+N".
- Keep Open ride/map, Wait for me and the existing SOS confirmation entry available within the platform layout budget. Swap optional context content; do not squeeze many tiny actions into a row.
- Refuelling confirmation, adding/suggesting stops and changing the group plan happen in the existing app sheets while stopped. Opening a notification never automatically confirms a fill, sends SOS, changes a route or sends a group message.
- Validate group id, user/session, route revision and target id again when handling an action. Old or expired targets open the current ride overview with an explanatory message. Handle foreground, background, cold start, locked screen and repeated taps.

## Shared state and background operation

The current essentials controller is screen-owned. Before this notification can show fuel reliably with the map closed, introduce a ride-scoped coordinator sharing route, rider progress, fuel estimate and cached essentials with the screen and notification. The notification consumes the same snapshot; it must not create a second GPS subscription, matching engine or place-provider polling loop.

The coordinator follows group route changes and personal reroutes even when no map widget is mounted, using existing background fixes. Reject old-route responses. If background routing or GPS is unavailable, invalidate affected guidance and display last-updated state until the app can refresh; do not promise operation after a force-stop or revoked background permission.

Add typed snapshot fields for self position, mode, rider identities, essentials, estimate confidence, coverage, freshness, contextual alert and action target. Keep platform payloads small and versioned. Preserve older native/plain notification fallback.

Normal numeric updates retain the existing ten-second throttle and rounded distances. Actual emergency/priority transitions can refresh immediately. Freshness expiry must update even while stationary without causing network requests. Notification refreshes should be silent; use the existing deduplicated voice policy for appropriate alerts. Never announce every station or GPS movement.

## Offline, privacy and reliability

- Show cached POIs with their original timestamp, last-known riders with ages, and connection state separately from GPS state.
- No cache means "Fuel information unavailable offline", not zero stations or guaranteed absence.
- Reconnection performs one bounded refresh with backoff and merges current state. Repeated failures cannot flash, duplicate or reorder notifications.
- Fuel-sharing consent applies to group estimates. Fuel litres/mileage remain private. Private lock-screen mode hides names, positions, fuel estimates and destinations while retaining the existing emergency exception selected by the user.
- Low-data and battery-saver settings reduce noncritical refresh work without weakening SOS delivery. Android denied notification permission, service termination, OEM background restrictions and rich-view render failure have explicit fallback states.
- Do not claim exact Spotify size, always-expanded presentation or unrestricted lock-screen interactions. Native system colours, readable text and accessible labels take precedence over copying app colours.

## Additional recommended improvements

1. A "Group / Fuel" preference, with temporary priority-alert override and automatic return after the alert resolves.
2. Next group stop distance and arrived/expected count using existing arrival records; unknown/offline arrival is not counted as confirmed.
3. Leader view showing group spread, current fuel-estimate contributor count and offline rider count, within the same compact content budget.
4. A useful group fuel recommendation must compare each contributing rider's own road distance to the station, not the leader's distance against the lowest range.
5. Route-gap warning with an explanation and a deep link; "Can I skip?" stays in the detailed sheet and never says "safe to continue".
6. A user preference for names on the lock screen and for compact-only notifications; honour existing privacy defaults.
7. Planned-stop approaching cue and weather-ahead cue, subordinate to SOS, assistance and hazards.

## Delivery sequence

1. Fix and validate current analyzer/UI failures; add widget imports/render tests.
2. Extract shared ride-scoped essentials state and cover background lifecycle, route revision and caching.
3. Extend snapshot model and pure policies, then native compact/expanded templates and labelled rider/fuel line.
4. Add view switching, deep links, fuel/alert context and existing-action compatibility.
5. Add offline freshness, privacy, group summaries and low-data behaviour.
6. Validate native layouts on real/emulated Android devices, then rollout with the existing rich-notification fallback. Advanced future provider/sensor integrations remain later phases.

## Acceptance tests

- Rider line: solo, one side empty, many riders, same-position riders, loops, divided roads, direction unknown, off-route riders, stale updates and reordering without flicker.
- Fuel: unset profile/baseline, full/partial fill, changed profile, tracking gaps, reserve/buffer, station passed, inaccessible station, missing following station, partial/stale coverage and reroute during fetch.
- Network: offline start with/without cache, disconnected socket with working HTTP, lost GPS with working network, intermittent signal, timeout, captive portal, 401/403/429/5xx, backoff, reconnect and route change while offline.
- Actions: every icon opens its intended description; foreground/background/cold launch; locked device; outdated group/route/alert; duplicate tap; permission denied; role changes; no automatic irreversible actions.
- Priority: SOS replaces fuel; resolving SOS restores current content; muted warnings remain visible; routine updates do not play sounds or reset expanded mode.
- Privacy: public/private lock screen, sharing off/on/withdrawn, expired peer estimates, sign-out/account switch and old notification intents.
- Native layout: supported Android versions including Android 12+ and Android 13+ permissions, narrow phones, large fonts, light/dark system themes, TalkBack, rotation, and representative OEM skins.
- Lifecycle/performance: map closed, screen off, app recreation, service restart, notification replacement by plugin, ride end, low battery, denied background location and no duplicate GPS/provider work.

Flutter widget tests alone do not validate Android RemoteViews. Require native build plus emulator/device notification inspection before claiming this feature verified.

Reference: https://developer.android.com/develop/ui/views/notifications/custom-notification
Reference: https://developer.android.com/about/versions/12/behavior-changes-12

## Alert-aware appearance and battery efficiency (additional requirement)

The notification should feel calm, polished and useful at a glance: rounded tinted surfaces, a thin accent outline, stable tabular distance text, a clear You marker and labelled alert icons. Avoid flashing red, pulses, animated gradients and decorative redraws. Keep normal system notification chrome and native text appearances.

Colour meanings:

| State | Surface and accent | Meaning |
| --- | --- | --- |
| Normal ride | Muted blue/cyan | Routine group and route information |
| Warning | Amber | Fuel recommendation, significant separation or actionable warning |
| Critical | Red | Existing emergency/critical priority; colour never upgrades a routine fuel suggestion to SOS |
| Positive | Green | Existing positive/acknowledgement state, not a guarantee that conditions are safe |
| Offline/unknown (planned) | Neutral grey plus timestamp | Missing or stale information, not an emergency by itself |

Implementation status for this increment: the existing native tone now selects matching light/dark rounded surfaces in both notification layouts. Full notification shade tint is deliberately not requested; Android/OEM controls that outer area. Icons, wording and priority must continue to explain the state without relying on colour. Fuel-specific colour transitions still depend on the planned shared essentials/notification coordinator.

### Battery work implemented in this increment

- Stationary routine telemetry follows the existing 30-second heartbeat cadence instead of using the moving interval on every stationary GPS fix.
- A pure power policy enters conservation at 15% battery, remains there until 20%, and exits while charging. This prevents repeated switching around a threshold.
- Moving routine telemetry uses the existing 5-second low-data cadence in conservation mode; normal cadence remains 2.5 seconds. Significant movement and existing status transitions can still send earlier.
- Routine notification refreshes slow from 10 to 20 seconds during conservation. Existing emergency/mode transitions still request an immediate update.
- Active emergencies, assistance requests and hazards retain the normal telemetry/notification cadence. GPS accuracy, crash detection, SOS actions and intercom sampling are not reduced by this increment.
- Invalid UTF-8 bytes in the two new sheet libraries were repaired; this is separate from battery behaviour.

These are bounded reductions in routine work, not a measured battery-life improvement. Field measurement and native rendering checks remain required.

### Broader optimisation backlog, in recommended order

1. **Screen and rendering:** keep screen-on opt-in; stop offscreen map animations and marker interpolation; use static notification graphics; rebuild only changed rows and rounded numbers. Respect reduced motion. Do not force system brightness changes.
2. **Shared location:** one GPS stream for map, recording, fuel, safety and notification. Retain accurate moving fixes; measure existing idle-profile resume latency before increasing idle intervals. Never lower location accuracy merely because the map is hidden during an active ride.
3. **Network batching:** deduplicate route/category requests, share group route caches, coalesce telemetry with existing heartbeats, bounded jittered reconnect backoff, honour rate limits, and stop retrying non-retryable authentication failures. Emergency outbox traffic takes priority over POI, weather and uploads.
4. **Offline preparation:** offer route essentials/map download while on Wi-Fi or charging, with visible size/progress and cancellation. Cache only bounded route corridors. Honour provider caching terms. Suspend optional prefetch at low battery rather than interrupting critical tracking.
5. **Sensors:** compass only while visible/needed, existing conditional crash accelerometer retained, no microphone capture when intercom is idle, prompt release of audio/wake resources at ride end. Verify reconnect and Bluetooth lifecycle so resources do not remain held accidentally.
6. **Storage and CPU:** batch track writes, incremental route matching, bounded cache size, move expensive parsing/simplification off the UI thread only when profiling shows benefit. Persist refuel confirmations and emergency actions promptly, not in a delayed bulk batch.
7. **Notification workload:** compare stable snapshots before native calls; one ongoing notification; one freshness-expiry timer; rate-limit routine changes without suppressing alert severity changes; restore plain fallback on rich-view failure.
8. **Optional ride power settings:** Balanced and Battery saver with a plain explanation of routine update cadence; automatic low-battery assistance; expose current mode without repeatedly notifying the group. Emergency overrides must be visible and reversible when the incident ends.
9. **OS lifecycle:** use supported foreground-location behaviour; stop work when a ride ends; handle revoked permissions, process recreation, Doze and OEM limitations honestly. Do not rely on aggressive battery-optimisation exemptions as the main efficiency strategy.
10. **Measurement:** compare identical 60- and 120-minute rides with screen on/off, stationary/moving, strong/weak/no signal, Bluetooth intercom, low battery and charging. Record battery drain, CPU time, wake locks, GPS requests, provider calls, radio bytes and notification posts. Use Android power/system tracing tools and representative real phones.

Release gates: no regression in SOS dispatch, crash-event processing, rider freshness, stop detection or route guidance latency. Run policy tests, service regressions, analyzer, native build and on-device layout/power checks. Set quantitative battery targets only after establishing a repeatable baseline; do not promise a percentage saving or zero issues before measurement.

Reference: https://developer.android.com/develop/sensors-and-location/location/battery

## Related feature family: Ride Guardian (2026-10-09)

See [Ride Guardian feasibility and delivery plan](RIDE_GUARDIAN_PLAN.md). This adds scoped, account-free browser observation using separate observer grants, never rider membership. Guardians cannot change group spread, fuel, arrivals, route permissions or intercom. Existing rider emergency and notification priorities remain unchanged.

Sequence: validate the shared coordinator first; build guardian access/privacy and browser views independently; add durable browser alerts after supported-device validation. Guardian monitoring does not require completion of the native Group/Fuel notification redesign. No extra rider GPS, provider queries or per-viewer phone work. Web push is conditional on browser permission/platform support, including the iOS Home Screen requirement.

The new plan covers personal/group scope, consent, BASIC/LIVE/EMERGENCY_ONLY levels, expiring/revocable links, guest sessions, response-status projections, background push infrastructure, battery/load controls and acceptance tests. It is planning only; no guardian feature has been implemented.
