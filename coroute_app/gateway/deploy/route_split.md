# Route split: LIVE (VM1) vs WEB (VM2)

Audited from `gateway/src` route definitions (app.js, routes.js, guardian_routes.js, membership_routes.js,
subscription_routes.js, admin_analytics.js, ws.js). Source of truth for the VM1 Caddy matcher:

    node deploy/gen_caddy_routes.js            # rewrites the GENERATED block in deploy/caddy/Caddyfile.vm1
    node deploy/gen_caddy_routes.js --check    # exit 1 if a route in src/ is in neither list (run before every deploy)
    node deploy/gen_caddy_routes.js --list     # every route in src/ with its class

**Rule.** A route is LIVE when it reads or changes in-memory ride state: convoy rooms (`convoys.rooms`,
`getRoom`, `getSnapshot`, anything that loads a room), live links, the emergency gateway's link table, the
safety network, the WebSocket hub (`hub.*`: sockets of riders are on VM1 only), timeline timers, or
`gate.invalidate` paired with a socket disconnect. A WEB route touches only the database, object storage or
outbound HTTP. A WEB route that ran on VM2 would see no rooms, and any route that *loads* a room on VM2 would
create a second, divergent copy of a live ride: that is the failure this split prevents.

Caddy on VM1 sends LIVE to `127.0.0.1:3000`; everything else to VM2 (`10.0.0.99:3000`) with VM1 as fallback.
VM2's Caddy (NLB backup) serves everything locally. Unlisted paths are WEB in Caddy (`--check` keeps the lists
complete). Matching is case-insensitive and accepts a trailing slash, like Express. `GET` implies `HEAD`.

Path syntax: `:param` = one segment, trailing `/*` = the path itself and everything below it.

## LIVE (VM1, 127.0.0.1:3000)

| Class | Methods | Path | Source | Why |
|---|---|---|---|---|
| LIVE | * | /ws | ws.js | WebSocket: telemetry, voice relay, SOS, convoy rooms (`Hub`) |
| LIVE | GET | /api/health | routes.js | reports `convoys.rooms.size` and socket count of the live node |
| LIVE | GET | /api/health/live | (mirror/health, M) | NLB health check of the live node |
| LIVE | GET | /e/:token | app.js | live emergency page: `convoys.liveViewLoaded` / `emergencyGateway.liveView` (memory) |
| LIVE | GET | /api/public/live/:token | routes.js | same live view as JSON (`convoys.liveLinks`) |
| LIVE | GET | /join/:code | app.js | join page; stays next to the join API it hands over to |
| LIVE | GET | /watch | app.js | Ride Guardian page; its whole API is LIVE |
| LIVE | GET | /watch-sw.js | app.js | Ride Guardian service worker (scope /watch) |
| LIVE | * | /api/guardian/* | guardian_routes.js | `GuardianService.viewGrant` -> `convoys.getRoom` (loads/reads rooms); push subscriptions |
| LIVE | POST | /api/convoys | routes.js | `convoys.createConvoy` creates the room |
| LIVE | POST | /api/convoys/join | routes.js | `convoys.joinByCode` (room membership, join limits in memory) |
| LIVE | GET | /api/convoys/active | routes.js | `convoys.getSnapshot` |
| LIVE | GET | /api/convoys/:groupId | routes.js | `convoys.getSnapshot` / `isMember` |
| LIVE | GET | /api/convoys/:groupId/emergency-roster | routes.js | `convoys.emergencyRoster` |
| LIVE | POST,DELETE | /api/convoys/:groupId/alerts/:alertId/live-link | routes.js | create / revoke live link (`convoys.liveLinks`) |
| LIVE | POST | /api/convoys/:groupId/leave | routes.js | `convoys.leave` |
| LIVE | POST | /api/convoys/:groupId/trip-head | routes.js | `convoys.setTripHead` |
| LIVE | DELETE | /api/convoys/:groupId/riders/:targetUserId | routes.js | `convoys.removeRider` |
| LIVE | POST | /api/convoys/:groupId/status | routes.js | `convoys.getRoom` + `setTripStatus` |
| LIVE | POST | /api/convoys/:groupId/tracks | routes.js | track upload reads `convoys.rooms` meta and schedules `timeline.scheduleRebuild` (in-memory timer); on VM2 a second report rebuild would race VM1's |
| LIVE | DELETE | /api/v1/sos/live-links | routes.js | `emergencyGateway.revokeLinksFor` (in-memory link table) |
| LIVE | POST | /api/v1/sos/dispatch-external | routes.js | `emergencyGateway.dispatchExternal`; in-memory dedupe and live links |
| LIVE | POST | /api/sos/dispatch-external | routes.js | same handler (legacy path) |
| LIVE | PATCH | /api/me | routes.js | `auth.updateProfile` -> `convoys.applyProfile` updates (or loads) the rider's live room: SOS roster phone / opt-out |
| LIVE | DELETE | /api/me | routes.js | `prepareErase`: leaves rooms, `hub.disconnectUser`, `timeline.forgetUser` |
| LIVE | POST | /api/geo/essentials | routes.js | `convoys.getRoom` / `isMember` |
| LIVE | DELETE | /api/membership/members/:targetUserId | membership_routes.js | `convoys.blockFutureJoin` (room meta) |
| LIVE | GET | /api/admin/fleet | routes.js | `convoys.fleet` |
| LIVE | GET | /api/admin/groups | routes.js | `convoys.fleet` |
| LIVE | GET | /api/admin/emergencies | routes.js | `convoys.emergencies` |
| LIVE | POST | /api/admin/emergencies/:groupId/:alertId/contact | routes.js | `convoys.getRoom` |
| LIVE | GET | /api/admin/safety | routes.js | `network.adminView` |
| LIVE | POST | /api/admin/broadcast | routes.js | `convoys.adminBroadcast` (sockets) |
| LIVE | GET | /api/admin/feature-analytics | routes.js | in-memory counters `convoys.featureAnalytics` |
| LIVE | GET | /api/admin/stats | routes.js | `convoys.rooms` |
| LIVE | * | /api/admin/users/* | routes.js, admin_analytics.js | riding flags from `convoys.rooms`; status / delete / config call `hub.disconnectUser` + `gate.invalidate` where the sockets are |
| LIVE | DELETE | /api/admin/convoys/:groupId | routes.js | `convoys.adminDissolve` |
| LIVE | GET | /api/admin/analytics/* | admin_analytics.js | overview / riders / groups read `convoys.rooms` |

## WEB (VM2 10.0.0.99:3000, VM1 fallback)

| Class | Methods | Path | Source | Why |
|---|---|---|---|---|
| WEB | GET | /api/meta | routes.js | static metadata |
| WEB | POST | /api/auth/* | routes.js | register / login / Google / guest: database + password hashing |
| WEB | POST | /api/pv | routes.js | page-view counter (database) |
| WEB | POST | /api/feedback | routes.js | website contact form (database) |
| WEB | GET | /api/me | routes.js | `auth.me` (database). The sliding token refresh is stateless |
| WEB | POST | /api/me/password | routes.js | database; VM1's account cache picks the change up within USER_GATE_TTL_MS (30 s) |
| WEB | GET,POST | /api/trips | routes.js | trip records (database) |
| WEB | GET,DELETE | /api/trips/:tripId | routes.js | trip records (database) |
| WEB | GET | /api/trips/:tripId/report | routes.js | stored report (database) |
| WEB | * | /api/trips/:tripId/feedback/* | membership_routes.js | reviews and review photos (database / object storage); eligibility reads the database only |
| WEB | GET | /api/convoys/:groupId/timeline | routes.js | `repo.listEvents` (rooms persist every RIDER_PERSIST_INTERVAL_MS) |
| WEB | GET | /api/convoys/:groupId/tracks | routes.js | `tracks.load` (database) |
| WEB | GET | /api/convoys/:groupId/summary | routes.js | database |
| WEB | GET | /api/convoys/:groupId/report | routes.js | database |
| WEB | GET | /api/convoys/:groupId/gpx | routes.js | `tracks.load` (database) |
| WEB | GET | /api/geo/search | routes.js | Photon/Nominatim proxy (own cache and polite queue per node) |
| WEB | GET | /api/geo/nearby-fuel | routes.js | OSM proxy |
| WEB | GET | /api/geo/poi-cells | routes.js | Map places by 0.05 degree cell (proxy and cache) |
| WEB | GET | /api/geo/reverse | routes.js | Nominatim proxy |
| WEB | POST | /api/geo/route | routes.js | OSRM proxy |
| WEB | POST | /api/geo/weather | routes.js | Open-Meteo proxy |
| WEB | * | /api/subscription/* | subscription_routes.js | payments and plans (database, Razorpay). `hub.sendToUser` notices are relayed to VM1 sockets by the mirror |
| WEB | POST | /api/validate-coupon | subscription_routes.js | coupons (database) |
| WEB | GET | /api/checkout/order/:orderId | subscription_routes.js | signed web-checkout link (database) |
| WEB | POST | /api/verify-payment | subscription_routes.js | Razorpay signature check (database) |
| WEB | POST | /api/razorpay/callback | subscription_routes.js | Razorpay redirect (database) |
| WEB | * | /api/membership/* | membership_routes.js | memberships, orders, invites, webhook (database); except DELETE members/:id (LIVE) |
| WEB | GET | /api/public/* | membership_routes.js, admin_analytics.js | community stats / stories / usage / review photos (database, object storage) |
| WEB | GET | /api/community-stats | membership_routes.js | database |
| WEB | GET | /api/community-stories | membership_routes.js | database |
| WEB | GET | /api/usage-stats | admin_analytics.js | database |
| WEB | GET | /api/impact-stats | admin_analytics.js | database |
| WEB | GET | /api/me/warnings | admin_warnings.js | database |
| WEB | POST | /api/me/warnings/:id/ack | admin_warnings.js | database |
| WEB | GET | /api/features | feature_flags.js | feature switches snapshot |
| WEB | GET | /api/road-hazards/near | road_and_places.js | database |
| WEB | POST | /api/road-hazards/:hazardId/clear | road_and_places.js | database |
| WEB | POST | /api/places/reviews | road_and_places.js | database |
| WEB | POST | /api/places/reviews/:reviewId/photo | road_and_places.js | database / object storage |
| WEB | GET | /api/places/reviews | road_and_places.js | database |
| WEB | GET | /api/places/review-summary | road_and_places.js | database |
| WEB | GET | /api/places/reviews/:reviewId/photo/:photoId | road_and_places.js | database / object storage |
| WEB | POST | /api/road-risk/brakes | road_risk.js | database |
| WEB | GET | /api/road-risk/near | road_risk.js | database |
| WEB | POST | /api/diagnostics/submit | routes.js | database |
| WEB | * | /api/admin/* | routes.js, subscription_routes.js, membership_routes.js | every other admin screen: payments, coupons, offers, pricing, payment gateway, memberships, reviews, feedback, diagnostics, audit, app builds, convoy history, page analytics (database only) |
| WEB | GET | /download | app.js | redirect |
| WEB | GET | /download/32bit | app.js | redirect |
| WEB | GET | /robots.txt | app.js | static |
| WEB | GET | /sitemap.xml | app.js | static |
| WEB | GET | /.well-known/assetlinks.json | app.js | static |
| WEB | GET | /status | app.js | static |
| WEB | GET | /community-stories | app.js | database |
| WEB | GET | /* | app.js, pages.js | website pages and static assets (public/), APKs |

## Known cross-node effects (by design, documented)

- Jobs: scheduled jobs run once across both VMs (src/job_lease.js). `guardian-push` and `convoy-auto-end`
  prefer the live node (they load rooms); everything else prefers web.
- `hub.sendToUser` from a WEB route (plan activated / revoked) or from the subscriptions job is relayed to the
  rider's socket on the other VM by the mirror (`U` frames). With the mirror link down it reaches only local
  sockets; riders then see the change on the next `/api/me`.
- The account cache (`UserGate`) is per node: a password change or admin action on VM2 reaches VM1 within
  USER_GATE_TTL_MS (30 s). Admin user actions are LIVE for that reason.
- Feature analytics counters are per node; `/api/admin/feature-analytics` shows VM1's (the ride features).
- Geo proxies keep a per-node polite queue: two nodes may each send up to 1 request/s to Nominatim from two IPs.
