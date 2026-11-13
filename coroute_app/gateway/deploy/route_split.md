# Route split: LIVE (VM1) vs WEB (VM2)

Audited from the routes the gateway really serves (round 6: the check walks the booted express app, every router
and mount prefix included, not a text scan of `src/`). Source of truth for the VM1 Caddy matcher:

    node deploy/gen_caddy_routes.js            # rewrites the GENERATED block in deploy/caddy/Caddyfile.vm1
    node deploy/gen_caddy_routes.js --check    # exit 1 if a served route is in neither list, or the Caddyfile block is stale
    node deploy/gen_caddy_routes.js --list     # every served route with its class and the row that matched

The check is STRICT: `deploy/release.sh` stops on an unclassified route (`--skip-route-check` is the explicit,
logged escape), and `test/route_split_356.test.js` fails in `npm test`. A new route needs a row here first.

**Rule.** A route is LIVE when it reads or changes in-memory ride state: convoy rooms (`convoys.rooms`,
`getRoom`, `getSnapshot`, anything that loads a room), live links, the emergency gateway's link table, the
safety network, the WebSocket hub (`hub.*`: sockets of riders are on VM1 only), timeline timers, or
`gate.invalidate` paired with a socket disconnect. A WEB route touches only the database, object storage or
outbound HTTP. A WEB route that ran on VM2 would see no rooms, and any route that *loads* a room on VM2 would
create a second, divergent copy of a live ride: that is the failure this split prevents.

Caddy on VM1 sends LIVE to `127.0.0.1:3000`; everything else to VM2 (`<vm2-private-ip>:3000`) with VM1 as fallback.
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
| LIVE | * | /api/admin/public-ride/* | public_ride.js | safety review: a suspension or a report decision changes the public-ride state held in memory on the live node |
| LIVE | GET | /api/admin/riders/:userId | admin_riders.js | rider page: ride lock state (`rideLock.active` looks at the rider's live room) |
| LIVE | * | /api/admin/riders/:userId/ride-lock/* | admin_riders.js | ride lock view / "End ride lock" (live room of the riding device) |
| LIVE | GET | /api/admin/intel/overview | intel/routes.js | `intel.health()`: the in-memory accumulators fed by ride telemetry live on this node |
| LIVE | * | /api/operator/* | operator_routes.js | operator / club console: ride start (`convoys.createConvoy`), end, roles, live view, SOS view and attendance read or change rooms (`convoys.getRoom`, `convoys.rooms`) |
| LIVE | GET,POST | /api/crews/:crewId/ride-invites | crew_ride_invites.js | invites of a live crew ride: `convoys.getRoom` / `rideFeatureOff` (room state) |
| LIVE | DELETE | /api/crews/:crewId/ride-invites/:inviteId | crew_ride_invites.js | same |
| LIVE | GET | /api/me/ride-invites | crew_ride_invites.js | lists invites with the live state of their rides (`convoys.rooms`) |
| LIVE | * | /api/ride-invites/* | crew_ride_invites.js | accept joins the ride (`convoys.joinByCode`, `getSnapshot`) |

## WEB (VM2 <vm2-private-ip>:3000, VM1 fallback)

| Class | Methods | Path | Source | Why |
|---|---|---|---|---|
| WEB | GET | /api/meta | routes.js | static metadata |
| WEB | GET | /api/web/config | web_shop.js | website config (Google web client id, support address) |
| WEB | GET | /api/web/receipt/:orderId | web_shop.js | the rider's own receipt (database) |
| WEB | POST | /api/web/receipt-email | purchase_email.js | optional receipt address of an order (database, mailer) |
| WEB | GET,PUT | /api/web/marketing-consent | offer_emails.js | offer e-mail consent (database) |
| WEB | GET,PUT | /api/web/email-preferences | lifecycle_emails.js | e-mail categories (database) |
| WEB | POST | /email/unsubscribe | offer_emails.js, lifecycle_emails.js | signed one-click unsubscribe (database) |
| WEB | GET | /api/me/capabilities | access_mode.js | plan capabilities from the access mode (one cached copy per node, re-read every 30 s and on a mirror poke) |
| WEB | GET,PUT | /api/me/push-prefs | push_campaigns.js | "News and updates" switch (database) |
| WEB | POST,DELETE | /api/me/push-tokens | push.js | FCM tokens (database) |
| WEB | GET | /api/me/coupons | admin_riders.js | the rider's own coupons (database) |
| WEB | GET | /api/me/score | leaderboard.js | rider score (database) |
| WEB | GET | /api/me/leaderboard | leaderboard.js | leaderboard position (database) |
| WEB | POST | /api/me/score/rides | leaderboard.js | phone-computed ride scores (database) |
| WEB | DELETE | /api/me/score/phone | leaderboard.js | deletes them (database) |
| WEB | POST | /api/me/feedback | engagement.js | in-app feedback (database) |
| WEB | GET | /api/app/engagement-config | engagement.js | rating prompt config (database) |
| WEB | POST | /api/me/diagnostics | diag_logs.js | diagnostics log upload (database / object storage) |
| WEB | GET | /api/me/diagnostics/requests | diag_logs.js | open log requests (database) |
| WEB | GET,DELETE | /api/me/sessions/* | security_routes.js | sessions list / sign out one (database; the revoke reaches VM1 sockets through the mirror `ss` frames) |
| WEB | GET | /api/me/security | security_routes.js | 2-step state (database) |
| WEB | POST | /api/me/email | security_routes.js | e-mail change link (database, mailer) |
| WEB | * | /api/me/mfa/* | security_routes.js | 2-step verification set-up (database) |
| WEB | GET | /api/me/profile | social_routes.js | own profile card (database) |
| WEB | GET | /api/me/stats | social_routes.js | own ride totals (database) |
| WEB | PATCH | /api/me/username | social_routes.js | database (unique index) |
| WEB | PATCH | /api/me/privacy | social_routes.js | database |
| WEB | * | /api/me/avatar/* | social_routes.js, avatars.js | profile picture: upload, original, crop, delete (database / object storage) |
| WEB | GET | /api/avatars/:avatarId | social_routes.js | profile picture bytes |
| WEB | GET | /api/users/* | social_routes.js | username check, search, public profile (database) |
| WEB | * | /api/friends/* | social_routes.js | friends, requests, suggestions (database; `hub.sendToUser` notices are relayed to VM1 by the mirror) |
| WEB | * | /api/blocks/* | social_routes.js | blocks (database) |
| WEB | GET | /api/join/friend/:code | social_routes.js | friend invite lookup (database) |
| WEB | GET | /api/convoys/:groupId/usernames | social_routes.js | `repo.getConvoyMeta` + users (database only; no room is loaded) |
| WEB | GET,POST | /api/crews | crew_routes.js | crews (database) |
| WEB | POST | /api/crews/invites/:inviteId/accept | crew_routes.js | database; notices relayed by the mirror |
| WEB | POST | /api/crews/invites/:inviteId/decline | crew_routes.js | database |
| WEB | GET,PATCH,DELETE | /api/crews/:crewId | crew_routes.js | database |
| WEB | GET | /api/crews/:crewId/invitable | crew_routes.js | database |
| WEB | POST | /api/crews/:crewId/invites | crew_routes.js | database |
| WEB | DELETE | /api/crews/:crewId/invites/:inviteId | crew_routes.js | database |
| WEB | POST | /api/crews/:crewId/leave | crew_routes.js | database |
| WEB | PATCH,DELETE | /api/crews/:crewId/members/:username | crew_routes.js | database |
| WEB | POST | /api/crews/:crewId/transfer | crew_routes.js | database |
| WEB | * | /api/crews/:crewId/polls/* | crew_routes.js | polls and votes (database) |
| WEB | GET | /api/operators/application | operator_routes.js | the rider's operator application (database) |
| WEB | POST | /api/operators/apply | operator_routes.js | database, mailer |
| WEB | * | /api/clubs/* | operator_routes.js | club membership and broadcasts (database) |
| WEB | * | /api/rides/:slug/* | operator_routes.js | public ride sign-up (database; the join code comes from the stored ride meta) |
| WEB | POST | /api/sms/receipts/:provider/:token | sos_sms.js | SMS delivery receipts: updates the stored send log only |
| WEB | * | /api/intel/* | intel/routes.js | road & safety intelligence: consent, event upload (queued to the database), layers read from stored cells (per-node read cache) |
| WEB | POST | /api/geo/link | routes.js | map link resolver (outbound HTTP, allow-listed hosts) |
| WEB | GET | /api/alltime-stats | admin_analytics.js | aggregates (database) |
| WEB | GET | /metrics | metrics.js | this node's own metrics (loopback / METRICS_ALLOW only; Caddy answers 404 publicly) |
| WEB | GET | /download/ios | app.js | redirect |
| WEB | GET | /security.txt | app.js | static |
| WEB | GET | /.well-known/security.txt | app.js | static |
| WEB | GET | /trip/:tripId | app.js | ride summary page (its data comes from GET /api/trips/:tripId) |
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
| WEB | * | /api/admin/* | routes.js, subscription_routes.js, membership_routes.js, admin_riders.js, email_marketing.js, push_campaigns.js, business/*.js ... | every other admin screen: payments, coupons, offers, pricing, payment gateway, memberships, reviews, feedback, diagnostics, audit, app builds, convoy history, page analytics, riders list / plan / coupon / e-mail, e-mail and push studios, templates, access mode, operators review, intelligence layers, Business analytics and Servers (database only; `/api/admin/business/servers` asks the peer node for its metrics over the VCN) |
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
