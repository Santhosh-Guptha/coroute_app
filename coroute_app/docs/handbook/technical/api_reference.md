# CoRoute API reference

Generated on 11 Nov 2026 by reading the route registrations in `gateway/src/*.js` (Express routers
mounted by `gateway/src/app.js` and `gateway/src/routes.js`) and the socket handlers in
`gateway/src/ws.js` / `convoys.js`. 386 HTTP route registrations were found; all are listed below,
grouped by area.

Conventions

- Base: `https://coroute.devmonks.space` (legacy `https://coroute.duckdns.org` serves the same API).
- **Auth** column: `Public` (no token), `Bearer` (rider JWT in `Authorization: Bearer <token>`),
  `Admin` (Bearer of a `MASTER_ADMIN` account, `requireAdmin`; rider 403, anonymous 401),
  `Signature` (HMAC from the provider), `Token in URL` (one-time or hashed code in the path).
- Every authenticated `/api` call passes the account gate (`UserGate`, cached `USER_GATE_TTL_MS`)
  and the general limiter **240 requests / min** (`apiLimiter`). A token older than
  `TOKEN_REFRESH_AFTER_HOURS` (24 h) gets a fresh one in the `X-CoRoute-Token` response header.
- Every response carries `X-Request-Id` (echoed when the client sent a well-formed one). In a
  two-VM deployment `X-CoRoute-Node: <node>/<role>` tells which node answered.
- Errors: JSON `{ error, code? }`. Common codes: `FEATURE_OFF` (403, admin switch off),
  `GROUP_FEATURE_LOCKED` (403, not in this free-tier ride), `CONVOY_FULL` (409), `SOLO_TRIP_ONLY`
  (409), `SESSION_INVALID`, `GUEST_RETIRED` (410), `RATE_LIMITED` / 429 with `Retry-After`,
  `VERSION_CONFLICT` (409), `PLAY_POLICY` (422).
- Paths below are relative to the host. `/api/...` routes are JSON.

Feature-switch guards (403 `FEATURE_OFF`) are registered in front of: `/api/geo/essentials`,
`/api/geo/poi-cells`, `/api/geo/weather`, `/api/places*`, `/api/road-hazards/near`, plus each
module's own switch (crews, crewRides, friends, operators, marketingStudio, pushNotifications,
diagnosticsUpload, riderScore, leaderboard ...).

---

## 1. REST endpoints

### 1.1 Health, meta and app support

| Method | Path | Auth | Purpose / notes |
|---|---|---|---|
| GET | `/api/health` | Public | Gateway and DB health (`db: UP/DOWN`, `leases`). 503 when the DB is down. |
| GET | `/api/health/live` | Public | Node liveness for the NLB (mirror state, `liveRiders`, `eventLoopLagMs`). `Cache-Control: no-store`. Stays 200 during a DB outage. |
| GET | `/status` | Public | `{service, version, status:'ONLINE'}` |
| GET | `/api/meta` | Public | App version gate: `minAppBuild`, `latestAppBuild`, download links. |
| GET | `/api/features` | Bearer | Feature switch snapshot for the app. |
| GET | `/api/app/engagement-config` | Bearer | Rating / review prompt texts and rules (Play-policy-checked). |
| GET | `/.well-known/assetlinks.json` | Public | Android App Links (identical on both hosts). |
| GET | `/robots.txt`, `/sitemap.xml` | Public | Website SEO. |
| GET | `/download`, `/download/32bit`, `/download/ios` | Public | Redirect to Play, APK or iOS links (`PLAY_STORE_URL`, `APK_URL`, ...). |
| POST | `/api/pv` | Public | Website page-view counter (60/min per IP); no cookies. |

### 1.2 Authentication and account

| Method | Path | Auth | Purpose / notes |
|---|---|---|---|
| POST | `/api/auth/register` | Public | E-mail + password (scrypt). Limit 30 / 15 min per IP. |
| POST | `/api/auth/login` | Public | E-mail or callsign + password. 30 / 15 min per IP and 10 failed / 15 min per account (`loginIdLimiter`). Same 401 text for unknown account and wrong password. Used by the app, `/signin`, `/admin`, `/operator`. |
| POST | `/api/auth/google` | Public | Google ID token (audiences `GOOGLE_CLIENT_IDS` + `GOOGLE_WEB_CLIENT_ID`). |
| POST | `/api/auth/guest` | Public | Retired: **410 `GUEST_RETIRED`**. |
| | | | **3.57 sessions** ([sessions_and_security.md](../../features_355/sessions_and_security.md)): sign-in answers add `sessionId`, `sessionKind`, and for clients that send `X-CoRoute-Session: 2` (app ≥ 10025) `refreshToken` + `accessExpiresAt` (website kinds `X-CoRoute-Client: web / admin / operator` get the refresh token as an httpOnly `__Host-` cookie instead), or `{ mfa: 'verify' \| 'enroll', mfaToken }` for 2-step accounts. Short tokens answer 401 **`TOKEN_EXPIRED`** when they run out (refresh, never a sign-out). Locked accounts: 429 `RATE_LIMITED`. Weak passwords: 422 `WEAK_PASSWORD`. |
| POST | `/api/auth/refresh` | Refresh token (body, or cookie + `X-CoRoute-CSRF: 1`) | Rotates the refresh token; reuse of an old one revokes the session. 204 when no token at all. |
| POST | `/api/auth/logout` | Bearer and/or refresh token | Revokes that session (sockets close 4401 `SIGNED_OUT`, except a live ride's socket until the ride ends); clears the cookie. |
| POST | `/api/auth/logout-all` | Bearer | Revokes every session and pre-3.57 token of the account. |
| POST | `/api/auth/reauth` | Bearer | `{password}` or `{idToken}`: marks the session re-authenticated for `REAUTH_WINDOW_MIN` (403 `REAUTH_FAILED` when wrong). |
| POST | `/api/auth/password/forgot` / `/reset` | Public | Reset link by e-mail (always 202) / `{token, newPassword}` (single use, 30 min; ends every session). |
| POST | `/api/auth/email/confirm` | Public (link token) | Confirms a change of e-mail. |
| POST | `/api/auth/mfa/verify`, `/mfa/enroll/start`, `/mfa/enroll/confirm` | Public (`mfaToken`) | Second sign-in step; enrolment returns ten recovery codes once. |
| GET / DELETE | `/api/me/sessions`, `/api/me/sessions/:sessionId` | Bearer | "Where you're signed in"; sign one out (another rider's: 404). |
| GET | `/api/me/security` | Bearer | 2-step status / eligibility, password set, session count. |
| POST | `/api/me/email` | Bearer + re-auth | Change of e-mail (link to the new address, notice to the old). |
| POST / DELETE | `/api/me/mfa/setup`, `/confirm`, `/recovery-codes`, `/api/me/mfa` | Bearer + re-auth | 2-step for admins and operators. |
| GET | `/api/me` | Bearer | Own profile (also sends `PATCH /me {assistHelp, assistAsk:true}` from the app when off; see SETTINGS_MINIMAL). |
| PATCH | `/api/me` | Bearer | Update profile (name, phone, vehicle, emergency contact, medical info, bike summary, network prefs). |
| POST | `/api/me/password` | Bearer | Change password. |
| DELETE | `/api/me` | Bearer (+ re-auth for 3.57 clients: 403 `REAUTH_REQUIRED`) | **Delete account** at once: erase cascade (memberships, usernames, friends, crews, push tokens, ride invites, diag logs, hosted-ride counts, marketing consent, score ...); shared rides keep "Former rider". |
| GET | `/api/me/capabilities` | Bearer | Access-mode result for this rider: `{gated, canHostGroup, maxRiders, groupFeatures, hostedRidesLeft, hostedRidesLimit, reason, version}`. Never a price, plan name or mode. |
| GET | `/api/me/warnings` | Bearer | Admin warnings for the rider. |
| POST | `/api/me/warnings/:id/ack` | Bearer | Acknowledge a warning. |
| POST | `/api/me/feedback` | Bearer | In-app feedback (`topic`: `bug` / `idea` / `other`, message, reply-by-email). |
| POST | `/api/feedback` | Bearer | Older feedback endpoint (5 / h per network). |
| POST | `/api/diagnostics/submit` | Bearer | Older device diagnostics (5 / 24 h). |
| POST | `/api/me/diagnostics` | Bearer | Upload a gzip diagnostics log bundle (max 5 MB compressed, 5 per day, reason `manual` / `safety_prompt` / `admin_request`). Switch `diagnosticsUpload`. |
| GET | `/api/me/diagnostics/requests` | Bearer | Open admin "send your log" requests (7 days). |
| POST | `/api/me/push-tokens` | Bearer | `{token, platform:'android', appVersion}` → `{ok, tokens, enabled}`. 10 / min per rider. |
| DELETE | `/api/me/push-tokens` | Bearer | `{token}` removes one; empty body removes all → `{ok, removed}`. |
| GET / PUT | `/api/me/push-prefs` | Bearer | `{news, events, safetyTips, community, partnerPerks, safety:true}`; `safety:false` → 400 `SAFETY_ALWAYS_ON`; unknown key → 400 `BAD_PREF`. |

### 1.3 Profile, usernames, friends, blocks

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/me/profile` | Bearer | My profile (picture, username, name, stats, score). |
| GET | `/api/me/stats` | Bearer | Trips, km, hours, longest trip, largest group. |
| PATCH | `/api/me/username` | Bearer | Change username (once per 30 days). |
| PATCH | `/api/me/privacy` | Bearer | Leaderboard visibility and other profile privacy flags. |
| POST / DELETE | `/api/me/avatar` | Bearer | Upload / remove profile picture (switch `profilePhotos`). |
| GET | `/api/avatars/:avatarId` | Bearer | Profile picture bytes. |
| GET | `/api/users/:username/profile` | Bearer | Another rider's public profile (no phone, e-mail, medical, location, plan). |
| GET | `/api/users/search`, `/api/users/username-available` | Bearer | Username search / availability. |
| GET | `/api/convoys/:groupId/usernames` | Bearer | Usernames of riders in my ride. |
| GET | `/api/friends`, `/api/friends/suggestions`, `/api/friends/invite` | Bearer | Friends list, suggestions, personal invite link. |
| POST | `/api/friends/requests` | Bearer | Send a friend request (push `FRIEND_REQUEST`). |
| POST | `/api/friends/requests/:requestId/accept` · `/decline` | Bearer | Answer. |
| DELETE | `/api/friends/requests/:requestId`, `/api/friends/:username` | Bearer | Cancel / unfriend. |
| GET / POST | `/api/blocks` · DELETE `/api/blocks/:username` | Bearer | Silent blocks. |
| GET | `/join/friend/:code` | Public | Friend invite web page. |

### 1.4 Rides (convoys), trips and tracks

| Method | Path | Auth | Purpose / notes |
|---|---|---|---|
| POST | `/api/convoys` | Bearer | Create a ride (seats from capabilities; trip owner = creator). |
| POST | `/api/convoys/join` | Bearer | Join by 6-digit code. Brute-force guard: `JOIN_MAX_FAILURES` (10) per rider and `JOIN_MAX_FAILURES_PER_IP` (30) per `JOIN_WINDOW_MIN` (15 min). 409 `CONVOY_FULL` / `SOLO_TRIP_ONLY`. |
| GET | `/api/convoys/active` | Bearer | My active ride. |
| GET | `/api/convoys/:groupId` | Bearer | Ride meta + riders (members only). |
| POST | `/api/convoys/:groupId/leave` | Bearer | Leave. |
| POST | `/api/convoys/:groupId/status` | Bearer | Trip status (start, pause, end: trip owner). |
| POST | `/api/convoys/:groupId/trip-head` | Bearer | Pick a trip head (settings only). |
| DELETE | `/api/convoys/:groupId/riders/:targetUserId` | Bearer | Remove a rider (trip owner only). |
| GET | `/api/convoys/:groupId/emergency-roster` | Bearer | Phone numbers + roles for the phone's SMS fallback (`ROSTER_PER_MIN` 6/min, valid `ROSTER_VALID_H` 12 h). |
| POST / DELETE | `/api/convoys/:groupId/alerts/:alertId/live-link` | Bearer | Create / revoke a live emergency link (6/min, at most 3 per alert, 30 min). |
| DELETE | `/api/v1/sos/live-links` | Bearer | Revoke my live links. |
| POST | `/api/sos/dispatch-external`, `/api/v1/sos/dispatch-external` | Bearer | Ask the server to text contacts / external dispatch (8 / 10 min). |
| POST | `/api/convoys/:groupId/tracks` | Bearer | Upload a track chunk (60/min per rider, `TRIP_MAX_BYTES`). |
| GET | `/api/convoys/:groupId/tracks`, `/timeline`, `/summary`, `/report`, `/gpx` | Bearer | Replay, timeline, trip report, GPX (only the window the rider was in the ride). |
| POST / GET | `/api/trips` · `/api/trips/:tripId` · `/api/trips/:tripId/report` | Bearer | Personal trip log (max `MAX_TRIPS_PER_USER`). |
| DELETE | `/api/trips/:tripId` | Bearer | Delete a trip. |
| GET / POST / DELETE | `/api/trips/:tripId/feedback` | Bearer | Trip review (rating, text, chips). |
| POST / GET | `/api/trips/:tripId/feedback/photos` · `/photos/:photoId` | Bearer | Up to 3 photos, EXIF stripped, published only with consent and admin approval. |
| GET | `/api/public/live/:token` | Token in URL | Live emergency link data: first name, position, time, expiry. 410 when expired. 60/min per IP. Each view audited (5 min dedupe). |
| GET | `/e/:token` | Token in URL | Live emergency web page (`live.html`, fallback plain page with Call 112). |
| GET | `/join/:code` | Public | Join web page / App Link. |

### 1.5 Safety extras, road and places

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/road-hazards/near` | Bearer | Saved potholes / speed breakers / rough road near a route (switch `roadHistory`). |
| POST | `/api/road-hazards/:hazardId/clear` | Bearer | "Fixed?" vote. |
| POST | `/api/road-risk/brakes` · GET `/api/road-risk/near` | Bearer | Anonymous hard-brake cells; risky-stretch heads-up. |
| GET | `/api/places/reviews`, `/api/places/review-summary` | Bearer | CoRoute rider reviews of a place. |
| POST | `/api/places/reviews` · `/api/places/reviews/:reviewId/photo` | Bearer | Rate a place (+ photo, shown after admin check). |
| GET | `/api/places/reviews/:reviewId/photo/:photoId` | Bearer | Approved photo. |
| GET | `/api/geo/search` | Bearer | Place search (Photon; 90/min). |
| GET | `/api/geo/reverse` | Bearer | Reverse geocode (Nominatim; 60/min). |
| POST | `/api/geo/route` | Bearer | Route (OSRM; 12/min). |
| POST | `/api/geo/link` | Bearer | Parse a pasted maps link or coordinates (20/min). |
| POST | `/api/geo/essentials` | Bearer | Fuel, puncture, food, medical along a route (Overpass). |
| GET | `/api/geo/poi-cells` | Bearer | Map places by cell (cached 7 days; 20/min). |
| GET | `/api/geo/nearby-fuel` | Bearer | Nearest fuel stations. |
| POST | `/api/geo/weather` | Bearer | Weather on route (Open-Meteo; `WEATHER_USER_PER_MIN` 6/min). |

### 1.6 Ride Guardian (pilot, only when `GUARDIAN_ENABLED=true`, prefix `/api/guardian`)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/capabilities` | Bearer | Whether guardian links are available. |
| POST | `/links` · GET `/links/:groupId` · PATCH / DELETE `/links/:grantId` | Bearer | Create / list / pause / revoke grants (tier Basic, Live, Emergency; hashed PIN and tokens). |
| GET / PATCH | `/consent/:groupId` | Bearer | Group consent for guardian links. |
| POST | `/ticket`, `/session` | Public + PIN | Viewer exchanges link + PIN for a session (httpOnly cookie; Origin checked against site origins). |
| GET | `/sessions/:id/snapshot` | Guardian session | Tier-limited view. |
| POST / DELETE | `/sessions/:id/subscription[/:subscriptionId]` | Guardian session | Web push subscription (VAPID). |
| GET | `/watch`, `/watch-sw.js` | Public | Viewer page and service worker (strict CSP). |

### 1.7 Social: crews, polls, crew ride invites

All Bearer; switches `crews`, `crewPolls`, `crewRides`.

| Method | Path | Purpose |
|---|---|---|
| GET / POST | `/api/crews` | My crews / create (crew admin). |
| GET / PATCH / DELETE | `/api/crews/:crewId` | Read / rename / delete (club crews: 409 `CLUB_MANAGED`). |
| GET | `/api/crews/:crewId/invitable` | Friends that can be invited. |
| POST | `/api/crews/:crewId/invites` · DELETE `/invites/:inviteId` | Invite a friend / cancel. |
| POST | `/api/crews/invites/:inviteId/accept` · `/decline` | Answer a crew (or club) invite. |
| PATCH / DELETE | `/api/crews/:crewId/members/:username` | Co-admin / remove. |
| POST | `/api/crews/:crewId/leave`, `/transfer` | Leave / hand over. |
| GET / POST | `/api/crews/:crewId/polls` | Polls (the only crew posts). |
| POST | `/api/crews/:crewId/polls/:pollId/vote` · `/close` · DELETE `/vote`, DELETE poll | Vote / close / unvote / delete. |
| POST | `/api/crews/:crewId/ride-invites` | `{groupId, usernames}`; trip owner only; free-tier ride without `crewRides` → `GROUP_FEATURE_LOCKED`. |
| GET | `/api/crews/:crewId/ride-invites?groupId=` · DELETE `/:inviteId` | List / cancel. |
| GET | `/api/me/ride-invites`, `/api/ride-invites/:inviteId` | My invites. |
| POST | `/api/ride-invites/:inviteId/accept` `{rider?}` · `/decline` | Accept runs the normal join. |

### 1.8 Rider score and leaderboards

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/me/score` | Bearer | Private 0-100 score, level (Learner / Steady / Skilled / Ace Rider), tips. |
| POST | `/api/me/score/rides` | Bearer | Per-ride safety counts (no route or position). |
| DELETE | `/api/me/score/phone` | Bearer | Remove phone-sent score data. |
| GET | `/api/me/leaderboard` | Bearer | Boards with my rank. |
| GET | `/api/public/leaderboard` | Public | Usernames and rounded totals only; opted-out riders left off. |

### 1.9 Plans, membership and payments (website)

The app calls only `/api/membership/my` and `/api/me/capabilities`; buying happens on the website.

| Method | Path | Auth | Purpose / notes |
|---|---|---|---|
| GET | `/api/public/access` | Public | `{mode, checkout, free?, hybrid?, changesAt?, nextMode?}` (cached 30 s). |
| GET | `/api/membership/catalog` | Public/Bearer | Plans (Community, Small Group 2-6, Large Group 7-12), list and offer prices. |
| GET | `/api/membership/quote` | Bearer | Server-computed price (`plan_pricing.computeQuote`), proration, coupon. Coupon brake: 10 unknown codes / 15 min → 429 `COUPON_ATTEMPTS`; 20 lookups/min. |
| POST | `/api/membership/validate-coupon` | Bearer | Coupon check (uniform `COUPON_NOT_FOUND` for missing/private/draft). |
| POST | `/api/membership/order` | Bearer | Razorpay order at the server's amount (30 min TTL). 409 `FREE_MODE` in free mode; 409 `DOWNGRADE_NOT_ALLOWED` for smaller / same plan while a paid plan runs; 400 `ONE_CODE_ONLY`. |
| POST | `/api/membership/verify` | Bearer | Payment signature + amount/currency check; only the order's rider (admins too are refused). |
| POST | `/api/membership/purchase`, `/api/membership/activate-free` | Bearer | ₹0 activations (atomic coupon reservation). |
| POST | `/api/membership/webhook` | Signature | Razorpay webhook (raw body, 1 MB); active only when `RAZORPAY_WEBHOOK_URL=membership`, else 410 `WEBHOOK_URL_INACTIVE`. |
| POST | `/api/subscription/webhook` | Signature | Razorpay webhook, the default active URL (`RAZORPAY_WEBHOOK_URL=subscription`). |
| GET | `/api/membership/my` | Bearer | My membership + `capabilities`. |
| GET | `/api/membership/payments` | Bearer | My payment history. |
| GET | `/api/me/coupons` | Bearer | 3.57 round 3: personal single-use codes given to me (`code, discount, validUntil, state ACTIVE/USED/EXPIRED/..., plans, plansPath`); never another rider's. 30/min. |
| POST | `/api/membership/members/invite` · `/respond` · DELETE `/members/:targetUserId` | Bearer | Plan seat sharing (legacy group membership). |
| GET | `/api/subscription/config`, `/status`, `/history`, `/orders` | Bearer | Legacy subscription views (older apps). |
| POST | `/api/subscription/create-order`, `/verify-payment`, `/validate-coupon` and `/api/verify-payment`, `/api/validate-coupon` | Bearer / Public | Legacy app checkout paths (same settle path and security). |
| POST | `/api/razorpay/callback` | Signature | Razorpay redirect-mode callback (old app orders on `/checkout`). |
| GET | `/api/checkout/order/:orderId` | Signed link | Old-app order page data. |
| GET | `/api/web/config` | Public | Google web client id (when set), support e-mail, payments on/off (60/min per IP). |
| GET | `/api/web/receipt/:orderId` | Bearer | One paid order of this rider (others 404, admins too). |
| POST | `/api/web/receipt-email` | Bearer | Re-send the receipt e-mail. |
| GET / PUT | `/api/web/marketing-consent` | Bearer | `{offersEmail}` opt-in (default off; history kept). |
| GET / POST | `/email/unsubscribe?u=&t=` | HMAC in URL | GET shows a button; POST (or RFC 8058 one-click) unsubscribes and suppresses. |
| GET | `/get?coupon=CODE` | Public | 302 to `/plans?coupon=CODE`. |

### 1.10 Operators and clubs (switch `operators`)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/operators/application` | Bearer | My application. |
| POST | `/api/operators/apply` | Bearer | Apply (type, org name, city, business contact, description without phones/e-mails). |
| GET | `/api/operator/me` | Bearer | Operators I own / co-organise. |
| GET | `/api/operator/:operatorId` | Operator | Overview. |
| GET | `/api/operator/:operatorId/roster` · POST `/roster/invites` · DELETE `/roster/invites/:inviteId` · POST `/roster/link` · DELETE `/roster/:username` | Operator | Roster, invites by username, invite link rotate/off, remove member. |
| POST / DELETE | `/api/operator/:operatorId/co-organisers[/:username]` | Operator owner | Co-organisers (within limit). |
| GET / POST | `/api/operator/:operatorId/rides` · PATCH `/rides/:rideId` | Operator | Schedule / edit rides (IST). |
| POST | `/rides/:rideId/start` · `/end` · `/cancel` · `/publish` · `/roles` | Operator | Start (normal convoy, trip owner = lead), end, cancel, announce, roles. |
| GET / POST | `/rides/:rideId/signups[/:username]` | Operator | Public sign-up approvals. |
| GET | `/api/operator/:operatorId/live` | Operator | All live rides (multi-group feature). |
| GET | `/api/operator/:operatorId/rides/:rideId/sos/:alertId` | Operator + `rosterEmergency` | Emergency contact, rider phone, medical ID, last position **only during an open SOS**; audited `operator.sos_contacts_viewed`. |
| GET | `/rides/:rideId/attendance`, `/reports` | Operator + `attendance` | Attendance and monthly totals. |
| GET | `/api/operator/:operatorId/reports.csv` | Operator + `exportReports` | CSV (no coordinates, phones or e-mails; formula-injection guarded; audited). |
| GET / POST | `/api/operator/:operatorId/broadcasts` | Operator + `broadcast` | Up to 5/day; Play policy guard; no phones/e-mails. |
| GET | `/api/clubs` · POST `/clubs/invites/:inviteId/accept`/`decline` · POST `/clubs/join` · POST `/clubs/:operatorId/leave` · GET `/clubs/:operatorId/broadcasts` | Bearer | Member side. |
| POST / DELETE | `/api/rides/:slug/signup` · GET `/api/rides/:slug/me` | Bearer | Sign up for a public operator ride. |
| GET | `/api/public/rides/:slug`, `/api/public/clubs/:code` | Public | Public ride / club pages data. |
| GET | `/operator/*`, `/rides/:slug`, `/clubs`, `/clubs/join/:code`, `/operators/apply` | Public pages | Console and pages (strict CSP). |
| GET | `/api/admin/operators[/:operatorId]`, `/summary`, `/templates` · PUT `/templates` | Admin | Review list, detail, badge count, per-type defaults. |
| POST / PUT | `/api/admin/operators/:operatorId/approve` · `/reject` · `/suspend` · `/reinstate` · PUT `/limits` | Admin | Decisions (reason required for reject/suspend; audited `operator.*`). |

### 1.11 Public website data

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/public/alltime-stats` (also `/api/alltime-stats`) | Public | All-time totals, rounded down, floors of 10. |
| GET | `/api/public/impact-stats`, `/api/public/usage-stats` (and unprefixed) | Public | Privacy-rounded impact / usage (switch `communityStatsWebsite`). |
| GET | `/api/public/live-now` | Public | Rounded riders on the road now (cached 30 s). |
| GET | `/api/public/community-stats`, `/api/public/community-stories`, `/community-stories` | Public | Approved stories ("Rider #"). |
| GET | `/api/public/review-photos/:feedbackId/:photoId` | Public | Approved review photo. |
| GET | `/api/public/board`, `/api/public/board/images/:imageId` | Public | Offers board posts on `/updates` (website only). |

### 1.12 Admin APIs (all `Admin` = MASTER_ADMIN; every write audited in `subscription_config k='audit'` or `safety_audit`)

| Area | Endpoints |
|---|---|
| Overview and analytics | GET `/api/admin/stats`, `/analytics`, `/analytics/overview`, `/analytics/trends`, `/analytics/riders[/:userId]`, `/analytics/groups[/:groupId]`, `/feature-analytics`, `/fleet`, `/groups`, `/convoys/history`, `/app-builds`; GET `/api/admin/web/config`, `/api/admin/web/revenue` |
| Users | GET `/api/admin/users`, `/users/:userId/details`, `/users/:userId/config`, `/users/:userId/social`; PATCH `/users/:userId/role`, `/status`, `/config`; POST `/users/:userId/reset-password`, `/users/:userId/false-alarms/reset`; DELETE `/users/:userId`, `/users/:userId/avatar`; POST `/api/admin/usernames/backfill` |
| Safety | GET `/api/admin/emergencies`, `/safety`; POST `/api/admin/emergencies/:groupId/:alertId/contact` (10/min); POST `/api/admin/broadcast`; DELETE `/api/admin/convoys/:groupId` (dissolve); `/api/admin/public-ride/log`, `/reports`, PATCH `/reports/:reportId`, POST `/users/:userId/suspension` |
| Feature switches | GET `/api/admin/features`; PUT `/api/admin/features/:id` (reason required to turn off; locked ids refused) |
| Access mode | GET / PUT `/api/admin/access-mode` (`expectedVersion`, `schedule {mode, atIst}`) |
| Plans, coupons, offers, payments | GET/PUT `/api/admin/membership/catalog`; GET `/membership/memberships`, `/membership/payments`, `/membership/analytics`; POST `/membership/payments/:orderId/refund`, `/membership/reconcile`; POST `/admin/subscription/users/:userId/grant` · `/revoke` (Change plan); GET/PUT `/admin/subscription/pricing`, `/admin/pricing-rules` (`minPayableInr`); coupons GET/POST `/admin/coupons`, PATCH/DELETE `/admin/coupons/:code`, POST `/coupons/:code/pause` · `/resume`, GET `/coupons/usage`, `/coupons/plan-options`; offers GET/POST/PATCH/DELETE `/admin/offers[/:id]`; payments GET `/admin/payments`, `/payments/history`, `/payments/analytics`, `/payments/users/:userId`, `/payments/export.csv`, POST `/payments/:orderId/refund`; Razorpay GET/PUT `/admin/payment-gateway`, POST `/payment-gateway/test` (secrets never returned); GET `/admin/audit`; GET `/admin/subscriptions`, `/subscription/overview` |
| Reviews and feedback | GET `/api/admin/reviews`, `/reviews/:feedbackId/photos/:photoId`; PUT `/reviews/:feedbackId`, `/feedback/:feedbackId/review`; GET `/admin/feedback`; GET/PUT `/admin/place-reviews[/:reviewId]`; engagement GET/PUT `/admin/engagement/config`, POST `/config/restore`, GET `/engagement/feedback`, PUT `/feedback/:feedbackId`, GET `/engagement/stats`; GET/PUT `/admin/community-stats/config` |
| Diagnostics | GET `/api/admin/diag-logs[/:id]`, `/:id/lines`, `/:id/download` (views audited); DELETE `/:id`; POST `/admin/diag-logs/request` (push `DIAG_LOG_REQUEST`); GET/PATCH `/admin/diagnostics[/:id]` (older device diagnostics) |
| Notifications | `/api/admin/push`: GET `/`, `/config`, `/campaigns[/:id]`; POST `/check`, `/test`, `/images`, `/audience-count`, `/campaigns`, `/campaigns/:id/cancel`; PUT `/` · `/api/admin/email`: GET `/config`, `/offers/campaigns[/:id]`, `/suppression`; POST `/offers/check`, `/preview`, `/test`, `/audience-count`, `/campaigns`, `/campaigns/:id/cancel`, `/suppression`; DELETE `/suppression/:hash` · `/api/admin/sms`: GET/PUT `/settings`, GET `/log`, POST `/test` · `/api/admin/templates`: GET `/`, PUT `/:id`, POST `/:id/preview`, `/:id/reset`, GET `/:id/history` · GET `/media/push/:file` (public push image) |
| Marketing | `/api/admin/marketing/templates` (GET/POST/PUT/DELETE, `/duplicate`, `/status`), `/images`, `/coupons`; board GET/POST/PATCH/DELETE `/api/admin/board[/:postId]`, `/board/images`, `/board/coupons` |
| Crews | GET `/api/admin/crews[/:crewId]`; DELETE `/admin/crews/:crewId`, `/admin/crews/:crewId/polls/:pollId` |
| Riders (3.57 round 3, web admin) | GET `/api/admin/riders` (search, filters, sort, pages; no phone / medical data), GET `/riders/:userId` (rider page), POST `/riders/:userId/preview`, `/riders/:userId/email/check`, `/riders/:userId/assign-plan` (existing admin grant + optional "Plan assigned" e-mail), `/riders/:userId/coupon` (single-use code bound to the rider; consent rule for the e-mail), `/riders/:userId/email` (1:1, transactional vs marketing); GET `/api/admin/search?q=` (riders, orders, coupons); GET `/api/admin/email-wizard/templates`. Reads 120/min, writes 30/min per admin. See docs/features_355/web_riders_admin.md |
| E-mail studio | `/api/admin/email/studio/*` (templates, check, preview, audience-count, test, campaigns, rules, unique-codes, images); account notices may go to up to 50 named riders (`audience.kind = usernames`). See docs/features_355/email_marketing.md |
| Operators | see 1.10 |
| Web console pages | GET `/admin`, `/admin/:file` (strict CSP, noindex) |

### 1.13 Provider callbacks

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/sms/receipts/:provider/:token` | `SMS_WEBHOOK_TOKEN` in path | SMS delivery reports (MSG91 / Twilio). |
| POST | `/api/subscription/webhook`, `/api/membership/webhook` | Razorpay HMAC | See 1.9. |

---

## 2. Rate limits summary

| Limiter | Window | Limit | Key |
|---|---|---|---|
| Authenticated API (`apiLimiter`) | 1 min | 240 | IP |
| Auth (`authLimiter`) | 15 min | 30 | IP |
| Failed sign-in per account (`loginIdLimiter`) | 15 min | 10 failures | account |
| Join by code | 15 min | 10 failures / rider, 30 / IP | rider, IP |
| Emergency roster | 1 min | 6 | rider |
| Live link create | 1 min | 6 | rider |
| External dispatch | 10 min | 8 | rider |
| Public live link / `/e/` / stories | 1 min | 60 | IP |
| Track uploads | 1 min | 60 | rider |
| Geo search / reverse / link / route / poi / weather | 1 min | 90 / 60 / 20 / 12 / 20 / 6 | rider |
| Website feedback | 1 h | 5 | IP |
| Diagnostics upload | 24 h | 5 | rider |
| Push tokens | 1 min | 10 | rider |
| Admin emergency contact | 1 min | 10 | admin |
| Web admin riders: reads / writes / search | 1 min | 120 / 30 / 120 | admin |
| `/api/me/coupons` | 1 min | 30 | rider |
| Socket actions | 1 s | `WS_ACTIONS_PER_SEC` (10) | socket |
| Socket alarms (`WAIT`, `SOS`, `CHECK_IN`, `REPORT_DOWN`) | 10 s | `WS_ALARMS_PER_10S` (3) per type | socket |

---

## 3. WebSocket protocol

Connection, HELLO features and binary frames: [architecture.md §3](architecture.md#3-realtime-protocol-websocket).
Messages are JSON `{type, ...}`. Types carrying a `clientId` (phone outbox) are applied once and
answered with `ACK`: `CHAT, WAIT, STATUS, STOP_VISITED, SOS_RESPOND, CHECK_IN, REPORT_DOWN,
ASSIST_ANSWER, NET_REPORT_FALSE, WAVE, ROLE_SET, REGROUP_SET, REGROUP_CLEAR, ROLE_SWAP, ROLE_AUTO,
SWAP_REQUEST, SWAP_ANSWER, BUDDY_ASSIGN, BUDDY_PING, PILLION_SEAT, PILLION_UNSEAT`.

### 3.1 Client to server

| Group | Types |
|---|---|
| Session | `PING`, `BYE` (`APP_CLOSED` / `SIGN_OUT` / `LEFT`), `JOIN`, `LEAVE`, `ADMIN_SUBSCRIBE` (admins: fleet view) |
| Position | `TELEMETRY` (or binary `0x10` with `bin1`), `TRACK`, `TIMELINE_SINCE` |
| Safety | `SOS`, `SOS_RESOLVE`, `SOS_RESPOND`, `CHECK_IN`, `REPORT_DOWN`, `WAIT`, `LAST_GASP_BEACON` (low-battery last position), `SIGNAL_AHEAD`, `ASSIST_ANSWER`, `NET_REPORT_FALSE` |
| Group | `STATUS`, `CHAT`, `CHAT_REPORT`, `CONFIG` (group settings: trip owner / trip head), `ROUTE_SET`, `TRIP_STATUS`, `REGROUP_SET`, `REGROUP_CLEAR`, `MIC_STATE` |
| Stops | `STOP_ADD`, `STOP_SUGGEST`, `STOP_ACCEPT`, `STOP_DECLINE`, `STOP_REMOVE`, `STOP_SKIP`, `STOP_REORDER`, `STOP_VISITED` |
| Roles and bikes | `ROLE_SET`, `ROLE_SWAP`, `ROLE_AUTO`, `SWAP_REQUEST`, `SWAP_ANSWER`, `RIDER_VEHICLE`, `CORIDER` (legacy pillion), `PILLION_SEAT`, `PILLION_UNSEAT`, `BUDDY_ASSIGN`, `BUDDY_PING` |
| Road | `ROAD_HAZARD` (potholes etc. from the front phone), `ROAD_WARN`, `ROAD_WARN_VOTE` |
| Discovery / public ride | `WAVE`, `PR_PREFS`, `PR_SAY`, `PR_REPLY`, `PR_CONTACT`, `PR_SHARE_CONTACT`, `PR_SHARE_LOC`, `PR_BLOCK`, `PR_REPORT`, `PR_CLOSE` |
| Voice (binary) | `0x01` START, `0x02` FRAME, `0x03` END |

### 3.2 Server to client

| Group | Types |
|---|---|
| Session | `HELLO`, `PONG`, `ACK`, `ERROR`, `RECONNECT` (`shutdown`, server move), `FEATURE_FLAGS`, `CAPABILITIES_CHANGED` |
| Room state | `SNAPSHOT`, `JOINED`, `LEFT`, `RIDER_UPDATE`, `STALE_UPDATE`, `MESSAGE`, `STATUS`, `ROUTE_CHANGED`, `TRIP_STARTED`, `TRIP_ENDED`, `TIMELINE_BATCH`, `TRACK_ACK`, `BROADCAST`, `FLEET` (admins) |
| Safety (lane 0) | `ALERT` (SOS / crash / member report), `ALERT_RESOLVED`, `SOS`, `SOS_RESPONSE`, `CHECK_IN`, `FOLLOW_UP`, `NO_REPLY`, `POSSIBLE_INCIDENT`, `OFFLINE`, `LOW_BATTERY`, `BATTERY_SHUTDOWN`, `RIDER_BATTERY_SHUTDOWN`, `SWEEPER_DISTRESS`, `SWEEPER_DISTRESS_RESOLVED`, `BEHIND_SWEEPER`, `SEPARATED`, `CONVOY_SPLIT`, `CONVOY_SPLIT_RESOLVED`, `ARRIVED` |
| Safety network (`net1`) | `ASSIST_REQUEST` (point + distance only), `ASSIST_UPDATE`, `ASSIST_CLOSED`, `EMERGENCY_NETWORK`, `EMERGENCY_STATUS`, `EMERGENCY_UPDATE` |
| Ride advisories | `OVERSPEED`, `OFF_ROUTE`, `STOPPED`, `MOVING`, `STOP_ADDED`, `STOP_SUGGESTED`, `STOP_PASSED`, `STOP_SKIPPED`, `REGROUP_INITIATED`, `REGROUP_COMPLETED`, `HAZARD`, `HAZARD_CLEAR`, `ROAD_HAZARD`, `ROAD_HAZARD_ACK`, `ROAD_WARNING`, `ROAD_WARNING_CLEAR`, `ROAD_WARN_SENT`, `ROAD_WARN_VOTE_OK`, `SAME_DIRECTION`, `OPPOSITE_DIRECTION`, `WAVED`, `DISCOVERY` |
| Roles and bikes | `ROLE_CHANGED`, `AUTO_ROLES`, `SWAP_ASK`, `SWAP_RESULT`, `VEHICLE_SWAP`, `CORIDE`, `PILLION_SEATED`, `PILLION_UNSEATED`, `BUDDY_PING` |
| Voice | binary START/FRAME/END, `VOICE_BUSY`, `MIC_STATUS` |
| Chat | `CHAT_REPORT_OK` |
| Public ride (`pubride1`) | `PUBLIC_RIDES`, `PR_REQUEST`, `PR_SENT`, `PR_UPDATE`, `PR_CHANNEL`, `PR_MESSAGE`, `PR_LOCATION`, `PR_CONTACT_SHARED`, and `*_OK` acknowledgements |
| Personal (rider's own sockets) | `FRIEND_REQUEST`, `FRIEND_ACCEPTED`, `CREW_INVITE`, `CREW_UPDATED`, `CREW_REMOVED`, `CREW_DELETED`, `POLL_CREATED`, `POLL_UPDATED`, `RIDE_INVITE`, `RIDE_INVITE_UPDATE`, `CLUB_BROADCAST`, `OPERATOR_STATUS`, `OPERATOR_SIGNUP`, `ADMIN_WARNING`, `DIAG_LOG_REQUEST`, `NEWS`, `SUBSCRIPTION_ACTIVATED`, `SUBSCRIPTION_SCHEDULED`, `SUBSCRIPTION_EXPIRING`, `SUBSCRIPTION_EXPIRED`, `SUBSCRIPTION_REVOKED` (neutral plan notices; never a price) |

Personal pushes and socket messages never carry another rider's userId, phone, e-mail, medical info
or a join code.

### 3.3 Close codes

| Code | Meaning | App behaviour |
|---|---|---|
| 4401 | Account gone, signed out, session invalid | sign out |
| 4403 | Account on hold or blocked | do not retry |
| 1011 | Account check failed (DB) | retry |
| 503 at upgrade (`SERVER_BUSY`) | `LIVE_RIDER_CAP` reached for a new live rider | retry later; riders already riding are never refused |

## Round 4 security endpoints (12 Nov 2026)

Details: `docs/features_355/sessions_and_security.md` §9-§12.

| Method & path | Auth | Purpose |
|---|---|---|
| `POST /api/auth/ride-lock/code` | lock token | E-mails the 6-digit ride sign-in code after a `423 RIDE_ACTIVE_ELSEWHERE` |
| `POST /api/auth/ride-lock/verify` | lock token + code | Signs the new device in; hands the ride over; revokes the riding session |
| `POST /api/auth/email/verify` | link token | Confirms a sign-up (single use, 24 h) |
| `POST /api/auth/register/resend` | public | New sign-up link (always 202, rate limited) |
| `POST /api/auth/mfa/email-code` | 2-step token | E-mailed 2-step code (operators; never MASTER_ADMIN) |
| `POST /api/auth/delete/confirm` | link token | Account deletion confirmed from the e-mail (builds < 10025) |
| `POST /api/auth/mfa/step-up` | signed in | 2-step step-up of the session (app admin tools on `403 MFA_REQUIRED`) |
| `POST /api/auth/mfa/step-up/email-code` | signed in | E-mailed code for the step-up (operators) |
| `POST /api/me/mfa/email` | signed in + re-auth | Turn e-mailed 2-step codes on / off (not for admins) |
| `GET /api/admin/riders/:userId/ride-lock` | admin | "On a ride (device)" |
| `POST /api/admin/riders/:userId/ride-lock/end` | admin | End ride lock (reason required, audited) |

Changed: `POST /api/auth/register` answers `202 { pending, message }` (builds < 10025: `400 EMAIL_VERIFICATION_SENT` unless
`REGISTER_VERIFY_LEGACY=allow`); every sign-in may answer `423 RIDE_ACTIVE_ELSEWHERE { error, device, lockToken }`;
`POST /convoys` and `/convoys/join` may answer `409 RIDE_ACTIVE_ELSEWHERE`; `DELETE /api/me` from builds < 10025 without the
password answers `202 DELETE_CONFIRM_SENT`; `/ws` accepts `{ type: "AUTH", token }` as the first message.
