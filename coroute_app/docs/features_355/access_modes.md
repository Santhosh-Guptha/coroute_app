# Access modes: paid, free for everyone, free up to limits (3.56)

Owner decision (Nov 11, 2026): "Make it configurable: payment needed, or free with all features,
controlled in the web admin; don't show plans, features or payments in the app."

The admin chooses the **access mode** in the web admin (**Plans & pricing > Access mode**). The
gateway is the only place that decides (`gateway/src/access_mode.js`, on top of
`entitlements.js`). The app learns only the result for the signed-in rider (capabilities). It never
learns the mode, a plan price or an offer.

## Modes

| Mode | Who hosts group rides | Riders per ride | Group features | Website `/plans` |
| --- | --- | --- | --- | --- |
| **Paid** (default) | Riders with a group plan bought on the website. Community riders host solo rides. | The plan's seats (Small Group 6, Large Group 12) | All, in a group ride | Plans and checkout |
| **Free for everyone** | Every rider | `free.maxRiders` (default 12). A paid plan with more seats keeps them. | All | "CoRoute is free right now". No checkout. The account page stays. |
| **Free up to limits** (hybrid) | Every rider, within the limits. Beyond them, riders with a group plan. | `hybrid.maxRiders` (e.g. 6) without a plan. With a plan: the plan's seats, never fewer than the free limit. | Without a plan: only `hybrid.freeFeatures`. With a plan: all. | Plans and checkout, with a line about the free limits |

In every mode:

* **Safety is never gated.** That covers SOS, crash alerts, emergency texts, medical ID, guardians, the
  missing-rider check, the stretch alert, buddy pairs and roll call. They are not in the list of
  features a mode can leave out.
* **Joining a ride is free.** The only limit is the host's seats (`409 CONVOY_FULL`).
* **Paid plans keep running.** Changing the mode never touches a membership: nothing is refunded,
  cancelled or shortened. A plan's seats still count whenever they are higher than the free limit.
* **Live rides never shrink.** When a host may now have more (free mode, a plan, higher limits), the
  ride takes the new seats and features at once (`CONFIG`). Fewer seats only apply to rides started
  later.
* The server switch `PAYMENTS_ENABLED=false` still means "everything free". It overrides the mode.

### Free up to limits

| Setting | Default | Range |
| --- | --- | --- |
| `hybrid.maxRiders` | 6 | 2 to 1000, capped by `MAX_CONVOY_RIDERS` |
| `hybrid.maxHostedRidesPerMonth` | 8 | 0 to 1000 |
| `hybrid.freeFeatures` | all of the list below | a subset of the list |

The features a free tier can leave out are ids from the feature switch catalog
(`feature_flags.js`): `intercom` (group talk), `rideRoles`, `autoRoles`, `crewRides`, `groupFuel`,
`regroupSuggest`, `publicRide`, `discovery` and `vehicleSwap`. Messages and regroup come with every
group ride.

How a hosted ride is counted:

* A ride counts as **one hosted group ride** when the first other rider joins it. Rides nobody joins
  do not count.
* The count is per host, per India calendar month. It resets at 00:00 IST on the 1st.
* Collection: `hosted_ride_counts`, key `<userId>:<YYYY-MM>`. The rows are erased with the account.
* Once the month's limit is used up, the rider's next ride is a solo ride. The capabilities then carry
  `reason: HOSTED_RIDES_LIMIT`.

Group features left out of a free-tier ride are refused by the server with `403 GROUP_FEATURE_LOCKED`
("This isn't included in this ride."). This applies to:

* socket messages: roles, swaps, public ride, nearby groups;
* group talk (`VOICE_START`);
* crew ride invites (`POST /api/crews/:crewId/ride-invites`).

The app hides those features using the ride's `groupFeatures`. Each ride stores its features on
`meta.groupFeatures`, where `null` means all of them.

### Scheduled change

An admin can schedule one mode change at a date and time in **India time**. For example: "Free for
everyone now, then Paid on 1 Dec 00:00 IST".

* The admin enters `YYYY-MM-DDTHH:MM` in IST. It is stored as epoch ms, so 1 Dec 00:00 IST is stored
  as 30 Nov 18:30 UTC.
* The switch is computed (`effectiveDoc`), so it happens on time on both gateway nodes with no write.
  Each node checks every 15 s and then sends `CAPABILITIES_CHANGED` to its connected apps.
* The next admin save starts from the mode in force.
* The time must be in the future and at most a year ahead. The scheduled mode must differ from the
  current mode.

## Storage, versioning and audit

* One document in `subscription_config` (`k = 'access_mode'`). It holds `mode`, `free`, `hybrid`,
  `schedule`, `version`, `updatedAt`, `updatedBy` and the last 50 changes (`history`). Each change is
  stored with its before and after state and a reason.
* An edit made with a stale `expectedVersion` gets `409 VERSION_CONFLICT`.
* Every save is also an admin audit entry (`access_mode.update`, shown in Plans & pricing > Audit log).
* Each node keeps a cached copy and re-reads it every 30 s. A save pokes the other node at once over the
  mirror (extension `am`; the poke only triggers a re-read). A database outage keeps the last known
  state.

## App capability contract

`GET /api/me/capabilities` (Bearer). The same object is also `capabilities` in `GET /api/membership/my`:

```json
{ "ok": true, "capabilities": {
  "gated": true,
  "canHostGroup": true,
  "maxRiders": 6,
  "groupFeatures": ["intercom", "rideRoles", "crewRides"],
  "hostedRidesLeft": 5,
  "hostedRidesLimit": 8,
  "reason": null,
  "version": 7
} }
```

| Field | Meaning |
| --- | --- |
| `gated` | `false` while nothing is gated (free for everyone, or payments off). The app then shows no plan status at all (`plansEnforced` false). |
| `canHostGroup` | The rider may start a ride others can join |
| `maxRiders` | Riders in a ride the rider hosts, host included. `1` means a solo ride. |
| `groupFeatures` | `"all"`, or the list of feature ids of the rider's own group rides |
| `hostedRidesLeft`, `hostedRidesLimit` | Free up to limits only. Otherwise `null`. |
| `reason` | `GROUP_PLAN_REQUIRED`, `HOSTED_RIDES_LIMIT` or `null` |
| `version` | The access mode version |

The payload never carries a price, an amount, a coupon, an offer, a plan name or the mode. A test checks
every key.

Live update:

* A change sends the socket event **`CAPABILITIES_CHANGED`** `{version}` to every connected app, in a
  ride or not.
* The app re-reads `/membership/my` (`ConvoyService` -> `onPlanChanged`, the same path as
  `SUBSCRIPTION_*`).
* Live rides get a `CONFIG` with the new `capacity` and `groupFeatures`.

What the app shows (pure, `lib/domain/membership/plan_gate_messages.dart`, `ride_capabilities.dart`):

| Situation | Text | Link or button |
| --- | --- | --- |
| Free for everyone | Nothing. The plan chip and the "Your plan" rows are hidden. | none |
| Paid, no group plan | "Hosting a group ride needs a group plan." | none |
| Free up to limits, monthly limit used up | "Hosting more group rides needs a group plan." | none |
| Ride is full | "This ride is full." | none |
| Feature not in this ride | "This isn't included in this ride." | none |

* `MembershipService.canHostGroup` is the one answer for hosting (the home hero "Start one and share
  the code." / "Start a solo ride for free.").
* `ConvoyModel.groupFeatures` / `allowsGroupFeature` hide the features a free-tier ride does not
  include (the talk bar, and `ConvoyService._featureOn`).

## Website

* `GET /api/public/access` returns `{mode, checkout, free?: {maxRiders}, hybrid?: {maxRiders,
  maxHostedRidesPerMonth}, changesAt?, nextMode?}`. It is public and cached for 30 s.
* `/plans` (`public/assets/plans.js`) depends on the mode:
  * **free**: one card, "CoRoute is free right now", with the free rider limit, "Free until …" when a
    change is scheduled, "Get the app", "Your account", and "Already have a plan? It keeps running".
    The steps and the checkout are hidden.
  * **hybrid**: a line above the plans about the free limits.
* `POST /api/membership/order` answers `409 FREE_MODE` in free mode, as a safety net.
* `/account` is unchanged.

## Admin endpoints

| Method and path | What |
| --- | --- |
| `GET /api/admin/access-mode` | The stored and effective settings, the schedule (with an IST label), version, history (last 20), the feature list and the defaults |
| `PUT /api/admin/access-mode` | `{mode?, free?: {maxRiders}, hybrid?: {maxRiders, maxHostedRidesPerMonth, freeFeatures}, schedule?: {mode, atIst} \| null, expectedVersion?, reason?}`. Partial; validated; audited. |

These are MASTER_ADMIN only.

## Files

* Gateway:
  * `src/access_mode.js`
  * the wiring in `src/app.js`
  * `src/convoys.js`: `_hostAccess`, `_currentCapacity`, `rideFeatureOff`, `refreshAllCapacities`,
    `_countFreeHosting`
  * `src/ws.js`: the `GROUP_FEATURE_LOCKED` guard
  * `src/crew_ride_invites.js`
  * `src/membership_routes.js`: `capabilities` and `FREE_MODE`
* Web admin: `public/admin/access.js` (the card in Plans & pricing)
* Website: `public/assets/plans.js`
* App:
  * `lib/domain/membership/ride_capabilities.dart`, `plan_gate_messages.dart`
  * `lib/data/models/membership_model.dart` (`capabilities`), `convoy_model.dart` (`groupFeatures`)
  * `lib/data/services/membership_service.dart` (`canHostGroup`, `hostingLimitMessage`),
    `convoy_service.dart`
* Tests:
  * `gateway/test/access_mode_356.test.js`: each mode, limits, the IST schedule boundary, paid plans
    untouched, the website, the capability payload keys, live refresh
  * `test/access_mode_gate_messages_356_test.dart`
