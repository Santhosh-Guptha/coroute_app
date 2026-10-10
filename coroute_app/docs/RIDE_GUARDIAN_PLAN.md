> Current implementation, verification and remaining work: [Implementation checklist](IMPLEMENTATION_CHECKLIST.md). This plan includes future work and is not a completion report.

# Ride Guardian / Trip Monitor — feasibility and delivery plan

Status: planned, not implemented. Reviewed against the current uncommitted application on 2026-10-09. This extends Route Essentials and Smart Ride Notification work; it does not replace their pending implementation or validation. The latest shared ride coordinator changes are awaiting validation by the user's agent.

## Product decision

User-facing name: **Ride Guardian**. Action: **Share with a Ride Guardian**. Technical access principal: MONITOR, with guest or registered authentication. A guardian is an observer, never a convoy rider. Basic monitoring requires neither an account nor the native app.

Feasibility: high for scoped browser monitoring and lifecycle alerts; moderate for durable browser push, privacy-filtered group views and emergency response updates. Reliable delivery to every closed browser, exact responder ETAs without current routing data, and proof that everyone is safe are not promises the system can make.

## Fit with the current code

| Existing component | Reuse | Required change |
| --- | --- | --- |
| gateway/src/app.js, pages.js, public/ | Express-hosted website, shared templates, fonts and responsive styling | Separate /watch shell and assets; privacy headers; no trip metadata in previews |
| gateway/src/convoys.js | Current ride state, arrivals, existing hashed emergency links | Guardian service with independent grants and explicit projections; do not reuse full room snapshots |
| gateway/src/routes.js | Authenticated management and limited public endpoints | Separate guardian authorization middleware and read-only API |
| gateway/src/ws.js | Existing rider transport remains unchanged | Dedicated observer transport; never accept guardian credentials as rider JWTs or JOIN credentials |
| gateway/src/timeline.js | Persisted lifecycle, stop, offline, separation and SOS events | Allowlisted guardian event projection, audience filtering and notification policy |
| gateway/src/safety_network.js | Incident/response status | Minimal scoped status projection; availability varies because some response fields are memory-only |
| gateway/src/oracle/repo.js, retention.js | Repository-only SODA persistence, migrations and cleanup | Grant/session/subscription/delivery collections and indexes; restart-safe revocation |
| Flutter Provider/services and showAppSheet | Existing settings, share and sheet conventions | Guardian management service/models and a small sharing sheet |
| Shared ride essentials coordinator | Existing rider-side route work | No guardian GPS or POI requests; guardians consume gateway projections, not a phone-owned coordinator |

Current roles include LEAD, PACK and SWEEPER. Preserve them. Adding MONITOR to the rider-role enum or inserting guests into convoy_riders would contaminate membership-based permissions, spread, arrivals, fuel and intercom. Registered guardians also use the observer grants, separate from riding membership.

Existing /e/:token emergency links are short-lived incident links, not general trip grants. Reuse token-generation and no-cache patterns, but do not silently extend their access or expiry. Guardian storage failures must fail closed; issuing an undurable grant or acknowledging an undurable revocation is unacceptable.

## Scope and privacy matrix

Two independent dimensions: subject (PERSONAL or GROUP) and level (BASIC, LIVE or EMERGENCY_ONLY).

| Level | Personal subject | Group subject |
| --- | --- | --- |
| BASIC | Shared rider status, coarse progress, permitted stops and approximate ETA | Aggregated status, coarse progress, permitted stops and approximate ETA |
| LIVE | That rider's current/last-known position, permitted route/stops and emergency detail | Consenting riders' positions, permitted route/stops and scoped emergencies |
| EMERGENCY_ONLY | Minimal trip/access state normally; shared rider's active incident when present | Minimal trip/access state normally; consented group incidents when present |

BASIC never includes exact rider coordinates, hidden map markers, raw tracks or detailed geometry from which current positions can be recovered. EMERGENCY_ONLY reveals precise incident location only when expressly covered by that grant and rider consent. BASIC emergency alerts remain general; showing precise emergency location requires the corresponding explicit permission.

Personal access must not leak other riders through counts, timeline text, responder identities, photos, map bounds, shared stop authors or nested incident payloads. Shared destination/stop details require an explicit permission too; sharing one's current location does not automatically share the entire group's itinerary. No normal fuel estimate, litres, mileage, medical ID, chat, phone number or intercom metadata in any default projection.

Initial defaults: personal BASIC; group sharing off until enabled. Riders can grant personal access to their own information. Only the current lead/authorized creator can manage group grants. Group LIVE requires explicit per-rider consent for external visibility; exclude nonconsenting riders from individual details and clearly state coverage. Aggregate inclusion also follows ride-level disclosure consent. Joining or a leadership change must never silently broaden an existing grant. Losing management authority disables the creator's group grants pending authorized reissue; subject departure disables personal grants. Account deletion removes access and associated personal data.

Contact actions are explicit opt-ins scoped per contact and grant. Never expose emergency contacts from existing internal rosters by default. Use tap-to-call links only for authorized numbers; no automatic calls. No anonymous check-in, SOS, responder acceptance or incident-resolution action. Verified check-rider requests remain a later design.

## Sharing flow and UI

Flutter: existing group settings/share entry -> Guardian sheet -> Personal/Group -> access level -> optional label -> expiration -> optional PIN -> disclosure -> create -> native share sheet. Use existing Space, Radii, AppText, palette, loading/error and sheet conventions. Generating/sharing a link does not send a message automatically.

Disclosure: “Anyone with this link can view the selected trip information until it expires or you revoke it.” Explain group consent coverage and contacts separately. Default omit contacts.

Management lists **links/invitations**, not verified people: “Mother — Personal Live — expires …”. A forwarded anonymous link cannot prove one unique guardian. Sessions/subscriptions may be counted separately, labelled as devices, never people. Pause access, resume within the original expiry, revoke and replace. A pause closes active streams and suspends push; resume does not replay obsolete emergencies.

Hash-only token storage means the original URL cannot be recovered by the server. Offer copy/share on creation and while the app retains it in memory. Later offer “Replace link”, revoking the old one. Do not promise persistent Copy Link without choosing secure recoverable client storage explicitly.

Web: compact trip title, connection/freshness label, summary cards, optional map, rider status list and timeline. Use existing gateway public templates/assets and the same visual language, without embedding the full Flutter rider app. Mobile single column; desktop map plus summary. Large touch targets, keyboard and screen-reader support, large text and reduced motion.

State colours: blue routine, amber meaningful delay, red active emergency, grey stale/unavailable, green confirmed arrival/completion. Always pair colour with text/icon; no flashing. Say “No active alerts reported” instead of “Everyone is safe”. Completion shows confirmed arrivals and unknown/not-arrived riders separately. Manual ride end does not mean all riders arrived safely.

## Link and session design

- Generate at least 192 bits of cryptographically random token entropy; store only a cryptographic hash. Human-friendly example codes in the brief are not production credentials.
- Prefer /watch#token=… so the initial secret is not sent in URL paths/referrers. Exchange it via HTTPS POST for a short-lived, Secure, HttpOnly, SameSite guardian session; remove the fragment immediately. Test actual messaging-app link handling. No third-party scripts before exchange.
- Scope sessions to grant id/version; every snapshot, stream reconnect, push send and action rechecks active grant, expiry, subject and consent. Session expiry cannot exceed grant expiry. Support multiple grants without a single cookie silently switching another open tab's trip.
- Session creation is read-only trip access, not native account login. Validate Origin and apply CSRF protection to cookie-authenticated preference/subscription mutations. Use strict same-origin CORS, request limits and payload bounds.
- Optional PIN is separately entered, hashed with an appropriate password KDF, rate-limited per grant and origin/IP with cooldowns. Avoid a permanent global lockout an attacker can trigger. A PIN does not prevent screenshots or forwarding both secrets.
- Generic invalid/expired responses avoid revealing whether a ride exists. Use no-store, noindex/nofollow, no-referrer, restrictive CSP and safe text rendering. Exclude watch pages from sitemap and redact tokens from proxy/application/error/analytics logs. robots.txt is supplementary, never access control.
- No social previews containing trip, rider, destination or incident information. Tile/geocoding providers can receive map viewport information: assess provider terms/privacy, approved hosting and attribution before enabling the map.
- Revocation invalidates all dependent sessions/subscriptions and disconnects active streams. Recheck permission before every emission, not only when connecting. Durable versioning and bounded cache invalidation are required across processes.
- Previously viewed information/screenshots and already delivered OS notifications cannot be recalled. Push defaults to generic “Trip update — open to view”; sensitive details require a fresh authorized fetch.

Proposed lifecycle: prepared -> active -> paused/revoked/expired, with explicit terminal states. Before trip start, show a minimal waiting page, no live location. Default expiry is min(actual ride end + 6 hours, explicitly displayed absolute expiry). Initial absolute default: 72 hours from creation; support explicit multi-day dates with a proposed 14-day cap, configurable after product review. Never-started/never-ended rides therefore expire. Extending access requires explicit reissue, never silently extends old links. End-of-ride grace shows a bounded summary, no continuing live location. Emergency-only detail closes on incident resolution, with a minimal resolved event retained within the grant window.

## Proposed API and persistence

Authenticated management: POST/GET /convoys/:groupId/guardian-links; PATCH .../:grantId for pause/revoke/preferences allowed by owner policy; replacement creates a new token and invalidates the old grant. Guest routes use separate middleware: POST /guardian/session, GET /guardian/snapshot, GET /guardian/events, and scoped push subscription/preferences endpoints. Exact naming follows existing routes during implementation.

Proposed records:
- guardian_grants: id, tokenHash, creatorId, groupId, subjectType/subjectId, level, explicit permissions, label, consent version, createdAt, absoluteExpiresAt, effectiveExpiresAt, status, version, optional PIN hash.
- guardian_sessions: opaque session hash, grant/version, expiry; no synthetic rider account.
- guardian_subscriptions: session/grant reference, endpoint and keys, selected categories, expiry and last failure. Treat endpoints as credentials; validate external push destinations to prevent SSRF.
- guardian_deliveries: grant/subscription + eventId + eventRevision/channel idempotency key, status, attempts, nextAttemptAt and expiry. Bounded retention and retry.

All storage through Repo; migrate collections/indexes, cleanup through Retention, remove records on account/trip deletion as applicable. Define short configurable retention for expired grants, sessions and delivery audit, without duplicating indefinite raw trip/location histories. Durable grant writes precede issuance; database unavailability denies new access and fails closed for uncertain authorization. Test actual Oracle SODA consistency/index behavior as well as MemorySoda; in-process serialization alone is not a multi-instance solution.

## Live delivery and battery/load

Use a separate read-only SSE channel first, with conditional snapshot polling fallback. Never join guardians to rider sockets. One per-ride projection coalescer derives data from existing telemetry/timeline; normal visible updates target 15 seconds (configurable 10–30), while authorized emergency transitions bypass normal coalescing. Do not change rider GPS or telemetry frequency when viewers connect.

Use monotonic event IDs/cursors and a bounded replay window; cursor gaps cause a fresh authorized snapshot. Reapply current scope to replay; permission changes cannot replay previously allowed private fields. Coalesce duplicate tabs where supported. Suspend routine hidden-tab rendering/polling, use backoff with jitter and honor Retry-After; one refresh on foreground/reconnect. Browser suspension is expected, not a reliable background timer.

Rate-limit grant creation, exchanges, sessions, stream connections and subscriptions. Bound per-grant/per-ride fans and buffers; shed slow viewers without blocking rider/SOS processing. No per-viewer directions, reverse geocoding, fuel-provider requests or sensor work. Cache permitted route geometry per revision. Do not derive a misleading group center across loops, off-route or stale riders; unknown route relation means unknown progress/spread. ETA is labelled approximate and omitted when inputs are unsuitable.

## Event semantics and emergencies

Build from existing server events, not duplicate phone-only detectors. Allowlist fields per event and subject. Deduplicate initial/update/resolved messages by incident/event revision; keep a bounded ordered timeline and use server timestamps plus observed-at times.

Initial alerts: trip started, confirmed stop arrival/departure, destination arrival, ride ended and authoritative active SOS/assistance transitions. Show “x/y confirmed at stop” unless every expected consenting subject has arrived. Keep manual ending distinct from destination arrival.

Long stops, offline, deviation and separation are phase-two policies: proposed defaults 15-minute unplanned stop and 10-minute location silence, with hysteresis/cooldown. Suppress expected stops and pauses. A dead zone or browser disconnection is not an accident. Separate viewer connectivity, rider location age and server snapshot age. Fuel appears only through a permitted stop-plan event, not personal estimates.

Crash messaging uses the server's incident source/status after the existing detection/cancellation workflow. “Possible accident” is never upgraded to confirmed injury. Guardian fanout is queued off the critical SOS path; failures cannot delay group assistance. Responder accepted/arrived/handling/resolved must come from explicit current states. Do not fabricate group ETA or responder ETA from straight-line distance. Expose an existing fresh routed estimate only if its provenance and scope permit it; otherwise show status/distance or unavailable. External responder identity/contact/location stays hidden by default.

## Browser notifications: feasible with conditions

Foreground webpage updates work without registration or installation. Background alerts require supported browser push, HTTPS and user-granted permission. Standard implementation uses a service worker, VAPID keys, subscription storage and a durable delivery worker; these are new infrastructure (no web-push dependency is currently declared). Feature-detect rather than relying on browser names.

Apple documents web push for Home Screen web apps on iOS/iPadOS 16.4+; an ordinary no-install tab is not equivalent. Explain “Add to Home Screen to enable alerts” only when required; monitoring remains usable without doing so. On supported desktop/Android browsers offer Enable Alerts after explanation and a user gesture. Permission denial and embedded WhatsApp/in-app browsers have clear “Open in browser”/live-page fallbacks.

No delivery guarantee when offline, permissions disabled, subscriptions expired, browser/OS restrictions apply or providers fail. Notification delivery is not confirmation of human acknowledgement. Queue current relevant incident states with bounded TTL; discard resolved/outdated emergencies instead of sending a frightening backlog. Remove dead subscriptions on terminal provider responses; retry transient failures with bounded backoff. Revalidate grants immediately before sends. SMS, email, WhatsApp and OTP are deferred and require separate providers, verified recipients, consent, abuse controls and cost decisions.

## Delivery sequence and gates

1. Validate current coordinator/analyzer regressions first; keep guardian work independent of unfinished Android notification layouts.
2. Access foundation: separate grant/session model, explicit permission matrix, consent, hash/PIN lifecycle, durable revocation, audit and negative authorization tests.
3. First usable release: personal BASIC/LIVE browser view, Flutter sharing management, read-only snapshot/SSE/polling, stale/offline states and bounded summary. Group access follows the consent/projection tests; no fake guardian rider accounts.
4. Scoped timeline and emergency details, emergency-only mode, opt-in contacts and resolver/reconnect tests. Reuse emergency truth; no new SOS path.
5. Browser push and notification preferences, durable outbox and real-device matrix. Release full advertised alert experience only after this gate; foreground-only pilot is labelled clearly.
6. Group LIVE, aggregate summaries and significant-delay policies after per-rider privacy and load gates (basic group scope may ship earlier only if those gates pass).
7. Optional account linking, persistent guardian list/history within retention, verified recipient OTP/check-rider workflows and additional channels. Link an account only after proving access; never escalate scope by registering.
8. Website promotional section in the existing site templates after the feature is available. Use “Share the journey with someone you trust”, with honest browser-alert caveats; avoid safety guarantees.

Feature flags default off until release gates pass. Independent kill switches for guest monitoring and push; emergency rider flows remain operational. No deployment is part of this planning request.

## Acceptance and regression matrix

- Authorization: every subject x level x consent combination; personal data cannot leak through nested JSON, SSE, push, timeline, map geometry, counts, errors or exports. Guest credentials rejected by every rider/admin mutation and voice/telemetry channel.
- Lifecycle: creation before start, multi-day rides, no start/end, pause/resume, expiry boundary, revoke during stream/send, replacement, leadership change, subject departure, deletion, gateway restart, multiple processes and failed database writes.
- Link abuse: malformed/guessed/forwarded tokens, PIN failures, rate limits/NAT fairness, brute force, XSS labels/names, referrer/log/preview leakage, CSRF/CORS, session fixation, multiple grants/tabs, subscription endpoint SSRF.
- Network: offline open, disconnect/reconnect, HTTP alive/SSE blocked, proxy buffering, replay gaps, 401/403/410/429/5xx, timeouts, captive portal, slow consumers and retry storms. No refresh falsely makes an old position current.
- Ride semantics: solo/many/zero visible riders, late joining/leaving, stale or off-route subjects, loops, approximate/no route, stops skipped/reordered, paused/manual-ended ride, partial arrival and destination completion.
- Emergency: manual SOS, crash cancelled before escalation, member report, multiple incidents, out-of-order/duplicate/replayed updates, accepted/withdrawn/arrived responders, resolution and unknown ETA. No unauthorized contact or medical information.
- Push: unsupported/denied/revoked permission, expired subscription, browser closed/suspended, iOS Home Screen flow, expired grant while queued, quiet routine categories, idempotency, transient failures and stale-alert suppression.
- UI: narrow phone/desktop, large text, light/dark, screen reader/keyboard, reduced motion, translated safety text using existing localization conventions; screenshots for the supported browser matrix.
- Regression: rider counts, spread, fuel min/range contributors, arrivals, intercom and route permissions unchanged; no extra phone GPS; guardian backlog cannot delay SOS. Full Flutter/gateway suites plus new browser integration tests.
- Performance: baseline versus 1/10/100 viewers per ride; measure fanout, bytes, memory, CPU, DB requests and emergency dispatch latency. Establish deployment-specific limits from measurements, not promised capacity or battery savings.

## References checked 2026-10-09

- Apple: https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers
- WebKit: https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/
- MDN Push API: https://developer.mozilla.org/en-US/docs/Web/API/Push_API
- MDN notification permission/mobile guidance: https://developer.mozilla.org/en-US/docs/Web/API/Notifications_API/Using_the_Notifications_API
