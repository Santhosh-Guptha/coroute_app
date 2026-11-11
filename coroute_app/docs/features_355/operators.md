# Operator and club console (3.56)

Tour operators, riding clubs, rental fleets and corporate fleets can run many rides for many riders from a web
console. A rider applies on the website. A master admin approves the application in the web admin and sets the
limits and features. The approved operator then runs a roster, rides, a live map, attendance and broadcasts from
`/operator`. It is the "Operators/clubs" item of the Trilyt addendum
([COMPETITOR_ANALYSIS_2026-11.md](../COMPETITOR_ANALYSIS_2026-11.md)), brought forward from B3 of
[NEXT_RELEASE_PLAN_v3.56.md](../NEXT_RELEASE_PLAN_v3.56.md).

Feature switch: **`operators`** (Platform group, on by default). When it is off, applications, the console, the
club pages and public sign-ups answer `403 FEATURE_OFF`, and the three website pages return 404. Admin review
keeps working, and live rides are never affected.

## Flows

1. **Apply** (`/operators/apply`, signed in with the CoRoute account). The rider gives:
   - the type: Tour operator, Riding club, Rental fleet or Corporate fleet;
   - the organisation name and city;
   - a business e-mail and phone (private: only the applicant and master admins see them);
   - an optional website or social link;
   - the expected number of riders;
   - a short description, which must not contain phone numbers or e-mail addresses.

   The status is then **PENDING**. Each rider can have one application. A rejected application can be sent again
   and keeps its id. Admins are told in two ways: a count badge on "Operators" in the web admin (refreshed every
   60 s), and an e-mail to `OPERATOR_REVIEW_EMAIL` (falling back to `SUPPORT_EMAIL`) when SMTP is configured.
2. **Admin review** (web admin > **Operators**, MASTER_ADMIN only).
   - The list can be filtered by status (Waiting, Approved, Suspended, Rejected, Expired) and by type, and searched.
   - The detail page shows the private contact, the history and the usage.
   - **Approve** with limits, features and a validity in days. The defaults come from the template for that
     operator type, and the admin can edit the templates.
   - **Reject** needs a reason, which the applicant sees.
   - **Suspend** needs a reason. **Reinstate** reopens the console.
   - **Save limits** changes an approved operator later.
   - The owner gets an e-mail about each decision when SMTP is configured.
   - Every action goes into the admin audit log (`operator.*`).
3. **Approval creates a club crew.** The operator's roster *is* a crew document carrying
   `club: {operatorId, type, maxMembers}`, with the owner as crew ADMIN. Riders therefore see a club invite in the
   app's existing crew invite list (People hub > Requests) without any app change, and they leave it like any
   crew. In the app, the club crew cannot be renamed, deleted or handed over, and the owner cannot leave it
   (`409 CLUB_MANAGED`). Members can always leave.
4. **Console** (`/operator`). Owners and co-organisers sign in with their CoRoute account. A website session in the
   same tab is reused. Sections: Overview, Roster, Rides, Live map, Attendance & reports, Broadcasts.
   - **Roster.**
     - The operator invites riders by username (no friendship needed; the rider still has to accept). The invite
       arrives as a socket `CREW_INVITE` plus a push of type `CREW_INVITE` with `data.kind = OPERATOR_INVITE`, so
       the app opens its crew invites. `GET /api/clubs` lists the same invites with `requestType: 'OPERATOR_INVITE'`.
     - An invite link (`/clubs/join/<code>`) can be rotated or turned off.
     - The operator can remove members and make or unmake co-organisers (owner only, within the limit).
     - Riders accept in the app or on `/clubs`.
   - **Rides.**
     - Schedule a ride with a name, start time (India time), meeting point, destination, notes, number of riders
       (up to the riders-per-ride limit), a lead and a sweeper. The lead and sweeper must be on the roster.
     - Optional: a public sign-up page, with or without approval of each sign-up.
     - **Start** creates a normal CoRoute convoy. Its trip owner is the lead, who sees it on their phone. Its seats
       come from the operator limits, not anyone's plan. The assigned sweeper gets the SWEEPER role when they join.
     - **Invite roster** sends crew ride invites (`ride_invites`, crewId = the club crew) while seats last. Riders
       accept in the app's existing ride-invite screen.
     - **Announce** sends a scheduled ride to the roster as a "Community update".
     - Other actions: **Roles** (LEAD / SWEEPER / PACK while the ride is live), **End**, **Cancel** (a cancelled
       ride stops counting against the month), **Edit**.
   - **Live map.**
     - Every live ride is on one map. This needs the multi-group feature; without it the map shows one ride at a time.
     - Markers show the role (L, S), whether the rider is stale, and SOS markers, next to a rider list per ride.
     - A red SOS banner appears on top, and an SOS badge shows in the navigation.
     - **Emergency contact**: only during an open SOS in that ride, and only with the `rosterEmergency` feature.
       It shows the contact name and phone, the rider's phone, the medical ID and the last position. Every view is
       audited (`operator.sos_contacts_viewed`).
   - **Attendance & reports.**
     - Per ride: who joined, who left and when, who finished (arrived, or still in the ride at the end), distance
       (from the stored tracks) and incidents (type, time and outcome, never a location).
     - Monthly totals.
     - **CSV export** needs the `exportReports` feature and is audited. It contains no coordinates, phone numbers
       or e-mail addresses, and is guarded against CSV formula injection.
   - **Broadcasts.**
     - A title and message go to every roster member: a socket `CLUB_BROADCAST` plus a push of type `NEWS` with
       `data.kind = community_update` and `target = crews`.
     - The **Play policy guard** applies (`policy_terms.forbiddenTermIn`: no prices, offers or buying words).
     - Phone numbers and e-mail addresses are refused.
     - Up to 5 broadcasts a day.
5. **Members** (`/clubs`):
   - club invites (Join / Decline);
   - clubs I am in, with upcoming rides (and their sign-up link) and the latest broadcasts;
   - Leave;
   - the invite link (`?code=`) to join.
6. **Public sign-up page** (`/rides/<slug>`, indexable):
   - shows the operator, time, meeting point, destination, notes and seats left;
   - signed-in riders sign up, or ask to join when approval is on;
   - the operator approves or declines in the console;
   - approved riders see the 6-digit join code (and `/join/<code>`) on the page once the ride is live; the normal
     join rules and the ride's seats apply.

## Limits (set per operator; defaults per type)

| Limit | Bounds | Tour operator | Riding club | Rental fleet | Corporate fleet |
|---|---|---|---|---|---|
| Roster size (`maxMembers`, invites waiting count) | 1-1000 | 200 | 150 | 100 | 300 |
| Live rides at once (`maxConcurrentRides`) | 1-20 | 3 | 2 | 5 | 5 |
| Rides per month (`maxRidesPerMonth`, by start month, India time) | 1-500 | 30 | 12 | 60 | 40 |
| Riders per ride (`maxRidersPerRide`, lead included) | 2 to MAX_CONVOY_RIDERS | 30 | 40 | 12 | 25 |
| Co-organisers (`coOrganisers`) | 0-10 | 3 | 3 | 2 | 5 |
| Validity (days) | 1-1095 | 365 | 365 | 365 | 365 |

Features are checkboxes, all on by default except for a few defaults per type:

| Feature | Off by default for |
|---|---|
| `multiGroupDashboard`: multi-group live dashboard | none |
| `rosterEmergency`: roster & emergency contacts during an SOS | none |
| `attendance` | none |
| `rideCalendar`: ride calendar & public sign-ups | Rental fleet, Corporate fleet |
| `broadcast` | none |
| `exportReports`: CSV export | Riding club |

What each limit refuses:

| Situation | Answer |
|---|---|
| Roster full (members + waiting invites), on an invite or link join | `409 ROSTER_FULL` |
| A third ride in a 2-a-month plan | `409 RIDES_PER_MONTH_LIMIT` |
| A ride with more riders than the per-ride limit | `422 RIDERS_PER_RIDE_LIMIT` |
| A full live ride | the convoy's own capacity: `409 CONVOY_FULL` on join, `RIDE_FULL` for invites and sign-ups |
| Starting a ride beyond the concurrent limit | `409 CONCURRENT_RIDES_LIMIT` |
| Too many co-organisers | `409 CO_ORGANISER_LIMIT` |
| A feature not in the plan | `403 NOT_IN_PLAN` |
| Suspended operator | every console call answers `403 OPERATOR_SUSPENDED {reason}` |
| Expired operator | reads work; writes answer `403 OPERATOR_EXPIRED` |

Live rides keep running through a suspension or an expiry, because safety comes first.

## Entitlements hook

- Operator rides skip the personal plan and access-mode check but follow the operator limits.
  `convoys.createConvoy(user, p, { operator: { operatorId, rideId, capacity } })` (server only) stores
  `capacityPlan: 'operator'`, `operatorId`, `operatorRideId` and `groupFeatures: null` (every group feature).
- `_currentCapacity` returns the stored seats for an operator ride and never raises them from the lead's plan.
- `operators.operatorCapacity(repo, groupId)` gives the seats of an operator ride, or null for a normal ride. It
  is re-exported as `entitlements.operatorCapacity` for the access / entitlements code.

## Privacy

- Operators see usernames, first names, roles, join times and, during their own live rides, positions, speed and
  battery.
- They never see a member's phone, e-mail or medical ID, except the emergency contact view during an open SOS
  (audited, feature-gated).
- Roster, sign-up, live and report responses are tested to contain no phone, e-mail or contact fields.
- Reports and CSV contain no coordinates.
- Members can leave at any time, on `/clubs` or by leaving the crew in the app.
- Account erase removes the rider's operator (its rides, broadcasts and club crew), their co-organiser seats and
  their sign-ups.

## Endpoints (all under `/api`)

| Who | Endpoints |
|---|---|
| Public | `GET /public/rides/:slug`, `GET /public/clubs/:code` |
| Applicant | `GET /operators/application`, `POST /operators/apply` |
| Admin (MASTER_ADMIN) | `GET /admin/operators[?status&type&q]`, `GET /admin/operators/summary`, `GET /admin/operators/:id`, `POST /admin/operators/:id/approve` `{limits, features, validityDays\|validUntil}`, `POST /admin/operators/:id/reject` `{reason}`, `POST /admin/operators/:id/suspend` `{reason}`, `POST /admin/operators/:id/reinstate`, `PUT /admin/operators/:id/limits`, `GET/PUT /admin/operators/templates` |
| Console (owner / co-organiser) | `GET /operator/me`, `GET /operator/:id`, `GET /operator/:id/roster`, `POST /operator/:id/roster/invites` `{usernames}`, `DELETE /operator/:id/roster/invites/:inviteId`, `POST /operator/:id/roster/link` `{action: rotate\|disable\|enable}`, `DELETE /operator/:id/roster/:username`, `POST /operator/:id/co-organisers` `{username}` (owner), `DELETE /operator/:id/co-organisers/:username` (owner), `GET/POST /operator/:id/rides`, `PATCH /operator/:id/rides/:rideId`, `POST /operator/:id/rides/:rideId/{start\|publish\|end\|cancel\|roles}`, `GET /operator/:id/rides/:rideId/signups`, `POST /operator/:id/rides/:rideId/signups/:username` `{approve}`, `GET /operator/:id/live[?rideId]`, `GET /operator/:id/rides/:rideId/sos/:alertId`, `GET /operator/:id/rides/:rideId/attendance`, `GET /operator/:id/reports?month=YYYY-MM`, `GET /operator/:id/reports.csv?month=`, `GET/POST /operator/:id/broadcasts` |
| Members | `GET /clubs`, `POST /clubs/invites/:inviteId/{accept\|decline}`, `POST /clubs/join` `{code}`, `POST /clubs/:operatorId/leave`, `GET /clubs/:operatorId/broadcasts` |
| Sign-up | `POST /rides/:slug/signup`, `DELETE /rides/:slug/signup`, `GET /rides/:slug/me` (join code once approved and live) |

Audit actions:

- `operator.applied`, `operator.approve`, `operator.reject`, `operator.suspend`, `operator.reinstate`,
  `operator.limits`, `operator.templates`;
- `operator.roster_invite`, `operator.roster_remove`, `operator.invite_link`;
- `operator.co_organiser_add`, `operator.co_organiser_remove`;
- `operator.ride_create`, `operator.ride_update`, `operator.ride_cancel`, `operator.ride_start`,
  `operator.ride_announce`, `operator.ride_publish`, `operator.ride_end`, `operator.ride_role`;
- `operator.signup_decision`, `operator.sos_contacts_viewed`, `operator.report_export`, `operator.broadcast`.

## Files

| File | What |
|---|---|
| `gateway/src/operators.js` | Storage (`operators`, `operator_rides`, `operator_broadcasts`, `operators_config`), validation, templates, decisions, club crew, roster, rides, sign-ups, `operatorCapacity`, erase |
| `gateway/src/operator_routes.js` | API, pages (`/operators/apply`, `/clubs`, `/clubs/join/:code`, `/rides/:slug`, `/operator` with its own strict CSP and OpenStreetMap tiles only), pushes, audit, sweeper-on-join, erase cascade |
| `gateway/public/operator/` | Console: `index.html`, `operator.js`, `map.js` (a small slippy map, no third-party script), `operator.css` (on top of `/admin/admin.css`) |
| `gateway/public/admin/operators.js` | Web admin section (list, detail, approve / reject / suspend / reinstate, limits, templates, nav badge) |
| `gateway/public/operators_apply.html`, `clubs.html`, `ride_public.html` + `assets/operators*.js`, `clubs.js`, `ride_public.js`, `operators.css` | Website pages (strict CSP, sessionStorage token as on `/account`) |
| `gateway/test/operators_356.test.js` | Gateway tests (16) |
| `tool/operators_smoke.js` | Playwright smoke and screenshots (57: light / dark, desktop / tablet) |

Small additive edits in shared files:

- `app.js`: one `attachOperators(...)` call after the web admin pages.
- `pages.js`: three entries in `SPECIAL_PAGES`.
- `feature_flags.js`: the `operators` switch.
- `convoys.js`: the `createConvoy` `opts.operator` option, and the guard at the top of `_currentCapacity`.
- `entitlements.js`: the `operatorCapacity` re-export.
- `crews.js`: the club roster cap (`capOf`) and no friendship re-check when accepting a club invite; `setRole` and
  `syncCount` are exported.
- `crew_routes.js`: `club` in the crew view, and the `CLUB_MANAGED` guards.
- `public/assets/shop.js`: `safeNext` allows `/operators/apply`, `/clubs` and `/rides/<slug>`.
- Web admin `index.html`: the nav link and script tag.
- `admin.css`: three small classes.

## App follow-up (optional)

No app change is required: club invites appear as crew invites, ride invites use the existing screen, and
broadcasts use the NEWS notice. If wanted, the app can label a club in the crew list and in Requests from
`crew.club` (`GET /crews/:id`) or `requestType: 'OPERATOR_INVITE'` (`GET /clubs`), and hide Rename and Delete for
club crews.

## Not in this release

The B3 plan also lists these, which were left out on purpose:

- bike or fleet garage assignment;
- GST invoicing and billing per bike;
- fuel-stop plans;
- an explicit consent screen at join ("This ride is run by ..."). Joining a club already says this on `/clubs`,
  and the public page and the club crew description name the operator.
