# Website device compatibility (v3.58, ships with build 3.55.0+10030)

Owner request (14 Nov 2026): "resolve all website related issues, device compatibility should work in every device".

## Support targets

| Tier | Browsers | Promise |
|---|---|---|
| Full | Chrome / Edge / Samsung Internet / Android WebView from the last 3 years; Safari and iOS 15.4+; Firefox 115+ (ESR) | Everything, including the 3D hero and the scroll story |
| Works | iOS / Safari 12.2-15.3 (iPhone 5s/6 and up), Chrome 70-89, Samsung Internet 10-14, Firefox 68-114 | Every page readable and usable: navigation, downloads, sign-in, plans, account, legal pages. Simpler visuals (still story frames instead of the pinned stage; fallback spacing) |
| No JavaScript | any | Static pages fully readable; pages that need JavaScript show a notice |

Screens: 280 px (Galaxy Fold folded) to 1920 px+, portrait and landscape, system text up to 200 %.

## How it was checked

1. **Automated layout audit** (Playwright/Chromium, 27 pages x 10 viewports: 280, 320, 360, 390 iPhone, 412 Pixel,
   740 landscape, 768 iPad, 1024, 1280, 1920; light and dark): horizontal scrolling, elements past the screen edge,
   console/page errors, failed requests, tap targets, tiny text, images without alt.
2. **Accessibility modes** at 360 px: system text 150 % and 200 %, JavaScript off, reduced motion; iOS input zoom
   (inputs under 16 px).
3. **Static compatibility scan**: every CSS feature against the "Works" tier (doiuse / caniuse) and every script
   against ES2019 syntax and API support (eslint-plugin-compat).
Firefox and WebKit engines are not installed in the build sandbox: real-device checks are in the release prompt.

## What was wrong, and the fix

| # | Problem | Who was affected | Fix |
|---|---|---|---|
| 1 | Page scrolled sideways: header row too wide | Galaxy Fold (280 px); any phone with large system text (150 %+) | `site.js` `fitHeader()`: hides the header theme button, then "Get the app" (both also in the menu/footer) when the row does not fit; re-checked on resize, font load, text-size change. CSS fallback below 300 px |
| 2 | Page scrolled sideways: footer link columns | Large system text, Fold | Footer grid `minmax(0, 1fr)`, one column under 300 px, long words wrap; `overflow-wrap: break-word` on the page; buttons may wrap instead of overflowing |
| 3 | **site.js stopped at line 47** (`MediaQueryList.addEventListener` does not exist) so the menu, reveals, forms and the rest of the page script did nothing | Safari / iOS < 14 | `onMQ()` helper with the `addListener` fallback; same in home.js |
| 4 | Keyboard users saw **no focus ring** (`:focus { outline: none }` + `:focus-visible` the browser does not know) | Safari < 15.4 | `:focus:not(:focus-visible)`: old browsers keep their own outline |
| 5 | Declarations with `clamp()`, `min()`, `max()`, `svh`, `cqi`, `color-mix()` dropped, collapsing spacing, sizes and header backgrounds | iOS < 13.4 (clamp), < 15.4 (svh), < 16.2 (color-mix); Chrome < 79/111 | `tool/web_compat/css_compat.js` writes a plain fallback before each one; custom properties get an `@supports not (...)` block |
| 6 | `inset: 0` overlays lost their position (hero scene, poster, rings, dialogs) | Safari < 14.1, Chrome < 87 | top/right/bottom/left written before every `inset` (same tool) |
| 7 | `margin-inline`, `padding-block` and friends ignored | Safari < 14.1 / 15 | physical sides written before them (same tool) |
| 8 | Flex `gap` ignored: buttons, chips, lists touching each other | Safari < 14.1, Chrome < 84 | `theme-init.js` detects it and adds `.no-flexgap`; the tool writes margin rules for every flex container with a gap |
| 9 | `:has()` / `:focus-visible` in a selector list made old browsers drop the whole rule | Safari < 15.4, Chrome < 105, Firefox < 121 | the tool splits such lists |
| 10 | Admin top bar transparent (no `-webkit-backdrop-filter`, `color-mix`) | Safari < 18 / < 16.2 | prefix + solid fallback |
| 11 | Story frames and board images lost their box (`aspect-ratio`) | Safari < 15 | `@supports not (aspect-ratio)` padding boxes; the pinned story stage switches to still frames when `aspect-ratio` is missing |
| 12 | Guardian live page (`/watch`) script failed to parse (optional chaining) and `replaceChildren` | iOS < 13.4 / < 14 | rewritten in ES2019; DOM clear helper |
| 13 | Profile photo editor button did nothing (no `<dialog>` / `createImageBitmap`) | Safari < 15.4 | button hidden on those browsers (the picture still shows; the app can change it) |
| 14 | iPhone landscape: text under the notch (`viewport-fit=cover` without safe-area padding) | iPhone X and newer, landscape | `env(safe-area-inset-*)` on containers, mobile menu, footer |
| 15 | Account, sign-in, clubs, trip, receipt, checkout, updates, leaderboard, live, delete-account stuck on "Loading..." | JavaScript off | `<noscript>` notice on each |
| 16 | 3D hero heavy on low-end phones | 2 GB RAM / 2 cores or less | still poster (same scene), as with Data Saver |

Not issues (checked): no input under 16 px (no iOS zoom on focus); viewport metas allow zoom; no inline scripts (CSP);
all tap targets 24 px+ except inline text links and native checkboxes; all images have alt text; the old `/api/auth/refresh`
"failed" in the audit is a 204 reported as aborted by Chromium.

## Keeping it fixed

- After any website CSS change: `cd tool/web_compat && npm install && node css_compat.js` (README there).
- `gateway/test/website_device_compat_358.test.js` fails when a new `clamp()`, `svh` or `inset` has no fallback, a
  `backdrop-filter` has no prefix, `:focus { outline: none }` comes back, site.js uses `MediaQueryList.addEventListener`
  directly, a public script uses `?.` / `??`, or a JavaScript-only page loses its notice.

## Real-device QA (release agent, after deploy)

| ID | Device / browser | Check |
|---|---|---|
| D1 | Old iPhone (iOS 12.5 or 14.x if available), Safari | Home, features, get, plans, sign-in: menu opens, no sideways scroll, buttons spaced, focus ring with a keyboard |
| D2 | iPhone (iOS 17/18), Safari, portrait + landscape | Story scrolls, header clear of the notch in landscape, Add to Home Screen icon |
| D3 | Galaxy Z Fold folded (or Chrome 280 px), Samsung Internet | No sideways scroll on any page; header shows logo + menu |
| D4 | Low-end Android (2 GB) Chrome | Home shows the still hero, scrolls smoothly |
| D5 | Android, system font size largest + display size largest | No sideways scroll; footer links readable |
| D6 | iPad Safari portrait/landscape; desktop Firefox, Safari, Edge | Layout, menu at 1024 px boundary, theme switch |
| D7 | Any browser with JavaScript off | Static pages readable; account/sign-in show the notice |
