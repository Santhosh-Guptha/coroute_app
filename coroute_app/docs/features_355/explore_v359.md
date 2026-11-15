# Explore v3.59: admin-configurable, real riders' routes, CoRoute's own look

Owner request (14 Nov 2026): fix alignment / text overflow in the app; make Explore configurable from the admin
console; show real riders' routes when riders complete a ride there ("be the first to guide others"); make the app
look clearly different from the competitor app while keeping every feature.
Owner choices: routes are **opt-in with the username shown**; **new layout + our own style**; managed in the **web
admin and in the in-app admin**.

## 1. Admin configuration (gateway `src/explore.js`)

Stored as one document (`destinations` collection, `type: meta, id: explore_config`).

| Setting | Rules |
|---|---|
| Headline, subtitle | 60 / 120 characters |
| Sections | `featured` (Picked for you), `rider_routes` (Ridden by CoRoute riders), `near_you`, `categories` (type tiles), `suggest`. Each: on/off, title, order. Missing ones come back switched off |
| Categories | the 6 built-in ones can be renamed, hidden and re-ordered; up to 6 custom ones (`[a-z][a-z0-9_]{1,23}`). Hiding a category hides its destinations. A category used by a destination cannot be removed (409 IN_USE). Destinations may use custom categories |
| Featured | up to 12 destination ids, in order |
| Rider routes | on/off, show riders' notes on/off |

APIs: `GET /api/public/explore` (public, ETag, 120 s: config + active destinations of visible categories + live route
counts), `GET|PUT /api/admin/explore/config` (MASTER_ADMIN, audited). The old `GET /api/public/destinations` stays for
older apps.

## 2. Rider routes (opt-in)

* After a ride, the trip report shows **"Guide other riders to (place)"** only when the ride passed within 3 km of an
  Explore destination and route sharing is on. Nothing is sent until the rider ticks *Share this route to guide other
  riders* and taps *Share route*. Optional tip (140 characters).
* The phone drops the first and last 1 km and thins the track (≤ 1,500 points); the gateway validates again
  (consent, reaches the destination, no 50 km gaps, ≤ 2,000 km), drops the first and last 1 km again, simplifies to
  ≤ 300 points (Douglas-Peucker), keeps 5 decimals.
* Stored: username (required; 409 USERNAME_REQUIRED otherwise), distance, riding time, IST calendar day (no time of
  day), tip, bike label (optional). At most 3 routes per rider per destination (oldest replaced); 10 shares per day.
* Shown to signed-in riders only: `GET /api/explore/destinations/:id/routes` (newest 20, no user ids).
* Delete: the rider (`DELETE /api/explore/routes/:id`, Profile > My shared routes), a moderator (hide/show/delete,
  audited), account deletion (repo cascade).
* Feature flag `exploreRoutes` (Community). Privacy page section "Routes you share on Explore".
* "First": the share answer says whether this rider is the first to guide others there.

## 3. App

| Where | What |
|---|---|
| Explore (`explore_screen.dart`) | admin headline/subtitle; search + round "add road" key; live map strip of every place (tap: full map with pins); chips in the admin's order (only categories in use, custom ones included, squared chips); sections in the admin's order: **Picked for you** postcards, **Ridden by CoRoute riders** (or "Be the first to guide others"), **Rides near you** as route tickets (distance on a road stub, no rank numbers), type tiles, suggest card. Offline: saved copy; older gateway: built-in layout |
| Ride detail | "The way riders went": the selected rider route drawn on the map (others faint); **Ridden by CoRoute riders** cards (username, distance, time, day, tip, small route drawing); none yet: "Ride it and be the first to guide others" + Plan this ride |
| Trip report | Share route card (consent, tip, place picker when several were reached) |
| Profile | My shared routes (list, delete) |
| In-app admin | Content > **Explore**: places (show/hide, star = featured), layout (sections order/on, categories order/on, route switches), routes (hide/show/delete). Adding places, photos and custom categories: web admin |
| Web admin | Website & community > **Explore**: destinations (add/edit/photo/order/hide/delete, route counts), layout & categories (incl. custom), featured, rider routes moderation with a map preview |

## 4. CoRoute's own look (different from the competitor, same features)

* **Bottom bar**: rounded top with a soft lift; centre key is a road-shaped **Ride** key (motorcycle icon over a
  lane-marked road) instead of a round "+"; the selected tab shows two amber **lane marks** under its label (no pill,
  no top line).
* **Home**: opens with the **safety panel** (status edge colour, "Ready to ride" / "Check before you ride", check
  rows, solid red **Emergency** key), then "Your next ride" ideas, communities, stats, bike.
* **Explore**: map-first, postcards, route tickets, squared chips, admin-driven sections (above).
* **Shared visual language** (`lib/core/ui/route_visuals.dart`): `RoadStripe` (teal road, amber dashes),
  `RoadSectionHeader` (a short road before every section title), `RouteSparkline` (a ridden route in a small box).

## 5. Alignment and text overflow

`tool/ui_lint/overflow_lint.py` (no Flutter SDK needed) flags Rows where text can push past the screen, fixed-height
boxes around text, and Positioned text. 47 findings were reviewed: 15 fixed (community search placeholder, people
buttons, home hero button, place reviews, membership dashboard titles, force-update button, ride wrap-up label,
device-compatibility admin rows); the remaining 32 are short fixed labels or sit inside horizontally scrolling /
unbounded parents where `Flexible` would crash (HUD chips, map markers, DataTable cells, cockpit counters). All new
v3.59 widgets cap their text (`maxLines` + ellipsis) and were written for 320 dp at text x2.

Real-device check still needed (release prompt): the screens at 320 dp with the largest font and display size.
