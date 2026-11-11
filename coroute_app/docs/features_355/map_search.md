# Map search and pasted map links (3.56)

Owner report: "Search is not working in the map search, and pasting a maps URL should also work."

Every place search in the app goes through one screen, the map picker
(`lib/presentation/map_picker/map_picker_screen.dart`). The trip planner opens it for the start,
the destination and every stop. It calls the gateway (`GeoService`,
`lib/data/services/geo_service.dart`), and the gateway calls Photon or Nominatim through its cache
(`gateway/src/geo.js`). The phone never calls a geocoder directly.

## Why search failed

1. **Shared rate limit.** `GET /api/geo/search` used the same 30-a-minute bucket per rider as
   `/geo/reverse`, `/geo/route`, `/geo/nearby-fuel` and `/geo/essentials`. The picker does a
   reverse lookup every time the map moves, and a ride's reroutes and essentials use the same
   bucket. So a rider who panned the map and typed a few places got HTTP 429.
2. **Errors looked like "no results".** `GeoService.search` caught every error and returned `[]`.
   The screen then said "No matching places found" for a 429, being offline, an expired session
   or a geocoder outage. There was no retry.
3. **Stale answers.** Nothing cancelled an older request. A slow answer for "Hyd" could arrive
   after the answer for "Hyderabad" and replace it.
4. **"Nothing found" was cached for 30 days.** Any empty answer went into `geo_cache` for the
   full `GEO_CACHE_DAYS`. If Photon had a bad moment, that query found nothing for a month.
5. **No fallback when Photon came back empty.** Nominatim was asked only when Photon threw an
   error, not when Photon answered with nothing.
6. **Links did not work.** The old `CoordinateParser` read only `?q=lat,lng`, `@lat,lng` and
   `geo:`. Short links (`maps.app.goo.gl`, `goo.gl/maps`), place names in links, `/dir/` links,
   Apple Maps, OpenStreetMap and Waze links were sent to the place search as text and found
   nothing. For place links it used the map view centre (`@`) instead of the place's own pin
   (`!3d…!4d…`).

## What changed

### Gateway
- `GET /api/geo/search?q=&lat=&lng=[&everywhere=1]`
  - Has its own budget: 90 a minute per rider (`search:` key). Reverse lookups have their own
    60 a minute (`rev:`). Pasted links have 20 a minute (`link:`). The other geo routes keep the
    old 30-a-minute bucket.
  - Searches India first (`countrycodes=in` / Photon bbox, biased to the map centre), then the
    world. Results from outside India are marked `outside: true`. `everywhere=1` skips the India
    pass ("Search everywhere" button).
  - Photon first. Nominatim is asked when Photon fails **or finds nothing**. A home-country
    answer from Nominatim beats Photon's world-only answer.
  - If every provider fails, the answer is **503 `SEARCH_UNAVAILABLE`** (not cached), not an
    empty list.
  - Empty answers are cached for 1 hour only. Answers with results are cached for
    `GEO_CACHE_DAYS`. The cache key prefix is now `q3:`, so empty answers cached under the old
    key are not used again.
  - Each result: `name`, `displayName` (short address: locality, district, state, and the
    country only when abroad), `lat`, `lng`, `distanceM` from the map centre, `outside`.
  - Upstream calls keep the polite queue and the identifying User-Agent with a contact address
    (`CoRoute/<version> (+<site>; <GEO_CONTACT>)`), as the Nominatim policy requires.
- `POST /api/geo/link {text, lat?, lng?}` (new; POST so the link never appears in an access-log
  URL). Implemented in `gateway/src/geo_links.js`.
  - `{ place: {lat, lng, name, source, precise}, expanded }`: the link holds a point. The name
    comes from the link, or from the reverse geocoder when the link has none.
  - `{ query, results, expanded }`: the link holds only a name, so the gateway searches for it.
  - Errors: 400 `LINK_EMPTY` / `LINK_TOO_LONG`, 422 `LINK_UNSUPPORTED` / `LINK_NOT_ALLOWED`,
    502 `LINK_UNREACHABLE` / `LINK_TIMEOUT` / `LINK_TOO_MANY_REDIRECTS`.
  - **Short-link expansion:**
    - Starts only from `maps.app.goo.gl` or `goo.gl/maps/…`.
    - Follows redirects by hand (`redirect: 'manual'`), over HTTPS only, through these hosts
      only: `maps.app.goo.gl`, `goo.gl`, `www.google.com`, `google.com`, `maps.google.com`,
      `www.google.co.in`, `google.co.in`, `maps.google.co.in`.
    - At most 5 redirects and 5 s in total. No cookies, no credentials, and response bodies are
      never read.
    - Stops as soon as the redirect target is a Google Maps URL it can read, so google.com
      itself is never fetched.
    - An EU consent redirect (`consent.google.com/?continue=`) is unwrapped without fetching it.
    - Expanded links are cached in memory for 24 h (500 entries).
    - If expansion fails but the shared text had a place name, the gateway searches for that
      name instead.
  - The link and the text are never logged. A failure logs only its code.

### App
- `lib/domain/geo/map_link_parser.dart` (pure Dart) reads links, coordinates and plus codes on
  the phone. Short links come back as `needsExpansion` and go to `POST /geo/link`.
- Map picker search:
  - Waits 350 ms after the last key (was 600 ms), then searches.
  - Each request has a sequence number, so only the newest answer is shown.
  - Shows a spinner while waiting and searching.
  - On failure it shows the reason with **Retry**: offline, too many searches (429), search
    busy (503), or signed out.
  - When India has nothing it says "No matching places found in India" and offers **Search
    everywhere**.
  - Results show the name, the short address and the distance ("12 km away").
  - Recent places (on the phone only) appear when the box is focused and empty.
  - The search is biased to the map centre, which is the rider's location when the picker
    opens for a new place.
- Pasted text (typed, or the paste button):
  - A link or coordinates with a point shows a **"Pasted location"** row at the top. It shows
    the name from the link, or one looked up with `/geo/reverse`, plus the coordinates. A map
    view centre is labelled "check the pin". Tapping the row moves the pin there and names it.
    Confirming sets the destination or stop.
  - A short link shows "Opening the map link…" until the gateway has read it.
  - A link that only names a place (`?q=Nandi+Hills`) runs a normal search for the name.
- **Share to CoRoute** (Android):
  - In the share sheet, `ShareInActivity` (`text/plain` `SEND`, label "Plan a ride in
    CoRoute") is an invisible trampoline. It hands the text to the app's own task, signed with
    a token that is valid only inside this app process, and finishes at once.
  - `ShareInOpener` (`lib/presentation/trip_planner/share_in_opener.dart`) waits until the rider
    is signed in and past the splash screen. Then it opens the trip planner, and the destination
    picker opens with the shared text in the search box.
  - During a live ride it shows a snackbar instead.
  - Channel `coroute/share_in`: `takeSharedText`, plus `sharedText` when text arrives while the
    app is running.

## Supported input

| Input | Example | Result |
|---|---|---|
| Google place | `https://www.google.com/maps/place/Charminar/@17.36,78.47,17z/data=…!3d17.3615636!4d78.4746552` | pin from `!3d!4d`, name from path |
| Google dropped pin | `…/maps/place/12°58'16.0"N+77°35'38.0"E/@…` | the DMS point |
| Google view | `https://www.google.com/maps/@12.97,77.59,15z` | view centre (not precise) |
| Google query | `https://maps.google.com/?q=12.97,77.59`, `?q=Name`, `?ll=` | point / name search / point |
| Google search | `/maps/search/Name/@…`, `/maps/search/?api=1&query=…` | name search or point |
| Google directions | `/maps/dir/A/B/@…/data=…!1dLNG!2dLAT`, `?api=1&destination=` | the destination |
| Google short links | `https://maps.app.goo.gl/XXXX`, `https://goo.gl/maps/XXXX` | expanded by the gateway |
| Shared text | `Charminar\n<address>\nhttps://maps.app.goo.gl/…` | first line is the name |
| geo: URI | `geo:12.97,77.59`, `geo:12.97,77.59?q=Name`, `geo:0,0?q=12.97,77.59(Label)`, `geo:0,0?q=Name` | point (+label) / name search |
| Apple Maps | `maps.apple.com/?ll=…&q=…`, `?coordinate=…&name=…`, `?address=…` | point / name search |
| OpenStreetMap | `openstreetmap.org/?mlat=…&mlon=…`, `#map=z/lat/lng` | marker / view centre |
| Waze | `waze.com/ul?ll=lat,lng`, `live-map/directions?to=ll.lat,lng`, `?q=` | point / name search |
| Coordinates | `12.97, 77.59`, `12.97 77.59`, `12.97N 77.59E`, `lat: 12.97 lng: 77.59` | point (decimals required) |
| DMS | `12°58'16"N 77°35'38"E` | point |
| Plus code | `7J4VXHFR+2C` (full codes only; short codes need a town, so they go to the search) | point |

Every point is checked: it must be finite and in range, and 0,0 is rejected. Bare integers such
as "Sector 21 22" are not read as coordinates.

## Privacy

- Diagnostics never contain the words typed or a pasted link:
  - `place_search` logs `len`, `kind` (text / numeric / mixed), `count`, `ms` and `scope`.
  - `place_search_failed` logs the HTTP status.
  - `map_link` logs `point` or `query`.
  - `share_in` logs the text length.
- API paths are logged without their query string (`DiagRedact.pathTemplate`).
- The gateway logs only error codes for searches and links.

## Tests

- `test/map_link_parser_356_test.dart`: every format above, plus rejection cases. Run with
  `flutter test`; the logic was also checked with plain Dart.
- `gateway/test/geo_links_356.test.js`: the same formats on the gateway; short-link expansion
  through a fake HTTP layer (allowlist, http refused, loops stopped after 5 redirects, timeout,
  consent unwrap, body dropped, no cookies); the resolver (naming, name search, fallback, no
  logging); search fallbacks (empty Photon → Nominatim, 1 h empty cache, `SEARCH_UNAVAILABLE`,
  `everywhere`); and the HTTP endpoints with separate budgets. Run with
  `cd gateway && node --test test/geo_links_356.test.js`.

## Navigate in Google Maps / Mappls (3.55 owner decision)

One tap hands turn-by-turn navigation to a navigation app; CoRoute keeps running in the
background (ride tracking, intercom, safety; the foreground service is not stopped). Tapping the
ride notification is the way back ("Back to CoRoute").

Where the Navigate button is: the cockpit top bar (next stop, else destination), the "Route and
stops" sheet (every stop and the destination), the meeting / regroup point card and the "rider
stopped" card in the cockpit action stack, the incident banner and sheet (rider in trouble,
nearest hospital), assistance requests and place cards.

Which app (Settings > More > **Navigation app**, kept on the phone):

| Choice | Order tried |
|---|---|
| Automatic (default) | Google Maps (if installed) > Mappls (if installed) > any map app (`geo:`) > Google Maps web link |
| Google Maps | Google Maps turn-by-turn > Google Maps web link in the app > Mappls > `geo:` |
| Mappls | Mappls > Google Maps > `geo:` > web link |
| Other app | `geo:` (the phone asks or uses its default) > web link |

Links (`lib/domain/navigation/nav_handoff.dart`, pure; tests `test/nav_handoff_test.dart`):
- `google.navigation:q=<lat>,<lng>&mode=l` (two-wheeler; `mode=d` for car kinds). Where Google
  Maps has no two-wheeler routing it uses driving.
- `https://www.google.com/maps/dir/?api=1&destination=<lat>,<lng>&travelmode=two-wheeler&dir_action=navigate`.
- Mappls (package `com.mmi.maps`): no documented public custom scheme for third-party
  navigation, so the https link `https://www.mappls.com/direction?places=<lat>,<lng>` is sent to
  the Mappls package when it is installed; if Mappls does not take it the next link is tried.
- `geo:<lat>,<lng>?q=<lat>,<lng>(<label>)`.

Android: `NavHandoffChannel.kt` (`coroute/nav_handoff`) checks which apps are installed and
opens a link in one package. Manifest `<queries>`: packages `com.google.android.apps.maps` and
`com.mmi.maps`, VIEW `https://www.mappls.com` (the `google.navigation`, `geo` and `https`
intents were already declared). Without the bridge (tests, iOS) links go through url_launcher.
