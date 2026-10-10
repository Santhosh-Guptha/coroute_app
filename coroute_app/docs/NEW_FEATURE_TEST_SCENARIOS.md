# New feature test scenarios and execution checklist

Updated 2026-10-09. Scope: implemented Route Essentials, fuel, shared coordinator, smart ride notification, battery policy and Ride Guardian. This is a bounded coverage inventory, not a claim that every possible condition has been tested. Future features in IMPLEMENTATION_CHECKLIST.md require their own tests when implemented.

## Execution rules
Use isolated test accounts and a test ride. Never send real SOS, external messages or push to uninvolved users. Use fake clocks/providers for automated failures. Device scenarios below are NOT verified by unit tests. Record device/OS, build, setup, expected/actual result and evidence for each execution.

## Automated scenario inventory

Executable names below map to current source. Device cases remain separate.

### [test/route_essentials_test.dart](../test/route_essentials_test.dart)

- unknown baseline is unknown; reserve and buffer deducted once
- partial fills add to remaining fuel, full fill resets and capacity caps
- invalid amounts do not mutate state; config changes invalidate old baseline
- simple range mode supports a current estimate and reserve
- bad profiles and corrupted state are rejected
- tracking gaps invalidate confidence, partial fill cannot erase uncertainty
- duplicate or out-of-order fixes cannot rewind the distance anchor
- four levels, unknown coverage, boundaries and from-rider distances
- GPS updates use cache; offline and data saver make no calls
- outage retains timestamp and options with bounded retry
- restart offline restores route-specific cache
- late old route response cannot overwrite rerouted results
- concurrent updates deduplicate requests
- approximate route clears old results without network
- HTML captive portal, unauthorised, rate limit, invalid JSON retain cache
- empty success differs from provider failure; malformed places mark partial
- stale provider fallback does not trigger a request storm
- corrupt cache and failed disk writes leave live results usable
- $status blocks forced retries until credentials change
- expired and future disk snapshots are not shown offline
- timeout preserves last success and recovery clears failure
- default disk writes from separate services retain both routes
- disk failure is recoverable without discarding live data
- default cache keeps newest eighteen entries across independent services
- road access distance becomes unknown after passing its entry anchor

### [test/fuel_range_test.dart](../test/fuel_range_test.dart)

- sums the distance between consecutive fixes
- skips a jump over 500 m and a gap over 5 min (GPS teleports, restarts)
- warns once per fill at 80% of the range; "Filled up" resets
- round-trips through JSON
- prompt at 80% of the range, once; "Filled up" resets the count
- arriving at a FUEL stop never assumes refuelling
- the count survives a restart of the app in the same ride
- range 0: no reminder

### [test/fuel_notification_test.dart](../test/fuel_notification_test.dart)

- route line is from self and warning uses road access distance
- stale offline uncertain and passed-access data never creates a fresh fuel warning
- missing data and profile stay explicitly unknown

### [test/fuel_sharing_binding_test.dart](../test/fuel_sharing_binding_test.dart)

- sharing is opt-in, minimal, withdrawn immediately and detached on disposal
- unknown nonfinite and unconfirmed fuel never leaves the phone

### [test/ride_power_policy_test.dart](../test/ride_power_policy_test.dart)

- low battery enters at 15 and recovers at 20 without flapping
- charging restores normal cadence and invalid readings do not change it
- stationary telemetry remains present with a thirty second heartbeat
- moving cadence follows low data or low battery, critical activity overrides both
- only noncritical notification refreshes slow down on low battery

### [test/ride_essentials_coordinator_test.dart](../test/ride_essentials_coordinator_test.dart)

- works without a map and shares discovery across fixes
- offline start and reconnect perform one bounded refresh
- stale GPS expires while stationary without network work
- old future inaccurate and duplicate fixes cannot move progress
- account switch resets matching and rejects pending results
- route change rejects the old response
- conservation suppresses optional work but allows explicit refresh
- ride end and revoked GPS invalidate guidance without fetching

### [test/essentials_ui_test.dart](../test/essentials_ui_test.dart)

- fuel profile sheet renders with large text on a narrow screen
- failed stop submission stays retryable; successful request disables it

### [test/guardian_ui_test.dart](../test/guardian_ui_test.dart)

- narrow large-text sheet requires acknowledgement and validates PIN locally
- load failure can retry and failed consent does not change sharing
- pause resume and revoke update links only after success
- account switch discards delayed old-account links

### [test/ride_notification_service_test.dart](../test/ride_notification_service_test.dart)

- freshness deadline updates without another location event and stops after disposal
- stale fuel action falls back to map and ended ride ignores fuel action
- 3.16: the medical ID provider is asked on every push; my own SOS shows it and the key changes
- nothing without a ride; pushes at once when the ride starts
- at most one push per 10 s, only when the content changed
- an emergency is pushed at once (mode change), ignoring the 10 s window
- three failures in a row fall back to the plain notification for the ride
- a success after a failure clears the count; a throw counts as a failure
- no native side (MissingPluginException) or unsupported phone: plain notification
- setting off: plain notification; on again: pushed again
- lock screen setting reaches the native side
- ride end: rich off, nothing pushed
- buttons: SOS opens the hold screen (never sends), Wait, I Can Help, Open map
- the button that started the app is taken once at start
- service (re)start: pushed again at once and checked again 3 s later
- swiped away (ensure false): plain one back, ours again on the next change
- native action names map to kinds; unknown ones are ignored

### [test/notification_snapshot_test.dart](../test/notification_snapshot_test.dart)

- two riders ahead and two behind, nearest first, with flags
- header: destination, remaining km along the route and ETA as a clock time
- no destination: the convoy name; no route: crow-flies remaining, no ETA
- rounding keeps the text stable across small moves (same dedupeKey)
- dedupeKey is equal for equal input and covers the lock-screen choice
- without a route my heading decides the side; unknown side is listed as away
- status line: the worst open group warning
- my own Wait for me shows as confirmation
- alone: waiting for the group, no Wait for me button
- group emergency: red, distance and update time, Navigate to the rider
- manual SOS says needs help; responder line is positive
- nearest member line when nobody is responding yet
- my own SOS: no SOS button, no Navigate
- my own SOS with the medical ID setting (3.16): blood group, allergies and contact on the lock screen
- rider down reports (3.16): the reporter is named, never "may have met with an accident"; my own nearby report is not my SOS
- assist request before accepting: distance only, I Can Help, never a name
- assist accepted: responding, ETA, Navigate
- declined requests are not shown
- hazard: amber caution with the distance
- priority: group emergency > assist > hazard > ride
- quick state matches the built mode and changes with the emergency state
- public version is minimal; emergency adds a line without names
- no phone numbers, contacts or plates anywhere in the channel arguments
- channel arguments carry the service notification id and channel
- StatusText.flagFor

### [gateway/test/essentials.test.js](../gateway/test/essentials.test.js)

- validates malformed, approximate, oversized and invalid category inputs
- window is bounded and advances every 5 km to avoid exhausting dense-city candidates
- road detour includes return and provides separate access distance
- duplicate place ids are deduplicated within a pass, not across loops
- fresh cache and concurrent clients share a discovery request
- outage serves old cache with original timestamp, never fresh empty data
- outage without cache and cache older than seven days fail explicitly
- routing failure produces partial coverage and no invented detour
- routing shortcuts and non-finite results are rejected
- bounded candidates remain partial; empty complete provider results stay non-exhaustive
- route/category changes do not share stale results
- storage failure does not prevent a successful live response
- provider disabled fails without upstream work
- Overpass errors, timeout remarks and malformed replies fail explicitly
- Overpass sends fixed category query and preserves unknown opening status

### [gateway/test/essentials_integration.test.js](../gateway/test/essentials_integration.test.js)

- fuel telemetry is opt-in, bounded and contains no private tank data
- old group fuel estimates expire independently of rider heartbeat
- essentials endpoint requires auth; invalid requests and disabled provider are explicit
- group websocket shares only own fuel estimate and withdraws it on opt-out

### [gateway/test/guardians.test.js](../gateway/test/guardians.test.js)

- credentials are hashed and observers never enter the rider roster
- personal LIVE exposes no peer, contact, fuel, destination or medical fields
- BASIC omits exact location even during own emergency
- emergency-only hides routine identity and unrelated incidents
- group scope, impersonation, contacts and unacknowledged access are rejected
- revocation persists across service instances and rejects existing sessions
- leave and rejoin cannot resurrect a personal grant
- blocked and deleted accounts fail closed
- absolute expiration and session expiration use exact boundaries
- before start and after end have no position or inferred safe arrival
- invalid/future positions are hidden and old locations remain explicitly stale
- persistence failure issues neither a grant nor a session
- revocation failure is not acknowledged and read failures do not fall back to cached authorization
- malformed credentials and invalid expiration are rejected
- retention removes expired access records including revocation tombstones
- group sharing includes only pinned consent and withdrawal removes a rider immediately
- group BASIC aggregates without individual data and loss of lead authority ends access
- PIN is hashed, never listed, and is required before a session is issued
- convoy deletion clears observer credentials and leaves other rides intact
- timeline filters scope, duration, planned stops, pauses and private fields
- emergency-only timeline excludes routine and peer events
- pause resume preserves expiry and permanent revocation; deleted grants fail closed

### [gateway/test/guardian_push.test.js](../gateway/test/guardian_push.test.js)

- subscription endpoint allowlist prevents arbitrary requests and malformed keys
- routine unchanged state is quiet; emergency delivery is generic and deduplicated
- transient failures retry durably but an obsolete emergency is discarded
- revocation and browser opt-out prevent queued delivery
- repeated trip state cycles have distinct delivery revisions
- changed preferences invalidate jobs queued for an older subscription revision
- unsubscribe while preparing a delivery cancels it before sending
- invalid preferences rejected and permanently gone push endpoint removed
- shutdown prevents delivery and concurrent ticks share one worker

### [gateway/test/guardians_integration.test.js](../gateway/test/guardians_integration.test.js)

- guest cookie access is scoped, revocable and never rider authentication
- PIN and pause are enforced over HTTP and guest access cannot manage a link

### [gateway/test/guardian_browser.test.js](../gateway/test/guardian_browser.test.js)

- observer page strips capability and clears private DOM when hidden or revoked
- late response after pagehide cannot restore private location
- PIN denial waits for user input and offline failures use bounded retry
- service worker rejects malformed payloads and external click destinations

### [gateway/test/guardian_push_http.test.js](../gateway/test/guardian_push_http.test.js)

- enabled push HTTP endpoints enforce origin, session and subscription ownership

## Device/browser and end-to-end acceptance cases

All cases in this section are **pending manual/device execution** unless a result is explicitly attached. Automated coverage of individual calculations does not verify the full device flow.

| ID | Setup and steps | Expected result |
|---|---|---|
| NET-01 | Start offline with no saved route essentials; open Fuel and every category. | Explicit unavailable/offline state; no fabricated stations or range assurance; responsive controls. |
| NET-02 | Load online, terminate app, relaunch offline on same route. | Saved entries use original age; cache is labelled; no fresh-coverage claim. |
| NET-03 | Repeat with different route/category, expired cache and corrupt storage. | Wrong/expired data is not reused; corrupt storage does not prevent later live recovery. |
| NET-04 | Toggle Wi-Fi/mobile/airplane mode during discovery and stop submission. | No duplicate stop, stale result overwrite or endless spinner; actionable retry. |
| NET-05 | Simulate DNS failure, TLS error, timeout, captive HTML portal and connection reset. | Safe failure state; previous valid data keeps its timestamp; bounded retry. |
| NET-06 | Return 401/403, then repeated refreshes, then sign in with new credentials. | Failed credentials do not cause retry storms; new credentials allow recovery. |
| NET-07 | Return 429/500/502/503 then recover. | No false empty-success response; retry/backoff and explicit refresh recover. |
| NET-08 | Change route/account/ride while response is delayed; end ride mid-request. | Old response cannot populate the new context or trigger an old action. |
| NET-09 | Enable low-data mode and battery conservation, move repeatedly, then explicit refresh. | Optional requests suppressed; explicit permitted refresh works; no extra GPS stream. |
| ESS-01 | Route loop, parallel road, divided road, inaccessible pump and provider duplicate. | Correct route visit/order; road access and return detour; no invented shortcut. |
| ESS-02 | Cross discovery window boundary; drive beyond a station entry. | Window refresh is bounded; passed access does not remain a reliable upcoming road distance. |
| ESS-03 | Provider disabled, partial routing, malformed place, valid empty set. | Each has distinct honest status; partial results never imply exhaustive coverage. |
| ESS-04 | Lead adds stop; member suggests; simulate submission failure and retry. | Role respected, useful feedback, retry possible, no duplicate mutation. |
| FUEL-01 | Unknown profile, litres profile and simple-range profile; change capacity/mileage. | Unknown stays unknown; reserve/buffer deducted once; incompatible baseline invalidated. |
| FUEL-02 | Full refill, partial refill, zero/negative/nonfinite/over-capacity inputs. | Valid updates only; explicit refill required; no refill inferred from arrival. |
| FUEL-03 | GPS gap, poor accuracy, duplicate/out-of-order/future fix, restart. | Distance not rewound or inflated; uncertainty survives restart. |
| FUEL-04 | One rider opts in/out; estimate expires while heartbeat remains current. | Only fresh opted-in usable range contributes; private tank data absent. |
| FUEL-05 | Test advice thresholds exactly below/equal/above station road distance. | Consistent caution; stale/offline/uncertain data cannot create fresh range assurance. |
| UI-01 | 320/360px width, landscape, 1.3x/2x text, dark/light mode. | No clipped primary controls or unreadable distances; sheets scroll. |
| UI-02 | Screen reader, keyboard navigation and high contrast. | Meaningful focus/labels; colour not the only alert signal. |
| UI-03 | Repeated open/close, back navigation, rotate, app resume during loading. | No disposed updates, duplicate listeners or lost error recovery. |
| NOT-01 | Start/end ride, collapse/expand notification, switch Group/Fuel. | Correct content and actions; ride end removes stale notification. |
| NOT-02 | Ahead/behind unavailable, stationary, off-route, stale rider and many riders. | Unknowns labelled; line does not invent order or imply accurate scale. Track known roadmap gaps. |
| NOT-03 | Tap fuel details foreground/background/cold start; reroute or switch account first. | Opens appropriate current context or safe fallback; never acts on stale ride. |
| NOT-04 | Trigger warning/critical/positive state, then recover; trigger SOS while Fuel view open. | Correct severity surface and accessible wording; emergency priority retained. |
| NOT-05 | Deny notification/location permission; disable channel; force-stop process. | Honest capability state, no false background-monitoring promise; recovery after permissions restored. |
| NOT-06 | Android supported minimum/current versions and OEM battery restrictions. | Native layout/actions verified on each; OS restrictions documented. |
| BAT-01 | Battery 16→15→19→20, charging on/off, invalid battery values. | Conservation hysteresis works without flapping. |
| BAT-02 | Stationary/moving, low-data on/off, emergency on/off. | Routine cadence follows policy; critical events retain intended cadence. |
| BAT-03 | Screen-off ride benchmark, same route/device/duration versus baseline. | Record battery drain, GPS subscriptions, CPU wakeups, bytes and request counts; no unsupported savings claim. |
| GUA-01 | Create each access level; open shared link in clean browser. | Scope matches consent; observer never joins rider roster or gets rider write privileges. |
| GUA-02 | Missing/wrong/correct PIN, malformed token, brute-force attempts. | No session on denial; throttling; secrets absent from logs and rendered page. |
| GUA-03 | Pause/resume/revoke while browser open and push queued. | Pause hides data; resume preserves expiry; revoke stays permanent. Already delivered notifications cannot be recalled. |
| GUA-04 | Leave/rejoin, leader demotion, blocked/deleted owner, deleted ride. | Access fails closed; cleanup reviewed separately; no resurrection. |
| GUA-05 | Consent withdrawal during fetch; opt-in after link created; revoke/reconsent. | Old link never gains new people; withdrawal removes prior subject. |
| GUA-06 | BASIC during SOS; emergency-only before/during/after own/peer alert. | Only authorized facts; no private contacts, fuel, medical fields or unconsented peers. |
| GUA-07 | Exact expiry, trip planning/pause/end, six-hour end boundary and clock anomalies. | No position before start/after end; ended is not inferred safe arrival; expiry enforced. |
| GUA-08 | Offline browser, hidden tab, regain visibility, reload and simultaneous links. | Data clears or is clearly unavailable; bounded polling; sessions do not replace unrelated links. |
| GUA-09 | Timeline includes short/long stops, offline duration, planned stop, SOS and peer events. | Authorized bounded timeline; sustained thresholds. Known planned-stop/pause intervals are now suppressed; validate end-to-end and bounded history. |
| PUSH-01 | Unsupported browser, denied permission, disabled server; user enables supported push. | Honest capability status; permission only on explicit action. |
| PUSH-02 | Actual configured test push on Chrome/Firefox/Android and iOS installed web app. | Generic notification; click uses valid bounded ticket; no secret in notification text. |
| PUSH-03 | Upstream timeout/429/5xx, 404/410, worker restart and duplicate delivery. | Bounded durable retries; obsolete work canceled; invalid subscriptions removed; stable notification tag. |
| PUSH-04 | Opt-out/revoke/consent withdrawal while queued, repeated trip-state transitions. | No further authorized delivery; state cycles not incorrectly deduplicated. |
| PUSH-05 | Multiple server workers, backlog and shutdown during delivery. | Measure delivery/duplication; atomic claiming is pending and blocks production-load certification. |
| SEC-01 | Cross-origin exchange, copied guest cookie on rider APIs, raw watch source, cache headers. | Origin restriction, no rider authorization, source hidden, no-store/no-referrer and CSP present. |
| SEC-02 | Inspect network/logs/cache after sign-out/revoke; malicious names and labels. | No executable markup, private field leakage or secret persistence outside intended secure storage. |

## Remaining validation work
- Native broadcast fallback, OS cold launch and permission/process-death checks on devices.
- Real-browser rendering/accessibility and real service-worker push delivery; VM DOM coverage is now implemented.
- Distributed push atomic claiming, multiworker load/restart races and production Oracle retention/deletion checks.
- Fuel preference/account-scoping review on shared devices.
- Device battery/network measurement and signed release/R8 smoke tests.
These are explicit unchecked gates. Completed Guardian widget, timeline, push HTTP, cache bounds/recovery and fuel binding tests are listed above.

## Commands and latest results
Run Flutter from coroute_app; Node from coroute_app/gateway.
```powershell
& 'C:/Users/santhosh/flutter/bin/flutter.bat' analyze
& 'C:/Users/santhosh/flutter/bin/flutter.bat' test --no-pub
npm test
```
Latest execution: expanded focused Flutter suite **90/90 passed**; full gateway suite **260/260 passed**. These are the counts actually reported for the current working tree; earlier runs had different totals. Secure-storage plugin warnings in Flutter tests mean native secure storage was not exercised. Analyzer/full Flutter suite and manual/device cases were not rerun in this test-writing pass.

Latest completion pass: Flutter full suite 888/888 plus 2/2 later fuel-binding tests; gateway 273/273; Android debug build passed. See [Release handoff](RELEASE_HANDOFF.md) for final analyzer result and unchecked release gates.
